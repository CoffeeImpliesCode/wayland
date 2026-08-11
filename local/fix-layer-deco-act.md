# fix-layer-deco-act — layer-shell + xdg-decoration + xdg-activation fix plan

All O: citations re-verified against current source on 2026-08-11; drifted cmp line numbers corrected in place. Reference lines re-verified against the read-only clones (wlroots 0.20.2, smithay master, KWin master).

## Layer-shell

### L1 get_popup emits `new_popup` compositor signal [MAJOR] → FIX (Phase 2)
- Files: `src/shell/layer_shell.zig` — `LayerShell.events` struct (:79-82, currently only `new_layer_surface` at :81), `LayerShell.init` (:104), `getPopup` (:455-486). `src/server/main.zig` — listener field block (:296-301), listener init (:559-566), signal registration (:597-617).
- Change: add `new_popup: wire.Signal(*xdg_mod.XdgPopup)` to `LayerShell.events` (next to `new_layer_surface`, :81) and `shell.events.new_popup.init()` next to :104. In `getPopup`, after the popup is fully parented (`popup.layer_parent = ls.surface` at :462, list insert + destroy-listener attach, before the log at :485), emit `shell.events.new_popup.emit(popup)` — wlroots order is insert into `parent->popups` then emit (`wl_signal_emit_mutable(&parent->events.new_popup, popup)`, wlr_layer_shell_v1.c:256-257; smithay `WlrLayerShellHandler::new_popup`, handlers.rs:272-295; KWin `popupPrivate->attachTo`, layershell_v1.cpp:259). In `main.zig` add a `new_layer_popup_listener` + `onNewLayerPopup` handler that tracks layer popups for observability (mirror `onNewLayerSurface` :1025-1032) and subscribe next to the `new_layer_surface` registration (:599). Positioning/rendering of layer popups stays DEFER with F12 popup compositing — the handler must not attempt anchoring.
- Test: extend the in-module wire test "layer surface: get_popup parents a NULL-parent xdg_popup" (:1205-1260): add a capture listener on `ts.shell.?.events.new_popup` before `layer_surface.getPopup(popup)`, pump, assert capture count == 1 and the captured `*xdg_mod.XdgPopup` equals `ls.popups.items[0]` (same object, `layer_parent == ls.surface`). Keep the existing assertions — signal emission must not disturb the popup configure/ack flow (:1256-1260).
- Acceptance: a compositor subscribing to `LayerShell.events.new_popup` observes every layer-popup creation with the parented `XdgPopup`; layer popups become consumable (anchoring lands with F12).
- Risk: emit ordering — listeners must see a fully-parented popup (layer_parent set, destroy listener attached) or an observer touching the popup races the teardown path. Do not confuse with the xdg-shell `shell.events.new_popup` signal (main.zig :598) — separate signal, separate type.

