# Wayland compositor

An experimental Wayland compositor library and server written in Zig.
It includes a canvas scene graph, Pixman and GLES2 renderers, and headless,
Raylib, nested Wayland, and DRM/KMS backends.

## Requirements

- Linux and Zig 0.17.0.
- `pkg-config`, Wayland client/server libraries, xkbcommon, Pixman, libdrm,
  GBM, EGL/GLES2, libinput, and libudev.
- Raylib for the default debug-backend build.
- Mesa or another EGL/GLES2 driver for rendering.

Install the development headers and make the libraries discoverable through
`PKG_CONFIG_PATH`. The Nix development environment supplies the native packages:

```sh
devenv shell
```

Provide Zig 0.17.0 separately. With the anyzig shim, the package manifest selects
that version.

## Build

```sh
zig build
zig build test
zig build check
zig build docs
zig build run
```

The default optimization mode is `safe`. Override it with
`-Doptimize=debug|safe|fast|small`. Raylib is enabled by default; disable it with
`-Denable_raylib=false`. Tracy instrumentation is disabled by default; enable it
with `-Denable_tracy=true`.

The build installs `wayland` (a generated-binding summary), `wayland-server`,
`wayland-client`, and `rtprobe` under `zig-out/bin`. Documentation goes into
`zig-out/docs`.

## Run

The server uses a headless output by default. For a debug window:

```sh
WAYLAND_BACKEND=raylib zig build run-server
```

Select `WAYLAND_BACKEND=nested` to run under an existing compositor, or
`WAYLAND_BACKEND=drm` for native KMS output. The nested backend needs the parent
`WAYLAND_DISPLAY` socket. DRM and libinput need access to the relevant devices
and session. `WAYLAND_LIBINPUT=1` enables libinput.

`WAYLAND_RENDERER=gles2` selects GLES2; the default renderer is Pixman.
`WAYLAND_RUN_FRAMES=N` stops after N rendered frames (zero runs indefinitely).
The server prints `WAYLAND_SOCKET=<name>` when ready. Set `WAYLAND_DISPLAY` to
that socket for clients:

```sh
WAYLAND_DISPLAY=<name> zig build run-client
WAYLAND_DISPLAY=<name> zig build run-rtprobe
```

The client and protocol probe require a running server. Scripts under `scripts/`
provide Raylib demonstrations and NixOS/QEMU DRM tests. The VM workflows require
Nix and QEMU; they also need the graphics and input devices that each script
configures.

## Source layout

- `src/root.zig`: reusable `wayland` module and public exports.
- `src/core`, `buffers`, `compositor`, `shell`, `output`: protocol and device state.
- `src/scene`, `renderer`: scene graph, canvas, Pixman, and GLES2.
- `src/backend`: output, input, and session backends.
- `src/server`: server policy, test client, and adversarial protocol probe.
- `protocols`: upstream XML used by the pinned zig-wayland scanner.

Edit protocol XML rather than generated bindings. Keep reusable compositor logic
in `src/` and application policy in `src/server/`.
Unlink signal listeners before freeing their storage, including inside destroy
callbacks.

## License

No project-wide license is declared. Protocol XML files retain their upstream
copyright and license notices.
