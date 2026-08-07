# Zig Wayland Stack

Layered stack for the project, verified 2026-08-07. Sources: zig-wayland.md,
wlroots.md, zio.md, README.md. Local clones in `~/projects/` are the ground
truth for every component below.

## Layers

```
DRM/KMS + libinput + libdrm/mesa   kernel + GL drivers
wlroots 0.20.2                     C compositor library (backends, renderers,
                                   wlr_scene, shells, input, dmabuf)
zig-wlroots v0.20.1                zig bindings over wlroots C API
zig-wayland v0.6.0                 protocol XML scanner + generated bindings
vendored XMLs                      wayland.xml, wayland-protocols, wlroots
your compositor (zig 0.16)         main loop, seat policy, canvas layer
zio.ev (optional)                  companion network services only
```

## Components

| Component | Version | Role | State |
|---|---|---|---|
| wlroots | 0.20.2 | compositor machinery: backends (drm/headless/wayland/x11), renderers (pixman/gles2/vulkan), wlr_scene, xdg/layer-shell, libinput→seat, linux-dmabuf, screencopy, presentation | stable release line; master 0.21.0-dev |
| zig-wlroots | v0.20.1 | zig bindings, @cImport-based; version scheme encodes wlroots release (0.20.1 ↔ 0.20 line) | coverage is river-driven: only APIs river uses; gaps bound by hand; C API `WLR_USE_UNSTABLE` |
| zig-wayland | v0.6.0 | Zig-native protocol scanner: parses XML specs at build time, generates client/server/common namespaces per global | tracks zig 0.16; every zig release since 0.13 broke it — pin the hash; forks all dead |
| libwayland | system | ffi pieces via pkg-config (`ffi_import` option) | pkg-config honored for hermetic NixOS builds |
| zio | v0.17.0 | async runtime (zio.ev/coro/Runtime) | NOT for the compositor core loop (small fixed fd set); revisit for HTTP/WebSocket companions; `do_not_call_callbacks` embedding mode exists |
| spec XMLs | wayland 1.26, wayland-protocols 1.49, wlroots 0.20.2 | codegen input | local at freedesktop-wayland-*, freedesktop-wlroots-wlroots/protocol/; vendor into this repo for hermetic builds |

## Gaps (no library provides these)

- Canvas/custom camera render pass — DIY (wlroots GLES2 path or own Vulkan
  pipeline via noapi; sokol-zig GLES3 is the strongest external candidate).
- Zig client toolkit — not needed; test clients via zig-wayland client
  bindings.
- zig-wlroots coverage beyond river's usage — extend by hand.
- Zig-version churn tax — each zig release requires a zig-wayland update.

## Reference reads (all local)

| Read | Path |
|---|---|
| End-to-end zig compositor | ~/projects/codeberg-river-river |
| Minimal wlroots compositor | ~/projects/freedesktop-wlroots-wlroots/tinywl/tinywl.c |
| Scene-graph usage | ~/projects/github-swaywm-sway, ~/projects/github-labwc-labwc |
| Custom render passes (canvas problem) | ~/projects/github-WayfireWM-wayfire |
| Canvas-like UX | ~/projects/github-YaLTeR-niri (scrollable, smithay-based) |
