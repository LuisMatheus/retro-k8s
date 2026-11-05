# Local development UI and token issuer; no uinput/device access required.
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY services/frontend/server.py /app/server.py
COPY services/frontend/frontend.py /app/frontend.py
COPY services/frontend/browser/ /app/browser/
COPY services/runtimes/retroarch/input-agent/agent/__init__.py services/runtimes/retroarch/input-agent/agent/auth.py /app/agent/
ENV PYTHONUNBUFFERED=1 DEV_HOST=0.0.0.0 DEV_PORT=8000
USER 1000:1000
EXPOSE 8000
CMD ["python3", "/app/server.py"]
