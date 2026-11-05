"""Session discovery and reverse proxy for the browser frontend.

Inside Kubernetes the frontend lists ``RetroSession`` resources with its
service account and proxies the browser's input WebSocket and WHEP signaling to
the session Services. Outside Kubernetes it keeps the static
``SESSIONS``/``*_INPUT_PORT`` configuration.

The proxy deliberately derives every upstream from the ``RetroSession`` status,
never from a browser-supplied host or path.
"""

from __future__ import annotations

import json
import os
import select
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.client import HTTPConnection, HTTPException
from http.server import SimpleHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

from agent.auth import mint_token

GROUP = "retro.k8s"
VERSION = "v1alpha1"
PLURAL = "retrosessions"
SERVICE_ACCOUNT_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
BROWSER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "browser")


class SessionSourceError(RuntimeError):
    """Session discovery could not be completed."""


class ProxyError(RuntimeError):
    """A session endpoint could not be reached or proxied."""


@dataclass(frozen=True)
class Session:
    name: str
    console: str = ""
    phase: str = "Pending"
    ready: bool = False
    message: str = ""
    input_service: str = ""
    input_port: int = 0
    input_path: str = ""
    stream_path: str = ""
    whep_path: str = ""

    def public(self) -> dict:
        """Return the browser-visible fields, without internal endpoints."""
        return {
            "console": self.console,
            "phase": self.phase,
            "ready": self.ready,
            "message": self.message,
        }


def parse_sessions(items: list[dict]) -> dict[str, Session]:
    """Convert the Kubernetes list response into sessions keyed by name."""
    sessions: dict[str, Session] = {}
    for item in items or []:
        metadata = item.get("metadata") or {}
        name = metadata.get("name")
        if not name or metadata.get("deletionTimestamp"):
            continue
        spec = item.get("spec") or {}
        status = item.get("status") or {}
        endpoints = status.get("endpoints") or {}
        conditions = status.get("conditions") or []
        phase = str(status.get("phase") or "Pending")
        ready = phase == "Ready" and any(
            condition.get("type") == "Ready" and condition.get("status") == "True"
            for condition in conditions
        )
        try:
            input_port = int(endpoints.get("inputPort") or 0)
        except (TypeError, ValueError):
            input_port = 0
        sessions[name] = Session(
            name=name,
            console=str(spec.get("console") or ""),
            phase=phase,
            ready=ready,
            message=str(status.get("message") or ""),
            input_service=str(endpoints.get("inputService") or ""),
            input_port=input_port,
            input_path=str(endpoints.get("inputPath") or ""),
            stream_path=str(endpoints.get("streamPath") or ""),
            whep_path=str(endpoints.get("whepPath") or ""),
        )
    return sessions


def public_config(
    mode: str,
    source: str,
    sessions: dict[str, Session],
    media_port: int | None = None,
    input_ports: dict[str, int] | None = None,
) -> dict:
    """Build the browser configuration without leaking Service DNS names."""
    names = sorted(sessions)
    config = {
        "mode": mode,
        "source": source,
        "sessions": names,
        "details": {name: sessions[name].public() for name in names},
    }
    if media_port is not None:
        config["mediaPort"] = int(media_port)
    if input_ports is not None:
        config["inputPorts"] = {
            name: int(input_ports[name]) for name in names if name in input_ports
        }
    return config


def static_sessions(
    names: list[str], input_ports: dict[str, int], media_port: int
) -> tuple[dict[str, Session], dict]:
    """Build the direct-connection configuration used outside Kubernetes."""
    sessions: dict[str, Session] = {}
    for name in sorted({name.strip() for name in names if name and name.strip()}):
        port = int(input_ports.get(name, 0) or 0)
        sessions[name] = Session(
            name=name,
            console=name if name in ("snes", "gba") else "",
            phase="Ready" if port else "Pending",
            ready=bool(port),
            message="" if port else "No input port is configured for this session",
            input_port=port,
        )
    return sessions, public_config(
        "direct", "static", sessions, media_port, input_ports
    )


