# Presenting Wayland Surfaces on a Large 2D Canvas

Research note. Date: 2026-08-07.
Goal: pan/zoom over a large 2D canvas of Wayland surfaces (dynamicland-inspired).
Primary sources read: wlroots `wlr_scene.h`, `wlr_output.h`, `wlr_renderer.h`; smithay `desktop/space`; project READMEs (niri, wayfire, wayvr); gnome-shell `magnifier.js`.
All facts below verified from these sources unless marked [UNVERIFIED].

## 1. Spatial model

### wlroots scene graph (local, include/wlr/types/wlr_scene.h)
- Node types: `WLR_SCENE_NODE_TREE`, `WLR_SCENE_NODE_RECT`, `WLR_SCENE_NODE_BUFFER`.
- `struct wlr_scene_node` holds: parent, `int x, y` (relative to parent), `bool enabled`, `pixman_region32_t visible` (private).
- Position API: `wlr_scene_node_set_position(node, int x, int y)`. Integer positions only.
- **No scale and no rotation exist on scene nodes or buffers.**
  - Buffers: `wlr_scene_buffer_set_dest_size(w, h)` scales the whole buffer (int dest size, uniform source crop via `wlr_scene_buffer_set_source_box(wlr_fbox)`).
  - Orientation: `wlr_scene_buffer_set_transform(enum wl_output_transform)` — 90-degree rotations/flips only.
  - `wlr_scene_buffer_set_filter_mode(enum wlr_scale_filter_mode)` and `set_opacity(float)` exist.
- Hit testing: `wlr_scene_node_at(node, double lx, double ly, double *nx, double *ny)` — topmost node containing the point, layout-local input, returns node-relative coords. Per-buffer override hook `wlr_scene_buffer_point_accepts_input_func_t`.
- Output viewport: `wlr_scene_output_create(scene, output)`, `wlr_scene_output_set_position(int lx, int ly)`. Position is an integer offset; there is **no camera/zoom concept**.
- Output layout sync: `wlr_scene_attach_output_layout` keeps scene outputs aligned with `wlr_output_layout`.
- Composite helpers: `wlr_scene_subsurface_tree_create`, `wlr_scene_xdg_surface_create`, `wlr_scene_layer_surface_v1_create`, `wlr_scene_drag_icon_create`.

### Smithay (local, src/desktop/space/mod.rs)
- `Space<E: SpaceElement>` is "a two dimensional plane to map windows and outputs upon" — a flat z-ordered `Vec<InnerElement<E>>`, not a tree.
- `map_element(element, location: Point<i32, Logical>, activate)` sets a window's position. Positions are `i32` logical points; no per-element scale/rotation in `Space`.
- Rendering is trait-based: `SpaceElement`/`AsRenderElements`/`RenderElement` produce render elements; damage handled by `backend::renderer::damage::OutputDamageTracker` (`RenderOutputResult`).
- Smithay has no scene-graph module (no `src/scene`). `src/wayland/viewporter/` and `src/wayland/fractional_scale/` exist (verified by listing).

### Proposed architecture (sketch)
```
Canvas (world space, f64/f32 coords)
 ├── per-surface node: position (world), scale (uniform), rotation (optional), z-order
 ├── camera: center (world) + zoom + rotation(optional)
 └── viewport = screen rect; world→screen = translate(-center)*zoom; screen→world inverse

Render pass (per output, custom):
  clear → for each surface in z-order ∩ frustum (cull by world bbox):
          draw textured quad via camera matrix (rotation/arbitrary scale need a custom pass)
Input: pointer (screen) → invert camera → world → per-surface inverse transform → surface-local
```

## 2. Rendering

