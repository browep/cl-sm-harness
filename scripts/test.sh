#!/bin/sh
set -eu

mode="${1:-unit}"
shift || true

export CL_SOURCE_REGISTRY="/workspace//:/usr/share/common-lisp/source//"

if [ -e /workspace/.env ]; then
  printf '%s\n' 'refusing to run offline tests with /workspace/.env mounted' >&2
  exit 1
fi

case "$mode" in
  unit)
    case "${1:-}" in
      "")
        exec sbcl --non-interactive \
          --eval '(require :asdf)' \
          --eval '(asdf:test-system :claude-agent-sdk-cl/tests)'
        ;;
      --suite)
        suite="${2:-}"
        case "$suite" in
          conditions|options|types|protocol|query|client)
            exec sbcl --non-interactive \
              --eval '(require :asdf)' \
              --eval '(asdf:load-system :claude-agent-sdk-cl/tests)' \
              --eval "(unless (fiveam:run! :claude-agent-sdk-cl/$suite) (uiop:quit 1))"
            ;;
          *)
            printf '%s\n' "unknown test suite: $suite" >&2
            exit 64
            ;;
        esac
        ;;
      *)
        printf '%s\n' "usage: unit [--suite conditions|options|types|protocol|query|client]" >&2
        exit 64
        ;;
    esac
    ;;
  integration)
    exec sbcl --non-interactive \
      --eval '(require :asdf)' \
      --eval '(asdf:load-system :claude-agent-sdk-cl/tests)' \
      --eval '(unless (fiveam:run! :claude-agent-sdk-cl/subprocess) (uiop:quit 1))'
    ;;
  parity)
    node /workspace/scripts/verify-parity.mjs \
      /opt/upstream-catalog.json \
      /workspace/test/fixtures/upstream/manifest.json
    ;;
  live|live-client)
    # Never run a provider-backed command by accident. The separate Compose
    # `live` service is the only service that receives this one credential.
    if [ "${CLAUDE_SDK_LIVE_TEST:-}" != "1" ]; then
      printf '%s\n' 'refusing live smoke: set CLAUDE_SDK_LIVE_TEST=1 explicitly' >&2
      exit 64
    fi
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      printf '%s\n' 'refusing live smoke: CLAUDE_CODE_OAUTH_TOKEN is required' >&2
      exit 64
    fi
    case "$mode" in
      live) exec sbcl --non-interactive --load /workspace/scripts/live-smoke.lisp ;;
      live-client) exec sbcl --non-interactive --load /workspace/scripts/live-client-smoke.lisp ;;
    esac
    # The exec above never returns; reaching here is an internal routing error.
    exit 1
    ;;
  *)
    printf '%s\n' "unknown test mode: $mode" >&2
    exit 64
    ;;
esac
