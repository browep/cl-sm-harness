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

(defun %call-bash-tool (&key command timeout-seconds cwd)
  (let ((arguments (make-hash-table :test #'equal)))
    (setf (gethash "command" arguments) command)
    (when timeout-seconds (setf (gethash "timeout_seconds" arguments) timeout-seconds))
    (when cwd (setf (gethash "cwd" arguments) cwd))
    (multiple-value-bind (text is-error)
        (sm-harness::%bash-tool-handler arguments nil)
      (list text is-error))))

(test bash-tool-runs-a-successful-command-and-reports-exit-code-and-stdout
  (destructuring-bind (text is-error) (%call-bash-tool :command "echo hello")
    (is (null is-error))
    (is (search "exit code: 0" text))
    (is (search "hello" text))))

(test bash-tool-reports-a-nonzero-exit-code-as-a-normal-result-not-an-error
  (destructuring-bind (text is-error) (%call-bash-tool :command "exit 7")
    (is (null is-error))
    (is (search "exit code: 7" text))))

(test bash-tool-kills-a-command-that-exceeds-its-timeout
  (destructuring-bind (text is-error)
      (%call-bash-tool :command "sleep 5" :timeout-seconds 1)
    (is (eq t is-error))
    (is (search "timed out" text))))

(test bash-tool-timeout-kills-the-whole-process-group-no-orphans
  (let* ((root (temp-data-root))
         (marker (merge-pathnames "child-pid.txt" root))
         (command (format nil "sleep 10 & echo $! > ~A; sleep 10" (namestring marker))))
    (unwind-protect
         (progn
           (destructuring-bind (text is-error)
               (%call-bash-tool :command command :timeout-seconds 1)
             (is (eq t is-error))
             (is (search "timed out" text)))
           (is (probe-file marker))
           (let ((child-pid (parse-integer
                             (string-trim '(#\Space #\Newline #\Return)
                                          (%read-whole-file marker)))))
             ;; A group-killed background child reparents to PID 1 and can
             ;; linger briefly as an unreaped zombie, which a signal-0
             ;; probe still counts as alive -- the source of this test's
             ;; historical flakiness. Read /proc state instead: gone or
             ;; Z(ombie) both mean "killed, not an orphan", and poll with a
             ;; deadline since reaping is asynchronous.
             (flet ((dead-p ()
                      (let ((stat (ignore-errors
                                    (uiop:read-file-string
                                     (format nil "/proc/~D/stat" child-pid)))))
                        (or (null stat) (search ") Z " stat)))))
               (loop repeat 50 until (dead-p) do (sleep 0.1))
               (is (dead-p)))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test bash-tool-kill-helper-treats-an-already-dead-group-as-success
  ;; ESRCH (no such process group) is what a successful kill leaves behind,
  ;; so it must read as success, not as a failure to report.
  (let ((process (sb-ext:run-program "/bin/sh" (list "-c" "true")
                                     :wait t :search t)))
    (is (null (sm-harness::%kill-process-group
               (sb-ext:process-pid process) sb-posix:sigterm)))))

(test bash-tool-kill-helper-reports-a-genuine-kill-failure
  ;; An invalid signal number provokes EINVAL, standing in for any genuine
  ;; killpg failure. (The production incident behind #79 -- a missing kill
  ;; binary -- is a failure mode sb-posix removes entirely.)
  (let ((process (sb-ext:run-program "/bin/sh" (list "-c" "sleep 5")
                                     :wait nil :search t)))
    (unwind-protect
         (is (stringp (sm-harness::%kill-process-group
                       (sb-ext:process-pid process) -1)))
      (sm-harness::%kill-process-group (sb-ext:process-pid process)
                                       sb-posix:sigkill))))

(test bash-tool-timeout-result-reports-a-failed-kill-distinctly
  (let ((killed (sm-harness::%bash-timeout-result-text 5 nil))
        (unkilled (sm-harness::%bash-timeout-result-text 5 "killpg(123, 9) failed: EPERM")))
    (is (search "was killed" killed))
    (is (search "could not be killed" unkilled))
    (is (search "EPERM" unkilled))
    (is (search "may still be running" unkilled))))

(test bash-tool-truncates-output-over-the-character-cap
  (let ((sm-harness::+bash-tool-max-output-chars+ 5))
    (destructuring-bind (text is-error)
        (%call-bash-tool :command "printf '0123456789'")
      (is (null is-error))
      (is (search "[stdout truncated]" text)))))

(test bash-tool-rejects-a-timeout-request-over-the-hard-cap
  (destructuring-bind (text is-error)
      (%call-bash-tool :command "echo hi" :timeout-seconds 99999)
    (is (eq t is-error))
    (is (search "exceeds" text))))
