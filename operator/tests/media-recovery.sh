#!/usr/bin/env bash
set -euo pipefail
media_image=${MEDIA_IMAGE:-bluenviron/mediamtx:1}
ffmpeg_image=${FFMPEG_IMAGE:-retro-k8s-poc/frontend:pilot}
p="retro-recovery-$$"
network="$p-net"
cleanup() { docker rm -f "$p-publisher" "$p-relay" "$p-local" "$p-shared" >/dev/null 2>&1 || true; docker network rm "$network" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create "$network" >/dev/null
docker run -d --name "$p-shared" --network "$network" --network-alias shared "$media_image" >/dev/null
docker run -d --name "$p-local" --network "$network" -e MTX_RTMPADDRESS=127.0.0.1:1935 -e MTX_RTSP=no -e MTX_WEBRTC=no -e MTX_HLS=no -e MTX_SRT=no "$media_image" >/dev/null
docker run -d --name "$p-publisher" --network "container:$p-local" --entrypoint /bin/sh "$ffmpeg_image" -c 'sleep 2; exec ffmpeg -nostdin -loglevel warning -re -f lavfi -i testsrc=size=240x160:rate=15 -f lavfi -i sine=frequency=440 -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -c:a aac -f flv rtmp://127.0.0.1:1935/raw/test' >/dev/null
docker run -d --name "$p-relay" --network "container:$p-local" --entrypoint /bin/sh "$ffmpeg_image" -c 'while true; do ffmpeg -nostdin -loglevel warning -i rtmp://127.0.0.1:1935/raw/test -map 0:v:0 -map 0:a:0 -c:v copy -c:a libopus -ar 48000 -ac 2 -f rtsp -rtsp_transport tcp rtsp://shared:8554/test; sleep 2; done' >/dev/null
readiness() {
  docker exec -i "$p-relay" /bin/sh -s >/dev/null 2>&1 <<'PROBE'
python3 -c 'import socket; socket.create_connection(("127.0.0.1", 1935), timeout=1).close()' && streams=$(timeout 4 ffprobe -v error -rtsp_transport tcp -analyzeduration 0 -probesize 32 -show_entries stream=codec_type -of csv=p=0 rtsp://shared:8554/test) && printf '%s\n' "$streams" | grep -qx video && printf '%s\n' "$streams" | grep -qx audio
PROBE
}
probe() {
  local result
  for i in {1..15}; do
    result=$(docker run --rm --network "$network" --entrypoint /bin/sh "$ffmpeg_image" -c 'timeout 6 ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name -of csv=p=0 rtsp://shared:8554/test' 2>/dev/null || true)
    if [[ $result == *h264* && $result == *opus* ]] && readiness; then return 0; fi
    sleep 2
  done
  docker logs --tail 20 "$p-relay" >&2
  return 1
}
probe
echo 'PASS: shared server published H.264 and Opus before restart'
before=$(docker inspect -f '{{.State.StartedAt}}' "$p-publisher")
docker stop "$p-shared" >/dev/null
if readiness; then
  echo 'FAIL: readiness stayed true while shared MediaMTX was stopped' >&2
  exit 1
fi
echo 'PASS: readiness fails when shared media is unavailable'
docker start "$p-shared" >/dev/null
probe
after=$(docker inspect -f '{{.State.StartedAt}} {{.State.Running}}' "$p-publisher")
[[ $after == "$before true" ]]
echo 'PASS: H.264 and Opus recovered after shared server restart; publisher stayed running'
docker stop "$p-local" >/dev/null
if readiness; then
  echo 'FAIL: readiness stayed true while Pod-local MediaMTX was stopped' >&2
  exit 1
fi
echo 'PASS: readiness fails when Pod-local media is unavailable'
