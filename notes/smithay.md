# Smithay — Rust Wayland Compositor Library

Research note. 2026-08-07. Sources: local clone
`~/projects/github-Smithay-smithay` (tag v0.7.0, HEAD 5fb12b87 =
v0.7.0-407, master post-0.7.0), DeepWiki (deepwiki.com/Smithay/smithay),
anvil source in the clone.

Library (not a compositor binary) for writing Wayland compositors in
Rust. v0.7.0, MIT, edition 2024, MSRV 1.85. Handles system interaction
(session, DRM, input) and Wayland protocol; window management and
drawing policy are left to the author. Reference compositor: `anvil`.
Source: https://github.com/Smithay/smithay, README.md.

## Crate / workspace map

Workspace members (Cargo.toml): `smithay` (core), `anvil` (reference
compositor, winit/udev/x11), `smallvil` (minimal example),
`smithay-drm-extras`, `wlcs_anvil` (WLCS conformance cdylib),
`test_clients`. Core modules (src/lib.rs): `backend`, `desktop`,
`input`, `output`, `utils`, `wayland`, `xwayland` (feature-gated),
`reexports` (re-exports `calloop`, `wayland_server`).

## Feature flags (module map)

Backends: `backend_drm`, `backend_gbm`, `backend_egl`, `backend_libinput`,
`backend_udev`, `backend_winit`, `backend_x11`, `backend_vulkan`,
`backend_session_libseat`. Renderers: `renderer_gl`, `renderer_glow`,
`renderer_pixman` (CPU), `renderer_multi`, `renderer_test`. Protocols:
`wayland_frontend` (wayland-server + protocols), `xwayland`, `desktop`,
`backend_libei`. Source: Cargo.toml:89-115, DeepWiki "Feature Flags".

## Architecture

Three layers:
1. `backend` — OS/hardware: DRM/KMS, GBM allocator, libinput, libseat
   session, udev hotplug, winit/x11 nested backends, EGL context.
   Central traits: `Renderer`, `Allocator`, `InputBackend`.
2. `wayland` — protocol handlers. State/Handler/Delegate pattern: each
   module has a `*State` struct (`CompositorState`, `XdgShellState`,
   `WlrLayerShellState`, `SeatState`), a `*Handler` trait the compositor
   implements, and a `delegate_dispatch2!` macro wiring it into
   `wayland_server::Dispatch` (src/wayland/mod.rs).
3. `desktop` — optional helpers: `Space`, `Window`, `LayerSurface`,
   `PopupManager`, `LayerMap`.

Event loop: `calloop` 0.14. Threading model is DOCUMENTED (src/lib.rs):
callbacks receive `&mut State`; "the callback invocation is *always*
sequential", so a centralized mutable state needs no synchronization.
That State is therefore not `Sync` follows from the documented model
CORRECTED 2026-08-09: `SyncPoint`/`wait` are present in the v0.7.0 tag itself — src/backend/renderer/sync/{egl.rs,mod.rs} — not master-only. New in master:
`Frame::finish()` returns a `SyncPoint`, `Renderer::wait(&SyncPoint)`
waits on it (src/backend/renderer/sync/; anvil waits after
`render_frame`, anvil/src/udev.rs:1662) — cross-thread rendering is
still the author's job, but the handoff primitive now exists.

## wayland protocol coverage (src/wayland/)

Very broad: nearly all stable + staged + unstable protocols. Highlights:
`compositor/` (CompositorState, transaction, tree, cache), `buffer/`,
`shm/`, `socket.rs`, `seat/` (Seat, KeyboardHandle, PointerHandle,
TouchHandle), `shell/xdg/`, `shell/wlr_layer/`, `shell/kde/`, `output/`,
`presentation/`, `dmabuf/`, `viewporter/`, `fractional_scale/`,
`single_pixel_buffer/`, pointer constraints/gestures/warp,
`cursor_shape.rs`, `selection/` (data_device, primary_selection,
wlr_data_control, ext_data_control), `drm_lease/`, `drm_syncobj/`,
`session_lock/`, `idle_inhibit/`, `idle_notify/`, `input_method/`,
`text_input/`, `virtual_keyboard/`, `tablet_manager/`, `xdg_activation/`,
`xdg_foreign/`, xdg toplevel icon/tag/system_bell,
`keyboard_shortcuts_inhibit/`, `security_context/`,
`foreign_toplevel_list/`, screencopy (`image_capture_source/`),
`content_type/`, `background_effect/`, `alpha_modifier/`,
`commit_timing/`, `fifo/`, `xwayland_shell.rs`.

