//! wl_subcompositor (M3/M4): nested surfaces (toolkit requirement).
//!
//! Minimal-but-functional subcompositor: the wl_subcompositor global and
//! wl_subsurface objects with role enforcement, set_position and
//! sync/desync tracking. The compositor renders subsurface surfaces as
//! scene nodes positioned over their parent (server-side sync, see the
//! test server's syncSubsurfaceNodes).
//!
//! M3 simplifications (documented, foot-compatible):
//!   - sync/desync is tracked but not enforced: every commit is treated
//!     as desync'd (immediate). Rendering stays correct; tearing may
//!     occur during scrollback updates.
//!   - place_above/place_below are ignored: the child always draws above
//!     its parent (the server re-appends child nodes on top).
//!   - Destroying a wl_subsurface while its surface lives leaves the
//!     surface renderable as a plain surface (foot only destroys
//!     subsurfaces at teardown).
//!   - Lifecycle is guarded: if either surface (child or parent) is
//!     destroyed while the wl_subsurface lives, the compositor destroys
//!     the wl_subsurface synchronously (the child keeps rendering as a
//!     plain surface; a parent's death makes the wl_subsurface inert,
//!     per wlroots' destroy-on-parent-destroy). No raw *Surface pointer
//!     outlives its surface.
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, compositor/*.

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const compositor_mod = @import("compositor.zig");
const surface_mod = @import("surface.zig");
const role_mod = @import("role.zig");

const server = @import("protocol").server;

const Surface = surface_mod.Surface;

/// wl_subcompositor protocol version this library implements.
pub const subcompositor_version: u32 = 1;

pub const Subcompositor = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    compositor: *compositor_mod.Compositor,
    global: ?*wire.Global = null,
    /// All subsurfaces, for the compositor's per-frame node sync.
    subsurfaces: std.ArrayList(*Subsurface) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        compositor: *compositor_mod.Compositor,
    ) error{ OutOfMemory, GlobalCreateFailed }!*Subcompositor {
        const self = try allocator.create(Subcompositor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .compositor = compositor,
            .subsurfaces = .empty,
        };
        errdefer self.subsurfaces.deinit(allocator);
        self.global = try display.addGlobal(
            server.wl.Subcompositor,
            *Subcompositor,
            bindSubcompositor,
            subcompositor_version,
            self,
        );
        log.debug("subcompositor created", io, log_cfg, "subsurface", .{});
        return self;
    }

    pub fn deinit(self: *Subcompositor) void {
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        // Destroy outstanding wl_subsurface resources: each destroy
        // handler detaches its lifecycle listeners, removes the entry
        // from the registry and frees the Subsurface. This must happen
        // before the surfaces die (Compositor.deinit runs after this in
        // the server), or their destroy signals would fire listeners on
        // freed state.
        while (self.subsurfaces.items.len > 0) self.subsurfaces.items[0].resource.destroy();
        self.subsurfaces.deinit(allocator);
        allocator.destroy(self);
    }

    /// Resolve a wl_surface resource to its Surface (all surfaces belong
    /// to this compositor).
    pub fn surfaceFromResource(self: *Subcompositor, resource: *server.wl.Surface) ?*Surface {
        for (self.compositor.surfaces.items) |s| {
            if (s.resource == resource) return s;
        }
        return null;
    }
};

/// A wl_subsurface role object: the surface renders above `parent`,
/// offset by (x, y).
pub const Subsurface = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    subcompositor: *Subcompositor,
    resource: *server.wl.Subsurface,
    /// The child surface (wl_subsurface role). Valid only while this
    /// entry is in `subcompositor.subsurfaces`: either surface's death
    /// tears the entry down synchronously (see onSurfaceDestroy /
    /// onParentDestroy), so no raw pointer outlives its surface.
    surface: *Surface,
    /// The parent surface; same lifetime rule as `surface`.
    parent: *Surface,
    x: i32 = 0,
    y: i32 = 0,
    sync: bool = true,
    /// Fired when `surface` (the child) dies: the wl_subsurface must die
    /// with its role object.
    surface_listener: wire.Listener(*Surface),
    /// Fired when `parent` dies: the wl_subsurface becomes inert and is
    /// destroyed by the compositor.
    parent_listener: wire.Listener(*Surface),
};

/// The shared role for subsurface surfaces.
const subsurface_role: role_mod.SurfaceRole = .{ .name = "subsurface" };

fn bindSubcompositor(client: *wire.Client, sc: *Subcompositor, version: u32, id: u32) void {
    const resource = server.wl.Subcompositor.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Subcompositor, subcompositorRequest, null, sc);
}

fn subcompositorRequest(
    resource: *server.wl.Subcompositor,
    request: server.wl.Subcompositor.Request,
    sc: *Subcompositor,
) void {
    switch (request) {
        .get_subsurface => |r| getSubsurface(sc, resource, r.id, r.surface, r.parent),
        .destroy => resource.destroy(),
    }
}

fn getSubsurface(
    sc: *Subcompositor,
    resource: *server.wl.Subcompositor,
    id: u32,
    surface_res: *server.wl.Surface,
    parent_res: *server.wl.Surface,
) void {
    const client = resource.getClient();
    const surface = sc.surfaceFromResource(surface_res) orelse {
        resource.postNoMemory();
        return;
    };
    const parent = sc.surfaceFromResource(parent_res) orelse {
        resource.postNoMemory();
        return;
    };
    if (surface == parent) {
        // The parent must be a different surface.
        resource.postError(.bad_parent, "parent must be a different surface");
        return;
    }
    if (parent.role == &subsurface_role) {
        // A subsurface cannot be a parent (nesting goes through the
        // regular surface it is attached to).
        resource.postError(.bad_parent, "parent is a subsurface");
        return;
    }

    const ss_res = server.wl.Subsurface.create(client, 1, id) catch {
        resource.postNoMemory();
        return;
    };
    const ss = sc.allocator.create(Subsurface) catch {
        ss_res.destroy();
        resource.postNoMemory();
        return;
    };
    ss.* = .{
        .allocator = sc.allocator,
        .io = sc.io,
        .log_cfg = sc.log_cfg,
        .subcompositor = sc,
        .resource = ss_res,
        .surface = surface,
        .parent = parent,
        .surface_listener = wire.Listener(*Surface).init(onSurfaceDestroy),
        .parent_listener = wire.Listener(*Surface).init(onParentDestroy),
    };
    // Listener.init leaves `link` undefined; put it in the detached state
    // so the error paths below (which route through subsurfaceDestroy ->
    // detachListeners) never unlink garbage.
    ss.surface_listener.link.prev = null;
    ss.surface_listener.link.next = null;
    ss.parent_listener.link.prev = null;
    ss.parent_listener.link.next = null;
    ss_res.setHandler(*Subsurface, subsurfaceRequest, subsurfaceDestroy, ss);
    // The wl_subsurface cannot outlive either surface: tearing it down
    // when one dies also removes this entry from the registry, so the
    // per-frame sync (server/main.zig syncSubsurfaceNodes) never sees a
    // dead *Surface.
    surface.events.destroy.add(&ss.surface_listener);
    parent.events.destroy.add(&ss.parent_listener);
    sc.subsurfaces.append(sc.allocator, ss) catch {
        ss_res.destroy();
        resource.postNoMemory();
        return;
    };
    // The role is permanent for the surface: a surface with an xdg role
    // cannot become a subsurface and vice versa.
    role_mod.assignRole(surface, &subsurface_role, @ptrCast(ss_res)) catch {
        ss_res.destroy();
        return;
    };
    log.debug("subsurface@{d} under parent@{d}", sc.io, sc.log_cfg, "subsurface", .{
        surface.resource.getId(),
        parent.resource.getId(),
    });
}

fn subsurfaceRequest(ss_res: *server.wl.Subsurface, request: server.wl.Subsurface.Request, ss: *Subsurface) void {
    switch (request) {
        .set_position => |r| {
            ss.x = r.x;
            ss.y = r.y;
        },
        .place_above => |r| {
            _ = r;
            // Ignored in M3: the child always draws above its parent.
        },
        .place_below => |r| {
            _ = r;
            // Ignored in M3.
        },
        .set_sync => ss.sync = true,
        .set_desync => ss.sync = false,
        .destroy => ss_res.destroy(),
    }
}

/// The child surface died: the wl_subsurface must die with it (its role
/// pointer would dangle). The destroy handler clears the role and frees.
fn onSurfaceDestroy(listener: *wire.Listener(*Surface), _: *Surface) void {
    const ss: *Subsurface = @fieldParentPtr("surface_listener", listener);
    teardownOnSurfaceDeath(ss);
}

/// The parent surface died: the wl_subsurface is inert. Per wlroots
/// (wlr_subcompositor.c destroy-on-parent-destroy) the compositor
/// destroys it; the client sees its object die.
fn onParentDestroy(listener: *wire.Listener(*Surface), _: *Surface) void {
    const ss: *Subsurface = @fieldParentPtr("parent_listener", listener);
    teardownOnSurfaceDeath(ss);
}

/// Detach both lifecycle listeners, then destroy the wl_subsurface
/// resource. The destroy handler runs synchronously: it removes the entry
/// from the registry and frees `ss` — so `ss` must not be touched after
/// the resource.destroy() call.
fn teardownOnSurfaceDeath(ss: *Subsurface) void {
    detachListeners(ss);
    ss.resource.destroy();
}

/// Unsubscribe both lifecycle listeners. Idempotent: a link in the
/// detached state (prev/next null) is skipped.
fn detachListeners(ss: *Subsurface) void {
    if (ss.surface_listener.link.prev != null) ss.surface_listener.link.remove();
    if (ss.parent_listener.link.prev != null) ss.parent_listener.link.remove();
}

fn subsurfaceDestroy(ss_res: *server.wl.Subsurface, ss: *Subsurface) void {
    _ = ss_res;
    // Unsubscribe the lifecycle listeners first: a later surface destroy
    // must not fire into the freed state (this path frees ss below).
    detachListeners(ss);
    const sc = ss.subcompositor;
    // The surface loses its role; it keeps rendering as a plain surface
    // until it unmaps (the server's commit path handles that).
    if (ss.surface.role == &subsurface_role) {
        ss.surface.role = null;
        ss.surface.role_resource = null;
    }
    const idx = std.mem.indexOfScalar(*Subsurface, sc.subsurfaces.items, ss) orelse 0;
    if (idx < sc.subsurfaces.items.len and sc.subsurfaces.items[idx] == ss) {
        _ = sc.subsurfaces.orderedRemove(idx);
    }
    const allocator = sc.allocator;
    allocator.destroy(ss);
}

// --- Tests --------------------------------------------------------------

const testing = std.testing;

/// Fabricate a Subcompositor for tests. Subcompositor.init is bypassed:
/// it would call display.addGlobal on the dummy display pointer.
fn testSubcompositor(
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    comp: *compositor_mod.Compositor,
) !*Subcompositor {
    const sc = try allocator.create(Subcompositor);
    sc.* = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = log_cfg,
        .display = @ptrFromInt(0x10), // dummy: never dereferenced
        .compositor = comp,
        .global = null,
        .subsurfaces = .empty,
    };
    return sc;
}

const SubsurfaceTest = struct {
    allocator: std.mem.Allocator,
    tw: surface_mod.TestWire,
    comp: *compositor_mod.Compositor,
    sc: *Subcompositor,
    child: *Surface,
    parent: *Surface,

    fn init(allocator: std.mem.Allocator, io: *std.Io, log_cfg: *const log.Config) !SubsurfaceTest {
        var tw = try surface_mod.TestWire.init();
        errdefer tw.deinit();
        const comp = try surface_mod.testCompositor(allocator, io, log_cfg);
        errdefer allocator.destroy(comp);
        const child = try surface_mod.testSurface(allocator, io, log_cfg, comp, &tw);
        const parent = try surface_mod.testSurface(allocator, io, log_cfg, comp, &tw);
        try comp.surfaces.append(allocator, child);
        try comp.surfaces.append(allocator, parent);
        errdefer comp.surfaces.deinit(allocator);
        const sc = try testSubcompositor(allocator, io, log_cfg, comp);
        errdefer allocator.destroy(sc);
        const sc_res = try server.wl.Subcompositor.create(tw.client, 1, tw.newId());
        getSubsurface(sc, sc_res, tw.newId(), child.resource, parent.resource);
        return .{
            .allocator = allocator,
            .tw = tw,
            .comp = comp,
            .sc = sc,
            .child = child,
            .parent = parent,
        };
    }

    /// Client teardown destroys any surface resources that are still
    /// alive (Surface.destroy); the registry must already be empty.
    fn deinit(self: *SubsurfaceTest) void {
        self.tw.deinit();
        self.sc.subsurfaces.deinit(self.allocator);
        self.comp.surfaces.deinit(self.allocator);
        self.allocator.destroy(self.sc);
        self.allocator.destroy(self.comp);
    }
};

test "child surface destroy removes the subsurface from the registry" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.sc.subsurfaces.items.len);

    // Destroying the child surface synchronously tears the wl_subsurface
    // down: the registry entry is gone before the Surface is freed, so
    // the per-frame sync never dereferences a dead *Surface.
    t.child.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);

    // The parent's destroy signal must not fire a dangling listener.
    t.parent.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);
}

test "parent surface destroy removes the subsurface and clears the role" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.sc.subsurfaces.items.len);

    // Parent death makes the wl_subsurface inert: destroyed by the
    // compositor, entry removed from the registry.
    t.parent.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);
    // The child keeps rendering as a plain surface: its role is cleared.
    try testing.expect(t.child.role == null);

    // The child's destroy signal must not fire a dangling listener.
    t.child.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);
}
