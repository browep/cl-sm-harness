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
    ;; #97: capture is robust beyond navigation entries -- a "page load"
    ;; marker recorded before anything else, and every click on an
    ;; interactive control, not just ones a Lisp handler happens to
    ;; annotate.
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "page load: /")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "click: #export-logs")
    (%e2e-step "click" "selector" "#logs-close")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "hidden")
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    ;; #97: a submitted prompt's *content*, not just a bare "click: #send",
    ;; must show up in the exported log -- that is the whole point of a
    ;; diagnostic export covering "what did the user actually send".
    (%e2e-step "fill" "selector" "#prompt" "value" "hello e2e")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready")
    ;; The chat screen's navigation entry and session tag (#92) let an
    ;; exported log be matched back to this session id, same as the
    ;; copyable session-id chip.
    (%e2e-step "click" "selector" "#export-logs")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "visible")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "nav: chat sess-")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "\\[session:sess-")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "send: hello e2e")
    ;; The "#logs-close" click on the home screen, above, is still in this
    ;; same tab's buffer (#92: one capture install per tab, not per screen).
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "click: #logs-close")
    (%e2e-step "click" "selector" "#logs-copy")
    (%e2e-step "click" "selector" "#logs-close")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "hidden"))))