- Textures: wlr_scene caches `struct wlr_texture *texture` inside `wlr_scene_buffer` (reuse across frames); shm and dmabuf both feed `wlr_buffer` → texture. `wlr_scene_set_linux_dmabuf_v1` wires dmabuf feedback for the whole scene.
- Single composite pass: wlr_scene renders one pass per output with `wlr_scene_output_commit()` / `wlr_scene_output_build_state(state, options)`, honoring `wlr_output_state_set_buffer` + `set_damage(pixman_region32_t)` (wlr_output.h). Renderer is generic (`wlr_renderer_autocreate`); render-pass API lives in `include/wlr/render/pass.h` (skimmed, not quoted).
- **What wlr_scene supports natively:** integer position, integer dest-size scale, 90-degree transform, opacity, crop, filter mode, per-output damage ring (`wlr_scene_output.damage_ring`), visibility culling (`wlr_scene.calculate_visibility`), texture caching, direct scanout (`wlr_scene_output_sample_event.direct_scanout`).
- **What needs a custom render pass:** arbitrary rotation, non-uniform or float zoom, per-surface perspective/3D. For float zoom you must either (a) write your own render pass drawing each visible surface as a quad with a camera matrix, reusing wlr textures (import via `wlr_renderer` / texture API), or (b) fake zoom by re-setting `dst_size` per frame — integer truncation, no rotation.
- Culling: wlr_scene already skips buffers not intersecting the output (per-node `visible` region, iterated by `wlr_scene_output_for_each_buffer`). A custom pass must implement its own frustum culling in world space.
- Smithay comparison: same gap — `RenderElement::render` gets a `RenderPass`; zoom/rotation requires the compositor to emit transformed geometry. `OutputDamageTracker` is the damage analogue of `wlr_damage_ring`.

## 3. Damage, textures, precision

- Surface damage arrives buffer-local (`wlr_scene_buffer_set_buffer_with_damage`); scene transforms it into layout space. With a camera you must convert layout damage → screen space per frame (damage accumulates as a region, then inverse-transform to output pixels).
- Texture reuse: keep the `wlr_texture` for a surface across pan/zoom frames; only re-import when the buffer changes. Zoom without content change costs only a re-draw, not a re-upload.
- Float precision at extreme zoom: wlr positions are `int`; world coords should be `double` (scene hit-test already takes `double lx, ly`). [UNVERIFIED] GPU vertex precision: fp32 becomes visibly jittery around ~1e5 px from origin — mitigate by rebasing the camera near the origin and recomputing world→screen in double before rounding to pixels.
- Scale filter: `wlr_scale_filter_mode` selects NEAREST vs BILINEAR; zooming in with bilinear will blur. Client-side high-res buffers (see §5) are the fix.

## 4. Input remapping

- Pipeline: screen coords → invert camera (zoom, translation, optional rotation) → world coords → walk surface list topmost-first, apply each surface's inverse transform, test bbox, hit-test in surface-local coords.
- wlr_scene's `wlr_scene_node_at` handles the untransformed case; with a camera you must transform `lx, ly` yourself (or reparent a temporary view). The `point_accepts_input` callback still gives per-surface control.
- Focus rules: pointer enters a surface only when world point is inside it AND it is the topmost at that point; with zoom, click targets grow/shrink — the enter/leave hysteresis and focus-follows-pointer timing must be in world space, not screen space, or focus flickers while panning.
- Cursor latency: niri's author measures input latency as a first-class concern (talk listed in niri README). Panning must not add a frame of pointer lag; sample input at device rate, transform in the same frame.
- Prior art for remapping pain: wayvr README documents mouse-mapping bugs ("Mouse movement is wrong", X11 DPI scaling not supported, upright screens not supported, mouse-fix modes) — direct evidence that screen→surface coordinate remapping is the fiddly part.

## 5. Client-side scaling (avoid blurry zoom)

- `viewporter` (wayland-protocols): client crops/scales its own buffers via `wp_viewport` — the compositor then composites the already-correctly-scaled buffer.
- `fractional-scale-v1`: gives the client the fractional scale factor; client renders at that factor. Compositor requests higher-res buffers by exposing a larger scale; at zoom > 1 the client renders 1:1 to screen pixels.
- Both protocols exist in smithay (`src/wayland/viewporter/`, `src/wayland/fractional_scale/` verified locally) and are standard in wlroots (`wlr_viewporter`, fractional-scale in `wlr/types/` — wlr_scene uses `wlr_linux_dmabuf_feedback` for buffer-size hints).
- Strategy for zoom: advertise scale = max(1, camera zoom) so clients redraw at native resolution; surfaces that don't support viewporter/fractional-scale stay blurry [UNVERIFIED — exact client behavior varies].

