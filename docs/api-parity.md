# API parity matrix

Baseline: [`anthropics/claude-agent-sdk-python@3145cc637778b23cb3caff7556ab76a10028b084`](upstream-baseline.md).

The machine-readable authority is [`test/fixtures/upstream/manifest.json`](../test/fixtures/upstream/manifest.json). It classifies all 35 upstream Python test files and 128 root public exports. The Docker-built catalog is compared against that manifest by `docker compose run --rm test parity`; missing, duplicate, or stale rows fail the command.

> **Capability vs. certification:** this page records manifest-certified parity
> against the pinned Python baseline, not the complete current Common Lisp API.
> For implemented harness-facing functionality, see the root README status and
> [harness integration guide](harness-integration.md). The certification matrix
> below is updated independently as source-provenance vectors are added.

## Current manifest-certified parity state

In this matrix, **deferred** means that the pinned upstream behavior has not
yet received the manifest/vector certification described above. It does not mean
that the corresponding Common Lisp capability is absent; consult the root README
and [harness integration guide](harness-integration.md) for the implemented
surface.

The target has a deterministic Phase 3 domain slice. `ClaudeAgentOptions`, `AssistantMessage`, `TextBlock`, `ProcessError`, and `CLIJSONDecodeError` have fixture-linked Common Lisp counterparts and are marked `ported` in the manifest. The remaining runtime contracts are explicitly deferred; upstream Python packaging/release checks and Python example-service tests are `not-applicable` with per-row rationale.

| Area | State | Planned slice |
|---|---|---|
| Options, messages, errors, parser, and public types | deferred | Phase 3 |
| JSONL protocol and subprocess transport | deferred | Phase 4 |
| One-shot `query` | deferred | Phase 5 |
| Interactive `ClaudeSDKClient` lifecycle | deferred | Phase 6 |
| MCP, callbacks, hooks, sessions, stores, mirroring | deferred | Phase 7 |
| Python wheel/sdist/changelog/CLI-maintenance tests | not-applicable | Target packaging checks when applicable |
| Python Redis/Postgres/S3 example-service tests | not-applicable | SessionStore contract, not copied examples |

## Status meanings

- **ported:** a Common Lisp public symbol, deterministic Lisp test, and at least one source-provenance vector exist.
- **deferred:** a behavior belongs to a planned target slice; a non-empty rationale identifies why it is not yet delivered.
- **not-applicable:** source-language packaging or example infrastructure has no direct target counterpart; the row explains the replacement boundary.

No live response can change a row to `ported` without deterministic lower-layer evidence.
