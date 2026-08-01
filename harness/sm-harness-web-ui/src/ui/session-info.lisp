(in-package #:sm-harness-web-ui)

(defun install-session-info-panel (header root snap session-id canon-el title-el)
  "Adds an 'Info' control (#106) to HEADER, opening a panel appended to ROOT
that shows this session's id, canonical provider id, title, and its
backend/model choice. SNAP is the SESSION-SNAPSHOT taken when the chat
screen was rendered -- backend/model are fixed at session-creation time and
never change over a session's life, so no live update wiring is needed for
those two, but CANON-EL's live text (it starts as \"Pending…\" and is
overwritten in place once the provider assigns a canonical id, see
render-chat) is read fresh on every click rather than captured once, so the
panel never shows a stale \"Pending…\" after that happens. TITLE-EL is read
fresh the same way (#129): a SET_SESSION_TITLE rename updates TITLE-EL's
live text in place (render-chat's ON-EVENT :TITLE branch), so reading it
here instead of SNAP's captured title keeps a reopened Info panel from
showing a name the session was renamed away from, possibly minutes
earlier, without requiring a page reload."
  (let* ((btn (clog:create-button header :content "Info"
                                  :class "btn" :html-id "session-info"))
         (panel (clog:create-div root :class "info-panel" :html-id "info-panel"))
         (body-el (clog:create-div panel :class "info-panel-body"
                                   :html-id "info-panel-body"))
         (panel-actions (clog:create-div panel :class "info-panel-actions"))
         (close-btn (clog:create-button panel-actions :content "Close"
                                        :class "btn" :html-id "info-close")))
    (setf (clog:hiddenp panel) t
          (clog:attribute btn "aria-label") "Show session info"
          (clog:attribute panel "role") "dialog"
          (clog:attribute panel "aria-label") "Session info")
    (clog:set-on-click btn
      (lambda (obj)
        (declare (ignore obj))
        (setf (clog:inner-html body-el)
              (format nil
                      "<div><strong>Session id:</strong> ~A</div>~
<div><strong>Canonical id:</strong> ~A</div>~
<div><strong>Title:</strong> ~A</div>~
<div><strong>Backend:</strong> ~A</div>~
<div><strong>Model:</strong> ~A</div>"
                      (escape-text session-id)
                      (escape-text (clog:text canon-el))
                      (escape-text (clog:text title-el))
                      (escape-text (%backend-label (sm-harness:session-snapshot-backend snap)))
                      (escape-text (%model-label (sm-harness:session-snapshot-backend snap)
                                                 (sm-harness:session-snapshot-model snap)))))
        (setf (clog:hiddenp panel) nil)))
    (clog:set-on-click close-btn
      (lambda (obj)
        (declare (ignore obj))
        (setf (clog:hiddenp panel) t)))
    (values btn panel)))
