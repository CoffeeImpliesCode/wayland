# Wayland Compositor Basics

Reference for writing a Wayland compositor. Terse facts, not prose. Interface versions verified against `wayland.xml` main branch (fetched 2026-08-07). One source per claim; unverifiable facts are marked `[UNVERIFIED]`.

Sources:
- Wayland Book: https://wayland-book.com (print: https://wayland-book.com/print.html)
- Core protocol XML: https://gitlab.freedesktop.org/wayland/wayland/-/raw/main/protocol/wayland.xml (fetched this session; 3442 lines)
- Human-readable core reference: https://wayland.app/protocols/wayland
- wayland-protocols XMLs (fetched this session): stable/xdg-shell, stable/linux-dmabuf (promoted from staging), stable/presentation-time, staging/fractional-scale
- wlroots local clone: ~/projects/freedesktop-wlroots-wlroots (refreshed to tag 0.20.2, the current stable, 2026-08-07; master is 0.21.0-dev). Sibling notes' "wlroots 0.20" claims match: river pins zig-wlroots v0.20.1 ↔ wlroots 0.20, which exists; 0.20.2 is the newest tag)
- weston repo (fetched this session): README.md, tests/meson.build, tests/harness/, protocol/weston-test.xml, tests/internal-screenshot-test.c

## 1. Protocol model

- Wire format: stream of 32-bit words, host byte order. Types: `int`/`uint` (32-bit), `fixed` (24.8 signed), `object` (32-bit object ID), `string`, `array`, `fd`, `new_id`.
- Two message kinds: requests (client to server) and events (server to client), both acting on objects. Each object has one interface, which fixes its requests/events and their signatures.
- Object IDs are allocated by the client; server sends `wl_display.delete_id` before a freed ID may be reused.
- `wl_display` (v1): singleton. Requests: `sync` (returns `wl_callback`; server fires `done` after all prior requests handled — the roundtrip/barrier), `get_registry`. Event: `error(object_id, code, message)` — fatal, kills the connection. Global error codes: `invalid_object=0`, `invalid_method=1`, `no_memory=2`, `implementation=3`.
- `wl_registry` (v1): advertises globals via `global(name, interface, version)`; announces removal via `global_remove(name)`. Client binds with `bind(name, new_id<interface>)`. End of initial burst: follow `get_registry` with `sync`. Hotplug = new `global`/`global_remove` events at runtime.
- Roundtrip: client sends requests, then `wl_display.sync`; when the callback fires, every prior request and its resulting events have been processed. Server-side equivalent: `wl_display_roundtrip` (libwayland).
- `wl_callback` (frozen v1): one event `done(callback_data)`. Used for roundtrips and frame scheduling.
- `wl_fixes` (v2, new core interface): fixes problems that cannot be fixed in the original interfaces. Requests: `destroy_registry` (cleanly destroy a wl_registry, v1), `ack_global_remove(registry, name)` (since 2) — the client acks a `wl_registry.global_remove`; once all clients acked, the compositor may destroy the wl_global without racing a late `bind` (binding a removed global is a protocol error). Error: `invalid_ack_remove=0` (unknown global or not removed). Not about surface destruction.

## 2. Core interfaces a compositor implements

