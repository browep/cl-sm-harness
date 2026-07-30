(in-package #:sm-harness-web-ui)

(defun e2e-read-recovery-scenario ()
  (%e2e-object
   "name" "read-recovery" "evidence_suffix" "canonical-retry"
   "steps"
   (list
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "fill" "selector" "#prompt" "value" "canonical first turn")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "read first complete")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
    (%e2e-step "sleep" "milliseconds" 1200)
    (%e2e-step "reload")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    ;; Replayed content implies the composer handlers are already bound
    ;; (chat.lisp binds them before the replay); typing at bare
    ;; #chat-root-visible races the binding and the Enter is dropped.
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "read first complete")
    (%e2e-step "fill" "selector" "#prompt" "value" "read failure after resume")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" "#chat-error" "text" "internal error")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
    (%e2e-step "assert_disabled" "selector" "#send" "value" nil)
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "read retry complete")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready"))))
