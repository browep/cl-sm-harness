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

### Phase 2 — Parity catalog and reference oracle

**Files:** `docs/upstream-baseline.md`, `docs/api-parity.md`, `test/fixtures/upstream/manifest.json`, reference-image setup, export/verification scripts.

**Done when:** every upstream test file has a manifest row and `docker compose run --rm test parity` fails on missing classification or fixture provenance.

### Phase 3 — Options, types, and conditions

**Files:** `src/options.lisp`, `src/types.lisp`, `src/conditions.lisp`, corresponding FiveAM suites and fixtures.

**Done when:** representative Python-derived fixture vectors cover defaults, option serialization, message variants, malformed data, unknown fields, and typed errors—without launching a process.

### Phase 4 — JSONL protocol and subprocess transport

**Files:** `src/transport/protocol.lisp`, `src/transport/subprocess.lisp`, protocol/subprocess tests, fake executable.

**Done when:** offline tests prove partial lines, request routing, EOF, malformed JSON, stderr capture, non-zero exit, timeout, and idempotent close/kill behavior.

### Phase 5 — One-shot `query`

**Files:** `src/query.lisp`, `test/query.lisp`, one-shot transcript fixtures, `examples/one-shot.lisp`.

**Done when:** a fake-transport scenario validates the full ordered stream and terminal result, followed by a gated live one-prompt smoke test.

### Phase 6 — Interactive client

**Files:** `src/client.lisp`, `test/client.lisp`, two-turn and interrupt fixtures, `examples/interactive.lisp`.

**Done when:** connect, send, receive, interrupt, disconnect, invalid lifecycle calls, and cleanup all pass deterministically; the gated live two-turn test is evidence only.

### Phase 7 — Advanced parity slices

Ship MCP tools/callbacks/hooks, then sessions/session stores/mirroring, as separate documented slices. Each must repeat the manifest → fixture → failing test → implementation → Docker verification loop.

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
