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
//! - The release signal fires AT MOST ONCE per buffer lifetime: a
//!   `released` guard (see maybeRelease) suppresses the duplicate
//!   wl_buffer.release that re-dropping a replaced buffer at the next
//!   commit would otherwise send. A client may re-attach the same
//!   wl_buffer resource across cycles (double buffering), but the protocol
//!   release event is per buffer, not per cycle — wlroots sends it exactly
//!   once per committed buffer.
//! - `destroy()`: emits the `destroy` signal, releases impl-private
//!   resources via `impl.destroy`, then frees the Buffer itself.
//!
//! Callers must never destroy a Buffer from inside a signal handler: signal
//! emission iterates live listeners, so freeing a listener's storage during
//! emission is use-after-free. The owner destroys from regular control flow.

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
    n_locks: u32 = 0, // public: the surface guards unlocks after early releases
    /// The release signal has fired; it is emitted at most once per buffer
    /// lifetime (see maybeRelease).
    released: bool = false,
    /// Whether a producer registry (e.g. ShmState) owns this wrapper and
    /// frees it at deinit. False for untracked wrappers (the stateless
    /// shm fromResource): the consumer that holds the last reference
    /// destroys them via Buffer.destroy when done.
    tracked: bool = true,
    events: struct {
        /// Fires once when `dropped && n_locks == 0`.
        release: wire.Signal(*Buffer),
        /// Fires from destroy() while the Buffer is still valid.
        destroy: wire.Signal(*Buffer),
    },

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
        };
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
        buf.n_locks += 1;
        buf.released = false;
    }

    /// A consumer is done reading. Unlocking an unlocked buffer is a
    /// programmer error. Dropping the last lock fires the release signal
    /// (once per lock cycle, re-armed by the next lock) even if the
    /// buffer was never dropped (wlroots types/buffer/buffer.c:50-61):
    /// the client learns it may reuse the buffer as soon as the
    /// compositor is done reading it.
    pub fn unlock(buf: *Buffer) void {
        assert(buf.n_locks > 0);
        buf.n_locks -= 1;
        buf.maybeRelease();
    }

    fn maybeRelease(buf: *Buffer) void {
        // Once per lock cycle: the next lock() re-arms. The surface's
        // re-drops of replaced buffers (drop only) never fire it.
        if (!buf.released and buf.n_locks == 0) {
            buf.released = true;
            buf.events.release.emit(buf);
        }
    }

    /// Destroy the buffer: fires the destroy signal while the Buffer is
    /// still valid, calls impl.destroy for impl-private resources, then
    /// frees the Buffer. Must not be called from inside a signal handler.
    pub fn destroy(buf: *Buffer) void {
        buf.events.destroy.emit(buf);
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
