(in-package #:sm-harness)

;;;; Durable application index/transcript under a single-writer data root.

(defstruct (session-repository (:constructor %make-session-repository))
  root
  project-key
  lock-stream
  (lock (sb-thread:make-mutex :name "session-repository")))

(defun %repo-project-dir (repo)
  (merge-pathnames
   (make-pathname :directory (list :relative (session-repository-project-key repo)))
   (session-repository-root repo)))

(defun %repo-index-path (repo)
  (merge-pathnames "index.json" (%repo-project-dir repo)))

(defun %repo-session-path (repo session-id)
  (merge-pathnames (format nil "sessions/~A.json" session-id)
                   (%repo-project-dir repo)))

(defun %repo-lock-path (repo)
  (merge-pathnames ".harness.lock" (session-repository-root repo)))

(defun %json-encode-to-file (path object)
  (ensure-directories-exist path)
  (let* ((tmp (make-pathname :defaults path :type "tmp"))
         (json (with-output-to-string (s) (yason:encode object s))))
    (with-open-file (out tmp :direction :output :if-exists :supersede
                         :if-does-not-exist :create)
      (write-string json out)
      (finish-output out))
    (uiop:rename-file-overwriting-target tmp path)))

(defun %json-decode-file (path)
  (when (probe-file path)
    (handler-case
        (with-open-file (in path :direction :input)
          (let ((raw (make-string (file-length in))))
            (read-sequence raw in)
            (when (plusp (length raw))
              (yason:parse raw))))
      (error () nil))))

(defun %acquire-data-lock (root)
  "Best-effort exclusive lock via exclusive create of lock file held open."
  (ensure-directories-exist root)
  (let ((path (merge-pathnames ".harness.lock" root)))
    (handler-case
        (open path :direction :output :if-exists :error :if-does-not-exist :create)
      (file-error ()
        (error 'harness-state-error
               :message "data root is locked by another sm-harness process")))))

(defun open-session-repository (&key root project-key)
  (let* ((root (uiop:ensure-directory-pathname (pathname root)))
         (stream (%acquire-data-lock root))
         (repo (%make-session-repository
                :root root
                :project-key project-key
                :lock-stream stream)))
    (ensure-directories-exist (%repo-project-dir repo))
    (ensure-directories-exist
     (merge-pathnames "sessions/" (%repo-project-dir repo)))
    repo))

(defun close-session-repository (repo)
  (when (session-repository-lock-stream repo)
    (ignore-errors (close (session-repository-lock-stream repo) :abort nil))
    (ignore-errors (delete-file (%repo-lock-path repo)))
    (setf (session-repository-lock-stream repo) nil))
  t)

(defun %plist->json (plist)
  "Convert a property list of keyword keys into a JSON object."
  (let ((o (make-hash-table :test #'equal)))
    (loop for (k v) on plist by #'cddr do
      (when (and k (not (null v)))
        (setf (gethash (string-downcase (symbol-name k)) o)
              (cond
                ((eq v t) t)
                ((or (stringp v) (numberp v) (hash-table-p v)) v)
                ((keywordp v) (string-downcase (symbol-name v)))
                ((symbolp v) (string-downcase (symbol-name v)))
                ((listp v) (if (and v (keywordp (first v)))
                               (%plist->json v)
                               v))
                (t (princ-to-string v))))))
    o))

(defun %entry->json (entry)
  (let ((o (make-hash-table :test #'equal)))
    (setf (gethash "role" o) (transcript-entry-role entry)
          (gethash "text" o) (transcript-entry-text entry)
          (gethash "kind" o) (transcript-entry-kind entry)
          (gethash "created_at" o) (transcript-entry-created-at entry))
    (when (transcript-entry-meta entry)
      (setf (gethash "meta" o)
            (if (and (listp (transcript-entry-meta entry))
                     (keywordp (first (transcript-entry-meta entry))))
                (%plist->json (transcript-entry-meta entry))
                (transcript-entry-meta entry))))
    o))

(defun %json->entry (obj)
  (make-transcript-entry
   :role (or (gethash "role" obj) "user")
   :text (or (gethash "text" obj) "")
   :kind (or (gethash "kind" obj) "message")
   :meta (gethash "meta" obj)
   :created-at (or (gethash "created_at" obj) (%now-iso))))

(defun %record->json (rec)
  (let ((o (make-hash-table :test #'equal)))
    (setf (gethash "id" o) (session-record-id rec)
          (gethash "title" o) (session-record-title rec)
          (gethash "status" o) (string-downcase (symbol-name (session-record-status rec)))
          (gethash "created_at" o) (session-record-created-at rec)
          (gethash "updated_at" o) (session-record-updated-at rec)
          (gethash "sequence" o) (session-record-sequence rec)
          (gethash "transcript" o)
          (mapcar #'%entry->json (session-record-transcript rec)))
    (when (session-record-canonical-id rec)
      (setf (gethash "canonical_id" o) (session-record-canonical-id rec)))
    (when (session-record-draft rec)
      (setf (gethash "draft" o) (session-record-draft rec)))
    o))

(defun %json->status (s)
  (cond
    ((null s) :ready)
    ((string-equal s "ready") :ready)
    ((string-equal s "connecting") :connecting)
    ((string-equal s "responding") :responding)
    ((string-equal s "stopping") :stopping)
    ((string-equal s "error") :error)
    ((string-equal s "disconnected") :disconnected)
    (t :ready)))

(defun %json->record (obj)
  (%make-session-record
   :id (gethash "id" obj)
   :title (or (gethash "title" obj) "New session")
   :status (%json->status (gethash "status" obj))
   :canonical-id (gethash "canonical_id" obj)
   :created-at (or (gethash "created_at" obj) (%now-iso))
   :updated-at (or (gethash "updated_at" obj) (%now-iso))
   :transcript (mapcar #'%json->entry (or (gethash "transcript" obj) '()))
   :draft (gethash "draft" obj)
   :sequence (or (gethash "sequence" obj) 0)))

(defun repository-save-session (repo rec)
  (sb-thread:with-mutex ((session-repository-lock repo))
    (setf (session-record-updated-at rec) (%now-iso))
    (%json-encode-to-file (%repo-session-path repo (session-record-id rec))
                          (%record->json rec))
    (let* ((index (or (%json-decode-file (%repo-index-path repo))
                      (make-hash-table :test #'equal)))
           (sessions (or (gethash "sessions" index) '()))
           (summary (make-hash-table :test #'equal)))
      (setf (gethash "id" summary) (session-record-id rec)
            (gethash "title" summary) (session-record-title rec)
            (gethash "updated_at" summary) (session-record-updated-at rec)
            (gethash "status" summary)
            (string-downcase (symbol-name (session-record-status rec))))
      (when (session-record-canonical-id rec)
        (setf (gethash "canonical_id" summary) (session-record-canonical-id rec)))
      (setf sessions
            (cons summary
                  (remove (session-record-id rec) sessions
                          :key (lambda (s) (gethash "id" s)) :test #'string=)))
      ;; most-recent-first
      (setf sessions
            (sort (copy-list sessions) #'string>
                  :key (lambda (s) (or (gethash "updated_at" s) ""))))
      (setf (gethash "sessions" index) sessions)
      (%json-encode-to-file (%repo-index-path repo) index))
    rec))

(defun repository-load-session (repo session-id)
  (sb-thread:with-mutex ((session-repository-lock repo))
    (let ((obj (%json-decode-file (%repo-session-path repo session-id))))
      (unless obj
        (error 'harness-not-found-error
               :message (format nil "session not found: ~A" session-id)))
      (%json->record obj))))

(defun repository-list-sessions (repo)
  (sb-thread:with-mutex ((session-repository-lock repo))
    (let* ((index (or (%json-decode-file (%repo-index-path repo))
                      (make-hash-table :test #'equal)))
           (sessions (or (gethash "sessions" index) '())))
      (mapcar (lambda (s)
                (make-session-summary
                 :id (gethash "id" s)
                 :title (or (gethash "title" s) "New session")
                 :updated-at (or (gethash "updated_at" s) "")
                 :status (%json->status (gethash "status" s))
                 :canonical-id (gethash "canonical_id" s)))
              sessions))))
