//! zxdg_decoration_manager_v1 (unstable/xdg-decoration): the
//! zxdg_decoration_manager_v1 global plus the xdg_toplevel_decoration
//! state machine.
//!
//! Semantics (audit-verified vs wlroots types/wlr_xdg_decoration_v1.c,
//! smithay shell/xdg/decoration.rs, KWin xdgdecoration_v1.cpp +
//! xdgshellwindow.cpp; XML ground truth
//! protocols/wayland-protocols/unstable/xdg-decoration/
//! xdg-decoration-unstable-v1.xml):
//! - (a) get_toplevel_decoration on a toplevel that already committed a
//!   buffer posts unconfigured_buffer=0 (v1 behavior; v2+ relaxes this).
//! - (b) a second decoration object on the same toplevel posts
//!   already_constructed=1.
//! - (c) a toplevel destroyed before its decoration posts orphaned=2 on
//!   the decoration resource (the client must destroy the decoration
//!   first). The decoration module tracks the toplevel's lifetime through
//!   XdgToplevel.events.destroy.
//! - (d) set_mode with a value outside {client_side, server_side} posts
//!   invalid_mode=3. [Divergence: the XML mandates this error but
//!   wlroots/smithay/KWin do not raise it — this implementation does,
//!   per the XML. See notes/129.]
//! - (e) set_mode/unset_mode are forwarded to the compositor as
//!   `events.request_mode`; the compositor replies by calling
//!   Decoration.sendConfigure (re-sent on every set_mode/unset_mode).
//!   No initial configure is sent: a client that never sets a mode draws
//!   client-side (the XML's default).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const display_mod = @import("../core/display.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const xdg_mod = @import("xdg.zig");

const log_tag = "xdg_decoration";

/// set_mode/unset_mode arrived; the compositor replies with
/// Decoration.sendConfigure. mode == null for unset_mode.
pub const RequestMode = struct {
    decoration: *Decoration,
    mode: ?server.zxdg.ToplevelDecorationV1.Mode,
};

pub const Decoration = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    manager: *XdgDecoration,
    resource: *server.zxdg.ToplevelDecorationV1,
    /// The decorated toplevel. Null once the toplevel died (orphaned path)
    /// — invariant: toplevel == null implies the destroy listener is no
    /// longer attached, so the destroy handler never touches freed memory.
    toplevel: ?*xdg_mod.XdgToplevel,
    /// The toplevel's destroy listener (orphaned detection).
    destroy_listener: wire.Listener(*xdg_mod.XdgToplevel),

    /// The compositor's reply to a request_mode: configure the effective
    /// decoration mode.
    pub fn sendConfigure(dec: *Decoration, mode: server.zxdg.ToplevelDecorationV1.Mode) void {
        dec.resource.sendConfigure(mode);
    }
};

// ---------------------------------------------------------------------------
// XdgDecoration: the zxdg_decoration_manager_v1 global.
// ---------------------------------------------------------------------------

pub const XdgDecoration = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The xdg shell whose toplevels this manager decorates (the toplevel
    /// destroy tracking hooks XdgToplevel.events.destroy).
    shell: *xdg_mod.XdgShell,
    /// The zxdg_decoration_manager_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// All live decorations, in creation order.
    decorations: std.ArrayList(*Decoration),
    events: struct {
        request_mode: wire.Signal(*RequestMode),
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        shell: *xdg_mod.XdgShell,
    ) !*XdgDecoration {
        const deco = try allocator.create(XdgDecoration);
        errdefer allocator.destroy(deco);
        deco.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .shell = shell,
            .decorations = .empty,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        errdefer deco.decorations.deinit(allocator);
        deco.events.request_mode.init();

        // Register zxdg_decoration_manager_v1 at the maximum version we
        // implement (v1: the strict unconfigured_buffer rule).
        deco.global = try display.addGlobal(
            server.zxdg.DecorationManagerV1,
            *XdgDecoration,
            decorationBind,
            server.zxdg.DecorationManagerV1.generated_version,
            deco,
        );
        return deco;
    }

    pub fn deinit(self: *XdgDecoration) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the wire resources cascades through their destroy
        // handlers, which remove entries from the list and free the objects
        // (and detach their toplevel destroy listeners).
        while (self.decorations.items.len > 0) self.decorations.items[0].resource.destroy();
        self.decorations.deinit(allocator);
        // The decoration global itself is owned by the display's registry.
        allocator.destroy(self);
    }
};

