{ pkgs, ... }:

rec {
  # zig 0.16 + wayland dev environment (house convention).
  # Debug backend (raylib window) follows the house patterns:
  # - skript: debug symbols, SDL platform, static link
  # - vain2-old: explicit X11 runtime deps
  packages = with pkgs; [
    zig
    pkg-config
    wayland
    wayland-protocols
    libxkbcommon # SDL/wayland video driver dep (raylib backend)
    (raylib.overrideAttrs {
      enableDebugging = true;
      dontStrip = true;
      separateDebugInfo = true;
      platform = "SDL";
      static = true;
    })
    xorg.libX11
    xorg.libXi
    xorg.libXcursor
    xorg.libXext
  ];

  env = {
    # .pc files live in the dev output; the zig build links via pkg-config.
    PKG_CONFIG_PATH = "${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig:${(pkgs.raylib.overrideAttrs { enableDebugging = true; dontStrip = true; separateDebugInfo = true; platform = "SDL"; static = true; })}/lib/pkgconfig";
    # PKG_CONFIG_PATH = "${pkgs.wayland.dev}"
    # Library path overrides (house pattern, cf. ~/projects/skript) so built
    # binaries find runtime libs (libraylib, X11, SDL) outside nix default paths.
    # LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.wayland pkgs.libxkbcommon (pkgs.raylib.overrideAttrs { enableDebugging = true; dontStrip = true; separateDebugInfo = true; platform = "SDL"; static = true; }) pkgs.xorg.libX11 pkgs.xorg.libXi pkgs.xorg.libXcursor pkgs.xorg.libXext ]}";
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    # INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath [ pkgs.wayland pkgs.libxkbcommon (pkgs.raylib.overrideAttrs { enableDebugging = true; dontStrip = true; separateDebugInfo = true; platform = "SDL"; static = true; }) pkgs.xorg.libX11 pkgs.xorg.libXi pkgs.xorg.libXcursor pkgs.xorg.libXext ]}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
  };
}
