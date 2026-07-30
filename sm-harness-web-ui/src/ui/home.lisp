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

(defun %populate-model-select (select-el backend-id)
  "Refill SELECT-EL (#106) with the models the static catalog offers for
BACKEND-ID, selecting SM-HARNESS:*DEFAULT-MODEL-ID* when it is one of
them. Called both at initial render and whenever the backend select
changes -- today's catalog has exactly one backend, but this stays
generically correct rather than assuming that never changes."
  (setf (clog:inner-html select-el) "")
  (let ((backend (sm-harness:find-backend backend-id)))
    (dolist (m (and backend (sm-harness:backend-descriptor-models backend)))
      (clog:add-select-option select-el
                              (sm-harness:model-descriptor-id m)
                              (sm-harness:model-descriptor-label m)
                              :selected (string= (sm-harness:model-descriptor-id m)
                                                 sm-harness:*default-model-id*)))))

(defun render-home (body)
  (setf (clog:title (clog:html-document body)) "sm-harness")
  ;; Browser log capture (#92): no session is active on this screen, and
  ;; recording the navigation itself lets exported logs be matched against
  ;; when the tab left a session for home.
  (%log-set-session body nil)
  (%log-nav body "home")
  (let* ((root (clog:create-div body :class "page" :html-id "home-root"))
         (header (clog:create-div root :class "header"))
         (_title (clog:create-section header :h1 :content "sm-harness"))
         ;; Positioned here (#92) so the panel opens directly under the
         ;; header row that holds the button, above the session actions
         ;; and list, instead of appearing after everything at the bottom
         ;; of the page.
         (log-panel (install-log-export-panel body header root))
         (actions (clog:create-div root :class "actions"))
         ;; #106: an explicit, static backend/model choice at session
         ;; creation. Both selects are populated from
         ;; SM-HARNESS:BACKEND-CATALOG -- the single source of truth this
         ;; harness itself validates START-SESSION's :BACKEND/:MODEL
         ;; against, so a choice this dropdown can produce is always legal.
         (backend-label (clog:create-label actions :content "Backend"
                                           :html-id "backend-label"))
         (backend-select (clog:create-select actions :class "backend-select"
                                             :html-id "backend-select"))
         (model-label (clog:create-label actions :content "Model"
                                         :html-id "model-label"))
         (model-select (clog:create-select actions :class "model-select"
                                           :html-id "model-select"))
         (new-btn (clog:create-button actions :content "New session"
                                      :class "btn primary"
                                      :html-id "new-session"))
         (list-region (clog:create-div root :class "session-list"
                                       :html-id "session-list"))
         (status (clog:create-div root :class "status" :html-id "home-status"
                                  :content "Loading…")))
    (declare (ignore _title log-panel))
    (setf (clog:attribute root "role") "main"
          (clog:attribute list-region "role") "region"
          (clog:attribute list-region "aria-label") "Sessions"
          (clog:attribute backend-select "aria-label") "Backend"
          (clog:attribute model-select "aria-label") "Model"
          (clog:attribute backend-label "for") "backend-select"
          (clog:attribute model-label "for") "model-select")
    (dolist (b (sm-harness:backend-catalog))
      (clog:add-select-option backend-select
                              (sm-harness:backend-descriptor-id b)
                              (sm-harness:backend-descriptor-label b)
                              :selected (string= (sm-harness:backend-descriptor-id b)
                                                 sm-harness:*default-backend-id*)))
    (%populate-model-select model-select sm-harness:*default-backend-id*)
    (clog:set-on-change backend-select
      (lambda (obj)
        (declare (ignore obj))
        (%populate-model-select model-select (clog:value backend-select))))
    (clog:set-on-click new-btn
      (lambda (obj)
        (declare (ignore obj))
        (handler-case
            (let ((snap (ui-start-session :backend (clog:value backend-select)
                                          :model (clog:value model-select))))
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
                              ;; #111: title/status plus a row of
                              ;; session-id/backend/model/turn-count/
                              ;; elapsed-time/canonical-id chips -- built in
                              ;; presenter.lisp (%SESSION-CHIP-HTML) so it
                              ;; is covered by PRESENTER-TESTS without a
                              ;; live CLOG server.
                              :content (%session-chip-html s))))
                  (clog:set-on-click row
                    (lambda (obj)
                      (declare (ignore obj))
                      (render-chat body sid)))))))
      (error (c)
        (setf (clog:text status) (format nil "Error loading sessions: ~A" c))))))
