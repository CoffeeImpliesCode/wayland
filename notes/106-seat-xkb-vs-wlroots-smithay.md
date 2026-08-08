# Seat / Xkb — wlroots/smithay diff

Scope: `src/compositor/seat.zig` (438 lines), `src/compositor/xkb.zig` (227 lines) vs
wlroots 0.20.2 `types/seat/wlr_seat.c`, `types/seat/wlr_seat_keyboard.c`,
`types/seat/wlr_seat_pointer.c`, `types/wlr_keyboard.c`, `types/wlr_pointer.c`,
`include/wlr/types/wlr_seat.h`, `include/wlr/types/wlr_keyboard.h`;
smithay 0.7.0 `src/wayland/seat/{mod.rs,keyboard.rs,pointer.rs,touch.rs}`,
`src/input/mod.rs`, `src/input/keyboard/mod.rs`, `src/input/pointer/mod.rs`.

Both references sit at wl_seat protocol version 9 (wlroots `types/seat/wlr_seat.c:14`
`#define SEAT_VERSION 9`; smithay creates the global at version 9,
`src/wayland/seat/mod.rs:175`). Ours is 7 (`seat.zig:37`).

## Surface

`src/compositor/seat.zig`:
- `pub const seat_version: u32 = 7` (seat.zig:37)
- `pub const capabilities_keyboard: u32 = 1` (seat.zig:39)
- `pub const capabilities_pointer: u32 = 2` (seat.zig:40)
- `pub const btn_left/btn_right/btn_middle` (seat.zig:43-45)
- `pub const Seat` (seat.zig:47)
- `pub const PickResult` (seat.zig:108)
- `Seat.init` (seat.zig:114)
- `Seat.deinit` (seat.zig:146)
- `Seat.setPick` (seat.zig:158)
- `Seat.pointerMotion` (seat.zig:169)
- `Seat.pointerButton` (seat.zig:193)
- `Seat.pointerAxis` (seat.zig:209)
- `Seat.setKeyboardFocus` (seat.zig:224)
- `Seat.keyEvent` (seat.zig:244)
- `Seat.cursorSurface` (seat.zig:288)
- `Seat.mod4Active` (seat.zig:295)
- private: `pointerEnter` (seat.zig:299), `pointerLeave` (seat.zig:318), `nowMs`
  (seat.zig:331), `bindSeat` (seat.zig:340), `seatRequest` (seat.zig:350),
  `touchRequest` (seat.zig:408), `keyboardRequest` (seat.zig:415),
  `pointerRequest` (seat.zig:422)

`src/compositor/xkb.zig`:
- `pub const keysym_escape: u32 = 0xff1b` (xkb.zig:15)
- `pub const Keycode = u32` (xkb.zig:65)
- `pub const Xkb` (xkb.zig:69)
- `Xkb.init` (xkb.zig:86)
- `Xkb.deinit` (xkb.zig:150)
- `Xkb.dupKeymapFd` (xkb.zig:162)
- `Xkb.updateKey` (xkb.zig:168)
- `Xkb.keysym` (xkb.zig:173)
- `Xkb.mods` (xkb.zig:179)

## Comparison

### seat.zig

**`Seat.init`** — build the "us" xkb keymap, register the wl_seat global at
version 7 with keyboard+pointer capabilities, init event signals.
- wlroots: `wlr_seat_create` `include/wlr/types/wlr_seat.h:354` (impl
  `types/seat/wlr_seat.c:337`); global at SEAT_VERSION 9; name param; no built-in
  xkb; capabilities set later via `wlr_seat_set_capabilities` (wlr_seat.h:370).
- smithay: `Seat::new_wl_seat` `src/wayland/seat/mod.rs:166`; global v9 at
  mod.rs:175; devices added separately — `add_pointer` `src/input/mod.rs:452`,
  `add_keyboard` (xkb_config + repeat_delay) `src/input/mod.rs:585`,
  `add_touch` `src/input/mod.rs:678`.
- verdict: close. Ours fuses seat creation with capabilities and keymap; both
  refs decouple seat, capabilities and devices.

**`Seat.deinit`** — remove global, free keyboard/pointer/pressed lists, xkb, seat.
- wlroots: `wlr_seat_destroy` wlr_seat.h:359 — clears pointer/keyboard focus
  (leave events) and touch points for all clients before freeing.
