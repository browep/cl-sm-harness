(in-package #:sm-harness)

;;;; Sole production boundary that calls claude-agent-sdk-cl exports.

(defun %sdk-tool-from-definition (definition)
  ;; #142: *CURRENT-SESSION-RECORD* (tool-catalog.lisp) is read here, once,
  ;; synchronously, while %ENSURE-CLIENT's LET* still has it genuinely
  ;; bound -- captured into CALLING-SESSION-ID and baked into the wrapper
  ;; closure below, which is safe precisely because that wrapper (unlike
  ;; TOOL-DEFINITION-HANDLER, always a late-bound symbol so RELOAD_HARNESS
  ;; reaches it) is already rebuilt fresh every connection and already
  ;; captures DEFINITION itself the same way. Passed to the handler via
  ;; CONTEXT -- a genuine argument -- rather than left as an ambient
  ;; special, because every MCP tool call actually runs on a freshly
  ;; spawned thread (CLAUDE-AGENT-SDK-CL's %CLIENT-SPAWN-TOOL-THREAD) that
  ;; was never inside %ENSURE-CLIENT's dynamic extent, so a handler reading
  ;; *CURRENT-SESSION-RECORD* directly always saw NIL there.
  (let ((calling-session-id
          (and *current-session-record*
               (session-record-id *current-session-record*))))
    (claude-agent-sdk-cl:make-sdk-tool
     :name (tool-definition-name definition)
     :description (tool-definition-description definition)
     :input-schema (tool-definition-input-schema definition)
     ;; #123: pass this catalog's own MCP ToolAnnotations plist straight
     ;; through -- claude-agent-sdk-cl:make-sdk-tool validates and serves it
     ;; on the tools/list wire, and its own client uses :read-only-p to decide
     ;; whether a call needs its belt-and-suspenders TOOL-EXECUTION-LOCK.
     :annotations (tool-definition-annotations definition)
     :handler (lambda (arguments context)
                ;; A handler returning a single value (the existing echo_text
                ;; contract) gets IS-ERROR nil for free: an unrequested extra
                ;; value from MULTIPLE-VALUE-BIND is nil. A handler that wants
                ;; to report a domain-level failure (not a Lisp condition, so
                ;; not the existing raise-to-JSON-RPC-error path) returns
                ;; (VALUES text t). A third value, CONTENT, is an optional
                ;; escape hatch (see TOOL-CATALOG.LISP's TOOL-DEFINITION
                ;; HANDLER slot doc) -- when non-NIL it is passed straight
                ;; through as MAKE-SDK-TOOL-RESULT's :CONTENT instead of
                ;; wrapping RESULT as a single text block, the mechanism
                ;; VIEW_IMAGE uses to return an actual MCP image content
                ;; block rather than text.
                (multiple-value-bind (result is-error content)
                    (funcall (tool-definition-handler definition) arguments
                             (list* :calling-session-id calling-session-id context))
                  (if content
                      (claude-agent-sdk-cl:make-sdk-tool-result
                       :content content
                       :is-error (and is-error t))
                      (claude-agent-sdk-cl:make-sdk-tool-result
                       :text (princ-to-string result)
                       :is-error (and is-error t))))))))

(defun %sdk-server-from-definition (server)
  (claude-agent-sdk-cl:make-sdk-mcp-server
   :name (tool-server-definition-name server)
   :version (tool-server-definition-version server)
   :tools (mapcar #'%sdk-tool-from-definition
                  (tool-server-definition-tools server))))

(defun %sdk-catalog (catalog)
  (mapcar #'%sdk-server-from-definition (tool-catalog-servers catalog)))

(defun build-agent-options (catalog policy &key resume model system-prompt)
  "Map catalog availability to session-start options with automatic execution."
  (claude-agent-sdk-cl:make-agent-options
   :builtin-tools (tool-policy-builtin-tools policy)
   :sdk-mcp-servers (%sdk-catalog catalog)
   :strict-mcp-config (tool-policy-strict-mcp-p policy)
   :permission-mode "bypassPermissions"
   :resume resume
   :model model
   :system-prompt system-prompt))

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

(defun %mcp-content-text (content)
  "Best-effort readable text from a tool-result-block's CONTENT: a list of
MCP content blocks (each typically a {\"type\":\"text\",\"text\":...} hash
table, the shape MAKE-SDK-TOOL-RESULT's :TEXT produces on the wire), a bare
string, or an opaque JSON value from a content shape this catalog does not
model further. Never the raw Lisp print representation of a decoded value."
  (cond
    ((stringp content) content)
    ((listp content)
     (with-output-to-string (out)
       (dolist (block content)
         (when (and (hash-table-p block)
                    (equal (gethash "type" block) "text")
                    (stringp (gethash "text" block)))
           (write-string (gethash "text" block) out)))))
    (t "")))

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
           (claude-agent-sdk-cl:thinking-block
            (push (list :system :subtype "thinking" :text "[thinking omitted]") events))))
       (when (and text (plusp (length text)))
         (push (list :assistant-text :text text) events))
       (nreverse events)))
    ((typep message 'claude-agent-sdk-cl:user-message)
     ;; The CLI returns a tool result wrapped in a type="user" message; its
     ;; tool-result-block never appears inside an assistant message. A
     ;; user-message with no tool-result content originates nothing new here
     ;; (the harness itself is the sole source of outbound user turns).
     (let ((events '()))
       (dolist (block (claude-agent-sdk-cl:user-message-content message))
         (typecase block
           (claude-agent-sdk-cl:tool-result-block
            (push (list (if (claude-agent-sdk-cl:tool-result-block-is-error block)
                            :tool-failed
                            :tool-completed)
                        :tool-use-id (claude-agent-sdk-cl:tool-result-block-tool-use-id block)
                        :content (%mcp-content-text
                                  (claude-agent-sdk-cl:tool-result-block-content block))
                        :is-error (claude-agent-sdk-cl:tool-result-block-is-error block))
                  events))))
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
     ;; #102: previously dropped every field, leaving the UI nothing to
     ;; render but the bare event type. rate-limit-info is always present
     ;; (decode-rate-limit-event requires it before constructing the
     ;; event), so these accessors never signal here even when an
     ;; individual field's own value happens to be NIL.
     (let ((info (claude-agent-sdk-cl:rate-limit-event-rate-limit-info message)))
       (list (list :rate-limit
                   :status (claude-agent-sdk-cl:rate-limit-info-status info)
                   :rate-limit-type (claude-agent-sdk-cl:rate-limit-info-rate-limit-type info)
                   :utilization (claude-agent-sdk-cl:rate-limit-info-utilization info)
                   :resets-at (claude-agent-sdk-cl:rate-limit-info-resets-at info)
                   :overage-status (claude-agent-sdk-cl:rate-limit-info-overage-status info)
                   :overage-resets-at (claude-agent-sdk-cl:rate-limit-info-overage-resets-at info)
                   :overage-disabled-reason (claude-agent-sdk-cl:rate-limit-info-overage-disabled-reason info)))))
    (t
     (list (list :unrecognized :class (symbol-name (class-name (class-of message))))))))

(defun safe-error-payload (condition)
  "Return the deliberately non-diagnostic public error contract.
Detailed SDK and repository conditions belong only in private diagnostics."
  (declare (ignore condition))
  (list :message "internal error"))
