(in-package #:claude-agent-sdk-cl)

;;;; Phase 6 public interactive client — persistent protocol layer.

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
   (state :initform :new :accessor client-state)
   (framer :initform (make-jsonl-framer) :reader client-framer)
   (router :initform (make-protocol-router) :reader client-router)
   ;; FIFO queues: raw complete JSON objects, then decoded public messages.
   (raw-records :initform '() :accessor client-raw-records)
   (messages :initform '() :accessor client-messages)
   ;; Alist of (subtype . synchronous function). Functions receive the decoded
   ;; request object and return a JSON object or :CANCEL.
   (control-handlers :initarg :control-handlers :initform nil
                     :reader client-control-handlers)
   ;; All control and user JSONL writes share this lock; an interactive child
   ;; must never receive interleaved frames from concurrent callers.
   (write-lock :initform (sb-thread:make-mutex :name "claude-client-write")
               :reader client-write-lock))
  (:documentation "Stateful interactive Claude Code client.

State transitions are :NEW -> :CONNECTED -> :CLOSING -> :CLOSED. A result
record closes a response boundary, not this persistent client connection."))

(defun make-claude-sdk-client (&key options transport cli-path timeout control-handlers)
  "Construct an interactive client.

With no injected TRANSPORT, provision Claude Code's persistent stream-json
subprocess using explicit CLI-PATH first and PATH discovery second."
  (unless (or (null options) (typep options 'agent-options))
    (signal-sdk-input-error "client options must be an agent-options instance or NIL"))
  (let ((effective-options (or options (make-agent-options))))
    (make-instance 'claude-sdk-client
                   :options effective-options
                   :control-handlers control-handlers
                   :transport (or transport
                                  (make-default-client-transport
                                   effective-options cli-path timeout)))))

(defun %require-client-state (client operation allowed)
  (unless (member (client-state client) allowed)
    (signal-client-lifecycle-error operation (client-state client))))

(defun %client-json-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key object) value))
    object))

(defun %client-json-line (object)
  (concatenate 'string
               (with-output-to-string (stream) (yason:encode object stream))
               (string #\Newline)))

(defun %client-write (client object)
  (let ((wire (%client-json-line object)))
    (sb-thread:with-mutex ((client-write-lock client))
      (emit-transport-log :client.stdin :input wire)
      (write-client-input (client-transport-instance client) wire))))

(defun %client-enqueue-message (client message)
  (setf (client-messages client) (nconc (client-messages client) (list message))))

(defun %client-next-record (client)
  "Return the next complete decoded JSON object, or NIL at transport EOF."
  (loop
    (when (client-raw-records client)
      (return (pop (client-raw-records client))))
    (let ((chunk (read-client-chunk (client-transport-instance client))))
      (unless chunk
        (let ((final (flush-jsonl-framer (client-framer client))))
          (when final
            (return (decode-jsonl-record final)))
          (return nil)))
      (let ((records (push-jsonl-chunk (client-framer client) chunk)))
        (setf (client-raw-records client)
              (nconc (client-raw-records client)
                     (remove nil (mapcar #'decode-jsonl-record records))))))))

(defun %client-route-next (client)
  "Read/rout one record. Returns (values payload route), NIL/NIL at EOF."
  (let ((record (%client-next-record client)))
    (if record
        (route-protocol-record (client-router client) record)
        (values nil nil))))

(defun %client-terminal-eof (client)
  (when (eq (client-state client) :connected)
    (setf (client-state client) :closing)
    (unwind-protect
         (close-client-transport (client-transport-instance client) :reason :eof)
      (clear-protocol-router (client-router client) :reason :eof)
      (setf (client-state client) :closed))))

(defun %client-decode-event (record)
  "Decode known public stream events; log and skip unknown future event types.

Protocol framing/JSON validity remains strict. This forward-compatibility policy
applies only after a valid object has been framed and routed as an ordinary event."
  (let ((type (gethash "type" record)))
    (if (member type '("assistant" "user" "system" "result" "rate_limit_event")
                :test #'equal)
        (decode-query-event record)
        (progn
          (emit-transport-log :client.unknown-event :record record :type type)
          nil))))

(defun %client-control-response (client request-id subtype &key response error)
  (%client-write client
                 (%client-json-object
                  "type" "control_response"
                  "response" (if error
                                 (%client-json-object "subtype" "error"
                                                      "request_id" request-id
                                                      "error" error)
                                 (%client-json-object "subtype" subtype
                                                      "request_id" request-id
                                                      "response" response)))))

(defun %client-handle-control-request (client record)
  "Synchronously service one inbound CLI control request.

All outcomes are terminal on the wire: a missing/failed/cancelled handler emits
an error response, while a handler returning a JSON object emits success."
  (let* ((request-id (control-request-request-id record))
         (request (gethash "request" record))
         (subtype (and (hash-table-p request) (gethash "subtype" request)))
         (entry (and (stringp subtype)
                     (assoc subtype (client-control-handlers client) :test #'equal)))
         (handler (cdr entry)))
    (cond
      ((not (stringp request-id))
       (emit-transport-log :client.control.invalid :record record :reason :missing-request-id))
      ((not (hash-table-p request))
       (%client-control-response client request-id "error" :error "control request is missing object request"))
      ((not (stringp subtype))
       (%client-control-response client request-id "error" :error "control request is missing subtype"))
      ((not (functionp handler))
       (%client-control-response client request-id "error"
                                 :error (format nil "No control handler for subtype: ~A" subtype)))
      (t
       (handler-case
           (let ((response (funcall handler request)))
             (if (eq response :cancel)
                 (%client-control-response client request-id "error" :error "control request cancelled")
                 (if (hash-table-p response)
                     (%client-control-response client request-id "success" :response response)
                     (%client-control-response client request-id "error"
                                               :error "control handler must return a hash table or :cancel"))))
         (error (condition)
           (%client-control-response client request-id "error" :error (princ-to-string condition))))))))

(defun %client-await-response (client request-id operation)
  "Wait synchronously for a registered control response, buffering public events."
  (declare (ignore request-id))
  (loop
    (multiple-value-bind (record route) (%client-route-next client)
      (unless record
        (%client-terminal-eof client)
        (error 'cli-connection-error
               :message (format nil "CLI stream ended waiting for ~A" operation)))
      (case route
        (:response
         ;; ROUTE only yields :response for a currently registered request. The
         ;; router removes it atomically, so this record belongs to the current request.
         (return record))
        (:request
         (%client-handle-control-request client record))
        (:event
         ;; System/rate-limit events may legitimately arrive before initialize
         ;; finishes; preserve them for receive-message.
         (let ((message (%client-decode-event record)))
           (when message (%client-enqueue-message client message))))))))

(defun %client-send-control (client subtype)
  (let* ((router (client-router client))
         (request-id (next-request-id router)))
    (register-request router request-id)
    (%client-write client
                   (%client-json-object
                    "type" "control_request" "request_id" request-id
                    "request" (%client-json-object "subtype" subtype "hooks" nil)))
    (%client-await-response client request-id subtype)))

(defun connect (client)
  "Start CLIENT and complete its initialize control handshake."
  (%require-client-state client :connect '(:new))
  (handler-case
      (progn
        (start-client-transport (client-transport-instance client) (client-options client))
        (setf (client-state client) :connected)
        (%client-send-control client "initialize")
        client)
    (error (condition)
      (unless (eq (client-state client) :closed)
        (disconnect client))
      (error condition))))

(defun send (client input &key (session-id "default"))
  "Send string INPUT as an upstream stream-json user envelope."
  (%require-client-state client :send '(:connected))
  (unless (stringp input)
    (signal-sdk-input-error "client input must be a string"))
  (%client-write client
                 (%client-json-object
                  "type" "user" "session_id" session-id
                  "message" (%client-json-object "role" "user" "content" input)
                  "parent_tool_use_id" nil))
  client)

(defun receive-message (client)
  "Return the next public typed message, skipping internal control traffic.
Returns NIL only at terminal stream EOF (and transitions the client to :CLOSED)."
  (%require-client-state client :receive-message '(:connected))
  (when (client-messages client)
    (return-from receive-message (pop (client-messages client))))
  (loop
    (multiple-value-bind (record route) (%client-route-next client)
      (unless record
        (%client-terminal-eof client)
        (return nil))
      (case route
        (:request (%client-handle-control-request client record))
        (:event
         (let ((message (%client-decode-event record)))
           (when message (return message))))))))

(defun receive-response (client)
  "Return ordered public messages through and including the next result record.
The client remains :CONNECTED after the result, ready for another `send`."
  (%require-client-state client :receive-response '(:connected))
  (let ((messages '()))
    (loop for message = (receive-message client)
          while message do
            (push message messages)
            (when (typep message 'result-message)
              (return (nreverse messages)))
          finally (return (nreverse messages)))))

(defun interrupt (client)
  "Send/correlate the upstream interrupt control request."
  (%require-client-state client :interrupt '(:connected))
  (%client-send-control client "interrupt")
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
       (clear-protocol-router (client-router client) :reason :disconnect)
       (setf (client-state client) :closed))
     client)))
