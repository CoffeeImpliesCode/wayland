# Buffer lifecycle — graveyard, locks, release (vs wlroots/smithay)

Scope: `src/buffers/shm.zig` (322 lines; wrapper registry, graveyard, resource-destroy/release paths), `src/buffers/buffer.zig` (311 lines; Buffer abstraction), buffer handling in `src/compositor/surface.zig` (attachBuffer 290-330, commit 332-405, destroy buffer release 252-262, handleAttach 435-460, handleGetRelease 495-509, fireReleaseCallbacks\* 573-581, swapState 614-638). Supporting: `src/server/main.zig` (wiring/teardown 214-218, copy path 869-964, cursor read 1108-1114, per-frame flush 799), `src/compositor/compositor.zig` (deinit 89-96), `src/screencopy.zig` (copyFrame 233-277). References: wlroots 0.20.2 `types/buffer/buffer.c`, `types/wlr_shm.c`, `include/wlr/types/wlr_buffer.h`, `types/wlr_compositor.c`; smithay checkout v0.7.0-407-g5fb12b87 at `~/projects/github-Smithay-smithay` (`src/wayland/buffer/mod.rs` byte-identical to tag v0.7.0, verified via `git diff v0.7.0`; `src/wayland/shm/{mod.rs,handlers.rs,pool.rs}` differ slightly from the tag). NOTE: the task-named smithay paths `src/buffer/shm.rs` and `src/buffer/buffer.rs` DO NOT EXIST in v0.7.0; the `Buffer`/`BufferAccess` traits live in the external wayland-server 0.31 crate, not in the clone — not verified by reading.

## Surface

`src/buffers/shm.zig`:
- `ShmState` struct (shm.zig:59-67) — `buffers` AutoHashMap (dedupe per resource), `dead_buffers` ArrayList (graveyard, shm.zig:67).
- `ShmState.init` (shm.zig:71-91) — initShm + alloc; `ShmState.deinit` (shm.zig:95-107) — destroys dead_buffers first, then map walk until empty, frees state.
- `ShmState.fromResource` (shm.zig:113-124) — tracked wrap, deduped; untracked `fromResource` (shm.zig:129-135) — fresh wrapper per call, "caller must call Buffer.destroy".
- `ShmBufferData` (shm.zig:139-152); `shm_impl` (shm.zig:154-158); `shmGetShm` (shm.zig:165-167).
- `shmBeginDataPtrAccess` (shm.zig:169-180) — SIGBUS guard begin; endAccess on the getData-null path; `shmEndDataPtrAccess` (shm.zig:182-185) — null-guarded end.
- `shmDestroy` (shm.zig:187-198) — map remove, listener detach, free data.
- `resourceDestroy` (shm.zig:204-221) — map remove, graveyard append with OOM early return (shm.zig:212-216), null resource/shm (shm.zig:218-219), drop (shm.zig:220).
- `releaseNotify` (shm.zig:225-229) — null-guarded `sendRelease`.
- `shmFromResource` (shm.zig:231-268) — wrap + destroy/release listener registration.

`src/buffers/buffer.zig`:
- `Impl` (buffer.zig:29-44); `Buffer` struct (buffer.zig:50-64) — `dropped`, `n_locks`, `events.release/destroy`.
- `init` (buffer.zig:67-95); `drop` (buffer.zig:98-101) — idempotent, fires release on 0-transition; `lock` (buffer.zig:104-106); `unlock` (buffer.zig:113-117); `maybeRelease` (buffer.zig:119-123) — release on every n_locks==0; `destroy` (buffer.zig:128-132) — destroy signal while valid, then impl.destroy, then free.

