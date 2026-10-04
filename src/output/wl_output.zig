//! wl_output protocol global (M3): exposes an Output to clients.
//!
//! One global per Output, created by the compositor when the backend
//! announces an output. On bind the current state is sent (geometry,
//! mode, scale, name, description, done). Committed mode/scale/transform
//! changes are re-broadcast to every bound resource with a coalesced
//! done (wlroots output_apply_state + schedule_done).
//!
//! Output teardown is two-phased and this module spans both. The destroy
//! phase (Output.events.destroy) only stops the world from hearing about
//! the output again: the global is withdrawn and the coalesced done is
//! dropped, while every bound resource stays LIVE and addressable — that
//! is when the compositor still has to send a real wl_surface.leave
//! naming this output (scene/surface_node.zig sendEnter). Freeing
//! anything here would strand those events. The finalize phase
//! (Output.events.finalize) runs after every consumer listener: it hands
//! each resource back to its client as an inert, release-only object,
//! detaches this module's listeners and frees the module state.
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
    /// protocols that take a wl_output argument (screencopy). A resource
    /// the client destroys is removed here by its own destroy callback,
    /// so a rebroadcast never reaches a freed Resource.
    resources: std.ArrayList(*server.wl.Output) = .empty,
    /// output.events.destroy: the output died. Its consumers still have to
    /// reach their clients through this module, so nothing is freed and no
    /// resource is touched here — see the module doc.
    destroy_listener: wire.Listener(*Output),
    /// output.events.finalize: every destroy listener has run, so the
    /// resources can be handed back to their clients and this module can
    /// be released while the output itself is still readable.
    finalize_listener: wire.Listener(*Output),
    /// Re-broadcast changed state (mode/scale/transform) to every bound
    /// resource and coalesce the trailing done into one idle callback
    /// (wlroots schedule_done, output.c:169-176).
    commit_listener: wire.Listener(*Output.CommitEvent),
    /// The pending coalesced done idle source; null when none scheduled.
    done_source: ?*wire.EventSource = null,
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
            .finalize_listener = wire.Listener(*Output).init(onOutputFinalize),
            .commit_listener = wire.Listener(*Output.CommitEvent).init(onOutputCommit),
            .name = name,
            .description = description,
        };
        errdefer self.resources.deinit(allocator);
        self.global = try display.addGlobal(server.wl.Output, *WlOutput, bindOutput, output_version, self);
        output.events.destroy.add(&self.destroy_listener);
        output.events.finalize.add(&self.finalize_listener);
        output.events.commit.add(&self.commit_listener);
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

    /// Bind-time state dump. Order matches wlroots output_bind
    /// (output.c:100-106): geometry, current mode, scale, name,
    /// description, done.
    fn sendState(self: *WlOutput, resource: *server.wl.Output) void {
        sendGeometry(self, resource);
        sendMode(self, resource);
        sendScale(self, resource);
        sendName(self, resource);
        sendDescription(self, resource);
        sendDone(self, resource);
    }

    /// Physical geometry + transform. This server has no physical size
    /// data, so the mm dims are 0 (wlroots sends real dims when the
    /// backend provides them); the transform is the output's real one,
    /// converted to the wire enum (same values as utils/geom.Transform).
    fn sendGeometry(self: *WlOutput, resource: *server.wl.Output) void {
        resource.sendGeometry(
            0,
            0,
            0,
            0,
            .unknown,
            "wayland",
            "wayland-m2",
            @enumFromInt(@as(c_int, @intCast(@intFromEnum(self.output.transform)))),
        );
    }

    /// The current mode. wlroots sends only the CURRENT flag at bind
    /// (output.c:24-35); the preferred flag is not fabricated.
    fn sendMode(self: *WlOutput, resource: *server.wl.Output) void {
        const out = self.output;
        resource.sendMode(
            .{ .current = true },
            out.mode.width,
            out.mode.height,
            @divTrunc(1_000_000, out.mode.refresh_msec), // mHz
        );
    }

    /// Scale as an integer: ceil(scale), the value clients must draw at
    /// (wlroots send_scale, output.c:37-42). The protocol scale event is
    /// since 2.
    fn sendScale(self: *WlOutput, resource: *server.wl.Output) void {
        if (resource.getVersion() >= 2) {
            resource.sendScale(@intFromFloat(@ceil(self.output.scale)));
        }
    }

    fn sendName(self: *WlOutput, resource: *server.wl.Output) void {
        if (resource.getVersion() >= 4) resource.sendName(self.name);
    }

    fn sendDescription(self: *WlOutput, resource: *server.wl.Output) void {
        if (resource.getVersion() >= 4) resource.sendDescription(self.description);
    }

    fn sendDone(_: *WlOutput, resource: *server.wl.Output) void {
        if (resource.getVersion() >= 2) resource.sendDone();
    }

    /// A committed state changed mode/scale/transform: re-send the
    /// affected events to every bound resource and coalesce the done
    /// (wlroots output_apply_state, output.c:329-339 + schedule_done
    /// output.c:169-176). Unchanged fields are stripped by
    /// Output.commitState, so a bit present here means a real change.
    fn onOutputCommit(listener: *wire.Listener(*Output.CommitEvent), event: *Output.CommitEvent) void {
        const self: *WlOutput = @fieldParentPtr("commit_listener", listener);
        const committed = event.state.committed;
        const mode_updated = committed & Output.State.committed_mode != 0;
        const geometry_updated = mode_updated or (committed & Output.State.committed_transform != 0);
        const scale_updated = committed & Output.State.committed_scale != 0;
        if (!geometry_updated and !scale_updated) return;
        for (self.resources.items) |res| {
            if (mode_updated) sendMode(self, res);
            if (geometry_updated) sendGeometry(self, res);
            if (scale_updated) sendScale(self, res);
        }
        scheduleDone(self);
    }

    /// Coalesce done: one idle callback covers any burst of state
    /// changes in a single dispatch (wlroots schedule_done). Falls back
    /// to sending immediately when the idle source cannot be allocated.
    fn scheduleDone(self: *WlOutput) void {
        if (self.done_source != null) return; // already scheduled
        const loop = self.display.getServer().getEventLoop();
        self.done_source = loop.addIdle(*WlOutput, sendDoneIdle, self) catch null;
        if (self.done_source == null) {
            for (self.resources.items) |res| sendDone(self, res);
        }
    }

    fn sendDoneIdle(wl_output: *WlOutput) void {
        wl_output.done_source = null;
        for (wl_output.resources.items) |res| sendDone(wl_output, res);
    }

    fn bindOutput(cli: *wire.Client, wl_output: *WlOutput, version: u32, id: u32) void {
        const resource = server.wl.Output.create(cli, version, id) catch {
            cli.postNoMemory();
            return;
        };
        resource.setHandler(*WlOutput, outputRequest, outputResourceDestroy, wl_output);
        wl_output.resources.append(wl_output.allocator, resource) catch {
            // The resource exists but never entered the list: destroy it
            // now. Leaving it alive would keep a live object's destroy
            // callback pointing at a list that never held it, and the
            // no-memory error makes the client go away anyway.
            resource.destroy();
            cli.postNoMemory();
            return;
        };
        wl_output.sendState(resource);
    }

    /// The output died: withdraw the global and drop the coalesced done,
    /// and free nothing. The bound resources must survive this phase —
    /// the compositor's own destroy listeners still send wl_surface.leave
    /// events naming THIS output through them, and they are the only
    /// way the client learns the output is gone. The module state goes in
    /// the finalize phase.
    fn onOutputDestroy(listener: *wire.Listener(*Output), _: *Output) void {
        const self: *WlOutput = @fieldParentPtr("destroy_listener", listener);
        self.dropIdle();
        if (self.global) |g| {
            g.destroy();
            self.global = null;
        }
    }

    /// Every destroy listener has run, so nothing may reach a client
    /// through this module any more. Each surviving resource becomes an
    /// inert release-only object — the client may still hold it and must
    /// be able to release it without touching freed state — and the
    /// module frees itself. `output` is still readable here; the Output
    /// itself is freed by the caller after this signal.
    fn onOutputFinalize(listener: *wire.Listener(*Output), _: *Output) void {
        const self: *WlOutput = @fieldParentPtr("finalize_listener", listener);
        for (self.resources.items) |res| {
            res.setHandler(?*WlOutput, inertOutputRequest, null, null);
        }
        self.dropIdle();
        if (self.global) |g| {
            g.destroy();
            self.global = null;
        }
        self.finalize_listener.link.remove();
        self.destroy_listener.link.remove();
        self.commit_listener.link.remove();
        const allocator = self.allocator;
        self.resources.deinit(allocator);
        allocator.destroy(self);
    }

    /// Cancel the coalesced-done idle source, once. Nulling the field
    /// keeps a second teardown pass from removing it again.
    fn dropIdle(self: *WlOutput) void {
        if (self.done_source) |src| {
            self.done_source = null;
            src.remove();
        }
    }
};

