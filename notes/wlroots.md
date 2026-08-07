# wlroots — architecture note

Source: local clone `~/projects/freedesktop-wlroots-wlroots` (v0.18.3, `meson.build`), `docs/architecture.md`, `include/wlr/types/wlr_scene.h`, `types/scene/wlr_scene.c`, DeepWiki answer for WayfireWM/wayfire. Unverified facts are marked `[UNVERIFIED]`.

## What it is

- C library for building Wayland compositors. MIT. "About 60,000 lines of code you were going to write anyway" (README).
- Modular and unopinionated: backends, renderers, protocol implementations, and helpers compose independently. A compositor may use only some modules (`docs/architecture.md`).
- Build: meson, C11 (C23 optional). Feature toggles: `drm-backend`, `x11-backend`, `libinput-backend`, `xwayland`, `gles2-renderer`, `vulkan-renderer`, `gbm-allocator`, `session`, `color-management`. Installs pkg-config `wlroots-0.18` with version script `wlroots.syms`.
- `examples/tinywl` is the minimal reference compositor (xdg-shell only).

## Core abstractions (API map = `include/wlr/`)

Backends (`include/wlr/backend/`): `drm.h`, `libinput.h`, `wayland.h`, `x11.h`, `headless.h`, `session.h` (libseat), `multi.h`. The multi backend combines several (e.g. DRM + libinput). Backends create and destroy at runtime; custom backends allowed.

Renderers (`render/`): implementations in `gles2/`, `vulkan/`, `pixman/`; shared `wlr_renderer.h`, `wlr_texture.h`, `pass.h` (render-pass API), `swapchain.h`, `egl.c`, `drm_syncobj.c`, color via `color_lcms2.c`. Pipeline: import buffer → texture (CPU upload or DMA-BUF import) → render pass with draw ops → submit to output (`docs/architecture.md`).

Allocators (`render/allocator/`): `gbm.c`, `shm.c`, `drm_dumb.c` — back GBM/dmabuf allocation.

Protocol types (`include/wlr/types/`, ~70 headers):
- Core: `wlr_compositor.h` (wl_compositor/wl_surface), `wlr_buffer.h`, `wlr_shm.h`, `wlr_output.h`, `wlr_output_layout.h`, `wlr_output_layer.h`, `wlr_output_swapchain_manager.h`, `wlr_seat.h` (24.6KB, the input hub), `wlr_cursor.h`, `wlr_damage_ring.h`, `wlr_matrix.h`, `wlr_region.h`.
- Shells: `wlr_xdg_shell.h`, `wlr_layer_shell_v1.h`, `wlr_xwayland/` (+ `wlr_xwayland.h`), `wlr_fullscreen_shell_v1.h`, `wlr_session_lock_v1.h`, `wlr_subcompositor.h`, `wlr_server_decoration.h`.
- Buffers/DMABUF: `wlr_linux_dmabuf_v1.h`, `wlr_linux_drm_syncobj_v1.h`, `wlr_single_pixel_buffer_v1.h`.
- Capture/timing: `wlr_screencopy_v1.h`, `wlr_export_dmabuf_v1.h`, `wlr_presentation_time.h`, `wlr_viewporter.h`, `wlr_fractional_scale_v1.h`.
- Desktop protocols: `wlr_foreign_toplevel_management_v1.h`, `wlr_ext_foreign_toplevel_list_v1.h`, `wlr_xdg_activation_v1.h`, `wlr_xdg_decoration_v1.h`, `wlr_xdg_foreign_v1/v2.h`, `wlr_xdg_output_v1.h`, `wlr_output_management_v1.h`, `wlr_output_power_management_v1.h`, `wlr_tearing_control_v1.h`, `wlr_alpha_modifier_v1.h`, `wlr_content_type_v1.h`, `wlr_gamma_control_v1.h`, `wlr_drm_lease_v1.h`, `wlr_security_context_v1.h`, `wlr_transient_seat_v1.h`.
- Input: `wlr_input_device.h`, `wlr_keyboard.h`, `wlr_keyboard_group.h`, `wlr_pointer.h`, `wlr_touch.h`, `wlr_tablet_v2.h`, `wlr_relative_pointer_v1.h`, `wlr_pointer_constraints_v1.h`, `wlr_pointer_gestures_v1.h`, `wlr_cursor_shape_v1.h`, `wlr_virtual_keyboard_v1.h`, `wlr_virtual_pointer_v1.h`, `wlr_input_method_v2.h`, `wlr_text_input_v3.h`, `wlr_keyboard_shortcuts_inhibit_v1.h`, `wlr_idle_inhibit_v1.h`, `wlr_idle_notify_v1.h`, `wlr_xcursor_manager.h`.
- Clipboard/session: `wlr_data_control_v1.h`, `wlr_primary_selection.h`, `wlr_data_device.h`.

