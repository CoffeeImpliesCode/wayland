# cmp-xdg-shell — Adversarial xdg-shell comparison (ours vs wlroots 0.20.2 / smithay v0.7.0 / KWin master)

## 1. Implemented surface
`src/shell/xdg.zig` (3698 ln incl. tests). Whole stable/xdg-shell module:
- **xdg_wm_base** (`XdgShell`/`WmBaseState`): global, per-binding surface list, `defunct_surfaces`, one pending ping serial per binding + `unresponsive` error post, pong handling.
- **xdg_surface** (`XdgSurface`): role dispatch (toplevel/popup), configure serial-list + ack→payload apply (F6/F7), double-buffered window geometry (F15), map/unmap configure-state reset.
- **xdg_toplevel** (`XdgToplevel`): all 14 requests; configure + close + configure_bounds(v4) + wm_capabilities(v5) events; scheduled/current/pending state model; parent/children with cycle rejection (F16); ping.
- **xdg_popup** (`XdgPopup`): configure + popup_done + repositioned(v3); constraint-box (F1) flip/slide/resize; `grab` is a stub (F2).
- **xdg_positioner** (`PositionerState`): full rules capture + raw geometry + flip/slide/resize unconstrain (F1) + completeness.

## 2. API breadth table
Versions: ours **7** (xdg.zig:74, `generated_version`); wlroots **7** (wlr_xdg_shell.c:5); smithay **7** (mod.rs:1248); KWin **6** (xdgshell.cpp:21).

| Interface | Requests | Events | Ours | wlroots | smithay | KWin |
|---|---|---|---|---|---|---|
| xdg_wm_base | destroy, create_positioner, get_xdg_surface, pong | ping | all 4 + ping ✓ | all | all | all |
| xdg_surface | destroy, get_toplevel, get_popup, set_window_geometry, ack_configure | configure | all 5 | all | all | all |
| xdg_toplevel | 14 | configure, close, configure_bounds(≥4), wm_capabilities(≥5) | all 14; all 4 events | all | all | all |
| xdg_popup | destroy, grab, reposition | configure, popup_done, repositioned(≥3) | destroy ✓, **grab STUB**, reposition ✓; all 3 events | all | all | all |
| xdg_positioner | destroy, set_size, set_anchor_rect, set_anchor, set_gravity, set_constraint_adjustment, set_offset, set_reactive, set_parent_size, set_parent_configure | — | all 10 | all | all | all |

Breadth gaps: `xdg_popup.grab` no-op (no seat grab, no `invalid_grab`, no `not_the_topmost_popup`); no reactive-popup reconfigure; compositor cannot drive toplevel size/states (auto-configure only). All three refs implement grab and compositor-driven configure fully.

## 3. Adversarial correctness findings (NEW, beyond 133/129)
1. **ack_configure error interface differs from BOTH references.** Ours posts `xdg_surface.invalid_serial` (code 4) on the xdg_surface for unknown/already-acked/older serials (xdg.zig:381-396). wlroots posts `XDG_WM_BASE_ERROR_INVALID_SURFACE_STATE` (code 4) on the wm_base (wlr_xdg_surface.c:74-80, `surface->client->resource`); smithay posts `wm_base::Error::InvalidSurfaceState` (surface.rs:318-322). The XML (xdg-shell.xml:573-593) says acking a never-sent serial "raises an invalid_serial error", so OURS is the spec-literal one and both refs post the same code on the wrong interface. Severity: **minor** — code identical (4); only the interface string differs, so a client keying on the wm_base interface (as wlroots/smithay generate it) breaks against ours and vice-versa; a conformance suite asserting the wlroots interface fails ours.

2. **Resize-edge validation precedence vs `configured`.** Ours checks `!xdg.configured` → `not_constructed` BEFORE edge validity (xdg.zig:1097-1102, then edge check ~1115-1122). wlroots validates the edge FIRST (`invalid_resize_edge`), then `configured` (wlr_xdg_toplevel.c:320-333). For an unconfigured surface carrying a bogus edge, wlroots posts invalid_resize_edge, ours posts not_constructed. Severity: **minor** (different protocol error on an already-doomed connection). Edge-value SET matches wlroots (none/top/bottom/left/top_left/bottom_left/right/top_right/bottom_right).

