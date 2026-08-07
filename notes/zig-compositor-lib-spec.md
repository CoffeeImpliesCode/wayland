# Zig Compositor Library — Spec

Goal: an own wlroots/smithay-style compositor library in zig 0.16. Not
bindings. wlroots 0.20.2 and smithay 0.7.0 are the design references,
compared at source level (2026-08-07, local clones). This spec derives the
common core and defines the zig components.

Companion notes: stock-wlroots-vs-smithay.md (capabilities), zig-wayland.md
(wire layer), canvas-compositing.md (scene requirements).

## 0. Decision: wire layer

Build on **zig-wayland v0.6.0** as the wire layer (Server/Client/Global/
Resource/EventLoop + generated protocol bindings). This mirrors wlroots,
which builds on libwayland-server; smithay reimplements the wire in Rust
(wayland-server crate).

Evidence: zig-wayland's server core is an FFI wrapper over libwayland-server
(~80 extern fns, wayland_server_core.zig:8-655) — NOT pure zig. Its
`common.Dispatcher` (comptime opcode→Request dispatch) and `setHandler`
signatures ARE pure zig and type-safe (verified in generated wayland.zig).

Tradeoffs:
- (a) On zig-wayland: ship fast; wire correctness from libwayland; typed
  resources. Cost: libwayland-server.so link dep (system pkg-config; devenv
  already provides).
- (b) Pure-zig wire (smithay-style): full ownership, no C dep. Cost: months
  of subtle work (marshal, fd passing, error semantics, client lifecycle).

Choose (a) now. Keep the wire behind `core.wire` so (b) can be swapped in
later as an alternative implementation without touching the rest.

## 1. The common core — source-level comparison

Both libraries solve the same 12 problems. zig column = this library's
module. All file refs from local clones.

