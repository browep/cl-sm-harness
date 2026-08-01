#!/bin/sh
# Host-side E2E orchestration. The Playwright container itself receives no
# Docker socket and cannot reset/restart the application.
set -eu
compose_file=compose.sm-harness-web-ui.yaml
project="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
artifact_dir="${E2E_ARTIFACTS_DIR:-$HOME/evidence/sm-harness-web-ui-e2e/latest}"
scenario_dir=sm-harness-web-ui/e2e/tests
export E2E_ARTIFACTS_DIR="$artifact_dir"

# Caddy serves this host directory directly. Clear stale evidence before each
# disposable suite run, then let the browser container write new artifacts.
sudo -n install -d -m 0755 "$artifact_dir"
sudo -n find "$artifact_dir" -mindepth 1 -maxdepth 1 -type f -delete

if [ -n "${E2E_SCENARIO:-}" ]; then
  scenarios=$E2E_SCENARIO
else
  scenarios=$(find "$scenario_dir" -maxdepth 1 -type f -name '*.mjs' -printf '%f\n' |
              sed 's/\.mjs$//' | sort)
fi
[ -n "$scenarios" ] || { echo "no browser E2E scenarios found" >&2; exit 1; }

cleanup() {
  docker compose -f "$compose_file" down --remove-orphans >/dev/null 2>&1 || true
  docker volume rm -f "${project}_sm-harness-e2e-data" \
    "${project}_sm-harness-e2e-artifacts" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

# Build once; every scenario receives a new application and durable data root.
docker compose -f "$compose_file" down --remove-orphans
docker compose -f "$compose_file" build web-ui web-ui-e2e

for scenario in $scenarios; do
  # Fresh durable state prevents one scenario's sessions/transcript/fixture
  # state from changing another scenario's selectors or assertions. The app
  # remains alive throughout a single scenario, preserving reopen/replay flows.
  docker compose -f "$compose_file" down --remove-orphans
  docker volume rm -f "${project}_sm-harness-e2e-data" \
    "${project}_sm-harness-e2e-artifacts" 2>/dev/null || true
  E2E_SCENARIO="$scenario" docker compose -f "$compose_file" up -d web-ui-e2e-app

  # Probe only the app logs while waiting for its compiled CLOG app to listen.
  i=0
  until docker compose -f "$compose_file" logs --tail=20 web-ui-e2e-app 2>&1 | grep -q 'sm-harness-web-ui listening'; do
    i=$((i + 1))
    if [ "$i" -ge 300 ]; then
      docker compose -f "$compose_file" logs --tail=100 web-ui-e2e-app >&2
      exit 1
    fi
    sleep 2
  done

  E2E_SCENARIO="$scenario" docker compose -f "$compose_file" run --rm web-ui-e2e
done