- `wl_compositor` (v7): requests `create_surface` → `wl_surface`, `create_region` → `wl_region`, `release` (v7, destructor).
- `wl_region` (v7): rectangle set built with `add(x,y,w,h)` / `subtract(x,y,w,h)`. Consumed by `wl_surface.set_opaque_region` / `set_input_region` (both double-buffered; NULL = empty region for opaque, infinite for input).
- `wl_surface` (v7): the atomic state machine. See section 3.
- `wl_shm` (v3): `create_pool(fd, size)` → `wl_shm_pool`; event `format` advertises supported pixel formats (e.g. ARGB8888, XRGB8888). "All renderers should support argb8888 and xrgb8888 but any other formats are optional" (wayland.xml). Errors (since 3): `invalid_stride=1`, `invalid_fd=2`. `wl_shm_pool` (v3): `create_buffer(offset, width, height, stride, format)`, `resize(size)` (grow only), `destroy`.
- `wl_buffer` (frozen v1): created by factories (shm, linux-dmabuf). Event `release` = compositor finished reading; client may reuse/destroy. Destructor-only interface. See section 6 for lifecycle.
- `wl_seat` (v11): group of input devices. `get_pointer`/`get_keyboard`/`get_touch`; event `capabilities` (enum: pointer=1, keyboard=2, touch=4), `name` (v2). `release` destructor since 5. Error: `missing_capability=0`. Client destroys seat objects on capability loss.
- `wl_output` (v4): see section 9.
- `wl_data_device_manager` (v4): `get_data_device(seat)`, `create_data_source`. `wl_data_device` (v4): `start_drag`, `set_selection`, events `offer`, `enter/leave/motion/drop`, `selection`. `wl_data_source` (v4): `offer(mime_type)`, `send`, `cancelled`, `dnd_drop_performed`, `dnd_finished`, `action`. Clipboard and drag-and-drop both flow through the same device; serials must come from a real input event.
- `wl_subcompositor` (v1): `get_subsurface(parent, surface)` → `wl_subsurface` (v1). Core protocol's only built-in surface role. See section 4.5.
- `wl_shell`/`wl_shell_surface` (v1): legacy desktop role, superseded by xdg-shell.

## 3. wl_surface state machine

- Each surface has pending state and applied state. Requests mutate pending; `wl_surface.commit` applies it atomically — no torn frames. Compositor keeps rendering the last applied state until the commit.
- Commit builds a Content Update (CU) from the pending state and queues it; CUs apply atomically in dependency order. A CU is Sync (SCU) or Desync (DCU) depending on the surface's effective sync mode (see 4.5). When applied, the wl_buffer is applied before all other state, so double-buffered coordinates are relative to the new buffer.
- Atomic state includes: attached buffer (via `attach(buffer, x, y)`), damage region, input region, opaque region, buffer transform (since 2), buffer scale (since 3), and role-specific state. `offset(x,y)` (since 5) replaces the attach x/y args; non-zero attach x/y is an `invalid_offset` error at version ≥5.
- `damage` (v1, surface-local; "new clients should not use this request" per wayland.xml) vs `damage_buffer` (v4, buffer-local, preferred). Both double-buffered. Damage from the two requests must be accumulated separately — the surface↔buffer mapping is only known at commit time (transform/scale requests may interleave).
- `frame` request: creates `wl_callback`; compositor sends `done` when it is a good time to draw. `callback_data` = "current time, in milliseconds, with an undefined base". The server must pace so clients do not draw too often and should avoid firing for invisible surfaces (off-screen or fully occluded by opaque surfaces). The callback object is destroyed after firing; the notification is one-shot per request.
- Errors: `invalid_scale=0`, `invalid_transform=1`, `invalid_size=2`, `invalid_offset=3`, `defunct_role_object=4` (surface destroyed before its role object), `no_buffer=5` (e.g. `get_release` without a non-NULL attach).
- Role: assigned once via a role-interface request (xdg_toplevel, xdg_popup, layer surface, subsurface, cursor surface...). Reassigning a role is a protocol error. Destroying the role object does not remove the role but may unmap the surface.
- Mapping: first commit that makes the state valid (buffer + role state present) maps the surface. Unmapping = attach NULL + commit (xdg) or role destroy.
- `set_buffer_scale(factor)`: integer scale of buffer pixels relative to surface coordinates (HiDPI). At commit, buffer size must be an integer multiple of the scale, else `invalid_size`. `set_buffer_transform`: rotation/flip of the buffer (values of `wl_output.transform`).
- `preferred_buffer_scale`/`preferred_buffer_transform` (since 6): hints for the client before it commits.

## 4. xdg-shell lifecycle

