#!/usr/bin/env bash
set -euo pipefail
profile=${MINIKUBE_PROFILE:-minikube}
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait || true
}
trap cleanup EXIT INT TERM
for mapping in 'frontend 18000:8000' 'mediamtx 18889:8889' 'snes-input 18765:8765'; do
  read -r service ports <<< "$mapping"
  kubectl --context "$profile" -n retro-k8s port-forward --address 127.0.0.1 \
    "service/$service" "$ports" &
  pids+=("$!")
done
echo "Open http://127.0.0.1:18000 and press Unmute. Ctrl+C stops forwarding."
wait -n "${pids[@]}"
exit 1
