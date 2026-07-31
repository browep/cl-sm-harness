(in-package #:sm-harness-web-ui)

(defun e2e-back-navigation-scenario ()
  "#125: the browser's own Back button, not any in-app control -- #124
made set-session-route/set-home-route keep the address bar in sync via
replaceState, but replaceState never adds a history entry, so a tab's
session-history stack never grew past its single starting one no matter
how many views it visited. Pressing Back from a chat view then had
nothing real to go back to, and a tab with no prior page in its history
closes outright on Back rather than doing nothing -- this scenario drives
a real go_back (Playwright's page.goBack, not a click on #back-home) to
catch exactly that, which the existing turn-identity scenario's in-app
navigation cannot: it never touches the actual browser history stack."
  (%e2e-object
   "name" "back-navigation" "evidence_suffix" "browser-back"
   "steps"
   (list
    (%e2e-step "wait" "selector" "#home-root" "state" "visible")
    (%e2e-step "assert_url_pattern" "pattern" "^/$")
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "assert_url_pattern" "pattern" "^/sessions/[^/]+$")
    ;; The real assertion: go_back must land back on the home screen (proof
    ;; the tab itself survived and actually navigated) with the address bar
    ;; reset to "/" -- not an error, not a closed page, not a stale chat
    ;; view left on screen with a "/" URL underneath it.
    (%e2e-step "go_back")
    (%e2e-step "wait" "selector" "#home-root" "state" "visible")
    (%e2e-step "assert_url_pattern" "pattern" "^/$"))))
