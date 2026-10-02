//! DRM/KMS backend with dumb-buffer scanout (pixman/software path).
//!
//! The compositor renders into its pixman Framebuffer (src/renderer/
//! pixman.zig); this backend memcpys the framebuffer rows into one of
//! two dumb buffers (DRM_IOCTL_MODE_CREATE_DUMB/MAP_DUMB/ADDFB2), then
//! atomically page-flips it to the primary plane, alternating between
//! the two buffers on every frame (A/B swapchain — every flip changes
//! FB_ID, see the commit() docs for why that is required on virtio-gpu).
//! Frame pacing is event-driven: each
//! DRM_EVENT_FLIP_COMPLETE (read via `dispatch()`) sends the next
//! output.frame signal — the same flip-completion pacing wlroots uses
//! (backend/drm/drm.c handle_page_flip: wlr_output_send_frame in the
//! flip handler) and smithay's dumb.rs scanout path (src/backend/drm/
//! dumb.rs + surface/atomic.rs page_flip()).
//!
//! # Wiring contract
//! The orchestrator wires this module in build.zig like the raylib_c
//! pattern: translate src/backend/drm_c.h with addTranslateC, import it
//! as `drm_c`, and `linkSystemLibrary("drm")` (pkg-config libdrm).
//! The server selects it with `WAYLAND_BACKEND=drm` and overrides the
//! device node with `WAYLAND_DRM_DEVICE` (default "/dev/dri/card0",
//! the VM's virtio-gpu). After `backend.start()`, the server registers
//! `drm.fromBackend(base).pollFd()` in its event loop and calls
//! `drm.fromBackend(base).dispatch()` when the fd is readable. The VM
//! test path: scripts/vm-drm-e2e.sh (builds with the guest toolchain,
//! runs wayland-server with WAYLAND_BACKEND=drm, greps "drm:" info lines
//! as the pass signal).
//!
//! M6 (logind session, VT switch, udev hotplug) adds two more fds to that
//! registration. `drm.fromBackend(base).extraFds()` returns them; the
//! server adds one `zio.ev.PipePoll` per non -1 entry, calling
//! `drm.dispatchSession(data)` and `drm.dispatchHotplug(base, data)` when
//! the matching fd is readable. Nothing else about the loop changes, and a
//! -1 entry (no logind, no libudev - the VM case) is simply skipped: the
//! backend already ran without them.
//!
//! The scanout size is the connector's preferred mode: the dumb buffer
//! and the atomic modeset are created at that size at start(), and the
//! output test hook rejects modes/buffers of any other size. The server
//! must render at the connector mode size (the pixman framebuffer handed
//! in state.buffer has to match); the orchestrator wires that when the
//! DRM output is announced.
//!
//! # drm_c namespace contract (names used, from libdrm headers)
//! Enumeration: drmModeGetResources/GetConnector/GetEncoder/GetPlane(Resources)
//! + drmModeFree* pairs; drmModeGetProperty/FreeProperty,
//! drmModeObjectGetProperties/FreeObjectProperties.
//! Properties/blobs: drmModeCreatePropertyBlob/DestroyPropertyBlob.
//! Atomic: drmModeAtomicAlloc/Free/AddProperty/Commit; drmModeRmFB
//! (teardown).
//! Events: drmHandleEvent + drmEventContext (page_flip_handler2, v3).
//! Caps/ioctl: drmSetClientCap, drmIoctl; constants DRM_IOCTL_MODE_*
//! (CREATE_DUMB/MAP_DUMB/DESTROY_DUMB/ADDFB2/SET_MASTER/DROP_MASTER),
//! DRM_CLIENT_CAP_ATOMIC, DRM_MODE_OBJECT_*, DRM_MODE_CONNECTED,
//! DRM_MODE_TYPE_PREFERRED, DRM_PLANE_TYPE_PRIMARY, DRM_MODE_PAGE_FLIP_EVENT,
//! DRM_MODE_ATOMIC_*, DRM_FORMAT_XRGB8888.
//!
//! Imports: utils/*, backend/backend.zig, output/output.zig,
//! renderer/pixman.zig, and the translated "drm_c" namespace.

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const backend_mod = @import("backend.zig");
const output_mod = @import("../output/output.zig");
const pixman = @import("../renderer/pixman.zig");
const c = @import("drm_c");
const dmabuf = @import("../buffers/dmabuf.zig");
const gbm_c = @import("gbm_c");
const session_mod = @import("session.zig");

/// DRM_FORMAT_XRGB8888 ('XR24' fourcc, 0x34325258): memory bytes
/// B,G,R,X (little-endian u32; the alpha byte is ignored on scanout).
/// The pixman Framebuffer is ARGB8888 in little-endian memory — bytes
/// B,G,R,A — the same layout with a live alpha byte (the renderer
/// stores B,G,R,A for rect fills, see addRect in renderer/pixman.zig),
/// so rows copy verbatim.
pub const drm_format_xrgb8888: u32 = 0x34325258;

/// The fourccs whose (format, modifier) pairs the GBM device is asked
/// about. This is the DRM backend's scanout list (drm_format_xrgb8888)
/// plus the colour/alpha variants a client is most likely to hand us, in
/// descending preference: the KMS plane here scans out a dumb XRGB8888
/// buffer, so XRGB8888 must be first. wlroots takes the list from its
/// renderer's format set instead (wlr_linux_dmabuf_v1_create_with_renderer
/// -> wlr_linux_dmabuf_feedback_v1_init_with_options), which this
/// compositor has no equivalent of; a query against the kernel's real
/// plane modifiers (queryGbmFormats) keeps the answer honest even so.
const gbm_candidate_formats = [_]u32{
    drm_format_xrgb8888,
    dmabuf.drm_format_argb8888,
    dmabuf.drm_format_xrgb2101010,
    dmabuf.drm_format_argb2101010,
};

const default_device_path = "/dev/dri/card0";

/// The plane properties we commit with, indexed by name — the plane_info
/// table from wlroots backend/drm/properties.c (names must match exactly;
/// "type" is read as a value, never committed). "FB_DAMAGE_CLIPS" lives in
/// the same wlroots table but is NOT listed here: it is optional (some
/// drivers lack it), while scanPropIds is all-or-nothing — a plane without
/// the property must still pass the scan. scanPlaneProps resolves it
/// separately, leaving the id 0 when absent (wlroots' scan_properties does
/// the same: missing optional ids stay 0).
const plane_prop_names = [_][]const u8{
    "FB_ID",  "CRTC_ID", "SRC_X",  "SRC_Y",  "SRC_W", "SRC_H",
    "CRTC_X", "CRTC_Y",  "CRTC_W", "CRTC_H",
};

const PlanePropIds = struct {
    fb_id: u32 = 0,
    crtc_id: u32 = 0,
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    crtc_x: u32 = 0,
    crtc_y: u32 = 0,
    crtc_w: u32 = 0,
    crtc_h: u32 = 0,
    /// Property id of the plane "type" property (read for classification).
    plane_type: u32 = 0,
    /// Property id of the optional "FB_DAMAGE_CLIPS" blob property; 0 when
    /// the driver lacks it (some do; virtio-gpu exposes it, see
    /// virtgpu_plane.c drm_plane_enable_fb_damage_clips). Commits attach
    /// damage only when nonzero (wlroots properties.c plane_info; atomic.c
    /// guards on `crtc->primary->props.fb_damage_clips != 0`).
    fb_damage_clips: u32 = 0,
};

/// One scanout framebuffer: an A/B swapchain side. Two flavours exist and
/// the only difference is where the pixels come from:
///
///  - **dumb**: CREATE_DUMB + MAP_DUMB, mapped by the kernel. This is the
///    VM path and the fallback everywhere else: no GBM, no render node, no
///    modifier, and it works on every KMS driver that supports dumb
///    buffers.
///  - **plane**: a real GEM buffer object allocated by the GBM device this
///    backend already opened (buffers/dmabuf.zig GbmDevice - the SAME
///    device the dmabuf global uses, never a second allocator), exported
///    to DRM with the modifier GBM reports through
///    drmModeAddFB2WithModifiers. The primary plane then scans out a
///    genuine framebuffer object with a negotiated layout instead of a
///    dumb one - the "planes + modifiers" half of GBM support (wlroots
///    allocator/drm_dumb.c vs render/allocator/gbm.c + drmModeAddFB2
///    with the bo's modifier, backend/drm/atomic.c plane commit).
///
/// Both flavours present identically: the modeset and the page flip only
/// ever name `fb_id`, and copyRows writes through `map`/`pitch`.
const ScanoutBuffer = struct {
    /// Framebuffer id from DRM_IOCTL_MODE_ADDFB2 / drmModeAddFB2WithModifiers.
    fb_id: u32 = 0,
    /// Bytes per row. Both a dumb pitch and a GBM stride exceed width*4 on
    /// real drivers, which is why copyRows walks rows.
    pitch: u32 = 0,
    /// CPU-mapped pixels. An mmap for a dumb buffer, gbm_bo_map's pointer
    /// for a plane one. A plain `[]u8` because the two mappers have
    /// different alignment contracts and only byte copies touch them.
    map: []u8 = &.{},
    /// Dumb-buffer handle (DRM_IOCTL_MODE_CREATE_DUMB); 0 on the plane
    /// path.
    handle: u32 = 0,
    /// GEM handle named by ADDFB2; nonzero only on the plane path.
    gem_handle: u32 = 0,
    /// DRM_FORMAT_MOD_* handed to drmModeAddFB2WithModifiers (the plane
    /// path); 0 (DRM_FORMAT_MOD_LINEAR) on the dumb path, which has no
    /// modifier to speak of.
    modifier: u64 = 0,
    /// The GBM buffer object behind this framebuffer; null on the dumb
    /// path.
    bo: ?*gbm_c.struct_gbm_bo = null,
    /// gbm_bo_map's pointer, released with gbm_bo_unmap. Null until mapped.
    bo_map: ?*anyopaque = null,
};

/// How the two swapchain buffers were allocated. Read for logs and for
/// teardown; the present path is identical either way.
const ScanoutPath = enum {
    /// CREATE_DUMB (DRM_IOCTL_MODE_CREATE_DUMB/MAP_DUMB).
    dumb,
    /// A GBM buffer object with a modifier, on a real primary plane.
    plane,
};

/// Per-output DRM state: the scanout buffers and the KMS object ids bound
/// during start(). `out` is the compositor Output wrapper, created once
/// the modeset succeeded.
const DrmOutput = struct {
    backend: *DrmBackendData,
    out: ?*output_mod.Output = null,
    crtc_id: u32,
    plane_id: u32,
    props: PlanePropIds,
    connector_crtc_id: u32 = 0,
    crtc_mode_id: u32 = 0,
    crtc_active: u32 = 0,
    mode: output_mod.Mode,
    /// The connector this output drives. Kept so a udev "remove" or
    /// "change" can find it again without re-enumerating the whole device
    /// (backend/session/direct.c wlr_output->connector is the same
    /// back-pointer wlroots keeps).
    connector_id: u32 = 0,
    /// Which buffer allocation won the start() decision, and for logs.
    scanout: ScanoutPath = .dumb,
    /// Two scanout buffers used as a flip-flop swapchain: every
    /// per-frame commit copies into the buffer that is NOT currently
    /// displayed and page-flips to ITS framebuffer id, so FB_ID changes
    /// on every flip. This is mandatory on virtio-gpu: the plane update
    /// is gated on drm_atomic_helper_damage_merged() (virtgpu_plane.c
    /// virtio_gpu_plane_atomic_update), and re-committing the same FB
    /// with only FB_DAMAGE_CLIPS damage empirically did not run the
    /// scanout switch/upload (screen stayed at the boot console).
    /// Alternating FB_ID makes `fb != old_state->fb` run the
    /// scanout+upload+flush unconditionally, damage-independent — the
    /// same buffer-swap trick wlroots uses for its swapchain
    /// (wlr_drm_plane swapchain, backend/drm/atomic.c). It also closes
    /// the single-buffer tearing gap (notes/116 gap 2): the previous
    /// flip's buffer stays on screen while the next frame is written.
    buffers: [2]ScanoutBuffer = .{ .{}, .{} },
    /// Index into `buffers` of the buffer the modeset bound / last
    /// flipped to. The next commit copies into buffers[1 - flip_index]
    /// and flips to it, then flips the index — FB_ID alternates
    /// A, B, A, B, ... (the modeset binds A = buffers[0]).
    flip_index: u32 = 0,
    /// Mode blob id from drmModeCreatePropertyBlob (destroyed on teardown).
    mode_blob: u32 = 0,
    /// One flip in flight (guarded by the frame-event pacing).
    flip_pending: bool = false,
    /// The connector mode's actual refresh interval (ns), carried by the
    /// presented event (the vblank interval of the mode being scanned
    /// out — wlroots drm.c handle_page_flip's refresh).
    refresh_ns: u64 = 0,
};

