(in-package #:sm-harness-web-ui)

;;;; Lisp owns scenario intent and assertions. The browser process only
;;;; interprets this contract and drives Playwright.

(defun %e2e-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr do
      (setf (gethash key object) value))
    object))

(defun %e2e-step (op &rest pairs)
  (apply #'%e2e-object "op" op pairs))

(defun e2e-scenario-contract ()
  (list (e2e-home-health-scenario)
        (e2e-new-chat-composer-scenario)
        (e2e-turn-identity-scenario)
        (e2e-direct-session-routes-scenario)
        (e2e-direct-session-resume-scenario)
        (e2e-streaming-layout-scenario)
        (e2e-errors-recovery-scenario)
        (e2e-safe-rendering-scenario)
        (e2e-accessibility-scenario)
        (e2e-stop-deadline-scenario)
        (e2e-custom-tool-lifecycle-scenario)))

(defparameter +e2e-supported-ops+
  '("assert_text_count" "wait" "wait_text" "assert_text" "assert_title"
    "focus" "assert_active_id" "press" "assert_disabled" "fill" "click"
    "wait_pattern" "assert_value" "assert_input_pattern" "assert_count"
    "wait_disabled" "assert_text_order" "assert_overflow_fits"
    "assert_attribute" "goto" "reload" "assert_url_pattern"))

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