`src/compositor/surface.zig` (buffer paths):
- `Surface.destroy` buffer release (surface.zig:252-262) — drop then guarded unlock, current and pending.
- `attachBuffer` (surface.zig:290-330) — lockless re-attach branch (surface.zig:296-297), pending replacement drop (surface.zig:311-315).
- `commit` (surface.zig:332-405) — step 3 old-buffer drop (surface.zig:354-358), step 8 unlock + get_release fire (surface.zig:401-404); frame-callback appendSlice OOM early return after swapState (surface.zig:345-347).
- `handleAttach` (surface.zig:435-460) — routes through `ShmState.fromResource` when `compositor.shm` set, else untracked `fromResource` (surface.zig:444-447).
- `handleGetRelease` (surface.zig:495-509); `fireReleaseCallbacksCurrent/Pending` (surface.zig:573-581); `swapState` (surface.zig:614-638); `handleDestroy` (surface.zig:754-757).

## Comparison

### Lifetime / ownership
- ours: ShmState owns tracked wrappers; `deinit` frees them unconditionally (shm.zig:95-107); graveyard bridges resource-destroy to deinit; surfaces hold raw pointers.
- wlroots: refcounted; freed only when `dropped && n_locks == 0` (`buffer_consider_destroy`, types/buffer/buffer.c:44-49); unlock is NULL-safe (buffer.c:62-65). Order-independent teardown.
- smithay: Rust ownership; `Buffer` is `Arc<InnerBuffer>` (backend/renderer/utils/wayland.rs:60-90); freed when the last Arc drops.
- verdict: divergent. Ours is an owner-with-mandatory-ordering contract; both references are refcounted. The ordering is violated in the server (Gap 2).

### drop() semantics
- ours: idempotent; fires release on every n_locks==0 transition (buffer.zig:98-101, 119-123); called per replace (surface.zig:354-358) and per surface destroy (surface.zig:252-262).
- wlroots: single-shot, `assert(!buffer->dropped)` (buffer.c:50-56).
- smithay: no drop API (Rust Drop).
- verdict: ours more lenient; enables duplicate release events (Gap 4).

### Release event trigger
- ours: `n_locks` reaches 0 on unlock or drop (buffer.zig:113-123).
- wlroots: n_locks reaches 0 on unlock (buffer.c:64-72); wl_shm sends via null-guarded listener (types/wlr_shm.c:299-304).
- smithay: `InnerBuffer::drop` calls `self.buffer.release()` (wayland.rs:65-71) — fires when the compositor's last Arc ref is gone (texture cache destroyed/replaced), i.e. after frame consumption.
- verdict: same principle (last consumer done). smithay ties release to frame/texture lifetime (later than commit); ours and wlroots tie it to the lock count (commit time).

### Client wl_buffer resource destroy
- ours: remove map entry (recycle-safe), append to graveyard, null resource/shm, drop (shm.zig:204-221).
- wlroots: `buffer->resource = NULL; wlr_buffer_drop(&buffer->base)` (types/wlr_shm.c:306-310).
- smithay: `destroyed()` runs destruction hooks + `BufferHandler::buffer_destroyed` (handlers.rs:233-240; src/wayland/buffer/mod.rs:15-27); the module frees nothing (Rust).
- verdict: same null-then-drop pattern; wlroots needs no graveyard because refcounts defer the free; the OOM early return bypasses the null (Gap 1).

### Release sender null guard
- ours: `releaseNotify` (shm.zig:225-229).
- wlroots: `buffer_handle_release` (types/wlr_shm.c:299-304).
- verdict: identical. The graveyard OOM path skips the nulling that makes this guard work.

### Commit unlock timing
- ours: commit signal (surface.zig:366-368) and map transition, then unlock current (surface.zig:401-404); texture copy happens inside a commit listener before that (main.zig:869-903).
- wlroots: upload in `surface_apply_damage` during commit processing (wlr_compositor.c:519, 555), then commit signal, then unlock + NULL current (wlr_compositor.c:564-572; comment: "released immediately on commit when they are uploaded to the GPU").
- smithay: no explicit unlock; references drop at state replacement.
- verdict: same ordering guarantee — the buffer content is copied/uploaded before the release fires. The DRM path renders from the server-owned framebuffer, never from the client buffer, so release-before-present is safe (Gap-free; see Verdict).

