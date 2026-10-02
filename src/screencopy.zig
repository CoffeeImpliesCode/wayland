//! zwlr_screencopy_manager_v1 (v3): output capture for clients.
//!
//! Shm-only compositor: on frame creation the manager sends the `buffer`
//! event (format/width/height/stride) + `buffer_done`; the client sends
//! `copy(buffer)` (or `copy_with_damage(buffer)`) with a matching
//! wl_shm buffer. The copy itself is DEFERRED to the next output commit
//! (wlroots wlr_screencopy_v1.c:434-435: the copy samples a presented
//! frame, never a mid-render or stale one); the ready event then carries
//! the commit timestamp. `copy_with_damage` sends the accumulated
//! per-client output damage boxes (wlroots screencopy_damage_accumulate,
//! :47-61) instead of a full rect.
//!
//! overlay_cursor: the compositor's framebuffer always has the cursor
//! composited into it, so overlay_cursor=1 is naturally satisfied; for
//! overlay_cursor=0 the copy source is the cursor-less base framebuffer
//! (a get_framebuffer callback flag — wlroots locks software cursors for
//! the opposite reason, :443-446).
//!
//! The framebuffer is supplied by the compositor through a callback (the
//! server's output framebuffers); the wl_output argument is validated
//! through another callback (the server's wl_output module), and a
//! request_frame callback wakes the renderer so the deferred copy gets
//! its commit (wlroots wlr_output_update_needs_frame, :440). Captures of
//! a disabled output fail at capture AND at copy (wlroots :508-511,
//! :364-367).
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, buffers/shm.zig,
//! renderer/pixman.zig, output/output.zig (sibling modules).

const std = @import("std");
const log = @import("./utils/log.zig");
const wire = @import("./core/wire.zig");
const display_mod = @import("./core/display.zig");
const shm_mod = @import("./buffers/shm.zig");
const buffer_mod = @import("./buffers/buffer.zig");
const pixman = @import("./renderer/pixman.zig");
const geom = @import("./utils/geom.zig");
const damage_mod = @import("./utils/damage.zig");
const matrix = @import("./utils/matrix.zig");
const output_mod = @import("./output/output.zig");

const server = @import("protocol").server;
const client = @import("protocol").client;

const Output = output_mod.Output;
const CommitEvent = Output.CommitEvent;

/// zwlr_screencopy_manager_v1 protocol version this library implements.
pub const screencopy_version: u32 = 3;

pub const Screencopy = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    shm: *shm_mod.ShmState,
    global: ?*wire.Global = null,
    /// Framebuffer of the captured output. `overlay_cursor` selects the
    /// cursor-composited framebuffer (true) or the cursor-less base
    /// (false).
    get_framebuffer: *const fn (ctx: *anyopaque, overlay_cursor: bool) ?*pixman.Framebuffer,
    fb_ctx: *anyopaque,
    /// Resolve a wl_output resource to the Output it belongs to; null
    /// when it is not this compositor's output.
    output_from_resource: *const fn (ctx: *anyopaque, resource: *server.wl.Output) ?*Output,
    output_ctx: *anyopaque,
    /// Wake the renderer so a deferred copy gets its next output commit.
    request_frame: *const fn (ctx: *anyopaque) void,
    request_ctx: *anyopaque,
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
        get_framebuffer: *const fn (ctx: *anyopaque, overlay_cursor: bool) ?*pixman.Framebuffer,
        fb_ctx: *anyopaque,
        output_from_resource: *const fn (ctx: *anyopaque, resource: *server.wl.Output) ?*Output,
        output_ctx: *anyopaque,
        request_frame: *const fn (ctx: *anyopaque) void,
        request_ctx: *anyopaque,
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
            .output_from_resource = output_from_resource,
            .output_ctx = output_ctx,
            .request_frame = request_frame,
            .request_ctx = request_ctx,
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

/// Per-client state (one per manager resource). Owns the with_damage
/// damage accumulator (wlroots wlr_screencopy_v1_client.damages).
/// Refcounted: 1 for the manager resource + 1 per outstanding frame, so
/// teardown order between the manager and its frames never dangles.
/// Destroy paths only touch the stored allocator — the Screencopy itself
/// may already be gone at client teardown (the server destroys the
/// manager global before its clients).
const ClientState = struct {
    allocator: std.mem.Allocator,
    /// Owning module. Only dereferenced from request handlers (the loop
    /// is running); destroy paths use the stored allocator because the
    /// Screencopy may already be freed at client teardown.
    screencopy: *Screencopy,
    /// Accumulated output damage since the last sent with_damage frame.
    /// Starts whole at first use (wlroots screencopy_damage_create);
    /// cleared after each sent frame. The whole flag covers the output.
    damage: damage_mod.Damage,
    /// The output being captured; null until the accumulator is armed.
    output: ?*Output = null,
    /// True once the commit/destroy listeners are attached to `output`.
    armed: bool = false,
    /// 1 for the manager resource + 1 per outstanding frame.
    ref: u32 = 1,
    commit_listener: wire.Listener(*CommitEvent),
    output_destroy_listener: wire.Listener(*Output),
};

