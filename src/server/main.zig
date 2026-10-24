//! M2 compositor test server (tinywl equivalent).
//!
//! Wires the `wayland` library end to end on a zio event loop:
//!   - CompositorDisplay + wl_shm + xdg-shell + wp_presentation + backend
//!   - the canvas renderer (WAYLAND_RENDERER: the pixman CPU rasterizer,
//!     the default, or the GLES2/EGL one) plus the scene graph: one
//!     SceneBufferNode per mapped surface (imported on commit)
//!   - main() is a phase sequence (buildCore, buildSeatModules,
//!     buildOutput, buildInputBackend, initServerState, subscribe,
//!     applyEnvironment, armEventLoop, runEventLoop); the `defer`s stay
//!     in main() because their LIFO order IS the teardown contract
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
//!                        "nested" selects the nested-wayland backend (our
//!                        compositor as a client of a parent compositor, M5);
//!                        "drm" selects the DRM/KMS backend; anything else
//!                        selects the headless backend
//!   WAYLAND_RENDERER    "pixman" (the default) selects the CPU renderer;
//!                        "gles2" selects the GLES2/EGL renderer, which
//!                        composites the canvas through the camera on
//!                        the GPU and reads the result back for scanout
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
/// The GLES2/EGL renderer (renderer/gles2.zig), selected by
/// WAYLAND_RENDERER=gles2. Same module as pixman: both satisfy the
/// renderer/renderer.zig Renderer contract, only the composite and the
/// scanout read-back differ.
const gles2 = wayland.gles2;
/// The one definition of a test-server roundtrip, used by the
/// PolicyServer harness below. Reached through the `wayland` module:
/// Zig 0.16 forbids importing a library file into the server module
/// (see the note below), so it comes in as `wayland.utils.test_pump`.
const test_pump = wayland.utils.test_pump;

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

// ---------------------------------------------------------------------------
// Renderer selection
// ---------------------------------------------------------------------------

/// Which renderer composites the canvas (WAYLAND_RENDERER).
///
/// `pixman` is the CPU path every pixel of today's server comes from:
/// it is the DEFAULT and its output is byte-for-byte what this server
/// has always presented. `gles2` composites the same canvas through
/// `renderer/gles2.zig` on the GPU, with the camera uploaded as the
/// renderer's scene -> target affine (`cameraAffine`).
pub const RendererKind = enum { pixman, gles2 };

/// Parse WAYLAND_RENDERER.
///
/// Unset is the normal default and maps to `.pixman` (no warning, the
/// same rule WAYLAND_BACKEND follows). A value this server does not
/// know returns null so the caller can WARN and fall back, rather than
/// silently rendering with something the operator did not ask for.
pub fn parseRendererEnv(value: ?[]const u8) ?RendererKind {
    const v = value orelse return .pixman;
    if (std.mem.eql(u8, v, "pixman")) return .pixman;
    if (std.mem.eql(u8, v, "gles2")) return .gles2;
    return null;
}

/// The renderer's scene -> target affine for `cam`, for CAMERA-RELATIVE
/// world coordinates.
///
/// camera.zig defines
///
///     p_screen = zoom * R(-rotation) * (p_world - center) + (W/2, H/2)
///
/// and the GLES2 shader multiplies every dst rect by `u_transform`. The
/// server hands the shader `p_world - center` (compositeBaseGles2
/// subtracts the camera centre in f64, per surface, BEFORE the f32
/// narrowing), so this matrix is the linear part plus the viewport
/// centre and carries NO world offset. That split is the point of step
/// 5: one f32 cannot represent 1e9 + 0.5, so a matrix carrying the world
/// offset would land a distant surface tens of pixels away, while
/// `p - center` is small and exact.
///
/// `Affine.m` is COLUMN-major (see gles2.Affine), so the linear part
/// stores d x'/d x, d y'/d x, d x'/d y, d y'/d y in that order and the
/// translation in indices 6 and 7. The arithmetic runs in f64 (the
/// camera's own precision) and narrows once, to what the uniform takes.
pub fn cameraAffine(cam: Camera) gles2.Affine {
    const cos_r = @cos(cam.rotation);
    const sin_r = @sin(cam.rotation);
    return .{ .m = .{
        @floatCast(cam.zoom * cos_r),
        @floatCast(-cam.zoom * sin_r),
        0,
        @floatCast(cam.zoom * sin_r),
        @floatCast(cam.zoom * cos_r),
        0,
        @floatCast(cam.screen_w / 2),
        @floatCast(cam.screen_h / 2),
        1,
    } };
}

// ---------------------------------------------------------------------------
// zwp_linux_dmabuf_v1 -> wl_surface.attach
// ---------------------------------------------------------------------------

/// `LinuxDmabuf.fromResource` rewrapped as a Compositor.DmabufResolver.
/// The compositor reaches it through a function pointer instead of
/// naming the type, because shell/linux_dmabuf.zig imports
/// compositor/compositor.zig: a direct field would close a
/// compositor<->shell cycle.
fn resolveDmabufBuffer(ctx: *anyopaque, resource: *wire.Resource) ?*wayland.shm.Buffer {
    const linux: *wayland.linux_dmabuf.LinuxDmabuf = @ptrCast(@alignCast(ctx));
    return linux.fromResource(resource);
}

/// Teach wl_surface.attach to resolve zwp_linux_dmabuf_v1 buffers.
/// Without it every dmabuf attach lands in the shm wrap, which answers
/// error.InvalidBuffer for a buffer it never created and the client dies
/// with "unknown buffer type" (compositor/surface.zig handleAttach, F56).
fn wireDmabufResolver(compositor: *wayland.compositor.Compositor, linux: *wayland.linux_dmabuf.LinuxDmabuf) void {
    compositor.setDmabufResolver(.{
        .ctx = linux,
        .resolve = resolveDmabufBuffer,
    });
}

/// L-D7: EXCLUSIVE layer keyboard grab state (see
/// ServerState.layer_kbd_grab). The `layer` pointer is compared for
/// identity only and never dereferenced: a destroyed surface clears the
/// seat's pointer focus, so the next pointer move releases the grab
/// before the surface could free.
const LayerKbdGrab = struct {
    /// The grabbed layer surface's wl_surface.
    layer: *Surface,
    /// The keyboard focus held before the grab; restored on release.
    previous: ?*Surface,
};

/// L-D7: layer keyboard-interactivity focus decision (spec
/// fix-layer-deco-act.md L7, wlroots keyboard_interactivity model).
/// The layer protocol only stores the value; routing keyboard focus is
/// compositor policy. Per the model:
///   - none (0):      the layer surface never receives keyboard focus;
///   - exclusive (1): receives focus while the pointer is over it and
///                    HOLDS it (a keyboard grab — no other surface can
///                    take focus while the grab is live); on pointer
///                    leave the previous focus is restored;
///   - on_demand (2): receives focus while the pointer is over it; on
///                    leave the focus is free to move (no grab).
/// `grab_active` is whether the exclusive grab is currently live.
pub const LayerFocusAction = enum {
    /// No focus change.
    keep,
    /// Give keyboard focus to the layer surface under the pointer.
    focus_layer,
    /// Release the exclusive grab and restore the pre-grab focus.
    restore_previous,
};

/// The per-pointer-move keyboard focus choice for a layer surface.
pub fn layerFocusDecision(
    pointer_over_layer: bool,
    interactive: u32,
    grab_active: bool,
) LayerFocusAction {
    if (pointer_over_layer) {
        switch (interactive) {
            0 => return if (grab_active) .restore_previous else .keep, // none: never
            1, 2 => return .focus_layer, // exclusive / on_demand: focus while over
            else => return .keep, // unknown value: keep the current focus
        }
    }
    // Pointer not over the layer: an active grab ends here.
    return if (grab_active) .restore_previous else .keep;
}

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
/// The opaque fill a locked session shows where no lock surface covers
/// the output. ext_session_lock_v1:74-91 requires "an opaque color such
/// that their normal content is fully hidden"; black is the choice sway
/// makes, and an alpha of 1 is what makes it opaque (the framebuffer is
/// premultiplied ARGB8888, so a translucent fill would let the previous
/// canvas's memory show through).
const lock_blank_color = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
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
    /// wp_fractional_scale_manager_v1 (the preferred fractional scale).
    fractional_scale: *wayland.fractional_scale.FractionalScale,
    /// wp_viewporter (crop/scale surface content).
    viewporter: *wayland.viewporter.Viewporter,
    /// zwp_pointer_gestures_v1 (shell/pointer_gestures.zig): swipe,
    /// pinch and hold recognition fed from the seat's pointer stream.
    /// Owns its seat listeners; the module is the wiring (main only
    /// hands it the seat).
    pointer_gestures: ?*wayland.pointer_gestures.PointerGestures = null,
    /// zwp_relative_pointer_manager_v1 (shell/relative_pointer.zig):
    /// unclaccelerated relative motion.
    relative_pointer: ?*wayland.relative_pointer.RelativePointer = null,
    /// zwp_pointer_constraints_v1 (shell/pointer_constraints.zig):
    /// locked and confined pointers.
    pointer_constraints: ?*wayland.pointer_constraints.PointerConstraints = null,
    /// zwp_tablet_manager_v2 (shell/tablet.zig): the tablet/tool/pad
    /// hardware registry. No tablet input backend exists yet, so no
    /// hardware is registered and the global announces nothing beyond
    /// the per-client zwp_tablet_seat_v2 (the module's documented
    /// "correct with no hardware" state).
    tablet: ?*wayland.tablet.Tablet = null,
    /// wp_cursor_shape_manager_v1 (shell/cursor_shape.zig): per-device
    /// cursor shapes, gated on the enter serial this server records in
    /// syncCursorShapeSerials. Needs the tablet module: a tablet-tool
    /// device resolves its serial there.
    cursor_shape: ?*wayland.cursor_shape.CursorShape = null,
    /// wp_tearing_control_manager_v1 (shell/tearing_control.zig): the
    /// per-surface async-presentation hint the present path consults in
    /// consultTearingHints.
    tearing_control: ?*wayland.tearing_control.TearingControl = null,
    /// ext_session_lock_manager_v1 (shell/session_lock.zig): the
    /// privilege boundary. Read on every input gate (isLocked) and on
    /// every render decision (lockedFrameFor).
    session_lock: ?*wayland.session_lock.SessionLock = null,
    /// zwlr_data_control_manager_v1 (compositor/data_control.zig): the
    /// compositor as data SOURCE — a client reads the seat selection
    /// without holding keyboard focus.
    data_control: ?*wayland.data_control.DataControlManager = null,
    /// zwlr_foreign_toplevel_manager_v1 (shell/foreign_toplevel.zig):
    /// our own xdg toplevels as client-visible handles.
    foreign_toplevel: ?*wayland.foreign_toplevel.ForeignToplevelManager = null,
    /// zwp_linux_dmabuf_v1 (shell/linux_dmabuf.zig): DMA-BUF buffer
    /// import. Registered ONLY when a GBM device exists (the DRM
    /// backend's); null on every backend without one, which is also the
    /// documented "no global" state of the module.
    linux_dmabuf: ?*wayland.linux_dmabuf.LinuxDmabuf = null,
    /// The renderer the surface textures are imported through and the
    /// canvas is composited with (WAYLAND_RENDERER; see RendererKind).
    renderer: *wayland.renderer.Renderer,
    /// The pixman renderer compositor/cursor.zig is handed: its draw
    /// path takes a `*pixman.Framebuffer` and its textures are imported
    /// through `PixmanRenderer.importMemory` whatever `renderer` is
    /// (cursor.zig:260, :337), so a pixman renderer always exists and
    /// is always the one the cursor uses. Identical to `renderer` when
    /// pixman is selected.
    pixman_renderer: *wayland.renderer.Renderer,
    /// Which renderer `compositeBase` composites with.
    renderer_kind: RendererKind = .pixman,
    backend: *wayland.backend.Backend,
    /// Raw WAYLAND_CAMERA value, borrowed from the process environ
    /// (parsed per view, with that view's own output size).
    camera_env: ?[]const u8,
    /// M2 scene graph: ONE scene shared by every output view. The views
    /// are the per-output `OutputView`s below; the scene is their common
    /// world (scene space = the desktop layout), never per output.
    scene: ?*wayland.scene.Scene = null,
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
    /// The desktop extent absolute input devices are normalized onto, as
    /// last published to `input_backend` (syncInputExtent). The record
    /// is what keeps the setter off the per-frame path: a layout that
    /// has not changed shape publishes nothing.
    input_extent_w: u32 = 0,
    input_extent_h: u32 = 0,
    /// The DRM backend's poll fd watcher state (page-flip events).
    drm_poll_fd: c_int = -1,
    /// The optional fds the loop was actually asked to watch, each -1
    /// when the feature behind it is absent. They exist because an
    /// absent feature must arm NOTHING (armFdPoll's rule): a poller on a
    /// -1 fd completes instantly and forever, which is a busy-spin. So
    /// the armed set is the record the tests read and the state keeps.
    /// The udev hotplug monitor beside the libinput device fd.
    input_hotplug_poll_fd: c_int = -1,
    /// The logind bus (M6 PrepareForSleep), DRM backend only.
    drm_session_poll_fd: c_int = -1,
    /// The DRM connector hotplug (udev) monitor, DRM backend only.
    drm_hotplug_poll_fd: c_int = -1,
    /// The DRM backend (when WAYLAND_BACKEND=drm).
    drm_backend: ?*wayland.backend.Backend = null,
    /// GPU DRM scanout is live: the renderer was created on the backend's
    /// GBM device and the backend accepted the renderer's renderable
    /// format pairs BEFORE start(). Only then do per-view leased-slot
    /// targets exist and the canvas is drawn straight into the scanout
    /// buffer instead of being read back for a CPU front.
    gpu_scanout: bool = false,
    // SAFETY: initialized in main() before the backend starts.
    new_input_listener: wire.Listener(*wayland.backend.Backend.InputDevice),
    /// Backend.events.input_removed: a device the new_input signal
    /// announced is gone. Subscribed beside new_input_listener in
    /// subscribe(); the handler forwards it to the seat so the wl_seat
    /// capability the LAST device of that kind provided is withdrawn.
    input_removed_listener: wire.Listener(*wayland.backend.Backend.InputDevice),
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
    /// Toplevels created by clients (tracked for observability).
    toplevels: std.ArrayList(*wayland.shell.XdgToplevel) = .empty,
    /// Layer surfaces created by clients (tracked for observability).
    layer_surfaces: std.ArrayList(*wayland.layer_shell.LayerSurface) = .empty,
    /// xdg_popups parented to layer surfaces via get_popup (tracked for
    /// observability; L1).
    layer_popups: std.ArrayList(*wayland.shell.XdgPopup) = .empty,
    /// L-D7: the live EXCLUSIVE layer keyboard grab (see
    /// applyLayerKeyboardFocus). While the pointer is over an
    /// exclusive-interactivity layer surface, the seat's keyboard focus
    /// is grabbed by it and the pre-grab focus is restored when the
    /// pointer leaves. Null while no grab is active.
    layer_kbd_grab: ?LayerKbdGrab = null,
    /// EVERY output the backend has announced, as a stable heap view each.
    /// There is no single "the output" any more: each view owns its
    /// camera, render and capture targets, damage ring, pacing, frame
    /// listeners and idle state, and the list IS the desktop layout.
    output_views: std.ArrayList(*OutputView) = .empty,
    /// Where each tracked surface's node lives: the view it was placed
    /// on and whether its node position has been written yet. Scene
    /// space is the desktop, so a view owns the region `view.rect`
    /// and a surface placed there belongs to it. Removed views drop
    /// their surfaces here so the next sync re-places them.
    surface_place: std.AutoHashMapUnmanaged(*Surface, SurfacePlace) = .{},
    /// What the tree-order draw walk needs per scene node: the tracked
    /// surface behind it (buffer node AND container) and the space it is
    /// composited in. The scene's own table is keyed the other way round;
    /// this index is rebuilt per frame (indexCanvasNodes) and retained, so
    /// a steady-state frame allocates nothing and classifies each surface
    /// exactly once instead of once per node per output.
    canvas_index: std.AutoHashMapUnmanaged(*wayland.scene.SceneNode, CanvasNode) = .{},
    /// Stop after this many frames; 0 = run until watchdog/error.
    run_frames: u32 = 0,
    watchdog_fired: bool = false,
    /// WAYLAND_SYNTH_INPUT=1: synthesize one pointer click + key press
    /// per newly-mapped surface (headless input E2E). The first client
    /// gets the original click+key; every later surface (a second
    /// client, a popup) gets the same treatment so multi-client sessions
    /// (selection roundtrips) also see focus + a serial. Tracked by
    /// surface identity so re-maps of the same surface do not re-click.
    synth_input: bool = false,
    synth_clicked: std.AutoHashMapUnmanaged(*Surface, void) = .{},
    /// WAYLAND_SYNTH_INPUT=2: mode 1's one click + key press + wheel
    /// notch, PLUS one real pointer motion after every DISTINCT committed
    /// content/state change on any tracked surface. The transform-parity
    /// acceptance needs a FRESH pointer per case: it asserts the
    /// surface-local coordinate it is handed lies inside the box the
    /// CURRENT transform/scale/viewport implies, and one motion for the
    /// whole run proves nothing about the cases after the first.
    ///
    /// Not per commit: a client's own verifyZoom round re-commits the same
    /// surface with identical state, and a motion per commit turns the
    /// server's own input into a self-triggered commit/motion loop. Not
    /// per render either: a frame is not a state change.
    synth_pointer_moves: bool = false,
    /// The committed state each surface was last pointed at, so a motion
    /// goes out exactly once per distinct change. A commit that only
    /// advances a frame callback leaves the snapshot identical.
    synth_pointed: std.AutoHashMapUnmanaged(*Surface, SynthSurfaceState) = .{},
    /// The one surface mode 2 points at for the whole run (see
    /// synthPointerMotion). Null until the first eligible one appears, and
    /// cleared when that surface leaves the scene.
    synth_target: ?*Surface = null,
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
    /// The compositor's own pointer gestures (the interactive move and
    /// the camera pan). Grouped because they are installed and torn
    /// down as ONE seat pointer grab and the left-button release ends
    /// both — see PointerGestures.
    gestures: PointerGestures = .{},
    /// The cursor's texture imported into the SELECTED renderer, for the
    /// GPU passes that draw the cursor as a texture instead of through
    /// Cursor.draw. Keyed on the CPU texture it was uploaded from, so a
    /// cursor change re-uploads once and every frame after that reuses
    /// the same GL texture: no per-frame copy, no per-frame alloc.
    cursor_gl: ?*Texture = null,
    cursor_gl_source: ?*Texture = null,
    /// WAYLAND_PERF=1: log per-frame pipeline timings (import -> render
    /// -> present) in microseconds.
    perf: bool = false,
    /// ext_session_lock_v1 `locked`: the privilege boundary closed. The
    /// handler runs inside the lock surface's commit dispatch, BEFORE
    /// renderFrame can composite, which is what makes the next frame the
    /// first locked frame (shell/session_lock.zig wiring item 1).
    session_locked_listener: wire.Listener(*wayland.session_lock.SessionLock),
    /// ext_session_lock_v1 unlock: the gates come off and the normal
    /// focus policy resumes.
    session_unlocked_listener: wire.Listener(*wayland.session_lock.SessionLock),
    /// A lock surface was fully configured: track its wl_surface in the
    /// scene and position it over its output.
    new_lock_surface_listener: wire.Listener(*wayland.session_lock.LockSurface),
    /// A lock surface stopped covering its output: drop its scene node so
    /// an unlocked session cannot composite the stale lock screen.
    lock_surface_gone_listener: wire.Listener(*wayland.session_lock.LockSurface),
    /// wp_cursor_shape_device_v1.set_shape was accepted. This compositor
    /// draws one cursor image for every shape (shell/cursor_shape.zig),
    /// so the only reaction is the record in the log.
    cursor_shape_changed_listener: wire.Listener(*wayland.cursor_shape.ShapeChange),
    /// The wl_surface the pointer was last sent an enter for, for
    /// syncCursorShapeSerials. Compared by identity only; null means
    /// "no serial is recorded" — never dereferenced.
    cursor_shape_focus: ?*Surface = null,
    /// The number of wl_pointer resources syncCursorShapeSerials has
    /// already visited. A client may bind more wl_pointers after an
    /// enter, and a resource that never saw the enter has no serial;
    /// watching the count re-scans when the set changes.
    cursor_shape_pointers: usize = 0,
    /// Whether the cursor is hidden while a session is locked
    /// (shell/session_lock.zig wiring item 2). The cursor nodes are
    /// re-enabled by Cursor.update on every frame, so the server hides
    /// the cursor by never painting it (compositeCanvas draws it).
    cursor_hidden: bool = false,

    new_output_listener: wire.Listener(*wayland.output.Output),
    /// A surface committed new content (scene.events.content_dirty):
    /// schedule a render so the update actually composites (note 137 F1).
    content_dirty_listener: wire.Listener(*wayland.scene.Scene),
    new_toplevel_listener: wire.Listener(*wayland.shell.XdgToplevel),
    new_popup_listener: wire.Listener(*wayland.shell.XdgPopup),
    new_activation_token_listener: wire.Listener(*wayland.xdg_activation.ActivationToken),
    new_layer_surface_listener: wire.Listener(*wayland.layer_shell.LayerSurface),
    new_layer_popup_listener: wire.Listener(*wayland.shell.XdgPopup),
    request_activate_listener: wire.Listener(*wayland.xdg_activation.ActivateRequest),
    request_mode_listener: wire.Listener(*wayland.xdg_decoration.RequestMode),
    new_decoration_listener: wire.Listener(*wayland.xdg_decoration.Decoration),
    /// wl_toplevel.activated follows the seat's keyboard focus (P1-9).
    seat_focus_listener: wire.Listener(*wayland.seat.Seat),
    seat_key_listener: wire.Listener(*wayland.seat.Seat),
    /// M4 Phase B camera controls: seat listeners for the drag-pan
    /// (button + pointer_move signals) and the wheel-zoom (axis signal).
    seat_button_listener: wire.Listener(*wayland.seat.Seat),
    seat_pointer_move_listener: wire.Listener(*wayland.seat.Seat),
    seat_axis_listener: wire.Listener(*wayland.seat.Seat),
};

/// Where a tracked surface's scene node lives: the view it was placed on
/// and whether its node position has been written yet.
const SurfacePlace = struct {
    view: *OutputView,
    /// False until the node exists and its position has been written to
    /// the view's desktop origin. SurfaceNode creates the node on the
    /// first map, which is after any placement sync that ran before it.
    placed: bool = false,
};

/// ONE output's whole compositor-side state: the view a client sees and
/// the view the renderer draws. Every field the old ServerState carried
/// for "the output" lives here instead, per view, so a second output is
/// a second instance of this struct rather than a clobbered singleton
/// (`self.output = out` used to overwrite the first connector outright).
///
/// The view owns, for its output:
///   - `camera`, parsed from WAYLAND_CAMERA at that output's real size
///     and moved only by the gestures pinned to this view;
///   - `scene_output`, the library's per-output view of the ONE shared
///     scene, carrying this view's camera and wl_output so output
///     membership and enter/leave name the real output;
///   - the CPU scanout framebuffer, the persisted base (canvas without
///     the cursor) and, under WAYLAND_RENDERER=gles2, the FBO the canvas
///     is rasterized into before it is read back for scanout;
///   - on a GPU DRM scanout, the cached `Gles2Target` per leased slot and
///     the frame currently leased from the backend;
///   - the capture target/framebuffers a zwlr_screencopy_v1 read of THIS
///     output needs, filled by an explicit read-back and nothing else;
///   - its own damage ring (in the scene output), frame pacing
///     (`frame_pending` lives on the Output), idle state, and frame and
///     destroy listeners.
const OutputView = struct {
    /// The owning server state (log config, renderer, allocator).
    state: *ServerState,
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    /// The backend output this view renders.
    output: *wayland.output.Output,
    /// wl_output for this output, created with the view and destroyed by
    /// the output's destroy signal.
    wl_output: *wayland.wl_output.WlOutput,
    /// The library's per-output scene view. `camera` points at this
    /// view's camera and `wl_output` at this view's wl_output.
    scene_output: *wayland.scene.SceneOutput,
    /// This view's region of the desktop, in global pixels: the layout
    /// every global pointer/touch/tablet coordinate is routed through.
    rect: geom.Rect,
    /// World -> screen for this output, in scene space. Parsed from
    /// WAYLAND_CAMERA at this output's real size; the default centres
    /// this view's own origin, so worldToScreen is the identity mapping
    /// — today's no-camera composite.
    camera: Camera,
    /// The camera at the last render: a change of centre, zoom OR
    /// rotation moves every pixel, so the whole output is damaged
    /// (a partial upload would smear the previous canvas).
    last_camera: Camera,
    /// The CPU scanout buffer this view's backends read, the cursor
    /// draws into and a screencopy with overlay_cursor=1 reads.
    framebuffer: *pixman.Framebuffer,
    /// The canvas WITHOUT the cursor, persisted so a hover cursor move
    /// restores a region from it instead of recompositing the whole
    /// canvas. Lazily created at this view's size.
    base_framebuffer: ?*pixman.Framebuffer = null,
    /// The GLES2 FBO the canvas is rasterized into on the CPU-scanout
    /// path (null unless `renderer_kind` is `.gles2`): created at this
    /// view's size on first use, re-created after a mode change.
    gles2_target: ?*gles2.Gles2Target = null,
    /// This view's canvas item list, RETAINED across frames: the pass
    /// clears it and refills it, so a steady-state frame allocates
    /// nothing. Per view, because the item list is filtered by the view
    /// a surface was placed on and two outputs never share it. Freed with
    /// the view.
    items: std.ArrayList(CanvasItem) = .empty,
    /// A GPU DRM scanout: the renderer's EGL display was created on the
    /// backend's GBM device, the backend was told the renderer's real
    /// renderable format pairs before start, and the canvas is drawn
    /// straight into the leased frame's target. No read-back, no CPU
    /// front buffer, no framebuffer copy on this path.
    gpu: bool = false,
    /// The EGL image FBO per leased slot, cached by slot index so a
    /// slot's native image is imported once and then reused for the life
    /// of the buffer behind it.
    gpu_targets: [2]?*gles2.Gles2Target = .{ null, null },
    /// The frame leased from the backend for the frame being composited.
    /// Set only between acquireGpuFrame and the commit (which consumes
    /// it); a failed commit cancels it and clears this.
    gpu_lease: ?*wayland.gpu_frame.GpuFrame = null,
    /// The explicit screencopy path: an offscreen FBO this view renders
    /// into only when a client captures it, and the CPU buffers the read
    /// lands in. `capture_base` is the overlay_cursor=0 image (no
    /// cursor); `capture_frame` the overlay_cursor=1 one.
    capture_target: ?*gles2.Gles2Target = null,
    capture_base: ?*pixman.Framebuffer = null,
    capture_frame: ?*pixman.Framebuffer = null,
    /// Whether each capture buffer already shows this view's CURRENT
    /// canvas. Cleared by every composite so the next capture re-reads.
    capture_base_valid: bool = false,
    capture_frame_valid: bool = false,
    /// Frames this view has presented. Per view, because pacing and the
    /// WAYLAND_RUN_FRAMES budget are per output.
    frames_rendered: u32 = 0,
    /// Idle-frame skip state, per view (the ServerState-level one would
    /// make one output's activity repaint the other).
    repaint_pending: bool = true,
    /// True while this view's renderFrame is on the stack. A
    /// requestRender from inside the frame (the synth input's pointer
    /// motion, a camera or seat event) must not emit another frame
    /// signal, or the emit re-enters renderFrame until the frame-event
    /// emit faults.
    in_render: bool = false,
    /// Hover cursor move in progress: skip the full composite and
    /// restore the old cursor region from the base instead.
    cursor_repaint: bool = false,
    /// A client is waiting for its next frame callback but this view's
    /// canvas is unchanged: present the unchanged frame so the callback
    /// fires (see the ServerState field of the same name).
    frame_kick: bool = false,
    /// Output.events.frame: this view's render entry point.
    frame_listener: wire.Listener(*wayland.output.Output),
    /// Output.events.commit: a state was applied to this output, which is
    /// where a MODE change shows up. It fires on every present, so the
    /// handler is a two-field compare that returns immediately while the
    /// mode still matches this view's slice of the desktop.
    commit_listener: wire.Listener(*wayland.output.Output.CommitEvent),
    /// Output.events.destroy: the backend took the output away (unplug,
    /// modeset, teardown). Frees every target this view owns and drops
    /// it from the layout, leaving every other view's cameras and
    /// targets untouched.
    destroy_listener: wire.Listener(*wayland.output.Output),

    /// This view's local scanout rect: (0,0) to the mode size. Output
    /// damage and capture coordinates are in THIS space, never the
    /// desktop's.
    fn localRect(view: *const OutputView) geom.Rect {
        return .{ .x = 0, .y = 0, .width = view.output.mode.width, .height = view.output.mode.height };
    }

    /// The camera change that invalidates the whole output. Centre, zoom
    /// AND rotation all move every pixel, so all three are compared: a
    /// rotated camera whose centre did not move still shows a different
    /// canvas, and damaging only the moved surfaces would leave the old
    /// rotation under the cursor.
    fn cameraChanged(view: *const OutputView) bool {
        return view.last_camera.center_x != view.camera.center_x or
            view.last_camera.center_y != view.camera.center_y or
            view.last_camera.zoom != view.camera.zoom or
            view.last_camera.rotation != view.camera.rotation;
    }

    /// Free every render and capture target this view owns. GL objects
    /// first (they need the renderer's EGL context, still current), and
    /// the lease cancelled BEFORE the backend's slots go away.
    fn freeTargets(view: *OutputView) void {
        if (view.gpu_lease) |frame| {
            if (view.state.drm_backend) |b| drm_mod.DrmBackend.cancelGpuFrame(b, view.output, frame);
            view.gpu_lease = null;
        }
        for (&view.gpu_targets) |*slot| {
            if (slot.*) |t| t.destroy();
            slot.* = null;
        }
        if (view.capture_target) |t| {
            t.destroy();
            view.capture_target = null;
        }
        if (view.gles2_target) |t| {
            t.destroy();
            view.gles2_target = null;
        }
        if (view.capture_base) |f| {
            f.deinit();
            view.capture_base = null;
        }
        if (view.capture_frame) |f| {
            f.deinit();
            view.capture_frame = null;
        }
        if (view.base_framebuffer) |f| {
            f.deinit();
            view.base_framebuffer = null;
        }
        view.items.deinit(view.allocator);
        view.capture_base_valid = false;
        view.capture_frame_valid = false;
        view.framebuffer.deinit();
    }
};

/// M4 Phase B: the drag-pan gesture anchor — the pointer position while
/// the left button is held.
const DragPoint = struct { x: i32, y: i32 };

/// The compositor's own pointer gestures: the interactive move
/// (xdg_toplevel.move — the client's titlebar drag) and the camera pan.
/// Both own ONE seat pointer grab — seat.swallow_pointer_grab, whose
/// suppress_click_focus is what keeps the client under the pointer from
/// seeing the gesture at all (seat.zig:206-218) — and the left-button
/// release ends both, so their state lives together.
///
/// `own_grab` is the grab THIS server installed, and the release may end
/// the seat grab only while the seat still carries it. Another subsystem
/// can own the seat instead (a wl_data_device.start_drag drag grab, an
/// xdg_popup.grab), and ending THAT one from a left release cancelled the
/// drag (the target got leave with no drop) or dismissed the popup
/// (P1-3). Identity is the ownership check Drag.end and popupGrabEnd
/// already make (data_device.zig:399, xdg.zig:1640).
const PointerGestures = struct {
    /// The toplevel being moved, null when idle. The move owns the
    /// pointer grab until the button release (the client sees no pointer
    /// events during the move).
    moving_toplevel: ?*wayland.shell.XdgToplevel = null,
    /// The view both gestures are PINNED to: the one that held the
    /// pointer when the gesture armed. The camera pan moves that view's
    /// camera and the interactive move converts the pointer delta
    /// through it, so a drag over the second output pans the second
    /// output's camera and leaves every other view's camera alone.
    /// Cleared with the rest of the gesture state.
    view: ?*OutputView = null,
    /// The pointer's WORLD position at the last move tick; the node
    /// moves by the delta between ticks.
    move_anchor: geom.FPoint = .{ .x = 0, .y = 0 },
    /// The last pointer position while the left button is held (the pan
    /// anchor); null when not dragging. A click without motion never
    /// produces a delta, so the seat's click-to-focus is unchanged.
    camera_drag: ?DragPoint = null,
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
    /// The pointer grab this compositor installed, or null when none of
    /// its gestures is live.
    own_grab: ?*const wayland.seat.PointerGrab = null,
};

/// Take the seat pointer for a compositor gesture (the interactive move
/// or the camera pan) and record the grab, so the teardown can tell
/// "ours" from "somebody else's" (PointerGestures.own_grab).
fn grabPointerForGesture(seat: *wayland.seat.Seat, g: *PointerGestures) void {
    seat.startPointerGrab(&wayland.seat.swallow_pointer_grab);
    g.own_grab = &wayland.seat.swallow_pointer_grab;
}

/// End every compositor gesture: clear the gesture state unconditionally
/// (the gesture is over whether or not the seat still carries our grab),
/// then end the seat grab only when it is OURS. Returns true when the
/// seat really carried our grab and it is now released, false when
/// another subsystem's grab is installed — that one survives.
fn endPointerGestures(seat: *wayland.seat.Seat, g: *PointerGestures) bool {
    g.moving_toplevel = null;
    g.camera_drag = null;
    // A pan that is no longer armed is not dragging, whatever it was a
    // moment ago. Leaving `drag_active` set is what made the first motion
    // after a session latch keep panning with no button held, and kept
    // the fast-render blockiness latched to a canvas nobody is dragging.
    g.drag_active = false;
    g.view = null;
    g.fast_render = false;
    const ours = g.own_grab orelse return false;
    g.own_grab = null;
    if (seat.pointer_grab != ours) return false;
    seat.endPointerGrab();
    return true;
}

/// Release every pointer button a client believes it is holding, to the
/// client that RECEIVED the press (Seat.held_clients), then clear the
/// set. This is the flush Seat.startPointerGrab runs when it installs a
/// grab, and it exists for the same reason there: a client's own gesture
/// state must not extend into the compositor's gesture (wlroots resets
/// the seat buttons when the grab focus changes,
/// wlr_seat_pointer.c:435-437).
///
/// The session latch needs that flush with NO grab around it.
/// ext_session_lock_v1:81-84 makes the lock client the only input
/// destination, so from the latch on no release can reach the client
/// that took the press: the seat routes a physical release by its
/// cached pointer_focus, and the latch's own pointerMotion has either
/// cleared that focus (the lock-aware pick drops user content) or moved
/// it onto the lock surface — where the release would land on a client
/// that never saw a press. Either way the pressed client keeps a button
/// it can never release, and Seat.held_button_count stays non-zero, so
/// the NEXT grab start invents a release for a button that is already
/// up.
///
/// The loop is the one inside startPointerGrab (seat.zig:1044-1060),
/// kept here because the seat exposes no entry point that flushes the
/// held buttons without also installing a grab. Its seat-side home is a
/// `resetHeldButtons` factored out of startPointerGrab and called from
/// here; until that exists this is the one place that flushes without
/// a grab, and it must stay the same loop.
fn flushHeldPointerButtons(seat: *wayland.seat.Seat) void {
    const count = seat.held_button_count;
    if (count == 0) return;
    const time = seat.nowMs();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const button = seat.held_buttons[i];
        const held_client = seat.held_clients[i];
        // A FRESH per-client serial, exactly as a grab start mints it:
        // this is a new input event, not the press coming back.
        const serial = seat.serialFor(held_client);
        var delivered = false;
        for (seat.pointers.items) |ptr| {
            if (ptr.getClient() != held_client) continue;
            ptr.sendButton(serial, time, button, .released);
            delivered = true;
        }
        if (delivered) seat.markFramePending(held_client);
    }
    // The buttons are logically released whether or not a client got the
    // release, so a later physical release cannot strand the set.
    seat.held_button_count = 0;
}

// ---------------------------------------------------------------------------
// Startup phases
// ---------------------------------------------------------------------------
//
// main() is the phase sequence and nothing else. Every `defer` stays in
// main's own scope because Zig runs them LIFO, and THAT ORDER IS THE
// TEARDOWN CONTRACT: wl_shm outlives the compositor, every seat-attached
// module dies before the seat, the clients die before any module their
// destroy handlers call into, and the dmabuf resolver is cleared before
// the module it points at dies. Each defer below says which of those it
// is. The phase functions only build and hand back what main registers.

/// What every wiring phase takes: the allocator, the runtime io, the log
/// config and the process environment. A WAYLAND_* knob is read by the
/// phase that applies it, so no knob is read twice and none is read by a
/// phase that does not use it.
const Startup = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    env: *std.process.Environ.Map,
};

/// The display, wl_shm, the compositor, the shell and everything built
/// on top of them, in buildCore's construction order.
const CoreModules = struct {
    display: *wayland.core.display.CompositorDisplay,
    presentation: *wayland.presentation.Presentation,
    shm_state: *wayland.shm.ShmState,
    compositor: *wayland.compositor.Compositor,
    shell: *wayland.shell.XdgShell,
    layer_shell: *wayland.layer_shell.LayerShell,
    seat: *wayland.seat.Seat,
    xdg_activation: *wayland.xdg_activation.XdgActivation,
    xdg_decoration: *wayland.xdg_decoration.XdgDecoration,
    fractional_scale: *wayland.fractional_scale.FractionalScale,
    xdg_output: *wayland.xdg_output.XdgOutput,
    viewporter: *wayland.viewporter.Viewporter,
    subcompositor: *wayland.subsurface.Subcompositor,
    data_device: *wayland.data_device.DataDeviceManager,
    primary_selection: *wayland.primary_selection.PrimarySelection,

    /// Destroy in the exact reverse of buildCore's construction order —
    /// the sequence main's per-module `defer`s used to produce. The
    /// display dies last (every global is removed into it), wl_shm dies
    /// just before it so the compositor's surfaces can still unmap, and
    /// the seat dies before every module attached to it.
    fn deinit(self: *const CoreModules) void {
        self.primary_selection.deinit();
        self.data_device.deinit();
        self.subcompositor.deinit();
        self.viewporter.deinit();
        self.xdg_output.deinit();
        self.fractional_scale.deinit();
        self.xdg_decoration.deinit();
        self.xdg_activation.deinit();
        self.seat.deinit();
        self.layer_shell.deinit();
        self.shell.deinit();
        self.compositor.deinit();
        self.shm_state.deinit();
        self.presentation.deinit();
        self.display.deinit();
    }
};

/// The nine modules constructed AFTER the seat, so their teardown (which
/// runs first) can never reach a freed seat.
const SeatModules = struct {
    pointer_gestures: *wayland.pointer_gestures.PointerGestures,
    relative_pointer: *wayland.relative_pointer.RelativePointer,
    pointer_constraints: *wayland.pointer_constraints.PointerConstraints,
    tablet: *wayland.tablet.Tablet,
    cursor_shape: *wayland.cursor_shape.CursorShape,
    tearing_control: *wayland.tearing_control.TearingControl,
    session_lock: *wayland.session_lock.SessionLock,
    data_control: *wayland.data_control.DataControlManager,
    foreign_toplevel: *wayland.foreign_toplevel.ForeignToplevelManager,

    /// Reverse construction order: the modules built last (which
    /// subscribe to the earlier ones' signals) are destroyed first.
    fn deinit(self: *const SeatModules) void {
        self.foreign_toplevel.deinit();
        self.data_control.deinit();
        self.session_lock.deinit();
        self.tearing_control.deinit();
        self.cursor_shape.deinit();
        self.tablet.deinit();
        self.pointer_constraints.deinit();
        self.relative_pointer.deinit();
        self.pointer_gestures.deinit();
    }
};

/// Which backend the selection picked, plus the flags the later phases
/// branch on: the dmabuf module needs the DRM backend's GBM device, the
/// loop arms the DRM page-flip poller only for DRM, and the raylib input
/// source only for the raylib window.
const BackendChoice = struct {
    backend: *wayland.backend.Backend,
    is_raylib: bool = false,
    is_drm: bool = false,
    is_nested: bool = false,
};

/// The renderer, the backend and zwp_linux_dmabuf_v1. `pixman_renderer`
/// is the renderer's cursor-side twin (see ServerState.pixman_renderer);
/// in the default configuration it IS `renderer`.
const OutputModules = struct {
    renderer_kind: RendererKind,
    renderer: *wayland.renderer.Renderer,
    pixman_renderer: *wayland.renderer.Renderer,
    backend: *wayland.backend.Backend,
    is_raylib: bool,
    is_drm: bool,
    is_nested: bool,
    linux_dmabuf: *wayland.linux_dmabuf.LinuxDmabuf,
    /// The DRM backend's GBM device, opened by prepareGpu before the
    /// backend started and reused for the renderer that draws into the
    /// GPU scanout buffers. Null on every other backend.
    gpu_device: ?*wayland.dmabuf.GbmDevice = null,
    /// The renderable (format, modifier) pairs the renderer really
    /// supports, BORROWED from it (they live as long as it does) and
    /// handed to the backend before start, so output creation intersects
    /// them with the plane's real capabilities.
    gpu_formats: []const wayland.dmabuf.Format = &.{},
    /// Whether GPU DRM scanout is live: a DRM backend with a prepared
    /// device, a GLES2 renderer created ON that device, and format pairs
    /// accepted. Only then do the per-view leased-slot targets exist.
    gpu_scanout: bool = false,

    /// The reverse of buildOutput's construction order, and still
    /// load-bearing: the dmabuf resolver is cleared BEFORE the module
    /// dies (no wl_surface.attach can then call into a freed module);
    /// the module dies before the backend (its GBM device belongs to the
    /// DRM backend); the backend dies before the renderer; the pixman
    /// renderer dies last.
    ///
    /// Everything that can still be HOLDING a dmabuf Buffer import or a
    /// GBM handle must already be gone by the time this runs: the GL
    /// renderer textures (one per tracked surface node), the cached
    /// per-slot EGL targets and the screencopy destination buffers.
    /// main()'s defers give exactly that — freeStateResources (which
    /// destroys the scene, and with it every surface texture, and frees
    /// the per-view targets through freeOutputViews) is registered
    /// AFTER this defer, so it unwinds FIRST. This method is the last
    /// thing to touch the backend and the device.
    fn deinit(self: *const OutputModules, compositor: *wayland.compositor.Compositor) void {
        compositor.clearDmabufResolver();
        self.linux_dmabuf.deinit();
        self.backend.destroy();
        if (self.renderer != self.pixman_renderer) self.renderer.destroy();
        self.pixman_renderer.destroy();
    }
};

/// The zio timers and fd pollers. They live in MAIN's scope because the
/// ServerState keeps pointers into them; armEventLoop only writes them
/// and adds them to the loop.
const LoopTimers = struct {
    /// One-shot watchdog, re-armed on every render.
    watchdog: zio.ev.Timer,
    /// Repeating xdg_wm_base ping (F3).
    ping: zio.ev.Timer,
    /// Server-side key repeat (seat key_repeat_delay/rate).
    repeat: zio.ev.Timer,
    /// raylib window input poll (~60 Hz); only armed for the raylib
    /// backend, so it is written and read only in that branch.
    raylib_poll: zio.ev.Timer,
    /// The display fd (client requests + wire timers).
    display_poll: zio.ev.PipePoll,
    /// The libinput udev/evdev fd, when WAYLAND_LIBINPUT=1.
    input_poll: zio.ev.PipePoll,
    /// The DRM card fd (page-flip events), for the DRM backend.
    drm_poll: zio.ev.PipePoll,
    /// The libinput udev hotplug monitor (device add/remove), when
    /// WAYLAND_LIBINPUT=1 AND the monitor exists.
    input_hotplug_poll: zio.ev.PipePoll,
    /// The logind bus (M6 PrepareForSleep), DRM backend only.
    drm_session_poll: zio.ev.PipePoll,
    /// The DRM connector udev monitor, DRM backend only.
    drm_hotplug_poll: zio.ev.PipePoll,
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

    log.info("m1 test server starting (zio runtime)", io, &log_cfg, "server", .{});

    var start: Startup = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = &log_cfg,
        .env = init.environ_map,
    };

    const core = try buildCore(&start);
    defer core.deinit();

    try announceSocket(&start, core.display);

    const seat_mods = try buildSeatModules(&start, &core);
    defer seat_mods.deinit();

    const output = try buildOutput(&start, &core);
    defer output.deinit(core.compositor);

    const input_backend = try buildInputBackend(&start, core.seat, seat_mods.tablet);
    defer if (input_backend) |ib| ib.destroy();

    var state = try initServerState(&start, &core, &seat_mods, &output);
    // freeStateResources frees the clients, the cursor, every OutputView
    // (with its render, capture and GPU-slot targets and any open GPU
    // lease) and the one shared scene. It is registered HERE, after
    // output.deinit above, so it unwinds FIRST — every GL texture
    // holding a dmabuf Buffer import, and every EGL image behind a
    // cached scanout target, is released while the renderer, the GBM
    // device and the dmabuf module are still alive.
    defer freeStateResources(&state);
    state.input_backend = input_backend;
    subscribe(&state);
    // The foreign-toplevel focus gate names `state` as its context, and
    // the defer below tears down the fields that context reads before the
    // module holding it dies — so the gate comes off first, exactly as
    // subscribe installs it.
    defer if (state.foreign_toplevel) |ft| ft.setFocusGate(&state, null);
    // Unlink before the module deinits run: their teardown emits
    // lock_surface_gone, and these handlers dereference `state`, whose
    // own teardown defer was registered earlier and has already run.
    defer unlinkSessionLockListeners(&state);
    try initScreencopy(&start, &state, &core);
    defer if (state.screencopy) |sc| sc.deinit();
    // The dmabuf half of zwlr_screencopy_v1 (screencopy.zig's wiring
    // snippet). Registered AFTER the screencopy deinit above and
    // therefore running BEFORE it, and long before OutputModules.deinit
    // destroys linux_dmabuf: a `copy` that arrived in between would
    // dereference a freed module through `destination.ctx`.
    wireScreencopyDmabuf(&state, &output);
    defer clearScreencopyDmabuf(&state);
    try applyEnvironment(&start, &state, &output);

    // --- zio event loop ---------------------------------------------------
    // SAFETY: initialized by loop.init() immediately below, before any use.
    var loop: zio.ev.Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();
    state.loop = &loop;
    // SAFETY: `timers` has no default and is written field by field by
    // armEventLoop before the loop is polled; the two conditional pollers
    // are read only under the same condition that writes them.
    var timers: LoopTimers = undefined;
    armEventLoop(&start, &state, &output, &timers);

    try output.backend.start(); // fires new_output; the headless timer paces frames
    if (input_backend) |ib| try ib.start();
    armBackendPollers(&state, &output, input_backend, &timers);

    runEventLoop(&state);
}

/// The ServerState's own resources, freed in the order main()'s `defer`s
/// used to run them (reverse registration), and for the same reasons:
/// the clients die FIRST, because their surface/buffer destroy signals
/// must fire against LIVE modules (the shm map remove, shm.zig:223, the
/// surface-node registry and the seat cleanup all touch module state);
/// display.deinit ALSO calls destroyClients as idempotent safety (no
/// clients are left here), which alone would run AFTER the shm deinit —
/// the shutdown UAF a live client (e.g. foot at window close) hit. Then
/// the per-surface scene state, the scene output view and the scene tree
/// itself; the compositor (core.deinit, deferred earlier) destroys its
/// surfaces afterwards, and the listeners were already removed, so no
/// entry is freed twice.
fn freeStateResources(state: *ServerState) void {
    state.display.destroyClients();
    // The output views go BEFORE the scene and the cursor: every GL
    // object they own (the CPU-path FBO, the per-slot scanout images, the
    // capture FBO) belongs to the renderer's EGL context, and every open
    // GPU lease belongs to the backend's slots — both must be released
    // while the renderer and the backend are still alive. The scene's
    // surface textures go next (they hold the dmabuf Buffer imports),
    // still before linux_dmabuf.deinit() and backend.destroy() run in
    // OutputModules.deinit.
    freeOutputViews(state);
    cleanupSurfaceEntries(state);
    if (state.cursor_gl) |t| {
        t.destroy();
        state.cursor_gl = null;
    }
    state.cursor_gl_source = null;
    // The scene's placement policy names this state; drop it before the
    // state dies and before the scene's own teardown can ask again.
    clearScenePlacementPolicy(state);
    if (state.scene) |scene| scene.deinit();
    state.canvas_index.deinit(state.allocator);
    state.surface_place.deinit(state.allocator);
    state.layer_popups.deinit(state.allocator);
    state.layer_surfaces.deinit(state.allocator);
    state.toplevels.deinit(state.allocator);
    state.synth_clicked.deinit(state.allocator);
    state.synth_pointed.deinit(state.allocator);
}

/// zwlr_screencopy_v1: captures the compositor framebuffer (shm only).
/// The copy is deferred to the next output commit; requestFrame wakes the
/// renderer so a pending copy gets its commit. The three callbacks reach
/// back into `state`, so the module is stored there, not in a local.
fn initScreencopy(start: *Startup, state: *ServerState, core: *const CoreModules) !void {
    state.screencopy = try wayland.screencopy.Screencopy.init(
        start.allocator,
        start.io,
        start.log_cfg,
        core.display,
        core.shm_state,
        getFramebuffer,
        state,
        outputFromResource,
        state,
        requestFrame,
        state,
    );
}

/// `dmabuf_mod.beginWrite` in the ctx/fn pair a screencopy destination
/// takes. The mapping lives in the Buffer's own impl data (the gbm bo the
/// import path created), so the context is not consulted — it is carried
/// only because DmabufDestination reaches all three of its members the
/// same way, and the resolver beside them does need it.
fn beginDmabufWrite(ctx: *anyopaque, buf: *wayland.buffers.Buffer) ?wayland.dmabuf.CpuWrite {
    _ = ctx;
    return wayland.dmabuf.beginWrite(buf);
}

/// `dmabuf_mod.endWrite` in the same pair. It runs AFTER the writes: for
/// a bo GBM could not map in place, `gbm_bo_unmap` is what copies the
/// staging buffer into the bo, so an early call loses the pixels.
fn endDmabufWrite(ctx: *anyopaque, buf: *wayland.buffers.Buffer, map: wayland.dmabuf.CpuWrite) void {
    _ = ctx;
    wayland.dmabuf.endWrite(buf, map);
}

/// Hand zwlr_screencopy_v1 the compositor's dmabuf import path, exactly
/// as screencopy.zig's wiring snippet spells it: the LinuxDmabuf module
/// owns the buffers and resolves the client's wl_buffer, and the CPU
/// write mapping comes from buffers/dmabuf.zig.
fn wireScreencopyDmabuf(state: *ServerState, output: *const OutputModules) void {
    const sc = state.screencopy orelse return;
    wireScreencopyDmabufInto(sc, output.linux_dmabuf, state.io, state.log_cfg);
}

/// The wiring itself, over the two modules it names. Split from
/// `wireScreencopyDmabuf` so the test harness can install the very same
/// destination on its own Screencopy, and so the teardown half has one
/// shape to mirror.
fn wireScreencopyDmabufInto(
    sc: *wayland.screencopy.Screencopy,
    linux: *wayland.linux_dmabuf.LinuxDmabuf,
    io: *std.Io,
    log_cfg: *const log.Config,
) void {
    // Only wired when the module actually has a device. A LinuxDmabuf
    // built with a null GBM device registers no global and resolves
    // every resource to null, so leaving the destination unset keeps
    // every backend without a GBM device byte-for-byte the shm-only
    // compositor it is today.
    if (!linux.advertised()) {
        log.info(
            "screencopy: no dmabuf import device; captures stay shm-only",
            io,
            log_cfg,
            "screencopy",
            .{},
        );
        return;
    }
    sc.setDmabufDestination(.{
        .ctx = linux,
        .resolve = resolveDmabufBuffer,
        .begin_write = beginDmabufWrite,
        .end_write = endDmabufWrite,
    });
}

/// The other half of the wiring: drop the destination so a `copy` that
/// arrives after the LinuxDmabuf module is gone cannot reach it. main()
/// runs this before the screencopy module is deinited, and both run
/// before OutputModules.deinit destroys linux_dmabuf.
fn clearScreencopyDmabuf(state: *ServerState) void {
    if (state.screencopy) |sc| sc.clearDmabufDestination();
}

/// Phase 1: the display, wl_shm, the compositor, the shell, the seat and
/// the modules that depend on them. The construction order IS the
/// teardown order reversed (CoreModules.deinit), so it is a contract, not
/// an accident; the two phases below fill ONE bundle so main registers
/// ONE defer for the whole group and the order cannot drift between
/// them.
fn buildCore(start: *Startup) !CoreModules {
    // SAFETY: written field by field by the two phases below; every
    // field a phase sets is also errdefer'd by that phase, so a failure
    // unwinds exactly what was built and the bundle is never read
    // half-filled.
    var core: CoreModules = undefined;
    try buildCoreDisplay(start, &core);
    try buildCoreModules(start, &core);
    return core;
}

/// Phase 1a: the display, wl_shm, the compositor, the shell and the seat
/// — the modules every later phase hangs off.
fn buildCoreDisplay(start: *Startup, core: *CoreModules) !void {
    const allocator = start.allocator;
    const io = start.io;
    const log_cfg = start.log_cfg;

    const display = try wayland.core.display.CompositorDisplay.init(allocator, io, log_cfg);
    errdefer display.deinit();
    core.display = display;
    try display.initShm();

    if (start.env.get("WAYLAND_PROTOCOL_LOG")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            display.attachProtocolLogger();
            log.info("protocol logger attached (WAYLAND_PROTOCOL_LOG=1)", io, log_cfg, "server", .{});
        }
    }

    // wp_presentation (stable v2): one global, registered right after the
    // display so feedback objects exist before any client commit.
    const presentation = try wayland.presentation.Presentation.init(allocator, io, log_cfg, display);
    errdefer presentation.deinit();
    core.presentation = presentation;

    // wl_shm outlives the compositor: both inits only need the display,
    // setShm wires them together after both exist, and CoreModules.deinit
    // destroys the compositor's surfaces BEFORE wl_shm.
    const shm_state = try wayland.shm.ShmState.init(allocator, io, log_cfg, display);
    errdefer shm_state.deinit();
    core.shm_state = shm_state;
    const compositor = try wayland.compositor.Compositor.init(allocator, io, log_cfg, display);
    errdefer compositor.deinit();
    core.compositor = compositor;
    compositor.setShm(shm_state);
    const shell = try wayland.shell.XdgShell.init(allocator, io, log_cfg, display, compositor);
    errdefer shell.deinit();
    core.shell = shell;
    // zwlr_layer_shell_v1: layer surfaces (panels, wallpapers, lock screens).
    const layer_shell = try wayland.layer_shell.LayerShell.init(allocator, io, log_cfg, display, compositor);
    errdefer layer_shell.deinit();
    core.layer_shell = layer_shell;
    // M3: the seat (keyboard + pointer) with the xkbcommon us keymap.
    const seat = try wayland.seat.Seat.init(allocator, io, log_cfg, display, .{});
    errdefer seat.deinit();
    core.seat = seat;
    // F10: runtime layout selection (WAYLAND_KEYBOARD_LAYOUT, default
    // "us" compiled by Seat.init) — recompiles the keymap and
    // re-broadcasts it before any client binds.
    if (start.env.get("WAYLAND_KEYBOARD_LAYOUT")) |layout| {
        seat.setKeyboardLayout(layout);
    }
}

/// Phase 1b: the eight protocol modules built on top of the core, in the
/// order CoreModules.deinit walks back through.
fn buildCoreModules(start: *Startup, core: *CoreModules) !void {
    const allocator = start.allocator;
    const io = start.io;
    const log_cfg = start.log_cfg;
    const display = core.display;
    const compositor = core.compositor;
    const shell = core.shell;
    const seat = core.seat;

    // xdg_activation_v1 (staging): activation tokens for focus requests
    // (needs the seat for serial/focus validation).
    const xdg_activation = try wayland.xdg_activation.XdgActivation.init(
        allocator,
        io,
        log_cfg,
        display,
        seat,
        compositor,
    );
    errdefer xdg_activation.deinit();
    core.xdg_activation = xdg_activation;
    // zxdg_decoration_manager_v1 (unstable): server-side decorations.
    const xdg_decoration = try wayland.xdg_decoration.XdgDecoration.init(allocator, io, log_cfg, display, shell);
    errdefer xdg_decoration.deinit();
    core.xdg_decoration = xdg_decoration;
    // wp_fractional_scale_manager_v1 (staging): the preferred scale.
    const fractional_scale = try wayland.fractional_scale.FractionalScale.init(allocator, io, log_cfg, display);
    errdefer fractional_scale.deinit();
    core.fractional_scale = fractional_scale;
    // zxdg_output_manager_v1 (unstable/xdg-output): logical output
    // geometry for clients (grim, region tools).
    const xdg_output = try wayland.xdg_output.XdgOutput.init(allocator, io, log_cfg, display);
    errdefer xdg_output.deinit();
    core.xdg_output = xdg_output;
    // Advertise the preferred scale now (scale 1: 120/120). The value is
    // a settable API — a future scale path calls setPreferredScale on
    // output-scale change (wlroots refines to per-surface notify_scale).
    fractional_scale.setPreferredScale(120);
    // wp_viewporter (stable): crop/scale surface content (foot needs it).
    const viewporter = try wayland.viewporter.Viewporter.init(allocator, io, log_cfg, display);
    errdefer viewporter.deinit();
    core.viewporter = viewporter;
    // Subcompositor (foot needs wl_subcompositor).
    const subcompositor = try wayland.subsurface.Subcompositor.init(allocator, io, log_cfg, display, compositor);
    errdefer subcompositor.deinit();
    core.subcompositor = subcompositor;
    // Data device manager (foot requires it; clipboard selection relay).
    const data_device = try wayland.data_device.DataDeviceManager.init(allocator, io, log_cfg, display, seat);
    errdefer data_device.deinit();
    core.data_device = data_device;
    // Primary selection (zwp_primary_selection_device_manager_v1, the
    // X11 PRIMARY analogue): per-seat, keyboard-focus-owned.
    const primary_selection = try wayland.primary_selection.PrimarySelection.init(
        allocator,
        io,
        log_cfg,
        display,
        seat,
    );
    errdefer primary_selection.deinit();
    core.primary_selection = primary_selection;
}

/// Create the listening socket and print its name on its own flushed
/// stdout line, the first thing a harness reads. It runs BEFORE the
/// backend init (the raylib window open can take seconds or fail on a
/// headless/broken display); logging goes to stderr, so stdout stays
/// parseable.
fn announceSocket(start: *Startup, display: *wayland.core.display.CompositorDisplay) !void {
    const socket_name = try display.addSocketAuto();
    log.info("created socket {s}", start.io, start.log_cfg, "server", .{socket_name});

    const stdout_file = std.Io.File.stdout();
    var buf: [128]u8 = undefined;
    var w = stdout_file.writer(start.io.*, &buf);
    w.interface.print("WAYLAND_SOCKET={s}\n", .{socket_name}) catch |err| {
        log.err("failed to write socket name to stdout: {s}", start.io, start.log_cfg, "server", .{@errorName(err)});
        return err;
    };
    w.interface.flush() catch |err| {
        log.err("failed to flush socket name to stdout: {s}", start.io, start.log_cfg, "server", .{@errorName(err)});
        return err;
    };
}

/// Phase 2: the nine modules constructed after the seat.
///
/// Dependency order: everything below is constructed AFTER the seat it
/// may attach to, and each module's teardown therefore runs BEFORE the
/// seat's (SeatModules.deinit, then core.deinit), so no module can reach
/// a freed seat during teardown. As in buildCore, the two phases fill ONE
/// bundle so main registers one defer for the whole group.
fn buildSeatModules(start: *Startup, core: *const CoreModules) !SeatModules {
    // SAFETY: written field by field by the two phases below; every
    // field a phase sets is also errdefer'd by that phase.
    var mods: SeatModules = undefined;
    try buildPointerModules(start, core, &mods);
    try buildProtocolModules(start, core, &mods);
    return mods;
}

/// Phase 2a: the pointer-stream modules — gestures, relative pointer and
/// pointer constraints, then the tablet registry the cursor shapes
/// resolve their serials through.
fn buildPointerModules(start: *Startup, core: *const CoreModules, mods: *SeatModules) !void {
    const allocator = start.allocator;
    const io = start.io;
    const log_cfg = start.log_cfg;
    const display = core.display;
    const compositor = core.compositor;
    const seat = core.seat;

    // zwp_pointer_gestures_v1 (unstable): swipe/pinch/hold recognition.
    // The module installs its own seat listeners (setSeat), so main's
    // only job is handing it the seat.
    const pointer_gestures = try wayland.pointer_gestures.PointerGestures.init(
        allocator,
        io,
        log_cfg,
        display,
        seat,
    );
    errdefer pointer_gestures.deinit();
    mods.pointer_gestures = pointer_gestures;
    // zwp_relative_pointer_manager_v1 (unstable): unclaccelerated
    // relative motion (24.8 deltas + a 64-bit utime).
    const relative_pointer = try wayland.relative_pointer.RelativePointer.init(
        allocator,
        io,
        log_cfg,
        display,
        seat,
    );
    errdefer relative_pointer.deinit();
    mods.relative_pointer = relative_pointer;
    // zwp_pointer_constraints_v1 (unstable): locked and confined
    // pointers. Needs the compositor to resolve a wl_surface for
    // lock_pointer / confine_pointer.
    const pointer_constraints = try wayland.pointer_constraints.PointerConstraints.init(
        allocator,
        io,
        log_cfg,
        display,
        compositor,
        seat,
    );
    errdefer pointer_constraints.deinit();
    mods.pointer_constraints = pointer_constraints;
    // zwp_tablet_manager_v2 (stable): the hardware registry. It needs no
    // seat — a tablet announces its own zwp_tablet_seat_v2 — and no
    // hardware is registered (this server has no tablet input backend),
    // which is the module's documented "correct with no hardware" state.
    const tablet = try wayland.tablet.Tablet.init(allocator, io, log_cfg, display);
    errdefer tablet.deinit();
    mods.tablet = tablet;
}

/// Phase 2b: cursor shapes (which need the tablet above), the tearing
/// hint, the session lock, the data-control manager and the foreign
/// toplevel handles.
fn buildProtocolModules(start: *Startup, core: *const CoreModules, mods: *SeatModules) !void {
    const allocator = start.allocator;
    const io = start.io;
    const log_cfg = start.log_cfg;
    const display = core.display;
    const shell = core.shell;
    const seat = core.seat;

    // wp_cursor_shape_manager_v1 (staging): per-device cursor shapes.
    // Built AFTER the tablet module: a tablet-tool cursor-shape device
    // resolves its serial through it (shell/cursor_shape.zig), and a
    // null tablet would make every such device permanently inert.
    const cursor_shape = try wayland.cursor_shape.CursorShape.init(allocator, io, log_cfg, display, mods.tablet);
    errdefer cursor_shape.deinit();
    mods.cursor_shape = cursor_shape;
    // wp_tearing_control_manager_v1 (staging): the per-surface async
    // present hint. The present path reads it per surface per frame
    // (consultTearingHints); the module itself only records.
    const tearing_control = try wayland.tearing_control.TearingControl.init(allocator, io, log_cfg, display);
    errdefer tearing_control.deinit();
    mods.tearing_control = tearing_control;
    // ext_session_lock_manager_v1 (staging): the session-lock privilege
    // boundary. The module owns the protocol state; main owns the gates
    // (see lockedFrameFor, pickSurface, keyboardFocusAllowed and the
    // session_locked listener handler).
    const session_lock = try wayland.session_lock.SessionLock.init(allocator, io, log_cfg, display);
    errdefer session_lock.deinit();
    mods.session_lock = session_lock;
    // zwlr_data_control_manager_v1 (wlroots/unstable): the compositor as
    // data SOURCE. Needs the seat (a device is per seat), the ordinary
    // wl_data_device_manager it mirrors (the read side) and the primary
    // selection manager (v2's set_primary_selection).
    const data_control = try wayland.data_control.DataControlManager.init(
        allocator,
        io,
        log_cfg,
        display,
        seat,
        core.data_device,
        core.primary_selection,
    );
    errdefer data_control.deinit();
    mods.data_control = data_control;
    // zwlr_foreign_toplevel_manager_v1 (wlroots/unstable): our own xdg
    // toplevels as client-visible handles. Built after the shell (it
    // subscribes to xdg_wm_base.new_toplevel) and after the seat (its
    // `activate` request acts on the seat).
    const foreign_toplevel = try wayland.foreign_toplevel.ForeignToplevelManager.init(
        allocator,
        io,
        log_cfg,
        display,
        shell,
        seat,
    );
    errdefer foreign_toplevel.deinit();
    mods.foreign_toplevel = foreign_toplevel;
}

/// Phase 3: the backend (WAYLAND_BACKEND), its GPU device, the renderer
/// (WAYLAND_RENDERER), the GPU scanout formats and zwp_linux_dmabuf_v1.
///
/// The ORDER is the contract, and it is the opposite of what this phase
/// used to do (renderer, then backend). A GPU scanout has one device
/// shared by the three parties, so each one must exist before the next
/// needs it:
///
///   1. the backend — prepareGpu opens the DRM node and its GBM device
///      here, before start(), without touching modesetting or acquiring
///      a seat/master/session;
///   2. the renderer — on a GPU DRM run it is created ON that device
///      (createOnDevice), so the EGL display, the GBM import path and
///      the scanout buffers' native images are one device's, and a
///      cross-device import is never attempted;
///   3. the format negotiation — the backend is told the renderer's REAL
///      renderable pairs (setGpuFormats) BEFORE start(), because output
///      creation happens inside start() and intersects the pairs with the
///      primary plane's actual format/modifier support to allocate the
///      GPU-only scanout buffers;
///   4. zwp_linux_dmabuf_v1 — with the device already open, so the
///      module advertises its real formats to clients. No client can
///      connect before the socket is announced, and main() announces it
///      BEFORE this phase, so every client sees a fully advertised
///      import device.
///
/// A capability failure is explicit: prepareGpu or setGpuFormats
/// returning an error propagates out of main(). Nothing here falls back
/// to a CPU front buffer behind the operator's back — GPU scanout is
/// either negotiated or the server does not start with it.
fn buildOutput(start: *Startup, core: *const CoreModules) !OutputModules {
    const allocator = start.allocator;
    const io = start.io;
    const log_cfg = start.log_cfg;
    const display = core.display;

    // 1. The renderer choice comes FIRST, because it decides whether a
    //    GPU device is opened at all. A pixman run is the CPU baseline
    //    and must not require a GBM node: on a card that cannot provide
    //    one the old order failed with error.GpuUnavailable even though
    //    nothing about a CPU canvas needs it. An explicit
    //    WAYLAND_RENDERER=gles2 failure still propagates — that is the
    //    capability report, never a silent CPU fallback.
    const renderer_kind = selectRendererKind(start);

    // 2. The backend, then its GPU device. prepareGpu is idempotent and
    //    uses the SAME fd/GBM handle the backend itself reuses in start,
    //    so there is one DRM node and one GBM device in the process.
    const chosen = try buildBackend(start, display);
    errdefer chosen.backend.destroy();
    var gpu_device: ?*wayland.dmabuf.GbmDevice = null;
    if (chosen.is_drm and renderer_kind == .gles2) {
        gpu_device = try drm_mod.DrmBackend.prepareGpu(chosen.backend);
    }

    // The cursor always needs a pixman renderer of its own:
    // compositor/cursor.zig draws into a `*pixman.Framebuffer` and
    // imports its textures through `PixmanRenderer.importMemory` whatever
    // renderer it is handed (cursor.zig:260, :337), so handing it a GLES2
    // renderer would read a GL texture payload as pixman memory. The
    // pixman renderer is therefore built either way, and the selected one
    // is a second object only under WAYLAND_RENDERER=gles2.
    const pixman_renderer = try pixman.PixmanRenderer.create(allocator, io, log_cfg);
    errdefer pixman_renderer.destroy();

    // 3. The renderer, on the backend's own device when there is one. A
    //    DRM run without a prepared device, or with the CPU renderer
    //    selected, gets the ordinary surfaceless context: the CPU
    //    backends scan out CPU bytes and are explicitly not GPU scanout.
    const renderer = switch (renderer_kind) {
        .pixman => pixman_renderer,
        .gles2 => if (gpu_device) |device|
            try gles2.Gles2Renderer.createOnDevice(allocator, io, log_cfg, device)
        else
            try gles2.Gles2Renderer.create(allocator, io, log_cfg),
    };
    errdefer if (renderer != pixman_renderer) renderer.destroy();

    // 4. The scanout formats, BEFORE start(). The pairs are the
    //    renderer's own (it allocated the native images behind them), so
    //    they are borrowed for the backend's lifetime and outlive it
    //    only as long as the renderer does — which teardown guarantees.
    var gpu_formats: []const wayland.dmabuf.Format = &.{};
    var gpu_scanout = false;
    if (gpu_device) |device| {
        gpu_formats = gles2.Gles2Renderer.renderFormats(renderer);
        if (gpu_formats.len == 0) return error.NoRenderableFormats;
        try drm_mod.DrmBackend.setGpuFormats(chosen.backend, gpu_formats);
        gpu_scanout = true;
        // 4b. zwp_linux_dmabuf_v1 advertises Device.formats(), which is
        //     read at LinuxDmabuf.init below, so the advertised set is
        //     narrowed HERE to exactly the pairs this renderer proved it
        //     can both import and render. GBM's own enumeration is a
        //     superset — it lists what the BOOM can allocate — and a
        //     client that attaches a pair the sampler cannot draw gets a
        //     surface that imports and then never appears. An OWNED copy:
        //     setFormats takes ownership and GbmDevice.deinit frees it.
        const advertised = try allocator.dupe(wayland.dmabuf.Format, gpu_formats);
        device.setFormats(advertised);
        log.info(
            "gpu scanout: {d} renderable format pair(s) negotiated with the DRM backend and advertised to clients",
            io,
            log_cfg,
            "server",
            .{gpu_formats.len},
        );
    }

    // 5. zwp_linux_dmabuf_v1 (stable/linux-dmabuf): DMA-BUF buffer
    //    import. Constructed AFTER the device exists (the module needs
    //    it) and destroyed BEFORE backend.destroy(): the GBM device
    //    belongs to the DRM backend and must outlive the module.
    //
    // The module registers its global ONLY for a device, and the only
    // device this server has is the GPU renderer's GBM one. A pixman run
    // therefore advertises NO zwp_linux_dmabuf_v1 at all: the CPU
    // compositor cannot sample a native image without mapping it, so
    // offering the global would promise a path that does not exist
    // (shell/linux_dmabuf.zig's documented gate). wl_shm is unaffected
    // and stays the CPU path.
    const linux_dmabuf = try wayland.linux_dmabuf.LinuxDmabuf.init(
        allocator,
        io,
        log_cfg,
        display,
        if (gpu_device) |dev| &dev.iface else null,
    );
    errdefer linux_dmabuf.deinit();

    // From here on wl_surface.attach resolves dmabuf buffers through the
    // module. The clear is the FIRST statement of OutputModules.deinit,
    // so it runs before linux_dmabuf.deinit(): no attach can ever call
    // into a freed module.
    //
    // The resolver is set even with no device: LinuxDmabuf.init
    // returns an inert module (no global, empty registry), so
    // fromResource answers null for every resource and the shm path runs
    // exactly as before on headless / raylib / nested.
    wireDmabufResolver(core.compositor, linux_dmabuf);

    return .{
        .renderer_kind = renderer_kind,
        .renderer = renderer,
        .pixman_renderer = pixman_renderer,
        .backend = chosen.backend,
        .is_raylib = chosen.is_raylib,
        .is_drm = chosen.is_drm,
        .is_nested = chosen.is_nested,
        .linux_dmabuf = linux_dmabuf,
        .gpu_device = gpu_device,
        .gpu_formats = gpu_formats,
        .gpu_scanout = gpu_scanout,
    };
}

/// Backend selection: WAYLAND_BACKEND=raylib uses the windowed raylib
/// debug backend (falling back to headless when the window cannot
/// open); anything else uses the headless backend. The raylib path is
/// only reachable when built with -Denable_raylib (default on).
fn buildBackend(start: *Startup, display: *wayland.core.display.CompositorDisplay) !BackendChoice {
    const mode: wayland.output.Mode = .{
        .width = output_width,
        .height = output_height,
        .refresh_msec = output_refresh_msec,
    };
    return blk: {
        // DRM/KMS native output (tested in the NixOS VM on virtio-gpu).
        if (wantDrmBackend(start.env)) {
            const device = start.env.get("WAYLAND_DRM_DEVICE");
            break :blk .{
                .backend = try drm_mod.DrmBackend.create(start.allocator, start.io, start.log_cfg, device),
                .is_drm = true,
            };
        }
        // Nested-wayland backend (M5): our compositor acts as a client of
        // a parent compositor (WAYLAND_DISPLAY), presenting its framebuffer
        // into a parent wl_surface. Real-session testing without DRM.
        if (wantNestedBackend(start.env)) {
            break :blk .{
                .backend = try wayland.wayland_backend.WaylandBackend.create(
                    start.allocator,
                    start.io,
                    start.log_cfg,
                    display.getServer().getEventLoop(),
                    mode,
                    "wayland-compositor",
                ),
                .is_nested = true,
            };
        }
        if (build_options.enable_raylib and wantRaylibBackend(start.env)) {
            const b = raylib_mod.RaylibBackend.create(
                start.allocator,
                start.io,
                start.log_cfg,
                display.getServer().getEventLoop(),
                mode,
                "wayland-m2",
            ) catch |err| {
                log.warn(
                    "raylib backend init failed ({s}); falling back to headless",
                    start.io,
                    start.log_cfg,
                    "server",
                    .{@errorName(err)},
                );
                break :blk .{ .backend = try wayland.headless.HeadlessBackend.create(
                    start.allocator,
                    start.io,
                    start.log_cfg,
                    display.getServer().getEventLoop(),
                    mode,
                ) };
            };
            break :blk .{ .backend = b, .is_raylib = true };
        }
        // Unknown WAYLAND_BACKEND value: headless fallback with a warning.
        // An unset variable is the normal default (no warning); the raylib
        // window-open failure logs its own warning above.
        if (start.env.get("WAYLAND_BACKEND")) |v| {
            const known = std.mem.eql(u8, v, "drm") or
                std.mem.eql(u8, v, "nested") or
                (build_options.enable_raylib and std.mem.eql(u8, v, "raylib"));
            if (!known) {
                log.warn("WAYLAND_BACKEND '{s}' unknown; using headless backend", start.io, start.log_cfg, "server", .{v});
            }
        }
        break :blk .{ .backend = try wayland.headless.HeadlessBackend.create(
            start.allocator,
            start.io,
            start.log_cfg,
            display.getServer().getEventLoop(),
            mode,
        ) };
    };
}

/// The libinput input source (evdev devices; VM: virtio keyboard/mouse).
/// A second Backend whose only role is announcing devices + the poll fd
/// the zio loop watches; events flow into the seat via its dispatch.
/// Null when WAYLAND_LIBINPUT is unset or not "1".
///
/// `tablet` is the zwp_tablet_manager_v2 module, handed over here so the
/// backend announces real tablet hardware instead of only logging a
/// device it cannot classify. It must outlive the backend: the module is
/// built by buildSeatModules and torn down after `input_backend.destroy()`
/// (defers unwind in reverse), and the backend's own teardown only frees
/// its device registry.
fn buildInputBackend(
    start: *Startup,
    seat: *wayland.seat.Seat,
    tablet: *wayland.tablet.Tablet,
) !?*wayland.backend.Backend {
    const value = start.env.get("WAYLAND_LIBINPUT") orelse return null;
    if (!std.mem.eql(u8, value, "1")) {
        log.warn("WAYLAND_LIBINPUT '{s}' ignored (expected \"1\")", start.io, start.log_cfg, "server", .{value});
        return null;
    }
    const backend = try libinput_mod.LibinputBackend.create(
        start.allocator,
        start.io,
        start.log_cfg,
        seat,
        "seat0",
        output_width,
        output_height,
    );
    // BEFORE start(): the initial udev drain inside start() is what
    // registers a tablet that was already plugged in, so attaching after
    // it would make the first tablet invisible (libinput.zig attachTablet).
    libinput_mod.LibinputBackend.attachTablet(backend, tablet);
    return backend;
}

/// The renderer WAYLAND_RENDERER selects, with the log line that says so.
/// An unset variable is the normal default (no warning — the same rule
/// WAYLAND_BACKEND follows); an unknown value warns and falls back to
/// the pixman renderer.
fn selectRendererKind(start: *Startup) RendererKind {
    const raw = start.env.get("WAYLAND_RENDERER");
    if (parseRendererEnv(raw)) |kind| {
        log.info("renderer: {s} (WAYLAND_RENDERER={s})", start.io, start.log_cfg, "server", .{
            @tagName(kind),
            raw orelse "(unset)",
        });
        return kind;
    }
    log.warn("WAYLAND_RENDERER '{s}' unknown; using the pixman renderer", start.io, start.log_cfg, "server", .{raw.?});
    return .pixman;
}

/// The ServerState every listener handler and policy function hangs
/// off: the modules, the render targets and the mutable frame policy.
fn initServerState(
    start: *Startup,
    core: *const CoreModules,
    seat_mods: *const SeatModules,
    output: *const OutputModules,
) !ServerState {
    return .{
        .allocator = start.allocator,
        .io = start.io,
        .log_cfg = start.log_cfg,
        .display = core.display,
        .compositor = core.compositor,
        .shm_state = core.shm_state,
        .shell = core.shell,
        .layer_shell = core.layer_shell,
        .seat = core.seat,
        .subcompositor = core.subcompositor,
        .data_device = core.data_device,
        .primary_selection = core.primary_selection,
        .renderer = output.renderer,
        .pixman_renderer = output.pixman_renderer,
        .renderer_kind = output.renderer_kind,
        .xdg_activation = core.xdg_activation,
        .xdg_decoration = core.xdg_decoration,
        .fractional_scale = core.fractional_scale,
        .viewporter = core.viewporter,
        .pointer_gestures = seat_mods.pointer_gestures,
        .relative_pointer = seat_mods.relative_pointer,
        .pointer_constraints = seat_mods.pointer_constraints,
        .tablet = seat_mods.tablet,
        .cursor_shape = seat_mods.cursor_shape,
        .tearing_control = seat_mods.tearing_control,
        .session_lock = seat_mods.session_lock,
        .data_control = seat_mods.data_control,
        .foreign_toplevel = seat_mods.foreign_toplevel,
        .linux_dmabuf = output.linux_dmabuf,
        .backend = output.backend,
        .drm_backend = if (output.is_drm) output.backend else null,
        .gpu_scanout = output.gpu_scanout,
        .camera_env = start.env.get("WAYLAND_CAMERA"),
        .presentation = core.presentation,
        .toplevels = .empty,
        .layer_surfaces = .empty,
        .layer_popups = .empty,
        .new_output_listener = wire.Listener(*wayland.output.Output).init(onNewOutput),
        .new_input_listener = wire.Listener(*wayland.backend.Backend.InputDevice).init(onNewInput),
        .input_removed_listener = wire.Listener(*wayland.backend.Backend.InputDevice).init(onInputRemoved),
        .content_dirty_listener = wire.Listener(*wayland.scene.Scene).init(onSceneContentDirty),
        .new_toplevel_listener = wire.Listener(*wayland.shell.XdgToplevel).init(onNewToplevel),
        .new_popup_listener = wire.Listener(*wayland.shell.XdgPopup).init(onNewPopup),
        .new_layer_surface_listener = wire.Listener(*wayland.layer_shell.LayerSurface).init(onNewLayerSurface),
        .new_layer_popup_listener = wire.Listener(*wayland.shell.XdgPopup).init(onNewLayerPopup),
        .request_activate_listener = wire.Listener(*wayland.xdg_activation.ActivateRequest).init(onRequestActivate),
        .request_mode_listener = wire.Listener(*wayland.xdg_decoration.RequestMode).init(onDecorationMode),
        .new_decoration_listener = wire.Listener(*wayland.xdg_decoration.Decoration).init(onNewDecoration),
        .new_activation_token_listener = wire.Listener(*wayland.xdg_activation.ActivationToken)
            .init(onNewActivationToken),
        .seat_key_listener = wire.Listener(*wayland.seat.Seat).init(onSeatKey),
        .seat_button_listener = wire.Listener(*wayland.seat.Seat).init(onSeatButton),
        .seat_pointer_move_listener = wire.Listener(*wayland.seat.Seat).init(onSeatPointerMove),
        .seat_axis_listener = wire.Listener(*wayland.seat.Seat).init(onSeatAxis),
        .seat_focus_listener = wire.Listener(*wayland.seat.Seat).init(onSeatKeyboardFocus),
        .session_locked_listener = wire.Listener(*wayland.session_lock.SessionLock).init(onSessionLocked),
        .session_unlocked_listener = wire.Listener(*wayland.session_lock.SessionLock).init(onSessionUnlocked),
        .new_lock_surface_listener = wire.Listener(*wayland.session_lock.LockSurface).init(onNewLockSurface),
        .lock_surface_gone_listener = wire.Listener(*wayland.session_lock.LockSurface).init(onLockSurfaceGone),
        .cursor_shape_changed_listener = wire.Listener(*wayland.cursor_shape.ShapeChange).init(onCursorShapeChanged),
    };
}

/// Every signal the compositor listens to, in the order the handlers
/// were registered before: the backend's outputs and input devices, the
/// shell's new surfaces, the seat's pointer stream (which carries the
/// camera controls), the focus-driven activation, the decoration and
/// activation requests, the session lock's four signals, and the
/// cursor-shape record.
fn subscribe(state: *ServerState) void {
    state.backend.events.new_output.add(&state.new_output_listener);
    if (state.input_backend) |ib| {
        ib.events.new_input.add(&state.new_input_listener);
        // Hotplug removal, the mirror of new_input: the seat must learn a
        // device it counted is gone, or it keeps advertising a wl_seat
        // capability no live hardware provides anymore.
        ib.events.input_removed.add(&state.input_removed_listener);
    }
    state.shell.events.new_toplevel.add(&state.new_toplevel_listener);
    state.shell.events.new_popup.add(&state.new_popup_listener);
    state.layer_shell.events.new_layer_surface.add(&state.new_layer_surface_listener);
    // L1: layer-popup parenting (get_popup) is observable; no anchoring or
    // placement policy here (out of scope, same as layer-surface layout).
    state.layer_shell.events.new_popup.add(&state.new_layer_popup_listener);
    state.seat.events.key.add(&state.seat_key_listener);
    // M4 Phase B camera controls: wheel zoom + drag pan hook the seat's
    // existing event surface (button, pointer_move, axis). The raylib
    // and libinput backends feed these signals through the seat API
    // (pointerButton/pointerMotion/pointerAxis), so no backend change is
    // needed; headless E2E synthesizes the same calls.
    state.seat.events.button.add(&state.seat_button_listener);
    state.seat.events.pointer_move.add(&state.seat_pointer_move_listener);
    state.seat.events.axis.add(&state.seat_axis_listener);
    // wl_toplevel.activated is compositor-authored state driven by the
    // seat's keyboard focus (P1-9), so a click — not only an
    // xdg_activation request — updates the active titlebar.
    state.seat.events.keyboard_focus.add(&state.seat_focus_listener);
    // xdg_activation_v1: activation requests with known tokens (focus
    // policy is out of scope — the handler logs and accepts) and the
    // token-creation hook (XA-1; the compositor can observe allowlists /
    // telemetry).
    state.xdg_activation.events.request_activate.add(&state.request_activate_listener);
    state.xdg_activation.events.new_token.add(&state.new_activation_token_listener);
    // zxdg_decoration_manager_v1: mode requests; the handler replies with
    // the effective mode via sendConfigure. New decorations announce the
    // compositor's initial mode the same way, so a client that never sends
    // set_mode still draws the policy chrome (L2).
    state.xdg_decoration.events.request_mode.add(&state.request_mode_listener);
    state.xdg_decoration.events.new_toplevel_decoration.add(&state.new_decoration_listener);
    // The compositor hit-tests over the scene graph: surfaces map to
    // scene nodes through the surface entries.
    state.seat.setPick(pickSurface, state);
    // Click-to-focus gates, in the order they are consulted: the session
    // lock first (while locked only a lock surface of the lock client may
    // take focus), then L-D7's layer policy — a layer surface with
    // keyboard_interactivity=none must never get focus, and the
    // move-based routing in applyLayerKeyboardFocus enforces the same
    // for hover.
    state.seat.setKeyboardFocusGate(keyboardFocusAllowed, state);
    // ext_session_lock_manager_v1, wiring item 2, for TOUCH: the
    // lock-aware pick above already drops every pointer event that is
    // not a lock surface, but the seat translates touch positions
    // through the same pick only to decide the focus surface. The gate
    // is what refuses a point (down AND motion) on a surface a locked
    // session must not drive, which is what stops a finger that went
    // down before the latch from dragging user content for the whole
    // locked interval. Same live-state callback shape as the two above,
    // so dropping the lock module restores touch by itself.
    state.seat.setTouchGate(touchAllowed, state);
    // zwlr_foreign_toplevel_manager_v1's `activate` is the THIRD route a
    // client has to keyboard focus (a click, xdg_activation, this one), so
    // it goes through the SAME composite gate with the SAME context: the
    // session-lock boundary must not have a hole on the side.
    state.foreign_toplevel.?.setFocusGate(state, keyboardFocusAllowed);
    // The popup grab hit-tests a pointer event (SCREEN pixels) against the
    // popup's WORLD rect, so the shell needs the same camera inversion
    // pickSurface does. Uninstalled it assumes the identity map, which is
    // only true until the first zoom or pan.
    state.shell.setScreenToWorld(screenToWorld, state);
    // A grab is the ONE input route that skips every gate above: the seat
    // returns into the grab's handlers before the pick, the focus gate and
    // the touch gate are reached. So the boundary needs a fourth gate,
    // consulted when a grab is INSTALLED rather than when input is
    // delivered. Same live-state callback shape, so unlocking restores
    // grabs by itself.
    state.seat.setGrabGate(grabAllowed, state);
    // ext_session_lock_manager_v1: the four signals main owns. `locked`
    // runs inside the lock surface's commit dispatch, so the grabs are
    // ended and the focus forced onto a lock surface BEFORE any frame can
    // be composited (shell/session_lock.zig wiring item 1).
    state.session_lock.?.events.locked.add(&state.session_locked_listener);
    state.session_lock.?.events.unlocked.add(&state.session_unlocked_listener);
    state.session_lock.?.events.new_lock_surface.add(&state.new_lock_surface_listener);
    state.session_lock.?.events.lock_surface_gone.add(&state.lock_surface_gone_listener);
    // wp_cursor_shape_manager_v1: an accepted set_shape is recorded by the
    // module; this compositor paints one cursor image for every shape, so
    // the handler only says so.
    state.cursor_shape.?.events.shape_changed.add(&state.cursor_shape_changed_listener);
}

/// The startup knobs read once and written straight into the
/// ServerState: the frame budget, the synthesized input, the perf trace,
/// and the raylib window's input source.
fn applyEnvironment(start: *Startup, state: *ServerState, output: *const OutputModules) !void {
    if (start.env.get("WAYLAND_RUN_FRAMES")) |frames| {
        state.run_frames = std.fmt.parseInt(u32, frames, 10) catch |err| blk: {
            log.warn(
                "WAYLAND_RUN_FRAMES '{s}' not parseable ({s}); running until watchdog",
                start.io,
                start.log_cfg,
                "server",
                .{ frames, @errorName(err) },
            );
            break :blk 0;
        };
        if (state.run_frames > 0) {
            log.info("WAYLAND_RUN_FRAMES: stopping after {d} frames", start.io, start.log_cfg, "server", .{state.run_frames});
        }
    }
    if (start.env.get("WAYLAND_SYNTH_INPUT")) |v| {
        // "1" is the original M3/M4 behaviour, byte for byte. "2" is that
        // PLUS a real pointer motion per distinct committed content/state
        // change (synth_pointer_moves). Anything else — including "0" and
        // an unset variable — stays off, exactly as before.
        if (std.mem.eql(u8, v, "1")) state.synth_input = true;
        if (std.mem.eql(u8, v, "2")) {
            state.synth_input = true;
            state.synth_pointer_moves = true;
            log.info("WAYLAND_SYNTH_INPUT=2: click/key/wheel once, plus a pointer motion per committed state change", start.io, start.log_cfg, "server", .{});
        }
    }
    if (start.env.get("WAYLAND_PERF")) |v| {
        if (std.mem.eql(u8, v, "1")) state.perf = true;
    }

    // The raylib window is the M3 input source: the backend polls raylib
    // state every commit and feeds the seat through raylib_input.poll.
    // Only when the raylib backend actually owns the backend object (the
    // headless fallback has no input source).
    if (output.is_raylib and build_options.enable_raylib) {
        const input = try raylib_input_mod.create(start.allocator, state.seat);
        state.raylib_input = input;
        raylib_mod.RaylibBackend.setInputHook(state.backend, raylib_input_mod.poll, input);
        log.info("raylib input source attached", start.io, start.log_cfg, "server", .{});
    }
}

/// Register the loop's timers. The Timer/PipePoll values live in
/// `timers` (main's scope) because the ServerState keeps pointers to
/// them; these functions only write them and add them. The fd pollers are
/// armed separately, AFTER backend.start(), exactly as before.
fn armEventLoop(
    start: *Startup,
    state: *ServerState,
    output: *const OutputModules,
    timers: *LoopTimers,
) void {
    const loop = state.loop.?;
    timers.* = .{
        .watchdog = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(watchdog_timeout_ms) }),
        .ping = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(xdg_ping_interval_ms) }),
        .repeat = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(600) }),
        .raylib_poll = zio.ev.Timer.init(.{ .duration = zio.Duration.fromMilliseconds(16) }),
        .display_poll = zio.ev.PipePoll.init(state.display.loopFd(), .read),
        // SAFETY: the optional pollers are written by armBackendPollers,
        // which registers each one with the loop in the same breath, so
        // the loop only ever reads one that was initialized.
        .input_poll = undefined,
        .drm_poll = undefined,
        .input_hotplug_poll = undefined,
        .drm_session_poll = undefined,
        .drm_hotplug_poll = undefined,
    };

    // Watchdog: registered BEFORE backend.start() so the first DRM frame's
    // re-arm (renderFrame) targets a timer already in the loop — a frame
    // can render as soon as the loop starts dispatching, and re-arming an
    // un-added timer would be a no-op. It fires only when nothing re-arms
    // it for the full window; a wedged loop stops with an error instead
    // of hanging tests.
    timers.watchdog.c.userdata = state;
    timers.watchdog.c.callback = onWatchdog;
    state.watchdog = &timers.watchdog;
    // The idle-frame skip means a healthy server renders nothing between
    // changes, so the watchdog (re-armed only per render) would stop an
    // idle interactive demo after the window. WAYLAND_WATCHDOG_DISABLE
    // opts out (set by the interactive VM demo; the E2E keeps it).
    const watchdog_disabled = start.env.get("WAYLAND_WATCHDOG_DISABLE") != null;
    state.watchdog_enabled = !watchdog_disabled;
    if (!watchdog_disabled) loop.add(&timers.watchdog.c);

    // xdg_wm_base ping policy (F3): a repeating timer re-arms itself in
    // onPingTick; each tick pings every live client and declares clients
    // unresponsive (error 6) when the previous ping went unanswered.
    timers.ping.c.userdata = state;
    timers.ping.c.callback = onPingTick;
    state.ping_timer = &timers.ping;
    loop.add(&timers.ping.c);

    // Server-side key repeat (seat key_repeat_delay/rate): one-shot
    // timer; the initial add arms a harmless no-op tick (nothing repeats),
    // onSeatKey re-arms it on a key press and disarms on release.
    timers.repeat.c.userdata = state;
    timers.repeat.c.callback = onRepeatTick;
    state.repeat_timer = &timers.repeat;
    loop.add(&timers.repeat.c);

    // raylib window input: poll + feed the seat from the loop at ~60 Hz.
    // The commit must NOT poll (mid-render feeding lands after the frame's
    // flush + the in_render guard suppresses the follow-up frame, leaving
    // the events queued forever). The timer requests a render when the
    // poll fed something, so events flush on the next pointerFrame().
    if (output.is_raylib and build_options.enable_raylib) {
        timers.raylib_poll.c.userdata = state;
        timers.raylib_poll.c.callback = onRaylibPollTick;
        state.raylib_poll_timer = &timers.raylib_poll;
        loop.add(&timers.raylib_poll.c);
    }
}

/// Register the fd pollers: the display (client requests + wire timers),
/// the libinput device fd, its udev hotplug monitor, and the DRM card
/// fd with its logind bus and connector monitor. Called after the
/// backends start, so the first frame a backend fires already has its
/// poller.
fn armBackendPollers(
    state: *ServerState,
    output: *const OutputModules,
    input_backend: ?*wayland.backend.Backend,
    timers: *LoopTimers,
) void {
    const loop = state.loop.?;

    // Watch the display fd: readable when a client sent requests or a wire
    // timer (headless frame pacing) is due. Rearm keeps the registration.
    timers.display_poll.c.userdata = state;
    timers.display_poll.c.callback = onDisplayReady;
    timers.display_poll.c.flags.rearm = true;
    loop.add(&timers.display_poll.c);

    // libinput: watch the udev/evdev fd; dispatch drains events into the seat.
    if (input_backend) |ib| {
        const libinput = libinput_mod.LibinputBackend.fromBackend(ib);
        timers.input_poll = zio.ev.PipePoll.init(libinput.pollFd(), .read);
        timers.input_poll.c.userdata = state;
        timers.input_poll.c.callback = onInputReady;
        timers.input_poll.c.flags.rearm = true;
        loop.add(&timers.input_poll.c);
        // The udev monitor beside it, so a device that appears or
        // disappears while the server runs is noticed and not only the
        // ones present at startup. It is a separate netlink socket from
        // the libinput context's, so it needs its own poller.
        if (armFdPoll(loop, &timers.input_hotplug_poll, libinput.hotplugPollFd(), state, onInputHotplugReady)) {
            state.input_hotplug_poll_fd = timers.input_hotplug_poll.handle;
        }
    }
    // DRM: watch the card fd for page-flip events (the frame pacing).
    if (output.is_drm) {
        const data = drm_mod.DrmBackend.fromBackend(output.backend);
        const drm_fd = drm_mod.pollFd(data);
        state.drm_poll_fd = drm_fd;
        timers.drm_poll = zio.ev.PipePoll.init(drm_fd, .read);
        timers.drm_poll.c.userdata = state;
        timers.drm_poll.c.callback = onDrmReady;
        timers.drm_poll.c.flags.rearm = true;
        loop.add(&timers.drm_poll.c);
        // M6: the logind bus (PrepareForSleep) and the connector hotplug
        // monitor are two more fds the DRM backend contributes, armed
        // beside the card fd exactly as the libinput monitor is beside the
        // device fd.
        const extra = drm_mod.extraFds(data);
        if (armFdPoll(loop, &timers.drm_session_poll, extra.session, state, onDrmSessionReady)) {
            state.drm_session_poll_fd = timers.drm_session_poll.handle;
        }
        if (armFdPoll(loop, &timers.drm_hotplug_poll, extra.hotplug, state, onDrmHotplugReady)) {
            state.drm_hotplug_poll_fd = timers.drm_hotplug_poll.handle;
        }
    }
}

/// Register one fd poller with the loop, or do NOTHING when there is no
/// fd to watch. Returns whether a poller was registered.
///
/// A -1 fd is the "this feature is not available" answer every one of
/// these subsystems gives (no udevd, no logind, no session). Registering
/// a poller for it would be the busy-spin the server must not have: a
/// poller on no descriptor completes immediately and forever, so the loop
/// would wake in a tight circle doing no work. Skipping is safe because
/// each dispatch function is itself a no-op without its fd.
fn armFdPoll(
    loop: *zio.ev.Loop,
    poll: *zio.ev.PipePoll,
    fd: std.posix.fd_t,
    state: *ServerState,
    callback: *const fn (*zio.ev.Loop, *zio.ev.Completion) void,
) bool {
    if (fd < 0) return false;
    poll.* = zio.ev.PipePoll.init(fd, .read);
    poll.c.userdata = state;
    poll.c.callback = callback;
    // Rearm: the callback drains the descriptor and the watch stays, so
    // the next wake dispatches again without re-registering.
    poll.c.flags.rearm = true;
    loop.add(&poll.c);
    return true;
}

/// Poll until the loop stops (the watchdog, WAYLAND_RUN_FRAMES, a poll
/// error or a client shutdown), then drop the loop pointer the state
/// hands to the watchdog re-arm.
fn runEventLoop(state: *ServerState) void {
    log.info("entering event loop (display fd {d})", state.io, state.log_cfg, "server", .{state.display.loopFd()});
    const loop = state.loop.?;
    while (!loop.stopped()) {
        loop.poll(.max) catch |err| {
            log.err("loop poll error: {s}", state.io, state.log_cfg, "server", .{@errorName(err)});
            break;
        };
    }
    log.info("event loop exited: views={d} frames={d} watchdog_fired={}", state.io, state.log_cfg, "server", .{
        state.output_views.items.len,
        totalFrames(state),
        state.watchdog_fired,
    });
    state.loop = null;
}

/// The session's total presented frames across every view. The frame
/// budget is a session budget, not a per-output one: a two-output server
/// must still stop after WAYLAND_RUN_FRAMES frames overall.
fn totalFrames(state: *ServerState) u32 {
    var total: u32 = 0;
    for (state.output_views.items) |v| total += v.frames_rendered;
    return total;
}

// ---------------------------------------------------------------------------
// Listeners
// ---------------------------------------------------------------------------

/// A backend announced an input device (libinput udev enumeration).
///
/// The announcement is RECORDED on the seat: the seat's device table is
/// what lets a later `input_removed` tell "the last device of this kind"
/// from "one of several", and only then may the corresponding wl_seat
/// capability be withdrawn. The seat decides the mask; this handler
/// only forwards the identity (compositor/seat.zig inputDeviceAdded).
fn onNewInput(
    listener: *wire.Listener(*wayland.backend.Backend.InputDevice),
    device: *wayland.backend.Backend.InputDevice,
) void {
    const self: *ServerState = @fieldParentPtr("new_input_listener", listener);
    log.info("libinput: device {s} ({s})", self.io, self.log_cfg, "libinput", .{
        device.name, @tagName(device.kind),
    });
    self.seat.inputDeviceAdded(device);
}

/// A device the seat counted is gone (udev "remove", libinput's
/// DEVICE_REMOVED, or the udev monitor).
///
/// The wire consequence is the seat's: when this was the LAST device
/// providing a capability, the seat withdraws that wl_seat capability
/// bit through setCapabilities, which re-announces the mask to every
/// bound wl_seat and inerts that interface's resources — so a client
/// asking for an interface no attached hardware can drive gets the
/// protocol's missing_capability error rather than a dead object
/// (wayland.xml:2094-2098). The touch case closes the live gesture with
/// an up per point plus the leave BEFORE the wl_touch resources go
/// inert, so no client is left waiting on points that will never lift.
fn onInputRemoved(
    listener: *wire.Listener(*wayland.backend.Backend.InputDevice),
    device: *wayland.backend.Backend.InputDevice,
) void {
    const self: *ServerState = @fieldParentPtr("input_removed_listener", listener);
    log.info("libinput: device {s} ({s}) removed", self.io, self.log_cfg, "libinput", .{
        device.name, @tagName(device.kind),
    });
    self.seat.inputDeviceRemoved(device);
}

/// A backend announced an output: build its OutputView.
///
/// Idempotent in the sense that matters: a second announcement of an
/// output that already has a view is ignored, so the view list can
/// never hold two views for one connector.
fn onNewOutput(listener: *wire.Listener(*wayland.output.Output), out: *wayland.output.Output) void {
    const self: *ServerState = @fieldParentPtr("new_output_listener", listener);
    if (viewForOutput(self, out) != null) return;
    log.info("new output {d}x{d} refresh={d}ms", self.io, self.log_cfg, "server", .{
        out.mode.width, out.mode.height, out.mode.refresh_msec,
    });
    const view = createOutputView(self, out) orelse return;

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
    requestRenderView(self, view);
}

/// Build the heap OutputView for `out` and add it to the layout. Null on
/// any allocation or module failure, with everything already built
/// unwound; the caller (onNewOutput) only logs and leaves the output
/// unrendered in that case, exactly as a failed scene creation did.
fn createOutputView(self: *ServerState, out: *wayland.output.Output) ?*OutputView {
    // M2: ONE scene for every output, created with the first view and
    // shared by all the rest — the views are the per-output state, the
    // scene is their common world.
    const scene = self.scene orelse blk: {
        const created = wayland.scene.Scene.init(self.allocator, self.io, self.log_cfg) catch |err| {
            log.err("scene init failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            return null;
        };
        // The scene's surface bindings need the compositor's
        // subcompositor (subsurface tree parenting). Set before any
        // surface is tracked (surfaces only appear after backend.start()).
        created.subcompositor = self.subcompositor;
        created.events.content_dirty.add(&self.content_dirty_listener);
        self.scene = created;
        break :blk created;
    };
    // The library classifies a tracked surface's output placement through
    // the compositor's own rules, so membership, presented lists and
    // damage agree with what the canvas pass draws. Idempotent: the
    // second output finds the scene already there.
    installScenePlacementPolicy(self);

    // M3: expose the output to clients (geometry/mode/scale/name). The
    // output's destroy signal owns this global, so the view never frees
    // it by hand.
    const wl_output = wayland.wl_output.WlOutput.create(
        self.allocator,
        self.io,
        self.log_cfg,
        self.display,
        out,
        "WL-1",
        "wayland debug output",
    ) catch |err| {
        log.err("wl_output create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return null;
    };

    const scene_output = wayland.scene.SceneOutput.create(
        self.allocator,
        self.io,
        self.log_cfg,
        scene,
        out,
    ) catch |err| {
        log.err("scene output init failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return null;
    };

    const framebuffer = pixman.Framebuffer.create(self.allocator, out.mode.width, out.mode.height) catch |err| {
        log.err("framebuffer create failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        scene_output.destroy();
        return null;
    };

    // The view's slice of the desktop. Appended at the RIGHT END of the
    // current extent and never moved afterwards, so adding or removing an
    // output leaves every other view's rect, camera and targets exactly
    // as they were — the property the hotplug requirement is about. A
    // removal leaves its column unused rather than shifting the rest.
    var origin_x: i32 = 0;
    for (self.output_views.items) |other| {
        origin_x = @max(origin_x, other.rect.x + other.rect.width);
    }
    const rect: geom.Rect = .{
        .x = origin_x,
        .y = 0,
        .width = out.mode.width,
        .height = out.mode.height,
    };

    // M4 camera, parsed with THIS output's real size (the DRM mode can
    // differ from the 1280x720 defaults) and then shifted into scene
    // space by the view's desktop origin: the camera's world space is the
    // shared scene, not the view's local canvas.
    const local = parseCameraEnv(self.camera_env, out.mode.width, out.mode.height);
    const camera: Camera = .{
        .center_x = local.center_x + @as(f64, @floatFromInt(rect.x)),
        .center_y = local.center_y + @as(f64, @floatFromInt(rect.y)),
        .zoom = local.zoom,
        .rotation = local.rotation,
        .screen_w = local.screen_w,
        .screen_h = local.screen_h,
    };

    const view = self.allocator.create(OutputView) catch |err| {
        log.err("output view alloc failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        framebuffer.deinit();
        scene_output.destroy();
        return null;
    };
    view.* = .{
        .state = self,
        .allocator = self.allocator,
        .io = self.io,
        .log_cfg = self.log_cfg,
        .output = out,
        .wl_output = wl_output,
        .scene_output = scene_output,
        .rect = rect,
        .camera = camera,
        .last_camera = camera,
        .framebuffer = framebuffer,
        .gpu = self.gpu_scanout,
        .frame_listener = wire.Listener(*wayland.output.Output).init(onViewFrame),
        .commit_listener = wire.Listener(*wayland.output.Output.CommitEvent).init(onViewCommit),
        .destroy_listener = wire.Listener(*wayland.output.Output).init(onViewDestroyed),
    };
    // The library's output view reads the camera and the wl_output it
    // reports on: output membership (the camera's visible world rect) and
    // the surface enter/leave wire events both come from here.
    scene_output.camera = &view.camera;
    scene_output.wl_output = wl_output;
    scene_output.x = @floatFromInt(rect.x);
    scene_output.y = @floatFromInt(rect.y);

    out.events.frame.add(&view.frame_listener);
    out.events.commit.add(&view.commit_listener);
    out.events.destroy.add(&view.destroy_listener);
    self.output_views.append(self.allocator, view) catch |err| {
        log.err("output view list append failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        unlinkViewListeners(view);
        scene_output.destroy();
        framebuffer.deinit();
        self.allocator.destroy(view);
        return null;
    };
    // The desktop grew by this column, so absolute input devices now
    // normalize onto a different extent.
    syncInputExtent(self);

    // The seat's pointer cursor is a single object for the whole session
    // (one pointer, one image) built against the shared scene; only its
    // DRAW is per view.
    if (self.cursor == null) {
        self.cursor = wayland.cursor.Cursor.create(
            self.allocator,
            self.io,
            self.log_cfg,
            scene,
            self.compositor,
            self.seat,
            // The pixman renderer, never `self.renderer`: the cursor's
            // CPU textures are imported through PixmanRenderer
            // (cursor.zig:260, :337), so under WAYLAND_RENDERER=gles2 the
            // two are different objects.
            self.pixman_renderer,
        ) catch |err| blk: {
            log.err("cursor init failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            break :blk null;
        };
    }
    log.info("output view at desktop ({d},{d}) {d}x{d}{s}", self.io, self.log_cfg, "server", .{
        rect.x, rect.y, rect.width, rect.height, if (view.gpu) ", gpu scanout" else "",
    });
    return view;
}

/// The view for `out`, or null when this backend output has none (a
/// view whose creation failed, or one already torn down).
fn viewForOutput(self: *ServerState, out: *wayland.output.Output) ?*OutputView {
    for (self.output_views.items) |v| {
        if (v.output == out) return v;
    }
    return null;
}

/// The view a global DESKTOP pixel belongs to: the one whose layout rect
/// contains it, else the nearest by centre distance, else the first.
/// Every input path (pointer, touch, tablet) resolves its coordinates
/// through this before any camera is consulted, so a position outside
/// every output still lands on a real view instead of being clamped.
fn viewAtGlobalPoint(self: *ServerState, x: i32, y: i32) ?*OutputView {
    var best: ?*OutputView = null;
    var best_distance: i64 = std.math.maxInt(i64);
    for (self.output_views.items) |v| {
        if (v.rect.containsPoint(.{ .x = x, .y = y })) return v;
        const cx = v.rect.x + @divTrunc(v.rect.width, 2);
        const cy = v.rect.y + @divTrunc(v.rect.height, 2);
        const dx = @as(i64, x) - cx;
        const dy = @as(i64, y) - cy;
        const d = dx * dx + dy * dy;
        if (d < best_distance) {
            best_distance = d;
            best = v;
        }
    }
    return best;
}

/// The view whose camera can SEE the world point: the first whose
/// visible world rect contains it, else null. Input that starts from a
/// world coordinate rather than a pixel — the synthesized click — has to
/// go through this, because the world is one space and each output is
/// only a window onto it. Converting through the wrong output's camera
/// puts the pointer somewhere the user is not looking.
fn viewSeeingWorldPoint(self: *ServerState, p: geom.FPoint) ?*OutputView {
    for (self.output_views.items) |view| {
        if (view.scene_output.visibleWorldRect().containsPoint(p.x, p.y)) return view;
    }
    return null;
}

/// The view a compositor gesture and new-surface placement act on: the
/// one under the pointer, else the one the live gesture pinned, else the
/// first. This is what "the selected output" means now that there is no
/// single output.
///
/// NULL when the desktop has no output at all — every connector gone,
/// before the first one arrives. There is no "first" to fall back to
/// then, and indexing an empty list is the crash an unplug of the last
/// output used to be. Every caller treats null as "place it nowhere for
/// now": a client can still map and be configured, and the surface is
/// placed on the next output that appears.
fn selectedView(self: *ServerState) ?*OutputView {
    if (self.output_views.items.len == 0) return null;
    if (self.gestures.view) |v| {
        if (std.mem.indexOfScalar(*OutputView, self.output_views.items, v) != null) return v;
    }
    if (viewAtGlobalPoint(self, self.seat.pointer_x, self.seat.pointer_y)) |v| return v;
    return self.output_views.items[0];
}

/// The view `surface`'s node is placed on: its recorded placement when
/// that view is still live, else the selected view (a new surface goes
/// where the user is looking).
fn viewForSurface(self: *ServerState, surface: *Surface) ?*OutputView {
    if (self.surface_place.get(surface)) |place| {
        if (std.mem.indexOfScalar(*OutputView, self.output_views.items, place.view) != null) return place.view;
    }
    return selectedView(self);
}

/// Put every tracked surface's tree on its view's desktop origin.
///
/// Scene space is the desktop, so a plain surface's tree — the container
/// SurfaceNode puts under the scene root — carries the view's origin and
/// the surface's own canvas-local position (0,0 to start, then whatever
/// the interactive move made of it). Run once per frame and after every
/// view change; a surface whose view disappeared loses its placement and
/// lands on the selected one.
fn syncSurfacePlacement(self: *ServerState) void {
    const scene = self.scene orelse return;
    var it = scene.surface_nodes.valueIterator();
    while (it.next()) |sn| {
        const surface = sn.*.surface;
        if (self.surface_place.getPtr(surface)) |place| {
            // The placed view is gone (unplug): drop the placement so the
            // surface is re-homed on the next pass.
            if (std.mem.indexOfScalar(*OutputView, self.output_views.items, place.view) == null) {
                _ = self.surface_place.remove(surface);
                continue;
            }
            // The node was destroyed by an unmap: re-apply on remap.
            if (place.placed and sn.*.node == null) place.placed = false;
        } else {
            const view = selectedView(self) orelse return;
            self.surface_place.put(self.allocator, surface, .{ .view = view }) catch |err| {
                log.warn("surface placement OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
                return;
            };
        }
        const entry = self.surface_place.getPtr(surface) orelse continue;
        if (entry.placed) continue;
        const tree = sn.*.tree orelse continue;
        tree.setPosition(
            @as(f64, @floatFromInt(entry.view.rect.x)),
            @as(f64, @floatFromInt(entry.view.rect.y)),
        );
        entry.placed = true;
    }
}

/// Output.events.frame for one view: this view's render entry point.
fn onViewFrame(listener: *wire.Listener(*wayland.output.Output), _: *wayland.output.Output) void {
    const view: *OutputView = @fieldParentPtr("frame_listener", listener);
    renderFrame(view);
}

/// Output.events.destroy for one view: the backend took the output away
/// (connector unplug, modeset, backend teardown). Free this view's
/// targets, drop it from the layout and hand its surfaces back to the
/// remaining views. NO other view's camera, target, damage or pacing is
/// touched, and a gesture pinned to it is ended rather than left
/// dangling on freed memory.
fn onViewDestroyed(listener: *wire.Listener(*wayland.output.Output), out: *wayland.output.Output) void {
    const view: *OutputView = @fieldParentPtr("destroy_listener", listener);
    log.info("output removed ({d}x{d})", view.io, view.log_cfg, "server", .{
        out.mode.width, out.mode.height,
    });
    removeOutputView(view.state, view);
}

/// Forget `view`: its targets and its place in the layout. The output
/// itself is NOT freed here — the backend owns it and is about to.
fn removeOutputView(self: *ServerState, view: *OutputView) void {
    // A gesture pinned to the view that is going away must be ended NOW,
    // while the view is still readable: its release path reads the view.
    if (self.gestures.view == view) _ = endPointerGestures(self.seat, &self.gestures);

    unlinkViewListeners(view);
    view.freeTargets();
    // The library's view holds borrowed camera/wl_output pointers into
    // this struct and its output; dropping it now stops any surface
    // membership test from reading them.
    view.scene_output.destroy();

    if (std.mem.indexOfScalar(*OutputView, self.output_views.items, view)) |idx| {
        _ = self.output_views.orderedRemove(idx);
    }
    // Only the DEAD view's placements are dropped. Every survivor keeps
    // the view it was placed on, where it sits and the size it was
    // configured for: an unplug is not a relayout, and clearing the whole
    // table re-homed every window on the next pass.
    var it = self.surface_place.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.view == view) {
            self.surface_place.removeByPtr(entry.key_ptr);
        }
    }
    // The desktop extent absolute input devices are normalized onto just
    // changed shape.
    syncInputExtent(self);
    self.allocator.destroy(view);
    // Whatever is left has to repaint: the desktop just lost a column.
    requestRender(self);
}

/// Output.events.commit for one view: a MODE change resizes this view's
/// slice of the desktop. The view's ORIGIN never moves — the layout is
/// append-only and a removal leaves its column unused — so a surviving
/// output keeps both its position and its pixels across any other
/// output's change. What does move is the size the compositor draws
/// into and the extent absolute input devices are normalized onto.
fn onViewCommit(
    listener: *wire.Listener(*wayland.output.Output.CommitEvent),
    ev: *wayland.output.Output.CommitEvent,
) void {
    const view: *OutputView = @fieldParentPtr("commit_listener", listener);
    const w = ev.output.mode.width;
    const h = ev.output.mode.height;
    // The common case: every present carries the mode we already have.
    if (view.rect.width == w and view.rect.height == h) return;
    view.rect.width = w;
    view.rect.height = h;
    // The camera's viewport follows the mode. Its centre stays where the
    // user (or WAYLAND_CAMERA) put it: a mode change is not a camera
    // change, and re-centring would silently move the canvas.
    view.camera.screen_w = @as(f64, @floatFromInt(w));
    view.camera.screen_h = @as(f64, @floatFromInt(h));
    resizeFramebuffers(view);
    // Every pixel of a resized output is new, and cameraChanged() only
    // compares centre/zoom/rotation, so the whole-output invalidation
    // is stated here rather than inferred from the camera.
    view.scene_output.addDamage(OutputView.localRect(view));
    syncInputExtent(view.state);
    requestRenderView(view.state, view);
}

/// Re-create this view's CPU storage after a mode change. The scanout
/// buffer must match the mode the output scans out or the commit hands
/// the backend the wrong geometry; the persisted base, both capture
/// buffers and the cached per-slot GL images are dropped so the next
/// frame rebuilds them at the new size. The CPU-scanout GLES2 FBO is
/// already size-checked where it is used (ensureGles2Target).
fn resizeFramebuffers(view: *OutputView) void {
    const w = view.output.mode.width;
    const h = view.output.mode.height;
    const fb = pixman.Framebuffer.create(view.allocator, w, h) catch |err| {
        // Keep the old buffer: this output simply keeps its previous size
        // until a later mode change succeeds, and the frame is dropped
        // rather than the server faulting.
        log.err("framebuffer resize failed: {s}", view.io, view.log_cfg, "server", .{@errorName(err)});
        return;
    };
    view.framebuffer.deinit();
    view.framebuffer = fb;
    if (view.base_framebuffer) |base| {
        base.deinit();
        view.base_framebuffer = null;
    }
    if (view.capture_base) |base| {
        base.deinit();
        view.capture_base = null;
    }
    if (view.capture_frame) |frame| {
        frame.deinit();
        view.capture_frame = null;
    }
    view.capture_base_valid = false;
    view.capture_frame_valid = false;
    for (&view.gpu_targets) |*slot| {
        if (slot.*) |target| target.destroy();
        slot.* = null;
    }
}

/// Publish the current desktop extent to the input backend: the bounding
/// box of the output layout, which is what an absolute pointer or tablet
/// tool is normalized against (libinput reports a fraction of the screen
/// it was given; LibinputBackend.setDesktopSize supplies it).
///
/// The layout never moves an existing view — an output is appended at
/// the right end and a removal leaves its column unused — so this only
/// ever changes the extent, never the pixels a survivor occupies. With
/// no output at all there is no desktop to report into, and the last
/// published extent stays until a connector comes back.
fn syncInputExtent(self: *ServerState) void {
    const backend = self.input_backend orelse return;
    if (self.output_views.items.len == 0) return;
    var width: i32 = 0;
    var height: i32 = 0;
    for (self.output_views.items) |view| {
        width = @max(width, view.rect.x + view.rect.width);
        height = @max(height, view.rect.y + view.rect.height);
    }
    if (width <= 0 or height <= 0) return;
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    if (w == self.input_extent_w and h == self.input_extent_h) return;
    self.input_extent_w = w;
    self.input_extent_h = h;
    libinput_mod.LibinputBackend.setDesktopSize(backend, w, h);
}

/// Detach a view's listeners, idempotently (teardown reaches them twice).
fn unlinkViewListeners(view: *OutputView) void {
    if (view.frame_listener.link.prev != null) view.frame_listener.link.remove();
    if (view.destroy_listener.link.prev != null) view.destroy_listener.link.remove();
    if (view.commit_listener.link.prev != null) view.commit_listener.link.remove();
}

/// Free every output view and empty the list (the event loop is over).
fn freeOutputViews(self: *ServerState) void {
    for (self.output_views.items) |view| {
        unlinkViewListeners(view);
        view.freeTargets();
        view.scene_output.destroy();
        self.allocator.destroy(view);
    }
    self.output_views.deinit(self.allocator);
    self.output_views = .empty;
    self.gestures.view = null;
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
    request_maximize: wire.Listener(*wayland.shell.XdgToplevel),
    request_fullscreen: wire.Listener(*wayland.shell.FullscreenRequest),
    request_move: wire.Listener(*wayland.shell.MoveRequest),
    initial_commit: wire.Listener(*wayland.shell.XdgToplevel),
    destroy: wire.Listener(*wayland.shell.XdgToplevel),
};

fn onToplevelTitle(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("set_title", listener);
    log.info("toplevel title changed: {s}", tl.state.io, tl.state.log_cfg, "server", .{t.title orelse "(none)"});
}

/// X08: the client performed the initial commit; the compositor replies
/// with the configure (the module never self-configures). 0,0 = "client
/// decides" (wlroots tinywl does the same on the initial commit).
///
/// The activation state is seeded here, not only in the seat's focus
/// signal. A role object may be a RE-CREATION on a wl_surface that still
/// holds the keyboard: a client may destroy xdg_toplevel and call
/// get_toplevel again on the same xdg_surface (xdg-shell.xml:637-641),
/// Seat.setKeyboardFocus early-returns on an unchanged focus
/// (seat.zig:1238), and the role destroy unmaps without touching the seat
/// (xdg.zig:1328-1329). Nothing moves, so the keyboard_focus signal never
/// fires and the only publisher of wl_toplevel.activated never runs for
/// the new role: it would configure activated=false forever and its CSD
/// would paint an inactive titlebar on the window that has the keyboard.
///
/// Seeding BEFORE the pass below means the pass sees this toplevel's
/// scheduled state already correct, skips it, and reconfigures only the
/// OTHER windows whose activation really flipped — so the activation
/// lands in the single configure the initial commit is entitled to.
fn onToplevelInitialCommit(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("initial_commit", listener);
    const self = tl.state;
    t.scheduled.activated = toplevelIsActivated(self, self.seat, t.xdg_surface.surface);
    syncToplevelActivation(self, self.seat);
    t.scheduleConfigure() catch {
        log.warn("initial toplevel configure failed", self.io, self.log_cfg, "server", .{});
    };
}

fn onToplevelAppId(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("set_app_id", listener);
    log.info("toplevel app_id changed: {s}", tl.state.io, tl.state.log_cfg, "server", .{t.app_id orelse "(none)"});
}

/// The output's FULL box (its mode rect at the local origin): the area a
/// fullscreen surface covers. Distinct from usableArea — a fullscreen
/// window covers panels, only a maximized one does not (wlroots keeps
/// the full and the usable box apart, types/wlr_output.c:1106-1114;
/// tinywl answers set_fullscreen with the full output size and
/// set_maximized with the usable area, tinywl.c handle_toplevel_configure).
///
/// `named` is the wl_output resource the client asked for; it belongs to
/// this compositor only when some view's WlOutput owns it (a resource of
/// a foreign global is ignored — the same identity check screencopy uses).
/// With no usable name the answer is the output the SURFACE is on, which
/// is what wlroots falls back to (the output containing the surface).
fn fullscreenBox(
    self: *ServerState,
    surface: ?*Surface,
    named: ?*wayland.server.wl.Output,
) ?geom.Rect {
    if (named) |res| {
        for (self.output_views.items) |view| {
            if (view.wl_output.owns(res)) return outputRect(view.output);
        }
    }
    if (surface) |s| {
        if (viewForSurface(self, s)) |view| return outputRect(view.output);
    }
    if (selectedView(self)) |view| return outputRect(view.output);
    return null;
}

/// The output's mode rect at ITS OWN origin: (0,0) to the mode size. The
/// configure sizes a maximized/fullscreen surface needs are output-local
/// (the surface lives in this output's canvas), which is why the desktop
/// layout origin never appears here.
fn outputRect(out: *wayland.output.Output) geom.Rect {
    return .{ .x = 0, .y = 0, .width = out.mode.width, .height = out.mode.height };
}

/// The view's USABLE area: its mode rect shrunk by every exclusive zone
/// the layer shell reserved ON THAT VIEW (wlroots wlr_output usable_area,
/// types/wlr_output.c:1106-1114 — a mapped layer surface's exclusive zone
/// takes its edge off the usable area, which is exactly why a maximized
/// window must not hide under a panel). A negative zone reserves the layer
/// surface's own extent along that edge (wlr_layer_surface_v1: a negative
/// zone lets the compositor size it).
///
/// A reserved strip comes off BOTH ends of the axis it sits on: the top
/// strip moves the origin down AND takes its pixels off the height (a
/// rect that only moved its origin would still run off the bottom of the
/// output). wlroots applies the reservation through the same two-sided
/// shrink — `wlr_output_layout` reserves each edge with
/// `output_layout_reserve` semantics, where a top reservation shifts
/// `usable.y` and subtracts from `usable.height`
/// (types/wlr_output_layout.c, `wlr_output_layout_get_usable_area`).
///
/// Only layer surfaces PLACED ON THIS VIEW shrink it: a panel on the second
/// output must not resize a window maximized on the first.
fn usableArea(self: *ServerState, view: *OutputView) geom.Rect {
    var area = outputRect(view.output);
    for (self.layer_shell.layer_surfaces.items) |ls| {
        const surface = ls.surface;
        if ((viewForSurface(self, surface) orelse continue) != view) continue;
        const edge = ls.exclusiveEdge() orelse continue;
        const px: i32 = if (ls.current.exclusive_zone > 0)
            ls.current.exclusive_zone
        else switch (edge) {
            .top, .bottom => @intCast(ls.current.actual_height),
            .left, .right => @intCast(ls.current.actual_width),
        };
        if (px <= 0) continue;
        switch (edge) {
            .top => {
                area.y += px;
                area.height -= px;
            },
            .bottom => area.height -= px,
            .left => {
                area.x += px;
                area.width -= px;
            },
            .right => area.width -= px,
        }
    }
    return area;
}

/// xdg_toplevel.set_maximized / unset_maximized (P1-8). The client
/// request is a REQUEST (xdg-shell.xml set_maximized: "Asks the window
/// manager to maximize the surface"), so the compositor answers with a
/// configure carrying the state it agrees with — never silence, which
/// left the client waiting for a configure forever (a protocol deadlock:
/// xdg_toplevel has no "request was denied" event).
///
/// Policy: the compositor imposes no size constraints, so it agrees, and
/// configures the surface to the USABLE area of THE OUTPUT THE SURFACE IS
/// ON (usableArea) — the answer tinywl gives (tinywl.c
/// handle_toplevel_configure sends the usable width/height for a maximized
/// surface). Unmaximizing hands the size back to the client: the protocol
/// has no "restore size" state and this server stores no pre-maximize
/// geometry, so 0,0 ("client decides", xdg_toplevel.configure
/// width/height) is the honest answer.
fn onToplevelMaximize(
    listener: *wire.Listener(*wayland.shell.XdgToplevel),
    t: *wayland.shell.XdgToplevel,
) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_maximize", listener);
    const self = tl.state;
    // The module stored the request in `pending` before emitting
    // (xdg.zig:1231-1238); the compositor decides, so `scheduled` is what
    // this handler writes.
    const maximize = t.pending.maximized;
    if (maximize) {
        // A fullscreen surface covers the FULL output box whatever the
        // maximize request says: xdg-shell.xml:1049-1051 — set_maximized
        // "has no direct effect" while the surface is fullscreen — and
        // xdg-shell.xml:850-854 requires a fullscreened surface to be able
        // to cover the fullscreened area. So the STATE is recorded (a later
        // un-fullscreen needs it) and the GEOMETRY is left as the
        // fullscreen handler wrote it: the usable area would pull the
        // window out from under the panel a fullscreen window covers.
        if (!t.scheduled.fullscreen) {
            if (viewForSurface(self, t.xdg_surface.surface)) |view| {
                const usable = usableArea(self, view);
                t.scheduled.width = usable.width;
                t.scheduled.height = usable.height;
            }
        }
    } else {
        t.scheduled.width = 0;
        t.scheduled.height = 0;
    }
    t.scheduled.maximized = maximize;
    log.info("toplevel maximize -> {s} ({d}x{d})", self.io, self.log_cfg, "server", .{
        if (maximize) "on" else "off",
        t.scheduled.width,
        t.scheduled.height,
    });
    t.scheduleConfigure() catch {
        log.warn("toplevel maximize configure failed", self.io, self.log_cfg, "server", .{});
    };
}

/// xdg_toplevel.set_fullscreen / unset_fullscreen (P1-8 + F10). The
/// same request/answer contract as maximize, with the FULL box of the
/// output the client NAMED, of the one the surface is on, or of the
/// selected view — in that order (fullscreen covers panels, wlroots /
/// tinywl.c handle_toplevel_configure).
fn onToplevelFullscreen(
    listener: *wire.Listener(*wayland.shell.FullscreenRequest),
    req: *wayland.shell.FullscreenRequest,
) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_fullscreen", listener);
    const self = tl.state;
    const t = req.toplevel;
    t.scheduled.fullscreen = req.fullscreen;
    // Leaving fullscreen hands the size back to the client (same reason as
    // unmaximize: no stored pre-fullscreen geometry to restore) — unless
    // the window is STILL maximized, in which case the box that maximizes
    // means is the answer, exactly as onToplevelMaximize wrote it. 0x0
    // would tell the client to pick its own size for a state it was just
    // told it has, and discard a geometry the two handlers otherwise
    // disagree about.
    t.scheduled.width = 0;
    t.scheduled.height = 0;
    if (req.fullscreen) {
        if (fullscreenBox(self, t.xdg_surface.surface, req.output)) |box| {
            t.scheduled.width = box.width;
            t.scheduled.height = box.height;
        }
    } else if (t.scheduled.maximized) {
        if (viewForSurface(self, t.xdg_surface.surface)) |view| {
            const usable = usableArea(self, view);
            t.scheduled.width = usable.width;
            t.scheduled.height = usable.height;
        }
    }
    log.info("toplevel fullscreen -> {s} ({d}x{d})", self.io, self.log_cfg, "server", .{
        if (req.fullscreen) "on" else "off",
        t.scheduled.width,
        t.scheduled.height,
    });
    t.scheduleConfigure() catch {
        log.warn("toplevel fullscreen configure failed", self.io, self.log_cfg, "server", .{});
    };
}

/// xdg_toplevel.set_minimized (P1-8). The protocol carries no minimized
/// STATE (xdg-shell.xml set_minimized: "There is no way to tell the
/// client that it is minimized"), so the compositor records the request —
/// the module keeps it in ToplevelState.minimized for exactly this — and
/// takes the surface off screen: a minimized window is a window the user
/// cannot see. This server has no iconifier to un-hide it, so the window
/// comes back when the client commits again (surfaceNodeBeforeUpdate
/// re-enables the container this hid).
fn onToplevelMinimize(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_minimize", listener);
    const self = tl.state;
    log.info("toplevel minimize requested (recorded)", self.io, self.log_cfg, "server", .{});
    const scene = self.scene orelse return;
    const sn = wayland.surface_node.surfaceNodeFor(scene, t.xdg_surface.surface) orelse return;
    // The surface's CONTAINER, not its buffer node: a minimized window
    // takes its popups and subsurfaces down with it, which is what the
    // canvas pass prunes on (a disabled subtree is skipped whole) and
    // what the hit test already skipped.
    if (sn.tree) |tree| {
        tree.enable(false);
    } else if (sn.node) |node| {
        // Unmapped: no container exists yet, so there is no subtree.
        node.enable(false);
    }
    // A window that vanishes leaves its pixels behind on EVERY camera
    // that could see it — which, now that membership is the camera's
    // visible world rect, is not only the output it was placed on.
    var damaged = false;
    if (sn.node) |node| {
        const rect = node.absolutePosition();
        for (self.output_views.items) |view| {
            if (!view.scene_output.visibleWorldRect().intersects(rect)) continue;
            view.scene_output.addDamage(OutputView.localRect(view));
            requestRenderView(self, view);
            damaged = true;
        }
    }
    if (!damaged) requestRender(self);
}

fn onToplevelMove(listener: *wire.Listener(*wayland.shell.MoveRequest), req: *wayland.shell.MoveRequest) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_move", listener);
    const self = tl.state;
    const seat = req.seat;
    // ext_session_lock_manager_v1: a locked session is the lock client's,
    // not the compositor's gestures'. The move installs the swallow grab,
    // and the release that would end it is gated on the lock itself
    // (onSeatButton), so a move armed here swallows the lock screen's
    // pointer for the rest of the locked session — no motion, no click,
    // and no release that can ever clear it (ext_session_lock_v1:81-84:
    // the lock client must be the only input destination). The request is
    // REFUSED, not deferred: xdg-shell.xml:761-763 lets the server ignore
    // a move request, and nothing replays it after the unlock.
    if (self.session_lock) |sl| {
        if (sl.isLocked()) return;
    }
    const toplevel_client = req.toplevel.xdg_surface.surface.resource.getClient();
    // The serial must be a recent input-event serial on the request's seat
    // (wlroots wlr_xdg_toplevel_move validates the same way).
    if (!seat.validateEventSerial(toplevel_client, req.serial)) return;
    // The move owns the gesture: cancel any armed camera drag.
    self.gestures.camera_drag = null;
    self.gestures.drag_active = false;
    self.gestures.fast_render = false;
    self.gestures.moving_toplevel = req.toplevel;
    // PIN the gesture to the output the pointer is on, and convert the
    // pointer through THAT view's camera: the drag then moves the window in
    // the output it started in, in that output's own units.
    const view = viewAtGlobalPoint(self, seat.pointer_x, seat.pointer_y) orelse return;
    self.gestures.view = view;
    const wp = screenToWorldIn(view, seat.pointer_x, seat.pointer_y);
    self.gestures.move_anchor = .{ .x = wp.x, .y = wp.y };
    grabPointerForGesture(seat, &self.gestures);
    const surface_id = req.toplevel.xdg_surface.surface.resource.getId();
    log.info("interactive move start surface@{d}", self.io, self.log_cfg, "server", .{surface_id});
}

fn onToplevelDestroy(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("destroy", listener);
    // The moved toplevel died mid-gesture: end the move and release
    // OUR grab so the pointer returns to the clients (a grab another
    // subsystem installed since the move survives — PointerGestures).
    if (tl.state.gestures.moving_toplevel == t) {
        _ = endPointerGestures(tl.state.seat, &tl.state.gestures);
        log.info("interactive move cancelled (toplevel destroyed)", tl.state.io, tl.state.log_cfg, "server", .{});
    }
    tl.set_title.link.remove();
    tl.set_app_id.link.remove();
    tl.request_minimize.link.remove();
    tl.request_maximize.link.remove();
    tl.request_fullscreen.link.remove();
    tl.request_move.link.remove();
    tl.initial_commit.link.remove();
    tl.destroy.link.remove();
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
        .request_maximize = wire.Listener(*wayland.shell.XdgToplevel).init(onToplevelMaximize),
        .request_fullscreen = wire.Listener(*wayland.shell.FullscreenRequest).init(onToplevelFullscreen),
        .request_move = wire.Listener(*wayland.shell.MoveRequest).init(onToplevelMove),
        .initial_commit = wire.Listener(*wayland.shell.XdgToplevel).init(onToplevelInitialCommit),
        .destroy = wire.Listener(*wayland.shell.XdgToplevel).init(onToplevelDestroy),
    };
    t.events.set_title.add(&tl.set_title);
    t.events.set_app_id.add(&tl.set_app_id);
    t.events.request_minimize.add(&tl.request_minimize);
    t.events.request_maximize.add(&tl.request_maximize);
    t.events.request_fullscreen.add(&tl.request_fullscreen);
    t.events.request_move.add(&tl.request_move);
    t.events.initial_commit.add(&tl.initial_commit);
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
    // dimensions — the SELECTED view's mode size is the fallback the
    // module uses in the initial configure, so a panel created while the
    // pointer is on the second output is sized for that output.
    if (selectedView(self)) |view| {
        ls.setFallbackSize(@intCast(view.output.mode.width), @intCast(view.output.mode.height));
    }
    // L-D6: the compositor drives the initial configure. One heap struct
    // per layer surface (freed by its destroy listener).
    const ll = self.allocator.create(LayerListeners) catch |err| {
        log.warn("failed to allocate layer listeners: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    ll.* = .{
        .state = self,
        .initial_commit = wire.Listener(*wayland.layer_shell.LayerSurface).init(onLayerInitialCommit),
        .destroy = wire.Listener(*wayland.layer_shell.LayerSurface).init(onLayerDestroy),
    };
    ls.events.initial_commit.add(&ll.initial_commit);
    ls.events.destroy.add(&ll.destroy);
    log.info("new layer surface (namespace={s} layer={d}) total={d}", self.io, self.log_cfg, "server", .{
        ls.namespace orelse "(none)",
        @backingInt(ls.current.layer),
        self.layer_surfaces.items.len,
    });
}

/// Per-layer-surface listeners (L-D6): heap-allocated in onNewLayerSurface,
/// freed by onLayerDestroy.
const LayerListeners = struct {
    state: *ServerState,
    initial_commit: wire.Listener(*wayland.layer_shell.LayerSurface),
    destroy: wire.Listener(*wayland.layer_shell.LayerSurface),
};

fn onLayerInitialCommit(
    listener: *wire.Listener(*wayland.layer_shell.LayerSurface),
    ls: *wayland.layer_shell.LayerSurface,
) void {
    _ = listener;
    // L-D6: the compositor replies to the initial commit with the arrange
    // (the module never self-configures).
    ls.arrange();
}

fn onLayerDestroy(
    listener: *wire.Listener(*wayland.layer_shell.LayerSurface),
    ls: *wayland.layer_shell.LayerSurface,
) void {
    _ = ls;
    const ll: *LayerListeners = @fieldParentPtr("destroy", listener);
    ll.initial_commit.link.remove();
    ll.destroy.link.remove();
    ll.state.allocator.destroy(ll);
}

/// zwlr_layer_shell_v1 events.new_popup (L1): an xdg_popup was parented to
/// a layer surface via get_popup. Tracked for observability only — NO
/// anchoring or placement policy here (layer-popup layout is compositor
/// policy, out of scope like layer-surface layout; see
/// notes/129-layer-shell-impl.md). Mirrors onNewLayerSurface.
fn onNewLayerPopup(listener: *wire.Listener(*wayland.shell.XdgPopup), p: *wayland.shell.XdgPopup) void {
    const self: *ServerState = @fieldParentPtr("new_layer_popup_listener", listener);
    self.layer_popups.append(self.allocator, p) catch |err| {
        log.warn("failed to track layer popup: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
    };
    log.info("new layer popup on wl_surface {*} total={d}", self.io, self.log_cfg, "server", .{
        p.xdg_surface.surface,
        self.layer_popups.items.len,
    });
}

fn onNewPopup(listener: *wire.Listener(*wayland.shell.XdgPopup), p: *wayland.shell.XdgPopup) void {
    const self: *ServerState = @fieldParentPtr("new_popup_listener", listener);
    // F1: the compositor supplies the usable area for popup placement —
    // the mode rect of the output the PARENT surface is on, in that
    // output's own coordinates. The popup configure then applies the
    // client's constraint_adjustment bits (flip/slide/resize) to stay
    // inside it. A popup on the second output is bounded by the second
    // output, not by whichever one happens to be first.
    const parent_surface = if (p.parent) |px| px.surface else p.layer_parent;
    if (parent_surface) |ps| {
        if (viewForSurface(self, ps)) |view| {
            p.setConstraintBox(.{
                .x = 0,
                .y = 0,
                .width = view.output.mode.width,
                .height = view.output.mode.height,
            });
        }
    }
    // X08: the compositor drives the initial configure. One heap struct
    // per popup (freed by its destroy listener).
    const pl = self.allocator.create(PopupListeners) catch |err| {
        log.warn("failed to allocate popup listeners: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return;
    };
    pl.* = .{
        .state = self,
        .initial_commit = wire.Listener(*wayland.shell.XdgPopup).init(onPopupInitialCommit),
        .destroy = wire.Listener(*wayland.shell.XdgPopup).init(onPopupDestroy),
    };
    p.events.initial_commit.add(&pl.initial_commit);
    p.events.destroy.add(&pl.destroy);
    log.info("new popup at {d},{d} {d}x{d}", self.io, self.log_cfg, "server", .{
        p.geometry.x, p.geometry.y, p.geometry.width, p.geometry.height,
    });
}

/// Per-popup listeners (X08): heap-allocated in onNewPopup, freed by
/// onPopupDestroy.
const PopupListeners = struct {
    state: *ServerState,
    initial_commit: wire.Listener(*wayland.shell.XdgPopup),
    destroy: wire.Listener(*wayland.shell.XdgPopup),
};

fn onPopupInitialCommit(listener: *wire.Listener(*wayland.shell.XdgPopup), p: *wayland.shell.XdgPopup) void {
    const pl: *PopupListeners = @fieldParentPtr("initial_commit", listener);
    p.scheduleConfigure() catch {
        log.warn("initial popup configure failed", pl.state.io, pl.state.log_cfg, "server", .{});
    };
}

fn onPopupDestroy(listener: *wire.Listener(*wayland.shell.XdgPopup), p: *wayland.shell.XdgPopup) void {
    _ = p;
    const pl: *PopupListeners = @fieldParentPtr("destroy", listener);
    pl.initial_commit.link.remove();
    pl.destroy.link.remove();
    pl.state.allocator.destroy(pl);
}

/// xdg_activation_v1: a client asks to activate a surface (the token
/// was already validated by the activation module). Activation MEANS the
/// keyboard focus on this server, so the request is honored by moving
/// the focus — and the focus change is what publishes
/// wl_toplevel.activated (syncToplevelActivation). Keeping ONE notion of
/// "active" (the seat's) is the point: a second, independently tracked
/// activated flag is what drifts out of sync with the real focus.
fn onRequestActivate(
    listener: *wire.Listener(*wayland.xdg_activation.ActivateRequest),
    req: *wayland.xdg_activation.ActivateRequest,
) void {
    const self: *ServerState = @fieldParentPtr("request_activate_listener", listener);
    log.info("xdg_activation: request_activate surface={*} token={s}", self.io, self.log_cfg, "server", .{
        req.surface, req.token,
    });
    // The COMPOSITE gate, the same one a click goes through
    // (setKeyboardFocusGate in subscribe): the session lock first — while
    // locked only a lock surface of the lock client may hold the keyboard
    // — then L-D7's layer policy. Activation is SELF-SERVICE (a token
    // with no serial validates trivially, xdg_activation.zig:545-558), so
    // a client that consults only the layer half walks straight through
    // the privilege boundary and reads every keystroke typed at the lock
    // screen.
    if (keyboardFocusAllowed(self, req.surface)) {
        self.seat.setKeyboardFocus(req.surface);
    }
}

/// The seat's keyboard focus changed (it fires after the leave/enter/
/// modifiers wire events, seat.zig:1270): republish wl_toplevel.
/// activated for every toplevel whose activated state flipped.
///
/// It is a pure observer: calling setKeyboardFocus from here re-enters the
/// signal being emitted, and wire.Signal.emitInner walks a list whose
/// sentinel is an uninitialized cursor node — the nested emit notifies it
/// as if it were a listener and calls through a garbage function pointer.
/// The session-lock focus re-assertion that belongs on a focus change
/// therefore lives in onSeatButton, on a signal of its own.
fn onSeatKeyboardFocus(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_focus_listener", listener);
    syncToplevelActivation(self, seat);
}

/// The COMPOSITE focus gate decides what `activated` means: a surface
/// that cannot take keyboard focus must never be reported activated,
/// whoever routed the focus at it (the session lock first, then L-D7).
/// Split out of syncToplevelActivation so the initial-commit path asks
/// exactly the same question instead of restating it.
fn toplevelIsActivated(self: *ServerState, seat: *wayland.seat.Seat, surface: *Surface) bool {
    return surface == seat.keyboard_focus and keyboardFocusAllowed(self, surface);
}

/// wl_toplevel.activated follows the seat's KEYBOARD FOCUS (P1-9). The
/// protocol makes it compositor-authored state — xdg_toplevel.state
/// "activated": "the surface ... is the one that has the focus" — and a
/// CSD toolkit renders its active titlebar from it, so a server that
/// never sends it never shows an active titlebar.
///
/// Driven from seat.events.keyboard_focus AND from the initial commit, so
/// a CLICK updates it, not only an xdg_activation request, and a role
/// re-created on a still-focused surface is not left unactivated. Both
/// ends of the change are reconfigured in the same pass: an unfocused
/// window must report activated=false, or the client keeps drawing it
/// active forever.
///
/// The focus gate is re-checked here (toplevelIsActivated): a surface
/// that cannot take keyboard focus must never be reported activated,
/// whoever routed the focus at it.
fn syncToplevelActivation(self: *ServerState, seat: *wayland.seat.Seat) void {
    // shell.toplevels is pruned when a role object is destroyed
    // (xdg.zig:1317-1318), so every entry here is live.
    for (self.shell.toplevels.items) |t| {
        const surface = t.xdg_surface.surface;
        const activated = toplevelIsActivated(self, seat, surface);
        // The module never self-configures: the server writes `scheduled`
        // and schedules the configure, the same contract as the initial
        // commit. Only a CHANGE schedules — the seat emits this signal
        // for every focus change, and re-configuring every window each
        // time would be pure wire traffic.
        if (t.scheduled.activated == activated) continue;
        t.scheduled.activated = activated;
        t.scheduleConfigure() catch {
            log.warn("activation configure failed", self.io, self.log_cfg, "server", .{});
        };
    }
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

/// The compositor's decoration-mode policy (placeholder — the compositor
/// has no real decorations): server-side for the focused toplevel,
/// client-side otherwise. See notes/129-shell-protocols-impl.md.
fn decorationModeFor(
    self: *ServerState,
    dec: *wayland.xdg_decoration.Decoration,
) wayland.server.zxdg.ToplevelDecorationV1.Mode {
    const toplevel = dec.toplevel orelse return .client_side;
    return if (self.seat.keyboard_focus == toplevel.xdg_surface.surface)
        .server_side
    else
        .client_side;
}

fn onDecorationMode(
    listener: *wire.Listener(*wayland.xdg_decoration.RequestMode),
    req: *wayland.xdg_decoration.RequestMode,
) void {
    const self: *ServerState = @fieldParentPtr("request_mode_listener", listener);
    // XD-1: sendConfigure schedules a toplevel configure; the
    // zxdg_toplevel_decoration_v1.configure event rides that
    // xdg_surface.configure/ack_configure cycle (the client applies the
    // mode when it acks).
    const mode = decorationModeFor(self, req.decoration);
    log.info("xdg_decoration: request_mode {s} -> {s}", self.io, self.log_cfg, "server", .{
        modeLabel(req.mode), modeLabel(mode),
    });
    req.decoration.sendConfigure(mode);
}

/// zxdg_decoration_manager_v1 events.new_toplevel_decoration (L2): a
/// client created a decoration. Announce the compositor's initial mode so
/// a client that never sends set_mode still draws the policy chrome
/// (wlroots emits after inserting into manager->decorations,
/// wlr_xdg_decoration_v1.c:237). The announce is idempotent: sendConfigure
/// only schedules the mode; the onSurfaceConfigure dedupe
/// (pending_mode == scheduled_mode) guards repeated configures, and
/// creation fires the signal exactly once per decoration.
fn onNewDecoration(
    listener: *wire.Listener(*wayland.xdg_decoration.Decoration),
    dec: *wayland.xdg_decoration.Decoration,
) void {
    const self: *ServerState = @fieldParentPtr("new_decoration_listener", listener);
    const mode = decorationModeFor(self, dec);
    log.info("xdg_decoration: new decoration, announced {s}", self.io, self.log_cfg, "server", .{
        modeLabel(mode),
    });
    dec.sendConfigure(mode);
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

/// The udev monitor armed beside the libinput device fd became readable:
/// an input device appeared or disappeared. `dispatchHotplug` drains the
/// whole queue (every queued notification, not one per wake), so a burst
/// of udev events is fully consumed before the loop sleeps again.
fn onInputHotplugReady(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    _ = loop;
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    if (self.input_backend) |ib| {
        libinput_mod.LibinputBackend.fromBackend(ib).dispatchHotplug();
        // A removed touchscreen owes its client a wl_touch.cancel, and an
        // added one may announce a new capability: both are marshalled
        // here, so flush for the same reason onInputReady does.
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

/// The logind bus became readable (M6). Draining it runs one
/// suspend/resume step if logind asked for one, entirely non-fatal: a bus
/// error drops the connection and logs, and the compositor keeps running
/// on the card it already has (session.zig's failure policy).
fn onDrmSessionReady(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    _ = loop;
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    if (self.drm_backend) |db| {
        drm_mod.dispatchSession(drm_mod.DrmBackend.fromBackend(db));
    }
}

/// The DRM connector udev monitor became readable: reconcile the output
/// list with the hardware. Non-fatal throughout — one connector that
/// cannot be driven is logged and the rest still are.
fn onDrmHotplugReady(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    _ = loop;
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    if (self.drm_backend) |db| {
        drm_mod.dispatchHotplug(db, drm_mod.DrmBackend.fromBackend(db));
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
    // A surface with a pending wl_surface.frame is ready for the next
    // frame. The idle-frame skip would starve it (foot's render loop waits
    // for the wl_callback.done before drawing + committing its next
    // update), so the views whose canvas is idle present it unchanged to
    // fire the callback. Only when a renderer is otherwise idle — a real
    // change already queues a render that presents everything — and only
    // for a view that actually shows the waiting surface.
    if (self.scene) |scene| {
        var it = scene.surface_nodes.valueIterator();
        while (it.next()) |sn| {
            if (sn.*.surface.current.frame_callbacks.items.len == 0) continue;
            const view = viewForSurface(self, sn.*.surface) orelse continue;
            if (view.repaint_pending or view.in_render) continue;
            view.frame_kick = true;
            requestRenderView(self, view);
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
///   The notch goes through the seat (pointerAxis), so the axis signal
///   zooms the camera (2 -> 2.5 under the E2E).
/// - WAYLAND_SYNTH_INPUT=2 only: everything above, unchanged and once
///   each, PLUS one real pointer motion per distinct committed
///   content/state change (synthPointerMotion). A mode-1 run is not
///   affected in any way.
fn maybeSynthInput(self: *ServerState) void {
    if (!self.synth_input) return;
    // Mode 2 rides on the same dispatch hook, and runs BEFORE the click
    // below: it must see every tracked surface, not only the not-yet-
    // clicked one the M3 click targets, because a client that re-commits
    // the same surface with a new transform or crop is exactly the case a
    // fresh motion exists for.
    if (self.synth_pointer_moves) synthPointerMotion(self);
    // Target every NOT-yet-clicked mapped surface (see synth_clicked):
    // the first client gets the original M3 click+key, later clients
    // (selection roundtrips) get focus + a serial too.
    var target: ?*wayland.scene.SceneNode = null;
    var target_surface: ?*Surface = null;
    if (self.scene) |scene| {
        var entry_it = scene.surface_nodes.valueIterator();
        while (entry_it.next()) |sn| {
            if (sn.*.node != null and
                !self.synth_clicked.contains(sn.*.surface))
            {
                target = sn.*.node;
                target_surface = sn.*.surface;
                break;
            }
        }
    }
    const t = target orelse return;
    const tsurf = target_surface.?;
    const rect = t.absolutePosition();
    // The click is aimed at the node's f64 centre, but the seat takes
    // DESKTOP PIXELS: a world coordinate narrowed straight to i32 is
    // wrong by every zoom and rotation, and off by a billion on a canvas
    // placed far from the origin. So the centre is projected through the
    // camera of the output that can SEE it, and only that screen result
    // is narrowed — the one narrowing this path is allowed.
    const centre = geom.FPoint{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    const view = viewSeeingWorldPoint(self, centre) orelse
        viewForSurface(self, tsurf) orelse
        return;
    const at = view.camera.worldToScreen(centre.x, centre.y);
    const sx: i32 = view.rect.x + @as(i32, @intFromFloat(@floor(at.x)));
    const sy: i32 = view.rect.y + @as(i32, @intFromFloat(@floor(at.y)));
    self.synth_clicked.put(self.allocator, tsurf, {}) catch return;
    const seat = self.seat;
    seat.pointerMotion(sx, sy);
    seat.pointerButton(wayland.seat.btn_left, true);
    seat.pointerButton(wayland.seat.btn_left, false);
    seat.keyEvent(38, true); // 'a' (evdev A + 8)
    seat.keyEvent(38, false);
    log.info("synth input: pointer click + key 'a' at {d},{d}", self.io, self.log_cfg, "server", .{ sx, sy });
    // (the wheel-zoom step follows below, once the first capture is served)
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

/// `*Buffer` as Surface.State stores it.
/// SAFETY: type-derivation only; the undefined value is never evaluated at runtime.
const CommittedBuffer = @TypeOf(@as(Surface, undefined).current.buffer);

/// The committed state a mode-2 synth pointer motion is derived from: the
/// surface's buffer and the three requests that change WHAT it displays
/// (buffer_transform, buffer_scale, wp_viewport). A commit that changes
/// none of them draws the same picture, so it must not draw a fresh
/// motion: the client's own verifyZoom round re-commits identical state,
/// and a motion per commit is a self-triggered motion/commit loop.
///
/// The buffer is compared by identity, not by content. A client that
/// re-attaches the SAME wl_buffer for every case — which the
/// transform matrix does — is caught by the transform, scale or viewport
/// fields instead, because those are what the case actually varies.
const SynthSurfaceState = struct {
    buffer: CommittedBuffer = null,
    transform: geom.Transform = .normal,
    scale: i32 = 1,
    has_src: bool = false,
    src: geom.FRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    has_dst: bool = false,
    dst: geom.Size = .{ .w = 0, .h = 0 },

    fn of(surface: *Surface) SynthSurfaceState {
        const vp = surface.current.viewport;
        return .{
            .buffer = surface.current.buffer,
            .transform = surface.current.transform,
            .scale = surface.current.scale,
            .has_src = vp.has_src,
            .src = vp.src,
            .has_dst = vp.has_dst,
            .dst = vp.dst,
        };
    }
};

/// WAYLAND_SYNTH_INPUT=2: point at the one designated surface whenever it
/// commits something NEW — once per distinct change, never per commit and
/// never per frame (see SynthSurfaceState).
///
/// ONE surface for the whole run, designated the first eligible one to
/// appear. The motion is the acceptance datum for a transform matrix, so
/// it must always describe THE surface whose box the client is about to
/// assert: a popup, a drag icon or a second client committing content
/// must not steal the pointer and leave that assertion reading some other
/// surface's coordinates. The target is released when it leaves the
/// scene, and the next eligible surface takes over.
///
/// Eligibility: ORDINARY world content with a buffer node. An
/// output-local overlay (a layer surface, a lock surface, the drag icon
/// and every descendant composited with one of them) is drawn in its own
/// output's pixels and is not what the matrix exercises; the client's
/// cursor surface is the pointer image itself and must never take focus.
fn synthPointerMotion(self: *ServerState) void {
    const scene = self.scene orelse return;
    var target = self.synth_target;
    if (target) |t| {
        if (scene.surface_nodes.get(t) == null) target = null;
    }
    if (target == null) target = synthPointerCandidate(self, scene);
    self.synth_target = target;
    const surface = target orelse return;
    const node = (scene.surface_nodes.get(surface) orelse return).node orelse return;
    const now = SynthSurfaceState.of(surface);
    if (self.synth_pointed.get(surface)) |was| {
        if (std.meta.eql(was, now)) return;
    }
    // The snapshot is taken even when nothing can be pointed at: a
    // surface no output can see has no pointer position, and a later
    // motion for the same state would be one with no commit behind it.
    self.synth_pointed.put(self.allocator, surface, now) catch return;
    const at = synthPointerTarget(self, surface, node) orelse return;
    self.seat.pointerMotion(at.x, at.y);
    log.info("synth input: pointer motion to {d},{d} (surface {*})", self.io, self.log_cfg, "server", .{ at.x, at.y, surface });
}

/// The first mapped world surface mode 2 may point at, or null when there
/// is none yet.
fn synthPointerCandidate(self: *ServerState, scene: *wayland.scene.Scene) ?*Surface {
    const cursor_res = self.seat.cursorSurface();
    var it = scene.surface_nodes.valueIterator();
    while (it.next()) |sn| {
        const surface = sn.*.surface;
        if (sn.*.node == null or !surface.mapped) continue;
        if (cursor_res) |cr| {
            if (surface.resource == cr) continue;
        }
        if (isLocalSpace(localSpaceOf(self, surface))) continue;
        return surface;
    }
    return null;
}

/// The desktop pixel a mode-2 motion should carry `node` to: the middle
/// of the surface's box as it is DISPLAYED.
///
/// That box is the node's own rect — the destination, not
/// wp_viewport.set_source, which only remaps which texels fill it and
/// never changes the coordinates the client is handed.
///
/// The centre is projected through the camera of the output that can see
/// it (a world coordinate narrowed straight to i32 would be wrong by
/// every zoom and rotation), then clamped into THAT output's own pixels
/// so the motion cannot land on a second connector. The clamp is the
/// projected bounding box intersected with the output, so a surface
/// clipped by an edge is pointed at its visible interior. A rotated
/// surface's bounding box also contains pixels that are not on it, so
/// the result is verified by inverting the camera: a point that misses
/// the surface sends no motion rather than one that would.
fn synthPointerTarget(self: *ServerState, surface: *Surface, node: *wayland.scene.SceneNode) ?geom.Point {
    const rect = node.absolutePosition();
    if (rect.isEmpty()) return null;
    const centre = geom.FPoint{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    const view = viewSeeingWorldPoint(self, centre) orelse
        viewForSurface(self, surface) orelse
        return null;
    // The four corners, so a ROTATED surface's projected box is a real
    // bounding box rather than the centre scaled by one factor.
    const corners = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
    const near = view.camera.worldToScreen(rect.x, rect.y);
    var min_x = near.x;
    var min_y = near.y;
    var max_x = near.x;
    var max_y = near.y;
    for (corners[1..]) |corner| {
        const p = view.camera.worldToScreen(
            rect.x + corner[0] * rect.width,
            rect.y + corner[1] * rect.height,
        );
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    const projected = geom.FRect{
        .x = min_x,
        .y = min_y,
        .width = max_x - min_x,
        .height = max_y - min_y,
    };
    const visible = projected.intersect(OutputView.localRect(view).toFloatRect()) orelse return null;
    const px = visible.x + visible.width / 2;
    const py = visible.y + visible.height / 2;
    const back = view.camera.screenToWorld(px, py);
    if (!rect.containsPoint(back.x, back.y)) return null;
    return .{
        .x = view.rect.x + geom.floorToI32(px),
        .y = view.rect.y + geom.floorToI32(py),
    };
}

/// A surface committed new content: schedule a render so the update is
/// composited this frame (the commit→present wake, note 137 F1).
fn onSceneContentDirty(listener: *wire.Listener(*wayland.scene.Scene), _: *wayland.scene.Scene) void {
    const self: *ServerState = @fieldParentPtr("content_dirty_listener", listener);
    requestRender(self);
}

/// Mark that EVERY view must render (something scene-global changed) and
/// wake each renderer. Per-view changes (a camera move, the cursor) call
/// requestRenderView with the one view they touch, so a second output's
/// camera and targets are never disturbed by the first one's activity.
fn requestRender(self: *ServerState) void {
    for (self.output_views.items) |view| requestRenderView(self, view);
}

/// Mark that `view` must render and wake it via output.sendFrame(). The
/// DRM frame chain is driven by the flip event (sendFrame -> renderFrame
/// -> commit -> flip -> event), so a change while idle needs this kick to
/// start a frame; subsequent frames then pace off the flips until the
/// change is consumed. While a frame is in flight (frame_pending, set by
/// the last commit) the kick is skipped: the backend's next frame event
/// renders it — starting a second frame now would duplicate the frame
/// signal (note 135 F2).
fn requestRenderView(_: *ServerState, view: *OutputView) void {
    view.repaint_pending = true;
    if (view.in_render) return;
    if (!view.output.frame_pending) view.output.sendFrame();
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// What the render phases share, captured once per frame by beginFrame:
/// the view being rendered, the session-lock decision (read ONCE, the
/// privilege boundary) and the cursor footprints (captured BEFORE the
/// cursor nodes move).
const FrameInput = struct {
    view: *OutputView,
    lock: LockedFrame,
    cursor_fp: wayland.cursor.Cursor.Footprints,
    scene_output: *wayland.scene.SceneOutput,
    /// The pointer's position in THIS view's own pixels (the global
    /// desktop position minus the view's layout origin). Null when the
    /// pointer is not over this view, which is what keeps one output's
    /// cursor out of another's frame.
    pointer: ?geom.Point,
};

/// The five marks one frame takes, in the order the phases take them.
/// finishFrame logs them as perf_frame_fmt's spans (microseconds).
const FramePerf = struct {
    /// Frame start, after the idle skip.
    t0: u64,
    /// After the scene sync (placement, subsurfaces, popups, drag icon).
    sync: u64,
    /// After the cursor update.
    cursor: u64,
    /// After the composite, before the present.
    render: u64,
    /// After the output commit.
    present: u64,
};

/// One frame for ONE view, in five phases: gather what the frame needs
/// (beginFrame), accumulate its damage, composite its canvas, commit it
/// to its output, then finish (frame callbacks, presentation, bookkeeping).
/// The order and every short-circuit in between are the frame's contract:
/// a locked session must be the FIRST thing a composited frame sees, and
/// a failed commit must skip every finishing step so the next flip
/// re-renders.
fn renderFrame(view: *OutputView) void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    const self = view.state;
    // See the in_render field: guard against re-entrant emits from
    // requestRender while this render is on the stack.
    view.in_render = true;
    defer view.in_render = false;
    // Close the seat's input batch: everything the backends fed since
    // the last frame forms one wl_pointer.frame group (F7, note 132).
    self.seat.pointerFrame();
    // Idle-frame skip: nothing changed since the last render, so skip the
    // full composite + flip. Without this the flip chain runs a full
    // composite at every vsync even with a static canvas — the observed
    // ~95% idle CPU. Changes set repaint_pending (requestRender); it is
    // cleared after a successful render, and a flip-pending collision
    // leaves it set so the next flip event re-renders.
    if (!view.repaint_pending) return;
    var perf: FramePerf = .{ .t0 = perfNs(self), .sync = 0, .cursor = 0, .render = 0, .present = 0 };

    const input = beginFrame(view, &perf) orelse return;
    accumulateFrameDamage(view, input);
    // A failed commit skips the whole finishing phase: no frame callback,
    // no presentation, no watchdog re-arm — the repaint flag stays set
    // so the flip event re-renders the same frame.
    if (!compositeAndPresent(view, input, &perf)) return;
    finishFrame(view, &perf);
}

/// Phase 1: the frame's inputs. Reads the session-lock latch ONCE (see
/// the ext_session_lock_manager_v1 wiring item 1 in the body), syncs the
/// scene, moves the cursor and captures its footprints. Null when there
/// is nothing to render into.
fn beginFrame(view: *OutputView, perf: *FramePerf) ?FrameInput {
    const self = view.state;
    // ext_session_lock_manager_v1, wiring item 1: the latch is read HERE,
    // once per frame, and every composite decision below uses this value.
    // Nothing caches "was I unlocked" across a dispatch, so the first
    // frame composited after the `locked` signal (which is emitted inside
    // the lock surface's commit dispatch, before this runs) is already a
    // locked frame.
    const lock = lockedFrameFor(self, view.output);

    perf.sync = perfNs(self);
    // Scene space is the desktop: every surface's tree belongs on the view
    // its surface was placed on (an unplug re-homes the survivors).
    syncSurfacePlacement(self);
    // Subsurfaces: position child nodes over their mapped parent.
    syncSubsurfaceNodes(self);
    // F12: popups position over their parent at the geometry offset and
    // stack above it (menus render where the positioner asked and
    // hit-test there).
    syncPopupNodes(self);
    // P2-12: the wl_data_device.start_drag icon follows the pointer in
    // scene coordinates while its drag lives.
    syncDragIconNodes(self);

    const cursor = self.cursor orelse {
        log.err("render: no cursor", self.io, self.log_cfg, "server", .{});
        return null;
    };
    // M3 cursor: follow the seat pointer, show the client cursor surface
    // or the fallback rect. update() captures the previous frame's
    // footprints BEFORE moving the nodes: a partial upload must repaint
    // both the old and the new position.
    const cursor_fp = cursor.update();
    perf.cursor = perfNs(self);
    // The pointer in THIS view's pixels: the seat carries global desktop
    // coordinates, and a view draws the cursor only while the pointer is
    // inside its own rectangle.
    const gx = self.seat.pointer_x;
    const gy = self.seat.pointer_y;
    const pointer: ?geom.Point = if (view.rect.containsPoint(.{ .x = gx, .y = gy }))
        .{ .x = gx - view.rect.x, .y = gy - view.rect.y }
    else
        null;
    return .{
        .view = view,
        .lock = lock,
        .cursor_fp = cursor_fp,
        .scene_output = view.scene_output,
        .pointer = pointer,
    };
}

/// Phase 2: this view's damage ring — the region the backend uploads and
/// the commit reports.
fn accumulateFrameDamage(view: *OutputView, input: FrameInput) void {
    const self = view.state;
    const so = input.scene_output;
    const out_rect = OutputView.localRect(view);
    // Damage accumulation: this frame's surface damage projected into THIS
    // output's coordinates, plus the cursor's old+new footprints. The ring
    // is the upload region; the pixman repaint below stays a full repaint.
    // The first frame damages the whole output — the window texture starts
    // blank, so a partial first upload would leave the background
    // uninitialized. A CAMERA change (pan, zoom, ROTATION) moves every
    // pixel, so the whole output is damaged too — otherwise the partial
    // upload smears the previous canvas (the drag-streak bug).
    const camera_changed = view.cameraChanged();
    view.last_camera = view.camera;
    if (view.frames_rendered == 0 or camera_changed) {
        so.addDamage(out_rect);
    }
    // The library queues damage on each surface commit. Re-reading its
    // current damage here would replay an idle overlay's damage forever.
    // Rebuild only THIS output's visible presentation-feedback targets.
    // Output membership decides enter/leave and the visible set, and it is
    // expressed through each scene output's camera visible world rect — so
    // it is refreshed here, after the frame's camera and placement work.
    if (self.scene) |scene| {
        wayland.surface_node.updateOutputAssociations(scene);
        wayland.surface_node.collectPresented(scene, so);
    }
    // The cursor's old and new footprints, projected through this view's
    // camera: a cursor that only ever touched another output contributes
    // nothing here. The footprints are f64 WORLD rects (Cursor.footprints
    // no longer narrows them), so a cursor parked a billion pixels out at
    // a fractional offset reaches this projection with its fraction
    // intact and is clipped there — never rounded into an i32 edge first.
    for ([_][2]?geom.FRect{ input.cursor_fp.old, input.cursor_fp.new }) |pair| {
        for (pair) |maybe_rect| {
            if (maybe_rect) |r| addProjectedDamage(so, r);
        }
    }
}

/// Project one WORLD rect into its output's screen pixels and accumulate
/// it there. Uses the library's own f64 projection (clip in f64, narrow
/// once) so a rect a billion pixels off-screen contributes nothing
/// instead of saturating onto an edge the output never had.
fn addProjectedDamage(so: *wayland.scene.SceneOutput, world: geom.FRect) void {
    if (so.projectWorldRect(world)) |on_screen| so.addDamage(on_screen);
}

/// Phases 3 and 4: composite this view's canvas into the target it scans
/// out from, then hand that target to the output.
///
/// The GPU DRM path leases the slot FIRST, because the canvas has to be
/// drawn into that very buffer: no CPU front, no read-back, no framebuffer
/// copy. Every CPU backend composites into the view's own framebuffer. A
/// failed lease or commit is explicit — the frame is dropped and the
/// repaint flag kept, never silently replaced by a CPU composite the
/// operator did not ask for.
fn compositeAndPresent(view: *OutputView, input: FrameInput, perf: *FramePerf) bool {
    const self = view.state;
    if (!view.gpu) {
        if (!compositeFrame(view, input, null)) return false;
        return presentFrame(view, input, perf, null);
    }
    const backend = self.drm_backend orelse {
        log.err("gpu scanout: no DRM backend", self.io, self.log_cfg, "server", .{});
        return false;
    };
    const frame = drm_mod.DrmBackend.acquireGpuFrame(backend, view.output) orelse {
        log.err("gpu scanout: no free slot on {d}x{d}; frame dropped", self.io, self.log_cfg, "server", .{
            view.output.mode.width, view.output.mode.height,
        });
        return false;
    };
    view.gpu_lease = frame;
    const target = gpuTargetForSlot(view, frame) orelse {
        drm_mod.DrmBackend.cancelGpuFrame(backend, view.output, frame);
        view.gpu_lease = null;
        return false;
    };
    if (!compositeFrame(view, input, target)) {
        drm_mod.DrmBackend.cancelGpuFrame(backend, view.output, frame);
        view.gpu_lease = null;
        return false;
    }
    // The lease is a WRITING lease: the buffer's contents must be complete
    // before it is scanned out. finishRendering is that barrier (glFinish
    // on the first implementation); the contract it keeps is "nothing is
    // scanned out before the writes land".
    gles2.Gles2Renderer.finishRendering(self.renderer) catch |err| {
        log.err("gpu scanout: render completion failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        drm_mod.DrmBackend.cancelGpuFrame(backend, view.output, frame);
        view.gpu_lease = null;
        return false;
    };
    return presentFrame(view, input, perf, frame);
}

/// The EGL image FBO for the frame's slot, imported once per slot and then
/// reused: a cached target belongs to the dmabuf behind that slot, and the
/// backend re-validates the frame's identity, owner, generation and slot
/// before every commit.
fn gpuTargetForSlot(view: *OutputView, frame: *wayland.gpu_frame.GpuFrame) ?*gles2.Gles2Target {
    if (view.gpu_targets[frame.slot]) |t| return t;
    const target = gles2.Gles2Target.fromDmabuf(view.allocator, view.state.renderer, &frame.attributes) catch |err| {
        log.err("gpu scanout: slot {d} import failed: {s}", view.io, view.log_cfg, "server", .{
            frame.slot, @errorName(err),
        });
        return null;
    };
    view.gpu_targets[frame.slot] = target;
    return target;
}

/// Phase 3: put this frame's canvas into the view's scanout target.
/// `gpu_target` is non-null only on the GPU DRM path, where the canvas goes
/// straight into the leased buffer.
fn compositeFrame(view: *OutputView, input: FrameInput, gpu_target: ?*gles2.Gles2Target) bool {
    const lock = input.lock;
    if (gpu_target != null) {
        // The GPU path always draws the full canvas: a fresh lease is a
        // fresh buffer, and there is no persisted base to restore a region
        // from — so the hover/present-unchanged shortcuts below, which are
        // CPU framebuffer tricks, do not apply.
        return compositeCanvas(view, input, gpu_target);
    }
    if (lock.locked) {
        // A locked session never reuses the previous canvas: the two
        // shortcuts below (hover cursor restore, present-unchanged) would
        // show a frame composited BEFORE the latch, which is exactly what
        // the privilege boundary forbids. Refill the output instead.
        view.cursor_repaint = false;
        view.frame_kick = false;
        return compositeCanvas(view, input, null);
    }
    if (view.cursor_repaint) {
        // Hover cursor move: the canvas is static, so restore the old cursor
        // region from the persisted base + redraw the cursor at the new
        // pointer — no full-canvas recomposite.
        view.cursor_repaint = false;
        if (view.base_framebuffer) |base| {
            // Restore BOTH old footprints (the fallback-rect node AND the
            // client-cursor node). Restoring only the rect node left the
            // old client cursor in place, smearing a trail behind the
            // moving pointer.
            for (input.cursor_fp.old) |r| {
                if (r) |rr| copyRegion(base, view.framebuffer, localRectOf(view, rr));
            }
        }
        if (!lock.cursor_hidden and input.pointer != null) compositeCursor(view, view.framebuffer);
        return true;
    }
    if (view.frame_kick) {
        // A client is ready for the next frame (pending wl_callback) but the
        // canvas is unchanged. Present the current framebuffer so the
        // callback fires and the client can render + commit its pending
        // update — no recomposite.
        view.frame_kick = false;
        return true;
    }
    return compositeCanvas(view, input, null);
}

/// A world-space rect as this view's own pixel rect, clipped to the
/// output. The damage ring and the cursor restore both speak output-local
/// coordinates while the cursor nodes are positioned in DESKTOP ones, and
/// `Cursor.footprints` hands them over as f64 world rects — so the shift
/// and the clip happen in f64, against the output rect in f64, and only
/// the clipped box is narrowed once. A footprint a billion pixels out at
/// a fractional offset therefore either lands on the output it really
/// covers or clips away entirely; it can never round onto an edge the
/// output never had.
fn localRectOf(view: *OutputView, world: geom.FRect) geom.Rect {
    const local = geom.FRect{
        .x = world.x - @as(f64, @floatFromInt(view.rect.x)),
        .y = world.y - @as(f64, @floatFromInt(view.rect.y)),
        .width = world.width,
        .height = world.height,
    };
    const clipped = local.intersect(OutputView.localRect(view).toFloatRect()) orelse
        return geom.Rect.empty();
    return clipped.toPixelRect();
}

/// Phase 4: hand the frame to the output. The output damage is the ring's
/// rects for this frame — the backend uploads only that region. An empty
/// ring falls back to a whole-output damage. False when the commit failed;
/// the repaint flag stays set so the flip event re-renders, and a GPU
/// lease the backend did not consume is cancelled.
fn presentFrame(
    view: *OutputView,
    input: FrameInput,
    perf: *FramePerf,
    gpu_frame: ?*wayland.gpu_frame.GpuFrame,
) bool {
    const self = view.state;
    const out = view.output;
    // wp_tearing_control_manager_v1: the present path consults the
    // committed hint of every surface it is about to scan out, per frame.
    _ = consultTearingHints(self, view);
    _ = input.scene_output.damage_ring.rotate();
    // The render span ends here — after the tearing consult and the ring
    // rotation — and before the commit, so the present span covers the
    // commit alone.
    perf.render = perfNs(self);

    var state = wayland.output.Output.State.init(self.allocator);
    defer state.deinit();
    state.committed = wayland.output.Output.State.committed_enabled |
        wayland.output.Output.State.committed_mode |
        wayland.output.Output.State.committed_buffer;
    state.enabled = true;
    state.mode = .{ .width = out.mode.width, .height = out.mode.height, .refresh_msec = out.mode.refresh_msec };
    state.buffer = if (gpu_frame) |f| .{ .gpu = f } else .{ .cpu = view.framebuffer };
    const damage_rects = input.scene_output.takeDamage();
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
        // A GPU lease the backend did not consume goes back: the slot stays
        // owned by the server and the buffer is never scanned out.
        if (gpu_frame) |f| {
            if (self.drm_backend) |b| drm_mod.DrmBackend.cancelGpuFrame(b, out, f);
            view.gpu_lease = null;
        }
        // Usually the flip-pending pacing collision (a commit while a flip
        // is in flight); the DRM logs real failures itself. The repaint
        // flag stays set so the flip event re-renders it.
        log.debug("output commit failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return false;
    };
    // The commit consumed the lease: the backend owns the buffer until it
    // flips, and the view must neither cancel nor re-render into it.
    view.gpu_lease = null;
    perf.present = perfNs(self);
    return true;
}

/// Phase 5: what a committed frame owes its clients — the frame callbacks,
/// the presentation feedback, the counters and the loop bookkeeping that
/// follows a successful present. EVERYTHING here is per view: only the
/// surfaces visible on THIS output get a callback, and the presentation
/// names THIS output's wl_output.
fn finishFrame(view: *OutputView, perf: *FramePerf) void {
    const self = view.state;
    const out = view.output;
    const presented = view.scene_output.presented.items;
    // Frame callbacks: the surfaces presented on this output get
    // wl_callback.done at present time (wlroots wlr_surface_send_frame_done).
    // The time is the monotonic clock in ms (.awake = CLOCK_MONOTONIC in the
    // 0.16 std.Io.Clock); the u32 wrap-around is fine — the protocol
    // defines an undefined base.
    const now_ms: u32 = @truncate(@as(u64, @bitCast(std.Io.Clock.now(.awake, self.io.*).toMilliseconds())));
    for (presented) |s| s.sendFrameDone(now_ms);

    view.frames_rendered += 1;
    if (self.perf) {
        log.info(perf_frame_fmt, self.io, self.log_cfg, "perf", .{
            view.frames_rendered,
            (perf.sync - perf.t0) / 1000,
            (perf.cursor - perf.sync) / 1000,
            (perf.render - perf.cursor) / 1000,
            (perf.present - perf.render) / 1000,
            (perf.present - perf.t0) / 1000,
        });
    }

    // wp_presentation: every surface drawn on this output awaits its
    // present. THIS view's wl_output global names the output for
    // sync_output. For real-display backends (DRM/nested —
    // Output.emits_present) present() QUEUES the feedbacks on the output's
    // commit seq (the seq of the frame just committed): the output's
    // presented event — the actual scanout/flip completion — delivers them.
    // Headless/raylib have no present event: present() synthesizes
    // immediately.
    self.presentation.present(
        presented,
        view.wl_output,
        out.commit_seq,
        @intCast(out.mode.refresh_msec),
        0,
    );

    // The frame was rendered + committed (the flip is in flight): clear the
    // pending flag so the next flip event skips until a change.
    view.repaint_pending = false;
    tracy.frameMark(null);
    // `presented` is this frame's FRAME-DONE FAN-OUT: the count the
    // sendFrameDone loop above walked. It is NOT the drawn count — the
    // canvas pass additionally drops the cursor surface and drag icons.
    log.debug("render view {d}x{d} frame={d} surfaces={d}", self.io, self.log_cfg, "server", .{
        out.mode.width, out.mode.height, view.frames_rendered, presented.len,
    });

    // Frame-done and presentation events were marshalled above; push them
    // out now. onDisplayReady flushes after dispatching client requests,
    // but a DRM-driven frame loop runs from the flip event instead, where
    // the display fd may be idle (a silent client) — without this the
    // callbacks sit in the outbound buffer forever. Idempotent when the
    // headless timer path already flushed.
    self.display.flushClients();

    // Progress: keep the watchdog from firing. A wedged loop stops instead
    // of hanging tests. Guarded by watchdog_enabled: zio's setTimer arms an
    // un-armed timer, so without this a disabled watchdog (interactive
    // demo) would be re-armed by the first render and fire anyway.
    if (self.watchdog_enabled) {
        if (self.watchdog) |t| {
            self.loop.?.setTimer(t, .{ .duration = zio.Duration.fromMilliseconds(watchdog_timeout_ms) });
        }
    }
    // The frame budget is a SESSION budget, so it sums across the views: a
    // two-output server that stopped after the first output's N frames
    // would never stop on its own.
    if (self.run_frames != 0 and totalFrames(self) >= self.run_frames) {
        log.info("reached WAYLAND_RUN_FRAMES={d}, stopping", self.io, self.log_cfg, "server", .{self.run_frames});
        self.loop.?.stop();
    }
}

/// What the present path decided about tearing for one frame
/// (wp_tearing_control_manager_v1).
const PresentTearing = struct {
    /// The presented surfaces whose COMMITTED hint is `.async`. A hint is
    /// a PERMISSION, not a command, so this count alone never changes the
    /// commit.
    async_surfaces: u32 = 0,
    /// Whether the flip may actually be asynchronous, i.e. the client
    /// asked AND the output tears. See consultTearingHints.
    honoured: bool = false,
};

/// The present path's wp_tearing_control_v1 gate: read every surface's
/// committed hint once per frame, for exactly the surfaces this frame is
/// about to scan out (`scene.presented`, rebuilt by collectPresented
/// earlier in accumulateFrameDamage).
///
/// The OUTPUT GATE is the honest part. `.async` is a permission from the
/// client (tearing-control-v1.xml:95-100), and wlroots only takes the
/// asynchronous page-flip path for an output whose DRM commit carries
/// DRM_MODE_PAGE_FLIP_ASYNC — without it the flip is vsync'd and the hint
/// has no effect. No backend in this server has an asynchronous page
/// flip: the DRM backend commits a dumb-buffer flip vsync'd
/// (backend/drm.zig) and headless / raylib / nested-wayland have no page
/// flip at all. So this server NEVER tears, and a `.async` hint is
/// recorded and reported here but the commit below stays vsync'd — the
/// hint is not silently upgraded into a command. Turning this on needs
/// `tearing: bool` on output.Output.State plus DRM_MODE_PAGE_FLIP_ASYNC
/// in backend/drm.zig; until then `honoured` is false by construction.
fn consultTearingHints(self: *ServerState, view: *OutputView) PresentTearing {
    const tc = self.tearing_control orelse return .{};
    var async_surfaces: u32 = 0;
    // Only the surfaces THIS output is about to scan out: a surface that
    // lives on the other output has no say in this frame's flip.
    for (view.scene_output.presented.items) |surface| {
        if (tc.hintFor(surface) == .async) async_surfaces += 1;
    }
    // The output gate: the client's `.async` is a permission, honoured
    // only when the output actually tears (see outputTears).
    const honoured = async_surfaces > 0 and outputTears(view.output);
    if (async_surfaces > 0 and !honoured) {
        log.debug(
            "tearing: {d} surface(s) request async presentation; this backend flips vsync'd, hint not honoured",
            self.io,
            self.log_cfg,
            "tearing_control",
            .{async_surfaces},
        );
    }
    return .{ .async_surfaces = async_surfaces, .honoured = honoured };
}

/// The output half of the wp_tearing_control_v1 gate: does a frame
/// committed to `out` reach the screen without waiting for the vertical
/// blank?
///
/// FALSE for every backend this server has. wlroots puts
/// DRM_MODE_PAGE_FLIP_ASYNC on the page-flip DRM commit of an output
/// configured for it, and only then does a `.async` hint shorten the
/// frame time; the headless, raylib and nested-wayland backends present
/// without a page flip at all (Output.emits_present is false for them).
/// This server's DRM backend (backend/drm.zig) commits its dumb-buffer
/// flip vsync'd and exposes no tearing switch, and Output.State has no
/// tearing field to carry one — so a hint is recorded, reported per frame
/// by consultTearingHints, and deliberately NOT honoured. Making it real
/// needs `tearing` in output.Output.State (src/output/output.zig) plus
/// DRM_MODE_PAGE_FLIP_ASYNC in backend/drm.zig; neither is this file.
fn outputTears(out: *wayland.output.Output) bool {
    _ = out; // every backend here flips vsync'd; see the doc comment.
    return false;
}

/// What the render path must do about the session lock on one output
/// (ext_session_lock_v1 wiring contract item 3, read fresh for every
/// frame — the latch is never cached across a dispatch).
const LockedFrame = struct {
    /// The session is locked: the whole output rect is filled with the
    /// opaque lock color BEFORE any node is drawn, and only lock
    /// surfaces are composited. The cursor, normal surfaces, drag icons
    /// and popups are all skipped.
    locked: bool = false,
    /// `outputIsBlank(out)`: this output has no lock surface, an
    /// unmapped one, or one SMALLER than the output, so the solid color
    /// STAYS and no lock content is drawn at all (composited lock
    /// content must never be stretched to cover the gap —
    /// ext_session_lock_surface_v1:277-280).
    blank: bool = false,
    /// Whether the cursor may be painted at all. A locked session never
    /// paints it (the contract's "hide the cursor node"), and an explicit
    /// hide (the same flag the lock handler sets) is honoured on its own,
    /// so the two can never disagree about what is on screen.
    cursor_hidden: bool = false,
};

/// The locked frame for `out`, read once per frame at the top of
/// beginFrame. The
/// `locked` signal is emitted inside the lock surface's commit dispatch
/// (shell/session_lock.zig), so this read happens after the latch was
/// written and the frame it decides IS the first locked frame — no
/// input dispatch or render pass in that dispatch can observe the
/// session as unlocked.
fn lockedFrameFor(self: *ServerState, out: *wayland.output.Output) LockedFrame {
    const sl = self.session_lock orelse return .{ .cursor_hidden = self.cursor_hidden };
    if (!sl.isLocked()) return .{ .cursor_hidden = self.cursor_hidden };
    return .{
        .locked = true,
        .blank = sl.outputIsBlank(out),
        .cursor_hidden = true,
    };
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
/// screen-space cursor) into the view's scanout target.
///
/// `gpu_target` non-null is the GPU DRM path: the canvas is drawn STRAIGHT
/// into the leased scanout buffer — no CPU front, no read-back, no
/// framebuffer copy. Null is a CPU backend: the base lands in the view's
/// persisted base framebuffer (so the hover-cursor path can restore a
/// region from it without recompositing), is copied to the scanout
/// framebuffer, and the cursor is stamped on top.
fn compositeCanvas(view: *OutputView, input: FrameInput, gpu_target: ?*gles2.Gles2Target) bool {
    const lock = input.lock;
    if (gpu_target != null) {
        // The cursor rides in the SAME pass as the canvas (compositeBaseGles2
        // draws it last, under the identity transform): a second pass would
        // start with an implicit clear and erase the base.
        if (!compositeBase(view, input, gpu_target)) return false;
        view.capture_base_valid = false;
        view.capture_frame_valid = false;
        return true;
    }
    if (ensureBaseFramebuffer(view) == null) return false;
    if (!compositeBase(view, input, null)) return false;
    const base = view.base_framebuffer orelse return false;
    copyWhole(base, view.framebuffer);
    // ext_session_lock_v1:74-91 — a locked session draws no cursor. The
    // cursor's scene nodes are re-enabled every frame by Cursor.update, so
    // hiding it is the server not painting it.
    if (!lock.cursor_hidden and input.pointer != null) compositeCursor(view, view.framebuffer);
    return true;
}

/// Render the background + every mapped surface through THIS view's
/// camera: the canvas WITHOUT the cursor.
///
/// `gpu_target` non-null draws into the leased GPU scanout buffer (and
/// reads nothing back); null rasterizes into CPU storage, which is the
/// view's persisted base on the pixman path and its FBO + read-back on the
/// GLES2 CPU-scanout path.
fn compositeBase(view: *OutputView, input: FrameInput, gpu_target: ?*gles2.Gles2Target) bool {
    const self = view.state;
    switch (self.renderer_kind) {
        .pixman => {
            compositeBasePixman(view, input);
            return true;
        },
        .gles2 => return compositeBaseGles2(view, input, gpu_target),
    }
}

/// The CPU canvas pass: fill the base framebuffer and rasterize the
/// surfaces through this view's camera into it, byte for byte the output
/// this server has always presented (WAYLAND_RENDERER unset or "pixman").
fn compositeBasePixman(view: *OutputView, input: FrameInput) void {
    const self = view.state;
    const base = ensureBaseFramebuffer(view) orelse return;
    const lock = input.lock;
    // 1. Fill. Premultiplied ARGB8888, memory bytes B,G,R,A — the same
    //    bytes the GLES2 pass's screen-space fill produces. A locked
    //    session fills with the opaque lock color INSTEAD, before anything
    //    is drawn: an output with no (or a too small) lock surface must
    //    never show what was there before.
    base.fill(premultipliedFill(lock));
    // A blank output draws NOTHING: the solid color stays (outputIsBlank
    // said the lock surface is missing, unmapped or smaller than the
    // output, and composited lock content must never be stretched to cover
    // the gap).
    if (lock.blank) return;

    // 2. Surfaces: world rect = the node's absolute scene position + the
    //    SURFACE size (the node dst is the surface size — the buffer size
    //    under the committed transform divided by the scale, set by the
    //    library's SurfaceNode update). Each item carries the surface's
    //    buffer transform and its raw buffer crop, and the CPU rasterizer
    //    samples through them exactly like the GLES2 sampler does — the
    //    eight standard transforms and a wp_viewport crop are drawn by
    //    BOTH paths, not dropped by either.
    view.items.clearRetainingCapacity();
    collectCanvasItems(self, lock, view, &view.items);
    // The progressive-quality stride belongs to the view the gesture is
    // PINNED to: another output's canvas is not being dragged.
    const fast = self.gestures.fast_render and self.gestures.view == view;
    wayland.canvas.render(self.allocator, base, &view.camera, view.items.items, if (fast) 3 else 1);
}

/// The GLES2 canvas pass (WAYLAND_RENDERER=gles2): the same canvas — the
/// same fill colour, the same item list, the same per-view camera —
/// rasterized by the GPU renderer.
///
/// ONE pass carries TWO coordinate spaces, which is what the mixed
/// transform contract asks for:
///   1. the background fill, the cursor and every OUTPUT-LOCAL overlay
///      (the session-lock screen, a layer surface, the drag icon) are
///      SCREEN space (identity transform, this view's own pixel rect) —
///      none is affected by the canvas camera, and none needs a world
///      coordinate at all;
///   2. the ordinary surfaces are WORLD space, through the camera: their
///      dst rect is the node's scene rect MINUS the camera centre,
///      computed in f64 per item, and the affine carries the linear part
///      plus the viewport centre. An f32 therefore never carries an
///      absolute world coordinate, which is what keeps a surface a
///      billion pixels out exactly where the f64 camera says it is.
/// An item names its own space, and the transform is re-issued only when
/// that space changes between two items.
/// Nothing here falls back to pixman.
fn compositeBaseGles2(view: *OutputView, input: FrameInput, gpu_target: ?*gles2.Gles2Target) bool {
    const self = view.state;
    const lock = input.lock;
    // The GPU DRM path draws into the leased scanout buffer; every other
    // path rasterizes into this view's own FBO.
    const target = gpu_target orelse (ensureGles2Target(view) orelse return false);
    // Only the CPU-scanout path reads back; the GPU path's target IS the
    // scanout buffer.
    const readback: ?*pixman.Framebuffer = if (gpu_target == null) ensureBaseFramebuffer(view) else null;
    if (gpu_target == null and readback == null) return false;

    gles2.Gles2Renderer.setTransform(self.renderer, .identity);
    const pass = self.renderer.beginPass(target) orelse return false;

    // 1. Fill, in SCREEN space. Straight-alpha RGBA, the same colour the
    //    CPU path premultiplies into its fill bytes (wlr_render_color,
    //    include/wlr/render/pass.h:135-137). At a = 1 the two agree to
    //    within one unit per channel: the shader declares `precision
    //    mediump float` and converts the result to unorm8 at that
    //    precision, so a channel whose exact value sits on a .5 boundary
    //    (0.1 * 255 = 25.5) can land one lower than the CPU path's
    //    round-half-away-from-zero. The tests pin both sides.
    const fill: [4]f32 = if (lock.locked) lock_blank_color else background_color;
    pass.addRect(OutputView.localRect(view).toFloatRect(), fill);

    // 2. Surfaces, each in the space its CanvasItem declares.
    //
    // `gestures.fast_render` has no counterpart here and is deliberately
    // not consulted: it asks the CPU rasterizer for a strided, blocky
    // composite during a camera drag, while the GLES2 sampler is already
    // bilinear and costs no more per pixel — the knob exists to make a
    // SOFTWARE rasterizer affordable, and honouring it here would only
    // degrade the GPU path.
    if (!lock.blank) {
        view.items.clearRetainingCapacity();
        collectCanvasItems(self, lock, view, &view.items);
        // `in_screen` starts true: the identity transform the fill was
        // drawn with is already in force, and setTransform copies the
        // matrix once per CHANGE, so a run of world items followed by a
        // run of overlays costs exactly two matrices.
        var in_screen = true;
        for (view.items.items) |item| {
            const want_screen = item.space == .screen;
            if (want_screen != in_screen) {
                in_screen = want_screen;
                gles2.Gles2Renderer.setTransform(
                    self.renderer,
                    if (in_screen) .identity else cameraAffine(view.camera),
                );
            }
            pass.addTexture(item.texture, .{
                .dst = if (in_screen)
                    // Already this output's own pixels.
                    .{ .x = item.world_x, .y = item.world_y, .width = item.world_w, .height = item.world_h }
                else
                    // The camera subtraction happens HERE, in f64, before
                    // the f32 narrowing the dst rect goes through.
                    .{
                        .x = item.world_x - view.camera.center_x,
                        .y = item.world_y - view.camera.center_y,
                        .width = item.world_w,
                        .height = item.world_h,
                    },
                .src = item.src,
                .transform = item.transform,
                .alpha = item.opacity,
            });
        }
    }
    // 3. The cursor, back in SCREEN space and on top of everything: an
    //    unrotated, unscaled overlay at its logical size (the same rule
    //    the CPU path follows with an identity camera). A locked session
    //    draws none.
    if (gpu_target != null and !lock.cursor_hidden and input.pointer != null) {
        if (ensureCursorGlTexture(self)) |tex| {
            const at = cursorScreenRect(view, tex);
            gles2.Gles2Renderer.setTransform(self.renderer, .identity);
            pass.addTexture(tex, .{
                .dst = .{
                    .x = @floatFromInt(at.x),
                    .y = @floatFromInt(at.y),
                    .width = @floatFromInt(at.width),
                    .height = @floatFromInt(at.height),
                },
                .alpha = 1.0,
            });
        }
    }
    pass.submit();

    // 4. Scanout read-back — CPU backends only. They cast the committed
    //    buffer to a `*pixman.Framebuffer` (backend/raylib.zig,
    //    backend/wayland.zig) and headless ignores it, so the frame the
    //    compositor presents is this read-back, not the FBO. It reuses the
    //    view's own base storage: no allocated buffer, no extra copy.
    if (readback) |base| {
        target.readPixelsInto(base) catch |err| {
            log.err("gles2 read-back failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            return false;
        };
    }
    return true;
}

/// The cursor's texture in the SELECTED renderer's GL namespace.
///
/// The GPU passes draw the cursor as a texture, and this is the one place
/// that uploads it: keyed on the CPU texture it came from, so a cursor
/// change (a new client cursor surface) re-uploads ONCE and every frame
/// after that reuses the same GL texture — no per-frame copy, no per-frame
/// allocation, no read-back.
fn ensureCursorGlTexture(self: *ServerState) ?*Texture {
    const cursor = self.cursor orelse return null;
    const source = cursor.texture orelse cursorFallbackTexture(self) orelse return null;
    if (self.cursor_gl_source == source) return self.cursor_gl;
    if (self.cursor_gl) |t| {
        t.destroy();
        self.cursor_gl = null;
    }
    // The cursor's textures are pixman ones (Cursor is handed the pixman
    // renderer), so their payload is pixman memory — published as
    // PixmanTextureData precisely so another module can read it.
    const data: *pixman.PixmanTextureData = @ptrCast(@alignCast(source.data));
    const bytes = @as(usize, @intCast(data.stride)) * @as(usize, @intCast(source.height));
    if (data.pixels.len < bytes) return null;
    const tex = gles2.Gles2Renderer.importMemory(
        self.renderer,
        source.width,
        source.height,
        data.stride,
        data.pixels[0..bytes],
    ) catch |err| {
        log.err("cursor GL import failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return null;
    };
    self.cursor_gl = tex;
    self.cursor_gl_source = source;
    return tex;
}

/// The cursor's rect in `view`'s own pixels: the pointer minus the
/// hotspot, at the cursor's logical size (buffer pixels divided by the
/// client cursor's buffer scale). Never rotated or scaled by the canvas
/// camera — the cursor is a screen overlay.
fn cursorScreenRect(view: *OutputView, tex: *Texture) geom.Rect {
    const self = view.state;
    const seat = self.seat;
    const cursor = self.cursor.?;
    const x = seat.pointer_x - view.rect.x - seat.cursor_hotspot_x;
    const y = seat.pointer_y - view.rect.y - seat.cursor_hotspot_y;
    if (cursor.texture != null) {
        const scale: i32 = if (cursor.client_scale > 1) cursor.client_scale else 1;
        return .{
            .x = x,
            .y = y,
            .width = @max(1, @divTrunc(tex.width, scale)),
            .height = @max(1, @divTrunc(tex.height, scale)),
        };
    }
    return .{ .x = x, .y = y, .width = wayland.cursor.cursor_size, .height = wayland.cursor.cursor_size };
}

/// The cursor stamped into `view`'s own CPU framebuffer, at the pointer's
/// VIEW-LOCAL position.
///
/// Cursor.draw would place it at the seat's GLOBAL coordinates, which is
/// right only for a view sitting at the desktop origin; with two outputs
/// the second one's cursor would be drawn one screen-width too far right.
/// The placement is therefore the compositor's policy, here, and the
/// camera is the identity over this framebuffer — a screen overlay at
/// constant size.
fn compositeCursor(view: *OutputView, fb: *pixman.Framebuffer) void {
    const self = view.state;
    const cursor = self.cursor orelse return;
    const tex = cursor.texture orelse cursorFallbackTexture(self) orelse return;
    const at = cursorScreenRect(view, tex);
    const item = CanvasItem{
        .texture = tex,
        .world_x = @floatFromInt(at.x),
        .world_y = @floatFromInt(at.y),
        .world_w = @floatFromInt(at.width),
        .world_h = @floatFromInt(at.height),
        .opacity = 1.0,
        .space = .screen,
    };
    var items = [_]CanvasItem{item};
    var cam = wayland.canvas.screenCamera(fb);
    wayland.canvas.render(self.allocator, fb, &cam, &items, 1);
}

/// The cursor's fallback arrow texture, materialized on first use.
///
/// Cursor builds it lazily behind a private factory and its public draw
/// composites in GLOBAL seat coordinates, so the one time the compositor
/// needs the texture itself it draws into a ONE-PIXEL scratch framebuffer
/// (nothing can land in it) and reads the texture back off the cursor.
/// One tiny allocation for the session, never per frame.
fn cursorFallbackTexture(self: *ServerState) ?*Texture {
    const cursor = self.cursor orelse return null;
    if (cursor.fallback_texture) |t| return t;
    const scratch = pixman.Framebuffer.create(self.allocator, 1, 1) catch return null;
    defer scratch.deinit();
    cursor.draw(scratch);
    return cursor.fallback_texture;
}

/// A FrameInput for code that drives the canvas pass directly instead of
/// through a frame event (the render tests): this view's live lock
/// decision, its current cursor footprints, and the pointer where the seat
/// actually is.
fn directFrameInput(view: *OutputView) FrameInput {
    const self = view.state;
    const gx = self.seat.pointer_x;
    const gy = self.seat.pointer_y;
    const pointer: ?geom.Point = if (view.rect.containsPoint(.{ .x = gx, .y = gy }))
        .{ .x = gx - view.rect.x, .y = gy - view.rect.y }
    else
        null;
    return .{
        .view = view,
        .lock = lockedFrameFor(self, view.output),
        .cursor_fp = if (self.cursor) |c| c.update() else .{ .old = .{ null, null }, .new = .{ null, null } },
        .scene_output = view.scene_output,
        .pointer = pointer,
    };
}

/// The frame's canvas items for ONE view, in SCENE TREE order — the
/// bottom-most node first, so the last item draws on top and the order
/// `Scene.pick` walks in reverse agrees with what is on screen.
///
/// The walk is the scene tree, not the tracked-surface table: a hash map
/// has no order, and drawing in map order put a subsurface or a later
/// popup UNDER an unrelated toplevel while the hit test found it on top.
/// Every disabled subtree is pruned on the way down, which is what makes
/// a minimized toplevel take its popups and subsurfaces with it.
///
/// Membership is the OUTPUT's camera, not the surface's placement: a
/// placement picks where a surface sits in the world (and which output
/// gets its configure sizes), while any camera whose visible world rect
/// meets the node draws it. Two outputs looking at the same window show
/// it at their own two different places.
///
/// Two kinds of surface are NOT world content and are emitted in the
/// `.screen` space instead: the session-lock screen and every layer
/// surface, which must COVER their output, and the drag icon, which must
/// sit AT the pointer. The cursor's own wl_surface and anything that is
/// not a lock surface while the session is locked are dropped here, the
/// one place the canvas pass chooses what to draw.
fn collectCanvasItems(
    self: *ServerState,
    lock: LockedFrame,
    view: *OutputView,
    items: *std.ArrayList(CanvasItem),
) void {
    const scene = self.scene orelse return;
    // The cursor's WlSurface is drawn ONLY as the cursor (compositeCursor),
    // never as a normal surface — matching wlroots (the cursor is a
    // separate plane, never a scene node) and niri (the cursor surface is
    // excluded from normal surface rendering via an early return on its
    // commit). Rendering it here too produced a SECOND cursor at the
    // surface's node position.
    const cursor_res = self.seat.cursorSurface();
    indexCanvasNodes(self);
    collectSubtree(self, view, lock, cursor_res, scene.root, world_frame, items);
}

/// The tracked surface behind every scene node the canvas pass may draw
/// — both the buffer node and the surface's container — rebuilt for the
/// frame the pass is about to walk. The scene's own table is keyed by
/// SURFACE and the tree walk needs the other direction; doing it once
/// per view keeps the walk O(nodes) instead of scanning the whole table
/// per node, and it is also what lets a descendant be drawn in the space
/// it inherited without re-deriving it. Retained across frames: nothing
/// is allocated once the map has grown.
///
/// The entry stores the EFFECTIVE space, inheritance included: every
/// node a local-space container owns reads `.output`/`.pointer`/`.hidden`
/// straight out of the index, so the walk below never has to carry the
/// space down itself and cannot disagree with `localSpaceOf`.
fn indexCanvasNodes(self: *ServerState) void {
    self.canvas_index.clearRetainingCapacity();
    var it = self.scene.?.surface_nodes.valueIterator();
    while (it.next()) |sn| {
        // Classifying ONCE per frame is what keeps the walk linear: the
        // classifier resolves the surface's role through the session-lock
        // and layer-shell registries and then walks its role-parent chain,
        // and asking per node per output per frame would be quadratic.
        const space = localSpaceOf(self, sn.*.surface);
        if (sn.*.node) |node| indexCanvasNode(self, node, sn.*.surface, space);
        if (sn.*.tree) |tree| indexCanvasNode(self, tree, sn.*.surface, space);
    }
}

fn indexCanvasNode(
    self: *ServerState,
    node: *wayland.scene.SceneNode,
    surface: *Surface,
    space: LocalSpace,
) void {
    self.canvas_index.put(self.allocator, node, .{ .surface = surface, .space = space }) catch |err| {
        log.warn("canvas node index OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
    };
}

/// What the canvas index holds for one scene node: the tracked surface it
/// belongs to (a buffer node and its container are indexed separately, to
/// the same entry) and the space that surface is composited in.
const CanvasNode = struct {
    surface: *Surface,
    space: LocalSpace,
};

/// The compositing space of a subtree, inherited from the surface that
/// owns the container above it. A subsurface, an xdg_popup on a layer
/// surface or a lock surface's child is composited WITH its overlay: the
/// output-local rule is a property of the overlay, not of one buffer
/// node, so nothing under one can slip back through the world camera.
const LocalSpace = union(enum) {
    /// Ordinary content, drawn through the output cameras.
    world,
    /// An overlay covering its output from that output's own (0, 0).
    output: *wayland.output.Output,
    /// An overlay anchored at the pointer, at its logical size.
    pointer: *wayland.output.Output,
    /// A local role with no output to be on yet: drawn nowhere, and not
    /// on any camera either — an unpinned overlay is HIDDEN, never
    /// world content.
    hidden,
};

/// Where `surface` is composited, INHERITANCE INCLUDED. THE single
/// classification the canvas pass, the hit test and the scene's
/// output-membership policy all read, so the three can never disagree
/// about what is on screen.
///
/// Output-local placement is a property of the OVERLAY, not of one buffer
/// node: a wl_subsurface of a layer surface, an xdg_popup parented to it
/// (xdg- or layer-parented) and a lock surface's child are all composited
/// WITH their overlay, at their own offsets inside it. So this asks the
/// surface's own role first and, when that role is ordinary world
/// content, keeps asking up the ROLE-PARENT chain until an overlay is
/// found. That chain is what stops a child from slipping back through the
/// world camera — in geometry (appendCanvasItem), in the hit test
/// (pickSurface) and in the scene's own membership/presentation/damage
/// (classifySurfacePlacement, which the library calls with no idea about
/// the scene tree).
fn localSpaceOf(self: *ServerState, surface: *Surface) LocalSpace {
    var cur: ?*Surface = surface;
    // NO depth limit: the walk visits every role parent the protocol
    // can create, however deeply nested, because a chain longer than
    // any fixed bound is legal and the old cutoff silently dropped such
    // a surface back into the world cameras — an output-local overlay
    // drawn through a camera, hit through a camera, and presented on
    // every output. The chain is ACYCLIC by construction, so the walk
    // always terminates: both role modules take a parent that already
    // exists (wl_subcompositor.get_subsurface, xdg_surface.get_popup)
    // and reject one that is a descendant of the child
    // (parentIsDescendant), so a parent can never reach its own child,
    // and a dying parent leaves its link null (subsurface.inert,
    // the popup role object destroyed with its parent) rather than
    // dangling. There is no malformed tree for a cutoff to guard.
    while (cur) |s| {
        const own = ownLocalSpace(self, s);
        if (isLocalSpace(own)) return own;
        cur = roleParentSurface(s);
    }
    return .world;
}

/// The wl_surface `s`'s own protocol role hangs off: the parent of a
/// wl_subsurface child, the parent of an xdg_popup. Null for a surface
/// with no role parent (a plain surface, an xdg_toplevel, a layer or lock
/// surface — those terminate the walk as overlays themselves).
///
/// Constant time: each role module recovers its own object from the wire
/// resource the role was assigned with, so this is one pointer chase per
/// hop and never a scan of a role registry. That is what keeps the
/// per-surface, per-frame walk in `localSpaceOf` linear.
fn roleParentSurface(s: *Surface) ?*Surface {
    return wayland.subsurface.parentSurfaceOf(s) orelse wayland.shell.parentSurfaceOf(s);
}

/// Where `surface` is composited by ITS OWN role, with no inheritance: the
/// drag icon follows the pointer, the session-lock screen and a layer
/// surface cover their output, everything else is world content. Only
/// `localSpaceOf` should call this — a caller that wants the space a
/// surface is actually drawn in wants the inherited answer.
fn ownLocalSpace(self: *ServerState, surface: *Surface) LocalSpace {
    // The drag icon follows the POINTER, so the output it belongs to is
    // whichever one the pointer is on right now.
    if (isDragIconSurface(surface)) {
        // The ROLE is permanent for the surface's lifetime, but the ICON
        // is only on screen while its drag lives: data_device is what
        // names the current one, and it stops naming it the moment the
        // drag ends. Classifying on the role alone left the icon glued to
        // the pointer after the drop — drawn, presented and a member of
        // the output for as long as the client kept the surface alive.
        // Hidden, not world content: the pixels the icon leaves behind
        // must come back to the background.
        if (self.data_device.currentDragIcon() != surface) return .hidden;
        const view = viewAtGlobalPoint(self, self.seat.pointer_x, self.seat.pointer_y) orelse return .hidden;
        return .{ .pointer = view.output };
    }
    if (self.session_lock) |sl| {
        for (sl.lockSurfaces()) |ls| {
            if (ls.surface != surface) continue;
            return .{ .output = ls.output };
        }
    }
    if (layerSurfaceForSurface(self, surface)) |ls| {
        // The output the client named, resolved to the backend output
        // behind its wl_output; otherwise the view the surface was
        // placed on. No output at all = no view to draw it on.
        if (ls.output) |res| {
            for (self.output_views.items) |view| {
                if (view.wl_output.owns(res)) return .{ .output = view.output };
            }
            return .hidden;
        }
        const view = viewForSurface(self, surface) orelse return .hidden;
        return .{ .output = view.output };
    }
    return .world;
}

/// Whether a compositing space is output-local rather than world content.
fn isLocalSpace(s: LocalSpace) bool {
    return switch (s) {
        .world => false,
        .output, .pointer, .hidden => true,
    };
}

/// The scene's output-placement policy, installed once (subscribe). It
/// answers the ONE question the library asks about a tracked surface: is
/// it world content an output camera shows, or an overlay that lives in
/// one output's own pixels? `localSpaceOf` decides, inheritance
/// included, so output membership, the presented list and damage
/// projection cannot drift from what the canvas pass actually drew — and
/// a subsurface or popup of an overlay is pinned with it, at any depth.
///
/// A local role with no output is `.output_local = null`: HIDDEN, never
/// world content. Falling back to `.world` there would advertise an
/// overlay to every camera on the desktop.
fn classifySurfacePlacement(ctx: ?*anyopaque, surface: *Surface) wayland.scene.SurfacePlacement {
    const self: *ServerState = @ptrCast(@alignCast(ctx.?));
    return switch (localSpaceOf(self, surface)) {
        .world => .world,
        .output, .pointer => |out| .{ .output_local = out },
        .hidden => .{ .output_local = null },
    };
}

/// Point the scene's placement policy at this state, so the library
/// classifies through the same rules the canvas pass draws by. A no-op
/// while there is no scene: the policy is installed when the first
/// output creates one.
fn installScenePlacementPolicy(self: *ServerState) void {
    const scene = self.scene orelse return;
    scene.setSurfacePlacementPolicy(self, classifySurfacePlacement);
}

/// Drop the policy. Load-bearing before the ServerState is freed: the
/// classifier names this state, and the library must not call it during
/// teardown.
fn clearScenePlacementPolicy(self: *ServerState) void {
    const scene = self.scene orelse return;
    scene.setSurfacePlacementPolicy(null, null);
}

/// An output-local subtree's placement: the space the whole subtree is
/// composited in, and the world rect of the ROOT overlay that space came
/// from. The root rect is what keeps a descendant where the client put
/// it: an item's own `absolutePosition` already carries every ancestor's
/// offset, so the anchor is subtracted back out and the anchor's own
/// position applied instead.
const LocalFrame = struct {
    space: LocalSpace,
    root: geom.FRect,
};

/// The frame the scene root is walked with: ordinary world content, with
/// no overlay root above it.
const world_frame: LocalFrame = .{
    .space = .world,
    .root = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

/// Append the canvas items for `node`'s enabled subtree, in draw order:
/// `node`'s own buffer first, then each child in order (a child-after-
/// parent append is what puts a popup above its parent and a subsurface
/// above the surface it belongs to). `frame` is what the containers above
/// this node decided, and a node that OWNS a local overlay starts a new
/// frame for its own subtree — that is what keeps a subsurface, popup or
/// lock-surface child of an output-local overlay out of the world
/// cameras and still at the offset the client gave it.
fn collectSubtree(
    self: *ServerState,
    view: *OutputView,
    lock: LockedFrame,
    cursor_res: ?*wire.wl.Surface,
    node: *wayland.scene.SceneNode,
    frame: LocalFrame,
    items: *std.ArrayList(CanvasItem),
) void {
    // A disabled node is not on screen, and neither is anything under it:
    // the minimize policy disables the surface's whole container
    // (onToplevelMinimize).
    if (!node.enabled) return;
    var here = frame;
    if (self.canvas_index.get(node)) |entry| {
        switch (entry.space) {
            // An overlay ROOT starts the space its subtree is drawn in,
            // anchored at THIS node. A DESCENDANT carries that same space
            // in its own index entry (inheritance already ran in
            // localSpaceOf) and must keep the anchor it was given: that is
            // exactly what preserves the offset the client put a
            // subsurface or popup at inside the overlay.
            .output, .pointer => {
                here = if (isLocalSpace(frame.space))
                    .{ .space = entry.space, .root = frame.root }
                else
                    .{ .space = entry.space, .root = node.absolutePosition() };
            },
            .hidden => here = .{ .space = .hidden, .root = frame.root },
            .world => {},
        }
    }
    if (node.kind == .buffer) {
        appendCanvasItem(self, view, lock, cursor_res, node, here, items);
    }
    for (node.children.items) |child| {
        collectSubtree(self, view, lock, cursor_res, child, here, items);
    }
}

/// One buffer node's item, or nothing when this view must not draw it.
fn appendCanvasItem(
    self: *ServerState,
    view: *OutputView,
    lock: LockedFrame,
    cursor_res: ?*wire.wl.Surface,
    node: *wayland.scene.SceneNode,
    frame: LocalFrame,
    items: *std.ArrayList(CanvasItem),
) void {
    const surface = (self.canvas_index.get(node) orelse return).surface;
    // ext_session_lock_v1:74-91 — while the session is locked "the
    // only surfaces that should be rendered ... are the lock surfaces
    // created through this interface". Everything else (user content,
    // popups, drag icons, the client cursor surface) is skipped here.
    if (lock.locked) {
        const sl = self.session_lock orelse return;
        if (!sl.isLockSurface(surface)) return;
    }
    if (cursor_res) |cr| {
        if (surface.resource == cr) return;
    }
    if (!surface.mapped) return;
    const bn = node.kind.buffer;
    const texture = bn.texture orelse return;
    const rect = node.absolutePosition();
    // The raw buffer -> surface map the draw has to invert, and the
    // raw buffer-pixel crop the sampler reads: the library's
    // SurfaceNode update already folded buffer_scale and the inverse
    // transform into the crop when the client committed, so the
    // compositor must NOT redo that conversion per frame. Null crop
    // (no wp_viewport.set_source) means the whole texture, byte for
    // byte what it always was.
    const src: ?geom.FRect = bn.src;

    switch (frame.space) {
        // A local role with no output: nothing is drawn anywhere.
        .hidden => return,
        // An output-local overlay: drawn in THAT output's own pixels,
        // never through a camera, at its logical size. Any other output
        // draws nothing of it. The position is the node's ABSOLUTE scene
        // rect minus the output's own origin: for the overlay's root that
        // is where the compositor placed it, and for a descendant it is
        // that same placement plus the offsets its ancestors carry — so a
        // child keeps the geometry the client asked for instead of being
        // restamped at the overlay's corner.
        .output => |out| {
            if (out != view.output) return;
            appendItem(self, items, .{
                .texture = texture,
                .world_x = rect.x - @as(f64, @floatFromInt(view.rect.x)),
                .world_y = rect.y - @as(f64, @floatFromInt(view.rect.y)),
                .world_w = rect.width,
                .world_h = rect.height,
                .opacity = 1.0,
                .src = src,
                .transform = bn.transform,
                .space = .screen,
            });
            return;
        },
        // The drag icon: AT THE POINTER, at logical size, on the output
        // the pointer is on — the cursor's own rule. The anchor is the
        // pointer, not the icon's scene node (syncDragIconNodes keeps that
        // on the pointer's world point so damage and membership follow the
        // pointer); a descendant of the icon is drawn at that anchor plus
        // its offset from the icon's own rect.
        .pointer => |out| {
            if (out != view.output) return;
            const at = dragIconRect(view) orelse return;
            appendItem(self, items, .{
                .texture = texture,
                .world_x = @as(f64, @floatFromInt(at.x)) + (rect.x - frame.root.x),
                .world_y = @as(f64, @floatFromInt(at.y)) + (rect.y - frame.root.y),
                .world_w = rect.width,
                .world_h = rect.height,
                .opacity = 1.0,
                .src = src,
                .transform = bn.transform,
                .space = .screen,
            });
            return;
        },
        .world => {},
    }
    // Ordinary world content: this camera draws it when it can see it.
    if (!view.scene_output.visibleWorldRect().intersects(rect)) return;
    appendItem(self, items, .{
        .texture = texture,
        .world_x = rect.x,
        .world_y = rect.y,
        .world_w = rect.width,
        .world_h = rect.height,
        .opacity = 1.0,
        .src = src,
        .transform = bn.transform,
    });
}

/// Append one item, logging an out-of-memory failure: a frame that cannot
/// hold an item simply does not draw that surface, which is the honest
/// degradation and never a fault in the middle of a composite.
fn appendItem(self: *ServerState, items: *std.ArrayList(CanvasItem), item: CanvasItem) void {
    items.append(self.allocator, item) catch |err| {
        log.warn("canvas item append OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
    };
}

/// Where the drag icon's top-left corner lands in `view`'s own pixels:
/// the pointer, when it is on this view at all.
fn dragIconRect(view: *OutputView) ?geom.Point {
    const gx = view.state.seat.pointer_x;
    const gy = view.state.seat.pointer_y;
    if (!view.rect.containsPoint(.{ .x = gx, .y = gy })) return null;
    return .{ .x = gx - view.rect.x, .y = gy - view.rect.y };
}

/// This frame's fill color as premultiplied ARGB8888 memory bytes
/// (B,G,R,A): the opaque lock color while the session is locked, the
/// background otherwise.
fn premultipliedFill(lock: LockedFrame) [4]u8 {
    const fill = if (lock.locked) lock_blank_color else background_color;
    return .{
        @intFromFloat(@round(fill[2] * 255.0)),
        @intFromFloat(@round(fill[1] * 255.0)),
        @intFromFloat(@round(fill[0] * 255.0)),
        @intFromFloat(@round(fill[3] * 255.0)),
    };
}

/// The GLES2 canvas target for ONE view, created on first use at that
/// view's scanout size and re-created if that size changes. Null when the
/// target cannot be created; the frame then keeps the previous canvas
/// instead of clearing it. Per view, because each output has its own size
/// and its own FBO — two outputs never share one color texture.
fn ensureGles2Target(view: *OutputView) ?*gles2.Gles2Target {
    const w = view.output.mode.width;
    const h = view.output.mode.height;
    if (view.gles2_target) |t| {
        if (t.width == w and t.height == h) return t;
        t.destroy();
        view.gles2_target = null;
    }
    const t = gles2.Gles2Target.create(view.allocator, view.state.renderer, w, h) catch |err| {
        log.err("gles2 target create failed: {s}", view.io, view.log_cfg, "server", .{@errorName(err)});
        return null;
    };
    view.gles2_target = t;
    return t;
}

/// The view's persisted base (the canvas WITHOUT the cursor), created on
/// first use at this view's size. Freed with the view.
fn ensureBaseFramebuffer(view: *OutputView) ?*pixman.Framebuffer {
    if (view.base_framebuffer) |fb| return fb;
    const fb = pixman.Framebuffer.create(
        view.allocator,
        view.output.mode.width,
        view.output.mode.height,
    ) catch |err| {
        log.err("base framebuffer create failed: {s}", view.io, view.log_cfg, "server", .{@errorName(err)});
        return null;
    };
    view.base_framebuffer = fb;
    view.capture_base_valid = false;
    return fb;
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
///
/// A zwp_linux_dmabuf_v1 buffer is a NATIVE image: it is imported as an
/// EGL image on the GPU and is never mapped, uploaded or copied. It
/// only reaches this function at all because buildOutput hands the
/// dmabuf module a device ONLY for the GPU renderer, so a pixman run
/// never sees one. The CPU branch refuses explicitly rather than
/// pretending: mapping the bo here would be a silent upload path behind
/// a global that promises zero-copy.
fn surfaceNodeImport(ctx: *anyopaque, s: *Surface, buf: *wayland.buffers.Buffer) ?*Texture {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    _ = s;
    if (buf.impl.get_dmabuf != null) {
        if (self.renderer_kind != .gles2) {
            log.err("surfnode: dmabuf buffer with the CPU renderer; no native path", self.io, self.log_cfg, "server", .{});
            return null;
        }
        return importDmabufTexture(self, buf);
    }
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
    // A native buffer names its own texture: updateDmabuf is true exactly
    // when this texture still holds THIS buffer's EGL image, so a
    // re-commit of the same bo is a no-op and a different bo (or a
    // texture that was a memory upload) falls through to the re-import
    // above. No mapping, no upload and no read-back on either path.
    if (buf.impl.get_dmabuf != null) {
        return self.renderer_kind == .gles2 and
            gles2.Gles2Renderer.updateDmabuf(texture, buf);
    }
    const pixels = surfacePixels(self, buf) orelse return false;
    const byte_len = @as(usize, @intCast(pixels.stride)) * @as(usize, @intCast(buf.height));
    // The same contract on both renderers — overwrite in place when the
    // geometry matches, false when the texture must be re-imported — so
    // the hot path has no per-renderer special case above it.
    return switch (self.renderer_kind) {
        .pixman => pixman.PixmanRenderer.updateMemory(
            texture,
            buf.width,
            buf.height,
            pixels.stride,
            pixels.ptr[0..byte_len],
        ),
        .gles2 => gles2.Gles2Renderer.updateMemory(
            texture,
            buf.width,
            buf.height,
            pixels.stride,
            pixels.ptr[0..byte_len],
        ),
    };
}

/// Compositor policy before the node syncs from a commit.
///
/// Two things, both keyed on this surface's container. A minimized
/// window comes back: onToplevelMinimize disabled the container and a
/// commit is the only event that can undo it (xdg-shell has no
/// un-minimize). And a subsurface orphan recovers — a surface whose
/// wl_subsurface died (the client destroyed the role object, or the
/// parent surface died; subsurface.zig tears the entry down and clears
/// the role) renders as a plain surface again, leaving the (possibly
/// dead) parent tree for the root and showing on its next commit
/// (wlroots recursively unmaps children with the parent,
/// wlr_compositor.c:854-872).
fn surfaceNodeBeforeUpdate(ctx: *anyopaque, sn: *wayland.surface_node.SurfaceNode) void {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    if (sn.tree) |tree| {
        // A commit is the restore path for a minimized window:
        // onToplevelMinimize hid this whole container, and "the client
        // drew again" is the only event that can bring it back (the
        // protocol has no un-minimize). It runs before the orphan
        // re-root below so a re-parented container ends up enabled
        // either way; the per-frame subsurface sync re-asserts its own
        // parenting decision afterwards.
        tree.enable(true);
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
    // The seat just sent wl_pointer.leave for a dead focus surface: drop
    // the cursor-shape serial NOW, while the stored focus pointer is
    // still readable, instead of letting the next sync compare against
    // freed memory.
    if (self.cursor_shape_focus == s) dropCursorShapeSerials(self);
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

/// Import a client's zwp_linux_dmabuf_v1 buffer as a GPU texture through
/// its native descriptors: one EGL image over the bo's own planes, with
/// no CPU mapping, upload or copy anywhere on this path (the renderer's
/// contract: it locks the Buffer and the texture keeps it until it is
/// destroyed or replaced). Null on failure, with the reason logged —
/// a surface that cannot import shows nothing, which is honest, and
/// never a CPU fallback behind a zero-copy promise.
fn importDmabufTexture(self: *ServerState, buf: *wayland.buffers.Buffer) ?*Texture {
    const t0 = perfNs(self);
    const tex = gles2.Gles2Renderer.importDmabuf(self.renderer, buf) catch |err| {
        log.err("dmabuf import failed: {s} ({d}x{d})", self.io, self.log_cfg, "server", .{
            @errorName(err), buf.width, buf.height,
        });
        return null;
    };
    if (self.perf) {
        log.info("perf dmabuf-import={d}us buf={d}x{d}", self.io, self.log_cfg, "perf", .{
            (perfNs(self) - t0) / 1000, buf.width, buf.height,
        });
    }
    return tex;
}

/// Copy the surface's current buffer into a renderer texture (same import
/// path the M1 render loop used per frame; the scene node owns the copy).
fn importSurfacePixels(self: *ServerState, buf: *wayland.buffers.Buffer, pixels: SurfacePixels) ?*Texture {
    const t0 = perfNs(self);
    const byte_len = @as(usize, @intCast(pixels.stride)) * @as(usize, @intCast(buf.height));
    // Both renderers take the same arguments and return the same
    // `*Texture`: the CPU one copies into pixman memory, the GLES2 one
    // uploads into a GL texture (gles2.zig's "# Wiring contract"), and
    // the rest of the compositor never has to know which it got.
    const imported = switch (self.renderer_kind) {
        .pixman => pixman.PixmanRenderer.importMemory(
            self.renderer,
            buf.width,
            buf.height,
            pixels.stride,
            pixels.ptr[0..byte_len],
        ),
        .gles2 => gles2.Gles2Renderer.importMemory(
            self.renderer,
            buf.width,
            buf.height,
            pixels.stride,
            pixels.ptr[0..byte_len],
        ),
    };
    const tex = imported catch |err| {
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

/// WAYLAND_BACKEND=nested selects the nested-wayland backend (M5): our
/// compositor acts as a client of a parent compositor. Requires a
/// WAYLAND_DISPLAY socket (the parent's); the backend fails to create if
/// absent.
fn wantNestedBackend(environ_map: *std.process.Environ.Map) bool {
    const v = environ_map.get("WAYLAND_BACKEND") orelse return false;
    return std.mem.eql(u8, v, "nested");
}

// ---------------------------------------------------------------------------
// M3: seat hit-test, screencopy sources, input bindings
// ---------------------------------------------------------------------------

/// A global DESKTOP pixel as a WORLD (scene) point, through the camera of
/// the output that pixel is on.
///
/// Two inversions compose, in this order: the desktop layout origin takes
/// the position to the output's own pixels, then that output's camera
/// takes it to world space. Both run in f64 and the result is never
/// narrowed, so a point far from the origin keeps its fraction (the old
/// path clamped it to i32 and lost it).
///
/// The VIEW is resolved from the given position, not from the seat's
/// current pointer: this conversion is also what an xdg_popup grab uses for
/// its inside/outside decision, which asks about a historical position.
fn screenToWorldIn(view: *OutputView, gx: i32, gy: i32) geom.FPoint {
    return view.camera.screenToWorld(
        @as(f64, @floatFromInt(gx - view.rect.x)),
        @as(f64, @floatFromInt(gy - view.rect.y)),
    );
}

/// Seat input is in DESKTOP pixels; scene nodes — and every popup origin
/// published by syncPopupNodes — are in WORLD pixels. This resolves the
/// output the position is on and inverts ITS camera, and is installed into
/// the shell through setScreenToWorld so an xdg_popup grab hit-tests its
/// inside/outside decision in the same space the popup was placed in
/// (xdg.zig popupGrabMotion / popupGrabButton). Without it the shell
/// assumes the identity map, which is right only until the first zoom or
/// pan (the camera is live: WAYLAND_CAMERA zoom is clamped to 0.1..16.0)
/// or until a second output exists.
fn screenToWorld(ctx: *anyopaque, sx: i32, sy: i32) geom.FPoint {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const view = viewAtGlobalPoint(self, sx, sy) orelse
        return .{ .x = @floatFromInt(sx), .y = @floatFromInt(sy) };
    return screenToWorldIn(view, sx, sy);
}

/// Seat hit test: the topmost surface under the DESKTOP pixel (x, y),
/// mapped back to its surface with surface-local coordinates.
///
/// One reverse scene-tree walk preserves draw order across both spaces.
/// Each leaf is tested in the space it is drawn in: camera-inverted world
/// coordinates or this output's own pixels. A non-covering local node
/// cannot hide world content merely because its world rect overlaps it.
fn pickSurface(ctx: *anyopaque, x: i32, y: i32) ?wayland.seat.Seat.PickResult {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const scene = self.scene orelse return null;
    const view = viewAtGlobalPoint(self, x, y) orelse return null;
    indexCanvasNodes(self);
    return pickViewSubtree(self, view, scene.root, self.shell.worldFromScreen(x, y), .{
        .x = @floatFromInt(x - view.rect.x),
        .y = @floatFromInt(y - view.rect.y),
    });
}

/// The output an output-local surface is pinned to, or null when its
/// role names none (nothing to draw or hit test it on).
fn pinnedOutput(self: *ServerState, surface: *Surface) ?*wayland.output.Output {
    return switch (localSpaceOf(self, surface)) {
        .world, .hidden => null,
        .output, .pointer => |out| out,
    };
}

/// Reverse of collectSubtree: children above their parent, later siblings
/// above earlier ones. Input-transparent leaves fall through; disabled
/// containers prune their children without clipping them to parent bounds.
fn pickViewSubtree(
    self: *ServerState,
    view: *OutputView,
    node: *wayland.scene.SceneNode,
    world: geom.FPoint,
    screen: geom.FPoint,
) ?wayland.seat.Seat.PickResult {
    if (!node.enabled or !node.pickable) return null;
    var i = node.children.items.len;
    while (i > 0) {
        i -= 1;
        if (pickViewSubtree(self, view, node.children.items[i], world, screen)) |hit| return hit;
    }
    if (node.kind != .buffer or node.kind.buffer.texture == null) return null;
    const entry = self.canvas_index.get(node) orelse return null;
    const surface = entry.surface;
    if (!surface.mapped) return null;
    if (self.seat.cursorSurface()) |cursor| {
        if (surface.resource == cursor) return null;
    }
    if (self.session_lock) |sl| {
        if (sl.isLocked() and !sl.isLockSurface(surface)) return null;
    }
    var rect = node.absolutePosition();
    const point = switch (entry.space) {
        .world => world,
        .output => |out| local: {
            if (out != view.output) return null;
            rect.x -= @as(f64, @floatFromInt(view.rect.x));
            rect.y -= @as(f64, @floatFromInt(view.rect.y));
            break :local screen;
        },
        .pointer, .hidden => return null,
    };
    if (!rect.containsPoint(point.x, point.y)) return null;
    const sx = point.x - rect.x;
    const sy = point.y - rect.y;
    if (!surfaceAcceptsInput(surface, sx, sy)) return null;
    return .{ .surface = surface, .sx = sx, .sy = sy };
}

/// wl_surface.set_input_region: does `surface` take pointer events at its
/// own surface-local (sx, sy)? No committed region is an infinite input
/// region (the whole surface); an empty one takes nothing — "an empty
/// input region will make the surface unselectable", which is what
/// turns the pointer over it into a miss and a leave. Region edges are
/// summed saturating, because a client rect may run past INT32_MAX
/// (geom.Rect.intersect does the same).
fn surfaceAcceptsInput(surface: *Surface, sx: f64, sy: f64) bool {
    const region = surface.current.input orelse return true;
    for (region.items) |r| {
        const x0: f64 = @floatFromInt(r.x);
        const y0: f64 = @floatFromInt(r.y);
        const x1: f64 = @floatFromInt(geom.addSat(r.x, r.width));
        const y1: f64 = @floatFromInt(geom.addSat(r.y, r.height));
        if (sx >= x0 and sy >= y0 and sx < x1 and sy < y1) return true;
    }
    return false;
}

/// L-D7: the live layer surface whose wl_surface is `surface`, or null.
/// Iterates the module's own registry (shell.layer_surfaces is pruned
/// on destroy) — the observability copy in ServerState.layer_surfaces
/// is append-only and can hold freed entries.
fn layerSurfaceForSurface(self: *const ServerState, surface: ?*Surface) ?*wayland.layer_shell.LayerSurface {
    const s = surface orelse return null;
    for (self.layer_shell.layer_surfaces.items) |ls| {
        if (ls.surface == s) return ls;
    }
    return null;
}

/// L-D7: give keyboard focus back to the surface focused before the
/// exclusive grab (wlroots: the grab ends when the pointer leaves the
/// layer surface). The saved surface may have been destroyed during the
/// grab — only a surface still alive in the compositor registry is
/// restored (compositor.surfaces is pruned on destroy, so membership is
/// the liveness check); otherwise the focus falls back to null.
fn restoreLayerFocus(self: *ServerState, seat: *wayland.seat.Seat, previous: ?*Surface) void {
    if (previous) |s| {
        if (std.mem.indexOfScalar(*Surface, self.compositor.surfaces.items, s) != null) {
            seat.setKeyboardFocus(s);
            return;
        }
    }
    seat.setKeyboardFocus(null);
}

/// L-D7: layer keyboard-interactivity focus routing. Runs on every
/// pointer move, after the seat has already updated its pointer focus
/// for the move: the layer surface under the pointer takes keyboard
/// focus per its committed keyboard_interactivity value (read from
/// current, layer_shell.zig applies pending at commit); the EXCLUSIVE
/// grab is released — and the pre-grab focus restored — the moment the
/// pointer is no longer over the grabbed layer.
fn applyLayerKeyboardFocus(self: *ServerState, seat: *wayland.seat.Seat) void {
    // Through the OVERLAY, not the surface under the pointer: the pick
    // answers with the topmost visible DESCENDANT (a subsurface, a popup
    // of the panel), and every keyboard rule in layer-shell is stated
    // about the layer surface itself.
    const over_ls = layerSurfaceForSurface(self, layerRootOf(self, seat.pointer_focus));
    const interactive: u32 = if (over_ls) |ls| ls.current.keyboard_interactive else 0;

    switch (layerFocusDecision(over_ls != null, interactive, self.layer_kbd_grab != null)) {
        .keep => {},
        .focus_layer => {
            const ls = over_ls.?;
            // The pointer moved from a grabbed exclusive layer onto this
            // one: release the old grab first (restoring its previous
            // focus) so a fresh grab captures the correct previous focus.
            if (self.layer_kbd_grab) |g| {
                if (g.layer != ls.surface) {
                    self.layer_kbd_grab = null;
                    restoreLayerFocus(self, seat, g.previous);
                }
            }
            // Start the exclusive grab, remembering the focus to restore
            // on pointer leave; a live grab on this layer stays untouched.
            if (interactive == 1 and self.layer_kbd_grab == null) {
                // If the layer already holds keyboard focus (a click gave
                // it focus before any pointer move — the initial pointer
                // position), the pre-grab focus is unrecoverable: the
                // grab then releases to null on leave instead of
                // restoring a stale surface.
                const previous: ?*Surface = if (seat.keyboard_focus == ls.surface) null else seat.keyboard_focus;
                self.layer_kbd_grab = .{ .layer = ls.surface, .previous = previous };
            }
            seat.setKeyboardFocus(ls.surface);
        },
        .restore_previous => {
            // The pointer is no longer over the grabbed layer (or the
            // layer no longer requests focus): release the grab and
            // restore the previous focus.
            const g = self.layer_kbd_grab orelse return;
            self.layer_kbd_grab = null;
            restoreLayerFocus(self, seat, g.previous);
        },
    }
}

/// L-D7: click-to-focus gate for the seat. Layer surfaces with
/// keyboard_interactivity=none must never receive keyboard focus: the
/// move-based policy never gives it to them, so the seat's built-in
/// click-to-focus must not either — and the property belongs to the
/// OVERLAY, so a click that landed on one of the panel's own descendants
/// (its menu, its toolbar, a wl_subsurface) is a click on the panel.
fn layerKeyboardFocusAllowed(ctx: *anyopaque, surface: *Surface) bool {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const ls = layerSurfaceForSurface(self, layerRootOf(self, surface)) orelse return true;
    return ls.current.keyboard_interactive != 0;
}

/// The layer surface whose output-local subtree `surface` belongs to: the
/// surface itself when it is one, else the nearest role-parent that is
/// (layerRootOf walks the same role-parent chain localSpaceOf does, so a
/// subsurface or a layer-parented popup resolves to its overlay).
/// Pointer focus is the topmost visible descendant, and every layer-shell
/// keyboard rule is stated about the overlay — so both the pointer-move
/// policy and the click-to-focus redirect resolve through this one walk.
fn layerRootOf(self: *ServerState, surface: ?*Surface) ?*Surface {
    var cur = surface;
    while (cur) |s| {
        if (layerSurfaceForSurface(self, s) != null) return s;
        cur = roleParentSurface(s);
    }
    return null;
}

/// L-D7 after a click that landed on an overlay's DESCENDANT: the seat's
/// click-to-focus gives the keyboard to whatever the pick returned, and
/// that is now the topmost visible child of the panel. Move the focus up
/// to the overlay, so the panel keeps the keyboard it asked for and keeps
/// its exclusive grab (whose release policy is stated about the pointer
/// leaving the LAYER, not one of its menus).
///
/// Runs on the button signal the seat emits AFTER its own focus work, and
/// not from a keyboard_focus handler: setKeyboardFocus from inside one
/// re-enters that signal's iteration — the same reason the lock block in
/// onSeatButton gives.
fn refocusLayerRoot(self: *ServerState, seat: *wayland.seat.Seat) void {
    const focus = seat.keyboard_focus orelse return;
    const root = layerRootOf(self, focus) orelse return;
    if (root == focus) return;
    seat.setKeyboardFocus(root);
}

/// The seat's click-to-focus gate: every surface that must never take
/// keyboard focus from a click, in the order the gates are consulted.
///
/// ext_session_lock_manager_v1, wiring item 2: while the session is
/// locked ONLY a lock surface may take focus, and `acceptsInput` is the
/// assertion that the surface really belongs to the lock client — a
/// click (the seat's built-in click-to-focus is the one path that can
/// move focus without a pointer move) cannot therefore land on user
/// content. ext_session_lock_surface_v1:252-256 leaves focus handling for
/// lock surfaces to the compositor; refusing everything else is the
/// policy sway and wlroots implement.
fn keyboardFocusAllowed(ctx: *anyopaque, surface: *Surface) bool {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    if (self.session_lock) |sl| {
        if (sl.isLocked()) {
            if (!sl.isLockSurface(surface)) return false;
            return sl.acceptsInput(surface.resource.getClient());
        }
    }
    return layerKeyboardFocusAllowed(ctx, surface);
}

/// The seat's touch gate: may `surface` receive a touch point right now.
///
/// ext_session_lock_manager_v1:77-85 is an INPUT privilege boundary, and
/// the lock-aware pick (pickSurface) only closes the POINTER half of it:
/// it stops a position from resolving to user content, which is what a
/// new touch-down needs, but it says nothing about a finger already down
/// when the session locked. Refusing the point here is what stops that
/// gesture from dragging user content for the whole locked interval —
/// the seat drops it exactly as it drops a missed pick (no down, no
/// enter, no focus change, nothing in activeTouchPoints), so the client
/// is never told about a point it may not act on.
///
/// Only lock surfaces pass, and `acceptsInput` is the assertion that the
/// surface really belongs to the lock client. Up and cancel are NOT
/// gated: they finalize a gesture the client was already told about, and
/// swallowing them would strand its state.
///
/// Read from LIVE lock state, so unlinking the lock listeners (or the
/// lock ending) restores touch by itself — the same teardown story as
/// setPick and setKeyboardFocusGate.
fn touchAllowed(ctx: *anyopaque, surface: *Surface) bool {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const sl = self.session_lock orelse return true;
    if (!sl.isLocked()) return true;
    if (!sl.isLockSurface(surface)) return false;
    return sl.acceptsInput(surface.resource.getClient());
}

/// The seat's grab gate: may a grab be INSTALLED right now.
///
/// ext_session_lock_v1:81-84 — once `locked` is sent the lock client is
/// the only input destination, and a grab diverts every input stream away
/// from the delivery path entirely. Enforcing that only in `onSessionLocked`
/// (which ends every grab once) leaves the latch unenforced: a client that
/// installs a grab afterwards takes every keystroke and pointer event on
/// the machine. `xdg_surface.get_popup`'s `grab` validates only a serial,
/// and the serial ring carries no time window, so the serial is no barrier.
///
/// Read from LIVE lock state, so unlocking restores grabs by itself —
/// the same teardown story as setPick / setKeyboardFocusGate /
/// setTouchGate.
fn grabAllowed(ctx: *anyopaque, _: *wayland.seat.Seat) bool {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const sl = self.session_lock orelse return true;
    return !sl.isLocked();
}

// ---------------------------------------------------------------------------
// ext_session_lock_manager_v1 + wp_cursor_shape_manager_v1 wiring
//
// shell/session_lock.zig and shell/cursor_shape.zig hold the protocol
// state and refuse to lie about it; the gates the client actually feels
// (which surface the pointer hits, what may take keyboard focus, what
// gets composited) live here. See each handler for the contract item it
// implements.
// ---------------------------------------------------------------------------

/// `locked`: the privilege boundary closed. This runs INSIDE the lock
/// surface's commit dispatch, before renderFrame can composite, so the
/// first frame after it is already a locked frame (wiring item 1).
fn onSessionLocked(
    listener: *wire.Listener(*wayland.session_lock.SessionLock),
    sl: *wayland.session_lock.SessionLock,
) void {
    const self: *ServerState = @fieldParentPtr("session_locked_listener", listener);
    // The buttons a client believes it is holding are the FIRST thing the
    // latch takes, and they must go BEFORE the pointer focus moves below:
    // from here on the lock client is the only input destination
    // (ext_session_lock_v1:81-84), so the release a pressed client is owed
    // can no longer be routed to it — the seat sends a physical release by
    // its cached pointer_focus, and that focus is about to be cleared (or
    // moved onto the lock surface, where the release would reach a client
    // that never saw a press).
    flushHeldPointerButtons(self.seat);
    // A compositor gesture armed before the latch ends HERE, beside the
    // grab teardown below. It cannot end on its own later: the release
    // branch in onSeatButton is gated on the very lock that armed it, so a
    // live camera drag or interactive move keeps its seat grab — and with
    // it the swallowed pointer the lock client must be getting.
    _ = endPointerGestures(self.seat, &self.gestures);
    // End EVERY compositor grab: a grab routes input to whoever it names,
    // and the lock client must be the only input destination
    // (ext_session_lock_v1:81-84). endPointerGrab/endKeyboardGrab are
    // unconditional — a grab installed by another subsystem (a DnD drag,
    // an xdg_popup grab) must not survive the latch either.
    self.seat.endPointerGrab();
    self.seat.endKeyboardGrab();
    // The layer keyboard grab is ours: release it without restoring its
    // previous surface, which would put focus back on user content.
    self.layer_kbd_grab = null;
    // The POINTER must leave user content too. pointer_focus is refreshed
    // by exactly one thing — Seat.pointerMotion (seat.zig:884-891) — and
    // that returns early under a pointer grab, so the cache still named
    // whatever the user had hovered when the latch fired. Both
    // pointerButton (seat.zig:1015) and pointerAxisDir (seat.zig:1125)
    // route by that cache, so the next click delivered its press AND its
    // release to a client the lock is supposed to be deaf to. The grab
    // ended on the line above, so re-running the seat's own refresh at the
    // pointer's CURRENT position is the state transition, not a guard:
    // pickSurface drops everything that is not a lock surface while the
    // session is locked, so the seat either sends wl_pointer.leave to the
    // user client and clears the focus, or enters the lock surface the
    // pointer really is over (session_lock.zig:99-103 — a null pick makes
    // the pointer leave and no client see motion or buttons).
    self.seat.pointerMotion(self.seat.pointer_x, self.seat.pointer_y);
    // Force keyboard focus onto a lock surface. The seat delivers keys
    // only to the focused surface's client (seat.zig:1339-1346), so this
    // is what actually suppresses typing to every other client. The XML
    // leaves focus policy for lock surfaces to the compositor
    // (ext_session_lock_surface_v1:252-256); focusing the lock surface is
    // the policy sway and wlroots implement.
    if (sl.lockSurfaces().len > 0) {
        self.seat.setKeyboardFocus(sl.lockSurfaces()[0].surface);
    }
    // Hide the cursor: a locked session must not show where the pointer
    // is. The canvas pass consults `lock.locked` (compositeCanvas), and
    // this flag is the assertion the server keeps for its own state.
    self.cursor_hidden = true;
    // The latch is set: schedule the frame that blanks the outputs. A
    // frame built before the latch must never be composited afterwards.
    requestRender(self);
    log.info("session locked: input suppressed, outputs blanked", self.io, self.log_cfg, "server", .{});
}

/// `unlock_and_destroy`: the gates come off and normal service resumes.
fn onSessionUnlocked(
    listener: *wire.Listener(*wayland.session_lock.SessionLock),
    _: *wayland.session_lock.SessionLock,
) void {
    const self: *ServerState = @fieldParentPtr("session_unlocked_listener", listener);
    // Drop the focus we forced: only a LOCK surface may lose focus here,
    // so a normal focus the client earned in the meantime is untouched.
    if (self.session_lock) |sl| {
        if (self.seat.keyboard_focus) |focus| {
            if (sl.isLockSurface(focus)) self.seat.setKeyboardFocus(null);
        }
    }
    self.layer_kbd_grab = null;
    self.cursor_hidden = false;
    requestRender(self);
    log.info("session unlocked: input and rendering restored", self.io, self.log_cfg, "server", .{});
}

/// A lock surface is fully configured (role assigned, first configure
/// sent). Track its wl_surface like any other surface and put its scene
/// node over the output it covers — a lock surface is an ordinary
/// wl_surface, so syncSurfaces picks it up, and the canvas pass draws it
/// because compositeBase filters on isLockSurface.
fn onNewLockSurface(
    listener: *wire.Listener(*wayland.session_lock.LockSurface),
    ls: *wayland.session_lock.LockSurface,
) void {
    const self: *ServerState = @fieldParentPtr("new_lock_surface_listener", listener);
    syncSurfaces(self);
    if (self.scene) |scene| {
        if (wayland.surface_node.surfaceNodeFor(scene, ls.surface) != null) {
            // The lock screen is configured to the output's logical size,
            // so its node belongs on THAT output's canvas: the lock
            // surface is pinned to the view it locks, and the tree
            // placement pass below keeps it there.
            const view = viewForOutput(self, ls.output) orelse return;
            self.surface_place.put(self.allocator, ls.surface, .{
                .view = view,
                .placed = false,
            }) catch |err| {
                log.warn("lock surface placement OOM: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            };
        }
    }
    requestRender(self);
}

/// A lock surface stopped covering its output (its object, its
/// wl_surface or its output died, or the lock ended). Its scene node must
/// go with it: an unlocked session that still composited the lock screen
/// would show a stale privilege boundary as ordinary content. detach()
/// keeps the surface tracked, so a later remap (a new lock on the same
/// wl_surface) gets its node back on the next commit.
fn onLockSurfaceGone(
    listener: *wire.Listener(*wayland.session_lock.LockSurface),
    ls: *wayland.session_lock.LockSurface,
) void {
    const self: *ServerState = @fieldParentPtr("lock_surface_gone_listener", listener);
    if (self.scene) |scene| {
        if (wayland.surface_node.surfaceNodeFor(scene, ls.surface)) |sn| sn.detach();
    }
    // outputIsBlank now reports true for that output: composite it.
    requestRender(self);
}

/// wp_cursor_shape_device_v1.set_shape was accepted. This compositor
/// paints ONE cursor image for every shape (shell/cursor_shape.zig: the
/// module records the request and isDrawableShape says whether a
/// different image would be drawn — here only `.default` has artwork), so
/// the handler records the change and nothing more.
fn onCursorShapeChanged(
    listener: *wire.Listener(*wayland.cursor_shape.ShapeChange),
    change: *wayland.cursor_shape.ShapeChange,
) void {
    const self: *ServerState = @fieldParentPtr("cursor_shape_changed_listener", listener);
    const drawable = wayland.cursor_shape.CursorShape.isDrawableShape(change.shape);
    log.info(
        "cursor shape {s} (serial {d}){s}",
        self.io,
        self.log_cfg,
        "cursor_shape",
        .{ @tagName(change.shape), change.serial, if (drawable) "" else " — no artwork for this shape, same sprite drawn" },
    );
}

/// Detach a listener that may never have been added, or may already be
/// detached (a link whose prev is null panics on remove). Teardown
/// reaches a ServerState from two places — the harness tears the modules
/// down early and again in deinit — so every unlink must be idempotent.
fn unlinkOne(comptime T: type, l: *wire.Listener(T)) void {
    if (l.link.prev != null) l.link.remove();
}

/// Unlink the session-lock listeners from a dying ServerState (main's
/// teardown). The module outlives the state only through its own deinit,
/// which can emit lock_surface_gone.
fn unlinkSessionLockListeners(state: *ServerState) void {
    unlinkOne(*wayland.session_lock.SessionLock, &state.session_locked_listener);
    unlinkOne(*wayland.session_lock.SessionLock, &state.session_unlocked_listener);
    unlinkOne(*wayland.session_lock.LockSurface, &state.new_lock_surface_listener);
    unlinkOne(*wayland.session_lock.LockSurface, &state.lock_surface_gone_listener);
    unlinkOne(*wayland.cursor_shape.ShapeChange, &state.cursor_shape_changed_listener);
}

/// Keep wp_cursor_shape_manager_v1's pointer-device serials in step with
/// the seat's pointer enter/leave (shell/cursor_shape.zig: set_shape must
/// quote the latest wl_pointer.enter serial or the request is ignored).
///
/// The seat exposes no enter/leave signal, so the server observes the one
/// field that changes: `pointer_focus`. The seat has exactly ONE pointer
/// focus, so at most one client can hold a valid serial at a time —
/// recording it for the focused client's wl_pointers and dropping it for
/// every other one is exact, not an approximation. A client may bind more
/// wl_pointers after the enter, so the pointer count is part of the
/// change test: a resource that never saw the enter must not inherit it.
fn syncCursorShapeSerials(self: *ServerState) void {
    const cs = self.cursor_shape orelse return;
    const seat = self.seat;
    const focus = seat.pointer_focus;
    if (focus == self.cursor_shape_focus and seat.pointers.items.len == self.cursor_shape_pointers) return;
    self.cursor_shape_focus = focus;
    self.cursor_shape_pointers = seat.pointers.items.len;
    for (seat.pointers.items) |ptr| {
        const focused = if (focus) |f| ptr.getClient() == f.resource.getClient() else false;
        if (focused) {
            cs.enterPointer(ptr, seat.pointer_enter_serial);
        } else {
            cs.leavePointer(ptr);
        }
    }
}

/// Drop every recorded wp_cursor_shape serial: the pointer left the
/// surface the serial was recorded for and that surface is about to be
/// freed, so the stored focus is cleared here rather than compared again
/// later.
fn dropCursorShapeSerials(self: *ServerState) void {
    self.cursor_shape_focus = null;
    if (self.cursor_shape) |cs| {
        for (self.seat.pointers.items) |ptr| cs.leavePointer(ptr);
    }
    self.cursor_shape_pointers = self.seat.pointers.items.len;
}

/// Capture source for zwlr_screencopy: THIS OUTPUT's display framebuffer
/// (cursor composited in) for overlay_cursor=1, THIS OUTPUT's base (the
/// canvas without the cursor) for overlay_cursor=0.
///
/// The `out` argument is what makes a capture output-SPECIFIC: a client
/// that names the second wl_output gets the second output's pixels, never
/// the first one's.
///
/// On the GPU DRM path there is no CPU front to hand over, so the capture
/// is produced by an EXPLICIT, LAZY read-back of this output alone:
///   - overlay_cursor=1 re-renders the canvas and the cursor into this
///     view's capture FBO and reads THAT back;
///   - overlay_cursor=0 renders the base only — the cursor is never drawn
///     into the capture pass at all, so "no cursor" is a real exclusion
///     rather than a stale frame or another output's image;
/// and the result is reused until this view composites again. No capture
/// ever happens as a side effect of the scanout path.
fn getFramebuffer(
    ctx: *anyopaque,
    out: *wayland.output.Output,
    overlay_cursor: bool,
) ?*pixman.Framebuffer {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const view = viewForOutput(self, out) orelse return null;
    if (!view.gpu) {
        if (!overlay_cursor) {
            if (view.base_framebuffer) |base| return base;
        }
        return view.framebuffer;
    }
    return gpuCapture(self, view, overlay_cursor);
}

/// The explicit read-back one GPU-scanned-out view's capture needs.
fn gpuCapture(
    self: *ServerState,
    view: *OutputView,
    overlay_cursor: bool,
) ?*pixman.Framebuffer {
    if (overlay_cursor) {
        if (view.capture_frame_valid) return view.capture_frame;
    } else if (view.capture_base_valid) return view.capture_base;
    const target = ensureCaptureTarget(view) orelse return null;
    const fb = ensureCaptureFramebuffer(view, overlay_cursor) orelse return null;
    var input = directFrameInput(view);
    // The cursor is EXCLUDED by not drawing it, not by handing back a
    // frame that happens not to have one in it.
    if (!overlay_cursor) input.lock.cursor_hidden = true;
    if (!compositeBaseGles2(view, input, target)) return null;
    gles2.Gles2Renderer.finishRendering(self.renderer) catch |err| {
        log.err("screencopy render completion failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
        return null;
    };
    target.readPixelsInto(fb) catch |err| {
        log.err("screencopy read-back failed on {d}x{d}: {s}", self.io, self.log_cfg, "server", .{
            view.output.mode.width, view.output.mode.height, @errorName(err),
        });
        return null;
    };
    if (overlay_cursor) view.capture_frame_valid = true else view.capture_base_valid = true;
    return fb;
}

/// The offscreen FBO a GPU view's captures are rendered into. Created on
/// first use at this view's size, freed with the view — never shared with
/// another output, so a capture can never pick up another output's pixels.
fn ensureCaptureTarget(view: *OutputView) ?*gles2.Gles2Target {
    const w = view.output.mode.width;
    const h = view.output.mode.height;
    if (view.capture_target) |t| {
        if (t.width == w and t.height == h) return t;
        t.destroy();
        view.capture_target = null;
    }
    const t = gles2.Gles2Target.create(view.allocator, view.state.renderer, w, h) catch |err| {
        log.err("capture target create failed: {s}", view.io, view.log_cfg, "server", .{@errorName(err)});
        return null;
    };
    view.capture_target = t;
    return t;
}

/// The CPU storage one capture kind reads into. Owned by the view and
/// reused: a repeated capture of an unchanged canvas allocates nothing.
fn ensureCaptureFramebuffer(view: *OutputView, overlay_cursor: bool) ?*pixman.Framebuffer {
    const slot = if (overlay_cursor) &view.capture_frame else &view.capture_base;
    if (slot.*) |fb| return fb;
    const fb = pixman.Framebuffer.create(
        view.allocator,
        view.output.mode.width,
        view.output.mode.height,
    ) catch |err| {
        log.err("capture framebuffer create failed: {s}", view.io, view.log_cfg, "server", .{@errorName(err)});
        return null;
    };
    slot.* = fb;
    return fb;
}

/// Resolve a client's wl_output resource to the output it belongs to, by
/// asking EVERY view's global — with two outputs the first one is not the
/// answer by default any more.
fn outputFromResource(ctx: *anyopaque, resource: *wayland.server.wl.Output) ?*wayland.output.Output {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    for (self.output_views.items) |view| {
        if (view.wl_output.owns(resource)) return view.output;
    }
    return null;
}

/// A screencopy frame is waiting for its NEXT COMMIT on this output: wake
/// that view's renderer (the idle-frame skip would otherwise never render
/// the copy) and no other view's.
fn requestFrame(ctx: *anyopaque, out: *wayland.output.Output) void {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const view = viewForOutput(self, out) orelse {
        requestRender(self);
        return;
    };
    requestRenderView(self, view);
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

/// One-shot repeat timer tick: emit the held key's repeat + re-arm at
/// the seat's repeat deadline (the remaining time to it) while the key
/// is held; otherwise stay dead.
fn onRepeatTick(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const self: *ServerState = @ptrCast(@alignCast(completion.userdata.?));
    if (!self.seat.repeatActive()) {
        self.repeat_timer_armed = false;
        return;
    }
    self.seat.onRepeatTick();
    // Re-arm against the seat's actual repeat deadline, not a fixed
    // interval (S7): a marginally-early tick must not skip the emission
    // AND advance the deadline by a full interval. After an emission the
    // deadline is in the future (advanced inside onRepeatTick), so the
    // remaining time is positive; an early tick re-arms for the exact
    // remaining time instead. Clamped to [1, interval] so the timer
    // never spins on a 0-duration arm. Both clocks are CLOCK_MONOTONIC
    // ms (the seat's nowMs is the same source).
    const remaining: i64 = self.seat.repeatNextAt() - @as(i64, self.seat.nowMs());
    const interval: i64 = @intCast(self.seat.repeatIntervalMs());
    const arm_ms: u32 = @intCast(@max(@as(i64, 1), @min(interval, remaining)));
    loop.setTimer(self.repeat_timer.?, .{ .duration = zio.Duration.fromMilliseconds(arm_ms) });
}

/// M4 camera drag: the left button press anchors a pan gesture; motion
/// while held pans the camera. A click without motion never moves the
/// pointer between press and release, so it keeps the seat's
/// click-to-focus (already handled inside the seat).
fn onSeatButton(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_button_listener", listener);
    // ext_session_lock_manager_v1: a locked session is about the user's
    // content, not the compositor's own gestures. The camera pan must not
    // arm (and must not install the pointer grab that swallows input) on
    // a press that belongs to the lock client.
    if (self.session_lock) |sl| {
        if (sl.isLocked()) {
            // The keyboard belongs to the lock client, and the module's
            // contract re-asserts the lock focus on every focus change
            // (session_lock.zig:104-108). The one-shot assignment in
            // onSessionLocked is not an invariant: a press that hits
            // nothing clears the focus (seat.zig:995, this server's
            // null-pick policy) and deafens the lock screen until
            // something focuses it again — and with the lock surface
            // covering less than the output, "a click on empty canvas" is
            // a click the user makes on purpose. Re-asserted HERE, on the
            // button signal the seat emits after its own focus work, and
            // not in onSeatKeyboardFocus: setKeyboardFocus from inside a
            // keyboard_focus handler re-enters that signal's safe
            // iteration, whose uninitialized cursor node would then be
            // notified as if it were a listener (wire.Signal.emitInner).
            const focus = seat.keyboard_focus;
            if (focus == null or !sl.isLockSurface(focus.?)) {
                if (sl.lockSurfaces().len > 0) {
                    seat.setKeyboardFocus(sl.lockSurfaces()[0].surface);
                }
            }
            return;
        }
    }
    // L-D7 with a descendant under the pointer: the seat's click-to-focus
    // just gave the keyboard to the topmost surface the pick returned,
    // which is the panel's own child rather than the panel. Move it up to
    // the overlay before the pan gesture below arms. Runs on the button
    // signal the seat emits after its own focus work, for the same
    // re-entrancy reason as the lock block above.
    refocusLayerRoot(self, seat);
    if (seat.last_button != wayland.seat.btn_left) return;
    if (seat.last_button_pressed) {
        // Arm the pan anchor but DON'T start it (drag_active stays false):
        // a click without enough movement must keep click-to-focus.
        // The gesture is PINNED to the output the pointer is on: a drag
        // that starts on the second output pans THAT output's camera, and
        // crossing into the first one mid-drag does not hand the camera
        // over (the pinned view owns it until the release).
        self.gestures.view = viewAtGlobalPoint(self, seat.pointer_x, seat.pointer_y);
        self.gestures.camera_drag = DragPoint{ .x = seat.pointer_x, .y = seat.pointer_y };
        self.gestures.drag_active = false;
        self.gestures.fast_render = false;
    } else {
        // The release ends OUR gesture and OUR grab, and only ours: an
        // unconditional endPointerGrab here cancelled an in-flight DnD
        // drag (the target got leave with no drop) and dismissed popup
        // grabs (P1-3).
        const was_moving = self.gestures.moving_toplevel != null;
        _ = endPointerGestures(seat, &self.gestures);
        if (was_moving) {
            log.info("interactive move end", self.io, self.log_cfg, "server", .{});
        }
        // A drag that just dropped took its icon off the canvas, so the
        // next frame must recomposite (the hover path below would only
        // repaint the cursor region).
        if (self.data_device.currentDragIcon() == null) requestRender(self);
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
    // wp_cursor_shape_manager_v1: the seat has just updated its pointer
    // focus (and minted the wl_pointer.enter serial) for this move, so
    // this is where the server records it (shell/cursor_shape.zig).
    syncCursorShapeSerials(self);
    // ext_session_lock_manager_v1: a locked session suppresses the
    // compositor's own pointer gestures as well. The layer focus routing
    // is skipped too: focus belongs to the lock surface, and
    // restoreLayerFocus would otherwise put a stale user surface back.
    if (self.session_lock) |sl| {
        if (sl.isLocked()) {
            for (self.output_views.items) |view| view.cursor_repaint = false;
            return;
        }
    }
    // L-D7: layer keyboard-interactivity focus routing. The seat already
    // updated its pointer focus for this move; apply the layer policy on
    // top (exclusive grab / on_demand focus / none exclusion). During a
    // compositor grab (camera drag, interactive move) the seat froze the
    // pointer focus, so this is a no-op there.
    applyLayerKeyboardFocus(self, seat);
    // The output this move belongs to: the one the pointer is over. Every
    // camera change below is applied to a PINNED view only, so a drag
    // that starts on the second output never moves the first one's camera.
    const view = viewAtGlobalPoint(self, seat.pointer_x, seat.pointer_y) orelse return;
    // Interactive move: the toplevel's node follows the pointer delta in
    // the PINNED view's world (the screen delta divided by ITS zoom,
    // matching the pick transform). The whole output is damaged so the
    // partial upload cannot smear the old position.
    if (self.gestures.moving_toplevel) |t| {
        const gesture_view = self.gestures.view orelse view;
        const wp = screenToWorldIn(gesture_view, seat.pointer_x, seat.pointer_y);
        const dx = wp.x - self.gestures.move_anchor.x;
        const dy = wp.y - self.gestures.move_anchor.y;
        self.gestures.move_anchor = .{ .x = wp.x, .y = wp.y };
        if (self.scene) |scene| {
            if (wayland.surface_node.surfaceNodeFor(scene, t.xdg_surface.surface)) |sn| {
                if (sn.node) |node| {
                    // f64 node positions: the delta is applied exactly,
                    // never rounded to a whole pixel first.
                    node.setPosition(node.x + dx, node.y + dy);
                }
            }
        }
        gesture_view.scene_output.addDamage(OutputView.localRect(gesture_view));
        requestRenderView(self, gesture_view);
        return;
    }
    // A drag is armed (button held). If it hasn't crossed the threshold
    // yet, a sub-threshold move is a hover (cursor follows, no pan); once
    // it crosses, start the pan.
    //
    // Never pan while ANOTHER subsystem owns the pointer: a
    // wl_data_device drag or an xdg popup grab installed its grab at its
    // own request, and grabPointerForGesture would replace it — the
    // replaced grab's cancel ends that gesture, so panning the canvas
    // silently killed the drag under the pointer. Same "ours vs theirs"
    // rule endPointerGestures applies on the release (P1-3): our arming
    // is dropped and the move falls through to the hover path, which
    // keeps a live drag icon following the pointer.
    if (self.gestures.camera_drag != null and seat.pointer_grab != null and
        seat.pointer_grab != self.gestures.own_grab)
    {
        self.gestures.camera_drag = null;
        self.gestures.drag_active = false;
        self.gestures.fast_render = false;
    }
    if (self.gestures.camera_drag) |anchor| {
        const dx = seat.pointer_x - anchor.x;
        const dy = seat.pointer_y - anchor.y;
        if (!self.gestures.drag_active and dx * dx + dy * dy < drag_threshold_sq) {
            // A sub-threshold hover: repaint the cursor in the view it
            // left (its old cursor pixels come back from the base) and in
            // the view it is now over.
            markCursorHover(self, self.gestures.view, view);
            return;
        }
        // Above the threshold (or already dragging): pan the PINNED
        // view's camera. The implicit pointer grab starts here: the
        // client under the pointer must not see the motion (it would
        // extend a text selection while the user pans the canvas).
        const target = self.gestures.view orelse view;
        self.gestures.drag_active = true;
        self.gestures.fast_render = true;
        grabPointerForGesture(seat, &self.gestures);
        target.camera.center_x -= @as(f64, @floatFromInt(dx)) / target.camera.zoom;
        target.camera.center_y -= @as(f64, @floatFromInt(dy)) / target.camera.zoom;
        self.gestures.camera_drag = DragPoint{ .x = seat.pointer_x, .y = seat.pointer_y };
        log.debug("camera center -> {d},{d}", self.io, self.log_cfg, "camera", .{
            target.camera.center_x, target.camera.center_y,
        });
        // The pan moved every pixel of the PINNED view and none of the
        // others: only that view is asked to repaint.
        requestRenderView(self, target);
        return;
    }
    // No drag armed: hover — the canvas is static, so just move the cursor
    // (repaint only the cursor region, not the full composite). A live
    // drag icon moves the canvas too, so that frame must recomposite for
    // the icon to follow the pointer — on the view the pointer is over.
    if (self.data_device.currentDragIcon() != null) {
        requestRenderView(self, view);
        return;
    }
    markCursorHover(self, null, view);
}

/// Ask the views involved in a hover for the cheap cursor-only repaint:
/// the one the pointer just left (its old cursor pixels have to be
/// restored from the base) and the one it is now over. Each gets its own
/// flag, so neither view paints a cursor the user cannot see there.
fn markCursorHover(self: *ServerState, from: ?*OutputView, to: *OutputView) void {
    if (from) |old| {
        if (old != to) {
            old.cursor_repaint = true;
            requestRenderView(self, old);
        }
    }
    to.cursor_repaint = true;
    requestRenderView(self, to);
}

/// M4 camera zoom: a vertical wheel notch (+1 discrete) multiplies the
/// SELECTED view's camera zoom by 1.25, -1 divides; clamped to
/// [0.1, 16.0]. The zoom is a per-output viewport property, so a notch
/// delivered over the second output zooms the second output — and it
/// applies regardless of pointer focus (the seat emits the axis signal
/// for every axis event).
fn onSeatAxis(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_axis_listener", listener);
    // A locked session must not zoom the canvas under the lock client.
    if (self.session_lock) |sl| {
        if (sl.isLocked()) return;
    }
    if (seat.last_axis != .vertical_scroll or seat.last_axis_discrete == 0) return;
    const view = viewAtGlobalPoint(self, seat.pointer_x, seat.pointer_y) orelse return;
    const factor: f64 = if (seat.last_axis_discrete > 0) 1.25 else 1.0 / 1.25;
    var steps: i32 = seat.last_axis_discrete;
    if (steps < 0) steps = -steps;
    var zoom = view.camera.zoom;
    var i: i32 = 0;
    while (i < steps) : (i += 1) zoom *= factor;
    view.camera.zoom = std.math.clamp(zoom, 0.1, 16.0);
    log.debug("camera zoom -> {d}", self.io, self.log_cfg, "camera", .{view.camera.zoom});
    requestRenderView(self, view);
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
/// F12: position popup surface nodes over their parent (the subsurface
/// pattern): a popup's tree becomes a child of the parent's tree,
/// offset by the popup geometry (parent-surface-local). This gives
/// popups their correct position, makes scene.pick hit-test them at
/// their offset, and (child-after-parent append) stacks them above the
/// parent's subsurfaces — the scene renders children in append order.
/// Runs each frame, before damage translation; cheap (no-op when the
/// tree is already placed).
fn syncPopupNodes(self: *ServerState) void {
    const scene = self.scene orelse return;
    for (self.shell.popups.items) |p| {
        // Layer-parented popups anchor to a layer surface (L1) — the
        // parent's own tree is at the layer's position already; xdg
        // popups anchor to the parent xdg surface.
        const parent_surface = if (p.parent) |px| px.surface else p.layer_parent orelse continue;
        const popup_sn = wayland.surface_node.surfaceNodeFor(scene, p.xdg_surface.surface) orelse continue;
        const popup_tree = popup_sn.tree orelse continue;
        const parent_sn = wayland.surface_node.surfaceNodeFor(scene, parent_surface) orelse continue;
        if (parent_sn.tree) |parent_tree| {
            if (popup_tree.parent != parent_tree) {
                parent_tree.appendChild(scene.allocator, popup_tree) catch |err| {
                    log.warn("popup parenting failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
                    popup_tree.enable(false);
                    continue;
                };
            }
            // f64 scene positions: the popup's own geometry offset inside
            // the parent's tree, unchanged in meaning.
            popup_tree.setPosition(@floatFromInt(p.geometry.x), @floatFromInt(p.geometry.y));
            popup_tree.enable(true);
            // P1-5b: publish the popup's ABSOLUTE scene position. The
            // popup grab converts the seat's scene coordinates into
            // surface-local ones with this origin, and the seat never
            // hit-tests while a grab is installed — so this sync is the
            // only place that can know it. `absolutePosition` sums the
            // node's own offset and every ancestor's (scene.zig:264),
            // and `p` (the shell.popups entry) is the role object.
            const abs = popup_tree.absolutePosition();
            p.setPopupOrigin(abs.x, abs.y);
        }
    }
}

/// True for a surface carrying the wl_data_device-icon role: the icon
/// of an in-flight wl_data_device.start_drag, which the role assigns at
/// the request (data_device.zig, wlr_drag.c:411-415). A drag icon is
/// not window content — it is composited at the POINTER and it vanishes
/// with the drag, so the canvas pass must never stamp it at its own node
/// position. wlroots instead parents the icon surface node under the
/// cursor node (wlr_drag.c:402-442); the equivalent here is the pointer
/// position written by syncDragIconNodes.
fn isDragIconSurface(s: *Surface) bool {
    const role = s.role orelse return false;
    return std.mem.eql(u8, role.name, "wl_data_device-icon");
}

/// Keep the drag icon's scene node on the pointer while its drag lives
/// (P2-12). Same pass shape as syncPopupNodes / syncSubsurfaceNodes: it
/// runs every frame from renderFrame, before the composite, and is a
/// no-op when no drag is running (a null check).
///
/// The icon is an ordinary tracked surface (syncSurfaces tracks every
/// compositor surface), so this pass keeps its tree at the scene ROOT (a
/// role surface has no parent tree) so it stacks with the other
/// top-level surfaces, and positions it at the pointer's WORLD point on
/// the output the pointer is over — the seat reports desktop pixels, and
/// inverting that output's camera is what turns them into world. An
/// unmapped icon has no tree yet (SurfaceNode creates it on the first
/// buffer commit), so an icon that has not committed costs nothing here.
///
/// The DRAW is not this rect: the icon is composited as a `.screen`
/// overlay at the pointer at its logical size (collectCanvasItem), which
/// is where a drag icon belongs — a scaled icon under a zoomed camera is
/// not a cursor. The node position is what keeps its damage, membership
/// and hit test on the pointer. Once the drag ends the icon is drawn
/// nowhere at all: data_device no longer names it, and `ownLocalSpace`
/// classifies an icon no drag names as `.hidden` — the role alone is
/// permanent and would otherwise keep the icon on screen.
fn syncDragIconNodes(self: *ServerState) void {
    const scene = self.scene orelse return;
    const icon = self.data_device.currentDragIcon() orelse return;
    const sn = wayland.surface_node.surfaceNodeFor(scene, icon) orelse return;
    const tree = sn.tree orelse return; // unmapped: nothing to draw yet
    if (tree.parent != scene.root) {
        scene.root.appendChild(scene.allocator, tree) catch |err| {
            log.warn("drag icon parenting failed: {s}", self.io, self.log_cfg, "server", .{@errorName(err)});
            tree.enable(false);
            return;
        };
    }
    const view = viewAtGlobalPoint(self, self.seat.pointer_x, self.seat.pointer_y) orelse return;
    const world = view.camera.screenToWorld(
        @as(f64, @floatFromInt(self.seat.pointer_x - view.rect.x)),
        @as(f64, @floatFromInt(self.seat.pointer_y - view.rect.y)),
    );
    tree.setPosition(world.x, world.y);
    tree.enable(true);
}

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
            // Offset relative to the parent tree (which carries the view's
            // desktop origin), in the f64 scene positions the cutover
            // introduced.
            child_tree.setPosition(@floatFromInt(ss.x), @floatFromInt(ss.y));
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

// ---------------------------------------------------------------------------
// Tests: the compositor's own policy (pointer-grab ownership, the
// xdg_toplevel state answers, the popup origin, the drag icon).
//
// They drive the REAL ServerState and the REAL policy functions above, so
// they need main()'s module stack minus the render loop (the fake backend
// below never starts and in_render keeps requestRender inert).
// build.zig runs this file's tests through src/server/main_test.zig.
// ---------------------------------------------------------------------------

const client = wayland.client;
const testing = std.testing;

/// A never-started backend: the policy tests render no frame, they only
/// need a real Output object for the fullscreen / maximize geometry.
const TestBackendImpl = struct {
    fn start(_: *wayland.backend.Backend) error{BackendFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const test_backend_impl: wayland.backend.Backend.Impl = .{
    .start = TestBackendImpl.start,
    .destroy = TestBackendImpl.destroy,
};

const TestOutputImpl = struct {
    fn setState(_: *wayland.output.Output, _: *const wayland.output.Output.State) error{InvalidState}!void {}
    fn commit(_: *wayland.output.Output, _: *const wayland.output.Output.State) error{CommitFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const test_output_impl: wayland.output.Output.Impl = .{
    .@"test" = TestOutputImpl.setState,
    .commit = TestOutputImpl.commit,
    .destroy = TestOutputImpl.destroy,
};

/// The client's xdg_toplevel events, recording the payload of the LAST
/// configure (the one under test).
const ClientToplevelEvents = struct {
    configures: usize = 0,
    width: i32 = 0,
    height: i32 = 0,
    states: [13]u32 = @splat(0),
    states_len: usize = 0,

    fn listener(toplevel: *client.xdg.Toplevel, event: client.xdg.Toplevel.Event, data: *ClientToplevelEvents) void {
        _ = toplevel;
        switch (event) {
            .configure => |c| {
                data.configures += 1;
                data.width = c.width;
                data.height = c.height;
                const s = c.states.slice(u32);
                const n = @min(s.len, data.states.len);
                data.states_len = s.len;
                @memcpy(data.states[0..n], s[0..n]);
            },
            .close => {},
            // configure_bounds / wm_capabilities are not armed by the
            // compositor here; ignore them so `width`/`height` keep
            // meaning the configure's size.
            .configure_bounds => |c| {
                _ = c;
            },
            .wm_capabilities => |c| {
                _ = c;
            },
        }
    }

    /// True when the last configure carried the xdg_toplevel.state
    /// `state` (the wire numbering xdg.zig's stateValues emits).
    fn carries(data: *const ClientToplevelEvents, state: u32) bool {
        for (data.states[0..data.states_len]) |v| {
            if (v == state) return true;
        }
        return false;
    }
};

/// xdg_toplevel.state wire values (xdg-shell.xml enumeration order).
const state_maximized: u32 = 1;
const state_fullscreen: u32 = 2;
const state_activated: u32 = 4;

/// The client's xdg_surface events, and the harness's ONLY ack_configure
/// driver. The compositor's half of the double buffer (`current`) moves
/// exactly once per ack (xdg.zig:415-434: `applyAckedConfigure` is called
/// from the ack request alone), so a harness that records the serial and
/// never acks can only assert on `scheduled` — the state the server wrote
/// microseconds earlier, right by construction — and never on the half a
/// client actually lives in. Acking here closes that gap: every configure
/// a test provokes completes the full request -> configure -> ack ->
/// current cycle.
///
/// `auto_ack = false` is the deferred mode (createToplevelDeferredAck):
/// the test observes the PRE-ack state and calls ackToplevelConfigure
/// itself, which is the only way to see that `current` is still unmoved.
const ClientXdgSurfaceEvents = struct {
    configures: usize = 0,
    serial: u32 = 0,
    acks: usize = 0,
    auto_ack: bool = true,

    fn listener(xdg_surface: *client.xdg.Surface, event: client.xdg.Surface.Event, data: *ClientXdgSurfaceEvents) void {
        switch (event) {
            .configure => |c| {
                data.configures += 1;
                data.serial = c.serial;
                // Requests from an event handler are ordinary libwayland
                // traffic: the proxy marshals into the same outgoing
                // buffer and the ack leaves with the next flush
                // (PolicyServer.pump: flush -> server dispatch -> flush ->
                // client dispatch, so the ack needs ONE more pump).
                if (data.auto_ack) {
                    xdg_surface.ackConfigure(c.serial);
                    data.acks += 1;
                }
            },
        }
    }
};

const ClientPopupEvents = struct {
    done_count: usize = 0,

    fn listener(popup: *client.xdg.Popup, event: client.xdg.Popup.Event, data: *ClientPopupEvents) void {
        _ = popup;
        switch (event) {
            .popup_done => data.done_count += 1,
            else => {},
        }
    }
};

/// The client's wl_data_source events: which end of the drag-and-drop the
/// client was told about. dnd_finished is the drop/finish half (a mouse
/// drag ends on the origin button's release), so it separates that from
/// the cancel half, which sends nothing (Drag.end, data_device.zig).
const ClientDataSourceEvents = struct {
    dnd_finished: usize = 0,
    dnd_drop_performed: usize = 0,
    cancelled: usize = 0,

    fn listener(source: *client.wl.DataSource, event: client.wl.DataSource.Event, data: *ClientDataSourceEvents) void {
        _ = source;
        switch (event) {
            .dnd_finished => data.dnd_finished += 1,
            .dnd_drop_performed => data.dnd_drop_performed += 1,
            .cancelled => data.cancelled += 1,
            .target => |t| {
                _ = t;
            },
            .send => |s| {
                _ = s;
            },
            .action => |a| {
                _ = a;
            },
        }
    }
};

fn ignoreOutputEvents(_: *client.wl.Output, _: client.wl.Output.Event, _: *u8) void {}

fn ignoreLayerEvents(_: *client.zwlr.LayerSurfaceV1, _: client.zwlr.LayerSurfaceV1.Event, _: *u8) void {}

const PolicyRegistryCapture = struct {
    compositor_name: ?u32 = null,
    wm_base_name: ?u32 = null,
    shm_name: ?u32 = null,
    seat_name: ?u32 = null,
    ddm_name: ?u32 = null,
    output_name: ?u32 = null,
    layer_shell_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *PolicyRegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "xdg_wm_base")) {
                    data.wm_base_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_shm")) {
                    data.shm_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_data_device_manager")) {
                    data.ddm_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_output")) {
                    data.output_name = g.name;
                } else if (std.mem.eql(u8, name, "zwlr_layer_shell_v1")) {
                    data.layer_shell_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// The full (interface, name, version) list a fresh wl_registry is told
/// about. The tearing-control module's RegistryCapture shape, widened to
/// keep the version: a global is only advertised if it is advertised AT
/// the version this server implements, and a removed global is
/// observable because a NEW registry only receives the globals that
/// still exist.
const PolicyGlobalCapture = struct {
    const max_globals = 64;
    /// The interface string is COPIED, not pointed at: libwayland hands
    /// `wl_registry.global` its interface as a `[*:0]const u8` INTO the
    /// connection's read buffer (the generated event carries the raw
    /// pointer), and the next read on that connection overwrites the
    /// buffer. A stored pointer therefore compares against whatever the
    /// buffer holds later — which is how a capture could report a global
    /// as missing that the server had just advertised.
    const max_interface_len = 64;
    const Entry = struct {
        interface: [max_interface_len]u8 = @splat(0),
        interface_len: usize = 0,
        name: u32 = 0,
        version: u32 = 0,
    };
    entries: [max_globals]Entry = @splat(.{}),
    len: usize = 0,

    fn listener(_: *client.wl.Registry, event: client.wl.Registry.Event, self: *PolicyGlobalCapture) void {
        switch (event) {
            .global => |g| {
                if (self.len >= self.entries.len) return;
                const entry = &self.entries[self.len];
                const s = std.mem.span(g.interface);
                const n = @min(s.len, entry.interface.len - 1);
                @memcpy(entry.interface[0..n], s[0..n]);
                entry.interface[n] = 0;
                entry.interface_len = n;
                entry.name = g.name;
                entry.version = g.version;
                self.len += 1;
            },
            .global_remove => {},
        }
    }

    fn find(self: *const PolicyGlobalCapture, interface: []const u8) ?*const Entry {
        for (self.entries[0..self.len]) |*e| {
            if (std.mem.eql(u8, e.interface[0..e.interface_len], interface)) return e;
        }
        return null;
    }
};

/// main()'s module stack (minus the render loop) with an in-memory client,
/// so the policy functions under test run against the real modules. The
/// ServerState is the REAL one: the tests call the production policy
/// functions directly, so no part of the behaviour is restated here.
const PolicyServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    /// Every module the policy functions read is built by init() in
    /// dependency order and may fail anywhere along the way, so each slot
    /// starts null and the `errdefer if (ts.x) |x| x.deinit()` unwinds
    /// exactly the ones that exist (the TestServer idiom, data_device.zig
    /// :1763 and xdg.zig:2979). Nothing is read before init() assigns it:
    /// a field's non-null value is the proof the module it names was
    /// constructed, so no field is ever observed uninitialized.
    state: ?*ServerState = null,
    display: ?*wayland.core.display.CompositorDisplay = null,
    shm_state: ?*wayland.shm.ShmState = null,
    compositor: ?*wayland.compositor.Compositor = null,
    shell: ?*wayland.shell.XdgShell = null,
    layer_shell: ?*wayland.layer_shell.LayerShell = null,
    seat: ?*wayland.seat.Seat = null,
    xdg_activation: ?*wayland.xdg_activation.XdgActivation = null,
    xdg_decoration: ?*wayland.xdg_decoration.XdgDecoration = null,
    fractional_scale: ?*wayland.fractional_scale.FractionalScale = null,
    viewporter: ?*wayland.viewporter.Viewporter = null,
    subcompositor: ?*wayland.subsurface.Subcompositor = null,
    data_device: ?*wayland.data_device.DataDeviceManager = null,
    primary_selection: ?*wayland.primary_selection.PrimarySelection = null,
    /// The nine protocol modules main() constructs after the seat. The
    /// harness builds them in the same order so the registry it shows a
    /// client is main()'s registry (see init).
    pointer_gestures: ?*wayland.pointer_gestures.PointerGestures = null,
    relative_pointer: ?*wayland.relative_pointer.RelativePointer = null,
    pointer_constraints: ?*wayland.pointer_constraints.PointerConstraints = null,
    tablet: ?*wayland.tablet.Tablet = null,
    cursor_shape: ?*wayland.cursor_shape.CursorShape = null,
    tearing_control: ?*wayland.tearing_control.TearingControl = null,
    session_lock: ?*wayland.session_lock.SessionLock = null,
    data_control: ?*wayland.data_control.DataControlManager = null,
    foreign_toplevel: ?*wayland.foreign_toplevel.ForeignToplevelManager = null,
    /// zwp_linux_dmabuf_v1, registered only when a GBM device exists. The
    /// test backend has none, so this stays null and the global is absent
    /// — the module's documented gate, not a wiring gap.
    linux_dmabuf: ?*wayland.linux_dmabuf.LinuxDmabuf = null,
    /// zxdg_output_manager_v1 + zwlr_screencopy_manager_v1: main()
    /// advertises both, so the harness mirrors them and a client sees the
    /// same global set here as on the running server.
    xdg_output: ?*wayland.xdg_output.XdgOutput = null,
    screencopy: ?*wayland.screencopy.Screencopy = null,
    renderer: ?*wayland.renderer.Renderer = null,
    /// The pixman renderer the ServerState hands the cursor (see
    /// ServerState.pixman_renderer); identical to `renderer` unless
    /// the harness was built with the GLES2 one.
    pixman_renderer: ?*wayland.renderer.Renderer = null,
    presentation: ?*wayland.presentation.Presentation = null,
    backend: ?*wayland.backend.Backend = null,
    output: ?*wayland.output.Output = null,
    /// The output's OutputView, built by the production factory: a test
    /// renders through the same camera, scene output, wl_output global
    /// and target lifecycle main() uses, never a test-only stand-in.
    view: ?*OutputView = null,
    scene: ?*wayland.scene.Scene = null,
    /// Backend / Output impl context (never dereferenced).
    dummy: u8 = 0,
    /// The surface the harness pick returns (the drag origin).
    pick_surface: ?*Surface = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wm_base: ?*client.xdg.WmBase = null,
    wl_shm: ?*client.wl.Shm = null,
    wl_seat: ?*client.wl.Seat = null,
    ddm: ?*client.wl.DataDeviceManager = null,
    wl_output_client: ?*client.wl.Output = null,
    layer_shell_client: ?*client.zwlr.LayerShellV1 = null,
    output_listener_data: u8 = 0,
    layer_listener_data: u8 = 0,
    shm_pool: ?*client.wl.ShmPool = null,
    buffer: ?*client.wl.Buffer = null,
    /// The pool of a createFilledBuffer buffer, retained like shm_pool so
    /// the buffer stays valid for the whole test.
    filled_pool: ?*client.wl.ShmPool = null,
    /// The pool of a createFixtureBuffer buffer: its own slot so a
    /// transform-parity test's fixture never displaces the retention
    /// reference the other buffer helpers keep.
    fixture_pool: ?*client.wl.ShmPool = null,
    /// A second SERVER-side client with nothing bound (the session-lock
    /// input assertions need a client that is NOT the lock client), plus
    /// its open peer fd: closing it would look like a disconnect at the
    /// next dispatch.
    idle_client: ?*wire.Client = null,
    idle_peer: ?std.posix.socket_t = null,
    /// Extra outputs a two-output test added through addSecondOutput, and
    /// that it has NOT destroyed: freed in deinit after their views are
    /// gone. removeOutput takes the entry out of this list FIRST, because
    /// Output.destroy frees the Output itself and a second destroy would
    /// be a double free.
    extra_outputs: std.ArrayList(*wayland.output.Output) = .empty,

    /// The compositor hit test for the tests: always the one surface the
    /// test armed it with (a drag's origin check needs the pointer to be
    /// over the origin surface), behind the SAME lock filter the real hit
    /// test applies (pickSurface:3717-3719). Without that half the harness
    /// would keep handing the seat a user surface while the session is
    /// locked — the one thing the compositor must never do — and no input
    /// policy would be observable.
    fn pick(ctx: *anyopaque, x: i32, y: i32) ?wayland.seat.Seat.PickResult {
        const ts: *PolicyServer = @ptrCast(@alignCast(ctx));
        const s = ts.pick_surface orelse return null;
        if (ts.session_lock) |sl| {
            if (sl.isLocked() and !sl.isLockSurface(s)) return null;
        }
        // The harness pick echoes the DESKTOP pixel back: the surface-local
        // coordinates are f64 now, and inventing a fraction here would be
        // a test artifact rather than a compositor behaviour.
        return .{ .surface = s, .sx = @floatFromInt(x), .sy = @floatFromInt(y) };
    }

    /// The default harness: pixman, the configuration every policy test
    /// has always run under.
    fn init(allocator: std.mem.Allocator) !*PolicyServer {
        return initWithRenderer(allocator, .pixman);
    }

    /// The harness with the renderer main() would pick for
    /// WAYLAND_RENDERER=<kind>. Everything else — the registry, the
    /// modules, the scene, the client — is identical, so a test that
    /// switches kind compares like with like.
    fn initWithRenderer(allocator: std.mem.Allocator, kind: RendererKind) !*PolicyServer {
        const ts = try allocator.create(PolicyServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try wayland.core.display.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        try ts.display.?.initShm();
        ts.shm_state = try wayland.shm.ShmState.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.shm_state) |s| s.deinit();
        ts.compositor = try wayland.compositor.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.compositor.?.setShm(ts.shm_state.?);
        ts.shell = try wayland.shell.XdgShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
        errdefer if (ts.shell) |s| s.deinit();
        ts.layer_shell = try wayland.layer_shell.LayerShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
        errdefer if (ts.layer_shell) |ls| ls.deinit();
        ts.seat = try wayland.seat.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();
        ts.xdg_activation = try wayland.xdg_activation.XdgActivation.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.seat.?,
            ts.compositor.?,
        );
        errdefer if (ts.xdg_activation) |xa| xa.deinit();
        ts.xdg_decoration = try wayland.xdg_decoration.XdgDecoration.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.shell.?,
        );
        errdefer if (ts.xdg_decoration) |xd| xd.deinit();
        ts.fractional_scale = try wayland.fractional_scale.FractionalScale.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.fractional_scale) |fs| fs.deinit();
        ts.viewporter = try wayland.viewporter.Viewporter.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.viewporter) |v| v.deinit();
        ts.subcompositor = try wayland.subsurface.Subcompositor.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.compositor.?,
        );
        errdefer if (ts.subcompositor) |sc| sc.deinit();
        ts.data_device = try wayland.data_device.DataDeviceManager.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.seat.?,
        );
        errdefer if (ts.data_device) |dd| dd.deinit();
        ts.primary_selection = try wayland.primary_selection.PrimarySelection.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.seat.?,
        );
        errdefer if (ts.primary_selection) |ps| ps.deinit();
        // main()'s post-seat module stack, in the same order (each
        // errdefer unwinds exactly the modules that exist).
        ts.pointer_gestures = try wayland.pointer_gestures.PointerGestures.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.seat.?,
        );
        errdefer if (ts.pointer_gestures) |pg| pg.deinit();
        ts.relative_pointer = try wayland.relative_pointer.RelativePointer.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.seat.?,
        );
        errdefer if (ts.relative_pointer) |rp| rp.deinit();
        ts.pointer_constraints = try wayland.pointer_constraints.PointerConstraints.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.compositor.?,
            ts.seat.?,
        );
        errdefer if (ts.pointer_constraints) |pc| pc.deinit();
        ts.tablet = try wayland.tablet.Tablet.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.tablet) |tb| tb.deinit();
        ts.cursor_shape = try wayland.cursor_shape.CursorShape.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.tablet.?,
        );
        errdefer if (ts.cursor_shape) |cs| cs.deinit();
        ts.tearing_control = try wayland.tearing_control.TearingControl.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.tearing_control) |tc| tc.deinit();
        ts.session_lock = try wayland.session_lock.SessionLock.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.session_lock) |sl| sl.deinit();
        ts.data_control = try wayland.data_control.DataControlManager.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.seat.?,
            ts.data_device.?,
            ts.primary_selection.?,
        );
        errdefer if (ts.data_control) |dc| dc.deinit();
        ts.foreign_toplevel = try wayland.foreign_toplevel.ForeignToplevelManager.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.shell.?,
            ts.seat.?,
        );
        errdefer if (ts.foreign_toplevel) |ft| ft.deinit();
        // zwp_linux_dmabuf_v1: the module registers its global only for a
        // GBM device, and the test backend has none — the documented
        // "null device, no global" state. main() passes
        // drm_backend.gbmDevice() for exactly the same reason.
        ts.linux_dmabuf = try wayland.linux_dmabuf.LinuxDmabuf.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            null,
        );
        errdefer if (ts.linux_dmabuf) |ld| ld.deinit();
        // zxdg_output_manager_v1: advertised by main() too.
        ts.xdg_output = try wayland.xdg_output.XdgOutput.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.xdg_output) |xo| xo.deinit();
        // The renderer the state composites with, exactly as main()
        // selects it (WAYLAND_RENDERER): a test that pins the GLES2
        // path builds the harness with `initWithRenderer(., .gles2)`
        // and every surface texture is imported through that renderer
        // from then on.
        ts.pixman_renderer = try pixman.PixmanRenderer.create(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.pixman_renderer) |r| r.destroy();
        ts.renderer = switch (kind) {
            .pixman => ts.pixman_renderer.?,
            .gles2 => try gles2.Gles2Renderer.create(allocator, &ts.io, &ts.log_cfg),
        };
        errdefer if (ts.renderer != ts.pixman_renderer) {
            ts.renderer.?.destroy();
        };
        ts.presentation = try wayland.presentation.Presentation.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.presentation) |p| p.deinit();
        ts.backend = try wayland.backend.Backend.init(allocator, &ts.io, &ts.log_cfg, &test_backend_impl, &ts.dummy);
        errdefer if (ts.backend) |b| b.destroy();
        ts.output = try wayland.output.Output.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.backend.?,
            &test_output_impl,
            &ts.dummy,
            .{ .width = 800, .height = 600, .refresh_msec = 16 },
        );
        errdefer if (ts.output) |o| o.destroy();
        // The scene is created up front (the harness owns it) and the
        // OutputView is built through the PRODUCTION factory, so a test
        // drives the same per-output wiring main() builds: camera, scene
        // output, wl_output global, render and capture targets.
        ts.scene = try wayland.scene.Scene.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.scene) |sc| sc.deinit();
        ts.scene.?.subcompositor = ts.subcompositor.?;

        // The real ServerState: the tests drive the production policy
        // functions, so the fields they read must be the real modules.
        const state = try allocator.create(ServerState);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .io = &ts.io,
            .log_cfg = &ts.log_cfg,
            .display = ts.display.?,
            .compositor = ts.compositor.?,
            .shm_state = ts.shm_state.?,
            .shell = ts.shell.?,
            .layer_shell = ts.layer_shell.?,
            .xdg_activation = ts.xdg_activation.?,
            .xdg_decoration = ts.xdg_decoration.?,
            .fractional_scale = ts.fractional_scale.?,
            .viewporter = ts.viewporter.?,
            .pointer_gestures = ts.pointer_gestures.?,
            .relative_pointer = ts.relative_pointer.?,
            .pointer_constraints = ts.pointer_constraints.?,
            .tablet = ts.tablet.?,
            .cursor_shape = ts.cursor_shape.?,
            .tearing_control = ts.tearing_control.?,
            .session_lock = ts.session_lock.?,
            .data_control = ts.data_control.?,
            .foreign_toplevel = ts.foreign_toplevel.?,
            .linux_dmabuf = ts.linux_dmabuf.?,
            .renderer = ts.renderer.?,
            .pixman_renderer = ts.pixman_renderer.?,
            .renderer_kind = kind,
            .backend = ts.backend.?,
            .camera_env = null,
            .scene = ts.scene.?,
            .seat = ts.seat.?,
            .subcompositor = ts.subcompositor.?,
            .data_device = ts.data_device.?,
            .primary_selection = ts.primary_selection.?,
            .presentation = ts.presentation.?,
            .toplevels = .empty,
            .layer_surfaces = .empty,
            .layer_popups = .empty,
            .new_output_listener = wire.Listener(*wayland.output.Output).init(onNewOutput),
            .new_input_listener = wire.Listener(*wayland.backend.Backend.InputDevice).init(onNewInput),
            .input_removed_listener = wire.Listener(*wayland.backend.Backend.InputDevice).init(onInputRemoved),
            .content_dirty_listener = wire.Listener(*wayland.scene.Scene).init(onSceneContentDirty),
            .new_toplevel_listener = wire.Listener(*wayland.shell.XdgToplevel).init(onNewToplevel),
            .new_popup_listener = wire.Listener(*wayland.shell.XdgPopup).init(onNewPopup),
            .new_activation_token_listener = wire.Listener(*wayland.xdg_activation.ActivationToken)
                .init(onNewActivationToken),
            .new_layer_surface_listener = wire.Listener(*wayland.layer_shell.LayerSurface).init(onNewLayerSurface),
            .new_layer_popup_listener = wire.Listener(*wayland.shell.XdgPopup).init(onNewLayerPopup),
            .request_activate_listener = wire.Listener(*wayland.xdg_activation.ActivateRequest).init(onRequestActivate),
            .request_mode_listener = wire.Listener(*wayland.xdg_decoration.RequestMode).init(onDecorationMode),
            .new_decoration_listener = wire.Listener(*wayland.xdg_decoration.Decoration).init(onNewDecoration),
            .seat_focus_listener = wire.Listener(*wayland.seat.Seat).init(onSeatKeyboardFocus),
            .seat_key_listener = wire.Listener(*wayland.seat.Seat).init(onSeatKey),
            .seat_button_listener = wire.Listener(*wayland.seat.Seat).init(onSeatButton),
            .seat_pointer_move_listener = wire.Listener(*wayland.seat.Seat).init(onSeatPointerMove),
            .seat_axis_listener = wire.Listener(*wayland.seat.Seat).init(onSeatAxis),
            .session_locked_listener = wire.Listener(*wayland.session_lock.SessionLock).init(onSessionLocked),
            .session_unlocked_listener = wire.Listener(*wayland.session_lock.SessionLock).init(onSessionUnlocked),
            .new_lock_surface_listener = wire.Listener(*wayland.session_lock.LockSurface).init(onNewLockSurface),
            .lock_surface_gone_listener = wire.Listener(*wayland.session_lock.LockSurface).init(onLockSurfaceGone),
            .cursor_shape_changed_listener = wire.Listener(*wayland.cursor_shape.ShapeChange).init(onCursorShapeChanged),
        };
        ts.state = state;

        // The harness output's OutputView, built by the PRODUCTION
        // factory: a test renders through the same camera, scene output,
        // wl_output global and target lifecycle main() uses. No frame is
        // ever PRESENTED here (the test backend's commit is a stub), so
        // in_render stays set and requestRender only marks repaint_pending.
        const view = createOutputView(state, ts.output.?) orelse return error.ViewCreateFailed;
        ts.view = view;
        view.in_render = true;
        // The first output's enable commit, exactly as onNewOutput makes
        // it (the frame test below needs `enabled` for sendFrame).
        var init_state = wayland.output.Output.State.init(allocator);
        defer init_state.deinit();
        init_state.committed = wayland.output.Output.State.committed_enabled |
            wayland.output.Output.State.committed_mode;
        init_state.enabled = true;
        init_state.mode = ts.output.?.mode;
        try ts.output.?.commitState(&init_state);

        // The production subscriptions the tests exercise.
        ts.shell.?.events.new_toplevel.add(&state.new_toplevel_listener);
        ts.shell.?.events.new_popup.add(&state.new_popup_listener);
        ts.layer_shell.?.events.new_layer_surface.add(&state.new_layer_surface_listener);
        ts.layer_shell.?.events.new_popup.add(&state.new_layer_popup_listener);
        ts.seat.?.events.keyboard_focus.add(&state.seat_focus_listener);
        ts.seat.?.events.button.add(&state.seat_button_listener);
        ts.seat.?.events.pointer_move.add(&state.seat_pointer_move_listener);
        // xdg_activation_v1: main() subscribes this in subscribe(), and it
        // is the route a client uses to ASK for keyboard focus, so a
        // test of the focus policy has to reach it the same way.
        ts.xdg_activation.?.events.request_activate.add(&state.request_activate_listener);
        ts.seat.?.setPick(PolicyServer.pick, ts);
        // main()'s gate: the session lock first, then L-D7's layer policy.
        ts.seat.?.setKeyboardFocusGate(keyboardFocusAllowed, state);
        // main()'s touch gate (ext_session_lock_manager_v1 wiring item 2
        // for touch): the same live-state callback, so a locked session
        // refuses a point on user content here exactly as it does in the
        // running server.
        ts.seat.?.setTouchGate(touchAllowed, state);
        // main()'s other two policy seams: the foreign-toplevel activate
        // gate (the third route to keyboard focus) and the popup grab's
        // screen->world conversion.
        ts.foreign_toplevel.?.setFocusGate(state, keyboardFocusAllowed);
        ts.shell.?.setScreenToWorld(screenToWorld, state);
        // main()'s grab gate: the fourth seam, consulted on INSTALL
        // rather than on delivery. A locked session must refuse the grab
        // outright, exactly as the running server does.
        ts.seat.?.setGrabGate(grabAllowed, state);
        // The production subscriptions main() makes for the new modules.
        ts.session_lock.?.events.locked.add(&state.session_locked_listener);
        ts.session_lock.?.events.unlocked.add(&state.session_unlocked_listener);
        ts.session_lock.?.events.new_lock_surface.add(&state.new_lock_surface_listener);
        ts.session_lock.?.events.lock_surface_gone.add(&state.lock_surface_gone_listener);
        ts.cursor_shape.?.events.shape_changed.add(&state.cursor_shape_changed_listener);
        // zwlr_screencopy_v1 (main() advertises it too): the copy source is
        // this state, which is why the harness builds it.
        ts.screencopy = try wayland.screencopy.Screencopy.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.shm_state.?,
            getFramebuffer,
            state,
            outputFromResource,
            state,
            requestFrame,
            state,
        );
        errdefer if (ts.screencopy) |sc| sc.deinit();

        // In-memory client: one socketpair end for the server, the other
        // for the client library.
        var fds: [2]std.posix.socket_t = undefined;
        const rc = std.posix.system.socketpair(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
            &fds,
        );
        if (std.posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        const registry = try ts.c_display.?.getRegistry();
        var capture: PolicyRegistryCapture = .{};
        registry.setListener(*PolicyRegistryCapture, PolicyRegistryCapture.listener, &capture);
        try ts.pump();
        if (capture.compositor_name == null or capture.wm_base_name == null or
            capture.shm_name == null or capture.seat_name == null or
            capture.ddm_name == null or capture.output_name == null or
            capture.layer_shell_name == null)
        {
            return error.GlobalMissing;
        }
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wm_base = try registry.bind(capture.wm_base_name.?, client.xdg.WmBase, 7);
        ts.wl_shm = try registry.bind(capture.shm_name.?, client.wl.Shm, 1);
        ts.wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
        ts.ddm = try registry.bind(capture.ddm_name.?, client.wl.DataDeviceManager, 3);
        ts.wl_output_client = try registry.bind(capture.output_name.?, client.wl.Output, 1);
        ts.layer_shell_client = try registry.bind(capture.layer_shell_name.?, client.zwlr.LayerShellV1, 4);
        // libwayland-client aborts on an event with no listener.
        ts.wl_output_client.?.setListener(*u8, ignoreOutputEvents, &ts.output_listener_data);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *PolicyServer) void {
        // Clients first: their resource destroy handlers must run while
        // the modules they call into are alive.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.idle_client) |c| c.destroy();
        ts.idle_client = null;
        if (ts.idle_peer) |fd| {
            ts.idle_peer = null;
            _ = std.os.linux.close(fd);
        }
        // zwlr_screencopy first: it was built with the ServerState's
        // framebuffer/output callbacks, so it must go while that state is
        // still whole (main() defers it after the state teardown because
        // the clients are already gone by then).
        if (ts.screencopy) |sc| sc.deinit();
        ts.screencopy = null;
        // Unlink the state BEFORE the modules deinit (their teardown emits
        // signals the listeners would otherwise receive with the state
        // already freed).
        if (ts.state) |state| {
            unlinkSessionLockListeners(state);
            unlinkOne(*wayland.shell.XdgToplevel, &state.new_toplevel_listener);
            unlinkOne(*wayland.shell.XdgPopup, &state.new_popup_listener);
            unlinkOne(*wayland.layer_shell.LayerSurface, &state.new_layer_surface_listener);
            unlinkOne(*wayland.shell.XdgPopup, &state.new_layer_popup_listener);
            unlinkOne(*wayland.seat.Seat, &state.seat_focus_listener);
            unlinkOne(*wayland.seat.Seat, &state.seat_button_listener);
            unlinkOne(*wayland.seat.Seat, &state.seat_pointer_move_listener);
            unlinkOne(*wayland.xdg_activation.ActivateRequest, &state.request_activate_listener);
            // The focus gate names `state`, which is freed a few lines
            // below — same reason main() clears it before freeStateResources.
            if (ts.foreign_toplevel) |ft| ft.setFocusGate(state, null);
            state.toplevels.deinit(ts.allocator);
            state.layer_surfaces.deinit(ts.allocator);
            state.layer_popups.deinit(ts.allocator);
            state.synth_clicked.deinit(ts.allocator);
            state.synth_pointed.deinit(ts.allocator);
            // The cursor's GL import (a .gles2 harness that composited a
            // GPU frame), freed before the renderer whose EGL context its
            // GL objects belong to.
            if (state.cursor_gl) |t| {
                t.destroy();
                state.cursor_gl = null;
            }
            // The output views, and with them every render target, the
            // capture storage and the scene output each one owns — the
            // same order main()'s freeStateResources uses.
            cleanupSurfaceEntries(state);
            freeOutputViews(state);
            state.surface_place.deinit(ts.allocator);
            state.canvas_index.deinit(ts.allocator);
            clearScenePlacementPolicy(state);
            ts.allocator.destroy(state);
        }
        ts.view = null;
        if (ts.scene) |sc| sc.deinit();
        // The extra outputs a two-output test added, after their views
        // (freeOutputViews above already ran). Each Output's destroy
        // signal frees the WlOutput global its view created for it.
        for (ts.extra_outputs.items) |o| o.destroy();
        ts.extra_outputs.deinit(ts.allocator);
        if (ts.output) |o| o.destroy();
        if (ts.backend) |b| b.destroy();
        if (ts.presentation) |p| p.deinit();
        // The selected renderer first when it is the GLES2 one, then
        // the pixman renderer (the same object in the default
        // configuration, so it must not be freed twice).
        if (ts.renderer != ts.pixman_renderer) {
            if (ts.renderer) |r| r.destroy();
        }
        if (ts.pixman_renderer) |r| r.destroy();
        // The new modules, in reverse dependency order: cursor_shape dies
        // before the tablet registry it resolves serials from, data_control
        // before the selection managers it mirrors, foreign_toplevel before
        // the shell, and all of them before the seat they attach to.
        if (ts.linux_dmabuf) |ld| ld.deinit();
        ts.linux_dmabuf = null;
        if (ts.foreign_toplevel) |ft| ft.deinit();
        ts.foreign_toplevel = null;
        if (ts.data_control) |dc| dc.deinit();
        ts.data_control = null;
        if (ts.session_lock) |sl| sl.deinit();
        ts.session_lock = null;
        if (ts.tearing_control) |tc| tc.deinit();
        ts.tearing_control = null;
        if (ts.cursor_shape) |cs| cs.deinit();
        ts.cursor_shape = null;
        if (ts.tablet) |tb| tb.deinit();
        ts.tablet = null;
        if (ts.pointer_constraints) |pc| pc.deinit();
        ts.pointer_constraints = null;
        if (ts.relative_pointer) |rp| rp.deinit();
        ts.relative_pointer = null;
        if (ts.pointer_gestures) |pg| pg.deinit();
        ts.pointer_gestures = null;
        if (ts.xdg_output) |xo| xo.deinit();
        ts.xdg_output = null;
        if (ts.primary_selection) |ps| ps.deinit();
        if (ts.data_device) |dd| dd.deinit();
        if (ts.subcompositor) |sc| sc.deinit();
        if (ts.viewporter) |v| v.deinit();
        if (ts.fractional_scale) |fs| fs.deinit();
        if (ts.xdg_decoration) |xd| xd.deinit();
        if (ts.xdg_activation) |xa| xa.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.layer_shell) |ls| ls.deinit();
        if (ts.shell) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.shm_state) |s| s.deinit();
        if (ts.display) |d| d.deinit();
        ts.allocator.destroy(ts);
    }

    /// Client flush -> server dispatch -> server flush -> client dispatch.
    ///
    /// The first three steps are the shared roundtrip
    /// (wayland.utils.test_pump): this harness emits nothing between the
    /// dispatch and the flush, so the combined helper is exactly the
    /// sequence. The client-side dispatch afterwards is this harness's
    /// own — a test's assertions live there, so the helper's split pair
    /// (dispatchOnce + flushServers) would only move code around.
    fn pump(ts: *PolicyServer) !void {
        try test_pump.roundtrip(ts.c_display.?, ts.display.?, 0);
        var fds = [_]std.posix.pollfd{.{
            .fd = ts.c_display.?.getFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) return error.ClientDispatchFailed;
        }
    }

    /// The harness's output view — the only one unless a test adds a
    /// second output.
    fn viewOf(ts: *PolicyServer) *OutputView {
        return ts.view orelse unreachable;
    }

    /// A SECOND output on the harness: a real `Output` plus a real
    /// `OutputView` through the production factory, laid out to the right
    /// of the first — exactly what a hot-plugged connector produces. The
    /// harness owns the extra Output and frees it in deinit.
    fn addSecondOutput(ts: *PolicyServer, w: i32, h: i32) !*OutputView {
        const out = try wayland.output.Output.create(
            ts.allocator,
            &ts.io,
            &ts.log_cfg,
            ts.backend.?,
            &test_output_impl,
            &ts.dummy,
            .{ .width = w, .height = h, .refresh_msec = 16 },
        );
        errdefer out.destroy();
        // The list owns it from here: a later failure must not destroy it
        // twice, and deinit still frees whatever is left in the list.
        try ts.extra_outputs.append(ts.allocator, out);
        const view = createOutputView(ts.state.?, out) orelse return error.ViewCreateFailed;
        view.in_render = true;
        return view;
    }

    /// Take a view off the harness the way a backend unplug does: the
    /// production destroy handler runs, so the layout, the surfaces and
    /// any pinned gesture are re-homed exactly as in the running server.
    fn removeOutput(ts: *PolicyServer, out: *wayland.output.Output) void {
        // Output.destroy frees the Output, so it must leave the harness's
        // ownership list first or deinit would destroy it again.
        if (ts.output == out) ts.output = null;
        for (ts.extra_outputs.items, 0..) |owned, i| {
            if (owned == out) {
                _ = ts.extra_outputs.orderedRemove(i);
                break;
            }
        }
        out.destroy();
    }

    /// Run one view's frame phases WITHOUT presenting: placement, damage
    /// and the composite, with no output commit. The pixels the test then
    /// inspects are the ones the frame really drew — through the same
    /// canvas pass main() uses, including the read-back under
    /// WAYLAND_RENDERER=gles2 — and the two cursor/present shortcuts are
    /// cleared so the canvas is always recomposited.
    fn renderView(ts: *PolicyServer, view: *OutputView) void {
        const state = ts.state.?;
        var perf: FramePerf = .{ .t0 = perfNs(state), .sync = 0, .cursor = 0, .render = 0, .present = 0 };
        const input = beginFrame(view, &perf) orelse return;
        accumulateFrameDamage(view, input);
        view.frame_kick = false;
        view.cursor_repaint = false;
        _ = compositeFrame(view, input, null);
    }

    /// The canvas the last renderView left in this view's persisted base:
    /// what the view is showing without the cursor.
    fn baseOf(ts: *PolicyServer, view: *OutputView) !*pixman.Framebuffer {
        _ = ts;
        return view.base_framebuffer orelse error.BaseFramebufferMissing;
    }

    /// Tear the ten new protocol modules down the way main() does (the
    /// globals removed, the modules freed in reverse dependency order)
    /// while the display and the client stay up. A test uses it to prove
    /// the globals are GONE from the registry afterwards; deinit() then
    /// finds every slot null and skips them.
    fn deinitNewGlobals(ts: *PolicyServer) void {
        if (ts.state) |state| {
            unlinkSessionLockListeners(state);
            state.linux_dmabuf = null;
            state.foreign_toplevel = null;
            state.data_control = null;
            state.session_lock = null;
            state.tearing_control = null;
            state.cursor_shape = null;
            state.tablet = null;
            state.pointer_constraints = null;
            state.relative_pointer = null;
            state.pointer_gestures = null;
        }
        if (ts.linux_dmabuf) |ld| ld.deinit();
        ts.linux_dmabuf = null;
        if (ts.foreign_toplevel) |ft| ft.deinit();
        ts.foreign_toplevel = null;
        if (ts.data_control) |dc| dc.deinit();
        ts.data_control = null;
        if (ts.session_lock) |sl| sl.deinit();
        ts.session_lock = null;
        if (ts.tearing_control) |tc| tc.deinit();
        ts.tearing_control = null;
        if (ts.cursor_shape) |cs| cs.deinit();
        ts.cursor_shape = null;
        if (ts.tablet) |tb| tb.deinit();
        ts.tablet = null;
        if (ts.pointer_constraints) |pc| pc.deinit();
        ts.pointer_constraints = null;
        if (ts.relative_pointer) |rp| rp.deinit();
        ts.relative_pointer = null;
        if (ts.pointer_gestures) |pg| pg.deinit();
        ts.pointer_gestures = null;
    }

    /// A real 64x64 shm buffer filled with opaque 0x40 gray (the pool is
    /// retained so the buffer stays valid for the whole test). The fill
    /// makes a composited pixel identify this surface: a frame that shows
    /// 0x40 gray at the canvas origin has drawn it.
    fn createBuffer(ts: *PolicyServer) !*client.wl.Buffer {
        if (ts.buffer) |b| return b;
        const width: i32 = 64;
        const height: i32 = 64;
        const size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        const fd = try filledMemfd("policy-test-buffer", size, 0x40);
        defer _ = std.os.linux.close(fd);
        ts.shm_pool = try ts.wl_shm.?.createPool(fd, @intCast(size));
        ts.buffer = try ts.shm_pool.?.createBuffer(0, width, height, width * 4, .argb8888);
        return ts.buffer.?;
    }

    /// A filled ARGB8888 shm buffer of the requested size: every pixel is
    /// the same OPAQUE gray `value` (alpha 0xFF, so the framebuffer keeps
    /// the value after compositing). The pool is retained (like
    /// createBuffer's) so the buffer stays valid for the whole test.
    fn createFilledBuffer(ts: *PolicyServer, width: i32, height: i32, value: u8) !*client.wl.Buffer {
        const size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        const fd = try filledMemfd("policy-test-filled", size, value);
        defer _ = std.os.linux.close(fd);
        ts.filled_pool = try ts.wl_shm.?.createPool(fd, @intCast(size));
        return ts.filled_pool.?.createBuffer(0, width, height, width * 4, .argb8888);
    }

    /// An ARGB8888 shm buffer of the requested size split down the middle
    /// between two OPAQUE grays (splitMemfd): the LEFT half is `left`, the
    /// RIGHT half is `right`. For a surface whose exact PLACE is the thing
    /// under test — a lock screen that must cover its output, a drag icon
    /// that must sit at the pointer — a uniform fill proves nothing,
    /// because a surface at the wrong place with the right colour still
    /// passes. The pool is retained like createFilledBuffer's.
    fn createSplitBuffer(
        ts: *PolicyServer,
        width: i32,
        height: i32,
        left: u8,
        right: u8,
    ) !*client.wl.Buffer {
        const size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        const fd = try splitMemfd("policy-test-split", width, height, left, right);
        defer _ = std.os.linux.close(fd);
        ts.filled_pool = try ts.wl_shm.?.createPool(fd, @intCast(size));
        return ts.filled_pool.?.createBuffer(0, width, height, width * 4, .argb8888);
    }

    /// A wl_buffer holding the four-quadrant fixture (fixture_w x
    /// fixture_h, quadrantFixtureColor per texel). The pool is retained
    /// in its own slot so the buffer stays valid for the whole test,
    /// exactly like createBuffer's.
    fn createFixtureBuffer(ts: *PolicyServer) !*client.wl.Buffer {
        const size: usize = @as(usize, @intCast(fixture_w)) * @as(usize, @intCast(fixture_h)) * 4;
        const fd = try quadrantMemfd("policy-test-fixture");
        defer _ = std.os.linux.close(fd);
        ts.fixture_pool = try ts.wl_shm.?.createPool(fd, @intCast(size));
        return ts.fixture_pool.?.createBuffer(0, fixture_w, fixture_h, fixture_w * 4, .argb8888);
    }

    /// A FRESH wl_registry roundtrip: libwayland sends the current global
    /// list to a newly created registry, which is how a test observes a
    /// global that appeared or disappeared since the last one. The
    /// registry object itself is never destroyed (wl_registry has no
    /// destroy request); the client display frees it at disconnect.
    fn readGlobals(ts: *PolicyServer, capture: *PolicyGlobalCapture) !*client.wl.Registry {
        const registry = try ts.c_display.?.getRegistry();
        registry.setListener(*PolicyGlobalCapture, PolicyGlobalCapture.listener, capture);
        try ts.pump();
        return registry;
    }

    /// A second server-side client with nothing bound: the session-lock
    /// input assertions need a client that is NOT the lock client.
    fn addIdleClient(ts: *PolicyServer) !*wire.Client {
        var fds: [2]std.posix.socket_t = undefined;
        const rc = std.posix.system.socketpair(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
            &fds,
        );
        if (std.posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.idle_client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ClientCreateFailed;
        };
        ts.idle_peer = fds[1];
        return ts.idle_client.?;
    }

    const Toplevel = struct {
        wl_surface: *client.wl.Surface,
        xdg_surface: *client.xdg.Surface,
        toplevel: *client.xdg.Toplevel,
        tl_events: ClientToplevelEvents,
        xs_events: ClientXdgSurfaceEvents,
    };

    /// A mapped toplevel: xdg_surface + xdg_toplevel, the initial commit
    /// the compositor answers with a configure, then a buffer so the
    /// surface has a scene node. The listener acks every configure
    /// (ClientXdgSurfaceEvents), so the returned toplevel has a `current`
    /// that matches the last configure it saw.
    fn createToplevel(ts: *PolicyServer) !*Toplevel {
        return ts.createToplevelWithAck(true);
    }

    /// The same, with the harness's auto-ack switched OFF: configures are
    /// recorded but not acked, so a test can observe the PRE-ack state and
    /// drive the ack itself (ackToplevelConfigure). Only the initial
    /// configure is acked here — attaching a buffer before any ack is
    /// `unconfigured_buffer` (xdg-shell.xml:1063-1065).
    fn createToplevelDeferredAck(ts: *PolicyServer) !*Toplevel {
        return ts.createToplevelWithAck(false);
    }

    fn createToplevelWithAck(ts: *PolicyServer, auto_ack: bool) !*Toplevel {
        return ts.createToplevelWithBufferAck(try ts.createBuffer(), auto_ack);
    }

    /// The same, with the buffer the surface first presents chosen by
    /// the caller instead of the harness's solid-gray one. A
    /// transform/scale/viewport test needs a buffer whose CONTENT
    /// identifies where it ended up on screen; a solid fill cannot.
    fn createToplevelWithBuffer(ts: *PolicyServer, buf: *client.wl.Buffer) !*Toplevel {
        return ts.createToplevelWithBufferAck(buf, true);
    }

    fn createToplevelWithBufferAck(ts: *PolicyServer, buf: *client.wl.Buffer, auto_ack: bool) !*Toplevel {
        // Heap-allocated: the client listeners take the address of the
        // event state, so it must outlive this call (a returned-by-value
        // copy would leave them pointing at the dead local).
        const out = try ts.allocator.create(Toplevel);
        errdefer ts.allocator.destroy(out);
        // SAFETY: the three proxy slots are filled by the create* calls
        // below before anything reads them, and a failure in one of those
        // runs the errdefer, which frees `out` without exposing it.
        out.* = .{
            .wl_surface = undefined,
            .xdg_surface = undefined,
            .toplevel = undefined,
            .tl_events = .{},
            .xs_events = .{ .auto_ack = auto_ack },
        };
        out.wl_surface = try ts.wl_compositor.?.createSurface();
        out.xdg_surface = try ts.wm_base.?.getXdgSurface(out.wl_surface);
        out.toplevel = try out.xdg_surface.getToplevel();
        out.toplevel.setListener(*ClientToplevelEvents, ClientToplevelEvents.listener, &out.tl_events);
        out.xdg_surface.setListener(*ClientXdgSurfaceEvents, ClientXdgSurfaceEvents.listener, &out.xs_events);
        try ts.pump();
        // Initial commit: the compositor's initial_commit handler replies
        // with the configure the client acks.
        out.wl_surface.commit();
        try ts.pump();
        if (!auto_ack) ts.ackToplevelConfigure(out);
        // Attach a buffer + ack: the surface maps and gets a scene node.
        out.wl_surface.attach(buf, 0, 0);
        out.wl_surface.commit();
        try ts.pump();
        syncSurfaces(ts.state.?);
        return out;
    }

    /// Ack the configure `t` last received — the deferred-ack path (the
    /// auto-ack listener would have sent this already).
    fn ackToplevelConfigure(_: *PolicyServer, t: *Toplevel) void {
        t.xdg_surface.ackConfigure(t.xs_events.serial);
        t.xs_events.acks += 1;
    }

    /// Destroy the role object and create a fresh one on the SAME
    /// xdg_surface / wl_surface, exactly as a client may
    /// (xdg-shell.xml:637-641: destroying the role leaves the xdg_surface
    /// usable for a new role). The wl_surface keeps its buffer, so the
    /// re-created role only needs its initial commit to reach the first
    /// configure.
    fn recreateRole(ts: *PolicyServer, t: *Toplevel) !void {
        t.toplevel.destroy();
        try ts.pump();
        t.toplevel = try t.xdg_surface.getToplevel();
        // The old proxy died with the role; its listener registration with
        // it. A fresh state object (in place, so the listener's data
        // pointer stays valid) records only what the NEW role is told.
        t.tl_events = .{};
        t.toplevel.setListener(*ClientToplevelEvents, ClientToplevelEvents.listener, &t.tl_events);
        try ts.pump();
        // The initial commit of the new role: the compositor answers with
        // the first configure, which the auto-ack listener acks.
        t.wl_surface.commit();
        try ts.pump();
        t.wl_surface.attach(try ts.createBuffer(), 0, 0);
        t.wl_surface.commit();
        try ts.pump();
        syncSurfaces(ts.state.?);
    }

    /// Two roundtrips. The harness acks from the configure listener, and
    /// the ack itself only leaves the client on the NEXT flush (pump's
    /// order: client flush -> server dispatch -> server flush -> client
    /// dispatch). Anything asserting on the compositor's `current` needs
    /// both halves.
    fn pumpAcked(ts: *PolicyServer) !void {
        try ts.pump();
        try ts.pump();
    }

    /// A committed top panel with an exclusive zone: the output's usable
    /// area shrinks by it, so a maximized box and the fullscreen box are
    /// two DIFFERENT sizes. Without it every maximized/fullscreen geometry
    /// assertion passes no matter which one the policy wrote.
    fn addExclusiveTopPanel(ts: *PolicyServer, zone: i32) !void {
        const wl_surface = try ts.wl_compositor.?.createSurface();
        const layer_surface = try ts.layer_shell_client.?.getLayerSurface(wl_surface, null, .top, "panel");
        layer_surface.setListener(*u8, ignoreLayerEvents, &ts.layer_listener_data);
        layer_surface.setSize(800, @intCast(zone));
        // zwlr_layer_surface_v1.anchor is a bitmask and the scanner binds
        // it as the raw u32; bit 0 is `top` (layer-shell.xml anchors).
        layer_surface.setAnchor(@bitCast(@as(u32, 1)));
        layer_surface.setExclusiveZone(zone);
        try ts.pump();
        // The layer module applies pending at commit.
        wl_surface.commit();
        try ts.pump();
    }

    /// Lock the session from this harness's own connection — the steps a
    /// lock client performs, up to and including the latch the `locked`
    /// signal fires on — and return the server-side lock surface. The
    /// event state is the CALLER's on purpose: a client listener keeps
    /// the address it was given, and the lock object outlives this call
    /// (its `unlocked` event arrives long after). The caller must keep
    /// `pick_surface` armed the way it wants the hit test to see it: a
    /// locked pick drops everything that is not a lock surface
    /// (pickSurface, ext_session_lock_manager_v1 wiring item 2).
    fn lockSession(
        ts: *PolicyServer,
        lock_events: *LockClientEvents,
        surface_events: *LockSurfaceClientEvents,
    ) !*Surface {
        var capture: PolicyGlobalCapture = .{};
        const registry = try ts.readGlobals(&capture);
        const entry = capture.find("ext_session_lock_manager_v1") orelse return error.GlobalMissing;
        const manager = try registry.bind(entry.name, client.ext.SessionLockManagerV1, entry.version);
        try ts.pump();
        const lock = try manager.lock();
        lock.setListener(*LockClientEvents, LockClientEvents.listener, lock_events);
        const wl_surface = try ts.wl_compositor.?.createSurface();
        const lock_surface = try lock.getLockSurface(wl_surface, ts.wl_output_client.?);
        lock_surface.setListener(*LockSurfaceClientEvents, LockSurfaceClientEvents.listener, surface_events);
        try ts.pump();
        // get_lock_surface configures immediately, sized to the output.
        lock_surface.ackConfigure(surface_events.serial);
        // The acked, correctly sized first buffer IS the locked frame.
        wl_surface.attach(try ts.createFilledBuffer(800, 600, 0x80), 0, 0);
        wl_surface.commit();
        try ts.pump();
        if (lock_events.locked != 1) return error.SessionNotLocked;
        return ts.serverSurface(wl_surface);
    }

    /// The server-side XdgToplevel created by `t`.
    fn serverToplevel(ts: *PolicyServer, t: *client.xdg.Toplevel) *wayland.shell.XdgToplevel {
        for (ts.shell.?.toplevels.items) |st| {
            if (st.resource.getId() == t.getId()) return st;
        }
        unreachable;
    }

    /// The server-side Surface the client's wl_surface maps to.
    fn serverSurface(ts: *PolicyServer, wl_surface: *client.wl.Surface) *Surface {
        for (ts.compositor.?.surfaces.items) |s| {
            if (s.resource.getId() == wl_surface.getId()) return s;
        }
        unreachable;
    }
};

test "left release does not cancel an in-flight DnD drag (P1-3)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const origin = try ts.createToplevel();
    defer ts.allocator.destroy(origin);
    const origin_surface = ts.serverSurface(origin.wl_surface);
    ts.pick_surface = origin_surface;
    ts.seat.?.pointerMotion(40, 40);
    ts.seat.?.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();

    const device = try ts.ddm.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.ddm.?.createDataSource();
    src.offer("text/plain");
    var src_events: ClientDataSourceEvents = .{};
    src.setListener(*ClientDataSourceEvents, ClientDataSourceEvents.listener, &src_events);
    try ts.pump();
    device.startDrag(src, origin.wl_surface, null, ts.seat.?.last_serial);
    try ts.pump();
    // The drag owns the seat pointer: its own grab, not the compositor's.
    try testing.expect(ts.data_device.?.drag != null);
    try testing.expect(ts.seat.?.pointer_grab != null);
    try testing.expect(ts.seat.?.pointer_grab != &wayland.seat.swallow_pointer_grab);

    // The release ENDS the drag — that is the drag's own end, not the
    // compositor's (a mouse drag drops on the origin button's release,
    // wlroots drag_handle_pointer_button, wlr_drag.c:113-125), so what
    // P1-3 pins is WHICH end ran. The release must reach the drag's grab
    // and run the drop/finish protocol: dnd_finished is what an
    // unconditional endPointerGrab on the release skipped by calling the
    // drag's cancel instead ("the target got leave with no drop").
    ts.seat.?.pointerButton(wayland.seat.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), src_events.dnd_finished);
    try testing.expect(ts.data_device.?.drag == null);
    try testing.expect(ts.seat.?.pointer_grab == null);
}

test "left release does not dismiss a popup grab (P1-3)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const parent = try ts.createToplevel();
    defer ts.allocator.destroy(parent);
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const popup_wl_surface = try ts.wl_compositor.?.createSurface();
    const popup_xdg_surface = try ts.wm_base.?.getXdgSurface(popup_wl_surface);
    var popup_events: ClientPopupEvents = .{};
    const client_popup = try popup_xdg_surface.getPopup(parent.xdg_surface, positioner);
    client_popup.setListener(*ClientPopupEvents, ClientPopupEvents.listener, &popup_events);
    positioner.destroy();
    try ts.pump();
    const p = ts.shell.?.popups.items[0];

    // Grab with a serial the client was just handed.
    ts.seat.?.setKeyboardFocus(p.xdg_surface.surface);
    client_popup.grab(ts.wl_seat.?, ts.seat.?.last_serial);
    try ts.pump();
    try testing.expect(p.grab_state != null);
    try testing.expect(ts.seat.?.pointer_grab != null);

    // The release must not cancel the popup grab: no popup_done, and the
    // popup keeps the pointer.
    ts.seat.?.pointerButton(wayland.seat.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), popup_events.done_count);
    try testing.expect(ts.seat.?.pointer_grab != null);
}

test "left release ends the interactive move and the camera pan (P1-3)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    // The interactive move: a compositor gesture holding the swallow
    // grab, installed exactly as onToplevelMove installs it.
    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);
    const gestures = &ts.state.?.gestures;
    gestures.moving_toplevel = st;
    grabPointerForGesture(ts.seat.?, gestures);
    try testing.expect(ts.seat.?.pointer_grab == &wayland.seat.swallow_pointer_grab);

    try testing.expect(endPointerGestures(ts.seat.?, gestures));
    try testing.expect(gestures.moving_toplevel == null);
    try testing.expect(gestures.own_grab == null);
    try testing.expect(ts.seat.?.pointer_grab == null);

    // The camera pan: the same grab, armed by the button press.
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();
    gestures.camera_drag = .{ .x = 10, .y = 10 };
    gestures.drag_active = true;
    gestures.fast_render = true;
    grabPointerForGesture(ts.seat.?, gestures);
    try testing.expect(ts.seat.?.pointer_grab == &wayland.seat.swallow_pointer_grab);

    try testing.expect(endPointerGestures(ts.seat.?, gestures));
    try testing.expect(gestures.camera_drag == null);
    try testing.expect(!gestures.drag_active);
    try testing.expect(!gestures.fast_render);
    try testing.expect(ts.seat.?.pointer_grab == null);

    // No gesture of ours is live: the release still clears the armed pan
    // anchor (a sub-threshold click never started one) and ends nothing.
    gestures.camera_drag = .{ .x = 20, .y = 20 };
    try testing.expect(!endPointerGestures(ts.seat.?, gestures));
    try testing.expect(gestures.camera_drag == null);
    try testing.expect(ts.seat.?.pointer_grab == null);
}

test "set_maximized / unset_maximized are answered with a configure (P1-8)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);
    t.toplevel.setMaximized();
    try ts.pump();
    // The answer carries the state AND the size the output's usable area
    // implies — not an echo of the request alone.
    try testing.expect(t.tl_events.carries(state_maximized));
    try testing.expectEqual(@as(i32, 800), t.tl_events.width);
    try testing.expectEqual(@as(i32, 600), t.tl_events.height);
    try testing.expect(st.scheduled.maximized);

    t.toplevel.unsetMaximized();
    try ts.pump();
    try testing.expect(!t.tl_events.carries(state_maximized));
    try testing.expect(!st.scheduled.maximized);
    // The size goes back to the client (no restore size exists).
    try testing.expectEqual(@as(i32, 0), t.tl_events.width);
    try testing.expectEqual(@as(i32, 0), t.tl_events.height);
}

test "an exclusive layer zone shrinks the maximized area (P1-8)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const layer_wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell_client.?.getLayerSurface(layer_wl_surface, null, .top, "panel");
    layer_surface.setListener(*u8, ignoreLayerEvents, &ts.layer_listener_data);
    layer_surface.setSize(800, 24);
    // zwlr_layer_surface_v1.anchor is a bitmask and the scanner binds it as
    // the raw u32; bit 0 is `top` (layer-shell.xml anchor values).
    layer_surface.setAnchor(@bitCast(@as(u32, 1)));
    layer_surface.setExclusiveZone(24);
    try ts.pump();
    // The layer module applies pending at commit.
    layer_wl_surface.commit();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.layer_shell.?.layer_surfaces.items.len);

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    t.toplevel.setMaximized();
    try ts.pump();
    // 800x600 minus the 24px exclusive strip at the top.
    try testing.expect(t.tl_events.carries(state_maximized));
    try testing.expectEqual(@as(i32, 800), t.tl_events.width);
    try testing.expectEqual(@as(i32, 576), t.tl_events.height);
}

test "set_fullscreen fills the named output; set_minimized is recorded (P1-8)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);

    t.toplevel.setFullscreen(ts.wl_output_client.?);
    try ts.pump();
    // The FULL output box (800x600), not the usable area: a fullscreen
    // window covers a panel.
    try testing.expect(t.tl_events.carries(state_fullscreen));
    try testing.expectEqual(@as(i32, 800), t.tl_events.width);
    try testing.expectEqual(@as(i32, 600), t.tl_events.height);
    try testing.expect(st.scheduled.fullscreen);

    t.toplevel.unsetFullscreen();
    try ts.pump();
    try testing.expect(!t.tl_events.carries(state_fullscreen));
    try testing.expect(!st.scheduled.fullscreen);

    // Minimize: recorded on the toplevel state and taken off screen. The
    // window is the harness's 64x64 gray square at the canvas origin, so
    // "off screen" is what the NEXT FRAME shows: the compositor disables
    // the surface's whole container (onToplevelMinimize — the container,
    // not the buffer node, so a popup or subsurface goes down with it),
    // and the canvas pass prunes a disabled subtree, leaving the
    // background fill where the window was.
    t.toplevel.setMinimized();
    try ts.pump();
    try testing.expect(st.pending.minimized);
    ts.renderView(ts.viewOf());
    try expectFillPixel(framebufferPixel(try ts.baseOf(ts.viewOf()), 10, 10));
    try expectFillPixel(framebufferPixel(try ts.baseOf(ts.viewOf()), 63, 63));
}

test "a keyboard-focus change publishes wl_toplevel.activated (P1-9)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const first = try ts.createToplevel();
    defer ts.allocator.destroy(first);
    const second = try ts.createToplevel();
    defer ts.allocator.destroy(second);

    // Focusing the first toplevel: its next configure carries activated.
    ts.seat.?.setKeyboardFocus(ts.serverSurface(first.wl_surface));
    try ts.pump();
    try testing.expect(first.tl_events.carries(state_activated));
    try testing.expect(!second.tl_events.carries(state_activated));

    // Moving the focus away clears it: an unfocused window must not keep
    // drawing an active titlebar.
    ts.seat.?.setKeyboardFocus(ts.serverSurface(second.wl_surface));
    try ts.pump();
    try testing.expect(!first.tl_events.carries(state_activated));
    try testing.expect(second.tl_events.carries(state_activated));
}

test "a surface the focus gate refuses never reports activated (P1-9)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);

    // A layer surface the gate refuses: keyboard_interactivity=none must
    // never take focus, so it can never be activated. The anchors matter
    // only to keep the layer surface VALID: set_size was never called, so
    // both desired dimensions are 0 and the commit-time rule ("You must
    // set your anchor to opposite edges in the dimensions you omit",
    // layer-shell.xml) demands all four anchors — layer-shell.xml:520-536
    // posts invalid_size otherwise. The point of the test is the focus
    // gate, not the layer-shell sizing rules.
    const layer_wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell_client.?.getLayerSurface(layer_wl_surface, null, .top, "none");
    layer_surface.setListener(*u8, ignoreLayerEvents, &ts.layer_listener_data);
    layer_surface.setAnchor(@bitCast(@as(u32, 1 | 2 | 4 | 8)));
    layer_surface.setKeyboardInteractivity(.none);
    try ts.pump();
    layer_wl_surface.commit();
    try ts.pump();
    const refused = ts.layer_shell.?.layer_surfaces.items[0].surface;
    try testing.expect(!layerKeyboardFocusAllowed(ts.state.?, refused));

    // A click cannot route focus to it...
    ts.pick_surface = refused;
    ts.seat.?.pointerMotion(5, 5);
    ts.seat.?.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();
    ts.seat.?.pointerButton(wayland.seat.btn_left, false);
    try ts.pump();
    try testing.expect(ts.seat.?.keyboard_focus != refused);
    try testing.expect(!st.scheduled.activated);

    // ...and even if a focus reaches it by another route, the activation
    // policy re-checks the gate: no configure carries activated.
    const before = t.tl_events.configures;
    ts.seat.?.setKeyboardFocus(refused);
    try ts.pump();
    try testing.expectEqual(before, t.tl_events.configures);
    try testing.expect(!st.scheduled.activated);
    try testing.expect(!t.tl_events.carries(state_activated));
}

/// The client's wl_pointer events. A pointer resource exists only where a
/// test creates one: the seat delivers to the client that OWNS the focused
/// surface's wl_pointer list, so without one a leaked button is invisible.
const ClientPointerEvents = struct {
    entered: bool = false,
    enter_surface_id: u32 = 0,
    left: usize = 0,
    motion: usize = 0,
    button: usize = 0,

    fn listener(_: *client.wl.Pointer, event: client.wl.Pointer.Event, data: *ClientPointerEvents) void {
        switch (event) {
            .enter => |e| {
                data.entered = true;
                if (e.surface) |s| data.enter_surface_id = s.getId();
            },
            .leave => data.left += 1,
            .motion => data.motion += 1,
            .button => data.button += 1,
            else => {},
        }
    }
};

/// The client's xdg_activation_v1 token: the done() event carries the
/// opaque token string activate() must echo back.
const ClientActivationTokenEvents = struct {
    done_count: usize = 0,
    /// The last done() token, NUL-terminated.
    token: [33]u8 = undefined,

    fn listener(_: *client.xdg.ActivationTokenV1, event: client.xdg.ActivationTokenV1.Event, data: *ClientActivationTokenEvents) void {
        switch (event) {
            .done => |d| {
                data.done_count += 1;
                const s = std.mem.span(d.token);
                const n = @min(s.len, data.token.len - 1);
                @memcpy(data.token[0..n], s[0..n]);
                data.token[n] = 0;
            },
        }
    }
};

test "a locked session refuses an xdg_activation that names a user surface" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);
    const user_surface = ts.serverSurface(t.wl_surface);

    // Lock from THIS connection, so the request below comes from the very
    // client that owns the lock: what is refused is the SURFACE, not who
    // asked. The lock surface covers the output, so it is what the pointer
    // is over from here on.
    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try ts.lockSession(&lock_events, &lock_surface_events);
    try testing.expect(ts.seat.?.keyboard_focus == lock_surface);

    // Activation is SELF-SERVICE: a token that never got a serial
    // validates trivially (xdg_activation.zig:545-558), so no input event
    // and no launcher stand between this request and every keystroke the
    // user types into their password field.
    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("xdg_activation_v1") orelse return error.GlobalMissing;
    const activation = try registry.bind(entry.name, client.xdg.ActivationV1, entry.version);
    try ts.pump();
    const token = try activation.getActivationToken();
    var token_events: ClientActivationTokenEvents = .{};
    token.setListener(*ClientActivationTokenEvents, ClientActivationTokenEvents.listener, &token_events);
    token.commit();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), token_events.done_count);

    activation.activate(@ptrCast(&token_events.token), t.wl_surface);
    try ts.pumpAcked();
    // The lock surface still holds the keyboard, and the user window is
    // not reported activated: the request went through the SAME composite
    // gate a click does, not the layer-only half of it.
    try testing.expect(ts.seat.?.keyboard_focus == lock_surface);
    try testing.expect(ts.seat.?.keyboard_focus != user_surface);
    try testing.expect(!st.current.activated);
    try testing.expect(!t.tl_events.carries(state_activated));
}

/// The client's zwlr_foreign_toplevel_manager_v1: the handles it is
/// announced, plus a listener for every event of every handle
/// (libwayland aborts on an event with no listener).
const ClientForeignToplevelEvents = struct {
    handles: usize = 0,
    last: ?*client.zwlr.ForeignToplevelHandleV1 = null,

    fn managerListener(
        _: *client.zwlr.ForeignToplevelManagerV1,
        event: client.zwlr.ForeignToplevelManagerV1.Event,
        self: *ClientForeignToplevelEvents,
    ) void {
        switch (event) {
            .toplevel => |e| {
                e.toplevel.setListener(*ClientForeignToplevelEvents, handleListener, self);
                self.handles += 1;
                self.last = e.toplevel;
            },
            .finished => {},
        }
    }

    fn handleListener(_: *client.zwlr.ForeignToplevelHandleV1, _: client.zwlr.ForeignToplevelHandleV1.Event, _: *ClientForeignToplevelEvents) void {}
};

test "a locked session refuses a foreign-toplevel activate for a user surface" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);

    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try ts.lockSession(&lock_events, &lock_surface_events);
    try testing.expect(ts.seat.?.keyboard_focus == lock_surface);

    // The THIRD route to the keyboard, and the one the module had no way
    // to gate by itself: every binding is announced every toplevel
    // (wlr-foreign-toplevel-management-unstable-v1.xml), so this client
    // holds a handle to the user window and can ask for its focus.
    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("zwlr_foreign_toplevel_manager_v1") orelse return error.GlobalMissing;
    const panel = try registry.bind(entry.name, client.zwlr.ForeignToplevelManagerV1, entry.version);
    var panel_events: ClientForeignToplevelEvents = .{};
    panel.setListener(*ClientForeignToplevelEvents, ClientForeignToplevelEvents.managerListener, &panel_events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), panel_events.handles);

    panel_events.last.?.activate(ts.wl_seat.?);
    try ts.pumpAcked();
    // The lock surface still holds the keyboard: the module consults the
    // gate main() installed, and that gate is the SAME composite one the
    // click path and the xdg_activation path consult, so the session-lock
    // boundary has no hole on this side.
    try testing.expect(ts.seat.?.keyboard_focus == lock_surface);
    try testing.expect(ts.seat.?.keyboard_focus != ts.serverSurface(t.wl_surface));
    try testing.expect(!st.current.activated);
}

test "the session-lock latch clears the pointer focus and keeps the keyboard on the lock" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const user_surface = ts.serverSurface(t.wl_surface);

    // A live wl_pointer on this connection, or a leaked button would be
    // invisible: the seat delivers to the focused CLIENT's pointers.
    const pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: ClientPointerEvents = .{};
    pointer.setListener(*ClientPointerEvents, ClientPointerEvents.listener, &ptr_events);
    try ts.pump();

    // Hover the user toplevel: enter, and the seat's cached pointer focus.
    ts.pick_surface = user_surface;
    ts.seat.?.pointerMotion(10, 10);
    try ts.pump();
    try testing.expect(ptr_events.entered);
    try testing.expectEqual(t.wl_surface.getId(), ptr_events.enter_surface_id);
    try testing.expect(ts.seat.?.pointer_focus == user_surface);

    // Lock. The grabs end and the keyboard focus moves to the lock
    // surface, and the POINTER must leave the user client too:
    // pointer_focus is refreshed only by Seat.pointerMotion, which returns
    // early under a grab, so the cache still named the user surface and
    // pointerButton (seat.zig:1015) routed the next click there — a press
    // AND a release delivered to a client that must not see input at all.
    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try ts.lockSession(&lock_events, &lock_surface_events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ptr_events.left);
    try testing.expect(ts.seat.?.pointer_focus == null);
    try testing.expect(ts.seat.?.keyboard_focus == lock_surface);

    // A click over the (now invisible) user window while locked: the
    // lock-aware pick drops the surface, so there is no focus to route the
    // button by and nothing is delivered.
    ts.seat.?.pointerButton(wayland.seat.btn_left, true);
    ts.seat.?.pointerButton(wayland.seat.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ptr_events.button);
    try testing.expect(ts.seat.?.pointer_focus == null);
    // And the keyboard never left the lock surface: a null pick on the
    // click-to-focus path must not deafen the lock screen
    // (session_lock.zig:104-108 re-asserts the lock focus on every focus
    // change).
    try testing.expect(ts.seat.?.keyboard_focus == lock_surface);
}

test "set_maximized does not resize a fullscreen toplevel (P1-8)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    // A top panel with an exclusive zone, so the usable area (800x576) and
    // the fullscreen box (800x600) are different sizes: without it the
    // geometry assertion below cannot tell which one the policy wrote.
    try ts.addExclusiveTopPanel(24);

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);

    t.toplevel.setFullscreen(ts.wl_output_client.?);
    try ts.pumpAcked();
    try testing.expect(st.current.fullscreen);
    try testing.expectEqual(@as(i32, 800), st.current.width);
    try testing.expectEqual(@as(i32, 600), st.current.height);

    // xdg-shell.xml:1049-1051: set_maximized "has no direct effect" on a
    // fullscreen surface; xdg-shell.xml:850-854 requires a fullscreened
    // surface to be able to cover the fullscreened area. The STATE is
    // remembered (so a later un-fullscreen knows), the GEOMETRY is left
    // alone: a 800x576 box would pull the window out from under the panel
    // a fullscreen window is supposed to cover.
    t.toplevel.setMaximized();
    try ts.pumpAcked();
    try testing.expect(t.tl_events.carries(state_maximized));
    try testing.expect(t.tl_events.carries(state_fullscreen));
    try testing.expectEqual(@as(i32, 800), t.tl_events.width);
    try testing.expectEqual(@as(i32, 600), t.tl_events.height);
    try testing.expect(st.scheduled.maximized and st.scheduled.fullscreen);
    try testing.expect(st.current.maximized and st.current.fullscreen);
    try testing.expectEqual(@as(i32, 600), st.current.height);
}

test "leaving fullscreen re-applies the maximized area (P1-8)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    try ts.addExclusiveTopPanel(24);

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);

    t.toplevel.setMaximized();
    try ts.pumpAcked();
    try testing.expect(st.current.maximized);
    try testing.expectEqual(@as(i32, 576), st.current.height);

    t.toplevel.setFullscreen(ts.wl_output_client.?);
    try ts.pumpAcked();
    try testing.expect(st.current.maximized and st.current.fullscreen);
    try testing.expectEqual(@as(i32, 600), st.current.height);

    // Leaving fullscreen: the window is STILL maximized, so the box that
    // maximizes means comes back. Handing the client 0x0 instead tells it
    // to pick its own size for a state it was just told it has, and
    // discards the box onToplevelMaximize agreed to.
    t.toplevel.unsetFullscreen();
    try ts.pumpAcked();
    try testing.expect(!t.tl_events.carries(state_fullscreen));
    try testing.expect(t.tl_events.carries(state_maximized));
    try testing.expectEqual(@as(i32, 800), t.tl_events.width);
    try testing.expectEqual(@as(i32, 576), t.tl_events.height);
    try testing.expect(st.current.maximized);
    try testing.expectEqual(@as(i32, 576), st.current.height);
}

test "a re-created role on a focused surface is activated in its first configure (P1-9)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    ts.seat.?.setKeyboardFocus(ts.serverSurface(t.wl_surface));
    try ts.pumpAcked();
    try testing.expect(t.tl_events.carries(state_activated));
    try testing.expect(ts.serverToplevel(t.toplevel).current.activated);

    // The client throws the role away and asks for a new one on the SAME
    // wl_surface (xdg-shell.xml:637-641). The seat's focus never MOVES —
    // it is the same surface — so the keyboard_focus signal never fires
    // and the only publisher of wl_toplevel.activated never runs. The
    // fresh role therefore configured activated=false forever, and its
    // client-side decoration painted an inactive titlebar on the one
    // window that had the keyboard.
    const xs_before = t.xs_events.configures;
    try ts.recreateRole(t);
    try ts.pumpAcked();
    try testing.expect(t.tl_events.carries(state_activated));
    try testing.expect(ts.serverToplevel(t.toplevel).current.activated);
    // ONE configure, not two: the activation state is seeded into the
    // initial configure rather than published as a separate one. The
    // xdg_surface listener is not reset (the xdg_surface is the same
    // object), so its count is compared against the baseline.
    try testing.expectEqual(@as(usize, 1), t.tl_events.configures);
    try testing.expectEqual(xs_before + 1, t.xs_events.configures);
}

test "the toplevel's current state moves only on ack_configure (P1-8)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    // The deferred-ack harness: this test is about the state the client has
    // NOT committed to yet.
    const t = try ts.createToplevelDeferredAck();
    defer ts.allocator.destroy(t);
    const st = ts.serverToplevel(t.toplevel);
    try ts.pumpAcked();
    try testing.expect(!st.current.maximized);

    const before = t.tl_events.configures;
    t.toplevel.setMaximized();
    try ts.pump();
    // The wire says yes...
    try testing.expectEqual(before + 1, t.tl_events.configures);
    try testing.expect(t.tl_events.carries(state_maximized));
    try testing.expectEqual(@as(i32, 800), t.tl_events.width);
    // ...and the compositor's own current state still says no: it is the
    // state the client COMMITTED against, and only ack_configure moves it
    // (xdg.zig:415-434).
    try testing.expect(!st.current.maximized);
    try ts.pump();
    try testing.expect(!st.current.maximized);

    ts.ackToplevelConfigure(t);
    try ts.pump();
    try testing.expect(st.current.maximized);
    try testing.expectEqual(@as(i32, 800), st.current.width);
    try testing.expectEqual(@as(i32, 600), st.current.height);
    // The auto-ack listener sent NONE of them: the deferred mode really
    // was in force, so the only acks are the initial one the harness had
    // to send (a buffer may not be attached before an ack,
    // xdg-shell.xml:1063-1065) and the one this test just made.
    try testing.expectEqual(@as(usize, 2), t.xs_events.acks);
}

test "syncPopupNodes publishes the popup's absolute scene origin (P1-5b)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const parent = try ts.createToplevel();
    defer ts.allocator.destroy(parent);
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const popup_wl_surface = try ts.wl_compositor.?.createSurface();
    const popup_xdg_surface = try ts.wm_base.?.getXdgSurface(popup_wl_surface);
    var popup_events: ClientPopupEvents = .{};
    var popup_xs: ClientXdgSurfaceEvents = .{};
    popup_xdg_surface.setListener(*ClientXdgSurfaceEvents, ClientXdgSurfaceEvents.listener, &popup_xs);
    const client_popup = try popup_xdg_surface.getPopup(parent.xdg_surface, positioner);
    client_popup.setListener(*ClientPopupEvents, ClientPopupEvents.listener, &popup_events);
    positioner.destroy();
    try ts.pump();
    const p = ts.shell.?.popups.items[0];
    popup_wl_surface.commit(); // initial commit -> the module's configure
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), popup_xs.configures);
    popup_wl_surface.attach(try ts.createBuffer(), 0, 0);
    popup_wl_surface.commit();
    try ts.pump();
    syncSurfaces(ts.state.?);

    // Move the PARENT away from the origin, so the popup's absolute
    // position is not simply its parent-relative offset.
    const parent_tree = wayland.surface_node.surfaceNodeFor(
        ts.scene.?,
        ts.serverSurface(parent.wl_surface),
    ).?.tree.?;
    // f64 scene placement: the tree is positioned through setPosition, the
    // same call the production sync makes, so the test moves the parent
    // the way the compositor would.
    parent_tree.setPosition(300, 150);

    syncPopupNodes(ts.state.?);
    const popup_tree = wayland.surface_node.surfaceNodeFor(
        ts.scene.?,
        ts.serverSurface(popup_wl_surface),
    ).?.tree.?;
    const abs = popup_tree.absolutePosition();
    // The published origin is the popup's ABSOLUTE scene position: the
    // parent chain plus the parent-relative geometry.
    try testing.expectEqual(parent_tree.x + @as(f64, @floatFromInt(p.geometry.x)), p.origin.x);
    try testing.expectEqual(parent_tree.y + @as(f64, @floatFromInt(p.geometry.y)), p.origin.y);
    try testing.expectEqual(abs.x, p.origin.x);
    try testing.expectEqual(abs.y, p.origin.y);
}

test "syncDragIconNodes puts the drag icon at the pointer and drops it (P2-12)" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const origin = try ts.createToplevel();
    defer ts.allocator.destroy(origin);
    const origin_surface = ts.serverSurface(origin.wl_surface);
    ts.pick_surface = origin_surface;
    ts.seat.?.pointerMotion(40, 40);
    ts.seat.?.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();

    const device = try ts.ddm.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.ddm.?.createDataSource();
    src.offer("text/plain");
    const icon_wl_surface = try ts.wl_compositor.?.createSurface();
    try ts.pump();
    // The icon carries a buffer, so it has a scene node to place.
    icon_wl_surface.attach(try ts.createBuffer(), 0, 0);
    icon_wl_surface.commit();
    try ts.pump();
    device.startDrag(src, origin.wl_surface, icon_wl_surface, ts.seat.?.last_serial);
    try ts.pump();
    const icon_surface = ts.data_device.?.currentDragIcon().?;
    try testing.expect(icon_surface != origin_surface);
    syncSurfaces(ts.state.?);

    // While the drag lives the icon sits at the pointer.
    ts.seat.?.pointerMotion(400, 300);
    syncDragIconNodes(ts.state.?);
    const icon_tree = wayland.surface_node.surfaceNodeFor(ts.scene.?, icon_surface).?.tree.?;
    // The icon sits at the GLOBAL pointer: scene space IS the desktop,
    // in f64. A view-local or narrowed position would land off by the
    // view's origin or lose a fraction.
    try testing.expectEqual(@as(f64, 400), icon_tree.x);
    try testing.expectEqual(@as(f64, 300), icon_tree.y);
    const abs = icon_tree.absolutePosition();
    try testing.expectEqual(@as(f64, 400), abs.x);
    try testing.expectEqual(@as(f64, 300), abs.y);

    // The drag ends: the icon is no longer at the pointer, and the canvas
    // pass no longer composites it as content.
    ts.seat.?.pointerButton(wayland.seat.btn_left, false);
    try ts.pump();
    try testing.expect(ts.data_device.?.currentDragIcon() == null);
    ts.seat.?.pointerMotion(500, 350);
    syncDragIconNodes(ts.state.?);
    try testing.expectEqual(@as(f64, 400), icon_tree.x);
    try testing.expectEqual(@as(f64, 300), icon_tree.y);
    try testing.expect(isDragIconSurface(icon_surface));
}

/// The protocol globals this wave adds, each with the version its module
/// registers (build.zig's scanner.generate bound, or the module's own
/// version constant). A client must be able to bind every one of them.
const new_protocol_globals = [_]struct { interface: []const u8, version: u32 }{
    .{ .interface = "zwp_pointer_gestures_v1", .version = wayland.server.zwp.PointerGesturesV1.generated_version },
    .{ .interface = "zwp_relative_pointer_manager_v1", .version = wayland.server.zwp.RelativePointerManagerV1.generated_version },
    .{ .interface = "zwp_pointer_constraints_v1", .version = wayland.server.zwp.PointerConstraintsV1.generated_version },
    .{ .interface = "zwp_tablet_manager_v2", .version = wayland.tablet.tablet_v2_version },
    .{ .interface = "wp_cursor_shape_manager_v1", .version = wayland.cursor_shape.cursor_shape_manager_version },
    .{ .interface = "wp_tearing_control_manager_v1", .version = wayland.server.wp.TearingControlManagerV1.generated_version },
    .{ .interface = "ext_session_lock_manager_v1", .version = wayland.server.ext.SessionLockManagerV1.generated_version },
    .{ .interface = "zwlr_data_control_manager_v1", .version = wayland.server.zwlr.DataControlManagerV1.generated_version },
    .{ .interface = "zwlr_foreign_toplevel_manager_v1", .version = wayland.server.zwlr.ForeignToplevelManagerV1.generated_version },
};

/// The compositor framebuffer byte at (x, y). Premultiplied ARGB8888 in
/// memory as B,G,R,A (compositeBase's fill layout).
fn framebufferPixel(fb: *pixman.Framebuffer, x: i32, y: i32) [4]u8 {
    const stride: usize = @intCast(fb.stride);
    const off: usize = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x)) * 4;
    return .{ fb.data[off], fb.data[off + 1], fb.data[off + 2], fb.data[off + 3] };
}

/// A memfd of `size` bytes in which every pixel is the OPAQUE gray
/// `value` (alpha 0xFF). Alpha 1 matters: the framebuffer is
/// premultiplied ARGB8888, so a translucent fill would darken whatever it
/// is composited over and the pixel would no longer identify its surface.
fn filledMemfd(name: []const u8, size: usize, value: u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(name, std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    const rc = std.os.linux.ftruncate(fd, @intCast(size));
    if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
    const pixels = try std.posix.mmap(
        null,
        size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(pixels);
    var off: usize = 0;
    while (off < size) : (off += 4) {
        pixels[off + 0] = value;
        pixels[off + 1] = value;
        pixels[off + 2] = value;
        pixels[off + 3] = 0xFF;
    }
    return fd;
}

/// The premultiplied ARGB8888 memory bytes of an opaque gray fill
/// (`value` in every colour channel, alpha 0xFF) — the layout
/// framebufferPixel reads and the canvas pass produces.
fn grayBytes(value: u8) [4]u8 {
    return .{ value, value, value, 0xFF };
}

/// A memfd of `width` x `height` opaque pixels split down the middle: the
/// left half is the gray `left`, the right half the gray `right`.
///
/// Asymmetric on purpose. A surface that has to COVER an output, a drag
/// icon that has to sit AT a point or a canvas that has to land at a
/// camera-mapped pixel is invisible to a uniform fill wherever it really
/// is; a split shows a shift or a wrong size as the boundary moving.
fn splitMemfd(name: []const u8, width: i32, height: i32, left: u8, right: u8) !std.posix.fd_t {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const size: usize = w * h * 4;
    const fd = try std.posix.memfd_create(name, std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    const rc = std.os.linux.ftruncate(fd, @intCast(size));
    if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
    const pixels = try std.posix.mmap(
        null,
        size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(pixels);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const value: u8 = if (x < w / 2) left else right;
            const off = (y * w + x) * 4;
            pixels[off + 0] = value;
            pixels[off + 1] = value;
            pixels[off + 2] = value;
            pixels[off + 3] = 0xFF;
        }
    }
    return fd;
}

test "the new protocol globals are advertised at their implemented version and gone with their modules" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    var live: PolicyGlobalCapture = .{};
    _ = try ts.readGlobals(&live);
    // Exactly the globals a headless server advertises: the 16 main()
    // registers (wl_shm, wl_compositor, xdg_wm_base, zwlr_layer_shell_v1,
    // wl_seat, xdg_activation_v1, zxdg_decoration_manager_v1,
    // wp_fractional_scale_manager_v1, zxdg_output_manager_v1, wp_viewporter,
    // wl_subcompositor, wl_data_device_manager,
    // zwp_primary_selection_device_manager_v1, wp_presentation, wl_output,
    // zwlr_screencopy_manager_v1) plus the nine unconditional new ones.
    // zwp_linux_dmabuf_v1 is the tenth and is conditional (see below).
    try testing.expectEqual(@as(usize, 25), live.len);
    for (new_protocol_globals) |want| {
        const got = live.find(want.interface) orelse {
            std.debug.print("missing global {s}\n", .{want.interface});
            return error.GlobalMissing;
        };
        try testing.expectEqual(want.version, got.version);
    }
    // zwp_linux_dmabuf_v1: the module registers its global only for a GBM
    // device, and the test backend has none — the same null device main()
    // passes on every non-DRM backend. With WAYLAND_BACKEND=drm this is
    // the 26th global.
    try testing.expect(live.find("zwp_linux_dmabuf_v1") == null);
    try testing.expect(ts.linux_dmabuf != null); // the module exists and is inert

    // Teardown removes the globals: a registry created AFTER the modules
    // are gone is only told about the ones that still exist.
    ts.deinitNewGlobals();
    var after: PolicyGlobalCapture = .{};
    _ = try ts.readGlobals(&after);
    try testing.expectEqual(live.len - new_protocol_globals.len, after.len);
    for (new_protocol_globals) |want| {
        try testing.expect(after.find(want.interface) == null);
    }
    // The rest of the server is untouched: the module teardown removed
    // exactly its own global.
    try testing.expect(after.find("wl_compositor") != null);
    try testing.expect(after.find("wl_seat") != null);
    try testing.expect(after.find("zwlr_screencopy_manager_v1") != null);
}

test "the present path consults wp_tearing_control_v1 per surface per frame" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    // The present path is per OUTPUT now: the presented list belongs to
    // this view's SceneOutput and the tearing consult names the view.
    const view = ts.viewOf();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const surface = ts.serverSurface(t.wl_surface);

    // Nothing opted in: no presented surface asks for async presentation.
    wayland.surface_node.collectPresented(ts.scene.?, view.scene_output);
    try testing.expectEqual(@as(u32, 0), consultTearingHints(ts.state.?, view).async_surfaces);

    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("wp_tearing_control_manager_v1") orelse return error.GlobalMissing;
    const manager = try registry.bind(entry.name, client.wp.TearingControlManagerV1, entry.version);
    try ts.pump();
    const control = try manager.getTearingControl(t.wl_surface);
    control.setPresentationHint(.async);
    // Double-buffered: until the wl_surface commits, the hint is still the
    // client's pending value and the present path must not see it
    // (TearingControl.hintFor reads the COMMITTED hint,
    // shell/tearing_control.zig:180-187).
    try testing.expectEqual(@as(u32, 0), consultTearingHints(ts.state.?, view).async_surfaces);
    t.wl_surface.commit();
    try ts.pump();

    // Committed: the frame's present path reads it for that surface...
    wayland.surface_node.collectPresented(ts.scene.?, view.scene_output);
    const async_frame = consultTearingHints(ts.state.?, view);
    try testing.expectEqual(@as(u32, 1), async_frame.async_surfaces);
    // ...and the OUTPUT gate refuses to honour it: no backend in this
    // server flips asynchronously (outputTears), so a `.async` permission
    // never becomes a torn frame.
    try testing.expect(!async_frame.honoured);

    // A surface with no tearing object never asks: the hint is per surface,
    // not per output.
    const other = try ts.createToplevel();
    defer ts.allocator.destroy(other);
    wayland.surface_node.collectPresented(ts.scene.?, view.scene_output);
    try testing.expectEqual(@as(u32, 1), consultTearingHints(ts.state.?, view).async_surfaces);

    // The client takes the permission back; the next frame reads vsync.
    control.setPresentationHint(.vsync);
    t.wl_surface.commit();
    try ts.pump();
    wayland.surface_node.collectPresented(ts.scene.?, view.scene_output);
    try testing.expectEqual(@as(u32, 0), consultTearingHints(ts.state.?, view).async_surfaces);
    try testing.expectEqual(wayland.tearing_control.Hint.vsync, ts.tearing_control.?.hintFor(surface));
}

/// ext_session_lock_v1 client events (the test only counts them).
const LockClientEvents = struct {
    locked: usize = 0,
    finished: usize = 0,

    fn listener(_: *client.ext.SessionLockV1, event: client.ext.SessionLockV1.Event, self: *LockClientEvents) void {
        switch (event) {
            .locked => self.locked += 1,
            .finished => self.finished += 1,
        }
    }
};

/// ext_session_lock_surface_v1.configure: the first configure carries the
/// exact size the client must commit.
const LockSurfaceClientEvents = struct {
    configures: usize = 0,
    serial: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    fn listener(
        _: *client.ext.SessionLockSurfaceV1,
        event: client.ext.SessionLockSurfaceV1.Event,
        self: *LockSurfaceClientEvents,
    ) void {
        switch (event) {
            .configure => |c| {
                self.configures += 1;
                self.serial = c.serial;
                self.width = c.width;
                self.height = c.height;
            },
        }
    }
};

test "a locked session denies input to every client but the lock one and blanks the output" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const state = ts.state.?;
    const view = ts.viewOf();
    const sl = ts.session_lock.?;
    const other_client = try ts.addIdleClient();

    // A mapped user toplevel: opaque 0x40 gray at the canvas origin.
    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const user_surface = ts.serverSurface(t.wl_surface);

    // Unlocked: normal content, normal input.
    try testing.expect(!sl.isLocked());
    try testing.expect(sl.acceptsInput(ts.client.?));
    try testing.expect(sl.acceptsInput(other_client));
    try testing.expectEqual(LockedFrame{ .locked = false, .blank = false }, lockedFrameFor(state, view.output));
    try testing.expect(keyboardFocusAllowed(state, user_surface));
    try testing.expect(pickSurface(state, 10, 10) != null);
    ts.renderView(view);
    try testing.expectEqual([4]u8{ 0x40, 0x40, 0x40, 0xFF }, framebufferPixel(try ts.baseOf(view), 10, 10));

    // The lock client takes the session: a lock object plus a lock surface
    // covering the output.
    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("ext_session_lock_manager_v1") orelse return error.GlobalMissing;
    const manager = try registry.bind(entry.name, client.ext.SessionLockManagerV1, entry.version);
    try ts.pump();
    var lock_events: LockClientEvents = .{};
    const lock = try manager.lock();
    lock.setListener(*LockClientEvents, LockClientEvents.listener, &lock_events);
    const lock_wl_surface = try ts.wl_compositor.?.createSurface();
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try lock.getLockSurface(lock_wl_surface, ts.wl_output_client.?);
    lock_surface.setListener(*LockSurfaceClientEvents, LockSurfaceClientEvents.listener, &lock_surface_events);
    try ts.pump();
    // get_lock_surface configures immediately, sized to the output.
    try testing.expectEqual(@as(usize, 1), lock_surface_events.configures);
    try testing.expectEqual(@as(u32, 800), lock_surface_events.width);
    try testing.expectEqual(@as(u32, 600), lock_surface_events.height);
    try testing.expect(!sl.isLocked());

    // The acked, correctly sized first buffer IS the locked frame.
    lock_surface.ackConfigure(lock_surface_events.serial);
    lock_wl_surface.attach(try ts.createFilledBuffer(800, 600, 0x80), 0, 0);
    lock_wl_surface.commit();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), lock_events.locked);
    try testing.expect(sl.isLocked());

    // Input reaches the lock client and nobody else.
    try testing.expect(sl.acceptsInput(ts.client.?));
    try testing.expect(!sl.acceptsInput(other_client));
    // The pointer reaches the lock surface and never the user toplevel:
    // the lock-aware pick drops every surface that is not a lock surface
    // (pickSurface, ext_session_lock_manager_v1 wiring item 2), so what
    // the hit test returns here is the lock surface, not user content.
    const picked = pickSurface(state, 10, 10) orelse return error.LockSurfaceNotPicked;
    try testing.expect(picked.surface == ts.serverSurface(lock_wl_surface));
    try testing.expect(!keyboardFocusAllowed(state, user_surface));
    try testing.expect(state.cursor_hidden);

    // The output shows the lock surface and nothing else: the user
    // toplevel's gray is gone even where it used to be.
    const locked = lockedFrameFor(state, view.output);
    // A locked frame never paints the cursor (LockedFrame.cursor_hidden),
    // so the expectation spells the whole struct out.
    try testing.expectEqual(LockedFrame{ .locked = true, .blank = false, .cursor_hidden = true }, locked);
    ts.renderView(view);
    try testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0xFF }, framebufferPixel(try ts.baseOf(view), 10, 10));
    try testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0xFF }, framebufferPixel(try ts.baseOf(view), 700, 500));

    // The lock surface stops covering its output (its object dies): the
    // fill stays opaque and NOTHING is drawn — user content must not come
    // back while the session is locked (ext_session_lock_v1:74-91).
    lock_surface.destroy();
    try ts.pump();
    try testing.expect(sl.isLocked());
    try testing.expectEqual(LockedFrame{ .locked = true, .blank = true, .cursor_hidden = true }, lockedFrameFor(state, view.output));
    ts.renderView(view);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0xFF }, framebufferPixel(try ts.baseOf(view), 10, 10));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0xFF }, framebufferPixel(try ts.baseOf(view), 700, 500));
    // Input stays suppressed: unlocking is the only way out.
    try testing.expect(!sl.acceptsInput(other_client));

    // unlock_and_destroy: the gates come off and normal service resumes.
    lock.unlockAndDestroy();
    try ts.pump();
    try testing.expect(!sl.isLocked());
    try testing.expectEqual(LockedFrame{ .locked = false, .blank = false }, lockedFrameFor(state, view.output));
    try testing.expect(keyboardFocusAllowed(state, user_surface));
    try testing.expect(!state.cursor_hidden);
    try testing.expect(sl.acceptsInput(other_client));
}

test "a locked session delivers no touch to user content" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const seat = ts.seat.?;

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const user_surface = ts.serverSurface(t.wl_surface);
    ts.pick_surface = user_surface;

    var events: ClientSeatEvents = .{};
    const wl_touch = try ts.wl_seat.?.getTouch();
    wl_touch.setListener(*ClientSeatEvents, ClientSeatEvents.touchListener, &events);
    try ts.pump();

    // Unlocked: the gesture is delivered, exactly as before the gate.
    seat.touchDown(1, 100, 100);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.downs);
    try testing.expectEqual(@as(usize, 1), seat.activeTouchPoints().len);
    seat.touchUp(1);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.ups);

    // The lock client takes the session.
    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try ts.lockSession(&lock_events, &lock_surface_events);
    try testing.expect(ts.session_lock.?.isLocked());

    // A finger on user content while locked: no down, no point registered,
    // no touch focus — exactly what a missed pick does.
    seat.touchDown(2, 100, 100);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.downs);
    try testing.expectEqual(@as(usize, 0), seat.activeTouchPoints().len);
    try testing.expectEqual(@as(?*Surface, null), seat.touchFocus());

    // The lock client's own surface still takes touch: the boundary
    // suppresses every client but the lock one, it does not suppress all.
    ts.pick_surface = lock_surface;
    seat.touchDown(3, 100, 100);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), events.downs);
    try testing.expectEqual(@as(usize, 1), seat.activeTouchPoints().len);
    try testing.expectEqual(@as(?*Surface, lock_surface), seat.touchFocus());

    // The gesture ends normally: up is NOT gated (swallowing it would
    // strand the client's point ids).
    seat.touchUp(3);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), events.ups);
    try testing.expectEqual(@as(usize, 0), seat.activeTouchPoints().len);
}

test "a touch point that was down when the session locked stops moving on user content" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const seat = ts.seat.?;

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const user_surface = ts.serverSurface(t.wl_surface);
    ts.pick_surface = user_surface;

    var events: ClientSeatEvents = .{};
    const wl_touch = try ts.wl_seat.?.getTouch();
    wl_touch.setListener(*ClientSeatEvents, ClientSeatEvents.touchListener, &events);
    try ts.pump();

    // A finger goes down on the user toplevel while the session is open.
    seat.touchDown(7, 100, 100);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.downs);
    try testing.expectEqual(@as(usize, 1), seat.activeTouchPoints().len);
    try testing.expectEqual(@as(?*Surface, user_surface), seat.touchFocus());

    // The session locks mid-gesture. This is the case the lock-aware PICK
    // alone does not cover, because the point is already down and there is
    // no new hit test to refuse. The pick is deliberately swapped for a
    // lock-UNAWARE one so the GATE is the only thing that can stop the
    // motion: with the production lock-aware pick installed, the motion is
    // dropped upstream of the gate and this test would prove nothing.
    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try ts.lockSession(&lock_events, &lock_surface_events);
    try testing.expect(ts.session_lock.?.isLocked());
    seat.setPick(pickIgnoringLock, ts);

    // The gate's own answer, both ways: user content is refused, the lock
    // surface is not (ext_session_lock_v1:77-85 — input stops for every
    // client but the lock one).
    try testing.expect(!touchAllowed(ts.state.?, user_surface));
    try testing.expect(touchAllowed(ts.state.?, lock_surface));

    // With the pick handing the seat the surface anyway, the motion is
    // still refused: no wl_touch.motion, and the seat's own point state
    // does not move — a refused point is as if it never arrived.
    seat.touchMotion(7, 400, 400);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), events.motions);
    try testing.expectEqual(@as(f64, 100), seat.activeTouchPoints()[0].x);
    try testing.expectEqual(@as(f64, 100), seat.activeTouchPoints()[0].y);

    // The up still goes out: the client saw the down, so its point must
    // resolve rather than hang forever. Up is deliberately NOT gated.
    seat.touchUp(7);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.ups);
    try testing.expectEqual(@as(usize, 0), seat.activeTouchPoints().len);
}

test "the session-lock latch ends an armed camera gesture and hands the lock client the pointer" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const seat = ts.seat.?;
    const gestures = &ts.state.?.gestures;

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const user_surface = ts.serverSurface(t.wl_surface);

    const pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: ClientPointerEvents = .{};
    pointer.setListener(*ClientPointerEvents, ClientPointerEvents.listener, &ptr_events);
    try ts.pump();

    // A left press on the window, then a drag past the threshold: the pan
    // arms and takes the pointer with the swallow grab (onSeatButton, then
    // onSeatPointerMove).
    ts.pick_surface = user_surface;
    seat.pointerMotion(10, 10);
    seat.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ptr_events.button);
    try testing.expect(gestures.camera_drag != null);
    seat.pointerMotion(300, 300);
    try ts.pump();
    try testing.expect(gestures.drag_active);
    try testing.expect(seat.pointer_grab == &wayland.seat.swallow_pointer_grab);

    // The session locks mid-pan.
    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try ts.lockSession(&lock_events, &lock_surface_events);
    try ts.pump();
    try testing.expect(ts.session_lock.?.isLocked());

    // The gesture is over and so is its record. It cannot end on its own
    // later: the release branch in onSeatButton is gated on the very lock
    // that armed it, so a live gesture would keep its seat grab (and an
    // interactive move would swallow the lock screen's pointer outright),
    // and a stale camera_drag pans the canvas on the first motion after
    // the unlock with no button held.
    try testing.expect(gestures.camera_drag == null);
    try testing.expect(!gestures.drag_active);
    try testing.expect(!gestures.fast_render);
    try testing.expect(gestures.moving_toplevel == null);
    try testing.expect(gestures.own_grab == null);
    try testing.expect(seat.pointer_grab == null);

    // The lock client has the pointer, and keeps it: motion and a click
    // are delivered, and neither installs a grab.
    const motion_before = ptr_events.motion;
    const buttons_before = ptr_events.button;
    ts.pick_surface = lock_surface;
    seat.pointerMotion(400, 400);
    try ts.pump();
    try testing.expect(seat.pointer_focus == lock_surface);
    try testing.expect(seat.pointer_grab == null);
    try testing.expect(ptr_events.motion > motion_before);
    seat.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();
    try testing.expect(seat.pointer_grab == null);
    try testing.expectEqual(buttons_before + 1, ptr_events.button);
}

test "a button held when the session locks is released to the client that took the press" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const seat = ts.seat.?;

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const user_surface = ts.serverSurface(t.wl_surface);

    const pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: ClientPointerEvents = .{};
    pointer.setListener(*ClientPointerEvents, ClientPointerEvents.listener, &ptr_events);
    try ts.pump();

    // The user client presses the left button on its own window: the press
    // is delivered and the seat remembers what that client now believes it
    // is holding.
    ts.pick_surface = user_surface;
    seat.pointerMotion(10, 10);
    seat.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ptr_events.button);
    try testing.expectEqual(@as(usize, 1), seat.held_button_count);
    try testing.expect(seat.held_buttons[0] == wayland.seat.btn_left);
    try testing.expect(seat.held_clients[0] == ts.client.?);

    // The session locks with the pointer still over the user window. The
    // latch's own pointerMotion runs the lock-aware pick, which drops user
    // content, so the seat's cached pointer focus is CLEARED — from here on
    // a physical release has nowhere to go (ext_session_lock_v1:81-84: the
    // lock client is the only input destination).
    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    _ = try ts.lockSession(&lock_events, &lock_surface_events);
    try ts.pump();
    try testing.expect(ts.session_lock.?.isLocked());
    try testing.expect(seat.pointer_focus == null);

    // The latch flushed the button: exactly ONE release, to the client
    // that received the press (not to whatever holds focus now), and the
    // held-button set is empty.
    try testing.expectEqual(@as(usize, 2), ptr_events.button);
    try testing.expectEqual(@as(usize, 0), seat.held_button_count);

    // The physical release now reaches nobody and re-arms nothing. Had
    // the latch left the entry, the pressed client would have been
    // stranded mid-gesture for the rest of the locked session, and the
    // next grab start would have invented a release for a button that was
    // already up.
    seat.pointerButton(wayland.seat.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), ptr_events.button);
    try testing.expectEqual(@as(usize, 0), seat.held_button_count);
}

test "a button held when the session locks is released with the pointer over the lock surface" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const seat = ts.seat.?;

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const user_surface = ts.serverSurface(t.wl_surface);

    const pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: ClientPointerEvents = .{};
    pointer.setListener(*ClientPointerEvents, ClientPointerEvents.listener, &ptr_events);
    try ts.pump();

    ts.pick_surface = user_surface;
    seat.pointerMotion(10, 10);
    seat.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ptr_events.button);
    try testing.expectEqual(@as(usize, 1), seat.held_button_count);

    // The lock client, up to but NOT including the latch — the harness
    // pick is armed with the lock surface first, so the latch's own
    // pointerMotion leaves the pointer focus ON the lock surface. That is
    // the other branch: here a physical release would reach the client
    // under the pointer, which never saw the press.
    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("ext_session_lock_manager_v1") orelse return error.GlobalMissing;
    const manager = try registry.bind(entry.name, client.ext.SessionLockManagerV1, entry.version);
    try ts.pump();
    var lock_events: LockClientEvents = .{};
    const lock = try manager.lock();
    lock.setListener(*LockClientEvents, LockClientEvents.listener, &lock_events);
    const lock_wl_surface = try ts.wl_compositor.?.createSurface();
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try lock.getLockSurface(lock_wl_surface, ts.wl_output_client.?);
    lock_surface.setListener(*LockSurfaceClientEvents, LockSurfaceClientEvents.listener, &lock_surface_events);
    try ts.pump();
    lock_surface.ackConfigure(lock_surface_events.serial);
    lock_wl_surface.attach(try ts.createFilledBuffer(800, 600, 0x80), 0, 0);
    ts.pick_surface = ts.serverSurface(lock_wl_surface);
    lock_wl_surface.commit();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), lock_events.locked);
    try testing.expect(ts.session_lock.?.isLocked());
    try testing.expect(seat.pointer_focus == ts.serverSurface(lock_wl_surface));

    // The release still went to the client that took the press, keyed on
    // held_clients rather than on the surface the pointer is over.
    try testing.expectEqual(@as(usize, 2), ptr_events.button);
    try testing.expectEqual(@as(usize, 0), seat.held_button_count);
}

test "a locked session refuses an interactive move request" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const seat = ts.seat.?;
    const gestures = &ts.state.?.gestures;

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);

    const pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: ClientPointerEvents = .{};
    pointer.setListener(*ClientPointerEvents, ClientPointerEvents.listener, &ptr_events);
    try ts.pump();

    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    const lock_surface = try ts.lockSession(&lock_events, &lock_surface_events);
    try ts.pump();
    ts.pick_surface = lock_surface;
    seat.pointerMotion(400, 400);
    try ts.pump();

    // A well-formed move request while the session is locked: serialFor
    // mints a serial the seat's own validateEventSerial accepts, so the
    // lock is the only thing that can refuse it (xdg-shell.xml:761-763 lets
    // the server ignore a move request).
    t.toplevel.move(ts.wl_seat.?, seat.serialFor(ts.client.?));
    try ts.pump();

    // No interactive move, and above all no grab: a move armed here owns
    // the pointer until the button release, and that release is gated on
    // the lock itself — the lock screen's pointer would stay swallowed for
    // the rest of the locked session.
    try testing.expect(gestures.moving_toplevel == null);
    try testing.expect(gestures.own_grab == null);
    try testing.expect(seat.pointer_grab == null);

    // The lock client still has a live pointer: motion and a click land.
    const motion_before = ptr_events.motion;
    const buttons_before = ptr_events.button;
    seat.pointerMotion(410, 410);
    try ts.pump();
    try testing.expect(seat.pointer_grab == null);
    try testing.expect(ptr_events.motion > motion_before);
    seat.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();
    try testing.expect(seat.pointer_grab == null);
    try testing.expectEqual(buttons_before + 1, ptr_events.button);
}

/// A hit test that does NOT consult the session lock, for the one test
/// that must show the touch gate refusing a point on its own: with the
/// production lock-aware pick installed a motion is already dropped by the
/// pick, and the gate would never be reached. Installed over `Seat.setPick`
/// for the body of that test only.
fn pickIgnoringLock(ctx: *anyopaque, x: i32, y: i32) ?wayland.seat.Seat.PickResult {
    const ts: *PolicyServer = @ptrCast(@alignCast(ctx));
    const s = ts.pick_surface orelse return null;
    return .{ .surface = s, .sx = @floatFromInt(x), .sy = @floatFromInt(y) };
}

// ---------------------------------------------------------------------------
// Input hotplug: Backend.events.input_removed
// ---------------------------------------------------------------------------

test "the last input device of a kind going away withdraws its wl_seat capability" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const seat = ts.seat.?;
    // The production subscription main() makes: the same two listeners on
    // one Backend. The harness has one Backend for both roles, so it plays
    // the libinput backend's part here (WAYLAND_LIBINPUT=1).
    ts.backend.?.events.new_input.add(&ts.state.?.new_input_listener);
    ts.backend.?.events.input_removed.add(&ts.state.?.input_removed_listener);

    const touch_capability = wayland.seat.capabilities_touch;
    const pointer_capability = wayland.seat.capabilities_pointer;
    try testing.expect(seat.capabilities & touch_capability != 0);
    try testing.expect(seat.capabilities & pointer_capability != 0);

    // Two touchscreens: the first removal must NOT withdraw the bit,
    // because another device of the kind still provides it.
    var first: wayland.backend.Backend.InputDevice = .{ .kind = .touch, .name = "Touchscreen A" };
    var second: wayland.backend.Backend.InputDevice = .{ .kind = .touch, .name = "Touchscreen B" };
    ts.backend.?.emitNewInput(&first);
    ts.backend.?.emitNewInput(&second);
    try testing.expect(seat.capabilities & touch_capability != 0);

    ts.backend.?.emitInputRemoved(&first);
    try testing.expect(seat.capabilities & touch_capability != 0);

    // A removal for an identity the seat never announced is ignored: it
    // must not withdraw a bit another live device still justifies.
    var stranger: wayland.backend.Backend.InputDevice = .{ .kind = .touch, .name = "Never Announced" };
    ts.backend.?.emitInputRemoved(&stranger);
    try testing.expect(seat.capabilities & touch_capability != 0);

    // The LAST touchscreen: the touch bit is withdrawn, and only it — the
    // pointer bit belongs to a different kind and stays.
    ts.backend.?.emitInputRemoved(&second);
    try testing.expect(seat.capabilities & touch_capability == 0);
    try testing.expect(seat.capabilities & pointer_capability != 0);

    // A client that asks for the withdrawn interface now gets the
    // protocol's missing_capability error rather than a dead object
    // (wayland.xml:2094-2098) — the seat serves no wl_touch at all.
    try testing.expectEqual(@as(usize, 0), seat.touches.items.len);
}

test "an unplugged touchscreen with a point down closes the gesture before inverting wl_touch" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const seat = ts.seat.?;
    ts.backend.?.events.new_input.add(&ts.state.?.new_input_listener);
    ts.backend.?.events.input_removed.add(&ts.state.?.input_removed_listener);

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    ts.pick_surface = ts.serverSurface(t.wl_surface);

    var touch: wayland.backend.Backend.InputDevice = .{ .kind = .touch, .name = "Touchscreen" };
    ts.backend.?.emitNewInput(&touch);

    // A client with live wl_touch and wl_pointer resources, so the gesture
    // the withdrawal has to finalize is delivered to something whose wire
    // state must stay consistent: the points go out on wl_touch, and the
    // enter/leave pair on this client's wl_pointer (wl_touch has no
    // enter/leave of its own — seat.zig's touch wire model).
    var events: ClientSeatEvents = .{};
    const wl_pointer = try ts.wl_seat.?.getPointer();
    wl_pointer.setListener(*ClientSeatEvents, ClientSeatEvents.pointerListener, &events);
    const wl_touch = try ts.wl_seat.?.getTouch();
    wl_touch.setListener(*ClientSeatEvents, ClientSeatEvents.touchListener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), seat.touches.items.len);
    try testing.expectEqual(@as(usize, 1), seat.pointers.items.len);

    seat.touchDown(1, 100, 100);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.downs);
    try testing.expectEqual(@as(usize, 1), seat.activeTouchPoints().len);

    // The device is unplugged with the finger still down. The gesture must
    // be finalized (an up per point plus the leave) BEFORE the wl_touch
    // resources are inerted, or the client waits forever on a point that
    // will never lift.
    ts.backend.?.emitInputRemoved(&touch);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.ups);
    try testing.expectEqual(@as(usize, 1), events.leaves);
    try testing.expectEqual(@as(usize, 0), seat.activeTouchPoints().len);
    try testing.expectEqual(@as(usize, 0), seat.touches.items.len);
    try testing.expect(seat.capabilities & wayland.seat.capabilities_touch == 0);
}

/// The client's wl_touch event record: what a locked session must not
/// produce, and what a withdrawn capability must finalize.
const ClientSeatEvents = struct {
    downs: usize = 0,
    motions: usize = 0,
    ups: usize = 0,
    cancels: usize = 0,
    frames: usize = 0,
    /// The pointer enter/leave pair the seat emits on the TOUCHED surface's
    /// own client's pointer resources (wl_touch has no enter/leave of its
    /// own; seat.zig's touch wire model).
    leaves: usize = 0,

    fn touchListener(_: *client.wl.Touch, event: client.wl.Touch.Event, self: *ClientSeatEvents) void {
        switch (event) {
            .down => self.downs += 1,
            .motion => self.motions += 1,
            .up => self.ups += 1,
            .cancel => self.cancels += 1,
            .frame => self.frames += 1,
            .shape, .orientation => {},
        }
    }

    fn pointerListener(_: *client.wl.Pointer, event: client.wl.Pointer.Event, self: *ClientSeatEvents) void {
        switch (event) {
            .leave => self.leaves += 1,
            .enter, .motion, .button, .axis, .frame, .axis_source, .axis_stop, .axis_discrete, .axis_value120, .axis_relative_direction, .warp => {},
        }
    }
};

// ---------------------------------------------------------------------------
// zwp_linux_dmabuf_v1 -> wl_surface.attach
// ---------------------------------------------------------------------------
//
// main()'s dmabuf wiring is two statements (wireDmabufResolver, then
// clearDmabufResolver before the module dies). What they enable is only
// observable over the wire: a client binds zwp_linux_dmabuf_v1, imports a
// buffer and attaches it to a wl_surface. Without the resolver that
// attach falls into the SHM wrap, which does not recognise a dmabuf
// wl_buffer, and the client is killed with "unknown buffer type".

/// A CPU-backed stand-in for the DRM backend's GBM device. The real
/// importer needs a DRM node; what is under test is the attach path, so
/// the import is a plain Buffer of the requested size. Mirrors the
/// double in shell/linux_dmabuf.zig's own harness, which proves the
/// protocol itself.
const FakeImportDevice = struct {
    formats: []const wayland.dmabuf.Format,
    /// How many imports reached the device.
    imports: u32 = 0,
    /// The interface view. `ptr` is filled in by init, because it must be
    /// this struct's own address.
    iface: wayland.dmabuf.Device = undefined,

    const Data = struct { width: i32, height: i32 };

    const impl: wayland.buffers.Impl = .{ .destroy = destroy };

    fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
        allocator.destroy(@as(*Data, @ptrCast(@alignCast(data))));
    }

    fn mainDevice(_: *anyopaque) u64 {
        // An arbitrary but stable dev_t; no test reads it back.
        return 0x1234_5678;
    }

    fn formatsOf(ptr: *anyopaque) []const wayland.dmabuf.Format {
        return @as(*FakeImportDevice, @ptrCast(@alignCast(ptr))).formats;
    }

    fn importBuffer(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        attrs_in: wayland.dmabuf.Attributes,
    ) error{ OutOfMemory, ImportFailed }!*wayland.buffers.Buffer {
        const self: *FakeImportDevice = @ptrCast(@alignCast(ptr));
        self.imports += 1;
        // The plane fds are ours on entry: a real importer closes them on
        // failure and once the bo owns the object (buffers/dmabuf.zig).
        var attrs = attrs_in;
        defer attrs.closePlanes();
        const d = try allocator.create(Data);
        errdefer allocator.destroy(d);
        d.* = .{ .width = attrs.width, .height = attrs.height };
        return wayland.buffers.Buffer.init(allocator, &impl, d, attrs.width, attrs.height);
    }

    const vtable: wayland.dmabuf.Device.VTable = .{
        .main_device = mainDevice,
        .formats = formatsOf,
        .import_buffer = importBuffer,
    };

    fn init(self: *FakeImportDevice, formats: []const wayland.dmabuf.Format) void {
        self.* = .{ .formats = formats, .iface = .{ .ptr = undefined, .vtable = &vtable } };
        self.iface.ptr = self;
    }
};

/// The pairs the fake advertises: linear only, like the GBM device it
/// stands in for (buffers/dmabuf.zig).
const fake_import_formats = [_]wayland.dmabuf.Format{
    .{ .format = wayland.dmabuf.drm_format_xrgb8888, .modifier = wayland.dmabuf.drm_format_mod_linear },
    .{ .format = wayland.dmabuf.drm_format_argb8888, .modifier = wayland.dmabuf.drm_format_mod_linear },
};

/// A compositor + wl_shm + zwp_linux_dmabuf_v1 stack with one in-memory
/// client: the smallest server main() builds that can answer a dmabuf
/// attach. Built in main()'s order, with main()'s resolver wiring
/// verbatim, so the code under test is the production one.
const DmabufAttachServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*wayland.core.display.CompositorDisplay = null,
    shm_state: ?*wayland.shm.ShmState = null,
    compositor: ?*wayland.compositor.Compositor = null,
    linux_dmabuf: ?*wayland.linux_dmabuf.LinuxDmabuf = null,
    device: ?*FakeImportDevice = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_dmabuf: ?*client.zwp.LinuxDmabufV1 = null,
    /// False once the server killed the connection (a protocol error).
    alive: bool = true,

    fn init(allocator: std.mem.Allocator) !*DmabufAttachServer {
        const ts = try allocator.create(DmabufAttachServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try wayland.core.display.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        try ts.display.?.initShm();
        ts.shm_state = try wayland.shm.ShmState.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.shm_state) |s| s.deinit();
        ts.compositor = try wayland.compositor.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.compositor.?.setShm(ts.shm_state.?);
        // The device is the ONLY stand-in here: the compositor, the shm
        // state and the dmabuf module are the production ones.
        const device = try allocator.create(FakeImportDevice);
        errdefer allocator.destroy(device);
        device.init(&fake_import_formats);
        ts.device = device;
        ts.linux_dmabuf = try wayland.linux_dmabuf.LinuxDmabuf.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            &device.iface,
        );
        errdefer if (ts.linux_dmabuf) |l| l.deinit();
        // main()'s wiring, unchanged.
        wireDmabufResolver(ts.compositor.?, ts.linux_dmabuf.?);

        // In-memory client: one socketpair end for the server, one for the
        // client library.
        var fds: [2]std.posix.socket_t = undefined;
        const rc = std.posix.system.socketpair(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
            &fds,
        );
        if (std.posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ClientCreateFailed;
        };
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch {
            _ = std.os.linux.close(fds[1]);
            ts.client.?.destroy();
            ts.client = null;
            return error.ClientConnectFailed;
        };

        const registry = try ts.c_display.?.getRegistry();
        var capture: PolicyGlobalCapture = .{};
        registry.setListener(*PolicyGlobalCapture, PolicyGlobalCapture.listener, &capture);
        try ts.pump();
        const compositor = capture.find("wl_compositor") orelse return error.GlobalMissing;
        const dmabuf = capture.find("zwp_linux_dmabuf_v1") orelse return error.GlobalMissing;
        ts.wl_compositor = try registry.bind(compositor.name, client.wl.Compositor, 7);
        ts.wl_dmabuf = try registry.bind(dmabuf.name, client.zwp.LinuxDmabufV1, dmabuf.version);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *DmabufAttachServer) void {
        // main()'s teardown order: the client first (its resource destroy
        // handlers must run while the modules live), then the resolver is
        // cleared, then the dmabuf module, then shm, the compositor and
        // the display.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        ts.compositor.?.clearDmabufResolver();
        ts.linux_dmabuf.?.deinit();
        ts.compositor.?.deinit();
        ts.shm_state.?.deinit();
        ts.display.?.deinit();
        if (ts.device) |d| ts.allocator.destroy(d);
        ts.allocator.destroy(ts);
    }

    /// Client flush + server dispatch. Every server-side effect of the
    /// queued requests has happened (including a protocol error), but
    /// nothing has been flushed to the client yet, so the server-side
    /// surfaces are still alive and readable.
    fn toServer(ts: *DmabufAttachServer) !void {
        if (!ts.alive) return;
        if (ts.c_display.?.flush() != .SUCCESS) {
            ts.alive = false;
            return;
        }
        try ts.display.?.getServer().getEventLoop().dispatch(0);
    }

    /// Server flush + client dispatch. False once the server killed the
    /// connection: libwayland reports the posted protocol error and tears
    /// the client down, and so has the server (it destroyed the client at
    /// flush time), so the wire.Client pointer is dropped.
    fn toClient(ts: *DmabufAttachServer) bool {
        if (!ts.alive) return false;
        ts.display.?.flushClients();
        var fds = [_]std.posix.pollfd{.{
            .fd = ts.c_display.?.getFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready: usize = std.posix.poll(&fds, 0) catch 0;
        if (ready > 0 and ts.c_display.?.dispatch() != .SUCCESS) {
            ts.alive = false;
            ts.client = null;
            return false;
        }
        return true;
    }

    fn pump(ts: *DmabufAttachServer) !void {
        try ts.toServer();
        if (!ts.toClient()) return error.ClientGone;
    }

    /// The compositor Surface behind a client wl_surface.
    fn serverSurface(ts: *DmabufAttachServer, wl_surface: *client.wl.Surface) *Surface {
        for (ts.compositor.?.surfaces.items) |s| {
            if (s.resource.getId() == wl_surface.getId()) return s;
        }
        unreachable;
    }

    /// Import one buffer the way a client does: a params object, one
    /// plane, then `create`. Returns the wl_buffer the server made.
    fn importBuffer(ts: *DmabufAttachServer, width: i32, height: i32) !*client.wl.Buffer {
        const params = try ts.wl_dmabuf.?.createParams();
        var capture: DmabufParamsCapture = .{};
        params.setListener(*DmabufParamsCapture, DmabufParamsCapture.listener, &capture);
        const stride: u32 = @intCast(width * 4);
        const size: usize = @as(usize, stride) * @as(usize, @intCast(height));
        const fd = try std.posix.memfd_create("dmabuf-attach-test", std.os.linux.MFD.CLOEXEC);
        _ = std.os.linux.ftruncate(fd, @intCast(size));
        // `add` takes the fd: paramsAdd closes it on every rejection and
        // hands it to the importer otherwise.
        params.add(fd, 0, 0, stride, 0, 0);
        params.create(width, height, wayland.dmabuf.drm_format_xrgb8888, .{});
        try ts.pump();
        if (capture.failed) return error.ImportFailed;
        return capture.created orelse error.NoBufferCreated;
    }
};

/// What a client saw on its zwp_linux_buffer_params_v1.
const DmabufParamsCapture = struct {
    created: ?*client.wl.Buffer = null,
    failed: bool = false,

    fn listener(
        _: *client.zwp.LinuxBufferParamsV1,
        event: client.zwp.LinuxBufferParamsV1.Event,
        self: *DmabufParamsCapture,
    ) void {
        switch (event) {
            .created => |e| self.created = e.buffer,
            .failed => self.failed = true,
        }
    }
};

test "a dmabuf buffer attaches to a wl_surface, maps at commit and damages through the pipeline" {
    const allocator = testing.allocator;
    const ts = try DmabufAttachServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    try ts.pump();
    const s = ts.serverSurface(wl_surface);

    const buffer = try ts.importBuffer(64, 64);
    try testing.expectEqual(@as(u32, 1), ts.device.?.imports);

    // The whole GPU-client path: attach, damage, commit. Nothing else in
    // the pipeline knows or cares that this buffer came from
    // zwp_linux_dmabuf_v1 instead of wl_shm.
    wl_surface.attach(buffer, 0, 0);
    wl_surface.damage(2, 3, 10, 10);
    wl_surface.commit();
    try ts.pump();

    try testing.expect(s.mapped);
    try testing.expect(s.buffer != null);
    // The committed wrapper IS the module's: resolving the attached
    // wl_buffer resource back through LinuxDmabuf.fromResource gives the
    // very Buffer the surface holds, not a copy and not an shm wrap.
    const committed = s.current_resource orelse return error.NoCommittedResource;
    const resolved = ts.linux_dmabuf.?.fromResource(committed) orelse return error.NotADmabufBuffer;
    try testing.expect(resolved == s.buffer.?);
    try testing.expectEqual(@as(i32, 64), resolved.width);
    try testing.expectEqual(@as(i32, 64), resolved.height);
    // Damage made it through translateDamage into buffer coordinates.
    try testing.expectEqual(@as(usize, 1), s.current.buffer_damage.rects.items.len);
    try testing.expectEqual(
        geom.Rect{ .x = 2, .y = 3, .width = 10, .height = 10 },
        s.current.buffer_damage.rects.items[0],
    );
    try testing.expectEqual(@as(usize, 1), s.current.surface_damage.rects.items.len);
}

test "with the resolver cleared a dmabuf buffer is no longer attached (F56)" {
    // main() clears the resolver BEFORE LinuxDmabuf.deinit, so an attach
    // arriving afterwards must not reach the module: the buffer takes the
    // shm path, which does not recognise it, and the client is killed with
    // "unknown buffer type". The identical request sequence with the
    // resolver in place is the test above — that pair is the point.
    const allocator = testing.allocator;
    const ts = try DmabufAttachServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    try ts.pump();
    const s = ts.serverSurface(wl_surface);
    const buffer = try ts.importBuffer(32, 32);

    ts.compositor.?.clearDmabufResolver();
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    // libwayland destroys a client the moment a protocol error is posted,
    // so the Surface is gone before this returns and its pointer must not
    // be dereferenced. The server-side proof that the attach was rejected
    // rather than resolved is that the client, and every surface it owned,
    // is gone.
    try ts.toServer();
    try testing.expect(std.mem.indexOfScalar(*Surface, ts.compositor.?.surfaces.items, s) == null);
    // Client side: the protocol error took the connection down.
    try testing.expect(!ts.toClient());
}

// ---------------------------------------------------------------------------
// zwlr_screencopy_v1 -> zwp_linux_dmabuf_v1 destination
// ---------------------------------------------------------------------------
//
// main()'s screencopy dmabuf wiring is two statements: wireScreencopyDmabuf
// once linux_dmabuf exists, then clearScreencopyDmabuf before the module
// dies. Both are visible to a client only through the frames it captures:
// with a destination installed a v3 frame advertises the `linux_dmabuf`
// buffer type and accepts a dmabuf wl_buffer, without one the same copy is
// the invalid_buffer protocol error it has always been.

test "without a dmabuf destination a screencopy frame advertises only shm" {
    // The default harness builds zwp_linux_dmabuf_v1 with NO device (the
    // documented null-device state every non-DRM backend is in), so this is
    // exactly what main() wires on a headless / raylib / nested run.
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("zwlr_screencopy_manager_v1") orelse return error.GlobalMissing;
    const manager = try registry.bind(entry.name, client.zwlr.ScreencopyManagerV1, 3);
    try ts.pump();

    var events: ClientScreencopyFrameEvents = .{};
    const frame = try manager.captureOutput(0, ts.wl_output_client.?);
    frame.setListener(*ClientScreencopyFrameEvents, ClientScreencopyFrameEvents.listener, &events);
    try ts.pump();

    try testing.expectEqual(@as(usize, 1), events.buffers);
    try testing.expectEqual(@as(usize, 1), events.buffer_done);
    try testing.expectEqual(@as(usize, 0), events.failed);
    // No dmabuf type: the client was never told one exists, so a dmabuf
    // buffer it sends stays the invalid_buffer protocol error it has
    // always been — today's behaviour, unchanged.
    try testing.expectEqual(@as(usize, 0), events.linux_dmabuf);
}

test "a screencopy dmabuf destination is wired only when the module has a device" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    // The harness's LinuxDmabuf has no device, so the production wiring
    // must leave the module shm-only rather than advertise a buffer type
    // no client on this backend can produce.
    try testing.expect(!ts.linux_dmabuf.?.advertised());
    wireScreencopyDmabufInto(ts.screencopy.?, ts.linux_dmabuf.?, &ts.io, &ts.log_cfg);
    try testing.expect(ts.screencopy.?.dmabuf == null);

    // The frame a client gets is unchanged: one shm buffer type, no
    // dmabuf, no failure.
    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("zwlr_screencopy_manager_v1") orelse return error.GlobalMissing;
    const manager = try registry.bind(entry.name, client.zwlr.ScreencopyManagerV1, 3);
    try ts.pump();
    var events: ClientScreencopyFrameEvents = .{};
    const frame = try manager.captureOutput(0, ts.wl_output_client.?);
    frame.setListener(*ClientScreencopyFrameEvents, ClientScreencopyFrameEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.buffers);
    try testing.expectEqual(@as(usize, 0), events.linux_dmabuf);
    try testing.expectEqual(@as(usize, 0), events.failed);
}

test "clearing the screencopy dmabuf destination removes the advertised buffer type" {
    // The teardown half: main() drops the destination before
    // linux_dmabuf.deinit, so a `copy` arriving afterwards cannot
    // dereference the freed module through `destination.ctx`. What that
    // looks like from a client is the shm-only frame again.
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const sc = ts.screencopy.?;

    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("zwlr_screencopy_manager_v1") orelse return error.GlobalMissing;
    const manager = try registry.bind(entry.name, client.zwlr.ScreencopyManagerV1, 3);
    try ts.pump();

    // The harness cannot allocate a real gbm bo (bo creation belongs to
    // the dmabuf module and needs a real GBM device), so the destination
    // is installed over the harness's inert module by hand. It is the SAME
    // struct production installs — same ctx, same resolver, same write
    // mapping — so the advertisement below is the one a wired server
    // makes, and the clear that follows is the production statement.
    sc.setDmabufDestination(.{
        .ctx = ts.linux_dmabuf.?,
        .resolve = resolveDmabufBuffer,
        .begin_write = beginDmabufWrite,
        .end_write = endDmabufWrite,
    });

    var with_destination: ClientScreencopyFrameEvents = .{};
    const frame = try manager.captureOutput(0, ts.wl_output_client.?);
    frame.setListener(*ClientScreencopyFrameEvents, ClientScreencopyFrameEvents.listener, &with_destination);
    try ts.pump();
    // A v3 client with a destination wired is told about BOTH buffer
    // types: the shm one and the dmabuf one, with the fourcc the frame's
    // own format maps to (wlr-screencopy-unstable-v1.xml:211-220).
    try testing.expectEqual(@as(usize, 1), with_destination.buffers);
    try testing.expectEqual(@as(usize, 1), with_destination.linux_dmabuf);
    try testing.expectEqual(wayland.dmabuf.drm_format_argb8888, with_destination.linux_dmabuf_format);
    try testing.expectEqual(@as(usize, 1), with_destination.buffer_done);
    try testing.expectEqual(@as(usize, 0), with_destination.failed);

    clearScreencopyDmabufInto(sc);
    try testing.expect(sc.dmabuf == null);

    var after_clear: ClientScreencopyFrameEvents = .{};
    const frame2 = try manager.captureOutput(0, ts.wl_output_client.?);
    frame2.setListener(*ClientScreencopyFrameEvents, ClientScreencopyFrameEvents.listener, &after_clear);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), after_clear.buffers);
    try testing.expectEqual(@as(usize, 0), after_clear.linux_dmabuf);
    try testing.expectEqual(@as(usize, 0), after_clear.failed);
}

// ---------------------------------------------------------------------------
// M6: logind session + connector hotplug pollers
// ---------------------------------------------------------------------------

test "with no logind session the server arms no session poller and still runs" {
    // The VM case: a DRM backend that never started has no session, no
    // connector monitor and no card fd, so `extraFds` is all -1. The server
    // must arm no poller for any of them — a PipePoll on -1 would report
    // readable forever and spin the loop — and must keep serving the
    // display, which is what "still starts" means here.
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const state = ts.state.?;

    const drm = try drm_mod.DrmBackend.create(testing.allocator, &ts.io, &ts.log_cfg, "/nonexistent/card");
    defer drm.destroy();
    const data = drm_mod.DrmBackend.fromBackend(drm);
    const extra = drm_mod.extraFds(data);
    try testing.expectEqual(@as(std.posix.fd_t, -1), extra.session);
    try testing.expectEqual(@as(std.posix.fd_t, -1), extra.hotplug);
    // The dispatch functions are the no-ops that make the missing fds
    // harmless: calling them on a session-less backend must not fault.
    drm_mod.dispatchSession(data);
    drm_mod.dispatchHotplug(drm, data);

    // A real event loop, driven the way main() drives it. The three M6
    // pollers are armed through the same helper main() uses, with the
    // session-less backend's -1 fds: nothing is registered, so the loop
    // has no descriptor to spin on.
    var loop: zio.ev.Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();
    const previous_loop = state.loop;
    state.loop = &loop;
    defer state.loop = previous_loop;

    // The display poller, armed the way armEventLoop does it, so the loop
    // has the ONE descriptor it should have on a session-less machine.
    var timers: LoopTimers = undefined;
    timers.display_poll = zio.ev.PipePoll.init(state.display.loopFd(), .read);
    timers.display_poll.c.userdata = state;
    timers.display_poll.c.callback = onDisplayReady;
    timers.display_poll.c.flags.rearm = true;
    loop.add(&timers.display_poll.c);

    // The three new pollers go through the same helper main() uses, fed the
    // -1 each subsystem answers with when the feature is missing (this
    // backend's own session/hotplug pair, and the libinput monitor's -1 for
    // an environment with no udevd). None is registered, so the loop has no
    // descriptor to spin on.
    var hotplug_poll: zio.ev.PipePoll = undefined;
    var session_poll: zio.ev.PipePoll = undefined;
    var connector_poll: zio.ev.PipePoll = undefined;
    try testing.expect(!armFdPoll(&loop, &hotplug_poll, -1, state, onInputHotplugReady));
    try testing.expect(!armFdPoll(&loop, &session_poll, extra.session, state, onDrmSessionReady));
    try testing.expect(!armFdPoll(&loop, &connector_poll, extra.hotplug, state, onDrmHotplugReady));
    // With nothing armed the poller slots stay at the "no fd" default the
    // state records, and the loop has nothing spurious to wake on.
    try testing.expectEqual(@as(c_int, -1), state.drm_session_poll_fd);
    try testing.expectEqual(@as(c_int, -1), state.drm_hotplug_poll_fd);
    try testing.expectEqual(@as(c_int, -1), state.input_hotplug_poll_fd);

    // A client request queued before the loop runs: the display poller is
    // the one that must fire, proving the loop is live and not wedged on a
    // missing descriptor.
    const wl_surface = try ts.wl_compositor.?.createSurface();
    try testing.expect(wl_surface.getId() != 0);
    if (ts.c_display.?.flush() != .SUCCESS) return error.FlushFailed;
    var iterations: usize = 0;
    while (iterations < 8) : (iterations += 1) {
        try loop.poll(.zero);
        if (ts.compositor.?.surfaces.items.len > 0) break;
    }
    // The compositor saw the client's create_surface: the display fd was
    // dispatched, and the absent session fds cost nothing.
    try testing.expectEqual(@as(usize, 1), ts.compositor.?.surfaces.items.len);
}

test "an output comes up on a machine with no logind session at all" {
    // The other half of "still starts": the output the server drives is
    // unaffected by the absence of a session, which is the VM this
    // compositor runs in today. The output is enabled by the same
    // enable-only commit onNewOutput makes, which the harness factory
    // performs when it builds its view.
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();

    const out = ts.output.?;
    try testing.expect(out.enabled);
    try testing.expectEqual(@as(i32, 800), out.mode.width);
    try testing.expectEqual(@as(i32, 600), out.mode.height);

    // The frame signal fires on an enabled output (wlroots
    // wlr_output_send_frame, output.c:833-837): the output is really up,
    // not merely flagged enabled.
    var recorder: FrameRecorder = .{};
    defer if (recorder.listener.link.prev != null) recorder.listener.link.remove();
    out.events.frame.add(&recorder.listener);
    out.sendFrame();
    try testing.expectEqual(@as(usize, 1), recorder.count);
}

/// One `Output.events.frame` listener, for the test that watches a frame
/// signal without standing up a whole backend.
const FrameRecorder = struct {
    listener: wire.Listener(*wayland.output.Output) = wire.Listener(*wayland.output.Output).init(onFrame),
    count: usize = 0,

    fn onFrame(listener: *wire.Listener(*wayland.output.Output), _: *wayland.output.Output) void {
        const self: *FrameRecorder = @fieldParentPtr("listener", listener);
        self.count += 1;
    }
};

/// The clear half over the module alone, so a test can drop the
/// destination without a whole ServerState behind it.
fn clearScreencopyDmabufInto(sc: *wayland.screencopy.Screencopy) void {
    sc.clearDmabufDestination();
}

/// What a client saw on its zwlr_screencopy_frame_v1: which buffer types
/// the frame advertised, and how it ended.
const ClientScreencopyFrameEvents = struct {
    buffers: usize = 0,
    linux_dmabuf: usize = 0,
    buffer_done: usize = 0,
    ready: usize = 0,
    failed: usize = 0,
    linux_dmabuf_format: u32 = 0,

    fn listener(_: *client.zwlr.ScreencopyFrameV1, event: client.zwlr.ScreencopyFrameV1.Event, self: *ClientScreencopyFrameEvents) void {
        switch (event) {
            .buffer => self.buffers += 1,
            .linux_dmabuf => |d| {
                self.linux_dmabuf += 1;
                self.linux_dmabuf_format = d.format;
            },
            .buffer_done => self.buffer_done += 1,
            .ready => self.ready += 1,
            .failed => self.failed += 1,
            // flags and damage are the metadata a v4+ client gets
            // alongside the copy; nothing here reads them.
            .flags, .damage => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Renderer selection (WAYLAND_RENDERER)
// ---------------------------------------------------------------------------
//
// The tests below pin three things: the selection rule itself, the
// default's bytes (the CPU canvas pass must keep compositing what it
// always has), and the GLES2 path — that it composites the same canvas
// through renderer/gles2.zig and that the camera really reaches the
// shader as its one scene -> target affine.

/// EGL/GLES2 is single-threaded per process: the display's current
/// context is process-global, and `zig test` runs test bodies on a
/// thread pool, so two renderers created at once fight over it (the
/// same hazard renderer/gles2.zig locks its own tests against). One
/// lock for every GL-touching body in this file.
var gles2_server_test_lock: std.atomic.Value(bool) = .init(false);

fn lockGles2ServerTest() void {
    while (gles2_server_test_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.Thread.yield() catch continue;
    }
}

fn unlockGles2ServerTest() void {
    gles2_server_test_lock.store(false, .release);
}

/// The premultiplied ARGB8888 memory bytes of the background fill
/// (0.1, 0.1, 0.12, 1.0) as the CPU canvas pass produces them:
/// B = round(0.12 * 255) = 31, G = R = round(0.1 * 255) = 26.
const background_bytes: [4]u8 = .{ 0x1F, 0x1A, 0x1A, 0xFF };
/// The test client's opaque gray surface (filledMemfd, value 0x40).
const surface_bytes: [4]u8 = .{ 0x40, 0x40, 0x40, 0xFF };

/// The background fill as the GLES2 pass produces it: the SAME colour,
/// but its float -> unorm8 conversion runs at the shader's `mediump`
/// precision (GLES2 gles2.zig's fragment shader, "precision mediump
/// float"), where 0.1 is 0.09997… and lands on 25 instead of the exact
/// 25.5 the CPU path rounds away from zero to 26. One unit, and only on
/// a channel whose exact value sits on a .5 boundary — so the GLES2
/// assertions check the fill within one unit per channel rather than
/// pinning a driver's rounding choice. The alpha is opaque on both.
fn expectFillPixel(got: [4]u8) !void {
    for (background_bytes, got) |want, actual| {
        const diff = if (want > actual) want - actual else actual - want;
        testing.expect(diff <= 1) catch |err| {
            std.debug.print("background pixel: got {any}, expected {any} (within one unit)\n", .{ got, background_bytes });
            return err;
        };
    }
}

test "WAYLAND_RENDERER selects the renderer; an unknown value is rejected, not guessed" {
    // Unset is the default: the CPU renderer, every byte of what this
    // server has always presented.
    try testing.expectEqual(RendererKind.pixman, parseRendererEnv(null).?);
    try testing.expectEqual(RendererKind.pixman, parseRendererEnv("pixman").?);
    try testing.expectEqual(RendererKind.gles2, parseRendererEnv("gles2").?);
    // Unknown values return null so the caller WARNS and falls back,
    // instead of silently rendering with something nobody asked for.
    // Matching is exact — case included: a typo must not reach EGL.
    try testing.expectEqual(@as(?RendererKind, null), parseRendererEnv("vulkan"));
    try testing.expectEqual(@as(?RendererKind, null), parseRendererEnv(""));
    try testing.expectEqual(@as(?RendererKind, null), parseRendererEnv("GLES2"));
    try testing.expectEqual(@as(?RendererKind, null), parseRendererEnv(" pixman"));
}

test "WAYLAND_RENDERER=pixman composites the canvas byte for byte as before" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const state = ts.state.?;
    const view = ts.viewOf();
    // The default: one renderer, and it is the CPU one.
    try testing.expectEqual(RendererKind.pixman, state.renderer_kind);
    try testing.expect(state.renderer == state.pixman_renderer);

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    ts.renderView(view);
    const base = try ts.baseOf(view);

    // The 64x64 opaque gray toplevel at the canvas origin, and the
    // background fill everywhere else. These are the exact bytes the
    // server has produced for this canvas since the canvas pass landed;
    // a refactor that changed the fill math, the item order or the
    // sampling would move one of them.
    try testing.expectEqual(surface_bytes, framebufferPixel(base, 10, 10));
    try testing.expectEqual(surface_bytes, framebufferPixel(base, 63, 63));
    try testing.expectEqual(background_bytes, framebufferPixel(base, 64, 64));
    try testing.expectEqual(background_bytes, framebufferPixel(base, 700, 500));
}

test "WAYLAND_RENDERER=gles2 composites the same canvas through the GLES2 renderer" {
    lockGles2ServerTest();
    defer unlockGles2ServerTest();

    const ts = try PolicyServer.initWithRenderer(testing.allocator, .gles2);
    defer ts.deinit();
    const state = ts.state.?;
    const view = ts.viewOf();
    // The selected renderer is the GLES2 one; the cursor's pixman twin is
    // a second, independent object (the cursor's draw path is pixman's).
    try testing.expectEqual(RendererKind.gles2, state.renderer_kind);
    try testing.expect(state.renderer != state.pixman_renderer);

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    ts.renderView(view);
    const base = try ts.baseOf(view);

    // The GLES2 pass really composited: it filled the background and
    // stamped the surface's GL texture through the camera. The surface
    // pixels are the CPU pass's bytes exactly — an opaque texture over
    // the fill — and the fill is the same colour within the shader's
    // mediump rounding (expectFillPixel).
    try testing.expectEqual(surface_bytes, framebufferPixel(base, 10, 10));
    try testing.expectEqual(surface_bytes, framebufferPixel(base, 63, 63));
    try expectFillPixel(framebufferPixel(base, 64, 64));
    try expectFillPixel(framebufferPixel(base, 700, 500));
}

test "the GLES2 canvas pass draws through the camera uniform" {
    lockGles2ServerTest();
    defer unlockGles2ServerTest();

    const ts = try PolicyServer.initWithRenderer(testing.allocator, .gles2);
    defer ts.deinit();
    const view = ts.viewOf();
    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);

    // A zoom-2 camera centred on the world origin: the 64x64 toplevel at
    // world (0,0) belongs on output [400, 528) x [300, 428), exactly what
    // Camera.worldToScreen says for its corners. Without the affine the
    // surface would sit 1:1 at the origin; with a transposed or
    // mis-ordered one the probes below would land outside the image.
    view.camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    ts.renderView(view);
    const base = try ts.baseOf(view);

    try testing.expectEqual(surface_bytes, framebufferPixel(base, 400, 300));
    try testing.expectEqual(surface_bytes, framebufferPixel(base, 527, 427));
    // One output pixel outside the mapped quad, still inside the fill:
    // background, on both sides of the image.
    try expectFillPixel(framebufferPixel(base, 399, 299));
    try expectFillPixel(framebufferPixel(base, 528, 428));
}

// ---------------------------------------------------------------------------
// Buffer-transform parity, wp_viewport crop/scale, camera-aware input and a
// camera far enough out that a world pixel does not fit in an f32.
// ---------------------------------------------------------------------------

/// The wire enum wl_surface.set_buffer_transform takes, re-exported by
/// the generated client bindings as wl_output's Transform.
const wire_transform = client.wl.Output.Transform;

/// The compositor's own Transform for a wire value. The two enums carry
/// the same protocol values (wayland.xml's wl_output.transform), so this
/// is the numeric identity — not a hand-written table that could drift.
fn geomTransform(t: wire_transform) geom.Transform {
    return @fromBackingInt(@intCast(@backingInt(t)));
}

/// Every wl_output.transform in protocol order — the eight standard
/// values a client may commit.
const standard_transforms = [_]wire_transform{
    .normal,
    .@"90",
    .@"180",
    .@"270",
    .flipped,
    .flipped_90,
    .flipped_180,
    .flipped_270,
};

/// The fixture buffer's size: 32x16, deliberately NOT square. A
/// 90-degree buffer transform swaps the surface's width and height, so
/// a non-square fixture makes "was the rotation applied at all?"
/// visible in the surface's drawn footprint as well as in its colours.
const fixture_w: i32 = 32;
const fixture_h: i32 = 16;

/// The fixture's four solid quadrants as premultiplied ARGB8888 memory
/// bytes (B, G, R, A) — the layout both the shm buffer and the
/// composited framebuffer use.
const fixture_red: [4]u8 = .{ 0, 0, 255, 255 };
const fixture_green: [4]u8 = .{ 0, 255, 0, 255 };
const fixture_blue: [4]u8 = .{ 255, 0, 0, 255 };
const fixture_white: [4]u8 = .{ 255, 255, 255, 255 };

/// The fixture colour at buffer texel (x, y).
///
/// Four QUADRANT BLOCKS, not a per-pixel pattern: a block is 16x8
/// texels, so a probe at its centre lands strictly inside it under
/// every sampler this server has (the CPU bilinear loop reads a pixel's
/// top-left corner, pixman and the GLES2 shader read its centre, and a
/// f32 `mediump` add is a third of a unit). The answer therefore never
/// depends on a filter's edge convention, while WHICH block is on
/// screen still separates all eight transforms from one another. The
/// channels are saturated primaries for the same reason: a 0 or a 255
/// survives any of those round trips intact.
fn quadrantFixtureColor(x: i32, y: i32) [4]u8 {
    const right = x >= fixture_w / 2;
    const bottom = y >= fixture_h / 2;
    if (bottom) return if (right) fixture_white else fixture_blue;
    return if (right) fixture_green else fixture_red;
}

/// A memfd holding the four-quadrant fixture. The pattern is written
/// through a private mapping of the same fd the wl_shm pool will mmap,
/// so the server's texture import reads exactly these bytes.
fn quadrantMemfd(name: []const u8) !std.posix.fd_t {
    const size: usize = @as(usize, @intCast(fixture_w)) * @as(usize, @intCast(fixture_h)) * 4;
    const fd = try std.posix.memfd_create(name, std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    const rc = std.os.linux.ftruncate(fd, @intCast(size));
    if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
    const pixels = try std.posix.mmap(
        null,
        size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(pixels);
    var y: i32 = 0;
    while (y < fixture_h) : (y += 1) {
        var x: i32 = 0;
        while (x < fixture_w) : (x += 1) {
            const texel = quadrantFixtureColor(x, y);
            const off = (@as(usize, @intCast(y)) * @as(usize, @intCast(fixture_w)) +
                @as(usize, @intCast(x))) * 4;
            pixels[off + 0] = texel[0];
            pixels[off + 1] = texel[1];
            pixels[off + 2] = texel[2];
            pixels[off + 3] = texel[3];
        }
    }
    return fd;
}

/// The surface-local size a committed transform and scale imply for the
/// fixture buffer, written straight from the wl_surface
/// .set_buffer_transform / .set_buffer_scale definitions: the buffer
/// size transformed (buffer -> surface) and divided by the scale.
fn fixtureSurfaceSize(t: geom.Transform, scale: i32) geom.Size {
    const swaps = t == .@"90" or t == .@"270" or t == .flipped_90 or t == .flipped_270;
    return if (swaps)
        .{ .w = @divTrunc(fixture_h, scale), .h = @divTrunc(fixture_w, scale) }
    else
        .{ .w = @divTrunc(fixture_w, scale), .h = @divTrunc(fixture_h, scale) };
}

/// The buffer texel a surface-local pixel samples under `t`, straight
/// from the wl_output.transform definition (which maps buffer ->
/// surface, so this is its inverse).
///
/// Written here rather than taken from the compositor's matrix helper
/// on purpose: whether the canvas pass honours that definition is
/// exactly what these tests measure, so the expectation must not be
/// computed with the code under test.
fn surfaceTexel(t: geom.Transform, sx: i32, sy: i32) geom.Point {
    return switch (t) {
        .normal => .{ .x = sx, .y = sy },
        .@"90" => .{ .x = sy, .y = fixture_h - 1 - sx },
        .@"180" => .{ .x = fixture_w - 1 - sx, .y = fixture_h - 1 - sy },
        .@"270" => .{ .x = fixture_w - 1 - sy, .y = sx },
        .flipped => .{ .x = fixture_w - 1 - sx, .y = sy },
        .flipped_90 => .{ .x = sy, .y = sx },
        .flipped_180 => .{ .x = sx, .y = fixture_h - 1 - sy },
        .flipped_270 => .{ .x = fixture_w - 1 - sy, .y = fixture_h - 1 - sx },
    };
}

/// The centre of quadrant `q` (0 = top-left, then clockwise) of a
/// surface `size` surface-local pixels across.
fn quadrantCentre(size: geom.Size, q: usize) geom.Point {
    return .{
        .x = if (q % 2 == 0) @divTrunc(size.w, 4) else size.w - @divTrunc(size.w, 4),
        .y = if (q < 2) @divTrunc(size.h, 4) else size.h - @divTrunc(size.h, 4),
    };
}

/// One output-pixel probe: where a surface's `q`-th quadrant centre is
/// displayed through `cam`, and the fixture colour it must be showing.
const Probe = struct {
    x: i32,
    y: i32,
    color: [4]u8,
};

/// The probe for quadrant `q` of a surface carrying `t` at `scale`,
/// whose node sits at world (`origin_x`, `origin_y`).
fn quadrantProbeAt(
    t: geom.Transform,
    scale: i32,
    cam: Camera,
    origin_x: i32,
    origin_y: i32,
    q: usize,
) Probe {
    const centre = quadrantCentre(fixtureSurfaceSize(t, scale), q);
    const world = cam.worldToScreen(
        @as(f64, @floatFromInt(origin_x)) + @as(f64, @floatFromInt(centre.x)),
        @as(f64, @floatFromInt(origin_y)) + @as(f64, @floatFromInt(centre.y)),
    );
    const texel = surfaceTexel(t, centre.x * scale, centre.y * scale);
    return .{
        .x = @intFromFloat(@floor(world.x)),
        .y = @intFromFloat(@floor(world.y)),
        .color = quadrantFixtureColor(texel.x, texel.y),
    };
}

/// The same probe for a surface at the world origin.
fn quadrantProbe(t: geom.Transform, scale: i32, cam: Camera, q: usize) Probe {
    return quadrantProbeAt(t, scale, cam, 0, 0, q);
}

/// The IDENTITY mapping over a `w` x `h` framebuffer: the camera a
/// `.screen` overlay is composited through, so a point at (x, y) is pixel
/// (x, y). Written out here rather than taken from the canvas pass, so a
/// probe against a screen-space item states the policy independently of
/// the code under test.
fn screenProbeCamera(w: i32, h: i32) Camera {
    return .{
        .center_x = @as(f64, @floatFromInt(w)) / 2.0,
        .center_y = @as(f64, @floatFromInt(h)) / 2.0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = @floatFromInt(w),
        .screen_h = @floatFromInt(h),
    };
}

/// The per-channel allowance for a composited pixel: one unit is the
/// GLES2 pass's `mediump` float -> unorm8 rounding (see expectFillPixel)
/// plus the CPU pass's bilinear rounding. The fixture's channels are
/// either 0 or 255, so a channel off by more than that means a
/// DIFFERENT QUADRANT is on screen — never a softened expectation.
const pixel_tolerance: u8 = 1;

/// One client-committed surface state, driven through the wire so the
/// two renderers can be asked for the same thing.
const TransformCase = struct {
    transform: wire_transform = .normal,
    scale: i32 = 1,
    /// wp_viewport.set_source in surface-local pixels (null = unset).
    src: ?[4]i32 = null,
    /// wp_viewport.set_destination (null = unset).
    dst: ?[2]i32 = null,
};

/// Commit `c` on `s` the way a client would: the transform and scale
/// requests, then — when the case names them — a wp_viewport's crop
/// and destination, then the one commit that applies all of it.
fn commitSurfaceState(ts: *PolicyServer, s: *client.wl.Surface, c: TransformCase) !void {
    s.setBufferTransform(c.transform);
    s.setBufferScale(c.scale);
    if (c.src != null or c.dst != null) {
        // wp_viewporter is a separate global from wl_compositor, so the
        // harness's own bind list does not carry it: the case asks the
        // registry for it here, the same roundtrip any other client
        // does. Only ONE wp_viewport may exist per wl_surface
        // (viewporter.xml), which holds because a case names a crop at
        // most once.
        var capture: PolicyGlobalCapture = .{};
        const registry = try ts.readGlobals(&capture);
        const entry = capture.find("wp_viewporter") orelse return error.GlobalMissing;
        const viewporter = try registry.bind(entry.name, client.wp.Viewporter, entry.version);
        try ts.pump();
        const viewport = try viewporter.getViewport(s);
        if (c.src) |src| {
            viewport.setSource(
                client.wl.Fixed.fromInt(@intCast(src[0])),
                client.wl.Fixed.fromInt(@intCast(src[1])),
                client.wl.Fixed.fromInt(@intCast(src[2])),
                client.wl.Fixed.fromInt(@intCast(src[3])),
            );
        }
        if (c.dst) |d| viewport.setDestination(d[0], d[1]);
        try ts.pump();
    }
    s.commit();
    try ts.pump();
    try ts.pumpAcked();
}

/// Present the fixture on `ts` with `c` committed, run ONE REAL frame of
/// the harness's view through `cam`, and return the base framebuffer
/// (owned by the server, valid until it is torn down).
///
/// The frame is the production `renderView` path, not a hand-called
/// composite: placement, damage accumulation and the canvas pass all run
/// exactly as they do on the running server, so the pixels asserted
/// afterwards are the ones it would scan out.
fn compositeFixture(ts: *PolicyServer, c: TransformCase, cam: Camera) !*pixman.Framebuffer {
    const t = try ts.createToplevelWithBuffer(try ts.createFixtureBuffer());
    defer ts.allocator.destroy(t);
    try commitSurfaceState(ts, t.wl_surface, c);
    const view = ts.viewOf();
    view.camera = cam;
    ts.renderView(view);
    return ts.baseOf(view);
}

/// Put a tracked surface's node at world (x, y) — the same f64 placement
/// the shell writes. A client cannot ask for a world position this far
/// out through the move gesture (it starts wherever the pointer is), and
/// large-world placement is precisely what these tests need to set up.
fn placeSurfaceNode(ts: *PolicyServer, surface: *Surface, x: i32, y: i32) void {
    const sn = wayland.surface_node.surfaceNodeFor(ts.scene.?, surface) orelse return;
    const node = sn.node orelse return;
    node.setPosition(@floatFromInt(x), @floatFromInt(y));
}

/// Compare one composited pixel with `want`, `tol` units per channel,
/// naming both on failure so a run says WHICH pixel of WHICH surface
/// was wrong.
fn expectPixelNear(got: [4]u8, want: [4]u8, tol: u8) !void {
    for (0..4) |i| {
        const w = want[i];
        const g = got[i];
        const diff = if (w > g) w - g else g - w;
        testing.expect(diff <= tol) catch |err| {
            std.debug.print(
                "channel {d}: composited {any}, expected {any} (tolerance {d})\n",
                .{ i, got, want, tol },
            );
            return err;
        };
    }
}

/// Drive `c` through the wire on a server of each renderer kind and
/// check that both frames put the fixture's four quadrants on the same
/// output pixels.
///
/// The pixman server is the CPU reference — the canvas pass this
/// compositor has always produced, which samples through a surface's
/// buffer transform. The expectation for WHERE each quadrant lands
/// comes from the protocol (quadrantProbe), not from either renderer,
/// so agreeing with the reference and agreeing with the protocol are
/// two separate things this asserts.
fn expectTransformParity(c: TransformCase, cam: Camera) !void {
    lockGles2ServerTest();
    defer unlockGles2ServerTest();

    const cpu = try PolicyServer.init(testing.allocator);
    defer cpu.deinit();
    const cpu_fb = try compositeFixture(cpu, c, cam);

    const gpu = try PolicyServer.initWithRenderer(testing.allocator, .gles2);
    defer gpu.deinit();
    const gpu_fb = try compositeFixture(gpu, c, cam);

    const t = geomTransform(c.transform);
    for (0..4) |q| {
        const p = quadrantProbe(t, c.scale, cam, q);
        expectPixelNear(framebufferPixel(cpu_fb, p.x, p.y), p.color, pixel_tolerance) catch |err| {
            std.debug.print("CPU frame, transform {s}, scale {d}, quadrant {d}\n", .{
                @tagName(t), c.scale, q,
            });
            return err;
        };
        expectPixelNear(framebufferPixel(gpu_fb, p.x, p.y), p.color, pixel_tolerance) catch |err| {
            std.debug.print("GPU frame, transform {s}, scale {d}, quadrant {d}\n", .{
                @tagName(t), c.scale, q,
            });
            return err;
        };
        // ...and the two frames are the same frame, pixel for pixel,
        // at that same output pixel.
        try expectPixelNear(framebufferPixel(gpu_fb, p.x, p.y), framebufferPixel(cpu_fb, p.x, p.y), pixel_tolerance);
    }
}

/// The transform-parity camera: the world origin at (400, 288) of the
/// 800x600 harness framebuffer, zoom 1, no rotation — so an output
/// pixel names exactly one displayed texel and the parity of the two
/// renderers is not blurred by a resample.
const parity_camera: Camera = .{
    .center_x = 16,
    .center_y = 12,
    .zoom = 1,
    .rotation = 0,
    .screen_w = 800,
    .screen_h = 600,
};

/// Panned, zoomed AND rotated: the camera's own three factors, so a
/// probe only lands on the right texel when the whole world->screen
/// affine is applied — and the buffer transform is still visible
/// through it.
const moved_camera: Camera = .{
    .center_x = 6,
    .center_y = 5,
    .zoom = 1.5,
    .rotation = 0.3,
    .screen_w = 800,
    .screen_h = 600,
};

test "the GLES2 canvas pass draws a client-committed buffer_transform of normal" {
    try expectTransformParity(.{ .transform = .normal }, parity_camera);
}

test "the GLES2 canvas pass draws a client-committed buffer_transform of 90" {
    try expectTransformParity(.{ .transform = .@"90" }, parity_camera);
}

test "the GLES2 canvas pass draws a client-committed buffer_transform of 180" {
    try expectTransformParity(.{ .transform = .@"180" }, parity_camera);
}

test "the GLES2 canvas pass draws a client-committed buffer_transform of 270" {
    try expectTransformParity(.{ .transform = .@"270" }, parity_camera);
}

test "the GLES2 canvas pass draws a client-committed buffer_transform of flipped" {
    try expectTransformParity(.{ .transform = .flipped }, parity_camera);
}

test "the GLES2 canvas pass draws a client-committed buffer_transform of flipped_90" {
    try expectTransformParity(.{ .transform = .flipped_90 }, parity_camera);
}

test "the GLES2 canvas pass draws a client-committed buffer_transform of flipped_180" {
    try expectTransformParity(.{ .transform = .flipped_180 }, parity_camera);
}

test "the GLES2 canvas pass draws a client-committed buffer_transform of flipped_270" {
    try expectTransformParity(.{ .transform = .flipped_270 }, parity_camera);
}

test "a panned, zoomed and rotated camera draws all eight buffer transforms through the GLES2 pass" {
    for (standard_transforms) |t| {
        try expectTransformParity(.{ .transform = t }, moved_camera);
    }
}

test "wl_surface.set_buffer_scale divides the surface and both renderers draw the same quadrants" {
    // The 32x16 fixture at scale 2 is a 16x8 surface: the four quadrants
    // are 8x4, and each still shows its OWN colour, so a pass that
    // ignored the scale would show a different picture, not just a
    // different size.
    try expectTransformParity(.{ .scale = 2 }, parity_camera);

    lockGles2ServerTest();
    defer unlockGles2ServerTest();
    const gpu = try PolicyServer.initWithRenderer(testing.allocator, .gles2);
    defer gpu.deinit();
    const fb = try compositeFixture(gpu, .{ .scale = 2 }, parity_camera);
    // The surface really is 16x8 and no larger: one output pixel past
    // its right edge and one past its bottom edge are the background
    // fill again, not more surface.
    try expectFillPixel(framebufferPixel(fb, 400, 288));
    try expectFillPixel(framebufferPixel(fb, 384, 296));
}

test "wp_viewport.set_source crops the drawn content and set_destination stretches the crop" {
    lockGles2ServerTest();
    defer unlockGles2ServerTest();

    const ts = try PolicyServer.initWithRenderer(testing.allocator, .gles2);
    defer ts.deinit();
    // Crop the fixture's TOP half — buffer columns 8..24, which is the
    // red block and the green one — and scale that 16x8 crop into a
    // 32x32 surface (viewporter.xml: set_source's rectangle is in
    // surface-local coordinates, after the buffer transform and scale;
    // set_destination is the size the surface then takes).
    const src: [4]i32 = .{ 8, 0, 16, 8 };
    const dst: [2]i32 = .{ 32, 32 };
    const fb = try compositeFixture(ts, .{ .src = src, .dst = dst }, parity_camera);

    // parity_camera puts surface-local (sx, sy) on output (sx + 384,
    // sy + 288). Everything the crop covers is the fixture's top half,
    // stretched 2x across and 4x down, so the WHOLE surface is red on
    // its left and green on its right — at every row, including the
    // rows past the buffer's own 16.
    const expect_red = [_][2]i32{ .{ 4, 20 }, .{ 4, 28 }, .{ 12, 30 } };
    for (expect_red) |p| try expectPixelNear(framebufferPixel(fb, p[0] + 384, p[1] + 288), fixture_red, pixel_tolerance);
    const expect_green = [_][2]i32{ .{ 20, 20 }, .{ 20, 28 } };
    for (expect_green) |p| try expectPixelNear(framebufferPixel(fb, p[0] + 384, p[1] + 288), fixture_green, pixel_tolerance);

    // Rows 16..31 of this surface exist ONLY because the destination
    // stretched the crop: an uncropped 32x16 buffer would show the
    // fixture's BOTTOM half (blue, white) down there.
    try expectPixelNear(framebufferPixel(fb, 388, 316), fixture_red, pixel_tolerance);
    try expectPixelNear(framebufferPixel(fb, 404, 316), fixture_green, pixel_tolerance);
}

test "wp_viewport.set_source at buffer_scale 2 crops BUFFER pixels, not surface-local ones" {
    lockGles2ServerTest();
    defer unlockGles2ServerTest();

    const ts = try PolicyServer.initWithRenderer(testing.allocator, .gles2);
    defer ts.deinit();
    // The 32x16 fixture at buffer_scale 2 is a 16x8 SURFACE, so
    // set_source's rectangle is surface-local in a space half the size of
    // the buffer. Two protocol rules are in play and the crop below is
    // chosen to separate them:
    //
    // 1. The source is surface-local, so the buffer crop is the source
    //    MULTIPLIED by the scale: (0, 2, 16, 4) surface-local is
    //    (0, 4, 32, 8) in buffer texels — buffer rows 4..11.
    // 2. With no set_destination, the destination size IS the source
    //    size (viewporter.xml, set_destination: "If this request is not
    //    sent, the destination size will be the source size"), so the
    //    SURFACE is 16x4, not the buffer's 16x8, and the crop is
    //    stretched to fill it.
    //
    // The fixture's own top/bottom boundary is buffer row 8, which inside
    // those eight cropped rows is row 4 of 8 — the exact middle of the
    // surface. A conversion that divided instead of multiplied would
    // crop buffer rows 2..6 and paint the whole surface from the red
    // block; one that ignored the destination rule would leave the
    // surface 16x8 with the crop's rows unstretched.
    const src: [4]i32 = .{ 0, 2, 16, 4 };
    const fb = try compositeFixture(ts, .{ .scale = 2, .src = src }, parity_camera);

    // parity_camera puts surface-local (sx, sy) on output (sx + 384,
    // sy + 288). The crop is stretched 8 buffer rows onto 4 surface
    // rows, so surface rows 0..1 come from buffer rows 4..7 (the
    // fixture's TOP half) and rows 2..3 from buffer rows 8..11 (its
    // BOTTOM half). x = 4 is in the left half of the crop, which is the
    // fixture's red block above the boundary and its blue one below.
    try expectPixelNear(framebufferPixel(fb, 4 + 384, 0 + 288), fixture_red, pixel_tolerance);
    try expectPixelNear(framebufferPixel(fb, 4 + 384, 1 + 288), fixture_red, pixel_tolerance);
    try expectPixelNear(framebufferPixel(fb, 4 + 384, 2 + 288), fixture_blue, pixel_tolerance);
    try expectPixelNear(framebufferPixel(fb, 4 + 384, 3 + 288), fixture_blue, pixel_tolerance);
    // The surface is 16x4 and no larger: past its bottom edge is the fill.
    try expectFillPixel(framebufferPixel(fb, 4 + 384, 4 + 288));
}

test "the seat hit test reports the surface-local coordinate of the pixel the camera displays" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const cam: Camera = .{
        .center_x = 16,
        .center_y = 8,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    const t = try ts.createToplevelWithBuffer(try ts.createFixtureBuffer());
    defer ts.allocator.destroy(t);
    try commitSurfaceState(ts, t.wl_surface, .{});
    const state = ts.state.?;
    const view = ts.viewOf();
    view.camera = cam;
    ts.renderView(view);

    const surface = ts.serverSurface(t.wl_surface);
    // Each quadrant's centre, in surface-local coordinates, taken out
    // to the output pixel that displays it: the hit test on that pixel
    // must name that surface-local point, on that surface.
    for (0..4) |q| {
        const centre = quadrantCentre(fixtureSurfaceSize(.normal, 1), q);
        const world = cam.worldToScreen(@floatFromInt(centre.x), @floatFromInt(centre.y));
        const px: i32 = @intFromFloat(@floor(world.x));
        const py: i32 = @intFromFloat(@floor(world.y));
        const picked = pickSurface(state, px, py) orelse return error.NothingPicked;
        try testing.expectEqual(surface, picked.surface);
        try testing.expectEqual(@as(f64, @floatFromInt(centre.x)), picked.sx);
        try testing.expectEqual(@as(f64, @floatFromInt(centre.y)), picked.sy);
    }
    // One output pixel past the surface's right edge (the 32x16 surface
    // ends at surface-local x = 32) hits nothing at all.
    try testing.expect(pickSurface(state, 448, 284) == null);
}

test "the hit test's surface-local coordinates name the pixel a 90-degree buffer displays" {
    lockGles2ServerTest();
    defer unlockGles2ServerTest();

    const ts = try PolicyServer.initWithRenderer(testing.allocator, .gles2);
    defer ts.deinit();
    const cam: Camera = .{
        .center_x = 8,
        .center_y = 16,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    const t = try ts.createToplevelWithBuffer(try ts.createFixtureBuffer());
    defer ts.allocator.destroy(t);
    try commitSurfaceState(ts, t.wl_surface, .{ .transform = .@"90" });
    const state = ts.state.?;
    const view = ts.viewOf();
    view.camera = cam;
    ts.renderView(view);

    // The 90-degree transform makes the surface 16 wide and 32 high,
    // and surface-local (4, 8) displays buffer texel (8, 11) — the
    // fixture's BLUE quadrant. So the pixel the camera puts there must
    // BE blue: the delivered surface-local coordinate and the pixel
    // under the pointer are the same statement about the same place.
    const world = cam.worldToScreen(4, 8);
    const px: i32 = @intFromFloat(@floor(world.x));
    const py: i32 = @intFromFloat(@floor(world.y));
    const picked = pickSurface(state, px, py) orelse return error.NothingPicked;
    try testing.expectEqual(ts.serverSurface(t.wl_surface), picked.surface);
    try testing.expectEqual(@as(f64, 4), picked.sx);
    try testing.expectEqual(@as(f64, 8), picked.sy);
    try expectPixelNear(framebufferPixel(try ts.baseOf(view), px, py), fixture_blue, pixel_tolerance);
}

/// A surface node a billion world pixels out. The offset is not a round
/// number of 64, so an f32 cannot represent it back.
const distant_origin_x: i32 = 1_000_000_000;
const distant_origin_y: i32 = 1_000_000_037;

/// A camera centred on that world position, with a FRACTIONAL centre:
/// at 1e9 an f32's spacing is 64, so any path that narrows an absolute
/// world coordinate to f32 before the camera origin is subtracted puts
/// the surface tens of pixels from where Camera.worldToScreen says —
/// while the f64 camera itself still resolves a unit step exactly.
const distant_camera: Camera = .{
    .center_x = 1_000_000_008.5,
    .center_y = 1_000_000_041.25,
    .zoom = 1,
    .rotation = 0,
    .screen_w = 800,
    .screen_h = 600,
};

/// Run ONE REAL frame with the fixture on a surface placed at
/// (distant_origin_x, distant_origin_y) through `distant_camera`, and
/// return that view's base framebuffer.
fn compositeDistantFixture(ts: *PolicyServer) !*pixman.Framebuffer {
    const t = try ts.createToplevelWithBuffer(try ts.createFixtureBuffer());
    defer ts.allocator.destroy(t);
    placeSurfaceNode(ts, ts.serverSurface(t.wl_surface), distant_origin_x, distant_origin_y);
    const view = ts.viewOf();
    view.camera = distant_camera;
    ts.renderView(view);
    return ts.baseOf(view);
}

test "the CPU canvas pass keeps a distant surface's local geometry" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const fb = try compositeDistantFixture(ts);
    for (0..4) |q| {
        const p = quadrantProbeAt(.normal, 1, distant_camera, distant_origin_x, distant_origin_y, q);
        try expectPixelNear(framebufferPixel(fb, p.x, p.y), p.color, pixel_tolerance);
    }
}

test "the GLES2 canvas pass keeps a distant surface's local geometry" {
    lockGles2ServerTest();
    defer unlockGles2ServerTest();
    const ts = try PolicyServer.initWithRenderer(testing.allocator, .gles2);
    defer ts.deinit();
    const fb = try compositeDistantFixture(ts);
    for (0..4) |q| {
        const p = quadrantProbeAt(.normal, 1, distant_camera, distant_origin_x, distant_origin_y, q);
        try expectPixelNear(framebufferPixel(fb, p.x, p.y), p.color, pixel_tolerance);
    }
}

// ---------------------------------------------------------------------------
// Two simultaneous outputs. Every view here is built by the production
// factory and driven by the production frame path, so what these tests
// read is what each output would really scan out and really answer to a
// pointer with.
// ---------------------------------------------------------------------------

/// The DESKTOP pixel that displays world (wx, wy) on `view`: that view's
/// own camera, then its own column of the desktop layout.
fn desktopPixelOf(view: *const OutputView, wx: f64, wy: f64) geom.Point {
    const local = view.camera.worldToScreen(wx, wy);
    return .{
        .x = view.rect.x + @as(i32, @intFromFloat(@floor(local.x))),
        .y = view.rect.y + @as(i32, @intFromFloat(@floor(local.y))),
    };
}

test "one client surface is drawn and picked through both outputs' own cameras" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const state = ts.state.?;
    const first = ts.viewOf();
    const second = try ts.addSecondOutput(800, 600);

    // The layout the production factory produced: the second connector is
    // the second column of the desktop, and scene space IS the desktop.
    try testing.expectEqual(geom.Rect{ .x = 0, .y = 0, .width = 800, .height = 600 }, first.rect);
    try testing.expectEqual(geom.Rect{ .x = 800, .y = 0, .width = 800, .height = 600 }, second.rect);

    // ONE regular client surface — a plain xdg_toplevel, no layer, popup,
    // cursor or drag role — mapped while the pointer is over output 1.
    ts.seat.?.pointerMotion(100, 100);
    const client_toplevel = try ts.createToplevelWithBuffer(try ts.createFixtureBuffer());
    defer ts.allocator.destroy(client_toplevel);
    ts.renderView(first);
    const client_surface = ts.serverSurface(client_toplevel.wl_surface);

    // Both cameras look at the SAME world rect — output 1 zoomed in on the
    // surface, output 2 not — so the two canvases must show it at two
    // different places. Placement says which output a surface BELONGS to;
    // it does not decide which cameras may see it, and a camera whose
    // visible world rect contains the surface has to draw it.
    first.camera = .{
        .center_x = 16,
        .center_y = 8,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    second.camera = .{
        .center_x = 100,
        .center_y = 100,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    ts.renderView(first);
    ts.renderView(second);

    for (0..4) |q| {
        const on_first = quadrantProbeAt(.normal, 1, first.camera, 0, 0, q);
        try expectPixelNear(
            framebufferPixel(try ts.baseOf(first), on_first.x, on_first.y),
            on_first.color,
            pixel_tolerance,
        );
        const on_second = quadrantProbeAt(.normal, 1, second.camera, 0, 0, q);
        try expectPixelNear(
            framebufferPixel(try ts.baseOf(second), on_second.x, on_second.y),
            on_second.color,
            pixel_tolerance,
        );
    }
    // A pixel past each camera's own image of the surface is background on
    // that output: the two cameras really do put it somewhere different.
    try expectFillPixel(framebufferPixel(try ts.baseOf(first), 384, 260));
    try expectFillPixel(framebufferPixel(try ts.baseOf(second), 308, 170));

    // The pointer asks at the desktop pixel each output DISPLAYS the same
    // surface-local point at, and both answer with that surface-local
    // point on the same surface. A pick that inverted the other output's
    // camera would land on a different world point and hit nothing.
    for ([_][2]i32{ .{ 8, 4 }, .{ 24, 12 } }) |l| {
        const px: f64 = @floatFromInt(l[0]);
        const py: f64 = @floatFromInt(l[1]);

        const at_first = desktopPixelOf(first, px, py);
        const pick_first = pickSurface(state, at_first.x, at_first.y) orelse return error.NothingPickedOnFirst;
        try testing.expectEqual(client_surface, pick_first.surface);
        try testing.expectEqual(px, pick_first.sx);
        try testing.expectEqual(py, pick_first.sy);

        const at_second = desktopPixelOf(second, px, py);
        try testing.expect(at_second.x >= second.rect.x);
        try testing.expect(at_first.x != at_second.x);
        const pick_second = pickSurface(state, at_second.x, at_second.y) orelse return error.NothingPickedOnSecond;
        try testing.expectEqual(client_surface, pick_second.surface);
        try testing.expectEqual(px, pick_second.sx);
        try testing.expectEqual(py, pick_second.sy);
    }
    // A desktop pixel no camera shows the surface on hits nothing, and the
    // hit test never reaches across the columns.
    try testing.expect(pickSurface(state, 700, 550) == null);
    try testing.expect(pickSurface(state, second.rect.x + 700, 550) == null);

    // Camera B pans and camera A does not: output A still shows the
    // fixture exactly where ITS camera puts it. (Asserted per quadrant
    // through A's own camera rather than by comparing whole framebuffers:
    // the probe states what the output must show, the byte compare only
    // that nothing changed.)
    second.camera.center_x = 300;
    ts.renderView(first);
    ts.renderView(second);
    try testing.expectEqual(@as(f64, 16), first.camera.center_x);
    for (0..4) |q| {
        const kept = quadrantProbeAt(.normal, 1, first.camera, 0, 0, q);
        try expectPixelNear(
            framebufferPixel(try ts.baseOf(first), kept.x, kept.y),
            kept.color,
            pixel_tolerance,
        );
    }
    // Output B shows the same surface at its NEW place, and background
    // where it used to be.
    for (0..4) |q| {
        const moved = quadrantProbeAt(.normal, 1, second.camera, 0, 0, q);
        try expectPixelNear(
            framebufferPixel(try ts.baseOf(second), moved.x, moved.y),
            moved.color,
            pixel_tolerance,
        );
    }
    try expectFillPixel(framebufferPixel(try ts.baseOf(second), 308, 204));

    // Camera A pans off the surface entirely: output A shows background
    // where the fixture used to be, the pointer no longer finds it there,
    // and output B is still showing the same four quadrants through its
    // own, unmoved camera.
    first.camera.center_x = 900;
    ts.renderView(first);
    ts.renderView(second);
    try expectFillPixel(framebufferPixel(try ts.baseOf(first), 384, 292));
    try expectFillPixel(framebufferPixel(try ts.baseOf(first), 416, 308));
    try testing.expect(pickSurface(state, 384, 292) == null);
    for (0..4) |q| {
        const b = quadrantProbeAt(.normal, 1, second.camera, 0, 0, q);
        try expectPixelNear(
            framebufferPixel(try ts.baseOf(second), b.x, b.y),
            b.color,
            pixel_tolerance,
        );
    }
    // Output B still answers with the same surface-local point.
    const still = desktopPixelOf(second, 8, 4);
    const pick_still = pickSurface(state, still.x, still.y) orelse return error.NothingPickedOnSecond;
    try testing.expectEqual(client_surface, pick_still.surface);
    try testing.expectEqual(@as(f64, 8), pick_still.sx);
    try testing.expectEqual(@as(f64, 4), pick_still.sy);
}

test "an unplugged output leaves the survivor's canvas, camera and input alone" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const state = ts.state.?;
    const first = ts.viewOf();

    ts.seat.?.pointerMotion(100, 100);
    const survivor = try ts.createToplevelWithBuffer(try ts.createFixtureBuffer());
    defer ts.allocator.destroy(survivor);
    ts.renderView(first);
    const survivor_surface = ts.serverSurface(survivor.wl_surface);

    const second = try ts.addSecondOutput(800, 600);
    const second_out = second.output;
    ts.renderView(second);
    ts.renderView(first);

    // A camera of the survivor's own, recorded so the unplug can be shown
    // not to have touched it.
    first.camera = .{
        .center_x = 16,
        .center_y = 8,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    ts.renderView(first);
    const kept_rect = first.rect;
    const kept_camera = first.camera;
    // The survivor sits at the desktop origin, so its local pixel IS the
    // desktop pixel here.
    const probe = quadrantProbeAt(.normal, 1, kept_camera, 0, 0, 0);
    try expectPixelNear(framebufferPixel(try ts.baseOf(first), probe.x, probe.y), probe.color, pixel_tolerance);

    // The connector is unplugged: the production destroy handler runs.
    ts.seat.?.pointerMotion(100, 100);
    ts.removeOutput(second_out);

    try testing.expectEqual(@as(usize, 1), state.output_views.items.len);
    try testing.expect(state.output_views.items[0] == first);
    try testing.expectEqual(kept_rect, first.rect);
    try testing.expectEqual(kept_camera, first.camera);
    // The survivor's contents survive untouched — the same pixels, from
    // the very same base framebuffer, with nothing composited in between.
    try expectPixelNear(framebufferPixel(try ts.baseOf(first), probe.x, probe.y), probe.color, pixel_tolerance);
    // And it still composites, and still routes input, on its own.
    ts.renderView(first);
    try expectPixelNear(framebufferPixel(try ts.baseOf(first), probe.x, probe.y), probe.color, pixel_tolerance);
    const picked = pickSurface(state, probe.x, probe.y) orelse return error.NothingPicked;
    try testing.expectEqual(survivor_surface, picked.surface);

    // The connector comes back: a new view at the right edge of the
    // layout, with a camera of its own, drawing its own client surface.
    const again = try ts.addSecondOutput(800, 600);
    try testing.expectEqual(@as(usize, 2), state.output_views.items.len);
    try testing.expectEqual(@as(i32, 800), again.rect.x);
    ts.seat.?.pointerMotion(900, 100);
    const replugged = try ts.createToplevelWithBuffer(try ts.createBuffer());
    defer ts.allocator.destroy(replugged);
    ts.renderView(again);
    // The re-added output's camera is the identity over its own column, so
    // the new surface's top-left corner is its local origin.
    try testing.expectEqual(surface_bytes, framebufferPixel(try ts.baseOf(again), 10, 10));
    // ...and the survivor is still exactly what it was.
    try testing.expectEqual(kept_camera, first.camera);
    try expectPixelNear(framebufferPixel(try ts.baseOf(first), probe.x, probe.y), probe.color, pixel_tolerance);
}

test "framing one output advances only that output's damage and pacing" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const first = ts.viewOf();
    const second = try ts.addSecondOutput(800, 600);

    ts.seat.?.pointerMotion(900, 100);
    const t = try ts.createToplevelWithBuffer(try ts.createBuffer());
    defer ts.allocator.destroy(t);
    ts.renderView(second);

    // Nothing about the second output's frame may reach the first one's
    // damage: that is checked below through the public takeDamage() the
    // present path reads, never through the ring's private arrays.

    // The production frame entry point, on the FIRST output only, after a
    // camera move: the whole-output invalidation belongs to that output.
    first.camera.center_x = 380;
    renderFrame(first);

    try testing.expectEqual(@as(u32, 1), first.frames_rendered);
    try testing.expectEqual(@as(u32, 0), second.frames_rendered);
    try testing.expect(!first.repaint_pending);
    try testing.expect(second.repaint_pending);

    // The damage this frame reported is in the FIRST output's own pixel
    // space, and it is the whole of that output — never desktop
    // coordinates, never a rect belonging to the other column.
    const frame_damage = first.scene_output.takeDamage();
    try testing.expect(frame_damage.len > 0);
    var whole_output = false;
    for (frame_damage) |r| {
        try testing.expect(r.x >= 0 and r.y >= 0);
        try testing.expect(r.x + r.width <= first.rect.width);
        try testing.expect(r.y + r.height <= first.rect.height);
        if (r.width == first.rect.width and r.height == first.rect.height) whole_output = true;
    }
    try testing.expect(whole_output);
    // The other output advances on its own: framing it produces ITS own
    // whole-output damage, in ITS pixel space, and leaves the first
    // output's frame count where it was.
    second.camera.center_x = 380;
    renderFrame(second);
    try testing.expectEqual(@as(u32, 1), first.frames_rendered);
    var second_whole = false;
    for (second.scene_output.takeDamage()) |r| {
        try testing.expect(r.x >= 0 and r.y >= 0);
        try testing.expect(r.x + r.width <= second.rect.width);
        try testing.expect(r.y + r.height <= second.rect.height);
        if (r.width == second.rect.width and r.height == second.rect.height) second_whole = true;
    }
    try testing.expect(second_whole);
}

test "the drag icon is a pointer-anchored screen overlay under any camera" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const view = ts.viewOf();

    const origin = try ts.createToplevel();
    defer ts.allocator.destroy(origin);
    ts.pick_surface = ts.serverSurface(origin.wl_surface);

    // An ASYMMETRIC drag icon — the four-quadrant fixture — so a pixel says
    // which quadrant of the icon is on screen and where. A uniform icon
    // looks the same wherever it lands, which is the only thing in
    // question here.
    ts.seat.?.pointerMotion(400, 300);
    ts.seat.?.pointerButton(wayland.seat.btn_left, true);
    try ts.pump();
    const device = try ts.ddm.?.getDataDevice(ts.wl_seat.?);
    const source = try ts.ddm.?.createDataSource();
    source.offer("text/plain");
    const icon_wl_surface = try ts.wl_compositor.?.createSurface();
    try ts.pump();
    icon_wl_surface.attach(try ts.createFixtureBuffer(), 0, 0);
    icon_wl_surface.commit();
    try ts.pump();
    device.startDrag(source, origin.wl_surface, icon_wl_surface, ts.seat.?.last_serial);
    try ts.pump();
    syncSurfaces(ts.state.?);

    // A zoom-2 camera centred on the pointer. A drag icon is a CURSOR,
    // not a window: it is composited in the output's own pixels at its
    // logical size, so this camera must not scale it or slide it. The
    // expectation is therefore read through the IDENTITY mapping over the
    // framebuffer (screenProbeCamera) — a point at (x, y) is pixel (x, y)
    // — which is the policy under test and not the code under it.
    view.camera = .{
        .center_x = 400,
        .center_y = 300,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    const screen = screenProbeCamera(800, 600);
    ts.renderView(view);
    // The pointer is at the output-local pixel (400, 300), so the icon
    // covers (400..432, 300..316) at 1:1.
    for (0..4) |q| {
        const p = quadrantProbeAt(.normal, 1, screen, 400, 300, q);
        try expectPixelNear(framebufferPixel(try ts.baseOf(view), p.x, p.y), p.color, pixel_tolerance);
    }
    // ...and only there: one pixel left of it and one row below it are
    // background, so the icon is neither scaled to 64x32 nor stretched
    // over the canvas.
    try expectFillPixel(framebufferPixel(try ts.baseOf(view), 399, 300));
    try expectFillPixel(framebufferPixel(try ts.baseOf(view), 400, 316));

    // The pointer moves: the icon follows it, and the place it left is
    // background again.
    ts.seat.?.pointerMotion(500, 300);
    ts.renderView(view);
    for (0..4) |q| {
        const p = quadrantProbeAt(.normal, 1, screen, 500, 300, q);
        try expectPixelNear(framebufferPixel(try ts.baseOf(view), p.x, p.y), p.color, pixel_tolerance);
    }
    try expectFillPixel(framebufferPixel(try ts.baseOf(view), 416, 308));

    // The drag ends, so the icon is not on the canvas any more: the
    // pixels it covered are background again.
    ts.seat.?.pointerButton(wayland.seat.btn_left, false);
    try ts.pump();
    try testing.expect(ts.data_device.?.currentDragIcon() == null);
    ts.renderView(view);
    try expectFillPixel(framebufferPixel(try ts.baseOf(view), 508, 308));
}

test "the lock screen covers its output and takes fixed input under a nonidentity camera" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const state = ts.state.?;
    const view = ts.viewOf();

    // A camera that is NOT the identity: a 100 px pan puts the world's
    // left edge 100 px off this output and its right edge 100 px past the
    // far side. A surface that has to COVER the output is output-local by
    // definition; drawing it through the canvas camera slides it and
    // leaves the lock fill showing at an edge.
    view.camera = .{
        .center_x = 500,
        .center_y = 300,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };

    var lock_events: LockClientEvents = .{};
    var lock_surface_events: LockSurfaceClientEvents = .{};
    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const entry = capture.find("ext_session_lock_manager_v1") orelse return error.GlobalMissing;
    const manager = try registry.bind(entry.name, client.ext.SessionLockManagerV1, entry.version);
    try ts.pump();
    const lock = try manager.lock();
    lock.setListener(*LockClientEvents, LockClientEvents.listener, &lock_events);
    const lock_wl_surface = try ts.wl_compositor.?.createSurface();
    const lock_surface = try lock.getLockSurface(lock_wl_surface, ts.wl_output_client.?);
    lock_surface.setListener(*LockSurfaceClientEvents, LockSurfaceClientEvents.listener, &lock_surface_events);
    try ts.pump();
    lock_surface.ackConfigure(lock_surface_events.serial);
    // A full-size ASYMMETRIC lock screen — dark gray left half, light gray
    // right half — so WHERE it covers the output is observable, not just
    // that something opaque is there.
    lock_wl_surface.attach(try ts.createSplitBuffer(800, 600, 0x20, 0xE0), 0, 0);
    lock_wl_surface.commit();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), lock_events.locked);
    try testing.expectEqual(
        LockedFrame{ .locked = true, .blank = false, .cursor_hidden = true },
        lockedFrameFor(state, view.output),
    );

    ts.renderView(view);
    const base = try ts.baseOf(view);

    // The split sits at the OUTPUT's own middle...
    try expectPixelNear(framebufferPixel(base, 10, 10), grayBytes(0x20), pixel_tolerance);
    try expectPixelNear(framebufferPixel(base, 399, 300), grayBytes(0x20), pixel_tolerance);
    try expectPixelNear(framebufferPixel(base, 400, 300), grayBytes(0xE0), pixel_tolerance);
    // ...and the far corner is lock content, not the lock fill showing
    // through a lock screen that was drawn through the canvas camera.
    try expectPixelNear(framebufferPixel(base, 790, 590), grayBytes(0xE0), pixel_tolerance);

    // Input is FIXED: a pointer at the output's own corner names that
    // output-local pixel on the lock surface, with no camera scaling.
    const far = pickSurface(state, 790, 590) orelse return error.LockSurfaceNotPicked;
    try testing.expectEqual(ts.serverSurface(lock_wl_surface), far.surface);
    try testing.expectEqual(@as(f64, 790), far.sx);
    try testing.expectEqual(@as(f64, 590), far.sy);
}

/// The client's zwlr_layer_surface_v1 events. libwayland aborts on an event
/// with no listener, and a layer surface may not attach a buffer before its
/// configure is acked (layer-shell.xml, already_constructed), so a test
/// that maps one needs the serial.
const ClientLayerSurfaceEvents = struct {
    serial: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    configures: usize = 0,

    fn listener(
        _: *client.zwlr.LayerSurfaceV1,
        event: client.zwlr.LayerSurfaceV1.Event,
        self: *ClientLayerSurfaceEvents,
    ) void {
        switch (event) {
            .configure => |c| {
                self.configures += 1;
                self.serial = c.serial;
                self.width = c.width;
                self.height = c.height;
            },
            .closed => {},
        }
    }
};

// An overlay's child keeps its offset and stays in that output's own
// pixels, membership and presentation under a rotated world camera.
// Its asymmetric colours distinguish that placement from a world draw.
test "a subsurface of a layer surface keeps its offset, stays on that output and is not world-pickable" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const state = ts.state.?;
    const view = ts.viewOf();

    // Centred on the child's own world origin (the layer surface's tree is
    // at the output's desktop origin, so the child's world rect is
    // (16, 8, 32, 16) once its offset is applied) and rotated off axis.
    view.camera = .{
        .center_x = 16,
        .center_y = 8,
        .zoom = 1,
        .rotation = 0.3,
        .screen_w = 800,
        .screen_h = 600,
    };

    // A 64x48 panel on THIS output: dark grey on the left half, light on
    // the right, so the layer's own pixels are distinguishable from both
    // the background fill and the fixture's quadrants.
    const layer_wl = try ts.wl_compositor.?.createSurface();
    try ts.pump();
    const layer_surface = try ts.layer_shell_client.?.getLayerSurface(
        layer_wl,
        ts.wl_output_client.?,
        .top,
        "overlay",
    );
    var layer_events: ClientLayerSurfaceEvents = .{};
    layer_surface.setListener(*ClientLayerSurfaceEvents, ClientLayerSurfaceEvents.listener, &layer_events);
    // Top-left anchoring places the panel at this output's own origin.
    layer_surface.setAnchor(@bitCast(@as(u32, 1 | 4)));
    layer_surface.setSize(64, 48);
    try ts.pump();
    // The first commit is buffer-less; that is what draws the arrange's
    // configure the client acks.
    layer_wl.commit();
    try ts.pump();
    layer_surface.ackConfigure(layer_events.serial);
    try ts.pump();

    // The child, offset 16,8 INSIDE the panel. set_position is applied when
    // the PARENT commits (wl_subsurface.set_position: "double-buffered
    // state on the parent surface"), so the panel's buffer commit below is
    // what moves the child.
    const child_wl = try ts.wl_compositor.?.createSurface();
    try ts.pump();
    var capture: PolicyGlobalCapture = .{};
    const registry = try ts.readGlobals(&capture);
    const subco_entry = capture.find("wl_subcompositor") orelse return error.GlobalMissing;
    const subco = try registry.bind(subco_entry.name, client.wl.Subcompositor, subco_entry.version);
    try ts.pump();
    // wl_subcompositor.get_subsurface takes no placement argument: the
    // generated binding is get_subsurface(surface, parent), and stacking
    // is the separate wl_subsurface.place_above / place_below request.
    const subsurface = try subco.getSubsurface(child_wl, layer_wl);
    subsurface.setPosition(16, 8);
    try ts.pump();

    layer_wl.attach(try ts.createSplitBuffer(64, 48, 0x20, 0xE0), 0, 0);
    layer_wl.commit();
    try ts.pump();
    child_wl.attach(try ts.createFixtureBuffer(), 0, 0);
    child_wl.commit();
    // Default subsurfaces are synchronized; the parent applies the
    // child's cached buffer state on its next commit.
    layer_wl.commit();
    try ts.pump();
    syncSurfaces(state);

    const layer_surface_ptr = ts.serverSurface(layer_wl);
    const child_surface = ts.serverSurface(child_wl);
    try testing.expect(layer_surface_ptr != child_surface);

    ts.renderView(view);
    const base = try ts.baseOf(view);
    const screen = screenProbeCamera(800, 600);

    // 1. RENDERING: the child is at the panel's origin plus the client's
    //    offset, in this output's own pixels, at its logical 32x16.
    for (0..4) |q| {
        const p = quadrantProbeAt(.normal, 1, screen, 16, 8, q);
        expectPixelNear(framebufferPixel(base, p.x, p.y), p.color, pixel_tolerance) catch |err| {
            std.debug.print("child quadrant {d} at ({d},{d})\n", .{ q, p.x, p.y });
            return err;
        };
    }
    // The panel's own pixels survive around the child: one inside its left
    // half and one inside its right half, both clear of the child.
    try expectPixelNear(framebufferPixel(base, 8, 8), grayBytes(0x20), pixel_tolerance);
    try expectPixelNear(framebufferPixel(base, 56, 40), grayBytes(0xE0), pixel_tolerance);
    // ...and the child was NOT also drawn through the camera. The camera
    // is centred on the child's own world origin, so the world projection
    // of the child's rect STARTS at this output's centre — the probe has
    // to be the middle of that projected quad, not its corner, or it
    // lands on the same child pixels the screen-space draw already put
    // there. (32, 16) is the child's world centre; the camera puts it
    // ~(410, 312), far outside the (16, 8, 32, 16) rect the screen pass
    // drew, so a fill there means the camera never drew it.
    const world_draw = view.camera.worldToScreen(32, 16);
    const draw_px: i32 = @intFromFloat(@floor(world_draw.x));
    const draw_py: i32 = @intFromFloat(@floor(world_draw.y));
    try testing.expect(draw_px > 48 or draw_py > 24);
    try expectFillPixel(framebufferPixel(base, draw_px, draw_py));

    // 2. PICKING: the scene tree really does hold the child at the world
    //    point the camera displays, and the compositor's hit test still
    //    refuses it there — an output-local descendant is not world
    //    content.
    const child_node = wayland.surface_node.surfaceNodeFor(ts.scene.?, child_surface).?.node.?;
    const world_probe = view.camera.worldToScreen(24, 12);
    const world_px: i32 = @intFromFloat(@floor(world_probe.x));
    const world_py: i32 = @intFromFloat(@floor(world_probe.y));
    const scene_hit = ts.scene.?.pick(24, 12) orelse return error.ChildNotInScene;
    try testing.expectEqual(child_node, scene_hit);
    try testing.expect(pickSurface(state, world_px, world_py) == null);
    // The panel itself is hit in its OWN pixels: the pointer there never
    // travels through a camera either.
    const panel_hit = pickSurface(state, 8, 8) orelse return error.PanelNotPicked;
    try testing.expectEqual(layer_surface_ptr, panel_hit.surface);
    try testing.expectEqual(@as(f64, 8), panel_hit.sx);
    try testing.expectEqual(@as(f64, 8), panel_hit.sy);

    // ...and the DESCENDANT is the topmost thing at its OWN pixels: the
    // pointer at the screen-local (24, 12) is inside the child's
    // (16, 8, 32, 16) rect and inside the panel's 64x48, and the child is
    // drawn over the panel, so the child is what the client must be told
    // — with the offset inside the CHILD, never inside the panel it is
    // composited with. The panel's own pixels outside the child still
    // name the panel (8, 8 above), so this is stacking, not a subtree
    // hit test answering for its parent.
    const child_hit = pickSurface(state, 24, 12) orelse return error.ChildNotPicked;
    try testing.expectEqual(child_surface, child_hit.surface);
    try testing.expectEqual(@as(f64, 8), child_hit.sx);
    try testing.expectEqual(@as(f64, 4), child_hit.sy);

    // 3. MEMBERSHIP: the child is presented on the overlay's output, and
    //    on no other one.
    const other = try ts.addSecondOutput(800, 600);
    ts.renderView(view);
    ts.renderView(other);
    var pinned = false;
    for (view.scene_output.presented.items) |s| {
        if (s == child_surface) pinned = true;
    }
    try testing.expect(pinned);
    for (other.scene_output.presented.items) |s| {
        try testing.expect(s != child_surface);
        try testing.expect(s != layer_surface_ptr);
    }
    // ...and the same offset on the OTHER output resolves to nothing: the
    // per-output pin draws and hits the child on the overlay's output
    // alone, and the world pass refuses it wherever it sits in world
    // space, so a pointer on a second connector never lands on it.
    try testing.expect(pickSurface(state, other.rect.x + 24, other.rect.y + 12) == null);
}

test "a fractional cursor footprint reaches the hover restore whole, on whichever output the pointer is on" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const view = ts.viewOf();
    const out = OutputView.localRect(view);

    // Cursor.footprints reports f64 WORLD rects, so a cursor whose world
    // position carries a fraction reaches the restore with it. The origin
    // floors and the far edges ceil: the restore covers EVERY pixel the
    // footprint touched, so no row or column of the old cursor survives
    // the move.
    const fractional: geom.FRect = .{ .x = 10.25, .y = 20.75, .width = 4, .height = 3 };
    try testing.expectEqual(
        geom.Rect{ .x = 10, .y = 20, .width = 5, .height = 4 },
        localRectOf(view, fractional),
    );

    // A footprint running off the output is cut AT the edge, in f64: the
    // covered pixels are the ones the output really had.
    try testing.expectEqual(
        geom.Rect{ .x = out.width - 3, .y = 0, .width = 3, .height = 2 },
        localRectOf(view, .{
            .x = @as(f64, @floatFromInt(out.width)) - 2.5,
            .y = 0,
            .width = 5,
            .height = 2,
        }),
    );

    // A world footprint a billion pixels out is not on this output and
    // contributes NOTHING — no rect at all, not a strip on the near edge.
    try testing.expectEqual(geom.Rect.empty(), localRectOf(view, .{
        .x = 1_000_000_000.25,
        .y = 1_000_000_000.75,
        .width = 8,
        .height = 8,
    }));

    // Footprints are DESKTOP coords. The same surface-local footprint on a
    // SECOND connector lands at the same output-local rect there, because
    // the shift is that view's own layout origin and not the origin of
    // whichever view happens to be first.
    const second = try ts.addSecondOutput(800, 600);
    try testing.expectEqual(
        geom.Rect{ .x = 10, .y = 20, .width = 5, .height = 4 },
        localRectOf(second, .{
            .x = @as(f64, @floatFromInt(second.rect.x)) + fractional.x,
            .y = @as(f64, @floatFromInt(second.rect.y)) + fractional.y,
            .width = fractional.width,
            .height = fractional.height,
        }),
    );
}

test "an interactive move keeps a fractional world position a billion pixels out" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const state = ts.state.?;
    const seat = ts.seat.?;
    const view = ts.viewOf();

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    ts.pick_surface = ts.serverSurface(t.wl_surface);
    // The node a billion world pixels out. At 1e9 an f32's spacing is 64,
    // so this position and its halves cannot survive any narrowing to f32
    // or any rounding of the drag delta.
    placeSurfaceNode(ts, ts.serverSurface(t.wl_surface), distant_origin_x, distant_origin_y);
    // Zoom 2 makes one pointer pixel exactly half a world pixel.
    view.camera = .{
        .center_x = 400,
        .center_y = 300,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };

    seat.pointerMotion(400, 300);
    try ts.pump();
    t.toplevel.move(ts.wl_seat.?, seat.serialFor(ts.client.?));
    try ts.pump();
    try testing.expect(state.gestures.moving_toplevel != null);

    const node = wayland.surface_node.surfaceNodeFor(ts.scene.?, ts.serverSurface(t.wl_surface)).?.node.?;
    // One pointer pixel at zoom 2 is half a world pixel, applied exactly.
    seat.pointerMotion(401, 300);
    try ts.pump();
    try testing.expectEqual(@as(f64, @floatFromInt(distant_origin_x)) + 0.5, node.x);
    try testing.expectEqual(@as(f64, @floatFromInt(distant_origin_y)), node.y);
    // Three pointer pixels across and one down: +1.5 and +0.5 world
    // pixels, still exact.
    seat.pointerMotion(403, 301);
    try ts.pump();
    try testing.expectEqual(@as(f64, @floatFromInt(distant_origin_x)) + 1.5, node.x);
    try testing.expectEqual(@as(f64, @floatFromInt(distant_origin_y)) + 0.5, node.y);
}

test "overlapping client pixels and pointer focus follow scene tree stacking" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const first = try ts.createToplevelWithBuffer(try ts.createSplitBuffer(32, 16, 0x20, 0x20));
    defer ts.allocator.destroy(first);
    const second = try ts.createToplevelWithBuffer(try ts.createSplitBuffer(32, 16, 0xE0, 0xE0));
    defer ts.allocator.destroy(second);
    const view = ts.viewOf();
    ts.renderView(view);
    const scene = ts.scene.?;
    const first_surface = ts.serverSurface(first.wl_surface);
    const second_surface = ts.serverSurface(second.wl_surface);
    const first_tree = wayland.surface_node.surfaceNodeFor(scene, first_surface).?.tree.?;
    const second_tree = wayland.surface_node.surfaceNodeFor(scene, second_surface).?.tree.?;

    try scene.root.appendChild(ts.allocator, first_tree);
    ts.renderView(view);
    try expectPixelNear(framebufferPixel(try ts.baseOf(view), 8, 4), grayBytes(0x20), pixel_tolerance);
    const first_pick = pickSurface(ts.state.?, 8, 4) orelse return error.NothingPicked;
    try testing.expectEqual(first_surface, first_pick.surface);

    try scene.root.appendChild(ts.allocator, second_tree);
    ts.renderView(view);
    try expectPixelNear(framebufferPixel(try ts.baseOf(view), 8, 4), grayBytes(0xE0), pixel_tolerance);
    const second_pick = pickSurface(ts.state.?, 8, 4) orelse return error.NothingPicked;
    try testing.expectEqual(second_surface, second_pick.surface);
}

test "an unmapped desktop can accept a new client and recover after the last output reconnects" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const first = ts.viewOf();
    ts.removeOutput(first.output);
    const top = try ts.createToplevelWithBuffer(try ts.createSplitBuffer(32, 16, 0x20, 0xE0));
    defer ts.allocator.destroy(top);
    top.toplevel.setMaximized();
    try ts.pump();
    syncSurfaces(ts.state.?);
    syncSurfacePlacement(ts.state.?);
    try testing.expect(pickSurface(ts.state.?, 8, 4) == null);
    const reconnected = try ts.addSecondOutput(800, 600);
    ts.renderView(reconnected);
    try expectPixelNear(framebufferPixel(try ts.baseOf(reconnected), 8, 4), grayBytes(0x20), pixel_tolerance);
    const picked = pickSurface(ts.state.?, 8, 4) orelse return error.NothingPicked;
    try testing.expectEqual(ts.serverSurface(top.wl_surface), picked.surface);
}

test "mixed world and output-local pixels and input follow one scene stacking order" {
    const ts = try PolicyServer.init(testing.allocator);
    defer ts.deinit();
    const view = ts.viewOf();
    const layer_wl = try ts.wl_compositor.?.createSurface();
    try ts.pump();
    const layer = try ts.layer_shell_client.?.getLayerSurface(layer_wl, ts.wl_output_client.?, .background, "background");
    var events: ClientLayerSurfaceEvents = .{};
    layer.setListener(*ClientLayerSurfaceEvents, ClientLayerSurfaceEvents.listener, &events);
    layer.setAnchor(@bitCast(@as(u32, 1 | 4)));
    layer.setSize(64, 48);
    layer_wl.commit();
    try ts.pump();
    layer.ackConfigure(events.serial);
    layer_wl.attach(try ts.createSplitBuffer(64, 48, 0x20, 0x20), 0, 0);
    layer_wl.commit();
    try ts.pump();
    const layer_surface = ts.serverSurface(layer_wl);

    const top = try ts.createToplevelWithBuffer(try ts.createSplitBuffer(32, 16, 0xE0, 0xE0));
    defer ts.allocator.destroy(top);
    const world_surface = ts.serverSurface(top.wl_surface);
    ts.renderView(view);
    try expectPixelNear(framebufferPixel(try ts.baseOf(view), 8, 4), grayBytes(0xE0), pixel_tolerance);
    try testing.expectEqual(world_surface, (pickSurface(ts.state.?, 8, 4) orelse return error.NothingPicked).surface);

    // Reordering the scene, not the role registry, moves the layer above.
    const layer_tree = wayland.surface_node.surfaceNodeFor(ts.scene.?, layer_surface).?.tree.?;
    try ts.scene.?.root.appendChild(ts.allocator, layer_tree);
    ts.renderView(view);
    try expectPixelNear(framebufferPixel(try ts.baseOf(view), 8, 4), grayBytes(0x20), pixel_tolerance);
    try testing.expectEqual(layer_surface, (pickSurface(ts.state.?, 8, 4) orelse return error.NothingPicked).surface);

    // The scene's top local node is NOT at the camera-projected window.
    // Picking world coordinates first would incorrectly let it hide this hit.
    view.camera.center_x = 16;
    view.camera.center_y = 8;
    view.camera.zoom = 2;
    view.camera.rotation = 0.3;
    ts.renderView(view);
    try expectPixelNear(framebufferPixel(try ts.baseOf(view), 400, 300), grayBytes(0xE0), pixel_tolerance);
    const world_hit = pickSurface(ts.state.?, 400, 300) orelse return error.NothingPicked;
    try testing.expectEqual(world_surface, world_hit.surface);
    try testing.expectApproxEqAbs(@as(f64, 16), world_hit.sx, 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 8), world_hit.sy, 0.000001);
}
