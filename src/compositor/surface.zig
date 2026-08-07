//! wl_surface state machine: double-buffered pending/current state,
//! commit pipeline, frame callbacks, map/unmap tracking, role hooks.
//!
//! Commit pipeline order:
//!   1. validate pending state (posts wl_surface protocol errors and
//!      discards the commit on failure)
//!   2. swap pending -> current (scalar copy; damage lists and frame
//!      callbacks transfer so the pending state restarts empty)
//!   3. release the buffer the surface stopped using
//!   4. role.client_commit hook
//!   5. send frame callback done(ms) with the monotonic timestamp
//!   6. role.commit hook
//!   7. emit client_commit + commit signals
//!   8. map/unmap transition: mapped = (current.buffer != null); on
//!      change, run the role.map/role.unmap hook and the map/unmap signal
//!
//! M1 simplifications (documented at each site):
//! - wl_surface.damage_buffer damage is accumulated as surface damage;
//!   the buffer->surface translation lands with the renderer (M2).
//! - opaque/input regions are snapshotted as their bounding rect.
//! - get_release callbacks fire at the commit that releases their buffer
//!   (M1 has no texture cache, so usage ends at the swap).
//!
//! Cross-module: src/buffers/buffer.zig + src/buffers/shm.zig (buffers
//! agent). Expected API (confirmed 2026-08-07):
//!   pub const Buffer = struct {
//!       impl: *const Impl,
//!       data: *anyopaque,
//!       width: i32,
//!       height: i32,
//!       dropped: bool,
//!       n_locks: u32,
//!       allocator: std.mem.Allocator,
//!       events: struct {
//!           release: wire.Signal(*Buffer),
//!           destroy: wire.Signal(*Buffer),
//!       },
//!   };
//!   pub fn init(allocator, impl: *const Impl, data: *anyopaque, w: i32, h: i32) !*Buffer;
//!   pub fn drop(b: *Buffer) void;
//!   pub fn lock(b: *Buffer) !void;
//!   pub fn unlock(b: *Buffer) void;
//!   pub fn destroy(b: *Buffer) void;
//!   pub const Impl = struct {
//!       get_dmabuf: ?*const fn (self: *Buffer) ?*anyopaque,
//!       get_shm: ?*const fn (self: *Buffer) ?*wire.shm.Buffer,
//!       begin_data_ptr_access: ?*const fn (self: *Buffer) error{Unsupported}!?[*]u8,
//!       end_data_ptr_access: ?*const fn (self: *Buffer) void,
//!       destroy: *const fn (self: *Buffer) void,
//!   };
//!   // src/buffers/shm.zig:
//!   pub fn fromResource(allocator: std.mem.Allocator, resource: *wire.Resource) !*Buffer
//! fromResource does NOT lock; the surface locks on attach and drop()s the
//! buffer when done presenting. The release signal fires exactly when
//! dropped && n_locks == 0 (once); the owner then destroys the Buffer.
//!
//! Cross-module: src/compositor/compositor.zig (this cluster):
//!   Compositor.removeSurface(*Surface) void — called by Surface.destroy.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const damage_mod = @import("../utils/damage.zig");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const role_mod = @import("role.zig");
const compositor_mod = @import("compositor.zig");
const region_mod = @import("region.zig");
const buffer_mod = @import("../buffers/buffer.zig");
const shm_mod = @import("../buffers/shm.zig");

const server = @import("protocol").server;

const Rect = geom.Rect;
const Damage = damage_mod.Damage;
const Buffer = buffer_mod.Buffer;
const Compositor = compositor_mod.Compositor;
const SurfaceRole = role_mod.SurfaceRole;
const Allocator = std.mem.Allocator;