## wlr_scene

Implemented in `types/scene/` (`wlr_scene.c`, `surface.c`, `subsurface_tree.c`, `xdg_shell.c`, `layer_shell_v1.c`, `output_layout.c`, `drag_icon.c`). Header requires `-DWLR_USE_UNSTABLE` (unstable API, no ABI guarantees).

Header self-description (wlr_scene.h:13-19): "declarative way to display surfaces... The scene-graph API only supports basic 2D composition operations (like the KMS API or the Wayland protocol does). For anything more complicated, compositors need to implement custom rendering logic."

Node model: `enum wlr_scene_node_type` = TREE | RECT | BUFFER. `struct wlr_scene_node` carries: type, parent, enabled flag, **integer** `x, y` relative to parent, `events.destroy`, `data`, addons, private `visible` region. Node ops: `wlr_scene_node_destroy`, `set_enabled`, `set_position`, `place_above/place_below/raise_to_top/lower_to_bottom`, `reparent`, `coords` (layout-local), `for_each_buffer`, `wlr_scene_node_at` (hit testing).

Constructors:
- `wlr_scene_create`, `wlr_scene_tree_create` (pure grouping node).
- `wlr_scene_rect_create(parent, w, h, color[4])` + `wlr_scene_rect_set_size/set_color`.
- `wlr_scene_buffer_create(parent, wlr_buffer)` — raw buffer node.
- `wlr_scene_surface_create` — single surface.
- `wlr_scene_subsurface_tree_create` — surface + subsurfaces; `wlr_scene_subsurface_tree_set_clip` (only clip API in the header).
- `wlr_scene_xdg_surface_create` — whole xdg window incl. popups.
- `wlr_scene_layer_surface_v1_create` + `wlr_scene_layer_surface_v1_configure(full_area, usable_area)` — anchored layout for layer-shell.
- `wlr_scene_drag_icon_create`.
- `*_from_node` downcasts; `wlr_scene_surface_try_from_buffer`.

`wlr_scene_buffer` per-node capabilities (the transform surface):
- `wlr_scene_buffer_set_buffer` / `set_buffer_with_damage` (custom damage region), `set_source_box` (wlr_fbox crop), `set_dest_size` (scaling), **`set_transform(enum wl_output_transform)`** — 90-degree rotations/mirrors only, no arbitrary angles, `set_opacity` (float), `set_filter_mode` (wlr_scale_filter_mode), `set_opaque_region` (optimization hint; skips occlusion checks).
- Signals: `outputs_update`, `output_enter`, `output_leave`, `output_sample` (event carries `direct_scanout` bool), `frame_done`. Tracks `primary_output` (largest display area) for frame callbacks/presentation.
- Texture cached internally; `wlr_scene_set_linux_dmabuf_v1` wires dmabuf feedback for zero-copy.

Outputs: `wlr_scene_output_create(scene, wlr_output)` (once per output), `wlr_scene_output_set_position`, `wlr_scene_output_commit` (render + commit; options struct has `color_transform` for color management), `wlr_scene_output_build_state` (render into `wlr_output_state` without committing), `wlr_scene_output_send_frame_done`, `wlr_scene_get_scene_output`, `wlr_scene_attach_output_layout` + `wlr_scene_output_layout_add_output`. `wlr_scene_timer` reports render duration ns. Per-output `wlr_damage_ring` + `pending_commit_damage`.