| # | Problem | wlroots (C) | smithay (Rust) | zig library |
|---|---|---|---|---|
| 1 | Wire layer | libwayland-server (wl_global_create, wl_resource_create in every types/*.c) | own wayland-server crate + Dispatch2/delegate_dispatch2! (src/wayland/dispatch2.rs) | zig-wayland: Server/Client/Global/Resource (wayland_server_core.zig) |
| 2 | Event loop | wl_event_loop (wlr_backend_autocreate(loop), headless timer at backend/headless/output.c:100) | calloop re-export; backend event sources | zig-wayland EventLoop (epoll, getFd for external loops) |
| 3 | Backend | wlr_backend_impl vtable {start,destroy,get_drm_fd,test,commit} (backend/interface.h:14); multi-backend | InputBackend trait (src/backend/input/mod.rs:628) + Device + per-event traits; Session trait (session/mod.rs:41) | backend/Backend impl struct (fn-pointer); input/device union |
| 4 | Output | wlr_output + wlr_output_state {committed bitfield, damage, mode, scale, transform, buffer} (wlr_output.h:114,179) + wlr_output_impl {test,commit,...} | Output concrete struct (src/output.rs) + OutputState; commit/present events | output/Output + Output.State (committed bitfield, atomic test/commit) |
| 5 | Renderer | wlr_renderer_impl + wlr_render_pass_impl {submit,add_texture,add_rect} + wlr_texture_impl (render/interface.h:16) | Renderer/Frame/Texture/Bind/Offscreen/ImportMem/ImportDma/ImportAll/ExportMem traits (renderer/mod.rs:216-736) | renderer/Renderer impl struct, renderer/Pass, renderer/Texture |
| 6 | Buffers | wlr_buffer + wlr_buffer_impl {get_dmabuf,get_shm,data_ptr} (wlr_buffer.h:73); lock/drop → release signal; wlr_client_buffer | Buffer trait + Allocator trait (allocator/mod.rs:44,60); shm/dmabuf impls; BufferHandler::buffer_destroyed | buffers/Buffer impl struct; lock/drop/release; shm + dmabuf + client variants |
| 7 | Surface | wlr_surface_state {committed, buffer, dx/dy, damage, opaque, transform, scale, frame_callbacks, viewport, subsurfaces} (wlr_compositor.h:30); wlr_surface_role vtable; commit flow at types/wlr_compositor.c:575 | SurfaceData/SurfaceAttributes + Cacheable/CachedState double-buffered typemap (compositor/cache.rs); TransactionQueue (transaction.rs) | compositor/Surface.State (pending/current); SurfaceRole impl struct; frame callbacks; subsurface tree |
| 8 | Seat | wlr_seat {focus, grabs, selection, drag} (wlr_seat.h:288); wlr_pointer_grab_interface etc.; wlr_cursor; wlr_input_device | Seat + PointerHandle/KeyboardHandle/TouchHandle; PointerTarget + PointerGrab (input/pointer/mod.rs); SeatHandler | input/Seat (focus, serial); grab impl structs; Cursor; InputDevice union |
| 9 | Shells | wlr_xdg_shell (configure/ack, popup grabs, positioner); wlr_layer_surface_v1 state {anchor, margin, exclusive_zone, keyboard_interactive} (wlr_layer_shell_v1.h:136) | XdgShellHandler trait; ToplevelSurface/PopupSurface + ToplevelState/PopupState; WlrLayerShellHandler + LayerSurface (shell/wlr_layer/mod.rs) | shell/xdg (WmBase, Toplevel, Popup state machines); shell/layer (LayerSurface) |
| 10 | Scene | wlr_scene tree (int coords; no rotation/float zoom) | no scene graph; Space<E> + Element/RenderElement/AsRenderElements (element/mod.rs:518-612) | scene/canvas tree (f64 coords + rotation + camera — see §5) |
| 11 | Utils | wl_signal; wlr_box/fbox; wlr_damage_ring; wlr_output_layout; wlr_matrix | Signaler (utils/signaling.rs); typed geometry Logical/Physical/Buffer (utils/geometry.rs); OutputDamageTracker (renderer/damage) | utils/ (f64 geometry, rect, matrix, damage); zig-wayland Signal/Listener/list |
| 12 | Extension | signals + compositor listens (tinywl: frame → render; new_toplevel → wrap) | Handler traits per subsystem (CompositorHandler, XdgShellHandler, SeatHandler, OutputHandler...) + State structs | Handlers fn-pointer struct + signals (see §3) |

Common invariants across both (must hold in zig):
- Surface state is double-buffered (pending/current); commit atomically swaps.
- Output commits are atomic state applications (test before commit).
- Client buffers use lock/drop + release callback before reuse.
- Seat focus changes are serialized events to clients.
- Shell surfaces have configure/ack_configure handshakes with serials.
- The compositor author implements policy; the library implements mechanism.

## 2. Component spec

### core/
- `wire.zig` — re-export zig-wayland server core: Server, Client, Global,
  Resource, EventLoop, EventSource, Signal(T), Listener(T), list.
- `display.zig` — CompositorDisplay: owns *Server, serial counter, global
  registry helpers (addGlobal(bindFn), bind wiring).
- `loop.zig` — Loop integration: `run()` (Server.run) and `pollFd()`
  (EventLoop.getFd) for embedding in custom loops (zio/custom epoll later).

### utils/
- `geom.zig` — Point/Size/Rect f64 (world) + i32 (pixel); Transform enum
  (90° + flips); conversions with rounding rules (snap only at draw).
- `matrix.zig` — 3x3 affine (f64): identity/mul/translate/scale/rotate;
  projectBox.
- `damage.zig` — DamageRing: accumulate regions across frames, rotate for
  buffer age (wlr_damage_ring pattern).
- `outlayout.zig` — OutputLayout: place outputs in world space; outputAt,
  box, adjacent (for cursor constraints and multi-output).

### buffers/
- `buffer.zig` — Buffer impl struct { .impl, .width, .height, .dropped,
  .n_locks, .release_signal, .destroy_signal }; drop(), lock(), unlock();
  release fires when dropped && n_locks == 0 (wlr_buffer.h:73 semantics).
- `shm.zig` — ShmBuffer: pool/stride/data access via zig-wayland shm; on
  wl_shm global + formats.
- `dmabuf.zig` — DmaBuffer: fd/planes/modifier; linux-dmabuf protocol state;
  import paths per renderer.
- `client.zig` — ClientBuffer: wl_buffer resource ↔ Buffer + cached texture
  (wlr_client_buffer pattern).

### compositor/
- `compositor.zig` — wl_compositor global; create_surface/create_region.
- `surface.zig` — Surface + Surface.State {committed bitfield, buffer,
  offset, surface_damage, buffer_damage, opaque, input, transform, scale,
  viewport {src,dst}, frame_callbacks, subsurfaces_above/below}; pending/
  current; commit pipeline: validate → cache → apply damage → role.commit →
  emit signals {client_commit, commit, map, unmap, destroy}; frame callback
  list management.
- `role.zig` — SurfaceRole impl struct { .name, .client_commit, .commit,
  .map, .unmap, .destroy } (wlr_surface_role pattern); role assignment
  enforcement.
- `subsurface.zig` — Subsurface tree: parent/children, cached position,
  sync/desync, apply-on-parent-commit.
- `region.zig` — Region (wl_region + damage helpers).

### output/
- `output.zig` — Output { .impl, .state: Output.State, .mode, .scale,
  .transform, .damage_ring, .swapchain, .events {frame, damage, precommit,
  commit, present, request_state} }; Output.State {committed bitfield,
  damage, enabled, scale, transform, mode, buffer}; commitState():
  test() → impl.commit() → apply → send frame; Output.Impl { .test,
  .commit, .set_cursor, .move_cursor, .destroy }.
- `mode.zig` — Mode {width, height, refresh}, custom mode support.

### backend/
- `backend.zig` — Backend impl struct { .start, .destroy, .get_drm_fd,
  .test, .commit, .data }; Backend { .impl, .events {new_output,
  new_input, destroy} } (wlr_backend_impl pattern).
- `multi.zig` — MultiBackend: sub-backend aggregation, atomic multi-output
  commit grouping.
- `headless.zig` — headless output + timer-driven frame pacing (first
  backend; also the test backend).
- `nested.zig` — nested wayland backend (client-side compositor surface) —
  development/testing on a real session.
- `drm.zig` — DRM/KMS + libinput + session (staged later; needs libdrm/gbm
  cinterop or zig-drm bindings; verify zig ecosystem first).

### renderer/
- `renderer.zig` — Renderer impl struct { .import_buffer, .begin_pass,
  .formats, .destroy, .data } (wlr_renderer_impl pattern); renderer owns
  texture cache.
- `pass.zig` — Pass impl struct { .add_texture, .add_rect, .submit };
  beginBufferPass(renderer, buffer, opts) → Pass.
- `texture.zig` — Texture impl struct { .update, .read_pixels, .destroy };
  from buffer import (shm upload / dmabuf import / EGLImage).
- `pixman.zig` — CPU renderer: compositing in memory, no GPU; canonical for
  headless/tests (and a reference implementation of the Pass contract).
- `gles2.zig` — EGL/GLES2 renderer (staged): wlr_texture import paths,
  camera-capable pass shaders (§5).

### input/
- `seat.zig` — Seat { .name, .capabilities, .pointer_state, .keyboard_state,
  .touch_state, .selection, .drag, .events {request_set_cursor,
  request_set_selection, request_start_drag, ...} }; focus helpers:
  keyboardFocusEnter/Leave (serialized), pointer focus; grab interfaces
  {enter, clear_focus, motion/button/axis, key, cancel}.
- `cursor.zig` — Cursor: position (world f64), attach input devices,
  constrain to OutputLayout, surface cursor image + hotspot.
- `device.zig` — InputDevice union {keyboard, pointer, touch, tablet,
  switch} + backend-specific data; events {destroy}.

### shell/
- `xdg.zig` — WmBase global; XdgSurface {role, configured, serial,
  current/pending geometry}; XdgToplevel {current/pending: maximized,
  fullscreen, resizing, activated, tiled, w/h, min/max; requested state;
  events request_maximize/fullscreen/move/resize/...}; XdgPopup
  {current/pending geometry, reactive, parent, seat}; popup grabs;
  positioner; configure queue + ack handling; map/unmap rules.
- `layer.zig` — LayerShell global; LayerSurface {current/pending: anchor,
  exclusive_zone, margin, keyboard_interactive, desired size, layer};
  exclusive zone accounting per output; configure/ack.

### scene/ (canvas-enabled, §5)
- `tree.zig` — SceneTree nodes: {type: tree/buffer/rect, parent, children,
  enabled, position: Vec2 f64, scale: f64, rotation: f32, z: f64}.
- `buffer_node.zig` — BufferNode: buffer/texture ref, opacity, filter mode,
  crop src box, dest size.
- `output_view.zig` — OutputView: output + camera {center: Vec2 f64, zoom:
  f64, rotation} + damage ring; world→screen matrix; culling; frame
  scheduling; direct scanout when camera is identity.
- `layout.zig` — scene output layout (world-space output placement).

### handlers.zig
Extension point (see §3).

## 3. Zig patterns

- **Interfaces**: fn-pointer impl structs (wlroots vtable style):
  `Backend`, `Output.Impl`, `Renderer`, `Pass`, `Texture`, `Buffer`,
  `SurfaceRole`, grab interfaces. Each holds `data: *anyopaque`; API fns
  take the interface + object. Runtime polymorphism without vtables-as-C
  or trait machinery; comptime where static.
- **Handlers**: hybrid of both references. (a) Signals (zig-wayland
  Signal/Listener) for lifecycle/state events — wlroots style. (b) One
  `Handlers` fn-pointer struct passed to `Compositor.init`: policy
  callbacks (newXdgToplevel, newPopup, seatFocus, outputFrame → the
  author's render step). smithay's per-trait State composition maps to one
  struct in zig.
- **Allocators**: explicit everywhere; library structs take `gpa` at init;
  no hidden allocation in hot paths (commit/render).
- **Errors**: explicit error sets (OutOfMemory, BackendFailed, ...); no
  anyerror across module boundaries.
- **Testing**: every state machine gets a test block (commit ordering,
  release semantics, configure/ack, focus serials, damage accumulation).
  std.testing.allocator for leak checks.

## 4. What the compositor author still writes

Unchanged from both references: window/canvas policy (focus, layout,
placement), keybindings, config, IPC, screen capture UI, decoration
policy, panel integration. The library provides mechanism only
(stock-wlroots-vs-smithay.md §burden).

## 5. Deliberate divergences (canvas-first)

wlroots' scene and smithay's Space both stop at integer 2D. This library's
scene is the differentiator:

- Scene nodes carry f64 world position, f64 scale, rotation (z-axis) —
  floats are exact at any zoom (rebased near origin, canvas-compositing.md).
- OutputView owns a camera (center/zoom/rotation) → pan/zoom/rotate the
  whole canvas per output; identity camera degrades to plain desktop
  compositing (int snapping, direct scanout).
- Damage accumulated in world space, transformed to screen per output.
- Input remapping: seat cursor in world coords; hit testing against
  transformed node quads (inverse camera, inverse node transform).
- Viewporter/fractional-scale surfaced to clients so zoom stays sharp.

This is the library's reason to exist: wlroots can't do it without a
custom pass; we make the canvas the first-class compositing model.

## 6. Build order (milestones)

M1 — core + utils + compositor/surface state + shm buffers + headless
     backend + pixman renderer + xdg-shell: tinywl-equivalent end-to-end
     (protocol roundtrip, one surface on a headless output).
M2 — output state machine + damage ring + scene (int mode) + frame
     scheduling + presentation.
M3 — seat/input: focus, serials, grabs, cursor, keyboard (xkb).
M4 — shells complete: layer-shell exclusive zones, popup grabs, positioner.
M5 — nested-wayland backend + gles2/EGL renderer (real session testing).
M6 — DRM + libinput + session backend (physical outputs).
M7 — canvas scene: f64 nodes, rotation, camera, world-space damage,
     input remapping (the differentiator).
M8 — extras: data-control, screencopy, foreign-toplevel, tearing,
     fractional-scale.

Each milestone ends green: `zig build test` + a runnable example.

## 7. Grounding

All claims verified in local clones 2026-08-07:
- wlr_output_state.committed bitfield — wlr_output.h:114; wlr_output — :179.
- wlr_backend_impl vtable — backend/interface.h:14; renderer vtables —
  render/interface.h:16.
- smithay InputBackend — src/backend/input/mod.rs:628; Device — :20;
  Renderer/Frame/Texture/Import* — renderer/mod.rs:216-736; Buffer/
  Allocator — allocator/mod.rs:44,60; Element/RenderElement —
  element/mod.rs:518,572.
- zig-wayland server core is FFI over libwayland-server —
  wayland_server_core.zig + ffi.zig; comptime Dispatcher + setHandler —
  common_core.zig + generated wayland.zig (13,188 lines, server:4389+).
