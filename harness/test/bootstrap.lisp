(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/tests
  :description "Bootstrap checks for the SDK system.")

(in-suite :claude-agent-sdk-cl/tests)

(test sdk-version-is-exposed
  (is (string= "0.1.0" (sdk-version))))
