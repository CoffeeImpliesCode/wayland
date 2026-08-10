//! SHM protocol + ShmBuffer wrappers.
//!
//! The wl_shm global is created by CompositorDisplay.initShm() →
//! wl_display_init_shm(), which registers libwayland's *internal* wl_shm
//! global (version 2). Its internal handlers (shm_create_pool,
//! shm_pool_create_buffer, shm_pool_resize, ...) mmap the client fd,
//! validate offset/stride/format and create wl_buffer resources whose
//! implementation is libwayland's internal shm_buffer_implementation.
//! The internal bind handler stores the wl_shm resource per client and
//! sends the formats (ARGB8888 + XRGB8888 + addShmFormat additions).
//!
//! wire.shm.Buffer.get() (wl_shm_buffer_get) only matches resources with
//! that internal implementation. Since libwayland 1.15 the compositor-facing
//! factory wl_shm_buffer_create() is deprecated and returns NULL (verified
//! in libwayland 1.26.0 src/wayland-shm.c:481-491 and 803-806), a compositor
//! cannot manufacture such buffers itself: intercepting create_pool /
//! create_buffer with custom handlers (server.wl.Shm/ShmPool setHandler)
//! would yield wl_buffer resources that wl_shm_buffer_get() rejects. So
//! this module deliberately does NOT set those handlers; the client-facing
//! lifecycle it owns is:
//!
//! - ShmState.fromResource() wraps a client wl_buffer resource (as it
//!   arrives, e.g. via wl_surface.attach) into a Buffer whose impl reads
//!   through wire.shm.Buffer (get_data/get_stride/... plus begin/end access
//!   for the SIGBUS guard).
//! - The release listener sends wl_buffer.release when the Buffer's release
//!   signal fires (dropped && n_locks == 0): libwayland never sends release,
//!   the compositor must.
//! - A resource-destroy listener marks the wrapper dead (its backing is
//!   freed by libwayland) and drops the Buffer. The wrapper is reclaimed by
//!   ShmState.deinit; it must not be freed from inside the resource destroy
//!   signal (that would free listener storage mid-emission).
//!
//! Wrapper lifetime contract:
//! - Consumers (surfaces) lock() on attach, unlock() and drop() when done
//!   presenting; drop is guarded by the caller (drop only if !buf.dropped),
//!   because the module also drops on resource destruction.
//! - Tracked wrappers (stateful path) are owned by ShmState and freed in
//!   deinit. Untracked wrappers (stateless fromResource) are owned by the
//!   surface, which destroys them via Buffer.destroy in its buffer-replace
//!   and destroy paths (Buffer.tracked == false).

const std = @import("std");
const wire = @import("../core/wire.zig");
const log = @import("../utils/log.zig");
const display_mod = @import("../core/display.zig");
pub const Buffer = @import("buffer.zig").Buffer;
const Impl = @import("buffer.zig").Impl;
const DataAccessError = @import("buffer.zig").DataAccessError;

// Cross-module assumptions:
// - `display_mod.CompositorDisplay.initShm()` exists and is idempotent
//   (core/display.zig).
// - `Buffer` API: init, drop, lock, unlock, destroy, events.release,
//   events.destroy, DataAccessError (buffers/buffer.zig).

pub const ShmState = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// Tracked wrappers: client wl_buffer resource -> Buffer (dedupe).
    buffers: std.AutoHashMap(*wire.Resource, *Buffer),
    /// Wrappers whose client resource was destroyed: dropped from the map
    /// (a recycled resource pointer must get a fresh wrapper) but still
    /// referenced by surfaces until teardown, so ownership moves here and
    /// deinit frees them.
    dead_buffers: std.ArrayList(*Buffer) = .empty,
    /// Fixed-size overflow for the graveyard when its append OOMs (F52):
    /// wrappers with outstanding consumer locks cannot be freed inside the
    /// resource-destroy signal, so they park here (no allocation) until
    /// deinit frees them. A full stash leaks (bounded, OOM-only).
    dead_stash: [8]?*Buffer = [_]?*Buffer{null} ** 8,
    dead_stash_len: usize = 0,

    /// Enable the wl_shm protocol (internal libwayland global + formats)
    /// and allocate the shm state. Safe to call once per display.
    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) error{OutOfMemory}!*ShmState {
        try display.initShm();
        const state = try allocator.create(ShmState);
        state.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .buffers = std.AutoHashMap(*wire.Resource, *Buffer).init(allocator),
        };
        log.info("shm state ready", io, log_cfg, "shm", .{});
        return state;
    }

    /// Reclaim all tracked wrappers (their client resources may already be
    /// gone; the wrappers themselves outlive them). Destroying a wrapper
    /// removes it from the map, so re-iterate until empty. Dead wrappers
    /// (resource destroyed, still surface-referenced) live in the
    /// graveyard list and are freed here too, plus the F52 overflow stash.
    pub fn deinit(state: *ShmState) void {
        for (state.dead_stash[0..state.dead_stash_len]) |buf| Buffer.destroy(buf.?);
        state.dead_stash_len = 0;
        for (state.dead_buffers.items) |buf| Buffer.destroy(buf);
        state.dead_buffers.deinit(state.allocator);
        while (state.buffers.count() > 0) {
            var it = state.buffers.keyIterator();
            const key = (it.next() orelse unreachable).*;
            const buf = state.buffers.get(key).?;
            Buffer.destroy(buf);
        }
        const allocator = state.allocator;
        state.buffers.deinit();
        allocator.destroy(state);
    }

    /// Wrap a client wl_buffer resource as a tracked Buffer. Repeated calls
    /// with the same resource return the same wrapper (one wrapper per
    /// resource; release fires when all consumers are done). The wrapper is
    /// owned by the state and freed in deinit.
    pub fn fromResource(
        state: *ShmState,
        allocator: std.mem.Allocator,
        resource: *wire.Resource,
    ) error{ InvalidBuffer, OutOfMemory }!*Buffer {
        if (state.buffers.get(resource)) |buf| return buf;
        const buf = try shmFromResource(allocator, resource, state);
        try state.buffers.put(resource, buf);
        return buf;
    }
};

