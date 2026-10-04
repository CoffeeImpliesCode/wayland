//! Output abstraction (wlr_output pattern).
//!
//! An Output is a display device owned by a backend. State changes are
//! atomic: callers build an `Output.State`, then `commitState` runs the
//! backend's `test` (validation) and `commit` (backend apply) hooks before
//! the new state becomes current and the `commit` signal fires. The backend
//! drives `frame` signals when a new frame can be rendered.
//!
//! Teardown runs in two phases. `destroy` belongs to the CONSUMERS: every
//! listener must still find the output, its globals and its clients' live
//! wire objects intact, because that is exactly when a real
//! wl_surface.leave, a discarded presentation feedback or a screencopy
//! frame error has to be delivered. `finalize` fires next — after every
//! destroy listener has run, before the impl hook and before the Output is
//! freed — and belongs to OWNERS of state hanging off the output (the
//! wl_output global): they hand their wire objects back to their clients
//! and let go of the output here.
//!
//! Imports: utils/*, core/wire.zig, backend/backend.zig (sibling module).

const std = @import("std");
const geom = @import("../utils/geom.zig");
const damage_mod = @import("../utils/damage.zig");
const log_mod = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const backend_mod = @import("../backend/backend.zig");
const pixman = @import("../renderer/pixman.zig");
const gpu_frame = @import("gpu_frame.zig");

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
    /// True while a committed frame is awaiting its frame event (wlroots
    /// frame_pending, output.c:771-780). Set by commitState on an enabled
    /// buffer commit; cleared by sendFrame. Callers check it before
    /// starting a new frame so two frames are never in flight.
    frame_pending: bool = false,
    /// Per-output commit sequence number: incremented on every enabled
    /// buffer commit. It identifies the committed frame: the presented
    /// event carries the seq of the frame the backend displayed, and
    /// presentation feedback matches its queued commit seq against it
    /// (wlroots wlr_output.commit_seq + presentation_time.c:277-301).
    commit_seq: u64 = 0,
    /// True when the backend fires `presented` on real display
    /// completion (DRM page-flip completion, nested-wayland parent frame
    /// callback). Headless/raylib have no display to observe and keep
    /// this false: the compositor synthesizes presents for them.
    emits_present: bool = false,

    impl: *const Impl,
    data: *anyopaque,
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    backend: *backend_mod.Backend,

    events: struct {
        /// The backend is ready for the next frame.
        frame: wire.Signal(*Output),
        /// A committed state has been applied (payload: CommitEvent).
        commit: wire.Signal(*CommitEvent),
        /// The backend actually displayed a committed frame (payload:
        /// PresentEvent). Only fired by backends with a real display to
        /// observe (DRM flip completion, nested-wayland parent frame
        /// callback); headless/raylib never fire it — the compositor
        /// synthesizes presents for them instead.
        presented: wire.Signal(*PresentEvent),
        ///
        /// The output is being destroyed: consumers only. Every listener
        /// still sees a fully valid Output and the live wire objects its
        /// clients hold, so this is where teardown work that reaches a
        /// client must happen.
        destroy: wire.Signal(*Output),
        /// The output died and every destroy listener has run: ownership
        /// finalizers only. State that outlives the Output (the
        /// wl_output global and the client resources it owns) is handed
        /// back to its clients and released here, while `*Output` is still
        /// readable. Fires before impl.destroy and before the Output's own
        /// memory is freed.
        finalize: wire.Signal(*Output),
    },

    /// Payload of the commit signal: what was applied and when.
    pub const CommitEvent = struct {
        output: *Output,
        /// The applied state (unchanged fields stripped). Valid only for
        /// the duration of the emit — it points at a stack copy inside
        /// commitState; listeners must not retain it.
        state: *const State,
        /// Monotonic commit timestamp (ns), for present/ready events.
        when_ns: u64,
    };

    /// Payload of the presented signal: the frame the backend displayed
    /// and when (wlroots wlr_output_event_present). The backend fires it
    /// at scanout/flip completion — the actual present, not the commit.
    pub const PresentEvent = struct {
        output: *Output,
        /// The output's commit sequence number of the displayed frame
        /// (the seq that was committed when the backend bound the frame
        /// to the flip/scanout).
        seq: u64,
        /// Presentation flags (wp_presentation_feedback.presented kind
        /// bits: 1=VSYNC, 2=HW_CLOCK, 4=HW_COMPLETION, 8=ZERO_COPY).
        flags: u32,
        /// Actual presented refresh interval (ns).
        refresh_ns: u64,
        /// Backend display/scanout completion timestamp
        /// (CLOCK_MONOTONIC, ns).
        when_ns: u64,
    };

    /// A pending output state update. Fields are only meaningful when their
    /// bit is set in `committed`; `damage` rides along for the impl to
    /// consume during commit.
    pub const State = struct {
        pub const Buffer = union(enum) {
            /// Borrowed host pixels, copied or uploaded synchronously.
            cpu: *pixman.Framebuffer,
            /// Backend-owned slot acquired for this output. Successful
            /// commit consumes the lease; failure requires caller cancellation.
            gpu: *gpu_frame.GpuFrame,
        };

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
        /// The pixels presented by this commit. CPU memory remains borrowed;
        /// a GPU writing lease transfers only after a successful commit.
        buffer: ?Buffer = null,
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
        /// Optional (wlroots output.c:731-734): commitState skips the
        /// probe when no impl is set, or when the state carries no
        /// changed fields.
        @"test": ?*const fn (output: *Output, state: *const State) error{InvalidState}!void,
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
        self.events.presented.init();
        self.events.destroy.init();
        self.events.finalize.init();
        return self;
    }

    /// Destroy the output in two ordered phases: consumers run first
    /// (events.destroy), then ownership finalizers (events.finalize), then
    /// the impl hook, then the Output itself. Frees `output` — a second
    /// destroy is a use-after-free, not a no-op.
    pub fn destroy(output: *Output) void {
        output.events.destroy.emit(output);
        output.events.finalize.emit(output);
        output.impl.destroy(output.allocator, output.data);
        const allocator = output.allocator;
        allocator.destroy(output);
    }

    /// Probe a prospective state without applying it: strip unchanged
    /// fields, then run the impl's test hook (when present). Nothing is
    /// committed and no commit signal fires (wlroots wlr_output_test_state,
    /// output.c:718-745).
    pub fn testState(output: *Output, state: *const State) error{InvalidState}!void {
        var pending = state.*;
        const unchanged = unchangedFields(output, &pending);
        pending.committed &= ~unchanged;
        if (pending.committed == 0) return; // nothing to validate
        if (output.impl.@"test") |t| try t(output, &pending);
    }

    /// Validate, commit, then apply a state update atomically. Fields
    /// whose value already matches the output are stripped first (wlroots
    /// output_compare_state, output.c:535-583) so repeated identical
    /// frames only carry their buffer + damage. On error nothing is
    /// applied and no commit signal fires.
    pub fn commitState(output: *Output, state: *Output.State) error{ InvalidState, CommitFailed }!void {
        var pending = state.*;
        const unchanged = unchangedFields(output, &pending);
        pending.committed &= ~unchanged;

        // The test hook is optional and skipped for an empty state
        // (wlroots output.c:731-734); the backend commit always runs —
        // a buffer may carry new content even when the mode/enabled/etc.
        // fields are unchanged.
        if (output.impl.@"test") |t| {
            if (pending.committed != 0) try t(output, &pending);
        }

        // A buffer commit for an enabled output advances the commit
        // sequence: the seq identifies THIS frame for the presented
        // event. Incremented BEFORE the impl commit so the backend's
        // commit can bind the frame's seq to the flip/scanout it starts
        // (the nested backend captures it with the parent frame callback;
        // the DRM flip handler reads the output's seq at completion).
        // A failed commit leaves a gap in the sequence — harmless, the
        // seq is opaque to clients.
        const new_enabled = if (pending.committed & State.committed_enabled != 0)
            pending.enabled
        else
            output.enabled;
        if (new_enabled and (pending.committed & State.committed_buffer != 0)) {
            output.commit_seq += 1;
        }

        try output.impl.commit(output, &pending);

        // Apply only the changed fields.
        if (pending.committed & State.committed_enabled != 0) output.enabled = pending.enabled;
        if (pending.committed & State.committed_scale != 0) output.scale = pending.scale;
        if (pending.committed & State.committed_transform != 0) {
            output.transform = pending.transform;
            updateSize(output);
        }
        if (pending.committed & State.committed_mode != 0) {
            if (pending.mode) |m| {
                output.mode = m;
                updateSize(output);
            }
        }
        // State.committed_buffer: the handle was handed to impl.commit; Output
        // keeps no current-buffer slot in M1.

        // A presented frame is now in flight: the backend owes a frame
        // event for it, and callers must not start another until then
        // (wlroots output_apply_commit, output.c:771-780). Enable-only
        // commits (setup) do not set the flag — no frame event is owed.
        if (output.enabled and (pending.committed & State.committed_buffer != 0)) {
            output.frame_pending = true;
        }

        const now_ns: u64 = @intCast(std.Io.Clock.now(.awake, output.io.*).nanoseconds);
        var ev: CommitEvent = .{ .output = output, .state = &pending, .when_ns = now_ns };
        output.events.commit.emit(&ev);
    }

    /// The backend is ready for the next frame. Clears the in-flight
    /// guard; the emit itself is gated on the output being enabled
    /// (wlroots wlr_output_send_frame, output.c:833-837).
    pub fn sendFrame(output: *Output) void {
        output.frame_pending = false;
        if (output.enabled) output.events.frame.emit(output);
    }

    /// The backend displayed the committed frame `seq` at `when_ns`:
    /// emit the presented signal. Only real-display backends call this —
    /// DRM fires it from the page-flip completion handler, the
    /// nested-wayland backend from the parent's wl_surface.frame done
    /// (the parent's frame_done IS the display present). The kernel/scanout
    /// time, flags and refresh travel in the payload so presentation
    /// feedback reports the actual display, not the commit (wlroots
    /// wlr_output_send_present, output.c:813-830).
    pub fn firePresented(output: *Output, seq: u64, flags: u32, refresh_ns: u64, when_ns: u64) void {
        var ev: PresentEvent = .{
            .output = output,
            .seq = seq,
            .flags = flags,
            .refresh_ns = refresh_ns,
            .when_ns = when_ns,
        };
        output.events.presented.emit(&ev);
    }
};

