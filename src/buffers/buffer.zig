//! Core buffer abstraction (wlr_buffer equivalent, wlroots types/wlr_buffer.c).
//!
//! A Buffer is a reference-counted handle to pixel data produced by some
//! backend (SHM, DMA-BUF, ...). Consumers (surfaces, renderers) lock it
//! while reading; the producer owns its lifetime via drop().
//!
//! Reference semantics (mirroring wlr_buffer.h:73):
//! - `drop()`: the producer is done with the buffer.
//! - `lock()`/`unlock()`: a consumer is reading it.
//! - The `release` signal fires when the buffer has been dropped AND all
//!   consumers are done (`dropped && n_locks == 0`). Listeners (e.g. the
//!   shm module) use it to tell the client the buffer may be reused.
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
    destroy: *const fn (self: *Buffer) void,
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
            .events = undefined,
        };
        wire.Signal(*Buffer).init(&buf.events.release);
        wire.Signal(*Buffer).init(&buf.events.destroy);
        return buf;
    }

    /// The producer is done with the buffer. Idempotency is the caller's
    /// job: dropping an already-dropped buffer is a programmer error.
    pub fn drop(buf: *Buffer) void {
        assert(!buf.dropped);
        buf.dropped = true;
        buf.maybeRelease();
    }

    /// A consumer starts reading the buffer. Must be paired with unlock().
    pub fn lock(buf: *Buffer) !void {
        buf.n_locks += 1;
    }

    /// A consumer is done reading. Unlocking an unlocked buffer is a
    /// programmer error.
    pub fn unlock(buf: *Buffer) void {
        assert(buf.n_locks > 0);
        buf.n_locks -= 1;
        buf.maybeRelease();
    }

    fn maybeRelease(buf: *Buffer) void {
        if (buf.dropped and buf.n_locks == 0) {
            buf.events.release.emit(buf);
        }
    }

    /// Destroy the buffer: fires the destroy signal while the Buffer is
    /// still valid, calls impl.destroy for impl-private resources, then
    /// frees the Buffer. Must not be called from inside a signal handler.
    pub fn destroy(buf: *Buffer) void {
        buf.events.destroy.emit(buf);
        buf.impl.destroy(buf);
        buf.allocator.destroy(buf);
    }
};

test "lock drop unlock release ordering" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{ .bytes = undefined };
    var observer: TestObserver = .{};
    observer.release_listener = wire.Listener(*Buffer).init(TestObserver.onRelease);
    observer.destroy_listener = wire.Listener(*Buffer).init(TestObserver.onDestroy);

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

test "drop with no locks releases immediately" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{ .bytes = undefined };
    var observer: TestObserver = .{};
    observer.release_listener = wire.Listener(*Buffer).init(TestObserver.onRelease);

    const buf = try Buffer.init(allocator, &test_impl, &data, 16, 16);
    defer buf.destroy();
    buf.events.release.add(&observer.release_listener);

    buf.drop();
    try std.testing.expectEqual(@as(u32, 1), observer.release_count);
}

test "unlock without drop does not release" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{ .bytes = undefined };
    var observer: TestObserver = .{};
    observer.release_listener = wire.Listener(*Buffer).init(TestObserver.onRelease);

    const buf = try Buffer.init(allocator, &test_impl, &data, 16, 16);
    defer buf.destroy();
    buf.events.release.add(&observer.release_listener);

    try buf.lock();
    buf.unlock();
    try std.testing.expectEqual(@as(u32, 0), observer.release_count);
}

test "destroy fires destroy signal before impl destroy" {
    const allocator = std.testing.allocator;
    var data: TestBufferData = .{ .bytes = undefined };
    var observer: TestObserver = .{};
    observer.destroy_listener = wire.Listener(*Buffer).init(TestObserver.onDestroy);

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
    var data: TestBufferData = .{ .bytes = undefined };
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
    bytes: [16]u8 = undefined,
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

fn testDestroy(buf: *Buffer) void {
    const d: *TestBufferData = @ptrCast(@alignCast(buf.data));
    d.destroyed = true;
}

const TestObserver = struct {
    release_count: u32 = 0,
    destroy_count: u32 = 0,
    release_listener: wire.Listener(*Buffer) = undefined,
    destroy_listener: wire.Listener(*Buffer) = undefined,

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
