//! zwlr_screencopy_manager_v1 (v3): output capture for clients.
//!
//! Shm-only compositor: on frame creation the manager sends the `buffer`
//! event (format/width/height/stride) + `buffer_done`; the client sends
//! `copy(buffer)` with a matching ARGB8888 wl_shm buffer and the module
//! copies the current output framebuffer (or the requested region) into
//! it, then sends flags + ready with the capture timestamp. The cursor is
//! already composited into the framebuffer by the scene (overlay_cursor
//! is accepted and ignored).
//!
//! The framebuffer is supplied by the compositor through a callback (the
//! server's single output framebuffer); the wl_output argument is
//! validated through another callback (the server's wl_output module).
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, buffers/shm.zig,
//! renderer/pixman.zig (sibling modules).

const std = @import("std");
const log = @import("./utils/log.zig");
const wire = @import("./core/wire.zig");
const display_mod = @import("./core/display.zig");
const shm_mod = @import("./buffers/shm.zig");
const pixman = @import("./renderer/pixman.zig");

const server = @import("protocol").server;
const client = @import("protocol").client;

/// zwlr_screencopy_manager_v1 protocol version this library implements.
pub const screencopy_version: u32 = 3;

pub const Screencopy = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    shm: *shm_mod.ShmState,
    global: ?*wire.Global = null,
    /// Framebuffer of the captured output (current frame).
    get_framebuffer: *const fn (ctx: *anyopaque) ?*pixman.Framebuffer,
    fb_ctx: *anyopaque,
    /// True when the wl_output argument belongs to this compositor.
    owns_output: *const fn (ctx: *anyopaque, resource: *server.wl.Output) bool,
    output_ctx: *anyopaque,
    /// Monotonic capture timestamp source (tv_sec_hi, tv_sec_lo, tv_nsec).
    clock: *const fn (ctx: *anyopaque, out: *[3]u32) void,
    clock_ctx: *anyopaque,
    /// Completed captures: incremented once per served `copy` request
    /// (pixels fully copied into the client's buffer, before the frame
    /// is marked ready). The server reads this to time synth input
    /// against real client captures instead of frame counts.
    captures_served: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        shm: *shm_mod.ShmState,
        get_framebuffer: *const fn (ctx: *anyopaque) ?*pixman.Framebuffer,
        fb_ctx: *anyopaque,
        owns_output: *const fn (ctx: *anyopaque, resource: *server.wl.Output) bool,
        output_ctx: *anyopaque,
        clock: *const fn (ctx: *anyopaque, out: *[3]u32) void,
        clock_ctx: *anyopaque,
    ) error{ OutOfMemory, GlobalCreateFailed }!*Screencopy {
        const self = try allocator.create(Screencopy);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .shm = shm,
            .get_framebuffer = get_framebuffer,
            .fb_ctx = fb_ctx,
            .owns_output = owns_output,
            .output_ctx = output_ctx,
            .clock = clock,
            .clock_ctx = clock_ctx,
        };
        self.global = try display.addGlobal(
            server.zwlr.ScreencopyManagerV1,
            *Screencopy,
            bindManager,
            screencopy_version,
            self,
        );
        log.debug("screencopy manager registered (shm only)", io, log_cfg, "screencopy", .{});
        return self;
    }

    pub fn deinit(self: *Screencopy) void {
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

/// Per-frame state: the capture region (output or clamped sub-rect) and
/// the copy-once guard. Freed by the frame's destroy handler.
const FrameState = struct {
    screencopy: *Screencopy,
    resource: *server.zwlr.ScreencopyFrameV1,
    /// Region in output coordinates (already clamped to the output).
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    used: bool = false,
};

fn bindManager(cli: *wire.Client, sc: *Screencopy, version: u32, id: u32) void {
    const resource = server.zwlr.ScreencopyManagerV1.create(cli, version, id) catch {
        cli.postNoMemory();
        return;
    };
    resource.setHandler(*Screencopy, managerRequest, null, sc);
}

fn managerRequest(
    resource: *server.zwlr.ScreencopyManagerV1,
    request: server.zwlr.ScreencopyManagerV1.Request,
    sc: *Screencopy,
) void {
    switch (request) {
        .capture_output => |r| capture(sc, resource, r.frame, r.output, 0, 0, 0, 0),
        .capture_output_region => |r| capture(sc, resource, r.frame, r.output, r.x, r.y, r.width, r.height),
        .destroy => resource.destroy(),
    }
}

fn capture(
    sc: *Screencopy,
    manager: *server.zwlr.ScreencopyManagerV1,
    frame_id: u32,
    output_resource: *server.wl.Output,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) void {
    const cli = output_resource.getClient();
    if (!sc.owns_output(sc.output_ctx, output_resource)) {
        cli.postNoMemory(); // manager path is only reachable via a real output
        return;
    }
    const fb = sc.get_framebuffer(sc.fb_ctx) orelse {
        // No framebuffer yet: fail the frame without killing the client.
        const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
        failed.sendFailed();
        return;
    };

    // The region is in output logical coordinates; clamp to the output.
    var rx = x;
    var ry = y;
    var rw = width;
    var rh = height;
    if (width == 0 and height == 0) {
        rx = 0;
        ry = 0;
        rw = fb.width;
        rh = fb.height;
    } else {
        if (rx < 0) {
            rw += rx;
            rx = 0;
        }
        if (ry < 0) {
            rh += ry;
            ry = 0;
        }
        if (rx + rw > fb.width) rw = fb.width - rx;
        if (ry + rh > fb.height) rh = fb.height - ry;
        if (rw <= 0 or rh <= 0) {
            const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
            failed.sendFailed();
            return;
        }
    }

    // The frame inherits the manager resource's version (opcode-gated
    // events below must not leak to older clients).
    const frame = server.zwlr.ScreencopyFrameV1.create(cli, manager.getVersion(), frame_id) catch {
        cli.postNoMemory();
        return;
    };
    const state = sc.allocator.create(FrameState) catch {
        frame.destroy();
        cli.postNoMemory();
        return;
    };
    state.* = .{
        .screencopy = sc,
        .resource = frame,
        .x = rx,
        .y = ry,
        .width = rw,
        .height = rh,
    };
    frame.setHandler(*FrameState, frameRequest, frameDestroy, state);

    // Advertise the shm path: ARGB8888, region size, tight stride.
    frame.sendBuffer(.argb8888, @intCast(rw), @intCast(rh), @intCast(rw * 4));
    if (frame.getVersion() >= 3) frame.sendBufferDone();
}

fn frameRequest(
    frame: *server.zwlr.ScreencopyFrameV1,
    request: server.zwlr.ScreencopyFrameV1.Request,
    state: *FrameState,
) void {
    switch (request) {
        .copy => |r| copyFrame(frame, state, r.buffer),
        .copy_with_damage => |r| copyFrame(frame, state, r.buffer),
        .destroy => frame.destroy(),
    }
}

fn frameDestroy(frame: *server.zwlr.ScreencopyFrameV1, state: *FrameState) void {
    _ = frame;
    const allocator = state.screencopy.allocator;
    allocator.destroy(state);
}

fn copyFrame(
    frame: *server.zwlr.ScreencopyFrameV1,
    state: *FrameState,
    buffer: *server.wl.Buffer,
) void {
    if (state.used) {
        frame.postError(.already_used, "the frame was already copied");
        return;
    }
    state.used = true;

    const fb = state.screencopy.get_framebuffer(state.screencopy.fb_ctx) orelse {
        frame.sendFailed();
        return;
    };

    // The client's wl_buffer must be a shm buffer of the advertised size.
    const buf = state.screencopy.shm.fromResource(state.screencopy.allocator, @ptrCast(buffer)) catch {
        frame.postError(.invalid_buffer, "buffer is not a wl_shm buffer");
        return;
    };
    if (buf.width != state.width or buf.height != state.height) {
        frame.postError(.invalid_buffer, "buffer size does not match the frame");
        return;
    }
    const get_shm = buf.impl.get_shm orelse {
        frame.postError(.invalid_buffer, "buffer has no shm data");
        return;
    };
    const shm = get_shm(buf) orelse {
        frame.postError(.invalid_buffer, "buffer has no shm data");
        return;
    };
    // getFormat returns the raw wl_shm format code (ARGB8888 = 0).
    if (wire.shm.Buffer.getFormat(shm) != 0) {
        frame.postError(.invalid_buffer, "buffer format is not ARGB8888");
        return;
    }
    const begin = buf.impl.begin_data_ptr_access orelse {
        frame.postError(.invalid_buffer, "buffer is not accessible");
        return;
    };
    const end = buf.impl.end_data_ptr_access orelse {
        frame.postError(.invalid_buffer, "buffer is not accessible");
        return;
    };
    const dst_ptr = begin(buf) catch {
        frame.postError(.invalid_buffer, "buffer access failed");
        return;
    };
    defer end(buf);
    // This module is a consumer: hold a lock while copying, then hand the
    // buffer back (drop + unlock fires wl_buffer.release).
    buf.lock() catch {
        frame.postError(.invalid_buffer, "buffer lock failed");
        return;
    };
    defer buf.unlock();

    // Row-wise copy of the region (both sides are ARGB8888).
    const dst = dst_ptr.?;
    const dst_stride: usize = @intCast(buf.width * 4);
    const src_stride: usize = @intCast(fb.width * 4);
    const src_offset: usize = @as(usize, @intCast(state.y)) * src_stride +
        @as(usize, @intCast(state.x)) * 4;
    const row_len: usize = @intCast(state.width * 4);
    var row: usize = 0;
    while (row < @as(usize, @intCast(state.height))) : (row += 1) {
        const src_row = fb.data[src_offset + row * src_stride ..][0..row_len];
        const dst_row = dst[row * dst_stride ..][0..row_len];
        @memcpy(dst_row, src_row);
    }

    // Hand the buffer back to the client (it may reuse it).
    buf.drop();

    // The capture is fully served: pixels are in the client's buffer.
    // The server times its synth input off this counter (the client's
    // first capture is count 1) rather than frame counts, which cannot
    // be predicted reliably against the client's retry window.
    state.screencopy.captures_served += 1;

    // Damage + flags + ready. The timestamp is the capture time.
    // damage is since 2 (wlr-screencopy-unstable-v1.xml:191): a v1 frame
    // must not receive it — the v1 client listener has no damage slot and
    // libwayland-client aborts on a listener-less opcode. The frame
    // inherits the manager's bound version (capture, above), so gate on
    // the frame version; buffer_done (>=3) is gated at frame creation.
    if (frame.getVersion() >= 2) {
        frame.sendDamage(@intCast(state.x), @intCast(state.y), @intCast(state.width), @intCast(state.height));
    }
    frame.sendFlags(.{});
    var ts: [3]u32 = undefined;
    state.screencopy.clock(state.screencopy.clock_ctx, &ts);
    frame.sendReady(ts[0], ts[1], ts[2]);
    log.debug("screencopy frame {d}x{d}@{d},{d} copied", state.screencopy.io, state.screencopy.log_cfg, "screencopy", .{
        state.width, state.height, state.x, state.y,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const posix = std.posix;
const backend_mod = @import("./backend/backend.zig");
const output_mod = @import("./output/output.zig");
const wl_output_mod = @import("./output/wl_output.zig");

const FakeBackendImpl = struct {
    fn start(_: *backend_mod.Backend) error{BackendFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_backend_impl: backend_mod.Backend.Impl = .{
    .start = FakeBackendImpl.start,
    .destroy = FakeBackendImpl.destroy,
};

const FakeOutputImpl = struct {
    fn testState(_: *output_mod.Output, _: *const output_mod.Output.State) error{InvalidState}!void {}
    fn commit(_: *output_mod.Output, _: *const output_mod.Output.State) error{CommitFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_output_impl: output_mod.Output.Impl = .{
    .@"test" = FakeOutputImpl.testState,
    .commit = FakeOutputImpl.commit,
    .destroy = FakeOutputImpl.destroy,
};

const RegistryCapture = struct {
    shm_name: ?u32 = null,
    output_name: ?u32 = null,
    screencopy_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_shm")) {
                    data.shm_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_output")) {
                    data.output_name = g.name;
                } else if (std.mem.eql(u8, name, "zwlr_screencopy_manager_v1")) {
                    data.screencopy_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Counts the events a wl_screencopy_frame client proxy received, so the
/// legacy-version tests can assert exactly which wire events arrived.
const FrameEvents = struct {
    buffer_count: usize = 0,
    flags_count: usize = 0,
    ready_count: usize = 0,
    failed_count: usize = 0,
    damage_count: usize = 0,
    buffer_done_count: usize = 0,

    fn listener(
        frame: *client.zwlr.ScreencopyFrameV1,
        event: client.zwlr.ScreencopyFrameV1.Event,
        data: *FrameEvents,
    ) void {
        _ = frame;
        switch (event) {
            .buffer => data.buffer_count += 1,
            .flags => data.flags_count += 1,
            .ready => data.ready_count += 1,
            .failed => data.failed_count += 1,
            .damage => data.damage_count += 1,
            .buffer_done => data.buffer_done_count += 1,
            // The compositor is shm-only: linux_dmabuf is never sent.
            .linux_dmabuf => data.buffer_done_count += 1,
        }
    }
};

/// A compositor + shm + output + screencopy manager + in-memory client, for
/// wire roundtrips of the capture flow at a chosen manager version.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    shm: ?*shm_mod.ShmState = null,
    backend: ?*backend_mod.Backend = null,
    output: ?*output_mod.Output = null,
    wl_output: ?*wl_output_mod.WlOutput = null,
    fb: ?*pixman.Framebuffer = null,
    sc: ?*Screencopy = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_shm: ?*client.wl.Shm = null,
    wl_output_client: ?*client.wl.Output = null,
    screencopy_mgr: ?*client.zwlr.ScreencopyManagerV1 = null,
    /// Lazily-created shm pool + buffer for the copy request; the pool is
    /// retained so the buffer stays valid until the frame is ready.
    shm_pool: ?*client.wl.ShmPool = null,
    buffer: ?*client.wl.Buffer = null,
    /// Backend data pointer (the fake impl never reads it).
    dummy: u8 = 0,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, shm and manager all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        return initAtVersion(allocator, 3);
    }

    /// init with zwlr_screencopy_manager_v1 bound at an explicit version,
    /// for the legacy-version conformance tests (a v1 client speaks an
    /// older wire and must not receive since-2 events).
    fn initAtVersion(allocator: std.mem.Allocator, manager_version: u32) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        // The internal wl_shm global (libwayland) must exist before the
        // client's first registry roundtrip so it can bind it for buffers.
        try ts.display.?.initShm();
        ts.shm = try shm_mod.ShmState.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.shm) |s| s.deinit();

        // One fake 64x64 output: the wl_output global supplies the
        // capture_output object argument and owns_output its identity
        // check; the framebuffer is the capture source.
        ts.backend = try backend_mod.Backend.init(allocator, &ts.io, &ts.log_cfg, &fake_backend_impl, &ts.dummy);
        errdefer if (ts.backend) |b| b.destroy();
        ts.output = try output_mod.Output.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.backend.?,
            &fake_output_impl,
            &ts.dummy,
            .{ .width = 64, .height = 64, .refresh_msec = 16 },
        );
        errdefer if (ts.output) |o| o.destroy();
        ts.wl_output = try wl_output_mod.WlOutput.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.output.?,
            "test",
            "test output",
        );
        ts.fb = try pixman.Framebuffer.create(allocator, 64, 64);
        errdefer if (ts.fb) |fb| fb.deinit();
        ts.sc = try Screencopy.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.shm.?,
            getFramebuffer,
            ts,
            ownsOutput,
            ts,
            captureClock,
            ts,
        );
        errdefer if (ts.sc) |sc| sc.deinit();

        // In-memory client connection: one socketpair end for the server,
        // the other for the client library.
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        // Round 1: registry + global announcements.
        const registry = try ts.c_display.?.getRegistry();
        var reg_capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &reg_capture);
        try ts.pump();
        if (reg_capture.shm_name == null or reg_capture.output_name == null or reg_capture.screencopy_name == null) {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_shm (for the copy buffer), wl_output (the
        // capture argument) and the screencopy manager at the tested
        // version.
        ts.wl_shm = try registry.bind(reg_capture.shm_name.?, client.wl.Shm, 1);
        ts.wl_output_client = try registry.bind(reg_capture.output_name.?, client.wl.Output, 1);
        ts.screencopy_mgr = try registry.bind(
            reg_capture.screencopy_name.?,
            client.zwlr.ScreencopyManagerV1,
            manager_version,
        );
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers (the
        // frame's frameDestroy) must run while the screencopy module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.sc) |sc| sc.deinit();
        // Destroying the output frees the WlOutput via its destroy
        // listener (wl_output.zig onOutputDestroy).
        if (ts.output) |o| o.destroy();
        if (ts.backend) |b| b.destroy();
        if (ts.fb) |fb| fb.deinit();
        if (ts.shm) |s| s.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Create a 64x64 ARGB8888 wl_shm buffer matching the frame's
    /// advertised size. The pool is retained so the buffer stays valid for
    /// the copy roundtrip.
    fn createBuffer(ts: *TestServer) !*client.wl.Buffer {
        if (ts.buffer) |b| return b;
        const width: i32 = 64;
        const height: i32 = 64;
        const fd = try std.posix.memfd_create("screencopy-test-buffer", std.os.linux.MFD.CLOEXEC);
        defer _ = std.os.linux.close(fd);
        const pool_size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
        ts.shm_pool = try ts.wl_shm.?.createPool(fd, @intCast(pool_size));
        ts.buffer = try ts.shm_pool.?.createBuffer(0, width, height, width * 4, .argb8888);
        return ts.buffer.?;
    }

    /// Client flush -> server event loop dispatch -> server flush ->
    /// client dispatch. Drives one roundtrip without blocking.
    fn pump(ts: *TestServer) !void {
        if (ts.c_display.?.flush() != .SUCCESS) return error.ClientFlushFailed;
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                // Protocol error or disconnect: the server has already
                // destroyed its client (dangling) — forget it for deinit.
                ts.client = null;
                return error.ClientDispatchFailed;
            }
        }
    }
};

fn getFramebuffer(ctx: *anyopaque) ?*pixman.Framebuffer {
    const ts: *TestServer = @ptrCast(@alignCast(ctx));
    return ts.fb;
}

fn ownsOutput(ctx: *anyopaque, resource: *server.wl.Output) bool {
    const ts: *TestServer = @ptrCast(@alignCast(ctx));
    const wl_output = ts.wl_output orelse return false;
    return wl_output.owns(resource);
}

/// Capture timestamp: fixed monotonic triple.
fn captureClock(_: *anyopaque, out: *[3]u32) void {
    out[0] = 0;
    out[1] = 42;
    out[2] = 0;
}

test "v1 manager: frame gets buffer/flags/ready but never damage or buffer_done" {
    const allocator = testing.allocator;
    var ts = try TestServer.initAtVersion(allocator, 1);
    defer ts.deinit();

    const frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var events: FrameEvents = .{};
    frame.setListener(*FrameEvents, FrameEvents.listener, &events);
    try ts.pump();

    // The v1 frame advertises its shm buffer (buffer is since 1) but
    // buffer_done is since 3: it must not arrive.
    try testing.expectEqual(@as(usize, 1), events.buffer_count);
    try testing.expectEqual(@as(usize, 0), events.buffer_done_count);

    const buffer = try ts.createBuffer();
    frame.copy(buffer);
    try ts.pump();

    // flags + ready are since 1 and arrive; damage is since 2 and must
    // not: the v1 client listener has no damage slot and libwayland-client
    // aborts on the listener-less opcode, killing the client.
    try testing.expectEqual(@as(usize, 1), events.flags_count);
    try testing.expectEqual(@as(usize, 1), events.ready_count);
    try testing.expectEqual(@as(usize, 0), events.damage_count);
    try testing.expectEqual(@as(usize, 0), events.failed_count);
}

test "v3 manager: damage and buffer_done arrive" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator); // manager bound at 3
    defer ts.deinit();

    const frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var events: FrameEvents = .{};
    frame.setListener(*FrameEvents, FrameEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.buffer_count);
    try testing.expectEqual(@as(usize, 1), events.buffer_done_count);

    const buffer = try ts.createBuffer();
    frame.copy(buffer);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.damage_count);
    try testing.expectEqual(@as(usize, 1), events.flags_count);
    try testing.expectEqual(@as(usize, 1), events.ready_count);
    try testing.expectEqual(@as(usize, 0), events.failed_count);
}
