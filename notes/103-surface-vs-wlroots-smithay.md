# Surface — wlroots/smithay diff

Note: wlroots 0.20.2 moved the wl_surface implementation into `types/wlr_compositor.c` (no `types/wlr_surface.c`). The public API lives in `include/wlr/types/wlr_compositor.h`. smithay splits the compositor into `handlers.rs`, `mod.rs`, `tree.rs`, `cache.rs`, `transaction.rs`.

## Surface

Public inventory of our module (`src/compositor/surface.zig`, grep `pub const`/`pub fn`):

- `State` struct (surface.zig:82) — double-buffered pending/current state.
  - `committed_buffer|damage|opaque|input|transform|scale` consts (surface.zig:83-88)
  - fields: `committed`, `buffer`, `dx`, `dy`, `surface_damage`, `buffer_damage`, `opaque`, `input`, `transform`, `scale`, `frame_callbacks` (surface.zig:90-116)
  - `init` (surface.zig:119), `deinit` (surface.zig:126)
- `Surface` struct (surface.zig:134) — the wl_surface state machine.
  - `create` (surface.zig:175), `destroy` (surface.zig:220)
  - `attachBuffer` (surface.zig:265), `commit` (surface.zig:307)
  - fields: `buffer`, `pending_locked`, `current`, `pending`, `mapped`, `role`, `role_resource`, `events` {client_commit, commit, map, unmap, destroy}, `release_callbacks_current`, `release_callbacks_pending` (surface.zig:134-173)
- `swapState` top-level fn (surface.zig:516)
- Test-only helpers: `TestWire` (:575), `testCompositor` (:612), `testSurface` (:627), `testBuffer` (:641).

Private request handlers (cited in rows, not inventory): `validatePending`, `handleAttach`, `handleDamage`, `handleDamageBuffer`, `handleFrame`, `handleGetRelease`, `handleSetOpaqueRegion`, `handleSetInputRegion`, `handleSetBufferTransform`, `handleSetBufferScale`, `handleOffset`, `fireReleaseCallbacksCurrent/Pending`, `handleRequest`, `handleDestroy`.

## Comparison

### `State.committed_*` bitfield
- ours: 6-bit committed mask (surface.zig:83-88).
- wlroots: `enum wlr_surface_state_field`, 10 fields incl `BUFFER_DAMAGE`, `FRAME_CALLBACK_LIST`, `VIEWPORT`, `OFFSET` (wlr_compositor.h:22-33).
- smithay: no committed mask; `Cacheable::commit` transfers whole pending fields (handlers.rs:111-123).
- verdict: close. Ours lacks VIEWPORT (no viewporter) and OFFSET/BUFFER_DAMAGE as separate bits.

### `State.buffer` + attach/lock lifecycle
- ours: `current.buffer` holds a locked reference across commits until replaced or destroyed (surface.zig:91, 265-305, 307-340). `attachBuffer` locks on attach; re-attach of the current buffer sets `pending_locked=false`, takes no new lock (surface.zig:267-280).
- wlroots: buffer NOT held across commits. `surface_handle_attach` only stores the pending resource (wlr_compositor.c:68-90); lock taken at commit in `surface_state_move` (`state->buffer = wlr_buffer_lock(next->buffer)`, wlr_compositor.c:352-357), and `surface_commit_state` UNLOCKS `current.buffer` and NULLs it at the END of every commit (wlr_compositor.c:570-574). `wl_buffer.release` is sent by the shm/dmabuf client-buffer drop path, not the surface.
- smithay: `merge_into` releases the replaced `BufferAssignment::NewBuffer` via `buffer.release()` (handlers.rs:125-137); releases buffers on destroy too (tree.rs:150-155). No lock counting at the surface layer.
- verdict: divergent. Ours holds a long-lived lock on the current buffer (M1: no texture cache, usage ends only at swap-out). wlroots/smithay release after commit/present so the client can reuse the buffer (double-buffering), which ours cannot.