/// Mask of committed fields whose value already equals the output's
/// current value (wlroots output_compare_state, output.c:535-583). The
/// buffer and damage are never compared: a repeated frame still carries
/// them.
fn unchangedFields(output: *Output, state: *const Output.State) u32 {
    var fields: u32 = 0;
    if (state.committed & Output.State.committed_mode != 0) {
        if (state.mode) |m| {
            if (m.width == output.mode.width and
                m.height == output.mode.height and
                m.refresh_msec == output.mode.refresh_msec)
            {
                fields |= Output.State.committed_mode;
            }
        }
    }
    if (state.committed & Output.State.committed_enabled != 0 and output.enabled == state.enabled) {
        fields |= Output.State.committed_enabled;
    }
    if (state.committed & Output.State.committed_scale != 0 and output.scale == state.scale) {
        fields |= Output.State.committed_scale;
    }
    if (state.committed & Output.State.committed_transform != 0 and output.transform == state.transform) {
        fields |= Output.State.committed_transform;
    }
    return fields;
}

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
    commit_listener: wire.Listener(*Output.CommitEvent),
    frame_listener: wire.Listener(*Output),
    destroy_listener: wire.Listener(*Output),

    fn onCommit(listener: *wire.Listener(*Output.CommitEvent), _: *Output.CommitEvent) void {
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

const PresentRecorder = struct {
    presents: usize = 0,
    /// Last presented event payload (a plain copy of scalars).
    last: ?Output.PresentEvent = null,
    listener: wire.Listener(*Output.PresentEvent),

    fn onPresented(listener: *wire.Listener(*Output.PresentEvent), ev: *Output.PresentEvent) void {
        const self: *PresentRecorder = @fieldParentPtr("listener", listener);
        self.presents += 1;
        self.last = ev.*;
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
        .commit_listener = wire.Listener(*Output.CommitEvent).init(SignalRecorder.onCommit),
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
    // No buffer was committed: no frame is in flight.
    try std.testing.expect(!out.frame_pending);

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

    // A buffer commit puts a frame in flight; sendFrame clears the guard.
    var state3 = Output.State.init(allocator);
    defer state3.deinit();
    state3.committed = Output.State.committed_buffer;
    const framebuffer = try pixman.Framebuffer.create(allocator, 1, 1);
    defer framebuffer.deinit();
    state3.buffer = .{ .cpu = framebuffer };
    try out.commitState(&state3);
    try std.testing.expect(out.frame_pending);
    out.sendFrame();
    try std.testing.expect(!out.frame_pending);
    try std.testing.expectEqual(@as(usize, 2), rec.frames);

    // Destroy: impl destroy runs and the destroy signal fires.
    out.destroy();
    try std.testing.expect(fake.destroyed);
    try std.testing.expectEqual(@as(usize, 1), rec.destroys);
}

test "frame_pending: no emit while disabled, guard on buffer commits" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{};
    const created = try makeOutput(allocator, &io, &log_cfg, &fake);
    const out = created[0];
    defer created[1].destroy();

    var rec: SignalRecorder = .{
        .commit_listener = wire.Listener(*Output.CommitEvent).init(SignalRecorder.onCommit),
        .frame_listener = wire.Listener(*Output).init(SignalRecorder.onFrame),
        .destroy_listener = wire.Listener(*Output).init(SignalRecorder.onDestroy),
    };
    out.events.frame.add(&rec.frame_listener);

    // The output starts disabled: sendFrame must not emit.
    out.sendFrame();
    try std.testing.expectEqual(@as(usize, 0), rec.frames);
    try std.testing.expect(!out.frame_pending);

    // An enable-only commit (setup) owes no frame event: no guard.
    var enable = Output.State.init(allocator);
    defer enable.deinit();
    enable.committed = Output.State.committed_enabled;
    enable.enabled = true;
    try out.commitState(&enable);
    try std.testing.expect(!out.frame_pending);

    // A buffer commit puts the guard up; sendFrame clears it and emits.
    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_buffer;
    const framebuffer = try pixman.Framebuffer.create(allocator, 1, 1);
    defer framebuffer.deinit();
    state.buffer = .{ .cpu = framebuffer };
    try out.commitState(&state);
    try std.testing.expect(out.frame_pending);
    out.sendFrame();
    try std.testing.expect(!out.frame_pending);
    try std.testing.expectEqual(@as(usize, 1), rec.frames);

    out.destroy();
}

test "unchanged state skips the impl test but still commits" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{};
    const created = try makeOutput(allocator, &io, &log_cfg, &fake);
    const out = created[0];
    defer created[1].destroy();

    var rec: SignalRecorder = .{
        .commit_listener = wire.Listener(*Output.CommitEvent).init(SignalRecorder.onCommit),
        .frame_listener = wire.Listener(*Output).init(SignalRecorder.onFrame),
        .destroy_listener = wire.Listener(*Output).init(SignalRecorder.onDestroy),
    };
    out.events.commit.add(&rec.commit_listener);

    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_enabled;
    state.enabled = true;

    // First commit: enabled actually changes, so the impl test runs.
    try out.commitState(&state);
    try std.testing.expectEqual(@as(usize, 1), fake.tests);
    try std.testing.expectEqual(@as(usize, 1), fake.commits);

    // Identical state again: the enabled field is stripped, the probe is
    // skipped, but the backend commit still runs (a repeated frame may
    // carry new buffer content).
    try out.commitState(&state);
    try std.testing.expectEqual(@as(usize, 1), fake.tests);
    try std.testing.expectEqual(@as(usize, 2), fake.commits);
    try std.testing.expectEqual(@as(usize, 2), rec.commits);
    try std.testing.expect(out.enabled);

    out.destroy();
}

