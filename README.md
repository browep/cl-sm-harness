# Claude Agent SDK for Common Lisp

An independent Common Lisp port of Anthropic's [Claude Agent SDK for Python](https://github.com/anthropics/claude-agent-sdk-python).

## Goal

Provide an idiomatic Common Lisp interface to the installed **Claude Code CLI**:

- one-shot, streamed `query` requests;
- stateful interactive conversations through a client API;
- typed messages, options, result/error conditions, and deterministic resource cleanup;
- future support for SDK MCP tools, callbacks/hooks, and session helpers.

This project is **not** a direct Anthropic Messages API client and does not reimplement Claude Code. The runtime boundary is Common Lisp ↔ Claude Code CLI over the CLI's JSONL/control protocol.

## Compatibility approach

The Python SDK is the behavioral reference, not a runtime dependency and not a source-to-source translation target. We preserve observable contracts:

- public behavior and documented option semantics;
- serialized control/protocol messages;
- decoded message and condition semantics;
- event ordering, terminal states, cancellation, and process cleanup.

Common Lisp names, CLOS classes/structures, conditions, and concurrency primitives may be idiomatic rather than Python-shaped. Every upstream API/test is tracked as **ported**, **deferred**, or **intentionally different** in the planned parity manifest.

## Planned architecture

```text
Public API: query / claude-sdk-client
              │
              ▼
Options, message types, conditions, protocol dispatch
              │
              ▼
JSONL framing + subprocess transport
              │
              ▼
Claude Code CLI
```

The public API must not own process framing. The transport starts and manages the CLI; the protocol layer owns line framing, JSON encoding/decoding, request IDs, and routing.

Expected layout:

```text
src/
  packages.lisp
  conditions.lisp
  options.lisp
  types.lisp
  query.lisp
  client.lisp
  transport/
    protocol.lisp
    subprocess.lisp
test/
  types.lisp
  options.lisp
  conditions.lisp
  protocol.lisp
  subprocess.lisp
  query.lisp
  client.lisp
  fixtures/
```

## Docker-only development and tests

All development, fixture generation, tests, and live CLI runs are planned to execute in Docker. The host should need only Docker/Compose—not SBCL, Python, Quicklisp, or Claude Code.

The planned command surface is:

```bash
# Offline unit/fixture suite
docker compose run --rm test unit

# Target a suite/test
docker compose run --rm test unit --suite protocol --test decode-assistant-message

# Deterministic fake-CLI subprocess integration
docker compose run --rm test integration

# Opt-in live Claude Code smoke test
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm test live
```

Phase 1 implements the offline `unit` command. It builds a pinned Node base image with SBCL, FiveAM, and Claude Code CLI `2.1.219`; exact resolved runtime versions are retained in `/usr/local/share/claude-agent-sdk-cl/runtime-versions.txt` in the image. The `test` service has network disabled, mounts source read-only, and uses a named `/cache` volume for compiled artifacts.

The `test` service intentionally mounts only its ASDF/source/test/script inputs. It cannot see the root `.env`, and the test wrapper fails closed if an `.env` mount is added. The fake-process, parity, and live commands remain future phases; see [PLAN.md](PLAN.md) for delivery order.

## Authentication boundary

The eventual live Docker service accepts one credential only, supplied from the root `.env`:

```dotenv
CLAUDE_CODE_OAUTH_TOKEN=...
```

Only the opt-in `live` service receives this variable. Unit, fixture, fake-CLI integration, and Python reference-oracle containers receive no credentials.

Out of scope: `ANTHROPIC_API_KEY`, other API-key schemes, Bedrock/Vertex/cloud-provider credentials, browser login, and fallback credential discovery. Never commit `.env`, bake it into an image, or include it in fixtures/logs/artifacts.

## Test and verification ladder

| Level | Focus | Evidence |
|---|---|---|
| 0 | API matrix | Every Python public symbol/test is classified. |
| 1 | Pure behavior | JSON options, type/condition decoding, validation, and defaults use deterministic fixtures. |
| 2 | Protocol | JSONL framing, request IDs, control flow, cancellation, EOF, and malformed records use transcript fixtures. |
| 3 | Process | A fake `claude` executable validates spawn, streams, exit status, timeout, and cleanup. |
| 4 | Public API | `query` and the interactive client run end-to-end against the fake transport. |
| 5 | Live smoke | A gated Docker run uses the installed CLI and OAuth token after deterministic layers pass. |

A live success never establishes feature support on its own. A feature needs deterministic coverage at the lowest applicable level first.

## Upstream test parity

The Python SDK currently has 35 test files. Their observable contracts are reused through a pinned, Docker-only Python reference image:

1. Each upstream test/symbol receives a row in `test/fixtures/upstream/manifest.json`.
2. The row identifies the upstream commit and pytest node, target Lisp test, fixture(s), and parity state.
3. Deterministic Python probes/mock scenarios emit redacted JSON vectors.
4. FiveAM tests consume the same vectors in Lisp.
5. A parity command validates manifest coverage and reports the upstream node ID on mismatch.

Pytest itself will not run against the Lisp implementation; Python test harness mechanics are not the product contract. See [PLAN.md](PLAN.md) for mapping rules and phased scope.

## Status

Phase 1 Docker/test foundation is implemented: `docker compose build --pull` followed by `docker compose run --rm test unit` runs the bootstrap FiveAM suite without network access or credentials. API and protocol implementation remains planned. See GitHub [issue #1](https://github.com/browep/claude-agent-sdk-cl/issues/1) and [PLAN.md](PLAN.md).

## License

The upstream Python SDK is MIT-licensed. This port is an independent implementation; copied or adapted test material must retain source provenance and required notices.
