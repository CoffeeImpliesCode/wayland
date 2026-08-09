# Server wiring — wlroots/smithay diff

Scope: `src/server/main.zig` (1226 lines; the tinywl-equivalent test server: env parsing, listener wiring, zio loop, teardown defers, synth input, watchdog, framebuffer resize) plus the backend abstraction and headless impl it drives (`src/backend/backend.zig`, `src/backend/headless.zig`). wlroots 0.20.2: `tinywl/tinywl.c` (NOTE: tinywl moved from `examples/` to the tree top in 0.20.2), `backend/backend.c`, `backend/libinput/backend.c`, `backend/drm/drm.c`, `types/output/output.c`. smithay v0.7.0: `anvil/src/main.rs`, `anvil/src/udev.rs`, `anvil/src/state.rs`, `src/backend/mod.rs`, `src/backend/libinput/mod.rs`. libwayland 1.24 `src/event-loop.c` cited for `wl_event_loop_dispatch` semantics; zio 0.17.0 `src/ev/completion.zig` for rearm; zig_wayland 0.6.0 `src/wayland_server_core.zig` for Listener/Signal.

## Surface

Public/private inventory of the wiring surface (file:line relative to repo root):

`src/server/main.zig`:
- `main` (main.zig:172) — env parsing, object init order, listener registration, zio loop, LIFO teardown defers.
- `onNewInput` (main.zig:474) — backend `new_input` (libinput device announcements).
- `onNewOutput` (main.zig:484) — output announce: framebuffer resize, scene build, frame listener, wl_output global, cursor nodes.
- `onNewToplevel` (main.zig:569), `onNewPopup` (main.zig:581).
- `onInputReady` (main.zig:592), `onDrmReady` (main.zig:602), `onDisplayReady` (main.zig:610), `onWatchdog` (main.zig:626), `onOutputFrame` (main.zig:633).
- `renderFrame` (main.zig:642) — damage, composite, `commitState`, `sendFrameDone`, presentation, flush, watchdog re-arm, RUN_FRAMES stop.
- `syncSurfaces` (main.zig:820), `onSurfaceCommit` (main.zig:848), `onSurfaceDestroy` (main.zig:856), `updateSurfaceNode` (main.zig:867), `removeSurfaceNode` (main.zig:941), `cleanupSurfaceEntries` (main.zig:1001).
- `wantDrmBackend` (main.zig:1017), `wantRaylibBackend` (main.zig:1023), `parseLogConfig` (main.zig:1208), `parseLevel` (main.zig:1192).
- `ServerState` (main.zig:101-170) — six state listeners (main.zig:165-169, 131).

`src/backend/backend.zig` and `src/backend/headless.zig`: full inventory in notes/114 (this round re-verifies only the wiring-relevant parts: `Backend.init` signal init backend.zig:46-54, headless timer on the wire loop headless.zig:71-80, `frameCb` headless.zig:91-97).

## Sanity review

Verified-correct items first; findings are numbered in Gaps.

(a) Event loop. Three PipePolls registered with `flags.rearm = true`: display fd (main.zig:420-424), libinput fd (main.zig:427-433), DRM fd (main.zig:436-443). zio rearm semantics verified: `rearm` re-adds the completion after its callback returns (zio src/ev/completion.zig:240-244), so the registrations persist. `display.dispatch(0)` semantics verified against libwayland 1.24 `wl_event_loop_dispatch` (src/event-loop.c:1006-1076): a zero timeout makes `epoll_wait` return immediately (event-loop.c:1025, "A timeout of zero causes the poll to always return immediately"), and due timers are dispatched BEFORE non-timer sources via `wl_timer_heap_dispatch` when the loop's timerfd fired (event-loop.c:1048-1062). The headless frame timer lives on the WIRE loop (main.zig:258-279 pass `display.getServer().getEventLoop()`; headless.zig:71-80), so its expiry makes the wire-loop fd readable and the headless `frameCb` → `sendFrame` → `renderFrame` chain runs inside `dispatch(0)` — exactly as the comment at main.zig:616-618 claims. Correct.

Double flush per headless frame: `renderFrame` flushes (main.zig:799) and `onDisplayReady` flushes again after dispatch (main.zig:623). Flushing an empty outbound buffer is a no-op, so the second flush is harmless; it is also NECESSARY: timers dispatch first (event-loop.c:1054-1060), so client requests processed later in the same dispatch round can marshal events after the frame's flush, and the second flush pushes them. For the DRM path the `renderFrame` flush is the ONLY flush most frames (the drm fd drives the frame loop while the display fd may be idle); without it, `wl_callback.done` and presentation events would sit in the outbound buffer indefinitely. The flush location (after `commitState`, after `sendFrameDone`) matches the marshalling order. Correct, not a bug.

