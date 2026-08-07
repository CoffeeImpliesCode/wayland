//! wl_seat: keyboard + pointer input (M3).
//!
//! The Seat owns one wl_seat global (keyboard + pointer capabilities; no
//! touch) and the input state the compositor drives it with:
//!
//!   - Keyboard: xkbcommon keymap (sent over a memfd), keyboard focus
//!     (enter/leave), key events with xkb keycodes, modifier tracking.
//!   - Pointer: focus via a compositor-supplied hit-test callback, motion
//!     in output coordinates, buttons, wheel axis; wl_pointer.set_cursor
//!     stores the client cursor surface (the compositor renders it).
//!
//! The input *source* is external (backend-driven): the server polls the
//! raylib backend each frame and feeds seat.keyEvent/pointerMotion/
//! pointerButton/pointerAxis. Headless/test servers can synthesize input
//! through the same API.
//!
//! Click-to-focus: a pointer button press moves keyboard focus to the
//! pointer focus surface. The seat also emits `key` signals so the
//! compositor can bind keys (the server quits on Mod4+Escape).
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, buffers (via the
//! surface), compositor/surface.zig + xkb.zig (sibling modules).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const surface_mod = @import("surface.zig");
const xkb_mod = @import("xkb.zig");

const server = @import("protocol").server;

const Surface = surface_mod.Surface;
const Fixed = wire.wl.Fixed;

/// wl_seat protocol version this library implements.
pub const seat_version: u32 = 7;

pub const capabilities_keyboard: u32 = 1;
pub const capabilities_pointer: u32 = 2;

/// wl_pointer button codes (linux input BTN_*).
pub const btn_left: u32 = 272;
pub const btn_right: u32 = 273;
pub const btn_middle: u32 = 274;

pub const Seat = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The wl_seat global, for teardown.
    global: ?*wire.Global = null,
    xkb: *xkb_mod.Xkb,

    // Keyboard -----------------------------------------------------------
    /// Per-client wl_keyboard resources (created on get_keyboard).
    keyboards: std.ArrayList(*server.wl.Keyboard) = .empty,
    keyboard_focus: ?*Surface = null,
    /// xkb keycodes currently pressed (sent in keyboard.enter).
    pressed: std.ArrayList(u32) = .empty,
    mods_depressed: u32 = 0,
    mods_latched: u32 = 0,
    mods_locked: u32 = 0,
    /// Keysym of the most recent key event (compositor bindings).
    last_keysym: u32 = 0,
    last_keycode: u32 = 0,

    // Pointer -------------------------------------------------------------
    /// Per-client wl_pointer resources (created on get_pointer).
    pointers: std.ArrayList(*server.wl.Pointer) = .empty,
    pointer_focus: ?*Surface = null,
    /// Pointer position in output coordinates.
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    /// Pointer position relative to the focus surface's top-left.
    focus_x: i32 = 0,
    focus_y: i32 = 0,
    pointer_enter_serial: u32 = 0,
    /// Client cursor surface resource (wl_pointer.set_cursor, applied
    /// when the serial matches the last enter) + hotspot. The compositor
    /// resolves the resource to its Surface for rendering.
    cursor_surface_resource: ?*server.wl.Surface = null,
    cursor_hotspot_x: i32 = 0,
    cursor_hotspot_y: i32 = 0,
    cursor_serial: u32 = 0,
    cursor_visible: bool = true,

    /// Hit-test callback: map output coords to the surface under the
    /// pointer (surface-local coords). Null when nothing is hit.
    pick_fn: ?*const fn (ctx: *anyopaque, x: i32, y: i32) ?PickResult = null,
    pick_ctx: ?*anyopaque = null,

    events: struct {
        /// A key was pressed/released. The seat state (last_keysym,
        /// mods) is already updated; read it in the handler.
        key: wire.Signal(*Seat),
        /// A pointer button was pressed/released.
        button: wire.Signal(*Seat),
        /// The pointer moved.
        pointer_move: wire.Signal(*Seat),
        /// Keyboard focus changed.
        keyboard_focus: wire.Signal(*Seat),
    },

    /// Result of a hit test: the surface and the pointer position in
    /// surface-local coordinates.
    pub const PickResult = struct {
        surface: *Surface,
        sx: i32,
        sy: i32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) error{ OutOfMemory, GlobalCreateFailed, XkbInitFailed, KeymapBuildFailed, KeymapMemfdFailed }!*Seat {
        const xkb = try xkb_mod.Xkb.init(allocator, io, log_cfg, "us");
        errdefer xkb.deinit();
        const self = try allocator.create(Seat);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .xkb = xkb,
            .keyboards = .empty,
            .pressed = .empty,
            .pointers = .empty,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        errdefer self.pressed.deinit(allocator);
        self.events.key.init();
        self.events.button.init();
        self.events.pointer_move.init();
        self.events.keyboard_focus.init();
        self.global = try display.addGlobal(server.wl.Seat, *Seat, bindSeat, seat_version, self);
        log.debug("seat created (keyboard + pointer)", io, log_cfg, "seat", .{});
        return self;
    }

    pub fn deinit(self: *Seat) void {
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        self.keyboards.deinit(allocator);
        self.pointers.deinit(allocator);
        self.pressed.deinit(allocator);
        self.xkb.deinit();
        allocator.destroy(self);
    }

    /// The compositor's hit-test callback: maps output coordinates to the
    /// surface under the pointer (see PickResult).
    pub fn setPick(
        self: *Seat,
        pick_fn: *const fn (ctx: *anyopaque, x: i32, y: i32) ?PickResult,
        ctx: *anyopaque,
    ) void {
        self.pick_fn = pick_fn;
        self.pick_ctx = ctx;
    }

    /// Move the pointer to output coords (x, y): hit-test, deliver
    /// enter/leave/motion to the focused client, move the cursor.
    pub fn pointerMotion(self: *Seat, x: i32, y: i32) void {
        self.pointer_x = x;
        self.pointer_y = y;
        const pick = if (self.pick_fn) |f| f(self.pick_ctx.?, x, y) else null;
        if (pick) |p| {
            if (p.surface != self.pointer_focus) self.pointerEnter(p.surface, p.sx, p.sy);
            self.focus_x = p.sx;
            self.focus_y = p.sy;
        } else if (self.pointer_focus != null) {
            self.pointerLeave();
        } else {
            return; // no focus, no motion target
        }
        const time = nowMs(self);
        for (self.pointers.items) |ptr| {
            if (self.pointer_focus == null) continue;
            ptr.sendMotion(time, Fixed.fromInt(@intCast(self.focus_x)), Fixed.fromInt(@intCast(self.focus_y)));
            if (ptr.getVersion() >= 5) ptr.sendFrame();
        }
        self.events.pointer_move.emit(self);
    }

    /// Pointer button press/release (linux input button code). A press
    /// moves keyboard focus to the surface under the pointer.
    pub fn pointerButton(self: *Seat, button: u32, pressed: bool) void {
        if (pressed) {
            if (self.pointer_focus) |focus| self.setKeyboardFocus(focus);
        }
        const serial = self.display.nextSerial();
        const time = nowMs(self);
        const state: server.wl.Pointer.ButtonState = if (pressed) .pressed else .released;
        for (self.pointers.items) |ptr| {
            ptr.sendButton(serial, time, button, state);
            if (ptr.getVersion() >= 5) ptr.sendFrame();
        }
        self.events.button.emit(self);
    }

    /// Vertical/horizontal wheel or scroll axis. `value` is in pixels
    /// (10 per notch is the wlroots convention), `discrete` the notches.
    pub fn pointerAxis(self: *Seat, axis: server.wl.Pointer.Axis, value: f64, discrete: i32) void {
        const time = nowMs(self);
        for (self.pointers.items) |ptr| {
            if (ptr.getVersion() >= 5) {
                ptr.sendAxisSource(.wheel);
                if (discrete != 0) ptr.sendAxisDiscrete(axis, discrete);
                ptr.sendAxisStop(time, axis);
            }
            ptr.sendAxis(time, axis, Fixed.fromDouble(value));
            if (ptr.getVersion() >= 5) ptr.sendFrame();
        }
    }

    /// Set keyboard focus. Sends leave to the old and enter (with the
    /// currently pressed keys) to the new focus surface.
    pub fn setKeyboardFocus(self: *Seat, surface: ?*Surface) void {
        if (surface == self.keyboard_focus) return;
        const serial = self.display.nextSerial();
        if (self.keyboard_focus) |old| {
            const old_res = old.resource;
            for (self.keyboards.items) |kbd| kbd.sendLeave(serial, old_res);
        }
        self.keyboard_focus = surface;
        if (surface) |s| {
            const s_res = s.resource;
            var keys = wire.wl.Array.fromArrayList(u32, self.pressed);
            for (self.keyboards.items) |kbd| kbd.sendEnter(serial, s_res, &keys);
            log.debug("keyboard focus -> surface@{d}", self.io, self.log_cfg, "seat", .{s_res.getId()});
        }
        self.events.keyboard_focus.emit(self);
    }

    /// Key press/release (xkb keycode, i.e. evdev scancode + 8). Updates
    /// the xkb state, modifiers, the pressed set, delivers the key event
    /// to the focused client and emits the key signal.
    pub fn keyEvent(self: *Seat, keycode: u32, pressed: bool) void {
        self.last_keysym = self.xkb.updateKey(keycode, pressed);
        self.last_keycode = keycode;

        if (pressed) {
            if (!std.mem.containsAtLeast(u32, self.pressed.items, 1, &.{keycode})) {
                self.pressed.append(self.allocator, keycode) catch |err| {
                    log.warn("pressed-keys append failed: {s}", self.io, self.log_cfg, "seat", .{@errorName(err)});
                };
            }
        } else {
            const idx = std.mem.indexOfScalar(u32, self.pressed.items, keycode) orelse 0;
            if (idx < self.pressed.items.len and
                self.pressed.items[idx] == keycode)
            {
                _ = self.pressed.orderedRemove(idx);
            }
        }

        const mods = self.xkb.mods();
        if (mods.depressed != self.mods_depressed or
            mods.latched != self.mods_latched or
            mods.locked != self.mods_locked)
        {
            self.mods_depressed = mods.depressed;
            self.mods_latched = mods.latched;
            self.mods_locked = mods.locked;
            const serial = self.display.nextSerial();
            for (self.keyboards.items) |kbd| {
                kbd.sendModifiers(serial, self.mods_depressed, self.mods_latched, self.mods_locked, 0);
            }
        }

        const state: server.wl.Keyboard.KeyState = if (pressed) .pressed else .released;
        const serial = self.display.nextSerial();
        const time = nowMs(self);
        if (self.keyboard_focus) |_| {
            for (self.keyboards.items) |kbd| kbd.sendKey(serial, time, keycode, state);
        }
        self.events.key.emit(self);
    }

    /// Current cursor surface resource (client-set via
    /// wl_pointer.set_cursor); null cursor surface means hidden.
    pub fn cursorSurface(self: *Seat) ?*server.wl.Surface {
        if (!self.cursor_visible) return null;
        return self.cursor_surface_resource;
    }

    /// True when the Mod4 mask (bit 6) is depressed — used by the
    /// server's Mod4+Escape quit binding.
    pub fn mod4Active(self: *Seat) bool {
        return self.mods_depressed & (1 << 6) != 0;
    }

    fn pointerEnter(self: *Seat, surface: *Surface, sx: i32, sy: i32) void {
        self.pointer_focus = surface;
        self.pointer_enter_serial = self.display.nextSerial();
        self.focus_x = sx;
        self.focus_y = sy;
        const res = surface.resource;
        for (self.pointers.items) |ptr| {
            ptr.sendEnter(
                self.pointer_enter_serial,
                res,
                Fixed.fromInt(@intCast(sx)),
                Fixed.fromInt(@intCast(sy)),
            );
            if (ptr.getVersion() >= 5) ptr.sendFrame();
        }
        log.debug("pointer enter surface@{d} at {d},{d}", self.io, self.log_cfg, "seat", .{
            res.getId(), sx, sy,
        });
    }

    fn pointerLeave(self: *Seat) void {
        const serial = self.display.nextSerial();
        const old = self.pointer_focus.?;
        const res = old.resource;
        for (self.pointers.items) |ptr| {
            ptr.sendLeave(serial, res);
            if (ptr.getVersion() >= 5) ptr.sendFrame();
        }
        self.pointer_focus = null;
        log.debug("pointer leave surface@{d}", self.io, self.log_cfg, "seat", .{res.getId()});
    }

    fn nowMs(self: *Seat) u32 {
        return @truncate(@as(u64, @bitCast(std.Io.Clock.now(.awake, self.io.*).toMilliseconds())));
    }
};

