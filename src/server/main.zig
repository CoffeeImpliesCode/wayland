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
const raylib_impl = @import("wayland").raylib;
const raylib_mod = if (build_options.enable_raylib) raylib_impl else null;
/// DRM/KMS backend (src/backend/drm.zig): native output on /dev/dri/cardN
/// with dumb-buffer scanout (WAYLAND_BACKEND=drm).
const drm_mod = @import("wayland").drm;
/// libinput backend (src/backend/libinput.zig): evdev devices through
/// libinput (WAYLAND_LIBINPUT=1).
const libinput_mod = @import("wayland").libinput;
/// The raylib input source feeds the seat from the window's keyboard and
/// mouse; same -Denable_raylib guard.
const raylib_input_impl = @import("wayland").raylib_input;
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
/// `*Subsurface` as stored in Subcompositor.subsurfaces.
// SAFETY: type-derivation only; the undefined value is never evaluated at runtime.
const Subsurface = std.meta.Child(std.meta.Child(
    @TypeOf(@as(wayland.subsurface.Subcompositor, undefined).subsurfaces.items),
));
/// M4 camera + canvas pass (wayland.camera / wayland.canvas): the
/// camera-transformed compositing path replacing the scene-output render.
const Camera = wayland.camera.Camera;
const CanvasItem = wayland.canvas.CanvasItem;

const output_width: i32 = 1280;
const output_height: i32 = 720;
const output_refresh_msec: i32 = 16;
const watchdog_timeout_ms: u64 = 5000;
/// xdg_wm_base ping policy (F3): ping every live client every 5s; a ping
/// still unanswered 5s later (the next tick) posts the unresponsive error
/// (error code 6), which disconnects the client.
const xdg_ping_interval_ms: u64 = 5000;
/// Background color (straight alpha RGBA).
const background_color = [4]f32{ 0.1, 0.1, 0.12, 1.0 };
/// The pointer-move threshold (px, squared) before a left-button press
/// becomes a camera drag. A click with sub-threshold micro-movement keeps
/// the seat's click-to-focus (the terminal gets the keyboard) instead of
/// panning the camera.
const drag_threshold_sq: i32 = 16; // 4 px

const ServerState = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *wayland.core.display.CompositorDisplay,
    compositor: *wayland.compositor.Compositor,
    shm_state: *wayland.shm.ShmState,
    shell: *wayland.shell.XdgShell,
    /// zwlr_layer_shell_v1 (layer surfaces with their own stacking layer).
    layer_shell: *wayland.layer_shell.LayerShell,
    /// xdg_activation_v1 (activation tokens for focus requests).
    xdg_activation: *wayland.xdg_activation.XdgActivation,
    /// zxdg_decoration_manager_v1 (server-side decorations).
    xdg_decoration: *wayland.xdg_decoration.XdgDecoration,
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
    /// zwp_primary_selection_device_manager_v1: the primary selection
    /// (X11 PRIMARY analogue, keyboard-focus-owned). Self-subscribes to
    /// the seat's keyboard-focus signal.
    primary_selection: *wayland.primary_selection.PrimarySelection,
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
    /// The seat's pointer cursor (compositor/cursor.zig): owns the
    /// cursor scene nodes, the client cursor surface (wl_pointer.
    /// set_cursor) texture and the fallback texture; the compositor
    /// keeps the repaint policy. Created in onNewOutput, freed in
    /// cleanupSurfaceEntries.
    cursor: ?*wayland.cursor.Cursor = null,
    presentation: *wayland.presentation.Presentation,
    /// The zio loop, set once initialized (callbacks stop it).
    loop: ?*zio.ev.Loop = null,
    /// One-shot watchdog timer, re-armed on every render.
    watchdog: ?*zio.ev.Timer = null,
    /// Repeating xdg_wm_base ping timer (F3): pings every live client;
    /// an unanswered ping on the next tick posts the unresponsive error.
    ping_timer: ?*zio.ev.Timer = null,
    /// Server-side key repeat timer (seat.onRepeatTick): armed on a key
    /// press, self-stops when the key is released. The seat owns the
    /// repeat state (delay/interval); this is just the clock.
    repeat_timer: ?*zio.ev.Timer = null,
    repeat_timer_armed: bool = false,
    /// raylib window input poll timer: polls the window + feeds the seat
    /// from the loop (NOT the commit) at ~60 Hz; only armed for the raylib
    /// backend. A fed event requests a render (the frame flush follows).
    raylib_poll_timer: ?*zio.ev.Timer = null,
    /// Whether the watchdog is active (WAYLAND_WATCHDOG_DISABLE unset).
    /// Guards BOTH the initial loop.add and the renderFrame re-arm: zio's
    /// setTimer arms an un-armed timer, so a re-arm on a disabled watchdog
    /// would re-add it and it would still fire on an idle demo.
    watchdog_enabled: bool = true,
    output: ?*wayland.output.Output = null,
    /// Toplevels created by clients (tracked for observability).
    toplevels: std.ArrayList(*wayland.shell.XdgToplevel) = .empty,
    /// Layer surfaces created by clients (tracked for observability).
    layer_surfaces: std.ArrayList(*wayland.layer_shell.LayerSurface) = .empty,
    frames_rendered: u32 = 0,
    /// Idle-frame skip: a frame only renders when something changed this
    /// cycle (a surface commit, a camera move, a cursor move). Cleared
    /// after a successful render+flip; when set, requestRender() wakes
    /// the renderer via output.sendFrame(). Without this the DRM flip
    /// chain renders + flips a full composite every vsync (~60fps) even
    /// with nothing on screen — the observed ~95% idle CPU.
    repaint_pending: bool = true,
    /// True while renderFrame is on the stack. requestRender() must not
    /// synchronously emit output.sendFrame() while a render is already in
    /// progress: a render can re-trigger requestRender (the synth input's
    /// seat.pointerMotion, camera/seat events) and an emit from inside
    /// the frame event handler re-enters renderFrame, recursing until the
    /// frame-event emit GP-faults. When set, requestRender only marks
    /// repaint_pending — the in-flight render has already read the
    /// changed state (the synth runs before the composite) and consumes
    /// it at the end.
    in_render: bool = false,
    /// The canvas WITHOUT the cursor (background + camera-transformed
    /// surfaces), persisted so a hover cursor move restores a region from
    /// it instead of recompositing the whole canvas (~450ms full-canvas
    /// bilinear in the VM). Recomposited only when the canvas changes; the
    /// display framebuffer = base + cursor overlay.
    base_framebuffer: ?*pixman.Framebuffer = null,
    /// Hover cursor move in progress: renderFrame skips the full composite
    /// and instead restores the old cursor region from base_framebuffer +
    /// redraws the cursor at the new pointer (set by onSeatPointerMove).
    cursor_repaint: bool = false,
    /// A client has a pending wl_surface.frame callback (it is ready for
    /// the next frame) but the canvas is otherwise unchanged. The
    /// idle-frame skip would starve it: the client waits for the
    /// wl_callback.done to render its next update (foot's render loop),
    /// which only fires on a present. renderFrame presents the unchanged
    /// framebuffer (no recomposite) so the callback fires and the client
    /// can commit its pending content.
    frame_kick: bool = false,
    /// Stop after this many frames; 0 = run until watchdog/error.
    run_frames: u32 = 0,
    watchdog_fired: bool = false,
    /// WAYLAND_SYNTH_INPUT=1: synthesize one pointer click + key press
    /// once the first surface is mapped (headless input E2E).
    synth_input: bool = false,
    synth_fired: bool = false,
    /// M4 Phase B: the synth wheel-zoom step (one wheel-up notch once
    /// the client's FIRST screencopy capture has been served, plus a
    /// 2-frame grace) has been sent. Separate from synth_fired: the
    /// input step is event-driven (map time varies), the zoom step is
    /// capture-count-driven so it lands after the client's zoom-2
    /// checks.
    synth_scrolled: bool = false,
    /// M4 Phase B: rendered frames since the first screencopy capture
    /// was served. The synth wheel fires once this reaches 2, so the
    /// zoom lands after the phase-1 capture buffer is fully delivered
    /// (ready message flushed) without depending on frame timing.
    synth_scroll_grace: u32 = 0,
    /// M4 Phase B camera drag: the last pointer position while the left
    /// button is held (the pan anchor); null when not dragging. A click
    /// without motion never produces a delta, so the seat's
    /// click-to-focus is unchanged.
    camera_drag: ?DragPoint = null,
    /// The camera state at the last render: a change (pan/zoom) forces
    /// whole-output damage so the partial upload never smears the
    /// previous canvas (the drag-streak bug).
    last_camera: Camera = .{
        .center_x = @as(f64, @floatFromInt(output_width)) / 2.0,
        .center_y = @as(f64, @floatFromInt(output_height)) / 2.0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = @floatFromInt(output_width),
        .screen_h = @floatFromInt(output_height),
    },
    /// Whether the drag has crossed the movement threshold (a real pan has
    /// started). A press alone only arms camera_drag; the pan (and the
    /// fast-render blockiness) begins once the pointer moves > drag_threshold
    /// px — so a click with a tiny micro-move doesn't pan the camera or
    /// steal focus from the terminal (the reported 'click hangs the cursor').
    drag_active: bool = false,
    /// Progressive-quality fast render: set while a camera drag/pan is
    /// active so compositeBase renders the canvas at a reduced stride
    /// (blocky but ~stride² cheaper per frame — keeps panning responsive
    /// on a slow CPU). Cleared when the drag ends; the next full-quality
    /// render replaces the blocky frame.
    fast_render: bool = false,
    /// WAYLAND_PERF=1: log per-frame pipeline timings (import -> render
    /// -> present) in microseconds.
    perf: bool = false,

    new_output_listener: wire.Listener(*wayland.output.Output),
    frame_listener: wire.Listener(*wayland.output.Output),
    /// A surface committed new content (scene.events.content_dirty):
    /// schedule a render so the update actually composites (note 137 F1).
    content_dirty_listener: wire.Listener(*wayland.scene.Scene),
    new_toplevel_listener: wire.Listener(*wayland.shell.XdgToplevel),
    new_popup_listener: wire.Listener(*wayland.shell.XdgPopup),
    new_activation_token_listener: wire.Listener(*wayland.xdg_activation.ActivationToken),
    new_layer_surface_listener: wire.Listener(*wayland.layer_shell.LayerSurface),
    request_activate_listener: wire.Listener(*wayland.xdg_activation.ActivateRequest),
    request_mode_listener: wire.Listener(*wayland.xdg_decoration.RequestMode),
    seat_key_listener: wire.Listener(*wayland.seat.Seat),
    /// M4 Phase B camera controls: seat listeners for the drag-pan
    /// (button + pointer_move signals) and the wheel-zoom (axis signal).
    seat_button_listener: wire.Listener(*wayland.seat.Seat),
    seat_pointer_move_listener: wire.Listener(*wayland.seat.Seat),
    seat_axis_listener: wire.Listener(*wayland.seat.Seat),
};

