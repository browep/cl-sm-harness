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
    exec sbcl --non-interactive \
      --eval '(require :asdf)' \
      --eval '(asdf:test-system :claude-agent-sdk-cl/tests)'
    ;;
  *)
    printf '%s\n' "unknown test mode: $mode" >&2
    exit 64
    ;;
esac
