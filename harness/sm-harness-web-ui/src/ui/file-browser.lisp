(in-package #:sm-harness-web-ui)

;;;; File browser (#138): a "Browse files" button next to "Upload file" in
;;;; the header, on both the home and chat screens, opening a lazily
;;;; expandable directory tree rooted at +FILE-BROWSER-ROOT+ (presenter.lisp,
;;;; "/app/" -- the live bind-mounted app repo, see
;;;; docs/sm-harness-web-ui.md's "Container privileges and the live repo
;;;; mount"). Clicking a file opens it in a new tab via a plain
;;;; target="_blank" anchor -- unlike the upload button's native
;;;; file-chooser (ui/upload.lisp), a new tab needs no synchronous-gesture
;;;; JS trick, so the whole panel (unlike upload.lisp) is built with
;;;; ordinary CLOG:SET-ON-CLICK round trips.
;;;;
;;;; Raw file content itself is served by a plain (CLOG:ADD-PLUGIN-PATH
;;;; "^/app/" "/") registered once in APPLICATION.LISP's START-WEB-UI --
;;;; see that call site's comment for why a file's browser URL is simply
;;;; its own absolute path (%FS-HREF, presenter.lisp) with no separate
;;;; rewriting layer, and why that sidesteps the "RELOAD_HARNESS only
;;;; reloads Lisp" route-reinstall gotcha the /upload route needs
;;;; (docs/sm-harness-web-ui.md).
;;;;
;;;; The panel itself is a fixed-position drawer sliding in from the left
;;;; (app.css's .file-browser-panel/.open), not the show/hide-in-place
;;;; pattern .logs-panel/.info-panel use -- see app.css for why: a slide
;;;; transition needs a class toggle, not CLOG:HIDDENP's display:none.

(defun %file-browser-glyph (kind expanded-p)
  (case kind
    (:directory (if expanded-p "&#9660; &#128193;" "&#9654; &#128193;"))
    (t "&#8203; &#128196;")))

(defun %file-browser-append-message (container text &key (css-class "file-tree-message"))
  (let ((row (clog:create-div container :class css-class)))
    (setf (clog:text row) text)
    row))

(defun %render-directory-listing (body container dir)
  "Lists DIR's immediate children (presenter.lisp's %LIST-DIRECTORY) into
CONTAINER, a fresh, currently-empty CLOG div -- called once the first
time a node is expanded (see %BUILD-FILE-TREE-NODE below), never
eagerly/recursively up front."
  (declare (ignore body))
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
         (%build-file-tree-node container entry))
       ;; On success (ENTRIES non-null), the second value is
       ;; %LIST-DIRECTORY's TRUNCATED-P rather than an error keyword.
       (when reason-or-truncated-p
         (%file-browser-append-message
          container
          (format nil "…truncated at ~D entries" +file-browser-max-entries+)))))))

(defun %build-file-tree-node (container entry)
  (let* ((path (getf entry :path))
         (name (getf entry :name))
         (kind (getf entry :kind))
         (node (clog:create-div container :class "file-tree-node")))
    (if (eq kind :directory)
        (let* ((row (clog:create-button node :class "file-tree-row file-tree-dir"))
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
                   (%render-directory-listing nil children path))
                 (setf (clog:hiddenp children) nil))
                (t
                 (setf expanded nil)
                 (when children (setf (clog:hiddenp children) t))))
              (setf (clog:inner-html row)
                    (format nil "~A ~A" (%file-browser-glyph :directory expanded) (escape-text name)))
              (setf (clog:attribute row "aria-expanded") (if expanded "true" "false")))))
        (let ((link (clog:create-a node :class "file-tree-row file-tree-file"
                                   :link (%fs-href path)
                                   :target "_blank"
                                   :content (format nil "~A ~A" (%file-browser-glyph :file nil) (escape-text name)))))
          (setf (clog:attribute link "rel") "noopener")))
    node))

(defun install-file-browser-panel (body header root)
  "Adds the #138 'Browse files' control to HEADER (next to the #127
'Upload file' button, on both the home and chat screens -- see
home.lisp/chat.lisp call sites) and its drawer/backdrop to ROOT. The
tree under +FILE-BROWSER-ROOT+ is only ever listed lazily: the root
listing happens on the *first* open, not at install time, and every
subdirectory only lists its own children the first time it is expanded."
  (let* ((btn (clog:create-button header :content "Browse files"
                                  :class "btn" :html-id "browse-files"))
         (backdrop (clog:create-div root :class "file-browser-backdrop"
                                    :html-id "file-browser-backdrop"))
         (panel (clog:create-div root :class "file-browser-panel"
                                 :html-id "file-browser-panel"))
         (panel-header (clog:create-div panel :class "file-browser-panel-header"))
         (title-el (clog:create-section panel-header :h2 :content "/app"))
         (close-btn (clog:create-button panel-header :content "Close"
                                        :class "btn" :html-id "file-browser-close"))
         (tree (clog:create-div panel :class "file-tree" :html-id "file-tree"))
         (loaded nil))
    (declare (ignore title-el))
    (setf (clog:attribute btn "aria-label") "Browse files under /app"
          (clog:attribute panel "role") "dialog"
          (clog:attribute panel "aria-label") "File browser"
          (clog:attribute tree "role") "tree"
          (clog:attribute backdrop "aria-hidden") "true")
    (labels ((open-panel ()
               (clog:add-class panel "open")
               (clog:add-class backdrop "open")
               (unless loaded
                 (setf loaded t)
                 (%render-directory-listing body tree +file-browser-root+)))
             (close-panel ()
               (clog:remove-class panel "open")
               (clog:remove-class backdrop "open")))
      (clog:set-on-click btn (lambda (obj) (declare (ignore obj)) (open-panel)))
      (clog:set-on-click close-btn (lambda (obj) (declare (ignore obj)) (close-panel)))
      ;; #138 review answer: click-outside-to-close, via a full-viewport
      ;; backdrop element that sits behind the panel and closes it on click.
      (clog:set-on-click backdrop (lambda (obj) (declare (ignore obj)) (close-panel))))
    (values btn panel)))
