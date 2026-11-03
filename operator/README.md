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

`status.phase` is `Pending`, `Ready` or `Failed`. The `Ready` condition and
`status.reason`/`status.message` explain the current state, including concrete
failures such as `SaveClaimNotFound`, `DeploymentReconcileFailed`,
`ServiceReconcileFailed`, `ProgressDeadlineExceeded`, `ImagePullBackOff`,
`CrashLoopBackOff` and unschedulable Pods.

`status.endpoints` is the frontend contract:

```yaml
endpoints:
  inputService: chrono-trigger-input
  inputPort: 8765
  inputPath: /sessions/chrono-trigger/input
  streamPath: chrono-trigger
  rtmpURL: rtmp://mediamtx:1935/raw/chrono-trigger
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
- A `.env` with `PUID`, `PGID`, `INPUT_GID`, and (if the Secret does not exist
  yet) `INPUT_TOKEN_SECRET`.

```bash
bash operator/deploy.sh
bash deploy/kubernetes/local/deploy-platform.sh
```

The script builds `retro-k8s-poc/operator:pilot`, loads it into Minikube,
reuses or creates `retro-session-secret`, attaches host input/ROM paths if they
are not attached already, applies the CRD/RBAC/manager, and waits for the
operator rollout. Host-specific UID/GID and input paths are passed through a
generated overlay; `deploy/kubernetes/operator/default` keeps checked-in pilot defaults.
The platform script installs the shared frontend and MediaMTX with the
Minikube IP advertised for WebRTC. It reuses the session Secret.

The default library root is `~/Documents/games`, with ROMs under `snes/`
and `gba/`. Session ROM paths are relative to that root.

Options: `--no-build`, `--no-load`, `--no-attach`.

Apply the sample session:

```bash
kubectl apply -f deploy/kubernetes/samples/snes/chrono-trigger-saves.yaml
kubectl apply -f deploy/kubernetes/samples/snes/retrosession-snes.yaml
kubectl -n retro-k8s get retrosession chrono-trigger -o yaml
```

## Verify

```bash
bash operator/verify.sh
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

The API selects the `mgba` core for `console: gba`, but GBA has not yet been
validated on the Minikube node. With the shared library attached, apply the
GBA save claim and sample:

```bash
kubectl apply -f deploy/kubernetes/samples/gba/gba-saves.yaml
kubectl apply -f deploy/kubernetes/samples/gba/retrosession-gba.yaml
```

The sample uses `rom: gba/Pokemon - Emerald Version (USA, Europe).gba`. Adjust
the filename to the ROM in the library.

### Existing SNES-only attachment

Older deployments attached `~/Documents/games/snes` as the library root and
used bare filenames in existing `RetroSession` objects. The attachment script
still recognizes the old state file. Before switching to the shared library,
save progress and stop all sessions using the existing attachment. Detach it
with `bash deploy/kubernetes/local/attach-node-input.sh detach`, then attach the shared root
with `bash deploy/kubernetes/local/attach-node-input.sh attach`. Update existing SNES
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
- Each session includes an FFmpeg relay that converts AAC to Opus while
  copying video to the session's MediaMTX playback path.
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
cd operator
make generate     # deepcopy
make manifests    # CRD and RBAC
make test
make build
```

`controller-gen` v0.23.0 and Go 1.27 were used for the pilot. The unit tests
use controller-runtime's fake client and cover creation, status/endpoints,
missing and pending claims, repair, foreign-resource refusal, readiness,
failure reporting, GBA core selection, and spec validation.
