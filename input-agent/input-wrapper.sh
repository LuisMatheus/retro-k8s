#!/usr/bin/env bash
# Starts the input agent, waits for the virtual pad (and its host udev metadata),
# then runs the image's ORIGINAL entrypoint (which launches Xvfb + RetroArch).
set -euo pipefail

: "${SESSION_ID:?SESSION_ID required}"
: "${INPUT_TOKEN_SECRET:?INPUT_TOKEN_SECRET required}"
: "${ORIGINAL_ENTRYPOINT:?set ORIGINAL_ENTRYPOINT to the base image entrypoint}"
DEVICE_NAME="${DEVICE_NAME:-Retro-K8s Virtual Gamepad}"
export DEVICE_NAME
if [[ -n "${INPUT_SOURCE_DIR:-}" && "$INPUT_SOURCE_DIR" != "/dev/input" ]]; then
  export INPUT_DEVICE_SYSNAME_FILE=/tmp/retro-input-sysname
  rm -f "$INPUT_DEVICE_SYSNAME_FILE"
fi

cd /app
python3 -m agent.main &
AGENT_PID=$!
APP_PID=""
cleanup() {
  trap - EXIT TERM INT
  kill "$AGENT_PID" ${APP_PID:+"$APP_PID"} 2>/dev/null || true
  wait "$AGENT_PID" ${APP_PID:+"$APP_PID"} 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

for _ in $(seq 1 50); do
  if [[ -n "${INPUT_DEVICE_SYSNAME_FILE:-}" ]]; then
    [[ -s "$INPUT_DEVICE_SYSNAME_FILE" ]] && break
  else
    grep -qF "\"$DEVICE_NAME\"" /proc/bus/input/devices 2>/dev/null && break
  fi
  kill -0 "$AGENT_PID" 2>/dev/null || { echo "input agent exited (is /dev/uinput usable?)" >&2; exit 1; }
  sleep 0.2
done

if { [[ -n "${INPUT_DEVICE_SYSNAME_FILE:-}" ]] && [[ ! -s "$INPUT_DEVICE_SYSNAME_FILE" ]]; } ||
   { [[ -z "${INPUT_DEVICE_SYSNAME_FILE:-}" ]] && ! grep -qF "\"$DEVICE_NAME\"" /proc/bus/input/devices; }; then
  echo "Timed out waiting for virtual gamepad '$DEVICE_NAME'" >&2
  exit 1
fi

# RetroArch's udev driver only lists devices the HOST udevd tagged ID_INPUT_JOYSTICK=1
# (visible via the /run/udev mount). Wait for that metadata before starting RetroArch.
EVENT=""
if [[ -n "${INPUT_DEVICE_SYSNAME_FILE:-}" ]]; then
  SYSNAME=$(cat "$INPUT_DEVICE_SYSNAME_FILE")
  [[ "$SYSNAME" =~ ^input[0-9]+$ ]] || { echo "Invalid uinput sysname" >&2; exit 1; }
  for d in "/sys/devices/virtual/input/$SYSNAME"/event*; do
    [[ -e "$d" ]] && EVENT=$(basename "$d") && break
  done
else
  for d in /sys/class/input/event*; do
    if [[ "$(cat "$d/device/name" 2>/dev/null)" == "$DEVICE_NAME" ]]; then EVENT=$(basename "$d"); break; fi
  done
fi
if [[ -n "$EVENT" && -r "/sys/class/input/$EVENT/dev" ]]; then
  INPUT_SOURCE_DIR="${INPUT_SOURCE_DIR:-/dev/input}"
  if [[ ! -r "$INPUT_SOURCE_DIR/$EVENT" ]]; then
    echo "Virtual gamepad $INPUT_SOURCE_DIR/$EVENT is not readable; check device mounts and INPUT_GID" >&2
    exit 1
  fi
  # When the session supplies a private /dev/input, expose only its own pad.
  if [[ "$INPUT_SOURCE_DIR" != "/dev/input" ]]; then
    find /dev/input -mindepth 1 -maxdepth 1 -delete
    ln -s "$INPUT_SOURCE_DIR/$EVENT" "/dev/input/$EVENT"
  fi
  DEVNUM=$(cat "/sys/class/input/$EVENT/dev")
  for _ in $(seq 1 50); do
    grep -qs 'ID_INPUT_JOYSTICK=1' "/run/udev/data/c${DEVNUM}" && break
    sleep 0.1
  done
  grep -qs 'ID_INPUT_JOYSTICK=1' "/run/udev/data/c${DEVNUM}" \
    || echo "WARNING: no udev metadata for $EVENT (c${DEVNUM}); is /run/udev mounted and udevd running on the host?" >&2
else
  echo "Could not locate event node for '$DEVICE_NAME'" >&2
  exit 1
fi

read -r -a ORIG <<< "$ORIGINAL_ENTRYPOINT"
"${ORIG[@]}" "$@" &
APP_PID=$!

# Preserve the first child's exit status and terminate its sibling on exit.
status=0
wait -n "$AGENT_PID" "$APP_PID" || status=$?
# An agent that exits while the emulator is running is a session failure.
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
  [[ "$status" != 0 ]] || status=1
fi
exit "$status"
