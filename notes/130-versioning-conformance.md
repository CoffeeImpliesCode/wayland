# 130: Versioning conformance

Area: protocol version round (workers VF1 + VF2; three audits: wire, semantics, adversarial).
Files: src/screencopy.zig, src/compositor/data_device.zig (VF1); test additions in src/shell/xdg.zig, src/shell/layer_shell.zig, src/output/wl_output.zig (VF2). This note covers the whole round.
Ground truth: freedesktop-wayland-wayland/src/wayland-server.c + wayland-client.c; zig-wayland scanner (codeberg-ifreund-zig-wayland/src/scanner.zig); protocols/wayland/wayland.xml; protocols/wlroots/wlr-screencopy-unstable-v1.xml; generated bindings .zig-cache/o/*/wayland.zig; wlroots types/data_device/*.c.

## Enforcement model: three layers

1. libwayland gates REQUESTS. wayland-server.c:451-457: opcode >= method_count posts INVALID_METHOD. wayland-server.c:459-466: request since > bound resource version posts INVALID_METHOD and disconnects the client. Bind validation: registry_bind (wayland-server.c:1058-1095; INVALID_OBJECT posts at 1074-1088) rejects unavailable global, interface-name mismatch, version 0, or version > advertised. The compositor never clamps a client's requested bind version — it must NOT (the error is the contract; a clamp silently downgrades a client that asked for more).
2. Child-object versions are NOT gated. The wire carries only the object id; wl_closure_invoke passes the raw new_id (connection.c:1186-1193) and the handler must create the resource itself. Client-side the child proxy inherits the parent's bound version (wayland-client.c wl_proxy_marshal_array_constructor -> proxy->version, :789-797; create_proxies for event-introduced objects, :1515-1530). Server-side the version the compositor passes to create() is final — libwayland never checks it against the parent.
3. zig-wayland generates NO version logic. Server Request unions filter only at compile time (scanner.zig:692-695: request.since <= target_version); dispatcher `unreachable` is unreachable because every advertised version <= generated (build.zig:33-47 vs every addGlobal). sendXxx = bare postEvent (server binding, no version check) — callers MUST gate events via res.getVersion(). Client side the same: the listener dispatcher delivers any opcode present in the generated Event union (wayland.zig common.Dispatcher), and libwayland-client wl_closure_invoke aborts when the listener table has no slot for an opcode (wayland-client.c dispatch_event -> wl_closure_invoke; connection.c:1237-1241 "listener function for opcode ... is NULL"). An un-gated since>1 event is a client abort, not a warning.

## Fixed bugs

1. [HIGH] screencopy damage event leak (screencopy.zig:314).
   - damage is since 2 (wlr-screencopy-unstable-v1.xml:191); the frame inherits the manager's bound version (screencopy.zig:183), so a v1 manager client received a v1 frame plus the since-2 damage event -> v1 listener has no damage slot -> client abort.
   - Fix: `if (frame.getVersion() >= 2) frame.sendDamage(...)` (screencopy.zig:313-315). The existing buffer_done >=3 gate (screencopy.zig:204) stays.
   - Full event audit of wlr-screencopy-unstable-v1.xml: buffer since 1 (always), flags since 1, ready since 1, failed since 1 (the no-framebuffer frames are created at version 1, screencopy.zig:148,175 — failed is since 1, safe), damage since 2 (now gated), linux_dmabuf since 3 (never sent: shm-only), buffer_done since 3 (gated). damage was the ONLY missing gate.
2. [MED-HIGH] data_device child versions hardcoded to 3 (data_device.zig:186, 215).
   - create_data_source and get_data_device created children at version 3 for every manager binding. libwayland never gates child versions, so a v1 manager client's v3 source/device accepted since-3 requests (finish, set_actions) the client never agreed to.
   - Fix: children now inherit the manager's bound version — `resource.getVersion()` (data_device.zig:186, 215), matching wlroots (client_data_source_create + data_device_manager_get_data_device, wlr_data_device.c:232-234, 259).
   - The selection offer was the same bug class: it is introduced in a data_device event, so its version follows the device's (wlroots: data_offer_create uses wl_resource_get_version(device_resource), wlr_data_offer.c:249-251). Fixed at data_device.zig:434 (`dev.resource.getVersion()`).

## Gate inventory (complete, audit-verified)

- wl_output sendState (wl_output.zig:78-103): geometry/mode since 1; scale >=2; name/description >=4; done >=2. Correct.
- wl_seat: pointer.frame >=5 (seat.zig:350,547); seat.name >=2 (seat.zig:1000); keyboard.repeat_info >=4 (seat.zig:1021); capabilities since 1 (always, seat.zig:999). Correct.
- screencopy: buffer_done >=3 (screencopy.zig:204); damage >=2 (screencopy.zig:313-315, fixed). Correct now.
- layer_shell keyboard_interactivity v<4 bool coercion (layer_shell.zig:345-352): v<4 maps any nonzero to exclusive (on_demand does not exist there); v>=4 validates the enum range. Correct.

## Decisions (recorded)

- wl_seat advertises v10 (seat.zig:56; build.zig:35 generates to 11) — bumped from
  v7 on 2026-08-10 (note 132 F4). Deliberate cap at 10, not 11: v10 exposes
  axis_value120 (wl_pointer v8), axis_relative_direction (v9) and the
  key_state.repeated pseudo-state (wl_keyboard v10) while keeping the dead-touch
  protection intact. Touch exists in the generated wire but not in the capability
  set; the v10 cap means a touch client binding at ≤10 still hits libwayland's
  request gating on the dead wl_touch (release is since 3, reachable at any
  advertised version ≥ 3 — the dead-object path at seat.zig:556-567 plus
  MISSING_CAPABILITY-free inert creation is the protection). A future touch
  feature must bump BOTH the advertisement (seat_version) AND the touch-capability
  coupling (sendCapabilities, seat.zig:495). Advertising 11 without the capability
  would not add touch events; the cap at 10 is the KWin parity point
  (KWin seat.cpp:30) with no wire surface above it in use.
- wl_seat.get_touch is since 1 (wayland.xml wl_seat; generated get_touch_since_version=1), so it IS reachable at v1. The seat's dead-object path (seat.zig:556-563: create a wl_touch at the seat's version, no events) plus libwayland's request gating (wl_touch.release is since 3) is the actual protection. The earlier audit's "unreachable at v1" framing was wrong; no code change needed.
- zxdg_decoration_manager_v1 advertises v1 (xdg_decoration.zig:112-117, generated_version=1) with v1 semantics (unconfigured_buffer at get). A v2-capable client clamps to v1; the generated target version is 1, so no v2 wire exists here at all.
- xdg_wm_base, wl_compositor, zwlr_layer_shell_v1, zwlr_screencopy_manager_v1, wl_data_device_manager, wl_output advertise exactly their generated versions. presentation_version = generated (presentation.zig:63).

## Dead code: do NOT add request-side "guards"

An earlier audit proposed gating request handlers by resource version. Dead code: libwayland already rejects out-of-version requests with INVALID_METHOD + disconnect before any handler runs (wayland-server.c:459-465), so a `getVersion() >= since` check inside a handler is unreachable and misleading. Do not add them.

## Tests

- screencopy.zig:587 "v1 manager: frame gets buffer/flags/ready but never damage or buffer_done": manager bound at v1; capture -> buffer arrives, buffer_done absent; copy -> flags+ready arrive, damage absent (fails pre-fix: damage_count becomes 1).
- screencopy.zig:615 "v3 manager: damage and buffer_done arrive": manager bound at 3; damage + buffer_done + flags + ready all arrive.
- data_device.zig:1105 "v1 manager creates v1 children": manager bound at v1; server-side source/device resources report version 1.
- data_device.zig:1124 "v3 manager creates v3 children": default bind (3); server-side children report version 3.
- VF2: legacy-version tests in xdg.zig, layer_shell.zig, wl_output.zig (see VF2's report).
- Harness pattern: TestServer wire roundtrip (initAtVersion + ts.pump + wl_display_get_protocol_error), same as xdg.zig / data_device.zig existing suites.
