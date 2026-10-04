//! zwlr_screencopy_manager_v1 (v3): output capture for clients.
//!
//! On frame creation the manager sends one event per buffer type it can
//! copy into, then `buffer_done`: `buffer` (the wl_shm format, width,
//! height and tight stride) always, and `linux_dmabuf` (the DRM fourcc,
//! width, height) from v3 on when the compositor has a dmabuf import
//! path wired in (wlr-screencopy-unstable-v1.xml:211-220). The client
//! sends `copy(buffer)` (or `copy_with_damage(buffer)`) with a
//! wl_buffer of one of those types. The copy itself is DEFERRED to the
//! next output commit (wlroots wlr_screencopy_v1.c:434-435: the copy
//! samples a presented frame, never a mid-render or stale one); the
//! ready event then carries the commit timestamp. `copy_with_damage`
//! sends the accumulated per-client output damage boxes (wlroots
//! screencopy_damage_accumulate, :47-61) instead of a full rect.
//!
//! overlay_cursor: the compositor's framebuffer always has the cursor
//! composited into it, so overlay_cursor=1 is naturally satisfied; for
//! overlay_cursor=0 the copy source is the cursor-less base framebuffer
//! (a get_framebuffer callback flag — wlroots locks software cursors for
//! the opposite reason, :443-446).
//! # The two destinations
//! The shm destination is written through libwayland's own mapping
//! (wire.shm.Buffer plus the impl's begin/end_data_ptr_access). A
//! dmabuf destination is GPU memory, so it is written through the CPU
//! write mapping in buffers/dmabuf.zig (`beginWrite`, gbm_bo_map) —
//! a memcpy for a linear bo the driver maps in place, and a staged
//! round trip for anything else. Both run the same row loop over a
//! (pointer, stride) pair, so the two destinations receive identical
//! bytes.
//!
//! A dmabuf wl_buffer is only *accepted* when the frame advertised the
//! type: a wl_buffer nobody owns is the invalid_buffer protocol error
//! it always was, and a v1/v2 client was never told the type exists,
//! so a dmabuf buffer it sends gets that same error (the event is
//! since 3 — the advertisement and the acceptance are one gate,
//! `FrameState.dmabuf_format`).
//!
//! A destination this compositor DID import but cannot copy into —
//! wrong size, a format the frame did not advertise, a stride too
//! small for the frame, a bo the driver will not map — FAILS THE
//! FRAME instead. The protocol's answer to a copy that could not be
//! made is the `failed` event (wlr-screencopy-unstable-v1.xml:122-123,
//! "If the frame is successfully copied ... Otherwise, a failed event
//! is sent"), and the failures this path can hit are not the client's
//! bug the way a padded wl_shm stride is: half of them are properties
//! of the driver's mapping rather than of anything the client sent.
//! The wl_shm rejections are untouched and still post invalid_buffer.
//!
//! # The capture region
//! `capture_output_region` puts an origin AND an extent on the wire,
//! both client-controlled, and the far edge is their sum. That sum is
//! weighed against the output ONCE, here, at frame creation, and in
//! i64: wlroots compares the same box (`:313-319`) but at COPY time,
//! after the client has already allocated a destination for a region
//! the compositor cannot read. A region that does not fit fails the
//! frame here instead — before a FrameState exists and before any
//! buffer type is advertised — so x = INT32_MAX buys a client
//! `failed` and not a capture that traps the process in the row loop
//! at the next presenting commit. The copy-time check is kept, against
//! the framebuffer the row loop actually reads: that is the bound that
//! still holds when the output has been resized since.
//!
//! # Wiring the dmabuf destination
//! `Screencopy.init` takes no dmabuf argument, so the server hands
//! the path over afterwards with `setDmabufDestination`:
//!
//!     sc.setDmabufDestination(.{
//!         .ctx = linux_dmabuf,
//!         .resolve = resolveDmabufBuffer,
//!         .begin_write = dmabuf_mod.beginWrite,
//!         .end_write = dmabuf_mod.endWrite,
//!     });
//!
//! where `resolveDmabufBuffer` is `LinuxDmabuf.fromResource` rewrapped
//! with the ctx/fn pair (main.zig already has that adapter for the
//! compositor's own DmabufResolver). Until it is called this module is
//! shm-only, which is every backend without a GBM device.
//!
//! Teardown is the other half: call `clearDmabufDestination` before
//! `linux_dmabuf.deinit()`, or a `copy` that arrives afterwards would
//! dereference a freed module.
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, buffers/shm.zig,
//! buffers/dmabuf.zig (the fourccs and the CPU write mapping),
//! renderer/pixman.zig, output/output.zig (sibling modules).

const std = @import("std");
const log = @import("./utils/log.zig");
const wire = @import("./core/wire.zig");
const display_mod = @import("./core/display.zig");
const shm_mod = @import("./buffers/shm.zig");
const buffer_mod = @import("./buffers/buffer.zig");
const dmabuf_mod = @import("./buffers/dmabuf.zig");
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

