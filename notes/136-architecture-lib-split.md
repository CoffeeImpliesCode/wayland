# 136: Architecture audit — library vs compositor split, configuration, Zig patterns

Audit date: 2026-08-10. No code changed. Verdict: the protocol machinery is
cleanly in the library and the policy is in the compositor, with four
concrete violations: (1) the raylib backend lives in src/server/, not the
library; (2) compositor config is hardcoded inside the library (xkb layout,
seat caps); (3) no Zig Options-argument structs anywhere; (4) ~600 lines of
library-level functionality (surface->scene integration, enter/leave,
cursor) is hand-rolled in main.zig, so a second compositor would have to
reimplement it.

## 1. What the library is (src/ + root.zig)

root.zig exports 26 modules: wire/core (display), utils (geom/damage/log/
matrix), buffers (buffer/shm), compositor (compositor/surface/region/role/
seat/xkb/subsurface/data_device/primary_selection), backend (backend.zig +
headless/drm/libinput), output (output/wl_output), renderer (renderer/
pixman/canvas), shell (xdg/layer_shell/xdg_activation/xdg_decoration),
scene (scene/camera), presentation, screencopy.

The library follows the wlroots/smithay model: protocol objects + events
(wire.Signal hooks are the smithay-handler analogue — xdg new_toplevel/
new_popup, seat key/button/move/axis, output commit/frame/destroy,
decoration request_mode, activation request_activate). This is the
library's main configuration mechanism and it works: main.zig consumes the
events and decides policy.

## 2. What belongs where — the violations

### V1 [placement] The raylib backend is not in the library
src/server/raylib.zig + raylib_input.zig are a BACKEND (one windowed
output + an input source), the same kind as src/backend/{headless,drm,
libinput}.zig — which ARE library modules exported from root.zig. The
raylib backend is imported directly by main.zig (build.zig wires
raylib_c via -Denable_raylib) and is NOT exported from root.zig, so the
library has a backend-shaped hole: a second compositor cannot select the
raylib backend through the library API. Fix: move to src/backend/raylib.zig
(+ raylib_input.zig to src/backend/ or compositor input glue), export from
root.zig, select via the same backend-selection path as drm/headless.
The E2E test client (src/server/client.zig) is a test fixture — fine
where it is (or a tests/ dir; cosmetic).

### V2 [placement] Library-level functionality hand-rolled in main.zig
main.zig is 2518 lines, 66 fns. Compositor policy legitimately there:
xdg toplevel/popup/layer consumers, camera state + env parsing, ping
policy, synth input, decoration/activation policy. NOT legitimate there
(the library has the machinery, main.zig bypasses it):
- surface->scene-node mapping + lifecycle: syncSurfaces, updateSurfaceNode,
  ensureSurfaceTree, removeSurfaceNode, onSurfaceCommit/Destroy/Unmap
  (12 SurfaceEntry references). wlroots' analogue is wlr_scene_surface +
  wlr_surface enter/leave (types/wlr_scene.c); smithay's is the scene tree.
  Our scene module (scene.zig) has the node + pick machinery but no
  surface binding; main.zig owns the binding table.
- surface enter/leave: sendSurfaceEnter + onSurfaceEnter/Leave live in
  main.zig (note 135 O20 was "wired" here) — the library's wl_surface
  enter/leave protocol implementation is missing; the compositor does it.
- cursor: updateCursor, cursorFootprints, drawCursor,
  ensureCursorFallbackTexture (main.zig) — wlroots ships wlr_cursor in the
  library. A second compositor gets none of this for free.
- the render loop orchestration (requestRender/renderFrame damage->
  composite->present) is main.zig. Acceptable per the zio decision (the
  compositor owns the loop), but the per-surface damage translation and
  base-framebuffer cache are generic and could be library helpers.

Net: a second compositor today reuses the 26 modules but must reimplement
~600 lines of surface-scene + cursor + enter/leave glue.

### V3 [configuration] Compositor config hardcoded inside the library
- xkb layout: Seat.init (seat.zig:290) + setKeyboardLayout (seat.zig:1821)
  hardcode "us". A compositor cannot choose a layout without editing the
  library.
- seat capabilities: keyboard|pointer only, hardcoded (seat.zig header +
  bind path). Touch/caps are not configurable.