/// Double-buffered surface state. Pending accumulates request state;
/// commit atomically applies it to current (see swapState).
pub const State = struct {
    pub const committed_buffer: u32 = 1 << 0;
    pub const committed_damage: u32 = 1 << 1;
    pub const committed_opaque: u32 = 1 << 2;
    pub const committed_input: u32 = 1 << 3;
    pub const committed_transform: u32 = 1 << 4;
    pub const committed_scale: u32 = 1 << 5;

    /// Bitfield of the state fields set since the last commit
    /// (committed_* constants). Read from current after a commit to learn
    /// what changed.
    committed: u32 = 0,
    /// Attached buffer (locked while referenced by this state).
    buffer: ?*Buffer = null,
    /// Position of the pending buffer relative to the previous one, in
    /// surface-local coordinates (wl_surface.attach x/y or offset).
    dx: i32 = 0,
    dy: i32 = 0,
    /// Accumulated damaged rects in surface coordinates.
    surface_damage: Damage,
    /// Accumulated damaged rects in buffer coordinates. M1: always empty;
    /// damage_buffer requests accumulate into surface_damage instead (see
    /// handleDamageBuffer).
    buffer_damage: Damage,
    /// Opaque region hint, in surface coordinates; null = no opaque area.
    @"opaque": ?Rect = null,
    /// Input region, in surface coordinates; null = whole surface accepts
    /// input (infinite).
    input: ?Rect = null,
    /// Transform the client already applied to the buffer contents.
    transform: geom.Transform = .normal,
    /// Scale the client rendered the buffer at.
    scale: i32 = 1,
    /// wl_callback resources created by wl_surface.frame, completed with
    /// done(ms) at commit.
    frame_callbacks: std.ArrayList(*server.wl.Callback) = .empty,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .surface_damage = Damage.init(allocator),
            .buffer_damage = Damage.init(allocator),
        };
    }

    pub fn deinit(state: *State, allocator: Allocator) void {
        state.surface_damage.deinit();
        state.buffer_damage.deinit();
        state.frame_callbacks.deinit(allocator);
        state.* = undefined;
    }
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    /// The wl_surface wire resource; its user data is this Surface.
    resource: *server.wl.Surface,
    compositor: *Compositor,
    /// Current buffer (mirror of current.buffer) for quick access.
    buffer: ?*Buffer = null,
    current: State,
    pending: State,
    /// Whether the surface currently presents content (buffer != null).
    mapped: bool = false,
    role: ?*const SurfaceRole = null,
    /// The wire resource that granted the role (e.g. the xdg_surface
    /// resource); the role object is reachable through its user data.
    role_resource: ?*wire.Resource = null,
    events: struct {
        /// The client's wl_surface.commit request was applied.
        client_commit: wire.Signal(*Surface),
        /// The commit fully processed (role hooks included).
        commit: wire.Signal(*Surface),
        /// The surface became mapped.
        map: wire.Signal(*Surface),
        /// The surface stopped being mapped.
        unmap: wire.Signal(*Surface),
        /// The surface is being destroyed (last event).
        destroy: wire.Signal(*Surface),
    },
    /// wl_surface.get_release callbacks (protocol v7) for the current
    /// buffer. M1: buffers are released as soon as they are swapped out
    /// (no texture cache), so these fire at the commit that replaces
    /// their buffer, or at surface destroy.
    release_callbacks_current: std.ArrayList(*server.wl.Callback) = .empty,
    /// get_release callbacks for the pending (attached) buffer.
    release_callbacks_pending: std.ArrayList(*server.wl.Callback) = .empty,

    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        compositor: *Compositor,
        resource: *server.wl.Surface,
    ) Allocator.Error!*Surface {
        const s = try allocator.create(Surface);
        errdefer allocator.destroy(s);
        s.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .resource = resource,
            .compositor = compositor,
            .buffer = null,
            .current = State.init(allocator),
            .pending = State.init(allocator),
            .mapped = false,
            .role = null,
            .role_resource = null,
            .events = .{
                // SAFETY: initialized via .init() immediately after construction, before any emit.
                .client_commit = undefined,
                // SAFETY: initialized via .init() immediately after construction, before any emit.
                .commit = undefined,
                // SAFETY: initialized via .init() immediately after construction, before any emit.
                .map = undefined,
                // SAFETY: initialized via .init() immediately after construction, before any emit.
                .unmap = undefined,
                // SAFETY: initialized via .init() immediately after construction, before any emit.
                .destroy = undefined,
            },
        };
        s.events.client_commit.init();
        s.events.commit.init();
        s.events.map.init();
        s.events.unmap.init();
        s.events.destroy.init();
        resource.setHandler(*Surface, handleRequest, handleDestroy, s);
        return s;
    }

    /// Full teardown. Called from handleDestroy (the wire resource is
    /// dying); also used by the compositor at deinit.
    pub fn destroy(s: *Surface) void {
        log.debug("wl_surface@{d} destroyed", s.io, s.log_cfg, "surface", .{s.resource.getId()});
        if (s.mapped) {
            s.mapped = false;
            if (s.role) |role| if (role.unmap) |f| f(s);
            s.events.unmap.emit(s);
        }
        if (s.role) |role| if (role.destroy) |f| f(s);
        s.events.destroy.emit(s);

        // Release the buffers we referenced. drop() then unlock(): the
        // release signal fires inside the last unlock, after which the
        // Buffer may be destroyed by the buffers module — do not touch it.
        if (s.current.buffer) |b| {
            b.drop();
            b.unlock();
        }
        if (s.pending.buffer) |b| {
            b.drop();
            b.unlock();
        }
        s.current.buffer = null;
        s.pending.buffer = null;
        s.buffer = null;
        s.fireReleaseCallbacksCurrent();
        s.fireReleaseCallbacksPending();

        // Frame callbacks that were never completed: destroy the wire
        // resources (no done event is sent for a destroyed surface).
        for (s.current.frame_callbacks.items) |cb| cb.destroy();
        for (s.pending.frame_callbacks.items) |cb| cb.destroy();

        s.release_callbacks_current.deinit(s.allocator);
        s.release_callbacks_pending.deinit(s.allocator);
        s.current.deinit(s.allocator);
        s.pending.deinit(s.allocator);
        s.compositor.removeSurface(s);
        s.allocator.destroy(s);
    }

    /// Set the pending buffer (from wl_surface.attach). The buffer must
    /// already be locked by the caller (shm.fromResource + lock); it is
    /// dropped+unlocked when the surface stops using it. A null buffer
    /// removes the surface content at the next commit.
    pub fn attachBuffer(s: *Surface, buffer: ?*Buffer, x: i32, y: i32) void {
        if (buffer) |b| {
            b.lock() catch {
                // Could not take a reference; nothing to present.
                b.drop();
                s.resource.postNoMemory();
                return;
            };
        }
        if (s.pending.buffer) |old| {
            if (old != buffer) {
                // The previously attached (never committed) buffer is done.
                s.fireReleaseCallbacksPending();
                old.drop();
                old.unlock();
            } else {
                // Re-attaching the same buffer: undo the extra lock.
                buffer.?.unlock();
            }
        }
        s.pending.buffer = buffer;
        s.pending.dx = x;
        s.pending.dy = y;
        s.pending.committed |= State.committed_buffer;
    }

    /// Commit pipeline: see the module comment for the step order.
    pub fn commit(s: *Surface) void {
        // 1. Validate; posts protocol errors and discards the commit.
        if (!s.validatePending()) return;

        // 2. Swap pending -> current.
        const old_buffer = s.current.buffer;
        swapState(&s.current, &s.pending);

        // 3. The surface stopped using the previous buffer; release it.
        if (old_buffer) |old| {
            if (old != s.current.buffer) {
                s.fireReleaseCallbacksCurrent();
                old.drop();
                old.unlock();
            }
        }
        // Release callbacks ride along with the current buffer.
        std.mem.swap(std.ArrayList(*server.wl.Callback), &s.release_callbacks_current, &s.release_callbacks_pending);
        s.release_callbacks_pending.clearRetainingCapacity();
        s.buffer = s.current.buffer;

        // 4. Role-specific processing of the committed state.
        if (s.role) |role| if (role.client_commit) |f| f(s);

        // 5. Complete frame callbacks with the monotonic time (ms).
        // .awake is CLOCK_MONOTONIC in the 0.16 std.Io.Clock. The u32
        // wrap-around is fine: the protocol defines an undefined base.
        const now_ms: u32 = @truncate(@as(u64, @bitCast(std.Io.Clock.now(.awake, s.io.*).toMilliseconds())));
        for (s.current.frame_callbacks.items) |cb| cb.destroySendDone(now_ms);
        s.current.frame_callbacks.clearRetainingCapacity();

        // 6-7. Role commit hook, then the commit signals.
        if (s.role) |role| if (role.commit) |f| f(s);
        s.events.client_commit.emit(s);
        s.events.commit.emit(s);

        // 8. Map/unmap transition.
        const now_mapped = s.current.buffer != null;
        if (now_mapped and !s.mapped) {
            s.mapped = true;
            if (s.role) |role| if (role.map) |f| f(s);
            s.events.map.emit(s);
        } else if (!now_mapped and s.mapped) {
            s.mapped = false;
            if (s.role) |role| if (role.unmap) |f| f(s);
            s.events.unmap.emit(s);
        }
    }

    fn validatePending(s: *Surface) bool {
        const buf = s.pending.buffer orelse return true;
        if (buf.width <= 0 or buf.height <= 0) {
            s.resource.postError(.invalid_size, "attached buffer has a non-positive size");
            return false;
        }
        // The surface size is the buffer size under the pending transform,
        // divided by the pending scale; it must be integral (invalid_size).
        const size = s.pending.transform.transformedSize(buf.width, buf.height);
        if (@rem(size.w, s.pending.scale) != 0 or @rem(size.h, s.pending.scale) != 0) {
            s.resource.postError(.invalid_size, "attached buffer size is not divisible by buffer scale");
            return false;
        }
        return true;
    }

    fn handleAttach(s: *Surface, buffer: ?*server.wl.Buffer, x: i32, y: i32) void {
        // wl_surface v5+: non-zero attach offsets are a protocol violation
        // (use wl_surface.offset instead).
        if (s.resource.getVersion() >= 5 and (x != 0 or y != 0)) {
            s.resource.postError(.invalid_offset, "wl_surface.attach with non-zero offset (use wl_surface.offset)");
            return;
        }
        const b: ?*Buffer = if (buffer) |wl_buffer| blk: {
            const res: *wire.Resource = @ptrCast(wl_buffer);
            const wrapped: ?*Buffer = if (s.compositor.shm) |st|
                st.fromResource(s.allocator, res) catch null
            else
                shm_mod.fromResource(s.allocator, res) catch null;
            if (wrapped == null) {
                log.warn(
                    "attach: unsupported wl_buffer, keeping previous pending buffer",
                    s.io,
                    s.log_cfg,
                    "surface",
                    .{},
                );
                return;
            }
            break :blk wrapped;
        } else null;
        s.attachBuffer(b, x, y);
    }

    fn handleDamage(s: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        s.pending.surface_damage.add(.{ .x = x, .y = y, .width = width, .height = height }) catch {
            s.resource.postNoMemory();
            return;
        };
        s.pending.committed |= State.committed_damage;
    }

    fn handleDamageBuffer(s: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        // M1 simplification: damage_buffer damage is in buffer coordinates,
        // but is accumulated as surface damage (surface and buffer damage
        // are treated identically). The correct scale/transform translation
        // lands with the renderer (M2).
        s.pending.surface_damage.add(.{ .x = x, .y = y, .width = width, .height = height }) catch {
            s.resource.postNoMemory();
            return;
        };
        s.pending.committed |= State.committed_damage;
    }

    fn handleFrame(s: *Surface, callback_id: u32) void {
        const client = s.resource.getClient();
        const callback = server.wl.Callback.create(client, 1, callback_id) catch {
            s.resource.postNoMemory();
            return;
        };
        s.pending.frame_callbacks.append(s.allocator, callback) catch {
            callback.destroy();
            s.resource.postNoMemory();
            return;
        };
    }

    fn handleGetRelease(s: *Surface, callback_id: u32) void {
        // The release callback is associated with the pending buffer at
        // commit; without one this is a protocol error.
        if (s.pending.buffer == null) {
            s.resource.postError(.no_buffer, "wl_surface.get_release without an attached buffer");
            return;
        }
        const client = s.resource.getClient();
        const callback = server.wl.Callback.create(client, 1, callback_id) catch {
            s.resource.postNoMemory();
            return;
        };
        s.release_callbacks_pending.append(s.allocator, callback) catch {
            callback.destroy();
            s.resource.postNoMemory();
            return;
        };
    }

    fn handleSetOpaqueRegion(s: *Surface, region: ?*server.wl.Region) void {
        // M1: the region is snapshotted as its bounding rect; null region
        // = no opaque area.
        s.pending.@"opaque" = if (region) |res| blk: {
            const r = regionModFromResource(res) orelse break :blk null;
            break :blk r.boundingRect();
        } else null;
        s.pending.committed |= State.committed_opaque;
    }

    fn handleSetInputRegion(s: *Surface, region: ?*server.wl.Region) void {
        // Null region = infinite input region (whole surface); an empty
        // region = empty rect (no input accepted). M1: snapshot as the
        // region's bounding rect.
        s.pending.input = if (region) |res| blk: {
            const r = regionModFromResource(res) orelse break :blk null;
            break :blk r.boundingRect() orelse Rect.empty();
        } else null;
        s.pending.committed |= State.committed_input;
    }

    fn handleSetBufferTransform(s: *Surface, transform: server.wl.Output.Transform) void {
        const value: i32 = @intFromEnum(transform);
        if (value < 0 or value > 7) {
            s.resource.postError(.invalid_transform, "invalid wl_surface.set_buffer_transform value");
            return;
        }
        s.pending.transform = @enumFromInt(@as(u32, @intCast(value)));
        s.pending.committed |= State.committed_transform;
    }

    fn handleSetBufferScale(s: *Surface, scale: i32) void {
        if (scale <= 0) {
            s.resource.postError(.invalid_scale, "wl_surface.set_buffer_scale must be greater than zero");
            return;
        }
        s.pending.scale = scale;
        s.pending.committed |= State.committed_scale;
    }

    fn handleOffset(s: *Surface, x: i32, y: i32) void {
        // wl_surface.offset (v5): role-specific location of the pending
        // buffer. M1: stored like the attach offsets, applied at commit.
        s.pending.dx = x;
        s.pending.dy = y;
    }

    fn fireReleaseCallbacksCurrent(s: *Surface) void {
        for (s.release_callbacks_current.items) |cb| cb.destroySendDone(0);
        s.release_callbacks_current.clearRetainingCapacity();
    }

    fn fireReleaseCallbacksPending(s: *Surface) void {
        for (s.release_callbacks_pending.items) |cb| cb.destroySendDone(0);
        s.release_callbacks_pending.clearRetainingCapacity();
    }
};

