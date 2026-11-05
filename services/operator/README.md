# RetroSession operator

This is roadmap step 4: a namespaced `RetroSession` resource and a Go
controller-runtime operator that turns each session into one emulator
Deployment and one input Service.

The operator manages the emulator lifecycle only. It does **not** create,
own or delete the save PVC. The claim is mounted at `/saves`, and its contents
survive session deletion so a recreated session can reuse them.

## API

- Group/version: `retro.k8s/v1alpha1`
- Kind: `RetroSession`
- Short name: `rs`
- Scope: namespaced (`retro-k8s` in the pilot)

```yaml
apiVersion: retro.k8s/v1alpha1
kind: RetroSession
metadata:
  name: chrono-trigger
  namespace: retro-k8s
spec:
  console: snes
  rom: snes/Chrono Trigger (USA).sfc
  saveClaimName: chrono-trigger-saves
```

### Spec

| Field | Required | Meaning |
| --- | --- | --- |
| `console` | yes | `snes` (snes9x) or `gba` (mgba). |
| `rom` | yes | Path relative to the operator's ROM library. No absolute paths, `.` or `..`. |
| `saveClaimName` | yes | Existing PVC in the same namespace, mounted at `/saves`. |
| `image` | no | Session image override. Defaults to `retro-k8s-poc/retroarch-input:pilot`. |
| `padName` | no | Virtual pad name. Defaults to `Retro-K8s Pad <session name>`. |
| `minHoldMS` | no | Minimum button hold in milliseconds. |
| `logLevel` | no | Input agent log level. |
| `showFPS` | no | Enable RetroArch's frame counter. |
| `allowedOrigins` | no | WebSocket origin allowlist for the input agent. |

### Status

`status.phase` is `Pending`, `Ready` or `Failed`. The `Ready` condition requires
the current Deployment rollout to be available and these component conditions:

- `EmulatorReady`: the `session` container's readiness probe sees the RetroArch
  process.
- `InputAgentReady`: the `input-health` sidecar can open a TCP connection to the
  input agent on `127.0.0.1:8765`.
- `MediaReady`: the `audio-relay` readiness probe checks the Pod-local RTMP
  listener and both video and audio from the shared MediaMTX stream.

`status.reason`/`status.message` report the first unavailable component
(`EmulatorNotReady`, `InputAgentNotReady` or `MediaNotReady`),
`DeploymentRolloutPending`, or a concrete failure such as `SaveClaimNotFound`,
`DeploymentReconcileFailed`, `ServiceReconcileFailed`,
`ProgressDeadlineExceeded`, `ImagePullBackOff`, `CrashLoopBackOff` and
unschedulable Pods. A progress deadline is not treated as a session failure
while the emulator container is still running; the component condition explains
the outage instead.

A live Minikube check with an isolated GBA session confirmed that a shared
MediaMTX outage reports `MediaNotReady` and recovers without restarting the
session Pod. A paused Deployment update remained `Pending` while its old Pod
was ready, then became `Ready` after the replacement rollout completed.

`status.endpoints` is the frontend contract:

```yaml
endpoints:
  inputService: chrono-trigger-input
  inputPort: 8765
  inputPath: /sessions/chrono-trigger/input
  streamPath: chrono-trigger
  rtmpURL: rtmp://127.0.0.1:1935/raw/chrono-trigger  # reachable within the session Pod
  whepPath: /chrono-trigger/whep
```

`status.deploymentName`, `status.serviceName`, `status.podName` and
`status.saveClaimName` report the resources the session is using.

## Behavior

- Creates a single-replica Deployment with the `Recreate` strategy and a
  `ClusterIP` input Service. Both have a controller owner reference, so
  Kubernetes garbage-collects them when the `RetroSession` is deleted.
- Uses server-side apply for the Deployment and Service. Reconciles are
  idempotent and API-defaulted fields do not cause a reconcile loop.
