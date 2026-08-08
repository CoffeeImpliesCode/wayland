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
//! Event delivery follows wlroots: keyboard and pointer events (enter,
//! leave, key, modifiers, motion, button, axis) reach only the focused
//! client's resources, never the whole seat's resource list. libwayland
//! itself rejects events carrying another client's surface, so a fan-out
//! would kill the unfocused clients.
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, buffers (via the
//! surface), compositor/surface.zig + xkb.zig (sibling modules).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const compositor_mod = @import("compositor.zig");
const surface_mod = @import("surface.zig");
const xkb_mod = @import("xkb.zig");

const server = @import("protocol").server;
const client = @import("protocol").client;

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
        // Motion goes only to the focused client's pointer resources
        // (wlroots: wlr_seat_pointer_send_motion iterates
        // focused_client->pointers, wlr_seat_pointer.c:246-268).
        if (self.pointer_focus) |focus| {
            const focus_client = focus.resource.getClient();
            for (self.pointers.items) |ptr| {
                if (ptr.getClient() != focus_client) continue;
                ptr.sendMotion(time, Fixed.fromInt(@intCast(self.focus_x)), Fixed.fromInt(@intCast(self.focus_y)));
                if (ptr.getVersion() >= 5) ptr.sendFrame();
            }
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
        // Button goes only to the focused client's pointer resources
        // (wlroots: wlr_seat_pointer_send_button iterates
        // focused_client->pointers, wlr_seat_pointer.c:274-295).
        if (self.pointer_focus) |focus| {
            const focus_client = focus.resource.getClient();
            for (self.pointers.items) |ptr| {
                if (ptr.getClient() != focus_client) continue;
                ptr.sendButton(serial, time, button, state);
                if (ptr.getVersion() >= 5) ptr.sendFrame();
            }
        }
        self.events.button.emit(self);
    }

    /// Vertical/horizontal wheel or scroll axis. `value` is in pixels
    /// (10 per notch is the wlroots convention), `discrete` the notches.
    ///
    /// Event shape follows wlr_seat_pointer_send_axis
    /// (wlr_seat_pointer.c:321-392): value != 0 emits axis_source +
    /// (axis_discrete) + axis, while value == 0 terminates the scroll
    /// with axis_stop. Events go only to the focused client's pointer
    /// resources.
    pub fn pointerAxis(self: *Seat, axis: server.wl.Pointer.Axis, value: f64, discrete: i32) void {
        const focus = self.pointer_focus orelse return;
        const focus_client = focus.resource.getClient();
        const time = nowMs(self);
        for (self.pointers.items) |ptr| {
            if (ptr.getClient() != focus_client) continue;
            if (ptr.getVersion() >= 5) {
                ptr.sendAxisSource(.wheel);
                if (value != 0) {
                    if (discrete != 0) ptr.sendAxisDiscrete(axis, discrete);
                    ptr.sendAxis(time, axis, Fixed.fromDouble(value));
                } else {
                    ptr.sendAxisStop(time, axis);
                }
                ptr.sendFrame();
            } else if (value != 0) {
                // Pre-v5 clients: axis only (source/discrete/stop do not
                // exist below version 5).
                ptr.sendAxis(time, axis, Fixed.fromDouble(value));
            }
        }
    }

    /// Set keyboard focus. Sends leave to the old and enter (with the
    /// currently pressed keys) to the new focus surface. Both go only to
    /// the respective surface's client's keyboards (wlroots:
    /// wlr_seat_keyboard_enter, wlr_seat_keyboard.c:234-311); libwayland
    /// rejects enter/leave carrying a foreign client's surface.
    pub fn setKeyboardFocus(self: *Seat, surface: ?*Surface) void {
        if (surface == self.keyboard_focus) return;
        const serial = self.display.nextSerial();
        if (self.keyboard_focus) |old| {
            const old_res = old.resource;
            const old_client = old_res.getClient();
            for (self.keyboards.items) |kbd| {
                if (kbd.getClient() != old_client) continue;
                kbd.sendLeave(serial, old_res);
            }
        }
        self.keyboard_focus = surface;
        if (surface) |s| {
            const s_res = s.resource;
            const s_client = s_res.getClient();
            var keys = wire.wl.Array.fromArrayList(u32, self.pressed);
            for (self.keyboards.items) |kbd| {
                if (kbd.getClient() != s_client) continue;
                kbd.sendEnter(serial, s_res, &keys);
            }
            // wlroots sends the current modifiers to the newly focused
            // client right after enter (wlr_seat_keyboard.c:291); the
            // protocol mandates a modifiers event after enter.
            self.sendKeyboardModifiers();
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
            // Modifier broadcasts go only to the focused client's
            // keyboards (wlroots: wlr_seat_keyboard_send_modifiers
            // iterates focused_client->keyboards).
            self.sendKeyboardModifiers();
        }

        const state: server.wl.Keyboard.KeyState = if (pressed) .pressed else .released;
        const serial = self.display.nextSerial();
        const time = nowMs(self);
        // Key events go only to the focused client's keyboards
        // (wlroots: wlr_seat_keyboard_send_key iterates
        // focused_client->keyboards, wlr_seat_keyboard.c:67-84).
        if (self.keyboard_focus) |focus| {
            const focus_client = focus.resource.getClient();
            for (self.keyboards.items) |kbd| {
                if (kbd.getClient() != focus_client) continue;
                kbd.sendKey(serial, time, keycode, state);
            }
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

    /// Send the current modifier state (with a fresh serial) to the
    /// focused client's keyboard resources only. Mirrors wlroots'
    /// wlr_seat_keyboard_send_modifiers (wlr_seat_keyboard.c:205-232);
    /// the protocol requires it right after keyboard.enter, and on any
    /// modifier change.
    fn sendKeyboardModifiers(self: *Seat) void {
        const focus = self.keyboard_focus orelse return;
        const focus_client = focus.resource.getClient();
        const serial = self.display.nextSerial();
        for (self.keyboards.items) |kbd| {
            if (kbd.getClient() != focus_client) continue;
            kbd.sendModifiers(serial, self.mods_depressed, self.mods_latched, self.mods_locked, 0);
        }
    }

    fn pointerEnter(self: *Seat, surface: *Surface, sx: i32, sy: i32) void {
        self.pointer_focus = surface;
        self.pointer_enter_serial = self.display.nextSerial();
        self.focus_x = sx;
        self.focus_y = sy;
        const res = surface.resource;
        // Enter goes only to the surface's client's pointer resources
        // (wlroots: wlr_seat_pointer_enter loops over client->pointers,
        // wlr_seat_pointer.c:184-196). Sending a foreign surface to
        // another client's wl_pointer is rejected by libwayland, which
        // flags the client connection as errored.
        const surface_client = res.getClient();
        for (self.pointers.items) |ptr| {
            if (ptr.getClient() != surface_client) continue;
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
        // Leave goes only to the leaving surface's client's pointers
        // (wlroots: seat_client_send_pointer_leave_raw,
        // wlr_seat_pointer.c:148-158).
        const old_client = res.getClient();
        for (self.pointers.items) |ptr| {
            if (ptr.getClient() != old_client) continue;
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

fn bindSeat(wl_client: *wire.Client, seat: *Seat, version: u32, id: u32) void {
    const resource = server.wl.Seat.create(wl_client, version, id) catch {
        wl_client.postNoMemory();
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
            // Late enter only for the focused client (wlroots:
            // focused_client == seat_client, wlr_seat_keyboard.c:449-460).
            // A foreign-surface enter is rejected by libwayland.
            if (seat.keyboard_focus) |s| {
                if (kbd.getClient() == s.resource.getClient()) {
                    var keys = wire.wl.Array.fromArrayList(u32, seat.pressed);
                    kbd.sendEnter(seat.display.nextSerial(), s.resource, &keys);
                    // wlroots sends enter then modifiers to the focused
                    // client's keyboards on bind (wlr_seat_keyboard.c:459-460).
                    seat.sendKeyboardModifiers();
                }
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
            // Late enter only for the focused client (wlroots:
            // focused_client == seat_client, wlr_seat_pointer.c:560-566).
            // A foreign-surface enter is rejected by libwayland.
            if (seat.pointer_focus) |s| {
                if (ptr.getClient() == s.resource.getClient()) {
                    ptr.sendEnter(
                        seat.display.nextSerial(),
                        s.resource,
                        Fixed.fromInt(@intCast(seat.focus_x)),
                        Fixed.fromInt(@intCast(seat.focus_y)),
                    );
                    if (ptr.getVersion() >= 5) ptr.sendFrame();
                }
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

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as presentation.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Event log for one client-side wl_keyboard. `order` records the
/// sequence of enter/modifiers/key/leave events so tests can assert that
/// modifiers follow enter (the protocol mandates a modifiers event right
/// after enter; wlroots sends it, wlr_seat_keyboard.c:291).
const KeyboardEvents = struct {
    const Order = enum { enter, modifiers, key, leave };

    keymaps: usize = 0,
    entered: bool = false,
    enter_surface_id: u32 = 0,
    modifiers: usize = 0,
    mods_depressed: u32 = 0,
    keys: usize = 0,
    last_key: u32 = 0,
    // SAFETY: filled during the test before any read.
    order: [16]Order = undefined,
    order_len: usize = 0,

    fn log(data: *KeyboardEvents, e: Order) void {
        std.debug.assert(data.order_len < data.order.len);
        data.order[data.order_len] = e;
        data.order_len += 1;
    }

    fn listener(keyboard: *client.wl.Keyboard, event: client.wl.Keyboard.Event, data: *KeyboardEvents) void {
        _ = keyboard;
        switch (event) {
            .keymap => |e| {
                data.keymaps += 1;
                // The fd is owned by the receiving client: close it.
                _ = std.os.linux.close(e.fd);
            },
            .enter => |e| {
                data.entered = true;
                if (e.surface) |s| data.enter_surface_id = s.getId();
                data.log(.enter);
            },
            .leave => data.log(.leave),
            .key => |e| {
                data.keys += 1;
                data.last_key = e.key;
                data.log(.key);
            },
            .modifiers => |e| {
                data.modifiers += 1;
                data.mods_depressed = e.mods_depressed;
                data.log(.modifiers);
            },
            .repeat_info => {},
        }
    }
};

/// Event counts for one client-side wl_pointer.
const PointerEvents = struct {
    entered: bool = false,
    enter_surface_id: u32 = 0,
    motion: usize = 0,
    button: usize = 0,
    axis: usize = 0,
    axis_stop: usize = 0,
    axis_discrete: usize = 0,
    axis_source: usize = 0,

    fn listener(pointer: *client.wl.Pointer, event: client.wl.Pointer.Event, data: *PointerEvents) void {
        _ = pointer;
        switch (event) {
            .enter => |e| {
                data.entered = true;
                if (e.surface) |s| data.enter_surface_id = s.getId();
            },
            .leave => {},
            .motion => data.motion += 1,
            .button => data.button += 1,
            .axis => data.axis += 1,
            .axis_stop => data.axis_stop += 1,
            .axis_discrete => data.axis_discrete += 1,
            .axis_source => data.axis_source += 1,
            .axis_value120 => {},
            .axis_relative_direction => {},
            .frame => {},
            .warp => {},
        }
    }
};

/// One connected in-memory client: server-side wire client + client-side
/// compositor/seat proxies, surface, keyboard and pointer.
const TestClient = struct {
    server: *wire.Client,
    display: *client.wl.Display,
    compositor: *client.wl.Compositor,
    seat: *client.wl.Seat,
    surface: *client.wl.Surface,
    keyboard: *client.wl.Keyboard,
    pointer: *client.wl.Pointer,
    kbd_events: KeyboardEvents = .{},
    ptr_events: PointerEvents = .{},
};

/// The seat's hit-test context: which surface the pick returns.
const TestPickState = struct {
    surface: ?*Surface = null,
};

fn testPick(ctx: *anyopaque, x: i32, y: i32) ?Seat.PickResult {
    const st: *TestPickState = @ptrCast(@alignCast(ctx));
    if (st.surface) |s| return .{ .surface = s, .sx = x, .sy = y };
    return null;
}

/// A full compositor + seat + two in-memory clients, for wire
/// roundtrips. `clients` tracks how many clients are connected so a
/// failed init can tear down safely.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*Seat = null,
    pick_state: TestPickState = .{},
    // SAFETY: initialized by the harness before any use.
    a: TestClient = undefined,
    // SAFETY: initialized by the harness before any use.
    b: TestClient = undefined,
    clients: usize = 0,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor and seat all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        const ts = try allocator.create(TestServer);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        // deinit() frees ts itself, so it is the only teardown errdefer.
        errdefer ts.deinit();
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        ts.seat = try Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        ts.seat.?.setPick(testPick, &ts.pick_state);
        try connectClient(ts, &ts.a);
        try connectClient(ts, &ts.b);
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // Clients tear down first (LIFO), then the modules.
        if (ts.clients >= 2) {
            ts.b.display.disconnect();
            ts.b.server.destroy();
        }
        if (ts.clients >= 1) {
            ts.a.display.disconnect();
            ts.a.server.destroy();
        }
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Client flush -> server event loop dispatch -> server flush ->
    /// client dispatch for every connected client. Drives one roundtrip
    /// without blocking.
    fn pump(ts: *TestServer) !void {
        if (ts.clients >= 1) {
            if (ts.a.display.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        if (ts.clients >= 2) {
            if (ts.b.display.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        if (ts.clients >= 1) try dispatchDisplay(ts.a.display);
        if (ts.clients >= 2) try dispatchDisplay(ts.b.display);
    }
};

/// Flush + roundtrip for one client display. Used while a client is
/// still connecting, i.e. before it is registered in ts.a/ts.b.
fn pumpOne(ts: *TestServer, c_display: *client.wl.Display) !void {
    if (c_display.flush() != .SUCCESS) return error.ClientFlushFailed;
    try ts.display.?.getServer().getEventLoop().dispatch(0);
    ts.display.?.flushClients();
    try dispatchDisplay(c_display);
}

fn dispatchDisplay(c_display: *client.wl.Display) !void {
    var fds = [_]posix.pollfd{
        .{ .fd = c_display.getFd(), .events = posix.POLL.IN, .revents = 0 },
    };
    if (try posix.poll(&fds, 0) > 0) {
        if (c_display.dispatch() != .SUCCESS) return error.ClientDispatchFailed;
    }
}

/// Connect one client: registry round, then bind wl_compositor + wl_seat
/// (v7), create a surface and the seat's keyboard/pointer objects.
fn connectClient(ts: *TestServer, tc: *TestClient) !void {
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    const server_client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
    errdefer server_client.destroy();
    const c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;
    errdefer c_display.disconnect();

    // Round 1: registry + global announcements.
    const registry = try c_display.getRegistry();
    var capture: RegistryCapture = .{};
    registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
    try pumpOne(ts, c_display);

    // Round 2: bind wl_compositor + wl_seat, create the surface and the
    // keyboard/pointer objects; listeners attach before the pump.
    const wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
    const wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
    tc.* = .{
        .server = server_client,
        .display = c_display,
        .compositor = wl_compositor,
        .seat = wl_seat,
        .surface = try wl_compositor.createSurface(),
        .keyboard = try wl_seat.getKeyboard(),
        .pointer = try wl_seat.getPointer(),
    };
    tc.keyboard.setListener(*KeyboardEvents, KeyboardEvents.listener, &tc.kbd_events);
    tc.pointer.setListener(*PointerEvents, PointerEvents.listener, &tc.ptr_events);
    try pumpOne(ts, c_display);
    ts.clients += 1;
}

/// The server-side Surface created by `server_client` (each test client
/// creates exactly one surface).
fn surfaceForClient(ts: *TestServer, server_client: *wire.Client) *Surface {
    for (ts.compositor.?.surfaces.items) |s| {
        if (s.resource.getClient() == server_client) return s;
    }
    unreachable;
}

test "keyboard and pointer events reach only the focused client" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        // xkeyboard-config must be available in the test environment
        // (same skip as xkb.zig's test).
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const b = &ts.b;
    const surface_a = surfaceForClient(ts, a.server);
    try std.testing.expectEqual(@as(usize, 2), ts.seat.?.keyboards.items.len);
    try std.testing.expectEqual(@as(usize, 2), ts.seat.?.pointers.items.len);

    // Pointer focus on A's surface.
    ts.pick_state.surface = surface_a;
    ts.seat.?.pointerMotion(10, 10);
    try ts.pump();

    // Enter reaches only the focused client's pointer; the unfocused
    // client gets nothing (a foreign-surface enter is rejected by
    // libwayland and kills the connection).
    try std.testing.expect(a.ptr_events.entered);
    try std.testing.expect(!b.ptr_events.entered);
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.motion);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.motion);

    // Button press: click-to-focus moves keyboard focus to A's surface;
    // the button event goes only to the focused client.
    ts.seat.?.pointerButton(btn_left, true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.button);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.button);
    try std.testing.expect(a.kbd_events.entered);
    try std.testing.expect(!b.kbd_events.entered);

    // Key events go only to the focused client's keyboard.
    ts.seat.?.keyEvent(38, true); // 'a' (evdev A + 8)
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.kbd_events.keys);
    try std.testing.expectEqual(@as(usize, 0), b.kbd_events.keys);
    try std.testing.expectEqual(@as(u32, 38), a.kbd_events.last_key);

    // Modifier change (left shift, keycode 50) also goes only to the
    // focused client. The earlier click-to-focus already delivered one
    // post-enter modifiers event to A.
    ts.seat.?.keyEvent(50, true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), a.kbd_events.modifiers);
    try std.testing.expectEqual(@as(usize, 0), b.kbd_events.modifiers);
    try std.testing.expectEqual(@as(u32, 1), a.kbd_events.mods_depressed);

    // Wheel burst (discrete != 0): axis_source + axis_discrete + axis,
    // no axis_stop; only the focused client.
    ts.seat.?.pointerAxis(.vertical_scroll, 10.0, 1);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_source);
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_discrete);
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis);
    try std.testing.expectEqual(@as(usize, 0), a.ptr_events.axis_stop);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis_source);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis_discrete);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis_stop);

    // Scroll end (value == 0): axis_stop only, no axis; only the focused
    // client.
    ts.seat.?.pointerAxis(.vertical_scroll, 0.0, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_stop);
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis); // unchanged
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_discrete); // unchanged
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis_stop);
}

