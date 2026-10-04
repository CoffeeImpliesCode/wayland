//! DMA-BUF import: the attributes a client hands the compositor, the
//! validation the zwp_linux_buffer_params_v1 error enum allows us to reject
//! them with, and the GBM-backed importer that turns a validated set into a
//! compositor Buffer (the wlr_dmabuf_attributes + wlr_buffer pair).
//!
//! Split of responsibilities:
//!   - this file owns WHAT a buffer is (Attributes), WHETHER a set of
//!     planes is legal (validate), HOW one becomes a Buffer
//!     (GbmDevice) and how its pixels are reached from the CPU
//!     (beginWrite/endWrite). It knows nothing about the wire protocol.
//!   - shell/linux_dmabuf.zig owns the zwp_linux_dmabuf_v1 objects and
//!     decides which Device (if any) the global may be advertised with.
//!   - backend/drm.zig owns the GBM device itself: it resolves the DRM
//!     node to open and enumerates the (format, modifier) pairs.
//!
//! # Validation is the protocol's, not ours
//! The XML fixes which rejections may be fatal and which error each one
//! carries (linux-dmabuf-v1.xml:207-227). There is NO `invalid_modifier`,
//! `invalid_stride` or `invalid_offset` error in this interface — those
//! names are from the v1-era draft. The legal mapping is:
//!   bad format or bad format+modifier  -> invalid_format  (:216-217, and
//!                                          :248-249 "Starting from version 4,
//                                          the invalid_format protocol error
//!                                          is sent if the format + modifier
//!                                          pair was not advertised")
//!   bad offset or bad stride           -> out_of_bounds  (:220-221)
//!   non-positive width/height          -> invalid_dimensions (:218-219)
//!   missing / extra / gapped planes     -> incomplete      (:214-215)
//!   plane_idx >= 4 / plane set twice   -> plane_idx / plane_set (:210-213)
//!   unknown bits in `flags`            -> invalid_format  (wlroots
//!                                          params_create_common :271-278)
//! Anything the compositor simply cannot import (a dmabuf the driver
//! rejects) is NOT a protocol error: `create` answers with the `failed`
//! event and `create_immed` with invalid_wl_buffer (wlroots
//! params_create_common :383-396).
//!
//! # Ownership of the plane fds
//! The client passes ownership of every fd in `add` (libwayland dups them
//! into the message, and we own the copies). Whoever receives an
//! `Attributes` owns closing them: `Attributes.closePlanes` is called on
//! every exit path, and `Device.import` takes the struct by value with
//! that contract spelled out in its error set documentation.
//! An IMPORTED buffer keeps its OWN descriptors: `gbmImport` duplicates
//! every plane fd into the wrapper (`wrapGbmBuffer`) and closes the ones
//! it was handed, so what `get_dmabuf` hands back afterwards is a
//! complete, exportable description - real fds, real strides, real plane
//! count - rather than a set of spent descriptor numbers. That is what
//! makes a client buffer usable as a scanout frame (EGLImage import,
//! drmModeAddFB2) and what makes `screencopy`'s single-plane destination
//! check (`attrs.n_planes != 1`) see the buffer it actually got. The
//! duplicates are closed exactly once, in `dmabufDestroy`.
//! # CPU access to an imported bo
//! A bo is GPU memory, so the Buffer impl carries no CPU pointer (see
//! `dmabuf_impl` below). One consumer needs the pixels anyway: a
//! screencopy frame is produced in system memory and the client may
//! have asked for it to land in a dmabuf, so the copy has to be able
//! to WRITE the destination. `beginWrite` / `endWrite` are that path
//! (gbm_bo_map, Mesa 21.1+), and they are deliberately NOT the
//! impl's begin/end_data_ptr_access pair: those say "this is a plain
//! CPU-mappable surface" to every consumer (the GL renderer picks its
//! texture upload path off them, buffer.zig:43-48), and a bo is
//! mapped for one copy at a time, not for its whole life.
//!
//! Imports: buffers/buffer.zig (the Buffer abstraction this exposes) and
//! the translated "gbm_c" namespace.

const std = @import("std");
const buffer_mod = @import("buffer.zig");
const c = @import("gbm_c");

pub const Buffer = buffer_mod.Buffer;
const Impl = buffer_mod.Impl;

/// Maximum planes a drm_fourcc format can carry: `WLR_DMABUF_MAX_PLANES`
/// (wlroots include/wlr/interfaces/wlr_buffer.h) and `GBM_MAX_PLANES`
/// (gbm.h:392) are both 4, and the wire carries at most
/// `gbm_import_fd_modifier_data.fds[4]`.
pub const max_planes = 4;

/// The fourccs a format/modifier pair can be advertised with. DRM_FORMAT_*
/// codes are a character packing of the fourcc (drm_fourcc.h:
/// `fourcc_code('A','R','2','4')`), so they are spelled out here rather
/// than pulled in through the shim (see dmabuf_c.h).
pub const drm_format_argb8888: u32 = 0x34325241; // 'AR24'
pub const drm_format_xrgb8888: u32 = 0x34325258; // 'XR24'
pub const drm_format_argb2101010: u32 = 0x30335241; // 'A210'
pub const drm_format_xrgb2101010: u32 = 0x30335258; // 'X210'

/// `DRM_FORMAT_MOD_INVALID`: the XML allows advertising it to mean "an
/// implicit (unspecified) layout also works" (linux-dmabuf-v1.xml:136-144).
/// We never advertise it — gbm_bo_import is given the layout the client
/// claims and we validate that claim against the device, so an implicit
/// layout would be a promise we cannot keep. Documented in the module
/// report as a divergence from wlroots, which does advertise it.
pub const drm_format_mod_invalid: u64 = 0x00ff_ffff_ffff_ffff;

