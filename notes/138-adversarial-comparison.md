# 138: Protocol-module adversarial comparison — ours vs wlroots 0.20.2 / smithay v0.7.0 / KWin master

Audit date: 2026-08-11. No code changed. Six parallel read-only comparisons
(one per protocol area), each against all three references (screencopy excepted:
smithay/KWin have none — compared against wlroots only). Working sections:
`local/cmp-*.md` (6 files, kept as raw evidence). Extends the per-area
face-to-face audits: notes/131 (core surface), 132 (seat/input), 133
(xdg/layer), 134 (selection/aux), 135 (output/backends), 129 series.

Reference line keys: `W:` = wlroots types/*.c, `S:` = smithay src/wayland/*.rs,
`K:` = KWin src/wayland/*.cpp, `O:` = ours.

Overall verdict: the wire surface is nearly complete — every request/event of
the advertised versions exists, and version choice is at or above reference
parity (compositor/surface v7 with a working get_release no reference has;
seat v10). The adversarial findings concentrate in three clusters:

1. **Lifetime/ownership bugs reachable from the wire** — 1 CRITICAL:
   viewporter UAF on wl_surface.destroy (F-AX-1); plus the subsurface
   destroyed-vs-inert divergence (C-CS-1) that disconnects a legal-order
   client.
2. **Missing compositor-facing hooks** — layer popup `new_popup` and
   xdg-decoration `new_toplevel_decoration` signals (L-D1, L-D2) all three
   refs expose; without them two consumption paths are unreachable.
3. **Advertised-version contract violations** — seat v10 repeat contract
   (rate must be 0 + KEY_STATE_REPEATED for v10 clients, S-F1), implicit grab
   leaking axis/release to clients (S-F2), wp_viewport single-buffering
   (F-AX-11).

Structural backlog items the refs close but ours cannot yet (already tracked):
popup grabs + reactive reconfigure + popup compositing (X04/X05), compositor-
driven configure (X08), DnD state machine (F-SEL-1), touch + grab layer
(S-F3/F5), real output-present event driving presentation (F-AX-2/F3).

## 1. Core surface / compositor / buffers / subcompositor / region

Ours: src/compositor/{compositor,surface,region,subsurface}.zig,
src/buffers/{buffer,shm}.zig, src/scene/surface_node.zig.

Breadth: complete request/event coverage at v7 for wl_compositor/wl_surface
(v7 get_release implemented — all three refs either cap at v6 or panic on it
[INFERENCE: smithay handlers.rs:339 unreachable]), v1 subcompositor, v2
libwayland-internal wl_shm. No gaps.

Findings:

- C-CS-1 [MAJOR] wl_subsurface destroyed on parent death instead of inert.
  O: subsurface.zig ~500-512, ~850 destroys the resource. W: keeps resource
  alive, nulls user_data (wlr_subcompositor.c:283-292, :222 — "becomes inert
  on parent surface destroy"); S/K keep the object too. Client destroying
  parent surface THEN its subsurface (legal order, spec wayland.xml:3288
  imposes none) hits a dead id → invalid-object protocol error → disconnect.
  Fix: keep resource, null role, ignore requests.
- C-CS-2 [MAJOR] Subsurface mapped state not coupled to parent mapped state.
  O: surface.zig applyCommit ~493-511 sets mapped on buffer+size alone; no
  recursive gate. W: subsurface_consider_map requires added && parent->mapped
  && has_buffer (wlr_subcompositor.c:237-256); K computeEffectiveMapped
  propagates recursively. Spec: child hidden when parent hidden
  (wayland.xml:3254-3258). Ours fires map/enter/present/frame_done for a
  hidden child — signaling violation; rendering coincidentally masked by the
  scene tree. Fix: gate child map/enter/present on the parent chain.
- C-CS-3 [MINOR] Rejected commit skips role.client_commit + client_commit
  signal (O surface.zig ~402-413); W runs them then checks pending_rejected
  (wlr_compositor.c:577-598). Sync-subsurface cache accounting diverges on
  rejected commits. [W's own ordering is arguably the bug; ours is cleaner.]
- C-CS-4 [MINOR] Surface/buffer damage never clipped to bounds before
  translation (O surface.zig ~715-740); W clips (wlr_compositor.c:243-258).
  Hostile unbounded damage retained/propagated — memory waste, no crash
  (saturating arithmetic + scene clip bound it).
- C-CS-5 [MINOR] current.buffer holds an unlocked ref across commits; W NULLs
  it each commit (wlr_compositor.c:570-574). Same client-visible release
  timing; latent footgun for consumers assuming lock-count liveness.
- C-CS-6 [INFO] Subsurface restack applied at frame-sync, only latest target
  retained (O main.zig applyRestack); W keeps an ordered list applied at
  parent commit. Sub-frame ordering difference for rapid restacks.
- C-CS-7 [INFO] get_release implemented; references omit or panic. Positive
  breadth delta.
- C-CS-8 [INFO] invalid_transform posted for out-of-range (O surface.zig
  ~676-683, matches W/K); smithay silently ignores. More spec-compliant.
- C-CS-9 [INFO] Non-divisible size is a hard error for any surface; W warns
  (not rejects) for pointer-cursor/tablet-cursor roles. No cursor surface
  role today; would diverge if added.

## 2. Seat / input / cursor / xkb

Ours: src/compositor/{seat,xkb,cursor}.zig, src/backend/raylib_input.zig,
src/server/main.zig wiring.

Breadth: wl_seat v10 (O seat.zig:61; W/S v9, K v10). wl_keyboard/wl_pointer
event coverage complete with correct per-event version gating. Holes: wl_touch
unimplemented (live dead object), no runtime capabilities/name broadcast.
Cursor: client surface + hotspot + fallback arrow.

Findings:

- S-F1 [MAJOR] v10 repeat wire contract broken. O advertises rate 25 and
  sends repeats as `key_state=pressed` (seat.zig:61, :913-923, :944-947). K at
  v10 sends rate **0** (keyboard.cpp:79-84) precisely because v10 adds
  KEY_STATE_REPEATED (K emits it for v10+, keyboard.cpp:207-216). A v10 client
  disables its own repeat and branches on `repeated` → double-processes or IME
  misfilters. Fix: rate 0 to v10 resources + emit repeated, or drop
  seat_version to 9 (wlroots/smithay parity).
- S-F2 [MAJOR] Implicit pointer grab leaks axis and button-release. Grab is a
  bool checked in pointerMotion (seat.zig:206) and press suppression
  (seat.zig:653 — release always delivered); pointerAxisDir (seat.zig:714+)
  never checks it. W routes motion/button/axis through grab->interface
  (wlr_seat_pointer.c:563-620); interactive-move grab swallows all three;
  reset_buttons clears held-button state on focus switch (:545-563). Ours:
  wheel scroll reaches the client under a camera drag; a release for a
  suppressed press is delivered. Fix: route axis (and release) through the
  grab gate.
- S-F3 [MED] wl_touch is a live dead object (never errors, never emits,
  seat.zig:1217-1225); no MISSING_CAPABILITY error (W wlr_seat.c:53-66); no
  capabilities/name change broadcast (W re-sends on change, :390-451; S
  send_all_caps; K sends on bind + change). A touch-probing client waits
  forever on a capability never announced.
- S-F4 [MED, cross-area] data_device.selection not re-sent on keyboard focus
  change (O seat.zig:319-350; W seat_client_send_selection after modifiers on
  enter, wlr_seat_keyboard.c:293). Newly focused client never learns current
  clipboard → paste empty until next set_selection. Seat-side root of a paste
  bug.
- S-F5 [MAJOR, structural] No per-button pressed-count / grab_serial;
  start_drag validation ring-only. W maintains n_pressed per button + mints
  grab_serial on first press; drag validation requires button_count==1 AND
  exact serial AND focus on origin (wlr_seat_pointer.c:481-517, 601-617).
  Ours: a drag can start on a key serial or stale pointer serial. Deferred
  from prior F3.
- S-F6 [INFO] Cursor hotspot ignores output scale (O cursor.zig:226-228,
  322-324; K divides by scale, pointer.cpp:90). Nil effect at scale 1; latent
  for scaled outputs.
- S-F7 [MINOR] Repeat first-tick jitter: timer armed at delay, early tick
  skips emission yet advances deadline → first repeat at delay+interval
  (main.zig:1963,1983; seat.zig:947).
- S-F8 [INFO] set_cursor serial scope ring-wide (seat.zig:583-600); K
  requires exact enter serial (pointer.cpp:65-66); W ring at compositor
  discretion. Matches majority reference; deliberate.

## 3. xdg-shell

Ours: src/shell/xdg.zig (3698 ln incl. tests). Version 7 (W/S 7, K 6).

Breadth: all requests/events present (toplevel 14 requests, popup grab is a
stub). Constraint math (flip/slide/resize) is an exact port of
wlr_xdg_positioner.c:327-518; state-version gating + ack payload model match
wlroots.

Findings:

- X04 [MAJOR] xdg_popup.grab is a no-op: no seat grab, no invalid_grab, no
  not_the_topmost_popup (O xdg.zig:1356-1360; W wlr_xdg_popup.c:272-280,
  320-326; S mod.rs:1991; K xdgshell.cpp:856-858). Mapped-popup grab gets a
  silent no-op instead of a protocol error. Structural (F2 backlog).
- X01 [MINOR] ack_configure invalid-serial error on the wrong interface vs
  both refs: O posts xdg_surface.invalid_serial (code 4); W posts
  wm_base.invalid_surface_state (code 4, wlr_xdg_surface.c:74-80); S same
  (surface.rs:318-322). XML (xdg-shell.xml:573-593) says invalid_serial →
  OURS is the spec-literal one; refs post the same code on the wrong
  interface. Conformance suites asserting the wlroots interface fail ours.
- X03 [MINOR] set_parent to an unmapped toplevel: O stores the parent
  (xdg.zig:1180-1219); W silently clears (wlr_xdg_toplevel.c:183-199).
  Transient/grouping behavior diverges.
- X05 [MAJOR, structural] Reactive popups never re-configure; set_reactive is
  dead state (xdg.zig:1762). S actively re-sends + refuses for v<3/non-
  reactive (mod.rs:1904-1920); W re-schedules on parent motion. Reactive
  tooltips never follow their parent.
- X06 [INFO/MINOR] sent_payloads not cleared on unmap/reset (O clears
  sent_serials only, xdg.zig:381); W destroys the whole configure_list
  (wlr_xdg_surface.c:26-45). Stale payloads linger until next ack. Memory
  only.
- X07 [MINOR] configure_bounds/wm_capabilities triggers value-driven, not
  flag-driven (xdg.zig ~853-880); W sends whenever the compositor sets the
  fields bit (wlr_xdg_toplevel.c:33-75). Cannot advertise empty caps or
  explicit 0,0 bounds.
- X08 [MAJOR, structural] Compositor cannot drive toplevel size/states —
  auto-configure architecture (xdg.zig:1881-1899); main.zig never calls
  t.configure. All refs compositor-driven. Every toplevel maps at client
  size, no maximized/fullscreen/activated. (F6/L2 reaffirmed.)
- X09 [INFO] repositioned event not version-gated (xdg.zig:1372; W gates at
  v3). Benign — only v3+ clients can send reposition.

## 4. layer-shell / xdg-decoration / xdg-activation

Ours: src/shell/{layer_shell,xdg_decoration,xdg_activation}.zig. Versions:
layer v5 (W/S/K v5), decoration v1 (W/S v1, K v2), activation v1 (all v1).

Breadth: all wire requests/events present. Two compositor-facing SIGNALS
missing that all three references provide:

- L-D1 [MAJOR] layer get_popup parents a popup but emits NO `new_popup`
  signal (O layer_shell.zig:455-486; W wlr_layer_shell_v1.c:254; S
  handlers.rs:272-295; K attachTo). Compositor never learns of layer popups →
  cannot position/render them (compounds F12 popup-offset gap).
- L-D2 [MAJOR] xdg-decoration has no `new_toplevel_decoration` signal (O
  xdg_decoration.zig:128-130, getToplevelDecoration :225-320 emits nothing;
  W wlr_xdg_decoration_v1.c:299,406; S decoration.rs:174,242; K
  decorationCreated). Decoration negotiation one-directional: compositor can
  only answer client set_mode, can never announce a compositor-decided
  initial mode → server-side-only decoration policy unreachable.

Other findings:

- L-D3 [MINOR] close() destroys the wire resource; W inerts it (client's
  later destroy targets a dead id on ours; W wlr_layer_shell_v1.c:337-341).
  Low impact today (main.zig never closes a layer surface).
- L-D4 [MINOR] set_size > INT32_MAX posts wire error -1; W posts
  client-level implementation error. Both kill the client; error location
  differs.
- L-D5 [MINOR] get_layer_surface rejects same-role re-assignment; W/K allow
  it. Ours deliberately stricter (note 129 #4).
- L-D6 [INFO] Initial configure module-auto with output-size fallback; refs
  compositor-driven. Known divergence (note 133 L2).
- L-D7 [INFO] Keyboard-interactivity stored, focus policy unconsumed
  (documented out of scope, layer_shell.zig:24-27).
- D-A1 [MINOR] xdg-activation surface-focus check enforced even when no
  seat/serial set (O xdg_activation.zig:494-514); W gates behind set_serial
  (wlr_xdg_activation_v1.c:155-164). Breaks the legit launcher
  set-surface-no-serial flow that works on wlroots. Only MINOR that rejects a
  flow wlroots accepts.
- D-A2 [MINOR] activate() destroys the creating client's wire resource; W
  leaves it inert (wlr_xdg_activation_v1.c:383-388). Cross-client flow:
  later creator-side destroy targets a dead id. Minor.
- D-D2 [MINOR, deliberate] invalid_mode=3 posted (XML-mandated,
  xdg-decoration-unstable-v1.xml); W/S/K all lax. Ours is XML-correct,
  stricter than refs; real toolkits never send 3.
- D-D3 [MINOR] decoration v1 vs KWin v2; v2 relaxations (decoration on
  committed toplevel, mode retained across re-create) unavailable. Coherent
  v1, breadth gap only.
- D-D4 [INFO] Orphaned-at-creation handled safely (matches S/K; strictly
  safer than W which would deref a freed toplevel).
- D-A3/A4/A5 [INFO] committed-flag vs inertness equivalent; new_token on
  valid commit only (matches W; S defers to handler); KWin does no
  server-side token validation at all.

## 5. selection / data-device / primary-selection

Ours: src/compositor/{data_device,primary_selection}.zig. Versions:
wl_data_device_manager v3, primary-selection v1.

Breadth: clipboard/primary surface complete and wire-conformant (offer
ordering, bind-time delivery, used-once, serial + superseded guards). Single
structural gap: drag-and-drop.

- F-SEL-1 [CRITICAL, DnD-blocking breadth] No drag state machine: start_drag
  (data_device.zig:356-377) finalizes source + validates serial + sends
  cancelled. W full machine (wlr_drag.c:30-380 grabs+focus, :213-231 drop,
  :402-442 icon role); S data_device/mod.rs:148-347; K datadevice.cpp:
  69-142, updateDragTarget :238-301. Missing: device enter/motion/leave/drop,
  source dnd_drop_performed/dnd_finished/action, drag icon role, grabs, drag
  offers, finish-validation. Known/deferred (notes/134 DD-1); dominant
  breadth gap.
- F-SEL-2 [MAJOR, latent] wl_data_offer.source_actions never emitted
  (updateAction data_device.zig:675-686 sends only action events). Protocol
  mandates it immediately after offer creation (wayland.xml:710-719); W
  sends on drag-offer creation (wlr_drag.c:99-101); K sendSourceActions
  (dataoffer.cpp:214). notes/134 DD-2 "FIXED" covers only `action` events.
  Destination never learns offered actions; client-visible the moment DnD
  lands.
- F-SEL-3 [MINOR] Cancelled source stays wire-live + reusable; W inerts it —
  re-passing a cancelled source: ours SETS it as new selection, W CLEARS
  (wlr_data_device.c client_data_source_destroy; wlr_primary_selection_v1.c:
  110-121).
- F-SEL-4 [MINOR] set_selection with same already-selected source re-
  delivers offer+selection; W early-returns on same source, updating only
  serial (wlr_data_device.c:184-189). Extra round-trip.
- F-SEL-5 [MINOR, latent single-seat] get_data_device/get_device ignore seat
  arg, never validate live seat (data_device.zig:317-335; W inerts for NULL
  seat_client, wlr_data_device.c:226-252). Unreachable single-seat; parallels
  the XA-5 fix for xdg_activation.
- F-SEL-6 [MINOR] Primary offer.receive does not validate mime
  (primary_selection.zig:538-552); S validates all offers (offer.rs:177-182);
  inconsistent with deliberate DD-7 hardening on wl_data_offer.receive
  (data_device.zig:704-768). smithay-parity + internal-consistency gap.
- F-SEL-7 [MINOR, latent] in_ask suppression not modeled (updateAction
  :672-686); W suppresses during ask (wlr_data_offer.c, flag declared but
  never set in 0.20.2). Latent until F-SEL-1.
- F-SEL-8 [MINOR, deliberate] Dead offers inerted; defensive branch
  unreachable. Not a divergence.

## 6. aux/ext — presentation / screencopy / fractional-scale / viewporter

Ours: src/presentation.zig, src/screencopy.zig, src/shell/{fractional_scale,
viewporter}.zig. Versions at reference parity (presentation v2, screencopy
v3, fractional-scale v1, viewporter v1). smithay/KWin have NO zwlr_screencopy
(smithay ships ext-image-copy-capture-v1) — that table is wlroots-only.

- F-AX-1 [CRITICAL] viewporter UAF on wl_surface.destroy. O stores raw
  `surface: *Surface` in ViewportRes (viewporter.zig:86), no surface.destroy
  listener; wl_surface.destroy legal (viewport not a role; surface.zig:
  1103-1107), Surface freed after destroy (surface.zig:396-397) → later
  set_destination writes through freed memory (viewporter.zig:161-170). W
  ties viewport to surface via addon destroyed with it (wlr_viewporter.c:
  122-126). Reachable UAF via wire. Fix first.
- F-AX-2 [MAJOR] wp_presentation.present synthetic, not gated on real
  display: server calls present right after commitState, before flip
  completes (main.zig:1510); tv from CLOCK_MONOTONIC at call time, per-output
  seq (presentation.zig:219-223). W queues on output, presents only when
  commit_seq matches from the present event (wlr_presentation_time.c:277-301,
  311-339) — dropped frames never presented. Ours: failed scanout still
  reported presented, timestamps = commit time. Consequence of deferred
  output-present-event work (note 135 F8).
- F-AX-3 [MAJOR] presented flags always 0 — never VSYNC/HW_CLOCK/
  HW_COMPLETION (presentation.zig:224-225; main.zig:1510 passes 0). W passes
  DRM present flags (:287-301); K sets HW_CLOCK|HW_COMPLETION + VSYNC
  (presentationtime.cpp:109-115). Clients cannot distinguish hw-completed
  vsync frames from estimates.
- F-AX-4 [MINOR] refresh mode-derived, not present-derived; no adaptive-sync
  v1 zeroing (presentation.zig:222; W :288-292, K :116-119). N/A today (no
  adaptive sync).
- F-AX-5 [MINOR] screencopy foreign wl_output kills the client (no_memory,
  screencopy.zig:261-264) instead of sending failed (W wlr_screencopy_v1.c:
  508-511). Disproportionate kill for a benign mistake.
- F-AX-6 [MINOR] screencopy shm-only: no linux_dmabuf event, dmabuf copy
  rejected (screencopy.zig:359-360, 405+; W :592-595). Breadth gap,
  documented shm-only compositor.
- F-AX-7/8 [INFO] screencopy damage accumulation wired to commit not
  precommit (equivalent outcome); overlay_cursor via composited framebuffer
  not cursor lock (functionally equivalent).
- F-AX-9 [MINOR] fractional-scale preferred_scale sent immediately +
  unconditionally (fractional_scale.zig:132-133); W/S/K send only when a
  scale was previously set (:144-146, mod.rs:100-106, :58-60). Ours hardcodes
  120/120, never updatable. Benign at constant scale 1.
- F-AX-10 [MINOR] fractional-scale stale ScaleState entry after surface
  destroy (fractional_scale.zig:98, no listener) — pointer-compared only, no
  deref, so no UAF; false-positive exists-check on address reuse. W destroys
  via surface addon (:38-55).
- F-AX-11 [MAJOR] wp_viewport.set_destination single-buffered (applied
  immediately, viewporter.zig:161-170); destroy never resets the override
  (143-153). All refs double-buffer + reset on destroy (W wlr_viewporter.c:
  81-82,109-111; K viewporter.cpp:93-100; S mod.rs:185-192,230-233).
  Destination override persists after viewport destroy; value takes effect
  even if the carrying commit never happens. Protocol double-buffer
  violation, observable via viewport.destroy.
- F-AX-12 [MAJOR] wp_viewport source crop neither validated nor applied: no
  commit listener, never raises out_of_buffer/bad_size, renderer draws the
  whole buffer; doc comment claims commit-time validation that does not
  exist ([INFERENCE] confirmed: no out_of_buffer/bad_size/reject in src/).
  W rejects at commit (wlr_viewporter.c:135-167); S same. Clients requesting
  a crop get the whole buffer with no error; out-of-bounds crops silently
  served garbage.
- F-AX-13 [INFO] no_surface error not implemented (W wlr_viewporter.c:71-77;
  S mod.rs:210-223) — would deref dangling surface (subsumed by F-AX-1).

## 7. Consolidated priorities

| Priority | Finding | Class | Fix |
|---|---|---|---|
| 1 | F-AX-1 viewporter UAF | CRITICAL | wire viewport to surface destroy |
| 2 | F-AX-11/12 viewport double-buffer + source validation | MAJOR | pending state at commit + reset on destroy + commit-time bounds check |
| 3 | C-CS-1 subsurface inert on parent death | MAJOR | keep resource, null role, ignore requests |
| 4 | C-CS-2 subsurface map/enter/present parent-coupled | MAJOR | gate child signaling on parent chain mapped |
| 5 | S-F1 v10 repeat contract (rate 0 + KEY_STATE_REPEATED) | MAJOR | per-version repeat_info + state, or drop to v9 |
| 6 | S-F2 implicit grab leaks axis/release | MAJOR | route axis+release through grab gate |
| 7 | L-D1 layer new_popup signal | MAJOR | emit hook on get_popup |
| 8 | L-D2 decoration new_toplevel_decoration signal | MAJOR | emit hook at get_toplevel_decoration |
| 9 | F-SEL-2 source_actions event | MAJOR (latent) | send on offer creation when DnD lands |
| 10 | F-AX-2/3 real present event → presentation | MAJOR | output present event (note 135 F8) |
| 11 | S-F4 selection re-sent on focus | MED | send selection after modifiers on enter |
| 12 | F-SEL-3 cancelled source inert | MINOR | null resource on cancel |
| 13 | X01 ack error interface | MINOR | adopt wm_base interface for ref parity |
| 14 | F-SEL-6 primary mime validation | MINOR | extend DD-7 check |

Classes: FIXABLE-IN-MODULE (module owns state, small local change),
NEEDS-WIRING (library machinery exists; server must consume a signal),
STRUCTURAL (policy architecture change: stacking, per-output state, grab
layer, DnD, compositor-driven configure). The structural items are the
known backlog (F2/F3/F6/F12, DD-1, note 135 F8); everything above the line
"structural" is a localized fix.

Working sections: `local/cmp-core-surface.md`, `local/cmp-seat-input.md`,
`local/cmp-xdg-shell.md`, `local/cmp-layer-deco-act.md`,
`local/cmp-selection.md`, `local/cmp-aux-ext.md`.
