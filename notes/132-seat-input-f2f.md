# Seat / Input (wl_seat + wl_keyboard + wl_pointer + xkb) and Subsurface — function-level audit

Scope: `src/compositor/seat.zig` (1010 lines incl. tests), `src/compositor/xkb.zig` (198),
`src/compositor/subsurface.zig` (791), server integration `src/server/main.zig`
(syncSubsurfaceNodes:2130, applyRestack:2188, onSurfaceDestroy:1562).
References: wlroots 0.20.2 `types/seat/{wlr_seat,wlr_seat_keyboard,wlr_seat_pointer,wlr_seat_touch}.c`,
`types/wlr_keyboard.c`, `types/wlr_subcompositor.c`, `include/wlr/types/wlr_seat.h`;
smithay 0.7.0 `src/wayland/seat/{mod,keyboard,pointer,touch}.rs`, `src/input/{pointer,keyboard}/mod.rs`,
`src/wayland/compositor/{handlers,tree}.rs`; KWin master `src/wayland/{seat,keyboard,pointer,subcompositor}.cpp`.
Protocol ground truth: `protocols/wayland/wayland.xml` (vendored).

Status note: notes/106 (seat/xkb) and 107 (subsurface) are stale for several rows — the
code has moved since. The fan-out bug, the missing post-enter modifiers, the unconditional
axis_stop, and the dangling-focus UAF are FIXED (verified below). place_above/place_below are
no longer no-ops. This note records the CURRENT state function by function.

Touch is NOT implemented (documented absence; see finding F3).

---

## 1. wl_seat / wl_keyboard / wl_pointer — function-level table