/// Per-frame state: the capture region (in buffer coordinates), the
/// client's validated copy buffer, and the deferred-copy listeners. Freed
/// by the frame's resource destroy handler.
const FrameState = struct {
    allocator: std.mem.Allocator,
    screencopy: *Screencopy,
    client: *ClientState,
    resource: *server.zwlr.ScreencopyFrameV1,
    output: *Output,
    /// Region in buffer coordinates (output framebuffer space), already
    /// mapped through transform + scale.
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    overlay_cursor: bool,
    /// copy_with_damage requested: the ready event carries accumulated
    /// per-client damage boxes.
    with_damage: bool = false,
    /// The client's validated shm buffer; null until `copy` is
    /// requested. Doubles as the already-used guard; cleared once the
    /// frame is served or failed.
    buffer: ?*buffer_mod.Buffer = null,
    /// True once ready/failed was sent: the frame no longer reacts to
    /// output commits or copy requests. The RESOURCE stays alive — the
    /// client owns its lifetime and destroys it after ready/failed
    /// (wlroots inerts the frame, wlr_screencopy_v1.c:208-221).
    finished: bool = false,
    /// Advertised format code (the source framebuffer's format).
    shm_format: u32,
    /// Advertised stride (tight for the format); the client's buffer
    /// stride must match it exactly.
    shm_stride: i32,
    commit_listener: wire.Listener(*CommitEvent),
    output_destroy_listener: wire.Listener(*Output),
};

fn bindManager(cli: *wire.Client, sc: *Screencopy, version: u32, id: u32) void {
    const resource = server.zwlr.ScreencopyManagerV1.create(cli, version, id) catch {
        cli.postNoMemory();
        return;
    };
    const client_state = sc.allocator.create(ClientState) catch {
        resource.destroy();
        cli.postNoMemory();
        return;
    };
    client_state.* = .{
        .allocator = sc.allocator,
        .screencopy = sc,
        .damage = damage_mod.Damage.init(sc.allocator),
        .commit_listener = wire.Listener(*CommitEvent).init(onClientOutputCommit),
        .output_destroy_listener = wire.Listener(*Output).init(onClientOutputDestroy),
    };
    // Detached-state links so a conditional remove() (clientUnref before
    // the accumulator was armed) is a no-op, never a dangling deref.
    client_state.commit_listener.link.init();
    client_state.output_destroy_listener.link.init();
    resource.setHandler(*ClientState, managerRequest, managerDestroy, client_state);
}

fn managerDestroy(_: *server.zwlr.ScreencopyManagerV1, client_state: *ClientState) void {
    clientUnref(client_state);
}

fn managerRequest(
    resource: *server.zwlr.ScreencopyManagerV1,
    request: server.zwlr.ScreencopyManagerV1.Request,
    client_state: *ClientState,
) void {
    switch (request) {
        .capture_output => |r| capture(
            client_state.screencopy,
            resource,
            client_state,
            r.frame,
            r.output,
            r.overlay_cursor,
            0,
            0,
            0,
            0,
        ),
        .capture_output_region => |r| capture(
            client_state.screencopy,
            resource,
            client_state,
            r.frame,
            r.output,
            r.overlay_cursor,
            r.x,
            r.y,
            r.width,
            r.height,
        ),
        .destroy => resource.destroy(),
    }
}

