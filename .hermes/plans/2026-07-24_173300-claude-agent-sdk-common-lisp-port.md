# Claude Agent SDK Common Lisp Port Implementation Plan

> **For Hermes:** Implement in small, independently reviewable increments; keep the conformance corpus and wire-protocol fixtures authoritative.

**Goal:** Build an MIT-licensed Common Lisp client for the Claude Code CLI that offers an idiomatic, documented equivalent of the Python SDK’s public `query()` and interactive-client capabilities, validated against deterministic protocol fixtures before live CLI smoke tests.

**Architecture:** Keep the implementation transport-first. A `uiop:launch-program` subprocess transport starts the bundled or configured `claude` CLI, a newline-delimited JSON codec parses stdout incrementally, and a protocol layer translates JSON-RPC/control messages into typed CLOS objects. The public API owns no CLI framing logic; it delegates to the transport and protocol layers. Advanced features are introduced only after the core protocol is fixture-compatible.

**Reference baseline:** `anthropics/claude-agent-sdk-python` `main`, inspected 2026-07-24; its package includes public `query`, `ClaudeSDKClient`, `Transport`, errors, types, SDK MCP helpers, session helpers, and a subprocess CLI transport. Pin the exact upstream commit and CLI-version compatibility range in the first implementation commit, then record changes deliberately.

**Tech stack:** Common Lisp; ASDF; FiveAM; `uiop`; `yason` or `jonathan` for JSON; `bordeaux-threads` plus channels/queues only if streaming requires them; an HTTP/MCP library selected after a compatibility spike. Do not require a Python runtime.

---

## Scope and compatibility contract

### First usable release (v0.1)
- One-shot `query` with streamed messages.
- A stateful `claude-sdk-client` supporting connect, send, receive, interrupt, and disconnect.
- Config/options, message/content-block objects, error conditions, subprocess lifecycle, JSONL framing, and deterministic transport fixtures.
- Explicit CLI discovery/version errors and a live smoke test gated by `CLAUDE_CODE_OAUTH_TOKEN` from the root `.env` and an installed `claude` executable.

### Follow-up parity tracks
- SDK-hosted MCP tools and custom-tool callbacks.
- Hook callbacks, permission requests/results, and control-protocol extensions.
- Session inspection/resume/import/mutation/store helpers, transcript mirroring, task events, plugins, sandbox settings, and OpenTelemetry.

### Non-goals for v0.1
- Embedding or reimplementing Claude Code itself.
- Running a hidden Python proxy or making a direct Anthropic Messages API client.
- Claiming exact source-level Python compatibility. The public behavior and wire protocol—not Python type names—are the compatibility target.

## Proposed repository layout

- Create: `claude-agent-sdk-cl.asd` — ASDF system definitions for library and tests.
- Create: `src/packages.lisp` — public/internal package boundaries.
- Create: `src/conditions.lisp` — `claude-sdk-error`, `cli-not-found-error`, `cli-connection-error`, `cli-json-decode-error`, and `process-error`.
- Create: `src/options.lisp` — `claude-agent-options` and validated option serialization.
- Create: `src/types.lisp` — CLOS message/content/result/event model and JSON translation dispatch.
- Create: `src/transport/protocol.lisp` — newline framing plus JSON encode/decode and request/response routing.
- Create: `src/transport/subprocess.lisp` — process spawn, CLI version check, stdin writes, stdout reader, stderr capture, close/kill behavior.
- Create: `src/query.lisp` — one-shot streaming `query` API.
- Create: `src/client.lisp` — interactive `claude-sdk-client` lifecycle/control methods.
- Create: `src/mcp.lisp` — SDK MCP tools/server adapter (after core transport).
- Create: `src/sessions/*.lisp` — session helpers and session-store protocol (after v0.1).
- Create: `test/package.lisp`, `test/fixtures.lisp`, `test/options.lisp`, `test/protocol.lisp`, `test/subprocess.lisp`, `test/query.lisp`, `test/client.lisp`, and fixture transcripts under `test/fixtures/`.
- Create: `examples/one-shot.lisp`, `examples/interactive.lisp`, and later `examples/sdk-mcp-tool.lisp`.
- Create: `README.md`, `CHANGELOG.md`, `LICENSE`, and CI workflow under `.github/workflows/ci.yml`.