fn decorationBind(client_wire: *wire.Client, deco: *XdgDecoration, version: u32, id: u32) void {
    const manager_res = server.zxdg.DecorationManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    manager_res.setHandler(*XdgDecoration, managerRequest, null, deco);
}

fn managerRequest(
    manager_res: *server.zxdg.DecorationManagerV1,
    request: server.zxdg.DecorationManagerV1.Request,
    deco: *XdgDecoration,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => manager_res.destroy(),
        .get_toplevel_decoration => |r| {
            const res = server.zxdg.ToplevelDecorationV1.create(
                manager_res.getClient(),
                manager_res.getVersion(),
                r.id,
            ) catch {
                manager_res.postNoMemory();
                return;
            };
            getToplevelDecoration(deco, manager_res, res, r.toplevel);
        },
    }
}

/// zxdg_decoration_manager_v1.get_toplevel_decoration. Validation errors
/// post on the NEW decoration resource (the error enum lives on
/// xdg_toplevel_decoration; wlroots posts there too).
fn getToplevelDecoration(
    deco: *XdgDecoration,
    manager_res: *server.zxdg.DecorationManagerV1,
    res: *server.zxdg.ToplevelDecorationV1,
    toplevel_res: *server.xdg.Toplevel,
) void {
    // The xdg_toplevel resource's user data is the XdgToplevel role
    // object; null means the toplevel was already destroyed.
    const toplevel_ud = toplevel_res.getUserData() orelse {
        res.postError(.orphaned, "xdg_toplevel_decoration created after its xdg_toplevel was destroyed");
        res.destroy();
        return;
    };
    const toplevel: *xdg_mod.XdgToplevel = @ptrCast(@alignCast(toplevel_ud));
    // Model decision (a), v1 semantics: a toplevel that already committed a
    // buffer must not be decorated (wlroots posts unconfigured_buffer on
    // the decoration resource; v2+ allows it).
    if (toplevel.xdg_surface.surface.buffer != null) {
        res.postError(.unconfigured_buffer, "xdg_toplevel_decoration must not be created after a buffer was committed");
        res.destroy();
        return;
    }
    // Model decision (b): one decoration per toplevel.
    for (deco.decorations.items) |existing| {
        if (existing.toplevel == toplevel) {
            res.postError(.already_constructed, "xdg_toplevel already has an xdg_toplevel_decoration");
            res.destroy();
            return;
        }
    }
    const dec = deco.allocator.create(Decoration) catch {
        res.destroy();
        manager_res.postNoMemory();
        return;
    };
    dec.* = .{
        .allocator = deco.allocator,
        .io = deco.io,
        .log_cfg = deco.log_cfg,
        .manager = deco,
        .resource = res,
        .toplevel = toplevel,
        .destroy_listener = wire.Listener(*xdg_mod.XdgToplevel).init(onToplevelDestroy),
    };
    res.setHandler(*Decoration, decorationRequest, decorationDestroy, dec);
    // Model decision (c): the module needs the toplevel's lifetime to post
    // orphaned when the toplevel dies first.
    toplevel.events.destroy.add(&dec.destroy_listener);
    deco.decorations.append(deco.allocator, dec) catch {
        dec.destroy_listener.link.remove();
        dec.toplevel = null; // the listener is detached; decorationDestroy skips it
        res.destroy();
        manager_res.postNoMemory();
        return;
    };
    log.debug("new toplevel decoration (mode unset; client-side default)", deco.io, deco.log_cfg, log_tag, .{});
}

