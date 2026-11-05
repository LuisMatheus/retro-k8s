#!/usr/bin/env bash
# Keep this foreground process running while local save volumes are in use.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
profile=${MINIKUBE_PROFILE:-minikube}
mkdir -p "$repo_root/saves/snes" "$repo_root/saves/gba"
echo "Mounting $repo_root/saves into $profile; keep this terminal open."
exec minikube -p "$profile" mount "$repo_root/saves:/mnt/retro-k8s-saves"
