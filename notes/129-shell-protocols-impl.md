# 129-shell-protocols-impl — xdg_activation_v1 + zxdg_decoration_manager_v1

Facts first. Scope: new modules src/shell/xdg_activation.zig and
src/shell/xdg_decoration.zig, wiring in src/server/main.zig and
src/root.zig. Audit-verified against wlroots (types/wlr_xdg_activation_v1.c,
types/wlr_xdg_decoration_v1.c), smithay (xdg_activation/, shell/xdg/
decoration.rs), KWin (xdgactivation_v1.cpp, xdgdecoration_v1.cpp +
xdgshellwindow.cpp); XML ground truth in protocols/wayland-protocols.

## Files changed
- src/shell/xdg_activation.zig (new): XdgActivation global +
  ActivationToken state machine + 4 wire tests.
- src/shell/xdg_decoration.zig (new): XdgDecoration manager + Decoration
  + 5 wire tests.
- src/server/main.zig: init blocks after the seat init (lines ~358-363),
  ServerState fields (~151-154), listener fields (~305-306), state literal
  (~505-508, ~524-525), signal wiring (~561-564), handlers onRequestActivate
  / onDecorationMode / modeLabel (~847-891).
- src/root.zig: exports `xdg_activation` / `xdg_decoration` (after
  layer_shell export), comptime refs `_ = xdg_activation; _ =
  xdg_decoration;`.

## xdg_activation_v1 v1 (XdgActivation)
- Global: destroy, get_activation_token, activate(token, surface). No
  global events. Bindings: server.xdg.ActivationV1 / ActivationTokenV1
  (xdg_activation.zig:128-160).
- Token requests: set_serial/set_app_id/set_surface/commit/destroy;
  event done(token). Error enum: already_used=0 (xdg_activation.zig:205-237).
- Model decisions (documented in the module header, xdg_activation.zig:1-35):
  - (a) commit is one-shot: any set_serial/set_app_id/set_surface/commit
    after commit posts already_used=0 on the token resource
    (xdg_activation.zig:206-235).
  - (b) commit-time validation: a set serial must equal the seat's last
    serial (data_device.zig equality rule, data_device.zig:285-295;
    wlroots uses a per-client serial ring — simplification documented);
    a set surface must be the seat's current keyboard- or pointer-focused
    surface. On failure done() still fires with a random 32-hex token, the
    token is dropped from the registry (never registered), activate() of it
    is silently ignored (xdg_activation.zig:243-258, 277-290).
  - (c) activate with an unknown token: silently ignored, never an error
    (xdg_activation.zig:169-188).
  - (d) single use: a used token is destroyed after the delivery; a second
    activate with the same token is ignored (wlroots model,
    xdg_activation.zig:186-188).
  - (e) token expiry: 30s one-shot wire event-loop timer per token
    (token_timeout_ms, xdg_activation.zig:37; addTimer/timerUpdate/remove
    per backend/headless.zig:79-108; libwayland 1.24+ disarms timers
    before dispatch and ignores the callback return value — event-loop.c
    wl_timer_heap_dispatch; the callback removes the source and destroys
    the token, xdg_activation.zig:299-305). Timer fires only on loop
    dispatch with a real timeout — never in tests (pump uses dispatch(0)).
- Compositor hook: `events.request_activate` — Signal(*ActivateRequest),
  payload { token: []const u8 (borrowed, valid only during emit),
  surface: *Surface wrapper } (xdg_activation.zig:49-53, 73). main.zig
  subscribes (main.zig:561) and logs/accepts; focus policy out of scope
  (onRequestActivate, main.zig:850-861).
- Token string: 32 lowercase hex chars from 16 PRNG bytes. [INFERENCE:
  wlroots uses getrandom(2); zig 0.16 std has no direct CSPRNG
  (std.crypto.random removed), so Xoshiro256 seeded from the monotonic
  clock + a counter stands in — note in xdg_activation.zig:311-322.]
- String args (set_app_id, activate token) span'ed via std.mem.span; app_id
  is dup'ed into the token and freed on destroy (xdg_activation.zig:214-223,
  264-271).

## zxdg_decoration_manager_v1 v1 (XdgDecoration)
- Manager: get_toplevel_decoration(toplevel), destroy. No manager events.
  Bindings: server.zxdg.DecorationManagerV1 / ToplevelDecorationV1;
  error enum unconfigured_buffer=0 already_constructed=1 orphaned=2
  invalid_mode=3; Mode client_side=1 server_side=2 (xdg_decoration.zig:20-25).
