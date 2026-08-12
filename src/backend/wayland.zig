//! Nested-wayland backend: one output presented through a PARENT
//! compositor.
//!
//! The compositor becomes a wayland CLIENT: it connects to the parent via
//! WAYLAND_DISPLAY, binds wl_compositor/wl_shm/xdg_wm_base, creates a
//! wl_surface + xdg_toplevel (mapped via the initial configure), and
//! uploads its pixman framebuffer into a wl_shm buffer on every commit.
//! This is the wayland-client analogue of backend/raylib.zig (the parent
//! surface replaces the raylib window).
//!
//! Frame pacing is a wire event-loop timer at mode.refresh_msec (same
//! pattern as headless/raylib); the parent's frame callbacks are NOT used
//! for pacing. The parent's events (configure, frame done) are dispatched
//! through an fd source on the same wire loop: every configure is acked.
//!
//! Pixel format: the pixman framebuffer is ARGB8888 little-endian (BGRA
//! bytes in memory), which is exactly the byte layout a wl_shm argb8888
//! buffer carries — no swizzle needed (same layout raylib uploads; the
//! parent's shm client interprets the bytes).
//!
//! For the orchestrator's integration agent: the parent must advertise
//! wl_compositor (v7), wl_shm (>= v2, argb8888 format) and xdg_wm_base
//! (v7). The backend binds wl_shm at the advertised version, the others
//! at 7. create() waits for the initial xdg configure (5s timeout) before
//! returning; the surface is only mapped after that ack, per xdg-shell
//! (a buffer commit before the ack is a protocol error).
//!
//! Imports: utils/*, core/wire.zig, backend/backend.zig, output/output.zig,
//! renderer/pixman.zig, the generated "protocol" module (client namespace).

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const backend = @import("backend.zig");
const output = @import("../output/output.zig");
const pixman = @import("../renderer/pixman.zig");
const protocol = @import("protocol");

const client = protocol.client;
const server = protocol.server;
const wl = client.wl;
const xdg = client.xdg;

/// Timeout for the create() protocol waits (registry burst, initial
/// configure), mirroring the test client's 5s window.
const connect_timeout_ms: i64 = 5000;

const Nested = struct {
    loop: *wire.EventLoop,
    timer: ?*wire.EventSource = null,
    /// Wire-loop fd source dispatching the parent's events. Registered in
    /// create() — the registry and configure waits need the parent's
    /// responses flowing — and removed in destroy before the disconnect.
    fd_source: ?*wire.EventSource = null,
    /// Null until create() succeeds: the impl destroy runs from an
    /// errdefer on a failed create() too, and must not deref a wrapper
    /// that was never created.
    out: ?*output.Output = null,
    mode: output.Mode,
    display: *wl.Display,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    /// Registry listener state: the registry proxy stays live until the
    /// display disconnects, so a parent that removes globals at runtime
    /// must not hit a dead stack copy.
    cs: ConnectState = .{},
};

/// Registry bind results (the listener's data during create()).
const ConnectState = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
};

/// Per-output nested-wayland state: the parent-side surface objects and
/// the wl_shm buffer the compositor framebuffer is uploaded into.
const WaylandOutputData = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    display: *wl.Display,
    /// The parent's wl_shm global (creates the pool backing the upload).
    shm: *wl.Shm,
    /// Parent-side surface objects (set right after creation; the impl
    /// destroy guards them like headless guards its output).
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    toplevel: ?*xdg.Toplevel = null,
    /// xdg_surface event state: every configure is acked from the
    /// listener; `configured` flips on the first one (the create() map).
    xdg_state: XdgState,
    /// The wl_shm buffer presented to the parent.
    shm_buf: ShmBuffer = .{},
};

/// xdg_surface listener state. One listener for the object's lifetime: the
/// initial configure is what create() waits for; every later configure
/// (parent resize) is acked immediately.
const XdgState = struct {
    display: *wl.Display,
    xdg_surface: *xdg.Surface,
    configured: bool = false,
    configure_serial: u32 = 0,
};

/// A client-side wl_shm buffer: the pool/buffer proxies plus the shared
/// mapping the compositor framebuffer is copied into.
const ShmBuffer = struct {
    pool: ?*wl.ShmPool = null,
    buffer: ?*wl.Buffer = null,
    /// memfd backing the pool (-1 when not allocated).
    fd: std.posix.fd_t = -1,
    /// Shared mapping of the pool (mmap'd; empty when not allocated).
    mapping: []align(std.heap.page_size_min) u8 = &.{},
    width: i32 = 0,
    height: i32 = 0,
};

const backend_impl: backend.Backend.Impl = .{
    .start = start,
    .destroy = destroy,
};

const output_impl: output.Output.Impl = .{
    .@"test" = testState,
    .commit = commit,
    .destroy = destroyOutput,
};

