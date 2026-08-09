# Buffers / Shm — wlroots/smithay diff

Scope: `src/buffers/buffer.zig`, `src/buffers/shm.zig` vs
wlroots 0.20.2 `types/buffer/buffer.c`, `types/buffer/resource.c`, `types/wlr_shm.c`,
`include/wlr/types/wlr_buffer.h`, `include/wlr/interfaces/wlr_buffer.h`;
smithay 0.7.0 `src/wayland/buffer/mod.rs`, `src/wayland/shm/{mod.rs,pool.rs,handlers.rs}`.

Note: the batch spec referenced a smithay `buffer.rs` containing `BufferAccess` and
`WeakBuffer`. Those types do not exist in smithay 0.7.0 (confirmed `Cargo.toml:3`
`version = "0.7.0"`). In 0.7.0 `src/wayland/buffer/mod.rs` holds only the
`BufferHandler` trait; SHM buffer access lives in `wayland/shm`. `BufferAccess`/
`WeakBuffer` are an older smithay (<0.6) layout. Rows below map to the 0.7.0
counterparts (`with_buffer_contents`, `ShmBufferUserData`, `Pool::with_data`).

## Surface

`src/buffers/buffer.zig`:
- `pub const DataAccessError` (buffer.zig:25)
- `pub const Impl` vtable: `get_dmabuf`, `get_shm`, `begin_data_ptr_access`,
  `end_data_ptr_access`, `destroy` (buffer.zig:29)
- `pub const Buffer` (buffer.zig:44)
- `Buffer.init` (buffer.zig:65)
- `Buffer.drop` (buffer.zig:96)
- `Buffer.lock` (buffer.zig:102)
- `Buffer.unlock` (buffer.zig:108)
- `Buffer.destroy` (buffer.zig:123)
- private `maybeRelease` (buffer.zig:113)

`src/buffers/shm.zig`:
- `pub const ShmState` (shm.zig:56)
- `ShmState.init` (shm.zig:66)
- `ShmState.deinit` (shm.zig:88)
- `ShmState.fromResource` (shm.zig:104)
- `pub fn fromResource` (untracked) (shm.zig:120)
- private `shm_impl` (shm.zig:144), `shmGetShm` (156), `shmBeginDataPtrAccess`
  (160), `shmEndDataPtrAccess` (173), `shmDestroy` (178), `resourceDestroy` (195),
  `releaseNotify` (206), `shmFromResource` (212)

## Comparison

### buffer.zig

**`Impl` vtable** — our impl fn-pointer struct with optional get_dmabuf/get_shm/
begin/end data access and mandatory destroy.
- wlroots: `struct wlr_buffer_impl` `include/wlr/interfaces/wlr_buffer.h:24-32`
  (destroy, get_dmabuf, get_shm, begin_data_ptr_access, end_data_ptr_access).
- smithay: N/A (no central vtable; per-module `ShmBufferUserData` holds pool+data,
  `shm/mod.rs:327-346`).
- verdict: close. Same five slots. `Impl.destroy` takes `(allocator, data)` and does
  NOT free the Buffer; wlroots `destroy` frees the whole buffer. See destroy row.

**`Buffer.init`** — allocate + zero-init, assert paired begin/end, init signals.
- wlroots: `wlr_buffer_init` `types/buffer/buffer.c:9-20` (asserts impl->destroy,
  paired begin/end, `wl_signal_init` x2, `wlr_addon_set_init`).
- smithay: N/A.
- verdict: close. Ours additionally allocates the Buffer and stores an allocator.

**`Buffer.lock`** — increment consumer refcount.
- wlroots: `wlr_buffer_lock` `types/buffer/buffer.c:47-49` (`n_locks++`, returns buffer).
- smithay: N/A (no lock refcount; compositor borrows `WlBuffer` directly).
- verdict: close. Ours returns `!void` (never errors) and returns `void`.