fn outputRequest(resource: *server.wl.Output, request: server.wl.Output.Request, _: *WlOutput) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

/// The client destroyed a wl_output it had bound here (wl_output.release
/// or a client teardown): drop it from the broadcast list NOW. A resource
/// left in the list is freed memory the next mode/scale commit would send
/// an event to.
fn outputResourceDestroy(resource: *server.wl.Output, wl_output: *WlOutput) void {
    const idx = std.mem.indexOfScalar(*server.wl.Output, wl_output.resources.items, resource) orelse return;
    _ = wl_output.resources.orderedRemove(idx);
}

/// A wl_output whose output died: the resource stays alive because the
/// client still holds it, but nothing about it may reach the freed
/// WlOutput any more. The only request the protocol defines is release,
/// which frees the resource itself — that is the whole contract of an
/// inert object. The null user data is what makes it inert (the generated
/// setHandler takes a nullable data type for exactly this case).
fn inertOutputRequest(resource: *server.wl.Output, request: server.wl.Output.Request, _: ?*WlOutput) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const client = @import("protocol").client;
const backend_mod = @import("../backend/backend.zig");
const test_pump = @import("../utils/test_pump.zig");

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
        // Output.destroy runs both teardown phases: the destroy phase
        // withdraws the global, the finalize phase frees this module. No
        // separate teardown here.
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
        // Output.destroy frees the WlOutput in its finalize phase, after
        // every destroy listener has run.
        if (ts.output) |o| o.destroy();
        if (ts.backend) |b| b.destroy();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// One shared roundtrip (utils/test_pump.zig) plus this harness's own
    /// client-side poll and dispatch, so the server's replies reach the
    /// test's listeners before the assertions run. A dispatch failure
    /// nulls the client: the server already destroyed it, so deinit must
    /// not destroy it again (libwayland logs a re-entrant destroy).
    fn pump(ts: *TestServer) !void {
        try test_pump.roundtrip(ts.c_display, ts.display.?, 0);
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

test "mode/scale commit rebroadcasts to bound resources with a coalesced done" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, 4);
    defer ts.deinit();

    var events: OutputEvents = .{};
    ts.wl_output_proxy.?.setListener(*OutputEvents, OutputEvents.listener, &events);
    try ts.pump(); // bind-time state send
    try std.testing.expectEqual(@as(usize, 1), events.mode_count);
    try std.testing.expectEqual(@as(usize, 1), events.done_count);

    // Commit a mode + scale change: the bound resource gets the new
    // mode, geometry and scale, and one done (idle-coalesced).
    var state = Output.State.init(allocator);
    defer state.deinit();
    state.committed = Output.State.committed_mode | Output.State.committed_scale;
    state.mode = .{ .width = 800, .height = 600, .refresh_msec = 8 };
    state.scale = 2.0;
    try ts.output.?.commitState(&state);

    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), events.mode_count);
    try std.testing.expectEqual(@as(i32, 800), events.mode_width);
    try std.testing.expectEqual(@as(i32, 600), events.mode_height);
    try std.testing.expectEqual(@as(usize, 2), events.geometry_count);
    try std.testing.expectEqual(@as(usize, 2), events.scale_count);
    try std.testing.expectEqual(@as(i32, 2), events.scale_factor);
    try std.testing.expectEqual(@as(usize, 2), events.done_count);

    // A commit whose fields are unchanged (a repeated frame) is stripped
    // by Output.commitState and rebroadcasts nothing.
    var frame = Output.State.init(allocator);
    defer frame.deinit();
    frame.committed = Output.State.committed_mode | Output.State.committed_scale;
    frame.mode = .{ .width = 800, .height = 600, .refresh_msec = 8 };
    frame.scale = 2.0;
    try ts.output.?.commitState(&frame);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), events.mode_count);
    try std.testing.expectEqual(@as(usize, 2), events.geometry_count);
    try std.testing.expectEqual(@as(usize, 2), events.scale_count);
    try std.testing.expectEqual(@as(usize, 2), events.done_count);
}

