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

## Backend/model selection and viewing (#106)

`start-session` takes optional `:backend`/`:model` keywords, validated against
a small static catalog (`model.lisp`) that is the single source of truth for
what a caller may legally choose -- an unrecognized value is
`harness-input-error`, not a silently-ignored no-op:

```lisp
(backend-catalog)              ; => list of BACKEND-DESCRIPTORs
(find-backend "claude")        ; => the BACKEND-DESCRIPTOR, or NIL
(backend-descriptor-models b)  ; => list of MODEL-DESCRIPTORs for that backend
(find-model "claude" "opus")   ; => the MODEL-DESCRIPTOR, or NIL
(valid-backend-id-p id) / (valid-model-id-p backend-id model-id)
*default-backend-id* / *default-model-id*
```

Today's catalog has exactly one backend, `"claude"` (this harness only ever
drives the `claude` CLI, see `docs/api-parity.md`), with four models --
`sonnet`, `opus`, `haiku`, `fable` -- each a `claude` CLI `--model` alias.
Every entry was verified against a live `claude -p "..." --model <alias>`
invocation before being added here, per the issue's own ask that the catalog
never list a model that doesn't actually work; extending the list later is a
deliberate, reviewed edit to `*backend-catalog*`, not runtime discovery.

`session-record`/`session-summary`/`session-snapshot` all carry `backend`
and `model` fields (`session-snapshot-backend`, `session-snapshot-model`,
etc.), persisted by `session-repository.lisp`. `backend` defaults to
`*default-backend-id*` when a caller omits it, so it is always populated for
display; `model` stays `NIL` unless a caller passes one explicitly -- exactly
the pre-#106 behavior, where `harness-config-model` (or ultimately the CLI's
own default) governs when nothing more specific is set. A record already on
disk from before this feature existed decodes the same way: `backend` reads
back as the sole default, `model` as `NIL`.

At runtime, `%ensure-client` (`runtime.lisp`) prefers a session's own `model`
over `harness-config-model` when building `AGENT-OPTIONS`, so a per-session
choice actually reaches `claude --model`; a session with no override falls
back to the harness-wide config exactly as before this feature.

The web UI (`docs/sm-harness-web-ui.md`) is the only caller today that ever
passes an explicit `:backend`/`:model` -- its new-session dropdowns are
populated directly from `backend-catalog`, and its chat-header Info panel
reads a session's stored choice back via `%backend-label`/`%model-label`
(`sm-harness-web-ui/src/presenter.lisp`).

## Session summary chip metadata: turn count and start time (#111)

`session-summary` also carries `created-at` and `turn-count`
(`session-summary-created-at`/`session-summary-turn-count`), added for the
web UI's home-screen session chips (`docs/sm-harness-web-ui.md`) but kept
here since both derive from durable session state, not anything UI-specific:

- `created-at` is just `session-record-created-at`, copied straight through
  by `session-record->summary` -- it never changes after a session is
  created, unlike `updated-at`, which bumps on every save.
