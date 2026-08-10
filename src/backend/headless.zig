//! Headless backend: one virtual output paced by an EventLoop timer.
//!
//! The first backend implementation; also the test backend. No DRM, no
//! sockets — frames are driven purely by `mode.refresh_msec` timer events.
//! The output is created eagerly but announced (`new_output`) when the
//! backend starts, so the compositor can attach its listener first.
//!
//! Imports: utils/*, core/wire.zig, backend/backend.zig, output/output.zig.

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const backend = @import("backend.zig");
const output = @import("../output/output.zig");

const Headless = struct {
    loop: *wire.EventLoop,
    timer: ?*wire.EventSource,
    /// Null until create() succeeds: the impl destroy runs from an
    /// errdefer on a failed create() too, and must not deref a wrapper
    /// that was never created.
    out: ?*output.Output,
    mode: output.Mode,
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

pub const HeadlessBackend = struct {
    /// Create a backend with a single headless output running at `mode`.
    /// The output's frame signal fires every `mode.refresh_msec` once the
    /// backend is started; `new_output` fires on start as well.
    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        loop: *wire.EventLoop,
        mode: output.Mode,
    ) !*backend.Backend {
        std.debug.assert(mode.width > 0);
        std.debug.assert(mode.height > 0);
        std.debug.assert(mode.refresh_msec > 0);

        const headless = try allocator.create(Headless);
        headless.* = .{
            .loop = loop,
            .timer = null,
            // SAFETY: assigned via `headless.out = out` right after output
            // creation; null until then (the impl destroy guards it).
            .out = null,
            .mode = mode,
        };

        // Backend.init does not take ownership of headless on failure, so
        // free it here; every failure path then frees headless exactly
        // once. After init succeeds, the backend impl destroy owns it.
        const base = backend.Backend.init(allocator, io, log_cfg, &backend_impl, headless) catch |err| {
            allocator.destroy(headless);
            return err;
        };
        errdefer base.destroy();

        const out = try output.Output.create(allocator, io, log_cfg, base, &output_impl, headless, mode);
        headless.out = out;
        return base;
    }
};

fn start(base: *backend.Backend) error{BackendFailed}!void {
    const headless: *Headless = @ptrCast(@alignCast(base.data));
    std.debug.assert(headless.timer == null);

    const timer = headless.loop.addTimer(*Headless, frameCb, headless) catch return error.BackendFailed;
    errdefer timer.remove();
    timer.timerUpdate(headless.mode.refresh_msec) catch return error.BackendFailed;
    headless.timer = timer;

    log_mod.info("started {d}x{d} @ {d}ms", base.io, base.log_cfg, "headless", .{
        headless.mode.width, headless.mode.height, headless.mode.refresh_msec,
    });
    base.emitNewOutput(headless.out.?);
}

fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const headless: *Headless = @ptrCast(@alignCast(data));
    // Stop the timer first so no callback can run against a torn-down output.
    if (headless.timer) |timer| timer.remove();
    // The output wrapper may never have been created when destroy runs
    // from a failed create() errdefer (headless.out is null then).
    if (headless.out) |out| out.destroy();
    allocator.destroy(headless);
}

fn frameCb(headless: *Headless) c_int {
    headless.out.?.sendFrame();
    // libwayland does not re-arm timer sources after they fire; re-arm for
    // the next period. On failure, drop the source (return 0).
    headless.timer.?.timerUpdate(headless.mode.refresh_msec) catch return 0;
    return 1;
}

/// What the headless backend can apply: enable/mode/buffer. Scale and
/// transform are rejected — the output draws its framebuffer 1:1, so a
/// scale/transform commit would mutate output.width/height with no
/// backend effect (wlroots SUPPORTED_OUTPUT_STATE, headless/output.c:10-14).
fn testState(_: *output.Output, state: *const output.Output.State) error{InvalidState}!void {
    const supported = output.Output.State.committed_enabled |
        output.Output.State.committed_mode |
        output.Output.State.committed_buffer;
    if (state.committed & ~supported != 0) return error.InvalidState;
}

