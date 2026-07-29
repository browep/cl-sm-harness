(in-package #:sm-harness-web-ui)

(defun clear-body (body)
  (setf (clog:inner-html body) ""))

(defun render-chat (body session-id)
  (clear-body body)
  (setf (clog:title (clog:html-document body)) "Chat — sm-harness")
  (let* ((snap (ui-open-session session-id))
         (root (clog:create-div body :class "page chat" :html-id "chat-root"))
         (header (clog:create-div root :class "header"))
         (back (clog:create-button header :content "Back to home"
                                   :class "btn" :html-id "back-home"))
         (title-el (clog:create-div header :class "chat-title"
                                    :content (sm-harness:session-snapshot-title snap)))
         (status-el (clog:create-div header :class "status-chip" :html-id "status-chip"
                                     :content (status-label (sm-harness:session-snapshot-status snap))))
         (canon-el (clog:create-div header :class "canonical-id" :html-id "canonical-id"
                                    :content (or (sm-harness:session-snapshot-canonical-id snap)
                                                 "Pending…")))
         (transcript (clog:create-div root :class "transcript" :html-id "transcript"))
         (composer-wrap (clog:create-div root :class "composer"))
         (input (clog:create-text-area composer-wrap :class "prompt" :html-id "prompt"))
         (send-btn (clog:create-button composer-wrap :content "Send"
                                       :class "btn primary" :html-id "send"))
         (stop-btn (clog:create-button composer-wrap :content "Stop"
                                       :class "btn danger" :html-id "stop"))
         (err (clog:create-div root :class "error" :html-id "chat-error"))
         (listener-id nil)
         (busy nil)
         (pending-prompt nil))
    (declare (ignore title-el))
    (setf (clog:attribute root "role") "main"
          (clog:attribute status-el "role") "status"
          (clog:attribute status-el "aria-live") "polite"
          (clog:attribute transcript "role") "log"
          (clog:attribute transcript "aria-label") "Conversation transcript"
          (clog:attribute transcript "aria-live") "polite"
          (clog:attribute err "role") "alert"
          (clog:attribute err "aria-live") "assertive"
          (clog:attribute input "aria-label") "Message")
    (labels ((add-line (role text)
      (let ((line (clog:create-div transcript
                                   :class (format nil "msg msg-~A" role))))
        (setf (clog:text line) text)
        line))
             (set-busy (v)
               (setf busy v)
               (setf (clog:disabledp send-btn) v)
               (setf (clog:disabledp stop-btn) (not v)))
             (on-event (ev)
               (let* ((d (event-display ev))
                      (role (car d))
                      (text (cdr d)))
                 (cond
                   ((eq (sm-harness:event-type ev) :status)
                    (setf (clog:text status-el) text))
                   ((eq (sm-harness:event-type ev) :terminal)
                    ;; A blank terminal text means the harness already showed
                    ;; this exact response via the assistant stream; only a
                    ;; genuinely distinct outcome (error, interrupt, tool-only
                    ;; turn) gets its own line here.
                    (when (and text (plusp (length text)))
                      (add-line role text))
                    (let ((cid (getf (sm-harness:event-payload ev) :session-id)))
                      (when cid (setf (clog:text canon-el) cid)))
                    (setf pending-prompt nil)
                    (set-busy nil)
                    (clog:focus input))
                   ((eq (sm-harness:event-type ev) :error)
                    (setf (clog:text err) text)
                    (when pending-prompt
                      (setf (clog:text-value input) pending-prompt))
                    (setf pending-prompt nil)
                    (set-busy nil))
                   (t (add-line role text))))))
      (dolist (entry (sm-harness:session-snapshot-transcript snap))
        (add-line (cond
                    ((string= "tool" (sm-harness:transcript-entry-kind entry)) "tool")
                    ;; A harness-initiated synthetic follow-up (#76) renders
                    ;; distinctly on reload/reopen too, matching the live path.
                    ((string= "synthetic" (sm-harness:transcript-entry-kind entry)) "harness")
                    (t (sm-harness:transcript-entry-role entry)))
                  (escape-text (sm-harness:transcript-entry-text entry))))
      (multiple-value-bind (snapshot lid cursor)
          (ui-attach session-id (lambda (ev) (ignore-errors (on-event ev))))
        (declare (ignore snapshot cursor))
        (setf listener-id lid))
      (set-busy nil)
      (clog:set-on-click back
        (lambda (obj)
          (declare (ignore obj))
          (when listener-id (ui-detach session-id listener-id))
          (clear-body body)
          (render-home body)
          (clog:js-execute body
                           "window.setTimeout(function () { document.getElementById('new-session').focus(); }, 0)")))
      (clog:set-on-click send-btn
        (lambda (obj)
          (declare (ignore obj))
          (unless busy
            (let ((prompt (clog:text-value input)))
              (handler-case
                  (progn
                    (setf pending-prompt prompt)
                    (ui-submit session-id prompt)
                    (setf (clog:text-value input) "")
                    (setf (clog:text err) "")
                    (set-busy t))
                (error (c)
                  (setf (clog:text err) (format nil "~A" c))))))))
      (clog:set-on-click stop-btn
        (lambda (obj)
          (declare (ignore obj))
          (ui-interrupt session-id)
          (setf (clog:text status-el) "Stopping")))
      (clog:set-on-key-down input
        (lambda (obj data)
          (declare (ignore obj))
          (when (and (equal (getf data :key) "Enter")
                     (not (getf data :shift-key))
                     (not busy))
            (let ((prompt (clog:text-value input)))
              (handler-case
                  (progn
                    (setf pending-prompt prompt)
                    (ui-submit session-id prompt)
                    (setf (clog:text-value input) "")
                    (set-busy t))
                (error (c)
                  (setf (clog:text err) (format nil "~A" c))))))))
      (clog:js-execute body
                       "window.setTimeout(function () { document.getElementById('prompt').focus(); }, 0)"))))
