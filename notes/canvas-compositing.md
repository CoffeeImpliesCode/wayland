# Presenting Wayland Surfaces on a Large 2D Canvas

Research note. Date: 2026-08-07.
Goal: pan/zoom over a large 2D canvas of Wayland surfaces (dynamicland-inspired).
Primary sources read: wlroots `wlr_scene.h`, `wlr_output.h`, `wlr_renderer.h`, `render/pass.h` (local clone 0.20.2); smithay `desktop/space` + `backend/renderer/element/utils/elements.rs` (local clone, HEAD 5fb12b87); gnome-shell `magnifier.js` (2183 lines, fetched); egui `crates/egui/src/gui_zoom.rs` (fetched); niri/wayfire/wayvr READMEs; GitHub API search "infinite canvas window manager".
All facts below verified from these sources unless marked [UNVERIFIED].

## 1. Spatial model

### wlroots scene graph (local, include/wlr/types/wlr_scene.h — re-verified)
- Node types: `WLR_SCENE_NODE_TREE`, `WLR_SCENE_NODE_RECT`, `WLR_SCENE_NODE_BUFFER`.
- `struct wlr_scene_node`: parent, `int x, y` (relative to parent), `bool enabled`, private `visible` region. `wlr_scene_node_set_position(node, int x, int y)` — integer only.
- **No node-level scale or rotation.** Buffers: `wlr_scene_buffer_set_dest_size(w, h)` (int), `set_source_box(wlr_fbox)` crop, `set_transform(enum wl_output_transform)` (90-degree steps only), `set_opacity(float)`, `set_filter_mode(wlr_scale_filter_mode)`.
- Hit testing: `wlr_scene_node_at(node, double lx, double ly, ...)` — takes **double** layout coords (confirms wlroots already thinks in sub-integer layout space for input).
- Outputs: `wlr_scene_output_set_position(int lx, int ly)`; no camera concept. `wlr_scene_attach_output_layout` syncs with `wlr_output_layout`.
- `wlr_scene_output.damage_ring` (header line 205) + `wlr_damage_ring.h` include — per-output damage ring confirmed.

### Smithay (local, src/desktop/space/mod.rs + elements.rs — re-verified)
- `Space<E: SpaceElement>`: flat z-ordered plane of `Point<i32, Logical>` elements; no tree, no per-element scale/rotation in `Space`.
- Per-element transforms exist only as render-time **wrapper elements** in `backend::renderer::element/utils/elements.rs`:
  - `RescaleRenderElement<E>`: uniform `Scale<f64>`; `geometry()` scales the element rect around an origin (`to_f64().upscale(scale).to_i32_round()`); `damage_since` scales damage with `to_i32_up()` (rounds outward — same rule a canvas pass needs).
  - `RelocateRenderElement<E>`: offset by `Point<i32, Physical>`, `Relocate::Absolute` (replace) or `Relative` (add).
  - `CropRenderElement<E>`: intersect geometry with a physical rect; recomputes `src` in buffer space.
  - Crucially, `RenderElement::draw` forwards `src`/`dst` rectangles **unchanged** to the inner element: the "transform" is expressed entirely through recomputed `Rectangle<i32, Physical>` geometry, not a matrix, and there is **no rotation** anywhere. Sub-pixel placement is impossible at the draw boundary (i32 dst).
- Verdict (matches README.md): both stacks cap at flat integer 2D; the canvas layer needs a custom pass on either.

### Proposed architecture (sketch, with math)

```
Canvas (world space, f64)
 ├── per-surface node: position (f64), size, uniform scale, optional rotation, z-order
 ├── camera: center c (f64), zoom z (f64, z=1 ⇒ 1 world px = 1 output px), rotation θ (optional)
 └── output viewport: screen rect W×H (physical px, per output)

world→screen (2D affine, 3×3 homogeneous, computed in f64):
    M = T(W/2, H/2) · S(z) · R(−θ) · T(−c)
    p_screen = M · p_world          // f64 throughout
screen→world (pointer, input):
    p_world = c + R(θ) · ((p_screen − (W/2, H/2)) / z)
```

