# 134: F2F audit — selection + shell auxiliaries

Scope: wl_data_device_manager (data_device.zig), zwp_primary_selection_device_manager_v1 (primary_selection.zig), xdg_activation_v1 (xdg_activation.zig), zxdg_decoration_manager_v1 (xdg_decoration.zig).
References (read-only): wlroots 0.20.2 `types/data_device/` + `types/wlr_{primary_selection,primary_selection_v1,xdg_activation_v1,xdg_decoration_v1}.c`; smithay v0.7.0 `src/wayland/selection/` + `xdg_activation/` + `shell/xdg/`; KWin master `src/wayland/{datadevice,dataoffer,datasource,seat,primaryselection*_v1,xdgactivation_v1,xdgdecoration_v1}.cpp` + `src/xdgshellwindow.cpp`. XML ground truth: protocols/wayland-protocols/ (unstable/primary-selection, unstable/xdg-decoration, staging/xdg-activation).

Legend: D=wlr_data_device.c, S=wlr_data_source.c, O=wlr_data_offer.c, G=wlr_drag.c, PV1=wlr_primary_selection_v1.c, PS=wlr_primary_selection.c, XA=wlr_xdg_activation_v1.c, XD=wlr_xdg_decoration_v1.c, smDD=smithay selection/data_device/device.rs, smPS=smithay selection/primary_selection/device.rs, smSD=smithay selection/seat_data.rs, smXA=smithay xdg_activation/dispatch.rs, smXD=smithay shell/xdg/decoration.rs, smXDM=smithay shell/xdg/mod.rs, KWDD=KWin wayland/datadevice.cpp, KWOF=KWin wayland/dataoffer.cpp, KWDS=KWin wayland/datasource.cpp, KWS=KWin wayland/seat.cpp, KWP=KWin wayland/primaryselectiondevice_v1.cpp, KWXA=KWin wayland/xdgactivation_v1.cpp, KWXD=KWin wayland/xdgdecoration_v1.cpp, KWSW=KWin xdgshellwindow.cpp.

## 1. wl_data_device_manager — data_device.zig

