(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(defclass harness-fake-transport (claude-agent-sdk-cl:client-transport)
  ((chunks :initarg :chunks :accessor fake-chunks)
   (writes :initform '() :accessor fake-writes)
   (start-error :initarg :start-error :initform nil :accessor fake-start-error)
   (read-error-after :initarg :read-error-after :initform nil :accessor fake-read-error-after)
   (read-count :initform 0 :accessor fake-read-count)
   (closed-reason :initform nil :accessor fake-closed-reason)))

(defmethod claude-agent-sdk-cl:start-client-transport
   ((transport harness-fake-transport) options)
  (declare (ignore options))
  (when (fake-start-error transport)
    (error "~A" (fake-start-error transport)))
  transport)

(defmethod claude-agent-sdk-cl:read-client-chunk ((transport harness-fake-transport))
  (let ((read-count (incf (fake-read-count transport))))
    (when (and (fake-read-error-after transport)
               (> read-count (fake-read-error-after transport)))
      (error "fixture read secret: transport failed"))
    (pop (fake-chunks transport))))

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

(defparameter +echo-tool-call+
  "{\"type\":\"control_request\",\"request_id\":\"tool-call-1\",\"request\":{\"subtype\":\"mcp_message\",\"server_name\":\"sm_harness\",\"message\":{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"echo_text\",\"arguments\":{\"text\":\"automatic\"}}}}}")

(defun make-simple-turn-transport ()
  (make-instance 'harness-fake-transport
                 :chunks
                 (list (concatenate 'string +init-ok+ +nl+)
                      (concatenate 'string +assistant+ +nl+ +result+ +nl+))))

(defun make-catalog-tool-turn-transport ()
  "Script a real session-start MCP tools/call request through the SDK client."
  (make-instance 'harness-fake-transport
                 :chunks
                 (list (concatenate 'string +init-ok+ +nl+)
                       (concatenate 'string +echo-tool-call+ +nl+
                                    +assistant+ +nl+ +result+ +nl+))))

(defun echoed-mcp-result-text (wire)
  (let* ((outer (yason:parse wire))
         (response (gethash "response" outer))
         (payload (gethash "response" response))
         (mcp-response (gethash "mcp_response" payload))
         (result (gethash "result" mcp-response))
         (content (gethash "content" result)))
    (gethash "text" (first content))))
