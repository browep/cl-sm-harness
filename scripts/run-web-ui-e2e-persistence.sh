#!/bin/sh
# Host-only retained-volume restart proof. Browser E2E never receives Docker access.
set -eu
compose_file=compose.sm-harness-web-ui.yaml

wait_for_app() {
  i=0
  until docker compose -f "$compose_file" logs --tail=20 web-ui-e2e-app 2>&1 | grep -q 'sm-harness-web-ui listening'; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
      docker compose -f "$compose_file" logs --tail=100 web-ui-e2e-app >&2
      exit 1
    fi
    sleep 2
  done
}

docker compose -f "$compose_file" down -v --remove-orphans
docker compose -f "$compose_file" build web-ui web-ui-e2e
docker compose -f "$compose_file" up -d web-ui-e2e-app
wait_for_app
# Produce a durable completed session through the real browser/UI/fixture stack.
E2E_SCENARIO=new-chat-composer docker compose -f "$compose_file" run --rm web-ui-e2e
# Restart only the application container; preserve the named data volume.
docker compose -f "$compose_file" stop web-ui-e2e-app
docker compose -f "$compose_file" up -d web-ui-e2e-app
wait_for_app
# Reopen persisted history and verify its canonical transcript after restart.
E2E_SCENARIO=turn-identity docker compose -f "$compose_file" run --rm web-ui-e2e
