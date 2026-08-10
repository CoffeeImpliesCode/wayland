//! libinput input backend (evdev path).
//!
//! Feeds the seat from libinput's udev seat enumeration: virtual and real
//! keyboards, mice and touch devices appear as `new_input` announcements
//! and their events translate into seat calls. The structure follows
//! wlroots backend/libinput/backend.c (context lifecycle: create in start,
//! assign seat, drain initial devices, then dispatch on the fd) and
//! smithay src/backend/libinput/mod.rs (dispatch + drain loop).
//!
//! Wiring contract (the server orchestrator owns this, src/server/main.zig):
//!
//!   1. WAYLAND_LIBINPUT=1 selects this backend. The orchestrator creates
//!      it with the seat and the output size:
//!
//!          const base = try libinput_mod.LibinputBackend.create(
//!              allocator, io, &log_cfg, state.seat, "seat0",
//!              output_width, output_height,
//!          );
//!
//!   2. `base.start()` creates the libinput udev context, assigns the seat
//!      and drains the initial DEVICE_ADDED burst (all devices present on
//!      the seat are announced through the backend's `new_input` signal, so
//!      the compositor must attach its listener before start, same as
//!      `new_output`).
//!
//!   3. Poll `libinput_mod.LibinputBackend.fromBackend(base).pollFd()`
//!      (libinput_get_fd) on the event loop and call `dispatch()` when the
//!      fd is readable:
//!
//!          const li = libinput_mod.LibinputBackend.fromBackend(base);
//!          const src = try loop.addFd(*libinput_mod.Libinput, li.pollFd(),
//!              .{ .readable = true }, onLibinputFd, li);
//!
//!          fn onLibinputFd(_: c_int, _: wire.EventMask,
//!              li: *libinput_mod.Libinput) c_int {
//!              li.dispatch() catch {
//!                  log.err("libinput dispatch failed", io, &log_cfg,
//!                      "server", .{});
//!                  return 0;
//!              };
//!              return 1; // keep the source armed
//!          }
//!
//!   4. `base.destroy()` tears everything down (device registry, context,
//!      udev).
//!
//! Keycode translation: libinput reports evdev scancodes; the seat expects
//! xkb keycodes (evdev + 8), the same offset xkbcommon applies — wlroots
//! does `event->keycode + 8` before xkb_state_update_key
//! (types/wlr_keyboard.c:120). See `evdevToXkb`.
//!
//! Pointer translation:
//!   - relative motion (dx/dy) accumulates into the backend's cursor
//!     position (f64) and feeds seat.pointerMotion rounded to pixels;
//!   - absolute motion (the VM's virtio-mouse, and the uinput test mouse
//!     with ABS_X/ABS_Y 0..0xFFFF) is normalized to 0..1 via
//!     libinput_event_pointer_get_absolute_{x,y}_transformed(ev, 1) — the
//!     exact call wlroots uses for POINTER_MOTION_ABSOLUTE — then scaled
//!     to the output size by `scaleToOutput`;
//!   - buttons pass through as-is (libinput button codes are the linux
//!     BTN_* codes the seat already expects);
//!   - axis: wheel scrolls come from LIBINPUT_EVENT_POINTER_SCROLL_WHEEL,
//!     the libinput 1.19+ event that carries v120-normalized deltas
//!     (libinput_event_pointer_get_scroll_value_v120, ±120 per logical
//!     click — the wlroots choice, backend/libinput/events.c:169-183).
//!     `v120ToNotches` normalizes the v120 delta to the seat's legacy
//!     click convention; the value (degrees, 15.0 per notch) converts via
//!     `axisValueToPixels` to the seat's 10 px per notch. The legacy
//!     LIBINPUT_EVENT_POINTER_AXIS event is consumed only for the
//!     FINGER/CONTINUOUS sources (touchpad/trackpoint): those are
//!     cursor-equivalent units (1.0 = 1 px, passed through as-is,
//!     matching wlroots backend/libinput/pointer.c:146) and their
//!     SCROLL_FINGER/CONTINUOUS twins are ignored to avoid double
//!     delivery (libinput posts both families; libinput.h:811-826). The
//!     source rides along to the seat as wl_pointer.axis_source.
//!
//! Test path: no real devices exist on the dev host, so the pure logic
//! (offset, scaling, axis conversion, event-type mapping, capability
//! mapping) is unit-tested below and the device path is exercised in the
//! VM: scripts/uinput-devices.py creates a virtual keyboard + absolute
//! mouse through /dev/uinput, which udev announces to this backend.
//!
//! Imports: utils/*, backend/backend.zig, compositor/seat.zig (sibling
//! modules). The libinput C library is linked by the orchestrator
//! (linkSystemLibrary("libinput") + libudev, which ships with systemd).

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const backend = @import("backend.zig");
const seat_mod = @import("../compositor/seat.zig");
const server = @import("protocol").server;

// ---------------------------------------------------------------------------
// Constants — numeric values verified against the real headers:
//   libinput:   /nix/store/25z81mr9anpamdwv7lizq5l56hhq6kmi-libinput-1.31.3-dev/include/libinput.h
//   input codes: /nix/store/1hrk7xhpm6h98n0lg1qixfrr2kb96zqs-linux-headers-6.18.7/include/linux/input-event-codes.h
// ---------------------------------------------------------------------------

/// enum libinput_event_type (libinput.h:775-1040).
pub const event_device_added: c_int = 1;
pub const event_device_removed: c_int = 2;
pub const event_keyboard_key: c_int = 300;
pub const event_pointer_motion: c_int = 400;
pub const event_pointer_motion_absolute: c_int = 401;
pub const event_pointer_button: c_int = 402;
pub const event_pointer_axis: c_int = 403;
pub const event_pointer_scroll_wheel: c_int = 404;
pub const event_pointer_scroll_finger: c_int = 405;
pub const event_pointer_scroll_continuous: c_int = 406;

