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
