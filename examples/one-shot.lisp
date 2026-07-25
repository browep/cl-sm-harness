;;;; One-shot streamed Claude Code query.
;;;;
;;;; Run in the SDK Docker image (or an environment with ASDF/Yason/SBCL and an
;;;; authenticated `claude` CLI on PATH):
;;;;   sbcl --non-interactive --load examples/one-shot.lisp
;;;;
;;;; For an explicit executable, add :cli-path "/path/to/claude" to `query`.

(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(let ((messages
        (claude-agent-sdk-cl:query
         "Reply with one short greeting."
         :options (claude-agent-sdk-cl:make-agent-options
                   :model "sonnet"
                   :permission-mode "default"))))
  (dolist (message messages)
    (typecase message
      (claude-agent-sdk-cl:assistant-message
       (format t "assistant: ~S~%"
               (claude-agent-sdk-cl:assistant-message-content message)))
      (claude-agent-sdk-cl:result-message
       (format t "result: ~A~%"
               (claude-agent-sdk-cl:result-message-result message)))
      (t
       (format t "event: ~S~%" message)))))
