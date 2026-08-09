# Subsurface — wlroots/smithay diff

Scope: wl_subcompositor + wl_subsurface. Our module: src/compositor/subsurface.zig; server-side node sync: src/server/main.zig (syncSubsurfaceNodes, called from renderFrame at main.zig:535). References: wlroots types/wlr_subcompositor.c + types/scene/subsurface_tree.c (0.20.2); smithay src/wayland/compositor/{handlers.rs,tree.rs} (0.7.0). Protocol text: protocols/wayland/wayland.xml.

## Surface

Public items in our module (src/compositor/subsurface.zig):

- `pub const subcompositor_version: u32 = 1` — subsurface.zig:34
- `pub const Subcompositor = struct` — subsurface.zig:36; fields: allocator:37, io:38, log_cfg:39, display:40, compositor:41, global:42, subsurfaces (ArrayList(*Subsurface)):43
- `pub fn Subcompositor.init` — subsurface.zig:46
- `pub fn Subcompositor.deinit` — subsurface.zig:75
- `pub fn Subcompositor.surfaceFromResource` — subsurface.zig:84
- `pub const Subsurface = struct` — subsurface.zig:94; fields: allocator:95, io:96, log_cfg:97, subcompositor:98, resource:99, surface:100, parent:101, x:102, y:103, sync:104
- Internal (behavioral surface of the module): `subsurface_role` — :108; `bindSubcompositor` — :110; `subcompositorRequest` — :118; `getSubsurface` — :129; `subsurfaceRequest` — :193; `subsurfaceDestroy` — :213
- Server integration: `syncSubsurfaceNodes` — src/server/main.zig:957-980

## Comparison

1. subcompositor_version (subsurface.zig:34) — wl_subcompositor protocol v1.
   - wlroots: SUBCOMPOSITOR_VERSION 1 (wlr_subcompositor.c:11); bind caps to version 1 (wlr_subcompositor.c:396).
   - smithay: version handled by wayland-server; GlobalData impl for WlSubcompositor (handlers.rs:442-477). N/A explicit constant.
   - Verdict: same.

2. Subcompositor struct (subsurface.zig:36-43) — global state plus a flat list of all subsurfaces for per-frame sync.
   - wlroots: wlr_subcompositor with display-destroy listener and events.destroy (wlr_subcompositor.c:419-439); no registry of live subsurfaces.
   - smithay: GlobalData per client bind; surface tree lives in PrivateSurfaceData (tree.rs:41-47).
   - Verdict: close. Our global registry exists to compensate for a missing event-driven scene update.

3. Subcompositor.init (subsurface.zig:46) — creates the wl_subcompositor global.
   - wlroots: wlr_subcompositor_create (wlr_subcompositor.c:419-439).
   - smithay: GlobalData::bind (handlers.rs:426-440).
   - Verdict: same.

4. Subcompositor.deinit (subsurface.zig:75) — removes global, frees list.
   - wlroots: subcompositor_handle_display_destroy (wlr_subcompositor.c:406-417).
   - smithay: globals owned by wayland-server GlobalId; N/A explicit destructor.
   - Verdict: close.

5. Subcompositor.surfaceFromResource (subsurface.zig:84) — linear scan of compositor.surfaces to resolve a wl_surface resource.
   - wlroots: wlr_surface_from_resource, resource user-data lookup (wlr_compositor.c:56-63 pattern).
   - smithay: WlSurface::data::<SurfaceUserData> (handlers.rs:153-157).
   - Verdict: ours-only (implementation detail); semantics same. O(n) vs O(1).

6. Subsurface struct (subsurface.zig:94-104) — role object: surface, parent, x/y, sync bool.
   - wlroots: wlr_subsurface with pending/current parent state (position, list link) and synchronized flag; wlr_surface_synced wired to the parent (wlr_subcompositor.c:308-386, 226-250).
   - smithay: SubsurfaceUserData (handlers.rs:486-495) + SubsurfaceState sync AtomicBool (handlers.rs:524-534) + SubsurfaceCachedState location (handlers.rs:498-522).
   - Verdict: close shape; ours has no pending/current split, so position is single-buffered (see row 8).

