const std = @import("std");
const wayland = @import("wayland");

pub fn main() !void {
    const wl = wayland.server.wl;
    std.debug.print("wayland skeleton — generated server bindings\n", .{});
    std.debug.print("  wl_compositor v{d}  wl_surface v{d}  wl_shm v{d}  wl_seat v{d}  wl_output v{d}\n", .{
        wl.Compositor.generated_version,
        wl.Surface.generated_version,
        wl.Shm.generated_version,
        wl.Seat.generated_version,
        wl.Output.generated_version,
    });
    std.debug.print("  xdg_wm_base v{d}  wp_viewporter v{d}  wp_fractional_scale_v1 v{d}  zwlr_layer_shell_v1 v{d}\n", .{
        wayland.server.xdg.WmBase.generated_version,
        wayland.server.wp.Viewporter.generated_version,
        wayland.server.wp.FractionalScaleManagerV1.generated_version,
        wayland.server.zwlr.LayerShellV1.generated_version,
    });
}