### Current-buffer retention between commits
- ours: locks at ATTACH (attachBuffer, surface.zig:299-304) and keeps `current.buffer` with n_locks==0 until replaced; requires the lockless re-attach special case (surface.zig:292-297) and the guarded unlock (surface.zig:402).
- wlroots: locks at COMMIT finalize (`wlr_buffer_try_from_resource`, wlr_compositor.c:194), unlocks and NULLs `surface->current.buffer` at commit end (wlr_compositor.c:571-572); the next commit's state_move unlocks NULL (no-op, wlr_compositor.c:342-343) — no special case needed, and an attached-but-never-committed buffer is never locked.
- smithay: keeps the Buffer in surface state (Arc refs).
- verdict: divergent bookkeeping; our lock accounting is verified correct across attach/commit/re-attach/replace/destroy traces, but release cadence differs (Gaps 4-5) and an uncommitted pending buffer is locked in ours but not in wlroots.

### SIGBUS-guarded data access
- ours: libwayland begin/endAccess pairing (shm.zig:169-185); all call sites defer the end (main.zig:955-964; screencopy.zig:262-276); no nesting guard.
- wlroots: own sigbus stack; asserts no nesting (`assert(!buffer->accessing_data_ptr)`, buffer.c:92; wlr_shm.c:220-283).
- smithay: thread-local guard, recursion panics (pool.rs:108-135); access is closure-scoped so pairing is structural (mod.rs:242-257).
- verdict: pairing in ours is sound on every path (Gap 9); wlroots/smithay enforce non-nesting, ours does not.

### wl_surface.get_release (v7)
- ours: implemented (surface.zig:495-509, 573-581), fires at commit-replace and destroy.
- wlroots: absent — `wl_surface_interface` has no get_release entry (wlr_compositor.c:649-661).
- smithay: no get_release handling found under src/wayland/ (grep, whole module tree).
- verdict: ours is ahead of both references on this protocol request.

### Teardown-order safety
- ours: order-dependent; violated (Gap 2).
- wlroots: order-independent via refcount (buffer.c:44-49) and NULL-safe unlock (buffer.c:62-65).
- smithay: Rust ownership, no ordering contract.
- verdict: ours is the outlier.

## Gaps

1. [BUG, Low] Graveyard OOM early return causes use-after-free. `resourceDestroy` (shm.zig:204-221): the append failure path (shm.zig:212-216, `return` at 215) exits before `d.resource = null` (218), `d.shm = null` (219) and `drop()` (220). Trace: the client destroys the wl_buffer; libwayland emits the resource destroy signal and frees the resource after emission returns (the harness is libwayland-server FFI; shm.zig:30-32 documents that the wrapper must not be freed mid-emission). Append OOMs → the wrapper is out of the map, NOT in the graveyard (deinit can never free it — leak, as the comment at 213-214 says), and `d.resource` still points at the freed resource. Any later surface unlock (surface.zig:401-404), replace, or surface destroy (surface.zig:252-262) fires the release signal → `releaseNotify` (shm.zig:228) sees a non-null `d.resource` → `sendRelease()` → `wl_resource_post_event` on freed memory → UAF. `d.shm` dangles likewise (a surfacePixels read would touch freed backing). In the sub-case where the wrapper has no locks and was never dropped, the skipped `drop()` means no release fires — leak only, no UAF. The comment documents only the leak, not the UAF. wlroots nulls the resource pointer before drop in the same handler (types/wlr_shm.c:306-310) and its release sender is null-guarded (types/wlr_shm.c:299-304). Fix: null resource/shm and drop BEFORE the append (or drop the early return; the append failure then degrades to the documented leak). Double-free question: NO — the map entry is removed before the append (shm.zig:211), deinit frees graveyard first then walks the map, and each `Buffer.destroy` removes its own map entry (shm.zig:189), so no wrapper is ever in both lists and none is freed twice. Verdict: BUG (OOM-only, so never hit under the DebugAllocator test regime, but a real defect with a complete trace).

