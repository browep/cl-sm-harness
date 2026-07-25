(in-package #:claude-agent-sdk-cl)

(defclass message () ((extra :initarg :extra :initform (make-hash-table :test #'equal) :reader message-extra)))
(defclass user-message (message) ((content :initarg :content :reader user-message-content)))
(defclass assistant-message (message)
  ((content :initarg :content :reader assistant-message-content)
   (model :initarg :model :reader assistant-message-model)))
(defclass text-block () ((text :initarg :text :reader text-block-text)))
(defclass thinking-block () ((thinking :initarg :thinking :reader thinking-block-thinking) (signature :initarg :signature :reader thinking-block-signature)))
(defclass tool-use-block () ((id :initarg :id :reader tool-use-block-id) (name :initarg :name :reader tool-use-block-name) (input :initarg :input :reader tool-use-block-input)))
(defclass tool-result-block () ((tool-use-id :initarg :tool-use-id :reader tool-result-block-tool-use-id) (content :initarg :content :reader tool-result-block-content) (is-error :initarg :is-error :initform nil :reader tool-result-block-is-error)))
(defclass unknown-content-block () ((raw :initarg :raw :reader unknown-content-block-raw)))
(defclass permission-update () ((type :initarg :type :reader permission-update-type) (wire :initarg :wire :reader permission-update-wire)))

(defclass system-message (message)
  ((subtype :initarg :subtype :reader system-message-subtype)
   (data :initarg :data :reader system-message-data)))

(defclass result-message (message)
  ((subtype :initarg :subtype :reader result-message-subtype)
   (duration-ms :initarg :duration-ms :reader result-message-duration-ms)
   (duration-api-ms :initarg :duration-api-ms :reader result-message-duration-api-ms)
   (is-error :initarg :is-error :reader result-message-is-error)
   (num-turns :initarg :num-turns :reader result-message-num-turns)
   (session-id :initarg :session-id :reader result-message-session-id)
   (stop-reason :initarg :stop-reason :reader result-message-stop-reason)
   (total-cost-usd :initarg :total-cost-usd :reader result-message-total-cost-usd)
   (usage :initarg :usage :reader result-message-usage)
   (result :initarg :result :reader result-message-result)
   (structured-output :initarg :structured-output :reader result-message-structured-output)
   (model-usage :initarg :model-usage :reader result-message-model-usage)
   (permission-denials :initarg :permission-denials :reader result-message-permission-denials)
   (deferred-tool-use :initarg :deferred-tool-use :reader result-message-deferred-tool-use)
   (errors :initarg :errors :reader result-message-errors)
   (api-error-status :initarg :api-error-status :reader result-message-api-error-status)
   (uuid :initarg :uuid :reader result-message-uuid)
   (terminal-reason :initarg :terminal-reason :reader result-message-terminal-reason)))

(defun %object (value context)
  (unless (hash-table-p value) (signal-cli-json-error context))
  value)

(defun %extra-fields (object known)
  (let ((extra (make-hash-table :test #'equal)))
    (maphash (lambda (key value) (unless (member key known :test #'equal) (setf (gethash key extra) value))) object)
    extra))

(defun decode-content-block (wire)
  (%object wire "content block must be an object")
  (let ((type (gethash "type" wire)))
    (cond
      ((equal type "text") (make-instance 'text-block :text (or (gethash "text" wire) "")))
      ((equal type "thinking") (make-instance 'thinking-block :thinking (or (gethash "thinking" wire) "") :signature (gethash "signature" wire)))
      ((equal type "tool_use") (make-instance 'tool-use-block :id (gethash "id" wire) :name (gethash "name" wire) :input (gethash "input" wire)))
      ((equal type "tool_result") (make-instance 'tool-result-block :tool-use-id (gethash "tool_use_id" wire) :content (gethash "content" wire) :is-error (gethash "is_error" wire)))
      (t (make-instance 'unknown-content-block :raw wire)))))

(defun decode-message (wire)
  (%object wire "message envelope must be an object")
  (let* ((type (gethash "type" wire)) (body (%object (gethash "message" wire) "message body must be an object"))
         (content (gethash "content" body)))
    (unless (listp content) (signal-cli-json-error "message content must be a list"))
    (let ((blocks (mapcar #'decode-content-block content))
          (extra (%extra-fields wire '("type" "message"))))
      (cond
        ((equal type "user") (make-instance 'user-message :content blocks :extra extra))
        ((equal type "assistant") (make-instance 'assistant-message :content blocks :model (gethash "model" body) :extra extra))
        (t (signal-cli-json-error (format nil "unsupported message type: ~A" type)))))))

(defun decode-permission-update (wire)
  (%object wire "permission update must be an object")
  (make-instance 'permission-update :type (gethash "type" wire) :wire wire))

(defun decode-system-message (wire)
  "Decode a top-level type=\"system\" record. Preserves the full raw wire on
`data' (callers can read un-modelled system fields) and keeps unknown fields in
message-extra. Subtype-aware modelling (task_started, hook lifecycle, ...) is a
later parity slice; a generic system-message is enough to not crash live streams."
  (%object wire "system message must be an object")
  (unless (equal "system" (gethash "type" wire))
    (signal-cli-json-error "system message type must be \"system\""))
  (unless (gethash "subtype" wire)
    (signal-cli-json-error "system message missing \"subtype\""))
  (make-instance 'system-message
                 :subtype (gethash "subtype" wire)
                 :data wire
                 :extra (%extra-fields wire '("type" "subtype"))))

(defparameter +result-message-known-fields+
  '("type" "subtype" "duration_ms" "duration_api_ms" "is_error"
    "num_turns" "session_id" "stop_reason" "total_cost_usd" "usage"
    "result" "structured_output" "model_usage" "permission_denials"
    "deferred_tool_use" "errors" "api_error_status" "uuid" "terminal_reason")
  "Upstream ResultMessage wire keys (types.py:1226); excluded from message-extra.")

(defun decode-result-message (wire)
  (%object wire "result message must be an object")
  (unless (equal "result" (gethash "type" wire))
    (signal-cli-json-error "result message type must be \"result\""))
  (make-instance 'result-message
                 :subtype (gethash "subtype" wire)
                 :duration-ms (gethash "duration_ms" wire)
                 :duration-api-ms (gethash "duration_api_ms" wire)
                 :is-error (gethash "is_error" wire)
                 :num-turns (gethash "num_turns" wire)
                 :session-id (gethash "session_id" wire)
                 :stop-reason (gethash "stop_reason" wire)
                 :total-cost-usd (gethash "total_cost_usd" wire)
                 :usage (gethash "usage" wire)
                 :result (gethash "result" wire)
                 :structured-output (gethash "structured_output" wire)
                 :model-usage (gethash "model_usage" wire)
                 :permission-denials (gethash "permission_denials" wire)
                 :deferred-tool-use (gethash "deferred_tool_use" wire)
                 :errors (gethash "errors" wire)
                 :api-error-status (gethash "api_error_status" wire)
                 :uuid (gethash "uuid" wire)
                 :terminal-reason (gethash "terminal_reason" wire)
                 :extra (%extra-fields wire +result-message-known-fields+)))

(defun permission-update->wire (update)
  (permission-update-wire update))
