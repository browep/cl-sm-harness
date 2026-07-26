;;;; Opt-in Phase 6 live two-turn smoke. Invoked only as `test.sh live-client`.
;;;; Prints fixed prompts and returned public text, never credentials or diagnostics.

(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defparameter +live-client-prompts+
  '("Reply with exactly: SDK interactive turn one OK"
    "Reply with exactly: SDK interactive turn two OK"))

(defun assistant-text (message)
  (when (typep message 'claude-agent-sdk-cl:assistant-message)
    (with-output-to-string (stream)
      (dolist (block (claude-agent-sdk-cl:assistant-message-content message))
        (when (typep block 'claude-agent-sdk-cl:text-block)
          (write-string (claude-agent-sdk-cl::text-block-text block) stream))))))

(let ((client (claude-agent-sdk-cl:make-claude-sdk-client :timeout 120)))
  (unwind-protect
       (progn
         (claude-agent-sdk-cl:connect client)
         (dolist (prompt +live-client-prompts+)
           (claude-agent-sdk-cl:send client prompt)
           (let* ((messages (claude-agent-sdk-cl:receive-response client))
                  (result (find-if (lambda (message)
                                     (typep message 'claude-agent-sdk-cl:result-message))
                                   messages))
                  (responses (remove nil (mapcar #'assistant-text messages))))
             (unless result (error "Interactive live turn ended without result-message."))
             (when (claude-agent-sdk-cl:result-message-is-error result)
               (error "Interactive live turn returned error subtype ~S."
                      (claude-agent-sdk-cl:result-message-subtype result)))
             (format t "live-client-prompt: ~A~%" prompt)
             (dolist (response responses)
               (format t "live-client-assistant-response: ~A~%" response))
             (format t "live-client-result: ~A~%"
                     (claude-agent-sdk-cl:result-message-result result))
             (format t "live-client: messages=~D result-subtype=~A~%"
                     (length messages)
                     (claude-agent-sdk-cl:result-message-subtype result)))))
    (claude-agent-sdk-cl:disconnect client)))
