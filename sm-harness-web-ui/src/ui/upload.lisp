(in-package #:sm-harness-web-ui)

;;;; File upload (#127): an "Upload file" button above the chat transcript
;;;; that opens the browser's native file chooser, saves the chosen file to
;;;; durable disk under this harness's own data root, and appends the
;;;; resulting *server-side* filesystem path to the composer -- never
;;;; sending it.
;;;;
;;;; Mechanism: CLOG's own multipart-form support (FORM-MULTIPART-DATA,
;;;; used today only by CLOG's own tutorial, not elsewhere in this
;;;; project) plus the classic hidden-iframe upload trick, so the visible
;;;; tab never navigates: INSTALL-UPLOAD-PANEL builds a hidden
;;;; <form target="upload-target-iframe" enctype="multipart/form-data">
;;;; that posts into a same-origin, hidden, named <iframe>. That iframe
;;;; navigation gets its own ordinary CLOG connection -- ON-UPLOAD-WINDOW,
;;;; registered at the "/upload" CLOG route next to "/sessions" in
;;;; application.lisp/live-reload.lisp -- which saves the file and
;;;; messages the parent window the result via window.postMessage. The
;;;; composer's own 'message' listener (installed once, inline, by
;;;; INSTALL-UPLOAD-PANEL) turns that into a spinner toggle and either an
;;;; appended path or an inline error.
;;;;
;;;; All browser-side glue here is generated via CLOG:JS-EXECUTE rather
;;;; than a new file under static/ -- see docs/sm-harness-web-ui.md,
;;;; "RELOAD_HARNESS only reloads Lisp": a new static/*.js file needs
;;;; re-copying into /opt/app-static (or an image rebuild) before a
;;;; running container actually serves it, where inline JS strings
;;;; compiled into this file are live the instant RELOAD_HARNESS reloads
;;;; it -- same as the session-id-copy and log-export "Copy" buttons
;;;; (chat.lisp, log-export.lisp) already do.

(defconstant +upload-max-bytes+ (* 20 1024 1024)
  "Per-file cap (#127): 20MB. Enforced both client-side -- immediately, no
round trip, see the 'change' handler JS in INSTALL-UPLOAD-PANEL -- and
server-side in %COPY-UPLOAD-STREAM as defence in depth: nothing but this
Lisp process's own generated JS enforces the client-side check, and by
the time ON-UPLOAD-WINDOW even runs, CLOG/lack's own multipart parser
(http-body's MULTIPART-PARSE) has already read the whole body into
memory regardless of this constant -- so the server-side check can only
stop an oversized file from being *written to disk*, not avoid that
memory cost.")

(defun %uploads-project-dir ()
  "web/uploads/ under the harness's data root -- the same PROJECT-KEY
layout %CONNECTION-LOG-PROJECT-DIR (connection-log.lisp) already uses for
index.json/sessions/*.json, so uploads land in the one already-durable
/data volume (#89/#90) rather than a new one."
  (let ((cfg (sm-harness:harness-config *app-harness*)))
    (merge-pathnames (make-pathname :directory '(:relative "uploads"))
                      (%connection-log-project-dir
                       (sm-harness:harness-config-data-root cfg)
                       (sm-harness:harness-config-project-key cfg)))))

(defun %sanitize-path-component (s &key (max-length 200) (default "x"))
  "Filesystem-safe filter for a single path component built from
client-controlled multipart form data (the hidden session-id field and
the uploaded file's own claimed name): keep only alphanumerics, '-', '_',
'.', drop everything else -- notably any slash, so no input can escape
the directory it is placed in -- strip leading dots (blocks both
dotfiles and an all-dots \"..\"-shaped component), and cap length. Falls
back to DEFAULT if nothing survives."
  (let* ((kept (remove-if-not (lambda (c) (or (alphanumericp c) (member c '(#\- #\_ #\.))))
                               (coerce (or s "") 'list)))
         (trimmed (string-left-trim "." (coerce kept 'string)))
         (capped (subseq trimmed 0 (min (length trimmed) max-length))))
    (if (plusp (length capped)) capped default)))

(defun %basename (s)
  "The final path segment of S, tolerating both a forward slash (every
real browser) and a backslash (the old IE full-path quirk some upload
docs still warn about) as separators."
  (let* ((s (or s ""))
         (fwd (position #\/ s :from-end t))
         (bwd (position (code-char 92) s :from-end t))
         (cut (max (or fwd -1) (or bwd -1))))
    (subseq s (1+ cut))))

(defun %upload-session-dir (session-id)
  (merge-pathnames (make-pathname :directory (list :relative (%sanitize-path-component session-id :default "session")))
                    (%uploads-project-dir)))

(defun %upload-target-path (session-id filename)
  "A collision-safe destination path for FILENAME (the uploaded file's own
claimed name, sanitized) under SESSION-ID's own upload directory --
prefixed with the current universal time plus a random suffix so two
uploads landing in the same second never collide."
  (let ((dir (%upload-session-dir session-id))
        (base (%sanitize-path-component (%basename filename) :default "upload")))
    (merge-pathnames (format nil "~D-~6,'0D-~A" (get-universal-time) (random 1000000) base)
                      dir)))

(defun %copy-upload-stream (in out-path)
  "Copy the multipart body stream IN (as CLOG's FORM-MULTIPART-DATA hands
it -- an in-memory octet stream, see clog-form.lisp) to OUT-PATH,
creating its parent directory first. Aborts (deleting the partial file)
and signals once more than +UPLOAD-MAX-BYTES+ has been read. Returns the
number of bytes written."
  (ensure-directories-exist out-path)
  (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8)))
        (total 0))
    (with-open-file (out out-path :element-type '(unsigned-byte 8)
                                   :direction :output :if-exists :supersede
                                   :if-does-not-exist :create)
      (loop
        (let ((n (read-sequence buffer in)))
          (when (zerop n) (return))
          (incf total n)
          (when (> total +upload-max-bytes+)
            (delete-file out-path)
            (error "file exceeds ~D MB limit" (truncate +upload-max-bytes+ (* 1024 1024))))
          (write-sequence buffer out :end n))))
    total))

(defun %post-upload-result (body ok path message)
  "Message BODY's parent window the outcome of one /upload POST -- the
other half of the protocol INSTALL-UPLOAD-PANEL's 'message' listener
implements. Never signals: BODY (the hidden iframe's own CLOG connection)
may already be gone by the time this runs, e.g. a tab closed mid-upload,
and a diagnostic-only postMessage must not turn that into an unhandled
condition."
  (ignore-errors
   (clog:js-execute body
    (format nil "window.parent.postMessage(~A, window.location.origin);"
            (with-output-to-string (s)
              (yason:encode
               (let ((h (make-hash-table :test #'equal)))
                 (setf (gethash "source" h) "sm-harness-upload")
                 (setf (gethash "ok" h) (if ok t yason:false))
                 (when path (setf (gethash "path" h) path))
                 (when message (setf (gethash "message" h) message))
                 h)
               s))))))

(defun on-upload-window (body)
  "CLOG route handler for the hidden-iframe target INSTALL-UPLOAD-PANEL's
form posts into (see this file's header comment for the whole protocol).
Runs once per uploaded file -- CLOG gives this its own fresh
connection/BODY per iframe navigation, same as any other CLOG page."
  (handler-case
      (let* ((data (clog:form-multipart-data body))
             (session-id (clog:form-data-item data "session_id"))
             (file-item (clog:form-data-item data "file")))
        (unwind-protect
             (progn
               (unless (and session-id (plusp (length session-id)))
                 (error "missing session id"))
               (unless (and (consp file-item) (= (length file-item) 3))
                 (error "no file selected"))
               (destructuring-bind (stream filename content-type) file-item
                 (declare (ignore content-type))
                 (when (or (null filename) (zerop (length filename)))
                   (error "no file selected"))
                 (let ((target (%upload-target-path session-id filename)))
                   (%copy-upload-stream stream target)
                   (%post-upload-result body t (namestring target) nil))))
          (clog:delete-multipart-data body)))
    (error (c)
      (%post-upload-result body nil nil (format nil "~A" c)))))

(defun install-upload-panel (body header root session-id)
  "Adds the #127 file-upload control to HEADER (a visible 'Upload file'
button and an inline spinner) and its hidden multipart-upload machinery
to ROOT: a same-origin hidden iframe target and a hidden
<form method=post enctype=multipart/form-data target=<iframe>> holding
SESSION-ID (so the saved file lands under that session's own upload
directory, %UPLOAD-SESSION-DIR) and the :file input the visible button
triggers.

The click-forwarding and 'change'/'message' wiring below is one inline
script (CLOG:JS-EXECUTE), not routed through a CLOG round trip per
event, because a native file-chooser dialog only opens when INPUT.click()
runs synchronously inside the browser's own handler for a real user
gesture -- a CLOG click round trip's response arrives asynchronously,
outside that gesture, and every mainstream browser silently no-ops
INPUT.click() called from there."
  (let* ((btn (clog:create-button header :content "Upload file"
                                  :class "btn" :html-id "upload-file"))
         (spinner (clog:create-span header :class "spinner" :html-id "upload-spinner"))
         (hidden-wrap (clog:create-div root :class "upload-hidden" :html-id "upload-hidden"))
         (form (clog:create-form hidden-wrap :action "/upload" :method :post
                                             :encoding "multipart/form-data"
                                             :target "upload-target-iframe"
                                             :html-id "upload-form"))
         (session-field (clog:create-form-element form :hidden :name "session_id"
                                                   :value session-id
                                                   :html-id "upload-session-id"))
         (file-field (clog:create-form-element form :file :name "file"
                                                :html-id "upload-file-input")))
    (declare (ignore session-field))
    (clog:create-child hidden-wrap
                       "<iframe name='upload-target-iframe' id='upload-target-iframe' title='File upload'></iframe>")
    (setf (clog:hiddenp spinner) t
          (clog:attribute spinner "aria-hidden") "true"
          (clog:attribute spinner "aria-label") "Uploading"
          (clog:attribute btn "aria-label") "Upload file"
          (clog:attribute file-field "aria-label") "Choose file to upload")
    (clog:js-execute body
      (format nil "(function () {~
  var btn = document.getElementById('upload-file');~
  var fileInput = document.getElementById('upload-file-input');~
  var form = document.getElementById('upload-form');~
  var spinner = document.getElementById('upload-spinner');~
  if (!btn || !fileInput || !form) { return; }~
  var MAX = ~D;~
  var NL = String.fromCharCode(10);~
  btn.addEventListener('click', function () { fileInput.click(); });~
  fileInput.addEventListener('change', function () {~
    var errEl = document.getElementById('chat-error');~
    if (!fileInput.files || fileInput.files.length === 0) { return; }~
    var f = fileInput.files[0];~
    if (errEl) { errEl.textContent = ''; }~
    if (f.size > MAX) {~
      if (errEl) { errEl.textContent = 'Upload failed: file exceeds 20MB limit'; }~
      fileInput.value = '';~
      return;~
    }~
    spinner.hidden = false;~
    form.submit();~
  });~
  window.addEventListener('message', function (ev) {~
    if (ev.origin !== window.location.origin) { return; }~
    if (!ev.data || ev.data.source !== 'sm-harness-upload') { return; }~
    var promptEl = document.getElementById('prompt');~
    var errEl = document.getElementById('chat-error');~
    spinner.hidden = true;~
    fileInput.value = '';~
    if (ev.data.ok) {~
      if (promptEl) {~
        var sep = (promptEl.value && promptEl.value.length > 0 && promptEl.value.slice(-1) !== NL) ? NL : '';~
        promptEl.value = promptEl.value + sep + ev.data.path;~
        promptEl.focus();~
      }~
    } else if (errEl) {~
      errEl.textContent = 'Upload failed: ' + ev.data.message;~
    }~
  });~
})();"
              +upload-max-bytes+))
    (values btn spinner form)))
