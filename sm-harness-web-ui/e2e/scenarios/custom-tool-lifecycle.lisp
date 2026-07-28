(in-package #:sm-harness-web-ui)

(defun e2e-custom-tool-lifecycle-scenario ()
  (%e2e-object
   "name" "custom-tool-lifecycle" "evidence_suffix" "session-start-catalog"
   "steps"
   (list
    (%e2e-step "click" "selector" "#new-session")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "fill" "selector" "#prompt" "value" "custom tool lifecycle")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-tool"
               "text" "Tool requested: mcp__sm_harness__echo_text")
    (%e2e-step "wait_text" "selector" ".msg-tool"
               "text" "Tool completed: echo: browser-actual")
    (%e2e-step "wait_text" "selector" ".msg-assistant"
               "text" "custom tool lifecycle complete")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon"))))