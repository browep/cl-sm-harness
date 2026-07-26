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
  client)
    # Persistent stream-json fixture: acknowledge initialize/interrupt controls
    # and produce a complete assistant/result turn for each user frame without
    # closing stdin between turns.
    turn=0
    while IFS= read -r line; do
      case "$line" in
        *'"type":"control_request"'*)
          request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
          printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s"}}\n' "$request_id"
          ;;
        *'"type":"user"'*)
          turn=$((turn + 1))
          printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"client turn %s"}]}}\n' "$turn"
          printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"turn %s done"}\n' "$turn"
          ;;
      esac
    done
    ;;
  client-eof)
    # Complete initialization then terminate cleanly without a user response.
    IFS= read -r line || exit 0
    request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s"}}\n' "$request_id"
    ;;
  client-nonzero)
    printf '%s\n' 'fake persistent client failed' >&2
    exit 23
    ;;
  client-large-stderr)
    # Fill stderr before answering initialize. The client must already be
    # draining stderr or the child will block and handshake will deadlock.
    IFS= read -r line || exit 0
    head -c 262144 /dev/zero | tr '\000' e >&2
    request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s"}}\n' "$request_id"
    IFS= read -r line || exit 0
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"stderr drained"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"done"}'
    ;;
  client-fragmented)
    # Deliberately split JSON records across writes while keeping the pipe open.
    # This exercises the transport's first-character/listen drain and the
    # client's JSONL framer independently of child EOF.
    IFS= read -r line || exit 0
    request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
    printf '{"type":"control_res'
    sleep 0.01
    printf 'ponse","response":{"subtype":"success","request_id":"%s"}}\n' "$request_id"
    IFS= read -r line || exit 0
    printf '{"type":"assistant","message":{"role":"assistant",'
    sleep 0.01
    printf '"content":[{"type":"text","text":"fragmented"}]}}\n'
    printf '{"type":"result","subtype":"success","is_error":false,'
    sleep 0.01
    printf '"num_turns":1,"session_id":"s","result":"fragmented done"}\n'
    ;;
  client-control)
    # Handshake, emit an inbound permission request, wait for its correlated
    # control response, then finish a normal assistant/result turn.
    IFS= read -r line || exit 0
    request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s"}}\n' "$request_id"
    printf '%s\n' '{"type":"control_request","request_id":"cli-request-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"pwd"}}}'
    IFS= read -r line || exit 0
    printf '%s' "$line" | grep -F '"request_id":"cli-request-1"' >/dev/null || exit 64
    printf '%s' "$line" | grep -F '"behavior":"allow"' >/dev/null || exit 64
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"permission accepted"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"control done"}'
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
  query-cancel-wait)
    # Emit one public system record then replace the shell with sleep.
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s","cwd":"/tmp"}'
    exec sleep 5
    ;;
  query-cancel-descendant)
    # Write the synthetic child PID before the public record: the callback may
    # cancel immediately when it receives that record.
    pid_file=${2:?descendant PID file is required}
    sh -c 'trap "" TERM; exec sleep 60' >/dev/null 2>&1 &
    descendant=$!
    printf '%s\n' "$descendant" >"$pid_file"
    # SBCL's stream read needs enough pipe progress while the child remains
    # open. The valid JSONL record is first; trailing spaces stay pending in
    # the framer but cause the callback to receive the system record now.
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s","cwd":"/tmp"}'
    head -c 8192 /dev/zero | tr '\000' ' '
    wait "$descendant"
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
    exec sleep 5
    ;;
  process-identity-wait)
    # The supervisor must exec this script as a session and process-group leader.
    identity_file=${2:?process identity file is required}
    printf '%s %s %s %s\n' "$$" \
      "$(ps -o ppid= -p "$$" | tr -d ' ')" \
      "$(ps -o pgid= -p "$$" | tr -d ' ')" \
      "$(ps -o sid= -p "$$" | tr -d ' ')" >"$identity_file"
    exec sleep 60
    ;;
  descendant-wait|client-descendant-wait)
    # Spawn a pipe-detached synthetic descendant and record only its PID. The
    # parent waits forever, so transport timeout/close must terminate both.
    pid_file=${2:?descendant PID file is required}
    mode=${3:-term}
    if [ "$1" = client-descendant-wait ]; then
      IFS= read -r line || exit 0
      request_id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
      printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s"}}\n' "$request_id"
    fi
    if [ "$mode" = ignore-term ]; then
      sh -c 'trap "" TERM; exec sleep 60' >/dev/null 2>&1 &
    else
      sleep 60 >/dev/null 2>&1 &
    fi
    descendant=$!
    printf '%s\n' "$descendant" >"$pid_file"
    wait "$descendant"
    ;;
  --output-format)
    # Default public query path: validate the upstream stream-json CLI shape and
    # its two JSONL stdin frames before emitting a deterministic transcript.
    [ "${2:-}" = "stream-json" ] || { printf '%s\n' 'missing stream-json output format' >&2; exit 64; }
    case " $* " in
      *" --verbose "*) ;;
      *) printf '%s\n' 'missing --verbose' >&2; exit 64 ;;
    esac
    case " $* " in
      *" --input-format stream-json "*) ;;
      *) printf '%s\n' 'missing stream-json input format' >&2; exit 64 ;;
    esac
    for expected in \
      '--system-prompt system text' \
      '--allowedTools Bash,Read' \
      '--disallowedTools Write' \
      '--model fake-model' \
      '--permission-mode acceptEdits' \
      '--continue' \
      '--resume=session-1'; do
      case " $* " in
        *" $expected "*|*" $expected --"*) ;;
        *) printf '%s\n' "missing supported option mapping: $expected" >&2; exit 64 ;;
      esac
    done
    input=$(cat)
    printf '%s' "$input" | grep -F '"type":"control_request"' >/dev/null || { printf '%s\n' 'missing initialize control frame' >&2; exit 64; }
    printf '%s' "$input" | grep -F '"subtype":"initialize"' >/dev/null || { printf '%s\n' 'missing initialize subtype' >&2; exit 64; }
    printf '%s' "$input" | grep -F '"type":"user"' >/dev/null || { printf '%s\n' 'missing user frame' >&2; exit 64; }
    printf '%s' "$input" | grep -F '"content":"default prompt"' >/dev/null || { printf '%s\n' 'missing user content' >&2; exit 64; }
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s","cwd":"/tmp"}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"fake response"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"done"}'
    ;;
  *)
    printf '%s\n' "unknown fake mode: $1" >&2
    exit 64
    ;;
esac