(b) Listener-registration audit (exhaustive — every `.add()` in main.zig with its init state):

| # | Registration | Listener init | Signal init |
|---|---|---|---|
| 1 | `backend.events.new_output.add(&state.new_output_listener)` (main.zig:340) | `.init(onNewOutput)` in the state literal (main.zig:323) | `Backend.init` (backend.zig:50) |
| 2 | `ib.events.new_input.add(&state.new_input_listener)` (main.zig:343) | `.init(onNewInput)` (main.zig:324) — THE recent fix | `Backend.init` (backend.zig:51) |
| 3 | `shell.events.new_toplevel.add(&state.new_toplevel_listener)` (main.zig:345) | `.init(onNewToplevel)` (main.zig:326) | XdgShell init |
| 4 | `shell.events.new_popup.add(&state.new_popup_listener)` (main.zig:346) | `.init(onNewPopup)` (main.zig:327) | XdgShell init |
| 5 | `seat.events.key.add(&state.seat_key_listener)` (main.zig:347) | `.init(onSeatKey)` (main.zig:328) | `Seat.init` (seat.zig:145) |
| 6 | `out.events.frame.add(&self.frame_listener)` (main.zig:534) | `.init(onOutputFrame)` (main.zig:325) | `Output.create` (output.zig:130) |
| 7 | `s.events.commit.add(&entry.commit_listener)` (main.zig:839) | `.init(onSurfaceCommit)` (main.zig:831) | Surface init |
| 8 | `s.events.destroy.add(&entry.destroy_listener)` (main.zig:840) | `.init(onSurfaceDestroy)` (main.zig:832) | Surface init |

`Listener.init` leaves `link` undefined (wayland_server_core.zig:383-387); `Signal.add` writes it via list insert (common_core.zig:96-97). The GP-fault class is an `.add()` on a listener whose link was never set OR a by-value copy of an already-added listener carrying a stale link. No remaining instance: all eight listeners are `.init()`-ed in the same literal that precedes the registrations, every signal is `.init()`-ed before any emit, and `SurfaceEntry` is stored by POINTER in the map (main.zig:834), so no listener is ever copied after being added. One latent hazard: the same `frame_listener` would be appended to a second output's frame list if a backend ever announced two outputs (a listener can live in one list only); all three backends are single-output today (headless.zig:38-64, drm.zig:139-162). Note only.

(c) Teardown order. Defer registrations (main.zig): 174 debug_alloc, 178 log tags, 188 runtime, 196 display, 202 presentation, 215 compositor, 217 shm_state, 220 shell, 223 seat, 226 subcompositor, 229 data_device, 231 renderer, 281 backend, 284 framebuffer, 304 input_backend, 331 toplevels, 336 scene, 337 scene_output, 338 cleanupSurfaceEntries, 366 screencopy, 415 loop. LIFO execution order: screencopy → cleanupSurfaceEntries → scene_output.destroy → scene.deinit → toplevels.deinit → input_backend.destroy → framebuffer.deinit → backend.destroy → renderer.destroy → data_device.deinit → subcompositor.deinit → seat.deinit → shell.deinit → **shm_state.deinit → compositor.deinit** → presentation.deinit → display.deinit (clients LAST) → loop.deinit → runtime.deinit → log tags → debug_alloc. The shm_state-before-compositor pair is the one proven ordering bug (Gap 1). Everything else checks out: seat.deinit never emits signals (seat.zig:154-157), so the still-registered data_device `focus_listener` (data_device.zig:76, never removed at deinit 81-85) is never called after its owner frees; SceneOutput holds NO output listeners (scene.zig:269-310); the six state listeners live on the stack through teardown; `wl_output` frees itself inside the output-destroy signal during backend.destroy (wl_output.zig:118-126), which is before anything touches `out` again; cleanupSurfaceEntries removes surface listeners before compositor.deinit destroys surfaces (no double free; the scene-node destroy path is idempotent because nodes were already detached).

(d) Env parsing: see Gap 6.

(e) DRM framebuffer resize: reallocated in `onNewOutput` when the announced mode differs from 1280x720 (main.zig:492-501: create new, `self.framebuffer.deinit()`, swap). The damage ring is fresh by construction: `SceneOutput` is created AFTER the resize (main.zig:505+) with an empty ring. Two mismatches remain — the first-frame whole-output damage (main.zig:697-699), the damage clip rect `out_rect` (main.zig:700), and the toplevel reconfigure (main.zig:927) all use the 1280x720 CONSTANTS instead of `out.mode`/`out.width` (Gap 2). Both DRM (whole-fb copy, drm.zig:497-503) and headless (log-only commit, headless.zig:101-125) ignore damage, so the wrong rects are invisible today.

