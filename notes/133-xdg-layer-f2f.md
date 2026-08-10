# 133 — xdg-shell + layer-shell function-by-function audit (ours vs wlroots 0.20.2 / smithay v0.7.0 / KWin master)

Audit date: 2026-08-10. No code changed. This note is the impl backlog.
Ours: `src/shell/xdg.zig` (2134 ln), `src/shell/layer_shell.zig` (996 ln).
Refs: `~/projects/freedesktop-wlroots-wlroots/types/xdg_shell/`, `types/wlr_layer_shell_v1.c`;
`~/projects/github-Smithay-smithay/src/wayland/shell/xdg/`, `wlr_layer/`;
`~/projects/invent-kde-org-plasma-kwin/src/wayland/xdgshell.cpp`, `layershell_v1.cpp`.
Ground truth XML: `protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml`,
`protocols/wlroots/wlr-layer-shell-unstable-v1.xml`.
Versions: ours registers xdg_wm_base 7 (build.zig:39), zwlr_layer_shell_v1 5 (build.zig:44);
wlroots WM_BASE_VERSION 7 (wlr_xdg_shell.c:5), LAYER_SHELL_VERSION 5 (wlr_layer_shell_v1.c:19);
smithay global 5 layer; KWin s_version 6 xdg (xdgshell.cpp:31), 5 layer (layershell_v1.cpp:24).
Mark `[INFERENCE]` for anything not directly read.

Architecture note: ours is a policy-in-shell design. The module auto-sends the initial
configure inside the role commit hook; the compositor (main.zig) only tracks objects and
never calls `t.configure` (main.zig:823-836, 859-867). wlroots/smithay/KWin push configure
from the compositor side (idle-coalesced in wlroots). The toplevel `current` state is never
mutated by main.zig, so every real toplevel renders at its client-chosen size with no states.

---

## 1. Function-level comparison tables

### 1.1 xdg_wm_base (XdgShell)

| ours fn | ours line | ref fn | ref line | what it does | parity |
|---|---|---|---|---|---|
| `XdgShell.init` | xdg.zig:77 | `wlr_xdg_shell_create` | wlr_xdg_shell.c:161 | create global, version 7, events new_surface/new_toplevel/new_popup | OK |
| `XdgShell.deinit` | xdg.zig:115 | `handle_display_destroy` | wlr_xdg_shell.c:141 | teardown: destroy role resources then free | OK (ours lacks destroy signal) |
| `wmBaseBind` | xdg.zig:150 | `xdg_shell_bind` | wlr_xdg_shell.c:93 | per-binding WmBaseState; wlroots adds per-client ping_timer | PARTIAL (no ping timer) |
| `wmBaseRequest.destroy` | xdg.zig:166-179 | `xdg_shell_handle_destroy` | wlr_xdg_shell.c:44 | defunct_surfaces error if surfaces live, else destroy | OK |
| `wmBaseRequest.create_positioner` | xdg.zig:180-190 | `xdg_shell_handle_create_positioner` | wlr_xdg_shell.c:16 | create PositionerState | OK |
| `wmBaseRequest.get_xdg_surface` | xdg.zig:191 | `xdg_shell_handle_get_xdg_surface` | wlr_xdg_shell.c:23 | route to get | OK |
| `wmBaseRequest.pong` | xdg.zig:194-197 | `xdg_shell_handle_pong` | wlr_xdg_shell.c:32 | clear ping_serial/timer + emit | PARTIAL (log only; no ping state) |
| `wmBaseDestroy` | xdg.zig:194 | `xdg_client_handle_resource_destroy` | wlr_xdg_shell.c:65 | client teardown: ours defers state free until last surface detaches (W4 fix) | OK |
| `wmBaseGetXdgSurface` | xdg.zig:207 | `create_xdg_surface` | wlr_xdg_surface.c:397 | role check (role err on wm_base), unconfigured_buffer check, XdgSurface create | OK |
| — | — | `xdg_client_ping_timeout` | wlr_xdg_shell.c:81 | emit ping_timeout per surface after 10 s | MISSING (F3) |
| — | — | `XdgShellHandler::client_pong` | smithay wm_base.rs:75-81 | pong callback | MISSING |

### 1.2 XdgSurface

| ours fn | ours line | ref fn | ref line | what it does | parity |
|---|---|---|---|---|---|
| `XdgSurface.sendConfigureEvent` | xdg.zig:305 | `xdg_surface_send_configure` in `surface_send_configure` | wlr_xdg_surface.c:126-152 | send xdg_surface.configure, record serial | OK (ours synchronous; refs idle-scheduled) |
| `resetConfigureState` | xdg.zig:318 | `reset_xdg_surface` | wlr_xdg_surface.c:26 | clear configured/initialized/serials | PARTIAL (no popup/child teardown, no role-object reset) |
| `ackConfigure` | xdg.zig:330 | `xdg_surface_handle_ack_configure` | wlr_xdg_surface.c:63 | serial-list lookup, prune older, set configured | PARTIAL (no role payload application — F7) |
| `unmapSurface` | xdg.zig:365 | `wlr_surface_unmap` paths | wlr_xdg_surface.c:315-352 | unmap + reset | PARTIAL (early-return when unmapped skips reset — F8) |
| `xdgSurfaceRequest.destroy` | xdg.zig:404 | `xdg_surface_handle_destroy` | wlr_xdg_surface.c:231 | defunct_role_object then teardown | PARTIAL (ours also tears roles down; wlroots returns) |
| `xdgSurfaceRequest.get_toplevel` | xdg.zig:415 | `xdg_surface_handle_get_toplevel` | wlr_xdg_surface.c:197 | role assign, XdgToplevel create, new_toplevel | OK |
| `xdgSurfaceRequest.get_popup` | xdg.zig:458 | `xdg_surface_handle_get_popup` + `create_xdg_popup` | wlr_xdg_popup.c:370 | parent role check, positioner completeness, popup create | OK (completeness check differs — F13) |
| `xdgSurfaceRequest.set_window_geometry` | xdg.zig:386-402 | `xdg_surface_handle_set_window_geometry` | wlr_xdg_surface.c:205 | not_constructed, invalid_size, double-buffer rect | OK |
| `xdgSurfaceDestroyRequest` | xdg.zig:404 | `xdg_surface_handle_destroy` | wlr_xdg_surface.c:231 | destroy request | OK |
| `xdgSurfaceDestroy` | xdg.zig:530 | `destroy_xdg_surface` | wlr_xdg_surface.c:528 | detach role, unmap, free | OK |
| `xdgSurfaceClientCommit` | xdg.zig:1076 | `xdg_surface_role_client_commit` | wlr_xdg_surface.c:282 | unconfigured_buffer, popup-parent, min/max checks | OK (order differs: ours buffer-check first, wlroots parent-check inside role switch) |
| `xdgSurfaceCommit` | xdg.zig:1107 | `xdg_surface_role_commit` | wlr_xdg_surface.c:315 | initial configure on first commit, unmap reset | OK (auto-configure vs compositor-driven — L2 analog) |
| `xdgSurfaceMap` | xdg.zig:1132 | `xdg_surface_role_map` | wlr_xdg_surface.c:353 | geometry update on map | PARTIAL (ours no-op; refs recompute effective geometry) |
| `xdgSurfaceUnmap` | xdg.zig:1142 | role reset in commit | wlr_xdg_surface.c:315-330 | NULL-buffer unmap reset | OK |
| `xdgSurfaceRoleDestroy` | xdg.zig:1150 | `xdg_surface_role_destroy` | wlr_xdg_surface.c:360 | wl_surface destroy cascades | OK |
| — | — | `wlr_xdg_surface_schedule_configure` | wlr_xdg_surface.c:156 | idle-coalesced configure scheduling | MISSING (F6) |
| — | — | `update_geometry` | wlr_xdg_surface.c:259 | effective geometry = extents ∩ window_geometry | MISSING (F15) |
| — | — | `wlr_xdg_surface_ping` | wlr_xdg_surface.c:553 | send ping, arm timer | MISSING (F3) |
| — | — | `wlr_xdg_surface_surface_at`/`popup_surface_at`/`for_each_surface` | wlr_xdg_surface.c:580-656 | popup-aware hit-test/iteration | MISSING (F12) |