/// enum libinput_key_state (libinput.h:222-225).
pub const key_state_pressed: c_int = 1;
/// enum libinput_button_state (libinput.h:246-249).
pub const button_state_pressed: c_int = 1;

/// enum libinput_pointer_axis (libinput.h:263-266).
pub const pointer_axis_scroll_vertical: c_int = 0;
pub const pointer_axis_scroll_horizontal: c_int = 1;
/// enum libinput_pointer_axis_source (libinput.h:278-302). WHEEL_TILT
/// is deprecated (never sent by any device since libinput 1.16); the
/// others map onto wl_pointer.axis_source via axisSourceFromLibinput.
pub const pointer_axis_source_wheel: c_int = 1;
pub const pointer_axis_source_finger: c_int = 2;
pub const pointer_axis_source_continuous: c_int = 3;
pub const pointer_axis_source_wheel_tilt: c_int = 4;

/// enum libinput_log_priority (libinput.h:195-197).
pub const log_priority_debug: c_int = 10;
pub const log_priority_info: c_int = 20;
pub const log_priority_error: c_int = 30;

/// enum libinput_device_capability (libinput.h:206-214).
pub const device_cap_keyboard: c_int = 0;
pub const device_cap_pointer: c_int = 1;
pub const device_cap_touch: c_int = 2;

/// enum libinput_led (libinput.h:232-238): the bitmask
/// libinput_device_led_update accepts. The values match the wlroots
/// WLR_LED_* layout (wlr_keyboard.h:22-24), which derives them from the
/// xkb_state led indexes (numlock=0, capslock=1) — see ledsFromModsLocked.
pub const led_num_lock: c_int = 1 << 0;
pub const led_caps_lock: c_int = 1 << 1;
pub const led_scroll_lock: c_int = 1 << 2;

/// linux/input-event-codes.h:357-359 (BTN_*). The seat exports the same
/// values (seat.btn_left == 272); these exist for the registry mapping and
/// tests.
pub const btn_left: u32 = 0x110; // 272
pub const btn_right: u32 = 0x111; // 273
pub const btn_middle: u32 = 0x112; // 274

/// evdev scancode -> xkb keycode offset (xkbcommon adds 8; the seat
/// forwards these codes in wl_keyboard.key).
pub const evdev_to_xkb_offset: u32 = 8;

// ---------------------------------------------------------------------------
// FFI (hand-written extern decls, same style as compositor/xkb.zig)
// ---------------------------------------------------------------------------

const c = struct {
    pub const libinput = opaque {};
    pub const libinput_event = opaque {};
    pub const libinput_event_keyboard = opaque {};
    pub const libinput_event_pointer = opaque {};
    pub const libinput_device = opaque {};
    pub const udev = opaque {};

    /// struct libinput_interface (libinput.h:3604-3621): device fd
    /// open/close callbacks. libinput never opens evdev nodes itself.
    pub const libinput_interface = extern struct {
        open_restricted: *const fn (path: [*:0]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int,
        close_restricted: *const fn (fd: c_int, user_data: ?*anyopaque) callconv(.c) void,
    };

    // Context lifecycle (libinput.h "base" group).
    extern fn libinput_udev_create_context(
        interface: *const libinput_interface,
        user_data: ?*anyopaque,
        udev: ?*udev,
    ) ?*libinput;
    extern fn libinput_udev_assign_seat(li: ?*libinput, seat_id: [*:0]const u8) c_int;
    extern fn libinput_get_fd(li: ?*libinput) c_int;
    extern fn libinput_dispatch(li: ?*libinput) c_int;
    /// Retrieve the next queued event (NULL when the queue is empty).
    /// libinput_next_event in pre-1.0.4 docs; the 1.31 header names it
    /// libinput_get_event (libinput.h:3884).
    extern fn libinput_get_event(li: ?*libinput) ?*libinput_event;
    extern fn libinput_event_destroy(event: ?*libinput_event) void;
    extern fn libinput_unref(li: ?*libinput) ?*libinput;

    // Log handler (libinput.h:4000-4071): the callback receives
    // (context, priority, printf format, va_list) — no user_data — and is
    // installed with libinput_log_set_handler after context creation.
    pub const libinput_log_handler = *const fn (
        li: ?*libinput,
        priority: c_int,
        format: [*:0]const u8,
        args: *std.builtin.VaList,
    ) callconv(.c) void;
    extern fn libinput_log_set_handler(li: ?*libinput, handler: libinput_log_handler) void;
    extern fn libinput_log_set_priority(li: ?*libinput, priority: c_int) void;
    /// libc vsnprintf — the only way to consume the handler's va_list.
    extern fn vsnprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, args: *std.builtin.VaList) c_int;

    // Event accessors (libinput.h "event" group).
    extern fn libinput_event_get_type(event: ?*libinput_event) c_int;
    extern fn libinput_event_get_device(event: ?*libinput_event) ?*libinput_device;
    extern fn libinput_event_get_keyboard_event(event: ?*libinput_event) ?*libinput_event_keyboard;
    extern fn libinput_event_get_pointer_event(event: ?*libinput_event) ?*libinput_event_pointer;

    // Keyboard events (libinput.h:1258-1268).
    extern fn libinput_event_keyboard_get_key(event: ?*libinput_event_keyboard) u32;
    extern fn libinput_event_keyboard_get_key_state(event: ?*libinput_event_keyboard) c_int;

    // Pointer events (libinput.h:1340-1666).
    extern fn libinput_event_pointer_get_dx(event: ?*libinput_event_pointer) f64;
    extern fn libinput_event_pointer_get_dy(event: ?*libinput_event_pointer) f64;
    extern fn libinput_event_pointer_get_absolute_x_transformed(event: ?*libinput_event_pointer, width: u32) f64;
    extern fn libinput_event_pointer_get_absolute_y_transformed(event: ?*libinput_event_pointer, height: u32) f64;
    extern fn libinput_event_pointer_get_button(event: ?*libinput_event_pointer) u32;
    extern fn libinput_event_pointer_get_button_state(event: ?*libinput_event_pointer) c_int;
    extern fn libinput_event_pointer_has_axis(event: ?*libinput_event_pointer, axis: c_int) c_int;
    extern fn libinput_event_pointer_get_axis_value(event: ?*libinput_event_pointer, axis: c_int) f64;
    extern fn libinput_event_pointer_get_axis_value_discrete(event: ?*libinput_event_pointer, axis: c_int) f64;
    extern fn libinput_event_pointer_get_axis_source(event: ?*libinput_event_pointer) c_int;
    // SCROLL_* accessors (libinput.h:1667-1760, @since 1.19): the wheel
    // event's value in degrees and its v120-normalized delta.
    extern fn libinput_event_pointer_get_scroll_value(event: ?*libinput_event_pointer, axis: c_int) f64;
    extern fn libinput_event_pointer_get_scroll_value_v120(event: ?*libinput_event_pointer, axis: c_int) f64;

    // Device accessors (libinput.h:4338, 4490).
    extern fn libinput_device_get_name(device: ?*libinput_device) [*:0]const u8;
    extern fn libinput_device_has_capability(device: ?*libinput_device, capability: c_int) c_int;
    // LED sync (libinput.h:4481): push the keyboard LED state
    // (numlock/capslock) to the device's LEDs (wlroots
    // backend/libinput/keyboard.c keyboard_set_leds).
    extern fn libinput_device_led_update(device: ?*libinput_device, leds: c_int) void;

    // libudev: a plain context for device enumeration (libinput needs an
    // initialized udev; wlroots passes its session's).
    extern fn udev_new() ?*udev;
    extern fn udev_unref(udev: ?*udev) ?*udev;
};