fn commit(out: *output.Output, state: *const output.Output.State) error{CommitFailed}!void {
    const self: *Headless = @ptrCast(@alignCast(out.data));
    if (state.committed & output.Output.State.committed_mode != 0) {
        if (state.mode) |m| {
            log_mod.info(
                "commit: bits=0x{x} enabled={} scale={d} mode={d}x{d}@{d}ms damage_rects={d}",
                out.io,
                out.log_cfg,
                "headless",
                .{
                    state.committed,
                    state.enabled,
                    state.scale,
                    m.width,
                    m.height,
                    m.refresh_msec,
                    state.damage.rects.items.len,
                },
            );
            // Apply the committed mode to the frame pacing: the timer
            // must run at the new mode's refresh, not the START mode's
            // (wlroots headless/output.c:56-78 output_commit updates
            // frame_delay from custom_mode.refresh and re-arms the
            // timer). The Output wrapper applies the mode/size fields in
            // commitState; this backend copy drives frameCb.
            self.mode = m;
            if (self.timer) |timer| {
                timer.timerUpdate(m.refresh_msec) catch return error.CommitFailed;
            }
            return;
        }
    }
    log_mod.info("commit: bits=0x{x} enabled={} scale={d} damage_rects={d}", out.io, out.log_cfg, "headless", .{
        state.committed, state.enabled, state.scale, state.damage.rects.items.len,
    });
}

fn destroyOutput(_: std.mem.Allocator, _: *anyopaque) void {}

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

test "headless backend paces frames on the event loop" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    const loop = try wire.EventLoop.create();
    defer loop.destroy();

    const mode: output.Mode = .{ .width = 320, .height = 240, .refresh_msec = 10 };
    const base = try HeadlessBackend.create(allocator, &io, &log_cfg, loop, mode);
    defer base.destroy();

    var rec: FrameRecorder = .{
        .listener = wire.Listener(*output.Output).init(FrameRecorder.onNewOutput),
        .frame_listener = wire.Listener(*output.Output).init(FrameRecorder.onFrame),
    };
    base.events.new_output.add(&rec.listener);

    try base.start();
    try std.testing.expect(rec.out != null);

    const out = rec.out.?;
    try std.testing.expectEqual(mode.width, out.width);
    try std.testing.expectEqual(mode.height, out.height);
    out.events.frame.add(&rec.frame_listener);

    // sendFrame gates the emit on enabled (wlroots output.c:833-837):
    // enable the output the way the compositor does, then the timer paces
    // frame signals.
    var enable = output.Output.State.init(allocator);
    defer enable.deinit();
    enable.committed = output.Output.State.committed_enabled |
        output.Output.State.committed_mode;
    enable.enabled = true;
    enable.mode = mode;
    try out.commitState(&enable);

    // One dispatch with a short timeout: the timer fires and the frame
    // signal is emitted synchronously.
    try loop.dispatch(100);
    try std.testing.expectEqual(@as(usize, 1), rec.frames);
    try loop.dispatch(100);
    try std.testing.expectEqual(@as(usize, 2), rec.frames);
}

test "headless commit applies a committed mode to the frame pacing" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    const loop = try wire.EventLoop.create();
    defer loop.destroy();

    const mode: output.Mode = .{ .width = 320, .height = 240, .refresh_msec = 10 };
    const base = try HeadlessBackend.create(allocator, &io, &log_cfg, loop, mode);
    defer base.destroy();

    var rec: FrameRecorder = .{
        .listener = wire.Listener(*output.Output).init(FrameRecorder.onNewOutput),
        .frame_listener = wire.Listener(*output.Output).init(FrameRecorder.onFrame),
    };
    base.events.new_output.add(&rec.listener);

    try base.start();
    const out = rec.out.?;
    out.events.frame.add(&rec.frame_listener);

    // Enable the output first: sendFrame gates the emit on enabled
    // (wlroots output.c:833-837), so a never-enabled output stays silent.
    var enable = output.Output.State.init(allocator);
    defer enable.deinit();
    enable.committed = output.Output.State.committed_enabled |
        output.Output.State.committed_mode;
    enable.enabled = true;
    enable.mode = mode;
    try out.commitState(&enable);

    // Commit a new mode: the backend must adopt it for pacing (the frame
    // timer's period follows mode.refresh_msec), and the Output wrapper
    // applies the new size in commitState.
    var state = output.Output.State.init(allocator);
    defer state.deinit();
    state.committed = output.Output.State.committed_mode;
    state.mode = .{ .width = 640, .height = 480, .refresh_msec = 1 };
    try out.commitState(&state);

    try std.testing.expectEqual(@as(i32, 640), out.width);
    try std.testing.expectEqual(@as(i32, 480), out.height);
    try std.testing.expectEqual(@as(i32, 1), out.mode.refresh_msec);

    // The backend copy that drives the frame timer must reflect the new
    // refresh (this is the pacing source frameCb re-arms with).
    const headless: *Headless = @ptrCast(@alignCast(base.data));
    try std.testing.expectEqual(@as(i32, 640), headless.mode.width);
    try std.testing.expectEqual(@as(i32, 480), headless.mode.height);
    try std.testing.expectEqual(@as(i32, 1), headless.mode.refresh_msec);

    // The re-armed timer still produces frames at the new (faster) rate.
    try loop.dispatch(100);
    try std.testing.expect(rec.frames > 0);
}
