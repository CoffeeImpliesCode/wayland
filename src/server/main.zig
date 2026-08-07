//! M1 compositor test server (tinywl equivalent).
//!
//! Wires the `wayland` library end to end on a zio event loop:
//!   - CompositorDisplay + wl_shm + xdg-shell + headless backend
//!   - pixman CPU renderer: background rect + one blit per mapped surface
//!   - zio ev loop watches the display fd (PipePoll); the headless
//!     backend paces frames via the display's own wire event loop timer,
//!     so rendering happens inside display.dispatch
//!   - 5s watchdog timer stops the loop when no frame has been rendered
//!     (tests must not hang); WAYLAND_RUN_FRAMES=N stops after N frames
//!
//! Environment:
//!   WAYLAND_LOG          log filter, e.g. "debug" or "wire=info,compositor=debug"
//!   WAYLAND_PROTOCOL_LOG set to "1" to log every protocol message
//!   WAYLAND_RUN_FRAMES   stop after N rendered frames (0/absent = run forever)
//!
//! The socket name is printed on its own stdout line as
//! `WAYLAND_SOCKET=<name>` (flushed) so test harnesses can read it.

const std = @import("std");
const wayland = @import("wayland");
const zio = @import("zio");
const tracy = @import("tracy");

// Tracy plumbing: the tracy package looks these up on the importing root.
// The build swaps "tracy_impl" between the enabled/disabled module.
pub const tracy_impl = @import("tracy_impl");
pub const tracy_options: tracy.Options = .{
    .on_demand = false,
    .no_broadcast = false,
    .only_localhost = false,
    .only_ipv4 = false,
    .delayed_init = false,
    .manual_lifetime = false,
    .verbose = false,
    .data_port = null,
    .broadcast_port = null,
    .default_callstack_depth = 0,
};

const log = wayland.utils.log;
const wire = wayland.wire;
const pixman = wayland.pixman;

const output_width: i32 = 1280;
const output_height: i32 = 720;
const output_refresh_msec: i32 = 16;
const watchdog_timeout_ms: u64 = 5000;
/// Background color (straight alpha RGBA).
const background_color = [4]f32{ 0.1, 0.1, 0.12, 1.0 };

const ServerState = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *wayland.core.display.CompositorDisplay,
    compositor: *wayland.compositor.Compositor,
    shm_state: *wayland.shm.ShmState,
    shell: *wayland.shell.XdgShell,
    renderer: *wayland.renderer.Renderer,
    backend: *wayland.backend.Backend,
    framebuffer: *pixman.Framebuffer,
    /// The zio loop, set once initialized (callbacks stop it).
    loop: ?*zio.ev.Loop = null,
    /// One-shot watchdog timer, re-armed on every render.
    watchdog: ?*zio.ev.Timer = null,
    output: ?*wayland.output.Output = null,
    /// Toplevels created by clients (tracked for observability).
    toplevels: std.ArrayList(*wayland.shell.XdgToplevel) = .empty,
    frames_rendered: u32 = 0,
    /// Stop after this many frames; 0 = run until watchdog/error.
    run_frames: u32 = 0,
    watchdog_fired: bool = false,

    new_output_listener: wire.Listener(*wayland.output.Output) = undefined,
    frame_listener: wire.Listener(*wayland.output.Output) = undefined,
    new_toplevel_listener: wire.Listener(*wayland.shell.XdgToplevel) = undefined,
    new_popup_listener: wire.Listener(*wayland.shell.XdgPopup) = undefined,
};

