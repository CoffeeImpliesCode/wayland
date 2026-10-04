//! Core buffer abstraction (wlr_buffer equivalent, wlroots types/wlr_buffer.c).
//!
//! A Buffer is a reference-counted handle to pixel data produced by some
//! backend (SHM, DMA-BUF, ...). Consumers (surfaces, renderers) lock it
//! while reading; the producer owns its lifetime via drop().
//!
//! Reference semantics (mirroring wlr_buffer.h:73):
//! - `drop()`: the producer is done with the buffer.
//! - `lock()`/`unlock()`: a consumer is reading it.
//! - The `release` signal fires whenever the last consumer lock drops
//!   (`n_locks == 0`), regardless of `dropped` — wlroots emits release on
//!   the last unlock (types/buffer/buffer.c:50-61), and drop() of an
//!   already-unlocked buffer also fires it. Listeners (e.g. the shm module)
//!   use it to tell the client the buffer may be reused.
//! - The release signal fires AT MOST ONCE per LOCK CYCLE: a `released`
//!   guard (see maybeRelease) suppresses the duplicate wl_buffer.release
//!   that re-dropping a replaced buffer at the next commit would
//!   otherwise send. `lock()` re-arms it, because a client re-attaches the
//!   same wl_buffer across cycles (double buffering) and needs a release
//!   per use.
//! - `destroy()`: notifies ONCE (the `destroy` signal) and hands the
//!   impl backing to the consumer locks — `impl.destroy` and the
//!   Buffer's own free run when `n_locks` reaches 0, never inside the
//!   emitter. A renderer still holding the pixels therefore keeps them
//!   valid past producer teardown.
//! - `queueReleaseCallback()`: a wl_surface.get_release callback (v7)
//!   rides the BUFFER, not the surface — the protocol promise is "when
//!   the compositor is no longer using this buffer". It completes the
//!   moment the last consumer lock drops, even when teardown was
//!   already requested. Every queued callback owns a destroy listener on
//!   its own wire resource, so a client that disconnects (or destroys
//!   the callback early) drops its record without touching the Buffer.
//!
//! Never free a Buffer or listener storage from inside a signal handler:
//! emission iterates live listeners. `destroy` is the one call that does
//! it, and it defers the free (`notifying_destroy`).

const std = @import("std");
const assert = std.debug.assert;
const wire = @import("../core/wire.zig");

/// Error set for `Impl.begin_data_ptr_access`.
pub const DataAccessError = error{Unsupported};

/// Buffer implementation vtable (wlr_buffer_impl equivalent). Each function
/// receives the Buffer itself; per-buffer state lives in `Buffer.data`.
pub const Impl = struct {
    /// DMA-BUF handle if the buffer is backed by one, else null.
    get_dmabuf: ?*const fn (self: *Buffer) ?*anyopaque = null,
    /// libwayland SHM buffer handle if the buffer is shm-backed, else null.
    get_shm: ?*const fn (self: *Buffer) ?*wire.shm.Buffer = null,
    /// Begin CPU access to the pixel data. Must be paired with
    /// `end_data_ptr_access`; nesting is not allowed.
    begin_data_ptr_access: ?*const fn (self: *Buffer) DataAccessError!?[*]u8 = null,
    /// End CPU access started by `begin_data_ptr_access`.
    end_data_ptr_access: ?*const fn (self: *Buffer) void = null,
    /// Release impl-private resources. The Buffer itself is freed by
    /// `Buffer.destroy`, never here.
    destroy: *const fn (allocator: std.mem.Allocator, data: *anyopaque) void,
};

