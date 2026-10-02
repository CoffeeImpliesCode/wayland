//! zwp_relative_pointer_manager_v1 / zwp_relative_pointer_v1 (unstable/
//! relative-pointer, v1): unaccelerated relative motion for the seat's
//! pointer.
//!
//! WHAT THE PROTOCOL CARRIES. zwp_relative_pointer_v1 declares exactly ONE
//! event, `relative_motion` (relative-pointer-unstable-v1.xml:88-125). The
//! task text asked for `relative_motion_absolute` as well; that event does
//! NOT exist in this protocol revision — the bindings have no such event and
//! there is nothing to send. It is therefore not implemented, because
//! implementing it would mean inventing a wire message.
//!
//! WHAT THE SEAT PROVIDES. Seat.events.pointer_move is a Signal(*Seat):
//! it carries NO payload beyond the seat, and the seat's own state holds
//! only the ABSOLUTE pointer position — Seat.pointer_x / Seat.pointer_y in
//! output coordinates (seat.zig:495-513, :456-458). wlroots by contrast
//! feeds wlr_relative_pointer_manager_v1_send_relative_motion the raw
//! libinput deltas (wlr_relative_pointer_v1.c:187-209). This module
//! therefore DERIVES the delta from consecutive absolute positions:
//!   dx = pointer_x - previous_pointer_x, dy likewise,
//! exactly the relation the XML states — "moving a pointer from (x, y) to
//! (x', y') would have the equivalent relative motion (x' - x, y' - y)"
//! (XML:92-94). The first motion after (re)attaching only establishes the
//! baseline and sends nothing, so no bogus jump from (0,0) is invented.
//!
//! Consequences, stated plainly:
//! - The XML also says the relative motion is "unaffected by the clipping"
//!   that wl_pointer.motion suffers at the screen edge (XML:95-97). With a
//!   derived delta the reported motion is the motion the compositor actually
//!   observed, i.e. already clipped. A backend that has the true unclipped
//!   deltas calls sendRelativeMotion directly (the wlroots entry point);
//!   then the derived path must be told where the pointer ended with
//!   syncPointerPosition.
//! - NO acceleration model is invented. The seat applies none —
//!   Seat.pointerMotion takes absolute output coordinates straight from the
//!   backend — so dx_unaccel/dy_unaccel equal dx/dy. That is exactly the
//!   case the XML sanctions: "non-accelerated deltas and accelerated
//!   deltas may have the same value on some devices" (XML:108-111).
//!
//! FIXED POINT AND TIMESTAMP. dx/dy/dx_unaccel/dy_unaccel are `fixed`,
//! i.e. 24.8 signed (wayland.xml). The deltas are whole pixels, so they are
//! converted with Fixed.fromInt (no rounding). utime_hi/utime_lo are the
//! high and low 32 bits of one 64-bit timestamp with MICROSECOND
//! granularity (XML:100-104), so the module reads a microsecond clock and
//! splits it exactly like wlroots does (`(uint32_t)(time_usec >> 32),
//! (uint32_t)time_usec`, wlr_relative_pointer_v1.c:204-207).
//!
//! FOCUS GATING. wlroots delivers only to relative pointers whose
//! wl_pointer belongs to the seat's FOCUSED client and returns early when
//! nothing is focused (wlr_relative_pointer_v1.c:191-201). Identical here.
//!
//! Cross-module contract: the manager binds per client;
//! get_relative_pointer creates one object per wl_pointer. A wl_pointer that
//! is not one of the live Seat.pointers — including any pointer created
//! while the seat's pointer capability was disabled (seat.zig:1778), and
//! every pointer when there is no seat at all — yields an INERT object:
//! it exists, it accepts destroy, it never emits (wlroots leaves the
//! resource implementation-less, wlr_relative_pointer_v1.c:92-95). Every
//! resource is tracked so deinit destroys it; no handler data outlives the
//! module. setSeat(null) detaches the seat listeners and clears the delta
//! baseline.

const std = @import("std");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const seat_mod = @import("../compositor/seat.zig");
const display_mod = @import("../core/display.zig");
const geom = @import("../utils/geom.zig");

const log_tag = "relative_pointer";
const Fixed = wire.wl.Fixed;

