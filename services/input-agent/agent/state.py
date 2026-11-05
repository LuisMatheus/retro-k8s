"""Tracks controller state and drives a sink. The sink is the only thing
that knows about Linux (see device.py), so this is testable without uinput."""
import time
from typing import Protocol

from .protocol import AXES, Axis, Button, Heartbeat, ReleaseAll

AXIS_MAX = 32767
DPAD = {"up", "down", "left", "right"}


class Sink(Protocol):
    def set_button(self, name: str, pressed: bool) -> None: ...
    def set_axis(self, name: str, value: int) -> None: ...
    def set_hat(self, x: int, y: int) -> None: ...
    def flush(self) -> None: ...


class ControllerState:
    def __init__(self, sink: Sink, min_hold: float = 0.0, call_later=None, clock=time.monotonic):
        """min_hold: minimum seconds a button stays down. RetroArch polls input once
        per frame, so a press+release landing inside one poll window would be lost."""
        self.sink = sink
        self.min_hold = min_hold
        self.call_later = call_later
        self.clock = clock
        self.pressed_at: dict[str, float] = {}
        self.pending: dict[str, object] = {}
        self.buttons: dict[str, bool] = {}
        self.axes: dict[str, int] = {a: 0 for a in AXES}
        self.dpad: set[str] = set()
        self.hat = (0, 0)

    def apply(self, msg) -> None:
        if isinstance(msg, Button):
            self._button_msg(msg.name, msg.pressed)
        elif isinstance(msg, Axis):
            self._axis(msg.name, msg.value)
        elif isinstance(msg, ReleaseAll):
            self.release_all()
        elif isinstance(msg, Heartbeat):
            pass

    def _button_msg(self, name: str, pressed: bool) -> None:
        self._cancel(name)
        if pressed:
            self.pressed_at[name] = self.clock()
            self._button(name, True)
            return
        held = self.clock() - self.pressed_at.get(name, float("-inf"))
        if self.call_later and held < self.min_hold:
            self.pending[name] = self.call_later(self.min_hold - held, self._deferred_release, name)
        else:
            self._button(name, False)

    def _deferred_release(self, name: str) -> None:
        self.pending.pop(name, None)
        self._button(name, False)

    def _cancel(self, name: str) -> None:
        handle = self.pending.pop(name, None)
        if handle is not None:
            handle.cancel()

    def _button(self, name: str, pressed: bool) -> None:
        if name in DPAD:
            before = set(self.dpad)
            (self.dpad.add if pressed else self.dpad.discard)(name)
            if before != self.dpad:
                self._sync_hat()
                self.sink.flush()
            return
        if self.buttons.get(name, False) == pressed:
            return
        self.buttons[name] = pressed
        self.sink.set_button(name, pressed)
        self.sink.flush()

    def _axis(self, name: str, value: float) -> None:
        v = int(round(value * AXIS_MAX))
        if self.axes[name] == v:
            return
        self.axes[name] = v
        self.sink.set_axis(name, v)
        self.sink.flush()

    def _sync_hat(self) -> None:
        x = ("right" in self.dpad) - ("left" in self.dpad)
        y = ("down" in self.dpad) - ("up" in self.dpad)
        if (x, y) != self.hat:
            self.hat = (x, y)
            self.sink.set_hat(x, y)

    def release_all(self) -> None:
        for name in list(self.pending):
            self._cancel(name)
        self.pressed_at.clear()
        changed = False
        for name, down in list(self.buttons.items()):
            if down:
                self.buttons[name] = False
                self.sink.set_button(name, False)
                changed = True
        for name, v in self.axes.items():
            if v != 0:
                self.axes[name] = 0
                self.sink.set_axis(name, 0)
                changed = True
        if self.dpad:
            self.dpad.clear()
            self._sync_hat()
            changed = True
        if changed:
            self.sink.flush()
