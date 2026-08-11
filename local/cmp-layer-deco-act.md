# cmp-layer-deco-act — layer-shell + xdg-decoration + xdg-activation (adversarial)

Audit date 2026-08-11. Ours: src/shell/layer_shell.zig (v5), src/shell/xdg_decoration.zig (v1), src/shell/xdg_activation.zig (v1). Refs: wlroots types/wlr_layer_shell_v1.c, types/wlr_xdg_decoration_v1.c, types/wlr_xdg_activation_v1.c (0.20.2); smithay src/wayland/shell/wlr_layer/{mod,handlers}.rs, shell/xdg/decoration.rs, xdg_activation/{mod,dispatch}.rs (v0.7.0); KWin src/wayland/{layershell_v1,xdgdecoration_v1,xdgactivation_v1}.cpp (master). Ground truth XML in protocols/wayland-protocols. Extends notes/133 + notes/129 adversarially.

## 1. Implemented surface
- zwlr_layer_shell_v1 (v5) + zwlr_layer_surface_v1 role: src/shell/layer_shell.zig (`LayerShell` global :98, `LayerSurface` role :234, role hooks :611-690). Version from build.zig:43.
- zxdg_decoration_manager_v1 (v1) + zxdg_toplevel_decoration_v1: src/shell/xdg_decoration.zig (`XdgDecoration` global :139, `Decoration` :67). Version from build.zig:41 (deliberately v1, not the XML's v2).
- xdg_activation_v1 (v1) + xdg_activation_token_v1: src/shell/xdg_activation.zig (`XdgActivation` global :89, `ActivationToken` :189). Version from build.zig:40.

## 2. API breadth table
Version we advertise / version each reference advertises:
|interface|ours|wlroots|smithay|KWin|
|---|---|---|---|---|
|zwlr_layer_shell_v1|5 (build.zig:43)|5 (LAYER_SHELL_VERSION, wlr_layer_shell_v1.c:19)|5 (wlr_layer/mod.rs create_global 5)|5 (layershell_v1.cpp:24)|
|zxdg_decoration_manager_v1|1 (build.zig:41)|1 (wlr_xdg_decoration_v1.c:19)|1 (decoration.rs create_global 1)|2 (xdgdecoration_v1.cpp:47; XML interface is v2)|
|xdg_activation_v1|1 (build.zig:40)|1 (wlr_xdg_activation_v1.c:6)|1 (xdg_activation/mod.rs create_global 1)|1 (xdgactivation_v1.cpp:23)|

Wire requests/events (all present in ours — breadth is complete for the advertised versions):
|interface|ours|refs|
|---|---|---|
|zwlr_layer_surface_v1 requests|destroy, set_size, set_anchor, set_exclusive_zone, set_margin, set_keyboard_interactivity, get_popup, ack_configure, set_layer, set_exclusive_edge (all 10; layer_shell.zig:381-451)|identical (wlr_layer_shell_v1.c:306-321; smithay handlers.rs; KWin layershell_v1.cpp)|
|zwlr_layer_surface_v1 events|configure, closed (sendConfigure :273, close :413)|identical|
|zwlr_layer_shell_v1 requests|get_layer_surface, destroy|identical|
|zxdg_decoration_manager_v1 requests|get_toplevel_decoration, destroy|identical|
|zxdg_toplevel_decoration_v1 requests|destroy, set_mode, unset_mode (xdg_decoration.zig:274-296)|identical|
|zxdg_toplevel_decoration_v1 events|configure (sent on xdg configure emission, :363-379)|identical|
|xdg_activation_v1 requests|destroy, get_activation_token, activate|identical|
|xdg_activation_token_v1 requests|set_serial, set_app_id, set_surface, commit, destroy|identical|
|xdg_activation_token_v1 events|done|identical|

Compositor-facing SIGNAL breadth (the real gaps):
|signal|ours|wlroots|smithay|KWin|
|---|---|---|---|---|
|layer new_surface|yes (layer_shell.zig:81)|yes|yes (new_layer_surface)|yes (surfaceCreated)|
|layer new_popup (get_popup)|NO|yes (wlr_layer_shell_v1.c:254)|yes (new_popup, handlers.rs:272-295)|yes (attachTo)|
|decoration new_toplevel_decoration|NO (only request_mode, xdg_decoration.zig:128-130)|yes (wlr_xdg_decoration_v1.c:299,406)|yes (new_decoration, decoration.rs:174,242)|yes (decorationCreated, xdgdecoration_v1.cpp:44)|
|activation request_activate|yes|yes|yes|yes|
|activation new_token|yes (commit-only)|yes (commit-only)|yes (token_created on EVERY commit)|via creator callback|

## 3. Adversarial correctness findings
L1 [MAJOR] get_popup parents a popup but emits NO `new_popup` signal. Ours getPopup (layer_shell.zig:455-486) sets layer_parent, tracks popup, dismisses on reset, but fires no compositor hook. wlroots emits events.new_popup (wlr_layer_shell_v1.c:254); smithay calls WlrLayerShellHandler::new_popup (handlers.rs:272-295); KWin attachTo. Consequence: the compositor is never told a layer popup was created, so it cannot position/render it (compounds unresolved F12 popup-offset gap) — layer-shell popups (panel menus, notification popups) are unrenderable. L1 partial from note 133.

L2 [MAJOR] No `new_toplevel_decoration` signal ⇒ decoration negotiation is one-directional. XdgDecoration.events has only request_mode (xdg_decoration.zig:128-130); getToplevelDecoration (:225-320) emits nothing on creation. wlroots events.new_toplevel_decoration (wlr_xdg_decoration_v1.c:299,406); smithay new_decoration handler (decoration.rs:174,242); KWin decorationCreated (xdgdecoration_v1.cpp:44). Consequence: the compositor can only reply to a client's set_mode (main.zig:617 request_mode → sendConfigure). It can never announce a compositor-decided initial mode, so a server-side-only decoration policy (client that never sends set_mode keeps drawing client chrome) is unreachable. All three references expose the creation hook.

L3 [MINOR] `close()` destroys the wire resource; wlroots inerts it. Ours close (layer_shell.zig:413-418) sends closed then `ls.resource.destroy()`. wlroots wlr_layer_surface_v1_destroy sends closed then makes the resource inert via wl_resource_set_user_data(resource, NULL) (wlr_layer_shell_v1.c:337-341, 48-49), leaving it alive for the client to destroy. Consequence: after closed, a well-behaved client's subsequent `destroy` targets a server-side-dead object on ours; on wlroots/smithay/KWin it is a normal client destructor. Low practical impact today (main.zig never closes a layer surface).

L4 [MINOR] set_size > INT32_MAX posts a wire error -1 on the surface resource; wlroots posts a client-level implementation error. Ours (layer_shell.zig:388-396) raw -1. wlroots wl_client_post_implementation_error (wlr_layer_shell_v1.c:128-151). Both terminate the client; error code/location differ (ours is observable via wl_display_get_protocol_error, wlroots is server-side only).

L5 [MINOR] get_layer_surface rejects a same-role re-assignment on one wl_surface; wlroots/KWin allow it. Ours treats ANY pre-existing role as conflict (role error, layer_shell.zig:168-177). wlroots wlr_surface_set_role allows re-assigning the layer role (wlr_layer_shell_v1.c:481-488); KWin allows same role (layershell_v1.cpp:96-103). Ours deliberately stricter (note 129 #4). Real clients don't create two layer surfaces on one wl_surface.

L6 [INFO] Initial configure is module-auto with fallback = output size; refs are compositor-driven. Ours sends configure from the commit hook (layerSurfaceCommit :655-663, sendConfigure :273) substituting ls.fallback (output size) for any 0-desired dimension (L2 of note 133). wlroots never self-configures; the compositor calls wlr_layer_surface_v1_configure on new_surface/arrange (asserts initialized, wlr_layer_shell_v1.c:316-336); smithay/KWin same. Consequence: ours always emits a configure (synchronously in the commit dispatch) even if the compositor's real layout would assign a different size, and no arrange hook exists, so layer surfaces always get desired-or-output sizing. Known divergence, not new; noted adversarially.

L7 [INFO] Keyboard-interactivity focus policy not consumed. ours stores current.keyboard_interactive (layer_shell.zig:432-444, current copied :614) but main.zig has no layer keyboard-focus routing (documented out of scope, layer_shell.zig:24-27). wlroots also only stores; focus is compositor policy. Not a wire divergence; a functional/policy gap for EXCLUSIVE/ON_DEMAND layer surfaces.

D1 [MAJOR] No `new_toplevel_decoration` signal (see L2 — the decoration-area headline). One-directional mode negotiation.

D2 [MINOR] Ours raises invalid_mode=3; wlroots/smithay/KWin do not. Ours set_mode (xdg_decoration.zig:278-285) posts invalid_mode for mode ∉ {client_side, server_side}. wlroots stores requested_mode and emits request_mode with no validation (wlr_xdg_decoration_v1.c:49-58); smithay only dispatches WEnum::Value (decoration.rs:312-318); KWin maps to Mode::Undefined (xdgdecoration_v1.cpp:68-89). The XML explicitly mandates invalid_mode ("If an invalid mode is supplied... invalid_mode protocol error is raised", xdg-decoration-unstable-v1.xml), so ours is XML-correct and the references are the lax ones. Adversarial consequence: a client sending mode=3 survives on all three references but is killed by ours. Real toolkits never send 3, so low practical risk; ours is defensible (documented deliberate divergence).

D3 [MINOR] Decoration advertised at v1, not v2 (KWin has v2). build.zig:41 generates 1; wlroots DECORATION_MANAGER_VERSION 1 (wlr_xdg_decoration_v1.c:19); smithay global 1 (decoration.rs); KWin init(*display, 2) (xdgdecoration_v1.cpp:47), matching the XML interface version 2 (xdg-decoration-unstable-v1.xml). Consequence: the v2 relaxation — allowing a decoration on a toplevel that already committed a buffer (and the "mode retained across decoration re-create" rule) — is unavailable to our clients. Ours enforcing unconfigured_buffer matches wlroots/smithay (v1 strict). Breadth gap only vs KWin; not a correctness bug (v1 is coherent).

D4 [INFO] Orphaned-at-creation handled more safely than wlroots. Ours getToplevelDecoration checks toplevel_res.getUserData() orelse → post orphaned + destroy (xdg_decoration.zig:231-237). wlroots doesn't check at creation (would deref a freed toplevel via wlr_xdg_toplevel_from_resource); smithay checks alive_tracker (decoration.rs:227-231), KWin checks toplevelPrivate (xdgdecoration_v1.cpp:27-31). Ours matches smithay/KWin; strictly safer than wlroots. Positive divergence.

D5 [INFO] request_mode/unset_mode folded into one signal carrying mode:?Mode (null=unset). Ours (xdg_decoration.zig:296-305). wlroots emits request_mode for both (requested_mode field distinguishes); smithay has separate request_mode/unset_mode callbacks (decoration.rs:174-178). Equivalent for the compositor. No finding beyond shape.

A1 [MINOR] Surface-focus check enforced even when no seat/serial was set; wlroots gates it behind set_serial. Ours tokenValid checks keyboard_focus/pointer_focus == surface whenever a surface is set (xdg_activation.zig:494-514), independent of the serial. wlroots only checks focus inside `if (token->seat != NULL)` (wlr_xdg_activation_v1.c:155-164). Consequence: a client that sets only set_surface(X) (no set_serial/seat) gets its token dropped on ours unless X is currently focused; wlroots accepts it. Both are permitted compositor policy per XML (set_surface "some compositors might refuse...", xdg-activation-v1.xml), ours stricter. Breaks the legit launcher set-surface-no-serial flow that works on wlroots. Common set_serial flow behaves identically on both.

A2 [MINOR] On activate(), ours destroys the creating client's wire resource; wlroots leaves it inert. Ours activationActivate (xdg_activation.zig:282-306) calls res.destroy() on the token's wire resource after delivery. wlroots makes the resource inert at commit and activate only frees the object (wlr_xdg_activation_v1.c:383-388), leaving the inert resource alive for the creator to destroy. In the cross-client flow (launcher B activates a token committed by client A), ours destroys A's object server-side; a later A-side destroy/use targets a dead id. Minor (typical clients abandon the token after forwarding).

A3 [INFO] post-commit already_used handled via a `committed` flag, not resource inertness. Ours keeps the resource live guarded by token.committed (xdg_activation.zig:300-380). wlroots inerts the resource at commit (user_data=NULL) and token_from_resource returns NULL → same already_used. Functionally equivalent error behavior for post-commit setters. Info.

A4 [INFO] new_token fires on successful commit only (matches wlroots); smithay calls token_created for EVERY commit, deferring validity to the compositor. Ours emits new_token before done() only on valid commit (xdg_activation.zig:240-258), matching wlroots (wlr_xdg_activation_v1.c:180-182). smithay invokes XdgActivationHandler::token_created before any validity decision and lets the handler reject (dispatch.rs:151-161). Design difference in smithay, not an ours bug. Info.

A5 [INFO] KWin performs no server-side token registry/validation at all. KWin activate just emits activateRequested(surface, token) (xdgactivation_v1.cpp:96-99); commit calls the compositor creator callback and always sends done (xdgactivation_v1.cpp:50-62). wlroots/ours validate serial+focus internally and drop invalid tokens. Ours matches wlroots. Info (policy difference in KWin).

## 4. Verdict
Breadth: all wire requests/events for the three protocols are implemented at the advertised versions (layer v5, decoration v1, activation v1) — request/event surface is complete. Two compositor-facing SIGNALS are missing that all three references provide: layer-shell `new_popup` (L1) and xdg-decoration `new_toplevel_decoration` (L2/D1). Both are MAJOR because they make two real consumption paths unreachable (layer popup anchoring; compositor-initiated decoration mode). The decoration version is v1 (matching wlroots/smithay; behind KWin's v2).

Correctness: no spec-violating wire errors found in the common paths; the configure/ack state machines (layer and decoration-via-xdg) match wlroots closely. The 14 findings are: 2 MAJOR (missing signals L1, L2), 7 MINOR, 5 INFO. The MINORs are mostly deliberate or low-impact strictness (invalid_mode XML-correct but stricter than all refs; focus-check gating; resource-destroy-vs-inert; INT32_MAX error location; same-role rejection; v1-vs-v2). The surface-focus gating (A1) is the only MINOR that rejects a flow wlroots accepts. Net: implementation is faithful to wlroots 0.20.2 for these three protocols; the adversarial exposure is concentrated in the missing compositor hooks (L1/L2) and in strictness choices that kill edge-case clients the references tolerate.
