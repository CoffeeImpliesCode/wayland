# Codebase Analysis: Feature Completeness, Reference Behavior, Code Quality

Research note. Date: 2026-08-14.
Three parallel read-only audits (feature completeness vs spec + breadth
notes; reference behavior vs wlroots 0.20.2 / smithay v0.7.0 / KWin
closure of notes 131-138; code quality vs the 121 slop scan + house
bar). All claims file:line cited; full evidence in the audit agents'
outputs (agent://FeatureCompletenessAudit, //ReferenceBehaviorAudit,
//CodeQualityAudit).

## 1. Feature completeness

### Milestones

| M | Status | Gap |
|---|---|---|
| M1 core/compositor | DONE | none |
| M2 output/scene/presentation | DONE | none |
| M3 seat/input | DONE | touch not implemented |
| M4 shells | DONE | none |
| M5 nested backend + gles2 | DONE | gles2 NOT wired into the server (main.zig:508 pixman only); no camera/rotation shader |
| M6 DRM + libinput | PARTIAL | no libseat/logind session, no VT switch, no pause/activate, no udev hotplug, no GBM/modifiers, single connector |
| M7 canvas scene | DONE (narrowed) | SceneNode coords still i32 (scene.zig:126); f64 at the CanvasItem boundary (main.zig:1880-1883); buffer-age partial damage under camera motion not started; gles2 rotation shader absent. Rotation landed in the pixman path despite the deferred decision |
| M8 extras | PARTIAL | fractional-scale + screencopy landed; data-control, foreign-toplevel, tearing NOT advertised |

### Protocol surface

16 globals advertised (verified by wayland-info in note 141): wl_shm v2,
wp_presentation v2, wl_compositor v7, xdg_wm_base v7,
zwlr_layer_shell_v1 v5, wl_seat v10, xdg_activation_v1 v1,
zxdg_decoration_manager_v1 v2, wp_fractional_scale_manager_v1 v1,
zxdg_output_manager_v1 v3 (new, note 141), wp_viewporter v1,
wl_subcompositor v1, wl_data_device_manager v3,
zwp_primary_selection_device_manager_v1 v1, zwlr_screencopy_manager_v1
v3, wl_output v4.

In-scope but MISSING (with references): zwp_pointer_gestures_v1,
zwp_relative_pointer_manager_v1, zwp_pointer_constraints_v1,
zwp_tablet_manager_v2, zwp_linux_dmabuf_v1 (blocks F-AX-6),
zwlr_data_control_manager_v1, zwlr_foreign_toplevel_manager_v1 /
ext_foreign_toplevel_list_v1, wp_tearing_control_manager_v1,
zwp_virtual_keyboard/pointer, wp_cursor_shape_manager_v1,
wp_single_pixel_buffer_manager_v1, ext_idle_notifier + idle_inhibitor,
ext_session_lock_v1, ext_image_copy_capture (wlroots/smithay refs in
the audit; smithay dropped wlr-screencopy for ext-image-copy-capture).

### Breadth notes closure (123-128)

LANDED since the notes: nested backend, DRM legacy fallback, output
enter/leave, scale/transform application at render, viewporter,
cached-state commit blockers, keyboard repeat, primary selection, DnD,
seat grabs, layer-shell, fractional-scale, xdg-output, xdg-activation,
decoration v2, subsurface sync + stacking, matrix helpers, selection
offer lifecycle, serial validation.

STILL-MISSING: session/logind, udev hotplug, multi-backend, GBM +
modifiers, DRM planes, syncobj/tearing, headless multi-output, backend
test/commit + buffer_caps, touch/tablet/gestures (libinput drops them
silently, libinput.zig:353-363), input-device removal signal,
preferred_buffer_scale/transform hints (v6), linux-dmabuf, buffer
import registry, partial upload, generic surface-tree helpers,
data-control, foreign-toplevel, tearing, drag icons rendered, wlr_region
helpers, output layout, output request_state, sync points/fences,
format negotiation, gles2 wiring + camera shader, drag icon role.

## 2. Reference behavior

### 138 closure (61 findings)

- 31 FIX: ALL verified present in code (viewporter UAF, subsurface
  inert/map, v10 repeat, grab gate, damage clip, source_actions, etc.).
- 15 DEFER: 14 landed in waves A-D (2026-08-13); F-AX-6 dmabuf screencopy
  BLOCKED (no dmabuf allocator).
- 15 ACCEPT: unchanged, no drift.

### F2F findings 131-135 open items

- 131 F35 single-slot deferred cache — STILL-OPEN (documented).
- 131 F3B role error resource — STILL-OPEN (posts on wl_surface vs
  caller resource).
- 133 L2 layer configure policy — PARTIAL (initial arrange done;
  z-order/layout pass absent).
- 135 F22 weak/user-data model, F25 DRM KMS restore, F26 multi-output
  backend, F27 touch/gesture — STILL-OPEN (deferred).

### 137 server-adversarial

- FIXED: commit→present starvation (content_dirty → requestRender),
  key repeat + static caps.
- PARTIAL: move (grab + serial); empty-click focus clear.
- STILL-OPEN: maximize/fullscreen unanswered (log-only handlers — no
  scheduled.maximized/fullscreen writer, protocol deadlock for waiting
  clients); resize dead (no subscriber); activated never sent (no
  writer; CSD toolkits stay visually inactive); compositor close path;
  minimize/fullscreen log-only; multi-output (onNewOutput clobbers
  self.output); placement/stacking (toplevels at 0,0); activation
  focus re-eval; append-only tracking lists; quit binding forwarded to
  clients; onNewOutput error paths; output ref cleanup; SD4 resize.

### NEW behavioral deltas (not in 138, HIGH confidence)

1. Popup-grab press: ANY press dismisses (popup_done) and never reaches
   the popup client; wlroots delivers inside-presses to the popup first
   (wlr_xdg_popup.c:69-80). GTK/Qt menus unusable while grabbed.
2. Popup-grab enter/motion coords: raw seat coords sent as surface-local
   (xdg.zig:1571-1596); wlroots sends true surface-local. Hover logic
   in popup clients misbehaves.
3. Drag icon never rendered (data_device.zig:924-932); wlroots creates
   a drag-icon scene role (wlr_drag.c:402-442).
4. DnD enter sent to EVERY device of the target client
   (data_device.zig:409-436); wlroots enters only the first
   (wlr_drag.c:78-101). Multi-device clients get duplicate enters.
5. Verified parity: DnD drop validation and presentation flags match
   wlroots exactly.

## 3. Code quality

### 121 closure

10/17 fixed (dead fields removed, XRGB doc, new_input doc, decl-only
externs gone, cursor_visible removed). 7 still present, most GROWN:
god fns (main 172-473 → 382-893; drm startInner 198-440 → 258-596;
renderFrame 642-819 → 1598-1826; client main 88-289 → 116-337),
screencopy 11-param init, copyRows 6 params, nodeWidth/nodeHeight dup,
TestServer.pump now FIVE copies (~80 lines), defensive-branch judgment
calls. 121#5 drifted: current.dx/dy + current.committed dead (read only
by tests; doc claims phantom consumers).