- `turn-count` is `%session-turn-count`: the number of `role "user"`
  transcript entries, counting both a real human prompt (`kind "message"`)
  and a harness-initiated synthetic follow-up (#76, `kind "synthetic"`) --
  both still round-trip the provider once, so both count as a turn.

Both are also written into the lightweight index (`repository-save-session`)
so `list-sessions` never has to reload every session's full transcript from
disk just to answer "how many turns has this session had" for a list view.
An index entry written before this feature has neither field on disk:
`repository-list-sessions` defaults `created-at` to `""` and `turn-count` to
`0` rather than erroring, matching how the pre-#111 backend/model fields
(#106) already degrade for records that predate them.

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

### Every tool result must fit the client's inline budget (#126)

`+tool-result-max-chars+` (32KB) caps what one tool result hands back to
the model, and it is **not** a memory guard — it is a client-side
constraint discovered the hard way. The CLI persists any tool result above
roughly 45KB to a file under
`~/.claude/projects/<project>/<uuid>/tool-results/` and replaces it with a
`<persisted-output>` wrapper containing a **2KB preview**. That short
wrapper variant contains no instruction to go read the saved file, so from
the model's side an oversized result is indistinguishable from a small,
complete one: it just quietly loses ~95% of its content.

The failure this caused is the reason the cap exists. A session asked to
debug an issue read `docs/sm-harness-web-ui.md` (959 lines) as its second
action, received ~40 lines of it, and — never having seen the section
titled "Running browser E2E without Docker" — twice told the user it could
not run the Playwright suite in this container. It could: Chromium is baked
into the image at `/opt/ms-playwright` precisely so it can. Every cap
below is derived from this one:

| tool | cap | on overflow |
| --- | --- | --- |
| `read_file` | `+tool-result-max-chars+` per result | stops at a line boundary, names the offset to resume from |
| `bash` | `+bash-tool-max-output-chars+` = half of it, per stream | `[stdout truncated]` / `[stderr truncated]` marker |

The bash cap is halved because stdout and stderr are capped independently
(see below), so a command that fills both must still produce one result
that fits. A handler that grows a new large output path should take its
budget from `+tool-result-max-chars+` rather than inventing another number.

### `read_file`

Reads a file's contents. **No sandboxing** (see #61): `path` can be any
path the harness process can reach, not confined to a project directory.
`offset` (1-indexed) and `limit` select a line range; output is
line-numbered (`"<n>\t<text>"`). Content beyond `+read-tool-max-chars+`
(2MB, a character count, not a strict byte count) is truncated with an
explicit notice rather than silently dropped. A missing file or non-UTF-8
binary content is reported as a safe result, not a crash.

One *result* is separately bounded by `+tool-result-max-chars+`
(`%read-result-text`). A read cut short by that ceiling stops on a line
boundary and ends with

```text
[truncated: 453 more lines not shown, this result hit the 32,768 character cap -- continue with read_file offset=507]
```

so paging is an instruction the model receives rather than a convention it
has to infer — the whole point of #126, where the missing content was
never announced at all. A single line longer than the entire cap (minified
JSON, a bundled `.js`) is cut mid-line and says so, instead of being
emitted whole and re-creating the oversized result. When everything
requested fits, no notice is emitted, so ordinary small reads are
byte-identical to what they were before.

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

The rename step uses `SB-POSIX:RENAME` on native namestrings rather than
`CL:RENAME-FILE` / `UIOP:RENAME-FILE-OVERWRITING-TARGET`: for any `path`
whose file name has no extension (`Dockerfile`, `Makefile`, `LICENSE`, ...),
`PATHNAME-TYPE` is NIL, and `CL:RENAME-FILE` merges components left
unspecified (NIL) in its new-name argument in from the pathname of the file
actually being renamed — the `.tmp` file, whose type is `"tmp"` — per CLHS
19.2.3. That silently turned the rename into a self-rename no-op: `path` was
left untouched while the tool still reported a fabricated success (see #96).

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

Output is capped at `+bash-tool-max-output-chars+` — half of
`+tool-result-max-chars+`, so roughly 16KB — per stream (stdout and stderr
are capped independently, read concurrently on separate threads to avoid
the classic pipe deadlock when a command fills both simultaneously, so this
is not a single precise combined budget; halving it is what keeps the
*pair* inside one deliverable result, per #126 above). Commands that
genuinely produce more should filter (`head`, `grep`, `wc`) or write to a
file and read it back in ranges. `cwd` defaults to the harness process's
own working directory.

#### The self-kill guard, and why it must never signal (#101, #126)

`%self-kill-command-p` rejects, without running it, any command whose
`kill`/`pkill`/`killall` would hit the harness's own process — the
reflexive restart-the-server footgun that took the web UI down twice. It is
a best-effort *static* reading of the command string (splitting on `;`,
`&`, `|`, newline, then reading each segment's head token), not a sandbox:
#61/#64 keep bash unsandboxed on purpose. Kills aimed at anything else,
including the scratch sbcl servers sessions legitimately start, are allowed
— the guard checks what a command *would hit*, not which binary it names.

Because the guard runs before every command, **any Lisp error it signals
becomes a rejection of an unrelated command**. It reached the model as a
bare JSON-RPC `-32603 "SDK tool handler failed"`, naming neither the guard
nor the reason. That is exactly what happened in #126: the guard splits on
`|`, so a grep pattern using two or more escaped-pipe alternations leaves a
segment whose head token ends in a backslash, and SBCL's pathname parser
reads a backslash as an escape character, so `FILE-NAMESTRING` signalled
`NAMESTRING-PARSE-ERROR` on it. Every such grep — eleven calls in the
session that surfaced this — was refused with no usable diagnosis.
`%command-basename` now falls back to the raw token, which is also the
correct guard answer (a token that is not a parsable namestring is not
`kill`, `pkill`, or `killall`), and a regression test covers both halves:
the greps run, and a self-`pkill` written alongside one is still rejected.

### `reload_harness`

Recompiles and reloads changed Lisp source into the *running* image via
ASDF (see #65), so an edit made with `write_file` to this project's own
source takes effect without a container restart. `CL_SOURCE_REGISTRY=/app//`
is a recursive registry covering everything under `/app` — including the
harness source now nested at `/app/harness` (#130) — and since #90 the
compose `web-ui` service bind-mounts the host app repo at `/app` (container
user uid-matched to the repo owner), so those edits also **persist on the
host across container restarts** instead of dying with the container. The image still bakes a
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

**`*reload-harness-system*` and `*post-reload-hook*` (both in
`tool-catalog.lisp`) must stay `DEFVAR`, not `DEFPARAMETER` (#102).**
`tool-catalog.lisp` is part of `:sm-harness`, so it gets recompiled as a
dependency on *every* `reload_harness` call, including ones targeting
`:sm-harness-web-ui`. A `DEFPARAMETER` unconditionally reassigns on each
load — that silently reset `*reload-harness-system*` back to its
`:sm-harness` default (and dropped the web UI's installed
`*post-reload-hook*`, see #78 below) immediately after every reload
finished, so only the very first `reload_harness` call of a process's life
ever actually reloaded `sm-harness-web-ui`; every call after that quietly
reloaded `:sm-harness` alone while still reporting success, with the
running web UI's own Lisp source silently going stale and no error
anywhere to notice by. `DEFVAR` only initializes an unbound variable, so
the web UI's startup `SETF` (`main`, `sm-harness-web-ui/src/application.lisp`)
now survives every later reload instead of just the first.

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

**The correlated name is MCP-namespaced (#118).** The CLI reports a
catalog tool call as `mcp__<server>__<tool>` —
`mcp__sm_harness__reload_harness`, not `reload_harness` — so the
correlation compares `%tool-base-name` output, which strips that prefix at
the *first* `__` after `mcp__` (a tool name may itself contain
underscores: `read_file`, `reload_harness`). Before this, the check was an
exact `string=` against `"reload_harness"`, which never matched anything a
real session ever produced: #76's automatic follow-up silently never fired
in production for its entire existence, and the human had to notice the
reload and prompt again by hand. Its tests all drove a fake transport
emitting the bare, unnamespaced name, so the whole suite passed while the
feature did nothing — the regression test now drives the namespaced name
the CLI actually sends. An unprefixed name still passes through unchanged,
so builtins and fake-transport fixtures keep working.

**This follow-up alone does not make a *brand-new* tool callable** — see
"Making a tool usable mid-session" below (#116) for why, and for what
actually closes that gap. It reliably helps once a tool the model already
has in its schema gets its underlying logic fixed via a reload.

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
   hitting stale pre-reload code until the process restarts;
2. pushes a page reload to every currently open browser tab (tracked in
   `*live-browser-windows*` as each one connects) via CLOG's own
   `clog:reload`, pruning any tab that has since closed; and
3. calls `mark-sessions-for-catalog-refresh` (see below, #116) so every
   currently open chat session picks up whatever the reload changed the
   next time a turn starts for it.

A misbehaving hook is folded into the tool result's warnings text, not
escalated to `is-error t`: a successful reload stays reported as a
success even if, say, a tracked browser vanished mid-broadcast.

Static assets (`app.css`, etc.) needed no such mechanism — the browser
already refetches those fresh on every page load; only the *routing* and
*already-open tabs* needed an explicit nudge.

#### Making a tool usable mid-session, not just after a restart (#116)

A `reload_harness` that adds a *brand-new* tool, or edits an *existing*
tool handler's own top-level body, needs more than the mechanisms above to
actually reach an already-open chat session. Three things had to be fixed
together:

1. **Handlers are late-bound by symbol, not captured as `#'name`.** Every
   `make-*-tool-definition` in `tool-catalog.lisp` stores its `:handler` as
   a symbol (e.g. `'%bash-tool-handler`), not `#'%bash-tool-handler`. A
   captured function object is a snapshot, frozen at the moment
   `(function name)` was evaluated — verified directly, with a genuinely
   separate `compile-file`+`load` (the same mechanism `reload_harness`'s
   `(asdf:load-system ... :force t)` uses): a captured reference keeps
   calling the pre-redefinition body forever, even after the underlying
   function is recompiled and reloaded. `funcall`ing a symbol instead
   performs a fresh lookup every call, so a symbol handler's own body
   hot-reloads correctly for the rest of an open session. (An anonymous
   `lambda`, like `echo_text`'s, has no symbol to late-bind and stays
   frozen the same way a captured `#'name` would — acceptable there since
   nothing else in that handler needs a live edit.)
2. **The harness-wide catalog is re-resolved per connection, not cached
   once at startup.** `harness`'s `catalog` slot (`runtime.lisp`) used to
   hold a `tool-catalog` value built once by `default-tool-catalog` in
   `make-harness` and never re-read — and since `sm-harness-web-ui` keeps
   one `harness` singleton (`*app-harness*`) for the whole process, even a
   *brand-new* session created after a successful reload still got the
   pre-reload tool list. The slot is now `catalog-provider`: a zero-argument
   function `%ensure-client` calls fresh every time it builds a *new*
   client connection. `make-harness`'s existing `:catalog` keyword (tests,
   the web UI's E2E fixture catalog) keeps its exact current contract — a
   fixed catalog for that harness's whole lifetime — via an internal
   constant-returning wrapper; only the real production path (no explicit
   `:catalog` argument at all) actually goes back to `default-tool-catalog`
   on every new connection.
3. **An already-open session deliberately reconnects after a reload.**
   `mark-sessions-for-catalog-refresh` (called by `sm-harness-web-ui`'s
   `*post-reload-hook*`, see above) sets a `pending-catalog-refresh-p` flag
   on every open `session-runtime`. This is the *only* thing a foreign
   thread (the reload's own caller) ever touches — never
   `session-runtime-client` itself. `%ensure-client` consumes the flag at
   the very start of its own next call, which only ever happens on that
   session's own worker thread, at the start of a *new* turn (`%run-turn`)
   — so a turn already in flight when the reload happens is never
   disrupted. If the flag is set and a client already exists,
   `%ensure-client` disconnects it and falls through to its ordinary
   connect logic, which already passes `:resume (session-record-canonical-id
   rec)` — the exact same rebuild an error-recovery reconnect already
   performs — so the CLI-side conversation carries forward unchanged; only
   the tool catalog offered on that reconnect is new. A session that never
   sends another message after the reload simply never reconnects: this is
   a lazy, next-message refresh, not an unsolicited push into a live
   conversation.

Net effect: editing a tool handler's own body reaches an open session
immediately (no reconnect needed, per (1)); a brand-new tool reaches a
*new* session immediately (per (2)) and reaches an *already-open* session
on its next message, with a brief (sub-second in practice) reconnect and
full context preserved (per (3)).

**What this does not do.** A brand-new tool does not appear *mid-turn*, in
an already-streaming response, with zero reconnect — that would require
either the underlying `claude` CLI polling for tool-list changes on an
already-open connection, or delivering this harness's tools through a real
external MCP server (`"type": "stdio"`/`"http"` in `--mcp-config`, which
supports the standard MCP `listChanged` notification) instead of the
synthetic in-process `"type": "sdk"` mechanism this harness uses today.
Both were prototyped and verified live against the real `claude` CLI while
investigating #116, and the external-MCP-server path genuinely works —
but it requires `claude-agent-sdk-cl` to gain a wholly new external
MCP-server option type and this harness's tool execution to move out of
this process's own synchronous control-request path, a separate, larger
piece of future work, deliberately not part of #116.

#### The provider itself had to be late-bound too (#117)

Phase 1 above re-*calls* the provider on every new connection, but
`make-harness` stored it as `#'default-tool-catalog` — a captured function
object, frozen exactly the way phase 1's own rationale says a captured
`#'name` handler is. So every call went to the body compiled at
`make-harness` time, whose `(list (make-echo-tool-definition) ...)` names
only the tools that existed then; a `reload_harness` that added a
brand-new tool rebound the symbol's function cell without mutating that
object, and the new tool stayed invisible to every session — including
sessions created *after* the reload — for the rest of the process's life.
That is the very failure #116 set out to fix, reintroduced one level up,
and it is why it survived #116's tests: those swap in their own fixture
provider closure and so never exercise the real captured one.

`make-harness` now stores the **symbol** `'default-tool-catalog`, so each
connection's `funcall` looks it up fresh. An explicit `:catalog` argument
still becomes a constant-returning closure and keeps its exact prior
contract.

Fixing the source is not enough for an image that is already running:
`sm-harness-web-ui` keeps one `*app-harness*` singleton for the whole
process, and its `catalog-provider` slot still holds the stale captured
object no reload can touch. `mark-sessions-for-catalog-refresh` therefore
also repairs the slot in place (`%repair-captured-catalog-provider`) —
that call is already the single "a reload just succeeded" moment, and
flagging sessions to reconnect accomplishes nothing if the provider they
reconnect through is itself a frozen snapshot. A captured provider is
told apart from a fixed-`:catalog` closure by
`function-lambda-expression`'s name value (`default-tool-catalog` vs. a
`(lambda () :in ...)` form or `nil`), so a test's or the E2E fixture's
deliberately fixed catalog is never silently swapped for the production
default.

### `web_search` (#112)

Searches the web via the [Tavily](https://docs.tavily.com) search API.
`query` is required; `max_results` defaults to
`+web-search-max-results-default+` (5) and is silently clamped to
`+web-search-max-results-cap+` (10) rather than rejected — unlike
`write_file`'s oversized-content guard, a smaller result set is still a
fully honest answer to the same query, so there is nothing to refuse.

Reads `TAVILY_API_KEY` from the process environment at *call* time (via
the injectable `*tavily-api-key-fn*`, default `(uiop:getenv
"TAVILY_API_KEY")`), not at catalog-build time, so a key configured
before a session starts is always picked up. An unset/empty key, a
non-200 HTTP response, an unparsable response body, or a transport
failure (DNS, TLS, timeout, ...) all report as a normal `(is-error t)`
tool result rather than a Lisp condition — same contract every other
catalog tool follows. A successful call renders Tavily's `results` array
as numbered `title` / `url` / `content` (truncated to 400 characters per
result) entries; an empty array renders as an explicit `"no results"`
line rather than blank output that could be mistaken for a failure.

The actual HTTPS POST (`%tavily-search-request`, `drakma:http-request`)
is reached only through `*web-search-request-fn*`, the tool's sole
network seam — the same dependency-injection shape the bash tool's own
`*bash-guard-command-line*` uses — so its own test suite runs fully
offline and never depends on a real API key or live network access.

Depends on `drakma`, available in this project's Debian-based images as
the apt package `cl-drakma` (pulling `cl-ppcre`, `cl-flexi-streams`,
`cl-puri`, `cl-base64`, `cl-chunga`, `cl-usocket`, `cl-plus-ssl`, and
`cl-chipz` in as hard `Depends`, same as `cl-yason`/`cl-fiveam` already
were) — not quicklisp, so the offline `sm-harness-test` Docker target
(`network_mode: none`) can load and test this tool with zero network
access. This also incidentally fixes #101's `cl-ppcre` dependency having
been added to `sm-harness.asd` without ever being added to either
Dockerfile's apt install list; it happened to work anyway in the
`sm-harness-web-ui` image only because quicklisp (bootstrapped there for
CLOG) pulled `cl-ppcre` in transitively and its runtime source-registry
already includes `/usr/share/common-lisp/source//` alongside `/app//`
(`sm-harness-web-ui/docker/entrypoint.sh`) — but the plain offline test
image never had that transitive path at all.

Requires `TAVILY_API_KEY` to reach the running container: the compose
`web-ui` service passes it through from the host's `harness/.env` the same way
`GITHUB_TOKEN` already was (`compose.sm-harness-web-ui.yaml`) — `.env`
itself is never baked into an image or visible to the offline test
services, per the existing `.env`-related guardrails elsewhere in this
project.

### `set_session_title`

Renames a session: updates the stored `title` shown on the home screen's
session chip and in a session's own Info panel (both currently always read
the literal default, `"New session"` — nothing had ever edited a title
before this). `session_id` and `title` are both required. `session_id` is
never inferred from which session is making the call: a call always names
the session explicitly, even to rename itself, matching every other
harness-facing API in this project (`open-session`, `submit-turn`, ...)
rather than introducing a first "current session" magic argument. An
agent's own session id is already available to it, named in its own system
prompt (`%session-system-prompt`, runtime.lisp) — but nothing stops one
session from renaming another, consistent with this catalog's existing
no-sandboxing stance (#61): `read_file`/`write_file` can already reach and
corrupt another session's durable JSON record directly, so a validated,
harness-level rename API is strictly *safer* than the status quo, not a
new exposure.

The DESCRIPTION itself instructs the calling model to invoke this
proactively, not only on an explicit rename request: once the user's
message makes clear what a session is about, call it with a short
descriptive title, and call it again later if the session's subject
changes substantially. This is pure model-behavior guidance carried in
the tool metadata -- nothing server-side enforces or nudges it, the same
way nothing enforces that a model actually reads read_file's pagination
notice; the handler itself accepts any valid rename request regardless of
why it was called.

`title` is trimmed of leading/trailing whitespace and rejected outright —
not silently truncated — if it is empty after trimming or exceeds
`+session-title-max-chars+` (200): a short display label has no good
truncation behavior, and rejecting means the caller finds out immediately
rather than shipping a truncated, confusing chip.

The actual mutation is `sm-harness:set-session-title` (session-service.lisp):
it reopens `session-id` first (`open-session`, transparent for both an
already-open and a durable-but-idle session — the caller never has to
attach it first), updates the in-memory record's `title` under
`session-runtime-lock`, and persists through `repository-save-session`,
which also refreshes the summary index — so a rename is immediately
reflected the next time the home screen or an Info panel reads either.
Signals `harness-input-error` for an invalid title and
`harness-not-found-error` (via `open-session`) for an unknown `session-id`,
both surfaced as a normal `(is-error t)` tool result, not a crash.

Unlike every other catalog tool, this handler needs a live `HARNESS`
instance to act on — `tool-catalog.lisp` is deliberately harness-agnostic
otherwise (a pure function of its arguments). `*tool-harness*` is the
dependency-injection seam for that, mirroring `*tavily-api-key-fn*`
above: `NIL` by default (so this file keeps loading/testing standalone,
no application wired up), and set to the live harness by
`sm-harness-web-ui:start-web-ui` at startup (alongside `*app-harness*`,
which the CLOG-facing UI code reads instead — this file must not import
that package, since `:sm-harness` has to load without CLOG).

### One-shot title nudge after the first turn (#128)

`set_session_title`'s own DESCRIPTION already instructs the model to call
it proactively as soon as a session's topic is clear — but that guidance
lives only in tool metadata, with nothing server-side enforcing or even
reminding the model of it. In practice a session can read that guidance
(even re-read the tool's own handler source while researching something
else) and still never call it: observed directly in a real transcript, a
single-topic planning session that learned its own topic within its first
tool call and still never titled itself.

To close that gap without turning it into hard enforcement (a title is
model judgment, not something the harness can validly invent), the harness
queues a **one-shot** synthetic follow-up — reusing #76's exact mechanism
below — right after a session's very first completed turn, if the title is
still the literal default (`"New session"`) at that point:

> "[harness] This was your first turn in this session. If you now know
> what this session is about, call set_session_title with a short
> descriptive title now, if you have not already -- do not wait to be
> asked. If it is genuinely not yet clear what this session is about, no
> action is needed."

`%maybe-queue-title-nudge` (`runtime.lisp`), called at the same
end-of-turn point `%run-turn` already calls `%maybe-run-synthetic-followup`
from, gates this on three things:

- `kind` is `"message"` — a real human turn, not a synthetic follow-up
  replying to itself (in practice a session's first turn is always
  `"message"`, since nothing can queue a synthetic follow-up before a
  first turn exists).
- `session-record-title` is still exactly `"New session"` — read under
  `session-runtime-lock`, unlike fields `%run-turn` otherwise owns
  exclusively for its own turn's duration, because `set_session_title` can
  rename this session from a *different* session's worker thread at any
  time (#61: no session is sandboxed from calling it on another). A
  session started with an explicit title, or one the model already titled
  earlier in this same first turn, is never nudged.
- `%session-turn-count` reads exactly `1` for the record's transcript —
  true only for a session's first-ever turn, so this needs no separate
  "already nudged" flag: it is structurally impossible to fire twice.

**Never clobbers a same-turn reload follow-up.** `pending-synthetic-
followup` is a single slot; if a session's first turn also happens to call
`reload_harness` successfully, `%handle-mapped-event` will already have
queued #76's own follow-up there first. `%maybe-queue-title-nudge` checks
that slot is still `nil` before writing to it, so the (more urgent —
verifying a just-reloaded tool actually works) reload follow-up always
wins; losing the title nudge to that rare overlap is an accepted trade,
not a bug, and since turn-count can never read `1` again, it is not
retried on a later turn either.

Renders through the exact same `kind "synthetic"` path #76 already built
— distinct transcript rendering, `:synthetic t` on the live
`:user-message` event, never mistaken for something a human typed — so
this needed no new UI work, only the queueing decision itself.

**This is still only a nudge, not enforcement.** An explicit harness-
authored turn in the transcript is harder to ignore than a tool
description skimmed once at session start, but a model can still do
nothing in response, exactly as it could ignore the tool description
before this — see `sm-harness-tests::first-turn-with-default-title-
schedules-a-one-shot-title-nudge` and its neighboring tests in
`test/runtime.lisp` for the one-shot/no-double-fire/no-clobber contract
this relies on.

### Tool annotations and concurrent execution (#123)

Every `tool-definition` in `tool-catalog.lisp` carries an `annotations`
plist -- `:read-only-p`/`:destructive-p`/`:idempotent-p`/`:open-world-p`,
the standard MCP `ToolAnnotations` set (`readOnlyHint` et al. on the wire).
`%sdk-tool-from-definition` (`sdk-adapter.lisp`) passes it straight through
to `claude-agent-sdk-cl:make-sdk-tool`, which serves it in this catalog's
`tools/list` response. No tool defaults to silently unannotated: every
`make-*-tool-definition` constructor sets all four keys explicitly, even
when every one of them is `nil`.

| tool | read-only | destructive | idempotent | open-world |
| --- | --- | --- | --- | --- |
| `read_file` | T | NIL | T | NIL |
| `web_search` | T | NIL | NIL | T |
| `echo_text` | T | NIL | T | NIL |
| `bash` | NIL | T | NIL | T |
| `write_file` | NIL | T | NIL | NIL |
| `reload_harness` | NIL | NIL | T | NIL |
| `set_session_title` | NIL | NIL | T | NIL |

`:read-only-p t` is what a conforming MCP client -- including the real
`claude` CLI (`isConcurrencySafe`/`isReadOnly`, both gated on
`annotations.readOnlyHint`) -- uses to decide a tool call is safe to run
concurrently with any other in-flight call. Only `read_file`, `web_search`,
and `echo_text` claim that today; `bash` stays conservatively unmarked for
the same reason the CLI's own built-in `Bash` tool is: a `grep` and a `git
push` both run through it, and nothing here can tell them apart from the
command string alone (a narrower, command-pattern-based classifier is
deliberately out of scope, see #123's own "open questions").

**Advertising the annotation is necessary but not sufficient.**
`claude-agent-sdk-cl` does not trust the CLI (or any other MCP client, or a
future CLI version) to actually honor `readOnlyHint`: its own
`claude-sdk-client` holds a `tool-execution-lock` mutex, and every inbound
`mcp_message` `tools/call` acquires it for the call's duration *unless* the
resolved tool's own annotations say `:read-only-p t`
(`%invoke-sdk-tool-serialized`, `mcp.lisp`). So a non-read-only tool call
physically cannot overlap another non-read-only call through this client
regardless of what the CLI schedules, and a `read_file`/`web_search`/
`echo_text` call can now run wall-clock-concurrently with another one, or
even with an in-flight `bash` call.

**The client's control-request read loop no longer blocks on any tool
call's execution**, not just read-only ones. Before #123, one single
reader thread read every CLI control request *and* ran that request's
handler fully synchronously before reading the next one, which meant every
tool call -- however concurrency-safe -- was serialized purely by that read
loop's own structure, independent of the CLI's own scheduling or any
annotation. `%client-handle-control-request` now spawns a fresh thread per
`mcp_message` request (`%client-spawn-tool-thread`, `client.lisp`) and
returns immediately; every other control subtype (`hook_callback`,
`can_use_tool`, `initialize`/`interrupt` acks, ...) is untouched and still
handled fully in-line on the reader thread, exactly as before. The
concurrency-safety policy itself still lives entirely in the
`tool-execution-lock` described above -- this only removes the transport
layer as an *additional*, tool-identity-blind bottleneck on top of it.
`disconnect` joins any still-running tool threads with a bounded grace
period (`+client-tool-thread-disconnect-grace-seconds+`, 5s) and abandons
(logging, never blocking on) any straggler, mirroring the bash tool's own
timeout-watchdog philosophy (#79/#80): a wedge, not a leaked thread, is the
catastrophic outcome.

**A visible consequence for anything downstream of `map-sdk-message`:**
tool-requested/-completed/-failed events for two calls in the same model
turn can now interleave in wall-clock time (though the event *stream*
itself stays strictly ordered -- only handler *execution* runs
concurrently, `runtime.lisp`'s `inflight-tool-calls` bookkeeping already
correlates purely by `tool-use-id`, never delivery order, so no runtime
change was needed there). Nothing here has been observed to assume at most
one open "tool requested" card in `sm-harness-web-ui`; if that surfaces a
real rendering problem it is a follow-up issue, not a #123 regression.

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
