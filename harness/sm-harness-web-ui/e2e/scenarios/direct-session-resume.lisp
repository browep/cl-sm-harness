(in-package #:sm-harness-web-ui)

(defun e2e-direct-session-resume-scenario ()
  (%e2e-object
   "name" "direct-session-resume" "evidence_suffix" "reloads-durable-route"
   "steps"
   (list
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "fill" "selector" "#prompt" "value" "route reload e2e")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
    (%e2e-step "assert_url_pattern" "pattern" "^/sessions/[^/]+$")
    (%e2e-step "reload")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
    (%e2e-step "wait_text" "selector" ".msg-user" "text" "route reload e2e"))))