## Task 1: Establish upstream baseline and public API matrix

**Objective:** Convert the Python SDK’s exported surface into a versioned, reviewable compatibility matrix before writing implementation code.

1. Pin `anthropics/claude-agent-sdk-python` to a commit SHA in `docs/upstream-baseline.md`; include its package version and the supported Claude Code CLI range.
2. Extract Python `__init__.py` exports, `query` signature, `ClaudeSDKClient` methods, all option fields, message variants, error types, and control message names into `docs/api-parity.md`.
3. Mark every entry as `v0.1`, `later`, or `intentionally different`; document each Common Lisp naming convention and callback/streaming semantic difference.
4. Add a script/test that rejects undocumented public symbols so the matrix remains current.
5. Commit: `docs: define Python SDK compatibility baseline`.

**Validation:** Review the matrix against upstream `src/claude_agent_sdk/__init__.py`, `types.py`, `query.py`, `client.py`, and `tests/`; confirm every export is categorized exactly once.

## Task 2: Bootstrap an installable, testable Common Lisp system

**Objective:** Make a clean checkout load and run an empty test suite on supported implementations.

1. Create `claude-agent-sdk-cl.asd` with `:claude-agent-sdk-cl` and `:claude-agent-sdk-cl/tests` systems.
2. Add packages with a narrow public package, e.g. `claude-agent-sdk`, and internal packages using `%` naming only where necessary.
3. Select and pin dependencies with documented rationale; prefer portable libraries and support SBCL first.
4. Add FiveAM test bootstrap and CI for SBCL (add CCL only after the core is passing).
5. Create `README.md` with loading and test commands.
6. Commit: `build: bootstrap ASDF system and FiveAM suite`.

**Validation:** In a fresh Quicklisp/Ultralisp environment, load `:claude-agent-sdk-cl/tests` and run `fiveam:run!` with zero failures.

## Task 3: Model options, errors, and wire-domain types from fixtures

**Objective:** Define stable data representations before process integration.

1. Write fixture-first tests for representative `user`, `assistant`, `system`, `result`, `stream-event`, rate-limit, task, and error messages from the Python test corpus/protocol transcripts.
2. Implement CLOS classes or structs in `src/types.lisp`, preserving unknown JSON fields in an extension slot for forward compatibility.
3. Implement condition hierarchy in `src/conditions.lisp`, carrying CLI exit code, stderr, and causal decoding errors where available.
4. Implement `claude-agent-options` with initialization validation and an encoder that only sends recognized non-NIL fields.
5. Add JSON round-trip tests for outgoing options/control messages and decoding tests for incoming messages.
6. Commit: `feat: add typed protocol model and options serialization`.

**Validation:** `test/options.lisp` and `test/protocol.lisp` pass without a CLI or API key.

## Task 4: Build a deterministic JSONL transport and subprocess lifecycle

**Objective:** Reliably start, communicate with, drain, and terminate the Claude CLI.

1. Implement a line framer that accepts fragmented bytes/text, produces complete JSON records, and reports malformed records with source context.
2. Implement a fake transport driven by checked-in JSONL request/response fixtures; tests must cover partial lines, EOF, malformed JSON, error response, and stderr capture.
3. Implement subprocess discovery order: explicit option, environment override, PATH lookup, then a condition that tells users how to install/configure the CLI.
4. Implement CLI version probe and minimum-version compatibility check; make the accepted range configurable and covered by fixtures.
5. Spawn with `uiop:launch-program`, write JSONL to stdin, read stdout/stderr concurrently without deadlock, and ensure close is idempotent and kills child processes on failure/cancellation.
6. Commit: `feat: implement JSONL subprocess transport`.

