# Compositor/Region/Role — wlroots/smithay diff

References: wlroots 0.20.2 (`~/projects/freedesktop-wlroots-wlroots`, cited as `types/...` and `include/...`), smithay checkout v0.7.0-407-g5fb12b87 (`~/projects/github-Smithay-smithay`, cited as `src/wayland/compositor/...`), our compositor (`src/compositor/compositor.zig`, `region.zig`, `role.zig`). Smithay module is the post-0.7.0 dispatch2/GlobalData tree, so line numbers refer to this checkout.

## Surface

### src/compositor/compositor.zig
- `pub const compositor_version: u32 = 7` — compositor.zig:45
- `pub const Compositor` struct — compositor.zig:47
  - `pub fn setShm(c, state) void` — compositor.zig:61
  - `pub fn init(allocator, io, log_cfg, display) error{OutOfMemory,GlobalCreateFailed}!*Compositor` — compositor.zig:66
  - `pub fn deinit(c) void` — compositor.zig:89
  - `pub fn removeSurface(c, surface) void` — compositor.zig:100
- (private, wire-facing) `createSurface` — compositor.zig:105; `createRegion` — compositor.zig:125; `bindCompositor` — compositor.zig:142; `handleRequest` — compositor.zig:150; `handleDestroy` — compositor.zig:158

### src/compositor/region.zig
- `pub const Region` struct — region.zig:16
  - `pub fn create(allocator, resource) Allocator.Error!*Region` — region.zig:23
  - `pub fn deinit(r) void` — region.zig:36
  - `pub fn add(r, rect) void` — region.zig:43
  - `pub fn subtract(r, rect) void` — region.zig:53
  - `pub fn boundingRect(r) ?Rect` — region.zig:104

### src/compositor/role.zig
- `pub const SurfaceRole` struct — role.zig:20
- `pub const RoleError = error{RoleConflict}` — role.zig:39
- `pub const role_error_code: u32 = 1` — role.zig:46
- `pub fn assignRole(surface, role, role_resource) RoleError!void` — role.zig:52

## Comparison

### Compositor
1. `compositor_version = 7` (compositor.zig:45) — max wl_compositor version advertised.
   - wlroots: `COMPOSITOR_VERSION 6` — types/wlr_compositor.c:19.
   - smithay: `CompositorState::new_v6` creates a version 6 global — src/wayland/compositor/mod.rs:710-713.
   - Verdict: divergent. We advertise one version higher than either reference; the extra slot has no additional request surface [INFERENCE: protocol scanner here generated from the same wayland.xml, whose last wl_compositor version is 6].

2. `Compositor` struct (compositor.zig:47) — allocator, io, log_cfg, display, `surfaces` list, global, optional shm registry.
   - wlroots: `struct wlr_compositor { global, renderer, events { new_surface, destroy }, display_destroy, renderer_destroy }` — include/wlr/types/wlr_compositor.h:276-283.
   - smithay: `CompositorState { compositor: GlobalId, subcompositor: GlobalId, surfaces: Vec<WlSurface> }` — src/wayland/compositor/mod.rs:613-616.
   - Verdict: close. Same shape (global + surface registry); ours has no renderer link and no new_surface/destroy signals; smithay additionally owns the subcompositor global.

3. `setShm` (compositor.zig:61) — attach the SHM buffer registry; attach() routes buffers through it.
   - wlroots: N/A — buffer resolution is centralized in `wlr_buffer_try_from_resource` via the renderer (types/wlr_compositor.c:229-234, renderer set at 1392).
   - smithay: N/A — buffer ownership lives in `src/wayland/buffer`, the compositor module is buffer-agnostic.
   - Verdict: ours-only. Our buffer path is wired to the SHM module instead of a renderer/global buffer registry.

4. `init` (compositor.zig:66) — allocate Compositor, register wl_compositor global.
   - wlroots: `wlr_compositor_create(display, version, renderer)` — types/wlr_compositor.c:1368-1395; also initializes new_surface/destroy signals (1384-1385) and display/renderer destroy listeners.
   - smithay: `CompositorState::new` / `new_v6` — src/wayland/compositor/mod.rs:696-713; registers wl_compositor and wl_subcompositor globals.
   - Verdict: close. Same role; ours takes no renderer, creates no signals, and reports failure via Zig errors instead of NULL.