- Global `xdg_wm_base` (stable v7, wayland-protocols). Requests: `destroy`, `create_positioner`, `get_xdg_surface(surface)`, `ping(serial)`; event `ping` answered with `pong(serial)` (liveness check).
- `xdg_surface`: `get_toplevel`/`get_popup`, `set_window_geometry`, `ack_configure(serial)`, `destroy`. A role must be assigned before any other request; creating an xdg_surface from a surface with a committed buffer is an error.
- Configure/ack handshake: server sends `xdg_toplevel.configure(width, height, states)` (or popup geometry), then `xdg_surface.configure(serial)`. Client renders to match and replies `ack_configure(serial)`; the following `wl_surface.commit` is what the compositor treats as consistent. Errors: `not_constructed=1` (request before role assigned / before initial configure acked), `already_constructed=2`, `unconfigured_buffer=3` (attaching a buffer to an unconfigured surface), `invalid_serial=4`, `invalid_size=5`, `defunct_role_object=6`.
- Initial map: client binds wm_base, creates xdg_surface + toplevel, performs the FIRST commit with no buffer attached. Server replies with initial state (e.g. `preferred_buffer_scale`) then `xdg_surface.configure`. Client acks and may now attach a buffer and commit → mapped.
- Toplevel events: `configure(w,h,states)`, `close`. State enum: maximized, fullscreen, resizing, activated, tiled_left/right/top/bottom. Width/height 0 = compositor defers to client. `close` may be ignored (e.g. unsaved-work dialog).
- Toplevel requests: `set_title`, `set_app_id`, `set_min_size`/`set_max_size`, `set_maximized`/`unset_maximized`, `set_fullscreen(output?)`/`unset_fullscreen`, `set_minimized`, `move(seat, serial)`, `resize(seat, serial, edges)` — move/resize need a serial from a button press, or the compositor must reject.
- Popups: `xdg_popup` created with an `xdg_positioner` (anchor rect, anchor, gravity, constraint adjustments, reactive). New popups stack above all previous popups of the same toplevel; parent must be mapped first.
- Popup grab: `xdg_popup.grab(seat, serial)` (v1) takes an EXPLICIT grab, must follow a user action (button/key/touch serial). If the compositor denies the grab, the popup is dismissed immediately. During the grab the owning client receives pointer/touch for all its surfaces ("owner-events", X11 parlance) and the topmost grabbing popup always has keyboard focus. Nested grabbing popups must be destroyed in reverse order; destroying the topmost returns the grab to its parent. Errors: `invalid_grab=0` (grab after the popup was mapped), `not_the_topmost_popup` (xdg_wm_base, destroying a non-topmost popup). `popup_done` event closes the popup; `reposition`/`repositioned` since 3.
- Compositor side (wlroots): `wlr_xdg_popup_grab` per seat with pointer/keyboard/touch grabs (`wlr_xdg_shell.h`), tracked in the shell's `popup_grabs` list.

## 4.5 Subsurfaces (wl_subcompositor)

- `wl_subsurface` (v1): one parent; size/position NOT clipped to the parent. Requests: `set_position(x,y)` (relative to parent, negative allowed, initial 0,0), `place_above`/`place_below(sibling)` (sibling must be a sibling surface or the parent — else `bad_surface=0` error; new subsurface starts topmost), `set_sync`/`set_desync`, `destroy`.
- Position and z-order are double-buffered state ON THE PARENT: cached by the subsurface and applied at the PARENT's commit (wlr_subsurface.parent_state; wlr_subcompositor.h: "applied on parent surface commit"). The subsurface's own commit applies its buffer/damage.
- Sync/desync: initially synchronized. `set_sync` = commits are cached and applied with the parent (SCU); `set_desync` = commits apply immediately (DCU). Effective sync is recursive: a desync subsurface under an effectively-synchronized parent behaves synchronized. The main surface is always effectively desynchronized.
- Mapped when a non-NULL buffer is applied AND the parent is mapped (either order). Hidden when the parent hides or a NULL buffer is applied. Destroying the wl_subsurface unmaps the surface immediately (to sync removal, unmap first via attach NULL, then destroy). A subsurface never has keyboard focus.

## 5. Layer-shell

- Global `zwlr_layer_shell_v1` (unstable v1, wayland-protocols). Request `get_layer_surface(surface, output?, layer, namespace)` → `zwlr_layer_surface_v1`.
- Layer enum: `background=0, bottom=1, top=2, overlay=3`. Panels/bars use top; OSD/lockscreens use overlay.
- `zwlr_layer_surface_v1` requests: `set_size`, `set_anchor` (bitmask: top/bottom/left/right), `set_exclusive_zone` (reserves screen space; e.g. 0 for a bar), `set_margin`, `set_keyboard_interactivity`, `ack_configure(serial)`, `set_layer`, `destroy`. Events: `configure(w,h,serial)`, `closed`.
- Layer surfaces must ack the configure before commit; same handshake pattern as xdg. Compositor must apply `exclusive_zone` when laying out work areas (wlroots exposes it in `wlr_layer_surface_v1` state).

