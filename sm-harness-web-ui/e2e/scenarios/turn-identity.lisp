(in-package #:sm-harness-web-ui)

(defun e2e-turn-identity-scenario ()
  (%e2e-object
   "name" "turn-identity" "evidence_suffix" "history-reopen"
   "steps"
   (list
    (%e2e-step "click" "selector" ".session-row")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "click" "selector" "#back-home")
    (%e2e-step "wait" "selector" "#home-root" "state" "visible")
    (%e2e-step "wait_text" "selector" ".session-row" "text" "New session — Ready — e2e-canon")
    (%e2e-step "assert_count" "selector" ".session-row" "count" 1)
    (%e2e-step "click" "selector" ".session-row")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
    (%e2e-step "wait_text" "selector" ".msg-user" "text" "hello e2e")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello"))))
