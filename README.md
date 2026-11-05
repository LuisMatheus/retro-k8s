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
bootstrap/minikube/       Local setup scripts and shared platform overlay
services/
  frontend/              Browser UI, proxy, and its Kubernetes manifests
  mediamtx/k8s/          Shared streaming server and its manifests
  operator/              RetroSession controller, manifests, and samples
  profile-api/           Phoenix API, SQLite schema, and manifests
  runtimes/              Emulator runtimes
    retroarch/           RetroArch image and startup scripts
      input-agent/       Gamepad code included in the session image
games/                   Local read-only ROM library (not tracked by Git)
profiles/                Local SQLite data (not tracked by Git)
saves/                   Local game saves (not tracked by Git)
```

The operator generates a session Deployment that combines RetroArch and the
input agent; they do not have separate static Deployment manifests.

See the [operator README](services/operator/README.md) for the API, reconciliation,
configuration and verification details, and the [frontend README](services/frontend/README.md)
for the browser components.

The session image starts `services/runtimes/retroarch/start-session.sh`, which starts the
input agent and then `start-retroarch.sh`. For local cluster setup, run
`bootstrap/minikube/deploy-operator.sh` and `deploy-platform.sh`; use
`port-forward-frontend.sh` to connect a browser.

## Run on Minikube

These instructions use a Linux host with Docker, Minikube, `kubectl` and
OpenSSL. The Minikube profile must use the Docker driver. The session image
requires `/dev/uinput`, `/dev/input` and live udev metadata; it runs privileged
for this pilot. Ensure you have permission to use the ROMs you provide.

### Setup order and dependencies

For a first installation, follow the numbered steps below. Each step supplies
something needed by the next:

```text
Host configuration and ROMs
  → Minikube and locally loaded images
  → operator and shared platform
  → save PVC and RetroSession
  → operator-created game Deployment and input Service
  → frontend port-forward and browser
```

Run the operator helper before the platform helper: it creates or reuses the
Secret needed by the frontend, installs the `RetroSession` CRD and starts the
operator. Apply a session's PVC before its `RetroSession`; the operator expects
the claim to exist and does not create it. If the claim is missing, the session
reports `SaveClaimNotFound` and the operator retries. You do not need to apply
an emulator Deployment yourself: the operator creates it and the input Service.

Kubernetes starts and reconciles the resources asynchronously, so applying a
manifest does not mean its Pods are already ready. Check progress with
`kubectl --context minikube -n retro-k8s get retrosessions,pods,pvc` before
opening the browser.

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

Place your ROMs in the repository's `games/` directory, one subdirectory per
console:

```text
games/
├── snes/<game>.sfc
└── gba/<game>.gba
```

The local game mount defaults to this directory. Each console has a separate
read-only game PVC, mounted by the operator into its sessions.
To use another library, set `GAMES_DIR` in `.env` to its absolute path. Existing
`.env` values still take precedence; relative paths are relative to the repository
root. Session ROM paths are relative to the library root. **Edit the sample
`spec.rom` to match your file**. If the node already has a different library
attached, follow the [attachment instructions](services/operator/README.md#existing-snes-only-attachment).

### 2. Start Minikube and load images

From the repository root:

```bash
bash bootstrap/minikube/start.sh

docker build -t retro-k8s-poc/retroarch-input:latest -t retro-k8s-poc/retroarch-input:pilot \
  --target retroarch-input -f services/runtimes/retroarch/Dockerfile .
docker build -t retro-k8s-poc/frontend:latest -t retro-k8s-poc/frontend:pilot \
  -f services/frontend/Dockerfile .
docker pull bluenviron/mediamtx:1

minikube -p minikube image load --daemon retro-k8s-poc/retroarch-input:pilot
minikube -p minikube image load --daemon retro-k8s-poc/frontend:pilot
```

The pilot uses locally loaded images with `imagePullPolicy: Never` for the
operator's session containers. The operator deploy script builds and loads the
operator image and loads the local MediaMTX image.

### 3. Deploy the operator and shared platform

```bash
bash bootstrap/minikube/deploy-operator.sh
bash bootstrap/minikube/deploy-platform.sh
```

The operator script creates or reuses the token Secret, attaches the host input
and ROM paths if needed, and deploys the operator. The platform script deploys
the frontend and shared MediaMTX, advertising the Minikube IP for WebRTC. See
[operator deployment](services/operator/README.md#deploy-on-minikube) for options and
attachment details.

### 4. Mount saves and create a session

From the repository root, keep each of these commands running in a separate
terminal while sessions are running. They connect the host game and save folders
to the Minikube node:

```bash
bash bootstrap/minikube/mount-saves.sh
# In another terminal:
bash bootstrap/minikube/mount-games.sh
```

Then, after updating the sample ROM path, apply the local save volume and its
`RetroSession`:

```bash
# SNES
kubectl --context minikube apply -k bootstrap/minikube/storage/snes
kubectl --context minikube apply -f services/operator/samples/snes/retrosession-snes.yaml

# Or GBA
kubectl --context minikube apply -k bootstrap/minikube/storage/gba
kubectl --context minikube apply -f services/operator/samples/gba/retrosession-gba.yaml

