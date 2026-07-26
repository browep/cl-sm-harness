;;;; Load-safe persistent-client adapter. Invoke RUN-INTERACTIVE-TURNS explicitly.
(defpackage #:claude-agent-sdk-cl.harness-example.interactive
  (:use #:cl)
  (:export #:run-interactive-turns))
(in-package #:claude-agent-sdk-cl.harness-example.interactive)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun run-interactive-turns (prompts publish-event &key cli-path (model "sonnet")
                                                     (session-id "harness"))
  "Run PROMPTS through one client. One owner must serialize send/receive pairs."
  (let ((client (claude-agent-sdk-cl:make-claude-sdk-client
                 :cli-path cli-path
                 :options (claude-agent-sdk-cl:make-agent-options :model model))))
    (unwind-protect
         (let ((all-messages '()))
           (claude-agent-sdk-cl:connect client)
           (dolist (prompt prompts)
             (claude-agent-sdk-cl:send client prompt :session-id session-id)
             (dolist (message (claude-agent-sdk-cl:receive-response client))
               (push message all-messages)
               (funcall publish-event message)))
           (nreverse all-messages))
      (claude-agent-sdk-cl:disconnect client))))
