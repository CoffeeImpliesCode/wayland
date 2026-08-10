//! wl_seat: keyboard + pointer input (M3).
//!
//! The Seat owns one wl_seat global (keyboard + pointer capabilities; no
//! touch) and the input state the compositor drives it with:
//!
//!   - Keyboard: xkbcommon keymap (sent over a memfd), keyboard focus
//!     (enter/leave), key events with xkb keycodes, modifier tracking.
//!     The WIRE keycode is the evdev scancode (xkb keycode minus 8):
//!     the protocol says clients add 8 to get the xkb keycode
//!     (wayland.xml:2597), so we send scancodes and keep the xkb keycode
//!     only inside the state machine (F1).
//!   - Pointer: focus via a compositor-supplied hit-test callback, motion
//!     in output coordinates, buttons, wheel axis; wl_pointer.set_cursor
//!     stores the client cursor surface (the compositor renders it).
//!     Pointer events are batched: each input batch (between two
//!     pointerFrame() calls) closes with one wl_pointer.frame (F7).
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
const role_mod = @import("role.zig");
const xkb_mod = @import("xkb.zig");

const server = @import("protocol").server;
const client = @import("protocol").client;

const Surface = surface_mod.Surface;
const Fixed = wire.wl.Fixed;

/// wl_seat protocol version this library implements. 10 = KWin's version
/// (seat.cpp:30): axis_value120 (wl_pointer v8), axis_relative_direction
/// (v9) and the key_state "repeated" pseudo-state (wl_keyboard v10) are
/// all reachable. The generated bindings are at 11 (build.zig:35), so
/// nothing above 10 exists in the wire here.
pub const seat_version: u32 = 10;

pub const capabilities_keyboard: u32 = 1;
pub const capabilities_pointer: u32 = 2;

/// Reset the v120 accumulators when the scroll direction flips (or on
/// the first event of a new sequence): wlroots should_reset_value120_accumulators,
/// wlr_seat_pointer.c:264-269.
fn shouldResetValue120(last_discrete: i32, current: i32) bool {
    if (last_discrete == 0) return true;
    return (current < 0 and last_discrete > 0) or (current > 0 and last_discrete < 0);
}

/// wl_pointer button codes (linux input BTN_*).
pub const btn_left: u32 = 272;
pub const btn_right: u32 = 273;
pub const btn_middle: u32 = 274;

/// One logical scroll step in 120ths, the axis_value120 unit
/// (wlroots WLR_POINTER_AXIS_DISCRETE_STEP, include/wlr/types/wlr_pointer.h:74).
const discrete_step: i32 = 120;

/// wl_pointer serial-ring size (wlroots WLR_SERIAL_RINGSET_SIZE,
/// include/wlr/types/wlr_seat.h:18).
const serial_ring_size: usize = 128;

/// A contiguous span of serials handed to one client (wlroots
/// struct wlr_serial_range, wlr_seat.h:23-25).
const SerialRange = struct { min_incl: u32 = 0, max_incl: u32 = 0 };

/// Per-client set of serials recently sent to that client, merged into
/// contiguous ranges on add (wlroots struct wlr_serial_ringset,
/// wlr_seat.h:20-30; wlr_seat_client_next_serial, wlr_seat.c:473-497).
/// Validation uses wrap-safe half-range arithmetic
/// (wlr_seat_client_validate_event_serial, wlr_seat.c:500-524).
const SerialRing = struct {
    // SAFETY: only data[0..count] is read (count gates all access).
    data: [serial_ring_size]SerialRange = undefined,
    end: usize = 0,
    count: usize = 0,

    fn add(self: *SerialRing, serial: u32) void {
        if (self.count == 0) {
            self.data[0] = .{ .min_incl = serial, .max_incl = serial };
            self.count = 1;
            self.end = 0;
        } else if (self.data[self.end].max_incl +% 1 != serial) {
            if (self.count < serial_ring_size) self.count += 1;
            self.end = (self.end + 1) % serial_ring_size;
            self.data[self.end] = .{ .min_incl = serial, .max_incl = serial };
        } else {
            self.data[self.end].max_incl = serial;
        }
    }

    /// True when `serial` was handed to this client recently (or was
    /// recycled out of a full set — wlroots' final full-set acceptance).
    fn contains(self: *const SerialRing, serial: u32, cur: u32) bool {
        const rev_dist = cur -% serial;
        if (rev_dist >= std.math.maxInt(u32) / 2) {
            // Closer to being 'newer' than the current serial: invalid.
            return false;
        }
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const j = (self.end +% serial_ring_size -% i) % serial_ring_size;
            if (rev_dist < cur -% self.data[j].max_incl) return false;
            if (rev_dist <= cur -% self.data[j].min_incl) return true;
        }
        return self.count == serial_ring_size;
    }
};

/// High-resolution scroll accumulator for one client (wlroots
/// client->value120, wlr_seat.h:56-60 + update_value120_accumulators,
/// wlr_seat_pointer.c:270-318): converts per-event 120ths into whole
/// notches for clients below wl_pointer v8, which have no axis_value120.
const Value120 = struct {
    acc_discrete: [2]i32 = .{ 0, 0 },
    last_discrete: [2]i32 = .{ 0, 0 },
    acc_axis: [2]f64 = .{ 0, 0 },
};

/// Per-client seat state: the serial ringset for serial validation (F2)
/// plus the v120 scroll accumulator (F4). Created on first use, pruned
/// when the client's last keyboard/pointer resource dies.
const SeatClient = struct {
    client: *wire.Client,
    serials: SerialRing = .{},
    value120: Value120 = .{},
    /// A pointer event was delivered to this client without a closing
    /// wl_pointer.frame yet (F7 batching); pointerFrame() flushes it.
    frame_pending: bool = false,
};