## Backends and renderers

- DRM: `backend/drm/` — DrmDevice, DrmSurface, GbmBufferedSurface,
  `DrmCompositor` (plane assignment, direct scan-out, atomic test),
  DrmOutputManager, DrmOutput, GbmFramebufferExporter.
- Input: `backend/libinput/` (`LibinputInputBackend`), `backend/udev.rs`
  (hotplug), `backend/libei/`; session: `backend/session/` (libseat).
- Nested dev: `backend/winit/`, `backend/x11/` (DRI3/present).
- Renderers: `renderer/gles/` (GLES2/3, ~130KB), `renderer/glow.rs`,
  `renderer/pixman/`, `renderer/multigpu/` (`GpuManager`,
  `MultiRenderer`, `GbmGlesBackend`), `renderer/element/`
  (Element/RenderElement/AsRenderElements), `renderer/damage/`
  (`OutputDamageTracker`), `renderer/sync/` (`SyncPoint`, master).
  Allocators: GBM, dumb buffers, dmabuf.
- Vulkan: `backend/vulkan/` is a THIN ash wrapper — `Instance`
  (extensions, layers) and `PhysicalDevice::enumerate` only; module docs
  state it "does not provide abstractions for logical devices, rendering
  or memory allocation" (src/backend/vulkan/mod.rs). No Vulkan
  `Renderer`/`Frame` exists (no `renderer_vulkan` feature;
  `backend_vulkan` is default-on; `examples/vulkan.rs` is instance init
  only). Maturity: init helpers, not a renderer.

## Scene graph story — the key finding

Smithay has NO dedicated `scene` module (verified: no `src/scene/`, no
`Scene` struct anywhere). Scene-graph duties are split:

1. `desktop::space::Space<E: SpaceElement>` — 2D layout plane. Elements
   and `Output`s map onto it. API: `map_element(element, location,
   activate)`, `map_element_above`, `relocate_element`, `raise_element`,
   `lower_element`, `unmap_elem`, `element_under(point)`,
   `output_under`, `elements()`, `outputs()`,
   `render_elements_for_region`, `render_elements_for_output`, free fn
   `render_output(...)`. Position: `Point<i32, Logical>`. Z-order:
   mapping order + `RenderZindex` (Background=10, Bottom=20, Shell=30,
   Top=40, Overlay=60; src/desktop/space/element/mod.rs:26). Source:
   src/desktop/space/{mod,element/mod}.rs.
2. Per-element rendering transforms exist only as WRAPPER elements in
   `backend::renderer::element::utils::elements`:
   `RescaleRenderElement<E>` (uniform `Scale<f64>`), `CropRenderElement<E>`
   (crop rect), `RelocateRenderElement<E>` (offset; `Relocate` enum
   Absolute/Relative), `constrain_render_elements` /
   `constrain_as_render_elements` (`ConstrainAlign`,
   `ConstrainScaleBehavior` CutOff/Fit). Anvil composes: `Preview =
   CropRenderElement<RelocateRenderElement<RescaleRenderElement<
   WindowRenderElement<R>>>>` (anvil/src/render.rs:58).
3. Rotation: NO per-element rotation API. Only `utils::Transform`
   (Normal/90/180/270 + flips, src/utils/geometry.rs:1869) at output
   level (`Output::current_transform`) and as `Element::transform()`
   reporting buffer rotation for scan-out.

Verdict: flat 2D scene, integer positions, z-order; uniform scale and
crop via render-time wrapper elements; arbitrary per-element rotation NOT
supported; no retained transform hierarchy or group nodes. Rotation must
be done by the compositor author — consistent with canvas-compositing.md
(both stacks cap at flat 2D integer composition).

