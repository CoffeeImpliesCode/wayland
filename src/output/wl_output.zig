//! wl_output protocol global (M3): exposes an Output to clients.
//!
//! One global per Output, created by the compositor when the backend
//! announces an output. On bind the current state is sent (geometry,
//! mode, scale, name, description, done). Output destruction removes the
//! global and frees the module state. Mode/geometry changes are not
//! re-broadcast in M3 (the server runs a single fixed mode).
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, output/output.zig
//! (sibling modules).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const output_mod = @import("output.zig");

const server = @import("protocol").server;

const Output = output_mod.Output;

/// wl_output protocol version this library implements.
pub const output_version: u32 = 4;

pub const WlOutput = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    output: *Output,
    display: *display_mod.CompositorDisplay,
    global: ?*wire.Global = null,
    /// Per-client wl_output resources; also the identity check for
    /// protocols that take a wl_output argument (screencopy).
    resources: std.ArrayList(*server.wl.Output) = .empty,
    destroy_listener: wire.Listener(*Output),
    /// wl_output.name.
    name: [:0]const u8,
    /// wl_output.description.
    description: [:0]const u8,

    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        output: *Output,
        name: [:0]const u8,
        description: [:0]const u8,
    ) error{ OutOfMemory, GlobalCreateFailed }!*WlOutput {
        const self = try allocator.create(WlOutput);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .output = output,
            .display = display,
            .resources = .empty,
            .destroy_listener = wire.Listener(*Output).init(onOutputDestroy),
            .name = name,
            .description = description,
        };
        errdefer self.resources.deinit(allocator);
        self.global = try display.addGlobal(server.wl.Output, *WlOutput, bindOutput, output_version, self);
        output.events.destroy.add(&self.destroy_listener);
        log.debug("wl_output global for {d}x{d}", io, log_cfg, "wl_output", .{
            output.mode.width, output.mode.height,
        });
        return self;
    }

    /// True when `resource` is a wl_output object this compositor created
    /// (used by protocols taking a wl_output argument).
    pub fn owns(self: *WlOutput, resource: *server.wl.Output) bool {
        return std.mem.indexOfScalar(*server.wl.Output, self.resources.items, resource) != null;
    }

    fn sendState(self: *WlOutput, resource: *server.wl.Output) void {
        const out = self.output;
        const version = resource.getVersion();
        // v1 events first; version-gated events follow (a v1 client
        // aborts on any newer opcode).
        resource.sendGeometry(
            0,
            0,
            0,
            0,
            .unknown,
            "wayland",
            "wayland-m2",
            .normal,
        );
        resource.sendMode(
            .{ .current = true, .preferred = true },
            out.mode.width,
            out.mode.height,
            @divTrunc(1_000_000, out.mode.refresh_msec), // mHz
        );
        if (version >= 2) resource.sendScale(1);
        if (version >= 4) resource.sendName(self.name);
        if (version >= 4) resource.sendDescription(self.description);
        if (version >= 2) resource.sendDone();
    }

    fn bindOutput(cli: *wire.Client, wl_output: *WlOutput, version: u32, id: u32) void {
        const resource = server.wl.Output.create(cli, version, id) catch {
            cli.postNoMemory();
            return;
        };
        resource.setHandler(*WlOutput, outputRequest, null, wl_output);
        wl_output.resources.append(wl_output.allocator, resource) catch {
            cli.postNoMemory();
            return;
        };
        wl_output.sendState(resource);
    }

    fn onOutputDestroy(listener: *wire.Listener(*Output), _: *Output) void {
        const self: *WlOutput = @fieldParentPtr("destroy_listener", listener);
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        self.resources.deinit(allocator);
        allocator.destroy(self);
    }
};

fn outputRequest(resource: *server.wl.Output, request: server.wl.Output.Request, _: *WlOutput) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const client = @import("protocol").client;
const backend_mod = @import("../backend/backend.zig");

const posix = std.posix;

const FakeImpl = struct {
    fn testState(_: *output_mod.Output, _: *const output_mod.Output.State) error{InvalidState}!void {}
    fn commit(_: *output_mod.Output, _: *const output_mod.Output.State) error{CommitFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_impl: output_mod.Output.Impl = .{
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

const RegistryCapture = struct {
    output_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_output")) data.output_name = g.name;
            },
            .global_remove => {},
        }
    }
};

