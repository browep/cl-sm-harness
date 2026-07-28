(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(test interrupt-turn-writes-control-without-waiting-for-the-worker-mailbox
  (let* ((root (temp-data-root))
         (transport (make-instance 'harness-fake-transport
                                   :chunks (list (concatenate 'string +init-ok+ +nl+))))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root)))
         (snapshot (sm-harness:start-session h :title "interrupt"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (rt (sm-harness::%get-runtime h session-id))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (sb-thread:with-mutex ((sm-harness::session-runtime-lock rt))
             (setf (sm-harness::session-runtime-client rt) client
                   (sm-harness::session-record-active-turn-id
                    (sm-harness::session-runtime-record rt)) "turn-stop"))
           (is (string= "turn-stop" (sm-harness:interrupt-turn h session-id "turn-stop")))
           (is (eq :stopping (sm-harness::session-record-status
                              (sm-harness::session-runtime-record rt))))
           (let ((wire (first (fake-writes transport))))
             (is (search "\"subtype\":\"interrupt\"" wire)))
           (is (null (sm-harness:interrupt-turn h session-id "stale-turn"))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test deadline-watchdog-targets-its-active-turn-with-writer-only-interrupt
  (let* ((root (temp-data-root))
         (transport (make-instance 'harness-fake-transport
                                   :chunks (list (concatenate 'string +init-ok+ +nl+))))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config :data-root root :turn-deadline-seconds 1)))
         (snapshot (sm-harness:start-session h :title "deadline"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (rt (sm-harness::%get-runtime h session-id))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (sb-thread:with-mutex ((sm-harness::session-runtime-lock rt))
             (setf (sm-harness::session-runtime-client rt) client
                   (sm-harness::session-record-active-turn-id
                    (sm-harness::session-runtime-record rt)) "turn-deadline"))
           (sm-harness::%start-deadline-watchdog h rt "turn-deadline")
           (is (wait-until (lambda () (= 2 (length (fake-writes transport)))) :timeout 3))
           (is (eq :stopping (sm-harness::session-record-status
                              (sm-harness::session-runtime-record rt))))
           (is (search "\"subtype\":\"interrupt\"" (first (fake-writes transport)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test catalog-tools-use-an-automatic-no-approval-session-policy
  "The explicit catalog controls availability; the harness never installs approval policy."
  (let* ((root (temp-data-root))
         (catalog (sm-harness:default-tool-catalog))
         (policy (sm-harness:default-tool-policy))
         (opts (sm-harness::build-agent-options catalog policy))
         (transport nil)
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options))
                                           (setf transport (make-catalog-tool-turn-transport)))))))
    (unwind-protect
         (progn
           (is (eq :none (claude-agent-sdk-cl:agent-options-builtin-tools opts)))
           (is (eq t (claude-agent-sdk-cl:agent-options-strict-mcp-config opts)))
           (is (= 1 (length (claude-agent-sdk-cl:agent-options-sdk-mcp-servers opts))))
           (is (null (claude-agent-sdk-cl:agent-options-allowed-tools opts)))
           (is (null (claude-agent-sdk-cl:agent-options-disallowed-tools opts)))
           (is (string= "bypassPermissions"
                        (claude-agent-sdk-cl:agent-options-permission-mode opts)))
           (let* ((snapshot (sm-harness:start-session h :title "automatic tools"))
                  (session-id (sm-harness:session-snapshot-id snapshot))
                  (runtime (sm-harness::%get-runtime h session-id)))
             (sm-harness:submit-turn h session-id "run the catalog tool")
             (is (wait-until (lambda () (sm-harness::session-runtime-client runtime))))
             (is (null (claude-agent-sdk-cl:client-control-handlers
                        (sm-harness::session-runtime-client runtime))))
             (is (wait-until (lambda () (>= (length (fake-writes transport)) 3))))
             (is (string= "echo: automatic"
                          (echoed-mcp-result-text (first (fake-writes transport)))))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