/// One queued wl_surface.get_release callback (protocol v7). The record
/// is intrusive on the Buffer that must complete it and owns the destroy
/// listener on the callback's own wire resource: a client that destroys
/// the callback (or disconnects) unlinks and frees the record here, so
/// the Buffer never completes a dead resource.
pub const ReleaseCallback = struct {
    allocator: std.mem.Allocator,
    buf: *Buffer,
    /// The client's wl_callback; owned here until completion.
    callback: *wire.wl.Callback,
    /// Position on `Buffer.release_callbacks`.
    link: wire.list.Link,
    /// Fires when the client destroys the callback resource.
    destroy: wire.Listener(*wire.Resource),

    fn onClientDestroy(listener: *wire.Listener(*wire.Resource), _: *wire.Resource) void {
        const rec: *ReleaseCallback = @fieldParentPtr("destroy", listener);
        const allocator = rec.allocator;
        // Unlink before freeing: the record's own destroy link is
        // detached by wl_resource_destroy itself, and the Buffer list
        // must not keep pointing at freed storage. No done: the client
        // asked for this callback to be gone.
        rec.link.remove();
        allocator.destroy(rec);
    }
};

pub const Buffer = struct {
    impl: *const Impl,
    /// Impl-private state (the fn-pointer functions receive it via self).
    data: *anyopaque,
    allocator: std.mem.Allocator,
    width: i32,
    height: i32,
    /// The producer has dropped the buffer.
    dropped: bool = false,
    /// Number of consumers currently reading the buffer.
    n_locks: u32 = 0,
    /// The release signal has fired in this lock cycle.
    released: bool = false,
    /// Producer teardown was requested; consumer locks retain the backing.
    destroy_requested: bool = false,
    /// Final unlock inside a destroy listener must not free the emitter.
    notifying_destroy: bool = false,
    /// Whether a producer registry (e.g. ShmState) keeps this wrapper
    /// reachable for as long as its wire resource lives. True wrappers
    /// must not be destroyed by a consumer dropping its reference: a
    /// later attach of the same resource would hand the client back a
    /// dead wrapper. False for untracked wrappers (the stateless shm
    /// fromResource), whose only owner is the consumer.
    tracked: bool = true,
    events: struct {
        /// Fires once per completed consumer-lock cycle while alive.
        release: wire.Signal(*Buffer),
        /// Fires from destroy() while the Buffer is still valid.
        destroy: wire.Signal(*Buffer),
    },
    /// get_release callbacks this buffer owes the client. They live on
    /// the Buffer, not on the Surface: the promise is "when the
    /// compositor stops reading this buffer", and the surface that
    /// requested them may already be gone.
    release_callbacks: wire.list.Head(ReleaseCallback, .link),

    /// Allocate a Buffer with the given impl. The impl must provide
    /// `destroy`; `begin_data_ptr_access` and `end_data_ptr_access` must be
    /// provided together.
    pub fn init(
        allocator: std.mem.Allocator,
        impl: *const Impl,
        data: *anyopaque,
        w: i32,
        h: i32,
    ) error{OutOfMemory}!*Buffer {
        if (impl.begin_data_ptr_access != null or impl.end_data_ptr_access != null) {
            assert(impl.begin_data_ptr_access != null);
            assert(impl.end_data_ptr_access != null);
        }
        const buf = try allocator.create(Buffer);
        buf.* = .{
            .impl = impl,
            .data = data,
            .allocator = allocator,
            .width = w,
            .height = h,
            // SAFETY: events signals are initialized via .init() immediately below, before any emit.
            .events = undefined,
            .release_callbacks = undefined,
        };
        buf.release_callbacks.init();
        wire.Signal(*Buffer).init(&buf.events.release);
        wire.Signal(*Buffer).init(&buf.events.destroy);
        return buf;
    }

    /// The producer is done with the buffer. Cycle-idempotent: a client
    /// may re-attach a released buffer (double buffering), so the same
    /// Buffer is dropped once per replace and can be dropped many times
    /// across its lifetime. The release signal itself fires from unlock()
    /// only — the consumer's done — so a bare (re-)drop stays silent and
    /// cannot duplicate the release.
    ///
    /// F53: this is deliberately more lenient than wlroots, where
    /// wlr_buffer_drop asserts !dropped and the refcount freeing at zero
    /// makes a double drop a bug (types/buffer/buffer.c:45-56). Our
    /// cycle-idempotent drop keeps the repeated drop harmless, and the
    /// commit path relies on it (a replaced buffer is re-dropped at the
    /// next commit). Keep the leniency; do not add the assert.
    pub fn drop(buf: *Buffer) void {
        buf.dropped = true;
    }

    /// A consumer starts reading the buffer. Must be paired with unlock().
    /// Re-arms the release: a client may re-attach the SAME buffer after
    /// the release (weston double-buffering reuses buffers) and needs a
    /// wl_buffer.release for every use — the weston shm_surface marks the
    /// leaf busy until the release arrives, and a missed release leaves
    /// the leaf stuck, exhausting the pool ("all buffers are held by the
    /// server", weston clients/window.c shm_surface_prepare exit(1)).
    pub fn lock(buf: *Buffer) !void {
        assert(!buf.destroy_requested);
        buf.n_locks += 1;
        buf.released = false;
    }

    /// A consumer is done reading. Unlocking an unlocked buffer is a
    /// programmer error. Dropping the last lock completes every queued
    /// get_release callback and fires the release signal (once per lock
    /// cycle, re-armed by the next lock) even if the buffer was never
    /// dropped (wlroots types/buffer/buffer.c:50-61): the client learns
    /// it may reuse the buffer as soon as the compositor is done.
    pub fn unlock(buf: *Buffer) void {
        assert(buf.n_locks > 0);
        buf.n_locks -= 1;
        if (buf.n_locks != 0) return;
        buf.maybeRelease();
        if (buf.destroy_requested and !buf.notifying_destroy) buf.finishDestroy();
    }

    /// The compositor stopped reading the buffer. Queued get_release
    /// callbacks complete even when teardown was already requested: they
    /// are a protocol promise about the CLIENT's reuse, not about
    /// backing memory, and dropping them would hang the client forever.
    fn maybeRelease(buf: *Buffer) void {
        assert(buf.n_locks == 0);
        buf.completeReleaseCallbacks();
        // Once per lock cycle: the next lock() re-arms. The surface's
        // re-drops of replaced buffers (drop only) never fire it. After
        // teardown the wire resource is gone, so no release goes out.
        if (!buf.released) {
            buf.released = true;
            if (!buf.destroy_requested) buf.events.release.emit(buf);
        }
    }

    /// Queue a wl_surface.get_release callback against this buffer. It
    /// completes now when no consumer holds a lock, otherwise on the
    /// final unlock. The callback resource itself is owned by the record
    /// until then: the client destroying it (or disconnecting) unlinks
    /// and frees the record without a done.
    pub fn queueReleaseCallback(buf: *Buffer, callback: *wire.wl.Callback) error{OutOfMemory}!void {
        if (buf.n_locks == 0) {
            // Nobody is reading: the client may reuse the buffer now.
            callback.destroySendDone(0);
            return;
        }
        const rec = try buf.allocator.create(ReleaseCallback);
        rec.* = .{
            .allocator = buf.allocator,
            .buf = buf,
            .callback = callback,
            .link = undefined,
            .destroy = wire.Listener(*wire.Resource).init(ReleaseCallback.onClientDestroy),
        };
        rec.link.init();
        buf.release_callbacks.append(rec);
        const res: *wire.Resource = @ptrCast(callback);
        res.addDestroyListener(&rec.destroy);
    }

    /// Send done on every queued get_release callback and free its
    /// record. Called at the final unlock, never while the destroy
    /// emitter is walking the Buffer.
    fn completeReleaseCallbacks(buf: *Buffer) void {
        var it = buf.release_callbacks.iterator(.forward);
        while (it.next()) |rec| {
            // Detach the callback's own destroy listener BEFORE destroying
            // the resource: wl_resource_destroy would otherwise call back
            // into the record we are about to free.
            rec.destroy.link.remove();
            rec.link.remove();
            const callback = rec.callback;
            buf.allocator.destroy(rec);
            callback.destroySendDone(0);
        }
    }

    /// Notify producer teardown once. The Buffer and impl backing survive
    /// until the last consumer unlocks. Do not call from a release listener.
    pub fn destroy(buf: *Buffer) void {
        if (buf.destroy_requested) return;
        buf.destroy_requested = true;
        buf.notifying_destroy = true;
        buf.events.destroy.emit(buf);
        buf.notifying_destroy = false;
        if (buf.n_locks == 0) {
            // No queued callback can outlive a lock (queueReleaseCallback
            // completes immediately at zero locks), but a destroy listener
            // may have queued one during the emission; nothing may be
            // owed to the client once the backing is gone.
            buf.completeReleaseCallbacks();
            buf.finishDestroy();
        }
    }

    fn finishDestroy(buf: *Buffer) void {
        assert(buf.destroy_requested and !buf.notifying_destroy and buf.n_locks == 0);
        buf.impl.destroy(buf.allocator, buf.data);
        buf.allocator.destroy(buf);
    }
};

