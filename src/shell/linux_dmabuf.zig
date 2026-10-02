//! zwp_linux_dmabuf_v1 (stable/linux-dmabuf): the factory that turns
//! client dmabuf fds into wl_buffers the compositor can present.
//!
//! # The global is a promise, so it is gated on a device
//! A client that binds this global and cannot create a single buffer has
//! lost a roundtrip and a fallback to shm for nothing. The global is
//! therefore registered only when `init` is handed a live `dmabuf.Device`
//! (a device that advertises at least one format/modifier pair). With no
//! device the module still exists — it just has no global, and
//! `LinuxDmabuf.global` stays null. The DRM backend produces the device
//! (`src/backend/drm.zig`, `DrmBackendData.gbmDevice`); headless, raylib
//! and nested-wayland backends have none, and the server passes null.
//!
//! # Version divergence from wlroots 0.20.2
//! wlroots registers this global at version 5
//! (`#define LINUX_DMABUF_VERSION 5`,
//! types/wlr_linux_dmabuf_v1.c:24). The vendored XML declares version 6
//! and build.zig generates 6, so this server registers 6. The two extra
//! versions are handled, not ignored:
//!   - v6 `sampling` tranche flag: the tranche we advertise carries it
//!     (the XML *requires* at least one sampling tranche from v6 on,
//!     :447-449). Below v6 the flag is not sent at all, because the enum
//!     entry is `since="6"` (:607) and a client that does not know a bit
//!     must not be told it is set.
//!   - v6 `set_sampling_device`: recorded, not obeyed — see
//!     `Params.sampling_device`.
//! Everything below v4 (the `format`/`modifier` events) is version-gated
//! in `dmabufBind`; the v4+ feedback objects in `sendFeedback`.
//!
//! # What is NOT implemented
//! - `y_invert` / `interlaced` / `bottom_first` are accepted and ignored.
//!   The XML explicitly recommends rejecting interlaced buffers outright
//!   (:314-315) and says the result of an interlaced buffer is undefined;
//!   this compositor has no field-aware path, so ignoring is the honest
//!   behaviour and is documented on `Params`.
//! - `get_surface_feedback` sends the same parameters as
//!   `get_default_feedback`. Per-surface (per-output) dmabuf feedback
//!   needs an output-side capability query this compositor does not have
//!   yet; the object is inert after creation either way, because the XML
//!   only requires the parameters to be sent once.
//! - `DRM_FORMAT_MOD_INVALID` is never advertised. We hand GBM the exact
//!   layout the client claims and validate that claim, so an implicit
//!   layout would be a promise we cannot keep.
//!
//! # Buffer lifetime
//! `create` / `create_immed` produce a `wl_buffer` resource plus a
//! `buffer.Buffer` wrapper (buffers/buffer.zig). The wrapper is owned by
//! this module: `buffers` is the live set, `dead_buffers` the graveyard
//! for wrappers whose wl_buffer the client already destroyed but which a
//! surface may still hold a lock on. This is the same discipline
//! buffers/shm.zig uses, and for the same reason: freeing a wrapper from
//! inside the resource-destroy signal would be a use-after-free for a
//! surface that still references it.
//!
//! Cross-module contract:
//!   - `init` needs a `*dmabuf.Device` and owns nothing but its own state;
//!     the device belongs to the DRM backend and must outlive deinit.
//!   - `fromResource` is the hook compositor/surface.zig's attach path
//!     needs to resolve a dmabuf wl_buffer (see the note on it).
//!   - `params` owns its plane fds and closes them on every exit.

const std = @import("std");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;
const display_mod = @import("../core/display.zig");
const buffer_mod = @import("../buffers/buffer.zig");
const dmabuf = @import("../buffers/dmabuf.zig");

const zwp = server.zwp;
const Buffer = buffer_mod.Buffer;

const log_tag = "linux_dmabuf";

/// Size of one zwp_linux_dmabuf_feedback_v1 format-table entry: a u32
/// format, 4 bytes of padding, a u64 modifier, tightly packed
/// (linux-dmabuf-v1.xml:474-493, mirrored by wlroots'
/// wlr_linux_dmabuf_feedback_v1_table_entry with a static_assert on
/// sizeof == 16, types/wlr_linux_dmabuf_v1.c:48-55).
const table_entry_size = 16;

