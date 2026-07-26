# Harness integration examples

Every `.lisp` file is **load-safe**: loading it defines a package/functions but
never starts Claude or reads credentials. Each file is independently packaged,
so load the individual sample you need.

```sh
export CL_SOURCE_REGISTRY="$PWD//:${CL_SOURCE_REGISTRY:-}"
sbcl --non-interactive \
  --eval '(require :asdf)' \
  --load examples/harness/01-install-and-verify.lisp
```

| File | Scope | Live CLI needed to invoke? |
|---|---|---|
| `01-install-and-verify.lisp` | Load the SDK and report its version | No |
| `02-one-shot.lisp` | One-shot `query`, callback streaming, cancellation policy | Yes for `run-one-shot` |
| `03-interactive-client.lisp` | One persistent client, multiple turns, cleanup | Yes for `run-interactive-turns` |
| `04-message-mapping.lisp` | Map public typed records to a harness event schema | No |
| `05-control-handlers.lisp` | Permission, hook, and SDK-MCP inbound control handlers | Yes when CLI emits control traffic |
| `06-session-store.lisp` | Local in-memory/filesystem store primitives | No |
| `07-fake-query-transport.lisp` | Deterministic, no-CLI `query` fixture transport | No |
| `08-thin-adapter.lisp` | Small one-turn harness boundary using a persistent client | Yes for `run-harness-turn` |
| `09-fake-client-transport.lisp` | Deterministic, no-CLI persistent-client fixture transport | No |

For the conceptual API reference, operational constraints, and error mapping,
see [`docs/harness-integration.md`](../../docs/harness-integration.md).

Run the repository's canonical offline checks from its root:

```sh
docker compose run --rm test unit
docker compose run --rm test integration
docker compose run --rm test examples
docker compose run --rm test parity
```

The offline Compose `test` service mounts this directory read-only and runs the
examples through `scripts/check-harness-examples.sh`. No example runs a
credentialed CLI request merely from loading.
