//! zwp_pointer_constraints_v1 (unstable/pointer-constraints, v1):
//! wp_locked_pointer_v1 and wp_confined_pointer_v1.
//!
//! wlroots parity (0.20.2). types/wlr_pointer_constraints_v1.c:
//! - The constraint RESOURCE is always created first, then the state is
//!   attached (:213-224), so the client's new_id is always answered.
//! - A wl_pointer that is not a live seat pointer leaves the resource
//!   INERT — created, never implemented, never signalled (:226-229). Same
//!   model here.
//! - `already_constrained` is posted on the zwp_pointer_constraints_v1
//!   resource (NOT on the new constraint object) when a constraint for the
//!   same (surface, seat) already exists, and the new resource is
//!   destroyed first (:233-241). The lookup is
//!   wlr_pointer_constraints_v1_constraint_for_surface, which compares
//!   surface AND seat (:375-387).
//! - Activation is NOT decided by this module in wlroots: the backend
//!   calls wlr_pointer_constraint_v1_send_activated / send_deactivated
//!   (:389-412). The events themselves are `locked`/`unlocked` and
//!   `confined`/`unconfined` with NO serial argument at all — the XML
//!   declares none (pointer-constraints-unstable-v1.xml:249-263, :315-330)
//!   and the bindings confirm it (`sendLocked()` takes no arguments).
//! - A ONESHOT constraint is destroyed the moment it deactivates
//!   (:408-411); a PERSISTENT one survives and may reactivate.
//! - Surface destruction destroys the constraint (:130-134).
//!
//! ACTIVATION POLICY (this compositor's, chosen and documented here).
//! A constraint activates on the first pointer motion while ALL of these
//! hold:
//!   1. its surface has POINTER FOCUS (the XML guarantees this at
//!      activation, XML:184-190 / :267-272),
//!   2. no compositor pointer grab is installed — a grab (main.zig's
//!      camera pan / interactive move, seat.zig:482-489) means the
//!      compositor owns the pointer, so it must not be constrained,
//!   3. the pointer's surface-local position lies inside the effective
//!      constraint region (the XML's own activation precondition,
//!      XML:119-121, :166-170).
//! A constraint that never satisfies this simply never activates — the XML
//! allows exactly that: "It is thus possible to request a lock that will
//! never activate" (XML:56-59).
//! Deactivation happens when the surface loses pointer focus.
//!
//! THE EFFECTIVE REGION is the intersection of the region the client passed
//! with the surface's committed INPUT region, with the input region alone
//! when no region was passed, and with the client's region alone when the
//! input region is unset (XML:119-121, :166-170; wlroots update_region,
//! :108-130). An unset input region accepts the whole surface, so a lock
//! without a region locks at the current position; with a region and no
//! input region that region is still the effective one — only a constraint
//! with NEITHER is unbounded.
//! set_region is DOUBLE-BUFFERED: it lands on the surface's next commit
//! (XML:218-219, :294-299), the same rule wlroots implements with
//! wlr_surface_synced (:250-251, :177-183).
//!
//! BOUNDED LIFETIME. Every constraint ends:
//!   - its own destroy request (the client asked for it; no event can
//!     follow a destroyed resource),
//!   - surface destruction: an ACTIVE lock/confine sends unlocked /
//!     unconfined and the object is destroyed, because the protocol's only
//!     way to tell the client is the event (XML:184-190);
//!   - deactivation of a ONESHOT constraint: event, then destroy
//!     (wlroots parity, :408-411);
//!   - setSeat(null) and PointerConstraints.deinit: every constraint is
//!     released, sending unlocked / unconfined for the active ones FIRST,
//!     so a client that is still connected always learns that the pointer
//!     came free.
//!
//! Geometry the driver needs is exposed, not hidden: cursorPosition
//! reports the pinned point of an active lock instead of the live pointer
//! position, and confine clamps a proposed cursor position into the
//! effective region of an active confinement. The wire module itself does
//! not suppress wl_pointer.motion — the seat delivers motion before the
//! pointer_move signal fires, so gating delivery belongs to the driver that
//! owns the grab (wlroots has the same split: libinput's constrained device
//! does the gating, not wlr_pointer_constraints_v1.c).

