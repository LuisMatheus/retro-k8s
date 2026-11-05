#!/usr/bin/env bash
# Attach a native host bind mount to the Docker-backed Minikube node.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
profile=${MINIKUBE_PROFILE:-minikube}
node_path=/mnt/retro-k8s-profiles
helper="retro-k8s-profiles-$profile"
image=${HELPER_IMAGE:-retro-k8s-poc/retroarch-input:latest}
action=${1:-attach}
case "$action" in
  detach)
    if docker exec "$profile" mountpoint -q "$node_path"; then
      docker exec "$profile" umount "$node_path"
    fi
    docker rm -f "$helper" >/dev/null 2>&1 || true
    echo "Detached $profile:$node_path"
    exit 0 ;;
  attach) ;;
  *) echo "Usage: $0 [attach|detach]" >&2; exit 2 ;;
esac
mkdir -p "$repo_root/profiles"
if docker exec "$profile" mountpoint -q "$node_path"; then
  echo "A mount already exists at $profile:$node_path; detach it first." >&2
  exit 1
fi
if docker inspect "$helper" >/dev/null 2>&1; then
  echo "Helper $helper already exists; run $0 detach first." >&2
  exit 1
fi
docker run -d --rm --name "$helper" --pull=never --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges --pid="container:$profile" \
  --mount "type=bind,src=$repo_root/profiles,dst=/input/profiles" \
  --entrypoint /bin/sh "$image" -c 'echo $$; exec sleep infinity' >/dev/null
cleanup() { docker rm -f "$helper" >/dev/null 2>&1 || true; }
trap cleanup EXIT
pid=""
for _ in {1..50}; do
  pid=$(docker logs "$helper" 2>/dev/null || true)
  [[ $pid =~ ^[1-9][0-9]*$ ]] && break
  sleep 0.1
done
[[ $pid =~ ^[1-9][0-9]*$ ]] || { echo "Cannot identify profile mount helper." >&2; exit 1; }
docker exec "$profile" mkdir -p "$node_path"
docker exec -i "$profile" python3 - "$node_path" "$pid" <<'PY'
import ctypes
import os
import sys

target, pid = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
def checked(fn, *args):
    value = fn(*args)
    if value < 0:
        error = ctypes.get_errno()
        raise OSError(error, f"{fn.__name__}: {os.strerror(error)}")
    return value
node_ns = os.open('/proc/self/ns/mnt', os.O_RDONLY)
source_ns = os.open(f'/proc/{pid}/ns/mnt', os.O_RDONLY)
source = os.open(f'/proc/{pid}/root/input', os.O_PATH)
destination = os.open(os.path.dirname(target), os.O_PATH)
checked(libc.setns, source_ns, 0)
mount = checked(libc.open_tree, source, b'profiles', 1)
checked(libc.setns, node_ns, 0)
checked(libc.move_mount, mount, b'', destination, os.path.basename(target).encode(), 4)
PY
trap - EXIT
echo "Attached $repo_root/profiles to $profile:$node_path."