| Our fn (data_device.zig) | Ref fn | What it does |
|---|---|---|
| data_device_version:41 | DATA_DEVICE_MANAGER_VERSION, D:13 | Manager global version 3 |
| DataDeviceManager struct :43 | struct wlr_data_device_manager, D:295 | Manager state: selection, sources, devices, offers |
| init :74 | wlr_data_device_manager_create, D:295-319 | Create global, wire focus listener |
| deinit :106 | handle_display_destroy, D:283-293 | Tear down global + every resource |
| DataDevice struct :134 | wlr_seat_client data_devices list, D:100-103 | Per-client device resource |
| DataSource struct :140 (mime_types, actions) | wlr_client_data_source, S:236-267 | Source: mimes + action mask; NO finalized flag |
| DataOffer struct :154 (source ptr) | wlr_data_offer, O:239-284 | Offer: source ref, type |
| bindManager :164 | data_device_manager_bind, D:269-281 | Bind global |
| managerRequest.create_data_source :178 | data_device_manager_create_data_source, D:254-261 | Create source, child version = manager version |
| managerRequest.get_data_device :209 | data_device_manager_get_data_device, D:226-252 | Create device; bind-time selection to focused client (D:247-249) |
| sourceRequest.offer :255 | data_source_offer, S:184-222 | Append mime (ours: no dedup; wlroots dedups S:199-204) |
| sourceRequest.set_actions :267 | data_source_set_actions, S:152-182 | Validate copy/move mask, store. wlroots also: once-only S:166-170, finalized check S:173-178; ours: no once-only, no finalized |
| sourceRequest.destroy :280 | data_source_destroy, S:147-150 | Destroy resource |
| sourceDestroy :284 | client_data_source_destroy, S:114-120 + seat_handle_selection_source_destroy, D:167-182 | Selected source death: cancel, clear selection, re-deliver NULL |
| deviceRequest.set_selection :315 | data_device_set_selection, D:24-45 + wlr_seat_request_set_selection, D:144-165 | Serial-validated clipboard set; ours: serial==last_serial; wlroots: per-client ring + superseded check D:148-153; smithay: focus-gated, no serial (smDD:147-183); KWin: ordering-only (KWS:308-317) |
| deviceRequest.start_drag :356 | data_device_start_drag, D:47-87 + G:444-561 | Ours: serial check, cancel source. Ref: full DnD (see finding DD-1) |
| deviceRequest.release :379 | data_device_release, D:89-92 | Destroy device |
| deviceDestroy :383 | data_device_handle_resource_destroy, D:100-103 | Unlink; selection survives (same) |
| onKeyboardFocus :399 | seat_client_send_selection, D:125-143 (focus hook) | Re-deliver on focus change |
| deliverSelectionToFocus :410 | seat_client_send_selection D:125-143 + device_resource_send_selection D:105-123 | Destroy old offers, fresh offer per device, order data_offer→mimes→selection |
| offerRequest.accept :477 | data_offer_handle_accept, O:78-92 | Ours: no-op. wlroots: relays to source only for drag offers |
| offerRequest.receive :481 | data_offer_handle_receive, O:94-102 + client_data_source_send, S:106-112 | Relay send(mime, fd), close fd |
| offerRequest.destroy :497 | data_offer_handle_destroy, O:118-121 | Destroy offer |
| offerRequest.finish :498 | data_offer_handle_finish, O:123-153 | invalid_finish on non-drag offer (parity) |
| offerRequest.set_actions :506 | data_offer_handle_set_actions, O:155-189 | Mask/preferred validation + source support (ours). wlroots adds INVALID_OFFER for non-drag O:178-182 + stores actions + update_action O:184-189 |
| offerDestroy :540 | data_offer_handle_resource_destroy, O:225-228 | Unlink + free on client destroy |
| deadOfferHandler :556 | inert offer path, O:191-214 | Inert offers: close fd only |
| destroyOffer :574 | data_offer_destroy, O:191-214 + data_offer_handle_source_destroy, O:230-236 | Inert + free; null source first |

## 2. zwp_primary_selection_device_manager_v1 — primary_selection.zig