**Validation:** Fixture transport tests execute entirely offline. An opt-in smoke test runs a benign CLI command only when `claude` is installed; it must always clean up the child process.

## Task 5: Ship one-shot `query` streaming

**Objective:** Provide the smallest useful public API compatible with Python’s `query(prompt=..., options=...)` behavior.

1. Write a failing test showing a string prompt becomes the expected initialize/query sequence in the fake transport.
2. Implement `query` to return an idiomatic stream interface (callback, iterator/generator abstraction, or channel chosen in Task 2); document cancellation and backpressure semantics.
3. Decode each received protocol message into public message objects, preserve order, and surface result/error terminal states correctly.
4. Support a caller-provided transport so tests never need a real CLI.
5. Add examples and a live integration test requiring explicit environment opt-in.
6. Commit: `feat: add streaming query API`.

**Validation:** Offline fixture test confirms message order and terminal result; live test sends a minimal prompt only when `CLAUDE_SDK_LIVE_TEST=1`, the root `.env` contains `CLAUDE_CODE_OAUTH_TOKEN`, and `claude` is present.

## Task 6: Ship interactive `claude-sdk-client`

**Objective:** Support multi-turn sessions and core control requests.

1. Create lifecycle tests for connect/disconnect, send message, receive response, interrupt, and reconnect/close failure paths using the fake transport.
2. Implement `claude-sdk-client` with explicit states (`new`, `connected`, `closing`, `closed`) and guards that signal conditions on invalid calls.
3. Route initialize/control request IDs and responses through a single protocol dispatcher; prohibit concurrent writes from interleaving JSON records.
4. Implement `send-message`, `receive-message`/stream consumption, `interrupt`, and `disconnect`; propagate process exit and malformed-control errors to blocked callers.
5. Add transcript fixtures that cover a complete two-turn exchange and an interrupt.
6. Commit: `feat: add interactive Claude SDK client`.

**Validation:** Offline tests prove lifecycle, ordering, cleanup, and error behavior. A gated live test completes a two-turn session and verifies the session ID/result structure.

## Task 7: Add SDK MCP tools and permission/callback bridge

**Objective:** Port the high-value extension path after the transport is stable.

1. Define a CL representation for SDK MCP tool metadata, JSON Schema, and async/synchronous handler adaptation.
2. Implement MCP initialize/list-tools/call-tool messages over the existing control channel.
3. Add tool permission callback protocol with allow/deny result objects and timeout/error behavior.
4. Port hooks incrementally, one event family at a time; start with pre-tool-use and post-tool-use.
5. Add fixture tests for tool invocation, handler error, permission denial, hook timeout, and unknown future hook fields.
6. Commit per capability, e.g. `feat: add SDK MCP tool bridge` and `feat: add tool permission callbacks`.

**Validation:** Fixture conformance tests exercise each callback/control message. Gated live test demonstrates an in-process echo tool invoked by Claude Code.

## Task 8: Add sessions and advanced parity in separately releasable slices

**Objective:** Avoid blocking the core SDK on the Python package’s large session feature set.

1. Port read-only session APIs: list sessions, get session info/messages/subagents.
2. Port session resume/import and mutations: fork, rename, tag, delete.
3. Define a `session-store` generic-function protocol and implement in-memory conformance first; add external stores only as examples/extensions.
4. Add transcript mirroring, task lifecycle messages, context usage, MCP status, plugins, sandbox settings, and optional telemetry as individually tracked slices.
5. For each slice, add a matrix row, fixture test, docs, and changelog entry before declaring parity.

**Validation:** Reuse/translate the Python `tests/test_session_*.py` scenarios into language-neutral JSONL fixtures plus Lisp behavior tests. No advanced feature may rely solely on a live test.

## Task 9: Release engineering and compatibility maintenance

**Objective:** Make the port consumable and maintainable as Claude Code evolves.

