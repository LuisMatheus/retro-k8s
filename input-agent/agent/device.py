"""The only module that imports evdev. Maps logical names to Linux codes."""
from evdev import AbsInfo, UInput
from evdev import ecodes as e

from .config import Config

BUTTON_CODES = {
    "south": e.BTN_SOUTH, "east": e.BTN_EAST,
    "west": e.BTN_WEST, "north": e.BTN_NORTH,
    "l": e.BTN_TL, "r": e.BTN_TR,
    "start": e.BTN_START, "select": e.BTN_SELECT,
}
AXIS_CODES = {
    "left_x": e.ABS_X, "left_y": e.ABS_Y,
    "right_x": e.ABS_RX, "right_y": e.ABS_RY,
}


class VirtualGamepad:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._ui: UInput | None = None

    def open(self) -> None:
        stick = AbsInfo(value=0, min=-32768, max=32767, fuzz=16, flat=128, resolution=0)
        hat = AbsInfo(value=0, min=-1, max=1, fuzz=0, flat=0, resolution=0)
        caps = {
            e.EV_KEY: sorted(BUTTON_CODES.values()),
            e.EV_ABS: [(c, stick) for c in AXIS_CODES.values()]
                      + [(e.ABS_HAT0X, hat), (e.ABS_HAT0Y, hat)],
        }
        self._ui = UInput(
            caps, name=self.cfg.device_name, vendor=self.cfg.vendor,
            product=self.cfg.product, version=1, bustype=e.BUS_USB,
        )

    def close(self) -> None:
        if self._ui:
            self._ui.close()
            self._ui = None

    # --- Sink interface ---
    def set_button(self, name: str, pressed: bool) -> None:
        self._ui.write(e.EV_KEY, BUTTON_CODES[name], 1 if pressed else 0)

    def set_axis(self, name: str, value: int) -> None:
        self._ui.write(e.EV_ABS, AXIS_CODES[name], value)

    def set_hat(self, x: int, y: int) -> None:
        self._ui.write(e.EV_ABS, e.ABS_HAT0X, x)
        self._ui.write(e.EV_ABS, e.ABS_HAT0Y, y)

    def flush(self) -> None:
        self._ui.syn()
