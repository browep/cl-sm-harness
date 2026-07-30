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
      (t
       (cons "system" (escape-text (princ-to-string type)))))))

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