### 1.3 XdgToplevel

| ours fn | ours line | ref fn | ref line | what it does | parity |
|---|---|---|---|---|---|
| `XdgToplevel.configure` | xdg.zig:628 | `wlr_xdg_toplevel_configure` + `send_xdg_toplevel_configure` | wlr_xdg_toplevel.c:569, 25 | send configure(width,height,states) + surface.configure | PARTIAL (no bounds/caps; no version gating — F4/F5) |
| `XdgToplevel.sendClose` | xdg.zig:648 | `wlr_xdg_toplevel_send_close` | wlr_xdg_toplevel.c:567 | send close | OK |
| `setTitle` | xdg.zig:652 | `xdg_toplevel_handle_set_title` | wlr_xdg_toplevel.c:222 | UTF-8 check, store, emit | PARTIAL (no set_title event; log-only on invalid — F14) |
| `setAppId` | xdg.zig:670 | `xdg_toplevel_handle_set_app_id` | wlr_xdg_toplevel.c:245 | store, emit | PARTIAL (no set_app_id event) |
| `stateValues` | xdg.zig:682 | states array in `send_xdg_toplevel_configure` | wlr_xdg_toplevel.c:76-124 | serialize state bools → enum array | PARTIAL (order matches; no version filter — F5) |
| `toplevelRequest.set_parent` | xdg.zig:741-756 | `xdg_toplevel_handle_set_parent` + `wlr_xdg_toplevel_set_parent` | wlr_xdg_toplevel.c:206, 178 | parent assignment, loop check, unmap hook | PARTIAL (self-check only; no storage — F18) |
| `toplevelRequest.show_window_menu` | xdg.zig:746-758 | `xdg_toplevel_handle_show_window_menu` | wlr_xdg_toplevel.c:262 | not_constructed check + emit w/ seat,serial,x,y | PARTIAL (check ok; event MISSING — F11) |
| `toplevelRequest.move` | xdg.zig:763-772 | `xdg_toplevel_handle_move` | wlr_xdg_toplevel.c:288 | not_constructed + emit w/ seat,serial | PARTIAL (no seat/serial — F11) |
| `toplevelRequest.resize` | xdg.zig:775-793 | `xdg_toplevel_handle_resize` | wlr_xdg_toplevel.c:312 | edge validation + emit w/ seat,serial,edges | PARTIAL (edge list ok; no seat/serial) |
| `toplevelRequest.set_max/min_size` | xdg.zig:795-803 | `xdg_toplevel_handle_set_max/min_size` | wlr_xdg_toplevel.c:345-359 | pending min/max | PARTIAL (validated then dropped — F9) |
| `toplevelRequest.set/unset_maximized` | xdg.zig:804-813 | `xdg_toplevel_handle_set/unset_maximized` | wlr_xdg_toplevel.c:361-375 | pending + request_maximize | OK |
| `toplevelRequest.set/unset_fullscreen` | xdg.zig:814-821 | `xdg_toplevel_handle_set_fullscreen` + `store_fullscreen_requested` | wlr_xdg_toplevel.c:392-424 | pending + request_fullscreen + output | PARTIAL (output dropped — F10) |
| `toplevelRequest.set_minimized` | xdg.zig:822-823 | `xdg_toplevel_handle_set_minimized` | wlr_xdg_toplevel.c:426 | request_minimize | PARTIAL (log only — F10) |
| `toplevelDestroy` | xdg.zig:826 | `destroy_xdg_toplevel` / `reset_xdg_toplevel` | wlr_xdg_toplevel.c:542, 523 | unmap, clear title/app_id/parent, free | PARTIAL (no pre-map reset — F8) |
| — | — | `wlr_xdg_toplevel_set_size/activated/maximized/fullscreen/resizing/tiled/bounds/wm_capabilities/suspended/constrained` | wlr_xdg_toplevel.c:593-667 | per-field scheduled setters | MISSING (F6) |
| — | — | `handle_xdg_toplevel_ack_configure` | wlr_xdg_toplevel.c:10 | apply acked payload to pending | MISSING (F7) |

### 1.4 XdgPopup

| ours fn | ours line | ref fn | ref line | what it does | parity |
|---|---|---|---|---|---|
| `XdgPopup.configure` | xdg.zig:864 | `send_xdg_popup_configure` | wlr_xdg_popup.c:13 | popup.configure(geometry) + surface.configure | OK (no repositioned token path) |
| `XdgPopup.sendPopupDone` | xdg.zig:879 | `wlr_xdg_popup_destroy` popup_done / smithay `send_popup_done` | wlr_xdg_popup.c:486; smithay mod.rs:2073 | send popup_done | OK (ours send-only, does not destroy) |
| `popupRequest.grab` | xdg.zig:884-891 | `xdg_popup_handle_grab` + grabs | wlr_xdg_popup.c:272, 52-214 | seat grabs, invalid_grab, topmost checks | STUB (F2) |
| `popupRequest.reposition` | xdg.zig:891-896 | `xdg_popup_handle_reposition` | wlr_xdg_popup.c:317 | recompute geometry, repositioned event, reactive configure | STUB (F1) |
| `popupDestroy` | xdg.zig:900 | `destroy_xdg_popup` / `reset_xdg_popup` | wlr_xdg_popup.c:470, 444 | unmap, clear role, free | PARTIAL (no grab release, no topmost check — F2/F12) |
| `XdgPopup` fields (geometry, parent) | xdg.zig:846-862 | `wlr_xdg_popup` (parent, current/pending geometry, seat, grab_link, link) | wlr_xdg_popup.c:370-443 | popup state | PARTIAL (no child list, no seat) |
| — | — | `wlr_xdg_popup_get_toplevel_coords` | wlr_xdg_popup.c:500 | popup→toplevel coord walk | MISSING (F12) |
| — | — | `wlr_xdg_popup_unconstrain_from_box` | wlr_xdg_popup.c:521 | apply constraint box then schedule | MISSING (F1) |
| — | — | `handle_xdg_popup_ack_configure` | wlr_xdg_popup.c:6 | apply acked geometry to pending | MISSING (F7) |

### 1.5 XdgPositioner

| ours fn | ours line | ref fn | ref line | what it does | parity |
|---|---|---|---|---|---|
| `PositionerState.geometry` | xdg.zig:935 | `wlr_xdg_positioner_rules_get_geometry` | wlr_xdg_positioner.c:221 | anchor/gravity/offset geometry | OK (identical math; tests xdg.zig:1160-1186) |
| `positionerEdges` | xdg.zig:982 | `xdg_positioner_anchor_to_wlr_edges` | wlr_xdg_positioner.c:172 | enum→edge bits | OK |
| `positionerRequest.set_size` | xdg.zig:1001-1010 | `xdg_positioner_handle_set_size` | wlr_xdg_positioner.c:15 | positive size, invalid_input | OK |
| `positionerRequest.set_anchor_rect` | xdg.zig:1011-1021 | `xdg_positioner_handle_set_anchor_rect` | wlr_xdg_positioner.c:31 | non-negative, invalid_input | OK (ours allows 0; smithay/KWin reject <1 — ours + wlroots match XML) |
| `positionerRequest.set_anchor` | xdg.zig:1022-1030 | `xdg_positioner_handle_set_anchor` | wlr_xdg_positioner.c:50 | enum range, invalid_input | OK |
| `positionerRequest.set_gravity` | xdg.zig:1031-1039 | `xdg_positioner_handle_set_gravity` | wlr_xdg_positioner.c:66 | enum range, invalid_input | OK |
| `positionerRequest.set_constraint_adjustment` | xdg.zig:1040-1049 | `xdg_positioner_handle_set_constraint_adjustment` | wlr_xdg_positioner.c:82 | bit mask 0x3F, invalid_input | OK |
| `positionerRequest.set_offset/reactive/parent_size/parent_configure` | xdg.zig:1050-1055 | same-named handlers | wlr_xdg_positioner.c:99-135 | store rules | OK (no parent_configure has-flag; wlroots tracks has_parent_configure_serial — LOW) |
| `positionerDestroy` | xdg.zig:1057 | `xdg_positioner_handle_resource_destroy` | wlr_xdg_positioner.c:156 | free | OK |
| — | — | `wlr_xdg_positioner_is_complete` | wlr_xdg_positioner.c:216 | size>0 && anchor_rect>0 | PARTIAL (ours = flags — F13) |
| — | — | `xdg_positioner_rules_unconstrain_by_flip/slide/resize`, `rules_unconstrain_box` | wlr_xdg_positioner.c:340, 386, 454, 500 | constraint adjustment math | MISSING (F1) |
| — | — | smithay `get_unconstrained_geometry` | smithay mod.rs:693 | flip/slide/resize in one fn | MISSING (F1) |
| — | — | KWin `XdgPositioner::placement` | xdgshell.cpp:1228 | per-axis flip/slide/resize | MISSING (F1) |

