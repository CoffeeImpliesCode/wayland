# 129 — layer-shell v5 implementation (zwlr_layer_shell_v1)

Scope: NEW module `src/shell/layer_shell.zig` (907 lines) implementing the
LayerShellV1 state machine; wiring in `src/server/main.zig` + `src/root.zig`.
Reference: wlroots 0.20.2 `types/wlr_layer_shell_v1.c` (clone
`~/projects/freedesktop-wlroots-wlroots`, read-only), protocol XML
`protocols/wlroots/wlr-layer-shell-unstable-v1.xml`. All citations below are
relative to the repo root unless noted.

## What was built

- `LayerShell` global: `src/shell/layer_shell.zig:64-133`. `init` mirrors
  xdg.zig (heap struct, `display.addGlobal(server.zwlr.LayerShellV1, …,
  generated_version=5, …)`, `events.new_layer_surface` signal). `deinit`
  destroys live layer-surface resources first (cascades through the wire
  destroy handlers).
- `LayerSurface` role object: `:234-380`. State: namespace (owned), output
  (raw wire pointer, `:245`), `configured` / `configure_sent` /
  `configure_serial` / `sent_serials` (ack validation list), double-buffered
  `pending`/`current` `LayerState` (`:216-232`: desired size, anchor bits,
  exclusive zone, exclusive edge, margin, keyboard interactivity, layer).
- Role implementation `layer_surface_role`: `:524-533` — `client_commit`
  (`:465-503`), `commit` (`:505-522`), `destroy` (`:523` referenced fn
  `:430-450`). Recovered from the surface via `layerFromSurface`
  (`:457-463`, role_resource user data — xdg.zig pattern).

## State machine (per wlroots types/wlr_layer_shell_v1.c)

1. `get_layer_surface` (`:140-191`): validate layer (0-3) else
   `invalid_layer` (1) on the shell resource (wlroots order, wlr_layer_shell_v1.c:455-462);
   assign the `zwlr_layer_surface_v1` role via `role_mod.assignRole`.
   Any pre-existing role posts the shell error `role` (0) on the shell
   resource and drops the object (`:178-184`) — the layer-surface error enum
   has no `role` member; wlroots posts code 0 on the creating resource
   (wlr_layer_shell_v1.c:481-488).
2. First commit MUST be buffer-less: a commit with a buffer while never
   configured posts `already_constructed` (2) on the layer surface
   (`:478-487`). Code comes from the SHELL error enum (surface enum has no
   such member); wlroots posts it on the layer-surface resource
   (wlr_layer_shell_v1.c:300-308).
3. After the first buffer-less commit the module sends the initial
   configure(serial, desired_width, desired_height) (`:505-519`,
   `sendConfigure` `:270-287`). Width/height = the last `set_size`, else 0,0
   (client decides). THIS IS A DIVERGENCE FROM WLROOTS: wlroots never sends
   the initial configure itself — the compositor (sway) calls
   `wlr_layer_surface_v1_configure` on `new_surface`/arrange
   (wlr_layer_shell_v1.c:348-367). The task spec mandates the self-contained
   module behavior ("After the bufferless commit, send configure"), so the
   initial configure is emitted here.
4. `invalid_size` (1) at EVERY commit: desired width 0 without BOTH
   left|right anchors, or height 0 without BOTH top|bottom
   (`:488-499`) — wlr_layer_shell_v1.c:310-333 (`(anchor & horiz) != horiz`).
   Consequence: the initial buffer-less commit also fails when size is 0,0
   without opposing anchors — matching wlroots; tests set all four anchors
   for the happy path.
5. `ack_configure` (`:308-321`): serial must be in `sent_serials`, else
   `invalid_surface_state` (0). The ack removes the serial and every older
   one (wlroots configure-list prune, wlr_layer_shell_v1.c:69-100). Sets
   `configured`; buffer commits then map (compositor pipeline does the
   map/unmap transition).
6. NULL-buffer commit = unmap + RESET (`:505-519`, `reset` `:302-306`):
   `configured=false`, `configure_sent=false`, serials cleared. A fresh
   buffer-less commit + configure + ack are required to map again
   (wlroots `layer_surface_reset`, wlr_layer_shell_v1.c:33-52).
7. destroy request → `close()` (`:322-331`): send `closed` first, then
   destroy the resource (inert; requests after are gone). Idempotent;
   compositor-side close uses the same API.
8. `set_anchor`: validate bits ⊆ {1,2,4,8} else `invalid_anchor` (2)
   (`:390-396`). `set_exclusive_edge` (v5): SINGLE bit only else
   `invalid_exclusive_edge` (4) at set time (`:415-424`) AND
   `(anchor & edge) != edge` at commit (`:500-503`). wlroots validates any
   subset via `anchor_is_valid` (wlr_layer_shell_v1.c:283-290) — the task
   spec's single-bit rule is stricter; followed the spec.
9. `set_keyboard_interactivity` (`:341-354`): v4+ validates the enum
   (0..2) else `invalid_keyboard_interactivity` (3); v3 resources coerce
   nonzero→1 (wlroots `!!interactive`, wlr_layer_shell_v1.c:223-238).
10. `set_layer` (`:405-413`): invalid layer → `invalid_layer` (1) posted on
    the SHELL resource (XML home). wlroots posts it on the surface resource
    with an XXX comment (wlr_layer_shell_v1.c:253-274); the task spec chose
    the shell resource.
