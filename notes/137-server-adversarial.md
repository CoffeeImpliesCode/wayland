# 137: Server adversarial audit — ours vs tinywl (wlroots) vs smallvil (smithay)

Audit date: 2026-08-11. No code changed. Three read-only inventories (tinywl.c
full read; smithay smallvil/ tree; our src/ wiring) plus a verified headline
finding.

Verdict: the protocol machinery (commit, configure, serials, focus cleanup,
unconstrain) is healthy, but the compositor policy layer is thin, and one
wiring gap — a surface commit never wakes the renderer — starves interactive
content. tinywl and smallvil get this right by never skipping the composite.
Everything else is policy omissions (maximize/fullscreen never answered,
move/resize dead, no activation/raise/focus-on-map, no key repeat), not
protocol failures: the library emits the signals, the server subscribes to
almost none of them.

Reference line keys: `T:` = tinywl.c, `S:` = smithay smallvil/src (file:line
where the inventory recorded lines; file-level otherwise), `O:` = ours.

## 1. Headline finding — commit → present starvation (VERIFIED)

A client content commit updates the scene texture but never schedules a
composite. The renderer only wakes on input, camera motion, screencopy, or a
pending wl_surface.frame callback — and the frame-callback path presents the
STALE framebuffer.

The exact path:

1. Commit: `wl_surface.commit` → surface_node's commit listener runs
   `sn.update()` and nothing else (O `src/scene/surface_node.zig:463-466`).
   The node holds the new texture; no compositor wake.
2. `requestRender` callers — the ONLY setters of `repaint_pending`
   (O `src/server/main.zig:1237-1248`): frame_kick (O 1106-1107), raylib
   poll (O 1173-1175), new-surface tracking in syncSurfaces (O 1603-1604),
   screencopy requestFrame (O 1833-1834), pointer hover/pan (O 1882/1894),
   wheel zoom (O 1918). No surface-commit listener exists in main.zig.
3. No frame callback pending → the render never runs; the commit is never
   presented. Content stays invisible until a camera move, screencopy, or
   new-surface event forces `compositeCanvas` (O 1455-1463).
4. Frame callback pending (foot-style render loop) → onDisplayReady sees the
   pending callback and sets `frame_kick` (O `main.zig:1096-1111`), which
   wakes the renderer, but renderFrame's frame_kick branch presents the
   CURRENT framebuffer without a recomposite and fires `frame_done` against
   it (O `main.zig:1347-1352`; done sent to `scene.presented` at O 1395-1397).
   The client then renders the next frame and commits — same path again.
   Result: the client's newest content never reaches the screen; the
   callback loop runs forever against stale pixels.

tinywl has no such skip: every frame unconditionally commits the scene and
sends frame_done (T:183-195), so the presented buffer is always the latest
committed content. Its correctness comes from never skipping. The idle skip
(O `main.zig:1267-1269`, repaint_pending) is our divergence — it buys the
~95% idle-CPU win but must be re-armed by every content change, and the
frame_kick shortcut re-presents the previous framebuffer.

Why the E2E missed it: the M3/M4 harness verifies the gradient via screencopy
`requestFrame`, which calls `requestRender` (O `main.zig:1832-1836`) and
forces a real composite — the very path the bug bypasses. Synth input
(O `main.zig:1186-1223`) also runs per dispatch and injects pointer/key
events that wake the renderer. Real interactive clients (typing into a
terminal, an idle compositor with a rendering app) do neither. Repro
reasoning [orchestrator-confirmed]: start any client that commits content
continuously with wl_surface.frame; pan/zoom once so the first frame shows,
then leave the pointer still — subsequent commits never appear. [INFERENCE:
runtime symptom not re-run in this session; the code path above is
verified.] [INFERENCE: the same gap makes cursor_repaint safe only because
the canvas is genuinely unchanged — a commit during a hover sequence leaves
the base stale until the next full composite.]

## 2. Comparison matrix

### 2.1 vs tinywl (wlroots minimal, single file — everything is inline policy)

