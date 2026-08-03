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

(test read-file-tool-caps-one-result-and-names-the-offset-to-resume-from
  ;; #126: the client persists an oversized tool result to disk and shows the
  ;; model a 2KB preview carrying no instruction to read the rest, so a result
  ;; that does not fit must stop early and say where to continue instead.
  (let* ((root (temp-data-root))
         (path (merge-pathnames "many-lines.txt" root)))
    (unwind-protect
         (progn
           (%write-text-file path (format nil "~{line ~D~%~}"
                                          (loop for i from 1 to 20 collect i)))
           (let ((sm-harness::+tool-result-max-chars+ 40))
             (destructuring-bind (text is-error) (%call-read-tool :path (namestring path))
               (is (null is-error))
               (is (search (format nil "1~Cline 1" #\Tab) text))
               (is (search "[truncated:" text))
               (is (search "more lines not shown" text))
               ;; The notice names the next unread line, so paging on is an
               ;; instruction the model receives, not a convention to infer.
               (let* ((marker "offset=")
                      (pos (search marker text))
                      (resume (and pos (parse-integer text :start (+ pos (length marker))
                                                          :junk-allowed t))))
                 (is (integerp resume))
                 (destructuring-bind (rest-text rest-error)
                     (%call-read-tool :path (namestring path) :offset resume :limit 1)
                   (is (null rest-error))
                   (is (search (format nil "~D~Cline ~D" resume #\Tab resume) rest-text)))))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test read-file-tool-cuts-a-single-line-longer-than-the-result-cap
  ;; A minified one-line file must respect the cap too: emitting the line
  ;; whole "because it is one line" would reintroduce the oversized result.
  (let* ((root (temp-data-root))
         (path (merge-pathnames "minified.json" root)))
    (unwind-protect
         (progn
           (%write-text-file path (format nil "~A~%" (make-string 5000 :initial-element #\x)))
           (let ((sm-harness::+tool-result-max-chars+ 100))
             (destructuring-bind (text is-error) (%call-read-tool :path (namestring path))
               (is (null is-error))
               (is (< (length text) 400))
               (is (search "cut mid-line" text)))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test read-file-tool-emits-no-truncation-notice-when-everything-fits
  (let* ((root (temp-data-root))
         (path (merge-pathnames "small.txt" root)))
    (unwind-protect
         (progn
           (%write-text-file path (format nil "a~%b~%"))
           (destructuring-bind (text is-error) (%call-read-tool :path (namestring path))
             (is (null is-error))
             (is (null (search "[truncated" text)))))
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

(test write-file-tool-overwrites-an-existing-extensionless-file
  ;; Regression test for #96: PATH names with no extension (Dockerfile,
  ;; Makefile, LICENSE, ...) have PATHNAME-TYPE NIL. CL:RENAME-FILE (what
  ;; UIOP:RENAME-FILE-OVERWRITING-TARGET wraps) merges unspecified (NIL)
  ;; components of its new-name argument in from the pathname of the file
  ;; actually being renamed -- the .tmp file, whose type is "tmp" -- which
  ;; silently turned the rename into a no-op self-rename onto the .tmp
  ;; file's own name. The destination was left untouched while the tool
  ;; still reported a fabricated success with the *old* file's byte count.
  (let* ((root (temp-data-root))
         (path (merge-pathnames "Dockerfile" root)))
    (unwind-protect
         (progn
           (%write-text-file path "FROM debian:stable-slim AS original-base-image-content")
           (destructuring-bind (text is-error)
               (%call-write-tool :path (namestring path) :content "UNIQUE_MARKER_ABCDEF_TEST_ONLY")
             (is (null is-error))
             (is (search "wrote" text))
             ;; The reported byte count must match what was actually written,
             ;; not a stale count from the untouched original file.
             (is (search (format nil "~:D" (length "UNIQUE_MARKER_ABCDEF_TEST_ONLY")) text))
             (is (string= "UNIQUE_MARKER_ABCDEF_TEST_ONLY" (%read-whole-file path))))
           ;; No orphaned temp file should survive a successful write.
           (is (not (probe-file (make-pathname :defaults path :type "tmp")))))
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

(test bash-tool-rejects-kills-that-would-hit-the-harness-own-process
  ;; Pinned guard identity: what matters is the pattern-vs-own-cmdline
  ;; match, not how this test image happened to be invoked. The pkill
  ;; commands are the exact ones that killed the web UI twice in #101.
  (let ((sm-harness::*bash-guard-command-line*
          "sbcl --non-interactive --eval (sm-harness-web-ui:main)"))
    (dolist (command (list "pkill -f \"sbcl.*sm-harness-web-ui\" 2>/dev/null; sleep 1"
                           "pkill -f \"sbcl.*non-interactive\" 2>/dev/null; sleep 1; echo done"
                           "pkill sbcl"
                           "killall sbcl"
                           "kill -9 1"
                           "kill 1"))
      (destructuring-bind (text is-error) (%call-bash-tool :command command)
        (is (eq t is-error))
        (is (search "rejected" text))
        (is (search "reload_harness" text))))))

(test bash-tool-self-kill-guardrail-still-allows-other-sbcl-kills
  ;; Sessions legitimately start and stop scratch sbcl servers to test
  ;; changes: a kill is allowed whenever its target/pattern cannot hit the
  ;; guarded process, even when it names sbcl. Also covers specific-PID
  ;; kills and an incidental "1" argument in a later segment.
  (let ((sm-harness::*bash-guard-command-line*
          "sbcl --non-interactive --eval (sm-harness-web-ui:main)"))
    (dolist (command (list "kill -0 999999 2>/dev/null; echo ran"
                           "kill -9 4242 && sleep 1; echo ran"
                           ;; [.] keeps the regex from matching the /bin/sh -c
                           ;; wrapper's own command line and killing it.
                           "pkill -f 'sbcl.*scratch-server[.]lisp'; echo ran"
                           "killall my-scratch-server 2>/dev/null; echo ran"))
      (destructuring-bind (text is-error) (%call-bash-tool :command command)
        (is (null is-error))
        (is (search "ran" text))))))

(test bash-tool-guard-does-not-crash-on-backslash-tokens
  ;; #126: the guard splits a command on the pipe character, so a grep pattern
  ;; with two or more escaped-pipe alternations leaves a segment whose head
  ;; token ends in a backslash. FILE-NAMESTRING signalled on that token and the
  ;; error left the handler as an opaque JSON-RPC -32603 "SDK tool handler
  ;; failed" -- eleven such rejections in one real session, including its own
  ;; attempts to grep the project docs.
  (let ((sm-harness::*bash-guard-command-line*
          "sbcl --non-interactive --eval (sm-harness-web-ui:main)"))
    (dolist (command (list "printf '%s' 'x\\|y\\|z'"
                           "printf '%s' 'a\\|b\\|c\\|d'"
                           "printf 'ran' | grep -c 'ran\\|other\\|third'"))
      (destructuring-bind (text is-error) (%call-bash-tool :command command)
        (is (null is-error))
        (is (search "exit code: 0" text))))))

(test bash-tool-guard-still-rejects-self-kills-written-with-a-backslash
  ;; Reading an unparsable token literally must not open a hole in the guard:
  ;; the pkill segment of the same command is still parsed and still matched.
  (let ((sm-harness::*bash-guard-command-line*
          "sbcl --non-interactive --eval (sm-harness-web-ui:main)"))
    (destructuring-bind (text is-error)
        (%call-bash-tool :command "echo 'a\\|b\\|c'; pkill -f 'sbcl.*sm-harness-web-ui'")
      (is (eq t is-error))
      (is (search "rejected" text)))))

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

(test bash-tool-output-cap-keeps-both-streams-inside-one-result
  ;; #126: the two streams are capped independently, so the pair still has to
  ;; fit the client's tool-result ceiling when a command fills both.
  (is (<= (* 2 sm-harness::+bash-tool-max-output-chars+)
          sm-harness::+tool-result-max-chars+)))

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

(defun %call-web-search-tool (&key query max-results)
  (let ((arguments (make-hash-table :test #'equal)))
    (setf (gethash "query" arguments) query)
    (when max-results (setf (gethash "max_results" arguments) max-results))
    (multiple-value-bind (text is-error)
        (sm-harness::%web-search-tool-handler arguments nil)
      (list text is-error))))

(defmacro with-stubbed-tavily-key ((&optional (key "test-key")) &body body)
  `(let ((sm-harness::*tavily-api-key-fn* (lambda () ,key)))
     ,@body))

(test web-search-tool-rejects-an-empty-query
  (with-stubbed-tavily-key ()
    (destructuring-bind (text is-error) (%call-web-search-tool :query "")
      (is (eq t is-error))
      (is (search "non-empty query" text)))))

(test web-search-tool-rejects-a-non-positive-max-results
  (with-stubbed-tavily-key ()
    (destructuring-bind (text is-error) (%call-web-search-tool :query "x" :max-results 0)
      (is (eq t is-error))
      (is (search "positive integer max_results" text)))))

(test web-search-tool-reports-a-missing-api-key-as-a-safe-error-not-a-crash
  (let ((sm-harness::*tavily-api-key-fn* (lambda () nil)))
    (destructuring-bind (text is-error) (%call-web-search-tool :query "common lisp")
      (is (eq t is-error))
      (is (search "TAVILY_API_KEY" text)))))

(test web-search-tool-formats-results-from-a-stubbed-response
  (with-stubbed-tavily-key ()
    (let ((sm-harness::*web-search-request-fn*
            (lambda (api-key query max-results)
              (declare (ignore max-results))
              (is (string= "test-key" api-key))
              (is (string= "common lisp" query))
              (values "{\"results\":[{\"title\":\"CL\",\"url\":\"http://example.com\",\"content\":\"about lisp\"}]}"
                      200))))
      (destructuring-bind (text is-error) (%call-web-search-tool :query "common lisp")
        (is (null is-error))
        (is (search "CL" text))
        (is (search "http://example.com" text))
        (is (search "about lisp" text))))))

(test web-search-tool-reports-no-results-explicitly
  (with-stubbed-tavily-key ()
    (let ((sm-harness::*web-search-request-fn*
            (lambda (api-key query max-results)
              (declare (ignore api-key query max-results))
              (values "{\"results\":[]}" 200))))
      (destructuring-bind (text is-error) (%call-web-search-tool :query "nothing found ever")
        (is (null is-error))
        (is (string= "no results" text))))))

(test web-search-tool-clamps-max-results-to-the-hard-cap
  (with-stubbed-tavily-key ()
    (let* ((seen nil)
           (sm-harness::*web-search-request-fn*
            (lambda (api-key query max-results)
              (declare (ignore api-key query))
              (setf seen max-results)
              (values "{\"results\":[]}" 200))))
      (%call-web-search-tool :query "x" :max-results 9999)
      (is (= sm-harness::+web-search-max-results-cap+ seen)))))

(test web-search-tool-maps-a-non-200-status-to-a-safe-error
  (with-stubbed-tavily-key ()
    (let ((sm-harness::*web-search-request-fn*
            (lambda (api-key query max-results)
              (declare (ignore api-key query max-results))
              (values "rate limited" 429))))
      (destructuring-bind (text is-error) (%call-web-search-tool :query "x")
        (is (eq t is-error))
        (is (search "429" text))
        (is (search "rate limited" text))))))

(test web-search-tool-maps-an-unparsable-response-to-a-safe-error
  (with-stubbed-tavily-key ()
    (let ((sm-harness::*web-search-request-fn*
            (lambda (api-key query max-results)
              (declare (ignore api-key query max-results))
              (values "not json" 200))))
      (destructuring-bind (text is-error) (%call-web-search-tool :query "x")
        (is (eq t is-error))
        (is (search "could not parse" text))))))

(test web-search-tool-maps-a-transport-failure-to-a-safe-error-not-a-crash
  (with-stubbed-tavily-key ()
    (let ((sm-harness::*web-search-request-fn*
            (lambda (api-key query max-results)
              (declare (ignore api-key query max-results))
              (error "connection refused"))))
      (destructuring-bind (text is-error) (%call-web-search-tool :query "x")
        (is (eq t is-error))
        (is (search "web search failed" text))))))

(test web-search-tool-is-registered-in-the-default-catalog
  (let* ((catalog (sm-harness:default-tool-catalog))
         (tools (sm-harness:tool-server-definition-tools (first (sm-harness:tool-catalog-servers catalog)))))
    (is (find "web_search" tools :key #'sm-harness:tool-definition-name :test #'string=))))

;;;; #116 phase 0: a tool-definition handler stored as a SYMBOL designator
;;;; (not a captured #'name function object) must hot-reload -- a later
;;;; redefinition of the underlying function (what RELOAD_HARNESS does) must
;;;; be visible to a tool-definition built *before* that redefinition, with
;;;; no new catalog/tool-definition construction in between.
;;;;
;;;; These tests reproduce a redefinition via genuinely separate
;;;; COMPILE-FILE + LOAD calls against temp source files, not IN-PROCESS
;;;; (COMPILE 'name ...) or (EVAL '(DEFUN ...)): verified directly that
;;;; those lighter-weight redefinition paths do not reliably reproduce the
;;;; frozen-old-closure behavior a real RELOAD_HARNESS run does (SBCL's
;;;; single-image COMPILE can patch an existing function in ways a genuine
;;;; separate fasl compile+load -- what ASDF:LOAD-SYSTEM actually performs
;;;; -- never does), so only the file-based form here is a faithful stand-in.

(defun %write-hot-reload-fixture-source (path return-value)
  (with-open-file (out path :direction :output :if-exists :supersede
                       :if-does-not-exist :create :external-format :utf-8)
    (format out "(in-package #:sm-harness/tests)~%")
    (format out "(defun %hot-reload-fixture-handler (arguments context)~%")
    (format out "  (declare (ignore arguments context))~%")
    (format out "  (values ~S nil))~%" return-value)
    (format out "(defun %hot-reload-fixture-capture () (function %hot-reload-fixture-handler))~%")))

(defun %compile-and-load-hot-reload-fixture (root return-value)
  (let ((source (merge-pathnames "fixture.lisp" root)))
    (%write-hot-reload-fixture-source source return-value)
    (let ((fasl (compile-file source :output-file (merge-pathnames "fixture.fasl" root)
                                     :verbose nil :print nil)))
      (load fasl))))

(test tool-handler-symbol-designator-hot-reloads-mid-session
  (let* ((root (temp-data-root)))
    (unwind-protect
         (progn
           (%compile-and-load-hot-reload-fixture root "before-reload")
           (let ((def (sm-harness::make-tool-definition
                       :name "fixture" :description "fixture"
                       :input-schema (sm-harness::%echo-schema)
                       :handler '%hot-reload-fixture-handler)))
             (multiple-value-bind (text is-error)
                 (funcall (sm-harness:tool-definition-handler def)
                          (make-hash-table :test #'equal) nil)
               (is (null is-error))
               (is (string= "before-reload" text)))
             ;; A genuinely separate recompile+reload -- exactly what
             ;; RELOAD_HARNESS's (ASDF:LOAD-SYSTEM ... :FORCE T) performs.
             ;; DEF itself is never touched: no new tool-definition, no new
             ;; catalog, just the underlying function redefined out from
             ;; under it.
             (%compile-and-load-hot-reload-fixture root "after-reload")
             (multiple-value-bind (text is-error)
                 (funcall (sm-harness:tool-definition-handler def)
                          (make-hash-table :test #'equal) nil)
               (is (null is-error))
               (is (string= "after-reload" text)
                   "a symbol-designator handler must see a post-construction redefinition"))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test tool-handler-captured-function-object-does-not-hot-reload-illustrative
  "Documents the exact defect #116 fixed, as a permanent regression guard: a
CAPTURED #'name closure -- unlike a symbol designator -- keeps calling
whatever body existed at capture time forever, even after the underlying
function is reloaded via a genuinely separate recompile (what RELOAD_HARNESS
performs). If this test ever starts failing, something in this Lisp
implementation's redefinition semantics changed; it is not this project's
own regression to chase."
  (let* ((root (temp-data-root)))
    (unwind-protect
         (progn
           (%compile-and-load-hot-reload-fixture root "before-reload")
           (let ((captured (funcall (symbol-function '%hot-reload-fixture-capture))))
             (%compile-and-load-hot-reload-fixture root "after-reload")
             (multiple-value-bind (text is-error) (funcall captured (make-hash-table :test #'equal) nil)
               (declare (ignore is-error))
               (is (string= "before-reload" text)
                   "a captured #'name handler froze the pre-redefinition body -- exactly the #116 defect a symbol designator avoids"))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test default-tool-catalog-handlers-are-symbol-designators-not-captured-closures
  "Guards every catalog tool, not just one fixture: #116 requires each
built-in tool's :HANDLER to be late-bound. An anonymous LAMBDA (no symbol to
late-bind) or a captured #'name FUNCTION object would both fail this."
  (let* ((catalog (sm-harness:default-tool-catalog))
         (tools (sm-harness:tool-server-definition-tools
                 (first (sm-harness:tool-catalog-servers catalog)))))
    (dolist (tool tools)
      ;; echo_text is deliberately exempted: its handler is a small anonymous
      ;; LAMBDA with nothing else to late-bind against (see tool-catalog.lisp).
      (unless (string= (sm-harness:tool-definition-name tool) "echo_text")
        (is (symbolp (sm-harness:tool-definition-handler tool))
            (format nil "~A's handler should be a symbol designator, not a captured function object"
                    (sm-harness:tool-definition-name tool)))))))

(defun %call-set-session-title-tool (&key session-id title)
  (let ((arguments (make-hash-table :test #'equal)))
    (when session-id (setf (gethash "session_id" arguments) session-id))
    (when title (setf (gethash "title" arguments) title))
    (multiple-value-bind (text is-error)
        (sm-harness::%set-session-title-tool-handler arguments nil)
      (list text is-error))))

(test set-session-title-tool-is-registered-in-the-default-catalog
  (let* ((catalog (sm-harness:default-tool-catalog))
         (tools (sm-harness:tool-server-definition-tools
                 (first (sm-harness:tool-catalog-servers catalog))))
         (tool (find "set_session_title" tools
                     :key #'sm-harness:tool-definition-name :test #'string=)))
    (is (not (null tool)))
    (is (equal '("session_id" "title")
               (gethash "required" (sm-harness:tool-definition-input-schema tool))))))

(test set-session-title-tool-handler-requires-tool-harness-to-be-configured
  "With *TOOL-HARNESS* unset (the default -- headless sm-harness with no
application wired up), the handler reports a safe tool-result error
instead of crashing."
  (let ((sm-harness::*tool-harness* nil))
    (destructuring-bind (text is-error)
        (%call-set-session-title-tool :session-id "sess-1" :title "New title")
      (is (eq t is-error))
      (is (search "no harness is wired up" text)))))

(test set-session-title-tool-handler-rejects-missing-arguments
  (let ((sm-harness::*tool-harness* nil))
    (destructuring-bind (text is-error)
        (%call-set-session-title-tool :title "New title")
      (is (eq t is-error))
      (is (search "session_id" text)))
    (destructuring-bind (text is-error)
        (%call-set-session-title-tool :session-id "sess-1")
      (is (eq t is-error))
      (is (search "title" text)))))

(test set-session-title-tool-handler-renames-a-real-session-end-to-end
  "Exercises the handler exactly as a live tool call would: through
*TOOL-HARNESS*, against a real (temp-rooted) HARNESS, confirming the
rename is both reported back in the tool result text and durably
persisted."
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root))))
    (unwind-protect
         (let* ((snap (sm-harness:start-session h :title "Original"))
                (sid (sm-harness:session-snapshot-id snap))
                (sm-harness::*tool-harness* h))
           (destructuring-bind (text is-error)
               (%call-set-session-title-tool :session-id sid :title "  Renamed via tool  ")
             (is (null is-error))
             (is (search "Renamed via tool" text)))
           (let ((reopened (sm-harness:open-session h sid)))
             (is (string= "Renamed via tool" (sm-harness:session-snapshot-title reopened)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test set-session-title-tool-handler-reports-unknown-session-safely
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root))))
    (unwind-protect
         (let ((sm-harness::*tool-harness* h))
           (destructuring-bind (text is-error)
               (%call-set-session-title-tool :session-id "sess-does-not-exist" :title "hi")
             (is (eq t is-error))
             (is (search "session not found" text))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;;;; #123: every catalog tool declares explicit MCP-style annotations, no
;;;; tool silently defaults to unannotated. read_file/web_search/echo_text
;;;; are the only ones marked read-only-safe today; bash/write_file/
;;;; reload_harness/set_session_title stay deliberately conservative.

(test default-catalog-tools-all-declare-explicit-annotations
  (let* ((catalog (sm-harness:default-tool-catalog))
         (tools (sm-harness:tool-server-definition-tools
                 (first (sm-harness:tool-catalog-servers catalog)))))
    (is (plusp (length tools)))
    (dolist (tool tools)
      (is (not (null (sm-harness::tool-definition-annotations tool)))
          "~A must declare explicit #123 annotations, not default to unannotated"
          (sm-harness:tool-definition-name tool)))))

(test default-catalog-read-only-tools-match-the-123-table
  (let* ((catalog (sm-harness:default-tool-catalog))
         (tools (sm-harness:tool-server-definition-tools
                 (first (sm-harness:tool-catalog-servers catalog)))))
    (flet ((read-only-p (name)
             (let ((tool (find name tools :key #'sm-harness:tool-definition-name :test #'string=)))
               (is (not (null tool)) "~A must be registered in the default catalog" name)
               (eq t (getf (sm-harness::tool-definition-annotations tool) :read-only-p)))))
      (is (eq t (read-only-p "read_file")))
      (is (eq t (read-only-p "web_search")))
      (is (eq t (read-only-p "echo_text")))
      (is (eq nil (read-only-p "bash")))
      (is (eq nil (read-only-p "write_file")))
      (is (eq nil (read-only-p "reload_harness")))
      (is (eq nil (read-only-p "set_session_title"))))))

(test sdk-tool-from-definition-passes-annotations-through-to-the-sdk
  (let* ((definition (sm-harness::make-tool-definition
                       :name "annotated" :description "d"
                       :input-schema (sm-harness::%echo-schema)
                       :annotations '(:read-only-p t :destructive-p nil
                                      :idempotent-p t :open-world-p nil)
                       :handler (lambda (arguments context)
                                  (declare (ignore arguments context))
                                  "ok")))
         (sdk-tool (sm-harness::%sdk-tool-from-definition definition)))
    (is (equal '(:read-only-p t :destructive-p nil :idempotent-p t :open-world-p nil)
               (claude-agent-sdk-cl:sdk-tool-annotations sdk-tool)))))

;;;; #142: RUN_SUBAGENT -- parallel subagent sessions with backend/model
;;;; choice and authoritative parent-session linkage via CONTEXT's
;;;; :CALLING-SESSION-ID (captured by %SDK-TOOL-FROM-DEFINITION from
;;;; *CURRENT-SESSION-RECORD* at catalog-construction time, never read
;;;; directly by the handler -- see %RUN-SUBAGENT-TOOL-HANDLER's docstring
;;;; for why: every MCP tool call runs on a freshly spawned thread that was
;;;; never inside the dynamic extent where *CURRENT-SESSION-RECORD* was
;;;; bound, so CALLING-SESSION-ID has to travel as a genuine argument).

(defun %call-run-subagent-tool (requests &key calling-session-id)
  "REQUESTS is a list of plists (:prompt :backend :model); NIL entries for
:backend/:model are simply omitted from that request's JSON object,
matching how an optional field looks over the wire. CALLING-SESSION-ID
models what %SDK-TOOL-FROM-DEFINITION would have put in CONTEXT for a real
tool call."
  (let ((arguments (make-hash-table :test #'equal))
        (items '()))
    (dolist (r requests)
      (let ((item (make-hash-table :test #'equal)))
        (setf (gethash "prompt" item) (getf r :prompt))
        (when (getf r :backend) (setf (gethash "backend" item) (getf r :backend)))
        (when (getf r :model) (setf (gethash "model" item) (getf r :model)))
        (push item items)))
    (setf (gethash "requests" arguments) (nreverse items))
    (multiple-value-bind (text is-error)
        (sm-harness::%run-subagent-tool-handler
         arguments (list :calling-session-id calling-session-id))
      (list text is-error))))

(test run-subagent-tool-is-registered-in-the-default-catalog-for-a-top-level-session
  (let ((sm-harness::*current-session-record* nil))
    (let* ((catalog (sm-harness:default-tool-catalog))
           (tools (sm-harness:tool-server-definition-tools
                   (first (sm-harness:tool-catalog-servers catalog))))
           (tool (find "run_subagent" tools
                       :key #'sm-harness:tool-definition-name :test #'string=)))
      (is (not (null tool)))
      (is (equal '("requests") (gethash "required" (sm-harness:tool-definition-input-schema tool)))))))

(test run-subagent-tool-is-omitted-from-a-subagents-own-catalog
  "#142's resolved decision: a subagent cannot itself call run_subagent --
enforced here by DEFAULT-TOOL-CATALOG simply never including it, not by a
depth counter a subagent's own tool calls could evade."
  (let* ((parent (sm-harness::make-session-record :title "Parent"))
         (child (sm-harness::make-session-record
                 :title "Child"
                 :parent-session-id (sm-harness::session-record-id parent)))
         (sm-harness::*current-session-record* child))
    (let* ((catalog (sm-harness:default-tool-catalog))
           (tools (sm-harness:tool-server-definition-tools
                   (first (sm-harness:tool-catalog-servers catalog)))))
      (is (null (find "run_subagent" tools
                      :key #'sm-harness:tool-definition-name :test #'string=)))
      ;; every other tool is still present -- full catalog minus run_subagent.
      (is (not (null (find "bash" tools
                          :key #'sm-harness:tool-definition-name :test #'string=)))))))

(test run-subagent-tool-handler-requires-tool-harness-to-be-configured
  (let ((sm-harness::*tool-harness* nil))
    (destructuring-bind (text is-error)
        (%call-run-subagent-tool (list (list :prompt "do something"))
                                 :calling-session-id "sess-parent-1")
      (is (eq t is-error))
      (is (search "no harness is wired up" text)))))

(test run-subagent-tool-handler-requires-calling-session-context
  "CALLING-SESSION-ID absent from CONTEXT (as it would be if
*CURRENT-SESSION-RECORD* were unbound when %SDK-TOOL-FROM-DEFINITION built
this connection's tools, e.g. headless sm-harness with nothing wired up)
is reported as a safe error, never crashes trying to use a NIL id."
  (let ((sm-harness::*tool-harness* :not-actually-used))
    (destructuring-bind (text is-error)
        (%call-run-subagent-tool (list (list :prompt "do something")))
      (is (eq t is-error))
      (is (search "no calling-session context" text)))))

(test run-subagent-tool-handler-rejects-empty-or-oversized-requests
  (let ((sm-harness::*tool-harness* :not-actually-used))
    (destructuring-bind (text is-error)
        (%call-run-subagent-tool '() :calling-session-id "sess-parent-1")
      (is (eq t is-error))
      (is (search "non-empty" text)))
    (destructuring-bind (text is-error)
        (%call-run-subagent-tool
         (loop repeat (1+ sm-harness::+run-subagent-max-requests+)
               collect (list :prompt "hi"))
         :calling-session-id "sess-parent-1")
      (is (eq t is-error))
      (is (search "at most" text)))))

(test run-subagent-tool-handler-rejects-a-non-string-prompt-without-launching-anything
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root)))
         (parent-snap (sm-harness:start-session h :title "P"))
         (parent-id (sm-harness:session-snapshot-id parent-snap)))
    (unwind-protect
         (let ((sm-harness::*tool-harness* h))
           (destructuring-bind (text is-error)
               (%call-run-subagent-tool (list (list :prompt ""))
                                        :calling-session-id parent-id)
             (is (eq t is-error))
             (is (search "prompt" text)))
           ;; Nothing was launched: still only the parent session on disk.
           (is (= 1 (length (sm-harness:list-sessions h :include-subagents t)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test run-subagent-tool-handler-end-to-end-parallel-with-parent-linkage
  "Real HARNESS, real (fixture-transport) sessions: two requests launched in
parallel both complete, each spawned session's PARENT-SESSION-ID is the
calling session's own id (arriving via CONTEXT's :CALLING-SESSION-ID, never
from a tool argument), both are excluded from the default LIST-SESSIONS,
and both are found via the :PARENT-SESSION-ID reverse-edge query."
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :turn-deadline-seconds 5
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-simple-turn-transport))))))
    (unwind-protect
         (let* ((parent-snap (sm-harness:start-session h :title "Parent"))
                (parent-id (sm-harness:session-snapshot-id parent-snap))
                (sm-harness::*tool-harness* h))
           (destructuring-bind (text is-error)
               (%call-run-subagent-tool
                (list (list :prompt "first subagent prompt")
                      (list :prompt "second subagent prompt" :backend "claude"))
                :calling-session-id parent-id)
             (is (null is-error))
             (is (search "[0]" text))
             (is (search "[1]" text))
             (is (search "ok" text))
             (is (search "hello from fixture" text)))
           (let ((children (sm-harness:list-sessions h :parent-session-id parent-id)))
             (is (= 2 (length children)))
             (dolist (c children)
               (is (string= parent-id (sm-harness:session-summary-parent-session-id c)))))
           ;; Default listing (what the home screen/any other caller sees)
           ;; still shows only the parent.
           (let ((ids (mapcar #'sm-harness:session-summary-id (sm-harness:list-sessions h))))
             (is (member parent-id ids :test #'string=))
             (is (= 1 (length ids)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test run-subagent-tool-handler-isolates-one-bad-request-from-the-rest
  "An unknown backend fails START-SESSION for just that request (#106's own
validation, not duplicated here) -- reported as that request's own failure
text, never crashing the whole batch or the sibling request's own thread."
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :turn-deadline-seconds 5
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-simple-turn-transport))))))
    (unwind-protect
         (let* ((parent-snap (sm-harness:start-session h :title "Parent"))
                (parent-id (sm-harness:session-snapshot-id parent-snap))
                (sm-harness::*tool-harness* h))
           (destructuring-bind (text is-error)
               (%call-run-subagent-tool
                (list (list :prompt "good prompt")
                      (list :prompt "bad prompt" :backend "no-such-backend"))
                :calling-session-id parent-id)
             (is (eq t is-error))
             (is (search "ok" text))
             (is (search "FAILED" text))
             (is (search "unknown backend" text))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test run-subagent-tool-handler-reaches-a-real-caller-id-through-a-spawned-mcp-tool-thread
  "The real bug this guards against: RUN_SUBAGENT's caller id must survive
being read on a *different thread* than the one that built the catalog --
exactly what CLAUDE-AGENT-SDK-CL's %CLIENT-SPAWN-TOOL-THREAD does for every
real MCP tool call, and exactly what a naive *CURRENT-SESSION-RECORD*-only
design (the first, broken #142 implementation) got wrong: a special bound
via LET in %ENSURE-CLIENT is invisible to a freshly spawned SB-THREAD. This
drives the exact same path a real tool call does: %SDK-TOOL-FROM-DEFINITION
captures the id while *CURRENT-SESSION-RECORD* is genuinely bound, then a
brand-new thread (standing in for %CLIENT-SPAWN-TOOL-THREAD) invokes the
resulting handler with only CONTEXT to go on."
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root)))
         (parent-snap (sm-harness:start-session h :title "Parent"))
         (parent-id (sm-harness:session-snapshot-id parent-snap))
         (parent-rec (sm-harness::repository-load-session
                      (sm-harness::harness-repository h) parent-id)))
    ;; *TOOL-HARNESS* set via SETF, not LET, deliberately: that is how
    ;; production actually sets it (sm-harness-web-ui's START-WEB-UI, once,
    ;; at startup) -- a genuine global value change any thread sees, unlike
    ;; a LET binding's dynamic extent, which a freshly spawned thread never
    ;; inherits either (the same class of bug this whole test exists to
    ;; catch, so the harness here has to avoid it too).
    (setf sm-harness::*tool-harness* h)
    (unwind-protect
         (let* ((sdk-tool
                  (let ((sm-harness::*current-session-record* parent-rec))
                    (sm-harness::%sdk-tool-from-definition
                     (sm-harness::make-run-subagent-tool-definition))))
                (arguments (make-hash-table :test #'equal))
                (item (make-hash-table :test #'equal)))
           (setf (gethash "prompt" item) "")
           (setf (gethash "requests" arguments) (list item))
           ;; *CURRENT-SESSION-RECORD* is unbound again out here -- the
           ;; whole point. A different thread (standing in for
           ;; %CLIENT-SPAWN-TOOL-THREAD) invokes the handler with no access
           ;; to it at all, only whatever SDK-TOOL's own handler closure
           ;; already captured.
           (let ((sdk-result
                   (sb-thread:join-thread
                    (sb-thread:make-thread
                     (lambda ()
                       (funcall (claude-agent-sdk-cl:sdk-tool-handler sdk-tool)
                                arguments nil))))))
             (is (claude-agent-sdk-cl:sdk-tool-result-is-error sdk-result))
             ;; An empty prompt is rejected *after* the calling-session-id
             ;; check succeeds -- if CALLING-SESSION-ID had failed to reach
             ;; the handler, this would instead be "no calling-session
             ;; context", not "prompt".
             (is (search "prompt" (claude-agent-sdk-cl:sdk-tool-result-text sdk-result)))))
      (setf sm-harness::*tool-harness* nil)
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
