(in-package #:sm-harness-web-ui)

(defstruct (web-ui-config (:constructor %make-web-ui-config))
  (host "0.0.0.0" :type string)
  (port 8080 :type integer)
  (static-root #P"static/" :type pathname))

(defun make-web-ui-config (&key (host "0.0.0.0") (port 8080) (static-root #P"static/"))
  (%make-web-ui-config :host host :port port
                       :static-root (uiop:ensure-directory-pathname static-root)))

(defvar *app-harness* nil)
(defvar *web-ui-config* nil)
(defvar *clog-server* nil)
