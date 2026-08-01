(in-package #:sm-harness-web-ui)

(defun e2e-tool-handler-failure-scenario ()
  (%e2e-object
   "name" "tool-handler-failure" "evidence_suffix" "correlated-safe-failure"
   "steps"
   (list
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "fill" "selector" "#prompt" "value" "run failing fixture tool")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-tool" "text" "echo_text")
    (%e2e-step "wait_text" "selector" "#chat-error" "text" "internal error")
    (%e2e-step "assert_text_count" "selector" ".msg-tool" "text" "echo_text" "count" 1)
    (%e2e-step "assert_not_text" "value" "fixture handler secret")
    (%e2e-step "assert_not_text" "value" "e2e-failing-tool-call")
    (%e2e-step "assert_not_text" "value" "SDK tool handler failed")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Error"))))
