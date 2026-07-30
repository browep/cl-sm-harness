(in-package #:sm-harness-web-ui)

(defun e2e-session-info-scenario ()
  "#106: the new-session backend/model dropdowns and the chat header's
Info panel, exercised end to end -- a non-default model choice on the
home screen must be what the info panel shows back once the session
exists, and the panel must not appear until the button is clicked."
  (%e2e-object
   "name" "session-info" "evidence_suffix" "info-panel"
   "steps"
   (list
    (%e2e-step "wait" "selector" "#new-session" "state" "visible")
    ;; Only one backend exists today, but exercise the select regardless --
    ;; asserting its value below still catches a regression that silently
    ;; stopped wiring the chosen backend through.
    (%e2e-step "select_option" "selector" "#backend-select" "value" "claude")
    (%e2e-step "select_option" "selector" "#model-select" "value" "opus")
    (%e2e-step "click" "selector" "#new-session")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "wait" "selector" "#info-panel" "state" "hidden")
    (%e2e-step "click" "selector" "#session-info")
    (%e2e-step "wait" "selector" "#info-panel" "state" "visible")
    (%e2e-step "wait_pattern" "selector" "#info-panel-body" "pattern" "sess-")
    (%e2e-step "wait_pattern" "selector" "#info-panel-body" "pattern" "Claude Opus")
    (%e2e-step "click" "selector" "#info-close")
    (%e2e-step "wait" "selector" "#info-panel" "state" "hidden"))))