test "keyboard enter is followed by a modifiers event" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const b = &ts.b;
    const surface_a = surfaceForClient(ts, a.server);

    // Initial bind: no focus yet, so no enter and no modifiers.
    try std.testing.expect(!a.kbd_events.entered);
    try std.testing.expectEqual(@as(usize, 0), a.kbd_events.modifiers);
    try std.testing.expectEqual(@as(usize, 1), a.kbd_events.keymaps);

    // setKeyboardFocus delivers enter then modifiers, in that order, to
    // the focused client (wlroots: wlr_seat_keyboard.c:291).
    ts.seat.?.setKeyboardFocus(surface_a);
    try ts.pump();
    try std.testing.expect(a.kbd_events.entered);
    try std.testing.expectEqual(@as(u32, a.surface.getId()), a.kbd_events.enter_surface_id);
    try std.testing.expectEqual(@as(usize, 1), a.kbd_events.modifiers);
    try std.testing.expectEqual(@as(usize, 2), a.kbd_events.order_len);
    try std.testing.expectEqual(KeyboardEvents.Order.enter, a.kbd_events.order[0]);
    try std.testing.expectEqual(KeyboardEvents.Order.modifiers, a.kbd_events.order[1]);

    // The unfocused client's keyboard gets no enter at all (enter
    // targets the focused client; a foreign-surface enter is rejected by
    // libwayland and kills the connection).
    try std.testing.expect(!b.kbd_events.entered);
    try std.testing.expectEqual(@as(usize, 0), b.kbd_events.modifiers);

    // A keyboard bound after the focus exists also gets enter + modifiers
    // (wlroots: seat_client_create_keyboard, wlr_seat_keyboard.c:459-460).
    const second_kbd = try a.seat.getKeyboard();
    var second_events: KeyboardEvents = .{};
    second_kbd.setListener(*KeyboardEvents, KeyboardEvents.listener, &second_events);
    try ts.pump();
    try std.testing.expect(second_events.entered);
    try std.testing.expectEqual(@as(usize, 1), second_events.modifiers);
    try std.testing.expectEqual(@as(usize, 2), second_events.order_len);
    try std.testing.expectEqual(KeyboardEvents.Order.enter, second_events.order[0]);
    try std.testing.expectEqual(KeyboardEvents.Order.modifiers, second_events.order[1]);

    // The unfocused client (B) binding late gets keymap/repeat_info only:
    // no enter and no modifiers — the focus surface belongs to another
    // client (wlroots gates on focused_client == seat_client).
    const late_b_kbd = try b.seat.getKeyboard();
    var late_b_events: KeyboardEvents = .{};
    late_b_kbd.setListener(*KeyboardEvents, KeyboardEvents.listener, &late_b_events);
    try ts.pump();
    try std.testing.expect(!late_b_events.entered);
    try std.testing.expectEqual(@as(usize, 0), late_b_events.modifiers);
    try std.testing.expectEqual(@as(usize, 1), late_b_events.keymaps);
}