### `Surface.pending_locked` re-attach special-case
- ours: when `pending.buffer == null` and `current.buffer == b`, `attachBuffer` skips the lock and clears `pending_locked` (surface.zig:267-280), else locks (`b.lock()`, :281-290). Commit guards `old != s.current.buffer` before releasing (surface.zig:321-331) so a same-buffer re-attach never strands it. Comment cites weston-simple-shm resize.
- wlroots: NO special case. Re-attach just re-sets `pending_buffer_resource` (wlr_compositor.c:68-90); the double lock never materializes because the prior `current.buffer` was already unlocked+NULLed at the previous commit (wlr_compositor.c:570-574).
- smithay: no special case; `Attach` overwrites `pending.buffer` with a new `BufferAssignment` (handlers.rs:175-211), old released at apply.
- verdict: divergent. Our special-case is a workaround for our own hold-the-lock model; wlroots avoids it by resetting `current.buffer` to NULL each commit. Ours is correct for M1 but is a genuine model difference.

### `Surface.commit` ordering
- ours (surface.zig:307-376): 1 validatePending; 2 swapState; 3 release old buffer + swap release callbacks; 4 role.client_commit; 5 send frame done(now_ms) AT COMMIT; 6 role.commit; 7 emit client_commit+commit; 8 map/unmap from buffer!=null.
- wlroots: `surface_handle_commit` (wlr_compositor.c:575-597): finalize_pending → role.client_commit → emit client_commit → cache-or-`surface_commit_state`. `surface_commit_state` (wlr_compositor.c:511-574): null-buffer unmap → `surface_state_move` → `surface_update_damage` → `surface_apply_damage` → update opaque/input regions → subsurface parent-commit hooks → synced commits → role.commit → emit commit → unlock current.buffer. Frame callbacks NOT completed at commit; deferred to `wlr_surface_send_frame_done` at present (wlr_compositor.c:1131-1139). Map NOT automatic: roles call `wlr_surface_map`/`unmap` (wlr_compositor.c:831-871); commit only auto-UNMAPS on a NULL buffer commit (:515-522).
- smithay: `Request::Commit` (handlers.rs:266-279): set client_scale → pre-commit hooks → `PrivateSurfaceData::commit` (tree.rs:281-361): apply/cache pending + sync-subsurface transaction merge → queue → `Transaction::apply` (transaction.rs:207-236): `apply_state` → post-commit hooks → `CompositorHandler::commit`. Frame callbacks stored (handlers.rs:228-238), sent later by compositor.
- verdict: divergent. (a) ours fires frame `done` at commit; wlroots/smithay defer to present time. (b) ours auto-maps/unmaps from `buffer != null`; wlroots auto-unmaps on null commit but roles initiate map; smithay leaves mapping to the compositor. wlroots also releases the buffer AFTER emitting commit (listeners can access it); ours releases before the hooks.

### `Surface.attachBuffer` / attach offset guard
- ours: `handleAttach` posts `invalid_offset` for non-zero x/y at v5+ (surface.zig:397-407); wraps via `fromResource`+lock, else keeps previous pending (surface.zig:408-428).
- wlroots: `surface_handle_attach` posts `WL_SURFACE_ERROR_INVALID_OFFSET` at v5+; below v5 stores dx/dy as offset state (wlr_compositor.c:68-90).
- smithay: `Request::Attach` posts `InvalidOffset` at version >=5 (handlers.rs:175-211).
- verdict: same.

### `Surface.handleDamage` (wl_surface.damage)
- ours: accumulate rect into `pending.surface_damage` (surface.zig:429-438).
- wlroots: `surface_handle_damage` union-rects into `pending.surface_damage`, ignores negative width/height (wlr_compositor.c:91-106); clipped to surface bounds at finalize (wlr_compositor.c:233-240).
- smithay: pushes `Damage::Surface` scaled by client_scale (handlers.rs:212-226).
- verdict: close. Ours does not clip to bounds nor reject negative w/h; smithay applies client_scale ours lacks.

