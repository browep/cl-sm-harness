(defpackage #:sm-harness
  (:use #:cl)
  (:export
   #:harness-config #:make-harness-config
   #:harness-config-data-root #:harness-config-project-key
   #:harness-config-idle-ttl-seconds #:harness-config-turn-deadline-seconds
   #:make-harness #:close-harness
   #:start-session #:list-sessions #:open-session
   #:submit-turn #:interrupt-turn
   #:attach-session-listener #:detach-session-listener
   #:session-status
   #:make-event #:event-type #:event-sequence #:event-session-id #:event-payload
   #:session-snapshot #:session-snapshot-id #:session-snapshot-title
   #:session-snapshot-status #:session-snapshot-canonical-id
   #:session-snapshot-transcript #:session-snapshot-cursor
   #:session-summary #:session-summary-id #:session-summary-title
   #:session-summary-updated-at #:session-summary-status
   #:session-summary-canonical-id
   #:transcript-entry #:transcript-entry-role #:transcript-entry-text
   #:transcript-entry-kind #:transcript-entry-meta #:transcript-entry-created-at
   #:default-tool-catalog #:default-tool-policy
   #:make-tool-policy #:tool-policy-builtin-tools #:tool-policy-strict-mcp-p
   #:tool-policy-allowed-tools #:tool-policy-disallowed-tools
   #:tool-catalog #:tool-catalog-servers
   #:tool-server-definition #:tool-server-definition-name #:tool-server-definition-version
   #:tool-server-definition-tools
   #:tool-definition #:tool-definition-name #:tool-definition-description
   #:tool-definition-input-schema #:tool-definition-handler
   #:harness-error #:harness-error-message
   #:harness-input-error #:harness-state-error #:harness-not-found-error))