### L2 xdg-decoration `new_toplevel_decoration` signal + main.zig announces initial mode [MAJOR] → FIX (Phase 2)
- Files: `src/shell/xdg_decoration.zig` — `XdgDecoration.events` (:128-130, only `request_mode`), `init` (:152), `getToplevelDecoration` (:225-292). `src/server/main.zig` — `request_mode` registration (:617), `onDecorationMode` (:1093-1116).
- Change: add `new_toplevel_decoration: wire.Signal(*Decoration)` to `XdgDecoration.events` and init it next to `request_mode.init()` (:152). Emit at the end of `getToplevelDecoration`, after `deco.decorations.append(...)` succeeds (:282-291) and before the function returns — wlroots emits after inserting into `manager->decorations` (`wl_signal_emit_mutable(&manager->events.new_toplevel_decoration, decoration)`, wlr_xdg_decoration_v1.c:237; smithay `new_decoration` handler call, decoration.rs:252; KWin `decorationCreated`, xdgdecoration_v1.cpp:47). In `main.zig`: add a listener + `onNewDecoration` handler that announces the compositor's initial mode — call `dec.sendConfigure(mode)` (:105-109) with the same policy mode as `onDecorationMode` (:1115), so a client that never sends `set_mode` receives a server-side-mode configure (wlroots compositors call `wlr_xdg_toplevel_decoration_v1_set_mode` on the new_decoration signal). Update the stale module doc comment at :29-31 ("No initial configure is sent").
- Test: module wire test (extend :587+): subscribe to `new_toplevel_decoration`, `getToplevelDecoration`, pump, assert count == 1 and the captured `*Decoration` == `deco.decorations.items[0]`; assert the module alone sends no configure (configures stay client-driven — the existing happy-path tests :587-622, :711-749 must still pass unchanged). New main.zig E2E (no decoration coverage exists in `src/server/main_test.zig` today): client creates a toplevel + decoration, never calls `set_mode`; after acking the first xdg configure, a `zxdg_toplevel_decoration_v1.configure` arrives carrying the policy mode (server_side for the focused toplevel).
- Acceptance: the compositor is notified of every decoration creation and can announce a compositor-decided initial mode; a client that never sends `set_mode` stops drawing client chrome (server-side policy reachable).
- Risk: `sendConfigure` → `toplevel.configure(0, 0)` (:108) must not race the toplevel's own first configure — the `onSurfaceConfigure` dedupe (`pending_mode == scheduled_mode`, :366) already guards double mode-configures; keep the announce idempotent. `main_test.zig` has no decoration tests, so no existing E2E breaks.

