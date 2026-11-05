import asyncio
import json
import logging
import time
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
        counters = dict(received=0, accepted=0, invalid=0, rate_limited=0)
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

                started = time.perf_counter()
                counters["received"] += 1
                # seq is optional: old clients retain their fire-and-forget protocol.
                seq = None
                try:
                    envelope = json.loads(raw)
                    candidate = envelope.get("seq") if isinstance(envelope, dict) else None
                    if type(candidate) is int and 0 <= candidate <= 2**53 - 1:
                        seq = candidate
                except (ValueError, UnicodeDecodeError):
                    pass
                status = "accepted"
                if not bucket.allow():
                    violations += 1
                    counters["rate_limited"] += 1
                    status = "rate_limited"
                else:
                    try:
                        parsed = parse(raw, cfg.max_message_bytes)
                        if log.isEnabledFor(logging.DEBUG) and type(parsed).__name__ != "Heartbeat":
                            log.debug("rx %s", parsed)
                        state.apply(parsed)
                        counters["accepted"] += 1
                        violations = 0
                    except ProtocolError as exc:
                        violations += 1
                        counters["invalid"] += 1
                        status = "invalid"
                        await ws.send(json.dumps({"type": "error", "message": str(exc)}))
                if seq is not None:
                    processing_ms = (time.perf_counter() - started) * 1000
                    await ws.send(json.dumps({
                        "version": 1, "type": "ack", "seq": seq,
                        "status": status, "processing_ms": processing_ms,
                        "counters": counters,
                        # This is the agent's applied state, including minimum-hold
                        # deferred releases. It isn't proof of an emulator poll.
                        "state": {
                            "buttons": sorted([n for n, down in state.buttons.items() if down] + list(state.dpad)),
                            "axes": state.axes,
                            "pending_releases": sorted(state.pending),
                        },
                    }))
                if violations >= MAX_VIOLATIONS:
                    await ws.close(1008, "too many invalid or rate-limited messages")
                    break
        except ConnectionClosed:
            pass
        finally:
            state.release_all()  # never leave buttons stuck
            busy["active"] = False
            log.info("controller disconnected, state neutralized")

    return handler
