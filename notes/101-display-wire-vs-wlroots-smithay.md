# Display — wlroots/smithay diff

Our module is a thin wrapper over libwayland-server (via zig-wayland v0.6.0 generated bindings, re-exported by `src/core/wire.zig`). wlroots also wraps libwayland-server directly; smithay wraps the `wayland-server` Rust crate (v0.31.13, Cargo.toml:63). Substrate citations: zig-wayland `src/wayland_server_core.zig` (= zws), libwayland `src/wayland-server.c` (= wls), `src/wayland-shm.c` (= wlshm).

## Surface

Public inventory of our module (`src/core/display.zig`, grep `pub const`/`pub fn`):

- `CompositorDisplay` struct (display.zig:16) — owns `*wire.Server`, socket name, shm guard, destroyed flag.
  - `init` (display.zig:28) — create libwayland server + allocate struct.
  - `deinit` (display.zig:46) — `Server.destroy` (tears down clients/globals/loop) + free socket name.
  - `initShm` (display.zig:61) — enable libwayland internal wl_shm; idempotent.
  - `addSocketAuto` (display.zig:76) — auto listen socket wayland-N, N>=1; dupe name.
  - `getServer` (display.zig:86) — raw `*wire.Server` accessor.
  - `run` (display.zig:91) — libwayland event loop until terminate.
  - `terminate` (display.zig:95) — stop the loop.
  - `loopFd` (display.zig:101) — fd of display event loop, for external loops (zio, server/main.zig:367).
  - `dispatch` (display.zig:107) — `wl_event_loop_dispatch(timeout)`.
  - `flushClients` (display.zig:112) — flush buffered events.
  - `nextSerial` (display.zig:117) — wl_display serials.
  - `addGlobal` (display.zig:123) — advertise a global with typed bind callback.
  - `attachProtocolLogger` (display.zig:137) — log all protocol messages via structured logger.
- `protocolLog` (display.zig:168) — private logger callback with wl_surface.attach buffer-id special case.

Substrate re-exports in `src/core/wire.zig:9-28`: Server, Client, Global, Resource, EventLoop, EventSource, ProtocolLogger, shm, list, Credentials, Listener, Signal.

## Comparison

### `init` (display.zig:28)
- ours: `Server.create` → `wl_display_create` (zws:35); no socket, no loop start.
- wlroots: `wl_display_create()` (tinywl/tinywl.c:910); backend attaches to `wl_display_get_event_loop` (tinywl.c:915).
- smithay: `Display::<State>::new()` (anvil/src/winit.rs:96); wayland-server crate owns the display backend.
- verdict: same. All three create the same underlying display object (libwayland or its Rust port).

### `deinit` (display.zig:46)
- ours: `Server.destroy` → `wl_display_destroy`; single-shot guard; frees duped socket name.
- wlroots: explicit order — `wl_display_destroy_clients` (tinywl.c:1075), then backend/renderer/allocator destroy, then `wl_display_destroy` (tinywl.c:1099).
- smithay: N/A — no explicit destroy API; `Display` is dropped at loop end (anvil shutdown).
- verdict: close. Ours relies on `wl_display_destroy` tearing down clients and globals implicitly; wlroots runs an explicit client-destroy phase before display teardown.

