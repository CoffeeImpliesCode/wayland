//! Raylib input source (M3): feeds the seat from the raylib window.
//!
//! The raylib backend calls the poll hook after PollInputEvents in every
//! commit (server-side wiring: RaylibBackend.setInputHook). The poll reads
//! the current raylib keyboard/mouse state and translates it into seat
//! events: xkb keycodes (raylib's KEY_* codes are GLFW-style, so a fixed
//! table maps them to evdev scancodes + 8), pointer motion in window
//! coordinates (= output coordinates), buttons and the mouse wheel.
//!
//! Key repeat is intentionally not synthesized in M3 (the seat advertises
//! repeat_info(0,0)); raylib's IsKeyPressed fires once per physical press.
//!
//! Imports: the "wayland" library module and the translated raylib C
//! bindings ("raylib_c", wired in build.zig when -Denable_raylib).

const std = @import("std");
const seat_mod = @import("../compositor/seat.zig");
const xkb_mod = @import("../compositor/xkb.zig");
const raylib = @import("raylib_c");

/// raylib KEY_* -> xkb keycode (evdev scancode + 8). Printable ASCII keys
/// map by table below; raylib uses GLFW-style codes for the rest.
const Entry = struct { raylib_key: c_int, xkb: xkb_mod.Keycode };

// Letters: raylib KEY_A..KEY_Z = 65..90.
const letters = [_]Entry{
    .{ .raylib_key = 65, .xkb = 38 }, // a
    .{ .raylib_key = 66, .xkb = 56 }, // b
    .{ .raylib_key = 67, .xkb = 54 }, // c
    .{ .raylib_key = 68, .xkb = 40 }, // d
    .{ .raylib_key = 69, .xkb = 26 }, // e
    .{ .raylib_key = 70, .xkb = 41 }, // f
    .{ .raylib_key = 71, .xkb = 42 }, // g
    .{ .raylib_key = 72, .xkb = 43 }, // h
    .{ .raylib_key = 73, .xkb = 31 }, // i
    .{ .raylib_key = 74, .xkb = 44 }, // j
    .{ .raylib_key = 75, .xkb = 45 }, // k
    .{ .raylib_key = 76, .xkb = 46 }, // l
    .{ .raylib_key = 77, .xkb = 58 }, // m
    .{ .raylib_key = 78, .xkb = 57 }, // n
    .{ .raylib_key = 79, .xkb = 32 }, // o
    .{ .raylib_key = 80, .xkb = 33 }, // p
    .{ .raylib_key = 81, .xkb = 24 }, // q
    .{ .raylib_key = 82, .xkb = 27 }, // r
    .{ .raylib_key = 83, .xkb = 39 }, // s
    .{ .raylib_key = 84, .xkb = 28 }, // t
    .{ .raylib_key = 85, .xkb = 30 }, // u
    .{ .raylib_key = 86, .xkb = 55 }, // v
    .{ .raylib_key = 87, .xkb = 25 }, // w
    .{ .raylib_key = 88, .xkb = 53 }, // x
    .{ .raylib_key = 89, .xkb = 29 }, // y
    .{ .raylib_key = 90, .xkb = 52 }, // z
};

// Digits: raylib KEY_0..KEY_9 = 48..57; evdev KEY_1=2 -> xkb 10 ... KEY_0=11 -> xkb 19.
const digits = [_]Entry{
    .{ .raylib_key = 48, .xkb = 19 }, // 0
    .{ .raylib_key = 49, .xkb = 10 }, // 1
    .{ .raylib_key = 50, .xkb = 11 }, // 2
    .{ .raylib_key = 51, .xkb = 12 }, // 3
    .{ .raylib_key = 52, .xkb = 13 }, // 4
    .{ .raylib_key = 53, .xkb = 14 }, // 5
    .{ .raylib_key = 54, .xkb = 15 }, // 6
    .{ .raylib_key = 55, .xkb = 16 }, // 7
    .{ .raylib_key = 56, .xkb = 17 }, // 8
    .{ .raylib_key = 57, .xkb = 18 }, // 9
};

