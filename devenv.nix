{ pkgs, config, ... }:

let
  # wmww/wayland-debug: filter + breakpoint CLI over WAYLAND_DEBUG output
  # (notes/140 §3). Pure Python 3.8+; gdb mode additionally needs a
  # debug-symbol libwayland (see libwayland_debug_symbols.md upstream) —
  # run/pipe/file modes work with the stock libwayland. Pinned to master
  # 110592a (2026-08-12).
  wayland-debug-pkg = pkgs.stdenv.mkDerivation {
    pname = "wayland-debug";
    version = "master-110592a";
    src = pkgs.fetchzip {
      url = "https://github.com/wmww/wayland-debug/archive/110592ab1e6299281da7eab47419843ac0861023.tar.gz";
      sha256 = "063vpvxk6bpx72kmm106bs98iyhj9b54gx5bfnxaxdmw8jspsdnd";
    };
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/wayland-debug $out/bin
      cp -r main.py core backends frontends interfaces resources $out/lib/wayland-debug/
      # The upstream tarball ships a dangling git-submodule symlink
      # (resources/protocols/core/git-blame-ignore-revs) that trips the
      # noBrokenSymlinks check; it is not used at runtime.
      find $out/lib/wayland-debug -type l -delete
      makeWrapper ${pkgs.python3}/bin/python3 $out/bin/wayland-debug \
        --add-flags "$out/lib/wayland-debug/main.py" \
        --prefix PYTHONPATH : "$out/lib/wayland-debug"
      runHook postInstall
    '';
    meta = {
      description = "CLI for viewing, filtering, and setting breakpoints on Wayland protocol messages";
      license = pkgs.lib.licenses.mit;
      homepage = "https://github.com/wmww/wayland-debug";
    };
  };
in
{
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
    libinput
    libdrm
    udev
    pixman
    systemd
    libglvnd # EGL + GLES2 dev headers + libEGL/libGLESv2 (gles2 renderer)
    mesa # software GL (llvmpipe) so the gles2 renderer works headless
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
    # Protocol/client debugging tools (notes/140-wayland-debug-tools.md).
    # All are real Wayland clients — run them against our server (or a
    # reference compositor) to exercise the wire from outside.
    wayland-utils # wayland-info (globals/versions), wayland-display
    wl-clipboard # wl-copy / wl-paste — data_device + primary selection
    wev # input event viewer (keyboard/pointer/touch)
    grim # screencopy client (zwlr_screencopy_v1) — validates our screencopy
    slurp # grim region selection (-g "$(slurp)")
    wl-mirror # mirror a surface via zwlr_screencopy — visual debug
    weston # reference compositor + clients (weston-terminal, weston-debug, ...)
    wayland-debug-pkg # wmww/wayland-debug protocol filter/breakpoint CLI
  ];

  env = {
    # .pc files live in the dev output; the zig build links via pkg-config.
    PKG_CONFIG_PATH = "${pkgs.wayland.dev}/lib/pkgconfig:${pkgs.wayland-protocols}/lib/pkgconfig:${(pkgs.raylib.overrideAttrs { enableDebugging = true; dontStrip = true; separateDebugInfo = true; platform = "SDL"; static = true; })}/lib/pkgconfig";
    # PKG_CONFIG_PATH = "${pkgs.wayland.dev}"
    # Library path overrides (house pattern, cf. ~/projects/skript) so built
    # binaries find runtime libs (libraylib, X11, SDL) outside nix default paths.
    # LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.wayland pkgs.libxkbcommon (pkgs.raylib.overrideAttrs { enableDebugging = true; dontStrip = true; separateDebugInfo = true; platform = "SDL"; static = true; }) pkgs.xorg.libX11 pkgs.xorg.libXi pkgs.xorg.libXcursor pkgs.xorg.libXext ]}";
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath config.packages}";
    # INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath [ pkgs.wayland pkgs.libxkbcommon (pkgs.raylib.overrideAttrs { enableDebugging = true; dontStrip = true; separateDebugInfo = true; platform = "SDL"; static = true; }) pkgs.xorg.libX11 pkgs.xorg.libXi pkgs.xorg.libXcursor pkgs.xorg.libXext ]}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath config.packages}";
  };

  scripts.gate.exec = "zig-gate";
}
