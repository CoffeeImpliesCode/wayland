# Wayland compositor prototype

Zig `0.16.0` (`0.0.0` package): a reusable compositor library and prototype server for a large 2D/3D canvas. `src/main.zig` only summarizes generated bindings; `run-server` starts the compositor.

## Structure and contracts

- Keep reusable protocol and compositor logic in `src/`; keep application wiring and policy in `src/server/`.
- `src/root.zig` re-exports public modules. Add each new module to its root `comptime` analysis list, or Zig 0.16.0 omits its tests.
- `build.zig` scans the vendored Wayland, wayland-protocols, and wlroots XML in `protocols/` with `zig-wayland`. Edit XML, not generated `.zig-cache/` bindings. `build.zig.zon` pins `zig-wayland`, Zio, and Tracy.
- `src/core/`, `buffers/`, `compositor/`, `shell/`, and `output/` hold protocol state. `src/scene/` and `renderer/` implement the canvas, camera, Pixman, and GLES2 paths. `src/backend/` holds headless, raylib, nested Wayland, DRM, and libinput backends. `src/server/` holds the server, client, and `rtprobe`.
- The build defaults to `ReleaseSafe`; the test client and `rtprobe` use `ReleaseFast`. Raylib defaults on (`-Denable_raylib`); Tracy defaults off (`-Denable_tracy`).
- `devenv.nix` sets `ZIG_GLOBAL_CACHE_DIR = ".zig-global-cache"`, so this project never shares `~/.cache/zig` with other Zig work on the host. Without it a wedged build-runner convoy in the shared cache blocks `zig build` with no output at all. Never remove it; the directory is gitignored.
- Keep local wlroots, Smithay, KWin, and `zig-wayland` clones read-only. Use `jj`, not Git mutation commands.

## Commands (repository root)

- `devenv shell -c "zig build"` builds with native dependencies; `zig build` generates bindings and installs artifacts.
- `zig build run` shows the binding summary. `zig build run-server -- <args>` starts the compositor.
- `zig build run-client -- <args>` and `zig build run-rtprobe -- <args>` run against a live server.
- `zig build test` runs library and server tests; `zig build check` compiles the main executable and both test artifacts. In devenv, `gate` runs configured checks.
- `zig build -Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` overrides the optimization mode. The default is `ReleaseSafe`, so the demo server is not silently slowed to Debug.
- `zig build -Denable_raylib=false` disables raylib; `zig build -Denable_tracy=true` enables server Tracy instrumentation.
