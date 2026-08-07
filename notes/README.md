# Wayland Research — Index and Decisions

Synthesis of the research phase (2026-08-07). Target: a Wayland compositor
whose compositor layer is wlroots/smithay-style and whose usage layer is a
dynamicland-inspired large 2D canvas. Stack: Zig 0.16.0. All facts come from
the seven notes indexed below. Additions are marked `[INFERENCE]`.

## Index

| File | Topic | Key findings |
|---|---|---|
| `wayland-compositor-basics.md` | Core protocol, shells, render loop, input, outputs, testing | wl_surface atomic commit state machine; xdg-shell configure/ack handshake; render loop = damage accumulate → vblank → composite → present → frame_done; headless + pixman gives a deterministic unprivileged test env. |
| `zig-wayland.md` | Spec parsing and codegen for Zig | ifreund/zig-wayland is an ACTIVE Zig-native scanner (v0.7.0-dev, min_zig 0.16.0, pushed 2026-07-14); no fork needed; all forks dead; zig-wlroots (Zig 0.16 + wlroots 0.20) is river-driven and hand-written. |
| `wlroots.md` | wlroots architecture and wlr_scene | C library; wlr_scene is declarative basic-2D composition: integer positions, no node rotation/scale, opacity only on buffers, no shader hooks; damage ring, culling, texture caching, direct scanout built in; effects need a custom render pass. |
| `smithay.md` | Rust compositor library | Broad protocol coverage and production DRM path, but no scene graph: flat `desktop::Space` with i32 positions, uniform scale only, no per-element rotation; Rust-vs-Zig porting cost is substantial. |
| `canvas-compositing.md` | Presenting surfaces on a large canvas | wlr_scene cannot do rotation or float zoom; custom camera pass (world double coords → screen) is mandatory; viewporter/fractional-scale for sharp zoom; input = invert camera → world → surface-local. |
| `zio.md` | Async I/O framework for Zig | lalinsky/zio is active, Zig 0.16-native, a `std.Io` implementation; verdict: DO NOT adopt for the compositor core loop (small fixed fd set, hand-rolled poll/epoll); revisit for companion network services only. |
| `dynamicland.md` | Dynamicland / Realtalk | Take: spatial persistence, live always-current objects, multi-scale navigation as memory, in-place authorability, shared presence. Leave: paper/camera/projector substrate, anti-product philosophy. Implementation details not public. |

## Stack recommendation

### (a) Compositor layer: wlroots over smithay

Recommendation: build on **wlroots via zig-wayland + zig-wlroots**, not smithay.

- The stack is Zig. Smithay is Rust; porting its protocol codegen, trait
  dispatch (`delegate_dispatch2!`), and `Element`/`Renderer` abstraction to
  Zig is substantial (smithay.md). Zig instead owns the render graph and
  shader plumbing directly — exactly where smithay is weakest (rotation,
  sub-pixel transforms, effects).
- zig-wlroots tracks Zig 0.16 + wlroots 0.20; river is a full compositor
  proving the bindings complete enough for real use (zig-wayland.md).
- Both scene models cap at flat 2D integer composition; the canvas layer
  needs a custom render pass on either stack (smithay.md, canvas-compositing.md).

### (b) Wayland spec parsing: upstream zig-wayland scanner

- Use upstream ifreund/zig-wayland (main, v0.7.0-dev or newer) as a
  build.zig.zon dependency. It is the only maintained line and already
  targets Zig 0.16.0.
- Scanner is Zig-native (own code generator, not a wayland-scanner wrapper),
  integrated into build.zig; generates `client`/`server`/`common` namespaces
  per global (`scanner.generate("wl_seat", 4)` trims to reachable
  interfaces). Covers wayland core, wayland-protocols, wlr protocols, custom
  XML.
- Forks (seanpm2001, kdchambers, zoriya) are all dead; no fork needed.
  Alternative tiawl/wayland.zig is a C-headers package, not a scanner.