## Custom render pass — what the API actually allows

Render loop (anvil udev, anvil/src/udev.rs): `DrmEvent::VBlank(crtc)`
(795) -> `frame_finish` (1201: presentation feedback, VBlank-throttle
timer) -> `render` (1389) -> `pre_repaint` (1424) -> `output_elements` +
`surface.drm_output.render_frame(renderer, &elements, clear_color,
frame_mode)` (1659; plane offload or GLES fallback) -> next VBlank.
winit path: per-frame `render_output` (anvil/src/winit.rs:349).

Plug points for a custom pass:
1. Elements: implement `Element` (+ `RenderElement<R>` for drawables).
   Anvil merges its own `custom_elements` (cursor, DnD icon, FPS) with
   the Space's via `output_elements()` (anvil/src/render.rs:139), which
   calls `space::space_render_elements::<_, WindowElement, _>(renderer,
   [space], output, 1.0)`.
2. Composite: `OutputDamageTracker::render_output(renderer, framebuffer,
   age, elements, clear_color)` (renderer/damage/mod.rs:326) computes
   damage (age 0 = full redraw) and internally calls
   `Renderer::render(framebuffer, output_size, dst_transform)`
   (renderer/mod.rs:427) to obtain the pass.

The pass object is the `Frame` trait (renderer/mod.rs:270) — there is NO
`RenderPass` type in smithay. Methods: `clear(color, at)`, `draw_solid(
dst, damage, color)`, `render_texture_at(texture, pos, texture_scale,
output_scale: Scale<f64>, src_transform, damage, opaque_regions, alpha)`,
`render_texture_from_to(texture, src: Rect<f64, BufferCoord>, dst: Rect<
i32, Physical>, ...)`, `finish() -> Result<SyncPoint, _>`;
`Offscreen<Target>::create_buffer` renders to a texture target.

Per-element quad transforms: NONE beyond integer dst quads.
- `dst` is always `Rectangle<i32, Physical>`; `src` is `Rectangle<f64,
  BufferCoords>`. Scale is `Scale<f64>` but rounded to integer pixels at
  draw (`to_physical_precise_round`, renderer/mod.rs:441). No
  float/sub-pixel destinations, no perspective, no arbitrary angle —
  `src_transform` is `utils::Transform` (90-degree + flips only). A
  canvas zoom would re-emit `RescaleRenderElement` per frame (integer
  rounding jitters at high zoom) or bypass `Frame` entirely.
