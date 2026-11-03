# retro-k8s-poc

Headless RetroArch sessions with browser video and controller input. Docker
Compose is the development setup; a `RetroSession` operator runs SNES sessions
on Minikube and the frontend discovers them through the Kubernetes API.

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
- `input-agent/frontend.py`: RetroSession discovery and same-origin input/WHEP proxy.
- `retroarch/rtmp.cfg`: H.264/AAC RTMP encoder settings.
- `mediamtx/mediamtx.yml`: RTMP ingest and WebRTC playback.
- `k8s/input-probe/`: disposable Minikube virtual-controller probe.
- `k8s/snes/`: static Kustomize single-SNES pilot with a read-only ROM and save PVC.
- `operator/`: `RetroSession` CRD, Go controller, manifests and verification scripts.

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
address in `webrtcAdditionalHosts`. Outside Kubernetes the development UI
connects directly to local HTTP media on port 8889 and local WebSocket input
ports; in Kubernetes it uses same-origin proxy routes. Neither mode is a
production gateway.

## Stop

```bash
docker compose down
```

Compose also stops the frontend. For frontend/token logs, run
`docker compose logs -f frontend`.

## Kubernetes roadmap

### Current state

During the November 2, 2026 check, Docker Compose was running the frontend,
MediaMTX and a SNES session. Logs showed that RetroArch selected the session's
virtual gamepad for player 1 and that browsers received H.264 video. Keyboard
and gamepad input, session tokens, disconnect cleanup and browser diagnostics
are implemented. All 20 Python tests and both Node test suites passed. GBA is
configured but was offline during the check.

Browser audio now carries Opus through the relay, but audible playback through
the host speakers has not been confirmed. Saves persist in per-console host
directories.

The static Kustomize SNES pilot was also deployed to Minikube and passed its
step 2 checks: the game started from a read-only ROM host mount, RetroArch
selected the pilot pad for player 1, writes to the ROM mount failed, and a save
marker survived Pod replacement.

On November 3, 2026, the `RetroSession` operator was deployed to Minikube and
passed its SNES checks: a `RetroSession` created one emulator Deployment and one
input Service, reported `Ready` with frontend endpoints, repaired a deleted
Deployment, garbage-collected the session resources, and retained and reused the
save PVC across `RetroSession` deletion and recreation. The frontend now lists
`RetroSession` resources with its service account and proxies input WebSocket
and WHEP signaling through same-origin routes, so the browser only needs the
frontend port-forward. GBA validation, per-session audio relay, and per-player
isolation are still to be built.

On November 3, 2026, the operator-aware frontend was verified in Minikube:
`/api/config` listed `chrono-trigger` with `mode: proxy`, `/api/token` minted a
session token, and the proxy carried a WebSocket heartbeat to the input agent
and a WHEP request to MediaMTX. The browser UI renders discovered sessions and
follows readiness changes.

### Roadmap

1. **Prove virtual controller access in Minikube.** Run a disposable probe Pod
   using the existing session image and the emulator's UID, GID and supplementary
   input group. Check `/dev/uinput`, `/dev/input` and udev metadata inside the
   Docker-backed node and again inside the Pod. The probe passes when it creates
   a uniquely named pad, reads a button press and release from that pad's new
   event device, and confirms the device disappears on close. Record any
   privileged access required for this trusted local pilot. **Verified on
   Minikube on November 2, 2026:** the regular Pod could not open `/dev/uinput`;
   the privileged Pod passed as the non-root session user with the live input
   paths attached. Follow the [input probe instructions](k8s/input-probe/README.md)
   to reproduce both results.

2. **Deploy one SNES session with static manifests.** Use Kustomize to deploy
   the frontend, MediaMTX and the combined RetroArch/input container. Load tagged
   images into Minikube, mount one user-supplied ROM read-only, and give the
   emulator a separate writable save PVC. Use a single-replica `Recreate`
   Deployment, a Kubernetes Secret for token signing, and a unique pad name so
   the pilot can run alongside Compose. This step passes when the game starts,
   RetroArch selects the correct pad, and the save volume survives Pod replacement.
   **Verified on Minikube on November 2, 2026:** `k8s/snes/deploy.sh` started
   the game from a read-only ROM mount, logs reported
   `Retro-K8s Pad snes-k8s configured in port 1`, and `k8s/snes/verify.sh`
   confirmed the ROM mount rejects writes and a `/saves` marker survived Pod
   replacement. Follow the [pilot instructions](k8s/snes/README.md).

3. **Make the session playable from the local browser.** Make the frontend's
   session list and endpoints configurable. Use separate loopback TCP ports for
   the pilot UI, input and WebRTC signaling. Advertise the Minikube node IP and
   set the UDP NodePort to match MediaMTX's ICE listening port. For audio, relay
   the raw SNES stream through FFmpeg, copy H.264, convert AAC to Opus and
   publish to a separate playback path. This step passes when unmuting produces
   game sound, keyboard and gamepad presses visibly change the game,
   disconnecting releases held input, and an in-game save reloads after Pod
   replacement. In-game save and reload were confirmed on November 2, 2026.
   [MediaMTX playback codecs](https://mediamtx.org/docs/read/webrtc)
   · [WebRTC connectivity](https://mediamtx.org/docs/features/webrtc-specific-features)

4. **Build the `RetroSession` operator from the verified deployment.** Introduce
   a namespaced resource that selects a console, a ROM within its library and an
   existing save claim. The Go controller creates one emulator Deployment and
   input Service per session, supplies endpoint information for the frontend,
   and reports readiness or a concrete failure reason. Verify that reconciliation
   repairs deleted resources, avoids duplicate emulators and preserves saves when
   a session is deleted and recreated. Validate GBA as the second core. Before
   opening access to multiple players, add authenticated session routing,
   per-player save ownership and tested isolation between virtual controllers.
   **Verified for SNES on Minikube on November 3, 2026:**
   `operator/deploy.sh` deployed the controller and `operator/verify.sh`
   confirmed creation, `Ready` status and endpoints, Deployment repair,
   garbage-collection of the Deployment/Service, and save-PVC retention and
   reuse across `RetroSession` deletion and recreation. **Frontend integration
   was verified on Minikube on November 3, 2026:** the frontend service account
   listed the `chrono-trigger` session, `/api/config` returned `mode: proxy`, and
   the proxy forwarded both a WebSocket heartbeat to the input agent and a WHEP
   offer to MediaMTX. GBA validation remains pending. Follow the
   [operator instructions](operator/README.md).
