//! Test root for the server executable (src/server/main.zig).
//!
//! exe_tests cannot reuse the executable's root module directly: main.zig
//! declares its own `pub fn main(init: std.process.Init)`, which a test
//! binary built from that root would keep as its entry and then panic on
//! the runner's `--listen=-` protocol args. This root declares no main, so
//! the test runner becomes the entry. The comptime import plus the
//! refAllDecls test below still force full analysis of main.zig's decls
//! (AGENTS.md gate-5: unused decls still type-check), and any `test`
//! blocks added to main.zig run here.
//!
//! The module deps (wayland, zio, tracy, build_options, tracy_impl,
//! raylib_c) mirror server_exe.root_module's imports; build.zig wires them
//! before this file is compiled.

const std = @import("std");
const main_mod = @import("main.zig");
const wayland = @import("wayland");

const wire = wayland.wire;
const log = wayland.utils.log;
const client = wayland.client;

comptime {
    _ = main_mod;
}

test {
    std.testing.refAllDecls(main_mod);
}

// ---------------------------------------------------------------------------
// L-D7: layer keyboard-interactivity focus policy — the pure decision
// function (main.zig layerFocusDecision) drives the routing in
// applyLayerKeyboardFocus; the full matrix is tested here.
// ---------------------------------------------------------------------------

test "layerFocusDecision: layer keyboard-interactivity policy table (L-D7)" {
    const Action = main_mod.LayerFocusAction;
    const decide = main_mod.layerFocusDecision;

    // none (0): the layer never takes keyboard focus; a grab ending over
    // it (or a layer that dropped exclusive) is released.
    try std.testing.expectEqual(Action.keep, decide(false, 0, false));
    try std.testing.expectEqual(Action.keep, decide(true, 0, false));
    try std.testing.expectEqual(Action.restore_previous, decide(false, 0, true));
    try std.testing.expectEqual(Action.restore_previous, decide(true, 0, true));

    // exclusive (1): focus while the pointer is over it; the grab is
    // released (previous focus restored) when the pointer leaves.
    try std.testing.expectEqual(Action.keep, decide(false, 1, false));
    try std.testing.expectEqual(Action.focus_layer, decide(true, 1, false));
    try std.testing.expectEqual(Action.restore_previous, decide(false, 1, true));
    try std.testing.expectEqual(Action.focus_layer, decide(true, 1, true));

    // on_demand (2): focus while the pointer is over it, no grab — on
    // leave the focus is free (no forced restore).
    try std.testing.expectEqual(Action.keep, decide(false, 2, false));
    try std.testing.expectEqual(Action.focus_layer, decide(true, 2, false));
    try std.testing.expectEqual(Action.restore_previous, decide(false, 2, true));
    try std.testing.expectEqual(Action.focus_layer, decide(true, 2, true));

    // Unknown interactivity values: conservative (keep the current focus).
    try std.testing.expectEqual(Action.keep, decide(true, 3, false));
    try std.testing.expectEqual(Action.keep, decide(false, 3, false));
}

// ---------------------------------------------------------------------------
// E2E: full server wiring (mirrors main()'s module stack + listeners) with
// an in-memory client. Pattern: src/shell/xdg_decoration.zig TestServer,
// with the compositor policy listeners main() registers.
// ---------------------------------------------------------------------------

const posix = std.posix;

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

const XdgSurfaceEvents = struct {
    configure_count: usize = 0,
    serial: u32 = 0,

    fn listener(xdg_surface: *client.xdg.Surface, event: client.xdg.Surface.Event, data: *XdgSurfaceEvents) void {
        _ = xdg_surface;
        switch (event) {
            .configure => |c| {
                data.configure_count += 1;
                data.serial = c.serial;
            },
        }
    }
};

/// The compositor policy side of the E2E: the subset of main()'s ServerState
/// listener wiring under test. A new decoration announces the compositor's
/// initial mode via sendConfigure with the same focus policy as main.zig's
/// onDecorationMode/onNewDecoration (server-side for the focused toplevel).
const E2EState = struct {
    seat: *wayland.seat.Seat,
    new_decoration_listener: wire.Listener(*wayland.xdg_decoration.Decoration),

    fn onNewDecoration(
        listener: *wire.Listener(*wayland.xdg_decoration.Decoration),
        dec: *wayland.xdg_decoration.Decoration,
    ) void {
        const self: *E2EState = @fieldParentPtr("new_decoration_listener", listener);
        // The policy copied verbatim from main.zig's decorationModeFor.
        const mode: wayland.server.zxdg.ToplevelDecorationV1.Mode = blk: {
            const toplevel = dec.toplevel orelse break :blk .client_side;
            break :blk if (self.seat.keyboard_focus == toplevel.xdg_surface.surface)
                .server_side
            else
                .client_side;
        };
        dec.sendConfigure(mode);
    }
};

