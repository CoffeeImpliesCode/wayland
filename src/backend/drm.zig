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
//! # GPU data path (explicit selection, no CPU fallback)
//!
//! The default path above is the CPU one: pixman renders, `copyRows` puts
//! the rows into a dumb or CPU-mapped GBM buffer, KMS scans that out.
//! Selection is explicit and never automatic:
//!
//!   1. `DrmBackend.prepareGpu(base)` opens the card node and a GBM
//!      device on this device's own render node (or the primary one),
//!      BEFORE `start` and without touching the seat, DRM master or any
//!      KMS object. Idempotent.
//!   2. the renderer is built on that GBM device and the server hands its
//!      actual renderable (format, modifier) pairs to
//!      `DrmBackend.setGpuFormats(base, pairs)`, which borrows them for
//!      the backend's lifetime. After that point this backend is a GPU
//!      backend and there is no CPU fallback: a driver whose primary
//!      plane cannot be negotiated, whose GBM device refuses the pair, or
//!      whose allocation fails is reported as a capability failure.
//!   3. per output, BEFORE the first modeset, `createGpuSlots` allocates
//!      two GEM buffer objects with exported plane descriptors (no CPU
//!      mapping is ever created on this path) and adds them as KMS
//!      framebuffers. The renderer leases one at a time through
//!      `DrmBackend.acquireGpuFrame`, draws into it, and `Output.State`
//!      `.gpu` hands it back at commit; the flip names that slot's
//!      framebuffer id and nothing else. No row copy, no gbm_bo_map, no
//!      readPixels on this path - `copyRows` exists only for the CPU one.
//!
//! The negotiated (format, modifier) is real: the plane's IN_FORMATS blob
//! says which layouts it scans out, GBM says which of those it can
//! allocate, the renderer says which it can render into, and the
//! allocation is verified to come back with the modifier that was
//! requested rather than a guessed LINEAR one.
//!
//! # Flip identity: every queued flip is named by an integer
//!
//! A flip completion tells us WHICH CRTC finished, never WHICH flip of
//! that CRTC's history finished. The only thing the kernel hands back is
//! the `user_data` value the flip was queued with, so that value is the
//! identity - and it is an INTEGER (`PendingFlip.cookie`), never a
//! pointer. Nothing in this module dereferences what the kernel holds.
//!
//! Which backend a completion belongs to is a scope, not a pointer in the
//! cookie: every drmHandleEvent runs with `draining` set to the backend
//! reading the fd, and libdrm calls the handler synchronously from inside
//! that call, so the scope is exactly as wide as the drain.
//!
//! Three rules make a completion safe, and none of them needs an
//! assumption about what the kernel does with a flip it never completes:
//!
//!  1. **A completion acts on the output that is waiting for exactly that
//!     cookie** (`outputPendingCookie`). An unplugged or torn-down output
//!     is not waiting for anything, so its late event resolves to nothing
//!     - no use-after-free, and no tombstone, because the kernel never
//!     held a pointer into the output at all.
//!  2. **An invalidation is a new epoch.** Suspend and output teardown
//!     move `epoch` and clear the pending record, so a cookie from before
//!     matches no pending flip again, for ever: no ring promotion, no
//!     presented, no frame, and no later arm can make it current again
//!     because a cookie is never reissued.
//!  3. **A refused request disarms.** The kernel refused the flip, so no
//!     completion will name that cookie and the output goes back to
//!     waiting for nothing.
//!
//! Resume therefore does not "clear the pending flip and hope". It bumps
//! the epoch, drains what the kernel has already queued (a zero-timeout
//! poll loop, never a blocking read), re-commits the real modeset for that
//! CRTC through the same builders start() uses - atomic commit with
//! DRM_MODE_ATOMIC_ALLOW_MODESET, or drmModeSetCrtc on the legacy
//! interface - over the buffers, plane and mode blob it already owns,
//! drains again, adopts the framebuffer that modeset bound as the front of
//! the ring, and asks for a full repaint. DRM_IOCTL_DROP_MASTER does NOT
//! drain the file's event queue, and neither the drain nor the modeset is
//! relied on to make an old completion harmless: the cookie rule is.
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
//! output/gpu_frame.zig, buffers/dmabuf.zig, renderer/pixman.zig,
//! core/wire.zig (the flip-completion tests count its signals), and
//! the translated "drm_c" and "gbm_c" namespaces.

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const backend_mod = @import("backend.zig");
const output_mod = @import("../output/output.zig");
const pixman = @import("../renderer/pixman.zig");
const c = @import("drm_c");
const dmabuf = @import("../buffers/dmabuf.zig");
const gpu_frame = @import("../output/gpu_frame.zig");
const gbm_c = @import("gbm_c");
const session_mod = @import("session.zig");
const wire = @import("../core/wire.zig");

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
    /// A GBM buffer object with a modifier, on a real primary plane,
    /// mapped for the CPU: the CPU renderer path's plane scanout.
    plane,
    /// Two GPU-only GEM buffer objects with exported plane descriptors
    /// (`gpu_frame.GpuFrame` leases). The renderer draws into them and
    /// KMS scans them out; nothing on this path is ever mapped, copied
    /// or read back by the compositor.
    gpu,
};

/// Where one GPU scanout slot stands in the present ring. The renderer
/// writes into a leased slot and the kernel reads the front one; nothing
/// is ever written while it is on screen or waiting to go there.
///
/// ```text
///   free --acquire--> writing --commit--> pending --flip done--> front
///     ^                 |                                          |
///     +--- cancel ------+                                          |
///                                                                   |
///   (the next completion frees the slot that was front)  ---------+
/// ```
/// A completed PENDING slot becomes FRONT, and only then does the slot
/// it replaced become free - one writer and one queued flip at a time,
/// with the pixels on screen never belonging to the writer.
const SlotState = enum {
    /// Nobody holds it; the renderer may lease it.
    free,
    /// Leased to a caller through acquireGpuFrame. The caller owns the
    /// pixels until it commits or cancels; a FAILED commit leaves it
    /// here.
    writing,
    /// Committed and queued for flip: the framebuffer id is in a KMS
    /// request, waiting for the completion event.
    pending,
    /// Scanned out right now.
    front,
};

/// Ring transitions for the two slots of one output, as pure functions
/// so the ordering rules can be exercised without a card.
const GpuRing = struct {
    /// `completed` finished its flip: it is the front buffer now, and the
    /// one it replaced stops being scanned out and becomes free. A slot
    /// that is not pending (a cancelled or abandoned one) changes
    /// nothing else.
    fn flipCompleted(states: *[2]SlotState, completed: u2) void {
        if (states[completed] != .pending) return;
        states[completed] = .front;
        var i: usize = 0;
        while (i < states.len) : (i += 1) {
            if (i != completed and states[i] == .front) states[i] = .free;
        }
    }

    /// The first slot nobody holds, or null when both are taken.
    fn firstFree(states: *const [2]SlotState) ?u2 {
        for (states, 0..) |state, i| {
            if (state == .free) return @intCast(i);
        }
        return null;
    }
};

/// The identity of the one flip an output is waiting for. `cookie` is
/// what travels: it is handed to the kernel as the `user_data` value of
/// drmModePageFlip / drmModeAtomicCommit and comes back unchanged in
/// page_flip_handler2, and it is an INTEGER, never a pointer - nothing in
/// this module ever dereferences what the kernel holds.
const PendingFlip = struct {
    /// Monotonic per backend, never reused while any flip can still be
    /// outstanding, and never 0 (0 means "no flip in flight").
    cookie: usize,
    /// The output's epoch and flip counter when this flip was queued. A
    /// completion only counts when the output is still at both, which is
    /// what makes an invalidation final.
    epoch: u64,
    seq: u64,
    /// The CRTC the flip was queued on. The completion carries one too.
    crtc_id: u32,
};

/// The backend that is currently reading events, for the duration of one
/// drain and nothing else. libdrm calls the handler synchronously from
/// inside drmHandleEvent, so the scope is exactly as wide as that call;
/// a completion can therefore never be attributed to the wrong backend,
/// and none is reachable outside a drain at all.
threadlocal var draining: ?*DrmBackendData = null;

/// Run one drmHandleEvent with `self` as the scope the completion handler
/// resolves against. Nested drains (the resume barrier inside a session
/// dispatch) restore the outer scope on the way out.
fn handleEvents(self: *DrmBackendData, fd: std.posix.fd_t) c_int {
    const outer = draining;
    draining = self;
    defer draining = outer;
    var evctx = eventContext();
    return c.drmHandleEvent(fd, &evctx);
}

/// Name the flip this output is about to queue, and return the cookie to
/// hand the kernel. The cookie is minted per backend, so it identifies a
/// flip across every output and every epoch, and it is burned even if the
/// request is later refused: an identity is never reissued.
fn armFlip(drm_out: *DrmOutput) ?usize {
    const self = drm_out.backend;
    if (self.next_cookie == std.math.maxInt(usize) or drm_out.flip_seq == std.math.maxInt(u64))
        return null;
    self.next_cookie += 1;
    drm_out.pending = .{
        .cookie = self.next_cookie,
        .epoch = drm_out.epoch,
        .seq = drm_out.flip_seq + 1,
        .crtc_id = drm_out.crtc_id,
    };
    drm_out.flip_seq += 1;
    return self.next_cookie;
}

/// The kernel refused the request: no completion will name this cookie,
/// so the output is not waiting for a flip any more.
fn disarmFlip(drm_out: *DrmOutput) void {
    drm_out.pending = null;
}

/// The kernel `user_data` a flip was queued with. Integer only: it is
/// carried through a `?*anyopaque` because that is libdrm's parameter
/// type, and it is never dereferenced - not here, not in the handler.
fn cookiePointer(cookie: usize) *anyopaque {
    return @ptrFromInt(cookie);
}

/// The cookie back out of a completion's user_data.
fn cookieOf(user_data: ?*anyopaque) usize {
    const ptr = user_data orelse return 0;
    return @intFromPtr(ptr);
}

/// The live output that is waiting for exactly this flip, or null. Null is
/// the answer for every completion this backend no longer wants:
///
///  - the output is gone (unplugged, or the backend is tearing down), so
///    there is nothing to present on and nothing to promote;
///  - the output moved to another epoch (a resume or a teardown
///    invalidated the flip), or has since queued another one;
///  - the cookie names no pending flip of THIS backend - either a value it
///    never issued, or one another backend issued; a drain only ever
///    resolves against its own scope, so the two cannot be confused.
///
/// An old cookie is not merely ignored once: it matches nothing after any
/// later arm and stays that way for ever, which is why nothing has to be
/// tracked, reclaimed or kept alive until the kernel is done with it.
fn outputPendingCookie(self: *DrmBackendData, cookie: usize) ?*DrmOutput {
    if (cookie == 0) return null;
    for (self.outputs.items) |drm_out| {
        const pending = drm_out.pending orelse continue;
        if (pending.cookie != cookie) continue;
        // The record is only the current flip if the output never moved
        // on since it was armed.
        if (drm_out.epoch != pending.epoch or drm_out.flip_seq != pending.seq) return null;
        return drm_out;
    }
    return null;
}

/// One GPU scanout buffer object: what KMS scans out, and the stable
/// `GpuFrame` the renderer borrows while it draws into it.
///
/// There is deliberately no CPU mapping on this path. The only way to the
/// pixels is a GL target imported from `frame.attributes`.
const GpuSlot = struct {
    /// The buffer object; null only in the pure lease tests, which never
    /// touch a device.
    bo: ?*gbm_c.struct_gbm_bo = null,
    /// KMS framebuffer id for `bo`, named by the flip.
    fb_id: u32 = 0,
    format: u32 = 0,
    modifier: u64 = 0,
    state: SlotState = .free,
    /// Bumped for every allocation this backend ever makes. It is handed
    /// out in the frame and checked at commit, so a frame from a
    /// destroyed output (or a reconnected connector that got a fresh
    /// one) can never be committed against a recycled slot.
    generation: u64 = 0,
    /// Stable address: the renderer holds this across the lease.
    frame: gpu_frame.GpuFrame = .{
        .attributes = .{},
        .fb_id = 0,
        .owner = undefined,
        .slot = 0,
        .generation = 0,
    },
};

