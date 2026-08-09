//! wl_surface state machine: double-buffered pending/current state,
//! commit pipeline, frame callbacks, map/unmap tracking, role hooks.
//!
//! Commit pipeline order (client commit):
//!   1. validate pending state (posts wl_surface protocol errors and
//!      discards the commit on failure)
//!   2. emit the client_commit signal BEFORE the apply decision, mirroring
//!      wlroots surface_handle_commit (wlr_compositor.c:577-598): the
//!      subcompositor's sync handler locks the pending state here
//!      (wlr_subcompositor.c:224-235)
//!   3. if cached_state_locks is set, the commit is DEFERRED: the pending
//!      state keeps accumulating (sync-subsurface caching) and nothing is
//!      applied or signaled until the lock clears (parent commit, desync,
//!      or teardown — see wlroots surface_cache_pending,
//!      wlr_compositor.c:484-501)
//!   4. applyCommit (wlroots surface_commit_state, wlr_compositor.c:511-575):
//!      swap pending -> current (scalar copy; damage lists transfer so
//!      the pending state restarts empty; frame callbacks accumulate on
//!      current across commits — each waits for the next present)
//!   5. drop the buffer the surface stopped using (its lock was already
//!      released at the end of the previous commit)
//!   6. translate the committed surface damage into buffer coordinates
//!      (scale + inverse transform) and union into current.buffer_damage
//!   7. role.client_commit hook
//!   8. role.commit hook
//!   9. emit the commit signal
//!  10. map/unmap transition: mapped = (current.buffer != null and
//!      width/height > 0); on change, run the role.map/role.unmap hook
//!      and the map/unmap signal
//!  11. unlock the current buffer (wlroots wlr_compositor.c:570-574) so
//!      the client may reuse it (double buffering); the release signal
//!      fires here (buffers/buffer.zig) and completes get_release
//!      callbacks
//!
//! applyCommit also runs directly — without the client_commit phase — when
//! the subcompositor flushes a deferred (cached) commit on the parent's
//! commit, on desync, or at wl_subsurface teardown (wlroots
//! wlr_surface_unlock_cached -> surface_commit_state,
//! wlr_compositor.c:947-986): a flushed commit is not a client commit.
//!
//! Frame callbacks are NOT completed at commit: they accumulate in
//! current.frame_callbacks and are sent with wl_callback.done by
//! sendFrameDone at present time (wlroots wlr_surface_send_frame_done,
//! wlr_compositor.c:1131-1139). wl_surface.frame is a pacing hint, not a
//! commit acknowledgement.
//!
//! M1 simplifications (documented at each site):
//! - opaque/input regions are snapshotted as the region's rect list at
//!   request time (the client may destroy the wl_region afterwards).
//! - surface damage is not clipped to the surface bounds before the
//!   buffer-coordinate translation.
//! - get_release callbacks fire at the commit that releases their buffer
//!   (M1 has no texture cache, so usage ends at the commit).
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
//!       released: bool,
//!       tracked: bool,
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
//! buffer when done presenting. The release signal fires whenever the last
//! lock drops (n_locks == 0) — at most once per buffer lifetime
//! (buffers/buffer.zig); ShmState frees tracked wrappers at deinit, and
//! the surface destroys untracked ones (Buffer.tracked == false) in its
//! buffer-replace and destroy paths.
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
const output_mod = @import("../output/output.zig");
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
    /// Attached buffer (locked while referenced by this state).
    buffer: ?*Buffer = null,
    /// Accumulated damaged rects in surface coordinates.
    surface_damage: Damage,
    /// Accumulated damaged rects in buffer coordinates. wl_surface.damage_buffer
    /// requests accumulate here; the commit unions the surface damage
    /// translated into buffer coordinates on top (see commit/updateBufferDamage).
    buffer_damage: Damage,
    /// Opaque region hint, in surface coordinates; null = no opaque area.
    /// Owned rect list, deep-copied from the wl_region at request time so
    /// the snapshot survives the client destroying the region.
    @"opaque": ?std.ArrayList(Rect) = null,
    /// Input region, in surface coordinates; null = whole surface accepts
    /// input (infinite). Owned rect list (same snapshot semantics).
    input: ?std.ArrayList(Rect) = null,
    /// Transform the client already applied to the buffer contents.
    /// CANONICAL READ: consumers (rendering, input picking, damage
    /// translation) must read `current.transform` — the committed state
    /// after the pending->current swap (swapState). `pending.transform`
    /// is only the client's in-flight request. Mirror of wlroots'
    /// wlr_surface_state.transform (wlr_compositor.h:60-66).
    transform: geom.Transform = .normal,
    /// Scale the client rendered the buffer at.
    /// CANONICAL READ: same rule as transform — read `current.scale`
    /// (the committed value); the surface-local size is the buffer size
    /// transformed and divided by it (wlr_surface_state_has_buffer,
    /// wlr_compositor.h:356).
    scale: i32 = 1,
    /// wl_callback resources created by wl_surface.frame. Completed with
    /// done(ms) at present time by Surface.sendFrameDone (wlroots
    /// wlr_surface_send_frame_done); they accumulate here until then.
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
        if (state.@"opaque") |*list| list.deinit(allocator);
        if (state.input) |*list| list.deinit(allocator);
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
    /// Whether the pending slot holds a locked reference (attach took a
    /// lock). False when the pending buffer is a lockless re-attach of
    /// the current buffer (which already holds the surface's reference).
    pending_locked: bool = false,
    current: State,
    pending: State,
    /// Whether the surface currently presents content (buffer with a
    /// positive size; see the map transition in commit).
    mapped: bool = false,
    /// Deferred-commit lock (mirrors wlroots' pending.cached_state_locks,
    /// wlr_compositor.c:942-945): while set, commit() keeps the pending
    /// state accumulating instead of applying it (wlr_compositor.c:594-598).
    /// Set by the subcompositor's sync handler on the client_commit
    /// signal (wlr_subcompositor.c:224-235); a bool suffices because a
    /// surface holds at most one role, so at most one lock can exist
    /// (wlroots counts multiple synced-object locks).
    cached_state_locks: bool = false,
    /// The output this surface is currently composited on; null = on no
    /// output. Single-output world: wlroots' current_outputs list
    /// (wlr_compositor.h:134-153) collapsed to one slot. Driven by the
    /// compositor through setEntered/setLeft, which emit the enter/leave
    /// signals on change (wlroots wlr_surface_send_enter/send_leave,
    /// wlr_compositor.c:1071-1128 — the wire events are the listener's
    /// job, not the surface's).
    outputs: ?*output_mod.Output = null,
    role: ?*const SurfaceRole = null,
    /// The wire resource that granted the role (e.g. the xdg_surface
    /// resource); the role object is reachable through its user data.
    role_resource: ?*wire.Resource = null,
    events: struct {
        /// The client's wl_surface.commit request arrived (fired by
        /// commit() BEFORE the apply decision, wlroots wlr_compositor.c:
        /// 577-598): the subcompositor sync handler decides deferral
        /// here. Not fired for cache flushes (applyCommit).
        client_commit: wire.Signal(*Surface),
        /// The commit fully processed (role hooks included).
        commit: wire.Signal(*Surface),
        /// The surface became mapped.
        map: wire.Signal(*Surface),
        /// The surface stopped being mapped.
        unmap: wire.Signal(*Surface),
        /// The surface entered an output's composition (payload: the
        /// output; fired by setEntered). The wire wl_surface.enter event
        /// is the listener's job (wlroots wlr_surface_send_enter,
        /// wlr_compositor.c:1071-1103).
        enter: wire.Signal(*output_mod.Output),
        /// The surface left its output's composition (payload: the output
        /// lost; fired by setLeft). Not fired at surface destroy: the
        /// output relationship dies with the surface (wlroots destroys
        /// surface_output entries silently, wlr_compositor.c:1055-1063).
        leave: wire.Signal(*output_mod.Output),
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
                .enter = undefined,
                // SAFETY: initialized via .init() immediately after construction, before any emit.
                .leave = undefined,
                // SAFETY: initialized via .init() immediately after construction, before any emit.
                .destroy = undefined,
            },
        };
        s.events.client_commit.init();
        s.events.commit.init();
        s.events.map.init();
        s.events.unmap.init();
        s.events.enter.init();
        s.events.leave.init();
        s.events.destroy.init();
        resource.setHandler(*Surface, handleRequest, handleDestroy, s);
        return s;
    }

    /// Full teardown. Called from handleDestroy (the wire resource is
    /// dying); also used by the compositor at deinit.
    pub fn destroy(s: *Surface) void {
        log.debug("wl_surface@{d} destroyed", s.io, s.log_cfg, "surface", .{s.resource.getId()});
        // Inert the wire resource: clear its user data (this Surface) and
        // drop the destroy callback so the later client teardown
        // (display.deinit destroying clients) cannot dereference the freed
        // Surface through the resource. The generated bindings expose no
        // wl_resource_set_user_data wrapper, so null the user data via the
        // existing setDispatcher API — same effect as wlroots' inerting
        // (types/output/output.c:146-151: wl_resource_set_user_data(resource, NULL))
        // and it also removes the destroy callback, which the generated
        // destroy wrapper would otherwise call with the stale pointer.
        const res: *server.wl.Resource = @ptrCast(s.resource);
        res.setDispatcher(null, null, null, null);

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
        // Untracked wrappers (shm fromResource with no ShmState) are owned
        // by the surface: destroy them once the drop/unlock completes.
        const current_buf = s.current.buffer;
        if (current_buf) |b| {
            b.drop();
            if (b.n_locks > 0) b.unlock();
            if (!b.tracked) b.destroy();
        }
        const pending_buf = s.pending.buffer;
        if (pending_buf) |b| {
            // A lockless re-attach of the current buffer may leave the same
            // wrapper in both slots (no extra lock held); it was handled —
            // and possibly destroyed — above.
            if (b != current_buf) {
                b.drop();
                if (b.n_locks > 0) b.unlock();
                if (!b.tracked) b.destroy();
            }
        }
        s.current.buffer = null;
        s.pending.buffer = null;
        s.pending_locked = false;
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

    /// Set the pending buffer (from wl_surface.attach). attachBuffer takes
    /// a lock unless it is a lockless re-attach of the current buffer (the
    /// current state already holds the surface's reference); the lock is
    /// released at the end of the commit that applies it (step 10), and
    /// the buffer is dropped when the surface stops using it (replacement
    /// or destroy). A null buffer removes the surface content at the next
    /// commit.
    pub fn attachBuffer(s: *Surface, buffer: ?*Buffer) void {
        if (buffer) |b| {
            // Re-attaching the CURRENT buffer: the current state already
            // holds the surface's reference. Taking another lock would
            // strand the buffer — the commit sees old == new and never
            // releases it (weston-simple-shm hits this on resize).
            if (s.pending.buffer == null and s.current.buffer == b) {
                s.pending_locked = false;
            } else {
                b.lock() catch {
                    // Could not take a reference; nothing to present.
                    b.drop();
                    s.resource.postNoMemory();
                    return;
                };
                s.pending_locked = true;
            }
        } else {
            s.pending_locked = false;
        }
        if (s.pending.buffer) |old| {
            if (old != buffer) {
                // The previously attached (never committed) buffer is done.
                s.fireReleaseCallbacksPending();
                old.drop();
                if (old.n_locks > 0) old.unlock();
            } else {
                // Re-attaching the same buffer: undo the extra lock (only
                // when the previous attach actually took one).
                if (s.pending_locked) {
                    buffer.?.unlock();
                    s.pending_locked = false;
                }
            }
        }
        s.pending.buffer = buffer;
    }

    /// Commit pipeline: see the module comment for the step order.
    pub fn commit(s: *Surface) void {
        // 1. Validate; posts protocol errors and discards the commit.
        if (!s.validatePending()) return;

        // 2. The client_commit signal fires BEFORE the apply decision,
        // mirroring wlroots surface_handle_commit (wlr_compositor.c:577-598):
        // the subcompositor's sync handler decides here whether this commit
        // is deferred (wlr_subcompositor.c:224-235).
        s.events.client_commit.emit(s);

        // 3. Deferred (sync-subsurface caching): the pending state keeps
        // accumulating; nothing is applied and no signals fire until the
        // lock clears (parent commit, desync, or teardown — wlroots
        // surface_cache_pending, wlr_compositor.c:594-598). The cached
        // commits merge into the single pending slot, so the eventual
        // flush applies the latest state in one commit (wlroots keeps a
        // cached-state list and applies each; observationally equivalent
        // for buffer/damage/frame-callback behavior).
        if (s.cached_state_locks) return;

        s.applyCommit();
    }

    /// Apply the pending state (wlroots surface_commit_state,
    /// wlr_compositor.c:511-575). Runs on client commits (from commit)
    /// and directly when the subcompositor flushes a deferred commit
    /// (wlroots wlr_surface_unlock_cached, wlr_compositor.c:947-986): the
    /// flush is not a client commit, so the client_commit phase is
    /// skipped. See the module comment for the step order.
    pub fn applyCommit(s: *Surface) void {
        // 4. Swap pending -> current.
        const old_buffer = s.current.buffer;
        swapState(&s.current, s.allocator, &s.pending);

        // Frame callbacks accumulate across commits until the next
        // present: each wl_surface.frame waits for the present that
        // follows its commit (wlroots surface_state_move appends the
        // pending list to current, wlr_compositor.c:341-348).
        s.current.frame_callbacks.appendSlice(s.allocator, s.pending.frame_callbacks.items) catch {
            s.resource.postNoMemory();
            // The swap already made the pending buffer current; release
            // its attach lock (mirror step 10) so it is not stranded —
            // otherwise the client waits for the buffer until the next
            // successful commit or the surface is destroyed. OOM-only.
            if (s.current.buffer) |b| {
                if (b.n_locks > 0) b.unlock();
            }
            return;
        };
        s.pending.frame_callbacks.clearRetainingCapacity();

        // 5. The surface stopped using the previous buffer. Its lock was
        // already released at the end of the previous commit, so this only
        // marks the producer done; the guard keeps a zero-count buffer
        // (lockless re-attach) from being unlocked.
        if (old_buffer) |old| {
            if (old != s.current.buffer) {
                old.drop();
                if (old.n_locks > 0) old.unlock();
                // Untracked wrappers are caller-owned: this was the
                // surface's last reference, so free the wrapper (detaches
                // its resource listeners). Tracked wrappers belong to
                // ShmState, which frees them at deinit.
                if (!old.tracked) old.destroy();
            }
        }
        // Release callbacks ride along with the current buffer.
        std.mem.swap(std.ArrayList(*server.wl.Callback), &s.release_callbacks_current, &s.release_callbacks_pending);
        s.release_callbacks_pending.clearRetainingCapacity();
        s.buffer = s.current.buffer;

        // 6. Translate the committed surface damage into buffer
        // coordinates (wlroots surface_update_damage, wlr_compositor.c:248-296).
        s.updateBufferDamage();

        // 7. Role-specific processing of the committed state.
        if (s.role) |role| if (role.client_commit) |f| f(s);

        // 8. Role commit hook, then the commit signal. Frame callbacks
        // are not completed here: sendFrameDone fires them at present
        // time (wlroots wlr_surface_send_frame_done). The client_commit
        // signal was already emitted by commit() before the apply
        // decision (step 2); a flush via applyCommit is not a client
        // commit, so it must not re-emit it.
        if (s.role) |role| if (role.commit) |f| f(s);
        s.events.commit.emit(s);

        // 9. Map/unmap transition. wlroots maps only when the buffer has a
        // positive size (wlr_surface_state_has_buffer, wlr_compositor.h:356);
        // the unmap transition stays buffer == null.
        const now_mapped = blk: {
            const b = s.current.buffer orelse break :blk false;
            break :blk b.width > 0 and b.height > 0;
        };
        if (now_mapped and !s.mapped) {
            s.mapped = true;
            if (s.role) |role| if (role.map) |f| f(s);
            s.events.map.emit(s);
        } else if (!now_mapped and s.mapped) {
            s.mapped = false;
            if (s.role) |role| if (role.unmap) |f| f(s);
            s.events.unmap.emit(s);
        }

        // 10. Unlock the current buffer (wlroots wlr_compositor.c:570-574)
        // so the client can reuse it immediately (double buffering). The
        // lockless re-attach special case leaves n_locks at 0, so guard the
        // unlock; the release signal fires here (buffers/buffer.zig) and
        // the get_release callbacks for this buffer complete.
        if (s.current.buffer) |b| {
            if (b.n_locks > 0) b.unlock();
            s.fireReleaseCallbacksCurrent();
        }
    }

    /// Complete every frame callback accumulated since the last present
    /// with the given monotonic time (ms) and destroy the callback
    /// resources (wlroots wlr_surface_send_frame_done,
    /// wlr_compositor.c:1131-1139). Called by the compositor after the
    /// surface's content was presented; the callbacks queue until then.
    /// The u32 wrap-around is fine: the protocol defines an undefined
    /// base for the time.
    pub fn sendFrameDone(s: *Surface, time_ms: u32) void {
        for (s.current.frame_callbacks.items) |cb| cb.destroySendDone(time_ms);
        s.current.frame_callbacks.clearRetainingCapacity();
    }

    /// The surface entered `out`: it is now composited on that output.
    /// Idempotent (no-op when already on it); emits events.enter on the
    /// change. The wire wl_surface.enter event is the listener's job
    /// (wlroots wlr_surface_send_enter, wlr_compositor.c:1071-1103).
    pub fn setEntered(s: *Surface, out: *output_mod.Output) void {
        if (s.outputs == out) return;
        s.outputs = out;
        s.events.enter.emit(out);
    }

    /// The surface left its output. Idempotent; emits events.leave on the
    /// change (wlroots wlr_surface_send_leave, wlr_compositor.c:1105-1128).
    pub fn setLeft(s: *Surface) void {
        const prev = s.outputs orelse return;
        s.outputs = null;
        s.events.leave.emit(prev);
    }

    /// Validate the pending state (posts a wl_surface protocol error and
    /// returns false on failure; the pending state is kept so the client
    /// may fix and re-commit). Public because the subcompositor re-checks
    /// a merged pending at cache flush: deferred commits are validated at
    /// their own commit, but requests made after the last commit are not.
    pub fn validatePending(s: *Surface) bool {
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
        s.attachBuffer(b);
    }

    fn handleDamage(s: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        s.pending.surface_damage.add(.{ .x = x, .y = y, .width = width, .height = height }) catch {
            s.resource.postNoMemory();
            return;
        };
    }

    fn handleDamageBuffer(s: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        // Damage is in buffer coordinates and stays in buffer_damage; the
        // commit unions the surface damage translated into buffer
        // coordinates on top (see updateBufferDamage).
        s.pending.buffer_damage.add(.{ .x = x, .y = y, .width = width, .height = height }) catch {
            s.resource.postNoMemory();
            return;
        };
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
        // The region is snapshotted at request time as an owned rect list
        // (wlroots copies into pending.opaque, wlr_compositor.c:452-460);
        // the client may destroy the wl_region afterwards. Null = no
        // opaque area.
        if (s.pending.@"opaque") |*list| {
            list.deinit(s.allocator);
            s.pending.@"opaque" = null;
        }
        const r: ?*region_mod.Region = if (region) |res| regionModFromResource(res) else null;
        s.pending.@"opaque" = copyRegionRects(s.allocator, r) catch {
            s.resource.postNoMemory();
            return;
        };
    }

    fn handleSetInputRegion(s: *Surface, region: ?*server.wl.Region) void {
        // Null region = infinite input region (whole surface); an empty
        // region = empty rect list (no input accepted). Snapshot as an
        // owned rect list, like opaque.
        if (s.pending.input) |*list| {
            list.deinit(s.allocator);
            s.pending.input = null;
        }
        const r: ?*region_mod.Region = if (region) |res| regionModFromResource(res) else null;
        s.pending.input = copyRegionRects(s.allocator, r) catch {
            s.resource.postNoMemory();
            return;
        };
    }

    fn handleSetBufferTransform(s: *Surface, transform: server.wl.Output.Transform) void {
        const value: i32 = @intFromEnum(transform);
        if (value < 0 or value > 7) {
            s.resource.postError(.invalid_transform, "invalid wl_surface.set_buffer_transform value");
            return;
        }
        s.pending.transform = @enumFromInt(@as(u32, @intCast(value)));
    }

    fn handleSetBufferScale(s: *Surface, scale: i32) void {
        if (scale <= 0) {
            s.resource.postError(.invalid_scale, "wl_surface.set_buffer_scale must be greater than zero");
            return;
        }
        s.pending.scale = scale;
    }

    fn handleOffset(_: *Surface, _: i32, _: i32) void {
        // wl_surface.offset (v5): role-specific location of the pending
        // buffer. M1 stores no attach/offset position (the write-only
        // State.dx/dy were removed); the role ignores it.
    }

    fn fireReleaseCallbacksCurrent(s: *Surface) void {
        for (s.release_callbacks_current.items) |cb| cb.destroySendDone(0);
        s.release_callbacks_current.clearRetainingCapacity();
    }

    fn fireReleaseCallbacksPending(s: *Surface) void {
        for (s.release_callbacks_pending.items) |cb| cb.destroySendDone(0);
        s.release_callbacks_pending.clearRetainingCapacity();
    }

    /// wlroots surface_update_damage (wlr_compositor.c:248-296): translate
    /// the committed surface damage into buffer coordinates and union it
    /// with the damage_buffer rects already swapped into
    /// current.buffer_damage. Scale first, then invert the buffer
    /// transform. Damage is a hint, so over-reporting (saturating on
    /// overflow) is safe.
    fn updateBufferDamage(s: *Surface) void {
        const buf = s.current.buffer orelse return;
        const transform = s.current.transform;
        const size = transform.transformedSize(buf.width, buf.height);
        const inv = inverseTransform(transform);
        for (s.current.surface_damage.rects.items) |rect| {
            const scaled: Rect = .{
                .x = scaleCoord(rect.x, s.current.scale),
                .y = scaleCoord(rect.y, s.current.scale),
                .width = scaleCoord(rect.width, s.current.scale),
                .height = scaleCoord(rect.height, s.current.scale),
            };
            const r = transformRect(scaled, inv, size.w, size.h);
            s.current.buffer_damage.add(r) catch {
                s.resource.postNoMemory();
                return;
            };
        }
    }
};