/// The compositor's dmabuf import path, as a screencopy destination
/// needs it: resolve a client wl_buffer to the Buffer the compositor
/// owns for it, then take CPU write access to that Buffer's pixels.
/// Function pointers rather than a `?*linux_dmabuf.LinuxDmabuf`
/// field, the same reason `compositor.DmabufResolver` is a pointer
/// pair: shell/linux_dmabuf.zig imports modules that import this one,
/// and a field would close the cycle.
pub const DmabufDestination = struct {
    /// The module that owns the buffers (`ctx` is that module).
    ctx: *anyopaque,
    /// The Buffer for a client wl_buffer this path created; null when
    /// the resource is not one of them.
    resolve: *const fn (ctx: *anyopaque, resource: *wire.Resource) ?*buffer_mod.Buffer,
    /// Map a resolved buffer's pixels for writing. Null when the
    /// driver will not map it, which fails the frame.
    begin_write: *const fn (ctx: *anyopaque, buf: *buffer_mod.Buffer) ?dmabuf_mod.CpuWrite,
    /// Give a mapping back, AFTER the writes: for a bo GBM staged,
    /// this is where the pixels reach the bo.
    end_write: *const fn (ctx: *anyopaque, buf: *buffer_mod.Buffer, map: dmabuf_mod.CpuWrite) void,
};

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
    get_framebuffer: *const fn (ctx: *anyopaque, output: *Output, overlay_cursor: bool) ?*pixman.Framebuffer,
    fb_ctx: *anyopaque,
    /// Resolve a wl_output resource to the Output it belongs to; null
    /// when it is not this compositor's output.
    output_from_resource: *const fn (ctx: *anyopaque, resource: *server.wl.Output) ?*Output,
    output_ctx: *anyopaque,
    /// Wake the renderer so a deferred copy gets its next output commit.
    request_frame: *const fn (ctx: *anyopaque, output: *Output) void,
    request_ctx: *anyopaque,
    /// Completed captures: incremented once per served `copy` request
    /// (pixels fully copied into the client's buffer, before the frame
    /// is marked ready). The server reads this to time synth input
    /// against real client captures instead of frame counts.
    captures_served: u32 = 0,

    /// The dmabuf copy destination, or null when the compositor has no
    /// import path (no GBM device) or the server has not wired one.
    /// A null here means a dmabuf wl_buffer is a buffer nobody owns,
    /// which is the invalid_buffer protocol error it always was.
    dmabuf: ?DmabufDestination = null,

    /// Hand the compositor's dmabuf import path to this module. Called
    /// after `init` (which takes no dmabuf argument) and before the
    /// first frame is captured, because a frame decides from this
    /// whether it advertises the dmabuf buffer type at all.
    pub fn setDmabufDestination(self: *Screencopy, destination: DmabufDestination) void {
        self.dmabuf = destination;
        log.info("screencopy: dmabuf copy destinations enabled", self.io, self.log_cfg, "screencopy", .{});
    }

    /// Drop the dmabuf destination. The server calls this BEFORE the
    /// module that owns the buffers is destroyed: request handlers
    /// dereference `destination.ctx`, and a client can still send a
    /// `copy` after an unrelated module was torn down.
    pub fn clearDmabufDestination(self: *Screencopy) void {
        self.dmabuf = null;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        shm: *shm_mod.ShmState,
        get_framebuffer: *const fn (ctx: *anyopaque, output: *Output, overlay_cursor: bool) ?*pixman.Framebuffer,
        fb_ctx: *anyopaque,
        output_from_resource: *const fn (ctx: *anyopaque, resource: *server.wl.Output) ?*Output,
        output_ctx: *anyopaque,
        request_frame: *const fn (ctx: *anyopaque, output: *Output) void,
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
        log.debug("screencopy manager registered", io, log_cfg, "screencopy", .{});
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
    /// The client's validated copy destination; null until `copy` is
    /// requested. Doubles as the already-used guard; cleared once the
    /// frame is served or failed.
    buffer: ?*buffer_mod.Buffer = null,
    /// True when `buffer` is a dmabuf import rather than a wl_shm
    /// buffer, i.e. the copy reaches its pixels through the import
    /// path's CPU write mapping instead of libwayland's.
    destination_dmabuf: bool = false,
    /// The DRM fourcc a dmabuf destination must have, or null when
    /// this frame did NOT advertise the dmabuf buffer type (no import
    /// path, or a client too old to be told about one). The
    /// advertisement and the acceptance are the same gate: a
    /// wl_buffer this compositor owns but the client was never told it
    /// may send is a buffer this frame does not accept.
    dmabuf_format: ?u32 = null,
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
    const src_fb = sc.get_framebuffer(sc.fb_ctx, output, true) orelse {
        // No framebuffer yet: fail the frame without killing the client.
        const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
        failed.sendFailed();
        return;
    };

    // The region is in output LOGICAL coordinates; map it through the
    // inverse transform and the scale into buffer coordinates (wlroots
    // :576-580). The full-output form is the effective resolution
    // directly. Boxes are NOT clamped: wlroots judges the box against
    // the output and fails the frame when it does not fit (:313-319),
    // so a region that does not fit is FAILED here, at creation, where
    // the client learns of it before it has allocated anything — and
    // again at copy time, against the framebuffer that is really read.
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

    if (!regionInBounds(rx, ry, rw, rh, output.width, output.height)) {
        // A region outside the output fails the frame HERE, before the
        // FrameState exists and before a buffer type is advertised:
        // this is the ONE place the origin and the extent off the wire
        // are judged against the output, and both are client input.
        // Leaving it to the copy-time guard is what made a region like
        // x = INT32_MAX abort the process there instead (see
        // regionInBounds).
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

    // The dmabuf buffer type, advertised only when this compositor can
    // actually copy into one AND the client is new enough to be told
    // (the event is since 3, wlr-screencopy-unstable-v1.xml:211). A
    // frame that does not advertise it also does not accept one: a
    // client cannot have allocated a destination in a format it was
    // never given, so refusing that buffer tells it the truth.
    const dmabuf_format: ?u32 = if (sc.dmabuf != null and
        manager.getVersion() >= server.zwlr.ScreencopyFrameV1.linux_dmabuf_since_version)
        dmabufFormatFor(src_fb.format)
    else
        null;

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
        .dmabuf_format = dmabuf_format,
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
    if (dmabuf_format) |fourcc| {
        // Before buffer_done and after the shm event: the XML sends one
        // event per supported buffer type and then closes the list
        // (:87-91, :222-228).
        frame.sendLinuxDmabuf(fourcc, @intCast(rw), @intCast(rh));
    }
    if (frame.getVersion() >= 3) frame.sendBufferDone();
}

/// True when the capture region lies inside a `src_width` x
/// `src_height` source (wlroots :313-319, the bounds wlroots itself
/// compares at copy time).
///
/// The far edge is computed in i64, never i32: the origin AND the
/// extent are client-supplied, and `x + width` in i32 overflows for a
/// region like x = INT32_MAX, width = 1 — which PANICS here in
/// ReleaseSafe (the project default) and wraps negative in ReleaseFast,
/// where the comparison would pass and the copy would then index the
/// framebuffer out of bounds. Both destinations abort. Same class of
/// trap the `rowLen` product had, for the same reason: a value that
/// came off the wire.
fn regionInBounds(x: i32, y: i32, width: i32, height: i32, src_width: i32, src_height: i32) bool {
    if (x < 0 or y < 0 or width <= 0 or height <= 0) return false;
    const far_x = @as(i64, x) + @as(i64, width);
    const far_y = @as(i64, y) + @as(i64, height);
    return far_x <= @as(i64, src_width) and far_y <= @as(i64, src_height);
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

    const buf = switch (resolveDestination(state, buffer)) {
        .none => {
            // A buffer no factory of ours produced: the same
            // invalid_buffer the shm-only compositor always posted.
            frame.postError(.invalid_buffer, "buffer is not a wl_shm or a dmabuf buffer");
            return;
        },
        .shm => |shm_buf| resolved: {
            if (!validateShm(frame, state, shm_buf)) return;
            break :resolved shm_buf;
        },
        .dmabuf => |dmabuf_buf| resolved: {
            if (!validateDmabuf(state, dmabuf_buf)) {
                // A dmabuf destination this compositor cannot copy
                // into fails the frame instead of erroring the client
                // (module header, "The two destinations").
                frameFailed(state);
                return;
            }
            state.destination_dmabuf = true;
            break :resolved dmabuf_buf;
        },
    };
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
    state.screencopy.request_frame(state.screencopy.request_ctx, state.output);
}

/// The client's copy destination, resolved from the wl_buffer it sent.
/// `none` is a buffer this compositor does not own.
const Destination = union(enum) {
    shm: *buffer_mod.Buffer,
    dmabuf: *buffer_mod.Buffer,
    none,
};

/// Which Buffer receives the copy. A wl_buffer comes from exactly one
/// factory, so the two registries never overlap: the import is asked
/// first because it is the rarer answer, and a null from it falls
/// through to the shm registry every wl_shm client needs.
fn resolveDestination(state: *FrameState, buffer: *server.wl.Buffer) Destination {
    // Only when this frame advertised the type — see
    // FrameState.dmabuf_format.
    if (state.dmabuf_format != null) {
        if (state.screencopy.dmabuf) |destination| {
            if (destination.resolve(destination.ctx, @ptrCast(buffer))) |buf| {
                return .{ .dmabuf = buf };
            }
        }
    }
    const buf = state.screencopy.shm.fromResource(state.screencopy.allocator, @ptrCast(buffer)) catch {
        return .none;
    };
    return .{ .shm = buf };
}

/// The wl_shm destination must be of the advertised size, format and
/// exact stride (wlroots :381-421; the stride rejection is :418-421 —
/// a padded client buffer must not be silently mis-copied row by row).
/// A rejection posts invalid_buffer and kills the client, as wlroots
/// does: every check here is a claim the client itself made and cannot
/// have got wrong by accident.
fn validateShm(
    frame: *server.zwlr.ScreencopyFrameV1,
    state: *FrameState,
    buf: *buffer_mod.Buffer,
) bool {
    if (buf.width != state.width or buf.height != state.height) {
        frame.postError(.invalid_buffer, "buffer size does not match the frame");
        return false;
    }
    const get_shm = buf.impl.get_shm orelse {
        frame.postError(.invalid_buffer, "buffer has no shm data");
        return false;
    };
    const shm = get_shm(buf) orelse {
        frame.postError(.invalid_buffer, "buffer has no shm data");
        return false;
    };
    if (wire.shm.Buffer.getFormat(shm) != state.shm_format) {
        frame.postError(.invalid_buffer, "buffer format does not match the frame");
        return false;
    }
    const stride = wire.shm.Buffer.getStride(shm);
    if (stride <= 0 or stride != state.shm_stride) {
        frame.postError(.invalid_buffer, "buffer stride does not match the frame");
        return false;
    }
    return true;
}

/// The dmabuf destination, checked against what this frame
/// advertised. False FAILS THE FRAME; it never kills the client.
///
/// The modifier is deliberately not checked: a client may import a
/// tiled destination (the linux_dmabuf global advertises whatever the
/// device takes) and GBM stages it, which costs a driver round trip
/// and not correctness. The stride that matters is the one the copy
/// walks with, and that is checked in copyPixelsDmabuf, against the
/// mapping the driver actually gave back.
fn validateDmabuf(state: *FrameState, buf: *buffer_mod.Buffer) bool {
    if (buf.width != state.width or buf.height != state.height) return false;
    const get_dmabuf = buf.impl.get_dmabuf orelse return false;
    const attrs: *dmabuf_mod.Attributes = @ptrCast(@alignCast(get_dmabuf(buf) orelse return false));
    // The fourcc from the `linux_dmabuf` event: the client allocated
    // this buffer to receive exactly those bytes, in that layout.
    if (attrs.format != state.dmabuf_format.?) return false;
    // The fourccs this advertises are single-plane
    // (gbm_device_get_format_modifier_plane_count is 1 for both), so a
    // second plane does not describe the image the copy is about to
    // write, whatever the client claimed.
    if (attrs.n_planes != 1) return false;
    // A row must have room for the frame's width in 4-byte pixels. A
    // smaller claimed stride makes the row loop walk into the next
    // row's pixels, and past the end of the object on the last one.
    if (attrs.planes[0].stride < rowLen(state)) return false;
    return true;
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

    const src = state.screencopy.get_framebuffer(state.screencopy.fb_ctx, state.output, state.overlay_cursor) orelse {
        frameFailed(state);
        return;
    };
    // The box must lie inside the source (wlroots :313-319). Compared
    // in i64, NOT i32: the origin and the extent both came off the
    // wire, and their sum overflows for a region like x = INT32_MAX,
    // which panics in ReleaseSafe and wraps negative in ReleaseFast —
    // where the guard would pass and the copy would walk off the
    // framebuffer. `capture` refuses such a region at creation, so
    // this is the second line, not the only one.
    if (!regionInBounds(state.x, state.y, state.width, state.height, src.width, src.height)) {
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
    // Cleared with the buffer it describes: a frame that is finished
    // is never copied into again, and a stale flag must not outlive
    // the Buffer it was decided from.
    state.destination_dmabuf = false;
    state.finished = true;
}

/// Copy the region into whichever destination the client sent.
fn copyPixels(state: *FrameState, src: *pixman.Framebuffer) bool {
    return if (state.destination_dmabuf)
        copyPixelsDmabuf(state, src)
    else
        copyPixelsShm(state, src);
}

/// Row-wise copy of the region into the client's wl_shm buffer, through
/// libwayland's own mapping.
fn copyPixelsShm(state: *FrameState, src: *pixman.Framebuffer) bool {
    const buf = state.buffer orelse return false;
    const get_shm = buf.impl.get_shm orelse return false;
    const shm = get_shm(buf) orelse return false;
    const begin = buf.impl.begin_data_ptr_access orelse return false;
    const end = buf.impl.end_data_ptr_access orelse return false;
    const dst_ptr = begin(buf) catch return false;
    defer end(buf);
    const dst = dst_ptr orelse return false;
    // The stride was validated to equal the advertised tight stride.
    copyRegion(state, src, dst, @intCast(wire.shm.Buffer.getStride(shm)));
    return true;
}

/// Row-wise copy into the client's dmabuf, through the import path's
/// CPU write mapping (gbm_bo_map; buffers/dmabuf.zig beginWrite).
/// False fails the frame, and only for the two things this mapping can
/// tell us that validation could not: the driver refused to map the
/// bo, or it handed back a pitch too narrow for a row. The second
/// check is why the copy waits for the mapping — the client's claimed
/// stride is not the pitch GBM mapped.
fn copyPixelsDmabuf(state: *FrameState, src: *pixman.Framebuffer) bool {
    const buf = state.buffer orelse return false;
    const destination = state.screencopy.dmabuf orelse return false;
    const map = destination.begin_write(destination.ctx, buf) orelse return false;
    // A staged mapping is written back here, so this must run AFTER the
    // copy (and must run at all: skipping it loses the pixels).
    defer destination.end_write(destination.ctx, buf, map);
    if (map.stride < rowLen(state)) return false;
    copyRegion(state, src, map.ptr, map.stride);
    return true;
}

/// Bytes in one row of the capture region. Every format this frame
/// advertises is 4 bytes per pixel, so a row is the frame width times
/// four. The product is done in usize: the frame is already on the
/// wire with that width, and an i32 overflow here would trap a copy
/// the protocol accepted.
fn rowLen(state: *const FrameState) usize {
    return @as(usize, @intCast(state.width)) * 4;
}

/// The row loop both destinations share: rows are `stride` bytes apart
/// on each side and every format involved is the same ARGB8888 layout
/// (wl_shm's ARGB8888 and DRM_FORMAT_ARGB8888 are both a native 32-bit
/// 0xAARRGGBB, drm_fourcc.h fourcc_code('A','R','2','4')), so a row is
/// a memcpy with no conversion. That shared loop is what makes the two
/// destinations receive identical bytes.
fn copyRegion(state: *const FrameState, src: *pixman.Framebuffer, dst: [*]u8, stride: usize) void {
    const row_len = rowLen(state);
    const src_stride: usize = @intCast(src.stride);
    const src_offset: usize = @as(usize, @intCast(state.y)) * src_stride +
        @as(usize, @intCast(state.x)) * 4;
    var row: usize = 0;
    while (row < @as(usize, @intCast(state.height))) : (row += 1) {
        const src_row = src.data[src_offset + row * src_stride ..][0..row_len];
        const dst_row = dst[row * stride ..][0..row_len];
        @memcpy(dst_row, src_row);
    }
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

/// The DRM fourcc a `linux_dmabuf` destination for a framebuffer of
/// this read format must use, or null when no dmabuf destination can
/// carry those bytes. The two formats a frame can advertise are the
/// same 32-bit 0xAARRGGBB value in both spellings — wl_shm's
/// ARGB8888 (wayland.xml) and pixman's a8r8g8b8 are one native-endian
/// word — so the copy stays a row memcpy and the two destinations
/// agree byte for byte. A read format with no 4-byte dmabuf twin
/// (there is none today) would have to fail the frame instead of
/// converting, and this is where that decision is made.
fn dmabufFormatFor(shm_format: u32) ?u32 {
    return switch (shm_format) {
        pixman.format_argb8888 => dmabuf_mod.drm_format_argb8888,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const posix = std.posix;
const backend_mod = @import("./backend/backend.zig");
const wl_output_mod = @import("./output/wl_output.zig");
const test_pump = @import("./utils/test_pump.zig");

/// libwayland-client >= 1.18: the code and object of the last protocol
/// error, so a client-killing test can pin WHICH object answered.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

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
    /// dmabuf buffer types advertised. Zero unless the compositor has
    /// an import path AND the frame's client is new enough to be told
    /// (the event is since 3) — the same gate the copy request uses.
    linux_dmabuf_count: usize = 0,
    /// The fourcc, width and height of the last `linux_dmabuf` event.
    linux_dmabuf_format: u32 = 0,
    linux_dmabuf_width: u32 = 0,
    linux_dmabuf_height: u32 = 0,
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
            // Since 3, and only when this compositor can copy into a
            // dmabuf: counted apart from buffer_done so a test can
            // assert the buffer type was (or was not) offered.
            .linux_dmabuf => |d| {
                data.linux_dmabuf_count += 1;
                data.linux_dmabuf_format = d.format;
                data.linux_dmabuf_width = d.width;
                data.linux_dmabuf_height = d.height;
            },
        }
    }
};

/// A CPU-backed stand-in for an imported dmabuf: the Buffer the copy
/// path resolves for a client wl_buffer, plus the write access the copy
/// takes on it. Its impl is deliberately the same shape as a real
/// import — a `get_dmabuf` and nothing else, no shm handle and no
/// begin/end_data_ptr_access (buffers/dmabuf.zig, dmabuf_impl) — so
/// code that reached for a wl_shm pointer or a CPU data pointer fails
/// here exactly as it would on hardware.
///
/// The write path is staged, the way a bo GBM cannot map in place: the
/// copy writes `staging` and `endWrite` moves the bytes into `pixels`.
/// A copy that skipped endWrite therefore loses its pixels, which is
/// the bug the staging exists to catch.
const FakeDmabuf = struct {
    allocator: std.mem.Allocator,
    /// What the compositor knows about the "import": the geometry and
    /// the layout the copy path validates the destination against.
    attrs: dmabuf_mod.Attributes,
    /// The destination image. Only endWrite writes it.
    pixels: []u8,
    stride: usize,
    /// The image a mapping hands out.
    staging: []u8,
    /// Mappings currently open. A served frame leaves this at zero.
    open: usize = 0,
    /// Mappings ever handed out. Zero means the copy never reached the
    /// destination: a rejected buffer is refused before this point and
    /// must never be mapped.
    maps: usize = 0,
    // SAFETY: assigned from Buffer.init at construction, before the
    // Buffer is reachable from anywhere.
    buf: *buffer_mod.Buffer,
};

fn fakeDmabufGetDmabuf(buf: *buffer_mod.Buffer) ?*anyopaque {
    const fake: *FakeDmabuf = @ptrCast(@alignCast(buf.data));
    return @ptrCast(&fake.attrs);
}

fn fakeDmabufDestroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    _ = allocator;
    const fake: *FakeDmabuf = @ptrCast(@alignCast(data));
    fake.allocator.free(fake.pixels);
    fake.allocator.free(fake.staging);
    fake.allocator.destroy(fake);
}

const fake_dmabuf_impl: buffer_mod.Impl = .{
    .get_dmabuf = fakeDmabufGetDmabuf,
    .get_shm = null,
    .begin_data_ptr_access = null,
    .end_data_ptr_access = null,
    .destroy = fakeDmabufDestroy,
};

/// `LinuxDmabuf.fromResource` in the ctx/fn pair a screencopy
/// destination takes, over the harness's own one-entry table.
fn fakeDmabufResolve(ctx: *anyopaque, resource: *wire.Resource) ?*buffer_mod.Buffer {
    const ts: *TestServer = @ptrCast(@alignCast(ctx));
    if (ts.fake_dmabuf_resource != resource) return null;
    const fake = ts.fake_dmabuf orelse return null;
    return fake.buf;
}

fn fakeDmabufBeginWrite(ctx: *anyopaque, buf: *buffer_mod.Buffer) ?dmabuf_mod.CpuWrite {
    _ = ctx;
    const fake: *FakeDmabuf = @ptrCast(@alignCast(buf.data));
    @memcpy(fake.staging, fake.pixels);
    fake.open += 1;
    fake.maps += 1;
    // The token is the double itself: endWrite re-derives it from the
    // Buffer, and CpuWrite only has to carry it unchanged.
    const token: ?*anyopaque = @ptrCast(fake);
    return .{ .ptr = fake.staging.ptr, .stride = fake.stride, .map_data = token };
}

fn fakeDmabufEndWrite(ctx: *anyopaque, buf: *buffer_mod.Buffer, map: dmabuf_mod.CpuWrite) void {
    _ = ctx;
    const fake: *FakeDmabuf = @ptrCast(@alignCast(buf.data));
    // A real write-back takes what the caller wrote through the
    // mapping, not the image the mapping started from.
    @memcpy(fake.pixels, map.ptr[0..fake.pixels.len]);
    fake.open -= 1;
}

/// The capture source's pattern: opaque, and a distinct value for
/// every (x, y) of the 64x64 test frame.
fn patternPixel(x: u32, y: u32) u32 {
    return 0xFF00_0000 | (y << 16) | (x << 8);
}

/// Fill the capture source with `patternPixel`, so a copy that copied
/// nothing, the wrong region, or the wrong row cannot pass a
/// comparison against it.
fn fillCapturePattern(fb: *pixman.Framebuffer) void {
    const stride: usize = @intCast(fb.stride);
    var y: usize = 0;
    while (y < @as(usize, @intCast(fb.height))) : (y += 1) {
        var x: usize = 0;
        while (x < @as(usize, @intCast(fb.width))) : (x += 1) {
            const at = y * stride + x * 4;
            const pixel = patternPixel(@intCast(x), @intCast(y));
            std.mem.writeInt(u32, fb.data[at..][0..4], pixel, .little);
        }
    }
}

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
    /// The object behind the shm pool, retained (not closed after the
    /// pool request) so a test can read the copied pixels back through
    /// its own mapping. libwayland holds a dup, so the pool stays valid
    /// either way; only the test's readability needs this one.
    shm_fd: std.posix.fd_t = -1,
    /// The CPU-backed dmabuf import the copy path resolves, and the
    /// server-side resource the client's copy request names. Both null
    /// until createDmabufBuffer runs.
    fake_dmabuf: ?*FakeDmabuf = null,
    fake_dmabuf_resource: ?*wire.Resource = null,
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
        // The fabricated dmabuf import first: its server-side resource
        // belongs to the client that is about to go, and the wrapper is
        // ours.
        ts.destroyFakeDmabuf();
        if (ts.shm_fd >= 0) {
            _ = std.os.linux.close(ts.shm_fd);
            ts.shm_fd = -1;
        }
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
        errdefer _ = std.os.linux.close(fd);
        const pool_size = @as(usize, @intCast(stride)) * @as(usize, @intCast(height));
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
        ts.shm_pool = try ts.wl_shm.?.createPool(fd, @intCast(pool_size));
        ts.buffer = try ts.shm_pool.?.createBuffer(0, width, height, stride, .argb8888);
        // The object is retained instead of closed: libwayland holds a
        // dup for the pool, so the destination stays valid either way,
        // but only this descriptor lets a test read the pixels back.
        ts.retainShmFd(fd);
        return ts.buffer.?;
    }

    /// The shm destination's pixels, read through the pool object's own
    /// descriptor: the very bytes wl_shm handed the compositor.
    fn readShmPixels(ts: *TestServer, stride: usize, height: usize) ![]u8 {
        if (ts.shm_fd < 0) return error.NoShmBuffer;
        const map = std.posix.mmap(
            null,
            stride * height,
            .{ .READ = true, .WRITE = false },
            .{ .TYPE = .SHARED },
            ts.shm_fd,
            0,
        ) catch return error.ShmMapFailed;
        defer std.posix.munmap(map);
        return ts.allocator.dupe(u8, map);
    }

    fn retainShmFd(ts: *TestServer, fd: std.posix.fd_t) void {
        // The tests that create two shm buffers (copy_with_damage) must
        // not leak the first object.
        if (ts.shm_fd >= 0) _ = std.os.linux.close(ts.shm_fd);
        ts.shm_fd = fd;
    }

    /// Hand the compositor's dmabuf import path to the screencopy
    /// module, in the shape src/server/main.zig will: the resolver is
    /// the harness's one-entry table, the write access is the staged
    /// double's. After this the module advertises the dmabuf buffer
    /// type to v3 clients.
    fn enableDmabufDestination(ts: *TestServer) void {
        ts.sc.?.setDmabufDestination(.{
            .ctx = ts,
            .resolve = fakeDmabufResolve,
            .begin_write = fakeDmabufBeginWrite,
            .end_write = fakeDmabufEndWrite,
        });
    }

    /// A wl_buffer the harness owns as a dmabuf import: a client proxy
    /// for an object id no wl_shm pool made, the server-side resource
    /// of that exact id, and the CPU-backed import the resolver hands
    /// back for it.
    ///
    /// The zwp_linux_dmabuf_v1 factory needs a live GBM device, which a
    /// test may not have, so the object is fabricated on both sides at
    /// one id — the same trick buffers/shm.zig's resource test uses.
    /// Any previous double is released first, which is only safe
    /// because a frame that rejected its buffer holds no reference to
    /// it.
    fn createDmabufBuffer(ts: *TestServer, width: i32, height: i32, format: u32) !*client.wl.Buffer {
        ts.destroyFakeDmabuf();
        const stride: usize = @as(usize, @intCast(width)) * 4;
        const size = stride * @as(usize, @intCast(height));
        const fake = try ts.allocator.create(FakeDmabuf);
        errdefer ts.allocator.destroy(fake);
        const pixels = try ts.allocator.alloc(u8, size);
        errdefer ts.allocator.free(pixels);
        const staging = try ts.allocator.alloc(u8, size);
        errdefer ts.allocator.free(staging);
        @memset(pixels, 0);
        @memset(staging, 0);
        fake.* = .{
            .allocator = ts.allocator,
            .attrs = .{
                .width = width,
                .height = height,
                .format = format,
                .modifier = dmabuf_mod.drm_format_mod_linear,
                .n_planes = 1,
            },
            .pixels = pixels,
            .stride = stride,
            .staging = staging,
            // SAFETY: assigned from Buffer.init below, before the
            // Buffer is reachable from anywhere.
            .buf = undefined,
        };
        // No fd: the import is CPU-backed, and closePlanes on a set
        // whose fds are all -1 is a no-op (buffers/dmabuf.zig).
        fake.attrs.planes[0] = .{ .fd = -1, .offset = 0, .stride = @intCast(stride) };
        const buf = try buffer_mod.Buffer.init(ts.allocator, &fake_dmabuf_impl, fake, width, height);
        fake.buf = buf;
        ts.fake_dmabuf = fake;

        // Client side: a fresh object id for the copy request to carry.
        const proxy = try client.wl.Proxy.create(@ptrCast(ts.c_display.?), client.wl.Buffer.interface);
        // Server side: the resource of that exact id, which the copy
        // request resolves to and the resolver answers for.
        ts.fake_dmabuf_resource = wire.Resource.create(
            ts.client.?,
            wire.wl.Buffer,
            1,
            proxy.getId(),
        ) catch return error.ResourceCreateFailed;
        return @ptrCast(proxy);
    }

    /// Release the fabricated import: the server-side resource first
    /// (it belongs to the client), then the wrapper.
    ///
    /// The resource is the CLIENT's object, not the harness's: it was
    /// created with `wl_resource_create` on `ts.client` and lives in
    /// that client's object map. It only reaches this function while
    /// the client still owns it — `forgetClient` drops the handle
    /// otherwise — so `resource.destroy()` never touches a client the
    /// server has already destroyed.
    fn destroyFakeDmabuf(ts: *TestServer) void {
        if (ts.fake_dmabuf_resource) |resource| {
            resource.destroy();
            ts.fake_dmabuf_resource = null;
        }
        if (ts.fake_dmabuf) |fake| {
            buffer_mod.Buffer.destroy(fake.buf);
            ts.fake_dmabuf = null;
        }
    }

    /// The server destroyed this client: a protocol error kills it
    /// inside the server's own request dispatch
    /// (wl_client_connection_data, wayland-server.c:498-500), and
    /// `wl_client_destroy` frees every resource the client owned
    /// (wayland-server.c:1025) — the fabricated dmabuf buffer's
    /// server-side resource among them. Both handles go at once: the
    /// client is dangling, and destroying that resource again would be
    /// a use-after-free, so nothing may hold it past this point.
    fn forgetClient(ts: *TestServer) void {
        ts.client = null;
        ts.fake_dmabuf_resource = null;
    }

    /// One shared roundtrip (utils/test_pump.zig) plus this harness's own
    /// client-side poll and dispatch, so the server's replies reach the
    /// test's listeners before the assertions run. A dispatch failure
    /// means the server already destroyed the client: `forgetClient`
    /// drops it, so deinit must not destroy it again.
    fn pump(ts: *TestServer) !void {
        try test_pump.roundtrip(ts.c_display, ts.display.?, 0);
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                ts.forgetClient();
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
    state.buffer = .{ .cpu = ts.fb.? };
    if (rect) |r| try state.damage.add(r);
    try ts.output.?.commitState(&state);
}

