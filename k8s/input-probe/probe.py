"""Exercise the session's virtual controller and read back only its own events."""
import os
import select
import time
import uuid
from contextlib import closing
from pathlib import Path
from types import SimpleNamespace

from evdev import InputDevice, ecodes

from agent.device import VirtualGamepad


def wait_for(description, check):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for {description}")


def find_event(name):
    for event in Path("/sys/class/input").glob("event*"):
        try:
            if (event / "device/name").read_text().strip() == name:
                return event
        except FileNotFoundError:
            continue  # A device can disappear during enumeration.


def check_report(reader, pad, pressed):
    pad.set_button("south", pressed)
    pad.flush()
    events = []
    deadline = time.monotonic() + 5
    while select.select([reader], [], [], max(0, deadline - time.monotonic()))[0]:
        for event in reader.read():
            if event.type == ecodes.EV_KEY:
                events.append((event.code, event.value))
            if event.type == ecodes.EV_SYN and event.code == ecodes.SYN_REPORT:
                if events != [(ecodes.BTN_SOUTH, int(pressed))]:
                    raise RuntimeError(f"Unexpected button report: {events}")
                return
    raise RuntimeError(f"No complete button report for pressed={pressed}")


def main():
    name = f"Retro-K8s probe {uuid.uuid4().hex[:12]}"
    print(f"Creating {name!r} as uid={os.getuid()} gid={os.getgid()} groups={os.getgroups()}")
    pad = VirtualGamepad(SimpleNamespace(device_name=name, vendor=0x1209, product=1))
    try:
        pad.open()
        event = wait_for(f"sysfs event for {name}", lambda: find_event(name))
        node = Path("/dev/input") / event.name
        wait_for(str(node), node.is_char_device)
        major_minor = (event / "dev").read_text().strip()
        record = Path("/run/udev/data") / f"c{major_minor}"
        wait_for(f"joystick tag in {record}", lambda: record.exists() and
                 "E:ID_INPUT_JOYSTICK=1" in record.read_text().splitlines())
        with closing(InputDevice(str(node))) as reader:
            if reader.name != name:
                raise RuntimeError(f"{node} belongs to {reader.name!r}")
            check_report(reader, pad, True)
            check_report(reader, pad, False)
            print(f"Received BTN_SOUTH down and up on {node} ({major_minor})")
    finally:
        pad.close()
    wait_for(f"removal of {name}", lambda: not find_event(name))
    # An event number can be reassigned immediately to a different device.
    wait_for(f"removal or reassignment of {node}", lambda: not node.exists() or event.exists())
    print("PASS: virtual controller created, tagged, read and removed")


if __name__ == "__main__":
    main()
