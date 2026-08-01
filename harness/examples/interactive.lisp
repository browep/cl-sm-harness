;;;; Interactive multi-turn example.
;;;; Run in the Docker development environment with Claude Code available.

(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(let ((client (claude-agent-sdk-cl:make-claude-sdk-client)))
  (unwind-protect
       (progn
         (claude-agent-sdk-cl:connect client)
         (dolist (prompt '("Say hello in one short sentence."
                           "Now summarize your previous reply in three words."))
           (claude-agent-sdk-cl:send client prompt)
           ;; Each call returns ordered public records through one result record;
           ;; the client remains connected for the next turn.
           (dolist (message (claude-agent-sdk-cl:receive-response client))
             (format t "~S~%" message))))
    ;; Safe and idempotent; also terminates a still-running direct child.
    (claude-agent-sdk-cl:disconnect client)))
