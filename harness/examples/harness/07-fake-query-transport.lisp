;;;; Deterministic query fixture transport. No process, credentials, or network.
(defpackage #:claude-agent-sdk-cl.harness-example.fake-query
  (:use #:cl)
  (:export #:fixture-query-transport #:run-fixture-query))
(in-package #:claude-agent-sdk-cl.harness-example.fake-query)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defclass fixture-query-transport (claude-agent-sdk-cl:query-transport)
  ((chunks :initarg :chunks :accessor chunks)
   (started-p :initform nil :accessor started-p)
   (closed-reason :initform nil :accessor closed-reason)))

(defmethod claude-agent-sdk-cl:start-query-transport
    ((transport fixture-query-transport) prompt options)
  (declare (ignore prompt options)) (setf (started-p transport) t) transport)
(defmethod claude-agent-sdk-cl:read-query-chunk ((transport fixture-query-transport))
  (pop (chunks transport)))
(defmethod claude-agent-sdk-cl:close-query-transport
    ((transport fixture-query-transport) &key reason)
  (setf (closed-reason transport) reason) transport)

(defun run-fixture-query ()
  (claude-agent-sdk-cl:query
   "fixture prompt"
   :transport
   (make-instance 'fixture-query-transport
                  :chunks
                  (list
                   (format nil "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"offline\"}],\"model\":\"fixture\"}}~%")
                   (format nil "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"fixture\",\"result\":\"done\"}~%")))))
