(in-package #:claude-agent-sdk-cl)

;;;; Phase 6 public interactive client — lifecycle foundation.
;;;;
;;;; This file intentionally starts with an injected persistent transport. The
;;;; subprocess-backed implementation arrives in a subsequent slice; it cannot
;;;; reuse the one-shot transport because it must retain stdin across turns.

(defclass client-transport ()
  ()
  (:documentation "Abstract persistent bidirectional transport for claude-sdk-client."))

(defgeneric start-client-transport (transport options)
  (:documentation "Start TRANSPORT once for OPTIONS and retain it for later writes."))

(defgeneric read-client-chunk (transport)
  (:documentation "Return the next persistent stdout chunk, or NIL at stream EOF."))

(defgeneric write-client-input (transport input)
  (:documentation "Serialize INPUT onto the persistent stdin stream."))

(defgeneric close-client-transport (transport &key reason)
  (:documentation "Close TRANSPORT idempotently with terminal REASON."))

(defclass claude-sdk-client ()
  ((options :initarg :options :reader client-options)
   (transport :initarg :transport :reader client-transport-instance)
   (state :initform :new :accessor client-state))
  (:documentation "Stateful interactive Claude Code client.

State transitions are :NEW -> :CONNECTED -> :CLOSING -> :CLOSED. A closed
client is terminal; create a new client to start another underlying process."))

(defun make-claude-sdk-client (&key options transport)
  "Construct an interactive client over a persistent TRANSPORT.

Automatic subprocess provisioning is deliberately deferred until the persistent
transport exists; this keeps lifecycle behavior independently testable."
  (unless transport
    (signal-sdk-input-error "interactive client requires a persistent :transport in this slice"))
  (make-instance 'claude-sdk-client
                 :options (or options (make-agent-options))
                 :transport transport))

(defun %require-client-state (client operation allowed)
  (unless (member (client-state client) allowed)
    (signal-client-lifecycle-error operation (client-state client))))

(defun connect (client)
  "Start CLIENT's persistent transport and transition :NEW to :CONNECTED."
  (%require-client-state client :connect '(:new))
  (start-client-transport (client-transport-instance client) (client-options client))
  (setf (client-state client) :connected)
  client)

(defun send (client input)
  "Send INPUT through a connected client.

The first slice delegates raw input to the injected transport. The next protocol
slice will encode the upstream user JSONL envelope under a serialized write lock."
  (%require-client-state client :send '(:connected))
  (unless (stringp input)
    (signal-sdk-input-error "client input must be a string"))
  (write-client-input (client-transport-instance client) input)
  client)

(defun receive-message (client)
  "Receive one raw chunk from a connected client's persistent transport.

Incremental framing and typed message decoding are added in the next client
protocol slice; this function establishes lifecycle guarding first."
  (%require-client-state client :receive-message '(:connected))
  (read-client-chunk (client-transport-instance client)))

(defun receive-response (client)
  "Receive one response boundary from CLIENT (protocol implementation pending)."
  (%require-client-state client :receive-response '(:connected))
  (receive-message client))

(defun interrupt (client)
  "Validate a connected client for interrupt.

The next protocol slice writes/correlates the upstream interrupt control request."
  (%require-client-state client :interrupt '(:connected))
  client)

(defun disconnect (client)
  "Idempotently transition CLIENT to :CLOSED and close its transport once."
  (case (client-state client)
    (:closed client)
    (:closing client)
    (otherwise
     (setf (client-state client) :closing)
     (unwind-protect
          (close-client-transport (client-transport-instance client) :reason :disconnect)
       (setf (client-state client) :closed))
     client)))
