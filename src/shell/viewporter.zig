//! wp_viewporter (stable/viewporter): lets clients crop and scale a
//! wl_surface's content via a per-surface wp_viewport.
//!
//! Scope: the viewporter global + per-surface wp_viewport objects. The
//! crop/scale state is double-buffered (F-AX-11): set_source and
//! set_destination write the surface's PENDING viewport state, applied
//! atomically by the next wl_surface.commit (the surface size becomes
//! the dst size, else the src rect size, else the buffer-derived size).
//! The source is validated at commit (F-AX-12): a fractional source
//! without a destination raises bad_size; a source extending past the
//! attached buffer's surface size raises out_of_buffer; both clear the
//! pending crop so the aborting commit applies no invalid state. The
//! committed viewport also crops the scene node's texture (surface-local
//! coordinates, scale-1 pass-through in this renderer).
//!
//! A wp_viewport outlives its wl_surface: surface destroy detaches the
//! destroy + commit listeners, prunes the exists-check list, and marks
//! the object inert. Every request except destroy then posts no_surface
//! on the viewport resource (viewporter.xml); destroying the viewport
//! after the surface is a clean no-op. Destroying the viewport while the
//! surface lives resets the pending crop/scale so the next commit unsets
//! it.
//!
//! foot requires the viewporter (its wayland.c warns "compositor does not
//! implement fractional scaling" unless BOTH wp_fractional_scale and
//! wp_viewporter are present). At scale 1 foot uses an identity viewport
//! (full source, destination == buffer size), so the surface size is
//! unchanged in practice.

const std = @import("std");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const geom = @import("../utils/geom.zig");
const surface_mod = @import("../compositor/surface.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "viewporter";

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
    /// Detaches on surface death (and on resource death while the
    /// surface lives): a freed link must not stay in the surface's
    /// destroy listener list.
    destroy_listener: wire.Listener(*surface_mod.Surface),
    /// Commit-time source validation (F-AX-12): the pending crop is
    /// checked on every wl_surface.commit (bad_size / out_of_buffer).
    /// Same detach rules as destroy_listener.
    client_commit_listener: wire.Listener(*surface_mod.Surface),
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
                .destroy_listener = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroy),
                .client_commit_listener = wire.Listener(*surface_mod.Surface).init(onSurfaceClientCommit),
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
            // Validate the pending crop at commit time (F-AX-12): the
            // source must be integral without a destination and inside
            // the attached buffer's surface size.
            surface.events.client_commit.add(&vres.client_commit_listener);
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
            const sx = r.x.toDouble();
            const sy = r.y.toDouble();
            const sw = r.width.toDouble();
            const sh = r.height.toDouble();
            // All of x,y,w,h == -1 unsets; negative coords or non-positive
            // size is bad_value. Out-of-buffer is checked at commit (the
            // buffer may change).
            if (sx == -1 and sy == -1 and sw == -1 and sh == -1) {
                s.pending.viewport.has_src = false;
            } else if (sx < 0 or sy < 0 or sw <= 0 or sh <= 0) {
                res.postError(.bad_value, "wp_viewport.set_source: negative coords or non-positive size");
                return;
            } else {
                s.pending.viewport.has_src = true;
            }
            s.pending.viewport.src = .{ .x = sx, .y = sy, .width = sw, .height = sh };
            // Double-buffered: applied by the next wl_surface.commit
            // (wlroots wlr_viewporter.c:63-107).
            s.pending.committed.viewport = true;
        },
        .set_destination => |r| {
            const s = vres.surface orelse {
                res.postError(.no_surface, "wp_viewport set after wl_surface destroyed");
                return;
            };
            if (r.width == -1 and r.height == -1) {
                s.pending.viewport.has_dst = false;
            } else if (r.width <= 0 or r.height <= 0) {
                res.postError(.bad_value, "wp_viewport.set_destination: non-positive size");
                return;
            } else {
                s.pending.viewport.has_dst = true;
            }
            s.pending.viewport.dst = .{ .w = r.width, .h = r.height };
            s.pending.committed.viewport = true;
        },
    }
}