pub const LinuxDmabuf = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The import backend. Null when the display has no device, which is
    /// also the condition under which no global is registered.
    device: ?*dmabuf.Device,
    /// The device's advertised pairs, borrowed (the device owns them).
    formats: []const dmabuf.Format = &.{},
    global: ?*wire.Global = null,
    /// The memfd carrying the packed (format, modifier) table every
    /// feedback object points at. Built once, never mutated after the
    /// first send (the XML forbids mutation, :486-490).
    table_fd: std.posix.fd_t = -1,
    table_size: u32 = 0,
    /// Table index of each advertised pair, in table order: the
    /// `tranche_formats` payload.
    indices: []u16 = &.{},
    /// Live dmabuf wl_buffers, keyed by their wl_buffer resource (a
    /// recycled resource pointer must get a fresh wrapper, so the entry
    /// is dropped on resource destruction).
    buffers: std.AutoHashMap(*wire.Resource, *DmabufBuffer) = undefined,
    /// Wrappers whose wl_buffer is gone but which a surface may still
    /// reference; freed by deinit.
    dead_buffers: std.ArrayList(*DmabufBuffer) = .empty,
    /// Fixed-size overflow for the graveyard when its append OOMs: a
    /// wrapper with outstanding consumer locks cannot be freed inside the
    /// destroy signal, so it parks here (no allocation) until deinit. A
    /// full stash leaks — bounded, OOM-only, the same trade shm.zig makes.
    dead_stash: [8]?*DmabufBuffer = [_]?*DmabufBuffer{null} ** 8,
    dead_stash_len: usize = 0,

    pub const InitError = error{ OutOfMemory, FormatTableFailed, GlobalCreateFailed };

    /// Bring the module up. With a live `device` the global is registered
    /// and the feedback format table is built; without one the module is
    /// inert but fully constructed (deinit is still correct, and the
    /// server can log which branch it took).
    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        device: ?*dmabuf.Device,
    ) InitError!*LinuxDmabuf {
        const linux = try allocator.create(LinuxDmabuf);
        errdefer allocator.destroy(linux);
        linux.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .device = blk: {
                if (device) |d| {
                    if (d.isLive()) break :blk @as(?*dmabuf.Device, d);
                }
                break :blk null;
            },
            // SAFETY: the map is initialized with the module's own
            // allocator right here, before any lookup; a struct field
            // default cannot name `allocator`.
            .buffers = std.AutoHashMap(*wire.Resource, *DmabufBuffer).init(allocator),
        };
        if (linux.device) |dev| {
            linux.formats = dev.formats();
            try linux.buildFormatTable();
            linux.global = try display.addGlobal(
                zwp.LinuxDmabufV1,
                *LinuxDmabuf,
                dmabufBind,
                zwp.LinuxDmabufV1.generated_version,
                linux,
            );
            log.info("linux_dmabuf: advertising {d} format/modifier pairs", io, log_cfg, log_tag, .{
                linux.formats.len,
            });
        } else {
            // No device: no global. Say so at info level, because a
            // missing global is exactly the thing a client (and a human
            // reading the log) will ask about.
            log.info("linux_dmabuf: no import device, global not advertised", io, log_cfg, log_tag, .{});
        }
        return linux;
    }

    pub fn deinit(self: *LinuxDmabuf) void {
        const allocator = self.allocator;
        if (self.global) |global| {
            global.remove();
            self.global = null;
        }
        // Destroy the wl_buffers we still own. Each destroy runs
        // bufferResourceDestroy, which takes the entry out of the
        // registry and parks the wrapper, so the iterator restarts from
        // the top every round (shm.zig's deinit shape).
        while (self.buffers.count() > 0) {
            var it = self.buffers.keyIterator();
            const key = (it.next() orelse unreachable).*;
            const state = self.buffers.get(key).?;
            state.res.?.destroy();
        }
        for (self.dead_stash[0..self.dead_stash_len]) |state| state.?.finish();
        self.dead_stash_len = 0;
        for (self.dead_buffers.items) |state| state.finish();
        self.dead_buffers.deinit(allocator);
        self.buffers.deinit();
        allocator.free(self.indices);
        if (self.table_fd >= 0) {
            _ = std.os.linux.close(self.table_fd);
            self.table_fd = -1;
        }
        allocator.destroy(self);
    }

    /// Is the global advertised? The single source of truth for "this
    /// server can import dmabufs" — the tests read it directly.
    pub fn advertised(self: *const LinuxDmabuf) bool {
        return self.global != null;
    }

    /// Resolve a client wl_buffer resource this module created into its
    /// compositor Buffer. Null when the resource is not one of ours.
    ///
    /// This is the hook compositor/surface.zig's `handleAttach` needs:
    /// today that path only asks the SHM registry, so a dmabuf wl_buffer
    /// sent to wl_surface.attach lands on `error.InvalidBuffer` and the
    /// client is killed with "unknown buffer type". Wiring it is:
    ///
    ///     const wrapped = (if (compositor.linux_dmabuf) |ld|
    ///         ld.fromResource(res)) orelse
    ///         (if (compositor.shm) |st| st.fromResource(allocator, res)
    ///          else shm_mod.fromResource(allocator, res)) catch |err| ...;
    ///
    /// which needs compositor.zig to hold the LinuxDmabuf too. That is
    /// outside this module's file set, so it is left to the integration
    /// owner; everything else (the registry, the wrapper, the release
    /// plumbing) is in place and tested here.
    pub fn fromResource(self: *LinuxDmabuf, resource: *wire.Resource) ?*Buffer {
        const state = self.buffers.get(resource) orelse return null;
        return state.buf;
    }

    /// Build the feedback format table: a memfd holding one 16-byte entry
    /// per advertised pair, plus the u16 index of each pair. Built once at
    /// init; the XML allows reusing the same table for every feedback
    /// object as long as it is never mutated (:486-490).
    fn buildFormatTable(self: *LinuxDmabuf) InitError!void {
        if (self.formats.len == 0) return;
        if (self.formats.len > std.math.maxInt(u16)) return error.OutOfMemory;
        const size = self.formats.len * table_entry_size;

        const indices = try self.allocator.alloc(u16, self.formats.len);
        errdefer self.allocator.free(indices);
        for (indices, 0..) |*idx, i| idx.* = @intCast(i);

        const fd = std.posix.memfd_create("wlr-linux-dmabuf-table", std.os.linux.MFD.CLOEXEC) catch
            return error.FormatTableFailed;
        errdefer _ = std.os.linux.close(fd);
        // ftruncate + mmap rather than a write loop: std.posix has no
        // pwrite in Zig 0.16, and the table is written once and never
        // mutated again (the XML forbids mutation, :486-490).
        _ = std.os.linux.ftruncate(fd, @intCast(size));
        const map = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return error.FormatTableFailed;
        defer std.posix.munmap(map);
        for (self.formats, 0..) |f, i| {
            const at = map[i * table_entry_size ..][0..table_entry_size];
            std.mem.writeInt(u32, at[0..4], f.format, .native);
            std.mem.writeInt(u32, at[4..8], 0, .native);
            std.mem.writeInt(u64, at[8..16], f.modifier, .native);
        }
        self.table_fd = fd;
        self.table_size = @intCast(size);
        self.indices = indices;
    }
};

// ---------------------------------------------------------------------------
// Global
// ---------------------------------------------------------------------------

fn dmabufBind(client_wire: *wire.Client, linux: *LinuxDmabuf, version: u32, id: u32) void {
    const res = zwp.LinuxDmabufV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*LinuxDmabuf, dmabufRequest, dmabufDestroy, linux);
    // From v4 on, formats arrive through the feedback objects instead
    // (linux-dmabuf-v1.xml:121-123, :152); sending them as well is
    // explicitly forbidden.
    if (version < zwp.LinuxDmabufV1.Request.get_default_feedback_since_version) {
        sendFormats(res, version, linux.formats);
    }
    log.debug("linux_dmabuf bind v{d}", linux.io, linux.log_cfg, log_tag, .{version});
}

/// The v1-v3 advertisement. wlroots' linux_dmabuf_send_modifiers
/// (:794-818) sends the bare `format` event below v3 only for a format
/// that carries DRM_FORMAT_MOD_INVALID, because before the `modifier`
/// event existed an implicit modifier was the only thing a client could
/// learn. We advertise no implicit modifier, so a v1/v2 client is told
/// nothing — the same answer wlroots gives for any format whose modifier
/// list has no INVALID entry.
fn sendFormats(res: *zwp.LinuxDmabufV1, version: u32, formats: []const dmabuf.Format) void {
    if (version < zwp.LinuxDmabufV1.modifier_since_version) return;
    for (formats) |f| {
        res.sendModifier(f.format, @truncate(f.modifier >> 32), @truncate(f.modifier));
    }
}

fn dmabufRequest(res: *zwp.LinuxDmabufV1, request: zwp.LinuxDmabufV1.Request, linux: *LinuxDmabuf) void {
    switch (request) {
        // XML :93-98: destroying the factory leaves the wl_buffers it
        // created valid, so the destructor only drops this resource.
        .destroy => res.destroy(),
        .create_params => |r| createParams(res, r.params_id),
        .get_default_feedback => |r| feedbackObject(linux, res, r.id),
        .get_surface_feedback => |r| feedbackObject(linux, res, r.id),
    }
}

fn dmabufDestroy(res: *zwp.LinuxDmabufV1, linux: *LinuxDmabuf) void {
    _ = res;
    // The module outlives its per-client factory resources; buffers created
    // through them stay valid (XML :95-97) and are freed by deinit.
    _ = linux;
}

