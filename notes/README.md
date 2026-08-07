# Wayland Research — Index and Decisions

Synthesis of the research phase (2026-08-07), reconciled after the
improvement round (same day). Target: a Wayland compositor whose compositor
layer is wlroots/smithay-style and whose usage layer is a dynamicland-inspired
large 2D canvas. Stack: Zig 0.16.0. All facts come from the seven notes
indexed below. Additions are marked `[INFERENCE]`.

## Index

| File | Topic | Key findings |
|---|---|---|
| `wayland-compositor-basics.md` | Core protocol, shells, render loop, input, outputs, testing | wl_surface atomic commit state machine; xdg-shell configure/ack handshake; render loop = damage accumulate → vblank → composite → present → frame_done; headless + pixman gives a deterministic unprivileged test env; interface versions verified against wayland.xml; weston-test harness verified (in-process fixture compositor, TAP, 120 s timeout). |
| `zig-wayland.md` | Spec parsing and codegen for Zig | ifreund/zig-wayland ACTIVE, tracks zig 0.16 (v0.6.0, 2026-04-25; churn evidence per zig release since 0.13); all forks verified dead (last push 2022-2024); zig-wlroots v0.20.1 pin (2026-04-25) ↔ wlroots 0.20 line; build.zig.zon + Scanner recipe documented; addCSource workaround gone since v0.3.0. |
| `wlroots.md` | wlroots architecture and wlr_scene | Current stable wlroots = 0.20.2 (master 0.21.0-dev); local clone refreshed to 0.20.2. wlr_scene: integer positions, integer dest-size scale, 90° transforms, opacity, crop, filter; NO rotation/float zoom/shader hooks; damage ring, culling, texture caching, direct scanout built in (scanout conditions verified in wlr_scene.c); labcw + sway verified as scene users; tinywl is the minimal compositor reference. |
| `smithay.md` | Rust compositor library | No scene graph: flat `desktop::Space`, i32 positions, uniform scale, no per-element rotation. Pass object is the `Frame` trait (no `RenderPass` type); effect hooks `is_framebuffer_effect`/`capture_framebuffer` exist, blur is DIY; Vulkan backend = init-only wrapper (no renderer); callbacks are sequentially invoked with `&mut State`. Rust-vs-Zig porting cost is substantial. |
| `canvas-compositing.md` | Presenting surfaces on a large canvas | wlr_scene cannot do rotation or float zoom → custom camera pass mandatory: world `f64` coords, matrix `M = T·S·R·T`, camera rebase vs fp32 jitter, world-space damage + input via inverse camera; sharp zoom via fractional-scale/viewporter; 8-row prior-art table (niri, wayfire, wayvr, gnome magnifier.js, egui, ...); 9 risks. |
| `zio.md` | Async I/O framework for Zig | lalinsky/zio verified from source: created 2025-09-16, pushed 2026-08-05, 575 stars, NOT archived; three layers `zio.ev`/`zio.coro`/`zio.Runtime` (std.Io impl); zig-libuv archived 2023, libxev active. Verdict: DO NOT adopt for the compositor core loop (small fixed fd set, std.posix.poll / std.os.linux.epoll_*); revisit for companion network services only. |
| `dynamicland.md` | Dynamicland / Realtalk | Dead URLs recovered via Wayback (2019 Research Gallery capture, 2017 homepage); SAP/CDG affiliation VERIFIED via dynamicland.org/archive/2014/CDG + archived Bloomberg; no /2025/ /2026/ pages (404, verified 2026-08-07); commentary: Matuschak notes et al. Take: spatial persistence, live objects, multi-scale navigation, shared presence. Leave: paper/camera/projector substrate, anti-product philosophy. Impl details not public. |
| `zig-wayland-stack.md` | Zig wayland stack | Layered stack: wlroots 0.20.2 / zig-wlroots v0.20.1 / zig-wayland v0.6.0 / vendored XMLs; gaps (canvas pass DIY); reference reads. Now wired into build.zig: scanner generates ~13k-line bindings from protocols/ (server + client namespaces). |

## Stack recommendation

### (a) Compositor layer: wlroots over smithay

Recommendation: build on **wlroots via zig-wayland + zig-wlroots**, not smithay.

- The stack is Zig. Smithay is Rust; porting its protocol codegen, trait
  dispatch (`delegate_dispatch2!`), and `Element`/`Renderer` abstraction to
  Zig is substantial (smithay.md). Zig instead owns the render graph and
  shader plumbing directly — exactly where smithay is weakest (rotation,
  sub-pixel transforms, effects).