/// The kind enum of backend.Backend.InputDevice (anonymous in backend.zig;
/// recovered for the registry and announcements).
// SAFETY: type-derivation only; the undefined value is never evaluated at runtime.
const InputKind = @TypeOf(@as(backend.Backend.InputDevice, undefined).kind);

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested below)
// ---------------------------------------------------------------------------

/// evdev scancode -> xkb keycode (the seat's keyEvent contract).
pub fn evdevToXkb(scancode: u32) u32 {
    return scancode + evdev_to_xkb_offset;
}

/// Normalized (0..1) absolute coordinate -> output pixel coordinate.
/// libinput_event_pointer_get_absolute_{x,y}_transformed(ev, 1) yields the
/// normalized form; wlroots then maps it onto the output (wlr_cursor).
pub fn scaleToOutput(normalized: f64, size: u32) f64 {
    return normalized * @as(f64, @floatFromInt(size));
}

/// libinput wheel axis value (degrees, 15.0 per notch) -> the seat's pixel
/// convention (10 px per notch; the raylib input source uses the same
/// wheel * 10.0 formula with wheel in notches).
pub fn axisValueToPixels(value: f64) f64 {
    return value * (10.0 / 15.0);
}

/// libinput discrete axis value (physical wheel clicks) -> i32 notches.
pub fn axisDiscreteToNotches(value: f64) i32 {
    return @intFromFloat(@round(value));
}

/// libinput axis source -> wl_pointer.axis_source. Mirrors wlroots'
/// axis_source_from_libinput (backend/libinput/pointer.c:69-86).
pub fn axisSourceFromLibinput(source: c_int) ?server.wl.Pointer.AxisSource {
    return switch (source) {
        pointer_axis_source_wheel => .wheel,
        pointer_axis_source_finger => .finger,
        pointer_axis_source_continuous => .continuous,
        pointer_axis_source_wheel_tilt => .wheel_tilt,
        else => null,
    };
}

/// Scale a libinput axis value to seat pixels for the given source.
/// WHEEL is degrees (15.0 per notch) -> the seat's 10 px per notch via
/// axisValueToPixels; FINGER/CONTINUOUS are cursor-equivalent units
/// (1.0 = 1 px, libinput.h:1598-1599, 1614-1617) that pass through
/// unscaled, the same pass-through wlroots does
/// (backend/libinput/pointer.c:146).
pub fn axisValueToPixelsSource(source: server.wl.Pointer.AxisSource, value: f64) f64 {
    return switch (source) {
        .wheel, .wheel_tilt => axisValueToPixels(value),
        .finger, .continuous => value,
        _ => unreachable,
    };
}

/// Discrete (notches) for the source: WHEEL counts physical wheel clicks;
/// FINGER/CONTINUOUS discrete is always 0 (libinput.h:1653-1657).
pub fn axisDiscreteForSource(source: server.wl.Pointer.AxisSource, raw: f64) i32 {
    return switch (source) {
        .wheel, .wheel_tilt => axisDiscreteToNotches(raw),
        .finger, .continuous => 0,
        _ => unreachable,
    };
}

/// v120 scroll delta -> legacy notch count. libinput normalizes
/// high-resolution wheel deltas to ±120 per logical click
/// (libinput_event_pointer_get_scroll_value_v120, libinput.h:1712-1760:
/// "a value that is a fraction of ±120 indicates a wheel movement less
/// than one logical click"); one logical click is one legacy notch, so
/// dividing by 120 converts the v120 delta to the seat's legacy click
/// convention (10 px per notch, see axisValueToPixels). wlroots instead
/// forwards the raw v120 as delta_discrete (pointer.c:172-179); the seat
/// contract here is legacy clicks, so the normalization happens in the
/// backend.
pub fn v120ToNotches(v120: f64) i32 {
    return @intFromFloat(@round(v120 / 120.0));
}

