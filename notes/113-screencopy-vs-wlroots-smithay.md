# Screencopy — wlroots/smithay diff

zwlr_screencopy_manager_v1 v3, shm-only, synchronous copy.
Reference: wlroots types/wlr_screencopy_v1.c (0.20.2).
smithay: no zwlr_screencopy. Only ext-image-copy-capture-v1 (src/wayland/image_copy_capture/mod.rs:1-3, wired at src/wayland/mod.rs:71). No zwlr-screencopy protocol XML in smithay protocols dir; no "screencopy" code outside image_copy_capture/mod.rs. All smithay rows below are N/A for this reason.

## Surface

Public items in src/screencopy.zig (grep `pub fn` / `pub const`):

- src/screencopy.zig:28 `pub const screencopy_version: u32 = 3`
- src/screencopy.zig:30 `pub const Screencopy = struct` (callbacks: get_framebuffer :38, owns_output :41, clock :44)
- src/screencopy.zig:47 `pub fn init(...)`
- src/screencopy.zig:86 `pub fn deinit(self: *Screencopy) void`

Protocol logic lives in private handlers: bindManager :106, managerRequest :114, capture :126, frameRequest :202, copyFrame :220.

## Comparison

wlroots ref = types/wlr_screencopy_v1.c, header = include/wlr/types/wlr_screencopy_v1.h.

1. screencopy_version (:28) — protocol version 3. wlroots: `#define SCREENCOPY_MANAGER_VERSION 3` at wlr_screencopy_v1.c:17. smithay: N/A. Verdict: same.

2. Screencopy struct (:30) — manager state + compositor callbacks (framebuffer source, output ownership, clock). wlroots: wlr_screencopy_manager_v1 at wlr_screencopy_v1.h:24-43 and wlr_screencopy_frame_v1 at :45-68 (our FrameState is the private analogue). smithay: N/A. Verdict: close — same roles, ours injects callbacks instead of reading wlr_output/renderer.

3. init (:47) — allocates manager, registers global, wires bind handler. wlroots: wlr_screencopy_manager_v1_create at wlr_screencopy_v1.c:696-718 (wl_global_create at :703-705). smithay: N/A. Verdict: close.

4. deinit (:86) — removes global, frees manager. wlroots: handle_display_destroy at wlr_screencopy_v1.c:684-694 plus manager_handle_resource_destroy :649-654. smithay: N/A. Verdict: close.

5. capture() (:126) — creates frame resource, clamps region, sends buffer (+buffer_done). Ours: sends ARGB8888 + tight stride at :198, buffer_done only for v3 clients at :199. wlroots: capture_output at :486-606 — send_buffer at :587-589 with renderer preferred_read_format :543 and min_stride :585; sends linux_dmabuf + buffer_done for v3 at :591-596; fails disabled outputs at :508-511. smithay: N/A. Verdict: divergent — fixed ARGB8888 vs renderer format; no linux_dmabuf event; no transform/scale on box (:576-580).

6. copyFrame() timing (:220) — copies synchronously inside the copy request. Ours: row-wise @memcpy at :289 from current framebuffer, then damage/flags/ready at :297-301. wlroots: defers to next output commit — output_commit listener at :434-435, wlr_output_update_needs_frame :440, lock_attach_render :442; actual copy in frame_handle_output_commit :283-347 (shm copy :193-231, dma copy :234-281). smithay: N/A. Verdict: divergent — commit-deferred vs request-time copy.

7. copy_with_damage (:208-210) — routed to copyFrame, identical to copy. wlroots: sets with_damage at :456, waits until accumulated damage is non-empty at :302-308, sends per-box damage at :156-181. smithay: N/A. Verdict: divergent — damage semantics ignored.

8. Buffer validation (:237-276) — shm-only, checks dims :241-244, ARGB8888 format :254-257, never checks stride (writes tight rows, dst_stride recomputed :284). wlroots: accepts dmabuf or data-ptr at :381-412, dims :380-382, dmabuf format :386-394, shm format :396-404, stride :418-421. smithay: N/A. Verdict: divergent — no stride validation, no dmabuf path.

9. Region handling (:148-173) — clamps logical coords against framebuffer; out-of-range silently clamped. wlroots: transforms box by output transform + scale at :576-580; fails frame when box exceeds source buffer at :313-319. smithay: N/A. Verdict: divergent — no transform/scale, clamp instead of fail.

10. overlay_cursor — ignored: arg dropped in managerRequest at :117-123; module doc states cursor is already composited into the framebuffer by the scene (:5-6). wlroots: honors flag, locks software cursors at :443-446 (unlock :142-144). smithay: N/A. Verdict: missing — flag accepted but has no effect.

11. Completion events (:297-301) — flags, full-region damage, ready with compositor clock callback. wlroots: flags 0 at :334, damage :336, ready with output commit timestamp event->when at :337, failed on errors :341-345. smithay: N/A. Verdict: close — same event order; timestamp source differs (copy time vs commit time).

## Gaps

1. Synchronous copy at request time (screencopy.zig:220-301) vs commit-deferred (wlr_screencopy_v1.c:434-435, 440-442): capture can sample a mid-render or stale framebuffer; wlroots guarantees a presented frame.
2. copy_with_damage is a no-op (screencopy.zig:208-210): no damage accumulation or wait (wlr_screencopy_v1.c:302-308); clients get no per-box damage (wlr_screencopy_v1.c:156-181).
3. No linux-dmabuf capture: no linux_dmabuf event (wlr_screencopy_v1.c:592-595) and no dma render-pass copy (wlr_screencopy_v1.c:234-281).
4. Fixed ARGB8888 read format (screencopy.zig:198, 254-257) vs renderer preferred_read_format (wlr_screencopy_v1.c:543); no stride validation (wlr_screencopy_v1.c:418-421) — a padded client shm buffer is silently mis-copied because our rows assume tight stride.
5. Region ignores output scale/transform (wlr_screencopy_v1.c:576-580); clamps instead of failing (wlr_screencopy_v1.c:313-319). [VERIFIED 2026-08-09: our output pipeline is fixed at scale 1.0 / transform .normal (output.zig:66-67) with no mode-driven changes, so the clamp is correct today; it would break only if scale/transform became dynamic.]
6. overlay_cursor flag has no effect (screencopy.zig:117-123; wlr_screencopy_v1.c:443-446).
7. No output-enabled state: wlroots fails disabled outputs at capture and copy time (wlr_screencopy_v1.c:508-511, 364-367).
8. Ready timestamp is copy time, not frame commit/present time (screencopy.zig:299-301 vs wlr_screencopy_v1.c:337).
9. Protocol deprecation: wlroots declares zwlr_screencopy deprecated, superseded by ext-image-copy-capture-v1 (wlr_screencopy_v1.h:18-21); smithay ships only the successor. Our module implements the deprecated protocol.

## Verdict

- v3 shm path is functional for full-output captures; lifecycle, error codes, and event order match wlroots.
- Riskiest divergences: synchronous copy timing (stale frames), ignored damage semantics, missing stride validation (corrupt padded buffers), region mapping without scale/transform.
- wlroots is commit-deferred, damage-aware, dmabuf-capable, and renderer-format-driven; smithay implements neither zwlr_screencopy nor its semantics, offering ext-image-copy-capture-v1 instead.
