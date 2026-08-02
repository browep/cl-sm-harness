(in-package #:sm-harness-web-ui)

;;;; File browser (#138): a "Browse files" button next to "Upload file" in
;;;; the header, on both the home and chat screens, opening a lazily
;;;; expandable directory tree rooted at +FILE-BROWSER-ROOT+ (presenter.lisp,
;;;; "/" -- the whole container filesystem, widened from this feature's
;;;; first version's narrower /app; see +FILE-BROWSER-ROOT+'s own
;;;; docstring for why that's consistent with this project's stated
;;;; no-sandbox posture). Clicking a file opens it in a new tab via a
;;;; plain target="_blank" anchor -- unlike the upload button's native
;;;; file-chooser (ui/upload.lisp), a new tab needs no synchronous-gesture
;;;; JS trick, so the whole panel (unlike upload.lisp) is built with
;;;; ordinary CLOG:SET-ON-CLICK round trips.
;;;;
;;;; Raw file content itself is served by %SERVE-FS-REQUEST-APP below, a
;;;; LACK middleware wrapped around CLOG's own app chain via
;;;; :LACK-MIDDLEWARE-LIST in APPLICATION.LISP's START-WEB-UI (one CLOG:INITIALIZE
;;;; call, at real process boot only -- see that call site's comment for
;;;; the one-time-only consequence: unlike this project's other CLOG
;;;; routes, this specific piece cannot be picked up by a bare
;;;; RELOAD_HARNESS on an already-running process, only a fresh container
;;;; boot). %SERVE-FS-REQUEST-APP itself, as an ordinary named DEFUN
;;;; rather than a lambda baked directly into that one-time call, stays
;;;; RELOAD_HARNESS-editable even though the middleware chain wrapping it
;;;; is fixed forever -- see its own docstring.
;;;;
;;;; The panel itself is a fixed-position drawer sliding in from the left
;;;; (app.css's .file-browser-panel/.open), not the show/hide-in-place
;;;; pattern .logs-panel/.info-panel use -- see app.css for why: a slide
;;;; transition needs a class toggle, not CLOG:HIDDENP's display:none.
;;;;
;;;; Git diff viewer (#140, follow-up to #138): any directory row that is
;;;; itself a git working-tree root (presenter.lisp's %GIT-REPO-ROOT-P)
;;;; gets a small "Diff" button beside its usual expand/collapse row.
;;;; Clicking it swaps this *same* drawer to a second internal view (the
;;;; TREE div and the new GIT-DIFF-VIEW div below, toggled via HIDDENP)
;;;; rather than opening a whole separate drawer -- there is no single
;;;; "the repo" to hang a dedicated top-level button off of now that
;;;; #138 widened the tree's root from /app to /, so the entry point has
;;;; to come from wherever in the tree a repo actually is. The changed-
;;;; file list itself is click-to-load, not fetched eagerly for every
;;;; rendered repo-root row, the same lazy posture the tree already has
;;;; for directory contents.

(defun %serve-fs-request-app (app)
  "The #138 file-browser's raw-file-serving middleware, wrapping the rest
of CLOG's own APP chain: any request whose path starts with
+FILE-BROWSER-URL-PREFIX+ (presenter.lisp, \"/fs/\") is served straight
from +FILE-BROWSER-ROOT+ (\"/\") via LACK/MIDDLEWARE/STATIC's own,
already-hardened static-file middleware (mime-typing via TRIVIAL-MIMES,
Last-Modified/304 support, and -- importantly -- LACK/APP/FILE's own
rejection of any '..' path component); anything else falls through to
APP unchanged.

Registered once, in APPLICATION.LISP's START-WEB-UI, via CLOG:INITIALIZE's
:LACK-MIDDLEWARE-LIST -- and *only* there: unlike CLOG-CONNECTION:ADD-PLUGIN-PATH
(this feature's first version's mechanism, back when +FILE-BROWSER-ROOT+
was the narrower /app and a file's URL could just be its own absolute
path with no prefix-stripping needed), a LACK middleware chain is folded
together once, permanently, at that one CLOG:INITIALIZE call -- there is
no mutable table a later RELOAD_HARNESS can re-populate the way
%REINSTALL-CLOG-ROUTES (live-reload.lisp) does for ON-NEW-WINDOW/
ON-UPLOAD-WINDOW/the old ADD-PLUGIN-PATH call. Defining the actual
prefix-check-and-serve logic here, as a named function the middleware
wrapper merely calls by symbol rather than a lambda baked directly into
that one-time :LACK-MIDDLEWARE-LIST argument, keeps *this* function's
body RELOAD_HARNESS-editable regardless -- an ordinary call to a named
global function always re-consults its current definition; only a
directly captured function OBJECT (like CLOG:SET-ON-NEW-WINDOW's
argument) goes stale across a reload."
  (funcall lack/middleware/static:*lack-middleware-static* app
           :path +file-browser-url-prefix+
           :root +file-browser-root+))

(defun %file-browser-glyph (kind expanded-p)
  (case kind
    (:directory (if expanded-p "&#9660; &#128193;" "&#9654; &#128193;"))
    (t "&#8203; &#128196;")))

(defun %file-browser-append-message (container text &key (css-class "file-tree-message"))
  (let ((row (clog:create-div container :class css-class)))
    (setf (clog:text row) text)
    row))

(defun %render-directory-listing (container dir on-diff-click)
  "Lists DIR's immediate children (presenter.lisp's %LIST-DIRECTORY) into
CONTAINER, a fresh, currently-empty CLOG div -- called once the first
time a node is expanded (see %BUILD-FILE-TREE-NODE below), never
eagerly/recursively up front. ON-DIFF-CLICK (#140) is threaded through
to every directory node built along the way, unchanged, so any repo
root anywhere in the tree can open the same diff view -- see
INSTALL-FILE-BROWSER-PANEL, the only real caller, for what it does."
  (multiple-value-bind (entries reason-or-truncated-p) (%list-directory dir)
    (cond
      ((eq reason-or-truncated-p :forbidden)
       (%file-browser-append-message container "Not accessible" :css-class "file-tree-error"))
      ((eq reason-or-truncated-p :error)
       (%file-browser-append-message container "Could not read this directory" :css-class "file-tree-error"))
      ((null entries)
       (%file-browser-append-message container "(empty)"))
      (t
       (dolist (entry entries)
         (%build-file-tree-node container entry on-diff-click))
       ;; On success (ENTRIES non-null), the second value is
       ;; %LIST-DIRECTORY's TRUNCATED-P rather than an error keyword.
       (when reason-or-truncated-p
         (%file-browser-append-message
          container
          (format nil "…truncated at ~D entries" +file-browser-max-entries+)))))))

(defun %build-file-tree-node (container entry on-diff-click)
  (let* ((path (getf entry :path))
         (name (getf entry :name))
         (kind (getf entry :kind))
         (node (clog:create-div container :class "file-tree-node")))
    (if (eq kind :directory)
        (let* ((row-wrap (clog:create-div node :class "file-tree-dir-row"))
               (row (clog:create-button row-wrap :class "file-tree-row file-tree-dir"))
               (children nil)
               (expanded nil))
          (setf (clog:inner-html row)
                (format nil "~A ~A" (%file-browser-glyph :directory nil) (escape-text name)))
          (setf (clog:attribute row "aria-expanded") "false")
          (clog:set-on-click row
            (lambda (obj)
              (declare (ignore obj))
              (cond
                ((not expanded)
                 (setf expanded t)
                 (unless children
                   (setf children (clog:create-div node :class "file-tree-children"))
                   (%render-directory-listing children path on-diff-click))
                 (setf (clog:hiddenp children) nil))
                (t
                 (setf expanded nil)
                 (when children (setf (clog:hiddenp children) t))))
              (setf (clog:inner-html row)
                    (format nil "~A ~A" (%file-browser-glyph :directory expanded) (escape-text name)))
              (setf (clog:attribute row "aria-expanded") (if expanded "true" "false"))))
          ;; #140: only a git working-tree root gets a Diff button, and it
          ;; is a plain sibling of ROW (not nested inside it), so clicking
          ;; it never also fires ROW's own expand/collapse handler.
          (when (%git-repo-root-p path)
            (let ((diff-btn (clog:create-button row-wrap :content "Diff"
                                                :class "btn file-tree-diff-btn")))
              (setf (clog:attribute diff-btn "aria-label")
                    (format nil "View git diff for ~A" (namestring path)))
              (clog:set-on-click diff-btn
                (lambda (obj) (declare (ignore obj)) (funcall on-diff-click path))))))
        (let ((link (clog:create-a node :class "file-tree-row file-tree-file"
                                   :link (%fs-href path)
                                   :target "_blank"
                                   :content (format nil "~A ~A" (%file-browser-glyph :file nil) (escape-text name)))))
          (setf (clog:attribute link "rel") "noopener")))
    node))

;;; ---------------------------------------------------------------------
;;; Git diff view (#140)

(defun %git-status-entry-untracked-p (entry)
  (and (char= (getf entry :index-status) #\?)
       (char= (getf entry :worktree-status) #\?)))

(defun %git-status-badge-class (index-status worktree-status)
  "CSS suffix for a changed-file row's status badge -- one of the same
categories %GIT-STATUS-BADGE-TEXT (presenter.lisp) already labels, kept
as a separate, smaller mapping here since app.css needs a stable class
name, not the human label text itself."
  (cond
    ((and (char= index-status #\?) (char= worktree-status #\?)) "untracked")
    ((or (char= index-status #\U) (char= worktree-status #\U)) "conflict")
    ((char= index-status #\R) "renamed")
    ((char= index-status #\C) "copied")
    ((char= index-status #\A) "added")
    ((or (char= index-status #\D) (char= worktree-status #\D)) "deleted")
    ((or (char= index-status #\M) (char= worktree-status #\M)) "modified")
    (t "other")))

(defun %build-git-diff-file-row (container entry on-click)
  "One row in the changed-file list (#140): a status badge (%GIT-STATUS-
BADGE-TEXT/-CLASS, presenter.lisp) plus the path -- and, for a rename,
the original path it was renamed from -- as a single clickable button
that calls ON-CLICK with ENTRY. Every piece of ENTRY's text ultimately
comes from a real filename on disk, so it is ESCAPE-TEXT'd exactly like
any other untrusted content this UI renders."
  (let* ((index-status (getf entry :index-status))
         (worktree-status (getf entry :worktree-status))
         (rename-from (getf entry :rename-from))
         (row (clog:create-button container :class "git-diff-file-row")))
    (setf (clog:inner-html row)
          (format nil "<span class=\"git-diff-badge git-diff-badge-~A\">~A</span> ~A~A"
                  (%git-status-badge-class index-status worktree-status)
                  (escape-text (%git-status-badge-text index-status worktree-status))
                  (escape-text (getf entry :path))
                  (if rename-from
                      (format nil " <span class=\"git-diff-rename-from\">&larr; ~A</span>"
                              (escape-text rename-from))
                      "")))
    (clog:set-on-click row (lambda (obj) (declare (ignore obj)) (funcall on-click entry)))
    row))

(defun %render-git-diff-error (container reason message)
  (%file-browser-append-message
   container
   (case reason
     (:forbidden "Not accessible")
     (t (or message "git reported an error")))
   :css-class "file-tree-error"))

(defun install-file-browser-panel (body header root)
  "Adds the #138 'Browse files' control to HEADER (next to the #127
'Upload file' button, on both the home and chat screens -- see
home.lisp/chat.lisp call sites) and its drawer/backdrop to ROOT. The
tree under +FILE-BROWSER-ROOT+ is only ever listed lazily: the root
listing happens on the *first* open, not at install time, and every
subdirectory only lists its own children the first time it is expanded.

Also wires up the #140 git diff view: a second internal view of this
same PANEL (TREE vs the new git-diff elements below, toggled via
HIDDENP), reached via a directory row's Diff button
(%BUILD-FILE-TREE-NODE) rather than any control installed directly by
this function."
  (declare (ignore body))
  (let* ((btn (clog:create-button header :content "Browse files"
                                  :class "btn" :html-id "browse-files"))
         (backdrop (clog:create-div root :class "file-browser-backdrop"
                                    :html-id "file-browser-backdrop"))
         (panel (clog:create-div root :class "file-browser-panel"
                                 :html-id "file-browser-panel"))
         (panel-header (clog:create-div panel :class "file-browser-panel-header"))
         (title-el (clog:create-section panel-header :h2 :content "/"))
         (close-btn (clog:create-button panel-header :content "Close"
                                        :class "btn" :html-id "file-browser-close"))
         (tree (clog:create-div panel :class "file-tree" :html-id "file-tree"))
         (diff-view (clog:create-div panel :class "git-diff-view" :html-id "git-diff-view"))
         (diff-header (clog:create-div diff-view :class "git-diff-view-header"))
         (diff-back-btn (clog:create-button diff-header :content "&larr; Back to files"
                                            :class "btn" :html-id "git-diff-back"))
         (diff-title (clog:create-span diff-header :class "git-diff-repo-title"))
         (diff-file-list (clog:create-div diff-view :class "git-diff-file-list"
                                          :html-id "git-diff-file-list"))
         (diff-body-wrap (clog:create-div diff-view :class "git-diff-body-wrap"
                                          :html-id "git-diff-body-wrap"))
         (diff-body-back-btn (clog:create-button diff-body-wrap :content "&larr; Back to file list"
                                                 :class "btn" :html-id "git-diff-body-back"))
         (diff-body (clog:create-div diff-body-wrap :class "git-diff-body" :html-id "git-diff-body"))
         (loaded nil))
    (declare (ignore title-el))
    (setf (clog:attribute btn "aria-label") "Browse files under /app"
          (clog:attribute panel "role") "dialog"
          (clog:attribute panel "aria-label") "File browser"
          (clog:attribute tree "role") "tree"
          (clog:attribute backdrop "aria-hidden") "true"
          (clog:hiddenp diff-view) t
          (clog:hiddenp diff-body-wrap) t)
    (labels ((open-panel ()
               (clog:add-class panel "open")
               (clog:add-class backdrop "open")
               (unless loaded
                 (setf loaded t)
                 (%render-directory-listing tree +file-browser-root+ #'open-diff)))
             (close-panel ()
               (clog:remove-class panel "open")
               (clog:remove-class backdrop "open"))
             (show-tree ()
               (clog:remove-class panel "diff-open")
               (setf (clog:hiddenp diff-view) t
                     (clog:hiddenp tree) nil))
             (show-diff-file-list ()
               (setf (clog:hiddenp diff-body-wrap) t
                     (clog:hiddenp diff-file-list) nil))
             (show-diff-body ()
               (setf (clog:hiddenp diff-file-list) t
                     (clog:hiddenp diff-body-wrap) nil))
             (render-diff-body (repo-root entry)
               (setf (clog:inner-html diff-body) "")
               (multiple-value-bind (text reason message)
                   (%git-diff-text repo-root (getf entry :path)
                                   :untracked-p (%git-status-entry-untracked-p entry))
                 (setf (clog:inner-html diff-body)
                       (if reason
                           (format nil "<div class=\"file-tree-error\">~A</div>"
                                   (escape-text (or message "Could not read this diff")))
                           (%git-diff-html text))))
               (show-diff-body))
             (render-diff-file-list (repo-root entries)
               (setf (clog:inner-html diff-file-list) "")
               (if (null entries)
                   (%file-browser-append-message diff-file-list "No changes")
                   (dolist (entry entries)
                     (%build-git-diff-file-row diff-file-list entry
                                               (lambda (e) (render-diff-body repo-root e))))))
             (open-diff (repo-root)
               (clog:add-class panel "diff-open")
               (setf (clog:text diff-title) (namestring repo-root))
               (setf (clog:hiddenp tree) t
                     (clog:hiddenp diff-view) nil)
               (multiple-value-bind (entries reason message) (%git-status-entries repo-root)
                 (setf (clog:inner-html diff-file-list) "")
                 (if reason
                     (%render-git-diff-error diff-file-list reason message)
                     (render-diff-file-list repo-root entries)))
               (show-diff-file-list)))
      (clog:set-on-click btn (lambda (obj) (declare (ignore obj)) (open-panel)))
      (clog:set-on-click close-btn (lambda (obj) (declare (ignore obj)) (close-panel)))
      ;; #138 review answer: click-outside-to-close, via a full-viewport
      ;; backdrop element that sits behind the panel and closes it on click.
      (clog:set-on-click backdrop (lambda (obj) (declare (ignore obj)) (close-panel)))
      (clog:set-on-click diff-back-btn (lambda (obj) (declare (ignore obj)) (show-tree)))
      (clog:set-on-click diff-body-back-btn (lambda (obj) (declare (ignore obj)) (show-diff-file-list))))
    (values btn panel)))
