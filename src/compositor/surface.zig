//! wl_surface state machine: double-buffered pending/current state,
//! commit pipeline, frame callbacks, map/unmap tracking, role hooks.
//!
//! Commit pipeline order (client commit):
//!   1. validate pending state (posts wl_surface protocol errors and
//!      discards the commit on failure)
//!   2. role.client_commit hook — once per client commit, before the
//!      apply decision (wlroots wlr_compositor.c:582-584; F36)
//!   3. emit the client_commit signal BEFORE the apply decision, mirroring
//!      wlroots surface_handle_commit (wlr_compositor.c:577-598): the
//!      subcompositor's sync handler locks the pending state here
//!      (wlr_subcompositor.c:224-235)
//!   4. if cached_state_locks is set, the commit is DEFERRED: the pending
//!      state keeps accumulating (sync-subsurface caching) and nothing is
//!      applied or signaled until the lock clears (parent commit, desync,
//!      or teardown — see wlroots surface_cache_pending,
//!      wlr_compositor.c:484-501). F35: wlroots keeps a per-commit
//!      cached-state list and applies only committed states at flush;
//!      the merged single slot also applies post-commit requests
//!      (STRUCTURAL, deferred).
//!   5. applyCommit (wlroots surface_commit_state, wlr_compositor.c:511-575),
//!      TRANSACTIONAL (F31): all fallible work (frame-callback append,
//!      damage translation) runs before the swap; an OOM aborts with the
//!      state untouched + postNoMemory. Then:
//!      a. snapshot previous geometry (scale/transform/buffer size, F38)
//!      b. swap pending -> current (committed-mask filtered, F33)
//!      c. drop the buffer the surface stopped using (its lock was
//!         already released at the end of the previous commit)
//!      d. the get_release callbacks move onto the committed buffer,
//!         which completes them at ITS final unlock — not at this
//!         commit: a renderer may still be sampling the pixels
//!      e. role.commit hook
//!      f. emit the commit signal
//!      g. map/unmap transition: mapped = isEffectivelyMapped (current
//!         buffer != null with width/height > 0 AND the role's mapped
//!         gate — the subsurface parent chain, wayland.xml:3254-3258);
//!         on change, run the map/unmap signal and the role hook (unmap:
//!         signal first, then role — F37)
//!      h. unlock the current buffer (wlroots wlr_compositor.c:570-574) so
//!         the client may reuse it (double buffering); the release signal
//!         fires here (buffers/buffer.zig)
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
//! - get_release callbacks are NOT fired by this surface. They are handed
//!   to the buffer they were requested for at the commit, and the buffer
//!   completes them when the compositor stops reading it — which is the
//!   protocol promise (wayland.xml, get_release) and outlives both this
//!   surface and the client-side callback object.
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
//!   pub fn unlock(b: *Buffer) void;
//!   pub fn destroy(b: *Buffer) void;
//!   pub fn queueReleaseCallback(b: *Buffer, cb: *server.wl.Callback) !void;
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
//! lock drops (n_locks == 0) — at most once per lock cycle
//! (buffers/buffer.zig). A wrapper dies with its wire resource, which is
//! safe while a surface still points at it: the surface's own destroy
//! listener clears the slot in the same emission, before it touches the
//! buffer. Only untracked wrappers are destroyed by the surface
//! (Buffer.tracked == false); a tracked one stays reachable through
//! ShmState for as long as its resource lives.
//!
//! Cross-module: src/compositor/compositor.zig (this cluster):
//!   Compositor.removeSurface(*Surface) void — called by Surface.destroy.
//!   Compositor.resolveDmabuf(*wire.Resource) ?*Buffer — asked FIRST in
//!     handleAttach, before the shm registry: a zwp_linux_dmabuf_v1
//!     wl_buffer is not an shm pool buffer, so the shm wrap would answer
//!     error.InvalidBuffer and kill the client (F56). Null means "not a
//!     dmabuf buffer", and the shm path runs exactly as before.

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
    /// translated into buffer coordinates on top (see commit/translateDamage).
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
    /// Which request handlers have run since the last commit (wlroots
    /// wlr_surface_state.committed, wlr_compositor.h:38): swapState applies
    /// exactly the fields whose bit is set and leaves the rest of the
    /// committed surface alone (F33). This is PENDING-side bookkeeping — a
    /// record of the requests the client made, not a description of the
    /// committed surface — and the swap consumes it, so pending restarts
    /// with an empty mask (wlroots clears it in surface_state_move,
    /// wlr_compositor.c:397-399). Pending values otherwise persist across
    /// commits; the opaque/input regions are the exception (pending does
    /// not persist them — the swap moves the list out and nulls it).
    /// Damage transfers unconditionally: pending damage is always empty
    /// after a transfer, so wlroots' conditional clear-and-copy
    /// (wlr_compositor.c:374-385) is identical.
    committed: Committed = .{},
    /// wp_viewport crop/scale state (wlroots wlr_surface_state.viewport,
    /// wlr_compositor.h:45-50): written by the viewporter module from
    /// set_source/set_destination, applied by the commit (F-AX-11). The
    /// pending value persists across commits; a commit without the
    /// committed.viewport bit keeps the current value.
    viewport: Viewport = .{},
    /// wl_callback resources created by wl_surface.frame. Completed with
    /// done(ms) at present time by Surface.sendFrameDone (wlroots
    /// wlr_surface_send_frame_done); they accumulate here until then.
    frame_callbacks: std.ArrayList(*server.wl.Callback) = .empty,

    /// Which pending-state fields the client changed since the last commit
    /// (see `committed`); one bit per request handler that writes state.
    pub const Committed = struct {
        /// A wl_surface.attach arrived (null attach included: the
        /// NULL-buffer unmap commit).
        buffer: bool = false,
        /// A wl_surface.set_opaque_region arrived.
        @"opaque": bool = false,
        /// A wl_surface.set_input_region arrived.
        input: bool = false,
        /// A wl_surface.set_buffer_transform arrived.
        transform: bool = false,
        /// A wl_surface.set_buffer_scale arrived.
        scale: bool = false,
        /// A wp_viewport.set_source / set_destination arrived.
        viewport: bool = false,
    };

    /// wp_viewport crop/scale state (wlroots wlr_surface_state.viewport,
    /// wlr_compositor.h:45-50): the source crop in surface-local
    /// coordinates (after buffer_transform + buffer_scale) and the
    /// destination size. has_src/has_dst false = that half is unset.
    pub const Viewport = struct {
        has_src: bool = false,
        src: geom.FRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        has_dst: bool = false,
        dst: geom.Size = .{ .w = 0, .h = 0 },
    };

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
    /// Snapshot of the committed state before the last applyCommit
    /// (wlroots surface->previous, wlr_compositor.c:523-528): consumers
    /// diff this against the new current to damage the OLD footprint when
    /// the surface geometry changes (scale/transform/buffer size — M2
    /// damage ring). Populated at the top of every applyCommit; stale
    /// (from the last apply) while a commit is deferred or aborted.
    pub const Previous = struct {
        scale: i32 = 1,
        transform: geom.Transform = .normal,
        buffer_width: i32 = 0,
        buffer_height: i32 = 0,
    };
    const OutputAssociation = struct {
        surface: *Surface,
        output: *output_mod.Output,
        destroy_listener: wire.Listener(*output_mod.Output),

        fn onDestroy(listener: *wire.Listener(*output_mod.Output), out: *output_mod.Output) void {
            const association: *@This() = @fieldParentPtr("destroy_listener", listener);
            association.surface.leaveOutput(out);
        }
    };
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    /// The wl_surface wire resource; its user data is this Surface.
    resource: *server.wl.Surface,
    compositor: *Compositor,
    /// Current buffer (mirror of current.buffer) for quick access.
    buffer: ?*Buffer = null,
    /// The pending attachment owns exactly one consumer lock.
    pending_locked: bool = false,
    /// The lock being applied, released after scene/role commit hooks.
    current_locked: bool = false,
    /// The wl_buffer wire resource attached to the pending slot (null
    /// for a null attach). Mirrors wlroots' surface->pending.buffer_resource
    /// (wlr_compositor.c:38): its destroy listener clears the pending slot
    /// when the client destroys the resource, so the next commit is a
    /// NULL-buffer commit (unmap) instead of committing a dead wrapper.
    pending_resource: ?*wire.Resource = null,
    /// Same tracking for the committed (current) slot; pending_resource
    /// moves here at applyCommit. When the client destroys the displayed
    /// buffer's resource, the listener clears current so the surface does
    /// not keep a dead wrapper in its canonical buffer slot (F42).
    current_resource: ?*wire.Resource = null,
    /// Destroy listeners for the two slots above. They are SEPARATE
    /// records on purpose: one listener can only watch one resource, so a
    /// single shared listener silently stopped observing the displayed
    /// buffer the moment a second buffer was attached — the pending one
    /// is what the client destroys first, and the current slot kept a
    /// dead mirror with nothing watching it.
    pending_buffer_destroy: wire.Listener(*wire.Resource),
    current_buffer_destroy: wire.Listener(*wire.Resource),
    current: State,
    pending: State,
    /// Snapshot of the committed state before the last applyCommit
    /// (see Previous above).
    previous: Previous = .{},
    /// Whether the surface currently presents content: positive-size
    /// current buffer AND the role's mapped gate (see updateMapped).
    mapped: bool = false,
    /// Deferred-commit lock (mirrors wlroots' pending.cached_state_locks,
    /// wlr_compositor.c:942-945): while set, commit() keeps the pending
    /// state accumulating instead of applying it (wlr_compositor.c:594-598).
    /// Set by the subcompositor's sync handler on the client_commit
    /// signal (wlr_subcompositor.c:224-235); a bool suffices because a
    /// surface holds at most one role, so at most one lock can exist
    /// (wlroots counts multiple synced-object locks).
    cached_state_locks: bool = false,
    /// Output memberships have stable storage for their destroy listeners.
    outputs: std.ArrayList(*OutputAssociation) = .empty,
    destroying: bool = false,

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
    /// get_release callbacks requested since the last commit. They are
    /// not owned beyond the commit: at the commit the buffer takes them
    /// over (buffers/buffer.zig), because the protocol promise is about
    /// the BUFFER ("when the compositor stops using it"), and this
    /// surface — or the client — may be gone long before the last reader
    /// unlocks.
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
            // SAFETY: initialized via .link.init() immediately after
            // construction, before it can be attached to a resource.
            .pending_buffer_destroy = wire.Listener(*wire.Resource).init(onPendingBufferDestroy),
            .current_buffer_destroy = wire.Listener(*wire.Resource).init(onCurrentBufferDestroy),
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
        // Listener.init leaves the intrusive link undefined; put both in
        // the detached state (link.prev == link.next == &link) so the
        // attached-or-not check in detachBufferListener works.
        s.pending_buffer_destroy.link.init();
        s.current_buffer_destroy.link.init();
        resource.setHandler(*Surface, handleRequest, handleDestroy, s);
        return s;
    }

    /// Full teardown. Called from handleDestroy (the wire resource is
    /// dying); also used by the compositor at deinit.
    pub fn destroy(s: *Surface) void {
        log.debug("wl_surface@{d} destroyed", s.io, s.log_cfg, "surface", .{s.resource.getId()});
        s.destroying = true;
        while (s.outputs.items.len != 0) {
            s.removeOutputAssociation(s.outputs.items.len - 1);
        }
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
            // F37: wlroots emits the unmap signal BEFORE the role hook
            // (wlr_surface_unmap wlr_compositor.c:854-872); listeners see
            // the signal first.
            s.events.unmap.emit(s);
            if (s.role) |role| if (role.unmap) |f| f(s);
        }
        if (s.role) |role| if (role.destroy) |f| f(s);
        s.events.destroy.emit(s);

        // Detach both buffer-resource destroy listeners: the client's
        // wl_buffer resources outlive the surface, and the listeners live
        // inside the freed Surface. If a resource was already destroyed,
        // its handler detached itself (link in the detached state).
        detachBufferListener(&s.pending_buffer_destroy);
        detachBufferListener(&s.current_buffer_destroy);

        // Release only locks taken by this surface. Renderer locks may
        // still retain the source backing until its texture is destroyed.
        const current_buf = s.buffer;
        const pending_buf = s.pending.buffer;
        const current_locked = s.current_locked;
        const pending_locked = s.pending_locked;
        s.current.buffer = null;
        s.pending.buffer = null;
        s.current_locked = false;
        s.pending_locked = false;
        s.buffer = null;
        s.pending_resource = null;
        s.current_resource = null;
        // The get_release callbacks outlive the surface: hand them to the
        // buffer they were requested for BEFORE its last lock goes, and
        // the buffer completes them when the compositor is really done.
        if (current_buf) |b| s.transferReleaseCallbacks(b);
        if (pending_buf) |b| {
            if (pending_buf != current_buf) s.transferReleaseCallbacks(b);
        }
        if (current_buf) |b| {
            const pending_is_current = pending_buf == b;
            b.drop();
            if (!b.tracked) b.destroy();
            if (current_locked) b.unlock();
            if (pending_is_current and pending_locked) b.unlock();
        }
        if (pending_buf) |b| {
            if (b != current_buf) {
                b.drop();
                if (!b.tracked) b.destroy();
                if (pending_locked) b.unlock();
            }
        }
        // Whatever is left had no buffer to wait on (an attach never
        // reached the surface); it dies with the surface, exactly like an
        // uncompleted frame callback.
        for (s.release_callbacks_pending.items) |cb| cb.destroy();

        // Frame callbacks that were never completed: destroy the wire
        // resources (no done event is sent for a destroyed surface).
        for (s.current.frame_callbacks.items) |cb| cb.destroy();
        for (s.pending.frame_callbacks.items) |cb| cb.destroy();

        s.release_callbacks_pending.deinit(s.allocator);
        s.current.deinit(s.allocator);
        s.pending.deinit(s.allocator);
        s.compositor.removeSurface(s);
        s.outputs.deinit(s.allocator);
        s.allocator.destroy(s);
    }

    /// Set the pending buffer (from wl_surface.attach). Every attach takes
    /// a lock — including a re-attach of the current buffer: the commit's
    /// final unlock (step 11) releases each use, so the client receives a
    /// wl_buffer.release per attach. That per-use release is required:
    /// weston's shm_surface keeps a leaf busy until the release arrives
    /// and exit(1)s when its whole pool is busy ("all buffers are held by
    /// the server", clients/window.c shm_surface_prepare) — a lockless
    /// re-attach leaves the leaf stuck forever. A re-attach of the SAME
    /// pending buffer (no commit in between) undoes the redundant lock
    /// instead.
    pub fn attachBuffer(s: *Surface, buffer: ?*Buffer) void {
        const previous_locked = s.pending_locked;
        if (buffer) |b| {
            b.lock() catch {
                s.resource.postNoMemory();
                return;
            };
        }
        if (s.pending.buffer) |old| {
            if (old == buffer) {
                // The original pending lock survives a repeated attach.
                buffer.?.unlock();
                s.pending_locked = previous_locked;
                s.pending.committed.buffer = true;
                return;
            }
            // The get_release callbacks requested against the buffer we
            // just dropped belong to THAT buffer: hand them over before
            // its last lock goes, and it completes them when the
            // compositor is really done with it.
            s.transferReleaseCallbacks(old);
            old.drop();
            if (previous_locked) old.unlock();
        }
        s.pending.buffer = buffer;
        s.pending_locked = buffer != null;
        s.pending.committed.buffer = true;
    }

    /// Commit pipeline: see the module comment for the step order.
    pub fn commit(s: *Surface) void {
        // 1. Validate; posts protocol errors and discards the commit.
        if (!s.validatePending()) return;

        // 2. Role-specific processing of the client's committed state
        // (F36). wlroots runs role->client_commit inside surface_handle_commit
        // for EVERY client commit, before the deferral decision
        // (wlr_compositor.c:582-584), so it runs exactly once per client
        // commit and NOT on cache flushes (applyCommit from the
        // subcompositor is not a client commit).
        if (s.role) |role| if (role.client_commit) |f| f(s);

        // 3. The client_commit signal fires BEFORE the apply decision,
        // mirroring wlroots surface_handle_commit (wlr_compositor.c:577-598):
        // the subcompositor's sync handler decides here whether this commit
        // is deferred (wlr_subcompositor.c:224-235).
        s.events.client_commit.emit(s);

        // 4. Deferred (sync-subsurface caching): the pending state keeps
        // accumulating; nothing is applied and no signals fire until the
        // lock clears (parent commit, desync, or teardown — wlroots
        // surface_cache_pending, wlr_compositor.c:594-598). The cached
        // commits merge into the single pending slot, so the eventual
        // flush applies the latest state in one commit. F35 (STRUCTURAL):
        // wlroots keeps a per-commit cached-state list and the flush
        // applies only committed states in order; the merged-slot
        // approximation also applies requests the client made after its
        // last deferred commit.
        if (s.cached_state_locks) return;

        s.applyCommit();
    }

    /// Apply the pending state (wlroots surface_commit_state,
    /// wlr_compositor.c:511-575). Runs on client commits (from commit)
    /// and directly when the subcompositor flushes a deferred commit
    /// (wlroots wlr_surface_unlock_cached, wlr_compositor.c:947-986): the
    /// flush is not a client commit, so the client_commit phase is
    /// skipped. See the module comment for the step order.
    ///
    /// Transactional (F31): everything that can fail — the frame-callback
    /// append and the damage translation — happens BEFORE the swap, while
    /// the current state is untouched. On OOM the commit aborts with the
    /// state intact (pending stays pending with its attach lock held; no
    /// role hooks, signals, or unlock) and the client is told via
    /// postNoMemory, mirroring wlroots' surface_cache_pending
    /// (wlr_compositor.c:475-510). The damage translation is a hint: its
    /// OOM posts no_memory but does not abort the commit.
    pub fn applyCommit(s: *Surface) void {
        // 4. Snapshot the previous committed geometry (F38, wlroots
        // wlr_compositor.c:523-528): consumers diff old vs new to damage
        // the OLD footprint when scale/transform/buffer size change.
        // F32/C-CS-5: the previous presented content is `s.buffer` (the
        // persistent cache) — `s.current.buffer` was NULLed last commit.
        const old_buffer = s.buffer;
        s.previous.scale = s.current.scale;
        s.previous.transform = s.current.transform;
        s.previous.buffer_width = if (old_buffer) |b| b.width else 0;
        s.previous.buffer_height = if (old_buffer) |b| b.height else 0;

        // 5. Frame callbacks accumulate across commits until the next
        // present: each wl_surface.frame waits for the present that
        // follows its commit (wlroots surface_state_move appends the
        // pending list to current, wlr_compositor.c:341-348). Before the
        // swap so an OOM aborts with the state untouched (F31).
        s.current.frame_callbacks.appendSlice(s.allocator, s.pending.frame_callbacks.items) catch {
            s.resource.postNoMemory();
            return;
        };
        s.pending.frame_callbacks.clearRetainingCapacity();

        // 6. Translate the committed surface damage into buffer
        // coordinates (wlroots surface_update_damage, wlr_compositor.c:
        // 248-296) BEFORE the swap: same input state (the pending fields
        // are about to become current), and the pending damage list is
        // swapped over — so the union lands where the post-swap version
        // would have put it, and no allocation remains after the swap
        // (F31). Damage is a hint: on OOM the commit proceeds with the
        // rects translated so far.
        s.translateDamage();

        // 7. Swap pending -> current.
        // F32/C-CS-5: capture whether THIS commit carried a buffer. A
        // commit without the buffer bit (damage-only, wlroots
        // surface_state_move wlr_compositor.c:338-345) must NOT touch the
        // presented content — `s.buffer` persists, and the previous
        // buffer's drop is skipped.
        const buffer_committed = s.pending.committed.buffer;
        swapState(&s.current, s.allocator, &s.pending);
        if (buffer_committed) {
            s.current_locked = s.pending_locked;
            s.pending_locked = false;
            // The resource observer moves with the slot it describes: the
            // pending slot is empty now, so its listener comes off, and
            // the current slot watches its own resource until the next
            // commit replaces it. Sharing one listener (the old shape)
            // left the displayed buffer unobserved the moment a second
            // buffer was attached.
            detachBufferListener(&s.pending_buffer_destroy);
            detachBufferListener(&s.current_buffer_destroy);
            s.current_resource = s.pending_resource;
            s.pending_resource = null;
            if (s.current_resource) |res| res.addDestroyListener(&s.current_buffer_destroy);
        }

        // The old presented mirror owns no surface lock. A renderer may
        // retain it independently until the scene updates its texture.
        if (buffer_committed) {
            if (old_buffer) |old| {
                if (old != s.current.buffer) {
                    old.drop();
                    // Untracked wrappers are caller-owned: this was the
                    // surface's last reference, so retire it. Tracked
                    // wrappers belong to the module that made them and
                    // die with their wl_buffer resource.
                    if (!old.tracked) old.destroy();
                }
            }
        }
        // F32/C-CS-5: the mirror follows the swap only when the commit
        // carried a buffer; otherwise the presented content persists.
        if (buffer_committed) s.buffer = s.current.buffer;

        // 9. Role commit hook, then the commit signal. Frame callbacks
        // are not completed here: sendFrameDone fires them at present
        // time (wlroots wlr_surface_send_frame_done). The client_commit
        // signal was already emitted by commit() before the apply
        // decision (step 3); role.client_commit likewise ran there (F36).
        // A flush via applyCommit is not a client commit, so neither
        // re-runs here.
        if (s.role) |role| if (role.commit) |f| f(s);
        s.events.commit.emit(s);

        // 10. Map/unmap transition: `mapped` follows isEffectivelyMapped
        // (positive-size current buffer AND the role's mapped gate — the
        // subsurface parent chain, wayland.xml:3254-3258).
        s.updateMapped();

        // Scene import hooks retain their own source locks. The get_release
        // callbacks ride the BUFFER: hand them over BEFORE this surface
        // releases its attachment lock, so a renderer still sampling the
        // pixels keeps them pending and the client is not told "reusable"
        // while the compositor is still reading it.
        if (s.current.buffer) |b| {
            s.transferReleaseCallbacks(b);
            if (s.current_locked) {
                s.current_locked = false;
                b.unlock();
            }
        } else {
            // A commit without a buffer leaves nothing to wait on.
            for (s.release_callbacks_pending.items) |cb| cb.destroy();
            s.release_callbacks_pending.clearRetainingCapacity();
        }
        // F32/C-CS-5: NULL the committed slot at commit end like wlroots
        // (wlr_compositor.c:570-574 — current.buffer is not held across
        // commits). The scene-facing `s.buffer` mirror (set above, step 8)
        // is the per-surface cache that persists until the buffer is
        // replaced or its resource dies; consumers must read `s.buffer`,
        // never `s.current.buffer`, for the presented content.
        // current_resource is KEPT, watched by current_buffer_destroy,
        // which clears the mirror when the client destroys the displayed
        // buffer.
        s.current.buffer = null;
    }

    /// Whether the surface is effectively mapped: it has a presented
    /// buffer with a positive size AND its role's mapped gate passes. The
    /// gate (SurfaceRole.mapped_gate) adds the role condition — the
    /// subsurface role fails while any ancestor in the parent chain is
    /// unmapped (wayland.xml:3254-3258: a sub-surface maps only when the
    /// parent surface is mapped; the rules apply recursively). The scene
    /// uses this for enter/present decisions; `mapped` (the transition)
    /// is driven by updateMapped.
    ///
    /// F32/C-CS-5: reads `s.buffer` (the persistent presented-content
    /// cache), NOT `s.current.buffer` — the committed slot is NULLed at
    /// the end of every commit (wlroots wlr_compositor.c:570-574), so
    /// buffer presence is tracked by the mirror, which survives until the
    /// buffer is replaced or its resource dies.
    pub fn isEffectivelyMapped(s: *Surface) bool {
        const b = s.buffer orelse return false;
        if (!(b.width > 0 and b.height > 0)) return false;
        if (s.role) |role| {
            if (role.mapped_gate) |gate| return gate(s);
        }
        return true;
    }

    /// The map/unmap transition: `mapped` follows isEffectivelyMapped.
    /// wlroots maps only when the buffer has a positive size
    /// (wlr_surface_state_has_buffer, wlr_compositor.h:356); the mapped
    /// gate extends that with the role condition (subsurface parent
    /// chain). On change: map runs the role hook then the map signal;
    /// unmap emits the signal first, then the role hook (F37, wlroots
    /// wlr_surface_unmap wlr_compositor.c:854-872). Runs from applyCommit
    /// (step 10) and from the subsurface's parent map/unmap listeners
    /// (parent-chain propagation with no child commit of its own).
    pub fn updateMapped(s: *Surface) void {
        const now_mapped = s.isEffectivelyMapped();
        if (now_mapped and !s.mapped) {
            s.mapped = true;
            if (s.role) |role| if (role.map) |f| f(s);
            s.events.map.emit(s);
        } else if (!now_mapped and s.mapped) {
            s.mapped = false;
            // F37: wlroots emits the unmap signal BEFORE the role hook
            // (wlr_surface_unmap wlr_compositor.c:854-872); listeners see
            // the signal first.
            s.events.unmap.emit(s);
            if (s.role) |role| if (role.unmap) |f| f(s);
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

    pub fn hasOutput(s: *const Surface, out: *output_mod.Output) bool {
        for (s.outputs.items) |association| {
            if (association.output == out) return true;
        }
        return false;
    }

    /// Add one output membership; entering another does not replace it.
    pub fn setEntered(s: *Surface, out: *output_mod.Output) void {
        if (s.destroying or s.hasOutput(out)) return;
        const association = s.allocator.create(OutputAssociation) catch {
            s.resource.postNoMemory();
            return;
        };
        s.outputs.append(s.allocator, association) catch {
            s.allocator.destroy(association);
            s.resource.postNoMemory();
            return;
        };
        association.* = .{
            .surface = s,
            .output = out,
            .destroy_listener = wire.Listener(*output_mod.Output).init(OutputAssociation.onDestroy),
        };
        out.events.destroy.add(&association.destroy_listener);
        s.events.enter.emit(out);
    }

    /// Leave only this output, retaining all other memberships.
    pub fn leaveOutput(s: *Surface, out: *output_mod.Output) void {
        for (s.outputs.items, 0..) |association, i| {
            if (association.output != out) continue;
            s.removeOutputAssociation(i);
            s.events.leave.emit(out);
            return;
        }
    }

    /// Leave every output; surface teardown instead removes them silently.
    pub fn setLeft(s: *Surface) void {
        while (s.outputs.items.len != 0) {
            s.leaveOutput(s.outputs.items[s.outputs.items.len - 1].output);
        }
    }

    fn removeOutputAssociation(s: *Surface, index: usize) void {
        const association = s.outputs.swapRemove(index);
        association.destroy_listener.link.remove();
        s.allocator.destroy(association);
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
            // C9: a cursor surface may commit a non-integral size — the
            // client bug is logged, not fatal (wlroots
            // surface_finalize_pending, wlr_compositor.c:211-226; the
            // error is blocked upstream on wayland/wayland#194). Role
            // identity by name matches wlroots' strcmp against the cursor
            // role names; the seat assigns "wl_pointer-cursor" at
            // wl_pointer.set_cursor (seat.zig cursor_role). Deliberate
            // divergence: wlroots also warns for rol-less surfaces; every
            // other role (and no role) keeps the hard error here.
            if (s.role) |r| {
                if (std.mem.eql(u8, r.name, "wl_pointer-cursor")) {
                    log.warn(
                        "Client bug: wl_surface@{d} ({s}) committed a buffer size not divisible by scale; accepted",
                        s.io,
                        s.log_cfg,
                        "surface",
                        .{ s.resource.getId(), r.name },
                    );
                    return true;
                }
            }
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
        // The attach offset (below v5: the buffer position itself, F34 —
        // wlroots surface_handle_attach, wlr_compositor.c:68-83) is
        // validated above and then dropped: no consumer reads it. A
        // surface's position comes from the compositor's scene tree
        // (scene/surface_node.zig sets the node position; the surface size
        // is the buffer size under the committed transform and scale), so
        // storing dx/dy here would be write-only state.

        if (buffer) |wl_buffer| {
            const res: *wire.Resource = @ptrCast(wl_buffer);
            // The dmabuf registry is asked FIRST: a wl_buffer produced
            // through zwp_linux_dmabuf_v1 is not an shm pool buffer, so
            // the shm wrap answers error.InvalidBuffer for it and the
            // F56 branch below kills a perfectly good client with
            // "unknown buffer type". Only after the resolver declines do
            // we take the shm path, unchanged. The order is the call
            // contract documented on LinuxDmabuf.fromResource
            // (shell/linux_dmabuf.zig:213-216).
            const wrapped: *Buffer = s.compositor.resolveDmabuf(res) orelse (if (s.compositor.shm) |st|
                st.fromResource(s.allocator, res)
            else
                shm_mod.fromResource(s.allocator, res)) catch |err| switch (err) {
                error.InvalidBuffer => {
                    // F56: unknown buffer type. wlroots rejects the pending
                    // buffer at commit with an error on the buffer resource
                    // (wlr_surface_reject_pending, wlr_compositor.c:874-889);
                    // ours discovers the type at attach, so the fatal error
                    // fires here. The resource is destroyed like wlroots.
                    res.postError(@as(u32, @bitCast(@as(i32, -1))), "unknown buffer type");
                    res.destroy();
                    return;
                },
                error.OutOfMemory => {
                    // F55: an attach-time OOM must reach the client
                    // (postNoMemory), not silently keep the previous
                    // pending buffer.
                    s.resource.postNoMemory();
                    return;
                },
            };
            s.attachBuffer(wrapped);
            // F42: observe the attached wl_buffer's death (wlroots
            // pending_buffer_resource_handle_destroy, wlr_compositor.c:49-54)
            // so a client destroying the resource clears the pending slot
            // and the next commit unmaps instead of presenting a dead
            // wrapper. This is the PENDING slot's own listener; the
            // displayed buffer keeps its own (see applyCommit), so
            // attaching a second buffer never blinds the first.
            detachBufferListener(&s.pending_buffer_destroy);
            res.addDestroyListener(&s.pending_buffer_destroy);
            s.pending_resource = res;
            return;
        }
        // Null attach: the pending slot is empty, so its listener has
        // nothing left to watch.
        detachBufferListener(&s.pending_buffer_destroy);
        s.pending_resource = null;
        s.attachBuffer(null);
    }

    fn handleDamage(s: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        // The spec does not define damage with negative extents; wlroots
        // ignores them (wlr_compositor.c:91-106), as do smithay and KWin
        // (QRegion clamp). Negative dims would otherwise grow the damage
        // list and feed overflow paths (F39, F41).
        if (width < 0 or height < 0) return;
        s.pending.surface_damage.add(.{ .x = x, .y = y, .width = width, .height = height }) catch {
            s.resource.postNoMemory();
            return;
        };
    }

    fn handleDamageBuffer(s: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        // Negative extents are ignored like in wl_surface.damage (F39;
        // wlroots wlr_compositor.c:626-639, smithay handlers.rs:304-309).
        if (width < 0 or height < 0) return;
        // Damage is in buffer coordinates and stays in buffer_damage; the
        // commit unions the surface damage translated into buffer
        // coordinates on top (see translateDamage).
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
        s.pending.committed.@"opaque" = true;
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
        s.pending.committed.input = true;
    }

    fn handleSetBufferTransform(s: *Surface, transform: server.wl.Output.Transform) void {
        const value: i32 = @intFromEnum(transform);
        if (value < 0 or value > 7) {
            s.resource.postError(.invalid_transform, "invalid wl_surface.set_buffer_transform value");
            return;
        }
        s.pending.transform = @enumFromInt(@as(u32, @intCast(value)));
        s.pending.committed.transform = true;
    }

    fn handleSetBufferScale(s: *Surface, scale: i32) void {
        if (scale <= 0) {
            s.resource.postError(.invalid_scale, "wl_surface.set_buffer_scale must be greater than zero");
            return;
        }
        s.pending.scale = scale;
        s.pending.committed.scale = true;
    }

    /// wl_surface.offset (v5): the role-specific location of the buffer
    /// (wlroots surface_handle_offset, wlr_compositor.c:640-647). The
    /// request is consumed and discarded — this compositor places a
    /// surface from its own scene-tree coordinates, so a stored offset
    /// would have no reader. The handler stays (instead of dropping the
    /// dispatch arm) so a client that sends offset — most toolkits do on
    /// every attach — is answered normally.
    fn handleOffset(_: *Surface, _: i32, _: i32) void {}

    /// Hand the queued get_release callbacks to `buf` (or to `old`, when
    /// the surface stops using a buffer). The Buffer owns them from
    /// here and completes them at its final unlock — which may be long
    /// after this surface is gone.
    ///
    /// On OOM the callback cannot be tracked, so it is destroyed rather
    /// than left alive: a wl_callback the client waits on forever is
    /// worse than one that dies with the client-side id, and the failure
    /// is reported (a live surface can still be told). Queueing also
    /// completes immediately when nothing holds a lock, which is the
    /// common case and never allocates.
    fn transferReleaseCallbacks(s: *Surface, buf: *Buffer) void {
        for (s.release_callbacks_pending.items) |cb| {
            buf.queueReleaseCallback(cb) catch {
                cb.destroy();
                if (!s.destroying) s.resource.postNoMemory();
            };
        }
        s.release_callbacks_pending.clearRetainingCapacity();
    }

    /// Translate the pending surface damage into buffer coordinates and
    /// union it into the pending buffer_damage list (wlroots
    /// surface_update_damage, wlr_compositor.c:248-296) — run BEFORE the
    /// swap so the commit path is allocation-free after it (F31). Both
    /// lists are clipped to their bounds first (wlroots
    /// surface_finalize_pending, wlr_compositor.c:240-245): surface
    /// damage against the surface bounds (0,0,size.w,size.h), buffer
    /// damage against the buffer bounds (0,0,buf.width,buf.height) —
    /// fully-outside rects drop, partials trim. Then scale first, and
    /// invert the buffer transform. Damage is a hint, so over-reporting
    /// (saturating on overflow) is safe; on OOM the rects translated so
    /// far are kept and the commit proceeds.
    fn translateDamage(s: *Surface) void {
        const buf = s.pending.buffer orelse return;
        const transform = s.pending.transform;
        const size = transform.transformedSize(buf.width, buf.height);
        // Surface damage is in surface coordinates, so it clips against
        // the SURFACE bounds — the (transformed) buffer size divided by
        // the buffer scale — not the buffer bounds (wlroots
        // surface_finalize_pending). The scale is always >= 1
        // (handleSetBufferScale rejects <= 0); guard > 0 anyway.
        const scale: i32 = if (s.pending.scale > 0) s.pending.scale else 1;
        clipDamage(&s.pending.surface_damage.rects, .{
            .x = 0,
            .y = 0,
            .width = @divTrunc(size.w, scale),
            .height = @divTrunc(size.h, scale),
        });
        clipDamage(&s.pending.buffer_damage.rects, .{ .x = 0, .y = 0, .width = buf.width, .height = buf.height });
        const inv = inverseTransform(transform);
        for (s.pending.surface_damage.rects.items) |rect| {
            const scaled: Rect = .{
                .x = scaleCoord(rect.x, s.pending.scale),
                .y = scaleCoord(rect.y, s.pending.scale),
                .width = scaleCoord(rect.width, s.pending.scale),
                .height = scaleCoord(rect.height, s.pending.scale),
            };
            const r = transformRect(scaled, inv, size.w, size.h);
            s.pending.buffer_damage.add(r) catch {
                s.resource.postNoMemory();
                return;
            };
        }
    }
};

/// Clip a damage rect list to a bounding rect in place (wlroots
/// surface_finalize_pending, wlr_compositor.c:240-245): fully-outside
/// rects drop, partials trim to the intersection. The list compacts in
/// place — no allocation. The `whole` flag is untouched: whole damage is
/// unbounded by construction (rects is empty then).
fn clipDamage(rects: *std.ArrayList(Rect), bounds: Rect) void {
    var out: usize = 0;
    for (rects.items) |rect| {
        const clipped = Rect.intersect(rect, bounds) orelse continue;
        rects.items[out] = clipped;
        out += 1;
    }
    rects.shrinkRetainingCapacity(out);
}

/// Take a buffer-resource listener off its resource if it is attached.
/// A removed link has `prev == null` (wire list.Link.remove) and a
/// never-attached one is self-linked (Listener.link.init).
fn detachBufferListener(listener: *wire.Listener(*wire.Resource)) void {
    if (listener.link.prev != null and listener.link.prev != &listener.link) {
        listener.link.remove();
    }
}

/// The client destroyed the wl_buffer resource behind the PENDING
/// attachment (F42). Mirrors wlroots'
/// pending_buffer_resource_handle_destroy (wlr_compositor.c:49-54): a
/// commit after this clears the pending slot and unmaps instead of
/// committing a dead wrapper.
///
/// The module's own listener on that resource runs first in this
/// emission (it registered at wrapper creation): by the time this runs
/// the wrapper is invalidated, dropped and handed to Buffer.destroy,
/// which frees it as soon as the LAST lock goes — the one held here.
/// So the slot is cleared before the unlock, and the unlock releases
/// only this surface's own attachment lock; a renderer's lock on the
/// same buffer is never touched.
fn onPendingBufferDestroy(listener: *wire.Listener(*wire.Resource), resource: *wire.Resource) void {
    const s: *Surface = @fieldParentPtr("pending_buffer_destroy", listener);
    // Self-detach: the observed resource is going away; the link must not
    // outlive it (the destroy-path detach checks the link state).
    detachBufferListener(&s.pending_buffer_destroy);
    if (s.pending_resource != resource) return;
    const buf = s.pending.buffer;
    const locked = s.pending_locked;
    s.pending.buffer = null;
    s.pending_resource = null;
    s.pending_locked = false;
    // The get_release callbacks asked for against this buffer belong to
    // the buffer: hand them over before its last lock goes, and let the
    // unlock below (this surface's own lock) be what may complete them.
    if (buf) |b| {
        s.transferReleaseCallbacks(b);
        if (locked) b.unlock();
    }
}

/// The client destroyed the wl_buffer resource behind the DISPLAYED
/// buffer (F42). The committed slot and the scene-facing mirror must not
/// keep pointing at a wrapper whose resource is gone, and the next commit
/// must be a NULL-buffer commit. The surface holds no lock on this slot
/// (the commit released it), so nothing is unlocked here — a renderer
/// that still samples the pixels keeps its own lock and its backing.
fn onCurrentBufferDestroy(listener: *wire.Listener(*wire.Resource), resource: *wire.Resource) void {
    const s: *Surface = @fieldParentPtr("current_buffer_destroy", listener);
    detachBufferListener(&s.current_buffer_destroy);
    if (s.current_resource != resource) return;
    const locked = s.current_locked;
    const buf = s.current.buffer;
    s.current.buffer = null;
    s.current_resource = null;
    s.current_locked = false;
    s.buffer = null;
    if (locked and buf != null) buf.?.unlock();
}

/// Apply pending to current (wlroots surface_state_move,
/// wlr_compositor.c:321-405). Only the fields the client actually changed
/// this cycle (pending.committed, F33) are applied; uncommitted fields
/// keep their current value across commits. Pending values persist, so
/// this is observably equivalent to a full copy except where wlroots
/// explicitly clears on an absent bit: the opaque/input regions (pending
/// does not persist them — the swap moves the list out and nulls it).
/// The committed mask is consumed by this swap; pending restarts empty and
/// accumulates a fresh mask from the next requests (wlroots
/// clears it in surface_state_move, wlr_compositor.c:397-399).
/// Scalar state copies; the damage lists transfer so the pending state
/// restarts empty (the old current damage is stale — M2's damage ring
/// accumulates properly). Frame callbacks do NOT transfer here:
/// Surface.commit accumulates them across commits.
pub fn swapState(current: *State, allocator: Allocator, pending: *State) void {
    if (pending.committed.buffer) {
        current.buffer = pending.buffer;
        pending.buffer = null;
    }
    // Damage transfers unconditionally: pending damage is always empty
    // after a transfer, so the committed damage bits add nothing (wlroots
    // clears current damage when the bit is absent, wlr_compositor.c:374-385).
    std.mem.swap(Damage, &current.surface_damage, &pending.surface_damage);
    pending.surface_damage.clear();
    std.mem.swap(Damage, &current.buffer_damage, &pending.buffer_damage);
    pending.buffer_damage.clear();
    if (pending.committed.@"opaque") {
        if (current.@"opaque") |*list| list.deinit(allocator);
        current.@"opaque" = pending.@"opaque";
        pending.@"opaque" = null;
    }
    if (pending.committed.input) {
        if (current.input) |*list| list.deinit(allocator);
        current.input = pending.input;
        pending.input = null;
    }
    if (pending.committed.transform) current.transform = pending.transform;
    if (pending.committed.scale) current.scale = pending.scale;
    if (pending.committed.viewport) current.viewport = pending.viewport;
    pending.committed = .{};
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
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    c.events.new_surface.init();
    c.events.destroy.init();
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
        // SAFETY: signals and the callback list are initialized via
        // .init() below, before any use.
        .events = .{ .release = undefined, .destroy = undefined },
        .release_callbacks = undefined,
    };
    b.events.release.init();
    b.events.destroy.init();
    b.release_callbacks.init();
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

    var output: output_mod.Output = undefined;
    output.events.destroy.init();
    try testing.expectEqual(@as(usize, 0), s.outputs.items.len);

    s.setEntered(&output);
    try testing.expect(s.hasOutput(&output));
    try testing.expectEqual(@as(usize, 1), test_enter_count);

    // Idempotent: re-entering the same output fires nothing.
    s.setEntered(&output);
    try testing.expectEqual(@as(usize, 1), test_enter_count);

    s.setLeft();
    try testing.expectEqual(@as(usize, 0), s.outputs.items.len);
    try testing.expectEqual(@as(usize, 1), test_leave_count);

    // Idempotent: leaving without an output fires nothing.
    s.setLeft();
    try testing.expectEqual(@as(usize, 1), test_leave_count);
}