/// wl_pointer.set_cursor role (wlroots pointer_cursor_surface_role,
/// wlr_seat_pointer.c:85-90): a cursor surface may carry only this role;
/// F9 enforces it in set_cursor.
const cursor_role: role_mod.SurfaceRole = .{ .name = "wl_pointer-cursor" };

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
    /// Re-armed per focus change (wlroots re-arms surface_destroy
    /// listeners, wlr_seat_keyboard.c:276-287): fires when the focused
    /// surface dies, sending leave (F12) and clearing the focus BEFORE
    /// the Surface frees — no focus pointer can dangle. Detached on
    /// focus change and at seat deinit.
    keyboard_focus_listener: wire.Listener(*Surface),
    /// xkb keycodes currently pressed (sent in keyboard.enter).
    pressed: std.ArrayList(u32) = .empty,
    mods_depressed: u32 = 0,
    mods_latched: u32 = 0,
    mods_locked: u32 = 0,
    /// Effective layout group (wl_keyboard.modifiers.group; 0 for the
    /// single-layout keymap; F10 tracks it so multi-layout keymaps
    /// report the switch).
    mods_group: u32 = 0,
    /// Keysym of the most recent key event (compositor bindings).
    last_keysym: u32 = 0,
    /// Button code of the most recent pointer button event + its state
    /// (compositor bindings; mirrors last_keysym — the button signal is
    /// the notification, these fields carry the payload).
    last_button: u32 = 0,
    last_button_pressed: bool = false,
    /// The most recent scroll axis event: the axis + discrete notch
    /// count (compositor bindings; mirrors last_keysym — the axis signal
    /// is the notification, these fields carry the payload).
    last_axis: server.wl.Pointer.Axis = .vertical_scroll,
    last_axis_discrete: i32 = 0,
    /// The most recent serial this seat handed out. Input events carry it
    /// to the focused client, which echoes it back in serial-bearing
    /// requests (wl_pointer.set_cursor, wl_data_device.set_selection,
    /// wl_data_device.start_drag). Validation is PER CLIENT: serialFor
    /// records each serial in the receiving client's ring, and
    /// validateEventSerial checks that ring (wlroots
    /// wlr_seat_client_validate_event_serial, wlr_seat.c:500-524); this
    /// field is the display's current serial, kept for compat with the
    /// strict-equality consumers (data_device.zig until they move to
    /// validateEventSerial).
    last_serial: u32 = 0,

    // Pointer batching (F7) ---------------------------------------------
    /// axis_source was already sent in the current input batch (one per
    /// frame, wayland.xml:2400); the source sent, for change detection.
    sent_axis_source: bool = false,
    cached_axis_source: ?server.wl.Pointer.AxisSource = null,
    /// Fixed-point position of the last motion event actually sent
    /// (motion dedup, F8 — wlroots drops duplicate fixed-point
    /// positions, wlr_seat_pointer.c:252-263). Sentinel = never sent.
    last_motion_fixed_x: Fixed = @enumFromInt(std.math.minInt(i32)),
    last_motion_fixed_y: Fixed = @enumFromInt(std.math.minInt(i32)),
    /// wl_keyboard.repeat_info payload (get_keyboard, seat.zig:517).
    /// 0/0 = no server-side repeat: clients do their own key repetition
    /// (legal; the compositor takes over repetition only with a repeat
    /// timer, which this seat does not run — see note 132 F13).
    key_repeat_rate: i32 = 0,
    key_repeat_delay: i32 = 0,

    /// Per-client seat state (serial ringset, v120 accumulators, frame
    /// pending): see SeatClient.
    client_state: std.ArrayList(SeatClient) = .empty,

    // Pointer -------------------------------------------------------------
    /// Per-client wl_pointer resources (created on get_pointer).
    pointers: std.ArrayList(*server.wl.Pointer) = .empty,
    pointer_focus: ?*Surface = null,
    /// Same re-armed surface-destroy listener as keyboard_focus_listener
    /// (wlroots wlr_seat_pointer.c:210-225).
    pointer_focus_listener: wire.Listener(*Surface),
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

    /// Hit-test callback: map output coords to the surface under the
    /// pointer (surface-local coords). Null when nothing is hit.
    pick_fn: ?*const fn (ctx: *anyopaque, x: i32, y: i32) ?PickResult = null,
    pick_ctx: ?*anyopaque = null,

    events: struct {
        /// A key was pressed/released. The seat state (last_keysym,
        /// mods) is already updated; read it in the handler.
        key: wire.Signal(*Seat),
        /// A pointer button was pressed/released. The seat state
        /// (last_button, last_button_pressed) is already updated; read
        /// it in the handler.
        button: wire.Signal(*Seat),
        /// The pointer moved. The seat state (pointer_x, pointer_y) is
        /// already updated; read it in the handler.
        pointer_move: wire.Signal(*Seat),
        /// Keyboard focus changed.
        keyboard_focus: wire.Signal(*Seat),
        /// A scroll axis event was fed to the seat (pointerAxis). The
        /// seat state (last_axis, last_axis_discrete) is already
        /// updated; read it in the handler. Emitted even without a
        /// focused surface: the compositor's camera zoom is a viewport
        /// operation, not a client delivery.
        axis: wire.Signal(*Seat),
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
            .client_state = .empty,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
            // SAFETY: the links are put in the detached state below
            // before any focus can arm them.
            .keyboard_focus_listener = wire.Listener(*Surface).init(onKeyboardFocusDestroy),
            .pointer_focus_listener = wire.Listener(*Surface).init(onPointerFocusDestroy),
        };
        errdefer self.pressed.deinit(allocator);
        errdefer self.client_state.deinit(allocator);
        self.keyboard_focus_listener.link.prev = null;
        self.keyboard_focus_listener.link.next = null;
        self.pointer_focus_listener.link.prev = null;
        self.pointer_focus_listener.link.next = null;
        self.events.key.init();
        self.events.button.init();
        self.events.pointer_move.init();
        self.events.keyboard_focus.init();
        self.events.axis.init();
        self.global = try display.addGlobal(server.wl.Seat, *Seat, bindSeat, seat_version, self);
        log.debug("seat created (keyboard + pointer)", io, log_cfg, "seat", .{});
        return self;
    }

    pub fn deinit(self: *Seat) void {
        // Best-effort orderly shutdown (F11): wlroots clears focus with
        // leave on the way out (wlr_seat_destroy, wlr_seat.c:181-196);
        // the display teardown kills client connections right after. The
        // focus pointers are always valid here: the re-armed
        // surface-destroy listeners clear them before any Surface frees.
        if (self.keyboard_focus) |s| {
            const wl_client = s.resource.getClient();
            if (self.clientAlive(wl_client)) {
                const serial = self.nextSerial();
                for (self.keyboards.items) |kbd| {
                    if (kbd.getClient() != wl_client) continue;
                    kbd.sendLeave(serial, s.resource);
                }
            }
        }
        if (self.pointer_focus) |s| {
            const wl_client = s.resource.getClient();
            if (self.clientAlive(wl_client)) {
                const serial = self.nextSerial();
                for (self.pointers.items) |ptr| {
                    if (ptr.getClient() != wl_client) continue;
                    ptr.sendLeave(serial, s.resource);
                    if (ptr.getVersion() >= 5) ptr.sendFrame();
                }
            }
        }
        self.keyboard_focus = null;
        self.pointer_focus = null;
        // Detach the focus-destroy listeners: surfaces may outlive the
        // seat (main.zig frees the seat before the display teardown
        // kills clients), and their destroy signals must not fire into
        // the freed seat.
        if (self.keyboard_focus_listener.link.prev != null) self.keyboard_focus_listener.link.remove();
        if (self.pointer_focus_listener.link.prev != null) self.pointer_focus_listener.link.remove();
        // Deliver the leaves, then destroy the seat's keyboard/pointer
        // resources: their destroy handlers (keyboardDestroy /
        // pointerDestroy) run against THIS seat's lists, so the
        // resources must die before the seat is freed (wlroots
        // seat_client_destroy, wlr_seat.c:257-260). Each destroy prunes
        // the list, so the loops drain.
        self.display.flushClients();
        while (self.keyboards.items.len > 0) self.keyboards.items[0].destroy();
        while (self.pointers.items.len > 0) self.pointers.items[0].destroy();
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        self.keyboards.deinit(allocator);
        self.pointers.deinit(allocator);
        self.client_state.deinit(allocator);
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

    /// Next seat serial: wraps the display counter and records the value,
    /// so serial-bearing client requests (set_cursor, set_selection,
    /// start_drag) can be validated against the seat's last serial.
    fn nextSerial(self: *Seat) u32 {
        self.last_serial = self.display.nextSerial();
        return self.last_serial;
    }

    /// Mint a serial for an event delivered to `client` and record it in
    /// that client's ring (wlroots wlr_seat_client_next_serial,
    /// wlr_seat.c:473-497: each serial-bearing send records on the
    /// RECEIVING client). Serial recording is per client, so a client
    /// may echo any serial it was recently handed — an event to client B
    /// must not invalidate client A's serials (F2).
    fn serialFor(self: *Seat, wl_client: *wire.Client) u32 {
        const serial = self.nextSerial();
        if (self.seatClient(wl_client)) |sc| sc.serials.add(serial);
        return serial;
    }

    /// The per-client state entry for `client`, creating it on first use.
    /// Null on OOM: serial recording is skipped, events still go out.
    fn seatClient(self: *Seat, wl_client: *wire.Client) ?*SeatClient {
        for (self.client_state.items) |*sc| {
            if (sc.client == wl_client) return sc;
        }
        self.client_state.append(self.allocator, .{ .client = wl_client }) catch return null;
        return &self.client_state.items[self.client_state.items.len - 1];
    }

    /// True when the client still owns a live keyboard or pointer
    /// resource (i.e. the client connection is alive).
    fn clientAlive(self: *Seat, wl_client: *wire.Client) bool {
        for (self.keyboards.items) |kbd| {
            if (kbd.getClient() == wl_client) return true;
        }
        for (self.pointers.items) |ptr| {
            if (ptr.getClient() == wl_client) return true;
        }
        return false;
    }

    /// Drop the per-client state once the client's last keyboard/pointer
    /// resource dies (called from the resource destroy handlers).
    fn pruneSeatClient(self: *Seat, wl_client: *wire.Client) void {
        if (self.clientAlive(wl_client)) return;
        for (self.client_state.items, 0..) |sc, i| {
            if (sc.client != wl_client) continue;
            _ = self.client_state.orderedRemove(i);
            return;
        }
    }

    /// Validate a serial echoed by `client` in a serial-bearing request
    /// (wl_pointer.set_cursor, wl_data_device.set_selection/start_drag,
    /// xdg_activation activate): the serial must have been handed to
    /// THIS client recently (wlroots wlr_seat_client_validate_event_serial,
    /// wlr_seat.c:500-524; per-client ring with half-range wrap handling).
    /// A serial the seat never sent — including 0 with an empty ring —
    /// is rejected; the caller ignores the request (never a protocol
    /// error, like wlroots).
    pub fn validateEventSerial(self: *Seat, wl_client: *wire.Client, serial: u32) bool {
        for (self.client_state.items) |*sc| {
            if (sc.client == wl_client) return sc.serials.contains(serial, self.last_serial);
        }
        // No ring for this client: nothing was ever handed to it.
        const empty: SerialRing = .{};
        return empty.contains(serial, self.last_serial);
    }

    /// The pressed keys as a wire array in EVDEV SCANCODE space (the
    /// protocol wire format: clients add 8 to get the xkb keycode,
    /// wayland.xml:2597; wlroots sends scancodes in enter's keys array,
    /// wlr_seat_keyboard.c:234-273). The seat's `pressed` list keeps xkb
    /// keycodes (the state-machine space), so the conversion happens at
    /// the two send sites (F1).
    fn pressedScancodeArray(self: *Seat) wire.wl.Array {
        var buf: [128]u32 = undefined;
        var n: usize = 0;
        for (self.pressed.items) |code| {
            if (n >= buf.len) break;
            buf[n] = code - 8;
            n += 1;
        }
        return .{
            .size = n * @sizeOf(u32),
            .alloc = 0,
            .data = @ptrCast(&buf),
        };
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
        const fx = Fixed.fromInt(@intCast(self.focus_x));
        const fy = Fixed.fromInt(@intCast(self.focus_y));
        // Motion dedup (F8): a move within the same fixed-point cell is
        // dropped (wlroots wlr_seat_pointer_send_motion, wlr_seat_pointer.c:
        // 252-263 — compare against the last sent position).
        if (fx == self.last_motion_fixed_x and fy == self.last_motion_fixed_y) {
            self.events.pointer_move.emit(self);
            return;
        }
        self.last_motion_fixed_x = fx;
        self.last_motion_fixed_y = fy;
        // Motion goes only to the focused client's pointer resources
        // (wlroots: wlr_seat_pointer_send_motion iterates
        // focused_client->pointers, wlr_seat_pointer.c:246-268).
        if (self.pointer_focus) |focus| {
            const focus_client = focus.resource.getClient();
            var delivered = false;
            for (self.pointers.items) |ptr| {
                if (ptr.getClient() != focus_client) continue;
                ptr.sendMotion(time, fx, fy);
                delivered = true;
            }
            if (delivered) self.markFramePending(focus_client);
        }
        self.events.pointer_move.emit(self);
    }

    /// A pointer event was delivered to `client` without a closing frame:
    /// the batch closes at the next pointerFrame() (F7).
    fn markFramePending(self: *Seat, wl_client: *wire.Client) void {
        if (self.seatClient(wl_client)) |sc| sc.frame_pending = true;
    }

    /// Close the current input batch: flush the deferred wl_pointer.frame
    /// events to every client that received pointer events since the last
    /// call, and reset the axis-source dedup (wlroots
    /// wlr_seat_pointer_send_frame, wlr_seat_pointer.c:394-402 — one
    /// frame per input batch, not per event). The server calls this once
    /// per event-loop iteration (main.zig renderFrame); backends feed
    /// events between two calls.
    pub fn pointerFrame(self: *Seat) void {
        self.sent_axis_source = false;
        self.cached_axis_source = null;
        for (self.client_state.items) |*sc| {
            if (!sc.frame_pending) continue;
            sc.frame_pending = false;
            for (self.pointers.items) |ptr| {
                if (ptr.getClient() != sc.client) continue;
                if (ptr.getVersion() >= 5) ptr.sendFrame();
            }
        }
    }

    /// Pointer button press/release (linux input button code). A press
    /// moves keyboard focus to the surface under the pointer.
    pub fn pointerButton(self: *Seat, button: u32, pressed: bool) void {
        // Record the event for compositor listeners (mirrors keyEvent's
        // last_keysym): the camera drag hook reads these from the button
        // signal.
        self.last_button = button;
        self.last_button_pressed = pressed;
        if (pressed) {
            if (self.pointer_focus) |focus| self.setKeyboardFocus(focus);
        }
        const time = nowMs(self);
        const state: server.wl.Pointer.ButtonState = if (pressed) .pressed else .released;
        // Button goes only to the focused client's pointer resources
        // (wlroots: wlr_seat_pointer_send_button iterates
        // focused_client->pointers, wlr_seat_pointer.c:274-295).
        if (self.pointer_focus) |focus| {
            const focus_client = focus.resource.getClient();
            const serial = serialFor(self, focus_client);
            var delivered = false;
            for (self.pointers.items) |ptr| {
                if (ptr.getClient() != focus_client) continue;
                ptr.sendButton(serial, time, button, state);
                delivered = true;
            }
            if (delivered) self.markFramePending(focus_client);
        }
        self.events.button.emit(self);
    }

    /// Vertical/horizontal wheel or scroll axis. `source` is the input
    /// source (wheel/finger/continuous, set by the backend from
    /// libinput_event_pointer_get_axis_source), `value` is in pixels
    /// (10 per notch is the wlroots convention), `discrete` the notches
    /// (finger/continuous sources pass 0). `direction` is the physical
    /// motion direction relative to the axis (natural scrolling inverts
    /// it); identical is the default for wheel devices.
    ///
    /// Event shape follows wlr_seat_pointer_send_axis
    /// (wlr_seat_pointer.c:321-392): value != 0 emits axis_source +
    /// (axis_value120 for v8+ / accumulated axis_discrete for older
    /// clients) + axis, while value == 0 terminates the scroll with
    /// axis_stop. axis_source is sent at most once per input batch (F7,
    /// wayland.xml:2400) and the frame is deferred to pointerFrame().
    /// Events go only to the focused client's pointer resources.
    pub fn pointerAxis(
        self: *Seat,
        axis: server.wl.Pointer.Axis,
        source: server.wl.Pointer.AxisSource,
        value: f64,
        discrete: i32,
    ) void {
        self.pointerAxisDir(axis, source, value, discrete, .identical);
    }

    /// pointerAxis with an explicit relative direction (for
    /// natural-scrolling devices; see wl_pointer.axis_relative_direction,
    /// wayland.xml:2507-2548).
    pub fn pointerAxisDir(
        self: *Seat,
        axis: server.wl.Pointer.Axis,
        source: server.wl.Pointer.AxisSource,
        value: f64,
        discrete: i32,
        direction: server.wl.Pointer.AxisRelativeDirection,
    ) void {
        // Record the event for compositor listeners (mirrors keyEvent's
        // last_keysym): the camera zoom hook reads these from the axis
        // signal. Recorded and emitted BEFORE the focus check — the
        // viewport zoom is a compositor operation, not a client delivery,
        // so it works without a focused surface.
        self.last_axis = axis;
        self.last_axis_discrete = discrete;
        self.events.axis.emit(self);

        const focus = self.pointer_focus orelse return;
        const focus_client = focus.resource.getClient();
        const time = nowMs(self);
        const axis_idx: usize = @intCast(@intFromEnum(axis));

        // axis_source once per frame (wlroots sent_axis_source dedup,
        // wlr_seat_pointer.c:334-342; only one axis_source event is
        // permitted per frame, wayland.xml:2400).
        var send_source = false;
        if (self.sent_axis_source) {
            if (self.cached_axis_source) |cached| {
                if (cached == source) {
                    send_source = false;
                } else {
                    // Source changed mid-batch (different input device):
                    // send the new one (wlroots asserts here; we degrade
                    // gracefully).
                    send_source = true;
                    self.cached_axis_source = source;
                }
            } else {
                send_source = true;
                self.cached_axis_source = source;
            }
        } else {
            self.sent_axis_source = true;
            self.cached_axis_source = source;
            send_source = true;
        }

        // Per-client v120 accumulation: below wl_pointer v8 there is no
        // axis_value120, so per-event 120ths accumulate into whole
        // notches (wlroots update_value120_accumulators,
        // wlr_seat_pointer.c:270-318; the discrete argument is in
        // notches here, scaled to 120ths for the wire).
        var low_res_discrete: i32 = 0;
        var low_res_value: f64 = 0;
        if (discrete != 0) {
            if (self.seatClient(focus_client)) |sc| {
                const v120 = sc.value120;
                if (shouldResetValue120(v120.last_discrete[axis_idx], discrete)) {
                    sc.value120.acc_discrete[axis_idx] = 0;
                    sc.value120.acc_axis[axis_idx] = 0;
                }
                sc.value120.acc_discrete[axis_idx] += discrete * discrete_step;
                sc.value120.last_discrete[axis_idx] = discrete;
                sc.value120.acc_axis[axis_idx] += value;
                low_res_discrete = @divTrunc(sc.value120.acc_discrete[axis_idx], discrete_step);
                if (low_res_discrete != 0) {
                    sc.value120.acc_discrete[axis_idx] -= low_res_discrete * discrete_step;
                    low_res_value = sc.value120.acc_axis[axis_idx];
                    sc.value120.acc_axis[axis_idx] = 0;
                }
            }
        }

        var delivered = false;
        for (self.pointers.items) |ptr| {
            if (ptr.getClient() != focus_client) continue;
            const version = ptr.getVersion();
            if (version < 5) {
                // Pre-v5 clients: axis only (source/discrete/stop do not
                // exist below version 5).
                if (value != 0) {
                    ptr.sendAxis(time, axis, Fixed.fromDouble(value));
                    delivered = true;
                }
                continue;
            }
            if (discrete != 0 and version < 8 and low_res_discrete == 0) {
                // Below v8 with a partial notch accumulated: nothing to
                // report yet (wlroots continues — no source either).
                continue;
            }
            if (send_source) ptr.sendAxisSource(source);
            if (value != 0) {
                if (version >= 9) {
                    // Coupled to the axis event below (wayland.xml:2530-2534).
                    ptr.sendAxisRelativeDirection(axis, direction);
                }
                if (discrete != 0) {
                    if (version >= 8) {
                        // High-res discrete: raw 120ths replace
                        // axis_discrete (wayland.xml:2481-2482).
                        ptr.sendAxisValue120(axis, discrete * discrete_step);
                        ptr.sendAxis(time, axis, Fixed.fromDouble(value));
                    } else {
                        // Low-res discrete for older clients.
                        if (version >= 5) {
                            ptr.sendAxisDiscrete(axis, low_res_discrete);
                        }
                        ptr.sendAxis(time, axis, Fixed.fromDouble(low_res_value));
                    }
                } else {
                    // Continuous scrolling: no discrete component.
                    ptr.sendAxis(time, axis, Fixed.fromDouble(value));
                }
            } else if (version >= 5) {
                // value == 0 terminates the scroll (axis_stop only on
                // zero, wlr_seat_pointer.c:389-391).
                ptr.sendAxisStop(time, axis);
            }
            delivered = true;
        }
        if (delivered) self.markFramePending(focus_client);
    }

    /// Set keyboard focus. Sends leave to the old and enter (with the
    /// currently pressed keys) to the new focus surface. Both go only to
    /// the respective surface's client's keyboards (wlroots:
    /// wlr_seat_keyboard_enter, wlr_seat_keyboard.c:234-311); libwayland
    /// rejects enter/leave carrying a foreign client's surface.
    pub fn setKeyboardFocus(self: *Seat, surface: ?*Surface) void {
        if (surface == self.keyboard_focus) return;
        if (self.keyboard_focus) |old| {
            const old_res = old.resource;
            const old_client = old_res.getClient();
            const serial = serialFor(self, old_client);
            for (self.keyboards.items) |kbd| {
                if (kbd.getClient() != old_client) continue;
                kbd.sendLeave(serial, old_res);
            }
        }
        // Re-arm the surface-destroy listener on the new focus (wlroots
        // wlr_seat_keyboard.c:276-287).
        if (self.keyboard_focus_listener.link.prev != null) self.keyboard_focus_listener.link.remove();
        self.keyboard_focus = surface;
        if (surface) |s| {
            s.events.destroy.add(&self.keyboard_focus_listener);
            const s_res = s.resource;
            const s_client = s_res.getClient();
            const serial = serialFor(self, s_client);
            var keys = self.pressedScancodeArray();
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
    /// to the focused client and emits the key signal. The WIRE keycode
    /// is the evdev scancode (keycode minus 8): the protocol requires
    /// clients to add 8 to get the xkb keycode (wayland.xml:2597), and
    /// wlroots sends scancodes (wlr_seat_keyboard.c:67-84) while keeping
    /// xkb keycodes internally (wlr_keyboard.c:115-120) — F1.
    pub fn keyEvent(self: *Seat, keycode: u32, pressed: bool) void {
        self.last_keysym = self.xkb.updateKey(keycode, pressed);

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
            mods.locked != self.mods_locked or
            mods.group != self.mods_group)
        {
            self.mods_depressed = mods.depressed;
            self.mods_latched = mods.latched;
            self.mods_locked = mods.locked;
            self.mods_group = mods.group;
            // Modifier broadcasts go only to the focused client's
            // keyboards (wlroots: wlr_seat_keyboard_send_modifiers
            // iterates focused_client->keyboards).
            self.sendKeyboardModifiers();
        }

        const state: server.wl.Keyboard.KeyState = if (pressed) .pressed else .released;
        const time = nowMs(self);
        // Key events go only to the focused client's keyboards
        // (wlroots: wlr_seat_keyboard_send_key iterates
        // focused_client->keyboards, wlr_seat_keyboard.c:67-84).
        if (self.keyboard_focus) |focus| {
            const focus_client = focus.resource.getClient();
            const serial = serialFor(self, focus_client);
            for (self.keyboards.items) |kbd| {
                if (kbd.getClient() != focus_client) continue;
                kbd.sendKey(serial, time, keycode - 8, state);
            }
        }
        self.events.key.emit(self);
    }

    /// Current cursor surface resource (client-set via
    /// wl_pointer.set_cursor); null cursor surface means hidden.
    pub fn cursorSurface(self: *Seat) ?*server.wl.Surface {
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
    /// modifier change. Carries the effective layout group (F10).
    fn sendKeyboardModifiers(self: *Seat) void {
        const focus = self.keyboard_focus orelse return;
        const focus_client = focus.resource.getClient();
        const serial = serialFor(self, focus_client);
        for (self.keyboards.items) |kbd| {
            if (kbd.getClient() != focus_client) continue;
            kbd.sendModifiers(serial, self.mods_depressed, self.mods_latched, self.mods_locked, self.mods_group);
        }
    }

    /// Re-send the keymap to every client's keyboards (the keymap-change
    /// broadcast, F10; wlroots handle_keyboard_keymap re-broadcasts to
    /// all seat clients, wlr_seat_keyboard.c:87-99). The keymap text is
    /// unchanged while the seat compiles one keymap.
    pub fn broadcastKeymap(self: *Seat) void {
        const fd = self.xkb.dupKeymapFd();
        if (fd < 0) return;
        defer _ = std.os.linux.close(fd);
        for (self.keyboards.items) |kbd| {
            kbd.sendKeymap(.xkb_v1, fd, self.xkb.keymap_size);
        }
    }

    /// Replace the keyboard layout at runtime (F10; wlroots
    /// wlr_keyboard_set_keymap re-sends the keymap via the keymap
    /// signal): rebuild the xkb keymap/state, re-broadcast the keymap
    /// to all clients and re-send the modifiers (the group may have
    /// changed). Compositor-driven — the server wires it from
    /// WAYLAND_KEYBOARD_LAYOUT.
    pub fn setKeyboardLayout(self: *Seat, layout: []const u8) void {
        self.xkb.setLayout(layout) catch |err| {
            log.warn("keymap change to {s} failed: {s}", self.io, self.log_cfg, "seat", .{
                layout, @errorName(err),
            });
            return;
        };
        // A fresh state starts with no modifiers and group 0.
        self.mods_depressed = 0;
        self.mods_latched = 0;
        self.mods_locked = 0;
        self.mods_group = 0;
        self.broadcastKeymap();
        if (self.keyboard_focus != null) self.sendKeyboardModifiers();
    }

    /// A surface was destroyed: drop any focus pointing at it. The
    /// surface is still alive inside the destroy signal (the caller,
    /// main.zig:1572, runs before the Surface frees), so the focused
    /// client gets its leave events first — KWin sends leave with a
    /// fresh serial on aboutToBeDestroyed (keyboard.cpp:138-141,
    /// pointer.cpp:96-101); wlroots clears silently (F12). Also the
    /// seat's own re-armed surface-destroy listeners route here, so the
    /// focus pointers can never dangle. Idempotent.
    pub fn surfaceDestroyed(self: *Seat, surface: *Surface) void {
        if (self.pointer_focus == surface) self.pointerLeave();
        if (self.keyboard_focus == surface) {
            if (self.keyboard_focus_listener.link.prev != null) self.keyboard_focus_listener.link.remove();
            const serial = self.nextSerial();
            const wl_client = surface.resource.getClient();
            for (self.keyboards.items) |kbd| {
                if (kbd.getClient() != wl_client) continue;
                kbd.sendLeave(serial, surface.resource);
            }
            self.keyboard_focus = null;
        }
    }

    fn pointerEnter(self: *Seat, surface: *Surface, sx: i32, sy: i32) void {
        // Re-arm the surface-destroy listener (wlroots
        // wlr_seat_pointer.c:210-225).
        if (self.pointer_focus_listener.link.prev != null) self.pointer_focus_listener.link.remove();
        self.pointer_focus = surface;
        surface.events.destroy.add(&self.pointer_focus_listener);
        self.pointer_enter_serial = serialFor(self, surface.resource.getClient());
        self.focus_x = sx;
        self.focus_y = sy;
        const res = surface.resource;
        // Reset the motion-dedup base to "never sent": a motion must
        // follow every enter, even at the same position — dedup only
        // suppresses REPEATS of a position that was already delivered
        // (the E2E synth moves to the exact enter position; suppressing
        // that first motion starves the client's motion check).
        self.last_motion_fixed_x = @enumFromInt(std.math.minInt(i32));
        self.last_motion_fixed_y = @enumFromInt(std.math.minInt(i32));
        // Enter goes only to the surface's client's pointer resources
        // (wlroots: wlr_seat_pointer_enter loops over client->pointers,
        // wlr_seat_pointer.c:184-196). Sending a foreign surface to
        // another client's wl_pointer is rejected by libwayland, which
        // flags the client connection as errored.
        const surface_client = res.getClient();
        var delivered = false;
        for (self.pointers.items) |ptr| {
            if (ptr.getClient() != surface_client) continue;
            ptr.sendEnter(
                self.pointer_enter_serial,
                res,
                Fixed.fromInt(@intCast(sx)),
                Fixed.fromInt(@intCast(sy)),
            );
            delivered = true;
        }
        if (delivered) self.markFramePending(surface_client);
        log.debug("pointer enter surface@{d} at {d},{d}", self.io, self.log_cfg, "seat", .{
            res.getId(), sx, sy,
        });
    }

    fn pointerLeave(self: *Seat) void {
        if (self.pointer_focus_listener.link.prev != null) self.pointer_focus_listener.link.remove();
        const serial = serialFor(self, self.pointer_focus.?.resource.getClient());
        const old = self.pointer_focus.?;
        const res = old.resource;
        // Leave goes only to the leaving surface's client's pointers
        // (wlroots: seat_client_send_pointer_leave_raw,
        // wlr_seat_pointer.c:148-158).
        const old_client = res.getClient();
        var delivered = false;
        for (self.pointers.items) |ptr| {
            if (ptr.getClient() != old_client) continue;
            ptr.sendLeave(serial, res);
            delivered = true;
        }
        if (delivered) self.markFramePending(old_client);
        self.pointer_focus = null;
        log.debug("pointer leave surface@{d}", self.io, self.log_cfg, "seat", .{res.getId()});
    }

    /// The focused keyboard surface died (its destroy signal): clear the
    /// focus with leave (F12) before the Surface frees.
    fn onKeyboardFocusDestroy(listener: *wire.Listener(*Surface), surface: *Surface) void {
        const self: *Seat = @fieldParentPtr("keyboard_focus_listener", listener);
        self.surfaceDestroyed(surface);
    }

    /// The focused pointer surface died: same as onKeyboardFocusDestroy.
    fn onPointerFocusDestroy(listener: *wire.Listener(*Surface), surface: *Surface) void {
        const self: *Seat = @fieldParentPtr("pointer_focus_listener", listener);
        self.surfaceDestroyed(surface);
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
            kbd.setHandler(*Seat, keyboardRequest, keyboardDestroy, seat);
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
            if (kbd.getVersion() >= 4) kbd.sendRepeatInfo(seat.key_repeat_rate, seat.key_repeat_delay);
            // Late enter only for the focused client (wlroots:
            // focused_client == seat_client, wlr_seat_keyboard.c:449-460).
            // A foreign-surface enter is rejected by libwayland.
            if (seat.keyboard_focus) |s| {
                if (kbd.getClient() == s.resource.getClient()) {
                    var keys = seat.pressedScancodeArray();
                    kbd.sendEnter(seat.serialFor(kbd.getClient()), s.resource, &keys);
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
            ptr.setHandler(*Seat, pointerRequest, pointerDestroy, seat);
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
                        seat.serialFor(ptr.getClient()),
                        s.resource,
                        Fixed.fromInt(@intCast(seat.focus_x)),
                        Fixed.fromInt(@intCast(seat.focus_y)),
                    );
                    seat.markFramePending(ptr.getClient());
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

/// wl_keyboard resource died: drop it from the seat's list and prune the
/// per-client state when this was the client's last input resource.
fn keyboardDestroy(resource: *server.wl.Keyboard, seat: *Seat) void {
    const idx = std.mem.indexOfScalar(*server.wl.Keyboard, seat.keyboards.items, resource) orelse 0;
    if (idx < seat.keyboards.items.len and seat.keyboards.items[idx] == resource) {
        _ = seat.keyboards.orderedRemove(idx);
    }
    seat.pruneSeatClient(resource.getClient());
}

/// wl_pointer resource died: same bookkeeping as keyboardDestroy.
fn pointerDestroy(resource: *server.wl.Pointer, seat: *Seat) void {
    const idx = std.mem.indexOfScalar(*server.wl.Pointer, seat.pointers.items, resource) orelse 0;
    if (idx < seat.pointers.items.len and seat.pointers.items[idx] == resource) {
        _ = seat.pointers.orderedRemove(idx);
    }
    seat.pruneSeatClient(resource.getClient());
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
        // F9: the cursor surface applies only when the requesting client
        // is the focused one AND the serial is one this client was
        // recently handed (the enter serial qualifies: wlroots validates
        // over the client's serial ring, smithay last_enter, KWin the
        // enter serial). The unfocused allowance is gone (it let ANY
        // client swap the cursor while the pointer was outside all
        // surfaces), and the surface may carry only the pointer-cursor
        // role — a conflict posts WL_POINTER_ERROR_ROLE on this pointer
        // resource (wlroots pointer_set_cursor, wlr_seat_pointer.c:85-100;
        // smithay pointer.rs:380-386; KWin pointer.cpp:66-95). Requests
        // that fail the focus/serial checks are silently ignored, never
        // a protocol error.
        .set_cursor => |r| {
            const focus = seat.pointer_focus orelse return;
            if (focus.resource.getClient() != resource.getClient()) return;
            if (!seat.validateEventSerial(resource.getClient(), r.serial)) return;
            if (r.surface) |sr| {
                // The Surface is the wl_surface resource's user data;
                // null = the surface is inert (destroyed) — ignore.
                const ud = sr.getUserData() orelse return;
                const surf: *Surface = @ptrCast(@alignCast(ud));
                if (surf.role) |cur| {
                    if (cur != &cursor_role) {
                        resource.postError(.role, "surface already has a different role");
                        return;
                    }
                } else {
                    surf.role = &cursor_role;
                    surf.role_resource = null;
                }
            }
            seat.cursor_surface_resource = r.surface;
            seat.cursor_hotspot_x = r.hotspot_x;
            seat.cursor_hotspot_y = r.hotspot_y;
            log.debug("cursor surface set (serial={d})", seat.io, seat.log_cfg, "seat", .{r.serial});
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
    /// The enter event's pressed-keys array (wire format = evdev
    /// scancodes; F1) — first 8 entries.
    enter_keys: [8]u32 = undefined,
    enter_key_count: usize = 0,
    modifiers: usize = 0,
    mods_depressed: u32 = 0,
    mods_group: u32 = 0,
    repeat_info: usize = 0,
    repeat_rate: i32 = 0,
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
                const keys = e.keys.slice(u32);
                data.enter_key_count = @min(keys.len, data.enter_keys.len);
                for (keys[0..data.enter_key_count], 0..) |k, i| data.enter_keys[i] = k;
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
                data.mods_group = e.group;
                data.log(.modifiers);
            },
            .repeat_info => |e| {
                data.repeat_info += 1;
                data.repeat_rate = e.rate;
            },
        }
    }
};

/// Event counts for one client-side wl_pointer.
const PointerEvents = struct {
    entered: bool = false,
    enter_surface_id: u32 = 0,
    left: usize = 0,
    motion: usize = 0,
    button: usize = 0,
    axis: usize = 0,
    axis_stop: usize = 0,
    axis_discrete: usize = 0,
    axis_source: usize = 0,
    axis_value120: usize = 0,
    axis_relative_direction: usize = 0,
    frame: usize = 0,

    fn listener(pointer: *client.wl.Pointer, event: client.wl.Pointer.Event, data: *PointerEvents) void {
        _ = pointer;
        switch (event) {
            .enter => |e| {
                data.entered = true;
                if (e.surface) |s| data.enter_surface_id = s.getId();
            },
            .leave => data.left += 1,
            .motion => data.motion += 1,
            .button => data.button += 1,
            .axis => data.axis += 1,
            .axis_stop => data.axis_stop += 1,
            .axis_discrete => data.axis_discrete += 1,
            .axis_source => data.axis_source += 1,
            .axis_value120 => data.axis_value120 += 1,
            .axis_relative_direction => data.axis_relative_direction += 1,
            .frame => data.frame += 1,
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
    /// without blocking. Closes the seat's input batch first (the
    /// server's render loop does this too, main.zig renderFrame): the
    /// deferred wl_pointer.frame events flush with the batch.
    fn pump(ts: *TestServer) !void {
        if (ts.clients >= 1) {
            if (ts.a.display.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        if (ts.clients >= 2) {
            if (ts.b.display.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        if (ts.seat) |s| s.pointerFrame();
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
/// (v10, the seat's advertised version), create a surface and the
/// seat's keyboard/pointer objects.
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
    const wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, seat_version);
    // Bind the fallible calls to locals first: a struct literal with two
    // `try`s leaks the first allocation if the second fails (zbc).
    const surface = try wl_compositor.createSurface();
    const keyboard = try wl_seat.getKeyboard();
    const pointer = try wl_seat.getPointer();
    tc.* = .{
        .server = server_client,
        .display = c_display,
        .compositor = wl_compositor,
        .seat = wl_seat,
        .surface = surface,
        .keyboard = keyboard,
        .pointer = pointer,
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
    // The FIRST motion after the enter delivers even at the same
    // position (F8 dedup only suppresses repeats of an already-delivered
    // position — a motion must follow every enter).
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.motion);
    // A repeat of the delivered position is deduped (wlroots
    // wlr_seat_pointer.c:252-263).
    ts.seat.?.pointerMotion(10, 10);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.motion);
    // A new-cell move delivers.
    ts.seat.?.pointerMotion(10, 11);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), a.ptr_events.motion);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.motion);

    // Button press: click-to-focus moves keyboard focus to A's surface;
    // the button event goes only to the focused client.
    ts.seat.?.pointerButton(btn_left, true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.button);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.button);
    try std.testing.expect(a.kbd_events.entered);
    try std.testing.expect(!b.kbd_events.entered);

    // Key events go only to the focused client's keyboard; the WIRE
    // keycode is the evdev scancode (xkb keycode 38 minus 8 = 30, F1).
    ts.seat.?.keyEvent(38, true); // 'a' (evdev A + 8)
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.kbd_events.keys);
    try std.testing.expectEqual(@as(usize, 0), b.kbd_events.keys);
    try std.testing.expectEqual(@as(u32, 30), a.kbd_events.last_key);

    // Modifier change (left shift, keycode 50) also goes only to the
    // focused client. The earlier click-to-focus already delivered one
    // post-enter modifiers event to A.
    ts.seat.?.keyEvent(50, true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), a.kbd_events.modifiers);
    try std.testing.expectEqual(@as(usize, 0), b.kbd_events.modifiers);
    try std.testing.expectEqual(@as(u32, 1), a.kbd_events.mods_depressed);

    // Wheel burst (discrete != 0) to a v10 client: axis_source +
    // axis_relative_direction + axis_value120 + axis, no axis_discrete
    // (replaced at v8) and no axis_stop; only the focused client.
    ts.seat.?.pointerAxis(.vertical_scroll, .wheel, 10.0, 1);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_source);
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_value120);
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_relative_direction);
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis);
    try std.testing.expectEqual(@as(usize, 0), a.ptr_events.axis_discrete);
    try std.testing.expectEqual(@as(usize, 0), a.ptr_events.axis_stop);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis_source);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis_value120);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis);
    try std.testing.expectEqual(@as(usize, 0), b.ptr_events.axis_stop);

    // Scroll end (value == 0): axis_stop only, no axis; only the focused
    // client. axis_source is sent once per frame — the batch closed at
    // the pump's pointerFrame, so the stop's own batch re-sends it (F7).
    ts.seat.?.pointerAxis(.vertical_scroll, .wheel, 0.0, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_stop);
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis); // unchanged
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_value120); // unchanged
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

