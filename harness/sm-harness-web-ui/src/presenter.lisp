(in-package #:sm-harness-web-ui)

(defun status-label (status)
  (case status
    (:ready "Ready")
    (:connecting "Connecting")
    (:responding "Responding")
    (:stopping "Stopping")
    (:error "Error")
    (:disconnected "Disconnected")
    (t (princ-to-string status))))

(defun escape-text (text)
  "Text-only rendering: strip angle brackets so content is never HTML."
  (with-output-to-string (out)
    (loop for ch across (or text "") do
      (case ch
        (#\< (write-string "&lt;" out))
        (#\> (write-string "&gt;" out))
        (#\& (write-string "&amp;" out))
        (t (write-char ch out))))))

;;; ---------------------------------------------------------------------
;;; Markdown -> HTML (#71)
;;;
;;; A deliberately small, hand-rolled subset -- no external Markdown
;;; dependency, no support for tables/blockquotes/nested emphasis/raw
;;; HTML passthrough. Every code path starts from ESCAPE-TEXT'd input, so
;;; the only tags this ever emits are the fixed set below; anything that
;;; merely *looks* like Markdown but isn't recognized (or that names a
;;; disallowed link scheme) degrades to plain, already-escaped text
;;; rather than an unrecognized or dangerous tag. This keeps the existing
;;; safe-rendering guarantees (#30) intact: no <script>, no <img>, and no
;;; <a> unless the target is http(s)/mailto.
;;;
;;; Supported: **bold**/__bold__, *italic*/_italic_, `inline code`,
;;; fenced ``` code blocks, # .. ###### headings, "- "/"* " and "1. "
;;; lists, and [text](url) links restricted to http(s)/mailto.

(defun %escape-attr (text)
  "Additional escaping for TEXT (already ESCAPE-TEXT'd) so it is safe to
   drop verbatim inside a double-quoted HTML attribute value."
  (with-output-to-string (out)
    (loop for ch across text do
      (case ch
        (#\" (write-string "&quot;" out))
        (#\' (write-string "&#39;" out))
        (t (write-char ch out))))))

(defparameter +markdown-link-schemes+ '("http://" "https://" "mailto:")
  "Link targets are only ever turned into a real <a> when they start with
   one of these; anything else (javascript:, data:, bare text, ...)
   stays literal so a crafted message can never smuggle a clickable
   script/data URI into the transcript.")

(defun %markdown-allowed-link-target-p (url)
  (some (lambda (scheme)
          (and (>= (length url) (length scheme))
               (string-equal url scheme :end1 (length scheme))))
        +markdown-link-schemes+))

(defun %extract-code-spans (text)
  "Replace each inline `code` span in TEXT with a NUL-delimited
   placeholder immune to every later inline transform, returning
   (values TEXT-WITH-PLACEHOLDERS CODE-BODIES) so the spans can be
   spliced back in verbatim as <code> text at the very end."
  (let ((codes '()))
    (values
     (with-output-to-string (out)
       (let ((i 0) (n (length text)))
         (loop while (< i n) do
           (if (char= (char text i) #\`)
               (let ((end (position #\` text :start (1+ i))))
                 (if end
                     (progn
                       (push (subseq text (1+ i) end) codes)
                       (format out "~C~D~C" #\Nul (1- (length codes)) #\Nul)
                       (setf i (1+ end)))
                     (progn (write-char #\` out) (incf i))))
               (progn (write-char (char text i) out) (incf i))))))
     (nreverse codes))))

(defun %restore-code-spans (text codes)
  (with-output-to-string (out)
    (let ((i 0) (n (length text)))
      (loop while (< i n) do
        (if (char= (char text i) #\Nul)
            (let ((end (position #\Nul text :start (1+ i))))
              (format out "<code>~A</code>"
                      (nth (parse-integer text :start (1+ i) :end end) codes))
              (setf i (1+ end)))
            (progn (write-char (char text i) out) (incf i)))))))

(defun %try-markdown-link (text i)
  "If a [label](url) construct starts at index I in TEXT, return
   (values REPLACEMENT-HTML NEXT-INDEX); otherwise NIL."
  (when (and (< i (length text)) (char= (char text i) #\[))
    (let ((close-bracket (position #\] text :start i)))
      (when (and close-bracket
                 (< (1+ close-bracket) (length text))
                 (char= (char text (1+ close-bracket)) #\())
        (let ((close-paren (position #\) text :start (+ close-bracket 2))))
          (when close-paren
            (let* ((label (subseq text (1+ i) close-bracket))
                   (url (subseq text (+ close-bracket 2) close-paren)))
              (values
               (if (%markdown-allowed-link-target-p url)
                   (format nil "<a href=\"~A\" target=\"_blank\" rel=\"noopener noreferrer\">~A</a>"
                           (%escape-attr url) label)
                   (format nil "[~A](~A)" label url))
               (1+ close-paren)))))))))

(defun %markdown-links (text)
  (with-output-to-string (out)
    (let ((i 0) (n (length text)))
      (loop while (< i n) do
        (multiple-value-bind (replacement next) (%try-markdown-link text i)
          (if replacement
              (progn (write-string replacement out) (setf i next))
              (progn (write-char (char text i) out) (incf i))))))))

(defun %replace-paired (text open close tag)
  "Replace non-overlapping OPEN...CLOSE delimited spans in TEXT with
   <TAG>...</TAG>. An OPEN with no matching CLOSE, or an empty span, is
   left untouched."
  (with-output-to-string (out)
    (let ((i 0) (n (length text)) (ol (length open)) (cl (length close)))
      (loop while (< i n) do
        (if (and (<= (+ i ol) n) (string= text open :start1 i :end1 (+ i ol)))
            (let ((end (search close text :start2 (+ i ol))))
              (if (and end (> end (+ i ol)))
                  (progn
                    (format out "<~A>~A</~A>" tag (subseq text (+ i ol) end) tag)
                    (setf i (+ end cl)))
                  (progn (write-string open out) (incf i ol))))
            (progn (write-char (char text i) out) (incf i)))))))

(defun %markdown-inline (text)
  "Apply the supported inline subset to one already-ESCAPE-TEXT'd chunk:
   inline code first (protecting its contents from everything else),
   then scheme-checked links, then bold, then italic."
  (multiple-value-bind (masked codes) (%extract-code-spans text)
    (let* ((s (%markdown-links masked))
           (s (%replace-paired s "**" "**" "strong"))
           (s (%replace-paired s "__" "__" "strong"))
           (s (%replace-paired s "*" "*" "em"))
           (s (%replace-paired s "_" "_" "em")))
      (%restore-code-spans s codes))))

(defun %split-lines (text)
  (let ((lines '()) (start 0) (n (length text)))
    (loop
      (let ((nl (position #\Newline text :start start)))
        (if nl
            (progn (push (subseq text start nl) lines) (setf start (1+ nl)))
            (progn (push (subseq text start n) lines) (return)))))
    (nreverse lines)))

(defun %markdown-heading (line)
  "If LINE is a '#'..'######' heading, return (values LEVEL REST-TEXT)."
  (let ((i 0) (n (length line)))
    (loop while (and (< i n) (< i 6) (char= (char line i) #\#)) do (incf i))
    (when (and (> i 0) (< i n) (char= (char line i) #\Space))
      (values i (string-left-trim " " (subseq line i))))))

(defun %markdown-unordered-item (line)
  (when (and (>= (length line) 2)
             (member (char line 0) '(#\- #\*))
             (char= (char line 1) #\Space))
    (string-left-trim " " (subseq line 2)))) 

(defun %markdown-ordered-item (line)
  (let ((dot (position #\. line)))
    (when (and dot (plusp dot)
               (every #'digit-char-p (subseq line 0 dot))
               (> (length line) (1+ dot))
               (char= (char line (1+ dot)) #\Space))
      (string-left-trim " " (subseq line (+ dot 2))))))

(defun markdown-to-html (raw-text)
  "Render a conservative, safe subset of Markdown in RAW-TEXT as HTML.
   Always starts by ESCAPE-TEXT'ing the whole input, so nothing this
   function does not explicitly recognize can ever become a live tag."
  (let ((lines (%split-lines (escape-text (or raw-text ""))))
        (out (make-string-output-stream))
        (in-fence nil)
        (fence-lines '())
        (list-tag nil)
        (para-lines '()))
    (labels ((flush-para ()
               ;; Join with a literal newline, not <br>: the transcript box
               ;; is white-space: pre-wrap, so it renders the same, while
               ;; the element's text keeps the whitespace the raw message
               ;; had (a <br> contributes no text content, fusing adjacent
               ;; words for selection/copy and text-based assertions).
               (when para-lines
                 (format out "<p>~{~A~^~%~}</p>"
                         (mapcar #'%markdown-inline (nreverse para-lines)))
                 (setf para-lines nil)))
             (close-list ()
               (when list-tag
                 (format out "</~A>" list-tag)
                 (setf list-tag nil)))
             (close-fence ()
               (when in-fence
                 (format out "<pre><code>~{~A~^~%~}</code></pre>" (nreverse fence-lines))
                 (setf in-fence nil fence-lines nil))))
      (dolist (line lines)
        (let ((trimmed (string-trim " " line)))
          (cond
            ((and (>= (length trimmed) 3) (string= "```" trimmed :end2 3))
             (flush-para) (close-list)
             (if in-fence (close-fence) (setf in-fence t fence-lines nil)))
            (in-fence (push line fence-lines))
            ((zerop (length trimmed))
             (flush-para) (close-list))
            (t
             (multiple-value-bind (level rest) (%markdown-heading trimmed)
               (cond
                 (level
                  (flush-para) (close-list)
                  (format out "<h~D>~A</h~D>" level (%markdown-inline rest) level))
                 ((%markdown-unordered-item trimmed)
                  (flush-para)
                  (unless (equal list-tag "ul")
                    (close-list) (format out "<ul>") (setf list-tag "ul"))
                  (format out "<li>~A</li>"
                          (%markdown-inline (%markdown-unordered-item trimmed))))
                 ((%markdown-ordered-item trimmed)
                  (flush-para)
                  (unless (equal list-tag "ol")
                    (close-list) (format out "<ol>") (setf list-tag "ol"))
                  (format out "<li>~A</li>"
                          (%markdown-inline (%markdown-ordered-item trimmed))))
                 (t
                  (close-list)
                  (push line para-lines))))))))
      (close-fence) (flush-para) (close-list)
      (get-output-stream-string out))))

