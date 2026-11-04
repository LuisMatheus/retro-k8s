# Local development UI and token issuer; no uinput/device access required.
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY frontend/server.py /app/server.py
COPY frontend/frontend.py /app/frontend.py
COPY frontend/browser/ /app/browser/
COPY input-agent/agent/__init__.py input-agent/agent/auth.py /app/agent/
ENV PYTHONUNBUFFERED=1 DEV_HOST=0.0.0.0 DEV_PORT=8000
USER 1000:1000
EXPOSE 8000
CMD ["python3", "/app/server.py"]
