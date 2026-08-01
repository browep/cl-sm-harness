(defpackage #:sm-harness
  (:use #:cl)
  (:export
   #:harness-config #:make-harness-config
   #:harness-config-data-root #:harness-config-project-key
   #:harness-config-idle-ttl-seconds #:harness-config-turn-deadline-seconds
   #:make-harness #:close-harness #:mark-sessions-for-catalog-refresh
   #:start-session #:list-sessions #:open-session
   #:submit-turn #:interrupt-turn #:evict-idle-sessions #:set-session-title
   #:attach-session-listener #:detach-session-listener
   #:session-status
   #:make-event #:event-type #:event-sequence #:event-session-id #:event-payload
   #:session-snapshot #:session-snapshot-id #:session-snapshot-title
   #:session-snapshot-status #:session-snapshot-canonical-id
   #:session-snapshot-transcript #:session-snapshot-cursor
   #:session-snapshot-backend #:session-snapshot-model
   #:session-summary #:make-session-summary #:session-summary-id #:session-summary-title
   #:session-summary-updated-at #:session-summary-status
   #:session-summary-canonical-id
   #:session-summary-backend #:session-summary-model
   ;; #111: home-screen chip metadata -- when the session started and how
   ;; many user-initiated turns it has had.
   #:session-summary-created-at #:session-summary-turn-count
   #:transcript-entry #:transcript-entry-role #:transcript-entry-text
   #:transcript-entry-kind #:transcript-entry-meta #:transcript-entry-created-at
   #:default-tool-catalog #:default-tool-policy #:*reload-harness-system*
   #:*post-reload-hook* #:*tool-harness*
   #:make-tool-policy #:tool-policy-builtin-tools #:tool-policy-strict-mcp-p
   #:tool-catalog #:tool-catalog-servers
   #:tool-server-definition #:tool-server-definition-name #:tool-server-definition-version
   #:tool-server-definition-tools
   #:tool-definition #:tool-definition-name #:tool-definition-description
   #:tool-definition-input-schema #:tool-definition-handler #:tool-definition-annotations
   #:harness-error #:harness-error-message
   #:harness-input-error #:harness-state-error #:harness-not-found-error
   ;; #106: static backend/model catalog for session creation + viewing.
   #:backend-catalog #:backend-descriptor #:backend-descriptor-id
   #:backend-descriptor-label #:backend-descriptor-models
   #:model-descriptor #:model-descriptor-id #:model-descriptor-label
   #:find-backend #:find-model #:valid-backend-id-p #:valid-model-id-p
   #:*default-backend-id* #:*default-model-id*))
