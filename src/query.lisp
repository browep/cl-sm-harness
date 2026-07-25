(in-package #:claude-agent-sdk-cl)

;;;; One-shot streamed `query'.
;;;;
;;;; Built on an incremental JSONL read loop over an injected transport, NOT on
;;;; `run-cli' (which slurps stdout/stderr only after the child exits and so
;;;; cannot prove message-by-message delivery, control skipping, EOF
;;;; finalization, or mid-stream cancellation). See Phase 4.1 / issue #10.
;;;;
;;;; Note: `"system"' records ARE decoded (generic `system-message', below), so
;;;; live streams that emit system events before the assistant turn no longer
;;;; crash. Subtype-aware modelling (task_started, task_progress, hook lifecycle,
;;;; ... per upstream message_parser.py) is deferred to a later parity slice; the
;;;; generic system-message preserves the full raw wire on `data'.

(defclass query-transport ()
  ()
  (:documentation
   "Abstract streamed transport for `query'. Implementations yield stdout
chunks (strings) one at a time and NIL at EOF."))

(defgeneric read-query-chunk (transport)
  (:documentation
   "Return the next stdout chunk as a string, or NIL at end of stream."))

(defgeneric start-query-transport (transport prompt options)
  (:documentation
   "Deliver PROMPT and OPTIONS to TRANSPORT before the read loop begins
(the initialize/query exchange). Called exactly once. Returns TRANSPORT."))

(defmethod start-query-transport ((transport query-transport) prompt options)
  "Default: nothing to deliver. Fakes override to assert prompt/options."
  (declare (ignore prompt options))
  transport)

(defgeneric close-query-transport (transport &key reason)
  (:documentation
   "Release the transport. REASON is one of :eof, :error, or :cancel. Must be
idempotent."))

(defun decode-query-event (record)
  "Decode a routed :event RECORD into an SDK message object.
`decode-message' is the boundary for user/assistant envelopes; `result' is a
top-level record with no nested body and uses `decode-result-message'."
  (let ((type (gethash "type" record)))
    (cond
      ((equal type "result") (decode-result-message record))
      ((equal type "system") (decode-system-message record))
      ((or (equal type "assistant") (equal type "user")) (decode-message record))
      (t (signal-cli-json-error
          (format nil "unsupported query message type: ~A" type))))))

(defun query (prompt &key options transport on-message)
  "Run a one-shot streamed query and return the ordered list of yielded messages.

PROMPT must be a string. TRANSPORT is an injected `query-transport'
(subprocess auto-provisioning arrives in a later slice). OPTIONS is reserved for
the prompt/options-to-transport contract and is accepted but not yet consumed.

If ON-MESSAGE is supplied it is called synchronously with each yielded message
as that message is produced; the callback returning completes the backpressure
point. If the callback returns :cancel, reading stops immediately, the
transport is closed with reason :cancel, the router is cleared, and the messages
yielded so far are returned.

The transport is always closed and the protocol router always cleared on every
exit path (success/EOF, malformed JSON/error, cancellation), each exactly once."
  (unless (stringp prompt)
    (signal-sdk-input-error "query prompt must be a string"))
  (unless transport
    (signal-sdk-input-error "query requires an injected :transport in this slice"))
  (let ((framer (make-jsonl-framer))
        (router (make-protocol-router))
        (messages '())
        (cancelled nil)
        (close-reason :eof))
    (labels ((yield-record (record)
               ;; Returns :cancel when the caller asked to stop; blank records
               ;; (NIL from decode-jsonl-record) are ignored.
               (when record
                 (multiple-value-bind (routed route) (route-protocol-record router record)
                   (declare (ignore routed))
                   ;; :control and :response are internal control traffic;
                   ;; upstream `continue's past them and never yields them. A
                   ;; one-shot query has no pending-request consumer, so
                   ;; :response is intentionally dropped here too (matched
                   ;; responses are consumed from the router's pending table).
                   (when (eq route :event)
                     (let ((message (decode-query-event record)))
                       (push message messages)
                       (when (and on-message (eq (funcall on-message message) :cancel))
                         (setf cancelled t
                               close-reason :cancel)
                         :cancel))))))
             (process-raw (raw)
               (eq (yield-record (decode-jsonl-record raw)) :cancel)))
      (unwind-protect
           (handler-case
               (progn
                 ;; Inside the protected form: if start signals or partially
                 ;; allocates, cleanup still runs.
                 (start-query-transport transport prompt options)
                 (loop for chunk = (read-query-chunk transport)
                       while chunk do
                         (dolist (raw (push-jsonl-chunk framer chunk))
                           (when (process-raw raw)
                             (return)))
                       until cancelled)
                 (unless cancelled
                   ;; EOF: a valid unterminated final record still counts; an
                   ;; incomplete one makes decode-jsonl-record signal.
                   (let ((final (flush-jsonl-framer framer)))
                     (when final (process-raw final))))
                 ;; Single nreverse: this is the returned value.
                 (nreverse messages))
             (error (condition)
               (setf close-reason :error)
               (error condition)))
        ;; Sole cleanup path — runs on success/EOF, cancellation, and error.
        (clear-protocol-router router :reason close-reason)
        (close-query-transport transport :reason close-reason)))))
