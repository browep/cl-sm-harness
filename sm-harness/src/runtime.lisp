(in-package #:sm-harness)

(defstruct (session-runtime (:constructor %make-session-runtime))
  record
  client
  (listeners (make-hash-table :test #'equal))
  (lock (sb-thread:make-mutex :name "session-runtime"))
  worker-thread
  (mailbox (list))
  (mailbox-lock (sb-thread:make-mutex :name "session-mailbox"))
  (mailbox-cv (sb-thread:make-waitqueue :name "session-mailbox"))
  (closed-p nil)
  last-activity)

(defstruct (harness (:constructor %make-harness))
  config
  repository
  catalog
  policy
  (sessions (make-hash-table :test #'equal))
  (lock (sb-thread:make-mutex :name "harness"))
  (closed-p nil))

(defun %touch (rt)
  (setf (session-runtime-last-activity rt) (get-universal-time)))

(defun %publish (rt type payload)
  (let* ((rec (session-runtime-record rt))
         (seq (incf (session-record-sequence rec)))
         (ev (%event type (session-record-id rec) seq payload)))
    (maphash (lambda (id lst)
               (declare (ignore id))
               (listener-push lst ev)
               (when (functionp (listener-callback lst))
                 (ignore-errors (funcall (listener-callback lst) ev))))
             (session-runtime-listeners rt))
    ev))

(defun %set-status (rt status)
  (setf (session-record-status (session-runtime-record rt)) status)
  (%publish rt :status (list :status status)))

(defun %append-transcript (rt role text &key (kind "message") meta)
  (let ((entry (make-transcript-entry :role role :text text :kind kind :meta meta)))
    (setf (session-record-transcript (session-runtime-record rt))
          (append (session-record-transcript (session-runtime-record rt))
                  (list entry)))
    entry))

(defun %enqueue (rt message)
  (sb-thread:with-mutex ((session-runtime-mailbox-lock rt))
    (setf (session-runtime-mailbox rt)
          (append (session-runtime-mailbox rt) (list message)))
    (sb-thread:condition-notify (session-runtime-mailbox-cv rt))))

(defun %dequeue (rt)
  (sb-thread:with-mutex ((session-runtime-mailbox-lock rt))
    (loop
      (when (session-runtime-closed-p rt)
        (return nil))
      (let ((mb (session-runtime-mailbox rt)))
        (when mb
          (setf (session-runtime-mailbox rt) (cdr mb))
          (return (car mb))))
      (sb-thread:condition-wait (session-runtime-mailbox-cv rt)
                                (session-runtime-mailbox-lock rt)))))

(defun %ensure-client (harness rt &key resume)
  (when (session-runtime-client rt)
    (return-from %ensure-client (session-runtime-client rt)))
  (let* ((cfg (harness-config harness))
         (catalog (default-tool-catalog))
         (policy (harness-policy harness))
         (options (build-agent-options catalog policy
                                       :resume resume
                                       :model (harness-config-model cfg)))
         (factory (harness-config-transport-factory cfg))
         (transport (when factory (funcall factory options)))
         (handlers (list (cons "can_use_tool" (%can-use-tool-handler policy))))
         (client (make-sdk-client options
                                  :transport transport
                                  :cli-path (harness-config-cli-path cfg)
                                  :control-handlers handlers)))
    (setf (session-runtime-client rt) client
          (harness-catalog harness) catalog)
    (%set-status rt :connecting)
    (connect-client client)
    (%set-status rt :ready)
    client))

(defun %handle-mapped-event (rt rec mapped)
  (let ((etype (first mapped))
        (payload (rest mapped)))
    (case etype
      (:assistant-text
       (let ((text (getf payload :text)))
         (%append-transcript rt "assistant" text)
         (%publish rt :assistant-text payload)
         nil))
      (:tool-requested
       (%append-transcript rt "assistant"
                           (format nil "Tool requested: ~A" (getf payload :name))
                           :kind "tool" :meta payload)
       (%publish rt :tool-requested payload)
       nil)
      (:tool-completed
       (%append-transcript rt "assistant" "Tool completed"
                           :kind "tool" :meta payload)
       (%publish rt :tool-completed payload)
       nil)
      (:tool-failed
       (%append-transcript rt "assistant" "Tool failed"
                           :kind "tool" :meta payload)
       (%publish rt :tool-failed payload)
       nil)
      (:system
       (%publish rt :system payload)
       nil)
      (:rate-limit
       (%publish rt :rate-limit payload)
       nil)
      (:terminal
       (let ((cid (getf payload :session-id)))
         (when (and cid (stringp cid) (plusp (length cid)))
           (setf (session-record-canonical-id rec) cid)))
       (%append-transcript rt "system" (or (getf payload :text) "")
                           :kind "result" :meta payload)
       (%publish rt :terminal payload)
       (%set-status rt :ready)
       :done)
      (t
       (%publish rt etype payload)
       nil))))

(defun %run-turn (harness rt turn-id prompt)
  (let ((rec (session-runtime-record rt))
        (deadline (harness-config-turn-deadline-seconds (harness-config harness))))
    (handler-case
        (progn
          (setf (session-record-active-turn-id rec) turn-id)
          (%append-transcript rt "user" prompt)
          (%publish rt :user-message (list :text prompt :turn-id turn-id))
          (repository-save-session (harness-repository harness) rec)
          (let* ((resume (session-record-canonical-id rec))
                 (client (%ensure-client harness rt :resume resume))
                 (start (get-universal-time))
                 (done nil))
            (%set-status rt :responding)
            (send-prompt client prompt
                         :session-id (or (session-record-canonical-id rec)
                                         (session-record-id rec)))
            (loop until done do
              (when (> (- (get-universal-time) start) deadline)
                (%set-status rt :stopping)
                (ignore-errors (interrupt-client client))
                (%publish rt :error (list :message "turn deadline exceeded"))
                (ignore-errors (disconnect-client client))
                (setf (session-runtime-client rt) nil)
                (%set-status rt :error)
                (setf done t))
              (unless done
                (let ((msg (receive-one-message client)))
                  (cond
                    ((null msg)
                     (%set-status rt :disconnected)
                     (setf (session-runtime-client rt) nil)
                     (setf done t))
                    (t
                     (dolist (mapped (map-sdk-message msg))
                       (when (eq :done (%handle-mapped-event rt rec mapped))
                         (setf done t))))))))
            (setf (session-record-active-turn-id rec) nil)
            (repository-save-session (harness-repository harness) rec)
            (%touch rt)))
      (error (c)
        (setf (session-record-active-turn-id rec) nil)
        (%publish rt :error (safe-error-payload c))
        (%set-status rt :error)
        (ignore-errors
          (when (session-runtime-client rt)
            (disconnect-client (session-runtime-client rt))
            (setf (session-runtime-client rt) nil)))
        (repository-save-session (harness-repository harness) rec)))))

(defun %worker-loop (harness rt)
  (loop
    (when (session-runtime-closed-p rt)
      (return))
    (let ((msg (%dequeue rt)))
      (unless msg (return))
      (destructuring-bind (op . args) msg
        (ecase op
          (:turn
           (destructuring-bind (turn-id prompt) args
             (%run-turn harness rt turn-id prompt)))
          (:interrupt
           (let ((client (session-runtime-client rt)))
             (when client
               (%set-status rt :stopping)
               (ignore-errors (interrupt-client client)))))
          (:stop (return)))))))

(defun %start-worker (harness rt)
  (unless (and (session-runtime-worker-thread rt)
               (sb-thread:thread-alive-p (session-runtime-worker-thread rt)))
    (setf (session-runtime-worker-thread rt)
          (sb-thread:make-thread
           (lambda () (%worker-loop harness rt))
           :name (format nil "sm-session-~A"
                         (session-record-id (session-runtime-record rt)))))))

(defun %get-runtime (harness session-id &key (errorp t))
  (sb-thread:with-mutex ((harness-lock harness))
    (or (gethash session-id (harness-sessions harness))
        (when errorp
          (error 'harness-not-found-error
                 :message (format nil "session not open: ~A" session-id))))))

(defun %open-runtime (harness rec)
  (let ((rt (%make-session-runtime :record rec :last-activity (get-universal-time))))
    (setf (gethash (session-record-id rec) (harness-sessions harness)) rt)
    (%start-worker harness rt)
    rt))
