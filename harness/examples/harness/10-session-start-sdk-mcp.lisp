;;;; Session-start in-process SDK MCP catalog. Loading is side-effect-free:
;;;; it constructs validated tools/options and does not launch Claude.
(defpackage #:claude-agent-sdk-cl.harness-example.sdk-mcp
  (:use #:cl)
  (:export #:make-orders-catalog-options
           #:catalog-server-names
           #:qualified-tool-names))
(in-package #:claude-agent-sdk-cl.harness-example.sdk-mcp)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun json-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key object) value))
    object))

(defun make-lookup-order-tool ()
  "Return one validated in-process SDK tool. The handler stays in Lisp."
  (claude-agent-sdk-cl:make-sdk-tool
   :name "lookup_order"
   :description "Look up one order by ID."
   :input-schema (json-object
                  "type" "object"
                  "properties" (json-object
                                "order_id" (json-object "type" "string")))
   :handler (lambda (arguments context)
              (declare (ignore context))
              (claude-agent-sdk-cl:make-sdk-tool-result
               :text (format nil "order ~A" (gethash "order_id" arguments))))))

(defun make-orders-catalog-options ()
  "Build session-start options for an in-process SDK MCP catalog.

Prefer this over a bare generic mcp_message control handler when the harness
owns a typed tool catalog. The catalog is frozen here; replacement/resumed
clients must rebuild it explicitly."
  (let* ((tool (make-lookup-order-tool))
         (server (claude-agent-sdk-cl:make-sdk-mcp-server
                  :name "orders" :tools (list tool))))
    (claude-agent-sdk-cl:make-agent-options
     ;; Availability: disable Claude Code built-ins for this catalog-only session.
     :builtin-tools :none
     :sdk-mcp-servers (list server)
     ;; Exclude ambient user/project/plugin MCP configuration.
     :strict-mcp-config t
     ;; Invocation permission policy remains separate from source availability.
     :allowed-tools '("mcp__orders__lookup_order"))))

(defun catalog-server-names (options)
  (mapcar #'claude-agent-sdk-cl:sdk-mcp-server-name
          (claude-agent-sdk-cl:agent-options-sdk-mcp-servers options)))

(defun qualified-tool-names (options)
  (loop for server in (claude-agent-sdk-cl:agent-options-sdk-mcp-servers options)
        append (mapcar (lambda (tool)
                         (format nil "mcp__~A__~A"
                                 (claude-agent-sdk-cl:sdk-mcp-server-name server)
                                 (claude-agent-sdk-cl:sdk-tool-name tool)))
                       (claude-agent-sdk-cl:sdk-mcp-server-tools server))))
