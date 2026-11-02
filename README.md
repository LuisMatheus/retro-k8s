# retro-k8s-poc

Headless RetroArch sessions with browser video and controller input. This is a
Docker Compose proof of concept; a Kubernetes operator is not implemented yet.

```text
RetroArch SNES/GBA ── RTMP ── MediaMTX ── WebRTC ── browser
        ↑                                           │
   virtual gamepad ← uinput ← Python agent ← WebSocket
```

Each session runs its input agent and RetroArch in the same container. The
browser combines keyboard and standard physical gamepad input into a versioned
logical controller protocol. The agent authenticates the connection, validates
messages, and creates a Linux virtual gamepad that RetroArch reads through its udev joypad driver. Keyboard/mouse input uses
the private Xvfb display (`input_driver = "x"`) so host typing cannot bypass the
browser and trigger RetroArch pause/reset/menu hotkeys.

## Layout

- `Dockerfile`: builds RetroArch v1.22.2 and Snes9x/mGBA cores, then adds the agent.
- `compose.yaml`: browser/token server, MediaMTX, and two emulator sessions.
- `entrypoint.sh`: generates RetroArch config/autoconfiguration and starts Xvfb.
- `input-agent/agent/`: authentication, protocol, state, WebSocket server, uinput.
- `input-agent/input-wrapper.sh`: starts the agent before RetroArch and supervises both.
- `input-agent/browser/`: WebRTC player and keyboard/gamepad client.
- `input-agent/dev-server.py`: localhost development UI and short-lived token endpoint.
- `retroarch/rtmp.cfg`: H.264/AAC RTMP encoder settings.
- `mediamtx/mediamtx.yml`: RTMP ingest and WebRTC playback.

## Linux host setup

The host needs uinput, an active udev daemon, `/dev/input`, and `/run/udev`.
AMD64/ARM64 image support does not guarantee these devices exist, particularly
inside Docker Desktop's Linux VM.

```bash
sudo modprobe uinput
ls -l /dev/uinput /dev/input
getent group input
```

The session runs as `PUID:PGID` with the additional `INPUT_GID` group. Ensure the
host input group can read/write `/dev/uinput` and read `/dev/input/event*`.
Device permission changes must also persist through the host's udev rules.

## Configure

Place ROMs outside the project:

```text
~/Documents/games/snes/<game>.sfc
~/Documents/games/gba/<game>.gba
```

Copy `.env.example` to `.env` and set the ROM filenames, your host UID/GID,
`INPUT_GID` from `getent group input`, and `INPUT_TOKEN_SECRET`. Generate a
secret with `openssl rand -hex 32`. Quote ROM filenames that contain spaces.
Only the ROM for a session you start needs to be set.

```bash
cp .env.example .env
id -u
id -g
openssl rand -hex 32
```

`ALLOWED_ORIGINS` defaults in the example to the development UI on localhost:8000.
The private `.env`, ROMs, and existing game saves are not tracked in Git.

## Build and run

```bash
# Create bind-mount directories as your user before Docker starts.
mkdir -p saves/snes/states saves/gba/states
docker compose build
# Start one session first:
docker compose up frontend mediamtx retroarch-snes
```

For GBA use `retroarch-gba`, or start both with `docker compose up` after checking
the device-sharing limitation below. The build supports Linux AMD64 and ARM64.
To build only the original emulator image, use:

```bash
docker build --target retroarch-base -t retro-k8s-poc/retroarch:latest .
```

Compose starts the browser UI and development token endpoint automatically.
If you previously ran `python3 input-agent/dev-server.py`, stop that process
with Ctrl+C first so the frontend container can bind localhost:8000.

