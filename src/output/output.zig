//! Output abstraction (wlr_output pattern).
//!
//! An Output is a display device owned by a backend. State changes are
//! atomic: callers build an `Output.State`, then `commitState` runs the
//! backend's `test` (validation) and `commit` (backend apply) hooks before
//! the new state becomes current and the `commit` signal fires. The backend
//! drives `frame` signals when a new frame can be rendered.
//!
//! Imports: utils/*, core/wire.zig, backend/backend.zig (sibling module).

const std = @import("std");
const geom = @import("../utils/geom.zig");
const damage_mod = @import("../utils/damage.zig");
const log_mod = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const backend_mod = @import("../backend/backend.zig");

/// A video mode an output can run at.
pub const Mode = struct {
    width: i32,
    height: i32,
    /// Frame interval in milliseconds.
    refresh_msec: i32,
};

pub const Output = struct {
    /// Mode currently active on this output.
    mode: Mode,
    /// Scale factor applied to client content.
    scale: f32,
    transform: geom.Transform,
    enabled: bool,
    /// Current framebuffer size in pixels (mode size after transform).
    width: i32,
    height: i32,

    impl: *const Impl,
    data: *anyopaque,
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    backend: *backend_mod.Backend,

    events: struct {
        /// The backend is ready for the next frame.
        frame: wire.Signal(*Output),
        /// A committed state has been applied.
        commit: wire.Signal(*Output),
        /// The output is being destroyed.
        destroy: wire.Signal(*Output),
    },

    /// A pending output state update. Fields are only meaningful when their
    /// bit is set in `committed`; `damage` rides along for the impl to
    /// consume during commit.
    pub const State = struct {
        pub const committed_enabled: u32 = 1 << 0;
        pub const committed_scale: u32 = 1 << 1;
        pub const committed_transform: u32 = 1 << 2;
        pub const committed_mode: u32 = 1 << 3;
        pub const committed_buffer: u32 = 1 << 4;

        /// Bitfield of which fields are part of this state update.
        committed: u32 = 0,
        enabled: bool = false,
        scale: f32 = 1.0,
        transform: geom.Transform = .normal,
        mode: ?Mode = null,
        /// Renderer framebuffer handle for the next present; ownership
        /// passes to the impl during commit.
        buffer: ?*anyopaque = null,
        /// Damage attached to this state update (read by the impl).
        damage: damage_mod.Damage,

        pub fn init(allocator: std.mem.Allocator) Output.State {
            return .{ .damage = damage_mod.Damage.init(allocator) };
        }

        pub fn deinit(state: *State) void {
            state.damage.deinit();
            state.* = undefined;
        }
    };

    pub const Impl = struct {
        /// Validate a prospective state; reject with error.InvalidState.
        @"test": *const fn (output: *Output, state: *const State) error{InvalidState}!void,
        /// Apply a validated state at the backend level.
        commit: *const fn (output: *Output, state: *const State) error{CommitFailed}!void,
        /// Tear down backend resources owned by this output.
        destroy: *const fn (allocator: std.mem.Allocator, data: *anyopaque) void,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        backend: *backend_mod.Backend,
        impl: *const Impl,
        data: *anyopaque,
        mode: Mode,
    ) !*Output {
        std.debug.assert(mode.width > 0);
        std.debug.assert(mode.height > 0);
        std.debug.assert(mode.refresh_msec > 0);

        const self = try allocator.create(Output);
        errdefer allocator.destroy(self);
        self.* = .{
            .mode = mode,
            .scale = 1.0,
            .transform = .normal,
            .enabled = false,
            .width = mode.width,
            .height = mode.height,
            .impl = impl,
            .data = data,
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .backend = backend,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        self.events.frame.init();
        self.events.commit.init();
        self.events.destroy.init();
        return self;
    }

    pub fn destroy(output: *Output) void {
        output.events.destroy.emit(output);
        output.impl.destroy(output.allocator, output.data);
        const allocator = output.allocator;
        allocator.destroy(output);
    }

    /// Validate, commit, then apply a state update atomically. On error
    /// nothing is applied and no commit signal fires.
    pub fn commitState(output: *Output, state: *Output.State) error{ InvalidState, CommitFailed }!void {
        try output.impl.@"test"(output, state);
        try output.impl.commit(output, state);

        if (state.committed & State.committed_enabled != 0) output.enabled = state.enabled;
        if (state.committed & State.committed_scale != 0) output.scale = state.scale;
        if (state.committed & State.committed_transform != 0) {
            output.transform = state.transform;
            updateSize(output);
        }
        if (state.committed & State.committed_mode != 0) {
            if (state.mode) |m| {
                output.mode = m;
                updateSize(output);
            }
        }
        // State.committed_buffer: the handle was handed to impl.commit; Output
        // keeps no current-buffer slot in M1.
        output.events.commit.emit(output);
    }

    /// The backend is ready for the next frame.
    pub fn sendFrame(output: *Output) void {
        output.events.frame.emit(output);
    }
};

fn updateSize(output: *Output) void {
    const size = output.transform.transformedSize(output.mode.width, output.mode.height);
    output.width = size.w;
    output.height = size.h;
}

const FakeImpl = struct {
    reject: bool = false,
    fail_commit: bool = false,
    tests: usize = 0,
    commits: usize = 0,
    destroyed: bool = false,
    last_committed: u32 = 0,
    last_enabled: bool = false,
    last_scale: f32 = 0,
    last_mode: ?Mode = null,

    fn testState(out: *Output, _: *const Output.State) error{InvalidState}!void {
        const self: *FakeImpl = @ptrCast(@alignCast(out.data));
        self.tests += 1;
        if (self.reject) return error.InvalidState;
    }

    fn commit(out: *Output, state: *const Output.State) error{CommitFailed}!void {
        const self: *FakeImpl = @ptrCast(@alignCast(out.data));
        self.commits += 1;
        self.last_committed = state.committed;
        self.last_enabled = state.enabled;
        self.last_scale = state.scale;
        self.last_mode = state.mode;
        if (self.fail_commit) return error.CommitFailed;
    }

    fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
        _ = allocator;
        const self: *FakeImpl = @ptrCast(@alignCast(data));
        self.destroyed = true;
    }
};

