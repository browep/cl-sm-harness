(in-package #:sm-harness-web-ui)

(defun e2e-connection-lost-recovery-scenario ()
  (%e2e-object
   "name" "connection-lost-recovery" "evidence_suffix" "self-healed"
   "steps"
   (list
    (%e2e-step "wait" "selector" "#new-session" "state" "visible")
    ;; A marker click in this tab's captured browser log before the drop,
    ;; so the later export can show the pre-drop buffer really was
    ;; discarded by a genuine page reload, not just business as usual.
    (%e2e-step "click" "selector" "#export-logs")
    (%e2e-step "click" "selector" "#logs-close")
    ;; static/log-capture.js's self-heal (#100, fix B) deliberately only
    ;; ever reloads once it has *first* observed a live `window.ws`, so a
    ;; slow initial handshake can never be mistaken for a lost connection.
    ;; Give its poll (default interval 2000ms) a chance to observe that
    ;; before dropping the connection below, or this scenario's own speed
    ;; (this tab is only a couple hundred ms old) would race that guard --
    ;; a purely test-timeline artifact, not a real-world one: in practice
    ;; a connection is long-lived before it is ever lost.
    (%e2e-step "sleep" "milliseconds" 2500)
    ;; #100 repro/fix: put this tab's CLOG connection into the exact
    ;; terminal "Shutdown_ws already ran, ws permanently null" state that a
    ;; rejected stale reconnect produces after a real process restart --
    ;; via a throwaway second tab hitting a test-only route (see
    ;; e2e/test-hooks.lisp), CLOG's own recommended trick for testing this
    ;; deterministically (docs/sm-harness-web-ui.md).
    (%e2e-step "open_tab" "path" "/e2e-drop-connection")
    ;; The self-heal poll now auto-reloads within a couple more poll
    ;; intervals. Give it time; the reload's fresh DOM replaces
    ;; #new-session with a brand new element.
    (%e2e-step "sleep" "milliseconds" 6000)
    (%e2e-step "wait" "selector" "#new-session" "state" "visible")
    ;; The only way a click on this tab can work again post-drop is a
    ;; genuine page reload -- CLOG never revives a connection id it no
    ;; longer knows (docs/sm-harness-web-ui.md, "Dead browser tabs and
    ;; listener delivery"). A successful, error-free click here is direct
    ;; proof of self-heal recovery, not just an absence-of-crash check:
    ;; before the fix, this is exactly the click that throws
    ;; "Cannot read properties of null (reading 'send')" (#100).
    (%e2e-step "click" "selector" "#export-logs")
    (%e2e-step "wait" "selector" "#logs-panel" "state" "visible")
    ;; The captured buffer belongs to this fresh JS realm -- pre-drop
    ;; entries (like the "click: #export-logs" marker above) cannot appear
    ;; in it, and its very first line is always a fresh "page load".
    (%e2e-step "assert_input_pattern" "selector" "#logs-textarea" "pattern" "page load: /")
    (%e2e-step "click" "selector" "#logs-close"))))
