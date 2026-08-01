(in-package #:sm-harness-web-ui)

(defun e2e-connection-lost-fallback-scenario ()
  (%e2e-object
   "name" "connection-lost-fallback" "evidence_suffix" "html-on-close"
   "steps"
   (list
    ;; A very long self-heal poll interval (#100, fix B, static/log-capture.js)
    ;; effectively disables the auto-reload for this scenario's lifetime,
    ;; isolating fix A's CLOG:SET-HTML-ON-CLOSE fallback so it can be
    ;; asserted on directly instead of racing B's own reload.
    (%e2e-step "goto" "path" "/?smSelfHealPollMs=600000")
    (%e2e-step "wait" "selector" "#new-session" "state" "visible")
    ;; Same test-only drop-connection trick as connection-lost-recovery
    ;; (see e2e/test-hooks.lisp) -- puts this tab's `ws` into its terminal
    ;; null state, the same state a rejected stale reconnect after a real
    ;; process restart produces (docs/sm-harness-web-ui.md).
    (%e2e-step "open_tab" "path" "/e2e-drop-connection")
    ;; With B effectively disabled above, CLOG's own Shutdown_ws (which
    ;; ran when the drop landed) is the only thing that has acted so far:
    ;; it replaces document.body's HTML with clog['html_on_close'], set
    ;; once per connection in ON-NEW-WINDOW (application.lisp).
    (%e2e-step "wait" "selector" "#sm-connection-lost" "state" "visible")
    (%e2e-step "assert_text" "selector" "#sm-connection-lost-message"
               "value" "Connection lost. Reload to continue.")
    ;; The fallback's own reload affordance is a real, clickable control,
    ;; not inert text -- the whole point is turning a silent dead end into
    ;; something the user can act on.
    (%e2e-step "click" "selector" "#sm-connection-lost-reload")
    (%e2e-step "wait" "selector" "#new-session" "state" "visible"))))
