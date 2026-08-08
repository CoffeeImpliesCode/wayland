# Scene — wlroots/smithay diff

Sources: our `src/scene/scene.zig` vs wlroots 0.20.2 `types/scene/wlr_scene.c` +
`include/wlr/types/wlr_scene.h`; smithay 0.7.0 `src/backend/renderer/` (no scene
graph; N/A rows cite the element/damage system that fills the role).

## Surface

Flat inventory of public types and fns in our module (`src/scene/scene.zig`).

| item | location |
|---|---|
| `Scene` | scene.zig:32 |
| `Scene.init` | scene.zig:38 |
| `Scene.deinit` | scene.zig:54 |
| `Scene.pick` | scene.zig:65 |
| `SceneNode` | scene.zig:73 |
| `SceneNode.Kind` | scene.zig:86 |
| `SceneNode.create` | scene.zig:89 |
| `SceneNode.appendChild` | scene.zig:158 |
| `SceneNode.removeChild` | scene.zig:172 |
| `SceneNode.enable` | scene.zig:179 |
| `SceneNode.destroy` | scene.zig:185 |
| `SceneNode.absolutePosition` | scene.zig:202 |
| `SceneBufferNode` | scene.zig:234 |
| `SceneRectNode` | scene.zig:245 |
| `SceneOutput` | scene.zig:255 |
| `SceneOutput.create` | scene.zig:264 |
| `SceneOutput.destroy` | scene.zig:293 |
| `SceneOutput.render` | scene.zig:302 |

## Comparison

One row per surface item. `ours` = src/scene/scene.zig, `wlr` = types/scene/wlr_scene.c, `wlrH` = include/wlr/types/wlr_scene.h, `st` = smithay.

