//! wl_subcompositor (M3/M4): nested surfaces (toolkit requirement).
//!
//! Minimal-but-functional subcompositor: the wl_subcompositor global and
//! wl_subsurface objects with role enforcement, set_position, sync/desync
//! commit caching and restack recording. The compositor renders
//! subsurface surfaces as scene nodes positioned over their parent
//! (server-side sync, see the test server's syncSubsurfaceNodes).
//!
//! Sync semantics (mirrors wlroots types/wlr_subcompositor.c):
//!   - A `sync` child's commits are DEFERRED: the pending state keeps
//!     accumulating on the child surface (surface.cached_state_locks)
//!     and nothing is applied until the parent commits (the parent's
//!     commit flushes the cache through the normal commit pipeline,
//!     wlroots subsurface_handle_parent_commit :240-250 /
//!     wlr_surface_unlock_cached, wlr_compositor.c:947-986). A `desync`
//!     child commits immediately.
//!   - set_desync flushes the cache immediately when no ancestor in the
//!     parent chain is synced anymore (wlr_subcompositor.c:195-207).
//!   - wl_subsurface teardown (client destroy or parent death) applies
//!     the cached commit before the role dies (wlroots subsurface_destroy
//!     :38-40); a child surface's own death drops the cache with it
//!     (wlroots surface_handle_resource_destroy :724-763).
//!   - Deferred commits merge into the single pending slot, so a flush
//!     applies the latest state in one commit (wlroots keeps a
//!     cached-state list and applies each in sequence; observationally
//!     equivalent for buffer/damage/frame-callback behavior).
//!
//! M3 simplifications (documented, foot-compatible):
//!   - place_above/place_below are validated and recorded (restack_*
//!     fields) but NOT applied by this module: the server reads the
//!     fields per frame and reorders scene nodes (the child still draws
//!     above its parent by default).
//!   - Destroying a wl_subsurface while its surface lives leaves the
//!     surface renderable as a plain surface (foot only destroys
//!     subsurfaces at teardown).
//!   - Lifecycle is guarded: if either surface (child or parent) is
//!     destroyed while the wl_subsurface lives, the compositor destroys
//!     the wl_subsurface synchronously (the child keeps rendering as a
//!     plain surface; a parent's death makes the wl_subsurface inert,
//!     per wlroots' destroy-on-parent-destroy). No raw *Surface pointer
//!     outlives its surface.
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, compositor/*.

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const compositor_mod = @import("compositor.zig");
const surface_mod = @import("surface.zig");
const role_mod = @import("role.zig");
// Imported for the test blocks (fabricated buffers).
const buffer_mod = @import("../buffers/buffer.zig");

const server = @import("protocol").server;

const Surface = surface_mod.Surface;

/// wl_subcompositor protocol version this library implements.
pub const subcompositor_version: u32 = 1;

pub const Subcompositor = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    compositor: *compositor_mod.Compositor,
    global: ?*wire.Global = null,
    /// All subsurfaces, for the compositor's per-frame node sync.
    subsurfaces: std.ArrayList(*Subsurface) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        compositor: *compositor_mod.Compositor,
    ) error{ OutOfMemory, GlobalCreateFailed }!*Subcompositor {
        const self = try allocator.create(Subcompositor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .compositor = compositor,
            .subsurfaces = .empty,
        };
        errdefer self.subsurfaces.deinit(allocator);
        self.global = try display.addGlobal(
            server.wl.Subcompositor,
            *Subcompositor,
            bindSubcompositor,
            subcompositor_version,
            self,
        );
        log.debug("subcompositor created", io, log_cfg, "subsurface", .{});
        return self;
    }

    pub fn deinit(self: *Subcompositor) void {
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        // Destroy outstanding wl_subsurface resources: each destroy
        // handler detaches its lifecycle listeners, removes the entry
        // from the registry and frees the Subsurface. This must happen
        // before the surfaces die (Compositor.deinit runs after this in
        // the server), or their destroy signals would fire listeners on
        // freed state.
        while (self.subsurfaces.items.len > 0) self.subsurfaces.items[0].resource.destroy();
        self.subsurfaces.deinit(allocator);
        allocator.destroy(self);
    }

    /// Resolve a wl_surface resource to its Surface (all surfaces belong
    /// to this compositor).
    pub fn surfaceFromResource(self: *Subcompositor, resource: *server.wl.Surface) ?*Surface {
        for (self.compositor.surfaces.items) |s| {
            if (s.resource == resource) return s;
        }
        return null;
    }
};

/// A wl_subsurface role object: the surface renders above `parent`,
/// offset by (x, y).
pub const Subsurface = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    subcompositor: *Subcompositor,
    resource: *server.wl.Subsurface,
    /// The child surface (wl_subsurface role). Valid only while this
    /// entry is in `subcompositor.subsurfaces`: either surface's death
    /// tears the entry down synchronously (see onSurfaceDestroy /
    /// onParentDestroy), so no raw pointer outlives its surface.
    surface: *Surface,
    /// The parent surface; same lifetime rule as `surface`.
    parent: *Surface,
    x: i32 = 0,
    y: i32 = 0,
    sync: bool = true,
    /// A deferred commit is pending on the child surface: its pending
    /// state is locked (surface.cached_state_locks) and will be applied
    /// by the flush path when the parent commits, on set_desync, or at
    /// teardown. Mirrors wlroots' wlr_subsurface.has_cache
    /// (wlr_subcompositor.c:224-250). Read with surface.cached_state_locks.
    sync_cached: bool = false,
    /// Pending restack (place_above/place_below): the wl_surface resource
    /// id of the reference (the parent or a sibling subsurface of the
    /// same parent), validated at request time; 0 = none pending. The id
    /// is client-local (the whole registry is per-client here), so the
    /// server must resolve it against the compositor's surface list.
    /// The server applies the reorder and resets this to 0.
    restack_sibling_id: u32 = 0,
    /// true = place_above (the child goes above the reference),
    /// false = place_below.
    restack_above: bool = true,
    /// Fired when `surface` (the child) dies: the wl_subsurface must die
    /// with its role object.
    surface_listener: wire.Listener(*Surface),
    /// Fired when `parent` dies: the wl_subsurface becomes inert and is
    /// destroyed by the compositor.
    parent_listener: wire.Listener(*Surface),
    /// On the child's client_commit signal: decides whether each commit is
    /// deferred (sync chain) or flushes a leftover cache. Mirrors
    /// subsurface_handle_surface_client_commit (wlr_subcompositor.c:224-235).
    client_commit_listener: wire.Listener(*Surface),
    /// On the parent's commit signal: flushes the child's cached commit.
    /// Mirrors subsurface_handle_parent_commit (wlr_subcompositor.c:240-250).
    parent_commit_listener: wire.Listener(*Surface),
};

/// The shared role for subsurface surfaces.
const subsurface_role: role_mod.SurfaceRole = .{ .name = "subsurface" };

fn bindSubcompositor(client: *wire.Client, sc: *Subcompositor, version: u32, id: u32) void {
    const resource = server.wl.Subcompositor.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Subcompositor, subcompositorRequest, null, sc);
}

fn subcompositorRequest(
    resource: *server.wl.Subcompositor,
    request: server.wl.Subcompositor.Request,
    sc: *Subcompositor,
) void {
    switch (request) {
        .get_subsurface => |r| getSubsurface(sc, resource, r.id, r.surface, r.parent),
        .destroy => resource.destroy(),
    }
}

fn getSubsurface(
    sc: *Subcompositor,
    resource: *server.wl.Subcompositor,
    id: u32,
    surface_res: *server.wl.Surface,
    parent_res: *server.wl.Surface,
) void {
    const client = resource.getClient();
    const surface = sc.surfaceFromResource(surface_res) orelse {
        resource.postNoMemory();
        return;
    };
    const parent = sc.surfaceFromResource(parent_res) orelse {
        resource.postNoMemory();
        return;
    };
    if (surface == parent) {
        // The parent must be a different surface.
        resource.postError(.bad_parent, "parent must be a different surface");
        return;
    }
    if (parent.role == &subsurface_role) {
        // A subsurface cannot be a parent (nesting goes through the
        // regular surface it is attached to).
        resource.postError(.bad_parent, "parent is a subsurface");
        return;
    }

    const ss_res = server.wl.Subsurface.create(client, 1, id) catch {
        resource.postNoMemory();
        return;
    };
    const ss = sc.allocator.create(Subsurface) catch {
        ss_res.destroy();
        resource.postNoMemory();
        return;
    };
    ss.* = .{
        .allocator = sc.allocator,
        .io = sc.io,
        .log_cfg = sc.log_cfg,
        .subcompositor = sc,
        .resource = ss_res,
        .surface = surface,
        .parent = parent,
        .surface_listener = wire.Listener(*Surface).init(onSurfaceDestroy),
        .parent_listener = wire.Listener(*Surface).init(onParentDestroy),
        .client_commit_listener = wire.Listener(*Surface).init(onSurfaceClientCommit),
        .parent_commit_listener = wire.Listener(*Surface).init(onParentCommit),
    };
    // Listener.init leaves `link` undefined; put it in the detached state
    // so the error paths below (which route through subsurfaceDestroy ->
    // detachListeners) never unlink garbage.
    ss.surface_listener.link.prev = null;
    ss.surface_listener.link.next = null;
    ss.parent_listener.link.prev = null;
    ss.parent_listener.link.next = null;
    ss.client_commit_listener.link.prev = null;
    ss.client_commit_listener.link.next = null;
    ss.parent_commit_listener.link.prev = null;
    ss.parent_commit_listener.link.next = null;
    ss_res.setHandler(*Subsurface, subsurfaceRequest, subsurfaceDestroy, ss);
    // The wl_subsurface cannot outlive either surface: tearing it down
    // when one dies also removes this entry from the registry, so the
    // per-frame sync (server/main.zig syncSubsurfaceNodes) never sees a
    // dead *Surface.
    surface.events.destroy.add(&ss.surface_listener);
    parent.events.destroy.add(&ss.parent_listener);
    // Sync caching: the child's client_commit signal decides deferral
    // (fired by Surface.commit before the apply decision, wlr_compositor.c:
    // 577-598); the parent's commit signal flushes the cache.
    surface.events.client_commit.add(&ss.client_commit_listener);
    parent.events.commit.add(&ss.parent_commit_listener);
    sc.subsurfaces.append(sc.allocator, ss) catch {
        ss_res.destroy();
        resource.postNoMemory();
        return;
    };
    // The role is permanent for the surface: a surface with an xdg role
    // cannot become a subsurface and vice versa.
    role_mod.assignRole(surface, &subsurface_role, @ptrCast(ss_res)) catch {
        ss_res.destroy();
        return;
    };
    log.debug("subsurface@{d} under parent@{d}", sc.io, sc.log_cfg, "subsurface", .{
        surface.resource.getId(),
        parent.resource.getId(),
    });
}

fn subsurfaceRequest(ss_res: *server.wl.Subsurface, request: server.wl.Subsurface.Request, ss: *Subsurface) void {
    switch (request) {
        .set_position => |r| {
            ss.x = r.x;
            ss.y = r.y;
        },
        .place_above => |r| {
            // Recorded for the server (main.zig reads restack_* per frame
            // and reorders scene nodes). The reference must be the parent
            // or a sibling subsurface of the same parent (wlroots
            // subsurface_find_sibling, wlr_subcompositor.c:76-152); the
            // sibling surfaces are resolved against the registry — a
            // wl_surface that is not one of those is a BAD_SURFACE error.
            if (restackTarget(ss, r.sibling)) |target| {
                ss.restack_sibling_id = target.resource.getId();
                ss.restack_above = true;
            } else {
                ss_res.postError(.bad_surface, "place_above: wl_surface is not a parent or sibling");
            }
        },
        .place_below => |r| {
            if (restackTarget(ss, r.sibling)) |target| {
                ss.restack_sibling_id = target.resource.getId();
                ss.restack_above = false;
            } else {
                ss_res.postError(.bad_surface, "place_below: wl_surface is not a parent or sibling");
            }
        },
        .set_sync => ss.sync = true,
        .set_desync => {
            if (ss.sync) {
                ss.sync = false;
                // wlroots subsurface_handle_set_desync
                // (wlr_subcompositor.c:195-207): flush the cache when the
                // whole sync chain (this subsurface + its ancestors) is
                // now desynced; otherwise the ancestor still batches this
                // child's commits.
                if (!isSynchronized(ss) and ss.sync_cached) flushCached(ss);
            }
        },
        .destroy => {
            // wlroots subsurface_destroy (wlr_subcompositor.c:38-40)
            // applies a leftover cache before the role dies; the child
            // keeps rendering as a plain surface with its latest content.
            if (ss.sync_cached) flushCached(ss);
            ss_res.destroy();
        },
    }
}

/// Resolve a place_above/place_below reference: the parent surface or a
/// sibling subsurface (same parent, different surface). Returns the
/// referenced surface, or null for the bad_surface protocol error.
fn restackTarget(ss: *Subsurface, sibling_res: *server.wl.Surface) ?*Surface {
    if (sibling_res == ss.parent.resource) return ss.parent;
    const sibling = ss.subcompositor.surfaceFromResource(sibling_res) orelse return null;
    for (ss.subcompositor.subsurfaces.items) |other| {
        if (other != ss and other.parent == ss.parent and other.surface == sibling) return sibling;
    }
    return null;
}

/// The child surface died: the wl_subsurface must die with it (its role
/// pointer would dangle). The destroy handler clears the role and frees.
/// No cache flush: a deferred commit lives in the child's own pending
/// state, which dies with the surface (wlroots surface_handle_resource_destroy
/// destroys cached states, wlr_compositor.c:724-763).
fn onSurfaceDestroy(listener: *wire.Listener(*Surface), _: *Surface) void {
    const ss: *Subsurface = @fieldParentPtr("surface_listener", listener);
    teardownOnSurfaceDeath(ss);
}

/// The parent surface died: the wl_subsurface is inert. Per wlroots
/// (wlr_subcompositor.c destroy-on-parent-destroy) the compositor
/// destroys it; the client sees its object die. A leftover cache is
/// applied first (wlroots subsurface_destroy -> wlr_surface_unlock_cached,
/// wlr_subcompositor.c:38-40): the parent's commit will never come, so
/// the child keeps its latest committed content as a plain surface.
fn onParentDestroy(listener: *wire.Listener(*Surface), _: *Surface) void {
    const ss: *Subsurface = @fieldParentPtr("parent_listener", listener);
    if (ss.sync_cached) flushCached(ss);
    teardownOnSurfaceDeath(ss);
}

/// On the child's client_commit signal (fired by Surface.commit before
/// the apply decision, wlr_compositor.c:577-598). Mirrors wlroots
/// subsurface_handle_surface_client_commit (wlr_subcompositor.c:224-235):
/// a synchronized child's commit is deferred — the pending state is
/// locked and keeps accumulating until the parent commits. A desynced
/// child with a leftover cache (its sync chain desynced since) flushes:
/// the cached content lives in the very pending state this commit is
/// about to apply, so clearing the lock lets commit() apply it.
fn onSurfaceClientCommit(listener: *wire.Listener(*Surface), _: *Surface) void {
    const ss: *Subsurface = @fieldParentPtr("client_commit_listener", listener);
    if (isSynchronized(ss)) {
        if (ss.sync_cached) return; // already deferred; this commit merges into pending
        ss.sync_cached = true;
        ss.surface.cached_state_locks = true;
    } else if (ss.sync_cached) {
        ss.sync_cached = false;
        ss.surface.cached_state_locks = false;
    }
}

/// On the parent's commit signal. Mirrors subsurface_handle_parent_commit
/// (wlr_subcompositor.c:240-250): the parent's commit flushes each direct
/// synced child's cache. The flush runs the child through the normal
/// commit pipeline (wlroots unlock_cached -> surface_commit_state,
/// wlr_compositor.c:947-986); the child's own commit signal then cascades
/// to its subsurfaces, so nested caches flush recursively.
fn onParentCommit(listener: *wire.Listener(*Surface), _: *Surface) void {
    const ss: *Subsurface = @fieldParentPtr("parent_commit_listener", listener);
    if (ss.sync and ss.sync_cached) flushCached(ss);
}

/// Apply the child's deferred pending state now. Clears the lock first so
/// applyCommit's commit signal does not re-enter the sync decision, then
/// applies through the normal pipeline (map/unmap transition included).
/// The merged pending may hold requests made after the child's last
/// commit (which is what was validated); re-validate like a commit would
/// and keep the pending on failure, so the client's next commit posts the
/// error instead of the flush presenting unvalidated state.
fn flushCached(ss: *Subsurface) void {
    ss.sync_cached = false;
    ss.surface.cached_state_locks = false;
    if (!ss.surface.validatePending()) return;
    ss.surface.applyCommit();
}

/// wlroots subsurface_is_synchronized (wlr_subcompositor.c:14-22): a
/// subsurface is synchronized if it or any ancestor subsurface in the
/// parent chain has the sync flag set. getSubsurface rejects subsurface
/// parents, so the chain is depth 1 today; the walk keeps the wlroots
/// rule faithful if nesting is ever allowed.
fn isSynchronized(ss: *Subsurface) bool {
    var cur: ?*Subsurface = ss;
    while (cur) |c| {
        if (c.sync) return true;
        cur = subsurfaceFromSurface(c.parent);
    }
    return false;
}

/// wlroots wlr_subsurface_try_from_wlr_surface (wlr_subcompositor.c:309-314):
/// the Subsurface behind a surface, if its role object is a live
/// wl_subsurface.
fn subsurfaceFromSurface(s: *Surface) ?*Subsurface {
    if (s.role != &subsurface_role) return null;
    const rr = s.role_resource orelse return null;
    const ud = rr.getUserData() orelse return null;
    return @ptrCast(@alignCast(ud));
}

/// Detach both lifecycle listeners, then destroy the wl_subsurface
/// resource. The destroy handler runs synchronously: it removes the entry
/// from the registry and frees `ss` — so `ss` must not be touched after
/// the resource.destroy() call.
fn teardownOnSurfaceDeath(ss: *Subsurface) void {
    detachListeners(ss);
    ss.resource.destroy();
}

/// Unsubscribe all four listeners. Idempotent: a link in the detached
/// state (prev/next null) is skipped.
fn detachListeners(ss: *Subsurface) void {
    if (ss.surface_listener.link.prev != null) ss.surface_listener.link.remove();
    if (ss.parent_listener.link.prev != null) ss.parent_listener.link.remove();
    if (ss.client_commit_listener.link.prev != null) ss.client_commit_listener.link.remove();
    if (ss.parent_commit_listener.link.prev != null) ss.parent_commit_listener.link.remove();
}

fn subsurfaceDestroy(ss_res: *server.wl.Subsurface, ss: *Subsurface) void {
    _ = ss_res;
    // Unsubscribe the lifecycle listeners first: a later surface destroy
    // must not fire into the freed state (this path frees ss below).
    detachListeners(ss);
    const sc = ss.subcompositor;
    // The surface loses its role; it keeps rendering as a plain surface
    // until it unmaps (the server's commit path handles that).
    if (ss.surface.role == &subsurface_role) {
        ss.surface.role = null;
        ss.surface.role_resource = null;
    }
    const idx = std.mem.indexOfScalar(*Subsurface, sc.subsurfaces.items, ss) orelse 0;
    if (idx < sc.subsurfaces.items.len and sc.subsurfaces.items[idx] == ss) {
        _ = sc.subsurfaces.orderedRemove(idx);
    }
    const allocator = sc.allocator;
    allocator.destroy(ss);
}

// --- Tests --------------------------------------------------------------

const testing = std.testing;

/// Fabricate a Subcompositor for tests. Subcompositor.init is bypassed:
/// it would call display.addGlobal on the dummy display pointer.
fn testSubcompositor(
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    comp: *compositor_mod.Compositor,
) !*Subcompositor {
    const sc = try allocator.create(Subcompositor);
    sc.* = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = log_cfg,
        .display = @ptrFromInt(0x10), // dummy: never dereferenced
        .compositor = comp,
        .global = null,
        .subsurfaces = .empty,
    };
    return sc;
}

const SubsurfaceTest = struct {
    allocator: std.mem.Allocator,
    tw: surface_mod.TestWire,
    comp: *compositor_mod.Compositor,
    sc: *Subcompositor,
    child: *Surface,
    parent: *Surface,

    fn init(allocator: std.mem.Allocator, io: *std.Io, log_cfg: *const log.Config) !SubsurfaceTest {
        var tw = try surface_mod.TestWire.init();
        errdefer tw.deinit();
        const comp = try surface_mod.testCompositor(allocator, io, log_cfg);
        errdefer allocator.destroy(comp);
        const child = try surface_mod.testSurface(allocator, io, log_cfg, comp, &tw);
        const parent = try surface_mod.testSurface(allocator, io, log_cfg, comp, &tw);
        try comp.surfaces.append(allocator, child);
        try comp.surfaces.append(allocator, parent);
        errdefer comp.surfaces.deinit(allocator);
        const sc = try testSubcompositor(allocator, io, log_cfg, comp);
        errdefer allocator.destroy(sc);
        const sc_res = try server.wl.Subcompositor.create(tw.client, 1, tw.newId());
        getSubsurface(sc, sc_res, tw.newId(), child.resource, parent.resource);
        return .{
            .allocator = allocator,
            .tw = tw,
            .comp = comp,
            .sc = sc,
            .child = child,
            .parent = parent,
        };
    }

    /// Client teardown destroys any surface resources that are still
    /// alive (Surface.destroy); the registry must already be empty.
    fn deinit(self: *SubsurfaceTest) void {
        self.tw.deinit();
        self.sc.subsurfaces.deinit(self.allocator);
        self.comp.surfaces.deinit(self.allocator);
        self.allocator.destroy(self.sc);
        self.allocator.destroy(self.comp);
    }
};

test "child surface destroy removes the subsurface from the registry" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.sc.subsurfaces.items.len);

    // Destroying the child surface synchronously tears the wl_subsurface
    // down: the registry entry is gone before the Surface is freed, so
    // the per-frame sync never dereferences a dead *Surface.
    t.child.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);

    // The parent's destroy signal must not fire a dangling listener.
    t.parent.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);
}

test "parent surface destroy removes the subsurface and clears the role" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.sc.subsurfaces.items.len);

    // Parent death makes the wl_subsurface inert: destroyed by the
    // compositor, entry removed from the registry.
    t.parent.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);
    // The child keeps rendering as a plain surface: its role is cleared.
    try testing.expect(t.child.role == null);

    // The child's destroy signal must not fire a dangling listener.
    t.child.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);
}

test "synced child commits are deferred until the parent commits" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();
    const ss = t.sc.subsurfaces.items[0];
    try testing.expect(ss.sync); // subsurfaces start synchronized

    var buffer: buffer_mod.Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    t.child.attachBuffer(&buffer);
    t.child.commit();

    // Deferred: nothing applied, no map; the pending state (and its
    // buffer lock) is retained until the parent commits.
    try testing.expect(t.child.current.buffer == null);
    try testing.expect(!t.child.mapped);
    try testing.expect(t.child.pending.buffer == &buffer);
    try testing.expect(ss.sync_cached);
    try testing.expect(t.child.cached_state_locks);

    // The parent's commit flushes the cache through the normal commit
    // pipeline (wlroots subsurface_handle_parent_commit, wlr_subcompositor.c:
    // 240-250): the child's state is applied and it maps.
    t.parent.commit();
    try testing.expect(t.child.current.buffer == &buffer);
    try testing.expect(t.child.mapped);
    try testing.expect(!ss.sync_cached);
    try testing.expect(!t.child.cached_state_locks);
    try testing.expect(t.child.pending.buffer == null);
}

test "a desync child commits immediately" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();
    const ss = t.sc.subsurfaces.items[0];
    subsurfaceRequest(ss.resource, .set_desync, ss);
    try testing.expect(!ss.sync);

    var buffer: buffer_mod.Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    t.child.attachBuffer(&buffer);
    t.child.commit();

    // Desynced: applied immediately, like a plain surface.
    try testing.expect(t.child.current.buffer == &buffer);
    try testing.expect(t.child.mapped);
    try testing.expect(!ss.sync_cached);
    try testing.expect(!t.child.cached_state_locks);
}

test "set_desync flushes the cached commit" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();
    const ss = t.sc.subsurfaces.items[0];

    var buffer: buffer_mod.Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    t.child.attachBuffer(&buffer);
    t.child.commit();
    try testing.expect(t.child.current.buffer == null); // deferred

    // wlroots subsurface_handle_set_desync (wlr_subcompositor.c:195-207):
    // with no synced ancestor left, the cache is applied immediately.
    subsurfaceRequest(ss.resource, .set_desync, ss);
    try testing.expect(t.child.current.buffer == &buffer);
    try testing.expect(!ss.sync_cached);
    try testing.expect(!t.child.cached_state_locks);
}

test "parent destroy applies the cached commit" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();

    var buffer: buffer_mod.Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    t.child.attachBuffer(&buffer);
    t.child.commit();
    try testing.expect(t.child.current.buffer == null); // deferred

    // The parent's commit will never come; wlroots applies the cache at
    // subsurface_destroy (wlr_subcompositor.c:38-40) so the child keeps
    // its latest committed content as a plain surface.
    t.parent.resource.destroy();
    try testing.expectEqual(@as(usize, 0), t.sc.subsurfaces.items.len);
    try testing.expect(t.child.current.buffer == &buffer);
    try testing.expect(t.child.role == null);
}

test "multiple deferred commits merge into one flush commit" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();

    test_child_commit_count = 0;
    test_child_commit_listener = wire.Listener(*Surface).init(testChildCommitNotify);
    t.child.events.commit.add(&test_child_commit_listener);

    var b1: buffer_mod.Buffer = undefined;
    surface_mod.testBuffer(allocator, &b1);
    t.child.attachBuffer(&b1);
    t.child.commit();
    var b2: buffer_mod.Buffer = undefined;
    surface_mod.testBuffer(allocator, &b2);
    t.child.attachBuffer(&b2);
    t.child.commit();

    // No commit signal while the cache is pending; the latest state wins.
    try testing.expectEqual(@as(usize, 0), test_child_commit_count);
    try testing.expect(t.child.pending.buffer == &b2);

    // The flush applies the merged state in ONE commit (wlroots applies
    // each cached state in sequence; merged is observationally equivalent
    // for buffer/damage/frame-callback behavior).
    t.parent.commit();
    try testing.expect(t.child.current.buffer == &b2);
    try testing.expectEqual(@as(usize, 1), test_child_commit_count);
    try testing.expect(b1.dropped);
}

test "place_above/below validate the reference and record the restack" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var t = try SubsurfaceTest.init(allocator, io, &log_cfg);
    defer t.deinit();
    const ss = t.sc.subsurfaces.items[0];

    // A third surface becomes a sibling subsurface of the same parent.
    const third = try surface_mod.testSurface(allocator, io, &log_cfg, t.comp, &t.tw);
    try t.comp.surfaces.append(allocator, third);
    const sc_res2 = try server.wl.Subcompositor.create(t.tw.client, 1, t.tw.newId());
    getSubsurface(t.sc, sc_res2, t.tw.newId(), third.resource, t.parent.resource);

    // place_above with the parent as reference: recorded, above.
    subsurfaceRequest(ss.resource, .{ .place_above = .{ .sibling = t.parent.resource } }, ss);
    try testing.expectEqual(t.parent.resource.getId(), ss.restack_sibling_id);
    try testing.expect(ss.restack_above);

    // place_below with the sibling subsurface's surface: recorded, below.
    subsurfaceRequest(ss.resource, .{ .place_below = .{ .sibling = third.resource } }, ss);
    try testing.expectEqual(third.resource.getId(), ss.restack_sibling_id);
    try testing.expect(!ss.restack_above);

    // An unrelated surface is a bad_surface: the restack is unchanged.
    const other = try surface_mod.testSurface(allocator, io, &log_cfg, t.comp, &t.tw);
    try t.comp.surfaces.append(allocator, other);
    subsurfaceRequest(ss.resource, .{ .place_above = .{ .sibling = other.resource } }, ss);
    try testing.expectEqual(third.resource.getId(), ss.restack_sibling_id);
}

var test_child_commit_count: usize = 0;
// SAFETY: test fixture; initialized via .init(handler) inside the test before use.
var test_child_commit_listener: wire.Listener(*Surface) = undefined;

fn testChildCommitNotify(listener: *wire.Listener(*Surface), surface: *Surface) void {
    _ = listener;
    _ = surface;
    test_child_commit_count += 1;
}
