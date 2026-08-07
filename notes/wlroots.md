# wlroots — architecture note

Research date: 2026-08-07. Sources: local clone `~/projects/freedesktop-wlroots-wlroots` (tag 0.18.3, commit f0ae9df, 2025-10-23),
`docs/architecture.md`, `include/wlr/types/wlr_scene.h`, `types/scene/wlr_scene.c`, `tinywl/tinywl.c`, `meson_options.txt`; remote tags via
`git ls-remote https://gitlab.freedesktop.org/wlroots/wlroots.git`; labwc/sway/zig-wlroots READMEs (raw.githubusercontent.com). Facts
verified from these sources unless marked [UNVERIFIED].

## Version state (verified 2026-08-07)

- Current stable release: **0.20.2** (remote tags 0.20.0, 0.20.1, 0.20.2, plus 0.20.0-rc1..rc5); 0.19 line (0.19.0..0.19.3) also released. `master` is **0.21.0-dev** (meson.build) — unreleased.
- Local clone is **0.18.3**, two majors behind; `origin/0.19` and `origin/0.20` branches exist but the working tree is on `0.18`.
- Reconciliation with zig-wayland.md / zig-wlroots "wlroots 0.20": a **released line, not a master/branch target**. zig-wlroots versions
encode the wlroots release (`major.minor.revision`, README), so zig-wlroots 0.20.x is compatible with wlroots 0.20.x — and 0.20.2, the
current stable patch, is inside that line. zig-wlroots does not track master (0.21.0-dev).

## What it is

- C library for building Wayland compositors. MIT. "About 60,000 lines of code you were going to write anyway" (README). Modular: backends,
renderers, protocol implementations, and helpers compose independently; a compositor may use only some modules (docs/architecture.md).
- Build: meson, C11 (C23 optional). Toggles (meson_options.txt): `xwayland`, `renderers` (auto|gles2|vulkan; pixman always built),
`backends` (auto|drm|libinput|x11; wayland/headless always built), `allocators` (auto|gbm; shm/drm_dumb always built), `session`,
`color-management`, `xcb-errors`, `libliftoff`. Installs pkg-config `wlroots-0.18` with version script `wlroots.syms`.
- `tinywl/` is the minimal reference compositor (xdg-shell only; moved out of `examples/` before 0.18). `examples/` holds single-feature
demos (scene-graph.c, rotation.c, output-layout.c, pointer.c).

## Core abstractions (API map = `include/wlr/`)

- Backends (`backend/`: drm.h, headless.h, wayland.h, x11.h, libinput.h, multi.h, session.h, interface.h): DRM + libinput drive physical
devices; Wayland/X11 nest inside another compositor; headless runs with no display; the multi backend combines (e.g. DRM + libinput). Custom backends allowed.
- Renderers (`render/`): implementations in `gles2/`, `vulkan/`, `pixman/`; shared `wlr_renderer.h`, `wlr_texture.h`, `pass.h` (render-pass
API), `swapchain.h`, `egl.h`, `drm_syncobj.h`; color via `color_lcms2.h`. Pipeline: import client buffer → `wlr_texture` (CPU upload or
DMA-BUF import) → render pass with draw ops → submit to output.
- Allocators (`render/allocator/`): `gbm.c`, `shm.c`, `drm_dumb.c` — the bridge between renderer and backend for buffer allocation.
- Protocol types (`types/`, 70 headers in `include/wlr/types/`): compositor, shm, output, output-layout, output-layer, seat/cursor/input
devices, xdg and layer shells, xwayland, linux-dmabuf, screencopy, presentation-time, viewporter, fractional-scale, foreign-toplevel,
xdg-activation, idle, tablet-v2, text-input v3, data-control, etc. (matches the earlier note).

## wlr_scene

Implemented in `types/scene/` (wlr_scene.c, surface.c, subsurface_tree.c, xdg_shell.c, layer_shell_v1.c, output_layout.c, drag_icon.c).
Header requires `-DWLR_USE_UNSTABLE` — unstable API, no ABI guarantees. Header doc (wlr_scene.h:13-19): "The scene-graph API only supports
basic 2D composition operations (like the KMS API or the Wayland protocol does). For anything more complicated, compositors need to
implement custom rendering logic."

