# Wayland Research — Index and Decisions

Synthesis of the research phase (2026-08-07), reconciled after the
improvement round (same day). Target: a Wayland compositor whose compositor
layer is wlroots/smithay-style and whose usage layer is a dynamicland-inspired
large 2D canvas. Stack: Zig 0.16.0. All facts come from the seven notes
indexed below. Additions are marked `[INFERENCE]`.

## Index

| File | Topic | Key findings |
|---|---|---|
| `wayland-compositor-basics.md` | Core protocol, shells, render loop, input, outputs, testing | wl_surface atomic commit state machine; xdg-shell configure/ack handshake; render loop = damage accumulate → vblank → composite → present → frame_done; headless + pixman gives a deterministic unprivileged test env; interface versions verified against wayland.xml; weston-test harness verified (in-process fixture compositor, TAP, 120 s timeout). |
| `zig-wayland.md` | Spec parsing and codegen for Zig | ifreund/zig-wayland ACTIVE, tracks zig 0.16 (v0.6.0, 2026-04-25; churn evidence per zig release since 0.13); all forks verified dead (last push 2022-2024); zig-wlroots v0.20.1 pin (2026-04-25) ↔ wlroots 0.20 line; build.zig.zon + Scanner recipe documented; addCSource workaround gone since v0.3.0. |
| `wlroots.md` | wlroots architecture and wlr_scene | Current stable wlroots = 0.20.2 (master 0.21.0-dev); local clone refreshed to 0.20.2. wlr_scene: integer positions, integer dest-size scale, 90° transforms, opacity, crop, filter; NO rotation/float zoom/shader hooks; damage ring, culling, texture caching, direct scanout built in (scanout conditions verified in wlr_scene.c); labcw + sway verified as scene users; tinywl is the minimal compositor reference. |
| `smithay.md` | Rust compositor library | No scene graph: flat `desktop::Space`, i32 positions, uniform scale, no per-element rotation. Pass object is the `Frame` trait (no `RenderPass` type); effect hooks `is_framebuffer_effect`/`capture_framebuffer` exist, blur is DIY; Vulkan backend = init-only wrapper (no renderer); callbacks are sequentially invoked with `&mut State`. Rust-vs-Zig porting cost is substantial. |
| `canvas-compositing.md` | Presenting surfaces on a large canvas | wlr_scene cannot do rotation or float zoom → custom camera pass mandatory: world `f64` coords, matrix `M = T·S·R·T`, camera rebase vs fp32 jitter, world-space damage + input via inverse camera; sharp zoom via fractional-scale/viewporter; 8-row prior-art table (niri, wayfire, wayvr, gnome magnifier.js, egui, ...); 9 risks. |
| `zio.md` | Async I/O framework for Zig | lalinsky/zio verified from source: created 2025-09-16, pushed 2026-08-05, 575 stars, NOT archived; three layers `zio.ev`/`zio.coro`/`zio.Runtime` (std.Io impl); zig-libuv archived 2023, libxev active. Verdict: DO NOT adopt for the compositor core loop (small fixed fd set, std.posix.poll / std.os.linux.epoll_*); revisit for companion network services only. |
| `dynamicland.md` | Dynamicland / Realtalk | Dead URLs recovered via Wayback (2019 Research Gallery capture, 2017 homepage); SAP/CDG affiliation VERIFIED via dynamicland.org/archive/2014/CDG + archived Bloomberg; no /2025/ /2026/ pages (404, verified 2026-08-07); commentary: Matuschak notes et al. Take: spatial persistence, live objects, multi-scale navigation, shared presence. Leave: paper/camera/projector substrate, anti-product philosophy. Impl details not public. |
| `zig-wayland-stack.md` | Zig wayland stack | Layered stack: wlroots 0.20.2 / zig-wlroots v0.20.1 / zig-wayland v0.6.0 / vendored XMLs; gaps (canvas pass DIY); reference reads. Now wired into build.zig: scanner generates ~13k-line bindings from protocols/ (server + client namespaces). |
| `stock-wlroots-vs-smithay.md` | What wlroots & smithay provide | wlroots: mechanism (90+ headers, 7 backends, 3 renderers, scene graph) not policy. smithay: Rust framework (traits, Space, anvil). The compositor author's burden: 10 re-implemented features (config, IPC, keybindings, policy, ...). Pattern steals: river's WM split, wayfire's render pass, niri's scrollable space. |
| `101-display-wire-vs-wlroots-smithay.md` | Diff: display/wire layer | CompositorDisplay vs libwayland usage + smithay Display/GlobalDispatch. close parity; smithay uses an independent atomic SerialCounter; wlroots implements its own wl_shm global (ours delegates to libwayland's). |
| `102-compositor-region-role-vs-wlroots-smithay.md` | Diff: wl_compositor/region/role | close parity; role conflict: ours posts wl_surface error code 1 (invalid_transform) vs wlroots caller-supplied codes; missing DEFUNCT_ROLE_OBJECT guard; region bounding-rect vs pixman normalized. |
| `103-surface-vs-wlroots-smithay.md` | Diff: wl_surface state machine | medium parity; riskiest: frame done at commit vs present; hold-the-lock buffer model (wlroots releases every commit); damage_buffer folded into surface damage; auto-map off buffer presence. |
| `104-buffers-shm-vs-wlroots-smithay.md` | Diff: buffers/shm | Buffer wrapper near-parity; wl_shm delegated to libwayland vs wlroots/smithay own implementation; our external resource map has the pointer-reuse hazard wlroots avoids by design (fix verified). |
| `105-xdg-shell-vs-wlroots-smithay.md` | Diff: xdg shell | low-to-medium parity; accept-stale ack_configure vs serial list; auto 0x0 initial configure; popup stub (no grab/reposition/topmost); missing tiled/suspended/constrained states. |
| `106-seat-xkb-vs-wlroots-smithay.md` | Diff: seat/keyboard/pointer/xkb | medium parity; no grab system; events fanned out to all clients; no modifiers-after-enter; no MISSING_CAPABILITY; repeat 0/0; touch dead object; seat v7 vs wlroots 9. |
| `107-subsurface-vs-wlroots-smithay.md` | Diff: subcompositor | place_above/below no-ops; sync not enforced; UAF risk (no parent/child destroy listeners); flat per-frame re-append gives wrong cross-surface z-order. |
| `108-data-device-vs-wlroots-smithay.md` | Diff: wl_data_device | selection relay close; cross-client delivery broken (per-client storage); start_drag cancels only (no DnD); no dnd_drop_performed/finished. |
| `109-output-vs-wlroots-smithay.md` | Diff: output + wl_output | no test/commit split; no unchanged short-circuit; no mode-change rebroadcast; hardcoded geometry/scale; missing frame_pending guard. |
| `110-scene-vs-wlroots-smithay.md` | Diff: scene graph | damage_ring is dead code in render(); pick buffer-only vs wlr_scene_node_at; no self-ancestor cycle guard; smithay N/A (RenderElement instead). |
| `111-renderer-vs-wlroots-smithay.md` | Diff: renderer/pass/texture/pixman | per-pixel straight-alpha loops vs pixman C composites (premultiplied); updateMemory has no wlroots counterpart; eager no-op submit; no buffer locking. |
| `112-presentation-vs-wlroots-smithay.md` | Diff: wp_presentation | core-path wire parity; missing sync_output, supersede-discard, per-output tv/seq, ZERO_COPY flags. |
| `113-screencopy-vs-wlroots-smithay.md` | Diff: zwlr_screencopy | synchronous copy vs wlroots commit-deferred; copy_with_damage not honored; shm-only; overlay_cursor ignored; fixed ARGB8888; smithay N/A. |
| `114-backend-vs-wlroots-smithay.md` | Diff: backend + headless | lifecycle near-parity; headless re-arms timer unconditionally, single hardwired output, no new_input signal (blocks libinput), no teardown hook. |
| `115-utils-damage-geom-log-vs-wlroots-smithay.md` | Diff: damage ring/geom/log | rotate/2-ring close to wlr_damage_ring; no Logical/Physical size type distinction vs smithay; log levels vs wlr_log + tracing. |
| `116-drm-backend-audit.md` | Audit 2: DRM/KMS backend | High parity with wlroots drm.c/atomic.c + smithay (blocking modeset, NONBLOCK flips, pending-flip guard, leak-free reverse-order teardown all verified); XRGB8888 fix required for virtio-gpu (primary plane formats = {XRGB8888} only, kernel v6.6 virtgpu_plane.c:47-52); PROVEN BUG: pixman `addRect` stores [R,G,B,A] but drm.zig:57-60/814-815 claims BGRA — compositor-drawn rects (background, cursor) R/B-swapped on DRM scanout; single-buffer tearing by design; dumb-vs-GBM = scope cut. |
| `117-libinput-backend-audit.md` | Audit 2: libinput backend | FFI table 30/30 extern decls verified vs libinput 1.31.3 (has_capability two-arg fix correct, libinput.h:4490-4492); udev/ctx ref pairing + teardown order sound; PROVEN: (1) errdefer bypass — `append catch return` leaks the owned name on OOM (libinput.zig:352-354); (2) axis source ignored — wheel scaling applied to finger/continuous scrolls, seat hardcodes .wheel (libinput.zig:415-428, seat.zig:243). wlroots emits one new_input per capability, ours announces once by priority. |
| `118-server-wiring-audit.md` | Audit 2: server wiring | Event loop correct: three rearmed zio PipePolls, renderFrame-end flushClients required for DRM path, idempotent headless; listener audit exhaustive, all 8 .add() are .init()-ed. HIGH: defer LIFO — shm_state.deinit (main.zig:217) runs before compositor.deinit (main.zig:215) → surface destroy touches freed shm wrappers on RUN_FRAMES/watchdog exits (latent UAF; swap the defers). MED: damage rects + reconfigure hardcode 1280x720 vs out.mode. |
| `119-buffer-lifecycle-audit.md` | Audit 2: buffer lifecycle | Release fires at commit step 8 after the pixel copy; begin/endAccess pairing sound; no double-free in the graveyard (map entry removed before append); get_release v7 where wlroots 0.20.2/smithay have none. BUG (OOM-only): graveyard append OOM early-return skips resource-null + drop → releaseNotify sendRelease on freed resource (shm.zig:212-220). MED: same teardown-order UAF as 118. LEAK (dead in server): untracked fromResource wrappers never destroyed (contract at shm.zig:127-128 unimplemented). |
| `120-vm-harness-audit.md` | Audit 2: VM harness | Verdict: trustworthy as DRM/libinput init + client-completion gate WITH caveats — 14 gaps: headless E2E service missing libdrm/libinput .pc paths (headless gate likely dead, vm.nix:100); stale-cache false verdicts (no rm -rf in vm-e2e.sh); wiring grep matches WAYLAND_BACKEND emitted by both drm and raylib env branches (proves parsing, not wiring); drm_lines counts failure lines as pass evidence (grep 'drm: modeset ok' instead); dmesg dump misplaced pre-run; leak check advisory only. |
| `121-slop-scan.md` | Audit 2: slop scan | 17 findings (0 high): top debt = 4 god fns >140 lines (main.zig:172/642, drm.zig:198, client.zig:88), write-only protocol state (Surface.State.committed/dx/dy, Seat.last_keycode/cursor_serial), stale docs on two recent fixes (drm.zig:61-64 ARGB comment on XRGB8888 const; backend.zig:25-26 'new_input not emitted' — libinput emits). All six recent fixes verified present. |
| `122-client-raylib-audit.md` | Audit 2: client + raylib | waitForEvent: NO event-miss race (dispatch + predicate re-check + poll-before-wait); real defect = poll EINTR aborts the run (client.zig:586-591). Raylib OOM path double-free (raylib.zig:130,144,147). Client never acks the server's second (size) configure (main.zig:911-930) — legal today, latent hazard. Hardcoded 1280x720 couples the client to the VM's forced resolution. Screencopy pixel checks verified correct. |
| `123-backend-breadth.md` | Breadth: backends | 22 rows; missing vs wlroots/smithay: session/libseat (VT switching, pause/activate), GBM allocator+swapchain+modifiers, udev hotplug, multi-backend, nested Wayland, X11/winit, planes/libliftoff, legacy DRM, syncobj, leases, multi-GPU, EGL/GLES/Vulkan, libei, tablet/switch/gesture. In-scope: session/libseat, GBM+swapchain (when GPU lands), hotplug; raylib (ours-only) covers the dev-loop role. |
| `124-compositor-breadth.md` | Breadth: compositor/buffers | 18 rows; missing: scale/transform application (canvas draws buffers 1:1 — scale/transform only feed damage), output enter/leave, viewporter global, dmabuf path (vtable slot null), preferred-scale hints, surface-tree traversal, commit blockers. In-scope: scale/transform, enter/leave, viewporter, preferred-scale; dmabuf out-of-scope until a GPU renderer. |
| `125-seat-input-breadth.md` | Breadth: seat/input | 22 rows; in-scope for canvas: touch, tablet v2, gestures (pinch zoom), relative pointer (1/z), virtual keyboard+pointer (test automation), key repeat, seat grabs; optional: constraints/pointer lock, idle, primary selection, xcursor; out-of-scope: switch, keyboard groups, IME. Verified absences: wlr_idle removed in 0.20.2, input-inhibit in neither reference. |
| `126-shell-protocols-breadth.md` | Breadth: shell/protocols | 50 rows; 7 XMLs vendored, viewporter/fractional-scale/layer-shell vendored-but-unimplemented. In-scope: layer-shell (M4), viewporter+fractional-scale (roadmap 7), tablet, relative-pointer, gestures, constraints, primary-selection, data-control, linux-dmabuf, xdg-output, xdg-activation; out-of-scope: xwayland, drm-lease, server-decoration, export-dmabuf. Smithay v0.7 dropped gamma/output-management/output-power/virtual-pointer (wlroots types/ is the only reference). |
| `127-output-render-scene-breadth.md` | Breadth: renderer/output/scene | 45 rows; in-scope roadmap: GPU renderer + swapchain/allocator + format negotiation + sync points + per-element damage + output-layout-via-cameras; out-of-scope: direct scanout, KMS layers, color management, multi-GPU. canvas.zig/camera.zig EXCEED both references (f64 world, rotation, bilinear). wlr_output_damage removed in 0.20.2. |
| `128-misc-breadth.md` | Breadth: data-device/subcompositor/utils | 29 rows; missing: DnD lifecycle/drop zones/drag icons/action negotiation (start_drag cancels only), primary selection, selection-offer lifecycle (dangling-source hazard), subsurface sync not enforced + flat stacking, matrix/box-transform helpers (spec utils/matrix.zig). In-scope: offer lifecycle, serial validation, sync caching, matrix helpers, primary selection; defer DnD/grabs to the seat. |
| `129-layer-shell-impl.md` | layer-shell v5 impl | Full zwlr_layer_shell_v1 module (LayerShell + LayerSurface state machine: bufferless-first-commit, configure/ack, unmap reset, anchors/exclusive zone/kbd interactivity, error codes). 8 wire tests. Advertises v5. |
| `129-xdg-shell-conformance.md` | xdg-shell conformance fixes | 15 adversarial findings fixed (re-map reset, defunct_surfaces, wrong-resource invalid_positioner, not_constructed guards, resize-edge validation, positioner input validation, unconfigured_buffer at creation, title UTF-8). Deferred: popup grab/topmost, ping/pong, real parenting, wm_capabilities. |
| `129-selection-parity.md` | primary-selection + data-device | New zwp_primary_selection_device_manager_v1 module (no-serial, keyboard-focus gated, bind-time delivery, used-once); data-device bind-time delivery + offer/source protocol errors + event-order fix (data_offer→mimes→selection). Deferred: DnD full lifecycle. |
| `129-shell-protocols-impl.md` | xdg-activation + xdg-decoration | Both implemented v1: wlroots token model (one-shot commit, serial+focus validation, single-use, 30s expiry), decoration strict invalid_mode (XML-mandated, no reference raises it), orphaned/unconfigured_buffer/already_constructed. |
| `130-versioning-conformance.md` | Protocol version negotiation | Three-layer model: libwayland gates requests (since>bound → INVALID_METHOD) + binds (INVALID_OBJECT); zig-wayland generates no version logic; our modules gate events. Fixed: screencopy damage (since 2) leak to v1 clients, data_device children hardcoded v3. Legacy tests: xdg v5, layer v3, output v2, screencopy v1, data_device v1. Seat advertises v7 (generated 11) deliberately; decoration v1. |
| `131-core-surface-f2f.md` | F2F audit: core/surface/compositor/region/buffers | 23 findings; HIGH: F41 unchecked i32 rect arithmetic (geom.zig intersect/union — Debug trap/ReleaseFast UB; refs use int64/checked), F42 commit after attached-buffer destroy keeps stale content (wlroots nulls + unmaps). 15 FIXABLE-in-module, 2 NEEDS-wiring, 3 STRUCTURAL. |
| `132-seat-input-f2f.md` | F2F audit: seat/keyboard/pointer/xkb/subsurface | 13 findings; HIGH: wire keycode off by 8 (xkb keycode vs raw scancode; protocol + all refs send scancodes). Serial model single seat-wide value vs wlroots per-client 128-slot ringset (false rejects/accepts). Grab system absent (STRUCTURAL). Notes 106/107 largely stale (fan-out, modifiers, place_above/below now correct). |
| `133-xdg-layer-f2f.md` | F2F audit: xdg-shell + layer-shell | 23 findings; HIGH: popup unconstrain math (flip/slide/resize) absent, grab stub, ping/pong absent, configure_bounds/wm_capabilities never sent, layer get_popup is a stub. MED: state array not version-filtered (suspended/constrained leak to v5), role-destroy pre-map reset, min/max validated-then-discarded. Keep our ack_configure placement (XML-conformant). |
| `134-selection-shellaux-f2f.md` | F2F audit: selection + shell aux | 18 findings; HIGH: DnD state machine absent (STRUCTURAL), action negotiation never computed/emitted (FIXABLE), decoration configure not synced with xdg_surface configure/ack (XML violation, NEEDS-wiring). Doc fix: wlroots DOES validate primary-selection serial. |
| `135-output-presentation-backends-f2f.md` | F2F audit: output/presentation/screencopy/backends | 30 findings; open: sync_output (F7), copy_with_damage (F14), wl_output rebroadcast (F1), frame_pending guard (F2), headless mode pacing (F4/F22), synthetic tv/seq root cause = missing drm present event (F8 STRUCTURAL). Closed since last notes: axis-source handling, drm byte-order, A/B swapchain, libinput leaks. |
| `136-architecture-lib-split.md` | Architecture: library vs compositor | Library (26 modules, root.zig) clean; 4 violations: raylib backend in src/server (not the lib), xkb layout "us" + seat caps hardcoded in the lib, no Zig Options structs (24 positional inits), ~600 lines of surface→scene + cursor + enter/leave glue hand-rolled in main.zig (a second compositor would reimplement it). Fix plan: move raylib backend, Xkb/Seat Options, library SurfaceNode binding + cursor helper. |
| `137-server-adversarial.md` | Server adversarial vs tinywl/smallvil | Verified HEADLINE: commit→present starvation — surface content commits never wake a composite (frame_kick presents the stale framebuffer + fires wl_callback); content appears only after cursor/camera/screencopy events. Plus: maximize/fullscreen never answered (protocol deadlock), move/resize unhandled + camera-pan collision, activated never sent + no map-focus/raise, no key repeat + static caps, no compositor close path, hover-focus absent, single-output. Fix order: commit→present wake first. |
| `138-adversarial-comparison.md` | Protocol adversarial vs wlroots/smithay/KWin (6 areas) | Wire surface nearly complete at or above reference versions (v7 get_release unique). 1 CRITICAL: viewporter UAF on wl_surface.destroy. MAJORs: subsurface destroyed-vs-inert on parent death; subsurface map/enter/present not parent-coupled; seat v10 repeat contract (rate 0 + KEY_STATE_REPEATED); implicit grab leaks axis/release; missing layer new_popup + decoration new_toplevel_decoration signals; viewport single-buffered + unvalidated crop; synthetic presentation. Structural backlog: popup grab/reactive, compositor-driven configure, DnD, touch/grab layer, real present event. Working sections: local/cmp-*.md. |
| `139-fix-plan.md` | Triaged fix plan for the 138 findings | 31 fixes now (2 phase-0 wire-safety: viewporter UAF, fractional stale entry; 8 phase-1 majors: subsurface inert + parent-coupled map, v10 repeat, grab gate, selection-on-focus test, viewport double-buffer + crop validation; 21 phase-2 parity/hooks: grab error surface, layer/decoration signals, inert-on-close/activate, source_actions, mime validation). 15 deferred structural (DnD, grabs, compositor-driven configure, real present event) with triggers; 15 accepted deliberate/positive. Full per-fix specs (verified lines, tests, acceptance): local/fix-*.md. |
| `140-wayland-debug-tools.md` | Wayland debug + conformance ecosystem | Built-in WAYLAND_DEBUG (client :1247 / server :1283) + wl_display_set_protocol_logger (server-only). Middle-man dumpers: wayland-tracker (JSON), wayland-tracer, wlanalyzer, wldbg, wl-proxy/wl-veil/wl-format-filter, wlhax. wayland-debug (wmww): filter + GDB breakpoints. wayland-info, GammaRay, wev. Compositor debug: weston_debug_v1 + log scopes + timeline/perfetto; wlroots WLR_SCENE_DEBUG_DAMAGE + env set; swaymsg; KWin qCDebug. libinput record/replay/measure. Conformance: wlcs (in-process integration module; smithay pins it), weston suite (weston_test protocol, 81 tests), KWin autotests/wayland/server; wlroots 0.20 has NO tests/. Our next wins: WAYLAND_DEBUG on run-server, wayland-info global check, wlcs integration module. |
| `141-classical-client-conformance.md` | Classical Wayland client conformance + backend parity | 12 classical clients pass against the compositor (weston-terminal/flower/clickdot/eventdemo/smoke/image/resizor/dnd/presentation-shm, wev, wl-copy/wl-paste roundtrip, grim 1280x720 PNG). Two real bugs fixed: synth input clicked a fixed (50,50) coordinate (missed 1x1 surfaces → selection never set; now clicks each new surface's center) and missing zxdg_output_manager_v1 (grim sized captures 0x0 from empty logical layout; module implemented, protocol XML vendored). Backend parity verified: nested/headless/raylib identical client-visible behavior (frame counts differ by timer pacing only). |
| `zig-compositor-lib-spec.md` | Zig compositor library spec | Design authority for the own zig wlroots/smithay clone. Decision: build on zig-wayland wire layer (it is FFI over libwayland-server — not pure zig). 12-dimension common-core table (source-grounded, both libs). Component spec: core, utils, buffers, compositor, output, backend, renderer, input, shell, scene. Divergence: canvas-first scene (f64 coords, rotation, camera). Milestones M1-M8. |

## Stack recommendation

### (a) Compositor layer: wlroots over smithay

Recommendation: build on **wlroots via zig-wayland + zig-wlroots**, not smithay.

- The stack is Zig. Smithay is Rust; porting its protocol codegen, trait
  dispatch (`delegate_dispatch2!`), and `Element`/`Renderer` abstraction to
  Zig is substantial (smithay.md). Zig instead owns the render graph and
  shader plumbing directly — exactly where smithay is weakest (rotation,
  sub-pixel transforms, effects).
- zig-wlroots tracks Zig 0.16 + the wlroots 0.20 line (v0.20.1 pin, river
  is the proof of completeness) (zig-wayland.md, wlroots.md).
- Both scene models cap at flat 2D integer composition; the canvas layer
  needs a custom render pass on either stack (smithay.md, canvas-compositing.md).

### (b) Wayland spec parsing: upstream zig-wayland scanner

- Use upstream ifreund/zig-wayland (v0.6.0 or newer; current main tracks
  zig 0.16) as a build.zig.zon dependency. Only maintained line — all forks
  verified dead (seanpm2001 2022, zoriya 2023, kdchambers 2024).
- Scanner is Zig-native (own code generator, not a wayland-scanner wrapper),
  integrated into build.zig; generates `client`/`server`/`common` namespaces
  per global (`scanner.generate("wl_seat", 4)` trims to reachable
  interfaces). Covers wayland core, wayland-protocols, wlr protocols, custom
  XML. Options: `wayland_xml`, `wayland_protocols` (LazyPath), `ffi_import`.
- Pin the dependency hash; upgrade deliberately — every zig release since
  0.13 broke it (0.13→v0.2.0 2024-06-07, 0.14→v0.3.0 2025-03-07,
  0.15→v0.4.0 2025-08-22, 0.16→v0.6.0 2026-04-25) (zig-wayland.md).
- Local clone `~/projects/codeberg-ifreund-zig-wayland` refreshed to v0.6.0
  (2026-04-25, zig 0.16); matches the upstream release line.
- Vendor the XMLs (wayland.xml, wayland-protocols, wlroots.xml) and pass
  them via Options for hermetic NixOS builds; `PKG_CONFIG` is honored for
  the libwayland ffi pieces.

### (c) zio verdict

- Do NOT adopt zio for the compositor core loop. The loop is a small fixed
  fd set (wayland socket, libinput, DRM) driven synchronously by poll/epoll
  on one thread; zio adds a foreign event loop without benefit, and the
  compositor must own the loop for frame timing control. Verified std facts:
  `std.posix.poll` exists; epoll lives at `std.os.linux.epoll_*` (zio.md).
- Revisit zio only when network companion services (HTTP/WebSocket control,
  remote display forwarding) become a requirement; it is then the strongest
  candidate (active, Zig 0.16-native, `std.Io` drop-in) (zio.md).

### (d) Rendering: wlr_scene plus a custom canvas pass

- wlr_scene supports natively: integer position, integer dest-size scale,
  90-degree `wl_output_transform` rotation, opacity, crop, filter mode,
  per-output damage ring, visibility culling, texture caching, direct
  scanout, dmabuf feedback (wlroots.md, canvas-compositing.md).
- Not supported: arbitrary rotation, non-uniform or float zoom, perspective.
  A custom render pass drawing each visible surface as a quad with a camera
  matrix is mandatory for the canvas layer (canvas-compositing.md).
- Strategy: keep wlr_scene for the plain window/desktop layer and damage
  plumbing; add a camera pass that reuses the cached `wlr_texture` objects
  (zoom without content change costs only a re-draw, not a re-upload).
  Keep world state in `double`, snap to pixels only at draw; rebase the
  camera near the origin to avoid fp32 jitter (canvas-compositing.md).
- For sharp zoom, advertise `scale = max(1, camera zoom)` via
  viewporter/fractional-scale so clients redraw at native resolution
  (canvas-compositing.md).

### Named risks

1. **Zig churn breaks the scanner.** Every zig release since 0.13 required
   a zig-wayland update (0.13→v0.2.0, 0.14→v0.3.0, 0.15→v0.4.0,
   0.16→v0.6.0). Pin the dependency hash and upgrade deliberately
   (zig-wayland.md).
2. **zig-wlroots coverage is river-driven.** Bindings exist only for wlroots
   APIs river uses; missing parts must be added by hand. The wlroots C API is
   unstable (`WLR_USE_UNSTABLE`) and changes between releases
   (zig-wayland.md, wlroots.md).
3. **The custom canvas pass loses wlr_scene guarantees.** Rotation/float
   zoom bypasses the scene's damage ring and frame-done plumbing; damage
   accumulation, culling, and input remapping must be rebuilt in world space
   (canvas-compositing.md).

## Phased roadmap

1. **Scaffold** — done (2026-08-07): zig 0.16 project, zig-wayland v0.6.0
   pinned dep, Scanner wired, buildable skeleton generating `wayland.zig`.
2. **Spec codegen pipeline** — done (2026-08-07): wlroots target = 0.20
   line (clone refreshed at 0.20.2); wayland.xml, xdg-shell, viewporter,
   fractional-scale, wlr-layer-shell vendored in `protocols/`; server+
   client namespaces generated (wl_compositor v7 … zwlr_layer_shell_v1 v5);
   explicit XML paths — no pkg-config needed for codegen, only for linking
   libwayland (devenv.nix sets PKG_CONFIG_PATH).
3. **Minimal headless compositor** — done (2026-08-07, = spec M1): headless
   backend, wl_registry globals, xdg-shell configure/ack, shm buffers, own
   zig test client (no weston needed); pixman renderer; verified end-to-end
   (client roundtrip → surface mapped → rendered, leak-free).
4. **Output rendering with wlr_scene** — done (2026-08-07, own scene graph +
   output module): scene tree, frame_done pacing, presentation timing,
   damage ring; verified on the headless + DRM backends (VM-DRM-E2E-OK,
   2026-08-09).
5. **Canvas rendering spike** — IN PROGRESS (2026-08-09): custom render pass
   (`src/renderer/canvas.zig`) + camera (`src/scene/camera.zig`, world
   `f64` → screen, pan/zoom/rotation, world-space culling, cached-texture
   reuse). Deliverable: arbitrary scale/rotation proven on a surface.
6. **Input remapping** — IN PROGRESS (2026-08-09, with 5): pointer screen
   coords → inverse camera → world → surface-local; focus rules in world
   space; camera-aware `frame_done` during pan. Deliverable: click, scroll,
   and drag correct through the camera.
7. **Client-side scaling** — Implement viewporter and fractional-scale-v1;
   advertise `scale = max(1, zoom)`. Deliverable: sharp zoom for
   conforming clients.
8. **Dynamicland-style usage experiments** — Spatial persistence (position
   is state), live always-current objects, in-place authorability, shared
   presence. Deliverable: a usage-layer prototype validating the concepts
   from dynamicland.md.

## Open questions and risks

- **wlroots version target — resolved.** Current stable is 0.20.2 (master
  0.21.0-dev); zig-wlroots pins v0.20.1; both local clones refreshed
  2026-08-07 (wlroots 0.20.2, zig-wayland v0.6.0). Target the 0.20 line
  (wlroots.md, zig-wayland.md).
- **C-table workaround (zig issue #131) — resolved.** Gone since zig-wayland
  v0.3.0; current main and `example/hello` build without it (zig-wayland.md).
- **Weston test harness — resolved.** Verified: in-process fixture compositor
  via `wet_main`, weston-test protocol for input injection, screenshot
  capture, TAP output (wayland-compositor-basics.md).
- **Smithay pass API — resolved.** The pass object is the `Frame` trait
  (no `RenderPass` type); documented in smithay.md. Relevant only if the
  Rust path re-opens.
- **Damage under camera motion.** Whole-screen damage on pan is simplest and
  correct but costly; partial damage needs a world→screen region transform
  with output-scale rounding (canvas-compositing.md).
- **Blurry zoom for legacy clients.** Clients without viewporter or
  fractional-scale support stay blurry at high zoom; accept or filter
  NEAREST. Exact client behavior across toolkits at zoom > 1 is
  `[UNVERIFIED]` (canvas-compositing.md).
- **fp32 vertex precision.** Jitter appears around ~1e5 px from the origin;
  rebase the camera and compute world→screen in double before rounding
  (canvas-compositing.md).
- **Input remapping bugs.** wayvr documents mouse-mapping failures; add a
  debug overlay showing world coords early in phase 6 (canvas-compositing.md).
- **Realtalk implementation details are not public.** Anything beyond the
  FAQ-level description is `[UNVERIFIED]`; the usage layer must be designed
  from public narrative, not source (dynamicland.md).
- **zio interop spike.** If companion services arrive, `zio.ev` embedding
  against the compositor's real fds needs a one-day proof before adoption
  (zio.md).

## Repo references

- Foreign clones (read-only, `~/projects/<host>-<owner>-<repo>`):
  `freedesktop-wlroots-wlroots` (0.20.2), `github-Smithay-smithay` (v0.7.0),
  `codeberg-ifreund-zig-wayland` (v0.6.0, zig 0.16),
  `freedesktop-wayland-wayland` (1.26.0), `freedesktop-wayland-wayland-protocols`
  (1.49), `freedesktop-wayland-weston` (16.0.0), `codeberg-ifreund-zig-wlroots`
  (v0.20.1), `codeberg-river-river` (v0.4.0), `github-WayfireWM-wayfire`
  (v0.11.0), `github-YaLTeR-niri` (v26.04), `github-swaywm-sway` (1.11-rc2),
  `github-labwc-labwc` (0.20.1), `github-wayvr-org-wayvr` (v26.7.1).
  Linked-lib sources (pinned to the build versions, 2026-08-09):
  `gitlab-freedesktop-mesa-drm` (libdrm-2.4.134), `gitlab-freedesktop-libinput-libinput`
  (1.31.3), `github-xkbcommon-libxkbcommon` (xkbcommon-1.13.2), `github-raysan5-raylib`
  (6.0), `github-systemd-systemd` (v261.1), `gitlab-freedesktop-pixman-pixman` (0.46.4).
  Smithay's protocol crate: `github-Smithay-wayland-rs` (master; smithay v0.7.0 pins
  wayland-server 0.31.13).
- Architecture questions: deepwiki MCP (smithay and wlroots have wikis).
- VCS: jj only, never git.
