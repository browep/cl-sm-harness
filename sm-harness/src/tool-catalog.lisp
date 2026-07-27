(in-package #:sm-harness)

;;;; Product tool catalog. Handlers are process-local Lisp functions.

(defun %json-object (&rest pairs)
  (let ((o (make-hash-table :test #'equal)))
    (loop for (k v) on pairs by #'cddr do (setf (gethash k o) v))
    o))

(defun %echo-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (field (%json-object "type" "string")))
    (setf (gethash "text" props) field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "text"))
    schema))

(defun make-echo-tool ()
  "Deterministic fixture-friendly tool used by default catalog and E2E."
  (claude-agent-sdk-cl:make-sdk-tool
   :name "echo_text"
   :description "Echo the provided text argument."
   :input-schema (%echo-schema)
   :handler (lambda (arguments context)
              (declare (ignore context))
              (let ((text (or (gethash "text" arguments) "")))
                (claude-agent-sdk-cl:make-sdk-tool-result
                 :text (format nil "echo: ~A" text))))))

(defun default-tool-catalog ()
  "Return a list of SDK MCP servers for the product."
  (list
   (claude-agent-sdk-cl:make-sdk-mcp-server
    :name "sm_harness"
    :version "0.1.0"
    :tools (list (make-echo-tool)))))