/// Pixel delta -> 24.8 fixed, saturating. Fixed.fromInt takes an i24, whose
/// largest value is 2^23 - 1, so a larger delta would trap @intCast.
fn fixedFromPixels(d: i64) Fixed {
    const limit: i64 = (1 << 23) - 1;
    const clamped: i64 = if (d > limit) limit else if (d < -limit) -limit else d;
    return Fixed.fromInt(@intCast(clamped));
}

/// Microsecond timestamp, split for utime_hi / utime_lo (XML:100-104).
fn nowMicros(io: *std.Io) u64 {
    const ns = std.Io.Clock.now(.awake, io.*).toNanoseconds();
    return @intCast(@max(ns, 0) / 1000);
}

/// Per-zwp_relative_pointer_v1 state. `seat` is the seat the wl_pointer
/// belonged to at creation; null makes the object permanently INERT.
const RelativeState = struct {
    manager: *RelativePointer,
    seat: ?*seat_mod.Seat,
    res: *server.zwp.RelativePointerV1,
};

pub const RelativePointer = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The seat whose pointer motion drives the events; null when the
    /// compositor has no seat yet — the global still binds and every
    /// relative-pointer object is inert.
    seat: ?*seat_mod.Seat,
    /// The zwp_relative_pointer_manager_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// Bound manager resources (one per client bind).
    managers: std.ArrayList(*server.zwp.RelativePointerManagerV1) = .empty,
    /// Live zwp_relative_pointer_v1 objects.
    pointers: std.ArrayList(*RelativeState) = .empty,

    /// Seat motion / seat-destroy listeners. They live exactly as long as
    /// the module (removed by setSeat and deinit) and the module owns the
    /// seat pointer they dereference.
    motion_listener: wire.Listener(*seat_mod.Seat),
    seat_destroy_listener: wire.Listener(*seat_mod.Seat),

    /// Whether last_x/last_y hold a real previous pointer position.
    have_last: bool = false,
    last_x: i32 = 0,
    last_y: i32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        seat: ?*seat_mod.Seat,
    ) error{ OutOfMemory, GlobalCreateFailed }!*RelativePointer {
        const self = try allocator.create(RelativePointer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .seat = null,
            // SAFETY: the links are put in the detached state by setSeat
            // below (and stay there while self.seat is null) before any
            // seat can reach them, so Listener.init leaving them
            // undefined is never observed.
            .motion_listener = wire.Listener(*seat_mod.Seat).init(onSeatMotion),
            .seat_destroy_listener = wire.Listener(*seat_mod.Seat).init(onSeatDestroy),
        };
        errdefer self.managers.deinit(allocator);
        errdefer self.pointers.deinit(allocator);
        self.global = try display.addGlobal(
            server.zwp.RelativePointerManagerV1,
            *RelativePointer,
            relativeManagerBind,
            server.zwp.RelativePointerManagerV1.generated_version,
            self,
        );
        self.setSeat(seat);
        return self;
    }

    pub fn deinit(self: *RelativePointer) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Detach from the seat first: a detached listener must not fire
        // into a module that is about to free its state.
        self.setSeat(null);
        while (self.pointers.items.len > 0) self.pointers.items[0].res.destroy();
        while (self.managers.items.len > 0) self.managers.items[0].destroy();
        self.pointers.deinit(allocator);
        self.managers.deinit(allocator);
        allocator.destroy(self);
    }

    /// Attach (or detach, with null) the seat whose pointer motion drives
    /// the events. Detaching clears the delta baseline, so re-attaching
    /// never reports the jump between the old and the new pointer position.
    pub fn setSeat(self: *RelativePointer, seat: ?*seat_mod.Seat) void {
        if (self.seat == seat) return;
        if (self.seat != null) {
            // wire.Signal has no remove(); the links are live exactly
            // while self.seat != null (added below, removed here).
            self.motion_listener.link.remove();
            self.seat_destroy_listener.link.remove();
        }
        self.have_last = false;
        self.seat = seat;
        if (seat) |s| {
            s.events.pointer_move.add(&self.motion_listener);
            s.events.destroy.add(&self.seat_destroy_listener);
        }
    }

    /// Tell the module where the pointer is now, in output coordinates, so
    /// the derived delta continues from there. A backend that injected raw
    /// deltas through sendRelativeMotion, or a warp that moved the pointer
    /// without a motion the module saw, must call this.
    pub fn syncPointerPosition(self: *RelativePointer, x: i32, y: i32) void {
        self.last_x = x;
        self.last_y = y;
        self.have_last = true;
    }

    /// wlroots wlr_relative_pointer_manager_v1_send_relative_motion
    /// (wlr_relative_pointer_v1.c:187-209): deliver one relative motion to
    /// the seat's focused client's relative-pointer objects. Deltas are
    /// whole pixels in output coordinates; unaccelerated deltas are passed
    /// separately so a backend with real hardware deltas can supply them.
    pub fn sendRelativeMotion(
        self: *RelativePointer,
        dx: i32,
        dy: i32,
        dx_unaccel: i32,
        dy_unaccel: i32,
    ) void {
        const seat = self.seat orelse return;
        self.emit(seat, dx, dy, dx_unaccel, dy_unaccel);
    }

    /// Send to the focus client's objects (wlroots :191-201).
    fn emit(
        self: *RelativePointer,
        seat: *seat_mod.Seat,
        dx: i32,
        dy: i32,
        dx_unaccel: i32,
        dy_unaccel: i32,
    ) void {
        const focus = seat.pointer_focus orelse return;
        const focus_client = focus.resource.getClient();
        const utime = nowMicros(self.io);
        const utime_hi: u32 = @truncate(utime >> 32);
        const utime_lo: u32 = @truncate(utime);
        const fdx = fixedFromPixels(dx);
        const fdy = fixedFromPixels(dy);
        const fdxu = fixedFromPixels(dx_unaccel);
        const fdyu = fixedFromPixels(dy_unaccel);
        for (self.pointers.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus_client) continue;
            st.res.sendRelativeMotion(utime_hi, utime_lo, fdx, fdy, fdxu, fdyu);
        }
    }

    /// The seat a wl_pointer belongs to, or null for an INERT object
    /// (wlroots wlr_seat_client_from_pointer_resource returning NULL,
    /// wlr_relative_pointer_v1.c:80-95).
    fn seatFor(self: *RelativePointer, ptr: *server.wl.Pointer) ?*seat_mod.Seat {
        const seat = self.seat orelse return null;
        if (std.mem.indexOfScalar(*server.wl.Pointer, seat.pointers.items, ptr) == null) return null;
        return seat;
    }
};

