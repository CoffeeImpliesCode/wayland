{ pkgs, ... }:
{
  # zig 0.16 + wayland dev environment (house convention).
  packages = [
    pkgs.zig
    pkgs.pkg-config
    pkgs.wayland
    pkgs.wayland-protocols
  ];

  # .pc files live in the dev output; the zig build links via pkg-config.
  env.PKG_CONFIG_PATH = "${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig";
}