### 1.6 zwlr_layer_shell_v1 (global) + zwlr_layer_surface_v1

| ours fn | ours line | ref fn | ref line | what it does | parity |
|---|---|---|---|---|---|
| `LayerShell.init/deinit` | layer_shell.zig:79, 112 | `wlr_layer_shell_v1_create` + `handle_display_destroy` | wlr_layer_shell_v1.c:596, 553 | global v5 | OK |
| `layerShellBind/Request` | layer_shell.zig:124, 132 | `layer_shell_bind`, impl | wlr_layer_shell_v1.c:527, 523 | shell requests | OK |
| `layerShellGetLayerSurface` | layer_shell.zig:144 | `layer_shell_handle_get_layer_surface` | wlr_layer_shell_v1.c:436 | layer validate, role, namespace, initial layer into pending+current | OK (wlroots also seeds every cached state) |
| `LayerSurface.sendConfigure` | layer_shell.zig:274 | `wlr_layer_surface_v1_configure` | wlr_layer_shell_v1.c:316 | configure(serial, w, h), record | PARTIAL (auto on first commit; refs compositor-driven — L2) |
| `LayerSurface.ackConfigure` | layer_shell.zig:292 | `layer_surface_handle_ack_configure` | wlr_layer_shell_v1.c:87 | serial-list check, prune, configured | PARTIAL (no actual size storage — L6) |
| `LayerSurface.reset` | layer_shell.zig:306 | `layer_surface_reset` | wlr_layer_shell_v1.c:33 | unmap reset | PARTIAL (state kept; XML wants full reset — L5) |
| `LayerSurface.unmapSurface` | layer_shell.zig:315 | wlroots unmap in role_destroy | wlr_layer_shell_v1.c:48, 408 | destroy-path unmap | OK |
| `LayerSurface.close` | layer_shell.zig:326 | `wlr_layer_surface_v1_destroy` | wlr_layer_shell_v1.c:337 | closed then destroy | OK (ours idempotent; wlroots not) |
| `LayerSurface.exclusiveEdge` + `deducedEdge` | layer_shell.zig:338, 373 | `wlr_layer_surface_v1_get_exclusive_edge` | wlr_layer_shell_v1.c:656 | edge deduction | OK (identical cases, tests layer_shell.zig:541-553) |
| `setKeyboardInteractivity` | layer_shell.zig:345 | `layer_surface_handle_set_keyboard_interactivity` | wlr_layer_shell_v1.c:216 | v<4 bool coercion, else range check | OK |
| `getPopup` | layer_shell.zig:362 | `layer_surface_handle_get_popup` | wlr_layer_shell_v1.c:240 | popup parenting | STUB posts -1 (L1) |
| `layerSurfaceRequest.set_size/anchor/zone/margin` | layer_shell.zig:386-409 | same handlers | wlr_layer_shell_v1.c:128-215 | pending state | OK (no INT32_MAX guard — L3) |
| `layerSurfaceRequest.set_layer` | layer_shell.zig:416-425 | `layer_surface_set_layer` | wlr_layer_shell_v1.c:260 | layer validate + pending | PARTIAL (error on shell resource — L4) |
| `layerSurfaceRequest.set_exclusive_edge` | layer_shell.zig:426-437 | `layer_surface_set_exclusive_edge` | wlr_layer_shell_v1.c:284 | single-bit edge | PARTIAL (ours stricter — L7) |
| `layerSurfaceRequest.ack_configure` | layer_shell.zig:411-414 | `layer_surface_handle_ack_configure` | wlr_layer_shell_v1.c:87 | ack | OK |
| `layerSurfaceDestroy` | layer_shell.zig:438 | `layer_surface_destroy` | wlr_layer_shell_v1.c:48 | detach role, unmap, free | OK |
| `layerSurfaceClientCommit` | layer_shell.zig:473 | `layer_surface_role_client_commit` | wlr_layer_shell_v1.c:345 | already_constructed, zero-size anchors, edge subset | OK (identical order + codes) |
| `layerSurfaceCommit` | layer_shell.zig:513 | `layer_surface_role_commit` | wlr_layer_shell_v1.c:386 | initial configure / unmap reset | OK (auto-configure — L2) |
| `layerSurfaceRoleDestroy` | layer_shell.zig:527 | `layer_surface_role_destroy` | wlr_layer_shell_v1.c:408 | wl_surface destroy | OK |
| — | — | `wlr_layer_surface_v1_for_each_surface/_surface_at` | wlr_layer_shell_v1.c:612-655 | popup-aware iteration/hit-test | MISSING (L1/F12) |

---

## 2. Findings

### F1. Popup constraint adjustment (flip/slide/resize) not implemented
- Severity: HIGH.
- Ours: `PositionerState.geometry` (xdg.zig:935) computes only the raw anchor/gravity/offset placement. `constraint_adjustment` is stored (xdg.zig:1040) and never read. `xdg_popup.reposition` is a stub (xdg.zig:891-896). Popup configure sends the unconstrained rect (xdg.zig:864-882).
- Ref: wlroots `wlr_xdg_positioner_rules_unconstrain_box` (wlr_xdg_positioner.c:500) with `unconstrain_by_flip` (340), `unconstrain_by_slide` (386), `unconstrain_by_resize` (454); applied via `wlr_xdg_popup_unconstrain_from_box` (wlr_xdg_popup.c:521) — order flip → slide → resize, revert flip if it does not help; slide prefers gravity direction when the popup contains the anchor rect; resize clips with zero-size guard. smithay: `PositionerState::get_unconstrained_geometry` (mod.rs:693). KWin: `XdgPositioner::placement` (xdgshell.cpp:1228).
- Expected: on popup creation and on `reposition`, the compositor passes the constraint box (output or parent-toplevel box in parent-surface-local coords) and the geometry must be adjusted per the client's adjustment bits before `xdg_popup.configure`.
- Why it matters: popups render off-screen and off-anchor; reactive tooltips/menus never re-place when the parent moves; `set_constraint_adjustment` is silently ignored (protocol lie).
- Fixability: FIXABLE-in-module. Pure rectangle math on data already stored (xdg.zig:918-980). Needs a `constrain(rect, box)` port of wlr_xdg_positioner.c:327-518 (~190 lines) + a constraint-box parameter threaded into popup configure. Constraint box source (output geometry vs parent) is compositor policy; default to output box.
- FIXED 2026-08-10: ported wlr_xdg_positioner.c:327-518 (unconstrainBox + flip/slide/resize steps, xdg.zig `PositionerState.constrainedGeometry`); `XdgPopup.setConstraintBox` accepts the compositor's usable rect and `configure()`/`reposition` re-place within it; main.zig's onNewPopup supplies the output mode rect; tests: "positioner constraint adjustment math (F1)", "popup configure applies the constraint box (F1)", "popup reposition re-places and acknowledges the token (F1/F7)".

