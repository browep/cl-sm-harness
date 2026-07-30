(in-package #:sm-harness)

(define-condition harness-error (error)
  ((message :initarg :message :reader harness-error-message))
  (:report (lambda (c s) (format s "sm-harness: ~A" (harness-error-message c)))))

(define-condition harness-input-error (harness-error) ())
(define-condition harness-state-error (harness-error) ())
(define-condition harness-not-found-error (harness-error) ())

(defun %now-iso ()
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h m s)))

(defun %new-id (prefix)
  (format nil "~A-~A-~A" prefix (get-universal-time)
          (random 1000000 (make-random-state t))))

;;;; Static backend/model catalog (#106).
;;;;
;;;; This harness only ever drives the `claude` CLI (see
;;;; docs/api-parity.md) -- "Claude" is the sole backend today, kept as its
;;;; own catalog level rather than hard-coding that assumption, so a second
;;;; backend is additive later instead of a rework. Each model entry is a
;;;; CLI `--model` alias; the issue's own ask is that every entry here is
;;;; verified against a live `claude -p --model <alias>` invocation before
;;;; being added (see docs/sm-harness.md), not merely guessed from --help
;;;; text.

(defstruct (model-descriptor (:constructor make-model-descriptor))
  (id "" :type string)
  (label "" :type string))

(defstruct (backend-descriptor (:constructor make-backend-descriptor))
  (id "" :type string)
  (label "" :type string)
  (models '() :type list))

(defparameter *backend-catalog*
  (list (make-backend-descriptor
         :id "claude" :label "Claude"
         :models (list (make-model-descriptor :id "sonnet" :label "Claude Sonnet")
                       (make-model-descriptor :id "opus" :label "Claude Opus")
                       (make-model-descriptor :id "haiku" :label "Claude Haiku")
                       (make-model-descriptor :id "fable" :label "Claude Fable"))))
  "Static (backend . models) catalog offered by the new-session flow and
shown back in a session's info panel. Extending this list is a deliberate,
reviewed edit, not runtime discovery -- each model id is passed verbatim as
`claude`'s `--model <alias>` (src/transport/subprocess-query.lisp).")

(defparameter *default-backend-id* "claude")
(defparameter *default-model-id* "sonnet")

(defun backend-catalog ()
  "The static list of BACKEND-DESCRIPTORs available for session creation."
  *backend-catalog*)

(defun find-backend (backend-id)
  (and (stringp backend-id)
       (find backend-id *backend-catalog* :key #'backend-descriptor-id :test #'string=)))

(defun find-model (backend-id model-id)
  (and (stringp model-id)
       (let ((b (find-backend backend-id)))
         (and b (find model-id (backend-descriptor-models b)
                     :key #'model-descriptor-id :test #'string=)))))

(defun valid-backend-id-p (backend-id)
  (and (find-backend backend-id) t))

(defun valid-model-id-p (backend-id model-id)
  (and (find-model backend-id model-id) t))

(defstruct (transcript-entry (:constructor make-transcript-entry))
  (role "user" :type string)
  (text "" :type string)
  (kind "message" :type string)
  (meta nil)
  (created-at (%now-iso) :type string))

(defstruct (session-record (:constructor %make-session-record))
  (id "" :type string)
  (title "New session" :type string)
  (status :ready)
  (canonical-id nil)
  (created-at (%now-iso) :type string)
  (updated-at (%now-iso) :type string)
  (transcript '() :type list)
  (draft nil)
  (active-turn-id nil)
  (sequence 0 :type integer)
  ;; #106: static backend/model choice made at session-creation time.
  ;; BACKEND defaults to the sole supported backend; MODEL defaults to NIL,
  ;; meaning "no explicit per-session override" -- HARNESS-CONFIG-MODEL (or
  ;; ultimately the `claude` CLI's own default) still applies, exactly the
  ;; pre-#106 behavior, so a caller that never mentions :MODEL sees no
  ;; change. A session created through the web UI always gets an explicit
  ;; MODEL from its new-session dropdown instead of relying on that
  ;; fallback, so its info panel always has something concrete to show.
  (backend "claude" :type string)
  model)

(defun make-session-record (&key id title backend model)
  (%make-session-record
   :id (or id (%new-id "sess"))
   :title (or title "New session")
   :backend (or backend *default-backend-id*)
   :model model))

(defstruct (session-summary (:constructor make-session-summary))
  id title updated-at status canonical-id backend model)

(defstruct (session-snapshot (:constructor make-session-snapshot))
  id title status canonical-id transcript cursor backend model)

(defun session-record->summary (rec)
  (make-session-summary
   :id (session-record-id rec)
   :title (session-record-title rec)
   :updated-at (session-record-updated-at rec)
   :status (session-record-status rec)
   :canonical-id (session-record-canonical-id rec)
   :backend (session-record-backend rec)
   :model (session-record-model rec)))

(defun session-record->snapshot (rec)
  (make-session-snapshot
   :id (session-record-id rec)
   :title (session-record-title rec)
   :status (session-record-status rec)
   :canonical-id (session-record-canonical-id rec)
   :transcript (copy-list (session-record-transcript rec))
   :cursor (session-record-sequence rec)
   :backend (session-record-backend rec)
   :model (session-record-model rec)))
