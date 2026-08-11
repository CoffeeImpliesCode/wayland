// Adversarial Wayland roundtrip probe: deliberately triggers a protocol
// violation and verifies the compositor kills the connection (the error
// makes the next roundtrip fail). One scenario per process — a protocol
// error kills the connection, so the runner invokes this once per
// scenario. Prints PASS/FAIL. Run: zig build run-rtprobe -- <scenario>.
const std = @import("std");
const protocol = @import("protocol");
const client = protocol.client;

var display: *client.wl.Display = undefined;
var compositor: ?*client.wl.Compositor = null;
var xdg: ?*client.xdg.WmBase = null;
var seat: ?*client.wl.Seat = null;

fn roundtripOk() bool {
    return client.wl.Display.roundtrip(display) == .SUCCESS;
}

pub fn main(init: std.process.Init) !void {
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next(); // argv[0]
    const scenario = args_it.next() orelse "role-conflict";
    display = client.wl.Display.connect(null) catch return error.NoDisplay;

    const registry = try display.getRegistry();
    const Reg = struct {
        fn listener(r: *client.wl.Registry, event: client.wl.Registry.Event, data: *u8) void {
            _ = data;
            switch (event) {
                .global => |g| {
                    const iface = std.mem.span(g.interface);
                    if (std.mem.eql(u8, iface, "wl_compositor")) {
                        compositor = r.bind(g.name, client.wl.Compositor, 4) catch null;
                    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                        xdg = r.bind(g.name, client.xdg.WmBase, 1) catch null;
                    } else if (std.mem.eql(u8, iface, "wl_seat")) {
                        seat = r.bind(g.name, client.wl.Seat, 1) catch null;
                    }
                },
                .global_remove => {},
            }
        }
    };
    var reg_data: u8 = 0;
    registry.setListener(*u8, Reg.listener, &reg_data);
    if (!roundtripOk() or compositor == null or xdg == null) {
        std.debug.print("FAIL: no globals\n", .{});
        return;
    }

    if (std.mem.eql(u8, scenario, "role-conflict")) {
        const s = try compositor.?.createSurface();
        _ = try xdg.?.getXdgSurface(s);
        _ = roundtripOk();
        // Second xdg_surface on the same wl_surface: role error, the
        // compositor must kill the connection.
        _ = try xdg.?.getXdgSurface(s);
        const died = !roundtripOk();
        std.debug.print("{s} role-conflict (2nd xdg_surface on one wl_surface)\n", .{if (died) "PASS" else "FAIL"});
    } else if (std.mem.eql(u8, scenario, "zero-geometry")) {
        const s = try compositor.?.createSurface();
        const x1 = try xdg.?.getXdgSurface(s);
        _ = try x1.getToplevel();
        _ = roundtripOk();
        // set_window_geometry with a zero size: invalid_size error.
        x1.setWindowGeometry(0, 0, 0, 0);
        const died = !roundtripOk();
        std.debug.print("{s} zero-geometry (set_window_geometry 0x0)\n", .{if (died) "PASS" else "FAIL"});
    } else if (std.mem.eql(u8, scenario, "move-before-configure")) {
        const s = try compositor.?.createSurface();
        const x1 = try xdg.?.getXdgSurface(s);
        const tl = try x1.getToplevel();
        _ = roundtripOk();
        // xdg_toplevel.move before the surface is configured:
        // not_constructed error.
        if (seat) |st| tl.move(st, 0);
        const died = !roundtripOk();
        std.debug.print("{s} move-before-configure (xdg_toplevel.move)\n", .{if (died) "PASS" else "FAIL"});
    } else if (std.mem.eql(u8, scenario, "toplevel-twice")) {
        const s = try compositor.?.createSurface();
        const x1 = try xdg.?.getXdgSurface(s);
        _ = try x1.getToplevel();
        _ = roundtripOk();
        // Second get_toplevel on the same xdg_surface: role conflict.
        _ = try x1.getToplevel();
        const died = !roundtripOk();
        std.debug.print("{s} toplevel-twice (2nd get_toplevel)\n", .{if (died) "PASS" else "FAIL"});
    } else if (std.mem.eql(u8, scenario, "bad-utf8-title")) {
        const s = try compositor.?.createSurface();
        const x1 = try xdg.?.getXdgSurface(s);
        const tl = try x1.getToplevel();
        _ = roundtripOk();
        // Invalid UTF-8 title: the compositor deliberately REJECTS it and
        // keeps the connection (documented divergence, notes/133: the
        // xdg-shell XML has no error code for it, wlroots posts an
        // unbacked -1). Expect the connection to survive.
        tl.setTitle("\xff\xfe\xfd");
        const alive = roundtripOk();
        std.debug.print("{s} bad-utf8-title (rejected, connection kept — notes/133)\n", .{
            if (alive) "PASS" else "FAIL",
        });
    } else if (std.mem.eql(u8, scenario, "commit-before-configure")) {
        // Commit a null buffer before acking a configure: the xdg surface
        // must not map, and no error is raised (null buffer is legal).
        const s = try compositor.?.createSurface();
        const x1 = try xdg.?.getXdgSurface(s);
        _ = try x1.getToplevel();
        _ = roundtripOk();
        s.commit();
        const ok = roundtripOk();
        std.debug.print("{s} commit-before-configure (null buffer commit is legal)\n", .{if (ok) "PASS" else "FAIL"});
    } else if (std.mem.eql(u8, scenario, "happy-path")) {
        // The control: a well-behaved surface maps + destroys cleanly
        // (role object first, then the xdg surface, then the wl_surface).
        const s = try compositor.?.createSurface();
        const x1 = try xdg.?.getXdgSurface(s);
        const tl = try x1.getToplevel();
        _ = roundtripOk();
        s.commit();
        const ok = roundtripOk();
        tl.destroy();
        x1.destroy();
        s.destroy();
        _ = roundtripOk();
        std.debug.print("{s} happy-path (surface create/commit/destroy)\n", .{if (ok) "PASS" else "FAIL"});
    } else {
        std.debug.print("FAIL: unknown scenario '{s}'\n", .{scenario});
    }

    client.wl.Display.disconnect(display);
}