- shm format set: the base ARGB/XRGB pair only; the renderer exposes its
  formats (renderer.zig:19-21) but shm does not advertise them (F54).
- seat version: advertised 10 (bumped in the fixing round) — a library
  constant, not compositor-selectable.

The rest of the config lives where it should (main.zig env vars + consts:
WAYLAND_BACKEND/CAMERA/SYNTH_INPUT/RUN_FRAMES/WATCHDOG, output 1280x720).

## 4. Zig patterns — the Options-argument question

Every public init is positional: `init(allocator, io, log_cfg, display,
compositor, ...)` — 24 module inits, zero Options structs. The Zig
convention (std lib + language docs) for configurable construction is an
Options struct: `pub const Options = struct { ... }; pub fn init(allocator,
options: Options)`. wlroots uses config structs (wlr_backend_config,
wlr_renderer_config); smithay uses handler traits. Our library has the
event mechanism but the init-time configuration is positional + fixed.

Candidates for Options:
- Seat.init: layout (fixes V3), capabilities, version, repeat settings,
  pointer/axis batch policy.
- Xkb.init: layout, repeat delay/rate (currently constants).
- Backends: headless mode+refresh; drm card; raylib mode/title.
- XdgShell: ping interval (currently main.zig's const), configure policy.
- ShmState: format list.
- Output/State: mode, refresh, name (partially there).

Patterns already followed correctly: allocator-first params, explicit
deinit symmetry, errdefer on every allocation, wire.Signal event hooks,
no globals. The Options structs are the missing piece.

## 5. Prioritized fix plan

1. [V1, mechanical] Move raylib backend + input to src/backend/, export
   from root.zig, keep the -Denable_raylib build gate. — DONE 2026-08-10
   (src/backend/raylib.zig + raylib_input.zig + raylib_c.h, root.zig
   exports, build.zig shared build_options/raylib_c module instances).
2. [V3, small] Xkb/Seat Options: layout + caps configurable. — DONE
   2026-08-10 (Seat.Options {layout, keyboard, pointer} + Xkb.Options
   {layout}; core deps stay positional per the author's correction:
   Options structs are for optional/with-default args only).
3. [V2, medium] Move the surface->scene binding table + enter/leave into
   the library (scene gets a SurfaceNode binding; the seat/scene wiring
   for enter/leave moves from main.zig). — DONE 2026-08-10
   (src/scene/surface_node.zig: trackSurface/SurfaceNode/collectPresented/
   addSurfaceDamage/untrackAll; enter/leave wire events library-side;
   ~800 lines of main.zig glue removed).
4. [V2, medium] Move the cursor (update/draw/footprints) into the library
   as a Cursor helper on the seat + scene. — DONE 2026-08-10
   (src/compositor/cursor.zig: Cursor.create/update/footprints/draw/
   deinit + seat.events.cursor_surface).
5. [Q3, ongoing] Introduce Options structs per module as inits change
   (start with Seat/Xkb/backends/shm per the list above). — Partially
   done: Seat/Xkb; the rest rolls in as their inits change. The
   positional core deps (allocator/io/log_cfg/display) stay positional.
6. Defer: the render-loop orchestration stays compositor-side (zio
   decision, note 114/118).

## Evidence

- Library API: src/root.zig (26 exports).
- Raylib placement: src/server/raylib.zig, src/server/raylib_input.zig
  (vs src/backend/{headless,drm,libinput}.zig exported in root.zig).
- main.zig surface/cursor glue: syncSurfaces 1745, updateSurfaceNode 1868,
  ensureSurfaceTree 2001, removeSurfaceNode 2024, sendSurfaceEnter 1852,
  onSurfaceEnter/Leave 1819/1839, updateCursor 2299, drawCursor 1585,
  cursorFootprints (in renderFrame 1295), ensureCursorFallbackTexture 1666.
- Hardcoded config: seat.zig:290 ("us"), seat.zig:1821, seat caps header
  (seat.zig:1-20), renderer formats (renderer.zig:19-21) vs shm formats.
- Init signatures: 24 positional `pub fn init` across
  src/{core,compositor,shell,output,buffers,backend,scene,renderer} + 
  presentation.zig/screencopy.zig (sampled: display.zig:28, seat.zig:284,
  xdg.zig:83, backend.zig:49).