Ours (seat.zig unless noted; line numbers from the current file) | Reference | What it does
--- | --- | ---
`Seat.init` seat.zig:146 | `wlr_seat_create` wlr_seat.h:354 / impl wlr_seat.c:337; smithay `SeatState::new_wl_seat` seat/mod.rs:166; KWin `SeatInterface` ctor seat.cpp:58 | Create seat: global + name + default grabs (refs) + per-client state (refs)
`Seat.deinit` seat.zig:179 | `wlr_seat_destroy` wlr_seat.c:181 (clears pointer+keyboard focus with leave, destroys per-client state); KWin `~SeatInterface` seat.cpp:66 | Teardown; wlroots sends leave/clear on the way out — ours does not
`Seat.setPick` seat.zig:191 | none (wlroots: compositor feeds `wlr_seat_pointer_notify_enter` wlr_seat.h:441; smithay: focus passed into `PointerHandle::motion` input/pointer/mod.rs:232) | Ours-only hit-test hook; refs leave hit-testing to the compositor
`Seat.nextSerial` seat.zig:203 | `wlr_seat_client_next_serial` wlr_seat.c:488 + per-client ringset wlr_seat.h:26-30/55; smithay `Serial` (wayland-server); KWin `display->nextSerial()` seat.cpp:446 | Mint an event serial; wlroots records a 128-slot ring per client; ours keeps ONE `last_serial` (seat.zig:88)
`Seat.pointerMotion` seat.zig:210 | `wlr_seat_pointer_notify_motion` wlr_seat.h:461 → `wlr_seat_pointer_send_motion` wlr_seat_pointer.c:246-268; smithay `WlPointerHandle::motion` pointer.rs:106-120; KWin `PointerInterface::sendMotion` pointer.cpp:330 | Hit-test, enter/leave on focus change, motion to the focused client, frame
`Seat.pointerButton` seat.zig:240 | `wlr_seat_pointer_notify_button` wlr_seat_pointer.c:461-517 (button_count, grab_button/grab_serial bookkeeping, implicit-click-grab basis); smithay `PointerHandle::button` input/pointer/mod.rs:271; KWin `SeatInterface::notifyPointerButton` seat.cpp:665-700 | Press/release; wlroots tracks per-button counts and the grab serial; ours ALSO hardcodes click-to-focus (seat.zig:247) which no ref does
`Seat.pointerAxis` seat.zig:276 | `wlr_seat_pointer_send_axis` wlr_seat_pointer.c:321-392 (v120 accumulators :288-318, axis_source dedup :334-342, axis_stop only on value==0 :389-391, relative_direction :373-378); smithay `WlPointerHandle::axis` pointer.rs:126-232; KWin `PointerInterface::sendAxis` pointer.cpp:216-329 | Wheel/scroll: source + discrete/value120 + axis + stop + frame
`Seat.setKeyboardFocus` seat.zig:319 | `wlr_seat_keyboard_enter` wlr_seat_keyboard.c:234-311 (leave old, enter new, THEN modifiers :291, re-arm surface_destroy :276-287); smithay `enter_internal` keyboard.rs:207-261; KWin `KeyboardInterface::setFocusedSurface` keyboard.cpp:113-149 | Change keyboard focus: leave + enter(pressed keys) + modifiers
`Seat.keyEvent` seat.zig:351 | `wlr_keyboard_notify_key` wlr_keyboard.c:110-129 + `wlr_seat_keyboard_send_key` wlr_seat_keyboard.c:67-84; smithay `KbdInternal::key_input` input/keyboard/mod.rs:305-352 + `KeyboardTarget::key` keyboard.rs:262-269; KWin `KeyboardInterface::sendKey` keyboard.cpp:150-178 | Update xkb state, pressed set, modifiers, deliver key
`Seat.cursorSurface` seat.zig:401 | none as accessor; wlroots `request_set_cursor` signal wlr_seat_pointer.c:106-113; smithay `cursor_image` callback + `allow_setting_cursor` pointer.rs:515-537; KWin `PointerSurfaceCursor` pointer.cpp:63-108 | Expose the client cursor surface for rendering
`Seat.mod4Active` seat.zig:407 | none; wlroots `wlr_keyboard_get_modifiers` wlr_keyboard.h:159; smithay `modifier_state` input/keyboard/mod.rs:1230 | Hardcoded Mod4 bit 6 check for the quit binding
`Seat.sendKeyboardModifiers` (private) seat.zig:416 | `wlr_seat_keyboard_send_modifiers` wlr_seat_keyboard.c:205-232 (sends group too); smithay keyboard.rs:84-93 (layout_effective); KWin `KeyboardInterface::sendModifiers` keyboard.cpp:179-217 | Modifiers to the focused client with fresh serial
`Seat.surfaceDestroyed` seat.zig:431 | wlroots surface_destroy listeners re-armed per focus change (wlr_seat_keyboard.c:276-287, wlr_seat_pointer.c:210-225); KWin `aboutToBeDestroyed` → sendLeave + clear (keyboard.cpp:138-141, pointer.cpp:96-101) | Clear focus pointers when a focused surface dies (wired at main.zig:1572)
`Seat.pointerEnter` (private) seat.zig:436 | `wlr_seat_pointer_enter` wlr_seat_pointer.c:184-242; smithay `PointerTarget::enter` pointer.rs:308-313; KWin `PointerInterface::sendEnter` pointer.cpp:84-113 | Enter + frame to the entered client's pointers, store enter serial
`Seat.pointerLeave` (private) seat.zig:463 | `seat_client_send_pointer_leave_raw` wlr_seat_pointer.c:148-158; KWin `PointerInterface::sendLeave` pointer.cpp:118-123 | Leave + frame to the leaving client's pointers
`bindSeat` seat.zig:489 | `seat_handle_bind` wlr_seat.c:160-199; smithay `GlobalDispatch2::bind` seat/mod.rs:317-346; KWin `seat_bind_resource` seat.cpp:64-70 | Capabilities + name(v2) on bind; wlroots also builds per-client `wlr_seat_client`
`seatRequest.get_keyboard` seat.zig:501 | `seat_client_create_keyboard` wlr_seat_keyboard.c:399-463 (capability inert-ification :411-413, keymap+repeat_info+enter+modifiers :455-460); smithay `GetKeyboard` seat/mod.rs:255-262 + `new_kbd` keyboard.rs:59-98; KWin `keyboard_bind_resource` keyboard.cpp:34-51 | Create wl_keyboard; send keymap, repeat_info, late enter+modifiers
`seatRequest.get_pointer` seat.zig:531 | `seat_client_create_pointer` wlr_seat_pointer.c:543-570; smithay `GetPointer` seat/mod.rs:239-254; KWin `pointer_bind_resource` pointer.cpp:110-122 | Create wl_pointer; late enter+frame
`seatRequest.get_touch` seat.zig:556 | `seat_handle_get_touch` wlr_seat.c:53-66 (MISSING_CAPABILITY error); smithay `GetTouch` seat/mod.rs:263-290 (inert handle); KWin `seat_get_touch` seat.cpp:84-88 | Ours: dead wl_touch object (no events, no error)
`touchRequest` seat.zig:569 | wlroots wlr_seat_touch.c (full touch: points, grabs, cancel); smithay touch.rs; KWin seat.cpp:912-1039 | Release-only dead object (touch unimplemented)
`pointerRequest.set_cursor` seat.zig:583 | `pointer_set_cursor` wlr_seat_pointer.c:85-113 (cursor role enforcement :85-90, emits request_set_cursor); smithay `Request::SetCursor` pointer.rs:366-431 + `allow_setting_cursor` :515-537; KWin `pointer_set_cursor` pointer.cpp:63-108 (focused-client + focusedSerial checks) | Apply client cursor surface + hotspot when serial matches

### xkb.zig