- zig-wlroots tracks Zig 0.16 + the wlroots 0.20 line (v0.20.1 pin, river
  is the proof of completeness) (zig-wayland.md, wlroots.md).
- Both scene models cap at flat 2D integer composition; the canvas layer
  needs a custom render pass on either stack (smithay.md, canvas-compositing.md).

### (b) Wayland spec parsing: upstream zig-wayland scanner

- Use upstream ifreund/zig-wayland (v0.6.0 or newer; current main tracks
  zig 0.16) as a build.zig.zon dependency. Only maintained line — all forks
  verified dead (seanpm2001 2022, zoriya 2023, kdchambers 2024).
- Scanner is Zig-native (own code generator, not a wayland-scanner wrapper),
  integrated into build.zig; generates `client`/`server`/`common` namespaces
  per global (`scanner.generate("wl_seat", 4)` trims to reachable
  interfaces). Covers wayland core, wayland-protocols, wlr protocols, custom
  XML. Options: `wayland_xml`, `wayland_protocols` (LazyPath), `ffi_import`.
- Pin the dependency hash; upgrade deliberately — every zig release since
  0.13 broke it (0.13→v0.2.0 2024-06-07, 0.14→v0.3.0 2025-03-07,
  0.15→v0.4.0 2025-08-22, 0.16→v0.6.0 2026-04-25) (zig-wayland.md).
- Local clone `~/projects/codeberg-ifreund-zig-wayland` refreshed to v0.6.0
  (2026-04-25, zig 0.16); matches the upstream release line.
- Vendor the XMLs (wayland.xml, wayland-protocols, wlroots.xml) and pass
  them via Options for hermetic NixOS builds; `PKG_CONFIG` is honored for
  the libwayland ffi pieces.

### (c) zio verdict

- Do NOT adopt zio for the compositor core loop. The loop is a small fixed
  fd set (wayland socket, libinput, DRM) driven synchronously by poll/epoll
  on one thread; zio adds a foreign event loop without benefit, and the
  compositor must own the loop for frame timing control. Verified std facts:
  `std.posix.poll` exists; epoll lives at `std.os.linux.epoll_*` (zio.md).
- Revisit zio only when network companion services (HTTP/WebSocket control,
  remote display forwarding) become a requirement; it is then the strongest
  candidate (active, Zig 0.16-native, `std.Io` drop-in) (zio.md).

### (d) Rendering: wlr_scene plus a custom canvas pass

- wlr_scene supports natively: integer position, integer dest-size scale,
  90-degree `wl_output_transform` rotation, opacity, crop, filter mode,
  per-output damage ring, visibility culling, texture caching, direct
  scanout, dmabuf feedback (wlroots.md, canvas-compositing.md).
- Not supported: arbitrary rotation, non-uniform or float zoom, perspective.
  A custom render pass drawing each visible surface as a quad with a camera
  matrix is mandatory for the canvas layer (canvas-compositing.md).
- Strategy: keep wlr_scene for the plain window/desktop layer and damage
  plumbing; add a camera pass that reuses the cached `wlr_texture` objects
  (zoom without content change costs only a re-draw, not a re-upload).
  Keep world state in `double`, snap to pixels only at draw; rebase the
  camera near the origin to avoid fp32 jitter (canvas-compositing.md).
- For sharp zoom, advertise `scale = max(1, camera zoom)` via
  viewporter/fractional-scale so clients redraw at native resolution
  (canvas-compositing.md).

### Named risks

1. **Zig churn breaks the scanner.** Every zig release since 0.13 required
   a zig-wayland update (0.13→v0.2.0, 0.14→v0.3.0, 0.15→v0.4.0,
   0.16→v0.6.0). Pin the dependency hash and upgrade deliberately
   (zig-wayland.md).
2. **zig-wlroots coverage is river-driven.** Bindings exist only for wlroots
   APIs river uses; missing parts must be added by hand. The wlroots C API is
   unstable (`WLR_USE_UNSTABLE`) and changes between releases
   (zig-wayland.md, wlroots.md).
3. **The custom canvas pass loses wlr_scene guarantees.** Rotation/float
   zoom bypasses the scene's damage ring and frame-done plumbing; damage
   accumulation, culling, and input remapping must be rebuilt in world space
   (canvas-compositing.md).

## Phased roadmap

1. **Scaffold** — done (2026-08-07): zig 0.16 project, zig-wayland v0.6.0
   pinned dep, Scanner wired, buildable skeleton generating `wayland.zig`.
