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
          conditions|options|types|protocol)
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
        printf '%s\n' "usage: unit [--suite conditions|options|types|protocol]" >&2
        exit 64
        ;;
    esac
    ;;
  parity)
    node /workspace/scripts/verify-parity.mjs \
      /opt/upstream-catalog.json \
      /workspace/test/fixtures/upstream/manifest.json
    ;;
  *)
    printf '%s\n' "unknown test mode: $mode" >&2
    exit 64
    ;;
esac