fn onSeatMotion(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    const self: *RelativePointer = @fieldParentPtr("motion_listener", listener);
    const x = seat.pointer_x;
    const y = seat.pointer_y;
    if (!self.have_last) {
        // First motion after attaching: establish the baseline only, so no
        // delta from (0, 0) is invented.
        self.last_x = x;
        self.last_y = y;
        self.have_last = true;
        return;
    }
    // geom.subSat, not a private clamp: both positions are i32, so the
    // delta IS a saturating i32 subtraction and geom already provides
    // exactly that (geom.zig:70).
    const dx = geom.subSat(x, self.last_x);
    const dy = geom.subSat(y, self.last_y);
    self.last_x = x;
    self.last_y = y;
    if (dx == 0 and dy == 0) return; // the seat dedups repeats too (F8)
    // No acceleration is applied anywhere in this compositor, so the
    // unaccelerated deltas are the accelerated ones (XML:108-111).
    self.emit(seat, dx, dy, dx, dy);
}

/// The seat is dying: drop it so the module can never call into freed
/// memory (seat.zig:519-525 emits at the top of Seat.deinit).
fn onSeatDestroy(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    _ = seat;
    const self: *RelativePointer = @fieldParentPtr("seat_destroy_listener", listener);
    // Both links attached while self.seat was non-null go: the seat is
    // about to free its signal lists and the module may outlive it.
    self.motion_listener.link.remove();
    listener.link.remove();
    self.seat = null;
    self.have_last = false;
}

// --- wire plumbing -------------------------------------------------------

fn relativeManagerBind(client_wire: *wire.Client, self: *RelativePointer, version: u32, id: u32) void {
    log.debug("relative pointer manager bind v{d} id={d}", self.io, self.log_cfg, log_tag, .{ version, id });
    const res = server.zwp.RelativePointerManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    self.managers.append(self.allocator, res) catch {
        res.destroy();
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*RelativePointer, relativeManagerRequest, relativeManagerDestroy, self);
}