### Nodes

`enum wlr_scene_node_type` = TREE | RECT | BUFFER. `struct wlr_scene_node`: type, parent, sibling link, `bool enabled` (children disabled
with parent), `int x, y` relative to parent, `events.destroy`, `void *data` (per-node user pointer — sway's scene_descriptor hangs off it
via `wlr_addon_set addons`), private `pixman_region32_t visible` (culling region).

Node ops (exact signatures from the header):
- `wlr_scene_node_destroy(node)`; `wlr_scene_node_set_enabled(node, bool)`; `wlr_scene_node_set_position(node, int x, int y)` — integer only
- `wlr_scene_node_place_above(node, sibling)`, `place_below`, `raise_to_top`, `lower_to_bottom`; `wlr_scene_node_reparent(node, new_parent)`
- `bool wlr_scene_node_coords(node, int *lx, int *ly)` — layout-local; false if disabled;
`wlr_scene_node_for_each_buffer(node, iterator, user_data)` — root-to-leaf render order
- `struct wlr_scene_node *wlr_scene_node_at(node, double lx, double ly, double *nx, double *ny)` — topmost hit test, node-relative out

Constructors: `wlr_scene_create`; `wlr_scene_tree_create(parent)` (pure grouping); `wlr_scene_rect_create(parent, w, h, color[4])` +
`set_size`/`set_color`; `wlr_scene_buffer_create(parent, wlr_buffer)`; `wlr_scene_surface_create(parent, wlr_surface)` (sub-surfaces
ignored); `wlr_scene_subsurface_tree_create` + `wlr_scene_subsurface_tree_set_clip(node, wlr_box *)` (only clip API in the header);
`wlr_scene_xdg_surface_create` (whole window incl. popups; origin = window geometry top-left); `wlr_scene_layer_surface_v1_create` +
`_configure(full_area, usable_area)`; `wlr_scene_drag_icon_create`. Downcasts: `wlr_scene_{buffer,tree,rect}_from_node`,
`wlr_scene_surface_try_from_buffer`.

### wlr_scene_buffer — the transform surface

Per-buffer capabilities (exact signatures):
- `wlr_scene_buffer_set_buffer(b, wlr_buffer *)` / `set_buffer_with_damage(b, buffer, pixman_region32_t *)` (damage in buffer-local coords)
- `wlr_scene_buffer_set_source_box(b, wlr_fbox *)` — crop; NULL = whole buffer; `wlr_scene_buffer_set_dest_size(b, int w, int h)` —
**integer** scale; 0 = buffer size
- `wlr_scene_buffer_set_transform(b, enum wl_output_transform)` — 90-degree rotations/mirrors only;
`wlr_scene_buffer_set_opacity(b, float)`; `wlr_scene_buffer_set_filter_mode(b, enum wlr_scale_filter_mode)`
- `wlr_scene_buffer_set_opaque_region(b, pixman_region32_t *)` — occlusion optimization hint;
`wlr_scene_buffer_send_frame_done(b, struct timespec *now)`; input hook `wlr_scene_buffer_point_accepts_input_func_t` (`point_accepts_input` field)

Struct fields: `primary_output` (output showing the largest area — drives frame callbacks and presentation feedback), `opacity`,
`filter_mode`, `src_box`, `dst_width/dst_height`, `transform`, `opaque_region`; signals `outputs_update`, `output_enter`, `output_leave`,
`output_sample` (`wlr_scene_output_sample_event { output, direct_scanout }`), `frame_done`. Private: cached `wlr_texture` (reuse across
frames; re-import only on buffer change), `own_buffer`, `buffer_is_opaque`. `wlr_scene_set_linux_dmabuf_v1` wires dmabuf feedback for
zero-copy across the whole scene.

### Outputs and frame scheduling

