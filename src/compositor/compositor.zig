//! wl_compositor global: creates wl_surface and wl_region objects.
//!
//! Cross-module: src/core/display.zig (main agent). Expected API
//! (confirmed 2026-08-07):
//!   pub const CompositorDisplay = struct {
//!       allocator: std.mem.Allocator,
//!       io: *std.Io,
//!       log_cfg: *const log.Config,
//!       server: *wire.Server,
//!   };
//!   pub fn init(allocator: std.mem.Allocator, io: *std.Io,
//!       log_cfg: *const log.Config) !*CompositorDisplay;
//!   pub fn addGlobal(comptime T: type, version: u32, comptime DataT: type,
//!       data: DataT, comptime bind: fn (*wire.Client, DataT, u32, u32) void)
//!       !*wire.Global; // wraps wire.Global.create with display.server
//!   pub fn nextSerial(self: *CompositorDisplay) u32;
//!   pub fn loopFd(self: *CompositorDisplay) c_int;
//!   pub fn dispatch(self: *CompositorDisplay, timeout_ms: c_int) !void;
//!   pub fn run(self: *CompositorDisplay) void;
//!   pub fn initShm(self: *CompositorDisplay) !void;
//!   pub fn addSocketAuto(self: *CompositorDisplay) ![:0]const u8;
//!   pub fn deinit(self: *CompositorDisplay) void;
//!
//! Cross-module: src/compositor/surface.zig + region.zig (this cluster):
//!   Surface.create(allocator, io, log_cfg, compositor, resource) !*Surface
//!   Surface.destroy(*Surface) void
//!   Region.create(allocator, resource) !*Region
//!   Region.deinit(*Region) void

const std = @import("std");
const wire = @import("../core/wire.zig");
const log = @import("../utils/log.zig");
const display_mod = @import("../core/display.zig");
const shm_mod = @import("../buffers/shm.zig");
const surface_mod = @import("surface.zig");
const region_mod = @import("region.zig");

const server = @import("protocol").server;

const Surface = surface_mod.Surface;
const Region = region_mod.Region;

/// wl_compositor global version this library implements (max protocol
/// version of the interface; matches build.zig's scanner.generate).
pub const compositor_version: u32 = 7;

pub const Compositor = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// All surfaces created through this compositor.
    surfaces: std.ArrayList(*Surface) = .empty,
    /// The wl_compositor global, for teardown.
    global: ?*wire.Global = null,
    /// SHM buffer registry; attach() routes buffers through the tracked
    /// wrapper when set (release-delivering, deduped per resource).
    shm: ?*shm_mod.ShmState = null,

    /// Attach the SHM buffer registry to this compositor.
    pub fn setShm(c: *Compositor, state: *shm_mod.ShmState) void {
        c.shm = state;
    }

    /// Create the compositor and register the wl_compositor global.
    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) error{ OutOfMemory, GlobalCreateFailed }!*Compositor {
        const c = try allocator.create(Compositor);
        errdefer allocator.destroy(c);
        c.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .global = null,
            .shm = null,
        };
        errdefer c.surfaces.deinit(allocator);
        c.global = try display.addGlobal(server.wl.Compositor, *Compositor, bindCompositor, compositor_version, c);
        return c;
    }

    /// Destroy the compositor: unregister the global and destroy every
    /// remaining surface (each removes itself from the list).
    pub fn deinit(c: *Compositor) void {
        if (c.global) |g| g.remove();
        while (c.surfaces.items.len > 0) {
            c.surfaces.items[0].destroy();
        }
        const allocator = c.allocator;
        c.surfaces.deinit(allocator);
        allocator.destroy(c);
    }

    /// Remove a surface from the tracked list; called by Surface.destroy.
    pub fn removeSurface(c: *Compositor, surface: *Surface) void {
        const idx = std.mem.indexOfScalar(*Surface, c.surfaces.items, surface) orelse return;
        _ = c.surfaces.swapRemove(idx);
    }

    fn createSurface(c: *Compositor, client: *wire.Client, version: u32, id: u32) void {
        const resource = server.wl.Surface.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        const surface = Surface.create(c.allocator, c.io, c.log_cfg, c, resource) catch {
            resource.destroy();
            client.postNoMemory();
            return;
        };
        c.surfaces.append(c.allocator, surface) catch {
            // Destroying the resource runs the destructor chain
            // (handleDestroy -> Surface.destroy), freeing the surface.
            resource.destroy();
            client.postNoMemory();
            return;
        };
        log.debug("wl_surface@{d} created", c.io, c.log_cfg, "compositor", .{id});
    }

    fn createRegion(c: *Compositor, client: *wire.Client, version: u32, id: u32) void {
        const resource = server.wl.Region.create(client, version, id) catch {
            client.postNoMemory();
            return;
        };
        // The Region owns its lifetime via the resource destructor; the
        // compositor does not track regions.
        _ = Region.create(c.allocator, resource) catch {
            resource.destroy();
            client.postNoMemory();
            return;
        };
        log.debug("wl_region@{d} created", c.io, c.log_cfg, "compositor", .{id});
    }
};

/// Global bind callback: a client bound the wl_compositor global.
fn bindCompositor(client: *wire.Client, compositor: *Compositor, version: u32, id: u32) void {
    const resource = server.wl.Compositor.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Compositor, handleRequest, handleDestroy, compositor);
}

fn handleRequest(resource: *server.wl.Compositor, request: server.wl.Compositor.Request, compositor: *Compositor) void {
    switch (request) {
        .create_surface => |r| compositor.createSurface(resource.getClient(), resource.getVersion(), r.id),
        .create_region => |r| compositor.createRegion(resource.getClient(), resource.getVersion(), r.id),
        .release => resource.destroy(),
    }
}

fn handleDestroy(resource: *server.wl.Compositor, compositor: *Compositor) void {
    _ = resource;
    _ = compositor;
    // The wl_compositor object is a per-client view of the global; the
    // Compositor itself outlives its client resources.
}

const testing = std.testing;

test "compositor tracks and removes surfaces" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const c = try allocator.create(Compositor);
    c.* = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = &log_cfg,
        .display = @ptrFromInt(0x10), // dummy: never dereferenced
    };
    defer allocator.destroy(c);
    defer c.surfaces.deinit(allocator);

    const fake_a = @as(*Surface, @ptrFromInt(0x100));
    const fake_b = @as(*Surface, @ptrFromInt(0x200));
    try c.surfaces.append(allocator, fake_a);
    try c.surfaces.append(allocator, fake_b);

    c.removeSurface(fake_a);
    try testing.expectEqual(@as(usize, 1), c.surfaces.items.len);
    try testing.expect(c.surfaces.items[0] == fake_b);

    c.removeSurface(fake_a); // unknown surface: no-op
    try testing.expectEqual(@as(usize, 1), c.surfaces.items.len);
}
