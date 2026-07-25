# CLI provisioning and discovery

The Common Lisp port does **not** claim packaging parity with upstream Python's wheel-bundled CLI. Its production contract is:

1. Use the caller-supplied `cli-path` when present.
2. Otherwise resolve `claude` from `PATH`.
3. Signal `cli-not-found-error` with remediation when neither is executable.

The Docker image's pinned global npm CLI is test/live harness provisioning only. It is not bundled into the Lisp ASDF system and callers may select any compatible executable with `cli-path`.