| # | Area | tinywl (T:) | ours (O:) | Verdict |
|---|------|-------------|-----------|---------|
| 1 | xdg_toplevel listeners | map/unmap/commit/move/resize/maximize/fullscreen all wired (T:437-473) | only set_title/set_app_id/request_minimize/request_fullscreen/destroy (O main.zig:893-934) | OURS BEHIND — move/resize/maximize/map policy dropped |
| 2 | initial commit → configure | on initial commit `wlr_xdg_toplevel_set_size(0,0)` (T:253-262) | module auto-replies initial configure on first commit (O xdg.zig:1881-1893; popup 1894-1897 + constraint box O main.zig:957-975) | PARITY (policy moved into the library) |
| 3 | map → focus + raise | map inserts + focus_toplevel (T:241-247); raise-on-focus (T:75-76) | NO map listener; focus only via click; no z-raise — all toplevels at (0,0) in creation order (O main.zig:1492-1517 compositeBase; scene.pick topmost) | OURS BEHIND — new windows unfocused; earlier windows unreachable at origin |
| 4 | move/resize | begin_interactive grab: cursor consume + edge clamping (T:367-413; serial TODO 381-383) | module emits request_move/request_resize with validated serial/edge (O xdg.zig:1116, 1141); server subscribes to NEITHER; left-drag = camera pan (O main.zig:1850-1901) | OURS BEHIND — CSD drag pans the camera |
| 5 | maximize/fullscreen | maximize replied with configure, gated on initialized (T:408-420) | set_maximized stores pending + emits (O xdg.zig:1150-1157); NO listener → no configure with maximized state ever; fullscreen handler log-only (O main.zig:872-886) | OURS BEHIND — protocol deadlock for maximizing clients |
| 6 | close | tinywl never sends close; client destroy frees (T:264-282) | sendClose exists (O xdg.zig:946-949) but zero callers; client-side destroy cleans up (O main.zig:1677-1684 → seat.zig:930-942 leave-before-clear) | PARITY+ (ours cleans focus on death; tinywl does not) |
| 7 | outputs | N outputs via wlr_output_layout; request_state + destroy listeners (T:197-214, 216-240) | single output, no layout, no request_state, no destroy listener (O main.zig:738-847) | OURS BEHIND — backend resize/hotplug ignored |
| 8 | frame loop | unconditional per-frame scene commit + frame_done (T:183-195) | idle-skip + frame_kick + damage ring + watchdog (O main.zig:1250-1454) | OURS BEHIND on correctness (F1), AHEAD on idle CPU |
| 9 | seat/cursor | xcursor theme, default image, request_cursor focus check (T:296-306, 587-618) | vetted set_cursor (O seat.zig:1162-1167, stricter than T:296-300); fixed 16x16 fallback arrow (O cursor.zig:277-328); no themes/scales | PARITY+ (vetting stricter), minus themes |
| 10 | pointer motion/buttons | cursor move + hit-test + enter/motion, click-focus (T:379-435) | pickSurface hit-test (O main.zig:1781-1812), enter/leave/motion (O seat.zig:515-553), click-to-focus (O seat.zig:584-592) | PARITY, minus themes; wheel+left-drag consumed for camera (O main.zig:1907-1919, 1850-1901) |
| 11 | keyboard | Alt+Esc quit, Alt+F1 cycle, per-device keymap + repeat 25/600 (T:86-173) | Mod4+Escape quits AND is forwarded to the client (O main.zig:1838-1848); repeat 0/0 (O seat.zig:244-245); static caps (O seat.zig:163-174) | OURS BEHIND — no repeat, no cycle, no consume |
| 12 | focus policy | focus_toplevel: deactivate prev, raise, activate new, keyboard enter (T:69-84) | click-to-focus only (O seat.zig:590-592); activated NEVER sent (scheduled.activated has no writer, O xdg.zig:874-880 reads it); no map-focus; xdg_activation log-only (O main.zig:976-992) | OURS BEHIND |
| 13 | popups | scene parent + initial configure (T:475-515) | constraint box (O main.zig:957-975) + flip/slide/resize unconstrain (O xdg.zig:1502-1668) | PARITY+ |
| 14 | teardown | full destroy chain (T:651-672) | defer chain (O main.zig:443-728), cleanupSurfaceEntries (O 1748-1762), seat leave on deinit (O seat.zig:357-395), focus cleared pre-free | PARITY; ours ordered better |
| 15 | extras | -s startup command, WAYLAND_DISPLAY setenv, autocreate backend, multi-output layout (T:646-650) | ping/unresponsive (O main.zig:1134-1167), watchdog (O 1123-1131), WAYLAND_RUN_FRAMES, synth input, screencopy, presentation | OURS AHEAD on robustness; tinywl has a startup-command UX we lack |

