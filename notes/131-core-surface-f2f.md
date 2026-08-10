# 131: Core surface cluster — function-level audit (round 2, deep)

Scope: `src/core/display.zig`, `src/core/wire.zig`, `src/compositor/compositor.zig`,
`src/compositor/surface.zig`, `src/compositor/region.zig`, `src/buffers/shm.zig`,
`src/buffers/buffer.zig`, `src/compositor/role.zig`.
References: wlroots 0.20.2 (`types/wlr_compositor.c`, `types/wlr_region.c`,
`types/buffer/buffer.c`, `types/wlr_shm.c`, `include/wlr/types/wlr_compositor.h`),
smithay 0.7.0-407-g5fb12b87 (`src/wayland/compositor/{handlers,mod,tree,transaction,cache}.rs`,
`src/wayland/shm/*`, `src/wayland/buffer/mod.rs`), wayland-rs a55c54b
(`wayland-server/src/{display,global}.rs`, `wayland-backend/src/rs/server_impl/registry.rs`),
KWin master 573c16d (`src/wayland/{compositor,surface,region,shmclientbuffer}.cpp`),
libwayland (`src/wayland-server.c`, `src/wayland-shm.c`).
Prior notes: 101 (display), 102 (compositor/region/role), 103 (surface), 104 (buffers),
119 (buffer lifecycle), 130 (versioning). This round: full private-fn inventory, state
fields, error paths, ordering, ownership — usable as impl backlog. No builds/tests run.

## 1. wl_display / wl_registry / wl_client core

### 1.1 Function-level table

| ours | wlroots | smithay (wayland-rs) | libwayland | what it does |
|---|---|---|---|---|
| `CompositorDisplay.init` display.zig:28 | `wl_display_create` (via tinywl.c:910) | `Display::<State>::new` display.rs:43 | wl_display_create wayland-server.c:1274 | create server object |
| `deinit` display.zig:46 | tinywl.c:1075+1099 (destroy_clients then destroy) | N/A (drop) | wl_display_destroy wayland-server.c:1395 | teardown |
| `initShm` display.zig:61 | `wlr_shm_create_with_renderer` wlr_shm.c:553 | `ShmState::new` shm/mod.rs:143 | wl_display_init_shm wlshm:475 | advertise wl_shm v2 |
| `addSocketAuto` display.zig:76 | `wl_display_add_socket_auto` wls:1996 | `ListeningSocket::bind_auto` socket.rs:65 | wl_display_add_socket_auto | listen socket wayland-N |
| `getServer` display.zig:86 | N/A | `Display::handle` display.rs:50 | — | raw handle |
| `run` display.zig:91 | wl_display_run | backend loop | wl_display_run wls:1729 | event loop |
| `terminate` display.zig:95 | wl_display_terminate | N/A | wl_display_terminate wls:1697 | stop loop |
| `loopFd` display.zig:101 | wl_display_get_event_loop | N/A | wls:1717 | loop fd |
| `dispatch` display.zig:107 | wl_event_loop_dispatch | `dispatch_clients` display.rs:58 | wls:1741 | dispatch once |
| `flushClients` display.zig:112 | wl_display_flush_clients | `flush_clients` display.rs:63 | wls:1738 | flush buffered events |
| `nextSerial` display.zig:117 | wl_display_next_serial | N/A | wls:1705 | serial counter |
| `addGlobal` display.zig:123 | wl_global_create | `create_global` display.rs:126 | wl_global_create wls:1456 | register global |
| `attachProtocolLogger` display.zig:137 | N/A | N/A | wl_display_add_protocol_logger | wire logging |

wl_registry: not implemented by us, wlroots, or smithay — libwayland owns the registry
(registry_interface wayland-server.c:1096) and the wayland-rs backend owns its registry
(check_bind registry.rs:106-126). No code on our side to compare.

### 1.2 Bind-time version validation (re-verified per note 130)

- libwayland `registry_bind` wayland-server.c:1060-1094: rejects unavailable/not-visible
  global, interface-name mismatch, version 0, version > global version; then calls the
  bind callback with the CLIENT-REQUESTED version. No clamping.
- wayland-rs `check_bind` registry.rs:106-126: same four checks (name 0/version 0 →
  None; name mismatch → None; `target_global.version < version` → None).
- ours: `CompositorDisplay.addGlobal` display.zig:123 → `Global.create` (zws:120-131) →
  wl_global_create with the advertised version. Bind callbacks receive `version` from
  libwayland and create resources at that version (e.g. bindCompositor compositor.zig:142-147).
  Verified: no bind handler clamps; child objects (wl_surface, wl_region) are created at
  the parent resource's version (compositor.zig:107, 127; same as wlroots
  compositor_create_surface wlr_compositor.c:1309-1320, KWin compositor.cpp:39-47,
  smithay data_init). Request-side gating by libwayland (wls:459-465). CONFORMANT.

### 1.3 Findings (core display)

F11. [LOW] Client teardown at display destroy is missing.
ours: `CompositorDisplay.deinit` display.zig:46-59 calls only `Server.destroy`
(= wl_display_destroy), which does NOT destroy clients (wayland-server.c:1395-1418
frees sockets/loop/globals only). Surface.destroy's inerting comment (surface.zig:301-307)
claims "display.deinit destroying clients" — that teardown never happens; live clients
and their resources leak at shutdown. wlroots explicitly calls `wl_display_destroy_clients`
before destroy (tinywl.c:1075), and libwayland documents destroy_clients as the required
pre-step (wls:1769-1777). Fix: call `server.destroyClients()` (zws wrapper exists) in
`deinit` before `server.destroy()`. FIXABLE-in-module.
FIXED 2026-08-10: display.zig deinit now calls `server.destroyClients()` (zws
`wl.Server.destroyClients` → wl_display_destroy_clients, wayland_server_core.zig:63-64)
before `server.destroy()`, matching tinywl.c:1075 and libwayland's documented pre-step;
the existing display deinit test exercises the path.

F12. [LOW] `Global.remove()` (unpublish only) leaves a late-bind UAF window.
ours: `Compositor.deinit` compositor.zig:89-99 calls `g.remove()` (= wl_global_remove
wls:1596-1610), which sends global_remove but keeps the global in the display's
global_list and bindable; `registry_bind` wls:1060-1094 would still call `bindCompositor`
with the freed Compositor as data. wlroots destroys the global outright at display
destroy (`wl_global_destroy`, compositor_handle_display_destroy wlr_compositor.c:1346-1359)
and note libwayland's own docs recommend destroy only when no more binds can arrive.
In practice the window is process-shutdown-only (no new clients), but a test harness
connecting after deinit would UAF. Fix: use `g.destroy()`; keep `remove()` only when the
global must stay bindable for stragglers. FIXABLE-in-module.
FIXED 2026-08-10: Compositor.deinit uses `g.destroy()` (wl_global_destroy) instead of
`g.remove()` — the global leaves the display's global_list and is freed, so a late
registry_bind cannot reach the freed Compositor; `remove()` remains available for
straggler-safe paths (none currently). Teardown order now matches
compositor_handle_display_destroy (wlr_compositor.c:1346-1359): destroy signal →
global destroy → surface destroy. In main.zig, compositor.deinit runs before
display.deinit's destroyClients, so bound clients still get global_remove before teardown.

## 2. wl_compositor

### 2.1 Function-level table

