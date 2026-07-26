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
