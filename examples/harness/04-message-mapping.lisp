;;;; Convert public SDK messages to a small harness event schema; no CLI work.
(defpackage #:claude-agent-sdk-cl.harness-example.message-mapping
  (:use #:cl)
  (:export #:message->harness-event))
(in-package #:claude-agent-sdk-cl.harness-example.message-mapping)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun assistant-text (message)
  (with-output-to-string (out)
    (dolist (block (claude-agent-sdk-cl:assistant-message-content message))
      ;; TEXT-BLOCK-TEXT is public. Other public block types intentionally have
      ;; no exported slot readers, so preserve their occurrence without probing
      ;; implementation details.
      (typecase block
        (claude-agent-sdk-cl:text-block
         (write-string (claude-agent-sdk-cl:text-block-text block) out))
        (claude-agent-sdk-cl:thinking-block (write-string "[thinking]" out))
        (claude-agent-sdk-cl:tool-use-block (write-string "[tool-use]" out))
        (claude-agent-sdk-cl:tool-result-block (write-string "[tool-result]" out))
        (t (write-string "[unknown-block]" out))))))

(defun message->harness-event (message)
  (typecase message
    (claude-agent-sdk-cl:assistant-message
     (list :kind :assistant :text (assistant-text message)
           :model (claude-agent-sdk-cl:assistant-message-model message)))
    (claude-agent-sdk-cl:result-message
     (list :kind :result :text (claude-agent-sdk-cl:result-message-result message)
           :is-error (claude-agent-sdk-cl:result-message-is-error message)
           :stop-reason (claude-agent-sdk-cl:result-message-stop-reason message)
           :usage (claude-agent-sdk-cl:result-message-usage message)))
    (claude-agent-sdk-cl:system-message
     (list :kind :system :subtype (claude-agent-sdk-cl:system-message-subtype message)
           :data (claude-agent-sdk-cl:system-message-data message)))
    (claude-agent-sdk-cl:rate-limit-event
     (let ((info (claude-agent-sdk-cl:rate-limit-event-rate-limit-info message)))
       (list :kind :rate-limit :status (claude-agent-sdk-cl:rate-limit-info-status info)
             :utilization (claude-agent-sdk-cl:rate-limit-info-utilization info))))
    (t (list :kind :other :value message))))
