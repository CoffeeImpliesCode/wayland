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
//!   - axis: only the legacy LIBINPUT_EVENT_POINTER_AXIS is consumed. Since
//!     libinput 1.19 the new SCROLL_WHEEL/FINGER/CONTINUOUS events are sent
//!     *in addition* to it; consuming both would double every wheel click.
//!     The wheel value is in degrees (15.0 per notch); `axisValueToPixels`
//!     converts to the seat's 10 px per notch convention and
//!     `axisDiscreteToNotches` rounds the physical click count.
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

// ---------------------------------------------------------------------------
// Constants — numeric values verified against the real headers:
//   libinput:   /nix/store/25z81mr9anpamdwv7lizq5l56hhq6kmi-libinput-1.31.3-dev/include/libinput.h
//   input codes: /nix/store/1hrk7xhpm6h98n0lg1qixfrr2kb96zqs-linux-headers-6.18.7/include/linux/input-event-codes.h
// ---------------------------------------------------------------------------

/// enum libinput_event_type (libinput.h:775-1040).
pub const event_none: c_int = 0;
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
pub const key_state_released: c_int = 0;
pub const key_state_pressed: c_int = 1;
/// enum libinput_button_state (libinput.h:246-249).
pub const button_state_released: c_int = 0;
pub const button_state_pressed: c_int = 1;

/// enum libinput_pointer_axis (libinput.h:263-266).
pub const pointer_axis_scroll_vertical: c_int = 0;
pub const pointer_axis_scroll_horizontal: c_int = 1;
/// enum libinput_pointer_axis_source (libinput.h:280+); only wheel is
/// relevant to the VM test devices.
pub const pointer_axis_source_wheel: c_int = 1;

/// enum libinput_device_capability (libinput.h:206-214).
pub const device_cap_keyboard: c_int = 0;
pub const device_cap_pointer: c_int = 1;
pub const device_cap_touch: c_int = 2;

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
    pub const libinput_seat = opaque {};
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
    extern fn libinput_path_create_context(interface: *const libinput_interface, user_data: ?*anyopaque) ?*libinput;
    extern fn libinput_path_add_device(li: ?*libinput, path: [*:0]const u8) ?*libinput_device;
    extern fn libinput_get_fd(li: ?*libinput) c_int;
    extern fn libinput_dispatch(li: ?*libinput) c_int;
    /// Retrieve the next queued event (NULL when the queue is empty).
    /// libinput_next_event in pre-1.0.4 docs; the 1.31 header names it
    /// libinput_get_event (libinput.h:3884).
    extern fn libinput_get_event(li: ?*libinput) ?*libinput_event;
    extern fn libinput_event_destroy(event: ?*libinput_event) void;
    extern fn libinput_unref(li: ?*libinput) ?*libinput;

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

    // Device accessors (libinput.h:4338, 4418).
    extern fn libinput_device_get_name(device: ?*libinput_device) [*:0]const u8;
    extern fn libinput_device_get_seat(device: ?*libinput_device) ?*libinput_seat;
    extern fn libinput_device_has_capability(device: ?*libinput_device, capability: c_int) c_int;

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