## 6. Buffers

- Shared memory (wl_shm): client allocates an fd (memfd), maps it, renders with CPU, sends via `create_pool`. Cheap, no GPU; stride/format negotiated. Only formats any renderer must support: ARGB8888/XRGB8888 (as advertised).
- linux-dmabuf: GPU buffers zero-copied to the compositor. Globals (stable since its promotion; interfaces at v6): `zwp_linux_dmabuf_v1` (not `wp_`), `zwp_linux_buffer_params_v1`, `zwp_linux_dmabuf_feedback_v1`.
- dmabuf fd lifecycle: client adds planes with `zwp_linux_buffer_params_v1.add(fd, plane_idx, offset, stride, modifier_hi, modifier_lo)` (modifier = DRM tiling/compression token; since v4 the format+modifier must be advertised in feedback, else `invalid_format`; since v5 all planes must share one modifier). Then `create(w, h, format, flags)` is ASYNC: the buffer arrives later via `created(buffer)` or `failed` (non-fatal import error — client may fall back). After create only `destroy` is legal (`already_used` error). `create_immed` (since 2) is synchronous: success = no event, failure = fatal protocol error or an invalid buffer + `failed`. Errors: `already_used=0, plane_idx=1, plane_set=2, incomplete=3, invalid_format=4, invalid_dimensions=5, out_of_bounds=6, invalid_wl_buffer=7, invalid_dev_t_size=8`. `wl_drm` (legacy Mesa protocol, raw DRM fds) is superseded by this.
- Buffer release lifecycle (wl_surface.attach docs, wayland.xml): the compositor may read the attached buffer any time after commit and sends `wl_buffer.release` when it will not access it again; only then may the client reuse it. A buffer attached and REPLACED by another attach without an intervening commit is never released (compositor never used it). A buffer committed to more than one surface has undefined release delivery — use `wl_surface.get_release` (v7; wl_callback-style per-commit release, `done` data always 0, `no_buffer` error if no non-NULL attach) or a per-commit extension. Destroying the buffer before release is safe only if the backing storage is not reused; `attach(NULL)` + commit removes surface content.
- Pooling: client keeps 2-3 buffers in flight (triple-buffering avoids stalls). Fast path: if `release` arrives BEFORE the frame callback of the same commit, the client may reuse the buffer immediately — this happens when the compositor keeps a copy (e.g. GL texture of a wl_shm buffer).
- Damage vs buffer damage: `wl_surface.damage` is surface-local, `damage_buffer` is buffer-local. Accumulate separately; transform only after commit. wlroots: `wlr_surface_state.surface_damage`/`buffer_damage`, `wlr_surface_get_effective_damage`, `wlr_damage_ring` for output-side accumulation.
- dmabuf feedback (one paragraph): `zwp_linux_dmabuf_feedback_v1` tells the client which formats/modifiers and which device to allocate on. `format_table(fd, size)` gives a read-only mmap of 16-byte entries (u32 fourcc, 4 pad bytes, u64 modifier). Then preference tranches: `tranche_target_device(dev_t)` + `tranche_formats` (u16 indices into the table) + `tranche_flags` (`scanout=1` since 4 — direct scan-out possible; `sampling=2` since 6) closed by `tranche_done`, whole batch closed by `done` (atomic view). `main_device` is deprecated since 6 (use sampling-flagged tranches). wlroots: `wlr_linux_dmabuf_v1_create_with_renderer` builds default feedback from the renderer, `wlr_linux_dmabuf_feedback_add_tranche` (decreasing priority), `wlr_linux_dmabuf_v1_set_surface_feedback` per surface.
- Compositor keeps a buffer reference while scanning out (wlroots: `wlr_buffer` refcount via `wlr_buffer_lock`/`unlock`/`drop`; `wlr_dmabuf_v1_buffer`), then sends release.

## 7. Render loop