### `Surface.handleDamageBuffer` (wl_surface.damage_buffer)
- ours: M1 — accumulated into `surface_damage` (surface.zig:439-452); `buffer_damage` stays empty.
- wlroots: `surface_handle_damage_buffer` union-rects into a SEPARATE `pending.buffer_damage` (wlr_compositor.c:626-638); `surface_update_damage` transforms+scales surface damage into buffer coords, unions both into `surface->buffer_damage` (wlr_compositor.c:248-296); `wlr_surface_get_effective_damage` converts back.
- smithay: `Request::DamageBuffer` pushes `Damage::Buffer` (handlers.rs:304-322); `Damage` enum models both coordinate spaces (mod.rs:142-156).
- verdict: divergent. Ours conflates buffer and surface coordinates; wlroots/smithay keep them distinct and translate at render. Ours is correct only at scale=1/transform=normal; fix deferred to M2.

### `Surface.handleSetOpaqueRegion` / `handleSetInputRegion`
- ours: snapshots region as BOUNDING RECT; null input = infinite (surface.zig:455-476).
- wlroots: full pixman regions; null opaque=cleared, null input=infinite; clips to surface bounds on commit (`surface_update_opaque_region`/`input_region`, wlr_compositor.c:455-486); derives opaque from buffer format (`surface->opaque`, wlr_compositor.c:407-441).
- smithay: `Option<RegionAttributes>` full region (handlers.rs:240-264; mod.rs:236-239).
- verdict: divergent. Ours is lossy (bounding rect); wlroots/smithay keep the exact region and clip.

### `Surface.handleSetBufferTransform` / `handleSetBufferScale` (error codes)
- ours: transform 0..7 at request, posts `invalid_transform` (surface.zig:477-486); scale>0, posts `invalid_scale` (surface.zig:488-495); commit `validatePending` posts `invalid_size` if not divisible (surface.zig:379-395).
- wlroots: `INVALID_TRANSFORM` (wlr_compositor.c:601-612); `INVALID_SCALE` (wlr_compositor.c:614-623); `INVALID_SIZE` in `surface_finalize_pending` (wlr_compositor.c:205-226) with a cursor-role carve-out.
- smithay: scale<1 posts `InvalidScale` (handlers.rs:291-301); transform via `WEnum::Value` (invalid silently ignored, handlers.rs:280-289); NO commit-time divisibility check.
- verdict: close to wlroots, ahead of smithay. Matches wlroots error codes. Minor: ours also rejects non-positive buffer sizes (`invalid_size`, defensive); no cursor carve-out.

### `Surface.handleFrame` / frame callback timing
- ours: creates wl_callback, appends to `pending.frame_callbacks` (surface.zig:497-512); completed (destroySendDone) at commit step 5 (surface.zig:349-356).
- wlroots: stores in pending list (wlr_compositor.c:108-125); completed by `wlr_surface_send_frame_done` at present, NOT commit (wlr_compositor.c:1131-1139).
- smithay: stores `WlCallback` in `SurfaceAttributes.frame_callbacks` (handlers.rs:228-238); compositor sends `Done` later.
- verdict: divergent. Ours signals `done` at commit; wlroots/smithay signal after present. Ours violates protocol pacing intent and the no-signal-when-offscreen guidance (mod.rs:241-250).

### `Surface.handleGetRelease` / release callbacks
- ours: implements wl_surface.get_release (v7): posts `no_buffer` error with no pending buffer (surface.zig:514-523); callbacks fire `done(0)` at the swap-out commit or at destroy (M1 — no texture cache, surface.zig:24-29, 220-260).
- wlroots 0.20.2: NO `get_release` — `surface_implementation` has no `.get_release` (wlr_compositor.c:675-691); release is `wl_buffer.release` from the client-buffer drop path.
- smithay v0.7: no `get_release`; release is `wl_buffer.release()` (handlers.rs:136, tree.rs:150-155).
- verdict: ours-only vs both references. Ours ships a newer protocol feature (wayland v7) neither reference has, with M1 timing (fire at swap, not actual GPU release).