/// Map a libinput device to the backend's InputDevice kind. libinput's
/// has_capability takes ONE capability and returns a bool; devices are
/// classified by priority (keyboard > pointer > touch). Devices with only
/// tablet/pad/switch/gesture capabilities map to null and are not
/// announced.
pub fn kindForDevice(dev: ?*c.libinput_device) ?InputKind {
    if (c.libinput_device_has_capability(dev, device_cap_keyboard) != 0) return .keyboard;
    if (c.libinput_device_has_capability(dev, device_cap_pointer) != 0) return .pointer;
    if (c.libinput_device_has_capability(dev, device_cap_touch) != 0) return .touch;
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

    /// The libinput fd to poll (libinput_get_fd). Only valid after start().
    pub fn pollFd(self: *Libinput) c_int {
        std.debug.assert(self.ctx != null);
        return c.libinput_get_fd(self.ctx);
    }

    /// libinput_dispatch + drain every queued event into the seat.
    /// Called when pollFd() is readable (and once in start() to pick up
    /// the initial DEVICE_ADDED burst).
    pub fn dispatch(self: *Libinput) error{DispatchFailed}!void {
        std.debug.assert(self.ctx != null);
        if (c.libinput_dispatch(self.ctx) != 0) return error.DispatchFailed;
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
            // libinput >= 1.19 sends these *in addition* to POINTER_AXIS;
            // consuming both would double every wheel click.
            event_pointer_scroll_wheel, event_pointer_scroll_finger, event_pointer_scroll_continuous => {},
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

        const name_slice = std.mem.span(c.libinput_device_get_name(dev));
        const name = if (name_slice.len == 0) "unknown" else name_slice;
        const owned = self.allocator.dupeZ(u8, name) catch {
            log_mod.warn("device {s}: name allocation failed", self.io, self.log_cfg, "libinput", .{name});
            return;
        };
        errdefer self.allocator.free(owned);

        self.devices.append(self.allocator, .{ .handle = dev, .kind = kind, .name = owned }) catch return;
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
        // wlroots iterates both scroll axes (handle_pointer_axis).
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_vertical) != 0) {
            const value = c.libinput_event_pointer_get_axis_value(pevent, pointer_axis_scroll_vertical);
            const discrete = c.libinput_event_pointer_get_axis_value_discrete(pevent, pointer_axis_scroll_vertical);
            self.seat.pointerAxis(.vertical_scroll, axisValueToPixels(value), axisDiscreteToNotches(discrete));
        }
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_horizontal) != 0) {
            const value = c.libinput_event_pointer_get_axis_value(pevent, pointer_axis_scroll_horizontal);
            const discrete = c.libinput_event_pointer_get_axis_value_discrete(pevent, pointer_axis_scroll_horizontal);
            self.seat.pointerAxis(.horizontal_scroll, axisValueToPixels(value), axisDiscreteToNotches(discrete));
        }
    }
};

const backend_impl: backend.Backend.Impl = .{
    .start = start,
    .destroy = destroy,
};

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
    self.ctx = c.libinput_udev_create_context(&libinput_interface_impl, self, self.udev) orelse
        return error.BackendFailed;
    errdefer {
        _ = c.libinput_unref(self.ctx);
        self.ctx = null;
    }

    if (c.libinput_udev_assign_seat(self.ctx, self.seat_name.ptr) != 0) {
        log_mod.err("libinput seat assign failed (seat {s})", self.io, self.log_cfg, "libinput", .{self.seat_name});
        return error.BackendFailed;
    }

    log_mod.info("libinput backend started (seat {s}, output {d}x{d})", self.io, self.log_cfg, "libinput", .{
        self.seat_name, self.output_width, self.output_height,
    });

    // Assigning the seat queues DEVICE_ADDED for every device on it; they
    // arrive on the first dispatch (wlroots drains in backend_start too).
    self.dispatch() catch {
        log_mod.err("libinput initial dispatch failed", self.io, self.log_cfg, "libinput", .{});
        return error.BackendFailed;
    };
}

fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const self: *Libinput = @ptrCast(@alignCast(data));
    for (self.devices.items) |d| allocator.free(d.name);
    self.devices.deinit(allocator);
    if (self.ctx) |ctx| _ = c.libinput_unref(ctx);
    if (self.udev) |udev| _ = c.udev_unref(udev);
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
    // libinput 1.19+ scroll events: recognized, consumed by the "ignore"
    // prongs of the dispatch switch (they duplicate POINTER_AXIS).
    try testing.expectEqualStrings("pointer scroll wheel", eventTypeName(event_pointer_scroll_wheel));
    try testing.expectEqualStrings("other", eventTypeName(500)); // touch down
}

test "button constants match the seat" {
    try testing.expectEqual(seat_mod.btn_left, btn_left);
    try testing.expectEqual(seat_mod.btn_right, btn_right);
    try testing.expectEqual(seat_mod.btn_middle, btn_middle);
}
