#!/usr/bin/env bash
# Render or run one disposable Pod against a local, single-node Minikube profile.
set -euo pipefail

profile=${MINIKUBE_PROFILE:-minikube}
uid=${PUID:-$(id -u)}
gid=${PGID:-$(id -g)}
input_gid=${INPUT_GID:-$(stat -c %g /dev/uinput 2>/dev/null || true)}
root=${NODE_INPUT_ROOT:-}
probe_dir=$(cd "$(dirname "$0")" && pwd)
privileged=false
render=false
for arg in "$@"; do
  case "$arg" in
    --render) render=true ;;
    --privileged) privileged=true ;;
    *) echo "Usage: $0 [--render] [--privileged]" >&2; exit 2 ;;
  esac
done
[[ $uid =~ ^[1-9][0-9]*$ && $gid =~ ^(0|[1-9][0-9]*)$ && $input_gid =~ ^(0|[1-9][0-9]*)$ ]] ||
  { echo "Set numeric PUID (nonzero), PGID and INPUT_GID." >&2; exit 2; }
[[ -z $root || $root =~ ^(/[a-zA-Z0-9_-]+)+$ ]] ||
  { echo "NODE_INPUT_ROOT must be an absolute node directory, e.g. /mnt/retro-input." >&2; exit 2; }

manifest() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  generateName: retro-input-probe-
  labels:
    app: retro-input-probe
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 90
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: $uid
    runAsGroup: $gid
    supplementalGroups: [$input_gid]
  containers:
    - name: probe
      image: retro-k8s-poc/retroarch-input:latest
      imagePullPolicy: Never
      workingDir: /app
      command: ["/opt/venv/bin/python", "-u", "-c"]
      args:
        - |
$(sed 's/^/          /' "$probe_dir/probe.py")
      securityContext:
        privileged: $privileged
      volumeMounts:
        - {name: uinput, mountPath: /dev/uinput}
        - {name: events, mountPath: /dev/input, readOnly: true}
        - {name: udev, mountPath: /run/udev/data, readOnly: true}
  volumes:
    - name: uinput
      hostPath: {path: $root/dev/uinput, type: CharDevice}
    - name: events
      hostPath: {path: $root/dev/input, type: Directory}
    - name: udev
      hostPath: {path: $root/run/udev/data, type: Directory}
EOF
}

if "$render"; then manifest; exit; fi

echo "Host input paths:"
stat -c '%F %a %u:%g %n' /dev/uinput /dev/input /run/udev/data
echo "Checking profile $profile, node input paths rooted at ${root:-/}"
minikube -p "$profile" ssh -- "ls -ld $root/dev/uinput $root/dev/input $root/run/udev/data &&
  test -c $root/dev/uinput && test -d $root/dev/input && test -d $root/run/udev/data"

kube=(kubectl --context "$profile" --namespace default)
echo "Creating probe (privileged=$privileged, uid=$uid, gid=$gid, input group=$input_gid)"
pod=$(manifest | "${kube[@]}" create -f - -o name)
echo "$pod"
trap '"${kube[@]}" delete "$pod" --ignore-not-found --wait=false' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! "${kube[@]}" wait "$pod" --for='jsonpath={.status.containerStatuses[0].state.terminated.exitCode}' --timeout=100s; then
  "${kube[@]}" describe "$pod" >&2
  exit 1
fi
"${kube[@]}" logs "$pod"
code=$("${kube[@]}" get "$pod" -o 'jsonpath={.status.containerStatuses[0].state.terminated.exitCode}')
exit "${code:?missing probe exit status}"
