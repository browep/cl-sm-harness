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

(test permission-update-roundtrips-a-rule-wire-object
  (let* ((wire (make-wire-object
                "type" "addRules" "destination" "localSettings" "behavior" "allow"
                "rules" (list (make-wire-object "toolName" "Bash" "ruleContent" "npm *"))))
         (update (claude-agent-sdk-cl::decode-permission-update wire)))
    (is (string= "addRules" (claude-agent-sdk-cl::permission-update-type update)))
    (is (equal wire (claude-agent-sdk-cl::permission-update->wire update)))))
