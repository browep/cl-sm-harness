(in-package #:sm-harness-web-ui)

(defun e2e-accessibility-scenario ()
  (%e2e-object
   "name" "accessibility" "evidence_suffix" "semantics-focus"
   "steps"
   (list
    (%e2e-step "assert_attribute" "selector" "#home-root" "name" "role" "value" "main")
    (%e2e-step "assert_attribute" "selector" "#session-list" "name" "role" "value" "region")
    (%e2e-step "assert_attribute" "selector" "#session-list" "name" "aria-label" "value" "Sessions")
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "assert_active_id" "value" "prompt")
    (%e2e-step "assert_attribute" "selector" "#chat-root" "name" "role" "value" "main")
    (%e2e-step "assert_attribute" "selector" "#transcript" "name" "role" "value" "log")
    (%e2e-step "assert_attribute" "selector" "#transcript" "name" "aria-label" "value" "Conversation transcript")
    (%e2e-step "assert_attribute" "selector" "#transcript" "name" "aria-live" "value" "polite")
    (%e2e-step "assert_attribute" "selector" "#status-chip" "name" "role" "value" "status")
    (%e2e-step "assert_attribute" "selector" "#chat-error" "name" "role" "value" "alert")
    (%e2e-step "assert_attribute" "selector" "#prompt" "name" "aria-label" "value" "Message")
    (%e2e-step "click" "selector" "#back-home")
    (%e2e-step "wait" "selector" "#home-root" "state" "visible")
    (%e2e-step "assert_active_id" "value" "new-session"))))
