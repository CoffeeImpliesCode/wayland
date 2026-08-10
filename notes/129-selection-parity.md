# 129: Primary selection + data device parity fixes

Area: shell-protocol parity round (worker W3PrimarySelection).
Files: NEW src/compositor/primary_selection.zig; edits to src/compositor/data_device.zig, src/server/main.zig, src/root.zig.
Scope: zwp_primary_selection_device_manager_v1 v1 (full), wl_data_device_manager v3 protocol-error + bind-time delivery fixes. DnD lifecycle deferred (see Deferred).

## Facts

### Part 1: primary_selection.zig (NEW)
- Module `PrimarySelection` (src/compositor/primary_selection.zig:51). init(allocator, io, log_cfg, display, seat) at :90; deinit at :127. Global via display.addGlobal (server.zwp.PrimarySelectionDeviceManagerV1, version 1) at :114-120. Self-subscribes to seat.events.keyboard_focus at :122; unsubscribes (focus_listener.link.remove) at :131. Exposes events selection_set / selection_cleared (:83-88, emitted :353/:361).
- Manager requests (create_source / get_device / destroy): :197-251. get_device ignores the seat arg (single-seat compositor, same as data_device.zig).
- No protocol error enum exists in primary-selection-unstable-v1.xml; every violation is a silent denial (module doc :9-13).
- set_selection (deviceRequest :316): NO serial validation (:330-331 comment); caller must be the keyboard-focused client else denied silently (:318-329, smithay model). Source used-once via `finalized` flag (:167-170, set :346, denial :340-344, wlroots finalizes). Previous owner cancelled (:343-345). NULL source clears + cancels (:355-360). Delivery then goes to the focused client's devices (deliverToFocusedClient :402).
- Deliveries: deliverToFocusedClient :402 — destroys all offers, then per device of the given client: data_offer FIRST, then one offer event per mime, then selection (:427-434, order fix below). NULL selection → selection(NULL) (:441-444).
- Focus change (onKeyboardFocus :381): previous focused client's devices get selection(NULL) (:385-392, XML: offer valid "until the client loses keyboard focus"), then the current selection goes to the new focused client. focus_client tracking (:73-80) is only for the old-client NULL; set_selection validation reads the LIVE seat.keyboard_focus (:325), so a dead focused client never blocks new owners.
- Bind-time delivery: get_device :242-249 — a device bound by the focused client immediately receives the current selection (KWin/wlroots).
- source.offer dedupe: :265-270 — duplicate mime ignored.
- sourceDestroy :285: selected source death clears the selection, sends cancelled (courtesy; the proxy is already gone so it is unobservable), re-delivers selection(NULL), inerts every offer referencing the source.
- offer.receive :450-476: relays send(mime, fd) then closes the fd; no source → close fd only. Dead (inerted) offers use deadOfferHandler :493 (close fd, no crash). destroyOffer :512 inerts the wire resource (handler replaced, struct freed) so a later client destroy neither errors nor kills.
- Tests (in-file, wire-level, two clients A/B on separate socketpairs):
  - "primary selection: focused set_selection (serial ignored) delivers to the focused client and follows focus" (:819): serial=0 accepted; focused client gets offer+selection (1 mime event); on focus move the other bound client gets offer+selection and the previous focused client gets selection(NULL).
  - "primary selection: non-focused set_selection is denied silently" (:873).
  - "primary selection: set_selection(NULL) clears and cancels the previous owner" (:907).
  - "primary selection: offer.receive with no source closes the fd, no crash" (:945).
  - "primary selection: source destroy cancels and inerts the offer" (:991).
  - "primary selection: new device binding gets the current selection" (:1035).
  - "primary selection: duplicate source.offer is ignored" (:1063).

