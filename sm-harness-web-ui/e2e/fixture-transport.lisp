(in-package #:sm-harness-web-ui)

;;;; Test/E2E-only deterministic SDK transport.  Never loaded by production UI.
(defclass e2e-fake-transport (claude-agent-sdk-cl:client-transport)
  ((chunks :initarg :chunks :accessor e2e-chunks)
   (writes :initform '() :accessor e2e-writes)
   (read-count :initform 0 :accessor e2e-read-count)
   (mcp-response-count :initform 0 :accessor e2e-mcp-response-count)
   (stop-mode-p :initform nil :accessor e2e-stop-mode-p)
   (stop-lock :initform (sb-thread:make-mutex :name "e2e-stop") :reader e2e-stop-lock)
   (stop-cv :initform (sb-thread:make-waitqueue :name "e2e-stop") :reader e2e-stop-cv)
   (start-error :initarg :start-error :initform nil :accessor e2e-start-error)
   (read-error-after :initarg :read-error-after :initform nil :accessor e2e-read-error-after)
   (fail-writes-p :initarg :fail-writes-p :initform nil :accessor e2e-fail-writes-p)
   ;; Lets browser E2E observe the real busy/responding transition without
   ;; arbitrary test-side sleeps.
   (delay-before-second-read-seconds :initarg :delay-before-second-read-seconds
                                     :initform 1
                                     :accessor e2e-delay-before-second-read-seconds)))

(defparameter *e2e-retry-failure-available* t)
(defparameter *e2e-connect-failure-available* t)
(defparameter *e2e-read-recovery-client-count* 0)
(defparameter *e2e-malformed-event-available* t)

(defmethod claude-agent-sdk-cl:start-client-transport ((tport e2e-fake-transport) options)
  (declare (ignore options))
  (when (e2e-start-error tport)
    (error "~A" (e2e-start-error tport)))
  tport)
(defmethod claude-agent-sdk-cl:read-client-chunk ((tport e2e-fake-transport))
  (let ((read-count (incf (e2e-read-count tport))))
    (when (= read-count 2)
      (sb-thread:with-mutex ((e2e-stop-lock tport))
        (loop while (e2e-stop-mode-p tport) do
          (sb-thread:condition-wait (e2e-stop-cv tport) (e2e-stop-lock tport))))
      (sleep (e2e-delay-before-second-read-seconds tport)))
    (when (and (e2e-read-error-after tport)
               (> read-count (e2e-read-error-after tport)))
      (error "fixture read secret: transport failed"))
    (pop (e2e-chunks tport))))

(defun %e2e-stop-terminal ()
  (let ((nl (string #\Newline)))
    (concatenate 'string
                 "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-2\"}}" nl
                 "{\"type\":\"result\",\"subtype\":\"interrupted\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"e2e-canon\",\"result\":\"stopped by e2e\"}" nl)))

(defun %e2e-mcp-result-text (input)
  "Read the generated result from an SDK MCP control response."
  (handler-case
      (let* ((outer (yason:parse input))
             (response (gethash "response" outer))
             (payload (gethash "response" response))
             (mcp-response (gethash "mcp_response" payload))
             (result (gethash "result" mcp-response))
             (content (gethash "content" result)))
        (gethash "text" (first content)))
    (error () nil)))

(defun %e2e-tool-followup (result-text)
  "Return the post-handler CLI events, derived from the real handler response."
  (let ((nl (string #\Newline)))
    (concatenate 'string
                 ;; The real CLI wraps a tool result in a type="user" message
                 ;; (#58); an assistant-wrapped tool_result is silently
                 ;; dropped by the adapter and no tool-completed ever renders.
                 (format nil "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"e2e-tool-1\",\"content\":[{\"type\":\"text\",\"text\":\"~A\"}],\"is_error\":false}]}}" result-text)
                 nl
                 "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"custom tool lifecycle complete\"}],\"model\":\"fixture\"}}"
                 nl
                 "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"e2e-canon\",\"result\":\"ok\"}"
                 nl)))

(defmethod claude-agent-sdk-cl:write-client-input ((tport e2e-fake-transport) input)
  (push input (e2e-writes tport))
  (when (search "stop e2e" input)
    (setf (e2e-stop-mode-p tport) t))
  (when (and (e2e-stop-mode-p tport)
             (search "\"subtype\":\"interrupt\"" input))
    (sb-thread:with-mutex ((e2e-stop-lock tport))
      (setf (e2e-chunks tport) (list (%e2e-stop-terminal))
            (e2e-stop-mode-p tport) nil)
      (sb-thread:condition-notify (e2e-stop-cv tport))))
  (when (and *e2e-retry-failure-available*
             (e2e-fail-writes-p tport)
             (search "retry e2e" input))
    (setf *e2e-retry-failure-available* nil
          (e2e-fail-writes-p tport) nil)
    (error "fixture protocol secret: send failed"))
  (when (and (%e2e-tool-handler-failure-p)
             (search "e2e-failing-tool-call" input))
    (unless (search "-32603" input)
      (error "fixture expected a nested JSON-RPC internal error"))
    (unless (= 0 (e2e-mcp-response-count tport))
      (error "fixture failing tool handler response was not exactly once"))
    (incf (e2e-mcp-response-count tport))
    (setf (e2e-chunks tport)
          (append (e2e-chunks tport)
                  (list (concatenate 'string
                         "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"e2e-tool-fail-1\",\"content\":[{\"type\":\"text\",\"text\":\"Tool failed\"}],\"is_error\":true}]}}\n"
                         "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"e2e-canon\",\"result\":\"tool handler failure handled\"}\n")))))
  (let ((result-text (%e2e-mcp-result-text input)))
    (when result-text
      ;; A real session-start MCP handler produced this response.  Do not emit
      ;; a lifecycle result if that correlation is absent or unexpected.
      (unless (string= result-text "echo: browser-actual")
        (error "fixture MCP tool result did not match the catalog handler"))
      (unless (= 1 (incf (e2e-mcp-response-count tport)))
        (error "fixture catalog tool handler ran more than once"))
      (setf (e2e-chunks tport)
            (append (e2e-chunks tport) (list (%e2e-tool-followup result-text))))))
  t)
(defmethod claude-agent-sdk-cl:close-client-transport ((tport e2e-fake-transport) &key reason)
  (declare (ignore reason))
  t)

(defun %e2e-connect-recovery-p ()
  (string= (or (uiop:getenv "E2E_SCENARIO") "") "connect-recovery"))

(defun %e2e-init-chunk ()
  (concatenate 'string
               "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-1\"}}"
               (string #\Newline)))

(defun %e2e-connect-recovery-transport ()
  (if *e2e-connect-failure-available*
      (progn
        (setf *e2e-connect-failure-available* nil)
        (make-instance 'e2e-fake-transport
                       :start-error "fixture connect secret: unavailable"))
      (let ((nl (string #\Newline)))
        (make-instance 'e2e-fake-transport
                       :chunks
                       (list (%e2e-init-chunk)
                             (concatenate 'string
                                          "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"connect retry complete\"}],\"model\":\"fixture\"}}"
                                          nl
                                          "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"e2e-canon\",\"result\":\"connect retry done\"}"
                                          nl))))))

(defun %e2e-read-recovery-p ()
  (string= (or (uiop:getenv "E2E_SCENARIO") "") "read-recovery"))

(defun %e2e-read-result-chunk (text)
  (let ((nl (string #\Newline)))
    (concatenate 'string
                 (format nil "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"~A\"}],\"model\":\"fixture\"}}" text)
                 nl
                 "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"e2e-canon\",\"result\":\"done\"}"
                 nl)))

(defun %e2e-read-recovery-transport (options)
  (incf *e2e-read-recovery-client-count*)
  (let ((n *e2e-read-recovery-client-count*))
    (when (and (> n 1)
               (not (string= "e2e-canon" (claude-agent-sdk-cl:agent-options-resume options))))
      (error "fixture replacement client did not receive canonical resume"))
    (case n
      (1 (make-instance 'e2e-fake-transport
                        :chunks (list (%e2e-init-chunk)
                                      (%e2e-read-result-chunk "read first complete"))))
      (2 (make-instance 'e2e-fake-transport
                        :chunks (list (%e2e-init-chunk))
                        :read-error-after 1))
      (otherwise (make-instance 'e2e-fake-transport
                                :chunks (list (%e2e-init-chunk)
                                              (%e2e-read-result-chunk "read retry complete")))))))

(defun %e2e-tool-handler-failure-p ()
  (string= (or (uiop:getenv "E2E_SCENARIO") "") "tool-handler-failure"))

(defun e2e-fixture-catalog ()
  (let ((catalog (sm-harness:default-tool-catalog)))
    (when (%e2e-tool-handler-failure-p)
      (setf (sm-harness::tool-definition-handler
             (first (sm-harness::tool-server-definition-tools
                     (first (sm-harness::tool-catalog-servers catalog)))))
            (lambda (arguments context)
              (declare (ignore arguments context))
              (error "fixture handler secret"))))
    catalog))

(defun %e2e-tool-handler-failure-transport ()
  (let ((nl (string #\Newline)))
    (make-instance 'e2e-fake-transport
                   :chunks
                   (list (%e2e-init-chunk)
                         (concatenate 'string
                          "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"e2e-tool-fail-1\",\"name\":\"mcp__sm_harness__echo_text\",\"input\":{\"text\":\"fail\"}}],\"model\":\"fixture\"}}" nl
                          "{\"type\":\"control_request\",\"request_id\":\"e2e-failing-tool-call\",\"request\":{\"subtype\":\"mcp_message\",\"server_name\":\"sm_harness\",\"message\":{\"jsonrpc\":\"2.0\",\"id\":45,\"method\":\"tools/call\",\"params\":{\"name\":\"echo_text\",\"arguments\":{\"text\":\"fail\"}}}}}" nl)))))

(defun %e2e-malformed-event-p ()
  (string= (or (uiop:getenv "E2E_SCENARIO") "") "malformed-event-recovery"))

(defun %e2e-malformed-event-transport (options)
  (when (and (not *e2e-malformed-event-available*)
             (claude-agent-sdk-cl:agent-options-resume options))
    (error "fixture malformed-event retry unexpectedly resumed"))
  (if *e2e-malformed-event-available*
      (progn
        (setf *e2e-malformed-event-available* nil)
        (make-instance 'e2e-fake-transport
                       :chunks (list (%e2e-init-chunk)
                                     "{fixture malformed secret: invalid JSON}\n")))
      (%e2e-default-transport)))

(defun %e2e-default-transport ()
  (let ((nl (string #\Newline))
        (long-token (concatenate 'string "unbroken-" (make-string 512 :initial-element #\x))))
    (make-instance 'e2e-fake-transport
                   :fail-writes-p t
                   :chunks
                   (list
                    (concatenate 'string
                     "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-1\"}}"
                     nl)
                    (concatenate 'string
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"e2e hello\"}],\"model\":\"fixture\"}}"
                     nl
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"stream two: Unicode ✓\\nsecond line\"}],\"model\":\"fixture\"}}"
                     nl
                     (format nil "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"~A\"}],\"model\":\"fixture\"}}" long-token)
                     nl
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"<script>e2e-xss</script> **not bold** [not-link](javascript:alert(1))\"}],\"model\":\"fixture\"}}"
                     nl
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"e2e-tool-1\",\"name\":\"mcp__sm_harness__echo_text\",\"input\":{\"text\":\"browser-actual\"}}],\"model\":\"fixture\"}}"
                     nl
                     "{\"type\":\"control_request\",\"request_id\":\"e2e-tool-call\",\"request\":{\"subtype\":\"mcp_message\",\"server_name\":\"sm_harness\",\"message\":{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"echo_text\",\"arguments\":{\"text\":\"browser-actual\"}}}}}"
                     nl)))))

(defun %e2e-transport-factory (options)
  (cond
    ((%e2e-connect-recovery-p) (%e2e-connect-recovery-transport))
    ((%e2e-read-recovery-p) (%e2e-read-recovery-transport options))
    ((%e2e-tool-handler-failure-p) (%e2e-tool-handler-failure-transport))
    ((%e2e-malformed-event-p) (%e2e-malformed-event-transport options))
    (t (%e2e-default-transport))))
