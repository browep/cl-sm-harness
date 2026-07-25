(defpackage #:claude-agent-sdk-cl
  (:use #:cl)
  (:export #:sdk-version
           #:sdk-error #:sdk-input-error #:cli-connection-error #:cli-not-found-error
           #:cli-json-error #:process-error #:process-error-exit-code #:process-error-stderr
           #:signal-sdk-input-error #:signal-cli-json-error #:signal-process-error
           #:agent-options #:make-agent-options #:agent-options-allowed-tools
           #:agent-options-disallowed-tools #:agent-options-continue-conversation
           #:agent-options->wire
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
           #:system-message-subtype #:system-message-data))