2. [BUG, Medium] Teardown-order UAF: surfaces destroyed after their buffers are freed. `main.zig` registers `defer compositor.deinit()` (main.zig:215) before `defer shm_state.deinit()` (main.zig:217), so at exit shm_state.deinit runs FIRST and frees every wrapper (shm.zig:95-107) while surfaces still reference them; compositor.deinit then destroys the remaining surfaces (compositor.zig:89-96) and `Surface.destroy` drops/unlocks the freed buffers (surface.zig:252-262) — use-after-free (DebugAllocator poison → garbage signal iteration → crash). Second-order: `Surface.destroy` does not clear the wl_surface resource's user data, so the later client teardown (display.deinit: "Server.destroy tears down clients", display.zig:49) dereferences the freed Surface through handleDestroy (surface.zig:754-757). Only avoided when every client disconnected before loop exit; the E2E client exits before the server's 400 frames (scripts/vm-e2e.sh: WAYLAND_RUN_FRAMES=400; client sleeps ~700 ms then exits), so the VM tests dodge it; a client connected at run_frames/watchdog stop hits it. wlroots is immune: free only when `dropped && n_locks == 0` (buffer.c:44-49) and unlock is NULL-safe (buffer.c:62-65). Fix: destroy surfaces (compositor.deinit) before ShmState.deinit (reorder the defers, or an explicit teardown phase), or refcount the wrappers.

3. [LEAK, Low-Medium] Untracked `fromResource` wrappers are never freed. The ownership contract ("the caller must call Buffer.destroy", shm.zig:127-128) has no implementing caller: the surface only drop()/unlock()s buffers (surface.zig:252-262, 354-358) and never destroys them. Every untracked wrapper leaks (Buffer + ShmBufferData), and its resource-destroy listener stays attached to the resource; repeated attaches of one resource create duplicate wrappers with independent lock counts and duplicate release listeners. Reachable only when `s.compositor.shm == null` (surface.zig:444-447); the server always calls setShm (main.zig:218) and the library tests that create Compositors without setShm (seat.zig:704, xdg.zig:1093, presentation.zig:385) exercise no buffer attach [INFERENCE: verified by grep — no attach/commit in those tests]. Severity Low in the shipped server, real for library consumers. wlroots/smithay have no equivalent path (buffers are refcounted/owned).

