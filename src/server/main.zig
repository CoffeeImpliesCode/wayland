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
//!                        "nested" selects the nested-wayland backend (our
//!                        compositor as a client of a parent compositor, M5);
//!                        "drm" selects the DRM/KMS backend; anything else
//!                        selects the headless backend
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

/// The camera the server starts with: the world origin centered on the
/// viewport center at zoom 1, no rotation, whose worldToScreen is the
/// identity mapping. An unset or unparseable WAYLAND_CAMERA falls back to
/// exactly this (see parseCameraEnv), and `last_camera` starts here too so
/// the first frame observes no camera change.
const default_camera: Camera = .{
    .center_x = @as(f64, @floatFromInt(output_width)) / 2.0,
    .center_y = @as(f64, @floatFromInt(output_height)) / 2.0,
    .zoom = 1,
    .rotation = 0,
    .screen_w = @floatFromInt(output_width),
    .screen_h = @floatFromInt(output_height),
};

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
    /// xdg_popups parented to layer surfaces via get_popup (tracked for
    /// observability; L1).
    layer_popups: std.ArrayList(*wayland.shell.XdgPopup) = .empty,
    /// L-D7: the live EXCLUSIVE layer keyboard grab (see
    /// applyLayerKeyboardFocus). While the pointer is over an
    /// exclusive-interactivity layer surface, the seat's keyboard focus
    /// is grabbed by it and the pre-grab focus is restored when the
    /// pointer leaves. Null while no grab is active.
    layer_kbd_grab: ?LayerKbdGrab = null,
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
    /// per newly-mapped surface (headless input E2E). The first client
    /// gets the original click+key; every later surface (a second
    /// client, a popup) gets the same treatment so multi-client sessions
    /// (selection roundtrips) also see focus + a serial. Tracked by
    /// surface identity so re-maps of the same surface do not re-click.
    synth_input: bool = false,
    synth_clicked: std.AutoHashMapUnmanaged(*Surface, void) = .{},
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
    /// The camera state at the last render: a change (pan/zoom) forces
    /// whole-output damage so the partial upload never smears the
    /// previous canvas (the drag-streak bug).
    last_camera: Camera = default_camera,
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
    frame_listener: wire.Listener(*wayland.output.Output),
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
    g.drag_active = false;
    g.fast_render = false;
    const ours = g.own_grab orelse return false;
    g.own_grab = null;
    if (seat.pointer_grab != ours) return false;
    seat.endPointerGrab();
    return true;
}

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
    // wp_fractional_scale_manager_v1 (staging): the preferred scale.
    const fractional_scale = try wayland.fractional_scale.FractionalScale.init(allocator, io, &log_cfg, display);
    defer fractional_scale.deinit();
    // zxdg_output_manager_v1 (unstable/xdg-output): logical output
    // geometry for clients (grim, region tools).
    const xdg_output = try wayland.xdg_output.XdgOutput.init(allocator, io, &log_cfg, display);
    defer xdg_output.deinit();
    // Advertise the preferred scale now (scale 1: 120/120). The value is
    // a settable API — a future scale path calls setPreferredScale on
    // output-scale change (wlroots refines to per-surface notify_scale).
    fractional_scale.setPreferredScale(120);
    // wp_viewporter (stable): crop/scale surface content (foot needs it).
    const viewporter = try wayland.viewporter.Viewporter.init(allocator, io, &log_cfg, display);
    defer viewporter.deinit();
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
    // --- the pointer-stream protocols ------------------------------------
    // Dependency order: everything below is constructed AFTER the seat
    // it may attach to, and each defer therefore runs BEFORE the seat's
    // (LIFO), so no module can reach a freed seat during teardown.
    //
    // zwp_pointer_gestures_v1 (unstable): swipe/pinch/hold recognition.
    // The module installs its own seat listeners (setSeat), so main's
    // only job is handing it the seat.
    const pointer_gestures = try wayland.pointer_gestures.PointerGestures.init(
        allocator,
        io,
        &log_cfg,
        display,
        seat,
    );
    defer pointer_gestures.deinit();
    // zwp_relative_pointer_manager_v1 (unstable): unclaccelerated
    // relative motion (24.8 deltas + a 64-bit utime).
    const relative_pointer = try wayland.relative_pointer.RelativePointer.init(
        allocator,
        io,
        &log_cfg,
        display,
        seat,
    );
    defer relative_pointer.deinit();
    // zwp_pointer_constraints_v1 (unstable): locked and confined
    // pointers. Needs the compositor to resolve a wl_surface for
    // lock_pointer / confine_pointer.
    const pointer_constraints = try wayland.pointer_constraints.PointerConstraints.init(
        allocator,
        io,
        &log_cfg,
        display,
        compositor,
        seat,
    );
    defer pointer_constraints.deinit();
    // zwp_tablet_manager_v2 (stable): the hardware registry. It needs no
    // seat — a tablet announces its own zwp_tablet_seat_v2 — and no
    // hardware is registered (this server has no tablet input backend),
    // which is the module's documented "correct with no hardware" state.
    const tablet = try wayland.tablet.Tablet.init(allocator, io, &log_cfg, display);
    defer tablet.deinit();
    // wp_cursor_shape_manager_v1 (staging): per-device cursor shapes.
    // Built AFTER the tablet module: a tablet-tool cursor-shape device
    // resolves its serial through it (shell/cursor_shape.zig), and a
    // null tablet would make every such device permanently inert.
    const cursor_shape = try wayland.cursor_shape.CursorShape.init(allocator, io, &log_cfg, display, tablet);
    defer cursor_shape.deinit();
    // wp_tearing_control_manager_v1 (staging): the per-surface async
    // present hint. The present path reads it per surface per frame
    // (consultTearingHints); the module itself only records.
    const tearing_control = try wayland.tearing_control.TearingControl.init(allocator, io, &log_cfg, display);
    defer tearing_control.deinit();
    // ext_session_lock_manager_v1 (staging): the session-lock privilege
    // boundary. The module owns the protocol state; main owns the gates
    // (see lockedFrameFor, pickSurface, keyboardFocusAllowed and the
    // session_lock_locked_listener handler below).
    const session_lock = try wayland.session_lock.SessionLock.init(allocator, io, &log_cfg, display);
    defer session_lock.deinit();
    // zwlr_data_control_manager_v1 (wlroots/unstable): the compositor as
    // data SOURCE. Needs the seat (a device is per seat), the ordinary
    // wl_data_device_manager it mirrors (the read side) and the primary
    // selection manager (v2's set_primary_selection).
    const data_control = try wayland.data_control.DataControlManager.init(
        allocator,
        io,
        &log_cfg,
        display,
        seat,
        data_device,
        primary_selection,
    );
    defer data_control.deinit();
    // zwlr_foreign_toplevel_manager_v1 (wlroots/unstable): our own xdg
    // toplevels as client-visible handles. Built after the shell (it
    // subscribes to xdg_wm_base.new_toplevel) and after the seat (its
    // `activate` request acts on the seat).
    const foreign_toplevel = try wayland.foreign_toplevel.ForeignToplevelManager.init(
        allocator,
        io,
        &log_cfg,
        display,
        shell,
        seat,
    );
    defer foreign_toplevel.deinit();
    const renderer = try pixman.PixmanRenderer.create(allocator, io, &log_cfg);
    defer renderer.destroy();
    // Backend selection: WAYLAND_BACKEND=raylib uses the windowed raylib
    // debug backend (falling back to headless when the window cannot
    // open); anything else uses the headless backend. The raylib path is
    // only reachable when built with -Denable_raylib (default on).
    var backend_is_raylib = false;
    var backend_is_drm = false;
    var backend_is_nested = false;
    const backend = blk: {
        // DRM/KMS native output (tested in the NixOS VM on virtio-gpu).
        if (wantDrmBackend(init.environ_map)) {
            const device = init.environ_map.get("WAYLAND_DRM_DEVICE");
            const b = try drm_mod.DrmBackend.create(allocator, io, &log_cfg, device);
            backend_is_drm = true;
            break :blk b;
        }
        // Nested-wayland backend (M5): our compositor acts as a client of
        // a parent compositor (WAYLAND_DISPLAY), presenting its framebuffer
        // into a parent wl_surface. Real-session testing without DRM.
        if (wantNestedBackend(init.environ_map)) {
            const b = try wayland.wayland_backend.WaylandBackend.create(
                allocator,
                io,
                &log_cfg,
                display.getServer().getEventLoop(),
                .{ .width = output_width, .height = output_height, .refresh_msec = output_refresh_msec },
                "wayland-compositor",
            );
            backend_is_nested = true;
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
                std.mem.eql(u8, v, "nested") or
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

    // zwp_linux_dmabuf_v1 (stable/linux-dmabuf): DMA-BUF buffer import.
    // Constructed AFTER the backend because the module needs its GBM
    // device, and its defer runs BEFORE backend.destroy(): the GBM device
    // belongs to the DRM backend and must outlive the module.
    //
    // The module registers its global ONLY for a GBM device, and only the
    // DRM backend has one — headless / raylib / nested pass null and get
    // no zwp_linux_dmabuf_v1 global at all (the module's documented gate,
    // shell/linux_dmabuf.zig). So this server advertises 25 globals and a
    // DRM one advertises 26.
    const linux_dmabuf = try wayland.linux_dmabuf.LinuxDmabuf.init(
        allocator,
        io,
        &log_cfg,
        display,
        if (backend_is_drm) drm_mod.gbmDevice(drm_mod.DrmBackend.fromBackend(backend)) else null,
    );
    defer linux_dmabuf.deinit();

    // From here on wl_surface.attach resolves dmabuf buffers through the
    // module. The clear is registered AFTER the deinit defer, so LIFO runs
    // it BEFORE linux_dmabuf.deinit(): no attach can ever call into a
    // freed module. The window in between is unreachable in practice
    // (the event loop has stopped), but the ordering makes it impossible
    // rather than merely unlikely.
    //
    // The resolver is set even with no GBM device: LinuxDmabuf.init
    // returns an inert module (no global, empty registry), so
    // fromResource answers null for every resource and the shm path runs
    // exactly as before on headless / raylib / nested.
    wireDmabufResolver(compositor, linux_dmabuf);
    defer compositor.clearDmabufResolver();

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
        .fractional_scale = fractional_scale,
        .viewporter = viewporter,
        .pointer_gestures = pointer_gestures,
        .relative_pointer = relative_pointer,
        .pointer_constraints = pointer_constraints,
        .tablet = tablet,
        .cursor_shape = cursor_shape,
        .tearing_control = tearing_control,
        .session_lock = session_lock,
        .data_control = data_control,
        .foreign_toplevel = foreign_toplevel,
        .linux_dmabuf = linux_dmabuf,
        .backend = backend,
        .framebuffer = framebuffer,
        .camera = default_camera,
        .camera_env = init.environ_map.get("WAYLAND_CAMERA"),
        .presentation = presentation,
        .toplevels = .empty,
        .layer_surfaces = .empty,
        .layer_popups = .empty,
        .new_output_listener = wire.Listener(*wayland.output.Output).init(onNewOutput),
        .new_input_listener = wire.Listener(*wayland.backend.Backend.InputDevice).init(onNewInput),
        .frame_listener = wire.Listener(*wayland.output.Output).init(onOutputFrame),
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
    if (backend_is_drm) state.drm_backend = backend;
    defer state.synth_clicked.deinit(allocator);
    defer state.toplevels.deinit(allocator);
    defer state.layer_surfaces.deinit(allocator);
    defer state.layer_popups.deinit(allocator);
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
    // L1: layer-popup parenting (get_popup) is observable; no anchoring or
    // placement policy here (out of scope, same as layer-surface layout).
    layer_shell.events.new_popup.add(&state.new_layer_popup_listener);
    seat.events.key.add(&state.seat_key_listener);
    // M4 Phase B camera controls: wheel zoom + drag pan hook the seat's
    // existing event surface (button, pointer_move, axis). The raylib
    // and libinput backends feed these signals through the seat API
    // (pointerButton/pointerMotion/pointerAxis), so no backend change is
    // needed; headless E2E synthesizes the same calls.
    seat.events.button.add(&state.seat_button_listener);
    seat.events.pointer_move.add(&state.seat_pointer_move_listener);
    seat.events.axis.add(&state.seat_axis_listener);
    // wl_toplevel.activated is compositor-authored state driven by the
    // seat's keyboard focus (P1-9), so a click — not only an
    // xdg_activation request — updates the active titlebar.
    seat.events.keyboard_focus.add(&state.seat_focus_listener);
    // xdg_activation_v1: activation requests with known tokens (focus
    // policy is out of scope — the handler logs and accepts) and the
    // token-creation hook (XA-1; the compositor can observe allowlists /
    // telemetry).
    xdg_activation.events.request_activate.add(&state.request_activate_listener);
    xdg_activation.events.new_token.add(&state.new_activation_token_listener);
    // zxdg_decoration_manager_v1: mode requests; the handler replies with
    // the effective mode via sendConfigure. New decorations announce the
    // compositor's initial mode the same way, so a client that never sends
    // set_mode still draws the policy chrome (L2).
    xdg_decoration.events.request_mode.add(&state.request_mode_listener);
    xdg_decoration.events.new_toplevel_decoration.add(&state.new_decoration_listener);
    // The compositor hit-tests over the scene graph: surfaces map to
    // scene nodes through the surface entries.
    seat.setPick(pickSurface, &state);
    // Click-to-focus gates, in the order they are consulted: the session
    // lock first (while locked only a lock surface of the lock client may
    // take focus), then L-D7's layer policy — a layer surface with
    // keyboard_interactivity=none must never get focus, and the
    // move-based routing in applyLayerKeyboardFocus enforces the same
    // for hover.
    seat.setKeyboardFocusGate(keyboardFocusAllowed, &state);
    // ext_session_lock_manager_v1: the four signals main owns. `locked`
    // runs inside the lock surface's commit dispatch, so the grabs are
    // ended and the focus forced onto a lock surface BEFORE any frame can
    // be composited (shell/session_lock.zig wiring item 1).
    session_lock.events.locked.add(&state.session_locked_listener);
    session_lock.events.unlocked.add(&state.session_unlocked_listener);
    session_lock.events.new_lock_surface.add(&state.new_lock_surface_listener);
    session_lock.events.lock_surface_gone.add(&state.lock_surface_gone_listener);
    // Unlink before the module deinits run: their teardown emits
    // lock_surface_gone, and these handlers dereference `state`, whose
    // own teardown defers were registered later and have already run.
    defer unlinkSessionLockListeners(&state);
    // wp_cursor_shape_manager_v1: an accepted set_shape is recorded by the
    // module; this compositor paints one cursor image for every shape, so
    // the handler only says so.
    cursor_shape.events.shape_changed.add(&state.cursor_shape_changed_listener);

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
fn onToplevelInitialCommit(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("initial_commit", listener);
    t.scheduleConfigure() catch {
        log.warn("initial toplevel configure failed", tl.state.io, tl.state.log_cfg, "server", .{});
    };
}

fn onToplevelAppId(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("set_app_id", listener);
    log.info("toplevel app_id changed: {s}", tl.state.io, tl.state.log_cfg, "server", .{t.app_id orelse "(none)"});
}

/// The output's FULL box (its mode rect at the origin): the area a
/// fullscreen surface covers. Distinct from usableArea — a fullscreen
/// window covers panels, only a maximized one does not (wlroots keeps
/// the full and the usable box apart, types/wlr_output.c:1106-1114;
/// tinywl answers set_fullscreen with the full output size and
/// set_maximized with the usable area, tinywl.c handle_toplevel_configure).
fn fullscreenBox(self: *ServerState, named: ?*wayland.server.wl.Output) ?geom.Rect {
    // set_fullscreen may name the output; the wl_output resource is this
    // compositor's only when WlOutput.owns says so (a resource of a
    // foreign global is ignored — the same identity check the rest of the
    // server uses for protocols that take a wl_output, e.g. screencopy).
    if (named) |res| {
        if (self.wl_output) |wo| {
            if (wo.owns(res)) return outputRect(wo.output);
        }
    }
    // No usable name (null, or an output that is gone): this server has
    // a single output, so it is the one the surface belongs to
    // (wlroots falls back to the output containing the surface).
    return if (self.output) |out| outputRect(out) else null;
}

/// The output's mode rect at the origin: this server places its single
/// output at (0,0) (one canvas, no multi-output layout yet).
fn outputRect(out: *wayland.output.Output) geom.Rect {
    return .{ .x = 0, .y = 0, .width = out.mode.width, .height = out.mode.height };
}

/// The output's USABLE area: its mode rect shrunk by every exclusive
/// zone the layer shell reserved (wlroots wlr_output usable_area,
/// types/wlr_output.c:1106-1114 — a mapped layer surface's exclusive
/// zone takes its edge off the usable area, which is exactly why a
/// maximized window must not hide under a panel). A negative zone
/// reserves the layer surface's own extent along that edge
/// (wlr_layer_surface_v1: a negative zone lets the compositor size it).
///
/// A reserved strip comes off BOTH ends of the axis it sits on: the top
/// strip moves the origin down AND takes its pixels off the height (a
/// rect that only moved its origin would still run off the bottom of
/// the output). wlroots applies the reservation through the same
/// two-sided shrink — `wlr_output_layout` reserves each edge with
/// `output_layout_reserve` semantics, where a top reservation shifts
/// `usable.y` and subtracts from `usable.height`
/// (types/wlr_output_layout.c, `wlr_output_layout_get_usable_area`).
fn usableArea(self: *ServerState) geom.Rect {
    const out = self.output orelse return geom.Rect.empty();
    var area = outputRect(out);
    for (self.layer_shell.layer_surfaces.items) |ls| {
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
/// Policy: this server has one output and imposes no size constraints,
/// so it agrees, and configures the surface to the output's USABLE area
/// (usableArea) — the answer tinywl gives (tinywl.c
/// handle_toplevel_configure sends the usable width/height for a
/// maximized surface). Unmaximizing hands the size back to the client:
/// the protocol has no "restore size" state and this server stores no
/// pre-maximize geometry, so 0,0 ("client decides",
/// xdg_toplevel.configure width/height) is the honest answer.
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
        const area = usableArea(self);
        t.scheduled.width = area.width;
        t.scheduled.height = area.height;
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
/// same request/answer contract as maximize, with the FULL output box
/// (fullscreen covers panels, wlroots / tinywl.c handle_toplevel_configure)
/// taken from the output the client named, or from this server's single
/// output when it named none.
fn onToplevelFullscreen(
    listener: *wire.Listener(*wayland.shell.FullscreenRequest),
    req: *wayland.shell.FullscreenRequest,
) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_fullscreen", listener);
    const self = tl.state;
    const t = req.toplevel;
    t.scheduled.fullscreen = req.fullscreen;
    // Leaving fullscreen hands the size back to the client (same reason
    // as unmaximize: no stored pre-fullscreen geometry to restore).
    t.scheduled.width = 0;
    t.scheduled.height = 0;
    if (req.fullscreen) {
        if (fullscreenBox(self, req.output)) |box| {
            t.scheduled.width = box.width;
            t.scheduled.height = box.height;
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
/// client that it is minimized"), so the compositor records the request
/// — the module keeps it in ToplevelState.minimized for exactly this —
/// and takes the surface off screen: a minimized window is a window the
/// user cannot see. This server has no iconifier to un-hide it, so the
/// window comes back when the client commits again (the surface node's
/// own update re-enables it, surface_node.zig:172).
fn onToplevelMinimize(listener: *wire.Listener(*wayland.shell.XdgToplevel), t: *wayland.shell.XdgToplevel) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_minimize", listener);
    const self = tl.state;
    log.info("toplevel minimize requested (recorded)", self.io, self.log_cfg, "server", .{});
    const scene = self.scene orelse return;
    const sn = wayland.surface_node.surfaceNodeFor(scene, t.xdg_surface.surface) orelse return;
    if (sn.node) |node| node.enable(false);
    if (self.scene_output) |so| {
        so.addDamage(.{ .x = 0, .y = 0, .width = self.framebuffer.width, .height = self.framebuffer.height });
    }
    requestRender(self);
}

fn onToplevelMove(listener: *wire.Listener(*wayland.shell.MoveRequest), req: *wayland.shell.MoveRequest) void {
    const tl: *ToplevelListeners = @fieldParentPtr("request_move", listener);
    const self = tl.state;
    const seat = req.seat;
    const toplevel_client = req.toplevel.xdg_surface.surface.resource.getClient();
    // The serial must be a recent input-event serial on the request's
    // seat (wlroots wlr_xdg_toplevel_move validates the same way).
    if (!seat.validateEventSerial(toplevel_client, req.serial)) return;
    // The move owns the gesture: cancel any armed camera drag.
    self.gestures.camera_drag = null;
    self.gestures.drag_active = false;
    self.gestures.fast_render = false;
    self.gestures.moving_toplevel = req.toplevel;
    const wp = self.camera.screenToWorld(@floatFromInt(seat.pointer_x), @floatFromInt(seat.pointer_y));
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
    // dimensions — the (single) output's mode size is the fallback the
    // module uses in the initial configure.
    if (self.output) |out| {
        ls.setFallbackSize(@intCast(out.mode.width), @intCast(out.mode.height));
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
        @intFromEnum(ls.current.layer),
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
    // The focus gate is the compositor's policy for what may hold
    // keyboard focus (a keyboard_interactivity=none layer surface may
    // not, L-D7), so activation goes through it too.
    if (layerKeyboardFocusAllowed(self, req.surface)) {
        self.seat.setKeyboardFocus(req.surface);
    }
}

/// The seat's keyboard focus changed (it fires after the leave/enter/
/// modifiers wire events, seat.zig:1270): republish wl_toplevel.
/// activated for every toplevel whose activated state flipped.
fn onSeatKeyboardFocus(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_focus_listener", listener);
    syncToplevelActivation(self, seat);
}

/// wl_toplevel.activated follows the seat's KEYBOARD FOCUS (P1-9). The
/// protocol makes it compositor-authored state — xdg_toplevel.state
/// "activated": "the surface ... is the one that has the focus" — and a
/// CSD toolkit renders its active titlebar from it, so a server that
/// never sends it never shows an active titlebar.
///
/// Driven from seat.events.keyboard_focus, so a CLICK updates it, not
/// only an xdg_activation request. Both ends of the change are
/// reconfigured in the same pass: an unfocused window must report
/// activated=false, or the client keeps drawing it active forever.
///
/// The focus gate is re-checked here (layerKeyboardFocusAllowed): a
/// surface that cannot take keyboard focus must never be reported
/// activated, whoever routed the focus at it.
fn syncToplevelActivation(self: *ServerState, seat: *wayland.seat.Seat) void {
    // shell.toplevels is pruned when a role object is destroyed
    // (xdg.zig:1317-1318), so every entry here is live.
    for (self.shell.toplevels.items) |t| {
        const surface = t.xdg_surface.surface;
        const activated = surface == seat.keyboard_focus and layerKeyboardFocusAllowed(self, surface);
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
    const sx = rect.x + @divTrunc(rect.width, 2);
    const sy = rect.y + @divTrunc(rect.height, 2);
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
    // ext_session_lock_manager_v1, wiring item 1: the latch is read HERE,
    // once per frame, and every composite decision below uses this value.
    // Nothing caches "was I unlocked" across a dispatch, so the first
    // frame composited after the `locked` signal (which is emitted inside
    // the lock surface's commit dispatch, before this runs) is already a
    // locked frame.
    const lock = lockedFrameFor(self, out);

    const perf_t_sync = perfNs(self);
    // Subsurfaces: position child nodes over their mapped parent.
    syncSubsurfaceNodes(self);
    // F12: popups position over their parent at the geometry offset and
    // stack above it (menus render where the positioner asked and
    // hit-test there).
    syncPopupNodes(self);
    // P2-12: the wl_data_device.start_drag icon follows the pointer in
    // scene coordinates while its drag lives.
    syncDragIconNodes(self);

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
    if (lock.locked) {
        // A locked session never reuses the previous canvas: the two
        // shortcuts below (hover cursor restore, present-unchanged) would
        // show a frame composited BEFORE the latch, which is exactly what
        // the privilege boundary forbids. Refill the output instead.
        self.cursor_repaint = false;
        self.frame_kick = false;
        compositeCanvas(self, lock);
    } else if (self.cursor_repaint) {
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
        if (!lock.cursor_hidden) self.cursor.?.draw(self.framebuffer);
    } else if (self.frame_kick) {
        // A client is ready for the next frame (pending wl_callback) but
        // the canvas is unchanged. Present the current framebuffer so the
        // callback fires and the client can render + commit its pending
        // update — no recomposite.
        self.frame_kick = false;
    } else {
        compositeCanvas(self, lock);
    }

    // wp_tearing_control_manager_v1: the present path consults the
    // committed hint of every surface it is about to scan out, per frame.
    _ = consultTearingHints(self, out);
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

    // wp_presentation: every surface drawn this frame awaits its present.
    // The output's wl_output global names the output for sync_output. For
    // real-display backends (DRM/nested — Output.emits_present) present()
    // QUEUES the feedbacks on the output's commit seq (out.commit_seq,
    // the seq of the frame just committed): the output's presented event
    // — the actual scanout/flip completion — delivers them with the
    // backend's timestamp, flags and refresh; a frame that never presents
    // is never reported. Headless/raylib have no present event:
    // present() synthesizes immediately (the refresh/flags args are
    // theirs alone — a synthetic present is the only path that uses
    // them).
    self.presentation.present(
        self.scene.?.presented.items,
        self.wl_output,
        out.commit_seq,
        @intCast(out.mode.refresh_msec),
        0,
    );

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
/// earlier in renderFrame).
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
fn consultTearingHints(self: *ServerState, out: *wayland.output.Output) PresentTearing {
    const tc = self.tearing_control orelse return .{};
    const scene = self.scene orelse return .{};
    var async_surfaces: u32 = 0;
    for (scene.presented.items) |surface| {
        if (tc.hintFor(surface) == .async) async_surfaces += 1;
    }
    // The output gate: the client's `.async` is a permission, honoured
    // only when the output actually tears (see outputTears).
    const honoured = async_surfaces > 0 and outputTears(out);
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

/// The locked frame for `out`, read at the start of renderFrame. The
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
/// screen-space cursor) into the display framebuffer. The background +
/// surfaces (the "base") are rendered into the persisted base_framebuffer
/// first and copied out, so renderFrame's cursor_repaint path can restore
/// a cursor region from the base without recompositing the whole canvas
/// (the ~450ms full-canvas bilinear in the VM).
fn compositeCanvas(self: *ServerState, lock: LockedFrame) void {
    ensureBaseFramebuffer(self);
    compositeBase(self, lock);
    copyWhole(self.base_framebuffer.?, self.framebuffer);
    // ext_session_lock_v1:74-91 — a locked session draws no cursor.
    // Cursor.update re-enables its scene nodes every frame, so hiding the
    // cursor is the server not painting it (compositor/cursor.zig owns
    // the nodes; main owns the draw).
    if (!lock.cursor_hidden) self.cursor.?.draw(self.framebuffer);
}

/// Render the background + all mapped surfaces through the camera into the
/// base framebuffer (the canvas WITHOUT the cursor). The expensive
/// full-canvas bilinear; done only when the canvas actually changes.
///
/// `lock` is the session-lock decision for this frame (lockedFrameFor).
/// While locked the fill is the OPAQUE lock color instead of the
/// background and only lock surfaces reach the canvas pass — user
/// content, the drag icon and the cursor are never drawn, which is the
/// render half of the privilege boundary (ext_session_lock_v1:74-91).
fn compositeBase(self: *ServerState, lock: LockedFrame) void {
    const base = self.base_framebuffer orelse return;
    // 1. Fill. Premultiplied ARGB8888, memory bytes B,G,R,A; the scene's
    //    background rect drew the same color via addRect
    //    (round(color*a*255) per channel with straight alpha a=1), so
    //    the bytes are identical. A locked session fills with the opaque
    //    lock color INSTEAD, before anything is drawn: an output with no
    //    (or a too small) lock surface must never show what was there
    //    before.
    const fill = if (lock.locked) lock_blank_color else background_color;
    const bg: [4]u8 = .{
        @intFromFloat(@round(fill[2] * 255.0)),
        @intFromFloat(@round(fill[1] * 255.0)),
        @intFromFloat(@round(fill[0] * 255.0)),
        @intFromFloat(@round(fill[3] * 255.0)),
    };
    base.fill(bg);
    // A blank output draws NOTHING: the solid color stays (outputIsBlank
    // said the lock surface is missing, unmapped or smaller than the
    // output, and composited lock content must never be stretched to
    // cover the gap).
    if (lock.blank) return;

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
        // ext_session_lock_v1:74-91 — while the session is locked "the
        // only surfaces that should be rendered ... are the lock
        // surfaces created through this interface". Everything else
        // (user content, popups, drag icons, the client cursor surface)
        // is skipped here, the one place the canvas pass chooses what to
        // draw.
        if (lock.locked) {
            const sl = self.session_lock.?;
            if (!sl.isLockSurface(sn.*.surface)) continue;
        }
        if (cursor_res) |cr| {
            if (sn.*.surface.resource == cr) continue;
        }
        // A drag icon is drawn at the POINTER (syncDragIconNodes), never
        // as content at its own node position — which is where it used to
        // land, a drag "cursor" stuck at the scene origin.
        if (isDragIconSurface(sn.*.surface)) continue;
        const node = sn.*.node orelse continue;
        // A disabled node is not on screen: the minimize policy hides a
        // window that way (onToplevelMinimize).
        if (!node.enabled) continue;
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
    wayland.canvas.render(self.allocator, base, &self.camera, items.items, if (self.gestures.fast_render) 3 else 1);
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
    // ext_session_lock_manager_v1, wiring item 2: while the session is
    // locked the pointer may only ever land on a lock surface. Returning
    // null makes the seat send wl_pointer.leave and deliver nothing, so
    // no client outside the lock sees motion, buttons or an enter (the
    // XML requires input suppression, not merely a hidden screen). This
    // is the lock-aware pick the module's contract asks the server to
    // install through seat.setPick — the compositor's own hit test, not
    // a second seat.
    if (self.session_lock) |sl| {
        if (sl.isLocked() and !sl.isLockSurface(surface)) return null;
    }
    const rect = node.absolutePosition();
    return .{
        .surface = surface,
        .sx = pick_x - rect.x,
        .sy = pick_y - rect.y,
    };
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
    const over_ls = layerSurfaceForSurface(self, seat.pointer_focus);
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
/// click-to-focus must not either.
fn layerKeyboardFocusAllowed(ctx: *anyopaque, surface: *Surface) bool {
    const self: *ServerState = @ptrCast(@alignCast(ctx));
    const ls = layerSurfaceForSurface(self, surface) orelse return true;
    return ls.current.keyboard_interactive != 0;
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
        if (wayland.surface_node.surfaceNodeFor(scene, ls.surface)) |sn| {
            // The lock screen is configured to the output's logical size,
            // so its node belongs at the output's origin. With one canvas
            // at (0,0) that is the node's default; setting it explicitly
            // keeps the placement correct if that ever changes.
            const rect = outputRect(ls.output);
            if (sn.node) |node| {
                node.x = rect.x;
                node.y = rect.y;
            }
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
        if (sl.isLocked()) return;
    }
    if (seat.last_button != wayland.seat.btn_left) return;
    if (seat.last_button_pressed) {
        // Arm the pan anchor but DON'T start it (drag_active stays false):
        // a click without enough movement must keep click-to-focus.
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
            self.cursor_repaint = false;
            return;
        }
    }
    // L-D7: layer keyboard-interactivity focus routing. The seat already
    // updated its pointer focus for this move; apply the layer policy on
    // top (exclusive grab / on_demand focus / none exclusion). During a
    // compositor grab (camera drag, interactive move) the seat froze the
    // pointer focus, so this is a no-op there.
    applyLayerKeyboardFocus(self, seat);
    // Interactive move: the toplevel's node follows the pointer delta
    // (world coords — the screen delta divided by the zoom, matching the
    // pick transform). The whole output is damaged so the partial upload
    // cannot smear the old position.
    if (self.gestures.moving_toplevel) |t| {
        const wp = self.camera.screenToWorld(@floatFromInt(seat.pointer_x), @floatFromInt(seat.pointer_y));
        const dx = wp.x - self.gestures.move_anchor.x;
        const dy = wp.y - self.gestures.move_anchor.y;
        self.gestures.move_anchor = .{ .x = wp.x, .y = wp.y };
        if (self.scene) |scene| {
            if (wayland.surface_node.surfaceNodeFor(scene, t.xdg_surface.surface)) |sn| {
                if (sn.node) |node| {
                    node.x += @intFromFloat(@round(dx));
                    node.y += @intFromFloat(@round(dy));
                }
            }
        }
        if (self.scene_output) |so| {
            so.addDamage(.{ .x = 0, .y = 0, .width = self.framebuffer.width, .height = self.framebuffer.height });
        }
        requestRender(self);
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
            self.cursor_repaint = true;
            requestRender(self);
            return;
        }
        // Above the threshold (or already dragging): pan the camera. The
        // implicit pointer grab starts here: the client under the pointer
        // must not see the motion (it would extend a text selection while
        // the user pans the canvas).
        self.gestures.drag_active = true;
        self.gestures.fast_render = true;
        grabPointerForGesture(seat, &self.gestures);
        self.camera.center_x -= @as(f64, @floatFromInt(dx)) / self.camera.zoom;
        self.camera.center_y -= @as(f64, @floatFromInt(dy)) / self.camera.zoom;
        self.gestures.camera_drag = DragPoint{ .x = seat.pointer_x, .y = seat.pointer_y };
        log.debug("camera center -> {d},{d}", self.io, self.log_cfg, "camera", .{
            self.camera.center_x, self.camera.center_y,
        });
        requestRender(self);
        return;
    }
    // No drag armed: hover — the canvas is static, so just move the
    // cursor (repaint only the cursor region, not the full composite).
    // A live drag icon moves the canvas too, so that frame must
    // recomposite for the icon to follow the pointer.
    if (self.data_device.currentDragIcon() != null) {
        requestRender(self);
        return;
    }
    self.cursor_repaint = true;
    requestRender(self);
}

/// M4 camera zoom: a vertical wheel notch (+1 discrete) multiplies the
/// camera zoom by 1.25, -1 divides; clamped to [0.1, 16.0]. The zoom is
/// a viewport property, so it applies regardless of pointer focus (the
/// seat emits the axis signal for every axis event).
fn onSeatAxis(listener: *wire.Listener(*wayland.seat.Seat), seat: *wayland.seat.Seat) void {
    const self: *ServerState = @fieldParentPtr("seat_axis_listener", listener);
    // A locked session must not zoom the canvas under the lock client.
    if (self.session_lock) |sl| {
        if (sl.isLocked()) return;
    }
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
            popup_tree.x = p.geometry.x;
            popup_tree.y = p.geometry.y;
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

/// Keep the drag icon's scene node at the pointer while its drag lives
/// (P2-12). Same pass shape as syncPopupNodes / syncSubsurfaceNodes: it
/// runs every frame from renderFrame, before the composite, and is a
/// no-op when no drag is running (a null check).
///
/// The icon is an ordinary tracked surface (syncSurfaces tracks every
/// compositor surface), so this pass positions its tree in SCENE
/// coordinates — the space the seat reports the pointer in — at
/// seat.pointer_x/pointer_y, and keeps the tree at the scene root (a
/// role surface has no parent tree) so it stacks with the other
/// top-level surfaces. An unmapped icon has no tree yet (SurfaceNode
/// creates it on the first buffer commit), so an icon that has not
/// committed costs nothing here. Once the drag ends the icon is no
/// longer drawn at all: isDragIconSurface keeps the canvas pass from
/// stamping it at the position it was left at.
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
    tree.x = self.seat.pointer_x;
    tree.y = self.seat.pointer_y;
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
    states: [13]u32 = [_]u32{0} ** 13,
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

const ClientXdgSurfaceEvents = struct {
    configures: usize = 0,
    serial: u32 = 0,

    fn listener(xdg_surface: *client.xdg.Surface, event: client.xdg.Surface.Event, data: *ClientXdgSurfaceEvents) void {
        _ = xdg_surface;
        switch (event) {
            .configure => |c| {
                data.configures += 1;
                data.serial = c.serial;
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
    const Entry = struct {
        interface: [*:0]const u8,
        name: u32,
        version: u32,
    };
    entries: [max_globals]Entry = undefined,
    len: usize = 0,

    fn listener(_: *client.wl.Registry, event: client.wl.Registry.Event, self: *PolicyGlobalCapture) void {
        switch (event) {
            .global => |g| {
                if (self.len >= self.entries.len) return;
                self.entries[self.len] = .{ .interface = g.interface, .name = g.name, .version = g.version };
                self.len += 1;
            },
            .global_remove => {},
        }
    }

    fn find(self: *const PolicyGlobalCapture, interface: []const u8) ?Entry {
        for (self.entries[0..self.len]) |e| {
            if (std.mem.eql(u8, std.mem.span(e.interface), interface)) return e;
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
    presentation: ?*wayland.presentation.Presentation = null,
    backend: ?*wayland.backend.Backend = null,
    output: ?*wayland.output.Output = null,
    wl_output: ?*wayland.wl_output.WlOutput = null,
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
    /// A second SERVER-side client with nothing bound (the session-lock
    /// input assertions need a client that is NOT the lock client), plus
    /// its open peer fd: closing it would look like a disconnect at the
    /// next dispatch.
    idle_client: ?*wire.Client = null,
    idle_peer: ?std.posix.socket_t = null,

    /// The display framebuffer handle. Real (the minimize policy reads
    /// its size for the output damage) but never rendered into.
    fb: ?*pixman.Framebuffer = null,

    /// The compositor hit test for the tests: always the one surface the
    /// test armed it with (a drag's origin check needs the pointer to be
    /// over the origin surface).
    fn pick(ctx: *anyopaque, x: i32, y: i32) ?wayland.seat.Seat.PickResult {
        const ts: *PolicyServer = @ptrCast(@alignCast(ctx));
        const s = ts.pick_surface orelse return null;
        return .{ .surface = s, .sx = x, .sy = y };
    }

    fn init(allocator: std.mem.Allocator) !*PolicyServer {
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
        ts.renderer = try pixman.PixmanRenderer.create(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.renderer) |r| r.destroy();
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
        // No errdefer: Output's destroy signal owns the WlOutput global.
        ts.wl_output = try wayland.wl_output.WlOutput.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.output.?,
            "test",
            "test output",
        );
        ts.scene = try wayland.scene.Scene.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.scene) |sc| sc.deinit();
        ts.scene.?.subcompositor = ts.subcompositor.?;
        ts.scene.?.wl_output = ts.wl_output.?;

        // The real ServerState: the tests drive the production policy
        // functions, so the fields they read must be the real modules.
        const state = try allocator.create(ServerState);
        errdefer allocator.destroy(state);
        // A real framebuffer object: the minimize policy damages the
        // output through its size. Nothing composites into it here
        // (in_render keeps the render loop out of the way).
        ts.fb = try pixman.Framebuffer.create(allocator, 800, 600);
        errdefer if (ts.fb) |fb| fb.deinit();
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
            .backend = ts.backend.?,
            .camera = default_camera,
            .camera_env = null,
            .scene = ts.scene.?,
            .seat = ts.seat.?,
            .subcompositor = ts.subcompositor.?,
            .data_device = ts.data_device.?,
            .primary_selection = ts.primary_selection.?,
            .presentation = ts.presentation.?,
            .output = ts.output.?,
            .wl_output = ts.wl_output.?,
            .toplevels = .empty,
            .layer_surfaces = .empty,
            .layer_popups = .empty,
            .new_output_listener = wire.Listener(*wayland.output.Output).init(onNewOutput),
            .new_input_listener = wire.Listener(*wayland.backend.Backend.InputDevice).init(onNewInput),
            .frame_listener = wire.Listener(*wayland.output.Output).init(onOutputFrame),
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
            // No frame is ever rendered here: requestRender (from the
            // minimize policy) must only mark repaint_pending instead of
            // driving the output's frame chain.
            .in_render = true,
            .framebuffer = ts.fb.?,
        };
        ts.state = state;

        // The production subscriptions the tests exercise.
        ts.shell.?.events.new_toplevel.add(&state.new_toplevel_listener);
        ts.shell.?.events.new_popup.add(&state.new_popup_listener);
        ts.seat.?.events.keyboard_focus.add(&state.seat_focus_listener);
        ts.seat.?.events.button.add(&state.seat_button_listener);
        ts.seat.?.events.pointer_move.add(&state.seat_pointer_move_listener);
        ts.seat.?.setPick(PolicyServer.pick, ts);
        // main()'s gate: the session lock first, then L-D7's layer policy.
        ts.seat.?.setKeyboardFocusGate(keyboardFocusAllowed, state);
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
            unlinkOne(*wayland.seat.Seat, &state.seat_focus_listener);
            unlinkOne(*wayland.seat.Seat, &state.seat_button_listener);
            unlinkOne(*wayland.seat.Seat, &state.seat_pointer_move_listener);
            state.toplevels.deinit(ts.allocator);
            state.layer_surfaces.deinit(ts.allocator);
            state.layer_popups.deinit(ts.allocator);
            state.synth_clicked.deinit(ts.allocator);
            // ensureBaseFramebuffer() lazily builds this (a test that
            // composites has one); ServerState.deinit frees it in main(),
            // so the harness has to as well.
            if (state.base_framebuffer) |base| base.deinit();
            ts.allocator.destroy(state);
        }
        if (ts.scene) |sc| sc.deinit();
        if (ts.fb) |fb| fb.deinit();
        // The Output's destroy signal frees the WlOutput global.
        if (ts.output) |o| o.destroy();
        if (ts.backend) |b| b.destroy();
        if (ts.presentation) |p| p.deinit();
        if (ts.renderer) |r| r.destroy();
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
    fn pump(ts: *PolicyServer) !void {
        if (ts.c_display.?.flush() != .SUCCESS) return error.ClientFlushFailed;
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        var fds = [_]std.posix.pollfd{.{
            .fd = ts.c_display.?.getFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) return error.ClientDispatchFailed;
        }
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
    /// surface has a scene node.
    fn createToplevel(ts: *PolicyServer) !*Toplevel {
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
            .xs_events = .{},
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
        // Attach a buffer + ack: the surface maps and gets a scene node.
        out.wl_surface.attach(try ts.createBuffer(), 0, 0);
        out.xdg_surface.ackConfigure(out.xs_events.serial);
        out.wl_surface.commit();
        try ts.pump();
        syncSurfaces(ts.state.?);
        return out;
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

    // Minimize: recorded on the toplevel state and taken off screen.
    t.toplevel.setMinimized();
    try ts.pump();
    try testing.expect(st.pending.minimized);
    const sn = wayland.surface_node.surfaceNodeFor(ts.scene.?, ts.serverSurface(t.wl_surface)).?;
    try testing.expect(!sn.node.?.enabled);
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
    popup_xdg_surface.ackConfigure(popup_xs.serial);
    popup_wl_surface.commit();
    try ts.pump();
    syncSurfaces(ts.state.?);

    // Move the PARENT away from the origin, so the popup's absolute
    // position is not simply its parent-relative offset.
    const parent_tree = wayland.surface_node.surfaceNodeFor(
        ts.scene.?,
        ts.serverSurface(parent.wl_surface),
    ).?.tree.?;
    parent_tree.x = 300;
    parent_tree.y = 150;

    syncPopupNodes(ts.state.?);
    const popup_tree = wayland.surface_node.surfaceNodeFor(
        ts.scene.?,
        ts.serverSurface(popup_wl_surface),
    ).?.tree.?;
    const abs = popup_tree.absolutePosition();
    // The published origin is the popup's ABSOLUTE scene position: the
    // parent chain plus the parent-relative geometry.
    try testing.expectEqual(parent_tree.x + p.geometry.x, p.origin.x);
    try testing.expectEqual(parent_tree.y + p.geometry.y, p.origin.y);
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
    try testing.expectEqual(@as(i32, 400), icon_tree.x);
    try testing.expectEqual(@as(i32, 300), icon_tree.y);
    const abs = icon_tree.absolutePosition();
    try testing.expectEqual(@as(i32, 400), abs.x);
    try testing.expectEqual(@as(i32, 300), abs.y);

    // The drag ends: the icon is no longer at the pointer, and the canvas
    // pass no longer composites it as content.
    ts.seat.?.pointerButton(wayland.seat.btn_left, false);
    try ts.pump();
    try testing.expect(ts.data_device.?.currentDragIcon() == null);
    ts.seat.?.pointerMotion(500, 350);
    syncDragIconNodes(ts.state.?);
    try testing.expectEqual(@as(i32, 400), icon_tree.x);
    try testing.expectEqual(@as(i32, 300), icon_tree.y);
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

    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const surface = ts.serverSurface(t.wl_surface);

    // Nothing opted in: no presented surface asks for async presentation.
    wayland.surface_node.collectPresented(ts.scene.?);
    try testing.expectEqual(@as(u32, 0), consultTearingHints(ts.state.?, ts.output.?).async_surfaces);

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
    try testing.expectEqual(@as(u32, 0), consultTearingHints(ts.state.?, ts.output.?).async_surfaces);
    t.wl_surface.commit();
    try ts.pump();

    // Committed: the frame's present path reads it for that surface...
    wayland.surface_node.collectPresented(ts.scene.?);
    const async_frame = consultTearingHints(ts.state.?, ts.output.?);
    try testing.expectEqual(@as(u32, 1), async_frame.async_surfaces);
    // ...and the OUTPUT gate refuses to honour it: no backend in this
    // server flips asynchronously (outputTears), so a `.async` permission
    // never becomes a torn frame.
    try testing.expect(!async_frame.honoured);

    // A surface with no tearing object never asks: the hint is per surface,
    // not per output.
    const other = try ts.createToplevel();
    defer ts.allocator.destroy(other);
    wayland.surface_node.collectPresented(ts.scene.?);
    try testing.expectEqual(@as(u32, 1), consultTearingHints(ts.state.?, ts.output.?).async_surfaces);

    // The client takes the permission back; the next frame reads vsync.
    control.setPresentationHint(.vsync);
    t.wl_surface.commit();
    try ts.pump();
    wayland.surface_node.collectPresented(ts.scene.?);
    try testing.expectEqual(@as(u32, 0), consultTearingHints(ts.state.?, ts.output.?).async_surfaces);
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
    const sl = ts.session_lock.?;
    const other_client = try ts.addIdleClient();
    // The framebuffer compositeBase fills (no frame is ever rendered in
    // these tests).
    ensureBaseFramebuffer(state);

    // A mapped user toplevel: opaque 0x40 gray at the canvas origin.
    const t = try ts.createToplevel();
    defer ts.allocator.destroy(t);
    const user_surface = ts.serverSurface(t.wl_surface);

    // Unlocked: normal content, normal input.
    try testing.expect(!sl.isLocked());
    try testing.expect(sl.acceptsInput(ts.client.?));
    try testing.expect(sl.acceptsInput(other_client));
    try testing.expectEqual(LockedFrame{ .locked = false, .blank = false }, lockedFrameFor(state, ts.output.?));
    try testing.expect(keyboardFocusAllowed(state, user_surface));
    try testing.expect(pickSurface(state, 10, 10) != null);
    compositeBase(state, .{ .locked = false, .blank = false });
    try testing.expectEqual([4]u8{ 0x40, 0x40, 0x40, 0xFF }, framebufferPixel(state.base_framebuffer.?, 10, 10));

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
    const locked = lockedFrameFor(state, ts.output.?);
    // A locked frame never paints the cursor (LockedFrame.cursor_hidden),
    // so the expectation spells the whole struct out.
    try testing.expectEqual(LockedFrame{ .locked = true, .blank = false, .cursor_hidden = true }, locked);
    compositeBase(state, locked);
    try testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0xFF }, framebufferPixel(state.base_framebuffer.?, 10, 10));
    try testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0xFF }, framebufferPixel(state.base_framebuffer.?, 700, 500));

    // The lock surface stops covering its output (its object dies): the
    // fill stays opaque and NOTHING is drawn — user content must not come
    // back while the session is locked (ext_session_lock_v1:74-91).
    lock_surface.destroy();
    try ts.pump();
    try testing.expect(sl.isLocked());
    try testing.expectEqual(LockedFrame{ .locked = true, .blank = true, .cursor_hidden = true }, lockedFrameFor(state, ts.output.?));
    compositeBase(state, .{ .locked = true, .blank = true });
    try testing.expectEqual([4]u8{ 0, 0, 0, 0xFF }, framebufferPixel(state.base_framebuffer.?, 10, 10));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0xFF }, framebufferPixel(state.base_framebuffer.?, 700, 500));
    // Input stays suppressed: unlocking is the only way out.
    try testing.expect(!sl.acceptsInput(other_client));

    // unlock_and_destroy: the gates come off and normal service resumes.
    lock.unlockAndDestroy();
    try ts.pump();
    try testing.expect(!sl.isLocked());
    try testing.expectEqual(LockedFrame{ .locked = false, .blank = false }, lockedFrameFor(state, ts.output.?));
    try testing.expect(keyboardFocusAllowed(state, user_surface));
    try testing.expect(!state.cursor_hidden);
    try testing.expect(sl.acceptsInput(other_client));
}

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