const OutputEvents = struct {
    geometry_count: usize = 0,
    mode_count: usize = 0,
    done_count: usize = 0,
    scale_count: usize = 0,
    name_count: usize = 0,
    description_count: usize = 0,
    mode_width: i32 = 0,
    mode_height: i32 = 0,
    scale_factor: i32 = 0,

    fn listener(output: *client.wl.Output, event: client.wl.Output.Event, data: *OutputEvents) void {
        _ = output;
        switch (event) {
            .geometry => data.geometry_count += 1,
            .mode => |m| {
                data.mode_count += 1;
                data.mode_width = m.width;
                data.mode_height = m.height;
            },
            .done => data.done_count += 1,
            .scale => |s| {
                data.scale_count += 1;
                data.scale_factor = s.factor;
            },
            .name => data.name_count += 1,
            .description => data.description_count += 1,
        }
    }
};

/// A minimal compositor + wl_output global + in-memory client, for wire
/// roundtrips. Unlike the shell harnesses, init does NOT pump after binding
/// wl_output: the bind-time state send (sendState) is exactly what the
/// legacy-version test asserts on, so it must sit in the socket until the
/// test attaches its listener and pumps.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    backend: ?*backend_mod.Backend = null,
    output: ?*output_mod.Output = null,
    wl_output: ?*WlOutput = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_output_proxy: ?*client.wl.Output = null,

    fn init(allocator: std.mem.Allocator, bind_version: u32) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        ts.backend = try backend_mod.Backend.init(allocator, &ts.io, &ts.log_cfg, &fake_backend_impl, undefined);
        errdefer if (ts.backend) |b| b.destroy();
        const out = try output_mod.Output.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.backend.?,
            &fake_impl,
            undefined,
            .{ .width = 1920, .height = 1080, .refresh_msec = 16 },
        );
        ts.output = out;
        errdefer if (ts.output) |o| o.destroy();
        // The wl_output global is freed by onOutputDestroy when the output
        // is destroyed; no separate teardown.
        ts.wl_output = try WlOutput.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            out,
            "WL-1",
            "wayland debug output",
        );

        // In-memory client connection: one socketpair end for the server, the
        // other for the client library.
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        // Round 1: registry + global announcement.
        const registry = try ts.c_display.?.getRegistry();
        var capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
        try ts.pump();
        if (capture.output_name == null) return error.GlobalMissing;

        // Round 2: bind wl_output at the requested (legacy) version. No pump:
        // the bind response events must reach the test's listener.
        ts.wl_output_proxy = try registry.bind(capture.output_name.?, client.wl.Output, bind_version);
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        // Output.destroy emits the destroy signal, which frees the WlOutput.
        if (ts.output) |o| o.destroy();
        if (ts.backend) |b| b.destroy();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Client flush -> server event loop dispatch -> server flush -> client
    /// dispatch. Drives one roundtrip without blocking.
    fn pump(ts: *TestServer) !void {
        if (ts.c_display.?.flush() != .SUCCESS) return error.ClientFlushFailed;
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                ts.client = null;
                return error.ClientDispatchFailed;
            }
        }
    }
};

test "wl_output v2 client receives geometry/mode/scale/done but never name/description" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, 2);
    defer ts.deinit();

    // The client bound wl_output at v2.
    try std.testing.expectEqual(@as(u32, 2), ts.wl_output_proxy.?.getVersion());

    var events: OutputEvents = .{};
    ts.wl_output_proxy.?.setListener(*OutputEvents, OutputEvents.listener, &events);
    // First pump delivers the bind-time state send (sendState): the request
    // from round 2 was still in the client's outbound buffer.
    try ts.pump();

    // v1 events: geometry and mode.
    try std.testing.expectEqual(@as(usize, 1), events.geometry_count);
    try std.testing.expectEqual(@as(usize, 1), events.mode_count);
    try std.testing.expectEqual(@as(i32, 1920), events.mode_width);
    try std.testing.expectEqual(@as(i32, 1080), events.mode_height);
    // v2 events: scale and done.
    try std.testing.expectEqual(@as(usize, 1), events.scale_count);
    try std.testing.expectEqual(@as(i32, 1), events.scale_factor);
    try std.testing.expectEqual(@as(usize, 1), events.done_count);
    // name/description are since 4 (wayland.xml wl_output events): a v2
    // client must never receive them (sendState gates at version >= 4).
    try std.testing.expectEqual(@as(usize, 0), events.name_count);
    try std.testing.expectEqual(@as(usize, 0), events.description_count);

    // Another pump sends nothing more: the state was a one-shot at bind.
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), events.geometry_count);
    try std.testing.expectEqual(@as(usize, 1), events.done_count);
    try std.testing.expectEqual(@as(usize, 0), events.name_count);
    try std.testing.expectEqual(@as(usize, 0), events.description_count);
}
