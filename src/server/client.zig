//! M1 test client: drives the compositor test server end to end.
//!
//! Pure protocol client (generated `client.*` bindings + libwayland-client,
//! no compositor library import):
//!   1. connect via WAYLAND_DISPLAY, roundtrip
//!   2. bind wl_compositor (v7), wl_shm (v3), xdg_wm_base (v7)
//!   3. xdg toplevel "m1-test"; empty commit; wait for configure, ack it
//!   4. shm buffer (memfd, 1280x720x4, red gradient), attach, damage, commit
//!   5. one frame callback; on done -> "CLIENT-OK", exit 0
//!
//! On failure prints CLIENT-ERROR/CLIENT-TIMEOUT and exits nonzero.
//! All progress lines go to stderr; the CLIENT-* verdicts to stdout.

const std = @import("std");
const protocol = @import("protocol");

const client = protocol.client;
const wl = client.wl;
const xdg = client.xdg;

const surface_width: i32 = 1280;
const surface_height: i32 = 720;
const bytes_per_pixel: usize = 4;
const pool_size: usize = @as(usize, @intCast(surface_width)) *
    @as(usize, @intCast(surface_height)) * bytes_per_pixel;
const timeout_ms: i64 = 5000;

/// Set from main so the step/verdict log helpers can read the clock
/// (0.16 has no std.time.milliTimestamp; the Io provides it).
var client_io: std.Io = undefined;

const ClientState = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    toplevel: ?*xdg.Toplevel = null,
    shm_pool: ?*wl.ShmPool = null,
    buffer: ?*wl.Buffer = null,

    got_configure: bool = false,
    configure_serial: ?u32 = null,
    frame_done: bool = false,
};

pub fn main(init: std.process.Init) !void {
    client_io = init.io;
    const display_name = init.environ_map.get("WAYLAND_DISPLAY");
    if (display_name == null or display_name.?.len == 0) {
        verdict("CLIENT-ERROR", "WAYLAND_DISPLAY is not set", .{});
        return error.WaylandDisplayUnset;
    }
    step("connecting to {s}", .{display_name.?});

    // connect(null) uses WAYLAND_DISPLAY from the environment (validated above).
    const display = wl.Display.connect(null) catch |err| {
        verdict("CLIENT-ERROR", "wl_display_connect failed: {s}", .{@errorName(err)});
        return err;
    };
    defer wl.Display.disconnect(display);

    if (wl.Display.roundtrip(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "initial roundtrip failed", .{});
        return error.RoundtripFailed;
    }

    const registry = try display.getRegistry();
    var state = ClientState{ .display = display, .registry = registry };
    registry.setListener(*ClientState, onRegistryEvent, &state);

    // Collect globals: another roundtrip processes the registry burst.
    if (wl.Display.roundtrip(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "registry roundtrip failed", .{});
        return error.RoundtripFailed;
    }
    if (state.compositor == null or state.shm == null or state.wm_base == null) {
        verdict("CLIENT-ERROR", "missing globals (compositor={} shm={} xdg={})", .{
            state.compositor != null, state.shm != null, state.wm_base != null,
        });
        return error.MissingGlobals;
    }
    step("bound wl_compositor, wl_shm, xdg_wm_base", .{});

    // --- xdg toplevel -----------------------------------------------------
    const surface = try state.compositor.?.createSurface();
    state.surface = surface;
    const xdg_surface = try state.wm_base.?.getXdgSurface(surface);
    state.xdg_surface = xdg_surface;
    xdg_surface.setListener(*ClientState, onXdgSurfaceEvent, &state);
    const toplevel = try xdg_surface.getToplevel();
    state.toplevel = toplevel;
    toplevel.setListener(*ClientState, onToplevelEvent, &state);
    toplevel.setTitle("m1-test");
    toplevel.setAppId("m1-test");
    step("created xdg_toplevel, title=m1-test", .{});

    // Empty commit: the server answers with the initial configure. Flush so
    // the request leaves the client's outgoing buffer before we poll.
    surface.commit();
    if (wl.Display.flush(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "flush after empty commit failed", .{});
        return error.FlushFailed;
    }

    if (!try waitForEvent(&state, timeout_ms, hasConfigure)) {
        verdict("CLIENT-TIMEOUT", "no xdg configure within {d}ms", .{timeout_ms});
        return error.ClientTimeout;
    }
    step("received configure serial={d}", .{state.configure_serial.?});
    xdg_surface.ackConfigure(state.configure_serial.?);

    // --- shm buffer -------------------------------------------------------
    const fd = try std.posix.memfd_create("m1-test-buffer", std.os.linux.MFD.CLOEXEC);
    defer _ = std.os.linux.close(fd);
    {
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) {
            verdict("CLIENT-ERROR", "ftruncate failed", .{});
            return error.FtruncateFailed;
        }
    }
    const pixels = try std.posix.mmap(
        null,
        pool_size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(pixels);
    fillPattern(pixels, surface_width, surface_height);

    state.shm_pool = try state.shm.?.createPool(fd, @intCast(pool_size));
    state.buffer = try state.shm_pool.?.createBuffer(
        0,
        surface_width,
        surface_height,
        surface_width * 4,
        .argb8888,
    );
    step("created shm buffer {d}x{d}", .{ surface_width, surface_height });

    // --- map: attach + damage + frame + commit ----------------------------
    const frame_cb = try surface.frame();
    frame_cb.setListener(*ClientState, onFrameDone, &state);
    surface.attach(state.buffer, 0, 0);
    surface.damage(0, 0, surface_width, surface_height);
    surface.commit();
    if (wl.Display.flush(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "flush after buffer commit failed", .{});
        return error.FlushFailed;
    }
    step("committed buffer, waiting for frame callback", .{});

    if (!try waitForEvent(&state, timeout_ms, hasFrame)) {
        verdict("CLIENT-TIMEOUT", "no frame callback within {d}ms", .{timeout_ms});
        return error.ClientTimeout;
    }
    step("frame callback done", .{});

    // Hold the mapped surface briefly so the compositor renders it at least
    // once (the server logs render frames with the surface count).
    std.Io.sleep(client_io, .fromMilliseconds(700), .awake) catch {};

    // Drain remaining events so the server sees a clean client teardown.
    if (wl.Display.roundtrip(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "final roundtrip failed", .{});
        return error.RoundtripFailed;
    }
    verdict("CLIENT-OK", "roundtrip complete", .{});
}