**`Buffer.unlock`** — decrement; assert >0; fire release when released.
- wlroots: `wlr_buffer_unlock` `types/buffer/buffer.c:50-61` — decrement; when
  `n_locks == 0` emit release **regardless of dropped**; then `buffer_consider_destroy`.
- smithay: N/A.
- verdict: divergent. wlroots emits `release` whenever the last lock drops, even if
  the buffer is not dropped; ours fires `release` only when `dropped && n_locks == 0`
  (`maybeRelease` buffer.zig:113-116). Also wlroots auto-destroys on unlock; ours does not.

**`Buffer.drop`** — mark producer done; release when unlocked.
- wlroots: `wlr_buffer_drop` `types/buffer/buffer.c:40-45` — asserts `!dropped`
  (single-shot), sets dropped, `buffer_consider_destroy`.
- smithay: N/A.
- verdict: divergent. Ours is cycle-idempotent (may drop repeatedly, shm.zig:198
  guards with `if (!d.buf.dropped)`); wlroots asserts single drop. Ours does not
  auto-destroy on drop.

**`maybeRelease`** — fire release iff `dropped && n_locks == 0`.
- wlroots: `buffer_consider_destroy` `types/buffer/buffer.c:31-38` (dropped && n_locks==0
  -> assert !accessing_data_ptr -> impl->destroy, auto-free).
- smithay: N/A.
- verdict: divergent. Same guard condition, but wlroots destroys the object there;
  ours only emits a signal and keeps the wrapper alive until the owner calls destroy.

**`Buffer.destroy`** — emit destroy signal, call impl.destroy, free.
- wlroots: `wlr_buffer_finish` `types/buffer/buffer.c:22-29` (emit destroy, finish
  addons, assert empty listener lists) + `buffer_destroy` in the shm impl
  `types/wlr_shm.c:89-103` (removes release listener, finish, remove from pool,
  free). wlroots destroy is the auto path via `buffer_consider_destroy`.
- smithay: N/A (drop of `WlBuffer` handled by wayland_server).
- verdict: divergent. wlroots couples destroy to the dropped&&unlocked condition
  (automatic); ours is explicit and owner-driven. Our `destroy` emits the signal then
  frees; wlroots `finish` emits then asserts the destroy listener list is empty.

**`DataAccessError`** — `error{Unsupported}`.
- wlroots: no equivalent error; begin_data_ptr_access returns `bool`
  (`include/wlr/types/wlr_buffer.h` begin decl; `types/buffer/buffer.c:72-80`).
- smithay: `BufferAccessError` enum `wayland/shm/mod.rs:191-206` (NotManaged, BadMap,
  NotReadable, NotWritable).
- verdict: close (ours-only as a Zig error set). Ours is narrower: one `Unsupported`
  vs smithay's four-way discrimination.

**`begin_data_ptr_access` (impl slot)** — no flags, returns `?[*]u8` only.
- wlroots: `types/buffer/buffer.c:72-80` — takes `flags` (READ/WRITE), out-params
  `data, format, stride`, tracks `accessing_data_ptr`, returns bool.
- smithay: `with_buffer_contents`/`with_buffer_contents_mut` `wayland/shm/mod.rs:242,280`
  — closure-scoped RAII, passes `ptr, len, BufferData`; read/write split.
- verdict: divergent. Ours drops format/stride out-params and READ/WRITE flags
  (scope cut: shm impl gets width/height via getWidth/getHeight and stride is not
  exposed). Ours is an imperative begin/end pair (matches wlroots), not closure-scoped
  like smithay.

### shm.zig

**`ShmState`** — display-scoped state holding the resource->Buffer dedup map.
- wlroots: `struct wlr_shm` `types/wlr_shm.c:119-` + `wlr_shm_create`
  `types/wlr_shm.c:352-408` (formats list, global, display destroy listener,
  `wlr_buffer_register_resource_interface`). wlroots keeps **no** resource->wrapper
  map.
- smithay: `ShmState` `wayland/shm/mod.rs:50-98` (formats HashSet + GlobalId), no map.
- verdict: ours-only. The external `buffers` map is our dedup mechanism; wlroots and
  smithay store the buffer association inside the resource's user_data, so no map.

