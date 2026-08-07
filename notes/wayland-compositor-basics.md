# Wayland Compositor Basics

Reference for writing a Wayland compositor. Terse facts, not prose. Interface versions from `wayland.xml` main branch (2026-08-07). One source per claim.

Sources:
- Wayland Book: https://wayland-book.com (print: https://wayland-book.com/print.html)
- Core protocol XML: https://gitlab.freedesktop.org/wayland/wayland/-/raw/main/protocol/wayland.xml
- Human-readable core reference: https://wayland.app/protocols/wayland
- wlroots (local, fresh): ~/projects/freedesktop-wlroots-wlroots

## 1. Protocol model

- Wire format: stream of 32-bit words, host byte order. Types: `int`/`uint` (32-bit), `fixed` (24.8 signed), `object` (32-bit object ID), `string`, `array`, `fd`, `new_id`.
- Two message kinds: requests (client to server) and events (server to client), both acting on objects. Each object has one interface, which fixes its requests/events and their signatures.
- Object IDs are allocated by the client; server sends `wl_display.delete_id` before a freed ID may be reused.
- `wl_display` (v1): singleton. Requests: `sync` (returns `wl_callback`; server fires `done` after all prior requests handled — the roundtrip/barrier), `get_registry`. Event: `error(object_id, code, message)` — fatal, kills the connection. Global error codes: `invalid_object=0`, `invalid_method=1`, `no_memory=2`, `implementation=3`.
- `wl_registry` (v1): advertises globals via `global(name, interface, version)`; announces removal via `global_remove(name)`. Client binds with `bind(name, new_id<interface>)`. End of initial burst: follow `get_registry` with `sync`. Hotplug = new `global`/`global_remove` events at runtime.
- Roundtrip: client sends requests, then `wl_display.sync`; when the callback fires, every prior request and its resulting events have been processed. Server-side equivalent: `wl_display_roundtrip` (libwayland).
- `wl_callback` (frozen v1): one event `done(callback_data)`. Used for roundtrips and frame scheduling.
- `wl_fixes` (v2): new core interface; fixes for problems that cannot be fixed in the original interfaces (e.g. surface destruction races).

## 2. Core interfaces a compositor implements

- `wl_compositor` (v7): requests `create_surface` → `wl_surface`, `create_region` → `wl_region`, `release` (v7, destructor).
- `wl_region` (v7): rectangle set built with `add(x,y,w,h)` / `subtract(x,y,w,h)`. Consumed by `wl_surface.set_opaque_region` / `set_input_region` (both double-buffered; NULL = empty region).
- `wl_surface` (v7): the atomic state machine. See section 3.
- `wl_shm` (v3): `create_pool(fd, size)` → `wl_shm_pool`; event `format` advertises supported pixel formats (e.g. ARGB8888, XRGB8888). `wl_shm_pool` (v3): `create_buffer(offset, width, height, stride, format)`, `resize(size)` (grow only), `destroy`.
- `wl_buffer` (frozen v1): created by factories (shm, linux-dmabuf). Event `release` = compositor finished reading; client may reuse/destroy. Destructor-only interface.
- `wl_seat` (v11): group of input devices. `get_pointer`/`get_keyboard`/`get_touch`; event `capabilities` (enum: pointer=1, keyboard=2, touch=4), `name` (v2). Client destroys seat objects on capability loss.
- `wl_output` (v4): see section 8.
- `wl_data_device_manager` (v4): `get_data_device(seat)`, `create_data_source`. `wl_data_device` (v4): `start_drag`, `set_selection`, events `offer`, `enter/leave/motion/drop`, `selection`. `wl_data_source` (v4): `offer(mime_type)`, `send`, `cancelled`, `dnd_drop_performed`, `dnd_finished`, `action`. Clipboard and drag-and-drop both flow through the same device; serials must come from a real input event.
- `wl_subcompositor` (v1): `get_subsurface(parent, surface)` → `wl_subsurface` (v1). Requests: `set_position(x,y)`, `place_above`/`place_below`, `set_sync`/`set_desync`. Sub-surface state is cached and applied with the parent's commit. Core protocol's only built-in surface role.
- `wl_shell`/`wl_shell_surface` (v1): legacy desktop role, superseded by xdg-shell.

## 3. wl_surface state machine

