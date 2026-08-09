# Whole-tree AI-slop scan

Scope: every file under `src/` (35 .zig files, ~15.3k lines raw). Category definitions from AGENTS.md "AI-slop guard". No wlroots/smithay comparison. Every dead-code claim was verified by grep across `src/` before reporting; single-hit means the declaration is the only occurrence.

## Surface

Inventory (raw lines / pure code lines — pure = non-blank, non-`//` comment):

| file | raw | pure |
| --- | --- | --- |
| src/compositor/surface.zig | 1442 | 1007 |
| src/shell/xdg.zig | 1305 | 998 |
| src/server/main.zig | 1226 | 898 |
| src/compositor/seat.zig | 942 | 682 |
| src/scene/scene.zig | 894 | 670 |
| src/backend/drm.zig | 890 | 633 |
| src/server/client.zig | 655 | 543 |
| src/presentation.zig | 608 | 414 |
| src/compositor/data_device.zig | 542 | 403 |
| src/backend/libinput.zig | 617 | 368 |
| src/output/output.zig | 397 | 304 |
| src/compositor/subsurface.zig | 412 | 289 |
| src/buffers/shm.zig | 322 | 193 |
| src/screencopy.zig | 305 | ~200 |
| src/renderer/pixman.zig | 395 | ~230 |
| src/buffers/buffer.zig | 311 | ~170 |
| src/utils/damage.zig | 286 | ~180 |
| src/compositor/region.zig | 228 | ~130 |
| src/compositor/xkb.zig | 227 | ~140 |
| src/core/display.zig | 202 | ~140 |
| src/server/raylib.zig | 357 | ~240 |
| src/backend/backend.zig | 145 | ~100 |
| src/server/raylib_input.zig | 152 | ~110 |
| src/backend/headless.zig | 179 | ~110 |
| src/output/wl_output.zig | 131 | ~90 |
| src/renderer/renderer.zig | 99 | ~70 |
| src/utils/log.zig | 92 | ~70 |
| src/renderer/pass.zig | 85 | ~60 |
| src/renderer/texture.zig | 44 | ~30 |
| src/compositor/role.zig | 101 | ~70 |
| src/compositor/compositor.zig | 194 | ~120 |
| src/utils/geom.zig | 111 | ~80 |
| src/core/wire.zig | 28 | ~20 |
| src/root.zig | 108 | ~80 |
| src/main.zig | 31 | ~25 |

Test blocks are a large share of the pure count (e.g. surface.zig ~450 lines of tests, scene.zig ~350, xdg.zig ~250).

## Findings

Ordered by severity (med first, then low). All line numbers verified by read.

| # | file:line | cat | evidence | sev |
| --- | --- | --- | --- | --- |
| 1 | src/server/main.zig:172 | c | `main` spans 172-473 (~300 lines, ~200 pure): backend selection, libinput/DRM wiring, env parsing, event loop setup, teardown defers in one body. | med |
| 2 | src/backend/drm.zig:198 | c | `startInner` spans 198-440 (~240 lines): fd open, master, connector/crtc/plane enumeration, dumb buffer, modeset, output create. Section comments delimit phases but the body is one fn. | med |
| 3 | src/server/main.zig:642 | c | `renderFrame` spans 642-819 (~140 pure): synth input, damage accumulation, scene render, present state build, frame-done, presentation, perf, watchdog re-arm. | med |
| 4 | src/server/client.zig:88 | c | `main` spans 88-289 (~200 lines, ~150 pure): connect, globals, seat bind, xdg setup, shm buffer, capture verify. Linear E2E script; readable but over the 50-line bar. | med |
| 5 | src/compositor/surface.zig:109,114-115 | e | `State.committed`, `State.dx`, `State.dy` are write-only in production: set in request handlers and swapped in `swapState`, but read only by tests (lines 894, 936, 1009; dx/dy at 877-899). Doc comment on `committed` says "Read from current after a commit" — no production reader exists. | med |
| 6 | src/compositor/seat.zig:75,94 | e | `last_keycode` (written 298, never read) and `cursor_serial` (written 526, never read; the serial check at 527 uses `pointer_enter_serial`). Verified: only decl + one write per field. | med |
| 7 | src/backend/drm.zig:61-64 | i | Constant `drm_format_xrgb8888` (0x34325258 = 'XR24') carries a doc comment describing DRM_FORMAT_ARGB8888 ('AR24', 0x34325241, "bytes B,G,R,A"). Introduced by the recent XRGB fix: the name changed, the comment did not. Module header (drm.zig:19) also lists DRM_FORMAT_ARGB8888 in the namespace contract. | med |
| 8 | src/backend/backend.zig:25-26 | i | `new_input` doc: "No input backends emit this yet ... libinput will announce devices through it." Stale since the libinput backend landed: libinput.zig:359 calls `emitNewInput` and server/main.zig:343 subscribes. | med |
| 9 | src/compositor/seat.zig:95 | e | `cursor_visible` is read (348) but never written false anywhere; the hide path is unreachable state. `[INFERENCE]` intended for future cursor-hide support, but currently the flag is constant. | low |
| 10 | src/backend/libinput.zig:160-161 | e | `libinput_path_create_context` and `libinput_path_add_device` extern decls never called (verified: decl-only; the backend uses the udev path). | low |
| 11 | src/backend/libinput.zig:91,104,107,115 | e | Constants `event_none`, `key_state_released`, `button_state_released`, `pointer_axis_source_wheel` never referenced (verified: decl-only). Their enum siblings are used; these four are dead FFI mirrors. | low |
| 12 | src/screencopy.zig:47 | c | `Screencopy.init` takes 11 params: allocator, io, log_cfg, display, shm, plus three fn-pointer + ctx pairs (get_framebuffer, owns_output, clock). One `*anyopaque` ctx + method struct would halve the list; the caller (server/main.zig:354-364) passes the same `&state` three times. | low |
| 13 | src/backend/drm.zig:745 | c | `copyRows` takes 6 params (src, src_stride, dst, dst_stride, width, height). Borderline; a small struct would read better but it is a leaf helper with a single caller. | low |
| 14 | src/presentation.zig:248-251 | b | `handleRequest` carries a branch its own comment calls "Unreachable in this library ... be defensive rather than crash." Self-admitted defensive check on client input; the comment justifies it, so this is a judgment call, not a bug. | low |
| 15 | src/scene/scene.zig:393,401 | f | `nodeWidth`/`nodeHeight` are the same switch with one differing arm value; a single `fn nodeSize(node) Size` would cover both. | low |
| 16 | src/compositor/data_device.zig:441, src/presentation.zig:424, src/shell/xdg.zig:1133 | f | Byte-identical `TestServer.pump` helpers (flush client -> dispatch loop -> flushClients -> poll -> dispatch) in three files; seat.zig:732 is a two-client variant of the same pattern. Extraction into one shared harness module would remove ~60 duplicated lines. | low |
| 17 | src/server/main.zig:928 | c | `if (s.role != null) { for (toplevels) { if (matches) { configure catch { log } } } }` — control nesting to depth ~5 in the first-map reconfigure block. | low |

