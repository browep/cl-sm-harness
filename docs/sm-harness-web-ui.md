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
│   └── export-logs.lisp
├── fixture-transport.lisp     test-only deterministic SDK transport
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
`fill`, `press`, waits, DOM assertions), per-context console/page-error
collection, screenshots, traces on failure, and native WebM finalization. It
must not define fixture responses, expected application state, or bespoke
scenario assertions.

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