test "a surface keeps both output memberships until it leaves them" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    var log_cfg: log.Config = .{ .min_level = .err };
    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, &io_storage, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, &io_storage, &log_cfg, comp, &tw);
    defer s.destroy();
    const Observer = struct {
        enters: usize = 0,
        leaves: usize = 0,
        enter: wire.Listener(*output_mod.Output),
        leave: wire.Listener(*output_mod.Output),

        fn onEnter(listener: *wire.Listener(*output_mod.Output), _: *output_mod.Output) void {
            const self: *@This() = @fieldParentPtr("enter", listener);
            self.enters += 1;
        }

        fn onLeave(listener: *wire.Listener(*output_mod.Output), _: *output_mod.Output) void {
            const self: *@This() = @fieldParentPtr("leave", listener);
            self.leaves += 1;
        }
    };
    var observer: Observer = .{
        .enter = wire.Listener(*output_mod.Output).init(Observer.onEnter),
        .leave = wire.Listener(*output_mod.Output).init(Observer.onLeave),
    };
    s.events.enter.add(&observer.enter);
    s.events.leave.add(&observer.leave);
    defer observer.enter.link.remove();
    defer observer.leave.link.remove();
    // Membership only needs the output's destroy signal. These output
    // fixtures remain alive until their surface is destroyed.
    var a: output_mod.Output = undefined;
    var b: output_mod.Output = undefined;
    a.events.destroy.init();
    b.events.destroy.init();
    s.setEntered(&a);
    s.setEntered(&b);
    s.setEntered(&a);
    try testing.expectEqual(@as(usize, 2), observer.enters);
    try testing.expectEqual(@as(usize, 0), observer.leaves);
    s.setLeft();
    try testing.expectEqual(@as(usize, 2), observer.leaves);
    s.setLeft();
    try testing.expectEqual(@as(usize, 2), observer.leaves);
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