- Semantics (documented in module header, xdg_decoration.zig:1-32):
  - (a) v1 rule: a toplevel that already committed a buffer posts
    unconfigured_buffer=0 on the new decoration resource
    (xdg_decoration.zig:174-178; check is surface.buffer != null, the
    committed-buffer mirror, surface.zig:176).
  - (b) a second decoration on the same toplevel posts already_constructed=1
    (xdg_decoration.zig:180-185).
  - (c) toplevel destroyed before its decoration: orphaned=2 posted on the
    decoration resource. The module tracks the toplevel's lifetime via
    XdgToplevel.events.destroy (xdg_decoration.zig:189-193, 277-286).
    Invariant: dec.toplevel == null implies the destroy listener is
    detached, so decorationDestroy never touches a freed toplevel
    (xdg_decoration.zig:263-275).
  - (d) set_mode with a value outside {client_side, server_side} posts
    invalid_mode=3 (xdg_decoration.zig:240-247). DIVERGENCE: the XML
    mandates this error but wlroots/smithay/KWin do not raise it — this
    implementation raises it per the XML (documented at
    xdg_decoration.zig:24-27 and in the set_mode handler).
  - (e) set_mode/unset_mode are forwarded as `events.request_mode`
    (Signal(*RequestMode), payload { decoration, mode: ?Mode }; null for
    unset_mode); the compositor replies with Decoration.sendConfigure,
    re-sent on every set_mode/unset_mode (xdg_decoration.zig:249-256).
    No initial configure: a client that never sets a mode draws
    client-side (XML default).
- Decoration is destroyed by the client (or with the client). Error paths
  post on the NEW decoration resource because the error enum lives on
  xdg_toplevel_decoration (wlroots posts there too; xdg_decoration.zig:157-161).
- Compositor hook wiring (main.zig):
  - onDecorationMode (main.zig:864-882): placeholder policy — server_side
    if the decorated toplevel is the seat's keyboard-focus surface, else
    client_side; then req.decoration.sendConfigure(mode). Documented
    placeholder: the compositor has no real decorations (note here).
  - modeLabel helper for logging (main.zig:884-892).

## Wiring contract
- init signatures match the spec lines: XdgActivation.init(allocator, io,
  log_cfg, display, seat, compositor) — seat used for serial/focus
  validation, compositor used to resolve wl_surface resources
  (xdg_activation.zig:75-90, 324-331). XdgDecoration.init(allocator, io,
  log_cfg, display, shell) (xdg_decoration.zig:102-117). Defers registered
  right after init, so deinit runs before shell/seat deinit (LIFO).
- Signal payloads are non-const pointers: wire.Signal(*T) — the generated
  emit requires T coercible to ?*anyopaque, and *const T does not coerce
  (const-discard error, verified with zig 0.16.0). main.zig listener types
  follow (main.zig:304-305).

## Verification (scratch harness in /tmp, not the repo gates)
- Both modules + root.zig exports typecheck against freshly regenerated
  bindings (zig-wayland scanner CLI over the same XML set + targets as
  build.zig; the project cache had no regenerated bindings yet).
- Tests: 9 new tests pass leak-free (4 activation: commit->done->activate
  once + reuse ignored, bogus serial -> invalid done token + ignored
  activate, post-commit set_app_id -> already_used=0, unknown token -> no
  error; 5 decoration: happy path get->set_mode->request_mode->configure
  echo + unset_mode, already_constructed=1, invalid_mode=3, orphaned=2,
  unconfigured_buffer=0).
- Cross-worker findings (reported, fixed by the owners):
  - W2: WmBaseState freed at wm_base resource destroy, but libwayland
    destroys a client's resources in creation order (wl_map_for_each,
    object-id order), so the binding goes FIRST — xdgSurfaceDestroy read a
    freed wm_base (GP fault). Fixed with a `dead` flag + deferred free.
    Also W2's defunct_surfaces test asserted the error interface on an
    already-destroyed proxy ("[destroyed object]").
  - W1: unused local constant in layer_shell.zig:728 test code.
  - W2: `_ = toplevel_res;` became a pointless discard after their
    postError addition.

## Out of scope (documented)
- Focus policy for activation (main.zig logs/accepts only).
- Decoration mode policy is a placeholder (focus-based, no real
  decorations).
- Per-client serial ring (single seat; equality with last_serial).
