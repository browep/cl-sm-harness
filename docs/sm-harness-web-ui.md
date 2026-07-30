# sm-harness-web-ui

CLOG browser UI over `sm-harness`.

## Run

```bash
docker compose -f compose.sm-harness-web-ui.yaml up --build web-ui
# http://127.0.0.1:8080
```

Every turn's normalized harness events (including full payload content) are
logged to this container's stdout as they happen, tagged with the session
id — see [Operator diagnostics in docs/sm-harness.md](sm-harness.md#operator-diagnostics-per-session-event-logging)
for the log format and how to grep it per session.

## Container privileges and the live repo mount

Two deliberate extensions of the project's documented no-sandbox posture
(#61) — the container/tailnet boundary is the isolation layer, nothing
inside it is:

- **Passwordless sudo (#89)**: the `app` user has `NOPASSWD:ALL` via
  `/etc/sudoers.d/app`, so `bash`-tool commands can install packages and
  act as root inside the container.
- **Live repo at `/app` (#90)**: the compose `web-ui` service bind-mounts
  the host repo over `/app`. `write_file`/`reload_harness` edits therefore
  persist on the host across container restarts, and are ordinary git
  changes there. To make the mount writable, the image's `app` user is
  built with uid 1000 (`APP_UID` build arg) matching the host repo owner —
  the base image's `node` user, which held uid 1000, is removed at build.
  CLOG's static assets are assembled at `/opt/app-static`
  (`SM_HARNESS_STATIC_ROOT`), outside the mount's shadow. The entrypoint
  self-heals `/data`/`/cache` volume ownership via sudo when those volumes
  were created under the old image uid (10001).

The `web-ui-e2e-app` service keeps its narrower read-only source mounts and
the baked-in source copy; only `web-ui` gets the writable repo mount.

**`reload_harness` only reloads Lisp.** Because `/opt/app-static` is a
one-time copy taken at image build (see above), editing anything under
`sm-harness-web-ui/static/` and calling `reload_harness` changes the *source*
but not what a running `web-ui` container actually serves — `reload_harness`
recompiles/reloads ASDF-tracked Lisp systems only. A live container needs
those files re-copied into `/opt/app-static` (`cp -a sm-harness-web-ui/static/.
/opt/app-static/`) or a fresh image build/restart to pick up static asset
changes. Symptom if missed: browser-side JS that depends on a new static
file silently no-ops (see "Export browser logs" below, where this exact gap
made a freshly added script 404 and its hooks evaluate to `undefined`).

## Session-id chip and the chat agent's system prompt

The chat header shows the harness session id as a click-to-copy chip
(`#session-id`, next to the status chip). One click puts the id on the
system clipboard — via `navigator.clipboard` in secure contexts, else a
hidden-textarea `execCommand` fallback, since this UI is usually served
over plain http where the async clipboard API does not exist. The id is
also the transcript file name: `/data/web/sessions/<id>.json` in the
container (`sess-…` ids, distinct from the provider's canonical id shown
beside it).

`main` configures the harness with a chat-agent system prompt
(`%chat-agent-system-prompt`, `src/application.lisp`): the agent is told
the repo is mounted at `/app` and docs live in `/app/docs/`, and that when
given a session id and asked to debug it, it must read the docs that
currently exist there first, then that session's transcript under
`/data/web/sessions/`. The harness appends the agent's own session id and
transcript path (see [Agent system prompt in
docs/sm-harness.md](sm-harness.md#agent-system-prompt)).

## Backend/model selection and the session info panel (#106)

The new-session flow (`render-home`, `src/ui/home.lisp`) has two `<select>`
dropdowns, `#backend-select` and `#model-select`, populated directly from
`sm-harness:backend-catalog` (`docs/sm-harness.md`) -- the same static list
`sm-harness:start-session` validates its own `:backend`/`:model` keywords
against, so no choice this UI can produce is ever rejected as unknown.
`#model-select` is repopulated (`%populate-model-select`) whenever
`#backend-select` changes, defaulting to `sm-harness:*default-model-id*`
when it is offered by the newly selected backend; today's catalog has
exactly one backend, so that repopulation is a no-op in practice, but it
stays generically correct rather than assuming that never changes. Clicking
"New session" reads both selects' current `clog:value` and passes them to
`ui-start-session`, which forwards them verbatim to
`sm-harness:start-session` -- this layer does no re-validation of its own,
since sm-harness is the single source of truth for what is legal.

The chat header (`render-chat`, `src/ui/chat.lisp`) gets an "Info" button
(`install-session-info-panel`, `src/ui/session-info.lisp`) that opens a panel
showing the session id, canonical provider id, title, and the backend/model
choice made when the session was created. Backend/model are read straight
from the `SESSION-SNAPSHOT` taken when the chat screen rendered (they never
change over a session's life), formatted back to a human label via
`%backend-label`/`%model-label` (`src/presenter.lisp` -- kept there,
alongside `event-display`/`markdown-to-html`, specifically so they get
`presenter-tests` coverage without needing a live CLOG server); a session
with no explicit model override (created before this feature, or without
picking one) shows "Default" rather than blank, matching that
`harness-config-model`/the CLI's own default is what actually governs. The
canonical id is read fresh from `#canonical-id`'s live DOM text on every
click rather than captured once, so the panel never shows a stale
"Pending…" after the provider assigns a real one mid-session.

Covered end to end by the `session-info` browser E2E scenario
(`e2e/scenarios/session-info.lisp`): selects a non-default model, creates a
session, and asserts the info panel reflects it. Exercising a `<select>`
needed a new generic Playwright op, `select_option`
(`e2e/bridge.mjs`/`+e2e-supported-ops+` in `contract.lisp`) -- `fill` does
not work on `<select>` elements.

## Export browser logs (#92, made more robust in #97)

Both the home and chat headers have an "Export logs" button
(`#export-logs`) that opens a panel (`#logs-panel`) right below the header —
above the transcript/session list, not appended after everything — with a
read-only textarea (`#logs-textarea`) holding this browser tab's captured
log, plus "Copy" (`#logs-copy`, same secure-context/`execCommand`-fallback
clipboard idiom as the session-id chip) and "Close" (`#logs-close`) buttons.
No redaction is applied — it exports exactly what the tab logged.

- **Capture** (`static/log-capture.js`) wraps `console.log/info/warn/debug/error`
  (still forwarding to the original methods), and also listens for
  `window.onerror` and `unhandledrejection`, into a ring buffer capped at
  2000 entries. It is loaded once per tab from `on-new-window`
  (`src/application.lisp`); home↔chat transitions are in-place DOM
  rebuilds within that same JS realm (CLOG swaps `innerHTML` rather than
  navigating), so one load covers the whole tab lifetime, including later
  session switches. Each line is
  `ISO8601Z [LEVEL] [session:<id-or-none>] message`.
- **Page load, clicks, and focus (#97)**, also in `log-capture.js`: a
  `page load: <path><search>` entry is recorded before anything else
  installs, so an exported log always shows when this tab's JS realm
  started and on what screen; a capturing-phase `document` click listener
  logs `click: <#id-or-description>` for every `button`/`a`/`role=button`
  click, generically rather than requiring each Lisp `set-on-click` call
  site to remember to annotate itself, so newly added controls are covered
  automatically; and `window` `focus`/`blur` plus `document`
  `visibilitychange` are logged too, for diagnosing turns that stalled
  because a tab lost focus, went to sleep, or was backgrounded. Because
  console wrapping is only installed once this script has loaded, CLOG's
  own `/js/boot.js` reconnect/error status (it logs purely via
  `console.log`/`console.error`) is captured for any reconnect that
  happens afterward, but *not* the very first "connecting"/"connection
  successful" pair, which happens slightly earlier, before
  `on-new-window` gets a chance to load this script — that earliest-connect
  gap is still open (a fix would mean this project owning its own
  `boot.html` ahead of CLOG's stock one, deliberately deferred as more
  surface than this pass wanted).
- **Submitted prompt text (#97)**, from `src/browser-logs.lisp`'s
  `%log-send` and `src/ui/chat.lisp`'s Send-button and Enter-to-send
  handlers: a `send: <prompt text>` entry is recorded with the exact text
  just handed to `ui-submit`, before submission -- the generic click
  capture above only ever sees a bare `click: #send`, with no way to reach
  into the composer's value, which is exactly the content most useful for
  diagnosing "did the turn that looked stuck even send what the user
  thinks it sent". No redaction: same as everything else this exports.
- **Navigation and session tagging** (`src/browser-logs.lisp`,
  `%log-nav`/`%log-set-session`, called from `render-home`/`render-chat`)
  record a `nav: home` / `nav: chat <session-id>` entry on every
  transition and tag subsequent entries with the active session id, so an
  exported log can be matched against the per-session server-side event
  log documented above, the same way the session-id chip is meant to be
  used.
- **UI** (`install-log-export-panel`, `src/ui/log-export.lisp`) is shared
  by `render-home` and `render-chat` so pre-session errors are exportable
  too, not just in-session ones.
- No file-download option and no cap configurability for now — copy to
  clipboard only, fixed 2000-entry cap.
- If a freshly deployed/reloaded container's exported panel just says
  `undefined`, see "`reload_harness` only reloads Lisp" above — the static
  script most likely never made it to `/opt/app-static`.

## Dead browser tabs and listener delivery

A tab whose websocket silently died (laptop sleep, network drop) leaves a
harness listener whose CLOG operations time out instead of returning. Two
layers keep that harmless (2026-07-30 incident: exactly such a tab stalled
a session's event pipeline mid-turn until the CLI process gave up and the
turn died as `"internal error"`):

- The harness delivers listener callbacks on a per-listener dispatcher
  thread ([Listener callbacks are
  asynchronous](sm-harness.md#listener-callbacks-are-asynchronous)), so a
  blocked callback can no longer stall the session worker or starve the
  CLI's MCP control requests.
- The chat page's callback (`render-chat`, `src/ui/chat.lisp`) self-prunes:
  on each event it checks `clog:validp` for its own connection and detaches
  its listener the moment the connection is gone, instead of burning
  dead-connection timeouts for the life of the runtime.

The frozen tab itself cannot be revived — CLOG refuses to resume a
connection id it no longer knows ("Reconnection id … not found" in the
log). Reload the page; the session reopens from its durable record and the
next prompt resumes the same provider conversation.

## Silently dead buttons after a stale reconnect (#100)

A *different* bug from the listener-delivery story above: that one is about
the harness stalling on a dead listener callback, this one is CLOG's own
client-side reconnect logic leaving a tab in a permanently broken zombie
state, with the app never telling the user.

**Root cause.** `static/js/boot.js` (CLOG's own file, not one this project
overrides) keeps one global `var ws`; every click/form handler CLOG binds is
server-generated JS closing over that same global for the page's entire
life. If the **web-ui process itself restarts** (container restart,
crash+respawn — *not* `reload_harness`, which already pushes a real
`location.reload()` to every open tab post-reload, see `src/live-reload.lisp`
and #78) while a tab is still open, that tab reconnects using its old
`connection_id`. The fresh process's connection table doesn't know that id
and rejects it via `websocket-driver:close-connection` with the default
close code 1000 ("normal closure"). The browser's `ws.onclose` treats code
1000 as a deliberate, final, application-initiated close and calls
`Shutdown_ws()`, which sets `ws = null` **permanently** with no further
reconnect attempt. Because this app didn't call `clog:set-html-on-close`,
the DOM was left fully intact and interactive-looking — every button then
throws `TypeError: Cannot read properties of null (reading 'send')` on
click (visible only in devtools), with zero application-level feedback.

**Fix (two parts, deliberately not a third):**

- **A — `clog:set-html-on-close` fallback.** `on-new-window`
  (`src/application.lisp`) calls `%install-connection-lost-fallback`
  (`src/browser-logs.lisp`) once per connection, replacing
  `document.body`'s HTML with a visible, actionable "Connection lost.
  Reload to continue." message plus a real `#sm-connection-lost-reload`
  button the moment `Shutdown_ws` runs.
- **B — self-heal in `static/log-capture.js`.** A `setInterval` poll
  watches the plain global `window.ws` (`boot.js` declares it with `var` at
  top level, no module/IIFE, so it really is `window.ws`) for the
  live-then-null transition and auto-`location.reload()`s a couple of poll
  intervals later, so in the common case a user never even sees fix A's
  banner. A `smSawLiveConnection` guard is load-bearing, not decorative:
  `ws` also starts out `null` before the *first* successful connect (e.g. a
  slow initial handshake), and without the guard the poll would misfire a
  reload loop before the app ever got a chance to connect at all. The
  poll/reload-delay interval is overridable via a `?smSelfHealPollMs=<ms>`
  query parameter, purely so browser E2E coverage can isolate fix A from
  fix B racing it (see below); production never sets this.
- **Owning CLOG's `boot.html`/patching `Setup_ws`'s reconnect-vs-shutdown
  distinction at the source was deliberately not done** — same call as
  already made on #97 (see "Export browser logs" above): owning CLOG
  internals is more surface than warranted for this.

**Testing this deterministically, without an actual process restart.** CLOG
exposes the exact client-side trigger as a Lisp-callable function, but note
the correct call is in the `clog-connection` package, *not* `clog:shutdown`
(that symbol is CLOG's whole-server 0-arg shutdown and errors with "called
with one argument, but wants exactly zero" if you reach for it here — an
easy mistake, since the per-connection one isn't re-exported under `clog:`):

```lisp
(clog-connection:shutdown (clog::connection-id body))
;; => (execute connection-id "Shutdown_ws(event.reason='user')")
```

This puts a live tab into exactly the same terminal `ws = null`,
`Shutdown_ws`-already-ran state that a rejected stale reconnect produces.
`e2e/test-hooks.lisp` wraps this as a fixture-only CLOG route,
`/e2e-drop-connection`: opening it (via the generic `open_tab` Playwright
op added to `bridge.mjs`/`+e2e-supported-ops+`, which opens a second tab at
a path and closes it again) shuts down every other currently tracked live
tab — in practice, during a scenario, exactly the primary tab under test.
Two scenarios cover this:

- `connection-lost-recovery` (`e2e/scenarios/connection-lost-recovery.lisp`)
  drops the primary tab's connection, waits for fix B's self-heal, then
  proves recovery by clicking a button again — the only way that click can
  succeed post-drop is a genuine reload (CLOG never revives a connection id
  it no longer knows, see above), and separately confirms the captured
  browser-log buffer was actually discarded by a real page load, not just
  business as usual.
- `connection-lost-fallback` (`e2e/scenarios/connection-lost-fallback.lisp`)
  navigates with `?smSelfHealPollMs=600000` to effectively disable fix B
  for the scenario's lifetime, isolating fix A's banner (`#sm-connection-lost`)
  so it can be asserted on directly, then clicks its own
  `#sm-connection-lost-reload` button to confirm that manual recovery path
  too.

Gotcha hit writing these: `open_tab` must not close the second tab right
after Playwright's `domcontentloaded` fires — that tab's own CLOG
websocket handshake (and so its `on-new-window` server-side callback,
which is what actually triggers the drop) is still client-side JS kicked
off *after* `load`, and closing too early can abort the connection
server-side before `on-new-window` ever runs. `open_tab` waits for `load`
plus a short settle window (`settle_ms`, default 500ms) before closing.

## Contentless "SYSTEM" chips fixed (#102)

The transcript used to show a wall of chips labeled just `SYSTEM` (or
`RATE-LIMIT`) with no other content — see the issue for a screenshot. Root
cause, traced end to end from the CLI's own wire messages through
`sm-harness/src/sdk-adapter.lisp`'s `map-sdk-message` to
`sm-harness-web-ui/src/presenter.lisp`'s `event-display`:

- `event-display`'s `case` had no clause for `:system` or `:rate-limit` —
  two normal, frequent event types, not edge cases — so both fell through
  to the generic catch-all, which rendered only `(princ-to-string type)`
  and discarded the entire payload.
- The single biggest source of chips: the adapter synthesizes
  `(:system :subtype "thinking")` once per extended-thinking block the CLI
  omits from the wire (`sdk-adapter.lisp`), so a turn with several thinking
  blocks produced several contentless chips on its own, on top of the
  CLI's own `type="system"` messages (`subtype "init"` at session/turn
  start, possibly `"compact_boundary"`).
- Separately, `:rate-limit` was worse: `map-sdk-message` mapped
  `rate-limit-event` to a bare `(list (list :rate-limit))`, discarding
  `rate_limit_info` (`status`, `utilization`, `resets-at`, `rate-limit-type`,
  `overage-status`, ...) before it ever reached the UI — no presenter fix
  alone could have shown it.

**Fix:**

- `sdk-adapter.lisp` now carries the real `rate-limit-info` fields through
  to the `:rate-limit` event payload instead of dropping them.
- `event-display` gained dedicated clauses: `:system` renders `"System:
  <subtype>"` (or `"Thinking (details omitted)"` for the synthetic
  thinking subtype specifically, since there's nothing else to show once
  the CLI has omitted the actual thinking text), `:rate-limit` renders its
  fields (`"Rate limit: status: ..., utilization: ..., ..."`), and
  `:unrecognized` renders the SDK class name the adapter already captured.
- The catch-all itself no longer shows only the bare type name: it now
  dumps the full payload as `key: value` pairs via
  `%format-payload-fields`, so a genuinely new, still-unmapped event type
  shows real information instead of a blank badge.
- Per the issue's own ask ("if we have a parser and it ends up at a
  default then we should log that"): every time the catch-all actually
  fires, `%log-presenter-fallback` calls `warn` with the event type,
  session id, and sequence — SBCL prints an unhandled `WARN` to
  `*error-output*` (this container's stdout) with no extra plumbing, so
  it's grep-able apart from ordinary traffic and distinct from the
  existing full-payload `SM-HARNESS-EVENT` operator log (see
  [Operator diagnostics in docs/sm-harness.md](sm-harness.md#operator-diagnostics-per-session-event-logging)),
  which already contains the payload but isn't itself a "this needs a
  dedicated chip" signal.

`:system`/`:rate-limit` events are still not persisted to the durable
transcript (only appended via `%append-transcript` for tool calls,
assistant text, user messages, the followup-cap notice, and a genuinely
distinct terminal outcome) — they remain a live-view-only stream and
vanish on reload/reopen. Left as-is for this fix; a follow-up issue can
revisit whether they belong in the persisted transcript.

### A latent reload bug found (and fixed) while verifying this

Confirming the presenter fix actually reached the running image surfaced a
separate, previously invisible bug: `*reload-harness-system*` and
`*post-reload-hook*` (`sm-harness/src/tool-catalog.lisp`) were both
`DEFPARAMETER`, not `DEFVAR`. `main` (`sm-harness-web-ui/src/application.lisp`)
sets `*reload-harness-system*` to `:sm-harness-web-ui` once at startup so
`reload_harness` covers the whole tree — but `tool-catalog.lisp` is itself
part of `:sm-harness`, so it gets reloaded as a dependency on *every*
`reload_harness` call, including ones targeting `:sm-harness-web-ui`. A
`DEFPARAMETER` unconditionally reassigns on each load, silently resetting
the variable back to its `:sm-harness` default immediately after each
reload finished — so only the very first `reload_harness` call of a
process's life ever actually reloaded `sm-harness-web-ui`; every call after
that quietly reloaded `:sm-harness` alone (still reported as a success)
while the running web UI's own Lisp source went stale, with no error or
warning anywhere. The same reset silently dropped the installed
`*post-reload-hook*` (#78's CLOG re-routing + live browser tab refresh)
after the first reload too. Both are now `DEFVAR`, which only initializes
when unbound, so `main`'s startup `SETF` survives every later reload.

## Self-healing CLOG's static-root after a whole-tree reload (#105)

A `reload_harness` call is meant to touch only this project's own Lisp
files, but ASDF occasionally decides the *entire* dependency tree is
stale (seen once with stale fasls after same-day `.asd` edits) and
reloads everything, CLOG included -- visible after the fact only as
thousands of `CLOG` redefinition warnings in that call's output rather
than the usual handful of lines naming files under this repo. CLOG keeps
its static-asset directory in a plain `defparameter`
(`clog-connection:*static-root*`, `clog-connection.lisp`), assigned only
once, by `clog:initialize` at boot -- nothing else in CLOG ever sets it
again. Re-evaluating that `defparameter` during a whole-tree reload resets
it to `NIL`, and from that moment every static asset request (`/app.css`,
`/js/jquery.min.js`, `/log-capture.js`, ...) 500s from
`lack/middleware/static::call-app-file` -- while the harness, sessions, and
health check all keep looking fine, since none of them touch static
files. The 2026-07-30 incident stayed broken until a container restart,
because nothing revalidated CLOG's own internal state after a reload,
only this app's routing table (#78, previous section).

**Fix:** `%refresh-after-reload` (`src/live-reload.lisp`) now calls
`%reassert-static-root` first, which re-derives the expected path from
`*web-ui-config*` (already stored by `start-web-ui`) and writes it back to
`clog-connection:*static-root*` whenever it doesn't match -- a harmless
no-op on the vast majority of reloads that never touch CLOG, since the
comparison then simply confirms nothing was clobbered. When it does have
to repair the value, it also logs a line to stdout naming the value it
found and pointing at this issue, so a whole-tree reload leaves an
explicit trace instead of a silent, deferred 500 the next time a browser
tab loads.

## Fixture E2E

```bash
sg docker -c './scripts/run-web-ui-e2e.sh'
```

The host-side script resets disposable E2E state, builds the app/runner, waits
for the CLOG fixture service, and runs Playwright on an internal-only network.
The Playwright container has neither Docker access nor provider credentials.
`WEB_UI_E2E=1` injects a deterministic SDK transport.

Evidence defaults to the Caddy-served host directory:

```text
$HOME/evidence/sm-harness-web-ui-e2e/latest/
```

Override it per run with `E2E_ARTIFACTS_DIR=/absolute/path`. On this host, the
default is browsable through the Tailnet at
`https://frosty-hermes.tail6638cf.ts.net/e2e-evidence/latest/`.

## Running browser E2E without Docker

An agent working inside the `web-ui` container itself has no Docker socket
(#61), so `scripts/run-web-ui-e2e.sh` isn't an option there. The Dockerfile
bakes Chromium and its OS deps to `/opt/ms-playwright`
(`PLAYWRIGHT_BROWSERS_PATH`, outside `/app` for the same bind-mount-shadow
reason as `/opt/app-static`) and runs `npm ci` for `sm-harness-web-ui/e2e`'s
driver package, specifically so this works without any extra setup. To run
a scenario directly against a locally started fixture app instead of the
isolated `web-ui-e2e`/`web-ui-e2e-app` compose pair:

```bash
env WEB_UI_E2E=1 E2E_SCENARIO=<name> \
    SM_HARNESS_DATA=/tmp/e2e-data SM_HARNESS_HOST=127.0.0.1 SM_HARNESS_PORT=18080 \
    SM_HARNESS_STATIC_ROOT=/app/sm-harness-web-ui/static/ \
    sbcl --non-interactive --eval '(asdf:load-system :sm-harness-web-ui/e2e)' \
         --eval '(sm-harness-web-ui:main)' &

cd sm-harness-web-ui/e2e
BASE_URL=http://127.0.0.1:18080 ARTIFACTS=/tmp/e2e-artifacts E2E_SCENARIO=<name> \
  node run-e2e.mjs
```

Use a fresh `SM_HARNESS_DATA` per scenario (mirrors what the host script does
via disposable volumes) so one scenario's sessions/fixture state can't change
another's selectors. `SM_HARNESS_STATIC_ROOT` must point at the repo's real
`sm-harness-web-ui/static/` here, not the default `/opt/app-static` — this
container's ambient environment already sets `SM_HARNESS_STATIC_ROOT` for the
*production* chat-agent process, and inheriting that would serve stale
baked-in assets instead of the source tree being tested (see the "`reload_harness`
only reloads Lisp" note above; the same staleness applies here for the same
reason, just one directory over).

Note also (found writing #100's coverage): a handful of fixture scenarios
(`connect-recovery`, `malformed-event-recovery`, `tool-handler-failure`,
`read-recovery`) gate their fixture transport behind a module-level
`defparameter` "available" flag that is only ever consumed *once* per
server-process lifetime, by design (they model a failure that happens
exactly once before a retry succeeds). Re-running one of those scenarios a
second time against the *same* still-running fixture process (rather than a
fresh one) will fail — that is expected, not a regression; restart the
fixture process first. Separately, running the *entire* suite locally in one
pass can hit a pre-existing, unrelated flake: `turn-identity` asserts on
exactly one `.session-row` matching generic "New session — Ready —
<canonical>" text, which can collide with another scenario's own
still-generically-titled session left over earlier in the same run (this
reproduces identically against an unmodified checkout, so it is a known gap
in scenario isolation for local/non-disposable-volume runs, not something
any single scenario is doing wrong).

## Lisp-owned browser E2E contract

The E2E fixture app owns test intent. In fixture mode only, it serializes a
validated contract to `/e2e-contract.json`; production startup never serves or
loads it. The contract contains browser actions, assertions, scenario names,
and evidence suffixes. That makes fixture data, expected UI state, and test
behavior reviewable in Common Lisp beside the harness/UI implementation.

```text
sm-harness-web-ui/e2e/
├── contract.lisp              shared contract validation + JSON serialization
├── scenarios/
│   ├── home-health.lisp
│   ├── new-chat-composer.lisp
│   ├── turn-identity.lisp
│   ├── streaming-layout.lisp
│   ├── errors-recovery.lisp
│   ├── connection-lost-recovery.lisp
│   ├── connection-lost-fallback.lisp
│   └── export-logs.lisp
├── fixture-transport.lisp     test-only deterministic SDK transport
├── test-hooks.lisp            test-only CLOG routes (#100: /e2e-drop-connection)
├── bridge.mjs                 generic Playwright contract interpreter
├── run-e2e.mjs                discovers requested scenario entry points
└── tests/
    └── <scenario>.mjs         one minimal entry marker per scenario
```

### Responsibilities

**Lisp owns:** scenario actions/assertions, fixture transport scripts and call
logs, canonical IDs, persistence expectations, and all test data crossing the
SDK boundary.

**JavaScript owns only:** generic Playwright browser operations (`click`,
`fill`, `press`, waits, DOM assertions, opening/closing an extra tab at a
given path), per-context console/page-error collection, screenshots, traces
on failure, and native WebM finalization. It must not define fixture
responses, expected application state, or bespoke scenario assertions.

Each scenario starts in a fresh browser context. Any cross-scenario dependency
(such as reopening a persisted session) must be expressed explicitly in its
Lisp scenario rather than relying on an earlier page/context.

### Add a scenario

1. Add `e2e/scenarios/<name>.lisp`, returning a scenario object using
   `%e2e-object` and `%e2e-step`.
2. Register the file in `sm-harness-web-ui.asd` under
   `sm-harness-web-ui/e2e-contract`.
3. Add `e2e/tests/<name>.mjs`; it is a minimal marker naming the scenario.
4. Add the scenario function to `e2e-scenario-contract` in `contract.lisp`.
5. Run all scenarios, then optionally one scenario:

   ```bash
   sg docker -c './scripts/run-web-ui-e2e.sh'
   E2E_SCENARIO=<name> docker compose -f compose.sm-harness-web-ui.yaml run --rm web-ui-e2e
   ```

The generic bridge rejects a scenario absent from the Lisp contract or an
unsupported action. Each successful scenario emits a descriptive PNG and a
UTC-timestamped Playwright-native WebM directly into the default Caddy-served
host directory (or the `E2E_ARTIFACTS_DIR` override); no Docker-volume export
step is required.

### Current recovery coverage

`errors-recovery` deliberately causes one fixture transport write failure for
the `retry e2e` prompt. The harness emits only the safe public `internal error`
message (not the fixture/protocol detail), the UI retains the draft, and a
second submission creates a new client and completes canonically. This is a
real harness/transport recovery path, not a mocked DOM error. Other #28 cases
(connect, read, malformed SDK/tool, and persistence failures) remain separate
coverage work.

`connection-lost-recovery` and `connection-lost-fallback` (#100) cover the
client-side stale-reconnect zombie-tab recovery described above — see
"Silently dead buttons after a stale reconnect (#100)".