fn capture(
    sc: *Screencopy,
    manager: *server.zwlr.ScreencopyManagerV1,
    client_state: *ClientState,
    frame_id: u32,
    output_resource: *server.wl.Output,
    overlay_cursor: i32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) void {
    const cli = output_resource.getClient();
    const output = sc.output_from_resource(sc.output_ctx, output_resource) orelse {
        // Foreign wl_output: fail the frame, don't kill the client
        // (wlroots wlr_screencopy_v1.c:508-511 — output == NULL also
        // send_failed, never no_memory).
        const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
        failed.sendFailed();
        return;
    };

    if (!output.enabled) {
        // Capturing a disabled output fails the frame (wlroots :508-511).
        const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
        failed.sendFailed();
        return;
    }
    const src_fb = sc.get_framebuffer(sc.fb_ctx, true) orelse {
        // No framebuffer yet: fail the frame without killing the client.
        const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
        failed.sendFailed();
        return;
    };

    // The region is in output LOGICAL coordinates; map it through the
    // inverse transform and the scale into buffer coordinates (wlroots
    // :576-580). The full-output form is the effective resolution
    // directly. Boxes are NOT clamped: one that exceeds the source fails
    // at copy time (wlroots :313-319).
    var rx: i32 = undefined;
    var ry: i32 = undefined;
    var rw: i32 = undefined;
    var rh: i32 = undefined;
    if (width == 0 and height == 0) {
        rx = 0;
        ry = 0;
        rw = output.width;
        rh = output.height;
    } else {
        const logical: geom.Rect = .{ .x = x, .y = y, .width = width, .height = height };
        var box = matrix.boxTransform(logical, invertTransform(output.transform), output.width, output.height);
        box.x = scaleCoord(box.x, output.scale);
        box.y = scaleCoord(box.y, output.scale);
        box.width = scaleCoord(box.width, output.scale);
        box.height = scaleCoord(box.height, output.scale);
        rx = box.x;
        ry = box.y;
        rw = box.width;
        rh = box.height;
    }
    if (rw <= 0 or rh <= 0) {
        // A non-positive region is nonsense on the wire: fail rather than
        // advertise an unusable buffer size.
        const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
        failed.sendFailed();
        return;
    }

    // Advertise the shm path. The format is the source framebuffer's
    // format — the pixman renderer's read format (ARGB8888 today, but
    // not hardcoded; wlroots preferred_read_format :543). The stride is
    // the tight minimum for a 4-byte format (pixel_format_info_min_stride
    // for the ARGB8888 family).
    const fmt: server.wl.Shm.Format = @enumFromInt(@as(c_int, @intCast(src_fb.format)));
    const shm_stride = std.math.mul(i32, rw, 4) catch {
        const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
        failed.sendFailed();
        return;
    };

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
        .allocator = sc.allocator,
        .screencopy = sc,
        .client = client_state,
        .resource = frame,
        .output = output,
        .x = rx,
        .y = ry,
        .width = rw,
        .height = rh,
        .overlay_cursor = overlay_cursor != 0,
        .shm_format = @intCast(@intFromEnum(fmt)),
        .shm_stride = shm_stride,
        .commit_listener = wire.Listener(*CommitEvent).init(onFrameOutputCommit),
        .output_destroy_listener = wire.Listener(*Output).init(onFrameOutputDestroy),
    };
    // Detached-state links: frameDestroy removes them unconditionally,
    // which must be a no-op when the copy was never requested.
    state.commit_listener.link.init();
    state.output_destroy_listener.link.init();
    frame.setHandler(*FrameState, frameRequest, frameDestroy, state);
    client_state.ref += 1;

    frame.sendBuffer(fmt, @intCast(rw), @intCast(rh), @intCast(shm_stride));
    if (frame.getVersion() >= 3) frame.sendBufferDone();
}

fn frameRequest(
    frame: *server.zwlr.ScreencopyFrameV1,
    request: server.zwlr.ScreencopyFrameV1.Request,
    state: *FrameState,
) void {
    switch (request) {
        .copy => |r| {
            if (state.finished) return; // served/failed: inert (wlroots frame == NULL)
            copyRequest(frame, state, r.buffer, false);
        },
        .copy_with_damage => |r| {
            if (state.finished) return;
            copyRequest(frame, state, r.buffer, true);
        },
        .destroy => frame.destroy(),
    }
}

/// Validate the client's buffer and defer the actual copy to the next
/// output commit (wlroots frame_handle_copy, :347-456).
fn copyRequest(
    frame: *server.zwlr.ScreencopyFrameV1,
    state: *FrameState,
    buffer: *server.wl.Buffer,
    with_damage: bool,
) void {
    if (state.buffer != null) {
        frame.postError(.already_used, "the frame was already copied");
        return;
    }
    if (!state.output.enabled) {
        // The output was disabled between capture and copy (wlroots
        // :364-367).
        frameFailed(state);
        return;
    }
    state.with_damage = with_damage;

    // The client's wl_buffer must be a shm buffer of the advertised
    // size, format and exact stride (wlroots :381-421; the stride
    // rejection is :418-421 — a padded client buffer must not be
    // silently mis-copied row by row).
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
    if (wire.shm.Buffer.getFormat(shm) != state.shm_format) {
        frame.postError(.invalid_buffer, "buffer format does not match the frame");
        return;
    }
    const stride = wire.shm.Buffer.getStride(shm);
    if (stride <= 0 or stride != state.shm_stride) {
        frame.postError(.invalid_buffer, "buffer stride does not match the frame");
        return;
    }
    // Hold the buffer until the copy happens (the client may not reuse
    // it before wl_buffer.release, which fires on the unlock).
    buf.lock() catch {
        frame.postError(.invalid_buffer, "buffer lock failed");
        return;
    };
    state.buffer = buf;

    if (with_damage) {
        // Arm the per-client damage accumulator. It starts whole
        // (wlroots screencopy_damage_create) and accumulates the output
        // damage of every later commit.
        clientArmDamage(state.client, state.output);
    }

    // The copy happens at the next output commit (wlroots :434-435):
    // arm the commit listener and wake the renderer so a commit comes
    // (wlroots :440).
    state.output.events.commit.add(&state.commit_listener);
    state.output.events.destroy.add(&state.output_destroy_listener);
    state.screencopy.request_frame(state.screencopy.request_ctx);
}

