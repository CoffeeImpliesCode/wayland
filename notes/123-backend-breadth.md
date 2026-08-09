# Backend breadth — wlroots 0.20.2 / smithay v0.7.0

Scope: `src/backend/backend.zig` (Backend abstraction), `headless.zig` (timer-paced virtual output), `drm.zig` (KMS/dumb-buffer scanout), `libinput.zig` (evdev input), `src/server/raylib.zig` (host debug window backend). Reference surface: wlroots 0.20.2 `backend/` + `render/allocator/` + `render/swapchain.c`; smithay v0.7.0 `src/backend/` (all feature-gated modules). Parity coverage lives in 114-backend-vs-wlroots-smithay.md (Backend abstraction + headless), 116-drm-backend-audit.md, 117-libinput-backend-audit.md, 122-client-raylib-audit.md (raylib); this note is the breadth inventory: whole backends, session machinery, and allocator features we lack entirely.

## Inventory

Ours (`src/backend/`, dir listing + `src/server/raylib.zig`):
- `backend.zig` — `Backend` with `new_output`/`new_input`/`destroy` signals; `Impl.start`/`Impl.destroy`; `InputDevice.kind` = keyboard/pointer/touch only (backend.zig:38-41).
- `headless.zig` — single output, one timer, announce-on-start.
- `drm.zig` — direct `/dev/dri/cardN` open (`WAYLAND_DRM_DEVICE`), `DRM_IOCTL_SET_MASTER`/`DROP_MASTER` (drm.zig:229), one connected connector at preferred mode, atomic modeset + page flip on the primary plane, dumb buffer XRGB8888, no modifiers, no hotplug, no swapchain.
- `libinput.zig` — libinput udev seat, keyboard/pointer/touch events (event ids 300/400-406 at libinput.zig:99-122), no tablet/switch/gesture.
- `src/server/raylib.zig` — ours-only debug backend: one window, texture upload per commit, input poll hook. No wlroots/smithay analog.

wlroots 0.20.2 `backend/` (verified dir listing):
- `backend.c`, `meson.build`
- `drm/` — `backend.c`, `drm.c`, `atomic.c`, `legacy.c`, `libliftoff.c`, `renderer.c`, `properties.c`, `util.c`, `fb.c`, `monitor.c`, `gen_pnpids.sh`
- `headless/` — `backend.c`, `output.c`
- `libinput/` — `backend.c`, `events.c`, `keyboard.c`, `pointer.c`, `touch.c`, `switch.c`, `tablet_tool.c`, `tablet_pad.c`
- `multi/` — `backend.c`
- `wayland/` (nested) — `backend.c`, `output.c`, `pointer.c`, `seat.c`, `tablet_v2.c`
- `session/` — `session.c`
- `x11/` — `backend.c`, `output.c`, `input_device.c`
- wlroots allocator/render machinery: `render/allocator/` = `allocator.c`, `gbm.c`, `shm.c`, `drm_dumb.c`, `udmabuf.c`; `render/swapchain.c`; `render/egl.c`, `render/gles2/`, `render/vulkan/`, `render/pixman/`, `render/pass.c`, `render/drm_syncobj.c`
- public headers: `include/wlr/backend/` = drm, headless, interface, libinput, multi, session, wayland, x11 (verified listing)