kubectl --context minikube -n retro-k8s get retrosessions,pods,pvc
```

Each local storage configuration creates separate game and save PVs and PVCs.
The game PVs map `games/snes/` and `games/gba/` into the corresponding
sessions; the session mounts are read-only. The sample save claims use separate PersistentVolumes: `retro-k8s-local-snes-saves`
maps to `saves/snes/`, and `retro-k8s-local-gba-saves` maps to `saves/gba/`.
The script mounts their common parent once; each PV points to its own directory.
To add a console, create its directory under `saves/`, add game and save PVs and PVCs under
`bootstrap/minikube/storage/<console>/` with unique names and matching node
paths, add console support to the operator, and set the session's `saveClaimName` to its save PVC. They
are writable by the session's configured UID/GID. Keep the mount active and
restart both mounts after Minikube stops; stop session Pods before the mount is removed.
These static local volumes use `Retain` and are for the single-node Minikube
pilot. They do not create per-player isolation or backups.

**Existing installations:** a bound PVC cannot be switched to the local volume
in place, and applying this overlay does not migrate its data. Back up and migrate
any existing saves before replacing the claim. For a portable dynamic PVC instead,
use the save claim manifests under `services/operator/samples/`.

The frontend discovers the sessions when they become ready. Give each running
session its own save claim; the operator does not create or delete claims.
Deleting a `RetroSession` removes its Deployment and input Service, but keeps
its PVC. `Ready` means the operator's readiness checks pass; it is not an
end-to-end guarantee that browser playback works.

### Optional: deploy the profile API

The profile API is an independent, experimental service. The frontend can list,
create, rename, and select profiles, but profiles do not yet own sessions or saves.
After starting Minikube, use its [setup instructions](services/profile-api/README.md)
to build the image, create its Secret, mount `profiles/`, and apply its local
overlay. This can be done after the namespace is created in step 3.

### 5. Open the browser

In a terminal, keep the frontend port-forward running:

```bash
bash bootstrap/minikube/port-forward-frontend.sh
```

Open [http://127.0.0.1:18000](http://127.0.0.1:18000), select a ready session,
and click **Unmute** for sound. WebRTC media uses Minikube's UDP NodePort
`30189`; the frontend port-forward carries the web UI, input proxy and WebRTC
signaling. The optional [user service](bootstrap/minikube/retro-k8s-browser.service)
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
first.

On a normal Minikube restart, previously applied resources and PVCs remain in
the cluster. You normally do not need to rebuild images, redeploy the operator,
or reapply session manifests unless they have changed or are missing. Start
Minikube, restore the game and save mounts before starting session Pods, check session
readiness and run the browser port-forward. The mount must remain running in a
separate terminal:

```bash
bash bootstrap/minikube/start.sh
# In separate terminals: bash bootstrap/minikube/mount-saves.sh
# and bash bootstrap/minikube/mount-games.sh
kubectl --context minikube -n retro-k8s get retrosessions,pods,pvc
bash bootstrap/minikube/port-forward-frontend.sh
```

**Known restart issue:** the host input and ROM mounts may disappear when
Minikube stops, even though the attachment state file remains. The operator
deploy helper currently trusts that state file; it does not automatically detect
missing mounts. Check the default node paths after starting Minikube:

```bash
docker exec minikube sh -c 'test -c /run/retro-k8s-input/dev/uinput && test -d /run/retro-k8s-input/dev/input && test -d /run/retro-k8s-input/run/udev/data && test -d /run/retro-k8s-input/roms' \
  && echo 'Input and ROM paths exist' || echo 'Input or ROM paths are missing'
```

If paths are missing, save any running games and stop the sessions using the
attachment before detaching it. For the example SNES and GBA sessions, first
pause the operator so it does not immediately recreate their Pods, then scale
down the Deployments that exist in your cluster:

```bash
kubectl --context minikube -n retro-k8s scale deployment/retrosession-operator --replicas=0
# Run the following only for sessions that exist:
kubectl --context minikube -n retro-k8s scale deployment/chrono-trigger --replicas=0
kubectl --context minikube -n retro-k8s scale deployment/pokemon-emerald --replicas=0
kubectl --context minikube -n retro-k8s wait --for=delete pod -l 'retro.k8s/session' --timeout=120s
```

This keeps the `RetroSession` definitions and save PVCs. Then detach the stale
attachment and reattach the shared library. Substitute the same absolute
library path used in `.env`; a directly invoked attachment helper reads
`GAMES_DIR` from its **environment**, not from `.env`:

```bash
bash bootstrap/minikube/attach-node-input.sh detach
GAMES_DIR="/absolute/path/to/roms" bash bootstrap/minikube/attach-node-input.sh attach
kubectl --context minikube -n retro-k8s scale deployment/retrosession-operator --replicas=1
```

The operator reconciles the sessions back to one replica. Check their readiness
before reconnecting. The path check above only
confirms the node paths exist. See the [operator README](services/operator/README.md#existing-snes-only-attachment)
when migrating an older SNES-only attachment.

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

For automated checks:

```bash
python3 -m venv .venv
.venv/bin/pip install -r services/runtimes/retroarch/input-agent/requirements.txt
.venv/bin/python -m unittest discover -s services/runtimes/retroarch/input-agent/tests -t services/runtimes/retroarch/input-agent -v
PYTHONPATH=services/frontend:services/runtimes/retroarch/input-agent .venv/bin/python -m unittest discover -s services/frontend/tests -t services/frontend -v
node --test services/frontend/tests/*.mjs
(cd services/operator && make test)
bash services/operator/tests/media-recovery.sh
```

The media recovery test uses isolated Docker containers and a synthetic stream;
it needs the local `bluenviron/mediamtx:1` and `retro-k8s-poc/frontend:pilot`
images. [services/operator/verify-snes-session.sh](services/operator/verify-snes-session.sh) is a separate **live cluster
test**: it deletes and recreates its SNES test session and Deployment while
retaining its save PVC. Read the [verification steps](services/operator/README.md#verify)
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
under `services/runtimes/retroarch/` alone does not make it available.