/// The deferred copy: runs inside the output's commit signal, after the
/// compositor presented the new buffer.
fn onFrameOutputCommit(listener: *wire.Listener(*CommitEvent), event: *CommitEvent) void {
    const state: *FrameState = @fieldParentPtr("commit_listener", listener);
    const committed = event.state.committed;

    // The output was disabled by this commit: the copy cannot proceed
    // (wlroots :354-356).
    if (committed & Output.State.committed_enabled != 0 and !state.output.enabled) {
        frameFailed(state);
        return;
    }
    // Wait for a commit that presents a buffer (wlroots :358-363).
    if (committed & Output.State.committed_buffer == 0) return;
    if (state.buffer == null) return; // copy not requested yet
    if (state.with_damage) {
        // With damage: only copy once there is something new to report
        // (wlroots :366-371).
        if (state.client.damage.isEmpty()) return;
    }

    const src = state.screencopy.get_framebuffer(state.screencopy.fb_ctx, state.overlay_cursor) orelse {
        frameFailed(state);
        return;
    };
    // The box must lie inside the source (wlroots :313-319).
    if (state.x < 0 or state.y < 0 or
        state.x + state.width > src.width or state.y + state.height > src.height or
        state.width <= 0 or state.height <= 0)
    {
        frameFailed(state);
        return;
    }
    if (!copyPixels(state, src)) {
        frameFailed(state);
        return;
    }

    // The capture is fully served: pixels are in the client's buffer.
    // The server times its synth input off this counter (the client's
    // first capture is count 1) rather than frame counts, which cannot
    // be predicted reliably against the client's retry window.
    state.screencopy.captures_served += 1;

    // Damage boxes + flags + ready. The timestamp is the COMMIT time:
    // the presented frame's time (wlroots sends event->when, :337).
    // damage is since 2 (wlr-screencopy-unstable-v1.xml:191): a v1 frame
    // must not receive it — the v1 client listener has no damage slot
    // and libwayland-client aborts on a listener-less opcode.
    if (state.resource.getVersion() >= 2) sendFrameDamage(state);
    state.resource.sendFlags(.{});
    const when = event.when_ns;
    const sec: u64 = when / std.time.ns_per_s;
    const nsec: u32 = @truncate(when % std.time.ns_per_s);
    // ready is a plain event (not a destructor — "the client should
    // destroy the object"). The frame is finished: detach the output
    // listeners so it stops reacting to commits (the O14 bug), hand the
    // buffer back, and wait for the client's destroy to free the state.
    state.resource.sendReady(@truncate(sec >> 32), @truncate(sec), nsec);
    finishFrame(state);
}

fn onFrameOutputDestroy(listener: *wire.Listener(*Output), _: *Output) void {
    const state: *FrameState = @fieldParentPtr("output_destroy_listener", listener);
    frameFailed(state);
}

/// failed is a plain event (not a destructor — "the client should
/// destroy the object"): send it, finish the frame, and keep the
/// resource for the client's destroy.
fn frameFailed(state: *FrameState) void {
    state.resource.sendFailed();
    finishFrame(state);
}

/// The frame was served or failed: detach the output listeners, hand
/// the client buffer back, and mark the frame finished so further copy
/// requests and output commits are ignored. The resource itself stays
/// alive — the client owns its lifetime and destroys it after
/// ready/failed (wlroots inerts the frame, wlr_screencopy_v1.c:208-221);
/// frameDestroy then frees the state. Listener links may be detached
/// (never armed) or already removed — remove only when attached.
fn finishFrame(state: *FrameState) void {
    if (state.commit_listener.link.prev != null and
        state.commit_listener.link.prev != &state.commit_listener.link)
    {
        state.commit_listener.link.remove();
    }
    if (state.output_destroy_listener.link.prev != null and
        state.output_destroy_listener.link.prev != &state.output_destroy_listener.link)
    {
        state.output_destroy_listener.link.remove();
    }
    if (state.buffer) |b| {
        b.drop();
        if (b.n_locks > 0) b.unlock();
    }
    state.buffer = null;
    state.finished = true;
}

/// Row-wise copy of the region into the client's shm buffer. Both sides
/// are the advertised format (ARGB8888 family).
fn copyPixels(state: *FrameState, src: *pixman.Framebuffer) bool {
    const buf = state.buffer orelse return false;
    const get_shm = buf.impl.get_shm orelse return false;
    const shm = get_shm(buf) orelse return false;
    const begin = buf.impl.begin_data_ptr_access orelse return false;
    const end = buf.impl.end_data_ptr_access orelse return false;
    const dst_ptr = begin(buf) catch return false;
    defer end(buf);
    const dst = dst_ptr orelse return false;
    // The stride was validated to equal the advertised tight stride.
    const dst_stride: usize = @intCast(wire.shm.Buffer.getStride(shm));
    const src_stride: usize = @intCast(src.stride);
    const src_offset: usize = @as(usize, @intCast(state.y)) * src_stride +
        @as(usize, @intCast(state.x)) * 4;
    const row_len: usize = @intCast(state.width * 4);
    var row: usize = 0;
    while (row < @as(usize, @intCast(state.height))) : (row += 1) {
        const src_row = src.data[src_offset + row * src_stride ..][0..row_len];
        const dst_row = dst[row * dst_stride ..][0..row_len];
        @memcpy(dst_row, src_row);
    }
    return true;
}

