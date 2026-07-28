(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(test safe-error-payload-never-renders-sdk-or-fixture-detail
  (let ((payload (sm-harness::safe-error-payload
                  (make-condition 'simple-error
                                  :format-control "fixture connect secret: ~A"
                                  :format-arguments '("credential")))))
    (is (string= "internal error" (getf payload :message)))
    (is (not (search "secret" (getf payload :message))))))

(test connect-failure-keeps-precanonical-prompt-out-of-durable-transcript
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-instance 'harness-fake-transport
                                       :start-error "fixture connect secret")))))
         (snapshot (sm-harness:start-session h :title "connect failure"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "must remain draft")
           (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))) )
           (let ((reopened (sm-harness:open-session h session-id)))
             (is (null (sm-harness:session-snapshot-canonical-id reopened)))
             (is (null (sm-harness:session-snapshot-transcript reopened)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test read-failure-after-canonical-turn-retries-through-a-resumed-replacement-client
  (let* ((root (temp-data-root))
         (transports '())
         (options-seen '())
         (factory-count 0)
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (push options options-seen)
                        (let ((transport
                                (if (zerop factory-count)
                                    (make-simple-turn-transport)
                                    (make-instance 'harness-fake-transport
                                                   :chunks (list (concatenate 'string +init-ok+ +nl+))
                                                   :read-error-after 1))))
                          (incf factory-count)
                          (push transport transports)
                          transport)))))
         (snapshot (sm-harness:start-session h :title "canonical read failure"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "canonical first turn")
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (sm-harness:session-snapshot-canonical-id
                            (sm-harness:open-session h session-id))))))
           (let ((first-runtime (sm-harness::%get-runtime h session-id)))
             (setf (sm-harness::session-runtime-last-activity first-runtime) 0))
           (is (equal (list session-id) (sm-harness:evict-idle-sessions h)))
           (sm-harness:open-session h session-id)
           (sm-harness:submit-turn h session-id "read failure after resume")
           (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))))
           (let* ((runtime (sm-harness::%get-runtime h session-id))
                  (reopened (sm-harness:open-session h session-id))
                  (replacement (first transports))
                  (replacement-options (first options-seen)))
             (is (string= "canon-42" (sm-harness:session-snapshot-canonical-id reopened)))
             (is (null (sm-harness::session-record-active-turn-id
                        (sm-harness::session-runtime-record runtime))))
             (is (null (sm-harness::session-runtime-client runtime)))
             (is (eq :disconnect (fake-closed-reason replacement)))
             (is (= 2 (fake-read-count replacement)))
             (is (string= "canon-42"
                          (claude-agent-sdk-cl:agent-options-resume replacement-options)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test malformed-sdk-event-is-safe-terminal-and-a-fresh-retry-can-complete
  (let* ((root (temp-data-root))
         (factory-count 0)
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (incf factory-count)
                        (if (= factory-count 1)
                            (make-instance 'harness-fake-transport
                                           :chunks (list (concatenate 'string +init-ok+ +nl+)
                                                         "{not valid JSON}\n"))
                            (make-simple-turn-transport))))))
         (snapshot (sm-harness:start-session h :title "malformed event"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "malformed fixture turn")
           (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))) )
           (let ((reopened (sm-harness:open-session h session-id)))
             (is (null (sm-harness:session-snapshot-canonical-id reopened))))
           (sm-harness:submit-turn h session-id "fresh valid retry")
           (is (wait-until
                (lambda () (string= "canon-42"
                                     (sm-harness:session-snapshot-canonical-id
                                      (sm-harness:open-session h session-id)))))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test session-start-tool-handler-failure-emits-correlated-safe-mcp-error-once
  (let* ((root (temp-data-root))
         (calls 0)
         (catalog (sm-harness:default-tool-catalog))
         (tool (first (sm-harness::tool-server-definition-tools
                       (first (sm-harness::tool-catalog-servers catalog)))))
         (transport (make-catalog-tool-turn-transport))
         (h (sm-harness:make-harness
             :catalog catalog
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "failing control handler"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (setf (sm-harness::tool-definition-handler tool)
          (lambda (arguments context)
            (declare (ignore arguments context))
            (incf calls)
            (error "handler secret must never cross the MCP wire")))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "call failing tool")
           (is (wait-until (lambda () (= 1 calls))))
           (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
           (is (= 1 calls))
           (let* ((wire (find-if (lambda (line) (search "mcp_response" line))
                                 (fake-writes transport)))
                  (outer (yason:parse wire))
                  (response (gethash "response" outer))
                  (payload (gethash "response" response))
                  (mcp (gethash "mcp_response" payload))
                  (error (gethash "error" mcp)))
             (is (string= "success" (gethash "subtype" response)))
             (is (string= "tool-call-1" (gethash "request_id" response)))
             (is (= 7 (gethash "id" mcp)))
             (is (= -32603 (gethash "code" error)))
             (is (not (search "secret" (gethash "message" error)))))
           (is (= 1 (count-if (lambda (line) (search "mcp_response" line))
                               (fake-writes transport)))) )
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

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
