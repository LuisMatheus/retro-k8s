#!/usr/bin/env bash
# Deploy the single-SNES Minikube pilot: frontend, MediaMTX and one emulator.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
cd "$repo_root"

profile=${MINIKUBE_PROFILE:-minikube}
rom=""
build=false
load=true
attach=true

usage() {
  cat <<'EOF'
Usage: deploy/legacy/static-snes/deploy.sh [options]

  --rom PATH     ROM to expose read-only (default: $GAMES_DIR/snes/$SNES_ROM)
  --build        Rebuild the session and frontend images first
  --no-load      Do not load images into the Minikube profile
  --no-attach    Do not attach host input/ROM paths to the Minikube node
  -h, --help     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rom) rom=${2:?--rom needs a path}; shift 2 ;;
    --build) build=true; shift ;;
    --no-load) load=false; shift ;;
    --no-attach) attach=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

env_value() {
  local key=$1 line value
  [[ -f .env ]] || return 0
  line=$(grep -E "^[[:space:]]*${key}=" .env | tail -n 1 || true)
  [[ -n $line ]] || return 0
  value=${line#*=}
  value=${value%$'\r'}
  if [[ $value == \"*\" && $value == *\" ]]; then
    value=${value:1:${#value}-2}
  elif [[ $value == \'*\' && $value == *\' ]]; then
    value=${value:1:${#value}-2}
  fi
  printf '%s' "$value"
}

from_env_or_file() {
  local key=$1 value=${!1:-}
  [[ -n $value ]] || value=$(env_value "$key")
  printf '%s' "$value"
}

games_dir=$(from_env_or_file GAMES_DIR)
[[ -n $games_dir ]] || games_dir=$(from_env_or_file ROM_DIR)

if [[ -z $rom ]]; then
  rom_name=$(from_env_or_file SNES_ROM)
  [[ -n $rom_name ]] || { echo "Set SNES_ROM in .env or pass --rom PATH." >&2; exit 1; }
  [[ -n $games_dir ]] || { echo "Set GAMES_DIR in .env or the environment, or pass --rom PATH." >&2; exit 1; }
  rom="$games_dir/snes/$rom_name"
fi
[[ -f $rom ]] || { echo "ROM not found: $rom" >&2; exit 1; }
rom_parent=$(cd "$(dirname "$rom")" && pwd)
rom_file=$(basename "$rom")
[[ $rom_file != *$'\n'* ]] || { echo "ROM filename contains a newline." >&2; exit 1; }

secret=$(from_env_or_file INPUT_TOKEN_SECRET)
[[ -n $secret ]] || {
  echo "Set INPUT_TOKEN_SECRET in .env or the environment." >&2
  echo "Generate one with: openssl rand -hex 32" >&2
  exit 1
}
[[ $secret != *$'\n'* ]] || { echo "INPUT_TOKEN_SECRET contains a newline." >&2; exit 1; }

uid=$(from_env_or_file PUID); uid=${uid:-1000}
gid=$(from_env_or_file PGID); gid=${gid:-1000}
input_gid=$(from_env_or_file INPUT_GID)
[[ -n $input_gid ]] || input_gid=$(stat -c %g /dev/uinput 2>/dev/null || true)
[[ $uid =~ ^[1-9][0-9]*$ ]] || { echo "PUID must be a nonzero number." >&2; exit 1; }
[[ $gid =~ ^[0-9]+$ ]] || { echo "PGID must be a number." >&2; exit 1; }
[[ $input_gid =~ ^[0-9]+$ ]] || { echo "INPUT_GID must be a number." >&2; exit 1; }

show_fps=$(from_env_or_file SHOW_FPS); show_fps=${show_fps:-false}
log_level=$(from_env_or_file LOG_LEVEL); log_level=${log_level:-INFO}
min_hold=$(from_env_or_file MIN_HOLD_MS); min_hold=${min_hold:-40}
allowed_origins=$(from_env_or_file ALLOWED_ORIGINS)
allowed_origins="${allowed_origins:+$allowed_origins,}http://127.0.0.1:18000,http://localhost:18000"
webrtc_host=$(minikube -p "$profile" ip)
pad_name=${PAD_NAME:-Retro-K8s Pad snes-k8s}
[[ $pad_name != *$'\n'* && $allowed_origins != *$'\n'* ]] ||
  { echo "Pad name or allowed origins contain a newline." >&2; exit 1; }

if $build; then
  docker build -t retro-k8s-poc/retroarch-input:latest --target retroarch-input \
    -f runtimes/retroarch/Dockerfile .
  docker build -t retro-k8s-poc/frontend:latest -f frontend/Dockerfile .
fi
docker image inspect retro-k8s-poc/retroarch-input:latest >/dev/null
docker image inspect retro-k8s-poc/frontend:latest >/dev/null
docker tag retro-k8s-poc/retroarch-input:latest retro-k8s-poc/retroarch-input:pilot
docker tag retro-k8s-poc/frontend:latest retro-k8s-poc/frontend:pilot

if $load; then
  minikube -p "$profile" image load --daemon retro-k8s-poc/retroarch-input:pilot
  minikube -p "$profile" image load --daemon retro-k8s-poc/frontend:pilot
  minikube -p "$profile" image load --daemon bluenviron/mediamtx:1
fi

gen=$script_dir/generated
mkdir -p "$gen"
chmod 700 "$gen"
umask 077
cat > "$gen/secret.env" <<EOF
INPUT_TOKEN_SECRET=$secret
EOF
cat > "$gen/session.env" <<EOF
ROM_PATH=/roms/$rom_file
DEVICE_NAME=$pad_name
SESSION_ID=snes
SHOW_FPS=$show_fps
LOG_LEVEL=$log_level
MIN_HOLD_MS=$min_hold
ALLOWED_ORIGINS=$allowed_origins
WEBRTC_HOST=$webrtc_host
EOF
cat > "$gen/platform.env" <<EOF
WEBRTC_HOST=$webrtc_host
EOF
cat > "$gen/security-context.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snes
spec:
  template:
    spec:
      securityContext:
        runAsUser: $uid
        runAsGroup: $gid
        supplementalGroups:
          - $input_gid
        fsGroup: $gid
EOF
chmod 600 "$gen/secret.env" "$gen/session.env" "$gen/platform.env" "$gen/security-context.yaml"

if $attach; then
  state=$repo_root/deploy/kubernetes/local/.node-input-state
  [[ -f $state ]] || state=$repo_root/k8s/local/.node-input-state
  [[ -f $state ]] || state=$repo_root/k8s/snes/.node-input-state
  if [[ -f $state ]]; then
    # shellcheck disable=SC1090
    source "$state"
    if [[ ${rom_dir:-} != "$rom_parent" ]]; then
      echo "Attached ROM directory is $rom_dir, but the legacy session needs $rom_parent." >&2
      echo "Stop active sessions and detach before changing the attachment." >&2
      exit 1
    fi
    echo "Host input is already attached to the Minikube node."
    echo "To change the ROM directory, run $repo_root/deploy/kubernetes/local/attach-node-input.sh detach first."
  else
    GAMES_DIR="$rom_parent" MINIKUBE_PROFILE="$profile" \
      "$repo_root/deploy/kubernetes/local/attach-node-input.sh" attach
  fi
fi

existed=false
kubectl --context "$profile" -n retro-k8s get deployment/snes >/dev/null 2>&1 && existed=true
kubectl --context "$profile" apply -k "$script_dir"

# The pilot images keep the same "pilot" tag and the ConfigMaps use stable
# names, so restart existing workloads to pick up rebuilt images or config.
if $existed; then
  kubectl --context "$profile" -n retro-k8s rollout restart \
    deployment/mediamtx deployment/frontend deployment/audio-relay >/dev/null
fi

for deployment in mediamtx frontend audio-relay; do
  kubectl --context "$profile" -n retro-k8s rollout status \
    "deployment/$deployment" --timeout=120s
done

if $existed; then
  kubectl --context "$profile" -n retro-k8s rollout restart deployment/snes >/dev/null
fi

if ! kubectl --context "$profile" -n retro-k8s rollout status \
  deployment/snes --timeout=240s; then
  kubectl --context "$profile" -n retro-k8s get pods -o wide >&2 || true
  kubectl --context "$profile" -n retro-k8s describe deployment/snes >&2 || true
  pod=$(kubectl --context "$profile" -n retro-k8s get pods \
    -l app.kubernetes.io/name=snes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -z $pod ]] || kubectl --context "$profile" -n retro-k8s logs "$pod" --tail=120 >&2 || true
  exit 1
fi

pod=$(kubectl --context "$profile" -n retro-k8s get pods \
  -l app.kubernetes.io/name=snes -o jsonpath='{.items[0].metadata.name}')
echo
echo "SNES pod: $pod"
kubectl --context "$profile" -n retro-k8s logs "$pod" --tail=40

if kubectl --context "$profile" -n retro-k8s exec "$pod" -- \
  sh -c "grep -F '$pad_name' /proc/bus/input/devices >/dev/null"; then
  echo "Virtual pad '$pad_name' is present in /proc/bus/input/devices."
else
  echo "WARNING: virtual pad '$pad_name' was not found in the Pod." >&2
fi

if kubectl --context "$profile" -n retro-k8s exec "$pod" -- \
  sh -c 'touch /roms/.write-test' >/dev/null 2>&1; then
  kubectl --context "$profile" -n retro-k8s exec "$pod" -- \
    rm -f /roms/.write-test >/dev/null 2>&1 || true
  echo "WARNING: the ROM mount is writable." >&2
else
  echo "ROM mount is read-only."
fi

echo
echo "Saves persist in PVC retro-k8s/snes-saves (mounted at /saves)."
echo "Logs: kubectl --context $profile -n retro-k8s logs -f deployment/snes"
echo "Run bash deploy/kubernetes/local/port-forward-frontend.sh and open http://127.0.0.1:18000."
