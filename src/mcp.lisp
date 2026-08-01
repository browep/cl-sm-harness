(in-package #:claude-agent-sdk-cl)

;;;; In-process SDK MCP definitions. These values are process-local: only server
;;;; metadata crosses the CLI argv boundary; tool schemas are served later over
;;;; the persistent mcp_message control plane.

(defun %nonempty-string-or-error (value label)
  (unless (and (stringp value)
               (> (length (string-trim '(#\Space #\Tab #\Newline) value)) 0))
    (signal-sdk-input-error (format nil "~A must be a non-empty string" label)))
  value)

(defun %json-compatible-p (value)
  "True when VALUE is representable by YASON without exposing Lisp objects."
  (cond
    ((or (null value) (stringp value) (numberp value) (eq value t)
         (eq value 'yason:true) (eq value 'yason:false) (eq value 'yason:null)) t)
    ((hash-table-p value)
     (loop for key being the hash-keys of value using (hash-value nested)
           always (and (stringp key) (%json-compatible-p nested))))
    ((listp value) (every #'%json-compatible-p value))
    (t nil)))

(defun %copy-json-compatible (value)
  "Copy JSON data recursively so a session catalog cannot be mutated externally."
  (cond
    ((hash-table-p value)
     (let ((copy (make-hash-table :test #'equal)))
       (maphash (lambda (key nested)
                  (setf (gethash key copy) (%copy-json-compatible nested)))
                value)
       copy))
    ((listp value) (mapcar #'%copy-json-compatible value))
    (t value)))

(defparameter +sdk-tool-annotation-keys+
  '(:read-only-p :destructive-p :idempotent-p :open-world-p)
  "The only keys MAKE-SDK-TOOL's :ANNOTATIONS plist recognizes, mapped to the
standard MCP ToolAnnotations wire object by %SDK-TOOL-ANNOTATIONS->MCP
(readOnlyHint, destructiveHint, idempotentHint, openWorldHint respectively).")

(defun %validate-sdk-tool-annotations (annotations)
  "ANNOTATIONS is NIL or a plist using only +SDK-TOOL-ANNOTATION-KEYS+, each
value NIL or a boolean. NIL (the default) advertises no annotations at all,
distinct from a key present with value NIL, which advertises that hint as
explicitly false on the wire (see %SDK-TOOL-ANNOTATIONS->MCP)."
  (when annotations
    (unless (and (listp annotations) (evenp (length annotations)))
      (signal-sdk-input-error "SDK tool annotations must be a plist"))
    (loop for (key value) on annotations by #'cddr
          do (unless (member key +sdk-tool-annotation-keys+)
               (signal-sdk-input-error
                (format nil "Unknown SDK tool annotation key: ~S" key)))
             (unless (typep value 'boolean)
               (signal-sdk-input-error
                (format nil "SDK tool annotation ~S must be a boolean" key)))))
  annotations)

(defstruct (sdk-tool (:constructor %make-sdk-tool))
  name description input-schema handler annotations)

(defun make-sdk-tool (&key name description input-schema handler annotations)
  "Create one synchronous, in-process SDK MCP tool definition.

HANDLER receives JSON-compatible arguments and a context plist. It runs as
application code in the client control path; the SDK does not sandbox it.

ANNOTATIONS is NIL (the default, meaning: advertise nothing) or a plist with
only :READ-ONLY-P, :DESTRUCTIVE-P, :IDEMPOTENT-P, :OPEN-WORLD-P keys, each a
boolean. These map to the MCP-standard ToolAnnotations object
(readOnlyHint/destructiveHint/idempotentHint/openWorldHint) served in this
tool's tools/list entry -- see %SDK-MCP-TOOL-LIST. :READ-ONLY-P T is what a
conforming MCP client (including the real `claude` CLI) uses to decide a
tool call is safe to run concurrently with other calls; this client's own
belt-and-suspenders enforcement of that same policy lives in CLIENT.LISP's
TOOL-EXECUTION-LOCK and MAKE-SDK-MCP-HANDLER's :SERIALIZATION-LOCK."
  (%nonempty-string-or-error name "SDK tool name")
  (%nonempty-string-or-error description "SDK tool description")
  (unless (and (hash-table-p input-schema) (%json-compatible-p input-schema))
    (signal-sdk-input-error "SDK tool input-schema must be a JSON-compatible object"))
  (unless (functionp handler)
    (signal-sdk-input-error "SDK tool handler must be a function"))
  (%validate-sdk-tool-annotations annotations)
  (%make-sdk-tool :name name :description description
                  :input-schema (%copy-json-compatible input-schema) :handler handler
                  :annotations (copy-list annotations)))

(defstruct (sdk-mcp-server (:constructor %make-sdk-mcp-server))
  name (version "1.0.0" :type string) tools)

(defun make-sdk-mcp-server (&key name (version "1.0.0") (tools '()))
  "Create a validated SDK-hosted MCP server catalog for one client session."
  (%nonempty-string-or-error name "SDK MCP server name")
  (%nonempty-string-or-error version "SDK MCP server version")
  (unless (and (listp tools) (every #'sdk-tool-p tools))
    (signal-sdk-input-error "SDK MCP server tools must be a list of SDK tools"))
  (let ((names (mapcar #'sdk-tool-name tools)))
    (unless (= (length names) (length (remove-duplicates names :test #'equal)))
      (signal-sdk-input-error "SDK MCP server tool names must be unique")))
  (%make-sdk-mcp-server :name name :version version :tools (copy-list tools)))

(defstruct (sdk-tool-result (:constructor %make-sdk-tool-result))
  text content (is-error nil :type boolean))

(defun make-sdk-tool-result (&key text content (is-error nil))
  "Construct an MCP-compatible result.

TEXT becomes one MCP text content item. CONTENT is an explicit JSON-compatible
MCP content list escape hatch. Exactly one of TEXT or CONTENT is required."
  (unless (typep is-error 'boolean)
    (signal-sdk-input-error "SDK tool result is-error must be boolean"))
  (unless (or (and (stringp text) (null content))
              (and (null text) (listp content) (%json-compatible-p content)))
    (signal-sdk-input-error "SDK tool result requires text or JSON-compatible content"))
  (%make-sdk-tool-result :text text
                         :content (and content (%copy-json-compatible content))
                         :is-error is-error))

(defun snapshot-sdk-mcp-server (server)
  "Freeze SERVER's metadata and handlers for one persistent client lifetime."
  (unless (sdk-mcp-server-p server)
    (signal-sdk-input-error "SDK MCP server snapshot requires an SDK MCP server"))
  (%make-sdk-mcp-server
   :name (sdk-mcp-server-name server)
   :version (sdk-mcp-server-version server)
   :tools (mapcar (lambda (tool)
                    (%make-sdk-tool :name (sdk-tool-name tool)
                                    :description (sdk-tool-description tool)
                                    :input-schema (%copy-json-compatible
                                                   (sdk-tool-input-schema tool))
                                    :handler (sdk-tool-handler tool)
                                    :annotations (copy-list (sdk-tool-annotations tool))))
                  (sdk-mcp-server-tools server))))

(defun sdk-mcp-server->cli-config (server)
  "Return only serializable metadata for --mcp-config; handlers never leave Lisp."
  (let ((config (make-hash-table :test #'equal)))
    (setf (gethash "type" config) "sdk"
          (gethash "name" config) (sdk-mcp-server-name server))
    config))

(defun sdk-mcp-servers->cli-config (servers)
  (let ((mcp-servers (make-hash-table :test #'equal))
        (configuration (make-hash-table :test #'equal)))
    (dolist (server servers)
      (setf (gethash (sdk-mcp-server-name server) mcp-servers)
            (sdk-mcp-server->cli-config server)))
    (setf (gethash "mcpServers" configuration) mcp-servers)
    configuration))

(defun sdk-mcp-config-json (servers)
  "Encode metadata-only server configuration as one shell-free argv value."
  (with-output-to-string (stream)
    (yason:encode (sdk-mcp-servers->cli-config servers) stream)))

(defun %sdk-mcp-qualified-tool-name (server-name tool-name)
  (format nil "mcp__~A__~A" server-name tool-name))

(defun %validate-sdk-mcp-servers (servers)
  (unless (and (listp servers) (every #'sdk-mcp-server-p servers))
    (signal-sdk-input-error "sdk-mcp-servers must be a list of SDK MCP servers"))
  (let ((server-names (mapcar #'sdk-mcp-server-name servers))
        (qualified-tool-names
          (loop for server in servers append
                (mapcar (lambda (tool)
                          (%sdk-mcp-qualified-tool-name
                           (sdk-mcp-server-name server) (sdk-tool-name tool)))
                        (sdk-mcp-server-tools server)))))
    (unless (= (length server-names)
               (length (remove-duplicates server-names :test #'equal)))
      (signal-sdk-input-error "SDK MCP server names must be unique"))
    ;; The CLI dispatches these flattened names. Distinct server/tool pairs can
    ;; otherwise collide when either component contains a double underscore.
    (unless (= (length qualified-tool-names)
               (length (remove-duplicates qualified-tool-names :test #'equal)))
      (signal-sdk-input-error "SDK MCP qualified tool names must be unique")))
  servers)

(defun %normalize-builtin-tools (value)
  (cond
    ((member value '(:default :none)) value)
    ((and (listp value) (every (lambda (name)
                                 (and (stringp name) (> (length name) 0)))
                               value))
     (copy-list value))
    (t (signal-sdk-input-error
        "builtin-tools must be :default, :none, or a list of non-empty strings"))))

(defun builtin-tools->cli-value (value)
  (etypecase value
    (symbol (ecase value (:default "default") (:none "")))
    (list (format nil "~{~A~^,~}" value))))

(defun %mcp-object (&rest pairs)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key object) value))
    object))

(defun %sdk-mcp-jsonrpc-response (message &key result error)
  (let ((response (%mcp-object "jsonrpc" "2.0" "id" (gethash "id" message))))
    (if error
        (setf (gethash "error" response) error)
        (setf (gethash "result" response) result))
    response))

(defun %sdk-mcp-jsonrpc-error (message code text)
  (%sdk-mcp-jsonrpc-response message
                             :error (%mcp-object "code" code "message" text)))

(defun %sdk-mcp-tool-by-name (server name)
  (find name (sdk-mcp-server-tools server) :key #'sdk-tool-name :test #'equal))

(defun %sdk-tool-annotation-wire-key (key)
  (ecase key
    (:read-only-p "readOnlyHint")
    (:destructive-p "destructiveHint")
    (:idempotent-p "idempotentHint")
    (:open-world-p "openWorldHint")))

(defun %sdk-tool-annotations->mcp (annotations)
  "Translate an SDK-TOOL's :ANNOTATIONS plist to an MCP ToolAnnotations wire
object, or NIL when ANNOTATIONS has nothing to say (the MCP spec's
annotations object is fully optional; omit it rather than sending an empty
one). Only keys actually present in ANNOTATIONS are emitted -- a key with an
explicit NIL value still emits its hint as wire `false`, not absence, since
YASON encodes a bare Lisp NIL as JSON null; 'YASON:FALSE is this codebase's
existing convention for an explicit JSON false (see %JSON-COMPATIBLE-P)."
  (when annotations
    (let ((object (%mcp-object)))
      (loop for (key value) on annotations by #'cddr
            do (setf (gethash (%sdk-tool-annotation-wire-key key) object)
                     (if value t 'yason:false)))
      object)))

(defun %sdk-tool-read-only-p (tool)
  "True only when TOOL's annotations explicitly declare :READ-ONLY-P T -- the
MCP-standard signal (mirrored by the real `claude` CLI's own
`isConcurrencySafe`/`isReadOnly` gate) that concurrent execution of this tool
alongside other calls is safe. Absent or false annotations are conservatively
not read-only."
  (eq t (getf (sdk-tool-annotations tool) :read-only-p)))

(defun %sdk-mcp-tool-list (server)
  (mapcar (lambda (tool)
            (let ((entry (%mcp-object "name" (sdk-tool-name tool)
                                      "description" (sdk-tool-description tool)
                                      "inputSchema" (sdk-tool-input-schema tool)))
                  (annotations (%sdk-tool-annotations->mcp (sdk-tool-annotations tool))))
              (when annotations
                (setf (gethash "annotations" entry) annotations))
              entry))
          (sdk-mcp-server-tools server)))

(defun %sdk-tool-result->mcp (result)
  (unless (sdk-tool-result-p result)
    (signal-sdk-input-error "SDK tool handler must return an SDK tool result"))
  (let ((payload (%mcp-object
                  "content" (or (sdk-tool-result-content result)
                                (list (%mcp-object "type" "text"
                                                   "text" (sdk-tool-result-text result)))))))
    (when (sdk-tool-result-is-error result)
      (setf (gethash "isError" payload) t))
    payload))

(defun %invoke-sdk-tool (tool arguments context)
  "Invoke application code without exposing its conditions on the protocol wire."
  (handler-case
      (%sdk-tool-result->mcp
       (funcall (sdk-tool-handler tool) arguments context))
    ;; Error detail can contain secrets, arguments, or implementation internals.
    ;; Do not catch non-error conditions such as implementation interrupts.
    (error () :sdk-tool-handler-failed)))

(defun %invoke-sdk-tool-serialized (tool arguments context serialization-lock)
  "Run %INVOKE-SDK-TOOL directly for a TOOL whose annotations declare it
read-only-safe; otherwise, when SERIALIZATION-LOCK is given, hold it for the
call's duration. This is the belt-and-suspenders half of this codebase's
concurrency-safety story (see MAKE-SDK-TOOL's :ANNOTATIONS docstring): a
non-read-only tool call physically cannot overlap another non-read-only call
through this client, regardless of what the CLI itself schedules or whether
it honors readOnlyHint at all. SERIALIZATION-LOCK is NIL for callers (tests,
%SDK-MCP-JSONRPC-* fixtures) that never plumb one through; in that case no
locking happens, matching this function's historical, always-synchronous
behavior."
  (if (and serialization-lock (not (%sdk-tool-read-only-p tool)))
      (sb-thread:with-mutex (serialization-lock)
        (%invoke-sdk-tool tool arguments context))
      (%invoke-sdk-tool tool arguments context)))

(defun handle-sdk-mcp-message (server message &key context serialization-lock)
  "Synchronously handle the tools-only MCP JSON-RPC surface for SERVER.

The caller owns application handlers. This router preserves request IDs and maps
bad methods/parameters to JSON-RPC errors without ending the client session.

SERIALIZATION-LOCK, when given, is held around a tools/call invocation unless
the resolved tool's annotations declare it read-only-safe -- see
%INVOKE-SDK-TOOL-SERIALIZED. It has no effect on any other method."
  (unless (hash-table-p message)
    (return-from handle-sdk-mcp-message
      (%sdk-mcp-jsonrpc-error (make-hash-table :test #'equal) -32600
                              "MCP message must be an object")))
  (let ((method (gethash "method" message))
        (params (or (gethash "params" message) (%mcp-object))))
    (unless (stringp method)
      (return-from handle-sdk-mcp-message
        (%sdk-mcp-jsonrpc-error message -32600 "MCP message is missing method")))
    (cond
      ((equal method "initialize")
       (%sdk-mcp-jsonrpc-response
        message
        :result (%mcp-object
                 "protocolVersion" "2024-11-05"
                 "capabilities" (%mcp-object "tools" (%mcp-object))
                 "serverInfo" (%mcp-object "name" (sdk-mcp-server-name server)
                                            "version" (sdk-mcp-server-version server)))))
      ((equal method "notifications/initialized")
       (%sdk-mcp-jsonrpc-response message :result (%mcp-object)))
      ((equal method "tools/list")
       (%sdk-mcp-jsonrpc-response message
                                  :result (%mcp-object "tools" (%sdk-mcp-tool-list server))))
      ((equal method "tools/call")
       (unless (hash-table-p params)
         (return-from handle-sdk-mcp-message
           (%sdk-mcp-jsonrpc-error message -32602 "tools/call params must be an object")))
       (let* ((name (gethash "name" params))
              (arguments (or (gethash "arguments" params) (%mcp-object)))
              (tool (and (stringp name) (%sdk-mcp-tool-by-name server name))))
         (unless tool
           (return-from handle-sdk-mcp-message
             (%sdk-mcp-jsonrpc-error message -32602
                                     (format nil "SDK tool was not found: ~A" name))))
         (unless (hash-table-p arguments)
           (return-from handle-sdk-mcp-message
             (%sdk-mcp-jsonrpc-error message -32602 "tools/call arguments must be an object")))
         (let ((result (%invoke-sdk-tool-serialized
                        tool arguments
                        (append context (list :server-name (sdk-mcp-server-name server)
                                              :tool-name (sdk-tool-name tool)))
                        serialization-lock)))
           (if (eq result :sdk-tool-handler-failed)
               (%sdk-mcp-jsonrpc-error message -32603 "SDK tool handler failed")
               (%sdk-mcp-jsonrpc-response message :result result)))))
      (t (%sdk-mcp-jsonrpc-error message -32601
                                 (format nil "MCP method not found: ~A" method))))))

(defun make-sdk-mcp-handler (server &key serialization-lock)
  "Return the frozen MCP-envelope handler closure used by an interactive client.

SERIALIZATION-LOCK, when given, is CLIENT.LISP's per-client
TOOL-EXECUTION-LOCK, threaded through to HANDLE-SDK-MCP-MESSAGE so a
tools/call for a non-read-only tool stays serialized against every other
non-read-only tools/call on the same client even though the client's own
control-request read loop no longer blocks on tool execution (see
%CLIENT-HANDLE-CONTROL-REQUEST's mcp_message thread-spawn)."
  (lambda (message)
    ;; Preserve the existing shared control-plane envelope convention.
    (make-mcp-control-result
     :response (handle-sdk-mcp-message server message :context '(:signal nil)
                                        :serialization-lock serialization-lock))))
