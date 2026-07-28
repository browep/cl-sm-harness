#!/bin/sh
# Offline regression test for the host-owned browser-E2E lifecycle.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
log="$tmp/docker.log"
mkdir -p "$tmp/bin" "$tmp/artifacts"

cat > "$tmp/bin/docker" <<'SH'
#!/bin/sh
printf 'scenario=%s docker %s\n' "${E2E_SCENARIO:-}" "$*" >> "$E2E_RUNNER_LOG"
case " $* " in
  *" logs "*) printf '%s\n' 'sm-harness-web-ui listening' ;;
esac
SH
cat > "$tmp/bin/sudo" <<'SH'
#!/bin/sh
if [ "${1:-}" = "-n" ]; then shift; fi
exec "$@"
SH
chmod +x "$tmp/bin/docker" "$tmp/bin/sudo"

(
  cd "$repo"
  PATH="$tmp/bin:$PATH" \
  E2E_SCENARIO='' \
  E2E_RUNNER_LOG="$log" \
  E2E_ARTIFACTS_DIR="$tmp/artifacts" \
  ./scripts/run-web-ui-e2e.sh
)

scenarios=$(find "$repo/sm-harness-web-ui/e2e/tests" -maxdepth 1 -type f -name '*.mjs' -printf '%f\n' | sed 's/\.mjs$//' | sort)
count=$(printf '%s\n' "$scenarios" | sed '/^$/d' | wc -l | tr -d ' ')
actual=$(grep -c 'docker compose -f compose.sm-harness-web-ui.yaml run --rm web-ui-e2e' "$log" || true)
[ "$actual" -eq "$count" ] || { echo "expected $count isolated E2E runs, got $actual" >&2; exit 1; }

printf '%s\n' "$scenarios" | while IFS= read -r scenario; do
  grep -F "scenario=$scenario docker compose -f compose.sm-harness-web-ui.yaml run --rm web-ui-e2e" "$log" >/dev/null || {
    echo "missing isolated E2E run for $scenario" >&2
    exit 1
  }
done

resets=$(grep -c 'volume rm -f .*sm-harness-e2e-data' "$log" || true)
[ "$resets" -ge "$count" ] || { echo "expected at least $count data-volume resets, got $resets" >&2; exit 1; }

echo "browser E2E runner isolates $count scenarios"