5. `deinit` (compositor.zig:89) — remove global, destroy all tracked surfaces, free.
   - wlroots: `compositor_handle_display_destroy` — types/wlr_compositor.c:1344-1360; asserts listener lists empty, destroys global, frees.
   - smithay: N/A — `CompositorState` is dropped; globals removed via GlobalId, surfaces freed per client.
   - Verdict: close. wlroots ties teardown to display destroy; ours is explicit.

6. `removeSurface` (compositor.zig:100) — swap-remove from the tracked list; called by Surface.destroy.
   - wlroots: N/A — wlr_compositor keeps no surface registry; consumers observe creation via `events.new_surface` (types/wlr_compositor.c:1320).
   - smithay: surface pushed to `CompositorState.surfaces` at creation — src/wayland/compositor/handlers.rs:86.
   - Verdict: ours-only (with smithay's list as the closest analog). wlroots has no list to remove from.

7. `createSurface` [private] (compositor.zig:105) — create wl_surface resource + Surface, append to list, postNoMemory on failure.
   - wlroots: `compositor_create_surface` — types/wlr_compositor.c:1309-1321; then emits `events.new_surface`.
   - smithay: `CreateSurface` arm — src/wayland/compositor/handlers.rs:75-90; inits SurfaceUserData, pushes to `surfaces`, calls `state.new_surface(&surface)` (trait default src/wayland/compositor/mod.rs:573).
   - Verdict: close. Same flow; ours emits no new-surface notification (see Gaps 1).

8. `createRegion` [private] (compositor.zig:125) — create wl_region resource + Region; region not tracked by compositor.
   - wlroots: `compositor_create_region` — types/wlr_compositor.c:1323-1326, delegating to `region_create`.
   - smithay: `CreateRegion` arm — src/wayland/compositor/handlers.rs:92-100.
   - Verdict: same.

9. `bindCompositor` [private] (compositor.zig:142) — per-client bind creates a compositor resource with our handler.
   - wlroots: `compositor_bind` — types/wlr_compositor.c:1333-1343.
   - smithay: `GlobalDispatch2::bind` — src/wayland/compositor/handlers.rs:38-52.
   - Verdict: same.

10. `handleRequest` [private] (compositor.zig:150) — dispatches create_surface / create_region / release.
    - wlroots: `compositor_impl` — types/wlr_compositor.c:1328-1331 (create_surface, create_region; no release arm needed, wlroots handles destroy implicitly).
    - smithay: request match — src/wayland/compositor/handlers.rs:67-105.
    - Verdict: same; ours adds an explicit `.release` arm.

### Region
11. `Region` struct (region.zig:16) — union-of-rects as `ArrayList(Rect)`, never merged or normalized.
    - wlroots: pixman_region32_t stored as resource user data — types/wlr_region.c:11-15.
    - smithay: `RegionUserData { inner: Mutex<RegionAttributes> }` — src/wayland/compositor/handlers.rs:372-374; `RegionAttributes` is an ordered op log `Vec<(RectangleKind, Rectangle)>` — src/wayland/compositor/mod.rs:289-292.
    - Verdict: divergent. Three representations: eager rect list (ours) vs normalized pixman region (wlroots) vs deferred op log (smithay).

12. `create` (region.zig:23) — allocate and install request/destroy handlers.
    - wlroots: `region_create` — types/wlr_region.c:54-75.
    - smithay: region creation via `data_init.init(id, RegionUserData)` — src/wayland/compositor/handlers.rs:95-100.
    - Verdict: same.

13. `deinit` (region.zig:36) — free rects and struct; invoked from the wire destructor.
    - wlroots: `region_handle_resource_destroy` — types/wlr_region.c:48-52.
    - smithay: N/A — RegionUserData is dropped with the resource.
    - Verdict: same.

14. `add` (region.zig:43) — append rect (empty rects ignored); OOM posts no-memory.
    - wlroots: `region_add` — types/wlr_region.c:21-25, `pixman_region32_union_rect` (normalizes/merges).
    - smithay: `Add` arm pushes `(RectangleKind::Add, rect)` — src/wayland/compositor/handlers.rs:393-399; rect converted by client_scale to logical coords (396-398).
    - Verdict: close. Union semantics match; ours never merges (region can grow unboundedly), smithay scales at ingest, wlroots normalizes.

15. `subtract` (region.zig:53) — split each intersecting rect into up to four parts outside the subtracted area.
    - wlroots: `region_subtract` — types/wlr_region.c:27-36; unions the rect in first, then pixman-subtracts.
    - smithay: `Subtract` arm pushes `(RectangleKind::Subtract, rect)` — src/wayland/compositor/handlers.rs:400-406; evaluation deferred.
    - Verdict: divergent. Ours eagerly materializes and leaves overlapping corner parts (harmless under union semantics); smithay records the op; wlroots lets pixman compute the canonical region.

16. `boundingRect` (region.zig:104) — bounding box of the union, null when empty; consumers snapshot opaque/input regions into single rects.
    - wlroots: N/A — `wlr_region_from_resource` (include/wlr/types/wlr_compositor.h:557) exposes the pixman region; consumers read `pixman_region32_extents` themselves.
    - smithay: N/A — consumers evaluate `RegionAttributes` via `get_region_attributes` — src/wayland/compositor/mod.rs:438.
    - Verdict: ours-only. Convenience helper; the bbox equals pixman extents.

### Role
17. `SurfaceRole` struct (role.zig:20) — name plus client_commit/commit/map/unmap/destroy fn-pointer hooks.
    - wlroots: `struct wlr_surface_role { name, no_object, client_commit, commit, map, unmap, destroy }` — include/wlr/types/wlr_compositor.h:78-133.
    - smithay: N/A — a role is just a `&'static str` (mod.rs:396); there is no hook table, hooks are replaced by pre/post-commit and destruction hooks (mod.rs:499-556).
    - Verdict: close to wlroots. Hook set matches wlroots field-for-field except we lack `no_object` (Gaps 6).

18. `RoleError = error{RoleConflict}` (role.zig:39) — failure signal from assignRole.
    - wlroots: N/A — `wlr_surface_set_role` returns bool — types/wlr_compositor.c:890-912.
    - smithay: `AlreadyHasRole` unit error with Display "Surface already has a role." — src/wayland/compositor/tree.rs:74-82.
    - Verdict: close to smithay; wlroots uses a bool.

19. `role_error_code: u32 = 1` (role.zig:46) — fixed wl_surface error code for role conflicts.
    - wlroots: error code is caller-supplied to `wlr_surface_set_role` — types/wlr_compositor.c:890-891; the defunct-role-object path posts `WL_SURFACE_ERROR_DEFUNCT_ROLE_OBJECT` (=4) — types/wlr_compositor.c:61.
    - smithay: N/A — `give_role` returns `Err(AlreadyHasRole)`; callers post their own error, e.g. `wl_subcompositor::Error::BadSurface` — src/wayland/compositor/handlers.rs:455-457.
    - Verdict: divergent. Ours hard-codes code 1, which the generated wl_surface error enum names `invalid_transform` (documented in role.zig:41-45); wlroots lets each role assign a meaningful code; smithay posts nothing from the role layer.

20. `assignRole` (role.zig:52) — conflict posts code 1 + returns RoleConflict; same-role re-assign refreshes `role_resource`; otherwise sets role and role_resource in one step.
    - wlroots: two separate functions — `wlr_surface_set_role` (types/wlr_compositor.c:890-912, posts caller error, rejects any set while `role_resource != NULL` with "role object still exists" at 903-908) and `wlr_surface_set_role_object` (types/wlr_compositor.c:919-927, registers a destroy listener; `surface_destroy_role_object` at 929-936 unmaps and calls `role->destroy` when the object dies).
    - smithay: `give_role` → `PrivateSurfaceData::set_role` — src/wayland/compositor/tree.rs:170-176; same-role re-assign is allowed, different role returns `Err`; no role-object concept exists.
    - Verdict: divergent. Ours merges role assignment and role-object tracking; we post a fixed error code/resource instead of the caller's, skip the role-object lifetime checks, and never wire role-object destruction to unmap/`role.destroy` (Gaps 3-5). Same-role re-assign semantics match smithay, not wlroots.

## Gaps

1. No new-surface notification. wlroots emits `events.new_surface` (types/wlr_compositor.c:1320); smithay calls `CompositorHandler::new_surface` (src/wayland/compositor/mod.rs:573, invoked at handlers.rs:89). Ours only appends to `c.surfaces` (compositor.zig:114); consumers must poll the list instead of observing creation.
2. Fixed role-conflict error code. Ours posts code 1 (`invalid_transform` in the generated enum) with a fixed message (role.zig:46, 52-67). wlroots posts the caller-supplied code on the caller-supplied resource (types/wlr_compositor.c:895-899), letting each protocol define a meaningful error. A strict client may misread our code 1.
3. No defunct-role-object guard. wlroots blocks `wl_surface.destroy` while a role object exists, posting `WL_SURFACE_ERROR_DEFUNCT_ROLE_OBJECT` (types/wlr_compositor.c:56-65). Ours has no such check in role.zig:52-67, and the destroy path in surface.zig:220 does not consult `role_resource` [INFERENCE: surface.zig destroy body never references role/role_resource per grep at surface.zig:151,154,220-223].
4. Same-role re-assign with a live role object. wlroots rejects any `wlr_surface_set_role` while `role_resource != NULL` (types/wlr_compositor.c:903-908); ours refreshes `role_resource` unconditionally (role.zig:60-63). Smithay also allows same-role re-assign (tree.rs:172-176) but has no role objects, so the wlroots constraint is the behavioral gap.
5. Role-object teardown unwired. wlroots unmaps the surface and calls `role->destroy` when the role object dies (types/wlr_compositor.c:929-936, listener at 914-917). Ours declares the `destroy` hook (role.zig:36-37) but assignRole never registers a destroy listener, so object death leaves the surface mapped with stale role state [INFERENCE: no listener registration anywhere in role.zig].
6. Missing `no_object` flag. wlroots marks object-less roles (e.g. cursor) via `wlr_surface_role.no_object` (include/wlr/types/wlr_compositor.h:84, asserted in set_role_object at types/wlr_compositor.c:921). Ours has no such flag (role.zig:20-38); `role_resource` is merely nullable, so object-less roles are indistinguishable.
7. Region list never normalized. Ours appends rects without merging (region.zig:16-20, 43-45) and can grow without bound under repeated damage-style adds; wlroots pixman normalizes on every union (types/wlr_region.c:24). Behaviorally correct under union semantics, but a memory-growth divergence.
8. No client-scale handling in regions. Smithay converts region coordinates to logical space at ingest using client_scale (src/wayland/compositor/handlers.rs:396-398, 402-404); ours stores raw protocol coordinates (region.zig:131-134). Ours matches wlroots (which also stores raw pixman coords); this is a smithay-only divergence [INFERENCE: scale is applied to opaque/input regions at snapshot time in our surface module, not at ingest].
9. No renderer coupling. wlroots takes a renderer at creation and resolves buffers through it (types/wlr_compositor.c:1368-1370, 1392; set_renderer at 1397). Ours routes buffers through the optional SHM registry (compositor.zig:52-63), so dmabuf-style buffers have no path yet.

## Verdict

Compositor core is at close parity: global lifecycle, surface/region creation, bind, and per-client dispatch all mirror wlroots and smithay one-to-one; the structural gap is the missing new-surface notification (wlroots signal / smithay handler), which downstream modules currently compensate for by polling the surface list. Region semantics match for M1 union usage, but the representation (eager unnormalized rect list vs pixman vs deferred op log) and the absence of smithay's client-scale conversion are real divergences. The riskiest divergence is the role layer: our merged assignRole posts a fixed `invalid_transform` error code (1) instead of a caller-supplied code, skips the `DEFUNCT_ROLE_OBJECT` lifetime guard, and never wires role-object destruction to unmap/`destroy` — strict clients may misread the error, and shells can keep stale mapping state after their role object dies.
