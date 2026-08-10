//! CompositorDisplay: owns the wire Server and the compositor's core
//! lifecycle — socket, event loop passthrough, serials, global registry.
//!
//! Cross-module contract:
//! - `compositor.zig` (Compositor.init) takes a `*CompositorDisplay` and
//!   calls addGlobal/nextSerial/dispatch.
//! - `buffers/shm.zig` calls `initShm()`; the wl_shm global is libwayland's
//!   internal one (see shm.zig for the rationale).
//! - `backend/*` and `shell/*` call addGlobal.
//! All these call sites only use the functions below.

const std = @import("std");
const wire = @import("wire.zig");
const log = @import("../utils/log.zig");

pub const CompositorDisplay = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    server: *wire.Server,
    /// Name of the auto-created listen socket, if addSocketAuto was called.
    socket_name: ?[:0]const u8 = null,
    /// Guards initShm against double registration (wl_display_init_shm
    /// creates a global; calling it twice would advertise wl_shm twice).
    shm_initialized: bool = false,
    destroyed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
    ) error{ OutOfMemory, ServerCreateFailed }!*CompositorDisplay {
        const server = try wire.Server.create();
        errdefer server.destroy();
        const display = try allocator.create(CompositorDisplay);
        display.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .server = server,
        };
        log.info("compositor display created", io, log_cfg, "display", .{});
        return display;
    }

    /// Destroy every live client (the documented pre-step before
    /// wl_display_destroy, wayland-server.c:1769-1777). The compositor
    /// calls this FIRST in its teardown so the client destroy signals
    /// fire against live modules; deinit calls it again as idempotent
    /// safety for library consumers that never did.
    pub fn destroyClients(self: *CompositorDisplay) void {
        self.server.destroyClients();
    }

    pub fn deinit(self: *CompositorDisplay) void {
        assert(!self.destroyed);
        self.destroyed = true;
        // wl_display_destroy does NOT tear down clients (libwayland frees
        // sockets/loop/globals only, wayland-server.c:1395-1418);
        // destroying them first is the documented pre-step
        // (wayland-server.c:1769-1777) and matches tinywl.c:1075. Without
        // it, live clients' resources (wl_surface and friends) leak at
        // shutdown and their destructors never run (F11).
        self.server.destroyClients();
        self.server.destroy();
        const allocator = self.allocator;
        if (self.socket_name) |name| allocator.free(name);
        allocator.destroy(self);
    }

    /// Enable the wl_shm protocol. wl_display_init_shm registers libwayland's
    /// internal wl_shm global (version 2); its bind handler creates the
    /// per-client wl_shm resource and sends the base formats ARGB8888 and
    /// XRGB8888, plus any additional formats registered via addShmFormat.
    /// Idempotent.
    pub fn initShm(self: *CompositorDisplay) error{OutOfMemory}!void {
        if (self.shm_initialized) return;
        try self.server.initShm();
        // Base formats are implicit; registering them explicitly keeps the
        // additional-format list readable and is a no-op protocol-wise
        // (clients dedupe format events). Values match wl_shm.Format.
        _ = try self.server.addShmFormat(0); // argb8888
        _ = try self.server.addShmFormat(1); // xrgb8888
        self.shm_initialized = true;
        log.info("wl_shm initialized", self.io, self.log_cfg, "display", .{});
    }

    /// Create a listen socket with an auto-generated name (wayland-N, N >= 1,
    /// skipping wayland-0). The returned name is owned by the display and
    /// freed on deinit.
    pub fn addSocketAuto(self: *CompositorDisplay) error{ AddSocketFailed, OutOfMemory }![]const u8 {
        var buf: [11]u8 = undefined;
        const name = try self.server.addSocketAuto(&buf);
        const dup = try self.allocator.dupeZ(u8, name);
        if (self.socket_name) |old| self.allocator.free(old);
        self.socket_name = dup;
        return dup;
    }

    /// The underlying wire Server (e.g. to create test clients).
    pub fn getServer(self: *CompositorDisplay) *wire.Server {
        return self.server;
    }

    /// Run the server's own event loop until terminate is called.
    pub fn run(self: *CompositorDisplay) void {
        self.server.run();
    }

    pub fn terminate(self: *CompositorDisplay) void {
        self.server.terminate();
    }

    /// fd of the server event loop, for embedding in an external loop
    /// (zio, custom epoll, ...).
    pub fn loopFd(self: *CompositorDisplay) c_int {
        return self.server.getEventLoop().getFd();
    }

    /// Dispatch pending client events; blocks up to timeout ms. Returns
    /// posix.UnexpectedError on epoll failure. Call flushClients afterwards.
    pub fn dispatch(self: *CompositorDisplay, timeout: c_int) !void {
        try self.server.getEventLoop().dispatch(timeout);
    }

    /// Flush buffered events to clients.
    pub fn flushClients(self: *CompositorDisplay) void {
        self.server.flushClients();
    }

    /// Monotonic serial counter (wl_display serials).
    pub fn nextSerial(self: *CompositorDisplay) u32 {
        return self.server.nextSerial();
    }

    /// Advertise a global. `bind` is invoked for each client binding it:
    /// fn (client: *wire.Client, data: DataT, version: u32, id: u32) void.
    pub fn addGlobal(
        self: *CompositorDisplay,
        comptime T: type,
        comptime DataT: type,
        comptime bind: fn (client: *wire.Client, data: DataT, version: u32, id: u32) void,
        version: u32,
        data: DataT,
    ) error{GlobalCreateFailed}!*wire.Global {
        return wire.Global.create(self.server, T, version, DataT, data, bind);
    }

    /// Log all protocol messages (requests and events) to stderr via the
    /// structured logger. Cheap enough to leave on; volume is filtered by
    /// the "wire" tag level.
    pub fn attachProtocolLogger(self: *CompositorDisplay) void {
        self.server.addProtocolLogger(*CompositorDisplay, protocolLog, self);
    }
};

