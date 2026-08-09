# Libinput backend — FFI audit + wlroots/smithay diff

Scope: `src/backend/libinput.zig` (618 lines, evdev/udev input backend) and `scripts/uinput-devices.py` (VM test devices). libinput 1.31.3 header verified at `/nix/store/25z81mr9anpamdwv7lizq5l56hhq6kmi-libinput-1.31.3-dev/include/libinput.h` (cited as libinput.h:N). wlroots 0.20.2: `backend/libinput/backend.c`, `backend/libinput/events.c`, `backend/libinput/keyboard.c`, `backend/libinput/pointer.c`, `backend/libinput/touch.c`, `types/wlr_keyboard.c`, `include/wlr/backend.h`. smithay 0.7.0: the libinput backend is ONE file, `src/backend/libinput/mod.rs` (892 lines) + `tablet.rs` — there is NO keyboard.rs/pointer.rs/touch.rs in the clone (verified by directory listing); all device handling is trait impls in mod.rs. Supporting: `src/backend/backend.zig` (new_input signal), `src/compositor/seat.zig` (seat contracts), `src/server/main.zig` (wiring), `scripts/vm-drm-e2e.sh` + `scripts/vm.nix` (VM harness).

## Surface

Public inventory (file:line relative to repo roots):

`src/backend/libinput.zig`:
- `LibinputBackend.create` (libinput.zig:518) — allocate impl, `Backend.init`, defer context creation to start()
- `LibinputBackend.fromBackend` (libinput.zig:551) — recover impl from Backend data
- `Libinput.pollFd` (libinput.zig:301) — `libinput_get_fd` wrapper
- `Libinput.dispatch` (libinput.zig:309) — `libinput_dispatch` + drain queue
- `evdevToXkb` (libinput.zig:214) — evdev scancode + 8
- `scaleToOutput` (libinput.zig:221) — normalized 0..1 -> pixel
- `axisValueToPixels` (libinput.zig:228) — degrees -> seat pixels (15.0 -> 10.0)
- `axisDiscreteToNotches` (libinput.zig:233) — discrete f64 -> i32 round
- `kindForDevice` (libinput.zig:242) — keyboard > pointer > touch priority
- `eventTypeName` (libinput.zig:~250) — debug names
- `openRestricted`/`closeRestricted` (libinput.zig:440, 460) — raw open/close, ignores passed flags
- `start` (libinput.zig:470) — udev_new, create context, assign seat, initial drain
- `destroy` (libinput.zig:506) — free names, deinit registry, unref ctx/udev
- 8 unit tests (libinput.zig:557+) — offsets, scaling, axis conversion, capability/event constants

Private event handlers (all `Libinput` methods): `onDeviceAdded` (342), `onDeviceRemoved` (363), `onKey` (375), `onPointerMotion` (383), `onPointerMotionAbsolute` (393), `onPointerButton` (407), `onPointerAxis` (415), `handleEvent` dispatch switch (318).

`scripts/uinput-devices.py` (137 lines): `make_keyboard` (keyboard, EV_KEY letters + esc/enter/space/tab/backspace/arrows), `make_mouse` (EV_KEY buttons + EV_ABS ABS_X/ABS_Y 0..0xFFFF + EV_REL REL_WHEEL), commands key/mousemove/click/scroll, `finally` closes both UInput handles.

## FFI audit (libinput.h: every extern fn)

The `const c = struct {...}` block is libinput.zig:137-202. Recent bug fixed: `libinput_device_has_capability` now takes TWO args (libinput.zig:196) matching `int libinput_device_has_capability(struct libinput_device *, enum libinput_device_capability)` (libinput.h:4490-4492). The one-arg version read the capability enum as the return address, produced garbage on x86-64, and misclassified every device; the fix is correct.

