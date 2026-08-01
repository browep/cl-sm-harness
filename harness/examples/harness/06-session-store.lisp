;;;; Local session-store examples. These functions never invoke the CLI.
(defpackage #:claude-agent-sdk-cl.harness-example.session-store
  (:use #:cl)
  (:export #:record-in-memory-event #:make-filesystem-store #:make-session-plans))
(in-package #:claude-agent-sdk-cl.harness-example.session-store)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun event-object (uuid payload)
  (let ((event (make-hash-table :test #'equal)))
    (setf (gethash "uuid" event) uuid
          (gethash "type" event) "harness-event"
          (gethash "payload" event) payload)
    event))

(defun record-in-memory-event (project-key session-id uuid payload)
  (let* ((store (claude-agent-sdk-cl:make-in-memory-session-store))
         (key (claude-agent-sdk-cl:make-session-key :project-key project-key
                                                    :session-id session-id)))
    (claude-agent-sdk-cl:session-store-append store key (list (event-object uuid payload)))
    (values (claude-agent-sdk-cl:session-store-load store key)
            (claude-agent-sdk-cl:session-store-list-sessions store project-key))))

(defun make-filesystem-store (root)
  "Create a JSONL store rooted at ROOT; caller controls durable storage policy."
  (claude-agent-sdk-cl:make-filesystem-session-store :root root))

(defun make-session-plans ()
  "Return validated, side-effect-free import and mutation plans; no store I/O."
  (values
   (claude-agent-sdk-cl:make-session-import-plan
    :session-id "run-42" :path "imports/run-42.jsonl")
   (claude-agent-sdk-cl:make-session-mutation-plan
    :operation :rename :session-id "run-42" :value "baseline")))
