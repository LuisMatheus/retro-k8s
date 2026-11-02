import os
from dataclasses import dataclass


def _req(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return v


@dataclass(frozen=True)
class Config:
    host: str
    port: int
    session_id: str
    token_secret: str
    heartbeat_timeout: float
    max_message_bytes: int
    max_events_per_sec: float
    burst: int
    device_name: str
    vendor: int
    product: int
    allowed_origins: list | None
    min_hold_ms: float

    @classmethod
    def from_env(cls) -> "Config":
        origins = os.environ.get("ALLOWED_ORIGINS", "").strip()
        return cls(
            host=os.environ.get("AGENT_HOST", "0.0.0.0"),
            port=int(os.environ.get("AGENT_PORT", "8765")),
            session_id=_req("SESSION_ID"),
            token_secret=_req("INPUT_TOKEN_SECRET"),
            heartbeat_timeout=float(os.environ.get("HEARTBEAT_TIMEOUT", "5")),
            max_message_bytes=int(os.environ.get("MAX_MESSAGE_BYTES", "512")),
            max_events_per_sec=float(os.environ.get("MAX_EVENTS_PER_SEC", "200")),
            burst=int(os.environ.get("RATE_BURST", "400")),
            device_name=os.environ.get("DEVICE_NAME", "Retro-K8s Virtual Gamepad"),
            vendor=int(os.environ.get("DEVICE_VENDOR", "0x1209"), 0),
            product=int(os.environ.get("DEVICE_PRODUCT", "0x0001"), 0),
            min_hold_ms=float(os.environ.get("MIN_HOLD_MS", "40")),
            allowed_origins=[o.strip() for o in origins.split(",")] if origins else None,
        )