test "keyboard enter carries evdev scancodes, not xkb keycodes (F1)" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const b = &ts.b;
    const surface_a = surfaceForClient(ts, a.server);
    const surface_b = surfaceForClient(ts, b.server);

    // Hold 'a' (xkb keycode 38) with focus on A, then switch focus to B:
    // B's enter carries the pressed key as the evdev SCANCODE 30 (the
    // wire format; the protocol requires clients to add 8, wayland.xml:2597).
    ts.seat.?.setKeyboardFocus(surface_a);
    ts.seat.?.keyEvent(38, true);
    try ts.pump();
    ts.seat.?.setKeyboardFocus(surface_b);
    try ts.pump();
    try std.testing.expect(b.kbd_events.entered);
    try std.testing.expectEqual(@as(usize, 1), b.kbd_events.enter_key_count);
    try std.testing.expectEqual(@as(u32, 30), b.kbd_events.enter_keys[0]);
}

test "serial validation is per client with a recent-serial ring (F2)" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const b = &ts.b;
    const seat = ts.seat.?;
    const surface_a = surfaceForClient(ts, a.server);

    // No serial was ever handed to either client: 0 is rejected (wlroots
    // validates over the per-client ring, wlr_seat.c:500-524).
    try std.testing.expect(!seat.validateEventSerial(a.server, 0));
    try std.testing.expect(!seat.validateEventSerial(b.server, 0));

    // A pointer enter mints a serial for A only.
    ts.pick_state.surface = surface_a;
    seat.pointerMotion(10, 10);
    try ts.pump();
    const serial_a = seat.pointer_enter_serial;
    try std.testing.expect(seat.validateEventSerial(a.server, serial_a));
    // B was never handed A's serial: rejected for B (false-reject fix:
    // an event to A must not invalidate A's serials, and must not
    // validate for B).
    try std.testing.expect(!seat.validateEventSerial(b.server, serial_a));

    // A serial the seat never handed out is rejected for everyone.
    const bogus = seat.display.nextSerial();
    try std.testing.expect(!seat.validateEventSerial(a.server, bogus));
    try std.testing.expect(!seat.validateEventSerial(b.server, bogus));

    // A keyboard event serial for A also validates for A (any serial the
    // seat recently handed this client, not just the last one).
    seat.setKeyboardFocus(surface_a);
    seat.keyEvent(38, true);
    try ts.pump();
    const last_serial = seat.last_serial;
    try std.testing.expect(seat.validateEventSerial(a.server, serial_a));
    try std.testing.expect(seat.validateEventSerial(a.server, last_serial));
}

