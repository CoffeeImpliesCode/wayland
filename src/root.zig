//! The wayland compositor library.
//!
//! Re-exports the generated protocol bindings (see build.zig: the
//! zig-wayland scanner compiles vendored protocol XMLs into the
//! "protocol" module). Future compositor modules live here.

pub const protocol = @import("protocol");

/// Server-side protocol objects. `server.wl.wl_compositor` etc.
pub const server = protocol.server;

/// Client-side protocol objects (for test clients).
pub const client = protocol.client;

pub const wire = @import("core/wire.zig");

const build_options = @import("build_options");
const geom_mod = @import("utils/geom.zig");
const damage_mod = @import("utils/damage.zig");
const log_mod = @import("utils/log.zig");
const matrix_mod = @import("utils/matrix.zig");
const test_pump_mod = @import("utils/test_pump.zig");
const display_mod = @import("core/display.zig");

pub const utils = struct {
    pub const geom = geom_mod;
    pub const damage = damage_mod;
    pub const log = log_mod;
    pub const matrix = matrix_mod;
    /// Test-only: the one definition of a test-server roundtrip. It lives
    /// here because the server module's path root is `src/server/`, so
    /// `src/server/*` cannot import `src/utils/*` directly and reaches this
    /// through the `wayland` module like every other library file.
    pub const test_pump = test_pump_mod;
};

pub const core = struct {
    pub const display = display_mod;
};

pub const buffers = @import("buffers/buffer.zig");
/// Linux dmabuf buffer import (buffers/dmabuf.zig): the GBM-backed
/// buffer path a client reaches through zwp_linux_dmabuf_v1. Exported
/// for consumers that present GPU buffers.
pub const dmabuf = @import("buffers/dmabuf.zig");
pub const shm = @import("buffers/shm.zig");
pub const compositor = @import("compositor/compositor.zig");
pub const seat = @import("compositor/seat.zig");
/// Cursor rendering helper (compositor/cursor.zig): the seat's pointer
/// cursor — client cursor surface, fallback texture, scene nodes and
/// damage footprints.
pub const cursor = @import("compositor/cursor.zig");
pub const xkb = @import("compositor/xkb.zig");
/// wl_subcompositor (compositor/subsurface.zig): nested surfaces.
pub const subsurface = @import("compositor/subsurface.zig");
/// wl_data_device_manager (compositor/data_device.zig): clipboard relay.
pub const data_device = @import("compositor/data_device.zig");
/// zwp_primary_selection_device_manager_v1 (compositor/primary_selection.zig):
/// the X11 PRIMARY analogue, keyboard-focus-owned.
pub const primary_selection = @import("compositor/primary_selection.zig");
/// zwlr_data_control_manager_v1 (compositor/data_control.zig): the
/// compositor as the data SOURCE — a client reads the selection out
/// without ever providing a wl_data_source.
pub const data_control = @import("compositor/data_control.zig");
/// Logind session, VT and udev hotplug (backend/session.zig): the M6
/// session lifecycle the DRM backend speaks over sd-bus. Every path
/// degrades non-fatally when no session manager is present, which is the
/// VM case this compositor still runs in.
pub const session = @import("backend/session.zig");
pub const backend = @import("backend/backend.zig");
/// libinput input backend (backend/libinput.zig): evdev devices via
/// libinput (udev context). Exported for the test server.
pub const libinput = @import("backend/libinput.zig");
/// DRM/KMS backend (backend/drm.zig): native output on /dev/dri/cardN
/// with dumb-buffer scanout + atomic modeset/page flip.
pub const drm = @import("backend/drm.zig");
/// Headless backend implementation (backend/headless.zig): one virtual
/// output paced by a wire event loop timer. Exported for consumers that
/// run without a GPU (test servers, examples).
pub const headless = @import("backend/headless.zig");
/// Raylib debug backend (backend/raylib.zig): one windowed output
/// presented through a raylib window. Built only with -Denable_raylib.
pub const raylib = @import("backend/raylib.zig");
/// Raylib input source (backend/raylib_input.zig): feeds the seat from
/// the raylib window. Built only with -Denable_raylib.
pub const raylib_input = @import("backend/raylib_input.zig");
pub const output = @import("output/output.zig");
/// wl_output protocol global (output/wl_output.zig): exposes an Output
/// to clients (geometry/mode/scale/name/description).
pub const wl_output = @import("output/wl_output.zig");
pub const renderer = @import("renderer/renderer.zig");
/// The pixman CPU renderer implementation (renderer/pixman.zig): the
/// Framebuffer target plus PixmanRenderer.create/importMemory. Exported
/// for consumers that render with pixman (test servers, examples).
pub const pixman = @import("renderer/pixman.zig");
/// M4 canvas pass rasterizer (renderer/canvas.zig): camera-transformed
/// texture compositing into a pixman framebuffer.
pub const canvas = @import("renderer/canvas.zig");
pub const shell = @import("shell/xdg.zig");
/// zwlr_layer_shell_v1 (shell/layer_shell.zig): layer surfaces with
/// double-buffered size/anchor/zone/margin/keyboard/layer state.
pub const layer_shell = @import("shell/layer_shell.zig");
/// xdg_activation_v1 (staging/xdg-activation): activation tokens.
pub const xdg_activation = @import("shell/xdg_activation.zig");
/// zxdg_decoration_manager_v1 (unstable/xdg-decoration): server-side decorations.
pub const xdg_decoration = @import("shell/xdg_decoration.zig");
/// wp_fractional_scale_manager_v1 (staging/fractional-scale-v1): the
/// compositor's preferred fractional scale.
pub const fractional_scale = @import("shell/fractional_scale.zig");
/// zxdg_output_manager_v1 (unstable/xdg-output): logical output geometry
/// + stable name/description for clients (grim layout, screenshots).
pub const xdg_output = @import("shell/xdg_output.zig");
/// wp_viewporter (stable/viewporter): crop/scale surface content.
pub const viewporter = @import("shell/viewporter.zig");
/// zwp_pointer_gestures_v1 (shell/pointer_gestures.zig): swipe, pinch
/// and hold recognition from the seat's pointer stream.
pub const pointer_gestures = @import("shell/pointer_gestures.zig");
/// zwp_relative_pointer_manager_v1 (shell/relative_pointer.zig):
/// unclaccelerated relative motion (24.8 deltas + a 64-bit utime).
pub const relative_pointer = @import("shell/relative_pointer.zig");
/// zwp_pointer_constraints_v1 (shell/pointer_constraints.zig): locked
/// and confined pointers.
pub const pointer_constraints = @import("shell/pointer_constraints.zig");
/// zwp_tablet_manager_v2 (shell/tablet.zig): the tablet/tool/pad
/// hardware registry and the full v2 announcement tree.
pub const tablet = @import("shell/tablet.zig");
/// wp_cursor_shape_manager_v1 (shell/cursor_shape.zig): per-pointer and
/// per-tablet-tool cursor shapes, gated on the device enter serial.
pub const cursor_shape = @import("shell/cursor_shape.zig");
/// wp_tearing_control_manager_v1 (shell/tearing_control.zig): the
/// per-surface async-presentation hint. Recording only — whether an
/// output actually tears is the present path's gate.
pub const tearing_control = @import("shell/tearing_control.zig");
/// ext_session_lock_manager_v1 (shell/session_lock.zig): the session
/// lock privilege boundary — input suppression and lock-surface
/// rendering while locked.
pub const session_lock = @import("shell/session_lock.zig");
/// zwlr_foreign_toplevel_manager_v1 (shell/foreign_toplevel.zig): the
/// compositor's own toplevels as client-visible handles.
pub const foreign_toplevel = @import("shell/foreign_toplevel.zig");
/// zwp_linux_dmabuf_v1 (shell/linux_dmabuf.zig): the dmabuf global,
/// registered only when a GBM device exists — advertising it without
/// one would be a lie a client can detect.
pub const linux_dmabuf = @import("shell/linux_dmabuf.zig");
pub const scene = @import("scene/scene.zig");
/// Surface→scene binding (scene/surface_node.zig): the library's
/// wl_surface→scene-node table. Tracks a surface through its
/// commit/unmap/destroy signals, keeps its scene node attached (texture
/// sync, damage translation) and implements the wl_surface enter/leave
/// wire events from the node's output association.
pub const surface_node = @import("scene/surface_node.zig");
/// M4 camera (scene/camera.zig): the world→screen view transform for the
/// canvas pass.
pub const camera = @import("scene/camera.zig");
pub const presentation = @import("presentation.zig");
/// zwlr_screencopy_manager_v1 (screencopy.zig): shm-based output capture.
pub const screencopy = @import("screencopy.zig");
/// gles2/EGL renderer (renderer/gles2.zig): GPU compositor via EGL + GLES2
/// through the gles2_c translate-c shim (wired in build.zig).
pub const gles2 = @import("renderer/gles2.zig");
/// Nested-wayland backend (backend/wayland.zig): our compositor acts as a
/// wayland CLIENT of a parent compositor (M5 real-session testing).
pub const wayland_backend = @import("backend/wayland.zig");

