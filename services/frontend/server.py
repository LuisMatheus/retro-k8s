#!/usr/bin/env python3
"""Serve the browser UI, discover sessions and mint short-lived input tokens.

SESSION_SOURCE selects discovery:
  kubernetes - list RetroSession resources with the pod service account and
               proxy input/WHEP through this server (same origin).
  static     - use SESSIONS/SNES_INPUT_PORT/GBA_INPUT_PORT and let the browser
               connect directly.
  auto       - kubernetes when service-account credentials are present,
               otherwise static. This is the default.

Run from your project root:  python3 services/frontend/server.py
Reads INPUT_TOKEN_SECRET from the environment or a .env file. The token endpoint
has NO authentication: never expose this server beyond localhost."""
from __future__ import annotations

import os
import sys
from http.server import ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "..", "runtimes", "retroarch", "input-agent"))
from frontend import (  # noqa: E402
    _port_value,
    KubeSessionSource,
    SessionRegistry,
    make_handler,
    static_config_from_env,
)


def load_secret() -> str:
    if os.environ.get("INPUT_TOKEN_SECRET"):
        return os.environ["INPUT_TOKEN_SECRET"]
    for path in (os.path.join(os.getcwd(), ".env"), os.path.join(ROOT, "..", "..", ".env")):
        if os.path.exists(path):
            for line in open(path):
                if line.startswith("INPUT_TOKEN_SECRET="):
                    return line.split("=", 1)[1].strip().strip("\"'")
    sys.exit("INPUT_TOKEN_SECRET not found in environment or .env")


def session_source() -> KubeSessionSource | None:
    mode = os.environ.get("SESSION_SOURCE", "auto").strip().lower()
    kube = KubeSessionSource()
    if mode == "kubernetes":
        return kube
    if mode == "static":
        return None
    if mode != "auto":
        sys.exit(f"SESSION_SOURCE must be auto, kubernetes or static (got {mode!r})")
    return kube if kube.available() else None


SECRET = load_secret()
HOST = os.environ.get("DEV_HOST", "127.0.0.1")
PORT = int(os.environ.get("DEV_PORT", "8000"))
PROFILE_API_HOST = os.environ.get("PROFILE_API_HOST", "")
PROFILE_API_PORT = _port_value(os.environ.get("PROFILE_API_PORT", "4000"), 4000)
MEDIA_HOST = os.environ.get("MEDIA_HOST", "mediamtx")
MEDIA_WHEP_PORT = int(os.environ.get("MEDIA_WHEP_PORT", "8889"))

NAMES, PORTS, MEDIA_PORT = ([], {}, 8889)
SOURCE = session_source()
if SOURCE is None:
    NAMES, PORTS, MEDIA_PORT = static_config_from_env()
REGISTRY = SessionRegistry(SOURCE, NAMES, PORTS, MEDIA_PORT)


if __name__ == "__main__":
    mode = "kubernetes proxy" if SOURCE is not None else "static direct"
    print(f"Open http://localhost:{PORT}  (binding {HOST}, sessions: {mode})")
    ThreadingHTTPServer(
        (HOST, PORT), make_handler(REGISTRY, SECRET, MEDIA_HOST, MEDIA_WHEP_PORT, PROFILE_API_HOST, PROFILE_API_PORT)
    ).serve_forever()
