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

(test repository-roundtrip-persists-backend-and-model
  "#106: an explicit backend/model choice survives a save/load cycle, and a
record with neither field (pre-#106 data on disk) still decodes to the
sole default backend with no model override, matching the behavior any
already-persisted session had before this feature existed."
  (let* ((root (temp-data-root))
         (repo (sm-harness::open-session-repository :root root :project-key "p1"))
         (a (sm-harness::make-session-record :title "A" :backend "claude" :model "opus")))
    (unwind-protect
         (progn
           (sm-harness::repository-save-session repo a)
           (let ((loaded (sm-harness::repository-load-session
                          repo (sm-harness::session-record-id a))))
             (is (string= "claude" (sm-harness::session-record-backend loaded)))
             (is (string= "opus" (sm-harness::session-record-model loaded))))
           (let ((summary (find (sm-harness::session-record-id a)
                                (sm-harness::repository-list-sessions repo)
                                :key #'sm-harness:session-summary-id :test #'string=)))
             (is (string= "opus" (sm-harness:session-summary-model summary))))
           ;; Simulate a pre-#106 record: write raw JSON with neither field.
           (let ((path (sm-harness::%repo-session-path repo "legacy-1")))
             (ensure-directories-exist path)
             (with-open-file (out path :direction :output :if-does-not-exist :create
                                  :if-exists :supersede)
               (write-string "{\"id\":\"legacy-1\",\"title\":\"Legacy\"}" out)))
           (let ((loaded (sm-harness::repository-load-session repo "legacy-1")))
             (is (string= "claude" (sm-harness::session-record-backend loaded)))
             (is (null (sm-harness::session-record-model loaded)))))
      (sm-harness::close-session-repository repo)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test repository-roundtrip-persists-turn-count-and-created-at
  "#111: the home-screen chip needs a turn count and a session start time
without re-reading every session's full transcript from disk, so both are
carried in the lightweight index summary, not just the per-session file."
  (let* ((root (temp-data-root))
         (repo (sm-harness::open-session-repository :root root :project-key "p1"))
         (a (sm-harness::make-session-record :title "A")))
    (unwind-protect
         (progn
           (setf (sm-harness::session-record-transcript a)
                 (list (sm-harness::make-transcript-entry :role "user" :text "hi")
                       (sm-harness::make-transcript-entry :role "assistant" :text "hello")
                       (sm-harness::make-transcript-entry :role "user" :text "again"
                                                          :kind "synthetic")))
           (sm-harness::repository-save-session repo a)
           (let ((summary (find (sm-harness::session-record-id a)
                                (sm-harness::repository-list-sessions repo)
                                :key #'sm-harness:session-summary-id :test #'string=)))
             (is (= 2 (sm-harness:session-summary-turn-count summary)))
             (is (string= (sm-harness::session-record-created-at a)
                         (sm-harness:session-summary-created-at summary))))
           ;; Simulate a pre-#111 index entry: neither field on disk.
           (let ((path (sm-harness::%repo-session-path repo "legacy-2")))
             (ensure-directories-exist path)
             (with-open-file (out path :direction :output :if-does-not-exist :create
                                  :if-exists :supersede)
               (write-string "{\"id\":\"legacy-2\",\"title\":\"Legacy\"}" out)))
           (with-open-file (out (sm-harness::%repo-index-path repo)
                                :direction :output :if-does-not-exist :create
                                :if-exists :supersede)
             (write-string "{\"sessions\":[{\"id\":\"legacy-2\",\"title\":\"Legacy\"}]}" out))
           (let ((summary (find "legacy-2" (sm-harness::repository-list-sessions repo)
                                :key #'sm-harness:session-summary-id :test #'string=)))
             (is (= 0 (sm-harness:session-summary-turn-count summary)))
             (is (string= "" (sm-harness:session-summary-created-at summary)))))
      (sm-harness::close-session-repository repo)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
(test repository-roundtrip-persists-parent-session-id-and-filters-subagents
  "#142: PARENT-SESSION-ID round-trips through both the per-session file and
the lightweight index the way BACKEND/MODEL (#106) already do, and
REPOSITORY-LIST-SESSIONS omits any subagent (non-NIL PARENT-SESSION-ID) by
default -- the filter lives at this layer, not in any one caller -- while
INCLUDE-SUBAGENTS and a PARENT-SESSION-ID query both still reach it."
  (let* ((root (temp-data-root))
         (repo (sm-harness::open-session-repository :root root :project-key "p1"))
         (parent (sm-harness::make-session-record :title "Parent"))
         (child (sm-harness::make-session-record
                 :title "Child"
                 :parent-session-id (sm-harness::session-record-id parent))))
    (unwind-protect
         (progn
           (sm-harness::repository-save-session repo parent)
           (sm-harness::repository-save-session repo child)
           (let ((loaded (sm-harness::repository-load-session
                          repo (sm-harness::session-record-id child))))
             (is (string= (sm-harness::session-record-id parent)
                         (sm-harness::session-record-parent-session-id loaded))))
           ;; Default LIST-SESSIONS: parent shows up, child does not.
           (let ((ids (mapcar #'sm-harness:session-summary-id
                              (sm-harness::repository-list-sessions repo))))
             (is (member (sm-harness::session-record-id parent) ids :test #'string=))
             (is (not (member (sm-harness::session-record-id child) ids :test #'string=))))
           ;; :INCLUDE-SUBAGENTS T brings it back, with the field populated.
           (let ((summary (find (sm-harness::session-record-id child)
                                (sm-harness::repository-list-sessions repo :include-subagents t)
                                :key #'sm-harness:session-summary-id :test #'string=)))
             (is (not (null summary)))
             (is (string= (sm-harness::session-record-id parent)
                         (sm-harness:session-summary-parent-session-id summary))))
           ;; :PARENT-SESSION-ID queries the reverse edge directly.
           (let ((ids (mapcar #'sm-harness:session-summary-id
                              (sm-harness::repository-list-sessions
                               repo :parent-session-id (sm-harness::session-record-id parent)))))
             (is (equal (list (sm-harness::session-record-id child)) ids)))
           ;; An ordinary top-level session has no parent-session-id at all.
           (let ((summary (find (sm-harness::session-record-id parent)
                                (sm-harness::repository-list-sessions repo)
                                :key #'sm-harness:session-summary-id :test #'string=)))
             (is (null (sm-harness:session-summary-parent-session-id summary)))))
      (sm-harness::close-session-repository repo)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