/// Create a zwp_linux_buffer_params_v1 at the factory's bound version, so
/// a params object can never carry a request this server does not decode
/// (the same rule tearing_control.zig follows for its objects).
fn createParams(res: *zwp.LinuxDmabufV1, id: u32) void {
    const linux: *LinuxDmabuf = @ptrCast(@alignCast(res.getUserData().?));
    const params_res = zwp.LinuxBufferParamsV1.create(res.getClient(), res.getVersion(), id) catch {
        res.postNoMemory();
        return;
    };
    const params = linux.allocator.create(Params) catch {
        params_res.destroy();
        res.postNoMemory();
        return;
    };
    params.* = .{
        .allocator = linux.allocator,
        .linux = linux,
        .res = params_res,
    };
    params_res.setHandler(*Params, paramsRequest, paramsDestroy, params);
}

// ---------------------------------------------------------------------------
// zwp_linux_buffer_params_v1
// ---------------------------------------------------------------------------

/// The plane set a client is assembling, plus the bookkeeping that makes
/// the object single-use (XML :328-331).
const Params = struct {
    allocator: std.mem.Allocator,
    /// The module, for the device and the buffer registry.
    linux: *LinuxDmabuf,
    res: *zwp.LinuxBufferParamsV1,
    /// Plane fds collected by `add`; owned by this struct and closed by
    /// deinit (or moved to the importer on create).
    attrs: dmabuf.Attributes = .{},
    /// Set by create/create_immed: the object is spent, and any further
    /// add/create is the `already_used` error (XML :328-331).
    used: bool = false,
    /// v6 set_sampling_device hint, recorded but not obeyed: the XML says
    /// a client that names a device we did not advertise is not a protocol
    /// error, only a likely import failure (:404-411), and we import on
    /// our one device whatever the client asks for.
    sampling_device: ?u64 = null,

    fn deinit(self: *Params) void {
        self.attrs.closePlanes();
        self.allocator.destroy(self);
    }
};

fn paramsRequest(res: *zwp.LinuxBufferParamsV1, request: zwp.LinuxBufferParamsV1.Request, params: *Params) void {
    switch (request) {
        .destroy => res.destroy(),
        .add => |r| paramsAdd(params, r.fd, r.plane_idx, r.offset, r.stride, r.modifier_hi, r.modifier_lo),
        .create => |r| paramsCreate(params, 0, r.width, r.height, r.format, @as(u32, @bitCast(r.flags))),
        .create_immed => |r| paramsCreate(
            params,
            r.buffer_id,
            r.width,
            r.height,
            r.format,
            @as(u32, @bitCast(r.flags)),
        ),
        .set_sampling_device => |r| paramsSetSamplingDevice(params, r.device),
    }
}

/// paramsDestroy also runs for a params object that was never used, and
/// for one whose user data the create path already took away, so the
/// `used` flag is the only state a create leaves behind.
fn paramsDestroy(res: *zwp.LinuxBufferParamsV1, params: *Params) void {
    _ = res;
    params.deinit();
}

fn paramsAdd(
    params: *Params,
    raw_fd: i32,
    plane_idx: u32,
    offset: u32,
    stride: u32,
    modifier_hi: u32,
    modifier_lo: u32,
) void {
    const res = params.res;
    // The fd is ours the moment the message is decoded: libwayland does
    // not take ownership, so every rejection below has to close it
    // (wlroots params_add, :149-198, closes on each of its four paths).
    const fd: std.posix.fd_t = raw_fd;
    if (params.used) {
        _ = std.os.linux.close(fd);
        res.postError(.already_used, "params was already used to create a wl_buffer");
        return;
    }
    if (plane_idx >= dmabuf.max_planes) {
        _ = std.os.linux.close(fd);
        res.postError(.plane_idx, "plane index out of bounds");
        return;
    }
    if (params.attrs.planes[plane_idx].fd >= 0) {
        _ = std.os.linux.close(fd);
        res.postError(.plane_set, "this plane index was already set");
        return;
    }
    const modifier = (@as(u64, modifier_hi) << 32) | @as(u64, modifier_lo);
    // All planes must describe the same layout (XML :251-252 from v5;
    // wlroots enforces it on every version, :181-189).
    if (params.attrs.n_planes > 0 and modifier != params.attrs.modifier) {
        _ = std.os.linux.close(fd);
        res.postError(.invalid_format, "all planes must use the same modifier");
        return;
    }
    params.attrs.modifier = modifier;
    params.attrs.planes[plane_idx] = .{ .fd = fd, .offset = offset, .stride = stride };
    params.attrs.n_planes += 1;
}

fn paramsSetSamplingDevice(params: *Params, device: *server.wl.Array) void {
    // The payload is a wire array; copy the dev_t out before returning,
    // the message buffer does not outlive this call.
    const raw = device.slice(u64)[0..];
    if (raw.len != 1) {
        params.res.postError(
            .invalid_dev_t_size,
            "set_sampling_device carries exactly one dev_t",
        );
        return;
    }
    params.sampling_device = raw[0];
}

/// `buffer_id` is 0 for the asynchronous `create` (the XML carries the
/// new id in the `created` event) and the client's own id for
/// `create_immed`. That difference is the whole of the failure-reporting
/// split: `create` answers a failed import with the `failed` event,
/// `create_immed` with a fatal invalid_wl_buffer (XML :75-83; wlroots
/// params_create_common :383-396).
fn paramsCreate(
    params: *Params,
    buffer_id: u32,
    width: i32,
    height: i32,
    format: u32,
    raw_flags: u32,
) void {
    const res = params.res;
    if (params.used) {
        res.postError(.already_used, "params was already used to create a wl_buffer");
        return;
    }
    params.used = true;

    const linux = params.linux;
    const device = linux.device orelse {
        // Unreachable: a client can only hold a params object if it bound
        // the global, and the global only exists with a device. Guarded
        // anyway so a future caller cannot import through a null device.
        if (buffer_id == 0) res.sendFailed() else res.postError(.invalid_wl_buffer, "no import device");
        return;
    };

    dmabuf.validate(&params.attrs, width, height, format, raw_flags, linux.formats) catch |err| {
        postValidationError(res, err);
        return;
    };

    // The plane set alone does not describe the buffer: the create
    // request's width/height/format join it (wlroots
    // params_create_common :285-287). Without this the Buffer the
    // importer builds has a zero size and wl_surface.commit rejects it
    // with invalid_size.
    var attrs = params.attrs;
    params.attrs = .{};
    attrs.width = width;
    attrs.height = height;
    attrs.format = format;

    const buf = device.import(linux.allocator, attrs) catch |err| switch (err) {
        error.OutOfMemory => {
            res.postNoMemory();
            return;
        },
        error.ImportFailed => {
            if (buffer_id == 0) {
                res.sendFailed();
            } else {
                // XML :386-387: for create_immed the protocol leaves the
                // choice to the compositor. We treat an unknown import
                // failure as fatal rather than handing the client a
                // wl_buffer that is guaranteed to be useless (wlroots
                // makes the same choice, :388-395).
                res.postError(.invalid_wl_buffer, "importing the supplied dmabufs failed");
            }
            return;
        },
    };
    // The registry owns the wrapper, so `tracked` stays true: the surface
    // only ever destroys UNtracked wrappers (surface.zig:430, :617), and
    // LinuxDmabuf.deinit is the single place the wrapper is freed.

    const client_wire = res.getClient();
    const wl_buffer = server.wl.Buffer.create(client_wire, 1, buffer_id) catch {
        Buffer.destroy(buf);
        res.postNoMemory();
        return;
    };
    const state = linux.allocator.create(DmabufBuffer) catch {
        wl_buffer.destroy();
        Buffer.destroy(buf);
        res.postNoMemory();
        return;
    };
    state.* = .{
        .allocator = linux.allocator,
        .linux = linux,
        .res = wl_buffer,
        .buf = buf,
        .release = wire.Listener(*Buffer).init(onBufferRelease),
    };
    wl_buffer.setHandler(*DmabufBuffer, wlBufferRequest, bufferResourceDestroy, state);
    linux.buffers.put(@ptrCast(wl_buffer), state) catch {
        state.release.link.remove();
        linux.allocator.destroy(state);
        wl_buffer.destroy();
        Buffer.destroy(buf);
        res.postNoMemory();
        return;
    };
    // The client may reuse this wl_buffer after every release, and each
    // lock cycle re-arms the release (buffers/buffer.zig).
    buf.events.release.add(&state.release);

    log.debug("linux_dmabuf: {d}x{d} format 0x{x} modifier 0x{x} imported", linux.io, linux.log_cfg, log_tag, .{
        width,
        height,
        format,
        attrs.modifier,
    });

    if (buffer_id == 0) res.sendCreated(wl_buffer);
}

