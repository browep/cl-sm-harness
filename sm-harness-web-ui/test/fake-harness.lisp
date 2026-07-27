(in-package #:sm-harness-web-ui/tests)
(in-suite :sm-harness-web-ui/tests)

;;; Fake harness façade for pure UI-state tests (no SDK, no CLOG server).

(defvar *fake-sessions* nil)

(defun reset-fake ()
  (setf *fake-sessions* '()))
