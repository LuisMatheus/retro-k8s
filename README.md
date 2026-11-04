# Retro-K8s

Retro-K8s runs headless RetroArch game sessions on Kubernetes and streams them
to a browser. A `RetroSession` custom resource selects a console, ROM and save
claim; the operator creates the emulator workload and its input Service. The
frontend discovers sessions and connects the browser to the selected game.

The current target is a **trusted, single-node Linux Minikube pilot**. SNES
(Snes9x) and GBA (mGBA) cores are included.

## How it works

```text
RetroSession → operator → session Pod
                          ├─ RetroArch + input agent
                          ├─ local MediaMTX  →  FFmpeg audio relay
                          └───────────────────────────────┐
                                                          ↓
browser ← WebRTC ← shared MediaMTX ←──────────────────────┘
   └─ keyboard / gamepad → frontend proxy → input Service
                                              └→ virtual gamepad → RetroArch
```

Each session mounts a ROM library read-only and a separate writable save PVC.
The input agent translates browser events into a Linux virtual gamepad.
RetroArch publishes to MediaMTX inside the session Pod; the relay copies H.264
video, converts AAC audio to Opus and publishes to shared MediaMTX for browser
playback. The relay can reconnect when the shared media server restarts without
restarting the emulator. Session readiness reports the emulator, input agent and
media path separately; a media outage marks the session not ready without
restarting the running game.

## Project layout

```text
operator/                    RetroSession API, controller and tests
frontend/                    Browser UI, discovery and proxy server
input-agent/                 WebSocket input and virtual gamepad
runtimes/retroarch/          RetroArch image, cores and startup scripts
deploy/
  kubernetes/
    operator/                Operator CRD, RBAC and Deployment
    platform/                Shared frontend and MediaMTX manifests
    samples/                 SNES and GBA session and save claim examples
    local/                   Minikube helpers and virtual-controller probe
  legacy/static-snes/        Original static SNES pilot
```

See the [operator README](operator/README.md) for the API, reconciliation,
configuration and verification details, and the [frontend README](frontend/README.md)
for the browser components.

The session image starts `runtimes/retroarch/start-session.sh`, which starts the
input agent and then `start-retroarch.sh`. For local cluster setup, run
`deploy/kubernetes/local/deploy-operator.sh` and `deploy-platform.sh`; use
`port-forward-frontend.sh` to connect a browser.

## Run on Minikube

These instructions use a Linux host with Docker, Minikube, `kubectl` and
OpenSSL. The Minikube profile must use the Docker driver. The session image
requires `/dev/uinput`, `/dev/input` and live udev metadata; it runs privileged
for this pilot. Ensure you have permission to use the ROMs you provide.

### 1. Prepare the host and configuration

```bash
sudo modprobe uinput
ls -l /dev/uinput /dev/input
getent group input
cp .env.example .env
id -u
id -g
openssl rand -hex 32
```

Set `PUID`, `PGID`, `INPUT_GID` and `INPUT_TOKEN_SECRET` in `.env`. Use the
numeric group with access to `/dev/uinput` for `INPUT_GID` and the generated
random value for the secret. The private `.env`, ROMs and saves are not
tracked in Git.

Set `GAMES_DIR` in `.env` to the shared ROM library root. Keep one
subdirectory per console, for example:

```text
$GAMES_DIR/
├── snes/<game>.sfc
└── gba/<game>.gba
```

