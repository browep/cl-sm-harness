(in-package #:sm-harness-web-ui)

(defun e2e-streaming-layout-scenario ()
  (%e2e-object
   "name" "streaming-layout" "evidence_suffix" "streaming-layout"
   "steps"
   (list
    ;; This session is intentionally created here, not selected from a prior
    ;; scenario's durable state.
    (%e2e-step "click" "selector" "#new-session")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "fill" "selector" "#prompt" "value" "stream layout e2e")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" (format nil "stream two: Unicode ✓~%second line"))
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "unbroken-")
    (%e2e-step "assert_text_order" "selector" ".msg-assistant"
               "values" (list "e2e hello" (format nil "stream two: Unicode ✓~%second line") "unbroken-"))
    (%e2e-step "assert_overflow_fits" "selector" "#transcript"))))