def _port_value(value: str, default: int) -> int:
    """Accept a plain port or the URL form Kubernetes service links inject."""
    try:
        return int(value)
    except (TypeError, ValueError):
        pass
    try:
        return int(urlparse(str(value)).port or default)
    except (TypeError, ValueError):
        return default


def static_config_from_env() -> tuple[list[str], dict[str, int], int]:
    """Read the static/direct-mode session configuration."""
    names = [name.strip() for name in os.environ.get("SESSIONS", "snes,gba").split(",")]
    ports = {
        "snes": _port_value(os.environ.get("SNES_INPUT_PORT", "8765"), 8765),
        "gba": _port_value(os.environ.get("GBA_INPUT_PORT", "8766"), 8766),
    }
    # Optional extra mappings: INPUT_PORTS="session-a:9001,session-b:9002".
    for item in os.environ.get("INPUT_PORTS", "").split(","):
        name, separator, value = item.partition(":")
        if separator:
            try:
                ports[name.strip()] = int(value)
            except ValueError:
                pass
    return names, ports, _port_value(os.environ.get("MEDIA_PORT", "8889"), 8889)


def read_namespace() -> str:
    path = os.path.join(SERVICE_ACCOUNT_DIR, "namespace")
    try:
        with open(path, encoding="utf-8") as handle:
            value = handle.read().strip()
            if value:
                return value
    except OSError:
        pass
    return os.environ.get("POD_NAMESPACE", "retro-k8s")


class KubeSessionSource:
    """List RetroSession resources through the in-cluster API."""

    def __init__(
        self,
        namespace: str | None = None,
        api_host: str | None = None,
        api_port: str | None = None,
        token_path: str | None = None,
        ca_path: str | None = None,
        timeout: float = 3.0,
    ):
        self.namespace = namespace or read_namespace()
        self.api_host = api_host or os.environ.get("KUBERNETES_SERVICE_HOST", "")
        self.api_port = api_port or os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        self.token_path = token_path or os.path.join(SERVICE_ACCOUNT_DIR, "token")
        self.ca_path = ca_path or os.path.join(SERVICE_ACCOUNT_DIR, "ca.crt")
        self.timeout = timeout

    def available(self) -> bool:
        return (
            bool(self.api_host)
            and os.path.exists(self.token_path)
            and os.path.exists(self.ca_path)
        )

    def fetch(self) -> dict[str, Session]:
        if not self.available():
            raise SessionSourceError("Kubernetes API credentials are not available")
        try:
            with open(self.token_path, encoding="utf-8") as handle:
                token = handle.read().strip()
        except OSError as exc:
            raise SessionSourceError(f"read service account token: {exc}") from exc

        host = self.api_host
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        url = (
            f"https://{host}:{self.api_port}/apis/{GROUP}/{VERSION}"
            f"/namespaces/{self.namespace}/{PLURAL}"
        )
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            },
        )
        try:
            context = ssl.create_default_context(cafile=self.ca_path)
            with urllib.request.urlopen(
                request, context=context, timeout=self.timeout
            ) as response:
                payload = json.load(response)
        except (OSError, ssl.SSLError, urllib.error.URLError, ValueError) as exc:
            raise SessionSourceError(f"list {PLURAL}: {exc}") from exc
        if not isinstance(payload, dict):
            raise SessionSourceError("Kubernetes API returned an invalid session list")
        return parse_sessions(payload.get("items") or [])


