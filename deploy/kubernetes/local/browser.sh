#!/usr/bin/env bash
set -euo pipefail
profile=${MINIKUBE_PROFILE:-minikube}
echo "Forwarding the frontend. MediaMTX media uses the Minikube NodePort 30189/UDP."
kubectl --context "$profile" -n retro-k8s port-forward --address 127.0.0.1 \
  service/frontend 18000:8000