test "lock drop unlock release ordering" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{};
    var observer: TestObserver = .{
        .release_listener = wire.Listener(*Buffer).init(TestObserver.onRelease),
        .destroy_listener = wire.Listener(*Buffer).init(TestObserver.onDestroy),
    };

    const buf = try Buffer.init(allocator, &test_impl, &data, 640, 480);
    defer buf.destroy();
    buf.events.release.add(&observer.release_listener);
    buf.events.destroy.add(&observer.destroy_listener);

    // Two consumers lock; drop alone must not release.
    try buf.lock();
    try buf.lock();
    buf.drop();
    try std.testing.expectEqual(@as(u32, 0), observer.release_count);

    // First unlock: one consumer still reading.
    buf.unlock();
    try std.testing.expectEqual(@as(u32, 0), observer.release_count);

    // Last unlock: dropped and unlocked -> release fires exactly once.
    buf.unlock();
    try std.testing.expectEqual(@as(u32, 1), observer.release_count);
}

test "release fires per re-attach cycle, re-drops stay silent" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{};
    var observer: TestObserver = .{
        .release_listener = wire.Listener(*Buffer).init(TestObserver.onRelease),
        .destroy_listener = wire.Listener(*Buffer).init(TestObserver.onDestroy),
    };

    const buf = try Buffer.init(allocator, &test_impl, &data, 64, 64);
    defer buf.destroy();
    buf.events.release.add(&observer.release_listener);

    // Cycle 1: attach (lock), replace (drop+unlock) -> release.
    try buf.lock();
    buf.drop();
    buf.unlock();
    try std.testing.expectEqual(@as(u32, 1), observer.release_count);

    // Cycle 2: the client re-attaches the SAME buffer (double buffering).
    // The lock re-arms the release, so the second use emits again — a
    // client like weston reuses released buffers and needs a release per
    // use (its leaf stays busy until the release arrives).
    try buf.lock();
    buf.drop();
    buf.unlock();
    try std.testing.expectEqual(@as(u32, 2), observer.release_count);

    // A bare re-drop of the released (unlocked) buffer is silent too.
    buf.drop();
    try std.testing.expectEqual(@as(u32, 2), observer.release_count);
}