/// Apply pending to current. Scalar state copies; the damage lists
/// transfer so the pending state restarts empty (the old current damage
/// is stale — M2's damage ring accumulates properly). Frame callbacks do
/// NOT transfer here: Surface.commit accumulates them across commits.
pub fn swapState(current: *State, allocator: Allocator, pending: *State) void {
    current.buffer = pending.buffer;
    pending.buffer = null;
    // Region lists transfer ownership; the previous current lists are
    // discarded. Pending restarts without a region (null opaque = no
    // opaque area, null input = infinite).
    if (current.@"opaque") |*list| list.deinit(allocator);
    current.@"opaque" = pending.@"opaque";
    pending.@"opaque" = null;
    if (current.input) |*list| list.deinit(allocator);
    current.input = pending.input;
    pending.input = null;
    current.transform = pending.transform;
    current.scale = pending.scale;
    std.mem.swap(Damage, &current.surface_damage, &pending.surface_damage);
    pending.surface_damage.clear();
    std.mem.swap(Damage, &current.buffer_damage, &pending.buffer_damage);
    pending.buffer_damage.clear();
    // Frame callbacks are NOT transferred here: they accumulate on
    // current in Surface.commit until the next present (a commit must not
    // drop callbacks that are still waiting for wl_callback.done).
}