fn protocolLog(
    display: *CompositorDisplay,
    direction: wire.ProtocolLogger.Type,
    message: *const wire.ProtocolLogger.LogMessage,
) void {
    const dir = if (direction == .request) "request" else "event";
    const class = std.mem.span(message.resource.getClass());
    const name = std.mem.span(message.message.name);
    const res_id = message.resource.getId();
    // wl_surface.attach's first argument is the wl_buffer object: print
    // its id so buffer lifecycles are traceable end to end. The union
    // args are untyped, so only inspect the one known object slot.
    if (message.arguments_count > 0 and message.arguments != null and
        std.mem.eql(u8, name, "attach"))
    {
        const obj = message.arguments.?[0].o;
        if (obj) |o| {
            const res: *wire.Resource = @ptrCast(@alignCast(o));
            log.debug("{s} {s}.{s} id={d} buf={d}", display.io, display.log_cfg, "wire", .{
                dir, class, name, res_id, res.getId(),
            });
            return;
        }
    }
    log.debug("{s} {s}.{s} id={d}", display.io, display.log_cfg, "wire", .{ dir, class, name, res_id });
}

const assert = std.debug.assert;

test "display init deinit" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();
    var cfg: log.Config = .{};

    const display = try CompositorDisplay.init(allocator, &io, &cfg);
    defer display.deinit();

    // No socket needed: the Server exists and can hand out serials.
    const s1 = display.nextSerial();
    const s2 = display.nextSerial();
    try std.testing.expect(s2 > s1);
    // The event loop is live and exposes its fd for external loops.
    try std.testing.expect(display.loopFd() >= 0);
}

test "display shm init is idempotent and free of sockets" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();
    var cfg: log.Config = .{};

    const display = try CompositorDisplay.init(allocator, &io, &cfg);
    defer display.deinit();

    try display.initShm();
    // A second call must not register the internal wl_shm global again.
    try display.initShm();
}
