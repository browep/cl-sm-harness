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
