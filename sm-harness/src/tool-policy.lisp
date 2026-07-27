(in-package #:sm-harness)

(defstruct (tool-policy (:constructor %make-tool-policy))
  (builtin-tools :none)
  (strict-mcp-p t)
  (allowed-tools '() :type list)
  (disallowed-tools '() :type list)
  (permission-mode "default"))

(defun make-tool-policy (&key (builtin-tools :none)
                              (strict-mcp-p t)
                              (allowed-tools '())
                              (disallowed-tools '())
                              (permission-mode "default"))
  (%make-tool-policy
   :builtin-tools builtin-tools
   :strict-mcp-p strict-mcp-p
   :allowed-tools (copy-list allowed-tools)
   :disallowed-tools (copy-list disallowed-tools)
   :permission-mode permission-mode))

(defun default-tool-policy ()
  "SDK-tools-only product default: no Claude Code builtins, strict ambient MCP off."
  (make-tool-policy
   :builtin-tools :none
   :strict-mcp-p t
   ;; Permission allowlist uses qualified MCP names.
   :allowed-tools '("mcp__sm_harness__echo_text")
   :disallowed-tools '()
   :permission-mode "default"))

(defun %can-use-tool-handler (policy)
  (lambda (request)
    (let* ((name (and (hash-table-p request) (gethash "tool_name" request)))
           (allowed (tool-policy-allowed-tools policy))
           (denied (tool-policy-disallowed-tools policy)))
      (cond
        ((and (stringp name) (member name denied :test #'string=))
         (claude-agent-sdk-cl:make-permission-result-deny
          :message (format nil "tool denied by policy: ~A" name)
          :interrupt nil))
        ((null allowed)
         ;; Empty allowlist with default-deny for unknown when we want strict.
         (if (and (stringp name)
                  (or (null (tool-policy-strict-mcp-p policy))
                      (search "mcp__" name :test #'char=)))
             (claude-agent-sdk-cl:make-permission-result-allow)
             (claude-agent-sdk-cl:make-permission-result-deny
              :message (format nil "tool not allowlisted: ~A" name)
              :interrupt nil)))
        ((and (stringp name) (member name allowed :test #'string=))
         (claude-agent-sdk-cl:make-permission-result-allow))
        (t
         (claude-agent-sdk-cl:make-permission-result-deny
          :message (format nil "tool not allowlisted: ~A" name)
          :interrupt nil))))))
