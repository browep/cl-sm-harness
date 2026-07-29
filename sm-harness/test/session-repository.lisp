(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(test repository-roundtrip-and-list-order
  (let* ((root (temp-data-root))
         (repo (sm-harness::open-session-repository :root root :project-key "p1"))
         (a (sm-harness::make-session-record :title "A"))
         (b (sm-harness::make-session-record :title "B")))
    (unwind-protect
         (progn
           (sm-harness::repository-save-session repo a)
           (sleep 1.1)
           (sm-harness::repository-save-session repo b)
           (let ((list (sm-harness::repository-list-sessions repo)))
             (is (>= (length list) 2))
             (is (string= "B" (sm-harness:session-summary-title (first list)))))
           (let ((loaded (sm-harness::repository-load-session
                          repo (sm-harness::session-record-id a))))
             (is (string= "A" (sm-harness::session-record-title loaded)))))
      (sm-harness::close-session-repository repo)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test repository-recovers-from-corrupt-index
  (let* ((root (temp-data-root))
         (repo (sm-harness::open-session-repository :root root :project-key "p1")))
    (unwind-protect
         (progn
           (with-open-file (out (sm-harness::%repo-index-path repo)
                                :direction :output :if-does-not-exist :create
                                :if-exists :supersede)
             (write-string "{ broken json" out))
           (is (null (sm-harness::repository-list-sessions repo))))
      (sm-harness::close-session-repository repo)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test repository-recovers-stale-lock-from-prior-boot
  (let ((root (temp-data-root)))
    (unwind-protect
         (progn
           (ensure-directories-exist root)
           (with-open-file (out (merge-pathnames ".harness.lock" root)
                                :direction :output :if-does-not-exist :create
                                :if-exists :supersede)
             (write-string "boot_id=previous-boot\n" out))
           (let ((repo (sm-harness::open-session-repository :root root :project-key "p1")))
             (is (not (null repo)))
             (sm-harness::close-session-repository repo)))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test repository-recovers-same-boot-lock-with-no-live-owner
  ;; The #83 incident shape: the previous instance crashed (or its shutdown
  ;; handler did, #82) in THIS boot, leaving the lock file behind.  With no
  ;; live process holding the kernel fcntl lock, the next open must recover
  ;; automatically -- the old boot-id heuristic failed closed here forever,
  ;; requiring manual lock-file deletion before the service could start.
  (let ((root (temp-data-root)))
    (unwind-protect
         (progn
           (ensure-directories-exist root)
           (with-open-file (out (merge-pathnames ".harness.lock" root)
                                :direction :output :if-does-not-exist :create
                                :if-exists :supersede)
             (format out "boot_id=~A~%pid=99999999~%"
                     (sm-harness::%current-boot-id)))
           (let ((repo (sm-harness::open-session-repository :root root :project-key "p1")))
             (is (not (null repo)))
             (sm-harness::close-session-repository repo)))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test repository-fails-closed-while-this-process-holds-the-lock
  ;; fcntl record locks never conflict within one process, so same-process
  ;; exclusion comes from the in-process registry -- and must release on
  ;; close so the root is reusable.
  (let* ((root (temp-data-root))
         (repo1 (sm-harness::open-session-repository :root root :project-key "p1")))
    (unwind-protect
         (progn
           (signals sm-harness:harness-state-error
             (sm-harness::open-session-repository :root root :project-key "p2"))
           (sm-harness::close-session-repository repo1)
           (let ((repo3 (sm-harness::open-session-repository :root root :project-key "p3")))
             (is (not (null repo3)))
             (sm-harness::close-session-repository repo3)))
      (ignore-errors (sm-harness::close-session-repository repo1))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test repository-fails-closed-while-another-live-process-holds-the-lock
  ;; A genuinely live owner in ANOTHER process must still be refused --
  ;; recovery is only ever from the dead.  The helper subprocess takes the
  ;; same fcntl write lock production takes, signals readiness via a marker
  ;; file, and holds the lock until killed; after its death the kernel has
  ;; released the lock and the open must succeed with no cleanup at all.
  (let* ((root (temp-data-root))
         (lock-path (progn (ensure-directories-exist root)
                           (merge-pathnames ".harness.lock" root)))
         (marker (merge-pathnames "locker-ready" root))
         ;; Two separate --eval strings: sb-posix symbols cannot even be
         ;; READ until the contrib is loaded, and each --eval is read only
         ;; just before its own evaluation.
         (script (format nil "(let ((s (open ~S :direction :output :if-exists :overwrite :if-does-not-exist :create))) (sb-posix:fcntl (sb-sys:fd-stream-fd s) sb-posix:f-setlk (make-instance 'sb-posix:flock :type sb-posix:f-wrlck :whence sb-posix:seek-set :start 0 :len 0)) (with-open-file (m ~S :direction :output :if-does-not-exist :create) (write-string \"locked\" m)) (sleep 30))"
                         (namestring lock-path) (namestring marker)))
         (process (sb-ext:run-program "sbcl"
                                      (list "--non-interactive" "--no-sysinit"
                                            "--no-userinit"
                                            "--eval" "(require :sb-posix)"
                                            "--eval" script)
                                      :wait nil :search t)))
    (unwind-protect
         (progn
           (is (wait-until (lambda () (probe-file marker)) :timeout 15))
           (signals sm-harness:harness-state-error
             (sm-harness::open-session-repository :root root :project-key "p1"))
           (sb-ext:process-kill process sb-posix:sigkill)
           (is (wait-until (lambda ()
                             (not (eq (sb-ext:process-status process) :running)))
                           :timeout 5))
           (let ((repo (sm-harness::open-session-repository :root root :project-key "p1")))
             (is (not (null repo)))
             (sm-harness::close-session-repository repo)))
      (when (eq (sb-ext:process-status process) :running)
        (ignore-errors (sb-ext:process-kill process sb-posix:sigkill)))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