const std = @import("std");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
const geom = @import("../utils/geom.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const surface_mod = @import("../compositor/surface.zig");
const seat_mod = @import("../compositor/seat.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const region_mod = @import("../compositor/region.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "pointer_constraints";
const Fixed = wire.wl.Fixed;
const Rect = geom.Rect;
const Point = geom.Point;

/// zwp_pointer_constraints_v1.lifetime (XML:75-97).
pub const Lifetime = server.zwp.PointerConstraintsV1.Lifetime;

/// Which constraint a request created.
pub const ConstraintKind = enum {
    /// wp_locked_pointer_v1: the cursor is pinned where the lock activated.
    locked,
    /// wp_confined_pointer_v1: the cursor is confined to the region.
    confined,
};

/// Where the compositor must present the cursor.
pub const CursorPosition = struct {
    surface: *surface_mod.Surface,
    /// Surface-local x.
    x: i32,
    /// Surface-local y.
    y: i32,
    /// True when an active lock pins the cursor here: the position must not
    /// follow the seat any more.
    locked: bool,
};

/// wp_locked_pointer_v1.set_cursor_position_hint (XML:218-236): the
/// surface-local point the client draws its own cursor at.
pub const CursorPositionHint = struct { x: Fixed, y: Fixed };

pub const Constraint = struct {
    pc: *PointerConstraints,
    /// The seat the wl_pointer belonged to. Non-optional: a constraint for
    /// a foreign pointer is left INERT and never becomes a Constraint.
    seat: *seat_mod.Seat,
    /// The client's wl_surface; null once the surface is destroyed (the
    /// constraint then destroys its own resource).
    surface: ?*surface_mod.Surface,
    /// The wl_client the constraint resource belongs to, for serial minting.
    client: *wire.Client,
    kind: ConstraintKind,
    lifetime: Lifetime,
    /// Exactly one of these is non-null, matching `kind`.
    locked_res: ?*server.zwp.LockedPointerV1 = null,
    confined_res: ?*server.zwp.ConfinedPointerV1 = null,
    /// Whether `locked` / `confined` has been sent and not yet revoked.
    active: bool = false,
    /// The serial minted at the last activation. The XML declares no serial
    /// ARGUMENT on locked/confined/unlocked/unconfined, so this is the
    /// seat's serial for the activation boundary — minted through
    /// Seat.serialFor, which records it in the client's serial ring exactly
    /// like wlroots' wlr_seat_client_next_serial (wlr_pointer_gestures_v1.c
    /// style; wlr_seat_client_next_serial, wlr_seat.c:473-497).
    serial: u32 = 0,
    /// The surface-local point an active lock pins the cursor at.
    lock_x: i32 = 0,
    lock_y: i32 = 0,
    /// The client's set_cursor_position_hint in effect, if any. The hint is
    /// double-buffered too (XML:229-231), so it lands at the next commit.
    hint: ?CursorPositionHint = null,
    pending_hint: ?CursorPositionHint = null,
    /// The client's own region (deep-copied from the wl_region so it
    /// survives the client destroying it), or null for "whole surface".
    client_region: ?std.ArrayList(Rect),
    /// A pending set_region, applied at the next surface commit
    /// (double-buffered, XML:218-219 / :294-299).
    pending_client_region: ?std.ArrayList(Rect) = null,
    /// The effective region: client_region (or the input region) clipped to
    /// the input region. Empty means nothing can activate.
    region: std.ArrayList(Rect) = .empty,
    /// True when the effective region is the whole surface (no client region
    /// and no input region), so every point is inside it.
    region_unbounded: bool = false,
    /// Surface destroy / commit listeners, attached while `surface` is set.
    surface_listener: wire.Listener(*surface_mod.Surface),
    commit_listener: wire.Listener(*surface_mod.Surface),

    /// The wire resource, whichever interface it is. zwp_locked_pointer_v1
    /// and zwp_confined_pointer_v1 are DISTINCT types, so each branch casts
    /// on its own — an if-expression over the two never unifies. The cast is
    /// the one the generated bindings use themselves
    /// (LockedPointerV1.destroy, wayland.zig:21369-21370).
    pub fn resource(self: *Constraint) *wire.Resource {
        if (self.locked_res) |res| return @ptrCast(res);
        return @ptrCast(self.confined_res.?);
    }

    pub fn isActive(self: *const Constraint) bool {
        return self.active;
    }

    /// The serial minted at the last activation.
    pub fn activationSerial(self: *const Constraint) u32 {
        return self.serial;
    }

    /// The effective constraint region, in surface-local coordinates. Empty
    /// (with `isUnbounded` false) means no point can activate the
    /// constraint.
    pub fn effectiveRegion(self: *const Constraint) []const Rect {
        return self.region.items;
    }

    pub fn isUnbounded(self: *const Constraint) bool {
        return self.region_unbounded;
    }

    /// True when (x, y) lies inside the effective region.
    pub fn contains(self: *const Constraint, x: i32, y: i32) bool {
        if (self.region_unbounded) return true;
        for (self.region.items) |r| {
            if (r.containsPoint(.{ .x = x, .y = y })) return true;
        }
        return false;
    }

    /// The point the cursor must be moved to so it lies inside the
    /// effective region: an inside point is returned unchanged, otherwise
    /// the nearest inside point (per rect, then the closest of those).
    /// Null when the region is empty or unbounded — there is nothing to
    /// clamp to.
    pub fn clampTo(self: *const Constraint, x: i32, y: i32) ?Point {
        if (self.region_unbounded) return null;
        if (self.region.items.len == 0) return null;
        if (self.contains(x, y)) return .{ .x = x, .y = y };
        var best: ?Point = null;
        var best_dist: u64 = std.math.maxInt(u64);
        for (self.region.items) |r| {
            if (r.isEmpty()) continue; // a degenerate rect clamps to nothing
            const cx = std.math.clamp(x, r.x, geom.addSat(r.x, r.width) - 1);
            const cy = std.math.clamp(y, r.y, geom.addSat(r.y, r.height) - 1);
            const ddx: u64 = @abs(@as(i64, cx) - @as(i64, x));
            const ddy: u64 = @abs(@as(i64, cy) - @as(i64, y));
            const dist = ddx *| ddx +| ddy *| ddy;
            if (dist < best_dist) {
                best_dist = dist;
                best = .{ .x = cx, .y = cy };
            }
        }
        return best;
    }

    fn sendLocked(self: *Constraint, locked: bool) void {
        if (self.locked_res) |res| {
            if (locked) res.sendLocked() else res.sendUnlocked();
        } else if (self.confined_res) |res| {
            if (locked) res.sendConfined() else res.sendUnconfined();
        }
    }
};

pub const PointerConstraints = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// Resolves wl_surface resources for lock_pointer / confine_pointer.
    compositor: *compositor_mod.Compositor,
    /// The seat whose pointer is constrained; null when the compositor has
    /// no seat — the global still binds and every constraint is inert.
    seat: ?*seat_mod.Seat,
    /// The zwp_pointer_constraints_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// Live constraints. At most one per (surface, seat).
    constraints: std.ArrayList(*Constraint) = .empty,
    /// Bound zwp_pointer_constraints_v1 resources (one per client bind).
    /// Tracked so deinit destroys them: their handler data is this module.
    managers: std.ArrayList(*server.zwp.PointerConstraintsV1) = .empty,

    /// Seat motion / seat-destroy listeners, owned by the module for
    /// exactly as long as self.seat is non-null.
    motion_listener: wire.Listener(*seat_mod.Seat),
    seat_destroy_listener: wire.Listener(*seat_mod.Seat),

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        compositor: *compositor_mod.Compositor,
        seat: ?*seat_mod.Seat,
    ) error{ OutOfMemory, GlobalCreateFailed }!*PointerConstraints {
        const self = try allocator.create(PointerConstraints);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .compositor = compositor,
            .seat = null,
            // SAFETY: the links are put in the detached state by setSeat
            // below (and stay there while self.seat is null) before any
            // seat can reach them, so Listener.init leaving them
            // undefined is never observed.
            .motion_listener = wire.Listener(*seat_mod.Seat).init(onSeatMotion),
            .seat_destroy_listener = wire.Listener(*seat_mod.Seat).init(onSeatDestroy),
        };
        errdefer self.constraints.deinit(allocator);
        errdefer self.managers.deinit(allocator);
        self.global = try display.addGlobal(
            server.zwp.PointerConstraintsV1,
            *PointerConstraints,
            constraintsBind,
            server.zwp.PointerConstraintsV1.generated_version,
            self,
        );
        self.setSeat(seat);
        return self;
    }

    pub fn deinit(self: *PointerConstraints) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Detaching releases every constraint and drops the seat
        // listeners; a listener must not outlive the module.
        self.setSeat(null);
        self.releaseAll();
        // The manager resources carry this module as their handler data,
        // so they must die with it.
        while (self.managers.items.len > 0) self.managers.items[0].destroy();
        self.constraints.deinit(allocator);
        self.managers.deinit(allocator);
        allocator.destroy(self);
    }

    /// Attach (or detach, with null) the seat whose pointer is constrained.
    /// Detaching RELEASES every constraint: the pointer they constrained is
    /// gone. Each ACTIVE constraint sends its unlocked / unconfined event
    /// before its resource is destroyed.
    pub fn setSeat(self: *PointerConstraints, seat: ?*seat_mod.Seat) void {
        if (self.seat == seat) return;
        if (self.seat != null) {
            // wire.Signal has no remove(); the links are live exactly
            // while self.seat != null (added below, removed here).
            self.motion_listener.link.remove();
            self.seat_destroy_listener.link.remove();
        }
        self.releaseAll();
        self.seat = seat;
        if (seat) |s| {
            s.events.pointer_move.add(&self.motion_listener);
            s.events.destroy.add(&self.seat_destroy_listener);
        }
    }

    /// The constraint for `surface` on `seat`, if any (wlroots
    /// wlr_pointer_constraints_v1_constraint_for_surface,
    /// wlr_pointer_constraints_v1.c:375-387).
    pub fn constraintFor(
        self: *PointerConstraints,
        surface: *surface_mod.Surface,
        seat: *seat_mod.Seat,
    ) ?*Constraint {
        for (self.constraints.items) |c| {
            if (c.seat != seat) continue;
            if (c.surface != surface) continue;
            return c;
        }
        return null;
    }

    /// The active LOCKED constraint on `surface` for the attached seat.
    pub fn activeLock(self: *PointerConstraints, surface: *surface_mod.Surface) ?*Constraint {
        const seat = self.seat orelse return null;
        const c = self.constraintFor(surface, seat) orelse return null;
        if (!c.active or c.kind != .locked) return null;
        return c;
    }

    /// The active CONFINED constraint on `surface` for the attached seat.
    pub fn activeConfine(self: *PointerConstraints, surface: *surface_mod.Surface) ?*Constraint {
        const seat = self.seat orelse return null;
        const c = self.constraintFor(surface, seat) orelse return null;
        if (!c.active or c.kind != .confined) return null;
        return c;
    }

    /// Where the compositor must present the cursor on `surface`: the
    /// pinned point of an active lock, else the live pointer position.
    pub fn cursorPosition(
        self: *PointerConstraints,
        surface: *surface_mod.Surface,
        live_x: i32,
        live_y: i32,
    ) CursorPosition {
        if (self.activeLock(surface)) |c| {
            return .{ .surface = surface, .x = c.lock_x, .y = c.lock_y, .locked = true };
        }
        return .{ .surface = surface, .x = live_x, .y = live_y, .locked = false };
    }

    /// Clamp a proposed cursor position into the active confinement of
    /// `surface`. Null when nothing confines it.
    pub fn confine(
        self: *PointerConstraints,
        surface: *surface_mod.Surface,
        x: i32,
        y: i32,
    ) ?Point {
        const c = self.activeConfine(surface) orelse return null;
        return c.clampTo(x, y);
    }

    /// Number of constraints currently active (locked or confined).
    pub fn activeCount(self: *PointerConstraints) usize {
        var n: usize = 0;
        for (self.constraints.items) |c| {
            if (c.active) n += 1;
        }
        return n;
    }

    // --- activation ----------------------------------------------------

    fn onMotion(self: *PointerConstraints) void {
        const seat = self.seat orelse return;
        // A oneshot constraint destroys ITSELF when it deactivates, which
        // swap-removes the entry under us: only advance when the entry
        // survived, so the swapped-in element is still visited.
        var i: usize = 0;
        while (i < self.constraints.items.len) {
            const removed = self.step(self.constraints.items[i], seat);
            if (!removed) i += 1;
        }
    }

    /// Advance one constraint's state; returns true when the constraint
    /// destroyed itself and must not be stepped again.
    fn step(self: *PointerConstraints, c: *Constraint, seat: *seat_mod.Seat) bool {
        const surface = c.surface orelse return false;
        const focused = seat.pointer_focus == surface;
        if (c.active) {
            if (!focused) return self.deactivate(c);
            return false;
        }
        if (!focused) return false;
        // A compositor grab owns the pointer (main.zig's camera pan /
        // interactive move, seat.zig:482-489): never constrain it.
        if (seat.pointer_grab != null) return false;
        // The XML's activation precondition: the pointer must already be
        // inside the region (XML:119-121, :166-170).
        if (!c.contains(seat.focus_x, seat.focus_y)) return false;
        self.activate(c, seat);
        return false;
    }

    fn activate(self: *PointerConstraints, c: *Constraint, seat: *seat_mod.Seat) void {
        c.active = true;
        // The XML carries no serial argument, but the transition is a seat
        // event: mint a serial so it lands in the client's serial ring.
        c.serial = seat.serialFor(c.client);
        c.lock_x = seat.focus_x;
        c.lock_y = seat.focus_y;
        c.sendLocked(true);
        log.debug("pointer constraint {s} activated on surface@{d}", self.io, self.log_cfg, log_tag, .{
            @tagName(c.kind),
            c.surface.?.resource.getId(),
        });
    }

    /// Returns true when the constraint destroyed itself.
    fn deactivate(self: *PointerConstraints, c: *Constraint) bool {
        if (!c.active) return false;
        c.active = false;
        c.sendLocked(false);
        log.debug("pointer constraint {s} deactivated", self.io, self.log_cfg, log_tag, .{@tagName(c.kind)});
        // A oneshot constraint is defunct once it deactivates and must be
        // destroyed (XML:255-259; wlroots send_deactivated, :408-411).
        if (c.lifetime == .oneshot) {
            c.resource().destroy();
            return true;
        }
        return false;
    }

    /// Send unlocked / unconfined for every ACTIVE constraint, then destroy
    /// every constraint's resource. Used by setSeat(null) and deinit.
    fn releaseAll(self: *PointerConstraints) void {
        while (self.constraints.items.len > 0) {
            const c = self.constraints.items[0];
            if (c.active) {
                c.active = false;
                c.sendLocked(false);
            }
            // The destroy handler prunes index 0, so the loop terminates.
            c.resource().destroy();
        }
    }

    // --- constraint lifecycle -------------------------------------------

    fn createLocked(
        self: *PointerConstraints,
        manager: *server.zwp.PointerConstraintsV1,
        id: u32,
        surface_res: *server.wl.Surface,
        pointer_res: *server.wl.Pointer,
        region_res: ?*server.wl.Region,
        lifetime: Lifetime,
    ) void {
        // The resource is created before the state exists (wlroots
        // :213-224), so the client's new_id is always answered.
        const res = server.zwp.LockedPointerV1.create(manager.getClient(), manager.getVersion(), id) catch {
            manager.postNoMemory();
            return;
        };
        const seat = self.seatFor(pointer_res) orelse return inertLocked(res);
        const surface = self.surfaceFor(surface_res) orelse return inertLocked(res);
        if (self.constraintFor(surface, seat) != null) {
            res.destroy();
            manager.postError(
                .already_constrained,
                "a pointer constraint with a wl_pointer of the same wl_seat is already on this surface",
            );
            return;
        }
        const c = self.allocator.create(Constraint) catch {
            res.destroy();
            manager.postNoMemory();
            return;
        };
        c.* = .{
            .pc = self,
            .seat = seat,
            .surface = surface,
            .client = manager.getClient(),
            .kind = .locked,
            .lifetime = lifetime,
            .locked_res = res,
            .confined_res = null,
            .client_region = self.copyRegion(region_res) catch {
                self.allocator.destroy(c);
                res.destroy();
                manager.postNoMemory();
                return;
            },
            .surface_listener = wire.Listener(*surface_mod.Surface).init(onConstraintSurfaceDestroy),
            .commit_listener = wire.Listener(*surface_mod.Surface).init(onConstraintCommit),
        };
        self.constraints.append(self.allocator, c) catch {
            self.freeConstraintState(c);
            self.allocator.destroy(c);
            res.destroy();
            manager.postNoMemory();
            return;
        };
        res.setHandler(*Constraint, lockedRequest, lockedDestroy, c);
        surface.events.destroy.add(&c.surface_listener);
        surface.events.commit.add(&c.commit_listener);
        recomputeRegion(c) catch res.postNoMemory();
    }

    fn createConfined(
        self: *PointerConstraints,
        manager: *server.zwp.PointerConstraintsV1,
        id: u32,
        surface_res: *server.wl.Surface,
        pointer_res: *server.wl.Pointer,
        region_res: ?*server.wl.Region,
        lifetime: Lifetime,
    ) void {
        const res = server.zwp.ConfinedPointerV1.create(manager.getClient(), manager.getVersion(), id) catch {
            manager.postNoMemory();
            return;
        };
        const seat = self.seatFor(pointer_res) orelse return inertConfined(res);
        const surface = self.surfaceFor(surface_res) orelse return inertConfined(res);
        if (self.constraintFor(surface, seat) != null) {
            res.destroy();
            manager.postError(
                .already_constrained,
                "a pointer constraint with a wl_pointer of the same wl_seat is already on this surface",
            );
            return;
        }
        const c = self.allocator.create(Constraint) catch {
            res.destroy();
            manager.postNoMemory();
            return;
        };
        c.* = .{
            .pc = self,
            .seat = seat,
            .surface = surface,
            .client = manager.getClient(),
            .kind = .confined,
            .lifetime = lifetime,
            .locked_res = null,
            .confined_res = res,
            .client_region = self.copyRegion(region_res) catch {
                self.allocator.destroy(c);
                res.destroy();
                manager.postNoMemory();
                return;
            },
            .surface_listener = wire.Listener(*surface_mod.Surface).init(onConstraintSurfaceDestroy),
            .commit_listener = wire.Listener(*surface_mod.Surface).init(onConstraintCommit),
        };
        self.constraints.append(self.allocator, c) catch {
            self.freeConstraintState(c);
            self.allocator.destroy(c);
            res.destroy();
            manager.postNoMemory();
            return;
        };
        res.setHandler(*Constraint, confinedRequest, confinedDestroy, c);
        surface.events.destroy.add(&c.surface_listener);
        surface.events.commit.add(&c.commit_listener);
        recomputeRegion(c) catch res.postNoMemory();
    }

    fn seatFor(self: *PointerConstraints, ptr: *server.wl.Pointer) ?*seat_mod.Seat {
        const seat = self.seat orelse return null;
        if (std.mem.indexOfScalar(*server.wl.Pointer, seat.pointers.items, ptr) == null) return null;
        return seat;
    }

    fn surfaceFor(self: *PointerConstraints, res: *server.wl.Surface) ?*surface_mod.Surface {
        for (self.compositor.surfaces.items) |s| {
            if (s.resource == res) return s;
        }
        return null;
    }

    /// Deep-copy a wl_region's rects: the client may destroy the region
    /// right after the request, exactly like the surface's own input/opaque
    /// snapshots (surface.zig:133-139).
    fn copyRegion(self: *PointerConstraints, res: ?*server.wl.Region) !?std.ArrayList(Rect) {
        const region_res = res orelse return null;
        const ud = region_res.getUserData() orelse return null;
        const region: *region_mod.Region = @ptrCast(@alignCast(ud));
        var list: std.ArrayList(Rect) = .empty;
        errdefer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, region.rects.items);
        return list;
    }

    /// Free the three region buffers. Both optionals are captured BY
    /// POINTER: `|r|` copies the ArrayList into a const temporary while
    /// std.array_list.Aligned.deinit takes `*Self`, so the capture has to
    /// bind the field itself instead of laundering the pointer.
    fn freeConstraintState(self: *PointerConstraints, c: *Constraint) void {
        if (c.client_region) |*r| r.deinit(self.allocator);
        if (c.pending_client_region) |*r| r.deinit(self.allocator);
        c.region.deinit(self.allocator);
    }
};

