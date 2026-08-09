# XdgShell (xdg-shell) — wlroots/smithay diff

Module: `src/shell/xdg.zig` (M1 scope: xdg_wm_base global, XdgSurface/XdgToplevel/XdgPopup state machines, configure/ack_configure, map/unmap; no seat interaction, no popup grabs, no constraint adjustment). wlroots: `types/xdg_shell/` + `include/wlr/types/wlr_xdg_shell.h`. smithay: `src/wayland/shell/xdg/` (mod.rs + handlers/).

## Surface

Public inventory of our module (`src/shell/xdg.zig`, grep `pub const`/`pub fn`):

- `XdgShell` struct (xdg.zig:57) — the xdg_wm_base global.
  - `init` (xdg.zig:76), `deinit` (xdg.zig:114)
  - fields: `toplevels`, `popups` role lists, `events.new_toplevel` / `events.new_popup` signals
- `XdgSurface` struct (xdg.zig:194) — per-wl_surface role state.
  - fields: `role`, `configured`, `configure_serial`, `acked_serial`, `configure_sent`, `pending_geometry`/`current_geometry`, `geometry_set`, `toplevel`, `popup`
  - fns: `sendConfigureEvent` (xdg.zig:223), `ackConfigure` (xdg.zig:233), `unmapSurface` (xdg.zig:252)
- `ToplevelState` struct (xdg.zig:421) — compositor-authored state: maximized/fullscreen/resizing/activated, width/height, min/max.
- `XdgToplevel` struct (xdg.zig:433) — toplevel role object.
  - `configure` (xdg.zig:467), `sendClose` (xdg.zig:487)
  - fields: `title`, `app_id`, `current`/`pending`, `configured_size`, events request_move/request_resize/request_maximize/request_fullscreen/destroy
- `XdgPopup` struct (xdg.zig:597) — popup role object.
  - `configure` (xdg.zig:615), `sendPopupDone` (xdg.zig:630)
  - fields: `geometry`, `parent`
- `PositionerState` (private const, xdg.zig:669) with pub `geometry` (xdg.zig:686) — positioner rules + placement math.

Private handlers cited in rows (not inventory): `wmBaseRequest` (:136), `wmBaseGetXdgSurface` (:157), `toplevelRequest` (:533), `stateValues` (:512), `popupRequest` (:635), `positionerRequest` (:747), `positionerEdges` (:720), `xdgSurfaceClientCommit` (:803), `xdgSurfaceCommit` (:825), `xdgSurfaceDestroy` (:301).

## Comparison

### XdgShell.init — xdg_wm_base global (v7)
- ours: registers xdg_wm_base at `generated_version`; pong only logged (xdg.zig:76-113, 136-155).
- wlroots: `wlr_xdg_shell_create` (wlr_xdg_shell.c:143), WM_BASE_VERSION 7; per-client `wlr_xdg_client` with surfaces list + ping timer (wlr_xdg_shell.c:96-126).
- smithay: `XdgShellState::new` registers the global at v7 with default WmCapabilities (mod.rs:1225-1244).
- verdict: same (global + version). Ours lacks the per-client ping machinery.

### XdgShell.deinit
- ours: removes global, destroys role resources, frees lists (xdg.zig:114-133).
- wlroots: `handle_display_destroy` tears down global + shell (wlr_xdg_shell.c:128-141).
- smithay: no explicit teardown; resources dropped via user-data destructors.
- verdict: same.

### xdg_wm_base.destroy
- ours: destroys the resource unconditionally (xdg.zig:138-140).
- wlroots: posts DEFUNCT_SURFACES error if the client still has child surfaces (wlr_xdg_shell.c:44-58).
- smithay: CORRECTED 2026-08-09 — a defunct guard DOES exist: `xdg_wm_base::Error::DefunctSurfaces` posted at `src/wayland/shell/xdg/handlers/wm_base.rs:96` (the earlier grep missed the handlers/ submodule).
- verdict: divergent. Ours misses the protocol-required defunct guard.

