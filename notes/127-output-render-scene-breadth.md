# Output / Renderer / Scene — breadth inventory (wlroots 0.20.2, smithay v0.7.0)

Scope: our `src/output/{output,wl_output}.zig`, `src/renderer/{renderer,pass,texture,pixman,canvas}.zig`,
`src/scene/{scene,camera}.zig`, `src/presentation.zig`, `src/screencopy.zig`. Reference surface:
wlroots 0.20.2 `render/` + `types/wlr_output*` + `types/{scene,screencopy,presentation,damage_ring}`;
smithay v0.7.0 `src/backend/renderer/` (gles, pixman, multigpu, damage, utils, sync, element),
`src/backend/allocator/`, `src/output.rs`, `src/desktop/`. Note 111 covered per-function parity of the
renderer core; this note is the breadth inventory — whole modules/features the references have and we
lack entirely. The 101-115 parity notes cover the wire protocols; this note only flags render/output
features those protocols touch.

## Inventory

Reference module listing, verified by reading the clone directories.

wlroots (clone root `~/projects/freedesktop-wlroots-wlroots`):
- `render/`: `wlr_renderer.c`, `wlr_texture.c`, `pass.c` (render pass + timer), `swapchain.c`,
  `pixel_format.c`, `egl.c`, `dmabuf.c`, `dmabuf_fallback.c`, `dmabuf_linux.c`, `drm_format_set.c`,
  `drm_syncobj.c`, `drm_syncobj_merger.c`, `color.c`, `color_lcms2.c`, `color_fallback.c`;
  `allocator/` (`allocator.c`, `shm.c`, `drm_dumb.c`, `gbm.c`, `udmabuf.c`); `gles2/`
  (`renderer.c`, `pass.c`, `texture.c`, `pixel_format.c`, `shaders/`); `vulkan/` (`renderer.c`,
  `pass.c`, `texture.c`, `pixel_format.c`, `util.c`, `shaders/`); `pixman/` (`renderer.c`, `pass.c`,
  `pixel_format.c`).
- `types/`: `wlr_output.c` + `output/{state,render,swapchain,cursor}.c`; `wlr_output_layout.c`;
  `wlr_output_layer.c`; `wlr_output_swapchain_manager.c`; `wlr_damage_ring.c`; `wlr_screencopy_v1.c`;
  `wlr_presentation_time.c`; `wlr_linux_drm_syncobj_v1.c`; `scene/` (`wlr_scene.c`, `surface.c`,
  `xdg_shell.c`, `layer_shell_v1.c`, `subsurface_tree.c`, `output_layout.c`, `drag_icon.c`).
- Note: `wlr_output_damage` does NOT exist in 0.20.2 — `include/wlr/types/` has only
  `wlr_damage_ring.h`; output damage was folded into the damage ring + scene.

smithay (clone root `~/projects/github-Smithay-smithay`):
- `src/backend/renderer/`: `mod.rs` (Renderer trait suite: Bind, Offscreen, ImportMemWl/ImportMem,
  ImportEgl, ImportDmaWl/ImportDma, ImportAll, ExportMem, Blit/BlitFrame, Frame, FrameContext),
  `gles/` (`mod.rs`, `shaders/`, `texture.rs`, `uniform.rs`, `version.rs`, `format.rs`,
  `profiler.rs`, `element.rs`), `pixman/` (`mod.rs`), `glow.rs`, `multigpu/` (`mod.rs`, `gbm.rs`),
  `damage/` (`mod.rs` = OutputDamageTracker, `shaper.rs`), `element/` (`mod.rs` = Element/
  RenderElement/AsRenderElements + `render_elements!` macro, `solid.rs`, `surface.rs`,
  `texture.rs`, `memory.rs`, `utils/`), `sync/` (`mod.rs` = Fence/SyncPoint), `utils/`
  (`mod.rs` = CommitCounter/DamageBag/DamageSet/OpaqueRegions/SurfaceView, `wayland.rs` =
  `on_commit_buffer_handler`/`import_surface_tree`/`draw_render_elements`), `color.rs`.
- Note: there is NO top-level `src/render_elements/` in v0.7.0; the render-elements machinery
  (`render_elements!`, element types) lives in `src/backend/renderer/element/`.
