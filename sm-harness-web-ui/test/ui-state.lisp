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