pub const WaylandBackend = struct {
    /// Create a single-output nested backend presenting through a parent
    /// compositor. Connects via WAYLAND_DISPLAY, binds the globals, maps
    /// an xdg_toplevel (waits for and acks the initial configure) and
    /// sets up the wl_shm buffer at `mode`. Frames are paced by a wire
    /// event-loop timer at mode.refresh_msec once the backend is started;
    /// `new_output` fires on start as well.
    ///
    /// error.WaylandDisplayUnset / error.ConnectFailed when no parent is
    /// reachable; error.Timeout / error.MissingGlobals when the parent
    /// does not answer or lacks the globals. Callers fall back to
    /// headless like they do for raylib.
    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        loop: *wire.EventLoop,
        mode: output.Mode,
        title: [:0]const u8,
    ) !*backend.Backend {
        std.debug.assert(mode.width > 0);
        std.debug.assert(mode.height > 0);
        std.debug.assert(mode.refresh_msec > 0);

        const display = try connectParent(io, log_cfg);
        return createConnected(allocator, io, log_cfg, loop, mode, title, display);
    }

    /// Build the backend around an already-connected display. The public
    /// create() connects via WAYLAND_DISPLAY; the lifecycle test connects
    /// to a socketpair mock parent with connectToFd and drives this.
    fn createConnected(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        loop: *wire.EventLoop,
        mode: output.Mode,
        title: [:0]const u8,
        display: *wl.Display,
    ) !*backend.Backend {
        const nested = try allocator.create(Nested);
        nested.* = .{
            .loop = loop,
            .mode = mode,
            .display = display,
        };

        // Backend.init does not take ownership of nested on failure, so
        // free it here; every failure path after this is covered by
        // base.destroy() (headless pattern).
        const base = backend.Backend.init(allocator, io, log_cfg, &backend_impl, nested) catch |err| {
            wl.Display.disconnect(display);
            allocator.destroy(nested);
            return err;
        };
        errdefer base.destroy();

        // The client display must be dispatched for every step below (the
        // registry burst, the initial configure) and for the backend's
        // lifetime (resizes, frame callbacks): watch its fd on the loop.
        nested.fd_source = loop.addFd(
            *Nested,
            wl.Display.getFd(display),
            .{ .readable = true },
            displayFdCb,
            nested,
        ) catch return error.BackendFailed;

        // Bind the parent's globals: wl_compositor v7, wl_shm at the
        // advertised version, xdg_wm_base v7 (same binds as the test
        // client, client.zig).
        const registry = try display.getRegistry();
        registry.setListener(*ConnectState, onRegistryEvent, &nested.cs);
        try pumpUntil(*Nested, loop, io, display, connect_timeout_ms, globalsBound, nested);
        if (nested.cs.compositor == null or nested.cs.shm == null or nested.cs.wm_base == null) {
            return error.MissingGlobals;
        }
        nested.compositor = nested.cs.compositor;
        nested.shm = nested.cs.shm;
        nested.wm_base = nested.cs.wm_base;

        // The parent surface: wl_surface + xdg_toplevel.
        const surface = try nested.compositor.?.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try nested.wm_base.?.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const toplevel = try xdg_surface.getToplevel();
        errdefer toplevel.destroy();
        toplevel.setTitle(title.ptr);
        toplevel.setAppId(title.ptr);

        const od = try allocator.create(WaylandOutputData);
        errdefer allocator.destroy(od);
        od.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .shm = nested.shm.?,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .xdg_state = .{ .display = display, .xdg_surface = xdg_surface },
        };
        xdg_surface.setListener(*XdgState, onXdgSurfaceEvent, &od.xdg_state);

        // Map: an empty commit; the parent answers with the initial
        // configure, which the listener acks.
        surface.commit();
        _ = wl.Display.flush(display);
        try pumpUntil(*WaylandOutputData, loop, io, display, connect_timeout_ms, configured, od);

        // The wl_shm pool backing the presented framebuffer, at the mode
        // size (rebuilt by commit when the framebuffer size changes).
        try ensureShmBuffer(od, mode.width, mode.height);

        const out = try output.Output.create(allocator, io, log_cfg, base, &output_impl, od, mode);
        nested.out = out;
        return base;
    }
};

/// Connect to the parent compositor via WAYLAND_DISPLAY (client.zig
/// pattern: validate the env var, then connect(null)).
fn connectParent(io: *std.Io, log_cfg: *const log_mod.Config) !*wl.Display {
    const display_env = std.mem.span(std.c.getenv("WAYLAND_DISPLAY") orelse "");
    if (display_env.len == 0) {
        log_mod.warn("WAYLAND_DISPLAY is not set; cannot connect to a parent compositor", io, log_cfg, "wayland", .{});
        return error.WaylandDisplayUnset;
    }
    const display = wl.Display.connect(null) catch |err| {
        log_mod.warn("wl_display_connect failed: {s}", io, log_cfg, "wayland", .{@errorName(err)});
        return err;
    };
    return display;
}

fn start(base: *backend.Backend) error{BackendFailed}!void {
    const nested: *Nested = @ptrCast(@alignCast(base.data));
    std.debug.assert(nested.timer == null);

    const timer = nested.loop.addTimer(*Nested, frameCb, nested) catch return error.BackendFailed;
    errdefer timer.remove();
    timer.timerUpdate(nested.mode.refresh_msec) catch return error.BackendFailed;
    nested.timer = timer;

    log_mod.info("started nested wayland output {d}x{d} @ {d}ms (parent surface)", base.io, base.log_cfg, "wayland", .{
        nested.mode.width, nested.mode.height, nested.mode.refresh_msec,
    });
    base.emitNewOutput(nested.out.?);
}

fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const nested: *Nested = @ptrCast(@alignCast(data));
    // Stop the timer first so no callback can run against a torn-down output.
    if (nested.timer) |timer| timer.remove();
    // The fd source must go before the display disconnects (its data
    // points at nested, and the socket closes with the disconnect).
    if (nested.fd_source) |source| source.remove();
    // The output wrapper may never have been created when destroy runs
    // from a failed create() errdefer (nested.out is null then).
    if (nested.out) |out| out.destroy();
    wl.Display.disconnect(nested.display);
    allocator.destroy(nested);
}

fn frameCb(nested: *Nested) c_int {
    nested.out.?.sendFrame();
    // libwayland does not re-arm timer sources after they fire; re-arm for
    // the next period. On failure, drop the source (return 0).
    nested.timer.?.timerUpdate(nested.mode.refresh_msec) catch return 0;
    return 1;
}

/// Dispatch the parent's events (configure, frame callbacks) and flush
/// our pending requests. Returns 0 (removing the source) when the parent
/// connection failed; destroy() must then not remove it a second time.
fn displayFdCb(fd: c_int, mask: wire.wl.EventMask, nested: *Nested) c_int {
    _ = fd;
    if (mask.readable or mask.hangup or mask.@"error") {
        if (wl.Display.dispatch(nested.display) != .SUCCESS) {
            nested.fd_source = null;
            return 0;
        }
    }
    if (wl.Display.flush(nested.display) != .SUCCESS) {
        nested.fd_source = null;
        return 0;
    }
    return 1;
}

/// What the nested backend can apply: enable/mode/buffer. Scale and
/// transform are rejected — the parent surface shows the framebuffer 1:1
/// (same mask as headless/raylib: a scale/transform commit would mutate
/// output.width/height with no backend effect).
fn testState(_: *output.Output, state: *const output.Output.State) error{InvalidState}!void {
    const supported = output.Output.State.committed_enabled |
        output.Output.State.committed_mode |
        output.Output.State.committed_buffer;
    if (state.committed & ~supported != 0) return error.InvalidState;
}

/// Upload the committed framebuffer into the parent's wl_shm buffer and
/// present it (attach + damage + commit). The buffer is (re)created when
/// the framebuffer size changed — a mode commit alone keeps the old
/// buffer until the next frame, whose fb carries the new size.
fn commit(out: *output.Output, state: *const output.Output.State) error{CommitFailed}!void {
    const od: *WaylandOutputData = @ptrCast(@alignCast(out.data));
    if (state.committed & output.Output.State.committed_mode != 0) {
        if (state.mode) |m| {
            // Apply the committed mode to the frame pacing (headless
            // pattern): the timer must run at the new mode's refresh.
            const nested: *Nested = @ptrCast(@alignCast(out.backend.data));
            nested.mode = m;
            if (nested.timer) |timer| {
                timer.timerUpdate(m.refresh_msec) catch return error.CommitFailed;
            }
        }
    }
    if (state.buffer) |buf| {
        const fb: *pixman.Framebuffer = @ptrCast(@alignCast(buf));
        if (od.shm_buf.buffer == null or od.shm_buf.width != fb.width or od.shm_buf.height != fb.height) {
            ensureShmBuffer(od, fb.width, fb.height) catch return error.CommitFailed;
        }
        copyToShmBuffer(fb, &od.shm_buf);
        od.surface.?.attach(od.shm_buf.buffer.?, 0, 0);
        od.surface.?.damage(0, 0, fb.width, fb.height);
        od.surface.?.commit();
        if (wl.Display.flush(od.display) != .SUCCESS) return error.CommitFailed;
        log_mod.debug(
            "commit: uploaded {d}x{d} to the parent surface (damage_rects={d})",
            out.io,
            out.log_cfg,
            "wayland",
            .{
                fb.width, fb.height, state.damage.rects.items.len,
            },
        );
    }
}

/// Copy the compositor's framebuffer into the shm mapping. Both sides are
/// ARGB8888 little-endian bytes (BGRA in memory) — the parent's shm client
/// interprets them, so no swizzle is needed (same layout pixman/raylib
/// present). Handles a padded source stride row by row.
fn copyToShmBuffer(fb: *const pixman.Framebuffer, buf: *ShmBuffer) void {
    const dst_stride: usize = @as(usize, @intCast(buf.width)) * 4;
    const src_stride: usize = @intCast(fb.stride);
    const height: usize = @intCast(fb.height);
    const row_bytes = dst_stride;
    if (src_stride == dst_stride) {
        @memcpy(buf.mapping[0 .. height * dst_stride], fb.data[0 .. height * dst_stride]);
    } else {
        var y: usize = 0;
        while (y < height) : (y += 1) {
            @memcpy(
                buf.mapping[y * dst_stride ..][0..row_bytes],
                fb.data[y * src_stride ..][0..row_bytes],
            );
        }
    }
}

