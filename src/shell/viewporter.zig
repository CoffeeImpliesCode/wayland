//! wp_viewporter (stable/viewporter): lets clients crop and scale a
//! wl_surface's content via a per-surface wp_viewport.
//!
//! Scope: the viewporter global + per-surface wp_viewport objects. A
//! set destination size is applied immediately (single-buffered) on
//! set_destination (the surface size becomes dst_width x dst_height);
//! the source crop is recorded but this renderer draws the whole buffer.
//! (The protocol's double-buffered commit semantics and commit-time
//! source validation are F-AX-11/F-AX-12, not yet landed.)
//!
//! A wp_viewport outlives its wl_surface: surface destroy detaches the
//! destroy listener, prunes the exists-check list, and marks the object
//! inert. Every request except destroy then posts no_surface on the
//! viewport resource (viewporter.xml); destroying the viewport after the
//! surface is a clean no-op.
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

/// The per-surface viewport resource. Outlives its wl_surface: the
/// destroy listener prunes the exists list and marks the object inert
/// (requests then post no_surface). Freed by viewportDestroy when the
/// resource dies.
const ViewportRes = struct {
    vp: *Viewporter,
    /// The bound wl_surface; null once the surface died (inert).
    surface: ?*surface_mod.Surface,
    res: *server.wp.Viewport,
    state: ViewportState,
    /// Detaches on surface death (and on resource death while the
    /// surface lives): a freed link must not stay in the surface's
    /// destroy listener list.
    destroy_listener: wire.Listener(*surface_mod.Surface),
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
            vres.* = .{
                .vp = vp,
                .surface = surface,
                .res = res,
                .state = .{},
                .destroy_listener = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroy),
            };
            vp.objects.append(vp.allocator, vres) catch {
                vp.allocator.destroy(vres);
                res.destroy();
                viewporter.postNoMemory();
                return;
            };
            res.setHandler(*ViewportRes, viewportRequest, viewportDestroy, vres);
            // The viewport outlives the surface: track its death so the
            // exists check cannot false-positive on a recycled address
            // and later requests post no_surface instead of dereferencing
            // freed memory.
            surface.events.destroy.add(&vres.destroy_listener);
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
            // Guard: the surface may have died since get_viewport; only
            // destroy is legal on an inert viewport (viewporter.xml).
            const s = vres.surface orelse {
                res.postError(.no_surface, "wp_viewport set after wl_surface destroyed");
                return;
            };
            // F-AX-11 moves the pending writes to s.pending.viewport; the
            // state is recorded on the resource until then.
            _ = s;
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
            const s = vres.surface orelse {
                res.postError(.no_surface, "wp_viewport set after wl_surface destroyed");
                return;
            };
            if (r.width == -1 and r.height == -1) {
                vres.state.dst = null;
                s.viewport_dst = null;
                return;
            }
            if (r.width <= 0 or r.height <= 0) {
                res.postError(.bad_value, "wp_viewport.set_destination: non-positive size");
                return;
            }
            vres.state.dst = .{ .w = r.width, .h = r.height };
            s.viewport_dst = .{ .w = r.width, .h = r.height };
        },
    }
}

/// The wl_surface died: detach the listener (a later viewportDestroy
/// must not touch the dead surface's listener list), prune the exists
/// check (a recycled address must not false-positive), and mark the
/// object inert (requests post no_surface). The viewport resource stays
/// alive until the client destroys it.
fn onSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), _: *surface_mod.Surface) void {
    const vres: *ViewportRes = @fieldParentPtr("destroy_listener", listener);
    vres.destroy_listener.link.remove();
    const vp = vres.vp;
    const idx = std.mem.indexOfScalar(*ViewportRes, vp.objects.items, vres) orelse 0;
    if (idx < vp.objects.items.len and vp.objects.items[idx] == vres) {
        _ = vp.objects.orderedRemove(idx);
    }
    vres.surface = null;
}

fn viewportDestroy(res: *server.wp.Viewport, vres: *ViewportRes) void {
    _ = res;
    const vp = vres.vp;
    // Resource-first death: the surface lives, so detach the link before
    // the resource is freed. Surface-first death already detached it in
    // onSurfaceDestroy (the link is then in the detached state, and
    // remove() on a detached link would deref null).
    if (vres.destroy_listener.link.prev != null) vres.destroy_listener.link.remove();
    const idx = std.mem.indexOfScalar(*ViewportRes, vp.objects.items, vres) orelse 0;
    if (idx < vp.objects.items.len and vp.objects.items[idx] == vres) {
        _ = vp.objects.orderedRemove(idx);
    }
    vp.allocator.destroy(vres);
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/xdg.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    viewporter_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wp_viewporter")) {
                    data.viewporter_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// A full compositor + viewporter + in-memory client, for wire
/// roundtrips (xdg.zig TestServer pattern).
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    viewporter: ?*Viewporter = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wp_viewporter: ?*client.wp.Viewporter = null,

    /// Heap-allocated (the `io` pointer must outlive the stack frame).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.viewporter = try Viewporter.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.viewporter) |v| v.deinit();

        // In-memory client connection: one socketpair end for the server,
        // the other for the client library.
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        // Round 1: registry + global announcements.
        const registry = try ts.c_display.?.getRegistry();
        var capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
        try ts.pump();
        if (capture.compositor_name == null or capture.viewporter_name == null) {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor and wp_viewporter.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wp_viewporter = try registry.bind(capture.viewporter_name.?, client.wp.Viewporter, 1);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.viewporter) |v| v.deinit();
        if (ts.compositor) |c| c.deinit();
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
                // Protocol error or disconnect: the server has already
                // destroyed its client (dangling) — forget it for deinit.
                ts.client = null;
                return error.ClientDispatchFailed;
            }
        }
    }
};

test "surface destroy makes the viewport inert: set_destination posts no_surface" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_viewport = try ts.wp_viewporter.?.getViewport(wl_surface);
    try ts.pump();

    // Server side: one tracked viewport bound to the live surface.
    try std.testing.expectEqual(@as(usize, 1), ts.viewporter.?.objects.items.len);

    // Kill the wl_surface; the wp_viewport resource stays alive but is
    // pruned from the exists-check list and marked inert.
    wl_surface.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.viewporter.?.objects.items.len);

    // viewport_exists stays correct: a new surface binds a fresh
    // viewport without a false positive on the dead entry.
    const wl_surface_b = try ts.wl_compositor.?.createSurface();
    _ = try ts.wp_viewporter.?.getViewport(wl_surface_b);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.viewporter.?.objects.items.len);

    // A request on the dead surface's viewport posts no_surface (error
    // code 3) instead of dereferencing the freed Surface; the protocol
    // error kills the client, so the pump fails.
    c_viewport.setDestination(100, 100);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 3), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "destroying the viewport after the surface posts no double free" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_viewport = try ts.wp_viewporter.?.getViewport(wl_surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.viewporter.?.objects.items.len);

    // Surface-first death: onSurfaceDestroy detaches the link and prunes.
    wl_surface.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.viewporter.?.objects.items.len);

    // Resource death after the surface: viewportDestroy must not
    // double-remove the already-detached listener link, and must free
    // the bookkeeping exactly once. Clean teardown (defer ts.deinit())
    // under the test allocator would catch a leak or double free.
    c_viewport.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.viewporter.?.objects.items.len);
}
