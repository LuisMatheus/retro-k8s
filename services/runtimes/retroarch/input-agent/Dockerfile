# Wraps your existing retro-k8s-poc/retroarch image with the input agent.
# Assumes a Debian/Ubuntu base. Build the RetroArch base image first.
ARG BASE_IMAGE=retro-k8s-poc/retroarch:latest
FROM ${BASE_IMAGE}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-evdev \
    && rm -rf /var/lib/apt/lists/*

# --system-site-packages so the apt-provided evdev (no compiler needed) is visible
RUN python3 -m venv --system-site-packages /opt/venv
COPY services/runtimes/retroarch/input-agent/requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /app
COPY services/runtimes/retroarch/input-agent/agent/ /app/agent/
COPY services/runtimes/retroarch/start-session.sh /start-session.sh
RUN chmod +x /start-session.sh

ENV PATH="/opt/venv/bin:${PATH}" PYTHONUNBUFFERED=1 \
    ORIGINAL_ENTRYPOINT=/usr/local/bin/start-retroarch.sh INPUT_AGENT=1
ENTRYPOINT ["/start-session.sh"]
