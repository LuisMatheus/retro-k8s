#!/usr/bin/env bash
set -euo pipefail

: "${CORE:?CORE is required}"
: "${ROM_PATH:?ROM_PATH is required}"
: "${STREAM_URL:?STREAM_URL is required}"

: "${CORE_PATH:=/opt/retroarch/cores}"
: "${SAVE_PATH:=/saves}"
: "${VIDEO_DRIVER:=gl}"
: "${AUDIO_DRIVER:=null}"
: "${RTMP_HOST:=mediamtx}"
: "${RTMP_PORT:=1935}"
: "${HOME:=/tmp/retroarch}"

CORE_FILE="${CORE_PATH}/${CORE}_libretro.so"

if [[ ! -f "$CORE_FILE" ]]; then
    echo "Core not found: $CORE_FILE" >&2
    exit 1
fi

if [[ ! -f "$ROM_PATH" ]]; then
    echo "ROM not found: $ROM_PATH" >&2
    echo "Check the ROM filename in .env and the /roms volume mount." >&2
    exit 1
fi

mkdir -p "$SAVE_PATH/states" "$HOME"

cat > /tmp/session.cfg <<EOF
video_driver = "$VIDEO_DRIVER"
video_fullscreen = "true"
video_windowed_fullscreen = "false"
video_vsync = "false"
audio_driver = "$AUDIO_DRIVER"
audio_sync = "true"
fps_show = "${SHOW_FPS:-false}"

record_driver = "ffmpeg"

libretro_directory = "$CORE_PATH"
system_directory = "/bios"

savefile_directory = "$SAVE_PATH"
savestate_directory = "$SAVE_PATH/states"

config_save_on_exit = "false"
EOF

# --- Browser input (uinput virtual gamepad created by the input agent) ---
# Enabled with INPUT_AGENT=1. RetroArch was built from source, so no autoconfig
# profiles are installed: generate one that matches the agent's virtual pad.
if [[ "${INPUT_AGENT:-0}" == "1" ]]; then
    : "${DEVICE_NAME:?DEVICE_NAME is required when INPUT_AGENT=1}"
    AUTOCONFIG_DIR=/tmp/autoconfig
    mkdir -p "$AUTOCONFIG_DIR/udev"

    # Button index = position of the key code in sorted order (udev driver):
    # south=0 east=1 north=2 west=3 L=4 R=5 select=6 start=7. D-pad is a hat.
    cat > "$AUTOCONFIG_DIR/udev/${DEVICE_NAME}.cfg" <<PADEOF
input_driver = "udev"
input_device = "${DEVICE_NAME}"
input_b_btn = "0"
input_a_btn = "1"
input_x_btn = "2"
input_y_btn = "3"
input_l_btn = "4"
input_r_btn = "5"
input_select_btn = "6"
input_start_btn = "7"
input_up_btn = "h0up"
input_down_btn = "h0down"
input_left_btn = "h0left"
input_right_btn = "h0right"
input_l_x_plus_axis = "+0"
input_l_x_minus_axis = "-0"
input_l_y_plus_axis = "+1"
input_l_y_minus_axis = "-1"
input_r_x_plus_axis = "+2"
input_r_x_minus_axis = "-2"
input_r_y_plus_axis = "+3"
input_r_y_minus_axis = "-3"
PADEOF

    cat >> /tmp/session.cfg <<CFGEOF

input_driver = "udev"
input_joypad_driver = "udev"
input_autodetect_enable = "true"
joypad_autoconfig_dir = "$AUTOCONFIG_DIR"
input_max_users = "1"
input_player1_reserved_device = "$DEVICE_NAME"
input_player1_device_reservation_type = "2"
# No window manager under Xvfb: without this RetroArch can pause as "inactive"
pause_nonactive = "false"
CFGEOF
fi

echo "Waiting for RTMP endpoint ${RTMP_HOST}:${RTMP_PORT}..."
for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/${RTMP_HOST}/${RTMP_PORT}") 2>/dev/null; then
        break
    fi
    sleep 1
done

if ! (exec 3<>"/dev/tcp/${RTMP_HOST}/${RTMP_PORT}") 2>/dev/null; then
    echo "MediaMTX is not reachable at ${RTMP_HOST}:${RTMP_PORT}" >&2
    exit 1
fi

# Start an offscreen X server. xvfb-run hangs when it is PID 1 in a
# container, so start Xvfb directly and exec RetroArch on top of it.
DISPLAY_NUM=99
while [[ -e "/tmp/.X${DISPLAY_NUM}-lock" ]]; do
    DISPLAY_NUM=$((DISPLAY_NUM + 1))
done
export DISPLAY=":${DISPLAY_NUM}"

Xvfb "$DISPLAY" -screen 0 1280x720x24 +extension GLX -nolisten tcp \
    >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!

for _ in $(seq 1 50); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "Xvfb failed to start:" >&2
    cat /tmp/xvfb.log >&2
    exit 1
fi

echo "Starting RetroArch"
echo "Core: $CORE_FILE"
echo "ROM: $ROM_PATH"
echo "Stream: $STREAM_URL"

exec retroarch \
    --verbose \
    --config /tmp/session.cfg \
    --libretro "$CORE_FILE" \
    --record "$STREAM_URL" \
    --recordconfig /etc/retroarch/rtmp.cfg \
    "$ROM_PATH"
