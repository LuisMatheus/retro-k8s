#!/usr/bin/env bash
# Check the pilot's pass criteria: game starts, pad is selected, ROM is
# read-only, and the save PVC survives Pod replacement.
set -euo pipefail

profile=${MINIKUBE_PROFILE:-minikube}
pad_name=${PAD_NAME:-Retro-K8s Pad snes-k8s}
kube=(kubectl --context "$profile" -n retro-k8s)

"${kube[@]}" rollout status deployment/snes --timeout=240s >/dev/null
pod=$("${kube[@]}" get pods -l app.kubernetes.io/name=snes \
  -o jsonpath='{.items[0].metadata.name}')
echo "Checking pod $pod"

logs=""
for _ in $(seq 1 60); do
  logs=$("${kube[@]}" logs "$pod" 2>/dev/null || true)
  grep -q "Starting RetroArch" <<<"$logs" && break
  sleep 1
done
grep -q "Starting RetroArch" <<<"$logs" || {
  echo "FAIL: RetroArch did not start." >&2
  tail -n 80 <<<"$logs" >&2
  exit 1
}
grep -q "ROM: /roms/" <<<"$logs" || { echo "FAIL: ROM path was not used." >&2; exit 1; }
echo "PASS: game process started with the read-only ROM mount."

"${kube[@]}" exec "$pod" -- grep -F "$pad_name" /proc/bus/input/devices >/dev/null ||
  { echo "FAIL: virtual pad '$pad_name' is missing." >&2; exit 1; }
"${kube[@]}" exec "$pod" -- grep -F "input_player1_reserved_device = \"$pad_name\"" \
  /tmp/session.cfg >/dev/null ||
  { echo "FAIL: RetroArch config does not reserve the pilot pad." >&2; exit 1; }
if grep -Eq "Autodetect|joypad|udev" <<<"$logs"; then
  grep -E "Autodetect|joypad|udev" <<<"$logs" | tail -n 10
fi
echo "PASS: virtual pad '$pad_name' exists and is reserved for player 1."

if "${kube[@]}" exec "$pod" -- sh -c 'touch /roms/.write-test' >/dev/null 2>&1; then
  "${kube[@]}" exec "$pod" -- rm -f /roms/.write-test >/dev/null 2>&1 || true
  echo "FAIL: the ROM mount is writable." >&2
  exit 1
fi
echo "PASS: the ROM mount rejects writes."

marker="verify-$(date +%s)-$$"
"${kube[@]}" exec "$pod" -- sh -c "printf '%s' '$marker' > /saves/.verify-marker"
"${kube[@]}" delete pod "$pod" --wait=true >/dev/null
"${kube[@]}" rollout status deployment/snes --timeout=240s >/dev/null
new_pod=$("${kube[@]}" get pods -l app.kubernetes.io/name=snes \
  -o jsonpath='{.items[0].metadata.name}')
actual=$("${kube[@]}" exec "$new_pod" -- cat /saves/.verify-marker)
[[ $actual == "$marker" ]] || {
  echo "FAIL: save marker did not survive Pod replacement ($new_pod)." >&2
  exit 1
}
"${kube[@]}" exec "$new_pod" -- rm -f /saves/.verify-marker
echo "PASS: save PVC content survived Pod replacement ($pod -> $new_pod)."