test "state swap transfers committed fields, resets pending" {
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
    pending.viewport = .{ .has_dst = true, .dst = .{ .w = 40, .h = 30 } };
    // Only the committed fields transfer (F33); the rest keep their
    // current value.
    pending.committed.buffer = true;
    pending.committed.@"opaque" = true;
    pending.committed.input = true;
    pending.committed.transform = true;
    pending.committed.scale = true;
    pending.committed.viewport = true;

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
    // The viewport transfers with its bit (F-AX-11) and PENDING keeps the
    // value for the next commit.
    try testing.expect(current.viewport.has_dst);
    try testing.expectEqual(@as(i32, 40), current.viewport.dst.w);
    try testing.expectEqual(@as(i32, 30), current.viewport.dst.h);
    try testing.expectEqual(@as(usize, 1), current.surface_damage.rects.items.len);
    try testing.expect(pending.surface_damage.isEmpty());
    try testing.expectEqual(@as(usize, 1), current.buffer_damage.rects.items.len);
    try testing.expect(pending.buffer_damage.isEmpty());
    // The mask is consumed by the swap; pending accumulates a fresh one.
    try testing.expect(!pending.committed.buffer);
    try testing.expect(!pending.committed.@"opaque");
    try testing.expect(!pending.committed.input);
    try testing.expect(!pending.committed.transform);
    try testing.expect(!pending.committed.scale);
    try testing.expect(!pending.committed.viewport);
    // Frame callbacks are NOT moved by swapState: Surface.commit
    // accumulates them on current across commits until the next present.
    try testing.expectEqual(@as(usize, 0), current.frame_callbacks.items.len);
    try testing.expectEqual(@as(usize, 1), pending.frame_callbacks.items.len);
}