| extern (libinput.zig:line) | libinput.h signature | verdict |
|---|---|---|
| `libinput_udev_create_context` (:154) | `struct libinput *libinput_udev_create_context(const struct libinput_interface *, void *, struct udev *)` (3653-3656) | pass |
| `libinput_udev_assign_seat` (:159) | `int ...(struct libinput *, const char *seat_id)`; 0 on success, -1 on failure (3679-3680) | pass |
| `libinput_path_create_context` (:160) | `struct libinput *...(const struct libinput_interface *, void *)` (3701-3703) | pass, unused |
| `libinput_path_add_device` (:161) | `struct libinput_device *...(struct libinput *, const char *path)` (3725-3726) | pass, unused |
| `libinput_get_fd` (:162) | `int libinput_get_fd(struct libinput *)` (3849-3850) | pass |
| `libinput_dispatch` (:163) | `int ...(struct libinput *)`; 0 on success, negative errno on failure (3869-3870) | pass |
| `libinput_get_event` (:167) | `struct libinput_event *...(struct libinput *)`; NULL if no event available (3883-3884) | pass |
| `libinput_event_destroy` (:168) | `void ...(struct libinput_event *)` (1061-1062) | pass |
| `libinput_unref` (:169) | `struct libinput *...(struct libinput *)` (3996-3997) | pass |
| `libinput_event_get_type` (:172) | `enum libinput_event_type ...(struct libinput_event *)` (1071-1072); enum is int-sized | pass |
| `libinput_event_get_device` (:173) | `struct libinput_device *...(struct libinput_event *)` (1098-1099) | pass |
| `libinput_event_get_keyboard_event` (:174) | `struct libinput_event_keyboard *...(struct libinput_event *)` (1124-1125) | pass |
| `libinput_event_get_pointer_event` (:175) | `struct libinput_event_pointer *...(struct libinput_event *)` (1111-1112) | pass |
| `libinput_event_keyboard_get_key` (:178) | `uint32_t ...(struct libinput_event_keyboard *)` (1259-1260) | pass |
| `libinput_event_keyboard_get_key_state` (:179) | `enum libinput_key_state ...(struct libinput_event_keyboard *)` (1267-1268) | pass |
| `libinput_event_pointer_get_dx` / `get_dy` (:182-183) | `double ...(struct libinput_event_pointer *)` (1340-1342, 1361-1362) | pass |
| `..._get_absolute_x_transformed` (:184) | `double ...(struct libinput_event_pointer *, uint32_t width)` (1465-1468) | pass |
| `..._get_absolute_y_transformed` (:185) | `double ...(struct libinput_event_pointer *, uint32_t height)` (1486-1489) | pass |
| `libinput_event_pointer_get_button` (:186) | `uint32_t ...(struct libinput_event_pointer *)` (1502-1503) | pass |
| `libinput_event_pointer_get_button_state` (:187) | `enum libinput_button_state ...(struct libinput_event_pointer *)` (1517-1518) | pass |
| `libinput_event_pointer_has_axis` (:188) | `int ...(struct libinput_event_pointer *, enum libinput_pointer_axis)` (1558-1560) | pass |
| `libinput_event_pointer_get_axis_value` (:189) | `double ...(struct libinput_event_pointer *, enum libinput_pointer_axis)` (1586-1589) | pass |
| `libinput_event_pointer_get_axis_value_discrete` (:190) | `double ...(struct libinput_event_pointer *, enum libinput_pointer_axis)` (1664-1667) | pass |
| `libinput_event_pointer_get_axis_source` (:191) | `enum libinput_pointer_axis_source ...(struct libinput_event_pointer *)` (1636-1637) | pass, UNUSED (see Gaps 2) |
| `libinput_device_get_name` (:194) | `const char *...(struct libinput_device *)` (4337-4338); may be empty, never NULL | pass |
| `libinput_device_get_seat` (:195) | `struct libinput_seat *...(struct libinput_device *)` (4417-4418) | pass, unused |
| `libinput_device_has_capability` (:196) | `int ...(struct libinput_device *, enum libinput_device_capability)` (4490-4492) | pass (the fix) |
| `udev_new` / `udev_unref` (:200-201) | standard libudev API: `struct udev *udev_new(void)`, `struct udev *udev_unref(struct udev *)` [VERIFIED 2026-08-09 against the vendored systemd source: libudev.h:23 declares `udev_new`; udev_unref semantics at src/libudev/libudev.c:89-105 — drops a ref, returns NULL when the count reaches zero] | pass |

`libinput_interface` struct (libinput.zig:144-151) matches libinput.h:3617-3637 exactly: `int (*open_restricted)(const char *, int flags, void *)` and `void (*close_restricted)(int, void *)`; libinput's contract: return fd or negative errno (libinput.h:3619-3628). `openRestricted` (libinput.zig:440) returns `-errno` on failure and always opens `O_RDWR|O_NONBLOCK|O_CLOEXEC|O_NOCTTY`, ignoring the passed flags — correct for evdev nodes; wlroots routes the open through the session (`wlr_session_open_file`, backend.c:18-23), smithay passes the flags through to its session (mod.rs:688-691).