1. Publish versioning policy: semantic versioning for Lisp API plus an explicit upstream Python/CLI baseline in every release.
2. Add CI jobs for formatting/linting, offline fixtures, ASDF load, test suite, and gated nightly live smoke tests with secrets isolated from PRs.
3. Add a release checklist for ASDF system metadata, documentation, changelog, license notices, and package distribution target selection (Quicklisp/Ultralisp as appropriate).
4. Add a scheduled/manual upstream-diff workflow that reports changes to upstream exports, types, tests, and CLI protocol fixtures without auto-merging behavior changes.
5. Commit: `ci: add portable test and release checks`.

**Validation:** A clean CI run loads and tests the system with no API key; nightly live evidence captures CLI version, SDK version, redacted transcript metadata, and pass/fail status.

## Docker-only development and test harness

All development, test, fixture generation, and live Claude Code runs execute in Docker. The host only needs Docker/Compose; it must not need SBCL, Quicklisp, the Claude CLI, Python, or an API key in its shell environment.

### Container layout

- Create: `Dockerfile` — pinned Debian/Ubuntu base, SBCL, Quicklisp/Ultralisp setup, build tools, `git`, `jq`, and the Claude Code CLI at a pinned version. Run as a non-root `sdk` user.
- Create: `compose.yaml` — `test` service mounting the repository read-only where possible and named writable volumes only for Lisp dependency caches and test artifacts.
- Create: `docker/entrypoint.sh` — rejects missing commands, logs SBCL/CLI/image versions, and dispatches `unit`, `integration`, `live`, or `shell` targets.
- Create: `scripts/test.sh` — stable command interface used locally and by CI; it calls Docker Compose rather than invoking Lisp directly on the host.
- Create: `scripts/run-live.sh` — a separate opt-in target that passes `CLAUDE_CODE_OAUTH_TOKEN` from the root `.env` only at container runtime, creates a temporary in-container workspace, and writes redacted evidence to `artifacts/live/`.
- Create: `.env.example` with only `CLAUDE_CODE_OAUTH_TOKEN=` and `.dockerignore`/`.gitignore` entries that exclude the real root `.env`, local caches, runtime secrets, and generated artifacts.

### Authentication boundary

The root `.env` is the sole credential source and contains exactly one authentication setting:

```dotenv
CLAUDE_CODE_OAUTH_TOKEN=...
```

`compose.yaml` must inject that value only into the opt-in `live` service (for example with `env_file: .env` on that service). The offline unit and fake-CLI integration services must not receive it. Do not support, document, probe for, or fall back to `ANTHROPIC_API_KEY`, API keys, Bedrock/Vertex credentials, cloud-provider credentials, browser login, or any other authentication mechanism. Never copy `.env` into the Docker build context/image, fixture files, command output, CI logs, or artifacts; redact the variable/value if process-environment diagnostics are emitted.

### Required commands

```bash
# Reproducible offline suite; this is the default for every change.
docker compose run --rm test unit

# A targeted fixture/test name, forwarded to FiveAM.
docker compose run --rm test unit --suite protocol --test decode-assistant-message

# Subprocess integration using a fake Claude executable inside the container.
docker compose run --rm test integration

# Explicitly opt-in real Claude Code run; never runs in ordinary PR CI.
# compose reads CLAUDE_CODE_OAUTH_TOKEN only from the root .env for this service.
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm test live
```

Pin the image digest/base image, SBCL version, Quicklisp distribution date, JSON/test library versions, and Claude CLI version in a lockfile or Docker build args. A `make image`/`docker compose build --pull` path must rebuild cleanly, and CI must run the same commands. Do not bake API keys or transcripts containing prompts/results into layers or git history.

## Layered verification: small parts, protocol behavior, and end-to-end

Yes—verify both function-by-function and end-to-end, but do not attempt a mechanical one-for-one source translation. Python functions that are pure serialization/decoding/validation can have a direct behavior-level counterpart. Async orchestration, subprocess streams, callbacks, and client lifecycle need contract tests because their correct Common Lisp shape will differ.

### Verification ladder

