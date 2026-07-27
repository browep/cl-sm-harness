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