pub fn main(init: std.process.Init) !void {
    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    var log_cfg = try parseLogConfig(allocator, init.environ_map);
    defer log_cfg.tags.deinit(allocator);

    // The runtime's io is used from the main thread outside any executor:
    // with the main executor disabled, waitForIo takes its synchronous
    // blocking path (no ambient task), so logging works while the standalone
    // ev.Loop below drives the display fd.
    var runtime = try zio.Runtime.init(allocator, .{
        .executors = .exact(1),
        .enable_main_executor = false,
    });
    defer runtime.deinit();
    var io_value = runtime.io();
    const io: *std.Io = &io_value;

    log.info("m1 test server starting (zio runtime, pixman)", io, &log_cfg, "server", .{});

    // --- library wiring ---------------------------------------------------
    const display = try wayland.core.display.CompositorDisplay.init(allocator, io, &log_cfg);
    defer display.deinit();
    try display.initShm();

    if (init.environ_map.get("WAYLAND_PROTOCOL_LOG")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            display.attachProtocolLogger();
            log.info("protocol logger attached (WAYLAND_PROTOCOL_LOG=1)", io, &log_cfg, "server", .{});
        }
    }

    const socket_name = try display.addSocketAuto();
    log.info("created socket {s}", io, &log_cfg, "server", .{socket_name});

    const compositor = try wayland.compositor.Compositor.init(allocator, io, &log_cfg, display);
    defer compositor.deinit();
    const shm_state = try wayland.shm.ShmState.init(allocator, io, &log_cfg, display);
    defer shm_state.deinit();
    compositor.setShm(shm_state);
    const shell = try wayland.shell.XdgShell.init(allocator, io, &log_cfg, display, compositor);
    defer shell.deinit();
    const renderer = try pixman.PixmanRenderer.create(allocator, io, &log_cfg);
    defer renderer.destroy();
    const backend = try wayland.headless.HeadlessBackend.create(
        allocator,
        io,
        &log_cfg,
        display.getServer().getEventLoop(),
        .{ .width = output_width, .height = output_height, .refresh_msec = output_refresh_msec },
    );
    defer backend.destroy();

    const framebuffer = try pixman.Framebuffer.create(allocator, output_width, output_height);
    defer framebuffer.deinit();

    var state: ServerState = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = &log_cfg,
        .display = display,
        .compositor = compositor,
        .shm_state = shm_state,
        .shell = shell,
        .renderer = renderer,
        .backend = backend,
        .framebuffer = framebuffer,
        .toplevels = .empty,
    };
    defer state.toplevels.deinit(allocator);

    state.new_output_listener = wire.Listener(*wayland.output.Output).init(onNewOutput);
    state.frame_listener = wire.Listener(*wayland.output.Output).init(onOutputFrame);
    state.new_toplevel_listener = wire.Listener(*wayland.shell.XdgToplevel).init(onNewToplevel);
    state.new_popup_listener = wire.Listener(*wayland.shell.XdgPopup).init(onNewPopup);
    backend.events.new_output.add(&state.new_output_listener);
    shell.events.new_toplevel.add(&state.new_toplevel_listener);
    shell.events.new_popup.add(&state.new_popup_listener);

    if (init.environ_map.get("WAYLAND_RUN_FRAMES")) |frames| {
        state.run_frames = std.fmt.parseInt(u32, frames, 10) catch 0;
        if (state.run_frames > 0) {
            log.info("WAYLAND_RUN_FRAMES: stopping after {d} frames", io, &log_cfg, "server", .{state.run_frames});
        }
    }

    // The socket name must be a single flushed stdout line, first thing
    // tests read. Logging goes to stderr, so stdout stays parseable.
    {
        const stdout_file = std.Io.File.stdout();
        var buf: [128]u8 = undefined;
        var w = stdout_file.writer(io.*, &buf);
        w.interface.print("WAYLAND_SOCKET={s}\n", .{socket_name}) catch |err| {
            log.err("failed to write socket name to stdout: {s}", io, &log_cfg, "server", .{@errorName(err)});
            return err;
        };
        w.interface.flush() catch |err| {
            log.err("failed to flush socket name to stdout: {s}", io, &log_cfg, "server", .{@errorName(err)});
            return err;
        };
    }

    try backend.start(); // fires new_output; the headless timer paces frames

    // --- zio event loop ---------------------------------------------------
    var loop: zio.ev.Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();
    state.loop = &loop;

    // Watch the display fd: readable when a client sent requests or a wire
    // timer (headless frame pacing) is due. Rearm keeps the registration.
    var display_poll = zio.ev.PipePoll.init(display.loopFd(), .read);
    display_poll.c.userdata = &state;
    display_poll.c.callback = onDisplayReady;
    display_poll.c.flags.rearm = true;
    loop.add(&display_poll.c);

    // Watchdog: fires when no frame was rendered for the full window. The
    // render path re-arms it, so a healthy server runs forever; a wedged
    // one stops with an error instead of hanging tests.
    var watchdog = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(watchdog_timeout_ms) });
    watchdog.c.userdata = &state;
    watchdog.c.callback = onWatchdog;
    state.watchdog = &watchdog;
    loop.add(&watchdog.c);

    log.info("entering event loop (display fd {d})", io, &log_cfg, "server", .{display.loopFd()});
    while (!loop.stopped()) {
        loop.poll(.max) catch |err| {
            log.err("loop poll error: {s}", io, &log_cfg, "server", .{@errorName(err)});
            break;
        };
    }
    log.info("event loop exited: frames={d} watchdog_fired={}", io, &log_cfg, "server", .{
        state.frames_rendered,
        state.watchdog_fired,
    });
    state.loop = null;
}

