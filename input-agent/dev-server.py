#!/usr/bin/env python3
"""DEV ONLY. Serves browser/ and mints short-lived input tokens at /api/token.
Run from your project root:  python3 input-agent/dev-server.py
Reads INPUT_TOKEN_SECRET from the environment or a .env file. The token endpoint
has NO authentication: never expose this server beyond localhost."""
import os
import json
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
from agent.auth import mint_token  # noqa: E402  (stdlib only)

SESSIONS = set(os.environ.get("SESSIONS", "snes,gba").split(","))
HOST = os.environ.get("DEV_HOST", "127.0.0.1")
PORT = int(os.environ.get("DEV_PORT", "8000"))


def load_secret() -> str:
    if os.environ.get("INPUT_TOKEN_SECRET"):
        return os.environ["INPUT_TOKEN_SECRET"]
    for path in (os.path.join(os.getcwd(), ".env"), os.path.join(ROOT, "..", ".env")):
        if os.path.exists(path):
            for line in open(path):
                if line.startswith("INPUT_TOKEN_SECRET="):
                    return line.split("=", 1)[1].strip().strip("\"'")
    sys.exit("INPUT_TOKEN_SECRET not found in environment or .env")


SECRET = load_secret()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=os.path.join(ROOT, "browser"), **k)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/api/config":
            body = json.dumps({
                "sessions": sorted(SESSIONS),
                "mediaPort": int(os.environ.get("MEDIA_PORT", "8889")),
                "inputPorts": {
                    "snes": int(os.environ.get("SNES_INPUT_PORT", "8765")),
                    "gba": int(os.environ.get("GBA_INPUT_PORT", "8766")),
                },
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if url.path == "/api/token":
            sid = parse_qs(url.query).get("session", [""])[0]
            if sid not in SESSIONS:
                return self.send_error(404, "unknown session")
            body = mint_token(SECRET, sid, ttl=60).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()


if __name__ == "__main__":
    print(f"Open http://localhost:{PORT}  (binding {HOST})")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
