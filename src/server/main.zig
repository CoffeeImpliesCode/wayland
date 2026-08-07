//! M2 compositor test server (tinywl equivalent).
//!
//! Wires the `wayland` library end to end on a zio event loop:
//!   - CompositorDisplay + wl_shm + xdg-shell + wp_presentation + backend
//!   - pixman CPU renderer + the scene graph: a background rect plus one
//!     SceneBufferNode per mapped surface (imported on commit)
//!   - frame pacing by the backend's wire event loop timer (headless or
//!     raylib), rendering inside display.dispatch on output.frame
//!   - presentation feedback for every surface drawn in a frame
//!   - 5s watchdog timer stops the loop when no frame has been rendered
//!     (tests must not hang); WAYLAND_RUN_FRAMES=N stops after N frames
//!
//! Environment:
//!   WAYLAND_LOG          log filter, e.g. "debug" or "wire=info,compositor=debug"
//!   WAYLAND_PROTOCOL_LOG set to "1" to log every protocol message
//!   WAYLAND_RUN_FRAMES   stop after N rendered frames (0/absent = run forever)
//!   WAYLAND_BACKEND      "raylib" selects the windowed raylib debug backend
//!                        (falls back to headless if the window cannot open);
//!                        anything else selects the headless backend
//!
//! The socket name is printed on its own stdout line as
//! `WAYLAND_SOCKET=<name>` (flushed) so test harnesses can read it.

const std = @import("std");
const wayland = @import("wayland");
const zio = @import("zio");
const tracy = @import("tracy");

const build_options = @import("build_options");
/// The raylib debug backend is only linked when build.zig's
/// -Denable_raylib option is on; main only references it behind a
/// comptime guard on build_options.enable_raylib.
const raylib_impl = @import("raylib.zig");
const raylib_mod = if (build_options.enable_raylib) raylib_impl else null;

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

// Library types not re-exported from root.zig. Zig 0.16 module ownership
// forbids importing a library file into the server module, so the types
// are derived from public fields of exported structs instead.
/// `*Surface` as stored in Compositor.surfaces (ArrayList(*Surface).items).
// SAFETY: type-derivation only; the undefined value is never evaluated at runtime.
const Surface = std.meta.Child(std.meta.Child(@TypeOf(@as(wayland.compositor.Compositor, undefined).surfaces.items)));
/// `?*Texture` as stored in SceneBufferNode.texture.
// SAFETY: type-derivation only; the undefined value is never evaluated at runtime.
const Texture = std.meta.Child(std.meta.Child(@TypeOf(@as(wayland.scene.SceneBufferNode, undefined).texture)));

const output_width: i32 = 1280;
const output_height: i32 = 720;
const output_refresh_msec: i32 = 16;
const watchdog_timeout_ms: u64 = 5000;
/// Background color (straight alpha RGBA).
const background_color = [4]f32{ 0.1, 0.1, 0.12, 1.0 };

