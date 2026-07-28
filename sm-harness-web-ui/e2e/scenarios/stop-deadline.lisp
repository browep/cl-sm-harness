(in-package #:sm-harness-web-ui)

(defun e2e-stop-deadline-scenario ()
  (%e2e-object
   "name" "stop-deadline" "evidence_suffix" "interrupted-turn"
   "steps"
   (list
    (%e2e-step "click" "selector" "#new-session")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "fill" "selector" "#prompt" "value" "stop e2e")
    (%e2e-step "click" "selector" "#send")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Responding")
    (%e2e-step "wait_disabled" "selector" "#stop" "value" nil)
    (%e2e-step "click" "selector" "#stop")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready")
    (%e2e-step "wait_text" "selector" ".msg-result" "text" "stopped by e2e")
    (%e2e-step "assert_disabled" "selector" "#send" "value" nil)
    (%e2e-step "assert_value" "selector" "#prompt" "value" ""))))