/// Each rejection from `dmabuf.validate` maps onto exactly one error in
/// the XML's enum (linux-dmabuf-v1.xml:207-227); see buffers/dmabuf.zig
/// for why a bad modifier is invalid_format and a bad stride or offset is
/// out_of_bounds.
fn postValidationError(res: *zwp.LinuxBufferParamsV1, err: dmabuf.ValidationError) void {
    switch (err) {
        error.Incomplete => res.postError(.incomplete, "no dmabuf has been added for every plane"),
        error.InvalidFormat => res.postError(
            .invalid_format,
            "the format and modifier pair was not advertised, or a flag is unknown",
        ),
        error.InvalidDimensions => res.postError(.invalid_dimensions, "width and height must be positive"),
        error.OutOfBounds => res.postError(.out_of_bounds, "offset plus stride times height is out of bounds"),
    }
}

// ---------------------------------------------------------------------------
// The wl_buffer the params object produces
// ---------------------------------------------------------------------------

/// Per-wl_buffer state: the wire resource, the compositor Buffer and the
/// listener that answers the Buffer's release signal with
/// wl_buffer.release.
const DmabufBuffer = struct {
    allocator: std.mem.Allocator,
    linux: *LinuxDmabuf,
    /// The client wl_buffer; null once the client destroyed it.
    res: ?*server.wl.Buffer,
    buf: *Buffer,
    release: wire.Listener(*Buffer),

    /// Free the wrapper and the Buffer. Only legal from deinit: the
    /// Buffer may still be referenced by a surface, and Buffer.destroy
    /// emits a signal, so it must not run inside a destroy handler.
    fn finish(self: *DmabufBuffer) void {
        self.release.link.remove();
        Buffer.destroy(self.buf);
        self.allocator.destroy(self);
    }
};

fn wlBufferRequest(res: *server.wl.Buffer, request: server.wl.Buffer.Request, _: *DmabufBuffer) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

/// The client destroyed the wl_buffer resource. The Buffer itself lives
/// on: a surface may still hold a lock on it, and the backing gbm_bo must
/// stay valid until then (the same graveyard discipline as
/// buffers/shm.zig's resourceDestroy).
fn bufferResourceDestroy(res: *server.wl.Buffer, state: *DmabufBuffer) void {
    const linux = state.linux;
    _ = res;
    // Remove the registry entry first: libwayland recycles freed resource
    // memory, and a recycled pointer must resolve to a fresh wrapper.
    _ = linux.buffers.remove(@ptrCast(@as(*server.wl.Buffer, @ptrCast(state.res.?))));
    // Invalidate before the graveyard append: if the append OOMs the
    // wrapper is unreachable and must not keep pointing at the freed
    // client resource.
    state.res = null;
    if (!state.buf.dropped) state.buf.drop();

    linux.dead_buffers.append(linux.allocator, state) catch {
        if (state.buf.n_locks == 0) {
            // Safe inside the destroy signal: nothing else runs in this
            // emission for this wrapper, and the surface-side listeners
            // that follow only compare resource pointers.
            state.finish();
        } else if (linux.dead_stash_len < linux.dead_stash.len) {
            linux.dead_stash[linux.dead_stash_len] = state;
            linux.dead_stash_len += 1;
        }
        // Stash full: the wrapper leaks at deinit (bounded, OOM-only).
    };
}

/// The compositor is done with the buffer (dropped && n_locks == 0): tell
/// the client it may reuse it. Only while the resource is alive.
fn onBufferRelease(listener: *wire.Listener(*Buffer), buf: *Buffer) void {
    _ = buf;
    const state: *DmabufBuffer = @fieldParentPtr("release", listener);
    if (state.res) |r| r.sendRelease();
}

// ---------------------------------------------------------------------------
// zwp_linux_dmabuf_feedback_v1 (v4+)
// ---------------------------------------------------------------------------

/// Create a feedback object and send the full parameter set to it: the
/// format table, then one tranche, then `done` (XML :423-454).
///
/// `get_surface_feedback` is answered from the same table: this
/// compositor has no per-output dmabuf capability query, so a
/// per-surface object carries the same (correct, if not optimally
/// specific) advice as the default one. The object is inert after this —
/// the XML only requires the parameters once (:430-434).
fn feedbackObject(linux: *LinuxDmabuf, res: *zwp.LinuxDmabufV1, id: u32) void {
    const version = res.getVersion();
    const fb = zwp.LinuxDmabufFeedbackV1.create(res.getClient(), version, id) catch {
        res.postNoMemory();
        return;
    };
    fb.setHandler(*LinuxDmabuf, feedbackRequest, null, linux);

    // The table must be sent before any tranche (XML :451-454).
    fb.sendFormatTable(linux.table_fd, linux.table_size);
    const main_dev = linux.device.?.mainDevice();
    if (version < zwp.LinuxDmabufFeedbackV1.TrancheFlags.sampling_since_version) {
        // main_device is deprecated in v6 and must not be sent then
        // (XML :520-522).
        const dev = [_]u64{main_dev};
        var dev_arr = arrayOf(u64, dev[0..]);
        fb.sendMainDevice(&dev_arr);
    }
    const target = [_]u64{main_dev};
    var target_arr = arrayOf(u64, target[0..]);
    fb.sendTrancheTargetDevice(&target_arr);
    // Exactly one tranche: our device both samples what it imports and is
    // the only thing we can hand to the KMS plane, but direct scan-out of
    // an imported buffer is not implemented, so the `scanout` hint is not
    // set. The `sampling` bit only exists from v6 on (:607-614).
    fb.sendTrancheFlags(if (version >= zwp.LinuxDmabufFeedbackV1.TrancheFlags.sampling_since_version)
        .{ .sampling = true }
    else
        .{});
    var idx_arr = arrayOf(u16, linux.indices);
    fb.sendTrancheFormats(&idx_arr);
    fb.sendTrancheDone();
    fb.sendDone();
}