/// Apply pending to current. Scalar state copies; the damage lists and
/// frame callbacks transfer so the pending state restarts empty (the old
/// current damage is stale — M2's damage ring accumulates properly).
pub fn swapState(current: *State, pending: *State) void {
    current.committed = pending.committed;
    pending.committed = 0;
    current.buffer = pending.buffer;
    pending.buffer = null;
    current.dx = pending.dx;
    current.dy = pending.dy;
    current.@"opaque" = pending.@"opaque";
    current.input = pending.input;
    current.transform = pending.transform;
    current.scale = pending.scale;
    std.mem.swap(Damage, &current.surface_damage, &pending.surface_damage);
    pending.surface_damage.clear();
    std.mem.swap(Damage, &current.buffer_damage, &pending.buffer_damage);
    pending.buffer_damage.clear();
    std.mem.swap(std.ArrayList(*server.wl.Callback), &current.frame_callbacks, &pending.frame_callbacks);
    pending.frame_callbacks.clearRetainingCapacity();
}

fn regionModFromResource(resource: *server.wl.Region) ?*region_mod.Region {
    const ud = resource.getUserData() orelse return null;
    return @ptrCast(@alignCast(ud));
}

fn handleRequest(resource: *server.wl.Surface, request: server.wl.Surface.Request, s: *Surface) void {
    switch (request) {
        .attach => |r| s.handleAttach(r.buffer, r.x, r.y),
        .damage => |r| s.handleDamage(r.x, r.y, r.width, r.height),
        .frame => |r| s.handleFrame(r.callback),
        .set_opaque_region => |r| s.handleSetOpaqueRegion(r.region),
        .set_input_region => |r| s.handleSetInputRegion(r.region),
        .commit => s.commit(),
        .set_buffer_transform => |r| s.handleSetBufferTransform(r.transform),
        .set_buffer_scale => |r| s.handleSetBufferScale(r.scale),
        .damage_buffer => |r| s.handleDamageBuffer(r.x, r.y, r.width, r.height),
        .offset => |r| s.handleOffset(r.x, r.y),
        .get_release => |r| s.handleGetRelease(r.callback),
        // Destructor requests are dispatched to the handler; the handler
        // must destroy the resource (handleDestroy then runs the teardown).
        .destroy => resource.destroy(),
    }
}