### 2.2 vs smallvil (smithay minimal — Space<Window> + Seat; file-level refs)

| # | Area | smallvil (S:) | ours (O:) | Verdict |
|---|------|---------------|-----------|---------|
| 1 | redraw scheduling | Redraw → render + send_frame + request_redraw (winit.rs:86-100) | idle-skip + requestRender; frame_kick shortcut (O main.zig:1237-1352) | PARITY on pacing; ours ahead on idle CPU, behind via F1 |
| 2 | frame callbacks | send_frame to all elements per redraw (winit.rs:86-90) | per-presented sendFrameDone (O main.zig:1395-1397) | PARITY |
| 3 | xdg configure | commit → initial configure (handlers/xdg_shell.rs) | module auto-reply (O xdg.zig:1881-1893) | PARITY |
| 4 | close | no compositor-initiated close at all | sendClose uncalled (O xdg.zig:946-949) | PARITY (both absent); ours has the API |
| 5 | move/resize grabs | real grabs via check_grab: serial + same-client validation (handlers/xdg_shell.rs:59, 91, 125; grabs/move_grab.rs; grabs/resize_grab.rs w/ min/max clamp + WaitingForLastCommit) | module emits validated signals (O xdg.zig:1116, 1141); zero subscribers; left-drag = camera pan (O main.zig:1850-1901) | OURS BEHIND |
| 6 | keyboard focus | click → set_focus (input.rs:72-77); empty-click clears focus (input.rs:83-87) | click-to-focus (O seat.zig:584-592); no clear/deactivate | OURS BEHIND (no deactivate/clear) |
| 7 | pointer focus/enter | hover-follow (input.rs) | hover-follow + enter/leave (O seat.zig:515-553) | PARITY |
| 8 | cursor | cursor_image handler is a no-op (handlers/mod.rs) | real cursor (fallback rect + client surface, O cursor.zig:165-272) + serial/focus-vetted set_cursor (O seat.zig:1162-1167) | OURS AHEAD |
| 9 | seat caps/repeat | static caps keyboard+pointer; [INFERENCE: smithay default keyboard repeat (25/600) applies — smallvil sets no repeat config] | static caps (O seat.zig:163-174); repeat explicitly 0/0 (O seat.zig:244-245) | OURS BEHIND on repeat; caps parity |
| 10 | shortcuts | none | Mod4+Escape quits server (O main.zig:1838-1848) | PARITY-ish; ours has one binding |
| 11 | new client/surface | window.on_commit / handle_commit (handlers/compositor.rs) | syncSurfaces wake on new surface (O main.zig:1589-1609) | PARITY |
| 12 | output | winit Resized → change_current_state(Mode) (winit.rs:48-52); CloseRequested → stop (102-103) | no request_state listener at all; single output (O main.zig:738-847) | OURS BEHIND |
| 13 | activation/raise | click raises + activates + send_pending_configure to ALL toplevels (input.rs:72-77); empty-click deactivates all (input.rs:83-86) | never raises, never activates, never reconfigures on focus (O main.zig:976-992 log-only) | OURS BEHIND |
| 14 | ping/liveness | none | xdg ping → postError(.unresponsive) disconnect (O main.zig:1134-1167); 5s render watchdog (O 1123-1131) | OURS AHEAD |
| 15 | popups | initial configure + grab routing (handlers/xdg_shell.rs) | constraint box + unconstrain (O xdg.zig:1502-1668) | PARITY+ |
| 16 | teardown | event-loop stop, output teardown | defer chain + focus leave (O main.zig:443-728; seat.zig:357-395) | PARITY+ |
| 17 | DnD / data-device | DnD grab present (handlers/mod.rs) | data_device + primary_selection modules; no DnD drag UI | OURS BEHIND on DnD; selection parity |

## 3. Numbered findings

Severity: C = critical, H = high, M = medium, L = low. Fix class: see §4.

### F1 [C] commit → present starvation (headline, §1)
- O: surface_node.zig:463-466 (commit listener syncs only); main.zig:1096-1111
  (frame_kick), 1347-1352 (stale present), 1237-1248 (requestRender setters).
- Ref: tinywl always composites + sends done (T:183-195); smallvil redraw
  loop always renders (S winit.rs:86-100).
- Expected: any committed content change schedules a composite; a frame
  callback fires only after that content is presented.