fn feedbackRequest(res: *zwp.LinuxDmabufFeedbackV1, request: zwp.LinuxDmabufFeedbackV1.Request, _: *LinuxDmabuf) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

/// A wl_array view over `items`, valid for the duration of the postEvent:
/// the wire protocol copies the contents synchronously
/// (zig-wayland's common.Array, common_core.zig:194-214).
fn arrayOf(comptime T: type, items: []const T) server.wl.Array {
    return .{
        .size = items.len * @sizeOf(T),
        .alloc = items.len * @sizeOf(T),
        .data = @constCast(items.ptr),
    };
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same shape as
// shell/tearing_control.zig).
// ---------------------------------------------------------------------------

const testing = std.testing;
const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");
const surface_mod = @import("../compositor/surface.zig");

/// A CPU-backed stand-in for a GBM device. The production implementation
/// needs a DRM node; the protocol module must be provable without one, and
/// "the global is advertised only with a live device" is a claim about the
/// module, not about GBM. This double advertises a fixed format set and
/// turns an import into a plain Buffer, recording what it was handed.
const FakeDevice = struct {
    formats: []const dmabuf.Format,
    /// How many imports reached us (valid or not).
    imports: u32 = 0,
    /// Make the next import fail the way a driver rejection does.
    fail_next: bool = false,
    /// The interface view. `ptr` is filled in by `device`, because it must
    /// be this struct's own address.
    iface: dmabuf.Device = undefined,

    const FakeData = struct {
        width: i32,
        height: i32,
    };

    const impl: buffer_mod.Impl = .{
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = null,
        .end_data_ptr_access = null,
        .destroy = fakeDestroy,
    };

    fn fakeDestroy(allocator: std.mem.Allocator, data: *anyopaque) void {
        const d: *FakeData = @ptrCast(@alignCast(data));
        allocator.destroy(d);
    }

    fn mainDevice(ptr: *anyopaque) u64 {
        _ = ptr;
        // An arbitrary but stable dev_t; the tests only check it survives
        // the round trip.
        return 0x1234_5678;
    }

    fn formatsOf(ptr: *anyopaque) []const dmabuf.Format {
        const self: *FakeDevice = @ptrCast(@alignCast(ptr));
        return self.formats;
    }

    fn importFn(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        attrs_in: dmabuf.Attributes,
    ) error{ OutOfMemory, ImportFailed }!*Buffer {
        const self: *FakeDevice = @ptrCast(@alignCast(ptr));
        self.imports += 1;
        // The plane fds are ours on entry: a real importer closes them on
        // failure and once the bo owns the object.
        var attrs = attrs_in;
        defer attrs.closePlanes();
        if (self.fail_next) return error.ImportFailed;
        const d = try allocator.create(FakeData);
        errdefer allocator.destroy(d);
        d.* = .{ .width = attrs.width, .height = attrs.height };
        return Buffer.init(allocator, &impl, d, attrs.width, attrs.height);
    }

    const vtable = dmabuf.Device.VTable{
        .main_device = mainDevice,
        .formats = formatsOf,
        .import_buffer = importFn,
    };

    fn init(formats: []const dmabuf.Format) FakeDevice {
        return .{ .formats = formats, .iface = .{ .ptr = undefined, .vtable = &vtable } };
    }

    fn device(self: *FakeDevice) *dmabuf.Device {
        self.iface.ptr = self;
        return &self.iface;
    }
};

/// The pairs the fake advertises: one per candidate fourcc, linear only.
const fake_formats = [_]dmabuf.Format{
    .{ .format = dmabuf.drm_format_xrgb8888, .modifier = dmabuf.drm_format_mod_linear },
    .{ .format = dmabuf.drm_format_argb8888, .modifier = dmabuf.drm_format_mod_linear },
};

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    dmabuf_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "zwp_linux_dmabuf_v1")) {
                    data.dmabuf_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// What a client saw on its zwp_linux_dmabuf_v1.
const GlobalCapture = struct {
    formats: u32 = 0,
    modifiers: u32 = 0,

    fn listener(dm: *client.zwp.LinuxDmabufV1, event: client.zwp.LinuxDmabufV1.Event, data: *GlobalCapture) void {
        _ = dm;
        switch (event) {
            .format => data.formats += 1,
            .modifier => data.modifiers += 1,
        }
    }
};

/// What a client saw on its zwp_linux_buffer_params_v1.
const ParamsCapture = struct {
    created: ?*client.wl.Buffer = null,
    failed: bool = false,

    fn listener(params: *client.zwp.LinuxBufferParamsV1, event: client.zwp.LinuxBufferParamsV1.Event, data: *ParamsCapture) void {
        _ = params;
        switch (event) {
            .created => |e| data.created = e.buffer,
            .failed => data.failed = true,
        }
    }
};

/// What a client saw on its zwp_linux_dmabuf_feedback_v1.
const FeedbackCapture = struct {
    done: u32 = 0,
    format_table_size: u32 = 0,
    format_table_fd: i32 = -1,
    main_device: u32 = 0,
    tranche_target_device: u32 = 0,
    tranche_done: u32 = 0,
    tranche_formats: u32 = 0,
    flags: zwp.LinuxDmabufFeedbackV1.TrancheFlags = .{},

    fn listener(fb: *client.zwp.LinuxDmabufFeedbackV1, event: client.zwp.LinuxDmabufFeedbackV1.Event, data: *FeedbackCapture) void {
        _ = fb;
        switch (event) {
            .done => data.done += 1,
            .format_table => |e| {
                data.format_table_size = e.size;
                data.format_table_fd = e.fd;
            },
            .main_device => data.main_device += 1,
            .tranche_done => data.tranche_done += 1,
            .tranche_target_device => data.tranche_target_device += 1,
            .tranche_formats => data.tranche_formats += 1,
            .tranche_flags => |e| data.flags = e.flags,
        }
    }
};

/// A compositor + dmabuf module + in-memory client, for wire roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    linux: ?*LinuxDmabuf = null,
    /// Owned fake, when the harness was asked for a live device.
    fake: ?*FakeDevice = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    registry: ?*client.wl.Registry = null,
    compositor_name: ?u32 = null,
    dmabuf_name: ?u32 = null,
    wl_compositor: ?*client.wl.Compositor = null,
    /// Bound at 6 by default; `initAt` takes a lower version.
    wl_dmabuf: ?*client.zwp.LinuxDmabufV1 = null,
    bind_version: u32 = zwp.LinuxDmabufV1.generated_version,
    global_capture: GlobalCapture = .{},

    /// Heap-allocated: the io pointer must outlive the stack frame.
    /// A harness with no import device: the branch where the global must
    /// NOT be advertised.
    fn initNoDevice(allocator: std.mem.Allocator) !*TestServer {
        return initWith(allocator, null, zwp.LinuxDmabufV1.generated_version);
    }

    /// A harness with a live (fake) device, bound at the current version.
    fn init(allocator: std.mem.Allocator) !*TestServer {
        return initAt(allocator, zwp.LinuxDmabufV1.generated_version);
    }

    /// A harness with a live (fake) device, bound at `version`.
    fn initAt(allocator: std.mem.Allocator, version: u32) !*TestServer {
        return initWith(allocator, &fake_formats, version);
    }

    fn initWith(
        allocator: std.mem.Allocator,
        formats: ?[]const dmabuf.Format,
        version: u32,
    ) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
            .bind_version = version,
        };
        try ts.initDisplay();
        errdefer if (ts.display) |d| d.deinit();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();

        var device: ?*dmabuf.Device = null;
        if (formats) |f| {
            const fake = try allocator.create(FakeDevice);
            errdefer allocator.destroy(fake);
            fake.* = FakeDevice.init(f);
            ts.fake = fake;
            device = fake.device();
        }
        ts.linux = try LinuxDmabuf.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, device);
        errdefer if (ts.linux) |l| l.deinit();
        try ts.connect();
        if (ts.compositor_name == null) return error.GlobalMissing;
        ts.bindCompositor();
        if (ts.dmabuf_name) |name| try ts.bindDmabuf(name);
        return ts;
    }

    fn initDisplay(ts: *TestServer) !void {
        ts.display = try display_mod.CompositorDisplay.init(ts.allocator, &ts.io, &ts.log_cfg);
    }

    fn connect(ts: *TestServer) !void {
        // SAFETY: written by socketpair() on success, which the errno check
        // below proves before either end is used.
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        const registry = try ts.c_display.?.getRegistry();
        ts.registry = registry;
        var capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
        try ts.pump();
        ts.compositor_name = capture.compositor_name;
        ts.dmabuf_name = capture.dmabuf_name;
    }

    fn bindCompositor(ts: *TestServer) void {
        ts.wl_compositor = ts.registry.?.bind(ts.compositor_name.?, client.wl.Compositor, 7) catch unreachable;
    }

    fn bindDmabuf(ts: *TestServer, name: u32) !void {
        const dm = try ts.registry.?.bind(name, client.zwp.LinuxDmabufV1, ts.bind_version);
        dm.setListener(*GlobalCapture, GlobalCapture.listener, &ts.global_capture);
        ts.wl_dmabuf = dm;
    }

    fn deinit(ts: *TestServer) void {
        // The client first: its resource destroy handlers must run while
        // the dmabuf module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.linux) |l| l.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        if (ts.fake) |f| ts.allocator.destroy(f);
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// The shared `test_pump.roundtrip` (client flush -> server dispatch ->
    /// server flush) plus a client dispatch, which runs only when the server
    /// actually wrote to the socket. Never blocks.
    fn pump(ts: *TestServer) !void {
        try test_pump.roundtrip(ts.c_display.?, ts.display.?, 0);
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                // Protocol error or disconnect: the server already
                // destroyed the client. Forget it for deinit.
                ts.client = null;
                return error.ClientDispatchFailed;
            }
        }
    }

    /// The compositor Surface behind a client wl_surface.
    fn serverSurface(ts: *TestServer, wl_surface: *client.wl.Surface) *surface_mod.Surface {
        for (ts.compositor.?.surfaces.items) |s| {
            if (s.resource.getId() == wl_surface.getId()) return s;
        }
        unreachable;
    }

    /// The server-side wl_buffer resource the client received as `created`.
    fn serverBuffer(ts: *TestServer, id: u32) ?*server.wl.Buffer {
        var it = ts.linux.?.buffers.iterator();
        while (it.next()) |entry| {
            const state: *DmabufBuffer = entry.value_ptr.*;
            const res = state.res orelse continue;
            if (res.getId() == id) return res;
        }
        return null;
    }
};

