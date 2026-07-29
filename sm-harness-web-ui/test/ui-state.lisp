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
