(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(defun %write-text-file (path content)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                       :if-does-not-exist :create :external-format :utf-8)
    (write-string content out))
  path)

(defun %call-read-tool (&key path offset limit)
  (let ((arguments (make-hash-table :test #'equal)))
    (setf (gethash "path" arguments) path)
    (when offset (setf (gethash "offset" arguments) offset))
    (when limit (setf (gethash "limit" arguments) limit))
    ;; MULTIPLE-VALUE-BIND, not MULTIPLE-VALUE-LIST: a handler returning a
    ;; single value (no explicit second value) still yields IS-ERROR nil
    ;; here, matching production's %SDK-TOOL-FROM-DEFINITION contract.
    (multiple-value-bind (text is-error)
        (sm-harness::%read-file-tool-handler arguments nil)
      (list text is-error))))

(defun %call-write-tool (&key path content)
  (let ((arguments (make-hash-table :test #'equal)))
    (setf (gethash "path" arguments) path)
    (setf (gethash "content" arguments) content)
    (multiple-value-bind (text is-error)
        (sm-harness::%write-file-tool-handler arguments nil)
      (list text is-error))))

(defun %read-whole-file (path)
  (with-open-file (in path :direction :input :external-format :utf-8)
    (let ((buf (make-string (file-length in))))
      (subseq buf 0 (read-sequence buf in)))))

(test read-file-tool-returns-exact-content-for-a-small-file
  (let* ((root (temp-data-root))
         (path (merge-pathnames "hello.txt" root)))
    (unwind-protect
         (progn
           (%write-text-file path (format nil "line one~%line two~%"))
           (destructuring-bind (text is-error) (%call-read-tool :path (namestring path))
             (is (null is-error))
             (is (string= (format nil "1~Cline one~%2~Cline two~%" #\Tab #\Tab) text))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test read-file-tool-offset-and-limit-slice-lines
  (let* ((root (temp-data-root))
         (path (merge-pathnames "multi.txt" root)))
    (unwind-protect
         (progn
           (%write-text-file path (format nil "a~%b~%c~%d~%"))
           (destructuring-bind (text is-error)
               (%call-read-tool :path (namestring path) :offset 2 :limit 2)
             (is (null is-error))
             (is (string= (format nil "2~Cb~%3~Cc~%" #\Tab #\Tab) text))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test read-file-tool-missing-file-is-a-safe-error-not-a-crash
  (let* ((root (temp-data-root))
         (path (merge-pathnames "does-not-exist.txt" root)))
    (unwind-protect
         (destructuring-bind (text is-error) (%call-read-tool :path (namestring path))
           (is (eq t is-error))
           (is (search "file not found" text)))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test read-file-tool-truncates-a-file-over-the-character-cap
  (let* ((root (temp-data-root))
         (path (merge-pathnames "big.txt" root)))
    (unwind-protect
         (progn
           (%write-text-file path (format nil "0123456789~%0123456789~%0123456789~%"))
           (let ((sm-harness::+read-tool-max-chars+ 15))
             (destructuring-bind (text is-error) (%call-read-tool :path (namestring path))
               (is (null is-error))
               (is (search "[truncated: file exceeds 15 characters]" text)))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test read-file-tool-handles-a-binary-file-safely
  (let* ((root (temp-data-root))
         (path (merge-pathnames "binary.dat" root)))
    (unwind-protect
         (progn
           (ensure-directories-exist path)
           (with-open-file (out path :direction :output :if-exists :supersede
                                :if-does-not-exist :create
                                :element-type '(unsigned-byte 8))
             (write-sequence (vector 0 159 146 150 255 0 1 2) out))
           (destructuring-bind (text is-error) (%call-read-tool :path (namestring path))
             (is (null is-error))
             (is (search "binary file" text))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test write-file-tool-writes-then-reads-back-exact-content
  (let* ((root (temp-data-root))
         (path (merge-pathnames "written.txt" root)))
    (unwind-protect
         (destructuring-bind (text is-error)
             (%call-write-tool :path (namestring path) :content "hello world")
           (is (null is-error))
           (is (search "wrote" text))
           (is (string= "hello world" (%read-whole-file path))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test write-file-tool-creates-parent-directories
  (let* ((root (temp-data-root))
         (path (merge-pathnames "a/b/c/nested.txt" root)))
    (unwind-protect
         (destructuring-bind (text is-error)
             (%call-write-tool :path (namestring path) :content "nested content")
           (is (null is-error))
           (is (search "wrote" text))
           (is (string= "nested content" (%read-whole-file path))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test write-file-tool-overwrites-an-existing-file
  (let* ((root (temp-data-root))
         (path (merge-pathnames "overwrite.txt" root)))
    (unwind-protect
         (progn
           (%write-text-file path "original content")
           (destructuring-bind (text is-error)
               (%call-write-tool :path (namestring path) :content "replaced")
             (is (null is-error))
             (is (search "wrote" text))
             (is (string= "replaced" (%read-whole-file path)))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test write-file-tool-rejects-oversized-content-and-leaves-target-untouched
  (let* ((root (temp-data-root))
         (path (merge-pathnames "capped.txt" root)))
    (unwind-protect
         (progn
           (%write-text-file path "original")
           (let ((sm-harness::+write-tool-max-chars+ 5))
             (destructuring-bind (text is-error)
                 (%call-write-tool :path (namestring path) :content "this is too long")
               (is (eq t is-error))
               (is (search "exceeds" text))
               ;; Rejected outright: the existing file must be untouched, not
               ;; partially overwritten.
               (is (string= "original" (%read-whole-file path))))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test write-file-tool-target-path-is-a-directory-is-a-safe-error
  (let* ((root (temp-data-root))
         (path (merge-pathnames "somedir/" root)))
    (unwind-protect
         (progn
           (ensure-directories-exist path)
           (destructuring-bind (text is-error)
               (%call-write-tool :path (namestring path) :content "x")
             (is (eq t is-error))
             (is (search "unable to write file" text))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