| Level | What is tested | Docker command | Evidence / failure localization |
|---|---|---|---|
| 0. API matrix | Every Python public symbol/option/message is classified as supported, deferred, or intentionally different. | `docker compose run --rm test unit --suite api-matrix` | `docs/api-parity.md` plus machine-readable `test/fixtures/api-matrix.json`; an unclassified symbol fails. |
| 1. Pure function parity | Option encoding, JSON-key conversion, defaulting, enum/condition mapping, input validation, and individual message decoder functions. | `... unit --suite types` | One fixture and one named FiveAM test per behavior; mismatch diff shows expected vs actual JSON/object slots. |
| 2. Transcript/protocol parity | JSONL framing, request IDs, initialize/control sequence, error mapping, partial chunks, unknown fields, cancellation, and EOF. | `... unit --suite protocol` | Checked-in request/response transcripts and fake transport; no real process or network. |
| 3. Process integration | CLI discovery/version checks, stdin/stdout/stderr draining, exit status, timeout, and descendant cleanup. | `docker compose run --rm test integration` | A deterministic fake `claude` executable supplied by the image; test logs retain redacted command/exit details. |
| 4. Public API scenario | `query` and `claude-sdk-client` produce expected ordered messages and conditions against the fake transport. | `... unit --suite query` / `... --suite client` | API-level tests avoid asserting private threads/queues, so internals can change safely. |
| 5. Live E2E smoke | Installed Claude CLI authenticates with the sole supported OAuth token, starts, completes a low-cost fixed prompt, and closes cleanly. | `CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm test live` | Redacted JSON evidence: image digest, SBCL, SDK, and CLI version; event-type sequence; exit status; cleanup confirmation. |

### Function-to-behavior mapping workflow

1. For an upstream Python function/class method, add its row to `docs/api-parity.md`: upstream file/symbol, target Lisp public symbol, status, fixtures, tests, and live scenario if applicable.
2. Classify it as **pure**, **protocol**, **process**, or **public workflow**. A single feature can have tests at several levels.
3. For **pure** functions, translate a compact vector of inputs/outputs into language-neutral JSON fixtures. Run the upstream Python implementation in a *Docker reference service* only to generate/refresh approved fixture vectors; do not make Python a runtime dependency of the Lisp SDK.
4. Write the failing Lisp test against that fixture, implement the smallest Lisp behavior, and run the targeted test in Docker.
5. For **protocol/process** functions, record both sides of the JSONL/control exchange with a fake CLI. Assert messages, order, IDs, terminal conditions, and cleanup—not a line-for-line copy of Python internals.
6. For **public workflow** functions, add an API scenario with a fake transport first, then a gated live E2E smoke only once the deterministic scenario is green.
7. Add the compatibility row and test evidence to the PR/issue before declaring the feature supported.

### Concrete initial slices

- `ClaudeAgentOptions` → `claude-agent-options`: Level 1 JSON serialization/default/invalid-combination tests.
- `message_parser` → `decode-message`: Level 1 fixture per message variant plus Level 2 unknown-field/malformed-line behavior.
- `SubprocessCLITransport` → `subprocess-transport`: Level 2 framing fixtures and Level 3 fake-executable lifecycle tests.
- `query()` → `query`: Level 4 single-prompt transcript; Level 5 live one-prompt smoke after the prior levels pass.
- `ClaudeSDKClient.connect/send/interrupt/disconnect` → client generic functions: Level 4 two-turn and interrupt transcripts; Level 5 two-turn gated smoke.

**Rule:** A feature cannot be marked supported from a live run alone. It needs deterministic fixtures at the lowest applicable level; a live run demonstrates deployment compatibility, not exhaustive correctness.

## Testing strategy

