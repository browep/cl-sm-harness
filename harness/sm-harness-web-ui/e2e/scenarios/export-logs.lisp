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
    (%e2e-step "wait" "selector" "#logs-panel" "state" "hidden")
    ;; #120: captured entries live in localStorage, not just an in-memory
    ;; buffer a reload would discard -- a real `reload` here also exercises
    ;; the `pagehide` listener firing on the outgoing document (the event
    ;; itself is the #120 "mobile backgrounding" signal, but a reload is a
    ;; reliable, deterministic way to trigger it in a headless browser).
    ;; direct-session-resume (e2e/scenarios/direct-session-resume.lisp)
    ;; already covers that /sessions/<id> itself resumes correctly; this
    ;; asserts the *log*, not the chat transcript, survives the same
    ;; reload.
    (%e2e-step "reload")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "click" "selector" "#export-logs")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "visible")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "send: hello e2e")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "pagehide")
    (%e2e-step "click" "selector" "#logs-close")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "hidden")
    ;; #120: localStorage is per-origin, not per-tab, so a second tab's own
    ;; "page load" entry (tagged with a marker query param unique to it)
    ;; shows up in this tab's export too, without either tab's websocket
    ;; connection or in-memory state being involved at all.
    (%e2e-step "open_tab" "path" "/?smCrossTabMarker=1")
    (%e2e-step "click" "selector" "#export-logs")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "visible")
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea"
               "pattern" "page load: /\\?smCrossTabMarker=1")
    (%e2e-step "click" "selector" "#logs-close")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "hidden"))))