/// libwayland-client >= 1.18: the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const ProtocolError = struct { code: c_int, interface: []const u8, id: u32 };

fn protocolError(ts: *TestServer) ProtocolError {
    var interface: ?*client.wl.Interface = null;
    var id: u32 = 0;
    const code = wl_display_get_protocol_error(ts.c_display.?, @ptrCast(&interface), &id);
    return .{ .code = code, .interface = if (interface) |i| std.mem.span(i.name) else "", .id = id };
}

/// The numeric codes of zwp_linux_buffer_params_v1's error enum
/// (linux-dmabuf-v1.xml:207-227), spelled out so a test that asserts
/// "the XML's exact error" cannot silently follow a renumbered enum.
/// A tiled NVIDIA layout modifier, split the way the protocol splits it
/// (linux-dmabuf-v1.xml:261-264): 0x0100_0000_0000_0002 does not fit the
/// pattern, so the tests use the vendor-form 0x0100_0000_0000_0002 as
/// (hi = 0x0100_0000, lo = 0x0000_0002).
const tiled_modifier_hi: u32 = 0x0100_0000;
const tiled_modifier_lo: u32 = 0x0000_0002;

const ParamsErrorCode = struct {
    const already_used: c_int = 0;
    const plane_idx: c_int = 1;
    const plane_set: c_int = 2;
    const incomplete: c_int = 3;
    const invalid_format: c_int = 4;
    const invalid_dimensions: c_int = 5;
    const out_of_bounds: c_int = 6;
    const invalid_wl_buffer: c_int = 7;
    const invalid_dev_t_size: c_int = 8;
};

/// A memfd of `size` bytes to hand to `add` as a plane, or -1 on failure.
/// The test never closes the returned fd: `add` transfers ownership.
fn planeObject(size: usize) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("dmabuf-client-plane", std.os.linux.MFD.CLOEXEC);
    _ = std.os.linux.ftruncate(fd, @intCast(size));
    return fd;
}

test "no import device: the global is not advertised" {
    const allocator = testing.allocator;
    var ts = try TestServer.initNoDevice(allocator);
    defer ts.deinit();

    // The module is fully constructed, just inert.
    try testing.expect(ts.linux.?.device == null);
    try testing.expect(!ts.linux.?.advertised());
    try testing.expect(ts.linux.?.global == null);
    try testing.expectEqual(@as(usize, 0), ts.linux.?.formats.len);

    // The compositor must not even see the interface name.
    try testing.expect(ts.dmabuf_name == null);
    try testing.expect(ts.wl_dmabuf == null);
}

