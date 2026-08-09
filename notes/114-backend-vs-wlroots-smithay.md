# Backend — wlroots/smithay diff

Scope: `src/backend/backend.zig` (the `Backend` abstraction, wlr_backend pattern) and `src/backend/headless.zig` (first impl, test backend). wlroots 0.20.2: `backend/backend.c`, `backend/headless/backend.c`, `backend/headless/output.c`, `include/wlr/backend.h`, `include/wlr/backend/interface.h`. smithay 0.7.0: `src/backend/mod.rs` + per-module backends. smithay has NO unified Backend type (verified: no `pub struct|trait|enum Backend` anywhere under `src/`; `src/backend/mod.rs` is a feature-gated module container plus `SwapBuffersError`). Each smithay backend is a constructor that registers calloop sources itself (drm: `DrmDevice::new` returns a notifier, src/backend/drm/device/mod.rs:181; input: src/backend/libinput/mod.rs:39; hotplug: src/backend/udev.rs:92). Rows below mark smithay N/A for the unified abstraction.

## Surface

Public inventory (grep `pub fn`/`pub const`/`pub const` structs; file:line relative to repo roots):

`src/backend/backend.zig`:
- `Backend` struct (backend.zig:15) — impl/data/allocator/io/log_cfg + `events`.
  - `events.new_output` signal (backend.zig:23)
  - `events.destroy` signal (backend.zig:25)
- `Backend.Impl` struct (backend.zig:29) — `start` fn ptr (backend.zig:31), `destroy` fn ptr (backend.zig:33).
- `Backend.init` (backend.zig:36)
- `Backend.start` (backend.zig:59)
- `Backend.destroy` (backend.zig:63)
- `Backend.emitNewOutput` (backend.zig:71)

`src/backend/headless.zig`:
- `HeadlessBackend` struct (headless.zig:34)
- `HeadlessBackend.create` (headless.zig:38)

Private module fns (cited in rows, not inventory): `start` (headless.zig:68), `destroy` (headless.zig:83), `frameCb` (headless.zig:91), `testState` (headless.zig:99), `commit` (headless.zig:101), `destroyOutput` (headless.zig:127).

## Comparison

### `Backend.init`
- ours: allocates the struct, sets impl/data/allocator/io/log_cfg, inits `new_output`+`destroy` signals (backend.zig:36-57).
- wlroots: `wlr_backend_init` zero-fills the struct, sets impl, inits `destroy`/`new_input`/`new_output` signals (backend/backend.c:37-44). Caller allocates.
- smithay: N/A — no unified backend init.
- verdict: close. Ours allocates and requires allocator/io/log_cfg; wlroots initializes caller-owned memory and also inits `new_input`.

### `Backend.start`
- ours: mandatory `impl.start`, returns `error{BackendFailed}!void` (backend.zig:59-61).
- wlroots: `wlr_backend_start` tolerates NULL `impl->start` and returns `true`; failure is bool (backend/backend.c:55-59).
- smithay: N/A — backends start on construction and run through calloop sources (src/backend/drm/device/mod.rs:181, src/backend/udev.rs:92).
- verdict: close. Ours makes `start` non-optional and uses Zig errors instead of bool; no default-success path.

### `Backend.destroy`
- ours: emits `destroy` signal, calls `impl.destroy(allocator, data)`, frees the struct (backend.zig:63-67).
- wlroots: `wlr_backend_destroy` calls `impl->destroy` (backend/backend.c:62-72); impls call `wlr_backend_finish` which emits `destroy` and asserts all three signal listener lists are empty (backend/backend.c:47-53). Impl frees its struct.
- smithay: N/A — no unified destroy; each backend drops via Rust ownership.
- verdict: close. Signal ordering matches (destroy emitted before impl teardown); ours lacks the empty-listener asserts and the wrapper emits the signal instead of the impl.

### `Backend.emitNewOutput`
- ours: wraps `events.new_output.emit(out)` (backend.zig:71-73).
- wlroots: no wrapper fn; impls call `wl_signal_emit_mutable(&backend->events.new_output, ...)` directly, e.g. headless `backend_start` (backend/headless/backend.c:28-30) and `wlr_headless_add_output` (backend/headless/output.c:194-196).
- smithay: N/A — no signal; device hotplug surfaces through the udev monitor (src/backend/udev.rs:63-66) and compositor callbacks.
- verdict: same.

### `Backend.events.new_output`
- ours: `wire.Signal(*output.Output)` (backend.zig:23).
- wlroots: `struct wl_signal new_output` (include/wlr/backend.h:45).
- smithay: N/A.
- verdict: same.

### `Backend.events.destroy`
- ours: `wire.Signal(*Backend)` (backend.zig:25).
- wlroots: `struct wl_signal destroy` (include/wlr/backend.h:41).
- smithay: N/A.
- verdict: same.

