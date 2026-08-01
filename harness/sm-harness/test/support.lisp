(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(defun temp-data-root ()
  (let ((p (merge-pathnames
            (format nil "sm-harness-test-~A/" (get-universal-time))
            (uiop:temporary-directory))))
    (ensure-directories-exist p)
    p))

(defun wait-until (pred &key (timeout 5.0) (interval 0.05))
  (let ((start (get-internal-real-time))
        (limit (* timeout internal-time-units-per-second)))
    (loop
      (when (funcall pred) (return t))
      (when (> (- (get-internal-real-time) start) limit)
        (return nil))
      (sleep interval))))
