(in-package #:sm-harness-web-ui)

;;;; Web layer talks only to sm-harness — never claude-agent-sdk-cl.

(defun ensure-harness ()
  (or *app-harness*
      (error "sm-harness-web-ui: harness not started")))

(defun ui-start-session (&key backend model)
  "BACKEND/MODEL (#106) are an explicit choice from the new-session dropdowns,
validated against SM-HARNESS:BACKEND-CATALOG by SM-HARNESS:START-SESSION
itself -- this layer passes them through verbatim rather than re-validating,
since sm-harness is the single source of truth for what is a legal choice."
  (sm-harness:start-session (ensure-harness) :backend backend :model model))

(defun ui-list-sessions ()
  (sm-harness:list-sessions (ensure-harness)))

(defun ui-open-session (id)
  (sm-harness:open-session (ensure-harness) id))

(defun ui-submit (session-id prompt)
  (sm-harness:submit-turn (ensure-harness) session-id prompt))

(defun ui-interrupt (session-id &optional turn-id)
  (sm-harness:interrupt-turn (ensure-harness) session-id turn-id))

(defun ui-attach (session-id callback)
  (sm-harness:attach-session-listener (ensure-harness) session-id :callback callback))

(defun ui-detach (session-id listener-id)
  (sm-harness:detach-session-listener (ensure-harness) session-id listener-id))