fn regionModFromResource(resource: *server.wl.Region) ?*region_mod.Region {
    const ud = resource.getUserData() orelse return null;
    return @ptrCast(@alignCast(ud));
}

/// Deep-copy a wl_region's rect list into an owned list. A null region
/// yields null (opaque: no opaque area; input: infinite); an empty region
/// yields an empty list (input: nothing accepts input). The client may
/// destroy the wl_region after the request; the copy keeps the snapshot
/// alive (wlroots copies at request time, wlr_compositor.c:452-486).
fn copyRegionRects(
    allocator: Allocator,
    region: ?*region_mod.Region,
) Allocator.Error!?std.ArrayList(Rect) {
    const r = region orelse return null;
    var list: std.ArrayList(Rect) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, r.rects.items);
    return list;
}

/// Inverse of a buffer transform (wlr_output_transform_invert, wlroots
/// util/transform.c:3-9): rotations swap 90<->270 (and flipped variants),
/// everything else maps to itself.
fn inverseTransform(t: geom.Transform) geom.Transform {
    return switch (t) {
        .@"90" => .@"270",
        .@"270" => .@"90",
        .flipped_90 => .flipped_270,
        .flipped_270 => .flipped_90,
        else => t,
    };
}

/// Multiply with saturation so a client-supplied huge rect cannot
/// overflow i32 (damage is a hint; over-reporting is safe).
fn scaleCoord(v: i32, scale: i32) i32 {
    return std.math.mul(i32, v, scale) catch blk: {
        break :blk if (v < 0) std.math.minInt(i32) else std.math.maxInt(i32);
    };
}