- Each surface has pending state and applied state. Requests mutate pending; `wl_surface.commit` applies it atomically — no torn frames. Compositor keeps rendering the last applied state until the commit.
- Atomic state includes: attached buffer (via `attach(buffer, x, y)`), damage region, input region, opaque region, buffer transform, buffer scale, and role-specific state.
- `damage` (legacy, transform-aware) vs `damage_buffer` (preferred, buffer coordinates). Both double-buffered.
- `frame` request: creates `wl_callback`; compositor sends `done` when ready for the next frame. `callback_data` = milliseconds since unspecified epoch. This is the vsync pacing primitive; also fires when a surface is occluded/hidden (at a reduced rate).
- Role: assigned once via a role-interface request (xdg_toplevel, xdg_popup, layer surface, subsurface, cursor surface...). Reassigning a role is a protocol error.
- Mapping: first commit that makes the state valid (buffer + role state present) maps the surface. Unmapping = attach NULL + commit (xdg) or role destroy.
- `set_buffer_scale(factor)`: integer scale of buffer pixels relative to surface coordinates (HiDPI). `set_buffer_transform`: rotation/flip of the buffer.

## 4. xdg-shell lifecycle

- Global `xdg_wm_base` (stable, from wayland-protocols). Requests: `destroy`, `create_positioner`, `get_xdg_surface(surface)`, `ping(serial)`; event `ping` answered with `pong(serial)` (liveness check).
- `xdg_surface`: `get_toplevel`/`get_popup`, `set_window_geometry`, `ack_configure(serial)`, `destroy`.
- Configure/ack handshake: server sends `xdg_toplevel.configure(width, height, states)` (or popup geometry), then `xdg_surface.configure(serial)`. Client renders to match and replies `ack_configure(serial)`. The following `wl_surface.commit` is what the compositor treats as consistent.
- Toplevel events: `configure(w,h,states)`, `close`. State enum: maximized, fullscreen, resizing, activated, tiled_left/right/top/bottom. Width/height 0 = compositor defers to client. `close` may be ignored (e.g. unsaved-work dialog).
- Toplevel requests: `set_title`, `set_app_id`, `set_min_size`/`set_max_size`, `set_maximized`/`unset_maximized`, `set_fullscreen(output?)`/`unset_fullscreen`, `set_minimized`, `move(seat, serial)`, `resize(seat, serial, edges)` — move/resize need a serial from a button press, or the compositor must reject.
- Popups: `xdg_popup` created with an `xdg_positioner` (anchor rect, anchor, gravity, constraint adjustments, reactive). Compositor grabs input while a popup is open (`wlr_xdg_popup_grab` per seat). `popup.done` closes it.
- Initial map: client binds wm_base, gets surface, creates xdg_surface + toplevel, commits. Server sends initial configure; client acks and commits again → mapped.

## 5. Layer-shell

- Global `zwlr_layer_shell_v1` (unstable v1, wayland-protocols). Request `get_layer_surface(surface, output?, layer, namespace)` → `zwlr_layer_surface_v1`.
- Layer enum: `background=0, bottom=1, top=2, overlay=3`. Panels/bars use top; OSD/lockscreens use overlay.
- `zwlr_layer_surface_v1` requests: `set_size`, `set_anchor` (bitmask: top/bottom/left/right), `set_exclusive_zone` (reserves screen space; e.g. 0 for a bar), `set_margin`, `set_keyboard_interactivity`, `ack_configure(serial)`, `set_layer`, `destroy`. Events: `configure(w,h,serial)`, `closed`.
- Layer surfaces must ack the configure before commit; same handshake pattern as xdg. Compositor must apply `exclusive_zone` when laying out work areas (wlroots exposes it in `wlr_layer_surface_v1` state).

## 6. Buffers

- Shared memory (wl_shm): client allocates an fd (memfd), maps it, renders with CPU, sends via `create_pool`. Cheap, no GPU; stride/format negotiated. Reuse via the `release` event; triple-buffering avoids stalls. Only format ever guaranteed: ARGB8888/XRGB8888 (as advertised).
- linux-dmabuf: GPU buffers zero-copied to the compositor. Global `wp_linux_dmabuf_v1` + `wp_linux_buffer_params_v1` (`add` planes, `create`/`create_immed`, `format_table` with modifiers). Compositor imports via its renderer; wlroots: `wlr_linux_dmabuf_v1` + `wlr_buffer`/`wlr_dmabuf` abstraction.
- Lifetime: compositor keeps a buffer reference while scanning out; `release` fires when done. `wl_buffer.release` vs `wl_surface` attach(NULL) semantics must be honored to avoid use-after-free.

## 7. Render loop

