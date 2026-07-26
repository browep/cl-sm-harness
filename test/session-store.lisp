(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/session-store :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/session-store)

(defun session-entry (type uuid)
  (let ((entry (make-hash-table :test #'equal)))
    (setf (gethash "type" entry) type (gethash "uuid" entry) uuid)
    entry))

(test in-memory-store-preserves-order-deduplicates-and-isolates-subkeys
  (let* ((store (claude-agent-sdk-cl:make-in-memory-session-store))
         (main (claude-agent-sdk-cl:make-session-key :project-key "project" :session-id "session-1"))
         (sub (claude-agent-sdk-cl:make-session-key :project-key "project" :session-id "session-1" :subpath "subagents/a"))
         (first (session-entry "assistant" "u1"))
         (second (session-entry "result" "u2")))
    (claude-agent-sdk-cl:session-store-append store main (list first second first))
    (claude-agent-sdk-cl:session-store-append store sub (list (session-entry "assistant" "u3")))
    (let ((loaded (claude-agent-sdk-cl:session-store-load store main)))
      (is (= 2 (length loaded)))
      (is (string= "u1" (gethash "uuid" (first loaded))))
      (is (string= "u2" (gethash "uuid" (second loaded)))))
    (is (equal '("session-1") (claude-agent-sdk-cl:session-store-list-sessions store "project")))
    (is (equal '("subagents/a") (claude-agent-sdk-cl:session-store-list-subkeys store main)))))

(test session-store-rejects-unsafe-key
  (signals claude-agent-sdk-cl:sdk-input-error
    (claude-agent-sdk-cl:session-store-load
     (claude-agent-sdk-cl:make-in-memory-session-store)
     (claude-agent-sdk-cl:make-session-key :project-key "../bad" :session-id "s"))))