- Do NOT use the stale local clone `~/projects/codeberg-ifreund-zig-wayland`
  (Zig 0.13 era) as a reference.
- For server-side handling the same scan yields xdg-shell, layer-shell, and
  wlr protocols. Vendor the XMLs and pass `Options.wayland_xml` /
  `Options.wayland_protocols` for hermetic NixOS builds.

### (c) zio verdict

- Do NOT adopt zio for the compositor core loop. The loop is a small fixed
  fd set (wayland socket, libinput, DRM) driven synchronously by poll/epoll
  on one thread; zio adds a foreign event loop without benefit, and the
  compositor must own the loop for frame timing control (zio.md).
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

1. **Zig churn breaks the scanner.** Each Zig release historically broke
   zig-wayland (0.13 → 0.14 → 0.16 all required updates). Pin the dependency
   hash and upgrade deliberately (zig-wayland.md).
2. **zig-wlroots coverage is river-driven.** Bindings exist only for wlroots
   APIs river uses; missing parts must be added by hand. The wlroots C API is
   unstable (`WLR_USE_UNSTABLE`) and changes between releases
   (zig-wayland.md, wlroots.md).
3. **The custom canvas pass loses wlr_scene guarantees.** Rotation/float
   zoom bypasses the scene's damage ring and frame-done plumbing; damage
   accumulation, culling, and input remapping must be rebuilt in world space
   (canvas-compositing.md).

## Phased roadmap

1. **Scaffold** — Zig 0.16 project with `build.zig.zon`; add zig-wayland as
   a pinned dependency; wire the scanner step per `example/hello`.
   Deliverable: buildable skeleton that generates `wayland.zig`.
2. **Spec codegen pipeline** — Pin wayland.xml, wayland-protocols, wlroots
   XML; generate client+server namespaces for wl_compositor, wl_shm,
   xdg-shell; vendor XMLs for hermetic builds. Deliverable: reproducible
   codegen, no configure-time pkg-config surprise.
3. **Minimal headless compositor** — Headless backend, wl_registry globals,
   xdg-shell handling, shm buffers; test with `WLR_BACKENDS=headless` +
   `WLR_RENDERER=pixman` and a weston client. Deliverable: end-to-end
   protocol roundtrip.
4. **Output rendering with wlr_scene** — Outputs on the nested wayland
   backend (then DRM), wlr_scene tree, frame_done pacing, presentation
   timing. Deliverable: windows composite on a real output.
5. **Canvas rendering spike** — Custom render pass: camera matrix
   (world `double` → screen), pan/zoom, world-space frustum culling, reuse
   cached textures. Deliverable: arbitrary scale/rotation proven on a
   surface.
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

- **wlroots version target.** The local wlroots clone is 0.18.3; river pins
  zig-wlroots v0.20.1 ↔ wlroots 0.20. `[UNVERIFIED]` whether zig-wlroots
  publishes a 0.18 binding — decide the target wlroots version first, or
  refresh the clone (wlroots.md, zig-wayland.md).
- **C-table workaround (zig issue #131).** `[UNVERIFIED]` whether the 0.16
  toolchain still needs `addCSource` for exotic protocols; current main and
  `example/hello` build without it, so assume resolved (zig-wayland.md).
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
- **Weston test harness.** `weston-test` protocol and runner details are
  `[UNVERIFIED]`; verify before relying on them for compositor tests
  (wayland-compositor-basics.md).
- **Smithay RenderPass API.** Skimmed only; relevant only if the Rust path
  is re-opened (canvas-compositing.md).
- **zio interop spike.** If companion services arrive, `zio.ev` embedding
  against the compositor's real fds needs a one-day proof before adoption
  (zio.md).

## Repo references

- Foreign clones (read-only): `~/projects/freedesktop-wlroots-wlroots`,
  `~/projects/github-Smithay-smithay`,
  `~/projects/codeberg-ifreund-zig-wayland` (stale — verify upstream).
- Architecture questions: deepwiki MCP (smithay and wlroots have wikis).
- VCS: jj only, never git.