| Our fn (primary_selection.zig) | Ref fn | What it does |
|---|---|---|
| primary_selection_version:49 | DEVICE_MANAGER_VERSION, PV1:13 | Global version 1 |
| PrimarySelection struct :51 | wlr_primary_selection_v1_device_manager, PV1:362+ | State: devices, sources, offers, selection, focus_client |
| init :90 | wlr_primary_selection_v1_device_manager_create, PV1:473-497 | Create global, wire focus listener |
| deinit :127 | handle_display_destroy, PV1:455-471 | Teardown |
| PrimarySelectionDevice struct :155 | wlr_primary_selection_v1_device, PV1:298-334 | Per-seat device (wlroots: one per seat, ours: one per client) |
| PrimarySelectionSource struct :161 (finalized) | client_data_source, PV1:99-124 | Source + used-once flag |
| PrimarySelectionOffer struct :174 | offer resource, PV1:16-46 | Offer, source ref |
| bindManager :183 | primary_selection_device_manager_bind, PV1:441-453 | Bind global |
| managerRequest.create_source :197 | device_manager_handle_create_source, PV1:369-388 | Create source |
| managerRequest.get_device :221 | device_manager_handle_get_device, PV1:390-426 | Create device; bind-time selection if focused (PV1:421-424) |
| managerRequest.destroy :251 | device_manager_handle_destroy, PV1:428-432 | Destroy manager |
| sourceRequest.offer :259 | source_handle_offer, PV1:133-167 | Append mime, dedup (both dedup) |
| sourceRequest.destroy :281 | source_handle_destroy, PV1:169-173 | Destroy source |
| sourceDestroy :285 | source_resource_handle_destroy, PV1:179-188 + client_source_destroy, PV1:110-121 | Selected source death: cancel, clear, re-deliver NULL |
| deviceRequest.set_selection :316 | device_handle_set_selection, PV1:198-222 + wlr_seat_request_set_primary_selection, PS:48-70 | Ours: focus-gated, no serial, used-once enforced. wlroots: serial + superseded (PS:54-62), finalizes always (PV1:213-216); smithay: focus-gated, no serial, no used-once (smPS:72-92); KWin: ordering-only (KWS:319-333) |
| deviceRequest.destroy :379 | device_handle_destroy, PV1:224-228 | Destroy device |
| deviceDestroy :383 | device_handle_resource_destroy, PV1:234-237 | Unlink; selection survives |
| onKeyboardFocus :399 | device_handle_seat_focus_change, PV1:276-283 | Ours: NULL to old client + deliver to new. wlroots: deliver to new only (TODO comment PV1:279-280) |
| deliverToFocusedClient :420 | create_offer PV1:53-80 + device_send_selection PV1:250-265 | Destroy old offers, order data_offer→mimes→selection |
| offerRequest.receive :478 | offer_handle_receive, PV1:23-34 | Relay send, close fd; no source → close |
| offerRequest.destroy :500 | offer_handle_destroy, PV1:36-40 | Destroy offer |
| offerDestroy :504 | offer_handle_resource_destroy, PV1:46-48 | Unlink + free |
| deadOfferHandler :519 | destroy_offer, PV1:82-96 | Inert offers: close fd only |
| destroyOffer :538 | destroy_offer, PV1:82-96 | Inert + free |

## 3. xdg_activation_v1 — xdg_activation.zig

| Our fn (xdg_activation.zig) | Ref fn | What it does |
|---|---|---|
| token_timeout_ms:42 | XA:373 (token_timeout_msec = 30000) | 30 s validity |
| ActivateRequest struct :51 | request_activate event, XA:292-321 | Compositor-facing activation payload |
| XdgActivation struct :56 | wlr_xdg_activation_v1, XA:360-389 | Global + token registry |
| init :77 | wlr_xdg_activation_v1_create, XA:360-389 | Create global (v1) |
| deinit :112 | handle_display_destroy, XA:341-358 | Destroy tokens + global |
| activationBind :125 | activation_bind, XA:328-339 | Bind global |
| activationRequest.destroy :140 | activation_handle_destroy, XA:247-251 | Destroy global |
| activationRequest.get_activation_token :141 | activation_handle_get_activation_token, XA:269-290 | Create token, child version = global version |
| activationRequest.activate :164 | activation_handle_activate, XA:292-321 | Lookup + emit + destroy (single-use) |
| activationActivate :171 | activation_handle_activate, XA:292-321 | Unknown token ignored; emit; destroy |
| ActivationToken struct :196 | wlr_xdg_activation_token_v1, XA:22-44 | committed/invalid/serial/surface/app_id/timer state |
| tokenRequest.set_serial :224 | token_handle_set_serial, XA:175-200 | Store serial (+ seat); ours: seat arg ignored (single seat) |
| tokenRequest.set_app_id :232 | token_handle_set_app_id, XA:151-164 | Store app_id, already_used after commit |
| tokenRequest.set_surface :244 | token_handle_set_surface, XA:210-228 | Store surface, already_used after commit |
| tokenRequest.commit :251 | token_handle_commit, XA:93-149 | One-shot; validate; done() with token |
| tokenRequest.destroy :253 | token_handle_destroy, XA:58-61 | Destroy token |
| tokenDestroy :257 | wlr_xdg_activation_token_v1_destroy, XA:22-44 | Unlink, remove timer, free |
| tokenCommit :270 | token_handle_commit, XA:93-149 | Generate, validate, register, timer, done |
| tokenValid :318 | commit validation, XA:104-114 | serial==last_serial (ours) vs per-client ring (wlroots); surface in kbd/pointer focus (parity) |
| tokenTimeout :335 | token_handle_timeout, XA:46-51 | Expiry: destroy token |
| findToken :342 | wlr_xdg_activation_v1_find_token, XA:406-415 | Registry lookup |
| surfaceForResource :350 | wlr_surface_from_resource (wlroots) | Wire → Surface wrapper |
| generateToken :361 | generate_token (util/token.h) | 32-hex token; ours Xoshiro-clock, wlroots getrandom |

