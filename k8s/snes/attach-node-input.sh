#!/usr/bin/env bash
# Attach the host's live input paths and one read-only ROM directory to the
# Docker-backed Minikube node. The pilot Pod uses these node paths through
# hostPath volumes. Run "detach" after deleting the session.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
profile=${MINIKUBE_PROFILE:-minikube}
root=${NODE_INPUT_ROOT:-/run/retro-k8s-input}
rom_dir=${ROM_DIR:-$HOME/Documents/games/snes}
image=${HELPER_IMAGE:-retro-k8s-poc/retroarch-input:latest}
state=$script_dir/.node-input-state
action=${1:-attach}

usage() {
  echo "Usage: $0 [attach|detach]" >&2
}

[[ $action == attach || $action == detach ]] || { usage; exit 2; }
[[ $root =~ ^(/[a-zA-Z0-9_.-]+)+$ ]] ||
  { echo "NODE_INPUT_ROOT must be an absolute node directory." >&2; exit 2; }
[[ -d $rom_dir ]] || { echo "ROM directory not found: $rom_dir" >&2; exit 1; }

node_exists() {
  local label
  label=$(docker inspect --format '{{index .Config.Labels "name.minikube.sigs.k8s.io"}}' "$profile" 2>/dev/null) || return 1
  [[ $label == "$profile" ]]
}

stop_helper() {
  local helper=${1:-}
  [[ -n $helper ]] || return 0
  docker stop -t 1 "$helper" >/dev/null 2>&1 || docker rm -f "$helper" >/dev/null 2>&1 || true
}

unmount_node_root() {
  node_exists || return 0
  docker exec "$profile" sh -ec '
    root=$1
    failed=0
    for path in roms run/udev/data dev/input dev/uinput; do
      if mountpoint -q "$root/$path"; then
        umount "$root/$path" || failed=1
      fi
    done
    rm -f "$root/dev/uinput"
    rmdir "$root/roms" "$root/run/udev/data" "$root/run/udev" "$root/run" \
      "$root/dev/input" "$root/dev" "$root" 2>/dev/null || true
    exit "$failed"
  ' sh "$root"
}

detach() {
  local helper=""
  if [[ -f $state ]]; then
    # shellcheck disable=SC1090
    source "$state"
    helper=${helper:-}
  fi
  stop_helper "$helper"
  if ! unmount_node_root; then
    echo "Some mounts under $root are still busy. Delete the session Pods first." >&2
    exit 1
  fi
  rm -f "$state"
  echo "Detached host input and ROM directory from $profile:$root"
}

attach() {
  [[ -f $state ]] && { echo "Already attached; run $0 detach first." >&2; exit 1; }
  node_exists || { echo "Minikube Docker node '$profile' not found." >&2; exit 1; }
  [[ -c /dev/uinput ]] || { echo "/dev/uinput is not a character device." >&2; exit 1; }
  [[ -d /dev/input ]] || { echo "/dev/input is missing." >&2; exit 1; }
  [[ -d /run/udev/data ]] || { echo "/run/udev/data is missing." >&2; exit 1; }
  docker image inspect "$image" >/dev/null 2>&1 ||
    { echo "Helper image not found: $image" >&2; exit 1; }

  kubectl --context "$profile" wait --for=condition=Ready "node/$profile" --timeout=20s >/dev/null
  if docker exec "$profile" test -e "$root"; then
    echo "Node path already exists: $profile:$root (run $0 detach)" >&2
    exit 1
  fi

  local helper
  helper="retro-k8s-input-$(date +%s)-$$"
  # The helper shares the node's PID namespace so the node can clone the live
  # host mounts. It runs no session code and has no capabilities.
  docker run -d --rm --name "$helper" --pull=never --network none --read-only \
    --cap-drop ALL --security-opt no-new-privileges --pid="container:$profile" \
    --mount type=bind,src=/dev/uinput,dst=/input/uinput \
    --mount type=bind,src=/dev/input,dst=/input/events,readonly \
    --mount type=bind,src=/run/udev/data,dst=/input/metadata,readonly \
    --mount type=bind,src="$rom_dir",dst=/input/roms,readonly \
    --entrypoint /bin/sh "$image" -c 'echo $$; exec sleep infinity' >/dev/null

  umask 077
  printf 'helper=%q\nroot=%q\nrom_dir=%q\n' "$helper" "$root" "$rom_dir" > "$state"

  local pid=""
  for _ in {1..50}; do
    pid=$(docker logs "$helper" 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ ]] && break
    sleep 0.1
  done
  [[ $pid =~ ^[1-9][0-9]*$ ]] || { echo "Cannot identify input mount helper." >&2; exit 1; }

  cleanup() {
    stop_helper "$helper"
    unmount_node_root >/dev/null 2>&1 || true
    rm -f "$state"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  docker exec "$profile" sh -ec '
    root=$1
    mkdir -p "$root/dev/input" "$root/run/udev/data" "$root/roms"
    touch "$root/dev/uinput"
    chmod 0711 "$root"
  ' sh "$root"

  # Linux rejects legacy bind mounts between mount namespaces. Clone the four
  # selected mounts in the helper namespace, then attach them inside the node.
  docker exec -i "$profile" python3 - "$root" "$pid" <<'PY'
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
         (b"metadata", b"run/udev/data"), (b"roms", b"roms")]
checked(libc.setns, source_ns, 0)
mounts = [(checked(libc.open_tree, source, src, 1), dst) for src, dst in paths]  # OPEN_TREE_CLONE
checked(libc.setns, node_ns, 0)
for fd, dst in mounts:
    checked(libc.move_mount, fd, b"", destination, dst, 4)  # MOVE_MOUNT_F_EMPTY_PATH
PY

  docker exec "$profile" sh -ec '
    root=$1
    test -c "$root/dev/uinput"
    test -d "$root/dev/input"
    test -d "$root/run/udev/data"
    test -d "$root/roms"
  ' sh "$root"

  trap - EXIT INT TERM
  echo "Attached host input and ROM directory at $profile:$root"
  echo "ROM directory (read-only): $rom_dir"
}

case "$action" in
  attach) attach ;;
  detach) detach ;;
esac
