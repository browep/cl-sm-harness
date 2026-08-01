(in-package #:sm-harness-web-ui)

(defun e2e-home-health-scenario ()
  (%e2e-object
   "name" "home-health" "evidence_suffix" "empty-home"
   "steps"
   (list
    (%e2e-step "assert_text_count" "selector" "body" "text" "e2e hello" "count" 0)
    (%e2e-step "wait" "selector" "#home-root" "state" "visible")
    (%e2e-step "wait" "selector" "#new-session" "state" "visible")
    (%e2e-step "wait" "selector" "#empty-sessions" "state" "visible")
    (%e2e-step "assert_text" "selector" "#home-status" "value" "")
    (%e2e-step "assert_title" "value" "sm-harness")
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "assert_active_id" "value" "new-session"))))
