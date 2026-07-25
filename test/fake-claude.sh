#!/bin/sh
case "${1:-ok}" in
  ok)
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"fake response"}]}}'
    ;;
  fail)
    printf '%s\n' 'fake cli failed' >&2
    exit 23
    ;;
  large-output)
    head -c 131072 /dev/zero | tr '\\000' x
    head -c 131072 /dev/zero | tr '\\000' y >&2
    ;;
  interleaved-output)
    (head -c 131072 /dev/zero | tr '\\000' x) &
    (head -c 131072 /dev/zero | tr '\\000' y >&2) &
    wait
    ;;
  echo)
    printf '{"type":"echo","text":"%s"}\n' "$(cat)"
    ;;
  raw-stdin)
    cat
    ;;
  sleep)
    sleep 5
    ;;
  *)
    printf '%s\n' "unknown fake mode: $1" >&2
    exit 64
    ;;
esac