(f) Watchdog / RUN_FRAMES: zio callbacks are serialized on the loop thread; `onWatchdog` (main.zig:626-631) runs only from `loop.poll` dispatch, so it cannot preempt a frame mid-`renderFrame`. It can only fire when the loop is idle for 5 s — i.e. after a frame path that skipped the re-arm (early-return errors at main.zig:639/745, or a wedged DRM flip chain). Stop-with-flip-pending: Gap 3.

(g) Synth input: guarded by `synth_fired` (main.zig:669-693), set BEFORE the events are sent, so no double fire. It fires on the first frame where any surface has a scene node — the client is NOT focused yet; focus is established by the synthetic click itself via the seat's click-to-focus (seat.zig:838-852 test), but only if a surface covers (50,50) at that instant. The client may still be at its initial size (the reconfigure at main.zig:927 is sent during the same frame but lands asynchronously). [INFERENCE] risk for a client whose first-mapped surface does not cover (50,50) — Gap 7.

(h) Backend selection / exit code: `WAYLAND_BACKEND=drm` → `try drm_mod.DrmBackend.create` (main.zig:242) then `try backend.start()` (main.zig:408). `DrmBackend.create` only allocates; every real failure (open, master, connector, modeset) surfaces in `startInner` as `error.BackendFailed` (drm.zig:169-181, 186-192, 236-246, 445-453) and propagates out of `main` → the Zig runtime reports the error and exits non-zero. Verified by code structure; the exact exit code (1) is std behavior [INFERENCE]. `WAYLAND_BACKEND=raylib` failure falls back to headless with a warning (main.zig:254-268); DRM has no fallback — intentional.

## Comparison

### Main loop
- ours: `zio.ev.Loop` with three PipePolls + one Timer, `while (!loop.stopped()) loop.poll(.max)` (main.zig:413-459).
- wlroots tinywl: `wl_display_run(server.wl_display)` (tinywl/tinywl.c:1070) — libwayland's own loop; the backend registers everything (libinput fd, DRM fd, frame timers) onto that same wire loop.
- smithay anvil: calloop `EventLoop` + `while state.running { event_loop.dispatch(Some(16ms), &mut state); space.refresh(); display_handle.flush_clients() }` (anvil/src/udev.rs:537-545); the wayland Display is itself a calloop source (anvil/src/state.rs:655-665).
- verdict: equivalent shape (one loop, per-source callbacks); ours splits the headless frame timer onto the WIRE loop and the watchdog onto the zio loop (two timer systems); tinywl and anvil each use one.

### Backend selection
- ours: `WAYLAND_BACKEND` string switch — "drm" → DRM, "raylib" → raylib (headless fallback), anything else → headless (main.zig:240-280); no multi-backend, no session.
- wlroots: `wlr_backend_autocreate` (backend/backend.c:327-441) — multi-backend; precedence WLR_BACKENDS (explicit, comma list) → WAYLAND_DISPLAY/WAYLAND_SOCKET → DISPLAY → DRM+libinput+session; unknown WLR_BACKENDS name is a hard error (backend.c:347-352).
- smithay: CLI-arg selection in anvil (`--winit`/`--tty-udev`/`--x11`, anvil/src/main.rs:23-53); no autocreate equivalent (matches notes/114).
- verdict: ours is a fixed 3-way env switch; no fallback chain except raylib→headless. Unknown values fall through silently (Gap 6).

### libinput fd embedding
- ours: separate zio PipePoll on the libinput fd; `onInputReady` → `Libinput.dispatch()` (main.zig:427-433, 592-600); drain loop identical to wlroots (libinput.zig:301-311).
- wlroots: `wl_event_loop_add_fd(session->event_loop, libinput_fd, WL_EVENT_READABLE, handle_libinput_readable, backend)` (backend/libinput/backend.c:119-120); `handle_libinput_readable` does `libinput_dispatch` + drain (backend.c:49-60); on dispatch failure it DESTROYS the backend (backend.c:52-55); the initial device burst is drained in `backend_start` (backend.c:107-118).
- smithay: `LibinputInputBackend` implements calloop `EventSource` (src/backend/libinput/mod.rs:707-891), level-triggered READ (mod.rs:879); `process_events` does `context.dispatch()` then iterates events (mod.rs:714-723); DeviceAdded handling with capability checks in anvil (anvil/src/udev.rs:309-319).
- verdict: same pattern (fd poll + dispatch + drain); ours logs on dispatch failure instead of failing hard (Gap 8); smithay's EventSource API is the Rust analogue of our PipePoll.

