# Claude Agent SDK for Common Lisp — Implementation Plan

**Goal:** Build an independent, Docker-tested Common Lisp port of the Claude Agent SDK for Python that communicates with the Claude Code CLI through its JSONL/control protocol.

**Reference:** [anthropics/claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python), pinned to an explicit commit before implementation starts.

**Delivery principle:** Build and verify the smallest behavior first. A Python function/class method is a reference for observable behavior; do not mechanically translate its source. Every supported behavior must have deterministic evidence before any real OAuth-enabled run.

## Non-negotiable boundaries

- All build, test, fixture-generation, integration, and live runs execute in Docker.
- The host requires Docker/Compose only.
- The SDK does not require Python at runtime.
- Root `.env` contains the only credential accepted for live runs:

  ```dotenv
  CLAUDE_CODE_OAUTH_TOKEN=...
  ```

- The token reaches only the opt-in live service. No other authentication scheme is supported, documented, probed, or used as fallback.
- `.env` is ignored by Git and must never enter Docker layers, test vectors, logs, or artifacts.
- Real live calls are opt-in, low-cost, redacted, and run only after offline layers pass.

## Target code structure

```text
claude-agent-sdk-cl.asd          ASDF systems: library and tests
src/packages.lisp                Public and internal package boundaries
src/conditions.lisp              Typed SDK/CLI/process conditions
src/options.lisp                 Claude-agent option validation + JSON encoding
src/types.lisp                   Message/result/content/event representations + decoding
src/transport/protocol.lisp      JSONL framing, JSON codec, request/response routing
src/transport/subprocess.lisp    CLI discovery, spawn, stdin/stdout/stderr, close/kill
src/query.lisp                   One-shot streamed query API
src/client.lisp                  Stateful interactive client lifecycle
src/mcp.lisp                     Deferred: SDK MCP tool/control bridge
src/sessions/                    Deferred: sessions and session-store support

test/fixtures/                   Hand-authored and source-provenance test vectors
test/fixtures/upstream/          Python-reference contract vectors + manifest
test/types.lisp                  Level 1 tests
test/options.lisp                Level 1 tests
test/conditions.lisp             Level 1 tests
test/protocol.lisp               Level 2 tests
test/subprocess.lisp             Level 3 tests
test/query.lisp                  Level 4 tests
test/client.lisp                 Level 4 tests

docker/                          Docker entrypoint/reference setup
scripts/                         Docker-only test and parity wrappers
docs/api-parity.md               Human-readable supported/deferred API matrix
```

## The testing ladder

| Level | Question answered | Test mechanism | Required before advancing |
|---|---|---|---|
| **0. Matrix** | Is the upstream API/test classified? | `docs/api-parity.md` and `test/fixtures/upstream/manifest.json` | No unclassified upstream symbol/test. |
| **1. Pure behavior** | Does an isolated encoder/decoder/validator return the correct value or condition? | FiveAM + JSON vectors | Fixture test passes without process/network. |
| **2. Protocol** | Does JSONL/control behavior match the exchange contract? | Fake transport + request/response transcripts | Exact expected event order, IDs, errors, EOF, and unknown-field behavior. |
| **3. Process** | Does the CLI subprocess lifecycle work? | Docker-local fake `claude` executable | Spawn, writes, stdout/stderr drains, timeout, non-zero exit, and cleanup pass. |
| **4. Public API** | Does a user-facing query/client workflow work? | Public API against the fake transport | Ordered messages, terminal state, cancellation, and resource cleanup pass. |
| **5. Live E2E** | Does the compiled SDK work with the installed Claude Code CLI? | Opt-in Docker run with OAuth token | Redacted evidence plus all lower levels green. |

**Rule:** a Level 5 success is deployment evidence, not a substitute for Levels 1–4.

## Function-to-contract workflow

Use this loop for every upstream Python function, class method, option, or message variant:

1. **Classify.** Add an API-parity row with upstream file/symbol, target Lisp API, category (`pure`, `protocol`, `process`, or `workflow`), planned test file, and status.
2. **Find the smallest observable contract.** Reuse an upstream mock/fixture scenario where possible. Otherwise create a narrow Python reference probe that emits redacted JSON only.
3. **Record provenance.** Store upstream commit, pytest node/source symbol, generation command, and vector SHA-256 in the manifest.
4. **Write a failing FiveAM test.** Place it at the lowest suitable level; do not start with a live test.
5. **Implement the minimum Lisp behavior.** Preserve unknown protocol fields for forward compatibility and signal typed conditions for invalid input/transport failure.
6. **Run the targeted Docker test.** The failure output must identify the Lisp test and upstream fixture/node ID.
7. **Run the complete applicable level.** Do not mark the row supported until it is green.
8. **Add a gated live case only if it adds value.** It must use the root `.env` token, a temporary in-container workspace, redacted evidence, and guaranteed process cleanup.

