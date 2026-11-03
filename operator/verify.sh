#!/usr/bin/env bash
# Verify the RetroSession operator against the Minikube pilot:
# create, readiness/endpoints, repair, save-PVC retention, and PVC reuse.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
profile=${MINIKUBE_PROFILE:-minikube}
namespace=retro-k8s
session=chrono-trigger
claim=chrono-trigger-saves
pad="Retro-K8s Pad $session"
timeout=${VERIFY_TIMEOUT:-300}
kube=(kubectl --context "$profile" -n "$namespace")

fail() {
  echo "FAIL: $*" >&2
  "${kube[@]}" get retrosession "$session" -o yaml >&2 2>/dev/null || true
  "${kube[@]}" get pods -o wide >&2 2>/dev/null || true
  exit 1
}

pass() { echo "PASS: $*"; }

field() {
  "${kube[@]}" get retrosession "$session" -o jsonpath="$1" 2>/dev/null || true
}

wait_ready() {
  local deadline=$((SECONDS + timeout)) phase reason message
  while ((SECONDS < deadline)); do
    phase=$(field '{.status.phase}')
    case "$phase" in
      Ready) return 0 ;;
      Failed)
        reason=$(field '{.status.reason}')
        message=$(field '{.status.message}')
        fail "session is Failed: $reason: $message"
        ;;
    esac
    sleep 2
  done
  fail "session did not become Ready within ${timeout}s"
}

