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

const geom_mod = @import("utils/geom.zig");
const damage_mod = @import("utils/damage.zig");
const log_mod = @import("utils/log.zig");
const display_mod = @import("core/display.zig");

pub const utils = struct {
    pub const geom = geom_mod;
    pub const damage = damage_mod;
    pub const log = log_mod;
};

pub const core = struct {
    pub const display = display_mod;
};

pub const buffers = @import("buffers/buffer.zig");
pub const shm = @import("buffers/shm.zig");
pub const compositor = @import("compositor/compositor.zig");
pub const backend = @import("backend/backend.zig");
/// Headless backend implementation (backend/headless.zig): one virtual
/// output paced by a wire event loop timer. Exported for consumers that
/// run without a GPU (test servers, examples).
pub const headless = @import("backend/headless.zig");
pub const output = @import("output/output.zig");
pub const renderer = @import("renderer/renderer.zig");
/// The pixman CPU renderer implementation (renderer/pixman.zig): the
/// Framebuffer target plus PixmanRenderer.create/importMemory. Exported
/// for consumers that render with pixman (test servers, examples).
pub const pixman = @import("renderer/pixman.zig");
pub const shell = @import("shell/xdg.zig");

// zig 0.16 collects `test` blocks only from analyzed declarations;
// force analysis of every module so `zig build test` runs all tests.
comptime {
    _ = wire;
    _ = utils;
    _ = core;
    _ = buffers;
    _ = shm;
    _ = compositor;
    _ = backend;
    _ = output;
    _ = renderer;
    _ = shell;
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