/// (Re)create the wl_shm buffer at w x h: a memfd-backed pool plus an
/// argb8888 buffer. A wl_shm pool is a fixed-size fd mapping, so a resize
/// destroys and rebuilds.
fn ensureShmBuffer(od: *WaylandOutputData, w: i32, h: i32) !void {
    const buf = &od.shm_buf;
    if (buf.buffer != null and buf.width == w and buf.height == h) return;
    destroyShmBuffer(buf);

    const size: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const fd = try std.posix.memfd_create("nested-fb", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    const rc = std.os.linux.ftruncate(fd, @intCast(size));
    if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
    const mapping = try std.posix.mmap(
        null,
        size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(mapping);
    const pool = try od.shm.createPool(fd, @intCast(size));
    errdefer pool.destroy();
    const buffer = try pool.createBuffer(0, w, h, w * 4, .argb8888);
    errdefer buffer.destroy();

    buf.* = .{
        .pool = pool,
        .buffer = buffer,
        .fd = fd,
        .mapping = mapping,
        .width = w,
        .height = h,
    };
}

fn destroyShmBuffer(buf: *ShmBuffer) void {
    // The buffer/pool proxies go before the mapping (the parent may still
    // read the buffer until the proxy is gone).
    if (buf.buffer) |b| b.destroy();
    if (buf.pool) |p| p.destroy();
    if (buf.fd != -1) {
        if (buf.mapping.len != 0) std.posix.munmap(buf.mapping);
        _ = std.os.linux.close(buf.fd);
    }
    buf.* = .{};
}

fn destroyOutput(allocator: std.mem.Allocator, data: *anyopaque) void {
    const od: *WaylandOutputData = @ptrCast(@alignCast(data));
    // Protocol teardown order: role object before the xdg_surface (a live
    // role would make the parent post defunct_role_object), xdg_surface
    // before the wl_surface, shm objects before the mapping.
    if (od.toplevel) |t| t.destroy();
    if (od.xdg_surface) |x| x.destroy();
    if (od.surface) |s| s.destroy();
    destroyShmBuffer(&od.shm_buf);
    allocator.destroy(od);
}

fn onRegistryEvent(registry: *wl.Registry, event: wl.Registry.Event, state: *ConnectState) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            // Bind at the parent's ADVERTISED version, clamped to what we
            // need. A hardcoded 7 (or any fixed value) is a protocol error
            // when the parent advertises less (weston: wl_compositor v5,
            // xdg_wm_base v6) — wl_registry.bind with a version above the
            // advertised one raises invalid_version.
            if (std.mem.eql(u8, name, "wl_compositor") and state.compositor == null) {
                state.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 7)) catch null;
            } else if (std.mem.eql(u8, name, "wl_shm") and state.shm == null) {
                state.shm = registry.bind(g.name, wl.Shm, g.version) catch null;
            } else if (std.mem.eql(u8, name, "xdg_wm_base") and state.wm_base == null) {
                state.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 7)) catch null;
            }
        },
        .global_remove => {},
    }
}

fn onXdgSurfaceEvent(surface: *xdg.Surface, event: xdg.Surface.Event, state: *XdgState) void {
    _ = surface;
    switch (event) {
        .configure => |c| {
            state.configure_serial = c.serial;
            state.configured = true;
            // Every configure is acked immediately: the surface must not
            // stall waiting for an ack we would only send later.
            state.xdg_surface.ackConfigure(c.serial);
        },
    }
}

/// Flush and dispatch the wire loop until `pred(ctx)` holds or the
/// timeout elapses. The parent's responses arrive through the loop's fd
/// sources (the client display source registered in create, plus — in the
/// tests — the mock parent's loop source).
fn pumpUntil(
    comptime PredT: type,
    loop: *wire.EventLoop,
    io: *std.Io,
    display: *wl.Display,
    timeout_ms: i64,
    pred: *const fn (ctx: PredT) bool,
    ctx: PredT,
) !void {
    const deadline = clockMs(io) + timeout_ms;
    while (!pred(ctx)) {
        if (clockMs(io) >= deadline) return error.Timeout;
        _ = wl.Display.flush(display);
        try loop.dispatch(100);
    }
}