### `Surface.handleOffset`
- ours: stores dx/dy in pending (surface.zig:508-511).
- wlroots: sets `WLR_SURFACE_STATE_OFFSET`, dx/dy, resets dx/dy to 0 after move (wlr_compositor.c:640-650, 341-348).
- smithay: `Request::Offset` sets `buffer_delta` (handlers.rs:344-359).
- verdict: close. Ours doesn't clear offsets after apply (each attach overwrites); smithay applies client_scale scaling ours lacks.

### `swapState`
- ours: scalar copy + transfer of damage lists and frame callbacks, unconditional swap (surface.zig:516-550).
- wlroots: `surface_state_move` copies per-committed-bit (wlr_compositor.c:321-400); unchanged damage/opaque/input fall back to clearing/carry-over; handles buffer lock/unlock.
- smithay: `CachedState::commit`/`apply_state` via `Cacheable` (cache.rs:102-130, handlers.rs:111-148).
- verdict: divergent. Ours does a full unconditional swap (all fields committed every time). wlroots only carries `committed`-marked fields and clears the rest. For damage this is the intended transfer (M2 ring), so functionally acceptable, but the committed-mask gating semantics differ.

### `Surface.create` / `destroy`
- ours: `create` wires the wire handler (surface.zig:175-218); `destroy` runs unmap→role.destroy→destroy signal→release buffers→destroy unfinished frame/release callbacks→compositor.removeSurface (surface.zig:220-264). No role-object destroy guard.
- wlroots: `surface_create` / `surface_handle_resource_destroy` (wlr_compositor.c:724-790). `surface_handle_destroy` REJECTS `wl_surface.destroy` while a role object exists, posting `WL_SURFACE_ERROR_DEFUNCT_ROLE_OBJECT` (wlr_compositor.c:56-66).
- smithay: `SurfaceUserData::destroyed` → destruction hooks → `CompositorHandler::destroyed` → cleanup + release buffers (handlers.rs:361-377, tree.rs:150-155).
- verdict: divergent. Ours misses the defunct-role-object guard (protocol-visible error path) and has no destruction hooks / `CompositorHandler` analog.

### Map/unmap signals
- ours: auto-mapped from `current.buffer != null` at commit step 8, emits map/unmap + role.map/unmap (surface.zig:360-375); also unmaps on destroy (surface.zig:222-227).
- wlroots: `wlr_surface_map`/`unmap` explicit, idempotent, emit after role hook; roles call them (wlr_compositor.c:831-871). Null-buffer commit auto-unmaps (wlr_compositor.c:515-522).
- smithay: no map/unmap signals in the compositor module; mapping left to the compositor.
- verdict: divergent (vs wlroots). Ours infers map from buffer presence; wlroots leaves map initiation to the role. Ours maps a zero-size buffer; wlroots requires width/height>0 (`wlr_surface_state_has_buffer`, wlr_compositor.h:356).

### Damage-ring integration
- ours: surface module has no ring; accumulates rects in `State.surface_damage`/`buffer_damage` (a `Damage` rect list, damage.zig:13-56). `DamageRing` lives in scene (`SceneOutput.damage_ring`, scene.zig:258, num_buffers=2 :276), driven whole-frame from server (`addWhole` + `rotate`, server/main.zig:572-589).
- wlroots: `wlr_surface` keeps `buffer_damage` region (wlr_compositor.h:156) built by `surface_update_damage`; scene nodes call `wlr_damage_ring_rotate_buffer` with per-buffer history (wlr_damage_ring.c:159-206, `entry_squash_damage`, `WLR_DAMAGE_RING_MAX_RECTS`).
- smithay: no ring; `SurfaceAttributes.damage: Vec<Damage>` consumed by compositor (mod.rs:244-247).
- verdict: divergent. Ours approximates wlr_damage_ring in scene but feeds it wholesale (addWhole) rather than per-buffer age tracking from surface damage; wlroots keys the ring off the actual buffer. smithay is compositor-driven like ours.