3. **`set_parent` to an unmapped toplevel: wlroots clears the parent, ours stores it.** Ours stores `t.parent = new_parent` unconditionally after self/cycle checks (xdg.zig:1180-1219). wlroots only installs the parent when `parent->base->surface->mapped`, else `toplevel->parent = NULL` (wlr_xdg_toplevel.c:183-199). A client parenting a dialog to a not-yet-mapped toplevel gets a parent from ours but none from wlroots; transient/grouping behavior diverges. Severity: **minor** [INFERENCE on real-client impact].

4. **`xdg_popup.grab` raises no error at all; destroy-side topmost check absent.** Ours logs only (xdg.zig:1356-1360). wlroots raises `invalid_grab` when already mapped and `not_the_topmost_popup` on grab/destroy of a non-topmost popup (wlr_xdg_popup.c:272-280, 320-326); smithay (mod.rs:1991) and KWin (xdgshell.cpp:856-858) raise invalid_grab. A client that grabs a mapped popup gets a silent no-op from ours instead of a protocol error. Severity: **major** (missing error surface + no grab; structural, tracked F2/F12).

5. **Reactive popups never re-configure; `set_reactive` is dead state.** Ours stores `reactive` (xdg.zig:1762) but no reconfigure path exists; popups composite at scene origin (F12 structural). smithay actively re-sends for reactive popups and refuses re-configure for v<3 / non-reactive (mod.rs:1904-1920); wlroots re-schedules on parent motion. A reactive tooltip never follows its parent. Severity: **major** (structural; F1/F12).

6. **`sent_payloads` not cleared on unmap/reset.** Ours clears `sent_serials` on reset (xdg.zig:381) but not `XdgToplevel.sent_payloads`/`XdgPopup.sent_payloads`; wlroots destroys the whole `configure_list` on reset (wlr_xdg_surface.c:26-45). Stale payloads linger until the next ack prunes them. Severity: **info/minor** (memory only; serials cleared prevent wrong acks).

7. **configure_bounds/wm_capabilities triggers are value-driven, not flag-driven.** Ours sends bounds only when `(bounds != 0,0) AND changed` (xdg.zig:~853-860) and caps only when `!isEmpty() AND changed` (~862-880); wlroots sends whenever the compositor sets the `fields` bit (wlr_xdg_toplevel.c:33-75), so an empty caps array or explicit 0,0 bounds is a legal sendable payload. A compositor cannot advertise "no capabilities" via ours. Severity: **minor** (default non-empty caps mask it).

8. **Compositor cannot drive toplevel size/states — auto-configure architecture.** Ours auto-sends the initial configure on the first commit (xdg.zig:1881-1899) from `scheduled` (0×0, no states by default); main.zig never calls `t.configure`. All three refs are compositor-driven (`wlr_xdg_surface_schedule_configure`; smithay `send_pending_configure`; KWin `sendConfigure`). Every real toplevel maps at its client-chosen size with no maximized/fullscreen/activated states. Severity: **major** (structural; F6/L2, reaffirmed adversarially).

9. **`repositioned` event not version-gated.** Ours calls `sendRepositioned(token)` unconditionally in the reposition handler (xdg.zig:1372); wlroots gates it on `version >= XDG_POPUP_REPOSITIONED_SINCE_VERSION` (v3). Benign — only v3+ clients can send `reposition` — but ours sends the event without a version guard. Severity: **info**.

## 4. Verdict
- **Breadth**: nearly complete wire surface; the only true missing request semantics is `xdg_popup.grab` (no-op). Every request/event the three refs implement is otherwise present, at version 7 (fullest; wlroots/smithay 7, KWin 6).
- **Correctness**: the constraint math (F1), state-version filtering (F5), ack payload model (F7) and parenting cycle checks (F16) are faithful ports. The adversarial divergences cluster in (a) error-interface/precedence choices where ours is arguably MORE spec-correct than wlroots/smithay (X01 — ack invalid serial; both refs post on the wrong interface) and (b) structural gaps the refs close but ours cannot yet: popup grabs (X04), reactive reconfigure + popup compositing (X05/X08), and compositor-driven configure (X08). No critical severity findings; the major ones are all the known structural F2/F6/F12 backlog.

Finding count: 9. Top 3: X04 (grab no-op, major), X01 (ack error interface, minor, ours spec-correct), X03 (set_parent to unmapped parent, minor).
