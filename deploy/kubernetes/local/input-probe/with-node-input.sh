#!/usr/bin/env bash
# Attach just the live input paths for one probe on a Docker-backed Minikube node.
set -euo pipefail
profile=${MINIKUBE_PROFILE:-minikube}
runner=$(dirname "$0")/run.sh
case "$#:${1:-}" in
  0:|1:--privileged) ;;
  *) echo "Usage: bash $0 [--privileged]" >&2; exit 2 ;;
esac

label=$(docker inspect --format '{{index .Config.Labels "name.minikube.sigs.k8s.io"}}' "$profile")
[[ $label == "$profile" ]] || { echo "Expected a local Minikube Docker node named $profile" >&2; exit 1; }
kubectl --context "$profile" wait --for=condition=Ready "node/$profile" --timeout=20s

# The helper shares the node's PID namespace so the node can bind the three
# explicitly supplied mounts. It has no capabilities and runs no probe code.
image=retro-k8s-poc/retroarch-input:latest
helper=$(docker run -d --rm --pull=never --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --pid="container:$profile" \
  --mount type=bind,src=/dev/uinput,dst=/input/uinput \
  --mount type=bind,src=/dev/input,dst=/input/events,readonly \
  --mount type=bind,src=/run/udev/data,dst=/input/metadata,readonly \
  --entrypoint /bin/sh "$image" -c 'echo $$; exec sleep 300')
node_root=""
cleanup() {
  if [[ -n $node_root ]]; then
    docker exec "$profile" sh -ec '
      cd "$1"
      for path in run/udev/data dev/input dev/uinput; do
        if mountpoint -q "$path"; then umount "$path"; fi
      done
      rm -f dev/uinput
      rmdir run/udev/data run/udev run dev/input dev
      cd / && rmdir "$1"
    ' sh "$node_root" || echo "Check temporary input mounts in $profile:$node_root" >&2
  fi
  docker stop -t 1 "$helper" >/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for _ in {1..20}; do
  pid=$(docker logs "$helper")
  [[ -n $pid ]] && break
  sleep 0.1
done
[[ $pid =~ ^[1-9][0-9]*$ ]] || { echo "Cannot identify input mount helper" >&2; exit 1; }
node_root=$(docker exec "$profile" mktemp -d /run/retro-input-XXXXXXXX)
docker exec "$profile" sh -ec '
  cd "$1"
  mkdir -p dev/input run/udev/data
  touch dev/uinput
  chmod 0711 .
' sh "$node_root"
# Linux rejects legacy bind mounts between mount namespaces. Clone the three
# selected mounts in their source namespace, then attach them inside the node.
docker exec -i "$profile" python3 - "$node_root" "$pid" <<'PY'
import ctypes
import os
import sys

target, pid = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)

def checked(fn, *args):
    value = fn(*args)
    if value < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"{fn.__name__}: {os.strerror(err)}")
    return value

node_ns = os.open("/proc/self/ns/mnt", os.O_RDONLY)
source_ns = os.open(f"/proc/{pid}/ns/mnt", os.O_RDONLY)
source = os.open(f"/proc/{pid}/root/input", os.O_PATH)
destination = os.open(target, os.O_PATH)
paths = [(b"uinput", b"dev/uinput"), (b"events", b"dev/input"),
         (b"metadata", b"run/udev/data")]
checked(libc.setns, source_ns, 0)
mounts = [(checked(libc.open_tree, source, src, 1), dst) for src, dst in paths]  # OPEN_TREE_CLONE
checked(libc.setns, node_ns, 0)
for fd, dst in mounts:
    checked(libc.move_mount, fd, b"", destination, dst, 4)  # MOVE_MOUNT_F_EMPTY_PATH
PY
NODE_INPUT_ROOT="$node_root" bash "$runner" "$@"