// ---------------------------------------------------------------------------
// Listeners
// ---------------------------------------------------------------------------

fn onNewOutput(listener: *wire.Listener(*wayland.output.Output), out: *wayland.output.Output) void {
    const self: *ServerState = @fieldParentPtr("new_output_listener", listener);
    self.output = out;
    log.info("new output {d}x{d} refresh={d}ms", self.io, self.log_cfg, "server", .{
        out.mode.width, out.mode.height, out.mode.refresh_msec,
    });
    out.events.frame.add(&self.frame_listener);
}

fn onNewToplevel(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const self: *ServerState = @fieldParentPtr("new_toplevel_listener", listener);
    self.toplevels.append(self.allocator, t) catch |err| {
        log.warn("failed to track toplevel: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
    };
    log.info("new toplevel (title={s} app_id={s}) total={d}", self.io, self.log_cfg, "server", .{
        t.title orelse "(none)",
        t.app_id orelse "(none)",
        self.toplevels.items.len,
    });
}

fn onNewPopup(listener: *wire.Listener(*wayland.shell.XdgPopup), p: *wayland.shell.XdgPopup) void {
    const self: *ServerState = @fieldParentPtr("new_popup_listener", listener);
    log.info("new popup at {d},{d} {d}x{d}", self.io, self.log_cfg, "server", .{
        p.geometry.x, p.geometry.y, p.geometry.width, p.geometry.height,
    });
}

// ---------------------------------------------------------------------------
// zio loop callbacks
// ---------------------------------------------------------------------------

fn onDisplayReady(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    _ = loop;
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Non-blocking dispatch: processes client requests and wire timers
    // (the headless frame timer fires output.frame signals here).
    self.display.dispatch(0) catch |err| {
        log.err("dispatch failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    self.display.flushClients();
}

fn onWatchdog(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    log.err("watchdog: no rendered frame for {d}ms; stopping", self.io, self.log_cfg, "server", .{watchdog_timeout_ms});
    self.watchdog_fired = true;
    loop.stop();
}

fn onOutputFrame(listener: *wire.Listener(*wayland.output.Output), out: *wayland.output.Output) void {
    const self: *ServerState = @fieldParentPtr("frame_listener", listener);
    renderFrame(self, out);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn renderFrame(self: *ServerState, out: *wayland.output.Output) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();

    // M1: single fixed-size framebuffer, reused across frames.
    const fb = self.framebuffer;
    const pass = self.renderer.beginPass(fb) orelse {
        log.err("begin_pass failed", self.io, self.log_cfg, "server", .{});
        return;
    };

    // Background clears the previous frame (alpha 1 overwrites).
    pass.addRect(.{ .x = 0, .y = 0, .width = fb.width, .height = fb.height }, background_color);

    // One 1:1 blit per mapped surface at (0, 0) (M1: no transforms).
    var n_surfaces: usize = 0;
    for (self.compositor.surfaces.items) |s| {
        if (!s.mapped) continue;
        const buf = s.buffer orelse continue;
        const get_shm = buf.impl.get_shm orelse continue;
        const shm = get_shm(buf) orelse continue;
        const begin = buf.impl.begin_data_ptr_access orelse continue;
        const end = buf.impl.end_data_ptr_access orelse continue;

        const pixels = begin(buf) catch continue;
        defer end(buf);
        const ptr = pixels orelse continue;
        const stride = wire.shm.Buffer.getStride(shm);
        const byte_len = @as(usize, @intCast(stride)) * @as(usize, @intCast(buf.height));
        const tex = pixman.PixmanRenderer.importMemory(
            self.renderer,
            buf.width,
            buf.height,
            stride,
            ptr[0..byte_len],
        ) catch continue;
        defer tex.destroy();

        pass.addTexture(tex, null, .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(buf.width),
            .height = @floatFromInt(buf.height),
        }, 1.0);
        n_surfaces += 1;
    }
    pass.submit();

    // Present: hand the framebuffer to the output, damage the whole screen.
    var state = wayland.output.Output.State.init(self.allocator);
    defer state.deinit();
    state.committed = wayland.output.Output.State.committed_enabled |
        wayland.output.Output.State.committed_mode |
        wayland.output.Output.State.committed_buffer;
    state.enabled = true;
    state.mode = .{ .width = output_width, .height = output_height, .refresh_msec = output_refresh_msec };
    state.buffer = @ptrCast(fb);
    state.damage.addWhole();
    out.commitState(&state) catch |err| {
        log.err("output commit failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };

    self.frames_rendered += 1;
    tracy.frameMark(null);
    log.debug("render frame={d} surfaces={d}", self.io, self.log_cfg, "server", .{
        self.frames_rendered,
        n_surfaces,
    });

    // Progress: keep the watchdog from firing. A wedged loop stops instead
    // of hanging tests.
    if (self.watchdog) |t| {
        self.loop.?.setTimer(t, .{ .duration = zio.Duration.fromMilliseconds(watchdog_timeout_ms) });
    }
    if (self.run_frames != 0 and self.frames_rendered >= self.run_frames) {
        log.info("reached WAYLAND_RUN_FRAMES={d}, stopping", self.io, self.log_cfg, "server", .{self.run_frames});
        self.loop.?.stop();
    }
}

// ---------------------------------------------------------------------------
// Log config
// ---------------------------------------------------------------------------

fn parseLevel(s: []const u8) ?log.Level {
    inline for (.{
        .{ "err", log.Level.err },
        .{ "warn", log.Level.warn },
        .{ "info", log.Level.info },
        .{ "debug", log.Level.debug },
        .{ "trace", log.Level.trace },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(s, entry[0])) return entry[1];
    }
    return null;
}

/// Parse WAYLAND_LOG: either a bare level ("debug") or a comma-separated
/// list of tag=level overrides ("wire=info,compositor=debug"). The test
/// server defaults to debug output.
fn parseLogConfig(
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
) !log.Config {
    var cfg: log.Config = .{ .min_level = .debug };
    const raw = environ_map.get("WAYLAND_LOG") orelse return cfg;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len == 0) continue;
        if (std.mem.findScalar(u8, p, '=')) |eq| {
            const lvl = parseLevel(p[eq + 1 ..]) orelse continue;
            try cfg.tags.put(allocator, p[0..eq], lvl);
        } else if (parseLevel(p)) |lvl| {
            cfg.min_level = lvl;
        }
    }
    return cfg;
}
