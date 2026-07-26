;;;; Opt-in Level 5 live smoke. Invoked only by scripts/test.sh live.
;;;; The prompt and model response are intentionally printed as live-evidence
;;;; output. Credentials and raw transport diagnostics are never printed.

(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defparameter +live-smoke-prompt+ "Reply with exactly: SDK live smoke OK")

(defun assistant-text (message)
  (when (typep message 'claude-agent-sdk-cl:assistant-message)
    (with-output-to-string (stream)
      (dolist (block (claude-agent-sdk-cl:assistant-message-content message))
        (when (typep block 'claude-agent-sdk-cl:text-block)
          (write-string (claude-agent-sdk-cl::text-block-text block) stream))))))

(let* ((messages (claude-agent-sdk-cl:query +live-smoke-prompt+ :timeout 120))
       (result (find-if (lambda (message)
                          (typep message 'claude-agent-sdk-cl:result-message))
                        messages))
       (responses (remove nil (mapcar #'assistant-text messages))))
  (unless result
    (error "Live smoke ended without a result-message."))
  (when (claude-agent-sdk-cl:result-message-is-error result)
    (error "Live smoke returned an error result (subtype ~S)."
           (claude-agent-sdk-cl:result-message-subtype result)))
  (format t "live-smoke-prompt: ~A~%" +live-smoke-prompt+)
  (dolist (response responses)
    (format t "live-smoke-assistant-response: ~A~%" response))
  (format t "live-smoke-result: ~A~%"
          (claude-agent-sdk-cl:result-message-result result))
  (format t "live-smoke: messages=~D result-subtype=~A~%"
          (length messages)
          (claude-agent-sdk-cl:result-message-subtype result)))