/// `DRM_FORMAT_MOD_LINEAR` (drm_fourcc.h): no tiling, no compression.
pub const drm_format_mod_linear: u64 = 0;

/// One plane of a dmabuf: the fd plus where in it the plane starts.
pub const Plane = struct {
    /// -1 means "this plane was not added". wlroots keeps the same
    /// sentinel in wlr_dmabuf_attributes.fd[] and initialises every
    /// entry to -1 (linux_dmabuf_create_params, :455-457).
    fd: std.posix.fd_t = -1,
    offset: u32 = 0,
    stride: u32 = 0,
};

/// A complete dmabuf buffer description (wlr_dmabuf_attributes plus the
/// width/height/format the create request carries).
pub const Attributes = struct {
    width: i32 = 0,
    height: i32 = 0,
    format: u32 = 0,
    /// The single modifier every plane shares. The XML requires the planes
    /// to agree from version 5 (:251-252); wlroots enforces it on every
    /// version (params_add, :181-189) and so do we.
    modifier: u64 = 0,
    planes: [max_planes]Plane = [_]Plane{.{}} ** max_planes,
    /// How many planes are actually set; `planes[i].fd` is authoritative
    /// for "which" ones (indices must be consecutive from 0).
    n_planes: u8 = 0,

    /// Close every plane fd and reset the struct. Idempotent: a closed
    /// plane goes back to -1, so a double close cannot double-close a
    /// recycled fd number.
    pub fn closePlanes(self: *Attributes) void {
        for (&self.planes) |*plane| {
            if (plane.fd >= 0) {
                _ = std.os.linux.close(plane.fd);
                plane.fd = -1;
            }
        }
        self.n_planes = 0;
    }
};

/// One (format, modifier) pair the compositor advertises. The pair is the
/// unit of acceptance: v4+ clients are sent exactly these pairs and the
/// create request is validated against exactly these pairs
/// (linux-dmabuf-v1.xml:248-249).
pub const Format = struct {
    format: u32,
    modifier: u64,
};

/// The rejections `validate` can make. Each maps 1:1 onto a
/// zwp_linux_buffer_params_v1 error code (see the module comment).
pub const ValidationError = error{
    Incomplete,
    InvalidFormat,
    InvalidDimensions,
    OutOfBounds,
};

/// The `flags` bitfield bits this XML defines (linux-dmabuf-v1.xml:268-272).
/// Any other bit is an unknown flag from a future version and is rejected
/// with invalid_format (wlroots params_create_common:271-278).
pub const known_flags: u32 = 1 | 2 | 4;

/// Is `format` + `modifier` one of the pairs the compositor advertised?
pub fn supports(formats: []const Format, format: u32, modifier: u64) bool {
    for (formats) |f| {
        if (f.format == format and f.modifier == modifier) return true;
    }
    return false;
}

/// Decide whether the planes collected by `add` plus the arguments of a
/// create/create_immed request describe a buffer this compositor can
/// accept, and say which protocol error the client's mistake maps to.
///
/// `attrs` is only read; the caller keeps ownership of the plane fds.
/// `supported` is the device's advertised (format, modifier) set.
///
/// Check order follows wlroots params_create_common (:249-343) with one
/// documented addition: the format+modifier pair is checked there (see the
/// module comment on v4+) before the per-plane bounds walk, so a client
/// that guessed a format learns that instead of tripping over a size check
/// on a buffer it was never going to get.
pub fn validate(
    attrs: *const Attributes,
    width: i32,
    height: i32,
    format: u32,
    raw_flags: u32,
    supported: []const Format,
) ValidationError!void {
    // Nothing added at all (linux-dmabuf-v1.xml:214-215).
    if (attrs.n_planes == 0) return error.Incomplete;
    // Plane 0 missing (the create request's width/height describe the base
    // plane, so plane 0 must exist).
    if (attrs.planes[0].fd < 0) return error.Incomplete;
    // "You must use consecutive plane indices from zero" (:199-201). A set
    // reaching plane 2 or 3 without plane 1 is a gap, not a reordering.
    if ((attrs.planes[2].fd >= 0 or attrs.planes[3].fd >= 0) and attrs.planes[1].fd < 0) {
        return error.Incomplete;
    }

    // Unknown flag bits: a value a future version adds must not be silently
    // dropped (wlroots params_create_common:271-278 posts invalid_format).
    if (raw_flags & ~known_flags != 0) return error.InvalidFormat;

    if (width < 1 or height < 1) return error.InvalidDimensions;

    // The format+modifier pair must be one we advertised (:248-249).
    if (!supports(supported, format, attrs.modifier)) return error.InvalidFormat;

    var i: usize = 0;
    while (i < max_planes) : (i += 1) {
        const plane = attrs.planes[i];
        if (plane.fd < 0) break;
        // gbm_import_fd_modifier_data.strides/offsets are C `int`
        // (gbm.h:394-403); a value that cannot be carried there can never
        // describe a real buffer.
        if (plane.stride > std.math.maxInt(i32) or plane.offset > std.math.maxInt(i32)) {
            return error.OutOfBounds;
        }
        // offset + stride must fit a 32-bit offset (wlroots :296-303).
        const first_row_end = @as(u64, plane.offset) + @as(u64, plane.stride);
        if (first_row_end > std.math.maxInt(u32)) return error.OutOfBounds;
        // offset + stride * height must fit too (wlroots :305-311). The
        // u64 math cannot overflow: both operands are <= 2^32.
        const buffer_end = @as(u64, plane.offset) +
            @as(u64, plane.stride) * @as(u64, @intCast(height));
        if (buffer_end > std.math.maxInt(u32)) return error.OutOfBounds;

        // The remaining checks need the object's real size. A kernel that
        // does not support lseek on a dmabuf gives -1 and we skip them
        // (wlroots :313-316 skips the whole per-plane check in that case).
        const size = planeSize(plane.fd) orelse continue;
        if (@as(u64, plane.offset) > size) return error.OutOfBounds;
        if (first_row_end > size or plane.stride == 0) return error.OutOfBounds;
        // Planes above 0 may be subsampled per the fourcc, so only the base
        // plane has to cover the whole height (wlroots :335-342).
        if (i == 0 and buffer_end > size) return error.OutOfBounds;
    }
}

