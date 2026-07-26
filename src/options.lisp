(in-package #:claude-agent-sdk-cl)

(defstruct (agent-options (:constructor %make-agent-options))
  (allowed-tools '() :type list)
  (disallowed-tools '() :type list)
  permission-mode
  (continue-conversation nil :type boolean)
  model
  system-prompt
  resume
  ;; Phase 7B configuration only; the generic store protocol arrives in 7C.
  session-store
  (session-store-list-sessions-p nil :type boolean)
  (enable-file-checkpointing nil :type boolean)
  session-path)

(defun %string-list-or-error (value name)
  (unless (and (listp value) (every #'stringp value))
    (signal-sdk-input-error (format nil "~A must be a list of strings" name)))
  value)

(defun normalize-session-id (value)
  "Validate an opaque CLI session identifier without over-constraining legacy IDs."
  (unless (and (stringp value) (> (length value) 0)
               (not (search ".." value))
               (not (find #\/ value)) (not (find #\\ value))
               (not (find #\Null value)) (not (find #\Newline value)))
    (signal-sdk-input-error "session ID must be non-empty and traversal-safe"))
  value)

(defun normalize-session-path (value)
  "Validate an import/export path: relative paths may not escape their root."
  (unless (and (stringp value) (> (length value) 0)
               (not (find #\Null value))
               (not (find #\Newline value))
               (not (search "../" value))
               (not (search "..\\" value))
               (not (string= value "..")))
    (signal-sdk-input-error "session path must be non-empty and traversal-safe"))
  value)

(defstruct (session-import-plan (:constructor %make-session-import-plan))
  session-id path (include-subagents t :type boolean))

(defstruct (session-mutation-plan (:constructor %make-session-mutation-plan))
  operation session-id value target-id)

(defun make-session-import-plan (&key session-id path (include-subagents t))
  "Create a validated, side-effect-free local transcript import plan.
Actual store append behavior is deliberately Phase 7C work."
  (normalize-session-id session-id)
  (normalize-session-path path)
  (unless (typep include-subagents 'boolean)
    (signal-sdk-input-error "include-subagents must be boolean"))
  (%make-session-import-plan :session-id session-id :path path :include-subagents include-subagents))

(defun make-session-mutation-plan (&key operation session-id value target-id)
  "Validate a future local/store session mutation without performing I/O.
OPERATION is one of :RENAME, :TAG, :DELETE, or :FORK."
  (unless (member operation '(:rename :tag :delete :fork))
    (signal-sdk-input-error "session mutation operation must be :rename, :tag, :delete, or :fork"))
  (normalize-session-id session-id)
  (when target-id (normalize-session-id target-id))
  (when (member operation '(:rename :tag))
    (unless (and (stringp value) (> (length (string-trim '(#\Space #\Tab #\Newline) value)) 0))
      (signal-sdk-input-error "rename/tag value must be non-empty")))
  (when (and (eq operation :fork) target-id (string= session-id target-id))
    (signal-sdk-input-error "fork target ID must differ from source ID"))
  (%make-session-mutation-plan :operation operation :session-id session-id
                               :value value :target-id target-id))

(defun %validate-session-options (continue-conversation resume session-store
                                  session-store-list-sessions-p enable-file-checkpointing session-path)
  (when resume (normalize-session-id resume))
  (when session-path (normalize-session-path session-path))
  (when (and session-store enable-file-checkpointing)
    (signal-sdk-input-error "session-store cannot be combined with file checkpointing"))
  (when (and session-store continue-conversation (null resume)
             (not session-store-list-sessions-p))
    (signal-sdk-input-error "continue-conversation with session-store requires list-sessions capability")))

(defun make-agent-options (&key (allowed-tools '()) (disallowed-tools '()) permission-mode
                               (continue-conversation nil) model system-prompt resume
                               session-store (session-store-list-sessions-p nil)
                               (enable-file-checkpointing nil) session-path)
  (%string-list-or-error allowed-tools "allowed-tools")
  (%string-list-or-error disallowed-tools "disallowed-tools")
  (when (and permission-mode (not (stringp permission-mode)))
    (signal-sdk-input-error "permission-mode must be a string or NIL"))
  (when (and model (not (stringp model)))
    (signal-sdk-input-error "model must be a string or NIL"))
  (%validate-session-options continue-conversation resume session-store
                             session-store-list-sessions-p enable-file-checkpointing session-path)
  (%make-agent-options :allowed-tools (copy-list allowed-tools)
                       :disallowed-tools (copy-list disallowed-tools)
                       :permission-mode permission-mode
                       :continue-conversation continue-conversation
                       :model model :system-prompt system-prompt :resume resume
                       :session-store session-store
                       :session-store-list-sessions-p session-store-list-sessions-p
                       :enable-file-checkpointing enable-file-checkpointing
                       :session-path session-path))

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
