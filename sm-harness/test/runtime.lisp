(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(test catalog-builds-sdk-options
  (let* ((catalog (sm-harness:default-tool-catalog))
         (policy (sm-harness:default-tool-policy))
         (opts (sm-harness::build-agent-options catalog policy)))
    (is (eq :none (claude-agent-sdk-cl:agent-options-builtin-tools opts)))
    (is (eq t (claude-agent-sdk-cl:agent-options-strict-mcp-config opts)))
    (is (= 1 (length (claude-agent-sdk-cl:agent-options-sdk-mcp-servers opts))))
    (is (member "mcp__sm_harness__echo_text"
                (claude-agent-sdk-cl:agent-options-allowed-tools opts)
                :test #'string=))))