smithay v0.7.0 `src/backend/` (verified dir listing):
- `mod.rs` (feature-gated container; no unified Backend type), `udev.rs`
- `session/` — `mod.rs` (Session trait: open/close devices, change VT, pause/activate events), `libseat.rs`
- `libinput/` — `mod.rs` (InputBackend, DeviceCapability incl. Gesture/Switch/TabletPad/TabletTool), `tablet.rs`
- `input/` — `mod.rs` (input event traits incl. gesture swipe/pinch/hold), `tablet.rs`
- `libei/` — `seat.rs`, `input.rs` (remote input injection via libei/EIS)
- `drm/` — `mod.rs` (DrmDevice/DrmSurface/DrmNode), `device/` = `atomic.rs`, `legacy.rs`, `fd.rs`, `mod.rs`; `surface/` = `atomic.rs`, `legacy.rs`, `gbm.rs`, `mod.rs`; `gbm.rs` (GbmBufferedSurface), `dumb.rs`; `exporter/` = `gbm.rs`, `dumb.rs`; `compositor/` (DrmCompositor, `elements.rs`, `frame_result.rs`); `output.rs`
- `allocator/` — `mod.rs`, `gbm.rs`, `dumb.rs`, `udmabuf.rs`, `dmabuf.rs`, `swapchain.rs`, `format.rs`, `vulkan/`
- `egl/` — `context.rs`, `display.rs`, `surface.rs`, `fence.rs`, `native.rs`
- `renderer/` — `gles/`, `pixman/`, `multigpu/` (gbm.rs), `glow.rs`, `element/`, `damage/`, `sync/`, `utils/`, `color.rs`
- `x11/`, `winit/`, `vulkan/`
- Cargo features (Cargo.toml:92-107): `backend_drm`, `backend_gbm`, `backend_libinput`, `backend_udev`, `backend_session_libseat`, `backend_egl`, `backend_vulkan`, `backend_winit`, `backend_x11`, `backend_libei`

## Breadth table