const DrmBackendData = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    device_path: []const u8,
    fd: ?std.posix.fd_t = null,
    is_master: bool = false,
    /// KMS interface in use: true = atomic (DRM_CLIENT_CAP_ATOMIC set),
    /// false = legacy (drmModeSetCrtc modeset + drmModePageFlip flips).
    /// Set in startInner from the atomic capability (wlroots
    /// check_drm_features drm.c:106-110 falls back to the legacy
    /// interface when the driver lacks ATOMIC; smithay the same,
    /// device/mod.rs:252-256). Read by commit() to pick the flip path.
    atomic: bool = true,
    /// Every output this backend drives. One entry per connected connector
    /// that has a mode, a free CRTC and a scannable plane; a second output
    /// appears here when a cable is plugged (see addOutput / dropOutputs).
    /// Owned: destroy() frees each entry after Output.destroy() has run.
    outputs: std.ArrayListUnmanaged(*DrmOutput) = .empty,
    /// The logind session (backend/session.zig), or null when this machine
    /// has none or logind would not host us. Null is the normal VM case
    /// and is NOT an error: the backend then runs exactly as it did before.
    session: ?*session_mod.Session = null,
    /// The udev monitor that turns connector changes into addOutput /
    /// dropOutputs, or null when libudev or its netlink socket is missing.
    hotplug: ?*session_mod.Hotplug = null,
    /// The GBM device this backend can import client dmabufs into, or null
    /// when the node offers no GBM (no render node, no gbm_create_device)
    /// or no supported (format, modifier) pair. The buffer allocator
    /// (buffers/dmabuf.zig) and the zwp_linux_dmabuf_v1 global
    /// (shell/linux_dmabuf.zig) are both gated on this field: a global
    /// without a device behind it is a promise the client can falsify.
    /// The plane scanout path (createPlaneBuffers) uses it too, so a
    /// modifier-capable allocation never needs a second GBM device.
    gbm: ?*dmabuf.GbmDevice = null,
};

const backend_impl: backend_mod.Backend.Impl = .{
    .start = start,
    .destroy = destroy,
};

const output_impl: output_mod.Output.Impl = .{
    .@"test" = testState,
    .commit = commit,
    .destroy = destroyOutput,
};

pub const DrmBackend = struct {
    /// Create a DRM/KMS backend. All device work happens in start():
    /// open + master, connector/mode/crtc (plane) enumeration, dumb
    /// buffers, modeset — atomic when the driver supports it
    /// (DRM_CLIENT_CAP_ATOMIC), else the legacy interface
    /// (drmModeSetCrtc/drmModePageFlip) — then `new_output` (plus the
    /// first frame kick). `device_path` selects the card node (default
    /// "/dev/dri/card0"; the server passes WAYLAND_DRM_DEVICE).
    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        device_path: ?[]const u8,
    ) !*backend_mod.Backend {
        const data = try allocator.create(DrmBackendData);
        errdefer allocator.destroy(data);
        data.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .device_path = device_path orelse default_device_path,
        };
        return backend_mod.Backend.init(allocator, io, log_cfg, &backend_impl, data);
    }

    /// Recover the DrmBackend impl from the Backend for pollFd()/dispatch().
    pub fn fromBackend(base: *backend_mod.Backend) *DrmBackendData {
        return @ptrCast(@alignCast(base.data));
    }
};

/// The GBM device the server may advertise zwp_linux_dmabuf_v1 with, or
/// null when this backend has none. Null is the correct answer for a
/// headless/raylib/nested-wayland backend and for a DRM node whose GBM
/// device or format set could not be brought up — the dmabuf global is
/// bound only when this returns a device (shell/linux_dmabuf.zig).
pub fn gbmDevice(self: *DrmBackendData) ?*dmabuf.Device {
    const dev = self.gbm orelse return null;
    if (!dev.iface.isLive()) return null;
    return &dev.iface;
}

/// The fd to poll for DRM events (page-flip completions).
pub fn pollFd(self: *DrmBackendData) std.posix.fd_t {
    return self.fd orelse -1;
}

/// Drain pending DRM events (drmHandleEvent); each flip completion emits
/// output.frame. Called by the server's event loop when `pollFd` is
/// readable (wlroots handle_drm_event). A failed event read is fatal:
/// the fd is wedged and frame pacing would stop, so the caller must
/// tear the server down (wlroots destroys the backend in
/// handle_drm_event, drm.c:2094-2100).
pub fn dispatch(self: *DrmBackendData) error{BackendFailed}!void {
    const fd = self.fd orelse return;
    var evctx: c.drmEventContext = .{
        .version = 3,
        // v3 = page_flip_handler2 with crtc_id (wlroots drm.c uses the
        // same version + handler).
        .page_flip_handler2 = pageFlipHandler,
    };
    if (c.drmHandleEvent(fd, &evctx) != 0) {
        log_mod.err("drm: drmHandleEvent failed", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
}

// ---------------------------------------------------------------------------
// Backend impl
// ---------------------------------------------------------------------------

fn start(base: *backend_mod.Backend) error{BackendFailed}!void {
    // The Backend.Impl start slot only allows BackendFailed; the
    // allocator failures inside must map onto it.
    startInner(base) catch |err| return switch (err) {
        error.OutOfMemory, error.BackendFailed => error.BackendFailed,
    };
}

/// Bring the device up. Ordered phases, each a named step that can fail on
/// its own (the definitions sit below `destroy`):
///
///   1. `openDevice`            openat the card node (O_RDWR|O_CLOEXEC).
///   2. `selectKmsInterface`    DRM_CLIENT_CAP_ATOMIC, or fall back to legacy.
///   3. `openSession`           logind session: CreateSession, Type=wayland,
///                               TTY, TakeDevice, PrepareForSleep watch,
///                               and the VT switch (VT_ACTIVATE + VT_ACK).
///   4. `becomeMaster`          DRM_IOCTL_SET_MASTER.
///   5. `openGbm`               the GBM device both the dmabuf global and the
///                               plane scanout path allocate from.
///   6. `addOutput`             one output per connected connector that has a
///                               mode, a free CRTC and a scannable plane
///                               (enumerateTarget -> resolvePlane ->
///                               allocOutput -> scanKmsProps ->
///                               createScanoutBuffers -> createModeBlob ->
///                               modeset -> announceOutput).
///   7. `openHotplug`           the udev monitor that drives 6 again (and
///                               tears outputs down) when a cable moves.
///
/// The order is load-bearing at five seams. The ATOMIC client cap must be
/// requested before any KMS ioctl (wlroots drm.c drm_open issues
/// drmSetClientCap as part of the open). The session must exist BEFORE DRM
/// master is taken and before the VT moves: `Manager.TakeDevice` is what
/// stops logind from handing the master to the console session the moment
/// we look away (org.freedesktop.login1(5) Manager.TakeDevice), and the VT
/// switch is only ours once Session.TTY names it (without that, logind
/// activates whatever getty owns the VT we activated). DRM master must be
/// held before the modeset commits, because the kernel rejects a
/// non-master client's mode/plane updates (drm_mode_atomic_ioctl,
/// drm_mode_crtc_set_property). The primary plane must be resolved before a
/// framebuffer can be attached to anything, since the atomic commit names
/// the plane object. And both framebuffers must exist before the modeset
/// points the plane at one of them. The VT ack is waited for on the DRM fd
/// before the first flip is queued, which is the only window in which a raw
/// read there cannot eat a flip event. Phases inside `addOutput` for the
/// properties and blobs (scanKmsProps, createModeBlob) are atomic-only —
/// the legacy interface has neither.
///
/// One `errdefer drmTeardown` covers every failure: teardown is
/// null-safe, idempotent and ordered by reverse acquisition, so a phase
/// that dies half-way leaves the phases before it to be released in the
/// right order. Success keeps everything; `destroy` tears it down.
fn startInner(base: *backend_mod.Backend) error{ BackendFailed, OutOfMemory }!void {
    const self: *DrmBackendData = @ptrCast(@alignCast(base.data));

    // --- phases 1-2: the device itself. A failed open publishes no fd, so
    // teardown only starts mattering once the open succeeded.
    try openDevice(self);
    errdefer drmTeardown(self);
    selectKmsInterface(self);

    // --- phase 3: the seat, before anyone can take the master away. Every
    // failure here is non-fatal and logged by openSession itself: the VM
    // has no logind at all, and a machine that refuses the session still
    // runs - it just does not hold the seat (see session.zig's failure
    // policy).
    openSession(self);

    // --- phase 4: master. After the session, so logind knows the device is
    // ours before we ask for it.
    becomeMaster(self);

    // --- phase 5: the GBM device. Not fatal: a node without GBM (or with
    // no format GBM accepts) still scans out - on the dumb path - it just
    // cannot offer zwp_linux_dmabuf_v1 nor scan out a modifier-capable
    // framebuffer. It sits here, right after the node is open and before
    // the modeset, because it re-resolves the node from the fd and that is
    // the last moment the KMS fd is unambiguously ours.
    try openGbm(self);

    // --- phase 6: one output per usable connector. The loop ends when the
    // enumeration has nothing left; the only error it can raise is a device
    // with no usable connector at all, which is a backend failure.
    while (try addOutput(base, self)) {}

    // --- phase 7: hotplug last, so the events that arrive during startup
    // are judged against an already-complete output list.
    openHotplug(self);
}

/// Tear the whole backend down, in reverse acquisition order: the udev
/// monitor first (it must stop producing callbacks into state we are about
/// to free), then the session (which puts the console back on its own VT
/// and hands the device to logind), then the outputs and finally the card
/// fd. The VT restore deliberately happens while we still hold DRM master
/// and before the session ends, so the console is never left on a VT that
/// no live session owns.
fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const self: *DrmBackendData = @ptrCast(@alignCast(data));
    // Outputs first: Output.destroy() emits the destroy signal, so no
    // compositor callback can touch the DRM state after the fd closes.
    for (self.outputs.items) |drm_out| {
        if (drm_out.out) |out| out.destroy();
    }
    drmTeardown(self);
    for (self.outputs.items) |drm_out| allocator.destroy(drm_out);
    self.outputs.deinit(allocator);
    allocator.destroy(self);
}

// ---------------------------------------------------------------------------
// Start phases (see startInner for the order and why it is load-bearing)
// ---------------------------------------------------------------------------

/// The atomic plane driving the scanout: the plane object id plus the
/// property ids every atomic commit writes through it. The legacy KMS
/// interface has no planes, so both stay zero there — legacy modeset and
/// flips target the CRTC directly (wlroots legacy.c), which is why this
/// struct is zero-valued rather than absent.
const PlaneSelection = struct {
    id: u32 = 0,
    props: PlanePropIds = .{},
};

/// Phase 1: open the card node (wlroots drm.c drm_open; O_RDWR|O_CLOEXEC).
/// The fd is published on the backend so every later phase — and
/// drmTeardown on the failure paths — can reach it.
fn openDevice(self: *DrmBackendData) error{BackendFailed}!void {
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        self.device_path,
        .{ .ACCMODE = .RDWR, .CLOEXEC = true },
        0,
    ) catch {
        log_mod.err("drm: open {s} failed", self.io, self.log_cfg, "drm", .{self.device_path});
        return error.BackendFailed;
    };
    self.fd = fd;
}

/// Phase 2: pick the KMS interface. Atomic modesetting must be requested
/// before any KMS ioctl (wlroots drm.c drm_open:
/// drmSetClientCap(DRM_CLIENT_CAP_ATOMIC, 1)). When the driver lacks
/// ATOMIC, fall back to the legacy KMS interface (drmModeSetCrtc modeset
/// + drmModePageFlip flips) instead of failing — wlroots
/// check_drm_features drm.c:106-110, smithay LegacyDrmDevice
/// (device/mod.rs:252-256). WLR_DRM_NO_ATOMIC forces the legacy path
/// (wlroots parity; lets the fallback be exercised on atomic hardware).
/// The legacy path needs no planes or property blobs; the
/// connector/mode/CRTC enumeration below is shared.
fn selectKmsInterface(self: *DrmBackendData) void {
    const fd = self.fd.?;
    const force_legacy = std.c.getenv("WLR_DRM_NO_ATOMIC") != null;
    if (force_legacy) {
        log_mod.info("drm: WLR_DRM_NO_ATOMIC set; using legacy KMS interface", self.io, self.log_cfg, "drm", .{});
        self.atomic = false;
    } else if (c.drmSetClientCap(fd, @intCast(c.DRM_CLIENT_CAP_ATOMIC), 1) != 0) {
        log_mod.warn(
            "drm: DRM_CLIENT_CAP_ATOMIC unsupported on {s}; using legacy KMS interface",
            self.io,
            self.log_cfg,
            "drm",
            .{self.device_path},
        );
        self.atomic = false;
    }
}

/// Phase 4: become DRM master (required for modeset). The first opener is
/// master automatically, so failure is non-fatal here (headless VM).
///
/// Callable more than once, which is what resume needs: after a suspend the
/// master is gone (the session either released the device or the kernel
/// handed the card to whoever opened it next), so `becomeMaster` runs again
/// from handlePrepareForSleep. Idempotent while the master is held.
fn becomeMaster(self: *DrmBackendData) void {
    const fd = self.fd orelse return;
    if (self.is_master) return;
    if (c.drmIoctl(fd, c.DRM_IOCTL_SET_MASTER, null) == 0) {
        self.is_master = true;
        log_mod.info("drm: DRM master acquired", self.io, self.log_cfg, "drm", .{});
    } else {
        log_mod.warn("drm: DRM_IOCTL_SET_MASTER failed (not master?)", self.io, self.log_cfg, "drm", .{});
    }
}

