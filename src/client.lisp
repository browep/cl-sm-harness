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
                     :accessor client-control-handlers)
   ;; Named registries power the upstream hook_callback and mcp_message
   ;; subtypes without requiring applications to parse raw control envelopes.
   (hook-callbacks :initform nil :accessor client-hook-callbacks)
   (mcp-handlers :initform nil :accessor client-mcp-handlers)
   ;; Inbound request IDs are one-shot. Retaining them for this connection makes
   ;; duplicate CLI deliveries deterministic instead of rerunning callbacks.
   (handled-control-requests :initform (make-hash-table :test #'equal)
                            :reader client-handled-control-requests)
   ;; All control and user JSONL writes share this lock; an interactive child
   ;; must never receive interleaved frames from concurrent callers.
   (write-lock :initform (sb-thread:make-mutex :name "claude-client-write")
               :reader client-write-lock))
  (:documentation "Stateful interactive Claude Code client.

State transitions are :NEW -> :CONNECTED -> :CLOSING -> :CLOSED. A result
record closes a response boundary, not this persistent client connection."))

(defun %validate-control-handlers (handlers)
  (unless (listp handlers)
    (signal-sdk-input-error "control handlers must be an alist"))
  (dolist (entry handlers)
    (unless (and (consp entry) (stringp (car entry)) (functionp (cdr entry)))
      (signal-sdk-input-error "each control handler must be (string . function)")))
  handlers)

(defun register-control-handler (client subtype function)
  "Register or replace FUNCTION for inbound control SUBTYPE before connect.

The persistent session freezes callback configuration at connect time so a
handler cannot change while its request is being synchronously serviced."
  (unless (stringp subtype)
    (signal-sdk-input-error "control handler subtype must be a string"))
  (unless (functionp function)
    (signal-sdk-input-error "control handler must be a function"))
  (%require-client-state client :register-control-handler '(:new))
  (setf (client-control-handlers client)
        (acons subtype function
               (remove subtype (client-control-handlers client)
                       :key #'car :test #'equal)))
  client)

(defun %register-named-control-handler (client registry-accessor name function operation)
  (unless (stringp name)
    (signal-sdk-input-error "control callback name must be a string"))
  (unless (functionp function)
    (signal-sdk-input-error "control callback must be a function"))
  (%require-client-state client operation '(:new))
  (let ((updated (acons name function
                        (remove name (funcall registry-accessor client)
                                :key #'car :test #'equal))))
    (ecase operation
      (:register-hook-callback (setf (client-hook-callbacks client) updated))
      (:register-sdk-mcp-handler (setf (client-mcp-handlers client) updated))))
  client)

(defun register-hook-callback (client callback-id function)
  "Register FUNCTION for a CLI hook callback ID before CLIENT connects.
FUNCTION receives INPUT, TOOL-USE-ID, and a context plist, and returns a
HOOK-CALLBACK-RESULT, a JSON hash table, or :CANCEL."
  (%register-named-control-handler client #'client-hook-callbacks callback-id function
                                   :register-hook-callback))

(defun register-sdk-mcp-handler (client server-name function)
  "Register FUNCTION for SDK MCP messages addressed to SERVER-NAME.
FUNCTION receives the decoded JSON-RPC message and returns an MCP-CONTROL-RESULT
or raw JSON object."
  (%register-named-control-handler client #'client-mcp-handlers server-name function
                                   :register-sdk-mcp-handler))

(defun make-claude-sdk-client (&key options transport cli-path timeout control-handlers)
  "Construct an interactive client.

With no injected TRANSPORT, provision Claude Code's persistent stream-json
subprocess using explicit CLI-PATH first and PATH discovery second."
  (unless (or (null options) (typep options 'agent-options))
    (signal-sdk-input-error "client options must be an agent-options instance or NIL"))
  (let ((effective-options (or options (make-agent-options))))
    (%validate-control-handlers control-handlers)
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

(defun %client-normalize-control-result (request result)
  "Map typed permission results or raw JSON objects to CLI response data."
  (cond
    ((permission-result-allow-p result)
     (let ((data (%client-json-object
                  "behavior" "allow"
                  "updatedInput" (or (permission-result-allow-updated-input result)
                                      (gethash "input" request)))))
       (when (permission-result-allow-updated-permissions result)
         (setf (gethash "updatedPermissions" data)
               (mapcar #'permission-update->wire
                       (permission-result-allow-updated-permissions result))))
       data))
    ((permission-result-deny-p result)
     (let ((data (%client-json-object "behavior" "deny"
                                     "message" (permission-result-deny-message result))))
       (when (permission-result-deny-interrupt result)
         (setf (gethash "interrupt" data) t))
       data))
    ((hook-callback-result-p result)
     (let ((data (hook-callback-result-data result)))
       (if (hash-table-p data) data nil)))
    ((mcp-control-result-p result)
     (%client-json-object "mcp_response" (mcp-control-result-response result)))
    ((hash-table-p result) result)
    (t nil)))

(defun %client-registered-handler (client subtype request)
  "Return a direct handler or resolve a named hook/MCP handler from REQUEST."
  (or (cdr (assoc subtype (client-control-handlers client) :test #'equal))
      (cond
        ((equal subtype "hook_callback")
         (let ((callback (cdr (assoc (gethash "callback_id" request)
                                     (client-hook-callbacks client) :test #'equal))))
           (when callback
             (lambda (ignored)
               (declare (ignore ignored))
               (funcall callback (gethash "input" request)
                        (gethash "tool_use_id" request) '(:signal nil))))))
        ((equal subtype "mcp_message")
         (let ((handler (cdr (assoc (gethash "server_name" request)
                                    (client-mcp-handlers client) :test #'equal))))
           (when handler
             (lambda (ignored)
               (declare (ignore ignored))
               (let ((result (funcall handler (gethash "message" request))))
                 (if (mcp-control-result-p result)
                     result
                     (make-mcp-control-result :response result))))))))))

(defun %client-handle-control-request (client record)
  "Synchronously service one inbound CLI control request.

All outcomes are terminal on the wire: a missing/failed/cancelled handler emits
an error response, while a handler returning a JSON object emits success."
  (let* ((request-id (control-request-request-id record))
         (request (gethash "request" record))
         (subtype (and (hash-table-p request) (gethash "subtype" request)))
         (handler (and (hash-table-p request) (stringp subtype)
                       (%client-registered-handler client subtype request))))
    (when (stringp request-id)
      (when (gethash request-id (client-handled-control-requests client))
        (%client-control-response client request-id "error" :error "duplicate control request")
        (return-from %client-handle-control-request nil))
      (setf (gethash request-id (client-handled-control-requests client)) t))
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
           (let* ((response (funcall handler request))
                  (wire-response (%client-normalize-control-result request response)))
             (if (eq response :cancel)
                 (%client-control-response client request-id "error" :error "control request cancelled")
                 (if wire-response
                     (%client-control-response client request-id "success" :response wire-response)
                     (%client-control-response client request-id "error"
                                               :error "control handler must return a permission result, hash table, or :cancel"))))
         (error (condition)
           (%client-control-response client request-id "error" :error (princ-to-string condition))))))))

(defun %client-handle-control-cancel (record)
  "Consume a late control cancellation in the synchronous client model."
  (emit-transport-log :client.control.cancel :record record
                       :request-id (gethash "request_id" record)))

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
        (:cancel
         (%client-handle-control-cancel record))
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
        (:cancel (%client-handle-control-cancel record))
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