### `initShm` (display.zig:61)
- ours: `Server.initShm` → `wl_display_init_shm`, which creates libwayland's internal wl_shm global v2 (`wl_global_create(..., &wl_shm_interface, 2, NULL, bind_shm)`, wlshm:475-481); bind sends ARGB8888+XRGB8888+additional formats (wlshm:449-473); we also register formats 0/1 via `wl_display_add_shm_format` (wls:2367, display.zig:70-71). Idempotence guard prevents double registration (display.zig:62-64).
- wlroots: does NOT call `wl_display_init_shm`. `wlr_renderer_init_wl_display` → `wlr_shm_create_with_renderer(display, 2, r)` (render/wlr_renderer.c:78-81, tinywl.c:931) → wlroots' own wl_shm global (`wl_global_create`, types/wlr_shm.c:536) advertising the renderer's WLR_BUFFER_CAP_DATA_PTR texture formats converted DRM→wl_shm codes (wlr_shm.c:533, 553-578). Own pool/buffer impl: stride validation (wlr_shm.c:342-345), unknown-format client kill (wlr_shm.c:328-331), SIGBUS mapping guard, wlr_buffer begin/end_data_ptr_access (wlr_shm.c:214-259).
- smithay: `ShmState::new::<D>(&display.handle(), formats)` → `display.create_global::<D, WlShm, _>(2, GlobalData)` (src/wayland/shm/mod.rs:143-158); ARGB8888/XRGB8888 always inserted (shm/mod.rs:151-153); bind handler sends formats (shm/handlers.rs:25-33); own pool handling with SIGBUS safety (shm/pool.rs, mod.rs:96-97).
- verdict: close on surface, divergent underneath. All three advertise wl_shm v2 with ARGB8888/XRGB8888. Ours delegates to libwayland's internal implementation (no renderer-format integration, no format/stride validation beyond libwayland's, buffers read via `wl_shm_buffer_get`, src/buffers/shm.zig:12-18); wlroots and smithay implement the protocol themselves and feed it renderer/formats.

### `addSocketAuto` (display.zig:76)
- ours: `Server.addSocketAuto` (zws:44-57) loops wayland-1..32 via `wl_display_add_socket`, skipping wayland-0; name duped into our allocator, freed at deinit.
- wlroots: `wl_display_add_socket_auto` (wls:1996-2020) — starts at wayland-0 (`displayno = 0`); name owned by libwayland; NULL on failure.
- smithay: `ListeningSocketSource::new_auto` → `ListeningSocket::bind_auto("wayland", 1..33)` (src/wayland/socket.rs:65-74) — skips wayland-0 for the same reason (socket.rs:67-69); socket wrapped as a calloop EventSource; accepted streams inserted via `DisplayHandle::insert_client` (anvil/src/state.rs:638-647, socket.rs:99).
- verdict: close. Same 1..32 auto-name semantics as smithay and zig-wayland; libwayland (hence wlroots compositors) includes wayland-0. Ours duplicates the name because the zig-wayland buffer is stack-owned; smithay never registers the socket on the display at all.

### `getServer` (display.zig:86)
- ours: returns `*wire.Server` for test clients and event-loop registration (server/main.zig:225-251, 367).
- wlroots: N/A — plain `struct wl_display *` threaded through every `wlr_*_create` (tinywl.c:951-1030); no wrapper object.
- smithay: N/A — `Display` is a concrete struct; helpers take `&DisplayHandle` (anvil state.rs:632, shm/mod.rs:158).
- verdict: ours-only accessor; the underlying handle exists in all three.

### `run` (display.zig:91)
- ours: `Server.run` → `wl_display_run` (zws:71-73) — libwayland's own loop, blocks until terminate.
- wlroots: `wl_display_run(server.wl_display)` (tinywl.c:1070) — the same function.
- smithay: N/A — the wayland-server crate has no run(); the compositor owns the loop (calloop) and drives the display (anvil state.rs:657-662).
- verdict: same vs wlroots; divergent vs smithay (loop ownership: libwayland-internal vs compositor-owned).

### `terminate` (display.zig:95)
- ours: `Server.terminate` → `wl_display_terminate` (zws:67-69).
- wlroots: `wl_display_terminate` from the SIGINT handler (tinywl.c:184).
- smithay: N/A — no terminate; shutdown = loop ends + Display dropped.
- verdict: same vs wlroots; N/A vs smithay.

### `loopFd` (display.zig:101)
- ours: `wl_event_loop_get_fd` (zws:571), polled by zio (server/main.zig:367, 382).
- wlroots: same loop via `wl_display_get_event_loop` handed to the backend (tinywl.c:915); `wlr_backend_dispatch` runs `wl_event_loop_dispatch` (backend/backend.c:90, backend/session/session.c:501).
- smithay: N/A — calloop owns fd polling; no fd accessor.
- verdict: ours-only accessor; the substrate (wl_event_loop) is identical to wlroots.

