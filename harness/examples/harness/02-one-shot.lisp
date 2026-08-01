;;;; Load-safe one-shot query adapter. Invoke RUN-ONE-SHOT explicitly to start Claude.
(defpackage #:claude-agent-sdk-cl.harness-example.one-shot
  (:use #:cl)
  (:export #:run-one-shot))
(in-package #:claude-agent-sdk-cl.harness-example.one-shot)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun run-one-shot (prompt publish-event &key cli-path (model "sonnet")
                                           (timeout 90) cancel-p)
  "Run one CLI-backed prompt and synchronously publish each public SDK event.
When CANCEL-P returns true for an event, stop reading and return prior events."
  (claude-agent-sdk-cl:query
   prompt
   :cli-path cli-path :timeout timeout
   :options (claude-agent-sdk-cl:make-agent-options
             :model model :allowed-tools '("Read" "Glob")
             :disallowed-tools '("Write" "Bash")
             :permission-mode "default")
   :on-message (lambda (message)
                 (funcall publish-event message)
                 (when (and cancel-p (funcall cancel-p message)) :cancel))))