4. [DIVERGENCE, Low] Duplicate wl_buffer.release for replaced buffers. The replace commit re-drops the old current buffer (surface.zig:354-358) after it was already released at its own commit's step 8 (surface.zig:401-404); `drop()` with n_locks==0 fires release again (buffer.zig:98-101, 119-123). Normal double-buffering (attach A, commit; attach B, commit) sends release for A twice; wlroots sends it exactly once per committed buffer cycle: it locks the buffer only at commit finalize (`wlr_buffer_try_from_resource` locks, wlr_compositor.c:194; state_move re-locks/unlocks, wlr_compositor.c:342-348) and unlocks+NULLs the current at commit end (wlr_compositor.c:571-572) — attach itself only swaps the pending resource pointer without touching refcounts (surface_handle_attach, wlr_compositor.c:78-90; set_pending_buffer_resource, wlr_compositor.c:38-45), so a replaced pending buffer never unlocks and never releases. The S6 variant (lockless attach A, attach B, commit) fires release for A three times (its commit step 8, the pending replacement drop at surface.zig:313-315, the commit step-3 drop) vs wlroots' one. Harmless to clients (release is idempotent; weston-simple-shm's handler just marks the buffer free), but a protocol-cadence divergence. Root cause: ours retains a zero-lock reference in current.buffer between commits and drops at replace.

5. [DIVERGENCE, Info] Lockless re-attach sends no release for the re-attach cycle. surface.zig:296-297 skips the lock, so commit step 8 (surface.zig:401-404) skips the unlock and no wl_buffer.release fires for that cycle; wlroots takes a fresh lock at commit finalize and fires release at each commit end (wlr_compositor.c:194, 571-572), so the client sees one release per commit cycle. Client-visible cadence difference, benign because the buffer was never re-locked in ours (the client may already reuse it). Lock accounting itself verified sound across attach/commit/re-attach/replace/destroy sequences — the only stranded-lock path is Gap 6.

6. [LOW] Commit OOM early return strands the new current buffer's lock. `appendSlice` failure after swapState (surface.zig:345-347) returns before step 8, so the new current buffer keeps its attach lock; release is deferred until the buffer is replaced or the surface destroyed. OOM-only; self-heals on the next successful commit. (The same return also leaves `s.buffer` pointing at the old current buffer, but no commit signal is emitted, so no inconsistency surfaces.)

7. [LOW] `updateCursor` reads the cursor surface's buffer every frame without a lock (main.zig:1108-1114): after its commit the buffer is released (n_locks==0, surface.zig:401-404) and the client may legally rewrite or shrink it; the read is SIGBUS-guarded (shm.zig:169-180) so a shrunk file cannot crash the compositor, but the copied pixels can be torn or mid-write [INFERENCE: the client may write after release — protocol-legal]. wlroots locks buffers around reads. Cosmetic only (torn cursor texture).

8. [INFO] get_release callback ordering: attachBuffer fires `fireReleaseCallbacksPending` (surface.zig:313) before the old buffer's drop/unlock (surface.zig:314-315), so the wl_surface.release callback (done(0)) is marshalled before the wl_buffer.release event in the same flush. No reference to compare (wlroots 0.20.2 does not implement get_release at all, wlr_compositor.c:649-661).

9. [INFO] Data-access pairing verified sound on every path: surfacePixels defers endAccess with no early-return gap (main.zig:958-963); the shm null-data path pairs begin/end inside the impl (shm.zig:174-177); screencopy defers endAccess before every return after begin (screencopy.zig:262-276); shmEndDataPtrAccess null-guards (shm.zig:182-185). Nesting is unguarded (a nested begin would push a second SIGBUS guard instead of failing) vs wlroots' assert (buffer.c:92) and smithay's panic (pool.rs:112-119).

10. [INFO] Buffer.destroy ordering is clean: destroy signal emitted while the Buffer is valid, then impl.destroy, then free (buffer.zig:128-132), matching wlr_buffer_finish (buffer.c:27-33). No production destroy-listener exists (grep: only tests), and resourceDestroy never frees from inside the signal — the graveyard defers to deinit control flow — so the documented "never destroy from inside a signal handler" rule holds. shmDestroy detaches both listeners before freeing its data (shm.zig:187-198).

Positive verification: the "both buffers busy" fix is sound — removing the map entry at resourceDestroy (shm.zig:211) plus the dedupe in fromResource (shm.zig:117-122) forces a fresh wrapper when libwayland recycles a freed resource pointer, so the release event for the recycled buffer is delivered instead of being dropped on a dead wrapper.

## Verdict

Release-event policy matches wlroots closely: fires on the last unlock (n_locks == 0), sent through a null-guarded listener (ours shm.zig:225-229 vs wlr_shm.c:299-304), and the commit unlocks the current buffer after the commit signal (surface.zig:401-404 vs wlr_compositor.c:564-572), with the pixel copy always completing before the unlock (main.zig:869-903). The DRM path presents the server-owned framebuffer, never the client buffer, so release-before-present is correct. The client-resource-destroy pattern (null-then-drop) also matches wlroots (wlr_shm.c:306-310). The material divergence is the lifetime model: ShmState-owned wrappers with mandatory ordering instead of wlroots' refcount — that produces the two proven UAF defects (Gaps 1-2). Release cadence divergences (Gaps 4-5) are benign. The untracked-path leak (Gap 3) is dead code in the shipped server. get_release (v7) support exceeds both references. Parity: high for release semantics and the copy-before-release guarantee; the ownership/teardown contract needs fixing (surface teardown before ShmState.deinit, or a refcount) and the graveyard OOM path needs the null-before-append reorder.