/// Wrap a client wl_buffer resource as an untracked Buffer. Unlike the
/// stateful variant this creates a fresh wrapper per call; the surface
/// (the only caller, via surface.zig handleAttach when no ShmState is
/// wired) owns it and destroys it via Buffer.destroy when it stops using
/// it (buffer-replace and surface-destroy paths). Prefer
/// ShmState.fromResource in the compositor so repeated attaches of one
/// resource share a wrapper.
pub fn fromResource(
    allocator: std.mem.Allocator,
    resource: *wire.Resource,
) error{ InvalidBuffer, OutOfMemory }!*Buffer {
    return shmFromResource(allocator, resource, null);
}

/// Per-wrapper state for the shm Buffer impl.
const ShmBufferData = struct {
    allocator: std.mem.Allocator,
    /// The client wl_buffer resource, as a raw Resource (registry key).
    resource_key: *wire.Resource,
    /// The wl_buffer resource; null once the client destroyed it.
    resource: ?*wire.wl.Buffer,
    /// The libwayland shm buffer; null once the client resource is gone
    /// (its backing is freed by libwayland at that point).
    shm: ?*wire.shm.Buffer,
    /// Owning ShmState for tracked wrappers; null for untracked ones.
    state: ?*ShmState,
    buf: *Buffer,
    resource_destroy: wire.Listener(*wire.Resource),
    release: wire.Listener(*Buffer),
};

const shm_impl: Impl = .{
    .get_dmabuf = null,
    .get_shm = shmGetShm,
    .begin_data_ptr_access = shmBeginDataPtrAccess,
    .end_data_ptr_access = shmEndDataPtrAccess,
    .destroy = shmDestroy,
};

fn shmData(buf: *Buffer) *ShmBufferData {
    return @ptrCast(@alignCast(buf.data));
}

fn shmGetShm(buf: *Buffer) ?*wire.shm.Buffer {
    return shmData(buf).shm;
}

fn shmBeginDataPtrAccess(buf: *Buffer) DataAccessError!?[*]u8 {
    const d = shmData(buf);
    const shm = d.shm orelse return error.Unsupported;
    // beginAccess installs the SIGBUS guard so a client-shrunk file cannot
    // crash the compositor; endAccess must pair it.
    wire.shm.Buffer.beginAccess(shm);
    const data = wire.shm.Buffer.getData(shm) orelse {
        wire.shm.Buffer.endAccess(shm);
        return error.Unsupported;
    };
    return @ptrCast(@alignCast(data));
}

fn shmEndDataPtrAccess(buf: *Buffer) void {
    const d = shmData(buf);
    if (d.shm) |shm| wire.shm.Buffer.endAccess(shm);
}

fn shmDestroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const d: *ShmBufferData = @ptrCast(@alignCast(data));
    if (d.state) |state| _ = state.buffers.remove(d.resource_key);
    // Detach listeners before freeing so a later signal emission cannot
    // touch freed memory. Only safe while the resource is still alive.
    if (d.resource != null) d.resource_destroy.link.remove();
    d.release.link.remove();
    allocator.destroy(d);
}