fn decorationRequest(
    dec_res: *server.zxdg.ToplevelDecorationV1,
    request: server.zxdg.ToplevelDecorationV1.Request,
    dec: *Decoration,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => dec_res.destroy(),
        .set_mode => |r| {
            // Model decision (d): the XML mandates invalid_mode for any mode
            // outside {client_side, server_side}; wlroots/smithay/KWin do
            // not raise it, this implementation does.
            if (r.mode != .client_side and r.mode != .server_side) {
                dec_res.postError(.invalid_mode, "set_mode: mode must be client_side (1) or server_side (2)");
                return;
            }
            emitRequestMode(dec, r.mode);
        },
        .unset_mode => emitRequestMode(dec, null),
    }
}

/// Forward the mode preference to the compositor; it replies with
/// sendConfigure (re-sent on every set_mode/unset_mode, model decision (e)).
fn emitRequestMode(dec: *Decoration, mode: ?server.zxdg.ToplevelDecorationV1.Mode) void {
    var req: RequestMode = .{
        .decoration = dec,
        .mode = mode,
    };
    dec.manager.events.request_mode.emit(&req);
}

fn decorationDestroy(dec_res: *server.zxdg.ToplevelDecorationV1, dec: *Decoration) void {
    _ = dec_res;
    const deco = dec.manager;
    if (std.mem.findScalar(*Decoration, deco.decorations.items, dec)) |i| {
        _ = deco.decorations.swapRemove(i);
    }
    // Invariant: toplevel != null means the destroy listener is still
    // attached (and the toplevel is alive).
    if (dec.toplevel != null) {
        dec.destroy_listener.link.remove();
    }
    deco.allocator.destroy(dec);
}

/// The toplevel died before the decoration (model decision (c)): detach and
/// forget the toplevel first, then post orphaned. The error kills the
/// client; the decoration resource dies with it, and its destroy handler
/// runs later with toplevel == null (no touch of the freed toplevel).
fn onToplevelDestroy(listener: *wire.Listener(*xdg_mod.XdgToplevel), toplevel: *xdg_mod.XdgToplevel) void {
    const dec: *Decoration = @fieldParentPtr("destroy_listener", listener);
    dec.destroy_listener.link.remove();
    dec.toplevel = null;
    _ = toplevel;
    dec.resource.postError(.orphaned, "xdg_toplevel_decoration must be destroyed before its xdg_toplevel");
}

// --- socketpair roundtrip harness (pattern: src/shell/xdg.zig) ------------

const posix = std.posix;

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    wm_base_name: ?u32 = null,
    decoration_manager_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "xdg_wm_base")) {
                    data.wm_base_name = g.name;
                } else if (std.mem.eql(u8, name, "zxdg_decoration_manager_v1")) {
                    data.decoration_manager_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

const DecorationEvents = struct {
    configure_count: usize = 0,
    mode: i32 = 0,

    fn listener(
        dec: *client.zxdg.ToplevelDecorationV1,
        event: client.zxdg.ToplevelDecorationV1.Event,
        data: *DecorationEvents,
    ) void {
        _ = dec;
        switch (event) {
            .configure => |c| {
                data.configure_count += 1;
                data.mode = @intFromEnum(c.mode);
            },
        }
    }
};

const RequestModeCapture = struct {
    count: usize = 0,
    mode: i32 = 0,
    listener: wire.Listener(*RequestMode),

    fn notify(listener: *wire.Listener(*RequestMode), req: *RequestMode) void {
        const cap: *RequestModeCapture = @fieldParentPtr("listener", listener);
        cap.count += 1;
        // The compositor's reply: echo the requested mode back via
        // sendConfigure (the happy-path policy in main.zig is the same,
        // keyed on focus).
        const mode = req.mode orelse .client_side;
        cap.mode = @intFromEnum(mode);
        req.decoration.sendConfigure(mode);
    }
};

/// A full compositor + shell + decoration manager + in-memory client, for
/// wire roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    shell: ?*xdg_mod.XdgShell = null,
    decoration: ?*XdgDecoration = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wm_base: ?*client.xdg.WmBase = null,
    decoration_client: ?*client.zxdg.DecorationManagerV1 = null,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor and shell all store it).
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
        ts.shell = try xdg_mod.XdgShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
        errdefer if (ts.shell) |s| s.deinit();
        ts.decoration = try XdgDecoration.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.shell.?);
        errdefer if (ts.decoration) |d| d.deinit();

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
        if (capture.compositor_name == null or
            capture.wm_base_name == null or
            capture.decoration_manager_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor, xdg_wm_base and the decoration
        // manager.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wm_base = try registry.bind(capture.wm_base_name.?, client.xdg.WmBase, 7);
        ts.decoration_client = try registry.bind(capture.decoration_manager_name.?, client.zxdg.DecorationManagerV1, 1);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers must
        // run while the decoration manager and shell still live.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.decoration) |d| d.deinit();
        if (ts.shell) |s| s.deinit();
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

    /// Create an xdg_toplevel for the test client.
    fn createToplevel(ts: *TestServer) !struct { surface: *client.wl.Surface, toplevel: *client.xdg.Toplevel } {
        const wl_surface = try ts.wl_compositor.?.createSurface();
        const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
        const toplevel = try xdg_surface.getToplevel();
        try ts.pump();
        return .{ .surface = wl_surface, .toplevel = toplevel };
    }
};

