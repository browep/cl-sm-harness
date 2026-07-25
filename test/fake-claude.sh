#!/bin/sh
case "${1:-ok}" in
  ok)
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"fake response"}]}}'
    ;;
  fail)
    printf '%s\n' 'fake cli failed' >&2
    exit 23
    ;;
  *)
    printf '%s\n' "unknown fake mode: $1" >&2
    exit 64
    ;;
esac