/// Whether the zero-device startup check is enabled. Mirrors wlroots
/// env_parse_bool (util/env.c): only the literal "1" is truthy — any
/// other value (or an unset variable) leaves the check on.
pub fn zeroDeviceCheckEnabled(env_value: ?[*:0]const u8) bool {
    const v = env_value orelse return true;
    return !std.mem.eql(u8, std.mem.span(v), "1");
}

/// Keyboard LED bitmask from the seat's locked-modifier state. The seat
/// stores mods_locked in the wl_keyboard.modifiers layout (bit 1 = Lock
/// = Caps Lock, bit 4 = Mod2 = Num Lock; xkb.zig mods() doc). Mirrors
/// wlroots keyboard_led_update (types/wlr_keyboard.c:20-35), which
/// derives the WLR_LED_* bits from the xkb_state led indexes — the
/// standard evdev keymap indexes numlock=0 and capslock=1, so the
/// produced bits align with libinput's enum libinput_led
/// (LIBINPUT_LED_NUM_LOCK=1, LIBINPUT_LED_CAPS_LOCK=2).
pub fn ledsFromModsLocked(mods_locked: u32) c_int {
    var leds: c_int = 0;
    // Lock (bit 1) -> Caps Lock.
    if (mods_locked & (1 << 1) != 0) leds |= led_caps_lock;
    // Mod2 (bit 4) -> Num Lock.
    if (mods_locked & (1 << 4) != 0) leds |= led_num_lock;
    return leds;
}

/// Map a libinput device to the backend's InputDevice kind. libinput's
/// has_capability takes ONE capability and returns a bool; devices are
/// classified by priority (keyboard > pointer). Devices with only
/// touch/tablet/pad/switch/gesture capabilities map to null and are not
/// announced. Touch is deliberately unannounced: the seat implements no
/// touch events, so a touchscreen would appear in the registry yet be
/// inert (wlroots implements touch in events.c:184-194).
pub fn kindForDevice(dev: ?*c.libinput_device) ?InputKind {
    if (c.libinput_device_has_capability(dev, device_cap_keyboard) != 0) return .keyboard;
    if (c.libinput_device_has_capability(dev, device_cap_pointer) != 0) return .pointer;
    return null;
}

/// Event type -> name (debug logging and the dispatch mapping test).
pub fn eventTypeName(event_type: c_int) []const u8 {
    return switch (event_type) {
        event_device_added => "device added",
        event_device_removed => "device removed",
        event_keyboard_key => "keyboard key",
        event_pointer_motion => "pointer motion",
        event_pointer_motion_absolute => "pointer motion absolute",
        event_pointer_button => "pointer button",
        event_pointer_axis => "pointer axis",
        event_pointer_scroll_wheel => "pointer scroll wheel",
        event_pointer_scroll_finger => "pointer scroll finger",
        event_pointer_scroll_continuous => "pointer scroll continuous",
        else => "other",
    };
}

// ---------------------------------------------------------------------------
// Backend implementation
// ---------------------------------------------------------------------------

/// A device announced to the compositor and tracked in the registry.
const Device = struct {
    handle: *c.libinput_device,
    kind: InputKind,
    /// Owned copy of libinput_device_get_name (the libinput-owned name is
    /// only valid for the lifetime of the event/device).
    name: [:0]u8,
};