- smithay: per-device `remove_pointer`/`remove_keyboard`/`remove_touch`
  `src/input/mod.rs:477/636/716`; no whole-seat destroy.
- verdict: close. Ours sends no leave/clear on teardown.

**`Seat.setPick`** — register the compositor hit-test callback (output coords →
surface + local coords).
- wlroots: N/A — the seat has no pick callback; the compositor runs its own
  hit-test and feeds `wlr_seat_pointer_notify_enter`/`notify_motion`
  (wlr_seat.h:441-462).
- smithay: N/A — the compositor passes focus into `PointerHandle::motion`
  `src/input/pointer/mod.rs:232` and `KeyboardHandle::set_focus`
  `src/input/keyboard/mod.rs:1194`.
- verdict: ours-only. Design choice: ours owns hit-testing inside the seat;
  refs leave it to the compositor.

**`Seat.pointerMotion`** — hit-test; enter/leave on focus change; send
motion+frame to ALL pointer resources; emit `pointer_move`.
- wlroots: `wlr_seat_pointer_send_motion` `types/seat/wlr_seat_pointer.c:246-268`
  — sends only to the focused client's resources; dedups identical fixed-point
  positions (wlr_seat_pointer.c:252-263); routed through the grab
  (`wlr_seat_pointer_notify_motion` wlr_seat.h:461).
- smithay: `WlPointerHandle::motion` `src/wayland/seat/pointer.rs:106-120` —
  gated per client via `for_each_focused_pointer` (pointer.rs:296-306), scaled
  by client_scale.
- verdict: divergent. Fan-out delivers motion to clients whose surface is not
  focused (protocol violation with 2+ clients); no dedup; no grab.

**`Seat.pointerButton`** — press moves keyboard focus to the pointer target
(click-to-focus); send button+frame to ALL pointer resources; emit `button`.
- wlroots: `wlr_seat_pointer_send_button` `types/seat/wlr_seat_pointer.c:274-295`
  — focused client only; records `grab_button`/`grab_serial` on press
  (wlr_seat_pointer.c:511-518) and returns the serial for grab validation.
- smithay: `PointerHandle::button` `src/input/pointer/mod.rs:271` — installs the
  implicit click grab (`SeatHandler::click_grab` `src/input/mod.rs:177-179`).
- verdict: divergent. Fan-out again; no implicit grab; no grab serial. Click-to-
  focus is a hardcoded policy in ours; refs leave focus policy to the compositor.

**`Seat.pointerAxis`** — send axis_source(.wheel), axis_discrete, axis_stop
UNCONDITIONALLY, then axis, then frame; to ALL pointer resources.
- wlroots: `wlr_seat_pointer_send_axis` `types/seat/wlr_seat_pointer.c:321-392` —
  axis_stop only when value == 0 (wlr_seat_pointer.c:389-391); axis only when
  value != 0 (363-388); value120 + low-res accumulator for clients < v8
  (`update_value120_accumulators` 288-318); relative_direction for v9.
- smithay: `WlPointerHandle::axis` `src/wayland/seat/pointer.rs:126-232` —
  axis_stop only on the explicit stop flag (pointer.rs:159-173); axis only when
  value != 0.0 (214-228); v120 accumulation for < v8 (135-158); per-client scale.
- verdict: divergent. Unconditional axis_stop makes every wheel event look like
  scroll-end; no v120 accumulation; no relative_direction; source hardcoded.

**`Seat.setKeyboardFocus`** — leave old, enter new surface with pressed keys to
ALL keyboards; no modifiers after enter; emit `keyboard_focus`.
- wlroots: `wlr_seat_keyboard_enter` `types/seat/wlr_seat_keyboard.c:234-311` —
  leave to the old focused client's keyboards (246-249), enter to the new
  focused client's keyboards (253-273), THEN `wlr_seat_keyboard_send_modifiers`
  to the focused client (291); re-arms surface-destroy listeners (276-287).
- smithay: `enter_internal` `src/wayland/seat/keyboard.rs:207-261`; modifiers
  after enter at keyboard.rs:82-87 with the comment "Modifiers must be send
  after enter event".