/// The size of the object behind `fd`, or null when the kernel refuses to
/// seek on it (wlroots params_create_common:313-316 treats that as "skip
/// the bounds checks", not as a client error).
fn planeSize(fd: std.posix.fd_t) ?u64 {
    const rc = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
    // std.os.linux.errno, not std.posix.errno: lseek ran as a raw syscall,
    // so the error lives in the return value, not in the libc thread-local
    // errno that std.posix.errno would read.
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    return rc;
}

/// The compositor side of a zwp_linux_dmabuf_v1 global: what can be
/// imported, on what, and which (format, modifier) pairs that implies.
///
/// This is an interface, not GBM: the protocol module must be exercisable
/// without a DRM device, and the surface that wants pixels is not
/// necessarily a GBM device either. `GbmDevice` is the production
/// implementation; the tests substitute a CPU-backed double.
pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// dev_t of the node the compositor imports on. Advertised as the
        /// feedback object's main_device / tranche_target_device
        /// (linux-dmabuf-v1.xml:495-525, :536-566).
        main_device: *const fn (ptr: *anyopaque) u64,
        /// The advertised (format, modifier) pairs. An empty list means
        /// the device cannot import anything.
        formats: *const fn (ptr: *anyopaque) []const Format,
        /// Import a validated set into a compositor Buffer.
        import_buffer: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            attrs: Attributes,
        ) error{ OutOfMemory, ImportFailed }!*Buffer,
    };

    pub fn mainDevice(self: Device) u64 {
        return self.vtable.main_device(self.ptr);
    }

    pub fn formats(self: Device) []const Format {
        return self.vtable.formats(self.ptr);
    }

    /// Import `attrs`, consuming its plane fds on every path: on success
    /// the importer keeps its OWN duplicates and closes the ones it was
    /// handed (so the buffer it returns exports a complete, still-valid
    /// description), on failure it closes every fd it was given and
    /// returns nothing.
    pub fn import(
        self: Device,
        allocator: std.mem.Allocator,
        attrs: Attributes,
    ) error{ OutOfMemory, ImportFailed }!*Buffer {
        return self.vtable.import_buffer(self.ptr, allocator, attrs);
    }

    /// Whether this device can actually import something. The
    /// zwp_linux_dmabuf_v1 global is advertised only for a live device:
    /// advertising it without one is a promise the client can falsify on
    /// its first create request (and every real client then falls back to
    /// shm, having lost a roundtrip for nothing).
    pub fn isLive(self: Device) bool {
        return self.formats().len != 0;
    }
};

/// A GBM device on a DRM node: what the compositor imports client dmabufs
/// into (wlroots' wlr_gbm_allocator, render/allocator/gbm.c:164-195,
/// carries the same `gbm_device` + fd pair).
///
/// The node is re-opened rather than reused from the KMS backend:
/// wlroots `reopen_drm_node` (render/allocator/allocator.c:35-96) does this
/// to avoid sharing GEM handle refcounts with the KMS fd (the reason is the
/// linked mesa/drm!110), and because the allocator may prefer the render
/// node where the KMS path used the primary node.
pub const GbmDevice = struct {
    allocator: std.mem.Allocator,
    /// The node GBM was opened on; held for the device's lifetime because
    /// gbm_create_device keeps only a borrowed fd.
    fd: std.posix.fd_t,
    device: *c.gbm_device,
    /// Owned; `setFormats` frees the slice it replaces and `deinit` frees
    /// the live one.
    formats: []Format = &.{},
    /// dev_t of `fd`, the node clients should target.
    main_dev: u64,
    /// The interface view of this device (handed to the protocol module).
    iface: Device,

    const vtable = Device.VTable{
        .main_device = gbmMainDevice,
        .formats = gbmFormats,
        .import_buffer = gbmImport,
    };

    pub const OpenError = error{
        NodeOpenFailed,
        GbmCreateFailed,
        DevStatFailed,
        OutOfMemory,
    };

    /// Open `node_path` and create a GBM device on it.
    pub fn create(allocator: std.mem.Allocator, node_path: []const u8) OpenError!*GbmDevice {
        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            node_path,
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        ) catch return error.NodeOpenFailed;
        errdefer _ = std.os.linux.close(fd);
        const device = c.gbm_create_device(fd) orelse return error.GbmCreateFailed;
        // The DRM device number behind the node, for the v4+ feedback
        // events. Zig 0.16's std.posix/std.os.linux have no fstat, so
        // declare the libc one. It is `st_rdev`, not `st_dev`: for a
        // character device node `st_dev` is the devtmpfs filesystem's
        // device (every /dev/dri node shares it) while `st_rdev` is the
        // rendered DRM device itself - what the feedback's main_device /
        // tranche_target_device advertise and what a client compares
        // against (wlroots reads the same field in renderer/drm.c:
        // `major(drm_node_stat.st_rdev)`).
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) return error.DevStatFailed;
        const self = try allocator.create(GbmDevice);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .device = device,
            .main_dev = @bitCast(@as(i64, @bitCast(st.st_rdev))),
            .iface = .{ .ptr = undefined, .vtable = &vtable },
        };
        // The vtable entry point receives exactly this pointer back.
        self.iface.ptr = self;
        return self;
    }

    /// Take ownership of the advertised (format, modifier) pairs. The
    /// previous pair set is released first: this device is asked for its
    /// capability table more than once (the DRM backend queries GBM,
    /// then the server narrows it to what the renderer can actually
    /// import), and dropping the old set would leak it. Only an owned
    /// non-empty slice is freed — the `&.{}` default is static.
    pub fn setFormats(self: *GbmDevice, formats: []Format) void {
        if (self.formats.len != 0) self.allocator.free(self.formats);
        self.formats = formats;
    }

    pub fn deinit(self: *GbmDevice) void {
        // The bo objects must die before the device (wlroots
        // allocator_destroy, render/allocator/gbm.c:197-212 orders it the
        // same way); the protocol module frees its buffers in its own
        // deinit, which the caller runs before this one.
        c.gbm_device_destroy(self.device);
        // Only an owned slice is freed: the default `&.{}` is static, and
        // free() on it would hand the allocator a non-heap pointer.
        if (self.formats.len != 0) self.allocator.free(self.formats);
        _ = std.os.linux.close(self.fd);
        self.allocator.destroy(self);
    }

    /// The GBM backend name for logs ("drm", "nvidia", "d3d12", ...), the
    /// same diagnostic wlroots logs (render/allocator/gbm.c:188-189).
    pub fn backendName(self: *GbmDevice) []const u8 {
        return std.mem.span(c.gbm_device_get_backend_name(self.device));
    }
};

