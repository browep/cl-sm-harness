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

(defparameter +echo-assistant+
  "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"e2e hello\"}],\"model\":\"fixture\"}}")
(defparameter +echo-result+
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"canon-42\",\"result\":\"e2e hello\"}")

(defun make-duplicate-response-turn-transport ()
  "The terminal result's text mirrors the assistant text verbatim, as a real
Claude Code CLI turn commonly does."
  (make-instance 'harness-fake-transport
                 :chunks
                 (list (concatenate 'string +init-ok+ +nl+)
                      (concatenate 'string +echo-assistant+ +nl+ +echo-result+ +nl+))))

(defun make-catalog-tool-turn-transport ()
  "Script a real session-start MCP tools/call request through the SDK client."
  (make-instance 'harness-fake-transport
                 :chunks
                 (list (concatenate 'string +init-ok+ +nl+)
                       (concatenate 'string +echo-tool-call+ +nl+
                                    +assistant+ +nl+ +result+ +nl+))))

(defparameter +conversational-tool-use+
  "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_99\",\"name\":\"Bash\",\"input\":{\"command\":\"echo hi\"}}],\"model\":\"fixture\"}}")
(defparameter +conversational-tool-result+
  ;; The realistic wire shape: "content" is an MCP content-block array (what
  ;; MAKE-SDK-TOOL-RESULT's :TEXT produces), not a bare string.
  "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_99\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"is_error\":false}]}}")
(defparameter +conversational-final-text+
  "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"the command printed hi\"}],\"model\":\"fixture\"}}")
(defparameter +conversational-result+
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"canon-42\",\"result\":\"the command printed hi\"}")

(defun make-conversational-tool-round-trip-transport ()
  "Script a real built-in-tool round trip through the conversational message
stream: an assistant tool_use block, then the CLI's type=\"user\" tool_result
message, then a final assistant text and result. Distinct from
make-catalog-tool-turn-transport, which scripts a session-start SDK MCP
control-plane call instead."
  (make-instance 'harness-fake-transport
                 :chunks
                 (list (concatenate 'string +init-ok+ +nl+)
                       (concatenate 'string +conversational-tool-use+ +nl+
                                    +conversational-tool-result+ +nl+
                                    +conversational-final-text+ +nl+
                                    +conversational-result+ +nl+))))

(defun make-catalog-tool-call-json (&key (request-id "tool-call-1") name arguments)
  "Build a control_request tools/call wire message invoking NAME with
ARGUMENTS (a hash table), for testing any catalog tool by its real name --
not just the fixed echo_text call scripted by +ECHO-TOOL-CALL+."
  (with-output-to-string (s)
    (yason:encode
     (let ((outer (make-hash-table :test #'equal)))
       (setf (gethash "type" outer) "control_request"
             (gethash "request_id" outer) request-id
             (gethash "request" outer)
             (let ((req (make-hash-table :test #'equal)))
               (setf (gethash "subtype" req) "mcp_message"
                     (gethash "server_name" req) "sm_harness"
                     (gethash "message" req)
                     (let ((msg (make-hash-table :test #'equal)))
                       (setf (gethash "jsonrpc" msg) "2.0"
                             (gethash "id" msg) 7
                             (gethash "method" msg) "tools/call"
                             (gethash "params" msg)
                             (let ((params (make-hash-table :test #'equal)))
                               (setf (gethash "name" params) name
                                     (gethash "arguments" params) arguments)
                               params))
                       msg))
               req))
       outer)
     s)))

(defun make-named-catalog-tool-turn-transport (tool-call-json)
  (make-instance 'harness-fake-transport
                 :chunks
                 (list (concatenate 'string +init-ok+ +nl+)
                       (concatenate 'string tool-call-json +nl+
                                    +assistant+ +nl+ +result+ +nl+))))

(defun wait-for-mcp-response (transport)
  "Wait for and return the transport write containing an mcp_response, not
just the Nth write: an earlier, unrelated write (e.g. a handshake message)
can satisfy a bare write-count threshold before the actual tool response
exists, making (FIRST (FAKE-WRITES TRANSPORT)) read the wrong message."
  (wait-until (lambda () (find-if (lambda (line) (search "mcp_response" line))
                                  (fake-writes transport))))
  (find-if (lambda (line) (search "mcp_response" line)) (fake-writes transport)))

(defun %reload-cycle-messages (id &key (tool-name "reload_harness") (is-error nil))
  "One conversational tool_use/tool_result round-trip cycle as a single
combined chunk: an assistant tool_use block, the CLI's type=\"user\"
tool_result message, a final assistant text, and the terminal result."
  (concatenate
   'string
   (format nil "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":~S,\"name\":~S,\"input\":{}}],\"model\":\"fixture\"}}"
           id tool-name)
   +nl+
   (format nil "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":~S,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"is_error\":~A}]}}"
           id (if is-error "true" "false"))
   +nl+
   "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"model\":\"fixture\"}}"
   +nl+
   "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"canon-42\",\"result\":\"done\"}"
   +nl+))

(defun make-repeated-tool-turn-transport (specs)
  "SPECS is a list of (:tool-name NAME :is-error BOOL) plists, one per turn
cycle, all queued up front on one transport/client -- for testing a chain
of turns each auto-submitted in response to the previous one, without a
human message in between."
  (make-instance 'harness-fake-transport
                 :chunks
                 (list* (concatenate 'string +init-ok+ +nl+)
                        (loop for i from 1
                              for spec in specs
                              collect (%reload-cycle-messages
                                       (format nil "toolu_~D" i)
                                       :tool-name (getf spec :tool-name "reload_harness")
                                       :is-error (getf spec :is-error))))))

(defun echoed-mcp-result-text (wire)
  (let* ((outer (yason:parse wire))
         (response (gethash "response" outer))
         (payload (gethash "response" response))
         (mcp-response (gethash "mcp_response" payload))
         (result (gethash "result" mcp-response))
         (content (gethash "content" result)))
    (gethash "text" (first content))))