| ours | wlroots | smithay | KWin | what it does |
|---|---|---|---|---|
| `compositor_version=7` compositor.zig:45 | `COMPOSITOR_VERSION 6` wlr_compositor.c:19 | `CompositorState::new_v6` mod.rs:710-713 | `s_version = 6` compositor.cpp:19 | advertised version |
| `Compositor` struct compositor.zig:47 | `struct wlr_compositor` wlr_compositor.h:276-283 | `CompositorState` mod.rs:613-616 | CompositorInterface | state: surfaces, global, shm |
| `setShm` compositor.zig:61 | N/A (renderer set via `wlr_compositor_set_renderer` wlr_compositor.c:1397) | N/A (buffer-agnostic) | N/A | wire buffer registry |
| `init` compositor.zig:66 | `wlr_compositor_create` wlr_compositor.c:1368 | `CompositorState::new` mod.rs:696 | ctor compositor.cpp:32 | register global + alloc |
| `deinit` compositor.zig:89 | `compositor_handle_display_destroy` wlr_compositor.c:1346 | drop | dtor compositor.cpp:65 | unregister + destroy surfaces |
| `removeSurface` compositor.zig:100 | N/A (no registry; `events.new_surface`) | `surfaces.retain` handlers.rs:357-360 | QObject parent | drop from list |
| `createSurface` compositor.zig:105 | `compositor_create_surface` wlr_compositor.c:1309 + `surface_create` :742 | `data_init.init` handlers.rs:82-90 | compositor.cpp:39 | create wl_surface at bind version |
| `createRegion` compositor.zig:125 | `compositor_create_region` wlr_compositor.c:1323 | handlers.rs:376-384 | compositor.cpp:49 | create wl_region at bind version |
| `bindCompositor` compositor.zig:142 | `compositor_bind` wlr_compositor.c:1333 | `GlobalDispatch2::bind` | QtWaylandServer | per-client resource |
| `handleRequest` compositor.zig:150 | `compositor_impl` wlr_compositor.c:1325-1331 | `Dispatch2` | generated | dispatch create_surface/region/release |
| `handleDestroy` compositor.zig:158 | N/A (no destroy fn; global lives on) | destructor | generated | per-client resource teardown |

### 2.2 Findings (compositor)

F21. [LOW] No `new_surface`/`destroy` signals on Compositor.
wlroots emits `events.new_surface` at create (wlr_compositor.c:1318-1320) and
`events.destroy` at teardown (:1348-1350); consumers observe creation instead of
polling the list. ours: consumers poll `c.surfaces` (server/main.zig). No current
consumer needs the signal; add only when a listener appears. FIXABLE-in-module.
FIXED 2026-08-10: Compositor now has `events.new_surface: wire.Signal(*Surface)`
(emitted in createSurface after list append) and `events.destroy: wire.Signal(*Compositor)`
(emitted at deinit start), mirroring wlr_compositor.c:1318-1320/1348-1350 with the
xdg.zig signal pattern (init after construction, emit on event). main.zig wiring
SKIPPED (documented): syncSurfaces already polls `compositor.surfaces.items` for
surface_entries tracking (main.zig:1509-1530), so the event would be redundant; wiring
it would change no behavior. Test: compositor.zig "new_surface and destroy signals fire".

F22. [LOW] Version 7 vs 6 — resolved in note 130: vendored wayland.xml declares
wl_compositor v7 (protocols/wayland/wayland.xml:197); the v7 slot adds only
wl_surface.get_release, which we implement (see F62). wlroots/KWin cap at 6; smithay's
protocol crate has v7 but its handler panics on GetRelease (F62). No action.
VERIFIED 2026-08-10: resolution still consistent. Vendored
protocols/wayland/wayland.xml:197 declares wl_compositor version 7; build.zig:33
generates it at 7; `compositor_version = 7` (compositor.zig:45) advertises exactly the
generated version. The v7-only slot is wl_surface.get_release, implemented
(surface.zig:626-643, no_buffer error matches the spec). Bind-time version validation
is conformant per §1.2/note 130 (no clamping; child objects inherit the bind version).
No code change.

## 3. wl_surface (the bulk)

### 3.1 Public fn table

| ours | wlroots | smithay | KWin | what it does |
|---|---|---|---|---|
| `State` surface.zig:119 | `struct wlr_surface_state` wlr_compositor.h:35-108 | `SurfaceAttributes` mod.rs:230-289 | `SurfaceState` surface.cpp:50 | double-buffered state |
| `State.init` surface.zig:153 | `surface_state_init` wlr_compositor.c:670 | `Default` | ctor surface.cpp:577 | zero-init + damage/region lists |
| `State.deinit` surface.zig:160 | `surface_state_finish` wlr_compositor.c:692 | drop | dtor surface.cpp:586 | free lists + callbacks |
| `Surface.create` surface.zig:241 | `surface_create` wlr_compositor.c:742 | `data_init.init` handlers.rs:82 | ctor surface.cpp:460 | alloc + set handler |
| `Surface.destroy` surface.zig:292 | `surface_handle_resource_destroy` wlr_compositor.c:724 | `destroyed` handlers.rs:348-362 | dtor surface.cpp:464 | full teardown |
| `attachBuffer` surface.zig:363 | `set_pending_buffer_resource` wlr_compositor.c:38 (lock model differs) | Attach arm handlers.rs:168-210 | surface.cpp:224 | pending buffer + lock |
| `commit` surface.zig:402 | `surface_handle_commit` wlr_compositor.c:575 | Commit arm handlers.rs:266-278 + `PrivateSurfaceData::commit` tree.rs:281 | surface.cpp:280 | client commit pipeline |
| `applyCommit` surface.zig:431 | `surface_commit_state` wlr_compositor.c:511 | `Transaction::apply` transaction.rs:207 | `applyState` surface.cpp:621 | apply pending→current |
| `sendFrameDone` surface.zig:524 | `wlr_surface_send_frame_done` wlr_compositor.c:1131 | compositor-side (WlCallback dispatch handlers.rs:644) | `frameRendered` surface.cpp:496 | done(msec) + destroy callbacks |
| `setEntered` surface.zig:533 | `wlr_surface_send_enter` wlr_compositor.c:1078 | compositor-side | compositor-side | output enter tracking |
| `setLeft` surface.zig:541 | `wlr_surface_send_leave` wlr_compositor.c:1111 | compositor-side | compositor-side | output leave |
| `validatePending` surface.zig:552 | `surface_finalize_pending` wlr_compositor.c:186 (subset) | n/a (validated at commit) | n/a | size/scale checks |
| `swapState` surface.zig:740 | `surface_state_move` wlr_compositor.c:321 | `Cacheable::commit/merge_into` handlers.rs:110-150 | `SurfaceState::mergeInto` surface.cpp:596 | transfer pending→current |

### 3.2 Private/request fn table (every request + internal)