Category (h): zero TODO/FIXME/XXX/HACK markers in `src/` (grep verified). Category (a): no restate-the-code comments found; the tree's comments are why-comments or wlroots/smithay citations. Category (e) commented-out code: none found (all `//`-prefixed code lines are citations, protocol notes, or SAFETY annotations). `std.debug.print` appears only inside test blocks (seat.zig:814,889, xkb.zig:198). Category (b): only finding 14. Category (d): no one-caller wrapper types found; the impl-table abstractions (Backend/Output/Renderer/Pass/Texture) mirror wlroots and have multiple impls (headless/drm, fake/test).

Modules over 250 pure LOC (cat g): surface.zig 1007, xdg.zig 998, server/main.zig 898, seat.zig 682, scene.zig 670, drm.zig 633, server/client.zig 543, presentation.zig 414, data_device.zig 403, libinput.zig 368, output.zig 304, subsurface.zig 289. Twelve files over the bar; the top five are the ones the task flagged. All carry 25-45% test code; the production halves of surface.zig/xdg.zig/seat.zig are the realistic split targets (surface state machine, xdg shell roles, seat input vs seat wire handlers). utils/ stays as-is per the no-utils.zig rule.

## Verdict

The tree is clean enough to build on. No slop markers, no commented-out code, no restate-the-code comments, no test-mode debug prints, and the dead-code surface is small (8 unused decls/fields, all in the two newest files: libinput FFI and seat). The work since round one (DRM, libinput, server wiring, buffer lifecycle, VM harness) is disciplined: recent fixes verified present — XRGB8888 fourcc in the ADDFB2 path (drm.zig:331), `new_input_listener` built via `.init()` (main.zig:324), per-frame `flushClients()` in renderFrame (main.zig:809-815) and onDisplayReady (main.zig:627), one-capability `kindForDevice` (libinput.zig:242), ShmState dead-buffer graveyard (shm.zig:66-67, 90-96), function-scope libinput destroy defer (main.zig:304).

Top-3 debt: (1) god functions — the four >140-line bodies in main.zig:172/642, drm.zig:198, client.zig:88 are the main structural risk; split `renderFrame` (synth-input block -> fn, damage build -> fn, present state -> fn) and `startInner` (per-phase fns already sketched by comments). (2) Write-only protocol state — `Surface.State.committed/dx/dy` and `Seat.last_keycode/cursor_serial` are set, swapped, and never consumed; either wire them into the consumers or delete the fields. (3) Stale docs on two recent changes — drm.zig:61-64 (ARGB comment on the XRGB constant) and backend.zig:25-26 (new_input "not emitted yet") mislead the next maintainer; both are one-line comment fixes. Secondary: the 4 dead libinput decls/constants (remove), 11-param `Screencopy.init` (collapse the three ctx/fn-pointer pairs), and the triplicated test pump (extract one harness module).
