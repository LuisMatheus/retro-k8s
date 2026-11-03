FROM ubuntu:24.04 AS retroarch-base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    unzip \
    pkg-config \
    ca-certificates \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libavdevice-dev \
    libswresample-dev \
    libswscale-dev \
    libx264-dev \
    libasound2-dev \
    libudev-dev \
    libgl1-mesa-dev \
    libgl1-mesa-dri \
    libglx-mesa0 \
    libx11-xcb-dev \
    libsdl2-dev \
    xvfb \
    xauth \
    x11-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

ARG RETROARCH_REF=v1.22.2

RUN git clone --depth 1 --branch "${RETROARCH_REF}" \
    https://github.com/libretro/RetroArch.git

WORKDIR /tmp/RetroArch

# --enable-ffmpeg is what gives us the FFmpeg recording/streaming driver.
RUN ./configure \
    --enable-ffmpeg \
    --enable-sdl2 \
    --disable-vulkan \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# BuildKit supplies TARGETARCH; older builders can use the image's native
# Debian architecture instead. Never assume an unspecified target is amd64.
ARG TARGETARCH
RUN ARCH="${TARGETARCH:-$(dpkg --print-architecture)}" \
    && case "$ARCH" in \
      amd64) LIBRETRO_ARCH="x86_64" ;; \
      arm64) LIBRETRO_ARCH="aarch64" ;; \
      *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
    esac \
    && mkdir -p /opt/retroarch/cores \
    && curl -fL \
      "https://buildbot.libretro.com/nightly/linux/${LIBRETRO_ARCH}/latest/snes9x_libretro.so.zip" \
      -o /tmp/snes9x.zip \
    && curl -fL \
      "https://buildbot.libretro.com/nightly/linux/${LIBRETRO_ARCH}/latest/mgba_libretro.so.zip" \
      -o /tmp/mgba.zip \
    && unzip /tmp/snes9x.zip -d /opt/retroarch/cores \
    && unzip /tmp/mgba.zip -d /opt/retroarch/cores \
    && rm -f /tmp/*.zip

RUN mkdir -p /saves/states /bios /tmp/.X11-unix \
    && chmod 1777 /tmp/.X11-unix

COPY runtimes/retroarch/entrypoint.sh /usr/local/bin/retroarch-entrypoint
COPY runtimes/retroarch/rtmp.cfg /etc/retroarch/rtmp.cfg

RUN chmod +x /usr/local/bin/retroarch-entrypoint

ENV CORE_PATH=/opt/retroarch/cores \
    SAVE_PATH=/saves \
    VIDEO_DRIVER=gl \
    AUDIO_DRIVER=null \
    DISPLAY=:99 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    HOME=/tmp/retroarch

ENTRYPOINT ["/usr/local/bin/retroarch-entrypoint"]

# Session image: emulator and input agent share the same Linux input devices.
FROM retroarch-base AS retroarch-input
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-evdev \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv --system-site-packages /opt/venv
COPY input-agent/requirements.txt /tmp/input-requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/input-requirements.txt
WORKDIR /app
COPY input-agent/agent/ /app/agent/
COPY input-agent/input-wrapper.sh /input-wrapper.sh
RUN chmod +x /input-wrapper.sh
ENV PATH="/opt/venv/bin:${PATH}" PYTHONUNBUFFERED=1 \
    ORIGINAL_ENTRYPOINT=/usr/local/bin/retroarch-entrypoint INPUT_AGENT=1
ENTRYPOINT ["/input-wrapper.sh"]
