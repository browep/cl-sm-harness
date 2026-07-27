(in-package #:sm-harness-web-ui)

(defun e2e-errors-recovery-scenario ()
  (%e2e-object
   "name" "errors-recovery" "evidence_suffix" "safe-retry"
   "steps"
   (list
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "fill" "selector" "#prompt" "value" "retry e2e")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" "#chat-error" "text" "internal error")
    (%e2e-step "assert_input_pattern" "selector" "#prompt" "pattern" "retry e2e")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "Pending…")
    (%e2e-step "assert_disabled" "selector" "#send" "value" nil)
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon"))))