| ours | wlroots | smithay | KWin | what it does |
|---|---|---|---|---|
| `handleAttach` surface.zig:568 | `surface_handle_attach` wlr_compositor.c:68 | Attach handlers.rs:168 | surface_attach surface.cpp:224 | v5+ offset error; wrap+lock buffer |
| `handleDamage` surface.zig:596 | `surface_handle_damage` wlr_compositor.c:91 | Damage handlers.rs:211 | surface_damage surface.cpp:243 | accumulate surface damage |
| `handleDamageBuffer` surface.zig:603 | `surface_handle_damage_buffer` wlr_compositor.c:626 | DamageBuffer handlers.rs:304 | surface_damage_buffer surface.cpp:455 | accumulate buffer damage |
| `handleFrame` surface.zig:613 | `surface_handle_frame` wlr_compositor.c:108 | Frame handlers.rs:226 | surface_frame surface.cpp:248 | create wl_callback v1 |
| `handleGetRelease` surface.zig:626 | NONE (wlroots v6) | PANIC (unreachable) | NONE | release callback (v7) |
| `handleSetOpaqueRegion` surface.zig:645 | `surface_handle_set_opaque_region` wlr_compositor.c:127 | SetOpaqueRegion handlers.rs:242 | surface_set_opaque_region surface.cpp:266 | snapshot region |
| `handleSetInputRegion` surface.zig:661 | `surface_handle_set_input_region` wlr_compositor.c:140 | SetInputRegion handlers.rs:254 | surface_set_input_region surface.cpp:273 | snapshot region |
| `handleSetBufferTransform` surface.zig:676 | `surface_handle_set_buffer_transform` wlr_compositor.c:601 | SetBufferTransform handlers.rs:280 (no error!) | surface.cpp:438 | validate + set |
| `handleSetBufferScale` surface.zig:685 | `surface_handle_set_buffer_scale` wlr_compositor.c:614 | SetBufferScale handlers.rs:291 | surface.cpp:447 | validate > 0 + set |
| `handleOffset` surface.zig:693 (NO-OP) | `surface_handle_offset` wlr_compositor.c:640 | Offset handlers.rs:321 | surface_offset surface.cpp:459 | store dx/dy |
| `handleRequest` surface.zig:848 | `surface_implementation` wlr_compositor.c:648-661 | `Dispatch2::request` handlers.rs:157 | generated | dispatch |
| `handleDestroy` surface.zig:876 | `surface_handle_destroy` wlr_compositor.c:56 | Destroy handlers.rs:334 (no role check) | surface_destroy surface.cpp:219 (no role check) | role check + destroy |
| `updateBufferDamage` surface.zig:715 | `surface_update_damage` wlr_compositor.c:248 | DamageBuffer translation in applyState surface.cpp:664-668 | translate damage to buffer space |
| `fireReleaseCallbacksCurrent/Pending` surface.zig:699/704 | N/A | N/A | N/A | v7 get_release done(0) |
| `regionModFromResource` surface.zig:763 | `wlr_region_from_resource` wlr_region.c:16 | `r.data::<RegionUserData>` handlers.rs:244 | `RegionInterface::get` region.cpp:43 | resource→region |
| `copyRegionRects` surface.zig:773 | pixman_region32_copy wlr_compositor.c:133-138 | clone handlers.rs:243 | `region().scaled` surface.cpp:267 | deep-copy snapshot |
| `inverseTransform` surface.zig:787 | `wlr_output_transform_invert` util/transform.c:3 | `OutputTransform::inverted` | — | invert transform |
| `scaleCoord` surface.zig:799 | `wlr_region_scale` util/region.c | `to_logical(client_scale)` | `scaled(1/scale)` | saturating scale |
| `transformRect` surface.zig:821 | `wlr_region_transform` util/region.c:57 | transform in applyState | `mapToBuffer` | transform rect |

### 3.3 State fields (ours vs wlroots)

| ours field | wlroots field | present in smithay | present in KWin | note |
|---|---|---|---|---|
| `buffer` surface.zig:121 | `state->buffer` wlr_compositor.h:44 + surface->current.buffer | `buffer: BufferAssignment` | `buffer: QPointer<GraphicsBuffer>` | see F32 (lock model) |
| `surface_damage` :122 | `surface_damage` :53 | `damage: Vec<Damage>` | `damage: RegionF` | ours keeps both damage spaces |
| `buffer_damage` :124 | `buffer_damage` :54 | same enum | `bufferDamage: Region` | ✓ |
| `opaque` :126 | `opaque` :56 | `opaque_region` | `opaque: RegionF` | ✓ snapshot |
| `input` :128 | `input` :57 | `input_region` | `input: RegionF` | ✓ snapshot |
| `transform` :130 | `transform` :61 | `buffer_transform` | `bufferTransform` | ✓ |
| `scale` :132 | `scale` :60 | `buffer_scale` | `bufferScale` | ✓ |
| `frame_callbacks` :134 | `frame_callback_list` :59 | `frame_callbacks` | `frameCallbacks` | ✓ |
| — | `dx/dy` (OFFSET) :58 | `buffer_delta` | `offset` | MISSING (F34) |
| — | `width/height` :36-37 | computed | `surfaceSize` | derived on demand (M1) |
| — | `committed` mask :38 | (Rust: commit/merge) | `committed: Fields` | ours has no mask (F33) |
| — | `viewport` :62-72 | viewport module | `viewport` | no viewporter (out of scope) |
| — | `cached_state_locks` / `cached` list | TransactionQueue | Transaction | ours: single bool (F35) |
| `Surface.buffer` mirror :177 | `surface->buffer` (texture/client buffer) :144 | texture ref | `bufferRef` | M1: raw wrapper, not texture |

### 3.4 Commit pipeline step order (ours vs wlroots)

wlroots `surface_handle_commit` wlr_compositor.c:575-598 + `surface_commit_state` :511-575:
1 finalize_pending (buffer resolve, scale check, damage clip, viewport size)
2 role->client_commit (:582-584)
3 emit client_commit signal (:587)
4 if rejected → return; if cached_state_locks>0 or cached list nonempty → surface_cache_pending (move pending into cached list) else commit_state
5 commit_state: unmap on NULL-buffer commit (:513-522)
6 surface_state_move (pending→current, committed-bit filtered, buffer lock/unlock, damage copy, callbacks move, subsurface order, seq bump)
7 surface_update_damage (:529)
8 surface_apply_damage (texture upload) (:531-533)
9 update opaque/input regions (:534-535)
10 subsurface parent-commit hooks (:537-544)
11 synced commit hooks (:548-554)
12 role->commit (:562-565)
13 emit commit signal (:567)
14 wlr_buffer_unlock(current.buffer) + NULL it (:570-574) — AFTER listeners.

ours `commit` surface.zig:402-429 + `applyCommit` :431-523:
1 validatePending (subset of finalize: buffer>0, scale divisibility) — posts error, ABORTS (no role hooks, no signals)
2 emit client_commit signal (:415)
3 if cached_state_locks → return (pending keeps accumulating; single slot) (:421)
4 applyCommit: swapState (full copy, no committed mask) (:438)
5 frame callback appendSlice (OOM → postNoMemory + partial state) (:441-454)
6 drop old buffer + swap release callbacks (:455-474)
7 updateBufferDamage (:478)
8 role->client_commit (:482) — ALSO on cache flushes
9 role->commit + emit commit signal (:489-490)
10 map/unmap transition from `buffer != null && size > 0` (:493-511)
11 unlock current buffer + fire release callbacks (:516-521)

Ordering divergences: F35 (single-slot cache, flush semantics), F36 (role client_commit
on flush), F37 (unmap order), F31 (OOM partial commit), and the map-transition
difference: wlroots maps via explicit `wlr_surface_map` (role-driven, wlr_compositor.c:831-852)
with auto-unmap only on NULL-buffer commit (:513-522); ours auto-maps from
`buffer != null && width>0 && height>0` in the commit itself (:493-511). For the roles we
have (xdg, layer-shell) the observable result matches, but wlroots' split lets roles
delay/map at will. LOW.

### 3.5 Findings (surface)