fn gbmMainDevice(ptr: *anyopaque) u64 {
    const self: *GbmDevice = @ptrCast(@alignCast(ptr));
    return self.main_dev;
}

fn gbmFormats(ptr: *anyopaque) []const Format {
    const self: *GbmDevice = @ptrCast(@alignCast(ptr));
    return self.formats;
}

/// Native sources need rendering/scanout, not a CPU-linear layout.
/// Add LINEAR only for an explicitly linear source; forcing it on a
/// tiled import makes drivers such as NVIDIA reject a valid DMA-BUF.
const import_usage: u32 = c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING;

/// A private copy of `fd` (CLOEXEC is irrelevant: it never outlives the
/// import), or null on failure. The wrapper and the bo must not share one
/// descriptor: the bo takes its own reference at import time, the
/// wrapper keeps the exportable one, and the two are closed by different
/// owners.
fn dupFd(fd: std.posix.fd_t) error{OutOfMemory}!std.posix.fd_t {
    const rc = std.os.linux.dup(fd);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.OutOfMemory;
    return @intCast(rc);
}

fn gbmImport(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    attrs_in: Attributes,
) error{ OutOfMemory, ImportFailed }!*Buffer {
    const self: *GbmDevice = @ptrCast(@alignCast(ptr));
    // `attrs_in` arrives by value and the fds are ours from here on; every
    // exit path below either closes them or hands them to the Buffer.
    var attrs = attrs_in;
    errdefer attrs.closePlanes();

    var data: c.struct_gbm_import_fd_modifier_data = std.mem.zeroes(
        c.struct_gbm_import_fd_modifier_data,
    );
    data.width = @intCast(attrs.width);
    data.height = @intCast(attrs.height);
    data.format = attrs.format;
    data.modifier = attrs.modifier;
    data.num_fds = attrs.n_planes;
    var i: usize = 0;
    while (i < attrs.n_planes) : (i += 1) {
        data.fds[i] = attrs.planes[i].fd;
        // validate() already rejected anything that does not fit an int.
        data.strides[i] = @intCast(attrs.planes[i].stride);
        data.offsets[i] = @intCast(attrs.planes[i].offset);
    }

    // gbm_bo_import is the modern dmabuf import entry point. The
    // pre-mesa-22 spelling gbm_bo_create(dev, w, h, fmt, usage, &bo,
    // &stride, &plane_fd, &offset), which wlroots' import path used to
    // call, is gone from gbm.h (26.1.3 declares the 5-argument
    // gbm_bo_create and gbm_bo_import instead).
    const bo = c.gbm_bo_import(
        self.device,
        c.GBM_BO_IMPORT_FD_MODIFIER,
        &data,
        import_usage | (if (attrs.modifier == drm_format_mod_linear) @as(u32, @intCast(c.GBM_BO_USE_LINEAR)) else 0),
    ) orelse return error.ImportFailed;
    errdefer c.gbm_bo_destroy(bo);

    const buf = try wrapGbmBuffer(allocator, bo, attrs);
    // The bo owns its own reference to the client's dma-buf and the
    // wrapper holds descriptors of its own, so the fds the client lent
    // us can go back.
    attrs.closePlanes();
    return buf;
}

/// Per-buffer state for the dmabuf Buffer impl.
const DmabufBufferData = struct {
    /// The imported object; the only thing the buffer really owns.
    bo: *c.gbm_bo,
    /// The description this buffer was imported with, so the renderer and
    /// any later exporter can reproduce it (wlroots keeps the same in
    /// wlr_gbm_buffer.dmabuf, render/allocator/gbm.c:102).
    attrs: Attributes,
    buf: *Buffer,
};

