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

(test session-options-fail-before-transport-construction
  (let ((store (list :opaque-store)))
    (signals claude-agent-sdk-cl::sdk-input-error
      (claude-agent-sdk-cl::make-agent-options :session-store store
                                                :continue-conversation t))
    (signals claude-agent-sdk-cl::sdk-input-error
      (claude-agent-sdk-cl::make-agent-options :session-store store
                                                :enable-file-checkpointing t))
    (signals claude-agent-sdk-cl::sdk-input-error
      (claude-agent-sdk-cl::make-agent-options :resume "../escape"))
    (signals claude-agent-sdk-cl::sdk-input-error
      (claude-agent-sdk-cl::make-agent-options :session-path "../../outside"))
    (let ((options (claude-agent-sdk-cl::make-agent-options
                    :session-store store :continue-conversation t
                    :session-store-list-sessions-p t :resume "session-1"
                    :session-path "exports/session.jsonl")))
      (is (string= "session-1" (claude-agent-sdk-cl::agent-options-resume options))))
    (let ((import (claude-agent-sdk-cl:make-session-import-plan
                   :session-id "session-1" :path "exports/session.jsonl"))
          (rename (claude-agent-sdk-cl:make-session-mutation-plan
                   :operation :rename :session-id "session-1" :value "Title")))
      (is (string= "session-1" (claude-agent-sdk-cl:session-import-plan-session-id import)))
      (is (eq :rename (claude-agent-sdk-cl:session-mutation-plan-operation rename))))
    (signals claude-agent-sdk-cl::sdk-input-error
      (claude-agent-sdk-cl:make-session-mutation-plan :operation :fork
                                                       :session-id "same" :target-id "same"))))

(test options-reject-invalid-tool-list
  (signals claude-agent-sdk-cl::sdk-input-error
    (claude-agent-sdk-cl::make-agent-options :allowed-tools "Read")))
