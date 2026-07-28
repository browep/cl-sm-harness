(in-package #:sm-harness)

;;;; Sole production boundary that calls claude-agent-sdk-cl exports.

(defun %sdk-tool-from-definition (definition)
  (claude-agent-sdk-cl:make-sdk-tool
   :name (tool-definition-name definition)
   :description (tool-definition-description definition)
   :input-schema (tool-definition-input-schema definition)
   :handler (lambda (arguments context)
              (let ((result (funcall (tool-definition-handler definition)
                                     arguments context)))
                (claude-agent-sdk-cl:make-sdk-tool-result
                 :text (princ-to-string result))))))

(defun %sdk-server-from-definition (server)
  (claude-agent-sdk-cl:make-sdk-mcp-server
   :name (tool-server-definition-name server)
   :version (tool-server-definition-version server)
   :tools (mapcar #'%sdk-tool-from-definition
                  (tool-server-definition-tools server))))

(defun %sdk-catalog (catalog)
  (mapcar #'%sdk-server-from-definition (tool-catalog-servers catalog)))

(defun build-agent-options (catalog policy &key resume model)
  "Map catalog availability to session-start options with automatic execution."
  (claude-agent-sdk-cl:make-agent-options
   :builtin-tools (tool-policy-builtin-tools policy)
   :sdk-mcp-servers (%sdk-catalog catalog)
   :strict-mcp-config (tool-policy-strict-mcp-p policy)
   :permission-mode "bypassPermissions"
   :resume resume
   :model model))

(defun make-sdk-client (options &key transport cli-path control-handlers)
  (apply #'claude-agent-sdk-cl:make-claude-sdk-client
         :options options
         :control-handlers control-handlers
         (append (when transport (list :transport transport))
                 (when cli-path (list :cli-path cli-path)))))

(defun connect-client (client)
  (claude-agent-sdk-cl:connect client))

(defun disconnect-client (client)
  (claude-agent-sdk-cl:disconnect client))

(defun send-prompt (client prompt &key (session-id "default"))
  (claude-agent-sdk-cl:send client prompt :session-id session-id))

(defun request-interrupt-client (client)
  (claude-agent-sdk-cl:request-interrupt client))

(defun interrupt-client (client)
  (claude-agent-sdk-cl:interrupt client))

(defun receive-one-message (client)
  (claude-agent-sdk-cl:receive-message client))

(defun assistant-text (message)
  (with-output-to-string (out)
    (dolist (block (claude-agent-sdk-cl:assistant-message-content message))
      (typecase block
        (claude-agent-sdk-cl:text-block
         (write-string (claude-agent-sdk-cl:text-block-text block) out))))))

(defun map-sdk-message (message)
  "Convert a typed SDK message into a list of frontend-neutral event payloads.
Each item is (event-type . plist-or-string)."
  (cond
    ((typep message 'claude-agent-sdk-cl:assistant-message)
     (let ((events '())
           (text (assistant-text message)))
       (dolist (block (claude-agent-sdk-cl:assistant-message-content message))
         (typecase block
           (claude-agent-sdk-cl:tool-use-block
            (push (list :tool-requested
                        :id (claude-agent-sdk-cl:tool-use-block-id block)
                        :name (claude-agent-sdk-cl:tool-use-block-name block)
                        :input (claude-agent-sdk-cl:tool-use-block-input block))
                  events))
           (claude-agent-sdk-cl:tool-result-block
            (push (list (if (claude-agent-sdk-cl:tool-result-block-is-error block)
                            :tool-failed
                            :tool-completed)
                        :tool-use-id (claude-agent-sdk-cl:tool-result-block-tool-use-id block)
                        :content (claude-agent-sdk-cl:tool-result-block-content block)
                        :is-error (claude-agent-sdk-cl:tool-result-block-is-error block))
                  events))
           (claude-agent-sdk-cl:thinking-block
            (push (list :system :subtype "thinking" :text "[thinking omitted]") events))))
       (when (and text (plusp (length text)))
         (push (list :assistant-text :text text) events))
       (nreverse events)))
    ((typep message 'claude-agent-sdk-cl:result-message)
     (list (list :terminal
                 :subtype (claude-agent-sdk-cl:result-message-subtype message)
                 :is-error (claude-agent-sdk-cl:result-message-is-error message)
                 :text (or (claude-agent-sdk-cl:result-message-result message) "")
                 :session-id (claude-agent-sdk-cl:result-message-session-id message)
                 :stop-reason (claude-agent-sdk-cl:result-message-stop-reason message))))
    ((typep message 'claude-agent-sdk-cl:system-message)
     (list (list :system
                 :subtype (claude-agent-sdk-cl:system-message-subtype message))))
    ((typep message 'claude-agent-sdk-cl:rate-limit-event)
     (list (list :rate-limit)))
    (t
     (list (list :unrecognized :class (symbol-name (class-name (class-of message))))))))

(defun safe-error-payload (condition)
  (list :message
        (typecase condition
          (claude-agent-sdk-cl:sdk-error
           (princ-to-string condition))
          (harness-error (harness-error-message condition))
          (t "internal error"))))
