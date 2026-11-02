import asyncio
import json
import logging
from urllib.parse import parse_qs, urlparse

from websockets.exceptions import ConnectionClosed

from .auth import verify_token
from .config import Config
from .protocol import ProtocolError, parse
from .ratelimit import TokenBucket
from .state import ControllerState

log = logging.getLogger("input-agent")
MAX_VIOLATIONS = 20


def make_handler(cfg: Config, state: ControllerState):
    busy = {"active": False}  # one controlling client per session

    async def handler(ws):
        query = parse_qs(urlparse(ws.request.path).query)
        token = query.get("token", [""])[0]
        if not verify_token(token, cfg.token_secret, cfg.session_id):
            await ws.close(4401, "unauthorized")
            return
        if busy["active"]:
            await ws.close(4409, "controller already connected")
            return

        busy["active"] = True
        state.release_all()  # reconnect always starts neutral
        bucket = TokenBucket(cfg.max_events_per_sec, cfg.burst)
        violations = 0
        log.info("controller connected")
        try:
            while True:
                try:
                    raw = await asyncio.wait_for(ws.recv(), cfg.heartbeat_timeout)
                except asyncio.TimeoutError:
                    log.warning("heartbeat timeout")
                    await ws.close(4408, "heartbeat timeout")
                    break
                except ConnectionClosed:
                    break

                if not bucket.allow():
                    violations += 1
                else:
                    try:
                        parsed = parse(raw, cfg.max_message_bytes)
                        if log.isEnabledFor(logging.DEBUG) and type(parsed).__name__ != "Heartbeat":
                            log.debug("rx %s", parsed)
                        state.apply(parsed)
                        violations = 0
                    except ProtocolError as exc:
                        violations += 1
                        await ws.send(json.dumps({"type": "error", "message": str(exc)}))
                if violations >= MAX_VIOLATIONS:
                    await ws.close(1008, "too many invalid or rate-limited messages")
                    break
        finally:
            state.release_all()  # never leave buttons stuck
            busy["active"] = False
            log.info("controller disconnected, state neutralized")

    return handler