fn clockMs(io: *std.Io) i64 {
    const ns = std.Io.Clock.now(.awake, io.*).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn globalsBound(nested: *Nested) bool {
    return nested.cs.compositor != null and nested.cs.shm != null and nested.cs.wm_base != null;
}

fn configured(od: *WaylandOutputData) bool {
    return od.xdg_state.configured;
}

// ---------------------------------------------------------------------------
// Test support: a mock parent compositor on a socketpair.
// ---------------------------------------------------------------------------
//
// The mock is a real libwayland SERVER (wire.Server + raw globals, no
// compositor library): it announces wl_compositor v7, wl_shm (libwayland's
// internal global) and xdg_wm_base v7, creates the surface objects the
// backend asks for, answers the initial commit with a configure, and
// captures the bytes of every committed wl_shm buffer. Its own event loop
// is embedded in the backend's wire loop via an fd source, so one thread
// drives both sides (no real compositor needed).

const MockParent = struct {
    allocator: std.mem.Allocator,
    server: *wire.Server,
    /// Client-end of the socketpair (owned by the connected display).
    client_fd: std.posix.socket_t,
    serial: u32 = 1,
    toplevel: ?*server.xdg.Toplevel = null,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    /// Capture of the last committed wl_shm buffer (owned, fixed size:
    /// test framebuffers stay well under 256x256).
    capture: []u8 = &.{},
    capture_len: usize = 0,
    capture_width: i32 = 0,
    capture_height: i32 = 0,
    commit_count: usize = 0,

    fn init(allocator: std.mem.Allocator) !*MockParent {
        const mock = try allocator.create(MockParent);
        errdefer allocator.destroy(mock);
        const srv = try wire.Server.create();
        errdefer srv.destroy();

        var fds: [2]std.posix.socket_t = undefined;
        const rc = std.posix.system.socketpair(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
            &fds,
        );
        if (std.posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        // In-memory client connection (the repo's test-server pattern,
        // data_device.zig TestServer): attach the already-connected fd as
        // a client directly. addSocketFd would register the fd as a
        // LISTENING socket and accept() on a socketpair end, which fails
        // with EINVAL ("failed to accept: Invalid argument").
        _ = wire.Client.create(srv, fds[0]) orelse return error.ClientCreateFailed;
        // wl_shm: libwayland's internal global (v2) advertises argb8888
        // and creates pools/buffers for us.
        try srv.initShm();
        _ = wire.Global.create(
            srv,
            server.wl.Compositor,
            7,
            *MockParent,
            mock,
            compositorBind,
        ) catch return error.GlobalCreateFailed;
        _ = wire.Global.create(
            srv,
            server.xdg.WmBase,
            7,
            *MockParent,
            mock,
            wmBaseBind,
        ) catch return error.GlobalCreateFailed;

        mock.* = .{
            .allocator = allocator,
            .server = srv,
            .client_fd = fds[1],
            .capture = try allocator.alloc(u8, 256 * 256 * 4),
        };
        return mock;
    }

    fn deinit(mock: *MockParent) void {
        const allocator = mock.allocator;
        // Destroy clients first: their resource destroy handlers free the
        // MockSurface states (wl_display_destroy alone would leak them).
        mock.server.destroyClients();
        mock.server.destroy();
        allocator.free(mock.capture);
        allocator.destroy(mock);
    }

    fn loopFd(mock: *MockParent) c_int {
        return mock.server.getEventLoop().getFd();
    }

    /// fd-source callback embedding the mock's loop in the backend's loop.
    fn loopCb(fd: c_int, mask: wire.wl.EventMask, mock: *MockParent) c_int {
        _ = fd;
        if (mask.readable or mask.hangup or mask.@"error") {
            mock.server.getEventLoop().dispatch(0) catch return 0;
            mock.server.flushClients();
        }
        return 1;
    }

    fn title(mock: *const MockParent) []const u8 {
        return mock.title_buf[0..mock.title_len];
    }

    fn sendInitialConfigure(mock: *MockParent, xdg_res: *server.xdg.Surface) void {
        // xdg-shell: toplevel.configure (0x0 = client decides, no states)
        // first, then xdg_surface.configure with the serial.
        if (mock.toplevel) |tl| {
            var states_data: [4]u32 = undefined;
            var states: server.wl.Array = .{ .size = 0, .alloc = states_data.len * @sizeOf(u32), .data = &states_data };
            tl.sendConfigure(0, 0, &states);
        }
        const serial = mock.serial;
        mock.serial +%= 1;
        xdg_res.sendConfigure(serial);
    }

    fn captureCommit(mock: *MockParent, buffer_res: *server.wl.Buffer) void {
        const shm_buf = wire.shm.Buffer.get(@ptrCast(buffer_res)) orelse return;
        const w = shm_buf.getWidth();
        const h = shm_buf.getHeight();
        const stride = shm_buf.getStride();
        if (w <= 0 or h <= 0 or stride < w * 4) return;
        const total: usize = @intCast(@as(u64, @intCast(stride)) * @as(u64, @intCast(h)));
        if (total > mock.capture.len) return;
        // beginAccess installs the SIGBUS guard against a shrunk file; the
        // copy is synchronous, so the pair brackets it (shm.zig pattern).
        wire.shm.Buffer.beginAccess(shm_buf);
        const data: [*]const u8 = @ptrCast(wire.shm.Buffer.getData(shm_buf).?);
        @memcpy(mock.capture[0..total], data[0..total]);
        wire.shm.Buffer.endAccess(shm_buf);
        mock.capture_len = total;
        mock.capture_width = w;
        mock.capture_height = h;
        mock.commit_count += 1;
    }
};

/// Per-wl_surface mock state (the resource's user data).
const MockSurface = struct {
    res: *server.wl.Surface,
    mock: *MockParent,
    /// xdg_surface created for this surface (its role), if any.
    xdg: ?*server.xdg.Surface = null,
    configured: bool = false,
    attached: ?*server.wl.Buffer = null,
    frame_cb: ?*server.wl.Callback = null,
};

fn compositorBind(client_wire: *wire.Client, mock: *MockParent, version: u32, id: u32) void {
    const res = server.wl.Compositor.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*MockParent, compositorRequest, compositorDestroy, mock);
}

fn compositorRequest(compositor: *server.wl.Compositor, request: server.wl.Compositor.Request, mock: *MockParent) void {
    switch (request) {
        .create_surface => |r| {
            const surf = mock.allocator.create(MockSurface) catch {
                compositor.getClient().postNoMemory();
                return;
            };
            surf.* = .{ .res = undefined, .mock = mock };
            // Create the wl_surface resource the client's new_id names,
            // wired to the mock surface handler (the client-side of the
            // nested backend's wl_surface).
            const surf_res = server.wl.Surface.create(
                compositor.getClient(),
                compositor.getVersion(),
                r.id,
            ) catch {
                mock.allocator.destroy(surf);
                return;
            };
            surf.res = surf_res;
            surf_res.setHandler(*MockSurface, surfaceRequest, surfaceDestroy, surf);
        },
        .create_region => |r| {
            // The backend never uses wl_region; keep the id valid by
            // creating an inert region resource.
            const reg = server.wl.Region.create(
                compositor.getClient(),
                compositor.getVersion(),
                r.id,
            ) catch {
                compositor.getClient().postNoMemory();
                return;
            };
            reg.setHandler(*MockParent, regionRequest, regionDestroy, mock);
        },
        else => {},
    }
}

fn compositorDestroy(_: *server.wl.Compositor, _: *MockParent) void {}

fn regionRequest(_: *server.wl.Region, _: server.wl.Region.Request, _: *MockParent) void {}
fn regionDestroy(_: *server.wl.Region, _: *MockParent) void {}

fn surfaceRequest(surface: *server.wl.Surface, request: server.wl.Surface.Request, surf: *MockSurface) void {
    switch (request) {
        .attach => |r| surf.attached = r.buffer,
        .frame => |r| {
            // Create the wl_callback resource the client's new_id names.
            const cb = server.wl.Callback.create(
                surface.getClient(),
                surface.getVersion(),
                r.callback,
            ) catch {
                surface.getClient().postNoMemory();
                return;
            };
            surf.frame_cb = cb;
        },
        .commit => {
            const mock = surf.mock;
            if (surf.xdg) |xdg_res| {
                if (!surf.configured) {
                    // First commit of an xdg-shell surface: the parent
                    // answers with the initial configure.
                    mock.sendInitialConfigure(xdg_res);
                    surf.configured = true;
                }
            }
            if (surf.attached) |b| mock.captureCommit(b);
            surf.attached = null;
            if (surf.frame_cb) |cb| {
                // wl_callback.done (opcode 0, one u32 serial arg): the
                // generated binding has no sendDone wrapper, so emit via
                // the generic Resource.postEvent.
                const raw: *wire.Resource = @ptrCast(cb);
                var args = [_]server.wl.Argument{.{ .u = 0 }};
                raw.postEvent(0, &args);
                cb.destroy();
                surf.frame_cb = null;
            }
        },
        // destroy and the geometry/scale requests are irrelevant to the
        // capture; the resource is destroyed on client teardown.
        else => {},
    }
}

fn surfaceDestroy(_: *server.wl.Surface, surf: *MockSurface) void {
    surf.mock.allocator.destroy(surf);
}

fn wmBaseBind(client_wire: *wire.Client, mock: *MockParent, version: u32, id: u32) void {
    const res = server.xdg.WmBase.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*MockParent, wmBaseRequest, wmBaseDestroy, mock);
}