test "uncommitted fields keep their current value across the swap" {
    const allocator = testing.allocator;
    var current = State.init(allocator);
    defer current.deinit(allocator);
    var pending = State.init(allocator);
    defer pending.deinit(allocator);

    // First commit sets buffer, scale and transform.
    pending.buffer = @as(?*Buffer, @ptrFromInt(0x200));
    pending.scale = 2;
    pending.transform = .@"90";
    pending.committed.buffer = true;
    pending.committed.scale = true;
    pending.committed.transform = true;
    swapState(&current, allocator, &pending);
    try testing.expectEqual(@as(i32, 2), current.scale);
    try testing.expectEqual(geom.Transform.@"90", current.transform);

    // Second commit changes only the buffer: scale and transform keep
    // their current value because their bits are absent (F33, wlroots
    // surface_state_move wlr_compositor.c:340-346).
    pending.buffer = @as(?*Buffer, @ptrFromInt(0x300));
    pending.committed.buffer = true;
    swapState(&current, allocator, &pending);
    try testing.expectEqual(@as(?*Buffer, @ptrFromInt(0x300)), current.buffer);
    try testing.expectEqual(@as(i32, 2), current.scale);
    try testing.expectEqual(geom.Transform.@"90", current.transform);
    // PENDING keeps its request values across commits, so the bits the
    // client has not re-sent still describe what it asked for (F33).
    try testing.expectEqual(@as(i32, 2), pending.scale);
    try testing.expectEqual(geom.Transform.@"90", pending.transform);
}

