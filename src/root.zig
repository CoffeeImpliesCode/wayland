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