/// Send the accumulated damage boxes and clear the accumulator (wlroots
/// frame_send_damage, :156-181).
fn sendFrameDamage(state: *FrameState) void {
    const d = &state.client.damage;
    if (d.whole) {
        const out = state.output;
        state.resource.sendDamage(0, 0, @intCast(out.width), @intCast(out.height));
    } else {
        for (d.rects.items) |r| {
            state.resource.sendDamage(@intCast(r.x), @intCast(r.y), @intCast(r.width), @intCast(r.height));
        }
    }
    d.clear();
}

/// The frame resource was destroyed (ready/failed sent, client destroy,
/// client teardown): detach listeners, hand the buffer back, free.
fn frameDestroy(_: *server.zwlr.ScreencopyFrameV1, state: *FrameState) void {
    const client_state = state.client;
    const allocator = state.allocator;
    // The frame may be finished already (listeners removed, buffer
    // handed back) or destroyed before its first copy: remove only what
    // is still attached and hand the buffer back only if still held.
    if (state.commit_listener.link.prev != null and
        state.commit_listener.link.prev != &state.commit_listener.link)
    {
        state.commit_listener.link.remove();
    }
    if (state.output_destroy_listener.link.prev != null and
        state.output_destroy_listener.link.prev != &state.output_destroy_listener.link)
    {
        state.output_destroy_listener.link.remove();
    }
    if (state.buffer) |b| {
        b.drop();
        if (b.n_locks > 0) b.unlock();
    }
    allocator.destroy(state);
    clientUnref(client_state);
}

/// Drop one reference to a ClientState; free it at zero (manager
/// resource gone AND all frames gone). Only touches the stored allocator
/// and the (possibly already emitted) output signals — safe at any
/// teardown order.
fn clientUnref(client_state: *ClientState) void {
    if (client_state.ref > 0) client_state.ref -= 1;
    if (client_state.ref != 0) return;
    if (client_state.armed) {
        client_state.commit_listener.link.remove();
        client_state.output_destroy_listener.link.remove();
        client_state.armed = false;
    }
    client_state.damage.deinit();
    const allocator = client_state.allocator;
    allocator.destroy(client_state);
}

/// Arm the per-client damage accumulator on the output: start whole and
/// accumulate the damage of every later commit (wlroots
/// screencopy_damage_get_or_create).
fn clientArmDamage(client_state: *ClientState, output: *Output) void {
    if (client_state.armed) return;
    client_state.output = output;
    client_state.damage.addWhole();
    client_state.armed = true;
    output.events.commit.add(&client_state.commit_listener);
    output.events.destroy.add(&client_state.output_destroy_listener);
}

fn onClientOutputCommit(listener: *wire.Listener(*CommitEvent), event: *CommitEvent) void {
    const client_state: *ClientState = @fieldParentPtr("commit_listener", listener);
    accumulateDamage(client_state, event);
}

fn onClientOutputDestroy(listener: *wire.Listener(*Output), _: *Output) void {
    const client_state: *ClientState = @fieldParentPtr("output_destroy_listener", listener);
    if (client_state.armed) {
        // The output signal is being destroyed with the output; only the
        // commit listener must be detached (the destroy listener dies
        // with the signal). The frame's own output-destroy listener fails
        // any pending copy.
        client_state.commit_listener.link.remove();
        client_state.armed = false;
    }
}

/// Accumulate a committed state's damage into the client's region
/// (wlroots screencopy_damage_accumulate, :47-61): the submitted damage
/// (clamped to the output), or whole damage when the compositor
/// submitted a buffer without damage.
fn accumulateDamage(client_state: *ClientState, event: *CommitEvent) void {
    const st = event.state;

    if (st.damage.whole) {
        client_state.damage.addWhole();
        return;
    }
    if (st.damage.rects.items.len > 0) {
        const out = client_state.output orelse return;
        const bounds: geom.Rect = .{ .x = 0, .y = 0, .width = out.width, .height = out.height };
        for (st.damage.rects.items) |r| {
            const clamped = bounds.intersect(r) orelse continue;
            damageAddRect(&client_state.damage, clamped);
        }
        return;
    }
    if (st.committed & Output.State.committed_buffer != 0) {
        client_state.damage.addWhole();
    }
}

/// Add a rect to the accumulator, skipping exact duplicates: repeated
/// identical commits must not emit duplicate damage boxes (wlroots unions
/// into a pixman region, which merges identical boxes).
fn damageAddRect(d: *damage_mod.Damage, r: geom.Rect) void {
    if (d.whole) return;
    for (d.rects.items) |existing| {
        if (existing.x == r.x and existing.y == r.y and
            existing.width == r.width and existing.height == r.height) return;
    }
    d.add(r) catch return;
}

/// wl_output_transform inverse (wlroots util/transform.c:66-85): maps a
/// logical box back into buffer space via matrix.boxTransform.
fn invertTransform(t: geom.Transform) geom.Transform {
    return switch (t) {
        .normal => .normal,
        .@"90" => .@"270",
        .@"180" => .@"180",
        .@"270" => .@"90",
        .flipped => .flipped,
        .flipped_90 => .flipped_270,
        .flipped_180 => .flipped_180,
        .flipped_270 => .flipped_90,
    };
}