Enum constants (libinput.zig:91-120) all match: device caps 0/1/2 (libinput.h:206-214), key/button state 0/1 (222-225, 246-249), pointer axis 0/1 (263-266), axis source WHEEL=1 (280-304), event types NONE=0, DEVICE_ADDED=1, DEVICE_REMOVED=2, KEYBOARD_KEY=300, POINTER_MOTION=400..SCROLL_CONTINUOUS=406 (775-871). The 1.31.3 enum jumps 406 -> TOUCH_DOWN=500 (871-874); there is NO `SCROLL_BUTTON` event in this header version (button scrolling surfaces as source CONTINUOUS on POINTER_AXIS, libinput.h:859-865).

Result: 30/30 extern decls correct, all arg counts and types match. No FFI bug remains.

## Comparison

### Context lifecycle (udev create + seat assign)
- ours: `start` — `udev_new` (474), `libinput_udev_create_context` (482), `libinput_udev_assign_seat(seat_name)` (489), errdefers unref ctx then udev; `destroy` unrefs ctx then udev (506-513). Pairing 1:1; ctx-before-udev order is safe.
- wlroots: same calls in `backend_start` (backend.c:90-100); passes its session's udev, never creates one; no udev ref juggling.
- smithay: the backend receives an already-built `libinput::Libinput` context in `new` (mod.rs:39); udev creation is the caller's job.
- verdict: close. Ours owns its udev (correct for a VM without a session); the errdefer chain cleans both on every failure path.

### Initial device drain
- ours: `dispatch()` at the end of `start` (libinput.zig:497-504) drains the DEVICE_ADDED burst; the module doc demands the compositor attach its `new_input` listener before `start` (libinput.zig:27-30; main.zig:343 wires the listener before the backend starts).
- wlroots: `handle_libinput_readable(fd, ...)` called directly from `backend_start` (backend.c:109).
- smithay: no drain; the first `process_events` delivers DEVICE_ADDED to the compositor callback (mod.rs:725-738).
- verdict: same effect; ours matches wlroots.

### Poll-fd integration
- ours: `pollFd()` (libinput.zig:301-304) exposed to the orchestrator, which registers a zio `PipePoll` in main.zig:427-431 and calls `dispatch()` on readiness (main.zig:595-599).
- wlroots: registers its own `wl_event_loop_add_fd` source in `backend_start` (backend.c:119-120). There is NO `wlr_backend_get_fd` in wlroots — only `wlr_backend_get_drm_fd` (include/wlr/backend.h:82); the fd never leaves the backend.
- smithay: `impl EventSource` (mod.rs:707-716) + `AsFd` (mod.rs:702-705); calloop drives it.
- verdict: same integration, different plumbing; ours externalizes the fd, which is fine for the zio loop.

### Dispatch error handling
- ours: nonzero `libinput_dispatch` -> `error.DispatchFailed` (libinput.zig:311); caller logs and keeps the source armed (main.zig:596-599).
- wlroots: on dispatch failure, `wlr_backend_destroy` is called (backend.c:51-57) — the backend tears down.
- smithay: `self.context.dispatch()?` propagates the error to calloop (mod.rs:723), which drops the source.
- verdict: divergent. Ours is resilient (keeps polling); wlroots/smithay are fail-fast. Note that `libinput_dispatch` failure is fatal for the context in practice (negative errno per libinput.h:3869-3870), so "keep going" buys little beyond logging — the fd source stays armed and may spin on a dead fd.