| ours | semantics | wlroots equiv | smithay equiv | verdict |
|---|---|---|---|---|
| `Scene.init` (38) | alloc scene + invisible root tree node | `wlr_scene_create` wlr:175 — calloc scene, init root tree, outputs list, debug env parsing | N/A — no scene graph in smithay; compositor builds its own element list per frame | close |
| `Scene.deinit` (54) | destroy whole tree + scene; outputs untouched | `wlr_scene_node_destroy` on root wlr:99 — also destroys every attached scene output and unregisters dmabuf/gamma hooks | N/A | close — wlroots roots own outputs, ours does not |
| `Scene.pick` (65) | topmost enabled pickable BUFFER node containing (x,y); rects skipped; reverse draw order | `wlr_scene_node_at` wlr:1413 — topmost node of ANY type (rects hit too) via `_scene_nodes_in_box` wlr:224, honoring enabled only | N/A — smithay has no hit test; compositor decides | divergent — ours skips rect nodes and adds a compositor `pickable` flag; wlroots filters via per-buffer input callback and returns rect hits |
| `SceneNode.create` (89) | one creator for tree/buffer/rect, tags node kind, auto-appends to parent | per-type creators: `wlr_scene_tree_create` wlr:205, `wlr_scene_rect_create` wlr:761, `wlr_scene_buffer_create` wlr:870 | N/A | close — ours merges three creators into one tagged fn |
| `SceneNode.appendChild` (158) | append as last child; reparents if already parented | `wlr_scene_node_reparent` wlr:1309 — explicit reparent, damages old+new positions | N/A | close — wlroots guards self-ancestor cycles wlr:1316-1319; ours only asserts node != child (161) |
| `SceneNode.removeChild` (172) | detach child, order preserved | no public detach; removal via `wlr_scene_node_reparent` (wl_list_remove wlr:1326) or destroy | N/A | ours-only — wlroots has no standalone detach |
| `SceneNode.enable` (179) | plain flag set | `wlr_scene_node_set_enabled` wlr:1236 — also damages old visibility region and re-runs visibility update | N/A | close semantics, divergent side effects — wlroots damages on every toggle |
| `SceneNode.destroy` (185) | free node + subtree, detach from parent | `wlr_scene_node_destroy` wlr:99 — emits destroy signal, sends buffer output_leave, releases buffer/texture, recurses | N/A | divergent — ours has no destroy event, no buffer release hooks |
| `SceneNode.absolutePosition` (202) | sum ancestor offsets + own size | `wlr_scene_node_coords` wlr:1336 — layout coords + enabled flag (no size); size via `scene_node_get_size` wlr:1221 | N/A | close |
| `SceneBufferNode` (234) | texture + src crop + dst size + opacity | `wlr_scene_buffer` wlrH:166; create wlr:870; `set_source_box` wlr:1082, `set_dest_size` wlr:1098, `set_opacity` wlr:1127, `set_transform` wlr:1110 | `TextureRenderElement` element/texture.rs:419 with `RenderElement::draw` element/mod.rs:572 | close core, divergent extras — wlroots adds filter mode, opaque region, colorimetry, transform, single-pixel fast path, output enter/leave/frame_done events; wlroots holds a `wlr_buffer` + lazy texture, ours holds a Texture directly |
| `SceneRectNode` (245) | solid RGBA rect fill | `wlr_scene_rect` wlrH:142; create wlr:761, `set_size` wlr:781, `set_color` wlr:793 | `SolidColorRenderElement` element/solid.rs:131 | close — wlroots color is premultiplied (wlr:763 comment), ours straight alpha |
| `SceneOutput` (255) | per-output view: offset + damage ring | `wlr_scene_output` wlrH:225 | `OutputDamageTracker` damage/mod.rs:193 | close in spirit |
| `SceneOutput.create` (264) | alloc view + 2-slot damage ring | `wlr_scene_output_create` wlr:1766 — also wires output commit/damage/needs_frame listeners, destroy addon, index, syncobj timelines, initial geometry update | `OutputDamageTracker::from_output` damage/mod.rs:309 — auto-tracks output size/scale changes | divergent — wlroots/smithay track output lifecycle, ours is passive |
| `SceneOutput.destroy` (293) | free view + ring, tree untouched | `wlr_scene_output_destroy` wlr:1832 — emits destroy, updates node output masks, frees ring/render list/timelines | N/A | close |
| `SceneOutput.render` (302) | walk tree, cull vs output rect, draw rects+buffers via pass, submit | `wlr_scene_output_commit` wlr:2189 + `build_state` wlr:2313 — render list from per-node visible regions, damage-ring damage, direct scanout, opaque-region background culling wlr:2530-2560 | `OutputDamageTracker::render_output` damage/mod.rs:326 — per-element damage, skips frame when no damage | divergent — ours redraws the whole output every call; wlroots/smithay render only damaged regions |
| damage ring field (258,276) | allocated + freed, never read by render | `wlr_scene_output.damage_ring` wlrH:229 fed by `scene_damage_outputs` wlr:397, consumed by `wlr_damage_ring_rotate_buffer` wlr:2535 | `damage_output` damage/mod.rs:435 + internal damage vec | divergent — ours is a dead field; no partial frames |
| `pickable` flag (80, 222) | compositor flag: cursor/decoration nodes excluded from pick | no flag; per-buffer `point_accepts_input` callback wlrH:181, wired to `wlr_surface_point_accepts_input` surface.c:381,440 | N/A | ours-only mechanism; wlroots input filtering is surface-buffer-driven, ours is a compositor node flag |
| cursor pattern (src/server/main.zig:902-952) | scene nodes: fallback rect + client cursor texture, non-pickable, re-appended to root each frame to stay on top | cursor outside scene: `wlr_output_add_software_cursors_to_render_pass` types/output/cursor.c:91 drawn after scene entries wlr:2619; hardware cursor via wlr_output_cursor | N/A — compositor responsibility in smithay | divergent — same goal (cursor on top, never picked), different mechanism: ours is scene-graph nodes, wlroots is an output render-pass overlay |

## Gaps

Numbered behaviors we lack vs wlroots/smithay, with evidence.

1. No damage-driven partial rendering. `SceneOutput.render` composites the full
   tree every call (scene.zig:302-312) and the damage ring is never consulted
   (only init scene.zig:276, deinit 295, test 597). wlroots damages on every
   node mutation via `scene_node_update` wlr:722 → `scene_damage_outputs` wlr:397
   and renders only the ring's damage at `wlr_damage_ring_rotate_buffer` wlr:2535.
   smithay skips the frame entirely when damage is empty (damage/mod.rs:360-364).