/// Recompute the effective region: the client's region (or the input
/// region) intersected with the input region. An unset input region accepts
/// the whole surface (wlroots update_region, wlr_pointer_constraints_v1.c:
/// 108-130). ONLY a constraint with neither a client region nor an input
/// region is unbounded: with a client region but no input region the
/// effective region is exactly that region, never the whole surface.
fn recomputeRegion(c: *Constraint) !void {
    const pc = c.pc;
    c.region.clearRetainingCapacity();
    const input: ?[]const Rect = blk: {
        const surface = c.surface orelse break :blk null;
        if (surface.current.input) |r| break :blk r.items;
        break :blk null;
    };
    if (input == null and c.client_region == null) {
        // Nothing bounds the constraint: the whole surface is effective.
        c.region_unbounded = true;
        return;
    }
    c.region_unbounded = false;
    if (input == null) {
        // An unset input region accepts the whole surface, so the client's
        // own region IS the effective one. It is NOT unbounded: a confine
        // region the client passed must still hold the cursor (XML:119-121,
        // :166-170), which the old early return here silently dropped —
        // the constraint then activated anywhere on the surface.
        try c.region.appendSlice(pc.allocator, c.client_region.?.items);
        return;
    }
    const base: []const Rect = if (c.client_region) |r| r.items else input.?;
    for (base) |r| {
        for (input.?) |ir| {
            if (r.intersect(ir)) |both| try c.region.append(pc.allocator, both);
        }
    }
}

