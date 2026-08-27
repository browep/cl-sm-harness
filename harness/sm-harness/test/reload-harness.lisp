(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

;;;; A throwaway ASDF system, written fresh under a temp directory per test,
;;;; used as *RELOAD-HARNESS-SYSTEM*'s target so these tests never touch the
;;;; real sm-harness system's own compiled state.

(defun %write-reload-fixture (root defun-body)
  (ensure-directories-exist root)
  (%write-text-file
   (merge-pathnames "reload-fixture.asd" root)
   (format nil "(asdf:defsystem #:reload-fixture :components ((:file \"fixture\")))~%"))
  (%write-text-file
   (merge-pathnames "fixture.lisp" root)
   (format nil "(defpackage #:reload-fixture (:use #:cl) (:export #:value #:load-count))~%(in-package #:reload-fixture)~%(defvar *load-count* 0)~%(incf *load-count*)~%(defun load-count () *load-count*)~%(defun value () ~A)~%"
           defun-body))
  root)

(defun %push-fixture-registry (root)
  (pushnew root asdf:*central-registry* :test #'equal))

(defun %call-reload-tool (&key force)
  (let ((arguments (make-hash-table :test #'equal)))
    (when force (setf (gethash "force" arguments) t))
    (multiple-value-bind (text is-error)
        (sm-harness::%reload-harness-tool-handler arguments nil)
      (list text is-error))))

(defun %extract-count (output marker)
  (let ((pos (search marker output)))
    (and pos
         (parse-integer output :start (+ pos (length marker)) :junk-allowed t))))

(test reload-harness-tool-picks-up-a-genuinely-changed-source-file
  (let* ((root (temp-data-root))
         (sm-harness::*reload-harness-system* :reload-fixture))
    (unwind-protect
         (progn
           (%write-reload-fixture root "\"v1\"")
           (%push-fixture-registry root)
           (destructuring-bind (text is-error) (%call-reload-tool)
             (is (null is-error))
             (is (search "reloaded" text)))
           (is (string= "v1" (funcall (intern "VALUE" "RELOAD-FIXTURE"))))
           (sleep 1.1) ; ensure a strictly newer source mtime than the fasl
           (%write-reload-fixture root "\"v2\"")
           (destructuring-bind (text is-error) (%call-reload-tool)
             (is (null is-error))
             (is (search "reloaded" text)))
           (is (string= "v2" (funcall (intern "VALUE" "RELOAD-FIXTURE")))))
      (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reload-harness-tool-is-a-no-op-when-nothing-changed
  (let* ((root (temp-data-root))
         (sm-harness::*reload-harness-system* :reload-fixture))
    (unwind-protect
         (progn
           (%write-reload-fixture root "\"v1\"")
           (%push-fixture-registry root)
           (%call-reload-tool)
           (let ((count-after-first (funcall (intern "LOAD-COUNT" "RELOAD-FIXTURE"))))
             (destructuring-bind (text is-error) (%call-reload-tool)
               (is (null is-error))
               (is (search "reloaded" text)))
             ;; ASDF's own timestamp check skips recompiling an unchanged
             ;; file: the fixture's top-level (incf *load-count*) must not
             ;; have run again.
             (is (= count-after-first (funcall (intern "LOAD-COUNT" "RELOAD-FIXTURE"))))))
      (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reload-harness-tool-force-recompiles-an-unchanged-file
  ;; ASDF forbids a nested OPERATE call's :FORCE from disagreeing with an
  ;; already-active outer operation's own forcing -- true here regardless
  ;; of ASDF session overrides, because the FiveAM test runner itself is
  ;; always mid-call inside (asdf:test-system ...). That restriction does
  ;; not exist in production (reload_harness there is never invoked from
  ;; inside an active ASDF operation), so this specifically exercises
  ;; :force in a genuinely separate SBCL subprocess -- which also more
  ;; faithfully matches how the tool is actually invoked in the field than
  ;; an in-process call would.
  (let* ((root (temp-data-root))
         (script (merge-pathnames "driver.lisp" root)))
    (unwind-protect
         (progn
           (%write-reload-fixture root "\"v1\"")
           (%write-text-file
            script
            (format nil "(require :asdf)~%~
(pushnew ~S asdf:*central-registry* :test (function equal))~%~
(asdf:load-system :reload-fixture)~%~
(asdf:load-system :reload-fixture)~%~
(format t \"after-plain-reload:~~D~~%\" (funcall (intern \"LOAD-COUNT\" \"RELOAD-FIXTURE\")))~%~
(asdf:load-system :reload-fixture :force t)~%~
(format t \"after-forced-reload:~~D~~%\" (funcall (intern \"LOAD-COUNT\" \"RELOAD-FIXTURE\")))~%~
(sb-ext:exit)~%"
                    (namestring root)))
           (let* ((process (sb-ext:run-program "/usr/bin/sbcl"
                                               (list "--non-interactive" "--load" (namestring script))
                                               :output :stream :error :stream :search t))
                  (output (uiop:slurp-stream-string (sb-ext:process-output process))))
             (sb-ext:process-wait process)
             (let ((plain (%extract-count output "after-plain-reload:"))
                   (forced (%extract-count output "after-forced-reload:")))
               (is (not (null plain)))
               (is (not (null forced)))
               (is (> forced plain)))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reload-harness-tool-reports-a-compile-error-safely-not-a-crash
  (let* ((root (temp-data-root))
         (sm-harness::*reload-harness-system* :reload-fixture))
    (unwind-protect
         (progn
           (%write-reload-fixture root "\"v1\"")
           (%push-fixture-registry root)
           (%call-reload-tool)
           (sleep 1.1)
           (%write-text-file
            (merge-pathnames "fixture.lisp" root)
            (format nil "(in-package #:reload-fixture)~%(defun value ( ~%"))
           (destructuring-bind (text is-error) (%call-reload-tool)
             (is (eq t is-error))
             (is (search "reload failed" text))))
      (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test post-reload-hook-runs-after-a-successful-reload
  ;; #78: sm-harness-web-ui installs *POST-RELOAD-HOOK* to re-point CLOG's
  ;; routing and refresh open browser tabs once a reload actually succeeds.
  (let* ((root (temp-data-root))
         (sm-harness::*reload-harness-system* :reload-fixture)
         (called nil)
         (sm-harness:*post-reload-hook* (lambda () (setf called t))))
    (unwind-protect
         (progn
           (%write-reload-fixture root "\"v1\"")
           (%push-fixture-registry root)
           (destructuring-bind (text is-error) (%call-reload-tool)
             (is (null is-error))
             (is (search "reloaded" text)))
           (is (eq t called)))
      (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test post-reload-hook-does-not-run-after-a-failed-reload
  ;; A failed reload's error is already visible in that turn's own tool
  ;; result; nothing successfully reloaded, so nothing should be
  ;; re-pointed or refreshed.
  (let* ((root (temp-data-root))
         (sm-harness::*reload-harness-system* :reload-fixture)
         (called nil)
         (sm-harness:*post-reload-hook* (lambda () (setf called t))))
    (unwind-protect
         (progn
           (%write-reload-fixture root "\"v1\"")
           (%push-fixture-registry root)
           (%call-reload-tool)
           ;; The hook fires on this first, genuinely successful load; only
           ;; the *second* (broken) reload below is under test.
           (setf called nil)
           (sleep 1.1) ; ensure a strictly newer source mtime than the fasl
           (%write-text-file
            (merge-pathnames "fixture.lisp" root)
            (format nil "(in-package #:reload-fixture)~%(defun value ( ~%"))
           (destructuring-bind (text is-error) (%call-reload-tool)
             (is (eq t is-error))
             (is (search "reload failed" text)))
           (is (null called)))
      (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test post-reload-hook-failure-is-folded-into-warnings-not-a-tool-error
  ;; A misbehaving hook (e.g. a browser vanished mid-broadcast) must not
  ;; turn an otherwise-successful reload into a reported failure.
  (let* ((root (temp-data-root))
         (sm-harness::*reload-harness-system* :reload-fixture)
         (sm-harness:*post-reload-hook* (lambda () (error "fixture hook secret"))))
    (unwind-protect
         (progn
           (%write-reload-fixture root "\"v1\"")
           (%push-fixture-registry root)
           (destructuring-bind (text is-error) (%call-reload-tool)
             (is (null is-error))
             (is (search "reloaded" text))
             (is (search "post-reload hook failed" text))
             (is (search "fixture hook secret" text))))
      (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;;;; #146: harness-computed, deterministic added/removed tool-name signal on
;;;; a successful reload_harness whose catalog's tool-name SET actually
;;;; changed. *CAPABILITY-CHANGE-CATALOG-FN* is *RELOAD-HARNESS-TOOL-HANDLER*'s
;;;; own before/after snapshot accessor (tool-catalog.lisp) -- rebound here to
;;;; a closure over the *RELOAD-FIXTURE* package's own VALUE function (already
;;;; defined by %WRITE-RELOAD-FIXTURE above), late-bound via INTERN/FUNCALL so
;;;; it reflects whatever FIXTURE.LISP currently defines, exactly the way
;;;; DEFAULT-TOOL-CATALOG reflects a real reload's own redefinition in
;;;; production. This drives an actual, real ASDF reload for each case
;;;; (empirically verified, not a mock of the diffing logic) -- consistent
;;;; with this file's other tests above.

(defun %tool-catalog-from-names (names)
  (sm-harness::make-tool-catalog
   :servers (list (sm-harness::make-tool-server-definition
                   :name "fixture"
                   :tools (mapcar (lambda (n)
                                    (sm-harness::make-tool-definition :name n :handler 'identity))
                                  names)))))

(defvar *capability-fixture-counter* 0
  "TEMP-DATA-ROOT's own directory name only has one-second resolution
(GET-UNIVERSAL-TIME), so two tests started within the same wall-clock
second -- routine, given how fast this suite runs -- can collide on the
exact same root pathname; ASDF then treats the second test's freshly
written .asd/.lisp pair as already loaded, nothing changed, and silently
keeps serving the first test's stale package contents instead. The
pre-existing reload-fixture tests above never hit this because they all
share one fixed system/package name across the whole file regardless, so a
same-second collision there just means a second test reuses the first
one's already-correct state. These #146 tests below instead need a
genuinely fresh package per test (their assertions depend on exactly what
VALUE returns), so each one gets its own uniquely named scratch system
instead of sharing that fixed name.")

(defun %write-capability-fixture (root name-sym defun-body)
  ;; Each scratch system's own SOURCE FILE is named after NAME-SYM too, not a
  ;; fixed "fixture.lisp" -- TEMP-DATA-ROOT's one-second resolution
  ;; (GET-UNIVERSAL-TIME) means two of these tests started in the same
  ;; wall-clock second, routine given how fast this suite runs, can share
  ;; the exact same ROOT directory; a fixed filename would then let a later
  ;; test's write silently clobber an earlier, still-registered system's
  ;; own source file out from under it.
  (ensure-directories-exist root)
  (let ((name (string-downcase (symbol-name name-sym))))
    (%write-text-file
     (merge-pathnames (format nil "~A.asd" name) root)
     (format nil "(asdf:defsystem #:~A :components ((:file ~S)))~%" name name))
    (%write-text-file
     (merge-pathnames (format nil "~A.lisp" name) root)
     (format nil "(defpackage #:~A (:use #:cl) (:export #:value))~%(in-package #:~A)~%(defun value () ~A)~%"
             name name defun-body))
    root))

(defmacro %with-capability-fixture ((system-var) &body body)
  "Binds SYSTEM-VAR to a keyword naming a scratch system unique to this
macro expansion (see *CAPABILITY-FIXTURE-COUNTER*'s docstring), rebinds
*RELOAD-HARNESS-SYSTEM* to it and *CAPABILITY-CHANGE-CATALOG-FN* to a
closure reading that same system's own VALUE function -- late-bound via
INTERN/FUNCALL, exactly like DEFAULT-TOOL-CATALOG reflects a real reload's
own redefinition in production -- around BODY, restoring both afterward."
  (let ((name (gensym "SYSTEM")))
    `(let* ((,name (intern (format nil "CAPABILITY-FIXTURE-~D" (incf *capability-fixture-counter*))
                            "KEYWORD"))
            (,system-var ,name)
            (sm-harness::*reload-harness-system* ,name)
            (sm-harness::*capability-change-catalog-fn*
              (lambda ()
                ;; The scratch package does not exist yet before this
                ;; fixture's very first successful load in a fresh image --
                ;; nothing to diff against yet, so an empty catalog is the
                ;; correct "before" snapshot for that call, not an error.
                (let ((pkg (find-package (symbol-name ,name))))
                  (%tool-catalog-from-names
                   (if pkg (funcall (intern "VALUE" pkg)) '()))))))
       (unwind-protect (progn ,@body)
         (setf sm-harness::*capability-change-catalog-fn* 'sm-harness:default-tool-catalog)))))

(defun %call-reload-tool-for-session (session-id &key force)
  (let ((arguments (make-hash-table :test #'equal)))
    (when force (setf (gethash "force" arguments) t))
    (multiple-value-bind (text is-error)
        (sm-harness::%reload-harness-tool-handler
         arguments (list :calling-session-id session-id))
      (list text is-error))))

(test reload-harness-tool-records-a-capability-change-on-an-added-tool
  (let ((root (temp-data-root)))
    (%with-capability-fixture (sys)
      (unwind-protect
           (progn
             (%write-capability-fixture root sys "(list \"a\" \"b\")")
             (%push-fixture-registry root)
             ;; Baseline load: no capability change is recorded (nothing to
             ;; diff against yet in this fresh image), and no CALLING-SESSION-ID
             ;; is under test here.
             (%call-reload-tool)
             (sleep 1.1) ; ensure a strictly newer source mtime than the fasl
             (%write-capability-fixture root sys "(list \"a\" \"b\" \"c\")")
             (destructuring-bind (text is-error)
                 (%call-reload-tool-for-session "sess-146-added")
               (is (null is-error))
               (is (search "reloaded" text)))
             (let ((cc (gethash "sess-146-added" sm-harness::*pending-capability-changes*)))
               (is (not (null cc)))
               (is (equal '("c") (getf cc :added)))
               (is (null (getf cc :removed)))))
        (remhash "sess-146-added" sm-harness::*pending-capability-changes*)
        (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test reload-harness-tool-records-a-capability-change-on-a-removed-tool
  (let ((root (temp-data-root)))
    (%with-capability-fixture (sys)
      (unwind-protect
           (progn
             (%write-capability-fixture root sys "(list \"a\" \"b\" \"c\")")
             (%push-fixture-registry root)
             (%call-reload-tool)
             (sleep 1.1)
             (%write-capability-fixture root sys "(list \"a\" \"b\")")
             (destructuring-bind (text is-error)
                 (%call-reload-tool-for-session "sess-146-removed")
               (is (null is-error))
               (is (search "reloaded" text)))
             (let ((cc (gethash "sess-146-removed" sm-harness::*pending-capability-changes*)))
               (is (not (null cc)))
               (is (null (getf cc :added)))
               (is (equal '("c") (getf cc :removed)))))
        (remhash "sess-146-removed" sm-harness::*pending-capability-changes*)
        (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test reload-harness-tool-records-no-capability-change-when-the-name-set-is-unchanged
  ;; A reload that only changes a tool handler's own body (or, as here,
  ;; nothing at all) with an identical tool-name set is not a "capability
  ;; change" for #146's purposes -- #76's existing generic follow-up already
  ;; covers a plain body-only edit.
  (let ((root (temp-data-root)))
    (%with-capability-fixture (sys)
      (unwind-protect
           (progn
             (%write-capability-fixture root sys "(list \"a\" \"b\")")
             (%push-fixture-registry root)
             (%call-reload-tool)
             (sleep 1.1)
             (%write-capability-fixture root sys "(list \"a\" \"b\")")
             (destructuring-bind (text is-error)
                 (%call-reload-tool-for-session "sess-146-nochange")
               (is (null is-error))
               (is (search "reloaded" text)))
             (is (null (gethash "sess-146-nochange" sm-harness::*pending-capability-changes*))))
        (remhash "sess-146-nochange" sm-harness::*pending-capability-changes*)
        (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test reload-harness-tool-records-no-capability-change-on-a-failed-reload
  (let ((root (temp-data-root)))
    (%with-capability-fixture (sys)
      (unwind-protect
           (progn
             (%write-capability-fixture root sys "(list \"a\" \"b\")")
             (%push-fixture-registry root)
             (%call-reload-tool)
             (sleep 1.1)
             (%write-text-file
              (merge-pathnames (format nil "~A.lisp" (string-downcase (symbol-name sys))) root)
              (format nil "(in-package #:~A)~%(defun value ( ~%" (string-downcase (symbol-name sys))))
             (destructuring-bind (text is-error)
                 (%call-reload-tool-for-session "sess-146-failed")
               (is (eq t is-error))
               (is (search "reload failed" text)))
             (is (null (gethash "sess-146-failed" sm-harness::*pending-capability-changes*))))
        (remhash "sess-146-failed" sm-harness::*pending-capability-changes*)
        (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test reload-harness-tool-records-no-capability-change-without-a-calling-session-id
  ;; CONTEXT with no :CALLING-SESSION-ID at all (e.g. %CALL-RELOAD-TOOL's own
  ;; NIL context, matching a headless/standalone call) has nowhere to record
  ;; a diff against -- silently skipped, never an error, since this signal is
  ;; a purely additive extra on top of RELOAD_HARNESS's own core contract.
  (let ((root (temp-data-root))
        (before-count 0))
    (%with-capability-fixture (sys)
      (unwind-protect
           (progn
             (%write-capability-fixture root sys "(list \"a\" \"b\")")
             (%push-fixture-registry root)
             (%call-reload-tool)
             (sleep 1.1)
             (setf before-count (hash-table-count sm-harness::*pending-capability-changes*))
             (%write-capability-fixture root sys "(list \"a\" \"b\" \"c\")")
             (destructuring-bind (text is-error) (%call-reload-tool)
               (is (null is-error))
               (is (search "reloaded" text)))
             (is (= before-count (hash-table-count sm-harness::*pending-capability-changes*))))
        (setf asdf:*central-registry* (remove root asdf:*central-registry* :test #'equal))
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))
