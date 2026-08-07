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

fn bindManager(client: *wire.Client, sc: *Screencopy, version: u32, id: u32) void {
    const resource = server.zwlr.ScreencopyManagerV1.create(client, version, id) catch {
        client.postNoMemory();
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
    const client = output_resource.getClient();
    if (!sc.owns_output(sc.output_ctx, output_resource)) {
        client.postNoMemory(); // manager path is only reachable via a real output
        return;
    }
    const fb = sc.get_framebuffer(sc.fb_ctx) orelse {
        // No framebuffer yet: fail the frame without killing the client.
        const failed = server.zwlr.ScreencopyFrameV1.create(client, 1, frame_id) catch return;
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
            const failed = server.zwlr.ScreencopyFrameV1.create(client, 1, frame_id) catch return;
            failed.sendFailed();
            return;
        }
    }

    // The frame inherits the manager resource's version (opcode-gated
    // events below must not leak to older clients).
    const frame = server.zwlr.ScreencopyFrameV1.create(client, manager.getVersion(), frame_id) catch {
        client.postNoMemory();
        return;
    };
    const state = sc.allocator.create(FrameState) catch {
        frame.destroy();
        client.postNoMemory();
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
    buf.unlock();

    // Damage + flags + ready. The timestamp is the capture time.
    frame.sendDamage(@intCast(state.x), @intCast(state.y), @intCast(state.width), @intCast(state.height));
    frame.sendFlags(.{});
    var ts: [3]u32 = undefined;
    state.screencopy.clock(state.screencopy.clock_ctx, &ts);
    frame.sendReady(ts[0], ts[1], ts[2]);
    log.debug("screencopy frame {d}x{d}@{d},{d} copied", state.screencopy.io, state.screencopy.log_cfg, "screencopy", .{
        state.width, state.height, state.x, state.y,
    });
}