fn handleDestroy(resource: *server.wl.Surface, s: *Surface) void {
    _ = resource;
    s.destroy();
}

const testing = std.testing;
const posix = std.posix;

// --- Test support -------------------------------------------------------
//
// Used by this file's and role.zig's test blocks. Tests must not require a
// server socket, so the wire objects are fabricated: a real Server with a
// socketpair-backed Client and real wl_surface resources. The compositor
// is a real Compositor struct with a dummy display pointer (never
// dereferenced).

pub const TestWire = struct {
    server: *wire.Server,
    client: *wire.Client,
    peer_fd: posix.fd_t,
    next_id: u32 = 2, // 1 is the display object id

    pub fn init() error{ ServerCreateFailed, SocketPairFailed, ClientCreateFailed }!TestWire {
        const srv = try wire.Server.create();
        errdefer srv.destroy();
        var fds: [2]posix.fd_t = undefined;
        // Linux-only test harness: raw socketpair syscall.
        const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
        if (@as(isize, @bitCast(rc)) < 0) return error.SocketPairFailed;
        const client = wire.Client.create(srv, fds[0]) orelse {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ClientCreateFailed;
        };
        return .{ .server = srv, .client = client, .peer_fd = fds[1] };
    }

    pub fn deinit(self: *TestWire) void {
        // Destroying the client destroys all its resources, firing the
        // wl_surface destructors (Surface.destroy).
        self.client.destroy();
        self.server.destroy();
        _ = std.os.linux.close(self.peer_fd);
        self.* = undefined;
    }

    pub fn newId(self: *TestWire) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

pub fn testCompositor(
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
) Allocator.Error!*Compositor {
    const c = try allocator.create(Compositor);
    c.* = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = log_cfg,
        .display = @ptrFromInt(0x10), // dummy: never dereferenced
    };
    return c;
}