F31. [MED] OOM mid-commit leaves partial state applied with no signals.
ours: `applyCommit` surface.zig:441-454 — swapState already moved pending→current; a
frame-callback appendSlice OOM posts no_memory, unlocks the buffer, and returns: role
hooks, commit signal, map/unmap transition, release-callback fire all SKIPPED, but
current.buffer now points at the new buffer. wlroots: `surface_cache_pending`
wlr_compositor.c:475-510 — on OOM the pending state stays pending (post_no_memory,
nothing moved). Fix: move the appendSlice (and its OOM path) BEFORE swapState, or
roll back the swap. FIXABLE-in-module.
FIXED 2026-08-10: applyCommit is now transactional — the frame-callback appendSlice
and the damage translation (translateDamage, pre-swap into pending.buffer_damage) run
before swapState; an OOM aborts with the state untouched + postNoMemory, and no
allocation remains after the swap (the post-swap phase is infallible). Damage-union
OOM posts no_memory but no longer aborts the commit (damage is a hint). Test:
"OOM in the commit path aborts without applying partial state" (FailingAllocator).

F32. [MED] Buffer lock model: hold-across-commits vs unlock-every-commit.
ours: `current.buffer` holds a locked reference until replaced or destroyed
(surface.zig:121, 363-400, 516-521); `pending_locked` + lockless re-attach special case
(:368-383) work around it. wlroots: buffer NOT held across commits — lock at
`surface_state_move` (wlr_compositor.c:352-357), unlock+NULL at end of commit_state
(:570-574); re-attach needs no special case. smithay: `merge_into` releases replaced
`BufferAssignment::NewBuffer` (handlers.rs:125-137). Divergence is documented M1; the
consequence: a same-buffer re-attach can never take a second lock, and any consumer
holding `current.buffer` after commit holds an UNLOCKED reference (release already
fired) — future readers must not assume liveness from the lock count. This is the
root cause behind F42 (dead-wrapper display). STRUCTURAL (changing it rewires
surface+buffers+subsurface).
DEFERRED 2026-08-10 fixing round: classified STRUCTURAL — switching to
unlock-per-commit rewires the attach locking, release_callbacks, the subcompositor
flush path, and both destroy paths. Cache-impact evidence (checked before deferring):
the M2 canvas does NOT hold buffer references — main.zig's commit-signal handler
copies the pixels at upload (updateSurfaceNode → surfacePixels →
importSurfacePixels/updateMemory, "the scene node owns the copy",
src/server/main.zig:1618-1703, src/renderer/pixman.zig:137-190), so per-commit unlock
would not free shm under a live texture. The deferral is about the lock-model rewrite
scope (F42 was fixed separately on top of the current model), not a cache hazard.
F51 is tied to this model and deferred with it.

F33. [LOW] No `committed` mask: every commit is a full state copy.
wlroots `surface_state_move` wlr_compositor.c:321-405 applies fields only when the
corresponding `committed` bit is set and resets the mask (:397-399). ours `swapState`
surface.zig:740-762 copies all fields unconditionally. Observably equivalent because
pending values persist (a field never set this cycle keeps its last value, which is
what wlroots would have committed); only damage is affected — wlroots CLEARS
current damage when the bit is absent (:374-385), ours always transfers pending
(empty after a swap → same result). No fix needed; note for future viewporter work.
FIXABLE-in-module (when viewport arrives).
FIXED 2026-08-10: State.committed mask added (buffer/opaque/input/transform/scale/
offset bits), set by the request handlers, consumed and cleared by swapState. The
swap applies only committed fields — behavior-preserving except where wlroots
explicitly clears on an absent bit: the offset (F34) and opaque/input regions (which
the old full copy lost on the next commit, because the swap nulls pending — the mask
now keeps them, matching wlroots). Damage transfers unconditionally (equivalent).
Tests: "uncommitted fields keep their current value across the swap", "opaque and
input regions persist until replaced by a commit".

F34. [MED] `wl_surface.offset` (v5) and pre-v5 attach dx/dy are dropped.
ours: `handleOffset` surface.zig:693-698 is a no-op; State has no dx/dy. All three
references store it: wlroots wlr_compositor.c:640-647 + surface_state_move :340-346
(clears on commits without OFFSET), smithay handlers.rs:321-330 (`buffer_delta`),
KWin surface.cpp:459-461. Consumers: XWayland positioning, cursor hotspots, popup
placement. Ours renders such surfaces at the wrong location (no visible consumer yet:
no XWayland). Add `dx`/`dy` to State, store on handleOffset and pre-v5 attach, expose
for the compositor. FIXABLE-in-module.
FIXED 2026-08-10: State.dx/dy added; handleOffset stores them (committed.offset bit),
handleAttach stores the attach dx/dy at every version (v5+: the mandatory 0, like
wlroots) and sets the bit; swapState applies them and CLEARS current.dx/dy on a
commit without the offset bit (wlr_compositor.c:340-346). Exposed on State for
consumers. Tests: "offset is stored, committed, and cleared by a commit without
one", "pre-v5 attach stores the offset".