/// Scale a coordinate by the output scale, truncating toward zero like
/// wlroots' C int *= double (wlr_screencopy_v1.c:578-581).
fn scaleCoord(v: i32, scale: f32) i32 {
    return std.math.lossyCast(i32, @as(f64, v) * @as(f64, scale));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const posix = std.posix;
const backend_mod = @import("./backend/backend.zig");
const wl_output_mod = @import("./output/wl_output.zig");
const test_pump = @import("./utils/test_pump.zig");

const FakeBackendImpl = struct {
    fn start(_: *backend_mod.Backend) error{BackendFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_backend_impl: backend_mod.Backend.Impl = .{
    .start = FakeBackendImpl.start,
    .destroy = FakeBackendImpl.destroy,
};

const FakeOutputImpl = struct {
    fn testState(_: *Output, _: *const Output.State) error{InvalidState}!void {}
    fn commit(_: *Output, _: *const Output.State) error{CommitFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_output_impl: Output.Impl = .{
    .@"test" = FakeOutputImpl.testState,
    .commit = FakeOutputImpl.commit,
    .destroy = FakeOutputImpl.destroy,
};

const RegistryCapture = struct {
    shm_name: ?u32 = null,
    /// First wl_output global: the compositor's owned output.
    output_name: ?u32 = null,
    /// Second wl_output global: the foreign output (a resource bound to
    /// it is not owned by the compositor's wl_output module).
    output_name_foreign: ?u32 = null,
    screencopy_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_shm")) {
                    data.shm_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_output")) {
                    // Globals are announced in registration order; the
                    // compositor's output is registered first.
                    if (data.output_name == null) {
                        data.output_name = g.name;
                    } else {
                        data.output_name_foreign = g.name;
                    }
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
    damage_x: u32 = 0,
    damage_y: u32 = 0,
    damage_width: u32 = 0,
    damage_height: u32 = 0,

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
            .damage => |d| {
                data.damage_count += 1;
                data.damage_x = d.x;
                data.damage_y = d.y;
                data.damage_width = d.width;
                data.damage_height = d.height;
            },
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
    output: ?*Output = null,
    wl_output: ?*wl_output_mod.WlOutput = null,
    /// A second, foreign output: its wl_output global gives the
    /// capture-flow tests a resource NOT owned by the compositor's
    /// wl_output module.
    output_foreign: ?*Output = null,
    wl_output_foreign: ?*wl_output_mod.WlOutput = null,
    fb: ?*pixman.Framebuffer = null,
    sc: ?*Screencopy = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_shm: ?*client.wl.Shm = null,
    wl_output_client: ?*client.wl.Output = null,
    wl_output_foreign_client: ?*client.wl.Output = null,
    screencopy_mgr: ?*client.zwlr.ScreencopyManagerV1 = null,
    /// Lazily-created shm pool + buffer for the copy request; the pool is
    /// retained so the buffer stays valid until the frame is ready.
    shm_pool: ?*client.wl.ShmPool = null,
    buffer: ?*client.wl.Buffer = null,
    /// Requests to wake the renderer (no-op in tests).
    frame_requests: usize = 0,
    /// Dummy listener data for the wl_output proxy.
    output_listener_data: u8 = 0,
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
        // capture_output object argument and output_from_resource its
        // identity check; the framebuffer is the capture source.
        ts.backend = try backend_mod.Backend.init(allocator, &ts.io, &ts.log_cfg, &fake_backend_impl, &ts.dummy);
        errdefer if (ts.backend) |b| b.destroy();
        ts.output = try Output.create(
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
        // The foreign output: never captured, never enabled — it exists
        // only so a client can hold a wl_output resource the
        // compositor's wl_output module does not own.
        ts.output_foreign = try Output.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.backend.?,
            &fake_output_impl,
            &ts.dummy,
            .{ .width = 32, .height = 32, .refresh_msec = 16 },
        );
        errdefer if (ts.output_foreign) |o| o.destroy();
        ts.wl_output_foreign = try wl_output_mod.WlOutput.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.output_foreign.?,
            "foreign",
            "foreign output",
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
            outputFromResource,
            ts,
            requestFrame,
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
        if (reg_capture.shm_name == null or reg_capture.output_name == null or
            reg_capture.output_name_foreign == null or reg_capture.screencopy_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_shm (for the copy buffer), wl_output (the
        // capture argument) and the screencopy manager at the tested
        // version. The wl_output bind response is consumed by a dummy
        // listener (libwayland-client aborts on listener-less opcodes).
        ts.wl_shm = try registry.bind(reg_capture.shm_name.?, client.wl.Shm, 1);
        ts.wl_output_client = try registry.bind(reg_capture.output_name.?, client.wl.Output, 1);
        ts.wl_output_foreign_client = try registry.bind(reg_capture.output_name_foreign.?, client.wl.Output, 1);
        ts.screencopy_mgr = try registry.bind(
            reg_capture.screencopy_name.?,
            client.zwlr.ScreencopyManagerV1,
            manager_version,
        );
        ts.wl_output_client.?.setListener(*u8, ignoreOutputEvents, &ts.output_listener_data);
        ts.wl_output_foreign_client.?.setListener(*u8, ignoreOutputEvents, &ts.output_listener_data);
        try ts.pump();

        // Enable the output: captures of a disabled output fail (wlroots
        // :508-511), and the deferred copy needs a commit to fire.
        try enableOutput(ts);
        return ts;
    }

    /// Consume the wl_output bind-time state dump.
    fn ignoreOutputEvents(_: *client.wl.Output, _: client.wl.Output.Event, _: *u8) void {}

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers (the
        // frame's frameDestroy) must run while the screencopy module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.sc) |sc| sc.deinit();
        // Destroying the output frees the WlOutput via its destroy
        // listener (wl_output.zig onOutputDestroy).
        if (ts.output) |o| o.destroy();
        if (ts.output_foreign) |o| o.destroy();
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
        return createBufferWithStride(ts, 64 * 4);
    }

    /// Create a 64x64 ARGB8888 wl_shm buffer with an explicit stride
    /// (for the stride-validation test).
    fn createBufferWithStride(ts: *TestServer, stride: i32) !*client.wl.Buffer {
        const width: i32 = 64;
        const height: i32 = 64;
        const fd = try std.posix.memfd_create("screencopy-test-buffer", std.os.linux.MFD.CLOEXEC);
        defer _ = std.os.linux.close(fd);
        const pool_size = @as(usize, @intCast(stride)) * @as(usize, @intCast(height));
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
        ts.shm_pool = try ts.wl_shm.?.createPool(fd, @intCast(pool_size));
        ts.buffer = try ts.shm_pool.?.createBuffer(0, width, height, stride, .argb8888);
        return ts.buffer.?;
    }

    /// One shared roundtrip (utils/test_pump.zig) plus this harness's own
    /// client-side poll and dispatch, so the server's replies reach the
    /// test's listeners before the assertions run. A dispatch failure
    /// nulls the client: the server already destroyed it, so deinit must
    /// not destroy it again.
    fn pump(ts: *TestServer) !void {
        try test_pump.roundtrip(ts.c_display, ts.display.?, 0);
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

/// Commit an enabling state so the output is enabled and the deferred
/// copy has a commit to fire on.
fn enableOutput(ts: *TestServer) !void {
    var state = Output.State.init(ts.allocator);
    defer state.deinit();
    state.committed = Output.State.committed_enabled | Output.State.committed_mode;
    state.enabled = true;
    state.mode = .{ .width = 64, .height = 64, .refresh_msec = 16 };
    try ts.output.?.commitState(&state);
}

/// Commit a frame (buffer + optional damage) to fire the deferred copy.
fn commitOutput(ts: *TestServer) !void {
    try commitOutputDamage(ts, null);
}

fn commitOutputDamage(ts: *TestServer, rect: ?geom.Rect) !void {
    var state = Output.State.init(ts.allocator);
    defer state.deinit();
    state.committed = Output.State.committed_enabled | Output.State.committed_mode |
        Output.State.committed_buffer;
    state.enabled = true;
    state.mode = .{ .width = 64, .height = 64, .refresh_msec = 16 };
    state.buffer = @ptrCast(ts.fb.?);
    if (rect) |r| try state.damage.add(r);
    try ts.output.?.commitState(&state);
}

fn getFramebuffer(ctx: *anyopaque, _: bool) ?*pixman.Framebuffer {
    const ts: *TestServer = @ptrCast(@alignCast(ctx));
    return ts.fb;
}

fn outputFromResource(ctx: *anyopaque, resource: *server.wl.Output) ?*Output {
    const ts: *TestServer = @ptrCast(@alignCast(ctx));
    const wl_output = ts.wl_output orelse return null;
    if (!wl_output.owns(resource)) return null;
    return ts.output;
}

fn requestFrame(ctx: *anyopaque) void {
    const ts: *TestServer = @ptrCast(@alignCast(ctx));
    ts.frame_requests += 1;
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

    // The copy is deferred to the next output commit: nothing yet, and
    // the renderer was asked for a frame.
    try testing.expectEqual(@as(usize, 0), events.flags_count);
    try testing.expectEqual(@as(usize, 0), events.ready_count);
    try testing.expectEqual(@as(usize, 1), ts.frame_requests);

    try commitOutput(ts);
    try ts.pump();

    // flags + ready are since 1 and arrive; damage is since 2 and must
    // not: the v1 client listener has no damage slot and libwayland-client
    // aborts on the listener-less opcode, killing the client.
    try testing.expectEqual(@as(usize, 1), events.flags_count);
    try testing.expectEqual(@as(usize, 1), events.ready_count);
    try testing.expectEqual(@as(usize, 0), events.damage_count);
    try testing.expectEqual(@as(usize, 0), events.failed_count);
    try testing.expectEqual(@as(usize, 1), ts.sc.?.captures_served);
}

test "v3 manager: copy is deferred to the next output commit" {
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
    // Deferred: no ready until a commit presents a new frame.
    try testing.expectEqual(@as(usize, 0), events.ready_count);
    try testing.expectEqual(@as(usize, 1), ts.frame_requests);

    // A commit with no buffer (a mode-only or enable-only state) does not
    // serve the copy: it waits for a presented buffer.
    var no_buf = Output.State.init(ts.allocator);
    defer no_buf.deinit();
    no_buf.committed = Output.State.committed_enabled;
    no_buf.enabled = true;
    try ts.output.?.commitState(&no_buf);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), events.ready_count);

    try commitOutput(ts);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.ready_count);
    try testing.expectEqual(@as(usize, 0), events.failed_count);
    // Plain copy: no damage events (only copy_with_damage sends them).
    try testing.expectEqual(@as(usize, 0), events.damage_count);
}

test "capturing a disabled output fails the frame" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Disable the output, then capture: the frame fails immediately
    // (wlroots :508-511).
    var disable = Output.State.init(ts.allocator);
    defer disable.deinit();
    disable.committed = Output.State.committed_enabled;
    disable.enabled = false;
    try ts.output.?.commitState(&disable);

    const frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var events: FrameEvents = .{};
    frame.setListener(*FrameEvents, FrameEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.failed_count);
    try testing.expectEqual(@as(usize, 0), events.buffer_count);
}

test "capturing a foreign wl_output fails the frame" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // A wl_output resource bound to the foreign output's global is not
    // owned by the compositor's wl_output module: the capture must fail
    // the frame cleanly, not disconnect the client (wlroots
    // wlr_screencopy_v1.c:508-511 — output == NULL is send_failed, not
    // no_memory).
    const frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_foreign_client.?);
    var events: FrameEvents = .{};
    frame.setListener(*FrameEvents, FrameEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.failed_count);
    try testing.expectEqual(@as(usize, 0), events.buffer_count);

    // The connection survives the failed frame: a subsequent capture
    // with the owned output round-trips normally (a no_memory/postError
    // kill would have torn the client down and pump() would fail).
    const frame2 = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var events2: FrameEvents = .{};
    frame2.setListener(*FrameEvents, FrameEvents.listener, &events2);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), events2.failed_count);
    try testing.expectEqual(@as(usize, 1), events2.buffer_count);
}

