# Wayland compositor prototype

This repository combines research with an implemented Zig compositor library
and prototype server. The target is a Wayland compositor on a large 2D/3D
canvas. The package is version `0.0.0` and requires Zig `0.16.0`.

The protocol stack, compositor modules, renderers, backends, test server,
client, and protocol probe exist. `src/main.zig` remains a generated-binding
summary. Use `run-server` for the compositor prototype.

## Repository outline

- `build.zig` runs the `zig-wayland` scanner and defines all artifacts and steps.
- `build.zig.zon` pins `zig-wayland`, Zio, and Tracy.
- `devenv.nix` supplies the compiler, native libraries, protocol tools, and `gate`.
- `protocols/` contains the vendored Wayland, wayland-protocols, and wlroots XML.
- `src/root.zig` is the reusable compositor library root.
- `src/core/`, `buffers/`, `compositor/`, `shell/`, and `output/` implement
  protocol and compositor state.
- `src/scene/` and `renderer/` implement the canvas, camera, Pixman, and GLES2 paths.
- `src/backend/` contains headless, raylib, nested Wayland, DRM, and libinput backends.
- `src/server/` contains the prototype server, test client, test root, and `rtprobe`.
- `notes/` contains research, audits, decisions, and the compositor library specification.
- `scripts/` contains local client, demo, and VM harnesses.

## Local contracts

- Treat `notes/zig-compositor-lib-spec.md` as the library design authority.
- Keep reusable compositor behavior in library modules under `src/`.
  Keep application wiring and policy in `src/server/`.
- Re-export public library modules from `src/root.zig`.
- When you add a module, update the root `comptime` analysis list.
  Zig `0.16.0` otherwise omits tests from unanalyzed declarations.
- Edit vendored XML in `protocols/` when protocol sources change.
  Never edit generated bindings in `.zig-cache/`.
- The build defaults to `ReleaseSafe`.
  The test client and `rtprobe` always use `ReleaseFast`.
- Raylib support defaults on through `-Denable_raylib`.
  Tracy defaults off through `-Denable_tracy`.
- Use the devenv or direnv environment for native builds.
  The build resolves Wayland, xkbcommon, Pixman, DRM, libinput, EGL, and GLES2
  through system libraries and `pkg-config`.
- Name research notes `NNN-topic.md`. Put one topic in each file.
- Write facts first. Cite sources. Mark unverified claims with `[INFERENCE]`.
- Do not run code gates for a note-only change.
- Treat the local wlroots, Smithay, KWin, and `zig-wayland` clones as read-only
  design references.
- Use `jj` for repository mutations. Do not use Git mutation commands.

## Commands

Run these commands from the repository root:

- `devenv shell -c "zig build"` builds with the required native environment.
- `zig build` generates protocol bindings and installs all executable artifacts.
- `zig build run` runs the binding-summary executable.
- `zig build run-server -- <args>` runs the compositor prototype.
- `zig build run-client -- <args>` runs the client against a live server.
- `zig build run-rtprobe -- <args>` runs the adversarial probe against a live server.
- `zig build test` runs the library and server tests.
- `zig build check` compiles the main executable and both test artifacts.
- `zig build -Denable_raylib=false` disables the raylib backend.
- `zig build -Denable_tracy=true` enables server Tracy instrumentation.
- In the devenv shell, `gate` runs the configured project checks.

## NixOS, Development Environment & Shared Notes

- This host runs NixOS. Never install system or development libraries imperatively.
  Declare dependencies, headers, runtime libraries, and tools in `devenv.nix`.
- Use the repository's direnv/devenv environment. Run `direnv allow` after
  environment changes. Use `devenv shell` for one-off shells.
- Put durable architecture, design, protocol, and experiment notes under `docs/`.
- Put cross-project or private agent handoff notes in `~/.agents/agent-notes/`.
  Never commit these notes.
