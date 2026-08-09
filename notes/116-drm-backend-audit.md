# DRM/KMS backend — wlroots/smithay diff

Scope: `src/backend/drm.zig` (890 lines), `src/backend/drm_c.h`, the DRM wiring in `build.zig` (translate-c module + pkg-config libdrm), plus the byte-order contract with `src/renderer/pixman.zig` and the server wiring in `src/server/main.zig` / `src/server/client.zig`. References: wlroots 0.20.2 `backend/drm/` (drm.c, atomic.c, properties.c, backend.c; no dumb.c — wlroots 0.20.2 has no dumb-buffer path, verified by listing the dir), smithay v0.7.0 `src/backend/drm/` (device/mod.rs, device/atomic.rs, device/fd.rs, surface/atomic.rs, dumb.rs; no framebuffer.rs in v0.7.0 — fb handling lives in dumb.rs + device/). Kernel facts verified against Linux v6.6 `drivers/gpu/drm/drm_ioctl.c` and `drivers/gpu/drm/virtio/virtgpu_plane.c` (fetched from torvalds/linux v6.6 tag, not from the clones).

## Surface

Public inventory (`pub fn`/`pub const`; file:line relative to repo root):

`src/backend/drm.zig`:
- `drm_format_xrgb8888` const (drm.zig:61)
- `DrmBackend.create` (drm.zig:142-157) — allocates backend data, defers to `Backend.init`
- `DrmBackend.fromBackend` (drm.zig:160-162)
- `pollFd` (drm.zig:166-168)
- `dispatch` (drm.zig:173-184) — `drmHandleEvent` + `page_flip_handler2`

Private module fns (cited in rows, not inventory): `start` (drm.zig:190-195), `startInner` (drm.zig:198-437), `destroy` (drm.zig:439-450), `testState` (drm.zig:456-472), `commit` (drm.zig:474-513), `destroyOutput` (drm.zig:517), `findConnectorMode` (drm.zig:534-603), `findPrimaryPlane` (drm.zig:610-634), `scanPropIds` (drm.zig:641-659), `scanPlaneProps` (drm.zig:664-695), `getPropValue` (drm.zig:700-707), `fixed16` (drm.zig:712-714), `modeToOutput` (drm.zig:719-734), `copyRows` (drm.zig:745-751), `drmTeardown` (drm.zig:757-783), `pageFlipHandler` (drm.zig:789-805).

`src/backend/drm_c.h`: five libdrm includes (xf86drm.h, xf86drmMode.h, drm.h, drm_mode.h, drm_fourcc.h); imported as the `drm_c` module. `build.zig:69-83` — `addTranslateC` over the shim, include path parsed from `pkg-config --cflags libdrm`, `linkSystemLibrary("drm", .{.use_pkg_config = .force})`.

## Comparison

### Device open + client caps
- ours: plain `openat` O_RDWR|O_CLOEXEC, then `DRM_IOCTL_SET_MASTER` (non-fatal on failure, drm.zig:204-227); sets only `DRM_CLIENT_CAP_ATOMIC` (drm.zig:216).
- wlroots: opens through the session (`wlr_session_open_file`, backend/drm/backend.c:68,298 — logind/seatd owns the fd and master state, session resume re-sets master, backend.c:109-113); sets `DRM_CLIENT_CAP_UNIVERSAL_PLANES` first (drm.c:75) then `DRM_CLIENT_CAP_ATOMIC` (drm.c:94,107), falls back to the legacy iface when atomic is unavailable (drm.c:106-110).
- smithay: `DrmDeviceFd` wraps the fd (src/backend/drm/device/fd.rs), sets `UniversalPlanes` then `Atomic` (src/backend/drm/device/mod.rs:194-196, 252), falls back to `LegacyDrmDevice` (device/mod.rs:252-256).
- verdict: close for the target. Skipping UNIVERSAL_PLANES is harmless on modern kernels — Linux v6.6 `drm_setclientcap` sets `file_priv->universal_planes` when ATOMIC is set (drm_ioctl.c:341-352, verified). Ours has no legacy fallback: a non-atomic driver fails start (drm.zig:216-219) where wlroots/smithay degrade.