/// M4 Phase B: the drag-pan gesture anchor — the pointer position while
/// the left button is held.
const DragPoint = struct { x: i32, y: i32 };

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

    // The socket name must be a single flushed stdout line, first thing
    // harnesses read — BEFORE the backend init (the raylib window open can
    // take seconds or fail on a headless/broken display). Logging goes to
    // stderr, so stdout stays parseable.
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
    // zwlr_layer_shell_v1: layer surfaces (panels, wallpapers, lock screens).
    const layer_shell = try wayland.layer_shell.LayerShell.init(allocator, io, &log_cfg, display, compositor);
    defer layer_shell.deinit();
    // M3: the seat (keyboard + pointer) with the xkbcommon us keymap.
    const seat = try wayland.seat.Seat.init(allocator, io, &log_cfg, display, .{});
    defer seat.deinit();
    // F10: runtime layout selection (WAYLAND_KEYBOARD_LAYOUT, default
    // "us" compiled by Seat.init) — recompiles the keymap and
    // re-broadcasts it before any client binds.
    if (init.environ_map.get("WAYLAND_KEYBOARD_LAYOUT")) |layout| {
        seat.setKeyboardLayout(layout);
    }
    // xdg_activation_v1 (staging): activation tokens for focus requests
    // (needs the seat for serial/focus validation).
    const xdg_activation = try wayland.xdg_activation.XdgActivation.init(
        allocator,
        io,
        &log_cfg,
        display,
        seat,
        compositor,
    );
    defer xdg_activation.deinit();
    // zxdg_decoration_manager_v1 (unstable): server-side decorations.
    const xdg_decoration = try wayland.xdg_decoration.XdgDecoration.init(allocator, io, &log_cfg, display, shell);
    defer xdg_decoration.deinit();
    // Subcompositor (foot needs wl_subcompositor).
    const subcompositor = try wayland.subsurface.Subcompositor.init(allocator, io, &log_cfg, display, compositor);
    defer subcompositor.deinit();
    // Data device manager (foot requires it; clipboard selection relay).
    const data_device = try wayland.data_device.DataDeviceManager.init(allocator, io, &log_cfg, display, seat);
    defer data_device.deinit();
    // Primary selection (zwp_primary_selection_device_manager_v1, the
    // X11 PRIMARY analogue): per-seat, keyboard-focus-owned.
    const primary_selection = try wayland.primary_selection.PrimarySelection.init(
        allocator,
        io,
        &log_cfg,
        display,
        seat,
    );
    defer primary_selection.deinit();
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
    // NOTE: no defer framebuffer.deinit() here — the ServerState owns the
    // framebuffer (state.framebuffer), and onNewOutput resizes it by
    // freeing the old + assigning a new one. A defer on this local would
    // point at the (possibly freed) original and double-free at shutdown
    // (DebugAllocator segfault); main frees state.framebuffer instead.

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
        .layer_shell = layer_shell,
        .seat = seat,
        .subcompositor = subcompositor,
        .data_device = data_device,
        .primary_selection = primary_selection,
        .renderer = renderer,
        .xdg_activation = xdg_activation,
        .xdg_decoration = xdg_decoration,
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
        .toplevels = .empty,
        .layer_surfaces = .empty,
        .new_output_listener = wire.Listener(*wayland.output.Output).init(onNewOutput),
        .new_input_listener = wire.Listener(*wayland.backend.Backend.InputDevice).init(onNewInput),
        .frame_listener = wire.Listener(*wayland.output.Output).init(onOutputFrame),
        .content_dirty_listener = wire.Listener(*wayland.scene.Scene).init(onSceneContentDirty),
        .new_toplevel_listener = wire.Listener(*wayland.shell.XdgToplevel).init(onNewToplevel),
        .new_popup_listener = wire.Listener(*wayland.shell.XdgPopup).init(onNewPopup),
        .new_layer_surface_listener = wire.Listener(*wayland.layer_shell.LayerSurface).init(onNewLayerSurface),
        .request_activate_listener = wire.Listener(*wayland.xdg_activation.ActivateRequest).init(onRequestActivate),
        .request_mode_listener = wire.Listener(*wayland.xdg_decoration.RequestMode).init(onDecorationMode),
        .new_activation_token_listener = wire.Listener(*wayland.xdg_activation.ActivationToken)
            .init(onNewActivationToken),
        .seat_key_listener = wire.Listener(*wayland.seat.Seat).init(onSeatKey),
        .seat_button_listener = wire.Listener(*wayland.seat.Seat).init(onSeatButton),
        .seat_pointer_move_listener = wire.Listener(*wayland.seat.Seat).init(onSeatPointerMove),
        .seat_axis_listener = wire.Listener(*wayland.seat.Seat).init(onSeatAxis),
    };
    if (backend_is_drm) state.drm_backend = backend;
    defer state.toplevels.deinit(allocator);
    defer state.layer_surfaces.deinit(allocator);
    // Scene teardown (LIFO): drop the per-surface scene state first, then
    // the scene output view, then the scene tree itself. The compositor
    // (deferred earlier in main) destroys its surfaces afterwards; the
    // listeners were already removed, so no entry is freed twice.
    defer if (state.scene) |scene| scene.deinit();
    defer if (state.scene_output) |so| so.destroy();
    defer cleanupSurfaceEntries(&state);
    // Destroy the clients FIRST in the teardown (LIFO: registered last,
    // runs first — before the scene/shm/module deinits below). Their
    // surface/buffer destroy signals must fire against LIVE modules: the
    // shm map remove (shm.zig:223), the surface-node registry and the
    // seat cleanup all touch module state. display.deinit ALSO calls
    // destroyClients as idempotent safety (no clients left here), which
    // alone would run AFTER the shm deinit — the shutdown UAF a live
    // client (e.g. foot at window close) hit.
    defer display.destroyClients();

    backend.events.new_output.add(&state.new_output_listener);
    if (input_backend) |ib| {
        state.input_backend = ib;
        ib.events.new_input.add(&state.new_input_listener);
    }
    shell.events.new_toplevel.add(&state.new_toplevel_listener);
    shell.events.new_popup.add(&state.new_popup_listener);
    layer_shell.events.new_layer_surface.add(&state.new_layer_surface_listener);
    seat.events.key.add(&state.seat_key_listener);
    // M4 Phase B camera controls: wheel zoom + drag pan hook the seat's
    // existing event surface (button, pointer_move, axis). The raylib
    // and libinput backends feed these signals through the seat API
    // (pointerButton/pointerMotion/pointerAxis), so no backend change is
    // needed; headless E2E synthesizes the same calls.
    seat.events.button.add(&state.seat_button_listener);
    seat.events.pointer_move.add(&state.seat_pointer_move_listener);
    seat.events.axis.add(&state.seat_axis_listener);
    // xdg_activation_v1: activation requests with known tokens (focus
    // policy is out of scope — the handler logs and accepts) and the
    // token-creation hook (XA-1; the compositor can observe allowlists /
    // telemetry).
    xdg_activation.events.request_activate.add(&state.request_activate_listener);
    xdg_activation.events.new_token.add(&state.new_activation_token_listener);
    // zxdg_decoration_manager_v1: mode requests; the handler replies with
    // the effective mode via sendConfigure.
    xdg_decoration.events.request_mode.add(&state.request_mode_listener);
    // The compositor hit-tests over the scene graph: surfaces map to
    // scene nodes through the surface entries.
    seat.setPick(pickSurface, &state);

    // zwlr_screencopy_v1: captures the compositor framebuffer (shm only).
    // The copy is deferred to the next output commit; requestFrame wakes
    // the renderer so a pending copy gets its commit.
    state.screencopy = try wayland.screencopy.Screencopy.init(
        allocator,
        io,
        &log_cfg,
        display,
        shm_state,
        getFramebuffer,
        &state,
        outputFromResource,
        &state,
        requestFrame,
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
    // The idle-frame skip means a healthy server renders nothing between
    // changes, so the watchdog (re-armed only per render) would stop an
    // idle interactive demo after the window. WAYLAND_WATCHDOG_DISABLE
    // opts out (set by the interactive VM demo; the E2E keeps it).
    const watchdog_disabled = init.environ_map.get("WAYLAND_WATCHDOG_DISABLE") != null;
    state.watchdog_enabled = !watchdog_disabled;
    if (!watchdog_disabled) loop.add(&watchdog.c);

    // xdg_wm_base ping policy (F3): a repeating timer re-arms itself in
    // onPingTick; each tick pings every live client and declares clients
    // unresponsive (error 6) when the previous ping went unanswered.
    var ping_timer = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(xdg_ping_interval_ms) });
    ping_timer.c.userdata = &state;
    ping_timer.c.callback = onPingTick;
    state.ping_timer = &ping_timer;
    loop.add(&ping_timer.c);

    // Server-side key repeat (seat key_repeat_delay/rate): one-shot
    // timer; the initial add arms a harmless no-op tick (nothing repeats),
    // onSeatKey re-arms it on a key press and disarms on release.
    var repeat_timer = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(600) });
    repeat_timer.c.userdata = &state;
    repeat_timer.c.callback = onRepeatTick;
    state.repeat_timer = &repeat_timer;
    loop.add(&repeat_timer.c);

    // raylib window input: poll + feed the seat from the loop at ~60 Hz.
    // The commit must NOT poll (mid-render feeding lands after the frame's
    // flush + the in_render guard suppresses the follow-up frame, leaving
    // the events queued forever). The timer requests a render when the
    // poll fed something, so events flush on the next pointerFrame().
    if (backend_is_raylib and build_options.enable_raylib) {
        var raylib_poll_timer = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(16) });
        raylib_poll_timer.c.userdata = &state;
        raylib_poll_timer.c.callback = onRaylibPollTick;
        state.raylib_poll_timer = &raylib_poll_timer;
        loop.add(&raylib_poll_timer.c);
    }

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
    // The ServerState owns the render framebuffer (onNewOutput may have
    // replaced the original via resize); free the CURRENT one here — the
    // backend must already be torn down so nothing references it. The base
    // (canvas-without-cursor) too.
    if (state.base_framebuffer) |base| base.deinit();
    state.base_framebuffer = null;
    state.framebuffer.deinit();
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
        // The base (canvas-without-cursor) is lazily recreated at the new
        // size on the next composite; a stale-sized base would copy wrong.
        if (self.base_framebuffer) |base| base.deinit();
        self.base_framebuffer = null;
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
    // The scene's surface bindings need the compositor's subcompositor
    // (subsurface tree parenting) and wl_output (the surface enter/leave
    // wire events). Set before any surface is tracked (surfaces only
    // appear after backend.start()).
    scene.subcompositor = self.subcompositor;
    scene.events.content_dirty.add(&self.content_dirty_listener);
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
    // The surface enter/leave wire events ride the wl_output resources.
    scene.wl_output = self.wl_output;
    // The seat's pointer cursor: its scene nodes are drawn above the
    // surfaces, never picked.
    self.cursor = wayland.cursor.Cursor.create(
        self.allocator,
        self.io,
        self.log_cfg,
        scene,
        self.compositor,
        self.seat,
        self.renderer,
    ) catch |err| {
        log.err("cursor init failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };

    // Enable the output up front: sendFrame gates the frame signal on
    // enabled (wlroots output.c:833-837), so the first requestRender
    // would otherwise never emit and the first frame would never render.
    // This enable-only commit sets no frame_pending (no frame event is
    // owed); the first buffer commit starts the frame chain.
    var init_state = wayland.output.Output.State.init(self.allocator);
    defer init_state.deinit();
    init_state.committed = wayland.output.Output.State.committed_enabled |
        wayland.output.Output.State.committed_mode;
    init_state.enabled = true;
    init_state.mode = .{ .width = out.mode.width, .height = out.mode.height, .refresh_msec = out.mode.refresh_msec };
    out.commitState(&init_state) catch |err| {
        log.err("output enable commit failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
}

/// Per-toplevel listeners owned by main.zig (F10/F14): title/app_id change
/// events, the minimize request, and the destroy event that frees this
/// struct. Freed from the destroy handler (the module emits it before the
/// role object is freed). `state` back-references the ServerState for the
/// log config.
const ToplevelListeners = struct {
    state: *ServerState,
    set_title: wire.Listener(*wayland.shell.XdgToplevel),
    set_app_id: wire.Listener(*wayland.shell.XdgToplevel),
    request_minimize: wire.Listener(*wayland.shell.XdgToplevel),
    request_fullscreen: wire.Listener(*wayland.shell.FullscreenRequest),
    destroy: wire.Listener(*wayland.shell.XdgToplevel),
};

fn onToplevelTitle(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("set_title", listener);
    log.info("toplevel title changed: {s}", tl.state.io, tl.state.log_cfg, "server", .{t.title orelse "(none)"});
}

fn onToplevelAppId(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("set_app_id", listener);
    log.info("toplevel app_id changed: {s}", tl.state.io, tl.state.log_cfg, "server", .{t.app_id orelse "(none)"});
}

fn onToplevelMinimize(listener: *wire.Listener(*wayland.shell.XdgToplevel), _: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_minimize", listener);
    log.info("toplevel minimize requested", tl.state.io, tl.state.log_cfg, "server", .{});
}

fn onToplevelFullscreen(
    listener: *wire.Listener(*wayland.shell.FullscreenRequest),
    req: *wayland.shell.FullscreenRequest,
) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_fullscreen", listener);
    // F10: the client-named fullscreen output reaches the compositor.
    log.info(
        "toplevel fullscreen requested: {s}",
        tl.state.io,
        tl.state.log_cfg,
        "server",
        .{if (req.fullscreen) "on" else "off"},
    );
    _ = req.output;
}

fn onToplevelDestroy(listener: *wire.Listener(*wayland.shell.XdgToplevel), _: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("destroy", listener);
    tl.state.allocator.destroy(tl);
}

fn onNewToplevel(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const self: *ServerState = @fieldParentPtr("new_toplevel_listener", listener);
    self.toplevels.append(self.allocator, t) catch |err| {
        log.warn("failed to track toplevel: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
    };
    // F10/F14: wire the per-toplevel change events; the listeners live in a
    // heap struct freed by onToplevelDestroy.
    const tl = self.allocator.create(ToplevelListeners) catch |err| {
        log.warn("failed to allocate toplevel listeners: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    tl.* = .{
        .state = self,
        .set_title = wire.Listener(*wayland.shell.XdgToplevel).init(onToplevelTitle),
        .set_app_id = wire.Listener(*wayland.shell.XdgToplevel).init(onToplevelAppId),
        .request_minimize = wire.Listener(*wayland.shell.XdgToplevel).init(onToplevelMinimize),
        .request_fullscreen = wire.Listener(*wayland.shell.FullscreenRequest).init(onToplevelFullscreen),
        .destroy = wire.Listener(*wayland.shell.XdgToplevel).init(onToplevelDestroy),
    };
    t.events.set_title.add(&tl.set_title);
    t.events.set_app_id.add(&tl.set_app_id);
    t.events.request_minimize.add(&tl.request_minimize);
    t.events.request_fullscreen.add(&tl.request_fullscreen);
    t.events.destroy.add(&tl.destroy);
    log.info("new toplevel (title={s} app_id={s}) total={d}", self.io, self.log_cfg, "server", .{
        t.title orelse "(none)",
        t.app_id orelse "(none)",
        self.toplevels.items.len,
    });
}

/// A new zwlr_layer_surface_v1 role object was created. Like toplevels,
/// layer surfaces composite through the shared surface→scene path
/// (syncSurfaces tracks every compositor surface through the library's
/// SurfaceNode bindings), so no scene wiring is needed here. The initial
/// configure is sent by the module in reply to the client's first
/// buffer-less commit (per the
/// protocol: "the client must perform an initial commit without any buffer
/// attached. The compositor will reply with a layer_surface.configure
/// event"); the module carries the output size as the assigned size for the
/// dimensions the client left at 0 (L2). Layer z-ordering and layout are
/// compositor policy and are not implemented yet (see
/// notes/129-layer-shell-impl.md).
fn onNewLayerSurface(
    listener: *wire.Listener(*wayland.layer_shell.LayerSurface),
    ls: *wayland.layer_shell.LayerSurface,
) void {
    const self: *ServerState = @fieldParentPtr("new_layer_surface_listener", listener);
    self.layer_surfaces.append(self.allocator, ls) catch |err| {
        log.warn("failed to track layer surface: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
    };
    // L2: the compositor assigns the real size for the zero desired
    // dimensions — the (single) output's mode size is the fallback the
    // module uses in the initial configure.
    if (self.output) |out| {
        ls.setFallbackSize(@intCast(out.mode.width), @intCast(out.mode.height));
    }
    log.info("new layer surface (namespace={s} layer={d}) total={d}", self.io, self.log_cfg, "server", .{
        ls.namespace orelse "(none)",
        @intFromEnum(ls.current.layer),
        self.layer_surfaces.items.len,
    });
}

fn onNewPopup(listener: *wire.Listener(*wayland.shell.XdgPopup), p: *wayland.shell.XdgPopup) void {
    const self: *ServerState = @fieldParentPtr("new_popup_listener", listener);
    // F1: the compositor supplies the usable area for popup placement —
    // the (single) output's mode rect in parent-surface-local coords. The
    // popup configure then applies the client's constraint_adjustment bits
    // (flip/slide/resize) to stay inside it.
    if (self.output) |out| {
        p.setConstraintBox(.{
            .x = 0,
            .y = 0,
            .width = out.mode.width,
            .height = out.mode.height,
        });
    }
    log.info("new popup at {d},{d} {d}x{d}", self.io, self.log_cfg, "server", .{
        p.geometry.x, p.geometry.y, p.geometry.width, p.geometry.height,
    });
}

fn onRequestActivate(
    listener: *wire.Listener(*wayland.xdg_activation.ActivateRequest),
    req: *wayland.xdg_activation.ActivateRequest,
) void {
    const self: *ServerState = @fieldParentPtr("request_activate_listener", listener);
    // Focus policy is out of scope for this phase: accept the activation
    // request by logging it (the token was already validated by the
    // activation module; the toplevel is not actually focused). See
    // notes/129-shell-protocols-impl.md.
    log.info("xdg_activation: request_activate surface={*} token={s}", self.io, self.log_cfg, "server", .{
        req.surface, req.token,
    });
}

/// xdg_activation_v1 events.new_token (XA-1): a client token was created
/// and committed successfully. Informational — the compositor can enforce
/// app_id allowlists or collect telemetry here (the token is already in
/// the registry and will be consumed by a matching activate()).
fn onNewActivationToken(
    listener: *wire.Listener(*wayland.xdg_activation.ActivationToken),
    token: *wayland.xdg_activation.ActivationToken,
) void {
    const self: *ServerState = @fieldParentPtr("new_activation_token_listener", listener);
    log.info("xdg_activation: new token committed app_id={s}", self.io, self.log_cfg, "server", .{
        token.app_id orelse "(none)",
    });
}

fn onDecorationMode(
    listener: *wire.Listener(*wayland.xdg_decoration.RequestMode),
    req: *wayland.xdg_decoration.RequestMode,
) void {
    const self: *ServerState = @fieldParentPtr("request_mode_listener", listener);
    // Placeholder policy (the compositor has no real decorations):
    // server-side for the focused toplevel, client-side otherwise. See
    // notes/129-shell-protocols-impl.md.
    // XD-1: sendConfigure schedules a toplevel configure; the
    // zxdg_toplevel_decoration_v1.configure event rides that
    // xdg_surface.configure/ack_configure cycle (the client applies the
    // mode when it acks).
    const mode: wayland.server.zxdg.ToplevelDecorationV1.Mode = blk: {
        const toplevel = req.decoration.toplevel orelse break :blk .client_side;
        break :blk if (self.seat.keyboard_focus == toplevel.xdg_surface.surface)
            .server_side
        else
            .client_side;
    };
    log.info("xdg_decoration: request_mode {s} -> {s}", self.io, self.log_cfg, "server", .{
        modeLabel(req.mode), modeLabel(mode),
    });
    req.decoration.sendConfigure(mode);
}

/// Short label for a decoration mode (or unset) for logging.
fn modeLabel(mode: ?wayland.server.zxdg.ToplevelDecorationV1.Mode) []const u8 {
    const m = mode orelse return "unset";
    return switch (m) {
        .client_side => "client_side",
        .server_side => "server_side",
        else => "invalid",
    };
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
        // The dispatch marshalled seat events (key/pointer/axis) into the
        // clients' outbound buffers. Without a flush here they sit until
        // the next display-poll wake — which only fires when a client is
        // ACTIVE (sending requests). An idle client therefore never
        // receives a key press (observed: weston-terminal/foot got no
        // keystroke while idle). Flush immediately so the event reaches
        // the client regardless of its own activity.
        self.display.flushClients();
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
    // Track any surfaces created this dispatch. syncSurfaces also runs at
    // the top of renderFrame, but with the idle-frame skip renderFrame
    // does not run between changes — without this, a surface created
    // after the first frame never gets its commit listener subscribed, so
    // its commits cannot wake the idle renderer (the compositor only saw
    // the surface once, at the pre-change render).
    syncSurfaces(self);
    // A surface with a pending wl_surface.frame is ready for the next
    // frame. The idle-frame skip would starve it (foot's render loop waits
    // for the wl_callback.done before drawing + committing its next
    // update), so present the unchanged canvas to fire the callback. Only
    // when the renderer is otherwise idle — a real change already queues
    // a render that presents everything.
    if (!self.repaint_pending and !self.in_render) {
        if (self.scene) |scene| {
            var it = scene.surface_nodes.valueIterator();
            while (it.next()) |sn| {
                if (sn.*.surface.current.frame_callbacks.items.len > 0) {
                    self.frame_kick = true;
                    requestRender(self);
                    break;
                }
            }
        }
    }
    // Synth input (headless/DRM E2E) fires on every dispatch, not in
    // renderFrame: the idle-frame skip means renders only happen on
    // changes, and the M4 scroll is gated on the client's screencopy
    // captures (which do not themselves trigger a render). Running here
    // (per loop dispatch, independent of rendering) keeps both the M3
    // click/key and the M4 wheel-scroll timing correct under the skip.
    maybeSynthInput(self);
    self.display.flushClients();
}

fn onWatchdog(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    log.err("watchdog: no rendered frame for {d}ms; stopping", self.io, self.log_cfg, "server", .{watchdog_timeout_ms});
    self.watchdog_fired = true;
    loop.stop();
}

/// Repeating xdg_wm_base ping tick (F3): for each distinct client (wm_base
/// binding), ping it when idle; declare it unresponsive (unresponsive
/// error, code 6 — disconnects the client) when the previous ping went
/// unanswered. Re-arms itself for the next tick.
fn onPingTick(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    defer loop.setTimer(self.ping_timer.?, .{ .duration = zio.Duration.fromMilliseconds(xdg_ping_interval_ms) });
    // Posting the error destroys the client and mutates the toplevel list,
    // so iterate a snapshot.
    var snapshot = std.ArrayList(*wayland.shell.XdgToplevel).empty;
    defer snapshot.deinit(self.allocator);
    snapshot.appendSlice(self.allocator, self.shell.toplevels.items) catch return;
    for (snapshot.items, 0..) |t, i| {
        // One ping per wm_base binding: skip toplevels sharing a client
        // already handled earlier in this tick.
        const res = t.wmBaseResource();
        var seen = false;
        for (snapshot.items[0..i]) |prev| {
            if (prev.wmBaseResource() == res) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (t.pingPending()) {
            log.warn("xdg client unresponsive: posting unresponsive error", self.io, self.log_cfg, "server", .{});
            res.postError(.unresponsive, "client did not respond to xdg_wm_base.ping");
        } else {
            t.ping();
        }
    }
}

/// raylib window input poll tick (~60 Hz): poll the window + feed the
/// seat, then request a render so the events flush on the next
/// pointerFrame(). Re-arms itself. Polling happens HERE, never in the
/// commit — mid-render feeding lands after the frame's flush and the
/// in_render guard suppresses the follow-up frame, so events would sit
/// queued forever.
fn onRaylibPollTick(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    defer loop.setTimer(self.raylib_poll_timer.?, .{ .duration = zio.Duration.fromMilliseconds(16) });
    if (build_options.enable_raylib) {
        // The window's close button (X) shuts the server down.
        if (raylib_mod.RaylibBackend.shouldClose(self.backend)) {
            log.info("raylib window close requested; stopping", self.io, self.log_cfg, "server", .{});
            loop.stop();
            return;
        }
        if (raylib_mod.RaylibBackend.pollWindowInput(self.backend)) {
            requestRender(self);
        }
    }
}

/// M3 + M4 synth input for the headless/DRM E2Es. Runs per dispatch (not
/// per render — see onDisplayReady).
/// - M3: one pointer click + key press once the first surface is mapped.
/// - M4 Phase B: one wheel-up notch once the client's FIRST screencopy
///   capture has been served (captures_served >= 1) plus a 2-call grace.
/// The notch goes through the seat (pointerAxis), so the axis signal
/// zooms the camera (2 -> 2.5 under the E2E).
fn maybeSynthInput(self: *ServerState) void {
    if (!self.synth_input) return;
    if (!self.synth_fired) {
        var any_mapped = false;
        if (self.scene) |scene| {
            var entry_it = scene.surface_nodes.valueIterator();
            while (entry_it.next()) |sn| {
                if (sn.*.node != null) {
                    any_mapped = true;
                    break;
                }
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
    if (!self.synth_scrolled) {
        if (self.screencopy) |sc| {
            if (sc.captures_served >= 1) {
                self.synth_scroll_grace += 1;
                if (self.synth_scroll_grace >= 2) {
                    self.synth_scrolled = true;
                    self.seat.pointerAxis(.vertical_scroll, .wheel, 10.0, 1);
                    log.info("synth input: wheel up notch (camera zoom x1.25)", self.io, self.log_cfg, "server", .{});
                }
            }
        }
    }
}

/// A surface committed new content: schedule a render so the update is
/// composited this frame (the commit→present wake, note 137 F1).
fn onSceneContentDirty(listener: *wire.Listener(*wayland.scene.Scene), _: *wayland.scene.Scene) void {
    const self: *ServerState = @fieldParentPtr("content_dirty_listener", listener);
    requestRender(self);
}

fn onOutputFrame(listener: *wire.Listener(*wayland.output.Output), out: *wayland.output.Output) void {
    const self: *ServerState = @fieldParentPtr("frame_listener", listener);
    renderFrame(self, out);
}

/// Mark that the next frame must render (something changed) and wake the
/// renderer via output.sendFrame(). The DRM frame chain is driven by the
/// flip event (sendFrame -> renderFrame -> commit -> flip -> event), so a
/// change while idle needs this kick to start a frame; subsequent frames
/// then pace off the flips until the change is consumed. While a frame is
/// in flight (frame_pending, set by the last commit) the kick is skipped:
/// the backend's next frame event renders it — starting a second frame
/// now would duplicate the frame signal (note 135 F2).
fn requestRender(self: *ServerState) void {
    self.repaint_pending = true;
    if (!self.in_render) {
        if (self.output) |out| {
            if (!out.frame_pending) out.sendFrame();
        }
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn renderFrame(self: *ServerState, out: *wayland.output.Output) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    // See the in_render field: guard against re-entrant emits from
    // requestRender while this render is on the stack.
    self.in_render = true;
    defer self.in_render = false;
    // Close the seat's input batch: everything the backends fed since
    // the last frame forms one wl_pointer.frame group (F7, note 132).
    self.seat.pointerFrame();
    // Idle-frame skip: nothing changed since the last render, so skip the
    // full composite + flip. Without this the flip chain runs a full
    // 1280x800 bilinear composite + fb copy at every vsync (~60fps) even
    // with a static canvas — the observed ~95% idle CPU. Changes set
    // repaint_pending (requestRender); it is cleared after a successful
    // render, and a flip-pending collision leaves it set so the next
    // flip event re-renders.
    if (!self.repaint_pending) {
        return;
    }
    const perf_t0 = perfNs(self);

    const perf_t_sync = perfNs(self);
    // Subsurfaces: position child nodes over their mapped parent.
    syncSubsurfaceNodes(self);

    const so = self.scene_output orelse {
        log.err("render: no scene output", self.io, self.log_cfg, "server", .{});
        return;
    };

    // M3 cursor: follow the seat pointer, show the client cursor surface
    // or the fallback rect. update() captures the previous frame's
    // footprints BEFORE moving the nodes: a partial upload must repaint
    // both the old and the new position.
    const cursor_fp = self.cursor.?.update();
    const perf_t_cursor = perfNs(self);

    // Damage accumulation: this frame's surface damage translated into
    // output coordinates, plus the cursor's old+new footprints. The ring
    // is the upload region for the raylib backend; the pixman repaint
    // below stays a full repaint. The first frame damages the whole
    // output — the window texture starts blank, so a partial first upload
    // would leave the background uninitialized. A CAMERA change (pan,
    // zoom) moves every pixel, so the whole output is damaged too —
    // otherwise the partial upload smears the previous canvas around the
    // dragged cursor (the drag-streak bug).
    const camera_changed = self.last_camera.center_x != self.camera.center_x or
        self.last_camera.center_y != self.camera.center_y or
        self.last_camera.zoom != self.camera.zoom;
    self.last_camera = self.camera;
    if (self.frames_rendered == 0 or camera_changed) {
        so.addDamage(.{ .x = 0, .y = 0, .width = out.mode.width, .height = out.mode.height });
    }
    const out_rect: geom.Rect = .{ .x = 0, .y = 0, .width = out.mode.width, .height = out.mode.height };
    // The surfaces about to be drawn this frame (presentation feedback
    // targets) + their damage: the library's per-frame surface pass.
    // collectPresented rebuilds the scene's presented list; the
    // addSurfaceDamage loop translates each node's committed damage
    // (surface coordinates) by the node's absolute position into output
    // coordinates, clipped to the output (damage is a hint; clipping is
    // safe). The compositor drives the pass; the scene.presented list is
    // consumed below for frame callbacks + presentation feedback.
    wayland.surface_node.collectPresented(self.scene.?);
    wayland.surface_node.addSurfaceDamage(self.scene.?, so, out_rect);
    if (!std.meta.eql(cursor_fp.old[0], cursor_fp.new[0]) or !std.meta.eql(cursor_fp.old[1], cursor_fp.new[1])) {
        for (cursor_fp.old) |r| if (r) |rr| so.addDamage(rr);
        for (cursor_fp.new) |r| if (r) |rr| so.addDamage(rr);
    }

    // Composite the canvas into the framebuffer, then present it. M4:
    // the canvas pass (background fill + camera-transformed surface
    // textures + screen-space cursor) replaces the scene-output render;
    // the damage-ring accounting below is unchanged.
    if (self.cursor_repaint) {
        // Hover cursor move: the canvas is static, so restore the old
        // cursor region from the persisted base + redraw the cursor at the
        // new pointer — no full-canvas recomposite (the ~450ms bilinear).
        // The base is only invalidated by a real canvas change, which takes
        // the compositeCanvas path.
        self.cursor_repaint = false;
        if (self.base_framebuffer) |base| {
            // Restore BOTH old footprints (the fallback-rect node AND the
            // client-cursor node — weston-terminal sets a cursor surface,
            // so the visible cursor is the buf node, not the rect node).
            // Restoring only the rect node left the old client cursor in
            // place, smearing a trail behind the moving pointer.
            for (cursor_fp.old) |r| {
                if (r) |rr| copyRegion(base, self.framebuffer, rr);
            }
        }
        self.cursor.?.draw(self.framebuffer);
    } else if (self.frame_kick) {
        // A client is ready for the next frame (pending wl_callback) but
        // the canvas is unchanged. Present the current framebuffer so the
        // callback fires and the client can render + commit its pending
        // update — no recomposite.
        self.frame_kick = false;
    } else {
        compositeCanvas(self);
    }
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
        // Usually the flip-pending pacing collision (a commit while a
        // flip is in flight); the DRM logs real failures itself. The
        // repaint flag stays set so the flip event re-renders it.
        log.debug("output commit failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    const perf_t_present = perfNs(self);

    // Frame callbacks: the surfaces presented this frame get
    // wl_callback.done at present time (wlroots wlr_surface_send_frame_done,
    // wlr_compositor.c:1131-1139). The time is the monotonic clock in ms
    // (.awake = CLOCK_MONOTONIC in the 0.16 std.Io.Clock); the u32
    // wrap-around is fine — the protocol defines an undefined base.
    const now_ms: u32 = @truncate(@as(u64, @bitCast(std.Io.Clock.now(.awake, self.io.*).toMilliseconds())));
    for (self.scene.?.presented.items) |s| s.sendFrameDone(now_ms);

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

    // wp_presentation: every surface drawn this frame was presented. The
    // output's wl_output global names the output for sync_output, and the
    // output's own refresh drives the protocol refresh value.
    self.presentation.present(self.scene.?.presented.items, self.wl_output, @intCast(out.mode.refresh_msec), 0);

    self.frames_rendered += 1;
    // The frame was rendered + committed (the flip is in flight): clear
    // the pending flag so the next flip event skips until a change.
    self.repaint_pending = false;
    tracy.frameMark(null);
    log.debug("render frame={d} surfaces={d}", self.io, self.log_cfg, "server", .{
        self.frames_rendered,
        self.scene.?.presented.items.len,
    });

    // Frame-done and presentation events were marshalled above; push them
    // out now. onDisplayReady flushes after dispatching client requests,
    // but a DRM-driven frame loop runs from the flip event instead, where
    // the display fd may be idle (a silent client) — without this the
    // callbacks sit in the outbound buffer forever. Idempotent when the
    // headless timer path already flushed.
    self.display.flushClients();

    // Progress: keep the watchdog from firing. A wedged loop stops instead
    // of hanging tests. Guarded by watchdog_enabled: zio's setTimer arms
    // an un-armed timer, so without this a disabled watchdog (interactive
    // demo) would be re-armed by the first render and fire anyway.
    if (self.watchdog_enabled) {
        if (self.watchdog) |t| {
            self.loop.?.setTimer(t, .{ .duration = zio.Duration.fromMilliseconds(watchdog_timeout_ms) });
        }
    }
    if (self.run_frames != 0 and self.frames_rendered >= self.run_frames) {
        log.info("reached WAYLAND_RUN_FRAMES={d}, stopping", self.io, self.log_cfg, "server", .{self.run_frames});
        self.loop.?.stop();
    }
}

/// Composite one frame into the framebuffer with the M4 canvas pass:
/// 1. background fill (fb.fill — the scene's background rect is gone),
/// 2. every mapped surface's texture stamped at its world rect (the
///    node's absolute position + the SURFACE size — buffer size under
///    the committed transform, divided by the scale — sampled through the
///    surface's buffer transform) through the server camera; canvas.render
///    composites in array order, so the last item draws on top (the entry
///    iteration order, same as the presented list; the E2E has a single
///    surface),
/// 3. the cursor in SCREEN space through an identity camera (constant
///    size, canvas-compositing.md §4). The cursor scene nodes remain as
///    state (Cursor.update/Cursor.footprints still position them for the
///    damage ring) but are no longer drawn by the scene.
/// Composite the full canvas (background + camera-transformed surfaces +
/// screen-space cursor) into the display framebuffer. The background +
/// surfaces (the "base") are rendered into the persisted base_framebuffer
/// first and copied out, so renderFrame's cursor_repaint path can restore
/// a cursor region from the base without recompositing the whole canvas
/// (the ~450ms full-canvas bilinear in the VM).
fn compositeCanvas(self: *ServerState) void {
    ensureBaseFramebuffer(self);
    compositeBase(self);
    copyWhole(self.base_framebuffer.?, self.framebuffer);
    self.cursor.?.draw(self.framebuffer);
}

/// Render the background + all mapped surfaces through the camera into the
/// base framebuffer (the canvas WITHOUT the cursor). The expensive
/// full-canvas bilinear; done only when the canvas actually changes.
fn compositeBase(self: *ServerState) void {
    const base = self.base_framebuffer orelse return;
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
    base.fill(bg);

    // 2. Surfaces: world rect = the node's absolute position + the
    //    SURFACE size (the node dst is the surface size — the buffer size
    //    under the committed transform divided by the scale, set by the
    //    library's SurfaceNode update). The item carries the surface's buffer
    //    transform so the canvas pass samples the texture through it
    //    (notes/124 gap 1; scale=1 + normal = today's 1:1 blit, byte
    //    identical).
    var items: std.ArrayList(CanvasItem) = .empty;
    defer items.deinit(self.allocator);
    // The cursor's WlSurface is drawn ONLY as the cursor (Cursor.draw),
    // never as a normal surface — matching wlroots (the cursor is a
    // separate plane, never a scene node) and niri (the cursor surface is
    // excluded from normal surface rendering via an early return on its
    // commit). Rendering it here too produced a SECOND cursor at the
    // surface's node position.
    const cursor_res = self.seat.cursorSurface();
    const scene = self.scene orelse return;
    var entry_it = scene.surface_nodes.valueIterator();
    while (entry_it.next()) |sn| {
        if (cursor_res) |cr| {
            if (sn.*.surface.resource == cr) continue;
        }
        const node = sn.*.node orelse continue;
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
            .transform = sn.*.surface.current.transform,
        }) catch |err| {
            log.warn("canvas item append OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        };
    }
    wayland.canvas.render(self.allocator, base, &self.camera, items.items, if (self.fast_render) 3 else 1);
}

/// Create the base framebuffer (matching the display framebuffer's size)
/// on first use; freed in main's teardown.
fn ensureBaseFramebuffer(self: *ServerState) void {
    if (self.base_framebuffer != null) return;
    const fb = pixman.Framebuffer.create(
        self.allocator,
        self.framebuffer.width,
        self.framebuffer.height,
    ) catch |err| {
        log.err("base framebuffer create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    self.base_framebuffer = fb;
}

/// Copy a rect from src to dst (both output-sized, stride = width*4).
fn copyRegion(src: *pixman.Framebuffer, dst: *pixman.Framebuffer, rect: geom.Rect) void {
    const x_start: i32 = @max(rect.x, 0);
    const y_start: i32 = @max(rect.y, 0);
    const x_end_raw = std.math.add(i32, rect.x, rect.width) catch std.math.maxInt(i32);
    const y_end_raw = std.math.add(i32, rect.y, rect.height) catch std.math.maxInt(i32);
    const x_end: i32 = @min(x_end_raw, dst.width);
    const y_end: i32 = @min(y_end_raw, dst.height);
    if (x_start >= x_end or y_start >= y_end) return;
    const row_bytes: usize = @intCast(@as(i32, x_end - x_start) * 4);
    const src_stride: usize = @intCast(src.stride);
    const dst_stride: usize = @intCast(dst.stride);
    var yy: i32 = y_start;
    while (yy < y_end) : (yy += 1) {
        const so: usize = @as(usize, @intCast(yy)) * src_stride + @as(usize, @intCast(x_start)) * 4;
        const do_: usize = @as(usize, @intCast(yy)) * dst_stride + @as(usize, @intCast(x_start)) * 4;
        @memcpy(dst.data[do_..][0..row_bytes], src.data[so..][0..row_bytes]);
    }
}

/// Copy the whole base into dst (same size + stride).
fn copyWhole(src: *pixman.Framebuffer, dst: *pixman.Framebuffer) void {
    @memcpy(dst.data, src.data);
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

/// Track every compositor surface we do not track yet. The library's
/// SurfaceNode owns the surface→scene lifecycle (its commit/unmap/destroy
/// listeners keep the scene node in sync); the compositor's remaining
/// policy is WHICH surfaces get bindings — all of them — plus the
/// renderer/texture integration (surface_node_impl). Called from the
/// frame handler, so surfaces created in the same dispatch are caught.
fn syncSurfaces(self: *ServerState) void {
    const scene = self.scene orelse return;
    var subscribed_new = false;
    for (self.compositor.surfaces.items) |s| {
        if (wayland.surface_node.surfaceNodeFor(scene, s) != null) continue;
        _ = wayland.surface_node.trackSurface(scene, s, &surface_node_impl, self) catch |err| {
            log.warn("failed to track surface: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            continue;
        };
        subscribed_new = true;
    }
    // A newly-tracked surface may already have committed its buffer (the
    // commit fired before we subscribed); wake the idle renderer so its
    // content actually appears. Without this, a surface that maps once
    // between renders is never drawn.
    if (subscribed_new) requestRender(self);
}

/// The library SurfaceNode's renderer/texture integration + the
/// compositor's policy hooks: pixel import/update through the pixman
/// renderer, subsurface orphan recovery before each commit sync, and
/// seat/presentation cleanup at surface death.
const surface_node_impl: wayland.surface_node.Impl = .{
    .import = surfaceNodeImport,
    .update = surfaceNodeUpdate,
    .before_update = surfaceNodeBeforeUpdate,
    .destroyed = surfaceNodeDestroyed,
};

/// Import the surface's current buffer into a renderer texture (the
/// scene node owns the copy).
fn surfaceNodeImport(ctx: *anyopaque, s: *Surface, buf: *wayland.buffers.Buffer) ?*Texture {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    _ = s;
    const pixels = surfacePixels(self, buf) orelse {
        log.debug("surfnode: no pixels", self.io, self.log_cfg, "server", .{});
        return null;
    };
    return importSurfacePixels(self, buf, pixels);
}

/// Same-size commit fast path: update the texture in place (no alloc, no
/// texture churn — the per-frame hot path).
fn surfaceNodeUpdate(
    ctx: *anyopaque,
    texture: *Texture,
    s: *Surface,
    buf: *wayland.buffers.Buffer,
) bool {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    _ = s;
    const pixels = surfacePixels(self, buf) orelse return false;
    const byte_len = @as(usize, @intCast(pixels.stride)) * @as(usize, @intCast(buf.height));
    return wayland.pixman.PixmanRenderer.updateMemory(
        texture,
        buf.width,
        buf.height,
        pixels.stride,
        pixels.ptr[0..byte_len],
    );
}

/// Compositor policy before the node syncs from a commit: subsurface
/// orphan recovery — a surface whose wl_subsurface died (the client
/// destroyed the role object, or the parent surface died; subsurface.zig
/// tears the entry down and clears the role) renders as a plain surface
/// again. Its tree leaves the (possibly dead) parent tree for the root
/// and shows on its next commit (wlroots recursively unmaps children
/// with the parent, wlr_compositor.c:854-872, and the surface re-renders
/// once its role object is gone).
fn surfaceNodeBeforeUpdate(ctx: *anyopaque, sn: *wayland.surface_node.SurfaceNode) void {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    if (sn.tree) |tree| {
        if (subsurfaceFor(self, sn.surface) == null and tree.parent != self.scene.?.root) {
            self.scene.?.root.appendChild(self.allocator, tree) catch |err| {
                // OOM: the subsurface tree is skipped this frame.
                log.warn("subsurface orphan re-root OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            };
            tree.enable(true);
        }
    }
}

/// The surface was destroyed: drop the seat's surface state and deliver
/// discarded presentation feedback. The library binding tears itself
/// down after this hook (its destroy listener detaches the node — the
/// leave signal sends the wire wl_surface.leave for a still-entered
/// surface, keeping the client's enter/leave accounting balanced).
fn surfaceNodeDestroyed(ctx: *anyopaque, s: *Surface) void {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    self.seat.surfaceDestroyed(s);
    self.presentation.discard(s);
}

/// The wl_subsurface role object for `s`, or null when `s` is not a
/// subsurface (the surface-side link to its parent; subsurface.zig
/// records surface/parent/x/y/sync plus the restack fields).
fn subsurfaceFor(self: *ServerState, s: *Surface) ?*Subsurface {
    for (self.subcompositor.subsurfaces.items) |ss| {
        if (ss.surface == s) return ss;
    }
    return null;
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

/// Tear down the compositor-side per-surface state. The library's
/// surface bindings (listeners, scene nodes, registry) are freed by
/// Scene.deinit (untrackAll), which runs after this in main's defer
/// order — and the compositor's surfaces are destroyed later still, so
/// no surface signal can reach freed bindings.
fn cleanupSurfaceEntries(self: *ServerState) void {
    // The cursor owns its textures + scene nodes; it detaches from the
    // seat and the scene root before they are torn down below.
    if (self.cursor) |c| {
        c.deinit();
        self.cursor = null;
    }
    if (build_options.enable_raylib) {
        if (self.raylib_input) |input| {
            self.allocator.destroy(input);
            self.raylib_input = null;
        }
    }
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
    const pick_x: i32 = @intFromFloat(@min(
        @max(world.x, @as(f64, std.math.minInt(i32))),
        @as(f64, std.math.maxInt(i32)),
    ));
    const pick_y: i32 = @intFromFloat(@min(
        @max(world.y, @as(f64, std.math.minInt(i32))),
        @as(f64, std.math.maxInt(i32)),
    ));
    const node = scene.pick(pick_x, pick_y) orelse return null;
    // Back-map the picked node to its surface through the library's
    // surface→scene table.
    const surface = wayland.surface_node.surfaceForNode(scene, node) orelse return null;
    const rect = node.absolutePosition();
    return .{
        .surface = surface,
        .sx = pick_x - rect.x,
        .sy = pick_y - rect.y,
    };
}

/// Capture source for zwlr_screencopy: the display framebuffer (cursor
/// composited in) for overlay_cursor=1; the base framebuffer (canvas
/// without the cursor, current because it is recomposited before the
/// cursor draw in the same render) for overlay_cursor=0. Falls back to
/// the display framebuffer when no base exists yet.
fn getFramebuffer(ctx: *anyopaque, overlay_cursor: bool) ?*pixman.Framebuffer {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    if (!overlay_cursor) {
        if (self.base_framebuffer) |base| return base;
    }
    return self.framebuffer;
}

/// Resolve a client's wl_output resource to the output it belongs to.
fn outputFromResource(ctx: *anyopaque, resource: *wayland.server.wl.Output) ?*wayland.output.Output {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const wl_output = self.wl_output orelse return null;
    if (!wl_output.owns(resource)) return null;
    return wl_output.output;
}

/// A screencopy frame is waiting for its next commit: wake the renderer
/// (the idle-frame skip would otherwise never render the copy).
fn requestFrame(ctx: *anyopaque) void {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    requestRender(self);
}

/// Seat key signal: Mod4+Escape quits the server (keysym binding).
fn onSeatKey(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_key_listener", listener);
    if (seat.last_keysym == wayland.xkb.keysym_escape and seat.mod4Active()) {
        log.info("Mod4+Escape pressed: stopping", self.io, self.log_cfg, "server", .{});
        if (self.loop) |loop| loop.stop();
    }
    // Server-side key repeat: arm the timer on a press (fires after the
    // seat's delay, then re-arms at the rate while the key is held);
    // disarm on release. Repeated events re-fire this signal with
    // pressed=true, but the timer is already armed then.
    if (self.repeat_timer) |t| {
        if (seat.last_key_pressed) {
            if (!self.repeat_timer_armed) {
                self.repeat_timer_armed = true;
                if (self.loop) |loop| {
                    loop.setTimer(t, .{
                        .duration = zio.Duration.fromMilliseconds(@intCast(@max(seat.key_repeat_delay, 1))),
                    });
                }
            }
        } else {
            self.repeat_timer_armed = false;
            if (self.loop) |loop| _ = loop.clearTimer(t);
        }
    }
}

/// One-shot repeat timer tick: emit the held key's repeat + re-arm at the
/// seat's interval while the key is held; otherwise stay dead.
fn onRepeatTick(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    if (!self.seat.repeatActive()) {
        self.repeat_timer_armed = false;
        return;
    }
    self.seat.onRepeatTick();
    loop.setTimer(self.repeat_timer.?, .{ .duration = zio.Duration.fromMilliseconds(self.seat.repeatIntervalMs()) });
}

/// M4 camera drag: the left button press anchors a pan gesture; motion
/// while held pans the camera. A click without motion never moves the
/// pointer between press and release, so it keeps the seat's
/// click-to-focus (already handled inside the seat).
fn onSeatButton(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_button_listener", listener);
    if (seat.last_button != wayland.seat.btn_left) return;
    if (seat.last_button_pressed) {
        // Arm the pan anchor but DON'T start it (drag_active stays false):
        // a click without enough movement must keep click-to-focus.
        self.camera_drag = DragPoint{ .x = seat.pointer_x, .y = seat.pointer_y };
        self.drag_active = false;
        self.fast_render = false;
    } else {
        self.camera_drag = null;
        self.drag_active = false;
        self.fast_render = false;
        seat.setPointerGrab(false);
    }
}

/// M4 camera pan: while the left button is held + the pointer has moved
/// past drag_threshold, motion pans the camera center by (-delta / zoom)
/// world units per screen pixel — the world point under the pointer stays
/// under it. Sub-threshold movement (a click) is a hover (cursor follows,
/// no pan), so click-to-focus on the terminal works and the camera does
/// not jump.
fn onSeatPointerMove(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_pointer_move_listener", listener);
    // A drag is armed (button held). If it hasn't crossed the threshold
    // yet, a sub-threshold move is a hover (cursor follows, no pan); once
    // it crosses, start the pan.
    if (self.camera_drag) |anchor| {
        const dx = seat.pointer_x - anchor.x;
        const dy = seat.pointer_y - anchor.y;
        if (!self.drag_active and dx * dx + dy * dy < drag_threshold_sq) {
            self.cursor_repaint = true;
            requestRender(self);
            return;
        }
        // Above the threshold (or already dragging): pan the camera. The
        // implicit pointer grab starts here: the client under the pointer
        // must not see the motion (it would extend a text selection while
        // the user pans the canvas).
        self.drag_active = true;
        self.fast_render = true;
        seat.setPointerGrab(true);
        self.camera.center_x -= @as(f64, @floatFromInt(dx)) / self.camera.zoom;
        self.camera.center_y -= @as(f64, @floatFromInt(dy)) / self.camera.zoom;
        self.camera_drag = DragPoint{ .x = seat.pointer_x, .y = seat.pointer_y };
        log.debug("camera center -> {d},{d}", self.io, self.log_cfg, "camera", .{
            self.camera.center_x, self.camera.center_y,
        });
        requestRender(self);
        return;
    }
    // No drag armed: hover — the canvas is static, so just move the
    // cursor (repaint only the cursor region, not the full composite).
    self.cursor_repaint = true;
    requestRender(self);
}

/// M4 camera zoom: a vertical wheel notch (+1 discrete) multiplies the
/// camera zoom by 1.25, -1 divides; clamped to [0.1, 16.0]. The zoom is
/// a viewport property, so it applies regardless of pointer focus (the
/// seat emits the axis signal for every axis event).
fn onSeatAxis(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_axis_listener", listener);
    if (seat.last_axis != .vertical_scroll or seat.last_axis_discrete == 0) return;
    const factor: f64 = if (seat.last_axis_discrete > 0) 1.25 else 1.0 / 1.25;
    var steps: i32 = seat.last_axis_discrete;
    if (steps < 0) steps = -steps;
    var zoom = self.camera.zoom;
    var i: i32 = 0;
    while (i < steps) : (i += 1) zoom *= factor;
    self.camera.zoom = std.math.clamp(zoom, 0.1, 16.0);
    log.debug("camera zoom -> {d}", self.io, self.log_cfg, "camera", .{self.camera.zoom});
    requestRender(self);
}

/// Position every subsurface over its mapped parent and keep its tree
/// inside the PARENT surface's tree (notes/107 gap 9: the old flat
/// re-append to the scene root made each subsurface draw above every
/// other surface in the scene). The parent tree's children order is the
/// stacking order — the parent's own buffer node first, then each
/// subsurface's tree in place_above/place_below order — so a subsurface
/// draws above its parent and earlier siblings, below later siblings, and
/// never above unrelated toplevels. wlroots keeps the same structure
/// (types/scene/subsurface_tree.c:238-304: children inside the parent's
/// tree node). Pending restacks are applied here (request-time recording
/// lives in the subsurface role state) and cleared.
fn syncSubsurfaceNodes(self: *ServerState) void {
    const scene = self.scene orelse return;
    for (self.subcompositor.subsurfaces.items) |ss| {
        const child_sn = wayland.surface_node.surfaceNodeFor(scene, ss.surface) orelse continue;
        const child_tree = child_sn.tree orelse continue;
        const parent_sn = wayland.surface_node.surfaceNodeFor(scene, ss.parent) orelse continue;
        if (parent_sn.tree) |parent_tree| {
            // Move the child tree under the parent's tree (appendChild
            // reparents; a root placeholder lands here on the parent's
            // first map).
            if (child_tree.parent != parent_tree) {
                parent_tree.appendChild(scene.allocator, child_tree) catch |err| {
                    log.warn("subsurface parenting failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
                    child_tree.enable(false);
                    continue;
                };
            }
            // A pending restack becomes effective only after the parent
            // committed (F5: z-order is double-buffered on the parent,
            // wayland.xml:3336-3337; the parent-commit listener sets
            // restack_committed). Applied here (the scene reorder) and
            // reset — the next place_above needs a fresh commit.
            if (ss.restack_committed) {
                if (ss.restack_sibling_id != 0) {
                    applyRestack(self, ss, child_tree, parent_tree);
                }
                ss.restack_committed = false;
                ss.restack_sibling_id = 0;
            }
            // Offset relative to the parent tree (which sits at the
            // parent surface's origin; the old code summed the parent's
            // absolute position, equal here because the trees are all at
            // the root's (0,0) chain).
            child_tree.x = ss.x;
            child_tree.y = ss.y;
            child_tree.enable(true);
        } else {
            child_tree.enable(false);
        }
    }
}

/// Apply a recorded wl_subsurface.place_above/place_below: reorder
/// `child` within `parent_tree`'s children to just after (above) or just
/// before (below) the reference surface's node. The reference is recorded
/// at request time as the wl_surface RESOURCE id of the parent or a
/// sibling subsurface (never a raw *Surface, so a dead reference cannot
/// dangle): resolve it to the parent's own buffer node or the sibling's
/// tree. A reference whose surface or node is gone drops the restack.
fn applyRestack(
    self: *ServerState,
    ss: *Subsurface,
    child: *wayland.scene.SceneNode,
    parent_tree: *wayland.scene.SceneNode,
) void {
    const scene = self.scene orelse return;
    const ref_node: ?*wayland.scene.SceneNode = blk: {
        if (ss.restack_sibling_id == ss.parent.resource.getId()) {
            const parent_sn = wayland.surface_node.surfaceNodeFor(scene, ss.parent) orelse break :blk null;
            break :blk parent_sn.node;
        }
        // The reference is a wl_surface resource id in the child's client
        // namespace, so match the client too (compositor.surfaces spans
        // clients; two clients could hold the same id).
        const child_client = ss.surface.resource.getClient();
        for (self.subcompositor.subsurfaces.items) |other| {
            if (other.parent != ss.parent) continue;
            if (other.surface.resource.getClient() != child_client) continue;
            if (other.surface.resource.getId() != ss.restack_sibling_id) continue;
            const other_sn = wayland.surface_node.surfaceNodeFor(scene, other.surface) orelse break :blk null;
            break :blk other_sn.tree;
        }
        break :blk null;
    };
    const ref = ref_node orelse return;
    if (ref == child) return; // degenerate: the reference is itself
    parent_tree.removeChild(child);
    const ref_idx = std.mem.indexOfScalar(*wayland.scene.SceneNode, parent_tree.children.items, ref) orelse {
        parent_tree.appendChild(self.allocator, child) catch |err| {
            // OOM: the child stays detached this frame.
            log.warn("subsurface append OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        };
        return;
    };
    const insert_at = ref_idx + (if (ss.restack_above) @as(usize, 1) else 0);
    parent_tree.children.insert(self.allocator, insert_at, child) catch {
        // OOM: fall back to the top of the stack (appendChild re-links).
        parent_tree.appendChild(self.allocator, child) catch |err| {
            // OOM: the child stays detached this frame.
            log.warn("subsurface append OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        };
        return;
    };
    child.parent = parent_tree;
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