- Why it matters: interactive content invisible or stale indefinitely; the
  frame_callback contract is dishonored (done precedes the presented buffer).
- Class: NEEDS-WIRING.

### F2 [H] maximize/fullscreen never answered
- O: xdg.zig:1150-1157 emits request_maximize (pending stored); no subscriber;
  onToplevelFullscreen log-only, req.output dropped (main.zig:872-886);
  scheduled.fullscreen never set (xdg.zig:874-880 reads scheduled).
- Ref: tinywl replies with a configure gated on initialized (T:408-420).
- Expected: compositor answers set_maximized/set_fullscreen with a configure
  carrying the state (xdg-shell requires it).
- Why: a client that waits for the required configure hangs unconfigured —
  protocol deadlock.
- Class: NEEDS-WIRING.

### F3 [H] move/resize/`show_window_menu` unhandled + camera-pan collision
- O: module emits validated signals (xdg.zig:1108 menu, 1116 move, 1141
  resize); main.zig subscribes to none; left-button drag is camera pan
  (main.zig:1850-1901).
- Ref: tinywl begin_interactive grab with edge clamping (T:367-413); smallvil
  check_grab serial+same-client grabs (S handlers/xdg_shell.rs:59,91,125).
- Expected: titlebar drag moves the window; edges resize; menu shows.
- Why: CSD windows immovable/resizable; drags pan the camera instead; client
  menus dead.
- Class: NEEDS-WIRING (+ policy: resolve drag ownership with camera pan).

### F4 [H] activated never sent; no map-focus; no raise; no deactivate
- O: scheduled.activated has no writer (configure reads it, xdg.zig:874-880);
  no map listener (main.zig:893-934); no raise (scene order = creation order,
  main.zig:1492-1517); xdg_activation log-only (main.zig:976-992); no focus
  clear on empty click.
- Ref: tinywl focuses + raises on map (T:241-247, 75-76); smallvil raises +
  activates + reconfigures all toplevels on click, deactivates all on
  empty-click (S input.rs:72-88).
- Expected: new windows focused on map; click raises+activates; empty click
  deactivates; activated state reaches clients.
- Why: CSD toolkits key titlebars/carets off activated — they stay inactive
  even when focused; second window at (0,0) is pointer-unreachable (scene.pick
  topmost) and never keyboard-focusable.
- Class: NEEDS-WIRING (library writer for scheduled.activated + server
  policy; raise needs stacking → STRUCTURAL companion).

### F5 [M] no key repeat; static seat caps
- O: key_repeat_rate/delay = 0,0 (seat.zig:244-245, sent 1060); caps fixed
  keyboard+pointer (seat.zig:163-174); onNewInput logs only (main.zig:728-737).
- Ref: tinywl per-device repeat 25/600 (T:157), caps recomputed per input
  (T:280-286); smallvil [INFERENCE: smithay default repeat].
- Expected: repeat info 25/600 (note 125 marks repeat in scope); caps reflect
  connected devices.
- Why: holding a key yields one event — unusable for editors/terminals;
  keyboard-less boot advertises keyboard; hotplug lies.
- Class: FIXABLE-IN-MODULE (repeat) + NEEDS-WIRING (caps recompute).

### G1 [L] compositor can never close a window
- O: sendClose zero callers (xdg.zig:946-949); no close keybinding (only
  Mod4+Escape quits the server, main.zig:1838-1848).
- Ref: tinywl and smallvil neither — parity, but tinywl's client destroy is
  the only path there too (T:264-282).
- Expected: a compositor-initiated close path (keybinding or policy).
- Why: a hung/fullscreen client is unrecoverable without killing the server.
- Class: NEEDS-WIRING.

### G2 [L] keyboard focus never follows hover
- O: pointerMotion changes pointer focus only (seat.zig:515-553); keyboard
  focus on button press only (seat.zig:584-592).
- Ref: click-only in tinywl (T:424-435) and smallvil — parity; not a
  reference divergence.
- Expected: at least focus-on-enter so click-free clients can get keys.
- Why: pure-hover UI never receives keyboard input. Deliberate policy today;
  low.
- Class: FIXABLE-IN-MODULE (policy change, deliberate).

### G3 [M] unconsumed toplevel requests (superset of F2/F3)
- O: request_move/resize/maximize/show_window_menu emitted (xdg.zig:1108,
  1116, 1141, 1150-1157), zero subscribers.