/// The client destroyed the wl_buffer resource: libwayland frees the shm
/// buffer backing, so mark the wrapper dead and drop it (the producer is
/// done). The map entry is removed so a REUSED resource pointer (libwayland
/// recycles freed resource memory) gets a fresh wrapper instead of this
/// dead one — without this, the release event for the recycled buffer is
/// silently dropped and the client's buffer stays busy forever
/// (weston-simple-shm: "Both buffers busy at redraw()").
fn resourceDestroy(listener: *wire.Listener(*wire.Resource), resource: *wire.Resource) void {
    _ = resource;
    const d: *ShmBufferData = @fieldParentPtr("resource_destroy", listener);
    if (d.state) |state| {
        // The wrapper still outlives the resource (surfaces may hold it
        // until teardown); move ownership to the graveyard so deinit
        // frees it instead of leaking (the map no longer tracks it).
        _ = state.buffers.remove(d.resource_key);
    }
    // Invalidate BEFORE the graveyard append: if the append OOMs the
    // wrapper is unreachable (removed from the map, never appended), so it
    // leaks at deinit — but it must not keep pointing at the freed client
    // resource, or a later surface unlock/replace/destroy would
    // use-after-free. The nulling also makes releaseNotify's guard work.
    d.resource = null;
    d.shm = null;
    if (!d.buf.dropped) d.buf.drop();
    if (d.state) |state| {
        state.dead_buffers.append(state.allocator, d.buf) catch {
            // F52: the graveyard could not take the wrapper. Free it now
            // when no consumer holds a lock — safe inside the destroy
            // signal: signal emission tolerates freeing the current
            // listener, and the surface-side F42 listeners that run later
            // in this emission only compare resource pointers, never
            // dereference the wrapper. With outstanding locks the wrapper
            // parks in the fixed-size stash for deinit.
            if (d.buf.n_locks == 0) {
                Buffer.destroy(d.buf);
            } else {
                if (state.dead_stash_len < state.dead_stash.len) {
                    state.dead_stash[state.dead_stash_len] = d.buf;
                    state.dead_stash_len += 1;
                }
                // Stash full: the wrapper leaks at deinit (bounded,
                // OOM-only).
            }
        };
    }
}

/// The compositor is done with the buffer (dropped && n_locks == 0): tell
/// the client it may reuse it. Only while the resource is alive.
fn releaseNotify(listener: *wire.Listener(*Buffer), buf: *Buffer) void {
    _ = buf;
    const d: *ShmBufferData = @fieldParentPtr("release", listener);
    if (d.resource) |r| r.sendRelease();
}

fn shmFromResource(
    allocator: std.mem.Allocator,
    resource: *wire.Resource,
    state: ?*ShmState,
) error{ InvalidBuffer, OutOfMemory }!*Buffer {
    const shm = wire.shm.Buffer.get(resource) orelse return error.InvalidBuffer;
    const wl_buffer: *wire.wl.Buffer = @ptrCast(resource);

    const d = try allocator.create(ShmBufferData);
    errdefer allocator.destroy(d);
    d.* = .{
        .allocator = allocator,
        .resource_key = resource,
        .resource = wl_buffer,
        .shm = shm,
        .state = state,
        // SAFETY: assigned from Buffer.init below before any use.
        .buf = undefined,
        // SAFETY: assigned during wrapper setup below before the resource is used.
        .resource_destroy = undefined,
        // SAFETY: assigned during wrapper setup below before any emit.
        .release = undefined,
    };

    const buf = try Buffer.init(
        allocator,
        &shm_impl,
        d,
        wire.shm.Buffer.getWidth(shm),
        wire.shm.Buffer.getHeight(shm),
    );
    errdefer allocator.destroy(buf);
    d.buf = buf;
    // Tracked wrappers (state != null) are owned by ShmState and freed in
    // deinit; untracked wrappers are caller-owned, and the surface destroys
    // them in its buffer-replace and destroy paths (Buffer.tracked).
    buf.tracked = state != null;

    d.resource_destroy = wire.Listener(*wire.Resource).init(resourceDestroy);
    resource.addDestroyListener(&d.resource_destroy);

    d.release = wire.Listener(*Buffer).init(releaseNotify);
    buf.events.release.add(&d.release);

    return buf;
}

test "fromResource rejects non-shm resources" {
    // No server socket: a socketpair fd is enough to create a client and a
    // plain wl_buffer resource, which the internal shm pipeline did not
    // create and therefore must be rejected.
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();
    var cfg: log.Config = .{};

    const display = try display_mod.CompositorDisplay.init(allocator, &io, &cfg);
    defer display.deinit();

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &fds) != 0) {
        return error.TestSetupFailed;
    }
    const client = wire.Client.create(display.server, fds[0]) orelse return error.TestSetupFailed;
    fds[0] = -1; // owned by the client now
    defer {
        _ = std.c.close(fds[1]);
    }
    defer client.destroy();

    // Client object ids must be sequential from the server map's point of
    // view (id 1 = wl_display); 2 is the next free slot.
    const resource = try wire.Resource.create(client, wire.wl.Buffer, 1, 2);
    defer resource.destroy();

    try std.testing.expectError(error.InvalidBuffer, fromResource(allocator, resource));
}