**`ShmState.init`** — call `display.initShm()` (registers libwayland's internal wl_shm
global) + allocate state.
- wlroots: `wlr_shm_create` `types/wlr_shm.c:352-408` creates its own `wl_shm` global
  with its own handlers (`shm_bind`, `wlr_shm.c:335-351`).
- smithay: `ShmState::new` `wayland/shm/mod.rs:64-91` creates its own `WlShm` global,
  `handlers.rs:33-52` sends formats on bind.
- verdict: divergent (structural). Ours delegates the entire wl_shm protocol
  (create_pool/create_buffer/resize/validation) to libwayland's internal global
  (`wire.shm`); wlroots and smithay implement the protocol themselves
  (`wlr_shm.c:158-333`, `handlers.rs:56-181`).

**`ShmState.deinit`** — destroy all tracked wrappers, free map + state.
- wlroots: no display-level sweep; per-buffer `buffer_destroy` + `handle_display_destroy`
  `types/wlr_shm.c:341-351` frees the global.
- smithay: global removal via `ShmState::global()`; no wrapper sweep (buffers freed by
  wayland_server on client disconnect).
- verdict: ours-only. Consequence of the owner-managed wrapper map; wlroots/smithay
  rely on reference counting / client disconnect to free buffers.

**`ShmState.fromResource`** — wrap a client wl_buffer resource into a tracked Buffer,
dedup by resource pointer.
- wlroots: `wlr_buffer_try_from_resource` `types/buffer/resource.c:42-60` — class check
  (`wl_buffer_interface.name`), dispatch to registered `wlr_buffer_resource_interface`,
  return the buffer, then `wlr_buffer_lock`. Dedup is implicit: the resource's user_data
  IS the `wlr_shm_buffer` (`buffer_base_from_resource` `types/wlr_shm.c:78-81`).
- smithay: no compositor-facing resource->buffer wrapper; access goes straight through
  `ShmBufferUserData` on the `WlBuffer` (`wayland/shm/mod.rs:327-346`).
- verdict: close in effect (both resolve a wl_buffer resource to a usable buffer),
  divergent in mechanism (external map vs in-resource user_data).

**`fn fromResource` (untracked)** — fresh wrapper, caller-owned, must `Buffer.destroy`.
- wlroots: no untracked variant; `wlr_buffer_try_from_resource` always returns the
  canonical buffer and the caller locks/unlocks.
- smithay: N/A.
- verdict: ours-only.

**`shmGetShm`** — return the underlying libwayland shm buffer.
- wlroots: `buffer_get_shm` `types/wlr_shm.c:105-119` fills `wlr_shm_attributes`
  (fd/format/width/height/stride/offset) and returns true.
- smithay: N/A (attributes in `BufferData`, `wayland/shm/mod.rs:327-346`).
- verdict: divergent. wlroots exposes a full attributes struct (incl. stride + offset);
  ours returns only the shm handle.

**`shmBeginDataPtrAccess` / `shmEndDataPtrAccess`** — SIGBUS guard via libwayland
`beginAccess`/`endAccess`, return mapped data pointer.
- wlroots: `buffer_begin_data_ptr_access` `types/wlr_shm.c:172-214` installs its OWN
  SIGBUS handler (`handle_sigbus` `types/wlr_shm.c:128-170` — replaces the faulting page
  with a zeroed MAP_PRIVATE|MAP_ANONYMOUS map or reraises), pushes onto a lock-free
  atomic sigbus_data list; `buffer_end_data_ptr_access` `types/wlr_shm.c:216-243`
  restores the previous action. Returns `mapping->data + offset` + format + stride.
- smithay: `Pool::with_data` `wayland/shm/pool.rs:151-190` installs its own handler
  (`place_sigbus_handler` `pool.rs:344-`), records a thread-local SIGBUS_GUARD; on
  SIGBUS the mapping is nullified and the call returns `Err(())`, which
  `with_buffer_contents` turns into `post_error(InvalidFd)` + `BufferAccessError::BadMap`
  (`wayland/shm/mod.rs:250-257`).
