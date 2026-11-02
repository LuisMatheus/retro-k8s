# retro-k8s-poc

Headless RetroArch sessions that publish RTMP to a single MediaMTX instance,
which serves the streams to browsers over WebRTC.

```
retroarch-snes ──RTMP /snes──┐
                             ├── MediaMTX ── WebRTC ── browser
retroarch-gba  ──RTMP /gba───┘
```

## Layout

```
retro-k8s-poc/
├── Dockerfile            # one shared RetroArch image (both cores)
├── compose.yaml          # MediaMTX + two RetroArch sessions
├── entrypoint.sh         # waits for RTMP, generates per-session config
├── retroarch/rtmp.cfg    # FFmpeg muxer/encoder settings
├── mediamtx/mediamtx.yml
└── saves/
    ├── snes/
    └── gba/
```

ROMs stay outside the project in `~/Documents/games/{snes,gba}`.

## 1. Add ROMs

Put the files here:

```
~/Documents/games/snes/<game>.sfc
~/Documents/games/gba/<game>.gba
```

## 2. Select the ROMs

Copy the example and edit `.env`:

```bash
cp .env.example .env
```

```dotenv
SNES_ROM="Chrono Trigger (USA).sfc"
GBA_ROM="Pokemon - Emerald Version (USA, Europe).gba"

PUID=1000
PGID=1001
```

The filenames are relative to the matching `games/` subdirectory. Quote names
that contain spaces. Set the filename for each session you intend to run.
`PUID`/`PGID` should match your host user (`id -u`, `id -g`).

## 3. Build

```bash
docker compose build
```

This compiles RetroArch `v1.22.2` from source with FFmpeg support and downloads
the Snes9x and mGBA cores for the target architecture: Linux x64 (`amd64`) or
ARM64 (`arm64`). Docker selects the host architecture by default. The first
build takes a while; later builds are cached.

On an Apple Silicon Mac, start Docker Desktop and use its Linux container
backend. The image builds for Linux arm64 natively; Rosetta is not required.
Ensure Docker Desktop can access your `Documents/games` directory.

Check that FFmpeg made it into the binary:

```bash
docker run --rm --entrypoint retroarch \
  retro-k8s-poc/retroarch:latest --features | grep -i ffmpeg
```

You should see `FFmpeg` in the feature list.

## 4. Run

Start MediaMTX plus both sessions:

```bash
docker compose up
```

Or start only one session (for example if you only have the SNES ROM):

```bash
docker compose up mediamtx retroarch-snes
```

Each session waits up to 60 seconds for `mediamtx:1935` before starting, then
runs one RetroArch process with one core and one ROM.

## 5. Watch

Open the built-in MediaMTX reader:

- SNES: <http://localhost:8889/snes>
- GBA:  <http://localhost:8889/gba>

Raw RTMP endpoints (for `ffplay`/`ffprobe`/OBS):

- `rtmp://localhost:1935/snes`
- `rtmp://localhost:1935/gba`

Verify the stream actually contains tracks:

```bash
ffprobe -v error \
  -show_entries stream=codec_type,codec_name,width,height \
  -of default=noprint_wrappers=1 \
  rtmp://localhost:1935/snes
```

Expected: one `h264` video stream and one `aac` audio stream. For the current
ROMs this resolves to 256x224 (SNES) and 240x160 (GBA), both with 44.1 kHz
stereo audio. If `ffprobe` reports no video, see Headless rendering below.

## Saves

- Battery saves: `./saves/snes` and `./saves/gba` (mounted at `/saves`)
- Save states: `./saves/<system>/states`

The containers run as `PUID:PGID` from `.env` (default `1000:1000`), so files
created on the host stay owned by your user. If your IDs differ, update them:

```bash
id -u   # PUID
id -g   # PGID
```

The directories are created automatically and survive `docker compose down`.

## Headless rendering

The sessions run under Xvfb with Mesa software GL (`VIDEO_DRIVER=gl`). Xvfb is
an offscreen X server, not a desktop environment: there is no window manager
and nothing is displayed on the host.

This was chosen after testing `video_driver = "null"`: the null video driver
does not provide an input driver, so RetroArch aborts during video init with
`Cannot initialize input driver`. Keeping Xvfb gives RetroArch a real GL
framebuffer and an input driver, which also makes the recorded stream reliable.

If you want to retry the null experiment, set `VIDEO_DRIVER=null` in
`compose.yaml`. The entrypoint still runs under Xvfb so input can initialize,
but verify the result with `ffprobe` before relying on it.

Audio output is still `AUDIO_DRIVER=null`. RetroArch logs
`failed_to_start_audio_driver`, but core audio samples are pushed to the FFmpeg
recorder independently of the output driver. The AAC track was verified
non-silent (about -25 dB mean) on both sessions. If it is missing on a future
build, a virtual audio backend is the next step.

## LAN access

`mediamtx.yml` advertises `127.0.0.1`, which is enough for a browser on the same
machine. To watch from another device, add the Docker host's LAN IP to
`webrtcAdditionalHosts` and publish the ports on that interface.

## Stop

```bash
docker compose down
```
