# cmp-seat-input — Seat / Input adversarial comparison (wl_seat + wl_keyboard + wl_pointer + wl_touch, xkb, cursor)

Area extends notes/132-seat-input-f2f.md. Prior audit fixed F1 (wire keycode scancode), F2 (per-client serial ring), F4 (v10 + value120/relative_direction), F5/F6/F7 (subsurface) and left F3 (grab layer, touch) deferred. This section adds NEW adversarial divergences the prior audit missed, centered on the implicit-grab routing, the v10 repeat wire contract, and the breadth table.

Our surface:
- `src/compositor/seat.zig` — wl_seat global (v10), wl_keyboard/wl_pointer state machines, serial ring, value120 accumulators, frame batching, server-side repeat, cursor surface, implicit pointer grab bool.
- `src/compositor/xkb.zig` — xkbcommon keymap/state, keymap memfd, modifier/group serialization.
- `src/compositor/cursor.zig` — cursor compositing (client cursor surface + fallback arrow).
- `src/backend/raylib_input.zig` — poll state machines feeding seat.keyEvent/pointerMotion/pointerButton/pointerAxis.
- wiring: `src/server/main.zig` (pointerFrame:1361, repeat timer:1962-1984, interactive move grab:939-976, camera drag grab:2006-2075, onSeatKey:1943-1973).

References read (line-level):
- wlroots types/seat/{wlr_seat,wlr_seat_keyboard,wlr_seat_pointer}.c (SEAT_VERSION 9 at wlr_seat.c:14; default grab impl wlr_seat_pointer.c:19-53; grab routing :563-620; set_capabilities :390-451; get_touch MISSING_CAPABILITY :53-66; selection-on-enter wlr_seat_keyboard.c:293).
- smithay src/wayland/seat/{mod,keyboard,pointer}.rs (global v9 mod.rs:175; inert get_touch mod.rs:281-297; serialize_pressed_keys keyboard.rs:168-170; repeat_info keyboard.rs:75-77; send_all_caps mod.rs:136-141).
- KWin src/wayland/{seat,keyboard,pointer}.cpp (rate 0 for v10+ keyboard.cpp:79-84; KEY_STATE_REPEATED keyboard.cpp:135-145,207-216; set_cursor focus+serial pointer.cpp:54-93; focusedSerial exact-match pointer.cpp:65-66; aboutToBeDestroyed→sendLeave keyboard.cpp:176-179, pointer.cpp:185-190).

## 1. Implemented surface

wl_seat (v10, name "default", capabilities keyboard+pointer), wl_keyboard, wl_pointer, a DEAD wl_touch, xkb state, and the compositor's own cursor. Implicit pointer grab = a single `pointer_grab` bool (seat.zig:110, setPointerGrab seat.zig:319-324) toggled by main.zig for camera drag (main.zig:2059) and xdg_toplevel.move (main.zig:963).

## 2. API breadth table

| interface | ours (version) | requests/events | wlroots 0.20.2 (v9) | smithay v0.7 (v9) | KWin master (v10) | gaps |
|---|---|---|---|---|---|---|
| wl_seat | v10 (seat.zig:61) | get_keyboard/get_pointer/get_touch/release; events capabilities,name(v2) | v9 (wlr_seat.c:14); + set_capabilities/set_name re-broadcast (wlr_seat.c:390-464) | v9 (mod.rs:175); add/remove caps (send_all_caps mod.rs:136-141) | v10 (seat.cpp:30) | no runtime capabilities/name change event; no touch capability; no MISSING_CAPABILITY error (wlroots-only) |
| wl_keyboard | v10 | keymap, enter, leave, key, modifiers, repeat_info(v4+) | keymap, enter, leave, key, modifiers, repeat_info, + re-broadcast on keymap/repeat change (wlr_seat_keyboard.c:87-111); selection on enter (:293) | same + selection/IME (keyboard.rs:75-91,256-260) | v10 adds key_state "repeated" (keyboard.cpp:135-145,207-216); rate 0 for v10 (keyboard.cpp:79-84) | KEY_STATE_REPEATED absent (F1); selection not re-sent on focus (F4) |
| wl_pointer | v10 | enter, leave, motion, button, axis, axis_source(v5+), axis_discrete, axis_stop(v5+), axis_value120(v8+), axis_relative_direction(v9+), frame(v5+) | all (wlr_seat_pointer.c) | all (pointer.rs) | all + frame per batch | breadth matches | grab routing of axis/button (F2) |
| wl_touch | v10 | release only (dead) | full touch + grabs (wlr_seat.c:53-66, wlr_seat_touch.c) | touch (touch.rs) | touch (seat.cpp:912-1039) | touch unimplemented (F3) |
| xkb | — | keymap memfd, state, modifiers+group, keysym | wlr_keyboard state+mods (wlr_keyboard.c) | xkbcommon (input/keyboard) | xkbcommon | none material |
| cursor | — | client cursor surface + hotspot, fallback arrow | request_set_cursor signal + compositor renders | cursor_image callback | hotspot /(serverScale·clientScale) (pointer.cpp:90) | hotspot ignores scale (F6) |