- `src/backend/allocator/`: `format.rs` (Format/FormatSet/Fourcc), `swapchain.rs`, `dmabuf.rs`,
  `gbm.rs`, `dumb.rs`, `udmabuf.rs`, `vulkan/`.
- `src/output.rs`: Output, WeakOutput, OutputState, OutputModeSource.
- `src/desktop/`: `space/` (`mod.rs` = Space, `render_elements_for_output`, `render_output`;
  `element/`, `wayland/`, `output.rs`, `utils.rs`), `wayland/` (`window.rs`, `layer.rs` =
  LayerSurface/LayerMap, `popup/` = PopupManager, `utils.rs`).

## Breadth table

`ours` column: same = we have an equivalent; partial = weaker/older form; missing = absent.
Verdict column answers: is the missing functionality worth taking for a canvas-first compositor
(notes/canvas-compositing.md, zig-compositor-lib-spec.md)?

### Renderer

| wlroots/smithay feature | reference location | ours? | what it does | verdict |
|---|---|---|---|---|
| `wlr_renderer_autocreate` / `wlr_allocator_autocreate` | include/wlr/render/wlr_renderer.h:44, include/wlr/render/allocator.h:52 | missing | pick renderer+allocator from the backend (EGL/GBM vs pixman+shm) | in-scope when the gles2 renderer lands (roadmap); headless/VM hardwires pixman today |
| `wlr_renderer_get_texture_formats` / `get_render_formats` | wlr_renderer.h:88; render/vulkan/renderer.c:1094 | missing | advertise DRM formats+modifiers for textures and render targets | in-scope: required for linux-dmabuf + swapchain negotiation (roadmap) |
| `wlr_texture_from_dmabuf` / `from_buffer` / `update_from_buffer` | include/wlr/render/wlr_texture.h:48,63,71 | missing | import dmabuf/wl_buffer into the renderer, partial uploads | in-scope with the GPU renderer (roadmap); our `importMemory`/`updateMemory` (pixman.zig:139,166) is the shm analog |
| `wlr_texture_read_pixels` + `preferred_read_format` | wlr_texture.h:41,45 | missing | texture readback | optional: needed once screencopy must capture a GPU framebuffer |
| `wlr_buffer_pass_options`: timer, color_transform, signal_timeline | include/wlr/render/pass.h (options struct) | missing | per-pass GPU timing, color transform, sync timeline | optional (timer) / out-of-scope v1 (transform, timeline) |
| `wlr_render_timer` | pass.h:27; wlr_renderer.h:99-111; render/pass.c | missing | GPU render duration query | optional: cheap canvas perf profiling |
| `wlr_swapchain` (4 slots) | include/wlr/render/swapchain.h:18-42; render/swapchain.c | missing | buffer recycling for multi-buffered presents | in-scope: needed for tear-free GPU+DRM present (roadmap) |
| `wlr_allocator` + shm/drm_dumb/gbm/udmabuf | include/wlr/render/allocator.h:31-64; render/allocator/*.c | missing | buffer allocation backends | in-scope with the GPU renderer; our DRM backend allocates dumb buffers directly (backend/drm.zig) |
| gles2 renderer | render/gles2/{renderer,pass,texture,pixel_format}.c + shaders/ | missing | GLES2 GPU compositor | in-scope roadmap (spec M2); the canvas rasterizer must move to GPU for real canvases |
| vulkan renderer | render/vulkan/{renderer,pass,texture,pixel_format,util}.c | missing | Vulkan compositor + timeline sync | optional: gles2 first |
| pixel format tables | render/pixel_format.c:14-48 (format info + opaque list) | missing (we hardcode ARGB8888) | alpha/YCbCr queries, stride checks, wl_shm<->DRM conversion | in-scope: needed for linux-dmabuf and multi-format shm |
| color transform pipeline | include/wlr/render/color.h:121-185; render/color.c, color_lcms2.c | missing | LUT/matrix/ICC transforms, primaries conversion | out-of-scope v1; optional later (HDR/WCG) |
| drm_syncobj + merger | render/drm_syncobj.c, drm_syncobj_merger.c | missing | DRM syncobj timeline import/export/merge | out-of-scope v1; sync points needed for multi-threaded rendering later (roadmap) |
| multi-GPU | render/dmabuf_linux.c + `wlr_renderer_get_drm_fd` (wlr_renderer.h:96); smithay src/backend/renderer/multigpu/mod.rs:85-1150 (GpuManager, MultiRenderer, MultiTexture, cross_renderer) | missing | render on one GPU, present on another; cross-GPU copy | out-of-scope (single-GPU headless/VM target); optional later |
| dmabuf import | render/dmabuf.c, dmabuf_fallback.c, dmabuf_linux.c | missing | dmabuf texture import, linux-dmabuf protocol support | in-scope with the GPU renderer (roadmap) |
| smithay `Frame::finish -> SyncPoint` + `wait` | src/backend/renderer/mod.rs:349-362,437 | missing | frame-completion fence returned on finish | in-scope: the primitive for multi-threaded render+present (roadmap) |
| smithay `ExportMem` / `Blit` | mod.rs:734-870 | missing | framebuffer readback + blit between targets | optional: readback for screencopy; blit for effect layers later |
| smithay ImportMem/ImportDma/ImportAll trait hierarchy | mod.rs:466-730 | partial | buffer import capability matrix | our `importMemory`/`updateMemory` cover shm only; dmabuf import missing (see dmabuf row) |
| smithay GlesRenderer / PixmanRenderer | gles/mod.rs:372; pixman/mod.rs | missing / partial | renderer implementations | gles in-scope roadmap; pixman: ours is simpler (single format, no ExportMem) |

### Output

| wlroots/smithay feature | reference location | ours? | what it does | verdict |
|---|---|---|---|---|
| output state breadth: adaptive_sync, render_format, subpixel, wait/signal_timeline, color_transform, image_description | include/wlr/types/wlr_output.h (state setters); types/output/state.c | missing (our State: enabled/scale/transform/mode/buffer/damage, output.zig:53-72) | per-frame output state fields | adaptive sync optional (smooth DRM panning); render_format in-scope; timelines out-of-scope v1; color/imaging out-of-scope |
| `wlr_output_init_render` + `configure_primary_swapchain` + `begin_render_pass` | wlr_output.h:134,302,311; types/output/render.c:20-63,163 | missing | wire allocator+renderer to the output, manage its primary swapchain | in-scope with GPU renderer + swapchain (roadmap) |
| test/commit split + unchanged short-circuit + `request_state` | wlr_output.h:203,208; types/output/output.c | partial | state validation vs apply | we have test/commit (output.zig:140); no unchanged short-circuit, no request_state event (needed for hotplug later) |
| `wlr_output_cursor` + `add_software_cursors_to_render_pass` | wlr_output.h:247-259; types/output/cursor.c:91 | missing | hardware cursor buffers, software cursor pass | optional; our scene-node cursor (server/main.zig:902-952) works, and a canvas cursor should stay screen-space anyway |
| `wlr_output_get_primary_formats` | wlr_output.h:240 | missing | formats for the output's primary buffer | in-scope with swapchain negotiation (roadmap) |
| `wlr_output_lock_attach_render` / `lock_software_cursors` / `is_direct_scanout_allowed` | wlr_output.h:213,217,243 | missing | direct scanout control | out-of-scope: no direct scanout in the canvas design |
| gamma (`get_gamma_size`) + gamma_control_v1 | wlr_output.h:211; types/wlr_gamma_control_v1.c | missing | gamma ramp management | out-of-scope v1; optional for HDR |
| `wlr_output_layout` | include/wlr/types/wlr_output_layout.h:32-90; types/wlr_output_layout.c | missing | 2D output arrangement: output_at, adjacent, closest_point, get_box, center_output | roadmap: multi-output canvas walls. The camera model gives placement almost free (one camera per output); the layout helpers (closest_point, adjacent_output) still serve pointer/seat logic |
| `wlr_output_layer` (KMS overlay planes) | include/wlr/types/wlr_output_layer.h:21-46; types/wlr_output_layer.c | missing | offload layers to KMS overlay planes | out-of-scope: planes cannot rotate/zoom; the canvas composites everything |
| `wlr_output_swapchain_manager` | include/wlr/types/wlr_output_swapchain_manager.h:31-89; types/wlr_output_swapchain_manager.c | missing | atomic multi-output swapchain reconfiguration | roadmap for multi-output; unnecessary for a single output |
| `wlr_damage_ring` | include/wlr/types/wlr_damage_ring.h:24-62; types/wlr_damage_ring.c | partial | per-buffer damage accumulation | close: our DamageRing (utils/damage.zig:65-250) implements current+history rotate; wlroots tracks damage per ring buffer |
| transformed/effective resolution + preferred mode | wlr_output.h:170-178,149 | partial | geometry helpers | in-scope; ours has `transform.transformedSize` (output.zig updateSize) |
| smithay Output / OutputState / OutputModeSource | src/output.rs:245,499 | partial | output state + mode-source abstraction, user_data, PhysicalProperties | close; ours lacks user_data and physical properties (wl_output geometry is hardcoded, wl_output.zig:74-78) |

### Scene

| wlroots/smithay feature | reference location | ours? | what it does | verdict |
|---|---|---|---|---|
| direct scanout in scene commit | types/scene/wlr_scene.c:2061-2178,2445-2475 (`scene_entry_try_direct_scanout`) | missing | skip compositing when one buffer fills the output | out-of-scope for canvas (every frame goes through the camera); relevant only for a future plain-desktop mode |
| damage-based partial rendering + `needs_frame` | wlr_scene.c `wlr_scene_output_commit` wlr:2189 + `needs_frame`; smithay OutputDamageTracker src/backend/renderer/damage/mod.rs:326-428 | missing | render only the damaged region; skip empty frames | in-scope: our `SceneOutput.render` redraws the whole output every call (scene.zig:345); smithay's per-element commit-counter model is the design to copy — roadmap |
| opaque-region occlusion culling | wlr_scene.c:2530-2560; smithay damage/mod.rs opaque-region skip | missing | skip elements hidden under opaque content | optional perf win; a canvas is usually sparse — low value |
| texture caching + buffer hold-until-present | wlr_scene_buffer holds wlr_buffer, `set_buffer_with_damage` (wlr_scene.h:198) | missing | cache imported textures, hold buffer locks until present | in-scope: our render path re-imports textures per frame in server wiring; adopt hold-until-present — roadmap |
| scene timer (render duration) | wlr_scene.h:295-298; wlr_scene.c:2498-2655 | missing | per-commit render duration | optional: canvas perf profiling |
| frame_done pacing inside the scene | `wlr_scene_output_send_frame_done`, `wlr_scene_surface_send_frame_done` (wlr_scene.h:288-293) | partial | frame_done for visible surfaces after commit | ours delivers frame_done in server wiring; scene-level visible/primary-output tracking is the missing piece (camera-aware frame_done per canvas-compositing.md) |
| linux-dmabuf feedback + `wlr_scene_set_linux_dmabuf_v1` | wlr_scene.h:116; wlr_scene.c:2587-2596 | missing | dmabuf feedback hints to clients | out-of-scope until dmabuf + GPU renderer land |
| gamma / color manager integration | `wlr_scene_set_gamma_control_manager_v1`, `set_color_manager_v1` (wlr_scene.h:121-129) | missing | protocol glue | out-of-scope v1 |
| per-buffer colorimetry (transfer fn, primaries, encoding, range) | wlr_scene.h:244-257 | missing | HDR metadata per buffer | out-of-scope v1 |
| node extras: filter mode, transform, opaque region | wlr_scene.h:212-242 | partial | node-level transform/filter | partial: ours has src crop + dst size + opacity (scene.zig:234-262); filter mode matters for canvas zoom sharpness (the canvas sampler hardcodes bilinear, canvas.zig sampleBilinear) — in-scope |
| scene helpers: xdg_surface, layer_surface, subsurface_tree, drag_icon, output_layout attach | types/scene/{xdg_shell,layer_shell_v1,surface,subsurface_tree,drag_icon,output_layout}.c | missing | one-call scene integration | drag_icon missing (no DnD yet); layer_shell out-of-scope until the protocol lands; output_layout — roadmap |
| debug damage options | wlr_scene.c:197 (`WLR_SCENE_DEBUG_DAMAGE`) | missing | visualize damage regions | optional dev tool, cheap to add |
| surface enter/leave + per-buffer input callback | wlr_scene.h (point_accepts_input func type); scene/surface.c | partial | enter/leave events, buffer-local input filtering | partial: our `Scene.pick` (scene.zig:65) is the hit test; enter/leave needed for cursor-role correctness later — optional |
| single-pixel buffer fast path | wlr_scene.c (single-pixel buffers) | missing | avoid texture upload for 1px buffers | optional micro-opt |

### Smithay desktop / render-elements

| wlroots/smithay feature | reference location | ours? | what it does | verdict |
|---|---|---|---|---|
| Element / RenderElement / AsRenderElements + `render_elements!` macro | src/backend/renderer/element/mod.rs:518-613,825 | missing | per-element draw+damage abstraction | optional: our scene graph is the equivalent abstraction; the framebuffer-effect hook (`is_framebuffer_effect` + `capture_framebuffer`, element/mod.rs:566-607) is the blur/effect seam our canvas pass could adopt — optional |
| element impls: Texture/SolidColor/WaylandSurface/MemoryRenderBuffer | element/{texture,solid,surface,memory}.rs | missing | ready-made render elements | partial: scene buffer/rect nodes + importMemory cover the same ground; MemoryRenderBuffer's RenderContext (damage + opaque regions returned on draw, memory.rs:405-450) is the update model to copy — in-scope (roadmap) |
| OutputDamageTracker + CommitCounter/DamageBag/DamageSet/OpaqueRegions | damage/mod.rs:193-974; utils/mod.rs:19-473 | missing | per-element damage state machine | in-scope: this is the partial-rendering model for the canvas — roadmap |
| Fence / SyncPoint | sync/mod.rs:38-107 | missing | cross-thread render synchronization | in-scope: needed for multi-threaded rendering later (roadmap) |
| `desktop::Space` (map/raise/relocate/outputs/output_geometry/render_elements_for_output) | desktop/space/mod.rs:51-565,757 | missing | 2D window arrangement + per-output rendering | the canvas supersedes it for elements; but `map_output`/`output_geometry` (space/mod.rs:354,384) is the multi-output arrangement needed for canvas walls — roadmap |
| `desktop::Window` + WindowSurface | desktop/wayland/window.rs | missing | toplevel abstraction with popup integration | optional: our shell/xdg module covers toplevels; the window abstraction is compositor policy |
| LayerSurface + LayerMap (arrange, exclusive zone, layer_under) | desktop/wayland/layer.rs:35-459 | missing | layer-shell desktop stack | out-of-scope until wlr-layer-shell lands; optional HUD use |
| PopupManager | desktop/wayland/popup/manager.rs | missing | popup geometry + grab | out-of-scope (xdg popup is stubbed, note 105) |
| desktop::utils constrain helpers | desktop/utils.rs | missing | viewporter-style element cropping | optional: canvas crop comes from the camera |

## Gaps

Numbered notable missing functionality, with why it matters for the canvas compositor.

1. **No GPU renderer.** The canvas rasterizer (renderer/canvas.zig) and the pixman pass are CPU-only.
   wlroots ships gles2 + vulkan, smithay gles + glow (render/gles2/, render/vulkan/, gles/mod.rs:372).
   At canvas scale (zoomed multi-surface scenes) CPU compositing caps frame rate; the spec's M2 gles2
   milestone is the roadmap item. The camera pass must be ported to a shader (same quad math,
   canvas.zig drawItem).
2. **No swapchain / allocator.** Every frame allocates a fresh framebuffer; there is no
   multi-buffering. wlroots `wlr_swapchain` (4 slots) + `wlr_allocator` (shm/drm_dumb/gbm/udmabuf)
   and smithay `allocator/swapchain.rs` exist because a compositor must never draw into a buffer the
   scanout may still be reading. Required the moment a GPU renderer presents on DRM.
3. **No sync points.** smithay `Frame::finish -> SyncPoint` (mod.rs:362), `Fence` (sync/mod.rs:38),
   and wlroots drm_syncobj timelines are the primitives for knowing when a frame is actually done —
   a prerequisite for multi-threaded rendering (rasterize next frame while the previous is scanned
   out) and for zero-copy presentation. Adopt before threading the rasterizer.
4. **No format negotiation.** No `get_texture_formats`, `wlr_output_get_primary_formats`, or pixel
   format tables (render/pixel_format.c). Consequences: linux-dmabuf clients cannot be served,
   screencopy is locked to ARGB8888, and a GPU renderer could not advertise its formats. In-scope
   with the GPU work.
5. **No readback.** `wlr_texture_read_pixels` / smithay `ExportMem` do not exist here. Once the
   renderer is GPU-backed, screencopy (shm-only today, screencopy.zig) needs readback to keep
   working; effects would too.
6. **No partial rendering.** `SceneOutput.render` (scene.zig:345) repaints the entire output on
   every call and the damage ring is never consumed. wlroots and smithay both repaint only the
   damaged region and skip empty frames (wlr_scene `needs_frame`; OutputDamageTracker
   damage/mod.rs:326). Under camera motion whole-screen damage is correct, but panning cost scales
   with output size; smithay's per-element commit-counter model (utils/mod.rs CommitCounter +
   element damage_since) is the design to copy. Roadmap.
7. **No texture caching / buffer hold.** Textures are re-imported per frame in server wiring;
   wlroots caches textures in scene buffers and holds the wl_buffer locked until present
   (`wlr_scene_buffer_set_buffer_with_damage`). Our Buffer already has the lock model
   (buffers/buffer.zig lock/drop); the scene must hold locks until the frame is presented.
8. **No output layout.** Single output only. Canvas walls need per-output placement; the camera
   model makes this nearly free (one camera per output, camera.zig), so the wlroots layout API is
   not the deliverable — the useful parts are its seat-facing helpers (closest_point,
   adjacent_output) and the smithay `Space::map_output`/`output_geometry` semantics. Roadmap.
9. **No render timing.** `wlr_render_timer` / `wlr_scene_timer` are absent. Cheap to add; useful
   for canvas performance profiling. Optional.
10. **No output cursor API.** Hardware cursor buffers and the software-cursor render pass
    (types/output/cursor.c) are absent; the cursor is scene nodes (server/main.zig:902-952). This
    is acceptable — a canvas cursor must be screen-space, not camera-space — but the per-output
    cursor is the wlroots mechanism if hardware cursors are ever wanted. Optional.
11. **Color management, gamma, image description.** Out of scope v1 (table rows above); only
    relevant for HDR/WCG later.
12. **Layer shell / desktop Space stack.** No wlr-layer-shell and no smithay-style desktop module;
    the canvas supersedes the desktop arrangement. Layer-shell would serve HUD/panel content in a
    later phase — optional, protocol-first.

## Verdict

Both references have substantial additional functionality in this area beyond what note 111's
parity diff covered: a GPU renderer with allocator/swapchain, format negotiation and readback
(renderer); output state breadth, output layout, swapchain manager and cursors (output); and
scene-side damage tracking, texture caching, render timing and direct scanout (scene). For the
canvas-first compositor the take is selective. Out of scope by design: direct scanout and KMS
output layers (both bypass the camera pass — a canvas is composited, never scanned out
directly), color management, gamma and image description (HDR later), multi-GPU, and the
layer-shell desktop stack. In scope on the roadmap: a gles2 renderer with the camera pass ported
to a shader, swapchain/allocator and format negotiation under it, sync points before any
multi-threaded rendering, per-element damage tracking (the smithay damage/commit-counter model)
and texture caching with hold-until-present, and multi-output canvas walls (one camera per
output, plus the seat-facing layout helpers). Optional: render timing, readback (needed if
screencopy must capture a GPU framebuffer), filter-mode control for zoom sharpness. Finally, the
inverse holds: our `canvas.zig`/`camera.zig` EXCEED both references. wlr_scene supports only
integer positions, integer dest-size scaling and 90-degree `wl_output_transform` rotation with no
arbitrary rotation or float zoom (note 110, wlroots.md); smithay has no scene graph at all and
its Space uses i32 positions with uniform scale and no per-element rotation (smithay.md). Our
camera (f64 world coordinates, arbitrary rotation, zoom, `visibleWorldRect` culling —
camera.zig:34-83) and the bilinear canvas rasterizer (canvas.zig) have no counterpart in either
library, which is exactly the canvas-first divergence the spec (canvas-compositing.md) mandates
and the reason the missing scene features are acceptable losses.
