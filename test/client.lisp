(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/client :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/client)

;;;; Persistent fake transport for lifecycle-only client tests. The first Phase 6
;;;; slice intentionally has no subprocess dependency.

(defclass fake-client-transport (claude-agent-sdk-cl:client-transport)
  ((start-count :initform 0 :accessor fake-client-start-count)
   (close-reasons :initform '() :accessor fake-client-close-reasons)
   (writes :initform '() :accessor fake-client-writes)))

(defmethod claude-agent-sdk-cl:start-client-transport ((transport fake-client-transport) options)
  (declare (ignore options))
  (incf (fake-client-start-count transport))
  transport)

(defmethod claude-agent-sdk-cl:write-client-input ((transport fake-client-transport) input)
  (push input (fake-client-writes transport))
  t)

(defmethod claude-agent-sdk-cl:read-client-chunk ((transport fake-client-transport))
  nil)

(defmethod claude-agent-sdk-cl:close-client-transport ((transport fake-client-transport) &key reason)
  (push reason (fake-client-close-reasons transport))
  t)

(test client-lifecycle-states-and-idempotent-disconnect
  (let* ((transport (make-instance 'fake-client-transport))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (is (eq :new (claude-agent-sdk-cl:client-state client)))
    (claude-agent-sdk-cl:connect client)
    (is (eq :connected (claude-agent-sdk-cl:client-state client)))
    (is (= 1 (fake-client-start-count transport)))
    ;; Disconnect is safe to call repeatedly, but a terminal client never
    ;; reconnects in this slice.
    (claude-agent-sdk-cl:disconnect client)
    (claude-agent-sdk-cl:disconnect client)
    (is (eq :closed (claude-agent-sdk-cl:client-state client)))
    (is (equal '(:disconnect) (fake-client-close-reasons transport)))))

(test client-invalid-lifecycle-calls-signal-typed-condition
  (let* ((transport (make-instance 'fake-client-transport))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:send client "before connect"))
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:receive-message client))
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:interrupt client))
    (claude-agent-sdk-cl:connect client)
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:connect client))
    (claude-agent-sdk-cl:disconnect client)
    (signals claude-agent-sdk-cl:client-lifecycle-error
      (claude-agent-sdk-cl:connect client))))

(test client-send-delegates-only-while-connected
  (let* ((transport (make-instance 'fake-client-transport))
         (client (claude-agent-sdk-cl:make-claude-sdk-client :transport transport)))
    (claude-agent-sdk-cl:connect client)
    (claude-agent-sdk-cl:send client "first turn")
    (claude-agent-sdk-cl:send client "second turn")
    ;; Wire encoding comes in the next protocol slice. This first lifecycle
    ;; slice proves ordered delegated writes only.
    (is (equal '("first turn" "second turn")
               (reverse (fake-client-writes transport))))
    (claude-agent-sdk-cl:disconnect client)))