fn wmBaseRequest(wm_base: *server.xdg.WmBase, request: server.xdg.WmBase.Request, mock: *MockParent) void {
    switch (request) {
        .get_xdg_surface => |r| {
            const surf: *MockSurface = @ptrCast(@alignCast(r.surface.getUserData()));
            // Create the xdg_surface resource the client's new_id names,
            // wired to the mock handler (client-side of the nested
            // backend's xdg_surface).
            const xdg_res = server.xdg.Surface.create(
                wm_base.getClient(),
                wm_base.getVersion(),
                r.id,
            ) catch {
                wm_base.getClient().postNoMemory();
                return;
            };
            surf.xdg = xdg_res;
            xdg_res.setHandler(*MockParent, xdgSurfaceRequest, xdgSurfaceDestroy, mock);
        },
        .destroy => wm_base.destroy(),
        // create_positioner / pong: the backend never uses them.
        else => {},
    }
}

fn wmBaseDestroy(_: *server.xdg.WmBase, _: *MockParent) void {}

fn xdgSurfaceRequest(xdg_surface: *server.xdg.Surface, request: server.xdg.Surface.Request, mock: *MockParent) void {
    switch (request) {
        .get_toplevel => |r| {
            // Create the xdg_toplevel resource the client's new_id names.
            const tl = server.xdg.Toplevel.create(
                xdg_surface.getClient(),
                xdg_surface.getVersion(),
                r.id,
            ) catch {
                xdg_surface.getClient().postNoMemory();
                return;
            };
            mock.toplevel = tl;
            tl.setHandler(*MockParent, toplevelRequest, toplevelDestroy, mock);
        },
        .destroy => xdg_surface.destroy(),
        else => {},
    }
}

fn xdgSurfaceDestroy(_: *server.xdg.Surface, _: *MockParent) void {}

