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
  (sequence 0 :type integer))

(defun make-session-record (&key id title)
  (%make-session-record
   :id (or id (%new-id "sess"))
   :title (or title "New session")))

(defstruct (session-summary (:constructor make-session-summary))
  id title updated-at status canonical-id)

(defstruct (session-snapshot (:constructor make-session-snapshot))
  id title status canonical-id transcript cursor)

(defun session-record->summary (rec)
  (make-session-summary
   :id (session-record-id rec)
   :title (session-record-title rec)
   :updated-at (session-record-updated-at rec)
   :status (session-record-status rec)
   :canonical-id (session-record-canonical-id rec)))

(defun session-record->snapshot (rec)
  (make-session-snapshot
   :id (session-record-id rec)
   :title (session-record-title rec)
   :status (session-record-status rec)
   :canonical-id (session-record-canonical-id rec)
   :transcript (copy-list (session-record-transcript rec))
   :cursor (session-record-sequence rec)))