## 4. zxdg_decoration_manager_v1 — xdg_decoration.zig

| Our fn (xdg_decoration.zig) | Ref fn | What it does |
|---|---|---|
| RequestMode struct :43 | request_mode event, XD:25-43 | Compositor-facing mode request |
| Decoration struct :48 (toplevel, destroy_listener) | wlr_xdg_toplevel_decoration_v1, XD:10-160 | Decoration state; ours lacks requested/scheduled/pending/current mode + configure_list |
| Decoration.sendConfigure :63 | wlr_xdg_toplevel_decoration_v1_set_mode, XD:52-58 + configure send, XD:93-113 | Ours: direct standalone event. Ref: schedules surface configure, mode sent in configure cycle |
| XdgDecoration struct :72 | wlr_xdg_decoration_manager_v1, XD:152-295 | Manager global + decorations list |
| init :88 | wlr_xdg_decoration_manager_v1_create, XD:273-295 | Create global (v1) |
| deinit :122 | handle_display_destroy, XD:260-271 | Teardown |
| decorationBind :135 | decoration_manager_bind, XD:246-258 | Bind global |
| managerRequest.destroy :150 | decoration_manager_handle_destroy, XD:162-165 | Destroy manager |
| managerRequest.get_toplevel_decoration :151 | decoration_manager_handle_get_toplevel_decoration, XD:167-238 | Create decoration; unconfigured_buffer + already_constructed checks |
| getToplevelDecoration :168 | same, XD:167-238 | Ours: errors on the NEW decoration resource; refs on the manager resource (XD:181, XD:190) |
| decorationRequest.destroy :233 | toplevel_decoration_handle_destroy, XD:20-23 | Destroy decoration |
| decorationRequest.set_mode :234 | toplevel_decoration_handle_set_mode, XD:25-34 | Ours: invalid_mode for out-of-enum (XML-mandated); wlroots stores raw, no error; KWin maps unknown→Undefined (KWXD:92-104) |
| decorationRequest.unset_mode :244 | toplevel_decoration_handle_unset_mode, XD:36-43 | Clear preference, forward |
| emitRequestMode :250 | request_mode signal, XD:25-43 | Forward to compositor |
| decorationDestroy :258 | toplevel_decoration_handle_resource_destroy, XD:60-79 | Unlink, detach listener, free |
| onToplevelDestroy :276 | toplevel_decoration_handle_toplevel_destroy, XD:81-91 | Orphaned: post error. wlroots also destroys the resource (XD:89-91); ours leaves it (client dies on the error) |

## Findings

DD-1 (HIGH, STRUCTURAL) — No drag-and-drop.
Ours: deviceRequest.start_drag data_device.zig:356-377 = serial check + cancel source. wlroots: full state machine — drag_set_focus G:30-122 (enter/leave per client, drag offers), pointer grab G:182-277 (motion G:193-211, button→drop G:233-256), touch grab G:280-352, keyboard grab G:354-388, drag_drop G:213-231, icon role G:402-442, wlr_drag_create G:444-491, wlr_seat_start_pointer/touch_drag G:541-561; wlr_seat_request_start_drag G:492-508. smithay: StartDrag serial-vs-implicit-grab + DND_ICON_ROLE smDD:63-146. KWin: dragRequested → seat endDrag/cancelDrag KWS:190-268, updateDragTarget KWDD:238-301.
Missing: wl_data_device.enter/motion/leave/drop, wl_data_source.dnd_drop_performed/dnd_finished/action, drag icon surface role, pointer/touch/keyboard grabs, drag offers, dropped-flag offer retention, cancelled-vs-finished paths.
Why: DnD is a core protocol contract; every drag-capable client (GTK, Qt, foot) fails to drag at all.

