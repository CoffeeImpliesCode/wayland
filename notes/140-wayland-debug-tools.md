# 140: Wayland debug tools and protocol conformance testing

Audit date: 2026-08-12. Sources: the official wayland.freedesktop.org
"Wayland debugging extras" page (https://wayland.freedesktop.org/extras.html),
repo READMEs (verified via browser), and the read-only clones:
freedesktop-wayland-wayland (1.26.0), freedesktop-wayland-weston (16.0.0),
freedesktop-wlroots-wlroots (0.20.2), github-swaywm-sway (1.11-rc2),
github-Smithay-smithay (v0.7.0), invent-kde-org-plasma-kwin (master),
gitlab-freedesktop-libinput-libinput (1.31.3). All claims cite their source.

Verdict: the ecosystem has a full debug stack, from the built-in libwayland
logger up to wire-level middle-man dumpers and compositor-independent
conformance suites. For this repo, the actionable pieces are: (a) wire
tracing via `WAYLAND_DEBUG` and `wayland-debug` (wmww) against our server,
(b) `wlcs` as an external conformance gate once the compositor runs
standalone, (c) the weston test-suite pattern (in-process test protocol +
headless backend) as the model for our own E2E, and (d) KWin's autotest
layout for per-interface unit coverage.

## 1. Built-in: libwayland protocol logging

- `WAYLAND_DEBUG=1` (or `=client` / `=server`) makes libwayland print every
  wire message to stderr — client side: wayland-client.c:1247
  (`getenv("WAYLAND_DEBUG")`); server side: wayland-server.c:1283. Weston's
  manpage documents it: "causes libwayland to print the live protocol to
  stderr" (weston.man:369-372).
- Programmatic logging: `wl_display_set_protocol_logger` — server-side
  implementation lives in wayland-server.c (protocol_loggers list :102,
  hook :180-190, init :1323). The client side has no such public hook
  (verified: no `set_protocol_logger` in wayland-client.c); client tracing
  is env-var only, or via the middle-man tools below.
- Limits (per wayland.freedesktop.org/extras.html): the env dump is
  unstructured text, message names but no argument names, and it only sees
  the libwayland layer — client-side toolkits that bypass or reimplement
  the wire (GTK's own connection handling in some paths) are invisible.

## 2. Wire-level dumpers (middle-man tools)

Official extras page lists these; all sit between the compositor and the
client(s) and dump both directions:

- **wayland-tracker** (Intel, Haskell, archived 2022-08-05 per repo banner):
  MIT; binary/text/JSON output; middle-man for a single client. JSON output
  is the differentiator — feedable to analysis tooling
  (github.com/intel/wayland-tracker).
- **wayland-tracer** (Boyan Ding, C): MIT; binary + human-readable output
  driven by XML protocol definitions; runs as middle-man for a single client
  OR as a middle-man Wayland server. `wayland-tracer -d wayland.xml --
  PROGRAM` (github.com/dboyan/wayland-tracer README).
- **wlanalyzer / wldump** (C++): MIT; human-readable output; middle-man for
  a single client.
- **wldbg** (C): connection processor; runs functions on messages or
  gdb-like interactive mode; can take over new connections to a compositor.
- **wl-proxy** (Rust, wmww): proxy library that intercepts and manipulates
  messages, incl. merging multiple clients over one compositor connection.
  Companion tools: **wl-veil** (hide globals / downgrade versions) and
  **wl-format-filter** (hide buffer formats / DRM modifiers) — useful for
  testing client fallback behavior. (wl-proxy repo moved; the extras page
  description is the citation.)
- **wlhax**: TUI acting as a Wayland proxy; displays connection state and
  the current surface tree.

## 3. Protocol debugger: wayland-debug (wmww)

github.com/wmww/wayland-debug (MIT, ~91 stars). A CLI for viewing,
filtering, and setting breakpoints on Wayland protocol messages:

- Run mode: `wayland-debug -r program` — runs the program with
  `WAYLAND_DEBUG=1` and parses the output; a patched libwayland on
  LD_LIBRARY_PATH fixes the multi-connection ambiguity.
- Filtering: `-f 'A: wl_pointer, wl_surface.[commit, destroy]'`.
- GDB mode: `-g` — breakpoints on protocol messages (`-b 'xdg_*.configure,
  12'`); needs a debug-symbol libwayland (snap ships one).
- Pipe/file modes: parses `WAYLAND_DEBUG=1 program 2>&1 | wayland-debug -p`
  or a log file.

## 4. Introspection

- **wayland-info** (wayland-utils package): lists all globals a compositor
  advertises + interface details (wl_seat caps, wl_shm formats, monitor
  make/model). "works on any compositor" (extras page).
- **GammaRay**: Qt introspection incl. a QtWayland module; shows connected
  clients, resources, protocol flow, via the libwayland-server introspection
  API (extras page).
- **wev** (sircmpwn, git.sr.ht/~sircmpwn/wev, packaged in Arch extra 1.1.0):
  opens an xdg-shell toplevel and prints events; `-g` prints globals, `-f`
  filters interfaces/events, `-M` dumps the keymap. Input-path debugging.

## 5. Compositor-side debug surfaces (reference compositors)

- **weston**: `--debug` enables the `weston_debug_v1` protocol global
  (weston.man:151-154); `--debug-scopes` filters which log scopes are
  advertised (:165-167). The protocol (protocol/weston-debug.xml, internal,
  version 1) streams debug text to any client; the `weston-debug` CLI client
  (clients/weston-debug.c) subscribes. Behind it: the `weston_log_scope`
  subscription machinery (libweston/weston-log-internal.h) and the timeline
  (libweston/timeline.h) with perfetto output hooks. Warning in the XML:
  the interface "by design allows a denial-of-service attack" — debug
  scopes must not be enabled in production.
- **wlroots**: scene-level damage debugging via env vars (docs/env_vars.md,
  verified in the 0.20.2 clone):
  - `WLR_SCENE_DEBUG_DAMAGE=none|rerender|highlight` (types/scene/
    wlr_scene.c:190-197),
  - `WLR_SCENE_DISABLE_DIRECT_SCANOUT`, `WLR_SCENE_DISABLE_VISIBILITY`,
    `WLR_SCENE_HIGHLIGHT_TRANSPARENT_REGION`,
  - `WLR_RENDERER`/`WLR_RENDERER_FORCE_SOFTWARE`/`WLR_EGL_NO_MODIFIERS`,
  - `WLR_DRM_NO_ATOMIC` (legacy KMS instead of atomic),
  - `WLR_DRM_DEVICES`, `WLR_DRM_NO_MODIFIERS`, `WLR_DRM_FORCE_LIBLIFTOFF`,
  - `WLR_BACKENDS`, `WLR_NO_HARDWARE_CURSORS`, `WLR_XWAYLAND`,
  - headless/wayland/x11 backend output counts (`WLR_HEADLESS_OUTPUTS` etc.).
- **sway**: logs env/args at startup (sway/main.c:66), `swaymsg` IPC client
  (swaymsg/) for runtime inspection; `SWAYSOCK` selects the socket.
- **KWin**: qt categorized logging (`qCDebug(KWIN_CORE)`, display.cpp:252);
  autotests under autotests/wayland/{client,server} with per-interface
  server tests (test_seat, test_viewporter_interface, test_screencast,
  test_datacontrol_interface, test_textinputv3_interface, ...) — the model
  for per-interface unit testing against the protocol.

## 6. Input-path debugging (libinput tools)

gitlab-freedesktop-libinput-libinput/tools/ (1.31.3): `libinput-debug-events`
(real-time event stream), `libinput-debug-gui`, `libinput-debug-tablet(-pad)`,
`libinput-list-devices`, `libinput-record`/`libinput-replay` (capture +
deterministic replay — useful for reproducing input bugs),
`libinput-analyze-*` (recordings analysis), `libinput-measure-*` (device
calibration/quirks).

## 7. Protocol conformance / adherence testing

- **wlcs** (canonical/wlcs, github.com/canonical/wlcs, ~59 stars,
  GPL-2/3): "aspires to be a protocol-conformance-verifying test suite
  usable by Wayland compositor implementors". Differentiator: compositors
  link an in-process integration module (`wlcs_server_integration` symbol,
  include/wlcs/display_server.h) instead of speaking a test protocol over
  the wire — same address space, consistent clock, no IPC happens-before
  ambiguity. Tests include toplevel image capture (tests/). It grew out of
  porting the Weston suite for Mir.
  - smithay wires it: compile_wlcs.sh pins WLCS_SHA=2b385328 and builds the
    suite against the compositor (verified in the v0.7.0 clone).
- **Weston test suite** (freedesktop-wayland-weston/tests/, 81 test files in
  16.0.0): the de-facto reference. Uses the internal `weston_test` protocol
  (protocol/weston-test.xml: `weston_test` + `weston_test_runner`
  interfaces — surface screenshots, output capture, repaint filters,
  explicit test failure reporting) + a headless backend. Coverage: xdg-shell,
  viewporter, subsurface, presentation, commit-timing, bad-buffer,
  constraints, pointer/touch, output transforms, alpha modifiers, color
  management, single-pixel-buffer. Clients: clients/ has the test patterns
  (screenshot.c, eventdemo.c, simple-timing.c, ...).
- **wlroots**: no test suite in 0.20.2 (tests/ was removed; repo has
  examples/ + tinywl only — verified by listing). Its historical suite was
  the wlcs-style in-process model. Conformance burden shifted to wlcs.
- **KWin**: autotests/wayland/server/*.cpp per-interface server tests (see
  §5) plus integration tests under autotests/ (drm/, effect/, integration/,
  libinput/).
- **Weston/WLCS history note** (wlcs README): earlier attempts — the
  "Wayland Functional Integration Test Suite" — used wire protocols to
  interrogate the compositor and died; the in-process integration-module
  approach is what makes wlcs compositor-agnostic.

## 8. Relevance to this repo

Our harness today: `rtprobe` (build.zig:248-252, adversarial protocol
probe against a live server), vm-e2e.sh / vm-drm-e2e.sh (headless VM runs),
uinput-devices.py (synthetic input), in-module wire tests, `WAYLAND_DEBUG`
available free from libwayland for any server run (wayland-server.c:1283).

- Nearest-term wins:
  1. `WAYLAND_DEBUG=server zig build run-server` — zero-cost wire trace of
     our own server for debugging our protocol modules.
  2. `wayland-debug -r` against our server for filtered message views once
     the server runs standalone (it parses the same WAYLAND_DEBUG stream).
  3. `wayland-info` against our server to validate global advertisement +
     versions (our versioning round, notes/130) from an external client.
- Conformance: wlcs is the only compositor-agnostic conformance suite; our
  single-process lib architecture (server + in-memory clients in tests) is
  actually closer to the wlcs in-process model than to weston's wire test
  protocol — an integration module is a plausible future gate once the
  server runs standalone outside the VM harness.
- Model notes: weston's weston_test protocol pattern (internal test global
  gated behind --debug) is the reference for adding our own test hooks
  without polluting the wire; KWin's per-interface server autotests mirror
  our in-module wire tests; libinput-record/replay could replace parts of
  uinput-devices.py for deterministic input repro.

## Sources

- https://wayland.freedesktop.org/extras.html (official tool list; the
  citation for wayland-tracker/tracer/wlanalyzer/wldbg/wl-proxy/wl-veil/
  wl-format-filter/wlhax/GammaRay/wayland-info/wflinfo)
- https://github.com/wmww/wayland-debug (README)
- https://github.com/canonical/wlcs (README)
- https://github.com/dboyan/wayland-tracer (README)
- https://github.com/intel/wayland-tracker (README; archived banner)
- https://man.archlinux.org/man/wev.1.en (wev 1.1.0)
- ~/projects/freedesktop-wayland-wayland/src/{wayland-client,wayland-server}.c
- ~/projects/freedesktop-wayland-weston/{protocol/weston-debug.xml,
  protocol/weston-test.xml, clients/weston-debug.c, libweston/timeline.h,
  libweston/weston-log-internal.h, man/weston.man, tests/}
- ~/projects/freedesktop-wlroots-wlroots/{docs/env_vars.md,
  types/scene/wlr_scene.c, include/wlr/backend/}
- ~/projects/github-Sway-smithay/compile_wlcs.sh (WLCS pin), smithay repo
  layout (test_clients/, examples/)
- ~/projects/invent-kde-org-plasma-kwin/{src/wayland/display.cpp,
  autotests/wayland/{client,server}/}
- ~/projects/github-swaywm-sway/{sway/main.c, swaymsg/}
- ~/projects/gitlab-freedesktop-libinput-libinput/tools/