/// Commit-time source validation (F-AX-12, wlr_viewporter.c:135-167):
/// the pending crop is checked on every client commit. A fractional
/// source without a destination raises bad_size; a source extending past
/// the pending buffer's surface size raises out_of_buffer. post_error is
/// fatal (the client dies), so clearing the pending crop keeps the
/// aborting commit from applying an invalid state (wlroots'
/// wlr_surface_reject_pending clears pending state; the client dies
/// either way).
fn onSurfaceClientCommit(listener: *wire.Listener(*surface_mod.Surface), s: *surface_mod.Surface) void {
    const vres: *ViewportRes = @fieldParentPtr("client_commit_listener", listener);
    const vp = &s.pending.viewport;
    // bad_size: fractional src with no dst (wlr_viewporter.c:145-152).
    if (!vp.has_dst and
        (std.math.floor(vp.src.width) != vp.src.width or
            std.math.floor(vp.src.height) != vp.src.height))
    {
        vres.res.postError(.bad_size, "wp_viewport.set_source: fractional source without destination");
        vp.has_src = false;
        vp.has_dst = false;
        return;
    }
    // out_of_buffer: src beyond the pending buffer's surface size
    // (wlr_viewporter.c:135-142, 154-164). Surface size = transformed
    // buffer size / scale; validatePending guarantees integrality.
    if (vp.has_src) {
        if (s.pending.buffer) |b| {
            const size = s.pending.transform.transformedSize(b.width, b.height);
            const w: f64 = @floatFromInt(@divTrunc(size.w, s.pending.scale));
            const h: f64 = @floatFromInt(@divTrunc(size.h, s.pending.scale));
            if (vp.src.x + vp.src.width > w or vp.src.y + vp.src.height > h) {
                vres.res.postError(.out_of_buffer, "wp_viewport.set_source: source out of buffer bounds");
                vp.has_src = false;
                vp.has_dst = false;
                return;
            }
        } // NULL buffer: out_of_buffer is NOT raised (viewporter.xml).
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
    vres.client_commit_listener.link.remove();
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
    // Destroying the viewport unsets the pending crop/scale: the change
    // applies on the NEXT wl_surface.commit (protocol: "the change will
    // be applied on the next wl_surface.commit"; wlr_viewporter.c:109-111).
    if (vres.surface) |s| {
        s.pending.viewport.has_src = false;
        s.pending.viewport.has_dst = false;
        s.pending.committed.viewport = true;
    }
    // Resource-first death: the surface lives, so detach the links before
    // the resource is freed. Surface-first death already detached them in
    // onSurfaceDestroy (the links are then in the detached state, and
    // remove() on a detached link would deref null).
    if (vres.destroy_listener.link.prev != null) vres.destroy_listener.link.remove();
    if (vres.client_commit_listener.link.prev != null) vres.client_commit_listener.link.remove();
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
const scene_mod = @import("../scene/scene.zig");
const surface_node_mod = @import("../scene/surface_node.zig");
const buffer_mod = @import("../buffers/buffer.zig");
const texture_mod = @import("../renderer/texture.zig");

const Texture = texture_mod.Texture;
const Buffer = buffer_mod.Buffer;

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
    /// Scene + tracked surface nodes: the crop/dst assertions read the
    /// surface's buffer node (dst_width/dst_height/src).
    scene: ?*scene_mod.Scene = null,
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
        ts.scene = try scene_mod.Scene.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.scene) |sc| sc.deinit();

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
        if (ts.scene) |sc| sc.deinit();
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.viewporter) |v| v.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// The shared `test_pump.roundtrip` (client flush -> server dispatch ->
    /// server flush) plus a client dispatch, which runs only when the server
    /// actually wrote to the socket. Never blocks.
    fn pump(ts: *TestServer) !void {
        try test_pump.roundtrip(ts.c_display.?, ts.display.?, 0);
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

// SurfaceNode test impl: import the surface's buffer as a fabricated
// texture (surface_node.zig test fixture pattern).
const TestCtx = struct {
    allocator: std.mem.Allocator,
    imports: usize = 0,
    destroyed: usize = 0,
};

const FakeTexData = struct {
    allocator: std.mem.Allocator,
    destroyed: bool = false,
};

fn fakeTexDestroy(texture: *Texture) void {
    const data: *FakeTexData = @ptrCast(@alignCast(texture.data));
    data.destroyed = true;
    const allocator = data.allocator;
    allocator.destroy(data);
    allocator.destroy(texture);
}

const fake_tex_impl: Texture.Impl = .{ .destroy = fakeTexDestroy };

fn testImport(ctx: *anyopaque, _: *surface_mod.Surface, buf: *Buffer) ?*Texture {
    const self: *TestCtx = @ptrCast(@alignCast(ctx));
    self.imports += 1;
    const data = self.allocator.create(FakeTexData) catch return null;
    data.* = .{ .allocator = self.allocator };
    const tex = self.allocator.create(Texture) catch {
        self.allocator.destroy(data);
        return null;
    };
    tex.* = .{ .impl = &fake_tex_impl, .data = data, .width = buf.width, .height = buf.height };
    return tex;
}

fn testDestroyed(ctx: *anyopaque, _: *surface_mod.Surface) void {
    const self: *TestCtx = @ptrCast(@alignCast(ctx));
    self.destroyed += 1;
}

const test_impl: surface_node_mod.Impl = .{
    .import = testImport,
    .destroyed = testDestroyed,
};

/// 64x64 fabricated buffer for the crop tests (testBuffer defaults to
/// 10x10).
fn testBuffer64(allocator: std.mem.Allocator, b: *Buffer) void {
    surface_mod.testBuffer(allocator, b);
    b.width = 64;
    b.height = 64;
}

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

test "set_destination is double-buffered and cleared by viewport destroy" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_viewport = try ts.wp_viewporter.?.getViewport(wl_surface);
    try ts.pump();

    // Track the server-side surface so the node reflects its size.
    const s = ts.viewporter.?.objects.items[0].surface.?;
    var ctx: TestCtx = .{ .allocator = allocator };
    const sn = try surface_node_mod.trackSurface(ts.scene.?, s, &test_impl, &ctx);

    // First commit (no viewport state): the node is buffer-derived 10x10.
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer); // 10x10
    s.attachBuffer(&buffer);
    s.commit();
    try std.testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_width);
    try std.testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_height);

    // set_destination is double-buffered: it lands in PENDING only; the
    // committed state and the node are untouched before the commit.
    c_viewport.setDestination(200, 100);
    try ts.pump();
    try std.testing.expect(s.pending.viewport.has_dst);
    try std.testing.expectEqual(geom.Size{ .w = 200, .h = 100 }, s.pending.viewport.dst);
    try std.testing.expect(!s.current.viewport.has_dst);
    try std.testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_width);

    // The next commit applies it: current + node dst become 200x100.
    var buffer2: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer2);
    s.attachBuffer(&buffer2);
    s.commit();
    try std.testing.expect(s.current.viewport.has_dst);
    try std.testing.expectEqual(@as(i32, 200), sn.node.?.kind.buffer.dst_width);
    try std.testing.expectEqual(@as(i32, 100), sn.node.?.kind.buffer.dst_height);

    // A commit without a viewport request keeps the dst (the F33
    // committed-mask semantics: pending persists, the bit is absent).
    var buffer3: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer3);
    s.attachBuffer(&buffer3);
    s.commit();
    try std.testing.expect(s.current.viewport.has_dst);
    try std.testing.expectEqual(@as(i32, 200), sn.node.?.kind.buffer.dst_width);

    // Destroying the viewport resets PENDING; the committed dst still
    // applies until the next commit carries the reset bit.
    c_viewport.destroy();
    try ts.pump();
    try std.testing.expect(!s.pending.viewport.has_dst);
    try std.testing.expect(s.current.viewport.has_dst);
    try std.testing.expectEqual(@as(i32, 200), sn.node.?.kind.buffer.dst_width);

    // The commit after the destroy applies the reset: back to 10x10.
    var buffer4: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer4);
    s.attachBuffer(&buffer4);
    s.commit();
    try std.testing.expect(!s.current.viewport.has_dst);
    try std.testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_width);
    try std.testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_height);
}