const fake_impl: Output.Impl = .{
    .@"test" = FakeImpl.testState,
    .commit = FakeImpl.commit,
    .destroy = FakeImpl.destroy,
};

const FakeBackendImpl = struct {
    fn start(_: *backend_mod.Backend) error{BackendFailed}!void {}

    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_backend_impl: backend_mod.Backend.Impl = .{
    .start = FakeBackendImpl.start,
    .destroy = FakeBackendImpl.destroy,
};

const SignalRecorder = struct {
    commits: usize = 0,
    frames: usize = 0,
    destroys: usize = 0,
    commit_listener: wire.Listener(*Output),
    frame_listener: wire.Listener(*Output),
    destroy_listener: wire.Listener(*Output),

    fn onCommit(listener: *wire.Listener(*Output), _: *Output) void {
        const self: *SignalRecorder = @fieldParentPtr("commit_listener", listener);
        self.commits += 1;
    }

    fn onFrame(listener: *wire.Listener(*Output), _: *Output) void {
        const self: *SignalRecorder = @fieldParentPtr("frame_listener", listener);
        self.frames += 1;
    }

    fn onDestroy(listener: *wire.Listener(*Output), _: *Output) void {
        const self: *SignalRecorder = @fieldParentPtr("destroy_listener", listener);
        self.destroys += 1;
    }
};

fn makeOutput(
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    fake: *FakeImpl,
) !struct { *Output, *backend_mod.Backend } {
    const backend = try backend_mod.Backend.init(allocator, io, log_cfg, &fake_backend_impl, fake);
    errdefer backend.destroy();
    const mode: Mode = .{ .width = 1920, .height = 1080, .refresh_msec = 16 };
    const out = try Output.create(allocator, io, log_cfg, backend, &fake_impl, fake, mode);
    return .{ out, backend };
}

test "state apply and signals" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{};
    const created = try makeOutput(allocator, &io, &log_cfg, &fake);
    const out = created[0];
    const backend = created[1];
    defer backend.destroy();

    var rec: SignalRecorder = .{
        .commit_listener = wire.Listener(*Output).init(SignalRecorder.onCommit),
        .frame_listener = wire.Listener(*Output).init(SignalRecorder.onFrame),
        .destroy_listener = wire.Listener(*Output).init(SignalRecorder.onDestroy),
    };
    out.events.commit.add(&rec.commit_listener);
    out.events.frame.add(&rec.frame_listener);
    out.events.destroy.add(&rec.destroy_listener);

    // Initial state: mode size, disabled.
    try std.testing.expectEqual(@as(i32, 1920), out.width);
    try std.testing.expectEqual(@as(i32, 1080), out.height);
    try std.testing.expect(!out.enabled);

    // Commit enabled + scale + transform + mode in one atomic update.
    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_enabled | Output.State.committed_scale |
        Output.State.committed_transform | Output.State.committed_mode;
    state.enabled = true;
    state.scale = 2.0;
    state.transform = .@"90";
    state.mode = Mode{ .width = 800, .height = 600, .refresh_msec = 8 };

    try out.commitState(&state);

    try std.testing.expect(out.enabled);
    try std.testing.expectEqual(@as(f32, 2.0), out.scale);
    try std.testing.expectEqual(geom.Transform.@"90", out.transform);
    try std.testing.expectEqual(@as(i32, 800), out.mode.width);
    try std.testing.expectEqual(@as(i32, 600), out.mode.height);
    // 90° transform swaps the mode size.
    try std.testing.expectEqual(@as(i32, 600), out.width);
    try std.testing.expectEqual(@as(i32, 800), out.height);

    // The impl saw the full state, and the commit signal fired exactly once.
    try std.testing.expectEqual(@as(usize, 1), fake.tests);
    try std.testing.expectEqual(@as(usize, 1), fake.commits);
    try std.testing.expectEqual(state.committed, fake.last_committed);
    try std.testing.expect(fake.last_enabled);
    try std.testing.expectEqual(@as(usize, 1), rec.commits);
    try std.testing.expectEqual(@as(usize, 0), rec.frames);

    // Mode-only commit updates mode and size without touching the others.
    var state2 = Output.State.init(allocator);
    defer state2.deinit();
    state2.committed = Output.State.committed_mode;
    state2.mode = Mode{ .width = 1024, .height = 768, .refresh_msec = 10 };
    try out.commitState(&state2);
    try std.testing.expectEqual(@as(i32, 768), out.width);
    try std.testing.expectEqual(@as(i32, 1024), out.height);
    try std.testing.expect(out.enabled); // unchanged
    try std.testing.expectEqual(@as(usize, 2), rec.commits);

    // Frame signal.
    out.sendFrame();
    try std.testing.expectEqual(@as(usize, 1), rec.frames);

    // Destroy: impl destroy runs and the destroy signal fires.
    out.destroy();
    try std.testing.expect(fake.destroyed);
    try std.testing.expectEqual(@as(usize, 1), rec.destroys);
}

