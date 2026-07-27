(in-package #:sm-harness-web-ui)

(defun e2e-safe-rendering-scenario ()
  (let ((user "literal-user")
        (assistant "e2e-xss"))
    (%e2e-object
     "name" "safe-rendering" "evidence_suffix" "literal-replay"
     "steps"
     (list
      (%e2e-step "focus" "selector" "#new-session")
      (%e2e-step "press" "key" "Enter")
      (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
      (%e2e-step "fill" "selector" "#prompt" "value" user)
      (%e2e-step "press" "selector" "#prompt" "key" "Enter")
      (%e2e-step "wait_text" "selector" ".msg-user" "text" user)
      (%e2e-step "wait_text" "selector" ".msg-assistant" "text" assistant)
      (%e2e-step "assert_count" "selector" "#transcript script" "count" 0)
      (%e2e-step "assert_count" "selector" "#transcript img" "count" 0)
      (%e2e-step "assert_count" "selector" "#transcript a" "count" 0)
      (%e2e-step "assert_count" "selector" "#transcript [data-e2e]" "count" 0)
      (%e2e-step "click" "selector" "#back-home")
      (%e2e-step "click" "selector" ".session-row:first-child")
      (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
      (%e2e-step "wait_text" "selector" ".msg-user" "text" user)
      (%e2e-step "wait_text" "selector" ".msg-assistant" "text" assistant)
      (%e2e-step "assert_count" "selector" "#transcript script" "count" 0)
      (%e2e-step "assert_count" "selector" "#transcript img" "count" 0)
      (%e2e-step "assert_count" "selector" "#transcript a" "count" 0)
      (%e2e-step "assert_count" "selector" "#transcript [data-e2e]" "count" 0)))))
