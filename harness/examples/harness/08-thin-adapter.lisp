;;;; One-turn harness boundary. Invoke RUN-HARNESS-TURN explicitly to start Claude.
(defpackage #:claude-agent-sdk-cl.harness-example.thin-adapter
  (:use #:cl)
  (:export #:run-harness-turn))
(in-package #:claude-agent-sdk-cl.harness-example.thin-adapter)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun run-harness-turn (prompt emit &key cli-path (session-id "harness"))
  "Emit ordered SDK messages and return the terminal RESULT-MESSAGE or NIL."
  (let ((client (claude-agent-sdk-cl:make-claude-sdk-client :cli-path cli-path)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (claude-agent-sdk-cl:send client prompt :session-id session-id)
           (let ((response (claude-agent-sdk-cl:receive-response client)))
             (dolist (message response) (funcall emit message))
             (find-if (lambda (message)
                        (typep message 'claude-agent-sdk-cl:result-message))
                      response)))
      (claude-agent-sdk-cl:disconnect client))))
