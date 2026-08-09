//! Backend abstraction (wlr_backend pattern).
//!
//! A Backend owns display devices (outputs) and input. The compositor
//! attaches a `new_output` listener before starting the backend; outputs
//! announced after start arrive through the signal. Backend teardown emits
//! the `destroy` signal before impl teardown runs.
//!
//! Imports: utils/*, core/wire.zig, output/output.zig (sibling module).

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const output_mod = @import("../output/output.zig");

pub const Backend = struct {
    impl: *const Impl,
    data: *anyopaque,
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,

    events: struct {
        /// A new output became available.
        new_output: wire.Signal(*output_mod.Output),
        /// A new input device became available (wlr_backend new_input).
        /// The libinput backend emits this for each evdev device found
        /// during udev enumeration (libinput.zig); the server subscribes
        /// in main.zig.
        new_input: wire.Signal(*InputDevice),
        /// The backend is being destroyed.
        destroy: wire.Signal(*Backend),
    },

    pub const Impl = struct {
        /// Start the backend (device init, timers, output enumeration).
        start: *const fn (backend: *Backend) error{BackendFailed}!void,
        /// Tear down backend-owned resources (not the Backend struct).
        destroy: *const fn (allocator: std.mem.Allocator, data: *anyopaque) void,
    };

    /// An input device announced by a backend (wlr_input_device pattern).
    /// M3 has no real input backends; the raylib source feeds the seat
    /// directly. The struct carries the device kind and a name for logs.
    pub const InputDevice = struct {
        kind: enum { keyboard, pointer, touch },
        name: [:0]const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        impl: *const Impl,
        data: *anyopaque,
    ) !*Backend {
        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .impl = impl,
            .data = data,
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        self.events.new_output.init();
        self.events.new_input.init();
        self.events.destroy.init();
        return self;
    }

    pub fn start(backend: *Backend) error{BackendFailed}!void {
        try backend.impl.start(backend);
    }

    pub fn destroy(backend: *Backend) void {
        backend.events.destroy.emit(backend);
        backend.impl.destroy(backend.allocator, backend.data);
        const allocator = backend.allocator;
        allocator.destroy(backend);
    }

    /// Announce an output to the compositor.
    pub fn emitNewOutput(backend: *Backend, out: *output_mod.Output) void {
        backend.events.new_output.emit(out);
    }

    /// Announce an input device to the compositor.
    pub fn emitNewInput(backend: *Backend, device: *InputDevice) void {
        backend.events.new_input.emit(device);
    }
};

const FakeImpl = struct {
    starts: usize = 0,
    destroyed: bool = false,

    fn start(backend: *Backend) error{BackendFailed}!void {
        const self: *FakeImpl = @ptrCast(@alignCast(backend.data));
        self.starts += 1;
    }

    fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
        _ = allocator;
        const self: *FakeImpl = @ptrCast(@alignCast(data));
        self.destroyed = true;
    }
};

const fake_impl: Backend.Impl = .{
    .start = FakeImpl.start,
    .destroy = FakeImpl.destroy,
};

const DestroyRecorder = struct {
    destroys: usize = 0,
    listener: wire.Listener(*Backend),

    fn onDestroy(listener: *wire.Listener(*Backend), _: *Backend) void {
        const self: *DestroyRecorder = @fieldParentPtr("listener", listener);
        self.destroys += 1;
    }
};

test "backend lifecycle" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    var fake: FakeImpl = .{};
    const backend = try Backend.init(allocator, &io, &log_cfg, &fake_impl, &fake);

    var rec: DestroyRecorder = .{
        .listener = wire.Listener(*Backend).init(DestroyRecorder.onDestroy),
    };
    backend.events.destroy.add(&rec.listener);

    try backend.start();
    try std.testing.expectEqual(@as(usize, 1), fake.starts);

    backend.destroy();
    try std.testing.expect(fake.destroyed);
    try std.testing.expectEqual(@as(usize, 1), rec.destroys);
}
