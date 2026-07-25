(in-package #:claude-agent-sdk-cl)

(defvar *transport-log-function* nil
  "Optional callback receiving full, unredacted transport event plists.")

(defun emit-transport-log (event &rest fields)
  (when *transport-log-function*
    (funcall *transport-log-function* (list* :event event fields))))
