(in-package #:sm-harness-web-ui)

(defun e2e-title-live-update-scenario ()
  "#129: a session's header title and Info-panel title must update live --
no page reload -- when SET_SESSION_TITLE renames it while this tab is
already open. Driven the same way #100's connection-lost-recovery drives a
server-side state change with no JS-reachable hook: a second, throwaway
tab hits a test-only route (e2e/test-hooks.lisp) that calls the real
SM-HARNESS:SET-SESSION-TITLE API -- the same call the set_session_title
catalog tool itself makes -- then this scenario asserts the *first* tab's
DOM updated in place."
  (%e2e-object
   "name" "title-live-update" "evidence_suffix" "title-live"
   "steps"
   (list
    (%e2e-step "click" "selector" "#new-session")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    ;; New sessions render the literal default until something renames them.
    (%e2e-step "wait_text" "selector" ".chat-title" "text" "New session")
    (%e2e-step "click" "selector" "#session-info")
    (%e2e-step "wait_pattern" "selector" "#info-panel-body" "pattern" "New session")
    (%e2e-step "click" "selector" "#info-close")
    (%e2e-step "open_tab" "path" "/e2e-rename-session")
    ;; The primary tab's header must pick up the rename with no reload.
    (%e2e-step "wait_text" "selector" ".chat-title" "text" "Renamed live via e2e")
    ;; Reopening (not reloading) the Info panel must show the new title too,
    ;; not the one captured when the chat screen first rendered (#129: this
    ;; used to read the stale SESSION-SNAPSHOT taken at render-chat time).
    (%e2e-step "click" "selector" "#session-info")
    (%e2e-step "wait_pattern" "selector" "#info-panel-body" "pattern" "Renamed live via e2e")
    (%e2e-step "click" "selector" "#info-close"))))