### Device added/removed
- ours: `onDeviceAdded` (342-361) — dupes the name (libinput's name is only valid while the device lives, libinput.h:4337-4338 doc), appends to the registry, announces through `emitNewInput`; `onDeviceRemoved` (363-371) — linear handle scan, frees the name, `orderedRemove`. Removal lookup is safe: the DEVICE_REMOVED event's device pointer is valid until the event is destroyed, and a device is only freed when its refcount hits 0 (libinput.h:4185-4208), which for a device we never ref'd means after the context is gone — the registry never outlives the context (destroy at libinput.zig:506-513). No `libinput_device_ref` needed [VERIFIED 2026-08-09: wlroots refs because it stores devices past events — `libinput_device_ref(libinput_dev)` at backend/libinput/events.c:78; ours keeps the context owning the devices, so no refs].
- wlroots: `handle_device_added` (events.c:64-126) refs the device, stores `user_data` for O(1) lookup, and emits ONE `new_input` per capability present (events.c:84-121). Removal unrefs (events.c:34, 128-136).
- smithay: forwards raw `DeviceAdded`/`DeviceRemoved` events to the compositor callback; no tracking in the backend (mod.rs:730-738).
- verdict: close. Ours tracks only identity+name and is safe for the context lifetime; wlroots' user_data lookup is O(1) vs our O(n) scan (irrelevant at device-add/remove frequency).

### Capability/kind mapping
- ours: `kindForDevice` priority keyboard > pointer > touch (libinput.zig:242-246); a combined device announces ONCE under its highest capability. Devices with only tablet/pad/switch/gesture caps announce nothing.
- wlroots: checks each capability independently (KEYBOARD, POINTER, SWITCH, TOUCH, TABLET_TOOL, TABLET_PAD — events.c:84-121); a keyboard+pointer device announces twice.
- smithay: no classification in the backend; the compositor queries `Device::has_capability` per device (mod.rs:59-70).
- verdict: divergent model. Priority order matches wlroots' check order; the single-announce choice is a policy difference. Practical impact is limited: our event handlers dispatch by event type, not registry kind, so pointer events from a keyboard-classified device still reach the seat.

### Keycode translation (+8)
- ours: `evdevToXkb` at the backend (libinput.zig:214-216, applied in `onKey` 375-380).
- wlroots: the libinput backend passes the raw keycode (keyboard.c:48-68); the +8 happens in `wlr_keyboard_notify_key` (types/wlr_keyboard.c:120).
- smithay: `(self.key() + 8).into()` in the backend trait impl (mod.rs:116).
- verdict: same offset, same result.

### Keymap / keyboard features
- ours: keymap state lives in the seat's xkb module (`seat.keyEvent` -> `self.xkb.updateKey`, seat.zig:296-298). No keymap is pushed to any device; no LED handling; no key repeat at the backend.
- wlroots: the libinput backend does NOT set keymaps (verified: keyboard.c has no xkbcommon code — the task premise is wrong). The compositor calls `wlr_keyboard_set_keymap`; the backend only implements LED sync (`keyboard_set_leds` -> `libinput_device_led_update`, keyboard.c:16-19, and an initial `libinput_device_led_update(handle, 0)` at keyboard.c:31). Key repeat is compositor-side in wlroots too (repeat timers in the seat, not the libinput backend).
- smithay: `From<LedState> for libinput::Led` mapping exists (mod.rs:655-681); keymap/repeat are the compositor's job (anvil).
- verdict: keymap handling is architecturally equivalent (compositor-side in all three). Missing vs wlroots: LED state sync (both directions) — cosmetic on the VM path.

### Absolute vs relative motion
- ours: relative accumulates f64 deltas (libinput.zig:383-390); absolute uses `get_absolute_{x,y}_transformed(ev, 1)` then `scaleToOutput` (libinput.zig:393-401, 221-223).
- wlroots: identical normalized call — `libinput_event_pointer_get_absolute_x_transformed(pevent, 1)` (pointer.c:49-50); the compositor's cursor maps it onto outputs.
- smithay: `PointerMotionAbsoluteEvent` exposes absolute x/y via the position trait (mod.rs:292-300, 296-305).
- verdict: same. The transformed(ev,1) choice is byte-for-byte wlroots'. No clamping anywhere in the three backends for relative motion (clamping is compositor/cursor-side), so ours not clamping is not a divergence.

### Axis / scroll events
- ours: consumes only the legacy `LIBINPUT_EVENT_POINTER_AXIS` (libinput.zig:415-428) and explicitly ignores the 1.19+ SCROLL_WHEEL/FINGER/CONTINUOUS events (libinput.zig:334-336). Per the header the legacy event is still emitted alongside the new ones and both choices are legal — "Do not mix and match, either use the old event or the new events" (libinput.h:811-826). Unit conversion: 15.0 degrees -> 10 px per notch (libinput.zig:228-230, matches the seat's wheel*10 convention and the test at seat.zig:865).
- wlroots: the OPPOSITE choice — legacy POINTER_AXIS is explicitly ignored ("This event must be ignored in favour of the SCROLL_* events", events.c:169-171) and the SCROLL_* events are consumed via `handle_pointer_axis_value120` (events.c:172-183, pointer.c:149-186), which carries the source in the event type and uses `get_scroll_value_v120` for discrete (pointer.c:179).
- smithay: same as wlroots — SCROLL_WHEEL/FINGER/CONTINUOUS become `PointerScrollAxis` (mod.rs:782-805) with `amount`/`amount_v120`/`source` accessors (mod.rs:198-243); the legacy axis event falls into the `_ => trace!` prong (mod.rs:810-812).
- verdict: the event-choice split is fine, but ours drops the axis SOURCE (see Gaps 2), which the legacy event requires for correct interpretation.

### Wheel discrete
- ours: `get_axis_value_discrete` -> round to i32 notches (libinput.zig:233-235).
- wlroots: discrete scaled by `WLR_POINTER_AXIS_DISCRETE_STEP` (pointer.c:137-141), or v120 for the new events (pointer.c:179).
- smithay: `amount_v120` for wheel (mod.rs:213-222).
- verdict: ours works for plain wheel devices (the VM path); v120 normalization is absent but the legacy discrete already counts physical clicks (libinput.h:1653-1654), so hi-res wheel data is not lost, just not normalized.

### Seat announce contract
- ours: `Backend.events.new_input` signal (backend.zig:28, inited :67, `emitNewInput` :89-91 — the signal note 114 flagged as missing now exists). The announced `InputDevice` borrows the registry's name copy (libinput.zig:358-359), which outlives the event; the listener (main.zig:474-482) only logs synchronously and stores nothing, so no dangling borrow.
- wlroots: `wlr_backend.events.new_input` (include/wlr/backend.h:47), emitted per device (events.c:84-121).
- smithay: no signal; `process_events` invokes the compositor callback per event (mod.rs:730-738).
- verdict: same synchronous announce contract; ours is safe by construction for the borrowed name.

### uinput-devices.py
- ours: keyboard = EV_KEY letters+common keys; mouse = EV_KEY buttons + EV_ABS ABS_X/ABS_Y (0..0xFFFF, fuzz 0) + EV_REL REL_WHEEL (uinput-devices.py:28-39). libinput classifies these as keyboard / absolute pointer with wheel (mouse buttons give POINTER cap; no INPUT_PROP_DIRECT and no BTN_TOOL_* means no touchscreen/touchpad/tablet misclassification). `scroll -1` (kernel down) -> libinput +15.0 -> seat +10px down, consistent with the Wayland sign convention. Cleanup: both UInput handles closed in `finally` (uinput-devices.py:130-134) -> UI_DEV_DESTROY on exit, including error exits.
- wlroots/smithay: no uinput equivalent (real devices through logind/session).
- verdict: sound for the E2E; exercised by scripts/vm-drm-e2e.sh:62-64 (WAYLAND_LIBINPUT=1, virtio keyboard/mouse on /dev/input) with libinput.dev in the guest closure (vm.nix:52-62).

## Gaps

1. Name leak on registry-append failure. `onDeviceAdded`: `errdefer self.allocator.free(owned)` (libinput.zig:352) does not run on `self.devices.append(...) catch return` (libinput.zig:354) — `catch return` is a plain return, not an error return, so errdefer is skipped and `owned` leaks. Only on OOM; severity low. Fix: `self.devices.append(...) catch { self.allocator.free(owned); return; }`. Proven from Zig control-flow semantics.
2. Axis source ignored; non-wheel scrolls mis-scaled. `onPointerAxis` (libinput.zig:415-428) never calls `libinput_event_pointer_get_axis_source` (declared at libinput.zig:191, unused). The legacy POINTER_AXIS value's units depend on the source: WHEEL = degrees, 15.0/click (libinput.h:1605-1612); FINGER = relative units, sequence terminated by 0 (1598-1599); CONTINUOUS = cursor-equivalent units, 1.0 = 1px (1614-1617). `axisValueToPixels` applies the wheel 10/15 scale to every source, and `axisDiscreteToNotches` rounds a discrete that is ALWAYS 0 for FINGER/CONTINUOUS (libinput.h:1656-1657). The seat then labels everything `.wheel` (seat.zig:243). A touchpad (announced as `.pointer` by `kindForDevice`, libinput.zig:244) therefore scrolls at an arbitrary scale with a false wheel source. wlroots/smithay avoid this by gating on the SCROLL_* event types, which carry the source in the type (wlroots events.c:172-183; smithay mod.rs:782-805, source at 226-231). Severity medium (VM path is wheel-only, so unobserved in the E2E). Proven against the header docs.
3. Touch devices announce but produce nothing. `kindForDevice` announces `.touch` (libinput.zig:245) but the dispatch switch (libinput.zig:318-340) has no TOUCH_* prongs — touch down/up/motion/cancel/frame (500-504) land in the `else` debug branch. wlroots implements all five (events.c:184-194, touch.c:10-83); smithay forwards all five (mod.rs:747-762). Severity low (M3 scope); a touchscreen would appear in the registry yet be inert.
4. No libinput log handler. wlroots installs a handler at ERROR priority (backend.c:104-105); ours leaves libinput's default stderr logging, so libinput-side diagnostics bypass the compositor's log. Severity low. Not a bug, a diagnostics gap.
5. No zero-device check at start. wlroots fails `backend_start` when the initial drain yields no devices unless `WLR_LIBINPUT_NO_DEVICES=1` (backend.c:109-114). Ours starts silently with an empty registry (libinput.zig:470-505). Intentional for the dev host, but a broken udev/seat config looks like a healthy backend with no input. Severity low.
6. No LED sync. wlroots pushes LED state to devices (`libinput_device_led_update`, keyboard.c:31-35, 44) and smithay maps LedState (mod.rs:674-688); ours has no LED path. Severity low.
7. Combined-capability devices announce once (priority) vs wlroots' per-capability announcements (events.c:84-121). Policy difference, not a defect — pointer/keyboard events still flow to the seat regardless of the announced kind (handlers dispatch on event type only). Severity low.
8. Dispatch-failure policy: ours logs and keeps the source armed (main.zig:596-599) vs wlroots destroying the backend (backend.c:51-57) and smithay propagating to calloop (mod.rs:723). [RESOLVED 2026-08-09 from the zio source: an errored rearm completion IS re-submitted — `finishCompletion` runs the callback then `if (was_rearm and completion.flags.rearm) self.loop.add(completion)` (zio-0.17.0 src/ev/loop.zig:371-373) — so a dead fd spins. Our fix (onInputReady stops the loop on dispatch error, main.zig) exits instead of spinning; wlroots destroys the backend, smithay propagates to calloop].
9. Dead FFI decls: `libinput_path_create_context`/`libinput_path_add_device` (libinput.zig:160-161), `libinput_device_get_seat` (:195), `libinput_event_pointer_get_axis_source` (:191) are declared but never called (verified by grep). Unused externs are harmless but misleading — the path-context pair implies a device path this backend will never take. Severity trivial.
10. udev ref pairing is balanced (udev_new libinput.zig:474, udev_unref :511, order ctx-then-udev) and correct either way; RESOLVED 2026-08-09 from the libinput source: `libinput_udev_create_context` takes its OWN ref on the passed context — `input->udev = udev_ref(udev)` (src/udev-seat.c:395) — so our pairing (udev_new → ctx create (libinput's ref) → libinput_unref (drops libinput's ref) → udev_unref (drops ours)) is balanced and correct. No action needed.

## Verdict

The FFI surface is fully correct — all 30 extern decls match libinput 1.31.3 (the two-arg `libinput_device_has_capability` fix at libinput.zig:196 is the right shape), the enum constants are exact for this header, and the lifecycle (udev create/assign/drain, errdefer cleanup, ctx-before-udev teardown) mirrors wlroots `backend_start` (backend.c:90-109). Keycode +8, absolute-motion normalization, and the seat announce contract match wlroots and smithay. The one real correctness bug is Gaps 2 (axis source ignored — wrong scale and a false wheel source for touchpad/continuous scrolls); the only leak is Gaps 1 (OOM-only, errdefer bypass). Everything else is scope or policy: no touch events, no LED sync, no zero-device check, no libinput log handler, and the legacy-vs-new scroll event choice (legal per libinput.h:815, and verified VM-correct for wheel devices). The uinput harness is sound and cleans up on exit.