test "drop with no locks stays silent; unlock fires the release" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{};
    var observer: TestObserver = .{
        .release_listener = wire.Listener(*Buffer).init(TestObserver.onRelease),
        .destroy_listener = wire.Listener(*Buffer).init(TestObserver.onDestroy),
    };

    const buf = try Buffer.init(allocator, &test_impl, &data, 16, 16);
    defer buf.destroy();
    buf.events.release.add(&observer.release_listener);

    // A bare producer drop must not release: the compositor (consumer)
    // still holds the lock, and the surface re-drops replaced buffers at
    // the next commit — a release from the drop would duplicate the
    // consumer's unlock release.
    buf.drop();
    try std.testing.expectEqual(@as(u32, 0), observer.release_count);

    try buf.lock();
    buf.drop();
    buf.unlock();
    try std.testing.expectEqual(@as(u32, 1), observer.release_count);
}

test "unlock to zero releases without a drop" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{};
    var observer: TestObserver = .{
        .release_listener = wire.Listener(*Buffer).init(TestObserver.onRelease),
        .destroy_listener = wire.Listener(*Buffer).init(TestObserver.onDestroy),
    };

    const buf = try Buffer.init(allocator, &test_impl, &data, 16, 16);
    defer buf.destroy();
    buf.events.release.add(&observer.release_listener);

    // A plain lock->unlock cycle fires release even though the producer
    // never dropped the buffer (wlroots types/buffer/buffer.c:50-61): the
    // client may reuse it as soon as the compositor is done reading.
    try buf.lock();
    buf.unlock();
    try std.testing.expectEqual(@as(u32, 1), observer.release_count);
}