pub fn testSurface(
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    compositor: *Compositor,
    tw: *TestWire,
) error{ OutOfMemory, ResourceCreateFailed }!*Surface {
    const resource = try server.wl.Surface.create(tw.client, 7, tw.newId());
    return Surface.create(allocator, io, log_cfg, compositor, resource);
}

/// Initialize a fabricated Buffer for tests (Buffer is a plain struct).
/// The signals are initialized in place so drop/unlock release paths are
/// safe (a by-value copy would carry stale self-pointers).
pub fn testBuffer(allocator: std.mem.Allocator, b: *Buffer) void {
    b.* = .{
        .impl = &test_buffer_impl,
        // SAFETY: test fixture; never dereferenced before assignment.
        .data = undefined,
        .width = 10,
        .height = 10,
        .dropped = false,
        .n_locks = 0,
        .allocator = allocator,
        // SAFETY: both signals are initialized via .init() below, before any emit.
        .events = .{ .release = undefined, .destroy = undefined },
    };
    b.events.release.init();
    b.events.destroy.init();
}

fn fakeBufferDestroy(self: *Buffer) void {
    _ = self;
}

var test_buffer_impl: buffer_mod.Impl = .{
    .get_dmabuf = null,
    .get_shm = null,
    .begin_data_ptr_access = null,
    .end_data_ptr_access = null,
    .destroy = fakeBufferDestroy,
};

