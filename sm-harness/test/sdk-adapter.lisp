(in-package #:sm-harness/tests)
(in-suite :sm-harness/tests)

(defun %mcp-text-content (text)
  "Build the realistic MCP content-block-array shape MAKE-SDK-TOOL-RESULT's
:TEXT produces on the wire: a list containing one {\"type\":\"text\",...}
hash table, matching what yason decodes a real tool_result's JSON content
array into."
  (let ((block (make-hash-table :test #'equal)))
    (setf (gethash "type" block) "text"
          (gethash "text" block) text)
    (list block)))

(test map-sdk-message-turns-a-user-message-tool-result-into-tool-completed
  (let* ((block (make-instance 'claude-agent-sdk-cl:tool-result-block
                               :tool-use-id "toolu_1"
                               :content (%mcp-text-content "tool output text")
                               :is-error nil))
         (message (make-instance 'claude-agent-sdk-cl:user-message :content (list block)))
         (mapped (sm-harness::map-sdk-message message)))
    (is (= 1 (length mapped)))
    (is (eq :tool-completed (first (first mapped))))
    (is (string= "toolu_1" (getf (rest (first mapped)) :tool-use-id)))
    ;; Readable text extracted from the MCP content-block array, never the
    ;; raw Lisp print representation of the decoded hash table.
    (is (string= "tool output text" (getf (rest (first mapped)) :content)))
    (is (null (getf (rest (first mapped)) :is-error)))))

(test map-sdk-message-turns-a-user-message-tool-error-into-tool-failed
  (let* ((block (make-instance 'claude-agent-sdk-cl:tool-result-block
                               :tool-use-id "toolu_2"
                               :content (%mcp-text-content "boom")
                               :is-error t))
         (message (make-instance 'claude-agent-sdk-cl:user-message :content (list block)))
         (mapped (sm-harness::map-sdk-message message)))
    (is (= 1 (length mapped)))
    (is (eq :tool-failed (first (first mapped))))
    (is (string= "boom" (getf (rest (first mapped)) :content)))
    (is (eq t (getf (rest (first mapped)) :is-error)))))

(test map-sdk-message-ignores-a-user-message-with-no-tool-result
  ;; The harness itself is the sole source of outbound user turns; an inbound
  ;; user-message that carries no tool-result-block originates nothing new.
  (let* ((message (make-instance 'claude-agent-sdk-cl:user-message
                                 :content (list (make-instance 'claude-agent-sdk-cl:text-block
                                                                :text "not a tool result"))))
         (mapped (sm-harness::map-sdk-message message)))
    (is (null mapped))))

(test mcp-content-text-handles-block-arrays-bare-strings-and-unknown-shapes
  (is (string= "hello" (sm-harness::%mcp-content-text (%mcp-text-content "hello"))))
  (is (string= "already text" (sm-harness::%mcp-content-text "already text")))
  ;; A non-text block (e.g. image) or an opaque shape must never surface a
  ;; raw Lisp print representation; a safe empty string is fine.
  (is (string= "" (sm-harness::%mcp-content-text 42)))
  (is (string= "" (sm-harness::%mcp-content-text
                   (list (let ((h (make-hash-table :test #'equal)))
                           (setf (gethash "type" h) "image")
                           h))))))

(test map-sdk-message-rate-limit-event-carries-its-fields
  ;; #102: this used to collapse to a bare (:RATE-LIMIT), discarding the
  ;; CLI's actual rate_limit_info before it ever reached the UI, so even a
  ;; presenter fix would have had nothing real to render.
  (let* ((info (make-instance 'claude-agent-sdk-cl:rate-limit-info
                              :status "allowed"
                              :resets-at "2026-08-01T00:00:00Z"
                              :rate-limit-type "5h"
                              :utilization 42
                              :overage-status "allowed"
                              :overage-resets-at nil
                              :overage-disabled-reason nil
                              :raw (make-hash-table :test #'equal)))
         (message (make-instance 'claude-agent-sdk-cl:rate-limit-event
                                 :rate-limit-info info
                                 :uuid "u1"
                                 :session-id "canon-1"))
         (mapped (sm-harness::map-sdk-message message)))
    (is (= 1 (length mapped)))
    (is (eq :rate-limit (first (first mapped))))
    (is (string= "allowed" (getf (rest (first mapped)) :status)))
    (is (string= "5h" (getf (rest (first mapped)) :rate-limit-type)))
    (is (= 42 (getf (rest (first mapped)) :utilization)))
    (is (string= "2026-08-01T00:00:00Z" (getf (rest (first mapped)) :resets-at)))))

(test map-sdk-message-system-message-carries-subtype
  (let* ((message (make-instance 'claude-agent-sdk-cl:system-message
                                 :subtype "init"
                                 :data (make-hash-table :test #'equal)))
         (mapped (sm-harness::map-sdk-message message)))
    (is (= 1 (length mapped)))
    (is (eq :system (first (first mapped))))
    (is (string= "init" (getf (rest (first mapped)) :subtype)))))
