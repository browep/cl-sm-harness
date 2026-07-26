;;;; Register inbound CLI control handlers before CONNECT. Loading is side-effect-free.
(defpackage #:claude-agent-sdk-cl.harness-example.control-handlers
  (:use #:cl)
  (:export #:make-policy-client))
(in-package #:claude-agent-sdk-cl.harness-example.control-handlers)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun allow-read-only (request)
  (if (member (gethash "tool_name" request) '("Read" "Glob") :test #'string=)
      (claude-agent-sdk-cl:make-permission-result-allow)
      (claude-agent-sdk-cl:make-permission-result-deny
       :message "Harness permits only read-only tools." :interrupt nil)))

(defun json-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr do (setf (gethash key object) value))
    object))

(defun make-policy-client (&key cli-path)
  "Return an unconnected client with generic, hook, and SDK-MCP handlers."
  (let ((client (claude-agent-sdk-cl:make-claude-sdk-client
                 :cli-path cli-path
                 :control-handlers (list (cons "can_use_tool" #'allow-read-only)))))
    (claude-agent-sdk-cl:register-hook-callback
     client "before-tool"
     (lambda (input tool-use-id context)
       (declare (ignore input tool-use-id context))
       (claude-agent-sdk-cl:make-hook-callback-result
        :data (json-object "continue" t))))
    (claude-agent-sdk-cl:register-sdk-mcp-handler
     client "harness-tools"
     (lambda (message)
       ;; Preserve the request ID so the peer can correlate this JSON-RPC reply.
       (claude-agent-sdk-cl:make-mcp-control-result
        :response (json-object "jsonrpc" "2.0"
                               "id" (gethash "id" message)
                               "result" (json-object)))))
    client))