// --- Tests --------------------------------------------------------------

test "state swap transfers damage and callbacks, resets pending" {
    const allocator = testing.allocator;
    var current = State.init(allocator);
    defer current.deinit(allocator);
    var pending = State.init(allocator);
    defer pending.deinit(allocator);

    try pending.surface_damage.add(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    try pending.buffer_damage.add(.{ .x = 5, .y = 6, .width = 7, .height = 8 });
    try pending.frame_callbacks.append(allocator, @as(*server.wl.Callback, @ptrFromInt(0x100)));
    pending.committed = State.committed_buffer | State.committed_damage;
    pending.buffer = @as(?*Buffer, @ptrFromInt(0x200));
    pending.dx = 5;
    pending.dy = 6;
    pending.@"opaque" = Rect{ .x = 1, .y = 1, .width = 2, .height = 2 };
    pending.transform = .@"90";
    pending.scale = 2;

    swapState(&current, &pending);

    try testing.expectEqual(State.committed_buffer | State.committed_damage, current.committed);
    try testing.expectEqual(@as(u32, 0), pending.committed);
    try testing.expectEqual(@as(?*Buffer, @ptrFromInt(0x200)), current.buffer);
    try testing.expect(pending.buffer == null);
    try testing.expectEqual(@as(i32, 5), current.dx);
    try testing.expectEqual(@as(i32, 6), current.dy);
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .width = 2, .height = 2 }, current.@"opaque".?);
    try testing.expectEqual(geom.Transform.@"90", current.transform);
    try testing.expectEqual(@as(i32, 2), current.scale);
    try testing.expectEqual(@as(usize, 1), current.surface_damage.rects.items.len);
    try testing.expect(pending.surface_damage.isEmpty());
    try testing.expectEqual(@as(usize, 1), current.buffer_damage.rects.items.len);
    try testing.expect(pending.buffer_damage.isEmpty());
    try testing.expectEqual(@as(usize, 1), current.frame_callbacks.items.len);
    try testing.expectEqual(@as(usize, 0), pending.frame_callbacks.items.len);
}