fn getFramebuffer(ctx: *anyopaque, _: *Output, _: bool) ?*pixman.Framebuffer {
    const ts: *TestServer = @ptrCast(@alignCast(ctx));
    return ts.fb;
}

fn outputFromResource(ctx: *anyopaque, resource: *server.wl.Output) ?*Output {
    const ts: *TestServer = @ptrCast(@alignCast(ctx));
    const wl_output = ts.wl_output orelse return null;
    if (!wl_output.owns(resource)) return null;
    return ts.output;
}

fn requestFrame(ctx: *anyopaque, _: *Output) void {
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

test "a dmabuf copy destination receives the same pixels as an shm one" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    ts.enableDmabufDestination();
    // A pattern the copy cannot fake: every pixel differs from its
    // neighbours and from zero, so an unwritten destination, the wrong
    // region or a copy that never happened all fail the comparison.
    fillCapturePattern(ts.fb.?);

    // The shm reference: the same source and the same region, through
    // the path that already worked. The dmabuf destination is wired
    // in, so this also proves the two registries do not shadow each
    // other.
    const shm_frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var shm_events: FrameEvents = .{};
    shm_frame.setListener(*FrameEvents, FrameEvents.listener, &shm_events);
    try ts.pump();
    // v3 with an import path: both buffer types are on the table, and
    // the dmabuf one names the source's fourcc and the frame's size.
    try testing.expectEqual(@as(usize, 1), shm_events.buffer_count);
    try testing.expectEqual(@as(usize, 1), shm_events.linux_dmabuf_count);
    try testing.expectEqual(dmabuf_mod.drm_format_argb8888, shm_events.linux_dmabuf_format);
    try testing.expectEqual(@as(u32, 64), shm_events.linux_dmabuf_width);
    try testing.expectEqual(@as(u32, 64), shm_events.linux_dmabuf_height);
    try testing.expectEqual(@as(usize, 1), shm_events.buffer_done_count);

    const shm_buffer = try ts.createBuffer();
    shm_frame.copy(shm_buffer);
    try ts.pump();
    try commitOutput(ts);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), shm_events.ready_count);
    try testing.expectEqual(@as(usize, 0), shm_events.failed_count);
    const shm_pixels = try ts.readShmPixels(64 * 4, 64);
    defer allocator.free(shm_pixels);

    // The dmabuf destination: a client wl_buffer the import path owns,
    // in the advertised size and format.
    const dmabuf_buffer = try ts.createDmabufBuffer(64, 64, dmabuf_mod.drm_format_argb8888);
    const dmabuf_frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var dmabuf_events: FrameEvents = .{};
    dmabuf_frame.setListener(*FrameEvents, FrameEvents.listener, &dmabuf_events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), dmabuf_events.linux_dmabuf_count);
    dmabuf_frame.copy(dmabuf_buffer);
    try ts.pump();
    // Still deferred: a destination is not a served copy.
    try testing.expectEqual(@as(usize, 0), dmabuf_events.ready_count);
    try commitOutput(ts);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), dmabuf_events.ready_count);
    try testing.expectEqual(@as(usize, 0), dmabuf_events.failed_count);
    // Both copies counted: the shm reference and the dmabuf one.
    try testing.expectEqual(@as(u32, 2), ts.sc.?.captures_served);

    const fake = ts.fake_dmabuf.?;
    // The destination was mapped once and the mapping handed back: a
    // copy that skipped endWrite would leave pixels behind.
    try testing.expectEqual(@as(usize, 1), fake.maps);
    try testing.expectEqual(@as(usize, 0), fake.open);

    // Byte for byte against the shm copy of the same capture.
    try testing.expectEqualSlices(u8, shm_pixels, fake.pixels);
    // And not two empty images that merely match each other.
    try testing.expectEqual(patternPixel(0, 0), std.mem.readInt(u32, fake.pixels[0..4], .little));
    try testing.expectEqual(patternPixel(63, 63), std.mem.readInt(u32, fake.pixels[fake.pixels.len - 4 ..][0..4], .little));
}