DD-2 (HIGH, FIXABLE) — Actions validated but never negotiated or emitted.
Ours: source.set_actions stores mask data_device.zig:267-279; offer.set_actions validates data_device.zig:506-535; offer.accept no-op :477-480. Nothing computes a chosen action; source_actions/action events never sent; accept never forwarded as wl_data_source.target. wlroots: data_offer_choose_action O:22-55, data_offer_update_action O:57-76 (sends action to source + offer), accept O:78-92 (source->accepted + target), set_actions stores + updates O:155-189; source side dnd_action S:71-86, dnd_drop/finish S:59-76. smithay: handle_dnd smithay selection/data_device/mod.rs:259-347, default_action_chooser. KWin: chooseDndAction KWDD:184-218, action events KWOF:190-203.
Why: clients receive no action feedback; on a real drag the destination never learns the source's actions.

DD-3 (MED, FIXABLE-in-module) — Source not finalized at set_selection/start_drag.
Ours: DataSource has no finalized flag (data_device.zig:140-151); set_actions after set_selection is accepted and replaces the mask. wlroots: finalizes at set_selection D:34-37 and start_drag D:82-85; set_actions after finalize → invalid_action_mask S:173-178; offer after finalize logs S:199-204.
Why: a source re-used or re-actioned mid-selection violates the protocol's one-shot source model.

DD-4 (MED, FIXABLE-in-module) — set_selection serial model is stricter than wlroots and misses the superseded check.
Ours: rejects unless serial == seat.last_serial (data_device.zig:315-341). wlroots: per-client serial ring validation D:144-148 + superseded rejection (serial - selection_serial > UINT32_MAX/2) D:148-153; a recent-but-not-last serial still accepted. smithay: no serial check, focus gate smDD:147-183. KWin: ordering only KWS:308-317.
Why: multi-client input (even on one seat) can produce a valid selection serial that is not the last one; ours silently drops it. [INFERENCE: in the current single-client-input compositor this never triggers; it becomes observable once more than one client receives input serials.]

DD-5 (MED, FIXABLE-in-module) — set_actions on a clipboard offer never posts invalid_offer.
Ours: valid set_actions on a clipboard offer is silently accepted (no state change) data_device.zig:506-535. wlroots: posts WL_DATA_OFFER_ERROR_INVALID_OFFER after the mask/preferred checks O:178-182. smithay selection offers ignore set_actions (clipboard offers have no handler) — smithay parity, wlroots divergence.
Why: protocol error contract; clients that misuse set_actions on clipboard offers should be killed.

DD-6 (LOW, FIXABLE-in-module) — KWin rejects DnD-action sources in set_selection; ours accepts.
KWin: data_source with supportedDragAndDropActions or xdgToplevelDrag in set_selection → invalid_source error KWDD:91-101. Ours: any source accepted data_device.zig:315-354. wlroots: no such check.
Why: KWin-specific hardening; a source that advertised actions cannot be a clipboard source. Ecosystem parity only.

DD-7 (LOW, FIXABLE-in-module) — receive() does not validate the mime type.
Ours: relays any mime data_device.zig:481-495 (wlroots parity, S:106-112 / O:94-102). smithay: rejects mimes not offered, offer.rs:165-168.
Why: smithay hardening; source clients may misbehave on unknown mimes.

