(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/subprocess :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/subprocess)

(test explicit-cli-path-runs-the-fake-cli
  (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("ok"))))
    (is (= 0 (getf result :exit-code)))
    (is (search "fake response" (getf result :stdout)))
    (is (string= "" (getf result :stderr)))))

(test fake-cli-nonzero-exit-preserves-stderr
  (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("fail"))))
    (is (= 23 (getf result :exit-code)))
    (is (search "fake cli failed" (getf result :stderr)))))

(test missing-cli-signals-typed-condition
  (signals claude-agent-sdk-cl::cli-not-found-error
    (claude-agent-sdk-cl::resolve-cli-path "/does/not/exist")))