- With θ=0 the visible world rect is `[c ± (W/2z, H/2z)]` — the frustum used for culling and damage.
- **Precision budget:** fp32 mantissa is 24 bits; ulp(x) = x·2^−23. At x = 1e5 px, ulp ≈ 0.012 px (invisible); at 1e6 px ≈ 0.12 px (approaching visible); at ~8.4e6 px ≈ 1 px. Screen-space jitter = ulp · z, so high zoom makes it visible earlier.
- **Camera rebase:** keep world state in f64; per frame pick an origin `o` on a coarse grid (e.g. multiples of 4096 px), emit vertices as `p' = p − o` in f64, then cast to fp32 for the vertex buffer. All visible vertices stay within ~1e5 px of the fp32 origin ⇒ jitter stays below ~0.02 px regardless of how far the camera has panned. Rebase is a pure translation — it does not accumulate error and is invisible to clients.
- **Culling in world space:** AABB test surface bbox vs visible world rect (θ=0); with θ≠0, back-transform the 4 screen corners to world and test quad-vs-quad (conservative: use the world AABB of the transformed screen rect). Skip quads whose screen area < 1 px² (avoid fp32 degenerates when zoomed far out).

## 2. Rendering

- Textures: wlr_scene caches `struct wlr_texture *` inside `wlr_scene_buffer` (reuse across frames); shm and dmabuf both feed `wlr_buffer` → texture; `wlr_scene_set_linux_dmabuf_v1` wires dmabuf feedback. A custom pass reuses these cached textures: pan/zoom costs only a re-draw, never a re-upload.
- **Pass API (render/pass.h, re-verified):** `wlr_renderer_begin_buffer_pass(renderer, buffer, options)` → `wlr_render_pass_add_texture(pass, options)` / `add_rect` → `wlr_render_pass_submit`. The texture options carry `enum wl_output_transform transform` **only** — there is no matrix parameter. Arbitrary rotation therefore requires a custom GLES/Vulkan subpass or shader; uniform float zoom does not (it is a dest-rect size), so float zoom is achievable with the stock pass API by computing integer dst rects from the camera matrix.
- Composite order per output: acquire output buffer → canvas pass (all visible surfaces, front-to-back z-order, each drawn with src crop + computed dst + filter mode + opacity) → submit → desktop layer on top (wlr_scene via `wlr_scene_output_build_state`, which renders into a caller-provided buffer) → commit with damage. Damage for the frame = canvas damage ∪ scene damage ring.
- Culling: wlr_scene's built-in culling only tests layout-space output bounds; the canvas pass implements its own world-space frustum culling (§1).

## 3. Damage, textures, precision

- **Dual-layer damage strategy** (matches wlroots.md/README.md): keep wlr_scene's damage ring untouched for the desktop layer; keep a **world-space damage accumulator** for the canvas layer.
- Surface damage arrives buffer-local (`wlr_scene_buffer_set_buffer_with_damage`); the canvas layer converts it to world space via the surface transform and accumulates f64 rects.
- **Camera-motion rule:** if the camera transform changed since the last frame, damage the whole output — correct and cheap to reason about (tracking shifted damage needs buffer-age bookkeeping, a later optimization). Partial damage is only attempted when the camera is static: map each damaged world rect to screen via M, **round outward** (floor loc, ceil size) to physical px, clip to output.
- Texture reuse: keep the `wlr_texture` across pan/zoom frames; re-import only when the buffer changes.
- fp32 at extreme zoom: wlr positions are int, but world coords are f64 and the scene hit-test already takes double — the precision fix is the camera rebase of §1 (compute world→screen in f64, cast to fp32 only for vertices).

## 4. Input remapping