test "destroy fires destroy signal before impl destroy" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{};
    var observer: TestObserver = .{
        .release_listener = wire.Listener(*Buffer).init(TestObserver.onRelease),
        .destroy_listener = wire.Listener(*Buffer).init(TestObserver.onDestroy),
    };

    const buf = try Buffer.init(allocator, &test_impl, &data, 32, 32);
    buf.events.destroy.add(&observer.destroy_listener);

    // Destroy without prior drop: allowed; the owner may destroy at any
    // time, release semantics only concern the client-facing lifecycle.
    buf.destroy();
    try std.testing.expectEqual(@as(u32, 1), observer.destroy_count);
    try std.testing.expect(data.destroyed);
}

test "destroy retains pixels while a renderer still owns a consumer lock" {
    var data: TestBufferData = .{};
    const buf = try Buffer.init(std.testing.allocator, &test_impl, &data, 4, 1);
    try buf.lock();
    buf.destroy();
    try std.testing.expect(!data.destroyed);
    const pixels = (try buf.impl.begin_data_ptr_access.?(buf)).?;
    pixels[0] = 0xA7;
    buf.impl.end_data_ptr_access.?(buf);
    try std.testing.expectEqual(@as(u8, 0xA7), data.bytes[0]);
    buf.unlock();
    try std.testing.expect(data.destroyed);
}

/// A server + client pair with a raw peer fd, so a test can watch the
/// bytes a wl_callback.done would put on the wire.
const CallbackWire = struct {
    server: *wire.Server,
    client: ?*wire.Client,
    peer_fd: std.posix.fd_t,
    scratch: [128]u8 = undefined,

    fn init() error{ ServerCreateFailed, SocketPairFailed, ClientCreateFailed }!CallbackWire {
        const srv = try wire.Server.create();
        errdefer srv.destroy();
        var fds: [2]std.posix.fd_t = undefined;
        const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
        if (@as(isize, @bitCast(rc)) < 0) return error.SocketPairFailed;
        const client = wire.Client.create(srv, fds[0]) orelse {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ClientCreateFailed;
        };
        return .{ .server = srv, .client = client, .peer_fd = fds[1] };
    }

    fn deinit(self: *CallbackWire) void {
        self.disconnect();
        self.server.destroy();
        _ = std.os.linux.close(self.peer_fd);
        self.* = undefined;
    }

    fn disconnect(self: *CallbackWire) void {
        if (self.client) |client| client.destroy();
        self.client = null;
    }

    /// Flush the server, then the bytes the client would read — null when
    /// nothing is queued.
    fn recv(self: *CallbackWire) ?[]const u8 {
        self.server.flushClients();
        const n = std.os.linux.recvfrom(
            self.peer_fd,
            &self.scratch,
            self.scratch.len,
            std.os.linux.MSG.DONTWAIT,
            null,
            null,
        );
        const got: isize = @bitCast(n);
        if (got < 12) return null;
        return self.scratch[0..@intCast(got)];
    }
};

