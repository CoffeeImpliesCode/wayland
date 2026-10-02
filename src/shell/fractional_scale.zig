//! wp_fractional_scale_manager_v1 (staging/fractional-scale-v1): lets
//! clients render at the compositor's preferred fractional scale.
//!
//! Scope: the manager global + per-surface wp_fractional_scale_v1
//! objects. The compositor advertises a preferred_scale (the numerator
//! of a fraction with denominator 120) once set via setPreferredScale;
//! until then no event is sent (wlroots sends only after a scale was
//! notified, wlr_fractional_scale_v1.c:144-146). This server runs at
//! scale 1, so main.zig sets 120 — the event still silences clients
//! that gate on the protocol (foot) and gives them their preferred
//! render path.
//!
//! Cross-module contract: the manager binds per client;
//! get_fractional_scale creates a wp_fractional_scale_v1 for a
//! wl_surface; a surface may only have one such object
//! (fractional_scale_exists error). Surface teardown detaches the
//! destroy listener and prunes the entry — the state goes inert (its
//! surface is nulled; the only request, destroy, never dereferences
//! it). The resource destroy frees the state (explicit
//! fractional_scale.destroy or client teardown; the resource user
//! data carries the state).

const std = @import("std");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const surface_mod = @import("../compositor/surface.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "fractional_scale";

pub const FractionalScale = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The manager global, for teardown.
    global: ?*wire.Global = null,
    /// Per-surface fractional_scale objects, for the exists check.
    objects: std.ArrayList(*ScaleState) = .empty,
    /// The compositor's preferred scale (numerator over 120); null until
    /// setPreferredScale — no preferred_scale event is sent before that
    /// (wlroots wlr_fractional_scale_v1.c:144-146).
    preferred_scale: ?u32 = null,

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

    /// Advertise the compositor's preferred scale (numerator over 120)
    /// and notify every existing per-surface object immediately
    /// (wlroots notify_scale). The value is retained: later
    /// get_fractional_scale binds send it on creation.
    pub fn setPreferredScale(self: *FractionalScale, scale_numerator: u32) void {
        self.preferred_scale = scale_numerator;
        for (self.objects.items) |st| st.res.sendPreferredScale(scale_numerator);
    }
};

/// Per-wl_surface fractional-scale state.
const ScaleState = struct {
    fs: *FractionalScale,
    /// The compositor's Surface the object was created for; null once
    /// the surface is destroyed (the state goes inert — the only
    /// request, destroy, never dereferences it).
    surface: ?*surface_mod.Surface,
    /// The wp_fractional_scale_v1 resource.
    res: *server.wp.FractionalScaleV1,
    /// Surface-destroy listener: wl_surface death prunes the entry
    /// (the exists check must not false-positive on a recycled address)
    /// and marks the state inert. The object outlives the surface,
    /// exactly like presentation Feedback.
    destroy_listener: wire.Listener(*surface_mod.Surface),
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
            st.* = .{
                .fs = fs,
                .surface = surface,
                .res = res,
                .destroy_listener = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroy),
            };
            fs.objects.append(fs.allocator, st) catch {
                fs.allocator.destroy(st);
                res.destroy();
                manager.postNoMemory();
                return;
            };
            res.setHandler(*ScaleState, scaleRequest, scaleDestroy, st);
            // Track the surface: wl_surface death must prune this entry
            // and mark the state inert, since the object outlives the
            // surface (presentation Feedback pattern).
            surface.events.destroy.add(&st.destroy_listener);
            // Advertise the compositor's preferred scale once set; the
            // default is unset, which sends nothing (wlroots :144-146).
            if (fs.preferred_scale) |scale| {
                res.sendPreferredScale(scale);
                log.debug("fractional scale for surface@{d}: {d}/120", fs.io, fs.log_cfg, log_tag, .{
                    surface.resource.getId(),
                    scale,
                });
            }
        },
    }
}