- **Primary:** Offline JSONL fixtures and fake transports derived from documented/observed protocol exchanges. These must cover happy paths, partial framing, cancellation, malformed JSON, process exits, timeouts, unknown fields, and control errors.
- **Secondary:** Dockerized subprocess integration with a deterministic fake Claude executable, then gated Dockerized real CLI integration tests. Live tests use a dedicated temporary in-container working directory, fixed low-cost prompts, timeouts, redacted logs, and guaranteed cleanup.
- **Compatibility:** Track upstream Python test intent in `docs/api-parity.md`; translate behavior, not Python implementation details. Maintain fixture provenance: upstream commit, Python test/symbol, and whether it was hand-authored or generated from the Docker reference service.
- **Portability:** Run unit/fixture tests in the pinned Docker image on SBCL first. Add further Common Lisp implementations as separate image targets only after eliminating implementation-specific process/stream behavior.

## Upstream Python test suite as the parity oracle

The upstream repository currently has **35 Python test files** under `tests/`. We will use them as the functional specification and source of test vectors, but not try to execute pytest tests directly against Common Lisp. Those tests are coupled to Python objects, AnyIO/Trio scheduling, pytest fixtures/monkeypatching, and Python packaging. The reusable artifact is each test's **observable contract**: input/options, mocked CLI/protocol exchange, expected public messages/errors, cleanup behavior, and side effects.

### Docker reference service

- Create: `docker/reference/Dockerfile` (or a `reference` build stage in the main `Dockerfile`) that checks out `anthropics/claude-agent-sdk-python` at the exact commit in `docs/upstream-baseline.md`, installs its pinned Python test dependencies, and runs only inside Docker.
- Create: `tools/export-python-contracts.py` — runs selected deterministic upstream tests or purpose-built probes against the pinned Python SDK and emits redacted, language-neutral JSON contract vectors under `test/fixtures/upstream/<area>/`.
- Create: `test/fixtures/upstream/manifest.json` — one row per upstream test/symbol with: upstream commit, pytest node ID, feature area, classification, target Lisp test, fixture paths, parity state (`ported`, `deferred`, `not-applicable`), and a non-empty rationale for every non-ported row.
- Create: `scripts/verify-parity.sh` — invokes Docker only; validates manifest coverage, regenerates/checks approved fixture vectors, and runs their Lisp FiveAM consumers.

The reference image is a **test-only oracle**, never a runtime dependency or a fallback implementation. It has no `.env`, OAuth token, or live credentials. It must run only deterministic tests/probes and use fake transports/filesystems where upstream supports them.

### Mapping rules

| Upstream test family | Reuse method | Lisp parity target | Initial status |
|---|---|---|---|
| `test_message_parser.py`, `test_types.py`, `test_errors.py`, `test_option_warnings.py`, `test_task_compat.py` | Translate parameterized cases and expected message/condition JSON into fixtures; add direct FiveAM tests per decoder/serializer/validator. | `test/types.lisp`, `test/options.lisp`, `test/conditions.lisp`, `test/protocol.lisp` | First implementation slice |
| `test_query.py`, `test_client.py`, `test_streaming_client.py`, `test_close_cancellation.py` | Reuse mocked transcript/control-flow scenarios; assert public message order, terminal result, cancellation, and cleanup. | `test/query.lisp`, `test/client.lisp` plus fake transport | v0.1 |
| `test_transport.py`, `test_subprocess_buffering.py` | Port process and stream edge-case intent to a deterministic fake `claude` executable built into the test image. | `test/subprocess.lisp` | v0.1 |
| `test_tool_callbacks.py`, `test_mcp_large_output.py`, `test_sdk_mcp_integration.py` | Translate control-protocol transcripts and tool/permission callback contracts. Add a Docker-local fake MCP server before a gated real CLI case. | `test/mcp.lisp`, `test/hooks.lisp` | Follow-up parity track |
| `test_sessions.py`, `test_session_*`, `test_transcript_mirror.py`, `test_rate_limit_event_repro.py` | Convert fixture/state-machine behavior into Lisp session-store and transcript tests. | `test/sessions/*.lisp` | Follow-up parity track |
| `test_example_redis_*`, `test_example_postgres_*`, `test_example_s3_*` | Reuse adapter conformance intent only after a Lisp session-store protocol exists. Run Redis/Postgres/MinIO as Docker Compose services; never use a real external store in CI. | adapter-specific systems/tests | Deferred; explicitly out of v0.1 |
| `test_build_wheel.py`, `test_download_cli.py`, `test_update_cli_version.py`, `test_changelog.py` | Do **not** port Python packaging implementation tests. Derive equivalent Lisp release/CLI-pinning checks where the underlying product behavior applies. | Docker build/release checks | Intentionally different |

