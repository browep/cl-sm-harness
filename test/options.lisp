(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/options :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/options)

(defun read-options-fixture ()
  (with-open-file (stream #P"/workspace/test/fixtures/upstream/options/options-wire.json")
    (gethash "options" (yason:parse stream))))

(test options-default-and-wire-encoding
  (let* ((fixture (read-options-fixture))
         (options (claude-agent-sdk-cl::make-agent-options
                   :allowed-tools (gethash "allowedTools" fixture)
                   :disallowed-tools (gethash "disallowedTools" fixture)
                   :permission-mode (gethash "permissionMode" fixture)
                   :continue-conversation (gethash "continue" fixture)
                   :model (gethash "model" fixture)))
         (wire (claude-agent-sdk-cl::agent-options->wire options)))
    (is (equal '("Read" "Write") (claude-agent-sdk-cl::agent-options-allowed-tools options)))
    (is (equal '("Bash") (claude-agent-sdk-cl::agent-options-disallowed-tools options)))
    (is (eq t (claude-agent-sdk-cl::agent-options-continue-conversation options)))
    (is (string= "acceptEdits" (gethash "permissionMode" wire)))
    (is (equal '("Read" "Write") (gethash "allowedTools" wire)))
    (is (equal '("Bash") (gethash "disallowedTools" wire)))
    (is (eq t (gethash "continue" wire)))
    (is (string= "claude-sonnet-4-5" (gethash "model" wire)))))

(test options-reject-invalid-tool-list
  (signals claude-agent-sdk-cl::sdk-input-error
    (claude-agent-sdk-cl::make-agent-options :allowed-tools "Read")))