test "decoration happy path: get -> set_mode -> request_mode -> configure" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: RequestModeCapture = .{
        .listener = wire.Listener(*RequestMode).init(RequestModeCapture.notify),
    };
    ts.decoration.?.events.request_mode.add(&capture.listener);

    const tl = try ts.createToplevel();
    const dec = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    var dec_events: DecorationEvents = .{};
    dec.setListener(*DecorationEvents, DecorationEvents.listener, &dec_events);
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);

    // set_mode(server_side) -> request_mode fires with the mode -> the
    // compositor (capture) replies with sendConfigure(server_side).
    dec.setMode(.server_side);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(i32, 2), capture.mode); // server_side
    try std.testing.expectEqual(@as(usize, 1), dec_events.configure_count);
    try std.testing.expectEqual(@as(i32, 2), dec_events.mode);

    // unset_mode -> request_mode with no mode -> client_side configure.
    dec.unsetMode();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(@as(i32, 1), capture.mode); // client_side
    try std.testing.expectEqual(@as(usize, 2), dec_events.configure_count);
    try std.testing.expectEqual(@as(i32, 1), dec_events.mode);

    // Client destroys the decoration cleanly.
    dec.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.decoration.?.decorations.items.len);
}

test "decoration second decoration on a toplevel -> already_constructed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const tl = try ts.createToplevel();
    _ = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);

    // Model decision (b): a second decoration object posts
    // already_constructed=1 and the client is killed.
    _ = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "decoration set_mode with invalid mode -> invalid_mode" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const tl = try ts.createToplevel();
    const dec = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try ts.pump();

    // Model decision (d): the XML mandates invalid_mode=3 for any mode
    // outside {1, 2}; wlroots/smithay/KWin do not raise it (documented
    // divergence).
    dec.setMode(@enumFromInt(3));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 3), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "decoration toplevel destroyed first -> orphaned" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const tl = try ts.createToplevel();
    const dec = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);

    // Model decision (c): the toplevel died before the decoration — the
    // orphaned=2 error is posted on the decoration resource.
    tl.toplevel.destroy();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 2), wl_display_get_protocol_error(ts.c_display.?, null, null));
    _ = dec;
}

test "decoration on a toplevel with a committed buffer -> unconfigured_buffer" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const tl = try ts.createToplevel();

    // Model decision (a), v1 semantics: a toplevel that already committed a
    // buffer must not be decorated. White-box: the client has no buffer
    // machinery here, so set the server-side committed-buffer mirror
    // directly (Surface.buffer mirrors current.buffer; the check only
    // tests presence).
    const srv_surface = ts.shell.?.toplevels.items[0].xdg_surface.surface;
    const fake: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    srv_surface.buffer = @ptrCast(@alignCast(fake));

    _ = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}