fn addSat(a: i32, b: i32) i32 {
    return std.math.add(i32, a, b) catch blk: {
        break :blk if (b < 0) std.math.minInt(i32) else std.math.maxInt(i32);
    };
}

fn subSat(a: i32, b: i32) i32 {
    return std.math.sub(i32, a, b) catch blk: {
        break :blk if (a < b) std.math.minInt(i32) else std.math.maxInt(i32);
    };
}

/// Transform a rect by `transform`, treating it as a box of size
/// (width, height) (wlr_region_transform, wlroots util/region.c:57-105).
/// Used to map surface damage back into buffer coordinates. All arithmetic
/// saturates: the rects come from the client and damage is a hint.
fn transformRect(r: Rect, transform: geom.Transform, width: i32, height: i32) Rect {
    const x1 = r.x;
    const y1 = r.y;
    const x2 = addSat(r.x, r.width);
    const y2 = addSat(r.y, r.height);
    return switch (transform) {
        .normal => r,
        .@"90" => .{ .x = subSat(height, y2), .y = x1, .width = subSat(y2, y1), .height = subSat(x2, x1) },
        .@"180" => .{
            .x = subSat(width, x2),
            .y = subSat(height, y2),
            .width = subSat(x2, x1),
            .height = subSat(y2, y1),
        },
        .@"270" => .{ .x = y1, .y = subSat(width, x2), .width = subSat(y2, y1), .height = subSat(x2, x1) },
        .flipped => .{ .x = subSat(width, x2), .y = y1, .width = subSat(x2, x1), .height = subSat(y2, y1) },
        .flipped_90 => .{ .x = y1, .y = x1, .width = subSat(y2, y1), .height = subSat(x2, x1) },
        .flipped_180 => .{ .x = x1, .y = subSat(height, y2), .width = subSat(x2, x1), .height = subSat(y2, y1) },
        .flipped_270 => .{
            .x = subSat(height, y2),
            .y = subSat(width, x2),
            .width = subSat(y2, y1),
            .height = subSat(x2, x1),
        },
    };
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
        .destroy => {
            // wlroots rejects wl_surface.destroy while a role object
            // exists (wlr_compositor.c:56-66): the role object must be
            // destroyed first.
            if (s.role_resource != null) {
                s.resource.postError(.defunct_role_object, "surface was destroyed before its role object");
                return;
            }
            resource.destroy();
        },
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

fn fakeBufferDestroy(_: std.mem.Allocator, _: *anyopaque) void {}

var test_buffer_impl: buffer_mod.Impl = .{
    .get_dmabuf = null,
    .get_shm = null,
    .begin_data_ptr_access = null,
    .end_data_ptr_access = null,
    .destroy = fakeBufferDestroy,
};

// --- Tests --------------------------------------------------------------

test "enter/leave signals fire once per output transition" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    test_enter_count = 0;
    test_leave_count = 0;
    test_enter_listener = wire.Listener(*output_mod.Output).init(testEnterNotify);
    test_leave_listener = wire.Listener(*output_mod.Output).init(testLeaveNotify);
    s.events.enter.add(&test_enter_listener);
    s.events.leave.add(&test_leave_listener);

    // SAFETY: test fixture; the payload pointer is only passed through
    // the signal, never dereferenced.
    const fake_out: *output_mod.Output = @ptrFromInt(0x100);
    try testing.expect(s.outputs == null);

    s.setEntered(fake_out);
    try testing.expect(s.outputs == fake_out);
    try testing.expectEqual(@as(usize, 1), test_enter_count);

    // Idempotent: re-entering the same output fires nothing.
    s.setEntered(fake_out);
    try testing.expectEqual(@as(usize, 1), test_enter_count);

    s.setLeft();
    try testing.expect(s.outputs == null);
    try testing.expectEqual(@as(usize, 1), test_leave_count);

    // Idempotent: leaving without an output fires nothing.
    s.setLeft();
    try testing.expectEqual(@as(usize, 1), test_leave_count);
}

