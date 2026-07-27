;;;; Register inbound CLI control handlers before CONNECT. Loading is side-effect-free.
;;;;
;;;; Prefer session-start SDK MCP catalogs (example 10) for typed in-process tools.
;;;; Use register-sdk-mcp-handler only for low-level JSON-RPC control replies when
;;;; the harness does not own a session catalog.
(defpackage #:claude-agent-sdk-cl.harness-example.control-handlers
  (:use #:cl)
  (:export #:make-policy-client
           #:make-catalog-policy-client))
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
  "Return an unconnected client with generic permission/hook handlers and a
low-level SDK MCP control handler for an ad-hoc server name.

Do not combine this low-level mcp_message path with :sdk-mcp-servers; session
catalogs own their generated server handlers."
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

(defun make-catalog-policy-client (&key cli-path)
  "Return an unconnected client that uses a session-start SDK MCP catalog plus
permission policy. Catalog tools are advertised via metadata-only --mcp-config."
  (let* ((tool (claude-agent-sdk-cl:make-sdk-tool
                :name "lookup_order"
                :description "Look up one order by ID."
                :input-schema (json-object
                               "type" "object"
                               "properties" (json-object
                                             "order_id" (json-object "type" "string")))
                :handler (lambda (arguments context)
                           (declare (ignore context))
                           (claude-agent-sdk-cl:make-sdk-tool-result
                            :text (format nil "order ~A"
                                          (gethash "order_id" arguments))))))
         (server (claude-agent-sdk-cl:make-sdk-mcp-server
                  :name "orders" :tools (list tool)))
         (options (claude-agent-sdk-cl:make-agent-options
                   :builtin-tools :none
                   :sdk-mcp-servers (list server)
                   :strict-mcp-config t
                   :allowed-tools '("mcp__orders__lookup_order"))))
    (claude-agent-sdk-cl:make-claude-sdk-client
     :cli-path cli-path
     :options options
     :control-handlers
     (list (cons "can_use_tool"
                 (lambda (request)
                   (let ((name (gethash "tool_name" request)))
                     (if (string= name "mcp__orders__lookup_order")
                         (claude-agent-sdk-cl:make-permission-result-allow)
                         (claude-agent-sdk-cl:make-permission-result-deny
                          :message (format nil "Harness denies ~A" name)
                          :interrupt nil)))))))))