### L3 layer `close()`: inert resource instead of destroy [MINOR] → FIX (Phase 2)
- Files: `src/shell/layer_shell.zig` — `close()` (:413-418), `layerSurfaceDestroy` (:592-610), module doc (:19-21).
- Change: `close()` keeps sending `closed` but inerts the wire resource and tears the object down without destroying the resource (wlroots: `wlr_layer_surface_v1_destroy` sends closed, then `layer_surface_destroy` runs `wl_resource_set_user_data(resource, NULL)`, wlr_layer_shell_v1.c:331-337/:58 — the client's later destroy is a no-op). Use the codebase inert idiom (`src/compositor/surface.zig:376-381`: `raw.setDispatcher(null, null, null, null)` — clears user data and drops the destroy callback), then run the existing teardown directly:
```zig
pub fn close(ls: *LayerSurface) void {
    if (ls.closed) return;
    ls.closed = true;
    ls.resource.sendClosed();
    const raw: *wire.Resource = @ptrCast(ls.resource);
    raw.setDispatcher(null, null, null, null); // inert: later client requests are no-ops
    layerSurfaceDestroy(ls.resource, ls); // teardown + free, resource stays alive
}
```
`layerSurfaceDestroy` never destroys the resource itself (it is the handler body), so this is a plain direct call; it still unmaps the surface and dismisses parented popups. Update the doc at :19-21 and the `close()` comment (:410-412).
- Test: in-module wire test: map a layer surface (configure + ack + buffer, per :1047-1122), call `ls.close()` compositor-side, pump, assert `closed_count == 1` (client received closed); then the client sends `destroy` on the layer surface — pump must SUCCEED with no protocol error, and `ts.shell.?.layer_surfaces` is empty (object torn down at close). Optionally assert a post-close `set_size` is silently ignored. The existing v3 close test (:1196-1203) keeps passing unchanged.
- Acceptance: after `closed`, the client's subsequent `destroy`/requests are silent no-ops on a live-but-inert resource — wlroots parity; the connection stays healthy.
- Risk: teardown ordering — `layerSurfaceDestroy` must be the only free path (client disconnect/deinit cascade unaffected because the null dispatcher makes the later client destroy a no-op); no double-free since the object leaves `shell.layer_surfaces` at close. `deinit()` (:139-141) destroys remaining resources; inerted ones are already gone from the list.

### L4 set_size overflow: implementation error instead of wire -1 [MINOR] → FIX (Phase 2)
- Files: `src/shell/layer_shell.zig` — `layerSurfaceRequest` `.set_size` arm (:511-521, `raw.postError(@bitCast(@as(i32, -1)), ...)` at :518-519); test at :1334-1348.
- Change: replace the raw -1 wire `postError` with a client-level implementation error, wlroots-parity (`wl_client_post_implementation_error`, wlr_layer_shell_v1.c:137-141). The generated bindings expose `Client.postImplementationError(msg)` (wl_client_post_implementation_error, verified in the generated `protocol` module), and `Resource.getClient()` exists:
```zig
if (r.width > std.math.maxInt(i32) or r.height > std.math.maxInt(i32)) {
    ls.resource.getClient().postImplementationError("zwlr_layer_surface_v1.set_size: width/height exceed INT32_MAX");
    return;
}
```
Both paths terminate the client; the implementation error is server-side only (not observable via `wl_display_get_protocol_error`), matching wlroots.
- Test: update the existing test "layer surface: set_size beyond INT32_MAX is an implementation error" (:1334-1348) — the name already states the target: `setSize(maxInt+1, 0)`, pump still `expectError(error.ClientDispatchFailed, ts.pump())`, but the `protocolError(ts)` assertion flips from `code == -1` to no wire protocol error (code 0 / no error recorded). Keep the duplicate-set_size no-op sibling test (:1365-1370) unchanged.
- Acceptance: an oversized set_size kills the client via a server-side implementation error, not a wire protocol error — indistinguishable to well-behaved clients, observable parity with wlroots.
- Risk: none beyond the one test assertion; the path is only reachable with a width/height above 2³¹−1.

### L5 same-role rejection [MINOR] → ACCEPT — Reason: deliberate strictness (note 129 #4): `layerShellGetLayerSurface` rejects ANY pre-existing role with the shell `role` error (:149-207, check at :168-177), while wlroots/KWin tolerate re-assigning the layer role (`wlr_surface_set_role`, wlr_layer_shell_v1.c:460; KWin layershell_v1.cpp:96-103). Real clients never create two layer surfaces on one wl_surface; the stricter check is the XML role-conflict behavior.

### L6 module-auto initial configure [INFO] → DEFER — Trigger: when X08 (compositor-driven configure) lands — the commit hook auto-sends the initial configure with the fallback size (`layerSurfaceCommit` :655-663 → `sendConfigure` :321-337, substituting `setFallbackSize` values :372-375 for 0-desired dimensions); wlroots never self-configures, the compositor calls `wlr_layer_surface_v1_configure` (asserts `initialized`, wlr_layer_shell_v1.c:316-336). | Prereq: X08 compositor-driven configure/arrange hook replacing `setFallbackSize`. | Scope: small — move the `sendConfigure` call out of `layerSurfaceCommit` into a public arrange entry point; update the affected configure tests (:1047-1122, :1313-1332).

### L7 keyboard-interactivity focus policy [INFO] → DEFER — Trigger: when main.zig implements layer keyboard-focus routing for EXCLUSIVE/ON_DEMAND surfaces (documented out of scope, layer_shell.zig:24-27; the value is stored in `setKeyboardInteractivity` :432-445 and applied to `current` at :614 — wlroots also only stores it; focus is compositor policy). | Prereq: seat focus-policy work in main.zig. | Scope: medium — new focus-routing logic only, no wire changes.

### D1 missing `new_toplevel_decoration` signal [MAJOR] → FIX (Phase 2) — Duplicate of L2 (the cmp's decoration-area headline; identical finding). See L2 for the full task spec; no separate work item.

### D2 invalid_mode raised for mode ∉ {client_side, server_side} [MINOR] → ACCEPT — Reason: XML-mandated ("If an invalid mode is supplied... the invalid_mode protocol error is raised", xdg-decoration-unstable-v1.xml); the references are the lax ones (wlroots stores `requested_mode` with no validation, wlr_xdg_decoration_v1.c:25-43; smithay dispatches only `WEnum::Value`; KWin maps to Undefined). Covered by the wire test at :649-661. Keep the strictness.

### D3 decoration v2 [MINOR] → DEFER — Trigger: a client needs the v2 relaxations (decoration on a toplevel that already committed a buffer; mode retained across decoration re-create) — KWin is the only reference at v2 (`d->init(*display, 2)`, xdgdecoration_v1.cpp:54); wlroots/smithay advertise v1 like ours (`DECORATION_MANAGER_VERSION 1`, wlr_xdg_decoration_v1.c:8; build.zig:41). | Prereq: bump build.zig:41 to 2 + relax the `unconfigured_buffer` check (:242-248) + mode-retention state. | Scope: small-moderate; v1 is coherent, not a correctness bug.

### D4 orphaned-at-creation handled more safely than wlroots [INFO] → ACCEPT — Reason: positive divergence: `getToplevelDecoration` checks `toplevel_res.getUserData() orelse → post orphaned + destroy` (:233-237) before any deref; wlroots would deref a freed toplevel, while smithay (alive_tracker, decoration.rs:227-231) and KWin (toplevelPrivate) check the same. Keep.

### D5 request_mode/unset_mode signal shape [INFO] → ACCEPT — Reason: one signal carrying `mode: ?Mode` (null = unset, `emitRequestMode` :318-324, set_mode :302-310 / unset_mode :313) is equivalent to wlroots' single `request_mode` with a distinguishing `requested_mode` field (wlr_xdg_decoration_v1.c:33/:42) and smithay's two callbacks — the compositor cannot confuse them. Keep.

## xdg-activation

### A1 gate the surface-focus check behind set_serial [MINOR] → FIX (Phase 2)
- Files: `src/shell/xdg_activation.zig` — `tokenValid` (:494-511; focus check at :502-504).
- Change: only enforce the focus constraint when a serial was set, wlroots-parity. wlroots checks focus only inside `if (token->seat != NULL)` (wlr_xdg_activation_v1.c:108-123 — verified; the cmp's :155-164 drifted); ours runs the focus check whenever a surface is set, regardless of serial, dropping the legit launcher set-surface-no-serial flow. Ours sets `token.seat` and `token.serial` together in `set_serial` (:381-382), so gating on `token.serial` is equivalent to gating on the seat. Fold the focus check into the existing serial branch:
```zig
if (token.serial) |serial| {
    const seat = token.seat orelse return false;
    if (!seat.validateEventSerial(token.resource.?.getClient(), serial)) return false;
    if (token.surface) |surface| {
        if (seat.keyboard_focus != surface and seat.pointer_focus != surface) return false;
    }
}
```
Update the `tokenValid` doc comment (:488-493), which states the focus rule unconditionally.
- Test: in-module wire test modeled on "activation bogus serial -> invalid done token" (:781-813): client creates a token, calls only `set_surface(unfocused_surface)` with NO `set_serial`, commits → done() carries a real (non-invalid) token, `new_token` fires (count 1, :850-916 pattern), and `activate()` of it fires `request_activate` (count 1). Today this token is dropped by the focus check; after the fix the launcher flow works. The bogus-serial test (:781-813) and the inert-seat test (:992-1024) must still pass (both exercise the serial-gated path).
- Acceptance: a token with `set_surface` but no `set_serial` is accepted and activates, matching wlroots; the common set_serial flow is unchanged.
- Risk: accepts tokens bound to unfocused surfaces when no serial is given — exactly wlroots' policy (the XML says compositors "might refuse", not must); no main.zig change needed (`onRequestActivate` :1065-1077 just logs).

### A2 activate(): inert token resource instead of destroy [MINOR] → FIX (Phase 2)
- Files: `src/shell/xdg_activation.zig` — `activationActivate` (:282-301, destroy at :300, and the surfaceForResource-failure path at :290-292), `destroyToken` doc (:421-425).
- Change: on `activate()`, make the creating client's token wire resource inert instead of destroying it, wlroots-parity (wlroots inerts the resource at commit, wlr_xdg_activation_v1.c:104-106, and activate only frees the object, :317-319 — the creator's later `destroy` is a no-op). Ours keeps the resource live at commit (guarded by `token.committed`, A3), so the inerting happens at activate: after the emit, replace the destroy at :300 with the inert idiom (`raw.setDispatcher(null, null, null, null)`, cf. `src/compositor/surface.zig:376-381`) followed by `destroyToken(token)` (unlinks from the registry, cancels the 30s timer at :435, frees). Apply the same inert+free to the failure path at :290-292 (surfaceForResource null). The dispatcher must be nulled BEFORE `destroyToken` frees the token so the handler data never dangles. Update `destroyToken`'s doc comment ("Only valid when the wire resource is already destroyed") to cover the inert-then-free path.
- Test: in-module wire test: commit a token (done arrives), the client calls `activate(token_str, surface)` → `request_activate` fires once (capture count 1); then the client sends `destroy` on the token resource → pump SUCCEEDS with no protocol error and the connection stays healthy (today the server destroyed the resource, so the client destroy targets a dead id → protocol error). Assert `ts.activation.?.tokens.items.len == 0` after activate (single-use preserved).
- Acceptance: the creating client can destroy its token after activate without a protocol error — the resource is inert, matching wlroots; single-use semantics unchanged.
- Risk: inert-before-free ordering (above); post-activate setters on the inert resource become silent no-ops instead of `already_used` — acceptable, the token is consumed; the expiry timer is cancelled by `destroyToken` and `tokenTimeout` (:512-521) can no longer fire for the consumed token since it is unlinked.

### A3 post-commit already_used via `committed` flag [INFO] → ACCEPT — Reason: functionally equivalent to wlroots' resource inertness at commit: ours keeps the resource live guarded by `token.committed` (:315-317, checks at :363-368, :384-388, :396-400, :450-453) and posts `already_used=0`; wlroots inerts the resource so `token_from_resource` returns NULL (wlr_xdg_activation_v1.c:104-106) — same observable error. Keep.

### A4 new_token timing matches wlroots [INFO] → ACCEPT — Reason: ours fires `new_token` before `done()` only on a successful commit (:484-485), matching wlroots (wlr_xdg_activation_v1.c:132-134); smithay invokes `token_created` for EVERY commit and defers validity to the handler (dispatch.rs:151-161) — a design difference in smithay, not an ours bug. Keep.

### A5 KWin policy difference [INFO] → ACCEPT — Reason: KWin performs no server-side token registry/validation at all — `activate` just emits `activateRequested(surface, token)` (xdgactivation_v1.cpp:96-99); wlroots and ours validate serial+focus and drop invalid tokens. Ours matches wlroots. Keep.

## Area verdict

Fixable now: 6 (L1, L2, L3, L4, A1, A2 — all FIX Phase 2, two MAJOR missing-compositor-signal gaps L1/L2 plus four MINOR strictness/resource-lifecycle fixes). Deferred: 2 (L6 initial-configure redesign, D3 decoration v2 — both gated on external work X08 / a client needing v2). Accepted: 8 (L5, D2, D4, D5, A3, A4, A5 deliberate-or-positive divergences) + the D1 dup note folded into L2. The wire surface of all three protocols is complete and faithful at the advertised versions; the real exposure is the two missing compositor hooks, which is why L1/L2 are Phase-2 first. First task to do: L1 (new_popup signal — smallest self-contained change, unblocks layer-popup consumption, and its wire test extends the existing get_popup test), then L2 (new_toplevel_decoration + main.zig initial-mode announce), then the four MINORs (L3, L4, A1, A2 — each a localized edit plus one test update/add).