class SessionRegistry:
    """Cache discovery briefly so a config poll and proxy share a snapshot."""

    def __init__(
        self,
        source: KubeSessionSource | None,
        static_names: list[str],
        static_input_ports: dict[str, int],
        static_media_port: int,
        cache_seconds: float = 2.0,
    ):
        self.source = source
        self.static_names = list(static_names)
        self.static_input_ports = dict(static_input_ports)
        self.static_media_port = int(static_media_port)
        self.cache_seconds = cache_seconds
        self._lock = threading.Lock()
        self._config: dict | None = None
        self._sessions: dict[str, Session] = {}
        self._loaded_at = 0.0

    def _load(self) -> tuple[dict, dict[str, Session]]:
        if self.source is not None:
            sessions = self.source.fetch()
            return public_config("proxy", "kubernetes", sessions), sessions
        sessions, config = static_sessions(
            self.static_names, self.static_input_ports, self.static_media_port
        )
        return config, sessions

    def _snapshot(self, force: bool = False) -> tuple[dict, dict[str, Session]]:
        with self._lock:
            now = time.monotonic()
            if (
                not force
                and self._config is not None
                and now - self._loaded_at < self.cache_seconds
            ):
                return self._config, self._sessions
            config, sessions = self._load()
            self._config, self._sessions, self._loaded_at = config, sessions, now
            return config, sessions

    def config(self) -> dict:
        return self._snapshot()[0]

    def session(self, name: str) -> Session | None:
        return self._snapshot()[1].get(name)


def relay(
    client: socket.socket, upstream: socket.socket, idle_timeout: float = 120.0
) -> None:
    """Tunnel bytes in both directions until both sides close."""
    peers = {client: upstream, upstream: client}
    open_reads = {client, upstream}
    try:
        while open_reads:
            readable, _, exceptional = select.select(
                list(open_reads), [], list(open_reads), idle_timeout
            )
            if exceptional or not readable:
                break
            for sock in readable:
                try:
                    data = sock.recv(65536)
                except OSError:
                    return
                other = peers[sock]
                if data:
                    try:
                        other.sendall(data)
                    except OSError:
                        return
                else:
                    open_reads.discard(sock)
                    try:
                        other.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
    finally:
        for sock in (client, upstream):
            try:
                sock.close()
            except OSError:
                pass


def proxy_websocket(
    client: socket.socket,
    session: Session,
    query: str,
    headers,
    connect_timeout: float = 5.0,
) -> None:
    """Forward a browser WebSocket handshake and tunnel the connection."""
    key = headers.get("Sec-WebSocket-Key")
    version = headers.get("Sec-WebSocket-Version")
    if not key or not version:
        raise ProxyError("missing WebSocket handshake headers")
    path = session.input_path or f"/sessions/{session.name}/input"
    if not path.startswith("/"):
        path = "/" + path
    if query:
        path += "?" + query
    try:
        upstream = socket.create_connection(
            (session.input_service, session.input_port), timeout=connect_timeout
        )
    except OSError as exc:
        raise ProxyError(
            f"connect to {session.input_service}:{session.input_port}: {exc}"
        ) from exc
    try:
        upstream.settimeout(None)
        lines = [
            f"GET {path} HTTP/1.1",
            f"Host: {session.input_service}:{session.input_port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            f"Sec-WebSocket-Version: {version}",
        ]
        origin = headers.get("Origin")
        if origin:
            lines.append(f"Origin: {origin}")
        for header in (
            "Sec-WebSocket-Extensions",
            "Sec-WebSocket-Protocol",
            "User-Agent",
        ):
            value = headers.get(header)
            if value:
                lines.append(f"{header}: {value}")
        lines.extend(["", ""])
        upstream.sendall("\r\n".join(lines).encode("latin-1"))
    except OSError as exc:
        upstream.close()
        raise ProxyError(f"send WebSocket handshake: {exc}") from exc
    relay(client, upstream)