/// Phase 3: the logind session - the seat, the device claim and the VT
/// switch, in the order session.zig needs (see that file's open()).
///
/// NON-fatal by construction: every error it can return is a reason this
/// machine cannot host a session, not a reason to fail the backend. The VM
/// has no logind at all and runs exactly as before; a machine whose seat
/// refuses us runs, reports, and leaves the console alone. What is NOT
/// negotiable is that this runs BEFORE becomeMaster: once logind knows the
/// session holds the device it will not hand the master to the console
/// session, which is the entire point.
fn openSession(self: *DrmBackendData) void {
    const fd = self.fd orelse return;
    self.session = session_mod.Session.open(self.allocator, self.io, self.log_cfg, .{
        // The VT ack arrives on the DRM fd: the DRM core queues a
        // `struct vt_event` to every open card when the console switches.
        .vt_ack_fd = fd,
        .drm_minor = cardMinor(self.device_path),
        .on_sleep = onSessionSleep,
        .ctx = self,
    }) catch |err| {
        log_mod.info(
            "drm: no logind session ({s}); the card is driven without one",
            self.io,
            self.log_cfg,
            "drm",
            .{@errorName(err)},
        );
        return;
    };
}

/// The session module's suspend callback. The session has already released
/// or re-taken the device by the time this runs (session.zig dispatch does
/// its own half first); this is the backend's half - see the sleep plan.
fn onSessionSleep(ctx: ?*anyopaque, sleeping: bool) void {
    const self: *DrmBackendData = @ptrCast(@alignCast(ctx.?));
    handlePrepareForSleep(self, sleeping);
}

/// PrepareForSleep, resolved through the session module's plan so the two
/// halves cannot disagree: on the way down the device goes back to logind
/// and DRM master is dropped; on the way up the device is taken back, the
/// VT is re-activated, DRM master is re-acquired and the flip pipeline is
/// re-armed (a flip that was in flight when the machine slept never
/// completes, so `flip_pending` must be cleared or the output would refuse
/// every commit until the next event).
fn handlePrepareForSleep(self: *DrmBackendData, sleeping: bool) void {
    const have_logind = self.session != null;
    const phase = if (self.session) |s| s.sleepPhase() else .running;
    const plan = session_mod.planSleep(phase, sleeping, have_logind);
    if (plan.work.drop_master and self.is_master) {
        const fd = self.fd orelse return;
        if (c.drmIoctl(fd, c.DRM_IOCTL_DROP_MASTER, null) == 0) {
            self.is_master = false;
            log_mod.info("drm: suspend: DRM master dropped", self.io, self.log_cfg, "drm", .{});
        } else {
            log_mod.warn("drm: suspend: DRM_IOCTL_DROP_MASTER failed", self.io, self.log_cfg, "drm", .{});
        }
    }
    if (plan.work.reacquire) {
        becomeMaster(self);
        for (self.outputs.items) |drm_out| {
            // The flip that was in flight across the suspend will never
            // complete, so its completion event will never arrive.
            drm_out.flip_pending = false;
        }
        log_mod.info("drm: resume: DRM master and flip pacing re-armed", self.io, self.log_cfg, "drm", .{});
    }
}

/// Phase 7: the udev monitor that turns connector changes into output
/// add/remove. NON-fatal: without libudev (or without its netlink socket)
/// the compositor simply does not react to a cable being plugged, and says
/// so once.
fn openHotplug(self: *DrmBackendData) void {
    self.hotplug = session_mod.Hotplug.open(self.allocator) catch |err| {
        log_mod.info(
            "drm: connector hotplug disabled ({s}); outputs are fixed for this run",
            self.io,
            self.log_cfg,
            "drm",
            .{@errorName(err)},
        );
        return;
    };
    log_mod.info(
        "drm: watching the drm subsystem for connector changes (fd {d})",
        self.io,
        self.log_cfg,
        "drm",
        .{self.hotplug.?.pollFd()},
    );
}

/// The extra fds the server's event loop must poll for M6 to be live: the
/// logind bus (PrepareForSleep) and the udev monitor (connector changes).
/// Both are -1 when the feature is not available, and the server skips
/// them - `dispatchSession` and `dispatchHotplug` are then no-ops.
///
/// The server wires these next to the DRM fd it already registers for
/// `dispatch` (src/server/main.zig: `zio.ev.PipePoll.init(drm_fd, .read)`
/// / onDrmReady): one PipePoll per non -1 fd, each calling the matching
/// dispatch on readability. Nothing else about the loop changes.
pub const ExtraFds = struct {
    /// Poll for readability, then call `dispatchSession`.
    session: std.posix.fd_t = -1,
    /// Poll mask for `session` (POLLIN, plus POLLOUT when the bus must
    /// flush).
    session_events: i16 = 0,
    /// Poll for readability, then call `dispatchHotplug`.
    hotplug: std.posix.fd_t = -1,
    /// Poll mask for `hotplug`.
    hotplug_events: i16 = 0,
    /// The logind connection's own timeout, if it has one.
    session_timeout_us: ?u64 = null,
};

pub fn extraFds(self: *DrmBackendData) ExtraFds {
    var fds: ExtraFds = .{};
    if (self.session) |s| {
        fds.session = s.pollFd();
        fds.session_events = s.pollEvents();
        fds.session_timeout_us = s.pollTimeoutUs();
    }
    if (self.hotplug) |hp| {
        fds.hotplug = hp.pollFd();
        fds.hotplug_events = hp.pollEvents();
    }
    return fds;
}

/// Drain the logind bus. Called when `extraFds().session` is readable; runs
/// one suspend/resume step if logind asked for one. Non-fatal throughout
/// (session.zig's failure policy).
pub fn dispatchSession(self: *DrmBackendData) void {
    const s = self.session orelse return;
    s.dispatch();
}

/// Drain the udev monitor and reconcile the output list with the hardware.
/// Called when `extraFds().hotplug` is readable.
///
/// One reconciliation per batch of events, and it is the same one whatever
/// the event was:
///
///   1. destroy the outputs whose connector is no longer connected
///      (`removeDisconnectedOutputs`) - this is the unplug path, and it is
///      what tells clients their wl_output is gone (wlroots calls
///      destroy_drm_connector on DRM_REMOVE, backend/drm/backend.c);
///   2. bring up an output for any connector that is connected and not yet
///      driven, through the very same `addOutput` path start() used - this
///      is the plug path (wlroots calls init_drm_connector on DRM_ADD and
///      DRM_CHANGE).
///
/// Reconciling on EVERY event rather than branching on the action is
/// deliberate: a connector arriving is an "add" on some drivers and a
/// "change" on others (a cable going into a connector the kernel already
/// knows flips its status file, drm_connector.c connector_detect ->
/// drm_sysfs_connector_status), and DRM does not promise which. Asking KMS
/// for the truth instead of trusting the event's verb is what makes a plug
/// work on all of them.
///
/// A failure while adding is logged and the remaining events are still
/// drained: one connector that cannot be driven is not a reason to take the
/// backend down.
pub fn dispatchHotplug(base: *backend_mod.Backend, self: *DrmBackendData) void {
    const hp = self.hotplug orelse return;
    var seen: usize = 0;
    while (hp.next()) |event| {
        seen += 1;
        // Only the drm subsystem reaches this monitor (the filter is set in
        // session.zig's Hotplug.open); anything else is logged and skipped
        // so a surprise cannot drive a modeset.
        log_mod.debug(
            "drm: udev {s} {s}",
            self.io,
            self.log_cfg,
            "drm",
            .{ @tagName(event.action), event.sysname },
        );
        if (!event.isConnector() and event.action != .remove) {
            log_mod.debug(
                "drm: udev event on {s} is not a connector; reconciling anyway",
                self.io,
                self.log_cfg,
                "drm",
                .{event.sysname},
            );
        }
    }
    if (seen == 0) return;
    removeDisconnectedOutputs(self);
    _ = addOutput(base, self) catch |err| {
        // "Nothing new" is the normal outcome of a change event on a
        // connector we already drive, so this is only worth a debug line.
        log_mod.debug(
            "drm: hotplug: no new output ({s})",
            self.io,
            self.log_cfg,
            "drm",
            .{@errorName(err)},
        );
    };
}

/// The DRM primary minor a card node names: "card0" -> 0. libdrm builds
/// node names the same way (xf86drmMode.h DRM_DEV_NAME is "%s/%s%d" over
/// DRM_PRIMARY_MINOR_NAME = "card"), and logind's TakeDevice wants that
/// number.
///
/// A path that is not a card node (a render node, an empty path) answers 0,
/// which is what logind will refuse - deliberately. Guessing a minor from a
/// name we do not understand would claim a device we do not hold.
fn cardMinor(path: []const u8) u32 {
    const base = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, base, "card")) return 0;
    const digits = base["card".len..];
    if (digits.len == 0 or digits.len > 2) return 0;
    return std.fmt.parseUnsigned(u32, digits, 10) catch 0;
}

/// Phase 3b: bring up the GBM device this backend can import client
/// dmabufs into, and enumerate the (format, modifier) pairs it accepts.
///
/// Node choice follows wlroots' allocator: prefer the RENDER node of the
/// same DRM device, fall back to the primary one
/// (`reopen_drm_node(drm_fd, /*allow_render_node=*/true)`,
/// render/allocator/allocator.c:38-67). The node is re-opened rather than
/// reusing the KMS fd for the reason wlroots gives: sharing GEM handle
/// refcounts between the display and the allocator is what
/// mesa/drm!110 is about, and a render node carries no modeset
/// authority we would then have to defend.
///
/// Every failure here is NON-fatal. A node with no GBM (a virtual machine
/// without a render node, a driver whose gbm_create_device refuses) must
/// still scan out; it simply does not get a zwp_linux_dmabuf_v1 global.
/// The reverse is not negotiable: a global without a device behind it is a
/// promise the client can falsify on its first create request.
fn openGbm(self: *DrmBackendData) error{OutOfMemory}!void {
    const node = gbmNodePath(self) orelse {
        log_mod.info("drm: no GBM node for {s}; dmabuf import disabled", self.io, self.log_cfg, "drm", .{
            self.device_path,
        });
        return;
    };
    const dev = dmabuf.GbmDevice.create(self.allocator, node) catch |err| {
        log_mod.warn("drm: gbm device on {s} failed ({s}); dmabuf import disabled", self.io, self.log_cfg, "drm", .{
            node,
            @errorName(err),
        });
        return;
    };
    errdefer dev.deinit();
    dev.setFormats(try queryGbmFormats(self, dev));
    if (dev.formats.len == 0) {
        log_mod.info("drm: GBM on {s} advertises no supported format; dmabuf import disabled", self.io, self.log_cfg, "drm", .{node});
        return;
    }
    self.gbm = dev;
    log_mod.info("drm: GBM {s} on {s} with {d} format/modifier pairs", self.io, self.log_cfg, "drm", .{
        dev.backendName(),
        node,
        dev.formats.len,
    });
}

/// The node to open a GBM device on: this device's render node when it
/// has one, its primary node otherwise. Both names come from the already
/// open KMS fd, so they always name the same physical device
/// (wlroots reopen_drm_node, render/allocator/allocator.c:53-65).
fn gbmNodePath(self: *DrmBackendData) ?[:0]const u8 {
    const fd = self.fd.?;
    if (c.drmGetRenderDeviceNameFromFd(fd)) |name| {
        defer std.c.free(name);
        return std.mem.span(name);
    }
    if (c.drmGetDeviceNameFromFd2(fd)) |name| {
        defer std.c.free(name);
        return std.mem.span(name);
    }
    return null;
}

/// The (format, modifier) pairs this GBM device really accepts.
///
/// One modifier is considered: DRM_FORMAT_MOD_LINEAR. GBM is the authority
/// for whether a (format, modifier) pair is importable at all
/// (`gbm_device_get_format_modifier_plane_count`, the call that decides
/// what wlroots' renderer would accept in render/allocator/gbm.c:71-87), and
/// linear is the one layout that is meaningful for this compositor: the
/// KMS scanout here is a dumb XRGB8888 buffer, and there is no tiled or
/// compressed modifier anywhere in the pipeline that could present one.
///
/// The kernel's FULL per-format modifier list (the IN_FORMATS_MODIFIERS
/// blob on each plane) is deliberately not walked: reading it needs a
/// per-plane property walk this backend does not otherwise do, and
/// advertising a tiled modifier we cannot scan out would be a promise the
/// first page flip would break. A driver that can only do tiled layouts
/// therefore ends up with no advertised pair, and with no
/// zwp_linux_dmabuf_v1 global - which is the honest answer.
fn queryGbmFormats(self: *DrmBackendData, dev: *dmabuf.GbmDevice) error{OutOfMemory}![]dmabuf.Format {
    var list: std.ArrayList(dmabuf.Format) = .empty;
    errdefer list.deinit(self.allocator);
    for (gbm_candidate_formats) |format| {
        if (gbm_c.gbm_device_get_format_modifier_plane_count(dev.device, format, dmabuf.drm_format_mod_linear) < 1) continue;
        if (dmabuf.supports(list.items, format, dmabuf.drm_format_mod_linear)) continue;
        try list.append(self.allocator, .{ .format = format, .modifier = dmabuf.drm_format_mod_linear });
    }
    return list.items;
}