test "a wrong-size or wrong-format dmabuf destination fails the frame" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    ts.enableDmabufDestination();
    fillCapturePattern(ts.fb.?);

    // A 32x32 destination for a 64x64 frame: a real import of the
    // wrong geometry, which the copy cannot be made into.
    const small = try ts.createDmabufBuffer(32, 32, dmabuf_mod.drm_format_argb8888);
    const small_frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var small_events: FrameEvents = .{};
    small_frame.setListener(*FrameEvents, FrameEvents.listener, &small_events);
    try ts.pump();
    small_frame.copy(small);
    try ts.pump();

    // failed, and at the copy request: no commit was needed, no
    // deferred copy was armed, and the destination was never even
    // mapped — let alone written.
    try testing.expectEqual(@as(usize, 1), small_events.failed_count);
    try testing.expectEqual(@as(usize, 0), small_events.ready_count);
    try testing.expectEqual(@as(usize, 0), small_events.flags_count);
    try testing.expectEqual(@as(usize, 0), ts.frame_requests);
    const small_fake = ts.fake_dmabuf.?;
    try testing.expectEqual(@as(usize, 0), small_fake.maps);
    try testing.expectEqual(@as(usize, 0), small_fake.open);
    for (small_fake.pixels) |byte| try testing.expectEqual(@as(u8, 0), byte);

    // The connection survived. This is the difference from the shm
    // path, which answers a wrong-size buffer with invalid_buffer and
    // kills the client (the padded-stride test above): the roundtrip
    // below cannot happen if this client is gone.
    const after = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var after_events: FrameEvents = .{};
    after.setListener(*FrameEvents, FrameEvents.listener, &after_events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), after_events.buffer_count);
    try testing.expectEqual(@as(usize, 0), after_events.failed_count);

    // A destination in a fourcc the frame did not advertise fails the
    // same way: the client allocated it for different bytes.
    const wrong_format = try ts.createDmabufBuffer(64, 64, dmabuf_mod.drm_format_xrgb8888);
    const format_frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var format_events: FrameEvents = .{};
    format_frame.setListener(*FrameEvents, FrameEvents.listener, &format_events);
    try ts.pump();
    format_frame.copy(wrong_format);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), format_events.failed_count);
    try testing.expectEqual(@as(usize, 0), format_events.ready_count);
    try testing.expectEqual(@as(usize, 0), ts.fake_dmabuf.?.maps);
}

