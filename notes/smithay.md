# Smithay — Rust Wayland Compositor Library

Research note. 2026-08-07. Sources: local clone
`~/projects/github-Smithay-smithay` (smithay 0.7.0, HEAD 5fb12b87),
DeepWiki (deepwiki.com/Smithay/smithay), anvil source in the clone.

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
   implements, and a `delegate_*!` macro wiring it into
   `wayland_server::Dispatch` (src/wayland/mod.rs).
3. `desktop` — optional helpers: `Space`, `Window`, `LayerSurface`,
   `PopupManager`, `LayerMap`.

Event loop: `calloop` 0.14. Callbacks receive `&mut State`, so no
Arc<Mutex> synchronization is needed (src/lib.rs).

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
`foreign_toplevel_list/`, screencopy (`image_capture_source/`,
`image_copy_capture/`), `content_type/`, `background_effect/`,
`alpha_modifier/`, `commit_timing/`, `fifo/`, `xwayland_shell.rs`.

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
  (`OutputDamageTracker`). Vulkan: `backend/vulkan/` (ash;
  `examples/vulkan.rs`). Allocators: GBM, dumb buffers, dmabuf.

## Scene graph story — the key finding

Smithay has NO dedicated `scene` module in 0.7 (no `smithay::scene`,
no `Scene`/`Node` types; DeepWiki Q&A + absence of `src/scene/`).
Scene-graph duties are split:

1. `desktop::space::Space<E: SpaceElement>` — 2D layout plane. Elements
   and `Output`s map onto it. API: `map_element(element, location,
   activate)`, `map_element_above`, `relocate_element`, `raise_element`,
   `lower_element`, `unmap_elem`, `element_under(point)`,
   `output_under`, `elements()`, `outputs()`,
   `render_elements_for_region`, `render_elements_for_output`, free fn
   `render_output(...)`. Position: `Point<i32, Logical>`. Z-order:
   mapping order + `RenderZindex` (Background=10 ... Overlay=1000).
   Source: src/desktop/space/{mod,element/mod}.rs.
2. Per-element rendering transforms exist only as WRAPPER elements in
   `backend::renderer::element::utils::elements`:
   - `RescaleRenderElement<E>` — uniform `Scale<f64>`.
   - `CropRenderElement<E>` — crop rect.
   - `RelocateRenderElement<E>` — position offset (`Relocate` enum).
   - `constrain_render_elements` / `constrain_as_render_elements`
     (`ConstrainAlign`, `ConstrainScaleBehavior` CutOff/Fit).
   Anvil composes: `Preview = CropRenderElement<
   RelocateRenderElement<RescaleRenderElement<WindowRenderElement<R>>>>`
   (anvil/src/render.rs:58).
3. Rotation: NO per-element rotation API. Only `utils::Transform`
   (Normal/90/180/270) at output level (`Output::current_transform` per
   DeepWiki); `Element::transform()` reports buffer rotation for
   scan-out.

Verdict: flat 2D scene, integer positions, z-order; uniform scale and
crop via render-time wrapper elements; arbitrary per-element rotation NOT
supported; no retained transform hierarchy or group nodes. Rotation must
be done by the compositor author.

## How a compositor is assembled (anvil)

`anvil/src/main.rs`: dispatch on argv: `--winit`, `--tty-udev`, `--x11`.
`anvil/src/state.rs`: `AnvilState<BackendData>` holds `CompositorState`,
`DataDeviceState`, `WlrLayerShellState`, `OutputManagerState`,
`SeatState`, `XdgShellState`, `PresentationState` plus ~25 more states;
one `delegate_dispatch2!` macro call (state.rs:623) wires them all.
`AnvilState::new` (state.rs:655+): inserts a calloop source for the
wayland display (`display.dispatch_clients`), then creates each
`*State::new::<Self>(&dh)` global.
`anvil/src/udev.rs` (`run_udev`, line 219):
- `EventLoop::try_new()` (calloop) + `Display::new()` (wayland_server);
  `GpuManager::new(GbmGlesBackend::with_factory(...))` creating
  `GlesRenderer` per GPU; `DrmCompositor<GbmAllocator, GbmDevice, ...>`
  alias (line 627). calloop sources: libinput, session notifier, udev
  hotplug, DrmEvent notifier.
- Render loop: `DrmEvent::VBlank` -> `frame_finish` (presentation
  feedback, VBlank throttling) -> `render(node, crtc, target)` ->
  `pre_repaint` + `output_elements` + `surface.drm_output.render_frame`
  (plane offload or GLES fallback) -> VBlank again (udev.rs:1201, 1281;
  DeepWiki "Rendering Pipeline in Anvil").
`anvil/src/render.rs`: `render_output(...)` takes renderer, framebuffer,
`OutputDamageTracker`, buffer `age`; age 0 = full redraw, else partial
(DeepWiki Q&A, src/backend/renderer/damage/mod.rs). `anvil/src/winit.rs`:
winit events drive `render_output` per frame (line 349), one
`OutputDamageTracker` per output.

## Strengths (sourced)

- Complete protocol surface: compositor, xdg/layer shells, seat/input,
  dmabuf, presentation feedback, session lock, screencopy, drm lease,
  xdg activation, text-input/input-method — all in-tree handlers.
- Production-grade DRM path: atomic KMS, hardware plane assignment,
  client-buffer direct scan-out via `DrmCompositor`, multi-GPU via
  `GpuManager`/`MultiRenderer` with DMA-BUF copy (DeepWiki Glossary).
- WLCS conformance tests run in CI (DeepWiki Build page); anvil is a
  real, feature-complete reference compositor.
- Built-in damage/buffer-age pipeline (`OutputDamageTracker`) for partial
  redraw (src/backend/renderer/damage/mod.rs).
- Feature-flag modularity: small dependency footprint per build.
- Strong typed geometry: Logical/Physical/Buffer spaces, `Transform`
  (72KB `utils::geometry`; DeepWiki Glossary).

## Weaknesses / gaps for a large-canvas compositor

- No per-element rotation; no transform hierarchy, group nodes, or
  retained scene graph with per-node matrices. Scale is uniform-only
  (`Scale<f64>`); non-uniform scale needs custom code (DeepWiki Q&A).
- Positions are `i32 Logical` in `Space`; sub-pixel placement needs custom
  elements (render-level location is `Point<i32, Physical>`).
- No built-in blur/effects pass; `background_effect` protocol exists but
  the compositor-side pipeline is DIY ([INFERENCE] — no effect renderer).
- `desktop::Space` is desktop-window oriented; large-canvas uses
  (pan/zoom, rotated content, tiling) need a custom Element layer.
- Calloop's `&mut State` model is single-threaded; multi-thread rendering
  is the author's job (State is not Sync) ([INFERENCE] from lib.rs).

## Rust vs Zig implication

- Rust gives smithay: trait-based renderer abstraction (one compositor
  over GLES/Pixman/Vulkan), macro-driven protocol dispatch
  (`delegate_dispatch2!`), safe FFI via `wayland-server`, memory safety
  in a large protocol state machine. Porting to Zig means reimplementing:
  protocol codegen (wayland-scanner equivalent), trait dispatch
  (comptime interfaces), and the `Element`/`Renderer` abstraction —
  feasible but substantial.
- Zig advantage for a canvas compositor: explicit control of allocation
  and rendering passes, no borrow-checker friction in the render graph,
  easier custom shader/pipeline plumbing — exactly where smithay is
  weakest (rotation, sub-pixel transforms, effects).
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
Calloop: https://github.com/Smithay/calloop