fn toplevelRequest(toplevel: *server.xdg.Toplevel, request: server.xdg.Toplevel.Request, mock: *MockParent) void {
    switch (request) {
        .set_title => |r| {
            const t = std.mem.span(r.title);
            const n = @min(t.len, mock.title_buf.len);
            @memcpy(mock.title_buf[0..n], t[0..n]);
            mock.title_len = n;
        },
        .destroy => toplevel.destroy(),
        else => {},
    }
}

fn toplevelDestroy(_: *server.xdg.Toplevel, mock: *MockParent) void {
    mock.toplevel = null;
}

const FrameRecorder = struct {
    frames: usize = 0,
    out: ?*output.Output = null,
    listener: wire.Listener(*output.Output),
    frame_listener: wire.Listener(*output.Output),

    fn onNewOutput(listener: *wire.Listener(*output.Output), out: *output.Output) void {
        const self: *FrameRecorder = @fieldParentPtr("listener", listener);
        self.out = out;
    }

    fn onFrame(listener: *wire.Listener(*output.Output), _: *output.Output) void {
        const self: *FrameRecorder = @fieldParentPtr("frame_listener", listener);
        self.frames += 1;
    }
};

/// Backend + mock parent on one wire loop, both driven from the test
/// thread (the mock's loop is embedded via an fd source).
const TestHarness = struct {
    allocator: std.mem.Allocator,
    loop: *wire.EventLoop,
    mock: *MockParent,
    mock_src: *wire.EventSource,
    base: *backend.Backend,

    fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        loop: *wire.EventLoop,
        mode: output.Mode,
    ) !TestHarness {
        const mock = try MockParent.init(allocator);
        errdefer mock.deinit();
        const mock_src = loop.addFd(
            *MockParent,
            mock.loopFd(),
            .{ .readable = true },
            MockParent.loopCb,
            mock,
        ) catch return error.AddFdFailed;
        errdefer mock_src.remove();
        const display = wl.Display.connectToFd(mock.client_fd) catch return error.ClientConnectFailed;
        const base = try WaylandBackend.createConnected(allocator, io, log_cfg, loop, mode, "nested-test", display);
        return .{
            .allocator = allocator,
            .loop = loop,
            .mock = mock,
            .mock_src = mock_src,
            .base = base,
        };
    }

    fn deinit(h: *TestHarness) void {
        h.base.destroy();
        h.mock_src.remove();
        h.mock.deinit();
        h.* = undefined;
    }
};

/// Each pixel's 4 bytes encode its linear index (B,G,R,A), so byte-level
/// equality with the captured shm buffer proves the upload end to end.
fn fillPattern(fb: *pixman.Framebuffer) void {
    var y: usize = 0;
    while (y < @as(usize, @intCast(fb.height))) : (y += 1) {
        var x: usize = 0;
        while (x < @as(usize, @intCast(fb.width))) : (x += 1) {
            const idx = x + y * @as(usize, @intCast(fb.width));
            const off = y * @as(usize, @intCast(fb.stride)) + x * 4;
            fb.data[off + 0] = @intCast(idx % 256);
            fb.data[off + 1] = @intCast((idx / 256) % 256);
            fb.data[off + 2] = 0xAB;
            fb.data[off + 3] = 0xFF;
        }
    }
}

test "nested backend maps a parent surface and uploads committed framebuffers" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    const loop = try wire.EventLoop.create();
    defer loop.destroy();

    const mode: output.Mode = .{ .width = 64, .height = 48, .refresh_msec = 10 };
    var harness = try TestHarness.init(allocator, &io, &log_cfg, loop, mode);
    defer harness.deinit();

    // The toplevel reached the parent with the requested title.
    try std.testing.expect(harness.mock.toplevel != null);
    try std.testing.expectEqualStrings("nested-test", harness.mock.title());

    var rec: FrameRecorder = .{
        .listener = wire.Listener(*output.Output).init(FrameRecorder.onNewOutput),
        .frame_listener = wire.Listener(*output.Output).init(FrameRecorder.onFrame),
    };
    harness.base.events.new_output.add(&rec.listener);

    try harness.base.start();
    try std.testing.expect(rec.out != null);
    const out = rec.out.?;
    try std.testing.expectEqual(mode.width, out.width);
    try std.testing.expectEqual(mode.height, out.height);

    // Enable the output (the compositor's setup commit).
    var enable = output.Output.State.init(allocator);
    defer enable.deinit();
    enable.committed = output.Output.State.committed_enabled |
        output.Output.State.committed_mode;
    enable.enabled = true;
    enable.mode = mode;
    try out.commitState(&enable);

    // The timer paces frames on the wire loop (one fire per period). The
    // loop also carries the parent-side fds (client display + mock loop),
    // and wl_event_loop_dispatch returns as soon as ANY source is ready —
    // so the first dispatch may be consumed by pending parent events
    // before the timer fires. Drain them, then the next dispatch blocks
    // until the timer fires exactly once.
    out.events.frame.add(&rec.frame_listener);
    try loop.dispatch(100);
    try loop.dispatch(100);
    try std.testing.expectEqual(@as(usize, 1), rec.frames);

    // Commit a patterned framebuffer: the parent must capture its bytes.
    const fb = try pixman.Framebuffer.create(allocator, mode.width, mode.height);
    defer fb.deinit();
    fillPattern(fb);
    var state = output.Output.State.init(allocator);
    defer state.deinit();
    state.committed = output.Output.State.committed_buffer;
    state.buffer = fb;
    try out.commitState(&state);

    try loop.dispatch(100);
    try std.testing.expectEqual(@as(usize, 1), harness.mock.commit_count);
    try std.testing.expectEqual(mode.width, harness.mock.capture_width);
    try std.testing.expectEqual(mode.height, harness.mock.capture_height);
    const total = @as(usize, @intCast(mode.height * mode.width * 4));
    try std.testing.expectEqual(total, harness.mock.capture_len);
    try std.testing.expectEqualSlices(u8, fb.data[0..total], harness.mock.capture[0..total]);

    // A mode commit resizes the shm buffer: the next upload lands in a
    // buffer of the new size.
    var resize = output.Output.State.init(allocator);
    defer resize.deinit();
    resize.committed = output.Output.State.committed_mode;
    resize.mode = .{ .width = 32, .height = 32, .refresh_msec = 10 };
    try out.commitState(&resize);

    const fb2 = try pixman.Framebuffer.create(allocator, 32, 32);
    defer fb2.deinit();
    fb2.fill(.{ 7, 8, 9, 10 });
    var state2 = output.Output.State.init(allocator);
    defer state2.deinit();
    state2.committed = output.Output.State.committed_buffer;
    state2.buffer = fb2;
    try out.commitState(&state2);

    try loop.dispatch(100);
    try std.testing.expectEqual(@as(usize, 2), harness.mock.commit_count);
    try std.testing.expectEqual(@as(i32, 32), harness.mock.capture_width);
    try std.testing.expectEqual(@as(i32, 32), harness.mock.capture_height);
    const total2 = @as(usize, 32 * 32 * 4);
    try std.testing.expectEqualSlices(u8, fb2.data[0..total2], harness.mock.capture[0..total2]);
}