`struct wlr_scene_output { wlr_output *, wlr_scene *, wlr_damage_ring damage_ring, int x, y, pending_commit_damage, prev_scanout, render_list }`.
- `wlr_scene_output_create(scene, output)` — once per output; `_destroy`; `wlr_scene_output_set_position(so, int lx, int ly)`
- `bool wlr_scene_output_commit(so, const struct wlr_scene_output_state_options *)` — render + commit;
`bool wlr_scene_output_build_state(so, wlr_output_state *, options)` — render without committing
- `struct wlr_scene_output_state_options { wlr_scene_timer *timer; wlr_color_transform *color_transform; wlr_swapchain *swapchain; }`
- `wlr_scene_output_send_frame_done(so, now)` — only surfaces whose `primary_output` matches;
`wlr_scene_output_for_each_buffer(so, iterator, user_data)` — visible buffers, render order
- `wlr_scene_get_scene_output(scene, output)`; `wlr_scene_attach_output_layout(scene, output_layout)` → `wlr_scene_output_layout`;
`wlr_scene_output_layout_add_output(sol, layout_output, scene_output)` — scene output positions synced to the layout
- `wlr_scene_timer_get_duration_ns` / `_finish` — render duration incl. GPU

Damage path (wlr_scene.c): `wlr_damage_ring_add` + `wlr_output_schedule_frame` on changes; buffer damage rotated by buffer transform
(`wlr_region_transform`), output damage by inverted output transform; `wlr_damage_ring_rotate_buffer` per frame; output transform/scale
applied at render time (scene nodes have no transform/scale). Debug env vars (wlr_scene.c:172-175): `WLR_SCENE_DEBUG_DAMAGE`
(none|rerender|highlight), `WLR_SCENE_DISABLE_DIRECT_SCANOUT`, `WLR_SCENE_DISABLE_VISIBILITY`, `WLR_SCENE_HIGHLIGHT_TRANSPARENT_REGION`.

Direct scanout (wlr_scene.c:1616-1689, call site ~1854): only when — one render-list entry, `options->color_transform == NULL`,
damage-highlight debug off, `scene->direct_scanout` on, entry is a BUFFER node, no mode/enabled/render-format state commit,
`wlr_output_is_direct_scanout_allowed`, buffer present, no crop (src_box empty or full-buffer), buffer transform == output transform, node
box covers the whole output logical box, and `wlr_output_test_state` passes. Opacity is **not** checked in the 0.18.3 scanout path (it only
affects occlusion, wlr_scene.c:253); sibling notes' "opacity 1" condition is therefore not exact for this version.

## Minimal compositor assembly (tinywl, 0.18.3)

Wiring order from `tinywl/tinywl.c` (setup ~905-1030; frame loop ~555-575):

1. `wl_display_create()`; 2. `wlr_backend_autocreate(wl_display_get_event_loop(display), NULL)` — picks DRM, nested Wayland/X11, or headless
via `WLR_BACKENDS`; multi backend bundles DRM + libinput; 3. `wlr_renderer_autocreate(backend)` — Pixman, GLES2, or Vulkan (`WLR_RENDERER`),
then `wlr_renderer_init_wl_display(renderer, display)`; 4. `wlr_allocator_autocreate(backend, renderer)`.
5. Globals: `wlr_compositor_create(display, 5, renderer)`, `wlr_subcompositor_create(display)`, `wlr_data_device_manager_create(display)`;
6. `wlr_output_layout_create(display)`; listen `backend->events.new_output` → per output: `wlr_scene_output_create(scene, output)` + connect
the output `frame` listener; 7. `wlr_scene_create()`; `wlr_scene_attach_output_layout(scene, output_layout)`.
8. `wlr_xdg_shell_create(display, 3)`; on `new_toplevel`: `wlr_scene_tree` + `wlr_scene_xdg_surface_create(tree, xdg_surface)`; focus =
`wlr_scene_node_raise_to_top` + `wlr_seat_keyboard_notify_enter`; 9. Input: `wlr_cursor_create()` + `wlr_cursor_attach_output_layout`,
`wlr_xcursor_manager_create(NULL, 24)`; `wlr_seat_create(display, "seat0")`; `backend->events.new_input` → `wlr_seat_set_keyboard`; handle
seat `request_set_cursor` / `request_set_selection`; 10. `wl_display_add_socket_auto(display)`; `wlr_backend_start(backend)`.

