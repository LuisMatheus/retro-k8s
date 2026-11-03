#!/usr/bin/env bash
# Stop the pilot. Saves are kept unless --delete-data is passed.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
profile=${MINIKUBE_PROFILE:-minikube}
delete_data=false
case "${1:-}" in
  "") ;;
  --delete-data) delete_data=true ;;
  *) echo "Usage: $0 [--delete-data]" >&2; exit 2 ;;
esac

kube=(kubectl --context "$profile" -n retro-k8s)
"${kube[@]}" delete \
  deployment/mediamtx deployment/frontend deployment/snes deployment/audio-relay \
  service/mediamtx service/mediamtx-ice service/frontend service/snes-input \
  configmap/mediamtx-config configmap/snes-session \
  secret/retro-session-secret \
  --ignore-not-found

"${kube[@]}" wait --for=delete pod -l app.kubernetes.io/part-of=retro-k8s \
  --timeout=60s >/dev/null 2>&1 || true

if bash "$script_dir/../../kubernetes/local/attach-node-input.sh" detach; then
  :
else
  echo "Could not detach all node input mounts; inspect the node before retrying." >&2
fi

if $delete_data; then
  kubectl --context "$profile" delete namespace retro-k8s --ignore-not-found
  rm -rf "$script_dir/generated"
  echo "Deleted the namespace, save PVC and generated files."
else
  echo "Kept PVC retro-k8s/snes-saves and the namespace."
fi