| wlroots/smithay feature | reference location | ours? | what it does | verdict for the canvas compositor |
|---|---|---|---|---|
| Session/logind/seatd (libseat) | wlroots `backend/session/session.c` (libseat_open_seat, libseat_switch_session in `wlr_session_change_vt`, udev monitor), `include/wlr/backend/session.h`; smithay `src/backend/session/libseat.rs` (Session trait, `switch_session(vt)` at libseat.rs:167) | missing — drm.zig opens /dev/dri/cardN directly and calls SET_MASTER/DROP_MASTER itself | mediates device access via logind or seatd, VT switching, pause/activate (sleep/TTY-switch) events | in-scope for real deployment (running on a TTY without root); optional while the target is the VM/headless |
| udev DRM monitoring + GPU hotplug | wlroots `backend/session/session.c` (udev monitor, `add_drm_card`/`change` events, primary GPU boot_vga detection, `WLR_DRM_DEVICES`); smithay `src/backend/udev.rs` (UdevBackend, device_list, primary_gpu, all_gpus) | missing — drm.zig enumerates connectors once at start(); libinput.zig uses libinput's own udev path | discovers DRM cards, notifies add/remove/change, identifies primary GPU | optional (fixed display in the VM; hotplug matters on a laptop) |
| Multi-backend composition | wlroots `backend/multi/backend.c` (wlr_multi_backend add/remove, commit/test fan-out by backend, buffer_caps intersection, get_drm_fd); smithay: none (compositor composes backends itself, e.g. anvil) | missing — server selects ONE backend via env (`WAYLAND_BACKEND`, `WAYLAND_LIBINPUT`) | runs headless + input + real backends in one process | optional (headless test output alongside raylib in one process is nice but not needed) |
| Nested Wayland backend | wlroots `backend/wayland/` (backend.c, output.c, pointer.c, seat.c, tablet_v2.c): parent xdg_wm_base + wl_shm + wl_drm + zwp_linux_dmabuf_v1 (+feedback) + wp_presentation + drm-syncobj timelines + relative pointer (pointer.c:398) | missing | hosts the compositor inside another Wayland session | optional — dev-loop value already delivered by our raylib backend; no separate nested backend needed |
| X11 backend | wlroots `backend/x11/` (output.c uses XCB XInput2 event masks output.c:648-655); smithay `src/backend/x11/` (x11rb + dri3 + present + xinput) | missing | X11 window output + XInput2 input | out-of-scope (raylib covers host dev display) |
| Winit backend (smithay) | smithay `src/backend/winit/` (mod.rs, input.rs) | missing (raylib is our analog) | windowed output/input via winit (Wayland or X11 client) | out-of-scope — raylib backend already fills this niche |
| GBM allocator + modifiers | wlroots `render/allocator/gbm.c`, `render/swapchain.c`, `render/drm_format_set.c`, `render/egl.c`; smithay `src/backend/allocator/gbm.rs` + `format.rs` + `swapchain.rs`, `src/backend/drm/gbm.rs` (GbmBufferedSurface) | missing — drm.zig is dumb-buffer XRGB8888, no modifier negotiation, no swapchain | allocates GPU buffers with format/modifier sets, swapchain double/triple buffering, dmabuf export | in-scope when hardware rendering lands (canvas compositor on real GPU); out of the current software path |
| DRM planes / hardware composition | wlroots `backend/drm/libliftoff.c`, `backend/drm/atomic.c` (plane assignment); smithay `src/backend/drm/compositor/` (DrmCompositor, elements.rs) | missing — primary plane only, one framebuffer | assigns overlay/cursor planes to composite in hardware | optional/out-of-scope (canvas compositor composites in software into one buffer; planes are a perf optimization) |
| Legacy (non-atomic) DRM fallback | wlroots `backend/drm/legacy.c` + `WLR_DRM_NO_ATOMIC` (drm.c:103); smithay `src/backend/drm/device/legacy.rs`, `surface/legacy.rs` | missing — atomic-only | modeset/page-flip via legacy ioctls for old drivers | out-of-scope (virtio-gpu and modern cards all support atomic) |
| DRM syncobj timelines + async/tearing page flips | wlroots `backend/drm/drm.c` (DRM_CAP_SYNCOBJ_TIMELINE, DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP at drm.c:122-125, timeline signal on commit drm.c:370-379), `render/drm_syncobj.c` | missing | explicit buffer release sync, tearing control | out-of-scope (no explicit-sync/torn-frame feature in project) |
| DRM monitor/lease | wlroots `backend/drm/monitor.c` (wlr_drm_lease_v1 support) | missing | leases DRM devices to clients (VR) | out-of-scope (protocol not in project scope) |
| Multi-GPU (dma-buf import across GPUs) | smithay `src/backend/renderer/multigpu/` (gbm.rs, mod.rs); wlroots enumerates multiple GPUs (drm.c find_gpus + primary selection) | missing — single device | renders on one GPU, imports buffers on another | out-of-scope (single-GPU canvas target) |
| EGL/GLES/Vulkan renderer backends | wlroots `render/egl.c`, `render/gles2/`, `render/vulkan/`, `render/pixman/`, `render/pass.c`; smithay `src/backend/egl/`, `src/backend/renderer/gles/`, `pixman/`, `vulkan/` | missing — pixman software renderer only | GL/EGL or Vulkan rendering into backend buffers | in-scope eventually (GPU accelerated rendering), not now |
| Renderer/backend split (smithay) | smithay `src/backend/allocator/` + `renderer/` traits; drm module takes buffers from any allocator/renderer (drm/mod.rs "Rendering" docs) | partial — our renderer (pixman.zig) hands a Framebuffer in output state; no allocator/renderer trait layer | decouples buffer allocation, rendering, and scanout | optional — worth adopting the allocator concept (GBM/swaphchain) but not the trait machinery |
| udmabuf allocator | wlroots `render/allocator/udmabuf.c`; smithay `src/backend/allocator/udmabuf.rs` | missing | allocates dmabufs via udmabuf for zero-copy | out-of-scope (GBM covers the GPU path; needs udmabuf kernel support) |
| wl_shm allocator | wlroots `render/allocator/shm.c` | missing | server-side shared-memory buffers | optional — clients already use shm on the wire (client.zig); a server shm allocator is a small add |
| Session pause/activate events | wlroots `session->events.active` (session.c:24-35); smithay `src/backend/session/libseat.rs` (SeatEvent active/inactive) | missing | notifies compositor to release/regain devices on VT switch/suspend | in-scope together with session integration (row 1); optional |
| Headless multi-output | wlroots `backend/headless/output.c:119` `wlr_headless_add_output` | missing — single output | multiple virtual outputs from one headless backend | optional |
| Backend test/commit + buffer_caps/features | wlroots `include/wlr/backend/interface.h`, `backend/multi/backend.c` commit/test, buffer_caps intersection | missing — output-level test/commit only, no backend caps | atomic multi-output state test/commit; query accepted buffer types | optional — buffer_caps will matter when DMABUF arrives |
| libinput tablets/switches/gestures | wlroots `backend/libinput/` tablet_tool.c, tablet_pad.c, switch.c; smithay `src/backend/libinput/tablet.rs`, `input/tablet.rs`, gesture traits (input/mod.rs:203-309) | missing — InputDevice.kind has only keyboard/pointer/touch (backend.zig:38-41) | tablet/touchpad-pad/switch/gesture input events | out-of-scope (canvas: keyboard+pointer+touch suffice) |
| libei (remote input injection) | smithay `src/backend/libei/` (seat.rs, input.rs) | missing | virtual/remote input via libei portal | out-of-scope (no remote-input feature) |
| Raylib debug backend | none — no wlroots/smithay analog | ours-only | windowed debug output/input for host development | keep (fills the x11/winit/nested-dev role for us) |