test "shm state init deinit" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();
    var cfg: log.Config = .{};

    const display = try display_mod.CompositorDisplay.init(allocator, &io, &cfg);
    defer display.deinit();

    const state = try ShmState.init(allocator, &io, &cfg, display);
    defer state.deinit();

    // The internal wl_shm global is advertised; initShm was called.
    try std.testing.expect(display.shm_initialized);
    try std.testing.expectEqual(@as(usize, 0), state.buffers.count());
}

test "graveyard append OOM frees unlocked wrappers and stashes locked ones" {
    // F52: dead_buffers.append OOM used to leak the wrapper (it was
    // removed from the map and never reclaimed). Now an unlocked wrapper
    // is freed immediately (safe: signal emission tolerates freeing the
    // current listener, and the surface-side F42 listeners that run later
    // only compare resource pointers), and a locked one parks in the
    // fixed-size stash for deinit.
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();
    var cfg: log.Config = .{};

    const display = try display_mod.CompositorDisplay.init(allocator, &io, &cfg);
    defer display.deinit();

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const state = try ShmState.init(failing.allocator(), &io, &cfg, display);
    defer state.deinit();

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &fds) != 0) {
        return error.TestSetupFailed;
    }
    const client = wire.Client.create(display.server, fds[0]) orelse return error.TestSetupFailed;
    fds[0] = -1; // owned by the client now
    defer {
        _ = std.c.close(fds[1]);
    }
    defer client.destroy();

    // Fabricate a wrapper for a (never-real) client wl_buffer: the
    // internal shm pipeline is unreachable in unit tests, so build the
    // ShmBufferData + Buffer pair the resource-destroy path expects.
    const resource = try wire.Resource.create(client, wire.wl.Buffer, 1, 2);
    const wl_buf_view: *wire.wl.Buffer = @ptrCast(resource);
    const d = try allocator.create(ShmBufferData);
    d.* = .{
        .allocator = allocator,
        .resource_key = resource,
        .resource = wl_buf_view,
        .shm = null,
        .state = state,
        .buf = undefined,
        .resource_destroy = undefined,
        .release = undefined,
    };
    const buf = try Buffer.init(allocator, &shm_impl, d, 16, 16);
    d.buf = buf;
    d.resource_destroy = wire.Listener(*wire.Resource).init(resourceDestroy);
    d.release = wire.Listener(*Buffer).init(releaseNotify);
    // Never added to a signal; shmDestroy removes it unconditionally, so
    // put the link in the removable detached state.
    d.release.link.init();
    resource.addDestroyListener(&d.resource_destroy);
    try state.buffers.put(resource, buf);

    // The client destroys the wl_buffer with the graveyard append failing:
    // no consumer lock -> the wrapper is freed immediately, not leaked.
    failing.fail_index = failing.alloc_index;
    resource.destroy();
    try std.testing.expectEqual(@as(usize, 0), state.buffers.count());
    try std.testing.expectEqual(@as(usize, 0), state.dead_buffers.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.dead_stash_len);

    // Second wrapper with an outstanding consumer lock: cannot free it
    // mid-emission, so the fixed-size stash takes it (freed by deinit).
    const resource2 = try wire.Resource.create(client, wire.wl.Buffer, 1, 3);
    const wl_buf_view2: *wire.wl.Buffer = @ptrCast(resource2);
    const d2 = try allocator.create(ShmBufferData);
    d2.* = .{
        .allocator = allocator,
        .resource_key = resource2,
        .resource = wl_buf_view2,
        .shm = null,
        .state = state,
        .buf = undefined,
        .resource_destroy = undefined,
        .release = undefined,
    };
    const buf2 = try Buffer.init(allocator, &shm_impl, d2, 8, 8);
    d2.buf = buf2;
    d2.resource_destroy = wire.Listener(*wire.Resource).init(resourceDestroy);
    d2.release = wire.Listener(*Buffer).init(releaseNotify);
    d2.release.link.init();
    resource2.addDestroyListener(&d2.resource_destroy);
    try state.buffers.put(resource2, buf2);
    try buf2.lock(); // a consumer is reading

    failing.fail_index = failing.alloc_index;
    resource2.destroy();
    try std.testing.expectEqual(@as(usize, 0), state.buffers.count());
    try std.testing.expectEqual(@as(usize, 0), state.dead_buffers.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.dead_stash_len);
    // state.deinit (defer) frees the stashed wrapper.
}