fn fractionalScaleDestroy(manager: *server.wp.FractionalScaleManagerV1, fs: *FractionalScale) void {
    _ = manager;
    _ = fs;
    // The manager resource dies with the client teardown; per-surface
    // states are freed by their own resource destroy handlers.
}

/// The wl_surface was destroyed: detach our listener (a later
/// scaleDestroy must not touch the dead surface's listener list), prune
/// the entry (the exists check must not false-positive on a recycled
/// address), and mark the state inert. The resource is not destroyed —
/// the client owns it; the only request, destroy, never dereferences
/// the surface.
fn onSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), _: *surface_mod.Surface) void {
    const st: *ScaleState = @fieldParentPtr("destroy_listener", listener);
    st.destroy_listener.link.remove();
    const fs = st.fs;
    const idx = std.mem.indexOfScalar(*ScaleState, fs.objects.items, st) orelse 0;
    if (idx < fs.objects.items.len and fs.objects.items[idx] == st) {
        _ = fs.objects.orderedRemove(idx);
    }
    st.surface = null;
}

fn scaleRequest(res: *server.wp.FractionalScaleV1, request: server.wp.FractionalScaleV1.Request, st: *ScaleState) void {
    _ = st;
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn scaleDestroy(res: *server.wp.FractionalScaleV1, st: *ScaleState) void {
    _ = res;
    // Detach the surface-destroy listener (resource-first death: client
    // teardown or explicit destroy while the surface lives — the freed
    // link must not stay in the surface's listener list before
    // destroy.emit). Surface-first death (onSurfaceDestroy) already
    // removed it; the attached-or-not check makes the second remove a
    // no-op.
    if (st.destroy_listener.link.prev != null and
        st.destroy_listener.link.prev != &st.destroy_listener.link)
    {
        st.destroy_listener.link.remove();
    }
    // Prune the state from the manager's list and free it.
    const fs = st.fs;
    const idx = std.mem.indexOfScalar(*ScaleState, fs.objects.items, st) orelse 0;
    if (idx < fs.objects.items.len and fs.objects.items[idx] == st) {
        _ = fs.objects.orderedRemove(idx);
    }
    fs.allocator.destroy(st);
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/xdg.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    fractional_scale_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wp_fractional_scale_manager_v1")) {
                    data.fractional_scale_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Client-side capture of wp_fractional_scale_v1 events: the compositor
/// advertises its preferred scale once set (setPreferredScale), sending
/// the event to live objects immediately and to new binds on
/// get_fractional_scale.
const ScaleEvents = struct {
    preferred_scales: u32 = 0,

    fn listener(_: *client.wp.FractionalScaleV1, event: client.wp.FractionalScaleV1.Event, self: *ScaleEvents) void {
        switch (event) {
            .preferred_scale => self.preferred_scales += 1,
        }
    }
};

/// A compositor + fractional-scale manager + in-memory client, for wire
/// roundtrips. The client binds wl_compositor (to create wl_surfaces)
/// and wp_fractional_scale_manager_v1.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    fs: ?*FractionalScale = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_fs_manager: ?*client.wp.FractionalScaleManagerV1 = null,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor and manager all store it).
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
        // The internal wl_shm global (libwayland) must exist before the
        // client's first registry roundtrip so it can bind it for buffers.
        try ts.display.?.initShm();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.fs = try FractionalScale.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.fs) |fs| fs.deinit();

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
        if (capture.compositor_name == null or capture.fractional_scale_name == null) {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor (for wl_surface) and the
        // fractional-scale manager.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wl_fs_manager = try registry.bind(capture.fractional_scale_name.?, client.wp.FractionalScaleManagerV1, 1);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers (the
        // scaleDestroy for every outstanding object) must run while the
        // fractional-scale module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.fs) |fs| fs.deinit();
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

test "surface destroy prunes the fractional-scale entry" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    // The compositor sets its scale up front (like main.zig), so binds
    // advertise it immediately.
    ts.fs.?.setPreferredScale(120);

    // Surface A binds a fractional-scale object; the compositor
    // advertises its preferred scale immediately.
    const surface_a = try ts.wl_compositor.?.createSurface();
    var events_a: ScaleEvents = .{};
    const fs_obj_a = try ts.wl_fs_manager.?.getFractionalScale(surface_a);
    fs_obj_a.setListener(*ScaleEvents, ScaleEvents.listener, &events_a);
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 1), events_a.preferred_scales);
    try std.testing.expectEqual(@as(usize, 1), ts.fs.?.objects.items.len);

    // Destroy surface A's wl_surface: the surface-destroy listener must
    // detach, prune the entry and mark the state inert.
    surface_a.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.fs.?.objects.items.len);
    // The state is freed only when the client destroys its
    // wp_fractional_scale_v1 (or the connection dies) — scaleDestroy
    // must tolerate the already-pruned, already-detached state.
    fs_obj_a.destroy();
    try ts.pump();

    // Surface B (the allocator may recycle surface A's address) binds a
    // fresh object: the exists check must not false-positive, the client
    // must receive no fractional_scale_exists error (the connection
    // survives — pump() below would fail otherwise) and the new object
    // gets its event.
    const surface_b = try ts.wl_compositor.?.createSurface();
    var events_b: ScaleEvents = .{};
    const fs_obj_b = try ts.wl_fs_manager.?.getFractionalScale(surface_b);
    fs_obj_b.setListener(*ScaleEvents, ScaleEvents.listener, &events_b);
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 1), events_b.preferred_scales);
    try std.testing.expectEqual(@as(usize, 1), ts.fs.?.objects.items.len);

    // Teardown (deinit) exercises the remaining paths under the testing
    // allocator: no leak, no double free, no use-after-free.
}

