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
    head -c 2097152 /dev/zero | tr '\000' x
    head -c 2097152 /dev/zero | tr '\000' y >&2
    ;;
  interleaved-output)
    (head -c 2097152 /dev/zero | tr '\000' x) &
    (head -c 2097152 /dev/zero | tr '\000' y >&2) &
    wait
    ;;
  echo)
    printf '{"type":"echo","text":"%s"}\n' "$(cat)"
    ;;
  raw-stdin)
    cat
    ;;
  query)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s","cwd":"/tmp"}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"fake response"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"done"}'
    ;;
  query-control)
    printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"unknown"}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"fake response"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"done"}'
    ;;
  query-write-before-read)
    # Emit a valid init line, THEN a large no-newline payload before reading
    # stdin. The bulk sits in the framer's pending buffer (no newline => no
    # premature decode). If the transport writes stdin synchronously before
    # starting stdout reads, the child blocks writing stdout and the parent
    # blocks writing stdin => deadlock. Readers-before-stdin avoids it.
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s","cwd":"/tmp"}'
    head -c 262144 /dev/zero | tr '\000' ' '
    cat >/dev/null
    printf '\n%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"after stdin"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"done"}'
    ;;
  query-stdin-length)
    # Echo the exact stdin byte count back as the result string. Proves stdin is
    # delivered with no implicit trailing newline, without JSON-escaping stdin.
    bytes=$(cat | wc -c | tr -d ' ')
    printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"%s"}\n' "$bytes"
    ;;
  query-nonzero)
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"partial"}]}}'
    printf '%s\n' 'fake query failed' >&2
    exit 23
    ;;
  query-large-stderr)
    # Large stderr concurrent with stdout JSON: proves stderr is drained
    # concurrently (undrained stderr pipe would deadlock the child).
    head -c 262144 /dev/zero | tr '\000' e >&2
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"done"}'
    ;;
  query-malformed)
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"before garbage"}]}}'
    printf '%s\n' '{garbage'
    ;;
  write-before-read)
    head -c 262144 /dev/zero | tr '\000' o
    cat >/dev/null
    ;;
  sleep)
    sleep 5
    ;;
  *)
    printf '%s\n' "unknown fake mode: $1" >&2
    exit 64
    ;;
esac
