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

(test one-shot-precanonical-save-failure-never-commits-the-unpersisted-prompt
  (let* ((root (temp-data-root))
         (armed t)
         (original (symbol-function 'sm-harness::repository-save-session))
         (h nil))
    (unwind-protect
         (progn
           ;; The first transcript-bearing save fails; the existing error path
           ;; subsequently writes the mutated in-memory record, which this test
           ;; must catch until the persistence boundary becomes transactional.
           (setf (symbol-function 'sm-harness::repository-save-session)
                 (lambda (repo rec)
                   (if (and armed (sm-harness::session-record-transcript rec))
                       (progn
                         (setf armed nil)
                         (error 'sm-harness:harness-state-error
                                :message "fixture persistence secret"))
                       (funcall original repo rec))))
           (setf h (sm-harness:make-harness
                    :config (sm-harness:make-harness-config
                             :data-root root
                             :transport-factory
                             (lambda (options)
                               (declare (ignore options))
                               (make-simple-turn-transport)))))
           (let* ((snapshot (sm-harness:start-session h :title "save failure"))
                  (session-id (sm-harness:session-snapshot-id snapshot)))
             (sm-harness:submit-turn h session-id "must not become durable")
             (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))))
             (let ((reopened (sm-harness:open-session h session-id)))
               (is (null (sm-harness:session-snapshot-canonical-id reopened)))
               (is (null (sm-harness:session-snapshot-transcript reopened))))))
      (setf (symbol-function 'sm-harness::repository-save-session) original)
      (when h (sm-harness:close-harness h))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test one-shot-postcanonical-save-failure-restores-the-last-committed-identity
  (let* ((root (temp-data-root))
         (armed t)
         (original (symbol-function 'sm-harness::repository-save-session))
         (h nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'sm-harness::repository-save-session)
                 (lambda (repo rec)
                   (if (and armed (sm-harness::session-record-canonical-id rec))
                       (progn
                         (setf armed nil)
                         (error 'sm-harness:harness-state-error
                                :message "fixture terminal persistence secret"))
                       (funcall original repo rec))))
           (setf h (sm-harness:make-harness
                    :config (sm-harness:make-harness-config
                             :data-root root
                             :transport-factory
                             (lambda (options)
                               (declare (ignore options))
                               (make-simple-turn-transport)))))
           (let* ((snapshot (sm-harness:start-session h :title "terminal save failure"))
                  (session-id (sm-harness:session-snapshot-id snapshot)))
             (sm-harness:submit-turn h session-id "committed user only")
             (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))))
             (let ((reopened (sm-harness::repository-load-session
                              (sm-harness::harness-repository h) session-id)))
               (is (null (sm-harness::session-record-canonical-id reopened)))
               (is (= 1 (length (sm-harness::session-record-transcript reopened))))
               (is (string= "committed user only"
                            (sm-harness::transcript-entry-text
                             (first (sm-harness::session-record-transcript reopened))))))))
      (setf (symbol-function 'sm-harness::repository-save-session) original)
      (when h (sm-harness:close-harness h))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test one-shot-postcanonical-save-failure-then-retry-recovers-durable-state
  (let* ((root (temp-data-root))
         (armed t)
         (original (symbol-function 'sm-harness::repository-save-session))
         (h nil))
    (unwind-protect
         (progn
           (setf (symbol-function 'sm-harness::repository-save-session)
                 (lambda (repo rec)
                   (if (and armed (sm-harness::session-record-canonical-id rec))
                       (progn
                         (setf armed nil)
                         (error 'sm-harness:harness-state-error
                                :message "fixture terminal persistence secret"))
                       (funcall original repo rec))))
           (setf h (sm-harness:make-harness
                    :config (sm-harness:make-harness-config
                             :data-root root
                             :transport-factory
                             (lambda (options)
                               (declare (ignore options))
                               (make-simple-turn-transport)))))
           (let* ((snapshot (sm-harness:start-session h :title "terminal save failure"))
                  (session-id (sm-harness:session-snapshot-id snapshot)))
             (sm-harness:submit-turn h session-id "committed user only")
             (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))))
             ;; The fault was one-shot: a later retry must not be contaminated by
             ;; it and must recover full durable state, including the canonical
             ;; identity the first attempt could not commit.
             (sm-harness:submit-turn h session-id "second turn after fault removed")
             (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
             (let ((reopened (sm-harness::repository-load-session
                              (sm-harness::harness-repository h) session-id)))
               (is (string= "canon-42" (sm-harness::session-record-canonical-id reopened)))
               (is (= 4 (length (sm-harness::session-record-transcript reopened))))
               (is (equal '("user" "user" "assistant" "system")
                          (mapcar #'sm-harness::transcript-entry-role
                                  (sm-harness::session-record-transcript reopened)))))))
      (setf (symbol-function 'sm-harness::repository-save-session) original)
      (when h (sm-harness:close-harness h))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test recovery-reload-load-failure-does-not-crash-the-worker
  (let* ((root (temp-data-root))
         (armed t)
         (original (symbol-function 'sm-harness::repository-load-session))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-instance 'harness-fake-transport
                                       :start-error "fixture connect secret")))))
         (snapshot (sm-harness:start-session h :title "load fault during recovery"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           ;; The runtime error handler's own recovery reload is the target: it
           ;; must tolerate a load-side fault rather than crash the worker
           ;; thread and strand the session.
           (setf (symbol-function 'sm-harness::repository-load-session)
                 (lambda (repo id)
                   (if armed
                       (progn
                         (setf armed nil)
                         (error 'sm-harness:harness-state-error
                                :message "fixture load secret"))
                       (funcall original repo id))))
           (sm-harness:submit-turn h session-id "must not crash the worker")
           (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))))
           (setf (symbol-function 'sm-harness::repository-load-session) original)
           (let ((reopened (sm-harness:open-session h session-id)))
             (is (null (sm-harness:session-snapshot-canonical-id reopened)))
             (is (null (sm-harness:session-snapshot-transcript reopened)))))
      (setf (symbol-function 'sm-harness::repository-load-session) original)
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test text-only-turn-renders-and-persists-the-response-exactly-once
  (let* ((root (temp-data-root))
         (events '())
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-duplicate-response-turn-transport)))))
         (snapshot (sm-harness:start-session h :title "dedup"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (listener-id nil))
    (unwind-protect
         (progn
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id
                :callback (lambda (ev) (push ev events)))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           (sm-harness:submit-turn h session-id "say hi")
           ;; :ready is also the session's untouched initial status, so wait
           ;; on the canonical id (only ever set by the terminal event) as
           ;; unambiguous proof the turn actually completed.
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))))
           (sm-harness:detach-session-listener h session-id listener-id)
           (setf events (nreverse events))
           ;; The CLI's terminal result text ("e2e hello") mirrors the
           ;; assistant text verbatim: exactly one durable entry for the
           ;; response, via the assistant stream, not a second "result"/system
           ;; duplicate.
           (let* ((reopened (sm-harness:open-session h session-id))
                  (transcript (sm-harness:session-snapshot-transcript reopened)))
             (is (equal '("user" "assistant")
                        (mapcar #'sm-harness:transcript-entry-role transcript))))
           ;; The terminal event still fires (status/canonical-id side
           ;; effects), but its published text is suppressed so the UI does
           ;; not paint a second copy of the same response.
           (let ((terminal (find :terminal events :key #'sm-harness:event-type)))
             (is (not (null terminal)))
             (is (null (getf (sm-harness:event-payload terminal) :text)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test distinct-terminal-outcome-still-renders-and-persists-its-own-entry
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-simple-turn-transport)))))
         (snapshot (sm-harness:start-session h :title "distinct"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "say hi")
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))))
           ;; make-simple-turn-transport's assistant text ("hello from
           ;; fixture") and terminal result text ("done") genuinely differ:
           ;; a broad role/type match must not hide the distinct outcome.
           (let* ((reopened (sm-harness:open-session h session-id))
                  (transcript (sm-harness:session-snapshot-transcript reopened)))
             (is (equal '("user" "assistant" "system")
                        (mapcar #'sm-harness:transcript-entry-role transcript)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test every-published-event-is-logged-with-session-id-and-full-payload
  (let* ((root (temp-data-root))
         (original-stream sm-harness::*session-event-log-stream*)
         (captured (make-string-output-stream))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-simple-turn-transport)))))
         (snapshot (sm-harness:start-session h :title "diagnostics"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (setf sm-harness::*session-event-log-stream* captured)
           (sm-harness:submit-turn h session-id "say hi")
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))))
           (let ((log (get-output-stream-string captured)))
             ;; Tied to the session: every line names it.
             (is (every (lambda (line) (search session-id line))
                        (remove "" (uiop:split-string log :separator '(#\Newline))
                                :test #'string=)))
             ;; Full payload content, not a redacted/truncated summary.
             (is (search "\"type\":\"assistant-text\"" log))
             (is (search "\"text\":\"hello from fixture\"" log))
             (is (search "\"type\":\"terminal\"" log))
             (is (search "\"session-id\":\"canon-42\"" log))))
      (setf sm-harness::*session-event-log-stream* original-stream)
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test conversational-tool-result-becomes-a-durable-tool-completed-entry
  ;; A built-in-tool's result arrives as a type="user" message, not as part
  ;; of the assistant message. It must map to :tool-completed and persist
  ;; with kind "tool", not fall through to :unrecognized.
  (let* ((root (temp-data-root))
         (events '())
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-conversational-tool-round-trip-transport)))))
         (snapshot (sm-harness:start-session h :title "conversational tool"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (listener-id nil))
    (unwind-protect
         (progn
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id
                :callback (lambda (ev) (push ev events)))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           (sm-harness:submit-turn h session-id "run the command")
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))))
           (sm-harness:detach-session-listener h session-id listener-id)
           (setf events (nreverse events))
           (is (null (find :unrecognized events :key #'sm-harness:event-type)))
           (let ((completed (find :tool-completed events :key #'sm-harness:event-type)))
             (is (not (null completed)))
             (is (string= "toolu_99" (getf (sm-harness:event-payload completed) :tool-use-id)))
             (is (string= "hi" (getf (sm-harness:event-payload completed) :content))))
           (let* ((reopened (sm-harness:open-session h session-id))
                  (transcript (sm-harness:session-snapshot-transcript reopened))
                  (tool-entries (remove-if-not
                                 (lambda (e) (string= "tool" (sm-harness:transcript-entry-kind e)))
                                 transcript))
                  (completed-entry (find-if
                                     (lambda (e) (search "Tool completed"
                                                        (sm-harness:transcript-entry-text e)))
                                     tool-entries)))
             (is (= 2 (length tool-entries)))
             (is (not (null completed-entry)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test conversational-tool-result-becomes-a-durable-tool-completed-entry
  ;; A built-in-tool's result arrives as a type="user" message, not as part
  ;; of the assistant message. It must map to :tool-completed and persist
  ;; with kind "tool", not fall through to :unrecognized.
  (let* ((root (temp-data-root))
         (events '())
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-conversational-tool-round-trip-transport)))))
         (snapshot (sm-harness:start-session h :title "conversational tool"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (listener-id nil))
    (unwind-protect
         (progn
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id
                :callback (lambda (ev) (push ev events)))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           (sm-harness:submit-turn h session-id "run the command")
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))))
           (sm-harness:detach-session-listener h session-id listener-id)
           (setf events (nreverse events))
           (is (null (find :unrecognized events :key #'sm-harness:event-type)))
           (let ((completed (find :tool-completed events :key #'sm-harness:event-type)))
             (is (not (null completed)))
             (is (string= "toolu_99" (getf (sm-harness:event-payload completed) :tool-use-id)))
             (is (string= "hi" (getf (sm-harness:event-payload completed) :content))))
           (let* ((reopened (sm-harness:open-session h session-id))
                  (transcript (sm-harness:session-snapshot-transcript reopened))
                  (tool-entries (remove-if-not
                                 (lambda (e) (string= "tool" (sm-harness:transcript-entry-kind e)))
                                 transcript))
                  (completed-entry (find-if
                                     (lambda (e) (search "Tool completed"
                                                        (sm-harness:transcript-entry-text e)))
                                     tool-entries)))
             (is (= 2 (length tool-entries)))
             (is (not (null completed-entry)))
             ;; Readable content ("hi"), never a raw Lisp object dump of the
             ;; decoded MCP content-block array.
             (is (string= "Tool completed: hi"
                          (sm-harness:transcript-entry-text completed-entry)))
             (is (not (search "HASH-TABLE" (sm-harness:transcript-entry-text completed-entry))))))
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

(test read-file-tool-executes-through-the-real-catalog-and-returns-file-content
  (let* ((root (temp-data-root))
         (file-path (merge-pathnames "catalog-read.txt" root))
         (catalog (sm-harness:default-tool-catalog))
         (arguments (let ((h (make-hash-table :test #'equal)))
                      (setf (gethash "path" h) (namestring file-path))
                      h))
         (tool-call-json (make-catalog-tool-call-json :name "read_file" :arguments arguments))
         (transport (make-named-catalog-tool-turn-transport tool-call-json))
         (h (sm-harness:make-harness
             :catalog catalog
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "real read_file"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (%write-text-file file-path (format nil "alpha~%beta~%"))
           (sm-harness:submit-turn h session-id "read the file")
           (let ((wire (wait-for-mcp-response transport)))
             (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
             (is (string= (format nil "1~Calpha~%2~Cbeta~%" #\Tab #\Tab)
                          (echoed-mcp-result-text wire)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test write-file-tool-executes-through-the-real-catalog-and-writes-a-file
  (let* ((root (temp-data-root))
         (file-path (merge-pathnames "catalog-write.txt" root))
         (catalog (sm-harness:default-tool-catalog))
         (arguments (let ((h (make-hash-table :test #'equal)))
                      (setf (gethash "path" h) (namestring file-path))
                      (setf (gethash "content" h) "written through the catalog")
                      h))
         (tool-call-json (make-catalog-tool-call-json :name "write_file" :arguments arguments))
         (transport (make-named-catalog-tool-turn-transport tool-call-json))
         (h (sm-harness:make-harness
             :catalog catalog
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "real write_file"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "write the file")
           (let ((wire (wait-for-mcp-response transport)))
             (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
             (is (search "wrote" (echoed-mcp-result-text wire)))
             (is (string= "written through the catalog" (%read-whole-file file-path)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test bash-tool-executes-through-the-real-catalog-and-runs-a-command
  (let* ((root (temp-data-root))
         (catalog (sm-harness:default-tool-catalog))
         (arguments (let ((h (make-hash-table :test #'equal)))
                      (setf (gethash "command" h) "echo through the catalog")
                      h))
         (tool-call-json (make-catalog-tool-call-json :name "bash" :arguments arguments))
         (transport (make-named-catalog-tool-turn-transport tool-call-json))
         (h (sm-harness:make-harness
             :catalog catalog
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "real bash"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "run the command")
           (let ((wire (wait-for-mcp-response transport)))
             (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
             (let ((result (echoed-mcp-result-text wire)))
               (is (search "exit code: 0" result))
               (is (search "through the catalog" result)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reload-harness-tool-executes-through-the-real-catalog
  (let* ((root (temp-data-root))
         (catalog (sm-harness:default-tool-catalog))
         (arguments (make-hash-table :test #'equal))
         (tool-call-json (make-catalog-tool-call-json :name "reload_harness" :arguments arguments))
         (transport (make-named-catalog-tool-turn-transport tool-call-json))
         (h (sm-harness:make-harness
             :catalog catalog
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "real reload"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "reload the harness")
           (let ((wire (wait-for-mcp-response transport)))
             (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
             ;; No arguments -> force nil, matching this test's own ambient
             ;; ASDF session forcing; reloading :sm-harness (the default
             ;; *reload-harness-system*, already loaded in this test binary)
             ;; is a safe no-op here.
             (is (search "reloaded" (echoed-mcp-result-text wire)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reload-harness-completion-schedules-and-runs-a-synthetic-followup
  (let* ((root (temp-data-root))
         (transport (make-repeated-tool-turn-transport
                     (list (list :tool-name "reload_harness" :is-error nil))))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "reload followup"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "please reload")
           (is (wait-until
                (lambda ()
                  (find "synthetic"
                        (sm-harness:session-snapshot-transcript
                         (sm-harness:open-session h session-id))
                        :key #'sm-harness:transcript-entry-kind :test #'string=))
                :timeout 5))
           (let* ((transcript (sm-harness:session-snapshot-transcript
                               (sm-harness:open-session h session-id)))
                  (entry (find "synthetic" transcript
                              :key #'sm-harness:transcript-entry-kind :test #'string=)))
             (is (string= "user" (sm-harness:transcript-entry-role entry)))
             (is (search "[harness] reload_harness finished successfully"
                        (sm-harness:transcript-entry-text entry)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reload-harness-failure-does-not-schedule-a-followup
  (let* ((root (temp-data-root))
         (transport (make-repeated-tool-turn-transport
                     (list (list :tool-name "reload_harness" :is-error t))))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "reload failure"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "please reload")
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))))
           ;; Give an (incorrect) auto-followup a moment to fire if it were
           ;; going to, before asserting its absence.
           (sleep 0.3)
           (is (null (find "synthetic"
                           (sm-harness:session-snapshot-transcript
                            (sm-harness:open-session h session-id))
                           :key #'sm-harness:transcript-entry-kind :test #'string=))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test different-tool-completion-does-not-schedule-a-followup
  (let* ((root (temp-data-root))
         (transport (make-repeated-tool-turn-transport
                     (list (list :tool-name "bash" :is-error nil))))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "other tool"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "run bash")
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))))
           (sleep 0.3)
           (is (null (find "synthetic"
                           (sm-harness:session-snapshot-transcript
                            (sm-harness:open-session h session-id))
                           :key #'sm-harness:transcript-entry-kind :test #'string=))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test reload-harness-followup-chain-stops-at-the-consecutive-cap
  (let* ((root (temp-data-root))
         (cycles (loop repeat (1+ sm-harness::+max-consecutive-synthetic-followups+)
                       collect (list :tool-name "reload_harness" :is-error nil)))
         (transport (make-repeated-tool-turn-transport cycles))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "reload chain cap"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "please reload")
           (is (wait-until
                (lambda ()
                  (find-if (lambda (e)
                             (search "follow-up limit" (sm-harness:transcript-entry-text e)))
                           (sm-harness:session-snapshot-transcript
                            (sm-harness:open-session h session-id))))
                :timeout 5))
           (let* ((transcript (sm-harness:session-snapshot-transcript
                               (sm-harness:open-session h session-id)))
                  (synthetic-count (count "synthetic" transcript
                                         :key #'sm-harness:transcript-entry-kind
                                         :test #'string=)))
             ;; +MAX-CONSECUTIVE-SYNTHETIC-FOLLOWUPS+ real auto-submitted
             ;; turns, plus one cap-notice entry (also kind "synthetic").
             (is (= (1+ sm-harness::+max-consecutive-synthetic-followups+) synthetic-count))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test first-turn-with-default-title-schedules-a-one-shot-title-nudge
  ;; #128: once a session's very first turn finishes and its title is still
  ;; the literal default ("New session" -- START-SESSION was never given an
  ;; explicit :TITLE here), a synthetic follow-up nudging SET_SESSION_TITLE
  ;; should be auto-submitted through the exact #76 mechanism, indistinguishable
  ;; in the transcript from a reload_harness follow-up except for its text.
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-n-simple-turns-transport 2)))))
         (snapshot (sm-harness:start-session h))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "see issue 68, let's plan")
           (is (wait-until
                (lambda ()
                  (find "synthetic"
                        (sm-harness:session-snapshot-transcript
                         (sm-harness:open-session h session-id))
                        :key #'sm-harness:transcript-entry-kind :test #'string=))
                :timeout 5))
           (let* ((transcript (sm-harness:session-snapshot-transcript
                               (sm-harness:open-session h session-id)))
                  (entry (find "synthetic" transcript
                              :key #'sm-harness:transcript-entry-kind :test #'string=)))
             (is (string= "user" (sm-harness:transcript-entry-role entry)))
             (is (search "call set_session_title" (sm-harness:transcript-entry-text entry)))
             (is (search "first turn" (sm-harness:transcript-entry-text entry)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test title-nudge-does-not-fire-when-the-session-already-has-an-explicit-title
  ;; A session created with a real :TITLE (never the literal default) must
  ;; never be nudged -- there is nothing to prompt the model to do.
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-simple-turn-transport)))))
         (snapshot (sm-harness:start-session h :title "already titled"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "hello")
           (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
           ;; Give an (incorrect) nudge a moment to fire if it were going to,
           ;; before asserting its absence.
           (sleep 0.3)
           (is (null (find "synthetic"
                           (sm-harness:session-snapshot-transcript
                            (sm-harness:open-session h session-id))
                           :key #'sm-harness:transcript-entry-kind :test #'string=))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test title-nudge-fires-at-most-once-even-if-the-title-stays-default
  ;; The nudge is one-shot: even if the model never calls SET_SESSION_TITLE
  ;; (title stays "New session" forever), a later, genuinely-independent
  ;; human turn must not be nudged a second time. Gated on SESSION-TURN-
  ;; COUNT reading exactly 1, which can only ever be true for the session's
  ;; first turn, this needs no separate "already nudged" flag to prove.
  (let* ((root (temp-data-root))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-n-simple-turns-transport 3)))))
         (snapshot (sm-harness:start-session h))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "first")
           (is (wait-until
                (lambda ()
                  (find "synthetic"
                        (sm-harness:session-snapshot-transcript
                         (sm-harness:open-session h session-id))
                        :key #'sm-harness:transcript-entry-kind :test #'string=))
                :timeout 5))
           (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
           (sm-harness:submit-turn h session-id "second, genuinely human")
           (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))))
           (sleep 0.3)
           (let* ((transcript (sm-harness:session-snapshot-transcript
                               (sm-harness:open-session h session-id)))
                  (synthetic-count (count "synthetic" transcript
                                         :key #'sm-harness:transcript-entry-kind
                                         :test #'string=)))
             (is (= 1 synthetic-count))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test deadline-re-arms-while-a-tool-call-is-in-flight
  ;; 1s deadline; the tool_result only arrives after 1.6s.  The watchdog
  ;; wakes mid-call, must observe the in-flight tool call and re-arm
  ;; instead of cancelling the turn (#80) -- expiring here is exactly what
  ;; doomed every legitimately slow tool call in the 2026-07-29 incident.
  (let* ((root (temp-data-root))
         (events '())
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root :turn-deadline-seconds 1
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-instance 'harness-fake-transport
                                       :chunks
                                       (list (concatenate 'string +init-ok+ +nl+)
                                             (concatenate 'string +conversational-tool-use+ +nl+)
                                             (lambda ()
                                               (sleep 1.6)
                                               (concatenate 'string
                                                            +conversational-tool-result+ +nl+
                                                            +conversational-final-text+ +nl+
                                                            +conversational-result+ +nl+))))))))
         (snapshot (sm-harness:start-session h :title "deadline re-arm"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (listener-id nil))
    (unwind-protect
         (progn
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id :callback (lambda (ev) (push ev events)))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           (sm-harness:submit-turn h session-id "slow tool turn")
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))
                :timeout 6))
           (sm-harness:detach-session-listener h session-id listener-id)
           (setf events (nreverse events))
           (is (find :terminal events :key #'sm-harness:event-type))
           ;; Neither a stopping status nor a deadline error may appear.
           (is (notany (lambda (ev)
                         (and (eq :status (sm-harness:event-type ev))
                              (eq :stopping (getf (sm-harness:event-payload ev) :status))))
                       events))
           (is (notany (lambda (ev)
                         (and (eq :error (sm-harness:event-type ev))
                              (search "deadline"
                                      (or (getf (sm-harness:event-payload ev) :message) ""))))
                       events)))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test deadline-still-cancels-a-stalled-turn-with-no-tool-in-flight
  ;; The re-arm must not neuter the watchdog: a turn stalled with nothing
  ;; in flight is still cancelled, and the transport sees the writer-only
  ;; interrupt request.
  (let* ((root (temp-data-root))
         (transport nil)
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root :turn-deadline-seconds 1
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (setf transport
                              (make-instance 'harness-fake-transport
                                             :chunks
                                             (list (concatenate 'string +init-ok+ +nl+)
                                                   (concatenate 'string +assistant+ +nl+)
                                                   (lambda () (sleep 2) nil))))))))
         (snapshot (sm-harness:start-session h :title "deadline stall"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "stall out")
           (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))
                           :timeout 6))
           (is (find-if (lambda (w) (search "\"subtype\":\"interrupt\"" w))
                        (fake-writes transport))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test deadline-abort-that-ends-in-a-terminal-reports-the-deadline
  ;; When the CLI answers the deadline interrupt with its own terminal
  ;; event, the loop ends via :done and %FINISH-CANCELLATION never runs.
  ;; The turn must still say why it stopped instead of ending silently --
  ;; the 2026-07-29 sessions ended with a bare empty-text
  ;; error_during_execution and nothing else (#80).
  (let* ((root (temp-data-root))
         (events '())
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root :turn-deadline-seconds 1
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-instance 'harness-fake-transport
                                       :chunks
                                       (list (concatenate 'string +init-ok+ +nl+)
                                             (concatenate 'string +assistant+ +nl+)
                                             (lambda ()
                                               (sleep 1.5)
                                               (concatenate 'string +result+ +nl+))))))))
         (snapshot (sm-harness:start-session h :title "deadline reported"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (listener-id nil))
    (unwind-protect
         (progn
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id :callback (lambda (ev) (push ev events)))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           (sm-harness:submit-turn h session-id "abort via terminal")
           (is (wait-until
                (lambda ()
                  (find-if (lambda (ev)
                             (and (eq :error (sm-harness:event-type ev))
                                  (equal "turn deadline exceeded"
                                         (getf (sm-harness:event-payload ev) :message))))
                           events))
                :timeout 6))
           (sm-harness:detach-session-listener h session-id listener-id)
           (setf events (nreverse events))
           ;; The deadline really fired (stopping was observed) and the CLI
           ;; terminal still came through before the explanation.
           (is (find-if (lambda (ev)
                          (and (eq :status (sm-harness:event-type ev))
                               (eq :stopping (getf (sm-harness:event-payload ev) :status))))
                        events))
           (is (find :terminal events :key #'sm-harness:event-type)))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test configured-system-prompt-reaches-session-options-with-identity-line
  "A configured system prompt reaches the client options verbatim, plus a
per-session line naming the session id and its transcript file on disk, so
an agent told to debug \"this session\" needs no discovery step."
  (let* ((root (temp-data-root))
         (captured nil)
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :system-prompt "Read /app/docs first."
                      :transport-factory
                      (lambda (options)
                        (setf captured options)
                        (make-duplicate-response-turn-transport)))))
         (snapshot (sm-harness:start-session h :title "system prompt"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "say hi")
           (is (wait-until (lambda () captured)))
           (let ((prompt (claude-agent-sdk-cl:agent-options-system-prompt captured)))
             (is (stringp prompt))
             (is (search "Read /app/docs first." prompt))
             (is (search session-id prompt))
             ;; Default project key, so the identity line must point at
             ;; <root>default/sessions/<id>.json.
             (is (search (format nil "default/sessions/~A.json" session-id)
                         prompt))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test absent-system-prompt-leaves-agent-options-prompt-nil
  "No configured system prompt means the CLI keeps its own default behavior."
  (let* ((root (temp-data-root))
         (captured nil)
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (setf captured options)
                        (make-duplicate-response-turn-transport)))))
         (snapshot (sm-harness:start-session h :title "no system prompt"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "say hi")
           (is (wait-until (lambda () captured)))
           (is (null (claude-agent-sdk-cl:agent-options-system-prompt captured))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test redacted-turn-error-still-logs-the-raw-condition-for-operators
  ;; The browser-facing :error event stays "internal error"
  ;; (SAFE-ERROR-PAYLOAD), but the operator log must carry the raw
  ;; condition on an SM-HARNESS-DIAGNOSTIC line -- without it a failed
  ;; turn is undiagnosable after the fact (2026-07-30 incident).
  (let* ((root (temp-data-root))
         (original-stream sm-harness::*session-event-log-stream*)
         (captured (make-string-output-stream))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-instance 'harness-fake-transport
                                       :start-error "fixture connect secret: credential")))))
         (snapshot (sm-harness:start-session h :title "diagnostic"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (setf sm-harness::*session-event-log-stream* captured)
           (sm-harness:submit-turn h session-id "boom")
           (is (wait-until (lambda () (eq :error (sm-harness:session-status h session-id)))))
           (let* ((log (get-output-stream-string captured))
                  (lines (remove "" (uiop:split-string log :separator '(#\Newline))
                                 :test #'string=))
                  (diagnostic (find-if (lambda (l) (search "SM-HARNESS-DIAGNOSTIC" l)) lines))
                  (error-event (find-if (lambda (l)
                                          (and (search "SM-HARNESS-EVENT" l)
                                               (search "\"type\":\"error\"" l)))
                                        lines)))
             ;; Operator line: raw condition text, tied to the session.
             (is (not (null diagnostic)))
             (is (search "fixture connect secret: credential" diagnostic))
             (is (search session-id diagnostic))
             (is (search "condition_type" diagnostic))
             ;; Published event: still redacted.
             (is (not (null error-event)))
             (is (search "internal error" error-event))
             (is (not (search "secret" error-event)))))
      (setf sm-harness::*session-event-log-stream* original-stream)
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test blocked-listener-callback-does-not-stall-the-turn
  ;; A listener whose callback never returns (canonically: a CLOG browser
  ;; round-trip against a half-dead connection) must not delay the session
  ;; worker, which also answers the CLI's MCP control requests -- the
  ;; 2026-07-30 wedge. Callbacks run on the listener's own dispatcher
  ;; thread, so the turn below completes while the callback is still
  ;; blocked on its very first event.
  (let* ((root (temp-data-root))
         (gate (sb-thread:make-semaphore :name "blocked-listener-gate"))
         (events '())
         (lock (sb-thread:make-mutex))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-simple-turn-transport)))))
         (snapshot (sm-harness:start-session h :title "blocked listener"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (listener-id nil))
    (unwind-protect
         (progn
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id
                :callback (lambda (ev)
                            (sb-thread:wait-on-semaphore gate)
                            (sb-thread:with-mutex (lock) (push ev events))))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           (sm-harness:submit-turn h session-id "say hi")
           ;; Completes within WAIT-UNTIL's window even though the callback
           ;; has not processed a single event yet.
           (is (wait-until
                (lambda ()
                  (string= "canon-42"
                           (or (sm-harness:session-snapshot-canonical-id
                                (sm-harness:open-session h session-id))
                               "")))))
           (is (null (sb-thread:with-mutex (lock) events)))
           ;; Once unblocked, the queued events all flush through in order;
           ;; DETACH-SESSION-LISTENER joins that flush before returning.
           (sb-thread:signal-semaphore gate 64)
           (sm-harness:detach-session-listener h session-id listener-id)
           (let ((seen (sb-thread:with-mutex (lock) (nreverse events))))
             (is (find :user-message seen :key #'sm-harness:event-type))
             (is (find :terminal seen :key #'sm-harness:event-type))
             (is (equal (mapcar #'sm-harness:event-sequence seen)
                        (sort (mapcar #'sm-harness:event-sequence seen) #'<)))))
      (sb-thread:signal-semaphore gate 64)
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(defun %submit-turn-once-idle (harness session-id prompt &key (timeout 5))
  "SUBMIT-TURN, retrying briefly on HARNESS-STATE-ERROR: the worker thread
publishes :TERMINAL and only *then* clears the previous turn's active-turn-id
a few forms later (RUNTIME.LISP's %RUN-TURN), so a caller that submits its
next turn the instant it observes that :TERMINAL event -- exactly what
CLIENT-SIDE-ECHO-MARKER-MUST-BE-SET-BEFORE-SUBMIT-TURN-NOT-AFTER below does,
deliberately, to pin down turn ordering precisely -- can still race that
narrow window. A real UI does not hit this: SUBMIT-TURN's own error there
already surfaces as a normal, retryable \"busy\" error to the user, not a
correctness bug."
  (let ((deadline (+ (get-internal-real-time)
                      (round (* timeout internal-time-units-per-second)))))
    (loop
      (handler-case
          (return (sm-harness:submit-turn harness session-id prompt))
        (sm-harness:harness-state-error (c)
          (when (> (get-internal-real-time) deadline) (error c))
          (sleep 0.01))))))

(test client-side-echo-marker-must-be-set-before-submit-turn-not-after
  "Regression for sm-harness-web-ui #69 (a submitted prompt rendered twice
   on send). Once a session's client is already connected -- i.e. any turn
   after the first -- SUBMIT-TURN returns to its caller after nothing more
   than a mailbox enqueue: the harness dispatcher thread, and in turn the
   listener's own separate dispatcher thread (see
   BLOCKED-LISTENER-CALLBACK-DOES-NOT-STALL-THE-TURN above), can process
   and deliver that turn's :USER-MESSAGE event well before the submitting
   thread gets around to its own later work -- notably a UI's own
   optimistic echo of the prompt it just sent, which needs a real round
   trip to a browser.

   A caller-side de-duplication marker (sm-harness-web-ui's chat.lisp
   AWAITING-USER-ECHO) is therefore only race-free set BEFORE calling
   SUBMIT-TURN, not after: this test proves both halves of that claim on
   an already-connected client. The 'unsafe' turns below simulate that
   slow post-submit round trip with a sleep before raising the marker --
   exactly the ordering an earlier version of the #69 fix used, which
   still showed a duplicated prompt in real usage -- and the listener
   reliably observes the marker still unset. The 'safe' turns raise the
   marker first and the listener never observes it unset, on any turn,
   confirming the ordering sm-harness-web-ui/src/ui/chat.lisp relies on."
  (let* ((root (temp-data-root))
         (turns 5)
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (declare (ignore options))
                        (make-n-simple-turns-transport turns)))))
         (snapshot (sm-harness:start-session h :title "echo-race"))
         (session-id (sm-harness:session-snapshot-id snapshot))
         (listener-id nil)
         (marker nil)
         (results '())
         (lock (sb-thread:make-mutex :name "echo-race-results"))
         ;; SEEN fires per :USER-MESSAGE, DONE fires per :TERMINAL -- an
         ;; exact, low-latency completion signal for "this submitted turn
         ;; is fully done", unlike polling SESSION-STATUS: :READY is also a
         ;; freshly-started session's untouched initial status (see the
         ;; comment on TEXT-ONLY-TURN-RENDERS-AND-PERSISTS-THE-RESPONSE-
         ;; EXACTLY-ONCE above), so a status-only wait right after the
         ;; first SUBMIT-TURN can spuriously return before that first turn
         ;; ever really finishes.
         (seen (sb-thread:make-semaphore :name "echo-race-seen"))
         (done (sb-thread:make-semaphore :name "echo-race-done")))
    (unwind-protect
         (progn
           ;; Attach before any turn is submitted, so DONE/SEEN cover turn 1
           ;; too, with no window where a completion could be missed.
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id
                :callback (lambda (ev)
                            (case (sm-harness:event-type ev)
                              (:user-message
                               (sb-thread:with-mutex (lock) (push (not marker) results))
                               (sb-thread:signal-semaphore seen))
                              (:terminal (sb-thread:signal-semaphore done)))))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           ;; Turn 1 connects the client; every turn below runs on an
           ;; already-connected client, the scenario that matters here. Its
           ;; own marker/results entry is discarded below -- only turns 2+
           ;; are on the ordering under test.
           (setf marker t)
           (%submit-turn-once-idle h session-id "turn 1")
           (is (sb-thread:wait-on-semaphore seen :timeout 5))
           (is (sb-thread:wait-on-semaphore done :timeout 5))
           (sb-thread:with-mutex (lock) (setf results '()))
           (dotimes (i (1- turns))
             (setf marker nil)
             (if (evenp i)
                 (progn
                   (%submit-turn-once-idle h session-id (format nil "turn ~D" (+ i 2)))
                   (sleep 0.2)
                   (setf marker t))
                 (progn
                   (setf marker t)
                   (%submit-turn-once-idle h session-id (format nil "turn ~D" (+ i 2)))))
             (is (sb-thread:wait-on-semaphore seen :timeout 5))
             (is (sb-thread:wait-on-semaphore done :timeout 5)))
           (let ((seen-results (nreverse (sb-thread:with-mutex (lock) results))))
             (is (= (1- turns) (length seen-results)))
             (loop for i from 0
                   for unset in seen-results
                   do (if (evenp i)
                          (is (eq t unset)
                              "unsafe order (marker raised after SUBMIT-TURN) must be observably racy")
                          (is (not unset)
                              "safe order (marker raised before SUBMIT-TURN) must never be observed racy")))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;;;; #116 phase 1: MAKE-HARNESS's catalog is a zero-argument provider
;;;; function, FUNCALLed fresh by %ENSURE-CLIENT every time it builds a
;;;; *new* client connection -- not a TOOL-CATALOG value materialized once
;;;; and read forever after. See HARNESS-CATALOG-PROVIDER's docstring
;;;; (runtime.lisp) and MAKE-HARNESS's docstring (session-service.lisp).

(defun %fixture-tool-catalog (&rest tool-names)
  (sm-harness::make-tool-catalog
   :servers (list (sm-harness::make-tool-server-definition
                   :name "fixture"
                   :tools (mapcar (lambda (name)
                                    (sm-harness::make-tool-definition
                                     :name name :description name
                                     :input-schema (sm-harness::%echo-schema)
                                     :handler (lambda (arguments context)
                                                (declare (ignore arguments context))
                                                "ok")))
                                  tool-names)))))

(defun %agent-options-tool-names (options)
  (loop for server in (claude-agent-sdk-cl:agent-options-sdk-mcp-servers options)
        append (mapcar #'claude-agent-sdk-cl:sdk-tool-name
                       (claude-agent-sdk-cl:sdk-mcp-server-tools server))))

(test new-session-after-catalog-provider-changes-sees-the-current-catalog
  "A brand-new session created after the harness's catalog provider starts
returning a different catalog must see that new catalog -- the harness-wide
staleness #116 fixed. Independent of whether an already-open session's own
connection gets refreshed (a separate, later phase)."
  (let* ((root (temp-data-root))
         (options-seen '())
         (current-catalog (%fixture-tool-catalog "tool_a"))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (push options options-seen)
                        (make-simple-turn-transport))))))
    ;; No :CATALOG argument above -- exactly the real production call shape
    ;; (sm-harness-web-ui's MAIN never passes one) -- so MAKE-HARNESS
    ;; installed the real #'DEFAULT-TOOL-CATALOG as the provider. Swap it
    ;; here for a controlled fixture provider instead of mutating the real
    ;; default catalog out from under every other test in this suite.
    (setf (sm-harness::harness-catalog-provider h) (lambda () current-catalog))
    (unwind-protect
         (progn
           (let* ((snapshot-1 (sm-harness:start-session h :title "session one"))
                  (id-1 (sm-harness:session-snapshot-id snapshot-1)))
             (sm-harness:submit-turn h id-1 "turn one")
             (is (wait-until (lambda () (string= "canon-42" (sm-harness:session-snapshot-canonical-id (sm-harness:open-session h id-1)))))))
           (let ((names-1 (%agent-options-tool-names (first options-seen))))
             (is (member "tool_a" names-1 :test #'string=))
             (is (not (member "tool_b" names-1 :test #'string=))))
           ;; Simulate what a successful RELOAD_HARNESS makes possible: the
           ;; provider now returns a catalog with a brand-new tool.
           (setf current-catalog (%fixture-tool-catalog "tool_a" "tool_b"))
           (let* ((snapshot-2 (sm-harness:start-session h :title "session two"))
                  (id-2 (sm-harness:session-snapshot-id snapshot-2)))
             (sm-harness:submit-turn h id-2 "turn one")
             (is (wait-until (lambda () (string= "canon-42" (sm-harness:session-snapshot-canonical-id (sm-harness:open-session h id-2)))))))
           (let ((names-2 (%agent-options-tool-names (first options-seen))))
             (is (member "tool_a" names-2 :test #'string=))
             (is (member "tool_b" names-2 :test #'string=)
                 "a brand-new session must see a tool added to the catalog after it started")))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;;;; #116 phase 2: MARK-SESSIONS-FOR-CATALOG-REFRESH flags an open session
;;;; to reconnect at the start of its *next* turn -- never by touching
;;;; SESSION-RUNTIME-CLIENT itself from a foreign thread -- reusing exactly
;;;; the :RESUME-based rebuild an error-recovery reconnect already performs.

(defun %robust-delete-directory-tree (root)
  "DELETE-DIRECTORY-TREE, tolerating one benign race: CLOSE-HARNESS returns
once every session's worker thread has stopped, but a session's own
listener dispatch thread (LISTENER-PUSH/%LISTENER-DISPATCH-LOOP) can still
be mid-write to this ROOT for a moment after that -- observed directly as
an intermittent \"directory not empty\" here for these two tests
specifically, which (unlike most of this suite) deliberately leave a
listener attached through a session's final :TERMINAL event. One retry
after a short settle is enough in practice; a second genuine failure is
reported normally rather than silently swallowed."
  (handler-case
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)
    (error ()
      (sleep 0.2)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test open-session-reconnects-with-the-current-catalog-after-a-marked-refresh
  "A session already connected, then flagged via
MARK-SESSIONS-FOR-CATALOG-REFRESH, must reconnect on its next turn and see
the harness's current catalog -- while the flagging call itself must never
touch the live client synchronously, and the reconnect must carry prior
CLI-side context forward via :RESUME exactly like the existing
error-recovery reconnect path already does."
  (let* ((root (temp-data-root))
         (options-seen '())
         (transports '())
         (current-catalog (%fixture-tool-catalog "tool_a"))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (push options options-seen)
                        (let ((transport (make-simple-turn-transport)))
                          (push transport transports)
                          transport)))))
         (done (sb-thread:make-semaphore :name "catalog-refresh-done")))
    (setf (sm-harness::harness-catalog-provider h) (lambda () current-catalog))
    (unwind-protect
         (let* ((snapshot (sm-harness:start-session h :title "catalog refresh"))
                (session-id (sm-harness:session-snapshot-id snapshot))
                (listener-id nil))
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id
                :callback (lambda (ev)
                            (when (eq :terminal (sm-harness:event-type ev))
                              (sb-thread:signal-semaphore done))))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           (sm-harness:submit-turn h session-id "turn one")
           (is (sb-thread:wait-on-semaphore done :timeout 5))
           (is (= 1 (length options-seen)))
           (is (member "tool_a" (%agent-options-tool-names (first options-seen)) :test #'string=))
           (let ((rt (sm-harness::%get-runtime h session-id)))
             (is (not (null (sm-harness::session-runtime-client rt)))
                 "the first turn's client must still be connected before any refresh is requested"))
           (sm-harness:mark-sessions-for-catalog-refresh h)
           (let ((rt (sm-harness::%get-runtime h session-id)))
             (is (sm-harness::session-runtime-pending-catalog-refresh-p rt)
                 "the flag must be set immediately")
             (is (not (null (sm-harness::session-runtime-client rt)))
                 "marking for refresh must never itself touch the live client -- only the next turn's own worker thread may"))
           (setf current-catalog (%fixture-tool-catalog "tool_a" "tool_b"))
           (sm-harness:submit-turn h session-id "turn two")
           (is (sb-thread:wait-on-semaphore done :timeout 5))
           (is (= 2 (length options-seen)))
           (is (member "tool_b" (%agent-options-tool-names (first options-seen)) :test #'string=)
               "the reconnected client must see the catalog change")
           (is (string= "canon-42"
                        (claude-agent-sdk-cl:agent-options-resume (first options-seen)))
               "the reconnect must resume the same CLI-side session, not start a fresh one")
           (let ((first-transport (car (last transports))))
             (is (eq :disconnect (fake-closed-reason first-transport))
                 "the stale client must be cleanly disconnected, not abandoned"))
           (let ((rt (sm-harness::%get-runtime h session-id)))
             (is (not (sm-harness::session-runtime-pending-catalog-refresh-p rt))
                 "the flag must be consumed, not left set forever")))
      (sm-harness:close-harness h)
      (%robust-delete-directory-tree root))))

(test in-flight-turn-is-not-disrupted-by-a-catalog-refresh-mark
  "MARK-SESSIONS-FOR-CATALOG-REFRESH must never interrupt a turn already in
flight: the flag is only consumed at the *start* of %ENSURE-CLIENT's next
call, which only happens at the beginning of a new turn -- never mid-turn,
and never by touching SESSION-RUNTIME-CLIENT from the marking thread."
  (let* ((root (temp-data-root))
         (options-seen '())
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory
                      (lambda (options)
                        (push options options-seen)
                        (make-instance 'harness-fake-transport
                                       :chunks
                                       (list (concatenate 'string +init-ok+ +nl+)
                                             (lambda ()
                                               (sleep 1.0)
                                               (concatenate 'string +assistant+ +nl+ +result+ +nl+))))))))
         (done (sb-thread:make-semaphore :name "in-flight-done")))
    (unwind-protect
         (let* ((snapshot (sm-harness:start-session h :title "in-flight refresh"))
                (session-id (sm-harness:session-snapshot-id snapshot))
                (listener-id nil)
                (client-during-flight nil))
           (multiple-value-bind (snap lid cursor)
               (sm-harness:attach-session-listener
                h session-id
                :callback (lambda (ev)
                            (when (eq :terminal (sm-harness:event-type ev))
                              (sb-thread:signal-semaphore done))))
             (declare (ignore snap cursor))
             (setf listener-id lid))
           (sm-harness:submit-turn h session-id "slow turn")
           ;; Give %ENSURE-CLIENT a moment to connect and start waiting on
           ;; the delayed chunk (the turn's own 1s sleep) before flagging.
           (sleep 0.2)
           (let ((rt (sm-harness::%get-runtime h session-id)))
             (setf client-during-flight (sm-harness::session-runtime-client rt))
             (is (not (null client-during-flight))))
           (sm-harness:mark-sessions-for-catalog-refresh h)
           (is (sb-thread:wait-on-semaphore done :timeout 5))
           (is (= 1 (length options-seen))
               "the in-flight turn's own connection must never be replaced mid-turn")
           (let ((rt (sm-harness::%get-runtime h session-id)))
             (is (eq client-during-flight (sm-harness::session-runtime-client rt))
                 "the same client object must still be in place after the turn completed")
             (is (sm-harness::session-runtime-pending-catalog-refresh-p rt)
                 "the flag must survive untouched until the *next* turn's own %ensure-client call")))
      (sm-harness:close-harness h)
      (%robust-delete-directory-tree root))))

;;;; #117: MAKE-HARNESS's default catalog provider must be a late-bound
;;;; SYMBOL, not a captured #'DEFAULT-TOOL-CATALOG function object -- and a
;;;; harness built before that fix, still live in a long-running image, must
;;;; be repaired in place by the same post-reload call that flags sessions.

(defmacro %with-provider-harness ((var &rest make-args) &body body)
  `(let* ((root (temp-data-root))
          (,var (sm-harness:make-harness
                 :config (sm-harness:make-harness-config :data-root root)
                 ,@make-args)))
     (unwind-protect (progn ,@body)
       (sm-harness:close-harness ,var)
       (%robust-delete-directory-tree root))))

(test default-catalog-provider-is-a-late-bound-symbol-not-a-captured-function
  ;; A captured function object is re-called per connection but frozen at
  ;; MAKE-HARNESS time, so a RELOAD_HARNESS-added tool never reaches it.
  (%with-provider-harness (h)
    (is (eq 'sm-harness::default-tool-catalog
            (sm-harness::harness-catalog-provider h)))
    (is (not (sm-harness::%captured-default-catalog-provider-p
              (sm-harness::harness-catalog-provider h))))))

(test an-explicit-catalog-argument-still-pins-that-exact-catalog
  (let ((fixed (%fixture-tool-catalog "tool_a")))
    (%with-provider-harness (h :catalog fixed)
      (is (eq fixed (funcall (sm-harness::harness-catalog-provider h))))
      ;; A refresh pass must never swap a deliberately fixed catalog
      ;; (tests, the web UI's E2E fixture) for the production default.
      (sm-harness:mark-sessions-for-catalog-refresh h)
      (is (eq fixed (funcall (sm-harness::harness-catalog-provider h)))))))

(test a-captured-default-catalog-provider-is-repaired-by-a-catalog-refresh
  (%with-provider-harness (h)
    ;; Exactly what pre-#117 MAKE-HARNESS left in the slot.
    (setf (sm-harness::harness-catalog-provider h) #'sm-harness:default-tool-catalog)
    (is (sm-harness::%captured-default-catalog-provider-p
         (sm-harness::harness-catalog-provider h)))
    (sm-harness:mark-sessions-for-catalog-refresh h)
    (is (eq 'sm-harness::default-tool-catalog
            (sm-harness::harness-catalog-provider h)))))

;;;; #118: the CLI reports a catalog tool call under its MCP-namespaced name
;;;; ("mcp__sm_harness__reload_harness"), so #76's follow-up correlation must
;;;; compare base names -- an exact match against "reload_harness" meant the
;;;; automatic follow-up never once fired in a real session.

(test tool-base-name-strips-the-mcp-server-namespace
  (is (string= "reload_harness" (sm-harness::%tool-base-name "mcp__sm_harness__reload_harness")))
  ;; A tool name may itself contain underscores: split at the first "__"
  ;; after the prefix, not the last.
  (is (string= "read_file" (sm-harness::%tool-base-name "mcp__sm_harness__read_file")))
  ;; Unprefixed names (builtins, fake transports) pass through untouched.
  (is (string= "reload_harness" (sm-harness::%tool-base-name "reload_harness")))
  (is (string= "Bash" (sm-harness::%tool-base-name "Bash")))
  (is (string= "mcp__weird" (sm-harness::%tool-base-name "mcp__weird"))))

(test a-namespaced-reload-harness-completion-still-schedules-a-followup
  (let* ((root (temp-data-root))
         (transport (make-repeated-tool-turn-transport
                     (list (list :tool-name "mcp__sm_harness__reload_harness"
                                 :is-error nil))))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "namespaced reload followup"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "please reload")
           (is (wait-until
                (lambda ()
                  (find "synthetic"
                        (sm-harness:session-snapshot-transcript
                         (sm-harness:open-session h session-id))
                        :key #'sm-harness:transcript-entry-kind :test #'string=))
                :timeout 5)
               "a reload reported under its MCP-namespaced name must still schedule the follow-up")
           (let ((entry (find "synthetic"
                              (sm-harness:session-snapshot-transcript
                               (sm-harness:open-session h session-id))
                              :key #'sm-harness:transcript-entry-kind :test #'string=)))
             (is (string= "user" (sm-harness:transcript-entry-role entry)))
             (is (search "[harness] reload_harness finished successfully"
                         (sm-harness:transcript-entry-text entry)))))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(test a-namespaced-non-reload-tool-completion-schedules-no-followup
  (let* ((root (temp-data-root))
         (transport (make-repeated-tool-turn-transport
                     (list (list :tool-name "mcp__sm_harness__echo_text" :is-error nil))))
         (h (sm-harness:make-harness
             :config (sm-harness:make-harness-config
                      :data-root root
                      :transport-factory (lambda (options)
                                           (declare (ignore options)) transport))))
         (snapshot (sm-harness:start-session h :title "no followup"))
         (session-id (sm-harness:session-snapshot-id snapshot)))
    (unwind-protect
         (progn
           (sm-harness:submit-turn h session-id "echo something")
           (is (wait-until (lambda () (eq :ready (sm-harness:session-status h session-id)))
                           :timeout 5))
           (sleep 0.3)
           (is (null (find "synthetic"
                           (sm-harness:session-snapshot-transcript
                            (sm-harness:open-session h session-id))
                           :key #'sm-harness:transcript-entry-kind :test #'string=))
               "only reload_harness schedules a follow-up, namespaced or not"))
      (sm-harness:close-harness h)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
