(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(test headless-fixture-session-turn
  "Non-browser consumer: sm-harness alone completes a fixture turn."
  (let* ((root (temp-data-root))
         (events '())
         (lock (sb-thread:make-mutex))
         (transport nil)
         (cfg (sm-harness:make-harness-config
               :data-root root
               :project-key "e2e"
               :turn-deadline-seconds 10
               :transport-factory
               (lambda (options)
                 (declare (ignore options))
                 (setf transport (make-simple-turn-transport))
                 transport)))
         (h (sm-harness:make-harness :config cfg)))
    (unwind-protect
         (progn
           (let ((snap (sm-harness:start-session h :title "T1")))
             (is (stringp (sm-harness:session-snapshot-id snap)))
             (is (eq :ready (sm-harness:session-snapshot-status snap)))
             (multiple-value-bind (snapshot listener-id cursor)
                 (sm-harness:attach-session-listener
                  h (sm-harness:session-snapshot-id snap)
                  :callback (lambda (ev)
                              (sb-thread:with-mutex (lock)
                                (push ev events))))
               (declare (ignore snapshot cursor))
               (is (stringp listener-id))
               (let ((turn (sm-harness:submit-turn
                            h (sm-harness:session-snapshot-id snap)
                            "hello fixture")))
                 (is (stringp turn))
                 (is (wait-until
                      (lambda ()
                        (sb-thread:with-mutex (lock)
                          (find :terminal events :key #'sm-harness:event-type)))
                      :timeout 5.0)))
               (let ((listed (sm-harness:list-sessions h)))
                 (is (= 1 (length listed)))
                 (is (string= "canon-42"
                              (sm-harness:session-summary-canonical-id (first listed)))))
               ;; reopen / resume path keeps durable transcript
               (sm-harness:detach-session-listener
                h (sm-harness:session-snapshot-id snap) listener-id)
               (let ((again (sm-harness:open-session
                             h (sm-harness:session-snapshot-id snap))))
                 (is (>= (length (sm-harness:session-snapshot-transcript again)) 1))))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test idle-eviction-reopens-with-canonical-resume-and-fresh-catalog
  (let* ((root (temp-data-root))
         (options-seen '())
         (cfg (sm-harness:make-harness-config
               :data-root root :idle-ttl-seconds 1
               :transport-factory
               (lambda (options)
                 (push options options-seen)
                 (make-simple-turn-transport))))
         (h (sm-harness:make-harness :config cfg)))
    (unwind-protect
         (let* ((snap (sm-harness:start-session h :title "resume"))
                (sid (sm-harness:session-snapshot-id snap))
                (rt (sm-harness::%get-runtime h sid)))
           (sm-harness:submit-turn h sid "first turn")
           (is (wait-until (lambda ()
                             (string= "canon-42"
                                      (sm-harness:session-summary-canonical-id
                                       (first (sm-harness:list-sessions h)))))))
           (setf (sm-harness::session-runtime-last-activity rt) 0)
           (is (equal (list sid) (sm-harness:evict-idle-sessions h)))
           (is (null (sm-harness::%get-runtime h sid :errorp nil)))
           (sm-harness:open-session h sid)
           (sm-harness:submit-turn h sid "resumed turn")
           (is (wait-until (lambda () (>= (length options-seen) 2))))
           (let ((resumed-options (first options-seen)))
             (is (string= "canon-42" (claude-agent-sdk-cl:agent-options-resume resumed-options)))
             (is (plusp (length (claude-agent-sdk-cl:agent-options-sdk-mcp-servers resumed-options))))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test empty-prompt-rejected
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root))))
    (unwind-protect
         (let ((snap (sm-harness:start-session h)))
           (signals sm-harness:harness-input-error
             (sm-harness:submit-turn h (sm-harness:session-snapshot-id snap) "   ")))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test idle-interrupt-is-safe
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root))))
    (unwind-protect
         (let ((snap (sm-harness:start-session h)))
           (is (null (sm-harness:interrupt-turn h (sm-harness:session-snapshot-id snap)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test start-session-rejects-unknown-backend-or-model
  "#106: the static catalog is the single source of truth for valid
backend/model choices; an unknown value is a caller mistake (bad UI state,
stale client), not a silently-accepted no-op."
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root))))
    (unwind-protect
         (progn
           (signals sm-harness:harness-input-error
             (sm-harness:start-session h :backend "vertex"))
           (signals sm-harness:harness-input-error
             (sm-harness:start-session h :model "gpt-5")))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test start-session-defaults-backend-and-persists-explicit-model
  "A session created with no :BACKEND/:MODEL still gets the sole default
backend (#106 keeps the field always populated for display), but MODEL
stays NIL -- HARNESS-CONFIG-MODEL (or ultimately the CLI's own default)
still governs exactly as it did before #106. A session created with an
explicit model carries it through SESSION-SNAPSHOT/SESSION-SUMMARY and
survives a reopen from durable storage."
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root))))
    (unwind-protect
         (progn
           (let ((snap (sm-harness:start-session h)))
             (is (string= "claude" (sm-harness:session-snapshot-backend snap)))
             (is (null (sm-harness:session-snapshot-model snap))))
           (let* ((snap (sm-harness:start-session h :backend "claude" :model "opus"))
                  (sid (sm-harness:session-snapshot-id snap)))
             (is (string= "claude" (sm-harness:session-snapshot-backend snap)))
             (is (string= "opus" (sm-harness:session-snapshot-model snap)))
             (let ((summary (find sid (sm-harness:list-sessions h)
                                  :key #'sm-harness:session-summary-id :test #'string=)))
               (is (string= "opus" (sm-harness:session-summary-model summary))))
             (let ((reopened (sm-harness:open-session h sid)))
               (is (string= "opus" (sm-harness:session-snapshot-model reopened))))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test session-model-override-reaches-agent-options
  "The per-session MODEL, when set, must actually reach the CLI-facing
AGENT-OPTIONS (src/transport/subprocess-query.lisp turns it into
--model), overriding HARNESS-CONFIG-MODEL rather than being silently
dropped by the runtime layer."
  (let* ((root (temp-data-root))
         (options-seen '())
         (cfg (sm-harness:make-harness-config
               :data-root root
               :transport-factory
               (lambda (options)
                 (push options options-seen)
                 (make-simple-turn-transport))))
         (h (sm-harness:make-harness :config cfg)))
    (unwind-protect
         (let* ((snap (sm-harness:start-session h :model "haiku"))
                (sid (sm-harness:session-snapshot-id snap)))
           (sm-harness:submit-turn h sid "hello")
           (is (wait-until (lambda () options-seen)))
           (is (string= "haiku" (claude-agent-sdk-cl:agent-options-model (first options-seen)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test static-backend-model-catalog-shape
  "#106: the catalog itself is the contract the web UI's dropdowns and
info panel are built from -- assert its shape and the defaults directly,
independent of any session."
  (let ((claude (sm-harness:find-backend "claude")))
    (is (not (null claude)))
    (is (string= "Claude" (sm-harness:backend-descriptor-label claude)))
    (is (member "sonnet" (sm-harness:backend-descriptor-models claude)
               :key #'sm-harness:model-descriptor-id :test #'string=)
        "sonnet must be in the catalog")
    (is (sm-harness:valid-backend-id-p sm-harness:*default-backend-id*))
    (is (sm-harness:valid-model-id-p sm-harness:*default-backend-id*
                                     sm-harness:*default-model-id*))
    (is (null (sm-harness:find-backend "vertex")))
    (is (null (sm-harness:find-model "claude" "gpt-5")))))
