(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/query :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/query)

;;;; Deterministic in-memory chunk transport. No real CLI/subprocess: proves the
;;;; incremental read loop, control filtering, EOF finalization, cancellation,
;;;; and cleanup entirely offline.

(defclass fake-query-transport (claude-agent-sdk-cl:query-transport)
  ((chunks :initarg :chunks :accessor fake-query-chunks)
   (started-p :initform nil :accessor fake-query-started-p)
   (prompt :initform nil :accessor fake-query-prompt)
   (options :initform :unset :accessor fake-query-options)
   (close-reasons :initform '() :accessor fake-query-close-reasons)
   (read-count :initform 0 :accessor fake-query-read-count)))

(defun make-fake-transport (&rest chunks)
  (make-instance 'fake-query-transport :chunks chunks))

(defmethod claude-agent-sdk-cl:start-query-transport ((transport fake-query-transport) prompt options)
  (setf (fake-query-started-p transport) t
        (fake-query-prompt transport) prompt
        (fake-query-options transport) options)
  transport)

(defmethod claude-agent-sdk-cl:read-query-chunk ((transport fake-query-transport))
  (incf (fake-query-read-count transport))
  (pop (fake-query-chunks transport)))

(defmethod claude-agent-sdk-cl:close-query-transport ((transport fake-query-transport) &key reason)
  (push reason (fake-query-close-reasons transport))
  t)

;;;; Wire fixtures (decode-message expects a nested "message" object with a
;;;; "content" list; result is a top-level record).

(defparameter +assistant-line+
  "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"model\":\"fake-model\"}}")
(defparameter +result-line+
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"s\",\"result\":\"done\"}")
(defparameter +control-line+
  "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"unknown\"}}")
(defparameter +nl+ (string #\Newline))

(test query-streams-assistant-then-result-in-order
  (let* ((transport (make-fake-transport
                     (concatenate 'string +assistant-line+ +nl+)
                     (concatenate 'string +result-line+ +nl+)))
         (seen '())
         (messages (claude-agent-sdk-cl:query
                    "hi" :options :opts :transport transport
                    :on-message (lambda (m) (push m seen)))))
    (is (= 2 (length messages)))
    (is (typep (first messages) 'claude-agent-sdk-cl:assistant-message))
    (is (typep (second messages) 'claude-agent-sdk-cl:result-message))
    (is (string= "done" (claude-agent-sdk-cl:result-message-result (second messages))))
    ;; on-message sees the same order.
    (is (equal (list (first messages) (second messages)) (nreverse seen)))
    ;; prompt/options actually delivered to the transport.
    (is (eq t (fake-query-started-p transport)))
    (is (string= "hi" (fake-query-prompt transport)))
    (is (eq :opts (fake-query-options transport)))
    ;; closed exactly once with :eof.
    (is (equal '(:eof) (fake-query-close-reasons transport)))))

(test query-reassembles-records-split-across-chunks
  ;; Assistant line arrives in three fragments; result in one — the framer must
  ;; stitch them.
  (let* ((mid (floor (length +assistant-line+) 2))
         (transport (make-fake-transport
                     (subseq +assistant-line+ 0 mid)
                     (subseq +assistant-line+ mid)
                     (concatenate 'string +nl+ +result-line+ +nl+)))
         (messages (claude-agent-sdk-cl:query "hi" :transport transport)))
    (is (= 2 (length messages)))
    (is (typep (first messages) 'claude-agent-sdk-cl:assistant-message))
    (is (typep (second messages) 'claude-agent-sdk-cl:result-message))))

(test query-skips-control-records
  (let* ((transport (make-fake-transport
                     (concatenate 'string +control-line+ +nl+)
                     (concatenate 'string +assistant-line+ +nl+)
                     (concatenate 'string +control-line+ +nl+)
                     (concatenate 'string +result-line+ +nl+)))
         (messages (claude-agent-sdk-cl:query "hi" :transport transport)))
    ;; Control traffic is never yielded as a user message.
    (is (= 2 (length messages)))
    (is (typep (first messages) 'claude-agent-sdk-cl:assistant-message))
    (is (typep (second messages) 'claude-agent-sdk-cl:result-message))))

(test query-flushes-valid-unterminated-eof-record
  ;; Final result has no trailing newline; flush-jsonl-framer must surface it.
  (let* ((transport (make-fake-transport
                     (concatenate 'string +assistant-line+ +nl+)
                     +result-line+))
         (messages (claude-agent-sdk-cl:query "hi" :transport transport)))
    (is (= 2 (length messages)))
    (is (typep (second messages) 'claude-agent-sdk-cl:result-message))
    (is (equal '(:eof) (fake-query-close-reasons transport)))))

(test query-empty-stream-returns-nil-and-closes-eof
  (let* ((transport (make-fake-transport))
         (messages (claude-agent-sdk-cl:query "hi" :transport transport)))
    (is (null messages))
    (is (equal '(:eof) (fake-query-close-reasons transport)))))

(test query-cancellation-stops-reading-and-closes-cancel
  (let* ((transport (make-fake-transport
                     (concatenate 'string +assistant-line+ +nl+)
                     (concatenate 'string +result-line+ +nl+)))
         (calls 0)
         (messages (claude-agent-sdk-cl:query
                    "hi" :transport transport
                    :on-message (lambda (m) (declare (ignore m)) (incf calls) :cancel))))
    ;; Only the first message is yielded, callback fired once.
    (is (= 1 (length messages)))
    (is (= 1 calls))
    (is (typep (first messages) 'claude-agent-sdk-cl:assistant-message))
    ;; Proves the loop actually stopped: chunk 2 (the result line) was never
    ;; fetched. (length messages) alone would pass even if reading continued.
    (is (= 1 (fake-query-read-count transport)))
    ;; Closed exactly once with :cancel.
    (is (equal '(:cancel) (fake-query-close-reasons transport)))))

(test query-malformed-mid-stream-signals-and-closes-error
  (let ((transport (make-fake-transport
                    (concatenate 'string +assistant-line+ +nl+)
                    (concatenate 'string "{garbage" +nl+))))
    (signals claude-agent-sdk-cl::cli-json-error
      (claude-agent-sdk-cl:query "hi" :transport transport))
    ;; Both chunks (assistant + garbage) were read; decode fails on the second
    ;; before any EOF probe.
    (is (= 2 (fake-query-read-count transport)))
    (is (equal '(:error) (fake-query-close-reasons transport)))))

(test query-incomplete-eof-record-signals-and-closes-error
  (let ((transport (make-fake-transport
                    (concatenate 'string +assistant-line+ +nl+)
                    "{\"type\":\"re")))
    (signals claude-agent-sdk-cl::cli-json-error
      (claude-agent-sdk-cl:query "hi" :transport transport))
    ;; assistant chunk, incomplete chunk, then the EOF probe (NIL) — the fake
    ;; transport counts every read-query-chunk call, including the EOF probe,
    ;; so the incomplete final record fails at flush after 3 read calls.
    (is (= 3 (fake-query-read-count transport)))
    (is (equal '(:error) (fake-query-close-reasons transport)))))

(test query-cleanup-logs-protocol-cleanup-reason
  ;; The router cleanup fires with the exit reason on every path.
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events)))
         (transport (make-fake-transport
                     (concatenate 'string +result-line+ +nl+))))
    (claude-agent-sdk-cl:query "hi" :transport transport)
    (let ((cleanup (find :protocol.cleanup (nreverse events)
                         :key (lambda (event) (getf event :event)))))
      (is-true cleanup)
      (is (eq :eof (getf cleanup :reason))))))

(test query-validates-prompt-and-transport-before-start
  ;; Non-string prompt: signals before any transport start.
  (let ((transport (make-fake-transport)))
    (signals claude-agent-sdk-cl::sdk-input-error
      (claude-agent-sdk-cl:query 42 :transport transport))
    (is (null (fake-query-started-p transport)))
    (is (null (fake-query-close-reasons transport))))
  ;; Missing transport: signals.
  (signals claude-agent-sdk-cl::sdk-input-error
    (claude-agent-sdk-cl:query "hi")))

;;;; Cleanup contract: every failure path inside the read loop closes the
;;;; transport exactly once with :error and logs :protocol.cleanup :reason :error.

(defclass exploding-start-transport (fake-query-transport) ())
(defmethod claude-agent-sdk-cl:start-query-transport ((transport exploding-start-transport) prompt options)
  (declare (ignore prompt options))
  (error "start blew up"))

(test query-start-failure-closes-error-exactly-once
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events)))
         (transport (make-instance 'exploding-start-transport :chunks '())))
    ;; The original error propagates (not swallowed by cleanup).
    (signals simple-error
      (claude-agent-sdk-cl:query "hi" :transport transport))
    ;; Closed exactly once, reason :error; no chunks were ever read.
    (is (equal '(:error) (fake-query-close-reasons transport)))
    (is (= 0 (fake-query-read-count transport)))
    (let ((cleanup (find :protocol.cleanup (nreverse events)
                         :key (lambda (event) (getf event :event)))))
      (is-true cleanup)
      (is (eq :error (getf cleanup :reason))))))

(test query-callback-error-closes-error-exactly-once
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events)))
         (transport (make-fake-transport
                     (concatenate 'string +assistant-line+ +nl+)
                     (concatenate 'string +result-line+ +nl+))))
    ;; A callback that raises must propagate and still clean up once with :error.
    (signals simple-error
      (claude-agent-sdk-cl:query
       "hi" :transport transport
       :on-message (lambda (m) (declare (ignore m)) (error "callback blew up"))))
    (is (equal '(:error) (fake-query-close-reasons transport)))
    ;; Callback errored on the first (assistant) message, so the loop must not
    ;; have fetched the second (result) chunk — same false-green guard as :cancel.
    (is (= 1 (fake-query-read-count transport)))
    (let ((cleanup (find :protocol.cleanup (nreverse events)
                         :key (lambda (event) (getf event :event)))))
      (is-true cleanup)
      (is (eq :error (getf cleanup :reason))))))
