"""Frontend discovery, config and same-origin proxy tests."""
import asyncio
import json
import os
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from agent.auth import mint_token, verify_token
from frontend import (
    KubeSessionSource,
    Session,
    SessionRegistry,
    SessionSourceError,
    make_handler,
    parse_sessions,
    public_config,
    static_config_from_env,
    static_sessions,
)


def item(name, console="snes", phase="Ready", ready=True, message="", **endpoints):
    conditions = [{"type": "Ready", "status": "True" if ready else "False"}]
    return {
        "metadata": {"name": name},
        "spec": {"console": console},
        "status": {
            "phase": phase,
            "message": message,
            "conditions": conditions,
            "endpoints": {
                "inputService": f"{name}-input",
                "inputPort": 8765,
                "inputPath": f"/sessions/{name}/input",
                "streamPath": name,
                "whepPath": f"/{name}/whep",
                **endpoints,
            },
        },
    }


class DiscoveryTests(unittest.TestCase):
    def test_parses_ready_and_pending_sessions(self):
        sessions = parse_sessions([
            item("chrono-trigger"),
            item("golden-sun", console="gba", phase="Pending", ready=False,
                 message="SaveClaimNotBound: waiting for the PVC"),
            {"metadata": {"name": "deleting", "deletionTimestamp": "2026-01-01T00:00:00Z"}},
        ])
        self.assertEqual(sorted(sessions), ["chrono-trigger", "golden-sun"])
        self.assertTrue(sessions["chrono-trigger"].ready)
        self.assertEqual(sessions["chrono-trigger"].input_service, "chrono-trigger-input")
        self.assertEqual(sessions["chrono-trigger"].input_port, 8765)
        self.assertEqual(sessions["chrono-trigger"].whep_path, "/chrono-trigger/whep")
        self.assertFalse(sessions["golden-sun"].ready)
        self.assertEqual(sessions["golden-sun"].phase, "Pending")
        self.assertIn("SaveClaimNotBound", sessions["golden-sun"].message)

    def test_ready_requires_matching_ready_condition(self):
        broken = item("broken")
        broken["status"]["conditions"] = [{"type": "Ready", "status": "False"}]
        sessions = parse_sessions([broken])
        self.assertFalse(sessions["broken"].ready)

    def test_invalid_input_port_is_zero(self):
        sessions = parse_sessions([item("odd", inputPort="not-a-number")])
        self.assertEqual(sessions["odd"].input_port, 0)

    def test_public_config_hides_internal_endpoints(self):
        sessions = parse_sessions([item("chrono-trigger")])
        config = public_config("proxy", "kubernetes", sessions)
        self.assertEqual(config["mode"], "proxy")
        self.assertEqual(config["source"], "kubernetes")
        self.assertEqual(config["sessions"], ["chrono-trigger"])
        self.assertTrue(config["details"]["chrono-trigger"]["ready"])
        encoded = json.dumps(config)
        for internal in ("inputService", "inputPath", "whepPath", "rtmpURL", "chrono-trigger-input"):
            self.assertNotIn(internal, encoded)

    def test_static_config_from_environment(self):
        env = {
            "SESSIONS": "snes,gba,extra",
            "SNES_INPUT_PORT": "9001",
            "GBA_INPUT_PORT": "9002",
            "INPUT_PORTS": "extra:9003",
            "MEDIA_PORT": "9999",
        }
        with patch.dict(os.environ, env, clear=True):
            names, ports, media_port = static_config_from_env()
        sessions, config = static_sessions(names, ports, media_port)
        self.assertEqual(names, ["snes", "gba", "extra"])
        self.assertEqual(config["mode"], "direct")
        self.assertEqual(config["source"], "static")
        self.assertEqual(config["mediaPort"], 9999)
        self.assertEqual(config["inputPorts"], {"extra": 9003, "gba": 9002, "snes": 9001})
        self.assertEqual(sorted(sessions), ["extra", "gba", "snes"])
        self.assertTrue(sessions["snes"].ready)

    def test_static_config_accepts_kubernetes_service_links(self):
        env = {"SESSIONS": "snes", "SNES_INPUT_PORT": "tcp://10.99.128.25:8765"}
        with patch.dict(os.environ, env, clear=True):
            names, ports, _ = static_config_from_env()
        self.assertEqual(names, ["snes"])
        self.assertEqual(ports["snes"], 8765)

    def test_static_session_without_port_is_pending(self):
        sessions, config = static_sessions(["snes", "mystery"], {"snes": 8765}, 8889)
        self.assertFalse(sessions["mystery"].ready)
        self.assertEqual(sessions["mystery"].phase, "Pending")
        self.assertNotIn("mystery", config["inputPorts"])

    def test_kube_source_unavailable_without_credentials(self):
        source = KubeSessionSource(namespace="retro-k8s", api_host="",
                                   token_path="/does/not/exist", ca_path="/does/not/exist")
        self.assertFalse(source.available())
        with self.assertRaises(SessionSourceError):
            source.fetch()