const dmabuf_impl: Impl = .{
    .get_dmabuf = dmabufGetAttributes,
    // No CPU pointer: a dmabuf is GPU memory. begin/end_data_ptr_access stay
    // null (they must be provided as a pair, buffer.zig:89-92) so the
    // renderer cannot mistake it for a mmap-able surface.
    .get_shm = null,
    .begin_data_ptr_access = null,
    .end_data_ptr_access = null,
    .destroy = dmabufDestroy,
};

fn dmabufData(buf: *Buffer) *DmabufBufferData {
    return @ptrCast(@alignCast(buf.data));
}

fn dmabufGetAttributes(buf: *Buffer) ?*anyopaque {
    return @ptrCast(&dmabufData(buf).attrs);
}

fn dmabufDestroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const d: *DmabufBufferData = @ptrCast(@alignCast(data));
    // The user-data destroy callback runs from here, not from
    // gbm_bo_destroy, so the bo is still valid when it fires. Our own
    // plane descriptors close here and only here - exactly once, even
    // though the same buffer may have been handed out, imported by a
    // renderer and destroyed late.
    c.gbm_bo_destroy(d.bo);
    d.attrs.closePlanes();
    allocator.destroy(d);
}

/// Wrap an imported bo in a compositor Buffer. The wrapper keeps its OWN
/// copy of every plane descriptor: `attrs`' fds belong to the caller (the
/// import path closes them once the wrapper exists) and are duplicated
/// here, so the exported `get_dmabuf` description stays complete for as
/// long as the buffer does.
fn wrapGbmBuffer(
    allocator: std.mem.Allocator,
    bo: *c.gbm_bo,
    attrs: Attributes,
) error{OutOfMemory}!*Buffer {
    const d = try allocator.create(DmabufBufferData);
    errdefer allocator.destroy(d);
    d.* = .{
        .bo = bo,
        // Start from the layout, not the descriptors: the fds that
        // arrive here are consumed by the caller and must not be closed
        // through this struct, ever. dupPlanes fills them in below.
        .attrs = emptyPlanes(attrs),
        // SAFETY: assigned from Buffer.init below before the Buffer is
        // reachable from anywhere.
        .buf = undefined,
    };
    errdefer d.attrs.closePlanes();
    try dupPlanes(&d.attrs, &attrs);
    const buf = try Buffer.init(allocator, &dmabuf_impl, d, attrs.width, attrs.height);
    errdefer allocator.destroy(buf);
    d.buf = buf;
    // Tie the two together so a future GBM-side teardown can find the
    // buffer from the bo without a lookup (the pattern the wlroots GBM
    // allocator uses for its own bo bookkeeping).
    c.gbm_bo_set_user_data(bo, d, null);
    return buf;
}

/// The layout of `src` with every descriptor cleared: a wrapper starts
/// from this and owns nothing until dupPlanes fills it.
fn emptyPlanes(src: Attributes) Attributes {
    var copy = src;
    var p: usize = 0;
    while (p < max_planes) : (p += 1) copy.planes[p].fd = -1;
    copy.n_planes = 0;
    return copy;
}

/// Fill `dst` with `dst`'s OWN descriptors for the planes of `src`, with
/// the same offsets and strides. `src`'s fds are untouched: they belong
/// to whoever produced them and are closed elsewhere, which is what
/// keeps a wrapper's teardown from closing a descriptor number the client
/// (or the bo) still owns.
///
/// A failure part way through closes the duplicates already made, so no
/// descriptor escapes this call.
fn dupPlanes(dst: *Attributes, src: *const Attributes) error{OutOfMemory}!void {
    errdefer dst.closePlanes();
    var made: u8 = 0;
    while (made < src.n_planes) : (made += 1) {
        dst.planes[made] = .{
            .fd = try dupFd(src.planes[made].fd),
            .offset = src.planes[made].offset,
            .stride = src.planes[made].stride,
        };
        dst.n_planes = made + 1;
    }
}

// ---------------------------------------------------------------------------
// CPU access to an imported bo
// ---------------------------------------------------------------------------

/// A writable CPU mapping of an imported bo's pixels, from
/// `beginWrite`, valid until the matching `endWrite`.
pub const CpuWrite = struct {
    /// First byte of the first row. Writable for as long as the
    /// mapping is held.
    ptr: [*]u8,
    /// Row pitch of the MAPPING in bytes. This is not the stride the
    /// client claimed in `add`: a bo GBM cannot map in place is staged
    /// in a buffer of the driver's choosing, so a copy that stepped
    /// rows by the claimed stride would shear every row after the
    /// first.
    stride: usize,
    /// GBM's per-mapping token; `endWrite` hands it back.
    map_data: ?*anyopaque,
};

