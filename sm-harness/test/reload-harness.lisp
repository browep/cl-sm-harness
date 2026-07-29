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
