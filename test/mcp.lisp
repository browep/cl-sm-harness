(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/mcp :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/mcp)

(defun mcp-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key object) value))
    object))

(defun mcp-json (object)
  (with-output-to-string (stream)
    (yason:encode object stream)))

(defun mcp-test-schema ()
  (mcp-object "type" "object"
              "properties" (mcp-object "order_id" (mcp-object "type" "string"))))

(defun read-sdk-mcp-upstream-fixture ()
  (with-open-file (stream #P"/workspace/test/fixtures/upstream/mcp/sdk-mcp-tools.json")
    (yason:parse stream)))

(defun json-value= (left right)
  "Compare Yason-compatible values structurally, including distinct hash tables."
  (cond
    ((and (hash-table-p left) (hash-table-p right))
     (and (= (hash-table-count left) (hash-table-count right))
          (loop for key being the hash-keys of left using (hash-value value)
                always (and (stringp key)
                            (multiple-value-bind (other present) (gethash key right)
                              (and present (json-value= value other)))))))
    ((and (listp left) (listp right))
     (and (= (length left) (length right))
          (every #'json-value= left right)))
    (t (equal left right))))

(defun mcp-test-tool (&key (handler nil))
  (claude-agent-sdk-cl:make-sdk-tool
   :name "lookup-order"
   :description "Look up an order by ID."
   :input-schema (mcp-test-schema)
   :handler (or handler
                (lambda (arguments context)
                  (declare (ignore context))
                  (claude-agent-sdk-cl:make-sdk-tool-result
                   :text (format nil "order ~A" (gethash "order_id" arguments)))))))

(defun mcp-server (&key (tools (list (mcp-test-tool))))
  (claude-agent-sdk-cl:make-sdk-mcp-server :name "orders" :tools tools))

(defun mcp-control-request (request-id jsonrpc-id method &optional params)
  (mcp-json
   (mcp-object
    "type" "control_request"
    "request_id" request-id
    "request" (mcp-object
                 "subtype" "mcp_message"
                 "server_name" "orders"
                 "message" (mcp-object "jsonrpc" "2.0"
                                       "id" jsonrpc-id
                                       "method" method
                                       "params" (or params (mcp-object)))))))

(defun mcp-response-object (wire)
  (let* ((outer (yason:parse wire))
         (response (gethash "response" outer))
         (payload (gethash "response" response)))
    (gethash "mcp_response" payload)))

(defun mcp-client (server chunks)
  (claude-agent-sdk-cl:make-claude-sdk-client
   :transport (make-instance 'fake-client-transport :chunks chunks)
   :options (claude-agent-sdk-cl:make-agent-options
             :sdk-mcp-servers (list server)
             :builtin-tools :none
             :strict-mcp-config t)))

(test sdk-tool-and-server-validate-public-contract
  (let* ((tool (mcp-test-tool))
         (server (claude-agent-sdk-cl:make-sdk-mcp-server
                  :name "orders" :version "1.2.3" :tools (list tool))))
    (is (string= "lookup-order" (claude-agent-sdk-cl:sdk-tool-name tool)))
    (is (string= "orders" (claude-agent-sdk-cl:sdk-mcp-server-name server)))
    (is (string= "1.2.3" (claude-agent-sdk-cl:sdk-mcp-server-version server)))
    (is (= 1 (length (claude-agent-sdk-cl:sdk-mcp-server-tools server)))))
  (dolist (arguments
           (list
            '(:name "" :description "description" :input-schema #() :handler identity)
            '(:name "tool" :description "" :input-schema #() :handler identity)
            '(:name "tool" :description "description" :input-schema #() :handler not-a-function)))
    (signals claude-agent-sdk-cl:sdk-input-error
      (apply #'claude-agent-sdk-cl:make-sdk-tool arguments)))
  (let ((tool (mcp-test-tool)))
    (signals claude-agent-sdk-cl:sdk-input-error
      (claude-agent-sdk-cl:make-sdk-mcp-server :name "" :tools (list tool)))
    (signals claude-agent-sdk-cl:sdk-input-error
      (claude-agent-sdk-cl:make-sdk-mcp-server :name "orders" :tools (list tool tool)))))

(test custom-tool-options-encode-availability-separately-from-permission
  (let* ((server (mcp-server))
         (options (claude-agent-sdk-cl:make-agent-options
                   :builtin-tools :none
                   :sdk-mcp-servers (list server)
                   :strict-mcp-config t
                   :allowed-tools '("Bash")
                   :disallowed-tools '("Write")))
         (wire (claude-agent-sdk-cl::agent-options->wire options))
         (configuration (claude-agent-sdk-cl:agent-options->mcp-config options)))
    (is (eq :none (claude-agent-sdk-cl:agent-options-builtin-tools options)))
    (is (eq t (claude-agent-sdk-cl:agent-options-strict-mcp-config options)))
    (is (equal '("Bash") (gethash "allowedTools" wire)))
    (is (equal '("Write") (gethash "disallowedTools" wire)))
    (is (string= "sdk" (gethash "type" (gethash "orders" (gethash "mcpServers" configuration)))))
    (is (string= "orders" (gethash "name" (gethash "orders" (gethash "mcpServers" configuration)))))))

(test custom-tool-options-reject-invalid-source-policies-before-spawn
  (let ((server (mcp-server)))
    (dolist (builtin-tools '(:unknown "Bash" ("Read" 3)))
      (signals claude-agent-sdk-cl:sdk-input-error
        (claude-agent-sdk-cl:make-agent-options :builtin-tools builtin-tools)))
    (signals claude-agent-sdk-cl:sdk-input-error
      (claude-agent-sdk-cl:make-agent-options :strict-mcp-config "yes"))
    (signals claude-agent-sdk-cl:sdk-input-error
      (claude-agent-sdk-cl:make-agent-options :sdk-mcp-servers (list server server)))
    (signals claude-agent-sdk-cl:sdk-input-error
      (claude-agent-sdk-cl:query "no control loop" :options
                                 (claude-agent-sdk-cl:make-agent-options
                                  :sdk-mcp-servers (list server))))))

(test custom-tool-options-reject-ambiguous-qualified-tool-names
  ;; The CLI flattens both catalogs below to mcp__a__b__c. Reject before a
  ;; subprocess starts rather than silently routing the model to one handler.
  (let* ((first-tool (claude-agent-sdk-cl:make-sdk-tool
                      :name "c" :description "Left side of collision."
                      :input-schema (mcp-test-schema)
                      :handler (lambda (arguments context)
                                 (declare (ignore arguments context))
                                 (claude-agent-sdk-cl:make-sdk-tool-result :text "left"))))
         (first (claude-agent-sdk-cl:make-sdk-mcp-server
                 :name "a__b" :tools (list first-tool)))
         (second-tool (claude-agent-sdk-cl:make-sdk-tool
                       :name "b__c" :description "Right side of collision."
                       :input-schema (mcp-test-schema)
                       :handler (lambda (arguments context)
                                  (declare (ignore arguments context))
                                  (claude-agent-sdk-cl:make-sdk-tool-result :text "right"))))
         (second (claude-agent-sdk-cl:make-sdk-mcp-server
                  :name "a" :tools (list second-tool))))
    (signals claude-agent-sdk-cl:sdk-input-error
      (claude-agent-sdk-cl:make-agent-options
       :sdk-mcp-servers (list first second))))
  ;; Same local tool names remain valid when their qualified names differ.
  (let ((options (claude-agent-sdk-cl:make-agent-options
                  :sdk-mcp-servers
                  (list (claude-agent-sdk-cl:make-sdk-mcp-server
                         :name "west" :tools (list (mcp-test-tool)))
                        (claude-agent-sdk-cl:make-sdk-mcp-server
                         :name "east" :tools (list (mcp-test-tool)))))))
    (is (= 2 (length (claude-agent-sdk-cl:agent-options-sdk-mcp-servers options))))))

(test sdk-catalog-snapshots-caller-schema-at-option-construction
  (let* ((schema (mcp-test-schema))
         (tool (claude-agent-sdk-cl:make-sdk-tool
                :name "snapshot" :description "Snapshot test."
                :input-schema schema
                :handler (lambda (arguments context)
                           (declare (ignore arguments context))
                           (claude-agent-sdk-cl:make-sdk-tool-result :text "ok"))))
         (options (claude-agent-sdk-cl:make-agent-options
                   :sdk-mcp-servers
                   (list (claude-agent-sdk-cl:make-sdk-mcp-server
                          :name "snapshots" :tools (list tool))))))
    ;; Mutate caller-owned schema after options construction. The session catalog
    ;; must retain the independent schema snapshot used for discovery.
    (setf (gethash "type" schema) "mutated")
    (is (string= "object"
                 (gethash "type"
                          (claude-agent-sdk-cl:sdk-tool-input-schema
                           (first (claude-agent-sdk-cl:sdk-mcp-server-tools
                                   (first (claude-agent-sdk-cl:agent-options-sdk-mcp-servers
                                           options))))))))))

(test custom-tool-cli-arguments-use-only-serializable-server-metadata
  (let* ((server (mcp-server))
         (options (claude-agent-sdk-cl:make-agent-options
                   :builtin-tools '("Read" "Bash")
                   :sdk-mcp-servers (list server) :strict-mcp-config t))
         (arguments (claude-agent-sdk-cl::one-shot-query-arguments options))
         (mcp-config (second (member "--mcp-config" arguments :test #'string=))))
    (is (equal "Read,Bash" (second (member "--tools" arguments :test #'string=))))
    (is (member "--strict-mcp-config" arguments :test #'string=))
    (is (search "\"mcpServers\"" mcp-config))
    (is (search "\"type\":\"sdk\"" mcp-config))
    (is (not (search "lookup-order" mcp-config)))
    (is (not (search "#<" mcp-config)))))

(test pinned-upstream-sdk-mcp-fixture-matches-lisp-catalog-and-router
  (let* ((fixture (read-sdk-mcp-upstream-fixture))
         (server-config (gethash "server_config" fixture))
         (tool-fixture (gethash "tool" fixture))
         (expected-result (gethash "call_result" fixture))
         (tool (claude-agent-sdk-cl:make-sdk-tool
                :name (gethash "name" tool-fixture)
                :description (gethash "description" tool-fixture)
                :input-schema (gethash "inputSchema" tool-fixture)
                :handler (lambda (arguments context)
                           (declare (ignore context))
                           (claude-agent-sdk-cl:make-sdk-tool-result
                            :text (format nil "Echo: ~A" (gethash "text" arguments))))))
         (server (claude-agent-sdk-cl:make-sdk-mcp-server
                  :name (gethash "name" server-config) :tools (list tool)))
         (options (claude-agent-sdk-cl:make-agent-options
                   :builtin-tools :none :strict-mcp-config t
                   :sdk-mcp-servers (list server)))
         (configuration (claude-agent-sdk-cl:agent-options->mcp-config options))
         (advertised (gethash (gethash "name" server-config)
                              (gethash "mcpServers" configuration)))
         (list-message (mcp-object "jsonrpc" "2.0" "id" "fixture-list"
                                   "method" "tools/list" "params" (mcp-object)))
         (call-params (mcp-object "name" (gethash "name" tool-fixture)
                                  "arguments" (mcp-object "text" "value")))
         (call-message (mcp-object "jsonrpc" "2.0" "id" "fixture-call"
                                   "method" "tools/call" "params" call-params))
         (list-response (claude-agent-sdk-cl::handle-sdk-mcp-message server list-message))
         (call-response (claude-agent-sdk-cl::handle-sdk-mcp-message server call-message)))
    (is (string= "sdk" (gethash "type" advertised)))
    (is (string= (gethash "name" server-config) (gethash "name" advertised)))
    (is (string= "fixture-list" (gethash "id" list-response)))
    (let ((listed (first (gethash "tools" (gethash "result" list-response)))))
      (is (string= (gethash "name" tool-fixture) (gethash "name" listed)))
      (is (string= (gethash "description" tool-fixture) (gethash "description" listed)))
      (is (json-value= (gethash "inputSchema" tool-fixture)
                        (gethash "inputSchema" listed))))
    (is (string= "fixture-call" (gethash "id" call-response)))
    (is (json-value= expected-result (gethash "result" call-response)))))

(test persistent-client-serves-sdk-mcp-initialize-list-and-call
  (let* ((calls 0)
         (tool (mcp-test-tool
                :handler (lambda (arguments context)
                           (declare (ignore context))
                           (incf calls)
                           (claude-agent-sdk-cl:make-sdk-tool-result
                            :text (format nil "order ~A" (gethash "order_id" arguments))))))
         (client (mcp-client
                  (mcp-server :tools (list tool))
                  (list (concatenate 'string +initialize-response+ +client-nl+)
                        (concatenate 'string
                                     (mcp-control-request "mcp-init" 1 "initialize") +client-nl+
                                     (mcp-control-request "mcp-list" 2 "tools/list") +client-nl+
                                     (mcp-control-request "mcp-call" 3 "tools/call"
                                                          (mcp-object "name" "lookup-order"
                                                                      "arguments" (mcp-object "order_id" "42")))
                                     +client-nl+
                                     +turn-one-assistant+ +client-nl+
                                     +client-result+ +client-nl+))))
         (transport (claude-agent-sdk-cl::client-transport-instance client)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (is (= 2 (length (claude-agent-sdk-cl:receive-response client))))
           (is (= 1 calls))
           (let ((responses (mapcar #'mcp-response-object
                                    (rest (reverse (fake-client-writes transport))))))
             (is (= 3 (length responses)))
             (is (string= "2024-11-05"
                          (gethash "protocolVersion" (gethash "result" (first responses)))))
             (let ((listed (gethash "tools" (gethash "result" (second responses)))))
               (is (= 1 (length listed)))
               (is (string= "lookup-order" (gethash "name" (first listed))))
               (is (hash-table-p (gethash "inputSchema" (first listed)))))
             (let ((content (gethash "content" (gethash "result" (third responses)))))
               (is (string= "order 42" (gethash "text" (first content)))))))
      (claude-agent-sdk-cl:disconnect client))))

(test subprocess-client-serves-sdk-mcp-tools-end-to-end
  ;; This uses the fake executable rather than injected chunks: it proves
  ;; options -> argv -> CLI subprocess -> correlated MCP control messages.
  (let* ((calls 0)
         (tool (mcp-test-tool
                :handler (lambda (arguments context)
                           (declare (ignore context))
                           (incf calls)
                           (claude-agent-sdk-cl:make-sdk-tool-result
                            :text (format nil "order ~A" (gethash "order_id" arguments))))))
         (server (mcp-server :tools (list tool)))
         (options (claude-agent-sdk-cl:make-agent-options
                   :sdk-mcp-servers (list server)
                   :builtin-tools :none
                   :strict-mcp-config t))
         (transport (claude-agent-sdk-cl::make-subprocess-client-transport
                     :cli-path "/workspace/test/fake-claude.sh"
                     :arguments (cons "mcp-client-smoke"
                                      (claude-agent-sdk-cl::one-shot-query-arguments options))))
         (client (claude-agent-sdk-cl:make-claude-sdk-client
                  :transport transport :options options)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (claude-agent-sdk-cl:send client "run mcp smoke")
           (let ((response (claude-agent-sdk-cl:receive-response client)))
             (is (= 2 (length response)))
             (is (string= "mcp done"
                          (claude-agent-sdk-cl:result-message-result (second response)))))
           (is (= 1 calls))
           (is (eq :connected (claude-agent-sdk-cl:client-state client))))
      (claude-agent-sdk-cl:disconnect client))))

(test persistent-sdk-mcp-handler-errors-are-safe-and-client-remains-usable
  (let* ((sentinel "MCP-SECRET-SENTINEL")
         (tool (mcp-test-tool
                :handler (lambda (arguments context)
                           (declare (ignore arguments context))
                           (error "handler failed with ~A" sentinel))))
         (client (mcp-client
                  (mcp-server :tools (list tool))
                  (list (concatenate 'string +initialize-response+ +client-nl+)
                        (concatenate 'string
                                     (mcp-control-request "handler-error" 9 "tools/call"
                                                          (mcp-object "name" "lookup-order"
                                                                      "arguments" (mcp-object)))
                                     +client-nl+
                                     +turn-one-assistant+ +client-nl+
                                     +client-result+ +client-nl+))))
         (transport (claude-agent-sdk-cl::client-transport-instance client)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (is (= 2 (length (claude-agent-sdk-cl:receive-response client))))
           (let ((error (gethash "error"
                                 (mcp-response-object
                                  (second (reverse (fake-client-writes transport)))))))
             (is (= -32603 (gethash "code" error)))
             (is (string= "SDK tool handler failed" (gethash "message" error)))
             (is (not (search sentinel (gethash "message" error)))))
           (is (eq :connected (claude-agent-sdk-cl:client-state client))))
      (claude-agent-sdk-cl:disconnect client))))

(test configured-sdk-catalog-rejects-shadowing-control-handlers-before-connect
  (let ((server (mcp-server)))
    ;; A generic MCP control handler would win the client router's direct-handler
    ;; lookup and silently dispatch a catalog to code other than its declaration.
    (signals claude-agent-sdk-cl:sdk-input-error
      (claude-agent-sdk-cl:make-claude-sdk-client
       :transport (make-instance 'fake-client-transport)
       :options (claude-agent-sdk-cl:make-agent-options
                 :sdk-mcp-servers (list server))
       :control-handlers (list (cons "mcp_message" (lambda (request)
                                                      (declare (ignore request))
                                                      (make-hash-table))))))
    (let ((client (claude-agent-sdk-cl:make-claude-sdk-client
                   :transport (make-instance 'fake-client-transport)
                   :options (claude-agent-sdk-cl:make-agent-options
                             :sdk-mcp-servers (list server)))))
      ;; Public manual registration remains available for unconfigured clients,
      ;; but cannot replace a generated handler for a typed catalog.
      (signals claude-agent-sdk-cl:sdk-input-error
        (claude-agent-sdk-cl:register-sdk-mcp-handler
         client "orders" (lambda (message) (declare (ignore message))
                           (make-hash-table))))
      ;; Registration after construction but before connect must not reopen the
      ;; generic subtype route that would shadow this catalog.
      (signals claude-agent-sdk-cl:sdk-input-error
        (claude-agent-sdk-cl:register-control-handler
         client "mcp_message" (lambda (request) (declare (ignore request))
                                (make-hash-table)))))))

(test resumed-client-requires-explicit-sdk-catalog-reconfiguration
  (let* ((server (mcp-server))
         (configured (claude-agent-sdk-cl:make-agent-options
                      :resume "session-1" :sdk-mcp-servers (list server)
                      :builtin-tools :none :strict-mcp-config t))
         (replacement (claude-agent-sdk-cl:make-agent-options :resume "session-1"))
         (configured-argv (claude-agent-sdk-cl::one-shot-query-arguments configured))
         (replacement-argv (claude-agent-sdk-cl::one-shot-query-arguments replacement)))
    (is (member "--mcp-config" configured-argv :test #'string=))
    (is (not (member "--mcp-config" replacement-argv :test #'string=)))
    (is (member "--resume=session-1" replacement-argv :test #'string=))))

(test persistent-sdk-mcp-errors-are-jsonrpc-and-client-remains-usable
  (let* ((client (mcp-client
                  (mcp-server)
                  (list (concatenate 'string +initialize-response+ +client-nl+)
                        (concatenate 'string
                                     (mcp-control-request "unknown" 7 "tools/call"
                                                          (mcp-object "name" "missing"
                                                                      "arguments" (mcp-object)))
                                     +client-nl+
                                     +turn-one-assistant+ +client-nl+
                                     +client-result+ +client-nl+))))
         (transport (claude-agent-sdk-cl::client-transport-instance client)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (is (= 2 (length (claude-agent-sdk-cl:receive-response client))))
           (let ((error (gethash "error"
                                 (mcp-response-object
                                  (second (reverse (fake-client-writes transport)))))))
             (is (= -32602 (gethash "code" error)))
             (is (search "missing" (gethash "message" error))))
           (is (eq :connected (claude-agent-sdk-cl:client-state client))))
      (claude-agent-sdk-cl:disconnect client))))