## Gaps
1. **Buffer release timing** — wlroots unlocks `current.buffer` at end of every commit (wlr_compositor.c:570-574); smithay releases replaced buffer at apply (handlers.rs:135-137). Ours holds the lock until swap-out/destroy (surface.zig:265-340) — no double-buffering.
2. **Frame `done` at present, not commit** — wlroots `wlr_surface_send_frame_done` (wlr_compositor.c:1131-1139), smithay deferred send (mod.rs:241-250, handlers.rs:228-238); ours signals in `commit` (surface.zig:349-356).
3. **damage_buffer coordinate separation** — wlroots separate `buffer_damage` + transform (wlr_compositor.c:248-296, 626-638); smithay `Damage::Buffer` vs `Damage::Surface` (mod.rs:142-156). Ours folds damage_buffer into surface damage (surface.zig:439-452) — wrong at scale!=1 / non-normal transform.
4. **Region fidelity** — wlroots clips opaque/input to bounds + buffer-format opaque (wlr_compositor.c:455-486, 407-441); smithay full `RegionAttributes` (handlers.rs:240-264). Ours snapshots a bounding rect (surface.zig:455-476).
5. **Cached-state / transactions** — wlroots `wlr_surface_lock_pending`/`unlock_cached` + cached states + synced objects (wlr_compositor.h:462-470; wlr_compositor.c:599-650); smithay `CachedState`/`MultiCache` + `TransactionQueue` (cache.rs:102-130; transaction.rs:1-352). Ours applies directly at commit.
6. **Defunct role-object destroy guard** — wlroots posts `DEFUNCT_ROLE_OBJECT` (wlr_compositor.c:56-66); ours lacks it (surface.zig:220).
7. **Preferred buffer scale/transform hinting** — wlroots `wlr_surface_set_preferred_buffer_scale`/`_transform` (wlr_compositor.c:~1243-1290; wlr_compositor.h:478-488). Ours sends neither.
8. **Auto-map keys off buffer presence, not size** — wlroots maps only when buffer_width/height>0 (wlr_compositor.h:356); ours maps on `buffer != null` (surface.zig:360).
9. **Surface hit-test / traversal helpers** — wlroots `wlr_surface_point_accepts_input`/`surface_at`/`for_each_surface`/`get_extents` (wlr_compositor.c:998-1140) and output enter/leave (`wlr_surface_send_enter/leave`, wlr_compositor.c:1071-1128) absent from our module; delegated to scene/output agents. VERIFIED 2026-08-09: the functionality exists as the seat's scene pick (`pickSurface`, main.zig:1070, wired via `seat.setPick` main.zig:365) instead of surface-local helpers; wlroots' helpers confirmed present (include/wlr/types/wlr_compositor.h:376,385,433) — the gap is API shape, not behavior.

## Verdict
Medium parity. Request-handler error codes (invalid_offset/invalid_transform/invalid_scale/invalid_size) match wlroots closely; smithay is actually behind on commit-time scale validation. Three riskiest divergences: (1) frame `done` fires at commit instead of present (breaks client throttling; wlroots wlr_compositor.c:1131, smithay handlers.rs:228); (2) hold-the-lock buffer model with its `pending_locked` re-attach special-case vs wlroots/smithay releasing every commit (wlr_compositor.c:570-574, handlers.rs:125-137) — a real performance/correctness gap for M1; (3) damage_buffer folded into surface damage with no coordinate translation (surface.zig:439-452 vs wlr_compositor.c:248-296). Secondary: auto-map off `buffer != null`, lossy bounding-rect regions, no cached-state/transaction mechanism, missing defunct-role-object guard. wlroots 0.20.2 and smithay v0.7 both lack wl_surface.get_release, which ours implements (ours-only, M1 timing).
