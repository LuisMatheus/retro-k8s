#!/usr/bin/env bash
# Build and deploy the RetroSession operator into the Minikube pilot.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$repo_root"

profile=${MINIKUBE_PROFILE:-minikube}
namespace=retro-k8s
node_input_root=${NODE_INPUT_ROOT:-/run/retro-k8s-input}
operator_image=${OPERATOR_IMAGE:-retro-k8s-poc/operator:pilot}
session_image=${SESSION_IMAGE:-retro-k8s-poc/retroarch-input:pilot}
local_media_image=${LOCAL_MEDIA_IMAGE:-bluenviron/mediamtx:1}
build=true
load=true
attach=true

usage() {
  cat <<'EOF'
Usage: bootstrap/minikube/deploy-operator.sh [options]

  --no-build     Do not rebuild the operator image
  --no-load      Do not load the operator image into the Minikube profile
  --no-attach    Do not attach host input/ROM paths to the Minikube node
  -h, --help     Show this help

Environment:
  MINIKUBE_PROFILE  Minikube profile (default: minikube)
  OPERATOR_IMAGE    Operator image (default: retro-k8s-poc/operator:pilot)
  SESSION_IMAGE     Default emulator image for sessions
  LOCAL_MEDIA_IMAGE Pod-local MediaMTX image (default: bluenviron/mediamtx:1)
  GAMES_DIR         Shared ROM library root (default: repository games/; ROM_DIR is a legacy alias)
  NODE_INPUT_ROOT   Node hostPath root (default: /run/retro-k8s-input)
  PUID/PGID/INPUT_GID, LOG_LEVEL, MIN_HOLD_MS
                    Session identity and input defaults, read from .env first
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) build=false; shift ;;
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
[[ -n $games_dir ]] || games_dir=$repo_root/games
[[ $games_dir = /* ]] || games_dir=$repo_root/$games_dir
rom_dir=$games_dir

uid=$(from_env_or_file PUID); uid=${uid:-1000}
gid=$(from_env_or_file PGID); gid=${gid:-1001}
input_gid=$(from_env_or_file INPUT_GID)
[[ -n $input_gid ]] || input_gid=$(stat -c %g /dev/uinput 2>/dev/null || true)
log_level=$(from_env_or_file LOG_LEVEL); log_level=${log_level:-INFO}
min_hold=$(from_env_or_file MIN_HOLD_MS); min_hold=${min_hold:-40}

[[ $uid =~ ^[1-9][0-9]*$ ]] || { echo "PUID must be a nonzero number." >&2; exit 1; }
[[ $gid =~ ^[0-9]+$ ]] || { echo "PGID must be a number." >&2; exit 1; }
[[ $input_gid =~ ^[0-9]+$ ]] || { echo "INPUT_GID must be a number." >&2; exit 1; }
[[ $min_hold =~ ^[0-9]+$ ]] || { echo "MIN_HOLD_MS must be a number." >&2; exit 1; }

if $attach; then
  [[ -d $rom_dir ]] || { echo "ROM directory not found: $rom_dir" >&2; exit 1; }
  state=$repo_root/bootstrap/minikube/.node-input-state
  [[ -f $state ]] || state=$repo_root/k8s/local/.node-input-state
  [[ -f $state ]] || state=$repo_root/k8s/snes/.node-input-state
  if [[ -f $state ]]; then
    requested_rom_dir=$(cd "$rom_dir" && pwd)
    # shellcheck disable=SC1090
    source "$state"
    node_input_root=${root:-$node_input_root}
    if [[ -n ${rom_dir:-} && ${rom_dir:-} != "$requested_rom_dir" ]]; then
      echo "Host input is already attached with ROM directory: $rom_dir" >&2
      echo "Stop active sessions, then run bootstrap/minikube/attach-node-input.sh detach and reattach the requested ROM library." >&2
      exit 1
    fi
    echo "Host input is already attached to the Minikube node."
  else
    GAMES_DIR="$rom_dir" ROM_DIR="$rom_dir" NODE_INPUT_ROOT="$node_input_root" MINIKUBE_PROFILE="$profile" \
      "$repo_root/bootstrap/minikube/attach-node-input.sh" attach
  fi
fi

if $build; then
  docker build -t "$operator_image" "$repo_root/services/operator"
fi
docker image inspect "$operator_image" >/dev/null
if $load; then
  minikube -p "$profile" image load --daemon "$operator_image"
  docker image inspect "$local_media_image" >/dev/null || { echo "Local media image not found: $local_media_image" >&2; exit 1; }
  minikube -p "$profile" image load --daemon "$local_media_image"
fi

kubectl --context "$profile" apply -f "$repo_root/services/operator/k8s/default/namespace.yaml" >/dev/null

if kubectl --context "$profile" -n "$namespace" get secret retro-session-secret >/dev/null 2>&1; then
  echo "Using existing Secret $namespace/retro-session-secret"
else
  secret=$(from_env_or_file INPUT_TOKEN_SECRET)
  [[ -n $secret ]] || {
    echo "Set INPUT_TOKEN_SECRET in .env or the environment to create the session Secret." >&2
    exit 1
  }
  kubectl --context "$profile" -n "$namespace" create secret generic retro-session-secret \
    --from-literal=INPUT_TOKEN_SECRET="$secret" >/dev/null
  echo "Created Secret $namespace/retro-session-secret"
fi

# A generated overlay carries the host-specific identity and input paths, so
# config/default stays usable with its checked-in pilot defaults.
overlay=$(mktemp -d "$repo_root/services/operator/k8s/.deploy-XXXXXX")
trap 'rm -rf "$overlay"' EXIT
cat > "$overlay/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../default
patches:
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: retrosession-operator
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: retrosession-operator
      spec:
        template:
          spec:
            containers:
              - name: manager
                image: $operator_image
                args:
                  - --namespace=$namespace
                  - --default-image=$session_image
                  - --local-media-image=$local_media_image
                  - --image-pull-policy=Never
                  - --rom-mount-path=/roms
                  - --node-input-root=$node_input_root
                  - --token-secret=retro-session-secret
                  - --media-service=mediamtx
                  - --media-rtmp-port=1935
                  - --session-uid=$uid
                  - --session-gid=$gid
                  - --input-gid=$input_gid
                  - --agent-port=8765
                  - --default-log-level=$log_level
                  - --default-min-hold-ms=$min_hold
                  - --leader-elect=false
EOF

existed=false
kubectl --context "$profile" -n "$namespace" get deployment/retrosession-operator >/dev/null 2>&1 && existed=true
kubectl --context "$profile" apply -k "$overlay"
kubectl --context "$profile" wait --for=condition=Established \
  crd/retrosessions.retro.k8s --timeout=60s >/dev/null

if $existed; then
  kubectl --context "$profile" -n "$namespace" rollout restart deployment/retrosession-operator >/dev/null
fi
kubectl --context "$profile" -n "$namespace" rollout status \
  deployment/retrosession-operator --timeout=180s

echo
kubectl --context "$profile" -n "$namespace" get deployment/retrosession-operator
echo
echo "Keep the games mount running: MINIKUBE_PROFILE=$profile bash $repo_root/bootstrap/minikube/mount-games.sh"
echo "Keep the saves mount running: MINIKUBE_PROFILE=$profile bash $repo_root/bootstrap/minikube/mount-saves.sh"
echo "Apply a session with:"
echo "  kubectl --context $profile apply -k $repo_root/bootstrap/minikube/storage/snes"
echo "  kubectl --context $profile apply -f $repo_root/services/operator/samples/snes/retrosession-snes.yaml"
echo "Then run: bash $repo_root/services/operator/verify-snes-session.sh"