### Per-test parity workflow

1. Add every upstream test file/node ID to `test/fixtures/upstream/manifest.json`; CI fails if an upstream test is missing a classification.
2. For a candidate test, identify the smallest observable contract. Prefer an existing upstream mocked transport fixture; otherwise write a narrow Python probe in the reference image that emits JSON only.
3. Check in the approved redacted vector with provenance (`upstream_commit`, source node ID, generation command, and SHA-256). Do not check in OAuth data, environment dumps, or unredacted live transcripts.
4. Write a failing FiveAM test against the vector at the lowest verification level: pure function, protocol, process, or public workflow.
5. Implement the Lisp behavior; run the targeted `docker compose run --rm test unit --suite ...` command.
6. Run `docker compose run --rm test parity` to verify the manifest and all mapped vectors. A mismatch must name the upstream node ID, fixture, and Lisp test.
7. Only after deterministic parity is green, add/enable the relevant gated OAuth live E2E scenario. Link the evidence to the upstream manifest row.

### What “parity” means

- **Required:** same supported public behavior, serialized CLI/control messages, decoded public message/condition semantics, ordering, and resource cleanup for the mapped scenario.
- **Allowed difference:** idiomatic Common Lisp naming, CLOS/condition representation, and concurrency primitives, provided documented public behavior matches the contract.
- **Not accepted:** matching only a successful live response while omitting upstream edge cases; silently dropping unsupported fields; declaring an upstream test irrelevant without a manifest rationale.

Because upstream is MIT-licensed, copied fixture data or directly adapted test text must retain appropriate provenance/attribution in the fixture header and repository notices. Prefer newly written, behavior-equivalent Lisp tests rather than carrying Python test harness code.

## Risks and decisions to settle before Task 2

1. **Streaming API:** Choose a library with portable cancellation/backpressure semantics; do not expose a raw implementation-specific thread/channel type publicly.
2. **JSON library:** Confirm correct Unicode, large-number, key-style, and `null` behavior against protocol fixtures before committing to a dependency.
3. **Subprocess portability:** Start with Linux/macOS SBCL support and state Windows support separately; validate child-process-tree cleanup explicitly.
4. **MCP dependency:** Evaluate mature Common Lisp MCP/JSON-RPC options in a short spike. If none meet the control protocol requirements, implement only the narrow stdio subset used by SDK-hosted tools.
5. **CLI protocol drift:** Treat every CLI update as a compatibility event. Preserve unknown fields and maintain fixtures from live captures with secrets removed.
6. **Licensing:** Retain Anthropic MIT attribution/notices where source-derived code or fixtures require it; write the port as an independent implementation unless a direct translation is intentional and documented.
7. **Transpilation:** Do not make a Python→Common Lisp transpiler part of the build. Repository searches did not identify a maintained general-purpose Python-to-Common-Lisp transpiler; the only `Py2Lisp` result found was an unmaintained 2017 socket client/server project, not a translator. Use the upstream Python source as behavioral reference and fixture generator, not as generated production Lisp.

## Definition of done for v0.1

- `query` and `claude-sdk-client` are documented public APIs with fixture-driven tests.
- No Python process/runtime is required.
- Offline CI passes from a fresh checkout; live tests are opt-in and leave no child processes.
- CLI discovery/version, malformed JSON, non-zero process exit, cancellation, and invalid client state have typed, documented conditions.
- README contains installation, one-shot, interactive, configuration, permissions/security, testing, and compatibility-baseline documentation.
- `docs/api-parity.md` explicitly lists all Python SDK features as supported, deferred, or intentionally different.