Open [the controller UI](http://localhost:8000). Select SNES or GBA, click Unmute
for audio, and keep the page focused while playing. The frontend container receives the same token secret as the session agent
through Compose; no Python process is needed on your host.

The agent endpoints bind to localhost:8765 (SNES) and localhost:8766 (GBA).
The UI obtains a short-lived session token automatically. Media-only readers
remain available at [SNES](http://localhost:8889/snes) and
[GBA](http://localhost:8889/gba).

| Keyboard | Control |
| --- | --- |
| Arrow keys | D-pad |
| X / Z | South (RetroPad B) / East (RetroPad A) |
| S / A | West (RetroPad Y) / North (RetroPad X) |
| Enter / Right Shift | Start / Select |
| Q / W | L / R |

Standard browser gamepads support D-pad, face/shoulder buttons, and both sticks.
Nonstandard devices and devices named Retro-K8s are ignored to prevent incorrect
mappings and virtual-controller feedback. The UI reports the selected/ignored
device. Unplugging, focus loss, disconnect, and heartbeat timeout release input.

## Rendering, audio, and saves

Xvfb provides an offscreen X server with Mesa software GL; no desktop is needed.
SDL2's dummy audio backend and `audio_sync = true` pace the emulator while FFmpeg
records core audio independently. RTMP uses H.264/AAC with ultrafast/zerolatency
settings. Set `SHOW_FPS=true` to inspect the on-stream frame counter.

Battery saves persist in `./saves/snes` and `./saves/gba`; save states use their
`states/` subdirectories. These survive `docker compose down`.

## Diagnostics and tests

```bash
docker compose logs -f retroarch-snes
# Accepted controller events:
# Set LOG_LEVEL=DEBUG in .env, then recreate the session.
docker compose logs retroarch-snes | rg 'rx |Autoconf|joypad|audio'
```

Expect the session's named Retro-K8s pad to be configured in port 1 and the
synchronous audio driver to start. `MIN_HOLD_MS` defaults to 40 to preserve short
button taps across RetroArch polling frames; adjust it for your latency needs.

```bash
python3 -m venv .venv
.venv/bin/pip install -r input-agent/requirements.txt
.venv/bin/python -m unittest discover -s input-agent/tests -t input-agent -v
node --test input-agent/tests/*.mjs
```

Python tests cover protocol/state/auth and real loopback WebSocket connections
without evdev or uinput. Browser tests cover feedback filtering, unplug cleanup,
focus loss, and stopped connection attempts. Full gameplay needs the Linux
container and browser; unit tests do not establish end-to-end latency or mapping.

## Live diagnostics

The browser UI includes a **Session diagnostics** panel, enabled by default.
Rebuild/recreate the emulator container after updating the agent, then reload the
page (a hard refresh may be needed for cached JavaScript):

```bash
docker compose up --build frontend mediamtx retroarch-snes
```

The panel shows:

- Agent-received input events with sequence numbers and accepted/invalid/rate-limited results.
- The agent's held buttons, normalized Linux axis values, and minimum-hold pending releases.
- Browser-to-agent round-trip time, p95 across the last 120 replies, and agent handling time.
- Sent/replied/pending/unacknowledged counts, plus server acceptance and rejection counts.
- Receiver FPS, video bitrate/resolution, received/decoded/dropped frames, video packet loss,
  jitter, jitter buffer delay, frame decode time, freezes, and selected WebRTC connection RTT.

**Export JSON** downloads a local snapshot, including up to 50 acknowledged input
events. Tokens and connection URLs are not included. Uncheck **Collect diagnostics**
to stop diagnostic acknowledgments and WebRTC polling while keeping gameplay input.

Input RTT includes both network directions and scheduling; it is not one-way
latency or input-to-screen latency. Agent acceptance means the event reached the
controller state, not that RetroArch consumed it. Minimum-hold releases may still
be pending when an acknowledgment is generated. State is refreshed on replies,
including idle heartbeats every two seconds. Counts reset when input reconnects.
Unacknowledged messages are not proof of lost inputs: a delayed reply, older
agent, or disconnect can also explain them. Background tabs affect timers/RTT.

WebRTC metrics use the [W3C statistics API](https://www.w3.org/TR/webrtc-stats/).
Interval metrics are sampled once per second; the first sample establishes a
baseline. Unsupported fields show `—`, rather than a misleading zero. Dropped
receiver frames, player rendering drops, and lost RTP packets measure different
things. These statistics cannot count frames lost inside RetroArch, its encoder,
or the RTMP path before MediaMTX. True button-to-screen latency needs dedicated
instrumentation or an external capture measurement.

## Device sharing and deployment limits

The POC mounts the host's entire `/dev/input` and `/run/udev`, and permits input
device major 13 so newly created event nodes are accessible. RetroArch reserves
player 1 for the session's named controller. This is controller selection, not
kernel device isolation: sessions can still see other host input devices.
Do not treat this setup as isolated multi-tenant Kubernetes workloads.

The development token endpoint has no user authentication and must stay local.
For remote deployment, add authenticated token issuance, HTTPS/WSS, explicit
origins, and session routing. Tokens currently travel in the WebSocket query
string, so avoid recording full URLs in proxy logs. Kubernetes device allocation
and per-session isolation still need their own implementation.

For LAN video, MediaMTX currently advertises `127.0.0.1`; configure the host LAN
address in `webrtcAdditionalHosts`. The development UI assumes local HTTP media
on port 8889 and local WebSocket input ports; it is not a production gateway.

## Stop

```bash
docker compose down
```

Compose also stops the frontend. For frontend/token logs, run
`docker compose logs -f frontend`.