/// Map the whole of `buf`'s pixels for CPU writing, or null when the
/// driver will not map it. The caller answers with its own failure (a
/// screencopy frame, in this compositor's case) rather than writing
/// through nothing.
///
/// Precondition: `buf` is a Buffer this module imported (the bo comes
/// from the impl's own data, so a Buffer from another factory is not
/// a thing this may be handed).
///
/// # Constraints this relies on
/// - This is explicit screencopy access, never the native texture path.
///   GBM may map a linear destination in place or stage a tiled one; the
///   caller must use the returned mapping stride and unmap after writing.
/// - The caller must already know the format: rows are
///   `width * bytes_per_pixel`, and nothing here checks that the
///   mapping is tall enough for them. The screencopy destination path
///   does (the `map.stride < row_len` guard there).
///
/// Mesa's gbm_bo_map may satisfy a bo it cannot map in place with a
/// staging buffer (gbm.h, "gbm_bo_map"); the write-back then happens
/// inside gbm_bo_unmap, which is why `endWrite` must run after the
/// writes.
pub fn beginWrite(buf: *Buffer) ?CpuWrite {
    const bo = dmabufData(buf).bo;
    var stride: u32 = 0;
    var map_data: ?*anyopaque = null;
    const ptr = c.gbm_bo_map(
        bo,
        0,
        0,
        c.gbm_bo_get_width(bo),
        c.gbm_bo_get_height(bo),
        @intCast(c.GBM_BO_TRANSFER_WRITE),
        &stride,
        &map_data,
    ) orelse return null;
    return .{
        .ptr = @ptrCast(ptr),
        .stride = @intCast(stride),
        .map_data = map_data,
    };
}

/// Hand a mapping back. Every successful `beginWrite` needs exactly
/// one of these, AFTER the writes: for a staged mapping gbm_bo_unmap
/// is what copies the pixels into the bo, so an early return loses
/// them.
pub fn endWrite(buf: *Buffer, map: CpuWrite) void {
    c.gbm_bo_unmap(dmabufData(buf).bo, map.map_data);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The DRM node the hardware test opens. A render node is preferred for
/// allocation; backend/drm.zig resolves the same way from the KMS fd.
const render_node = "/dev/dri/renderD128";

/// A memfd of exactly `size` zero bytes, standing in for the client's
/// dmabuf: the bounds checks lseek its length, which is exactly what they
/// need. ftruncate gives the right size and a sparse zero-filled object.
fn fakeObject(size: usize) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("dmabuf-test", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    _ = std.os.linux.ftruncate(fd, @intCast(size));
    return fd;
}

/// A single-plane 64x64 XRGB8888 set backed by an object of `size` bytes.
fn singlePlaneSet(size: usize) !Attributes {
    var attrs: Attributes = .{
        .width = 64,
        .height = 64,
        .format = drm_format_xrgb8888,
        .modifier = drm_format_mod_linear,
        .planes = [_]Plane{.{}} ** max_planes,
        .n_planes = 1,
    };
    attrs.planes[0] = .{ .fd = try fakeObject(size), .offset = 0, .stride = 256 };
    return attrs;
}

const supported_pairs = [_]Format{
    .{ .format = drm_format_xrgb8888, .modifier = drm_format_mod_linear },
    .{ .format = drm_format_argb8888, .modifier = drm_format_mod_linear },
};

test "validate accepts a well-formed single-plane buffer" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    try validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs);
    // The same request with the y_invert hint set is legal too: the flag is
    // known, we just do not consume it yet.
    try validate(&attrs, 64, 64, drm_format_xrgb8888, 1, &supported_pairs);
}