2. No per-node visibility / opaque-region tracking. wlroots computes per-node
   `visible` pixman regions (scene_node_update_iterator wlr:582, `scene_node_opaque_region` wlr:259)
   and culls the background where opaque nodes cover it (wlr:2530-2560).
   Ours only intersects the output rect (renderBuffer/renderRect scene.zig:341-349).
3. No mutation-triggered damage. Every wlroots setter (enable wlr:1236, position
   wlr:1253, source box wlr:1082, dest size wlr:1098, opacity wlr:1127, color
   wlr:793) calls `scene_node_update`. Ours are plain field writes; the
   compositor loop always full-redraws (src/server/main.zig:560-615).
4. No node/buffer events: no destroy signal, no output_enter/output_leave/
   outputs_update/frame_done on buffers (wlrH:172-177; emitted in
   `wlr_scene_node_destroy` wlr:99-112 and `update_node_update_outputs` wlr:426).
   Ours has no event surface at all; frame timing lives in the presentation
   module instead [INFERENCE — src/server/main.zig:122].
5. No direct scanout: `wlr_scene_output_build_state` tries scanout for
   single-entry frames (wlr:2448, `scene_entry_try_direct_scanout` wlr:2061);
   ours always renders through the pass.
6. No output lifecycle hooks: `wlr_scene_output_create` listens to output
   commit/damage/needs_frame and recomputes geometry on mode/scale changes
   (wlr:1766-1830, scene_output_handle_commit wlr:1704). Ours is passive —
   `render()` is invoked by the compositor loop.
7. No z-order operations: place_above/place_below/raise_to_top/lower_to_bottom
   (wlr:1263-1307) are missing; ours only appends (top) and removeChild.
8. No reparent cycle guard: wlroots asserts the new parent is not a descendant
   of the node (wlr:1316-1319); ours asserts only `node != child`
   (scene.zig:161) — a cycle is possible via multi-step reparenting.
9. Missing buffer-node features: transform (wlr:1110), filter mode (wlr:1138),
   opaque region hint (wlr:1062), colorimetry setters (wlr:1148-1186),
   single-pixel-buffer rect fast path (wlr:918-930, wlr:1510-1520),
   damage-optimized buffer swap `set_buffer_with_damage` (wlr:1049).
10. No frame_done propagation: `wlr_scene_output_send_frame_done` wlr:2687
    walks visible buffers and emits frame_done; ours has no equivalent path.
11. Hit-test fidelity: `wlr_scene_node_at` returns rect nodes as hits and the
    caller filters (wlr:1413, iterator wlr:1386-1410); ours hard-codes
    buffer-only hits (scene.zig:224-231), so rect-based interactive elements
    (e.g. resize handles) can never be picked.
12. No scene-level surface/shell helpers: `wlr_scene_surface_create` wlrH:418,
    subsurface/xdg/layer/drag-icon tree creators wlrH:688-740. Ours is
    texture-node based; the compositor wires surface commits by hand
    (src/server/main.zig surface_entries, 80-124, 560-615).

## Verdict

Core shape parity: node tree, buffer/rect drawables, per-output view, painter's
algorithm, and hit testing all map 1:1 to wlroots concepts; smithay has no scene
graph (N/A by design, element-list + OutputDamageTracker instead). Parity level:
close for structure, divergent for lifecycle and performance.

Riskiest divergences: (1) full redraw every frame — no damage ring usage and no
mutation-triggered damage, so the scene cannot scale to multiple outputs or
small updates; (2) no events — output enter/leave, frame_done, and destroy
signals are absent, forcing the compositor to reinvent surface tracking;
(3) no reparent cycle guard and no z-order ops, which can corrupt the tree or
force re-append hacks (cursor main.zig:907-914); (4) pick semantics differ from
wlroots (buffer-only, flag-based) — fine today, a fidelity gap for any future
non-surface interactive node.
