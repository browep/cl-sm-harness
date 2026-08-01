#!/bin/sh
# Host-only retained-volume restart proof. Browser E2E never receives Docker access.
set -eu
# Self-locate the harness root so invocation cwd does not matter.
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
compose_file=compose.sm-harness-web-ui.yaml
artifact_dir="${E2E_ARTIFACTS_DIR:-$HOME/evidence/sm-harness-web-ui-e2e/latest}"
export E2E_ARTIFACTS_DIR="$artifact_dir"

# Keep retained-volume test artifacts directly in Caddy's served evidence tree.
sudo -n install -d -m 0755 "$artifact_dir"
sudo -n find "$artifact_dir" -mindepth 1 -maxdepth 1 -type f -delete

wait_for_app() {
  i=0
  until docker compose -f "$compose_file" logs --tail=20 web-ui-e2e-app 2>&1 | grep -q 'sm-harness-web-ui listening'; do
    i=$((i + 1))
    if [ "$i" -ge 300 ]; then
      docker compose -f "$compose_file" logs --tail=100 web-ui-e2e-app >&2
      exit 1
    fi
    sleep 2
  done
}

docker compose -f "$compose_file" down -v --remove-orphans
docker compose -f "$compose_file" build web-ui web-ui-e2e
# The scenario env must be set at `up` time and match the later `run`:
# compose recreates a dependency container whose config drifted, so a
# mismatched E2E_SCENARIO would silently restart the app mid-phase and the
# runner would race its boot (connect ECONNREFUSED). `run --no-deps` keeps
# the app lifecycle entirely in this script's hands.
E2E_SCENARIO=new-chat-composer docker compose -f "$compose_file" up -d web-ui-e2e-app
wait_for_app
# Produce a durable completed session through the real browser/UI/fixture stack.
E2E_SCENARIO=new-chat-composer docker compose -f "$compose_file" run --rm --no-deps web-ui-e2e
# Replace only the application container; preserve the named data volume
# (the recreate is forced by the scenario-env change, and durable state
# surviving container replacement is exactly what this script proves).
docker compose -f "$compose_file" stop web-ui-e2e-app
E2E_SCENARIO=turn-identity docker compose -f "$compose_file" up -d web-ui-e2e-app
wait_for_app
# Reopen persisted history and verify its canonical transcript after restart.
E2E_SCENARIO=turn-identity docker compose -f "$compose_file" run --rm --no-deps web-ui-e2e