var test_enter_count: usize = 0;
var test_leave_count: usize = 0;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_enter_listener: wire.Listener(*output_mod.Output) = undefined;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_leave_listener: wire.Listener(*output_mod.Output) = undefined;

fn testEnterNotify(listener: *wire.Listener(*output_mod.Output), _: *output_mod.Output) void {
    _ = listener;
    test_enter_count += 1;
}

fn testLeaveNotify(listener: *wire.Listener(*output_mod.Output), _: *output_mod.Output) void {
    _ = listener;
    test_leave_count += 1;
}

test "state swap transfers damage and regions, resets pending" {
    const allocator = testing.allocator;
    var current = State.init(allocator);
    defer current.deinit(allocator);
    var pending = State.init(allocator);
    defer pending.deinit(allocator);

    try pending.surface_damage.add(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    try pending.buffer_damage.add(.{ .x = 5, .y = 6, .width = 7, .height = 8 });
    try pending.frame_callbacks.append(allocator, @as(*server.wl.Callback, @ptrFromInt(0x100)));
    pending.buffer = @as(?*Buffer, @ptrFromInt(0x200));
    {
        var list: std.ArrayList(Rect) = .empty;
        try list.append(allocator, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
        pending.@"opaque" = list;
    }
    {
        var list: std.ArrayList(Rect) = .empty;
        try list.append(allocator, .{ .x = 7, .y = 8, .width = 1, .height = 1 });
        pending.input = list;
    }
    pending.transform = .@"90";
    pending.scale = 2;

    swapState(&current, allocator, &pending);

    try testing.expectEqual(@as(?*Buffer, @ptrFromInt(0x200)), current.buffer);
    try testing.expect(pending.buffer == null);
    try testing.expectEqual(@as(usize, 1), current.@"opaque".?.items.len);
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .width = 2, .height = 2 }, current.@"opaque".?.items[0]);
    try testing.expect(pending.@"opaque" == null);
    try testing.expectEqual(@as(usize, 1), current.input.?.items.len);
    try testing.expect(pending.input == null);
    try testing.expectEqual(geom.Transform.@"90", current.transform);
    try testing.expectEqual(@as(i32, 2), current.scale);
    try testing.expectEqual(@as(usize, 1), current.surface_damage.rects.items.len);
    try testing.expect(pending.surface_damage.isEmpty());
    try testing.expectEqual(@as(usize, 1), current.buffer_damage.rects.items.len);
    try testing.expect(pending.buffer_damage.isEmpty());
    // Frame callbacks are NOT moved by swapState: Surface.commit
    // accumulates them on current across commits until the next present.
    try testing.expectEqual(@as(usize, 0), current.frame_callbacks.items.len);
    try testing.expectEqual(@as(usize, 1), pending.frame_callbacks.items.len);
}