// ---------------------------------------------------------------------------
// Event listeners
// ---------------------------------------------------------------------------

fn onRegistryEvent(registry: *wl.Registry, event: wl.Registry.Event, state: *ClientState) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            if (std.mem.eql(u8, name, "wl_compositor") and state.compositor == null) {
                state.compositor = registry.bind(g.name, wl.Compositor, 7) catch null;
            } else if (std.mem.eql(u8, name, "wl_shm") and state.shm == null) {
                state.shm = registry.bind(g.name, wl.Shm, g.version) catch null;
            } else if (std.mem.eql(u8, name, "xdg_wm_base") and state.wm_base == null) {
                state.wm_base = registry.bind(g.name, xdg.WmBase, 7) catch null;
            }
        },
        .global_remove => {},
    }
}

fn onXdgSurfaceEvent(surface: *xdg.Surface, event: xdg.Surface.Event, state: *ClientState) void {
    _ = surface;
    switch (event) {
        .configure => |c| {
            state.configure_serial = c.serial;
            state.got_configure = true;
        },
    }
}

fn onToplevelEvent(toplevel: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *ClientState) void {
    _ = toplevel;
    _ = state;
    switch (event) {
        .configure => |c| step("toplevel.configure {d}x{d} states={d}", .{ c.width, c.height, c.states.size }),
        .close => {},
        .configure_bounds => {},
        .wm_capabilities => {},
    }
}

fn onFrameDone(callback: *wl.Callback, event: wl.Callback.Event, state: *ClientState) void {
    _ = callback;
    switch (event) {
        .done => |d| {
            step("wl_callback.done time={d}", .{d.callback_data});
            state.frame_done = true;
        },
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn hasConfigure(state: *const ClientState) bool {
    return state.got_configure;
}

fn hasFrame(state: *const ClientState) bool {
    return state.frame_done;
}

/// Poll the display fd (bounded by the deadline) and dispatch until
/// `predicate` returns true. Returns false on timeout.
fn waitForEvent(
    state: *const ClientState,
    ms: i64,
    comptime predicate: fn (*const ClientState) bool,
) !bool {
    const display = state.display;
    const start_ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
    const start_ms: i64 = @intCast(@divTrunc(start_ns, std.time.ns_per_ms));
    const deadline = start_ms + ms;
    while (!predicate(state)) {
        const now_ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
        const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
        const remaining = deadline - now_ms;
        if (remaining <= 0) return false;

        var pfd = [_]std.posix.pollfd{
            .{ .fd = wl.Display.getFd(display), .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&pfd, @intCast(remaining)) catch |err| {
            verdict("CLIENT-ERROR", "poll failed: {s}", .{@errorName(err)});
            return err;
        };
        if (pfd[0].revents & std.posix.POLL.IN != 0) {
            if (wl.Display.dispatch(display) != .SUCCESS) {
                verdict("CLIENT-ERROR", "dispatch failed", .{});
                return error.DispatchFailed;
            }
        } else if (pfd[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
            verdict("CLIENT-ERROR", "display connection closed by server", .{});
            return error.ConnectionClosed;
        }
    }
    return true;
}

/// Fill the buffer with a red gradient (ARGB8888: bytes B,G,R,A).
fn fillPattern(pixels: []align(std.heap.page_size_min) u8, w: i32, h: i32) void {
    const stride: usize = @intCast(w * 4);
    var y: usize = 0;
    while (y < @as(usize, @intCast(h))) : (y += 1) {
        const row = pixels[y * stride ..][0..stride];
        var x: usize = 0;
        while (x < @as(usize, @intCast(w))) : (x += 1) {
            const intensity: u8 = @intCast((x * 255) / @as(usize, @intCast(w)));
            const off = x * 4;
            row[off + 0] = intensity; // B
            row[off + 1] = 0; // G
            row[off + 2] = 255; // R
            row[off + 3] = 255; // A
        }
    }
}

/// Timestamped client step, to stderr.
fn step(comptime fmt: []const u8, args: anytype) void {
    const now_ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
    const now_ms: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}.{d:0>3} client] " ++ fmt ++ "\n", .{
        now_ms / 1000,
        now_ms % 1000,
    } ++ args) catch return;
    writeFd(std.posix.STDERR_FILENO, line);
}

/// Verdict line, to stdout (parseable), mirrored to stderr.
fn verdict(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    const now_ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
    const now_ms: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, tag ++ ": " ++ fmt ++ "\n", args) catch return;
    writeFd(std.posix.STDOUT_FILENO, line);
    var err_buf: [512]u8 = undefined;
    const err_line = std.fmt.bufPrint(&err_buf, "[{d}.{d:0>3} client] " ++ tag ++ ": " ++ fmt ++ "\n", .{
        now_ms / 1000,
        now_ms % 1000,
    } ++ args) catch return;
    writeFd(std.posix.STDERR_FILENO, err_line);
}

/// Best-effort raw fd write (0.16 has no std.posix.write; test client
/// output must not fail the run).
fn writeFd(fd: i32, bytes: []const u8) void {
    const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
    _ = std.os.linux.errno(rc);
}