test "damage requests accumulate in pending surface damage" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    s.handleDamage(1, 2, 3, 4);
    s.handleDamageBuffer(10, 20, 30, 40);

    // M1: both land in surface damage.
    try testing.expectEqual(@as(usize, 2), s.pending.surface_damage.rects.items.len);
    try testing.expect(s.pending.committed & State.committed_damage != 0);
    try testing.expect(s.pending.buffer_damage.isEmpty());
}

test "frame callbacks are completed at commit" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    s.handleFrame(tw.newId());
    s.handleFrame(tw.newId());
    try testing.expectEqual(@as(usize, 2), s.pending.frame_callbacks.items.len);

    s.commit();

    // done was sent and the callbacks were destroyed; lists are empty.
    try testing.expectEqual(@as(usize, 0), s.pending.frame_callbacks.items.len);
    try testing.expectEqual(@as(usize, 0), s.current.frame_callbacks.items.len);
}

test "attach, commit, map and unmap transitions" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    test_map_count = 0;
    test_unmap_count = 0;
    test_commit_count = 0;
    test_map_listener = wire.Listener(*Surface).init(testMapNotify);
    test_unmap_listener = wire.Listener(*Surface).init(testUnmapNotify);
    test_commit_listener = wire.Listener(*Surface).init(testCommitNotify);
    s.events.map.add(&test_map_listener);
    s.events.unmap.add(&test_unmap_listener);
    s.events.commit.add(&test_commit_listener);

    try testing.expect(!s.mapped);
    try testing.expect(s.current.buffer == null);

    // First buffer commit maps the surface.
    var buffer: Buffer = undefined;
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer, 0, 0);
    try testing.expectEqual(@as(u32, State.committed_buffer), s.pending.committed & State.committed_buffer);
    s.commit();

    try testing.expect(s.mapped);
    try testing.expect(s.buffer == &buffer);
    try testing.expect(s.current.buffer == &buffer);
    try testing.expect(s.pending.buffer == null);
    try testing.expectEqual(@as(usize, 1), test_map_count);
    try testing.expectEqual(@as(usize, 0), test_unmap_count);
    try testing.expectEqual(@as(usize, 1), test_commit_count);

    // Null attach commits remove the content: unmap.
    s.attachBuffer(null, 0, 0);
    s.commit();

    try testing.expect(!s.mapped);
    try testing.expect(s.buffer == null);
    try testing.expect(s.current.buffer == null);
    try testing.expectEqual(@as(usize, 1), test_map_count);
    try testing.expectEqual(@as(usize, 1), test_unmap_count);
}

var test_map_count: usize = 0;
var test_unmap_count: usize = 0;
var test_commit_count: usize = 0;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_map_listener: wire.Listener(*Surface) = undefined;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_unmap_listener: wire.Listener(*Surface) = undefined;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_commit_listener: wire.Listener(*Surface) = undefined;

fn testMapNotify(listener: *wire.Listener(*Surface), surface: *Surface) void {
    _ = listener;
    _ = surface;
    test_map_count += 1;
}

fn testUnmapNotify(listener: *wire.Listener(*Surface), surface: *Surface) void {
    _ = listener;
    _ = surface;
    test_unmap_count += 1;
}

