# Minikube virtual controller probe

Run this on a trusted Linux workstation with a single-node, Docker-backed
Minikube profile. The disposable Pod uses the existing RetroArch session image
and its Python input driver. It needs no ROM, signing secret or running game.

## Run

From the project root, start the profile and load the local session image. If
the image is missing, build it first with `docker compose build retroarch-snes`.

```bash
export MINIKUBE_PROFILE=minikube
minikube start -p "$MINIKUBE_PROFILE" --driver=docker --keep-context
minikube -p "$MINIKUBE_PROFILE" image load --daemon retro-k8s-poc/retroarch-input:latest
bash k8s/input-probe/run.sh
```

On a Docker node missing the live event directory or udev metadata, use the
temporary attachment wrapper instead of the last command:

```bash
bash k8s/input-probe/with-node-input.sh
# If the device-open check fails, compare on the trusted local pilot:
bash k8s/input-probe/with-node-input.sh --privileged
```

The wrapper starts a short-lived helper from the local session image and gives
it the host uinput device, read-only input events and read-only udev metadata.
It uses the Docker node's mount privileges to attach those paths for the probe
and removes the attachments and helper on exit. It requires a Linux Docker
host and a Minikube node with Python 3 and glibc's `open_tree` and `move_mount`
interfaces. This procedure was verified with Minikube 1.39.0 on Nobara 44.

On November 2, 2026 the regular Pod could see the attachments but could not
open `/dev/uinput` for writing. On the same node the privileged Pod, running
as UID 1000, GID 1001 with supplementary input group 104, read `BTN_SOUTH` down
and up and confirmed device removal. Use this exception only for the trusted
single-session pilot.

The launcher defaults to your current UID/GID and the numeric group owning
`/dev/uinput`. If Compose uses different IDs, export `PUID`, `PGID` and
`INPUT_GID` with the corresponding values from your local configuration.
Use `bash k8s/input-probe/run.sh --render` to inspect the Pod manifest.

The launcher checks the host and node paths, then creates a uniquely named
Pod in the profile's `default` namespace. The probe creates one pad and opens
its event device by matching its unique name in sysfs. A pass requires the udev
joystick tag, a `BTN_SOUTH` press and release read from that event device, and
device removal on close. The launcher prints the Pod logs, returns its exit
status and requests deletion of the probe Pod on exit.

Record the profile, UID/GID, supplementary group, privilege mode and final
output. The expected final probe line is:

```text
PASS: virtual controller created, tagged, read and removed
```

## If the check fails

- **Several add-ons report connection refused on port 8443 during startup.**
  Check `minikube status` and `kubectl --context minikube get --raw /readyz`
  first. When the Docker node was recreated on this workstation, its etcd
  database survived but its kubeconfigs and static control-plane manifests
  were missing. The kubelet journal and `/etc/kubernetes/manifests` inside the
  node distinguished that failure from a device or add-on problem.

- **Missing node path or event device.** Kubernetes resolves host paths inside
  the Minikube Docker node. Check `/dev/uinput` (character device),
  `/dev/input` (including newly created events) and `/run/udev/data` (live
  joystick metadata) at both boundaries. A directory created by hand cannot
  supply device events or metadata. For a fresh dedicated profile, the
  Docker driver supports a start-time directory mount. If you stage native
  bind mounts under a host directory preserving `dev/uinput`, `dev/input`
  and `run/udev/data`, use `--mount-string <host-directory>:/mnt/retro-input`
  when creating the profile and export `NODE_INPUT_ROOT=/mnt/retro-input` for
  the runner. Verify the paths inside the node before retrying.
  [Minikube mount documentation](https://minikube.sigs.k8s.io/docs/handbook/mount/)
- **Permission denied.** Verify that the session's input group can write the
  host uinput device and read the event nodes. If those permissions match but
  the Pod still cannot open the devices, the container runtime may be denying
  device access. On the trusted local pilot only, retry with
  `bash k8s/input-probe/run.sh --privileged` and record both outcomes. This
  enables privileged container access while keeping the same non-root UID/GID.
- **Pod cannot start.** Check the Pod description printed on timeout. For
  `ErrImageNeverPull`, load the local session image into the selected profile.
  For admission or mount errors, check namespace policy and the node paths.
