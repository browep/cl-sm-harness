# sm-harness-web-ui

CLOG browser UI over `sm-harness`.

## Run

```bash
docker compose -f compose.sm-harness-web-ui.yaml up --build web-ui
# http://127.0.0.1:8080
```

## Fixture E2E

```bash
sg docker -c './scripts/run-web-ui-e2e.sh'
```

The host-side script resets the disposable E2E volumes, builds the app/runner,
waits for the CLOG fixture service, and runs Playwright on an internal-only
network. The Playwright container has neither Docker access nor provider
credentials. `WEB_UI_E2E=1` injects a deterministic SDK transport.