Rendering/damage internals (wlr_scene.c):
- Builds a render list front-to-back, then renders back-to-front with `wlr_render_pass`: `wlr_render_pass_add_texture` (transform = compose(invert(buffer transform), output transform), clip = damaged region, alpha, filter mode, color transform), `wlr_render_pass_add_rect` (background fill).
- Damage: `wlr_damage_ring_add` schedules frames via `wlr_output_schedule_frame`; buffer damage rotated by buffer transform (`wlr_region_transform`); output damage transformed by inverted output transform; `wlr_damage_ring_rotate_buffer` per frame.
- Output-level transform/scale applied at render time (`render_data.transform = output->transform`, `scale = output->scale`; logical size = transformed resolution / scale). Scene nodes themselves have NO transform/scale — only buffers do.
- Direct scanout: `scene_entry_try_direct_scanout` — requires a single render-list entry, buffer transform == output transform, opacity 1, `wlr_output_is_direct_scanout_allowed`, and `scene->direct_scanout`. Env vars: `WLR_SCENE_DEBUG_DAMAGE` (none|rerender|highlight), `WLR_SCENE_DISABLE_DIRECT_SCANOUT`, `WLR_SCENE_DISABLE_VISIBILITY`, `WLR_SCENE_HIGHLIGHT_TRANSPARENT_REGION` (docs/env_vars.md + wlr_scene.c:172-175).

## Compositor usage

- sway: rendering on wlr_scene since sway 1.5 (Nov 2020, wlroots 0.12 era). `[general knowledge]`.
- labwc: renders exclusively through wlr_scene (scene tree per view); keeps its own view/workspace state above the scene. `[UNVERIFIED — not checked against labwc source]`.
- wayfire (DeepWiki answer, WayfireWM/wayfire): builds on wlr_scene but extends it with its own `wf::scene::node_t` render-instance tree. Damage → front-to-back render-instruction list → back-to-front execution via `render_pass_t` (wraps `wlr_render_pass`). Plugins inject custom GL with `custom_gles_subpass`; effect hooks (e.g. `OUTPUT_EFFECT_OVERLAY`); post-processing pipeline alternating aux buffers (zoom, invert — these disable direct scanout); `try_scanout` for direct scanout; wobbly effect = custom triangle mesh + shader (`wobbly_transformer_node_t`). Conclusion: pure wlr_scene lacks the granular control for effects; custom rendering needed.

## Zig interop

- `zig-wayland` (ifreund) is a Wayland protocol XML scanner only — no wlroots bindings (README.md; local clone at `~/projects/codeberg-ifreund-zig-wayland` is 8 months stale, Zig 0.13 era).
- The wlroots binding package is **zig-wlroots** (codeberg.org/ifreund/zig-wlroots), versioned per wlroots release. river pins `zig-wlroots v0.20.1` ↔ wlroots 0.20 (river build.zig.zon). Local wlroots clone (0.18.3) predates that pin; `[UNVERIFIED]` whether zig-wlroots publishes a 0.18 binding.
- river (reference Zig compositor) build.zig: `b.dependency("wlroots").module("wlroots")` with imports `wayland`, `xkbcommon`, `pixman`; the module links `wlroots-0.20` via pkg-config — the comment states the include path must be exposed "for @cImport() to work", i.e. zig-wlroots is an @cImport wrapper over the C headers. river separately uses `translate_c` (ziglang/translate-c) for libinput/libevdev and a C shim `river/wlroots_log_wrapper.c` to bridge wlroots logging into Zig.
- Practical pattern for this repo: `@cImport` of `<wlr/...>` directly works if you link `wlroots-0.18` (pkg-config) and add its include dir; friction is the unstable C API (WLR_USE_UNSTABLE), callbacks/varargs translation, and per-release churn.

## Strengths/weaknesses for a large-canvas compositor

Strengths:
- Backend/renderer abstraction: same scene runs on DRM, nested Wayland, X11, headless (README, architecture.md).
- Damage tracking, damage ring, frame scheduling, and direct scanout built into the scene (wlr_scene.c).
- dmabuf feedback + texture caching = zero-copy client buffers (wlr_scene_set_linux_dmabuf_v1).
- Output layout helper, presentation timing, frame_done fan-out, color transform hook (0.18).
- Declarative: compositor mutates the tree; renderer handles output scale/transform/opacity.

Weaknesses:
- Only basic 2D composition (header doc, explicit). Node position is integer; no per-node rotation/scale/affine; rotation limited to `wl_output_transform` 90-degree steps on buffers.
- No per-node opacity or clipping (opacity only on buffers; clip only via `wlr_scene_subsurface_tree_set_clip`).
- No shader/custom-render hooks inside scene passes. Effects require dropping to `wlr_render_pass`/`wlr_renderer` or bypassing the scene (wayfire's approach: own render-instance tree, `custom_gles_subpass`, post-processing pipeline).
- Unstable API (`WLR_USE_UNSTABLE`); changes between releases; Zig bindings must track wlroots versions.
