#!/bin/sh
set -eu
mkdir -p /data /cache
# entrypoint runs as app user already in image
mode="${1:-web}"
export CL_SOURCE_REGISTRY="/app//:/usr/share/common-lisp/source//"
case "$mode" in
  web)
    system=':sm-harness-web-ui'
    if [ "${WEB_UI_E2E:-}" = "1" ]; then
      system=':sm-harness-web-ui/e2e'
    fi
    exec sbcl --non-interactive \
      --eval '(require :asdf)' \
      --eval "(asdf:load-system $system)" \
      --eval '(sm-harness-web-ui:main)'
    ;;
  health)
    # Lightweight non-Claude health: process is up if we got here under a healthcheck wrapper.
    printf 'ok\n'
    ;;
  *)
    printf 'unknown mode: %s\n' "$mode" >&2
    exit 64
    ;;
esac