test "opaque and input regions persist until replaced by a commit" {
    const allocator = testing.allocator;
    var current = State.init(allocator);
    defer current.deinit(allocator);
    var pending = State.init(allocator);
    defer pending.deinit(allocator);

    {
        var list: std.ArrayList(Rect) = .empty;
        try list.append(allocator, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
        pending.@"opaque" = list;
    }
    pending.committed.@"opaque" = true;
    swapState(&current, allocator, &pending);
    try testing.expectEqual(@as(usize, 1), current.@"opaque".?.items.len);

    // A commit without set_opaque keeps the current region (wlroots
    // applies fields only on their committed bit): the old full-copy
    // behavior lost it here, because the swap nulls pending.
    swapState(&current, allocator, &pending);
    try testing.expectEqual(@as(usize, 1), current.@"opaque".?.items.len);
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

test "negative damage extents are ignored (F39)" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    // Negative w/h are ignored per wlroots (wlr_compositor.c:91-106,
    // 626-639) — no protocol error, no accumulation.
    s.handleDamage(0, 0, -1, 10);
    s.handleDamage(0, 0, 10, -1);
    s.handleDamageBuffer(0, 0, -1, 10);
    s.handleDamageBuffer(0, 0, 10, -1);
    try testing.expectEqual(@as(usize, 0), s.pending.surface_damage.rects.items.len);
    try testing.expectEqual(@as(usize, 0), s.pending.buffer_damage.rects.items.len);

    // Valid damage still accumulates after the rejected rects.
    s.handleDamage(0, 0, 5, 5);
    s.handleDamageBuffer(0, 0, 5, 5);
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
    try testing.expect(s.buffer == &buffer);
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
    try testing.expect(s.buffer == &b1);

    s.attachBuffer(&b2);
    s.commit();
    // b1 was swapped out: dropped (producer done); it was already unlocked.
    try testing.expect(b1.dropped);
    try testing.expectEqual(@as(u32, 0), b1.n_locks);
    try testing.expectEqual(@as(u32, 0), b2.n_locks);
    try testing.expect(s.buffer == &b2);
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

    // Re-attach of the current buffer (weston double-buffering pattern):
    // a fresh lock is taken per attach so the commit-end unlock releases
    // each use (the client keeps a leaf busy until wl_buffer.release).
    s.attachBuffer(&b);
    try testing.expect(s.pending_locked);
    s.commit();
    try testing.expectEqual(@as(u32, 0), b.n_locks);
    try testing.expect(s.buffer == &b);
    try testing.expect(!b.dropped);
}

test "surface replacement never consumes a renderer's buffer lock" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    var log_cfg: log.Config = .{ .min_level = .err };
    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, &io_storage, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, &io_storage, &log_cfg, comp, &tw);
    var buffer: Buffer = undefined;
    testBuffer(allocator, &buffer);
    try buffer.lock();
    defer if (buffer.n_locks != 0) buffer.unlock();
    defer s.destroy();
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expectEqual(@as(u32, 1), buffer.n_locks);
    s.attachBuffer(null);
    s.commit();
    try testing.expectEqual(@as(u32, 1), buffer.n_locks);
}