- verdict: divergent (mechanism). Ours delegates the SIGBUS guard to libwayland's
  `wl_shm_buffer_begin_access`; wlroots and smithay implement their own handlers.
  Semantically equivalent protection (client-shrunk file cannot crash us). Ours returns
  only a pointer, not format/stride, and does not post_error on fault (libwayland's
  guard just zero-fills).

**`shmDestroy`** — remove wrapper from map, detach listeners, free impl data.
- wlroots: `buffer_destroy` `types/wlr_shm.c:89-103` (asserts `resource == NULL`,
  removes from pool list, `pool_consider_destroy`, free).
- smithay: N/A (no wrapper object).
- verdict: close in intent, ours-only shape.

**`resourceDestroy`** — on client resource destroy: remove map entry, null out
resource/shm, drop buffer. **Our pointer-reuse fix.**
- wlroots: `buffer_handle_resource_destroy` `types/wlr_shm.c:302-306` — `resource = NULL`,
  `wlr_buffer_drop(&buffer->base)`. wlroots has **no** pointer-reuse hazard because there
  is no cached pointer indexed by the resource: the association lives in the resource's
  own `wl_resource_get_user_data`, which libwayland sets afresh for every new resource
  (`buffer_from_resource` `types/wlr_shm.c:73-76`, set at create in `wlr_shm.c:234-244`).
  A recycled resource pointer gets a fresh `wlr_shm_buffer`, so `try_from_resource` can
  never return a stale wrapper.
- smithay: `Dispatch2::destroyed` for `ShmBufferUserData` `handlers.rs:194-201` — fires
  destruction hooks then `data.buffer_destroyed(buffer)` (compositor `BufferHandler`
  callback, `buffer/mod.rs:14-27`). No map, so no reuse hazard either.
- verdict: ours-only (the hazard is an artifact of our external-map design). The fix
  (remove the map entry so a recycled resource pointer gets a fresh wrapper) is
  correct and necessary given our design; wlroots/smithay avoid the hazard by never
  caching a resource->buffer association outside the resource.

**`releaseNotify`** — on our Buffer release signal, send `wl_buffer.release` to client
while the resource is alive.
- wlroots: `buffer_handle_release` `types/wlr_shm.c:295-299` — if `resource != NULL`,
  `wl_buffer_send_release`. Same guard.
- smithay: N/A — smithay does not send release for shm buffers (compositor drives
  buffer lifecycle via `BufferHandler`); release semantics differ (weston-smithay).
- verdict: close (wlroots identical guard). Timing differs because our `release` signal
  fires on drop+unlock, wlroots' on unlock only (see `Buffer.unlock` row).

**`shmFromResource`** — `wire.shm.Buffer.get(resource) orelse InvalidBuffer`; build
ShmBufferData; `Buffer.init`; attach resource_destroy + release listeners.
- wlroots: creation happens once in `pool_handle_create_buffer` `types/wlr_shm.c:215-250`
  (alloc `wlr_shm_buffer`, `wlr_buffer_init`, set as resource user_data, add release
  listener to `base.events.release`). Resolution via `buffer_base_from_resource`
  `types/wlr_shm.c:78-81`.
- smithay: creation in `Dispatch2<WlShmPool>` `handlers.rs:79-166` (`ShmBufferUserData`
  init); resolution via `buffer.data::<ShmBufferUserData>()` `wayland/shm/mod.rs:247-248`.
- verdict: divergent (mechanism). We wrap lazily at attach time by matching the resource
  against libwayland's internal shm impl (`wire.shm.Buffer.get`); wlroots/smithay create
  the buffer object at `create_buffer` request time and own the protocol.

## Gaps

