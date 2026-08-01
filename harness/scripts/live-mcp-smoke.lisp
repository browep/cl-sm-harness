;;;; Opt-in #20 live SDK MCP discovery/invocation smoke. Invoked only as
;;;; `test.sh live-mcp` in the credential-scoped Compose service.
;;;; Prints only lifecycle counts/status: never credentials, raw prompts,
;;;; arguments, control records, or model/tool payloads.

(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun json-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key object) value))
    object))

(let* ((calls 0)
       (tool (claude-agent-sdk-cl:make-sdk-tool
              :name "echo_marker"
              :description "Returns the fixed SDK MCP smoke marker."
              ;; This v1 schema surface accepts JSON values representable by
              ;; Yason; omit JSON false rather than confusing it with NIL/null.
              :input-schema (json-object "type" "object"
                                         "properties" (json-object))
              :handler (lambda (arguments context)
                         (declare (ignore arguments context))
                         (incf calls)
                         (claude-agent-sdk-cl:make-sdk-tool-result
                          :text "SDK MCP smoke marker"))))
       (server (claude-agent-sdk-cl:make-sdk-mcp-server
                :name "live_sdk" :version "1.0.0" :tools (list tool)))
       (options (claude-agent-sdk-cl:make-agent-options
                 :builtin-tools :none
                 :sdk-mcp-servers (list server)
                 :strict-mcp-config t
                 ;; This is invocation permission policy, distinct from
                 ;; discovery/availability above.
                 :allowed-tools '("mcp__live_sdk__echo_marker")))
       (client (claude-agent-sdk-cl:make-claude-sdk-client
                :options options :timeout 120)))
  (unwind-protect
       (progn
         (claude-agent-sdk-cl:connect client)
         (claude-agent-sdk-cl:send
          client
          "Invoke the mcp__live_sdk__echo_marker tool exactly once, then briefly confirm completion.")
         (let* ((messages (claude-agent-sdk-cl:receive-response client))
                (result (find-if (lambda (message)
                                   (typep message 'claude-agent-sdk-cl:result-message))
                                 messages)))
           (unless result
             (error "SDK MCP live smoke ended without a result-message."))
           (when (claude-agent-sdk-cl:result-message-is-error result)
             (error "SDK MCP live smoke returned error subtype ~S."
                    (claude-agent-sdk-cl:result-message-subtype result)))
           (unless (= calls 1)
             (error "SDK MCP live smoke expected one handler invocation, got ~D." calls))
           (format t "live-mcp: handler-calls=~D messages=~D result-subtype=~A~%"
                   calls (length messages)
                   (claude-agent-sdk-cl:result-message-subtype result))))
    (claude-agent-sdk-cl:disconnect client)))
