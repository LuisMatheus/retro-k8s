# Retro-K8s input agent

Browser → authenticated WebSocket → Python agent → uinput gamepad → RetroArch.
The agent and emulator share a container. See [the project README](../../README.md)
for the integrated build, Linux host setup and browser UI.

The operator deploys the agent inside each emulator container. The `frontend`
serves the webpage and development tokens and has no host input-device access.

## Tests

From the repository root:

```bash
python3 -m venv .venv
.venv/bin/pip install -r services/input-agent/requirements.txt
.venv/bin/python -m unittest discover -s services/input-agent/tests -t services/input-agent -v
PYTHONPATH=services/frontend:services/input-agent .venv/bin/python -m unittest discover -s services/frontend/tests -t services/frontend -v
node --test services/frontend/tests/*.mjs
```

The Python tests do not need evdev; the Docker image installs it from Ubuntu.

## Frontend session discovery

`services/frontend/server.py` serves the browser and mints tokens. `SESSION_SOURCE` selects
where sessions come from:

- `kubernetes` lists `retrosessions.retro.k8s` in the Pod namespace with the
  mounted service-account token. The browser uses same-origin routes:
  `/api/sessions/<name>/input` for the WebSocket and
  `/api/sessions/<name>/whep` for WebRTC signaling. The proxy resolves the
  upstream from `RetroSession.status.endpoints`, never from browser input.
- `static` uses `SESSIONS`, `SNES_INPUT_PORT`, `GBA_INPUT_PORT`,
  `INPUT_PORTS="name:port,..."` and `MEDIA_PORT`, and the browser connects
  directly to those ports. This is the static deployment path.
- `auto` (default) chooses Kubernetes when service-account credentials exist,
  otherwise static.

In Kubernetes, `services/frontend/k8s/frontend-rbac.yaml` grants the `frontend` service
account `get`/`list` on `retrosessions`. `MEDIA_HOST` (default `mediamtx`) and
`MEDIA_WHEP_PORT` (default `8889`) select the in-cluster MediaMTX WHEP endpoint.
`/api/config` reports `mode: proxy` with only public phase/readiness details;
`/api/token` refuses unknown sessions and sessions that are not `Ready`.

## Protocol

Messages use version 1 and logical names, never Linux event codes:

```json
{"version":1,"type":"button","button":"south","pressed":true}
{"version":1,"type":"axis","axis":"left_x","value":-0.75}
{"version":1,"type":"release_all"}
{"version":1,"type":"heartbeat"}
```

Buttons: `south`, `east`, `west`, `north`, `l`, `r`, `start`, `select`, `up`,
`down`, `left`, `right`. Axes: `left_x`, `left_y`, `right_x`, `right_y`.
Analog values are clamped to [-1, 1]. D-pad buttons become hat axes.

One authenticated controller is allowed per session. The server releases all
inputs on disconnect and after a message timeout. The default minimum button
hold is 40 ms. A reconnect starts neutral. Token expiration is checked when the
connection opens; it does not terminate an already established connection.

## Agent environment

Required: `SESSION_ID`, `INPUT_TOKEN_SECRET`.

Optional: `AGENT_HOST` (0.0.0.0), `AGENT_PORT` (8765), `HEARTBEAT_TIMEOUT` (5),
`MAX_MESSAGE_BYTES` (512), `MAX_EVENTS_PER_SEC` (200), `RATE_BURST` (400),
`MIN_HOLD_MS` (40), `LOG_LEVEL` (INFO), `ALLOWED_ORIGINS` (comma-separated),
`DEVICE_NAME`, `DEVICE_VENDOR`, `DEVICE_PRODUCT`.

The wrapper also uses `ORIGINAL_ENTRYPOINT`, set by the image to
`/usr/local/bin/start-retroarch.sh`. It starts the agent first, waits for a
readable device, checks host udev metadata, and stops the sibling process when
either the agent or RetroArch exits.

For an existing compatible RetroArch base image, the standalone image is an
alternative to the shared RetroArch runtime build:

```bash
docker build -f services/input-agent/Dockerfile \
  --build-arg BASE_IMAGE=retro-k8s-poc/retroarch:latest \
  -t retro-k8s-poc/retroarch-input:latest .
```

The base must include `services/retroarch/start-retroarch.sh` and its RTMP configuration.
The runtime's multi-stage Dockerfile builds the same image without a separate
base build.

## Diagnostic replies

A client can add an optional nonnegative safe-integer `seq` to a version-1
message. The agent echoes it in a version-1 `ack`, with `status` (`accepted`,
`invalid`, or `rate_limited`), `processing_ms`, connection counters, and the
current controller `state` (`buttons`, `axes`, `pending_releases`). Messages
without `seq` keep their original behavior. Invalid messages also retain the
existing error response; invalid sequence identifiers are not echoed.

The browser uses its own monotonic clock to time replies. No clock synchronization
is assumed. Replies indicate agent acceptance/controller state, not RetroArch
poll completion. See the root README's live diagnostics section for metric
scope and frame-loss/latency limitations.
