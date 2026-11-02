# Retro-K8s input agent

Browser → authenticated WebSocket → Python agent → uinput gamepad → RetroArch.
The agent and emulator share a container. See [the project README](../README.md)
for the integrated build, Linux host setup, browser UI, and Compose commands.

## Tests

From the repository root:

```bash
python3 -m venv .venv
.venv/bin/pip install -r input-agent/requirements.txt
.venv/bin/python -m unittest discover -s input-agent/tests -t input-agent -v
node --test input-agent/tests/test_browser.mjs
```

The Python tests do not need evdev; the Docker image installs it from Ubuntu.

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
`/usr/local/bin/retroarch-entrypoint`. It starts the agent first, waits for a
readable device, checks host udev metadata, and stops the sibling process when
either the agent or RetroArch exits.

For an existing compatible RetroArch base image, the standalone image is an
alternative to the root multi-stage build:

```bash
docker build -f input-agent/Dockerfile \
  --build-arg BASE_IMAGE=retro-k8s-poc/retroarch:latest \
  -t retro-k8s-poc/retroarch-input:latest input-agent
```

The base must include the updated root `entrypoint.sh` and RTMP configuration.
Compose uses the root multi-stage Dockerfile, so a separate base build is not
required for normal use.