F35. [MED] Deferred commits merge into one slot; post-commit requests are applied at
flush (wlroots applies only committed states).
ours: `commit` surface.zig:421-425 keeps the single pending slot accumulating while
`cached_state_locks` is set; `flushCached` subsurface.zig:428-434 re-validates and
applies the MERGED pending — including requests the client made AFTER its last
deferred commit, which wlroots keeps pending (each client commit moves pending into
the cached-state list, wlr_compositor.c:475-510, and `wlr_surface_unlock_cached`
:947-986 applies only cached states in order). Example: sync child commits, then sends
set_buffer_scale(2) without commit; parent commits — ours applies scale 2, wlroots
applies the committed scale and leaves 2 pending. Module comment claims equivalence;
that is not correct for post-commit requests. STRUCTURAL (needs a cached-state list
or an explicit "flush applies only last-committed snapshot" rule).
DEFERRED 2026-08-10 fixing round: classified STRUCTURAL — a faithful fix needs a
per-commit cached-state list on the surface and the flush path lives in
subsurface.zig (flushCached, W3's file); the merged-slot approximation is a
deliberate M1 simplification and observationally equivalent for
buffer/damage/frame-callback behavior. The commit() doc comment now states the
divergence explicitly.

F36. [MED] role.client_commit runs on cache flushes.
ours: `applyCommit` surface.zig:482 runs role.client_commit on EVERY apply, including
subsurface cache flushes; wlroots runs role->client_commit only inside
`surface_handle_commit` (wlr_compositor.c:582-584) and `surface_commit_state` runs
only role->commit (:562-565). The xdg client_commit hook does configure accounting;
running it once at flush (not per cached commit) shifts configure counting for
sync-subsurface xdg popups. Fix: run role.client_commit in `commit()` (before the
deferral check) instead of applyCommit, matching wlroots. FIXABLE-in-module.
FIXED 2026-08-10: role.client_commit moved to commit() (before the client_commit
signal and the deferral check, mirroring wlroots surface_handle_commit
wlr_compositor.c:582-584); applyCommit runs only role.commit, so cache flushes no
longer run client_commit. Consequence for the shell hooks: the xdg/layer
unconfigured/already_constructed checks in the client_commit hooks read
`surface.current.buffer` post-swap today; with the pre-swap placement they must read
`surface.pending.buffer` (wlroots checks pending.buffer_resource) — xdg.zig:1801 and
layer_shell.zig:623 updated by W4/W5 in coordination. Test: "role client_commit runs
per client commit, not on cache flushes".

F37. [LOW] Unmap ordering: role.unmap before unmap signal.
ours: surface.zig:306-311 (destroy path) and :504-510 (commit path) call role.unmap
then emit events.unmap; wlroots `wlr_surface_unmap` wlr_compositor.c:854-872 emits
the signal first, then role->unmap, then recursively unmaps subsurfaces. Also ours
does not recurse into subsurfaces (subsurface module handles orphan re-root in
main.zig:1629-1645 instead). LOW; listeners see hooks before the signal. FIXABLE-in-module.
FIXED 2026-08-10: both unmap sites (Surface.destroy and the commit-path transition)
now emit the unmap signal BEFORE role.unmap, matching wlr_surface_unmap
(wlr_compositor.c:854-872). No listener depended on the old order (verified: no
map/unmap signal consumers outside surface.zig). Test: "unmap signal fires before
the role unmap hook".

F38. [MED] No `previous` state.
wlroots snapshots `surface->previous.{scale,transform,width,height,buffer_width,buffer_height}`
before every commit_state (wlr_compositor.c:523-528); consumers (scene damage, KWin's
applyState diffing surface.cpp:634-655) use it to diff old vs new geometry. ours: no
previous fields; server recomputes surfaceSize per commit (main.zig:1654-1658) and
damages old+new cursor footprints manually. Needed for M2 damage-ring correctness on
transform/scale changes (a scale change currently damages only the new size).
FIXABLE-in-module (copy in applyCommit before swapState).
FIXED 2026-08-10: Surface.previous {scale, transform, buffer_width, buffer_height}
added and snapshotted from the CURRENT state at the top of every applyCommit
(before the swap, wlroots wlr_compositor.c:523-528). Consumers diff previous vs
current to damage the old footprint on geometry changes (M2 damage ring). Test:
"previous state snapshots the pre-commit geometry".

F39. [LOW] `handleDamage`/`handleDamageBuffer` accept negative w/h.
wlroots ignores negative dims at request time (wlr_compositor.c:91-106, 626-639);
smithay rejects them for DamageBuffer (handlers.rs:304-309) but not Damage;
KWin QRegion clamps. ours stores the rects raw (surface.zig:596-611); they are
harmless for rendering (isEmpty at union) but grow the rect list and feed F1's
overflow path at render time. Fix: reject/ignore negative dims like wlroots.
FIXABLE-in-module.
FIXED 2026-08-10: handleDamage/handleDamageBuffer (surface.zig) early-return when
`width < 0 or height < 0` — the rect is ignored, no protocol error. Reference check:
the wl_surface spec (wayland.xml damage/damage_buffer) defines no error for negative
extents and says "the compositor ignores the parts of the damage that fall outside of
the surface"; wlroots ignores (wlr_compositor.c:91-106, 626-639), smithay ignores for
DamageBuffer (handlers.rs:304-309 — the note's "rejects" means rejects-from-list, the
code is `if width < 0 || height < 0 { return; }`), KWin QRegion clamps. Decision:
ignore, per the majority reference and the note's prescription. Zero extents remain
accepted (harmless empties, isEmpty at consume) matching wlroots. Test:
surface.zig "negative damage extents are ignored".

F3A. [LOW] `validatePending` posts invalid_size for cursor surfaces.
wlroots exempts cursor roles from the scale-divisibility error (debug log instead,
wlr_compositor.c:220-240). ours posts the error for every surface (surface.zig:552-566).
Our server never assigns the cursor role (main.zig:195, 2058-2062 — cursor surfaces are
tracked but not roled), so a client with an odd-sized cursor surface at scale 2 gets
killed where wlroots tolerates. Add the role exemption once cursor roles exist.
FIXABLE-in-module.

F3B. [LOW] Error resource for role conflicts differs.
ours posts on the wl_surface with role_error_code=1 (role.zig:46-47, 60-67);
wlroots posts on the caller's `error_resource` (wlr_compositor.c:890-913, e.g. the
xdg_surface resource). Both are fatal; the object that reports differs. LOW.
FIXABLE-in-module.

F3C. [LOW] Re-role allowed after role-object death; wlroots forbids it.
xdg.zig:549-554 clears `surface.role = null` when the xdg_surface dies; wlroots
`surface_destroy_role_object` wlr_compositor.c:929-940 keeps `surface->role` and clears
only `role_resource`, so `wlr_surface_set_role` (:890-913) rejects any later different
role forever. Weston allows re-role [INFERENCE — weston_surface_set_role permits it];
protocol text is silent. Ours matches Weston, wlroots matches a stricter reading.
Document; no fix unless interop demands wlroots' behavior.

F3D. [LOW] smithay/KWin lack the wl_surface.destroy role-object check; ours matches
wlroots (surface.zig:863-872 vs wlr_compositor.c:56-66). CONFORMANT — OK.

## 4. wl_region

### 4.1 Function-level table

| ours | wlroots | smithay | KWin | what it does |
|---|---|---|---|---|
| `Region.create` region.zig:23 | `region_create` wlr_region.c:48 | data_init handlers.rs:376 | ctor region.cpp:13 | alloc + handler |
| `Region.deinit` region.zig:36 | `region_handle_resource_destroy` wlr_region.c:43 | drop | dtor region.cpp:18 | free |
| `Region.add` region.zig:43 | `region_add` wlr_region.c:20 | Add arm handlers.rs:393 | region_add region.cpp:28 | union rect |
| `Region.subtract` region.zig:53 | `region_subtract` wlr_region.c:28 | Subtract arm handlers.rs:400 | region_subtract region.cpp:33 | subtract rect |
| `boundingRect` region.zig:104 | N/A (pixman normalizes; consumers query) | `RegionAttributes::contains` mod.rs:294-306 | `region()` region.cpp:38 | M1 bounding box |
| `handleRequest` region.zig:130 | `region_impl` wlr_region.c:40-42 | Dispatch2 | generated | dispatch |
| `handleDestroy` region.zig:139 | region_destroy wlr_region.c:38 | backend destructor | region.cpp:23 | destroy |

Representation: ours = raw rect list, union-of-rects semantics, no normalization,
overlap legal (region.zig:1-10). wlroots = pixman_region32 (canonical disjoint rect
set, normalized per op). smithay = ordered (Add, Subtract) rect list, painter's
algorithm evaluated per query (mod.rs:289-307, handlers.rs:393-403). KWin = QRegion
(normalized).

### 4.2 Findings (region)