- verdict: divergent. (a) fan-out sends enter/leave for surfaces the client may
  not own; (b) missing the post-enter modifiers event that both refs send.

**`Seat.keyEvent`** — update xkb state; bookkeep pressed set; broadcast
modifiers (group=0) to ALL keyboards on change; send key to ALL keyboards when
focus exists; emit `key`.
- wlroots: `wlr_keyboard_notify_key` `types/wlr_keyboard.c:110-129` →
  `wlr_seat_keyboard_notify_key` `types/seat/wlr_seat_keyboard.c:333-336` →
  grab → `wlr_seat_keyboard_send_key` (67-84) — focused client only; modifiers
  with group (215-217).
- smithay: `KeyboardHandle::input` `src/input/keyboard/mod.rs:1026-1089` —
  filter/intercept API then `input_forward` (1151-1189) to the focused client;
  `serialized.layout_effective` in modifiers (keyboard.rs:84-93).
- verdict: divergent. Fan-out; group always 0 (no layouts); no repeat; input
  filter/keysym callback API absent (ours exposes a plain event signal).

**`Seat.cursorSurface`** — return the client cursor surface resource (with
hotspot) for compositor rendering.
- wlroots: N/A as an accessor — the seat only emits the `request_set_cursor`
  signal (`types/seat/wlr_seat_pointer.c:106-113`); the compositor validates
  the serial with `wlr_seat_validate_pointer_grab_serial` (wlr_seat.h:719-720,
  impl wlr_seat_pointer.c:603-613).
- smithay: N/A — `SeatHandler::cursor_image` callback `src/input/mod.rs:162-165`;
  serial/client/grab check in `allow_setting_cursor`
  `src/wayland/seat/pointer.rs:515-537`.
- verdict: ours-only shape, close semantics. Ours applies on
  `serial == pointer_enter_serial` (seat.zig:429) but lacks cursor-surface role
  enforcement (wlroots `pointer_cursor_surface_role` wlr_seat_pointer.c:85-90;
  smithay `CURSOR_IMAGE_ROLE` + role error pointer.rs:38, 380-386) and grab
  allowance.

**`Seat.mod4Active`** — true when bit 6 (Mod4) depressed; used for the
Mod4+Escape quit binding.
- wlroots: N/A — compositor binds keys via `wlr_keyboard` events.key/modifiers
  signals (`types/wlr_keyboard.c:113-127`) or `wlr_keyboard_get_modifiers`
  (wlr_keyboard.h:159) which maps through keymap mod_indexes (229-248, 298-313).
- smithay: N/A — `KeyboardHandle::modifier_state` `src/input/keyboard/mod.rs:1230`
  and `with_pressed_keysyms` (1210-1227) feed compositor bindings.
- verdict: ours-only. Semantics equivalent; ours hardcodes the Mod4 bit instead
  of resolving modifier indexes from the keymap.

**`bindSeat` (impl)** — on global bind send capabilities + name (v2).
- wlroots: `seat_handle_bind` `types/seat/wlr_seat.c:172-200` — capabilities +
  name, plus per-client `wlr_seat_client` bookkeeping (clients list, resource
  lists per device) used for event gating.
- smithay: `SeatGlobalData::bind` `src/wayland/seat/mod.rs:317-346` — name (v2)
  + capabilities from `compute_caps` (mod.rs:122-134).
- verdict: close. Ours has no per-client seat_client state (no per-client
  resource lists, no per-client serials).

**`get_keyboard` (impl)** — create wl_keyboard; send keymap (memfd dup),
repeat_info(0,0), and enter if focus exists — no modifiers.
- wlroots: `seat_client_create_keyboard` `types/seat/wlr_seat_keyboard.c:399-463`
  — keymap, repeat_info, enter + modifiers to the focused client (459-460);
  capability check makes the resource inert (411-413); keymap sends the shared
  fd (seat_client_send_keymap 339-377).
- smithay: `KeyboardHandle::new_kbd` `src/wayland/seat/keyboard.rs:59-98` —
  keymap via tempfile, repeat_info from stored rate/delay (75-77), enter +
  modifiers (78-93).