fn onSeatMotion(listener: *wire.Listener(*seat_mod.Seat), _: *seat_mod.Seat) void {
    const self: *PointerConstraints = @fieldParentPtr("motion_listener", listener);
    self.onMotion();
}

/// The seat is dying: release every constraint while the seat is still
/// valid (seat.zig:519-525 emits at the top of Seat.deinit, "while the seat
/// memory is still valid"), then drop the seat so the module can never call
/// into freed memory.
fn onSeatDestroy(listener: *wire.Listener(*seat_mod.Seat), _: *seat_mod.Seat) void {
    const self: *PointerConstraints = @fieldParentPtr("seat_destroy_listener", listener);
    self.setSeat(null);
}

/// The constrained surface is gone: detach both listeners, end an active
/// lock / confinement (its only client-visible notification), and destroy
/// the defunct object (XML:184-190, :267-272; wlroots
/// handle_surface_destroy, :130-134).
fn onConstraintSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), _: *surface_mod.Surface) void {
    const c: *Constraint = @fieldParentPtr("surface_listener", listener);
    c.surface_listener.link.remove();
    c.commit_listener.link.remove();
    c.surface = null;
    if (c.active) {
        c.active = false;
        c.sendLocked(false);
    }
    destroyConstraint(c);
}

/// The surface committed: apply a pending set_region (double-buffered,
/// XML:218-219 / :294-299) and refresh the effective region, which also
/// picks up a changed input region.
fn onConstraintCommit(listener: *wire.Listener(*surface_mod.Surface), _: *surface_mod.Surface) void {
    const c: *Constraint = @fieldParentPtr("commit_listener", listener);
    if (c.pending_client_region) |pending| {
        const allocator = c.pc.allocator;
        if (c.client_region) |*old| old.deinit(allocator);
        c.client_region = pending;
        c.pending_client_region = null;
    }
    // The cursor position hint is double-buffered too (XML:229-231).
    if (c.pending_hint) |pending| {
        c.hint = pending;
        c.pending_hint = null;
    }
    recomputeRegion(c) catch c.resource().postNoMemory();
}