test "damage requests accumulate in separate coordinate spaces" {
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

    // wl_surface.damage stays in surface coordinates; damage_buffer keeps
    // its own buffer-coordinate list (they are not folded together).
    try testing.expectEqual(@as(usize, 1), s.pending.surface_damage.rects.items.len);
    try testing.expectEqual(@as(usize, 1), s.pending.buffer_damage.rects.items.len);
}

test "frame callbacks are deferred until sendFrameDone" {
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

    // Commit only stores the callbacks (moved to current); the done event
    // fires later, at present time, via sendFrameDone (wlroots
    // wlr_surface_send_frame_done, wlr_compositor.c:1131-1139).
    try testing.expectEqual(@as(usize, 0), s.pending.frame_callbacks.items.len);
    try testing.expectEqual(@as(usize, 2), s.current.frame_callbacks.items.len);

    // Multiple commits accumulate callbacks until the present.
    s.handleFrame(tw.newId());
    s.commit();
    try testing.expectEqual(@as(usize, 3), s.current.frame_callbacks.items.len);

    // sendFrameDone completes and destroys them.
    s.sendFrameDone(1234);
    try testing.expectEqual(@as(usize, 0), s.current.frame_callbacks.items.len);

    // A later frame callback is held again until the next sendFrameDone.
    s.handleFrame(tw.newId());
    s.commit();
    try testing.expectEqual(@as(usize, 1), s.current.frame_callbacks.items.len);
    s.sendFrameDone(2345);
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
    s.attachBuffer(&buffer);
    s.commit();

    try testing.expect(s.mapped);
    try testing.expect(s.buffer == &buffer);
    try testing.expect(s.current.buffer == &buffer);
    try testing.expect(s.pending.buffer == null);
    try testing.expectEqual(@as(usize, 1), test_map_count);
    try testing.expectEqual(@as(usize, 0), test_unmap_count);
    try testing.expectEqual(@as(usize, 1), test_commit_count);

    // Null attach commits remove the content: unmap.
    s.attachBuffer(null);
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
var test_destroy_count: usize = 0;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_map_listener: wire.Listener(*Surface) = undefined;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_unmap_listener: wire.Listener(*Surface) = undefined;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_commit_listener: wire.Listener(*Surface) = undefined;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_destroy_listener: wire.Listener(*Surface) = undefined;

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

fn testDestroyNotify(listener: *wire.Listener(*Surface), surface: *Surface) void {
    _ = listener;
    _ = surface;
    test_destroy_count += 1;
}

test "commit unlocks the current buffer at commit end" {
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
    s.attachBuffer(&b1);
    s.commit();
    // The attach lock is released at the END of the commit (wlroots
    // wlr_compositor.c:570-574) so the client can reuse the buffer; the
    // release signal fired without any drop (fix 1).
    try testing.expectEqual(@as(u32, 0), b1.n_locks);
    try testing.expect(!b1.dropped);
    try testing.expect(s.current.buffer == &b1);

    s.attachBuffer(&b2);
    s.commit();
    // b1 was swapped out: dropped (producer done); it was already unlocked.
    try testing.expect(b1.dropped);
    try testing.expectEqual(@as(u32, 0), b1.n_locks);
    try testing.expectEqual(@as(u32, 0), b2.n_locks);
    try testing.expect(s.current.buffer == &b2);
}

test "re-attach of the current buffer does not double-lock" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    var b: Buffer = undefined;
    testBuffer(allocator, &b);
    s.attachBuffer(&b);
    s.commit();
    try testing.expectEqual(@as(u32, 0), b.n_locks);

    // Lockless re-attach of the current buffer (weston-simple-shm resize
    // pattern): no new lock is taken, and the commit-end unlock must not
    // underflow a zero-count buffer.
    s.attachBuffer(&b);
    try testing.expect(!s.pending_locked);
    s.commit();
    try testing.expectEqual(@as(u32, 0), b.n_locks);
    try testing.expect(s.current.buffer == &b);
    try testing.expect(!b.dropped);
}