test "a queued get_release callback completes on the final unlock, even after teardown" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{};
    var tw = try CallbackWire.init();
    defer tw.deinit();

    const buf = try Buffer.init(allocator, &test_impl, &data, 8, 8);
    defer if (!data.destroyed) {
        buf.destroy();
        if (!data.destroyed) buf.unlock();
    };
    try buf.lock(); // the consumer is still reading the pixels
    // A fresh client's display owns id 1; its next new_id is 2.
    const callback = try wire.wl.Callback.create(tw.client.?, 1, 2);
    try buf.queueReleaseCallback(callback);

    // The producer tears down first: the promise to the client outlives
    // the backing, and the backing outlives the consumer's lock.
    buf.destroy();
    try std.testing.expect(!data.destroyed);
    try std.testing.expect(tw.recv() == null);

    buf.unlock();
    try std.testing.expect(data.destroyed);
    const msg = tw.recv() orelse return error.NoCallbackDone;
    const endian = @import("builtin").target.cpu.arch.endian();
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, msg[0..][0..4], endian));
    try std.testing.expectEqual(@as(u32, 12 << 16), std.mem.readInt(u32, msg[4..][0..4], endian));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, msg[8..][0..4], endian));
}

test "a disconnected client drops its queued get_release callback" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{};
    var tw = try CallbackWire.init();
    defer tw.deinit();

    const buf = try Buffer.init(allocator, &test_impl, &data, 8, 8);
    defer if (!data.destroyed) {
        buf.destroy();
        if (!data.destroyed) buf.unlock();
    };
    try buf.lock();
    const callback = try wire.wl.Callback.create(tw.client.?, 1, 2);
    try buf.queueReleaseCallback(callback);
    try std.testing.expect(!buf.release_callbacks.empty());

    // wl_callback has no destroy request: disconnecting the client
    // destroys its resource and removes the promise before final unlock.
    tw.disconnect();
    try std.testing.expect(buf.release_callbacks.empty());
    buf.unlock();
    buf.destroy();
    try std.testing.expect(data.destroyed);
    try std.testing.expect(tw.recv() == null);
}

test "data ptr access roundtrip via impl" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{};
    const buf = try Buffer.init(allocator, &test_impl, &data, 4, 1);
    defer buf.destroy();

    const begin = buf.impl.begin_data_ptr_access.?;
    const end = buf.impl.end_data_ptr_access.?;
    const ptr = try begin(buf);
    try std.testing.expect(ptr != null);
    ptr.?[0] = 0xAB;
    ptr.?[3] = 0xCD;
    end(buf);
    try std.testing.expectEqual(@as(u8, 0xAB), data.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), data.bytes[3]);

    // Non-shm, non-dmabuf buffer reports neither backend.
    try std.testing.expect(buf.impl.get_dmabuf == null);
    try std.testing.expect(buf.impl.get_shm == null);
}

/// Test fixture: impl state observed by the test impl.
const TestBufferData = struct {
    bytes: [16]u8 = [_]u8{0} ** 16,
    destroyed: bool = false,
};

const test_impl: Impl = .{
    .get_dmabuf = null,
    .get_shm = null,
    .begin_data_ptr_access = testBeginData,
    .end_data_ptr_access = testEndData,
    .destroy = testDestroy,
};

fn testBeginData(buf: *Buffer) DataAccessError!?[*]u8 {
    const d: *TestBufferData = @ptrCast(@alignCast(buf.data));
    return &d.bytes;
}

fn testEndData(buf: *Buffer) void {
    _ = buf;
}

fn testDestroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    _ = allocator;
    const d: *TestBufferData = @ptrCast(@alignCast(data));
    d.destroyed = true;
}

const TestObserver = struct {
    release_count: u32 = 0,
    destroy_count: u32 = 0,
    release_listener: wire.Listener(*Buffer),
    destroy_listener: wire.Listener(*Buffer),

    fn onRelease(listener: *wire.Listener(*Buffer), buf: *Buffer) void {
        _ = buf;
        const self: *TestObserver = @fieldParentPtr("release_listener", listener);
        self.release_count += 1;
    }

    fn onDestroy(listener: *wire.Listener(*Buffer), buf: *Buffer) void {
        _ = buf;
        const self: *TestObserver = @fieldParentPtr("destroy_listener", listener);
        self.destroy_count += 1;
    }
};
