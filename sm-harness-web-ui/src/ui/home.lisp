(in-package #:sm-harness-web-ui)

(defun set-session-route (body session-id)
  (clog:js-execute body
                   (format nil "window.history.replaceState(null, '', '/sessions/~A');" session-id)))

(defun render-not-found (body)
  (setf (clog:title (clog:html-document body)) "Session not found — sm-harness")
  (let ((root (clog:create-div body :class "page" :html-id "not-found-root"))
        (home nil))
    (clog:create-div root :class "error" :html-id "session-not-found"
                     :content "Session not found")
    (setf home (clog:create-button root :class "btn" :html-id "not-found-home"
                                   :content "Back to home"))
    (clog:set-on-click home
      (lambda (obj)
        (declare (ignore obj))
        (clear-body body)
        (render-home body)))))

(defun render-home (body)
  (setf (clog:title (clog:html-document body)) "sm-harness")
  (let* ((root (clog:create-div body :class "page" :html-id "home-root"))
         (header (clog:create-div root :class "header"))
         (_title (clog:create-section header :h1 :content "sm-harness"))
         (actions (clog:create-div root :class "actions"))
         (new-btn (clog:create-button actions :content "New session"
                                      :class "btn primary"
                                      :html-id "new-session"))
         (list-region (clog:create-div root :class "session-list"
                                       :html-id "session-list"))
         (status (clog:create-div root :class "status" :html-id "home-status"
                                  :content "Loading…")))
    (declare (ignore _title))
    (setf (clog:attribute root "role") "main"
          (clog:attribute list-region "role") "region"
          (clog:attribute list-region "aria-label") "Sessions")
    (clog:set-on-click new-btn
      (lambda (obj)
        (declare (ignore obj))
        (handler-case
            (let ((snap (ui-start-session)))
              (render-chat body (sm-harness:session-snapshot-id snap))
              (set-session-route body (sm-harness:session-snapshot-id snap)))
          (error (c)
            (setf (clog:text status) (format nil "Error: ~A" c))))))
    (handler-case
        (let ((sessions (ui-list-sessions)))
          (setf (clog:text status) "")
          (if (null sessions)
              (clog:create-div list-region :class "empty"
                               :content "No previous sessions yet"
                               :html-id "empty-sessions")
              (dolist (s sessions)
                (let* ((sid (sm-harness:session-summary-id s))
                       (row (clog:create-button list-region
                              :class "session-row"
                              :html-id (format nil "session-~A" sid)
                              :content
                              (format nil "~A — ~A — ~A"
                                      (sm-harness:session-summary-title s)
                                      (status-label (sm-harness:session-summary-status s))
                                      (or (sm-harness:session-summary-canonical-id s)
                                          "Pending…")))))
                  (clog:set-on-click row
                    (lambda (obj)
                      (declare (ignore obj))
                      (render-chat body sid)))))))
      (error (c)
        (setf (clog:text status) (format nil "Error loading sessions: ~A" c))))))