### F2. xdg_popup.grab is a stub; no seat grabs, no invalid_grab, no topmost-popup rule
- Severity: HIGH.
- Ours: `popupRequest.grab` logs only (xdg.zig:884-891). No `invalid_grab` error for a mapped popup; no `not_the_topmost_popup`; no grab state on `XdgPopup`; no seat coupling.
- Ref: wlroots full grab machinery — `xdg_popup_handle_grab` (wlr_xdg_popup.c:272) validates mapped (invalid_grab), topmost (not_the_topmost_popup on wm_base), then installs pointer/keyboard/touch grabs (interfaces at wlr_xdg_popup.c:52-214); `reset_xdg_popup` (444) ends grabs. smithay defers grab to the commit hook (mod.rs:2030-2127, invalid_grab check) then `XdgShellHandler::grab`. KWin emits `grabRequested` (xdgshell.cpp:872-884), errors if mapped.
- Expected: `grab` with a mapped surface → `xdg_popup.invalid_grab`; grab only valid on the topmost popup of the seat's grab chain; while grabbed, input routes to the popup's client only; popup_done ends the grab.
- Why it matters: menus cannot be dismissed by outside clicks; compositors cannot route input during grabs; wlroots/smithay/KWin all treat this as core popup behavior.
- Fixability: NEEDS-wiring. seat.zig has no grab concept ([INFERENCE] — no grab API seen in src/compositor/seat.zig; only pointer/key/button events, main.zig:548-560). Requires seat grab interfaces + popup stacking (F12) before the module code can land.
- DEFERRED 2026-08-10 fixing round: seat grab interfaces and popup stacking (F12) are both STRUCTURAL and out of scope for this round; the module still logs `grab` (popupRequest).

### F3. ping/pong absent (no unresponsive detection)
- Severity: HIGH.
- Ours: `pong` logs only (xdg.zig:194-197). No `xdg_wm_base.ping` sender, no timer, no timeout event.
- Ref: wlroots `wlr_xdg_surface_ping` (wlr_xdg_surface.c:553) + per-client timer `xdg_client_ping_timeout` (wlr_xdg_shell.c:81), default 10 s (wlr_xdg_shell.c:175), `ping_timeout` signal. smithay `ShellClient::send_ping`/`unresponsive` (mod.rs:1349-1393, posts `unresponsive` error). KWin `XdgShellInterface::ping` + pingDelayed/pingTimeout (xdgshell.cpp:121-133).
- Expected: compositor pings on demand (e.g. for close/force-kill UI); pong matches the pending serial; timeout → `ping_timeout` event so the compositor can mark the window unresponsive.
- Why it matters: hung clients cannot be detected or force-closed; the ping wire event is simply never sent.
- Fixability: NEEDS-wiring. The module can add `sendPing()/onPong` + a pending-serial field (FIXABLE-in-module), but the timeout timer and unresponsive UI belong to main.zig policy.
- FIXED 2026-08-10: module tracks one pending ping serial per wm_base binding (`WmBaseState.ping_serial`), `XdgToplevel.ping()/pingPending()/wmBaseResource()`; pong with the matching serial clears it and emits `XdgShell.events.pong`; main.zig's repeating 5s loop timer (onPingTick) pings each distinct client and posts the unresponsive error (code 6) when a ping went unanswered; test: "ping/pong roundtrip and unresponsive tracking (F3)".

### F4. configure_bounds (v2+) and wm_capabilities (v6+) events never sent
- Severity: HIGH (protocol surface under-announced; the first configure must carry wm_capabilities per wlroots).
- Ours: `XdgToplevel.configure` (xdg.zig:628) sends only configure + surface.configure. `ToplevelState` (xdg.zig:565) has no bounds/caps fields. The test listener even lists `configure_bounds`/`wm_capabilities` (xdg.zig:1280-1291) that can never fire.
- Ref: wlroots `send_xdg_toplevel_configure` sends configure_bounds then wm_capabilities before configure (wlr_xdg_toplevel.c:33-75); seeds default caps at role creation (wlr_xdg_toplevel.c:524-532); setters `wlr_xdg_toplevel_set_bounds` (633), `set_wm_capabilities` (644). smithay `send_toplevel_configure` (toplevel.rs:262-311) sends both when changed. KWin `sendConfigureBounds`/`sendWmCapabilities` (xdgshell.cpp:739-766).
- Expected: `configure_bounds` on output/size changes; `wm_capabilities` on first configure and whenever the capability set changes.
- Why it matters: clients cannot honor work areas; clients never learn which actions the compositor supports (e.g. window menu is advertised then broken — see F11).
- Fixability: FIXABLE-in-module. Add bounds/caps fields to `ToplevelState`, emit both events version-gated in `configure()` before the states array.
- FIXED 2026-08-10: `ToplevelState.bounds_width/height` + `wm_capabilities` (WmCapabilities bool set); `XdgToplevel.configure` emits configure_bounds (since v4, on change) and wm_capabilities (since v5, before the first configure and on change); default caps (window_menu|maximize|fullscreen|minimize) seeded at role creation for v5+ clients per wlroots create_xdg_toplevel:299-309; tests: "xdg toplevel configure/ack roundtrip" (caps on first configure, bounds on change) + "wm_capabilities and configure_bounds version gating (F4)". Note: the audit brief said v2/v6; the vendored XML is authoritative — configure_bounds since 4, wm_capabilities since 5 (xdg-shell.xml:1189, 1220), matching wlroots' since-version macros.

### F5. States array not filtered by client version
- Severity: MED.
- Ours: `stateValues` (xdg.zig:682-737) emits `suspended` (9) and `constrained_*` (10-13) to any client, including v5 bindings, because it takes only `ToplevelState` (no resource version). The v5 test (xdg.zig:2053-2134) passes only because it sets states that are since ≤ 5.
- Ref: wlroots gates each state on the resource version (wlr_xdg_toplevel.c:83-124: tiled since v2, suspended since 6, constrained since 7); smithay `into_filtered_states` (mod.rs:946-974); KWin per-state version gates (xdgshell.cpp:708-727).
- Expected: a configure sent to a v5 client must never contain state values > 5.
- Why it matters: old toolkits (GTK < 3.24.30-era) mis-parse unknown state values; wire conformance per xdg-shell.xml since-annotations.
- Fixability: FIXABLE-in-module. Thread `resource.getVersion()` into `stateValues` (or filter in `configure`).
- FIXED 2026-08-10: `stateValues` takes the binding version and gates tiled_* (>=2), suspended (>=6), constrained_* (>=7) per the XML since annotations (wlroots gates identically, wlr_xdg_toplevel.c:83-124); `configure` passes `t.resource.getVersion()`; tests: "toplevel state values filtered by client version (F5)" + the v5 roundtrip now sets suspended/constrained and asserts they never arrive.

### F6. Configure payload model: no per-field scheduled state, no idle coalescing, compositor never configures
- Severity: MED (design).
- Ours: configure reads `t.current` (xdg.zig:628-646); the module auto-sends one configure (0×0, no states) on the first commit (xdg.zig:1107-1130). main.zig never calls `t.configure` (main.zig:823-836) — it only tracks the toplevel. No per-field "scheduled" struct, no `fields` bitmask, no coalescing.
- Ref: wlroots `wlr_xdg_toplevel_configure`/`set_size`/`set_activated`/… (wlr_xdg_toplevel.c:569-667) write into `scheduled` and call `wlr_xdg_surface_schedule_configure` (wlr_xdg_surface.c:156) which idle-coalesces multiple changes into one configure. smithay `with_pending_state` + `send_configure` (mod.rs:1696-1732) with change detection (`has_pending_changes`). KWin `XdgToplevelWindow::sendConfigure` driven by a configure timer (xdgshellwindow.cpp:66, 409).
- Expected: compositor policy sets size/states; each policy change produces exactly one configure; rapid changes coalesce.
- Why it matters: the compositor has no mechanism to resize/maximize a toplevel at all today. The ack payload model (F7) is the same seam.
- Fixability: STRUCTURAL. Touches the XdgToplevel public API shape and main.zig consumers; module-local emulation (a `pending_configure: ?ToplevelState` + send-on-commit) is possible but fights the current `current`-writes design.
- FIXED 2026-08-10 (orchestrator override: implement the module-local prescription): `XdgToplevel.scheduled: ToplevelState` holds the per-field state the next configure carries; `configure(width, height)` records a `ConfigurePayload {serial, width, height, state}` per configure; the ack applies the payload to `current` (the committed-against state). main.zig never called `configure` before and still does not; the module auto-configure now sends `scheduled.width/height`. Idle coalescing remains compositor-side policy (no timer in the module).

