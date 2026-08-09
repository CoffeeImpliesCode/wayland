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
/// wl_output_transform box/point helpers (utils/matrix.zig): the surface
/// size of a buffer under the surface's scale+transform (buffer -> surface
/// per wlroots util/box.c:105-145, ported 1:1).
const matrix = wayland.utils.matrix;

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
/// Background color (straight alpha RGBA).
const background_color = [4]f32{ 0.1, 0.1, 0.12, 1.0 };
/// Fallback cursor: a small light rect when no client cursor surface.
const cursor_size: i32 = 8;
const cursor_color = [4]f32{ 0.95, 0.95, 0.95, 1.0 };

/// Per-surface scene state: the SceneBufferNode that draws the surface's
/// current buffer, plus the listeners that keep it in sync (commit
/// updates the texture, destroy removes it and frees the entry).
///
/// Each surface also owns a .tree container node (`tree`, under
/// scene.root for toplevels, under the PARENT surface's tree for
/// subsurfaces). The buffer node is the tree's first child; a surface's
/// subsurfaces are its siblings' trees appended after it — draw order =
/// children order, so a subsurface draws above its parent but below any
/// later sibling, and never above unrelated toplevels (notes/107 gap 9:
/// the old flat re-append drew every subsurface above EVERYTHING).
const SurfaceEntry = struct {
    state: *ServerState,
    surface: *Surface,
    /// The .tree container holding `node` (and, for non-subsurfaces, the
    /// subtrees of this surface's subsurfaces). Null while unmapped.
    tree: ?*wayland.scene.SceneNode = null,
    /// The surface's buffer node (the tree's first child; what the seat
    /// picks and the canvas draws).
    node: ?*wayland.scene.SceneNode = null,
    commit_listener: wire.Listener(*Surface),
    destroy_listener: wire.Listener(*Surface),
    /// wl_surface.enter/leave signal listeners (the surface module emits
    /// the signals on output enter/leave; these send the wire events).
    enter_listener: wire.Listener(*wayland.output.Output),
    leave_listener: wire.Listener(*wayland.output.Output),
    /// Enter/leave: whether wl_surface.enter was sent for this surface
    /// (single-output server). Guards the wire events so map/unmap/destroy
    /// firing patterns can never double-send.
    entered: bool = false,
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
    /// Whether the watchdog is active (WAYLAND_WATCHDOG_DISABLE unset).
    /// Guards BOTH the initial loop.add and the renderFrame re-arm: zio's
    /// setTimer arms an un-armed timer, so a re-arm on a disabled watchdog
    /// would re-add it and it would still fire on an idle demo.
    watchdog_enabled: bool = true,
    output: ?*wayland.output.Output = null,
    /// Toplevels created by clients (tracked for observability).
    toplevels: std.ArrayList(*wayland.shell.XdgToplevel) = .empty,
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
    /// WAYLAND_PERF=1: log per-frame pipeline timings (import -> render
    /// -> present) in microseconds.
    perf: bool = false,

    new_output_listener: wire.Listener(*wayland.output.Output),
    frame_listener: wire.Listener(*wayland.output.Output),
    new_toplevel_listener: wire.Listener(*wayland.shell.XdgToplevel),
    new_popup_listener: wire.Listener(*wayland.shell.XdgPopup),
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
        .seat_button_listener = wire.Listener(*wayland.seat.Seat).init(onSeatButton),
        .seat_pointer_move_listener = wire.Listener(*wayland.seat.Seat).init(onSeatPointerMove),
        .seat_axis_listener = wire.Listener(*wayland.seat.Seat).init(onSeatAxis),
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
    // M4 Phase B camera controls: wheel zoom + drag pan hook the seat's
    // existing event surface (button, pointer_move, axis). The raylib
    // and libinput backends feed these signals through the seat API
    // (pointerButton/pointerMotion/pointerAxis), so no backend change is
    // needed; headless E2E synthesizes the same calls.
    seat.events.button.add(&state.seat_button_listener);
    seat.events.pointer_move.add(&state.seat_pointer_move_listener);
    seat.events.axis.add(&state.seat_axis_listener);
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
    // The idle-frame skip means a healthy server renders nothing between
    // changes, so the watchdog (re-armed only per render) would stop an
    // idle interactive demo after the window. WAYLAND_WATCHDOG_DISABLE
    // opts out (set by the interactive VM demo; the E2E keeps it).
    const watchdog_disabled = init.environ_map.get("WAYLAND_WATCHDOG_DISABLE") != null;
    state.watchdog_enabled = !watchdog_disabled;
    if (!watchdog_disabled) loop.add(&watchdog.c);

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
        var it = self.surface_entries.valueIterator();
        while (it.next()) |ep| {
            if (ep.*.surface.current.frame_callbacks.items.len > 0) {
                self.frame_kick = true;
                requestRender(self);
                break;
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

fn onOutputFrame(listener: *wire.Listener(*wayland.output.Output), out: *wayland.output.Output) void {
    const self: *ServerState = @fieldParentPtr("frame_listener", listener);
    renderFrame(self, out);
}

/// Mark that the next frame must render (something changed) and wake the
/// renderer via output.sendFrame(). The DRM frame chain is driven by the
/// flip event (sendFrame -> renderFrame -> commit -> flip -> event), so a
/// change while idle needs this kick to start a frame; subsequent frames
/// then pace off the flips until the change is consumed.
fn requestRender(self: *ServerState) void {
    self.repaint_pending = true;
    if (!self.in_render) {
        if (self.output) |out| out.sendFrame();
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
    if (self.cursor_repaint) {
        // Hover cursor move: the canvas is static, so restore the old
        // cursor region from the persisted base + redraw the cursor at the
        // new pointer — no full-canvas recomposite (the ~450ms bilinear).
        // The base is only invalidated by a real canvas change, which takes
        // the compositeCanvas path.
        self.cursor_repaint = false;
        if (self.base_framebuffer) |base| {
            if (old_cursor[0]) |r| copyRegion(base, self.framebuffer, r);
        }
        drawCursor(self);
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
    // The frame was rendered + committed (the flip is in flight): clear
    // the pending flag so the next flip event skips until a change.
    self.repaint_pending = false;
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
///    state (updateCursor/cursorFootprints still position them for the
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
    drawCursor(self);
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
    //    under the committed transform divided by the scale, see
    //    updateSurfaceNode). The item carries the surface's buffer
    //    transform so the canvas pass samples the texture through it
    //    (notes/124 gap 1; scale=1 + normal = today's 1:1 blit, byte
    //    identical).
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
            .transform = entry.*.surface.current.transform,
        }) catch |err| {
            log.warn("canvas item append OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        };
    }
    wayland.canvas.render(self.allocator, base, &self.camera, items.items);
}

/// Draw the screen-space cursor into the display framebuffer at the
/// pointer's current position (identity camera, constant size). The
/// fallback rect is a texture now — the canvas pass draws textures, not
/// scene rects — and the client cursor surface texture wins when one is
/// set.
fn drawCursor(self: *ServerState) void {
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
    var subscribed_new = false;
    for (self.compositor.surfaces.items) |s| {
        if (self.surface_entries.contains(s)) continue;
        const entry = self.allocator.create(SurfaceEntry) catch |err| {
            log.warn("failed to track surface: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            continue;
        };
        entry.* = .{
            .state = self,
            .surface = s,
            .tree = null,
            .node = null,
            .commit_listener = wire.Listener(*Surface).init(onSurfaceCommit),
            .destroy_listener = wire.Listener(*Surface).init(onSurfaceDestroy),
            .enter_listener = wire.Listener(*wayland.output.Output).init(onSurfaceEnter),
            .leave_listener = wire.Listener(*wayland.output.Output).init(onSurfaceLeave),
        };
        self.surface_entries.put(s, entry) catch |err| {
            self.allocator.destroy(entry);
            log.warn("failed to track surface: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            continue;
        };
        s.events.commit.add(&entry.commit_listener);
        s.events.destroy.add(&entry.destroy_listener);
        s.events.enter.add(&entry.enter_listener);
        s.events.leave.add(&entry.leave_listener);
        // updateSurfaceNode drives the enter/leave signals (setEntered at
        // node creation, setLeft at removal), so a surface that mapped
        // before this subscription still fires enter here — no separate
        // catch-up needed (the surface module's signals are the single
        // path; the wire event listeners are below).
        updateSurfaceNode(self, entry);
        subscribed_new = true;
    }
    // A newly-tracked surface may already have committed its buffer (the
    // commit fired before we subscribed); wake the idle renderer so its
    // content actually appears. Without this, a surface that maps once
    // between renders is never drawn.
    if (subscribed_new) requestRender(self);
}

/// wl_surface.commit applied: refresh the surface's scene node from its
/// current buffer. A committed buffer means the surface maps (or keeps
/// mapping) with content; a null buffer unmaps it.
fn onSurfaceCommit(listener: *wire.Listener(*Surface), _: *Surface) void {
    const entry: *SurfaceEntry = @fieldParentPtr("commit_listener", listener);
    updateSurfaceNode(entry.state, entry);
    requestRender(entry.state);
}

/// wl_surface destroyed: drop the scene node, deliver discarded feedback,
/// and free the tracking entry. The surface is still valid inside the
/// destroy signal (its buffers are released after the signal).
fn onSurfaceDestroy(listener: *wire.Listener(*Surface), s: *Surface) void {
    const entry: *SurfaceEntry = @fieldParentPtr("destroy_listener", listener);
    const self = entry.state;
    // removeSurfaceNode drives setLeft, whose leave signal sends the wire
    // wl_surface.leave — so a destroyed (still entered) surface gets its
    // leave here too, flag-guarded against double-sends. (wlroots drops
    // the output tracking silently at surface death, wlr_compositor.c:
    // 1055-1063; sending the event is harmless on a client-destroyed
    // resource and keeps the client's enter/leave accounting balanced.)
    removeSurfaceNode(self, entry);
    self.seat.surfaceDestroyed(s);
    self.presentation.discard(s);
    _ = self.surface_entries.remove(s);
    self.allocator.destroy(entry);
}

/// wl_surface.enter signal (surface gained the output; fired by the
/// surface module at map): send wl_surface.enter to the surface's client.
fn onSurfaceEnter(listener: *wire.Listener(*wayland.output.Output), _: *wayland.output.Output) void {
    const entry: *SurfaceEntry = @fieldParentPtr("enter_listener", listener);
    if (entry.entered) return;
    entry.entered = true;
    sendSurfaceEnter(entry.state, entry.surface, true);
}

/// wl_surface.leave signal (surface lost the output; fired at unmap):
/// send wl_surface.leave to the surface's client.
fn onSurfaceLeave(listener: *wire.Listener(*wayland.output.Output), _: *wayland.output.Output) void {
    const entry: *SurfaceEntry = @fieldParentPtr("leave_listener", listener);
    if (!entry.entered) return;
    entry.entered = false;
    sendSurfaceEnter(entry.state, entry.surface, false);
}

/// Send wl_surface.enter/leave for the surface's client: the wl_output
/// resource that client bound. A surface's events go only to its owner,
/// and a client that never bound wl_output gets none (wlroots
/// wlr_surface_send_enter/leave, wlr_compositor.c:1071-1128, iterate the
/// output's resources and match on the client). Single-output server: the
/// one WlOutput is the only output that can enter/leave.
fn sendSurfaceEnter(self: *ServerState, s: *Surface, enter: bool) void {
    const wl_output = self.wl_output orelse return;
    const client = s.resource.getClient();
    for (wl_output.resources.items) |res| {
        if (res.getClient() != client) continue;
        if (enter) {
            s.resource.sendEnter(res);
        } else {
            s.resource.sendLeave(res);
        }
        break;
    }
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
    // Orphan recovery: a surface whose wl_subsurface died (the client
    // destroyed the role object, or the parent surface died —
    // subsurface.zig tears the entry down and clears the role) renders as
    // a plain surface again. Its tree leaves the (possibly dead) parent
    // tree for the root and shows on its next commit (wlroots recursively
    // unmaps children with the parent, wlr_compositor.c:854-872, and the
    // surface re-renders once its role object is gone).
    if (entry.tree) |tree| {
        if (subsurfaceFor(self, s) == null and tree.parent != self.scene.?.root) {
            self.scene.?.root.appendChild(self.allocator, tree) catch |err| {
                // OOM: the subsurface tree is skipped this frame.
                log.warn("subsurface orphan re-root OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            };
            tree.enable(true);
        }
    }
    // The SURFACE size: the buffer size under the committed transform,
    // divided by the committed scale (notes/124 gap 1). The node's dst
    // rect is the surface rect, so pick, damage and the canvas world rect
    // are all surface-sized; the canvas pass samples the texture through
    // the transform. Commit validation guarantees integrality.
    const size = surfaceSize(s, buf);
    if (entry.node) |node| {
        // Same-size commit: update the texture in place (no alloc, no
        // texture churn — the per-frame hot path). The dst rect is still
        // refreshed: scale/transform can change on a commit that reuses
        // the same buffer.
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
                bn.dst_width = size.w;
                bn.dst_height = size.h;
                node.enable(true);
                return;
            }
            tex.destroy();
            bn.texture = null;
        }
    }
    const texture = importSurfacePixels(self, buf, pixels) orelse return;
    if (entry.node) |node| {
        // Update in place: swap in the new texture (dst = surface size).
        const bn = node.kind.buffer;
        if (bn.texture) |old| old.destroy();
        bn.texture = texture;
        bn.dst_width = size.w;
        bn.dst_height = size.h;
        node.enable(true);
    } else {
        // First map: create the tree container (under the parent surface's
        // tree for a subsurface, scene.root otherwise), then the buffer
        // node as its first child.
        ensureSurfaceTree(self, entry);
        const tree = entry.tree orelse {
            texture.destroy();
            log.warn("scene tree create failed", self.io, self.log_cfg, "server", .{});
            return;
        };
        const node = wayland.scene.SceneNode.create(self.allocator, tree, .buffer) catch |err| {
            texture.destroy();
            log.warn("scene node create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            return;
        };
        node.kind.buffer.texture = texture;
        node.kind.buffer.dst_width = size.w;
        node.kind.buffer.dst_height = size.h;
        entry.node = node;

        // The surface maps on the single output: drive the surface's
        // enter tracking (setEntered emits events.enter on the change;
        // the enter listener sends the wire event). Idempotent — node
        // creation happens exactly once per map.
        if (self.output) |out| s.setEntered(out);

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

/// The surface size of `buf` under the surface's committed transform and
/// scale: boxTransform of the buffer rect (buffer -> surface per
/// wl_output_transform, wlroots util/box.c:105-145) divided by the scale.
/// The commit validation (surface.zig validatePending) guarantees the
/// transformed buffer size is divisible by the scale, so the division is
/// exact.
fn surfaceSize(s: *Surface, buf: *wayland.buffers.Buffer) geom.Size {
    const rect = matrix.boxTransform(
        .{ .x = 0, .y = 0, .width = buf.width, .height = buf.height },
        s.current.transform,
        buf.width,
        buf.height,
    );
    return .{ .w = @divExact(rect.width, s.current.scale), .h = @divExact(rect.height, s.current.scale) };
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

/// Create the surface's tree container if it does not exist yet. A
/// non-subsurface (potential parent) gets its tree under scene.root; a
/// subsurface gets its tree under the PARENT surface's tree, or a
/// disabled root placeholder when the parent is not mapped yet
/// (syncSubsurfaceNodes reparents it into place once the parent maps).
fn ensureSurfaceTree(self: *ServerState, entry: *SurfaceEntry) void {
    if (entry.tree != null) return;
    const root = self.scene.?.root;
    var parent_tree: ?*wayland.scene.SceneNode = null;
    if (subsurfaceFor(self, entry.surface)) |ss| {
        if (self.surface_entries.get(ss.parent)) |parent_entry| {
            parent_tree = parent_entry.tree;
        }
    }
    const tree = wayland.scene.SceneNode.create(self.allocator, parent_tree orelse root, .tree) catch |err| {
        log.warn("scene tree create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    // A placeholder subsurface tree (parent unmapped) stays hidden until
    // syncSubsurfaceNodes moves it under the parent and enables it.
    if (parent_tree == null and subsurfaceFor(self, entry.surface) != null) {
        tree.enable(false);
    }
    entry.tree = tree;
}

/// Remove (and free) the surface's scene nodes; the entry keeps tracking
/// the surface for a future remap.
fn removeSurfaceNode(self: *ServerState, entry: *SurfaceEntry) void {
    // Detach this surface's subsurface trees first: node.destroy cascades
    // into the whole subtree, which would free the children's nodes out
    // from under their entries. Reparent them to the root, disabled; they
    // re-enter the parent's tree when the parent maps again. (On append
    // OOM the cascade still frees them — a catastrophic-memory path.)
    for (self.subcompositor.subsurfaces.items) |ss| {
        if (ss.parent != entry.surface) continue;
        const child_entry = self.surface_entries.get(ss.surface) orelse continue;
        const child_tree = child_entry.tree orelse continue;
        if (child_tree.parent != self.scene.?.root) {
            self.scene.?.root.appendChild(self.allocator, child_tree) catch |err| {
                log.warn("subsurface detach failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            };
            child_tree.enable(false);
        }
    }
    // The surface left the output: drive the surface's leave tracking
    // (setLeft emits events.leave on the change; idempotent when the
    // surface was never entered).
    if (entry.surface.outputs != null) entry.surface.setLeft();
    if (entry.node) |node| {
        if (node.kind.buffer.texture) |texture| texture.destroy();
        node.destroy(self.allocator);
        entry.node = null;
    }
    if (entry.tree) |tree| {
        tree.destroy(self.allocator);
        entry.tree = null;
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
        entry.enter_listener.link.remove();
        entry.leave_listener.link.remove();
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
    const pick_x: i32 = @intFromFloat(@min(
        @max(world.x, @as(f64, std.math.minInt(i32))),
        @as(f64, std.math.maxInt(i32)),
    ));
    const pick_y: i32 = @intFromFloat(@min(
        @max(world.y, @as(f64, std.math.minInt(i32))),
        @as(f64, std.math.maxInt(i32)),
    ));
    const node = scene.pick(pick_x, pick_y) orelse return null;
    var it = self.surface_entries.valueIterator();
    while (it.next()) |entry_ptr| {
        const entry = entry_ptr.*;
        if (entry.node == node) {
            const rect = node.absolutePosition();
            return .{
                .surface = entry.surface,
                .sx = pick_x - rect.x,
                .sy = pick_y - rect.y,
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

/// M4 camera drag: the left button press anchors a pan gesture; motion
/// while held pans the camera. A click without motion never moves the
/// pointer between press and release, so it keeps the seat's
/// click-to-focus (already handled inside the seat).
fn onSeatButton(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_button_listener", listener);
    if (seat.last_button != wayland.seat.btn_left) return;
    self.camera_drag = if (seat.last_button_pressed)
        DragPoint{ .x = seat.pointer_x, .y = seat.pointer_y }
    else
        null;
}

/// M4 camera pan: while the left button is held, pointer motion moves
/// the camera center by (-delta_x / zoom, -delta_y / zoom) world units
/// per screen pixel — the world point under the pointer stays under it.
fn onSeatPointerMove(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_pointer_move_listener", listener);
    // Hover (no drag): the canvas is static, so just move the cursor —
    // repaint only the cursor region (renderFrame's cursor_repaint path),
    // not the ~450ms full-canvas composite.
    if (self.camera_drag == null) {
        self.cursor_repaint = true;
        requestRender(self);
        return;
    }
    // Dragging: the camera pans, so the whole canvas re-composites.
    const drag = self.camera_drag.?;
    const dx = seat.pointer_x - drag.x;
    const dy = seat.pointer_y - drag.y;
    if (dx == 0 and dy == 0) return;
    self.camera.center_x -= @as(f64, @floatFromInt(dx)) / self.camera.zoom;
    self.camera.center_y -= @as(f64, @floatFromInt(dy)) / self.camera.zoom;
    self.camera_drag = DragPoint{ .x = seat.pointer_x, .y = seat.pointer_y };
    log.debug("camera center -> {d},{d}", self.io, self.log_cfg, "camera", .{
        self.camera.center_x, self.camera.center_y,
    });
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
        const child_entry = self.surface_entries.get(ss.surface) orelse continue;
        const child_tree = child_entry.tree orelse continue;
        const parent_entry = self.surface_entries.get(ss.parent) orelse continue;
        if (parent_entry.tree) |parent_tree| {
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
            if (ss.restack_sibling_id != 0) {
                applyRestack(self, ss, child_tree, parent_tree);
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
    const ref_node: ?*wayland.scene.SceneNode = blk: {
        if (ss.restack_sibling_id == ss.parent.resource.getId()) {
            const parent_entry = self.surface_entries.get(ss.parent) orelse break :blk null;
            break :blk parent_entry.node;
        }
        // The reference is a wl_surface resource id in the child's client
        // namespace, so match the client too (compositor.surfaces spans
        // clients; two clients could hold the same id).
        const child_client = ss.surface.resource.getClient();
        for (self.subcompositor.subsurfaces.items) |other| {
            if (other.parent != ss.parent) continue;
            if (other.surface.resource.getClient() != child_client) continue;
            if (other.surface.resource.getId() != ss.restack_sibling_id) continue;
            const other_entry = self.surface_entries.get(other.surface) orelse break :blk null;
            break :blk other_entry.tree;
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