F41. [HIGH] Unchecked client-controlled arithmetic can trap/UB the compositor.
`Rect.intersect`/`Rect.@"union"` (geom.zig:34-52) compute `a.x + a.width` with plain
i32 `+`. Reachable with client values: (a) `Region.subtract` region.zig:63 →
`existing.intersect(rect)` — wl_region.add(INT32_MAX-1, 0, 10, 10) then subtract(0,0,1,1)
overflows; (b) render-time damage translate main.zig:1124-1134 → `out_rect.intersect`
with a saturated x and client width; (c) `Damage.boundingRect` union (raylib.zig:309).
Debug builds trap ("integer overflow") = compositor crash; ReleaseFast = UB. All three
references are guarded: pixman uses validated int64 math internally, wlroots'
`wlr_region_transform`/`wlr_region_scale` use int64 (util/region.c:57-105), smithay
uses checked Rectangle types, KWin QRegion is 64-bit based. Fix: use saturating
`addSat`/`subSat` (already present surface.zig:805-819) inside Rect.intersect/union,
or reject rects whose `x + width` overflows at the request handlers (region.zig:43,
surface.zig:596-611). FIXABLE-in-module.
FIXED 2026-08-10: geom.zig gained pub `addSat`/`subSat` (i32 saturated add/sub,
clamp-at-boundary = the pixman int64-in/int32-out model); Rect.intersect, Rect.@"union"
and Rect.containsPoint now compute every edge via them, so no client-supplied rect can
trap the compositor. Region.subtract's split arithmetic (inter.x - existing.x,
existing.x + existing.width, ...) also switched to geom.addSat/subSat — it recomputed
the same edges outside Rect, so the geom fix alone was not sufficient (verified: the
fuzz's subtract invariant still holds under saturation because part edges are exact).
Callers (a) region.zig subtract, (b) main.zig:1124-1134 damage translate →
out_rect.intersect, (c) Damage.boundingRect union (damage.zig/raylib.zig) are all
protected through the shared Rect helpers. Tests: geom.zig "rect intersect saturates on
client-controlled overflow" + "rect containsPoint saturates"; region.zig "region
extreme coordinates never trap"; region fuzz now mixes in randExtremeRect rects whose
x + width overflows i32.

F42. [MED] Dead pending/current buffer still displays stale content after commit.
Client: attach B → destroy B's wl_buffer → commit. Ours: `shm.resourceDestroy`
(shm.zig:195-221) nulls the wrapper's resource and drops it, but `Surface.pending.buffer`
still points at the dead wrapper; `validatePending` surface.zig:552-566 reads the
stored width (passes); `swapState` makes it current; the map transition
(:493-511) keeps the surface mapped (width>0); the renderer cannot read pixels
(begin_data_ptr_access returns Unsupported on null shm, shm.zig:160-171) → stale
texture persists until the next commit. wlroots: `pending_buffer_resource_handle_destroy`
wlr_compositor.c:49-54 NULLs the pending resource on destroy; the subsequent commit is
a NULL-buffer commit → `wlr_surface_unmap` (wlr_compositor.c:513-522). smithay:
buffer destroy releases the pending BufferAssignment (handlers.rs:233-240). Fix:
surface must observe wrapper death (subscribe to the Buffer destroy signal or have
ShmState notify) and clear `pending.buffer`/`pending_locked` (and `current.buffer`
for the displayed case), so the next commit unmaps. NEEDS-wiring (buffer module →
surface module contract).
FIXED 2026-08-10: implemented with the wlroots mechanism (pending_buffer_resource_
handle_destroy wlr_compositor.c:49-54) instead of a Buffer signal: the surface tracks
`pending_resource`/`current_resource` (moved at applyCommit) and registers one destroy
listener on the attached wl_buffer resource at attach. On resource death the handler
compares resource pointers and clears the matching slot(s) — pending
(buffer + pending_locked, firing pending get_release callbacks) and/or current
(buffer + the s.buffer mirror, firing current callbacks) — so the next commit is a
NULL-buffer commit and unmaps. The handler never dereferences the wrapper: shm's own
resourceDestroy listener runs first in the emission and may have freed it (F52's OOM
fallback). The listener self-detaches and is detached in Surface.destroy. The wiring
stays within surface.zig + the existing Buffer/ShmState API (no Buffer changes).
Tests: "destroying the attached buffer resource unmaps on the next commit",
"destroying the displayed buffer's resource clears the current slot".

F43. [LOW] Region rect count grows unboundedly (no normalization).
Each `add` appends (region.zig:43-51); each `subtract` splits every intersecting rect
into ≤4 parts (:53-122) — O(n) per request, 4x growth per subtract, never merged.
wlroots pixman normalizes after each op (bounded by the canonical rect count of the
set); KWin QRegion likewise. A client can drive memory growth with overlapping adds.
For M1 (opaque/input snapshots) the list is copied wholesale, so accuracy is fine —
only growth differs. Fix: merge/compact on add when a rect is adjacent/contained, or
cap the list. FIXABLE-in-module.
FIXED 2026-08-10: Region.add compacts on insert (the note's merge option): a new rect
contained in an existing one is dropped; an existing rect contained in the new one is
absorbed; overlapping or touching rects sharing an edge alignment (same y+height →
horizontal, same x+width → vertical) merge into their union. Every merge preserves the
represented set exactly (the merged box equals the union of its inputs — alignment
guarantees no invented corners), so a client re-adding the same area cannot grow the
list; repeated overlapping adds of one shape collapse to a single rect. Disjoint
rects still append (union semantics unchanged). subtract parts are left unmerged
(growth there is bounded per intersecting rect; the note's 4x observation stands).
Tests: region.zig "region add compacts overlapping, contained and adjacent rects".

## 5. Buffers (buffer.zig + shm.zig)

### 5.1 Function-level table

| ours | wlroots | smithay | KWin | what it does |
|---|---|---|---|---|
| `Buffer` buffer.zig:44 | `struct wlr_buffer` wlr_buffer.h:17-43 | `Buffer` (Arc<InnerBuffer>) renderer/utils/wayland.rs:60-90 | GraphicsBuffer | buffer abstraction |
| `Impl` buffer.zig:29 | `wlr_buffer_impl` interfaces/wlr_buffer.h:24-32 | N/A | — | vtable |
| `Buffer.init` buffer.zig:65 | `wlr_buffer_init` buffer.c:8 | — | — | alloc + signal init |
| `Buffer.drop` buffer.zig:96 | `wlr_buffer_drop` buffer.c:45 | InnerBuffer::drop wayland.rs:65 | ShmClientBuffer::drop shmclientbuffer.cpp:164 | producer done |
| `Buffer.lock` buffer.zig:102 | `wlr_buffer_lock` buffer.c:55 | — | — | consumer ref |
| `Buffer.unlock` buffer.zig:108 | `wlr_buffer_unlock` buffer.c:60 | — | — | consumer done + release |
| `maybeRelease` buffer.zig:113 | N/A (release in unlock) | — | — | once-only release guard |
| `Buffer.destroy` buffer.zig:123 | (impl->destroy frees whole buffer) buffer.c:44-49 | drop | — | destroy signal + impl + free |
| `ShmState.init` shm.zig:66 | `wlr_shm_create` wlr_shm.c:501 | `ShmState::new` shm/mod.rs:143 | ShmClientBufferIntegration | wl_shm global + formats |
| `ShmState.deinit` shm.zig:88 | `handle_display_destroy` wlr_shm.c:493 | drop | — | reclaim wrappers |
| `ShmState.fromResource` shm.zig:104 | `wlr_buffer_try_from_resource` resource.c:42 | `ShmBufferUserData` lookup shm/mod.rs:228-247 | `Display::bufferForResource` | wrap wl_buffer |
| untracked `fromResource` shm.zig:120 | N/A | N/A | N/A | test-only fresh wrap |
| `shmGetShm` shm.zig:156 | `buffer_get_shm` wlr_shm.c:168 | with_buffer_contents | ShmAttributes | expose shm handle |
| `shmBeginDataPtrAccess` shm.zig:160 | `buffer_begin_data_ptr_access` wlr_shm.c:220 | `Pool::with_data` pool.rs:103 | ShmAccess | SIGBUS-guarded CPU access |
| `shmEndDataPtrAccess` shm.zig:173 | `buffer_end_data_ptr_access` wlr_shm.c:260 | pool.rs:137 | — | end access |
| `shmDestroy` shm.zig:178 | `buffer_destroy` wlr_shm.c:156 | drop | dtor shmclientbuffer.cpp:200 | impl teardown |
| `resourceDestroy` shm.zig:195 | `buffer_handle_resource_destroy` wlr_shm.c:306 | buffer_destroyed handlers.rs:233 | buffer_destroy_resource shmclientbuffer.cpp:164 | client destroyed wl_buffer |
| `releaseNotify` shm.zig:206 | `buffer_handle_release` wlr_shm.c:299 | InnerBuffer::drop → release | GraphicsBuffer::released → onReleased | send wl_buffer.release |
| `shmFromResource` shm.zig:212 | pool_handle_create_buffer wlr_shm.c:314 | CreateBuffer arm shm/handlers.rs:83-135 | ShmClientBuffer ctor shmclientbuffer.cpp:181 | wrap + listeners |

### 5.2 Findings (buffers)

F51. [MED] Release event fires at most once per wrapper lifetime; wlroots fires per
unlock-to-zero.
ours: `maybeRelease` buffer.zig:113-123 guards with `released`; wlroots emits on every
n_locks==0 transition (buffer.c:66-71) and its shm listener re-sends release each time
(wlr_shm.c:299-304). For M1 (no texture cache) once-only is protocol-safe: the first
release already tells the client the buffer is reusable, and the surface stops reading
at the unlock (upload happens in the commit signal, main.zig:1553-1555 → 1618-1703,
BEFORE step-10 unlock, so release never races the copy). BUT it blocks the M2 model:
with a texture cache the same wl_buffer re-attached across frames needs one release
per texture generation, and the guard must move from "per buffer" to "per use".
Also note: ours fires release at ATTACH-time drops of never-committed buffers
(surface.zig:386-395) — harmless (compositor never used it) but differs from wlroots
(no lock at attach). STRUCTURAL (tied to the lock model, F32).
DEFERRED 2026-08-10 fixing round: classified STRUCTURAL and tied to F32's lock
model — switching the release guard from "per buffer" to "per use" is exactly the
unlock-per-commit change deferred with F32 (same rewiring scope). The once-only guard
remains protocol-safe for M1: the commit-signal upload (main.zig:1553-1555 →
1618-1703) copies the pixels BEFORE the commit-end unlock, so wl_buffer.release never
races the copy. Cache evidence for the deferral: the canvas texture cache holds pixel
copies, not buffer references (importSurfacePixels/updateMemory, "the scene node owns
the copy"), so neither F32 nor F51 risks freeing shm under a live texture — the
deferral is purely the lock-model rewrite scope.

F52. [LOW] Graveyard OOM path leaks the wrapper (documented in 119).
shm.zig:212-216: `dead_buffers.append` OOM → `catch return` — wrapper is nulled and
dropped but never freed (leak at deinit). Safe (no UAF), valgrind-visible only under
OOM. wlroots needs no graveyard (refcounts). FIXABLE-in-module (fall back to
immediate free when n_locks==0, else keep a fixed-size stash).
FIXED 2026-08-10: resourceDestroy's graveyard append now falls back — an unlocked
wrapper (n_locks == 0) is freed immediately via Buffer.destroy (safe inside the
destroy signal: signal emission tolerates freeing the current listener, and the
surface-side F42 listeners that run later only compare resource pointers); a locked
wrapper parks in a fixed-size no-allocation stash (ShmState.dead_stash[8]) freed at
deinit. A full stash still leaks (bounded, OOM-only, documented). Test: "graveyard
append OOM frees unlocked wrappers and stashes locked ones" (FailingAllocator +
fabricated wrapper).

F53. [LOW] `Buffer.drop` is idempotent; wlroots asserts `!dropped`.
buffer.zig:96-101 vs buffer.c:45-56. Ours tolerates re-drops (the commit path re-drops
replaced buffers, surface.zig:455-469); wlroots' single-shot drop + refcount-free-at-0
makes double-drop a bug. Ours is more lenient; the `released` guard makes it safe.
OK/documented.
FIXED 2026-08-10 (documentation): kept the lenient cycle-idempotent drop (the commit
path re-drops replaced buffers and the released guard makes it harmless) and added the
wlroots-assert contrast + "keep the leniency; do not add the assert" note to
Buffer.drop's doc (buffer.zig). No code change — adding the assert would fire in
normal operation (re-attach cycles).

F54. [MED] Formats: only ARGB8888+XRGB8888 advertised; no renderer-format integration.
ours: `initShm` display.zig:61-74 uses libwayland's internal wl_shm (always exactly
ARGB8888/XRGB8888 + addShmFormat additions — we add none beyond the base pair).
wlroots advertises the renderer's DATA_PTR texture formats (`wlr_shm_create_with_renderer`
wlr_shm.c:553-578); smithay `ShmState::new` takes an explicit format list plus the
mandatory pair and can `update_formats` (shm/mod.rs:143-173). Clients cannot create
RGB565/YUYV pools here even though the pixman renderer could consume them. Also
libwayland's internal create_pool/create_buffer DO validate size/stride/format
(wlshm.c:449-473); wlroots additionally validates stride per pixel format info
(wlr_shm.c:314-372). Needs a format-query hook on the renderer. NEEDS-wiring.
FIXED 2026-08-10 (verified no-op, with evidence): the renderer ALREADY exposes the
format-query hook — `Renderer.formats: []const u32` (renderer.zig:19-21), and the
pixman renderer creates with `&.{format_argb8888}` (pixman.zig create) — a SINGLE
format, a8r8g8b8, which is a subset of what libwayland's internal wl_shm already
advertises (a8r8g8b8 + x8r8g8b8, display.zig initShm:67-68). The note's claim that
"the pixman renderer could consume RGB565/YUYV" is not true for this renderer:
importMemory/updateMemory copy the bytes verbatim into an a8r8g8b8 texture
(PixmanTextureData), so any non-4-bytes-per-pixel format would render garbage.
There is no renderer-supported format outside the advertised pair, so wiring
renderer.formats → wl_display_add_shm_format would be a no-op; the seam exists
(display.addShmFormat, renderer.formats) for a future renderer with more formats.

F55. [LOW] fromResource errors swallowed at attach (no postNoMemory on OOM).
surface.zig:568-594: `st.fromResource(...) catch null` conflates InvalidBuffer and
OutOfMemory — an OOM silently keeps the previous pending buffer and the client is
never told (no postNoMemory). wlroots surfaces an OOM at commit via post_no_memory.
Fix: split the error handling (InvalidBuffer → keep previous + debug log per M1;
OutOfMemory → postNoMemory). FIXABLE-in-module.
FIXED 2026-08-10: handleAttach no longer conflates the wrap errors — error.InvalidBuffer
now takes the F56 reject path (fatal error on the buffer resource + destroy), and
error.OutOfMemory posts postNoMemory on the surface and returns with the previous
pending buffer untouched (wlroots surfaces the OOM too). The OutOfMemory branch is
not reachable in the unit harness (fromResource fails with InvalidBuffer before any
allocation for fabricated non-shm resources — a real shm buffer is needed to reach
the allocation sites); the split itself is exercised by the F56 test, and the
InvalidBuffer arm asserts the previous pending buffer is kept.

F56. [LOW] Unknown buffer type: keep-previous vs kill-client.
wlroots: attach stores the resource; at commit `wlr_buffer_try_from_resource` fails →
`wlr_surface_reject_pending(surface, buffer_resource, -1, "unknown buffer type")`
(wlr_compositor.c:186-246, 874-889) → posts an error and disconnects. ours: keeps the
previous pending buffer with a warn log (surface.zig:579-591). Divergence is
deliberate M1 leniency; a client attaching a foreign buffer sees a stuck surface
instead of an error. Document or align. FIXABLE-in-module.
FIXED 2026-08-10: aligned with wlroots — an unknown buffer type now posts a fatal
error on the BUFFER resource with code -1 ("unknown buffer type", mirroring
wlr_surface_reject_pending wlr_compositor.c:874-889) and destroys the resource. The
error fires at ATTACH here (ours wraps at attach; wlroots resolves at commit) — same
observable outcome for the client (fatal protocol error + disconnect), and the
previous pending buffer is untouched (the error path never reaches attachBuffer).
Test: "attach of an unknown buffer type posts an error and keeps the previous
pending".

## 6. role.zig

### 6.1 Function-level table

| ours | wlroots | smithay | KWin | what it does |
|---|---|---|---|---|
| `SurfaceRole` role.zig:20 | `struct wlr_surface_role` wlr_compositor.h:193-200 | `&'static str` role + `set_role` tree.rs:166 | `SurfaceRole` surface.cpp:38 | role descriptor |
| `assignRole` role.zig:52 | `wlr_surface_set_role` wlr_compositor.c:890 | `set_role` tree.rs:166-176 | `setRole` surface.cpp:472 | one role per surface |
| `role_error_code=1` role.zig:46 | error on caller's resource :893-899 | AlreadyHasRole error | — | conflict error |
| hooks: client_commit/commit/map/unmap/destroy role.zig:26-37 | same five fn pointers wlr_compositor.h:193-200 | hooks via pre/post-commit hooks mod.rs:454-530 | Transaction extensions | lifecycle callbacks |

### 6.2 Findings (role)

F3B/F3C above. Role gating: wlroots runs role hooks only when
`role_resource != NULL || role->no_object` (wlr_compositor.c:562-565, 582-584, 840-848,
861-869); ours runs them whenever `role != null` (surface.zig:482, 489, 501, 507).
Since xdg/layer_shell clear `surface.role` on role-object death (xdg.zig:549-554), the
practical effect is identical today. If F3C is ever changed (keep role after object
death), the gating must be added. LOW, documented.

## 7. OK areas (function parity confirmed)

- Bind-time version validation end to end (F section 1.2): registry_bind
  wayland-server.c:1060-1094 == wayland-rs check_bind registry.rs:106-126 == our
  Global.create/bind path; child objects inherit bind version (compositor.zig:107,127;
  wlroots wlr_compositor.c:1309-1320; KWin compositor.cpp:39-47; smithay data_init).
- wl_surface.destroy role-object check + defunct_role_object (surface.zig:863-872 ==
  wlr_compositor.c:56-66; KWin/smithay lack it — we match wlroots).
- attach non-zero offset error at v5+ (surface.zig:573-579 == wlr_compositor.c:75-83 ==
  handlers.rs:180-190 == surface.cpp:227-234).
- set_buffer_transform range check → invalid_transform (surface.zig:676-684 ==
  wlr_compositor.c:601-612 == surface.cpp:438-445; smithay posts nothing).
- set_buffer_scale <= 0 → invalid_scale (surface.zig:685-691 == wlr_compositor.c:614-624
  == handlers.rs:291-299 == surface.cpp:447-453).
- Commit pipeline step order for the NON-deferred path: validate → client_commit
  signal → apply → role hooks → commit signal → unlock/release (surface.zig:402-521 vs
  wlr_compositor.c:575-598 + 511-575). Buffer unlock AFTER the commit signal, matching
  wlroots (:570-574), so listeners can read the buffer.
- Frame callbacks: accumulate on current across commits, done(msec)+destroy at present
  (surface.zig:613-624, 524-531 == wlr_compositor.c:108-125, 1131-1139 == KWin
  frameRendered surface.cpp:496-504); callback resource at version 1; destroyed
  without done at surface destroy (surface.zig:326-329 == surface_state_finish
  wlr_compositor.c:692-706).
- NULL-buffer commit unmaps; buffer+positive-size maps (surface.zig:493-511 vs
  wlr_compositor.c:513-522 + wlr_surface_state_has_buffer :827).
- Buffer release timing for the shm path: upload in commit signal → unlock at commit
  end → wl_buffer.release (surface.zig:516-521 + shm.zig:206-210 == wlr_compositor.c:570-574
  + wlr_shm.c:299-304). Verified main.zig copies pixels inside the commit signal
  (main.zig:1553-1555 → updateSurfaceNode :1618 → surfacePixels begin access) BEFORE
  the step-10 unlock — no premature-release race in the current wiring.
- get_release implementation (surface.zig:626-643, 699-712): only we and smithay's
  protocol crate (v7) have the wire; wlroots 0.20.2 and KWin do not implement it
  (v6); smithay's handler PANICS on it (`_ => unreachable!()` handlers.rs:342) — ours
  is the only working implementation. no_buffer error when no pending buffer
  (surface.zig:631-635) matches the spec.
- wl_region semantics: add=union, subtract=set difference (region.zig:43-122 ==
  wlr_region.c:20-35 == region.cpp:28-35 == smithay Subtract marker). Surface
  snapshots opaque/input regions at request time, deep-copied (surface.zig:645-675 ==
  wlr_compositor.c:127-153); null vs empty region semantics match
  (null = no opaque / infinite input; empty = nothing).
- Buffer vtable shape, paired begin/end access assertion, SIGBUS guard via libwayland
  beginAccess (shm.zig:160-171 — libwayland's wl_shm_buffer_begin_access installs the
  same remap SIGBUS handler wlroots/smithay/KWin install).
- State double-buffering transfers: buffer, damage (both spaces), opaque/input,
  transform, scale, frame callbacks (surface.zig:740-762 vs wlr_compositor.c:321-405).
- Damage coordinate translation: scale then inverse transform with saturation
  (surface.zig:715-738, 787-846 vs surface_update_damage wlr_compositor.c:248-286).

## 8. Fixability summary

| finding | severity | class |
|---|---|---|
| F41 rect arithmetic overflow | HIGH | FIXABLE-in-module |
| F42 dead-buffer commit keeps stale content | MED | NEEDS-wiring |
| F35 single-slot deferred cache (flush applies uncommitted requests) | MED | STRUCTURAL |
| F32 hold-the-lock buffer model | MED | STRUCTURAL |
| F51 once-only release vs per-use (M2 blocker) | MED | STRUCTURAL |
| F36 role.client_commit on flush | MED | FIXABLE-in-module |
| F34 wl_surface.offset dropped | MED | FIXABLE-in-module |
| F38 no previous state | MED | FIXABLE-in-module |
| F31 OOM mid-commit partial state | MED | FIXABLE-in-module |
| F54 shm formats hardcoded to base pair | MED | NEEDS-wiring |
| F55 attach OOM swallowed | LOW | FIXABLE-in-module |
| F56 unknown buffer keeps stale pending | LOW | FIXABLE-in-module |
| F39 negative damage dims accepted | LOW | FIXABLE-in-module |
| F43 region rect-list growth | LOW | FIXABLE-in-module |
| F52 graveyard OOM leak | LOW | FIXABLE-in-module |
| F11 no destroy_clients at deinit | LOW | FIXABLE-in-module |
| F12 global remove() UAF window | LOW | FIXABLE-in-module |
| F21 no new_surface signal | LOW | FIXABLE-in-module |
| F37 unmap hook/signal order | LOW | FIXABLE-in-module |
| F3A cursor invalid_size exemption | LOW | FIXABLE-in-module |
| F3B/F3C role error resource / re-role | LOW | FIXABLE-in-module |
| F33 committed mask | LOW | FIXABLE-in-module (defer to viewporter) |
| F22 compositor v7 | LOW | none (resolved 130) |

## 9. Test gaps (impl backlog companion)

- F41: extend the region fuzz (region.zig:184-214) with extreme coordinates
  (x/width near INT32_MAX) and assert no trap; same for damage translate in
  main.zig (needs harness-level test).
- F42: harness test — attach, destroy the wl_buffer resource, commit; expect unmap
  (currently stays mapped).
- F35/F36: harness test with a sync subsurface — commit child, send
  set_buffer_scale without commit, flush on parent commit; assert applied scale.
- F34: offset request stores dx/dy and pre-v5 attach offset maps to it.
- F31: OOM-injection test for frame-callback append after swap.