fn relativeManagerRequest(
    res: *server.zwp.RelativePointerManagerV1,
    request: server.zwp.RelativePointerManagerV1.Request,
    self: *RelativePointer,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => res.destroy(),
        .get_relative_pointer => |r| createRelativePointer(self, res, r.id, r.pointer),
    }
}

fn relativeManagerDestroy(_res: *server.zwp.RelativePointerManagerV1, self: *RelativePointer) void {
    const idx = std.mem.indexOfScalar(*server.zwp.RelativePointerManagerV1, self.managers.items, _res) orelse return;
    _ = self.managers.swapRemove(idx);
}

fn createRelativePointer(
    self: *RelativePointer,
    manager: *server.zwp.RelativePointerManagerV1,
    id: u32,
    ptr: *server.wl.Pointer,
) void {
    const res = server.zwp.RelativePointerV1.create(manager.getClient(), manager.getVersion(), id) catch {
        manager.postNoMemory();
        return;
    };
    const st = self.allocator.create(RelativeState) catch {
        res.destroy();
        manager.postNoMemory();
        return;
    };
    st.* = .{ .manager = self, .seat = self.seatFor(ptr), .res = res };
    self.pointers.append(self.allocator, st) catch {
        self.allocator.destroy(st);
        res.destroy();
        manager.postNoMemory();
        return;
    };
    res.setHandler(*RelativeState, relativePointerRequest, relativePointerDestroy, st);
}