### get_xdg_surface (XdgSurface creation)
- ours: assigns the "xdg_surface" role; no buffer-at-creation check (xdg.zig:157-192).
- wlroots: `create_xdg_surface` posts UNCONFIGURED_BUFFER if the wl_surface already carries a buffer (wlr_xdg_surface.c:397-410).
- smithay: `compositor::give_role` only; no buffer-at-creation check (surface.rs:93-99).
- verdict: divergent (minor). Ours and smithay skip the check wlroots enforces.

### xdg_surface.ack_configure validation
- ours: accepts any serial in `(acked_serial, configure_serial]` — in-range serials never sent are accepted as long as they are newer than the last ack; posts invalid_serial otherwise (xdg.zig:233-245).
- wlroots: exact match against `configure_list`; unknown serial → INVALID_SURFACE_STATE on wm_base; older pending configures discarded; ack_configure signal (wlr_xdg_surface.c:63-117).
- smithay: exact match against `pending_configures`; unknown → InvalidSurfaceState; older configures dropped via `retain(|c| c.serial > serial)` (mod.rs:219-238; surface.rs:267-335).
- verdict: divergent. Ours is accept-stale: an in-range serial that was never sent (e.g. latest sent = 5, ack 3 with no configure 3) passes. Both references reject any serial not in their pending list. Ours also lacks the must-have-a-role check (wlroots NOT_CONSTRUCTED, wlr_xdg_surface.c:82-86; smithay NotConstructed, surface.rs:279-289).

### Initial configure flow
- ours: auto-sends the first configure on the first commit when `!configure_sent` — toplevel 0x0 with no states, popup positioner geometry (xdg.zig:825-843); synchronous serial from `nextSerial`.
- wlroots: compositor-driven. `wlr_xdg_surface_schedule_configure` queues an idle `surface_send_configure`; nothing is sent automatically (wlr_xdg_surface.c:126-221). The first toplevel configure also carries wm_capabilities (wlr_xdg_toplevel.c:497-506).
- smithay: compositor-driven. The compositor must call `ToplevelSurface::send_configure` in `new_toplevel` (mod.rs:1091-1099, 1487-1558); `initial_configure_sent` tracks it; first configure carries default capabilities (surface.rs:110-128).
- verdict: divergent. Ours auto-sends 0x0 and never sends wm_capabilities; wlroots/smithay let the compositor own initial size and capabilities.

### XdgToplevel.configure — configure + states
- ours: synchronous `configure(width, height)` sends xdg_toplevel.configure + xdg_surface.configure(serial); states from `stateValues` of `current` (xdg.zig:467-484, 512-530).
- wlroots: `wlr_xdg_toplevel_configure` sets `scheduled` and defers to the schedule_configure idle (wlr_xdg_toplevel.c:569-592); `send_xdg_toplevel_configure` serializes states incl. tiled/suspended/constrained with version gating plus configure_bounds/wm_capabilities events (wlr_xdg_toplevel.c:25-123).
- smithay: `ToplevelSurface::send_configure` pushes a `ToplevelConfigure` into `pending_configures`, computes bounds/capabilities changes, sends via `send_toplevel_configure` (mod.rs:1487-1558; toplevel.rs:260-…).
- verdict: close for the 4 core states; divergent on breadth. Ours has a fixed `[4]u32` states buffer and no bounds/wm_capabilities/tiled/suspended/constrained.

### ToplevelState breadth
- ours: 4 bools (maximized/fullscreen/resizing/activated) + size + min/max (xdg.zig:421-431).
- wlroots: `wlr_xdg_toplevel_state` adds suspended, tiled, constrained (wlr_xdg_shell.h:141-148).
- smithay: `ToplevelState` has size, bounds, states, fullscreen_output, decoration_mode, capabilities (mod.rs:866-884); `ToplevelStateSet` supports every protocol state with version filtering (mod.rs:909-990).
- verdict: divergent. Ours covers 4 of the states; tiled (v2+), suspended (v6+), constrained (v7+) are missing (wlr_xdg_toplevel.c:97-121, 625-664; smithay mod.rs:960-985).

### XdgToplevel.sendClose
- ours: sends xdg_toplevel.close (xdg.zig:487-489).
- wlroots: `wlr_xdg_toplevel_send_close` (wlr_xdg_toplevel.c:565-567).
- smithay: `ToplevelSurface::send_close` (mod.rs:1674-1676).
- verdict: same.

