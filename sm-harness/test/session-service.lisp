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