/// A wl_pointer that is not a live seat pointer leaves the resource INERT:
/// it exists, its destroy works, it never emits (wlroots
/// wlr_pointer_constraints_v1.c:226-229). A live no-op handler is
/// required — a null dispatcher makes libwayland abort the compositor on
/// the client's next request (wayland-server.c wl_closure_invoke).
/// File scope, not a PointerConstraints method: neither helper touches the
/// module, and `self.f()` only resolves for METHODS.
fn inertLocked(res: *server.zwp.LockedPointerV1) void {
    res.setHandler(?*Constraint, inertLockedRequest, null, null);
}

/// zwp_confined_pointer_v1's twin of inertLocked (wlroots
/// wlr_pointer_constraints_v1.c:226-229).
fn inertConfined(res: *server.zwp.ConfinedPointerV1) void {
    res.setHandler(?*Constraint, inertConfinedRequest, null, null);
}

fn inertLockedRequest(res: *server.zwp.LockedPointerV1, request: server.zwp.LockedPointerV1.Request, _: ?*Constraint) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_cursor_position_hint => {},
        .set_region => {},
    }
}

fn inertConfinedRequest(res: *server.zwp.ConfinedPointerV1, request: server.zwp.ConfinedPointerV1.Request, _: ?*Constraint) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_region => {},
    }
}

// --- wire plumbing -------------------------------------------------------

fn constraintsBind(client_wire: *wire.Client, self: *PointerConstraints, version: u32, id: u32) void {
    log.debug("pointer constraints bind v{d} id={d}", self.io, self.log_cfg, log_tag, .{ version, id });
    const res = server.zwp.PointerConstraintsV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    self.managers.append(self.allocator, res) catch {
        res.destroy();
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*PointerConstraints, constraintsRequest, constraintsManagerDestroy, self);
}

fn constraintsRequest(
    res: *server.zwp.PointerConstraintsV1,
    request: server.zwp.PointerConstraintsV1.Request,
    self: *PointerConstraints,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => res.destroy(),
        .lock_pointer => |r| self.createLocked(res, r.id, r.surface, r.pointer, r.region, r.lifetime),
        .confine_pointer => |r| self.createConfined(res, r.id, r.surface, r.pointer, r.region, r.lifetime),
    }
}

fn constraintsManagerDestroy(res: *server.zwp.PointerConstraintsV1, self: *PointerConstraints) void {
    // The manager resource is a per-client view; the constraints it
    // created are separate objects that outlive it (wlroots
    // :311-331). Only the bookkeeping entry goes.
    const idx = std.mem.indexOfScalar(*server.zwp.PointerConstraintsV1, self.managers.items, res) orelse return;
    _ = self.managers.swapRemove(idx);
}

fn lockedRequest(res: *server.zwp.LockedPointerV1, request: server.zwp.LockedPointerV1.Request, c: *Constraint) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => res.destroy(),
        .set_cursor_position_hint => |r| c.pending_hint = .{ .x = r.surface_x, .y = r.surface_y },
        .set_region => |r| storePendingRegion(c, r.region),
    }
}

fn lockedDestroy(_: *server.zwp.LockedPointerV1, c: *Constraint) void {
    constraintDestroyed(c);
}

fn confinedRequest(res: *server.zwp.ConfinedPointerV1, request: server.zwp.ConfinedPointerV1.Request, c: *Constraint) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_region => |r| storePendingRegion(c, r.region),
    }
}

fn confinedDestroy(_: *server.zwp.ConfinedPointerV1, c: *Constraint) void {
    constraintDestroyed(c);
}

/// Destroy the constraint's wire resource; the resource's destroy handler
/// (constraintDestroyed) frees the state.
fn destroyConstraint(c: *Constraint) void {
    c.resource().destroy();
}

/// The zwp_locked_pointer_v1 / zwp_confined_pointer_v1 resource is dying:
/// detach the surface listeners, free the regions, prune the state. The
/// detach is idempotent: a surface-first death (onConstraintSurfaceDestroy)
/// already removed them, and Surface.destroy nulled `surface`.
fn constraintDestroyed(c: *Constraint) void {
    const self = c.pc;
    if (c.surface != null) {
        c.surface_listener.link.remove();
        c.commit_listener.link.remove();
        c.surface = null;
    }
    self.freeConstraintState(c);
    if (std.mem.indexOfScalar(*Constraint, self.constraints.items, c)) |idx| {
        _ = self.constraints.swapRemove(idx);
    }
    self.allocator.destroy(c);
}