## Python test reuse plan

A Docker-only reference image pins the upstream repository and is a **test oracle only**. It has no `.env`, OAuth token, or live credentials.

### Direct first-slice sources

| Upstream family | Lisp target | Verification |
|---|---|---|
| `test_message_parser.py`, `test_types.py`, `test_errors.py`, `test_option_warnings.py`, `test_task_compat.py` | Types, options, conditions, protocol decoder tests | JSON input/output/condition vectors at Levels 1–2. |
| `test_query.py`, `test_client.py`, `test_streaming_client.py`, `test_close_cancellation.py` | Query/client API tests | Fake transport scenarios at Levels 2 and 4. |
| `test_transport.py`, `test_subprocess_buffering.py` | Subprocess transport tests | Fake `claude` executable at Levels 2–3. |

### Deferred sources

- MCP tools, callbacks, and hooks: port after query/client transport is stable.
- Sessions, session stores, transcript mirroring, task events, and rate limits: port as separately releasable feature tracks.
- Redis/Postgres/S3 examples: run only against Docker Compose Redis/Postgres/MinIO services after a Lisp session-store protocol exists; never a real external store in CI.
- Python wheel/download/changelog tests: replace with equivalent Lisp packaging/CLI-pinning checks where product behavior applies.

Every one of the upstream suite's 35 test files must appear in the parity manifest as `ported`, `deferred`, or `not-applicable`, with a non-empty rationale for the latter two.

## Phased delivery

### [x] Phase 1 — Reproducible Docker foundation *(completed in `5cd96ed`)*

**Files:** `Dockerfile`, `compose.yaml`, `docker/entrypoint.sh`, `scripts/test.sh`, `.dockerignore`, `.env.example`, ASDF system, test bootstrap.

**Done when:**

```bash
docker compose build --pull
docker compose run --rm test unit
```

loads the test system and runs a known empty/bootstrap FiveAM suite. The image records pinned SBCL, package, and Claude CLI versions. The root `.env` is not copied into the image.

### [x] Phase 2 — Parity catalog and reference oracle *(completed in `f058d68`, hardened in `f60e4a5`)*

**Files:** `docs/upstream-baseline.md`, `docs/api-parity.md`, `test/fixtures/upstream/manifest.json`, reference-image setup, export/verification scripts.

**Done when:** every upstream test file has a manifest row and `docker compose run --rm test parity` fails on missing classification or fixture provenance.

### [x] Phase 3 — Options, types, and conditions *(completed in `28fb83a`)*

**Files:** `src/options.lisp`, `src/types.lisp`, `src/conditions.lisp`, corresponding FiveAM suites and fixtures.

**Done when:** representative Python-derived fixture vectors cover defaults, option serialization, message variants, malformed data, unknown fields, and typed errors—without launching a process.

### [x] Phase 3.1 — Reproducible Python reference dependencies *(completed in `92c0b97`)*

**Files:** `docker/reference/requirements.lock`, reference-image install commands, and reference-build verification.

**Done when:** every dependency needed to execute the selected upstream probes is pinned with hashes or immutable artifact digests; `docker compose build --pull reference` installs only that lock; the reference image reports the pinned upstream commit and dependency snapshot without credentials. The target Lisp image remains Python-free.

### [x] Phase 4 — JSONL protocol and subprocess transport *(completed in `16e72be`, `b8c5631`, and `9d70394`)*

**Files:** `src/transport/protocol.lisp`, `src/transport/subprocess.lisp`, protocol/subprocess tests, fake executable, and focused-test runner support.

**Before implementation:** document the target CLI provisioning contract. Upstream Python normally selects a wheel-bundled executable before a configured/system executable; this port must explicitly state whether it ships a project-owned pinned binary or requires a configured/system path, preserve an explicit `cli-path` override, and not call the current global npm install packaging parity.

**Done when:** offline tests prove partial lines, request routing, EOF, malformed JSON, stderr capture, non-zero exit, timeout, and idempotent close/kill behavior. `docker compose run --rm test unit --suite protocol` and `docker compose run --rm test integration` are real focused commands, not aliases for the whole suite.

### [x] Phase 4.1 — Transport hardening and diagnostic logging *(completed in #10; live follow-up in #11)*
Deterministic Docker-offline hardening + opt-in full-payload diagnostic logging:
- full-payload opt-in lifecycle/protocol logging via an injectable callback
  (`cli.resolve/spawn/stdin.closed/exit/timeout/close`, `jsonl.record/decode_error`,
  `protocol.route/cleanup`); offline tests use synthetic payloads only, no real
  credentials are printed, committed, or placed in fixtures