fn testCommitNotify(listener: *wire.Listener(*Surface), surface: *Surface) void {
    _ = listener;
    _ = surface;
    test_commit_count += 1;
}

test "commit releases the replaced buffer" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    var b1: Buffer = undefined;
    testBuffer(allocator, &b1);
    var b2: Buffer = undefined;
    testBuffer(allocator, &b2);
    s.attachBuffer(&b1, 0, 0);
    s.commit();
    try testing.expectEqual(@as(u32, 1), b1.n_locks);
    try testing.expect(!b1.dropped);

    s.attachBuffer(&b2, 0, 0);
    s.commit();
    // b1 was swapped out: dropped and released.
    try testing.expect(b1.dropped);
    try testing.expectEqual(@as(u32, 0), b1.n_locks);
    try testing.expectEqual(@as(u32, 1), b2.n_locks);
    try testing.expect(s.current.buffer == &b2);
}

test "get_release callbacks fire when the buffer is released" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    var b1: Buffer = undefined;
    testBuffer(allocator, &b1);
    s.attachBuffer(&b1, 0, 0);
    s.handleGetRelease(tw.newId());
    try testing.expectEqual(@as(usize, 1), s.release_callbacks_pending.items.len);
    s.commit();
    try testing.expectEqual(@as(usize, 1), s.release_callbacks_current.items.len);
    try testing.expectEqual(@as(usize, 0), s.release_callbacks_pending.items.len);

    // Replacing the buffer releases it: the callback is completed.
    var b2: Buffer = undefined;
    testBuffer(allocator, &b2);
    s.attachBuffer(&b2, 0, 0);
    s.commit();
    try testing.expectEqual(@as(usize, 0), s.release_callbacks_current.items.len);
    try testing.expect(b1.dropped);
}

test "get_release without a pending buffer is a protocol error" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    s.handleGetRelease(tw.newId());
    try testing.expectEqual(@as(usize, 0), s.release_callbacks_pending.items.len);
}

test "commit validation rejects a buffer not divisible by scale" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    var buffer: Buffer = undefined;
    testBuffer(allocator, &buffer); // 10x10
    s.handleSetBufferScale(3); // 10 % 3 != 0 -> invalid_size at commit
    s.attachBuffer(&buffer, 0, 0);
    s.commit();

    // The commit was discarded: nothing swapped, surface unmapped.
    try testing.expect(s.current.buffer == null);
    try testing.expect(!s.mapped);
}

test "set_buffer_scale rejects non-positive scale" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    s.handleSetBufferScale(0);
    try testing.expectEqual(@as(i32, 1), s.pending.scale);
    s.handleSetBufferScale(-1);
    try testing.expectEqual(@as(i32, 1), s.pending.scale);
    s.handleSetBufferScale(2);
    try testing.expectEqual(@as(i32, 2), s.pending.scale);
}

test "role hooks fire at commit, map and unmap" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    test_role_commits = 0;
    test_role_maps = 0;
    test_role_unmaps = 0;
    try role_mod.assignRole(s, &test_role, null);
    try testing.expect(s.role == &test_role);

    var buffer: Buffer = undefined;
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer, 0, 0);
    s.commit();
    try testing.expectEqual(@as(usize, 1), test_role_commits);
    try testing.expectEqual(@as(usize, 1), test_role_maps);
    try testing.expectEqual(@as(usize, 0), test_role_unmaps);

    s.attachBuffer(null, 0, 0);
    s.commit();
    try testing.expectEqual(@as(usize, 2), test_role_commits);
    try testing.expectEqual(@as(usize, 1), test_role_maps);
    try testing.expectEqual(@as(usize, 1), test_role_unmaps);
}

var test_role_commits: usize = 0;
var test_role_maps: usize = 0;
var test_role_unmaps: usize = 0;

const TestRoleHooks = struct {
    fn commit(s: *Surface) void {
        _ = s;
        test_role_commits += 1;
    }
    fn map(s: *Surface) void {
        _ = s;
        test_role_maps += 1;
    }
    fn unmap(s: *Surface) void {
        _ = s;
        test_role_unmaps += 1;
    }
};

var test_role: SurfaceRole = .{
    .name = "test-role",
    .commit = TestRoleHooks.commit,
    .map = TestRoleHooks.map,
    .unmap = TestRoleHooks.unmap,
};
