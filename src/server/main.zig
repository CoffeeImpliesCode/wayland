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
/// DRM/KMS backend (src/backend/drm.zig): native output on /dev/dri/cardN
/// with dumb-buffer scanout (WAYLAND_BACKEND=drm).
const drm_mod = @import("wayland").drm;
/// libinput backend (src/backend/libinput.zig): evdev devices through
/// libinput (WAYLAND_LIBINPUT=1).
const libinput_mod = @import("wayland").libinput;
/// The raylib input source feeds the seat from the window's keyboard and
/// mouse; same -Denable_raylib guard.
const raylib_input_impl = @import("raylib_input.zig");
const raylib_input_mod = if (build_options.enable_raylib) raylib_input_impl else null;
/// The ServerState field type: real pointer with raylib, void without
/// (a bare `?*null.RaylibInput` would not compile headless-only builds).
const RaylibInputPtr = if (build_options.enable_raylib) ?*raylib_input_mod.RaylibInput else void;

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
const geom = wayland.utils.geom;
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
/// M4 camera + canvas pass (wayland.camera / wayland.canvas): the
/// camera-transformed compositing path replacing the scene-output render.
const Camera = wayland.camera.Camera;
const CanvasItem = wayland.canvas.CanvasItem;

const output_width: i32 = 1280;
const output_height: i32 = 720;
const output_refresh_msec: i32 = 16;
const watchdog_timeout_ms: u64 = 5000;
/// Background color (straight alpha RGBA).
const background_color = [4]f32{ 0.1, 0.1, 0.12, 1.0 };
/// Fallback cursor: a small light rect when no client cursor surface.
const cursor_size: i32 = 8;
const cursor_color = [4]f32{ 0.95, 0.95, 0.95, 1.0 };

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
    /// M4 camera: the world→screen mapping for the canvas pass. Parsed
    /// from WAYLAND_CAMERA in onNewOutput once the real output size is
    /// known (the DRM mode can differ from the 1280x720 defaults); the
    /// default camera centers the world origin on the viewport center
    /// (zoom 1, no rotation), so worldToScreen is the identity mapping —
    /// today's no-camera composite.
    camera: Camera,
    /// Raw WAYLAND_CAMERA value, borrowed from the process environ
    /// (parsed in onNewOutput with the output size).
    camera_env: ?[]const u8,
    /// M2 scene graph: one scene and one output view (single-output server).
    scene: ?*wayland.scene.Scene = null,
    scene_output: ?*wayland.scene.SceneOutput = null,
    /// M3 input: the seat (keyboard + pointer) and its input source (the
    /// raylib window when the raylib backend is active).
    seat: *wayland.seat.Seat,
    /// wl_subcompositor: subsurface surfaces render over their parents.
    subcompositor: *wayland.subsurface.Subcompositor,
    /// wl_data_device_manager: clipboard selection relay.
    data_device: *wayland.data_device.DataDeviceManager,
    /// The raylib input poll object (null in headless mode).
    raylib_input: RaylibInputPtr = if (build_options.enable_raylib) null else {},
    /// The libinput backend (evdev input source), when active.
    input_backend: ?*wayland.backend.Backend = null,
    /// The DRM backend's poll fd watcher state (page-flip events).
    drm_poll_fd: c_int = -1,
    /// The DRM backend (when WAYLAND_BACKEND=drm).
    drm_backend: ?*wayland.backend.Backend = null,
    // SAFETY: initialized in main() before the backend starts.
    new_input_listener: wire.Listener(*wayland.backend.Backend.InputDevice),
    /// wl_output protocol global for the backend output.
    wl_output: ?*wayland.wl_output.WlOutput = null,
    screencopy: ?*wayland.screencopy.Screencopy = null,
    /// Cursor rendering: a fallback rect node plus a buffer node showing
    /// the client cursor surface (wl_pointer.set_cursor). Non-pickable.
    cursor_rect_node: ?*wayland.scene.SceneNode = null,
    cursor_buf_node: ?*wayland.scene.SceneNode = null,
    cursor_texture: ?*Texture = null,
    /// M4: the fallback cursor's texture (a light-grey cursor_size²
    /// square — the M3 fallback rect's color), created lazily on first
    /// render and owned by the state.
    cursor_fallback_texture: ?*Texture = null,
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
    /// WAYLAND_SYNTH_INPUT=1: synthesize one pointer click + key press
    /// once the first surface is mapped (headless input E2E).
    synth_input: bool = false,
    synth_fired: bool = false,
    /// WAYLAND_PERF=1: log per-frame pipeline timings (import -> render
    /// -> present) in microseconds.
    perf: bool = false,

    new_output_listener: wire.Listener(*wayland.output.Output),
    frame_listener: wire.Listener(*wayland.output.Output),
    new_toplevel_listener: wire.Listener(*wayland.shell.XdgToplevel),
    new_popup_listener: wire.Listener(*wayland.shell.XdgPopup),
    seat_key_listener: wire.Listener(*wayland.seat.Seat),
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

    // Teardown order (LIFO on the defers): wl_shm outlives the compositor,
    // so shm_state.deinit is registered FIRST and runs LAST. Both inits
    // only need the display; setShm wires them together after both exist.
    const shm_state = try wayland.shm.ShmState.init(allocator, io, &log_cfg, display);
    defer shm_state.deinit();
    const compositor = try wayland.compositor.Compositor.init(allocator, io, &log_cfg, display);
    defer compositor.deinit();
    compositor.setShm(shm_state);
    const shell = try wayland.shell.XdgShell.init(allocator, io, &log_cfg, display, compositor);
    defer shell.deinit();
    // M3: the seat (keyboard + pointer) with the xkbcommon us keymap.
    const seat = try wayland.seat.Seat.init(allocator, io, &log_cfg, display);
    defer seat.deinit();
    // Subcompositor (foot needs wl_subcompositor).
    const subcompositor = try wayland.subsurface.Subcompositor.init(allocator, io, &log_cfg, display, compositor);
    defer subcompositor.deinit();
    // Data device manager (foot requires it; clipboard selection relay).
    const data_device = try wayland.data_device.DataDeviceManager.init(allocator, io, &log_cfg, display, seat);
    defer data_device.deinit();
    const renderer = try pixman.PixmanRenderer.create(allocator, io, &log_cfg);
    defer renderer.destroy();
    // Backend selection: WAYLAND_BACKEND=raylib uses the windowed raylib
    // debug backend (falling back to headless when the window cannot
    // open); anything else uses the headless backend. The raylib path is
    // only reachable when built with -Denable_raylib (default on).
    var backend_is_raylib = false;
    var backend_is_drm = false;
    const backend = blk: {
        // DRM/KMS native output (tested in the NixOS VM on virtio-gpu).
        if (wantDrmBackend(init.environ_map)) {
            const device = init.environ_map.get("WAYLAND_DRM_DEVICE");
            const b = try drm_mod.DrmBackend.create(allocator, io, &log_cfg, device);
            backend_is_drm = true;
            break :blk b;
        }
        if (build_options.enable_raylib and wantRaylibBackend(init.environ_map)) {
            const b = raylib_mod.RaylibBackend.create(
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
            backend_is_raylib = true;
            break :blk b;
        }
        // Unknown WAYLAND_BACKEND value: headless fallback with a warning.
        // An unset variable is the normal default (no warning); the raylib
        // window-open failure logs its own warning above.
        if (init.environ_map.get("WAYLAND_BACKEND")) |v| {
            const known = std.mem.eql(u8, v, "drm") or
                (build_options.enable_raylib and std.mem.eql(u8, v, "raylib"));
            if (!known) {
                log.warn("WAYLAND_BACKEND '{s}' unknown; using headless backend", io, &log_cfg, "server", .{v});
            }
        }
        break :blk try wayland.headless.HeadlessBackend.create(
            allocator,
            io,
            &log_cfg,
            display.getServer().getEventLoop(),
            .{ .width = output_width, .height = output_height, .refresh_msec = output_refresh_msec },
        );
    };
    defer backend.destroy();

    const framebuffer = try pixman.Framebuffer.create(allocator, output_width, output_height);
    defer framebuffer.deinit();

    // libinput input source (evdev devices; VM: virtio keyboard/mouse).
    // A second Backend whose only role is announcing devices + the poll fd
    // the zio loop watches; events flow into the seat via its dispatch.
    var input_backend: ?*wayland.backend.Backend = null;
    if (init.environ_map.get("WAYLAND_LIBINPUT")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            input_backend = try libinput_mod.LibinputBackend.create(
                allocator,
                io,
                &log_cfg,
                seat,
                "seat0",
                output_width,
                output_height,
            );
        } else {
            log.warn("WAYLAND_LIBINPUT '{s}' ignored (expected \"1\")", io, &log_cfg, "server", .{v});
        }
    }
    // Function-scope: the backend is used until the event loop exits.
    defer if (input_backend) |ib| ib.destroy();

    var state: ServerState = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = &log_cfg,
        .display = display,
        .compositor = compositor,
        .shm_state = shm_state,
        .shell = shell,
        .seat = seat,
        .subcompositor = subcompositor,
        .data_device = data_device,
        .renderer = renderer,
        .backend = backend,
        .framebuffer = framebuffer,
        .camera = Camera{
            .center_x = @as(f64, @floatFromInt(output_width)) / 2.0,
            .center_y = @as(f64, @floatFromInt(output_height)) / 2.0,
            .zoom = 1,
            .rotation = 0,
            .screen_w = @floatFromInt(output_width),
            .screen_h = @floatFromInt(output_height),
        },
        .camera_env = init.environ_map.get("WAYLAND_CAMERA"),
        .presentation = presentation,
        .surface_entries = std.AutoHashMap(*Surface, *SurfaceEntry).init(allocator),
        .toplevels = .empty,
        .new_output_listener = wire.Listener(*wayland.output.Output).init(onNewOutput),
        .new_input_listener = wire.Listener(*wayland.backend.Backend.InputDevice).init(onNewInput),
        .frame_listener = wire.Listener(*wayland.output.Output).init(onOutputFrame),
        .new_toplevel_listener = wire.Listener(*wayland.shell.XdgToplevel).init(onNewToplevel),
        .new_popup_listener = wire.Listener(*wayland.shell.XdgPopup).init(onNewPopup),
        .seat_key_listener = wire.Listener(*wayland.seat.Seat).init(onSeatKey),
    };
    if (backend_is_drm) state.drm_backend = backend;
    defer state.toplevels.deinit(allocator);
    // Scene teardown (LIFO): drop the per-surface scene state first, then
    // the scene output view, then the scene tree itself. The compositor
    // (deferred earlier in main) destroys its surfaces afterwards; the
    // listeners were already removed, so no entry is freed twice.
    defer if (state.scene) |scene| scene.deinit();
    defer if (state.scene_output) |so| so.destroy();
    defer cleanupSurfaceEntries(&state);

    backend.events.new_output.add(&state.new_output_listener);
    if (input_backend) |ib| {
        state.input_backend = ib;
        ib.events.new_input.add(&state.new_input_listener);
    }
    shell.events.new_toplevel.add(&state.new_toplevel_listener);
    shell.events.new_popup.add(&state.new_popup_listener);
    seat.events.key.add(&state.seat_key_listener);
    // The compositor hit-tests over the scene graph: surfaces map to
    // scene nodes through the surface entries.
    seat.setPick(pickSurface, &state);

    // zwlr_screencopy_v1: captures the compositor framebuffer (shm only).
    state.screencopy = try wayland.screencopy.Screencopy.init(
        allocator,
        io,
        &log_cfg,
        display,
        shm_state,
        getFramebuffer,
        &state,
        ownsOutput,
        &state,
        captureClock,
        &state,
    );
    defer if (state.screencopy) |sc| sc.deinit();

    if (init.environ_map.get("WAYLAND_RUN_FRAMES")) |frames| {
        state.run_frames = std.fmt.parseInt(u32, frames, 10) catch |err| blk: {
            log.warn(
                "WAYLAND_RUN_FRAMES '{s}' not parseable ({s}); running until watchdog",
                io,
                &log_cfg,
                "server",
                .{ frames, @errorName(err) },
            );
            break :blk 0;
        };
        if (state.run_frames > 0) {
            log.info("WAYLAND_RUN_FRAMES: stopping after {d} frames", io, &log_cfg, "server", .{state.run_frames});
        }
    }
    if (init.environ_map.get("WAYLAND_SYNTH_INPUT")) |v| {
        if (std.mem.eql(u8, v, "1")) state.synth_input = true;
    }
    if (init.environ_map.get("WAYLAND_PERF")) |v| {
        if (std.mem.eql(u8, v, "1")) state.perf = true;
    }

    // The raylib window is the M3 input source: the backend polls raylib
    // state every commit and feeds the seat through raylib_input.poll.
    // Only when the raylib backend actually owns the backend object (the
    // headless fallback has no input source).
    if (backend_is_raylib and build_options.enable_raylib) {
        const input = try raylib_input_mod.create(allocator, state.seat);
        state.raylib_input = input;
        raylib_mod.RaylibBackend.setInputHook(state.backend, raylib_input_mod.poll, input);
        log.info("raylib input source attached", io, &log_cfg, "server", .{});
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

    // --- zio event loop ---------------------------------------------------
    // SAFETY: initialized by loop.init() immediately below, before any use.
    var loop: zio.ev.Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();
    state.loop = &loop;

    // Watchdog: registered BEFORE backend.start() so the first DRM frame's
    // re-arm (renderFrame) targets a timer already in the loop — a frame
    // can render as soon as the loop starts dispatching, and re-arming an
    // un-added timer would be a no-op. It fires only when nothing re-arms
    // it for the full window; a wedged loop stops with an error instead
    // of hanging tests.
    var watchdog = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(watchdog_timeout_ms) });
    watchdog.c.userdata = &state;
    watchdog.c.callback = onWatchdog;
    state.watchdog = &watchdog;
    loop.add(&watchdog.c);

    try backend.start(); // fires new_output; the headless timer paces frames
    if (input_backend) |ib| try ib.start();

    // Watch the display fd: readable when a client sent requests or a wire
    // timer (headless frame pacing) is due. Rearm keeps the registration.
    var display_poll = zio.ev.PipePoll.init(display.loopFd(), .read);
    display_poll.c.userdata = &state;
    display_poll.c.callback = onDisplayReady;
    display_poll.c.flags.rearm = true;
    loop.add(&display_poll.c);

    // libinput: watch the udev/evdev fd; dispatch drains events into the seat.
    if (input_backend) |ib| {
        const input_fd = libinput_mod.LibinputBackend.fromBackend(ib).pollFd();
        var input_poll = zio.ev.PipePoll.init(input_fd, .read);
        input_poll.c.userdata = &state;
        input_poll.c.callback = onInputReady;
        input_poll.c.flags.rearm = true;
        loop.add(&input_poll.c);
    }
    // DRM: watch the card fd for page-flip events (the frame pacing).
    if (backend_is_drm) {
        const drm_fd = drm_mod.pollFd(drm_mod.DrmBackend.fromBackend(backend));
        state.drm_poll_fd = drm_fd;
        var drm_poll = zio.ev.PipePoll.init(drm_fd, .read);
        drm_poll.c.userdata = &state;
        drm_poll.c.callback = onDrmReady;
        drm_poll.c.flags.rearm = true;
        loop.add(&drm_poll.c);
    }

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