- concurrent stdout/stderr draining; output readers start before stdin writes
  (256 KiB write-before-read regression) — fixes pipe deadlock classes
- exact stdin preservation (removed implicit trailing newline)
- strict JSONL validation (trailing garbage / non-object roots), trailing-whitespace
  predicate fix, bounded pending records, and `flush-jsonl-framer` EOF contract
- nested upstream `control_response.response.request_id` routing; unmatched control
  traffic routes as internal `:control`, never a user event
- `clear-protocol-router` cleanup helper (logs full `:protocol.cleanup` context);
  intended call site is the Phase 5/6 query loop (protocol layer owns routing)
- injectable CLI discovery + POSIX `test -f`/`test -x` executable validation
  (explicit paths never shell-interpreted); timeout validation before spawn and
  post-timeout recovery
- multi-megabyte (2 MiB) stdout/stderr and interleaved drains under concurrent readers
- deferred live-only items (signal termination semantics, descendant/process-group
  cleanup, reproducibility context, live Claude CLI drift diagnostics) tracked in #11

### Phase 5 — One-shot `query`

**Files:** `src/query.lisp`, `src/transport/subprocess-query.lisp`, `test/query.lisp`, `examples/one-shot.lisp`.

**Deterministic implementation:** complete. `query` provisions an upstream-style
`stream-json` subprocess by default (or accepts an injected transport); fake-CLI
coverage validates ordered stream/result delivery, protocol framing, option mapping,
stdin exactness, pipe deadlock prevention, errors, cancellation, timeout, and raw
transport diagnostics.

**Live evidence:** verified on 2026-07-26 through the credential-scoped,
fail-closed `CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm live` smoke. The
installed CLI returned a successful terminal result (exit 0) after a four-message
stream. The run also exposed and validated typed `rate_limit_event` decoding.
Live evidence complements—never replaces—the deterministic coverage above.

### Phase 6 — Interactive client

**Files:** `src/client.lisp`, `src/transport/subprocess-client.lisp`,
`test/client.lisp`, two-turn/interrupt fixtures, `examples/interactive.lisp`.

**Carry-forward design (post-Phase 5 live evidence):** use a dedicated persistent
stream-json transport—never the one-shot transport, which closes stdin. `connect`
performs a correlated initialize handshake and buffers ordinary events observed
during it; writes are serialized; `result` ends a response but not the connection;
and `interrupt` is a correlated control request rather than OS process termination.
The public client has explicit `:new`, `:connected`, `:closing`, and `:closed`
states with typed invalid-lifecycle conditions. Known `rate_limit_event` records
are typed, and unknown future top-level events must not tear down a live session.

**Status:** complete. Deterministic fake/custom-transport coverage verifies connect
handshake, two-turn order, result response boundaries, interrupt correlation,
process EOF/nonzero cleanup, invalid lifecycle calls, serialized writes, large
stderr drainage, fragmented open-pipe JSONL, and default CLI provisioning.

**Live evidence:** on 2026-07-26 the credential-scoped `live-client` smoke
completed two turns (exit 0). Fixed prompts received exact responses `SDK
interactive turn one OK` and `SDK interactive turn two OK`; both terminal
results had subtype `success`. This evidence complements—not replaces—the
offline Docker matrix.

**Done when:** deterministic fake/custom-transport tests cover connect handshake,
two-turn order, response boundaries, interrupt correlation, process exit, cleanup,
invalid lifecycle calls, and serialized writes. The credential-scoped live two-turn
smoke is evidence only, run after lower layers pass.

### Phase 7 — Advanced parity slices

**Phase 6 carry-forward:** advanced features must build on the persistent client's
control plane, not bypass it with a second reader or a background stdout mailbox.
MCP/tool permission/hook callbacks arrive while a turn is being received, so the
first child slice is an **inbound control-request dispatcher**: decode a CLI
control request, invoke the registered synchronous Lisp handler, serialize its
correlated control response through the Phase 6 write lock, and retain
consumer-driven stdout/backpressure. Handler failures, cancellation, missing
handlers, and duplicate/unknown IDs require deterministic terminal responses and
router cleanup. A generic transport inactivity timeout must never close stdin
while an MCP server or hook callback is active; any deadline is an explicit
turn/control policy with a deterministic fake-clock/fixture test.

Ship linked child issues and documented slices in this order:

1. **Control-plane foundation, SDK MCP/custom tools, permission callbacks, and
   hooks.** **Complete as Phase 7A/#12:** inbound `control_request` and late
   `control_cancel_request` routing; consumer-driven synchronous dispatch;
   serialized correlated replies; typed permission/hook/MCP results; named hook
   and MCP registration; deterministic injected and subprocess fixtures; and
   Docker verification. Source behavior is ported from upstream
   `Query._handle_control_request` (baseline `3145cc637778b23cb3caff7556ab76a10028b084`,
   `src/claude_agent_sdk/_internal/query.py:420-544). Future MCP server
   conveniences expand this stable control plane rather than replacing it.
   Acceptance included typed inbound-control and callback-result models, source
   provenance, fake CLI request/response fixtures, reentrancy/serialized-write
   tests, callback-error tests, and forward-compatible unknown control/event
   handling. Public task/context/rate-limit records must remain ordered relative
   to turns; unknown future events continue to log/skip rather than tear down a
   persistent client.
2. **Read-only sessions plus resume/import/mutation helpers.** **Complete as
   Phase 7B/#13:** pre-spawn session option validation and safe opaque
   identifiers/paths; validated side-effect-free import and mutation plans.
   Provenance: upstream `session_store_validation.py:18-45`,
   `session_import.py:28-104`, and `session_mutations.py:53-179` at baseline
   `3145cc637778b23cb3caff7556ab76a10028b084`. Actual store persistence is
   intentionally deferred to the next slice. Validate every
   session-store option combination before spawning a subprocess. In particular,
   `continue` without explicit `resume` requires a store that implements session
   listing, and session-store mirroring cannot be combined with file
   checkpointing. Session IDs/paths must be normalized and traversal-safe.
3. **Session-store protocol, in-memory conformance, and transcript mirroring.**
   **Complete as Phase 7C/#15:** generic key/store API, deterministic
   in-memory append/load/list/subkey conformance, UUID idempotency, and typed
   public-message mirror hook with best-effort error isolation. Provenance:
   upstream `types.py:1366-1474` and transcript mirror semantics. Define the generic store API and deterministic batch/ordering/error semantics
   before adding a backend. Mirror only typed public records after client routing;
   never make a store write block the transport control path without an explicit
   bounded policy.
4. **Filesystem session-store adapter.** **Complete as Phase 7D/#16:** local
   JSONL filesystem persistence implementing the generic protocol, UUID
   idempotency, deterministic listing, and root-bound traversal checks.
   Provenance: Phase 7C store contract plus upstream session key semantics.
   Implement one local filesystem-backed
   adapter only after generic store conformance is stable. It uses a configured,
   traversal-safe root and deterministic fixture directories; it is the sole
   Phase 7D backend and requires no service container or credentials.

Redis, Postgres, MinIO/S3-compatible, and other remote adapters are explicitly
out of Phase 7. They belong to a separately tracked future integration ticket
and must not expand the Phase 7 acceptance scope.

Each child repeats manifest → provenance fixture → failing FiveAM test →
implementation → Docker verification. A separately gated live check is evidence
only after the corresponding deterministic slice passes; it prints no raw
transport diagnostics or credentials.

## Planned command interface

```bash
# Offline fixture and unit test suite
docker compose run --rm test unit

# Focused suite/test
docker compose run --rm test unit --suite protocol --test decode-assistant-message

# Fake-CLI subprocess suite
docker compose run --rm test integration

# Upstream-contract manifest and vector verification
docker compose run --rm test parity

# Explicit live smoke test; compose reads CLAUDE_CODE_OAUTH_TOKEN from root .env
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm test live
```

These are the required target commands; the Docker harness will introduce them in Phase 1.

## Deliberate exclusions

- Python-to-Common-Lisp transpilation or a Python proxy runtime.
- Direct Anthropic Messages API implementation.
- Credentials other than `CLAUDE_CODE_OAUTH_TOKEN` in root `.env`.
- Non-Docker development/test runs.
- Treating one successful live response as functional parity.
- Default TLS interception/network capture with mitmproxy. If needed for a one-off OAuth/network diagnosis, it must be an isolated opt-in debug profile with no persisted sensitive capture; it is not part of the standard test ladder.

## Definition of done for v0.1

- Docker-only build/test workflow is reproducible from a clean checkout.
- `query` and interactive client APIs are documented and pass Levels 1–4 deterministic tests.
- Live tests are explicitly gated, OAuth-only, redacted, and prove cleanup.
- CLI discovery/version, malformed JSON, process errors, cancellation, and invalid client state produce documented typed conditions.
- The parity manifest has no unclassified upstream tests, and every supported behavior links to fixture/test evidence.
- README and API parity docs document current support, deferred areas, and intentional differences.