### Part 2: data_device.zig fixes (audit A3)
- Bind-time delivery: get_data_device :223-232 — new device of the focused client immediately receives the current selection via deliverSelectionToFocus (wlroots seat_client_send_selection, wlr_seat.c; KWin seat.cpp:159-177).
- wl_data_source.set_actions: :256-268 — bits outside {copy, move} → invalid_action_mask=0 on wl_data_source (wayland.xml: the source side may only offer copy/move; wlroots data_source_handle_set_actions). Valid mask stored in DataSource.actions (:146-150) for the offer-side check.
- wl_data_offer.finish: :484-490 — clipboard offers are never drag-and-drop offers, so finish is never eligible → invalid_finish=0 (wayland.xml: "If wl_data_offer.finish request is received for a non drag and drop operation, the invalid_finish protocol error is raised").
- wl_data_offer.set_actions: :491-517 — dnd_actions/preferred_action with bits outside the dnd_action enum or a multi-bit preferred_action → invalid_action_mask=1; preferred action the source does not support (source without action support: actions==0) → invalid_action=2 (wayland.xml:581-590 enum; wlroots data_offer_handle_set_actions, wlr_data_offer.c:123-189).
- Offer event ORDER fixed: data_offer now sent BEFORE the per-mime offer events and selection (:435-441). libwayland-client queue_event (wayland-client.c) silently discards events for object ids it does not know yet; the old order (mimes first) dropped every mime event client-side. Matches wlroots device_resource_send_selection. Same fix applied to primary_selection.zig (:427-434).
- Cross-client selection + dangling-source behavior (existing tests "selection is stored seat-wide...", "offer dies with its source...", "stale set_selection serials are ignored...") untouched: set_selection serial validation retained for wl_data_device (M3 behavior, wlroots-compatible).
- New tests:
  - "new data device binding receives the current selection at bind time" (data_device.zig:1000).
  - "offer.finish on a clipboard offer raises invalid_finish" (:1035) — ClientDispatchFailed + protocol error code 0 (invalid_finish).
  - "source.set_actions with invalid bits raises invalid_action_mask" (:1061) — ClientDispatchFailed + protocol error code 0 (invalid_action_mask).

### Wiring
- src/server/main.zig: ServerState field `primary_selection` after `data_device` (:173-176); init + defer after the data_device block (:376-379); state literal entry (:484). No listener fields: the module self-subscribes to the seat's keyboard-focus signal; main.zig needs no module events.
- src/root.zig: export (:43-45) + comptime analysis entry (:94).

## Divergences
- The task text placed the primary_selection init "after the XdgShell block (353-354)"; it is actually registered after the data_device block (:376-379) because init requires the `seat` object, which is created after XdgShell.
- The offer event-ordering fix (data_offer → mimes → selection) was not in the ticket list but is a wire-conformance bug in the same delivery path: with the previous order, libwayland-client dropped every mime event (unknown object id). Fixed in both data_device.zig and primary_selection.zig.
- wl_data_offer.set_actions ordering: mask validation runs before the source check; a preferred_action with multiple bits or invalid bits is invalid_action_mask (1), a single valid bit the source does not support is invalid_action (2).
- Primary selection offer.mime events are observed client-side by attaching the offer listener inside the device's data_offer handler (OfferMimeCounter, primary_selection.zig:599-607), because the offer proxy only exists after data_offer arrives.

## Verification (real gate)
- `zig build test`: EXIT 0, zero failed tests, zero leaks (lib + exe suites). Confirmed the gate catches failures: a deliberately broken assertion in a primary test made the build exit 1 with the test name, then reverted.
- Harness bug found by the real suite (all 7 primary tests failed at init with GlobalMissing): `connectClient` pumped via the shared `pump()`, but the connecting client is not yet in `ts.client_a/client_b`, so the pump polled zero fds and the registry globals sat undelivered. Fixed with `connectPump` (primary_selection.zig:720-734), which flushes/dispatches only the connecting client's fd for the registry and bind rounds.
- The `wl_data_offer#4278190080: error 0: finish` line in the suite log is the EXPECTED outcome of the data_device "offer.finish on a clipboard offer raises invalid_finish" test (0xFF000000 = first server-allocated id), not a primary-selection failure.
- The build's "failed command: .../test --listen=-" line in green runs is informational: build_runner printErrorMessages prints the run command for any step with stderr output; the exit code comes from failure_count only (build_runner.zig:975).

## Deferred (DnD, out of scope this round)
- wl_data_device.start_drag remains a source-cancel stub (data_device.zig deviceRequest.start_drag): no drag icon, no enter/motion/drop/finished, no source_actions/action events, no wl_data_source dnd_drop_performed/dnd_finished/action.
- wl_data_offer.accept and set_actions are validated but their results are unused (no DnD negotiation state machine).
- No wl_data_device.enter/leave/motion/drop delivery; no pointer-grab serial ring (single-seat last_serial only).
- wl_data_source.set_actions stores the mask but no DnD uses it yet.

## [INFERENCE]
- libwayland-client dropping unknown-id events: verified by reading wayland-1.26.0 src/wayland-client.c queue_event ("If our proxy is gone or a zombie, just eat the event"), not by running the compositor.
- wlroots/KWin primary-selection semantics (focus-gated set_selection, used-once source, bind-time delivery) are taken from the audit brief; no wlroots source tree is present in this repo to cite file:line.