Ours | Reference | What it does
--- | --- | ---
`Xkb.init` xkb.zig:86 | `wlr_keyboard_set_keymap` wlr_keyboard.c:204-283 (shm-file pair + mmap, mod_indexes/led_indexes :229-248, pressed-key replay :243-246); smithay `add_keyboard_with_context_flags` input/mod.rs:604 + `XkbConfig::compile_keymap` input/keyboard/mod.rs:906-909; KWin `KeyboardInterface::setKeymap` keyboard.cpp:82-94 | Compile "us" keymap, state; memfd + text dump
`Xkb.deinit` xkb.zig:150 | `keyboard_unset_keymap` wlr_keyboard.c:154-166; smithay Drop of Xkb | Free fd, text, state, keymap, context
`Xkb.dupKeymapFd` xkb.zig:162 | `seat_client_send_keymap` wlr_seat_keyboard.c:339-377 (shared fd, no dup); smithay `keymap_file.send` keyboard.rs:66-68; KWin `sendKeymap` keyboard.cpp:70-81 (sealed shared RamFile for v7+) | dup memfd per keymap send
`Xkb.updateKey` xkb.zig:168 | `wlr_keyboard_notify_key` wlr_keyboard.c:110-129 — xkb keycode space is scancode+8 there too, but the WIRE value is scancode (see F1); smithay `key_input` input/keyboard/mod.rs:305-352 | xkb_state_update_key + keysym
`Xkb.keysym` xkb.zig:173 | `wlr_keyboard_keysym_to_*` helpers wlr_keyboard.h:126-135; smithay `KeysymHandle` input/keyboard/mod.rs:458-547 | keysym of a keycode
`Xkb.mods` xkb.zig:179 | `keyboard_modifier_update` wlr_keyboard.c:41-66 + group; smithay `ModifiersState::serialized` keyboard.rs:84-93 (layout_effective); KWin `KeyboardInterface::sendModifiers` keyboard.cpp:179-217 | depressed/latched/locked; ours drops group (always 0)

## 2. wl_subcompositor / wl_subsurface — function-level table

