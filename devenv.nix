{ pkgs, ... }:
{
  # zig 0.16 + wayland dev environment (house convention).
  packages = [
    pkgs.zig
    pkgs.pkg-config
    pkgs.wayland
    pkgs.wayland-protocols
    pkgs.raylib # debug backend (windowed output visualization)
  ];

  # .pc files live in the dev output; the zig build links via pkg-config.
  env.PKG_CONFIG_PATH = "${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig";
}
