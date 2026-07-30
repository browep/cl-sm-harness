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
group is signaled (SIGTERM, then SIGKILL after a short grace period) via
`sb-posix:killpg` directly — **never an external `kill` binary**, because
the production web-ui image shipped none and a `run-program`-based kill
silently no-opped, leaving the child alive and the session worker wedged
forever (#79). `SB-EXT:RUN-PROGRAM` already places its child shell in a
new process group of its own (the shell's PID doubles as its PGID), so
signaling the group reaches any children the command itself forked, not
just the shell. This mirrors, at the scale of a single tool call, the
process-tree supervision precedent this project already has for the
long-lived Claude CLI subprocess (#17,
`sm-harness-web-ui/docker/claude-agent-sdk-cl-supervisor.c`).

If the kill itself fails, the tool result says so explicitly ("could not
be killed ... may still be running") instead of claiming the command was
killed, and every wait in the handler is bounded (reader-thread joins and
the process-status wait both give up after `timeout_seconds` + 10s,
abandoning the readers) so a kill failure degrades to a leaked thread and
an honest error — never a permanently wedged session worker.

Output is capped at roughly 200KB per stream (stdout and stderr are capped
independently, read concurrently on separate threads to avoid the classic
pipe deadlock when a command fills both simultaneously — so this is not a
single precise combined budget). `cwd` defaults to the harness process's
own working directory.

### `reload_harness`

Recompiles and reloads changed Lisp source into the *running* image via
ASDF (see #65), so an edit made with `write_file` to this project's own
source takes effect without a container restart. `CL_SOURCE_REGISTRY=/app//`
covers everything under `/app`, and since #90 the compose `web-ui` service
bind-mounts the host repo at `/app` (container user uid-matched to the
repo owner), so those edits also **persist on the host across container
restarts** instead of dying with the container. The image still bakes a
source copy at build time for the bind-mount-free e2e services.

Calling `(asdf:load-system *reload-harness-system* :force force)` *is* the
implementation: ASDF's own timestamp-aware incremental compilation already
means an unchanged file is skipped, satisfying "reload changed files" with
no file-watching of its own. `*reload-harness-system*` defaults to
`:sm-harness` (so this tool and its tests work standalone — `sm-harness`
must load and run without CLOG, so it cannot itself reference
`sm-harness-web-ui`); the web UI overrides it to `:sm-harness-web-ui` at
startup, which transitively covers `sm-harness` and `claude-agent-sdk-cl`
too via ASDF's dependency graph. `force` (boolean, default false) bypasses
the timestamp check and recompiles everything — direct fix for a stale
compiled-`.fasl`-cache problem encountered firsthand while building the
`bash` tool.

**An incompatible structure/class redefinition can permanently disable
further reloads for the rest of the process's life — empirically
confirmed, not theoretical.** Changing a `defstruct`'s slots while live
instances of the old shape exist (any active session) makes SBCL signal an
error during the reload. That error is caught here — the process does not
crash, and the failure is reported as a normal (`is-error t`) tool result —
but the Lisp image's *compile-time* tracking of that struct's layout is left
permanently inconsistent: every subsequent `reload_harness` call touching
that type fails identically, even after reverting the source back to its
original, previously-working shape. Verified directly: a second reload
attempt with the reverted source still failed the same way. Only a
container restart clears this. If a reload failure mentions instance
length or layout, that is the signal to restart rather than retry.

Because `asdf:load-system` cannot honor a `:force` that disagrees with an
already-active outer ASDF operation in a *nested* call, the handler starts
its own fresh ASDF session (`asdf/session:call-with-asdf-session` with
`:override t :override-cache t`) before loading — relevant mainly for
testing (offline tests run inside `(asdf:test-system ...)`, itself an
active ASDF operation), since production never invokes this tool from
inside one.

#### Automatic follow-up after a successful reload (#76)

Once `reload_harness` completes without error, the harness automatically
submits a synthetic follow-up turn — no human message involved — so the
model can exercise a tool it just added or changed within the same session,
rather than the human having to notice the reload happened and manually
prompt it to try. A failed reload does not schedule one: the error is
already visible in that turn's own tool result, so no extra nudge is
needed. Completing a *different* tool does not schedule one either — this
is specifically tied to `reload_harness`, via a tool-use-id → tool-name
correlation table on `session-runtime` (`:tool-completed`/`:tool-failed`
payloads carry the id but not the name; `:tool-requested` carries both).

The follow-up is submitted through the exact same `submit-turn` path a
human message would use, tagged with `:kind "synthetic"` so its transcript
entry (and the live `:user-message` event's `:synthetic t` payload flag)
render distinctly — role `"harness"`, not `"user"`, in the web UI — and are
never mistaken for something a human actually typed.

**Consecutive-followup cap.** A model stuck in a reload/fail/retry loop
could otherwise keep triggering new follow-ups indefinitely, unnoticed,
consuming the operator's provider budget: `+max-consecutive-synthetic-followups+`
(default 3) bounds a single chain. Hitting it does not submit a fourth
follow-up; instead it records a safe `"[harness] automatic reload_harness
follow-up limit ... reached"` transcript notice and resets the counter, so
a later, independent chain still gets a fresh allowance. The counter itself
resets to 0 whenever any turn completes without queueing a new follow-up
(a normal reply, a failed reload, or a different tool call) — it bounds one
chain, not a session's lifetime total.

#### Post-reload hook and browser live-refresh (#78)

Once `reload_harness` completes without error, it also calls an optional,
best-effort `*post-reload-hook*` (a zero-argument function, default `nil`)
if one is installed. `sm-harness` itself stays CLOG-free (see above), so
this hook is how `sm-harness-web-ui` reaches back in without `sm-harness`
depending on it: `start-web-ui` installs a hook that

1. re-points CLOG's own routing table at the just-reloaded
   `on-new-window` — CLOG captures that function object exactly once, at
   `clog:initialize`/`clog:set-on-new-window` time, into a private routing
   table; redefining `on-new-window` (or anything it calls, e.g.
   `render-home`/`render-chat`/the presenter) via a reload rebinds the
   *symbol's* function cell but does not touch that already-captured
   function object, so a *new* browser connection would otherwise keep
   hitting stale pre-reload code until the process restarts; and
2. pushes a page reload to every currently open browser tab (tracked in
   `*live-browser-windows*` as each one connects) via CLOG's own
   `clog:reload`, pruning any tab that has since closed.

A misbehaving hook is folded into the tool result's warnings text, not
escalated to `is-error t`: a successful reload stays reported as a
success even if, say, a tracked browser vanished mid-broadcast.

Static assets (`app.css`, etc.) needed no such mechanism — the browser
already refetches those fresh on every page load; only the *routing* and
*already-open tabs* needed an explicit nudge.

## Turn deadline

`turn-deadline-seconds` (default 600, `make-harness-config`) bounds
model/CLI *stall*, not total turn time. The watchdog wakes every
`turn-deadline-seconds` and cancels the turn **only if no conversational
tool call is in flight** (requested but not yet completed/failed) at that
moment; otherwise it re-arms (#80). A tool call owns its own timeout (the
`bash` tool enforces one explicitly, up to 600s), so a turn whose tool
calls keep completing can legitimately run far longer than the deadline —
previously any tool call slower than the remaining turn budget was doomed,
every time. Because stall is sampled at wakeups, a stall that begins right
after a re-arm can take up to two periods to be noticed.

A deadline cancellation usually ends through the CLI's own terminal event
(`error_during_execution`, empty text). The turn then also publishes an
explicit `error` event — `"turn deadline exceeded"` — so the abort is never
a silent stop.

## Agent system prompt

`system-prompt` (`make-harness-config`, default `nil`) becomes the CLI
session's system prompt (`--system-prompt`; when `nil` the flag still goes
out with the upstream-default empty string). When set, the harness appends
one per-session identity line naming the harness session id and the
transcript file it maps onto
(`<data-root><project-key>/sessions/<id>.json`), so an agent asked to debug
"this session" can locate its own transcript without a discovery step.

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

### `SM-HARNESS-DIAGNOSTIC`: the raw condition behind a redacted error

When a turn fails, the browser-facing `:error` event deliberately says
nothing but `"internal error"` (`safe-error-payload`). The condition it
withheld goes to the same operator-only channel as one JSON line:

```text
SM-HARNESS-DIAGNOSTIC {"ts":"2026-07-30T03:36:38Z","session_id":"sess-...","turn_id":"turn-...","condition_type":"CLI-CONNECTION-ERROR","condition":"CLI stream ended waiting for ..."}
```

Grep for `SM-HARNESS-DIAGNOSTIC` the same way as for `SM-HARNESS-EVENT`
above. Before this line existed, a redacted turn failure was undiagnosable
after the fact: the 2026-07-30 incident (a half-dead browser tab starving a
CLI MCP control request until the CLI died) had to be reconstructed from the
CLI's own transcript file because the harness dropped the real condition.

## Listener callbacks are asynchronous

`attach-session-listener`'s `:callback` runs on a dedicated per-listener
dispatcher thread, never on the session worker. `%publish` only enqueues
into each listener's bounded mailbox (overflow drops oldest and sets the gap
flag), so a callback that blocks — canonically, a CLOG browser round-trip
against a connection whose peer silently died — cannot stall the worker,
which also answers the CLI's MCP control requests (the 2026-07-30 wedge).
Ordering is preserved per listener. `detach-session-listener` flushes
already-published events through the callback and joins the dispatcher
before returning, so a caller that waited for a turn to finish has observed
every event of that turn once detach returns; idle eviction and
`close-harness` instead discard undelivered events (their browsers are
gone, and flushing through a dead connection would serialize per-query
timeouts).

## Debugging a stuck session

The procedure below reconstructed a real wedge end-to-end (session
`sess-3994332033-243035`, 2026-07-29 — see #79/#80/#81 for what it found).
Work outside-in: event log first, then the container's processes, then the
harness's own threads.

### 1. Read the session's event timeline

```bash
docker compose -f compose.sm-harness-web-ui.yaml logs web-ui \
  | grep SM-HARNESS-EVENT | grep '"session_id":"sess-XXXX"' > /tmp/session.log
# The status/terminal skeleton is usually enough to see the shape of a turn:
grep -E '"type":"(status|terminal|error)"' /tmp/session.log
tail -20 /tmp/session.log
```

Signatures to recognize in the tail:

- **`status: stopping` at *exactly* `turn-deadline-seconds` (default 600)
  after the last `status: responding`** — the per-turn deadline watchdog
  fired (`%start-deadline-watchdog`, `config.lisp`), not a user Stop. A
  turn whose tool calls legitimately run long will hit this every time
  (#80).
- **`stopping` followed by a `terminal` in the same second, then `ready`**
  — a deadline/interrupt that worked: the CLI aborted and the worker
  consumed the result. Normal, if abrupt.
- **`stopping` and then *nothing*, ever** — the worker is wedged. The
  worker thread is both the sole SDK reader and the synchronous MCP tool
  executor, so if it is blocked inside a tool handler (e.g. a `bash` child
  that survived its timeout, #79), no interrupt result can ever be
  consumed. Go to step 2.
- **A `tool-requested` with no matching `tool-completed`/`tool-failed`** —
  identifies the in-flight tool call the worker is blocked on; its
  `input` shows the exact command.

### 2. Inspect the container's processes

The web-ui image has **no procps** (`ps`, `kill` are absent — see #79);
use `/proc` directly:

```bash
docker exec claude-agent-sdk-cl-web-ui-1 sh -c \
  'for p in /proc/[0-9]*; do pid=${p#/proc/}; \
     echo "$pid ppid=$(awk "/^PPid:/{print \$2}" $p/status) \
$(awk "/^State:/{print \$2}" $p/status) $(cat $p/comm) :: \
$(tr "\0" " " < $p/cmdline | cut -c1-120)"; done'
```

What to look for: a leftover tool-command process tree (a `/bin/sh -c ...`
whose start time matches the unmatched `tool-requested`), and whether the
Claude CLI subprocess is present at all — a dead CLI with a still-blocked
worker is the #79 wedge. Process-group membership (field 5 of
`/proc/PID/stat`) tells you what a group signal would have reached.

### 3. Inspect the harness's threads

```bash
docker exec claude-agent-sdk-cl-web-ui-1 sh -c \
  'for t in /proc/1/task/*; do echo "${t##*/} \
$(awk "{print \$3}" $t/stat) wchan=$(cat $t/wchan)"; done'
```

Threads in state `R` with `wchan=0` are spinning; sample
`utime`/`stime` (fields 14/15 of `/proc/1/task/TID/stat`) a few seconds
apart to confirm. Spinning readers after a CLI death are #81.

### 4. Remediation

- A wedged worker cannot be recovered in place — even killing the orphaned
  tool process group only moves the worker into a spin (#81). **Restart
  the container.**
- The data-root lock is a kernel-held POSIX fcntl record lock (#83): it
  is released automatically when the owning process dies, however it
  died, so a restart after any crash needs **no lock cleanup**. A refusal
  to start with `"data root is locked by another sm-harness process"` now
  always means a genuinely live owner — the error message names the lock
  file and the owner's recorded boot id/pid. (Deployments predating #83
  used a lock file that could go stale after a crash and required
  deleting `/data/.harness.lock` by hand.)
- Kill any orphaned tool process group first: `docker exec
  claude-agent-sdk-cl-web-ui-1 kill -KILL -- -<pgid>` (the image ships
  procps since #79). Note the harness (PID 1) does not reap reparented
  grandchildren, so expect a harmless zombie until restart (#81).