7. getSubsurface (subsurface.zig:129) — role assignment with parent validation; posts bad_parent (subsurface.zig:147-159).
   - wlroots: subcompositor_handle_get_subsurface — role conflict posts BAD_SURFACE on subcompositor (wlr_subcompositor.c:316-323); self/ancestor parent posts BAD_PARENT (wlr_subcompositor.c:326-333); default synchronized=true (342); inserted top of above list (380-384).
   - smithay: handlers.rs:454-473 — set_parent returns AlreadyHasRole, posts BadSurface (tree.rs:357-386; cycle check 361-366; role check 369-373; duplicate-parent check 375-378).
   - Verdict: divergent. We reject any subsurface-role parent (subsurface.zig:154-159); both references allow nesting and reject only cycles. Our role-conflict error is posted on the wl_surface with code 1 (role.zig:40-54) instead of wl_subcompositor bad_surface.

8. subsurfaceRequest.set_position (subsurface.zig:195-197) — writes ss.x/ss.y immediately.
   - wlroots: writes pending.x/y, applied to current at the next commit via surface_synced move_state (wlr_subcompositor.c:65-73, 236-244).
   - smithay: writes pending SubsurfaceCachedState.location, applied on commit (Cacheable, handlers.rs:512-521); converted by client_scale (handlers.rs:570-581).
   - Verdict: divergent. Ours is immediate, not double-buffered; no fractional/scale handling.

9. subsurfaceRequest.place_above (subsurface.zig:199-202) — no-op.
   - wlroots: restacks the pending list link above the sibling/parent; posts bad_surface if the reference is not a sibling or parent (wlr_subcompositor.c:95-123).
   - smithay: reorder(Location::After) on the parent children vec; posts BadSurface on failure (handlers.rs:583-590; tree.rs:419-448).
   - Verdict: missing. Z-order never changes; no protocol error posted.

10. subsurfaceRequest.place_below (subsurface.zig:203-205) — no-op.
    - wlroots: wlr_subcompositor.c:125-153.
    - smithay: reorder(Location::Before) (handlers.rs:591-597; tree.rs:419-448).
    - Verdict: missing (same as row 9).

11. subsurfaceRequest.set_sync/set_desync (subsurface.zig:206-207) — tracks ss.sync.
    - wlroots: sets synchronized; desync unlocks a cached commit when no ancestor is synced (wlr_subcompositor.c:155-182); enforcement via subsurface_is_synchronized walk-up (13-24), pending-state lock on child commit (262-280), unlock on parent commit (282-294); lock primitives wlr_surface_lock_pending/unlock_cached (wlr_compositor.c:942-950).
    - smithay: stores AtomicBool (handlers.rs:599-614); is_effectively_sync recurses up parents (handlers.rs:537-552); commit() merges sync-child transactions and commits the sync subtree with the parent (tree.rs:281-329, 258-278).
    - Verdict: divergent. Tracked but not enforced: every commit applies immediately (module doc subsurface.zig:8-11; surface.zig:307-357 commit path has no cached/locked state).

12. subsurfaceDestroy (subsurface.zig:213-227) — clears role/role_resource; surface keeps rendering as a plain surface.
    - wlroots: role-object destroy → surface_destroy_role_object → wlr_surface_unmap immediately (wlr_compositor.c:929-940, 854-872); recursive unmap of children (865-871); protocol mandates "The wl_surface is unmapped immediately" (protocols/wayland/wayland.xml:3301).
    - smithay: destroyed() unsets parentship, resets sync and location state (handlers.rs:622-645); no library-level unmap — buffer/mapped state stays with the compositor.
    - Verdict: divergent vs wlroots (protocol violation: ours keeps the surface mapped); matches smithay library behavior. Also ours never posts defunct_role_object for the reverse direction (see Gap 4).

13. syncSubsurfaceNodes (src/server/main.zig:957-980) — per frame, positions every child at parent absolute + (x,y), enables it, re-appends the node at the scene root end (always top).
    - wlroots scene: nested tree per surface; below-list, parent, above-list ordering via scene place_above; clip to parent clip; map/unmap toggles node enabled (subsurface_tree.c:104-148, 68-102, 173-187, 238-304); event-driven on surface commit and new_subsurface (157-164, 223-231).
    - smithay: no scene; exposes tree traversal (map_tree, tree.rs:465-551) for the compositor to build render order; ordering encoded in the children vec (tree.rs:43, 419-448).
    - Verdict: divergent. Flat, per-frame, no relative ordering, no clip; child draws above every scene node, not just its parent.