1. Client damages and commits surface state.
2. Compositor accumulates damage (wlroots: `wlr_damage_ring`, `wlr_output_damage`).
3. On the next vblank (DRM page-flip event / output frame event), schedule a frame.
4. Composite the scene (wlroots: `wlr_scene`, `wlr_surface` hierarchy with subsurfaces/layer surfaces) into an output buffer (renderer: GLES2/Vulkan in wlroots; pixman for software).
5. Present: KMS atomic commit (wlroots `backend/drm/atomic.c` uses libliftoff for plane assignment) or headless/wayland-backend equivalent.
6. After the flip completes: fire `wl_callback.done` for each committed surface's frame callback, and `wp_presentation_feedback.presented` (tv_sec/tv_nsec, refresh, seq, flags) — the high-resolution timing extension.
- Frame callbacks gate clients: request a callback, render on `done`, never render ahead of vsync.

## 8. Input pipeline

- Kernel evdev nodes → libinput (decodes events) → wlroots libinput backend → `wlr_input_device` (pointer/keyboard/touch/tablet/switch) → `wlr_seat` (seat/ dir: `wlr_seat_pointer.c`, `wlr_seat_keyboard.c`, `wlr_seat_touch.c`).
- Focus: keyboard focus is an explicit surface the compositor picks (click or keyboard navigation); pointer focus is hit-testing — topmost surface under the cursor using input regions, `wlr_scene` hit test, or the compositor's own layout.
- Events carry serials. Serial = input-event sequence number; clients echo it back for privileged requests (xdg move/resize, data device drag, popup grab). Compositor validates serials before honoring.
- Keyboard: send keymap fd + `key` events (scancodes) + `modifiers`; clients run xkbcommon to map to keysyms. Wlroots: `wlr_keyboard`, `wlr_keyboard_group`.
- Pointer: `enter/leave` (surface + surface-local position), `motion`, `button`, `axis` (scroll), `axis_source`/`axis_stop`, batched with `frame` (v5). Touch: `down/up/motion/frame/cancel`, each touch point tracked by id.
- Per-surface hit test inputs: `set_input_region`; opaque region is a compositing optimization only.

## 9. Outputs

- `wl_output` (v4): events `geometry(x, y, physical_size, subpixel, make, model, transform)`, `mode(flags, w, h, refresh)` (flags: current=1, preferred=2), `scale` (integer DPR), `done`, `name`, `description` (v4).
- Modes: enumerate via DRM/KMS; preferred mode is the panel's native. Custom modes possible (KMS mode object). wlroots: `wlr_output_mode`, `wlr_output_state` (mode, scale, transform, position, enabled).
- Atomic KMS: one atomic commit sets mode, CRTC, planes, properties (vrr, etc). Legacy KMS = separate setcrtc calls (wlroots `backend/drm/legacy.c`); atomic path in `backend/drm/atomic.c`.
- Multi-output: compositor assigns each output a position in one global coordinate space (wlroots: `wlr_output_layout`); surfaces/cursors live in that space; outputs are regions of it.
- DPR: `wl_output.scale` is an integer (1x/2x). Fractional: `wp_fractional_scale_manager_v1` → `wp_fractional_scale_v1.preferred_scale(scale)` where scale = value/120 (e.g. 150 → 1.25x).
- viewporter: `wp_viewporter` global → `wp_viewport` (`set_source` crop, `set_destination` scale) lets clients render at a different resolution than the surface size. Needed for fractional scaling of wl_surface content.

## 10. Testing

- wlroots headless backend (`backend/headless/`): outputs with no real display, driven by the renderer; pairs with the wayland backend for nested testing.
- `WLR_BACKENDS=headless` + `WLR_RENDERER=pixman` gives a deterministic, unprivileged test environment; X11/wayland backends for nested runs.
- weston test harness: weston's tests/ use a test client plus the `weston-test` protocol extension and `weston-test-runner` to script compositor behavior under test. [UNVERIFIED — not read this session]
- In-tree test protocol `weston-test`: lets tests drive input, screenshot outputs, and force frames. [UNVERIFIED]

## 11. Key references

- Core protocol: https://gitlab.freedesktop.org/wayland/wayland/-/raw/main/protocol/wayland.xml
- All protocols, browsable: https://wayland.app/protocols/ (e.g. /protocols/xdg-shell, /protocols/wlr-layer-shell-unstable-v1, /protocols/linux-dmabuf-v1, /protocols/fractional-scale-v1, /protocols/viewporter, /protocols/presentation-time)
- wayland-protocols repo: https://gitlab.freedesktop.org/wayland/wayland-protocols
- Wayland Book: https://wayland-book.com
- wlroots: https://gitlab.freedesktop.org/wlroots/wlroots (local mirror: ~/projects/freedesktop-wlroots-wlroots)
- libinput: https://gitlab.freedesktop.org/libinput/libinput
- Wayland docs (server-side howto): https://wayland.freedesktop.org/docs/html/