### God functions (current)

main.zig main 512, renderFrame 229, onNewOutput 120, onSeatPointerMove
66; drm startInner 339, commit 103; client main 222; seat pointerButton
118, pointerAxisDir 139; data_device Drag.end 60, dragSetFocus 65.

### Dead code

- Surface.State.current.dx/dy + current.committed — write-only
  (surface.zig:160-170, 1114-1121; reads only in tests).
- Drag.origin, Drag.icon — written, never used (data_device.zig:901-905).
- Stale "DnD deferred" docs — data_device.zig:58-61, 73-76, 243-245,
  1090-1093, 2532-2535 contradict the landed machine.
- xdg_output doc claims output_already_exists error — not implemented
  (xdg_output.zig:16-17 vs 92-156).

### TigerStyle

Explicit error sets, split entry asserts, named allocators, sized ints:
positive. Violations: 4 unsafe-undefined without SAFETY lines
(xdg_output.zig:123, data_device.zig:280, xdg.zig:1524-1525,
seat.zig:339); unused `= undefined` defaults in PopupGrab (delete).

### Module split

18 modules over 250 prod LOC. Biggest: xdg.zig 2095, main.zig 1646,
seat.zig 1361, data_device.zig 1090 (7x growth since 121). Split
targets: xdg roles, server render/input, seat grab layer, DnD machine.

