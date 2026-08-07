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
    out: *output.Output,
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
        errdefer allocator.destroy(headless);
        headless.* = .{
            .loop = loop,
            .timer = null,
            .out = undefined,
            .mode = mode,
        };

        const base = try backend.Backend.init(allocator, io, log_cfg, &backend_impl, headless);
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
    base.emitNewOutput(headless.out);
}

fn destroy(base: *backend.Backend) void {
    const headless: *Headless = @ptrCast(@alignCast(base.data));
    // Stop the timer first so no callback can run against a torn-down output.
    if (headless.timer) |timer| timer.remove();
    headless.out.destroy();
    base.allocator.destroy(headless);
}

fn frameCb(headless: *Headless) c_int {
    headless.out.sendFrame();
    // libwayland does not re-arm timer sources after they fire; re-arm for
    // the next period. On failure, drop the source (return 0).
    headless.timer.?.timerUpdate(headless.mode.refresh_msec) catch return 0;
    return 1;
}

fn testState(_: *output.Output, _: *const output.Output.State) error{InvalidState}!void {}

fn commit(out: *output.Output, state: *const output.Output.State) error{CommitFailed}!void {
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
            return;
        }
    }
    log_mod.info("commit: bits=0x{x} enabled={} scale={d} damage_rects={d}", out.io, out.log_cfg, "headless", .{
        state.committed, state.enabled, state.scale, state.damage.rects.items.len,
    });
}

fn destroyOutput(_: *output.Output) void {}

const FrameRecorder = struct {
    frames: usize = 0,
    out: ?*output.Output = null,
    listener: wire.Listener(*output.Output) = undefined,
    frame_listener: wire.Listener(*output.Output) = undefined,

    fn onNewOutput(listener: *wire.Listener(*output.Output), out: *output.Output) void {
        const self: *FrameRecorder = @fieldParentPtr("listener", listener);
        self.out = out;
    }

    fn onFrame(listener: *wire.Listener(*output.Output), _: *output.Output) void {
        const self: *FrameRecorder = @fieldParentPtr("frame_listener", listener);
        self.frames += 1;
    }

    fn init(self: *FrameRecorder) void {
        self.listener = wire.Listener(*output.Output).init(onNewOutput);
        self.frame_listener = wire.Listener(*output.Output).init(onFrame);
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

    var rec: FrameRecorder = .{};
    rec.init();
    base.events.new_output.add(&rec.listener);

    try base.start();
    try std.testing.expect(rec.out != null);

    const out = rec.out.?;
    try std.testing.expectEqual(mode.width, out.width);
    try std.testing.expectEqual(mode.height, out.height);
    out.events.frame.add(&rec.frame_listener);

    // One dispatch with a short timeout: the timer fires and the frame
    // signal is emitted synchronously.
    try loop.dispatch(100);
    try std.testing.expectEqual(@as(usize, 1), rec.frames);
    try loop.dispatch(100);
    try std.testing.expectEqual(@as(usize, 2), rec.frames);
}