test "get_release callbacks fire when the buffer is released at commit end" {
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
    s.attachBuffer(&b1);
    s.handleGetRelease(tw.newId());
    try testing.expectEqual(@as(usize, 1), s.release_callbacks_pending.items.len);
    s.commit();
    // M1: usage ends at the commit, which releases the buffer; the
    // callback is completed in the same commit.
    try testing.expectEqual(@as(usize, 0), s.release_callbacks_current.items.len);
    try testing.expectEqual(@as(usize, 0), s.release_callbacks_pending.items.len);

    // Replacing the buffer drops the old one; its callbacks already fired.
    var b2: Buffer = undefined;
    testBuffer(allocator, &b2);
    s.attachBuffer(&b2);
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
    s.attachBuffer(&buffer);
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
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expectEqual(@as(usize, 1), test_role_commits);
    try testing.expectEqual(@as(usize, 1), test_role_maps);
    try testing.expectEqual(@as(usize, 0), test_role_unmaps);

    s.attachBuffer(null);
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

test "commit with a zero-sized buffer does not map" {
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
    testBuffer(allocator, &buffer); // 10x10, then zeroed
    buffer.width = 0;
    buffer.height = 0;
    s.attachBuffer(&buffer);
    s.commit();

    // A zero-sized buffer is rejected at validation (invalid_size) and the
    // commit is discarded; wlroots additionally only maps buffers with
    // width/height > 0 (wlr_surface_state_has_buffer, wlr_compositor.h:356).
    try testing.expect(s.current.buffer == null);
    try testing.expect(!s.mapped);
}

test "wl_surface.destroy is rejected while a role object exists" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    test_destroy_count = 0;
    test_destroy_listener = wire.Listener(*Surface).init(testDestroyNotify);
    s.events.destroy.add(&test_destroy_listener);

    // A role object is present (dummy resource pointer, never dereferenced).
    try role_mod.assignRole(s, &test_role, @ptrFromInt(0x1));
    try testing.expect(s.role_resource != null);

    // The client's wl_surface.destroy request is rejected with
    // DEFUNCT_ROLE_OBJECT (wlr_compositor.c:56-66): the surface survives.
    handleRequest(s.resource, .destroy, s);
    try testing.expectEqual(@as(usize, 0), test_destroy_count);

    // Once the role object is gone, the same request tears the surface
    // down (the destroy signal fires).
    s.role = null;
    s.role_resource = null;
    handleRequest(s.resource, .destroy, s);
    try testing.expectEqual(@as(usize, 1), test_destroy_count);
}

