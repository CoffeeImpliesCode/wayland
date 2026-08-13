# Classical Wayland Client Conformance

Research note. Date: 2026-08-14.
Goal: run a small set of classical Wayland test clients against the
compositor, fix what breaks, and verify identical behavior across the
nested / headless / raylib backends.

## Method

- Harness: `scripts/run-client.sh <client>` starts a parent weston
  (headless, socket `weston-parent`), launches the nested server
  (`WAYLAND_BACKEND=nested`), reads the `WAYLAND_SOCKET=` stdout line,
  runs the client against it under `timeout`, and reports PASS/FAIL.
- The nested backend's parent weston provides the parent surface; the
  server's own socket serves the test clients.
- Verdict: exit 124 (ran the full window without dying) + the server
  log shows at least one `render frame=… surfaces=N` with N>=1 (the
  client actually mapped and was composited — survival alone is a weak
  verdict). Roundtrip clients (wl-copy/wl-paste, grim) have explicit
  PASS criteria.
- Backend parity: the same client set run with `WAYLAND_BACKEND=nested`,
  `headless`, `raylib`; "identical behavior" = the client maps, renders,
  and completes its wire handshake on every backend.

## Results

### Globals (wayland-info)

16 interfaces announced; versions match the build.zig maxima:
wl_shm v2, wp_presentation v2, wl_compositor v7, xdg_wm_base v7,
zwlr_layer_shell_v1 v5, wl_seat v10 (pointer+keyboard, repeat 25/600),
xdg_activation_v1 v1, zxdg_decoration_manager_v1 v2,
wp_fractional_scale_manager_v1 v1, wp_viewporter v1, wl_subcompositor v1,
wl_data_device_manager v3, zwp_primary_selection_device_manager_v1 v1,
zwlr_screencopy_manager_v1 v3, wl_output v4.

### Classical clients (nested backend)

| Client | Verdict | What it exercises |
|---|---|---|
| weston-terminal | PASS (2 frames) | xdg toplevel configure/ack, keyboard keymap |
| weston-flower | PASS | frame-callback animation loop |
| weston-clickdot | PASS | pointer + serial roundtrip |
| weston-eventdemo | PASS | full input event stream |
| weston-smoke | PASS (117 frames) | multi-surface scene |
| weston-image | PASS | xdg + shm buffer + image decode |
| weston-resizor | PASS | xdg resize negotiation |
| weston-dnd | PASS | drag-and-drop (F-SEL-1 state machine) |
| weston-presentation-shm | PASS (151 frames) | presentation feedback timing |
| wev | PASS | input viewer (binds all seat objects) |
| wl-copy/wl-paste | PASS roundtrip | data_device selection deliver+receive |
| grim | PASS (1280x720 PNG, 7620 B) | zwlr_screencopy capture |

### Fixes landed during this round

1. **Synth input targeted a fixed coordinate (50,50).** The headless
   input E2E (WAYLAND_SYNTH_INPUT=1) clicked at (50,50), which misses
   1x1 surfaces (wl-clipboard's invisible toplevel) — wl-copy never got
   keyboard focus, so no serial was minted and `set_selection` was never
   sent. Fix: click the FIRST not-yet-clicked mapped surface's center
   (per-surface tracking via `synth_clicked` map). This also makes
   multi-client sessions (selection roundtrips) work: each new client's
   surface gets focus + a serial. main.zig `maybeSynthInput`.
2. **grim captured 0x0 PNG.** grim sizes the capture from the output's
   LOGICAL geometry via `zxdg_output_manager_v1` — which the compositor
   did not implement, so grim guessed an empty layout (warning
   "zxdg_output_manager_v1 isn't available, guessing the output
   layout") and wrote a 0x0 PNG even though the wire buffer event
   carried 1280x720. Fix: implemented `zxdg_output_manager_v1` v3
   (src/shell/xdg_output.zig): manager global, per-wl_output
   zxdg_output_v1 with logical_position (0,0 single-output),
   logical_size (mode/scale), name/description (v2+), done; the object
   dies with its wl_output; foreign outputs get an inert object.
   Protocol XML vendored from wayland-protocols 1.49
   (protocols/wayland-protocols/unstable/xdg-output/), scanner +
   generate in build.zig, root.zig export, main.zig init/deinit.
   grim now produces a real 1280x720 PNG.

### Backend parity

| Client | nested | headless | raylib |
|---|---|---|---|
| weston-terminal | Y (2f) | Y (2f) | Y (2f) |
| weston-flower | Y (1f) | Y (1f) | Y (1f) |
| weston-clickdot | Y (1f) | Y (1f) | Y (1f) |
| weston-smoke | Y (117f) | Y (150f) | Y (148f) |
| weston-dnd | Y (1f) | Y (1f) | Y (1f) |
| weston-presentation-shm | Y (151f) | Y (175f) | Y (165f) |
| wev | Y | Y | Y |
| wayland-info | Y | Y | Y |
| selection roundtrip | PASS | PASS | PASS |
| grim capture | PASS | PASS | PASS |

(f = rendered frames in the 4-5s window; smoke/presentation are
animation clients so their frame counts scale with the timer backend.)

All three backends produce identical client-visible behavior: same
global set, same configure/ack handshakes, same selection and capture
paths. The frame-count differences are timer pacing, not behavioral.

## Environment notes

- weston 15.0.1 clients from the devenv. weston-simple-shm /
  weston-simple-egl are NOT packaged in 15.0.1 (removed upstream);
  the classical set above covers the same protocol surface.
- Reference weston 15 headless does not support zwlr_screencopy_v1
  ("compositor doesn't support the screen capture protocol"), so grim
  could not be control-tested against it; the grim wire trace
  (buffer(1280,720,5120) -> copy -> flags -> ready) plus a valid PNG
  is the verification.
- Selection roundtrips need WAYLAND_SYNTH_INPUT=1 (keyboard focus +
  serial) and WAYLAND_WATCHDOG_DISABLE=1 (the 5s no-frame watchdog
  stops the server between clients).

## Source list

- wlroots wlr_xdg_output_v1.c (xdg-output semantics); the vendored XML
  is from wayland-protocols 1.49 (unstable/xdg-output).
- grim 1.5.0 (emersion/grim, cloned for diagnosis): sizes the PNG from
  the xdg-output logical extents, not the screencopy frame buffer event
  — the missing-protocol failure mode.
