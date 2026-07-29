(in-package #:sm-harness)

(defstruct (harness-config (:constructor %make-harness-config))
  (data-root #P"/data/" :type pathname)
  (project-key "default" :type string)
  (idle-ttl-seconds 1800 :type integer)
  (turn-deadline-seconds 600 :type integer)
  (listener-mailbox-size 256 :type integer)
  ;; Optional injected transport factory for tests: (lambda (options) transport-or-nil)
  transport-factory
  cli-path
  model)

(defun make-harness-config (&key (data-root #P"/data/")
                                 (project-key "default")
                                 (idle-ttl-seconds 1800)
                                 (turn-deadline-seconds 600)
                                 (listener-mailbox-size 256)
                                 transport-factory
                                 cli-path
                                 model)
  (unless (and (integerp idle-ttl-seconds) (plusp idle-ttl-seconds))
    (error 'harness-input-error :message "idle-ttl-seconds must be a positive integer"))
  (unless (and (integerp turn-deadline-seconds) (plusp turn-deadline-seconds))
    (error 'harness-input-error :message "turn-deadline-seconds must be a positive integer"))
  (unless (and (stringp project-key) (plusp (length project-key)))
    (error 'harness-input-error :message "project-key must be a non-empty string"))
  (%make-harness-config
   :data-root (uiop:ensure-directory-pathname (pathname data-root))
   :project-key project-key
   :idle-ttl-seconds idle-ttl-seconds
   :turn-deadline-seconds turn-deadline-seconds
   :listener-mailbox-size listener-mailbox-size
   :transport-factory transport-factory
   :cli-path cli-path
   :model model))