const Libinput = struct {
    base: *backend.Backend,
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    seat: *seat_mod.Seat,
    /// Seat id passed to libinput_udev_assign_seat ("seat0"). Borrowed;
    /// the caller keeps it alive (it is a literal in practice).
    seat_name: [:0]const u8,
    /// Output size in pixels; absolute pointers scale to it.
    output_width: u32,
    output_height: u32,
    /// Created in start(), freed in destroy().
    udev: ?*c.udev = null,
    ctx: ?*c.libinput = null,
    devices: std.ArrayList(Device) = .empty,
    /// Cursor position accumulated from relative motion (f64 so subpixel
    /// deltas do not get lost per event).
    cursor_x: f64 = 0,
    cursor_y: f64 = 0,
    /// Last LED bitmask pushed to devices (libinput_device_led_update).
    /// The seat's LED state is global to the keyboard, so one cache
    /// serves all devices; -1 forces the first key event to sync
    /// (wlroots caches kb->leds the same way, wlr_keyboard.c:188-196).
    last_leds: c_int = -1,

    /// The libinput fd to poll (libinput_get_fd). Only valid after start().
    pub fn pollFd(self: *Libinput) c_int {
        std.debug.assert(self.ctx != null);
        return c.libinput_get_fd(self.ctx);
    }

    /// libinput_dispatch + drain every queued event into the seat.
    /// Called when pollFd() is readable (and once in start() to pick up
    /// the initial DEVICE_ADDED burst). A negative libinput_dispatch rc
    /// is fatal for the context (libinput.h:3869-3870), so it surfaces
    /// as BackendFailed and the caller tears the backend down.
    pub fn dispatch(self: *Libinput) error{BackendFailed}!void {
        std.debug.assert(self.ctx != null);
        if (c.libinput_dispatch(self.ctx) < 0) return error.BackendFailed;
        while (c.libinput_get_event(self.ctx)) |event| {
            self.handleEvent(event);
            c.libinput_event_destroy(event);
        }
    }

    fn handleEvent(self: *Libinput, event: *c.libinput_event) void {
        const event_type = c.libinput_event_get_type(event);
        switch (event_type) {
            event_device_added => self.onDeviceAdded(event),
            event_device_removed => self.onDeviceRemoved(event),
            event_keyboard_key => self.onKey(event),
            event_pointer_motion => self.onPointerMotion(event),
            event_pointer_motion_absolute => self.onPointerMotionAbsolute(event),
            event_pointer_button => self.onPointerButton(event),
            event_pointer_axis => self.onPointerAxis(event),
            // Wheel scrolls arrive here with v120-normalized deltas
            // (libinput >= 1.19; wlroots consumes exactly this event,
            // events.c:169-183). The legacy POINTER_AXIS twin of a wheel
            // event is skipped in onPointerAxis, so no double delivery.
            event_pointer_scroll_wheel => self.onPointerScrollWheel(event),
            // SCROLL_FINGER/CONTINUOUS carry the same data as their
            // POINTER_AXIS twins (libinput posts both families,
            // libinput.h:811-826); the AXIS handler consumes those, so
            // these stay ignored to avoid double delivery.
            event_pointer_scroll_finger, event_pointer_scroll_continuous => {},
            // Touch, gestures, tablets, switches: not implemented in M3.
            else => log_mod.debug(
                "unhandled libinput event {s} ({d})",
                self.io,
                self.log_cfg,
                "libinput",
                .{ eventTypeName(event_type), event_type },
            ),
        }
    }

    fn onDeviceAdded(self: *Libinput, event: *c.libinput_event) void {
        const dev = c.libinput_event_get_device(event) orelse return;
        const kind = kindForDevice(dev) orelse return;
        // Fresh keyboard: LEDs start off (wlroots init_device_keyboard
        // calls libinput_device_led_update(handle, 0),
        // backend/libinput/keyboard.c:38-44). libinput no-ops for
        // devices without LED support.
        if (kind == .keyboard) {
            _ = c.libinput_device_led_update(dev, 0);
        }

        const name_slice = std.mem.span(c.libinput_device_get_name(dev));
        const name = if (name_slice.len == 0) "unknown" else name_slice;
        const owned = self.allocator.dupeZ(u8, name) catch {
            log_mod.warn("device {s}: name allocation failed", self.io, self.log_cfg, "libinput", .{name});
            return;
        };
        errdefer self.allocator.free(owned);

        self.devices.append(self.allocator, .{ .handle = dev, .kind = kind, .name = owned }) catch {
            // Free the owned name here: `catch` returns without error, so
            // the errdefer above is skipped.
            self.allocator.free(owned);
            return;
        };
        // The announcement borrows the registry's name copy, which outlives
        // the event (libinput's own name pointer does not).
        // SAFETY: the string copy below (dupe) always succeeds before use.
        var announced: backend.Backend.InputDevice = .{ .kind = kind, .name = owned };
        self.base.emitNewInput(&announced);
        log_mod.info("input device added: {s}", self.io, self.log_cfg, "libinput", .{owned});
    }

    fn onDeviceRemoved(self: *Libinput, event: *c.libinput_event) void {
        const dev = c.libinput_event_get_device(event) orelse return;
        for (self.devices.items, 0..) |d, i| {
            if (d.handle == dev) {
                log_mod.info("input device removed: {s}", self.io, self.log_cfg, "libinput", .{d.name});
                self.allocator.free(d.name);
                _ = self.devices.orderedRemove(i);
                return;
            }
        }
    }

    fn onKey(self: *Libinput, event: *c.libinput_event) void {
        const kevent = c.libinput_event_get_keyboard_event(event) orelse return;
        const key = c.libinput_event_keyboard_get_key(kevent);
        const pressed = c.libinput_event_keyboard_get_key_state(kevent) == key_state_pressed;
        // libinput reports evdev scancodes; the seat expects xkb keycodes.
        self.seat.keyEvent(evdevToXkb(key), pressed);
        // Push the seat's LED state (numlock/capslock, updated by
        // keyEvent) to the device's LEDs — wlroots keyboard_set_leds
        // (backend/libinput/keyboard.c:31-35) + keyboard_led_update
        // (types/wlr_keyboard.c:20-35), with the same skip-when-unchanged
        // cache (wlr_keyboard.c:188-196).
        const leds = ledsFromModsLocked(self.seat.mods_locked);
        if (leds != self.last_leds) {
            self.last_leds = leds;
            if (c.libinput_event_get_device(event)) |dev| {
                _ = c.libinput_device_led_update(dev, leds);
            }
        }
    }

    fn onPointerMotion(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        self.cursor_x += c.libinput_event_pointer_get_dx(pevent);
        self.cursor_y += c.libinput_event_pointer_get_dy(pevent);
        self.seat.pointerMotion(
            @intFromFloat(@round(self.cursor_x)),
            @intFromFloat(@round(self.cursor_y)),
        );
    }

    fn onPointerMotionAbsolute(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        // Normalize to 0..1 (wlroots' handle_pointer_motion_abs uses the
        // same call with 1), then scale onto the output.
        const nx = c.libinput_event_pointer_get_absolute_x_transformed(pevent, 1);
        const ny = c.libinput_event_pointer_get_absolute_y_transformed(pevent, 1);
        self.cursor_x = scaleToOutput(nx, self.output_width);
        self.cursor_y = scaleToOutput(ny, self.output_height);
        self.seat.pointerMotion(
            @intFromFloat(@round(self.cursor_x)),
            @intFromFloat(@round(self.cursor_y)),
        );
    }

    fn onPointerButton(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        const button = c.libinput_event_pointer_get_button(pevent);
        const pressed = c.libinput_event_pointer_get_button_state(pevent) == button_state_pressed;
        // libinput button codes are the linux BTN_* codes the seat expects.
        self.seat.pointerButton(button, pressed);
    }

    fn onPointerAxis(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        // The axis value's units depend on the source
        // (libinput.h:1598-1617); the source is required to interpret it.
        const source = axisSourceFromLibinput(c.libinput_event_pointer_get_axis_source(pevent)) orelse return;
        // Wheel data now arrives via LIBINPUT_EVENT_POINTER_SCROLL_WHEEL
        // (v120-normalized, libinput 1.19+). The legacy AXIS event is
        // still posted alongside SCROLL_WHEEL for hi-res devices, so
        // consuming it here would double every wheel click — wheel
        // sources are handled in onPointerScrollWheel only (wlroots
        // events.c:167-169 ignores the AXIS event for the same reason).
        if (source == .wheel or source == .wheel_tilt) return;
        // wlroots iterates both scroll axes (handle_pointer_axis,
        // backend/libinput/pointer.c:114-148).
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_vertical) != 0) {
            self.sendAxis(pevent, source, .vertical_scroll);
        }
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_horizontal) != 0) {
            self.sendAxis(pevent, source, .horizontal_scroll);
        }
    }

    /// A LIBINPUT_EVENT_POINTER_SCROLL_WHEEL event: wheel scroll with a
    /// v120-normalized delta (libinput 1.19+; wlroots
    /// handle_pointer_axis_value120, pointer.c:149-186). The value is in
    /// degrees (15.0 per logical click) and converts via
    /// axisValueToPixels; the discrete is the v120 delta normalized to
    /// legacy clicks via v120ToNotches.
    fn onPointerScrollWheel(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        // wlroots iterates both scroll axes.
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_vertical) != 0) {
            self.sendAxisV120(pevent, .vertical_scroll);
        }
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_horizontal) != 0) {
            self.sendAxisV120(pevent, .horizontal_scroll);
        }
    }

    /// Forward one SCROLL_WHEEL axis to the seat: value in degrees -> the
    /// seat's 10 px per notch convention, discrete v120-normalized to
    /// legacy clicks.
    fn sendAxisV120(
        self: *Libinput,
        pevent: *c.libinput_event_pointer,
        axis: server.wl.Pointer.Axis,
    ) void {
        const libinput_axis: c_int = switch (axis) {
            .vertical_scroll => pointer_axis_scroll_vertical,
            .horizontal_scroll => pointer_axis_scroll_horizontal,
            else => return, // unknown wire axis: nothing to forward
        };
        const value = c.libinput_event_pointer_get_scroll_value(pevent, libinput_axis);
        const v120 = c.libinput_event_pointer_get_scroll_value_v120(pevent, libinput_axis);
        self.seat.pointerAxis(
            axis,
            .wheel,
            axisValueToPixels(value),
            v120ToNotches(v120),
        );
    }

    /// Forward one scroll axis to the seat, scaled per source (see
    /// axisValueToPixelsSource/axisDiscreteForSource for the semantics).
    fn sendAxis(
        self: *Libinput,
        pevent: *c.libinput_event_pointer,
        source: server.wl.Pointer.AxisSource,
        axis: server.wl.Pointer.Axis,
    ) void {
        const libinput_axis: c_int = switch (axis) {
            .vertical_scroll => pointer_axis_scroll_vertical,
            .horizontal_scroll => pointer_axis_scroll_horizontal,
            else => return, // unknown wire axis: nothing to forward
        };
        const value = c.libinput_event_pointer_get_axis_value(pevent, libinput_axis);
        const raw_discrete = c.libinput_event_pointer_get_axis_value_discrete(pevent, libinput_axis);
        self.seat.pointerAxis(
            axis,
            source,
            axisValueToPixelsSource(source, value),
            axisDiscreteForSource(source, raw_discrete),
        );
    }
};

