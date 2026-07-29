(in-package #:sm-harness-web-ui)

(defun status-label (status)
  (case status
    (:ready "Ready")
    (:connecting "Connecting")
    (:responding "Responding")
    (:stopping "Stopping")
    (:error "Error")
    (:disconnected "Disconnected")
    (t (princ-to-string status))))

(defun escape-text (text)
  "Text-only rendering: strip angle brackets so content is never HTML."
  (with-output-to-string (out)
    (loop for ch across (or text "") do
      (case ch
        (#\< (write-string "&lt;" out))
        (#\> (write-string "&gt;" out))
        (#\& (write-string "&amp;" out))
        (t (write-char ch out))))))

(defun event-display (ev)
  (let ((type (sm-harness:event-type ev))
        (payload (sm-harness:event-payload ev)))
    (case type
      (:assistant-text
       (cons "assistant" (escape-text (getf payload :text))))
      (:user-message
       ;; A harness-initiated synthetic follow-up (#76) must never render
       ;; indistinguishably from something the human actually typed.
       (cons (if (getf payload :synthetic) "harness" "user")
             (escape-text (getf payload :text))))
      (:tool-requested
       (cons "tool" (escape-text (format nil "Tool requested: ~A" (getf payload :name)))))
      (:tool-completed
       (cons "tool"
             (escape-text (format nil "Tool completed: ~A" (getf payload :content)))))
      (:tool-failed
       (cons "tool" "Tool failed"))
      (:terminal
       (cons "result" (escape-text (or (getf payload :text) ""))))
      (:error
       (cons "error" (escape-text (or (getf payload :message) "error"))))
      (:status
       (cons "status" (status-label (getf payload :status))))
      (t
       (cons "system" (escape-text (princ-to-string type)))))))
