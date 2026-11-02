import asyncio
import logging
import os
import signal

from websockets.asyncio.server import serve

from .config import Config
from .device import VirtualGamepad
from .server import make_handler
from .state import ControllerState


async def amain() -> None:
    cfg = Config.from_env()
    pad = VirtualGamepad(cfg)
    pad.open()  # fails loudly if /dev/uinput is unavailable
    loop = asyncio.get_running_loop()
    state = ControllerState(pad, min_hold=cfg.min_hold_ms / 1000, call_later=loop.call_later)

    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    try:
        async with serve(
            make_handler(cfg, state), cfg.host, cfg.port,
            max_size=cfg.max_message_bytes, origins=cfg.allowed_origins,
            ping_interval=10, ping_timeout=10,
        ):
            logging.info("listening on %s:%d", cfg.host, cfg.port)
            await stop.wait()
    finally:
        state.release_all()
        pad.close()


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(), format="%(asctime)s %(name)s %(message)s")
    asyncio.run(amain())
