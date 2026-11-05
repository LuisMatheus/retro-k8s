#!/usr/bin/env bash
# Keep this foreground process running while local game volumes are in use.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
profile=${MINIKUBE_PROFILE:-minikube}
games_dir=${GAMES_DIR:-${ROM_DIR:-}}
if [[ -z $games_dir && -f $repo_root/.env ]]; then
  line=$(grep -E '^[[:space:]]*GAMES_DIR=' "$repo_root/.env" | tail -n 1 || true)
  [[ -n $line ]] || line=$(grep -E '^[[:space:]]*ROM_DIR=' "$repo_root/.env" | tail -n 1 || true)
  games_dir=${line#*=}
  games_dir=${games_dir%$'\r'}
  if [[ $games_dir == \"*\" && $games_dir == *\" ]] || [[ $games_dir == \'*\' && $games_dir == *\' ]]; then
    games_dir=${games_dir:1:${#games_dir}-2}
  fi
fi
games_dir=${games_dir:-$repo_root/games}
[[ $games_dir = /* ]] || games_dir=$repo_root/$games_dir
[[ -d $games_dir ]] || {
  echo "Game directory not found: $games_dir" >&2
  exit 1
}
echo "Mounting $games_dir into $profile; keep this terminal open."
exec minikube -p "$profile" mount "$games_dir:/mnt/retro-k8s-games"
