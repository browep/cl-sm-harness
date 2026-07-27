# sm-harness-web-ui

CLOG browser UI over `sm-harness`.

## Run

```bash
docker compose -f compose.sm-harness-web-ui.yaml up --build web-ui
# http://127.0.0.1:8080
```

## Fixture E2E

```bash
docker compose -f compose.sm-harness-web-ui.yaml run --rm web-ui-e2e
```

`WEB_UI_E2E=1` injects a deterministic SDK transport (no Claude/provider credentials).