// ---------------------------------------------------------------------------
// wl_seat request handling
// ---------------------------------------------------------------------------

fn bindSeat(client: *wire.Client, seat: *Seat, version: u32, id: u32) void {
    const resource = server.wl.Seat.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Seat, seatRequest, null, seat);
    resource.sendCapabilities(.{ .keyboard = true, .pointer = true });
    if (resource.getVersion() >= 2) resource.sendName("default");
}

fn seatRequest(resource: *server.wl.Seat, request: server.wl.Seat.Request, seat: *Seat) void {
    switch (request) {
        .get_keyboard => |r| {
            const kbd = server.wl.Keyboard.create(resource.getClient(), resource.getVersion(), r.id) catch {
                resource.getClient().postNoMemory();
                return;
            };
            kbd.setHandler(*Seat, keyboardRequest, null, seat);
            seat.keyboards.append(seat.allocator, kbd) catch {
                resource.getClient().postNoMemory();
                return;
            };
            // Keymap first, then repeat info, then the current focus.
            const fd = seat.xkb.dupKeymapFd();
            if (fd >= 0) {
                kbd.sendKeymap(.xkb_v1, fd, seat.xkb.keymap_size);
                _ = std.os.linux.close(fd);
            }
            if (kbd.getVersion() >= 4) kbd.sendRepeatInfo(0, 0); // no server-side repeat in M3
            if (seat.keyboard_focus) |s| {
                var keys = wire.wl.Array.fromArrayList(u32, seat.pressed);
                kbd.sendEnter(seat.display.nextSerial(), s.resource, &keys);
            }
        },
        .get_pointer => |r| {
            const ptr = server.wl.Pointer.create(resource.getClient(), resource.getVersion(), r.id) catch {
                resource.getClient().postNoMemory();
                return;
            };
            ptr.setHandler(*Seat, pointerRequest, null, seat);
            seat.pointers.append(seat.allocator, ptr) catch {
                resource.getClient().postNoMemory();
                return;
            };
            // A client binding late still sees the current focus.
            if (seat.pointer_focus) |s| {
                ptr.sendEnter(
                    seat.display.nextSerial(),
                    s.resource,
                    Fixed.fromInt(@intCast(seat.focus_x)),
                    Fixed.fromInt(@intCast(seat.focus_y)),
                );
                if (ptr.getVersion() >= 5) ptr.sendFrame();
            }
        },
        .get_touch => |r| {
            // Touch is not advertised in the seat capabilities; if a
            // client asks anyway, create a dead object (no events).
            const touch = server.wl.Touch.create(resource.getClient(), resource.getVersion(), r.id) catch {
                resource.getClient().postNoMemory();
                return;
            };
            touch.setHandler(*Seat, touchRequest, null, seat);
        },
        .release => resource.destroy(),
    }
}

fn touchRequest(resource: *server.wl.Touch, request: server.wl.Touch.Request, seat: *Seat) void {
    _ = seat;
    switch (request) {
        .release => resource.destroy(),
    }
}

fn keyboardRequest(resource: *server.wl.Keyboard, request: server.wl.Keyboard.Request, seat: *Seat) void {
    _ = seat;
    switch (request) {
        .release => resource.destroy(),
    }
}

fn pointerRequest(resource: *server.wl.Pointer, request: server.wl.Pointer.Request, seat: *Seat) void {
    switch (request) {
        // The cursor surface only applies when the serial matches the
        // most recent pointer.enter serial (or the pointer is not
        // focused, in which case the next enter uses it).
        .set_cursor => |r| {
            seat.cursor_serial = r.serial;
            if (r.serial == seat.pointer_enter_serial or seat.pointer_focus == null) {
                seat.cursor_surface_resource = r.surface;
                seat.cursor_hotspot_x = r.hotspot_x;
                seat.cursor_hotspot_y = r.hotspot_y;
                log.debug("cursor surface set (serial={d})", seat.io, seat.log_cfg, "seat", .{r.serial});
            }
        },
        .release => resource.destroy(),
    }
}