test "get_release waits for retained renderer usage and sends done on final unlock" {
    const allocator = testing.allocator;
    const buffer = try allocator.create(Buffer);
    testBuffer(allocator, buffer);
    defer buffer.destroy();
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    var log_cfg: log.Config = .{ .min_level = .err };
    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, &io_storage, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, &io_storage, &log_cfg, comp, &tw);
    try buffer.lock();
    defer if (buffer.n_locks != 0) buffer.unlock();
    s.attachBuffer(buffer);
    const callback_id = tw.newId();
    s.handleGetRelease(callback_id);
    s.commit();
    tw.server.flushClients();

    var bytes: [128]u8 = undefined;
    const before = std.os.linux.recvfrom(tw.peer_fd, &bytes, bytes.len, std.os.linux.MSG.DONTWAIT, null, null);
    try testing.expectEqual(-@as(isize, @intFromEnum(std.os.linux.E.AGAIN)), @as(isize, @bitCast(before)));
    buffer.unlock();
    tw.server.flushClients();
    const after = std.os.linux.recvfrom(tw.peer_fd, &bytes, bytes.len, std.os.linux.MSG.DONTWAIT, null, null);
    try testing.expect(@as(isize, @bitCast(after)) >= 12);
    const endian = @import("builtin").target.cpu.arch.endian();
    try testing.expectEqual(callback_id, std.mem.readInt(u32, bytes[0..4], endian));
    try testing.expectEqual(@as(u32, 12 << 16), std.mem.readInt(u32, bytes[4..8], endian));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[8..12], endian));
}

test "a get_release callback survives its surface and completes when the reader is done" {
    const allocator = testing.allocator;
    const buffer = try allocator.create(Buffer);
    testBuffer(allocator, buffer);
    defer buffer.destroy();
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    var log_cfg: log.Config = .{ .min_level = .err };
    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, &io_storage, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, &io_storage, &log_cfg, comp, &tw);
    try buffer.lock(); // a renderer is still sampling the pixels
    defer if (buffer.n_locks != 0) buffer.unlock();
    s.attachBuffer(buffer);
    const callback_id = tw.newId();
    s.handleGetRelease(callback_id);
    s.commit();

    // The surface dies with the callback outstanding: the promise is the
    // buffer's, and the client is waiting on it.
    s.destroy();

    var bytes: [128]u8 = undefined;
    tw.server.flushClients();
    const before = std.os.linux.recvfrom(tw.peer_fd, &bytes, bytes.len, std.os.linux.MSG.DONTWAIT, null, null);
    try testing.expectEqual(-@as(isize, @intFromEnum(std.os.linux.E.AGAIN)), @as(isize, @bitCast(before)));

    buffer.unlock();
    tw.server.flushClients();
    const after = std.os.linux.recvfrom(tw.peer_fd, &bytes, bytes.len, std.os.linux.MSG.DONTWAIT, null, null);
    try testing.expect(@as(isize, @bitCast(after)) >= 12);
    const endian = @import("builtin").target.cpu.arch.endian();
    try testing.expectEqual(callback_id, std.mem.readInt(u32, bytes[0..4], endian));
    try testing.expectEqual(@as(u32, 12 << 16), std.mem.readInt(u32, bytes[4..8], endian));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[8..12], endian));
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

test "cursor-role surfaces may commit non-divisible sizes; others are rejected (C9)" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();

    // A cursor-role surface (the seat assigns this role name at
    // wl_pointer.set_cursor, seat.zig cursor_role): a non-divisible size
    // is accepted with a warning, not rejected (wlroots
    // surface_finalize_pending, wlr_compositor.c:211-226). The role is
    // assigned at set_cursor, BEFORE the cursor surface's first commit,
    // so the commit's validation sees it.
    const cursor_s = try testSurface(allocator, io, &log_cfg, comp, &tw);
    var cursor_role: SurfaceRole = .{ .name = "wl_pointer-cursor" };
    try role_mod.assignRole(cursor_s, &cursor_role, null);
    var cursor_buf: Buffer = undefined;
    testBuffer(allocator, &cursor_buf); // 10x10
    cursor_s.handleSetBufferScale(3); // 10 % 3 != 0 -> non-divisible
    cursor_s.attachBuffer(&cursor_buf);
    cursor_s.commit();

    // The commit proceeded past validation: the buffer swapped and the
    // surface mapped (a rejected commit would leave both untouched).
    try testing.expect(cursor_s.buffer == &cursor_buf);
    try testing.expect(cursor_s.mapped);

    // Any non-cursor surface keeps the hard error: invalid_size is
    // posted and the commit is discarded (the discard is the posted
    // error's observable, same as the test above).
    const plain_s = try testSurface(allocator, io, &log_cfg, comp, &tw);
    var plain_buf: Buffer = undefined;
    testBuffer(allocator, &plain_buf); // 10x10
    plain_s.handleSetBufferScale(3);
    plain_s.attachBuffer(&plain_buf);
    plain_s.commit();
    try testing.expect(plain_s.current.buffer == null);
    try testing.expect(!plain_s.mapped);
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
var test_role_client_commits: usize = 0;

const TestRoleHooks = struct {
    fn clientCommit(s: *Surface) void {
        _ = s;
        test_role_client_commits += 1;
    }
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
        // Record the order relative to the unmap signal listener (1 =
        // role hook; the signal listener records 2).
        test_unmap_seq[test_unmap_seq_len] = 1;
        test_unmap_seq_len += 1;
    }
};

var test_role: SurfaceRole = .{
    .name = "test-role",
    .client_commit = TestRoleHooks.clientCommit,
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
    s.handleDamageBuffer(1, 1, 3, 3);
    s.commit();

    // The in-bounds damage_buffer rect stays as-is; the surface damage
    // (1,2,3,4) is appended translated (scale 1, normal transform:
    // unchanged). Out-of-bounds rects are clipped away by translateDamage
    // (C4 — see the bounds-clipping test below).
    try testing.expectEqual(@as(usize, 2), s.current.buffer_damage.rects.items.len);
    try testing.expectEqual(
        Rect{ .x = 1, .y = 1, .width = 3, .height = 3 },
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
    // In-bounds rect: the C4 clip (surface bounds = 5x5 at scale 2)
    // must not trim it — this test covers the translate, not the clip.
    s.handleDamage(1, 1, 3, 3);
    s.commit();

    // Scale 2: (1,1,3,3) -> (2,2,6,6). Inverse of 90 is 270, applied to
    // the 10x10 surface box: (x,y,w,h) = (2,2,6,6).
    try testing.expectEqual(@as(usize, 1), s.current.buffer_damage.rects.items.len);
    try testing.expectEqual(Rect{ .x = 2, .y = 2, .width = 6, .height = 6 }, s.current.buffer_damage.rects.items[0]);
}

test "damage is clipped to surface and buffer bounds at commit" {
    // C4: translateDamage clips both damage lists to their coordinate
    // bounds before the scale/transform translate (wlroots
    // surface_finalize_pending, wlr_compositor.c:240-245): surface damage
    // against the surface bounds, buffer damage against the buffer
    // bounds. Fully-outside rects drop, partials trim — retained lists
    // stay bounded (damage is a hint).
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
    testBuffer(allocator, &buffer); // 10x10, resized to 100x100
    buffer.width = 100;
    buffer.height = 100;

    // Scale 1: an overflowing rect trims to the full surface, a
    // fully-outside rect drops, a partial trims; the fully-out-of-bounds
    // damage_buffer rect drops and a partial one trims to the buffer.
    s.attachBuffer(&buffer);
    s.handleDamage(-50, -50, 300, 300);
    s.handleDamage(1000, 1000, 50, 50);
    s.handleDamage(80, 80, 50, 50);
    s.handleDamageBuffer(120, 120, 50, 50);
    s.handleDamageBuffer(-10, -10, 30, 30);
    s.commit();

    // buffer_damage: the trimmed partial buffer rect first (accumulation
    // order), then the two translated surface rects.
    try testing.expectEqual(@as(usize, 3), s.current.buffer_damage.rects.items.len);
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .width = 20, .height = 20 },
        s.current.buffer_damage.rects.items[0],
    );
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .width = 100, .height = 100 },
        s.current.buffer_damage.rects.items[1],
    );
    try testing.expectEqual(
        Rect{ .x = 80, .y = 80, .width = 20, .height = 20 },
        s.current.buffer_damage.rects.items[2],
    );
    // The fully-outside (1000,1000,50,50) rect is absent; every rect lies
    // within the 100x100 buffer bounds.
    for (s.current.buffer_damage.rects.items) |r| {
        try testing.expect(r.x >= 0 and r.y >= 0);
        try testing.expect(r.x + r.width <= 100 and r.y + r.height <= 100);
    }

    // Surface damage is clipped too (the M2 ring reads it): the
    // fully-outside rect dropped, the others trimmed.
    try testing.expectEqual(@as(usize, 2), s.current.surface_damage.rects.items.len);
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .width = 100, .height = 100 },
        s.current.surface_damage.rects.items[0],
    );
    try testing.expectEqual(
        Rect{ .x = 80, .y = 80, .width = 20, .height = 20 },
        s.current.surface_damage.rects.items[1],
    );

    // Scale 2 (surface 50x50): a surface rect at x=-10 clips to
    // x in [0,50] BEFORE scaling, so the translated buffer rect never
    // goes negative or exceeds 100 px. Pre-fix this rect scaled to
    // (-20,0,160,20) — outside the buffer.
    s.handleSetBufferScale(2);
    s.attachBuffer(&buffer); // re-attach of the current buffer: no double lock
    s.handleDamage(-10, 0, 80, 10);
    s.commit();

    try testing.expectEqual(@as(usize, 1), s.current.buffer_damage.rects.items.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 100, .height = 20 }, s.current.buffer_damage.rects.items[0]);
    for (s.current.buffer_damage.rects.items) |r| {
        try testing.expect(r.x >= 0 and r.y >= 0);
        try testing.expect(r.x + r.width <= 100 and r.y + r.height <= 100);
    }
}

