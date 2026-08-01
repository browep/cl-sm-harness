;;;; Convert public SDK messages to a small harness event schema; no CLI work.
(defpackage #:claude-agent-sdk-cl.harness-example.message-mapping
  (:use #:cl)
  (:export #:message->harness-event
           #:tool-use->harness-event
           #:tool-result->harness-event))
(in-package #:claude-agent-sdk-cl.harness-example.message-mapping)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun tool-use->harness-event (block)
  (list :kind :tool-use
        :id (claude-agent-sdk-cl:tool-use-block-id block)
        :name (claude-agent-sdk-cl:tool-use-block-name block)
        :input (claude-agent-sdk-cl:tool-use-block-input block)))

(defun tool-result->harness-event (block)
  (list :kind :tool-result
        :tool-use-id (claude-agent-sdk-cl:tool-result-block-tool-use-id block)
        :content (claude-agent-sdk-cl:tool-result-block-content block)
        :is-error (claude-agent-sdk-cl:tool-result-block-is-error block)))

(defun assistant-text (message)
  (with-output-to-string (out)
    (dolist (block (claude-agent-sdk-cl:assistant-message-content message))
      (typecase block
        (claude-agent-sdk-cl:text-block
         (write-string (claude-agent-sdk-cl:text-block-text block) out))
        (claude-agent-sdk-cl:thinking-block (write-string "[thinking]" out))
        (claude-agent-sdk-cl:tool-use-block
         (format out "[tool-use ~A]"
                 (claude-agent-sdk-cl:tool-use-block-name block)))
        (claude-agent-sdk-cl:tool-result-block
         (format out "[tool-result ~A]"
                 (claude-agent-sdk-cl:tool-result-block-tool-use-id block)))
        (t (write-string "[unknown-block]" out))))))

(defun message->harness-event (message)
  (typecase message
    (claude-agent-sdk-cl:assistant-message
     (list :kind :assistant :text (assistant-text message)
           :model (claude-agent-sdk-cl:assistant-message-model message)
           :blocks (mapcar (lambda (block)
                             (typecase block
                               (claude-agent-sdk-cl:tool-use-block
                                (tool-use->harness-event block))
                               (claude-agent-sdk-cl:tool-result-block
                                (tool-result->harness-event block))
                               (t (list :kind :block :type (type-of block)))))
                           (claude-agent-sdk-cl:assistant-message-content message))))
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
