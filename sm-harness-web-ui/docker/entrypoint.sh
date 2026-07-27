#!/bin/sh
set -eu
mkdir -p /data /cache
# entrypoint runs as app user already in image
mode="${1:-web}"
export CL_SOURCE_REGISTRY="/app//:/usr/share/common-lisp/source//"
case "$mode" in
  web)
    exec sbcl --non-interactive \
      --eval '(require :asdf)' \
      --eval '(asdf:load-system :sm-harness-web-ui)' \
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