test "a v1 frame is neither offered nor served a dmabuf destination" {
    const allocator = testing.allocator;
    var ts = try TestServer.initAtVersion(allocator, 1);
    defer ts.deinit();
    ts.enableDmabufDestination();

    const frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var events: FrameEvents = .{};
    frame.setListener(*FrameEvents, FrameEvents.listener, &events);
    try ts.pump();
    // The shm buffer type is since 1 and is always sent; buffer_done
    // and linux_dmabuf are since 3, so a v1 client is told neither.
    try testing.expectEqual(@as(usize, 1), events.buffer_count);
    try testing.expectEqual(@as(usize, 0), events.linux_dmabuf_count);
    try testing.expectEqual(@as(usize, 0), events.buffer_done_count);

    // A dmabuf buffer is then one this frame does not accept: the same
    // invalid_buffer any buffer nobody owns gets, and the client is
    // gone (the same shape as the padded-stride test). The error must
    // name the FRAME (its object id, code 1) and not the buffer: the
    // frame is what refuses it, and an error on the buffer would mean
    // this compositor failing to resolve a buffer it owns.
    const buffer = try ts.createDmabufBuffer(64, 64, dmabuf_mod.drm_format_argb8888);
    frame.copy(buffer);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(
        @as(c_int, @intCast(@intFromEnum(server.zwlr.ScreencopyFrameV1.Error.invalid_buffer))),
        wl_display_get_protocol_error(ts.c_display.?, null, null),
    );
    var error_id: u32 = 0;
    _ = wl_display_get_protocol_error(ts.c_display.?, null, &error_id);
    try testing.expectEqual(frame.getId(), error_id);
}

