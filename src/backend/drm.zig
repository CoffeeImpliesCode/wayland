//! DRM/KMS backend with dumb-buffer scanout (pixman/software path).
//!
//! The compositor renders into its pixman Framebuffer (src/renderer/
//! pixman.zig); this backend memcpys the framebuffer rows into a dumb
//! buffer (DRM_IOCTL_MODE_CREATE_DUMB/MAP_DUMB/ADDFB2), then atomically
//! page-flips it to the primary plane. Frame pacing is event-driven: each
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
//! DRM_MODE_ATOMIC_*, DRM_FORMAT_ARGB8888.
//!
//! Imports: utils/*, backend/backend.zig, output/output.zig,
//! renderer/pixman.zig, and the translated "drm_c" namespace.

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const backend_mod = @import("backend.zig");
const output_mod = @import("../output/output.zig");
const pixman = @import("../renderer/pixman.zig");
const c = @import("drm_c");

/// DRM_FORMAT_ARGB8888 ('AR24' fourcc, 0x34325241): the pixman
/// Framebuffer is an ARGB8888 u32 in little-endian memory — bytes
/// B,G,R,A — which is exactly the layout DRM_FORMAT_ARGB8888 specifies
/// ([31:0] A:R:G:B 8:8:8:8 little endian), so rows copy verbatim.
pub const drm_format_argb8888: u32 = 0x34325241;

const default_device_path = "/dev/dri/card0";

/// The plane properties we commit with, indexed by name — the plane_info
/// table from wlroots backend/drm/properties.c (names must match exactly;
/// "type" is read as a value, never committed).
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
};

/// Per-output DRM state: the scanout buffer and the KMS object ids bound
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
    /// Dumb buffer (struct drm_mode_create_dumb output).
    dumb_handle: u32 = 0,
    dumb_pitch: u32 = 0,
    dumb_size: usize = 0,
    /// mmap of the dumb buffer; pitch may exceed width*4 (padding).
    map: []align(std.heap.page_size_min) u8 = &.{},
    /// Framebuffer id from DRM_IOCTL_MODE_ADDFB2.
    fb_id: u32 = 0,
    /// Mode blob id from drmModeCreatePropertyBlob (destroyed on teardown).
    mode_blob: u32 = 0,
    /// One flip in flight (guarded by the frame-event pacing).
    flip_pending: bool = false,
};

const DrmBackendData = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    device_path: []const u8,
    fd: ?std.posix.fd_t = null,
    is_master: bool = false,
    drm_output: ?*DrmOutput = null,
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
    /// open + master, connector/mode/crtc/plane enumeration, dumb buffer,
    /// atomic modeset, then `new_output` (plus the first frame kick).
    /// `device_path` selects the card node (default "/dev/dri/card0";
    /// the server passes WAYLAND_DRM_DEVICE).
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

/// The fd to poll for DRM events (page-flip completions).
pub fn pollFd(self: *DrmBackendData) std.posix.fd_t {
    return self.fd orelse -1;
}

