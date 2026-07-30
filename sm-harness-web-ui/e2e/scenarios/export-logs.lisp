(in-package #:sm-harness-web-ui)

(defun e2e-export-logs-scenario ()
  (%e2e-object
   "name" "export-logs" "evidence_suffix" "panel-open"
   "steps"
   (list
    ;; Home renders first (#92): its own "nav: home" entry should already
    ;; be in the captured browser log before any session exists.
    (%e2e-step "wait" "selector" "#new-session" "state" "visible")
    (%e2e-step "click" "selector" "#export-logs")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "visible")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "nav: home")
    (%e2e-step "click" "selector" "#logs-close")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "hidden")
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    ;; The chat screen's navigation entry and session tag (#92) let an
    ;; exported log be matched back to this session id, same as the
    ;; copyable session-id chip.
    (%e2e-step "click" "selector" "#export-logs")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "visible")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "nav: chat sess-")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "\\[session:sess-")
    (%e2e-step "click" "selector" "#logs-copy")
    (%e2e-step "click" "selector" "#logs-close")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "hidden"))))
