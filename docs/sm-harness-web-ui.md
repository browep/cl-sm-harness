# sm-harness-web-ui

CLOG browser UI over `sm-harness`.

## Run

```bash
docker compose -f compose.sm-harness-web-ui.yaml up --build web-ui
# http://127.0.0.1:8080
```

## Fixture E2E

```bash
sg docker -c './scripts/run-web-ui-e2e.sh'
```

The host-side script resets the disposable E2E volumes, builds the app/runner,
waits for the CLOG fixture service, and runs Playwright on an internal-only
network. The Playwright container has neither Docker access nor provider
credentials. `WEB_UI_E2E=1` injects a deterministic SDK transport.

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
│   └── errors-recovery.lisp
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
unsupported action. A successful scenario emits a descriptive PNG and a
Playwright-native WebM in the disposable `sm-harness-e2e-artifacts` volume.
Export evidence to a host directory before tearing down a run when it must be
retained outside Docker.

### Current recovery coverage

`errors-recovery` deliberately causes one fixture transport write failure for
the `retry e2e` prompt. The harness emits only the safe public `internal error`
message (not the fixture/protocol detail), the UI retains the draft, and a
second submission creates a new client and completes canonically. This is a
real harness/transport recovery path, not a mocked DOM error. Other #28 cases
(connect, read, malformed SDK/tool, and persistence failures) remain separate
coverage work.
