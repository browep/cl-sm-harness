# sm-harness

Headless reusable session/tool runtime over `claude-agent-sdk-cl`.

## Load

```bash
# Offline unit tests (Docker)
docker compose run --rm sm-harness-test
```

## Façade

- `make-harness` / `close-harness`
- `start-session` / `list-sessions` / `open-session`
- `submit-turn` / `interrupt-turn`
- `attach-session-listener` / `detach-session-listener`

Uses merged session-start SDK MCP catalogs (`make-sdk-tool`, `:builtin-tools`, `:strict-mcp-config`) only inside `sdk-adapter.lisp`.

## Product tool catalog

`sm-harness/src/tool-catalog.lisp`'s `default-tool-catalog` defines the tools
every session advertises. Every catalog tool executes automatically with
**no approval gate** (`bypassPermissions`, no `can_use_tool` callback, per
`catalog-tools-use-an-automatic-no-approval-session-policy`) — the safety
boundary for each tool has to live in its own handler, not in a confirmation
step, because there isn't one.

A tool-definition handler returns either a bare string (success, `is-error`
nil) or `(values text t)` to report a domain-level failure as a normal MCP
tool result rather than a Lisp condition (`%sdk-tool-from-definition` in
`sdk-adapter.lisp` maps this). Raising an actual Lisp error from a handler
still maps to a generic, safe JSON-RPC error instead, per the existing
`session-start-tool-handler-failure-emits-correlated-safe-mcp-error-once`
contract — reserve that path for genuine handler bugs/crashes, not expected
domain failures like a missing file.

### `read_file`

Reads a file's contents. **No sandboxing** (see #61): `path` can be any
path the harness process can reach, not confined to a project directory.
`offset` (1-indexed) and `limit` select a line range; output is
line-numbered (`"<n>\t<text>"`). Content beyond `+read-tool-max-chars+`
(2MB, a character count, not a strict byte count) is truncated with an
explicit notice rather than silently dropped. A missing file or non-UTF-8
binary content is reported as a safe result, not a crash.

### `write_file`

Writes (creating or overwriting) a file's contents. **No sandboxing** (see
#61): `path` can be any path the harness process can reach. Overwrites an
existing file **without confirmation** — every catalog tool executes with
no approval gate, and this one is no exception. Writes atomically (temp
file + rename in the same directory, so a failure partway through never
leaves a partially-written file at `path`) and creates parent directories
as needed. Content over `+write-tool-max-chars+` (5MB) is **rejected
outright** — the write does not happen and the existing file, if any, is
left untouched — rather than truncated: a truncated write would silently
corrupt the caller's intended file content, which is worse than refusing.

### `bash`

Runs a shell command via `/bin/sh -c`. **No sandboxing beyond the
container's own non-root user and whatever filesystem/network access it
has** (see #61): no bubblewrap/firejail/seccomp, no allow/denylist. A
non-zero exit code is a normal result, not a tool failure — `is-error`
reflects only the tool's own inability to run the command (it couldn't be
spawned, or it timed out), never the command's own exit status.

`timeout_seconds` defaults to 120 and is capped at 600; a larger request is
**rejected outright**, not silently clamped. On timeout, the whole process
group is signaled (SIGTERM, then SIGKILL after a short grace period) —
`SB-EXT:RUN-PROGRAM` already places its child shell in a new process group
of its own (the shell's PID doubles as its PGID), so killing the negative
PID reaches any children the command itself forked, not just the shell.
This mirrors, at the scale of a single tool call, the process-tree
supervision precedent this project already has for the long-lived Claude
CLI subprocess (#17, `sm-harness-web-ui/docker/claude-agent-sdk-cl-supervisor.c`).

Output is capped at roughly 200KB per stream (stdout and stderr are capped
independently, read concurrently on separate threads to avoid the classic
pipe deadlock when a command fills both simultaneously — so this is not a
single precise combined budget). `cwd` defaults to the harness process's
own working directory.

## Operator diagnostics: per-session event logging

Every normalized harness event that passes through `%publish` in
`sm-harness/src/runtime.lisp` (`status`, `user-message`, `assistant-text`,
`tool-requested`/`tool-completed`/`tool-failed`, `system`, `rate-limit`,
`terminal`, `error`, and any future event type) is written as one JSON line
to container stdout:

```text
SM-HARNESS-EVENT {"ts":"2026-07-29T11:58:18Z","session_id":"sess-...","sequence":6,"type":"terminal","payload":{"subtype":"success","text":"done","session-id":"canon-42"}}
```

Fields: `ts` (UTC ISO-8601), `session_id` (the harness's own session id — not
the provider's canonical id, which appears inside `payload` once assigned),
`sequence` (the session's monotonic event counter), `type`, and `payload`
(the event's full, unredacted content).

**Find it** with the running Compose service:

```bash
docker compose -f compose.sm-harness-web-ui.yaml logs web-ui | grep SM-HARNESS-EVENT
# filter to one session:
docker compose -f compose.sm-harness-web-ui.yaml logs web-ui | grep SM-HARNESS-EVENT | grep '"session_id":"sess-...'
```

**This is a deliberate exception** to the browser-facing redaction boundary
documented for `safe-error-payload` and the web UI's public error contract:
those exist to keep raw condition text, stack traces, and protocol detail out
of what a browser renders. This log is operator-only (container stdout,
never sent to the browser) and intentionally includes full payload content —
prompt/response text, tool names and arguments/results — to make a session
fully reconstructable for diagnosis. It does not include credentials, OAuth
tokens, or raw CLI transport frames; those remain out of scope here as
elsewhere in this project.

Logging is unconditional (no debug flag): every `%publish` call logs, so a
new event type gets diagnostic coverage automatically without a corresponding
code change. Concurrent sessions' worker threads share one write lock
(`*session-event-log-lock*`) so lines from different sessions never interleave
mid-line. `*session-event-log-stream*` is a global (not per-call dynamic)
binding specifically so it stays swappable by tests despite each session
running on its own worker thread, which does not inherit another thread's
`LET` bindings.