11. `get_popup` (`:358-367`): rejected with wlroots' raw -1 implementation
    error (`wl_resource_post_error(resource, -1, …)`,
    wlr_layer_shell_v1.c:240-251) — popup parenting is M4 for the popup
    module (xdg.zig XdgPopup.parent comment). No popup object is created.

## exclusiveEdge helper

`exclusiveEdge` (`:334-336`) → pure `deducedEdge(zone, anchor, exclusive_edge)`
(`:369-382`): zone <= 0 → null (ignores explicit edge — wlroots order,
wlr_layer_shell_v1.c:641-642); else single anchor edge, or edge plus both
perpendicular edges, with `set_exclusive_edge` overriding the deduction
(wlr_layer_shell_v1.c:643-671). Returns `Edge` enum {top,bottom,left,right}.
Note: the task spec's parenthetical "zone<=0: none unless set_exclusive_edge"
does NOT match wlroots (zone<=0 is always none); wlroots behavior implemented.

## Wiring

- `src/root.zig:70-72` export `pub const layer_shell = @import("shell/layer_shell.zig");`
  + `_ = layer_shell;` in the comptime analysis block (`:102`).
- `src/server/main.zig`:
  - ServerState fields: `layer_shell` (`:148-149`), `layer_surfaces` list
    (`:218`), `new_layer_surface_listener` (`:299`).
  - init/defer after the XdgShell block (`:364-366`).
  - state literal (`:480`, `:500`, `:506`), `defer state.layer_surfaces.deinit`
    (`:514`), listener wiring (`:530`).
  - `onNewLayerSurface` (`:807-816`): mirrors `onNewToplevel` — appends to
    `layer_surfaces`, logs namespace/layer. Compositing needs no extra wiring:
    layer surfaces reach the scene through the shared `surface_entries` path
    (`syncSurfaces`/`updateSurfaceNode` key every compositor surface,
    main.zig:1381-1429). No initial configure is sent here (see item 3).

## Tests (in-file, wire-level TestServer + socketpair)

- `test "layer exclusive edge deduction"` (`:537-551`).
- `test "layer surface: buffer before first configure is already_constructed"`
  (`:722-739`) — real shm buffer commit before any configure → error code 2.
- `test "layer surface: zero size without opposing anchors is invalid_size"`
  (`:742-756`) — set_size(0,100), no anchors, buffer-less commit → code 1.
- `test "layer surface: acking a never-sent serial is invalid_surface_state"`
  (`:758-770`) — ack 12345 → code 0.
- `test "layer surface: invalid anchor bitfield is invalid_anchor"`
  (`:772-785`) — set_anchor(0x10) → code 2.
- `test "layer surface: invalid keyboard interactivity is invalid_keyboard_interactivity"`
  (`:787-800`) — value 3 → code 3.
- `test "layer surface: bufferless commit, configure, ack, buffer commit maps"`
  (`:802-848`) — happy path; asserts configure serial/0x0 size, `mapped`,
  `configured`, serials drained.
- `test "layer surface: NULL commit unmaps and resets; remap needs a fresh configure"`
  (`:850-906`) — unmap+reset state, fresh configure on remap (2nd configure),
  re-map, then buffer-without-fresh-configure → code 2 again.

Errors asserted via `wl_display_get_protocol_error` after
`ClientDispatchFailed` (xdg.zig pattern). The TestServer
(`:616-704`) inits `display.initShm()` (internal libwayland wl_shm global)
and binds wl_shm client-side; buffers resolve through the stateless
untracked path (surface.zig handleAttach:578-580). `createShmBuffer`
(`:706-720`): memfd + mmap + createPool + createBuffer(64x64 argb8888).

## Out of scope (documented in module header `:24-27`)

- Layer z-ordering / layout against an output (no arrange logic; wlroots
  leaves this to the compositor, sway's `arrange_layers`).
- Keyboard-focus policy (compositor-policy per task; not implemented).
- xdg_popup parenting (get_popup rejected, item 11).
- `output` in get_layer_surface is stored raw (`:245`); resolution to
  the Output object is policy (single-output world).

## Divergences from the task spec

1. Initial configure is sent by the MODULE on the first buffer-less commit
   (item 3), not eagerly from `onNewLayerSurface`. An eager configure would
   arrive before the protocol-mandated initial commit and duplicate the
   event (XML: "the client must perform an initial commit without any buffer
   attached. The compositor will reply with a layer_surface.configure
   event").
2. `exclusiveEdge` follows wlroots: zone <= 0 always returns none
   (task parenthetical "unless set_exclusive_edge" not implemented).
3. `set_exclusive_edge` validated as a single bit (task spec), stricter than
   wlroots' any-subset validation.
4. `get_layer_surface` on a surface that already has the layer role (a second
   layer surface on one wl_surface): rejected with `role` (0) and dropped.
   wlroots allows same-role re-assignment (wlr_layer_shell_v1.c:481-488);
   two layer surfaces on one wl_surface would double-hook its commits, so
   any pre-existing role is treated as a conflict.
5. No `geometry` field on LayerSurface: layout geometry is compositor policy
   (out of scope); the desired size in `LayerState` carries the protocol
   hint. `[INFERENCE]` — spec listed "geometry" descriptively; adding dead
   state would violate the repo slop guard.