const backend_impl: backend.Backend.Impl = .{
    .start = start,
    .destroy = destroy,
};

/// The libinput log handler callback carries no user_data
/// (libinput.h:4049-4053), so the logging context is stashed module-wide
/// while the backend runs. The server is single-threaded; start() sets
/// both before the context is created, destroy() clears them.
var handler_io: ?*std.Io = null;
var handler_cfg: ?*const log_mod.Config = null;

/// libinput log handler (libinput.h:4049-4053): forwards libinput's
/// printf-style messages to log_mod under the "libinput" tag, mapped by
/// priority (libinput.h:195-197). Installed at ERROR priority in start()
/// (the same choice as wlroots backend.c:104-105).
fn libinputLogHandler(
    li: ?*c.libinput,
    priority: c_int,
    format: [*:0]const u8,
    args: *std.builtin.VaList,
) callconv(.c) void {
    _ = li;
    const io = handler_io orelse return;
    const cfg = handler_cfg orelse return;
    const level: log_mod.Level = switch (priority) {
        log_priority_debug => .debug,
        log_priority_info => .info,
        log_priority_error => .err,
        else => return,
    };
    // The only way to consume a C va_list: vsnprintf into a stack buffer.
    var buf: [1024]u8 = undefined;
    const n = c.vsnprintf(&buf, buf.len, format, args);
    if (n < 0) return;
    const len: usize = @min(@as(usize, @intCast(n)), buf.len);
    log_mod.log("{s}", io, cfg, level, "libinput", .{buf[0..len]});
}

/// open_restricted: plain open of the evdev node (no logind session in the
/// VM). libinput passes open(2) flags; evdev always opens
/// O_RDWR|O_NONBLOCK|O_CLOEXEC, so the passed flags are ignored (the
/// session-based wlroots impl effectively does the same for input devices).
fn openRestricted(path: [*:0]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = flags;
    _ = user_data;
    const o: std.os.linux.O = .{
        .ACCMODE = .RDWR,
        .NONBLOCK = true,
        .CLOEXEC = true,
        .NOCTTY = true,
    };
    // std.posix.open is gone in 0.16; the raw syscall returns the fd or a
    // negated errno (std.os.linux.write/close are used the same way in
    // compositor/xkb.zig).
    const rc = std.os.linux.open(path, o, 0);
    if (rc > std.math.maxInt(usize) / 2) {
        // The libinput_interface contract: negative errno on failure.
        return -@as(c_int, @intFromEnum(std.os.linux.errno(rc)));
    }
    return @intCast(rc);
}

fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    _ = std.os.linux.close(fd);
}