// Specials: raylib GLFW-style codes -> xkb.
const specials = [_]Entry{
    .{ .raylib_key = 32, .xkb = 65 }, // space
    .{ .raylib_key = 256, .xkb = 9 }, // escape
    .{ .raylib_key = 257, .xkb = 36 }, // enter
    .{ .raylib_key = 258, .xkb = 23 }, // tab
    .{ .raylib_key = 259, .xkb = 22 }, // backspace
    .{ .raylib_key = 261, .xkb = 119 }, // delete
    .{ .raylib_key = 262, .xkb = 114 }, // right
    .{ .raylib_key = 263, .xkb = 113 }, // left
    .{ .raylib_key = 264, .xkb = 116 }, // down
    .{ .raylib_key = 265, .xkb = 111 }, // up
    .{ .raylib_key = 266, .xkb = 112 }, // page up
    .{ .raylib_key = 267, .xkb = 117 }, // page down
    .{ .raylib_key = 268, .xkb = 110 }, // home
    .{ .raylib_key = 269, .xkb = 115 }, // end
    .{ .raylib_key = 280, .xkb = 66 }, // caps lock
    .{ .raylib_key = 281, .xkb = 78 }, // scroll lock
    .{ .raylib_key = 282, .xkb = 77 }, // num lock
    .{ .raylib_key = 290, .xkb = 67 }, // F1
    .{ .raylib_key = 291, .xkb = 68 }, // F2
    .{ .raylib_key = 292, .xkb = 69 }, // F3
    .{ .raylib_key = 293, .xkb = 70 }, // F4
    .{ .raylib_key = 294, .xkb = 71 }, // F5
    .{ .raylib_key = 295, .xkb = 72 }, // F6
    .{ .raylib_key = 296, .xkb = 73 }, // F7
    .{ .raylib_key = 297, .xkb = 74 }, // F8
    .{ .raylib_key = 298, .xkb = 75 }, // F9
    .{ .raylib_key = 299, .xkb = 76 }, // F10
    .{ .raylib_key = 300, .xkb = 95 }, // F11
    .{ .raylib_key = 301, .xkb = 96 }, // F12
    .{ .raylib_key = 340, .xkb = 50 }, // left shift
    .{ .raylib_key = 341, .xkb = 37 }, // left control
    .{ .raylib_key = 342, .xkb = 64 }, // left alt
    .{ .raylib_key = 343, .xkb = 133 }, // left super
    .{ .raylib_key = 344, .xkb = 62 }, // right shift
    .{ .raylib_key = 345, .xkb = 105 }, // right control
    .{ .raylib_key = 346, .xkb = 108 }, // right alt
    .{ .raylib_key = 347, .xkb = 134 }, // right super
    .{ .raylib_key = 39, .xkb = 48 }, // apostrophe '
    .{ .raylib_key = 44, .xkb = 59 }, // comma ,
    .{ .raylib_key = 45, .xkb = 20 }, // minus -
    .{ .raylib_key = 46, .xkb = 60 }, // period .
    .{ .raylib_key = 47, .xkb = 61 }, // slash /
    .{ .raylib_key = 59, .xkb = 47 }, // semicolon ;
    .{ .raylib_key = 61, .xkb = 21 }, // equal =
    .{ .raylib_key = 91, .xkb = 34 }, // left bracket [
    .{ .raylib_key = 92, .xkb = 51 }, // backslash \
    .{ .raylib_key = 93, .xkb = 35 }, // right bracket ]
    .{ .raylib_key = 96, .xkb = 49 }, // grave `
    .{ .raylib_key = 260, .xkb = 118 }, // insert
    .{ .raylib_key = 348, .xkb = 135 }, // menu
    .{ .raylib_key = 320, .xkb = 90 }, // keypad 0
    .{ .raylib_key = 321, .xkb = 87 }, // keypad 1
    .{ .raylib_key = 322, .xkb = 88 }, // keypad 2
    .{ .raylib_key = 323, .xkb = 89 }, // keypad 3
    .{ .raylib_key = 324, .xkb = 83 }, // keypad 4
    .{ .raylib_key = 325, .xkb = 84 }, // keypad 5
    .{ .raylib_key = 326, .xkb = 85 }, // keypad 6
    .{ .raylib_key = 327, .xkb = 79 }, // keypad 7
    .{ .raylib_key = 328, .xkb = 80 }, // keypad 8
    .{ .raylib_key = 329, .xkb = 81 }, // keypad 9
    .{ .raylib_key = 330, .xkb = 91 }, // keypad .
    .{ .raylib_key = 331, .xkb = 106 }, // keypad /
    .{ .raylib_key = 332, .xkb = 63 }, // keypad *
    .{ .raylib_key = 333, .xkb = 82 }, // keypad -
    .{ .raylib_key = 334, .xkb = 86 }, // keypad +
    .{ .raylib_key = 335, .xkb = 104 }, // keypad enter
    .{ .raylib_key = 336, .xkb = 125 }, // keypad =
};

