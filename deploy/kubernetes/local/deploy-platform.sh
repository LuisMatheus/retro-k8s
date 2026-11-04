#!/usr/bin/env bash
# Install the shared local platform with a browser-reachable ICE address.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
k8s_dir=$(cd "$script_dir/.." && pwd)
profile=${MINIKUBE_PROFILE:-minikube}
host=$(minikube -p "$profile" ip)
overlay=$(mktemp -d "$k8s_dir/.platform-XXXXXX")
trap 'rm -rf "$overlay"' EXIT
cat > "$overlay/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../platform
configMapGenerator:
  - name: platform-settings
    behavior: replace
    literals:
      - WEBRTC_HOST=$host
generatorOptions:
  disableNameSuffixHash: true
EOF
kubectl --context "$profile" apply -k "$overlay"
echo "Shared platform applied. The frontend requires the retro-session-secret created by deploy/kubernetes/local/deploy-operator.sh."