fn relativePointerRequest(res: *server.zwp.RelativePointerV1, request: server.zwp.RelativePointerV1.Request, _: *RelativeState) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn relativePointerDestroy(_: *server.zwp.RelativePointerV1, st: *RelativeState) void {
    const self = st.manager;
    const idx = std.mem.indexOfScalar(*RelativeState, self.pointers.items, st) orelse return;
    _ = self.pointers.swapRemove(idx);
    self.allocator.destroy(st);
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/fractional_scale.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");
const surface_mod = @import("../compositor/surface.zig");

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,
    manager_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "zwp_relative_pointer_manager_v1")) {
                    data.manager_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Client-side capture of zwp_relative_pointer_v1.
const RelativeEvents = struct {
    count: usize = 0,
    utime: u64 = 0,
    dx: Fixed = Fixed.fromInt(0),
    dy: Fixed = Fixed.fromInt(0),
    dx_unaccel: Fixed = Fixed.fromInt(0),
    dy_unaccel: Fixed = Fixed.fromInt(0),
    monotonic: bool = true,

    fn listener(_: *client.zwp.RelativePointerV1, event: client.zwp.RelativePointerV1.Event, data: *RelativeEvents) void {
        switch (event) {
            .relative_motion => |e| {
                const stamp = (@as(u64, e.utime_hi) << 32) | @as(u64, e.utime_lo);
                if (stamp < data.utime) data.monotonic = false;
                data.count += 1;
                data.utime = stamp;
                data.dx = e.dx;
                data.dy = e.dy;
                data.dx_unaccel = e.dx_unaccel;
                data.dy_unaccel = e.dy_unaccel;
            },
        }
    }
};

/// The seat's hit-test stub.
const PickState = struct {
    surface: ?*surface_mod.Surface = null,
};

fn testPick(ctx: *anyopaque, x: i32, y: i32) ?seat_mod.Seat.PickResult {
    const st: *PickState = @ptrCast(@alignCast(ctx));
    if (st.surface) |s| return .{ .surface = s, .sx = x, .sy = y };
    return null;
}

/// One connected client. The registry listener target lives here (not in a
/// stack frame): libwayland keeps the listener data pointer for the life
/// of the proxy.
const Peer = struct {
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_seat: ?*client.wl.Seat = null,
    wl_pointer: ?*client.wl.Pointer = null,
    wl_manager: ?*client.zwp.RelativePointerManagerV1 = null,
    capture: RegistryCapture = .{},
    registry: ?*client.wl.Registry = null,
    surface: ?*client.wl.Surface = null,
    compositor_surface: ?*surface_mod.Surface = null,

    fn connect(p: *Peer, server_wire: *wire.Server) !void {
        // SAFETY: posix.socketpair fills both slots before either is read,
        // or the call returns non-SUCCESS and the function bails out.
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        p.client = wire.Client.create(server_wire, fds[0]) orelse return error.ClientCreateFailed;
        p.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;
        p.registry = try p.c_display.?.getRegistry();
        p.registry.?.setListener(*RegistryCapture, RegistryCapture.listener, &p.capture);
    }
};

/// A compositor + seat + relative-pointer module + two in-memory clients.
/// `with_seat` false builds the module with NO seat at all.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    relative: ?*RelativePointer = null,
    pick_state: PickState = .{},
    a: Peer = .{},
    b: Peer = .{},

    fn init(allocator: std.mem.Allocator, with_seat: bool) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        // deinit() frees ts itself, so it is the only teardown errdefer.
        errdefer ts.deinit();
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        // The internal wl_shm global (libwayland) must exist before the
        // clients' first registry roundtrips.
        try ts.display.?.initShm();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        if (with_seat) {
            ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
            ts.seat.?.setPick(testPick, &ts.pick_state);
        }
        ts.relative = try RelativePointer.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.seat);

        try ts.a.connect(ts.display.?.getServer());
        try ts.b.connect(ts.display.?.getServer());
        try ts.pump();

        if (ts.a.capture.manager_name == null or ts.a.capture.compositor_name == null) return error.GlobalMissing;
        if (with_seat and ts.a.capture.seat_name == null) return error.SeatMissing;

        for ([_]*Peer{ &ts.a, &ts.b }) |p| {
            p.wl_compositor = try p.registry.?.bind(p.capture.compositor_name.?, client.wl.Compositor, 7);
            if (with_seat) {
                p.wl_seat = try p.registry.?.bind(p.capture.seat_name.?, client.wl.Seat, seat_mod.seat_version);
                p.wl_pointer = try p.wl_seat.?.getPointer();
            }
            p.wl_manager = try p.registry.?.bind(p.capture.manager_name.?, client.zwp.RelativePointerManagerV1, 1);
        }
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // The clients go first: their resource destroy handlers must run
        // while the module lives.
        for ([_]*Peer{ &ts.b, &ts.a }) |p| {
            if (p.c_display) |d| d.disconnect();
            if (p.client) |c| c.destroy();
        }
        if (ts.relative) |r| r.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Per-peer client flush, then `test_pump.dispatchOnce` / `flushServers`
    /// around the seat's batch close, then the per-peer client dispatch —
    /// the roundtrip order this harness had before the shared helper existed.
    fn pump(ts: *TestServer) !void {
        for ([_]*Peer{ &ts.a, &ts.b }) |p| {
            if (p.c_display) |d| {
                if (d.flush() != .SUCCESS) return error.ClientFlushFailed;
            }
        }
        // The server dispatches, then the seat closes its per-batch
        // wl_pointer.frame, and only THEN do the server's replies go out —
        // the order this harness had before the shared helper existed, so
        // the frame event still reaches the client in the same roundtrip.
        // `null`: both peers flushed their own request above.
        try test_pump.dispatchOnce(null, ts.display.?, 0);
        if (ts.seat) |s| s.pointerFrame();
        test_pump.flushServers(ts.display.?);
        for ([_]*Peer{ &ts.a, &ts.b }) |p| {
            const d = p.c_display orelse continue;
            var fds = [_]posix.pollfd{.{ .fd = d.getFd(), .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&fds, 0) > 0) {
                if (d.dispatch() != .SUCCESS) {
                    // Protocol error or disconnect: the server already
                    // destroyed this client — forget it for deinit.
                    p.client = null;
                    return error.ClientDispatchFailed;
                }
            }
        }
    }

    /// Create a wl_surface for `p` on the wire and in the compositor, and
    /// return the compositor's Surface (the newest one, which is this peer's).
    fn createSurface(ts: *TestServer, p: *Peer) !*surface_mod.Surface {
        p.surface = try p.wl_compositor.?.createSurface();
        try ts.pump();
        const c = ts.compositor.?;
        p.compositor_surface = c.surfaces.items[c.surfaces.items.len - 1];
        return p.compositor_surface.?;
    }

    /// Focus `surface` with the pointer (the pick stub returns it for every
    /// position), then pump.
    fn focus(ts: *TestServer, surface: *surface_mod.Surface) !void {
        ts.pick_state.surface = surface;
        ts.seat.?.pointerMotion(100, 100);
        try ts.pump();
    }
};