test "a capture region outside the output fails the frame at creation" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    fillCapturePattern(ts.fb.?);

    // Four regions a client can put on the wire, none of which lies
    // inside the 64x64 source. The first puts the origin at INT32_MAX,
    // so the far edge is not representable in i32 at all; the second
    // is simply negative; the third and fourth carry an ordinary-looking
    // origin past INT32_MAX on their own. The last one is the sharpest:
    // its extent is a 64x64 the client can really allocate a
    // destination for, so before the fix it passed every check and
    // reached the shared row loop — the one both destinations use — on
    // the next presenting commit.
    const regions = [_]struct { x: i32, y: i32, width: i32, height: i32 }{
        .{ .x = std.math.maxInt(i32), .y = 0, .width = 1, .height = 1 },
        .{ .x = -1, .y = 0, .width = 1, .height = 1 },
        .{ .x = std.math.maxInt(i32) - 7, .y = 0, .width = 16, .height = 1 },
        .{ .x = std.math.maxInt(i32) - 63, .y = 0, .width = 64, .height = 64 },
    };
    for (regions) |region| {
        const frame = try ts.screencopy_mgr.?.captureOutputRegion(
            0,
            ts.wl_output_client.?,
            region.x,
            region.y,
            region.width,
            region.height,
        );
        var events: FrameEvents = .{};
        frame.setListener(*FrameEvents, FrameEvents.listener, &events);
        try ts.pump();
        // failed, and nothing else. No buffer type was advertised, so
        // the client never allocated a destination for a region the
        // compositor will not read, and no copy request can be armed
        // against a frame that is already inert.
        try testing.expectEqual(@as(usize, 1), events.failed_count);
        try testing.expectEqual(@as(usize, 0), events.buffer_count);
        try testing.expectEqual(@as(usize, 0), events.buffer_done_count);
        try testing.expectEqual(@as(usize, 0), events.linux_dmabuf_count);
    }

    // The connection survived all three and the source is intact: the
    // whole output still advertises its buffer and still copies. A
    // server that aborted on any of the three is not running this
    // line, and a client the server had killed cannot send this
    // request.
    const frame = try ts.screencopy_mgr.?.captureOutput(0, ts.wl_output_client.?);
    var events: FrameEvents = .{};
    frame.setListener(*FrameEvents, FrameEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.buffer_count);
    const buffer = try ts.createBuffer();
    frame.copy(buffer);
    try ts.pump();
    try commitOutput(ts);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.ready_count);
    try testing.expectEqual(@as(usize, 0), events.failed_count);
}

