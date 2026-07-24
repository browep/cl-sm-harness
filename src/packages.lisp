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
           #:permission-update->wire))