### toplevel move / resize / show_window_menu
- ours: move/resize emit bare signals; no seat/serial; no configured check; show_window_menu ignored (xdg.zig:533-577).
- wlroots: `request_move`/`request_resize`/`request_show_window_menu` events carry seat+serial after a NOT_CONSTRUCTED check; resize validates edges (INVALID_RESIZE_EDGE) (wlr_xdg_toplevel.c:262-335).
- smithay: `move_request`/`resize_request`/`show_window_menu` trait callbacks with seat/serial/edges (mod.rs:1109-1161; toplevel.rs:107-129).
- verdict: divergent. Ours lacks seat/serial data (M3) and the configured/edge validation.

### toplevel set_parent
- ours: ignored (xdg.zig:537-538).
- wlroots: `wlr_xdg_toplevel_set_parent` with loop detection and parent-unmap listener (wlr_xdg_toplevel.c:178-235).
- smithay: `set_parent` with validity check + `parent_changed` callback (toplevel.rs:236-…).
- verdict: missing.

### toplevel maximize / fullscreen / minimize requests
- ours: sets `pending` flag, emits request_maximize/request_fullscreen; minimize ignored (xdg.zig:552-577).
- wlroots: stores in `requested` (incl. fullscreen_output tracking), emits signals (wlr_xdg_toplevel.c:361-448).
- smithay: `maximize_request` (default sends configure), `fullscreen_request(output)`, `minimize_request` callbacks (mod.rs:1128-1161; toplevel.rs:140-160).
- verdict: close. Ours lacks fullscreen_output tracking.

### min/max size validation
- ours: validated at commit in `xdgSurfaceClientCommit` — negatives, max<min → invalid_size (xdg.zig:810-821).
- wlroots: same check in `handle_xdg_toplevel_client_commit` (wlr_xdg_toplevel.c:138-153).
- smithay: no validation; stored double-buffered in `SurfaceCachedState.min_size/max_size` (mod.rs:1053-1061; toplevel.rs:130-139).
- verdict: same as wlroots, stricter than smithay.

### Unconfigured-buffer commit check
- ours: posts unconfigured_buffer when a buffer is committed before ack (xdg.zig:803-809).
- wlroots: same in `xdg_surface_role_client_commit` (wlr_xdg_surface.c:282-296).
- smithay: `pre_commit_hook` posts UnconfiguredBuffer (mod.rs:1615-1621).
- verdict: same.

### XdgPopup.configure
- ours: sends xdg_popup.configure (positioner geometry) + xdg_surface.configure, once, on first commit (xdg.zig:615-627, 836-841).
- wlroots: `send_xdg_popup_configure` (geometry + optional repositioned token) via schedule_configure (wlr_xdg_popup.c:13-37).
- smithay: `PopupSurface::send_configure` with re-configure gating (AlreadyConfigured / NotReactive) and `send_repositioned(token)` (mod.rs:1894-1952; popup.rs:108-122).
- verdict: close for the initial configure only. Ours cannot re-configure or send repositioned.

### XdgPopup.sendPopupDone
- ours: sends xdg_popup.popup_done (xdg.zig:630-632).
- wlroots: popup_done sent in `wlr_xdg_popup_destroy` and at grab end (wlr_xdg_popup.c:486-493, 116-…).
- smithay: `PopupSurface::send_popup_done` (mod.rs:2073-2075).
- verdict: same event; ours lacks the grab-driven auto-dismiss path.

### popup grab
- ours: ignored (xdg.zig:639-641).
- wlroots: full per-seat grab — pointer/keyboard/touch grabs, dismiss on outside button, INVALID_GRAB if already mapped, NOT_THE_TOPMOST_POPUP at grab (wlr_xdg_popup.c:116-311).
- smithay: `grab` trait callback; `requested_grab` stored and applied at first map commit (mod.rs:1125, 1986-1991; popup.rs:41-54).
- verdict: missing (M3).

### popup reposition
- ours: ignored (xdg.zig:642-644).
- wlroots: recomputes geometry from the new positioner, sets REPOSITION_TOKEN, schedules configure, emits reposition (wlr_xdg_popup.c:317-343).
- smithay: `reposition_request` callback; `send_repositioned(token)` sends xdg_popup.repositioned (mod.rs:1178, 1950-1952; popup.rs:56-66).
- verdict: missing (M4).