### `Backend.events.new_input` — ours MISSING
- ours: absent from the events struct (backend.zig:22-27).
- wlroots: `struct wl_signal new_input`, passed `struct wlr_input_device` (include/wlr/backend.h:43); inited in `wlr_backend_init` (backend/backend.c:42).
- smithay: N/A — libinput devices flow through `InputHandler` + calloop (src/backend/libinput/mod.rs:39), not a backend-level signal.
- verdict: missing. The seam to announce input devices does not exist; a libinput backend would have nowhere to emit.

### `Backend.Impl.start` / `Impl.destroy`
- ours: both fields mandatory fn pointers (backend.zig:31,33).
- wlroots: `struct wlr_backend_impl` — `start`/`destroy` optional, plus optional `get_drm_fd`/`test`/`commit` (include/wlr/backend/interface.h:16-26).
- smithay: N/A — no impl table.
- verdict: close for start/destroy; ours has no slots for get_drm_fd/test/commit (see Gaps 6).

### `Backend` capability/feature fields — ours MISSING
- ours: none — Backend has no caps/features (backend.zig:15-27).
- wlroots: `buffer_caps` bitfield (include/wlr/backend.h:36) + `features.timeline` (include/wlr/backend.h:38-39); headless sets `WLR_BUFFER_CAP_DATA_PTR|DMABUF|SHM` and `features.timeline = true` at create (backend/headless/backend.c:69-71, 87-88).
- smithay: N/A — capabilities live on per-module types (e.g. allocator/renderer traits, src/backend/mod.rs:24-31).
- verdict: missing. Compositor cannot query DMABUF/SHM capability or timeline support.

### `HeadlessBackend.create`
- ours: asserts positive mode, allocates `Headless`, inits base Backend, eagerly creates ONE output with fixed mode, returns base (headless.zig:38-64).
- wlroots: `wlr_headless_backend_create` allocates backend, inits impl, sets buffer_caps+timeline, stores event loop, inits empty output list, adds an event-loop-destroy listener (backend/headless/backend.c:59-87). Outputs added later via `wlr_headless_add_output` (backend/headless/output.c:119-200), which assigns auto names "HEADLESS-%zu" and descriptions (output.c:158-163).
- smithay: N/A — no headless backend module exists (src/backend/mod.rs lists drm/egl/libinput/session/udev/vulkan/winit/x11/libei; no headless); closest test backends winit/x11 still present to a window.
- verdict: divergent. Hardwired single output vs N runtime-addable outputs; no event-loop-destroy hook; no buffer_caps; no name/description.

### headless `start` (impl)
- ours: asserts timer null, creates+arms frame timer with `mode.refresh_msec`, logs, emits `new_output` for the single output (headless.zig:68-81).
- wlroots: `backend_start` emits `new_output` for EVERY output in the list, sets `started = true` (backend/headless/backend.c:14-32). Frame timer is NOT armed at start — it is created at add_output and armed only by the first commit.
- smithay: N/A.
- verdict: close for the announce path; divergent on timer arming (ours paces immediately on start, wlroots waits for a commit).

### headless `destroy` (impl)
- ours: removes timer first (so no callback runs against torn-down state), destroys the output, frees `Headless` (headless.zig:83-88).
- wlroots: `backend_destroy` calls `wlr_backend_finish` (emits destroy, asserts empty listeners), destroys every output, removes the event-loop-destroy listener, frees (backend/headless/backend.c:29-45).
- smithay: N/A.
- verdict: close. Ours lacks the event-loop-destroy listener removal because it never registers one (see Gaps 4).

### headless `frameCb` (frame pacing)
- ours: sends frame, then unconditionally re-arms the timer via `timerUpdate(refresh_msec)`; returns 1 on success, 0 on re-arm failure (headless.zig:91-97).
- wlroots: `signal_frame` sends frame and returns 0 — a one-shot timer that is NEVER re-armed from the callback (backend/headless/output.c:113-117). Re-arm happens only in `output_commit`, gated on the output being enabled (output.c:61-64).
- smithay: N/A.
- verdict: divergent. Ours paces continuously once started; wlroots paces only while an enabled output is committed. Risk: ours frames even when no compositor commits arrive (busy loop at refresh rate).

### headless `commit` (impl)
- ours: logs committed bits/mode/damage; no state change, no timer touch, no present event (headless.zig:101-125).
- wlroots: `output_commit` runs `output_test`, updates `frame_delay` from the custom mode, defers a present event (`commit_seq + 1`, `presented = true`), and re-arms the frame timer when the output is enabled (backend/headless/output.c:56-64).
- smithay: N/A.
- verdict: divergent. Ours ignores mode changes (refresh fixed at create) and emits no present event, so presentation feedback has nothing to consume.

### headless `testState` (impl)
- ours: accepts everything, no-op (headless.zig:99).
- wlroots: `output_test` rejects unsupported committed bits against `SUPPORTED_OUTPUT_STATE` and accepts output layers (backend/headless/output.c:34-51).
- smithay: N/A.
- verdict: close in effect for headless-only states; ours has no capability filter.