/// wp_locked_pointer_v1.set_region / wp_confined_pointer_v1.set_region are
/// double-buffered: the new region lands on the surface's next commit
/// (XML:218-219, :294-299).
fn storePendingRegion(c: *Constraint, region_res: ?*server.wl.Region) void {
    const allocator = c.pc.allocator;
    const pending = c.pc.copyRegion(region_res) catch {
        c.resource().postNoMemory();
        return;
    };
    if (c.pending_client_region) |*old| old.deinit(allocator);
    c.pending_client_region = pending;
}
// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/fractional_scale.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,
    constraints_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "zwp_pointer_constraints_v1")) {
                    data.constraints_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Client-side capture of zwp_locked_pointer_v1.
const LockEvents = struct {
    locked: usize = 0,
    unlocked: usize = 0,

    fn listener(_: *client.zwp.LockedPointerV1, event: client.zwp.LockedPointerV1.Event, data: *LockEvents) void {
        switch (event) {
            .locked => data.locked += 1,
            .unlocked => data.unlocked += 1,
        }
    }
};

/// Client-side capture of zwp_confined_pointer_v1.
const ConfineEvents = struct {
    confined: usize = 0,
    unconfined: usize = 0,

    fn listener(_: *client.zwp.ConfinedPointerV1, event: client.zwp.ConfinedPointerV1.Event, data: *ConfineEvents) void {
        switch (event) {
            .confined => data.confined += 1,
            .unconfined => data.unconfined += 1,
        }
    }
};

/// The seat's hit-test stub.
const PickState = struct {
    surface: ?*surface_mod.Surface = null,
};

fn testPick(ctx: *anyopaque, x: i32, y: i32) ?seat_mod.Seat.PickResult {
    const st: *PickState = @ptrCast(@alignCast(ctx));
    if (st.surface) |s| return .{ .surface = s, .sx = x, .sy = y };
    return null;
}

/// One connected client. The registry listener target lives here (not in a
/// stack frame): libwayland keeps the listener data pointer for the life of
/// the proxy.
const Peer = struct {
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_seat: ?*client.wl.Seat = null,
    wl_pointer: ?*client.wl.Pointer = null,
    wl_constraints: ?*client.zwp.PointerConstraintsV1 = null,
    capture: RegistryCapture = .{},
    registry: ?*client.wl.Registry = null,
    surface: ?*client.wl.Surface = null,
    compositor_surface: ?*surface_mod.Surface = null,

    fn connect(p: *Peer, server_wire: *wire.Server) !void {
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        p.client = wire.Client.create(server_wire, fds[0]) orelse return error.ClientCreateFailed;
        p.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;
        p.registry = try p.c_display.?.getRegistry();
        p.registry.?.setListener(*RegistryCapture, RegistryCapture.listener, &p.capture);
    }
};

const TestOptions = struct {
    /// Build the module with no seat at all.
    with_seat: bool = true,
    /// Serve the seat's pointer capability. Off: get_pointer yields a DEAD
    /// wl_pointer (never in Seat.pointers), which is exactly the input that
    /// makes a constraint INERT.
    pointer_capability: bool = true,
};

/// A compositor + seat + pointer-constraints module + one in-memory client.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    pc: ?*PointerConstraints = null,
    pick_state: PickState = .{},
    a: Peer = .{},

    fn init(allocator: std.mem.Allocator, opts: TestOptions) !*TestServer {
        const ts = try allocator.create(TestServer);

        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        // deinit() frees ts itself, so it is the ONLY teardown errdefer: a
        // second allocator.destroy(ts) would double-free on the error path.
        errdefer ts.deinit();
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        // The internal wl_shm global (libwayland) must exist before the
        // client's first registry roundtrip.
        try ts.display.?.initShm();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        if (opts.with_seat) {
            ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{
                .pointer = opts.pointer_capability,
            });
            ts.seat.?.setPick(testPick, &ts.pick_state);
        }
        ts.pc = try PointerConstraints.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?, ts.seat);

        try ts.a.connect(ts.display.?.getServer());
        try ts.pump();

        if (ts.a.capture.constraints_name == null or ts.a.capture.compositor_name == null) {
            return error.GlobalMissing;
        }
        if (opts.with_seat and ts.a.capture.seat_name == null) return error.SeatMissing;

        ts.a.wl_compositor = try ts.a.registry.?.bind(ts.a.capture.compositor_name.?, client.wl.Compositor, 7);
        if (opts.with_seat) {
            ts.a.wl_seat = try ts.a.registry.?.bind(ts.a.capture.seat_name.?, client.wl.Seat, seat_mod.seat_version);
            ts.a.wl_pointer = try ts.a.wl_seat.?.getPointer();
        }
        ts.a.wl_constraints = try ts.a.registry.?.bind(
            ts.a.capture.constraints_name.?,
            client.zwp.PointerConstraintsV1,
            1,
        );
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // The client goes first: its resource destroy handlers must run
        // while the module lives.
        if (ts.a.c_display) |d| d.disconnect();
        if (ts.a.client) |c| c.destroy();
        if (ts.pc) |p| p.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// `test_pump.dispatchOnce` (client flush -> server dispatch), then the
    /// seat batch close, then the server flush — so the wl_pointer.frame the
    /// close queues still reaches the client in this roundtrip, as it did
    /// before the shared helper existed. Then a client dispatch.
    fn pump(ts: *TestServer) !void {
        try test_pump.dispatchOnce(ts.a.c_display, ts.display.?, 0);
        if (ts.seat) |s| s.pointerFrame();
        test_pump.flushServers(ts.display.?);
        if (ts.a.c_display) |d| {
            var fds = [_]posix.pollfd{.{ .fd = d.getFd(), .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&fds, 0) > 0) {
                if (d.dispatch() != .SUCCESS) {
                    // Protocol error or disconnect: the server already
                    // destroyed this client — forget it for deinit.
                    ts.a.client = null;
                    return error.ClientDispatchFailed;
                }
            }
        }
    }

    /// Create a wl_surface for the client on the wire and in the
    /// compositor, and return the compositor's Surface.
    fn createSurface(ts: *TestServer) !*surface_mod.Surface {
        const p = &ts.a;
        p.surface = try p.wl_compositor.?.createSurface();
        try ts.pump();
        const c = ts.compositor.?;
        p.compositor_surface = c.surfaces.items[c.surfaces.items.len - 1];
        return p.compositor_surface.?;
    }

    /// Point the pick stub at `surface` and move the pointer there.
    fn focus(ts: *TestServer, surface: *surface_mod.Surface, x: i32, y: i32) !void {
        ts.pick_state.surface = surface;
        ts.seat.?.pointerMotion(x, y);
        try ts.pump();
    }

    /// Point the pick stub at nothing (the pointer leaves every surface).
    fn unfocus(ts: *TestServer) !void {
        ts.pick_state.surface = null;
        ts.seat.?.pointerMotion(4000, 4000);
        try ts.pump();
    }
};

/// Every seat-backed test needs a real Seat, which needs xkbcommon and a
/// keymap; the seat's own tests skip with the same diagnostic when the
/// keymap source is unavailable.
fn testServer(allocator: std.mem.Allocator) !*TestServer {
    return TestServer.init(allocator, .{}) catch |err| {
        std.debug.print("pointer_constraints test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return err;
    };
}

test "pointer constraints init and teardown with no seat and no client" {
    const allocator = std.testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const display = try display_mod.CompositorDisplay.init(allocator, io, &log_cfg);
    defer display.deinit();
    const compositor = try compositor_mod.Compositor.init(allocator, io, &log_cfg, display);
    defer compositor.deinit();

    // No seat, no client: the global still registers and teardown is clean.
    const pc = try PointerConstraints.init(allocator, io, &log_cfg, display, compositor, null);
    try std.testing.expectEqual(@as(usize, 0), pc.constraints.items.len);
    try std.testing.expectEqual(@as(usize, 0), pc.activeCount());
    try std.testing.expect(pc.cursorPosition(@ptrFromInt(0x100), 5, 6).x == 5);
    try std.testing.expect(pc.confine(@ptrFromInt(0x100), 5, 6) == null);
    pc.deinit();
}

test "a client binds the manager with no seat behind it" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, .{ .with_seat = false });
    defer ts.deinit();

    try std.testing.expectEqual(@as(usize, 1), ts.pc.?.managers.items.len);
    ts.a.wl_constraints.?.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.managers.items.len);
}