### `dispatch` (display.zig:107)
- ours: `EventLoop.dispatch` → `wl_event_loop_dispatch(timeout)` (zws:555-563); called non-blocking (timeout 0) from the zio loop then `flushClients` (server/main.zig:503-507).
- wlroots: server-side dispatch is inside `wl_display_run` or `wlr_backend_dispatch` → `wl_event_loop_dispatch` (backend.c:90, session.c:501). `wl_display_dispatch` itself appears only in the wayland backend, as a CLIENT call on the remote display (backend/wayland/backend.c:60).
- smithay: `display.get_mut().dispatch_clients(data)` (anvil state.rs:662) — dispatches pending client events only; calloop does the fd polling (state.rs:657-661).
- verdict: divergent in architecture. Ours and wlroots use the libwayland event loop (dispatch covers all loop sources); smithay splits fd polling (calloop) from client dispatch (dispatch_clients), so its dispatch never blocks on the display.

### `flushClients` (display.zig:112)
- ours: `Server.flushClients` → `wl_display_flush_clients` (zws:75-77).
- wlroots: same libwayland call, implicit inside `wl_display_run`; not called manually in tinywl.
- smithay: N/A — flushing is internal to the crate's dispatch path.
- verdict: same vs wlroots (same function); N/A vs smithay (internal).

### `nextSerial` (display.zig:117)
- ours: `Server.nextSerial` → `wl_display_next_serial` (zws:112-114; wls:1708-1715) — increments `display->serial` then returns; display-owned; first call returns 1.
- wlroots: `wl_display_next_serial(display)` used pervasively: seat serials (types/seat/wlr_seat.c:475-477), layer-shell configure (types/wlr_layer_shell_v1.c:330), xdg-shell scheduled serial (types/xdg_shell/wlr_xdg_surface.c:171), data-control (types/wlr_data_control_v1.c:348), xwm (xwayland/xwm.c:2255).
- smithay: `SerialCounter::next_serial` (src/utils/serial.rs:77-82) — atomic `fetch_add`, wraps 0→1 via compare_exchange (serial.rs:78-80); global `SERIAL_COUNTER` static (serial.rs:6); decoupled from Display and thread-safe; `Serial` type does wrapping-aware comparison (serial.rs:11-29).
- verdict: divergent. Ours/wlroots tie serials to the wl_display object (single-threaded by construction); smithay uses a free-standing atomic counter, shareable across threads. Both skip 0 in practice (libwayland increments before returning from 0; smithay counter starts at 1).

### `addGlobal` (display.zig:123)
- ours: `Global.create` → `wl_global_create` (zws:197-211) with typed bind callback; returns `*wire.Global` (remove/destroy available in zig-wayland, zws:213-220).
- wlroots: raw `wl_global_create(display, &wl_X_interface, version, data, bind)` per protocol — e.g. compositor (types/wlr_compositor.c:1377), subcompositor (types/wlr_subcompositor.c:425), shm (types/wlr_shm.c:536), seat (types/seat/wlr_seat.c:337); global removed on display destroy (wlr_shm.c:493-499).
- smithay: `display.create_global::<D, I, _>(version, GlobalData)` returning a `GlobalId` (shm/mod.rs:158, 164); bind handled by `GlobalDispatch2::bind` (src/wayland/dispatch2.rs:25-38; shm/handlers.rs:25-33); per-client visibility via `GlobalDispatch2::can_view` (dispatch2.rs:31-34).
- verdict: same core (advertise global + per-client bind callback). Differences: ours returns the raw global pointer (caller tracks lifetime); smithay returns a GlobalId for later removal; global visibility filtering exists in zig-wayland (`setGlobalFilter`, zws:94-108) but is NOT exposed through CompositorDisplay, whereas smithay exposes `can_view`; wlroots core uses no global filter.