running_pod() {
  "${kube[@]}" get pods -l "retro.k8s/session=$session" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

"${kube[@]}" rollout status deployment/retrosession-operator --timeout=120s >/dev/null

"${kube[@]}" apply -f "$repo_root/deploy/kubernetes/samples/snes/chrono-trigger-saves.yaml" >/dev/null

# Start from a clean session but keep the save claim: this also makes a re-run
# prove that a previous run's saves are reused.
"${kube[@]}" delete retrosession "$session" --ignore-not-found --wait=true >/dev/null
for _ in $(seq 1 60); do
  if ! "${kube[@]}" get deployment "$session" >/dev/null 2>&1 &&
     ! "${kube[@]}" get service "$session-input" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

"${kube[@]}" apply -f "$repo_root/deploy/kubernetes/samples/snes/retrosession-snes.yaml" >/dev/null
wait_ready
pass "session $session is Ready"

generation=$(field '{.metadata.generation}')
observed=$(field '{.status.observedGeneration}')
[[ -n $generation && $generation == "$observed" ]] ||
  fail "observedGeneration $observed does not match generation $generation"

[[ $(field '{.status.deploymentName}') == "$session" ]] ||
  fail "status.deploymentName is not $session"
[[ $(field '{.status.serviceName}') == "$session-input" ]] ||
  fail "status.serviceName is not $session-input"
[[ $(field '{.status.saveClaimName}') == "$claim" ]] ||
  fail "status.saveClaimName is not $claim"
[[ $(field '{.status.endpoints.inputService}') == "$session-input" ]] ||
  fail "inputService endpoint is wrong"
[[ $(field '{.status.endpoints.inputPort}') == "8765" ]] ||
  fail "inputPort endpoint is wrong"
[[ $(field '{.status.endpoints.inputPath}') == "/sessions/$session/input" ]] ||
  fail "inputPath endpoint is wrong"
[[ $(field '{.status.endpoints.streamPath}') == "$session" ]] ||
  fail "streamPath endpoint is wrong"
[[ $(field '{.status.endpoints.rtmpURL}') == "rtmp://mediamtx:1935/raw/$session" ]] ||
  fail "rtmpURL endpoint is wrong"
[[ $(field '{.status.endpoints.whepPath}') == "/$session/whep" ]] ||
  fail "whepPath endpoint is wrong"
pass "status reports deployment, service, save claim and frontend endpoints"

[[ $("${kube[@]}" get deployment "$session" -o jsonpath='{.spec.replicas}') == 1 ]] ||
  fail "session Deployment does not have one replica"
[[ $("${kube[@]}" get deployment "$session" -o jsonpath='{.spec.strategy.type}') == Recreate ]] ||
  fail "session Deployment does not use the Recreate strategy"
[[ $("${kube[@]}" get deployment "$session" -o jsonpath='{.metadata.ownerReferences[0].name}') == "$session" ]] ||
  fail "session Deployment is not owned by the RetroSession"
[[ $("${kube[@]}" get service "$session-input" -o jsonpath='{.spec.ports[0].port}') == 8765 ]] ||
  fail "input Service does not expose port 8765"
[[ -n $("${kube[@]}" get endpoints "$session-input" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true) ]] ||
  fail "input Service has no ready endpoints"
pass "Deployment and input Service are owned by the session and select a ready Pod"

pod=$(running_pod)
[[ -n $pod ]] || fail "no running session Pod found"
logs=""
for _ in $(seq 1 60); do
  logs=$("${kube[@]}" logs "$pod" -c session --tail=200 2>/dev/null || true)
  grep -q "Starting RetroArch" <<<"$logs" && break
  sleep 1
done
grep -q "Starting RetroArch" <<<"$logs" ||
  fail "RetroArch did not start in Pod $pod"
grep -q "ROM: /roms/snes/Chrono Trigger (USA).sfc" <<<"$logs" ||
  fail "Pod $pod did not use the expected ROM path"
pass "RetroArch started from the read-only ROM library"

"${kube[@]}" exec "$pod" -- grep -F "$pad" /proc/bus/input/devices >/dev/null ||
  fail "virtual pad '$pad' is missing"
"${kube[@]}" exec "$pod" -- grep -F "input_player1_reserved_device = \"$pad\"" \
  /tmp/session.cfg >/dev/null ||
  fail "RetroArch config does not reserve '$pad' for player 1"
pass "virtual pad '$pad' exists and is reserved for player 1"
grep -F "Autoconf] $pad configured in port 1." <<<"$logs" >/dev/null ||
  fail "RetroArch did not configure '$pad' in player port 1"
pass "RetroArch configured the session pad in player port 1"

if "${kube[@]}" exec "$pod" -- sh -c 'touch /roms/.write-test' >/dev/null 2>&1; then
  "${kube[@]}" exec "$pod" -- rm -f /roms/.write-test >/dev/null 2>&1 || true
  fail "the ROM mount is writable"
fi
pass "the ROM mount rejects writes"

marker="verify-$(date +%s)-$$"
"${kube[@]}" exec "$pod" -- sh -c "printf '%s' '$marker' > /saves/.verify-marker"

"${kube[@]}" delete deployment "$session" --wait=true >/dev/null
for _ in $(seq 1 60); do
  "${kube[@]}" get deployment "$session" >/dev/null 2>&1 && break
  sleep 1
done
"${kube[@]}" get deployment "$session" >/dev/null 2>&1 ||
  fail "operator did not repair the deleted Deployment"
"${kube[@]}" rollout status deployment "$session" --timeout=240s >/dev/null
repaired_pod=$(running_pod)
[[ -n $repaired_pod ]] || fail "repaired session has no running Pod"
actual=$("${kube[@]}" exec "$repaired_pod" -- cat /saves/.verify-marker)
[[ $actual == "$marker" ]] ||
  fail "save marker did not survive Deployment repair"
pass "operator repaired the deleted Deployment; save content survived"

"${kube[@]}" delete retrosession "$session" --wait=true >/dev/null
for _ in $(seq 1 60); do
  if ! "${kube[@]}" get deployment "$session" >/dev/null 2>&1 &&
     ! "${kube[@]}" get service "$session-input" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
"${kube[@]}" get deployment "$session" >/dev/null 2>&1 &&
  fail "session Deployment survived RetroSession deletion"
"${kube[@]}" get service "$session-input" >/dev/null 2>&1 &&
  fail "input Service survived RetroSession deletion"
"${kube[@]}" get pvc "$claim" >/dev/null 2>&1 ||
  fail "save PVC $claim was deleted with the session"
pass "session resources were garbage-collected; save PVC $claim was retained"

"${kube[@]}" apply -f "$repo_root/deploy/kubernetes/samples/snes/retrosession-snes.yaml" >/dev/null
wait_ready
reused_pod=$(running_pod)
[[ -n $reused_pod ]] || fail "recreated session has no running Pod"
reused_logs=$("${kube[@]}" logs "$reused_pod" -c session)
grep -F "Autoconf] $pad configured in port 1." <<<"$reused_logs" >/dev/null ||
  fail "recreated session did not configure '$pad' in player port 1"
pass "recreated session configured its pad in player port 1"
actual=$("${kube[@]}" exec "$reused_pod" -- cat /saves/.verify-marker)
[[ $actual == "$marker" ]] ||
  fail "recreated session did not reuse the existing save content"
"${kube[@]}" exec "$reused_pod" -- rm -f /saves/.verify-marker
pass "recreated session reused save PVC $claim and its content"

echo
echo "Session $session is Ready:"
"${kube[@]}" get retrosession "$session"
echo
echo "Stop it with:"
echo "  kubectl --context $profile -n $namespace delete retrosession $session"
echo "The save PVC $claim is retained."
