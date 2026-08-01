(in-package #:sm-harness-web-ui/tests)
(in-suite :sm-harness-web-ui/tests)

(test status-labels
  (is (string= "Ready" (sm-harness-web-ui::status-label :ready)))
  (is (string= "Responding" (sm-harness-web-ui::status-label :responding))))

(test escape-text-is-literal
  (is (string= "a&lt;b&gt;&amp;c"
               (sm-harness-web-ui::escape-text "a<b>&c"))))

(test event-display-assistant
  (let* ((ev (sm-harness:make-event :type :assistant-text :sequence 1
                                    :session-id "s"
                                    :payload (list :text "hi <x>")))
         (d (sm-harness-web-ui::event-display ev)))
    (is (string= "assistant" (car d)))
    (is (search "&lt;x&gt;" (cdr d)))))

(test event-display-user-message-is-plain-user
  (let* ((ev (sm-harness:make-event :type :user-message :sequence 1
                                    :session-id "s"
                                    :payload (list :text "hello")))
         (d (sm-harness-web-ui::event-display ev)))
    (is (string= "user" (car d)))))

(test event-display-title-shows-the-new-title-unescaped
  ;; #129: consumed via CLOG:TEXT (DOM textContent), not ADD-LINE's
  ;; INNER-HTML, so this must come back raw -- ESCAPE-TEXTing it here would
  ;; double-encode and show a user a literal "&amp;" instead of "&".
  (let* ((ev (sm-harness:make-event :type :title :sequence 1
                                    :session-id "s"
                                    :payload (list :title "Fix & ship it")))
         (d (sm-harness-web-ui::event-display ev)))
    (is (string= "title" (car d)))
    (is (string= "Fix & ship it" (cdr d)))))

(test event-display-synthetic-user-message-is-harness-not-user
  ;; A harness-initiated follow-up (#76) must never render indistinguishably
  ;; from something the human actually typed.
  (let* ((ev (sm-harness:make-event :type :user-message :sequence 1
                                    :session-id "s"
                                    :payload (list :text "[harness] ..." :synthetic t)))
         (d (sm-harness-web-ui::event-display ev)))
    (is (string= "harness" (car d)))))

(test event-display-system-init-subtype-is-legible
  ;; #102: this used to render as a bare, contentless "SYSTEM" chip -- the
  ;; CLI's own type="system" subtype="init" message reaching here every
  ;; session/turn start.
  (let* ((ev (sm-harness:make-event :type :system :sequence 1
                                    :session-id "s"
                                    :payload (list :subtype "init")))
         (d (sm-harness-web-ui::event-display ev)))
    (is (string= "system" (car d)))
    (is (search "init" (cdr d)))))

(test event-display-system-thinking-subtype-is-a-friendly-label
  ;; sm-harness/src/sdk-adapter.lisp synthesizes (:SYSTEM :SUBTYPE "thinking")
  ;; once per omitted extended-thinking block -- often several per turn, and
  ;; the single biggest source of the "wall of SYSTEM chips" in #102.
  (let* ((ev (sm-harness:make-event :type :system :sequence 1
                                    :session-id "s"
                                    :payload (list :subtype "thinking"
                                                   :text "[thinking omitted]")))
         (d (sm-harness-web-ui::event-display ev)))
    (is (string= "system" (car d)))
    (is (search "Thinking" (cdr d)))))

(test event-display-rate-limit-shows-its-fields
  ;; #102: sm-harness/src/sdk-adapter.lisp used to drop rate_limit_info
  ;; entirely before it reached here; this asserts the presenter actually
  ;; surfaces the fields it now receives.
  (let* ((ev (sm-harness:make-event :type :rate-limit :sequence 1
                                    :session-id "s"
                                    :payload (list :status "allowed"
                                                   :rate-limit-type "5h"
                                                   :utilization 42
                                                   :resets-at "2026-08-01T00:00:00Z")))
         (d (sm-harness-web-ui::event-display ev)))
    (is (string= "system" (car d)))
    (is (search "allowed" (cdr d)))
    (is (search "42" (cdr d)))
    (is (search "2026-08-01T00:00:00Z" (cdr d)))))

(test event-display-unrecognized-shows-the-sdk-class-name
  (let* ((ev (sm-harness:make-event :type :unrecognized :sequence 1
                                    :session-id "s"
                                    :payload (list :class "SOME-FUTURE-SDK-CLASS")))
         (d (sm-harness-web-ui::event-display ev)))
    (is (string= "system" (car d)))
    (is (search "SOME-FUTURE-SDK-CLASS" (cdr d)))))

(test event-display-unmapped-type-warns
  ;; The catch-all is meant to be a safety net, not a normal path (#102):
  ;; every time it fires should be discoverable in operator logs.
  (let ((ev (sm-harness:make-event :type :something-brand-new :sequence 1
                                   :session-id "s" :payload nil)))
    (signals warning (sm-harness-web-ui::event-display ev))))

(test event-display-unmapped-type-still-shows-type-and-payload
  ;; Muffled here only so the test can inspect EVENT-DISPLAY's return value
  ;; without the expected WARN aborting the form; the warning itself is
  ;; covered separately above.
  (let* ((ev (sm-harness:make-event :type :something-brand-new :sequence 1
                                    :session-id "s" :payload (list :foo "bar")))
         (d (handler-bind ((warning #'muffle-warning))
              (sm-harness-web-ui::event-display ev))))
    (is (string= "system" (car d)))
    (is (search "SOMETHING-BRAND-NEW" (cdr d)))
    (is (search "foo: bar" (cdr d)))))

(test shutdown-signal-handler-survives-a-real-three-argument-signal-call
  ;; #82: SB-SYS:ENABLE-INTERRUPT invokes handlers with 3 arguments; the
  ;; previous 0-arg lambda died with "invalid number of arguments: 3" on
  ;; every SIGTERM, so shutdown was always a crash, never graceful.
  ;; Deliver a real SIGTERM to this very process and require the shutdown
  ;; flag to flip with no unhandled condition.
  (let ((requested nil))
    (unwind-protect
         (progn
           (sm-harness-web-ui::%install-shutdown-signal-handlers
            (lambda () (setf requested t)))
           (sb-posix:kill (sb-posix:getpid) sb-unix:sigterm)
           (loop repeat 100 until requested do (sleep 0.05))
           (is (eq t requested)))
      ;; Restore defaults so a later real TERM still terminates the
      ;; test process normally.
      (sb-sys:enable-interrupt sb-unix:sigterm :default)
      (sb-sys:enable-interrupt sb-unix:sigint :default))))

;;; --- markdown-to-html (#71) ---------------------------------------------

(test markdown-bold
  (is (string= "<p><strong>hi</strong></p>"
               (sm-harness-web-ui::markdown-to-html "**hi**"))))

(test markdown-bold-underscore
  (is (string= "<p><strong>hi</strong></p>"
               (sm-harness-web-ui::markdown-to-html "__hi__"))))

(test markdown-italic
  (is (string= "<p><em>hi</em></p>"
               (sm-harness-web-ui::markdown-to-html "*hi*"))))

(test markdown-italic-underscore
  (is (string= "<p><em>hi</em></p>"
               (sm-harness-web-ui::markdown-to-html "_hi_"))))

(test markdown-inline-code
  (is (string= "<p><code>hi</code></p>"
               (sm-harness-web-ui::markdown-to-html "`hi`"))))

(test markdown-inline-code-protects-content-from-emphasis
  (is (string= "<p><code>*not em*</code></p>"
               (sm-harness-web-ui::markdown-to-html "`*not em*`"))))

(test markdown-heading-levels
  (is (string= "<h1>Title</h1>" (sm-harness-web-ui::markdown-to-html "# Title")))
  (is (string= "<h3>Sub</h3>" (sm-harness-web-ui::markdown-to-html "### Sub"))))

(test markdown-unordered-list
  (is (string= "<ul><li>a</li><li>b</li></ul>"
               (sm-harness-web-ui::markdown-to-html (format nil "- a~%- b")))))

(test markdown-ordered-list
  (is (string= "<ol><li>a</li><li>b</li></ol>"
               (sm-harness-web-ui::markdown-to-html (format nil "1. a~%2. b")))))

(test markdown-fenced-code-block-is-not-interpreted
  (is (string= "<pre><code>*x* [y](https://z)</code></pre>"
               (sm-harness-web-ui::markdown-to-html
                (format nil "```~%*x* [y](https://z)~%```")))))

(test markdown-paragraph-lines-keep-their-newline
  ;; A literal newline, not <br>: the transcript renders pre-wrap, and the
  ;; newline must survive into text content (selection, text assertions).
  (is (string= (format nil "<p>a~%b</p>")
               (sm-harness-web-ui::markdown-to-html (format nil "a~%b")))))

(test markdown-https-link-is-rendered
  (let ((html (sm-harness-web-ui::markdown-to-html "[go](https://example.com)")))
    (is (search "<a href=\"https://example.com\" target=\"_blank\" rel=\"noopener noreferrer\">go</a>"
                html))))

(test markdown-mailto-link-is-rendered
  (let ((html (sm-harness-web-ui::markdown-to-html "[mail](mailto:a@b.com)")))
    (is (search "<a href=\"mailto:a@b.com\"" html))))

(test markdown-javascript-link-is-not-rendered
  ;; A disallowed scheme must never become a clickable <a>; it degrades to
  ;; literal, already-escaped text instead.
  (let ((html (sm-harness-web-ui::markdown-to-html "[bad](javascript:alert(1))")))
    (is (not (search "<a " html)))
    (is (search "[bad](javascript:alert(1))" html))))

(test markdown-raw-html-is-neutralized
  (let ((html (sm-harness-web-ui::markdown-to-html "<script>alert(1)</script>")))
    (is (not (search "<script>" html)))
    (is (search "&lt;script&gt;" html))))

(test markdown-safe-rendering-fixture-has-no-script-or-anchor
  ;; The exact assistant text used by the safe-rendering E2E fixture
  ;; (fixture-transport.lisp): a raw <script> tag, an unrecognized
  ;; disallowed-scheme "link", and legitimate bold syntax alongside it.
  ;; None of that may ever produce a real <script> or <a> element.
  (let ((html (sm-harness-web-ui::markdown-to-html
               "<script>e2e-xss</script> **not bold** [not-link](javascript:alert(1))")))
    (is (not (search "<script>" html)))
    (is (not (search "<a " html)))
    (is (search "e2e-xss" html))
    (is (search "<strong>not bold</strong>" html))))

(test backend-label-and-model-label-106
  (is (string= "Claude" (sm-harness-web-ui::%backend-label "claude")))
  ;; An unrecognized backend id (shouldn't happen given START-SESSION's own
  ;; validation, but a display helper must still degrade gracefully) falls
  ;; back to the raw id rather than erroring.
  (is (string= "vertex" (sm-harness-web-ui::%backend-label "vertex")))
  (is (string= "Claude Opus" (sm-harness-web-ui::%model-label "claude" "opus")))
  (is (string= "Default" (sm-harness-web-ui::%model-label "claude" nil))
      "NIL model (no session-level override) must read as Default, not blank")
  (is (string= "gpt-5" (sm-harness-web-ui::%model-label "claude" "gpt-5"))
      "an unrecognized model id still degrades to the raw id"))

(test format-elapsed-buckets-111
  ;; #111: home-screen chip's "time since started" label. NOW is pinned so
  ;; this never flakes on real wall-clock timing.
  (let ((now (encode-universal-time 30 0 12 15 6 2026 0)))
    (is (string= "just now"
                 (sm-harness-web-ui::%format-elapsed
                  "2026-06-15T12:00:01Z" :now now)))
    (is (string= "5m ago"
                 (sm-harness-web-ui::%format-elapsed
                  "2026-06-15T11:55:30Z" :now now)))
    (is (string= "2h ago"
                 (sm-harness-web-ui::%format-elapsed
                  "2026-06-15T10:00:30Z" :now now)))
    (is (string= "3d ago"
                 (sm-harness-web-ui::%format-elapsed
                  "2026-06-12T12:00:30Z" :now now)))))

(test format-elapsed-clamps-future-skew-and-degrades-missing-input-111
  (let ((now (encode-universal-time 0 0 12 15 6 2026 0)))
    (is (string= "just now"
                 (sm-harness-web-ui::%format-elapsed
                  "2026-06-15T12:00:05Z" :now now))
        "a small clock skew putting ISO slightly in the future must clamp,
never print a negative duration")
    (is (string= "unknown" (sm-harness-web-ui::%format-elapsed nil)))
    (is (string= "unknown" (sm-harness-web-ui::%format-elapsed "")))
    (is (string= "unknown" (sm-harness-web-ui::%format-elapsed "garbage")))))

(test turn-count-label-pluralizes-111
  (is (string= "0 turns" (sm-harness-web-ui::%turn-count-label 0)))
  (is (string= "1 turn" (sm-harness-web-ui::%turn-count-label 1)))
  (is (string= "3 turns" (sm-harness-web-ui::%turn-count-label 3)))
  (is (string= "0 turns" (sm-harness-web-ui::%turn-count-label nil))))

(test session-chip-html-shows-every-required-field-111
  ;; Issue #111's own ask: each home-screen chip must show session id,
  ;; backend, model, turn count, time since started, and canonical id.
  (let* ((summary (sm-harness:make-session-summary
                   :id "sess-123-456" :title "New session"
                   :status :ready :canonical-id "canon-9"
                   :backend "claude" :model "opus"
                   :created-at "2020-01-01T00:00:00Z"
                   :turn-count 3))
         (html (sm-harness-web-ui::%session-chip-html summary)))
    (is (search "sess-123-456" html))
    (is (search "Claude" html))
    (is (search "Claude Opus" html))
    (is (search "3 turns" html))
    (is (search "canon-9" html))
    (is (search "Ready" html))
    (is (search "ago" html))))

(test session-chip-html-pending-canonical-and-default-model-111
  (let* ((summary (sm-harness:make-session-summary
                   :id "sess-1" :title "New session"
                   :status :connecting :canonical-id nil
                   :backend "claude" :model nil
                   :created-at nil :turn-count 0))
         (html (sm-harness-web-ui::%session-chip-html summary)))
    (is (search "Pending" html))
    (is (search "Default" html))
    (is (search "0 turns" html))
    (is (search "unknown" html))))

(test session-chip-html-escapes-untrusted-title-111
  (let* ((summary (sm-harness:make-session-summary
                   :id "sess-1" :title "<script>alert(1)</script>"
                   :status :ready :canonical-id nil
                   :backend "claude" :model nil
                   :created-at nil :turn-count 0))
         (html (sm-harness-web-ui::%session-chip-html summary)))
    (is (not (search "<script>" html)))
    (is (search "&lt;script&gt;" html))))

(test app-css-href-cache-busts-on-the-served-files-own-write-date
  ;; A real incident (chasing #111): a browser can keep serving a stale
  ;; "/app.css" from its own HTTP cache indefinitely, since that response
  ;; carries no Cache-Control/Expires header. %APP-CSS-HREF must change
  ;; whenever the actually-served file's content changes on disk, whether
  ;; or not the Lisp process itself was ever restarted (the exact case
  ;; that bit us: /opt/app-static re-copied with no restart).
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "sm-harness-web-ui-css-test-~A/"
                                        (random 1000000 (make-random-state t)))
                                (uiop:temporary-directory))))
         (css-path (merge-pathnames "app.css" dir))
         (sm-harness-web-ui::*web-ui-config* nil))
    (unwind-protect
         (progn
           (ensure-directories-exist dir)
           (with-open-file (out css-path :direction :output :if-does-not-exist :create)
             (write-string "body{color:red}" out))
           (setf sm-harness-web-ui::*web-ui-config*
                 (sm-harness-web-ui::make-web-ui-config :static-root dir))
           (let ((href1 (sm-harness-web-ui::%app-css-href)))
             (is (search "/app.css?v=" href1))
             ;; A file-write-date bump (real edit, or a re-copy with no
             ;; process restart) changes the URL.
             (sleep 1.1)
             (with-open-file (out css-path :direction :output :if-exists :supersede)
               (write-string "body{color:blue}" out))
             (let ((href2 (sm-harness-web-ui::%app-css-href)))
               (is (not (string= href1 href2))))))
      (ignore-errors (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(test app-css-href-degrades-to-the-plain-url-without-config-or-file
  (let ((sm-harness-web-ui::*web-ui-config* nil))
    (is (string= "/app.css" (sm-harness-web-ui::%app-css-href))))
  (let ((sm-harness-web-ui::*web-ui-config*
          (sm-harness-web-ui::make-web-ui-config
           :static-root (uiop:ensure-directory-pathname
                         (merge-pathnames "sm-harness-web-ui-css-test-missing/"
                                          (uiop:temporary-directory))))))
    (is (string= "/app.css" (sm-harness-web-ui::%app-css-href)))))

;;; ---------------------------------------------------------------------
;;; File browser (#138)

(defmacro with-fs-fixture ((root-var) &body body)
  "Build a scratch directory tree under a temp dir for the duration of
BODY, bound to ROOT-VAR as a directory pathname, then remove it
afterwards regardless of outcome. Layout:
  b-dir/            (a directory, sorts after \".hidden\" but before z.txt)
  .hidden           (a dotfile -- must still show up, #138 review answer)
  a.txt, z.txt       (plain files)
  many/ (with +file-browser-max-entries+ + 5 files in it, for truncation)"
  `(let ((,root-var (uiop:ensure-directory-pathname
                     (merge-pathnames (format nil "sm-harness-web-ui-fs-test-~A/"
                                              (random 1000000 (make-random-state t)))
                                      (uiop:temporary-directory)))))
     (unwind-protect
          (progn
            (ensure-directories-exist ,root-var)
            (ensure-directories-exist (merge-pathnames "b-dir/" ,root-var))
            (ensure-directories-exist (merge-pathnames "many/" ,root-var))
            (dolist (name '(".hidden" "a.txt" "z.txt"))
              (with-open-file (out (merge-pathnames name ,root-var)
                                   :direction :output :if-does-not-exist :create)
                (write-string "x" out)))
            (dotimes (i (+ sm-harness-web-ui::+file-browser-max-entries+ 5))
              (with-open-file (out (merge-pathnames (format nil "f~4,'0D.txt" i)
                                                     (merge-pathnames "many/" ,root-var))
                                   :direction :output :if-does-not-exist :create)
                (write-string "x" out)))
            ,@body)
       (ignore-errors (uiop:delete-directory-tree ,root-var :validate t :if-does-not-exist :ignore)))))

(test file-browser-list-directory-sorts-directories-first-then-alpha
  (with-fs-fixture (root)
    (multiple-value-bind (entries truncated)
        (sm-harness-web-ui::%list-directory root :root root)
      (is (null truncated))
      ;; b-dir (the only directory) sorts before every file, regardless of
      ;; where "b" would otherwise land alphabetically among a/.hidden/z.
      (is (eq :directory (getf (first entries) :kind)))
      (is (string= "b-dir" (getf (first entries) :name)))
      (let ((file-names (mapcar (lambda (e) (getf e :name)) (rest (rest entries)))))
        (is (equal (sort (copy-list file-names) #'string-lessp) file-names))))))

(test file-browser-list-directory-includes-dotfiles
  ;; #138 review answer: dotfiles are shown, not filtered.
  (with-fs-fixture (root)
    (multiple-value-bind (entries truncated) (sm-harness-web-ui::%list-directory root :root root)
      (declare (ignore truncated))
      (is (member ".hidden" entries :key (lambda (e) (getf e :name)) :test #'string=)))))

(test file-browser-list-directory-truncates-past-the-cap
  ;; #138 review answer: cap very large directories rather than build
  ;; thousands of DOM rows in one click.
  (with-fs-fixture (root)
    (multiple-value-bind (entries truncated)
        (sm-harness-web-ui::%list-directory (merge-pathnames "many/" root) :root root)
      (is (eq t truncated))
      (is (= sm-harness-web-ui::+file-browser-max-entries+ (length entries))))))

(test file-browser-list-directory-rejects-a-path-outside-root
  (with-fs-fixture (root)
    (multiple-value-bind (entries reason)
        (sm-harness-web-ui::%list-directory (uiop:temporary-directory) :root root)
      (is (null entries))
      (is (eq :forbidden reason)))))

(test file-browser-list-directory-surfaces-a-missing-directory-as-error
  (with-fs-fixture (root)
    (multiple-value-bind (entries reason)
        (sm-harness-web-ui::%list-directory (merge-pathnames "does-not-exist/" root) :root root)
      (is (null entries))
      (is (eq :error reason)))))

(test file-browser-path-under-root-accepts-nested-paths-and-rejects-escapes
  (with-fs-fixture (root)
    (is (sm-harness-web-ui::%path-under-root-p (merge-pathnames "b-dir/" root) root))
    (is (not (sm-harness-web-ui::%path-under-root-p (uiop:temporary-directory) root)))))

(test file-browser-href-matches-the-serve-fs-request-app-mapping
  ;; The whole point of %FS-HREF (see %SERVE-FS-REQUEST-APP,
  ;; ui/file-browser.lisp): +FILE-BROWSER-URL-PREFIX+ followed by a
  ;; file's own absolute path, percent-encoded component by component --
  ;; exactly what that middleware strips back off before resolving
  ;; against +FILE-BROWSER-ROOT+. Exercised against a real file that
  ;; genuinely exists in this container (this project's own docs --
  ;; consistent with the project's stated posture that /app is real, not
  ;; sandboxed/fixture data, see docs/sm-harness-web-ui.md "Running
  ;; browser E2E without Docker").
  (let* ((file #P"/app/harness/docs/sm-harness-web-ui.md")
         (href (sm-harness-web-ui::%fs-href file)))
    (is (string= "/fs/app/harness/docs/sm-harness-web-ui.md" href))))

(test file-browser-url-encode-component-escapes-non-ascii-and-reserved-bytes
  (is (string= "a%20b" (sm-harness-web-ui::%fs-url-encode-component "a b")))
  (is (string= "a-b_c.d~e" (sm-harness-web-ui::%fs-url-encode-component "a-b_c.d~e")))
  ;; A non-ASCII character's UTF-8 continuation bytes must each be
  ;; percent-encoded individually, not accidentally passed through
  ;; (found while writing %FS-UNRESERVED-BYTE-P: CODE-CHAR on a raw
  ;; continuation byte can land on an ALPHANUMERICP Latin-1 letter).
  (is (string= "%C3%A9" (sm-harness-web-ui::%fs-url-encode-component "é"))))