- verdict: divergent. repeat_info hardcoded 0,0 vs wlroots default 25/600
  (`types/wlr_keyboard.c:140-141`) and smithay's add_keyboard repeat_delay
  (input/mod.rs:585-588); missing post-enter modifiers; no inert path.

**`get_pointer` (impl)** — create wl_pointer; late enter+frame if focus exists.
- wlroots: `seat_client_create_pointer` `types/seat/wlr_seat_pointer.c:543-570`
  — same late-enter; capability check makes the resource inert (555-557);
  `request_set_cursor` signal on set_cursor (85-113).
- smithay: `Request::GetPointer` `src/wayland/seat/mod.rs:239-262` — inert
  handle when no pointer device (comment: "should send a protocol error... but
  cannot", 258-260).
- verdict: close. Late-enter matches; ours lacks cursor-role enforcement.

**`get_touch` (impl)** — create a dead wl_touch object (never advertised, no
events, only release works).
- wlroots: `seat_handle_get_touch` `types/seat/wlr_seat.c:53-66` — posts
  `WL_SEAT_ERROR_MISSING_CAPABILITY`; touch is fully implemented (touch points,
  grabs: wlr_seat.h:596-714).
- smithay: `Request::GetTouch` `src/wayland/seat/mod.rs:263-290` — inert
  `TouchUserData` with handle=None; touch fully implemented (touch.rs,
  `TouchHandle` `src/input/mod.rs:678`).
- verdict: divergent. A dead object traps the client: it holds a live resource
  that never errors and never delivers. Refs either error (wlroots) or hand
  back an inert handle (smithay).

**`set_cursor` (impl)** — apply when serial matches last enter or pointer
unfocused; store surface + hotspot.
- wlroots: `pointer_set_cursor` `types/seat/wlr_seat_pointer.c:85-113` —
  enforces the cursor surface role (85-90), then emits `request_set_cursor`;
  serial validation is the compositor's via grab-serial helper (wlr_seat.h:719).
- smithay: `Request::SetCursor` `src/wayland/seat/pointer.rs:366-431` —
  `allow_setting_cursor` (515-537: last_enter serial match OR same-client grab,
  plus focus client check); role error posted (380-386).
- verdict: close. Ours adds the pointer-unfocused allowance; both refs require
  a matching enter serial or an active grab, and enforce the role.

### xkb.zig

**`Xkb.init`** — xkb_context_new + keymap_new_from_names("us") + state_new;
keymap text via get_as_string into a memfd (write + lseek, no mmap).
- wlroots: keymap built by the compositor and installed via
  `wlr_keyboard_set_keymap` `types/wlr_keyboard.c:204-283` — shm-file pair +
  mmap write (214-220), `xkb_keymap_ref`, led_indexes (221-228) and
  mod_indexes (229-248), replay of pressed keys into state (243-246).
- smithay: `Seat::add_keyboard_with_context_flags` `src/input/mod.rs:604` with
  `XkbConfig` compile (input/keyboard/mod.rs:906-909); Xkb wrapper owns
  context/keymap/state (input/keyboard/mod.rs:136-190).
- verdict: close. Same core FFI calls; ours fixes one "us" layout, no keymap
  swap, no mod/led index mapping, no shm-file pair.

**`Xkb.deinit`** — close fd, free keymap string, unref state/keymap/context.
- wlroots: `keyboard_unset_keymap` `types/wlr_keyboard.c:154-166`.
- smithay: Rust ownership drop of Xkb (input/keyboard/mod.rs:136-145).
- verdict: same.

**`Xkb.dupKeymapFd`** — dup the memfd for each wl_keyboard.keymap send.
- wlroots: `seat_client_send_keymap` `types/seat/wlr_seat_keyboard.c:339-377` —
  sends the shared keymap_fd (no dup; kernel dups per client over the socket).
- smithay: `keymap_file.send(&kbd)` `src/wayland/seat/keyboard.rs:66-68` —
  tempfile dup per send.
- verdict: same. Ours dups eagerly, which is equivalent.

**`Xkb.updateKey`** — xkb_state_update_key then keysym lookup.
- wlroots: `keyboard_key_update` `types/wlr_keyboard.c:69-96` — pressed-set
  bookkeeping + `xkb_state_update_key` (243-246); events.key emitted
  (110-114).
- smithay: `KbdInternal::key_input` `src/input/keyboard/mod.rs:305-352` —
  per-source pressed-key tracking, xkb update, mods/leds change detection.
- verdict: close. Ours also keeps a pressed set but only for the enter payload;
  no per-source tracking (no virtual keyboards/aux sources).

**`Xkb.keysym`** — xkb_state_key_get_one_sym.
- wlroots: same call pattern used by compositors; keysym helpers
  `wlr_keyboard_keysym_to_pointer_button`/`motion` (wlr_keyboard.h:126-135).
- smithay: `KeysymHandle::modified_sym` `src/input/keyboard/mod.rs:481-483`.
- verdict: same.

**`Xkb.mods`** — serialize depressed/latched/locked (no group).
- wlroots: `keyboard_modifier_update` `types/wlr_keyboard.c:41-66` +
  `wlr_keyboard_get_modifiers` (298-313) — wl-mask computed via keymap
  mod_indexes; group tracked in `wlr_keyboard_modifiers` and sent
  (wlr_seat_keyboard.c:215-217).
- smithay: `ModifiersState` serialized incl. `layout_effective`
  (keyboard.rs:84-93; input/keyboard/mod.rs:553-560).
- verdict: close. `xkb_state_serialize_mods` yields the same bit layout as the
  refs' masks; ours drops the group field (always 0) and never remaps indexes.

## Gaps

1. **No modifiers after enter.** wlroots sends modifiers to the newly focused
   client right after enter (`types/seat/wlr_seat_keyboard.c:291`, and on bind
   459-460); smithay does the same (`src/wayland/seat/keyboard.rs:82-87`).
   Ours sends enter only in `setKeyboardFocus` (seat.zig:232-237) and
   `get_keyboard` (seat.zig:369-372). A client that resets state on enter is
   left with stale modifier state.
2. **Fan-out to all seat resources instead of the focused client.** Every event
   path loops over all resources: motion (seat.zig:183-187), button
   (seat.zig:199-202), axis (seat.zig:211-218), keyboard enter/leave
   (seat.zig:227-237), key (seat.zig:280-282), modifiers (seat.zig:253-262).
   Both refs deliver only to the focused client's resources
   (wlr_seat_pointer.c:325-345, wlr_seat_keyboard.c:67-84; smithay
   pointer.rs:296-306, keyboard.rs:308-319). With 2+ clients this sends
   enter/leave/motion/key for surfaces a client does not own — a protocol
   violation.
3. **No grab system.** wlroots has pointer/keyboard/touch grab structs
   (`include/wlr/types/wlr_seat.h:120-220`) with start/end/has
   (wlr_seat.h:491-503, 581-593, 702-714); smithay has `PointerGrab`/
   `KeyboardGrab`/`TouchGrab` traits and set_grab/unset_grab
   (`src/input/pointer/mod.rs:168-178`, `src/input/keyboard/mod.rs:961-970`).
   Ours has no grab concept — no implicit click grab, no path for popup grabs
   or drag-and-drop.
4. **Touch is a dead object.** `get_touch` (seat.zig:395-405) creates a
   resource that never errors and never emits. wlroots posts
   `WL_SEAT_ERROR_MISSING_CAPABILITY` (`types/seat/wlr_seat.c:62-66`) and
   implements touch fully; smithay returns an inert handle
   (`src/wayland/seat/mod.rs:263-290`) and implements touch fully
   (`src/wayland/seat/touch.rs`, `TouchHandle` input/mod.rs:678).
5. **No MISSING_CAPABILITY error posting.** wlroots posts it for
   get_pointer/get_keyboard/get_touch (`types/seat/wlr_seat.c:26-66`, gated on
   `accumulated_capabilities`). smithay deliberately does not
   (mod.rs:258-260 comment). Ours silently creates dead objects for all three.
6. **repeat_info 0,0.** seat.zig:368 sends `repeat_info(0, 0)` (no server-side
   repeat). wlroots default is 25/600 (`types/wlr_keyboard.c:140-141`) and
   re-broadcasts on change (`wlr_seat_keyboard.c:100-108`, 379-397); smithay
   takes repeat_delay at `add_keyboard` (input/mod.rs:585-588) and supports
   `change_repeat_info` (input/keyboard/mod.rs:1322-1325). Clients that rely on
   compositor repeat get none.
7. **axis_stop sent unconditionally.** seat.zig:213-215 sends axis_stop with
   every wheel event. wlroots sends it only when value == 0
   (`wlr_seat_pointer.c:389-391`); smithay only on the explicit stop flag
   (`pointer.rs:159-173`). Related: ours sends axis for value 0 too, where both
   refs gate on value != 0 (wlr_seat_pointer.c:363-388; pointer.rs:214-228);
   and ours lacks v120 accumulation for < v8 clients and relative_direction.
8. **seat_version 7 vs 9.** seat.zig:37 vs `wlr_seat.c:14` and
   `src/wayland/seat/mod.rs:175`. Missing client-visible events:
   `wl_pointer.axis_value120` (v8) and `wl_pointer.axis_relative_direction`
   (v9). (v7's wl_touch.frame is moot — touch is dead.)
9. **No pointer motion dedup.** wlroots drops duplicate fixed-point positions
   (`wlr_seat_pointer.c:252-263`); ours re-sends every motion (seat.zig:183-186).
10. **set_cursor validation is weaker.** Ours checks only
    `serial == pointer_enter_serial` (seat.zig:429). wlroots additionally
    enforces the cursor role (wlr_seat_pointer.c:85-90) and lets the compositor
    require a grab serial (wlr_seat.h:719-720); smithay checks last_enter serial
    or same-client grab (pointer.rs:515-537).
11. **No focused-surface destroy handling.** wlroots re-arms surface_destroy
    listeners on every focus change and clears focus when the surface dies
    (`wlr_seat_keyboard.c:276-287`; `wlr_seat_pointer.c:210-225`). seat.zig has
    no destroy listener for either focus. If a focused surface is destroyed
    without a preceding focus change, `keyboard_focus`/`pointer_focus` dangle
    [INFERENCE — no seat-side cleanup found in seat.zig or surface.zig].
12. **xkb is a minimal FFI subset.** Ours binds 7 extern fns (xkb.zig:24-40).
    wlroots uses the full xkbcommon API: keymap ref/swap
    (wlr_keyboard.c:204-283), keymap comparison `wlr_keyboard_keymaps_match`
    (wlr_keyboard.h:118), mod_indexes/led_indexes mapping (229-248),
    `wlr_keyboard_get_modifiers` (298-313), `wlr_keyboard_led_update`
    (wlr_keyboard.h:152), keysym→pointer helpers (wlr_keyboard.h:126-135).
    smithay wraps xkbcommon with layouts, LedMapping, XkbContext
    set_layout/cycle, KeysymHandle raw/modified syms, inject_text_keysyms
    (input/keyboard/mod.rs:136-190, 458-547, 551-615, 1374-1440).
13. **No keymap change path.** wlroots re-sends the keymap to all clients on
    `wlr_keyboard_set_keymap` (`wlr_seat_keyboard.c:110-120`); smithay has
    `set_keymap_from_string`/`set_xkb_config` (input/keyboard/mod.rs:888-918).
    Ours compiles once at init (seat.zig:114-120) and can never change layout,
    variant or rules at runtime.
14. **No layout group tracking.** Modifiers always carry group 0 (seat.zig:262);
    wlroots sends `modifiers->group` (wlr_seat_keyboard.c:215-217) and smithay
    `layout_effective` (keyboard.rs:84-93). Multi-layout keymaps and
    group-switch keys are unsupported.

## Verdict

Partial parity (~50%). The single-surface, single-client demo path works, but
the seat's event delivery is not protocol-correct: fan-out to all resources
(Gap 2) and the missing post-enter modifiers (Gap 1) are client-visible
violations, and the dead touch object (Gap 4) plus absent MISSING_CAPABILITY
errors (Gap 5) break the error contract. The riskiest divergences are the
fan-out broadcast, the unconditional axis_stop, and the complete absence of a
grab mechanism — the last one blocks any popup/drag-and-drop/overlay input
feature. The xkb wrapper is adequate for its single fixed layout but cannot
grow toward layout switching without adopting the refs' mod/led index mapping
and keymap-change broadcast.
