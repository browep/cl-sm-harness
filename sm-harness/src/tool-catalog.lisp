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

(defparameter +read-tool-max-chars+ (* 2 1024 1024)
  "Cap on characters read from a file before line-slicing. Approximate for
multi-byte UTF-8 content (a character cap, not a strict byte cap) -- this
tool is not a precision file-size accounting mechanism, just a guard
against reading an unbounded file into memory.")

(defun %read-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (path-field (%json-object "type" "string"))
        (offset-field (%json-object "type" "integer"))
        (limit-field (%json-object "type" "integer")))
    (setf (gethash "path" props) path-field
          (gethash "offset" props) offset-field
          (gethash "limit" props) limit-field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "path"))
    schema))

(defun %split-lines (text)
  (let ((lines '()) (start 0) (len (length text)))
    (loop
      (let ((pos (position #\Newline text :start start)))
        (cond
          (pos (push (subseq text start pos) lines) (setf start (1+ pos)))
          (t (when (< start len) (push (subseq text start) lines))
             (return)))))
    (nreverse lines)))

(defun %file-byte-size (path)
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (file-length in)))

(defun %read-file-text (path)
  "Return (values text truncated-p) read as UTF-8 up to +READ-TOOL-MAX-CHARS+
characters, or NIL if PATH does not decode as UTF-8 text."
  (handler-case
      (with-open-file (in path :direction :input :external-format :utf-8)
        (let* ((buf (make-string +read-tool-max-chars+))
               (n (read-sequence buf in)))
          (values (subseq buf 0 n) (not (null (read-char in nil nil))))))
    (error () nil)))

(defun %read-file-tool-handler (arguments context)
  (declare (ignore context))
  (let ((path (gethash "path" arguments))
        (offset (gethash "offset" arguments))
        (limit (gethash "limit" arguments)))
    (cond
      ((not (and (stringp path) (plusp (length path))))
       (values "read_file requires a non-empty path" t))
      ((not (probe-file path))
       (values (format nil "file not found: ~A" path) t))
      (t
       (handler-case
           (multiple-value-bind (text truncated-p) (%read-file-text path)
             (if (null text)
                 (values (format nil "binary file, ~:D bytes" (%file-byte-size path)) nil)
                 (let* ((lines (%split-lines text))
                        (start (max 0 (1- (or offset 1))))
                        (end (if (and limit (< start (length lines)))
                                 (min (length lines) (+ start limit))
                                 (length lines)))
                        (selected (if (< start (length lines))
                                      (subseq lines start end)
                                      '())))
                   (values
                    (with-output-to-string (out)
                      (loop for line in selected
                            for n from (1+ start)
                            do (format out "~D~C~A~%" n #\Tab line))
                      (when truncated-p
                        (format out "[truncated: file exceeds ~:D characters]~%"
                                +read-tool-max-chars+)))
                    nil))))
         (error ()
           (values (format nil "unable to read file: ~A" path) t)))))))

(defun make-read-tool-definition ()
  "No sandboxing: any path the harness process can reach is readable (see
issue #61/#62). OFFSET/LIMIT select a 1-indexed line range; content beyond
+READ-TOOL-MAX-CHARS+ is truncated, not silently dropped without notice."
  (make-tool-definition
   :name "read_file"
   :description "Read a file's contents from the container's filesystem.
No sandboxing: any path the harness process can reach is readable, not
just a project directory. PATH is required. OFFSET (1-indexed) and LIMIT
select a line range. Output is line-numbered (\"<n>\\t<text>\"). Large
files are truncated with an explicit notice; binary/non-UTF-8 files
return a size summary instead of their content."
   :input-schema (%read-schema)
   :handler #'%read-file-tool-handler))

(defun default-tool-catalog ()
  "Return product-owned tool metadata, not SDK objects."
  (make-tool-catalog
   :servers
   (list (make-tool-server-definition
          :name "sm_harness"
          :version "0.1.0"
          :tools (list (make-echo-tool-definition)
                       (make-read-tool-definition))))))
