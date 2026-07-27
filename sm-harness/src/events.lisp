(in-package #:sm-harness)

(defstruct (event (:constructor make-event))
  (type :unknown)
  (sequence 0 :type integer)
  (session-id "" :type string)
  (payload nil))

(defun %event (type session-id sequence payload)
  (make-event :type type :session-id session-id :sequence sequence :payload payload))