test "copy_with_damage sends accumulated damage boxes" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Frame 1: the accumulator starts whole, so the first with_damage
    // copy reports the full output (wlroots screencopy_damage_create).
    const frame1 = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var fe1: FrameEvents = .{};
    frame1.setListener(*FrameEvents, FrameEvents.listener, &fe1);
    try ts.pump();
    const buffer1 = try ts.createBuffer();
    frame1.copyWithDamage(buffer1);
    try ts.pump();
    try commitOutput(ts);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), fe1.ready_count);
    try testing.expectEqual(@as(usize, 1), fe1.damage_count);
    try testing.expectEqual(@as(u32, 0), fe1.damage_x);
    try testing.expectEqual(@as(u32, 0), fe1.damage_y);
    try testing.expectEqual(@as(u32, 64), fe1.damage_width);
    try testing.expectEqual(@as(u32, 64), fe1.damage_height);

    // A commit with a partial-damage region accumulates it (no frame is
    // pending, so this only feeds the per-client region).
    try commitOutputDamage(ts, .{ .x = 10, .y = 12, .width = 5, .height = 6 });

    // Frame 2: the accumulated partial damage is sent as its own box.
    // The serving commit must itself carry partial damage — a buffer
    // commit without damage accumulates as whole (wlroots :62-66).
    const frame2 = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var fe2: FrameEvents = .{};
    frame2.setListener(*FrameEvents, FrameEvents.listener, &fe2);
    try ts.pump();
    const buffer2 = try ts.createBuffer();
    frame2.copyWithDamage(buffer2);
    try ts.pump();
    try commitOutputDamage(ts, .{ .x = 10, .y = 12, .width = 5, .height = 6 });
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), fe2.ready_count);
    try testing.expectEqual(@as(usize, 1), fe2.damage_count);
    try testing.expectEqual(@as(u32, 10), fe2.damage_x);
    try testing.expectEqual(@as(u32, 12), fe2.damage_y);
    try testing.expectEqual(@as(u32, 5), fe2.damage_width);
    try testing.expectEqual(@as(u32, 6), fe2.damage_height);

    // The client owns the frame lifetime: destroying a served frame is
    // legal ("can be sent at any time" — the E2E client does exactly
    // this after verifying pixels). The resource must still exist, so
    // this must not produce a protocol error (invalid object).
    frame1.destroy();
    try ts.pump();
    frame2.destroy();
    try ts.pump();
}

test "padded client stride is rejected as invalid_buffer" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var events: FrameEvents = .{};
    frame.setListener(*FrameEvents, FrameEvents.listener, &events);
    try ts.pump();

    // Advertised tight stride is 64*4 = 256; a padded 260-byte stride
    // must be rejected (wlroots :418-421), not silently mis-copied.
    const padded = try ts.createBufferWithStride(64 * 4 + 4);
    frame.copy(padded);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
}
