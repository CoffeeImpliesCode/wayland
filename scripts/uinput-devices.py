#!/usr/bin/env python3
"""Virtual input devices for the libinput backend (HOST-side tooling).

Creates a virtual keyboard and an absolute mouse through /dev/uinput
(python-evdev's uinput API) on the HOST. udev announces the devices to
the compositor, whose libinput backend (WAYLAND_LIBINPUT=1) picks them
up like real hardware. Run as root (or with uinput group access) on the
host.

This script is NOT part of the E2E gate: the guest image ships no
python3/evdev, and the VM E2Es use the virtio keyboard/mouse instead.
It exists for interactive host-side debugging of the libinput backend.

Usage (multiple commands per invocation; devices live for the process):

    uinput-devices.py key a                # tap the 'a' key
    uinput-devices.py key esc              # names: a-z, esc, enter, space,
                                           #   tab, backspace, arrows, or an
                                           #   evdev code (e.g. key 30)
    uinput-devices.py mousemove 32768 32768  # absolute position (0..0xFFFF)
    uinput-devices.py click                # click [left|right|middle]
    uinput-devices.py scroll -1            # wheel: -1 down, +1 up

The mouse mirrors the VM's virtio-mouse: ABS_X/ABS_Y 0..0xFFFF with a
relative wheel, exactly what the backend's absolute-motion path scales to
the output size.

Only dependency: python-evdev (no stdlib equivalent exists).
"""

import sys

from evdev import UInput, ecodes as e

ABS_RANGE = 0xFFFF

KEYBOARD_KEYS = (
    [getattr(e, "KEY_" + c.upper()) for c in "abcdefghijklmnopqrstuvwxyz"]
    + [e.KEY_ESC, e.KEY_ENTER, e.KEY_SPACE, e.KEY_TAB, e.KEY_BACKSPACE,
       e.KEY_LEFT, e.KEY_RIGHT, e.KEY_UP, e.KEY_DOWN]
)

BUTTONS = {"left": e.BTN_LEFT, "right": e.BTN_RIGHT, "middle": e.BTN_MIDDLE}


def make_keyboard():
    return UInput({e.EV_KEY: KEYBOARD_KEYS},
                  name="wayland-test-keyboard", bustype=e.BUS_VIRTUAL)


def make_mouse():
    return UInput({
        e.EV_KEY: list(BUTTONS.values()),
        e.EV_ABS: [(e.ABS_X, (0, ABS_RANGE, 0, 0)), (e.ABS_Y, (0, ABS_RANGE, 0, 0))],
        e.EV_REL: [e.REL_WHEEL],
    }, name="wayland-test-mouse", bustype=e.BUS_VIRTUAL)


def emit(ui, etype, code, value):
    ui.write(etype, code, value)
    ui.syn()


def tap(ui, code):
    emit(ui, e.EV_KEY, code, 1)
    emit(ui, e.EV_KEY, code, 0)


def resolve_key(name):
    if name.isdigit():
        return int(name)
    code = getattr(e, "KEY_" + name.upper(), None)
    if code is None:
        sys.exit(f"unknown key name: {name}")
    return code


def clamp(value, name):
    try:
        v = int(value)
    except ValueError:
        sys.exit(f"{name}: expected an integer, got {value}")
    return max(0, min(ABS_RANGE, v))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.split("Usage")[1].split("Only dependency")[0].strip())
        return 0

    kbd = None
    mouse = None
    try:
        i = 0
        while i < len(argv):
            cmd = argv[i]
            i += 1
            if cmd == "key":
                if i >= len(argv):
                    sys.exit("key: missing key name")
                kbd = kbd or make_keyboard()
                tap(kbd, resolve_key(argv[i]))
                i += 1
            elif cmd == "mousemove":
                if i + 1 >= len(argv):
                    sys.exit("mousemove: missing x y")
                mouse = mouse or make_mouse()
                x = clamp(argv[i], "x")
                y = clamp(argv[i + 1], "y")
                i += 2
                mouse.write(e.EV_ABS, e.ABS_X, x)
                mouse.write(e.EV_ABS, e.ABS_Y, y)
                mouse.syn()
            elif cmd == "click":
                button = e.BTN_LEFT
                if i < len(argv) and argv[i] in BUTTONS:
                    button = BUTTONS[argv[i]]
                    i += 1
                mouse = mouse or make_mouse()
                tap(mouse, button)
            elif cmd == "scroll":
                if i >= len(argv):
                    sys.exit("scroll: missing count")
                mouse = mouse or make_mouse()
                try:
                    n = int(argv[i])
                except ValueError:
                    sys.exit(f"scroll: expected an integer, got {argv[i]}")
                i += 1
                emit(mouse, e.EV_REL, e.REL_WHEEL, n)
            else:
                sys.exit(f"unknown command: {cmd}")
        return 0
    finally:
        if mouse:
            mouse.close()
        if kbd:
            kbd.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