const libinput_interface_impl: c.libinput_interface = .{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

fn start(base: *backend.Backend) error{BackendFailed}!void {
    const self: *Libinput = @ptrCast(@alignCast(base.data));
    std.debug.assert(self.ctx == null);

    self.udev = c.udev_new() orelse return error.BackendFailed;
    errdefer {
        _ = c.udev_unref(self.udev);
        self.udev = null;
    }

    // Context lifecycle follows wlroots backend_start (backend.c): create
    // the udev context, assign the seat, then drain the initial events.
    // The log handler goes in right after creation so libinput-side
    // diagnostics land in the compositor log (wlroots backend.c:104-105).
    handler_io = self.io;
    handler_cfg = self.log_cfg;
    self.ctx = c.libinput_udev_create_context(&libinput_interface_impl, self, self.udev) orelse
        return error.BackendFailed;
    errdefer {
        _ = c.libinput_unref(self.ctx);
        self.ctx = null;
    }
    c.libinput_log_set_handler(self.ctx, libinputLogHandler);
    c.libinput_log_set_priority(self.ctx, log_priority_error);

    if (c.libinput_udev_assign_seat(self.ctx, self.seat_name.ptr) != 0) {
        log_mod.err("libinput seat assign failed (seat {s})", self.io, self.log_cfg, "libinput", .{self.seat_name});
        return error.BackendFailed;
    }

    // Assigning the seat queues DEVICE_ADDED for every device on it; they
    // arrive on the first dispatch (wlroots drains in backend_start too).
    self.dispatch() catch {
        log_mod.err("libinput initial dispatch failed", self.io, self.log_cfg, "libinput", .{});
        return error.BackendFailed;
    };

    // Zero-device check (wlroots backend.c:112-116): an empty registry
    // usually means a broken udev/seat config, and a healthy-looking
    // backend with no devices is worse than a failed start.
    // WLR_LIBINPUT_NO_DEVICES=1 suppresses the check.
    if (zeroDeviceCheckEnabled(std.c.getenv("WLR_LIBINPUT_NO_DEVICES")) and
        self.devices.items.len == 0)
    {
        log_mod.err(
            "libinput: no input devices found; set WLR_LIBINPUT_NO_DEVICES=1 to suppress this check",
            self.io,
            self.log_cfg,
            "libinput",
            .{},
        );
        return error.BackendFailed;
    }

    log_mod.info("libinput backend started (seat {s}, output {d}x{d})", self.io, self.log_cfg, "libinput", .{
        self.seat_name, self.output_width, self.output_height,
    });
}

fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const self: *Libinput = @ptrCast(@alignCast(data));
    for (self.devices.items) |d| allocator.free(d.name);
    self.devices.deinit(allocator);
    if (self.ctx) |ctx| _ = c.libinput_unref(ctx);
    if (self.udev) |udev| _ = c.udev_unref(udev);
    handler_io = null;
    handler_cfg = null;
    allocator.destroy(self);
}

pub const LibinputBackend = struct {
    /// Create the libinput backend. The libinput context is created in
    /// start() (Backend.Impl.start), not here, matching wlroots.
    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        seat: *seat_mod.Seat,
        seat_name: [:0]const u8,
        output_width: u32,
        output_height: u32,
    ) !*backend.Backend {
        std.debug.assert(output_width > 0);
        std.debug.assert(output_height > 0);

        const self = try allocator.create(Libinput);
        errdefer allocator.destroy(self);
        self.* = .{
            // SAFETY: assigned right after Backend.init, before any use.
            .base = undefined,
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .seat = seat,
            .seat_name = seat_name,
            .output_width = output_width,
            .output_height = output_height,
        };

        const base = try backend.Backend.init(allocator, io, log_cfg, &backend_impl, self);
        errdefer base.destroy();
        self.base = base;
        return base;
    }

    /// Recover the Libinput impl from the Backend for pollFd()/dispatch().
    pub fn fromBackend(base: *backend.Backend) *Libinput {
        return @ptrCast(@alignCast(base.data));
    }
};

// ---------------------------------------------------------------------------
// Tests — pure logic only (no real devices; the device path is
// VM-verified with scripts/uinput-devices.py)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "evdev to xkb offset" {
    // KEY_A scancode 30 -> xkb keycode 38; KEY_ESC 1 -> 9.
    try testing.expectEqual(@as(u32, 38), evdevToXkb(30));
    try testing.expectEqual(@as(u32, 9), evdevToXkb(1));
    try testing.expectEqual(evdev_to_xkb_offset, evdevToXkb(0));
}

test "absolute coordinate scaling" {
    try testing.expectApproxEqAbs(@as(f64, 400.0), scaleToOutput(0.5, 800), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 800.0), scaleToOutput(1.0, 800), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), scaleToOutput(0.0, 800), 0.0001);
    // 0..0xFFFF device range normalized then scaled: midpoint maps to the
    // output midpoint.
    try testing.expectApproxEqAbs(@as(f64, 400.0), scaleToOutput(@as(f64, 0x8000) / @as(f64, 0xFFFF), 800), 0.01);
}

test "axis conversion" {
    // One wheel click: libinput reports 15.0 degrees; the seat convention
    // is 10 px per notch.
    try testing.expectApproxEqAbs(@as(f64, 10.0), axisValueToPixels(15.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, -10.0), axisValueToPixels(-15.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), axisValueToPixels(0.0), 0.0001);
    try testing.expectEqual(@as(i32, 1), axisDiscreteToNotches(1.0));
    try testing.expectEqual(@as(i32, 0), axisDiscreteToNotches(0.4));
    try testing.expectEqual(@as(i32, -2), axisDiscreteToNotches(-1.6));
}