### Output add/commit flow
- ours: backend `emitNewOutput` (backend.zig:71-73) inside `start` (headless.zig:78-80, drm.zig:428-430); server `onNewOutput` builds the scene and attaches `out.events.frame` DURING the emit (main.zig:484-534) so the DRM `sendFrame()` immediately after the emit (drm.zig:430) reaches the listener. Commit: `Output.commitState` = test → impl commit → apply → `commit` signal (output.zig:136-146); the server commits enabled+mode+buffer every frame (main.zig:741-773).
- wlroots: `wlr_backend_start` → impl emits `new_output` (backend/headless/backend.c:14-32; drm.c:1896); commit is `wlr_output_commit_state` = `output_basic_test` + `output_prepare_commit` + `impl->commit` + `output_apply_commit` (sets `frame_pending`, `commit_seq`) + `commit` event (types/output/output.c:793-831); frame events driven by the backend (drm flip → `wlr_output_send_frame`, drm.c:2084-2086).
- smithay: `DrmDevice::new` returns a notifier whose `DrmEvent::VBlank` drives scheduling (anvil/src/udev.rs:787-795); connectors/CRTCs managed via `DrmOutputManager`; no unified wlr_output_state analogue — state lives on smithay types.
- verdict: ours matches the wlroots state-object shape; no present event, no `commit_seq`, no `frame_pending` on the Output (already noted in notes/114).

### Frame scheduling
- ours: flip-driven for DRM — `pageFlipHandler` clears `flip_pending` and calls `out.sendFrame()` (drm.zig:789-805); a second commit while `flip_pending` is refused (drm.zig:482-485); timer-driven for headless (`frameCb` re-arms unconditionally, headless.zig:91-97).
- wlroots: same flip-completion pacing — `handle_page_flip` sends present, then `wlr_output_send_frame` if the session is active (drm.c:2009-2087); pending-flip guard at drm.c:992-996; `wlr_output_send_frame` clears `frame_pending` and emits only when enabled (output.c:833-846); `frame_pending` set on commit (output.c:774-777); `wlr_output_schedule_frame` idle-frame path for needs_frame (output.c:848-861).
- smithay: `DrmEvent::VBlank` → `frame_finish` → `schedule_render` inserts a one-shot calloop Timer for the next frame target (anvil/src/udev.rs:1379-1383, 1545-1548).
- verdict: ours mirrors wlroots' flip-driven model with a `flip_pending` guard; lacks `frame_pending`/`needs_frame`/idle-frame scheduling (a client that requests frame callbacks without committing gets nothing).

### Flush pattern
- ours: flush at end of `renderFrame` (main.zig:799) AND after every dispatch (main.zig:623).
- wlroots tinywl: `wl_display_run` flushes clients per dispatch iteration (libwayland loop; tinywl.c:1070).
- smithay: `display_handle.flush_clients()` after every loop dispatch (anvil/src/udev.rs:544).
- verdict: same intent; ours additionally flushes inside the frame path so the DRM flip-driven loop (display fd idle) still delivers frame-done/presentation events promptly.

### Teardown
- ours: LIFO defers; clients destroyed LAST (`display.deinit` → `Server.destroy`, main.zig:196 + display.zig:49-59).
- wlroots tinywl: `wl_display_destroy_clients` FIRST, before scene/backend/display teardown (tinywl.c:1073-1076).
- smithay: Rust drop order; anvil has no explicit client-destroy step before teardown.
- verdict: directly relevant to Gap 1 — wlroots kills clients before any compositor resource is freed, which is exactly the ordering our shm_state/compositor pair lacks.

## Gaps