- Ref: tinywl handles all four (T:367-420).
- Expected: every request signal has a consumer (even a "no-op" reply).
- Why: dead protocol surface; clients see silent no-ops.
- Class: NEEDS-WIRING.

### G4 [M] fullscreen/minimize log-only
- O: onToplevelMinimize/Fullscreen log only (main.zig:867-886); no unmap on
  minimize; req.output dropped.
- Ref: tinywl handles maximize; minimize is policy in real compositors.
- Expected: minimize hides (unmap/lower); fullscreen sets scheduled state +
  configure.
- Why: minimize/fullscreen requests are silently discarded.
- Class: NEEDS-WIRING.

### G5 [M] multi-output unsupported + no output destroy listener
- O: onNewOutput clobbers self.output/scene/wl_output/cursor (main.zig:738-
  847); second output would corrupt state; no request_state (output.zig has
  none) — backend-requested resize ignored; no destroy listener in main.zig
  (only wl_output.zig:73 + screencopy.zig:449 subscribe).
- Ref: tinywl layout + request_state + destroy (T:197-240).
- Expected: per-output state; request_state honors backend resize; destroy
  cleans references.
- Why: nested-backend resize, hotplug, multi-connector DRM break or dangle.
- Class: STRUCTURAL.

### G6 [M] no placement / no stacking policy
- O: all toplevels at scene root (0,0), creation order; main never calls
  configure with a size (initial configure from the module's first commit,
  xdg.zig:1881-1893); no raise.
- Ref: tinywl is equally (0,0)-simple but raises on focus (T:75-76).
- Expected: at minimum raise-on-focus (F4); placement is a policy choice.
- Why: overlapping windows unreachable; no stacking order.
- Class: STRUCTURAL (pairs with F4 raise).

### G7 [M] activation requests logged only; decorations stale on focus change
- O: onRequestActivate logs only (main.zig:976-992, documented out of scope);
  onDecorationMode reads seat.keyboard_focus at request time but no
  keyboard_focus signal subscription → mode never re-evaluated.
- Ref: smallvil full activation handling (S input.rs:72-88).
- Expected: request_activate grants focus; decoration mode re-applies on
  focus change.
- Why: CSD/SSD mismatch; focus UI stale.
- Class: NEEDS-WIRING.

### G8 [L] tracking lists append-only
- O: self.toplevels / self.layer_surfaces never removed on destroy
  (main.zig:895, 943) — stale pointers, wrong counts in logs.
- Ref: tinywl's list is the scene itself (no parallel bookkeeping).
- Expected: remove on destroy.
- Why: log-only today; any future per-window iteration walks dead pointers.
- Class: FIXABLE-IN-MODULE.

### G9 [L] hardcoded quit binding; bound keys forwarded to the client
- O: Mod4+Escape → loop.stop() (main.zig:1838-1848) and the key is ALSO
  delivered to the focused client (no consume path).
- Ref: tinywl consumes bound keys, never forwards them (T:102-138).
- Expected: compositor keybindings do not leak into clients; window-level
  bindings exist.
- Why: apps see phantom Escape; no window close/cycle keys.
- Class: FIXABLE-IN-MODULE (consume) + NEEDS-WIRING (bindings).

### G10 [L] error-path leaks in onNewOutput [INFERENCE]
- O: if wl_output/cursor create fails after self.scene is set (main.zig:800-
  826), partial state remains; output stays disabled → watchdog stops the
  server.
- Ref: tinywl's output path has no partial-state window (single structure).
- Expected: failed output setup unwinds what it built.
- Why: one bad connector kills the server instead of degrading.
- Class: FIXABLE-IN-MODULE.

### G11 [M] no compositor-side output reference cleanup
- O: cursor / self.output never nulled on output loss (see G5); pickSurface
  and renderFrame would touch dead state.
- Ref: tinywl removes scene output + listeners on destroy (T:207-214).
- Expected: destroy listener nulls refs, removes scene_output.
- Why: dangles on hotplug once outputs can die.
- Class: NEEDS-WIRING (companion of G5).

### SD1-SD4 smallvil deltas (ours behind, beyond G-items)
- SD1 [H] click raises + activates + reconfigures ALL toplevels
  (S input.rs:72-77) vs ours nothing (F4). NEEDS-WIRING.