/// Drain pending DRM events (drmHandleEvent); each flip completion emits
/// output.frame. Called by the server's event loop when `pollFd` is
/// readable (wlroots handle_drm_event).
pub fn dispatch(self: *DrmBackendData) void {
    const fd = self.fd orelse return;
    var evctx: c.drmEventContext = .{
        .version = 3,
        // v3 = page_flip_handler2 with crtc_id (wlroots drm.c uses the
        // same version + handler).
        .page_flip_handler2 = pageFlipHandler,
    };
    if (c.drmHandleEvent(fd, &evctx) != 0) {
        log_mod.err("drm: drmHandleEvent failed", self.io, self.log_cfg, "drm", .{});
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

fn startInner(base: *backend_mod.Backend) error{ BackendFailed, OutOfMemory }!void {
    const self: *DrmBackendData = @ptrCast(@alignCast(base.data));

    // --- open the card node (wlroots drm.c drm_open; O_RDWR|O_CLOEXEC).
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
    errdefer drmTeardown(self);

    // Atomic modesetting must be requested before any KMS ioctl
    // (wlroots drm.c drm_open: drmSetClientCap(DRM_CLIENT_CAP_ATOMIC, 1)).
    if (c.drmSetClientCap(fd, @intCast(c.DRM_CLIENT_CAP_ATOMIC), 1) != 0) {
        log_mod.err("drm: DRM_CLIENT_CAP_ATOMIC unsupported on {s}", self.io, self.log_cfg, "drm", .{self.device_path});
        return error.BackendFailed;
    }

    // Become DRM master (required for modeset). The first opener is
    // master automatically, so failure is non-fatal here (headless VM).
    if (c.drmIoctl(fd, c.DRM_IOCTL_SET_MASTER, null) == 0) {
        self.is_master = true;
    } else {
        log_mod.warn("drm: DRM_IOCTL_SET_MASTER failed (not master?)", self.io, self.log_cfg, "drm", .{});
    }

    // --- find a connected connector with a mode, its encoder and a CRTC
    // (wlroots drm.c init_drm_resources + drm_connector_alloc_crtc).
    const found = findConnectorMode(self) orelse {
        log_mod.err("drm: no connected connector with a mode on {s}", self.io, self.log_cfg, "drm", .{
            self.device_path,
        });
        return error.BackendFailed;
    };
    log_mod.info(
        "drm: {s} connector={d} mode={d}x{d}",
        self.io,
        self.log_cfg,
        "drm",
        .{ basename(self.device_path), found.connector_id, found.mode.hdisplay, found.mode.vdisplay },
    );

    // --- primary plane for the CRTC, with all commit property ids
    // (wlroots drm.c init_plane: possible_crtcs + type == PRIMARY).
    var plane: PlanePropIds = .{};
    const plane_id = findPrimaryPlane(self, found.crtc_index, &plane) orelse {
        log_mod.err("drm: no primary plane for crtc={d}", self.io, self.log_cfg, "drm", .{found.crtc_id});
        return error.BackendFailed;
    };

    const allocator = self.allocator;
    const drm_out = try allocator.create(DrmOutput);
    drm_out.* = .{
        .backend = self,
        .crtc_id = found.crtc_id,
        .plane_id = plane_id,
        .props = plane,
        .mode = modeToOutput(found.mode),
    };
    // Owned by self from here on: a start() failure releases the device
    // resources via drmTeardown (errdefer below) and the caller's
    // backend.destroy() frees the struct.
    self.drm_output = drm_out;

    // --- connector + crtc property ids (wlroots properties.c tables).
    {
        var conn_props: [1]u32 = undefined;
        if (!scanPropIds(fd, found.connector_id, c.DRM_MODE_OBJECT_CONNECTOR, &[_][]const u8{"CRTC_ID"}, &conn_props)) {
            log_mod.err("drm: connector CRTC_ID property missing", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
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

    // --- dumb buffer: create, map, addfb2
    // (smithay src/backend/drm/dumb.rs framebuffer_from_dumb_buffer:
    // create dumb -> add_framebuffer; wlroots uses the same ioctls).
    {
        const width: u32 = found.mode.hdisplay;
        const height: u32 = found.mode.vdisplay;

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
        drm_out.dumb_handle = create_dumb.handle;
        drm_out.dumb_pitch = create_dumb.pitch;
        drm_out.dumb_size = @intCast(create_dumb.size);

        var map_dumb: c.struct_drm_mode_map_dumb = .{ .handle = create_dumb.handle };
        if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &map_dumb) != 0) {
            log_mod.err("drm: DRM_IOCTL_MODE_MAP_DUMB failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
        drm_out.map = std.posix.mmap(
            null,
            drm_out.dumb_size,
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
            .pixel_format = drm_format_argb8888,
            .handles = .{ create_dumb.handle, 0, 0, 0 },
            .pitches = .{ create_dumb.pitch, 0, 0, 0 },
            .offsets = .{ 0, 0, 0, 0 },
        };
        if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_ADDFB2, &fb2) != 0) {
            log_mod.err("drm: DRM_IOCTL_MODE_ADDFB2 failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
        drm_out.fb_id = fb2.fb_id;
    }

    // --- mode blob (wlroots atomic.c create_mode_blob).
    {
        var blob_id: u32 = 0;
        if (c.drmModeCreatePropertyBlob(fd, &found.mode, @sizeOf(c.drmModeModeInfo), &blob_id) != 0) {
            log_mod.err("drm: drmModeCreatePropertyBlob failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
        drm_out.mode_blob = blob_id;
    }

    // --- atomic modeset: connector->crtc binding, crtc active+mode,
    // plane fb + full source/dest rect. Blocking (no flip event; the
    // first frame's page flip sends the event).
    // (wlroots atomic.c atomic_connector_add + set_plane_props; smithay
    // surface/atomic.rs set_connector/set_crtc/set_plane).
    {
        const req = c.drmModeAtomicAlloc() orelse {
            log_mod.err("drm: drmModeAtomicAlloc failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        };
        defer c.drmModeAtomicFree(req);
        const src_w = fixed16(found.mode.hdisplay);
        const src_h = fixed16(found.mode.vdisplay);
        if (c.drmModeAtomicAddProperty(req, found.connector_id, drm_out.connector_crtc_id, found.crtc_id) < 0 or
            c.drmModeAtomicAddProperty(req, found.crtc_id, drm_out.crtc_mode_id, drm_out.mode_blob) < 0 or
            c.drmModeAtomicAddProperty(req, found.crtc_id, drm_out.crtc_active, 1) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.crtc_id, found.crtc_id) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.fb_id, drm_out.fb_id) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.src_x, 0) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.src_y, 0) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.src_w, src_w) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.src_h, src_h) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.crtc_x, 0) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.crtc_y, 0) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.crtc_w, found.mode.hdisplay) < 0 or
            c.drmModeAtomicAddProperty(req, plane_id, plane.crtc_h, found.mode.vdisplay) < 0)
        {
            log_mod.err("drm: atomic modeset property add failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
        if (c.drmModeAtomicCommit(fd, req, c.DRM_MODE_ATOMIC_ALLOW_MODESET, null) != 0) {
            log_mod.err("drm: atomic modeset commit failed", self.io, self.log_cfg, "drm", .{});
            return error.BackendFailed;
        }
    }

    // --- announce the output, then kick the first frame. The compositor
    // attaches its frame listener during the emit, so the flip event
    // chain starts here (wlroots: wlr_output_send_frame after modeset).
    const out = try output_mod.Output.create(
        allocator,
        self.io,
        self.log_cfg,
        base,
        &output_impl,
        drm_out,
        drm_out.mode,
    );
    drm_out.out = out;
    base.emitNewOutput(out);
    out.sendFrame();
    log_mod.info("drm: modeset ok, output live", self.io, self.log_cfg, "drm", .{});
}

fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const self: *DrmBackendData = @ptrCast(@alignCast(data));
    // Tear down the output first (emits destroy signals) so no frame
    // callback can touch the DRM state after the fd closes; then release
    // the device resources (which live in drm_out) before freeing it.
    if (self.drm_output) |drm_out| {
        if (drm_out.out) |out| out.destroy();
    }
    drmTeardown(self);
    if (self.drm_output) |drm_out| allocator.destroy(drm_out);
    allocator.destroy(self);
}

// ---------------------------------------------------------------------------
// Output impl
// ---------------------------------------------------------------------------

fn testState(out: *output_mod.Output, state: *const output_mod.Output.State) error{InvalidState}!void {
    const self: *DrmOutput = @ptrCast(@alignCast(out.data));
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
        log_mod.err("drm: page flip already pending", self.backend.io, self.backend.log_cfg, "drm", .{});
        return error.CommitFailed;
    }

    const fb: *pixman.Framebuffer = @ptrCast(@alignCast(state.buffer.?));
    // Row-by-row copy: the dumb pitch may exceed width*4, so a single
    // whole-buffer memcpy would skew every row past the first.
    // (smithay dumb.rs scans out the same pitch-padded ARGB buffer.)
    copyRows(fb.data, @intCast(fb.stride), self.map, self.dumb_pitch, fb.width, fb.height);

    // Page flip: only FB_ID changes on the plane (the modeset bound the
    // rest); PAGE_FLIP_EVENT + NONBLOCK like wlroots atomic.c
    // (non-modeset commits with a new buffer are non-blocking flips).
    const fd = self.backend.fd.?;
    const req = c.drmModeAtomicAlloc() orelse return error.CommitFailed;
    defer c.drmModeAtomicFree(req);
    if (c.drmModeAtomicAddProperty(req, self.plane_id, self.props.fb_id, self.fb_id) < 0) {
        log_mod.err("drm: atomic add FB_ID failed", self.backend.io, self.backend.log_cfg, "drm", .{});
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

/// Find the first connected connector with a mode; prefer the preferred
/// mode (mode.type & DRM_MODE_TYPE_PREFERRED), else the first mode
/// (wlroots drm.c drm_connector_get_current_mode). Resolves the encoder
/// and a free CRTC via possible_crtcs (wlroots drm_connector_alloc_crtc).
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

        var chosen: c_int = 0;
        var m: c_int = 0;
        while (m < conn.*.count_modes) : (m += 1) {
            if (conn.*.modes[@intCast(m)].type & c.DRM_MODE_TYPE_PREFERRED != 0) {
                chosen = m;
                break;
            }
        }

        // Encoder: the connector's own when set, else the first encoder
        // that can drive any CRTC.
        var encoder_id = conn.*.encoder_id;
        var possible_crtcs: u32 = 0;
        if (encoder_id != 0) {
            const enc = c.drmModeGetEncoder(fd, encoder_id) orelse continue;
            possible_crtcs = enc.*.possible_crtcs;
            c.drmModeFreeEncoder(enc);
        } else {
            var e: c_int = 0;
            while (e < res.*.count_encoders) : (e += 1) {
                const enc = c.drmModeGetEncoder(fd, res.*.encoders[@intCast(e)]) orelse continue;
                const enc_possible = enc.*.possible_crtcs;
                c.drmModeFreeEncoder(enc);
                if (enc_possible != 0) {
                    encoder_id = res.*.encoders[@intCast(e)];
                    possible_crtcs = enc_possible;
                    break;
                }
            }
        }
        if (possible_crtcs == 0) continue;

        // First free CRTC the encoder can drive (kernels expose <= 32
        // CRTCs; wlroots asserts the same bound).
        var j: c_int = 0;
        var crtc_index: usize = 0;
        var crtc_id: u32 = 0;
        while (j < res.*.count_crtcs and j < 32) : (j += 1) {
            const bit = @as(u32, 1) << @as(u5, @intCast(j));
            if (possible_crtcs & bit != 0) {
                crtc_index = @intCast(j);
                crtc_id = res.*.crtcs[@intCast(j)];
                break;
            }
        }
        if (crtc_id == 0) continue;

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
/// possible_crtcs and type == DRM_PLANE_TYPE_PRIMARY; properties.c
/// plane_info table names the ids).
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

        out_props.* = props;
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
/// property id (read to classify the plane).
fn scanPlaneProps(fd: c_int, plane_id: u32, out_props: *PlanePropIds) bool {
    var ids: [11]u32 = undefined;
    if (!scanPropIds(fd, plane_id, c.DRM_MODE_OBJECT_PLANE, &plane_prop_names, ids[0..10])) return false;

    const props = c.drmModeObjectGetProperties(fd, plane_id, c.DRM_MODE_OBJECT_PLANE) orelse return false;
    defer c.drmModeFreeObjectProperties(props);
    ids[10] = 0;
    var i: u32 = 0;
    while (i < props.*.count_props) : (i += 1) {
        const prop = c.drmModeGetProperty(fd, props.*.props[i]) orelse continue;
        defer c.drmModeFreeProperty(prop);
        // drmModePropertyRes.name is a NUL-terminated char[32] buffer.
        const name_ptr: [*:0]const u8 = @ptrCast(&prop.*.name);
        const prop_name = std.mem.sliceTo(name_ptr, 0);
        if (std.mem.eql(u8, prop_name, "type")) ids[10] = prop.*.prop_id;
    }
    if (ids[10] == 0) return false;

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
        .plane_type = ids[10],
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

/// Release DRM device resources in reverse acquisition order: RmFB,
/// destroy dumb, munmap, drop master, close (task teardown order).
/// Null-safe and idempotent so partial start() failures clean up.
fn drmTeardown(self: *DrmBackendData) void {
    const fd = self.fd orelse return;
    if (self.drm_output) |drm_out| {
        if (drm_out.mode_blob != 0) {
            _ = c.drmModeDestroyPropertyBlob(fd, drm_out.mode_blob);
            drm_out.mode_blob = 0;
        }
        if (drm_out.fb_id != 0) {
            _ = c.drmModeRmFB(fd, drm_out.fb_id);
            drm_out.fb_id = 0;
        }
        if (drm_out.map.len != 0) {
            std.posix.munmap(drm_out.map);
            drm_out.map = &.{};
        }
        if (drm_out.dumb_handle != 0) {
            var destroy_dumb: c.struct_drm_mode_destroy_dumb = .{ .handle = drm_out.dumb_handle };
            _ = c.drmIoctl(fd, c.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy_dumb);
            drm_out.dumb_handle = 0;
        }
    }
    if (self.is_master) {
        _ = c.drmIoctl(fd, c.DRM_IOCTL_DROP_MASTER, null);
        self.is_master = false;
    }
    _ = std.os.linux.close(fd);
    self.fd = null;
}

/// DRM_EVENT_FLIP_COMPLETE handler (wlroots drm.c handle_page_flip): the
/// flip for our crtc has completed — the buffer is now visible, so wake
/// the output for the next frame.
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
    _ = tv_sec;
    _ = tv_usec;
    const drm_out: *DrmOutput = @ptrCast(@alignCast(user_data.?));
    if (crtc_id != drm_out.crtc_id) return;
    drm_out.flip_pending = false;
    if (drm_out.out) |out| out.sendFrame();
}

// ---------------------------------------------------------------------------
// Tests (pure logic only; device paths are VM-verified)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fourcc constant matches drm_fourcc.h" {
    // ARGB8888 fourcc 'A' 'R' '2' '4' = 0x34325241; the pixman framebuffer
    // byte order (B,G,R,A in memory) equals DRM_FORMAT_ARGB8888's.
    try testing.expectEqual(drm_format_argb8888, c.DRM_FORMAT_ARGB8888);
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
