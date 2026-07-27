(in-package #:sm-harness)

;;;; Product-owned tool definitions.  These are deliberately SDK-free:
;;;; metadata crosses the adapter boundary; handler closures remain local.

(defstruct (tool-definition (:constructor make-tool-definition))
  (name "" :type string)
  (description "" :type string)
  input-schema
  handler)

(defstruct (tool-server-definition (:constructor make-tool-server-definition))
  (name "" :type string)
  (version "0.1.0" :type string)
  (tools '() :type list))

(defstruct (tool-catalog (:constructor make-tool-catalog))
  (servers '() :type list))

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

(defun make-echo-tool-definition ()
  "Deterministic fixture-friendly tool definition used by the default catalog."
  (make-tool-definition
   :name "echo_text"
   :description "Echo the provided text argument."
   :input-schema (%echo-schema)
   :handler (lambda (arguments context)
              (declare (ignore context))
              (format nil "echo: ~A" (or (gethash "text" arguments) "")))))

(defun default-tool-catalog ()
  "Return product-owned tool metadata, not SDK objects."
  (make-tool-catalog
   :servers
   (list (make-tool-server-definition
          :name "sm_harness"
          :version "0.1.0"
          :tools (list (make-echo-tool-definition))))))