### popup parenting / topmost enforcement
- ours: parent stored as a raw XdgSurface pointer; no parent-role check, no parentless-commit rejection, no topmost rules (xdg.zig:262-271, 635-647).
- wlroots: INVALID_POPUP_PARENT if the parent has no role (wlr_xdg_popup.c:382-386); commit of a parentless popup rejected NOT_CONSTRUCTED (wlr_xdg_popup.c:247-253); destroy and grab enforce NOT_THE_TOPMOST_POPUP (wlr_xdg_popup.c:345-355, 298-301).
- smithay: `pre_commit_hook` rejects a popup without parent (mod.rs:1986-1992); VERIFIED 2026-08-09: no topmost enforcement anywhere in the xdg module (grep `topmost` over src/wayland/shell/xdg/ is empty — smithay leaves stacking to the compositor's space).
- verdict: divergent. Ours lacks all three: parent-role check, parentless-commit rejection, topmost rules.

### positioner completeness at get_popup
- ours: requires size_set and anchor_rect_set; posts wm_base invalid_positioner on the xdg_surface resource (xdg.zig:213-227).
- wlroots: `wlr_xdg_positioner_is_complete` = size.width>0 && anchor_rect.width>0; posts INVALID_POSITIONER (wlr_xdg_positioner.c:216-219; wlr_xdg_popup.c:370-375).
- smithay: no completeness check at get_popup; geometry computed from the possibly-default PositionerState (surface.rs:153-180).
- verdict: same as wlroots, stricter than smithay. Minor: ours posts the wm_base error code on the xdg_surface resource; wlroots posts on the client resource.

### positioner set_size / set_anchor_rect
- ours: validates size >0, anchor_rect >=0 (xdg.zig:752-767).
- wlroots: same (wlr_xdg_positioner.c:15-47).
- smithay: same for size; anchor_rect requires >=1, stricter (positioner.rs:31-45).
- verdict: same (ours and wlroots agree on anchor_rect >=0).

### positioner anchor / gravity / constraint_adjustment validation
- ours: no enum validation; unknown values fall back to none in `positionerEdges` (xdg.zig:720-744, 770-781).
- wlroots: posts INVALID_INPUT for invalid anchor/gravity/constraint_adjustment (wlr_xdg_positioner.c:50-97).
- smithay: `WEnum::Value` match; invalid enum values silently ignored (positioner.rs:46-66).
- verdict: divergent. wlroots validates; ours and smithay do not. Ours additionally coerces unknown values to none, which is lossy.

### PositionerState.geometry
- ours: offset + anchor edge + gravity offset math (xdg.zig:686-716).
- wlroots: `wlr_xdg_positioner_rules_get_geometry` (wlr_xdg_positioner.c:221-247).
- smithay: `PositionerState::get_geometry` (mod.rs:640-698).
- verdict: same (identical placement rules).

### constraint adjustment
- ours: none; `constraint_adjustment` stored but unused (xdg.zig:773-774).
- wlroots: flip/slide/resize via `wlr_xdg_positioner_rules_unconstrain_box` (wlr_xdg_positioner.c:500-519).
- smithay: `PositionerState::get_unconstrained_geometry` (mod.rs:700-…).
- verdict: missing (M4).

### set_window_geometry / window geometry
- ours: double-buffered; applied to `current_geometry` at ack_configure time; no role requirement (xdg.zig:233-245, 286-294).
- wlroots: role required (NOT_CONSTRUCTED); `update_geometry` runs at commit/map and intersects with surface extents, falling back if empty (wlr_xdg_surface.c:205-226, 259-280).
- smithay: double-buffered cached geometry; role required (surface.rs:231-249; mod.rs:1043-1062).
- verdict: divergent. Ours applies geometry at ack time (not commit), skips the role check, and does not intersect with extents.

### unmap / reset
- ours: `unmapSurface` resets configure_sent=false and acked_serial=null but keeps `configured=true`; no pending-configure list; child popups untouched (xdg.zig:252-267).
- wlroots: `reset_xdg_surface` sets configured=false, initialized=false, clears the configure_list, destroys all child popups (wlr_xdg_surface.c:26-44).
- smithay: on unmap resets role attributes but deliberately keeps pending_configures (mod.rs:1637-1645).
- verdict: divergent. After an unmap ours still treats the surface as configured, so a re-map commit with a buffer can skip the fresh configure+ack; wlroots rejects it as unconfigured.

### ping
- ours: none; pong logged only (xdg.zig:151-154).
- wlroots: `wlr_xdg_surface_ping` + per-client ping timer, ping_timeout signal (wlr_xdg_surface.c:553-565; wlr_xdg_shell.c:81-94, 120-125).
- smithay: pending_ping on ShellClientData, `client_pong` callback (mod.rs:1086, 1311-1316).
- verdict: missing.

## Gaps
1. **accept-stale ack_configure** — ours accepts any in-range, monotonic serial, including serials never sent (xdg.zig:233-245); wlroots requires an exact configure_list match (wlr_xdg_surface.c:76-107) and smithay an exact pending_configures match (mod.rs:219-238). Also no must-have-a-role (NOT_CONSTRUCTED) check.
2. **Auto-initial configure 0x0, no wm_capabilities** — ours sends 0x0 on first commit (xdg.zig:825-843); wlroots/smithay are compositor-driven and announce wm_capabilities with the first configure (wlr_xdg_toplevel.c:497-506; surface.rs:110-128).
3. **State breadth** — only maximized/fullscreen/resizing/activated; tiled, suspended, constrained_* never sent (xdg.zig:512-530 vs wlr_xdg_toplevel.c:97-121; mod.rs:909-990).
4. **configure_bounds and wm_capabilities events never sent** (vs wlr_xdg_toplevel.c:30-52; mod.rs:1513-1519, toplevel.rs:260-…).
5. **Popup is a stub** — no grab, no reposition/token, no topmost enforcement, no INVALID_POPUP_PARENT check, no parentless-commit rejection (xdg.zig:635-647 vs wlr_xdg_popup.c:247-355, 382-386; mod.rs:1986-1992).
6. **No constraint adjustment** — reactive repositioning impossible (vs wlr_xdg_positioner.c:500-519; mod.rs:700-…).
7. **Window geometry applied at ack, not commit; no extent intersection** (xdg.zig:241 vs wlr_xdg_surface.c:259-280).
8. **Unmap keeps configured=true and leaves child popups alive** (xdg.zig:252-267 vs wlr_xdg_surface.c:26-44).
9. **No ping/ping_timeout** (vs wlr_xdg_shell.c:81-94, 120-125; mod.rs:1086).
10. **wm_base.destroy missing DEFUNCT_SURFACES guard** (xdg.zig:138-140 vs wlr_xdg_shell.c:44-58).
11. **get_xdg_surface accepts a surface that already has a buffer** (vs wlr_xdg_surface.c:397-410).
12. **set_parent / show_window_menu / set_minimized ignored; move/resize lack seat/serial and configured check** (xdg.zig:533-577 vs wlr_xdg_toplevel.c:262-448).
13. **Positioner enum validation absent** — wlroots posts INVALID_INPUT; ours coerces unknown values to none (xdg.zig:720-744 vs wlr_xdg_positioner.c:50-97).
14. **Fullscreen requested output not tracked** (vs wlr_xdg_toplevel.c:385-400).

## Verdict
Low-to-medium parity. The core protocol skeleton matches: configure/ack/commit sequencing, unconfigured-buffer rejection, min/max validation, positioner placement math, and the completeness check are correct and agree with wlroots (and are stricter than smithay in two spots). The riskiest divergences: (1) accept-stale ack_configure breaks the pending-serial contract both references enforce — a client can ack a never-sent serial and desync the configured state; (2) the auto-sent 0x0 initial configure with no wm_capabilities takes initial sizing and capability announcement out of the compositor's hands; (3) the popup is a stub — no grab, reposition, topmost or parent enforcement, so popups only work as static, unmanaged tooltips; (4) unmap leaves `configured=true`, so a re-map can skip the mandatory fresh configure. Secondary: no ping, no bounds/wm_capabilities, and no tiled/suspended/constrained states.
