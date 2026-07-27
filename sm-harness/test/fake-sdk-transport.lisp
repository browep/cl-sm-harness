(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(defclass harness-fake-transport (claude-agent-sdk-cl:client-transport)
  ((chunks :initarg :chunks :accessor fake-chunks)
   (writes :initform '() :accessor fake-writes)
   (closed-reason :initform nil :accessor fake-closed-reason)))

(defmethod claude-agent-sdk-cl:start-client-transport
    ((transport harness-fake-transport) options)
  (declare (ignore options))
  transport)

(defmethod claude-agent-sdk-cl:read-client-chunk ((transport harness-fake-transport))
  (pop (fake-chunks transport)))

(defmethod claude-agent-sdk-cl:write-client-input
    ((transport harness-fake-transport) input)
  (push input (fake-writes transport))
  t)

(defmethod claude-agent-sdk-cl:close-client-transport
    ((transport harness-fake-transport) &key reason)
  (setf (fake-closed-reason transport) reason)
  t)

(defparameter +nl+ (string #\Newline))
(defparameter +init-ok+
  "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-1\"}}")
(defparameter +assistant+
  "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hello from fixture\"}],\"model\":\"fixture\"}}")
(defparameter +result+
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"canon-42\",\"result\":\"done\"}")

(defun make-simple-turn-transport ()
  (make-instance 'harness-fake-transport
                 :chunks
                 (list (concatenate 'string +init-ok+ +nl+)
                       (concatenate 'string +assistant+ +nl+ +result+ +nl+))))