### Connector / mode / CRTC discovery
- ours: first CONNECTED connector with modes; mode = PREFERRED else first (drm.zig:530-603); encoder = connector's own, else first encoder with possible_crtcs != 0; CRTC = first bit of possible_crtcs, bounded `j < 32` (drm.zig:600-610 region); CRTC reuse across connectors not considered (single output).
- wlroots: connects every connector (`create_drm_connector` drm.c:1553-1625, `connect_drm_connector` drm.c:1627-1771); mode = the connector's CURRENT mode from the crtc blob (drm.c:1591-1619) or a custom mode with that refresh (drm.c:1677-1693) — it does NOT prefer PREFERRED at start; CRTCs matched across all connectors via `possible_crtcs` (realloc_crtcs drm.c:1399-1453, `match_connectors_with_crtcs`).
- smithay: surface per crtc+primary plane (`DrmSurface::new` src/backend/drm/surface/atomic.rs:180-260); the compositor picks the mode.
- verdict: divergent in mode policy (preferred-vs-current) and in encoder fallback (see Gap 4); acceptable for a single-output VM backend.

### Primary plane selection
- ours: possible_crtcs bit + `type` property == PRIMARY (drm.zig:610-634); no plane-format check.
- wlroots: `init_plane` — type + possible_crtcs, records plane formats (drm.c:195-213) and IN_FORMATS blob (drm.c:214-227), `assert(drm->num_crtcs <= 32)` (drm.c:242).
- smithay: `planes()` filters `possible_crtcs` and `PlaneType::Primary` (src/backend/drm/mod.rs:152-216), also records formats (mod.rs:146-149).
- verdict: same selection criteria; ours lacks the format set (Gap 3).

### Property-id resolution
- ours: `scanPropIds`/`scanPlaneProps` — `drmModeObjectGetProperties` + name match, any missing id fails start (drm.zig:641-695); plane table `plane_prop_names` order-tested (drm.zig:852-862).
- wlroots: `scan_properties` over `plane_info`/`crtc_info`/`conn_info` tables (backend/drm/properties.c:40-53, 81-122); missing properties fail plane init.
- smithay: `PropMapping` built at `AtomicDrmDevice::new` (src/backend/drm/device/atomic.rs:92-190).
- verdict: same. Missing property -> explicit BackendFailed with log, never a silent zero.

### Dumb buffer + framebuffer
- ours: CREATE_DUMB (32 bpp) -> MAP_DUMB -> mmap -> ADDFB2 with XRGB8888 (drm.zig:297-340).
- smithay: `framebuffer_from_dumb_buffer` — `add_planar_framebuffer` (FB_CMD2 path), legacy `add_framebuffer` fallback (src/backend/drm/dumb.rs:156-204); buffer comes from the dumb allocator, one fresh dumb buffer per allocation.
- wlroots: no dumb path in 0.20.2 — scanout buffers are GBM (dmabuf) framebuffers; `wlr_drm_fb` wraps a `wlr_buffer` with a drm fb id.
- verdict: dumb-buffer scanout is a deliberate simplification. vs GBM this changes: format list limited to what the dumb driver exposes (virtio-gpu primary = XRGB8888 only), no modifier support, no dmabuf export for screencopy/DRM-lease, single-buffer flip (Gap 2).

### Atomic modeset
- ours: one blocking commit, `ALLOW_MODESET`, props: connector CRTC_ID, crtc MODE_ID+ACTIVE, plane CRTC_ID/FB_ID/SRC_*/CRTC_* with 16.16 SRC (drm.zig:351-432); error path logs errno from the return value, single commit call (drm.zig:383-427).
- wlroots: `atomic_connector_add` sets the same core set (atomic.c:494-568, `set_plane_props` atomic.c:452-477, SRC as `x * (1 << 16)` atomic.c:462-465); blocking when modeset, `ALLOW_MODESET` added in `atomic_device_commit` (atomic.c:600-606).
- smithay: `commit` with `ALLOW_MODESET` and (optionally) `PAGE_FLIP_EVENT` in the same call (src/backend/drm/surface/atomic.rs:829-841); connector/crtc/plane props via `set_connector`/`set_crtc`/`set_plane` (surface/atomic.rs:1370-1450).
- verdict: matches the kernel ABI and wlroots' property set. The errno-from-return trick is correct: libdrm returns `-errno` from `drmModeAtomicCommit`, and Zig 0.16 `std.os.linux.errno` maps negative isizes back (linux.zig:592-596, verified in the pinned 0.16.0 std).

