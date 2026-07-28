(in-package #:sm-harness)

(defun make-harness (&key config catalog policy)
  (let* ((cfg (or config (make-harness-config)))
         (repo (open-session-repository
                :root (harness-config-data-root cfg)
                :project-key (harness-config-project-key cfg))))
    (%make-harness
     :config cfg
     :repository repo
     :catalog (or catalog (default-tool-catalog))
     :policy (or policy (default-tool-policy)))))

(defun close-harness (harness)
  (sb-thread:with-mutex ((harness-lock harness))
    (when (harness-closed-p harness)
      (return-from close-harness harness))
    (setf (harness-closed-p harness) t)
    (maphash
     (lambda (id rt)
       (declare (ignore id))
       (setf (session-runtime-closed-p rt) t)
       (%enqueue rt (cons :stop nil))
       (let ((client (session-runtime-client rt)))
         (when client
           (ignore-errors (interrupt-client client))
           (ignore-errors (disconnect-client client))
           (setf (session-runtime-client rt) nil))))
     (harness-sessions harness))
    (clrhash (harness-sessions harness))
    (close-session-repository (harness-repository harness))
    harness))

(defun start-session (harness &key title)
  (when (harness-closed-p harness)
    (error 'harness-state-error :message "harness is closed"))
  (let ((rec (make-session-record :title title)))
    (repository-save-session (harness-repository harness) rec)
    (sb-thread:with-mutex ((harness-lock harness))
      (%open-runtime harness rec))
    (session-record->snapshot rec)))

(defun list-sessions (harness)
  (repository-list-sessions (harness-repository harness)))

(defun open-session (harness session-id)
  (when (harness-closed-p harness)
    (error 'harness-state-error :message "harness is closed"))
  (let ((existing (sb-thread:with-mutex ((harness-lock harness))
                    (gethash session-id (harness-sessions harness)))))
    (when existing
      (return-from open-session
        (session-record->snapshot (session-runtime-record existing)))))
  (let ((rec (repository-load-session (harness-repository harness) session-id)))
    (setf (session-record-status rec) :ready
          (session-record-active-turn-id rec) nil)
    (sb-thread:with-mutex ((harness-lock harness))
      (%open-runtime harness rec))
    (session-record->snapshot rec)))

(defun submit-turn (harness session-id prompt)
  (unless (and (stringp prompt)
               (plusp (length (string-trim '(#\Space #\Tab #\Newline) prompt))))
    (error 'harness-input-error :message "prompt must be a non-empty string"))
  (let ((rt (%get-runtime harness session-id)))
    (sb-thread:with-mutex ((session-runtime-lock rt))
      (when (session-record-active-turn-id (session-runtime-record rt))
        (error 'harness-state-error :message "session already has an active turn"))
      (let ((turn-id (%new-id "turn")))
        (setf (session-record-active-turn-id (session-runtime-record rt)) turn-id)
        (%enqueue rt (list :turn turn-id prompt))
        turn-id))))

(defun interrupt-turn (harness session-id &optional turn-id)
  (let* ((rt (%get-runtime harness session-id))
         (active (sb-thread:with-mutex ((session-runtime-lock rt))
                   (session-record-active-turn-id (session-runtime-record rt)))))
    (cond
      ((null active) nil)
      ((and turn-id (not (string= turn-id active))) nil)
      (t
       (%request-cancellation rt active :interrupt)
       active))))

(defun attach-session-listener (harness session-id &key callback)
  (let* ((rt (%get-runtime harness session-id))
         (cfg (harness-config harness))
         (listener (make-listener session-id
                                  (harness-config-listener-mailbox-size cfg)
                                  callback)))
    (sb-thread:with-mutex ((session-runtime-lock rt))
      (setf (gethash (listener-id listener) (session-runtime-listeners rt)) listener)
      (values (session-record->snapshot (session-runtime-record rt))
              (listener-id listener)
              (session-record-sequence (session-runtime-record rt))))))

(defun detach-session-listener (harness session-id listener-id)
  (let ((rt (%get-runtime harness session-id :errorp nil)))
    (when rt
      (sb-thread:with-mutex ((session-runtime-lock rt))
        (let ((lst (gethash listener-id (session-runtime-listeners rt))))
          (when lst
            (setf (listener-closed-p lst) t)
            (remhash listener-id (session-runtime-listeners rt))))))
    t))

(defun session-status (harness session-id)
  (session-record-status
   (session-runtime-record (%get-runtime harness session-id))))