test "test_state probes without committing" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{};
    const created = try makeOutput(allocator, &io, &log_cfg, &fake);
    const out = created[0];
    defer created[1].destroy();

    var rec: SignalRecorder = .{
        .commit_listener = wire.Listener(*Output.CommitEvent).init(SignalRecorder.onCommit),
        .frame_listener = wire.Listener(*Output).init(SignalRecorder.onFrame),
        .destroy_listener = wire.Listener(*Output).init(SignalRecorder.onDestroy),
    };
    out.events.commit.add(&rec.commit_listener);

    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_enabled;
    state.enabled = true;

    try out.testState(&state);
    try std.testing.expectEqual(@as(usize, 1), fake.tests);
    try std.testing.expectEqual(@as(usize, 0), fake.commits);
    try std.testing.expectEqual(@as(usize, 0), rec.commits);
    try std.testing.expect(!out.enabled); // nothing applied

    out.destroy();
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
        .commit_listener = wire.Listener(*Output.CommitEvent).init(SignalRecorder.onCommit),
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

test "commit seq advances per enabled buffer commit" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{};
    const created = try makeOutput(allocator, &io, &log_cfg, &fake);
    const out = created[0];
    defer created[1].destroy();

    // No commits yet: seq 0.
    try std.testing.expectEqual(@as(u64, 0), out.commit_seq);

    // Enable-only commit (setup) owes no frame: no seq advance.
    var enable = Output.State.init(allocator);
    defer enable.deinit();
    enable.committed = Output.State.committed_enabled;
    enable.enabled = true;
    try out.commitState(&enable);
    try std.testing.expectEqual(@as(u64, 0), out.commit_seq);

    // A buffer commit advances the seq — the frame's identity.
    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_buffer;
    const framebuffer = try pixman.Framebuffer.create(allocator, 1, 1);
    defer framebuffer.deinit();
    state.buffer = .{ .cpu = framebuffer };
    try out.commitState(&state);
    try std.testing.expectEqual(@as(u64, 1), out.commit_seq);
    try out.commitState(&state);
    try std.testing.expectEqual(@as(u64, 2), out.commit_seq);

    // Disabled output: a buffer commit (would be) rejected by backends,
    // but the seq gate itself must not advance while disabled.
    var disable = Output.State.init(allocator);
    defer disable.deinit();
    disable.committed = Output.State.committed_enabled;
    disable.enabled = false;
    try out.commitState(&disable);
    try out.commitState(&state);
    try std.testing.expectEqual(@as(u64, 2), out.commit_seq);

    out.destroy();
}