test "v8+ clients get axis_value120, v7 clients get accumulated discrete (F4)" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const seat = ts.seat.?;
    const surface_a = surfaceForClient(ts, a.server);

    // Bind a SECOND wl_pointer for client A at seat version 7 (a fresh
    // registry round): its resources are v7, so it gets axis_discrete
    // where the v10 pointer gets axis_value120 (wayland.xml:2481-2482).
    const registry = try a.display.getRegistry();
    var capture: RegistryCapture = .{};
    registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
    try pumpOne(ts, a.display);
    const seat7 = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
    const ptr7 = try seat7.getPointer();
    var ptr7_events: PointerEvents = .{};
    ptr7.setListener(*PointerEvents, PointerEvents.listener, &ptr7_events);
    try ts.pump();

    ts.pick_state.surface = surface_a;
    seat.pointerMotion(10, 10);
    try ts.pump();

    seat.pointerAxis(.vertical_scroll, .wheel, 10.0, 1);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_value120);
    try std.testing.expectEqual(@as(usize, 0), a.ptr_events.axis_discrete);
    try std.testing.expectEqual(@as(usize, 1), ptr7_events.axis_discrete);
    try std.testing.expectEqual(@as(usize, 0), ptr7_events.axis_value120);
    // The v7 client got the accumulated value too.
    try std.testing.expectEqual(@as(usize, 1), ptr7_events.axis);
}

