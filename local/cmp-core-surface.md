# cmp-core-surface.md — Core surface/compositor/buffer/subcompositor/region adversarial comparison

Area: wl_compositor, wl_surface, wl_region, wl_subcompositor/wl_subsurface, wl_shm pool, buffer lifecycle. References: wlroots 0.20.2 (types/wlr_compositor.c, types/wlr_subcompositor.c, types/buffer/buffer.c, types/wlr_region.c), smithay v0.7.0 (src/wayland/compositor/*.rs, src/wayland/shm/), KWin master (src/wayland/surface.cpp, compositor.cpp, region.cpp, subcompositor.cpp). Prior audit extended: notes/131-core-surface-f2f.md. Impl part only; no event-loop/backend plumbing.

## 1. Implemented surface (our files)
- src/compositor/compositor.zig — wl_compositor global, create_surface/create_region/release, v7, new_surface/destroy signals.
- src/compositor/surface.zig — wl_surface: pending/current double-buffer, committed mask, commit pipeline (validate→role.client_commit→client_commit signal→cache-or-apply), transactional applyCommit, map/unmap transition, frame callbacks (deferred to present), get_release (v7), damage (surface/buffer spaces + translate), enter/leave, offset/dx/dy, F42 buffer-resource death handling.
- src/compositor/region.zig — wl_region: add/subtract with compact-on-insert, saturating arithmetic.
- src/compositor/subsurface.zig — wl_subcompositor global + wl_subsurface: role enforcement, sync/desync cache deferral, set_position/place_above/below double-buffered on parent commit, parent/child death teardown.
- src/buffers/buffer.zig + src/buffers/shm.zig — refcounted Buffer, drop/lock/unlock, per-cycle release, ShmState wrapper (tracked/dead/graveyard), libwayland internal wl_shm for the pool.
- src/scene/surface_node.zig — surface→scene binding, enter/leave drive, presented-list, damage translation.

## 2. API breadth table
| Interface (version we advertise) | Requests/events we implement | wlroots 0.20.2 | smithay v0.7 | KWin master | Gaps vs refs |
|---|---|---|---|---|---|
| wl_compositor (v7) | create_surface, create_region, release | v6: all three | v7-proto, all three | v6: all three | none (we exceed version; v7 slot = wl_surface.get_release, implemented) |
| wl_surface (v7) | destroy, attach, damage, frame, set_opaque_region, set_input_region, commit, set_buffer_transform, set_buffer_scale, damage_buffer(v4), offset(v5), get_release(v7) = 12 | 11 (no get_release; caps at v6) | 11 (get_release → unreachable! panic, handlers.rs:339) | 11 (no get_release) | none; we are the only one with a live get_release |
| wl_surface events | enter(v2), leave(v2) | same | same | same | none |
| wl_region | add, subtract, destroy | same | same | same | none |
| wl_subcompositor (v1) | get_subsurface, destroy | same | same | same | none |
| wl_subsurface (v1) | destroy, set_position, place_above, place_below, set_sync, set_desync | all 6 | all 6 | all 6 | none (see C7 for z-order timing) |
| wl_shm (v2, libwayland-internal) | create_pool, create_buffer, resize, release; format events (ARGB8888/XRGB8888) | wlr_shm own impl, renderer formats | ShmState own impl | ShmClientBuffer | none — we delegate pool/resize/format validation to libwayland (identical semantics); format set is the base 2 (wlroots may add renderer formats) |
| wl_buffer | release event via our Buffer.release | wlr_buffer release | BufferAssignment release | releasePoint | none |

Breadth verdict: full request coverage; we exceed all three references on wl_compositor/wl_surface version (v7 get_release). No missing requests/events.

## 3. Adversarial correctness findings

C1. [MAJOR] wl_subsurface is destroyed on parent death instead of made inert.
- ours: subsurface.zig onParentDestroy → teardownOnSurfaceDeath → ss.resource.destroy() (subsurface.zig ~500-512, ~850).
- refs: wlroots subsurface_handle_parent_destroy wlr_subcompositor.c:283-292 → subsurface_destroy, which does `wl_resource_set_user_data(resource, NULL)` (:222) and keeps the resource alive — the file header even notes "wl_subsurface becomes inert on parent surface destroy"; smithay handlers.rs:555-620 keeps the WlSubsurface object (destructor only on client destroy; parent is a weak link, ops on a dead parent no-op); KWin subcompositor.cpp deletes the object only on child-surface destroy, not parent death.
- why it matters: the spec (wayland.xml:3288) only says the sub-surface is unmapped on parent destruction — the client keeps the object. If a client destroys its parent wl_surface and THEN its wl_subsurface (a legal order; the spec imposes none), our server has already destroyed the subsurface resource, so the client's wl_subsurface.destroy (or any request) resolves to a dead id → libwayland posts an invalid-object protocol error → the client is disconnected. All three references keep the object inert and tolerate this. Severity: MAJOR (spec conformance; kills a well-behaved client on a permitted sequence).

C2. [MAJOR] Subsurface mapped-state is not coupled to the parent's mapped state (recursive map/unmap missing).
- ours: surface.zig applyCommit step 10 sets s.mapped on buffer+size alone (surface.zig ~493-511); subsurface.zig never gates child mapping on parent.mapped.
- refs: wlroots subsurface_consider_map wlr_subcompositor.c:237-245 requires `subsurface->added && subsurface->parent->mapped && wlr_surface_has_buffer`; role commit re-checks it :247-256. KWin computeEffectiveMapped surface.cpp:786-812 propagates mapped/unmapped to subsurfaces recursively. Smithay ties child sync application to parent state (transaction.rs:19-25).
- why it matters: spec wayland.xml:3254-3258 ("A sub-surface becomes mapped ... when ... the parent surface is mapped. A sub-surface is hidden if the parent becomes hidden"). Ours sets surface.mapped=true and fires the map signal / wl_surface.enter / adds the child to the presented list even when its parent is unmapped or hidden. The visible rendering is coincidentally correct (scene hides the child behind a disabled placeholder tree, surface_node.zig ensureTree ~300), but state and signals diverge: presentation feedback (frame_done/present) is emitted for a hidden child, and enter/leave fire while hidden. Severity: MAJOR (spec violation in map/enter/present signaling), rendering masked.

C3. [MINOR] Rejected commit skips role.client_commit and the client_commit signal.
- ours: surface.zig commit step 1 validatePending returns early, so steps 2-3 (role.client_commit, client_commit signal) never run (surface.zig ~402-413).
- refs: wlroots surface_handle_commit wlr_compositor.c:577-598 runs surface_finalize_pending, then role->client_commit, then emits events.client_commit, and only AFTER that checks pending_rejected and returns.
- why it matters: on an invalid commit (non-divisible size, unknown buffer), wlroots still fires client_commit (the subcompositor sync handler runs and may lock the pending state); ours does not. On a sync subsurface whose commit is rejected, the cache-lock accounting diverges. Note wlroots' own ordering here is arguably a latent bug (lock set, cache never created); ours is cleaner, but it is a real divergence in the commit-pipeline contract. Severity: MINOR.

C4. [MINOR] Surface and buffer damage are not clipped to surface/buffer bounds before buffer-coordinate translation.
- ours: surface.zig translateDamage (~715-740) never clips; documented M1.
- refs: wlroots surface_finalize_pending wlr_compositor.c:243-258 intersects pending.surface_damage with the surface bounds and pending.buffer_damage with the buffer bounds.
- why it matters: a hostile client can submit unbounded/negative damage rects; saturating arithmetic (scaleCoord/addSat/subSat) prevents traps, and the scene's output clip (surface_node.zig addDamage) bounds over-reporting, so no crash — but unbounded damage lists are retained and propagated, wasting memory and violating the reference's bounded-damage contract. Severity: MINOR.

C5. [MINOR] Buffer reference model holds an unlocked ref on current.buffer across commits (vs wlroots NULLing it each commit).
- ours: surface.zig current.buffer persists until replaced/destroyed (F32, deferred STRUCTURAL); the M1 no-texture-cache model releases at the presenting commit.
- refs: wlroots surface_commit_state wlr_compositor.c:570-574 does `wlr_buffer_unlock(surface->current.buffer); surface->current.buffer = NULL;` every commit (the texture lives in surface->buffer).
- why it matters: clients see the SAME release timing (both release at the presenting commit; the weston re-attach / double-buffer case is verified correct in both — each attach→commit cycle emits one release, so weston's busy-leaf exit(1) is avoided). But internally, a consumer reading s.current.buffer after commit holds an ALREADY-RELEASED, unlocked reference; any unlock() asserts (n_locks>0). This is a latent footgun for future consumers that assume liveness from the lock count, unlike wlroots where a NULL current.buffer makes the contract explicit. Severity: MINOR (internal fragility; documented/deferred).

C6. [INFO] Subsurface z-order applied at frame-sync, not at the parent commit; only the latest restack retained.
- ours: subsurface.zig restack_sibling_id/restack_above recorded; main.zig applyRestack applies it server-side after the parent commit (M3).
- refs: wlroots applies place_above/place_below in the parent's pending.subsurfaces list and commits the order in surface_state_move (wlr_compositor.c surface_state_move subsurface-order section; wlr_subcompositor.c:76-152).
- why it matters: wlroots maintains a list so repeated restacks keep relative order; ours keeps a single latest restack target. Observable only as a sub-frame timing/ordering difference for multiple rapid restacks. Severity: INFO.

C7. [INFO] get_release (v7): we implement it; every reference either omits the slot (wlroots/KWin cap at v6) or panics on it (smithay handlers.rs:339 unreachable!). We exceed the references here — a positive breadth delta, no correctness concern.

C8. [INFO] set_buffer_transform validation: ours posts invalid_transform for out-of-range (surface.zig ~676-683, matches wlroots wlr_compositor.c:602-611 and KWin); smithay silently ignores unknown WEnum values (handlers.rs ~296-304). Ours is more spec-compliant than smithay.

C9. [INFO] Non-divisible-size hard error vs wlroots cursor exemption. ours validatePending posts invalid_size for any surface (surface.zig ~552-565); wlroots surface_finalize_pending wlr_compositor.c:214-226 only warns (does not reject) for wl_pointer-cursor / wp_tablet_tool-cursor roles. No cursor surface role exists in this area today, so no current impact; would diverge if cursor surfaces are added. Severity: INFO.

Verified-correct (not findings): commit-pipeline ordering for accepted commits (validate→role.client_commit→client_commit→apply matches wlroots; applyCommit is transactional per F31); scale/transform divisibility check (transformed-dim modulo is equivalent to wlroots' raw-dim modulo for all 8 transforms); offset dx/dy clearing on a no-offset commit (F34); the committed-mask swap (F33); frame-callback batching (accumulate until present, single done() pass); get_subsurface bad_parent (matches spec + wlroots); buffer-release per attach cycle (weston re-attach case correct).

## 4. Verdict
- Breadth: full request/event coverage across wl_compositor/wl_surface/wl_region/wl_subcompositor/wl_subsurface/wl_shm; we implement the v7 wl_surface.get_release that all three references lack. No gaps.
- Correctness: 2 MAJOR (C1 parent-destroy destroys the wl_subsurface resource instead of inerting it — can disconnect a legal-order client; C2 subsurface mapped/enter/present state not coupled to parent mapped — spec violation in signaling), 3 MINOR (C3 rejected-commit signal ordering, C4 unbounded damage, C5 unlocked current.buffer contract), 4 INFO (C6-C9). The two MAJORs are the adversarial deltas the prior audit missed; both are localized and fixable (C1: keep the resource, null its role and ignore requests; C2: gate child map/enter/present on the parent chain's mapped state).

Finding count: 9 (2 MAJOR, 3 MINOR, 4 INFO). Top 3: C1 (subsurface destroyed vs inert on parent death), C2 (subsurface mapped state not parent-coupled), C4/C3 (unbounded damage, rejected-commit signal ordering).
