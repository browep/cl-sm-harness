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
/opt/app-static/`) or a rebuilt image to pick up static asset changes —
**a bare container restart on the *same* image does not help**: confirmed
2026-07-30 when a restart meant to pick up #111's new chip CSS left the
homepage rendering with none of it, because `docker/entrypoint.sh` never
re-copies `/opt/app-static` on boot, only the Dockerfile's build-time `COPY`
ever populates it. Symptom if missed: browser-side JS that depends on a new
static file silently no-ops (see "Export browser logs" below, where this
exact gap made a freshly added script 404 and its hooks evaluate to
`undefined`), or, for CSS specifically, the page renders with stale/missing
styling and no error anywhere (nothing 404s — the old file is still there
and still valid CSS, just outdated).

**Browser-side caching compounds this.** Even after `/opt/app-static` is
correctly refreshed server-side, an already-open tab (or a fresh page load
in the same browser profile) can still show the old styling: `app.css` is
served with no `Cache-Control`/`Expires` header (only `Last-Modified`), so
a browser is free to keep serving a previously-fetched copy from its own
HTTP cache without ever revalidating, even across an ordinary reload.
`on-new-window` (`application.lisp`) therefore loads `%app-css-href`'s
value (`presenter.lisp`) instead of a bare `"/app.css"`: that function
appends the actually-served file's own `file-write-date` as a `?v=`
query string, so the URL itself changes the instant the file's content
changes on disk -- independent of whether the Lisp process was ever
restarted, which is exactly the scenario that bit us (`/opt/app-static`
re-copied with no restart in between). A missing/unreadable file or unset
`*web-ui-config*` (headless/test contexts) degrades to the plain
unversioned URL rather than erroring.

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

## Richer home-screen session chips (#111)

Each row in the home screen's session list (`render-home`, `src/ui/home.lisp`)
used to be one plain dash-joined line: `"<title> — <status> — <canonical id
or Pending…>"`. That left out most of what an operator actually wants to see
at a glance when several sessions are open -- which backend/model a session
uses, how many turns it has had, and how long ago it started -- so the issue
asked for a chip that shows all of: session id, backend, model, turn count,
time since start, and canonical id (title/status are kept too, for
continuity with the pre-#111 chip).

**Data.** `sm-harness:session-summary` gained `created-at`/`turn-count`
fields (`docs/sm-harness.md#session-summary-chip-metadata-turn-count-and-start-time-111`)
so the home screen never needs anything beyond what `list-sessions` already
returns -- no per-row round trip to load a full transcript just to render a
chip.

**Rendering.** The chip's inner HTML is built by
`%session-chip-html` (`sm-harness-web-ui/src/presenter.lisp`), not inline in
`render-home`, for the same reason `event-display`/`%backend-label`/
`%model-label` already live there: it gets `presenter-tests` coverage
without needing a live CLOG server. Every field is `escape-text`'d before
insertion, including title and canonical id -- both ultimately come from
outside this process (a future editable title; the CLI's own session id),
so they don't get a free pass just because nothing edits titles yet.
Backend/model reuse `%backend-label`/`%model-label` from #106 (so "Default"
still means "no explicit per-session model override", not blank); turn count
goes through `%turn-count-label` (pluralizes: "1 turn" vs "3 turns"); elapsed
time goes through `%format-elapsed`, which parses the fixed
`sm-harness::%now-iso` timestamp shape and buckets into `"just now"`/`"Nm
ago"`/`"Nh ago"`/`"Nd ago"`, clamping a small clock-skew-induced negative
delta to `"just now"` rather than ever printing something like `"-3s ago"`,
and degrading to `"unknown"` for a summary from before this feature (blank
`created-at`) instead of erroring.

**Markup/styling.** The row is still one clickable `<button class="session-
row">` (unchanged: the whole chip opens that session), now containing a
`chip-top` line (title + a status pill reusing `.status-chip`, with a
per-status color modifier class like `.status-ready`/`.status-error`) and a
`chip-meta` line of individual pill-style `chip-item` spans for session id,
backend, model, turn count, elapsed time, and canonical id (`static/app.css`).
Only `<span>`s nest inside the button (phrasing content, valid HTML) --
no `<div>`s -- so the row stays a single valid interactive element.

**Compatibility.** The `turn-identity` browser E2E scenario
(`e2e/scenarios/turn-identity.lisp`) previously asserted on the old
dash-joined text as one blob; it now asserts against the specific
`.chip-title`/`.chip-status`/`.chip-canonical`/`.chip-turns` elements
instead, which is more precise, not just adjusted to keep passing.

**Dark-on-dark title, and a click affordance (both reported right after
shipping).** `.session-row` is a `<button>`; buttons don't inherit
`color`/`font` from the page by default in the UA stylesheet (every other
button-styled control here, `.btn`, already set both explicitly -- this
one just hadn't), so `.chip-title` rendered in the browser's default dark
button text color against the new dark `.session-row` background: dark on
dark. Fixed by setting `color`/`font: inherit` explicitly on `.session-row`
itself. Separately, a plain pill with no visual affordance didn't read as
obviously clickable, so `.session-row` also gained an explicit
`cursor: pointer`, a `:active` press state (darker background, blue
border, a slight `scale(0.995)`) distinct from the steady-state `:hover`
look, and a right-aligned `›` chevron (a `::after` pseudo-element, dimmed
by default, brightening and nudging right on hover/focus) marking the
whole row as "opens this session" before the first click.

## Export browser logs (#92, made more robust in #97, persisted in #120)

Both the home and chat headers have an "Export logs" button
(`#export-logs`) that opens a panel (`#logs-panel`) right below the header —
above the transcript/session list, not appended after everything — with a
read-only textarea (`#logs-textarea`) holding this browser tab's captured
log, plus "Copy" (`#logs-copy`, same secure-context/`execCommand`-fallback
clipboard idiom as the session-id chip) and "Close" (`#logs-close`) buttons.
No redaction is applied — it exports exactly what was captured.

- **Capture** (`static/log-capture.js`) wraps `console.log/info/warn/debug/error`
  (still forwarding to the original methods), and also listens for
  `window.onerror` and `unhandledrejection`. It is loaded once per tab from
  `on-new-window` (`src/application.lisp`); home↔chat transitions are
  in-place DOM rebuilds within that same JS realm (CLOG swaps `innerHTML`
  rather than navigating), so one load covers the whole tab lifetime,
  including later session switches. Each line is
  `ISO8601Z [LEVEL] [session:<id-or-none>] message`.
- **Durable, cross-tab storage (#120)**: entries are written to
  `window.localStorage` (key `smBrowserLog`), not just an in-memory array —
  localStorage is per-*origin*, not per-tab, so every open tab on this app
  reads and appends to the same underlying log. A reload no longer loses
  history, and an export from one tab can include what a different tab (or
  an earlier page load in the same tab, before a crash/reload) logged.
  Each `push()` does a read-modify-write of the whole stored array; there
  is no cross-tab locking, so concurrent writes from two tabs can
  occasionally interleave imperfectly, an accepted tradeoff for a
  diagnostic feature over actual write-locking machinery. The store is
  capped at 2000 entries (oldest dropped first); a probe at load time
  falls back to an in-memory array, scoped to that tab only, if
  localStorage throws (sandboxed iframe, disabled storage, etc.) — capture
  never lets a storage failure propagate into app code. `__smExportLogs()`
  (called by `export-browser-logs`, `src/browser-logs.lisp`) returns only
  the most recent 500 of those entries, not the whole capped store, to
  keep an export a reasonable size to paste into a bug report.
- **Page load, clicks, and focus (#97)**, also in `log-capture.js`: a
  `page load: <path><search>` entry is recorded before anything else
  installs, so an exported log always shows when this tab's JS realm
  started and on what screen; a capturing-phase `document` click listener
  logs `click: <#id-or-description>` for every `button`/`a`/`role=button`
  click, generically rather than requiring each Lisp `set-on-click` call
  site to remember to annotate itself, so newly added controls are covered
  automatically — and this is entirely local (storage/memory only, never
  the network), so a click is still logged even while this tab's websocket
  is closed (#120), same as every other capture path here; and `window`
  `focus`/`blur` plus `document` `visibilitychange` are logged too, for
  diagnosing turns that stalled because a tab lost focus, went to sleep,
  or was backgrounded. Because console wrapping is only installed once
  this script has loaded, CLOG's own `/js/boot.js` reconnect/error status
  (it logs purely via `console.log`/`console.error`) is captured for any
  reconnect that happens afterward, but *not* the very first
  "connecting"/"connection successful" pair, which happens slightly
  earlier, before `on-new-window` gets a chance to load this script — that
  earliest-connect gap is still open (a fix would mean this project owning
  its own `boot.html` ahead of CLOG's stock one, deliberately deferred as
  more surface than this pass wanted).
- **`pagehide`/`pageshow` for mobile backgrounding (#120)**: in addition
  to `visibilitychange` above, `window` `pagehide`/`pageshow` are logged
  with an explicit `(bfcache)`/`(from bfcache)` suffix when
  `event.persisted` is set. These are the events the Page Lifecycle API
  (web.dev) recommends for detecting a page about to be frozen or evicted
  — unlike `unload`/`beforeunload`, which mobile browsers are not
  obligated to fire at all when backgrounding/killing a tab, `pagehide` is
  expected to fire first, and gives an exported log an explicit marker for
  "the tab was about to be backgrounded/evicted here" that `blur`/
  `visibilitychange` alone can miss or lag on some mobile WebViews.
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
  used. The session tag itself is still an in-memory, per-tab variable
  (reset by a reload until the Lisp side re-tags it) — only the log lines
  it gets baked into at write time persist, same as everything else.
- **UI** (`install-log-export-panel`, `src/ui/log-export.lisp`) is shared
  by `render-home` and `render-chat` so pre-session errors are exportable
  too, not just in-session ones.
- No file-download option and no cap configurability for now — copy to
  clipboard only, fixed 2000-entry store capped to the most recent
  500-entry export.
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

## Durable connection-lifecycle logging (#122)

Follow-up to #110 ("reconnect detection takes too long"): before another
attempt at detection logic, #110's own investigation called for
instrumenting the connection lifecycle first, since two prior debugging
rounds were inconclusive purely because there was no durable ground truth
to check a guess against (see #110's comments for the full history,
including a stale-closure bug that silently disarmed an earlier
prototype's own probe). This is that instrumentation — no detection logic
changed here, only visibility.

Two files, both under the same durable `web/` project directory
`sm-harness`'s own `session-repository.lisp` already uses for
`index.json`/`sessions/*.json` — no new Docker volume or image change
needed, `/data` is already a durable named volume, already writable
(#89/#90):

- **`web/connection-log.jsonl`** — clean, first-party JSON lines this
  project writes itself, one per line:
  `{"ts":..., "connection_id":..., "event":"opened"|"stale", ...}`.
  `"opened"` comes from `on-new-window` (`src/application.lisp`), which
  CLOG only ever calls for a genuinely *new* connection id, never for a
  reconnect (successful or rejected). `"stale"` comes from a ping-derived
  liveness table: CLOG's own client (`static-files/js/boot.js`'s
  `Ping_ws`) already sends a bare `"0"` message every 10s from every open
  tab: a handler registered on `clog-connection::*message-handlers*` (an
  internal, unexported list, but a `defvar`, not a `defparameter` —
  confirmed by reading `clog-connection-websockets.lisp` — so it is not
  reset by a stray whole-CLOG re-evaluation the way a `defparameter`
  global would be, #105's failure class; the same extension point the
  reverted #110 prototype already used for its `SMPROBE` handler) records
  each ping's connection id as alive with no client-side change at all.
  A background thread (`%install-connection-sweep-thread`,
  `src/connection-log.lisp`) then logs `"stale"` once for any connection
  that has gone `*connection-stale-after-seconds*` (default 30s — three
  missed pings, not one unlucky poll tick) without being seen, and clears
  that flag if the connection is later heard from again so a second lapse
  is reported too.
- **`web/clog-stdout.log`** — a verbatim tee of `*standard-output*`,
  covering the connection-lifecycle lines CLOG's own private, non-exported
  `handle-new-connection` (`clog-connection-websockets.lisp`) already
  prints via plain `(format t ...)`, with no handler-list hook of its own
  to intercept instead: `"New connection id - ID - CONN"`,
  `"Reconnection id - ID to CONN"` (a stale connection's tab successfully
  resuming), and `"Reconnection id ID not found. Closing the connection."`
  (the terminal, unrecoverable case #100/#110 care about most).
  Monkeypatching that private `defun` was deliberately not done: unlike
  `*message-handlers*`, an ordinary `defun` *is* clobbered by any
  re-evaluation of that file — the same failure class as #105 and the
  invalidated #110 field test (see that issue's addendum). `*standard-output*`
  is a plain CL special variable nothing in this project's reload path
  ever resets, and a fresh `bordeaux-threads` thread (which is how CLOG
  spawns its own connection callbacks) was confirmed live, before writing
  this, to still observe a broadcast stream installed this way. Because
  CLOG's own `format t` calls never `force-output` afterward (why would
  they, against a plain console stream), the sweep thread above also
  force-outputs this stream once per tick — worst case this file lags
  real time by one sweep interval, acceptable for a diagnostic log, and a
  clean shutdown (`%stop-connection-log`, below) flushes immediately
  regardless.
- **Deliberately not captured:** CLOG's `"Connection id ID has closed"`
  line (`handle-close-connection`) turns out to be gated behind
  `clog-connection:*verbose-output*` (default `nil`, confirmed by reading
  the same file) — and that flag also makes every ping, every UI event
  dispatch, and every JS query round trip log a line, i.e. one line per
  user interaction with the whole app. Far too much durable write volume
  for what this exists to do, so it was not enabled. The ping-derived
  `"stale"` event above is the substitute signal for "this connection is
  effectively gone", and arguably a better fit for #110's actual failure
  modes 2 (an endless silent reconnect retry loop) and 3 (a half-open
  socket) anyway, since neither of those ever reaches a real close at all.

**Installed from two places** (`src/connection-log.lisp`,
`%install-connection-log`, idempotent): `start-web-ui`, before
`clog:initialize`, so a fresh process boot captures its very first
connection too; and the top of `on-new-window` itself, because
`%install-connection-log` is otherwise boot-time-only code that a bare
`reload_harness` does not re-run (see "`reload_harness` only reloads
Lisp" above) — `on-new-window` *does* get re-pointed at fresh code on
every reload (`%reinstall-clog-routes`, called by name from the
post-reload hook, `live-reload.lisp`), so installing there too means a
process that already existed before this feature shipped picks it up live,
from its very next connection onward, without needing a restart.

**Reading it.** Both files are plain, greppable text under `$SM_HARNESS_DATA/web/`
(`/data/web/` in the running container) — an agent working inside this
container can read them directly, unlike the per-session event log
(`docs/sm-harness.md`, "Operator diagnostics"), which only ever goes to
PID 1's stdout, a pipe to Docker this container has no socket to read
(#61). Correlate a specific tab's trouble by `connection_id` across both
files, and now the browser's own captured log too: `static/log-capture.js`
logs a `connection_id: <id>` line (handling both possible orderings —
already set by the time this script's own, separately-fetched `<script
src>` finishes loading, versus not yet — via an accessor on
`clog.connection_id` that catches either), verified to actually match
the id this same connection produced in `connection-log.jsonl`. The two
other deliverables #122 originally scoped (a client log recoverable
without a live socket, and a build/version marker on `log-capture.js`)
are still left for a future pass.

**Not yet done:** the actual reconnect-detection logic this instruments
for is still #110, unchanged by this work.

## Hide/unhide reload-on-resume (#110, after two reverted reconnect experiments)

`static/log-capture.js`'s `pagehide`/`pageshow`/`visibilitychange`
handlers (#120) were purely diagnostic logging until two rounds of actual
reconnect experiments here — both tried, both reverted, in favor of a
much simpler approach informed by what they found. This section covers
all three, in order, because the negative results are exactly what
justify the current design; skipping straight to "just reload" without
this trail would look like giving up rather than the evidence-driven
conclusion it actually is.

**v1 (forced close, uncommitted logic first, later shipped).** On resume
past a hidden-duration threshold, if `window.ws.readyState` was
`CONNECTING`/`OPEN`, force-close it — `rc()` (boot.js's private reconnect
closure) can't be called directly, but forcing `ws.close()` triggers
whichever `onclose` handler `boot.js` currently has attached, achieving
the same effect without touching CLOG internals. Had to close with an
explicit non-1000 code (confirmed by testing against a real server: a
bare `ws.close()` landed as code 1000, which routes to `Shutdown_ws()`
instead of `rc()` — the opposite of the goal). **Field result**: on a real
phone, this correctly kicked `rc()` into an actual reconnect attempt, but
that attempt then sat in `boot.js`'s own opaque, always-retry-every-500ms
loop (it ignores the close code entirely once a reconnect is already in
flight) for ~16 seconds, with every click throwing `InvalidStateError:
Still in CONNECTING state` the whole time, before finally succeeding.

**v2 (suppress + drive our own reconnect, reverted, never committed).**
Took over the decision instead of nudging `boot.js`'s: on hide, replace
`window.ws`'s `onclose`/`onerror` with a no-op logger, so CLOG's automatic
reconnect-on-close never starts while backgrounded (nothing left to get
stuck mid-`CONNECTING` for the whole hidden window). On resume, if not
`OPEN`, drive one reconnect attempt directly via `window.adr` (the
already-computed `wss://.../clog` base URL) and `window.Setup_ws` — both
plain top-level globals in `boot.js`, no module wrapper, confirmed
reachable without redefining or monkeypatching anything CLOG owns.
**Field result**: the server had *already evicted* the session
(`Reconnection id ... not found`, confirmed directly in
`web/connection-log.jsonl`/`clog-stdout.log`, #122) by the time the
resume-triggered attempt reached it, several minutes after backgrounding.
Chased the root cause properly (read `websocket-driver`'s own
`read-websocket-frame`, `src/ws/base.lisp`): no ping/pong, no configured
timeout anywhere in this stack (checked this app's own config and
`websocket-driver`'s server code directly) — eviction is driven purely by
a blocking socket read returning EOF/error, which happens the moment the
OS delivers a real TCP FIN/RST. Both real field traces captured so far
show a mobile OS actively, promptly tearing the connection down on
backgrounding (`code=1006`), detected by *both* client and server within
seconds, symmetrically. **Reconnect fundamentally cannot help this specific
case**: it only ever wins in the asymmetric window where the server
hasn't noticed yet even though the client has (e.g. a real network
handoff with no FIN ever reaching the server) — a case neither real trace
has actually hit. Deferring the attempt to "on resume" (v2's whole
premise) makes this worse than v1, not better, since it guarantees trying
only after the longest possible delay.

**v3 (current): stop attempting reconnect at all.** Track hide/unhide
timestamps only; on resume past `smHideResumeThresholdMs` (default
15000ms, overridable via that query parameter, same idiom as
`smSelfHealPollMs`), reload the page outright —
`SM-RELOAD-IF-HIDDEN-LONG-ENOUGH`. No readyState inspection, no forced
close, no attempted reconnect. This reaches the *same* recovery #100's
fallback banner/self-heal poll already produce after a failed reconnect,
just without first burning 15-20+ seconds on a doomed handshake with
every click throwing in the meantime — the actual, measured cost of both
v1 and v2 in the field. The durable session record (not anything
CLOG-level) is what the reload resumes from, same as every other recovery
path in this app; verified the reload lands back on the exact
`/sessions/<id>` URL and the transcript is intact.

**Logged, start and result, every time**: `hide/unhide reload check
(<trigger>): start, hidden_ms=<n>` followed by exactly one of
`result=skipped (below threshold or no prior hide)` or
`result=reloading`. `visibilitychange` and `pageshow` commonly both fire
for the same resume; the shared `smHiddenAt` timestamp is consumed (reset
to `null`) by whichever runs first, so the second is always a clean skip,
not a repeat.

**Known, deliberate trade-off**: gives up the (never-yet-observed in a
real trace) asymmetric case where a reconnect could have been seamless,
in favor of guaranteed-fast, predictable recovery for the case that
actually keeps happening. Does not preserve any in-flight, unsent
composer text across the reload — a pre-existing limitation shared with
the self-heal poll's own forced reload, not something new here.

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

## Session-switch clicks not updating the address bar (#124)

`render-chat`/`render-home` (`src/ui/chat.lisp`/`src/ui/home.lisp`) are
in-place DOM rebuilds, not real browser navigations (CLOG swaps `innerHTML`
over the same connection), so nothing updates `window.location` unless a
handler does it explicitly via `window.history.replaceState`
(`set-session-route`, added in #43 for the direct-load/new-session case).
That turned out to be exactly the gap: `set-session-route` was only ever
called from the "New session" button's click handler, not from every path
that actually changes what's on screen. Reported symptom (with a
screenshot): click a different session in the home list, and the address
bar still shows a stale URL — reloading the page then resumes the *wrong*
session, not the one visibly open.

**The two missing call sites:**

- Clicking an existing row in the home session list (`render-home`'s
  `list-region` loop) called `render-chat` but never synced the route, so
  the bar kept showing whatever it was on before the click (`/` from the
  home screen itself, or a previous session's stale `/sessions/<id>`).
- "Back to home" (the chat header's `#back-home` button, and the
  not-found screen's `#not-found-home` button, `render-not-found` in
  `home.lisp`) both called `render-home` but never reset the bar back to
  `/`, leaving it pointing at the session just left while home was what
  actually rendered.

**Fix:** rather than patch each call site — which is how this bug happened
in the first place, a case-by-case habit that's easy to forget for any new
caller — the URL sync moved *into* `render-chat`/`render-home` themselves:

- `render-chat` (`src/ui/chat.lisp`) now calls `set-session-route` itself,
  right after `ui-open-session` succeeds (deliberately after, not before:
  a bad `session-id` must not land in the bar ahead of
  `harness-not-found-error` propagating to `application.lisp`'s
  `render-not-found`, which resets the bar back to `/` anyway via the next
  point below). Every caller — a direct `/sessions/<id>` load, "New
  session", and clicking an existing row in the list — gets a correct,
  reload-safe URL for free; the "New session" handler's own explicit call
  (the only one that existed pre-#124) was removed as redundant.
- `render-home` (`src/ui/home.lisp`) gained the mirror image,
  `set-home-route` (`window.history.replaceState(null, '', '/')`), called
  at the top of `render-home` itself. A no-op on a direct load of `/`;
  what actually fixes both "Back to home" buttons, since they only ever
  called `render-home`, never the route helper.

**Coverage:** the `turn-identity` browser E2E scenario
(`e2e/scenarios/turn-identity.lisp`) already drove exactly the click path
that exposed this (create a session, go back to home, click that
session's row from the list) — `assert_url_pattern` steps were added at
each stage (`^/sessions/[^/]+$` after creation, `^/$` after "Back to
home", `^/sessions/[^/]+$` again after clicking the row from the list),
plus a `reload` immediately after the list-click step to prove a reload
from there actually resumes the session on screen, not a stale one —
mirroring how `direct-session-resume` already proves this for the
session-creation path alone.

## Browser Back closing the tab from a chat view (#125, follow-up to #124)

#124's fix kept the address bar in sync via `window.history.replaceState`
on every view change. That fixed the reload-resumes-the-wrong-session bug,
but `replaceState` overwrites the *current* history entry instead of
adding a new one — so no matter how many views a tab visited (home → chat
A → home → chat B, …), that tab's actual browser session-history stack
never grew past its single starting entry. Reported symptom: pressing the
browser's own **Back** button (not the in-app "Back to home" button, which
#124 already covered) from a chat view **closed the tab** instead of going
anywhere. Root cause: a tab whose session-history stack has nothing before
the current entry has, by design in every major browser, nothing for Back
to do — and the documented behavior for that case, when the tab has no
prior page in history either (opened as a fresh tab/window, exactly how
this app is normally reached), is to close the tab outright rather than do
nothing.

**Fix, two parts:**

- `set-session-route`/`set-home-route` (`src/ui/home.lisp`) switched from
  `replaceState` to `pushState`, guarded by a same-path check
  (`window.location.pathname !== <target>`) so a render whose target
  already matches the current URL — the common case, the initial render
  of a fresh connection — never pushes a redundant duplicate entry; only a
  genuine view change (new session, a session-list click, "Back to home")
  does. This is what actually grows the tab's history stack, restoring
  real Back/Forward semantics.
- Growing the stack alone isn't enough: this app has no logic to
  re-render in place for an arbitrary popped-to URL (it only ever renders
  forward, from a click or a fresh connection). Without more, Back would
  now move the address bar to the previous URL while leaving the *old*
  view still on screen — the same class of bug #124 fixed for forward
  navigation, reintroduced for backward. `static/log-capture.js` gained a
  `popstate` listener that reloads the page outright on Back/Forward,
  reusing the same "reload and let the durable session record resolve the
  correct view" pattern already established by #100's self-heal and #110
  v3's hide/resume reload — `on-new-window` (`application.lisp`) already
  renders home or chat correctly from whatever path is in the bar on a
  fresh connection, which is exactly what a reload here produces, without
  needing new client-side re-render logic for an arbitrary popped route.

**Coverage:** a new `back-navigation` browser E2E scenario
(`e2e/scenarios/back-navigation.lisp`) drives a real `page.goBack()` — a
new generic `go_back` Playwright op (`e2e/bridge.mjs`/
`+e2e-supported-ops+` in `contract.lisp`) — after creating a session, and
asserts the tab lands back on the home screen with the address bar reset
to `/`. This is deliberately a *different* exercise from `turn-identity`'s
existing "Back to home"/session-list clicks: those only ever click
in-app controls, never touch the actual browser history stack, and so
could not have caught this bug (`set-session-route`'s pre-#125
`replaceState` call satisfied every one of those assertions just fine —
the address bar was correct at each step, only Back itself was broken).

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
