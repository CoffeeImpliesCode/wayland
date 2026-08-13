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
//!      d. move the get_release callback lists with the buffer
//!      e. role.commit hook
//!      f. emit the commit signal
//!      g. map/unmap transition: mapped = isEffectivelyMapped (current
//!         buffer != null with width/height > 0 AND the role's mapped
//!         gate — the subsurface parent chain, wayland.xml:3254-3258);
//!         on change, run the map/unmap signal and the role hook (unmap:
//!         signal first, then role — F37)
//!      h. unlock the current buffer (wlroots wlr_compositor.c:570-574) so
//!         the client may reuse it (double buffering); the release signal
//!         fires here (buffers/buffer.zig) and completes get_release
//!         callbacks
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
    /// Buffer position within the surface (wlroots wlr_surface_state.dx/dy,
    /// wlr_compositor.h:58): wl_surface.offset (v5) or the pre-v5 attach
    /// dx/dy (F34). Consumers: XWayland positioning, cursor hotspots,
    /// popup placement. Cleared by a commit that carried no offset
    /// (wlroots surface_state_move wlr_compositor.c:340-346).
    dx: i32 = 0,
    dy: i32 = 0,
    /// Which fields the client changed since the last commit (wlroots
    /// wlr_surface_state.committed, wlr_compositor.h:38). swapState
    /// applies only the committed fields; uncommitted fields keep their
    /// current value across commits (F33). The pending state persists, so
    /// this is observably equivalent to a full copy EXCEPT where wlroots
    /// explicitly clears on an absent bit: the offset (dx/dy reset to 0,
    /// F34) and opaque/input regions (which pending does not persist —
    /// the swap nulls them). Damage transfers unconditionally: pending
    /// damage is always empty after a transfer, so wlroots' conditional
    /// clear-and-copy (wlr_compositor.c:374-385) is identical.
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

    /// Committed-field mask (see `committed`).
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
        /// A wl_surface.offset (or pre-v5 attach offset) arrived.
        offset: bool = false,
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
    /// The wl_buffer wire resource attached to the pending slot (null
    /// for a null attach). Mirrors wlroots' surface->pending.buffer_resource
    /// (wlr_compositor.c:38): its destroy listener (F42,
    /// pending_buffer_destroy) clears the pending slot when the client
    /// destroys the resource, so the next commit is a NULL-buffer commit
    /// (unmap) instead of committing a dead wrapper.
    pending_resource: ?*wire.Resource = null,
    /// Same tracking for the committed (current) slot; pending_resource
    /// moves here at applyCommit. When the client destroys the displayed
    /// buffer's resource, the listener clears current so the surface does
    /// not keep a dead wrapper in its canonical buffer slot (F42).
    current_resource: ?*wire.Resource = null,
    /// Destroy listener on the buffer resource of the most recently
    /// attached buffer (the F42 wrapper-death observer). Attached to at
    /// most one resource at a time; the handler detaches itself.
    pending_buffer_destroy: wire.Listener(*wire.Resource),
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
            // SAFETY: initialized via .link.init() immediately after
            // construction, before it can be attached to a resource.
            .pending_buffer_destroy = wire.Listener(*wire.Resource).init(onPendingBufferDestroy),
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
        // Listener.init leaves the intrusive link undefined; put it in the
        // detached state (link.prev == link.next == &link) so the
        // attached-or-not check in detachBufferDestroyListener works.
        s.pending_buffer_destroy.link.init();
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
            // F37: wlroots emits the unmap signal BEFORE the role hook
            // (wlr_surface_unmap wlr_compositor.c:854-872); listeners see
            // the signal first.
            s.events.unmap.emit(s);
            if (s.role) |role| if (role.unmap) |f| f(s);
        }
        if (s.role) |role| if (role.destroy) |f| f(s);
        s.events.destroy.emit(s);

        // Detach the buffer-resource destroy listener: the client's
        // wl_buffer resources outlive the surface, and the listener lives
        // inside the freed Surface. If the resource was already destroyed,
        // the handler detached itself (link in the detached state).
        if (s.pending_buffer_destroy.link.prev != null and
            s.pending_buffer_destroy.link.prev != &s.pending_buffer_destroy.link)
        {
            s.pending_buffer_destroy.link.remove();
        }

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
        if (buffer) |b| {
            b.lock() catch {
                // Could not take a reference; nothing to present.
                b.drop();
                s.resource.postNoMemory();
                return;
            };
            s.pending_locked = true;
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
        // The attach request changed the pending buffer (F33 committed
        // mask); a null attach sets it too, so a NULL-buffer commit swaps
        // the pending null into current and unmaps.
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
        const old_buffer = s.current.buffer;
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
        swapState(&s.current, s.allocator, &s.pending);
        // The buffer resource moves with the buffer (F42): the destroy
        // listener now watches the current slot.
        s.current_resource = s.pending_resource;
        s.pending_resource = null;

        // 8. The surface stopped using the previous buffer. Its lock was
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

        // 11. Unlock the current buffer (wlroots wlr_compositor.c:570-574)
        // so the client can reuse it immediately (double buffering). The
        // lockless re-attach special case leaves n_locks at 0, so guard the
        // unlock; the release signal fires here (buffers/buffer.zig) and
        // the get_release callbacks for this buffer complete.
        if (s.current.buffer) |b| {
            if (b.n_locks > 0) b.unlock();
            s.fireReleaseCallbacksCurrent();
        }
    }

    /// Whether the surface is effectively mapped: it has a current buffer
    /// with a positive size AND its role's mapped gate passes. The gate
    /// (SurfaceRole.mapped_gate) adds the role condition — the subsurface
    /// role fails while any ancestor in the parent chain is unmapped
    /// (wayland.xml:3254-3258: a sub-surface maps only when the parent
    /// surface is mapped; the rules apply recursively). The scene uses
    /// this for enter/present decisions; `mapped` (the transition) is
    /// driven by updateMapped.
    pub fn isEffectivelyMapped(s: *Surface) bool {
        const b = s.current.buffer orelse return false;
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
        // The attach carries the buffer position: at v5+ it is the
        // (mandatorily zero) offset that resets the pending dx/dy; below
        // v5 it is the real offset (F34, wlroots surface_handle_attach
        // wlr_compositor.c:68-83 stores dx/dy at every version).
        s.pending.dx = x;
        s.pending.dy = y;
        s.pending.committed.offset = true;

        if (buffer) |wl_buffer| {
            const res: *wire.Resource = @ptrCast(wl_buffer);
            const wrapped: *Buffer = (if (s.compositor.shm) |st|
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
            // wrapper. The listener watches one resource at a time (the
            // most recently attached); the handler matches it against both
            // slots by resource pointer.
            if (s.pending_buffer_destroy.link.prev != null and
                s.pending_buffer_destroy.link.prev != &s.pending_buffer_destroy.link)
            {
                s.pending_buffer_destroy.link.remove();
            }
            res.addDestroyListener(&s.pending_buffer_destroy);
            s.pending_resource = res;
            return;
        }
        // Null attach: no pending buffer; the F42 listener stays where it
        // is (it may be watching the current buffer).
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

    fn handleOffset(s: *Surface, x: i32, y: i32) void {
        // wl_surface.offset (v5): role-specific location of the pending
        // buffer (wlroots surface_handle_offset wlr_compositor.c:640-647).
        // Consumers: XWayland positioning, cursor hotspots, popup
        // placement. The offset is committed with the state and cleared by
        // a commit that carries none (see swapState / F34).
        s.pending.dx = x;
        s.pending.dy = y;
        s.pending.committed.offset = true;
    }

    fn fireReleaseCallbacksCurrent(s: *Surface) void {
        for (s.release_callbacks_current.items) |cb| cb.destroySendDone(0);
        s.release_callbacks_current.clearRetainingCapacity();
    }

    fn fireReleaseCallbacksPending(s: *Surface) void {
        for (s.release_callbacks_pending.items) |cb| cb.destroySendDone(0);
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

/// The client destroyed the wl_buffer resource backing the attached
/// (pending) or committed (current) buffer (F42). Mirrors wlroots'
/// pending_buffer_resource_handle_destroy (wlr_compositor.c:49-54): the
/// pending slot must not commit a dead wrapper — a commit after this
/// clears the pending slot becomes a NULL-buffer commit and unmaps. The
/// shm module's own resource listener runs first in this emission (it
/// registered at wrapper creation): by the time this runs the wrapper is
/// dropped, nulled, and possibly freed (F52's OOM fallback), so this
/// handler ONLY compares resource pointers and nulls its own slots — it
/// must never dereference the wrapper.
fn onPendingBufferDestroy(listener: *wire.Listener(*wire.Resource), resource: *wire.Resource) void {
    const s: *Surface = @fieldParentPtr("pending_buffer_destroy", listener);
    // Self-detach: the observed resource is going away; the link must not
    // outlive it (the destroy-path detach checks the link state).
    if (s.pending_buffer_destroy.link.prev != null and
        s.pending_buffer_destroy.link.prev != &s.pending_buffer_destroy.link)
    {
        s.pending_buffer_destroy.link.remove();
    }
    if (s.pending_resource == resource) {
        s.pending.buffer = null;
        s.pending_locked = false;
        s.pending_resource = null;
        s.fireReleaseCallbacksPending();
    }
    if (s.current_resource == resource) {
        s.current.buffer = null;
        s.current_resource = null;
        s.buffer = null;
        s.fireReleaseCallbacksCurrent();
    }
}

/// Apply pending to current (wlroots surface_state_move,
/// wlr_compositor.c:321-405). Only the fields the client actually changed
/// this cycle (pending.committed, F33) are applied; uncommitted fields
/// keep their current value across commits. Pending values persist, so
/// this is observably equivalent to a full copy except where wlroots
/// explicitly clears on an absent bit: the offset (dx/dy reset, F34) and
/// opaque/input regions (which pending does not persist — the swap nulls
/// them). The committed mask is consumed by this swap; pending restarts
/// empty and accumulates a fresh mask from the next requests (wlroots
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
    if (pending.committed.offset) {
        current.dx = pending.dx;
        current.dy = pending.dy;
    } else {
        // A commit that carried no offset clears it (wlroots
        // surface_state_move, wlr_compositor.c:340-346).
        current.dx = 0;
        current.dy = 0;
    }
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
    pending.dx = 3;
    pending.dy = -4;
    // Only the committed fields transfer (F33); the rest keep their
    // current value (and the offset clears without the offset bit, F34).
    pending.committed.buffer = true;
    pending.committed.@"opaque" = true;
    pending.committed.input = true;
    pending.committed.transform = true;
    pending.committed.scale = true;
    pending.committed.offset = true;

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
    try testing.expectEqual(@as(i32, 3), current.dx);
    try testing.expectEqual(@as(i32, -4), current.dy);
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
    try testing.expect(!pending.committed.offset);
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

    // First commit sets everything.
    pending.buffer = @as(?*Buffer, @ptrFromInt(0x200));
    pending.scale = 2;
    pending.dx = 3;
    pending.committed.buffer = true;
    pending.committed.scale = true;
    pending.committed.offset = true;
    swapState(&current, allocator, &pending);
    try testing.expectEqual(@as(i32, 2), current.scale);
    try testing.expectEqual(@as(i32, 3), current.dx);

    // Second commit changes only the buffer: scale keeps its current
    // value; the absent offset bit clears dx/dy (F34, wlroots
    // surface_state_move wlr_compositor.c:340-346).
    pending.buffer = @as(?*Buffer, @ptrFromInt(0x300));
    pending.committed.buffer = true;
    swapState(&current, allocator, &pending);
    try testing.expectEqual(@as(?*Buffer, @ptrFromInt(0x300)), current.buffer);
    try testing.expectEqual(@as(i32, 2), current.scale);
    try testing.expectEqual(@as(i32, 0), current.dx);
    try testing.expectEqual(@as(i32, 0), current.dy);
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

    // Re-attach of the current buffer (weston double-buffering pattern):
    // a fresh lock is taken per attach so the commit-end unlock releases
    // each use (the client keeps a leaf busy until wl_buffer.release).
    s.attachBuffer(&b);
    try testing.expect(s.pending_locked);
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
    try testing.expect(cursor_s.current.buffer == &cursor_buf);
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
    try testing.expect(s.current.buffer == &buffer);
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

test "offset is stored, committed, and cleared by a commit without one" {
    // F34: wl_surface.offset stores the pending dx/dy (wlroots
    // surface_handle_offset wlr_compositor.c:640-647); the commit applies
    // it; a commit that carried no offset clears it (surface_state_move
    // wlr_compositor.c:340-346).
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try TestWire.init();
    const comp = try testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try testSurface(allocator, io, &log_cfg, comp, &tw);

    s.handleOffset(7, -9);
    try testing.expectEqual(@as(i32, 7), s.pending.dx);
    try testing.expectEqual(@as(i32, -9), s.pending.dy);
    try testing.expect(s.pending.committed.offset);

    var buffer: Buffer = undefined;
    testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expectEqual(@as(i32, 7), s.current.dx);
    try testing.expectEqual(@as(i32, -9), s.current.dy);

    // A commit with no offset bit resets the current offset.
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expectEqual(@as(i32, 0), s.current.dx);
    try testing.expectEqual(@as(i32, 0), s.current.dy);
}

test "pre-v5 attach stores the offset" {
    // F34: below wl_surface v5 the attach dx/dy ARE the buffer position
    // (wlroots surface_handle_attach wlr_compositor.c:68-83). The offset
    // is stored even when the buffer wrap fails (the error path leaves
    // the pending state's offset intact).
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
    // fails the wrap with InvalidBuffer; the offset survives the error.
    const foreign = try wire.Resource.create(tw.client, wire.wl.Buffer, 1, tw.newId());
    const foreign_buf: *server.wl.Buffer = @ptrCast(foreign);
    s4.handleAttach(foreign_buf, 3, 5);
    try testing.expectEqual(@as(i32, 3), s4.pending.dx);
    try testing.expectEqual(@as(i32, 5), s4.pending.dy);
    try testing.expect(s4.pending.committed.offset);
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