/// Every seat-backed test needs a real Seat, which needs xkbcommon and a
/// keymap; the seat's own tests skip with the same diagnostic when the
/// keymap source is unavailable.
fn testServer(allocator: std.mem.Allocator) !*TestServer {
    return TestServer.init(allocator, true) catch |err| {
        std.debug.print("relative_pointer test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return err;
    };
}

test "relative pointer init and teardown with no seat and no client" {
    const allocator = std.testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const display = try display_mod.CompositorDisplay.init(allocator, io, &log_cfg);
    defer display.deinit();

    // No seat, no client: the global still registers and teardown is clean.
    const relative = try RelativePointer.init(allocator, io, &log_cfg, display, null);
    try std.testing.expectEqual(@as(usize, 0), relative.managers.items.len);
    try std.testing.expectEqual(@as(usize, 0), relative.pointers.items.len);
    // No seat: the compositor-side entry point is inert. It delivers to
    // no object and — the part that was silently unasserted — it must
    // NOT fabricate a delta baseline. have_last is what the derived
    // path keys off, and only syncPointerPosition (the backend's own
    // statement of where the pointer is) may set it; a call that
    // quietly recorded one would make the first motion after a later
    // attach report a jump out of (0, 0).
    relative.sendRelativeMotion(5, -3, 5, -3);
    try std.testing.expect(relative.seat == null);
    try std.testing.expectEqual(@as(usize, 0), relative.pointers.items.len);
    try std.testing.expect(!relative.have_last);
    try std.testing.expectEqual(@as(i32, 0), relative.last_x);
    try std.testing.expectEqual(@as(i32, 0), relative.last_y);

    // syncPointerPosition is NOT gated on a seat: recording the position
    // the pointer is at needs no focus target, and the recorded baseline
    // is what the next derived delta is measured from.
    relative.syncPointerPosition(10, 20);
    try std.testing.expect(relative.have_last);
    try std.testing.expectEqual(@as(i32, 10), relative.last_x);
    try std.testing.expectEqual(@as(i32, 20), relative.last_y);

    // Detaching an already detached module is a no-op (setSeat :178), so
    // the recorded baseline survives it and deinit must cope with it.
    relative.setSeat(null);
    try std.testing.expect(relative.have_last);
    try std.testing.expectEqual(@as(i32, 10), relative.last_x);
    try std.testing.expectEqual(@as(i32, 20), relative.last_y);
    relative.deinit();
}

test "both entry points are inert with no seat and deliver once attached" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface(&ts.a);
    const rel = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    var ev: RelativeEvents = .{};
    rel.setListener(*RelativeEvents, RelativeEvents.listener, &ev);
    try ts.pump();
    try ts.focus(surface);

    // Detach, so the module holds no seat at all — the same state init
    // leaves it in with a null seat.
    ts.relative.?.setSeat(null);
    try ts.pump();
    try std.testing.expect(ts.relative.?.seat == null);
    try std.testing.expect(!ts.relative.?.have_last);

    // Inert: nothing reaches the client and no baseline appears.
    ts.relative.?.sendRelativeMotion(5, -3, 5, -3);
    try std.testing.expectEqual(@as(usize, 0), ev.count);
    try std.testing.expect(!ts.relative.?.have_last);

    // The position sync still records its baseline.
    ts.relative.?.syncPointerPosition(10, 20);
    try std.testing.expect(ts.relative.?.have_last);
    try std.testing.expectEqual(@as(i32, 10), ts.relative.?.last_x);
    try std.testing.expectEqual(@as(i32, 20), ts.relative.?.last_y);

    // Re-attaching clears the baseline, so the first motion only
    // re-establishes it and the next one reports the exact delta.
    ts.relative.?.setSeat(ts.seat);
    ts.seat.?.pointerMotion(100, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.count);
    ts.seat.?.pointerMotion(105, 97);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.count);
    try std.testing.expectEqual(@as(i32, 5), ev.dx.toInt());
    try std.testing.expectEqual(@as(i32, -3), ev.dy.toInt());

    // And the backend entry point delivers verbatim again.
    ts.relative.?.sendRelativeMotion(7, -11, 9, -13);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ev.count);
    try std.testing.expectEqual(@as(i32, 7), ev.dx.toInt());
    try std.testing.expectEqual(@as(i32, -11), ev.dy.toInt());
    try std.testing.expectEqual(@as(i32, 9), ev.dx_unaccel.toInt());
    try std.testing.expectEqual(@as(i32, -13), ev.dy_unaccel.toInt());
}

