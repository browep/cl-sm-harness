(in-package #:sm-harness)

(defstruct (listener (:constructor %make-listener))
  id
  session-id
  (queue '() :type list)
  capacity
  (overflowed-p nil)
  callback
  (closed-p nil)
  (lock (sb-thread:make-mutex :name "listener")))

(defun make-listener (session-id capacity callback)
  (%make-listener
   :id (%new-id "lst")
   :session-id session-id
   :capacity capacity
   :callback callback))

(defun listener-push (listener event)
  "Enqueue EVENT under lock. Overflow sets gap flag and drops oldest."
  (sb-thread:with-mutex ((listener-lock listener))
    (unless (listener-closed-p listener)
      (let ((q (listener-queue listener)))
        (when (>= (length q) (listener-capacity listener))
          (setf (listener-overflowed-p listener) t
                q (cdr q)))
        (setf (listener-queue listener) (append q (list event)))))))

(defun listener-drain (listener)
  (sb-thread:with-mutex ((listener-lock listener))
    (let ((q (listener-queue listener))
          (gap (listener-overflowed-p listener)))
      (setf (listener-queue listener) '()
            (listener-overflowed-p listener) nil)
      (values q gap))))