test "preferred_scale is not sent until set" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // The compositor never set a scale: get_fractional_scale must not
    // emit preferred_scale (wlroots wlr_fractional_scale_v1.c:144-146).
    const surface = try ts.wl_compositor.?.createSurface();
    var events: ScaleEvents = .{};
    const fs_obj = try ts.wl_fs_manager.?.getFractionalScale(surface);
    fs_obj.setListener(*ScaleEvents, ScaleEvents.listener, &events);
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 0), events.preferred_scales);
    try std.testing.expectEqual(@as(usize, 1), ts.fs.?.objects.items.len);
}

test "setPreferredScale notifies existing objects and later binds" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Two surfaces bind before any scale is set: no events yet.
    const surface_a = try ts.wl_compositor.?.createSurface();
    var events_a: ScaleEvents = .{};
    const obj_a = try ts.wl_fs_manager.?.getFractionalScale(surface_a);
    obj_a.setListener(*ScaleEvents, ScaleEvents.listener, &events_a);
    const surface_b = try ts.wl_compositor.?.createSurface();
    var events_b: ScaleEvents = .{};
    const obj_b = try ts.wl_fs_manager.?.getFractionalScale(surface_b);
    obj_b.setListener(*ScaleEvents, ScaleEvents.listener, &events_b);
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 0), events_a.preferred_scales);
    try std.testing.expectEqual(@as(u32, 0), events_b.preferred_scales);

    // Setting the scale notifies both live objects (wlroots notify_scale).
    ts.fs.?.setPreferredScale(120);
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 1), events_a.preferred_scales);
    try std.testing.expectEqual(@as(u32, 1), events_b.preferred_scales);

    // A later bind sends the retained value immediately.
    const surface_c = try ts.wl_compositor.?.createSurface();
    var events_c: ScaleEvents = .{};
    const obj_c = try ts.wl_fs_manager.?.getFractionalScale(surface_c);
    obj_c.setListener(*ScaleEvents, ScaleEvents.listener, &events_c);
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 1), events_c.preferred_scales);
}