### New-code review (2026-08-13 additions)

HIGH: **UAF on a dropped drag offer after the source dies** —
data_device.zig:729-757 (sourceDestroy skips the drag path when
mgr.drag is already null) + 1161-1195 (offer.receive reads
source.mime_types); the dropped offer survives "for the transfer" but
nothing nulls its source pointer on source death (wlroots nulls it via
data_offer_handle_source_destroy). Fix: per-offer source-destroy
listener, or null offer.source on every referencing offer in
sourceDestroy.

MED: **wrong-owner grab teardown** — main.zig:2381 onSeatButton calls
`seat.endPointerGrab()` on every left release, cancelling the DnD drag
grab (middle-button-origin drag aborted by a left release) and
dismissing popup grabs (popupGrabEnd(true) → popup_done). Guard: end
only the swallow grab (drag_active / moving_toplevel).

MED: popup-grab motion coords (see delta 2); popupGrabEnd ends both
grabs unconditionally (safe today, future-owner hazard); xdg_output
missing dedup error.

Verified sound: popupGrabKey scancode, PopupGrab destroy-listener
lifetime, drag.end recursion guard, source-dies-mid-drag, drop ordering,
synth input boundedness.

## 4. Top findings ranked

1. **UAF: dropped-drag offer after source death** (data_device.zig)
   — correctness bug in the newest DnD code; fix with a per-offer
   source-destroy listener.
2. **Wrong-owner grab teardown** (main.zig:2381) — blanket
   endPointerGrab aborts DnD/popup grabs; guard to the swallow grab.
3. **maximize/fullscreen unanswered** (137 F2) — protocol deadlock for
   waiting clients; subscribe + write scheduled.* + scheduleConfigure
   (machinery exists).
4. **activated never sent** (137 F4) — CSD toolkits stay visually
   inactive; write scheduled.activated on focus.
5. **Popup-grab press semantics + motion coords** — menus unusable /
   wrong coords; deliver inside-presses, convert coords via scene
   origin.
6. **Input breadth** (touch/gestures/relative-pointer/tablet) — the
   canvas's native interactions unreachable; libinput silently drops
   touch/gesture events.
7. **No dmabuf / GPU client path** — blocks F-AX-6 + zero-copy; gles2
   unwired, no camera shader.
8. **DRM deployment** — no libseat/VT/hotplug; root-only VM usage.
9. **God fns + module bloat** — main/renderFrame/startInner +
   xdg/seat/data_device tripled; split by the documented phases/roles.
10. **Stale docs + dead state** — "DnD not implemented" docs, phantom
    current.dx/dy consumers, unimplemented xdg_output error; one line
    each, actively misleading.

## Source list

- Agent audits (full evidence, all file:line): agent://FeatureCompletenessAudit,
  agent://ReferenceBehaviorAudit, agent://CodeQualityAudit.
- Prior notes: 121 (slop scan), 123-128 (breadth), 131-135 (F2F),
  137 (server adversarial), 138 (61 findings), 139 (fix plan), 141
  (client conformance).
- References: wlroots 0.20.2, smithay v0.7.0, KWin master clones.