test "rejected state is not applied" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{ .reject = true };
    const created = try makeOutput(allocator, &io, &log_cfg, &fake);
    const out = created[0];
    defer created[1].destroy();

    var rec: SignalRecorder = .{
        .commit_listener = wire.Listener(*Output).init(SignalRecorder.onCommit),
        .frame_listener = wire.Listener(*Output).init(SignalRecorder.onFrame),
        .destroy_listener = wire.Listener(*Output).init(SignalRecorder.onDestroy),
    };
    out.events.commit.add(&rec.commit_listener);

    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_enabled;
    state.enabled = true;

    try std.testing.expectError(error.InvalidState, out.commitState(&state));
    try std.testing.expect(!out.enabled); // nothing applied
    try std.testing.expectEqual(@as(usize, 0), fake.commits);
    try std.testing.expectEqual(@as(usize, 0), rec.commits); // no commit signal

    out.destroy();
}

test "failed commit is not applied" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{ .fail_commit = true };
    const created = try makeOutput(allocator, &io, &log_cfg, &fake);
    const out = created[0];
    defer created[1].destroy();

    var rec: SignalRecorder = .{
        .commit_listener = wire.Listener(*Output).init(SignalRecorder.onCommit),
        .frame_listener = wire.Listener(*Output).init(SignalRecorder.onFrame),
        .destroy_listener = wire.Listener(*Output).init(SignalRecorder.onDestroy),
    };
    out.events.commit.add(&rec.commit_listener);

    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_mode;
    state.mode = Mode{ .width = 640, .height = 480, .refresh_msec = 12 };

    try std.testing.expectError(error.CommitFailed, out.commitState(&state));
    try std.testing.expectEqual(@as(i32, 1920), out.width); // unchanged
    try std.testing.expectEqual(@as(usize, 1), fake.commits); // impl ran
    try std.testing.expectEqual(@as(usize, 0), rec.commits); // no commit signal

    out.destroy();
}
