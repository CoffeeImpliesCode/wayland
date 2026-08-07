# Stock: what wlroots & smithay provide

Inventory from local clones (2026-08-07): freedesktop-wlroots-wlroots 0.20.2,
github-Smithay-smithay 0.7.0, plus what ecosystem compositors add on top
(river, wayfire, sway, labwc, niri). Question answered: what do we get for
free, what must we write.

## wlroots 0.20.2 — mechanism, not policy

8 subsystems, 90+ public headers (`include/wlr/{types,backend,render,util,interfaces,xwayland}/`).

| Subsystem | Provides |
|---|---|
| backends | drm (KMS/atomic), headless, wayland (nested), x11, libinput, multi, session |
| renderers | gles2 (mature), pixman (mature), vulkan (production-ready) |
| allocators | gbm, shm, udmabuf, drm-dumb |
| types | wlr_compositor, wlr_surface/buffer (shm/dmabuf/egl/client), wlr_scene graph, xdg-shell, layer-shell, xwayland, seat/cursor/touch/tablet/switch, output/layout, data-control, primary-selection, idle, gamma, screencopy, foreign-toplevel, export-dmabuf, virtual-keyboard/pointer, fractional-scale, viewporter, single-pixel, tearing, output-management/power, xdg-activation |
| util | box/geometry, matrix, region, wlr_signal, wlr_list, damage ring, keyboard (xkb), output layout |
| protocols | 13 wlr-* XMLs in `protocol/` (ships with the library) |
| scene | declarative compositing: tree/node/output/buffer/rect, per-node int position + int scale + 90° transform + opacity + crop, damage ring, culling, texture cache, direct scanout, frame scheduling |

tinywl (1102 lines) shows the minimal wiring:
backend → renderer → allocator → compositor → scene → output_layout → xdg_shell →
cursor → seat → frame loop.

**Not provided**: window policy, IPC, config, shell UI, effects pipeline,
accessibility, notifications. "Mechanism (how), not policy (what/when/why)."

## smithay 0.7.0 — Rust framework

Workspace: `smithay` (core), `anvil` (reference compositor), `smallvil`
(minimal, winit-only), `smithay-drm-extras` (hotplug + display-info),
`wlcs_anvil` (WLCS compositor-testing bridge), `test_clients`.

| Area | Provides |
|---|---|
| wayland/ | protocol implementations: xdg-shell, layer-shell, session-lock, data-control, primary-selection, idle, input-method, tablet, xdg-foreign/output, fractional-scale, cursor-shape, single-pixel, tearing, security-context, ... |
| backend/ | drm, libinput, winit, x11, headless, udev, session, egl; renderer: gles2, glow, pixman, multigpu, vulkan; allocators |
| renderer traits | `Renderer`, `Frame` (clear/draw_solid/render_texture_*/finish), `Texture`, Import/Export/Bind/Offscreen traits; `Element`/`RenderElement` + `render_elements!` macro |
| elements | provided: SolidColor, Texture, Memory, WaylandSurface; transform wrappers: `RescaleRenderElement`, `CropRenderElement`, `RelocateRenderElement` (int geometry only, no rotation) |
| damage | `OutputDamageTracker` (buffer-age based) |
| desktop/ | `Space<E>`: flat 2D element plane — map/raise/stacking/output tracking, i32 coords; layer/popup/window helpers |
| reexports | calloop (event loop), wayland-server |
| anvil | full reference: state (1189 lines), input (1402), udev DRM (60KB), winit/x11 backends, shell handlers |

**Not provided**: window policy, IPC, config, effects, scene graph with
transforms (Space is flat).

## The compositor author's burden (re-implemented by every compositor)

1. Config parsing — INI (wayfire), i3-syntax (sway), Openbox XML (labwc),
   KDL (niri), Wayland protocol (river).
2. Keyboard shortcut handling — xkb, binding registration, modifier state.
3. IPC / external control — unix socket + JSON (sway, wayfire, niri) or
   custom Wayland protocol (river).
4. Window management policy — focus, stacking, rules, fullscreen/maximize.
5. Input device config — libinput settings from config.
6. Screen capture — wlr-screencopy / ext-image-copy-capture / portals.
7. State notification — event stream for bars/status (no standard exists).
8. Output management — layout, scale, transform, VRR, DPMS.
9. Decoration handling — SSD vs CSD negotiation, titlebar rendering.
10. Layer-shell panels — exclusive zones, keyboard interactivity, z-order.

## What ecosystem compositors add (the useful patterns)

| Compositor | Adds | Pattern to steal |
|---|---|---|
| river (~6K LOC zig) | compositor/WM split over custom Wayland protocols (`river-window-management-v1` XML 83KB) — WM is an external process; no built-in config/IPC | thin compositor core; policy in a separate process; protocol-defined control surface |
| wayfire (~25K LOC C++) | plugin architecture (~15 plugins: tile, scale, blur, cube, wobbly, wrot, ipc, decor), wf-config INI, custom render pipeline (`render-manager.cpp`), scene-node hooks for effects | effects/custom rendering on wlroots; plugin seams |
| sway (~20K LOC C) | container tree model, i3 config + IPC (JSON), swaybar/msg/nag; deliberately no effects | completeness reference for policy |
| labwc (~15K LOC C) | Openbox XML config, ~50 actions, full SSD theming, menus on xdg-popup; no IPC, no plugins | minimal clean policy layer |
| niri (~35K LOC Rust, smithay) | scrollable column layout (`ScrollingSpace`), KDL config live-reload, JSON IPC + EventStream, PipeWire screencasting, DBus portals, built-in screenshot UI | the spatial/canvas UX precedent; closest to our usage layer |

## Canvas-project implications

Free from wlroots: all protocol/backend/renderer/scene/input mechanism.
Smithay adds Rust traits + policy ergonomics we do not need (stack is zig).

Must build ourselves (in zig):
- Canvas spatial model + policy layer (position/scale/rotation of surfaces
  in world space, focus rules) — no library provides it.
- Custom camera render pass (wlr_scene stops at int positions/scales).
- Input remapping (screen → world → surface) and hit testing.
- Config/IPC/state-notification only if the usage layer needs them (river's
  split-protocol pattern is the model: compositor core + separate policy
  process).

Reference reads: tinywl (wiring), river (thin compositor + protocol split),
wayfire render-manager (custom pass), niri layout/scrolling (canvas UX),
sway/labwc (policy completeness).
