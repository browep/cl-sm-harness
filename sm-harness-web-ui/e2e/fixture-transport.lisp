(in-package #:sm-harness-web-ui)

;;;; Test/E2E-only deterministic SDK transport.  Never loaded by production UI.
(defclass e2e-fake-transport (claude-agent-sdk-cl:client-transport)
  ((chunks :initarg :chunks :accessor e2e-chunks)
   (writes :initform '() :accessor e2e-writes)))

(defmethod claude-agent-sdk-cl:start-client-transport ((tport e2e-fake-transport) options)
  (declare (ignore options))
  tport)
(defmethod claude-agent-sdk-cl:read-client-chunk ((tport e2e-fake-transport))
  (pop (e2e-chunks tport)))
(defmethod claude-agent-sdk-cl:write-client-input ((tport e2e-fake-transport) input)
  (push input (e2e-writes tport))
  t)
(defmethod claude-agent-sdk-cl:close-client-transport ((tport e2e-fake-transport) &key reason)
  (declare (ignore reason))
  t)

(defun %e2e-transport-factory (options)
  (declare (ignore options))
  (let ((nl (string #\Newline)))
    (make-instance 'e2e-fake-transport
                   :chunks
                   (list
                    (concatenate 'string
                     "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-1\"}}"
                     nl)
                    (concatenate 'string
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"e2e hello\"}],\"model\":\"fixture\"}}"
                     nl
                     "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"e2e-canon\",\"result\":\"ok\"}"
                     nl)))))
