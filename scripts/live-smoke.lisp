;;;; Opt-in Level 5 live smoke. Invoked only by scripts/test.sh live.
;;;; It deliberately prints no environment, token, prompt echo, raw transport
;;;; logs, or full model response—only terminal metadata needed as evidence.

(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(let* ((messages (claude-agent-sdk-cl:query
                  "Reply with exactly: SDK live smoke OK"
                  :timeout 120))
       (result (find-if (lambda (message)
                          (typep message 'claude-agent-sdk-cl:result-message))
                        messages)))
  (unless result
    (error "Live smoke ended without a result-message."))
  (when (claude-agent-sdk-cl:result-message-is-error result)
    (error "Live smoke returned an error result (subtype ~S)."
           (claude-agent-sdk-cl:result-message-subtype result)))
  (format t "live-smoke: messages=~D result-subtype=~A session-id=~A~%"
          (length messages)
          (claude-agent-sdk-cl:result-message-subtype result)
          (claude-agent-sdk-cl:result-message-session-id result)))