test "a client binds and releases the manager with no seat behind it" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, false);
    defer ts.deinit();

    try std.testing.expectEqual(@as(usize, 2), ts.relative.?.managers.items.len);
    ts.a.wl_manager.?.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.relative.?.managers.items.len);

    // The other client's manager still lives.
    const managers = ts.relative.?.managers.items.len;
    ts.b.wl_manager.?.destroy();
    try ts.pump();
    try std.testing.expectEqual(managers - 1, ts.relative.?.managers.items.len);
}

test "relative motion carries exact 24.8 deltas and a 64-bit utime" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface(&ts.a);
    const rel = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    var ev: RelativeEvents = .{};
    rel.setListener(*RelativeEvents, RelativeEvents.listener, &ev);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.relative.?.pointers.items.len);

    // The first motion only establishes the delta baseline: no event, so no
    // bogus jump from (0, 0) is invented.
    try ts.focus(surface);
    try std.testing.expectEqual(@as(usize, 0), ev.count);

    // Every later motion is one relative_motion with the exact pixel delta
    // in 24.8 fixed, and identical unaccelerated deltas (no acceleration
    // model exists in this compositor, XML:108-111).
    ts.seat.?.pointerMotion(103, 97);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.count);
    try std.testing.expectEqual(@as(i32, 3), ev.dx.toInt());
    try std.testing.expectEqual(@as(i32, -3), ev.dy.toInt());
    try std.testing.expectEqual(@as(i32, 3 * 256), @as(i32, @intFromEnum(ev.dx)));
    try std.testing.expectEqual(@as(i32, -3 * 256), @as(i32, @intFromEnum(ev.dy)));
    try std.testing.expectEqual(@as(i32, @intFromEnum(ev.dx)), @as(i32, @intFromEnum(ev.dx_unaccel)));
    try std.testing.expectEqual(@as(i32, @intFromEnum(ev.dy)), @as(i32, @intFromEnum(ev.dy_unaccel)));
    // utime is one 64-bit microsecond timestamp split hi/lo (XML:100-104).
    try std.testing.expect(ev.utime > 0);

    ts.seat.?.pointerMotion(103, 97);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.count); // no movement, no event

    ts.seat.?.pointerMotion(200, 197);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ev.count);
    try std.testing.expectEqual(@as(i32, 97), ev.dx.toInt());
    try std.testing.expect(ev.monotonic);
}

test "relative motion reaches only the pointer-focus client" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface_a = try ts.createSurface(&ts.a);
    const surface_b = try ts.createSurface(&ts.b);
    const rel_a = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    const rel_b = try ts.b.wl_manager.?.getRelativePointer(ts.b.wl_pointer.?);
    var ev_a: RelativeEvents = .{};
    var ev_b: RelativeEvents = .{};
    rel_a.setListener(*RelativeEvents, RelativeEvents.listener, &ev_a);
    rel_b.setListener(*RelativeEvents, RelativeEvents.listener, &ev_b);
    try ts.pump();

    // Focus A: only A's object receives motion (wlroots
    // wlr_relative_pointer_v1.c:191-201).
    try ts.focus(surface_a);
    ts.seat.?.pointerMotion(140, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev_a.count);
    try std.testing.expectEqual(@as(usize, 0), ev_b.count);

    // Focus B: focusing IS a pointer motion (the helper moves the pointer
    // back to (100, 100)), and Seat.pointerMotion runs the hit test and
    // pointerEnter — which sets pointer_focus — BEFORE emitting
    // pointer_move (seat.zig:883-918). So the focus-changing motion is
    // delivered to the NEW focus client, exactly as wlroots sends
    // relative motion after the seat processed the focus
    // (wlr_relative_pointer_v1.c:191-201): one event for B, none for A.
    try ts.focus(surface_b);
    try std.testing.expectEqual(@as(usize, 1), ev_a.count);
    try std.testing.expectEqual(@as(usize, 1), ev_b.count);

    ts.seat.?.pointerMotion(180, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev_a.count);
    try std.testing.expectEqual(@as(usize, 2), ev_b.count);
}