### Page flip
- ours: FB_ID-only commit, `PAGE_FLIP_EVENT | NONBLOCK`, `flip_pending` guard -> CommitFailed (drm.zig:474-513); same single dumb fb every frame (Gap 2).
- wlroots: non-modeset buffer commits are non-blocking (`nonblock = !allow_reconfiguration && committed & BUFFER`, drm.c:955-956), `PAGE_FLIP_EVENT` flag when active (drm.c:1002-1006), explicit "a page-flip is already pending" failure (drm.c:993-996); multi-buffer swapchain, flips queued across buffers.
- smithay: `page_flip` with `PAGE_FLIP_EVENT | NONBLOCK` (src/backend/drm/surface/atomic.rs:899-903); fresh framebuffers per frame.
- verdict: guard matches wlroots exactly. Caller handles CommitFailed: server logs and drops the frame (src/server/main.zig:758-761), pacing resumes at the next flip event — same drop semantics as wlroots commit failure.

### Flip events / frame pacing
- ours: `pageFlipHandler` (v3 handler2) clears flip_pending, sends `out.sendFrame()` (drm.zig:789-805); `dispatch` drains via `drmHandleEvent` (drm.zig:173-184); poll fd wired in main.zig:436-444, dispatch at main.zig:605-608.
- wlroots: same version-3 context + handler2 (drm.c:2092-2097), `handle_page_flip` sends present then `wlr_output_send_frame` when the session is active (drm.c:2082-2086).
- smithay: `DrmDeviceNotifier` EventSource decodes `Event::PageFlip` (src/backend/drm/device/mod.rs:525-547).
- verdict: pacing parity. Divergence: ours logs-only on `drmHandleEvent` failure (drm.zig:181-183); wlroots destroys the backend (`wlr_backend_destroy` in handle_drm_event, drm.c:2089-2104).

### Teardown
- ours: `destroy` destroys the output, then `drmTeardown` — DestroyPropertyBlob, RmFB, munmap, DESTROY_DUMB, DROP_MASTER, close; idempotent and null-safe (drm.zig:439-450, 757-783); partial-start failures cleaned by errdefer (drm.zig:212) + caller's `backend.destroy()` frees DrmOutput/backend structs.
- wlroots: session close (backend.c:68), output destroy via `wlr_output_finish` (drm.c:1244-1260); fbs released through `drm_fb`.
- smithay: `DumbFramebuffer` Drop destroys the fb (dumb.rs:27-37); `AtomicDrmDevice` Drop restores the previous KMS state (device/atomic.rs:238-275).
- verdict: ours is leak-free end to end (traced every acquisition: dumb handle, mmap, fb id, blob, master, fd all released in reverse order). It does NOT restore the previous KMS state on exit like smithay's Drop (device/atomic.rs:253-274); on a headless VM this is moot, on a real session the fb is left modeset.

### First-frame kick / output announce
- ours: modeset -> `emitNewOutput` -> `sendFrame` (drm.zig:433-436). The listener resizes the render framebuffer to the connector mode, builds the scene output, and attaches the frame listener during the emit (main.zig:484-563), so the first frame commit can run immediately.
- wlroots: output created + current mode set at connect; the compositor drives the first frame via its own output state API.
- verdict: ordering is safe (listener attach happens inside `emitNewOutput`, before `sendFrame`).

## Gaps

1. **Byte-order mismatch between the renderer and the XRGB8888 fb claim** (proven, high). drm.zig:57-60 and the test comment drm.zig:814-815 claim "the pixman framebuffer byte order (B,G,R,A in memory) equals DRM_FORMAT_ARGB8888's", and the fb is created XRGB8888 (drm.zig:331). The renderer's rect path stores the opposite order: `addRect` writes `color[0]` (documented R, pass.zig:27 "RGBA color") at memory byte 0 (pixman.zig:228-233, blendPixel copies verbatim at pixman.zig:249-250), proven by the renderer's own tests: addRect red -> bytes `[255,0,0,255]` and blue-over-white -> `[127,127,255,191]` (pixman.zig:375, 379-380, 394). So rect-drawn content (background rect, fallback cursor, any rect node) is `[R,G,B,A]` = DRM ABGR8888 layout; scanned out as XRGB8888 (`[B,G,R,A]` per drm_fourcc) the R and B channels are swapped on screen. Client surface textures are imported verbatim from wl_shm ARGB8888 buffers, which ARE `[B,G,R,A]` (client.zig:605-620 fills byte0=B, byte2=R), so textures scan out correctly — only compositor-drawn rects swap. The raylib debug backend makes the same `[B,G,R,A]` assumption (server/raylib.zig:308-318), confirming the intended fb layout and locating the bug in pixman `addRect`/`fill`, not in the DRM backend. The DRM-side claim is false; the e2e cannot catch it (verifyCapturePixels checks texture-gradient pixels only, client.zig:547-556; the VM e2e pass signal is CLIENT-OK + `drm:`/`libinput:` log lines, scripts/vm-drm-e2e.sh). Fix direction: `addRect` should store `[B,G,R,A]` to match its own declared `format_argb8888` (pixman.zig:17-18) and both display backends.