/// Find the next connector this backend does not drive yet: connected, with
/// a mode, and with a CRTC no live output holds (wlroots drm.c
/// init_drm_resources + drm_connector_alloc_crtc).
///
/// Connectors already bound to a live output are skipped inside the scan
/// (see connectorBound), so one call per connector brings every output up
/// and a hotplug "add" finds only the connector that is actually new. Null
/// when nothing is left, which is the normal end of the loop rather than a
/// failure.
fn enumerateTarget(self: *DrmBackendData) ?FoundConnector {
    const found = findConnectorMode(self) orelse return null;
    log_mod.info(
        "drm: {s} connector={d} mode={d}x{d}",
        self.io,
        self.log_cfg,
        "drm",
        .{ basename(self.device_path), found.connector_id, found.mode.hdisplay, found.mode.vdisplay },
    );
    return found;
}

/// Bring up one output. Returns true when it did, false when there was no
/// connector left to bring one up for.
///
/// Every phase inside is the same one the first start() used, in the same
/// order (see startInner): resolve the plane, allocate the output that will
/// own the device resources, resolve the property ids, allocate the A/B
/// swapchain, create the mode blob, modeset, announce. Calling it again
/// after a udev event is how a plugged cable becomes an output, and it
/// reuses that enumeration rather than growing a second one.
///
/// The bool is what lets start() say `while (try addOutput(...)) {}`: the
/// enumeration skips connectors that already drive an output, so the call
/// that finds none ends the loop. It is also an error only while NO output
/// is up - a device with nothing connected cannot announce an output, and
/// that is a backend failure; afterwards, "nothing new" is the normal
/// answer to a hotplug event.
fn addOutput(base: *backend_mod.Backend, self: *DrmBackendData) error{ BackendFailed, OutOfMemory }!bool {
    const found = enumerateTarget(self) orelse {
        // Nothing left. With no live output that is a real failure - the
        // device has nothing to show - and drmTeardown takes the backend
        // down; with outputs already up it is the normal "nothing new"
        // answer after a hotplug event.
        if (self.outputs.items.len == 0) {
            log_mod.err("drm: no connected connector with a mode on {s}", self.io, self.log_cfg, "drm", .{
                self.device_path,
            });
            return error.BackendFailed;
        }
        return false;
    };
    const plane = try resolvePlane(self, found);
    const drm_out = try allocOutput(self, found, plane);
    try scanKmsProps(self, found, drm_out);
    try createScanoutBuffers(self, found, drm_out);
    try createModeBlob(self, found, drm_out);
    // `found` by pointer: the legacy drmModeSetCrtc path passes
    // &found.connector_id / &found.mode to C, which wants mutable [*c].
    var mutable = found;
    try modeset(self, &mutable, plane, drm_out);
    try announceOutput(base, self, drm_out);
    return true;
}
/// Is this connector already driving one of our outputs? A linear scan over
/// a handful of entries - cheaper than materialising an id list, and it
/// cannot go stale between the check and the use, which is the failure mode
/// a cached list would have. wlroots skips bound connectors the same way
/// (backend/drm/drm.c realloc_crtcs skips the connectors already allocated).
fn connectorBound(self: *DrmBackendData, connector_id: u32) bool {
    for (self.outputs.items) |drm_out| {
        if (drm_out.connector_id == connector_id) return true;
    }
    return false;
}

/// Phase 6: allocate the DrmOutput that owns every device resource the
/// later phases create (wlroots attaches the mode, buffers and blobs to
/// the output it enables). Ownership moves to the backend list before
/// returning, so a failure further down still reaches these through
/// drmTeardown; destroy() frees the structs themselves.
fn allocOutput(self: *DrmBackendData, found: FoundConnector, plane: PlaneSelection) error{OutOfMemory}!*DrmOutput {
    const drm_out = try self.allocator.create(DrmOutput);
    drm_out.* = .{
        .backend = self,
        .crtc_id = found.crtc_id,
        .plane_id = plane.id,
        .props = plane.props,
        .connector_id = found.connector_id,
        .mode = modeToOutput(found.mode),
        .refresh_ns = modeRefreshNs(found.mode),
    };
    // Append before the resources exist: drmTeardown walks the list, so a
    // phase that dies after this point releases what did get created.
    errdefer self.allocator.destroy(drm_out);
    try self.outputs.append(self.allocator, drm_out);
    return drm_out;
}

/// Phase 5: the primary plane for the CRTC, with all commit property ids
/// (wlroots drm.c init_plane: possible_crtcs + type == PRIMARY).
/// Atomic-only: the legacy interface has no planes — modeset and flips
/// target the CRTC directly (drmModeSetCrtc/drmModePageFlip), so the
/// selection stays zeroed.
fn resolvePlane(self: *DrmBackendData, found: FoundConnector) error{BackendFailed}!PlaneSelection {
    if (!self.atomic) return .{};
    var props: PlanePropIds = .{};
    const id = findPrimaryPlane(self, found.crtc_index, &props) orelse {
        log_mod.err("drm: no primary plane for crtc={d}", self.io, self.log_cfg, "drm", .{found.crtc_id});
        return error.BackendFailed;
    };
    return .{ .id = id, .props = props };
}