- Pipeline: device coords → output-local → layout coords → inverse camera (`p_world = c + R(θ)·((p_screen − t)/z)`) → topmost-first walk of surfaces, apply each surface's inverse transform, test the world point against the surface rect → surface-local coords → `wlr_seat` enter/leave/motion.
- **Zoom-invariance:** hit testing in world space means zooming the camera does not change hit results at all — the world point under the pointer is unchanged. Focus flicker can only come from surfaces moving under a stationary pointer. Do enter/leave arbitration in world space (enter when hit; leave only when the hit changes or the surface unmaps; hysteresis optional), never in screen space.
- Forwarded events must be camera-aware: `wlr_relative_pointer` deltas scale by 1/z; scroll/gesture deltas too. A pinch gesture can drive zoom directly (niri does this).
- **Cursor:** the hardware cursor plane (`wlr_output_set_cursor`) is screen-space and zero-latency — ideal, the cursor keeps constant size under zoom. A software cursor (wlr_cursor) must be composited after the camera pass at constant screen size, never scaled by z. GNOME magnifier has the same concern: it hides the system cursor and draws its own scaled `MouseSpriteContent` (`magnifier.js`).
- Latency: sample input at device rate (libinput) and transform in the same frame; no buffering between event and render. niri treats input latency as a first-class metric (README talk).
- Prior art for remapping pain: wayvr README documents mouse-mapping bugs (X11 DPI, upright screens, fix modes) — screen→surface remapping is the fiddly part.

## 5. Client-side scaling (avoid blurry zoom)

- `fractional-scale-v1`: compositor advertises per-surface `wl_fractional_scale`; rule: **advertise f = z · s** (z = camera zoom, s = output scale), i.e. client buffers get z× pixel density; at z ≤ 1 advertise f = s and let the compositor downsample. Client renders at that density, compositor composites 1:1 — sharp at any zoom.
- `viewporter` (`wp_viewport` source/dest): lets the client crop/scale its own buffers; compositor can also use it to request specific buffer sizes. Both protocols verified present in smithay (`src/wayland/viewporter/`, `src/wayland/fractional_scale/`) and wlroots (`wlr_viewporter.h`, `wlr_fractional_scale_v1.h`).
- Legacy clients (no viewporter/fractional-scale): buffers stay at native resolution; at z > 1 use NEAREST filter to avoid bilinear smearing [UNVERIFIED — exact per-toolkit behavior varies].

## 6. Multi-output / video wall

One world, N outputs: `wlr_output_layout` positions outputs in layout space; `wlr_scene_attach_output_layout` keeps the desktop layer aligned. Each output has its own camera (center, zoom, θ) — or, for a video wall, all outputs share one camera cropped per-output: `M_i = T(−output_pos_in_layout) · M`, so the layout is a window onto the shared world. Independent cameras enable e.g. a detail output plus an overview output. Input: one seat, pointer in output-local coords → layout coords → that output's inverse camera → world; per-output damage is per-camera (the same world region damages different outputs under different cameras). Per-output fractional-scale advertises per-output z.

## 7. Prior art (verified unless marked)