- Refuses to adopt a same-name Deployment or Service that is not controlled by
  the session. The session reports `DeploymentReconcileFailed` or
  `ServiceReconcileFailed` instead of creating a duplicate emulator.
- Recreates a missing Deployment or Service on the next reconcile.
- Requires the save PVC to exist. While it is unbound, the Deployment is still
  created (so `WaitForFirstConsumer` storage can bind it), but the session stays
  `Pending` with reason `SaveClaimNotBound`.
- Watches the save PVC, so a claim that binds later triggers another reconcile.
- Watches the session Pod and requeues while the session is not `Ready`, so a
  recovered media path is observed even without a Pod update.
- Uses readiness probes, not liveness probes, for the emulator, input agent and
  media path. A failing probe removes the Pod from the input Service endpoints
  without restarting it, and the `Recreate` strategy only replaces the Pod when
  the Deployment spec changes. A shared MediaMTX outage therefore does not
  restart a running game.
- Runs a lightweight `input-health` sidecar with the session image so the input
  agent has an independent readiness signal without changing the combined
  agent/emulator container.
- Never deletes the save PVC. Deleting the `RetroSession` removes the emulator
  and input Service only.
- Skips unchanged status writes, so a steady-state session does not reconcile in
  a loop.

The session Pod keeps the pilot's trusted-local security exception: it runs as
the configured non-root UID/GID with the input group and a privileged container
for `/dev/uinput`. It mounts the node's attached input paths and ROM library
read-only.

## Deploy on Minikube

Prerequisites:

- A Docker-backed Minikube profile with the pilot's input/ROM paths attached.
- The session image (`retro-k8s-poc/retroarch-input:pilot`) loaded into the
  profile.
- A `.env` with `GAMES_DIR`, `PUID`, `PGID`, `INPUT_GID`, and (if the Secret
  does not exist yet) `INPUT_TOKEN_SECRET`.

```bash
bash bootstrap/minikube/deploy-operator.sh
bash bootstrap/minikube/deploy-platform.sh
```

The script builds `retro-k8s-poc/operator:pilot`, loads it into Minikube,
reuses or creates `retro-session-secret`, attaches host input/ROM paths if they
are not attached already, applies the CRD/RBAC/manager, and waits for the
operator rollout. Host-specific UID/GID and input paths are passed through a
generated overlay; `services/operator/k8s/default` keeps checked-in pilot defaults.
The platform script installs the shared frontend and MediaMTX with the
Minikube IP advertised for WebRTC. It reuses the session Secret.

`GAMES_DIR` must point to the shared ROM library root, with ROMs under `snes/`
and `gba/`. Session ROM paths are relative to that root. The scripts still
accept `ROM_DIR` as a legacy alias.

Options: `--no-build`, `--no-load`, `--no-attach`.

Apply the sample session:

```bash
kubectl apply -f services/operator/samples/snes/chrono-trigger-saves.yaml
kubectl apply -f services/operator/samples/snes/retrosession-snes.yaml
kubectl -n retro-k8s get retrosession chrono-trigger -o yaml
```

## Verify

```bash
bash services/operator/verify-snes-session.sh
```

The script checks the full SNES path:

1. Creates the dedicated save PVC and the sample `RetroSession`.
2. Waits for `Ready` and checks the status endpoints.
3. Confirms the Deployment/Service ownership, one replica, `Recreate`, and a
   ready input Service endpoint.
4. Confirms RetroArch starts, the ROM path is read-only, and the session's
   virtual pad is reserved for player 1.
5. Writes a marker to `/saves`, deletes the Deployment, and confirms the
   operator repairs it and the marker survives.
6. Deletes the `RetroSession`, confirms the Deployment/Service are gone and the
   PVC remains.
7. Recreates the session and confirms it reuses the PVC and the marker.

It leaves the recreated session running. Stop it with:

```bash
kubectl -n retro-k8s delete retrosession chrono-trigger
```

The save PVC `chrono-trigger-saves` is retained.

## GBA