test "OOM in the commit path aborts without applying partial state" {
    // F31: the commit is transactional — the frame-callback append (the
    // only fallible step that used to run after the swap) happens before
    // any state is mutated, so an OOM leaves the state untouched and the
    // client is told (postNoMemory), like wlroots' surface_cache_pending
    // (wlr_compositor.c:475-510).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(failing.allocator(), io, &log_cfg);
    defer destroyTestCompositor(&failing, comp);
    defer tw.deinit();
    const s = try testSurface(failing.allocator(), io, &log_cfg, comp, &tw);

    var buffer: Buffer = undefined;
    testBuffer(failing.allocator(), &buffer);
    s.attachBuffer(&buffer);
    s.handleFrame(tw.newId());

    // The next allocation inside commit() is the frame-callback append
    // (pre-swap): fail it.
    failing.fail_index = failing.alloc_index;
    s.commit();

    // Nothing was applied: no swap, no map, the pending state (with its
    // attach lock) is intact, and the callback was not moved.
    try testing.expect(s.current.buffer == null);
    try testing.expect(!s.mapped);
    try testing.expect(s.pending.buffer == &buffer);
    try testing.expectEqual(@as(u32, 1), buffer.n_locks);
    try testing.expectEqual(@as(usize, 1), s.pending.frame_callbacks.items.len);
    try testing.expectEqual(@as(usize, 0), s.current.frame_callbacks.items.len);

    // A later successful commit applies the same pending state.
    failing.fail_index = std.math.maxInt(usize);
    s.commit();
    try testing.expect(s.mapped);
    try testing.expect(s.buffer == &buffer);
    try testing.expectEqual(@as(u32, 0), buffer.n_locks);
    try testing.expectEqual(@as(usize, 0), s.pending.frame_callbacks.items.len);
    try testing.expectEqual(@as(usize, 1), s.current.frame_callbacks.items.len);
}

/// Destroy a test compositor allocated with a possibly-failing allocator
/// (the failing allocator wraps testing.allocator, so a plain destroy is
/// fine once failures are disabled).
fn destroyTestCompositor(failing: *std.testing.FailingAllocator, comp: *Compositor) void {
    failing.fail_index = std.math.maxInt(usize);
    testing.allocator.destroy(comp);
}

test "wl_surface.offset is consumed and changes no committed state (F34)" {
    // F34: wl_surface.offset is the role-specific location of the buffer
    // (wlroots surface_handle_offset, wlr_compositor.c:640-647). This
    // compositor places a surface from its own scene-tree coordinates, so
    // the request is accepted and discarded — it must leave the committed
    // buffer, scale and the map state untouched (clients send offset on
    // most attaches).
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
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.mapped);

    s.handleOffset(7, -9);
    s.commit();

    // The mirror (the presented-content cache, F32/C-CS-5) still holds the
    // buffer, the committed scale is untouched and the surface stays
    // mapped: a discarded offset changes nothing observable.
    try testing.expect(s.buffer == &buffer);
    try testing.expectEqual(@as(i32, 1), s.current.scale);
    try testing.expect(s.mapped);
}

test "pre-v5 attach accepts an offset; an unknown buffer type kills the wl_buffer" {
    // F34: below wl_surface v5 the attach dx/dy ARE the buffer position
    // (wlroots surface_handle_attach, wlr_compositor.c:68-83), so no
    // invalid_offset is posted. The offset itself is not stored (no
    // consumer reads it); what must hold is that the request is processed
    // at all: the fabricated wl_buffer fails the wrap with InvalidBuffer
    // and is destroyed, and the surface survives that error untouched.
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const v4_res = try server.wl.Surface.create(tw.client, 4, tw.newId());
    const s4 = try Surface.create(allocator, io, &log_cfg, comp, v4_res);
    defer s4.destroy();

    // A fabricated wl_buffer (never created by the internal shm pipeline)
    // fails the wrap with InvalidBuffer.
    const foreign = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    const foreign_buf: *server.wl.Buffer = @ptrCast(foreign);
    s4.handleAttach(foreign_buf, 3, 5);
    try testing.expect(s4.pending.buffer == null);
    try testing.expect(s4.pending_resource == null);

    // The surface is intact: a commit with nothing attached maps nothing.
    s4.commit();
    try testing.expect(s4.current.buffer == null);
    try testing.expect(!s4.mapped);
}

test "previous state snapshots the pre-commit geometry" {
    // F38: applyCommit copies the current scale/transform/buffer size
    // into `previous` before the swap (wlroots wlr_compositor.c:523-528)
    // so consumers can damage the OLD footprint on geometry changes.
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
    testBuffer(allocator, &b1); // 10x10
    s.attachBuffer(&b1);
    s.commit();
    try testing.expectEqual(@as(i32, 1), s.previous.scale);
    try testing.expectEqual(geom.Transform.normal, s.previous.transform);
    try testing.expectEqual(@as(i32, 0), s.previous.buffer_width); // nothing before the first commit

    s.handleSetBufferScale(2);
    s.handleSetBufferTransform(server.wl.Output.Transform.@"90");
    var b2: Buffer = undefined;
    testBuffer(allocator, &b2);
    s.attachBuffer(&b2);
    s.commit();

    try testing.expectEqual(@as(i32, 1), s.previous.scale);
    try testing.expectEqual(geom.Transform.normal, s.previous.transform);
    try testing.expectEqual(@as(i32, 10), s.previous.buffer_width);
    try testing.expectEqual(@as(i32, 10), s.previous.buffer_height);
    try testing.expectEqual(@as(i32, 2), s.current.scale);
    try testing.expectEqual(geom.Transform.@"90", s.current.transform);
}

test "destroying the attached buffer resource unmaps on the next commit" {
    // F42: client destroys the wl_buffer resource backing the pending
    // buffer; the next commit must be a NULL-buffer commit (unmap) instead
    // of committing the dead wrapper (wlroots
    // pending_buffer_resource_handle_destroy wlr_compositor.c:49-54).
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
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    // A renderer is also reading the buffer: the surface must give up
    // exactly the lock it took and leave the rest alone.
    try buffer.lock();
    // Simulate handleAttach's wiring: the pending slot tracks the wire
    // resource and observes its death.
    const buf_res = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    s.pending_resource = buf_res;
    buf_res.addDestroyListener(&s.pending_buffer_destroy);
    try testing.expect(s.pending.buffer == &buffer);

    buf_res.destroy();
    try testing.expect(s.pending.buffer == null);
    try testing.expect(!s.pending_locked);
    try testing.expect(s.pending_resource == null);
    // The surface's attachment lock is released, the renderer's is not.
    try testing.expectEqual(@as(u32, 1), buffer.n_locks);
    buffer.unlock();

    // The commit is now a NULL-buffer commit: nothing maps.
    s.commit();
    try testing.expect(!s.mapped);
    try testing.expect(s.current.buffer == null);
}

test "destroying the displayed buffer's resource clears the current slot" {
    // F42 displayed case: the resource dies while its buffer is CURRENT.
    // applyCommit moves pending_resource -> current_resource, so the
    // destroy listener clears the current slot (and the s.buffer mirror).
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
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    const buf_res = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    s.pending_resource = buf_res;
    buf_res.addDestroyListener(&s.pending_buffer_destroy);
    s.commit();
    try testing.expect(s.mapped);
    try testing.expect(s.current_resource == buf_res);
    try testing.expect(s.pending_resource == null);

    buf_res.destroy();
    try testing.expect(s.current.buffer == null);
    try testing.expect(s.buffer == null);
    try testing.expect(s.current_resource == null);
    // The next commit is a NULL-buffer commit: unmap.
    s.commit();
    try testing.expect(!s.mapped);
}