(defun %humanize-payload-key (key)
  "Turn a payload plist key such as :RATE-LIMIT-TYPE into \"rate limit type\"
   for human-readable chip text."
  (substitute #\Space #\- (string-downcase (symbol-name key))))

(defun %format-payload-fields (payload &key exclude)
  "Render PAYLOAD (an event plist) as a comma-separated \"key: value\" list,
   skipping any key in EXCLUDE and any key whose value is NIL/empty. Used
   both by the dedicated :SYSTEM/:RATE-LIMIT/:UNRECOGNIZED chips below and by
   the final catch-all, so a genuinely new event type still shows its real
   payload instead of just its type name (#102)."
  (let ((parts '()))
    (loop for (k v) on payload by #'cddr
          unless (or (member k exclude)
                     (null v)
                     (and (stringp v) (zerop (length v))))
          do (push (format nil "~A: ~A" (%humanize-payload-key k) v) parts))
    (format nil "~{~A~^, ~}" (nreverse parts))))

(defun %log-presenter-fallback (ev)
  "#102: EVENT-DISPLAY's catch-all is meant to be a safety net, not the
   normal path for any event type this UI actually expects to see. Every
   time it fires, warn (SBCL prints unhandled WARN conditions to
   *error-output*, i.e. this container's stdout, with no extra plumbing
   needed) so an operator grepping logs can tell 'the presenter has no
   dedicated rendering for this event type' apart from ordinary traffic,
   instead of that gap being silently invisible."
  (warn "sm-harness-web-ui presenter: no dedicated rendering for event type ~A (session ~A, sequence ~A) -- falling back to a generic payload dump; see issue #102"
        (sm-harness:event-type ev)
        (sm-harness:event-session-id ev)
        (sm-harness:event-sequence ev)))

(defun event-display (ev)
  (let ((type (sm-harness:event-type ev))
        (payload (sm-harness:event-payload ev)))
    (case type
      (:assistant-text
       (cons "assistant" (markdown-to-html (getf payload :text))))
      (:user-message
       ;; A harness-initiated synthetic follow-up (#76) must never render
       ;; indistinguishably from something the human actually typed.
       (cons (if (getf payload :synthetic) "harness" "user")
             (escape-text (getf payload :text))))
      (:tool-requested
       (cons "tool" (escape-text (format nil "Tool requested: ~A" (getf payload :name)))))
      (:tool-completed
       (cons "tool"
             (escape-text (format nil "Tool completed: ~A" (getf payload :content)))))
      (:tool-failed
       (cons "tool" "Tool failed"))
      (:terminal
       (cons "result" (escape-text (or (getf payload :text) ""))))
      (:error
       (cons "error" (escape-text (or (getf payload :message) "error"))))
      (:status
       (cons "status" (status-label (getf payload :status))))
      (:title
       ;; #129: SET-SESSION-TITLE's live rename notification. Deliberately
       ;; NOT ESCAPE-TEXTd, unlike every case above whose result is consumed
       ;; via ADD-LINE's INNER-HTML: chat.lisp handles :TITLE by assigning
       ;; this straight to a CLOG:TEXT property (DOM textContent, same as
       ;; STATUS-EL/CANON-EL above), which needs no pre-escaping and would
       ;; double-encode (a literal "&amp;" shown to the user) if it got
       ;; ESCAPE-TEXTd here first.
       (cons "title" (getf payload :title)))
      (:system
       ;; #102: the CLI's own system messages (subtype "init" at
       ;; session/turn start, possibly "compact_boundary") and the
       ;; synthetic "thinking" subtype the adapter emits per omitted
       ;; extended-thinking block (sm-harness/src/sdk-adapter.lisp) both
       ;; used to render as a bare, contentless "SYSTEM" chip.
       (let ((subtype (getf payload :subtype)))
         (cons "system"
               (escape-text
                (cond
                  ((equal subtype "thinking") "Thinking (details omitted)")
                  (subtype
                   (let ((extra (%format-payload-fields payload :exclude '(:subtype))))
                     (if (plusp (length extra))
                         (format nil "System: ~A (~A)" subtype extra)
                         (format nil "System: ~A" subtype))))
                  (t (let ((extra (%format-payload-fields payload)))
                       (if (plusp (length extra)) (format nil "System (~A)" extra) "System"))))))))
      (:rate-limit
       ;; #102: sm-harness/src/sdk-adapter.lisp used to drop the CLI's
       ;; rate_limit_info entirely before it ever reached here, so even a
       ;; fixed chip had nothing real to show; that payload now carries the
       ;; actual fields.
       (cons "system" (escape-text (format nil "Rate limit: ~A" (%format-payload-fields payload)))))
      (:unrecognized
       (cons "system"
             (escape-text (format nil "Unrecognized event: ~A" (or (getf payload :class) "?")))))
      (t
       (%log-presenter-fallback ev)
       (let ((extra (%format-payload-fields payload)))
         (cons "system"
               (escape-text
                (if (plusp (length extra))
                    (format nil "~A (~A)" (princ-to-string type) extra)
                    (princ-to-string type)))))))))

;;; ---------------------------------------------------------------------
;;; Session backend/model display (#106)

(defun %backend-label (backend-id)
  "Display label for a stored backend id: the catalog's own label when the
id is still recognized, else the raw id (a value predating a later catalog
change, however unlikely with today's single-backend catalog, should still
render something rather than blow up)."
  (let ((b (sm-harness:find-backend backend-id)))
    (if b (sm-harness:backend-descriptor-label b) backend-id)))

(defun %model-label (backend-id model-id)
  "Display label for a stored model id, or \"Default\" when the session
carries no explicit override (#106): MODEL-ID is NIL exactly when the
session was created before this feature, or created without picking a
model, and in both cases HARNESS-CONFIG-MODEL/the CLI's own default governs
instead of any value this panel could show."
  (cond
    ((null model-id) "Default")
    (t (let ((m (sm-harness:find-model backend-id model-id)))
         (if m (sm-harness:model-descriptor-label m) model-id)))))

;;; ---------------------------------------------------------------------
;;; Home-screen chip metadata (#111)

(defun %parse-iso8601z (s)
  "Parse the fixed \"YYYY-MM-DDTHH:MM:SSZ\" shape SM-HARNESS::%NOW-ISO
always produces (the only timestamp format this codebase ever writes to
CREATED-AT/UPDATED-AT) into a universal time. NIL on anything that isn't
that exact shape -- a summary predating this field, or any future format
change -- rather than signaling, since a chip missing its elapsed time is
far preferable to one that crashes the whole home screen."
  (and (stringp s) (>= (length s) 20)
       (ignore-errors
        (encode-universal-time
         (parse-integer s :start 17 :end 19)
         (parse-integer s :start 14 :end 16)
         (parse-integer s :start 11 :end 13)
         (parse-integer s :start 8 :end 10)
         (parse-integer s :start 5 :end 7)
         (parse-integer s :start 0 :end 4)
         0))))

(defun %format-elapsed (iso &key (now (get-universal-time)))
  "Human \"time since\" label for ISO (an SM-HARNESS::%NOW-ISO-shaped
timestamp) relative to NOW (a universal time, overridable for tests).
Renders \"unknown\" for NIL/unparseable input -- a session summary from
before #111 added CREATED-AT -- and never a negative duration: a small
clock skew that makes ISO look slightly in the future clamps to \"just
now\" instead of printing something like \"-3s ago\"."
  (let ((then (%parse-iso8601z iso)))
    (if (null then)
        "unknown"
        (let ((delta (max 0 (- now then))))
          (cond
            ((< delta 60) "just now")
            ((< delta 3600) (format nil "~Dm ago" (floor delta 60)))
            ((< delta 86400) (format nil "~Dh ago" (floor delta 3600)))
            (t (format nil "~Dd ago" (floor delta 86400))))))))

(defun %turn-count-label (n)
  "Pluralizes the home-screen chip's turn count (#111): N is always a
non-negative integer (SM-HARNESS::%SESSION-TURN-COUNT/repository default
of 0), never NIL, so this never needs its own missing-value case."
  (format nil "~D turn~:P" (or n 0)))

(defun %status-slug (status)
  "CSS-safe modifier class fragment for STATUS (a SESSION-SUMMARY-STATUS
keyword such as :READY/:RESPONDING/:ERROR): lowercase, no colon."
  (string-downcase (symbol-name status)))

(defun %session-chip-html (summary)
  "Inner HTML for a home-screen session chip (#111) built from SUMMARY (a
SM-HARNESS:SESSION-SUMMARY): title/status on their own line, then a row of
meta chips -- session id, backend, model, turn count, time since the
session started, and canonical provider id (or \"Pending…\" before the CLI
has assigned one, same fallback the pre-#111 chip already used). Kept
here, not in ui/home.lisp, for the same reason as EVENT-DISPLAY/
%BACKEND-LABEL/%MODEL-LABEL above: so it gets PRESENTER-TESTS coverage
without needing a live CLOG server. Every field is ESCAPE-TEXT'd before
insertion -- title and canonical id ultimately come from outside this
process (a future editable title, the CLI's own session id), so neither
gets a free pass just because nothing edits titles yet."
  (let* ((status (sm-harness:session-summary-status summary))
         (backend (sm-harness:session-summary-backend summary))
         (model (sm-harness:session-summary-model summary)))
    (format nil
            "<span class=\"chip-top\"><span class=\"chip-title\">~A</span><span class=\"chip-status status-chip status-~A\">~A</span></span><span class=\"chip-meta\"><span class=\"chip-item chip-id\">~A</span><span class=\"chip-item chip-backend\">~A</span><span class=\"chip-item chip-model\">~A</span><span class=\"chip-item chip-turns\">~A</span><span class=\"chip-item chip-elapsed\">~A</span><span class=\"chip-item chip-canonical\">~A</span></span>"
            (escape-text (sm-harness:session-summary-title summary))
            (%status-slug status)
            (escape-text (status-label status))
            (escape-text (sm-harness:session-summary-id summary))
            (escape-text (%backend-label backend))
            (escape-text (%model-label backend model))
            (escape-text (%turn-count-label (sm-harness:session-summary-turn-count summary)))
            (escape-text (%format-elapsed (sm-harness:session-summary-created-at summary)))
            (escape-text (or (sm-harness:session-summary-canonical-id summary)
                             "Pending…")))))

;;; ---------------------------------------------------------------------
;;; Cache-busting the stylesheet URL

(defun %app-css-href ()
  "URL ON-NEW-WINDOW (application.lisp) hands to CLOG:LOAD-CSS. Found
necessary chasing a real incident: a plain, unversioned \"/app.css\" never
changes across a static-asset edit, and the response carries no
Cache-Control/Expires header (only Last-Modified) -- see
docs/sm-harness-web-ui.md's static-asset-staleness note -- so a browser's
own HTTP cache can go on serving a stale copy indefinitely, even across a
hard-looking page reload, once it has fetched it once. Appending the
actually-served app.css file's own write-date as a query string changes
the URL the instant that file's content changes on disk, independent of
whether the Lisp process was ever restarted (the exact case that bit us:
/opt/app-static was re-copied without a restart). *WEB-UI-CONFIG* unset
(headless/test contexts) or the file being unreadable both degrade to the
plain, unversioned URL rather than erroring -- a same-content re-fetch is
harmless, just not maximally cache-friendly."
  (let* ((root (and *web-ui-config* (web-ui-config-static-root *web-ui-config*)))
         (write-date (and root
                          (ignore-errors
                           (file-write-date (merge-pathnames "app.css" root))))))
    (if write-date
        (format nil "/app.css?v=~A" write-date)
        "/app.css")))

;;; ---------------------------------------------------------------------
;;; File browser (#138): pure directory-listing/path logic, kept here
;;; (not in ui/file-browser.lisp, which is CLOG glue only) for the same
;;; reason as EVENT-DISPLAY/%SESSION-CHIP-HTML above -- so it gets
;;; PRESENTER-TESTS coverage without a live CLOG server.

(defparameter +file-browser-root+ #P"/"
  "The file browser is rooted here (#138): the whole container
filesystem, not just the live bind-mounted app repository under /app
-- a deliberate widening from this feature's first version, matching
this project's already-stated no-sandbox posture (docs/sm-harness-web-ui.md,
\"Container privileges and the live repo mount\": the container/tailnet
boundary is the isolation layer, nothing inside it is). This is also the
root %SERVE-FS-REQUEST-APP (ui/file-browser.lisp) serves a clicked file's
raw content from, so a listing built from this root and a URL built from
%FS-HREF below always agree.")

(defparameter +file-browser-url-prefix+ "/fs/"
  "The URL namespace a file's browser href (%FS-HREF below) lives under,
and the prefix %SERVE-FS-REQUEST-APP (ui/file-browser.lisp) strips before
resolving a request against +FILE-BROWSER-ROOT+. Needed -- and not just
\"a file's URL is its own absolute path\", this feature's first version's
simpler approach when +FILE-BROWSER-ROOT+ was /app -- specifically
*because* +FILE-BROWSER-ROOT+ is now /: reserved single-path-segment
names this app itself already serves at the true filesystem root
(/app.css, /log-capture.js, /e2e-contract.json, CLOG's own /js/boot.js,
...) would otherwise collide with a real absolute path of the same name,
and, more importantly, CLOG's own registered routes (/, /sessions,
/upload) take dispatch priority over any plugin/middleware match
regardless, but nothing already reserves a distinct \"/fs/\" segment, so
prefixing here is what keeps every real file -- including one that
happens to be named exactly like a reserved asset -- reachable.")

(defparameter +file-browser-max-entries+ 2000
  "Cap (#138) on how many entries a single %LIST-DIRECTORY call will ever
return, so an enormous directory under /app (checked-in node_modules,
build output, ...) can't stall the browser tab building thousands of DOM
rows in one lazy-expand click. Entries beyond this are silently dropped;
the CLOG glue surfaces a \"truncated\" row instead of pretending the
directory just happens to have exactly this many entries.")

(defun %path-under-root-p (path root)
  "Defense in depth (#138), independent of %SERVE-FS-REQUEST-APP's own
+FILE-BROWSER-URL-PREFIX+ scoping on the serving side (ui/file-browser.lisp)
and LACK/APP/FILE's own '..'-component rejection. Never trusts a
caller-supplied PATH on its own, the same posture as upload.lisp's
%SANITIZE-PATH-COMPONENT comment about not relying on a single layer.
Effectively a no-op now that +FILE-BROWSER-ROOT+ is / (every absolute
path is \"under\" /) -- kept anyway as the same defense-in-depth layer,
and it still does real work for any caller passing a narrower ROOT
(PRESENTER-TESTS, e.g., always does).

Two checks, not one: PATH's plain (unresolved) namestring must start
with ROOT's own TRUENAME textually -- this is the check that still works
for a PATH that doesn't exist yet/anymore (e.g. %LIST-DIRECTORY called
on a directory that vanished between being listed and being expanded;
%LIST-DIRECTORY-SURFACES-A-MISSING-DIRECTORY-AS-ERROR below depends on
this staying a :FORBIDDEN-vs-:ERROR distinction, not both collapsing to
the same outcome) -- and, only when PATH does exist, its TRUENAME must
*also* start with ROOT's TRUENAME, so a symlink actually pointing outside
ROOT is caught even though it textually appeared to be inside it."
  (handler-case
      (let* ((true-root (namestring (truename root)))
             (text-path (namestring path)))
        (and (>= (length text-path) (length true-root))
             (string= true-root text-path :end2 (length true-root))
             (or (not (probe-file path))
                 (let ((true-path (namestring (truename path))))
                   (and (>= (length true-path) (length true-root))
                        (string= true-root true-path :end2 (length true-root)))))))
    (error () nil)))

(defun %fs-entry-kind (path)
  (if (uiop:directory-pathname-p path) :directory :file))

(defun %fs-sort-key (path)
  "Display name for PATH -- the last directory component for a directory
pathname, or NAME(.TYPE) for a file -- also used directly as the sort
key: CL's STRING-LESSP is already case-insensitive, so no separate
downcasing is needed (and downcasing here would have leaked into the
displayed name if it had been applied)."
  (if (uiop:directory-pathname-p path)
      (or (car (last (pathname-directory path))) "")
      (let ((name (or (pathname-name path) ""))
            (type (pathname-type path)))
        (if type (format nil "~A.~A" name type) name))))

(defun %list-directory (dir &key (root +file-browser-root+) (limit +file-browser-max-entries+))
  "List DIR's immediate children (#138), directories before files,
case-insensitive alphabetical within each group, dotfiles/dotdirs
included with no filtering (#138 review comment: this project's stated
no-sandbox posture -- docs/sm-harness-web-ui.md, \"Container privileges
and the live repo mount\" -- already treats /app as fully visible to the
agent; this is that same visibility, just browsable).

Returns (VALUES ENTRIES TRUNCATED-P) on success, where each entry is a
plist (:NAME :KIND (:DIRECTORY or :FILE) :PATH). Returns (VALUES NIL
:FORBIDDEN) if DIR does not resolve under ROOT (%PATH-UNDER-ROOT-P) and
(VALUES NIL :ERROR) if DIR can't be read (permission error, or it
vanished between being listed and being expanded) -- callers must not
let a directory-listing failure take down the rest of an already-open
tree."
  (cond
    ((not (%path-under-root-p dir root))
     (values nil :forbidden))
    ((not (uiop:directory-exists-p dir))
     ;; DIRECTORY/UIOP:SUBDIRECTORIES silently returns an empty list for a
     ;; nonexistent directory in SBCL rather than signaling -- found
     ;; writing this function's own test coverage -- so a vanished/never-
     ;; existed DIR must be checked explicitly, or it would be
     ;; indistinguishable from a directory that genuinely has zero
     ;; entries.
     (values nil :error))
    (t
     (handler-case
          (let* ((dirs (uiop:subdirectories dir))
                 (files (uiop:directory-files dir))
                 (sorted-dirs (sort (copy-list dirs) #'string-lessp :key #'%fs-sort-key))
                 (sorted-files (sort (copy-list files) #'string-lessp :key #'%fs-sort-key))
                 (all (append sorted-dirs sorted-files))
                 (truncated (> (length all) limit))
                 (kept (if truncated (subseq all 0 limit) all)))
            (values (mapcar (lambda (p)
                              (list :name (%fs-sort-key p) :kind (%fs-entry-kind p) :path p))
                            kept)
                    truncated))
        (error () (values nil :error))))))

(defun %fs-unreserved-byte-p (byte)
  "True for an octet in RFC 3986's unreserved set (ALPHA / DIGIT / '-'
'.' '_' '~'), checked as raw byte *ranges* rather than via a CL character
predicate on (CODE-CHAR BYTE) -- deliberately, since a UTF-8 continuation
byte (128-255) run through CODE-CHAR lands on Latin-1 code points, and
ALPHANUMERICP is true for several of those (e.g. accented letters),
which would have let a multi-byte UTF-8 sequence's continuation bytes
escape percent-encoding and corrupt the resulting URL."
  (or (<= 48 byte 57)   ; 0-9
      (<= 65 byte 90)   ; A-Z
      (<= 97 byte 122)  ; a-z
      (member byte '(45 46 95 126)))) ; - . _ ~

(defun %fs-url-encode-component (name)
  "Percent-encode NAME (a single path component -- never containing '/')
for safe use in an href, by hand rather than pulling in a new dependency
(same preference already stated for Markdown rendering above): every
octet outside RFC 3986's unreserved set becomes %XX, operating on NAME's
UTF-8 encoding so non-ASCII names survive too -- see
%FS-UNRESERVED-BYTE-P for why this checks raw bytes, not characters."
  (with-output-to-string (out)
    (loop for byte across (sb-ext:string-to-octets name :external-format :utf-8) do
      (if (%fs-unreserved-byte-p byte)
          (write-char (code-char byte) out)
          (format out "%~2,'0X" byte)))))

(defun %fs-rel-components (path)
  "PATH's path components below the filesystem root -- e.g.
#P\"/app/harness/docs/sm-harness.md\" -> (\"app\" \"harness\" \"docs\"
\"sm-harness.md\") -- used by %FS-HREF below. Resolves PATH's TRUENAME
first so a symlink component can't produce a mismatched URL."
  (let* ((true-path (truename path))
         (dirs (rest (pathname-directory true-path)))
         (name (pathname-name true-path))
         (type (pathname-type true-path)))
    (if (and name (not (uiop:directory-pathname-p true-path)))
        (append dirs (list (if type (format nil "~A.~A" name type) name)))
        dirs)))

(defun %fs-href (path)
  "The browser URL for PATH (a file or directory under
+FILE-BROWSER-ROOT+ -- the whole filesystem), built as
+FILE-BROWSER-URL-PREFIX+ followed by PATH's own absolute path with each
component percent-encoded. %SERVE-FS-REQUEST-APP (ui/file-browser.lisp)
strips that exact prefix back off before resolving the rest against
+FILE-BROWSER-ROOT+, so the two always agree -- see +FILE-BROWSER-URL-PREFIX+'s
own docstring above for why a prefix is needed at all now that the root
is / rather than the narrower /app this feature originally shipped with."
  (format nil "~A~{~A~^/~}" +file-browser-url-prefix+
          (mapcar #'%fs-url-encode-component (%fs-rel-components path))))

;;; ---------------------------------------------------------------------
;;; Git diff viewer (#140, follow-up to #138's file browser): pure
;;; git-plumbing/parsing logic, kept here for the same PRESENTER-TESTS-
;;; without-a-live-CLOG-server reason as the file browser section above.
;;; ui/file-browser.lisp adds the CLOG glue: a "Diff" affordance on any
;;; directory row that is itself a git working-tree root, reusing the
;;; existing .file-browser-panel drawer (a second internal view, toggled
;;; via HIDDENP, rather than a whole new drawer) instead of a dedicated
;;; top-level button -- there is no single "the repo" to default such a
;;; button to now that #138 widened the tree's root from /app to /.
;;;
;;; Scope (v1, #140): the working tree's own uncommitted changes only
;;; (`git diff HEAD`, which folds staged and unstaged changes into one
;;; diff), no arbitrary ref/commit picker.

(defparameter +git-diff-timeout-seconds+ 10
  "Bound on a single `git status`/`git diff` child process (#140), so a
pathological repo (a corrupt .git, a diff/status hook that hangs, an
enormous rename-detection search) can't wedge the UI thread that called
%RUN-GIT forever -- the same posture as the bash tool's own timeout
(tool-catalog.lisp), just far shorter: this always runs a fixed, cheap
plumbing command, never arbitrary user input.")

(defparameter +git-diff-max-chars+ 200000
  "Cap (#140) on how much stdout a single %RUN-GIT call will ever return,
so an enormous diff (a checked-in binary asset, a huge generated file)
can't stall the browser tab rendering hundreds of thousands of DOM
lines in one click -- same UX as +FILE-BROWSER-MAX-ENTRIES+'s truncated
directory listing.")

(defun %git-repo-root-p (dir)
  "True when DIR (a directory pathname) is a git working-tree root -- has
an immediate .git entry, whether that's an ordinary repo's .git
directory or the single-line .git FILE a submodule/linked-worktree
checkout uses instead. Deliberately shallow (just this one entry, not a
full `git rev-parse --is-inside-work-tree` round trip) so it's cheap
enough to call once per rendered directory row in the file tree (#138)
without spawning a process for every row."
  (let ((git-path (merge-pathnames ".git" (uiop:ensure-directory-pathname dir))))
    (or (uiop:directory-exists-p git-path) (uiop:file-exists-p git-path))))

(defun %git-read-stream-capped (stream max-chars)
  "Local, trimmed copy of sm-harness/src/tool-catalog.lisp's
%READ-STREAM-CAPPED (not reused directly across the package/system
boundary: that symbol is internal to a different ASDF system and this
call site never needs its process-group-kill machinery, only the plain
capped read) -- returns (values text truncated-p)."
  (if (<= max-chars 0)
      (values "" (not (null (read-char stream nil nil))))
      (let* ((buf (make-string max-chars))
             (n (read-sequence buf stream)))
        (values (subseq buf 0 n)
                (and (= n max-chars) (not (null (read-char stream nil nil))))))))

(defun %run-git (repo-root argv &key (timeout-seconds +git-diff-timeout-seconds+)
                                      (max-chars +git-diff-max-chars+))
  "Run git ARGV (a list of plain string arguments, e.g. (\"status\"
\"--porcelain=v1\") -- never a shell string) with REPO-ROOT as its
working directory. Returns (values stdout stderr exit-code timed-out-p).
stdout is capped at MAX-CHARS the same way the bash tool's own output is
(tool-catalog.lisp); a run that outlives TIMEOUT-SECONDS is killed
(SIGTERM, then SIGKILL after a short grace period if still alive) rather
than left to wedge the caller -- git spawns no grandchildren for a plain
`diff`/`status`, so unlike the bash tool's process-group kill this only
ever needs to signal the one child. ARGV going straight to RUN-PROGRAM
as separate arguments (not interpolated into a command string) means a
crafted pathspec/filename can never be parsed as a flag or escape into a
wider command line -- deliberately stronger than the bash tool's own
posture, which is fine there only because that tool's whole point is
running an arbitrary caller-chosen command."
  (let* ((process (sb-ext:run-program "git" argv :directory repo-root :search t
                                       :output :stream :error :stream :wait nil))
         (stdout-text nil) (stdout-truncated nil)
         (stderr-text nil) (stderr-truncated nil)
         (stdout-reader (sb-thread:make-thread
                          (lambda ()
                            (multiple-value-setq (stdout-text stdout-truncated)
                              (%git-read-stream-capped (sb-ext:process-output process) max-chars)))
                          :name "git-diff-stdout-reader"))
         (stderr-reader (sb-thread:make-thread
                          (lambda ()
                            (multiple-value-setq (stderr-text stderr-truncated)
                              (%git-read-stream-capped (sb-ext:process-error process) max-chars)))
                          :name "git-diff-stderr-reader"))
         (exited-p (loop repeat (max 1 (ceiling (* timeout-seconds 10)))
                          do (unless (eq (sb-ext:process-status process) :running)
                               (return t))
                             (sleep 0.1)
                          finally (return (not (eq (sb-ext:process-status process) :running))))))
    (unless exited-p
      (ignore-errors (sb-ext:process-kill process sb-posix:sigterm))
      (sleep 0.2)
      (unless (eq (sb-ext:process-status process) :exited)
        (ignore-errors (sb-ext:process-kill process sb-posix:sigkill))))
    (sb-thread:join-thread stdout-reader :timeout (+ timeout-seconds 5) :default nil)
    (sb-thread:join-thread stderr-reader :timeout (+ timeout-seconds 5) :default nil)
    (values (if stdout-truncated
                (concatenate 'string (or stdout-text "") (format nil "~%[output truncated]"))
                (or stdout-text ""))
            (if stderr-truncated
                (concatenate 'string (or stderr-text "") (format nil "~%[stderr truncated]"))
                (or stderr-text ""))
            (and exited-p (sb-ext:process-exit-code process))
            (not exited-p))))

(defun %split-on-char (text ch)
  "TEXT split on every occurrence of CH, as a list of (possibly empty)
substrings -- e.g. used to split git's NUL-delimited -z status output
and to walk a relative path's '/'-separated components."
  (let ((parts '()) (start 0))
    (loop for i from 0 below (length text) do
      (when (char= (char text i) ch)
        (push (subseq text start i) parts)
        (setf start (1+ i))))
    (push (subseq text start) parts)
    (nreverse parts)))

(defun %git-rel-path-safe-p (rel-path)
  "Defense in depth (#140), the same posture as %PATH-UNDER-ROOT-P's own
comment about never trusting a caller-supplied path on its own: even
though every REL-PATH this ever actually sees comes from our own
%GIT-STATUS-ENTRIES parse of trusted `git status` output (never typed by
a caller), reject an absolute path or one with a literal \"..\" path
component before it ever reaches a git argv."
  (and (stringp rel-path)
       (plusp (length rel-path))
       (not (char= (char rel-path 0) #\/))
       (notany (lambda (c) (string= c "..")) (%split-on-char rel-path #\/))))

(defun %parse-git-status-z (text)
  "Parse `git status --porcelain=v1 -z --untracked-files=all` output into
a list of plists (:PATH :INDEX-STATUS :WORKTREE-STATUS :RENAME-FROM),
NIL RENAME-FROM unless either status char is #\\R or #\\C. Each record is
\"XY PATH\\0\", or, for a rename/copy, \"XY PATH\\0ORIG-PATH\\0\" (the new
path first, then the original -- verified empirically against a real
`git status --porcelain=v1 -z` run, not from memory of the docs)."
  (let ((tokens (remove "" (%split-on-char text #\Nul) :test #'string= :from-end t :count 1)))
    ;; -z terminates every record with \0, so the split leaves exactly one
    ;; trailing empty string when TEXT is non-empty; REMOVE ... :COUNT 1
    ;; :FROM-END T drops only that one, not a genuinely empty leading path.
    (let ((entries '()))
      (loop while tokens do
        (let* ((rec (pop tokens))
               (index-status (char rec 0))
               (worktree-status (char rec 1))
               (path (subseq rec 3))
               (renamed-p (or (char= index-status #\R) (char= index-status #\C)
                               (char= worktree-status #\R) (char= worktree-status #\C))))
          (push (list :path path :index-status index-status :worktree-status worktree-status
                      :rename-from (when renamed-p (pop tokens)))
                entries)))
      (nreverse entries))))

(defun %git-status-entries (repo-root)
  "List ROOT's uncommitted changes (#140) via `git status --porcelain=v1
-z --untracked-files=all`. Returns (values ENTRIES NIL) on success, each
entry a %PARSE-GIT-STATUS-Z plist, sorted by :PATH; (values NIL
:FORBIDDEN) if REPO-ROOT does not resolve under +FILE-BROWSER-ROOT+ or
is not a git working-tree root; (values NIL :ERROR MESSAGE) if git
itself failed or timed out."
  (cond
    ((not (%path-under-root-p repo-root +file-browser-root+)) (values nil :forbidden))
    ((not (%git-repo-root-p repo-root)) (values nil :forbidden))
    (t (multiple-value-bind (stdout stderr exit-code timed-out-p)
           (%run-git repo-root (list "status" "--porcelain=v1" "-z" "--untracked-files=all"))
         (declare (ignore exit-code))
         (cond
           (timed-out-p (values nil :error "git status timed out"))
           ((plusp (length (string-trim '(#\Space #\Newline #\Return) stderr)))
            (values nil :error (string-trim '(#\Space #\Newline #\Return) stderr)))
           (t (values (sort (%parse-git-status-z stdout) #'string-lessp
                             :key (lambda (e) (getf e :path)))
                      nil)))))))

(defun %git-status-badge-text (index-status worktree-status)
  "Human label for a %GIT-STATUS-ENTRIES entry's two status characters,
checked in the same priority order `git status`'s own plain-format
column headers document (conflict/untracked first, since those are not
really \"index vs worktree\" distinctions at all)."
  (cond
    ((and (char= index-status #\?) (char= worktree-status #\?)) "Untracked")
    ((or (char= index-status #\U) (char= worktree-status #\U)) "Conflict")
    ((char= index-status #\R) "Renamed")
    ((char= index-status #\C) "Copied")
    ((char= index-status #\A) "Added")
    ((or (char= index-status #\D) (char= worktree-status #\D)) "Deleted")
    ((or (char= index-status #\M) (char= worktree-status #\M)) "Modified")
    (t (format nil "~C~C" index-status worktree-status))))

(defun %git-diff-text (repo-root rel-path &key untracked-p)
  "Uncommitted diff (#140) for REL-PATH (git-relative to REPO-ROOT, as
returned by %GIT-STATUS-ENTRIES -- never a caller-typed path) within
REPO-ROOT. Tracked files use `git diff --no-color HEAD -- REL-PATH`,
which folds staged and unstaged changes into one diff; UNTRACKED-P (set
for a %GIT-STATUS-ENTRIES entry whose status is \"??\") instead uses
`git diff --no-color --no-index -- /dev/null REL-PATH`, since `git diff
HEAD` never shows a file git isn't tracking at all. Returns (values TEXT
NIL) on success (TEXT may be empty -- \"no changes\" -- e.g. a file whose
mode changed back to match HEAD between status and this call), (values
NIL :FORBIDDEN) if REPO-ROOT/REL-PATH fail validation, or (values NIL
:ERROR MESSAGE) if git reported one. Exit code alone can't distinguish a
real error from \"differences found\" here -- empirically, `git diff
--no-index` exits 1 both when the two sides differ *and* when the target
flat-out doesn't exist -- so this checks STDERR content instead, which
git leaves empty on every ordinary successful run of either form."
  (cond
    ((not (%path-under-root-p repo-root +file-browser-root+)) (values nil :forbidden))
    ((not (%git-rel-path-safe-p rel-path)) (values nil :forbidden))
    (t (multiple-value-bind (stdout stderr exit-code timed-out-p)
           (%run-git repo-root
                     (if untracked-p
                         (list "diff" "--no-color" "--no-index" "--" "/dev/null" rel-path)
                         (list "diff" "--no-color" "HEAD" "--" rel-path)))
         (declare (ignore exit-code))
         (cond
           (timed-out-p (values nil :error "git diff timed out"))
           ((plusp (length (string-trim '(#\Space #\Newline #\Return) stderr)))
            (values nil :error (string-trim '(#\Space #\Newline #\Return) stderr)))
           (t (values stdout nil)))))))

(defparameter +git-diff-meta-line-prefixes+
  '("diff --git" "index " "similarity index" "dissimilarity index"
    "rename from" "rename to" "copy from" "copy to" "new file mode"
    "deleted file mode" "old mode" "new mode" "Binary files"
    "\\ No newline")
  "Unified-diff header/metadata lines (#140), rendered with the dimmer
\"diff-meta\" style rather than as context/added/removed content.")

(defun %diff-meta-line-p (line)
  (some (lambda (prefix)
          (and (>= (length line) (length prefix))
               (string= line prefix :end1 (length prefix))))
        +git-diff-meta-line-prefixes+))

(defun %classify-diff-line (line)
  "One of :HUNK, :META, :ADD, :DEL, :CONTEXT for a single unified-diff
LINE (#140) -- checked in an order where a \"+++ \"/\"--- \" file-header
line is caught as :META before the plain \"starts with +/-\" content
checks below it would otherwise misclassify it as :ADD/:DEL."
  (cond
    ((and (>= (length line) 2) (string= line "@@" :end1 2)) :hunk)
    ((and (>= (length line) 4) (or (string= line "+++ " :end1 4)
                                    (string= line "--- " :end1 4)))
     :meta)
    ((%diff-meta-line-p line) :meta)
    ((and (plusp (length line)) (char= (char line 0) #\+)) :add)
    ((and (plusp (length line)) (char= (char line 0) #\-)) :del)
    (t :context)))

(defun %parse-unified-diff (text)
  "TEXT (a %GIT-DIFF-TEXT result) as a list of plists (:KIND :TEXT), one
per line, via %CLASSIFY-DIFF-LINE. %SPLIT-LINES always contributes one
final empty \"line\" for TEXT's own trailing newline (every real git diff
ends with one) -- dropped here so the rendered diff doesn't end with a
spurious blank row; a TEXT that doesn't end in a newline (or is empty)
keeps whatever %SPLIT-LINES actually produced, untouched."
  (let ((lines (%split-lines text)))
    (when (and lines
               (plusp (length text))
               (char= (char text (1- (length text))) #\Newline))
      (setf lines (butlast lines)))
    (mapcar (lambda (line) (list :kind (%classify-diff-line line) :text line))
            lines)))

(defun %git-diff-html (text &key truncated-p)
  "Render unified diff TEXT (#140) as HTML: one <div class=\"diff-line
diff-KIND\"> per line, ESCAPE-TEXT'd so raw diff content -- which is
after all arbitrary file content -- can never inject markup, the same
posture as EVENT-DISPLAY/MARKDOWN-TO-HTML above. Empty TEXT renders a
plain \"No changes\" message instead of an empty element."
  (with-output-to-string (out)
    (if (zerop (length (or text "")))
        (format out "<div class=\"diff-empty\">No changes</div>")
        (dolist (entry (%parse-unified-diff text))
          (format out "<div class=\"diff-line diff-~(~A~)\">~A</div>"
                  (getf entry :kind) (escape-text (getf entry :text)))))
    (when truncated-p
      (format out "<div class=\"diff-truncated\">…diff truncated at ~D characters</div>"
              +git-diff-max-chars+))))
