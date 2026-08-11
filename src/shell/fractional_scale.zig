//! wp_fractional_scale_manager_v1 (staging/fractional-scale-v1): lets
//! clients render at the compositor's preferred fractional scale.
//!
//! Scope: the manager global + per-surface wp_fractional_scale_v1
//! objects. The compositor advertises a preferred_scale (the numerator
//! of a fraction with denominator 120) when a surface's output scale
//! changes. This server runs at scale 1, so the advertised scale is
//! always 120 — the event still silences clients that gate on the
//! protocol (foot) and gives them their preferred render path.
//!
//! Cross-module contract: the manager binds per client;
//! get_fractional_scale creates a wp_fractional_scale_v1 for a
//! wl_surface; a surface may only have one such object
//! (fractional_scale_exists error). The state owns the per-surface
//! object and frees it on the fractional_scale.destroy or the surface
//! teardown (the resource user data carries the state).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const surface_mod = @import("../compositor/surface.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "fractional_scale";

/// The preferred scale (numerator of a fraction over 120) this compositor
/// advertises. Always 120 (scale 1.0).
const preferred_scale: u32 = 120;

pub const FractionalScale = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The manager global, for teardown.
    global: ?*wire.Global = null,
    /// Per-surface fractional_scale objects, for the exists check.
    objects: std.ArrayList(*ScaleState) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) !*FractionalScale {
        const fs = try allocator.create(FractionalScale);
        errdefer allocator.destroy(fs);
        fs.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .objects = .empty,
        };
        errdefer fs.objects.deinit(allocator);
        fs.global = try display.addGlobal(
            server.wp.FractionalScaleManagerV1,
            *FractionalScale,
            fractionalScaleBind,
            server.wp.FractionalScaleManagerV1.generated_version,
            fs,
        );
        return fs;
    }

    pub fn deinit(self: *FractionalScale) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the resources cascades through their destroy
        // handlers, which free the states and prune the list.
        while (self.objects.items.len > 0) self.objects.items[0].res.destroy();
        self.objects.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Per-wl_surface fractional-scale state.
const ScaleState = struct {
    fs: *FractionalScale,
    /// The compositor's Surface the object was created for.
    surface: *surface_mod.Surface,
    /// The wp_fractional_scale_v1 resource.
    res: *server.wp.FractionalScaleV1,
};

fn fractionalScaleBind(client_wire: *wire.Client, fs: *FractionalScale, version: u32, id: u32) void {
    log.info("FS bind v{d} id={d}", fs.io, fs.log_cfg, log_tag, .{ version, id });
    const manager = server.wp.FractionalScaleManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    manager.setHandler(*FractionalScale, fractionalScaleRequest, fractionalScaleDestroy, fs);
}

fn fractionalScaleRequest(
    manager: *server.wp.FractionalScaleManagerV1,
    request: server.wp.FractionalScaleManagerV1.Request,
    fs: *FractionalScale,
) void {
    switch (request) {
        .destroy => manager.destroy(),
        .get_fractional_scale => |r| {
            // The wl_surface resource's user data is the compositor's Surface.
            const surface: *surface_mod.Surface = @ptrCast(@alignCast(r.surface.getUserData()));
            for (fs.objects.items) |st| {
                if (st.surface == surface) {
                    manager.postError(.fractional_scale_exists, "wl_surface already has a fractional scale object");
                    return;
                }
            }
            const res = server.wp.FractionalScaleV1.create(manager.getClient(), manager.getVersion(), r.id) catch {
                manager.postNoMemory();
                return;
            };
            const st = fs.allocator.create(ScaleState) catch {
                res.destroy();
                manager.postNoMemory();
                return;
            };
            st.* = .{ .fs = fs, .surface = surface, .res = res };
            fs.objects.append(fs.allocator, st) catch {
                fs.allocator.destroy(st);
                res.destroy();
                manager.postNoMemory();
                return;
            };
            res.setHandler(*ScaleState, scaleRequest, scaleDestroy, st);
            // Advertise the compositor's scale immediately.
            res.sendPreferredScale(preferred_scale);
            log.debug("fractional scale for surface@{d}: {d}/120", fs.io, fs.log_cfg, log_tag, .{
                surface.resource.getId(),
                preferred_scale,
            });
        },
    }
}

fn fractionalScaleDestroy(manager: *server.wp.FractionalScaleManagerV1, fs: *FractionalScale) void {
    _ = manager;
    _ = fs;
    // The manager resource dies with the client teardown; per-surface
    // states are freed by their own resource destroy handlers.
}

fn scaleRequest(res: *server.wp.FractionalScaleV1, request: server.wp.FractionalScaleV1.Request, st: *ScaleState) void {
    _ = st;
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn scaleDestroy(res: *server.wp.FractionalScaleV1, st: *ScaleState) void {
    _ = res;
    // Prune the state from the manager's list and free it.
    const fs = st.fs;
    const idx = std.mem.indexOfScalar(*ScaleState, fs.objects.items, st) orelse 0;
    if (idx < fs.objects.items.len and fs.objects.items[idx] == st) {
        _ = fs.objects.orderedRemove(idx);
    }
    fs.allocator.destroy(st);
}
