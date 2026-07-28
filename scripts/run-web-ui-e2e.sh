#!/bin/sh
# Host-side E2E orchestration. The Playwright container itself receives no
# Docker socket and cannot reset/restart the application.
set -eu
compose_file=compose.sm-harness-web-ui.yaml
project="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
artifact_dir="${E2E_ARTIFACTS_DIR:-$HOME/evidence/sm-harness-web-ui-e2e/latest}"
export E2E_ARTIFACTS_DIR="$artifact_dir"

# Caddy serves this host directory directly. Clear stale evidence before each
# disposable run, then let the browser container write the new artifacts here.
sudo -n install -d -m 0755 "$artifact_dir"
sudo -n find "$artifact_dir" -mindepth 1 -maxdepth 1 -type f -delete

docker compose -f "$compose_file" down --remove-orphans
# Reset only disposable browser state/evidence. Keep the dependency FASL cache so
# focused scenarios do not pay a full CLOG/Quicklisp compile on every run.
docker volume rm -f "${project}_sm-harness-e2e-data" "${project}_sm-harness-e2e-artifacts" 2>/dev/null || true
docker compose -f "$compose_file" build web-ui web-ui-e2e
docker compose -f "$compose_file" up -d web-ui-e2e-app

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

docker compose -f "$compose_file" run --rm web-ui-e2e