PS-1 (MED, FIXABLE-in-module) — Primary selection serial: not validated; module doc claims no reference validates it — false for wlroots.
Ours: set_selection ignores serial entirely (primary_selection.zig:316-377; doc :21-25). wlroots: wlr_seat_request_set_primary_selection validates serial + superseded (PS:54-62). smithay: focus-gated, serial ignored (smPS:72-92). KWin: ordering-only (KWS:319-333).
Why: the audit claim in the module doc is factually wrong about wlroots; behavior itself matches smithay. A stale-serial primary set is accepted by ours but rejected by wlroots. Focus gating (ours, smithay) is the alternative wlroots does not require.

PS-2 (LOW, FIXABLE-in-module) — Used-once enforced on success only; wlroots finalizes before the seat check.
Ours: finalized set only after the focus gate passes (primary_selection.zig:316-377). wlroots: finalizes in device_handle_set_selection before wlr_seat_request_set_primary_selection, PV1:213-216 — a rejected (stale-serial) set still burns the source.
Why: edge divergence; also smithay deliberately does NOT enforce used-once at all (smPS:70-75) — ours is stricter than smithay, matching wlroots.

PS-3 (LOW, FIXABLE-in-module) — Focus-change NULL delivery diverges from all three references.
Ours: sends selection(NULL) to the previous focused client on focus change (primary_selection.zig:399-415, XML: offer valid "until the client loses keyboard focus"). wlroots: only delivers to the new focused client; old offers linger until the next selection change (PV1:276-283, TODO comment PV1:279-280). smithay: focus swap re-offers new client only (smSD:80-90). KWin: destroys old offers, no explicit NULL (KWS:1227-1243).
Why: ours is the XML-literal behavior and strictly safer; divergence from ecosystem behavior (clients see selection(NULL) where GTK/KWin clients would not).

XA-1 (MED, FIXABLE-in-module) — No new_token event / compositor token-creation hook.
Ours: commit validates internally and emits nothing besides done() (xdg_activation.zig:270-316). wlroots: events.new_token at successful commit XA:141. smithay: token_created handler (smXA:104-120, mod.rs:254-258). KWin: creator callback (KWXA:96-104).
Why: compositor cannot observe or veto token creation; needed for app-id allowlists and telemetry.

XA-2 (MED, FIXABLE-in-module) — Surface destroy before commit invalidates the token; wlroots drops the constraint.
Ours: set_surface stores a raw resource (xdg_activation.zig:244-250); if the surface dies, surfaceForResource returns null at commit → token invalid → done() with an unusable token (tokenValid :323-327). wlroots: surface-destroy listener nulls token->surface (XA:202-208); at commit the check `token->surface != NULL && ...` is skipped (XA:109-114) → token stays valid.
Why: a client that created the token from a surface it then destroyed gets a dead token from us, a live one from wlroots.

XA-3 (MED, FIXABLE-in-module) — No compositor-side external-token API.
Ours: no way to inject a token (e.g. launching an app with activation). wlroots: wlr_xdg_activation_v1_add_token XA:422-435, find_token XA:406-415, get_name XA:417-420. smithay: create_external_token (mod.rs:199-206). KWin: setActivationTokenCreator (KWXA:132-138).
Why: portal-style activation (xdg-desktop-portal uses external tokens) cannot be implemented.

XA-4 (LOW, FIXABLE-in-module) — Token RNG is not a CSPRNG.
Ours: Xoshiro256 seeded from monotonic clock + counter (xdg_activation.zig:361-372; [INFERENCE] comment in code). wlroots: getrandom (util/token.h). Predictable tokens → spoofable activation.
Why: a malicious client could guess another client's pending token and trigger activation; low practical risk in a single-user compositor, but the reference uses getrandom.

XA-5 (LOW, FIXABLE-in-module) — set_serial ignores the seat argument.
Ours: stores the serial, drops the seat resource (xdg_activation.zig:224-231). wlroots: verifies the seat resource maps to a live seat, else rejects (XA:186-199). Single-seat server makes this unreachable today.
Why: inert-seat handling divergence; only observable with a bogus seat object.