## 6. Prior art (verified)

| Project | What it does | Techniques relevant to canvas | Source |
|---|---|---|---|
| niri | Scrollable-tiling Wayland compositor (Rust) | Infinite horizontal strip of columns; dynamic vertical workspaces; overview that zooms out workspaces/windows; custom fragment shaders for open/close/resize animations; fractional scaling "pixel-perfect"; gestures; input-latency measurement | https://github.com/YaLTeR/niri (README, docs/wiki listing) |
| wayfire | 3D Wayland compositor (C++, on wlroots) | Views as 3D-transformed surfaces: `cube`, `expo`, `wobbly`, `wrot` (rotate), `zoom` plugins; plugin architecture | https://github.com/WayfireWM/wayfire (README + plugin listing) |
| wayvr (ex WlxOverlay-S) | OpenXR/OpenVR overlay (Rust) | Captures Wayland/X11 screens (PipeWire) into VR; screens freely repositioned/resized in 3D; laser→screen mouse remapping with fix modes; pointer-precedence rules; documented remapping bugs (X11 DPI, upright screens) | https://github.com/wayvr/wayvr (README) |
| GNOME Magnifier | a11y zoom in gnome-shell (Clutter) | `ZoomRegion` clutter actors; magnification factor; 60 Hz pointer watcher drives scroll-to-mouse; disables unredirect while active; Clutter scene graph provides per-actor scale/transform | https://gitlab.gnome.org/GNOME/gnome-shell/-/raw/main/js/ui/magnifier.js |
| egui | Immediate-mode GUI with zoom/pan | `egui::Memory` zoom factor + pan per layer [UNVERIFIED — zoom.rs 404 on fetch, not verified from source] | https://github.com/emilk/egui |
| Figma / Miro | Infinite-canvas web apps | World↔screen transform, LOD, culled layers [UNVERIFIED — not fetched] | — |

## 7. Key risks

1. **wlr_scene cannot do rotation/float zoom.** Custom render pass is mandatory; you lose wlr_scene's damage-ring and frame-done plumbing unless you reuse them (`wlr_scene_output_build_state` still usable if you stay integer; otherwise rebuild damage tracking).
2. **Integer truncation.** `wlr_scene_node_set_position`/`set_dest_size` are int; continuous pan/zoom jitters unless you keep world state in double and snap to pixels only at draw.
3. **Frame-done / presentation.** Surfaces only redraw when they receive `frame_done`; with a camera, a pan must still tick `wlr_scene_buffer_send_frame_done` so clients repaint during zoom.
4. **Blurry zoom.** Clients must opt into viewporter/fractional-scale to render sharp at high zoom; legacy clients stay blurry (accept or scale-filter NEAREST).
5. **Damage accumulation under camera motion.** Whole-screen damage on pan is simplest and correct but costly; partial damage needs world→screen region transform and output-scale rounding.
6. **Input remapping bugs** (wayvr's documented history): scale/rotation inversion errors, focus flicker during pan, cursor lag. Add a debug overlay showing world coords early.
7. **fp32 precision** at extreme zoom/pan distances; rebase camera or use double in hit-testing.
8. **Culling correctness**: surfaces off-screen must not be drawn (wlr_scene culls only against output bounds in layout space — with a camera, cull in world space yourself).

## Gaps [UNVERIFIED]
- Smithay `RenderPass` API details for arbitrary quad transforms (skimmed only).
- Client behavior of viewporter/fractional-scale across toolkits at zoom > 1.
- niri's internal scene/rendering architecture (README-level only; `docs/wiki/Development:-Redraw-Loop.md` exists and was not read).
- egui zoom API, Figma/Miro internals.
