(in-package #:sm-harness-web-ui)

;;;; Lisp owns scenario intent and assertions.  The browser process only
;;;; interprets this contract and drives Playwright.

(defun %e2e-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr do
      (setf (gethash key object) value))
    object))

(defun %e2e-step (op &rest pairs)
  (apply #'%e2e-object "op" op pairs))

(defun e2e-scenario-contract ()
  (list
   (%e2e-object
    "name" "home-health" "evidence_suffix" "empty-home"
    "steps"
    (list
     (%e2e-step "assert_text_count" "selector" "body" "text" "e2e hello" "count" 0)
     (%e2e-step "wait" "selector" "#home-root" "state" "visible")
     (%e2e-step "wait" "selector" "#new-session" "state" "visible")
     (%e2e-step "wait" "selector" "#empty-sessions" "state" "visible")
     (%e2e-step "assert_text" "selector" "#home-status" "value" "")
     (%e2e-step "assert_title" "value" "sm-harness")
     (%e2e-step "focus" "selector" "#new-session")
     (%e2e-step "assert_active_id" "value" "new-session")))
   (%e2e-object
    "name" "new-chat-composer" "evidence_suffix" "completed-turn"
    "steps"
    (list
     (%e2e-step "focus" "selector" "#new-session")
     (%e2e-step "press" "key" "Enter")
     (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
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
     (%e2e-step "wait_disabled" "selector" "#send" "value" t)
     (%e2e-step "wait_disabled" "selector" "#stop" "value" nil)
     (%e2e-step "wait_text" "selector" "#status-chip" "text" "Responding")
     (%e2e-step "wait_text" "selector" ".msg-user" "text" "hello e2e")
     (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello")
     (%e2e-step "wait_text" "selector" "#status-chip" "text" "Ready")
     (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
     (%e2e-step "assert_count" "selector" ".msg-user" "count" 1)
     (%e2e-step "assert_value" "selector" "#prompt" "value" "")
     (%e2e-step "assert_active_id" "value" "prompt")))
   (%e2e-object
    "name" "turn-identity" "evidence_suffix" "history-reopen"
    "steps"
    (list
     (%e2e-step "click" "selector" ".session-row")
     (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
     (%e2e-step "click" "selector" "#back-home")
     (%e2e-step "wait" "selector" "#home-root" "state" "visible")
     (%e2e-step "wait_text" "selector" ".session-row" "text" "New session — Ready — e2e-canon")
     (%e2e-step "assert_count" "selector" ".session-row" "count" 1)
     (%e2e-step "click" "selector" ".session-row")
     (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
     (%e2e-step "wait_text" "selector" "#canonical-id" "text" "e2e-canon")
     (%e2e-step "wait_text" "selector" ".msg-user" "text" "hello e2e")
     (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "e2e hello")))
   (%e2e-object
    "name" "streaming-layout" "evidence_suffix" "streaming-layout"
    "steps"
    (list
     (%e2e-step "click" "selector" ".session-row")
     (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
     (%e2e-step "wait_text" "selector" ".msg-assistant" "text" (format nil "stream two: Unicode ✓~%second line"))
     (%e2e-step "wait_text" "selector" ".msg-assistant" "text" "unbroken-")
     (%e2e-step "assert_text_order" "selector" ".msg-assistant"
                "values" (list "e2e hello" (format nil "stream two: Unicode ✓~%second line") "unbroken-"))
     (%e2e-step "assert_overflow_fits" "selector" "#transcript")))))

(defparameter +e2e-supported-ops+
  '("assert_text_count" "wait" "wait_text" "assert_text" "assert_title"
    "focus" "assert_active_id" "press" "assert_disabled" "fill" "click"
    "wait_pattern" "assert_value" "assert_input_pattern" "assert_count"
    "wait_disabled" "assert_text_order" "assert_overflow_fits"))

(defun validate-e2e-contract (contract)
  (let ((names (make-hash-table :test #'equal)))
    (dolist (scenario contract t)
      (let ((name (gethash "name" scenario))
            (suffix (gethash "evidence_suffix" scenario))
            (steps (gethash "steps" scenario)))
        (unless (and (stringp name) (plusp (length name))
                     (stringp suffix) (plusp (length suffix))
                     (listp steps) (plusp (length steps))
                     (not (gethash name names)))
          (return-from validate-e2e-contract nil))
        (setf (gethash name names) t)
        (unless (every (lambda (step)
                         (member (gethash "op" step) +e2e-supported-ops+
                                 :test #'string=))
                       steps)
          (return-from validate-e2e-contract nil))))))

(defun write-e2e-contract (&optional (path #P"/app/static/e2e-contract.json"))
  (unless (validate-e2e-contract (e2e-scenario-contract))
    (error "invalid E2E browser contract"))
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
    (yason:encode (e2e-scenario-contract) stream))
  path)