class FakeSource:
    def __init__(self, sessions):
        self.sessions = sessions

    def fetch(self):
        return self.sessions


def start_server(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, server.server_address[1]


def stop_server(server):
    server.shutdown()
    server.server_close()


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.session = Session(
            name="chrono-trigger",
            console="snes",
            phase="Ready",
            ready=True,
            input_service="127.0.0.1",
            input_port=1,
            input_path="/sessions/chrono-trigger/input",
            stream_path="chrono-trigger",
            whep_path="/chrono-trigger/whep",
        )
        self.pending = Session(
            name="golden-sun", console="gba", phase="Pending", ready=False,
            message="SaveClaimNotBound: waiting for the PVC",
        )
        self.registry = SessionRegistry(
            FakeSource({"chrono-trigger": self.session, "golden-sun": self.pending}),
            [], {}, 8889, cache_seconds=0,
        )
        self.secret = "test-secret"
        self.server, self.port = start_server(
            make_handler(self.registry, self.secret, "127.0.0.1", 1)
        )

    def tearDown(self):
        stop_server(self.server)

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def test_config_and_token(self):
        with urllib.request.urlopen(self.url("/api/config")) as response:
            config = json.load(response)
        self.assertEqual(config["mode"], "proxy")
        self.assertEqual(sorted(config["sessions"]), ["chrono-trigger", "golden-sun"])
        self.assertNotIn("inputPorts", config)
        self.assertNotIn("mediaPort", config)

        with urllib.request.urlopen(self.url("/api/token?session=chrono-trigger")) as response:
            token = response.read().decode()
        self.assertTrue(verify_token(token, self.secret, "chrono-trigger"))

        for path, code in (("/api/token?session=golden-sun", 409),
                           ("/api/token?session=missing", 404)):
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(self.url(path))
            self.assertEqual(raised.exception.code, code)
            if code == 409:
                self.assertIn("SaveClaimNotBound", raised.exception.read().decode())
            raised.exception.close()

    def test_unknown_post_is_not_found(self):
        request = urllib.request.Request(self.url("/nope"), data=b"x", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request)
        self.assertEqual(raised.exception.code, 404)
        raised.exception.close()


class ProxyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.seen = {}
        self.upstream = await serve(self._echo, "127.0.0.1", 0)
        self.upstream_port = self.upstream.sockets[0].getsockname()[1]
        self.whep_server, self.whep_port = start_server(self._whep_handler())

    async def asyncTearDown(self):
        self.upstream.close()
        await self.upstream.wait_closed()
        await asyncio.to_thread(stop_server, self.whep_server)

    async def _echo(self, ws):
        self.seen["path"] = ws.request.path
        self.seen["origin"] = ws.request.headers.get("Origin")
        async for message in ws:
            await ws.send(message)

    def _whep_handler(self):
        seen = self.seen

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                seen["whep_path"] = self.path
                seen["whep_body"] = self.rfile.read(length)
                body = b"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"
                self.send_response(201)
                self.send_header("Content-Type", "application/sdp")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        return Handler

    def session(self):
        return Session(
            name="chrono-trigger",
            console="snes",
            phase="Ready",
            ready=True,
            input_service="127.0.0.1",
            input_port=self.upstream_port,
            input_path="/sessions/chrono-trigger/input",
            stream_path="chrono-trigger",
            whep_path="/chrono-trigger/whep",
        )

    async def test_websocket_proxy_forwards_path_origin_and_bytes(self):
        registry = SessionRegistry(FakeSource({"chrono-trigger": self.session()}),
                                   [], {}, 8889, cache_seconds=0)
        server, port = start_server(
            make_handler(registry, "test-secret", "127.0.0.1", self.whep_port)
        )
        try:
            async with connect(
                f"ws://127.0.0.1:{port}/api/sessions/chrono-trigger/input?token=abc",
                origin="http://example.test",
            ) as ws:
                await ws.send("hello")
                self.assertEqual(await ws.recv(), "hello")
        finally:
            await asyncio.to_thread(stop_server, server)
        self.assertEqual(self.seen["path"], "/sessions/chrono-trigger/input?token=abc")
        self.assertEqual(self.seen["origin"], "http://example.test")

    async def test_whep_proxy_uses_status_path(self):
        registry = SessionRegistry(FakeSource({"chrono-trigger": self.session()}),
                                   [], {}, 8889, cache_seconds=0)
        server, port = start_server(
            make_handler(registry, "test-secret", "127.0.0.1", self.whep_port)
        )

        def post():
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/api/sessions/chrono-trigger/whep",
                data=b"offer-sdp",
                headers={"Content-Type": "application/sdp"},
                method="POST",
            )
            with urllib.request.urlopen(request) as response:
                return response.status, response.headers["Content-Type"], response.read()

        try:
            status, content_type, body = await asyncio.to_thread(post)
        finally:
            await asyncio.to_thread(stop_server, server)
        self.assertEqual(status, 201)
        self.assertEqual(content_type, "application/sdp")
        self.assertTrue(body.startswith(b"v=0"))
        self.assertEqual(self.seen["whep_path"], "/chrono-trigger/whep")
        self.assertEqual(self.seen["whep_body"], b"offer-sdp")

    async def test_proxy_rejects_unknown_and_pending_sessions(self):
        pending = Session(name="golden-sun", console="gba", phase="Pending",
                          ready=False, message="SaveClaimNotBound")
        registry = SessionRegistry(
            FakeSource({"chrono-trigger": self.session(), "golden-sun": pending}),
            [], {}, 8889, cache_seconds=0,
        )
        server, port = start_server(
            make_handler(registry, "test-secret", "127.0.0.1", self.whep_port)
        )
        try:
            for name, code in (("missing", 404), ("golden-sun", 409)):
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/api/sessions/{name}/input",
                    headers={
                        "Upgrade": "websocket",
                        "Connection": "Upgrade",
                        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
                        "Sec-WebSocket-Version": "13",
                    },
                )
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    await asyncio.to_thread(urllib.request.urlopen, request)
                self.assertEqual(raised.exception.code, code)
                raised.exception.close()
        finally:
            await asyncio.to_thread(stop_server, server)