test "no pointer focus means no relative motion" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface(&ts.a);
    const rel = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    var ev: RelativeEvents = .{};
    rel.setListener(*RelativeEvents, RelativeEvents.listener, &ev);
    try ts.pump();

    // Focus once to establish the delta baseline, then leave.
    try ts.focus(surface);
    ts.pick_state.surface = null;
    ts.seat.?.pointerMotion(200, 200);
    try ts.pump();
    ts.seat.?.pointerMotion(240, 240);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.count);
}

test "destroying the relative pointer stops delivery" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface(&ts.a);
    const rel = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    var ev: RelativeEvents = .{};
    rel.setListener(*RelativeEvents, RelativeEvents.listener, &ev);
    try ts.pump();
    try ts.focus(surface);

    rel.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.relative.?.pointers.items.len);

    ts.seat.?.pointerMotion(180, 180);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.count);
}

test "a relative pointer outlives its manager" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface(&ts.a);
    const rel = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    var ev: RelativeEvents = .{};
    rel.setListener(*RelativeEvents, RelativeEvents.listener, &ev);
    try ts.pump();
    try ts.focus(surface);

    // Destroying zwp_relative_pointer_manager_v1 does not take the objects
    // it created with it: they live in the manager struct, not the manager
    // resource (wlroots wlr_relative_pointer_v1.c:71-74, :115).
    ts.a.wl_manager.?.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.relative.?.pointers.items.len);

    ts.seat.?.pointerMotion(150, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.count);

    rel.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.relative.?.pointers.items.len);
}

test "setSeat(null) detaches and re-attaching clears the delta baseline" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface(&ts.a);
    const rel = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    var ev: RelativeEvents = .{};
    rel.setListener(*RelativeEvents, RelativeEvents.listener, &ev);
    try ts.pump();
    try ts.focus(surface);

    ts.relative.?.setSeat(null);
    try ts.pump();
    try std.testing.expect(ts.relative.?.seat == null);
    ts.seat.?.pointerMotion(400, 400);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.count);

    // Re-attaching clears the baseline, so the first motion after the
    // re-attach reports nothing instead of a jump from the old position.
    ts.relative.?.setSeat(ts.seat);
    ts.seat.?.pointerMotion(500, 500);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.count);
    ts.seat.?.pointerMotion(503, 500);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.count);
    try std.testing.expectEqual(@as(i32, 3), ev.dx.toInt());
}

test "the backend entry point delivers unclipped deltas verbatim" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface(&ts.a);
    const rel = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    var ev: RelativeEvents = .{};
    rel.setListener(*RelativeEvents, RelativeEvents.listener, &ev);
    try ts.pump();
    try ts.focus(surface);

    // A backend with real hardware deltas (wlroots'
    // wlr_relative_pointer_manager_v1_send_relative_motion,
    // wlr_relative_pointer_v1.c:187-209) supplies both the accelerated and
    // the unaccelerated pair; they are carried unchanged.
    ts.relative.?.sendRelativeMotion(7, -11, 9, -13);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.count);
    try std.testing.expectEqual(@as(i32, 7), ev.dx.toInt());
    try std.testing.expectEqual(@as(i32, -11), ev.dy.toInt());
    try std.testing.expectEqual(@as(i32, 9), ev.dx_unaccel.toInt());
    try std.testing.expectEqual(@as(i32, -13), ev.dy_unaccel.toInt());

    // syncPointerPosition keeps the derived path consistent afterwards.
    ts.relative.?.syncPointerPosition(100, 100);
    ts.seat.?.pointerMotion(104, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ev.count);
    try std.testing.expectEqual(@as(i32, 4), ev.dx.toInt());
}

test "module teardown releases every live relative pointer" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, true);
    defer ts.deinit();

    // The proxies are owned by the client display; the module holds the
    // server resources, which is what deinit must release.
    _ = try ts.createSurface(&ts.a);
    _ = try ts.a.wl_manager.?.getRelativePointer(ts.a.wl_pointer.?);
    _ = try ts.b.wl_manager.?.getRelativePointer(ts.b.wl_pointer.?);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ts.relative.?.pointers.items.len);

    // Tear the module down while both clients still hold their objects.
    ts.relative.?.deinit();
    ts.relative = null;
    try ts.pump();

    ts.seat.?.pointerMotion(300, 300);
    try ts.pump();
}