// zig 0.16 collects `test` blocks only from analyzed declarations;
// force analysis of every module so `zig build test` runs all tests.
comptime {
    _ = wire;
    _ = utils;
    // `_ = utils` forces the wrapper struct, not the nested modules' tests;
    // force each member so geom/damage/log/matrix tests are always collected.
    _ = utils.geom;
    _ = utils.damage;
    _ = utils.log;
    _ = utils.matrix;
    _ = utils.test_pump;
    _ = core;
    _ = buffers;
    _ = shm;
    _ = compositor;
    _ = seat;
    _ = cursor;
    _ = xkb;
    _ = subsurface;
    _ = data_device;
    _ = primary_selection;
    _ = backend;
    _ = libinput;
    _ = data_control;
    _ = session;
    _ = drm;
    // raylib/raylib_input import "raylib_c", which build.zig only wires
    // with -Denable_raylib; force their analysis only when it exists.
    if (build_options.enable_raylib) {
        _ = raylib;
        _ = raylib_input;
    }
    _ = output;
    _ = wl_output;
    _ = renderer;
    _ = shell;
    _ = layer_shell;
    _ = xdg_activation;
    _ = xdg_decoration;
    _ = fractional_scale;
    _ = xdg_output;
    _ = viewporter;
    _ = pointer_gestures;
    _ = relative_pointer;
    _ = pointer_constraints;
    _ = tablet;
    _ = cursor_shape;
    _ = tearing_control;
    _ = session_lock;
    _ = foreign_toplevel;
    _ = dmabuf;
    _ = linux_dmabuf;
    _ = scene;
    _ = surface_node;
    _ = camera;
    _ = canvas;
    _ = presentation;
    _ = screencopy;
    _ = gles2;
    _ = wayland_backend;
}

test "generated server bindings compile" {
    const wl = server.wl;
    _ = wl.Display;
    _ = wl.Registry;
    _ = wl.Callback;
    _ = wl.Buffer;
    _ = wl.Compositor;
    _ = wl.Surface;
    _ = wl.Region;
    _ = wl.Shm;
    _ = wl.Seat;
    _ = wl.Output;
    _ = server.xdg.WmBase;
    _ = server.wp.Viewporter;
    _ = server.wp.FractionalScaleManagerV1;
    _ = server.zwlr.LayerShellV1;
}
