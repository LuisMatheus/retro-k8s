#!/usr/bin/env bash
# Start the local cluster without changing the current kubectl context.
set -euo pipefail
profile=${MINIKUBE_PROFILE:-minikube}
exec minikube start -p "$profile" --driver=docker --keep-context "$@"
