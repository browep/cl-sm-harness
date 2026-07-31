(in-package #:sm-harness)

(defun make-harness (&key config catalog policy)
  "CATALOG, if supplied, is a fixed TOOL-CATALOG value used for this
harness's whole lifetime -- the shape every existing caller (tests, the
web UI's E2E fixture catalog) already passes, and it keeps working
unchanged. Omitting CATALOG (the real production path: sm-harness-web-ui's
MAIN never passes one) instead defers to DEFAULT-TOOL-CATALOG, re-called
fresh on every new client connection rather than fixed once here (#116) --
see HARNESS-CATALOG-PROVIDER's docstring in runtime.lisp for why a fixed
snapshot made a RELOAD_HARNESS-added tool invisible to every session,
including ones not yet created, for the rest of a process's life."
  (let* ((cfg (or config (make-harness-config)))
         (repo (open-session-repository
                :root (harness-config-data-root cfg)
                :project-key (harness-config-project-key cfg)))
         (catalog-provider (if catalog
                               (lambda () catalog)
                               #'default-tool-catalog)))
    (%make-harness
     :config cfg
     :repository repo
     :catalog-provider catalog-provider
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
       ;; Terminal teardown: dispatcher threads must not outlive the
       ;; harness (tests leak threads otherwise), and nothing is listening
       ;; for the remaining events, so discard rather than flush.
       (maphash (lambda (lid lst)
                  (declare (ignore lid))
                  (listener-close lst :discard t :join-timeout 1))
                (session-runtime-listeners rt))
       (clrhash (session-runtime-listeners rt))
       (let ((client (session-runtime-client rt)))
         (when client
           (ignore-errors (interrupt-client client))
           (ignore-errors (disconnect-client client))
           (setf (session-runtime-client rt) nil))))
     (harness-sessions harness))
    (clrhash (harness-sessions harness))
    (close-session-repository (harness-repository harness))
    harness))

(defun start-session (harness &key title backend model)
  (when (harness-closed-p harness)
    (error 'harness-state-error :message "harness is closed"))
  (let ((backend (or backend *default-backend-id*)))
    (unless (valid-backend-id-p backend)
      (error 'harness-input-error
             :message (format nil "unknown backend: ~A" backend)))
    (when (and model (not (valid-model-id-p backend model)))
      (error 'harness-input-error
             :message (format nil "unknown model ~A for backend ~A" model backend)))
    (let ((rec (make-session-record :title title :backend backend :model model)))
      (repository-save-session (harness-repository harness) rec)
      (sb-thread:with-mutex ((harness-lock harness))
        (%open-runtime harness rec))
      (session-record->snapshot rec))))

(defun list-sessions (harness)
  (repository-list-sessions (harness-repository harness)))

(defun open-session (harness session-id)
  (when (harness-closed-p harness)
    (error 'harness-state-error :message "harness is closed"))
  ;; Opportunistic sweep makes idle eviction automatic without a second owner
  ;; thread: reopening an old browser/session always reconstructs from durable
  ;; state when its client aged out.
  (evict-idle-sessions harness)
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

(defun submit-turn (harness session-id prompt &key (kind "message"))
  "KIND tags the durable transcript entry and published :user-message event
(default \"message\"). Internal harness-initiated follow-ups (#76) pass
\"synthetic\" so they render distinctly and are never mistaken for a
message the human actually typed."
  (unless (and (stringp prompt)
               (plusp (length (string-trim '(#\Space #\Tab #\Newline) prompt))))
    (error 'harness-input-error :message "prompt must be a non-empty string"))
  (let ((rt (%get-runtime harness session-id)))
    (sb-thread:with-mutex ((session-runtime-lock rt))
      (when (session-record-active-turn-id (session-runtime-record rt))
        (error 'harness-state-error :message "session already has an active turn"))
      (let ((turn-id (%new-id "turn")))
        (setf (session-record-active-turn-id (session-runtime-record rt)) turn-id)
        (%enqueue rt (list :turn turn-id prompt kind))
        turn-id))))

(defun evict-idle-sessions (harness &key (now (get-universal-time)))
  "Disconnect and unload idle, non-active runtimes while retaining durable records.
A later OPEN-SESSION constructs a replacement client from the canonical ID."
  (let ((ttl (harness-config-idle-ttl-seconds (harness-config harness)))
        (victims '()))
    (sb-thread:with-mutex ((harness-lock harness))
      (maphash
       (lambda (session-id rt)
         (sb-thread:with-mutex ((session-runtime-lock rt))
           (when (and (null (session-record-active-turn-id
                             (session-runtime-record rt)))
                      (>= (- now (session-runtime-last-activity rt)) ttl))
             (push (cons session-id rt) victims))))
       (harness-sessions harness))
      (dolist (victim victims)
        (remhash (car victim) (harness-sessions harness))))
    (dolist (victim victims)
      (let* ((rt (cdr victim))
             (client (session-runtime-client rt))
             (listeners (sb-thread:with-mutex ((session-runtime-lock rt))
                          (let (ls)
                            (maphash (lambda (id lst)
                                       (declare (ignore id))
                                       (push lst ls))
                                     (session-runtime-listeners rt))
                            (clrhash (session-runtime-listeners rt))
                            ls))))
        (setf (session-runtime-closed-p rt) t)
        (%enqueue rt (cons :stop nil))
        ;; :DISCARD -- an evicted runtime's listeners belong to browsers
        ;; that are idle at best and gone at worst; flushing through a dead
        ;; CLOG connection would serialize its per-query timeouts here.
        (dolist (lst listeners)
          (listener-close lst :discard t :join-timeout 1))
        (when client
          (ignore-errors (disconnect-client client))
          (setf (session-runtime-client rt) nil))))
    (mapcar #'car (nreverse victims))))

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
  (let ((rt (%get-runtime harness session-id :errorp nil))
        (lst nil))
    (when rt
      (sb-thread:with-mutex ((session-runtime-lock rt))
        (setf lst (gethash listener-id (session-runtime-listeners rt)))
        (when lst
          (remhash listener-id (session-runtime-listeners rt))))
      ;; Graceful detach: already-published events still flush through the
      ;; callback before the dispatcher exits, so a detacher that waited for
      ;; a turn to finish has observed every event of that turn on return.
      ;; Closed outside the runtime lock -- LISTENER-CLOSE joins the
      ;; dispatcher, which may be mid-callback for several seconds.
      (when lst (listener-close lst)))
    t))

(defun session-status (harness session-id)
  (session-record-status
   (session-runtime-record (%get-runtime harness session-id))))