1. Client damages and commits surface state.
2. Compositor accumulates damage (wlroots: `wlr_damage_ring`, `wlr_output_damage`).
3. On the next vblank (DRM page-flip event / output frame event), schedule a frame (`wlr_output_schedule_frame`).
4. Composite the scene (wlroots: `wlr_scene`, `wlr_surface` hierarchy with subsurfaces/layer surfaces) into an output buffer (renderer: GLES2/Vulkan in wlroots; pixman for software).
5. Present: KMS atomic commit (wlroots `backend/drm/atomic.c` — `DRM_MODE_ATOMIC_*` flags, libliftoff plane assignment) or headless/wayland-backend equivalent.
6. After the flip completes: fire `wl_callback.done` for each committed surface's frame callback, and `wp_presentation_feedback.presented` — the high-resolution timing extension.
- Frame callbacks gate clients: request a callback, render on `done`, never render ahead of vsync.

### Frame timing

- `wl_callback.done`: one-shot pacing signal; data = milliseconds, undefined base. The compositor decides WHEN to fire (its job: only it knows vblank, occlusions, and output state). A client that commits without waiting wastes draws that never reach the display.
- presentation-time (`wp_presentation` v2, stable): `feedback` request associates a `wp_presentation_feedback` object with the NEXT commit. `clock_id` event names the presentation clock (a POSIX `clockid_t`; should not jump/slew). Outcome is exactly one of two destructor events:
  - `presented(tv_sec_hi, tv_sec_lo, tv_nsec, refresh, seq_hi, seq_lo, flags)`: time the update turned into light (first scan-out on the main output; preceded by `sync_output`). `refresh` = ns until the next refresh (0 if unknown/not constant). `seq` = vertical-retrace counter, GLX_OML_sync_control MSC-compatible (0 if the output has no retrace concept). Flags (`kind`): `vsync=0x1` (hardware-synced, no tearing), `hw_clock=0x2` (hardware-provided timestamp), `hw_completion=0x4` (hardware signalled the switch), `zero_copy=0x8` (direct scanout/hardware overlay — GL compositing counts as copying).
  - `discarded`: the update was never displayed (superseded or surface destroyed).
- wlroots: `wlr_presentation_create(display, backend)`; surfaces marked sampled/textured/scanned-out per output; `wlr_output_event_present` carries when/seq/refresh/flags, filled from the backend's flip event.

### EGL/GBM/KMS pipeline

GBM (Mesa's buffer-allocation API) produces dmabufs from the GPU; the renderer imports them as textures (wlroots: gles2/vulkan renderers, `render/allocator/gbm.c`). EGLStreams (NVIDIA's vendor scan-out/import path) is absent from wlroots — no eglstream code in the 0.20.2 tree — so the GBM/dmabuf path is the supported one. The compositor takes DRM master on the seat via the session (libseat; wlroots checks `drmIsMaster`/`drmDropMaster`), because only the master may commit KMS state. A frame is one atomic commit (`DRM_MODE_ATOMIC_ALLOW_MODESET` for mode changes, else plane/property updates) with `DRM_MODE_PAGE_FLIP_EVENT` to get the flip-completion callback that drives frame events and presentation feedback. Only damaged regions are re-rendered and re-uploaded (damage buffers), keeping the flip cheap.

## 8. Input pipeline

- Kernel evdev nodes → libinput (decodes events) → wlroots libinput backend → `wlr_input_device` (pointer/keyboard/touch/tablet/switch) → `wlr_seat` (seat/ dir: `wlr_seat_pointer.c`, `wlr_seat_keyboard.c`, `wlr_seat_touch.c`).
- Focus: keyboard focus is an explicit surface the compositor picks (click or keyboard navigation); pointer focus is hit-testing — topmost surface under the cursor using input regions, `wlr_scene` hit test, or the compositor's own layout.
- Events carry serials. Serial = input-event sequence number; clients echo it back for privileged requests (xdg move/resize, data device drag, popup grab). Compositor validates serials before honoring.
- Keyboard: send keymap fd + `key` events (scancodes) + `modifiers`; clients run xkbcommon to map to keysyms. Wlroots: `wlr_keyboard`, `wlr_keyboard_group`.
- Pointer: `enter/leave` (surface + surface-local position), `motion`, `button`, `axis` (scroll), `axis_source`/`axis_stop`, batched with `frame` (v5). Touch: `down/up/motion/frame/cancel`, each touch point tracked by id.
- Per-surface hit test inputs: `set_input_region` (default: infinite); opaque region is a compositing optimization only.

