# Upstream baseline

## Immutable reference

- **Repository:** `https://github.com/anthropics/claude-agent-sdk-python`
- **Commit:** `3145cc637778b23cb3caff7556ab76a10028b084`
- **SDK version:** `0.2.127`
- **License:** MIT, Copyright (c) 2025 Anthropic, PBC
- **Bundled Claude Code CLI version:** `2.1.219`
- **Catalog:** 35 Python files under `tests/` (including `conftest.py`) and 128 root `claude_agent_sdk.__all__` exports.

## Reference-oracle boundary

The Python SDK is a test-only behavioral oracle. The Docker `reference` target contains its pinned source but receives no credentials, `harness/.env`, provider environment, or network at container runtime. The Common Lisp SDK must never import, invoke, or fall back to Python in production.

The Python SDK bundles a Claude Code executable where available and otherwise supports a configured/system path. This port currently pins the same CLI version in its test image as an intentional development choice, not as a claim of Python-wheel packaging parity. Phase 4 must document target binary discovery and override behavior against this baseline.

## Update policy

Updating this baseline requires a deliberate commit that changes the SHA, regenerates the image catalog, updates `test/fixtures/upstream/manifest.json`, reviews every added/removed test file and export, and reruns `docker compose run --rm test parity`. Source-derived vectors must retain their source test/symbol, generator command, SHA-256, and this commit.