test "axis events batch into one frame with a single axis_source (F7)" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const seat = ts.seat.?;
    const surface_a = surfaceForClient(ts, a.server);

    ts.pick_state.surface = surface_a;
    seat.pointerMotion(10, 10);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.frame); // enter batch

    // Two wheel notches in ONE batch: one axis_source (dedup,
    // wayland.xml:2400), two axis events, one closing frame.
    seat.pointerAxis(.vertical_scroll, .wheel, 10.0, 1);
    seat.pointerAxis(.vertical_scroll, .wheel, 10.0, 1);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.axis_source);
    try std.testing.expectEqual(@as(usize, 2), a.ptr_events.axis);
    try std.testing.expectEqual(@as(usize, 2), a.ptr_events.axis_value120);
    try std.testing.expectEqual(@as(usize, 2), a.ptr_events.frame);

    // The next batch re-sends axis_source (reset at the frame boundary).
    seat.pointerAxis(.vertical_scroll, .wheel, 10.0, 1);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), a.ptr_events.axis_source);
}

test "set_cursor requires focus, a valid serial and the cursor role (F9)" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const b = &ts.b;
    const seat = ts.seat.?;
    const surface_a = surfaceForClient(ts, a.server);

    // Unfocused: any client's set_cursor is ignored (the old code let
    // ANY client set the cursor while the pointer was outside surfaces).
    a.pointer.setCursor(1234, a.surface, 0, 0);
    try ts.pump();
    try std.testing.expect(seat.cursorSurface() == null);

    // Focus A; the enter serial becomes valid for A.
    ts.pick_state.surface = surface_a;
    seat.pointerMotion(10, 10);
    try ts.pump();
    const valid_serial = seat.pointer_enter_serial;

    // Stale serial (never handed out): ignored.
    const bogus = seat.display.nextSerial();
    a.pointer.setCursor(bogus, a.surface, 1, 2);
    try ts.pump();
    try std.testing.expect(seat.cursorSurface() == null);

    // The unfocused client B with a valid-looking serial: ignored.
    b.pointer.setCursor(valid_serial, b.surface, 0, 0);
    try ts.pump();
    try std.testing.expect(seat.cursorSurface() == null);

    // Focused client + valid serial: accepted, hotspot recorded.
    a.pointer.setCursor(valid_serial, a.surface, 5, 6);
    try ts.pump();
    try std.testing.expect(seat.cursorSurface() != null);
    try std.testing.expectEqual(@as(i32, 5), seat.cursor_hotspot_x);
    try std.testing.expectEqual(@as(i32, 6), seat.cursor_hotspot_y);

    // Role conflict: a surface with a different role posts
    // WL_POINTER_ERROR_ROLE on the pointer resource (wlroots
    // pointer_set_cursor, wlr_seat_pointer.c:96-100), which kills the
    // client connection; the cursor keeps its previous image (the
    // handler returns before touching the seat state).
    var fake_role: role_mod.SurfaceRole = .{ .name = "fake-role" };
    surface_a.role = &fake_role;
    surface_a.role_resource = null;
    a.pointer.setCursor(valid_serial, a.surface, 0, 0);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(i32, 5), seat.cursor_hotspot_x);
}