test "validate rejects an empty plane set as incomplete" {
    var attrs: Attributes = .{};
    defer attrs.closePlanes();
    try testing.expectError(
        error.Incomplete,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects a missing plane 0 as incomplete" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    // A set that only has plane 1: n_planes counts it, plane 0 is missing.
    attrs.planes[0] = .{};
    attrs.planes[1] = attrs.planes[1];
    attrs.planes[1] = .{ .fd = try fakeObject(256 * 64), .offset = 0, .stride = 256 };
    attrs.n_planes = 1;
    try testing.expectError(
        error.Incomplete,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects a gap in the plane indices as incomplete" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    // planes 0 and 2, nothing at 1.
    attrs.planes[2] = .{ .fd = try fakeObject(256 * 64), .offset = 0, .stride = 256 };
    attrs.n_planes = 2;
    try testing.expectError(
        error.Incomplete,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects unknown flag bits as invalid_format" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    // Bit 3 is not defined by linux-dmabuf-v1.xml:268-272.
    try testing.expectError(
        error.InvalidFormat,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 8, &supported_pairs),
    );
    // Every defined bit is fine.
    try validate(&attrs, 64, 64, drm_format_xrgb8888, known_flags, &supported_pairs);
}

test "validate rejects a non-positive dimension as invalid_dimensions" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    try testing.expectError(
        error.InvalidDimensions,
        validate(&attrs, 0, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
    try testing.expectError(
        error.InvalidDimensions,
        validate(&attrs, 64, -1, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects an unadvertised format as invalid_format" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    // A fourcc we never advertised.
    try testing.expectError(
        error.InvalidFormat,
        validate(&attrs, 64, 64, drm_format_argb2101010, 0, &supported_pairs),
    );
}

test "validate rejects an unadvertised modifier for an advertised format as invalid_format" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    attrs.modifier = 0x0100_0000_0000_0002; // a tiled NVIDIA modifier
    try testing.expectError(
        error.InvalidFormat,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects an offset past the end of the object as out_of_bounds" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    attrs.planes[0].offset = 256 * 64;
    try testing.expectError(
        error.OutOfBounds,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects a zero stride as out_of_bounds" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    attrs.planes[0].stride = 0;
    try testing.expectError(
        error.OutOfBounds,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects stride times height past the end of the object as out_of_bounds" {
    // Object holds 8 rows; the buffer claims 64.
    var attrs = try singlePlaneSet(256 * 8);
    defer attrs.closePlanes();
    try testing.expectError(
        error.OutOfBounds,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects a size that overflows a 32-bit offset as out_of_bounds" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    // stride * height alone is far past 2^32, so the check must fire
    // before the lseek comparison can be reached with a wrapped value.
    attrs.planes[0].stride = std.math.maxInt(u32);
    try testing.expectError(
        error.OutOfBounds,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects a stride wider than the GBM import struct can carry" {
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    attrs.planes[0].stride = @as(u32, std.math.maxInt(i32)) + 1;
    try testing.expectError(
        error.OutOfBounds,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &supported_pairs),
    );
}

test "validate rejects a format no device advertises when the set is empty" {
    // The empty set is what makes a Device not live; nothing can pass.
    var attrs = try singlePlaneSet(256 * 64);
    defer attrs.closePlanes();
    try testing.expectError(
        error.InvalidFormat,
        validate(&attrs, 64, 64, drm_format_xrgb8888, 0, &.{}),
    );
    try testing.expect(!supports(&.{}, drm_format_xrgb8888, drm_format_mod_linear));
    try testing.expect(supports(&supported_pairs, drm_format_argb8888, drm_format_mod_linear));
    // The pair must match on BOTH halves: right format, wrong modifier is
    // not a hit.
    try testing.expect(!supports(
        &supported_pairs,
        drm_format_argb8888,
        drm_format_mod_invalid,
    ));
}

test "closePlanes closes every fd once and forgets them" {
    var attrs = try singlePlaneSet(256 * 64);
    attrs.planes[1] = .{ .fd = try fakeObject(256), .offset = 0, .stride = 256 };
    attrs.n_planes = 2;
    attrs.closePlanes();
    try testing.expectEqual(@as(u8, 0), attrs.n_planes);
    for (attrs.planes) |plane| try testing.expectEqual(@as(std.posix.fd_t, -1), plane.fd);
    // A second call must be a no-op, not a double close of recycled fds.
    attrs.closePlanes();
    for (attrs.planes) |plane| try testing.expectEqual(@as(std.posix.fd_t, -1), plane.fd);
}

test "a retained description exports working descriptors of its own" {
    // What an imported buffer hands back through get_dmabuf is the whole
    // point of dupPlanes: real descriptor numbers, real strides and a
    // real plane count, owned by the wrapper. A description whose fds are
    // -1 and whose n_planes is 0 describes nothing - no renderer can
    // import it, and a single-plane consumer rejects it outright.
    var src = try singlePlaneSet(256 * 64);
    defer src.closePlanes();
    src.planes[1] = .{ .fd = try fakeObject(256 * 16), .offset = 64, .stride = 128 };
    src.n_planes = 2;

    var dst = emptyPlanes(src);
    try dupPlanes(&dst, &src);
    try testing.expectEqual(@as(u8, 2), dst.n_planes);
    // Same layout, different descriptors: sharing one would make the
    // wrapper's teardown close the bo's or the caller's handle.
    try testing.expect(dst.planes[0].fd != src.planes[0].fd);
    try testing.expect(dst.planes[1].fd != src.planes[1].fd);
    for (0..2) |i| {
        try testing.expectEqual(src.planes[i].offset, dst.planes[i].offset);
        try testing.expectEqual(src.planes[i].stride, dst.planes[i].stride);
        try testing.expect(dst.planes[i].fd >= 0);
    }
    // Each retained descriptor still names its own object, so a consumer
    // can map, export or re-import from it.
    try testing.expectEqual(@as(?u64, 256 * 64), planeSize(dst.planes[0].fd));
    try testing.expectEqual(@as(?u64, 256 * 16), planeSize(dst.planes[1].fd));

    // Tearing the wrapper down closes only its own duplicates: the source
    // objects survive, which is what makes a late Buffer.destroy safe
    // after the client has gone.
    dst.closePlanes();
    try testing.expectEqual(@as(?u64, 256 * 64), planeSize(src.planes[0].fd));
    try testing.expectEqual(@as(?u64, 256 * 16), planeSize(src.planes[1].fd));
    // And the closed numbers must not be closed again through the source.
    dst.closePlanes();
    try testing.expectEqual(@as(?u64, 256 * 64), planeSize(src.planes[0].fd));
}

test "planeSize reads the object length and tolerates a non-seekable fd" {
    const fd = try fakeObject(4096);
    defer _ = std.os.linux.close(fd);
    try testing.expectEqual(@as(?u64, 4096), planeSize(fd));
    // A pipe is not seekable: the bounds checks must skip, not fail.
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.posix.system.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
        &fds,
    );
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(rc));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);
    try testing.expectEqual(@as(?u64, null), planeSize(fds[0]));
}

test "a Device with no formats is not live" {
    const Empty = struct {
        fn main_device(ptr: *anyopaque) u64 {
            _ = ptr;
            return 0;
        }
        fn formats(ptr: *anyopaque) []const Format {
            _ = ptr;
            return &.{};
        }
        fn import(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            attrs_in: Attributes,
        ) error{ OutOfMemory, ImportFailed }!*Buffer {
            _ = ptr;
            _ = allocator;
            var attrs = attrs_in;
            attrs.closePlanes();
            return error.ImportFailed;
        }
        const vtable = Device.VTable{
            .main_device = main_device,
            .formats = formats,
            .import_buffer = import,
        };
    };
    var sink: u8 = 0;
    const dev = Device{ .ptr = @ptrCast(&sink), .vtable = &Empty.vtable };
    try testing.expect(!dev.isLive());
    try testing.expectEqual(@as(u64, 0), dev.mainDevice());
}

test "a real GBM device imports a real dmabuf (skipped without a DRM node)" {
    // The one test that needs hardware. It is a SKIP, never a failure, on a
    // machine with no render node: everything above proves the validation
    // and the wire contract, but only a real driver proves that
    // gbm_bo_import accepts a client's dma-buf and that the bo we get back
    // describes the buffer we asked for.
    const dev = GbmDevice.create(testing.allocator, render_node) catch {
        return error.SkipZigTest;
    };
    defer dev.deinit();
    // Ask the device what it accepts rather than guessing: this is the
    // same query backend/drm.zig's queryGbmFormats runs.
    const format = drm_format_xrgb8888;
    const plane_count = c.gbm_device_get_format_modifier_plane_count(dev.device, format, drm_format_mod_linear);
    if (plane_count < 1) return error.SkipZigTest;
    // setFormats takes ownership; deinit frees it.
    dev.setFormats(try testing.allocator.dupe(Format, &.{.{ .format = format, .modifier = drm_format_mod_linear }}));
    try testing.expect(dev.iface.isLive());

    // Allocate the object we will hand to the importer, exactly as a
    // client would, then import our own copy of its fd.
    // gbm_bo_create, not gbm_bo_create_with_modifiers: the nvidia backend
    // faults on the modifiers-array form, and a LINEAR allocation is what
    // a client can always make anyway.
    const src = c.gbm_bo_create(dev.device, 64, 64, format, c.GBM_BO_USE_LINEAR) orelse
        return error.SkipZigTest;
    defer c.gbm_bo_destroy(src);
    const plane_fd = c.gbm_bo_get_fd_for_plane(src, 0);
    if (plane_fd < 0) return error.SkipZigTest;
    defer _ = std.os.linux.close(plane_fd);

    var attrs: Attributes = .{
        .width = 64,
        .height = 64,
        .format = format,
        .modifier = drm_format_mod_linear,
        .n_planes = 1,
    };
    attrs.planes[0] = .{
        .fd = try dupFd(plane_fd),
        .offset = c.gbm_bo_get_offset(src, 0),
        .stride = c.gbm_bo_get_stride_for_plane(src, 0),
    };
    defer attrs.closePlanes();

    try validate(&attrs, 64, 64, format, 0, dev.formats);
    // A driver may still refuse the import (a busy device, a format it
    // cannot map). That is the ImportFailed the protocol turns into the
    // `failed` event, not a bug here, so skip rather than fail.
    const buf = dev.iface.import(testing.allocator, attrs) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ImportFailed => return error.SkipZigTest,
    };
    defer Buffer.destroy(buf);

    // The wrapper is a real compositor Buffer of the right size, and the
    // attributes the renderer would read back describe the same object.
    try testing.expectEqual(@as(i32, 64), buf.width);
    try testing.expectEqual(@as(i32, 64), buf.height);
    const d = dmabufData(buf);
    try testing.expectEqual(format, d.attrs.format);
    try testing.expectEqual(drm_format_mod_linear, d.attrs.modifier);
    try testing.expectEqual(@as(u32, attrs.planes[0].stride), d.attrs.planes[0].stride);
    // The exported description must be usable on its own: the renderer
    // and the scanout allocator take descriptors from here, and a
    // single-plane consumer (screencopy's dmabuf destination) rejects
    // anything that does not carry its plane count and descriptors.
    try testing.expectEqual(@as(u8, 1), d.attrs.n_planes);
    try testing.expect(d.attrs.planes[0].fd >= 0);
    // Ours, not the caller's: the same number closed twice would take the
    // bo's own export down with it.
    try testing.expect(d.attrs.planes[0].fd != attrs.planes[0].fd);
    // gbm_bo_set_user_data tied the two together.
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(d)), c.gbm_bo_get_user_data(d.bo));
    // A dmabuf has no CPU pointer, so the impl must not pretend otherwise.
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&d.attrs)), buf.impl.get_dmabuf.?(buf));
    try testing.expect(buf.impl.begin_data_ptr_access == null);

    // The CPU write path, end to end on a real bo: map it, write a
    // distinct pattern into every pixel, unmap, then map again and
    // read it all back. This is the round trip the screencopy dmabuf
    // destination depends on, and the only part of it a driver can
    // break — a bo it will not map, or a staged mapping that never
    // comes back. A driver that refuses is a skip, like the import
    // above, not a failure: the copy path turns a null mapping into a
    // `failed` event, which is the contract, not an error.
    const write = beginWrite(buf) orelse return error.SkipZigTest;
    var y: usize = 0;
    while (y < 64) : (y += 1) {
        var x: usize = 0;
        while (x < 64) : (x += 1) {
            const at = y * write.stride + x * 4;
            write.ptr[at] = @truncate(x);
            write.ptr[at + 1] = @truncate(y);
            write.ptr[at + 2] = 0x5a;
            write.ptr[at + 3] = 0xa5;
        }
    }
    endWrite(buf, write);

    const read = beginWrite(buf) orelse return error.SkipZigTest;
    defer endWrite(buf, read);
    try testing.expect(read.stride >= 64 * 4);
    y = 0;
    while (y < 64) : (y += 1) {
        var x: usize = 0;
        while (x < 64) : (x += 1) {
            const at = y * read.stride + x * 4;
            try testing.expectEqual(@as(u8, @truncate(x)), read.ptr[at]);
            try testing.expectEqual(@as(u8, @truncate(y)), read.ptr[at + 1]);
            try testing.expectEqual(@as(u8, 0x5a), read.ptr[at + 2]);
            try testing.expectEqual(@as(u8, 0xa5), read.ptr[at + 3]);
        }
    }
}
