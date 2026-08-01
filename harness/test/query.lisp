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
(defparameter +rate-limit-line+
  "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed_warning\",\"resetsAt\":1700000000,\"rateLimitType\":\"five_hour\",\"utilization\":0.85},\"uuid\":\"u\",\"session_id\":\"s\"}")
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

(test query-yields-rate-limit-events-in-wire-order
  (let* ((transport (make-fake-transport
                     (concatenate 'string +rate-limit-line+ +nl+)
                     (concatenate 'string +assistant-line+ +nl+)
                     (concatenate 'string +result-line+ +nl+)))
         (messages (claude-agent-sdk-cl:query "hi" :transport transport))
         (event (first messages)))
    (is (= 3 (length messages)))
    (is (typep event 'claude-agent-sdk-cl:rate-limit-event))
    (is (string= "allowed_warning"
                 (claude-agent-sdk-cl:rate-limit-info-status
                  (claude-agent-sdk-cl:rate-limit-event-rate-limit-info event))))
    (is (typep (second messages) 'claude-agent-sdk-cl:assistant-message))
    (is (typep (third messages) 'claude-agent-sdk-cl:result-message))))

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

;;;; ---------------------------------------------------------------------------
;;;; Subprocess-backed streaming query transport (fake-CLI driven, offline).
;;;; ---------------------------------------------------------------------------

(defparameter +system-line+
  "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\",\"cwd\":\"/tmp\"}")

(defparameter +fake-cli+ "/workspace/test/fake-claude.sh")

(defun run-subprocess-query (arguments &key (prompt "hi") on-message (timeout 10))
  (let ((transport (claude-agent-sdk-cl::make-subprocess-query-transport
                    :cli-path +fake-cli+ :arguments arguments :timeout timeout)))
    (claude-agent-sdk-cl:query prompt :transport transport :on-message on-message)))

(test subprocess-query-streams-ordered-transcript
  (let ((messages (run-subprocess-query '("query"))))
    (is (= 3 (length messages)))
    (is (typep (first messages) 'claude-agent-sdk-cl:system-message))
    (is (string= "init" (claude-agent-sdk-cl:system-message-subtype (first messages))))
    (is (typep (second messages) 'claude-agent-sdk-cl:assistant-message))
    (is (typep (third messages) 'claude-agent-sdk-cl:result-message))
    (is (string= "done" (claude-agent-sdk-cl:result-message-result (third messages))))))

(test subprocess-query-skips-control-records
  (let ((messages (run-subprocess-query '("query-control"))))
    (is (= 2 (length messages)))
    (is (typep (first messages) 'claude-agent-sdk-cl:assistant-message))
    (is (typep (second messages) 'claude-agent-sdk-cl:result-message))))

(test subprocess-query-preserves-exact-stdin
  ;; The fake echoes stdin byte count; proves no implicit trailing newline.
  (dolist (case '(("abc" . "3")
                  (#.(format nil "abc~%") . "4")
                  ("" . "0")
                  ("café" . "5")))                 ; é is 2 UTF-8 bytes
    (let* ((messages (run-subprocess-query '("query-stdin-length") :prompt (car case)))
           (result (first (last messages))))
      (is (typep result 'claude-agent-sdk-cl:result-message))
      (is (string= (cdr case) (claude-agent-sdk-cl:result-message-result result))
          "stdin ~S should echo byte count ~S" (car case) (cdr case)))))

(test subprocess-query-write-before-read-does-not-deadlock
  ;; Child writes 256 KiB stdout before reading stdin; parent supplies a large
  ;; prompt. Readers-before-stdin ordering must prevent the Phase 4.1 deadlock.
  (let* ((big-prompt (make-string 262144 :initial-element #\x))
         (messages (run-subprocess-query '("query-write-before-read")
                                         :prompt big-prompt)))
    (is (typep (first messages) 'claude-agent-sdk-cl:system-message))
    (is (typep (first (last messages)) 'claude-agent-sdk-cl:result-message))
    (is (find-if (lambda (m) (typep m 'claude-agent-sdk-cl:assistant-message)) messages))))

(test subprocess-query-drains-large-stderr-concurrently
  (let ((messages (run-subprocess-query '("query-large-stderr"))))
    (is (typep (first messages) 'claude-agent-sdk-cl:assistant-message))
    (is (typep (second messages) 'claude-agent-sdk-cl:result-message))))

(test subprocess-query-logs-raw-stdout-chunks
  ;; Phase 4.1 policy: transport diagnostics keep raw/unredacted streaming bytes.
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events))))
    (run-subprocess-query '("query"))
    (let ((chunks (loop for event in (nreverse events)
                        when (eq :cli.stdout.chunk (getf event :event))
                          collect (getf event :chunk))))
      (is-true chunks)
      (is (search "\"type\":\"system\"" (apply #'concatenate 'string chunks)))
      (is (search "\"type\":\"result\"" (apply #'concatenate 'string chunks))))))

(test subprocess-query-malformed-mid-stream-signals-cli-json-error
  (signals claude-agent-sdk-cl::cli-json-error
    (run-subprocess-query '("query-malformed"))))

(test subprocess-query-nonzero-exit-signals-process-error
  ;; EOF + nonzero exit must surface a process-error (exit 23, stderr text),
  ;; not a silent :eof close.
  (handler-case
      (progn (run-subprocess-query '("query-nonzero"))
             (fail "expected process-error"))
    (claude-agent-sdk-cl:process-error (condition)
      (is (= 23 (claude-agent-sdk-cl:process-error-exit-code condition)))
      (is (search "fake query failed" (claude-agent-sdk-cl:process-error-stderr condition))))))

(test subprocess-query-timeout-signals-process-error
  ;; `sleep` mode never emits output; a small timeout must bound the wait.
  (let ((start (get-internal-real-time)))
    (signals claude-agent-sdk-cl:process-error
      (run-subprocess-query '("sleep") :timeout 1))
    (let ((elapsed (/ (- (get-internal-real-time) start)
                      internal-time-units-per-second)))
      (is (< elapsed 4) "timeout should bound elapsed (~,2Fs)" elapsed))))

(defun query-descendant-pid-from-file (path)
  (loop repeat 50
        do (when (probe-file path)
             (with-open-file (stream path :direction :input)
               (let ((line (read-line stream nil nil)))
                 (when (and line (> (length line) 0))
                   (return (parse-integer line))))))
           (sleep 0.02)
        finally (error "Query fake descendant did not write PID file: ~A" path)))

(defun query-descendant-running-p (pid)
  ;; A zombie is terminated even if the container init has not reaped it yet.
  (let ((stat (format nil "/proc/~D/stat" pid)))
    (and (probe-file stat)
         (with-open-file (stream stat :direction :input)
           (let ((line (read-line stream nil "")))
             (not (search ") Z " line)))))))

(defun wait-for-query-descendant-exit (pid)
  (loop repeat 50
        unless (query-descendant-running-p pid) do (return t)
        do (sleep 0.02)
        finally (return nil)))

(defun kill-query-fixture-pid (pid)
  (when (and pid (query-descendant-running-p pid))
    (ignore-errors
      (uiop:run-program (list "/usr/bin/kill" "-KILL" (princ-to-string pid))
                        :ignore-error-status t))))

(test subprocess-query-cancellation-closes-cleanly
  (let* ((count 0)
         (messages (run-subprocess-query
                    '("query-cancel-wait")
                    :on-message (lambda (m) (declare (ignore m)) (incf count) :cancel))))
    (is (= 1 (length messages)))
    (is (= 1 count))
    (is (typep (first messages) 'claude-agent-sdk-cl:system-message))))

(test subprocess-query-cancellation-kills-descendant-tree
  (let* ((pid-file (format nil "/tmp/claude-sdk-query-descendant-~D.pid"
                           (random most-positive-fixnum)))
         (pid nil)
         (count 0))
    (unwind-protect
         (progn
           (let ((messages (run-subprocess-query
                            (list "query-cancel-descendant" pid-file)
                            :on-message (lambda (message)
                                          (declare (ignore message))
                                          (incf count)
                                          :cancel))))
             (is (= 1 (length messages)))
             (is (= 1 count)))
           (setf pid (query-descendant-pid-from-file pid-file))
           (is-true (wait-for-query-descendant-exit pid)))
      (kill-query-fixture-pid pid)
      (ignore-errors (delete-file pid-file)))))

(test query-default-provisions-stream-json-subprocess
  ;; No injected transport: query resolves the CLI and provisions a one-shot
  ;; stream-json subprocess with initialize + user JSONL input frames. The fake
  ;; CLI exits 64 if any expected flag/frame is absent.
  (let ((claude-agent-sdk-cl::*cli-path-resolver*
          (lambda () +fake-cli+)))
    (let ((messages (claude-agent-sdk-cl:query
                     "default prompt"
                     :options (claude-agent-sdk-cl:make-agent-options
                               :allowed-tools '("Bash" "Read")
                               :disallowed-tools '("Write")
                               :permission-mode "acceptEdits"
                               :continue-conversation t
                               :model "fake-model"
                               :system-prompt "system text"
                               :resume "session-1"))))
      (is (= 3 (length messages)))
      (is (typep (first messages) 'claude-agent-sdk-cl:system-message))
      (is (typep (second messages) 'claude-agent-sdk-cl:assistant-message))
      (is (typep (third messages) 'claude-agent-sdk-cl:result-message)))))

(test query-yields-system-then-assistant-then-result-in-order
  ;; Upstream emits system records before the assistant turn; they are public
  ;; messages, NOT internal :control traffic, and must be yielded in order.
  (let* ((transport (make-fake-transport
                     (concatenate 'string +system-line+ +nl+)
                     (concatenate 'string +assistant-line+ +nl+)
                     (concatenate 'string +result-line+ +nl+)))
         (messages (claude-agent-sdk-cl:query "hi" :transport transport)))
    (is (= 3 (length messages)))
    (is (typep (first messages) 'claude-agent-sdk-cl:system-message))
    (is (string= "init" (claude-agent-sdk-cl:system-message-subtype (first messages))))
    (is (typep (second messages) 'claude-agent-sdk-cl:assistant-message))
    (is (typep (third messages) 'claude-agent-sdk-cl:result-message))
    (is (equal '(:eof) (fake-query-close-reasons transport)))))

(test query-validates-prompt-and-transport-before-start
  ;; Non-string prompt: signals before any transport start.
  (let ((transport (make-fake-transport)))
    (signals claude-agent-sdk-cl::sdk-input-error
      (claude-agent-sdk-cl:query 42 :transport transport))
    (is (null (fake-query-started-p transport)))
    (is (null (fake-query-close-reasons transport))))
  ;; Missing transport now provisions the default subprocess path; make CLI
  ;; discovery deterministic and assert its normal not-found condition.
  (let ((claude-agent-sdk-cl::*cli-path-resolver* (lambda () nil)))
    (signals claude-agent-sdk-cl:cli-not-found-error
      (claude-agent-sdk-cl:query "hi"))))

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