/// Per-surface scene state: the SceneBufferNode that draws the surface's
/// current buffer, plus the listeners that keep it in sync (commit
/// updates the texture, destroy removes it and frees the entry).
const SurfaceEntry = struct {
    state: *ServerState,
    surface: *Surface,
    node: ?*wayland.scene.SceneNode = null,
    commit_listener: wire.Listener(*Surface),
    destroy_listener: wire.Listener(*Surface),
};

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
    /// M2 scene graph: one scene and one output view (single-output server).
    scene: ?*wayland.scene.Scene = null,
    scene_output: ?*wayland.scene.SceneOutput = null,
    presentation: *wayland.presentation.Presentation,
    /// Per-surface scene state, keyed by the compositor surface
    /// (initialized in the state literal with the server allocator).
    surface_entries: std.AutoHashMap(*Surface, *SurfaceEntry),
    /// Surfaces drawn this frame (presentation feedback targets), reused.
    presented: std.ArrayList(*Surface) = .empty,
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

    new_output_listener: wire.Listener(*wayland.output.Output),
    frame_listener: wire.Listener(*wayland.output.Output),
    new_toplevel_listener: wire.Listener(*wayland.shell.XdgToplevel),
    new_popup_listener: wire.Listener(*wayland.shell.XdgPopup),
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

    // wp_presentation (stable v2): one global, registered right after the
    // display so feedback objects exist before any client commit.
    const presentation = try wayland.presentation.Presentation.init(allocator, io, &log_cfg, display);
    defer presentation.deinit();

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
    // Backend selection: WAYLAND_BACKEND=raylib uses the windowed raylib
    // debug backend (falling back to headless when the window cannot
    // open); anything else uses the headless backend. The raylib path is
    // only reachable when built with -Denable_raylib (default on).
    const backend = if (build_options.enable_raylib) blk: {
        if (wantRaylibBackend(init.environ_map)) {
            break :blk raylib_mod.RaylibBackend.create(
                allocator,
                io,
                &log_cfg,
                display.getServer().getEventLoop(),
                .{ .width = output_width, .height = output_height, .refresh_msec = output_refresh_msec },
                "wayland-m2",
            ) catch |err| {
                log.warn(
                    "raylib backend init failed ({s}); falling back to headless",
                    io,
                    &log_cfg,
                    "server",
                    .{@errorName(err)},
                );
                break :blk try wayland.headless.HeadlessBackend.create(
                    allocator,
                    io,
                    &log_cfg,
                    display.getServer().getEventLoop(),
                    .{ .width = output_width, .height = output_height, .refresh_msec = output_refresh_msec },
                );
            };
        }
        break :blk try wayland.headless.HeadlessBackend.create(
            allocator,
            io,
            &log_cfg,
            display.getServer().getEventLoop(),
            .{ .width = output_width, .height = output_height, .refresh_msec = output_refresh_msec },
        );
    } else try wayland.headless.HeadlessBackend.create(
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
        .presentation = presentation,
        .surface_entries = std.AutoHashMap(*Surface, *SurfaceEntry).init(allocator),
        .toplevels = .empty,
        .new_output_listener = wire.Listener(*wayland.output.Output).init(onNewOutput),
        .frame_listener = wire.Listener(*wayland.output.Output).init(onOutputFrame),
        .new_toplevel_listener = wire.Listener(*wayland.shell.XdgToplevel).init(onNewToplevel),
        .new_popup_listener = wire.Listener(*wayland.shell.XdgPopup).init(onNewPopup),
    };
    defer state.toplevels.deinit(allocator);
    // Scene teardown (LIFO): drop the per-surface scene state first, then
    // the scene output view, then the scene tree itself. The compositor
    // (deferred earlier in main) destroys its surfaces afterwards; the
    // listeners were already removed, so no entry is freed twice.
    defer if (state.scene) |scene| scene.deinit();
    defer if (state.scene_output) |so| so.destroy();
    defer cleanupSurfaceEntries(&state);

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
    // SAFETY: initialized by loop.init() immediately below, before any use.
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

    // M2: build the scene for this output (one scene, one output view).
    const scene = wayland.scene.Scene.init(self.allocator, self.io, self.log_cfg) catch |err| {
        log.err("scene init failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    const scene_output = wayland.scene.SceneOutput.create(
        self.allocator,
        self.io,
        self.log_cfg,
        scene,
        out,
    ) catch |err| {
        scene.deinit();
        log.err("scene output init failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    // Background rect covering the whole output (draws first, under the
    // surface nodes).
    const bg = wayland.scene.SceneNode.create(self.allocator, scene.root, .rect) catch |err| {
        scene_output.destroy();
        scene.deinit();
        log.err("scene background init failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    bg.kind.rect.width = out.mode.width;
    bg.kind.rect.height = out.mode.height;
    bg.kind.rect.color = background_color;

    self.scene = scene;
    self.scene_output = scene_output;
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

    // M2: surfaces created since the last frame get scene nodes.
    syncSurfaces(self);

    const so = self.scene_output orelse {
        log.err("render: no scene output", self.io, self.log_cfg, "server", .{});
        return;
    };

    // Single reused framebuffer; repaint everything every frame.
    so.damage_ring.addWhole();

    // The surfaces about to be drawn this frame (presentation feedback
    // targets): every tracked surface with an active scene node.
    // Rebuilt each frame; the compositor drives this loop.
    self.presented.clearRetainingCapacity();
    var entry_it = self.surface_entries.valueIterator();
    while (entry_it.next()) |entry| {
        if (entry.*.node != null) {
            self.presented.append(self.allocator, entry.*.surface) catch |err| {
                log.warn("presented list append OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            };
        }
    }

    // Composite the scene into the framebuffer, then present it.
    so.render(self.renderer, self.framebuffer);
    _ = so.damage_ring.rotate();

    // Present: hand the framebuffer to the output, damage the whole screen.
    var state = wayland.output.Output.State.init(self.allocator);
    defer state.deinit();
    state.committed = wayland.output.Output.State.committed_enabled |
        wayland.output.Output.State.committed_mode |
        wayland.output.Output.State.committed_buffer;
    state.enabled = true;
    state.mode = .{ .width = output_width, .height = output_height, .refresh_msec = output_refresh_msec };
    state.buffer = @ptrCast(self.framebuffer);
    state.damage.addWhole();
    out.commitState(&state) catch |err| {
        log.err("output commit failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };

    // wp_presentation: every surface drawn this frame was presented.
    self.presentation.present(self.presented.items, @intCast(output_refresh_msec), 0);

    self.frames_rendered += 1;
    tracy.frameMark(null);
    log.debug("render frame={d} surfaces={d}", self.io, self.log_cfg, "server", .{
        self.frames_rendered,
        self.presented.items.len,
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
// Scene surface tracking
// ---------------------------------------------------------------------------

/// Subscribe to commit/destroy on every compositor surface we do not
/// track yet, and initialize the scene node from its current state (the
/// surface may have committed before we subscribed). Called from the
/// frame handler, so surfaces created in the same dispatch are caught.
fn syncSurfaces(self: *ServerState) void {
    for (self.compositor.surfaces.items) |s| {
        if (self.surface_entries.contains(s)) continue;
        const entry = self.allocator.create(SurfaceEntry) catch |err| {
            log.warn("failed to track surface: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            continue;
        };
        entry.* = .{
            .state = self,
            .surface = s,
            .node = null,
            .commit_listener = wire.Listener(*Surface).init(onSurfaceCommit),
            .destroy_listener = wire.Listener(*Surface).init(onSurfaceDestroy),
        };
        self.surface_entries.put(s, entry) catch |err| {
            self.allocator.destroy(entry);
            log.warn("failed to track surface: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            continue;
        };
        s.events.commit.add(&entry.commit_listener);
        s.events.destroy.add(&entry.destroy_listener);
        updateSurfaceNode(self, entry);
    }
}

/// wl_surface.commit applied: refresh the surface's scene node from its
/// current buffer. A committed buffer means the surface maps (or keeps
/// mapping) with content; a null buffer unmaps it.
fn onSurfaceCommit(listener: *wire.Listener(*Surface), _: *Surface) void {
    const entry: *SurfaceEntry = @fieldParentPtr("commit_listener", listener);
    updateSurfaceNode(entry.state, entry);
}

/// wl_surface destroyed: drop the scene node, deliver discarded feedback,
/// and free the tracking entry. The surface is still valid inside the
/// destroy signal (its buffers are released after the signal).
fn onSurfaceDestroy(listener: *wire.Listener(*Surface), s: *Surface) void {
    const entry: *SurfaceEntry = @fieldParentPtr("destroy_listener", listener);
    const self = entry.state;
    removeSurfaceNode(self, entry);
    self.presentation.discard(s);
    _ = self.surface_entries.remove(s);
    self.allocator.destroy(entry);
}

/// Ensure the surface's scene node exists and shows its current buffer;
/// remove it when the surface has no buffer (unmapped).
fn updateSurfaceNode(self: *ServerState, entry: *SurfaceEntry) void {
    const s = entry.surface;
    const buf = s.buffer orelse {
        removeSurfaceNode(self, entry);
        return;
    };
    const texture = importSurfaceTexture(self, buf) orelse return;
    if (entry.node) |node| {
        // Update in place: swap in the new texture (1:1, dst = buffer size).
        const bn = node.kind.buffer;
        if (bn.texture) |old| old.destroy();
        bn.texture = texture;
        bn.dst_width = buf.width;
        bn.dst_height = buf.height;
        node.enable(true);
    } else {
        const node = wayland.scene.SceneNode.create(self.allocator, self.scene.?.root, .buffer) catch |err| {
            texture.destroy();
            log.warn("scene node create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            return;
        };
        node.kind.buffer.texture = texture;
        node.kind.buffer.dst_width = buf.width;
        node.kind.buffer.dst_height = buf.height;
        entry.node = node;
    }
}

/// Remove (and free) the surface's scene node; the entry keeps tracking
/// the surface for a future remap.
fn removeSurfaceNode(self: *ServerState, entry: *SurfaceEntry) void {
    if (entry.node) |node| {
        if (node.kind.buffer.texture) |texture| texture.destroy();
        node.destroy(self.allocator);
        entry.node = null;
    }
}

/// Copy the surface's current buffer into a renderer texture (same import
/// path the M1 render loop used per frame; the scene node owns the copy).
fn importSurfaceTexture(self: *ServerState, buf: *wayland.buffers.Buffer) ?*Texture {
    const get_shm = buf.impl.get_shm orelse return null;
    const shm = get_shm(buf) orelse return null;
    const begin = buf.impl.begin_data_ptr_access orelse return null;
    const end = buf.impl.end_data_ptr_access orelse return null;

    const pixels = begin(buf) catch return null;
    defer end(buf);
    const ptr = pixels orelse return null;
    const stride = wire.shm.Buffer.getStride(shm);
    const byte_len = @as(usize, @intCast(stride)) * @as(usize, @intCast(buf.height));
    return pixman.PixmanRenderer.importMemory(
        self.renderer,
        buf.width,
        buf.height,
        stride,
        ptr[0..byte_len],
    ) catch null;
}

/// Tear down every surface entry (listeners, scene nodes, allocations).
/// Runs before the scene and compositor teardown in main().
fn cleanupSurfaceEntries(self: *ServerState) void {
    var it = self.surface_entries.valueIterator();
    while (it.next()) |entry_ptr| {
        const entry = entry_ptr.*;
        entry.commit_listener.link.remove();
        entry.destroy_listener.link.remove();
        removeSurfaceNode(self, entry);
        self.allocator.destroy(entry);
    }
    self.surface_entries.deinit();
    self.presented.deinit(self.allocator);
}

/// WAYLAND_BACKEND=raylib selects the windowed raylib debug backend.
fn wantRaylibBackend(environ_map: *std.process.Environ.Map) bool {
    const v = environ_map.get("WAYLAND_BACKEND") orelse return false;
    return std.mem.eql(u8, v, "raylib");
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