### F7. ack_configure applies no role payload
- Severity: MED.
- Ours: `ackConfigure` (xdg.zig:330-363) only validates serials and flips `configured`. No per-configure payload is stored (flat `sent_serials` list, xdg.zig:307-317), so nothing can be applied.
- Ref: wlroots `handle_xdg_toplevel_ack_configure` (wlr_xdg_toplevel.c:10-23) copies the acked configure's states+size into `toplevel->pending`; `handle_xdg_popup_ack_configure` (wlr_xdg_popup.c:6-11) copies geometry into `popup->pending`. smithay tracks `last_acked` per surface (mod.rs:1460-1467, 2133-2140).
- Expected: the last-acked configure's width/height/states define what the client committed against (the "current" state source in wlroots).
- Why it matters: no last-acked state; the compositor cannot distinguish "client is at the state I configured" from "client ignored the configure". Popup geometry cannot be re-derived from the acked configure (reactive popups, F1).
- Fixability: STRUCTURAL (tied to F6's payload model). A list of `{serial, width, height, states}` replacing `sent_serials` is a module-local change, but applying acked state into `current` collides with the policy-writes-current design.
- FIXED 2026-08-10 (orchestrator override): `XdgToplevel.sent_payloads` (ConfigurePayload list) records each configure; `applyAckedConfigure(serial)` copies the acked width/height/states into `current` and prunes superseded payloads (wlroots handle_xdg_toplevel_ack_configure). Popups likewise: `PopupConfigurePayload` + `acked_geometry` (wlroots handle_xdg_popup_ack_configure). Policy now writes `scheduled`; `current` is read-only committed-against state. Tests: "xdg toplevel configure/ack roundtrip" (current == acked payload), "popup configure applies the constraint box (F1)" (acked_geometry), "popup reposition re-places and acknowledges the token (F1/F7)".

### F8. Role-object destroy before map does not reset the configure state machine
- Severity: MED.
- Ours: `toplevelDestroy` (xdg.zig:826-844) and `popupDestroy` (xdg.zig:900-916) call `unmapSurface` (xdg.zig:365), which early-returns when `!surface.mapped` — so `configured`/`configure_sent`/`acked_serial` survive role destruction. A new role object + immediate buffer commit then maps with no fresh configure.
- Ref: wlroots role-resource destroy listener (`xdg_surface_handle_role_resource_destroy`, wlr_xdg_surface.c:512) → `destroy_xdg_surface_role_object` + `reset_xdg_surface` (26-45) → `configured = false` always. smithay role destroyed handler resets role attributes + cached state (toplevel.rs:198-238).
- Expected: any role-object destruction resets the xdg_surface to the initial state: next map requires buffer-less commit → configure → ack.
- Why it matters: XML "Unmapping" + role-destroy semantics; a client that destroys its toplevel and re-creates it could map without ever acking, breaking the configure handshake.
- Fixability: FIXABLE-in-module. Call `resetConfigureState` unconditionally in `toplevelDestroy`/`popupDestroy`.
- FIXED 2026-08-10: `toplevelDestroy` and `popupDestroy` call `xdg.resetConfigureState()` before `unmapSurface` (which early-returns when unmapped); test: "role-object destroy before map resets the configure machine (F8)" (re-create + buffer commit before the fresh handshake -> unconfigured_buffer).

### F9. Client min/max size validated then discarded; compositor never reads it
- Severity: MED.
- Ours: `set_max/min_size` store into `t.pending` (xdg.zig:795-803); `xdgSurfaceClientCommit` validates them (xdg.zig:1094-1104) but nothing copies `pending` → `current` anywhere (checked: no other writer of `t.current`), and there is no signal. The values are unreadable.
- Ref: wlroots synced state makes `toplevel->current.min_width` available after commit (wlr_xdg_toplevel.c:345-359 + `wlr_surface_synced_impl`); smithay `SurfaceCachedState.min_size/max_size` committed per cache (mod.rs:1044-1072, exposed via `with_cached_state`).
- Expected: after commit, the compositor can read the client's constraints to size/limit the window.
- Why it matters: without constraints, resizing policy (F6) cannot clamp; a future maximize path cannot honor the client's limits.
- Fixability: FIXABLE-in-module. Apply `pending.min/max_size` into `current` at commit (in `xdgSurfaceClientCommit`), mirroring the wlroots synced move; expose via `current`.
- FIXED 2026-08-10: after the existing commit-time validation, `t.current.min_size/max_size = t.pending.*` in `xdgSurfaceClientCommit`; the compositor reads the constraints from `t.current`; test: "client min/max size is applied to current at commit (F9)".

### F10. set_fullscreen drops the output; set_minimized has no signal
- Severity: MED.
- Ours: `set_fullscreen`/`unset_fullscreen` write `t.pending.fullscreen` and emit `request_fullscreen` carrying only the toplevel (xdg.zig:814-821) — the `output` request argument is discarded at the wire layer. `set_minimized` logs only (xdg.zig:822-823); there is no `request_minimize` event on `XdgToplevel.events` (xdg.zig:593-627).
- Ref: wlroots `store_fullscreen_requested` keeps `requested.fullscreen_output` with a destroy listener (wlr_xdg_toplevel.c:392-424) and emits `request_fullscreen`; `set_minimized` emits `request_minimize` (wlr_xdg_toplevel.c:426-432). smithay `fullscreen_request(state, handle, output)` (mod.rs:1136), `minimize_request` (mod.rs:1144). KWin emits `fullscreenRequested(output)` / `minimizeRequested` (xdgshell.cpp:564-583).
- Expected: the compositor learns which output was requested for fullscreen; it receives a minimize request event.
- Why it matters: fullscreen-on-a-specific-output cannot be honored; minimize requests are silently dropped.
- Fixability: FIXABLE-in-module. Add `output: ?*wire.Resource` to a request payload (and a `request_minimize` signal + `minimized` field).
- FIXED 2026-08-10: `request_fullscreen` widened to `FullscreenRequest {toplevel, fullscreen, output}` carrying the client-named wl_output; `set_minimized` records `pending.minimized` and emits `request_minimize`; `ToplevelState.minimized` field added; main.zig logs both via per-toplevel listeners; test: "set_fullscreen carries the output; set_minimized emits a signal (F10)".

### F11. move/resize/show_window_menu lose seat + serial; window menu has no event at all
- Severity: MED.
- Ours: `request_move` carries only the toplevel (xdg.zig:763-772); `ResizeRequest` carries only the edge (xdg.zig:577-583); `show_window_menu` checks `not_constructed` then logs (xdg.zig:746-758) — no event exists on `XdgToplevel.events`.
- Ref: wlroots emits `request_move`/`request_resize`/`request_show_window_menu` with seat, serial, and (menu) x/y (wlr_xdg_toplevel.c:262-343). smithay `move_request`/`resize_request`/`show_window_menu` all pass seat + serial (mod.rs:1109-1158). KWin passes seat+serial (xdgshell.cpp:448-522).
- Expected: the compositor receives seat+serial so it can verify the client held the button (serial check) before starting interactive move/resize, and it can raise the window menu at (x,y).
- Why it matters: interactive move/resize cannot validate serials; window menus are unimplementable today. wm_capabilities advertises WINDOW_MENU (once F4 lands) but no event exists.
- Fixability: NEEDS-wiring. Payload widening (seat ref + serial + coords) is FIXABLE-in-module; serial-vs-seat validation and the menu UI are compositor work.
- FIXED 2026-08-10: `request_move` now emits `MoveRequest {toplevel, seat, serial}`, `request_resize` carries seat+serial, and `request_show_window_menu` (new event) carries `ShowWindowMenuRequest {toplevel, seat, serial, x, y}`; main.zig has no interactive-move consumers yet (logs fullscreen/minimize only). Serial-vs-seat validation and the menu UI remain compositor work; tests: "move and show_window_menu carry seat + serial (F11)" + updated resize payload test.

### F12. No popup stacking / child lists / parent-unmap teardown / popup hit-testing
- Severity: MED.
- Ours: `XdgPopup` stores `parent: ?*XdgSurface` (xdg.zig:855) but nothing else — no parent→children list, no grab chain, no popup-aware `surface_at`, no coordinate walk. Popups are rendered by the generic surface path at scene origin (main.zig:1618-1685 applies no popup offset; onNewPopup only logs, main.zig:859-867) — a mapped popup renders at (0,0) and hit-tests there. `popupDestroy` (xdg.zig:900) has no topmost-popup check.
- Ref: wlroots keeps `parent->popups` child list, `wlr_xdg_popup_get_toplevel_coords` (wlr_xdg_popup.c:500), popup-aware `wlr_xdg_surface_surface_at`/`for_each_surface` (wlr_xdg_surface.c:580-656), `not_the_topmost_popup` on grab and `an_existing_popup_was_destroyed` on non-topmost destroy (wlr_xdg_popup.c:272-368); parent reset destroys child popups with popup_done (wlr_xdg_surface.c:26-45). smithay/KWin track children through their window layers.
- Expected: popups stack above their parent and siblings; destroying a popup that is not the topmost (under an active grab) is a protocol error; parent unmap dismisses children; hit-testing descends into popups at their offset.
- Why it matters: menus render at wrong positions, intercept clicks at the wrong location, and cannot be ordered. This is the largest STRUCTURAL gap in the popup story.
- Fixability: STRUCTURAL. Needs scene ordering/offset application (main.zig), seat focus rules, and popup parent/child data structures in the module. F2 (grab) and F1 (reposition) both depend on it.
- DEFERRED 2026-08-10 fixing round: STRUCTURAL (scene ordering/offset + seat focus + popup parent/child lists); F1's constraint math and reposition were landed independently; popups still composite at scene origin (main.zig onNewPopup only logs).

### F13. Positioner completeness check differs; zero-size anchor rect accepted
- Severity: LOW.
- Ours: completeness = `size_set && anchor_rect_set` (xdg.zig:484-490). `set_anchor_rect` allows width/height 0 (xdg.zig:1011-1021, matching wlroots' `< 0` check), so `set_size(100,50)` + `set_anchor_rect(0,0,0,0)` passes ours.
- Ref: wlroots `wlr_xdg_positioner_is_complete` requires `size.width > 0 && anchor_rect.width > 0` (wlr_xdg_positioner.c:216); a 0-width anchor rect → `invalid_positioner` at get_popup/reposition (wlr_xdg_popup.c:370-378, 317-343).
- Expected: per XML only "set_size and set_anchor_rect must be called"; zero-size anchor rect is undefined territory. wlroots is stricter.
- Why it matters: edge-case clients get through with a degenerate popup; behavior difference vs wlroots in a conformance test.
- Fixability: FIXABLE-in-module. Require `anchor_rect.width > 0 && anchor_rect.height > 0` (or track set-with-nonzero) in the completeness check.
- FIXED 2026-08-10: `PositionerState.isComplete` requires positive size AND positive anchor-rect width+height (wlroots checks only width; the height requirement is the note's prescription, deliberately stricter); used at get_popup and reposition; test: "zero-size anchor rect positioner is incomplete (F13)".

### F14. Title/app_id: no change events; invalid UTF-8 handled differently from wlroots; state not cleared on unmap
- Severity: LOW.
- Ours: `setTitle` rejects invalid UTF-8 with a log and stores nothing (xdg.zig:652-668); no `set_title`/`set_app_id` events (events struct xdg.zig:593-627); title/app_id persist across unmap (toplevelDestroy frees them only at role destroy, xdg.zig:836-840).
- Ref: wlroots posts error `-1` (non-XML) on invalid UTF-8 (wlr_xdg_toplevel.c:222-243); emits `set_title`/`set_app_id` signals; `reset_xdg_toplevel` clears title/app_id on unmap (wlr_xdg_toplevel.c:523-541). smithay `title_changed`/`app_id_changed` (mod.rs:1202-1206). KWin `titleChanged`/`appIdChanged` (xdgshell.cpp:430-446).
- Expected: compositor notified on title/app_id change; title cleared on unmap (window metadata is per-map).
- Why it matters: taskbar/CSD title updates never arrive; metadata leaks across unmap; invalid-UTF-8 handling differs from wlroots (ours keeps the connection, which is arguably safer — no XML error exists).
- Fixability: FIXABLE-in-module (add events; clear on unmap). The UTF-8 policy (log+reject vs error) is a deliberate divergence — keep, but document.
- FIXED 2026-08-10: `set_title`/`set_app_id` events on XdgToplevel, emitted after storing; `resetOnUnmap` frees title/app_id on NULL-buffer unmap (per-map metadata); UTF-8 policy kept (log+reject, no wire error) and documented in setTitle; main.zig attaches per-toplevel title/app_id listeners; test: "title/app_id change events; unmap clears metadata (F14)".

### F15. Window geometry: applied at ack, not commit; no extents intersection
- Severity: LOW.
- Ours: `ackConfigure` applies `pending_geometry` → `current_geometry` at ack time (xdg.zig:354-356); `xdgSurfaceMap` is a no-op (xdg.zig:1132-1140).
- Ref: wlroots applies window geometry on commit via synced state and computes effective geometry = `wlr_surface_get_extents` ∩ window_geometry on commit/map, with a fallback and a warning (update_geometry, wlr_xdg_surface.c:259-280). smithay `SurfaceCachedState.geometry` committed per commit (mod.rs:1044-1072).
- Expected: geometry clamped to the committed buffer extents; geometry refreshed at map (so subsurfaces are included).
- Why it matters: a client can set a window geometry larger than its buffer; ours reports it as-is to the compositor. Timing (ack vs commit) is usually identical in practice since the ack precedes the buffer commit.
- Fixability: FIXABLE-in-module (commit-time apply); the extents clamp needs the compositor surface extent API — [INFERENCE] `surfaceSize` exists in main.zig:1685 but extents are not exposed to the shell module.
- FIXED 2026-08-10: window geometry applies at COMMIT (`xdgSurfaceClientCommit`, wlroots synced-state move), not at ack; the extents intersection (effective geometry = extents ∩ window_geometry, wlr_xdg_surface.c:259-280) still needs the surface-extents API which is not exposed to the shell module — applied as-is until that lands; test: "window geometry applies at commit, not ack (F15)".

### F16. set_parent: self-check only; no storage, no loop detection, no parent-unmap handling
- Severity: MED.
- Ours: `set_parent` rejects `parent == self` (invalid_parent, xdg.zig:741-756) and logs "parenting deferred". `XdgToplevel` has no parent field.
- Ref: wlroots `wlr_xdg_toplevel_set_parent` walks the parent chain for cycles, stores parent, subscribes to the parent's unmap to re-parent (wlr_xdg_toplevel.c:178-204). smithay `is_valid_parent` cycle-walk (mod.rs:55-80) + `parent_changed` handler (mod.rs:1208). KWin stores `parentXdgToplevel` and emits change (xdgshell.cpp:420-429).
- Expected: descendant-cycle → invalid_parent; parent stored and exposed; parent unmap clears the child's parent.
- Why it matters: dialog/transient semantics, taskbar grouping, and popup-parent chains need real parenting.
- Fixability: STRUCTURAL (the task brief classifies parenting as such). A parent field + cycle walk is FIXABLE-in-module; consuming it (stacking, transient windows) is compositor work.
- FIXED 2026-08-10 (orchestrator override: implement the module-local parts): `XdgToplevel.parent` stored and exposed; `set_parent` walks the ancestor chain and posts invalid_parent on descendant cycles (wlroots wlr_xdg_toplevel.c:178-204); `children` list keeps no stale pointers — parent destroy/unmap reparents children to the grandparent (resetOnUnmap) or clears them; consuming parenting (stacking, transient windows) remains compositor work; test: "set_parent stores the parent and rejects descendant cycles (F16)".

### L1. get_popup on a layer surface is a stub (posts raw -1)
- Severity: HIGH.
- Ours: `getPopup` posts implementation error -1 and creates nothing (layer_shell.zig:362-368); module header documents "parenting is M4".
- Ref: wlroots `layer_surface_handle_get_popup` attaches the popup to the layer surface, errors -1 only if the popup already has a parent (wlr_layer_shell_v1.c:240-257). smithay sets the popup's parent and calls `new_popup` (handlers.rs:272-295). KWin attaches via `popupPrivate->attachTo(surface)`, errors if the popup is already configured (layershell_v1.cpp:262-274).
- Expected: `zwlr_layer_surface_v1.get_popup` makes the xdg_popup's parent the layer surface; the popup must then be positioned relative to the layer surface and dismissed with it.
- Why it matters: layer-shell panels with popups (notification popups, panel menus) are a standard use case; every reference implements it. Also drags `invalid_surface_state`-style behavior with it.
- Fixability: FIXABLE-in-module for the wire path (set `XdgPopup.parent`-equivalent to the layer surface, hook popup configure), but the popup offset/stacking consumption is NEEDS-wiring (F12). Requires relaxing the xdg.zig commit-time null-parent error (xdg.zig:1076-1092) to accept the layer-surface parent.
- FIXED 2026-08-10: `getPopup` parents the xdg_popup to the layer surface — `XdgPopup.layer_parent = the layer wl_surface` (wlroots `popup->parent = parent->surface` parity; the popup keeps its NULL xdg `parent`), the popup is tracked in `LayerSurface.popups` (pruned via a per-popup resource destroy listener) and dismissed with the layer surface on unmap-reset and destroy (popup_done + role destroy, mirroring `layer_surface_reset`). The xdg.zig commit-time null-parent check is relaxed to accept a layer parent (xdg.zig:1795, added by W4 per this finding). Already-parented popup → raw -1 on the layer-surface resource (wlroots). Popup offset/stacking consumption remains F12 (deferred). Wire-level `new_popup` on the layer surface was not added: main.zig already sees xdg popups via the xdg `new_popup` signal.

### L2. Initial layer configure is module-auto; compositor never assigns real sizes
- Severity: MED.
- Ours: `layerSurfaceCommit` sends the initial configure automatically on the first buffer-less commit (layer_shell.zig:513-525) with `ls.current.desired_width/height` (0,0 default). main.zig never calls a size-assigning configure (main.zig:836-858 tracks only).
- Ref: wlroots `wlr_layer_surface_v1_configure` is compositor-called (asserts `initialized`, wlr_layer_shell_v1.c:316-335); smithay `LayerSurface::send_configure`/`send_pending_configure` (mod.rs:363-394); KWin `sendConfigure` called from the window's configure path (layershell_v1.cpp:452-475).
- Expected: the compositor assigns sizes for zero-dimension axes (panel height, dock width) and informs the client.
- Why it matters: clients asking for auto-assigned sizes (the common case: a top bar with width 0) never learn their actual size; layer layout policy is entirely absent (acknowledged in notes/129-layer-shell-impl.md).
- Fixability: STRUCTURAL. The module flow is protocol-correct; assigning sizes requires a layout pass over outputs in main.zig plus a public configure entry (FIXABLE-in-module to expose; compositor work to drive).
- FIXED 2026-08-10 (minimal wiring per the task brief): `LayerSurface.setFallbackSize(w, h)` exposes the compositor-assigned size; main.zig `onNewLayerSurface` supplies the (single) output's mode size; the module's initial configure carries the fallback for each zero desired dimension (the client's nonzero desired size wins per axis). The full layout policy (z-ordering, exclusive-zone arrangement, compositor-driven configures after the initial one) remains deferred.

### L3. set_size: no INT32_MAX guard, no change short-circuit
- Severity: LOW.
- Ours: `set_size` stores u32 directly (layer_shell.zig:390-394).
- Ref: wlroots rejects > INT32_MAX with an implementation error and skips re-marking when unchanged (wlr_layer_shell_v1.c:128-151); smithay/KWin keep the values.
- Expected: implementation-error guard per wlroots (the XML has no error code).
- Why it matters: overflow beyond INT32_MAX only matters to hostile clients; ours stores u32 losslessly, so no corruption. Parity nicety.
- Fixability: FIXABLE-in-module.
- FIXED 2026-08-10: `set_size` rejects width/height > INT32_MAX with raw -1 on the surface resource (wlroots posts client-level via `wl_client_post_implementation_error`; ours uses the codebase's resource-level implementation-error pattern — documented) and short-circuits when the pending size is unchanged (wlroots wlr_layer_shell_v1.c:128-151).

### L4. set_layer invalid_layer posted on the shell resource; refs post on the layer surface
- Severity: LOW.
- Ours: posts `invalid_layer` on `shell_resource` with a comment documenting the divergence (layer_shell.zig:416-425).
- Ref: wlroots posts on the layer-surface resource with an "XXX: this sends a zwlr_layer_shell_v1 error to a zwlr_layer_surface_v1 object" comment (wlr_layer_shell_v1.c:260-283); smithay posts on the layer surface (handlers.rs:239-250); KWin on the surface resource (layershell_v1.cpp:303-309).
- Expected: the error enum lives on `zwlr_layer_shell_v1`; clients match the error to the resource's interface. Posting on the shell resource is XML-defensible but all three references post on the surface.
- Why it matters: a client that only binds the surface object reads the error as unknown-interface; GTK-style clients expect the error on the surface object. Divergence is deliberate; revisit if a client complains.
- Fixability: FIXABLE-in-module (one-line move; note the existing comment).
- FIXED 2026-08-10: `invalid_layer` (code 1, shell error enum) is now posted on the layer-surface resource (wlroots/smithay/KWin parity); the shell-resource divergence comment is updated.

### L5. Layer state not reset on unmap (matches wlroots; both diverge from XML text)
- Severity: LOW.
- Ours: `reset` (layer_shell.zig:306-313) clears configure flags only; `pending`/`current` keep size/anchor/margins/zone across unmap.
- Ref: XML: "The layer_surface returns to the state it had right after layer_shell.get_layer_surface" (wlr-layer-shell-unstable-v1.xml:113-118). wlroots `layer_surface_reset` also keeps the state (wlr_layer_shell_v1.c:33-46). smithay resets cached state + attributes on unmap (mod.rs:465-479); KWin `state = LayerSurfaceV1State()` (layershell_v1.cpp:333-336) — but KWin also loses the initial `layer`, which is arguably wrong.
- Expected per XML: full state reset. wlroots and ours keep state; smithay/KWin reset.
- Why it matters: after unmap/remap, a client that set margins once sees them persist in ours/wlroots but not in smithay/KWin. Low real-world impact; conformance test difference.
- Fixability: FIXABLE-in-module (clear `pending`/`current` in `reset`, keep only the initial `layer`).
- FIXED 2026-08-10 (verified, no state-behavior change): re-read wlroots `layer_surface_reset` (wlr_layer_shell_v1.c:33-46) — it keeps `pending`/`current` (size/anchor/margins/zone/layer) across unmap, matching ours; both diverge from the XML text (smithay/KWin reset the state). Documented in `reset()`. Note: `reset()` now also dismisses the parented popups (L1), which wlroots also does here.

### L6. ack_configure stores no actual configure size
- Severity: LOW.
- Ours: `ackConfigure` records only the serial (layer_shell.zig:292-304).
- Ref: wlroots stores `pending.actual_width/actual_height` from the acked configure (wlr_layer_shell_v1.c:105-125) so the compositor knows the size the client committed against.
- Why it matters: layout policy cannot compare desired vs assigned size per ack. Minor.
- Fixability: FIXABLE-in-module (store last configure size alongside the serial list).
- FIXED 2026-08-10: the sent-configures list now stores `{serial, width, height}`; `ack_configure` writes the acked size into `pending.actual_width/actual_height` (wlroots `layer_surface_handle_ack_configure` parity), readable as `current.actual_width/height` after the next commit.

### L7. set_exclusive_edge stricter than wlroots (single-bit only)
- Severity: LOW.
- Ours: rejects any non-single-bit edge with `invalid_exclusive_edge` at the request (layer_shell.zig:426-437).
- Ref: wlroots accepts any valid anchor bitset via `zwlr_layer_surface_v1_anchor_is_valid` and defers the subset check to commit (wlr_layer_shell_v1.c:284-313, 378-385). smithay (handlers.rs:251-270) and KWin (layershell_v1.cpp:193-213) also require a single bit.
- Expected: per XML the edge "must be one the surface is anchored to"; a corner value is not a single edge. Ours + smithay + KWin agree on strictness.
- Why it matters: lenient clients (none in practice) only; wlroots diverges from the other three. Keep.
- Fixability: none required.
- FIXED 2026-08-10 (decision: wlroots parity per the task brief, over the note's "keep" recommendation): `set_exclusive_edge` now accepts any valid anchor bitset (incl. 0 and corner/multi-bit values) at request time via the mask check (wlroots `zwlr_layer_surface_v1_anchor_is_valid`); the subset-of-anchor check stays at commit (wlroots order). smithay/KWin remain stricter; a corner edge with matching anchors is accepted and simply occupies no exclusive edge (`exclusiveEdge` returns null).

---

## 3. Fixability summary

| Finding | Class | Depends on | 2026-08-10 round |
|---|---|---|---|
| F1 popup constraint math | FIXABLE-in-module | — | FIXED |
| F2 popup grab | NEEDS-wiring | F12 stacking, seat grab API | DEFERRED |
| F3 ping/pong | NEEDS-wiring | main.zig timer | FIXED |
| F4 bounds/wm_capabilities | FIXABLE-in-module | — | FIXED |
| F5 state version filter | FIXABLE-in-module | — | FIXED |
| F6 configure payload model | STRUCTURAL | main.zig policy | FIXED (orchestrator override, module-local) |
| F7 ack payload application | STRUCTURAL | F6 | FIXED (orchestrator override) |
| F8 role-destroy pre-map reset | FIXABLE-in-module | — | FIXED |
| F9 min/max exposure | FIXABLE-in-module | — | FIXED |
| F10 fullscreen output / minimize signal | FIXABLE-in-module | — | FIXED |
| F11 move/resize/menu seat+serial | NEEDS-wiring | seat serial validation | FIXED (payloads; validation is compositor work) |
| F12 popup stacking/hit-test | STRUCTURAL | main.zig scene, seat | DEFERRED |
| F13 positioner completeness | FIXABLE-in-module | — | FIXED |
| F14 title/app_id events + unmap clear | FIXABLE-in-module | — | FIXED |
| F15 window geometry extents | FIXABLE-in-module (extents API needed) | surface extents [INFERENCE] | FIXED (commit-time; extents clamp pending API) |
| F16 parenting | STRUCTURAL | main.zig stacking | FIXED (storage + cycle check; stacking is compositor work) |
| L1 layer get_popup | FIXABLE-in-module (wire) / NEEDS-wiring (stacking) | F12 |
| L2 layer configure policy | STRUCTURAL | main.zig layout |
| L3 set_size INT32_MAX | FIXABLE-in-module | — |
| L4 set_layer error resource | FIXABLE-in-module | — |
| L5 layer state reset on unmap | FIXABLE-in-module | — |
| L6 ack size storage | FIXABLE-in-module | — |
| L7 exclusive edge strictness | none (keep) | — |

Suggested backlog order: F8, F13, F5, F9 (cheap correctness) → F4, F10, F14, F15 (wire surface) → F1 (constraint math) → L1/L6/L3/L4/L5 → F3, F11 (seat wiring) → F2, F12, F16, F6/F7, L2 (structural).

---

## 4. OK areas (parity confirmed)

- wm_base bind/destroy/defunct_surfaces handshake: ours xdg.zig:150-240 ↔ wlr_xdg_shell.c:16-64,93-120. Includes the W4 fix (wm_base destroyed before its surfaces: binding state survives until the last surface detaches, xdg.zig:194-205, 530-563).
- get_xdg_surface role/unconfigured_buffer errors on the correct resources (xdg.zig:207-263 ↔ wlr_xdg_surface.c:397-412); second get_xdg_surface posts `role` on wm_base per XML, not wl_surface role error.
- ack_configure serial semantics: ours posts `invalid_serial` (4) on xdg_surface for never-sent, duplicate, and stale serials (xdg.zig:330-363) — this is XML-conformant (xdg-shell.xml:573-593) where wlroots/smithay post `invalid_surface_state` (4) on xdg_wm_base (wlr_xdg_surface.c:86-93; smithay surface.rs:300-309). Ours is the reference-correct placement; keep and do not "fix" toward wlroots.
- Positioner request validation + geometry math: all nine requests (xdg.zig:996-1055 ↔ wlr_xdg_positioner.c:15-150); anchor/gravity/offset placement identical to `wlr_xdg_positioner_rules_get_geometry` (wlr_xdg_positioner.c:221-267) and smithay `get_geometry` (mod.rs:640). (F13, 2026-08-10: the completeness check now rejects zero-size anchor rects — wlroots also rejects 0-width; see F13.)
- Popup initial configure event order (popup.configure then surface.configure, xdg.zig:864-882 ↔ wlr_xdg_popup.c:13-51, smithay popup.rs:236-260) and positioner-copied-at-get_popup semantics.
- Toplevel state array order matches wlroots exactly (maximized, fullscreen, resizing, activated, tiled L/R/T/B, suspended, constrained L/R/T/B — xdg.zig:682-737 ↔ wlr_xdg_toplevel.c:76-124) apart from the version gating (F5).
- resize-edge validation list (xdg.zig:775-793 ↔ wlr_xdg_toplevel.c:312-343); not_constructed checks on move/resize/menu/set_window_geometry/ack (xdg.zig:386-402, 746-772 ↔ wlr_xdg_toplevel.c:262-343).
- Popup-without-parent commit error (`not_constructed` on xdg_surface, xdg.zig:1076-1092 ↔ wlr_xdg_popup.c:247-252); invalid_popup_parent placement on wm_base (xdg.zig:458-530 ↔ wlr_xdg_popup.c:370-383).
- Layer-shell: role error on shell resource (layer_shell.zig:144-210 ↔ wlr_layer_shell_v1.c:436-485); already_constructed=2 posted on the surface resource (layer_shell.zig:483-493 ↔ wlr_layer_shell_v1.c:345-358); zero-size-anchor and exclusive-edge-subset commit checks in the same order (layer_shell.zig:494-511 ↔ wlr_layer_shell_v1.c:358-385); keyboard interactivity v<4 coercion (layer_shell.zig:345-360 ↔ wlr_layer_shell_v1.c:216-239); anchor bitmask validation; exclusive-edge deduction identical (layer_shell.zig:373-384 ↔ wlr_layer_shell_v1.c:656-685, tests layer_shell.zig:541-553); double-buffered pending/current apply at commit (layer_shell.zig:473-481 ↔ wlr_layer_shell_v1.c:345 + synced impl); closed-then-destroy close path (layer_shell.zig:326-336 ↔ wlr_layer_shell_v1.c:337-343); ack-of-unknown-serial `invalid_surface_state` on the surface (layer_shell.zig:292-304 ↔ wlr_layer_shell_v1.c:87-125).
- Unmap/re-map configure-state reset for both modules (NULL-buffer commit: xdg.zig:1142-1149, layer_shell.zig:513-525; tests xdg.zig:1684, layer_shell.zig:889) matching the XML unmap rule.

Cross-references: prior rounds — notes/129-xdg-shell-conformance.md (error-code parity, defers grab/ping/parenting), notes/129-layer-shell-impl.md (layout policy deferred), notes/129-shell-protocols-impl.md. This note supersedes the "Deferred" items there with concrete backlog entries F1-F16, L1-L7.
