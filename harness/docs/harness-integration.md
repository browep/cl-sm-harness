# Integrating `claude-agent-sdk-cl` into a Common Lisp harness

This guide is for a harness that wants to drive an installed **Claude Code CLI**
from Common Lisp. It covers the supported public API, cleanup rules, deterministic
tests, and copyable adapters.

> **Boundary:** this library starts `claude` as a subprocess and exchanges the
> Claude Code `stream-json` protocol over JSONL. It is **not** an Anthropic
> Messages HTTP client, and it does not read or manage API credentials. It does
> not implement a second provider protocol. CLI authentication remains the
> responsibility of the installed `claude` executable.

## Contents

- [Install and verify](#install-and-verify)
- [One-shot turns](#one-shot-turns)
- [Interactive multi-turn clients](#interactive-multi-turn-clients)
- [Options](#options)
- [Messages and result mapping](#messages-and-result-mapping)
- [Permissions, hooks, and SDK MCP tools](#permissions-hooks-and-sdk-mcp-tools)
- [Errors, timeouts, and ownership](#errors-timeouts-and-ownership)
- [Session-store adapters](#session-store-adapters)
- [Offline harness tests and custom transports](#offline-harness-tests-and-custom-transports)
- [Complete thin adapter](#complete-thin-adapter)
- [Public API map](#public-api-map)
- [Production checklist and current limits](#production-checklist-and-current-limits)

The runnable, side-effect-free function definitions referenced below are in
[`examples/harness/`](../examples/harness/). They load the ASDF system but do
not make a provider call merely by being loaded.

## Install and verify

### ASDF source dependency

The system name is `:claude-agent-sdk-cl`; its declared dependency is `yason`.
Place this checkout where ASDF can discover it (for example in an ASDF source
registry) and load it:

```lisp
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)
(format t "SDK version: ~A~%" (claude-agent-sdk-cl:sdk-version))
```

For a checkout-local invocation, an implementation can set an ASDF source
registry before starting Lisp:

```sh
export CL_SOURCE_REGISTRY="$PWD//:${CL_SOURCE_REGISTRY:-}"
sbcl --non-interactive \
  --eval '(require :asdf)' \
  --eval '(asdf:load-system :claude-agent-sdk-cl)'
```

The library resolves the executable in this order:

1. an explicit `:cli-path` passed to `query` or `make-claude-sdk-client`;
2. an executable named `claude` on `PATH`;
3. otherwise it signals `cli-not-found-error`.

See [CLI provisioning](cli-provisioning.md) for the precise discovery contract.
Do not put credentials in Lisp source, fixtures, or offline test commands. For
this repository's opt-in Docker live smoke, authentication is supplied to the
CLI with `CLAUDE_CODE_OAUTH_TOKEN`; an ordinary production harness should use
whatever authenticated CLI installation it intentionally owns.

## One-shot turns

Use `query` when one prompt maps to one short-lived CLI subprocess. It returns
an ordered list of typed public events and always closes the transport:

```lisp
(claude-agent-sdk-cl:query
 "Answer with one sentence."
 :options (claude-agent-sdk-cl:make-agent-options
           :model "sonnet"
           :system-prompt "You are a concise harness worker.")
 :cli-path "/usr/local/bin/claude"
 :timeout 60)
```

`query` accepts:

| Keyword | Meaning |
|---|---|
| `:options` | An `agent-options` instance. Defaults to `(make-agent-options)` for the built-in subprocess transport. |
| `:transport` | A `query-transport` implementation. This is the deterministic-test/extension seam; see [offline tests](#offline-harness-tests-and-custom-transports). |
| `:on-message` | Synchronous `(lambda (message) ...)` callback invoked for each public event. Return `:cancel` to stop reading immediately. |
| `:cli-path` | Explicit executable path; preferred when the harness owns an exact CLI installation. |
| `:timeout` | `NIL` or a positive number of seconds. For the default one-shot subprocess it bounds the complete query. |

### Stream into a harness event sink and cancel deliberately

The callback is the backpressure point: the SDK will not read the next chunk
until it returns. Returning `:cancel` makes `query` return events already seen;
it closes the subprocess transport with cancel semantics.

```lisp
(defun run-one-shot (prompt publish-event &key cancel-p)
  (claude-agent-sdk-cl:query
   prompt
   :options (claude-agent-sdk-cl:make-agent-options
             :allowed-tools '("Read")
             :disallowed-tools '("Write" "Bash")
             :permission-mode "default")
   :on-message (lambda (message)
                 (funcall publish-event message)
                 ;; Only a genuine harness policy cancels an in-flight stream.
                 ;; Let a normal result record reach EOF naturally.
                 (when (and cancel-p (funcall cancel-p message)) :cancel))
   :timeout 90))
```

A one-shot query does **not** require a caller-side `unwind-protect`: its
transport/router cleanup is internal. Do still catch its conditions at the
harness boundary; examples appear in [errors](#errors-timeouts-and-ownership).

## Interactive multi-turn clients

Use a `claude-sdk-client` when the harness needs one persistent CLI process for
several turns. The lifecycle is strict:

```text
:new --connect--> :connected --disconnect/EOF--> :closed
```

Call `receive-response` after every `send`. It returns all public events through
and including the next `result-message`; the client remains connected for the
next turn. `receive-message` instead returns exactly one public event (or `NIL`
at terminal EOF).

Use `receive-response` when a harness persists or judges one complete turn at a
time. Use `receive-message` when it must publish each public event immediately;
the following loop preserves the same terminal boundary explicitly:

```lisp
(defun receive-one-turn-as-events (client emit)
  (loop for message = (claude-agent-sdk-cl:receive-message client)
        while message
        do (funcall emit message)
        when (typep message 'claude-agent-sdk-cl:result-message)
          do (return message)))
```

```lisp
(let ((client (claude-agent-sdk-cl:make-claude-sdk-client
               :options (claude-agent-sdk-cl:make-agent-options :model "sonnet")
               :cli-path "/usr/local/bin/claude")))
  (unwind-protect
       (progn
         (claude-agent-sdk-cl:connect client)
         (dolist (prompt '("Remember the color blue."
                           "What color did I ask you to remember?"))
           (claude-agent-sdk-cl:send client prompt :session-id "harness-run-42")
           (dolist (message (claude-agent-sdk-cl:receive-response client))
             (format t "~S~%" message))))
    ;; Safe after an error, EOF, or an earlier disconnect.
    (claude-agent-sdk-cl:disconnect client)))
```

`interrupt` sends and correlates the CLI interrupt control request. It does not
discard the client automatically; a connected client can receive a later turn:

```lisp
(claude-agent-sdk-cl:send client "Perform the long task.")
(claude-agent-sdk-cl:interrupt client) ; waits for its correlated control reply
;; Consume remaining public records through the interrupted turn's result.
(claude-agent-sdk-cl:receive-response client)
;; The persistent stream is still usable if the CLI remains connected.
(claude-agent-sdk-cl:send client "Give a concise status instead.")
(claude-agent-sdk-cl:receive-response client)
```

### Client ownership and concurrency

The SDK serializes writes to a client, preventing interleaved JSONL frames. That
is not permission to have multiple workers consume one response stream. Give a
connected client one harness owner, serialize **turns** as `send` then
`receive-response`, and use one client per concurrent conversation. Always put
`disconnect` in `unwind-protect`; it is idempotent and terminates a still-running
direct child.

Calling `send`, `receive-message`, `receive-response`, or `interrupt` before
`connect`, or calling `connect` twice, signals `client-lifecycle-error`.

## Options

Create options only with `make-agent-options`. The current supported keywords
are below. The default subprocess projects the applicable options to Claude Code
CLI flags and JSONL initialization; a custom transport receives the object and
may interpret it itself.

```lisp
(defparameter *worker-options*
  (claude-agent-sdk-cl:make-agent-options
   :allowed-tools '("Read" "Glob")
   :disallowed-tools '("Write" "Bash")
   :permission-mode "default"
   :continue-conversation nil
   :model "sonnet"
   :system-prompt "Return only the requested harness result."
   :resume nil))
```

| Keyword | Type / behavior |
|---|---|
| `:allowed-tools`, `:disallowed-tools` | Lists of strings. They map to Claude Code tool **permission** flags. Distinct from built-in availability. |
| `:builtin-tools` | Built-in **availability**: `:default` (omit CLI override), `:none` (no built-ins), or an explicit non-empty string list. Maps to `--tools`. |
| `:sdk-mcp-servers` | List of `sdk-mcp-server` catalogs for in-process tools. Metadata-only on the CLI; handlers stay in Lisp. Persistent-client only. |
| `:strict-mcp-config` | Boolean. When true, exclude ambient user/project/plugin MCP configuration (`--strict-mcp-config`). |
| `:permission-mode` | String or `NIL`. Pass the exact Claude Code permission mode intended by the harness. |
| `:continue-conversation` | Boolean. Enables CLI continuation. |
| `:model` | String or `NIL`. |
| `:system-prompt` | Optional string. |
| `:resume` | Traversal-safe, non-empty session identifier or `NIL`; maps to CLI resume. |
| `:session-store` | A local `session-store` object used by the harness's own adapter; it is **not automatically wired** into `query` or the client. |
| `:session-store-list-sessions-p` | Boolean capability declaration used to validate store-backed continuation. |
| `:enable-file-checkpointing` | Boolean configuration validation field. |
| `:session-path` | Traversal-safe local import/export path configuration. |

Validation is performed before a default transport is constructed:

- tool lists must be lists of strings;
- `:builtin-tools` must be `:default`, `:none`, or a list of non-empty strings;
- `:sdk-mcp-servers` must be unique server names with unique qualified tool names
  (`mcp__<server>__<tool>`); catalogs are **frozen** when options are built;
- `:strict-mcp-config` must be boolean;
- one-shot `query` **rejects** `:sdk-mcp-servers` because it has no inbound
  control loop to service tool calls;
- `:resume` and `:session-path` reject empty, control-character, and traversal
  paths;
- a `:session-store` cannot be combined with `:enable-file-checkpointing t`;
- a store-backed `:continue-conversation t` requires either an explicit
  `:resume` or `:session-store-list-sessions-p t`.

This is the CLI continuation/resume configuration shape; the local store remains
harness-owned and is not implicitly connected to it:

```lisp
(claude-agent-sdk-cl:make-agent-options
 :continue-conversation t
 :resume "existing-cli-session-id"
 :model "sonnet")
```

`make-session-import-plan` and `make-session-mutation-plan` validate local
session-management intent without doing I/O. They are plans for a harness/store
adapter, not a CLI command executor.

```lisp
(let ((import (claude-agent-sdk-cl:make-session-import-plan
               :session-id "run-42" :path "imports/run-42.jsonl"))
      (rename (claude-agent-sdk-cl:make-session-mutation-plan
               :operation :rename :session-id "run-42" :value "baseline")))
  (list (claude-agent-sdk-cl:session-import-plan-session-id import)
        (claude-agent-sdk-cl:session-import-plan-path import)
        (claude-agent-sdk-cl:session-mutation-plan-operation rename)))
```

## Messages and result mapping

Both `query` and interactive receive functions yield ordered typed objects. Do
not assume an assistant response is a string: `assistant-message-content` is a
list of typed blocks.

```lisp
(defun text-from-assistant (message)
  (check-type message claude-agent-sdk-cl:assistant-message)
  (with-output-to-string (output)
    (dolist (block (claude-agent-sdk-cl:assistant-message-content message))
      (typecase block
        (claude-agent-sdk-cl:text-block
         (write-string (claude-agent-sdk-cl:text-block-text block) output))
        ;; Preserve/route these according to harness policy rather than silently
        ;; treating them as assistant prose.
        (claude-agent-sdk-cl:thinking-block
         (format output "[thinking omitted]"))
        (claude-agent-sdk-cl:tool-use-block
         (format output "[tool request ~A]"
                 (claude-agent-sdk-cl:tool-use-block-name block)))
        (claude-agent-sdk-cl:tool-result-block
         (format output "[tool result ~A]"
                 (claude-agent-sdk-cl:tool-result-block-tool-use-id block)))
        (t
         (format output "[unknown content block]"))))))

(defun publish-sdk-message (message emit)
  (typecase message
    (claude-agent-sdk-cl:assistant-message
     (funcall emit :assistant-text (text-from-assistant message)))
    (claude-agent-sdk-cl:result-message
     (funcall emit :terminal
              (list :subtype (claude-agent-sdk-cl:result-message-subtype message)
                    :is-error (claude-agent-sdk-cl:result-message-is-error message)
                    :stop-reason (claude-agent-sdk-cl:result-message-stop-reason message)
                    :text (claude-agent-sdk-cl:result-message-result message)
                    :cost-usd (claude-agent-sdk-cl:result-message-total-cost-usd message)
                    :usage (claude-agent-sdk-cl:result-message-usage message))))
    (claude-agent-sdk-cl:system-message
     (funcall emit :system
              (list :subtype (claude-agent-sdk-cl:system-message-subtype message)
                    :data (claude-agent-sdk-cl:system-message-data message))))
    (claude-agent-sdk-cl:rate-limit-event
     (let ((limit (claude-agent-sdk-cl:rate-limit-event-rate-limit-info message)))
       (funcall emit :rate-limit
                (list :status (claude-agent-sdk-cl:rate-limit-info-status limit)
                      :utilization (claude-agent-sdk-cl:rate-limit-info-utilization limit)
                      :resets-at (claude-agent-sdk-cl:rate-limit-info-resets-at limit)))))
    (claude-agent-sdk-cl:user-message
     (funcall emit :user-echo message))
    (t
     (funcall emit :unrecognized message))))
```

Relevant block readers are `text-block-text`; `thinking-block`'s type is
public but its slot readers are not exported. Tool lifecycle readers **are**
exported: `tool-use-block-id`, `tool-use-block-name`, `tool-use-block-input`,
`tool-result-block-tool-use-id`, `tool-result-block-content`, and
`tool-result-block-is-error`. `message-extra` preserves unknown top-level fields
for decoded assistant/user messages. A `system-message` retains its complete raw
record in `data`.

## Permissions, hooks, and SDK MCP tools

Only the persistent client services inbound control requests. Configure handlers
and session-start catalogs before `connect`; registration is frozen after
connect.

**Execution model (#123).** Every control subtype except `mcp_message`
(`can_use_tool`, `hook_callback`, `initialize`/`interrupt` acks, ...) still
runs fully synchronously and in-line on the client's single reader thread,
exactly as before #123: the read loop cannot see the next inbound record
until that handler returns. An `mcp_message` `tools/call`, in contrast, runs
on its own freshly spawned thread so a slow or blocking tool handler cannot
stall delivery of other queued control requests or public events; the
reader loop spawns it and moves straight on. Concurrency *safety* between
simultaneous tool calls is a separate, deliberate guarantee, not left to
the CLI's own scheduling: the client holds one `tool-execution-lock` mutex
per connection and acquires it for a tool call's duration unless that
tool's own `:annotations` say `:read-only-p t` (see `make-sdk-tool` below),
so two non-read-only tool calls through one client can never actually
overlap in wall-clock execution, only two calls both marked read-only-safe
can. `disconnect` joins any still-running tool threads with a bounded grace
period and abandons (logging, never blocking indefinitely on) any
straggler.

### Session-start in-process SDK MCP catalogs (preferred)

Use typed catalogs when the harness owns Lisp tool implementations. Handlers
never leave the process; the CLI receives only metadata via `--mcp-config`.

```lisp
(let* ((lookup
         (claude-agent-sdk-cl:make-sdk-tool
          :name "lookup_order"
          :description "Look up one order by ID."
          :input-schema (let ((schema (make-hash-table :test #'equal)))
                          (setf (gethash "type" schema) "object")
                          schema)
          :handler (lambda (arguments context)
                     (declare (ignore context))
                     (claude-agent-sdk-cl:make-sdk-tool-result
                      :text (format nil "order ~A"
                                    (gethash "order_id" arguments))))
          ;; Optional (#123): a plist of :READ-ONLY-P/:DESTRUCTIVE-P/
          ;; :IDEMPOTENT-P/:OPEN-WORLD-P booleans, served as this tool's MCP
          ;; ToolAnnotations on the tools/list wire and used by this client's
          ;; own TOOL-EXECUTION-LOCK (see above). Defaults to NIL, i.e. no
          ;; annotations at all -- treated as not read-only-safe, the
          ;; conservative default.
          :annotations '(:read-only-p t :destructive-p nil
                         :idempotent-p t :open-world-p nil)))
       (server (claude-agent-sdk-cl:make-sdk-mcp-server
                :name "orders" :tools (list lookup)))
       (options (claude-agent-sdk-cl:make-agent-options
                 :builtin-tools :none
                 :sdk-mcp-servers (list server)
                 :strict-mcp-config t
                 :allowed-tools '("mcp__orders__lookup_order")))
       (client (claude-agent-sdk-cl:make-claude-sdk-client :options options)))
  (unwind-protect
       (progn
         (claude-agent-sdk-cl:connect client)
         (claude-agent-sdk-cl:send client "Look up order 42")
         (claude-agent-sdk-cl:receive-response client))
    (claude-agent-sdk-cl:disconnect client)))
```

Rules for this path:

- **Availability vs permission:** `:builtin-tools` / `:sdk-mcp-servers` /
  `:strict-mcp-config` control what tools can appear; `:allowed-tools`,
  `:disallowed-tools`, and `can_use_tool` control invocation policy.
- **Qualified names:** the CLI wire name is `mcp__<server>__<tool>`.
- **Freeze:** catalogs snapshot at `make-agent-options`; mutate caller schemas
  afterward does not change the session.
- **Resume:** a replacement client with `:resume` must supply the catalog again.
- **No query:** one-shot `query` rejects SDK MCP catalogs.
- **No shadowing:** do not combine a session catalog with a generic
  `mcp_message` control handler or replace a configured server name via
  `register-sdk-mcp-handler`.
- **Handlers:** must return `sdk-tool-result` text or JSON-compatible content.
  Errors become a safe JSON-RPC `-32603` without leaking condition text.
- **Annotations (#123):** `:annotations` is optional and defaults to NIL
  (no hints advertised, conservatively not read-only-safe). Only
  `:read-only-p t` changes this client's own execution behavior (see above);
  the other three keys are advertised on the wire for a conforming MCP
  client's benefit but are not otherwise interpreted here.
- **Out of v1 scope:** async handlers, external stdio/SSE/HTTP MCP, binary or
  size-managed content, and schema inference.

See [`examples/harness/10-session-start-sdk-mcp.lisp`](../examples/harness/10-session-start-sdk-mcp.lisp)
for a load-safe catalog builder.

### Generic permission handler

```lisp
(defun allow-read-only-tool (request)
  (let ((tool-name (gethash "tool_name" request)))
    (if (member tool-name '("Read" "Glob") :test #'string=)
        (claude-agent-sdk-cl:make-permission-result-allow)
        (claude-agent-sdk-cl:make-permission-result-deny
         :message (format nil "Harness policy denies ~A" tool-name)
         :interrupt nil))))

(defparameter *client*
  (claude-agent-sdk-cl:make-claude-sdk-client
   :control-handlers (list (cons "can_use_tool" #'allow-read-only-tool))))
```

A generic control handler receives the decoded request hash table and may return:

- `permission-result-allow` (optionally `:updated-input` and
  `:updated-permissions`);
- `permission-result-deny` (`:message`, optionally `:interrupt t`);
- `hook-callback-result` containing a JSON hash table;
- `mcp-control-result` containing a JSON-RPC response hash table;
- a raw JSON hash table; or
- `:cancel`.

Missing handlers, exceptions, invalid values, cancellation, and duplicate
request IDs receive correlated CLI error responses; the outer turn continues if
the CLI continues.

### Named hook and SDK MCP handlers

```lisp
(let ((client (claude-agent-sdk-cl:make-claude-sdk-client)))
  (claude-agent-sdk-cl:register-hook-callback
   client "before-tool"
   (lambda (input tool-use-id context)
     (declare (ignore input tool-use-id context))
     (claude-agent-sdk-cl:make-hook-callback-result
      :data (let ((reply (make-hash-table :test #'equal)))
              (setf (gethash "continue" reply) t)
              reply))))
  (claude-agent-sdk-cl:register-sdk-mcp-handler
   client "harness-tools"
   (lambda (json-rpc-message)
     (let ((reply (make-hash-table :test #'equal)))
       ;; Preserve the peer request ID for JSON-RPC correlation.
       (setf (gethash "jsonrpc" reply) "2.0"
             (gethash "id" reply) (gethash "id" json-rpc-message)
             (gethash "result" reply) (make-hash-table :test #'equal))
       (claude-agent-sdk-cl:make-mcp-control-result :response reply))))
  client)
```

These APIs respond to inbound CLI control records. Prefer
**session-start SDK MCP catalogs** (above) for typed in-process tools. Use
`register-sdk-mcp-handler` only for low-level JSON-RPC control when the harness
does not own a session catalog. Neither path creates an external MCP server,
makes a general tool-loop abstraction, or lets one-shot `query` answer control
requests. Use an interactive client whenever the harness must answer control
traffic.

## Errors, timeouts, and ownership

All SDK-specific conditions inherit from `sdk-error`:

```text
sdk-error
├── sdk-input-error
├── cli-not-found-error
├── cli-connection-error
├── cli-json-error
├── process-error          ; readers: process-error-exit-code, process-error-stderr
└── client-lifecycle-error ; readers: client-lifecycle-error-operation/state
```

Catch conditions at the backend boundary and map them to your harness error
model. Do not log credentials or raw prompts merely because a child failed.

```lisp
(defun call-with-sdk-error-mapping (thunk)
  (handler-case
      (funcall thunk)
    (claude-agent-sdk-cl:sdk-input-error (condition)
      (list :kind :configuration :message (princ-to-string condition)))
    (claude-agent-sdk-cl:cli-not-found-error (condition)
      (list :kind :provisioning :message (princ-to-string condition)))
    (claude-agent-sdk-cl:cli-connection-error (condition)
      (list :kind :connection :message (princ-to-string condition)))
    (claude-agent-sdk-cl:cli-json-error (condition)
      (list :kind :protocol :message (princ-to-string condition)))
    (claude-agent-sdk-cl:process-error (condition)
      (list :kind :process
            :exit-code (claude-agent-sdk-cl:process-error-exit-code condition)
            :stderr (claude-agent-sdk-cl:process-error-stderr condition)))
    (claude-agent-sdk-cl:client-lifecycle-error (condition)
      (list :kind :lifecycle
            :operation (claude-agent-sdk-cl:client-lifecycle-error-operation condition)
            :state (claude-agent-sdk-cl:client-lifecycle-error-state condition)))))
```

The one-shot timeout is implemented by the default streaming subprocess. The
persistent client's `:timeout` is accepted and validated at construction but is
not yet a per-turn watchdog; enforce an outer harness deadline and call
`disconnect` on expiry. CLI descendant process-group cleanup is also a current
limitation: the SDK terminates its direct child, not a guaranteed complete tree.

## Session-store adapters

Session stores are an explicit local harness persistence interface. They are
not automatic transcript persistence for `query` or `claude-sdk-client`.
Choose a stable project key and opaque, traversal-safe session ID:

```lisp
(let* ((store (claude-agent-sdk-cl:make-in-memory-session-store))
       (key (claude-agent-sdk-cl:make-session-key
             :project-key "my-harness" :session-id "run-2026-07-26"))
       (entry (make-hash-table :test #'equal)))
  (setf (gethash "type" entry) "harness-event"
        (gethash "uuid" entry) "evt-001"
        (gethash "payload" entry) "durable metadata")
  (claude-agent-sdk-cl:session-store-append store key (list entry))
  (values (claude-agent-sdk-cl:session-store-load store key)
          (claude-agent-sdk-cl:session-store-list-sessions store "my-harness")
          (claude-agent-sdk-cl:session-store-list-subkeys store key)))
```

Duplicate entry UUIDs are idempotent per session key. The filesystem backend
uses JSONL only below its declared root:

```lisp
(let ((store (claude-agent-sdk-cl:make-filesystem-session-store
              :root #P"/var/lib/my-harness/claude-sessions/")))
  ;; Use the same session-store-* calls as the in-memory backend.
  store)
```

The store rejects unsafe project keys, session IDs, and subpaths. Do not use
user-controlled `../` segments as a storage identity. To implement another
backend, subclass `session-store` and implement the four exported generics:
`session-store-append`, `session-store-load`, `session-store-list-sessions`, and
`session-store-list-subkeys`.

`session-store-mirror-message` is a best-effort helper: it records a typed
message marker, isolates store errors through transport logging, and returns the
message. It does **not** serialize a full assistant transcript or guarantee
persistence. A production harness needing replay should serialize the data it
owns into its own JSON object with a stable UUID.

For a light-weight marker on every one-shot event, explicitly compose it at the
harness boundary:

```lisp
(claude-agent-sdk-cl:query
 prompt
 :options options
 :on-message (lambda (message)
               (claude-agent-sdk-cl:session-store-mirror-message store key message)
               (funcall publish-event message)))
```

## Offline harness tests and custom transports

Normal harness tests should not launch Claude or require credentials. Inject a
`query-transport` that supplies a fixed JSONL transcript. This is a public
extension seam:

```lisp
(defclass fixture-query-transport (claude-agent-sdk-cl:query-transport)
  ((chunks :initarg :chunks :accessor fixture-chunks)
   (started-p :initform nil)))

(defmethod claude-agent-sdk-cl:start-query-transport
    ((transport fixture-query-transport) prompt options)
  (declare (ignore prompt options))
  (setf (slot-value transport 'started-p) t)
  transport)

(defmethod claude-agent-sdk-cl:read-query-chunk
    ((transport fixture-query-transport))
  (pop (fixture-chunks transport)))

(defmethod claude-agent-sdk-cl:close-query-transport
    ((transport fixture-query-transport) &key reason)
  (declare (ignore reason))
  transport)
```

Then pass a transcript whose records end in newlines:

```lisp
(let ((transport
        (make-instance 'fixture-query-transport
                       :chunks (list
                                (format nil "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"offline\"}]}}~%")
                                (format nil "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"s\",\"result\":\"done\"}~%")))))
  (claude-agent-sdk-cl:query "ignored by this fixture" :transport transport))
```

For persistent-client tests, subclass `client-transport` and implement
`start-client-transport`, `read-client-chunk`, `write-client-input`, and
`close-client-transport`. The repository's `test/client.lisp` is a complete
offline fake-transport reference. For a standalone, load-safe version that
exercises the complete `connect` → `send` → `receive-response` → `disconnect`
lifecycle without launching Claude, see
[`examples/harness/09-fake-client-transport.lisp`](../examples/harness/09-fake-client-transport.lisp).

Repository verification commands are Docker-only:

```sh
# Full offline unit suite
docker compose run --rm test unit

# Fake CLI subprocess integration suite
docker compose run --rm test integration

# Load and exercise the credential-free harness examples
docker compose run --rm test examples

# Upstream catalog/manifest check
docker compose run --rm test parity

# Explicitly credential-gated smoke only
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm live live
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm live live-client
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm live live-terminate
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm live live-mcp
```

## Complete thin adapter

[`examples/harness/08-thin-adapter.lisp`](../examples/harness/08-thin-adapter.lisp)
contains a small `run-harness-turn` function. Its contract is deliberately
narrow:

1. construct an interactive client (optionally with a harness permission policy);
2. connect once;
3. send exactly one prompt;
4. map ordered public events to a harness event function;
5. return the terminal `result-message`; and
6. disconnect on every exit path.

Use that adapter as a boundary, not as a hidden global client. If a harness
needs conversation reuse, own the client alongside its conversation/session
record and serialize turns.

## Public API map

The public exports fall into the following groups. Accessors are listed where a
harness normally needs values; constructors/readers not listed here remain
exported for inspection and are discoverable from `src/packages.lisp`.

| Group | Use in a harness |
|---|---|
| Bootstrap | `sdk-version`. |
| One-shot API | `query`; `query-transport`, `start-query-transport`, `read-query-chunk`, `close-query-transport`. |
| Interactive API | `claude-sdk-client`, `make-claude-sdk-client`, `connect`, `send`, `receive-message`, `receive-response`, `interrupt`, `disconnect`, `client-state`; client transport generic functions. |
| Options and local session plans | `make-agent-options` plus `agent-options-*` readers (including `agent-options-builtin-tools`, `agent-options-sdk-mcp-servers`, `agent-options-strict-mcp-config`); `normalize-session-id`, `normalize-session-path`; `make-session-import-plan`, `make-session-mutation-plan` and their readers. |
| Session-start SDK MCP tools | `make-sdk-tool`, `sdk-tool` and readers; `make-sdk-mcp-server`, `sdk-mcp-server` and readers; `make-sdk-tool-result`, `sdk-tool-result` and readers; `agent-options->mcp-config`. |
| Messages | `message`, `user-message`, `assistant-message`, `message-extra`, `assistant-message-content`, `assistant-message-model`, `text-block`, `text-block-text`, `thinking-block`, `tool-use-block` (+ id/name/input readers), `tool-result-block` (+ tool-use-id/content/is-error readers); decoding helpers. |
| Terminal/system/quota records | `result-message` and all `result-message-*` readers; `system-message`, `system-message-subtype`, `system-message-data`; `rate-limit-event`, `rate-limit-info`, and their readers. |
| Control callbacks | `register-control-handler`, `client-control-handlers`, `register-hook-callback`, `register-sdk-mcp-handler`; permission/hook/MCP result constructors and readers; permission update decoding/wire conversion. |
| Session storage | `session-key`, `make-session-key`, key readers; `session-store`, built-in stores, four store generics, and `session-store-mirror-message`. |
| Conditions | `sdk-error`, its concrete subclasses, condition readers, and the three explicit signal helpers. |

## Production checklist and current limits

Before enabling a provider-backed harness path:

- [ ] Pin or intentionally discover the `claude` executable; handle
  `cli-not-found-error` as a provisioning failure.
- [ ] Authenticate the CLI outside the source tree; do not expose a token in
  logs, reports, example code, or an offline test container.
- [ ] Give each live client one owner; serialize turns and always disconnect.
- [ ] Set an outer per-turn deadline for persistent clients and disconnect when
  it expires.
- [ ] Use explicit tool **availability** (`:builtin-tools`,
  `:sdk-mcp-servers`, `:strict-mcp-config`) separately from **permission**
  policy (`:allowed-tools` / `:disallowed-tools` / `can_use_tool`); never return
  unconditional permissions unless that is the product policy.
- [ ] Prefer session-start SDK MCP catalogs for in-process tools; rebuild the
  catalog on every replacement/resumed client.
- [ ] Persist only the data your harness intentionally owns; session-store
  mirroring is not full transcript archival.
- [ ] Keep fake JSONL transports in unit tests and reserve live smoke tests for
  a separately credential-scoped job.

Current scope is intentionally bounded. The library supports one-shot streamed
queries, persistent stream-json clients, typed public records (including tool
use/result readers), inbound control handlers, session-start in-process SDK MCP
tools, local session-store primitives, process-tree supervision/cleanup, and
fake transports. It does not bundle the CLI, provide HTTP Messages API access,
automatically mirror a full conversation to a store, make `query` answer inbound
control traffic, provide concurrent/async SDK tool handlers, external MCP
transports, or a persistent-client per-turn timeout. The
[API parity](api-parity.md) page and manifest track upstream parity
certification; their phase matrix may lag the implemented surface described in
this guide and the repository README.

### Python-to-Common-Lisp name map

The Python SDK is a behavioral reference, not a source-level compatibility
layer. Use the Common Lisp API in this library:

```lisp
;; Python `query`                 -> `claude-agent-sdk-cl:query`
;; Python `ClaudeSDKClient`       -> `make-claude-sdk-client` + lifecycle functions
;; Python async iteration         -> `:on-message` or `receive-message`
;; Python `tool` / `SdkMcpTool`   -> `make-sdk-tool`
;; Python `create_sdk_mcp_server` -> `make-sdk-mcp-server`
```