test "a live device: the global is advertised, binds and answers create" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    try testing.expect(ts.linux.?.advertised());
    try testing.expect(ts.dmabuf_name != null);
    try testing.expectEqual(@as(u32, 6), ts.bind_version);
    try testing.expect(ts.wl_dmabuf != null);

    // The v6 bind must NOT receive the deprecated format/modifier events.
    try ts.pump();
    try testing.expectEqual(@as(u32, 0), ts.global_capture.formats);
    try testing.expectEqual(@as(u32, 0), ts.global_capture.modifiers);

    // A well-formed request produces a wl_buffer and an imported Buffer.
    const params = try ts.wl_dmabuf.?.createParams();
    var capture: ParamsCapture = .{};
    params.setListener(*ParamsCapture, ParamsCapture.listener, &capture);
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try ts.pump();
    try testing.expect(capture.created != null);
    try testing.expect(!capture.failed);
    try testing.expectEqual(@as(u32, 1), ts.fake.?.imports);
    try testing.expectEqual(@as(usize, 1), ts.linux.?.buffers.count());
}

test "a device that advertises no format is treated as no device" {
    const allocator = testing.allocator;
    // A live pointer whose format list is empty: isLive() must veto the
    // global, so a client is never told to expect buffers it cannot get.
    var ts = try TestServer.initWith(allocator, &.{}, zwp.LinuxDmabufV1.generated_version);
    defer ts.deinit();

    try testing.expect(ts.linux.?.device == null);
    try testing.expect(!ts.linux.?.advertised());
    try testing.expect(ts.dmabuf_name == null);
}

test "a v3 bind is told every advertised format/modifier pair" {
    const allocator = testing.allocator;
    var ts = try TestServer.initAt(allocator, 3);
    defer ts.deinit();

    try testing.expect(ts.wl_dmabuf != null);
    try ts.pump();
    try testing.expectEqual(@as(u32, fake_formats.len), ts.global_capture.modifiers);
    // Before v3 the only event is `format`, and it is only meaningful for
    // an implicit modifier we do not advertise.
    try testing.expectEqual(@as(u32, 0), ts.global_capture.formats);
}

test "a v4+ bind gets a complete feedback object and no legacy events" {
    const allocator = testing.allocator;
    var ts = try TestServer.initAt(allocator, 4);
    defer ts.deinit();

    try ts.pump();
    try testing.expectEqual(@as(u32, 0), ts.global_capture.modifiers);

    const fb = try ts.wl_dmabuf.?.getDefaultFeedback();
    var cap: FeedbackCapture = .{};
    fb.setListener(*FeedbackCapture, FeedbackCapture.listener, &cap);
    try ts.pump();

    // One format_table, one tranche, one done (XML :451-454, :423-454).
    try testing.expect(cap.format_table_fd >= 0);
    try testing.expectEqual(@as(u32, fake_formats.len * table_entry_size), cap.format_table_size);
    try testing.expectEqual(@as(u32, 1), cap.tranche_target_device);
    try testing.expectEqual(@as(u32, 1), cap.tranche_formats);
    try testing.expectEqual(@as(u32, 1), cap.tranche_done);
    try testing.expectEqual(@as(u32, 1), cap.done);
    // v4 predates the sampling bit (enum entry is since="6"), so the
    // tranche must carry no flags at all.
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(cap.flags)));
    // main_device is sent below v6 and not at or above it.
    try testing.expectEqual(@as(u32, 1), cap.main_device);
    _ = std.os.linux.close(cap.format_table_fd);
}

test "a v6 feedback tranche carries the sampling flag and no main_device" {
    const allocator = testing.allocator;
    var ts = try TestServer.initAt(allocator, 6);
    defer ts.deinit();

    const fb = try ts.wl_dmabuf.?.getDefaultFeedback();
    var cap: FeedbackCapture = .{};
    fb.setListener(*FeedbackCapture, FeedbackCapture.listener, &cap);
    try ts.pump();

    try testing.expect(cap.flags.sampling);
    try testing.expect(!cap.flags.scanout);
    // XML :520-522: "With version 6 and above, this event is no longer
    // sent."
    try testing.expectEqual(@as(u32, 0), cap.main_device);
    try testing.expectEqual(@as(u32, 1), cap.done);
    _ = std.os.linux.close(cap.format_table_fd);
}

test "the format table holds one 16-byte entry per advertised pair" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const linux = ts.linux.?;
    try testing.expect(linux.table_fd >= 0);
    try testing.expectEqual(@as(u32, fake_formats.len * table_entry_size), linux.table_size);
    try testing.expectEqual(@as(usize, fake_formats.len), linux.indices.len);
    // The table is a mapping of what the module advertised, in order.
    const map = try posix.mmap(
        null,
        linux.table_size,
        .{ .READ = true, .WRITE = false },
        .{ .TYPE = .SHARED },
        linux.table_fd,
        0,
    );
    defer posix.munmap(map);
    for (fake_formats, 0..) |f, i| {
        const at = map[i * table_entry_size ..][0..table_entry_size];
        try testing.expectEqual(f.format, std.mem.readInt(u32, at[0..4], .native));
        try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, at[4..8], .native));
        try testing.expectEqual(f.modifier, std.mem.readInt(u64, at[8..16], .native));
    }
}

test "create with no plane added is incomplete" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try testing.expectEqual(ParamsErrorCode.incomplete, err.code);
    try testing.expectEqualStrings("zwp_linux_buffer_params_v1", err.interface);
}

test "create with a zero dimension is invalid_dimensions" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(0, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.invalid_dimensions, protocolError(ts).code);
}

test "create with an unadvertised format is invalid_format" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    // ARGB2101010 is a legal fourcc we never advertised.
    params.create(64, 64, dmabuf.drm_format_argb2101010, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.invalid_format, protocolError(ts).code);
}

test "create with an unadvertised modifier is invalid_format" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    // A tiled NVIDIA modifier on an advertised format: the PAIR is what
    // v4+ requires us to have advertised (XML :248-249).
    params.add(fd, 0, 0, 256, tiled_modifier_hi, tiled_modifier_lo);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.invalid_format, protocolError(ts).code);
}

test "planes with different modifiers are invalid_format" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const a = try planeObject(256 * 64);
    params.add(a, 0, 0, 256, 0, 0);
    const b = try planeObject(256 * 64);
    params.add(b, 1, 0, 256, tiled_modifier_hi, tiled_modifier_lo);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.invalid_format, protocolError(ts).code);
}

test "an unknown flag bit is invalid_format" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    // y_invert (1) is known; bit 3 is not in this XML.
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{ .y_invert = true, ._padding3 = true });
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.invalid_format, protocolError(ts).code);
}

test "a stride past the end of the object is out_of_bounds" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    // The object is 8 rows; the buffer claims 64.
    const fd = try planeObject(256 * 8);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.out_of_bounds, protocolError(ts).code);
}

test "a zero stride is out_of_bounds" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 0, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.out_of_bounds, protocolError(ts).code);
}

test "an offset past the end of the object is out_of_bounds" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 256 * 64, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.out_of_bounds, protocolError(ts).code);
}

