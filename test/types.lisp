(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/types :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/types)

(defun make-wire-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr do (setf (gethash key object) value))
    object))

(defun read-json-fixture (relative-path)
  (with-open-file (stream (merge-pathnames relative-path #P"/workspace/"))
    (yason:parse stream)))

(test decode-content-and-preserve-unknown-fields
  (let* ((wire (gethash "wire" (read-json-fixture "test/fixtures/upstream/types/assistant-message-unknown-field.json")))
         (message (claude-agent-sdk-cl::decode-message wire)))
    (is (typep message 'claude-agent-sdk-cl::assistant-message))
    (is (string= "claude-sonnet-4-5" (claude-agent-sdk-cl::assistant-message-model message)))
    (is (= 1 (length (claude-agent-sdk-cl::assistant-message-content message))))
    (is (typep (first (claude-agent-sdk-cl::assistant-message-content message)) 'claude-agent-sdk-cl::text-block))
    (is (string= "Hello" (claude-agent-sdk-cl::text-block-text (first (claude-agent-sdk-cl::assistant-message-content message)))))
    (is (gethash "futureField" (claude-agent-sdk-cl::message-extra message)))))

(test malformed-message-signals-cli-json-error
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-message (make-wire-object "type" "assistant" "message" "not-an-object"))))

(test decode-result-message-preserves-known-and-unknown-fields
  (let* ((wire (make-wire-object
                "type" "result" "subtype" "success"
                "duration_ms" 123 "duration_api_ms" 100
                "is_error" t "num_turns" 1 "session_id" "session-1"
                "result" "done" "total_cost_usd" 0.01d0
                "terminal_reason" "completed" "futureField" "preserved"))
         (message (claude-agent-sdk-cl::decode-result-message wire)))
    (is (typep message 'claude-agent-sdk-cl::result-message))
    (is (typep message 'claude-agent-sdk-cl::message))
    (is (string= "success" (claude-agent-sdk-cl::result-message-subtype message)))
    (is (= 123 (claude-agent-sdk-cl::result-message-duration-ms message)))
    (is (= 100 (claude-agent-sdk-cl::result-message-duration-api-ms message)))
    ;; is_error true proves the decoder actually reads the field (a NIL here
    ;; would be indistinguishable from an absent key under Yason).
    (is (eq t (claude-agent-sdk-cl::result-message-is-error message)))
    (is (= 1 (claude-agent-sdk-cl::result-message-num-turns message)))
    (is (string= "session-1" (claude-agent-sdk-cl::result-message-session-id message)))
    (is (string= "done" (claude-agent-sdk-cl::result-message-result message)))
    (is (= 0.01d0 (claude-agent-sdk-cl::result-message-total-cost-usd message)))
    (is (string= "completed" (claude-agent-sdk-cl::result-message-terminal-reason message)))
    (is (string= "preserved" (gethash "futureField" (claude-agent-sdk-cl::message-extra message))))))

(test decode-result-message-error-subtype-and-absent-optionals
  ;; is_error true is still a message, not a transport error; a genuinely absent
  ;; is_error key and other absent optionals decode to NIL without signalling.
  (let* ((wire (make-wire-object
                "type" "result" "subtype" "error_max_turns"
                "num_turns" 8 "session_id" "session-2"))
         (message (claude-agent-sdk-cl::decode-result-message wire)))
    (is (string= "error_max_turns" (claude-agent-sdk-cl::result-message-subtype message)))
    (is (null (claude-agent-sdk-cl::result-message-is-error message)))
    (is (null (claude-agent-sdk-cl::result-message-result message)))
    (is (null (claude-agent-sdk-cl::result-message-total-cost-usd message)))
    (is (null (claude-agent-sdk-cl::result-message-terminal-reason message)))))

(test decode-result-message-rejects-non-result-and-non-object
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-result-message (make-wire-object "type" "assistant")))
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-result-message "not-an-object"))
  ;; Missing "type" key: gethash returns NIL, so the guard must use `equal`,
  ;; not `string=` (which would signal TYPE-ERROR on NIL).
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-result-message (make-wire-object))))

(test decode-result-message-is-reachable-through-public-export
  ;; Proves the exported (single-colon) surface, not just the internal symbol.
  (let ((message (claude-agent-sdk-cl:decode-result-message
                  (make-wire-object "type" "result" "subtype" "success"
                                    "session_id" "s"))))
    (is (typep message 'claude-agent-sdk-cl:result-message))
    (is (string= "success" (claude-agent-sdk-cl:result-message-subtype message)))))

(test decode-system-message-preserves-subtype-and-raw-fields
  (let* ((wire (make-wire-object
                "type" "system" "subtype" "init"
                "session_id" "s" "uuid" "u" "cwd" "/tmp" "futureField" "keep"))
         (message (claude-agent-sdk-cl::decode-system-message wire)))
    (is (typep message 'claude-agent-sdk-cl::system-message))
    (is (typep message 'claude-agent-sdk-cl::message))
    (is (string= "init" (claude-agent-sdk-cl::system-message-subtype message)))
    ;; Full raw wire preserved for callers that need un-modelled system fields.
    (is (eq wire (claude-agent-sdk-cl::system-message-data message)))
    ;; Unknown fields also surfaced through message-extra.
    (is (string= "keep" (gethash "futureField" (claude-agent-sdk-cl::message-extra message))))))

(test decode-system-message-rejects-non-system-missing-subtype-and-non-object
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-system-message (make-wire-object "type" "assistant" "subtype" "x")))
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-system-message (make-wire-object "type" "system")))
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-system-message "not-an-object"))
  ;; Missing "type" key must signal via equal guard, not TYPE-ERROR.
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-system-message (make-wire-object "subtype" "init"))))

(test decode-system-message-is-reachable-through-public-export
  (let ((message (claude-agent-sdk-cl:decode-system-message
                  (make-wire-object "type" "system" "subtype" "init"))))
    (is (typep message 'claude-agent-sdk-cl:system-message))
    (is (string= "init" (claude-agent-sdk-cl:system-message-subtype message)))))

(test permission-update-roundtrips-a-rule-wire-object
  (let* ((wire (make-wire-object
                "type" "addRules" "destination" "localSettings" "behavior" "allow"
                "rules" (list (make-wire-object "toolName" "Bash" "ruleContent" "npm *"))))
         (update (claude-agent-sdk-cl::decode-permission-update wire)))
    (is (string= "addRules" (claude-agent-sdk-cl::permission-update-type update)))
    (is (equal wire (claude-agent-sdk-cl::permission-update->wire update)))))