test "destroying a displayed buffer while another attachment is pending clears only the displayed slot" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    var log_cfg: log.Config = .{ .min_level = .err };
    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, &io_storage, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, &io_storage, &log_cfg, comp, &tw);
    var current: Buffer = undefined;
    testBuffer(allocator, &current);
    var pending: Buffer = undefined;
    testBuffer(allocator, &pending);
    const current_resource = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    const pending_resource = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    s.attachBuffer(&current);
    s.pending_resource = current_resource;
    current_resource.addDestroyListener(&s.pending_buffer_destroy);
    s.commit();
    s.attachBuffer(&pending);
    // A renderer is reading the pending buffer: nothing about the
    // displayed buffer's death may touch it.
    try pending.lock();
    detachBufferListener(&s.pending_buffer_destroy);
    s.pending_resource = pending_resource;
    pending_resource.addDestroyListener(&s.pending_buffer_destroy);

    current_resource.destroy();
    try testing.expect(s.buffer == null);
    try testing.expect(s.current_resource == null);
    try testing.expect(s.pending.buffer == &pending);
    try testing.expect(s.pending_resource == pending_resource);
    // The pending slot keeps both of its locks: the attachment and the
    // renderer's.
    try testing.expectEqual(@as(u32, 2), pending.n_locks);
    s.commit();
    try testing.expect(s.mapped);
    try testing.expect(s.buffer == &pending);
    // The commit released the attachment lock; the renderer's remains.
    try testing.expectEqual(@as(u32, 1), pending.n_locks);
    pending.unlock();
    defer s.destroy();
}


test "attach of an unknown buffer type posts an error and keeps the previous pending" {
    // F56: a wl_buffer the internal shm pipeline never created fails the
    // wrap; the client is rejected with a fatal error on the buffer
    // resource (wlroots wlr_surface_reject_pending, wlr_compositor.c:
    // 874-889) and the resource is destroyed. The previous pending buffer
    // is untouched (the error path never reaches attachBuffer).
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
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);

    const foreign = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    const foreign_buf: *server.wl.Buffer = @ptrCast(foreign);
    s.handleAttach(foreign_buf, 0, 0);
    try testing.expect(s.pending.buffer == &buffer);
    try testing.expect(s.pending_resource == null);
}

test "role client_commit runs per client commit, not on cache flushes" {
    // F36: role.client_commit runs inside commit() (wlroots
    // surface_handle_commit wlr_compositor.c:582-584), exactly once per
    // client commit — NOT on the applyCommit of a cache flush
    // (wlr_surface_unlock_cached), which is not a client commit.
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    test_role_client_commits = 0;
    test_role_commits = 0;
    try role_mod.assignRole(s, &test_role, null);

    var buffer: Buffer = undefined;
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expectEqual(@as(usize, 1), test_role_client_commits);
    try testing.expectEqual(@as(usize, 1), test_role_commits);

    // A cache flush (applyCommit directly, like subsurface flushCached)
    // runs role.commit but not role.client_commit.
    var buffer2: Buffer = undefined;
    testBuffer(allocator, &buffer2);
    s.attachBuffer(&buffer2);
    s.applyCommit();
    try testing.expectEqual(@as(usize, 1), test_role_client_commits);
    try testing.expectEqual(@as(usize, 2), test_role_commits);
}

test "unmap signal fires before the role unmap hook" {
    // F37: wlroots emits the unmap signal before role->unmap
    // (wlr_surface_unmap wlr_compositor.c:854-872); ours used to run the
    // hook first.
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    test_unmap_seq_len = 0;
    test_unmap_order_listener = wire.Listener(*Surface).init(testUnmapOrderNotify);
    s.events.unmap.add(&test_unmap_order_listener);
    try role_mod.assignRole(s, &test_role, null);

    var buffer: Buffer = undefined;
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.mapped);

    s.attachBuffer(null);
    s.commit();
    try testing.expect(!s.mapped);
    // Sequence: 2 = unmap signal listener, 1 = role.unmap hook.
    try testing.expectEqual(@as(usize, 2), test_unmap_seq_len);
    try testing.expectEqual(@as(u8, 2), test_unmap_seq[0]);
    try testing.expectEqual(@as(u8, 1), test_unmap_seq[1]);
}

var test_unmap_seq: [8]u8 = undefined;
var test_unmap_seq_len: usize = 0;
// SAFETY: test fixture; initialized via .init(handler) inside the tests before use.
var test_unmap_order_listener: wire.Listener(*Surface) = undefined;

fn testUnmapOrderNotify(listener: *wire.Listener(*Surface), surface: *Surface) void {
    _ = listener;
    _ = surface;
    test_unmap_seq[test_unmap_seq_len] = 2; // the unmap signal
    test_unmap_seq_len += 1;
}

// --- zwp_linux_dmabuf_v1 attach ------------------------------------------
//
// handleAttach asks Compositor.resolveDmabuf before the shm registry, so
// a wl_buffer that shell/linux_dmabuf.zig created becomes a Buffer
// instead of an error.InvalidBuffer. That module cannot be imported here
// — it imports this file — so the stub below stands in for it. It
// implements the same contract (Compositor.DmabufResolver), which is
// what these tests pin: the resolver is consulted first, a resource it
// does not own falls through to shm unchanged, and clearing it stops
// the resolution.

/// Stands in for a producer registry (shell/linux_dmabuf.zig): it owns
/// exactly one wl_buffer resource and answers with the Buffer it
/// wrapped for it.
const StubDmabufRegistry = struct {
    resource: *wire.Resource,
    buffer: *Buffer,

    fn resolve(ctx: *anyopaque, resource: *wire.Resource) ?*Buffer {
        const self: *StubDmabufRegistry = @ptrCast(@alignCast(ctx));
        if (resource != self.resource) return null;
        return self.buffer;
    }
};

test "a dmabuf buffer resolves through the compositor resolver, then maps and damages" {
    // Before the resolver existed the attach only asked the SHM registry,
    // which answers error.InvalidBuffer for a buffer it never created,
    // and the client was killed with "unknown buffer type" (F56). The
    // resolved wrapper must now travel the ordinary attach -> damage ->
    // commit pipeline untouched.
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    var imported: Buffer = undefined;
    testBuffer(allocator, &imported); // 10x10, like a real dmabuf buffer
    const res = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    var registry: StubDmabufRegistry = .{ .resource = res, .buffer = &imported };
    comp.setDmabufResolver(.{ .ctx = &registry, .resolve = StubDmabufRegistry.resolve });

    s.handleAttach(@ptrCast(res), 0, 0);
    try testing.expect(s.pending.buffer == &imported);
    try testing.expect(s.pending_resource == res);
    // The attach took its lock on the module's own wrapper.
    try testing.expectEqual(@as(u32, 1), imported.n_locks);

    s.handleDamageBuffer(1, 1, 3, 3);
    s.handleDamage(1, 2, 3, 4);
    s.commit();

    try testing.expect(s.mapped);
    try testing.expect(s.buffer == &imported);
    try testing.expectEqual(@as(u32, 0), imported.n_locks); // commit unlocked it
    // Damage reached the commit pipeline: the buffer rect as sent, the
    // surface rect translated into buffer coordinates (scale 1, normal
    // transform), and the surface list untouched.
    try testing.expectEqual(@as(usize, 2), s.current.buffer_damage.rects.items.len);
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .width = 3, .height = 3 }, s.current.buffer_damage.rects.items[0]);
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .width = 3, .height = 4 }, s.current.buffer_damage.rects.items[1]);
    try testing.expectEqual(@as(usize, 1), s.current.surface_damage.rects.items.len);
}

test "a wl_buffer the dmabuf resolver does not own still goes down the shm path (F56)" {
    // The resolver is a lookup, not a claim on every wl_buffer in the
    // process: a resource it does not know must reach the SHM registry
    // exactly as before, and be rejected there for being an unknown
    // buffer type. The previous pending buffer survives.
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    var pending: Buffer = undefined;
    testBuffer(allocator, &pending);
    s.attachBuffer(&pending);

    var imported: Buffer = undefined;
    testBuffer(allocator, &imported);
    const mine = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    var registry: StubDmabufRegistry = .{ .resource = mine, .buffer = &imported };
    comp.setDmabufResolver(.{ .ctx = &registry, .resolve = StubDmabufRegistry.resolve });

    const foreign = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    s.handleAttach(@ptrCast(foreign), 0, 0);
    try testing.expect(s.pending.buffer == &pending);
    try testing.expect(s.pending_resource == null);
}

test "clearDmabufResolver stops the attach path resolving dmabuf buffers" {
    // main() clears the resolver BEFORE LinuxDmabuf.deinit, so an attach
    // that arrives afterwards must not reach the module. The same buffer
    // that resolved a moment ago now falls through to shm and is
    // rejected; the pending buffer the surface already had survives.
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    var imported: Buffer = undefined;
    testBuffer(allocator, &imported);
    const res = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    var registry: StubDmabufRegistry = .{ .resource = res, .buffer = &imported };
    comp.setDmabufResolver(.{ .ctx = &registry, .resolve = StubDmabufRegistry.resolve });

    s.handleAttach(@ptrCast(res), 0, 0);
    try testing.expect(s.pending.buffer == &imported);

    // Release the pending slot first: its F42 destroy listener is still
    // watching `res`, and rejecting the attach destroys that resource,
    // which would clear the pending slot through the listener and hide
    // what is being asserted.
    s.handleAttach(null, 0, 0);
    comp.clearDmabufResolver();
    var pending: Buffer = undefined;
    testBuffer(allocator, &pending);
    s.attachBuffer(&pending);
    s.handleAttach(@ptrCast(res), 0, 0);
    try testing.expect(s.pending.buffer == &pending);
}