test "releasing one wl_output leaves another binding receiving mode changes" {
    const ts = try TestServer.init(std.testing.allocator, 4);
    defer ts.deinit();
    var first_events: OutputEvents = .{};
    ts.wl_output_proxy.?.setListener(*OutputEvents, OutputEvents.listener, &first_events);
    try ts.pump();
    const registry = try ts.c_display.?.getRegistry();
    var capture: RegistryCapture = .{};
    registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
    try ts.pump();
    const survivor = try registry.bind(capture.output_name.?, client.wl.Output, 4);
    var survivor_events: OutputEvents = .{};
    survivor.setListener(*OutputEvents, OutputEvents.listener, &survivor_events);
    try ts.pump();
    try std.testing.expectEqual(@as(i32, 1920), survivor_events.mode_width);

    ts.wl_output_proxy.?.release();
    ts.wl_output_proxy = null;
    try ts.pump();
    var state = Output.State.init(std.testing.allocator);
    defer state.deinit();
    state.committed = Output.State.committed_mode;
    state.mode = .{ .width = 1280, .height = 720, .refresh_msec = 16 };
    try ts.output.?.commitState(&state);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), survivor_events.mode_count);
    try std.testing.expectEqual(@as(i32, 1280), survivor_events.mode_width);
    try std.testing.expectEqual(@as(i32, 720), survivor_events.mode_height);
}

test "a bound wl_output can be released after its output is unplugged" {
    const ts = try TestServer.init(std.testing.allocator, 4);
    defer ts.deinit();
    var events: OutputEvents = .{};
    ts.wl_output_proxy.?.setListener(*OutputEvents, OutputEvents.listener, &events);
    try ts.pump();
    try std.testing.expectEqual(@as(i32, 1920), events.mode_width);
    ts.output.?.destroy();
    ts.output = null;
    ts.wl_output = null;
    try ts.pump();
    ts.wl_output_proxy.?.release();
    ts.wl_output_proxy = null;
    try ts.pump();
    // A live roundtrip after the release distinguishes a valid inert
    // wl_output from a request dispatched through freed global state.
    const callback = try ts.c_display.?.sync();
    var done: bool = false;
    callback.setListener(*bool, outputReleaseSync, &done);
    try ts.pump();
    try std.testing.expect(done);
}

fn outputReleaseSync(callback: *client.wl.Callback, _: client.wl.Callback.Event, done: *bool) void {
    done.* = true;
    callback.destroy();
}