## Gaps

1. **Session/logind/seatd integration** — the biggest functional gap. drm.zig opens /dev/dri/cardN directly and does SET_MASTER itself, which only works as root (VM) or with seat permissions; there is no libseat/logind path, no VT switching, no pause/activate handling. This is the difference between "runs in the VM" and "runs on a laptop TTY", and it is the standard compositor bootstrap (wlroots backend/session/session.c, smithay session/libseat.rs).
2. **No GBM allocator/swapchain/modifiers** — the dumb-buffer path caps scanout at XRGB8888 no-modifier and forces a CPU memcpy per frame; any future GPU renderer needs GBM + modifier negotiation, and GPU-sourced dmabuf export (screencopy from rendered buffers) is impossible without it. wlroots render/allocator/gbm.c + render/swapchain.c; smithay allocator/gbm.rs + swapchain.rs.
3. **No hotplug** — connectors are enumerated once at start(); plug/unplug (or a laptop lid) is not handled. wlroots session udev monitor + drm connector re-scan; smithay UdevBackend. Matters the moment the compositor leaves the VM.
4. **No multi-backend composition** — one backend per process; cannot run headless test output and the raylib window simultaneously. wlroots backend/multi/backend.c.
5. **No nested Wayland backend** — cannot run inside another Wayland session; irrelevant while raylib serves as the host dev display, but a true nested backend (wlroots backend/wayland/) would make VM-based development unnecessary.
6. **No backend buffer_caps/test/commit** — the compositor cannot query which buffer types a backend accepts or atomically test/commit states across outputs; output-level test/commit exists but the backend-level contract (wlroots interface.h buffer_caps) is absent.
7. **Input device kinds are a fixed enum** — tablets, switches, gestures are structurally excluded (backend.zig InputDevice.kind); fine for the canvas, a design constraint if input scope grows.

## Verdict

wlroots and smithay both carry a large additional backend surface beyond our four modules: session/logind (libseat) with VT switching and pause/activate events, udev GPU hotplug, multi-backend composition, nested Wayland and X11/winit windowed backends, GBM allocator + swapchain with modifier negotiation, DRM plane/libliftoff hardware composition, legacy (non-atomic) DRM, drm-syncobj timelines with tearing page flips, DRM leases, multi-GPU dma-buf import, EGL/GLES/Vulkan renderer backends, libei remote input, and tablet/switch/gesture input events. For a canvas-first compositor on a software pixman renderer targeting the VM and headless: the items worth taking are (1) session/libseat integration so the compositor can run on a real TTY without root and handle VT switches, (2) the GBM allocator + swapchain + modifier negotiation when GPU rendering arrives, and (3) udev-driven hotplug for plug/unplug resilience. The development-loop niche is already covered by our raylib backend — which has no wlroots/smithay analog — so the nested-Wayland, X11, and winit backends are redundant with it. Planes, legacy DRM, syncobj timelines, DRM leases, multi-GPU, Vulkan, libei, and tablets are out of scope for a canvas compositor.