test "lock lifecycle: locked, cursor pinned, unlocked when focus is lost" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const locked = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    var ev: LockEvents = .{};
    locked.setListener(*LockEvents, LockEvents.listener, &ev);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.pc.?.constraints.items.len);

    // No motion yet, so no activation: the lock waits for the pointer.
    try std.testing.expectEqual(@as(usize, 0), ev.locked);
    try ts.focus(surface, 120, 80);
    try std.testing.expectEqual(@as(usize, 1), ev.locked);
    try std.testing.expectEqual(@as(usize, 1), ts.pc.?.activeCount());

    // The activation minted a seat serial, so it lands in the client's
    // serial ring exactly like wlroots' wlr_seat_client_next_serial.
    const c = ts.pc.?.constraints.items[0];
    try std.testing.expect(ts.seat.?.validateEventSerial(ts.a.client.?, c.activationSerial()));

    // The cursor is pinned where the lock activated, even though the live
    // pointer keeps moving.
    const pinned = ts.pc.?.cursorPosition(surface, 900, 900);
    try std.testing.expect(pinned.locked);
    try std.testing.expectEqual(@as(i32, 120), pinned.x);
    try std.testing.expectEqual(@as(i32, 80), pinned.y);
    ts.seat.?.pointerMotion(900, 900);
    try ts.pump();
    const still = ts.pc.?.cursorPosition(surface, 900, 900);
    try std.testing.expectEqual(@as(i32, 120), still.x);
    try std.testing.expectEqual(@as(i32, 80), still.y);

    // Losing pointer focus deactivates: a PERSISTENT constraint survives.
    try ts.unfocus();
    try std.testing.expectEqual(@as(usize, 1), ev.unlocked);
    try std.testing.expectEqual(@as(usize, 1), ts.pc.?.constraints.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.activeCount());
    const free = ts.pc.?.cursorPosition(surface, 900, 900);
    try std.testing.expect(!free.locked);
    try std.testing.expectEqual(@as(i32, 900), free.x);

    // Re-focusing reactivates the same persistent object.
    try ts.focus(surface, 30, 40);
    try std.testing.expectEqual(@as(usize, 2), ev.locked);
}

test "confine lifecycle with a region and exact geometry clamping" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const region = try ts.a.wl_compositor.?.createRegion();
    region.add(0, 0, 100, 100);
    const confined = try ts.a.wl_constraints.?.confinePointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        region,
        .persistent,
    );
    var ev: ConfineEvents = .{};
    confined.setListener(*ConfineEvents, ConfineEvents.listener, &ev);
    try ts.pump();

    // The pointer is outside the region, so the constraint cannot activate
    // (the XML guarantees the pointer is inside at activation,
    // XML:166-170).
    try ts.focus(surface, 500, 500);
    try std.testing.expectEqual(@as(usize, 0), ev.confined);

    ts.seat.?.pointerMotion(10, 10);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.confined);

    // The confinement geometry: an inside point is unchanged, an outside
    // point is clamped to the NEAREST INSIDE one. The effective region is
    // the client's (0, 0, 100, 100), so its last inside coordinate is 99,
    // not 150: a clamp that landed outside the region would confine
    // nothing.
    const pc = ts.pc.?;
    try std.testing.expectEqual(@as(i32, 10), pc.confine(surface, 10, 10).?.x);
    try std.testing.expectEqual(@as(i32, 99), pc.confine(surface, 150, 50).?.x);
    try std.testing.expectEqual(@as(i32, 50), pc.confine(surface, 150, 50).?.y);
    try std.testing.expectEqual(@as(i32, 0), pc.confine(surface, -40, -40).?.x);
    try std.testing.expectEqual(@as(i32, 0), pc.confine(surface, -40, -40).?.y);
    // Losing focus deactivates, so confine() has nothing to clamp to.
    try ts.unfocus();
}

test "a lock with no region constrains the whole surface" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const locked = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    var ev: LockEvents = .{};
    locked.setListener(*LockEvents, LockEvents.listener, &ev);
    try ts.pump();

    const c = ts.pc.?.constraints.items[0];
    try std.testing.expect(c.isUnbounded());
    try std.testing.expect(c.contains(-5000, 9000));
    try std.testing.expectEqual(@as(usize, 0), c.effectiveRegion().len);

    try ts.focus(surface, 700, 700);
    try std.testing.expectEqual(@as(usize, 1), ev.locked);
}

test "already_constrained is posted on the manager and kills the client" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.createSurface();
    _ = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.pc.?.constraints.items.len);

    // A second constraint on the SAME surface with a wl_pointer of the same
    // wl_seat is the illegal request the XML names
    // (pointer-constraints-unstable-v1.xml:66-73, :61-65).
    _ = try ts.a.wl_constraints.?.confinePointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    // The error is posted ON THE MANAGER resource, never on the new
    // constraint object (wlroots wlr_pointer_constraints_v1.c:233-241).
    var err_id: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.a.c_display.?, null, &err_id));
    try std.testing.expectEqual(ts.a.wl_constraints.?.getId(), err_id);

    // The rejected constraint never became state — and the FIRST one did
    // not survive either: a fatal protocol error kills the client, and
    // libwayland destroys every resource that client owned
    // (wl_client_destroy), so its constraint went with the connection.
    // That is what "kills the client" in this test's name means.
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.constraints.items.len);
}

test "a oneshot constraint is destroyed on deactivation" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const confined = try ts.a.wl_constraints.?.confinePointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .oneshot,
    );
    var ev: ConfineEvents = .{};
    confined.setListener(*ConfineEvents, ConfineEvents.listener, &ev);
    try ts.pump();

    try ts.focus(surface, 10, 10);
    try std.testing.expectEqual(@as(usize, 1), ev.confined);
    try std.testing.expectEqual(@as(usize, 1), ts.pc.?.constraints.items.len);

    // Losing focus deactivates AND destroys the defunct oneshot object
    // (XML:255-259; wlroots send_deactivated, :408-411).
    try ts.unfocus();
    try std.testing.expectEqual(@as(usize, 1), ev.unconfined);
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.constraints.items.len);
}

