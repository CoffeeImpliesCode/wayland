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

/// A producer registry's buffer lookup: given a client wl_buffer
/// resource, return the Buffer the module already wrapped, or null when
/// the resource is not one of that module's buffers. `ctx` is the module
/// pointer the server handed to Compositor.setDmabufResolver.
///
/// A function pointer rather than a `?*linux_dmabuf.LinuxDmabuf` field on
/// purpose. shell/linux_dmabuf.zig imports compositor/compositor.zig and
/// compositor/surface.zig (its harness builds a real Compositor), so
/// naming its type here would close a compositor<->shell cycle and pull a
/// shell protocol module into wl_compositor's dependency set. This seam
/// keeps the compositor protocol-agnostic: the server, which owns both
/// modules, hands the lookup over at startup and takes it back before
/// teardown.
pub const DmabufResolver = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, resource: *wire.Resource) ?*shm_mod.Buffer,
};

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
    /// Optional lookup for wl_buffers that are NOT shm pool buffers
    /// (today zwp_linux_dmabuf_v1). See DmabufResolver.
    dmabuf_resolver: ?DmabufResolver = null,
    /// Compositor lifecycle events (wlroots events.new_surface /
    /// events.destroy, wlr_compositor.c:1318-1320, 1348-1350). Consumers
    /// observe surface creation instead of polling `surfaces`.
    events: struct {
        /// A new wl_surface was created.
        new_surface: wire.Signal(*Surface),
        /// The compositor is being torn down; remaining surfaces are
        /// destroyed right after this signal.
        destroy: wire.Signal(*Compositor),
    },

    /// Attach the SHM buffer registry to this compositor.
    pub fn setShm(c: *Compositor, state: *shm_mod.ShmState) void {
        c.shm = state;
    }

    /// Teach wl_surface.attach to resolve zwp_linux_dmabuf_v1 buffers
    /// through `resolver`. The server calls this right after constructing
    /// the module; `resolver.ctx` is that module.
    pub fn setDmabufResolver(c: *Compositor, resolver: DmabufResolver) void {
        c.dmabuf_resolver = resolver;
    }

    /// Drop the dmabuf resolver. The server calls this before the module
    /// is destroyed, so a late wl_surface.attach can never reach a freed
    /// LinuxDmabuf; attach falls back to the shm registry.
    pub fn clearDmabufResolver(c: *Compositor) void {
        c.dmabuf_resolver = null;
    }

    /// Ask the registered resolver for the Buffer that owns `resource`.
    /// Null when no resolver is registered, or when the resource is not a
    /// dmabuf buffer — the caller then takes the shm path.
    pub fn resolveDmabuf(c: *Compositor, resource: *wire.Resource) ?*shm_mod.Buffer {
        const r = c.dmabuf_resolver orelse return null;
        return r.resolve(r.ctx, resource);
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
            .dmabuf_resolver = null,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        c.events.new_surface.init();
        c.events.destroy.init();
        errdefer c.surfaces.deinit(allocator);
        c.global = try display.addGlobal(server.wl.Compositor, *Compositor, bindCompositor, compositor_version, c);
        return c;
    }

    /// Destroy the compositor: emit the destroy signal, destroy the global
    /// and destroy every remaining surface (each removes itself from the
    /// list). The global is destroyed (wl_global_destroy), not just
    /// unpublished: remove() keeps it registered and bindable, so a late
    /// registry_bind could call into the freed Compositor (F12). Order
    /// matches compositor_handle_display_destroy (wlr_compositor.c:1346-1359).
    pub fn deinit(c: *Compositor) void {
        c.events.destroy.emit(c);
        if (c.global) |g| g.destroy();
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
        c.events.new_surface.emit(surface);
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
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    c.events.new_surface.init();
    c.events.destroy.init();
    defer allocator.destroy(c);
    defer c.surfaces.deinit(allocator);

    const fake_a: *Surface = @ptrFromInt(0x100);
    const fake_b: *Surface = @ptrFromInt(0x200);
    try c.surfaces.append(allocator, fake_a);
    try c.surfaces.append(allocator, fake_b);

    c.removeSurface(fake_a);
    try testing.expectEqual(@as(usize, 1), c.surfaces.items.len);
    try testing.expect(c.surfaces.items[0] == fake_b);

    c.removeSurface(fake_a); // unknown surface: no-op
    try testing.expectEqual(@as(usize, 1), c.surfaces.items.len);
}

test "compositor new_surface and destroy signals fire (F21)" {
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
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    c.events.new_surface.init();
    c.events.destroy.init();
    defer allocator.destroy(c);
    defer c.surfaces.deinit(allocator);

    var created: CreatedCapture = .{ .listener = wire.Listener(*Surface).init(CreatedCapture.notify) };
    var destroyed: DestroyedCapture = .{ .listener = wire.Listener(*Compositor).init(DestroyedCapture.notify) };
    c.events.new_surface.add(&created.listener);
    c.events.destroy.add(&destroyed.listener);

    const fake: *Surface = @ptrFromInt(0x300);
    c.events.new_surface.emit(fake);
    try testing.expect(created.surface == fake);

    c.events.destroy.emit(c);
    try testing.expect(destroyed.compositor == c);
}

const CreatedCapture = struct {
    surface: ?*Surface = null,
    listener: wire.Listener(*Surface),

    fn notify(listener: *wire.Listener(*Surface), surface: *Surface) void {
        @as(*CreatedCapture, @fieldParentPtr("listener", listener)).surface = surface;
    }
};

const DestroyedCapture = struct {
    compositor: ?*Compositor = null,
    listener: wire.Listener(*Compositor),

    fn notify(listener: *wire.Listener(*Compositor), compositor: *Compositor) void {
        @as(*DestroyedCapture, @fieldParentPtr("listener", listener)).compositor = compositor;
    }
};