/// The server-side Surface for the client's wl_surface (same resolution as
/// main.zig's type derivation; only used to find the focus target).
const Surface = std.meta.Child(std.meta.Child(@TypeOf(@as(wayland.compositor.Compositor, undefined).surfaces.items)));

/// A full compositor stack wired like main() (display + compositor + seat +
/// xdg shell + decoration manager) with an in-memory client.
const E2EServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*wayland.core.display.CompositorDisplay = null,
    compositor: ?*wayland.compositor.Compositor = null,
    seat: ?*wayland.seat.Seat = null,
    shell: ?*wayland.shell.XdgShell = null,
    decoration: ?*wayland.xdg_decoration.XdgDecoration = null,
    /// The compositor policy listeners main() registers (E2EState.onNewDecoration).
    state: E2EState,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wm_base: ?*client.xdg.WmBase = null,
    decoration_client: ?*client.zxdg.DecorationManagerV1 = null,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor, seat, shell and decoration all store it).
    fn init(allocator: std.mem.Allocator) !*E2EServer {
        const ts = try allocator.create(E2EServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
            // SAFETY: assigned below once the seat exists (E2EState.seat).
            .state = undefined,
        };
        ts.display = try wayland.core.display.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        ts.compositor = try wayland.compositor.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.seat = try wayland.seat.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();
        ts.shell = try wayland.shell.XdgShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
        errdefer if (ts.shell) |s| s.deinit();
        ts.decoration = try wayland.xdg_decoration.XdgDecoration.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.shell.?,
        );
        errdefer if (ts.decoration) |d| d.deinit();
        // The code under test: main()'s new_toplevel_decoration announce
        // listener.
        ts.state = .{
            .seat = ts.seat.?,
            .new_decoration_listener = wire.Listener(*wayland.xdg_decoration.Decoration)
                .init(E2EState.onNewDecoration),
        };
        ts.decoration.?.events.new_toplevel_decoration.add(&ts.state.new_decoration_listener);

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

    fn deinit(ts: *E2EServer) void {
        // Tear the client down first: its resource destroy handlers must
        // run while the modules still live.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.decoration) |d| d.deinit();
        if (ts.shell) |s| s.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Client flush -> server event loop dispatch -> server flush -> client
    /// dispatch. Drives one roundtrip without blocking.
    fn pump(ts: *E2EServer) !void {
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

    /// The server-side Surface the client's wl_surface maps to.
    fn surfaceForClient(ts: *E2EServer, wl_surface: *client.wl.Surface) *Surface {
        for (ts.compositor.?.surfaces.items) |s| {
            if (s.resource.getId() == wl_surface.getId()) return s;
        }
        unreachable;
    }
};

test "E2E: decoration without set_mode receives the policy mode configure" {
    const allocator = std.testing.allocator;
    var ts = try E2EServer.init(allocator);
    defer ts.deinit();

    // Client: wl_surface + xdg_surface + toplevel.
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    try ts.pump();

    // Focus the toplevel (server-side) so the policy picks server_side:
    // main.zig's decorationModeFor reads seat.keyboard_focus.
    ts.seat.?.setKeyboardFocus(ts.surfaceForClient(wl_surface));

    // Create the decoration and never send set_mode (L2): the announce
    // (main()'s new_toplevel_decoration wiring) must deliver the policy
    // mode.
    const dec = try ts.decoration_client.?.getToplevelDecoration(toplevel);
    var dec_events: DecorationEvents = .{};
    dec.setListener(*DecorationEvents, DecorationEvents.listener, &dec_events);
    try ts.pump();

    // The zxdg configure arrived in the same roundtrip as the xdg configure
    // it rode in on (XD-1), carrying the policy mode (server_side).
    try std.testing.expectEqual(@as(usize, 1), dec_events.configure_count);
    try std.testing.expectEqual(@as(i32, 2), dec_events.mode); // server_side
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);

    // Ack the xdg configure: the announced mode applies.
    const dec_obj = ts.decoration.?.decorations.items[0];
    try std.testing.expectEqual(@as(?wayland.xdg_decoration.Mode, .server_side), dec_obj.scheduled_mode);
    xdg_surface.ackConfigure(xs_events.serial);
    try ts.pump();
    try std.testing.expectEqual(@as(?wayland.xdg_decoration.Mode, .server_side), dec_obj.current_mode);
}