## 9. Outputs

- `wl_output` (v4): events `geometry(x, y, physical_size, subpixel, make, model, transform)` (v1), `mode(flags, w, h, refresh)` (v1; flags: current=1, preferred=2), `scale` (v2, integer DPR), `done` (v2), `name`, `description` (v4). `release` destructor since 3.
- Modes: enumerate via DRM/KMS; preferred mode is the panel's native. Custom modes possible (KMS mode object). wlroots: `wlr_output_mode`, `wlr_output_state` (mode, scale, transform, position, enabled).
- Atomic KMS: one atomic commit sets mode, CRTC, planes, properties (vrr, etc). Legacy KMS = separate setcrtc calls (wlroots `backend/drm/legacy.c`); atomic path in `backend/drm/atomic.c`.
- Multi-output: compositor assigns each output a position in one global coordinate space (wlroots: `wlr_output_layout`); surfaces/cursors live in that space; outputs are regions of it.
- DPR: `wl_output.scale` is an integer (1x/2x). Fractional: `wp_fractional_scale_manager_v1` → `wp_fractional_scale_v1.preferred_scale(scale)` (v1 event; "the numerator of a fraction with a denominator of 120" — e.g. 150 → 1.25x). Semantics: buffer size = surface size × scale; the client renders at the fractional scale and submits through `wp_viewport` with destination = surface size, while `wl_surface.set_buffer_scale` stays 1. Toplevel sizes round halfway away from zero; subsurface rounding is undefined.
- viewporter: `wp_viewporter` global → `wp_viewport` (`set_source` crop, `set_destination` scale) lets clients render at a different resolution than the surface size. Needed for fractional scaling of wl_surface content.

## 10. Testing

- wlroots headless backend (`backend/headless/`): outputs with no real display, driven by the renderer; pairs with the wayland backend for nested testing. `WLR_BACKENDS=headless` + `WLR_RENDERER=pixman` gives a deterministic, unprivileged test environment (wlroots docs/env_vars.md).
- weston test harness (verified from weston main, 2026-08-07): tests live in `tests/`, one meson executable per test, run via `meson test` with TAP output and a 120 s timeout (tests/meson.build). The harness in `tests/harness/` runs each test inside a real compositor (`weston-test-fixture-compositor.c` calls `wet_main`, i.e. weston's own main); `weston-test-runner.c` drives the test cases, assertions via `weston-test-assert.h`.
- In-tree test protocol `weston-test` (protocol/weston-test.xml): `weston_test` interface lets a test client inject input and move state — `move_pointer`, `send_button`, `send_axis`, `send_key`, `send_touch`, `move_surface`, `activate_surface`, `device_add`/`device_release`, `client_break`; event `pointer_position`. A separate `weston_test_runner` interface (`run` request, `finished` event) drives test execution. Note: weston's README links test docs at wayland.freedesktop.org/testing.html, which 404s — the repo itself is the source.
- Screenshot tests use the output-capture protocol (`weston_capture_source_v1`, in-tree `weston_output_capture_protocol`): `capture_screenshot_of_output` helper grabs the output, and results are compared against reference PNGs (tests/internal-screenshot-test.c, `check_images_match`).

## 11. Key references

- Core protocol: https://gitlab.freedesktop.org/wayland/wayland/-/raw/main/protocol/wayland.xml
- All protocols, browsable: https://wayland.app/protocols/ (e.g. /protocols/xdg-shell, /protocols/wlr-layer-shell-unstable-v1, /protocols/linux-dmabuf-v1, /protocols/fractional-scale-v1, /protocols/viewporter, /protocols/presentation-time)
- wayland-protocols repo: https://gitlab.freedesktop.org/wayland/wayland-protocols
- Wayland Book: https://wayland-book.com
- wlroots: https://gitlab.freedesktop.org/wlroots/wlroots (local mirror: ~/projects/freedesktop-wlroots-wlroots, 0.20.2)
- weston: https://gitlab.freedesktop.org/wayland/weston (tests/, protocol/weston-test.xml)
- libinput: https://gitlab.freedesktop.org/libinput/libinput
- Wayland docs (server-side howto): https://wayland.freedesktop.org/docs/html/