test "backend-fired presented event carries seq flags refresh" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{};
    const created = try makeOutput(allocator, &io, &log_cfg, &fake);
    const out = created[0];
    defer created[1].destroy();

    var rec: PresentRecorder = .{ .listener = wire.Listener(*Output.PresentEvent).init(PresentRecorder.onPresented) };
    out.events.presented.add(&rec.listener);

    // The backend fires presented at scanout completion, after a commit:
    // the event must carry that frame's seq plus the backend's flags,
    // refresh and scanout time.
    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_enabled | Output.State.committed_buffer;
    state.enabled = true;
    const framebuffer = try pixman.Framebuffer.create(allocator, 1, 1);
    defer framebuffer.deinit();
    state.buffer = .{ .cpu = framebuffer };
    try out.commitState(&state);
    try std.testing.expectEqual(@as(u64, 1), out.commit_seq);

    const when_ns: u64 = 1234 * std.time.ns_per_s + 567_000_000;
    out.firePresented(out.commit_seq, 0x1 | 0x2 | 0x4, 8_333_333, when_ns);

    try std.testing.expectEqual(@as(usize, 1), rec.presents);
    const ev = rec.last orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(out, ev.output);
    try std.testing.expectEqual(@as(u64, 1), ev.seq);
    try std.testing.expectEqual(@as(u32, 0x1 | 0x2 | 0x4), ev.flags);
    try std.testing.expectEqual(@as(u64, 8_333_333), ev.refresh_ns);
    try std.testing.expectEqual(when_ns, ev.when_ns);

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
        .commit_listener = wire.Listener(*Output.CommitEvent).init(SignalRecorder.onCommit),
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