Version gating is correct for the events we do send: axis_value120 at v8+, axis_relative_direction at v9+, axis_source/discrete/stop at v5+, frame at v5+, repeat_info at v4+, name at v2+ (verified against vendored wayland.xml in prior audit). The gaps are semantic, not per-event version gates.

## 3. Adversarial correctness findings

### F1 — v10 advertised but the repeat wire contract is broken: non-zero rate + repeats sent as `pressed`, never `repeated` (MAJOR)
- Ours: `seat_version = 10` (seat.zig:61); repeat_info advertises rate 25 (Options default seat.zig:179, sent seat.zig:1175); repeated keys are re-fed through keyEvent which sends `key_state = pressed` (seat.zig:913, `kbd.sendKey(..., .pressed)` seat.zig:923 via onRepeatTick seat.zig:944-947).
- Reference: KWin at v10 sends repeat_info rate **0** for v10+ clients (keyboard.cpp:79-84) precisely because v10 adds `KEY_STATE_REPEATED`; KWin emits repeats with that state, gated on version>=10 (keyboard.cpp:207-216). wlroots (v9) and smithay (v9) send pressed-state repeats with rate 25/600 — correct for a v9 seat, but we advertise v10, so a protocol-correct v10 client is expected.
- Why it matters: a v10-aware client reads rate 25, disables its own repeat timer, and branches on `key_state==repeated` to avoid re-running one-shot actions or to let an input method filter repeats (the KWin comment keyboard.cpp:136-138). Our repeats arrive as `pressed` → the client double-processes or the IME misfilters. A client that ignores repeat_info and repeats itself gets doubled repeats. Advertising a capability (v10) we do not honor is a spec-contract violation.
- Severity: **major**. Fix: send rate 0 to v10 resources and emit `KEY_STATE_REPEATED` on repeats, or drop seat_version to 9 (wlroots/smithay parity).

### F2 — the implicit pointer grab leaks axis and button-release to the focused client (MAJOR)
- Ours: the grab is a bool checked only in pointerMotion (seat.zig:206) and for press suppression in pointerButton (`if (!self.pointer_grab or !pressed)` seat.zig:653 — a RELEASE is always delivered). `pointerAxisDir` (seat.zig:714 onward) **never checks pointer_grab**: during a camera drag or interactive move, a wheel scroll is still delivered to the last-focused client (scrolling the terminal while panning the canvas).
- Reference: wlroots routes motion/button/axis through `grab->interface` (wlr_seat_pointer.c:563-620; notify_motion/notify_button/notify_axis all call the grab). The default grab forwards (default_pointer_motion/button/axis, wlr_seat_pointer.c:19-53), but an active interactive-move grab uses its OWN handlers that swallow all three — the client under the pointer sees none of them for the duration. reset_buttons on focus switch (wlr_seat_pointer.c:545-563) also clears the client's notion of held buttons across a grab focus.
- Why it matters: (a) axis reaching a client during a grab is visible wrong behavior — the client scrolls under a pan gesture wlroots would suppress; (b) a release delivered for a button whose press was suppressed leaves the client in a state it never entered (a second-button press mid-drag is suppressed, its release delivered). Both differ from wlroots/KWin/smithay grab semantics.
- Severity: **major**. Fix: route axis (and release) through the same grab gate as motion; a grab should suppress all three delivery types.

### F3 — wl_touch is a live dead object, no MISSING_CAPABILITY error, no runtime capabilities/name broadcast (MED)
- Ours: get_touch creates a wl_touch that never errors and never emits (seat.zig:1217-1225); touchRequest handles only release (seat.zig:1249-1253). bindSeat sends capabilities exactly once (seat.zig:1147-1150); no API to change capabilities/name, no re-broadcast.
- Reference: wlroots posts `WL_SEAT_ERROR_MISSING_CAPABILITY` when get_touch/get_keyboard/get_pointer is called for a capability that never existed (wlr_seat.c:53-66, 26-48), and wlr_seat_set_capabilities re-sends wl_seat.capabilities on change, inerts resources when a capability is removed (wlr_seat.c:390-451). smithay deliberately returns an inert handle ("should error but cannot", mod.rs:293-297) but supports runtime capability changes (send_all_caps mod.rs:136-141). KWin sends capabilities on bind and on change.
- Why it matters: a client that probes for touch (e.g. a touch-first app on a device it assumes has one) holds a live wl_touch that never delivers down/motion/up/cancel — it waits forever on a capability the seat never announced. And the absence of a capabilities-change path means touch can never be added at runtime and existing clients never learn of any change.
- Severity: **medium** (touch absence is documented; the live-dead-object non-error is a client trap).

