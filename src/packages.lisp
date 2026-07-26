(defpackage #:claude-agent-sdk-cl
  (:use #:cl)
  (:export #:sdk-version
           #:sdk-error #:sdk-input-error #:cli-connection-error #:cli-not-found-error
           #:client-lifecycle-error #:client-lifecycle-error-operation #:client-lifecycle-error-state
           #:cli-json-error #:process-error #:process-error-exit-code #:process-error-stderr
           #:signal-sdk-input-error #:signal-cli-json-error #:signal-process-error
           #:make-agent-options #:agent-options #:agent-options-allowed-tools
           #:agent-options-disallowed-tools #:agent-options-permission-mode
           #:agent-options-continue-conversation #:agent-options-model
           #:agent-options-system-prompt #:agent-options-resume
           #:normalize-session-id #:normalize-session-path
           #:session-import-plan #:make-session-import-plan #:session-import-plan-session-id #:session-import-plan-path
           #:session-mutation-plan #:make-session-mutation-plan #:session-mutation-plan-operation
           #:session-mutation-plan-session-id #:session-mutation-plan-value #:session-mutation-plan-target-id
           #:session-key #:make-session-key #:session-key-project-key #:session-key-session-id #:session-key-subpath
           #:session-store #:in-memory-session-store #:make-in-memory-session-store
           #:session-store-append #:session-store-load #:session-store-list-sessions #:session-store-list-subkeys
           #:session-store-mirror-message
           #:message #:user-message #:assistant-message #:message-extra
           #:assistant-message-content #:assistant-message-model
           #:text-block #:text-block-text #:thinking-block #:tool-use-block #:tool-result-block
           #:decode-message #:decode-permission-update #:permission-update #:permission-update-type
           #:permission-update->wire
           #:result-message #:decode-result-message
           #:result-message-subtype #:result-message-duration-ms #:result-message-duration-api-ms
           #:result-message-is-error #:result-message-num-turns #:result-message-session-id
           #:result-message-stop-reason #:result-message-total-cost-usd #:result-message-usage
           #:result-message-result #:result-message-structured-output #:result-message-model-usage
           #:result-message-permission-denials #:result-message-deferred-tool-use
           #:result-message-errors #:result-message-api-error-status #:result-message-uuid
           #:result-message-terminal-reason
           #:query #:query-transport #:read-query-chunk
           #:start-query-transport #:close-query-transport
           #:system-message #:decode-system-message
           #:system-message-subtype #:system-message-data
           #:rate-limit-event #:decode-rate-limit-event #:rate-limit-event-rate-limit-info
           #:rate-limit-event-uuid #:rate-limit-event-session-id
           #:rate-limit-info #:rate-limit-info-status #:rate-limit-info-resets-at
           #:rate-limit-info-rate-limit-type #:rate-limit-info-utilization
           #:rate-limit-info-overage-status #:rate-limit-info-overage-resets-at
           #:rate-limit-info-overage-disabled-reason #:rate-limit-info-raw
           #:permission-result-allow #:make-permission-result-allow
           #:permission-result-allow-updated-input #:permission-result-allow-updated-permissions
           #:permission-result-deny #:make-permission-result-deny
           #:permission-result-deny-message #:permission-result-deny-interrupt
           #:hook-callback-result #:make-hook-callback-result #:hook-callback-result-data
           #:mcp-control-result #:make-mcp-control-result #:mcp-control-result-response
           #:register-control-handler #:client-control-handlers
           #:register-hook-callback #:register-sdk-mcp-handler
           #:claude-sdk-client #:make-claude-sdk-client #:client-state
           #:client-transport #:start-client-transport #:read-client-chunk
           #:write-client-input #:close-client-transport
           #:connect #:send #:receive-message #:receive-response #:interrupt #:disconnect))
