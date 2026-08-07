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
    surface: *Surface,
    parent: *Surface,
    x: i32 = 0,
    y: i32 = 0,
    sync: bool = true,
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
    };
    ss_res.setHandler(*Subsurface, subsurfaceRequest, subsurfaceDestroy, ss);
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

fn subsurfaceDestroy(ss_res: *server.wl.Subsurface, ss: *Subsurface) void {
    _ = ss_res;
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
