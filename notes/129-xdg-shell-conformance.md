# 129: xdg-shell conformance fixes

Area: shell-protocol parity round (worker W2XdgShellFixes).
Files: edits to src/shell/xdg.zig; notes only for src/compositor/role.zig (no code change needed, see Finding 4).
Ground truth: protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml; generated bindings under .zig-cache/o/*/wayland.zig (server.xdg namespace); wlroots types/xdg_shell/*.c; smithay src/wayland/shell/xdg/; KWin src/wayland/xdgshell.cpp.

All error codes cited match the XML enums (verified): xdg_wm_base.error role=0 defunct_surfaces=1 not_the_topmost_popup=2 invalid_popup_parent=3 invalid_surface_state=4 invalid_positioner=5 unresponsive=6; xdg_surface.error not_constructed=1 already_constructed=2 unconfigured_buffer=3 invalid_serial=4 invalid_size=5 defunct_role_object=6; xdg_toplevel.error invalid_resize_edge=0 invalid_parent=1 invalid_size=2; xdg_positioner.error invalid_input=0.

## Fixed findings

1. NULL-buffer unmap resets the configure state machine.
   - Added `xdgSurfaceUnmap` (xdg.zig:1122) wired as the role's `unmap` hook (xdg.zig:1138-1140); it calls the new `resetConfigureState` (xdg.zig:305) which clears configure_sent, configured, acked_serial and sent_serials. `unmapSurface` (xdg.zig:352) now calls the same reset (the destroy paths detach the role first, so the hook alone is not enough there).
   - Behavior: map -> attach(NULL)+commit -> attach(buffer)+commit posts unconfigured_buffer=3; a buffer-less commit after unmap sends a fresh configure. XML basis: xdg_toplevel "Unmapping" + xdg_surface "A newly-unmapped surface ... must perform the initial commit again before attaching a buffer".
   - Test: "unmap via null buffer resets the configure state machine" (xdg.zig:1684).

2. wm_base.destroy with live surfaces posts defunct_surfaces=1, does not destroy.
   - New per-binding `WmBaseState` (xdg.zig:133) — the wm_base resource's user data — tracks the xdg_surfaces created through the binding (appended in wmBaseGetXdgSurface, xdg.zig:242; removed in xdgSurfaceDestroy, xdg.zig:531). `.destroy` posts defunct_surfaces=1 on the wm_base and keeps the resource (xdg.zig:162-167). `wmBaseDestroy` (xdg.zig:188) marks the state `dead` and defers the free: libwayland destroys a client's resources in OBJECT-ID order, so the wm_base (created before its xdg_surfaces) goes first; `xdgSurfaceDestroy` detaches each surface and frees the state when it was the last one (xdg.zig:531-540).
   - Test: "wm_base.destroy with live surfaces posts defunct_surfaces" (xdg.zig:1744).

3. get_popup incomplete-positioner error posted on the xdg_wm_base resource.
   - xdgSurfaceGetPopup now posts `.invalid_positioner` on `xdg.wm_base.res` (xdg.zig:463-467); previously it posted the numeric code 5 on the xdg_surface resource, which the client reads as xdg_surface.invalid_size (code collision).
   - Test: strengthened "xdg popup configure and positioner errors" (xdg.zig:1630-1637) asserts code 5 AND the interface name "xdg_wm_base" via wl_display_get_protocol_error (helper `protocolError`, xdg.zig:1257).

4. Role conflict on get_xdg_surface posts wm_base role=0.
   - Pre-check `surface.role != null` in wmBaseGetXdgSurface (xdg.zig:208-213) posts role=0 on the wm_base before assignRole, instead of role.zig's wl_surface code-1 post. role.zig unchanged: its assignRole semantics still serve other roles (cursor etc.); its wl_surface role post remains correct for those. XML basis: get_xdg_surface "It is illegal to create an xdg_surface for a wl_surface which already has an assigned role".
   - Test: "get_xdg_surface on a surface with a role posts wm_base role error" (xdg.zig:1761).

5. ack_configure before a role is assigned posts not_constructed=1.
   - Role check added at the top of ackConfigure (xdg.zig:319-323), before the serial checks. XML basis: "A role must be assigned before any other requests are made to the xdg_surface object".
   - Test: "ack_configure before a role is assigned posts not_constructed" (xdg.zig:1781).

6. set_window_geometry before a role is assigned posts not_constructed=1.
   - Role check added before the size validation (xdg.zig:376-380).
   - Test: "set_window_geometry before a role is assigned posts not_constructed" (xdg.zig:1797).

7. toplevel move/resize/show_window_menu before configured posts not_constructed=1 on the xdg_surface.
   - Guards on `xdg.configured` in toplevelRequest (xdg.zig:741, 754, 761). The error uses the xdg_surface resource (the not_constructed code lives in xdg_surface.error; posting on the toplevel would read as invalid_parent).
   - Test: "toplevel move before configured posts not_constructed" (xdg.zig:1813). NOTE: test harness now creates a wl_seat (TestServer, xdg.zig:1378+) because move/resize/show_window_menu take a seat argument.

8. Resize edges validated + carried in the request_resize payload.
   - Valid edges per the XML resize_edge enum: 0,1,2,4,5,6,8,9,10 (none, top, bottom, left, top_left, bottom_left, right, top_right, bottom_right). Anything else posts invalid_resize_edge=0 on the toplevel (xdg.zig:770-774).
   - `request_resize` payload widened from `wire.Signal(*XdgToplevel)` to `wire.Signal(*ResizeRequest)` (xdg.zig:568-571, 598-599) carrying the validated edge; emit at xdg.zig:776. No consumer exists in main.zig today (verified by grep), so no callsite update was needed there.
   - Tests: "resize with an invalid edge posts invalid_resize_edge" (xdg.zig:1843); "resize carries the validated edges in the signal payload" (xdg.zig:1859).
   - NOTE: the audit brief listed edges as "top=0 bottom=1 left=2 ..." — WRONG per the XML; actual values are none=0 top=1 bottom=2 left=4 top_left=5 bottom_left=6 right=8 top_right=9 bottom_right=10. Validation follows the XML.

9. Positioner set_anchor/set_gravity/set_constraint_adjustment validated.
   - anchor/gravity valid range 0..8 (none..bottom_right per the XML enums; NOT a 0..15 bitmask as the brief guessed) — xdg.zig:1004-1017. constraint_adjustment valid bits slide_x=1 slide_y=2 flip_x=4 flip_y=8 resize_x=16 resize_y=32 (mask 0x3F) — xdg.zig:1019-1027. Violations post invalid_input=0 on the positioner. XML basis: set_gravity explicitly requires invalid_input; smithay also validates anchor.
   - Test: "positioner rejects invalid anchor, gravity and constraint adjustments" (xdg.zig:1876).

10. get_popup parent must have a role.
    - xdgSurfaceGetPopup checks `r.parent`'s XdgSurface role != .none, posting invalid_popup_parent=3 on the wm_base (xdg.zig:450-458).
    - Test: "get_popup with a parent without a role posts invalid_popup_parent" (xdg.zig:1916).
    - Child-popup stacking lists deferred (see Deferred).

13. Popup committed with a NULL parent posts not_constructed=1 on the xdg_surface.
    - Check in xdgSurfaceClientCommit (xdg.zig:1061-1066), before the unconfigured_buffer check, so a doomed popup is never configured. XML basis: get_popup "If null is passed as a parent, a parent surface must be specified using some other protocol, before committing the initial state".
    - Test: "popup with a null parent posts not_constructed at commit" (xdg.zig:1937). The pre-existing popup test was updated to give its popup a toplevel parent (xdg.zig:1589-1592).

14. set_parent self-loop posts invalid_parent=1 on the toplevel.
    - Check `r.parent == t.resource` (xdg.zig:728-733). Descendant-cycle detection needs real parenting and is deferred; parenting itself still unimplemented (logged).
    - Test: "set_parent to itself posts invalid_parent" (xdg.zig:1959).

15. get_xdg_surface on a surface with a committed/attached buffer posts unconfigured_buffer=3 at creation time.
    - Check in wmBaseGetXdgSurface after the role check (xdg.zig:213-219), posted on the new xdg_surface resource. XML basis: "Creating an xdg_surface from a wl_surface which has a buffer attached or committed is a client error".
    - Test: "get_xdg_surface on a surface with a committed buffer posts unconfigured_buffer" (xdg.zig:1976).

17. Second role object on one xdg_surface: KEPT already_constructed=2 on the xdg_surface (xdg.zig:403-407).
    - Divergence from wlroots (which posts XDG_WM_BASE_ERROR_ROLE on the xdg_surface resource — a cross-interface post the client reads as undefined code 0). The XML's xdg_surface.error.already_constructed ("Surface was already constructed") describes exactly this case and smithay posts AlreadyConstructed; kept + documented here.
    - Test: "second role object on one xdg_surface posts already_constructed" (xdg.zig:1994).

18. set_title invalid UTF-8 rejected with a log, not stored.
    - std.unicode.utf8ValidateSlice in setTitle (xdg.zig:634-643). The XML requires UTF-8 but defines no error code; wlroots' error -1 has no XML backing, so a plain reject + warn is used.
    - Test: "invalid utf-8 title is rejected without storing" (xdg.zig:2013).

19. ToplevelState grown to carry all 13 configure state values.
    - New fields tiled_left/right/top/bottom, suspended, constrained_left/right/top/bottom (xdg.zig:546-567); `stateValues` emits maximized=1..constrained_bottom=13 in XML enum order (xdg.zig:663-718); configure's stack buffer widened [4]u32 -> [13]u32 (xdg.zig:612). The client ToplevelEvents.states buffer widened likewise (xdg.zig:1300).
    - wm_capabilities (first-configure hint, since v5) NOT implemented: it needs a new event path before the first xdg_surface.configure (deferred; see Deferred).

## Deferred (documented, not implemented)

- Popup grab / not_the_topmost_popup / invalid_grab: needs seat focus + popup stacking (M3/M4). xdg_popup.grab still logged only (xdg.zig:1034-1036 area).
- ping/pong unresponsive enforcement: needs a main.zig timer; pong is logged only.
- Real parenting/stacking: set_parent beyond the self-loop check; descendant-cycle detection; popup stacking order (child-popup lists). Needs main.zig scene stacking.
- wm_capabilities event (since v5): new event path before the first configure; not required for the listed error-code parity.
- Popup parent-mapped check at commit (XML: "The parent of an xdg_popup must be mapped"): not in the audit's fix list; role+null-parent checks are in.

## Notes

- Tests use the existing TestServer wire-roundtrip pattern; the harness now also registers wl_shm (display.initShm) and wl_seat so tests can attach real shm buffers and send seat-taking requests (xdg.zig:1359-1440). createBuffer helper (xdg.zig:1462) builds a 64x64 ARGB8888 shm buffer via a retained pool.
- main.zig had no request_resize consumer (verified: grep over src/ shows only xdg.zig), so the payload widening broke nothing; the one-consumer note in the brief did not apply.
- Constraint-adjustment validation allows resize_x/resize_y (16/32) — valid per the XML bitfield, though our geometry() does not implement adjustment (M4).