Ours (subsurface.zig) | Reference | What it does
--- | --- | ---
`Subcompositor.init` subsurface.zig:72 | `wlr_subcompositor_create` wlr_subcompositor.c:419-439; smithay `GlobalDispatch2` handlers.rs:420-440; KWin `SubCompositorInterface` ctor subcompositor.cpp:49-59 | wl_subcompositor global at v1 (subsurface.zig:60 == wlr_subcompositor.c:11)
`Subcompositor.deinit` subsurface.zig:101 | `subcompositor_handle_display_destroy` wlr_subcompositor.c:406-417; smithay globals owned by wayland-server | Destroy outstanding wl_subsurface resources, drop registry
`Subcompositor.surfaceFromResource` subsurface.zig:117 | wlr_surface_from_resource pattern (O(1) user-data); smithay `WlSurface::data` handlers.rs:153-157 | O(n) linear scan; implementation detail
`Subsurface` struct subsurface.zig:127 | `wlr_subsurface` wlr_subcompositor.c (pending/current position, synced state); smithay `SubsurfaceState`/`SubsurfaceCachedState` handlers.rs:486-534; KWin `SubSurfaceInterface` subcompositor.cpp:118-124 | Role object: surface, parent, x/y, sync + restack + 4 listeners
`getSubsurface` subsurface.zig:210 | `subcompositor_handle_get_subsurface` wlr_subcompositor.c:322-395 (role conflict → bad_surface on subcompositor :338-343; self/ancestor → bad_parent :346-356; default sync :359); smithay handlers.rs:442-477 (role error → BadSurface, cycle check); KWin subcompositor.cpp:64-100 | Role assignment + parent validation; nesting ALLOWED now (parentIsDescendant subsurface.zig:201; note 107 gap 5 FIXED)
`subsurfaceRequest.set_position` subsurface.zig:307 | `subsurface_handle_set_position` wlr_subcompositor.c:58-73 → pending, applied on parent commit via surface_synced_move_state :161-179; smithay handlers.rs:568-581 (pending SubsurfaceCachedState.location); KWin `subsurface_set_position` subcompositor.cpp:108-116 (pending + committed flag) | Ours writes ss.x/ss.y IMMEDIATELY (single-buffered; see F5)
`subsurfaceRequest.place_above` subsurface.zig:318 | `subsurface_handle_place_above` wlr_subcompositor.c:95-123 (restack pending list, bad_surface on non-sibling/parent); smithay handlers.rs:583-590 + `reorder` tree.rs:419-448; KWin `subsurface_place_above` subcompositor.cpp:125-141 | Validate reference (restackTarget subsurface.zig:358 — parent or same-parent sibling, self excluded), record restack_sibling_id/restack_above; server applies (main.zig:2188 applyRestack). Note 107 gap 2 FIXED
`subsurfaceRequest.place_below` subsurface.zig:325 | `subsurface_handle_place_below` wlr_subcompositor.c:125-153; smithay handlers.rs:591-597; KWin `subsurface_place_below` subcompositor.cpp:143-159 | Same as above, below
`subsurfaceRequest.set_sync` subsurface.zig:337 | `subsurface_handle_set_sync` wlr_subcompositor.c:155-157; smithay handlers.rs:599-605; KWin `subsurface_set_sync` subcompositor.cpp:161-167 | Set sync flag
`subsurfaceRequest.set_desync` subsurface.zig:338 | `subsurface_handle_set_desync` wlr_subcompositor.c:159-182 (flush cache when no synced ancestor); smithay handlers.rs:606-614; KWin `subsurface_set_desync` subcompositor.cpp:169-177 + `parentDesynchronized` :211-232 | Clear sync; flush cached commit if chain desynced (isSynchronized subsurface.zig:439)
`subsurfaceRequest.destroy` subsurface.zig:345 | `subsurface_handle_destroy` → `subsurface_destroy` wlr_subcompositor.c:38-54 (flush cache :39-41, UNMAP :43); smithay `Destroy`/`destroyed` handlers.rs:615-647 (unset parent, reset state); KWin `subsurface_destroy` subcompositor.cpp:102-106 | Flush cache, destroy resource; surface keeps rendering as plain surface (protocol says unmapped — F6)
`onSurfaceClientCommit` subsurface.zig:397 | `subsurface_handle_surface_client_commit` wlr_subcompositor.c:224-235 (lock pending when synchronized); smithay commit() tree.rs:258-329 (sync subtree merge) | Defer/lock synced child commits (Surface.cached_state_locks, surface.zig:188-195; commit gate surface.zig:420)
`onParentCommit` subsurface.zig:415 | `subsurface_handle_parent_commit` wlr_subcompositor.c:240-250 (unlock_cached on parent commit) | Flush cached child state when parent commits — commit ordering parent-before-child FIXED (note 107 gap 1)
`flushCached` subsurface.zig:427 | `wlr_surface_unlock_cached` wlr_compositor.c:947-986 (apply pending via normal pipeline) | Apply the merged deferred state through validatePending + applyCommit
`isSynchronized` subsurface.zig:439 | `subsurface_is_synchronized` wlr_subcompositor.c:13-24; smithay `is_effectively_sync` handlers.rs:537-552; KWin `SubSurfaceInterface::isSynchronized` subcompositor.cpp:185-198 | Sync walk up the parent chain
`onSurfaceDestroy` subsurface.zig:372 / `onParentDestroy` subsurface.zig:383 / `teardownOnSurfaceDeath` subsurface.zig:462 / `detachListeners` subsurface.zig:469 / `subsurfaceDestroy` subsurface.zig:476 | wlroots role destroy (surface) wlr_compositor.c:854-872; parent_destroy listener wlr_subcompositor.c:253-259; smithay tree.rs:126-149 orphan cleanup | Lifecycle guards — UAF gap (note 107 gap 4) FIXED: child or parent death tears the wl_subsurface down synchronously before the Surface frees
`Subcompositor.syncSubsurfaceNodes` server main.zig:2130 + `applyRestack` main.zig:2188 | scene `subsurface_tree.c:238-304` (children inside parent's node, below/parent/above ordering, clip); smithay `map_tree` tree.rs:465-551 | Per-frame scene parenting + restack application + enable/disable (note 107 gap 9 FIXED: no more flat root re-append)

---

## 3. Findings

### F1 — wire keycode is off by 8 (HIGH)
Ours: `Seat.keyEvent` sends `keycode` straight to `kbd.sendKey` (seat.zig:393) and the
enter pressed-keys array carries the same values (seat.zig:337, 524). The seat API and
xkb state operate in xkb keycode space = evdev scancode + 8 (docstring seat.zig:350,
backend feeds `evdevToXkb` libinput.zig:236-238, 446; tests use 38 = 'a').
Reference: protocol says clients ADD 8 to the wire keycode to get the xkb keycode
(protocols/wayland/wayland.xml:2597 "to determine the xkb keycode, clients must add 8
to the key event keycode"); wlroots keeps wlr_keyboard in SCANCODE space
(libinput backend passes raw scancodes, backend/libinput/keyboard.c:50-61) and adds 8
only for xkb_state_update_key (wlr_keyboard.c:115-120), sending scancodes on the wire
(wlr_seat_keyboard.c:67-84) and in enter's keys array (wlr_seat_keyboard.c:234-273);
smithay stores xkb keycodes but subtracts 8 at the wire (keyboard.rs:262-269,
`serialize_pressed_keys` keyboard.rs:33-35); KWin likewise (input adds 8 only for xkb,
keyboard.cpp:179 sends raw).
Expected: wire key + enter keys = evdev scancode; xkb gets scancode+8.
Why it matters: any protocol-correct client (foot, GTK, Qt) feeds `key+8` to xkb and
reads every key one row off ('a' → 'l' with our current wire value 38). Latent today:
no real client in the gate; tests only count events and never xkb-interpret the wire.
Class: FIXABLE-in-module (keep the seat API in xkb keycodes; subtract 8 in
keyEvent's send and in both enter-array constructions).

### F2 — serial model: single `last_serial` vs per-client ringset (MED)
Ours: `nextSerial` (seat.zig:200) records only the seat-wide last serial
(`last_serial` seat.zig:88); data_device validates `set_selection`/`start_drag` with
STRICT equality `r.serial != mgr.seat.last_serial` (data_device.zig:327, 363).
Reference: wlroots keeps a per-client 128-slot serial ringset
(`struct wlr_serial_ringset` wlr_seat.h:20-30,55) filled by
`wlr_seat_client_next_serial` (wlr_seat.c:488-513) and validated over the ring with
wrap-safe arithmetic (`wlr_seat_client_validate_event_serial` wlr_seat.c:515-524);
smithay `Serial` from wayland-server with `last_enter`/grab checks (pointer.rs:515-537);
KWin validates set_cursor against the focused serial (pointer.cpp:74) and drags against
per-button serials + `hasImplicitPointerGrab` (seat.cpp:1063-1071).
Expected: a client may echo any serial it was handed recently; validity is per client,
with half-range wrap handling.
Why it matters: (a) FALSE REJECTS — with split pointer/keyboard focus, an event to
client B bumps last_serial; client A's set_selection with its own (still valid) enter
serial is rejected; (b) FALSE ACCEPTS — start_drag accepts a key-event serial, where
wlroots requires the pointer grab serial (button_count==1, grab_serial, origin==focus,
wlr_seat_pointer.c:603-617); any client event serial "works" for ours. Blocks nothing
today (single focused client per device, no drags) but is a correctness debt for popups
and DnD.
Class: NEEDS-wiring (per-client serial storage + ring; data_device validation moves to
a seat-provided `validateEventSerial(client, serial)`; pointer grab serial F3).

### F3 — no grab system (pointer/keyboard) and touch is a dead object (HIGH/STRUCTURAL)
Ours: no grab state anywhere in `Seat` (seat.zig:55-110); `pointerButton` hardcodes
click-to-focus (seat.zig:247); `get_touch` creates a dead wl_touch that never errors
and never emits (seat.zig:556-567); no `WL_SEAT_ERROR_MISSING_CAPABILITY` post for any
get_* (wlroots posts it wlr_seat.c:26-66; smithay deliberately returns an inert handle
seat/mod.rs:258-260 comment — so the error path is wlroots-specific; ours does neither).
Reference: wlroots has full grab machinery — interfaces + structs
wlr_seat.h:94-145,151-174, default grabs wlr_seat.c:337-372, start/end/has for pointer
(wlr_seat.h:491-503), keyboard (581-593), touch (702-714); implicit click-grab serial
bookkeeping wlr_seat_pointer.c:461-517, reset_buttons on focus switch :545-563;
smithay `PointerGrab`/`KeyboardGrab` traits + `set_grab`/`unset_grab`
(input/pointer/mod.rs:168-178, input/keyboard/mod.rs:961-970); KWin implicit grabs via
per-button serials (seat.cpp:1063-1071) and drag system (seat.cpp:190-236, 1276-1322).
Expected: events route through the current grab; press mints a grab serial; DnD,
popup grabs, pointer constraints all hang off this.
Why it matters: no path to drag-and-drop, xdg_popup grabs, or pointer constraints;
the dead wl_touch traps clients that probe for touch (they hold a live resource that
never delivers). The hardcoded click-to-focus is a policy the refs leave to the
compositor (wlroots does NOT move keyboard focus on click).
Class: STRUCTURAL (grab trait/struct layer + routing seam) — the largest single item;
the implicit-click-grab serial (grab_serial) is a FIXABLE prerequisite that unlocks
F2's start_drag check.

### F4 — version 7 vs 9/10: missing axis_value120, axis_relative_direction, key repeat state (MED)
Ours: `seat_version = 7` (seat.zig:45); axis path sends source/discrete/axis/stop+frame
(seat.zig:296-317) but can never send value120 or relative_direction; repeat_info
hardcoded `(0,0)` (seat.zig:517).
Reference: wlroots `SEAT_VERSION 9` (wlr_seat.c:14) with axis_value120 for v8+
(wlr_seat_pointer.c:361-370) and axis_relative_direction for v9 (:373-378); smithay
global at 9 (seat/mod.rs:175), axis_value120 + per-client v120 accumulation
(pointer.rs:135-158), relative_direction v9 (pointer.rs:214-228); KWin at 10
(seat.cpp:30) with `KEY_STATE_REPEATED` (keyboard.cpp:44-47, 150-168) and rate 0 for
v10+ clients. wlroots repeat default 25/600 (wlr_keyboard.c:140-141) re-broadcast on
change (wlr_seat_keyboard.c:100-108); smithay `change_repeat_info`
(input/keyboard/mod.rs:1322-1325); KWin `setRepeatInfo` keyboard.cpp:219-226.
Expected: v8+ clients get value120 deltas (accumulated for <v8), v9 clients get
relative_direction, and repeat_info advertises a real rate/delay.
Why it matters: high-res wheels (all modern trackpads via libinput) degrade to
low-res; clients that prefer repeat get none (rate 0 tells clients to do their own
repeat, which is legal but pushes repeat into every toolkit; foot expects compositor
repeat). Version bump is a wire-contract change.
Class: FIXABLE-in-module (bump seat_version to 9; add value120 accumulation per
pointer resource — the accumulator state is per client like wlroots'
`client->value120` wlr_seat.h:58; send relative_direction; make repeat_info configurable).

### F5 — subsurface position and z-order are request-time, not double-buffered (MED)
Ours: `set_position` writes ss.x/ss.y immediately (subsurface.zig:307-310); the server
applies it per frame regardless of any commit (main.zig:2160-2161); restack is recorded
at request time and applied at the next frame (main.zig:2148-2153) — not gated on a
commit either.
Reference: protocol: "Position is double-buffered state on the parent surface"
(wayland.xml:3315-3317), z-order likewise (wayland.xml:3336-3337); wlroots writes
pending.x/y (wlr_subcompositor.c:65-73) applied by the parent's commit
(surface_synced_move_state :161-179, move_state hook wlr_compositor.c:1000-1015);
smithay pending location committed via `Cacheable` (handlers.rs:568-581, 512-521);
KWin pending->subsurface.position + committed flag applied on parent commit
(subcompositor.cpp:108-116, parentApplyState :234-244).
Expected: a set_position/place_above before commit changes nothing visible until the
parent's next wl_surface.commit.
Why it matters: clients that batch position+commit in one roundtrip see the move one
frame early — cosmetic; but it also applies position the client explicitly deferred,
which can desync a client's own bookkeeping (rare). Combined with F5's immediate
application it is a protocol-contract deviation, not just timing.
Class: FIXABLE-in-module (hold pending x/y/restack on the Subsurface; apply when the
parent commits — there is already an `onParentCommit` flush seam; or move pending
into the surface's cached-state slot).

### F6 — wl_subsurface destroy / parent death leaves the child mapped (MED)
Ours: `.destroy` flushes the cache and clears the role; the surface keeps rendering as
a plain surface (subsurface.zig:345-351, 482-486, module doc "foot only destroys
subsurfaces at teardown"); parent death likewise (onParentDestroy subsurface.zig:383-387).
Reference: protocol: destroy → "The wl_surface is unmapped immediately"
(wayland.xml:3298-3301); parent destroyed → "the sub-surface is unmapped"
(wayland.xml:3279-3280). wlroots unmaps in both paths (`subsurface_destroy` →
`wlr_surface_unmap` wlr_subcompositor.c:43; parent_destroy listener :253-259);
smithay unparents and resets state but leaves display to the compositor
(handlers.rs:622-645 — library behavior, compositor decides); KWin `~SubSurfaceInterface`
subcompositor.cpp:143-156 (clears role; unmap is the surface role's job).
Expected: child disappears when its wl_subsurface dies or its parent dies.
Why it matters: a dead parent leaves the child's last frame on screen — visible
ghosting in any client that destroys a popup's subsurface while the popup surface
lives. Ours is a documented M3 deviation; wlroots semantics are the contract.
Class: FIXABLE-in-module (call the unmap path — Surface has map/unmap transitions —
in subsurfaceDestroy and onParentDestroy; keep the cache flush first).

### F7 — axis_source sent per call, frame after every event; no batch (LOW)
Ours: `pointerAxis` sends axis_source unconditionally per call (seat.zig:301) and a
frame after every motion/button/enter/leave (seat.zig:227, 260, 308, 456, 474); no
`sent_axis_source` dedup.
Reference: wlroots sends axis_source once per frame (cached_axis_source,
wlr_seat_pointer.c:334-342, reset on frame :438-441); frames are compositor-driven
(`wlr_seat_pointer_notify_frame` wlr_seat.h:485) after the whole input batch — one
frame per event-loop batch, not per event. KWin likewise: `sendFrame` is a separate
call (pointer.cpp:330-343) from the input processing. smithay: `axis_source` only when
`details.source` is Some (pointer.rs:131-150), `axis_stop` only on explicit stop flags
(:159-173).
Expected: one axis_source per frame (matching the source of that frame's events), one
frame per input batch.
Why it matters: legal but chatty; clients see N frames for an N-event scroll burst
and axis_source repeated mid-frame where the protocol expects it once. No functional
break.
Class: FIXABLE-in-module.

### F8 — pointer motion dedup absent (LOW)
Ours: every pointerMotion with focus sends motion (seat.zig:225-227).
Reference: wlroots drops duplicate fixed-point positions
(wlr_seat_pointer.c:252-263); KWin does NOT dedup (sendMotion pointer.cpp:330-339) and
smithay does not either — so this is a wlroots nicety, not a cross-reference contract.
Why it matters: sub-pixel movement in the same fixed-point cell generates redundant
events; the raylib backend already avoids same-pixel calls (raylib_input.zig:139).
Class: FIXABLE-in-module (compare fixed-point of focus_x/focus_y against last sent).

### F9 — set_cursor validation: no role enforcement, allows when unfocused (MED)
Ours: accepts when `serial == pointer_enter_serial OR pointer_focus == null`
(seat.zig:589-593); no cursor-surface role check.
Reference: wlroots enforces the pointer-cursor surface role and posts
`WL_POINTER_ERROR_ROLE` on conflict (wlr_seat_pointer.c:85-90, 96-100); smithay same
role error (pointer.rs:380-386) plus `allow_setting_cursor` = last_enter serial match
OR same-client grab, AND current focus is the same client (pointer.rs:515-537);
KWin rejects when unfocused, when the caller isn't the focused client, or on serial
mismatch (pointer.cpp:66-79), and enforces the cursor role (:83-95).
Expected: set_cursor is accepted only from the focused client with the current enter
serial (or during that client's grab), and the surface may carry only the cursor role.
Why it matters: the `pointer_focus == null` branch lets ANY client set the cursor
image with any serial while the pointer is outside all surfaces — a client can swap
the cursor remotely. Latent (single-client demo) but a real authority hole.
Class: FIXABLE-in-module (add focused-client + role checks; keep the enter-serial match).

### F10 — no keymap change / layout-group tracking (LOW-MED)
Ours: keymap compiled once at init (seat.zig:146-153); modifiers always send group 0
(seat.zig:416-425); `Xkb.mods` has no group (xkb.zig:179-186); xkb FFI subset is 11
functions (xkb.zig:38-48).
Reference: wlroots `wlr_keyboard_set_keymap` re-sends keymap to all clients via the
keymap signal (wlr_seat_keyboard.c:87-99, 110-120) and tracks mod_indexes/led_indexes
(wlr_keyboard.c:229-248); modifiers carry group (wlr_seat_keyboard.c:215-217);
smithay `set_keymap_from_string`/`set_xkb_config` (input/keyboard/mod.rs:888-918) and
`layout_effective` (keyboard.rs:84-93); KWin `setKeymap` re-broadcasts
(keyboard.cpp:82-94) and sends group (keyboard.cpp:179-217).
Expected: keymap replaceable at runtime; multi-layout keymaps report the effective
group in modifiers.
Why it matters: layout switching (both refs and KWin support it) is impossible; a
2-layout keymap would report group 0 forever. Latent: single "us" layout.
Class: NEEDS-wiring (keymap-change broadcast channel + group in Xkb.mods + mod-index
mapping); the broadcast is FIXABLE-in-module.

### F11 — teardown sends no leave/clear (LOW)
Ours: `Seat.deinit` (seat.zig:179-188) just frees; focused clients get no
keyboard.leave / pointer.leave.
Reference: wlroots `wlr_seat_destroy` clears focus for all devices first
(wlr_seat.c:181-186, 191-196) and destroys per-client state with leave on
capability removal (wlr_seat_set_capabilities wlr_seat.c:421-452).
Expected: on seat teardown the focused client is told (best-effort; the display is
dying anyway).
Why it matters: cosmetic only — the display teardown immediately kills client
connections; wlroots does it for orderly shutdown of clients that might otherwise
hang. LOW.
Class: FIXABLE-in-module.

### F12 — focused-surface destroy: ours clears silently, refs send leave (LOW)
Ours: `surfaceDestroyed` (seat.zig:431-434) nulls the focus pointers without events
(comment: "no leave events are sent").
Reference: wlroots clears focus silently on surface destroy too (wlr_seat_keyboard.c:
276-287, wlr_seat_pointer.c:210-225 — remove listener, clear); KWin instead sends
leave with a fresh serial on `aboutToBeDestroyed` (keyboard.cpp:138-141,
pointer.cpp:96-101).
Expected: either behavior is defensible; the surface's client is the one destroying
it. Ours matches wlroots; KWin is stricter. Verified wired: main.zig:1572 calls
`seat.surfaceDestroyed(s)` before the entry is freed — the note-106 UAF is closed.
Class: OK (documented divergence vs KWin).

### F13 — KWin-style Repeated key state (v10) absent (LOW)
Ours: no repeat generation at all (repeat_info 0,0, seat.zig:515).
Reference: protocol v10 adds `key_state.repeated` (wayland.xml:2653-2666, 2690-2693);
KWin sends it and sets repeat rate 0 for v10+ clients (keyboard.cpp:44-47, 150-168).
Why it matters: only relevant after F4's version bump; server-side repeat would be a
new feature (timer), not a fix.
Class: FIXABLE-in-module (after F4) / out of scope for the current gate.

---

## 4. Fixability summary

- FIXABLE-in-module: F1 (wire keycode −8), F4 (version bump + v120 + repeat_info),
  F5 (double-buffer position/restack via existing onParentCommit seam), F6 (unmap on
  destroy/parent-death), F7 (axis_source/frame batching), F8 (motion dedup), F9
  (set_cursor role + focused-client checks), F11 (teardown leave), F13 (repeat state).
- NEEDS-wiring: F2 (per-client serial ringset + seat.validateEventSerial consumed by
  data_device.zig:327/363), F10 (keymap-change broadcast + group tracking).
- STRUCTURAL: F3 (grab layer: interface + default grab + routing seam; implicit click
  grab serial; touch either fully implemented or inert-with-error like smithay).

Suggested order: F1 (wire correctness, one-line) → F9 (authority hole) → F4 (version)
→ F2's grab_serial prerequisite → F3 (grab system) → F5/F6 (subsurface contract) →
F7/F8/F10/F11/F13.

## 5. Explicit OK areas (parity confirmed, current state)

- Event delivery is focused-client-only everywhere: motion, button, axis, key,
  modifiers, enter/leave, late-enter-on-bind (seat.zig:225-227, 259-268, 296-317,
  322-346, 380-394, 436-476, 517-552) — note-106 gap 2 RESOLVED; matches wlroots
  (wlr_seat_pointer.c:246-268, wlr_seat_keyboard.c:67-84) and smithay
  (pointer.rs:296-306, keyboard.rs:308-319).
- Modifiers follow enter on focus change AND on late bind (seat.zig:337-342, 517-527;
  test seat.zig:970-995) — note-106 gap 1 RESOLVED; matches wlroots
  wlr_seat_keyboard.c:291,459-460 and smithay keyboard.rs:78-93.
- axis_stop gated on value == 0 and axis gated on value != 0 for v5+ (seat.zig:
  305-313); matches wlroots wlr_seat_pointer.c:363-391 and smithay pointer.rs:159-173,
  214-228 — note-106 gap 7 RESOLVED.
- Focus lifetime: `surfaceDestroyed` wired at main.zig:1572; both focus pointers
  cleared before the Surface frees (seat.zig:431-434) — note-106 gap 11 RESOLVED.
- xkb: memfd keymap with correct size + lseek-0 (xkb.zig:107-126), dup-per-send
  (xkb.zig:162-164) equivalent to wlroots' shared-fd send; updateKey/keysym/mods
  mirror the wlroots call pattern (wlr_keyboard.c:110-129); tests cover keysym +
  modifier resolution (xkb.zig:190-212).
- Subsurface lifecycle: both destroy directions teardown the wl_subsurface
  synchronously (subsurface.zig:372-387, 462-475); registry removed before the
  Surface frees; tests assert no dangling listeners (subsurface.zig:604-636) —
  note-107 gap 4 RESOLVED.
- Subsurface sync: synced child commits are deferred via cached_state_locks
  (surface.zig:188-195, 420), flushed by the parent's commit / set_desync / teardown
  (subsurface.zig:397-417, 338-351) — note-107 gap 1 RESOLVED; tests cover defer,
  desync flush, parent-destroy flush and commit merging (subsurface.zig:638-736).
- Nesting allowed with cycle rejection (parentIsDescendant subsurface.zig:201-208;
  test subsurface.zig:757-779) — note-107 gap 5 RESOLVED; matches wlroots
  wlr_subcompositor.c:346-356 and smithay tree.rs:361-366.
- place_above/place_below: reference validated (parent or same-parent sibling, self
  and unrelated → bad_surface, subsurface.zig:318-334, 358-370), applied by the server
  inside the parent's scene tree with correct ordering (main.zig:2130-2162,
  2188-2223) — note-107 gap 2 and gap 9 RESOLVED; child no longer draws above every
  unrelated toplevel.
- Parent-map gating: children disabled when the parent's tree is gone (main.zig:
  2158-2160; unmap reparents to root disabled, main.zig:1774-1790) — note-107 gap 7
  RESOLVED behaviorally (child inside a disabled parent renders nothing).
- Seat tests: two-client focused-delivery + order assertions (seat.zig:888-963,
  968-1010) exercise the wire end to end.