test "destroying the constrained surface while active sends unlocked" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const locked = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    var ev: LockEvents = .{};
    locked.setListener(*LockEvents, LockEvents.listener, &ev);
    try ts.pump();
    try ts.focus(surface, 200, 300);
    try std.testing.expectEqual(@as(usize, 1), ev.locked);

    // The surface dies under an active lock: the client is told, and the
    // defunct object goes with it (XML:184-190; wlroots
    // handle_surface_destroy, :130-134).
    ts.a.surface.?.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.unlocked);
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.constraints.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.activeCount());
}

test "destroying the constraint object while active releases it" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const locked = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    var ev: LockEvents = .{};
    locked.setListener(*LockEvents, LockEvents.listener, &ev);
    try ts.pump();
    try ts.focus(surface, 200, 300);
    try std.testing.expectEqual(@as(usize, 1), ev.locked);

    // To unconfine / unlock, the client sends destroy (XML:211-213); the
    // compositor stops enforcing immediately. No event can follow a
    // destroyed resource, so none is sent.
    locked.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.unlocked);
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.constraints.items.len);
    const free = ts.pc.?.cursorPosition(surface, 800, 800);
    try std.testing.expect(!free.locked);
    // The surface listeners went with the constraint: later commits and a
    // later surface destroy must not touch freed memory.
    ts.a.surface.?.commit();
    try ts.pump();
    ts.a.surface.?.destroy();
    try ts.pump();
}

test "set_region is double-buffered and lands on the next commit" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const small = try ts.a.wl_compositor.?.createRegion();
    small.add(0, 0, 50, 50);
    const confined = try ts.a.wl_constraints.?.confinePointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        small,
        .persistent,
    );
    var ev: ConfineEvents = .{};
    confined.setListener(*ConfineEvents, ConfineEvents.listener, &ev);
    try ts.pump();

    // The pointer is outside the 50x50 region: no activation.
    try ts.focus(surface, 300, 300);
    ts.seat.?.pointerMotion(400, 400);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.confined);

    // A bigger region is requested but NOT applied: set_region is
    // double-buffered (XML:166-170, :294-299).
    const big = try ts.a.wl_compositor.?.createRegion();
    big.add(0, 0, 1000, 1000);
    confined.setRegion(big);
    try ts.pump();
    ts.seat.?.pointerMotion(500, 500);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.confined);

    // The commit applies it (wlroots wlr_surface_synced, :177-183).
    ts.a.surface.?.commit();
    try ts.pump();
    ts.seat.?.pointerMotion(600, 600);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.confined);
}

test "set_cursor_position_hint is double-buffered with exact 24.8 encoding" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    // The surface must exist, or lock_pointer leaves the object inert and
    // constraints.items[0] below would not exist. The hint lands on the
    // constraint, not the surface, so the handle itself is unused.
    _ = try ts.createSurface();
    const locked = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    try ts.pump();

    // 3.5 and 4.25 are exact in 24.8: 896 and 1088.
    locked.setCursorPositionHint(Fixed.fromDouble(3.5), Fixed.fromDouble(4.25));
    try ts.pump();
    try std.testing.expect(ts.pc.?.constraints.items[0].hint == null);

    ts.a.surface.?.commit();
    try ts.pump();
    const hint = ts.pc.?.constraints.items[0].hint.?;
    try std.testing.expectEqual(@as(i32, 896), @as(i32, @intFromEnum(hint.x)));
    try std.testing.expectEqual(@as(i32, 1088), @as(i32, @intFromEnum(hint.y)));
}

test "a compositor grab blocks activation" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    // Focus FIRST, so pointer focus is the one precondition the constraint
    // already satisfies and the GRAB is the only one left to block.
    // (Focusing is itself a pointer motion, so a constraint created before
    // it would activate right there — the documented policy the lock
    // lifecycle test asserts.)
    try ts.focus(surface, 40, 40);

    _ = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    try ts.pump();
    // No motion since the constraint exists, so it has not activated yet.
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.activeCount());

    // main.zig's camera pan / interactive move owns the pointer: the
    // compositor must not constrain it (seat.zig:482-489).
    ts.seat.?.startPointerGrab(&seat_mod.swallow_pointer_grab);
    ts.seat.?.pointerMotion(50, 50);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.activeCount());

    // Once the grab ends the constraint activates on the next motion.
    ts.seat.?.endPointerGrab();
    ts.seat.?.pointerMotion(60, 60);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.pc.?.activeCount());
}

test "a wl_pointer that is not a live seat pointer leaves the object inert" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, .{ .pointer_capability = false });
    defer ts.deinit();

    _ = try ts.createSurface();
    // The seat's pointer capability is off, so get_pointer yielded a dead
    // wl_pointer that never entered Seat.pointers (seat.zig:1778) — the
    // exact input that leaves a constraint inert (wlroots
    // wlr_pointer_constraints_v1.c:226-229).
    const locked = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    var ev: LockEvents = .{};
    locked.setListener(*LockEvents, LockEvents.listener, &ev);
    try ts.pump();

    // No Constraint state exists and no event is ever sent.
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.constraints.items.len);
    ts.pick_state.surface = ts.a.compositor_surface.?;
    ts.seat.?.pointerMotion(100, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.locked);
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.activeCount());

    // The inert object still accepts destroy.
    locked.destroy();
    try ts.pump();
}

test "setSeat(null) releases every constraint with unlocked" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const locked = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    var ev: LockEvents = .{};
    locked.setListener(*LockEvents, LockEvents.listener, &ev);
    try ts.pump();
    try ts.focus(surface, 100, 100);
    try std.testing.expectEqual(@as(usize, 1), ev.locked);

    ts.pc.?.setSeat(null);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.unlocked);
    try std.testing.expectEqual(@as(usize, 0), ts.pc.?.constraints.items.len);

    // Motion and surface lifetime changes no longer reach the module.
    ts.seat.?.pointerMotion(700, 700);
    ts.a.surface.?.commit();
    ts.a.surface.?.destroy();
    try ts.pump();
}

test "module teardown releases every constraint with unlocked" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface = try ts.createSurface();
    const locked = try ts.a.wl_constraints.?.lockPointer(
        ts.a.surface.?,
        ts.a.wl_pointer.?,
        null,
        .persistent,
    );
    var lock_ev: LockEvents = .{};
    locked.setListener(*LockEvents, LockEvents.listener, &lock_ev);
    try ts.pump();
    try ts.focus(surface, 100, 100);
    try std.testing.expectEqual(@as(usize, 1), lock_ev.locked);

    // deinit unregisters the global and releases every constraint, sending
    // unlocked for the active ones first.
    ts.pc.?.deinit();
    ts.pc = null;
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), lock_ev.unlocked);

    ts.seat.?.pointerMotion(700, 700);
    try ts.pump();
}