/// A backend announced an input device (libinput udev enumeration).
fn onNewInput(
    listener: *wire.Listener(*wayland.backend.Backend.InputDevice),
    device: *wayland.backend.Backend.InputDevice,
) void {
    const self: *ServerState = @fieldParentPtr("new_input_listener", listener);
    log.info("libinput: device {s} ({s})", self.io, self.log_cfg, "libinput", .{
        device.name, @tagName(device.kind),
    });
}

fn onNewOutput(listener: *wire.Listener(*wayland.output.Output), out: *wayland.output.Output) void {
    const self: *ServerState = @fieldParentPtr("new_output_listener", listener);
    self.output = out;
    log.info("new output {d}x{d} refresh={d}ms", self.io, self.log_cfg, "server", .{
        out.mode.width, out.mode.height, out.mode.refresh_msec,
    });
    // The DRM backend drives its connector's preferred mode: resize the
    // render framebuffer to match (headless/raylib stay at the defaults).
    if (out.mode.width != output_width or out.mode.height != output_height) {
        const fb = pixman.Framebuffer.create(self.allocator, out.mode.width, out.mode.height) catch |err| {
            log.err("framebuffer resize failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            return;
        };
        self.framebuffer.deinit();
        self.framebuffer = fb;
        log.info("framebuffer resized to {d}x{d}", self.io, self.log_cfg, "server", .{
            out.mode.width, out.mode.height,
        });
    }

    // M4 camera: parse WAYLAND_CAMERA with the REAL output size — the
    // camera's viewport must match the framebuffer, so this runs after
    // the resize above (unset/unparseable keeps the identity-behavior
    // default, see parseCameraEnv).
    self.camera = parseCameraEnv(self.camera_env, out.mode.width, out.mode.height);

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
    // M4: the background is drawn by the canvas pass (fb.fill) instead of
    // a scene rect node — the scene graph is no longer rendered.
    self.scene = scene;
    self.scene_output = scene_output;
    out.events.frame.add(&self.frame_listener);

    // M3: expose the output to clients (geometry/mode/scale/name) and
    // build the cursor nodes (drawn above the surfaces, never picked).
    self.wl_output = wayland.wl_output.WlOutput.create(
        self.allocator,
        self.io,
        self.log_cfg,
        self.display,
        out,
        "WL-1",
        "wayland debug output",
    ) catch |err| {
        log.err("wl_output create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    const cursor_rect = wayland.scene.SceneNode.create(self.allocator, scene.root, .rect) catch |err| {
        log.err("cursor rect create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    cursor_rect.pickable = false;
    cursor_rect.kind.rect.width = cursor_size;
    cursor_rect.kind.rect.height = cursor_size;
    cursor_rect.kind.rect.color = cursor_color;
    cursor_rect.enable(false);
    self.cursor_rect_node = cursor_rect;
    const cursor_buf = wayland.scene.SceneNode.create(self.allocator, scene.root, .buffer) catch |err| {
        log.err("cursor buffer create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    cursor_buf.pickable = false;
    cursor_buf.enable(false);
    self.cursor_buf_node = cursor_buf;
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

fn onInputReady(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    _ = loop;
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    if (self.input_backend) |ib| {
        libinput_mod.LibinputBackend.fromBackend(ib).dispatch() catch |err| {
            log.err("libinput dispatch failed: {s}", self.io, self.log_cfg, "libinput", .{@errorName(err)});
            // Fatal device error: stop the loop (tests must not hang).
            if (err == error.BackendFailed) self.loop.?.stop();
        };
    }
}

fn onDrmReady(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    _ = loop;
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    if (self.drm_poll_fd >= 0) {
        drm_mod.dispatch(drm_mod.DrmBackend.fromBackend(self.drm_backend.?)) catch |err| {
            log.err("drm dispatch failed: {s}", self.io, self.log_cfg, "drm", .{@errorName(err)});
            // Fatal device error: stop the loop (tests must not hang).
            if (err == error.BackendFailed) self.loop.?.stop();
        };
    }
}

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
    log.debug("display ready: dispatch done", self.io, self.log_cfg, "server", .{});
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
    const perf_t0 = perfNs(self);

    // M2: surfaces created since the last frame get scene nodes.
    syncSurfaces(self);
    const perf_t_sync = perfNs(self);
    // Subsurfaces: position child nodes over their mapped parent.
    syncSubsurfaceNodes(self);

    // M3 synth input: one pointer click + key press once the first
    // surface is mapped (headless E2E). Event-driven: the map time varies
    // with client startup, so a fixed frame number would race.
    if (self.synth_input and !self.synth_fired) {
        var any_mapped = false;
        var entry_it = self.surface_entries.valueIterator();
        while (entry_it.next()) |ep| {
            if (ep.*.node != null) {
                any_mapped = true;
                break;
            }
        }
        if (any_mapped) {
            self.synth_fired = true;
            const seat = self.seat;
            seat.pointerMotion(50, 50);
            seat.pointerButton(wayland.seat.btn_left, true);
            seat.pointerButton(wayland.seat.btn_left, false);
            seat.keyEvent(38, true); // 'a' (evdev A + 8)
            seat.keyEvent(38, false);
            log.info("synth input: pointer click + key 'a' at 50,50", self.io, self.log_cfg, "server", .{});
        }
    }

    const so = self.scene_output orelse {
        log.err("render: no scene output", self.io, self.log_cfg, "server", .{});
        return;
    };

    // M3 cursor: follow the seat pointer, show the client cursor surface
    // or the fallback rect. Capture the previous frame's cursor footprints
    // BEFORE updateCursor moves the nodes: a partial upload must repaint
    // both the old and the new position.
    const old_cursor = cursorFootprints(self);
    updateCursor(self);
    const new_cursor = cursorFootprints(self);
    const perf_t_cursor = perfNs(self);

    // Damage accumulation: this frame's surface damage translated into
    // output coordinates, plus the cursor's old+new footprints. The ring
    // is the upload region for the raylib backend; the pixman repaint
    // below stays a full repaint. The first frame damages the whole
    // output — the window texture starts blank, so a partial first upload
    // would leave the background uninitialized.
    if (self.frames_rendered == 0) {
        so.addDamage(.{ .x = 0, .y = 0, .width = out.mode.width, .height = out.mode.height });
    }
    const out_rect: geom.Rect = .{ .x = 0, .y = 0, .width = out.mode.width, .height = out.mode.height };
    // The surfaces about to be drawn this frame (presentation feedback
    // targets): every tracked surface with an active scene node.
    // Rebuilt each frame; the compositor drives this loop.
    self.presented.clearRetainingCapacity();
    var entry_it = self.surface_entries.valueIterator();
    while (entry_it.next()) |entry| {
        const node = entry.*.node orelse continue;
        self.presented.append(self.allocator, entry.*.surface) catch |err| {
            log.warn("presented list append OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        };
        // Translate the surface's damaged rects (surface coordinates) by
        // the node's absolute position into output coordinates, clipped
        // to the output (damage is a hint; clipping is safe).
        const abs = node.absolutePosition();
        for (entry.*.surface.current.surface_damage.rects.items) |rect| {
            const translated: geom.Rect = .{
                .x = addSat(abs.x, rect.x),
                .y = addSat(abs.y, rect.y),
                .width = rect.width,
                .height = rect.height,
            };
            if (out_rect.intersect(translated)) |visible| so.addDamage(visible);
        }
    }
    if (!std.meta.eql(old_cursor[0], new_cursor[0]) or !std.meta.eql(old_cursor[1], new_cursor[1])) {
        for (old_cursor) |r| if (r) |rr| so.addDamage(rr);
        for (new_cursor) |r| if (r) |rr| so.addDamage(rr);
    }

    // Composite the canvas into the framebuffer, then present it. M4:
    // the canvas pass (background fill + camera-transformed surface
    // textures + screen-space cursor) replaces the scene-output render;
    // the damage-ring accounting below is unchanged.
    compositeCanvas(self);
    _ = so.damage_ring.rotate();
    const perf_t_render = perfNs(self);

    // Present: hand the framebuffer to the output. The output damage is
    // the ring's rects for this frame — the raylib backend uploads only
    // that region. An empty ring (nothing changed, or whole damage) falls
    // back to a whole-output damage.
    var state = wayland.output.Output.State.init(self.allocator);
    defer state.deinit();
    state.committed = wayland.output.Output.State.committed_enabled |
        wayland.output.Output.State.committed_mode |
        wayland.output.Output.State.committed_buffer;
    state.enabled = true;
    state.mode = .{ .width = out.mode.width, .height = out.mode.height, .refresh_msec = out.mode.refresh_msec };
    state.buffer = @ptrCast(self.framebuffer);
    const damage_rects = so.takeDamage();
    if (damage_rects.len == 0) {
        state.damage.addWhole();
    } else {
        for (damage_rects) |rect| {
            state.damage.add(rect) catch {
                state.damage.addWhole();
                break;
            };
        }
    }
    out.commitState(&state) catch |err| {
        log.err("output commit failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    const perf_t_present = perfNs(self);

    // Frame callbacks: the surfaces presented this frame get
    // wl_callback.done at present time (wlroots wlr_surface_send_frame_done,
    // wlr_compositor.c:1131-1139). The time is the monotonic clock in ms
    // (.awake = CLOCK_MONOTONIC in the 0.16 std.Io.Clock); the u32
    // wrap-around is fine — the protocol defines an undefined base.
    const now_ms: u32 = @truncate(@as(u64, @bitCast(std.Io.Clock.now(.awake, self.io.*).toMilliseconds())));
    for (self.presented.items) |s| s.sendFrameDone(now_ms);

    if (self.perf) {
        log.info(perf_frame_fmt, self.io, self.log_cfg, "perf", .{
            self.frames_rendered,
            (perf_t_sync - perf_t0) / 1000,
            (perf_t_cursor - perf_t_sync) / 1000,
            (perf_t_render - perf_t_cursor) / 1000,
            (perf_t_present - perf_t_render) / 1000,
            (perf_t_present - perf_t0) / 1000,
        });
    }

    // wp_presentation: every surface drawn this frame was presented.
    self.presentation.present(self.presented.items, @intCast(output_refresh_msec), 0);

    self.frames_rendered += 1;
    tracy.frameMark(null);
    log.debug("render frame={d} surfaces={d}", self.io, self.log_cfg, "server", .{
        self.frames_rendered,
        self.presented.items.len,
    });

    // Frame-done and presentation events were marshalled above; push them
    // out now. onDisplayReady flushes after dispatching client requests,
    // but a DRM-driven frame loop runs from the flip event instead, where
    // the display fd may be idle (a silent client) — without this the
    // callbacks sit in the outbound buffer forever. Idempotent when the
    // headless timer path already flushed.
    self.display.flushClients();

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

/// Composite one frame into the framebuffer with the M4 canvas pass:
/// 1. background fill (fb.fill — the scene's background rect is gone),
/// 2. every mapped surface's texture stamped at its world rect (the
///    node's absolute position + buffer size, 1:1) through the server
///    camera — canvas.render composites in array order, so the last item
///    draws on top (the entry iteration order, same as the presented
///    list; the E2E has a single surface),
/// 3. the cursor in SCREEN space through an identity camera (constant
///    size, canvas-compositing.md §4). The cursor scene nodes remain as
///    state (updateCursor/cursorFootprints still position them for the
///    damage ring) but are no longer drawn by the scene.
fn compositeCanvas(self: *ServerState) void {
    // 1. Background. Premultiplied ARGB8888, memory bytes B,G,R,A; the
    //    scene's background rect drew the same color via addRect
    //    (round(color*a*255) per channel with straight alpha a=1), so
    //    the bytes are identical.
    const bg: [4]u8 = .{
        @intFromFloat(@round(background_color[2] * 255.0)),
        @intFromFloat(@round(background_color[1] * 255.0)),
        @intFromFloat(@round(background_color[0] * 255.0)),
        @intFromFloat(@round(background_color[3] * 255.0)),
    };
    self.framebuffer.fill(bg);

    // 2. Surfaces: world rect = the node's absolute position + buffer
    //    size (opacity 1.0; skip nodes without a texture).
    var items: std.ArrayList(CanvasItem) = .empty;
    defer items.deinit(self.allocator);
    var entry_it = self.surface_entries.valueIterator();
    while (entry_it.next()) |entry| {
        const node = entry.*.node orelse continue;
        const bn = node.kind.buffer;
        const texture = bn.texture orelse continue;
        const rect = node.absolutePosition();
        items.append(self.allocator, .{
            .texture = texture,
            .world_x = @floatFromInt(rect.x),
            .world_y = @floatFromInt(rect.y),
            .world_w = @floatFromInt(rect.width),
            .world_h = @floatFromInt(rect.height),
            .opacity = 1.0,
        }) catch |err| {
            log.warn("canvas item append OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        };
    }
    wayland.canvas.render(self.allocator, self.framebuffer, &self.camera, items.items);

    // 3. Cursor: screen space at constant size. The identity camera
    //    (center W/2,H/2, zoom 1, no rotation) makes worldToScreen the
    //    identity mapping, so items placed at the pointer's screen coords
    //    land on exactly those pixels. The fallback rect is a texture
    //    now — the canvas pass draws textures, not scene rects — and the
    //    client cursor surface texture wins when one is set.
    const identity: Camera = .{
        .center_x = @as(f64, @floatFromInt(self.framebuffer.width)) / 2.0,
        .center_y = @as(f64, @floatFromInt(self.framebuffer.height)) / 2.0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = @floatFromInt(self.framebuffer.width),
        .screen_h = @floatFromInt(self.framebuffer.height),
    };
    var cursor_items: [1]CanvasItem = undefined;
    if (self.cursor_texture) |tex| {
        const seat = self.seat;
        cursor_items[0] = .{
            .texture = tex,
            .world_x = @floatFromInt(seat.pointer_x - seat.cursor_hotspot_x),
            .world_y = @floatFromInt(seat.pointer_y - seat.cursor_hotspot_y),
            .world_w = @floatFromInt(tex.width),
            .world_h = @floatFromInt(tex.height),
            .opacity = 1.0,
        };
    } else {
        const tex = ensureCursorFallbackTexture(self) orelse return;
        cursor_items[0] = .{
            .texture = tex,
            .world_x = @floatFromInt(self.seat.pointer_x),
            .world_y = @floatFromInt(self.seat.pointer_y),
            .world_w = @floatFromInt(cursor_size),
            .world_h = @floatFromInt(cursor_size),
            .opacity = 1.0,
        };
    }
    wayland.canvas.render(self.allocator, self.framebuffer, &identity, &cursor_items);
}

/// The fallback cursor's texture: a solid light-grey cursor_size² square
/// (the M3 fallback rect's color), created once and reused. The canvas
/// pass draws textures only, so the rect becomes a texture; owned by the
/// state and destroyed in cleanupSurfaceEntries.
fn ensureCursorFallbackTexture(self: *ServerState) ?*Texture {
    if (self.cursor_fallback_texture) |t| return t;
    const n: usize = @as(usize, @intCast(cursor_size)) * @as(usize, @intCast(cursor_size));
    var pixels: [n * 4]u8 = undefined;
    const color: [4]u8 = .{
        @intFromFloat(@round(cursor_color[2] * 255.0)),
        @intFromFloat(@round(cursor_color[1] * 255.0)),
        @intFromFloat(@round(cursor_color[0] * 255.0)),
        @intFromFloat(@round(cursor_color[3] * 255.0)),
    };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pixels[i * 4 ..][0..4].* = color;
    }
    const tex = pixman.PixmanRenderer.importMemory(
        self.renderer,
        cursor_size,
        cursor_size,
        cursor_size * 4,
        &pixels,
    ) catch |err| {
        log.err("cursor fallback texture import failed: {s}", self.io, self.log_cfg, "server", .{
            @errorName(err),
        });
        return null;
    };
    self.cursor_fallback_texture = tex;
    return tex;
}

/// The M4 camera from WAYLAND_CAMERA ("cx=…,cy=…,zoom=…,rot=…") parsed
/// with the output size; unset or unparseable values fall back to the
/// default camera — center at the output center, zoom 1, no rotation —
/// whose worldToScreen is the identity mapping (today's no-camera
/// behavior; camera.isIdentity()'s center-(0,0) form is NOT the server
/// default, which would shift every surface by half a viewport).
fn parseCameraEnv(env_value: ?[]const u8, w: i32, h: i32) Camera {
    const default: Camera = .{
        .center_x = @as(f64, @floatFromInt(w)) / 2.0,
        .center_y = @as(f64, @floatFromInt(h)) / 2.0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = @floatFromInt(w),
        .screen_h = @floatFromInt(h),
    };
    const value = env_value orelse return default;
    return wayland.camera.parseEnv(value, @intCast(w), @intCast(h)) orelse default;
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
    self.seat.surfaceDestroyed(s);
    self.presentation.discard(s);
    _ = self.surface_entries.remove(s);
    self.allocator.destroy(entry);
}

/// Ensure the surface's scene node exists and shows its current buffer;
/// remove it when the surface has no buffer (unmapped).
fn updateSurfaceNode(self: *ServerState, entry: *SurfaceEntry) void {
    const s = entry.surface;
    const buf = s.buffer orelse {
        log.debug("surfnode: no buffer", self.io, self.log_cfg, "server", .{});
        removeSurfaceNode(self, entry);
        return;
    };
    const pixels = surfacePixels(self, buf) orelse {
        log.debug("surfnode: no pixels", self.io, self.log_cfg, "server", .{});
        return;
    };
    if (entry.node) |node| {
        // Same-size commit: update the texture in place (no alloc, no
        // texture churn — the per-frame hot path).
        const bn = node.kind.buffer;
        if (bn.texture) |tex| {
            const byte_len = @as(usize, @intCast(pixels.stride)) * @as(usize, @intCast(buf.height));
            if (wayland.pixman.PixmanRenderer.updateMemory(
                tex,
                buf.width,
                buf.height,
                pixels.stride,
                pixels.ptr[0..byte_len],
            )) {
                node.enable(true);
                return;
            }
            tex.destroy();
            bn.texture = null;
        }
    }
    const texture = importSurfacePixels(self, buf, pixels) orelse return;
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

        // First map: give the toplevel its real size. The initial
        // configure was 0x0 ("client decides"); after the client acked it
        // and mapped, a configure with the output size makes well-behaved
        // clients (foot, simple-shm) fill the output.
        if (s.role != null) {
            for (self.toplevels.items) |t| {
                if (t.xdg_surface.surface == s and
                    t.configured_size.w == 0 and t.configured_size.h == 0)
                {
                    // The output is announced (onNewOutput) before any
                    // surface can map, so its mode is the real size.
                    const out = self.output.?;
                    t.configure(out.mode.width, out.mode.height) catch |err| {
                        log.warn("toplevel reconfigure failed: {s}", self.io, self.log_cfg, "server", .{
                            @errorName(err),
                        });
                    };
                    break;
                }
            }
        }
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

/// The surface's shm pixels (with SIGBUS guard active) + stride.
const SurfacePixels = struct {
    ptr: [*]u8,
    stride: i32,
};

fn surfacePixels(_: *ServerState, buf: *wayland.buffers.Buffer) ?SurfacePixels {
    const get_shm = buf.impl.get_shm orelse return null;
    const shm = get_shm(buf) orelse return null;
    const begin = buf.impl.begin_data_ptr_access orelse return null;
    const end = buf.impl.end_data_ptr_access orelse return null;
    const pixels = begin(buf) catch return null;
    defer end(buf);
    const ptr = pixels orelse return null;
    return .{ .ptr = ptr, .stride = wire.shm.Buffer.getStride(shm) };
}

/// Copy the surface's current buffer into a renderer texture (same import
/// path the M1 render loop used per frame; the scene node owns the copy).
fn importSurfacePixels(self: *ServerState, buf: *wayland.buffers.Buffer, pixels: SurfacePixels) ?*Texture {
    const t0 = perfNs(self);
    const byte_len = @as(usize, @intCast(pixels.stride)) * @as(usize, @intCast(buf.height));
    const tex = pixman.PixmanRenderer.importMemory(
        self.renderer,
        buf.width,
        buf.height,
        pixels.stride,
        pixels.ptr[0..byte_len],
    ) catch |err| {
        log.err("texture import failed: {s} ({d}x{d} stride={d})", self.io, self.log_cfg, "server", .{
            @errorName(err), buf.width, buf.height, pixels.stride,
        });
        return null;
    };
    if (self.perf) {
        log.info("perf import={d}us buf={d}x{d}", self.io, self.log_cfg, "perf", .{
            (perfNs(self) - t0) / 1000, buf.width, buf.height,
        });
    }
    return tex;
}

/// Frame-level perf trace format (WAYLAND_PERF=1).
const perf_frame_fmt = "perf frame={d} sync={d}us cursor={d}us render={d}us present={d}us total={d}us";

/// Monotonic nanoseconds for the perf trace.
fn perfNs(self: *ServerState) u64 {
    return @intCast(@max(std.Io.Clock.now(.awake, self.io.*).toNanoseconds(), 0));
}

/// Tear down every surface entry (listeners, scene nodes, allocations).
/// Runs before the scene and compositor teardown in main().
fn cleanupSurfaceEntries(self: *ServerState) void {
    if (self.cursor_texture) |t| t.destroy();
    self.cursor_texture = null;
    if (self.cursor_fallback_texture) |t| t.destroy();
    self.cursor_fallback_texture = null;
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

/// WAYLAND_BACKEND=drm selects the DRM/KMS backend (native output).
fn wantDrmBackend(environ_map: *std.process.Environ.Map) bool {
    const v = environ_map.get("WAYLAND_BACKEND") orelse return false;
    return std.mem.eql(u8, v, "drm");
}

/// WAYLAND_BACKEND=raylib selects the windowed raylib debug backend.
fn wantRaylibBackend(environ_map: *std.process.Environ.Map) bool {
    const v = environ_map.get("WAYLAND_BACKEND") orelse return false;
    return std.mem.eql(u8, v, "raylib");
}

// ---------------------------------------------------------------------------
// M3: seat hit-test, screencopy sources, input bindings
// ---------------------------------------------------------------------------

/// Seat hit test: the topmost surface scene node under (x, y), mapped
/// back to its surface with surface-local coordinates.
fn pickSurface(ctx: *anyopaque, x: i32, y: i32) ?wayland.seat.Seat.PickResult {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const scene = self.scene orelse return null;
    // M4: the pointer arrives in SCREEN coords, but the scene nodes live
    // in world space — invert the camera first, then pick in world coords
    // (surface-local coords are world coords too). With the default
    // camera worldToScreen is the identity mapping, so this is a no-op.
    const world = self.camera.screenToWorld(@floatFromInt(x), @floatFromInt(y));
    const node = scene.pick(@intFromFloat(world.x), @intFromFloat(world.y)) orelse return null;
    var it = self.surface_entries.valueIterator();
    while (it.next()) |entry_ptr| {
        const entry = entry_ptr.*;
        if (entry.node == node) {
            const rect = node.absolutePosition();
            return .{
                .surface = entry.surface,
                .sx = @as(i32, @intFromFloat(world.x)) - rect.x,
                .sy = @as(i32, @intFromFloat(world.y)) - rect.y,
            };
        }
    }
    return null;
}

fn getFramebuffer(ctx: *anyopaque) ?*pixman.Framebuffer {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    return self.framebuffer;
}

fn ownsOutput(ctx: *anyopaque, resource: *wayland.server.wl.Output) bool {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const wl_output = self.wl_output orelse return false;
    return wl_output.owns(resource);
}

/// Capture timestamp: monotonic nanoseconds split into the protocol's
/// tv_sec_hi / tv_sec_lo / tv_nsec triple.
fn captureClock(ctx: *anyopaque, out: *[3]u32) void {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const ms: i64 = std.Io.Clock.now(.awake, self.io.*).toMilliseconds();
    const sec: u64 = @intCast(@max(ms, 0) / 1000);
    const ms_rem: u64 = @intCast(@max(@rem(ms, @as(i64, 1000)), 0));
    const nsec: u64 = ms_rem * std.time.ns_per_ms;
    out[0] = @truncate(sec >> 32);
    out[1] = @truncate(sec);
    out[2] = @truncate(nsec);
}

/// Seat key signal: Mod4+Escape quits the server (keysym binding).
fn onSeatKey(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_key_listener", listener);
    if (seat.last_keysym == wayland.xkb.keysym_escape and seat.mod4Active()) {
        log.info("Mod4+Escape pressed: stopping", self.io, self.log_cfg, "server", .{});
        if (self.loop) |loop| loop.stop();
    }
}

/// Sync the cursor nodes with the seat state: position at the pointer
/// minus the hotspot; client cursor surface texture when one is set and
/// has a buffer, else the fallback rect.
fn updateCursor(self: *ServerState) void {
    const seat = self.seat;
    const x = seat.pointer_x;
    const y = seat.pointer_y;

    // Keep the cursor on top of every surface: re-append both nodes to
    // the scene root (appendChild reparents, moving them to draw last).
    self.scene.?.root.appendChild(self.allocator, self.cursor_rect_node.?) catch |err| {
        log.warn("cursor z-order failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
    };
    self.scene.?.root.appendChild(self.allocator, self.cursor_buf_node.?) catch |err| {
        log.warn("cursor z-order failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
    };

    const cursor_surface_res = seat.cursorSurface();
    var surface_texture: ?*Texture = null;
    if (cursor_surface_res) |res| {
        // Resolve the wire resource to the compositor surface (the
        // cursor surface may belong to any client).
        for (self.compositor.surfaces.items) |s| {
            if (s.resource == res) {
                if (s.buffer) |buf| {
                    if (surfacePixels(self, buf)) |sp| {
                        surface_texture = importSurfacePixels(self, buf, sp) orelse null;
                    }
                }
                break;
            }
        }
    }
    if (self.cursor_texture) |old| {
        if (old != surface_texture) old.destroy();
        self.cursor_texture = null;
    }
    if (surface_texture) |tex| {
        self.cursor_texture = tex;
        const node = self.cursor_buf_node.?;
        node.kind.buffer.texture = tex;
        node.kind.buffer.dst_width = tex.width;
        node.kind.buffer.dst_height = tex.height;
        node.x = x - seat.cursor_hotspot_x;
        node.y = y - seat.cursor_hotspot_y;
        node.enable(true);
        self.cursor_rect_node.?.enable(false);
    } else {
        self.cursor_rect_node.?.x = x;
        self.cursor_rect_node.?.y = y;
        self.cursor_rect_node.?.enable(true);
        self.cursor_buf_node.?.enable(false);
    }
}

/// The cursor nodes' absolute rects (fallback rect + client cursor
/// buffer), or null for a disabled node. renderFrame captures the old
/// footprints before updateCursor moves the nodes so a partial upload
/// repaints both the old and the new position.
fn cursorFootprints(self: *ServerState) [2]?geom.Rect {
    var out: [2]?geom.Rect = .{ null, null };
    inline for (.{ self.cursor_rect_node, self.cursor_buf_node }, 0..) |node, i| {
        if (node) |n| {
            if (n.enabled) out[i] = n.absolutePosition();
        }
    }
    return out;
}

/// Saturating i32 add: surface damage rects are client-controlled and may
/// overflow when translated by the node position. Damage is a hint, so a
/// saturated value is a safe over-report (clipped to the output below).
fn addSat(a: i32, b: i32) i32 {
    return std.math.add(i32, a, b) catch blk: {
        break :blk if (b < 0) std.math.minInt(i32) else std.math.maxInt(i32);
    };
}

/// Position every subsurface node over its mapped parent: the child node
/// follows the parent's absolute position plus the subsurface offset, and
/// always draws above the parent (re-appended at the end of the tree).
fn syncSubsurfaceNodes(self: *ServerState) void {
    const scene = self.scene orelse return;
    for (self.subcompositor.subsurfaces.items) |ss| {
        const child_entry = self.surface_entries.get(ss.surface) orelse continue;
        const child_node = child_entry.node orelse continue;
        const parent_entry = self.surface_entries.get(ss.parent) orelse continue;
        if (parent_entry.node) |parent_node| {
            const pr = parent_node.absolutePosition();
            child_node.x = pr.x + ss.x;
            child_node.y = pr.y + ss.y;
            child_node.enable(true);
            // Draw the child above its parent (and everything else).
            scene.root.appendChild(self.allocator, child_node) catch |err| {
                log.warn("subsurface z-order failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            };
        } else {
            child_node.enable(false);
        }
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
