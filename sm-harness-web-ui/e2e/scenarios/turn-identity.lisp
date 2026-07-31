(in-package #:sm-harness-web-ui)

(defun e2e-turn-identity-scenario ()
  (%e2e-object
   "name" "turn-identity" "evidence_suffix" "history-reopen"
   "steps"
   (list
    ;; Provision the durable session in this scenario: suite runs never depend
    ;; on state created by a previous browser context.
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "assert_url_pattern" "pattern" "^/sessions/[^/]+$")
    (%e2e-step "fill" "selector" "#prompt" "value" "hello e2e")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready")
    (%e2e-step "click" "selector" "#back-home")
    (%e2e-step "wait" "selector" "#home-root" "state" "visible")
    ;; #124: "Back to home" must reset the address bar too, or a reload
    ;; from this screen would silently re-open the session just left
    ;; instead of showing home.
    (%e2e-step "assert_url_pattern" "pattern" "^/$")
    ;; #111: the home-screen chip's title/status/canonical-id now each live
    ;; in their own element rather than one dash-joined text blob.
    (%e2e-step "wait_text" "selector" ".session-row .chip-title" "text" "New session")
    (%e2e-step "wait_text" "selector" ".session-row .chip-status" "text" "Ready")
    (%e2e-step "wait_text" "selector" ".session-row .chip-canonical" "text" "e2e-canon")
    (%e2e-step "wait_text" "selector" ".session-row .chip-turns" "text" "1 turn")
    (%e2e-step "assert_count" "selector" ".session-row" "count" 1)
    (%e2e-step "click" "selector" ".session-row")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    ;; #124: clicking an existing session from the home list must land the
    ;; bar back on that session's own /sessions/<id> route -- this was the
    ;; exact click path (home list -> chat) whose address bar went stale in
    ;; the reported bug, since only the "New session" button used to sync it.
    (%e2e-step "assert_url_pattern" "pattern" "^/sessions/[^/]+$")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
    (%e2e-step "wait_text" "selector" ".msg-user" "text" "hello e2e")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello")
    ;; A reload here must land back on this exact session -- proving the URL
    ;; set by the session-list click above, not just the one set at session
    ;; creation, is what a reload actually resumes from (#124).
    (%e2e-step "reload")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "assert_url_pattern" "pattern" "^/sessions/[^/]+$")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
    (%e2e-step "wait_text" "selector" ".msg-user" "text" "hello e2e"))))