## Gaps

1. Sync mode is not enforced — cached-commit locking is absent. wlroots locks a synced child's pending state and flushes it on parent commit (wlr_subcompositor.c:262-294; wlr_compositor.c:942-950); smithay routes sync children through PendingTransaction/commit_sync_surface_tree (tree.rs:258-329). Our commit applies pending immediately regardless of ss.sync (surface.zig:307-357; subsurface.zig:206-207 only flips a bool). Tearing during parent updates is possible.
2. place_above/place_below are no-ops and post no error (subsurface.zig:199-205). Protocol requires restacking and bad_surface for a reference that is neither sibling nor parent (protocols/wayland/wayland.xml:3330-3336); wlroots wlr_subcompositor.c:95-153, smithay handlers.rs:583-597. Z-order is fixed: child always on top of the whole scene.
3. Destroying wl_subsurface does not unmap the surface (subsurface.zig:213-227). Protocol: "The wl_surface is unmapped immediately" (protocols/wayland/wayland.xml:3301). wlroots unmaps (wlr_compositor.c:929-940); smithay unparents and resets state (handlers.rs:622-645) but leaves display state to the compositor. Ours keeps rendering the surface as a plain surface.
4. No lifecycle listeners — parent or child wl_surface destruction leaves raw pointers dangling: Subsurface.surface/parent are `*Surface` (subsurface.zig:100-101) and Surface.destroy frees the struct (surface.zig:220-255); syncSubsurfaceNodes dereferences them per frame (main.zig:959-964). Use-after-free when the parent or the child surface dies while the wl_subsurface lives. wlroots handles both directions (parent_destroy listener wlr_subcompositor.c:253-259; role destroy 211-218; defunct_role_object error on surface-destroy wlr_compositor.c:56-64); smithay cleanup orphans the tree (tree.rs:126-149).
5. Nesting (sub-subsurfaces) is rejected (subsurface.zig:154-159), while both references reject only cycles (wlr_subcompositor.c:326-333; tree.rs:361-366; protocol bans only descendants, wayland.xml:3230-3232). Tree depth in ours is 1.
6. Position is single-buffered and immediate (subsurface.zig:195-197) vs double-buffered pending/current in both references (wlr_subcompositor.c:65-73 + 236-244; handlers.rs:570-581 + 512-521), and has no client_scale conversion (smithay handlers.rs:571).
7. Parent-map gating is indirect and frame-lagged: the child maps when it has a buffer; it is hidden only when the parent node is gone at frame time (main.zig:966-975). wlroots gates on parent mapped state (subsurface_consider_map wlr_subcompositor.c:195-200; recursive unmap wlr_compositor.c:854-872; scene enable/disable subsurface_tree.c:173-187); protocol: child maps only when parent is mapped (wayland.xml:3254-3258).
8. No clipping of children to the parent (wlroots scene implements clip in subsurface_tree.c:68-102, 328-360). Not a protocol violation — the protocol states subsurfaces are not auto-clipped (wayland.xml:3251-3252) — but a wlroots-scene feature we lack.
9. Z-order across multiple surfaces is wrong by construction: every frame re-appends children to the scene root (main.zig:969-971), so a subsurface draws above every other surface in the scene, not merely above its parent and siblings (wlroots keeps children inside the parent's tree node, subsurface_tree.c:238-304). [VERIFIED 2026-08-09: code claim confirmed at main.zig:969-971 (children re-appended per frame); visibility restricted to multi-toplevel/overlap scenarios — our E2E client creates exactly one toplevel (client.zig), so the defect is latent in the gate.]

## Verdict

Protocol object model parity: v1 global, get_subsurface with role permanence, set_position, sync/desync flag, and immediate destroy are present. Parity ends there: sync is not enforced, place_above/place_below are no-ops, destroy leaves the surface mapped, and lifecycle is unguarded. Riskiest divergences: (1) missing destroy/parent-destroy listeners cause use-after-free when a parent or child surface dies while the wl_subsurface lives; (2) sync ignored means parent-commit atomicity is absent (tearing); (3) flat per-frame re-append gives wrong stacking without relative order or clip. Level: workable for foot (single toplevel, no nesting, teardown-only subsurface destroy) but not compositor-grade.
