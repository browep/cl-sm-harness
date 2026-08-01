(in-package #:sm-harness-web-ui)

(defun e2e-malformed-event-recovery-scenario ()
  (%e2e-object
   "name" "malformed-event-recovery" "evidence_suffix" "safe-fresh-retry"
   "steps"
   (list
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "fill" "selector" "#prompt" "value" "malformed event e2e")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" "#chat-error" "text" "internal error")
    (%e2e-step "assert_text" "selector" "#chat-error" "value" "internal error")
    (%e2e-step "assert_not_text" "value" "fixture malformed secret")
    (%e2e-step "assert_not_text" "value" "invalid JSON")
    (%e2e-step "assert_input_pattern" "selector" "#prompt" "pattern" "malformed event e2e")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready"))))
