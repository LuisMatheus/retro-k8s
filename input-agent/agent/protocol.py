"""Versioned JSON protocol. Pure Python: no evdev, no websockets."""
import json
import math
from dataclasses import dataclass

VERSION = 1
BUTTONS = frozenset({
    "up", "down", "left", "right",
    "south", "east", "west", "north",
    "start", "select", "l", "r",
})
AXES = frozenset({"left_x", "left_y", "right_x", "right_y"})


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class Button:
    name: str
    pressed: bool


@dataclass(frozen=True)
class Axis:
    name: str
    value: float  # clamped to -1.0..1.0


@dataclass(frozen=True)
class ReleaseAll:
    pass


@dataclass(frozen=True)
class Heartbeat:
    pass


def parse(raw, max_bytes: int = 512):
    size = len(raw.encode() if isinstance(raw, str) else raw)
    if size > max_bytes:
        raise ProtocolError("message too large")
    try:
        msg = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        raise ProtocolError("malformed JSON")
    if not isinstance(msg, dict):
        raise ProtocolError("message must be an object")
    if type(msg.get("version")) is not int or msg["version"] != VERSION:
        raise ProtocolError("unsupported version")

    if "seq" in msg and (type(msg["seq"]) is not int or not 0 <= msg["seq"] <= 2**53 - 1):
        raise ProtocolError("seq must be a nonnegative safe integer")

    kind = msg.get("type")
    if kind == "button":
        name, pressed = msg.get("button"), msg.get("pressed")
        if not isinstance(name, str) or name not in BUTTONS:
            raise ProtocolError("unknown button")
        if not isinstance(pressed, bool):
            raise ProtocolError("pressed must be boolean")
        return Button(name, pressed)
    if kind == "axis":
        name, value = msg.get("axis"), msg.get("value")
        if not isinstance(name, str) or name not in AXES:
            raise ProtocolError("unknown axis")
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ProtocolError("value must be a number")
        if isinstance(value, float) and not math.isfinite(value):
            raise ProtocolError("value must be finite")
        if value < -1.0 or value > 1.0:
            # Compare integers before converting: very large JSON integers can
            # overflow float conversion even within the message size limit.
            value = max(-1.0, min(1.0, value))
        return Axis(name, max(-1.0, min(1.0, float(value))))
    if kind == "release_all":
        return ReleaseAll()
    if kind == "heartbeat":
        return Heartbeat()
    raise ProtocolError("unknown message type")