1. Auto-destroy on `dropped && n_locks == 0`: wlroots frees the buffer object there
   (`buffer_consider_destroy` `types/buffer/buffer.c:31-38`); we keep the wrapper until
   `ShmState.deinit` or resource destruction. Wrappers not dropped before deinit are
   reclaimed only at teardown (memory held longer). Evidence: `buffer.c:31-38`, our
   `shm.zig:88-98` + `buffer.zig:113-116`.
2. Release timing: wlroots emits `release` on every unlock reaching `n_locks == 0`
   regardless of `dropped` (`buffer.c:56-57`); we require `dropped` too
   (`buffer.zig:113-116`). A consumer that unlocks an undropped buffer would not notify
   the client in our model. RESOLVED 2026-08-09: premise stale post-fix — `maybeRelease`
   (buffer.zig:119-123) now emits on `n_locks == 0` regardless of `dropped` (guarded by
   the new exactly-once `released` flag), and the surface's commit step 8 unlocks the
   current buffer without a prior drop, so the client IS notified at every commit end;
   downstream impact nil (verified against surface.zig commit + buffer.zig).
3. Full protocol ownership: wlroots and smithay implement wl_shm create_pool/
   create_buffer/resize with their own validation (offset/stride/format overflow,
   pool-shrink forbid, format table). See `wlr_shm.c:158-333`, `handlers.rs:79-166`,
   `shm/mod.rs:191-206`. Ours delegates to libwayland's internal `wl_shm` global
   (`shm.zig:18-45`), so we inherit libwayland's validation and cannot intercept
   `create_pool`/`create_buffer`.
4. Data-access interface: wlroots exposes READ/WRITE flags and out-params format+stride
   (`buffer.c:72-80`, `wlr_buffer.h`); smithay splits read vs mutable access and passes
   `BufferData` (stride, offset, format) to the callback (`wayland/shm/mod.rs:242,280`).
   Ours returns only a raw pointer with no format/stride/access-mode
   (`buffer.zig:35-38`, `shm.zig:160-171`). Stride is not exposed, so any consumer
   needing the real stride (e.g. format-aware upload) cannot get it from this API.
5. Resource-interface registry: wlroots resolves any registered buffer backend from a
   resource via `wlr_buffer_register_resource_interface` (`resource.c:11-28`,
   `resource.c:42-60`); smithay dispatches by per-module user-data (`mod.rs:247-248`).
   Ours is hardcoded to shm (`wire.shm.Buffer.get`, `shm.zig:212-217`); a DMA-BUF
   resource cannot be wrapped by this path (see `get_dmabuf` slot unused in shm_impl,
   `shm.zig:145`).
6. SIGBUS fault reporting: smithay converts a SIGBUS fault into a protocol error + kills
   the client (`wayland/shm/mod.rs:250-257`); ours (via libwayland) silently zero-fills
   the faulting page and returns the data pointer, so a bad client is not errored.
   [RESOLVED 2026-08-09: `getData` returns `?*anyopaque` (generated bindings, nullable)
   and our impl null-checks it — `begin_data_ptr_access` returns `error.Unsupported`
   when null (shm.zig:174-177) — so the missing-mapping case IS surfaced; the
   zero-fill-vs-error divergence from smithay stands.]

## Verdict

The `Buffer` wrapper is near-parity on refcount shape, release/destroy signals, and the
impl vtable, but diverges on lifecycle: wlroots auto-destroys on `dropped && n_locks==0`
and fires `release` on unlock-only; ours is owner/deinit-driven with a drop+unlock
release condition and cycle-idempotent drop. The shm integration is structurally
different: we delegate the whole wl_shm protocol and the SIGBUS guard to libwayland's
internal global, whereas wlroots and smithay implement both themselves; validation and
fault reporting are therefore libwayland's, not ours. Riskiest divergences: (1) the
external resource->Buffer map introduces the pointer-reuse hazard that wlroots avoids
by design — our `resourceDestroy` removal fix is essential and correct, but the
mechanism is more error-prone; (2) auto-destroy absence means undropped wrappers live
until teardown; (3) the narrow data-access API (no stride/format/flags) limits
renderer consumers relative to both references.