test "destroy clears only at the next commit" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_viewport = try ts.wp_viewporter.?.getViewport(wl_surface);
    try ts.pump();

    const s = ts.viewporter.?.objects.items[0].surface.?;
    var ctx: TestCtx = .{ .allocator = allocator };
    const sn = try surface_node_mod.trackSurface(ts.scene.?, s, &test_impl, &ctx);

    c_viewport.setDestination(200, 100);
    try ts.pump();
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try std.testing.expectEqual(@as(i32, 200), sn.node.?.kind.buffer.dst_width);

    // The destroy alone changes nothing committed: current dst and the
    // node size hold until the NEXT commit delivers the reset.
    c_viewport.destroy();
    try ts.pump();
    try std.testing.expect(s.current.viewport.has_dst);
    try std.testing.expectEqual(@as(i32, 200), sn.node.?.kind.buffer.dst_width);

    var buffer2: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer2);
    s.attachBuffer(&buffer2);
    s.commit();
    try std.testing.expect(!s.current.viewport.has_dst);
    try std.testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_width);
    try std.testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_height);
}

test "out_of_buffer: source outside the buffer is rejected at commit" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_viewport = try ts.wp_viewporter.?.getViewport(wl_surface);
    try ts.pump();

    const s = ts.viewporter.?.objects.items[0].surface.?;
    var ctx: TestCtx = .{ .allocator = allocator };
    const sn = try surface_node_mod.trackSurface(ts.scene.?, s, &test_impl, &ctx);

    // src (0,0,100,100) on a 64x64 buffer: beyond the content area.
    c_viewport.setSource(
        client.wl.Fixed.fromInt(0),
        client.wl.Fixed.fromInt(0),
        client.wl.Fixed.fromInt(100),
        client.wl.Fixed.fromInt(100),
    );
    try ts.pump();
    try std.testing.expect(s.pending.viewport.has_src);

    // The commit validates: out_of_buffer is posted, the invalid crop is
    // cleared, and the commit itself still applies the buffer.
    var buffer: Buffer = undefined;
    testBuffer64(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try std.testing.expect(!s.current.viewport.has_src);
    try std.testing.expect(!s.current.viewport.has_dst);
    try std.testing.expect(s.buffer == &buffer);
    try std.testing.expect(sn.node.?.kind.buffer.src == null);

    // The error is fatal: the next dispatch kills the client (error code
    // 2 = out_of_buffer).
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 2), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "bad_size: fractional source without destination" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_viewport = try ts.wp_viewporter.?.getViewport(wl_surface);
    try ts.pump();

    const s = ts.viewporter.?.objects.items[0].surface.?;
    var ctx: TestCtx = .{ .allocator = allocator };
    _ = try surface_node_mod.trackSurface(ts.scene.?, s, &test_impl, &ctx);

    // Fractional src width (10.5) with no destination: bad_size at commit.
    c_viewport.setSource(
        client.wl.Fixed.fromInt(0),
        client.wl.Fixed.fromInt(0),
        client.wl.Fixed.fromDouble(10.5),
        client.wl.Fixed.fromInt(10),
    );
    try ts.pump();

    var buffer: Buffer = undefined;
    testBuffer64(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try std.testing.expect(!s.current.viewport.has_src);
    try std.testing.expect(!s.current.viewport.has_dst);

    // Error code 1 = bad_size.
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "crop is applied to the scene node" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_viewport = try ts.wp_viewporter.?.getViewport(wl_surface);
    try ts.pump();

    const s = ts.viewporter.?.objects.items[0].surface.?;
    var ctx: TestCtx = .{ .allocator = allocator };
    const sn = try surface_node_mod.trackSurface(ts.scene.?, s, &test_impl, &ctx);

    // A real crop: src (8,8,32,32) scaled to dst 32x32 on a 64x64 buffer.
    c_viewport.setSource(
        client.wl.Fixed.fromInt(8),
        client.wl.Fixed.fromInt(8),
        client.wl.Fixed.fromInt(32),
        client.wl.Fixed.fromInt(32),
    );
    c_viewport.setDestination(32, 32);
    try ts.pump();

    var buffer: Buffer = undefined;
    testBuffer64(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();

    // No protocol error: the connection survives a follow-up roundtrip.
    try ts.pump();
    const bn = sn.node.?.kind.buffer;
    try std.testing.expectEqual(geom.FRect{ .x = 8, .y = 8, .width = 32, .height = 32 }, bn.src.?);
    try std.testing.expectEqual(@as(i32, 32), bn.dst_width);
    try std.testing.expectEqual(@as(i32, 32), bn.dst_height);
}
