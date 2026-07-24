(in-package #:claude-agent-sdk-cl)

(defstruct (agent-options (:constructor %make-agent-options))
  (allowed-tools '() :type list)
  (disallowed-tools '() :type list)
  permission-mode
  (continue-conversation nil :type boolean)
  model
  system-prompt
  resume)

(defun %string-list-or-error (value name)
  (unless (and (listp value) (every #'stringp value))
    (signal-sdk-input-error (format nil "~A must be a list of strings" name)))
  value)

(defun make-agent-options (&key (allowed-tools '()) (disallowed-tools '()) permission-mode
                              (continue-conversation nil) model system-prompt resume)
  (%string-list-or-error allowed-tools "allowed-tools")
  (%string-list-or-error disallowed-tools "disallowed-tools")
  (when (and permission-mode (not (stringp permission-mode)))
    (signal-sdk-input-error "permission-mode must be a string or NIL"))
  (when (and model (not (stringp model)))
    (signal-sdk-input-error "model must be a string or NIL"))
  (%make-agent-options :allowed-tools (copy-list allowed-tools)
                       :disallowed-tools (copy-list disallowed-tools)
                       :permission-mode permission-mode
                       :continue-conversation continue-conversation
                       :model model :system-prompt system-prompt :resume resume))

(defun agent-options->wire (options)
  (let ((wire (make-hash-table :test #'equal)))
    (setf (gethash "allowedTools" wire) (agent-options-allowed-tools options)
          (gethash "disallowedTools" wire) (agent-options-disallowed-tools options)
          (gethash "continue" wire) (agent-options-continue-conversation options))
    (when (agent-options-permission-mode options)
      (setf (gethash "permissionMode" wire) (agent-options-permission-mode options)))
    (when (agent-options-model options)
      (setf (gethash "model" wire) (agent-options-model options)))
    (when (agent-options-system-prompt options)
      (setf (gethash "systemPrompt" wire) (agent-options-system-prompt options)))
    (when (agent-options-resume options)
      (setf (gethash "resume" wire) (agent-options-resume options)))
    wire))
