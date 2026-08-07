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

    fn bindOutput(client: *wire.Client, wl_output: *WlOutput, version: u32, id: u32) void {
        const resource = server.wl.Output.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        resource.setHandler(*WlOutput, outputRequest, null, wl_output);
        wl_output.resources.append(wl_output.allocator, resource) catch {
            client.postNoMemory();
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