test "nested backend rejects scale and transform commits" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    const loop = try wire.EventLoop.create();
    defer loop.destroy();

    const mode: output.Mode = .{ .width = 64, .height = 48, .refresh_msec = 10 };
    var harness = try TestHarness.init(allocator, &io, &log_cfg, loop, mode);
    defer harness.deinit();

    var rec: FrameRecorder = .{
        .listener = wire.Listener(*output.Output).init(FrameRecorder.onNewOutput),
        .frame_listener = wire.Listener(*output.Output).init(FrameRecorder.onFrame),
    };
    harness.base.events.new_output.add(&rec.listener);
    try harness.base.start();
    const out = rec.out.?;

    var st = output.Output.State.init(allocator);
    defer st.deinit();
    st.committed = output.Output.State.committed_scale;
    st.scale = 2.0;
    try std.testing.expectError(error.InvalidState, out.commitState(&st));

    st.committed = output.Output.State.committed_transform;
    st.transform = .@"90";
    try std.testing.expectError(error.InvalidState, out.commitState(&st));
}

test "copyToShmBuffer copies framebuffer rows into the shm mapping" {
    const allocator = std.testing.allocator;
    const w: i32 = 16;
    const h: i32 = 8;
    const fb = try pixman.Framebuffer.create(allocator, w, h);
    defer fb.deinit();
    fillPattern(fb);

    var buf: ShmBuffer = .{};
    buf.mapping = try allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(std.heap.page_size_min),
        @as(usize, @intCast(w * h * 4)),
    );
    defer allocator.free(buf.mapping);
    buf.width = w;
    buf.height = h;

    copyToShmBuffer(fb, &buf);
    const total = @as(usize, @intCast(w * h * 4));
    try std.testing.expectEqualSlices(u8, fb.data[0..total], buf.mapping[0..total]);
}

test "copyToShmBuffer handles a padded framebuffer stride" {
    const allocator = std.testing.allocator;
    const w: i32 = 8;
    const h: i32 = 4;
    const src_stride: usize = @as(usize, @intCast(w)) * 4 + 16;
    const src = try allocator.alloc(u8, src_stride * @as(usize, @intCast(h)));
    defer allocator.free(src);
    // Each row starts with a distinct byte pattern (the padding differs
    // per row, so the copy must be row-wise, not a flat memcpy).
    var y: usize = 0;
    while (y < @as(usize, @intCast(h))) : (y += 1) {
        @memset(src[y * src_stride ..][0..src_stride], @intCast(y + 1));
    }
    var fb: pixman.Framebuffer = .{
        .width = w,
        .height = h,
        .stride = @intCast(src_stride),
        .format = 0,
        .data = src,
        .allocator = allocator,
    };

    var buf: ShmBuffer = .{};
    buf.mapping = try allocator.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(std.heap.page_size_min),
        @as(usize, @intCast(w * h * 4)),
    );
    defer allocator.free(buf.mapping);
    buf.width = w;
    buf.height = h;

    copyToShmBuffer(&fb, &buf);
    const dst_stride = @as(usize, @intCast(w * 4));
    var row: usize = 0;
    while (row < @as(usize, @intCast(h))) : (row += 1) {
        const row_bytes = buf.mapping[row * dst_stride ..][0..dst_stride];
        for (row_bytes) |byte| {
            try std.testing.expectEqual(@as(u8, @intCast(row + 1)), byte);
        }
    }
}