test "a gapped plane set is incomplete" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const a = try planeObject(256 * 64);
    params.add(a, 0, 0, 256, 0, 0);
    const c = try planeObject(256 * 64);
    params.add(c, 2, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.incomplete, protocolError(ts).code);
}

test "an out-of-range plane index is plane_idx" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 4, 0, 256, 0, 0);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.plane_idx, protocolError(ts).code);
}

test "setting the same plane twice is plane_set" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const a = try planeObject(256 * 64);
    params.add(a, 0, 0, 256, 0, 0);
    const b = try planeObject(256 * 64);
    params.add(b, 0, 0, 256, 0, 0);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.plane_set, protocolError(ts).code);
}

test "a second create on one params object is already_used" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try ts.pump();
    // The XML allows only destroy after create (:328-331).
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.already_used, protocolError(ts).code);
}

test "an add after create is already_used" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try ts.pump();
    const late = try planeObject(256 * 64);
    params.add(late, 1, 0, 256, 0, 0);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.already_used, protocolError(ts).code);
}

test "a set_sampling_device array of the wrong size is invalid_dev_t_size" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    // Two dev_t where exactly one is required (XML :413-416).
    const devs = [_]u64{ 0x1111, 0x2222 };
    var devs_arr = arrayOf(u64, devs[0..]);
    params.setSamplingDevice(&devs_arr);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(ParamsErrorCode.invalid_dev_t_size, protocolError(ts).code);
}

test "create_immed on an import the device refuses is invalid_wl_buffer" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    ts.fake.?.fail_next = true;
    const params = try ts.wl_dmabuf.?.createParams();
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    _ = try params.createImmed(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    // XML :380-387: for create_immed the compositor may pick, and a fatal
    // error is the choice that never hands out a useless wl_buffer.
    try testing.expectEqual(ParamsErrorCode.invalid_wl_buffer, protocolError(ts).code);
    try testing.expectEqual(@as(usize, 0), ts.linux.?.buffers.count());
}

test "create on an import the device refuses is the failed event, not an error" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    ts.fake.?.fail_next = true;
    const params = try ts.wl_dmabuf.?.createParams();
    var cap: ParamsCapture = .{};
    params.setListener(*ParamsCapture, ParamsCapture.listener, &cap);
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try ts.pump();
    // XML :69-74: a failed import is a non-fatal `failed` event so the
    // client can fall back to another allocation strategy.
    try testing.expect(cap.failed);
    try testing.expect(cap.created == null);
    try testing.expectEqual(@as(usize, 0), ts.linux.?.buffers.count());
}

test "a client that destroys its wl_buffer frees the registry entry but not the wrapper" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    var cap: ParamsCapture = .{};
    params.setListener(*ParamsCapture, ParamsCapture.listener, &cap);
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try ts.pump();
    const wl_buffer = cap.created.?;
    try testing.expectEqual(@as(usize, 1), ts.linux.?.buffers.count());
    try testing.expectEqual(@as(usize, 0), ts.linux.?.dead_buffers.items.len);

    // The registry entry must go with the resource: libwayland recycles
    // freed resource memory, and a recycled pointer has to resolve to a
    // fresh wrapper. The wrapper itself survives, because a surface may
    // still hold a lock on the Buffer.
    wl_buffer.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.linux.?.buffers.count());
    try testing.expectEqual(@as(usize, 1), ts.linux.?.dead_buffers.items.len);
}

test "a buffer created through the global reaches the surface's buffer and damage path" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const params = try ts.wl_dmabuf.?.createParams();
    var cap: ParamsCapture = .{};
    params.setListener(*ParamsCapture, ParamsCapture.listener, &cap);
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try ts.pump();
    const wl_buffer = cap.created.?;

    // The surface's attach path resolves the wl_buffer through
    // LinuxDmabuf.fromResource - the hook surface.zig's handleAttach needs
    // (see fromResource's doc comment). attachBuffer is the exact call
    // handleAttach makes once it has a wrapper.
    const res = ts.serverBuffer(wl_buffer.getId()) orelse return error.NoServerBuffer;
    const wrapper = ts.linux.?.fromResource(@ptrCast(res)) orelse return error.NotOurBuffer;
    const surface = ts.serverSurface(wl_surface);
    surface.attachBuffer(wrapper);
    try testing.expectEqual(@as(u32, 1), wrapper.n_locks);

    wl_surface.damage(3, 4, 10, 20);
    wl_surface.commit();
    try ts.pump();

    // The buffer is the surface's content and the damage reached the
    // committed buffer-coordinate list.
    try testing.expect(surface.isEffectivelyMapped());
    try testing.expectEqual(wrapper, surface.buffer);
    try testing.expectEqual(@as(usize, 1), surface.current.buffer_damage.rects.items.len);
    try testing.expectEqual(@as(i32, 3), surface.current.buffer_damage.rects.items[0].x);
    try testing.expectEqual(@as(i32, 10), surface.current.buffer_damage.rects.items[0].width);
    try testing.expectEqual(@as(i32, 20), surface.current.buffer_damage.rects.items[0].height);
}

test "the compositor finishing with a buffer sends wl_buffer.release" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const params = try ts.wl_dmabuf.?.createParams();
    var cap: ParamsCapture = .{};
    params.setListener(*ParamsCapture, ParamsCapture.listener, &cap);
    const fd = try planeObject(256 * 64);
    params.add(fd, 0, 0, 256, 0, 0);
    params.create(64, 64, dmabuf.drm_format_xrgb8888, .{});
    try ts.pump();
    const wl_buffer = cap.created.?;
    var releases: u32 = 0;
    const ReleaseCapture = struct {
        fn on(_: *client.wl.Buffer, event: client.wl.Buffer.Event, data: *u32) void {
            switch (event) {
                .release => data.* += 1,
            }
        }
    };
    wl_buffer.setListener(*u32, ReleaseCapture.on, &releases);

    const res = ts.serverBuffer(wl_buffer.getId()) orelse return error.NoServerBuffer;
    const wrapper = ts.linux.?.fromResource(@ptrCast(res)).?;
    // lock + drop + unlock is one full compositor use; the module's
    // release listener must turn it into a wl_buffer.release, the same
    // chain buffers/shm.zig runs for shm buffers. A client that pools
    // buffers (weston's shm_surface) stalls without it.
    try wrapper.lock();
    wrapper.drop();
    wrapper.unlock();
    try ts.pump();
    try testing.expectEqual(@as(u32, 1), releases);

    // A second use re-arms the release, so a client can reuse the buffer.
    try wrapper.lock();
    wrapper.drop();
    wrapper.unlock();
    try ts.pump();
    try testing.expectEqual(@as(u32, 2), releases);

    // Destroying the resource while the compositor still holds the
    // wrapper must not crash: the wrapper goes to the graveyard and the
    // release listener becomes a no-op.
    wl_buffer.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.linux.?.dead_buffers.items.len);
    try testing.expectEqual(@as(usize, 0), ts.linux.?.buffers.count());
}