2. **Spec codegen pipeline** — done (2026-08-07): wlroots target = 0.20
   line (clone refreshed at 0.20.2); wayland.xml, xdg-shell, viewporter,
   fractional-scale, wlr-layer-shell vendored in `protocols/`; server+
   client namespaces generated (wl_compositor v7 … zwlr_layer_shell_v1 v5);
   explicit XML paths — no pkg-config needed for codegen, only for linking
   libwayland (devenv.nix sets PKG_CONFIG_PATH).
3. **Minimal headless compositor** — Headless backend, wl_registry globals,
   xdg-shell handling, shm buffers; test with `WLR_BACKENDS=headless` +
   `WLR_RENDERER=pixman` and a weston client (weston-test harness verified
   for this). Deliverable: end-to-end protocol roundtrip.
4. **Output rendering with wlr_scene** — Outputs on the nested wayland
   backend (then DRM), wlr_scene tree, frame_done pacing, presentation
   timing. Deliverable: windows composite on a real output.
5. **Canvas rendering spike** — Custom render pass: camera matrix
   (world `f64` → screen), pan/zoom, world-space culling, reuse cached
   textures. Deliverable: arbitrary scale/rotation proven on a surface.
6. **Input remapping** — Pointer screen coords → invert camera → world →
   per-surface inverse transform → surface-local; focus rules in world
   space; tick `frame_done` during pan so clients repaint. Deliverable:
   click, scroll, and drag correct through the camera.
7. **Client-side scaling** — Implement viewporter and fractional-scale-v1;
   advertise `scale = max(1, zoom)`. Deliverable: sharp zoom for
   conforming clients.
8. **Dynamicland-style usage experiments** — Spatial persistence (position
   is state), live always-current objects, in-place authorability, shared
   presence. Deliverable: a usage-layer prototype validating the concepts
   from dynamicland.md.

## Open questions and risks

- **wlroots version target — resolved.** Current stable is 0.20.2 (master
  0.21.0-dev); zig-wlroots pins v0.20.1; both local clones refreshed
  2026-08-07 (wlroots 0.20.2, zig-wayland v0.6.0). Target the 0.20 line
  (wlroots.md, zig-wayland.md).
- **C-table workaround (zig issue #131) — resolved.** Gone since zig-wayland
  v0.3.0; current main and `example/hello` build without it (zig-wayland.md).
- **Weston test harness — resolved.** Verified: in-process fixture compositor
  via `wet_main`, weston-test protocol for input injection, screenshot
  capture, TAP output (wayland-compositor-basics.md).
- **Smithay pass API — resolved.** The pass object is the `Frame` trait
  (no `RenderPass` type); documented in smithay.md. Relevant only if the
  Rust path re-opens.
- **Damage under camera motion.** Whole-screen damage on pan is simplest and
  correct but costly; partial damage needs a world→screen region transform
  with output-scale rounding (canvas-compositing.md).
- **Blurry zoom for legacy clients.** Clients without viewporter or
  fractional-scale support stay blurry at high zoom; accept or filter
  NEAREST. Exact client behavior across toolkits at zoom > 1 is
  `[UNVERIFIED]` (canvas-compositing.md).
- **fp32 vertex precision.** Jitter appears around ~1e5 px from the origin;
  rebase the camera and compute world→screen in double before rounding
  (canvas-compositing.md).
- **Input remapping bugs.** wayvr documents mouse-mapping failures; add a
  debug overlay showing world coords early in phase 6 (canvas-compositing.md).
- **Realtalk implementation details are not public.** Anything beyond the
  FAQ-level description is `[UNVERIFIED]`; the usage layer must be designed
  from public narrative, not source (dynamicland.md).
- **zio interop spike.** If companion services arrive, `zio.ev` embedding
  against the compositor's real fds needs a one-day proof before adoption
  (zio.md).

## Repo references

- Foreign clones (read-only, `~/projects/<host>-<owner>-<repo>`):
  `freedesktop-wlroots-wlroots` (0.20.2), `github-Smithay-smithay` (v0.7.0),
  `codeberg-ifreund-zig-wayland` (v0.6.0, zig 0.16),
  `freedesktop-wayland-wayland` (1.26.0), `freedesktop-wayland-wayland-protocols`
  (1.49), `freedesktop-wayland-weston` (16.0.0), `codeberg-ifreund-zig-wlroots`
  (v0.20.1), `codeberg-river-river` (v0.4.0), `github-WayfireWM-wayfire`
  (v0.11.0), `github-YaLTeR-niri` (v26.04), `github-swaywm-sway` (1.11-rc2),
  `github-labwc-labwc` (0.20.1), `github-wayvr-org-wayvr` (v26.7.1).
- Architecture questions: deepwiki MCP (smithay and wlroots have wikis).
- VCS: jj only, never git.
