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

# Opt-in live Claude Code smoke tests (credential-scoped service only)
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm live live
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm live live-client
CLAUDE_SDK_LIVE_TEST=1 docker compose run --rm live live-terminate
```

Phase 1 implements the offline `unit` command. Phase 2 adds `parity`: it compares the checked-in classification manifest with a catalog generated from the pinned upstream Python source in a separate credential-free Docker stage. It builds a pinned Node base image with SBCL, FiveAM, and Claude Code CLI `2.1.219`; exact resolved runtime versions are retained in `/usr/local/share/claude-agent-sdk-cl/runtime-versions.txt` in the image. The `test` service has network disabled, mounts source read-only, and uses a named `/cache` volume for compiled artifacts.

The `test` service intentionally mounts only its ASDF/source/test/script inputs. It cannot see the root `.env`, and the test wrapper fails closed if an `.env` mount is added. The `reference` service is also credential-free and network-isolated at runtime; it can export the pinned source catalog for later vector generation. The `live` service is separate: it is the only network-enabled service, mounts source/scripts but never `.env`, receives only `CLAUDE_CODE_OAUTH_TOKEN`, and refuses to run unless `CLAUDE_SDK_LIVE_TEST=1` is set.

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

Phases 1–4.1 and Phase 5 are implemented. Phase 6 supplies a persistent interactive `claude-sdk-client`: connect once, send multiple user turns, consume each response through its `result` boundary, optionally interrupt a turn, then disconnect. It defaults to a stream-json Claude Code subprocess when no injected transport is supplied. See `examples/interactive.lisp`.

```lisp
(let ((client (claude-agent-sdk-cl:make-claude-sdk-client)))
  (unwind-protect
       (progn
         (claude-agent-sdk-cl:connect client)
         (claude-agent-sdk-cl:send client "Hello")
         (claude-agent-sdk-cl:receive-response client))
    (claude-agent-sdk-cl:disconnect client)))
```

### Inbound control callbacks

Pass `:control-handlers` as an alist from upstream control subtype to a
synchronous function. A handler receives the decoded request object while the
client is consuming the current turn. Its reply is serialized with all normal
client writes; no background stdout reader is used.

```lisp
(make-claude-sdk-client
 :control-handlers
 (list (cons "can_use_tool"
             (lambda (request)
               (declare (ignore request))
               (make-permission-result-allow)))
       (cons "hook_callback"
             (lambda (request)
               (declare (ignore request))
               (make-hook-callback-result :data (make-hash-table))))
       (cons "mcp_message"
             (lambda (request)
               (declare (ignore request))
               (make-mcp-control-result :response (make-hash-table))))))
```

For named CLI registrations, use `register-hook-callback` (callback ID; function
receives input, tool-use ID, and context) or `register-sdk-mcp-handler` (server
name; function receives JSON-RPC message). Both registrations are validated and
frozen once `connect` succeeds.

Handlers may return a JSON hash table, `permission-result-allow`,
`permission-result-deny`, `hook-callback-result`, `mcp-control-result`, or
`:cancel`. Missing handlers, invalid results, cancellation, exceptions, and
duplicate inbound request IDs receive deterministic correlated error responses;
the enclosing public turn continues when the CLI does.

### Session store (Phase 7C)

Use `make-in-memory-session-store` as the deterministic reference backend with
`session-store-append`, `session-store-load`, `session-store-list-sessions`,
and `session-store-list-subkeys`. Entries are opaque JSON objects, append order
is preserved, and an entry UUID is idempotent per session key.
`session-store-mirror-message` accepts only typed public messages and isolates
store errors via transport logging; filesystem persistence is Phase 7D.

Filesystem persistence is Phase 7D via `make-filesystem-session-store :root`.
It stores JSONL only beneath the configured root and rejects traversal-unsafe
project/session/subpath components. Remote adapters are outside Phase 7 (#14).

### Session configuration (Phase 7B)

`make-agent-options` validates session configuration before default transport
provisioning can spawn Claude: a store-backed `:continue-conversation` needs
`:session-store-list-sessions-p t` unless `:resume` is explicit, and a
`:session-store` cannot be combined with `:enable-file-checkpointing t`.
`normalize-session-id` and `normalize-session-path` reject empty/control or
traversal-unsafe values. `make-session-import-plan` and
`make-session-mutation-plan` create validated, side-effect-free plans; actual
store persistence and transcript mirroring are Phase 7C.

Offline tests remain credential-free and network-isolated. The one-shot smoke is `test.sh live`; the separately gated interactive two-turn smoke is `test.sh live-client`. Both require `CLAUDE_SDK_LIVE_TEST=1` and run only in the credential-scoped `live` Compose service. The interactive smoke was verified on 2026-07-26 with two exact fixed replies and two terminal `success` results.

See GitHub [issue #1](https://github.com/browep/claude-agent-sdk-cl/issues/1) and [PLAN.md](PLAN.md).

## License

The upstream Python SDK is MIT-licensed. This port is an independent implementation; copied or adapted test material must retain source provenance and required notices.