- SD2 [M] empty-click deactivates all + clears focus (S input.rs:83-87) vs
  ours no clear. NEEDS-WIRING.
- SD3 [H] move/resize grabs with serial + same-client validation
  (S handlers/xdg_shell.rs:59,91,125; grabs/*) vs ours no listeners (F3).
  NEEDS-WIRING.
- SD4 [M] winit/backend resize honored (S winit.rs:48-52) vs ours no
  request_state (G5). NEEDS-WIRING (library: request_state support) +
  STRUCTURAL (per-output state).

## 4. Fixability and fix order

Classes:
- FIXABLE-IN-MODULE: the module owns the state; a small local change (default,
  cleanup, writer) closes it.
- NEEDS-WIRING: the library machinery exists; the server (or one subscriber)
  must consume a signal / call an API.
- STRUCTURAL: single-field/global assumptions or policy architecture must
  change (stacking, per-output state).

| # | Finding | Class | Order |
|---|---------|-------|-------|
| F1 | commit → present starvation | NEEDS-WIRING (surface commit listener → requestRender; make frame_kick recomposite or gate done on real present) | 1 — correctness: interactive content is invisible |
| F2/G3 | maximize/fullscreen/menu replies | NEEDS-WIRING (subscribe request_maximize/fullscreen → write scheduled state → configure) | 2 — protocol deadlock |
| F3/SD3 | move/resize grabs | NEEDS-WIRING (subscribers + grab policy; resolve left-drag ownership vs camera pan first) | 3 — CSD usability |
| F4/SD1/SD2/G7 | activation/map-focus/raise/deactivate | NEEDS-WIRING (+ library writer for scheduled.activated; raise needs G6 stacking) | 4 — multi-window UX |
| F5 | key repeat + caps recompute | FIXABLE-IN-MODULE + NEEDS-WIRING | 5 — cheap, high feel |
| G1 | close path | NEEDS-WIRING (sendClose from a binding once F4 gives focus) | 6 |
| G8/G9 | tracking lists, key consume/bindings | FIXABLE-IN-MODULE | 7 — cheap hygiene |
| G6 | placement/stacking | STRUCTURAL (pairs with F4 raise) | 8 |
| SD4/G5/G11 | backend resize + multi-output + destroy cleanup | STRUCTURAL (+ library request_state) | 9 |
| G10 | error-path unwind | FIXABLE-IN-MODULE | 10 |

F1 first: every other fix that changes content (F2-F4, SD*) worsens the
starved-present symptom until the commit wake exists, and F1 is a small,
isolated wiring change.

## 5. Parity / OK areas — where ours is AHEAD

- Ping/unresponsive: xdg ping → postError(.unresponsive, code 6) disconnects
  hung clients (O main.zig:1134-1167). Neither tinywl nor smallvil has this.
- Render watchdog: 5s no-render stops the loop instead of hanging tests
  (O main.zig:1123-1131).
- Serial-vetted set_cursor: focus + serial + role check (O seat.zig:1162-1167)
  — stricter than tinywl's focused_client-only check (T:296-300).
- Idle CPU: idle-frame skip keeps a static canvas at ~0% render cost
  (O main.zig:1267-1269) vs tinywl's unconditional per-vsync render
  (T:183-195) — the F1 fix must preserve this win (wake on commit, not vsync).
- Popup unconstrain: flip/slide/resize repositioning (O xdg.zig:1502-1668) +
  compositor constraint box (O main.zig:957-975); tinywl has no reposition
  policy at all (T:475-515).
- Cleanup order: defer chain (O main.zig:443-728), leave-before-clear on
  surface death (O seat.zig:930-942), seat leave on teardown (O seat.zig:357-
  395) — tinywl has NO focus cleanup at all; ours has a double net (server
  hook + seat re-armed destroy listeners, seat.zig:1006-1015).
- Initial configure: auto-replied in the module (O xdg.zig:1881-1897) — parity
  with tinywl's explicit (T:253-262); popups get a constraint-box configure
  first.
- Protocol hygiene the module does for free: serial ringset validation on
  move/resize (xdg.zig:1110-1141), pointer frame batching (seat.zig:627-762,
  O main.zig:1262), stale-cursor self-heal (cursor.zig), presentation +
  screencopy + synth-input (ours-only, no reference equivalent).
- Pointer-vs-keyboard focus split is deliberate and matches both references;
  the gap is only the missing map-focus/raise (F4), not the hover model.