test "the region gate compares the far edge in i64" {
    // The client controls the origin AND the extent, and it is their
    // sum that has to be weighed against the source. Every pair here
    // sums past i32, so a gate that did the add in i32 would panic on
    // it in ReleaseSafe — and in ReleaseFast the wrap would read as
    // "inside the framebuffer", letting the copy index out of bounds.
    const big = std.math.maxInt(i32);
    try testing.expect(!regionInBounds(big, 0, 1, 1, 64, 64));
    try testing.expect(!regionInBounds(0, big, 1, 1, 64, 64));
    try testing.expect(!regionInBounds(big - 7, 0, 16, 1, 64, 64));
    try testing.expect(!regionInBounds(big, big, big, big, 64, 64));

    // In range: the whole source, its last pixel, and a region whose
    // far edge lands exactly on the source edge (the gate is <=, so a
    // region that fills the output to the last pixel is served).
    try testing.expect(regionInBounds(0, 0, 64, 64, 64, 64));
    try testing.expect(regionInBounds(63, 63, 1, 1, 64, 64));
    try testing.expect(regionInBounds(0, 0, 32, 32, 64, 64));

    // Out of range for the ordinary reasons as well: a negative
    // origin, a non-positive extent, and a box past either edge.
    try testing.expect(!regionInBounds(-1, 0, 1, 1, 64, 64));
    try testing.expect(!regionInBounds(0, -1, 1, 1, 64, 64));
    try testing.expect(!regionInBounds(0, 0, 0, 1, 64, 64));
    try testing.expect(!regionInBounds(0, 0, 1, 0, 64, 64));
    try testing.expect(!regionInBounds(0, 63, 1, 2, 64, 64));
    try testing.expect(!regionInBounds(0, 0, 65, 1, 64, 64));
}