2. **Single-buffer scanout tears** (design gap, medium). One dumb buffer is flipped every frame (drm.zig:101-112, 474-513); `copyRows` writes into the buffer the scanout is currently reading (render happens after the flip event, before the next flip). wlroots scans out a multi-buffer GBM swapchain; smithay's dumb path allocates a fresh dumb buffer per frame (`create_dumb_buffer` at src/backend/drm/surface/atomic.rs:257, allocator-backed). Ours cannot do damage-based partial updates either (full copyRows, drm.zig:745-751). Mitigations: none in the note's scope; acceptable for a VM screenshot backend, not for real use.

3. **No plane-format check at plane selection** (minor). `findPrimaryPlane` (drm.zig:610-634) checks possible_crtcs + type only; an unsupported fb format surfaces as an EINVAL at commit instead of a start-time error. wlroots records plane formats (drm.c:195-213) and smithay checks them (mod.rs:146-149). Works on the target because the virtio-gpu primary plane format list is exactly `{XRGB8888}` (kernel virtgpu_plane.c:47-52, verified) — the XRGB8888 fix (vs ARGB8888, which that plane rejects) is required and correct; smithay uses XRGB8888 for primary and ARGB8888 for non-primary planes for the same reason (src/backend/drm/surface/atomic.rs:231-246). `[INFERENCE]` for other hardware: a plane that lacks XRGB8888 fails at commit time.

4. **Encoder fallback skips a connector when its bound encoder has no CRTC** (minor). `findConnectorMode` uses the connector's own encoder; `possible_crtcs == 0` -> `continue`, never trying the connector's other encoders (drm.zig:570-600). wlroots matches across the union of the connector's encoders (realloc_crtcs drm.c:1399-1453). Single-encoder hardware (virtio-gpu) unaffected.

5. **testState accepts scale/transform/enabled bits it does not apply** (minor). testState validates only mode size and buffer (drm.zig:456-472); a transform/scale commit passes, `Output.commitState` then applies it to `output.width/height` (src/output/output.zig:207-216) which diverges from the real modeset. wlroots rejects unsupported state bits (drm.c:840-846). Not reachable today: the server always commits enabled|mode|buffer (main.zig:748-752).

6. **Atomic-only, no legacy fallback** (parity gap, low for target). Ours hard-requires `DRM_CLIENT_CAP_ATOMIC` (drm.zig:216-219); wlroots falls back to the legacy iface (drm.c:106-110) and smithay to `LegacyDrmDevice` (device/mod.rs:252-256). Fine for virtio-gpu.

7. **`drmHandleEvent` failure is logged, not fatal** (minor). Ours logs and returns (drm.zig:181-183); wlroots destroys the backend (handle_drm_event, drm.c:2089-2104). A wedged event fd would silently stop frame pacing in ours (watchdog eventually stops the server, main.zig:446+).

## Verdict

The core KMS path is correct and closely matches wlroots: property set and 16.16 SRC fixed point (atomic.c:452-477), blocking modeset + non-blocking flip with the pending-flip guard (drm.c:955-996), version-3 flip-event pacing (drm.c:2082-2097), and a leak-free reverse-order teardown (drm.zig:757-783) all verified against the references, and the ATOMIC-only client cap is fine on modern kernels (v6.6 drm_ioctl.c:341-352). The XRGB8888 fix is verified correct and necessary for virtio-gpu (virtgpu_plane.c:47-52) with no ARGB8888 remaining in the scanout path. The two real problems are rendering-side: (1) the byte-order claim in drm.zig:57-60/814-815 is false for rect content — pixman `addRect` stores `[R,G,B,A]`, so compositor-drawn rects are R/B-swapped on scanout (proven by pixman.zig:228-233 + tests 375-394); (2) single-buffer scanout tears by design (vs wlroots' GBM swapchain and smithay's per-frame dumb buffers). Secondary: no legacy fallback, no plane-format check, encoder-fallback gap, and no current-mode preservation at start (wlroots drm.c:1591-1619). Parity: high on lifecycle and atomic commit semantics; low on buffering strategy, which is the deliberate dumb-buffer scope cut.