### headless cursor — ours MISSING
- ours: headless output impl has no cursor slots (headless.zig:28-32).
- wlroots: `output_set_cursor`/`output_move_cursor` no-op returning true (backend/headless/output.c:82-89).
- smithay: N/A.
- verdict: missing. Benign for a headless output, but wlroots API parity is absent.

### headless `destroyOutput` (impl)
- ours: no-op — the output owns no extra resources (headless.zig:127).
- wlroots: `output_destroy` finishes the wlr_output, removes it from the backend list, removes the frame timer, frees (backend/headless/output.c:91-98).
- smithay: N/A.
- verdict: close (ours has nothing to tear down); wlroots also unregisters its per-output timer.

### `wlr_backend_is_headless` / is-impl predicate — ours MISSING
- ours: no runtime predicate; Zig comptime types select impls (headless.zig:23-26 uses a typed `Backend.Impl` table).
- wlroots: `wlr_backend_is_headless` compares `impl` pointer (backend/headless/backend.c:84-86).
- smithay: N/A.
- verdict: missing, but harmless — the typed `data: *anyopaque` + comptime dispatch replaces it [VERIFIED 2026-08-09: backend.zig's Impl fn-pointer table with typed data (backend.zig:29-34,49-57) — the typed `*anyopaque` per-impl data + comptime dispatch gives the same per-impl polymorphism as wlr_backend_impl's void data].

## Gaps

1. No `new_input` signal. Ours emits only `new_output`/`destroy` (backend.zig:22-27); wlroots inits and emits `new_input` (include/wlr/backend.h:43, backend/backend.c:42). A libinput backend cannot announce devices through the seam.
2. Frame timer re-armed unconditionally. `frameCb` re-arms on every fire (headless.zig:91-97); wlroots re-arms only inside `output_commit` when the output is enabled (backend/headless/output.c:61-64) and `signal_frame` returns 0 (output.c:113-117). Ours frames even with no commits; wlroots paces per commit.
3. Single hardwired output. `HeadlessBackend.create` builds one output at a fixed mode (headless.zig:38-64); wlroots supports N runtime-addable outputs with auto names/descriptions (`wlr_headless_add_output`, output.c:119-200) and emits `new_output` for add-after-start (output.c:194-196).
4. No event-loop-destroy teardown hook. Ours registers nothing on the loop (headless.zig:38-64); wlroots adds `wl_event_loop_add_destroy_listener` and destroys the backend when the loop goes away (backend/headless/backend.c:53-57, 62-64). Risk: leak if the event loop is torn down first.
5. No `buffer_caps`/`features` on Backend (backend.zig:15-27) vs include/wlr/backend.h:36-39, set by headless at backend/headless/backend.c:69-71, 87-88. DMABUF/SHM capability is not queryable.
6. No backend-level `test`/`commit`/`get_drm_fd` (Backend.Impl, backend.zig:29-34) vs `wlr_backend_impl` (include/wlr/backend/interface.h:19-24), `wlr_backend_test`/`wlr_backend_commit` (backend/backend.c:442, 459), `wlr_backend_get_drm_fd` (backend/backend.c:117). No atomic multi-output state path.
7. No `wlr_backend_autocreate` equivalent (backend/backend.c:327) — no multi-backend, no session handling, no env-driven selection (`WLR_BACKENDS`).
8. No present event on headless commit (headless.zig:101-125) vs wlroots deferring a present with `commit_seq + 1`, `presented = true` (output.c:55-60). Presentation feedback cannot observe the headless output.
9. Commit cannot change refresh: ours reads only the create-time mode (headless.zig:42-56, 101-125); wlroots recomputes `frame_delay` on mode commit (output.c:25-31, 61-64).
10. `Impl.start` non-optional with no default-true path (backend.zig:31) vs wlroots treating NULL `impl->start` as success (backend/backend.c:55-59). Minor.
11. `Backend.destroy` does not assert that listeners are drained (backend.zig:63-67) vs `wlr_backend_finish` asserts all three lists empty (backend/backend.c:50-52). Minor.

## Verdict

Lifecycle parity is high: init/start/destroy and the `new_output`/`destroy` signals match the wlr_backend pattern closely, and the headless announce-on-start matches `backend_start` (backend/headless/backend.c:14-32). The riskiest divergences: (1) unconditional timer re-arm in `frameCb` vs wlroots' commit-gated pacing (headless.zig:91-97 vs output.c:61-64) — a busy-loop hazard; (2) the missing `new_input` signal (backend.zig:22-27) blocks any libinput backend from announcing devices; (3) no event-loop-destroy hook (vs backend/headless/backend.c:53-57) — teardown order leak; (4) no buffer_caps/features — DMABUF/SHM capability is unqueryable, which will block DRM/renderer integration. Secondary: no multi-output, no backend test/commit, no present event, no autocreate. smithay provides no comparison surface: it has no Backend abstraction at all, so every smithay row is N/A with per-module calloop backends (src/backend/mod.rs:1-113) as the closest analogue.
