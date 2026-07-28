#!/bin/sh
# Host-side E2E orchestration. The Playwright container itself receives no
# Docker socket and cannot reset/restart the application.
set -eu
compose_file=compose.sm-harness-web-ui.yaml

docker compose -f "$compose_file" down -v --remove-orphans
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