### `attachProtocolLogger` (display.zig:137)
- ours: `Server.addProtocolLogger` → `wl_display_add_protocol_logger` (zws:116-131; wls:2314-2328); structured-log callback with a wl_surface.attach buffer-id special case (display.zig:168-199).
- wlroots: N/A — no usage of `wl_display_add_protocol_logger` anywhere in wlroots.
- smithay: N/A — no protocol-logger equivalent in smithay or the wayland-server crate (grep over src/ and anvil/ finds none).
- verdict: ours-only. Debugging aid; no protocol semantics.

## Gaps

1. **No renderer-driven wl_shm format list.** Ours advertises only ARGB8888/XRGB8888 plus whatever we hand-register via `addShmFormat` (display.zig:61-73); the global is libwayland's internal one (wlshm:475-481). wlroots advertises the renderer's DATA_PTR texture formats (types/wlr_shm.c:553-578 via render/wlr_renderer.c:78); smithay takes an explicit format list (shm/mod.rs:143-158). Extra formats must be registered manually per format code — no query of renderer capability.
2. **No per-buffer validation or buffer abstraction.** wlroots wlr_shm rejects unknown formats and kills the client (wlr_shm.c:328-331), validates stride (wlr_shm.c:342-345), and exposes a wlr_buffer with begin/end_data_ptr_access (wlr_shm.c:214-259); smithay has pool.rs plus `with_buffer_contents` access (shm/mod.rs:183-210). Ours reads raw shm via `wl_shm_buffer_get` (src/buffers/shm.zig:12-18, 166) — no stride check, no access-callback discipline, no format allow-list at pool-create time beyond libwayland's.
3. **Socket name selection diverges from wlroots.** Ours (zws:44-57) and smithay (socket.rs:65-74) skip wayland-0; `wl_display_add_socket_auto` starts at wayland-0 (wls:1996-2010), so a wlroots compositor can own wayland-0. Ours is deliberately safer (client fallback to wayland-0 without WAYLAND_DISPLAY), but the two ecosystems may pick different names for the same display slot.
4. **No explicit client-destroy / global-remove lifecycle API.** wlroots destroys clients explicitly before display teardown (tinywl.c:1075) and removes globals on display destroy (wlr_shm.c:493-499); smithay keeps GlobalId for removal (shm/mod.rs:164) and gets per-resource destruction hooks via `Dispatch2::destroyed` (dispatch2.rs:16-19). Ours only has `wl_display_destroy` (implicit teardown) and hands out raw `*Global` (display.zig:123-135) with no module-level removal helper.
5. **Global visibility filtering not exposed.** zig-wayland has `setGlobalFilter` (zws:94-108) but CompositorDisplay has no wrapper; smithay exposes `GlobalDispatch2::can_view` (dispatch2.rs:31-34). wlroots core uses no filter; relevant only if a compositor needs per-client global masking.
6. **No serial comparison type.** smithay's `Serial` implements wrapping-aware `PartialOrd` (serial.rs:11-29) for serial-age checks; ours and wlroots use raw `u32` from `wl_display_next_serial` (wls:1708-1715). Behaviorally equivalent for well-spaced serials; ours lacks the helper.

## Verdict

High parity on the surface: init/run/terminate/nextSerial/addGlobal are the same libwayland calls wlroots makes, and smithay's crate mirrors the same semantics (Display::new, create_global, SERIAL_COUNTER). The riskiest divergences: (1) wl_shm is libwayland's internal implementation with no renderer format list and no buffer/stride validation — wlroots (wlr_shm.c:553-578) and smithay (shm/mod.rs:143-158) both implement the protocol themselves with renderer formats; (2) event-loop architecture: ours/wlroots run the libwayland loop and dispatch everything (zws:555-563), smithay splits polling (calloop) from `dispatch_clients` (anvil state.rs:657-662), so loop embedding APIs differ (`loopFd` is ours-only); (3) serials are display-owned u32 in ours/wlroots vs smithay's free-standing atomic SerialCounter (serial.rs:77-82) — thread-safety and wrap semantics differ. attachProtocolLogger is ours-only (no wlroots/smithay counterpart). [INFERENCE: wayland-server crate internals (Display::new, create_global, dispatch_clients, insert_client) cited via smithay call sites only; the crate is not vendored locally.]
