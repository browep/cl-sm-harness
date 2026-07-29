(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(test map-sdk-message-turns-a-user-message-tool-result-into-tool-completed
  (let* ((block (make-instance 'claude-agent-sdk-cl:tool-result-block
                               :tool-use-id "toolu_1"
                               :content "tool output text"
                               :is-error nil))
         (message (make-instance 'claude-agent-sdk-cl:user-message :content (list block)))
         (mapped (sm-harness::map-sdk-message message)))
    (is (= 1 (length mapped)))
    (is (eq :tool-completed (first (first mapped))))
    (is (string= "toolu_1" (getf (rest (first mapped)) :tool-use-id)))
    (is (string= "tool output text" (getf (rest (first mapped)) :content)))
    (is (null (getf (rest (first mapped)) :is-error)))))

(test map-sdk-message-turns-a-user-message-tool-error-into-tool-failed
  (let* ((block (make-instance 'claude-agent-sdk-cl:tool-result-block
                               :tool-use-id "toolu_2"
                               :content "boom"
                               :is-error t))
         (message (make-instance 'claude-agent-sdk-cl:user-message :content (list block)))
         (mapped (sm-harness::map-sdk-message message)))
    (is (= 1 (length mapped)))
    (is (eq :tool-failed (first (first mapped))))
    (is (eq t (getf (rest (first mapped)) :is-error)))))

(test map-sdk-message-ignores-a-user-message-with-no-tool-result
  ;; The harness itself is the sole source of outbound user turns; an inbound
  ;; user-message that carries no tool-result-block originates nothing new.
  (let* ((message (make-instance 'claude-agent-sdk-cl:user-message
                                 :content (list (make-instance 'claude-agent-sdk-cl:text-block
                                                                :text "not a tool result"))))
         (mapped (sm-harness::map-sdk-message message)))
    (is (null mapped))))