/// Is `frame` a live writing lease of THIS output's slot? The commit
/// path trusts nothing else: the owner pointer, the slot index, the
/// generation and the slot's own state all have to agree, so a frame
/// from another output, a stale frame from a released slot, or a slot
/// that is already on screen cannot be flipped to.
fn gpuFrameValid(drm_out: *const DrmOutput, frame: *const gpu_frame.GpuFrame) bool {
    const slots = drm_out.gpu_slots orelse return false;
    const index = frame.slot;
    if (index >= slots.len) return false;
    if (frame.owner != @as(*const anyopaque, @ptrCast(drm_out))) return false;
    const slot = &slots[index];
    if (frame != &slot.frame) return false;
    if (frame.generation != slot.generation) return false;
    return slot.state == .writing;
}

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
    /// The connector mode's actual refresh interval (ns), carried by the
    /// presented event (the vblank interval of the mode being scanned
    /// out — wlroots drm.c handle_page_flip's refresh).
    refresh_ns: u64 = 0,
    /// The primary plane chosen for GPU mode. Set even on the legacy KMS
    /// interface, which commits through the CRTC: the plane's IN_FORMATS
    /// blob is where the scannable (format, modifier) pairs come from,
    /// and its id is what keeps two outputs off one plane.
    gpu_plane_id: u32 = 0,
    /// The GPU present ring: two GEM buffer objects with exported plane
    /// descriptors, allocated before the first modeset. Null on the CPU
    /// paths, which use `buffers` instead.
    gpu_slots: ?*[2]GpuSlot = null,
    /// The one flip this output is waiting for, or null. Non-null is the
    /// frame-pacing guard (a second flip before the completion would
    /// EBUSY) AND the only thing a completion can ever match.
    pending: ?PendingFlip = null,
    /// Bumped whenever this output's flip pipeline is invalidated (resume,
    /// teardown). A completion carrying an older epoch belongs to a flip
    /// this output no longer waits for: it is dropped without promoting a
    /// ring slot and without firing presented or frame. Never reused, so
    /// repeated invalidation cannot resurrect an earlier identity.
    epoch: u64 = 1,
    /// Flips this output has named, monotonic and never reused - a refused
    /// request burns one, which is the safe direction: no later event can
    /// ever match a record a different flip once carried.
    flip_seq: u64 = 0,
    /// The connector mode as KMS reported it, kept so a resume can re-run
    /// the same modeset (the legacy drmModeSetCrtc path needs the full
    /// drmModeModeInfo) without re-enumerating the device. The mode blob
    /// this produced is still alive too, so no blob is recreated.
    crtc_mode: c.drmModeModeInfo = .{},
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
    /// Renderer-owned renderable (format, modifier) pairs, borrowed for
    /// this backend's lifetime by setGpuFormats. Non-null means GPU mode
    /// was selected explicitly, and it is the ONLY switch: the CPU dumb
    /// path stays the default and is never entered as a fallback.
    gpu_render_pairs: ?[]const dmabuf.Format = null,
    /// Set once start() ran. setGpuFormats must refuse afterwards: the
    /// first modeset has already been negotiated by then.
    started: bool = false,
    /// Monotonic slot generations across every output this backend ever
    /// created, so no two frames in the process share one.
    next_generation: u64 = 1,
    /// Last issued native-width cookie. Exhaustion refuses a new flip:
    /// even a completion delayed across a resume must never alias one.
    next_cookie: usize = 0,
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

    /// GPU mode, step 1: open the card node and a GBM device on this
    /// device's own render node (falling back to the primary one) and
    /// enumerate what it accepts. Runs BEFORE `start` and touches
    /// nothing else: no seat, no VT, no DRM master, no modeset, no
    /// output. `start` then reuses exactly this fd and this GBM device
    /// (openDevice/openGbm are idempotent), so the renderer the caller
    /// builds next renders and scans out on the same device the client
    /// dmabuf global imports into.
    ///
    /// Idempotent: a second call returns the same device. An explicit
    /// failure here IS the capability report - `error.GpuUnavailable`
    /// means this node cannot do the GPU data path, and the caller must
    /// report that rather than quietly run the CPU one.
    pub const PrepareError = error{ OutOfMemory, GpuUnavailable };

    pub fn prepareGpu(base: *backend_mod.Backend) PrepareError!*dmabuf.GbmDevice {
        const self = fromBackend(base);
        if (self.gbm) |dev| return dev;
        try prepareGbm(self);
        return self.gbm.?;
    }

    /// GPU mode, step 2: borrow the renderer's actual renderable
    /// (format, modifier) pairs for this backend's lifetime. Must run
    /// BEFORE `start`, because the first modeset negotiates against
    /// them: each output intersects them with what its primary plane
    /// really scans out and with what GBM can allocate.
    ///
    /// The slice is NOT copied - the renderer owns it and outlives the
    /// backend - and it is not freed here. After this call the backend
    /// is a GPU backend: no allocation or negotiation failure falls back
    /// to CPU scanout.
    pub const SetFormatsError = error{
        /// prepareGpu has not run, or this node has no GBM device.
        GpuNotPrepared,
        /// start() already ran: the first modeset is behind us.
        AlreadyStarted,
        /// The renderer renders into nothing this backend could ever
        /// scan out, so no output could be brought up.
        NoRenderableFormats,
    };

    pub fn setGpuFormats(
        base: *backend_mod.Backend,
        render_pairs: []const dmabuf.Format,
    ) SetFormatsError!void {
        const self = fromBackend(base);
        if (self.started) return error.AlreadyStarted;
        if (self.gbm == null) return error.GpuNotPrepared;
        if (render_pairs.len == 0) return error.NoRenderableFormats;
        self.gpu_render_pairs = render_pairs;
        log_mod.info(
            "drm: GPU scanout selected with {d} renderable pairs",
            self.io,
            self.log_cfg,
            "drm",
            .{render_pairs.len},
        );
    }

    /// Lease one of this output's GPU slots for drawing, or null when
    /// there is none to lease: a CPU-mode output, a torn-down device, or
    /// both slots taken (one is on screen, the other is being written or
    /// waiting for its flip).
    ///
    /// The returned frame is owned by the output, keeps its plane
    /// descriptors open for as long as the slot lives, and must be
    /// handed back exactly once - committed through `Output.State`
    /// `.gpu`, or given to `cancelGpuFrame` when that commit did not
    /// happen. A caller that drops it without either starves the output:
    /// the slot stays `writing` and no further frame can be presented.
    pub fn acquireGpuFrame(
        base: *backend_mod.Backend,
        out: *output_mod.Output,
    ) ?*gpu_frame.GpuFrame {
        _ = base;
        const drm_out: *DrmOutput = @ptrCast(@alignCast(out.data));
        if (drm_out.backend.fd == null) return null;
        const slots = drm_out.gpu_slots orelse return null;
        var states: [2]SlotState = .{ slots[0].state, slots[1].state };
        const index = GpuRing.firstFree(&states) orelse return null;
        const slot = &slots[index];
        slot.state = .writing;
        return &slot.frame;
    }

    /// Give a leased slot back without presenting it: the caller's commit
    /// failed, so the pixels it drew are discarded and the slot returns
    /// to `free` for the next frame. Anything that is not a live lease
    /// of this output (a frame from another output, an already
    /// committed or cancelled one) is ignored - cancelling twice must
    /// not hand the same buffer to two writers.
    pub fn cancelGpuFrame(
        base: *backend_mod.Backend,
        out: *output_mod.Output,
        frame: *gpu_frame.GpuFrame,
    ) void {
        _ = base;
        const drm_out: *DrmOutput = @ptrCast(@alignCast(out.data));
        if (!gpuFrameValid(drm_out, frame)) return;
        drm_out.gpu_slots.?[frame.slot].state = .free;
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
    if (handleEvents(self, fd) != 0) {
        log_mod.err("drm: drmHandleEvent failed", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
}

/// The handler context every drain runs with: v3, so libdrm calls
/// page_flip_handler2 with the CRTC the completion belongs to. Same
/// version and handler wlroots uses (backend/drm/drm.c handle_drm_event).
fn eventContext() c.drmEventContext {
    return .{
        .version = 3,
        .page_flip_handler2 = pageFlipHandler,
    };
}

/// Drain the KMS event queue as part of a state transition rather than a
/// poll tick - the resume barrier's two drains. It polls with a zero
/// timeout and never blocks, and it keeps reading for as long as the fd
/// stays readable, so an fd with nothing queued costs one poll and an fd
/// with a backlog costs exactly as many reads as it takes to empty it.
///
/// Correctness does not depend on this. A completion the kernel still
/// holds can arrive after the re-arm; the epoch moved before the first of
/// these drains is what makes such a completion unmatchable. What the
/// drain buys is that nothing ALREADY queued is delivered after the
/// re-arm, and that the queue is not left holding pre-suspend events that
/// would otherwise land in the middle of the first post-resume frames.
fn drainFlipEvents(self: *DrmBackendData) void {
    const fd = self.fd orelse return;
    var fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        // Timeout 0: a bare "is it readable" check, never a wait. A signal
        // is retried inside std.posix.poll itself.
        const ready = std.posix.poll(&fds, 0) catch {
            log_mod.warn("drm: resume: poll of the KMS fd failed", self.io, self.log_cfg, "drm", .{});
            return;
        };
        if (ready == 0 or fds[0].revents & std.posix.POLL.IN == 0) return;
        if (handleEvents(self, fd) != 0) {
            // Not fatal here: the caller is a sleep/resume transition, not
            // a frame tick, and the event loop's next dispatch reports the
            // same failure to the server.
            log_mod.warn("drm: resume: drmHandleEvent drain failed", self.io, self.log_cfg, "drm", .{});
            return;
        }
        // poll(2) clears revents on every call, so the next iteration asks
        // the kernel again rather than repeating this answer.
        fds[0].revents = 0;
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
///                               and the VT switch (VT_ACTIVATE +
///                               bounded VT_GETSTATE confirmation).
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
/// points the plane at one of them. The VT switch is confirmed by polling
/// VT_GETSTATE.v_active on the console fd session.zig opened, so the DRM
/// fd is read only by `dispatch`, for DRM events. Phases inside
/// `addOutput` for the properties and blobs (scanKmsProps, createModeBlob)
/// are atomic-only — the legacy interface has neither.
///
/// One `errdefer drmTeardown` covers every failure: teardown is
/// null-safe, idempotent and ordered by reverse acquisition, so a phase
/// that dies half-way leaves the phases before it to be released in the
/// right order. Success keeps everything; `destroy` tears it down.
fn startInner(base: *backend_mod.Backend) error{ BackendFailed, OutOfMemory }!void {
    const self: *DrmBackendData = @ptrCast(@alignCast(base.data));

    // --- phases 1-2: the device itself. A failed open publishes no fd, so
    // teardown only starts mattering once the open succeeded. Both phases
    // are idempotent: prepareGpu may already have opened the node before
    // start, and start must reuse THAT fd.
    try openDevice(self);
    errdefer drmTeardown(self);
    selectKmsInterface(self);
    // From here the backend mutates the device, so GPU mode can no longer
    // be selected: setGpuFormats has to have run before this point.
    self.started = true;

    // --- phase 3: the seat, before anyone can take the master away. Every
    // failure here is non-fatal and logged by openSession itself: the VM
    // has no logind at all, and a machine that refuses the session still
    // runs - it just does not hold the seat (see session.zig's failure
    // policy).
    openSession(self);

    // --- phase 4: master. After the session, so logind knows the device is
    // ours before we ask for it.
    becomeMaster(self);

    // --- phase 5: the GBM device. Already opened when prepareGpu ran, so
    // this is a no-op there and the same device is reused. Not fatal:
    // a node without GBM (or with no format GBM accepts) still scans out
    // - on the dumb path - it just cannot offer zwp_linux_dmabuf_v1 nor
    // scan out a modifier-capable framebuffer. In GPU mode there is
    // nothing to fall back to, and prepareGbm already refused.
    try tryOpenGbm(self);

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
    // drmTeardown closed the KMS fd. Closing a DRM fd destroys the file's
    // event queue, so no queued page-flip event can be delivered after it:
    // a completion can only resolve a cookie to a live output of this
    // backend, and there are none left.
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
///
/// Idempotent, and deliberately so: prepareGpu opens the same node BEFORE
/// start so the renderer can be built on this device's GBM device, and
/// start then reuses that exact fd. Opening twice would give the
/// renderer and the KMS path different file descriptions of one card,
/// which is precisely what wlroots avoids by reopening the node only for
/// the allocator (render/allocator/allocator.c:35-96).
fn openDevice(self: *DrmBackendData) error{BackendFailed}!void {
    if (self.fd != null) return;
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
    self.session = session_mod.Session.open(self.allocator, self.io, self.log_cfg, .{
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
/// VT is re-activated, DRM master is re-acquired and every output is put
/// back into a state this backend can present from.
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
        for (self.outputs.items) |drm_out| resumeOutput(self, drm_out);
        log_mod.info(
            "drm: resume: DRM master re-acquired; {d} output(s) re-modeset and repainting",
            self.io,
            self.log_cfg,
            "drm",
            .{self.outputs.items.len},
        );
    }
}

/// One output's half of the resume, in the only order that is safe.
///
/// A suspend loses the CRTC state: the console takes the card over, the
/// flip that was in flight when the machine slept may or may not still be
/// pending in the kernel, and DRM_IOCTL_DROP_MASTER does NOT drain the
/// file's event queue. So the resume cannot simply drop the pending flip
/// and hope the old completion never arrives - a completion that lands
/// after the re-arm would find the current pending slot and present it,
/// which is a false present and a slot the ring still believes is queued.
///
/// What happens instead:
///
///  1. the epoch moves and the pending flip is dropped, so every
///     completion from before this moment names a cookie no output waits
///     for any more: it cannot touch the ring, present, or the compositor;
///  2. whatever the kernel has already queued is drained and discarded
///     under that new epoch;
///  3. the CRTC is put back into a state this backend owns, by re-running
///     the same modeset start() ran - atomic commit with
///     DRM_MODE_ATOMIC_ALLOW_MODESET, or drmModeSetCrtc on the legacy
///     interface - over the buffers, plane and mode blob this output
///     already has. Nothing is recreated: no new GBM device, no renderer,
///     no framebuffer, no blob. On the atomic interface that commit is
///     blocking, so a flip still pending on the CRTC completes before the
///     modeset is applied;
///  4. the queue is drained once more, for a completion the blocking
///     modeset itself waited for;
///  5. the framebuffer that modeset bound becomes the ring's front
///     buffer, everything else is free, and the output is asked for a
///     full repaint. Pacing restarts from a known state.
///
/// A failed re-modeset is reported, not hidden: the ring is still reset
/// to the one buffer the modeset was asked to bind, because refusing to
/// present at all would leave the machine with a black screen and a
/// silent log.
fn resumeOutput(self: *DrmBackendData, drm_out: *DrmOutput) void {
    invalidateFlipIdentity(drm_out);
    drainFlipEvents(self);
    const bound = reapplyModeset(self, drm_out);
    drainFlipEvents(self);
    adoptModesetFront(drm_out, bound);
    if (drm_out.out) |out| out.sendFrame();
}

/// Every completion this output ever queued is now irrelevant: the flip
/// epoch moves and the output stops waiting for a flip. Nothing else has
/// to be forgotten - the kernel still holds the old cookie, but that
/// cookie now matches no pending flip on any output, so its completion
/// can only ever be dropped.
fn invalidateFlipIdentity(drm_out: *DrmOutput) void {
    drm_out.epoch += 1;
    drm_out.pending = null;
}

/// Re-run this output's modeset over the resources it already owns. False
/// when the device refused it, which is reported by the caller.
fn reapplyModeset(self: *DrmBackendData, drm_out: *DrmOutput) bool {
    if (self.fd == null) return false;
    var found = FoundConnector{
        .connector_id = drm_out.connector_id,
        .crtc_id = drm_out.crtc_id,
        .crtc_index = 0,
        .mode = drm_out.crtc_mode,
    };
    const plane = PlaneSelection{ .id = drm_out.plane_id, .props = drm_out.props };
    modeset(self, &found, plane, drm_out) catch |err| {
        log_mod.err(
            "drm: resume: modeset of crtc {d} failed ({s})",
            self.io,
            self.log_cfg,
            "drm",
            .{ drm_out.crtc_id, @errorName(err) },
        );
        return false;
    };
    return true;
}

/// Derive the ring from what the modeset actually bound: the first
/// framebuffer of whichever swapchain this output has (the same
/// `initialFbId` the modeset builders name), front, and the other side
/// free. A renderer lease that was open across the suspend stops being
/// valid here - the ring state check in `gpuFrameValid` rejects it, and
/// the server cancels it like any other refused commit.
fn adoptModesetFront(drm_out: *DrmOutput, modeset_ok: bool) void {
    drm_out.flip_index = 0;
    drm_out.pending = null;
    if (!modeset_ok) {
        log_mod.warn(
            "drm: resume: crtc {d} was not re-modeset; adopting the modeset framebuffer as front anyway",
            drm_out.backend.io,
            drm_out.backend.log_cfg,
            "drm",
            .{drm_out.crtc_id},
        );
    }
    const slots = drm_out.gpu_slots orelse return;
    slots[0].state = .front;
    slots[1].state = .free;
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
/// Two callers, one body: `tryOpenGbm` (start) treats every failure as
/// NON-fatal, because a node with no GBM (a virtual machine without a
/// render node, a driver whose gbm_create_device refuses) must still scan
/// out on the dumb path - it simply does not get a
/// zwp_linux_dmabuf_v1 global. `prepareGbm` (DrmBackend.prepareGpu) turns
/// the same failures into an explicit capability error, because a caller
/// that asked for the GPU data path must be told rather than handed the
/// CPU one. A global without a device behind it is a promise the client
/// can falsify on its first create request, and a GPU request answered
/// with CPU scanout is the same lie in a different place.
///
/// Idempotent: prepareGpu runs first in GPU mode and start finds the
/// device already there.
fn tryOpenGbm(self: *DrmBackendData) error{OutOfMemory}!void {
    _ = openGbm(self) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoGbmNode => {
            log_mod.info("drm: no GBM node for {s}; dmabuf import disabled", self.io, self.log_cfg, "drm", .{
                self.device_path,
            });
            return;
        },
        error.NoGbmFormats => {
            log_mod.info("drm: GBM on {s} advertises no supported format; dmabuf import disabled", self.io, self.log_cfg, "drm", .{self.device_path});
            return;
        },
    };
}

/// The explicit-GPU-mode form of openGbm: same work, failure reported.
/// Runs before `start`, so the renderer the caller builds next lands on
/// this exact GBM device.
fn prepareGbm(self: *DrmBackendData) error{ OutOfMemory, GpuUnavailable }!void {
    if (self.gbm != null) return;
    openDevice(self) catch return error.GpuUnavailable;
    _ = openGbm(self) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoGbmNode => {
            log_mod.err("drm: {s} has no GBM node; the GPU data path needs one", self.io, self.log_cfg, "drm", .{self.device_path});
            return error.GpuUnavailable;
        },
        error.NoGbmFormats => {
            log_mod.err("drm: GBM on {s} accepts no (format, modifier) pair; the GPU data path needs one", self.io, self.log_cfg, "drm", .{self.device_path});
            return error.GpuUnavailable;
        },
    };
}

const GbmOpenError = error{ OutOfMemory, NoGbmNode, NoGbmFormats };

/// Create the GBM device on this device's own node. Publishes it on
/// `self.gbm` on success only.
fn openGbm(self: *DrmBackendData) GbmOpenError!void {
    if (self.gbm != null) return;
    const node = gbmNodePath(self) orelse return error.NoGbmNode;
    defer self.allocator.free(node);
    const dev = dmabuf.GbmDevice.create(self.allocator, node) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NodeOpenFailed, error.GbmCreateFailed, error.DevStatFailed => {
            log_mod.warn("drm: gbm device on {s} failed ({s}); dmabuf import disabled", self.io, self.log_cfg, "drm", .{
                node,
                @errorName(err),
            });
            return error.NoGbmNode;
        },
    };
    errdefer dev.deinit();
    dev.setFormats(try queryGbmFormats(self, dev));
    if (dev.formats.len == 0) return error.NoGbmFormats;
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
///
/// The returned path is OWNED by the caller. libdrm hands back a
/// malloc'd string that the caller must free, so the bytes are copied
/// out before that free - returning the span itself (and freeing it in a
/// `defer`) would hand the caller a path into freed memory, which is
/// exactly what a GBM device create on the node then reads.
fn gbmNodePath(self: *DrmBackendData) ?[]u8 {
    const fd = self.fd orelse return null;
    if (c.drmGetRenderDeviceNameFromFd(fd)) |name| {
        defer std.c.free(name);
        return self.allocator.dupe(u8, std.mem.span(name)) catch null;
    }
    if (c.drmGetDeviceNameFromFd2(fd)) |name| {
        defer std.c.free(name);
        return self.allocator.dupe(u8, std.mem.span(name)) catch null;
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
/// The kernel's FULL per-format modifier list (the plane's IN_FORMATS
/// blob) is not walked here, because this list is what the compositor
/// tells CLIENTS it can import and the client path only ever promises
/// linear: a tiled buffer this pipeline cannot scan out would be a
/// promise the first page flip breaks. GPU scanout negotiation does read
/// the blob - `planeScanoutFormats`, against the renderer's own pairs.
/// A driver that can only do tiled layouts therefore gets no advertised
/// import pair and no zwp_linux_dmabuf_v1 global - which is the honest
/// answer.
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
    // GPU mode resolves ONE primary plane and uses it both as the commit
    // target (atomic interface) and as the capability probe (both
    // interfaces: the legacy one has no plane commit, but it does have
    // planes, and their IN_FORMATS blob is where the scannable layouts
    // come from). CPU mode keeps today's behaviour, where the plane is
    // only looked for on the atomic path.
    var plane: PlaneSelection = .{};
    if (gpuModeSelected(self)) {
        var gpu_props: PlanePropIds = .{};
        const gpu_plane_id = try resolveGpuPlane(self, found, &gpu_props);
        plane = .{ .id = gpu_plane_id, .props = gpu_props };
    } else {
        plane = try resolvePlane(self, found);
    }
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
        .gpu_plane_id = plane.id,
        .crtc_mode = found.mode,
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

/// The primary plane GPU mode drives, on either KMS interface. Resolved
/// unconditionally here (unlike resolvePlane, which is atomic-only)
/// because GPU mode needs the plane as a CAPABILITY statement even when
/// the legacy interface commits through the CRTC: the negotiated
/// (format, modifier) comes from this plane's IN_FORMATS blob, and the
/// plane id is what keeps two outputs off the same hardware.
fn resolveGpuPlane(
    self: *DrmBackendData,
    found: FoundConnector,
    props: *PlanePropIds,
) error{BackendFailed}!u32 {
    const id = findPrimaryPlane(self, found.crtc_index, props) orelse {
        log_mod.err(
            "drm: no primary plane for crtc={d}; the GPU data path needs one",
            self.io,
            self.log_cfg,
            "drm",
            .{found.crtc_id},
        );
        return error.BackendFailed;
    };
    return id;
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
///
/// GPU mode has NO such fallback. `setGpuFormats` was an explicit
/// selection, so failing the allocation fails the output rather than
/// quietly handing back a CPU path the caller did not ask for and cannot
/// tell apart from a real one.
fn createScanoutBuffers(self: *DrmBackendData, found: FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    if (gpuModeSelected(self)) {
        try createGpuSlots(self, found, drm_out);
        drm_out.scanout = .gpu;
        return;
    }
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

/// Was the GPU data path selected explicitly? The single source of truth
/// for every branch in this file: renderer pairs were handed to
/// setGpuFormats, so allocation, commit and lease all go through the GPU
/// ring and never through `buffers`/`copyRows`.
fn gpuModeSelected(self: *DrmBackendData) bool {
    const pairs = self.gpu_render_pairs orelse return false;
    return pairs.len != 0;
}

/// The (format, modifier) both ends of the pipeline agreed on for one
/// output: the plane really scans it out, the renderer can render into
/// it, and GBM can allocate it.
const GpuScanoutFormat = struct {
    format: u32,
    modifier: u64,
};

/// Pick the pair to allocate scanout buffers with, or null when the
/// three capability sets have nothing in common.
///
/// Order of authority: the renderer's pairs come first, because the
/// renderer is the one that has to draw into the result. Each is
/// accepted only when the output's primary plane lists it (from its
/// IN_FORMATS blob AND its format list) and GBM says it can allocate it
/// with at least one plane. A modifier no plane reports is never
/// substituted for a better one - guessing LINEAR here is exactly the
/// failure this replaces, where a flip then lands on a plane that
/// cannot present that layout.
fn chooseGpuFormat(
    plane_pairs: []const dmabuf.Format,
    render_pairs: []const dmabuf.Format,
    ctx: *anyopaque,
    probe: *const fn (ctx: *anyopaque, format: u32, modifier: u64) bool,
) ?GpuScanoutFormat {
    for (render_pairs) |candidate| {
        if (!dmabuf.supports(plane_pairs, candidate.format, candidate.modifier)) continue;
        if (!probe(ctx, candidate.format, candidate.modifier)) continue;
        return .{ .format = candidate.format, .modifier = candidate.modifier };
    }
    return null;
}

/// What GBM can actually allocate for a pair, through the same call the
/// client import path uses (render/allocator/gbm.c:71-87). Injected into
/// chooseGpuFormat as a probe so the negotiation itself is testable
/// without a device.
fn gbmAcceptsPair(ctx: *anyopaque, format: u32, modifier: u64) bool {
    const dev: *dmabuf.GbmDevice = @ptrCast(@alignCast(ctx));
    return gbm_c.gbm_device_get_format_modifier_plane_count(dev.device, format, modifier) >= 1;
}

/// Allocate this output's GPU ring: two buffer objects with the same
/// negotiated layout, both added as KMS framebuffers BEFORE the first
/// modeset (the modeset names one of them as the initial front buffer,
/// and a plane commit needs its FB_ID to exist first).
///
/// Allocation order per slot, and why it is that order: create the bo,
/// check the modifier it came back with, export its plane descriptors,
/// then add the framebuffer. Every step after the bo has an `errdefer`
/// that unwinds exactly what it created - descriptors close before the
/// bo dies (an EGL image may still hold them), and the bo dies before
/// the framebuffer can name it. Both slots are allocated before either
/// is published, so a failure on the second leaves the first to be
/// released by the caller's error path rather than a half-built ring.
fn createGpuSlots(self: *DrmBackendData, found: FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    const gbm = self.gbm orelse {
        log_mod.err("drm: GPU mode without a GBM device", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    };
    const plane_id = drm_out.gpu_plane_id;
    if (plane_id == 0) {
        log_mod.err("drm: GPU mode without a primary plane", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
    const render_pairs = self.gpu_render_pairs orelse return error.BackendFailed;

    const plane_pairs = planeScanoutFormats(self, plane_id) catch return error.BackendFailed;
    defer self.allocator.free(plane_pairs);
    const chosen = chooseGpuFormat(plane_pairs, render_pairs, gbm, gbmAcceptsPair) orelse {
        log_mod.err(
            "drm: plane {d} scans out none of the renderer's {d} pairs",
            self.io,
            self.log_cfg,
            "drm",
            .{ plane_id, render_pairs.len },
        );
        return error.BackendFailed;
    };
    log_mod.info(
        "drm: GPU scanout on plane {d}: format 0x{x} modifier 0x{x}",
        self.io,
        self.log_cfg,
        "drm",
        .{ plane_id, chosen.format, chosen.modifier },
    );

    const slots = self.allocator.create([2]GpuSlot) catch return error.BackendFailed;
    slots.* = .{ .{}, .{} };
    // Registered in release order: whichever slot fails, both are
    // released (framebuffers, then descriptors, then the buffer objects)
    // before the allocation goes back.
    errdefer self.allocator.destroy(slots);
    errdefer releaseGpuSlot(self, &slots[0]);
    errdefer releaseGpuSlot(self, &slots[1]);
    var i: usize = 0;
    while (i < slots.len) : (i += 1) {
        try allocGpuSlot(self, gbm, drm_out, found, @intCast(i), chosen, &slots[i]);
    }
    drm_out.gpu_slots = slots;
}

/// One slot: a GEM buffer object with a modifier GBM really honoured,
/// its plane descriptors exported for the renderer, and a KMS
/// framebuffer for the flip to name.
fn allocGpuSlot(
    self: *DrmBackendData,
    gbm: *dmabuf.GbmDevice,
    drm_out: *DrmOutput,
    found: FoundConnector,
    index: u2,
    format: GpuScanoutFormat,
    slot: *GpuSlot,
) error{BackendFailed}!void {
    const fd = self.fd.?;
    const width = found.mode.hdisplay;
    const height = found.mode.vdisplay;
    // SCANOUT (this is what KMS will display) | RENDERING (this is what
    // the renderer will draw into). Deliberately NOT LINEAR: nothing on
    // this path maps the bo, so there is no reason to constrain the
    // driver to a CPU-visible layout.
    const modifiers = [1]u64{format.modifier};
    const bo = gbm_c.gbm_bo_create_with_modifiers2(
        gbm.device,
        width,
        height,
        format.format,
        &modifiers,
        modifiers.len,
        gbm_c.GBM_BO_USE_SCANOUT | gbm_c.GBM_BO_USE_RENDERING,
    ) orelse {
        log_mod.err(
            "drm: gbm_bo_create_with_modifiers(0x{x}, 0x{x}) failed",
            self.io,
            self.log_cfg,
            "drm",
            .{ format.format, format.modifier },
        );
        return error.BackendFailed;
    };
    // The slot owns the bo from here: every failure below is unwound by
    // releaseGpuSlot (createGpuSlots' errdefer), which drops the
    // descriptors, the framebuffer and then the bo - each id zeroed as it
    // goes, so a half-built slot releases exactly what it holds.
    slot.bo = bo;
    // The driver may hand back a different layout than the one asked
    // for. Taking that silently would mean the framebuffer's modifier
    // disagrees with the plane's, which the kernel rejects at the flip
    // - so it is checked here, where the error can still name both.
    const got_modifier = gbm_c.gbm_bo_get_modifier(bo);
    if (got_modifier != format.modifier) {
        log_mod.err(
            "drm: GBM returned modifier 0x{x} for a 0x{x} request",
            self.io,
            self.log_cfg,
            "drm",
            .{ got_modifier, format.modifier },
        );
        return error.BackendFailed;
    }
    slot.format = format.format;
    slot.modifier = got_modifier;

    // Export the plane descriptors before the framebuffer exists: the FB
    // add needs the same handles, and a renderer that has not imported
    // them yet must not see a framebuffer it could not render into.
    try exportGpuPlanes(self, bo, width, height, &slot.frame.attributes);

    var fb_id: u32 = 0;
    const planes: usize = slot.frame.attributes.n_planes;
    var handles: [dmabuf.max_planes]u32 = .{0} ** dmabuf.max_planes;
    var pitches: [dmabuf.max_planes]u32 = .{0} ** dmabuf.max_planes;
    var offsets: [dmabuf.max_planes]u32 = .{0} ** dmabuf.max_planes;
    var fb_modifiers: [dmabuf.max_planes]u64 = .{0} ** dmabuf.max_planes;
    var p: usize = 0;
    while (p < planes) : (p += 1) {
        handles[p] = gbm_c.gbm_bo_get_handle_for_plane(bo, @intCast(p)).u32;
        pitches[p] = slot.frame.attributes.planes[p].stride;
        offsets[p] = slot.frame.attributes.planes[p].offset;
        fb_modifiers[p] = got_modifier;
    }
    if (c.drmModeAddFB2WithModifiers(
        fd,
        width,
        height,
        format.format,
        &handles,
        &pitches,
        &offsets,
        &fb_modifiers,
        &fb_id,
        0,
    ) != 0) {
        log_mod.err("drm: drmModeAddFB2WithModifiers failed", self.io, self.log_cfg, "drm", .{});
        return error.BackendFailed;
    }
    slot.fb_id = fb_id;

    self.next_generation += 1;
    slot.generation = self.next_generation;
    slot.frame.fb_id = fb_id;
    slot.frame.owner = drm_out;
    slot.frame.slot = index;
    slot.frame.generation = slot.generation;
    log_mod.debug(
        "drm: GPU slot {d}: bo planes={d} fb={d} generation={d}",
        self.io,
        self.log_cfg,
        "drm",
        .{ index, planes, fb_id, slot.generation },
    );
}

/// Export every plane of `bo` as descriptors the renderer can import and
/// the framebuffer can be described by, with the offsets and strides the
/// bo really uses.
///
/// The fds GBM returns are duplicated: `gbm_bo_get_fd_for_plane` hands out
/// a descriptor the bo owns, and the renderer may still be importing from
/// ours when the bo is destroyed (the server releases its GL targets
/// before backend slot memory, which is what makes that ordering safe).
fn exportGpuPlanes(
    self: *DrmBackendData,
    bo: *gbm_c.struct_gbm_bo,
    width: u32,
    height: u32,
    attrs: *dmabuf.Attributes,
) error{BackendFailed}!void {
    const count = gbm_c.gbm_bo_get_plane_count(bo);
    if (count < 1 or count > dmabuf.max_planes) {
        log_mod.err("drm: GBM buffer has {d} planes", self.io, self.log_cfg, "drm", .{count});
        return error.BackendFailed;
    }
    const planes: u8 = @intCast(count);
    var made: u8 = 0;
    errdefer {
        attrs.n_planes = made;
        attrs.closePlanes();
    }
    while (made < planes) : (made += 1) {
        const plane_fd = gbm_c.gbm_bo_get_fd_for_plane(bo, @intCast(made));
        if (plane_fd < 0) {
            log_mod.err("drm: plane {d} has no exportable fd", self.io, self.log_cfg, "drm", .{made});
            return error.BackendFailed;
        }
        const owned = std.os.linux.dup(plane_fd);
        if (std.os.linux.errno(owned) != .SUCCESS) return error.BackendFailed;
        attrs.planes[made] = .{
            .fd = @intCast(owned),
            .offset = @intCast(gbm_c.gbm_bo_get_offset(bo, @intCast(made))),
            .stride = gbm_c.gbm_bo_get_stride_for_plane(bo, @intCast(made)),
        };
        attrs.n_planes = made + 1;
    }
    attrs.width = @intCast(width);
    attrs.height = @intCast(height);
    attrs.format = gbm_c.gbm_bo_get_format(bo);
    attrs.modifier = gbm_c.gbm_bo_get_modifier(bo);
}

/// Release one GPU slot: the framebuffer first (it is what the kernel
/// holds a reference through), then the exported descriptors (a live
/// EGL image may still be reading them), then the buffer object. Every
/// id is zeroed as it is released, so this is idempotent and safe on a
/// slot that never finished being built.
fn releaseGpuSlot(self: *DrmBackendData, slot: *GpuSlot) void {
    if (slot.fb_id != 0) {
        if (self.fd) |fd| _ = c.drmModeRmFB(fd, slot.fb_id);
        slot.fb_id = 0;
    }
    slot.frame.attributes.closePlanes();
    slot.frame.fb_id = 0;
    if (slot.bo) |bo| {
        slot.bo = null;
        gbm_c.gbm_bo_destroy(bo);
    }
    slot.format = 0;
    slot.modifier = 0;
    slot.state = .free;
}

/// Both slots of one output's ring.
fn releaseGpuSlots(self: *DrmBackendData, drm_out: *DrmOutput) void {
    const slots = drm_out.gpu_slots orelse return;
    drm_out.gpu_slots = null;
    for (slots) |*slot| releaseGpuSlot(self, slot);
    self.allocator.destroy(slots);
}

/// The (format, modifier) pairs this output's primary plane really scans
/// out, read from the plane's IN_FORMATS blob and intersected with the
/// plane's own fourcc list.
///
/// The blob (drm_mode.h "plane framebuffer check") is the authoritative
/// modifier list: a header, the fourccs, then one `drm_format_modifier`
/// per format whose `formats` bitmask and `offset` select the fourccs it
/// applies to. A blob that is absent, truncated or of an unknown version
/// yields nothing rather than a guess: advertising LINEAR because
/// nothing was read is the failure this replaces.
fn planeScanoutFormats(self: *DrmBackendData, plane_id: u32) error{OutOfMemory}![]dmabuf.Format {
    var list: std.ArrayList(dmabuf.Format) = .empty;
    errdefer list.deinit(self.allocator);
    const fd = self.fd orelse return list.toOwnedSlice(self.allocator);

    // The plane's own fourcc list: what the plane claims to scan out,
    // independent of which layouts apply to which format.
    const plane = c.drmModeGetPlane(fd, plane_id) orelse return list.toOwnedSlice(self.allocator);
    defer c.drmModeFreePlane(plane);
    var list_formats: std.ArrayList(u32) = .empty;
    defer list_formats.deinit(self.allocator);
    var fi: u32 = 0;
    while (fi < plane.*.count_formats) : (fi += 1) {
        try list_formats.append(self.allocator, plane.*.formats[fi]);
    }

    // IN_FORMATS: the per-format modifier list.
    const props = c.drmModeObjectGetProperties(fd, plane_id, c.DRM_MODE_OBJECT_PLANE) orelse
        return list.toOwnedSlice(self.allocator);
    defer c.drmModeFreeObjectProperties(props);
    var blob_id: u32 = 0;
    var i: u32 = 0;
    while (i < props.*.count_props) : (i += 1) {
        const prop = c.drmModeGetProperty(fd, props.*.props[i]) orelse continue;
        defer c.drmModeFreeProperty(prop);
        const name_ptr: [*:0]const u8 = @ptrCast(&prop.*.name);
        if (std.mem.eql(u8, std.mem.sliceTo(name_ptr, 0), "IN_FORMATS")) {
            // prop_values are u64 in the uapi; a blob id is a 32-bit
            // object id and anything above that is not one.
            blob_id = std.math.cast(u32, props.*.prop_values[i]) orelse 0;
            break;
        }
    }
    if (blob_id == 0) {
        log_mod.debug(
            "drm: plane {d} has no IN_FORMATS; no modifier list to negotiate from",
            self.io,
            self.log_cfg,
            "drm",
            .{plane_id},
        );
        return list.toOwnedSlice(self.allocator);
    }
    const blob = c.drmModeGetPropertyBlob(fd, blob_id) orelse
        return list.toOwnedSlice(self.allocator);
    defer c.drmModeFreePropertyBlob(blob);
    const data = blob.*.data orelse return list.toOwnedSlice(self.allocator);
    const bytes = @as([*]const u8, @ptrCast(data))[0..blob.*.length];
    try parseInFormats(bytes, list_formats.items, &list, self.allocator);
    return list.toOwnedSlice(self.allocator);
}

/// Parse one IN_FORMATS blob into (format, modifier) pairs, keeping only
/// fourccs the plane lists.
///
/// The header's counts and offsets come from the kernel, so every read is
/// bounds-checked against the blob length and a truncated blob stops the
/// parse instead of walking off it.
fn parseInFormats(
    bytes: []const u8,
    fourccs: []const u32,
    out: *std.ArrayList(dmabuf.Format),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    const format_blob_current: u32 = 1;
    const header_size = 6 * @sizeOf(u32);
    if (bytes.len < header_size) return;
    const version = readU32(bytes, 0) orelse return;
    if (version != format_blob_current) return;
    const count_formats = readU32(bytes, 2 * @sizeOf(u32)) orelse return;
    const formats_offset = readU32(bytes, 3 * @sizeOf(u32)) orelse return;
    const count_modifiers = readU32(bytes, 4 * @sizeOf(u32)) orelse return;
    const modifiers_offset = readU32(bytes, 5 * @sizeOf(u32)) orelse return;

    // struct drm_format_modifier: u64 formats, u32 offset, u32 pad,
    // u64 modifier.
    const modifier_size: usize = 24;
    var i: u32 = 0;
    while (i < count_modifiers) : (i += 1) {
        const base = @as(usize, modifiers_offset) + @as(usize, i) * modifier_size;
        const formats_mask = readU64(bytes, base) orelse return;
        const format_offset = readU32(bytes, base + 8) orelse return;
        const modifier = readU64(bytes, base + 16) orelse return;
        var bit: u7 = 0;
        while (bit < 64) : (bit += 1) {
            if (formats_mask & (@as(u64, 1) << @intCast(bit)) == 0) continue;
            const index = @as(usize, format_offset) + bit;
            if (index >= count_formats) continue;
            const at = @as(usize, formats_offset) + index * @sizeOf(u32);
            const format = readU32(bytes, at) orelse return;
            // Both lists must agree: the blob says which layouts apply,
            // the plane's fourcc list says what it scans out at all.
            var listed = false;
            for (fourccs) |candidate| {
                if (candidate == format) {
                    listed = true;
                    break;
                }
            }
            if (!listed) continue;
            if (dmabuf.supports(out.items, format, modifier)) continue;
            try out.append(allocator, .{ .format = format, .modifier = modifier });
        }
    }
}

/// A little-endian u32 at `offset`, or null when the blob is too short.
fn readU32(bytes: []const u8, offset: usize) ?u32 {
    if (offset + @sizeOf(u32) > bytes.len) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

/// A little-endian u64 at `offset`, or null when the blob is too short.
fn readU64(bytes: []const u8, offset: usize) ?u64 {
    if (offset + @sizeOf(u64) > bytes.len) return null;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
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
        .{ plane.id, initialFbId(drm_out), secondFbId(drm_out), plane.props.fb_damage_clips, damage_blob },
    );
    const commit_rc = c.drmModeAtomicCommit(fd, req, c.DRM_MODE_ATOMIC_ALLOW_MODESET, null);
    if (commit_rc != 0) {
        logAtomicModesetFailure(self, found, plane, drm_out, damage_blob, commit_rc);
        return error.BackendFailed;
    }
}

/// The framebuffer the modeset binds as the initial front buffer: the
/// GPU ring's first slot in GPU mode, the CPU swapchain's A side
/// otherwise. Both were allocated before the modeset ran, which is what
/// the plane commit needs.
fn initialFbId(drm_out: *const DrmOutput) u32 {
    if (drm_out.gpu_slots) |slots| return slots[0].fb_id;
    return drm_out.buffers[0].fb_id;
}

/// The other buffer of the same swapchain, for logs only: which id a
/// flip would move to next.
fn secondFbId(drm_out: *const DrmOutput) u32 {
    if (drm_out.gpu_slots) |slots| return slots[1].fb_id;
    return drm_out.buffers[1].fb_id;
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
        c.drmModeAtomicAddProperty(req, plane.id, plane.props.fb_id, initialFbId(drm_out)) < 0 or
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
            initialFbId(drm_out),
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
/// with the connector array + mode). The first buffer of whichever
/// swapchain this output has is what the modeset binds: `buffers[0]` on
/// the CPU paths, GPU ring slot 0 in GPU mode.
fn legacyModeset(self: *DrmBackendData, found: *FoundConnector, drm_out: *DrmOutput) error{BackendFailed}!void {
    if (c.drmModeSetCrtc(
        self.fd.?,
        found.crtc_id,
        initialFbId(drm_out),
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
    // The modeset bound slot 0, so that is what is on screen: the ring
    // starts with one front buffer and one free one, exactly like the CPU
    // swapchain's A/B sides.
    if (drm_out.gpu_slots) |slots| slots[0].state = .front;
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
        switch (state.buffer orelse return error.InvalidState) {
            .cpu => |fb| {
                // A CPU buffer is only meaningful on a CPU output: a GPU
                // output has no CPU front buffer to copy into, so taking
                // one would mean silently dropping the frame.
                if (self.gpu_slots != null) return error.InvalidState;
                if (fb.width != self.mode.width or fb.height != self.mode.height) return error.InvalidState;
                if (fb.stride < fb.width * 4) return error.InvalidState;
            },
            .gpu => |frame| {
                // The lease must be live and ours: wrong owner, wrong
                // slot, stale generation, or a slot that is not being
                // written are rejected here rather than flipped to.
                if (!gpuModeSelected(self.backend)) return error.InvalidState;
                if (!gpuFrameValid(self, frame)) return error.InvalidState;
                if (frame.fb_id == 0) return error.InvalidState;
                if (frame.attributes.width != self.mode.width or
                    frame.attributes.height != self.mode.height)
                {
                    return error.InvalidState;
                }
            },
        }
    }
}

fn commit(out: *output_mod.Output, state: *const output_mod.Output.State) error{CommitFailed}!void {
    const self: *DrmOutput = @ptrCast(@alignCast(out.data));
    if (state.committed & output_mod.Output.State.committed_buffer == 0) return;
    if (self.backend.fd == null) return error.CommitFailed;

    // Frame pacing guarantees at most one flip in flight (the event for
    // the previous flip drives the next frame); a second flip before the
    // event would EBUSY. wlroots atomic.c guards the same way.
    if (self.pending != null) {
        // Normal pacing under the requestRender-driven model: a commit
        // can land while the previous flip is still in flight; the flip
        // completion event re-renders it. Not an error.
        log_mod.debug("drm: page flip already pending", self.backend.io, self.backend.log_cfg, "drm", .{});
        return error.CommitFailed;
    }

    const buffer = state.buffer orelse return error.CommitFailed;
    switch (buffer) {
        .gpu => |frame| return commitGpu(self, frame),
        .cpu => {
            // A CPU frame on a GPU output has nowhere to go: this output
            // has no CPU front buffer. testState rejects it, and this is
            // the same rule enforced where it would otherwise be a silent
            // dropped frame.
            if (self.gpu_slots != null) return error.CommitFailed;
        },
    }
    const fb = buffer.cpu;
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
    // through dispatch() and pageFlipHandler releases the pending flip. No
    // damage property exists on this path (damage is a plane property).
    if (!self.backend.atomic) {
        const cookie = armFlip(self) orelse return error.CommitFailed;
        if (c.drmModePageFlip(
            self.backend.fd.?,
            self.crtc_id,
            buf.fb_id,
            c.DRM_MODE_PAGE_FLIP_EVENT,
            cookiePointer(cookie),
        ) != 0) {
            disarmFlip(self);
            log_mod.err("drm: drmModePageFlip failed", self.backend.io, self.backend.log_cfg, "drm", .{});
            return error.CommitFailed;
        }
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
    const cookie = armFlip(self) orelse return error.CommitFailed;
    if (c.drmModeAtomicCommit(
        fd,
        req,
        c.DRM_MODE_PAGE_FLIP_EVENT | c.DRM_MODE_ATOMIC_NONBLOCK,
        cookiePointer(cookie),
    ) != 0) {
        disarmFlip(self);
        log_mod.err("drm: page flip commit failed", self.backend.io, self.backend.log_cfg, "drm", .{});
        return error.CommitFailed;
    }
    // The flip is queued; the buffer just flipped to is now the
    // displayed one, so the next commit copies into the other. Frame
    // pacing (one flip in flight, the completion event drives the next
    // frame) keeps this index accurate at commit time.
    self.flip_index = 1 - self.flip_index;
}

/// Present a leased GPU slot: page-flip the plane onto that slot's
/// framebuffer and nothing else.
///
/// There is no copy on this path, by construction: the renderer already
/// drew into the buffer object's memory through a GL target imported
/// from these same plane descriptors, so the compositor has nothing to
/// move and never looks at the pixels. The one thing that must happen
/// before the flip is that the renderer's GL work has finished - that is
/// `Gles2Renderer.finishRendering` (glFinish), the server's job,
/// immediately before it builds this state, because the kernel reads
/// the buffer when the flip completes.
///
/// The lease only becomes `pending` when the kernel has ACCEPTED the
/// flip. Any failure leaves the slot `writing`: the caller's commit did
/// not happen, so it still owns those pixels and must either retry or
/// cancel. Taking the slot here and failing later would hand a buffer
/// back to the next writer while the caller believes it is presenting.
fn commitGpu(self: *DrmOutput, frame: *gpu_frame.GpuFrame) error{CommitFailed}!void {
    const slots = self.gpu_slots orelse return error.CommitFailed;
    if (!gpuFrameValid(self, frame)) return error.CommitFailed;
    const slot = &slots[frame.slot];

    // Legacy interface (no atomic): drmModePageFlip names the CRTC and
    // the new framebuffer (wlroots legacy.c:206-209). Same asynchronous
    // contract, same completion event, and it works for a GEM framebuffer
    // with a modifier - which is what "legacy KMS is allowed here when
    // the flip actually works" means.
    if (!self.backend.atomic) {
        const cookie = armFlip(self) orelse return error.CommitFailed;
        if (c.drmModePageFlip(
            self.backend.fd.?,
            self.crtc_id,
            slot.fb_id,
            c.DRM_MODE_PAGE_FLIP_EVENT,
            cookiePointer(cookie),
        ) != 0) {
            disarmFlip(self);
            log_mod.err("drm: drmModePageFlip failed (gpu slot)", self.backend.io, self.backend.log_cfg, "drm", .{});
            return error.CommitFailed;
        }
        slot.state = .pending;
        return;
    }

    const fd = self.backend.fd.?;
    const req = c.drmModeAtomicAlloc() orelse return error.CommitFailed;
    defer c.drmModeAtomicFree(req);
    // Only FB_ID changes: the mode, the source and destination rects and
    // the framebuffer's modifier were all fixed at the modeset, and the
    // slot's framebuffer is the one the plane has already proven it can
    // scan out.
    if (c.drmModeAtomicAddProperty(req, self.plane_id, self.props.fb_id, slot.fb_id) < 0) {
        log_mod.err("drm: atomic add FB_ID failed (gpu slot)", self.backend.io, self.backend.log_cfg, "drm", .{});
        return error.CommitFailed;
    }
    const cookie = armFlip(self) orelse return error.CommitFailed;
    if (c.drmModeAtomicCommit(
        fd,
        req,
        c.DRM_MODE_PAGE_FLIP_EVENT | c.DRM_MODE_ATOMIC_NONBLOCK,
        cookiePointer(cookie),
    ) != 0) {
        disarmFlip(self);
        log_mod.err("drm: gpu page flip commit failed", self.backend.io, self.backend.log_cfg, "drm", .{});
        return error.CommitFailed;
    }
    slot.state = .pending;
}

/// Output.destroy() runs this and then frees the wrapper, so it is the
/// last chance to break every reference to it. A page-flip completion
/// queued before this can still arrive afterwards; it must not fire a
/// presented or frame event on freed compositor state, and it must not
/// promote a ring slot for an output nobody can see any more.
///
/// The flip epoch moves here for exactly that reason, and the KMS
/// resources are released by the caller (removeDisconnectedOutputs or
/// drmTeardown). The struct itself is freed right after the Output
/// wrapper is gone: nothing the kernel holds points at it, because a
/// queued flip is named by an integer cookie, not by this address.
fn destroyOutput(_: std.mem.Allocator, data: *anyopaque) void {
    const drm_out: *DrmOutput = @ptrCast(@alignCast(data));
    drm_out.out = null;
    invalidateFlipIdentity(drm_out);
}

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
/// i) within [0, count) that no live output already holds — the
/// encoder-fallback CRTC pick: the union mask comes from
/// drmModeConnectorGetPossibleCrtcs, and the lowest set bit is the first
/// CRTC a sibling encoder can drive (wlroots realloc_crtcs matches
/// connectors against every CRTC in possible_crtcs; we take the first
/// such CRTC, kernels expose <= 32). Null when the mask allows no free
/// CRTC in range, which is how a second connector on a single-CRTC
/// device is declined instead of being handed the CRTC already in use.
///
/// `claimed` is the list of CRTC ids live outputs hold. It is passed in
/// rather than read from the backend so the allocation rule is testable
/// on its own; the caller passes the backend's own list.
fn firstCrtcIndex(possible_crtcs: u32, count: usize, claimed: []const usize) ?usize {
    var i: usize = 0;
    while (i < count and i < 32) : (i += 1) {
        if (possible_crtcs & (@as(u32, 1) << @as(u5, @intCast(i))) == 0) continue;
        if (idClaimed(claimed, i)) continue;
        return i;
    }
    return null;
}

/// Is `index` one of the claimed slots? The claims are indexes into the
/// CRTC id array, which is what possible_crtcs bits address.
fn idClaimed(claimed: []const usize, index: usize) bool {
    for (claimed) |taken| {
        if (taken == index) return true;
    }
    return false;
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
        // <= 32 CRTCs; wlroots asserts the same bound). "Free" means no
        // output this backend already drives holds it: two outputs bound
        // to one CRTC fight over the same hardware, and the second
        // modeset would silently take the screen from the first.
        var claims_storage: [32]usize = undefined;
        const claimed = claimedCrtcs(self, res.*.crtcs[0..@intCast(res.*.count_crtcs)], &claims_storage);
        const crtc_index = firstCrtcIndex(possible_crtcs, @intCast(res.*.count_crtcs), claimed) orelse continue;
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
/// scanout format; properties.c plane_info table names the ids).
///
/// Two constraints beyond wlroots' single-output case, both about two
/// outputs living on one device:
///  - a plane already driven by another live output is skipped, so the
///    two never fight over one plane's framebuffer (one atomic commit
///    would unbind the other's scanout);
///  - in GPU mode the plane must scan out a format this backend could
///    actually negotiate, which is not necessarily XRGB8888: the
///    renderer's pairs decide. On the CPU paths XRGB8888 stays the
///    requirement, exactly as before.
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
        if (planeDrivenByOutput(self, plane_id)) continue;
        const plane = c.drmModeGetPlane(fd, plane_id) orelse continue;
        defer c.drmModeFreePlane(plane);
        if (plane.*.possible_crtcs & crtc_bit == 0) continue;

        // Classify first, then check the format: "type" is read as a
        // value, never committed (plane_prop_names has no "type" slot),
        // and only a primary plane may carry the scanout framebuffer.
        var props: PlanePropIds = .{};
        if (!scanPlaneProps(fd, plane_id, &props)) continue;
        const type_value = getPropValue(fd, plane_id, c.DRM_MODE_OBJECT_PLANE, props.plane_type) orelse continue;
        if (type_value != c.DRM_PLANE_TYPE_PRIMARY) continue;

        // The plane must scan out something this backend can put on it
        // (wlroots drm.c init_plane collects drm_plane->formats into the
        // plane's format set, drm.c:169-186, and drm_fb_import refuses
        // buffers whose format is absent from it, fb.c:144-169).
        const wanted: []const dmabuf.Format = if (gpuModeSelected(self)) self.gpu_render_pairs.? else &cpu_scanout_formats;
        if (!planeScannable(plane.*, wanted)) {
            log_mod.debug(
                "drm: plane {d} scans out none of the wanted formats; skipping",
                self.io,
                self.log_cfg,
                "drm",
                .{plane_id},
            );
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

/// The formats the CPU paths need a plane to scan out: XRGB8888 alone.
/// Declared as a pair list so one matcher serves both paths; the modifier
/// is irrelevant to a dumb buffer, so it is LINEAR.
const cpu_scanout_formats = [_]dmabuf.Format{
    .{ .format = drm_format_xrgb8888, .modifier = dmabuf.drm_format_mod_linear },
};

/// Does this plane list any of the wanted fourccs? The modifier half of
/// the pairs is not consulted: drmModeGetPlane reports the plane's
/// format list without modifiers, and the modifiers come from the
/// IN_FORMATS blob `planeScanoutFormats` reads separately.
fn planeScannable(plane: c.drmModePlane, wanted: []const dmabuf.Format) bool {
    for (wanted) |pair| {
        var i: u32 = 0;
        while (i < plane.count_formats) : (i += 1) {
            if (plane.formats[i] == pair.format) return true;
        }
    }
    return false;
}

/// Is this plane already committed by one of our live outputs? Two
/// outputs sharing a plane would each modeset away the other's scanout:
/// the second commit's FB_ID simply replaces the first.
fn planeDrivenByOutput(self: *DrmBackendData, plane_id: u32) bool {
    for (self.outputs.items) |drm_out| {
        if (drm_out.gpu_plane_id == plane_id) return true;
        if (drm_out.plane_id == plane_id) return true;
    }
    return false;
}

/// The positions in `crtcs` that live outputs already hold, using bounded
/// caller storage. `possible_crtcs` bits address the CRTC array by position, so
/// the claim is recorded as a position; within one drmModeGetResources
/// answer the same position always names the same CRTC, and every
/// enumeration re-derives the list from the outputs we hold.
fn claimedCrtcs(self: *DrmBackendData, crtcs: []const c_uint, storage: *[32]usize) []const usize {
    var count: usize = 0;
    for (crtcs[0..@min(crtcs.len, storage.len)], 0..) |id, index| {
        for (self.outputs.items) |drm_out| {
            if (id != drm_out.crtc_id) continue;
            storage[count] = index;
            count += 1;
            break;
        }
    }
    return storage[0..count];
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
    // The GPU ring first: its descriptors and buffer objects are what a
    // renderer import is still pointing at, and this output's Output has
    // already been destroyed by the time this runs, so the server has
    // released its GL targets.
    releaseGpuSlots(self, drm_out);
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
/// compositor uses to retire the wl_output, and `destroyOutput` clears
/// this output's flip identity - then the KMS resources. The struct is
/// freed right after: a page flip we queued before the unplug is named by
/// an integer cookie, not by this address, so a completion still sitting in
/// the kernel queue resolves to "no output waiting for that cookie" and
/// changes nothing. The list entry is removed before the free, because
/// orderedRemove shifts the tail down and the index has to stay valid for
/// the loop.
///
/// A replugged connector gets a brand new DrmOutput whose every slot
/// carries a fresh generation, and every flip it queues gets a fresh
/// cookie, so no frame, lease, framebuffer id or queued flip from before
/// the unplug can ever be mistaken for the new output's.
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
        _ = self.outputs.orderedRemove(i);
        self.allocator.destroy(drm_out);
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
///
/// The kernel gives us back one thing: the cookie we queued with, as an
/// integer this module never dereferences. A completion that resolves to
/// no output - because the output is gone, because a resume or a teardown
/// moved it to another epoch, or because it has queued a newer flip since
/// - is dropped without touching the ring or the compositor. It must not
/// present, and it must not promote a ring slot: either would report a
/// frame the compositor never committed and hand the next writer a buffer
/// the kernel is still scanning out.
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
    // Only reachable from inside one drmHandleEvent, which is what scopes
    // the backend. Nothing here is reachable between drains.
    const self = draining orelse return;
    const drm_out = outputPendingCookie(self, cookieOf(user_data)) orelse return;
    // The kernel names the CRTC that finished; the record names the one the
    // flip was queued on. They can only disagree if something queued a
    // flip under another CRTC's cookie, which nothing does.
    if (crtc_id != drm_out.pending.?.crtc_id) return;
    drm_out.pending = null;
    // The pending slot becomes the front buffer, and only then does the
    // one it replaced become free (GpuRing.flipCompleted). Both slots are
    // written back: the old front turns free inside that call, and a
    // partial write-back would leave the output with no writable buffer
    // for ever.
    if (drm_out.gpu_slots) |slots| {
        var states: [2]SlotState = .{ slots[0].state, slots[1].state };
        var i: usize = 0;
        while (i < states.len) : (i += 1) {
            if (states[i] != .pending) continue;
            GpuRing.flipCompleted(&states, @intCast(i));
            slots[0].state = states[0];
            slots[1].state = states[1];
            break;
        }
    }
    const out = drm_out.out orelse return;
    // The kernel's tv is the vblank time (CLOCK_MONOTONIC-family:
    // seconds + microseconds since boot).
    const when_ns: u64 = @as(u64, tv_sec) * std.time.ns_per_s +
        @as(u64, tv_usec) * std.time.ns_per_us;
    out.firePresented(out.commit_seq, drm_present_flags, drm_out.refresh_ns, when_ns);
    out.sendFrame();
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

test "encoder fallback picks the first FREE CRTC in the possible_crtcs union" {
    // F24: a connector's CRTC set is the union over ALL its encoders
    // (drmModeConnectorGetPossibleCrtcs); the lowest set bit wins.
    // Single-encoder mask: bit 0 -> CRTC 0.
    try testing.expectEqual(@as(?usize, 0), firstCrtcIndex(0b1, 4, &.{}));
    // Union of two encoders' masks (bits 0 and 2): first is CRTC 0.
    try testing.expectEqual(@as(?usize, 0), firstCrtcIndex(0b101, 4, &.{}));
    // Only the sibling encoder drives CRTC 2 (the connector's own
    // encoder reported 0): fallback must still find it.
    try testing.expectEqual(@as(?usize, 2), firstCrtcIndex(0b100, 4, &.{}));
    // Bit 3 is within a 4-CRTC device: index 3 is valid.
    try testing.expectEqual(@as(?usize, 3), firstCrtcIndex(0b1000, 4, &.{}));
    // Mask allows CRTCs past the resources' count: out of range -> null.
    try testing.expectEqual(@as(?usize, null), firstCrtcIndex(0b10000, 4, &.{}));
    // No CRTC reachable at all.
    try testing.expectEqual(@as(?usize, null), firstCrtcIndex(0, 4, &.{}));
    // Zero resources -> null even with a full mask.
    try testing.expectEqual(@as(?usize, null), firstCrtcIndex(0xFFFFFFFF, 0, &.{}));

    // The second output on a two-CRTC connector: CRTC 0 already drives
    // an output, so it must be skipped rather than modeset away the
    // first output's scanout.
    try testing.expectEqual(@as(?usize, 1), firstCrtcIndex(0b11, 2, &.{0}));
    // A claim on the SECOND CRTC leaves the first free: the rule is the
    // lowest free CRTC the union allows, not a preference order, so the
    // answer is the same whichever one the first output took.
    try testing.expectEqual(@as(?usize, 0), firstCrtcIndex(0b11, 2, &.{1}));
    // Both taken: this connector cannot be driven, and the caller is
    // told so instead of getting hardware already in use.
    try testing.expectEqual(@as(?usize, null), firstCrtcIndex(0b11, 2, &.{ 0, 1 }));
    // A single-CRTC device with that CRTC in use: nothing left.
    try testing.expectEqual(@as(?usize, null), firstCrtcIndex(0b1, 1, &.{0}));
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

test "the GPU ring presents one slot at a time and frees the old front last" {
    // After the modeset: slot 0 is on screen, slot 1 is free.
    var states = [2]SlotState{ .front, .free };
    try testing.expectEqual(@as(?u2, 1), GpuRing.firstFree(&states));

    // Leased and committed: one writer, one queued flip, and the front
    // buffer is still the one being scanned out.
    states[1] = .writing;
    states[1] = .pending;
    try testing.expectEqual(@as(?u2, null), GpuRing.firstFree(&states));

    // The flip completes: the pending slot becomes the front, and only
    // then does the slot it replaced become free. Before the completion
    // there was nothing to lease; after it there is exactly one.
    GpuRing.flipCompleted(&states, 1);
    try testing.expectEqual(SlotState.front, states[1]);
    try testing.expectEqual(SlotState.free, states[0]);
    try testing.expectEqual(@as(?u2, 0), GpuRing.firstFree(&states));

    // A completion that names a slot which is not pending changes
    // nothing: a stale or duplicated completion must not free the buffer
    // on screen, which would let the next writer scribble into it.
    states[0] = .writing;
    GpuRing.flipCompleted(&states, 0);
    try testing.expectEqual(SlotState.writing, states[0]);
    try testing.expectEqual(SlotState.front, states[1]);
    try testing.expectEqual(@as(?u2, null), GpuRing.firstFree(&states));
}

/// A DrmOutput with a GPU ring, built without a device and REGISTERED with
/// the backend, exactly as allocOutput registers a real one: the lease
/// rules and the flip-identity rules are pure state and must hold without
/// a card, and a completion resolves its cookie through the backend's
/// output list either way.
///
/// The caller owns the returned struct and must `deinit` the backend's
/// output list.
fn fakeGpuOutput(backend: *DrmBackendData, slots: *[2]GpuSlot) !*DrmOutput {
    const drm_out = try backend.allocator.create(DrmOutput);
    errdefer backend.allocator.destroy(drm_out);
    drm_out.* = .{
        .backend = backend,
        .crtc_id = 1,
        .plane_id = 2,
        .props = .{},
        .gpu_plane_id = 2,
        .mode = .{ .width = 64, .height = 64, .refresh_msec = 16 },
        .gpu_slots = slots,
    };
    var i: usize = 0;
    while (i < slots.len) : (i += 1) {
        slots[i].fb_id = @intCast(10 + i);
        slots[i].generation = @intCast(100 + i);
        slots[i].frame.fb_id = slots[i].fb_id;
        slots[i].frame.owner = drm_out;
        slots[i].frame.slot = @intCast(i);
        slots[i].frame.generation = slots[i].generation;
        slots[i].frame.attributes = .{
            .width = 64,
            .height = 64,
            .format = drm_format_xrgb8888,
            .modifier = dmabuf.drm_format_mod_linear,
        };
    }
    try backend.outputs.append(backend.allocator, drm_out);
    return drm_out;
}

/// Counts the signals a flip completion fires into the compositor. Those
/// are the consumer-visible effects a stale completion must never have:
/// a presented event reports a frame that was never displayed, and a
/// frame event asks the renderer to start a new one.
const FlipSignals = struct {
    frames: usize = 0,
    presents: usize = 0,
    frame_listener: wire.Listener(*output_mod.Output),
    present_listener: wire.Listener(*output_mod.Output.PresentEvent),

    fn onFrame(listener: *wire.Listener(*output_mod.Output), _: *output_mod.Output) void {
        @as(*FlipSignals, @fieldParentPtr("frame_listener", listener)).frames += 1;
    }

    fn onPresented(
        listener: *wire.Listener(*output_mod.Output.PresentEvent),
        _: *output_mod.Output.PresentEvent,
    ) void {
        @as(*FlipSignals, @fieldParentPtr("present_listener", listener)).presents += 1;
    }

    fn init() FlipSignals {
        return .{
            .frame_listener = wire.Listener(*output_mod.Output).init(FlipSignals.onFrame),
            .present_listener = wire.Listener(*output_mod.Output.PresentEvent).init(FlipSignals.onPresented),
        };
    }

    /// Count everything this output reports from now on.
    fn watch(self: *FlipSignals, out: *output_mod.Output) void {
        out.events.frame.add(&self.frame_listener);
        out.events.presented.add(&self.present_listener);
    }
};

/// Deliver a completion the way the kernel does: inside a drain's scope,
/// exactly as drmHandleEvent invokes the handler. A completion outside a
/// drain is not reachable in production, and this keeps the tests honest
/// about that instead of setting up state the driver could never have.
fn deliverFlip(backend: *DrmBackendData, cookie: usize, crtc_id: u32, tv_sec: c_uint) void {
    draining = backend;
    defer draining = null;
    pageFlipHandler(123, 42, tv_sec, 0, crtc_id, cookiePointer(cookie));
}

fn fakeGpuBackend(
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
) DrmBackendData {
    return .{
        .allocator = allocator,
        .io = io,
        .log_cfg = log_cfg,
        .device_path = "/dev/dri/card0",
        .gpu_render_pairs = &.{.{ .format = drm_format_xrgb8888, .modifier = 0 }},
    };
}

/// One live GPU output with its ring, its Output wrapper and its signal
/// counters: the state every flip-completion rule is about. Built without
/// a card, because the lease rules and the flip-identity rules are pure
/// state; `fd` is a placeholder because the lease entry points check only
/// that it is there.
const FlipFixture = struct {
    backend: DrmBackendData,
    base: *backend_mod.Backend,
    out: *output_mod.Output,
    drm_out: *DrmOutput,
    slots: [2]GpuSlot,
    signals: FlipSignals,
    /// False once unplug() has freed `drm_out`.
    owns: bool,

    fn init(
        self: *FlipFixture,
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
    ) !void {
        self.backend = fakeGpuBackend(allocator, io, log_cfg);
        self.backend.fd = 123;
        self.slots = .{ .{}, .{} };
        self.signals = .init();
        self.base = try backend_mod.Backend.init(allocator, io, log_cfg, &backend_impl, &self.backend);
        errdefer allocator.destroy(self.base);
        self.drm_out = try fakeGpuOutput(&self.backend, &self.slots);
        errdefer allocator.destroy(self.drm_out);
        self.out = try output_mod.Output.create(allocator, io, log_cfg, self.base, &output_impl, self.drm_out, self.drm_out.mode);
        self.drm_out.out = self.out;
        self.owns = true;
    }

    fn deinit(self: *FlipFixture) void {
        const allocator = self.backend.allocator;
        if (self.owns) {
            self.out.destroy();
            allocator.destroy(self.drm_out);
        }
        self.backend.outputs.deinit(allocator);
        allocator.destroy(self.base);
    }

    /// Start counting what this output reports. sendFrame only emits on an
    /// enabled output (wlroots output.c:833-837), so enable it the way the
    /// compositor does.
    fn enable(self: *FlipFixture) void {
        self.out.enabled = true;
        self.signals.watch(self.out);
    }

    /// Queue a flip to the free slot the way commitGpu does once the kernel
    /// has accepted it: a cookie is armed and the slot is pending until its
    /// completion.
    fn queueFlip(self: *FlipFixture) !usize {
        const index = GpuRing.firstFree(&.{ self.slots[0].state, self.slots[1].state }) orelse
            return error.TestUnexpectedResult;
        const cookie = armFlip(self.drm_out) orelse return error.TestUnexpectedResult;
        self.slots[index].state = .pending;
        return cookie;
    }

    /// The kernel delivers the completion for this cookie.
    fn complete(self: *FlipFixture, cookie: usize) void {
        deliverFlip(&self.backend, cookie, self.drm_out.crtc_id, 1);
    }

    /// Take the output apart the way the unplug path does: the Output
    /// wrapper dies (which drops the flip identity), the KMS resources are
    /// released, and the struct leaves the backend's list and is freed.
    /// The kernel still holds whatever cookie it was given.
    fn unplug(self: *FlipFixture) void {
        const allocator = self.backend.allocator;
        self.out.destroy();
        self.drm_out.gpu_slots = null;
        for (self.backend.outputs.items, 0..) |entry, i| {
            if (entry != self.drm_out) continue;
            _ = self.backend.outputs.orderedRemove(i);
            break;
        }
        allocator.destroy(self.drm_out);
        self.owns = false;
    }
};

test "a completed GPU page flip frees the old front and fires one frame" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    var fixture: FlipFixture = undefined;
    try fixture.init(testing.allocator, &io, &log_cfg);
    defer fixture.deinit();
    fixture.enable();
    fixture.slots[0].state = .front;

    const cookie = try fixture.queueFlip();
    try testing.expect(fixture.drm_out.pending != null);

    fixture.complete(cookie);
    try testing.expect(fixture.drm_out.pending == null);
    // BOTH slots move: the completed one is scanned out, and the one it
    // replaced is free again. A partial write-back would leave the output
    // with nothing the renderer may draw into.
    try testing.expectEqual(SlotState.front, fixture.slots[1].state);
    try testing.expectEqual(SlotState.free, fixture.slots[0].state);
    try testing.expectEqual(@as(usize, 1), fixture.signals.presents);
    try testing.expectEqual(@as(usize, 1), fixture.signals.frames);

    // Exactly one slot is leasable, and it is not the one on screen. While
    // the next flip is in flight there is nothing left to lease at all.
    const frame = DrmBackend.acquireGpuFrame(fixture.base, fixture.out) orelse
        return error.TestUnexpectedResult;
    try testing.expect(frame == &fixture.slots[0].frame);
    DrmBackend.cancelGpuFrame(fixture.base, fixture.out, frame);
    _ = try fixture.queueFlip();
    try testing.expect(DrmBackend.acquireGpuFrame(fixture.base, fixture.out) == null);
}

test "a completion that names a destroyed output touches nothing" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    var fixture: FlipFixture = undefined;
    try fixture.init(testing.allocator, &io, &log_cfg);
    defer fixture.deinit();
    fixture.enable();
    fixture.slots[0].state = .front;
    const dead_crtc: u32 = fixture.drm_out.crtc_id;
    const cookie = try fixture.queueFlip();

    // A second output on another CRTC, live throughout, which a completion
    // for the dead one must not touch.
    var live_slots: [2]GpuSlot = .{ .{}, .{} };
    const live = try fakeGpuOutput(&fixture.backend, &live_slots);
    defer testing.allocator.destroy(live);
    live.crtc_id = 2;
    const live_out = try output_mod.Output.create(testing.allocator, &io, &log_cfg, fixture.base, &output_impl, live, live.mode);
    defer live_out.destroy();
    live.out = live_out;
    live_out.enabled = true;
    var signals: FlipSignals = .init();
    signals.watch(live_out);
    live_slots[0].state = .front;

    fixture.unplug();

    // The completion arrives after the struct is gone. Its cookie resolves
    // to no output: no dereference of freed state, and no signal fired on a
    // wrapper that is gone or on the survivor.
    deliverFlip(&fixture.backend, cookie, dead_crtc, 1);
    try testing.expectEqual(@as(usize, 0), signals.presents);
    try testing.expectEqual(@as(usize, 0), signals.frames);
    try testing.expectEqual(SlotState.front, live_slots[0].state);
    try testing.expect(live_slots[1].state != .front);
    try testing.expect(live.pending == null);
}

test "a completion from before a resume presents nothing and leaves the ring alone" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    var fixture: FlipFixture = undefined;
    try fixture.init(testing.allocator, &io, &log_cfg);
    defer fixture.deinit();
    fixture.enable();
    fixture.slots[0].state = .front;
    const stale = try fixture.queueFlip();

    // Suspend and resume. The drains and the re-modeset are ioctl work; the
    // epoch move and the ring re-derivation are the state they exist for,
    // and they are what makes the old cookie unmatchable.
    invalidateFlipIdentity(fixture.drm_out);
    adoptModesetFront(fixture.drm_out, true);
    try testing.expect(fixture.drm_out.pending == null);
    try testing.expectEqual(SlotState.front, fixture.slots[0].state);
    try testing.expectEqual(SlotState.free, fixture.slots[1].state);

    // The compositor repaints and the post-resume flip is queued.
    const fresh = try fixture.queueFlip();

    // The pre-suspend completion finally arrives. It presents nothing,
    // promotes nothing, and does not release the flip now in flight.
    fixture.complete(stale);
    try testing.expectEqual(SlotState.front, fixture.slots[0].state);
    try testing.expectEqual(SlotState.pending, fixture.slots[1].state);
    try testing.expect(fixture.drm_out.pending != null);
    try testing.expectEqual(@as(usize, 0), fixture.signals.presents);
    try testing.expectEqual(@as(usize, 0), fixture.signals.frames);

    // The post-resume flip completes normally and paces the next frame.
    fixture.complete(fresh);
    try testing.expect(fixture.drm_out.pending == null);
    try testing.expectEqual(SlotState.front, fixture.slots[1].state);
    try testing.expectEqual(SlotState.free, fixture.slots[0].state);
    try testing.expectEqual(@as(usize, 1), fixture.signals.presents);
    try testing.expectEqual(@as(usize, 1), fixture.signals.frames);
}

test "a completion that arrives long after the resume changes nothing" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    var fixture: FlipFixture = undefined;
    try fixture.init(testing.allocator, &io, &log_cfg);
    defer fixture.deinit();
    fixture.enable();
    fixture.slots[0].state = .front;
    const ancient = try fixture.queueFlip();

    // Two suspend/resume cycles, then two post-resume flips that are
    // delivered and presented normally. The old cookie is now several
    // commits and several drains old.
    invalidateFlipIdentity(fixture.drm_out);
    adoptModesetFront(fixture.drm_out, true);
    invalidateFlipIdentity(fixture.drm_out);
    adoptModesetFront(fixture.drm_out, true);
    const first = try fixture.queueFlip();
    fixture.complete(first);
    const second = try fixture.queueFlip();
    fixture.complete(second);
    try testing.expectEqual(@as(usize, 2), fixture.signals.presents);
    try testing.expectEqual(SlotState.front, fixture.slots[0].state);
    try testing.expectEqual(SlotState.free, fixture.slots[1].state);

    // The renderer holds the free buffer when the ancient completion lands.
    const frame = DrmBackend.acquireGpuFrame(fixture.base, fixture.out) orelse
        return error.TestUnexpectedResult;
    try testing.expect(frame == &fixture.slots[1].frame);

    fixture.complete(ancient);
    // No present, no frame, no promotion - and the writer keeps its lease,
    // because the completion cannot reach a slot or a compositor signal.
    try testing.expectEqual(@as(usize, 2), fixture.signals.presents);
    try testing.expectEqual(@as(usize, 2), fixture.signals.frames);
    try testing.expectEqual(SlotState.front, fixture.slots[0].state);
    try testing.expectEqual(SlotState.writing, fixture.slots[1].state);
    try testing.expect(gpuFrameValid(fixture.drm_out, frame));

    // Still inert on a second delivery, and the writer can hand its buffer
    // in afterwards exactly as if nothing had arrived.
    fixture.complete(ancient);
    try testing.expectEqual(@as(usize, 2), fixture.signals.presents);
    try testing.expectEqual(SlotState.writing, fixture.slots[1].state);
    try testing.expect(fixture.drm_out.pending == null);
    DrmBackend.cancelGpuFrame(fixture.base, fixture.out, frame);
}

test "repeated invalidation cannot resurrect an earlier identity" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    var fixture: FlipFixture = undefined;
    try fixture.init(testing.allocator, &io, &log_cfg);
    defer fixture.deinit();
    fixture.enable();
    fixture.slots[0].state = .front;

    const before: u64 = fixture.drm_out.epoch;
    const first = try fixture.queueFlip();

    // Two suspend/resume cycles, neither of which drains the fd's event
    // queue: the epoch moves every time and never comes back.
    invalidateFlipIdentity(fixture.drm_out);
    invalidateFlipIdentity(fixture.drm_out);
    try testing.expect(fixture.drm_out.epoch > before);
    try testing.expect(fixture.drm_out.pending == null);
    adoptModesetFront(fixture.drm_out, true);

    // The next flip carries a cookie that was never issued before, so no
    // earlier completion can match it by any route.
    const fresh = try fixture.queueFlip();
    try testing.expect(fresh != first);

    // The completion from before both resumes arrives now: inert, and it
    // leaves the flip that IS in flight alone.
    fixture.complete(first);
    try testing.expectEqual(SlotState.front, fixture.slots[0].state);
    try testing.expectEqual(SlotState.pending, fixture.slots[1].state);
    try testing.expect(fixture.drm_out.pending != null);
    try testing.expectEqual(@as(usize, 0), fixture.signals.presents);
    try testing.expectEqual(@as(usize, 0), fixture.signals.frames);

    fixture.complete(fresh);
    try testing.expectEqual(@as(usize, 1), fixture.signals.presents);
}

test "a refused flip leaves the output waiting for nothing" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    var fixture: FlipFixture = undefined;
    try fixture.init(testing.allocator, &io, &log_cfg);
    defer fixture.deinit();
    fixture.enable();
    fixture.slots[0].state = .front;

    // The kernel refused the request (EBUSY, EINVAL): the commit paths
    // disarm, the slot stays the writer's, and no completion will name that
    // cookie. Were one to arrive anyway it would still be inert.
    const refused = armFlip(fixture.drm_out) orelse return error.TestUnexpectedResult;
    try testing.expect(fixture.drm_out.pending != null);
    disarmFlip(fixture.drm_out);
    try testing.expect(fixture.drm_out.pending == null);
    fixture.complete(refused);
    try testing.expectEqual(@as(usize, 0), fixture.signals.presents);
    try testing.expectEqual(@as(usize, 0), fixture.signals.frames);
    try testing.expectEqual(SlotState.front, fixture.slots[0].state);
    try testing.expectEqual(SlotState.free, fixture.slots[1].state);

    // Pacing is not stuck: the next commit arms a different cookie and the
    // output presents normally.
    const fresh = try fixture.queueFlip();
    try testing.expect(fresh != refused);
    fixture.complete(fresh);
    try testing.expectEqual(@as(usize, 1), fixture.signals.presents);
    try testing.expectEqual(SlotState.front, fixture.slots[1].state);
    try testing.expectEqual(SlotState.free, fixture.slots[0].state);
}

test "a GPU frame is only valid while its own output holds its writing lease" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    var backend = fakeGpuBackend(testing.allocator, &io, &log_cfg);
    var slots: [2]GpuSlot = .{ .{}, .{} };
    const drm_out = try fakeGpuOutput(&backend, &slots);
    defer backend.outputs.deinit(testing.allocator);
    defer testing.allocator.destroy(drm_out);

    // Nothing is leased, so no frame is committable.
    try testing.expect(!gpuFrameValid(drm_out, &slots[0].frame));
    try testing.expect(!gpuFrameValid(drm_out, &slots[1].frame));

    // A writing lease of this output is valid.
    slots[1].state = .writing;
    try testing.expect(gpuFrameValid(drm_out, &slots[1].frame));

    // After the commit the slot is pending: the SAME frame must not be
    // committable a second time, or the output would queue two flips to
    // one buffer while the renderer believes it owns it.
    slots[1].state = .pending;
    try testing.expect(!gpuFrameValid(drm_out, &slots[1].frame));
    // Nor is the slot on screen.
    slots[0].state = .front;
    try testing.expect(!gpuFrameValid(drm_out, &slots[0].frame));
}

test "a GPU frame from another output or a stale generation is rejected" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    var backend = fakeGpuBackend(testing.allocator, &io, &log_cfg);
    var first_slots: [2]GpuSlot = .{ .{}, .{} };
    var second_slots: [2]GpuSlot = .{ .{}, .{} };
    const first = try fakeGpuOutput(&backend, &first_slots);
    const second = try fakeGpuOutput(&backend, &second_slots);
    defer backend.outputs.deinit(testing.allocator);
    defer testing.allocator.destroy(first);
    defer testing.allocator.destroy(second);

    first_slots[1].state = .writing;
    second_slots[1].state = .writing;
    try testing.expect(gpuFrameValid(first, &first_slots[1].frame));
    try testing.expect(gpuFrameValid(second, &second_slots[1].frame));
    // Each output's own lease is the only one it accepts: the frame
    // pointer, the owner and the slot index all have to agree.
    try testing.expect(!gpuFrameValid(first, &second_slots[1].frame));
    try testing.expect(!gpuFrameValid(second, &first_slots[1].frame));
    try testing.expect(!gpuFrameValid(first, &first_slots[0].frame));

    // A frame whose generation no longer matches its slot is a stale
    // lease - from before a teardown, or from a slot the backend has
    // since reallocated.
    first_slots[1].frame.generation += 1;
    try testing.expect(!gpuFrameValid(first, &first_slots[1].frame));
    first_slots[1].frame.generation = first_slots[1].generation;
    try testing.expect(gpuFrameValid(first, &first_slots[1].frame));

    // A slot index the ring does not have cannot be committed even by
    // the owning output.
    first_slots[1].frame.slot = 3;
    try testing.expect(!gpuFrameValid(first, &first_slots[1].frame));
}

/// A GBM probe stand-in: accepts only the pairs in `list`. The real one
/// asks `gbm_device_get_format_modifier_plane_count`; this is the same
/// question with a table for an answer, which is what makes the
/// negotiation testable on a machine with no card.
const PairProbe = struct {
    list: []const dmabuf.Format,
    fn probe(ctx: *anyopaque, format: u32, modifier: u64) bool {
        const self: *PairProbe = @ptrCast(@alignCast(ctx));
        return dmabuf.supports(self.list, format, modifier);
    }
};

test "GPU format negotiation intersects plane, renderer and GBM" {
    const plane_pairs = [_]dmabuf.Format{
        .{ .format = drm_format_xrgb8888, .modifier = dmabuf.drm_format_mod_linear },
        .{ .format = dmabuf.drm_format_argb8888, .modifier = 0x0100_0000_0000_0002 },
    };
    const render_pairs = [_]dmabuf.Format{
        // The renderer's first choice is a modifier no plane reports:
        // it must be skipped, not silently downgraded to LINEAR.
        .{ .format = drm_format_xrgb8888, .modifier = 0x0100_0000_0000_0002 },
        .{ .format = dmabuf.drm_format_argb8888, .modifier = 0x0100_0000_0000_0002 },
    };
    // GBM can allocate both of the plane's pairs. The pick is the first
    // pair all THREE sets have: the renderer's unmatched first choice is
    // skipped, not downgraded to a modifier the renderer never claimed -
    // substituting LINEAR here is exactly the failure this negotiation
    // exists to prevent.
    var gbm: PairProbe = .{ .list = &plane_pairs };
    const chosen = chooseGpuFormat(&plane_pairs, &render_pairs, &gbm, PairProbe.probe) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(dmabuf.drm_format_argb8888, chosen.format);
    try testing.expectEqual(@as(u64, 0x0100_0000_0000_0002), chosen.modifier);
    // Whatever it picks is in all three sets - nothing is invented.
    try testing.expect(dmabuf.supports(&render_pairs, chosen.format, chosen.modifier));
    try testing.expect(dmabuf.supports(&plane_pairs, chosen.format, chosen.modifier));
    try testing.expect(PairProbe.probe(&gbm, chosen.format, chosen.modifier));

    // The renderer's own order is preserved when the plane agrees with
    // more than one of its pairs.
    const render_xrgb_first = [_]dmabuf.Format{
        .{ .format = drm_format_xrgb8888, .modifier = dmabuf.drm_format_mod_linear },
        .{ .format = dmabuf.drm_format_argb8888, .modifier = 0x0100_0000_0000_0002 },
    };
    const first_choice = chooseGpuFormat(&plane_pairs, &render_xrgb_first, &gbm, PairProbe.probe).?;
    try testing.expectEqual(drm_format_xrgb8888, first_choice.format);

    // GBM refusing everything leaves no choice - an explicit capability
    // failure, never a guessed LINEAR.
    var none: PairProbe = .{ .list = &.{} };
    try testing.expect(chooseGpuFormat(&plane_pairs, &render_xrgb_first, &none, PairProbe.probe) == null);

    // A plane that scans out nothing the renderer can produce: also no
    // choice.
    const unrelated_plane = [_]dmabuf.Format{
        .{ .format = dmabuf.drm_format_xrgb2101010, .modifier = dmabuf.drm_format_mod_linear },
    };
    try testing.expect(chooseGpuFormat(&unrelated_plane, &render_xrgb_first, &gbm, PairProbe.probe) == null);
    // An empty renderer set is the same answer.
    try testing.expect(chooseGpuFormat(&plane_pairs, &.{}, &gbm, PairProbe.probe) == null);
}

test "IN_FORMATS parsing yields the plane's real (format, modifier) pairs" {
    // Build the blob a driver writes: header, two fourccs, one
    // drm_format_modifier per modifier, each with a formats bitmask and
    // the offset of its first format.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(testing.allocator);
    const header = [_]u32{ 1, 0, 2, 24, 2, 32 };
    for (header) |word| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, word, .little);
        blob.appendSlice(testing.allocator, &buf) catch @panic("test alloc");
    }
    // formats: XRGB8888 then ARGB8888.
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, drm_format_xrgb8888, .little);
    blob.appendSlice(testing.allocator, &word) catch @panic("test alloc");
    std.mem.writeInt(u32, &word, dmabuf.drm_format_argb8888, .little);
    blob.appendSlice(testing.allocator, &word) catch @panic("test alloc");
    // Two modifiers, 24 bytes each: (formats bitmask, offset, pad,
    // modifier). First covers format 0 with LINEAR, second covers
    // format 1 with a tiled modifier.
    for ([_]u64{ 0b01, 0b01 }, 0..) |mask, index| {
        var wide: [8]u8 = undefined;
        std.mem.writeInt(u64, &wide, mask, .little);
        blob.appendSlice(testing.allocator, &wide) catch @panic("test alloc");
        const offset: u32 = @intCast(index);
        std.mem.writeInt(u32, &word, offset, .little);
        blob.appendSlice(testing.allocator, &word) catch @panic("test alloc");
        std.mem.writeInt(u32, &word, 0, .little);
        blob.appendSlice(testing.allocator, &word) catch @panic("test alloc");
        const modifier: u64 = if (index == 0) dmabuf.drm_format_mod_linear else 0x0100_0000_0000_0002;
        std.mem.writeInt(u64, &wide, modifier, .little);
        blob.appendSlice(testing.allocator, &wide) catch @panic("test alloc");
    }

    var out: std.ArrayList(dmabuf.Format) = .empty;
    defer out.deinit(testing.allocator);
    try parseInFormats(blob.items, &.{ drm_format_xrgb8888, dmabuf.drm_format_argb8888 }, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(dmabuf.supports(out.items, drm_format_xrgb8888, dmabuf.drm_format_mod_linear));
    try testing.expect(dmabuf.supports(out.items, dmabuf.drm_format_argb8888, 0x0100_0000_0000_0002));

    // A fourcc the plane does not list is not offered, even though the
    // blob names it.
    var narrowed: std.ArrayList(dmabuf.Format) = .empty;
    defer narrowed.deinit(testing.allocator);
    try parseInFormats(blob.items, &.{drm_format_xrgb8888}, &narrowed, testing.allocator);
    try testing.expectEqual(@as(usize, 1), narrowed.items.len);
    try testing.expect(dmabuf.supports(narrowed.items, drm_format_xrgb8888, dmabuf.drm_format_mod_linear));

    // Truncated, empty and unknown-version blobs yield nothing rather
    // than reading past the end or guessing.
    for ([_][]const u8{ "", blob.items[0..7], blob.items[0..@min(blob.items.len, 40)] }) |bytes| {
        var junk: std.ArrayList(dmabuf.Format) = .empty;
        defer junk.deinit(testing.allocator);
        try parseInFormats(bytes, &.{ drm_format_xrgb8888, dmabuf.drm_format_argb8888 }, &junk, testing.allocator);
        try testing.expectEqual(@as(usize, 0), junk.items.len);
    }
    const future = try testing.allocator.dupe(u8, blob.items);
    defer testing.allocator.free(future);
    std.mem.writeInt(u32, future[0..4], 99, .little);
    var junk2: std.ArrayList(dmabuf.Format) = .empty;
    defer junk2.deinit(testing.allocator);
    try parseInFormats(future, &.{ drm_format_xrgb8888, dmabuf.drm_format_argb8888 }, &junk2, testing.allocator);
    try testing.expectEqual(@as(usize, 0), junk2.items.len);
}

test "flip cookie exhaustion cannot alias an earlier completion or claim a writable slot" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    var fixture: FlipFixture = undefined;
    try fixture.init(testing.allocator, &io, &log_cfg);
    defer fixture.deinit();
    fixture.enable();
    fixture.slots[0].state = .front;
    const ancient = try fixture.queueFlip();
    invalidateFlipIdentity(fixture.drm_out);
    adoptModesetFront(fixture.drm_out, true);

    fixture.backend.next_cookie = std.math.maxInt(usize) - 1;
    const final_cookie = try fixture.queueFlip();
    fixture.complete(ancient);
    try testing.expect(fixture.drm_out.pending != null);
    try testing.expectEqual(@as(usize, 0), fixture.signals.presents);
    try testing.expectEqual(SlotState.front, fixture.slots[0].state);
    try testing.expectEqual(SlotState.pending, fixture.slots[1].state);
    fixture.complete(final_cookie);
    try testing.expectEqual(@as(usize, 1), fixture.signals.presents);
    try testing.expect(fixture.drm_out.pending == null);

    // Exhaustion refuses the next arm without taking the caller's slot.
    try testing.expectError(error.TestUnexpectedResult, fixture.queueFlip());
    try testing.expect(fixture.drm_out.pending == null);
    try testing.expectEqual(SlotState.free, fixture.slots[0].state);
    try testing.expectEqual(SlotState.front, fixture.slots[1].state);
    fixture.complete(ancient);
    try testing.expectEqual(@as(usize, 1), fixture.signals.presents);
}