- Compositor-side effects: `Element::is_framebuffer_effect()` +
  `RenderElement::capture_framebuffer(frame, src, dst, cache)` (master,
  CHANGELOG Unreleased: "render elements that take the current
  framebuffers contents and modify them, e.g. blurring") — the hook
  exists and `OutputDamageTracker` calls it with a `UserDataMap` cache,
  but no blur element ships; the pass is DIY. The generic term "render
  pass" in canvas-compositing.md refers to this `Frame`/`RenderElement`
  machinery — the actual smithay names are `Frame` +
  `RenderElement::draw` (there is no `RenderPass` type).

Consequence: rotation and float zoom are not expressible through `Frame`
or wrapper elements; the compositor must implement `Frame`/renderer
extension with its own quad geometry — same conclusion as wlroots: the
canvas layer owns its pass.

## Smithay 0.7 + master changes relevant to scene work (CHANGELOG.md)

Unreleased (post-0.7.0): `delegate_dispatch2!` replaces per-module
`delegate_*!` macros (one call wires all globals, anvil state.rs:623);
`Element::is_framebuffer_effect` / `RenderElement::capture_framebuffer`;
`Space` stacking fns `map_element_above`, `raise_element_above`,
`lower_element`, `relocate_element`; `last_acked` commit tracking for
xdg/layer/session_lock surfaces (`with_committed_state()`);
`ExtBackgroundEffect` in `smithay::wayland::background_effect`.
0.7.0 itself: DRM/syncobj (`DrmSyncobjState::into_global`,
`GbmFramebufferExporter::new(..., import_node)`), keyboard modifier
state, XWaylandKeyboardGrab; nothing scene-graph related.

## Strengths (sourced)

- Complete protocol surface: compositor, xdg/layer shells, seat/input,
  dmabuf, presentation feedback, session lock, screencopy, drm lease,
  xdg activation, text-input/input-method — all in-tree handlers.
- Production-grade DRM path: atomic KMS, hardware plane assignment,
  client-buffer direct scan-out via `DrmCompositor`, multi-GPU via
  `GpuManager`/`MultiRenderer` with DMA-BUF copy (DeepWiki Glossary).
- WLCS conformance tests run in CI (DeepWiki Build page); anvil is a
  real, feature-complete reference compositor.
- Built-in damage/buffer-age pipeline (`OutputDamageTracker`,
  `RenderOutputResult`) for partial redraw; `SyncPoint` for frame
  handoff across threads (master). Feature-flag modularity: small
  dependency footprint per build.
- Strong typed geometry: Logical/Physical/Buffer spaces, `Transform`
  (72KB `utils::geometry`; DeepWiki Glossary).

## Weaknesses / gaps for a large-canvas compositor

- No per-element rotation; no transform hierarchy, group nodes, or
  retained scene graph with per-node matrices. Scale is uniform-only
  (`Scale<f64>` snapped to integer pixels via `RescaleRenderElement`);
  non-uniform scale needs custom code (DeepWiki Q&A).
- Positions are `i32 Logical` in `Space`; `Frame` dst rectangles are
  `i32 Physical` — sub-pixel placement is impossible through the stock
  API.
- Effect pipeline is hooks-only: `is_framebuffer_effect` +
  `capture_framebuffer` exist (master) but no shipped blur/effects
  element — compositor-side pipeline is DIY (hooks verified in
  src/backend/renderer/element/mod.rs:566,597).
- `desktop::Space` is desktop-window oriented; large-canvas uses
  (pan/zoom, rotated content, tiling) need a custom Element layer.
- Threading: documented sequential `&mut State` model (lib.rs); State
  not `Sync` [UNRESOLVED 2026-08-09: the sequential model does not imply
  !Sync; `AnvilState` (anvil/src/state.rs:131-148) has no explicit
  Send/Sync impls and no Rc/RefCell in its direct fields — Sync-ness is
  auto-derived from deep field types (e.g. calloop::Loop), which would
  need a compile-time assertion to settle];
  multi-thread rendering is the author's job (`SyncPoint`/`wait` are the
  handoff primitive, see Architecture).

## Rust vs Zig implication

- Rust gives smithay: trait-based renderer abstraction (one compositor
  over GLES/Pixman — no Vulkan renderer yet), macro-driven protocol
  dispatch (`delegate_dispatch2!`), safe FFI via `wayland-server`,
  memory safety in a large protocol state machine. Porting to Zig means
  reimplementing: protocol codegen (wayland-scanner equivalent), trait
  dispatch (comptime interfaces), and the `Element`/`Frame` render
  abstraction — feasible but substantial.
- Zig advantage for a canvas compositor: explicit control of allocation
  and rendering passes, no borrow-checker friction in the render graph,
  easier custom shader/pipeline plumbing — exactly where smithay is
  weakest (rotation, sub-pixel transforms, effects: none expressible via
  `Frame`/`Scale<f64>`).
- Takeaway: smithay is strong as a protocol/desktop base but its scene
  model caps at "windows on a 2D plane with uniform scale". A
  large-canvas compositor either extends it via custom
  `Element`/`RenderElement` implementations or builds a custom scene
  layer above the renderer traits — the natural seam for Zig to own.

## URLs

Repo: https://github.com/Smithay/smithay — Docs: https://smithay.github.io/
Anvil: https://github.com/Smithay/smithay/tree/master/anvil
DeepWiki: https://deepwiki.com/Smithay/smithay
Space module: .../blob/master/src/desktop/space/mod.rs
Element transforms: .../blob/master/src/backend/renderer/element/utils/elements.rs
Frame/Renderer traits: .../blob/master/src/backend/renderer/mod.rs
Calloop: https://github.com/Smithay/calloop