XD-1 (HIGH, NEEDS-wiring) — Decoration configure is not synchronized with the xdg_surface configure/ack cycle.
Ours: sendConfigure fires the zxdg_toplevel_decoration_v1.configure event standalone, immediately on request_mode (xdg_decoration.zig:63-65; main.zig:879-897). No initial configure, no pending/current/scheduled mode, no ack handling. XML: set_mode "the compositor will respond by emitting an xdg_surface.configure event" (protocols/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml:132-136). wlroots: wlr_xdg_toplevel_decoration_v1_set_mode schedules a surface configure XD:52-58; mode sent during the configure cycle XD:93-113; ack moves pending→current XD:115-146. smithay: decoration_mode in the toplevel pending state, sent with send_configure, initial configure always carries the mode (smXDM:1490-1549). KWin: configureXdgDecoration + scheduleConfigure; mode carried in the configure event, applied on ack (KWSW:1574-1588, 690-723).
Why: clients drawing server-side decoration must render the new mode only after acking the matching xdg_surface.configure; standalone decoration configure events race the toplevel resize configure and can apply a mode to a stale frame.

XD-2 (LOW, FIXABLE-in-module) — Protocol errors posted on the new decoration resource; references post on the manager.
Ours: unconfigured_buffer/already_constructed on the fresh decoration resource (xdg_decoration.zig:165-197). wlroots: on the manager resource (XD:181, XD:190). smithay: on the manager (smXD:229-243). KWin: on the manager (KWXD:54-65).
Why: same client, same error code; only the object id in the error differs. Clients read code + interface, not the id.

XD-3 (LOW, FIXABLE-in-module) — invalid_mode enforcement diverges from every reference (deliberate).
Ours: posts invalid_mode=3 for out-of-enum set_mode (xdg_decoration.zig:234-241), per XML (xdg-decoration-unstable-v1.xml:146-147). wlroots: stores raw enum, no error (XD:25-34). smithay: WEnum::Unknown ignored (smXD:280-284). KWin: unknown→Undefined (KWXD:92-104).
Why: spec-literal but ecosystem-divergent; clients in the wild send only 1/2, so no practical break. Revisit if a toolkit sends 0 (client_side is 1; 0 = unset enum value) — GTK does not.

XD-4 (LOW, FIXABLE-in-module) — Orphaned path does not destroy the decoration resource.
Ours: posts orphaned, keeps the resource (xdg_decoration.zig:276-282); client dies on the error and teardown frees it. wlroots: posts orphaned AND destroys the resource (XD:81-91).
Why: observable only through a NULL-implementation handler risk after the error; posting an error kills the client in both cases. Behavioral parity in practice.

## Fixability classification

| Finding | Class | Note |
|---|---|---|
| DD-1 DnD state machine | STRUCTURAL | Requires seat grabs (pointer/touch/keyboard), drag icon role, per-drag offers, source dnd callbacks; touches seat.zig + compositor.zig + data_device.zig |
| DD-2 action negotiation | FIXABLE | Store offer actions, compute choose_action, emit source_actions/action; only needs data_device.zig + a compositor decision hook |
| DD-3 source finalize | FIXABLE-in-module | Add finalized flag + set_actions/offer guards in data_device.zig |
| DD-4 serial model | FIXABLE-in-module | Add superseded window; per-client ring needs seat.zig (upgrade to NEEDS-wiring) |
| DD-5 invalid_offer | FIXABLE-in-module | Add drag-offer type check |
| DD-6/DD-7 KWin/smithay hardening | FIXABLE-in-module | Local checks |
| PS-1 serial validation | FIXABLE-in-module | Add serial==last_serial or superseded check; fix module doc claim |
| PS-2 finalize order | FIXABLE-in-module | Move finalize before the gate (matches wlroots) |
| PS-3 focus-change NULL | FIXABLE-in-module | Keep or drop; deliberate XML-literal choice |
| XA-1 new_token event | FIXABLE-in-module | Add wire.Signal emit at commit |
| XA-2 surface-destroy listener | FIXABLE-in-module | Add destroy listener to null surface_res |
| XA-3 external token API | FIXABLE-in-module | pub fn add/find/get_name + timer wiring |
| XA-4 CSPRNG | FIXABLE-in-module | getrandom via libc |
| XA-5 seat arg | FIXABLE-in-module | Validate seat resource |
| XD-1 configure sync | NEEDS-wiring | Requires xdg.zig to expose configure/ack_configure signals (or a decoration-mode field on XdgToplevel carried in configure()); xdg.zig:300-302 has only events.destroy today |
| XD-2 error resource | FIXABLE-in-module | Post on manager_res |
| XD-3 invalid_mode | FIXABLE-in-module | Keep (spec) or drop (ecosystem) — decision |
| XD-4 orphaned destroy | FIXABLE-in-module | Destroy resource after posting |