1. **[HIGH, ordering proven / crash latent]** `shm_state.deinit` runs BEFORE `compositor.deinit` (defers at main.zig:217 vs 215; LIFO). `ShmState.deinit` frees every tracked wrapper and every graveyard wrapper (shm.zig:118-138) while surfaces still reference them; `Compositor.deinit` then destroys surfaces (compositor.zig:89-97) and `Surface.destroy` calls `b.drop()`/`b.unlock()` on those freed wrappers (surface.zig:255-262), which writes the release-signal list and reads freed `ShmBufferData` (shm.zig:225-232). The graveyard premise ("clients have disconnected first") does not hold on the paths that run defers: the VM E2E kills the server with SIGTERM (no defers run — no signal handler, scripts/vm-e2e.sh:63-65), but RUN_FRAMES=400 (vm-e2e.sh:29) stops the loop NORMALLY while the client may still be alive, and watchdog/Mod4+Escape stops do too. Under DebugAllocator the freed memory retains its values, so the writes usually "work" and the E2E passes; under heap reuse this corrupts a live allocation. Fix: swap the two defers (register `shm_state.deinit` before `compositor.deinit`), or destroy clients first like tinywl (tinywl.c:1075).
2. **[MED]** Damage rects and the toplevel reconfigure hardcode 1280x720 instead of the output mode: first-frame whole damage (main.zig:697-699), `out_rect` clip (main.zig:700), reconfigure size (main.zig:927). For a DRM mode != 1280x720 the damage ring carries wrong-sized rects; invisible today because DRM copies the whole framebuffer (drm.zig:497-503) and headless only logs (headless.zig:101-125), but any damage-uploading backend would tear. Use `out.mode.width/height` or `out.width/height`.
3. **[LOW]** Flip-pending at loop stop: RUN_FRAMES/watchdog stop the loop between `commit` and the flip event (`flip_pending` stays true, drm.zig:512); teardown then calls RmFB/destroy-dumb/munmap/close without waiting (drm.zig:700-745; RmFB error ignored). Benign in practice because the kernel refcounts in-use FBs and releases them on fd close [INFERENCE]. wlroots tracks pending flips explicitly (`pending_page_flip`, drm.c:550-561; guard drm.c:992-996; cleared at connector destroy drm.c:1252) and refuses a second non-blocking flip while one is pending. No wait-for-idle in ours.
4. **[LOW]** The first DRM frame renders INSIDE `backend.start()` (main.zig:408) before `state.loop` (main.zig:416) and `state.watchdog` (main.zig:452) are set. `renderFrame`'s only `self.loop.?` use is behind `if (self.watchdog)` (main.zig:803-807), so the path survives by null-guard luck; any future unguarded `self.loop.?.` in the frame path panics on the DRM first frame. Set loop+watchdog before `backend.start()` or document the invariant.
5. **[LOW]** `DataDeviceManager` never removes `focus_listener` from `seat.events.keyboard_focus` in deinit (registered data_device.zig:76; deinit 81-85 frees the struct). Safe only because `seat.deinit` never emits (seat.zig:154-157) and nothing emits after teardown begins; a late `keyboard_focus` emit after data_device deinit is a use-after-free. wlroots asserts listener lists are empty at finish (backend/backend.c:47-53 pattern).
6. **[LOW]** Silent env failures: `WAYLAND_RUN_FRAMES` non-integer or overflowing → `catch 0` → "run forever", silently disabling the test stop (main.zig:368-372); unknown `WAYLAND_BACKEND` value → silent headless (main.zig:1017-1026); `WAYLAND_LIBINPUT` any value != "1" → silently ignored (main.zig:288-302). wlroots logs and ignores invalid ints (`parse_outputs_env`, backend.c:125-137) but hard-errors on unknown backend names (backend.c:347-352). Log a warning on each parse failure.
7. **[LOW, [INFERENCE]]** Synth input can fire while no surface covers (50,50): it triggers on the first mapped surface (main.zig:669-693), but focus is established only if the click lands on a surface (seat click-to-focus, seat.zig:838-852) and the toplevel may still be at its initial size (reconfigure lands asynchronously, main.zig:927). The key 'a' then goes to whatever focus exists (possibly none). Not wrong for the shipped test client (initial surface is larger than 50x50 at (0,0)); fragile for any other client.
8. **[INFO]** `onInputReady` logs a failed libinput dispatch and keeps polling (main.zig:592-600); wlroots destroys the backend on dispatch failure (backend/libinput/backend.c:52-55). A wedged libinput fd produces log spam, not fail-stop.

## Verdict

The zio wiring (three rearmed PipePolls, `dispatch(0)` semantics, the renderFrame-end flush) is correct and the DRM-frame-loop flush fix is the right call — the double flush per headless frame is idempotent and required on the DRM path. The listener audit is clean: all eight `.add()` registrations in main.zig operate on `.init()`-ed listeners and initialized signals; the `new_input` fix (main.zig:324/343) closes the last instance of the GP-fault class. The one real ordering bug is Gap 1 (shm_state.deinit before compositor.deinit), a latent surface-buffer use-after-free that the "clients disconnect first" premise does not cover on the RUN_FRAMES/watchdog paths — swap two defers. Everything else is minor: hardcoded damage size (2), no wait-for-idle for pending flips (3), the first-DRM-frame timing (4), silent env parsing (6), and the wlroots parity gaps already catalogued in notes/114 (no present event, no frame_pending/needs_frame, no autocreate).
