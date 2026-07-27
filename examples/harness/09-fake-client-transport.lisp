;;;; Deterministic persistent-client transport. No process, credentials, or network.
(defpackage #:claude-agent-sdk-cl.harness-example.fake-client
  (:use #:cl)
  (:export #:fixture-client-transport #:run-fixture-client))
(in-package #:claude-agent-sdk-cl.harness-example.fake-client)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defclass fixture-client-transport (claude-agent-sdk-cl:client-transport)
  ((chunks :initarg :chunks :accessor chunks)
   (writes :initform '() :accessor writes)
   (closed-reason :initform nil :accessor closed-reason)))

(defmethod claude-agent-sdk-cl:start-client-transport
    ((transport fixture-client-transport) options)
  (declare (ignore options))
  transport)
(defmethod claude-agent-sdk-cl:read-client-chunk ((transport fixture-client-transport))
  (pop (chunks transport)))
(defmethod claude-agent-sdk-cl:write-client-input
    ((transport fixture-client-transport) input)
  (push input (writes transport))
  t)
(defmethod claude-agent-sdk-cl:close-client-transport
    ((transport fixture-client-transport) &key reason)
  (setf (closed-reason transport) reason)
  t)

(defun run-fixture-client ()
  "Exercise connect -> send -> receive-response -> disconnect without Claude.
Returns the public response messages and the wire frames written by the client."
  (let* ((newline (string #\Newline))
         (transport
           (make-instance 'fixture-client-transport
                          :chunks
                          (list
                           (concatenate 'string
                                        "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-1\"}}"
                                        newline)
                           (concatenate 'string
                                        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"offline turn\"}],\"model\":\"fixture\"}}"
                                        newline
                                        "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"fixture\",\"result\":\"done\"}"
                                        newline))))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl:connect client)
           (claude-agent-sdk-cl:send client "fixture prompt" :session-id "fixture")
           (values (claude-agent-sdk-cl:receive-response client)
                   (nreverse (writes transport))))
      (claude-agent-sdk-cl:disconnect client))))