Session ROM paths are relative to `GAMES_DIR`. **Edit the sample `spec.rom` to
match your file**. A session only needs its own console's ROM. `GAMES_DIR` is
required; the scripts still accept `ROM_DIR` as a legacy alias. If an existing
node attachment uses the old SNES-only root, follow the
[migration instructions](operator/README.md#existing-snes-only-attachment)
before changing it.

### 2. Start Minikube and load images

From the repository root:

```bash
minikube start -p minikube --driver=docker --keep-context

docker build -t retro-k8s-poc/retroarch-input:latest -t retro-k8s-poc/retroarch-input:pilot \
  --target retroarch-input -f runtimes/retroarch/Dockerfile .
docker build -t retro-k8s-poc/frontend:latest -t retro-k8s-poc/frontend:pilot \
  -f frontend/Dockerfile .
docker pull bluenviron/mediamtx:1

minikube -p minikube image load --daemon retro-k8s-poc/retroarch-input:pilot
minikube -p minikube image load --daemon retro-k8s-poc/frontend:pilot
```

The pilot uses locally loaded images with `imagePullPolicy: Never` for the
operator's session containers. The operator deploy script builds and loads the
operator image and loads the local MediaMTX image.

### 3. Deploy the operator and shared platform

```bash
bash deploy/kubernetes/local/deploy-operator.sh
bash deploy/kubernetes/local/deploy-platform.sh
```

The operator script creates or reuses the token Secret, attaches the host input
and ROM paths if needed, and deploys the operator. The platform script deploys
the frontend and shared MediaMTX, advertising the Minikube IP for WebRTC. See
[operator deployment](operator/README.md#deploy-on-minikube) for options and
attachment details.

### 4. Create a session

After updating the sample ROM path to match your library, apply its save claim
and `RetroSession`:

```bash
# SNES
kubectl --context minikube apply -f deploy/kubernetes/samples/snes/chrono-trigger-saves.yaml
kubectl --context minikube apply -f deploy/kubernetes/samples/snes/retrosession-snes.yaml

# Or GBA
kubectl --context minikube apply -f deploy/kubernetes/samples/gba/gba-saves.yaml
kubectl --context minikube apply -f deploy/kubernetes/samples/gba/retrosession-gba.yaml

kubectl --context minikube -n retro-k8s get retrosessions,pods,pvc
```

The frontend discovers the sessions when they become ready. Give each running
session its own save claim; the operator does not create or delete claims.
Deleting a `RetroSession` removes its Deployment and input Service, but keeps
its PVC. `Ready` means the operator's readiness checks pass; it is not an
end-to-end guarantee that browser playback works.

### 5. Open the browser

In a terminal, keep the frontend port-forward running:

```bash
bash deploy/kubernetes/local/port-forward-frontend.sh
```

Open [http://127.0.0.1:18000](http://127.0.0.1:18000), select a ready session,
and click **Unmute** for sound. WebRTC media uses Minikube's UDP NodePort
`30189`; the frontend port-forward carries the web UI, input proxy and WebRTC
signaling. The optional [user service](deploy/kubernetes/local/retro-k8s-browser.service)
can keep the port-forward running.

| Keyboard | Control |
| --- | --- |
| Arrow keys | D-pad |
| X / Z | South (RetroPad B) / East (RetroPad A) |
| S / A | West (RetroPad Y) / North (RetroPad X) |
| Enter / Right Shift | Start / Select |
| Q / W | L / R |

Standard browser gamepads are also supported. Keep the page focused while
playing. Unplugging, focus loss, disconnect or heartbeat timeout releases held
input.

### Stop or restart

Save in the game before stopping or restarting a session; unsaved progress may
be lost. To reset a session's emulator by replacing its Pod:

```bash
kubectl --context minikube -n retro-k8s rollout restart deployment/chrono-trigger
kubectl --context minikube -n retro-k8s rollout status deployment/chrono-trigger
```

To stop Minikube, run `minikube stop -p minikube`. Existing PVCs are retained;
stopping the cluster does not delete them. Stop the browser port-forward with
Ctrl+C. Restarting or upgrading the operator can replace session Pods, so save
first. See the [operator README](operator/README.md#existing-snes-only-attachment)
if the host input/ROM attachment needs to be reattached.

## Diagnostics and tests

The browser's **Session diagnostics** panel reports input acknowledgments,
held buttons, browser-to-agent round-trip times and WebRTC statistics. Agent
acceptance means the input reached the agent's controller state; it does not
prove that RetroArch consumed it. WebRTC metrics do not measure the entire
input-to-screen path.

Inspect a Kubernetes session and its logs:

```bash
kubectl --context minikube -n retro-k8s describe retrosession chrono-trigger
kubectl --context minikube -n retro-k8s logs deployment/chrono-trigger -c session
kubectl --context minikube -n retro-k8s logs deployment/chrono-trigger -c audio-relay
kubectl --context minikube -n retro-k8s logs deployment/mediamtx
```

The [input probe](deploy/kubernetes/local/input-probe/README.md) tests uinput
access without starting a game. For automated checks:

```bash
python3 -m venv .venv
.venv/bin/pip install -r input-agent/requirements.txt
.venv/bin/python -m unittest discover -s input-agent/tests -t input-agent -v
PYTHONPATH=frontend:input-agent .venv/bin/python -m unittest discover -s frontend/tests -t frontend -v
node --test frontend/tests/*.mjs
(cd operator && make test)
bash operator/tests/media-recovery.sh
```

The media recovery test uses isolated Docker containers and a synthetic stream;
it needs the local `bluenviron/mediamtx:1` and `retro-k8s-poc/frontend:pilot`
images. [operator/verify-snes-session.sh](operator/verify-snes-session.sh) is a separate **live cluster
test**: it deletes and recreates its SNES test session and Deployment while
retaining its save PVC. Read the [verification steps](operator/README.md#verify)
before running it.

## Status and next steps

Checks performed on Minikube in November 2026:

- A privileged, non-root probe created and read a virtual controller. The
  non-privileged probe could not open `/dev/uinput`.
- SNES started from a read-only ROM, used its reserved pad and reloaded an
  in-game save after Pod replacement. Operator checks covered resource repair
  and save-PVC retention across session deletion and recreation.
- GBA started with mGBA alongside SNES, used its own pad and save claim, and
  delivered video and non-silent decoded audio to a browser. Keyboard and a
  simulated gamepad were exercised. A GBA in-game save/reload and a physical
  gamepad check remain to be confirmed.
- An isolated GBA session resumed publishing H.264 and Opus after the shared
  MediaMTX restarted, without restarting the emulator Pod or its containers.
  Automatic browser reconnection after that interruption remains unverified.

Next, complete the GBA save/reload and physical-controller checks, verify
browser reconnection after a shared MediaMTX restart, and build authenticated
session routing, per-player save ownership and tested controller isolation
before supporting multiple untrusted players.

## Pilot limitations

- The emulator container is privileged and uses host input devices. Controller
  naming and selection are not security isolation.
- The token endpoint has no user authentication. Keep this pilot local; remote
  access needs authentication, HTTPS/WSS, explicit origins and session routing.
- `ReadWriteOnce` claims should be dedicated to individual sessions. ROMs are
  read-only; save data persists in the PVC, not in the ROM library.
- The session-local media server protects against a restart of the *shared*
  MediaMTX; failure of the local media container can still interrupt the stream.

To add another Libretro console, include its core in the RetroArch image and
extend the operator's console API, core mapping and tests. A different emulator
runtime also needs an operator workload implementation; adding a directory
under `runtimes/` alone does not make it available.