def proxy_whep(
    session: Session,
    body: bytes,
    media_host: str,
    media_port: int,
    timeout: float = 10.0,
) -> tuple[int, str, bytes]:
    """Forward a WHEP offer to MediaMTX and return its answer."""
    path = session.whep_path
    if not path and session.stream_path:
        path = f"/{session.stream_path}/whep"
    if not path:
        raise ProxyError("session has no WHEP endpoint")
    if not path.startswith("/"):
        path = "/" + path
    connection = HTTPConnection(media_host, media_port, timeout=timeout)
    try:
        connection.request(
            "POST",
            path,
            body=body,
            headers={
                "Content-Type": "application/sdp",
                "Accept": "application/sdp",
            },
        )
        response = connection.getresponse()
        data = response.read()
        return (
            response.status,
            response.getheader("Content-Type") or "application/sdp",
            data,
        )
    except (OSError, HTTPException) as exc:
        raise ProxyError(f"WHEP request failed: {exc}") from exc
    finally:
        connection.close()


def make_handler(
    registry: SessionRegistry, secret: str, media_host: str, media_whep_port: int
):
    """Create the HTTP handler with discovery and proxy dependencies bound."""

    class Handler(SimpleHTTPRequestHandler):
        server_version = "RetroK8sFrontend/1.0"

        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=BROWSER_DIR, **kwargs)

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/config":
                try:
                    config = registry.config()
                except SessionSourceError as exc:
                    self._send_json(503, {"error": str(exc)})
                    return
                self._send_json(200, config)
                return
            if parsed.path == "/api/token":
                self._token(parsed.query)
                return
            parts = parsed.path.strip("/").split("/")
            if (
                len(parts) == 4
                and parts[:2] == ["api", "sessions"]
                and parts[3] == "input"
            ):
                if "websocket" not in self.headers.get("Upgrade", "").lower():
                    self._send_text(400, "expected a WebSocket upgrade")
                    return
                self._input(parts[2], parsed.query)
                return
            super().do_GET()

        def do_POST(self):
            parsed = urlparse(self.path)
            parts = parsed.path.strip("/").split("/")
            if (
                len(parts) == 4
                and parts[:2] == ["api", "sessions"]
                and parts[3] == "whep"
            ):
                self._whep(parts[2])
                return
            self._send_text(404, "not found")

        def _token(self, query: str) -> None:
            name = parse_qs(query).get("session", [""])[0]
            try:
                session = registry.session(name)
            except SessionSourceError as exc:
                self._send_text(503, str(exc))
                return
            if session is None:
                self._send_text(404, "unknown session")
                return
            if not session.ready:
                self._send_text(409, f"session is {session.phase}: {session.message}")
                return
            self._send_text(200, mint_token(secret, name))

        def _input(self, name: str, query: str) -> None:
            try:
                session = registry.session(name)
            except SessionSourceError as exc:
                self._send_text(503, str(exc))
                return
            if session is None:
                self._send_text(404, "unknown session")
                return
            if not session.ready:
                self._send_text(409, f"session is {session.phase}: {session.message}")
                return
            if not session.input_service or not session.input_port:
                self._send_text(502, "session has no input endpoint")
                return
            self.close_connection = True
            try:
                proxy_websocket(self.connection, session, query, self.headers)
            except ProxyError as exc:
                try:
                    self._send_text(502, str(exc))
                except OSError:
                    pass

        def _whep(self, name: str) -> None:
            try:
                session = registry.session(name)
            except SessionSourceError as exc:
                self._send_text(503, str(exc))
                return
            if session is None:
                self._send_text(404, "unknown session")
                return
            if not session.ready:
                self._send_text(409, f"session is {session.phase}: {session.message}")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self._send_text(400, "invalid Content-Length")
                return
            if length <= 0 or length > 65536:
                self._send_text(400, "invalid SDP body")
                return
            body = self.rfile.read(length)
            try:
                status, content_type, data = proxy_whep(
                    session, body, media_host, media_whep_port
                )
            except ProxyError as exc:
                self._send_text(502, str(exc))
                return
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _send(self, status: int, content_type: str, body: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _send_json(self, status: int, payload: dict) -> None:
            self._send(status, "application/json", json.dumps(payload).encode())

        def _send_text(self, status: int, text: str) -> None:
            self._send(status, "text/plain; charset=utf-8", text.encode())

    return Handler
