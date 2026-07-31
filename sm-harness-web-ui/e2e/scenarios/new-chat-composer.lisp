(in-package #:sm-harness-web-ui)

(defun e2e-new-chat-composer-scenario ()
  (%e2e-object
   "name" "new-chat-composer" "evidence_suffix" "completed-turn"
   "steps"
   (list
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    ;; The copyable session-id chip shows the harness id, which is also the
    ;; transcript file name under <data>/web/sessions/.
    (%e2e-step "wait_pattern" "selector" "#session-id" "pattern" "^sess-")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "Pending…")
    (%e2e-step "wait" "selector" "#prompt" "state" "visible")
    (%e2e-step "assert_active_id" "value" "prompt")
    (%e2e-step "assert_disabled" "selector" "#send" "value" nil)
    (%e2e-step "assert_disabled" "selector" "#stop" "value" t)
    (%e2e-step "fill" "selector" "#prompt" "value" "   ")
    (%e2e-step "click" "selector" "#send")
    (%e2e-step "wait_pattern" "selector" "#chat-error" "pattern" "prompt")
    (%e2e-step "assert_value" "selector" "#prompt" "value" "   ")
    (%e2e-step "assert_disabled" "selector" "#send" "value" nil)
    (%e2e-step "fill" "selector" "#prompt" "value" "line one")
    (%e2e-step "press" "selector" "#prompt" "key" "Shift+Enter")
    (%e2e-step "assert_input_pattern" "selector" "#prompt" "pattern" "\\n")
    (%e2e-step "assert_count" "selector" ".msg-user" "count" 0)
    (%e2e-step "fill" "selector" "#prompt" "value" "hello e2e")
    (%e2e-step "press" "selector" "#prompt" "key" "Enter")
    ;; #69/#113: the prompt must appear the moment submission is accepted,
    ;; not once the harness round-trips its own :USER-MESSAGE event back.
    ;; The fixture transport (delay-before-second-read-seconds) deliberately
    ;; holds the assistant reply back for a beat, so this check only ever
    ;; passes well ahead of that hold when the echo was rendered
    ;; synchronously with submission. It is WAIT_COUNT rather than an
    ;; instant ASSERT_COUNT (#113: reliably 0 as an instant check in this
    ;; environment) because CLOG:TEXT-VALUE and the ADD-LINE div-creation
    ;; it feeds are each their own round trip to the browser -- rendering
    ;; genuinely starts the moment submission is accepted, but "moment"
    ;; still costs a network hop no local check can outrun. The bound stays
    ;; a two-order-of-magnitude margin under the fixture's held-back reply,
    ;; so a regression back to waiting on that round trip still fails this.
    (%e2e-step "wait_count" "selector" ".msg-user" "count" 1 "timeout_ms" 2000)
    (%e2e-step "assert_text" "selector" ".msg-user" "value" "hello e2e")
    (%e2e-step "wait_disabled" "selector" "#send" "value" t)
    (%e2e-step "wait_disabled" "selector" "#stop" "value" nil)
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Responding")
    (%e2e-step "wait_text" "selector" ".msg-user" "text" "hello e2e")
    (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello")
    (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready")
    (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
    ;; Exactly one .msg-user survives the full round trip: the optimistic
    ;; echo above must not be duplicated once the harness's own
    ;; :USER-MESSAGE event for this turn arrives over the listener.
    (%e2e-step "assert_count" "selector" ".msg-user" "count" 1)
    (%e2e-step "assert_value" "selector" "#prompt" "value" "")
    (%e2e-step "assert_active_id" "value" "prompt"))))