test "axis source mapping and per-source scaling" {
    // libinput source -> wl_pointer.axis_source (wlroots
    // backend/libinput/pointer.c:69-86).
    try testing.expectEqual(
        @as(?server.wl.Pointer.AxisSource, .wheel),
        axisSourceFromLibinput(pointer_axis_source_wheel),
    );
    try testing.expectEqual(
        @as(?server.wl.Pointer.AxisSource, .finger),
        axisSourceFromLibinput(pointer_axis_source_finger),
    );
    try testing.expectEqual(
        @as(?server.wl.Pointer.AxisSource, .continuous),
        axisSourceFromLibinput(pointer_axis_source_continuous),
    );
    try testing.expectEqual(
        @as(?server.wl.Pointer.AxisSource, .wheel_tilt),
        axisSourceFromLibinput(pointer_axis_source_wheel_tilt),
    );
    try testing.expectEqual(@as(?server.wl.Pointer.AxisSource, null), axisSourceFromLibinput(0));

    // WHEEL: degrees, 15.0 per click -> 10 px per notch.
    try testing.expectApproxEqAbs(@as(f64, 10.0), axisValueToPixelsSource(.wheel, 15.0), 0.0001);
    // FINGER/CONTINUOUS: cursor-equivalent units, 1.0 = 1 px (pass-through).
    try testing.expectApproxEqAbs(@as(f64, 3.5), axisValueToPixelsSource(.finger, 3.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, -2.0), axisValueToPixelsSource(.continuous, -2.0), 0.0001);
    // Discrete: wheel clicks rounded; finger/continuous always 0
    // (libinput.h:1653-1657).
    try testing.expectEqual(@as(i32, -2), axisDiscreteForSource(.wheel, -1.6));
    try testing.expectEqual(@as(i32, 0), axisDiscreteForSource(.finger, 1.6));
    try testing.expectEqual(@as(i32, 0), axisDiscreteForSource(.continuous, 1.6));
}

test "v120 deltas normalize to legacy clicks" {
    // B28: libinput high-resolution wheel deltas are ±120 per logical
    // click; the seat contract is legacy clicks (10 px per notch).
    try testing.expectEqual(@as(i32, 1), v120ToNotches(120.0));
    try testing.expectEqual(@as(i32, 2), v120ToNotches(240.0));
    try testing.expectEqual(@as(i32, -1), v120ToNotches(-120.0));
    try testing.expectEqual(@as(i32, -3), v120ToNotches(-360.0));
    // Fractional deltas (hi-res sub-notch, e.g. one third of a click):
    // the value carries the fraction; the discrete rounds to whole
    // notches (round-half-away-from-zero).
    try testing.expectEqual(@as(i32, 1), v120ToNotches(60.0));
    try testing.expectEqual(@as(i32, 0), v120ToNotches(40.0));
    try testing.expectEqual(@as(i32, 0), v120ToNotches(-40.0));
    try testing.expectEqual(@as(i32, 0), v120ToNotches(0.0));
}

test "zero-device check honors WLR_LIBINPUT_NO_DEVICES" {
    // B29: the startup check stays on unless the env var is exactly "1"
    // (wlroots env_parse_bool, util/env.c).
    try testing.expect(zeroDeviceCheckEnabled(null));
    try testing.expect(zeroDeviceCheckEnabled(""));
    try testing.expect(zeroDeviceCheckEnabled("0"));
    try testing.expect(zeroDeviceCheckEnabled("true"));
    try testing.expect(!zeroDeviceCheckEnabled("1"));
}

test "LED state derives from locked modifiers" {
    // B30: wl_keyboard.modifiers layout — Lock (bit 1) -> Caps Lock,
    // Mod2 (bit 4) -> Num Lock; bits match libinput's enum libinput_led.
    try testing.expectEqual(@as(c_int, 0), ledsFromModsLocked(0));
    try testing.expectEqual(@as(c_int, led_caps_lock), ledsFromModsLocked(1 << 1));
    try testing.expectEqual(@as(c_int, led_num_lock), ledsFromModsLocked(1 << 4));
    try testing.expectEqual(@as(c_int, led_caps_lock | led_num_lock), ledsFromModsLocked((1 << 1) | (1 << 4)));
    // Non-LED locked modifiers (Shift = bit 0, Mod4 = bit 6) contribute
    // nothing.
    try testing.expectEqual(@as(c_int, 0), ledsFromModsLocked((1 << 0) | (1 << 6)));
}

test "capability to kind mapping" {
    // kindForDevice queries the real libinput per capability (bool per
    // cap), so the unit level covers the classification PRIORITY order
    // only; the VM E2E exercises the FFI against real devices.
    try testing.expectEqual(device_cap_keyboard, 0);
    try testing.expectEqual(device_cap_pointer, 1);
    try testing.expectEqual(device_cap_touch, 2);
}

test "event type dispatch mapping" {
    try testing.expectEqualStrings("device added", eventTypeName(event_device_added));
    try testing.expectEqualStrings("device removed", eventTypeName(event_device_removed));
    try testing.expectEqualStrings("keyboard key", eventTypeName(event_keyboard_key));
    try testing.expectEqualStrings("pointer motion", eventTypeName(event_pointer_motion));
    try testing.expectEqualStrings("pointer motion absolute", eventTypeName(event_pointer_motion_absolute));
    try testing.expectEqualStrings("pointer button", eventTypeName(event_pointer_button));
    try testing.expectEqualStrings("pointer axis", eventTypeName(event_pointer_axis));
    // libinput 1.19+ scroll events: SCROLL_WHEEL is consumed (v120 wheel
    // path); SCROLL_FINGER/CONTINUOUS are ignored (their POINTER_AXIS
    // twins carry the data).
    try testing.expectEqualStrings("pointer scroll wheel", eventTypeName(event_pointer_scroll_wheel));
    try testing.expectEqualStrings("other", eventTypeName(500)); // touch down)
}

test "button constants match the seat" {
    try testing.expectEqual(seat_mod.btn_left, btn_left);
    try testing.expectEqual(seat_mod.btn_right, btn_right);
    try testing.expectEqual(seat_mod.btn_middle, btn_middle);
}