test "keymap change re-broadcasts to all clients (F10)" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const b = &ts.b;
    const seat = ts.seat.?;
    try std.testing.expectEqual(@as(usize, 1), a.kbd_events.keymaps);
    try std.testing.expectEqual(@as(usize, 1), b.kbd_events.keymaps);

    // A runtime layout switch re-broadcasts the keymap to EVERY client
    // (wlroots handle_keyboard_keymap, wlr_seat_keyboard.c:87-99) and
    // re-sends the modifiers to the focused client with the group.
    const surface_a = surfaceForClient(ts, a.server);
    seat.setKeyboardFocus(surface_a);
    try ts.pump();
    const modifiers_before = a.kbd_events.modifiers;

    seat.setKeyboardLayout("us");
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), a.kbd_events.keymaps);
    try std.testing.expectEqual(@as(usize, 2), b.kbd_events.keymaps);
    // Modifiers re-sent with the (single-layout) group 0.
    try std.testing.expectEqual(modifiers_before + 1, a.kbd_events.modifiers);
    try std.testing.expectEqual(@as(u32, 0), a.kbd_events.mods_group);
    // repeat_info was advertised at bind (F4: configurable rate/delay).
    try std.testing.expectEqual(@as(usize, 1), a.kbd_events.repeat_info);
    try std.testing.expectEqual(seat.key_repeat_rate, a.kbd_events.repeat_rate);
}

