(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/client :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/client)

;;;; Persistent fake transport for lifecycle-only client tests. The first Phase 6
;;;; slice intentionally has no subprocess dependency.

(defclass fake-client-transport (claude-agent-sdk-cl:client-transport)
  ((start-count :initform 0 :accessor fake-client-start-count)
   (close-reasons :initform '() :accessor fake-client-close-reasons)
   (writes :initform '() :accessor fake-client-writes)
   (chunks :initarg :chunks :initform '() :accessor fake-client-chunks)))

(defclass overlap-detecting-client-transport (fake-client-transport)
  ((active-writes :initform 0 :accessor overlap-active-writes)
   (max-active-writes :initform 0 :accessor overlap-max-active-writes)
   (counter-lock :initform (sb-thread:make-mutex :name "test-write-counter")
                 :reader overlap-counter-lock)))

(defmethod claude-agent-sdk-cl:write-client-input ((transport overlap-detecting-client-transport) input)
  ;; Holding ACTIVE-WRITES across SLEEP makes a missing client write mutex fail
  ;; reliably when a second sender enters the generic write concurrently.
  (sb-thread:with-mutex ((overlap-counter-lock transport))
    (incf (overlap-active-writes transport))
    (setf (overlap-max-active-writes transport)
          (max (overlap-max-active-writes transport)
               (overlap-active-writes transport))))
  (unwind-protect
       (progn (sleep 0.05)
              (call-next-method))
    (sb-thread:with-mutex ((overlap-counter-lock transport))
      (decf (overlap-active-writes transport)))))

(defparameter +client-nl+ (string #\Newline))
(defparameter +initialize-response+
  "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-1\"}}")
(defparameter +turn-one-assistant+
  "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"turn one\"}]}}")
(defparameter +turn-two-assistant+
  "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"turn two\"}]}}")
(defparameter +client-result+
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"s\",\"result\":\"done\"}")

(defmethod claude-agent-sdk-cl:start-client-transport ((transport fake-client-transport) options)
  (declare (ignore options))
  (incf (fake-client-start-count transport))
  ;; Lifecycle-only tests do not care about handshake traffic; provide the
  ;; smallest valid response unless a transcript was supplied explicitly.
  (when (null (fake-client-chunks transport))
    (setf (fake-client-chunks transport)
          (list (concatenate 'string +initialize-response+ +client-nl+))))
  transport)

(defmethod claude-agent-sdk-cl:write-client-input ((transport fake-client-transport) input)
  (push input (fake-client-writes transport))
  t)

(defmethod claude-agent-sdk-cl:read-client-chunk ((transport fake-client-transport))
  (pop (fake-client-chunks transport)))

(defmethod claude-agent-sdk-cl:close-client-transport ((transport fake-client-transport) &key reason)
  (push reason (fake-client-close-reasons transport))
  t)

(defparameter +interrupt-response+
  "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-2\"}}")

(defparameter +unknown-event+
  "{\"type\":\"future_cli_event\",\"payload\":\"ignored but logged\"}")

(test client-default-provisions-stream-json-transport
  (let* ((options (claude-agent-sdk-cl:make-agent-options
                   :model "fake-model" :allowed-tools '("Read")))
         (client (claude-agent-sdk-cl:make-claude-sdk-client
                  :options options :cli-path "/workspace/test/fake-claude.sh" :timeout 1.5))
         (transport (claude-agent-sdk-cl::client-transport-instance client))
         (arguments (claude-agent-sdk-cl::sct-arguments transport)))
    (is (typep transport 'claude-agent-sdk-cl::subprocess-client-transport))
    (is (string= "/workspace/test/fake-claude.sh" (claude-agent-sdk-cl::sct-cli-path transport)))
    (is (equal '("--output-format" "stream-json" "--verbose") (subseq arguments 0 3)))
    (is (member "--input-format" arguments :test #'string=))
    (is (member "stream-json" arguments :test #'string=))
    (is (member "fake-model" arguments :test #'string=))
    (is (member "Read" arguments :test #'string=)))
  (dolist (bad '(0 -1 "soon"))
    (signals claude-agent-sdk-cl:sdk-input-error
      (claude-agent-sdk-cl:make-claude-sdk-client :timeout bad))))

(test client-default-transport-runs-persistent-subprocess
  (let ((client (claude-agent-sdk-cl:make-claude-sdk-client
                 :cli-path "/workspace/test/fake-client-cli.sh")))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (claude-agent-sdk-cl:send client "public default")
           (let ((response (claude-agent-sdk-cl:receive-response client)))
             (is (= 2 (length response)))
             (is (string= "turn 1 done"
                          (claude-agent-sdk-cl:result-message-result (second response)))))
           (is (eq :connected (claude-agent-sdk-cl:client-state client))))
      (claude-agent-sdk-cl:disconnect client))))

(test client-serializes-concurrent-writes
  (let* ((transport (make-instance 'overlap-detecting-client-transport))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (let ((first (sb-thread:make-thread
                         (lambda () (claude-agent-sdk-cl:send client "first"))))
                 (second nil))
             ;; FIRST is deliberately inside WRITE-CLIENT-INPUT before SECOND
             ;; starts, so this is deterministic even on a lightly loaded VM.
             (sleep 0.01)
             (setf second (sb-thread:make-thread
                           (lambda () (claude-agent-sdk-cl:send client "second"))))
             (sb-thread:join-thread first)
             (sb-thread:join-thread second))
           (is (= 1 (overlap-max-active-writes transport))))
      (claude-agent-sdk-cl:disconnect client))))

(test subprocess-client-retains-stdin-across-two-turns
  (let* ((transport (claude-agent-sdk-cl::make-subprocess-client-transport
                     :cli-path "/workspace/test/fake-claude.sh" :arguments '("client")))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (claude-agent-sdk-cl:send client "first")
           (let ((response (claude-agent-sdk-cl:receive-response client)))
             (is (= 2 (length response)))
             (is (search "turn 1 done"
                         (claude-agent-sdk-cl:result-message-result (second response)))))
           (claude-agent-sdk-cl:send client "second")
           (let ((response (claude-agent-sdk-cl:receive-response client)))
             (is (= 2 (length response)))
             (is (search "turn 2 done"
                         (claude-agent-sdk-cl:result-message-result (second response)))))
           (is (eq :connected (claude-agent-sdk-cl:client-state client))))
      (claude-agent-sdk-cl:disconnect client))))

(test subprocess-client-interrupt-is-correlated-and-session-remains-usable
  (let* ((transport (claude-agent-sdk-cl::make-subprocess-client-transport
                     :cli-path "/workspace/test/fake-claude.sh" :arguments '("client")))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (claude-agent-sdk-cl:interrupt client)
           ;; The fake responds to the nested request id and retains stdin; a
           ;; following user turn proves interrupt did not terminate the child.
           (claude-agent-sdk-cl:send client "after interrupt")
           (let ((response (claude-agent-sdk-cl:receive-response client)))
             (is (= 2 (length response)))
             (is (search "turn 1 done"
                         (claude-agent-sdk-cl:result-message-result (second response)))))
           (is (eq :connected (claude-agent-sdk-cl:client-state client))))
      (claude-agent-sdk-cl:disconnect client))))

(test subprocess-client-drains-large-stderr-during-handshake
  (let* ((transport (claude-agent-sdk-cl::make-subprocess-client-transport
                     :cli-path "/workspace/test/fake-claude.sh" :arguments '("client-large-stderr")))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (claude-agent-sdk-cl:send client "after stderr")
           (let ((response (claude-agent-sdk-cl:receive-response client)))
             (is (= 2 (length response)))
             (is (string= "done"
                          (claude-agent-sdk-cl:result-message-result (second response)))))
           (is (eq :connected (claude-agent-sdk-cl:client-state client))))
      (claude-agent-sdk-cl:disconnect client))))

(test subprocess-client-eof-closes-session-and-rejects-later-writes
  (let* ((transport (claude-agent-sdk-cl::make-subprocess-client-transport
                     :cli-path "/workspace/test/fake-claude.sh" :arguments '("client-eof")))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (claude-agent-sdk-cl:connect client)
    (is (null (claude-agent-sdk-cl:receive-message client)))
    (is (eq :closed (claude-agent-sdk-cl:client-state client)))
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:send client "after eof"))
    (claude-agent-sdk-cl:disconnect client)))

(test subprocess-client-nonzero-exit-closes-connect-and-preserves-typed-error
  (let* ((transport (claude-agent-sdk-cl::make-subprocess-client-transport
                     :cli-path "/workspace/test/fake-claude.sh" :arguments '("client-nonzero")))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (signals claude-agent-sdk-cl:process-error
      (claude-agent-sdk-cl:connect client))
    (is (eq :closed (claude-agent-sdk-cl:client-state client)))
    (claude-agent-sdk-cl:disconnect client)))

(test client-lifecycle-states-and-idempotent-disconnect
  (let* ((transport (make-instance 'fake-client-transport))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (is (eq :new (claude-agent-sdk-cl:client-state client)))
    (claude-agent-sdk-cl:connect client)
    (is (eq :connected (claude-agent-sdk-cl:client-state client)))
    (is (= 1 (fake-client-start-count transport)))
    ;; Disconnect is safe to call repeatedly, but a terminal client never
    ;; reconnects in this slice.
    (claude-agent-sdk-cl:disconnect client)
    (claude-agent-sdk-cl:disconnect client)
    (is (eq :closed (claude-agent-sdk-cl:client-state client)))
    (is (equal '(:disconnect) (fake-client-close-reasons transport)))))

(test client-invalid-lifecycle-calls-signal-typed-condition
  (let* ((transport (make-instance 'fake-client-transport))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:send client "before connect"))
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:receive-message client))
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:interrupt client))
    (claude-agent-sdk-cl:connect client)
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:connect client))
    (claude-agent-sdk-cl:disconnect client)
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:connect client))))

(test client-send-delegates-only-while-connected
  (let* ((transport (make-instance 'fake-client-transport))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (claude-agent-sdk-cl:connect client)
    (claude-agent-sdk-cl:send client "first turn")
    (claude-agent-sdk-cl:send client "second turn")
    (let ((writes (reverse (fake-client-writes transport))))
      (is (= 3 (length writes)))
      ;; First write is initialize; later writes retain turn order in user JSON.
      (is (search "\"content\":\"first turn\"" (second writes)))
      (is (search "\"content\":\"second turn\"" (third writes))))
    (claude-agent-sdk-cl:disconnect client)))

(test client-connect-handshake-and-two-turn-response-boundaries
  ;; A result finishes one response but must leave the session connected for the
  ;; next send/receive pair. Initialize correlation is internal, never yielded.
  (let* ((transport
           (make-instance 'fake-client-transport
                          :chunks (list
                                   (concatenate 'string +initialize-response+ +client-nl+)
                                   (concatenate 'string +turn-one-assistant+ +client-nl+
                                                +client-result+ +client-nl+)
                                   (concatenate 'string +turn-two-assistant+ +client-nl+
                                                +client-result+ +client-nl+))))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (claude-agent-sdk-cl:connect client)
    (is (search "\"type\":\"control_request\"" (first (fake-client-writes transport))))
    (is (search "\"subtype\":\"initialize\"" (first (fake-client-writes transport))))
    (claude-agent-sdk-cl:send client "first prompt")
    (let ((first-response (claude-agent-sdk-cl:receive-response client)))
      (is (= 2 (length first-response)))
      (is (typep (first first-response) 'claude-agent-sdk-cl:assistant-message))
      (is (typep (second first-response) 'claude-agent-sdk-cl:result-message)))
    (is (eq :connected (claude-agent-sdk-cl:client-state client)))
    (claude-agent-sdk-cl:send client "second prompt")
    (let ((second-response (claude-agent-sdk-cl:receive-response client)))
      (is (= 2 (length second-response)))
      (is (typep (first second-response) 'claude-agent-sdk-cl:assistant-message))
      (is (typep (second second-response) 'claude-agent-sdk-cl:result-message)))
    (let ((writes (reverse (fake-client-writes transport))))
      (is (= 3 (length writes)))
      (is (search "\"content\":\"first prompt\"" (second writes)))
      (is (search "\"content\":\"second prompt\"" (third writes))))
    (claude-agent-sdk-cl:disconnect client)))

(test client-interrupt-uses-correlated-control-request
  (let* ((transport
           (make-instance 'fake-client-transport
                          :chunks (list
                                   (concatenate 'string +initialize-response+ +client-nl+)
                                   (concatenate 'string +interrupt-response+ +client-nl+))))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (claude-agent-sdk-cl:connect client)
    (claude-agent-sdk-cl:interrupt client)
    (let ((interrupt-wire (second (reverse (fake-client-writes transport)))))
      (is (search "\"type\":\"control_request\"" interrupt-wire))
      (is (search "\"request_id\":\"request-2\"" interrupt-wire))
      (is (search "\"subtype\":\"interrupt\"" interrupt-wire)))
    (is (eq :connected (claude-agent-sdk-cl:client-state client)))
    (claude-agent-sdk-cl:disconnect client)))

(test client-skips-unknown-events-without-ending-the-turn
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events)))
         (transport
           (make-instance 'fake-client-transport
                          :chunks (list
                                   (concatenate 'string +initialize-response+ +client-nl+)
                                   (concatenate 'string +unknown-event+ +client-nl+
                                                +turn-one-assistant+ +client-nl+
                                                +client-result+ +client-nl+))))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (claude-agent-sdk-cl:connect client)
    (let ((response (claude-agent-sdk-cl:receive-response client)))
      (is (= 2 (length response)))
      (is (typep (first response) 'claude-agent-sdk-cl:assistant-message))
      (is (typep (second response) 'claude-agent-sdk-cl:result-message)))
    (is (eq :connected (claude-agent-sdk-cl:client-state client)))
    (is (find :client.unknown-event events :key (lambda (event) (getf event :event))))
    (claude-agent-sdk-cl:disconnect client)))