if __name__ == "__main__":
    unittest.main()

class ProfileProxyTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        seen = self.requests

        class Upstream(BaseHTTPRequestHandler):
            def respond(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                seen.append((self.command, self.path, body))
                payload = b'{"profiles":[]}' if self.command == "GET" else body
                self.send_response(200 if self.command != "POST" else 201)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            do_GET = do_POST = do_PATCH = respond
            def log_message(self, *args):
                pass

        self.upstream, upstream_port = start_server(Upstream)
        registry = SessionRegistry(None, [], {}, 8889)
        self.frontend, self.port = start_server(
            make_handler(registry, "secret", "127.0.0.1", 1, "127.0.0.1", upstream_port)
        )

    def tearDown(self):
        stop_server(self.frontend)
        stop_server(self.upstream)

    def test_profile_methods_and_invalid_paths(self):
        base = f"http://127.0.0.1:{self.port}"
        profile_id = "8dc5e364-d145-46de-95ce-8fae4f6763cb"
        for method, path, data in (
            ("GET", "/api/profiles", None),
            ("POST", "/api/profiles", b'{"display_name":"Alice"}'),
            ("PATCH", f"/api/profiles/{profile_id}", b'{"display_name":"A"}'),
        ):
            req = urllib.request.Request(base + path, data=data, method=method)
            with urllib.request.urlopen(req) as response:
                self.assertEqual(response.status, 201 if method == "POST" else 200)
        self.assertEqual([item[:2] for item in self.requests], [
            ("GET", "/api/profiles"), ("POST", "/api/profiles"),
            ("PATCH", f"/api/profiles/{profile_id}"),
        ])
        request = urllib.request.Request(base + "/api/profiles/invalid", data=b"{}", method="PATCH")
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code, 404)
        error.exception.close()

    def test_limits_profile_request_size(self):
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}/api/profiles", data=b"x" * 4097, method="POST")
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code, 413)
        error.exception.close()
        self.assertFalse(self.requests)