| Project | What it does | Techniques relevant to canvas | Source |
|---|---|---|---|
| niri | Scrollable-tiling Wayland compositor (Rust) | Infinite horizontal column strip; overview zooming out workspaces; custom fragment shaders for open/close/resize; fractional scaling "pixel-perfect"; gestures; input-latency measurement | https://github.com/YaLTeR/niri |
| wayfire | 3D Wayland compositor (C++, on wlroots) | Views as 3D-transformed surfaces: `cube`, `expo`, `wobbly`, `wrot` (rotate), `zoom` plugins; own render-instance tree above wlr_scene | https://github.com/WayfireWM/wayfire |
| wayvr (ex WlxOverlay-S) | OpenXR/OpenVR overlay (Rust) | Wayland/X11 screens (PipeWire) freely repositioned/resized in 3D; laser→screen mouse remapping with fix modes; documented remapping bugs | https://github.com/wayvr-org/wayvr |
| GNOME Magnifier | a11y zoom in gnome-shell (Clutter) | `ZoomRegion` actors; mag factor from GSettings; 60 Hz pointer watcher drives scroll-to-mouse (`interval = 1000/60`); `disable_unredirect()` while active; own scaled cursor sprite | https://gitlab.gnome.org/GNOME/gnome-shell/-/raw/main/js/ui/magnifier.js (2183 lines, read) |
| egui | Immediate-mode GUI (Rust) | `Context::zoom_factor` / `set_zoom_factor` — global GUI zoom clamped 0.2–5.0, scales `pixels_per_point`; Cmd+/-/0 shortcuts; `Options::zoom_with_keyboard` (gui_zoom.rs). Browser-style whole-GUI zoom, not a per-canvas camera — canvas pan/zoom is app-level | https://raw.githubusercontent.com/emilk/egui/main/crates/egui/src/gui_zoom.rs (read) |
| canvaswm | Infinite-canvas window manager (macOS) | Spatial window placement on an unbounded plane; closest living analog to the goal (not Wayland) | https://github.com/annieversary/canvaswm (via api.github.com search, 32 stars) |
| wincanvas | Infinite-canvas window manager (Windows) | Infinite canvas with live DWM window thumbnails | https://github.com/sermtech/wincanvas (via api.github.com search) |
| Figma / Miro | Infinite-canvas web apps | World↔screen transform, LOD, culled layers [UNVERIFIED — internals not fetched] | — |

KWin zoom effect: probed `src/effects/zoom/` on invent.kde.org and the GitHub mirror — 404 on all paths [UNVERIFIED — not confirmed; do not cite without a source].

## 8. Key risks

1. **wlr_scene cannot do rotation/float zoom.** `wlr_render_pass_add_texture` takes only `wl_output_transform` (verified in pass.h) — float zoom is expressible as int dst rects, but arbitrary rotation needs a custom GLES/Vulkan subpass.
2. **Integer truncation.** wlr scene positions/dest sizes are int; keep world state in f64 and snap to pixels only at draw. wlr layout coords are also i32 (max ±2.1e9 px ≈ ±550 km at 96 dpi) — the desktop layer cannot follow the canvas beyond that; the custom pass (f64) is unbounded, so interop must clamp.
3. **Camera motion ⇒ whole-screen damage.** Correct and simple; partial damage only when the camera is static. Damage rects must round outward (ceil) or 1-px tears appear at region edges.
4. **Frame-done / presentation.** A pan must still tick `wlr_scene_buffer_send_frame_done` (or the canvas pass must send its own frame callbacks) so clients repaint during zoom; present via `wlr_output_commit` with presentation feedback.
5. **Blurry zoom.** Clients must opt into viewporter/fractional-scale; legacy clients stay blurry (accept or filter NEAREST).
6. **Input remapping bugs** (wayvr's documented history): scale/rotation inversion, relative-pointer scaling by 1/z, focus flicker. Hit test in world space (zoom-invariant); add a debug overlay showing world coords early.
7. **fp32 precision.** Jitter ≈ ulp·z; rebase the camera per frame (§1) and compute world→screen in f64.
8. **Cursor under zoom.** Hardware cursor plane is screen-space (safe); a software cursor must be drawn after the camera pass at constant size — scaling it by z breaks muscle memory and adds latency.
9. **Culling correctness.** Cull in world space against the camera frustum; wlr_scene's own culling only covers layout-space output bounds.

## Gaps [UNVERIFIED]
- Client behavior of viewporter/fractional-scale across toolkits at zoom > 1 (advertise f = z·s is the design; per-toolkit conformance untested).
- niri's internal scene/rendering architecture (README-level only; `docs/wiki/Development:-Redraw-Loop.md` exists, not read).
- Figma/Miro internals; KWin zoom effect file path (404 on probes).
- Exact wf-effects repo layout (API check failed) — wayfire's zoom plugin listed from README only.
- Whether the canvas pass and `wlr_scene_output_build_state` can share one output buffer cleanly across two passes (plumbing to prove in the phase-5 spike).
