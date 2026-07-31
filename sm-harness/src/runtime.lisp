(in-package #:sm-harness)

(defstruct (session-runtime (:constructor %make-session-runtime))
  record
  client
  (listeners (make-hash-table :test #'equal))
  (lock (sb-thread:make-mutex :name "session-runtime"))
  worker-thread
  (mailbox (list))
  (mailbox-lock (sb-thread:make-mutex :name "session-mailbox"))
  (mailbox-cv (sb-thread:make-waitqueue :name "session-mailbox"))
  (closed-p nil)
  cancellation-reason
  deadline-thread
  last-activity
  ;; Most recent assistant text streamed this turn.  The terminal result's
  ;; text commonly mirrors the last assistant message verbatim; tracking
  ;; this lets the terminal handler skip re-showing/re-persisting it as a
  ;; second, duplicate response.
  pending-assistant-text
  ;; Tool-use-id -> tool name, populated on :tool-requested and consumed on
  ;; :tool-completed/:tool-failed (see #76): those payloads don't carry the
  ;; tool name themselves, only the id, so correlating a completed tool back
  ;; to "was this reload_harness" needs this lookup.
  (pending-tool-names (make-hash-table :test #'equal))
  ;; Text queued by a successful reload_harness completion (#76), to be
  ;; auto-submitted as a fresh turn once the CURRENT turn finishes -- never
  ;; run immediately, since the harness allows only one active turn.
  pending-synthetic-followup
  ;; Consecutive count of harness-initiated (not human) follow-up turns.
  ;; Resets to 0 whenever a turn completes without queueing another one;
  ;; bounded by +MAX-CONSECUTIVE-SYNTHETIC-FOLLOWUPS+ so a model stuck in a
  ;; reload/fail/retry loop cannot run unbounded, unnoticed.
  (synthetic-followup-chain-length 0)
  ;; Conversational tool calls requested but not yet completed/failed this
  ;; turn.  The deadline watchdog re-arms instead of cancelling while this
  ;; is positive: a tool call owns its own timeout (the bash tool enforces
  ;; one), so the turn deadline measures model/CLI stall, not tool
  ;; runtime (#80).
  (inflight-tool-calls 0 :type integer)
  ;; Set by MARK-SESSIONS-FOR-CATALOG-REFRESH (#116 phase 2) after a
  ;; successful RELOAD_HARNESS, from a foreign thread -- so this flag, never
  ;; SESSION-RUNTIME-CLIENT itself, is the only thing a foreign thread ever
  ;; writes here. %ENSURE-CLIENT consumes it at the top of its own next call,
  ;; always on this session's own worker thread (%RUN-TURN), so an
  ;; in-flight turn is never disrupted: the flag is only checked when a *new*
  ;; turn is about to start, and disconnecting+rebuilding the client there
  ;; reuses the exact same code path an error-recovery reconnect already
  ;; does (:RESUME (SESSION-RECORD-CANONICAL-ID REC)).
  (pending-catalog-refresh-p nil))

(defstruct (harness (:constructor %make-harness))
  config
  repository
  ;; Zero-argument function returning a TOOL-CATALOG, called fresh every
  ;; time %ENSURE-CLIENT builds a *new* client connection -- never a
  ;; materialized TOOL-CATALOG value read once (see #116). Before #116 this
  ;; slot held a TOOL-CATALOG built once by (DEFAULT-TOOL-CATALOG) at
  ;; MAKE-HARNESS time and never re-read, so a RELOAD_HARNESS that added a
  ;; tool was invisible to every session for the rest of this process's
  ;; life -- including a session that had not even been created yet.
  ;; MAKE-HARNESS wraps an explicit :CATALOG argument (tests/fixtures that
  ;; want a fixed, unchanging catalog) in a constant-returning closure, so
  ;; only the *default*, no-:CATALOG-argument production path actually goes
  ;; back to DEFAULT-TOOL-CATALOG on every new connection.
  catalog-provider
  policy
  (sessions (make-hash-table :test #'equal))
  (lock (sb-thread:make-mutex :name "harness"))
  (closed-p nil))

(defun %touch (rt)
  (setf (session-runtime-last-activity rt) (get-universal-time)))

(defvar *session-event-log-lock* (sb-thread:make-mutex :name "session-event-log")
  "Serializes SM-HARNESS-EVENT log lines so concurrent sessions' worker
threads cannot interleave a single line.")

(defvar *session-event-log-stream* *standard-output*
  "Destination for SM-HARNESS-EVENT lines. A global (not per-call dynamic)
binding so a worker thread, which does not inherit another thread's LET
bindings, still observes a test's temporary swap of this stream.")

(defun %log-session-event (session-id sequence type payload)
  "Permanent, session-tagged operator diagnostic for every normalized harness
event, including its full payload. This is a deliberate exception to this
project's usual browser-facing redaction boundary (see SAFE-ERROR-PAYLOAD):
the payloads normalized here are product/tool content, not credentials or
raw provider transport frames, and this log is operator-only (container
stdout), never rendered to the browser. See docs/sm-harness-web-ui.md
under \"Operator diagnostics\" for how to locate and read it."
  (let ((line (with-output-to-string (s)
                (yason:encode
                 (let ((o (make-hash-table :test #'equal)))
                   (setf (gethash "ts" o) (%now-iso)
                         (gethash "session_id" o) session-id
                         (gethash "sequence" o) sequence
                         (gethash "type" o) (string-downcase (symbol-name type))
                         (gethash "payload" o)
                         (if (and (listp payload) (keywordp (first payload)))
                             (%plist->json payload)
                             payload))
                   o)
                 s))))
    (sb-thread:with-mutex (*session-event-log-lock*)
      (format *session-event-log-stream* "~&SM-HARNESS-EVENT ~A~%" line)
      (force-output *session-event-log-stream*))))

(defun %log-operator-diagnostic (session-id turn-id condition)
  "SM-HARNESS-DIAGNOSTIC line: the raw condition behind a redacted
browser-facing :error event. SAFE-ERROR-PAYLOAD deliberately tells the
browser nothing but \"internal error\"; this operator-only line (container
stdout, same channel as %LOG-SESSION-EVENT) is where the withheld detail
actually goes -- without it a failed turn is undiagnosable after the fact
(2026-07-30: a starved MCP control request took filesystem forensics to
explain because the condition was redacted and then dropped)."
  (let ((line (with-output-to-string (s)
                (yason:encode
                 (let ((o (make-hash-table :test #'equal)))
                   (setf (gethash "ts" o) (%now-iso)
                         (gethash "session_id" o) session-id
                         (gethash "turn_id" o) turn-id
                         (gethash "condition_type" o)
                         (princ-to-string (type-of condition))
                         (gethash "condition" o)
                         (handler-case (princ-to-string condition)
                           (error () "condition unprintable")))
                   o)
                 s))))
    (sb-thread:with-mutex (*session-event-log-lock*)
      (format *session-event-log-stream* "~&SM-HARNESS-DIAGNOSTIC ~A~%" line)
      (force-output *session-event-log-stream*))))

(defun %publish (rt type payload)
  (let* ((rec (session-runtime-record rt))
         (seq (incf (session-record-sequence rec)))
         (ev (%event type (session-record-id rec) seq payload)))
    (%log-session-event (session-record-id rec) seq type payload)
    ;; Enqueue only -- callbacks run on each listener's own dispatcher
    ;; thread (%LISTENER-DISPATCH-LOOP). Publishing happens on the session
    ;; worker, the same thread that answers the CLI's MCP control requests,
    ;; so one browser connection whose peer silently died must not be able
    ;; to stall it (2026-07-30: exactly that starved a tools/call answer
    ;; until the CLI gave up and the turn died as \"internal error\").
    (maphash (lambda (id lst)
               (declare (ignore id))
               (listener-push lst ev))
             (session-runtime-listeners rt))
    ev))

(defun %set-status (rt status)
  (setf (session-record-status (session-runtime-record rt)) status)
  (%publish rt :status (list :status status)))

(defparameter +max-consecutive-synthetic-followups+ 3
  "Safety cap on consecutive harness-initiated follow-up turns (#76).
Without this, a model stuck in a reload_harness reload/fail/retry loop
could keep triggering new follow-ups indefinitely, unnoticed, consuming
the operator's provider budget. Resets to 0 whenever a turn completes
without queueing another follow-up, so this bounds a single chain, not a
session's lifetime total.")

(defun %reload-followup-text ()
  "User-turn text auto-submitted after a successful reload_harness (#76).
Prefixed distinctly and explicit that no human sent it; also persisted
with transcript kind \"synthetic\" (see %RUN-TURN) so it is never
rendered indistinguishably from a real user message."
  "[harness] reload_harness finished successfully. This is an automatic follow-up turn -- no human sent it. Tool schemas and handlers have been re-resolved for this session. If you added or changed a tool, call it now to verify it works, then give your final response.")

(defun %followup-cap-message ()
  (format nil "[harness] automatic reload_harness follow-up limit (~D consecutive) reached; no further automatic follow-up turns will run until this chain resets."
          +max-consecutive-synthetic-followups+))

(defun %maybe-run-synthetic-followup (harness rt)
  "Consume RT's pending synthetic follow-up, if any, once the current turn
has fully finished. Auto-submits a new turn via the same SUBMIT-TURN path
a human message would use, up to +MAX-CONSECUTIVE-SYNTHETIC-FOLLOWUPS+;
beyond that, records a safe notice instead of submitting and resets the
chain so a later, genuine attempt gets a fresh allowance."
  (let ((text (session-runtime-pending-synthetic-followup rt)))
    (setf (session-runtime-pending-synthetic-followup rt) nil)
    (cond
      ((null text)
       (setf (session-runtime-synthetic-followup-chain-length rt) 0))
      ((< (session-runtime-synthetic-followup-chain-length rt)
          +max-consecutive-synthetic-followups+)
       (incf (session-runtime-synthetic-followup-chain-length rt))
       (submit-turn harness (session-record-id (session-runtime-record rt)) text
                    :kind "synthetic"))
      (t
       (setf (session-runtime-synthetic-followup-chain-length rt) 0)
       (%append-transcript rt "system" (%followup-cap-message) :kind "synthetic")
       (%publish rt :system (list :subtype "synthetic-followup-cap-reached"))))))

(defun %append-transcript (rt role text &key (kind "message") meta)
  (let ((entry (make-transcript-entry :role role :text text :kind kind :meta meta)))
    (setf (session-record-transcript (session-runtime-record rt))
          (append (session-record-transcript (session-runtime-record rt))
                  (list entry)))
    entry))

(defun %enqueue (rt message)
  (sb-thread:with-mutex ((session-runtime-mailbox-lock rt))
    (setf (session-runtime-mailbox rt)
          (append (session-runtime-mailbox rt) (list message)))
    (sb-thread:condition-notify (session-runtime-mailbox-cv rt))))

(defun %dequeue (rt)
  (sb-thread:with-mutex ((session-runtime-mailbox-lock rt))
    (loop
      (when (session-runtime-closed-p rt)
        (return nil))
      (let ((mb (session-runtime-mailbox rt)))
        (when mb
          (setf (session-runtime-mailbox rt) (cdr mb))
          (return (car mb))))
      (sb-thread:condition-wait (session-runtime-mailbox-cv rt)
                                (session-runtime-mailbox-lock rt)))))

(defun %session-system-prompt (cfg rt)
  "Configured base prompt plus a per-session identity line.
The identity line names the id shown in the UI and the transcript file it
maps onto, so an agent asked about \"this session\" needs no discovery step."
  (let ((base (harness-config-system-prompt cfg)))
    (when base
      (let ((id (session-record-id (session-runtime-record rt))))
        (format nil "~A~2%The id of the session you are currently serving is ~A. ~
Its transcript is persisted at ~A."
                base id
                (namestring
                 (merge-pathnames
                  (format nil "~A/sessions/~A.json"
                          (harness-config-project-key cfg) id)
                  (harness-config-data-root cfg))))))))

(defun %ensure-client (harness rt &key resume)
  ;; #116 phase 2: MARK-SESSIONS-FOR-CATALOG-REFRESH (a foreign thread, the
  ;; post-reload hook) may have flagged this session between turns. Consumed
  ;; here, on this session's own worker thread (%ENSURE-CLIENT only ever
  ;; runs from inside %RUN-TURN), strictly before the "already connected"
  ;; early return below -- so a turn actively in flight is never touched;
  ;; this only ever runs at the very start of the *next* turn. Disconnecting
  ;; here and falling through to the ordinary connect logic below reuses
  ;; exactly the :RESUME-based rebuild an error-recovery reconnect already
  ;; performs (RESUME is always (session-record-canonical-id rec), passed
  ;; in by %RUN-TURN, so this reconnect carries full prior context the same
  ;; way that recovery path already does).
  (when (session-runtime-pending-catalog-refresh-p rt)
    (setf (session-runtime-pending-catalog-refresh-p rt) nil)
    (when (session-runtime-client rt)
      (ignore-errors (disconnect-client (session-runtime-client rt)))
      (setf (session-runtime-client rt) nil)))
  (when (session-runtime-client rt)
    (return-from %ensure-client (session-runtime-client rt)))
  (let* ((cfg (harness-config harness))
         ;; Fresh every new connection, never cached across reconnects (#116):
         ;; a RELOAD_HARNESS that added a tool must reach the *next* client
         ;; this builds, including one for a session that already existed.
         (catalog (funcall (harness-catalog-provider harness)))
         (policy (harness-policy harness))
         ;; #106: a session created with an explicit :MODEL overrides the
         ;; harness-wide default; a legacy or default-backend session (NIL
         ;; model) falls back to HARNESS-CONFIG-MODEL exactly as before.
         (options (build-agent-options catalog policy
                                       :resume resume
                                       :model (or (session-record-model (session-runtime-record rt))
                                                  (harness-config-model cfg))
                                       :system-prompt (%session-system-prompt cfg rt)))
         (factory (harness-config-transport-factory cfg))
         (transport (when factory (funcall factory options)))
         (client (make-sdk-client options
                                  :transport transport
                                  :cli-path (harness-config-cli-path cfg))))
    (setf (session-runtime-client rt) client)
    (%set-status rt :connecting)
    (connect-client client)
    (%set-status rt :ready)
    client))

(defun %handle-mapped-event (rt rec mapped)
  (let ((etype (first mapped))
        (payload (rest mapped)))
    (case etype
      (:assistant-text
       (let ((text (getf payload :text)))
         (%append-transcript rt "assistant" text)
         (%publish rt :assistant-text payload)
         (setf (session-runtime-pending-assistant-text rt) text)
         nil))
      (:tool-requested
       (setf (gethash (getf payload :id) (session-runtime-pending-tool-names rt))
             (getf payload :name))
       (%append-transcript rt "assistant"
                           (format nil "Tool requested: ~A" (getf payload :name))
                           :kind "tool" :meta payload)
       (%publish rt :tool-requested payload)
       (incf (session-runtime-inflight-tool-calls rt))
       nil)
      (:tool-completed
       (let ((name (gethash (getf payload :tool-use-id) (session-runtime-pending-tool-names rt))))
         (remhash (getf payload :tool-use-id) (session-runtime-pending-tool-names rt))
         ;; :tool-completed only ever fires for a non-error result (the
         ;; mapping layer already splits success/failure into distinct event
         ;; types -- see #58) -- so reaching here already means success.
         (when (equal name "reload_harness")
           (setf (session-runtime-pending-synthetic-followup rt) (%reload-followup-text))))
       (%append-transcript rt "assistant"
                           (format nil "Tool completed: ~A" (getf payload :content))
                           :kind "tool" :meta payload)
       (%publish rt :tool-completed payload)
       (setf (session-runtime-inflight-tool-calls rt)
             (max 0 (1- (session-runtime-inflight-tool-calls rt))))
       nil)
      (:tool-failed
       (remhash (getf payload :tool-use-id) (session-runtime-pending-tool-names rt))
       (%append-transcript rt "assistant" "Tool failed"
                           :kind "tool" :meta payload)
       (%publish rt :tool-failed payload)
       (setf (session-runtime-inflight-tool-calls rt)
             (max 0 (1- (session-runtime-inflight-tool-calls rt))))
       nil)
      (:system
       (%publish rt :system payload)
       nil)
      (:rate-limit
       (%publish rt :rate-limit payload)
       nil)
      (:terminal
       (let* ((cid (getf payload :session-id))
              (text (getf payload :text))
              ;; The CLI's terminal result text commonly mirrors the last
              ;; assistant message verbatim for an ordinary text-only turn.
              ;; Render/persist that case exactly once, via the assistant
              ;; stream; a genuinely distinct terminal outcome (error text,
              ;; a tool-only turn with no assistant text, etc.) still gets
              ;; its own entry.
              (duplicate-p (and text (plusp (length text))
                               (equal text (session-runtime-pending-assistant-text rt))))
              (published-payload (if duplicate-p
                                     (let ((copy (copy-list payload)))
                                       (setf (getf copy :text) nil)
                                       copy)
                                     payload)))
         (when (and cid (stringp cid) (plusp (length cid)))
           (setf (session-record-canonical-id rec) cid))
         (unless duplicate-p
           (%append-transcript rt "system" (or text "")
                               :kind "result" :meta payload))
         (%publish rt :terminal published-payload))
       (setf (session-runtime-pending-assistant-text rt) nil)
       (%set-status rt :ready)
       :done)
      (t
       (%publish rt etype payload)
       nil))))

(defun %request-cancellation (rt turn-id reason)
  "Request a turn stop without waiting behind the session read owner."
  (let ((client nil))
    (sb-thread:with-mutex ((session-runtime-lock rt))
      (when (and (string= turn-id (or (session-record-active-turn-id
                                       (session-runtime-record rt)) ""))
                 (null (session-runtime-cancellation-reason rt)))
        (setf (session-runtime-cancellation-reason rt) reason
              client (session-runtime-client rt))
        (%set-status rt :stopping)))
    (when client
      ;; This write has no synchronous read/response wait, so the worker remains
      ;; the sole SDK reader while blocked in RECEIVE-ONE-MESSAGE.
      (ignore-errors (request-interrupt-client client))
      ;; The SDK reader owns transport lifecycle.  A deadline therefore emits
      ;; the same writer-only cancellation request and lets that reader consume
      ;; the correlated response/terminal event without racing router teardown.
      )
    reason))

(defun %start-deadline-watchdog (harness rt turn-id)
  "Cancel TURN-ID after TURN-DEADLINE-SECONDS of model/CLI stall.  A wake
that finds a conversational tool call still in flight re-arms instead of
cancelling: the tool call owns its own timeout (the bash tool enforces one
explicitly, up to 600s -- comparable to the 600s default here), so expiring
the whole turn mid-call guaranteed a doomed turn for every legitimately
slow tool call (#80).  Stall is therefore measured at watchdog wakeups: a
turn keeps running as long as tool calls are still in flight whenever the
watchdog looks."
  (let ((seconds (harness-config-turn-deadline-seconds (harness-config harness))))
    (setf (session-runtime-deadline-thread rt)
          (sb-thread:make-thread
           (lambda ()
             (loop
               (sleep seconds)
               (case (sb-thread:with-mutex ((session-runtime-lock rt))
                       (cond
                         ((not (string= turn-id
                                        (or (session-record-active-turn-id
                                             (session-runtime-record rt))
                                            "")))
                          :turn-over)
                         ((plusp (session-runtime-inflight-tool-calls rt))
                          :re-arm)
                         (t :expire)))
                 (:turn-over (return))
                 (:re-arm)
                 (:expire
                  (%request-cancellation rt turn-id :deadline)
                  (return)))))
           :name (format nil "sm-deadline-~A" turn-id)))))

(defun %finish-cancellation (rt)
  (case (session-runtime-cancellation-reason rt)
    (:interrupt
     (%publish rt :terminal (list :text "turn interrupted" :is-error nil))
     (%set-status rt :ready))
    (:deadline
     (%publish rt :error (list :message "turn deadline exceeded"))
     (%set-status rt :error))))

(defun %run-turn (harness rt turn-id prompt &optional (kind "message"))
  (let ((rec (session-runtime-record rt)))
    (handler-case
        (progn
          (setf (session-record-active-turn-id rec) turn-id
                (session-runtime-cancellation-reason rt) nil
                (session-runtime-pending-assistant-text rt) nil
                (session-runtime-inflight-tool-calls rt) 0)
          ;; A pre-connect failure has not accepted the prompt.  Do not create a
          ;; durable user record until the client connection is usable; the web
          ;; presentation retains its draft locally for retry.
          (let* ((resume (session-record-canonical-id rec))
                 (client (%ensure-client harness rt :resume resume))
                 (done nil))
            (%append-transcript rt "user" prompt :kind kind)
            (%publish rt :user-message
                      (list :text prompt :turn-id turn-id
                            :synthetic (and (equal kind "synthetic") t)))
            (repository-save-session (harness-repository harness) rec)
            (%set-status rt :responding)
            (send-prompt client prompt
                         :session-id (or (session-record-canonical-id rec)
                                         (session-record-id rec)))
            (%start-deadline-watchdog harness rt turn-id)
            ;; The loop's DO clause is exactly one form (the LET); its own
            ;; closing paren is required here so the post-loop cleanup below
            ;; runs once after DONE, not as extra DO forms re-run per message.
            (loop until done do
              (let ((msg (receive-one-message client)))
                (cond
                  ((null msg)
                   (if (session-runtime-cancellation-reason rt)
                       (%finish-cancellation rt)
                       (%set-status rt :disconnected))
                   (setf (session-runtime-client rt) nil
                         done t))
                  (t
                   (dolist (mapped (map-sdk-message msg))
                     (when (eq :done (%handle-mapped-event rt rec mapped))
                       (setf done t)))))))
            (let ((reason (session-runtime-cancellation-reason rt)))
              (setf (session-runtime-cancellation-reason rt) nil)
              ;; A deadline abort usually ends through the CLI's own
              ;; terminal event (error_during_execution with no text), which
              ;; the loop treats as :done -- so %FINISH-CANCELLATION never
              ;; runs and the turn would end with no visible explanation at
              ;; all.  That silent stop is exactly what made the 2026-07-29
              ;; incident look like the session died for no reason (#80).
              (when (eq reason :deadline)
                (%publish rt :error (list :message "turn deadline exceeded"))))
            (setf (session-record-active-turn-id rec) nil)
            (repository-save-session (harness-repository harness) rec)
            (%touch rt)
            (%maybe-run-synthetic-followup harness rt)))
      (error (c)
        ;; Operator-only raw condition first, before anything else here can
        ;; fail: the event published below is deliberately redacted.
        (%log-operator-diagnostic (session-record-id rec) turn-id c)
        ;; The in-memory record may contain a prompt or terminal event whose
        ;; save just failed.  Reload the last committed record before recording
        ;; the recoverable runtime error, so cleanup cannot accidentally commit
        ;; that failed mutation on its second save attempt.  A failing reload
        ;; (a load-side fault) must not crash the worker thread: fall back to
        ;; the in-memory record rather than lose the session entirely.
        (handler-case
            (setf (session-runtime-record rt)
                  (repository-load-session (harness-repository harness)
                                           (session-record-id rec)))
          (error () nil))
        (setf rec (session-runtime-record rt)
              (session-record-active-turn-id rec) nil)
        (%publish rt :error (safe-error-payload c))
        (%set-status rt :error)
        (ignore-errors
          (when (session-runtime-client rt)
            (disconnect-client (session-runtime-client rt))
            (setf (session-runtime-client rt) nil)))
        ;; Best-effort: a second persistence fault here must not crash the
        ;; worker thread or leave the runtime unable to accept a later turn.
        (ignore-errors
          (repository-save-session (harness-repository harness) rec))))))

(defun %worker-loop (harness rt)
  (loop
    (when (session-runtime-closed-p rt)
      (return))
    (let ((msg (%dequeue rt)))
      (unless msg (return))
      (destructuring-bind (op . args) msg
        (ecase op
          (:turn
           (destructuring-bind (turn-id prompt kind) args
             (%run-turn harness rt turn-id prompt kind)))
          (:interrupt
           (let ((client (session-runtime-client rt)))
             (when client
               (%set-status rt :stopping)
               (ignore-errors (interrupt-client client)))))
          (:stop (return)))))))

(defun %start-worker (harness rt)
  (unless (and (session-runtime-worker-thread rt)
               (sb-thread:thread-alive-p (session-runtime-worker-thread rt)))
    (setf (session-runtime-worker-thread rt)
          (sb-thread:make-thread
           (lambda () (%worker-loop harness rt))
           :name (format nil "sm-session-~A"
                         (session-record-id (session-runtime-record rt)))))))

(defun %get-runtime (harness session-id &key (errorp t))
  (sb-thread:with-mutex ((harness-lock harness))
    (or (gethash session-id (harness-sessions harness))
        (when errorp
          (error 'harness-not-found-error
                 :message (format nil "session not open: ~A" session-id))))))

(defun %open-runtime (harness rec)
  (let ((rt (%make-session-runtime :record rec :last-activity (get-universal-time))))
    (setf (gethash (session-record-id rec) (harness-sessions harness)) rt)
    (%start-worker harness rt)
    rt))