/// Phase 7: connector + crtc property ids (wlroots properties.c tables).
/// Atomic-only: the legacy modeset binds the connector to the CRTC
/// implicitly via drmModeSetCrtc, so no property ids are needed.
fn scanKmsProps(self: *DrmBackendData, found: FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    if (!self.atomic) return;
    const fd = self.fd.?;
    // SAFETY: scanPropIds @memsets the whole output array to 0 as its
    // first statement, so every element is initialized before it reads
    // one — and it returns false without filling in any id.
    var conn_props: [1]u32 = undefined;
    if (!scanPropIds(fd, found.connector_id, c.DRM_MODE_OBJECT_CONNECTOR, &[_][]const u8{"CRTC_ID"}, &conn_props)) {
        log_mod.err("drm: connector CRTC_ID property missing", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
    // SAFETY: as conn_props above — scanPropIds zeroes before writing.
    var crtc_props: [2]u32 = undefined;
    if (!scanPropIds(
        fd,
        found.crtc_id,
        c.DRM_MODE_OBJECT_CRTC,
        &[_][]const u8{ "MODE_ID", "ACTIVE" },
        &crtc_props,
    )) {
        log_mod.err("drm: crtc MODE_ID/ACTIVE properties missing", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
    drm_out.connector_crtc_id = conn_props[0];
    drm_out.crtc_mode_id = crtc_props[0];
    drm_out.crtc_active = crtc_props[1];
}

/// Phase 8: the A/B swapchain - TWO framebuffers, because every flip must
/// change FB_ID (see the DrmOutput.buffers doc: virtio-gpu's plane update is
/// damage-gated).
///
/// Which allocation backs them is one decision, taken once per output by
/// `chooseScanout` and then executed by whichever path it picked:
///
///  - **plane** (`createPlaneBuffers`): real GEM buffer objects from the
///    GBM device this backend already owns, added with the modifier GBM
///    reported. The primary plane then scans out a genuine framebuffer on a
///    real plane - the planes+modifiers half of GBM support.
///  - **dumb** (`createDumbBuffers`, the original path): CREATE_DUMB +
///    MAP_DUMB + ADDFB2. Still the fallback, and still what the VM uses
///    today; it needs no GBM device, no render node and no modifier.
///
/// The plane path is attempted FIRST and any failure in it falls back to
/// dumb rather than failing the backend: a driver whose bo cannot be
/// mmap'd for CPU access, or that has no GBM device at all, must still
/// scan out. A partial failure is fine either way - drmTeardown is
/// idempotent and releases whatever was created.
fn createScanoutBuffers(self: *DrmBackendData, found: FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    if (chooseScanout(self, drm_out.plane_id).use_plane) {
        createPlaneBuffers(self, found, drm_out) catch |err| {
            log_mod.warn(
                "drm: plane scanout buffers failed ({s}); falling back to dumb buffers",
                self.io,
                self.log_cfg,
                "drm",
                .{@errorName(err)},
            );
            releaseBuffers(self, drm_out);
            drm_out.scanout = .dumb;
            return createDumbBuffers(self, found, drm_out);
        };
        drm_out.scanout = .plane;
        log_mod.info(
            "drm: {d} GBM framebuffers (modifier 0x{x}) on plane {d}",
            self.io,
            self.log_cfg,
            "drm",
            .{ drm_out.buffers.len, drm_out.buffers[0].modifier, drm_out.plane_id },
        );
        return;
    }
    drm_out.scanout = .dumb;
    try createDumbBuffers(self, found, drm_out);
}

/// The dumb path, unchanged: CREATE_DUMB -> MAP_DUMB -> mmap -> ADDFB2,
/// twice (smithay src/backend/drm/dumb.rs framebuffer_from_dumb_buffer;
/// wlroots uses the same ioctls through allocator/drm_dumb.c).
fn createDumbBuffers(self: *DrmBackendData, found: FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    const fd = self.fd.?;
    const width: u32 = found.mode.hdisplay;
    const height: u32 = found.mode.vdisplay;

    for (&drm_out.buffers) |*buf| {
        var create_dumb: c.struct_drm_mode_create_dumb = .{
            .height = height,
            .width = width,
            .bpp = 32,
            .flags = 0,
        };
        if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &create_dumb) != 0) {
            log_mod.err("drm: DRM_IOCTL_MODE_CREATE_DUMB failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
        buf.handle = create_dumb.handle;
        buf.pitch = create_dumb.pitch;
        const size: usize = @intCast(create_dumb.size);

        var map_dumb: c.struct_drm_mode_map_dumb = .{ .handle = create_dumb.handle };
        if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &map_dumb) != 0) {
            log_mod.err("drm: DRM_IOCTL_MODE_MAP_DUMB failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
        buf.map = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            map_dumb.offset,
        ) catch {
            log_mod.err("drm: mmap dumb buffer failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        };

        var fb2: c.struct_drm_mode_fb_cmd2 = .{
            .width = width,
            .height = height,
            .pixel_format = drm_format_xrgb8888,
            .handles = .{ create_dumb.handle, 0, 0, 0 },
            .pitches = .{ create_dumb.pitch, 0, 0, 0 },
            .offsets = .{ 0, 0, 0, 0 },
        };
        if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_ADDFB2, &fb2) != 0) {
            log_mod.err("drm: DRM_IOCTL_MODE_ADDFB2 failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
        buf.fb_id = fb2.fb_id;
    }
}

/// The plane path: two GBM buffer objects, mapped for the CPU and added to
/// DRM with the modifier GBM gave them.
///
/// Steps, and why each one:
///  1. `gbm_bo_create(SCANOUT | LINEAR)` - SCANOUT because this is what the
///     KMS plane will display, LINEAR because the compositor writes it from
///     the CPU (the pixman framebuffer is host memory and copyRows has no
///     GPU renderer to upload through). wlroots asks for the same pair when
///     it needs a linear scanout buffer (render/allocator/gbm.c:
///     GBM_BO_USE_SCANOUT | GBM_BO_USE_LINEAR). RENDERING is a second
///     attempt: several drivers refuse to map a scanout-only bo.
///  2. `gbm_bo_map(READ | WRITE)` - the CPU view copyRows writes through.
///     A bo that cannot be mapped is the single most likely reason this
///     path has to fall back to dumb buffers.
///  3. `drmModeAddFB2WithModifiers` with `gbm_bo_get_modifier(bo)` - the
///     modifier-aware framebuffer add (xf86drmMode.h). Passing the modifier
///     the driver actually chose is what lets a tiled or compressed plane
///     take these buffers; the plain ADDFB2 struct has no field for it. The
///     GEM handle comes from `gbm_bo_get_handle_for_plane(bo, 0)`: DRM
///     handles are per-DEVICE, not per-fd, so a handle from the GBM render
///     node is valid on this KMS fd for the same card - which is why the GBM
///     device is opened on this device's own node (openGbm/gbmNodePath) and
///     never on another.
fn createPlaneBuffers(self: *DrmBackendData, found: FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    const gbm = self.gbm orelse return error.BackendFailed;
    const width: u32 = found.mode.hdisplay;
    const height: u32 = found.mode.vdisplay;

    // SCANOUT alone first, then with RENDERING: a bo the driver will not
    // scan out but will render to is still a fine framebuffer for us.
    const usages = [_]u32{
        gbm_c.GBM_BO_USE_SCANOUT | gbm_c.GBM_BO_USE_LINEAR,
        gbm_c.GBM_BO_USE_SCANOUT | gbm_c.GBM_BO_USE_LINEAR | gbm_c.GBM_BO_USE_RENDERING,
    };
    var first: ?ScanoutBuffer = null;
    var usage_index: usize = 0;
    while (usage_index < usages.len) : (usage_index += 1) {
        first = allocPlaneBuffer(self, gbm.device, width, height, usages[usage_index]) catch |err| switch (err) {
            error.BackendFailed => continue,
        };
        break;
    }
    // Nothing allocated at all: let the caller fall back to dumb buffers.
    var buffer = first orelse return error.BackendFailed;
    errdefer releaseBuffer(self, &buffer);

    const second = allocPlaneBuffer(self, gbm.device, width, height, usages[usages.len - 1]) catch
        return error.BackendFailed;
    drm_out.buffers[0] = buffer;
    drm_out.buffers[1] = second;
}

/// One GEM buffer object mapped for the CPU and added to DRM as a
/// framebuffer with its modifier. Null-safe on every failure: a bo that was
/// created is unmapped and destroyed before returning, and a bo that was
/// added and then abandoned is RmFB'd in `releaseBuffer`.
fn allocPlaneBuffer(
    self: *DrmBackendData,
    device: *gbm_c.struct_gbm_device,
    width: u32,
    height: u32,
    usage: u32,
) error{BackendFailed}!ScanoutBuffer {
    const fd = self.fd.?;
    const bo = gbm_c.gbm_bo_create(device, width, height, drm_format_xrgb8888, usage) orelse
        return error.BackendFailed;
    var stride_out: u32 = 0;
    var map_ptr: ?*anyopaque = null;
    if (gbm_c.gbm_bo_map(bo, 0, 0, width, height, gbm_c.GBM_BO_TRANSFER_READ_WRITE, &stride_out, &map_ptr) == null or map_ptr == null) {
        gbm_c.gbm_bo_destroy(bo);
        return error.BackendFailed;
    }
    const stride = gbm_c.gbm_bo_get_stride(bo);
    if (stride == 0) {
        gbm_c.gbm_bo_unmap(bo, map_ptr);
        gbm_c.gbm_bo_destroy(bo);
        return error.BackendFailed;
    }
    const handle = gbm_c.gbm_bo_get_handle_for_plane(bo, 0);
    const modifier = gbm_c.gbm_bo_get_modifier(bo);
    const handles = [1]u32{handle.u32};
    const pitches = [1]u32{stride};
    const offsets = [1]u32{gbm_c.gbm_bo_get_offset(bo, 0)};
    const modifiers = [1]u64{modifier};
    var fb_id: u32 = 0;
    if (c.drmModeAddFB2WithModifiers(fd, width, height, drm_format_xrgb8888, &handles, &pitches, &offsets, &modifiers, &fb_id, 0) != 0) {
        gbm_c.gbm_bo_unmap(bo, map_ptr);
        gbm_c.gbm_bo_destroy(bo);
        return error.BackendFailed;
    }
    const pixels: [*]u8 = @ptrCast(map_ptr.?);
    return .{
        .fb_id = fb_id,
        .pitch = stride,
        // One row per scanline, each `stride` bytes; copyRows reads at most
        // width*4 out of each and never past the last row's end.
        .map = pixels[0 .. @as(usize, stride) * height],
        .gem_handle = handle.u32,
        .modifier = modifier,
        .bo = bo,
        .bo_map = map_ptr,
    };
}

/// The scanout decision, as pure data so it can be tested without a card.
///
/// `use_plane` is true only when every precondition holds: a GBM device
/// exists, the caller owns a real PRIMARY plane (plane_id != 0, i.e. the
/// atomic interface - the legacy path has no planes and flips through the
/// CRTC), and GBM advertises at least one (format, modifier) pair with a
/// plane behind it. Anything else is the dumb path, which is what the VM
/// runs today and what must keep working.
const ScanoutChoice = struct {
    use_plane: bool,
    /// Which precondition failed, for the log line at the decision point.
    reason: Reason,

    const Reason = enum { plane, no_gbm, no_plane, gbm_has_no_format };

    /// The decision itself, from the three facts that drive it. Kept free of
    /// the backend so it can be tested on any machine.
    fn decide(has_gbm: bool, has_formats: bool, plane_id: u32) ScanoutChoice {
        if (!has_gbm) return .{ .use_plane = false, .reason = .no_gbm };
        if (plane_id == 0) return .{ .use_plane = false, .reason = .no_plane };
        if (!has_formats) return .{ .use_plane = false, .reason = .gbm_has_no_format };
        return .{ .use_plane = true, .reason = .plane };
    }
};

fn chooseScanout(self: *DrmBackendData, plane_id: u32) ScanoutChoice {
    const gbm = self.gbm orelse return ScanoutChoice.decide(false, false, plane_id);
    return ScanoutChoice.decide(true, gbm.formats.len != 0, plane_id);
}

/// Phase 9: the mode blob (wlroots atomic.c create_mode_blob). Atomic-only:
/// the legacy modeset passes the drmModeModeInfo directly to drmModeSetCrtc.
fn createModeBlob(self: *DrmBackendData, found: FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    if (!self.atomic) return;
    var blob_id: u32 = 0;
    if (c.drmModeCreatePropertyBlob(self.fd.?, &found.mode, @sizeOf(c.drmModeModeInfo), &blob_id) != 0) {
        log_mod.err("drm: drmModeCreatePropertyBlob failed", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
    drm_out.mode_blob = blob_id;
}

/// Phase 10: apply the mode. Atomic commits every binding in one request;
/// legacy binds connector + CRTC + fb in a single drmModeSetCrtc. Both
/// paths are synchronous (no flip event) — the first frame's page flip
/// sends the event.
fn modeset(
    self: *DrmBackendData,
    found: *FoundConnector,
    plane: PlaneSelection,
    drm_out: *DrmOutput,
) error{BackendFailed}!void {
    if (self.atomic) return atomicModeset(self, found, plane, drm_out);
    return legacyModeset(self, found, drm_out);
}

/// Phase 10a: the atomic modeset — connector->crtc binding, crtc
/// active+mode, plane fb + full source/dest rect + full-fb damage clip
/// (wlroots atomic.c atomic_connector_add + set_plane_props; smithay
/// surface/atomic.rs set_connector/set_crtc/set_plane). `found` travels
/// by pointer because libdrm's legacy twin takes the connector and mode
/// as non-const C pointers, and both phases share this signature.
fn atomicModeset(
    self: *DrmBackendData,
    found: *FoundConnector,
    plane: PlaneSelection,
    drm_out: *DrmOutput,
) error{BackendFailed}!void {
    const fd = self.fd.?;
    // FB_DAMAGE_CLIPS (full-fb rect) must ride every commit touching
    // the plane: virtio-gpu's plane update is gated on merged damage
    // clips — drivers/gpu/drm/virtio/virtgpu_plane.c
    // virtio_gpu_plane_atomic_update early-returns before the scanout
    // switch and the dumb upload/flush when
    // drm_atomic_helper_damage_merged() finds nothing, and our commits
    // otherwise change only FB_ID (wlroots atomic.c
    // drm_atomic_connector_prepare -> create_fb_damage_clips_blob,
    // set_plane_props adds the blob id). Skipped when the driver lacks
    // the property (fb_damage_clips == 0).
    var damage_blob: u32 = 0;
    if (plane.props.fb_damage_clips != 0) {
        if (!createDamageBlob(fd, found.mode.hdisplay, found.mode.vdisplay, &damage_blob)) {
            log_mod.err("drm: create FB_DAMAGE_CLIPS blob failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
    }
    // The kernel copies the clips into the plane state at commit
    // time; the blob is destroyed right after (wlroots atomic.c
    // drm_atomic_connector_commit_state: destroy_blob(state->fb_damage_clips)).
    defer {
        if (damage_blob != 0) _ = c.drmModeDestroyPropertyBlob(fd, damage_blob);
    }

    const req = c.drmModeAtomicAlloc() orelse {
        log_mod.err("drm: drmModeAtomicAlloc failed", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    };
    defer c.drmModeAtomicFree(req);
    if (!addModesetProps(req, found, plane, drm_out, damage_blob)) {
        log_mod.err("drm: atomic modeset property add failed", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
    log_mod.debug(
        "drm: modeset commit plane={d} fbA={d} fbB={d} damage_prop={d} damage_blob={d}",
        self.io,
        self.log_cfg,
        "drm",
        .{ plane.id, drm_out.buffers[0].fb_id, drm_out.buffers[1].fb_id, plane.props.fb_damage_clips, damage_blob },
    );
    const commit_rc = c.drmModeAtomicCommit(fd, req, c.DRM_MODE_ATOMIC_ALLOW_MODESET, null);
    if (commit_rc != 0) {
        logAtomicModesetFailure(self, found, plane, drm_out, damage_blob, commit_rc);
        return error.BackendFailed;
    }
}

/// The property set an atomic modeset commits, in the order wlroots adds
/// them: the connector's CRTC_ID, then the CRTC's MODE_ID and ACTIVE,
/// then the plane's FB_ID, the full 16.16 source rect, the full
/// destination rect and — when the driver has the property — the damage
/// blob (wlroots atomic.c atomic_connector_add adds connector state,
/// then crtc state, then set_plane_props for the primary plane and its
/// fb_damage_clips). SRC_* is 16.16 fixed point, the destination rect
/// plain pixels. False when the driver rejects any add: the request is
/// then not committed at all rather than committed half-filled.
fn addModesetProps(
    req: c.drmModeAtomicReqPtr,
    found: *FoundConnector,
    plane: PlaneSelection,
    drm_out: *DrmOutput,
    damage_blob: u32,
) bool {
    const src_w = fixed16(found.mode.hdisplay);
    const src_h = fixed16(found.mode.vdisplay);
    if (c.drmModeAtomicAddProperty(req, found.connector_id, drm_out.connector_crtc_id, found.crtc_id) < 0 or
        c.drmModeAtomicAddProperty(req, found.crtc_id, drm_out.crtc_mode_id, drm_out.mode_blob) < 0 or
        c.drmModeAtomicAddProperty(req, found.crtc_id, drm_out.crtc_active, 1) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.crtc_id, found.crtc_id) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.fb_id, drm_out.buffers[0].fb_id) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.src_x, 0) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.src_y, 0) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.src_w, src_w) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.src_h, src_h) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.crtc_x, 0) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.crtc_y, 0) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.crtc_w, found.mode.hdisplay) < 0 or
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.crtc_h, found.mode.vdisplay) < 0 or
        (plane.props.fb_damage_clips != 0 and
            c.drmModeAtomicAddProperty(req, plane.id, plane.props.fb_damage_clips, damage_blob) < 0))
    {
        return false;
    }
    return true;
}

/// Why the atomic modeset commit was rejected: the errno plus every
/// property id and value that went into the request. The kernel answers a
/// bad property set with a bare -EINVAL, so the request has to be
/// readable from the log alone. Split out of `atomicModeset` to keep the
/// commit sequence itself legible.
fn logAtomicModesetFailure(
    self: *DrmBackendData,
    found: *FoundConnector,
    plane: PlaneSelection,
    drm_out: *DrmOutput,
    damage_blob: u32,
    commit_rc: c_int,
) void {
    log_mod.err(
        "drm: atomic modeset commit failed (errno {s}); props: " ++
            "conn{{id={d},crtc_prop={d},crtc={d}}} " ++
            "crtc{{id={d},mode_prop={d},mode={d},active_prop={d}}} " ++
            "plane{{id={d},crtc_prop={d},crtc={d},fb_prop={d},fb={d}," ++
            "src={d},{d},{d},{d},dst={d},{d},{d},{d},damage_prop={d},damage={d}}}",
        self.io,
        self.log_cfg,
        "drm",
        .{
            @tagName(std.os.linux.errno(@as(usize, @bitCast(@as(isize, @intCast(commit_rc)))))),
            found.connector_id,
            drm_out.connector_crtc_id,
            found.crtc_id,
            found.crtc_id,
            drm_out.crtc_mode_id,
            drm_out.mode_blob,
            drm_out.crtc_active,
            plane.id,
            plane.props.crtc_id,
            found.crtc_id,
            plane.props.fb_id,
            drm_out.buffers[0].fb_id,
            plane.props.src_x,
            plane.props.src_y,
            plane.props.src_w,
            plane.props.src_h,
            plane.props.crtc_x,
            plane.props.crtc_y,
            plane.props.crtc_w,
            plane.props.crtc_h,
            plane.props.fb_damage_clips,
            damage_blob,
        },
    );
}

/// Phase 10b: the legacy modeset — bind the connector to the CRTC and
/// apply the mode in one call (wlroots legacy.c:121-126 drmModeSetCrtc
/// with the connector array + mode). buffers[0] is the A side of the
/// swapchain; the first commit flips to buffers[1].
fn legacyModeset(self: *DrmBackendData, found: *FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    if (c.drmModeSetCrtc(
        self.fd.?,
        found.crtc_id,
        drm_out.buffers[0].fb_id,
        0,
        0,
        &found.connector_id,
        1,
        &found.mode,
    ) != 0) {
        log_mod.err("drm: drmModeSetCrtc failed", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
}

/// Phase 11: announce the output, then kick the first frame. The
/// compositor attaches its frame listener during the emit, so the flip
/// event chain starts here (wlroots: wlr_output_send_frame after modeset).
/// This is the last phase that can fail, and only on allocation — the
/// device is already live, so the errdefer in startInner tears the whole
/// output back down.
fn announceOutput(base: *backend_mod.Backend, self: *DrmBackendData, drm_out: *DrmOutput) error{OutOfMemory}!void {
    const out = try output_mod.Output.create(
        self.allocator,
        self.io,
        self.log_cfg,
        base,
        &output_impl,
        drm_out,
        drm_out.mode,
    );
    drm_out.out = out;
    // The page-flip completion IS the real present: presentation
    // feedback gates on this output's presented event instead of
    // synthesizing.
    out.emits_present = true;
    base.emitNewOutput(out);
    out.sendFrame();
    log_mod.info("drm: modeset ok, output live", self.io, self.log_cfg, "drm", .{});
}

// ---------------------------------------------------------------------------
// Output impl
// ---------------------------------------------------------------------------

fn testState(out: *output_mod.Output, state: *const output_mod.Output.State) error{InvalidState}!void {
    const self: *DrmOutput = @ptrCast(@alignCast(out.data));
    // Unsupported-state mask (wlroots drm_connector_prepare,
    // drm.c:838-840): scale and transform are not applied by this
    // backend — the modeset pinned the plane's source/dest rect at init
    // and commits only change FB_ID, so any such state would be silently
    // ignored.
    const supported = output_mod.Output.State.committed_enabled |
        output_mod.Output.State.committed_mode |
        output_mod.Output.State.committed_buffer;
    if (state.committed & ~supported != 0) return error.InvalidState;
    // Mode changes are rejected: the dumb buffer and modeset are fixed
    // at init (single-mode backend for now). The refresh value is
    // advisory (pacing comes from the flip event, not the refresh
    // timer), so only the size must match the scanout buffer.
    if (state.committed & output_mod.Output.State.committed_mode != 0) {
        if (state.mode) |m| {
            if (m.width != self.mode.width or m.height != self.mode.height) return error.InvalidState;
        }
    }
    if (state.committed & output_mod.Output.State.committed_buffer != 0) {
        const fb: *pixman.Framebuffer = @ptrCast(@alignCast(state.buffer orelse return error.InvalidState));
        if (fb.width != self.mode.width or fb.height != self.mode.height) return error.InvalidState;
        if (fb.stride < fb.width * 4) return error.InvalidState;
    }
}

fn commit(out: *output_mod.Output, state: *const output_mod.Output.State) error{CommitFailed}!void {
    const self: *DrmOutput = @ptrCast(@alignCast(out.data));
    if (state.committed & output_mod.Output.State.committed_buffer == 0) return;
    if (self.backend.fd == null) return error.CommitFailed;

    // Frame pacing guarantees at most one flip in flight (the event for
    // the previous flip drives the next frame); a second flip before the
    // event would EBUSY. wlroots atomic.c guards the same way.
    if (self.flip_pending) {
        // Normal pacing under the requestRender-driven model: a commit
        // can land while the previous flip is still in flight; the flip
        // completion event re-renders it. Not an error.
        log_mod.debug("drm: page flip already pending", self.backend.io, self.backend.log_cfg, "drm", .{});
        return error.CommitFailed;
    }

    const fb: *pixman.Framebuffer = @ptrCast(@alignCast(state.buffer.?));
    // A/B swapchain: draw into the OTHER buffer (the one not currently
    // displayed — the modeset bound buffers[0], so the first commit
    // copies into buffers[1]) and flip to ITS framebuffer id. Every flip
    // therefore changes FB_ID, which is what makes the kernel's plane
    // update run at all on virtio-gpu: virtio_gpu_plane_atomic_update
    // (virtgpu_plane.c) early-returns before the scanout switch and the
    // dumb upload/flush when drm_atomic_helper_damage_merged() finds no
    // damage, and our FB_DAMAGE_CLIPS damage alone empirically did not
    // trigger it (screen stuck at the boot console, zero "handle 0x"
    // update lines). `fb != old_state->fb` skips the damage gate and
    // runs the update unconditionally. Alternating the buffer also
    // closes the single-buffer tearing gap (notes/116 gap 2): the
    // compositor writes into a buffer no scanout is currently reading.
    const buf = &self.buffers[1 - self.flip_index];
    // Row-by-row copy: the dumb pitch may exceed width*4, so a single
    // whole-buffer memcpy would skew every row past the first.
    // (smithay dumb.rs scans out the same pitch-padded ARGB buffer.)
    copyRows(fb.data, @intCast(fb.stride), buf.map, buf.pitch, fb.width, fb.height);

    // Legacy interface (no atomic): drmModePageFlip on the CRTC
    // (wlroots legacy.c:206-209). Asynchronous, like the atomic
    // non-blocking flip — completion arrives as DRM_EVENT_FLIP_COMPLETE
    // through dispatch() and pageFlipHandler clears flip_pending. No
    // damage property exists on this path (damage is a plane property).
    if (!self.backend.atomic) {
        if (c.drmModePageFlip(self.backend.fd.?, self.crtc_id, buf.fb_id, c.DRM_MODE_PAGE_FLIP_EVENT, self) != 0) {
            log_mod.err("drm: drmModePageFlip failed", self.backend.io, self.backend.log_cfg, "drm", .{});
            return error.CommitFailed;
        }
        self.flip_pending = true;
        self.flip_index = 1 - self.flip_index;
        return;
    }

    // Page flip: FB_ID changes on the plane (the modeset bound the rest)
    // plus a full-fb FB_DAMAGE_CLIPS clip; PAGE_FLIP_EVENT + NONBLOCK
    // like wlroots atomic.c (non-modeset commits with a new buffer are
    // non-blocking flips). The damage clip is kept for wlroots parity
    // even though the FB_ID alternation alone now drives the update:
    // virtio-gpu's plane update is gated on merged damage clips
    // (virtgpu_plane.c virtio_gpu_plane_atomic_update), so the clip must
    // stay attached for drivers that still consult it, and wlroots
    // attaches damage on every commit the same way (atomic.c
    // create_fb_damage_clips_blob + atomic_plane_set).
    const fd = self.backend.fd.?;
    var damage_blob: u32 = 0;
    if (self.props.fb_damage_clips != 0) {
        if (!createDamageBlob(fd, @intCast(fb.width), @intCast(fb.height), &damage_blob)) {
            log_mod.err("drm: create FB_DAMAGE_CLIPS blob failed", self.backend.io, self.backend.log_cfg, "drm", .{});
            return error.CommitFailed;
        }
    }
    // The kernel copies the clips into the plane state at commit time;
    // the blob is destroyed right after (wlroots atomic.c
    // drm_atomic_connector_commit_state: destroy_blob(state->fb_damage_clips)).
    defer {
        if (damage_blob != 0) _ = c.drmModeDestroyPropertyBlob(fd, damage_blob);
    }

    const req = c.drmModeAtomicAlloc() orelse return error.CommitFailed;
    defer c.drmModeAtomicFree(req);
    if (c.drmModeAtomicAddProperty(req, self.plane_id, self.props.fb_id, buf.fb_id) < 0 or
        (self.props.fb_damage_clips != 0 and
            c.drmModeAtomicAddProperty(req, self.plane_id, self.props.fb_damage_clips, damage_blob) < 0))
    {
        log_mod.err("drm: atomic add FB_ID/damage failed", self.backend.io, self.backend.log_cfg, "drm", .{});
        return error.CommitFailed;
    }
    if (c.drmModeAtomicCommit(
        fd,
        req,
        c.DRM_MODE_PAGE_FLIP_EVENT | c.DRM_MODE_ATOMIC_NONBLOCK,
        self,
    ) != 0) {
        log_mod.err("drm: page flip commit failed", self.backend.io, self.backend.log_cfg, "drm", .{});
        return error.CommitFailed;
    }
    self.flip_pending = true;
    // The flip is queued; the buffer just flipped to is now the
    // displayed one, so the next commit copies into the other. Frame
    // pacing (one flip in flight, the completion event drives the next
    // frame) keeps this index accurate at commit time.
    self.flip_index = 1 - self.flip_index;
}

/// The backend owns all per-output resources; Output.destroy() frees only
/// the wrapper (headless pattern).
fn destroyOutput(_: std.mem.Allocator, _: *anyopaque) void {}

// ---------------------------------------------------------------------------
// DRM helpers
// ---------------------------------------------------------------------------

const FoundConnector = struct {
    connector_id: u32,
    crtc_id: u32,
    crtc_index: usize,
    mode: c.drmModeModeInfo,
};

/// Index of the first CRTC a possible_crtcs mask allows (bit i = CRTC
/// i) within [0, count) — the encoder-fallback CRTC pick: the union mask
/// comes from drmModeConnectorGetPossibleCrtcs, and the lowest set bit
/// is the first CRTC a sibling encoder can drive (wlroots realloc_crtcs
/// matches connectors against every CRTC in possible_crtcs; we take the
/// first such CRTC, kernels expose <= 32). Null when the mask allows no
/// CRTC in range.
fn firstCrtcIndex(possible_crtcs: u32, count: usize) ?usize {
    var i: usize = 0;
    while (i < count and i < 32) : (i += 1) {
        if (possible_crtcs & (@as(u32, 1) << @as(u5, @intCast(i))) != 0) return i;
    }
    return null;
}

/// Find the first connected connector with a mode; prefer the preferred
/// mode (mode.type & DRM_MODE_TYPE_PREFERRED), else the first mode
/// (wlroots drm.c drm_connector_get_current_mode). Resolves a free CRTC
/// from the union of possible_crtcs over ALL encoders the connector can
/// use (wlroots drm.c:1579 drmModeConnectorGetPossibleCrtcs; F24: the
/// connector's own encoder may report possible_crtcs == 0 while a
/// sibling encoder can drive it).
fn findConnectorMode(self: *DrmBackendData) ?FoundConnector {
    const fd = self.fd.?;
    const res = c.drmModeGetResources(fd) orelse {
        log_mod.err("drm: drmModeGetResources failed", self.io, self.log_cfg, "drm", .{});
        return null;
    };
    defer c.drmModeFreeResources(res);

    var i: c_int = 0;
    while (i < res.*.count_connectors) : (i += 1) {
        const connector_id = res.*.connectors[@intCast(i)];
        const conn = c.drmModeGetConnector(fd, connector_id) orelse continue;
        defer c.drmModeFreeConnector(conn);
        if (conn.*.connection != c.DRM_MODE_CONNECTED or conn.*.count_modes <= 0) continue;
        // A connector one of our outputs already drives is skipped here, so
        // the caller's one-output-per-connector loop terminates and a
        // hotplug "change" on an existing connector does not add a second
        // output for it.
        if (connectorBound(self, connector_id)) continue;

        var chosen: c_int = 0;
        var m: c_int = 0;
        while (m < conn.*.count_modes) : (m += 1) {
            if (conn.*.modes[@intCast(m)].type & c.DRM_MODE_TYPE_PREFERRED != 0) {
                chosen = m;
                break;
            }
        }

        // Possible CRTCs: the union over ALL encoders the connector can
        // use. drmModeConnectorGetPossibleCrtcs iterates the connector's
        // encoder list and ORs their possible_crtcs (libdrm
        // xf86drmMode.c) — the same match wlroots uses for connector
        // CRTC allocation (drm.c:1579, realloc_crtcs drm.c:1399-1453).
        // Using only the connector's currently-bound encoder would skip
        // the connector when that encoder can drive no CRTC even though
        // a sibling encoder could (the F24 gap); single-encoder
        // virtio-gpu is unaffected, but the union is the correct KMS
        // behavior.
        const possible_crtcs = c.drmModeConnectorGetPossibleCrtcs(fd, conn);
        if (possible_crtcs == 0) continue;

        // First free CRTC the encoder union can drive (kernels expose
        // <= 32 CRTCs; wlroots asserts the same bound).
        const crtc_index = firstCrtcIndex(possible_crtcs, @intCast(res.*.count_crtcs)) orelse continue;
        const crtc_id = res.*.crtcs[crtc_index];

        return .{
            .connector_id = connector_id,
            .crtc_id = crtc_id,
            .crtc_index = crtc_index,
            .mode = conn.*.modes[@intCast(chosen)],
        };
    }
    return null;
}

/// Find the primary plane for the CRTC and resolve the property ids used
/// in commits (wlroots drm.c init_plane: the plane must have the CRTC in
/// possible_crtcs, type == DRM_PLANE_TYPE_PRIMARY, and support the
/// scanout format XRGB8888; properties.c plane_info table names the
/// ids).
fn findPrimaryPlane(self: *DrmBackendData, crtc_index: usize, out_props: *PlanePropIds) ?u32 {
    const fd = self.fd.?;
    const res = c.drmModeGetPlaneResources(fd) orelse {
        log_mod.err("drm: drmModeGetPlaneResources failed", self.io, self.log_cfg, "drm", .{});
        return null;
    };
    defer c.drmModeFreePlaneResources(res);

    const crtc_bit = @as(u32, 1) << @as(u5, @intCast(crtc_index));
    var i: u32 = 0;
    while (i < res.*.count_planes) : (i += 1) {
        const plane_id = res.*.planes[i];
        const plane = c.drmModeGetPlane(fd, plane_id) orelse continue;
        defer c.drmModeFreePlane(plane);
        if (plane.*.possible_crtcs & crtc_bit == 0) continue;

        var props: PlanePropIds = .{};
        if (!scanPlaneProps(fd, plane_id, &props)) continue;
        const type_value = getPropValue(fd, plane_id, c.DRM_MODE_OBJECT_PLANE, props.plane_type) orelse continue;
        if (type_value != c.DRM_PLANE_TYPE_PRIMARY) continue;

        // The plane must scan out our XRGB8888 dumb buffer; skip planes
        // without the format (wlroots drm.c init_plane collects
        // drm_plane->formats into the plane's format set, drm.c:169-186,
        // and drm_fb_import refuses buffers whose format is absent from
        // it, fb.c:144-169).
        var has_xrgb8888 = false;
        var fi: u32 = 0;
        while (fi < plane.*.count_formats) : (fi += 1) {
            if (plane.*.formats[fi] == drm_format_xrgb8888) {
                has_xrgb8888 = true;
                break;
            }
        }
        if (!has_xrgb8888) {
            log_mod.debug("drm: plane {d} lacks XRGB8888; skipping", self.io, self.log_cfg, "drm", .{plane_id});
            continue;
        }

        out_props.* = props;
        if (props.fb_damage_clips == 0) {
            // Optional property (wlroots atomic.c guards every damage
            // add on `props.fb_damage_clips != 0`): commits skip damage
            // and rely on the driver doing a full plane update on its
            // own. virtio-gpu exposes the property, so this only fires
            // on other drivers.
            log_mod.debug(
                "drm: plane {d} lacks FB_DAMAGE_CLIPS; damage updates skipped",
                self.io,
                self.log_cfg,
                "drm",
                .{plane_id},
            );
        }
        return plane_id;
    }
    return null;
}

/// Resolve property ids by name for one DRM object (wlroots
/// properties.c scan_properties: drmModeObjectGetProperties +
/// drmModeGetProperty, linear name match over a small table). Fails when
/// any requested property is missing — atomic commits would EINVAL.
fn scanPropIds(fd: c_int, obj_id: u32, obj_type: u32, names: []const []const u8, out: []u32) bool {
    const props = c.drmModeObjectGetProperties(fd, obj_id, obj_type) orelse return false;
    defer c.drmModeFreeObjectProperties(props);
    @memset(out, 0);
    var i: u32 = 0;
    while (i < props.*.count_props) : (i += 1) {
        const prop = c.drmModeGetProperty(fd, props.*.props[i]) orelse continue;
        defer c.drmModeFreeProperty(prop);
        // drmModePropertyRes.name is a NUL-terminated char[32] buffer.
        const name_ptr: [*:0]const u8 = @ptrCast(&prop.*.name);
        const prop_name = std.mem.sliceTo(name_ptr, 0);
        for (names, 0..) |want, idx| {
            if (std.mem.eql(u8, prop_name, want)) out[idx] = prop.*.prop_id;
        }
    }
    for (out) |id| {
        if (id == 0) return false;
    }
    return true;
}

/// Plane property scan: the ten commit properties plus the "type"
/// property id (read to classify the plane) and the optional
/// "FB_DAMAGE_CLIPS" id (0 when the driver lacks it — some do). The
/// damage property must stay optional: scanPropIds is all-or-nothing, so
/// a plane without FB_DAMAGE_CLIPS must still pass (wlroots properties.c
/// plane_info includes fb_damage_clips but leaves missing optional ids at
/// 0).
fn scanPlaneProps(fd: c_int, plane_id: u32, out_props: *PlanePropIds) bool {
    var ids: [10]u32 = undefined;
    if (!scanPropIds(fd, plane_id, c.DRM_MODE_OBJECT_PLANE, &plane_prop_names, &ids)) return false;

    const props = c.drmModeObjectGetProperties(fd, plane_id, c.DRM_MODE_OBJECT_PLANE) orelse return false;
    defer c.drmModeFreeObjectProperties(props);
    var plane_type: u32 = 0;
    var fb_damage_clips: u32 = 0;
    var i: u32 = 0;
    while (i < props.*.count_props) : (i += 1) {
        const prop = c.drmModeGetProperty(fd, props.*.props[i]) orelse continue;
        defer c.drmModeFreeProperty(prop);
        // drmModePropertyRes.name is a NUL-terminated char[32] buffer.
        const name_ptr: [*:0]const u8 = @ptrCast(&prop.*.name);
        const prop_name = std.mem.sliceTo(name_ptr, 0);
        if (std.mem.eql(u8, prop_name, "type")) {
            plane_type = prop.*.prop_id;
        } else if (std.mem.eql(u8, prop_name, "FB_DAMAGE_CLIPS")) {
            fb_damage_clips = prop.*.prop_id;
        }
    }
    if (plane_type == 0) return false;

    out_props.* = .{
        .fb_id = ids[0],
        .crtc_id = ids[1],
        .src_x = ids[2],
        .src_y = ids[3],
        .src_w = ids[4],
        .src_h = ids[5],
        .crtc_x = ids[6],
        .crtc_y = ids[7],
        .crtc_w = ids[8],
        .crtc_h = ids[9],
        .plane_type = plane_type,
        .fb_damage_clips = fb_damage_clips,
    };
    return true;
}

/// Read the current value of a property (wlroots properties.c
/// get_drm_prop: drmModeObjectGetProperties + id match).
fn getPropValue(fd: c_int, obj_id: u32, obj_type: u32, prop_id: u32) ?u64 {
    const props = c.drmModeObjectGetProperties(fd, obj_id, obj_type) orelse return null;
    defer c.drmModeFreeObjectProperties(props);
    var i: u32 = 0;
    while (i < props.*.count_props) : (i += 1) {
        if (props.*.props[i] == prop_id) return props.*.prop_values[i];
    }
    return null;
}

/// DRM plane SRC_* properties are 16.16 fixed point
/// (wlroots atomic.c set_plane_props: src_box->width * (1 << 16)).
fn fixed16(v: u16) u64 {
    return @as(u64, v) << 16;
}

/// Create an FB_DAMAGE_CLIPS property blob covering the whole framebuffer
/// (the backend repaints the entire dumb buffer every frame, so a full
/// rect is the honest damage). The blob is an array of `drm_mode_rect`
/// in plain framebuffer pixels — NOT 16.16 like SRC_*: kernel drm_plane.c
/// "DOC: damage tracking" ("blob property with the layout of blob data is
/// simply an array of &drm_mode_rect. Unlike plane &drm_plane_state.src
/// coordinates, damage clips are not in 16.16 fixed point") and the uapi
/// parse in drm_atomic_uapi.c checks `sizeof(struct drm_mode_rect)` per
/// element. wlroots sends the same layout (atomic.c
/// create_fb_damage_clips_blob passes pixman_box32_t rects, int32 x1/y1/
/// x2/y2) and smithay builds drm_mode_rect values (drm/surface/mod.rs
/// PlaneDamageClips::from_damage). The legacy uapi `struct drm_clip_rect`
/// (unsigned short fields) is a drawable-era type and is NOT the damage
/// blob element. `out` receives the blob id; the caller must destroy it
/// with drmModeDestroyPropertyBlob after the atomic commit (the kernel
/// copies the clips into the plane state at commit time — wlroots atomic.c
/// destroys state->fb_damage_clips in drm_atomic_connector_commit_state).
/// Returns false when blob creation fails.
fn createDamageBlob(fd: c_int, width: u32, height: u32, out: *u32) bool {
    // FB_DAMAGE_CLIPS blobs carry WHOLE-PIXEL rects, not 16.16: the
    // kernel's damage iterator returns clips raw ("damage clips are whole
    // number", drm_damage_helper.c) and virtio-gpu feeds them unshifted
    // into the transfer/flush commands (virtgpu_plane.c). 16.16 values
    // here made the upload 0x05000000px wide — a silent no-op on qemu.
    // struct_drm_mode_rect (4x s32) matches the kernel's drm_clip_rect
    // (u32) blob layout; wlroots uses the same pixel rects (atomic.c
    // create_fb_damage_clips_blob).
    const rect: c.struct_drm_mode_rect = .{
        .x1 = 0,
        .y1 = 0,
        // x2/y2 are exclusive, so the full rect spans the whole fb.
        .x2 = @intCast(width),
        .y2 = @intCast(height),
    };
    return c.drmModeCreatePropertyBlob(fd, &rect, @sizeOf(c.struct_drm_mode_rect), out) == 0;
}

/// Convert a drmModeModeInfo to the output Mode; refresh from vrefresh
/// (Hz), falling back to clock/(htotal*vtotal) when unset
/// (wlroots calculate_refresh_rate).
fn modeToOutput(mode: c.drmModeModeInfo) output_mod.Mode {
    var hz: u32 = mode.vrefresh;
    if (hz == 0 and mode.htotal != 0 and mode.vtotal != 0) {
        // clock is in kHz: refresh = pixel clock / (htotal * vtotal)
        // (wlroots calculate_refresh_rate). u64 math avoids overflow on
        // exotic modes.
        const clock: u64 = mode.clock;
        const total: u64 = @as(u64, mode.htotal) * @as(u64, mode.vtotal);
        hz = @intCast((clock * 1000) / total);
    }
    const refresh_msec: i32 = if (hz == 0) 16 else @intCast(@max(@as(u32, 1), 1000 / hz));
    return .{
        .width = @intCast(mode.hdisplay),
        .height = @intCast(mode.vdisplay),
        .refresh_msec = refresh_msec,
    };
}

/// Last path component for logs ("/dev/dri/card0" -> "card0").
fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Copy framebuffer rows into the dumb buffer; the dumb pitch may exceed
/// width*4, so rows must be copied individually (a whole-buffer memcpy
/// would skew every row past the first).
fn copyRows(src: []const u8, src_stride: usize, dst: []u8, dst_stride: u32, width: i32, height: i32) void {
    const row_bytes: usize = @as(usize, @intCast(width)) * 4;
    const dst_stride_us: usize = dst_stride;
    var y: usize = 0;
    while (y < @as(usize, @intCast(height))) : (y += 1) {
        @memcpy(dst[y * dst_stride_us ..][0..row_bytes], src[y * src_stride ..][0..row_bytes]);
    }
}

/// The GBM device this backend imported client dmabufs into. It goes
/// before the KMS fd: it was opened after it, and its gbm_bo objects
/// belong to the buffers the compositor imported through it. Those buffers
/// die with the zwp_linux_dmabuf_v1 module, so the server must deinit that
/// module before it destroys this backend or a bo destruction would touch
/// a freed device (wlroots orders it the same way,
/// render/allocator/gbm.c:197-212).
fn teardownGbm(self: *DrmBackendData) void {
    const dev = self.gbm orelse return;
    self.gbm = null;
    dev.deinit();
}

/// Release every DRM device resource, in reverse acquisition order.
///
/// Null-safe and idempotent, so a start() that died half-way (or a
/// teardown that runs twice) releases exactly what exists:
///
///   1. the udev monitor, so nothing produces a callback into state that is
///      about to be freed;
///   2. the logind session, which restores the console VT, hands the device
///      back to logind and ends the session - while we still hold DRM
///      master and the fd, so the handover happens on a card we still own;
///   3. per output: the mode blob, then each swapchain buffer (RmFB, then
///      the mapping, then the allocation);
///   4. the GBM device - after every bo, because a bo destruction touches
///      the device;
///   5. DRM master, then the fd.
///
/// The order of 2 and 5 is the answer to "can this leave the console on the
/// wrong VT or hold DRM master after shutdown": it cannot. The VT is put
/// back before the fd closes and before the master is dropped, so the
/// console is never switched while we are half-dead; and the master is
/// dropped unconditionally, whether or not the session existed.
fn drmTeardown(self: *DrmBackendData) void {
    if (self.hotplug) |hp| {
        self.hotplug = null;
        hp.close();
    }
    if (self.session) |s| {
        self.session = null;
        s.close();
    }
    const fd = self.fd orelse return;
    for (self.outputs.items) |drm_out| releaseOutputResources(self, drm_out);
    teardownGbm(self);
    if (self.is_master) {
        _ = c.drmIoctl(fd, c.DRM_IOCTL_DROP_MASTER, null);
        self.is_master = false;
    }
    _ = std.os.linux.close(fd);
    self.fd = null;
}

/// One output's KMS resources: the mode blob and both swapchain buffers, in
/// reverse acquisition order. Idempotent - every id is zeroed as it is
/// released - and safe on an output that never finished starting.
fn releaseOutputResources(self: *DrmBackendData, drm_out: *DrmOutput) void {
    const fd = self.fd orelse return;
    if (drm_out.mode_blob != 0) {
        _ = c.drmModeDestroyPropertyBlob(fd, drm_out.mode_blob);
        drm_out.mode_blob = 0;
    }
    releaseBuffers(self, drm_out);
}

/// Both swapchain buffers of one output.
fn releaseBuffers(self: *DrmBackendData, drm_out: *DrmOutput) void {
    for (&drm_out.buffers) |*buf| releaseBuffer(self, buf);
}

/// One swapchain buffer, whatever flavour it is: RmFB the framebuffer, then
/// drop the CPU mapping, then the allocation.
///
/// Order matters twice over. The framebuffer goes first because it is what
/// the kernel holds a reference through (drivers/gpu/drm/drm_framebuffer.c
/// drm_mode_rmfb takes the last fb reference). The mapping goes before the
/// allocation because the mapping IS a reference to it - unmapping after
/// gbm_bo_destroy would touch freed memory, and skipping it for a dumb
/// buffer leaves a live mapping onto a destroyed handle.
fn releaseBuffer(self: *DrmBackendData, buf: *ScanoutBuffer) void {
    const fd = self.fd orelse return;
    if (buf.fb_id != 0) {
        _ = c.drmModeRmFB(fd, buf.fb_id);
        buf.fb_id = 0;
    }
    if (buf.bo_map) |m| {
        buf.bo_map = null;
        buf.map = &.{};
        if (buf.bo) |bo| gbm_c.gbm_bo_unmap(bo, m);
    }
    if (buf.map.len != 0) {
        std.posix.munmap(@alignCast(buf.map));
        buf.map = &.{};
    }
    if (buf.bo) |bo| {
        buf.bo = null;
        gbm_c.gbm_bo_destroy(bo);
    }
    buf.gem_handle = 0;
    buf.modifier = 0;
    if (buf.handle != 0) {
        var destroy_dumb: c.struct_drm_mode_destroy_dumb = .{ .handle = buf.handle };
        _ = c.drmIoctl(fd, c.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy_dumb);
        buf.handle = 0;
    }
}

/// Destroy every output whose connector is no longer connected - the
/// unplug path.
///
/// Matching is by asking KMS, not by comparing udev names: for each live
/// output the connector is re-read and destroyed when it is gone,
/// DISCONNECTED, or has no modes left. That is exactly the state a yanked
/// cable produces (drivers/gpu/drm/drm_connector.c connector_detect writes
/// the new status; a connector object that disappeared makes
/// drmModeGetConnector fail), and it needs no name bookkeeping that could
/// drift from the kernel's.
///
/// The Output wrapper is destroyed first - that emits the signal the
/// compositor uses to retire the wl_output - then the KMS resources, then
/// the struct. The list entry is removed last, because orderedRemove shifts
/// the tail down and the index has to stay valid for the loop.
fn removeDisconnectedOutputs(self: *DrmBackendData) void {
    const fd = self.fd orelse return;
    var i: usize = 0;
    while (i < self.outputs.items.len) {
        const drm_out = self.outputs.items[i];
        if (connectorStillUsable(fd, drm_out.connector_id)) {
            i += 1;
            continue;
        }
        log_mod.info(
            "drm: connector {d} is disconnected; destroying its output",
            self.io,
            self.log_cfg,
            "drm",
            .{drm_out.connector_id},
        );
        if (drm_out.out) |out| out.destroy();
        releaseOutputResources(self, drm_out);
        self.allocator.destroy(drm_out);
        _ = self.outputs.orderedRemove(i);
    }
}

/// Is this connector still something we can drive? Present, connected, and
/// advertising at least one mode - the same three conditions
/// findConnectorMode applies, so what survives here is exactly what an
/// addOutput would accept.
fn connectorStillUsable(fd: std.posix.fd_t, connector_id: u32) bool {
    const conn = c.drmModeGetConnector(fd, connector_id) orelse return false;
    defer c.drmModeFreeConnector(conn);
    return conn.*.connection == c.DRM_MODE_CONNECTED and conn.*.count_modes > 0;
}

/// wp_presentation_feedback.presented flags for a DRM page flip
/// (wayland.xml: VSYNC=1, HW_CLOCK=2, HW_COMPLETION=4): the kernel's
/// flip-completion event is a hardware clock + hardware completion, and
/// the flip is vsync'd — the same set wlroots reports
/// (drm.c handle_page_flip, presentation_time.c:287-301).
const drm_present_flags: u32 = 0x1 | 0x2 | 0x4;

/// The connector mode's presented refresh interval (ns): 1e9 / vrefresh,
/// computed the same way modeToOutput derives refresh_msec (with the
/// pixel-clock fallback when vrefresh is 0). The presented event carries
/// this so presentation feedback reports the real display refresh.
fn modeRefreshNs(mode: c.drmModeModeInfo) u64 {
    var hz: u64 = mode.vrefresh;
    if (hz == 0 and mode.htotal != 0 and mode.vtotal != 0) {
        // clock is in kHz: refresh = pixel clock / (htotal * vtotal)
        // (wlroots calculate_refresh_rate). u64 math avoids overflow on
        // exotic modes.
        const clock: u64 = mode.clock;
        const total: u64 = @as(u64, mode.htotal) * @as(u64, mode.vtotal);
        hz = (clock * 1000) / total;
    }
    if (hz == 0) return 16 * std.time.ns_per_ms;
    return @intCast(std.time.ns_per_s / hz);
}

/// DRM_EVENT_FLIP_COMPLETE handler (wlroots drm.c handle_page_flip): the
/// flip for our crtc has completed — the buffer is now visible. Fire the
/// output's presented event FIRST (this completion IS the real present,
/// with the kernel's vblank time and the mode's refresh), then wake the
/// output for the next frame — the wlroots handle_page_flip order
/// (wlr_output_send_present before wlr_output_send_frame). The seq is
/// the output's commit sequence: flips are serialized (a commit while
/// one is in flight fails), so at completion it is the flipped frame's
/// seq.
fn pageFlipHandler(
    fd: c_int,
    sequence: c_uint,
    tv_sec: c_uint,
    tv_usec: c_uint,
    crtc_id: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = fd;
    _ = sequence;
    const drm_out: *DrmOutput = @ptrCast(@alignCast(user_data.?));
    if (crtc_id != drm_out.crtc_id) return;
    drm_out.flip_pending = false;
    if (drm_out.out) |out| {
        // The kernel's tv is the vblank time (CLOCK_MONOTONIC-family:
        // seconds + microseconds since boot).
        const when_ns: u64 = @as(u64, tv_sec) * std.time.ns_per_s +
            @as(u64, tv_usec) * std.time.ns_per_us;
        out.firePresented(out.commit_seq, drm_present_flags, drm_out.refresh_ns, when_ns);
        out.sendFrame();
    }
}

// ---------------------------------------------------------------------------
// Tests (pure logic only; device paths are VM-verified)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fourcc constant matches drm_fourcc.h" {
    // XRGB8888 fourcc 'X' 'R' '2' '4' = 0x34325258 is the scanned-out
    // format; the pixman framebuffer bytes (B,G,R,A in memory) match its
    // layout with a live alpha byte. ARGB8888 ('A' 'R' '2' '4' =
    // 0x34325241) is the same layout with alpha at the fourth byte.
    try testing.expectEqual(drm_format_xrgb8888, c.DRM_FORMAT_XRGB8888);
    try testing.expectEqual(@as(u32, 0x34325241), c.DRM_FORMAT_ARGB8888);
}

test "16.16 fixed point conversion" {
    try testing.expectEqual(@as(u64, 0), fixed16(0));
    try testing.expectEqual(@as(u64, 1) << 16, fixed16(1));
    try testing.expectEqual(@as(u64, 1080) << 16, fixed16(1080));
}

test "mode to output conversion" {
    var mode: c.drmModeModeInfo = .{
        .clock = 148500,
        .hdisplay = 1920,
        .vdisplay = 1080,
        .htotal = 2200,
        .vtotal = 1125,
        .vrefresh = 60,
    };
    const out_mode = modeToOutput(mode);
    try testing.expectEqual(@as(i32, 1920), out_mode.width);
    try testing.expectEqual(@as(i32, 1080), out_mode.height);
    try testing.expectEqual(@as(i32, 16), out_mode.refresh_msec); // 1000/60

    // vrefresh unset: computed from clock/(htotal*vtotal) = 60 Hz.
    mode.vrefresh = 0;
    const computed = modeToOutput(mode);
    try testing.expectEqual(@as(i32, 16), computed.refresh_msec);

    // Degenerate mode: fall back to 16ms (assumed 60 Hz).
    mode.clock = 0;
    mode.htotal = 0;
    mode.vtotal = 0;
    try testing.expectEqual(@as(i32, 16), modeToOutput(mode).refresh_msec);
}

test "scanout path: a plane framebuffer only when every precondition holds" {
    // Everything present: the real-plane GBM path.
    const plane = ScanoutChoice.decide(true, true, 42);
    try testing.expect(plane.use_plane);
    try testing.expectEqual(ScanoutChoice.Reason.plane, plane.reason);

    // No GBM device at all - the VM case, and the reason the dumb path
    // still exists. It must stay REACHABLE, not merely present in the
    // source: this is the configuration the backend runs in today.
    const no_gbm = ScanoutChoice.decide(false, false, 42);
    try testing.expect(!no_gbm.use_plane);
    try testing.expectEqual(ScanoutChoice.Reason.no_gbm, no_gbm.reason);

    // The legacy KMS interface has no planes (plane_id 0): flips go through
    // the CRTC, so there is nothing to allocate a plane framebuffer for.
    const no_plane = ScanoutChoice.decide(true, true, 0);
    try testing.expect(!no_plane.use_plane);
    try testing.expectEqual(ScanoutChoice.Reason.no_plane, no_plane.reason);

    // A GBM device with no (format, modifier) pair behind a plane cannot
    // allocate anything; the advertised pair set is what says so.
    const no_formats = ScanoutChoice.decide(true, false, 42);
    try testing.expect(!no_formats.use_plane);
    try testing.expectEqual(ScanoutChoice.Reason.gbm_has_no_format, no_formats.reason);
}

test "card node path yields the DRM minor logind wants" {
    // TakeDevice names the device by its primary minor, and libdrm builds
    // node names as "card<minor>" (xf86drmMode.h DRM_DEV_NAME).
    try testing.expectEqual(@as(u32, 0), cardMinor("/dev/dri/card0"));
    try testing.expectEqual(@as(u32, 12), cardMinor("/dev/dri/card12"));
    try testing.expectEqual(@as(u32, 1), cardMinor("card1"));
    // A render node is not a KMS device; claiming a device for it would be
    // claiming the wrong one, so the minor falls back to 0 rather than
    // inventing a number.
    try testing.expectEqual(@as(u32, 0), cardMinor("/dev/dri/renderD128"));
    try testing.expectEqual(@as(u32, 0), cardMinor(""));
}

test "encoder fallback picks the first CRTC in the possible_crtcs union" {
    // F24: a connector's CRTC set is the union over ALL its encoders
    // (drmModeConnectorGetPossibleCrtcs); the lowest set bit wins.
    // Single-encoder mask: bit 0 -> CRTC 0.
    try testing.expectEqual(@as(?usize, 0), firstCrtcIndex(0b1, 4));
    // Union of two encoders' masks (bits 0 and 2): first is CRTC 0.
    try testing.expectEqual(@as(?usize, 0), firstCrtcIndex(0b101, 4));
    // Only the sibling encoder drives CRTC 2 (the connector's own
    // encoder reported 0): fallback must still find it.
    try testing.expectEqual(@as(?usize, 2), firstCrtcIndex(0b100, 4));
    // Bit 3 is within a 4-CRTC device: index 3 is valid.
    try testing.expectEqual(@as(?usize, 3), firstCrtcIndex(0b1000, 4));
    // Mask allows CRTCs past the resources' count: out of range -> null.
    try testing.expectEqual(@as(?usize, null), firstCrtcIndex(0b10000, 4));
    // No CRTC reachable at all.
    try testing.expectEqual(@as(?usize, null), firstCrtcIndex(0, 4));
    // Zero resources -> null even with a full mask.
    try testing.expectEqual(@as(?usize, null), firstCrtcIndex(0xFFFFFFFF, 0));
}

test "plane property name table" {
    // The order must match the PlanePropIds field order used in commits
    // (wlroots properties.c plane_info table).
    try testing.expectEqual(@as(?usize, 0), planePropIndex("FB_ID"));
    try testing.expectEqual(@as(?usize, 1), planePropIndex("CRTC_ID"));
    try testing.expectEqual(@as(?usize, 4), planePropIndex("SRC_W"));
    try testing.expectEqual(@as(?usize, 5), planePropIndex("SRC_H"));
    try testing.expectEqual(@as(?usize, 9), planePropIndex("CRTC_H"));
    // "type" is read as a value, not a commit property.
    try testing.expectEqual(@as(?usize, null), planePropIndex("type"));
    try testing.expectEqual(@as(?usize, null), planePropIndex("MODE_ID"));
}

test "row copy handles dumb stride padding" {
    // 2x2 ARGB source, stride 8 (no padding); dst stride 16 (padded).
    const src = [_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,
        9, 10, 11, 12, 13, 14, 15, 16,
    };
    var dst = [_]u8{0} ** 32;
    copyRows(&src, 8, &dst, 16, 2, 2);

    try testing.expectEqualSlices(u8, src[0..8], dst[0..8]);
    // The padding byte between rows stays zero.
    try testing.expectEqual(@as(u8, 0), dst[8]);
    try testing.expectEqualSlices(u8, src[8..16], dst[16..24]);
    // Trailing padding stays zero.
    try testing.expectEqual(@as(u8, 0), dst[24]);
    try testing.expectEqual(@as(u8, 0), dst[31]);
}

/// Map a DRM plane property name to its commit-property slot
/// (wlroots properties.c plane_info table: name -> index).
fn planePropIndex(name: []const u8) ?usize {
    for (plane_prop_names, 0..) |want, idx| {
        if (std.mem.eql(u8, name, want)) return idx;
    }
    return null;
}
