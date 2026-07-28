(in-package #:sm-harness-web-ui)

(defun e2e-direct-session-routes-scenario ()
  (%e2e-object
   "name" "direct-session-routes" "evidence_suffix" "unknown-safe"
   "steps"
   (list
    (%e2e-step "goto" "path" "/sessions/missing-session")
    (%e2e-step "wait" "selector" "#not-found-root" "state" "visible")
    (%e2e-step "assert_text" "selector" "#session-not-found" "value" "Session not found")
    (%e2e-step "click" "selector" "#not-found-home")
    (%e2e-step "wait" "selector" "#home-root" "state" "visible"))))
