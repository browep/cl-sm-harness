(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/conditions :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/conditions)

(defun read-condition-fixture ()
  (with-open-file (stream #P"/workspace/test/fixtures/upstream/conditions/typed-errors.json")
    (yason:parse stream)))

(test typed-conditions-remain-distinct
  (let* ((fixture (read-condition-fixture))
         (process (gethash "process_error" fixture))
         (process-condition nil)
        (json-condition nil)
        (input-condition nil))
    (handler-case
        (claude-agent-sdk-cl::signal-process-error (gethash "message" process)
                                                    (gethash "exit_code" process)
                                                    (gethash "stderr" process))
      (claude-agent-sdk-cl::process-error (condition) (setf process-condition condition)))
    (handler-case
        (claude-agent-sdk-cl::signal-cli-json-error (gethash "malformed_json_line" fixture))
      (claude-agent-sdk-cl::cli-json-error (condition) (setf json-condition condition)))
    (handler-case
        (claude-agent-sdk-cl::signal-sdk-input-error "allowed-tools must be a list")
      (claude-agent-sdk-cl::sdk-input-error (condition) (setf input-condition condition)))
    (is-true process-condition)
    (is-true json-condition)
    (is-true input-condition)
    (is (= 17 (claude-agent-sdk-cl::process-error-exit-code process-condition)))
    (is (string= "bad stderr" (claude-agent-sdk-cl::process-error-stderr process-condition)))
    (is (string= "{broken" (claude-agent-sdk-cl::cli-json-error-line json-condition)))))
