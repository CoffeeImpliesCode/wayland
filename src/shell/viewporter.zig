//! wp_viewporter (stable/viewporter): lets clients crop and scale a
//! wl_surface's content via a per-surface wp_viewport.
//!
//! Scope: the viewporter global + per-surface wp_viewport objects. The
//! crop/scale state is double-buffered and applies on wl_surface.commit.
//! The compositor surfaces honor a set destination size (the surface
//! size becomes dst_width x dst_height); the source crop is recorded but
//! this renderer draws the whole buffer (the source is validated against
//! the buffer at commit like wlroots).
//!
//! foot requires the viewporter (its wayland.c warns "compositor does not
//! implement fractional scaling" unless BOTH wp_fractional_scale and
//! wp_viewporter are present). At scale 1 foot uses an identity viewport
//! (full source, destination == buffer size), so the surface size is
//! unchanged in practice.

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const geom = @import("../utils/geom.zig");
const surface_mod = @import("../compositor/surface.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "viewporter";

/// The destination size set via wp_viewport.set_destination, or null
/// when unset (the surface keeps its buffer-derived size). Stored on the
/// surface and applied by the commit pipeline.
pub const ViewportState = struct {
    /// Destination size in surface-local units; null = unset.
    dst: ?geom.Size = null,
    /// Source rectangle in buffer coords (after transform/scale); null =
    /// whole buffer.
    src: ?geom.FRect = null,
};

pub const Viewporter = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    global: ?*wire.Global = null,
    /// Per-surface viewport resources, for the exists check.
    objects: std.ArrayList(*ViewportRes) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) !*Viewporter {
        const vp = try allocator.create(Viewporter);
        errdefer allocator.destroy(vp);
        vp.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .objects = .empty,
        };
        errdefer vp.objects.deinit(allocator);
        vp.global = try display.addGlobal(
            server.wp.Viewporter,
            *Viewporter,
            viewporterBind,
            server.wp.Viewporter.generated_version,
            vp,
        );
        return vp;
    }

    pub fn deinit(self: *Viewporter) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        while (self.objects.items.len > 0) self.objects.items[0].res.destroy();
        self.objects.deinit(allocator);
        allocator.destroy(self);
    }
};

/// The per-surface viewport resource.
const ViewportRes = struct {
    vp: *Viewporter,
    surface: *surface_mod.Surface,
    res: *server.wp.Viewport,
    state: ViewportState,
};

fn viewporterBind(client_wire: *wire.Client, vp: *Viewporter, version: u32, id: u32) void {
    const viewporter = server.wp.Viewporter.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    viewporter.setHandler(*Viewporter, viewporterRequest, viewporterDestroy, vp);
}

fn viewporterRequest(viewporter: *server.wp.Viewporter, request: server.wp.Viewporter.Request, vp: *Viewporter) void {
    switch (request) {
        .destroy => viewporter.destroy(),
        .get_viewport => |r| {
            const surface: *surface_mod.Surface = @ptrCast(@alignCast(r.surface.getUserData()));
            for (vp.objects.items) |vres| {
                if (vres.surface == surface) {
                    viewporter.postError(.viewport_exists, "wl_surface already has a wp_viewport object");
                    return;
                }
            }
            const res = server.wp.Viewport.create(viewporter.getClient(), viewporter.getVersion(), r.id) catch {
                viewporter.postNoMemory();
                return;
            };
            const vres = vp.allocator.create(ViewportRes) catch {
                res.destroy();
                viewporter.postNoMemory();
                return;
            };
            vres.* = .{ .vp = vp, .surface = surface, .res = res, .state = .{} };
            vp.objects.append(vp.allocator, vres) catch {
                vp.allocator.destroy(vres);
                res.destroy();
                viewporter.postNoMemory();
                return;
            };
            res.setHandler(*ViewportRes, viewportRequest, viewportDestroy, vres);
            log.debug("viewport for surface@{d}", vp.io, vp.log_cfg, log_tag, .{surface.resource.getId()});
        },
    }
}

fn viewporterDestroy(viewporter: *server.wp.Viewporter, _: *Viewporter) void {
    _ = viewporter;
}

fn viewportRequest(res: *server.wp.Viewport, request: server.wp.Viewport.Request, vres: *ViewportRes) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_source => |r| {
            const sx = r.x.toDouble();
            const sy = r.y.toDouble();
            const sw = r.width.toDouble();
            const sh = r.height.toDouble();
            // All of x,y,w,h == -1 unsets; negative coords or non-positive
            // size is bad_value.
            if (sx == -1 and sy == -1 and sw == -1 and sh == -1) {
                vres.state.src = null;
                return;
            }
            if (sx < 0 or sy < 0 or sw <= 0 or sh <= 0) {
                res.postError(.bad_value, "wp_viewport.set_source: negative coords or non-positive size");
                return;
            }
            // Out-of-buffer is checked at commit (the buffer may change).
            vres.state.src = .{ .x = sx, .y = sy, .width = sw, .height = sh };
        },
        .set_destination => |r| {
            if (r.width == -1 and r.height == -1) {
                vres.state.dst = null;
                vres.surface.viewport_dst = null;
                return;
            }
            if (r.width <= 0 or r.height <= 0) {
                res.postError(.bad_value, "wp_viewport.set_destination: non-positive size");
                return;
            }
            vres.state.dst = .{ .w = r.width, .h = r.height };
            vres.surface.viewport_dst = .{ .w = r.width, .h = r.height };
        },
    }
}

fn viewportDestroy(res: *server.wp.Viewport, vres: *ViewportRes) void {
    _ = res;
    const vp = vres.vp;
    const idx = std.mem.indexOfScalar(*ViewportRes, vp.objects.items, vres) orelse 0;
    if (idx < vp.objects.items.len and vp.objects.items[idx] == vres) {
        _ = vp.objects.orderedRemove(idx);
    }
    vp.allocator.destroy(vres);
}