### F4 — data_device.selection is not re-sent on keyboard focus change (MED, cross-area)
- Ours: setKeyboardFocus sends leave/enter/modifiers but never re-delivers the current selection (seat.zig:319-350).
- Reference: wlroots calls `seat_client_send_selection(client)` after modifiers on keyboard enter (wlr_seat_keyboard.c:293); smithay's enter_internal notifies text_input on focus (keyboard.rs:256-260).
- Why it matters: a newly-focused client never learns the current clipboard; paste reports nothing until the next set_selection. (Seat-side source of a selection bug; CmpSelection may partly cover the data-device side.)
- Severity: **medium**.

### F5 — no per-button pressed-count / grab_serial; start_drag validation is ring-only (MED, structural — extends prior F3)
- Ours: pointerButton tracks only last_button (seat.zig:645-670); no button_count/grab_button/grab_serial; start_drag validation uses validateEventSerial only.
- Reference: wlr_seat_pointer_notify_button maintains per-button n_pressed and mints grab_serial when button_count becomes 1 on press (wlr_seat_pointer.c:481-517); wlr_seat_validate_pointer_grab_serial requires button_count==1 AND grab_serial match AND focused_surface==origin (wlr_seat_pointer.c:601-617). smithay tracks last_enter; KWin validates drags against per-button serials + hasImplicitPointerGrab (seat.cpp:1063-1071).
- Why it matters: a client can start a drag with a key serial or a stale pointer serial; wlroots requires the exact press serial with exactly one button held and the focus on the drag origin. DnD/xdg_activation validation is weaker than every reference.
- Severity: **major** (structural; deferred from prior F3).

### F6 — cursor hotspot ignores output scale (INFO)
- Ours: cursor.zig positions at `x - hotspot` unscaled (cursor.zig:226-228, 322-324).
- Reference: KWin divides the hotspot by serverScale·clientToCompositorScale (pointer.cpp:90). wlroots stores hotspot and lets the compositor scale. With no fractional-scale support in this library today the effect is nil, but it is a latent contract gap for scaled outputs.
- Severity: **info**.

### F7 — repeat first-tick jitter: timer armed at delay, tick may skip and re-arm at rate (MINOR)
- Ours: main.zig arms the timer at key_repeat_delay (main.zig:1963); onRepeatTick re-emits only when `now >= repeat_next_at` (seat.zig:947) but the main wrapper re-arms at repeatIntervalMs regardless (main.zig:1983). A tick that fires marginally early skips the emission yet advances the deadline by a full interval → first repeat lands at delay+interval.
- Reference: wlroots leaves repeat timing entirely to the compositor (no canonical timer); no reference constraint, but the timing is off vs the advertised delay.
- Severity: **minor**.

### F8 — set_cursor serial scope is ring-wide, broader than KWin's exact-focusedSerial (INFO, deliberate)
- Ours: set_cursor validates against the client's serial ring (seat.zig:583-600) — any recently-handed serial qualifies.
- Reference: KWin requires the exact enter serial (focusedSerial, pointer.cpp:65-66); wlroots validates over the ring at the compositor's discretion (wlr_seat_pointer.c:85-113). Ours matches wlroots, is looser than KWin (a button serial could drive set_cursor).
- Severity: **info** (matches the majority reference).

Positive confirmations vs the references (not divergences): wire keycodes are evdev scancodes with xkb+8 internal (F1 fixed); per-client serial ring with half-range wrap (F2 fixed); modifiers+group sent after enter (wlr_seat_keyboard.c:291, smithay keyboard.rs:83-89); axis_stop only on value==0; value120 only for v8+, accumulated axis_discrete for <v8; motion fixed-point dedup with re-arm on enter; xkb state updated for every key regardless of focus; pressed keys delivered in scancode space on enter and on late bind; re-armed surface-destroy listeners clear focus with leave before the Surface frees (KWin aboutToBeDestroyed parity).

## 4. Verdict

**Breadth**: wl_keyboard and wl_pointer event coverage is complete for their advertised versions (v10 gating correct); the two real breadth holes are wl_touch (unimplemented, live dead object) and the absence of any runtime capabilities/name change broadcast. **Correctness**: the two load-bearing divergences are both in the seat/input interaction model — the v10 repeat wire contract (rate must be 0 + KEY_STATE_REPEATED for v10 clients) and the implicit-grab routing (axis and release must be swallowed during a grab, as wlroots' interactive-move grab does). Both are fixable in-module. The selection-on-focus gap and the ring-only drag-serial validation are the remaining medium items; the former is the seat-side root of a paste bug, the latter a DnD hardening item carried from the prior F3.