Frame loop (per output, at refresh rate): `output->frame` event → `wlr_scene_get_scene_output(scene, output)` →
`wlr_scene_output_commit(scene_output, NULL)` → `clock_gettime` + `wlr_scene_output_send_frame_done(scene_output, &now)`. Damage
accumulation and frame scheduling live inside the scene (damage ring); the compositor never touches output buffers directly.

## Compositor usage (verified)

- **sway**: README lists wlroots as a build dependency; uses wlr_scene — `sway/scene_descriptor.c` attaches `wlr_addon` sets to
`wlr_scene_node` (verified via raw.githubusercontent.com). Scene rendering since sway 1.5.
- **labwc**: README: "a [wlroots]-based window-stacking compositor". Renders through wlr_scene — `src/desktop.c` includes
`<wlr/types/wlr_scene.h>`, keeps per-output scene `layer_tree`s toggled via `wlr_scene_node_set_enabled`, and uses `view->scene_tree` per
view; keeps its own view/workspace state above the scene. No `src/scene.c` (404); scene code lives in desktop.c/layers.c/view.c.
- **wayfire** (DeepWiki answer, WayfireWM/wayfire): builds on wlr_scene but extends it with its own `wf::scene::node_t` render-instance
tree; plugins inject custom GL via `custom_gles_subpass` (wobbly = custom triangle mesh + shader); effects disable direct scanout. Evidence
that pure wlr_scene lacks granular control — custom rendering needed for effects.

## Zig interop

- **zig-wlroots** (codeberg.org/ifreund/zig-wlroots; GitHub swaywm/zig-wlroots is a read-only mirror, last push 2026-05-10; api.github.com
search: 8 hits, only this one is maintained). README: "Idiomatic Zig bindings"; "Large parts of the wlroots API are fully bound, more than
enough for river"; "I only personally add bindings for new parts of the wlroots API as required by river". Deps: Zig 0.16, wlroots **0.20**,
zig-wayland, zig-xkbcommon, zig-pixman. Version scheme `major.minor.revision` encodes the compatible wlroots release (e.g. 0.16.42 ↔ wlroots
0.16). Ships `tinywl.zig` example. "See the C headers of wlroots for documentation" — bindings mirror headers.
- river pins zig-wlroots v0.20.1 ↔ wlroots 0.20 (river build.zig.zon, per zig-wayland.md). [UNVERIFIED] whether zig-wlroots publishes a 0.18
binding — the local 0.18.3 clone predates the pin.
- Contrast with `@cImport`: zig-wlroots is hand-written idiomatic Zig, not translate-c output — ergonomic but coverage is river-driven
(missing APIs must be added by hand). `@cImport` of `<wlr/...>` works if you link `wlroots-0.18` via pkg-config, add its include dir, and
define `WLR_USE_UNSTABLE`; friction is callback/varargs translation, opaque structs, and per-release churn of the unstable C API.
- Maintenance risk: wlroots API is explicitly unstable (WLR_USE_UNSTABLE); bindings lag releases, are river-shaped, and Zig-toolchain churn
compounds it. Pin both wlroots and zig-wlroots deliberately.
- wlrfx/zig-wlroots (scenefx fork, Zig 0.11 + wlroots 0.16, rounded corners/shadows) is stale and off-version — do not use.

## Strengths/weaknesses for a large-canvas compositor

Strengths:
- Backend/renderer abstraction: one scene runs on DRM, nested Wayland, X11, headless (README, architecture.md).
- Built into the scene: damage ring, culling (per-node `visible` region), frame scheduling, texture caching, direct scanout, dmabuf feedback, color-transform hook, per-output render timers.
- Declarative: compositor mutates the tree; renderer applies scale/transform/opacity. tinywl is a complete, heavily commented reference.

Weaknesses:
- Basic 2D only (header doc, explicit). Node position `int`; **no node-level scale/rotation**; rotation limited to `wl_output_transform`
90-degree steps on buffers; scaling only via integer `set_dest_size` per buffer.
- Opacity only on buffer nodes (rects carry color alpha only); clipping only via `wlr_scene_subsurface_tree_set_clip`.
- No per-node shaders or custom-render hooks inside scene passes; effects require dropping to `wlr_render_pass`/`wlr_renderer` or bypassing
the scene (wayfire's approach).
- Unstable API; Zig bindings must track wlroots versions (see Zig interop).