The API selects the `mgba` core for `console: gba`. GBA has started on
Minikube with video, decoded audio, keyboard and simulated gamepad input; an
in-game save/reload and physical gamepad check remain to be confirmed. With
the shared library attached, apply the GBA save claim and sample:

```bash
kubectl apply -f services/operator/samples/gba/gba-saves.yaml
kubectl apply -f services/operator/samples/gba/retrosession-gba.yaml
```

The sample uses `rom: gba/Pokemon - Emerald Version (USA, Europe).gba`. Adjust
the filename to the ROM in the library.

### Existing SNES-only attachment

Older deployments attached the `snes/` directory itself as the library root
and used bare filenames in existing `RetroSession` objects. The attachment script
still recognizes the old state file. Before switching to the shared library,
save progress and stop all sessions using the existing attachment. Detach it
with `bash bootstrap/minikube/attach-node-input.sh detach`, then attach the shared root
with `GAMES_DIR="/path/to/roms" bash bootstrap/minikube/attach-node-input.sh attach`.
The attachment helper reads `GAMES_DIR` from its environment; setting it only in
`.env` does not export it to a directly invoked helper. Update existing SNES
resources to prefix their ROM path with `snes/` before starting them again.
Save PVCs remain separate and should be retained during this migration.

## Pilot limitations

- One namespace (`retro-k8s`) and one shared host input device. There is no
  authenticated session routing or per-player isolation yet.
- The current browser frontend discovers `RetroSession` resources through its
  service account and proxies `/api/sessions/<name>/input` and
  `/api/sessions/<name>/whep` to the endpoints in `status.endpoints`. The browser
  no longer needs direct session port-forwards; WebRTC media still uses the
  MediaMTX NodePort.
- Each session publishes to a Pod-local MediaMTX container. Its FFmpeg relay
  retries the shared MediaMTX connection, converts AAC to Opus, and copies video
  to the session playback path. The Pod-local server preserves the emulator stream
  across shared MediaMTX restarts; loss of the local server can interrupt it.
- A save PVC is `ReadWriteOnce` in the pilot. Use a separate claim per session;
  do not point two running sessions at the same claim.
- The session image is privileged because the pilot's non-privileged probe
  could not open `/dev/uinput`. This is a trusted-local exception, not a
  multi-tenant security model.
- `imagePullPolicy` is `Never` in the pilot so locally loaded images are used.

## Development

The API types live in `api/v1alpha1`, the reconciler in
`internal/controller`, and the manager in `cmd/manager`.

```bash
cd services/operator
make generate     # deepcopy
make manifests    # CRD and RBAC
make test
make build
```

`controller-gen` v0.23.0 and Go 1.27 were used for the pilot. The unit tests
use controller-runtime's fake client and cover creation, status/endpoints,
missing and pending claims, repair, foreign-resource refusal, per-component
readiness and media recovery, failure reporting, GBA core selection, and spec
validation.

## Shared media recovery

Each session's local MediaMTX receives RetroArch's RTMP stream. The audio relay
reads that stream and retries its connection to the shared MediaMTX, so a shared
server restart does not require restarting RetroArch. If the relay cannot
probe the shared stream, `MediaReady` is false and the Pod is removed from the
input Service endpoints; the Pod is not restarted. Deploying this version changes
the session Pod template and therefore replaces running Pods: save game progress
before upgrading. The session Pod also needs the configured local media image
available on the node when the pull policy is `Never`.

To exercise the network topology without changing Kubernetes workloads, run
`bash services/operator/tests/media-recovery.sh`. It uses Docker, the local
`bluenviron/mediamtx:1` image, and the frontend FFmpeg image. The test publishes
a synthetic video/audio stream and restarts an isolated shared server; it does
not verify RetroArch or browser playback.

A separate Minikube check on November 3, 2026 used an isolated GBA
`RetroSession` and save claim. After restarting its shared MediaMTX deployment,
H.264 and Opus returned without restarting the emulator Pod or its containers.
That check did not exercise browser reconnection.