test "opaque and input regions are snapshotted as rect lists" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    // Fabricate a wl_region with two disjoint rects.
    const region_res = try server.wl.Region.create(tw.client, 1, tw.newId());
    const region = try region_mod.Region.create(allocator, region_res);
    region.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    region.add(.{ .x = 20, .y = 0, .width = 5, .height = 5 });

    s.handleSetOpaqueRegion(region_res);
    s.handleSetInputRegion(region_res);

    // The full rect list is kept, not a lossy bounding rect.
    try testing.expectEqual(@as(usize, 2), s.pending.@"opaque".?.items.len);
    try testing.expectEqual(@as(usize, 2), s.pending.input.?.items.len);

    // The snapshot survives the client destroying the wl_region.
    region_res.destroy();
    try testing.expectEqual(@as(usize, 2), s.pending.@"opaque".?.items.len);

    // Commit transfers ownership to current; pending restarts empty.
    var buffer: Buffer = undefined;
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expectEqual(@as(usize, 2), s.current.@"opaque".?.items.len);
    try testing.expectEqual(@as(usize, 2), s.current.input.?.items.len);
    try testing.expect(s.pending.@"opaque" == null);
    try testing.expect(s.pending.input == null);

    // Null regions: no opaque area, infinite input.
    s.handleSetOpaqueRegion(null);
    s.handleSetInputRegion(null);
    try testing.expect(s.pending.@"opaque" == null);
    try testing.expect(s.pending.input == null);
}

test "commit translates surface damage into buffer coordinates" {
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
    testBuffer(allocator, &buffer); // 10x10, scale 1, normal transform
    s.attachBuffer(&buffer);
    s.handleDamage(1, 2, 3, 4);
    s.handleDamageBuffer(10, 20, 30, 40);
    s.commit();

    // The damage_buffer rect stays as-is; the surface damage (1,2,3,4) is
    // appended translated (scale 1, normal transform: unchanged).
    try testing.expectEqual(@as(usize, 2), s.current.buffer_damage.rects.items.len);
    try testing.expectEqual(
        Rect{ .x = 10, .y = 20, .width = 30, .height = 40 },
        s.current.buffer_damage.rects.items[0],
    );
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .width = 3, .height = 4 }, s.current.buffer_damage.rects.items[1]);

    // Surface damage stays in surface coordinates (the M2 ring reads it).
    try testing.expectEqual(@as(usize, 1), s.current.surface_damage.rects.items.len);
}

test "surface damage translation applies scale and transform" {
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
    s.handleSetBufferScale(2);
    s.handleSetBufferTransform(server.wl.Output.Transform.@"90");
    s.attachBuffer(&buffer);
    s.handleDamage(1, 2, 3, 4);
    s.commit();

    // Scale 2: (1,2,3,4) -> (2,4,6,8). Inverse of 90 is 270, applied to
    // the 10x10 surface box: (x,y,w,h) = (4,2,8,6).
    try testing.expectEqual(@as(usize, 1), s.current.buffer_damage.rects.items.len);
    try testing.expectEqual(Rect{ .x = 4, .y = 2, .width = 8, .height = 6 }, s.current.buffer_damage.rects.items[0]);
}