/// The raylib input poll hook: reads raylib input state and feeds the
/// seat. `ctx` is the RaylibInput (see poll below).
pub const RaylibInput = struct {
    seat: *seat_mod.Seat,
    /// Per-key poll state, persistent across polls (the arrays would
    /// reset every call otherwise and the release debounce could never
    /// confirm — keys stuck down forever).
    prev_down: [512]bool = [_]bool{false} ** 512,
    pending_up: [512]bool = [_]bool{false} ** 512,
    release_age: [512]u8 = [_]u8{255} ** 512,
};

pub fn create(allocator: std.mem.Allocator, seat: *seat_mod.Seat) error{OutOfMemory}!*RaylibInput {
    const input = try allocator.create(RaylibInput);
    input.* = .{ .seat = seat };
    return input;
}

/// Poll hook called from the wire-loop poll timer (raylib backend). Feed
/// the seat + return whether anything changed (the caller then requests a
/// render). Called outside the render, so the events flush on the next
/// frame's pointerFrame().
pub fn poll(ctx: *anyopaque) bool {
    const input: *RaylibInput = @ptrCast(@alignCast(ctx));
    const seat = input.seat;
    var fed = false;

    // Key state is diffed against the seat's pressed set (single source of
    // truth), NOT raylib's press/release transitions: the X server's
    // autorepeat emits [release, press] pairs ~5ms apart which GLFW 3.4
    // discards only when both are already queued (x11_window.c KeyRelease
    // peek); a split socket read leaks both as real transitions, leaving
    // keys stuck or dropped. A press is fed when the seat does not hold the
    // key AND no release was fed for it within the last two polls (a
    // delayed autorepeat press cannot re-arm the seat); a release needs the
    // key up for a full poll window (autorepeat releases are momentary).
    // The seat's repeat timer feeds held-key repeats. The per-key arrays
    // live in the input struct: they must survive across polls.
    inline for (.{ letters, digits, specials }) |table| {
        for (table) |e| {
            const down = raylib.IsKeyDown(e.raylib_key);
            const key_idx: usize = @intCast(e.raylib_key);
            if (down) {
                if (!seat.isKeyDown(e.xkb) and input.release_age[key_idx] >= 2) {
                    seat.keyEvent(e.xkb, true);
                    fed = true;
                }
                input.pending_up[key_idx] = false;
            } else if (seat.isKeyDown(e.xkb)) {
                if (input.prev_down[key_idx] and !input.pending_up[key_idx]) {
                    input.pending_up[key_idx] = true;
                } else if (!input.prev_down[key_idx] and input.pending_up[key_idx]) {
                    input.pending_up[key_idx] = false;
                    input.release_age[key_idx] = 0;
                    seat.keyEvent(e.xkb, false);
                    fed = true;
                }
            }
            input.prev_down[key_idx] = down;
            if (input.release_age[key_idx] < 255) input.release_age[key_idx] += 1;
        }
    }

    const pos = raylib.GetMousePosition();
    const px: i32 = @intFromFloat(@round(pos.x));
    const py: i32 = @intFromFloat(@round(pos.y));
    if (px != seat.pointer_x or py != seat.pointer_y) {
        seat.pointerMotion(px, py);
        fed = true;
    }

    inline for (.{ 0, 1, 2 }) |b| {
        if (raylib.IsMouseButtonPressed(b)) {
            seat.pointerButton(@intCast(seat_mod.btn_left + b), true);
            fed = true;
        }
        if (raylib.IsMouseButtonReleased(b)) {
            seat.pointerButton(@intCast(seat_mod.btn_left + b), false);
            fed = true;
        }
    }

    const wheel = raylib.GetMouseWheelMove();
    if (wheel != 0) {
        // raylib wheel is f32 (fractional on high-res wheels); clamp to a
        // sane notch range before the lossy cast (zbc: no unbounded casts).
        const notches: i32 = @intFromFloat(@min(@max(wheel, -100.0), 100.0));
        seat.pointerAxis(.vertical_scroll, .wheel, wheel * 10.0, notches);
        fed = true;
    }
    return fed;
}