## OK areas (parity confirmed)

- Selection storage is seat-wide, not per-device (data_device.zig:71-81, 410-470; D:184-215; smSD:11-18). Prior per-device bug fixed.
- Offer lifecycle: destroyed on re-delivery, focus move, source death; inerted wire resources; no dangling source deref (data_device.zig:410-470, 574-589; D:125-143; O:230-236; primary_selection.zig:420-553; PV1:53-96).
- Event ordering data_offer → mimes → selection matches wlroots/KWin on both modules (data_device.zig:458-464; D:105-123; primary_selection.zig:445-452; PV1:69-80; KWP:69-81).
- Bind-time delivery for a focused client's new device (data_device.zig:240-244; D:247-249; primary_selection.zig:240-249; PV1:421-424; KWS:159-177, 291-301).
- Device destroy keeps the seat selection (data_device.zig:383-395; D:100-103; smDD:199-209; primary_selection.zig:383-396; PV1:234-237).
- Source death clears the selection, re-delivers NULL, inert offers (data_device.zig:284-303; D:167-182; primary_selection.zig:285-303; PV1:110-121).
- offer.finish invalid_finish on clipboard offers (data_device.zig:498-504; O:123-153). smithay clipboard offers ignore finish (parity via different rule).
- Source set_actions mask validation (data_device.zig:267-279; S:152-182) and offer set_actions mask/preferred/source-support validation (data_device.zig:506-535; O:155-189), including invalid_action for unsupported preferred.
- Primary selection used-once (primary_selection.zig:161-171, 335-345; PV1:213-216), mime dedup (:259-283; PV1:133-167).
- xdg_activation one-shot commit + already_used (xdg_activation.zig:224-254, 270-275; XA:93-149; smXA:49-98), validation-at-commit with done() carrying a useless token on failure (:281-285; XA:149-157), 30 s expiry (:292-302, 335-339; XA:46-51, 63-91), single-use activate (:171-192; XA:292-321), unknown token ignored (:172-175; XA:310-317), surface must be kbd/pointer focused (:323-327; XA:109-114).
- xdg_decoration unconfigured_buffer (v1 rule) + already_constructed (xdg_decoration.zig:179-197; XD:174-192), orphaned via toplevel destroy listener (xdg_decoration.zig:276-282; XD:81-91), toplevel null-invariant in destroy paths (:258-274).

## [INFERENCE]

- smithay/KWin line citations taken from the checked-out trees at ~/projects/github-Smithay-smithay and ~/projects/invent-kde-org-plasma-kwin as of this audit; they are the reference revisions the audit brief names (v0.7.0 / master) but no tag verification was run (no git commands per constraints).
- DD-4 multi-client trigger ("becomes observable once more than one client receives input serials") is a reasoning claim; the current compositor delivers input to one focused client.
- wlroots getrandom claim (XA-4) is repeated from our own code comment; util/token.h was not re-read.