test "seat teardown sends leave to the focused client (F11)" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const surface_a = surfaceForClient(ts, a.server);
    ts.pick_state.surface = surface_a;
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.setKeyboardFocus(surface_a);
    try ts.pump();

    // Tear the seat down while the clients are still connected: the
    // focused client is told (wlr_seat_destroy clears focus with leave,
    // wlr_seat.c:181-196).
    const seat = ts.seat.?;
    ts.seat = null;
    seat.deinit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.left);
    try std.testing.expectEqual(KeyboardEvents.Order.leave, a.kbd_events.order[a.kbd_events.order_len - 1]);
}

test "focused-surface destroy sends leave before clearing (F12)" {
    const allocator = std.testing.allocator;
    const ts = TestServer.init(allocator) catch |err| {
        std.debug.print("seat test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();

    const a = &ts.a;
    const seat = ts.seat.?;
    const surface_a = surfaceForClient(ts, a.server);
    ts.pick_state.surface = surface_a;
    seat.pointerMotion(10, 10);
    seat.setKeyboardFocus(surface_a);
    try ts.pump();

    // KWin sends leave with a fresh serial on aboutToBeDestroyed
    // (keyboard.cpp:138-141, pointer.cpp:96-101); the surface is still
    // alive inside the destroy signal (main.zig:1572 runs before the
    // Surface frees).
    seat.surfaceDestroyed(surface_a);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), a.ptr_events.left);
    try std.testing.expectEqual(KeyboardEvents.Order.leave, a.kbd_events.order[a.kbd_events.order_len - 1]);
    try std.testing.expect(seat.pointer_focus == null);
    try std.testing.expect(seat.keyboard_focus == null);
}
