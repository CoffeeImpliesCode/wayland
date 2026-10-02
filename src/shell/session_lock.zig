//! ext_session_lock_manager_v1 (staging/ext-session-lock, v1): privileged
//! session locking. A lock client renders its own lock screen and the
//! compositor withdraws everything else.
//!
//! This is a PRIVILEGE BOUNDARY, not a formatting feature. XML
//! ext_session_lock_v1:74-91: once `locked` is sent the compositor "must
//! stop rendering and providing input to normal clients. Instead the
//! compositor must blank all outputs with an opaque color such that their
//! normal content is fully hidden", and "the only surfaces that should be
//! rendered while the session is locked are the lock surfaces created
//! through this interface and optionally, at the compositor's discretion,
//! special privileged surfaces such as input methods" — an output with no
//! (or a too small) lock surface must be filled with an opaque color, never
//! left showing user content (ext_session_lock_surface_v1:277-280:
//! destroying the lock surface of an active output makes the compositor
//! "fall back to rendering a solid color").
//!
//! Objects and the wire argument order (read from the XML, not guessed):
//! - ext_session_lock_manager_v1.lock takes ONLY the new
//!   ext_session_lock_v1 id (XML:61-69). No wl_surface, no wl_output.
//! - The lock surface is created by the LOCK object, not the manager:
//!   ext_session_lock_v1.get_lock_surface(new_id
//!   ext_session_lock_surface_v1, object wl_surface, object wl_output)
//!   (XML:192-209). The order id/surface/output is fixed by the generated
//!   request union; the role goes on the wl_surface, the output decides
//!   which output the lock surface covers (and may appear at most once,
//!   `duplicate_output`).
//!
//! State machine (wlroots 0.20 ext session-lock, types/wlr_session_lock_v1.c:
//! lock_manager_handle_lock :400-428, lock_handle_get_lock_surface :277-316,
//! lock_surface_handle_ack_configure :107-152,
//! lock_surface_role_client_commit :154-181, lock_handle_destroy :347-361,
//! lock_handle_unlock_and_destroy :318-345):
//! - `lock` creates an ext_session_lock_v1. The compositor sends `locked`
//!   or `finished` on it. At most one lock object exists: a `lock` while one
//!   is held is denied with an immediate `finished` on the new object
//!   (XML:170-174 — "This might be sent because there is already another
//!   ext_session_lock_v1 object held by a client"; sway's handle_new_lock).
//! - `get_lock_surface` assigns the "ext_session_lock_surface_v1" role and
//!   the compositor sends the FIRST configure immediately on binding
//!   (XML:245-248). Preconditions, all posted on the ext_session_lock_v1
//!   resource (the XML's home for them): a second lock surface for the same
//!   output is `duplicate_output`, a wl_surface with a role is `role`, a
//!   wl_surface with a buffer attached or committed is
//!   `already_constructed`. The lock-surface wire resource is created first
//!   and left inert when the lock or the output is unknown, so a client
//!   that raced the denial stays in sync (wlroots :279-296).
//! - `ack_configure` consumes the named configure and every older one
//!   (XML:302-304); an unknown/consumed serial is `invalid_serial`. The
//!   client may ack several times; only the last one before the commit
//!   counts, which is why the acked size is stored as one value.
//! - Commit checks on the lock surface, in wlroots order: a commit with no
//!   buffer is `null_buffer`, a commit before the first ack is
//!   `commit_before_first_ack`, and a commit whose size differs from the
//!   acked configure is `dimensions_mismatch` (wlroots :154-181). The first
//!   commit that satisfies all of them is the locked frame.
//! - `locked` is sent by THIS module at that commit (wlroots delegates it
//!   to the compositor through wlr_session_lock_v1_send_locked :363-367;
//!   sway calls it once the lock surfaces carry buffers).
//! - `unlock_and_destroy` before `locked` is `invalid_unlock`; `destroy`
//!   while locked is `invalid_destroy` (XML:137-149, 225-227). A plain
//!   `destroy` before `locked` is also refused (wlroots :347-361 refuses
//!   both branches of that request), so the client can only ever end a
//!   pending attempt by committing a lock surface or letting the object
//!   die.
//!
//! Latch discipline (the property this module exists to guarantee):
//! `locked` is a latch, never a derived value. It is set the instant the
//! locked frame is committed and cleared only by `unlock_and_destroy` or
//! the compositor recovery hook. Destroying a lock surface, destroying the
//! lock object, or the lock CLIENT dying never clears it (XML:111-115:
//! "If the client dies while the session is locked, the compositor must
//! not unlock the session in response"). A lock surface that stops
//! covering its output therefore makes `outputIsBlank` fall back to a
//! solid color — it never reports itself unlocked.
//!
//! WIRING CONTRACT — what the server (src/server/main.zig) must gate, and
//! in which order. This module cannot touch seat.zig, surface.zig or the
//! server, so it only holds the state and refuses to lie about it; the
//! following gates are NOT implemented here and must be wired by the
//! integration:
//!
//! 1. Order of events. Every input flip and every render decision reads
//!    `isLocked()`, which is only ever written from a client-request
//!    dispatch (the lock surface's commit) or from `unlock_and_destroy`.
//!    Both happen inside `display.dispatch`, i.e. before `renderFrame`
//!    runs, so the first frame composited after the latch is already a
//!    locked frame. The server must keep that property: it may not
//!    composite a frame it built before the latch, and it may not cache
//!    "was I unlocked" across a dispatch.
//!
//! 2. Input suppression (the security half). While `isLocked()`, no
//!    wl_keyboard/wl_pointer/wl_touch event may reach any client except the
//!    lock-surface client (XML:81-84 and 252-256). The seat already
//!    delivers keys only to `keyboard_focus`'s client (seat.zig:1339-1346)
//!    and pointer only to `pointer_focus`'s client (seat.zig:908-917,
//!    1015-1023), so the gate is compositor policy the server already owns:
//!    - On the `locked` signal: end every compositor grab
//!      (`seat.endPointerGrab()`, `seat.endKeyboardGrab()` — a grab routes
//!      input to a non-lock client, seat.zig:1013/1337), hide the cursor
//!      node, and make `pickSurface` (installed via `seat.setPick`) return
//!      a surface only when `isLockSurface(surface)`, else null so the
//!      pointer leaves and no client sees motion or buttons.
//!    - Force keyboard focus onto a lock surface
//!      (`seat.setKeyboardFocus(ls.surface)` for the first lock surface,
//!      re-asserted on every focus change); the XML explicitly leaves focus
//!      handling for lock surfaces to the compositor (ext_session_lock_
//!      surface_v1:252-256) and this is the recommended policy.
//!    - Install a lock-aware click-to-focus gate via
//!      `seat.setKeyboardFocusGate`: while locked it accepts only lock
//!      surfaces, so a click cannot move focus to user content.
//!    - `acceptsInput(client)` is the assertion: it must be false for every
//!      client that is not the lock client (`locked` && no live lock
//!      object => false for everyone).
//!    - wl_touch has no implementation in this seat (seat.zig:1494 — the
//!      capability is never advertised), so the XML's touch clause is
//!      vacuously satisfied; a future touch path must read the same flag.
//!    - On the `unlocked` signal: drop the gates above and re-run the
//!      normal focus policy (keyboard focus is null at that point).
//!
//! 3. Render suppression (the other security half). While `isLocked()`,
//!    in `renderFrame`:
//!    - Fill the whole output rect with an opaque color BEFORE drawing any
//!      node, then draw only surfaces with `isLockSurface(node.surface)`
//!      true. Never draw cursor, normal surfaces, drag icons or popups.
//!    - For each output, `outputIsBlank(out)` decides whether the blank
//!      stays: an output whose lock surface is missing, unmapped or
//!      smaller than the output keeps the solid color. Composited lock
//!      content must never be stretched to cover a gap.
//!    - Normal-surface protocol events (wl_surface.enter/leave, frame
//!      callbacks, presentation feedback) are NOT user input and may keep
//!      flowing; they leak no pixels.
//!
//! 4. Lock-surface bookkeeping. `new_lock_surface` gives the server the
//!    surface to position over its output in the scene (a lock surface is an
//!    ordinary wl_surface, so `syncSurfaces` also tracks it); the server
//!    keeps its own `*LockSurface` copy and prunes it on
//!    `lock_surface_gone`, which fires when the lock surface object dies,
//!    when its wl_surface dies, when its output dies and at unlock — the
//!    scene node must go with it, or an unlocked session would composite
//!    the stale lock screen as ordinary content.
//!    Every one of those paths may fire first and more than one may be live,
//!    so the module frees the lock-surface state exactly once (`released`)
//!    and `lock_surface_gone` fires exactly once per lock surface.
//!
//! 5. Compositor policy hooks: `deny(lock)` sends `finished` (e.g. a
//!    compositor that refuses to lock without a seat), `forceUnlock()` is
//!    the out-of-band recovery path (XML:117-121) for a session whose lock
//!    client died. Both are no-ops unless the state says they apply.
//!
//! Documented divergences from wlroots 0.20 (types/wlr_session_lock_v1.c):
//! - `locked` is sent by this module at the first qualifying lock-surface
//!   commit instead of by the compositor's call to
//!   wlr_session_lock_v1_send_locked. It cannot wait for a presented frame:
//!   Output.events.presented only fires on backends with a real display,
//!   and no presentation hook exists for headless/raylib. The security
//!   property still holds (the latch flips in the same dispatch as the
//!   commit, before any locked frame is composited); the residual race is
//!   the XML's "client suspends on `locked` while the frame has not been
//!   scanned out" window, which a wiring slice with a presentation hook
//!   should close by moving the `locked` event behind it.
//! - No waiting timeout. wlroots has none either (the compositor decides);
//!   here a client that never commits a lock surface simply holds a pending
//!   lock that never latches — the session stays unlocked and fully
//!   interactive, so nothing is denied or blanked by waiting.
//! - A wl_surface that already carries ANY role (including another lock
//!   surface of the same lock) is refused with `role`; wlroots'
//!   wlr_surface_set_role tolerates the same-role case, which would leave
//!   one wl_surface driving two lock surfaces. The XML says a wl_surface
//!   with a role is a protocol error, so this is strictly conforming.

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const geom = @import("../utils/geom.zig");
const role_mod = @import("../compositor/role.zig");
const surface_mod = @import("../compositor/surface.zig");
const display_mod = @import("../core/display.zig");
const output_mod = @import("../output/output.zig");
const wl_output_mod = @import("../output/wl_output.zig");

const log_tag = "session_lock";

const Surface = surface_mod.Surface;

/// One sent configure: the serial plus the exact size it required (the
/// next commit after acking must match, XML:314-325).
pub const Configure = struct {
    serial: u32,
    width: u32,
    height: u32,
};

pub const SessionLock = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The ext_session_lock_manager_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// The live lock object, pending or locked. At most one exists (a
    /// second `lock` is denied with `finished`). Null while no lock object
    /// exists — including while the session is locked after the lock client
    /// died: `locked` outlives the object.
    active: ?*Lock = null,
    /// The privilege boundary: true from the moment `locked` is sent until
    /// `unlock_and_destroy` (or the compositor recovery hook). Never
    /// cleared by a lock surface, the lock object or the lock client
    /// dying (XML:111-115).
    locked: bool = false,
    events: struct {
        /// `locked` was sent: the session is locked. The listener runs
        /// BEFORE the server may composite a frame with the lock, i.e.
        /// within the same dispatch as the lock surface's commit.
        locked: wire.Signal(*SessionLock),
        /// The session was unlocked (`unlock_and_destroy`, or
        /// forceUnlock). The server drops its input gates and resumes
        /// normal rendering here.
        unlocked: wire.Signal(*SessionLock),
        /// A lock surface was created (fully configured, role assigned,
        /// first configure sent). The server positions its surface over
        /// the output.
        new_lock_surface: wire.Signal(*LockSurface),
        /// A lock surface stopped covering its output: its object, its
        /// wl_surface or its output died, or the lock ended. The server
        /// removes its scene node; `outputIsBlank` now reports true for
        /// that output.
        lock_surface_gone: wire.Signal(*LockSurface),
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) !*SessionLock {
        const sl = try allocator.create(SessionLock);
        errdefer allocator.destroy(sl);
        sl.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        sl.events.locked.init();
        sl.events.unlocked.init();
        sl.events.new_lock_surface.init();
        sl.events.lock_surface_gone.init();

        // Register ext_session_lock_manager_v1 at the maximum version we
        // implement (the protocol is v1 only).
        sl.global = try display.addGlobal(
            server.ext.SessionLockManagerV1,
            *SessionLock,
            sessionLockBind,
            server.ext.SessionLockManagerV1.generated_version,
            sl,
        );
        log.debug("session lock manager created", io, log_cfg, log_tag, .{});
        return sl;
    }

    pub fn deinit(self: *SessionLock) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the wire resource cascades through lockDestroy, which
        // frees the lock surfaces (emitting lock_surface_gone) and the lock.
        // The client's own lock-surface resources are only made inert, as
        // they belong to the client (wlroots lock_surface_destroy).
        if (self.active) |lock| lock.resource.destroy();
        allocator.destroy(self);
    }

    /// Whether the session is locked. THE read: every input dispatch and
    /// every render decision gates on this (see the wiring contract above).
    pub fn isLocked(self: *const SessionLock) bool {
        return self.locked;
    }

    /// Whether user input may be delivered to `wl_client` right now. False
    /// for every client except the one holding the live lock while the
    /// session is locked; also false for everyone while the session is
    /// locked and the lock client is gone (the "permanently locked" state,
    /// XML:111-115).
    pub fn acceptsInput(self: *const SessionLock, wl_client: *wire.Client) bool {
        if (!self.locked) return true;
        const lock = self.active orelse return false;
        return lock.resource.getClient() == wl_client;
    }

    /// Whether `surface` is a lock surface of the live lock: the server
    /// must render these (and nothing else) while the session is locked.
    pub fn isLockSurface(self: *const SessionLock, surface: *const Surface) bool {
        return self.lockSurfaceFromSurface(surface) != null;
    }

    /// Every lock surface of the live lock, in creation order. Empty when
    /// there is no lock object.
    pub fn lockSurfaces(self: *const SessionLock) []const *LockSurface {
        const lock = self.active orelse return &[_]*LockSurface{};
        return lock.surfaces.items;
    }

    /// The lock surface covering `output`, or null when there is none.
    pub fn lockSurfaceForOutput(self: *const SessionLock, output: *output_mod.Output) ?*LockSurface {
        for (self.lockSurfaces()) |ls| {
            if (ls.output == output) return ls;
        }
        return null;
    }

    /// Whether the server must fill `output` with the opaque blank color
    /// instead of compositing lock content: true when the session is locked
    /// and the output has no lock surface, an unmapped one, or one smaller
    /// than the output (XML:277-280 — a lock surface destroyed before
    /// unlock means "fall back to rendering a solid color"; and the locked
    /// description requires the output's normal content to be fully hidden
    /// where the lock surface does not cover it). False when the session is
    /// unlocked: normal content is correct then.
    pub fn outputIsBlank(self: *const SessionLock, output: *output_mod.Output) bool {
        if (!self.locked) return false;
        const ls = self.lockSurfaceForOutput(output) orelse return true;
        if (!ls.surface.isEffectivelyMapped()) return true;
        // The acked size is the size the lock surface committed (the commit
        // checks reject any other), so a smaller pair means uncovered area.
        const w: i32 = @intCast(ls.acked_width);
        const h: i32 = @intCast(ls.acked_height);
        return w < output.width or h < output.height;
    }

    /// Deny the lock: send `finished` on it and destroy the object
    /// (wlroots wlr_session_lock_v1_destroy :381-385, sway's
    /// handle_new_lock for a lock it will not take). A locked lock is not
    /// denied — the session stays locked; only a pending lock can be.
    pub fn deny(self: *SessionLock, lock: *Lock) void {
        if (lock.locked_sent or lock.finished_sent) return;
        self.finish(lock);
    }

    /// Compositor recovery (XML:117-121, "Compositors may also allow a
    /// secure way to recover the session"): clear the latch for a session
    /// whose lock client died while locked. No wire event is sent (the lock
    /// resource is gone with the client). Only the caller that owns the
    /// authenticated recovery path may call this; the module never does.
    pub fn forceUnlock(self: *SessionLock) void {
        if (!self.locked) return;
        log.warn("session lock: forcing unlock (recovery path)", self.io, self.log_cfg, log_tag, .{});
        self.sessionUnlocked();
    }

    /// The live lock object (pending or locked), or null. The compositor
    /// policy hooks take it: `deny(lock)` refuses a pending lock.
    pub fn activeLock(self: *const SessionLock) ?*Lock {
        return self.active;
    }

    // -- internals ---------------------------------------------------------

    /// The LockSurface whose wl_surface is `surface`, if any. Scans the
    /// live lock's surfaces rather than following surface.role_resource:
    /// the role resource is the lock surface's wire object, and the scan
    /// cannot be fooled into resolving to a different lock surface.
    fn lockSurfaceFromSurface(self: *const SessionLock, surface: *const Surface) ?*LockSurface {
        const lock = self.active orelse return null;
        for (lock.surfaces.items) |ls| {
            if (ls.surface == surface) return ls;
        }
        return null;
    }

    /// ext_session_lock_manager_v1.lock: create the lock object. A second
    /// lock while one is held is denied with `finished` on the new object
    /// (XML:170-174); the object stays alive and inert until the client
    /// destroys it (wlroots makes the request handler a NULL user data
    /// no-op, :343-346 and :404-428).
    fn createLock(self: *SessionLock, manager_res: *server.ext.SessionLockManagerV1, id: u32) void {
        const res = server.ext.SessionLockV1.create(manager_res.getClient(), manager_res.getVersion(), id) catch {
            manager_res.postNoMemory();
            return;
        };
        if (self.active != null) {
            // Inert with a live no-op handler: the struct is never created,
            // so no request may dereference anything, while the client's
            // own destroy must still free the wire resource.
            res.setHandler(?*Lock, deadLockHandler, null, null);
            res.sendFinished();
            log.info("session lock denied: another lock is held, finished sent", self.io, self.log_cfg, log_tag, .{});
            return;
        }
        const lock = self.allocator.create(Lock) catch {
            res.postNoMemory();
            return;
        };
        lock.* = .{
            .session_lock = self,
            .resource = res,
            .surfaces = .empty,
        };
        res.setHandler(*Lock, lockRequest, lockDestroy, lock);
        self.active = lock;
        log.info("ext_session_lock_v1 created (locked={})", self.io, self.log_cfg, log_tag, .{self.locked});
    }

    /// The locked frame is committed: latch the session, tell the client,
    /// then let the server react. The latch is written BEFORE the wire
    /// event and before the signal, so no input dispatch or render pass
    /// that runs in this dispatch can observe the session as unlocked.
    fn sendLocked(self: *SessionLock, lock: *Lock) void {
        if (lock.locked_sent or lock.finished_sent) return;
        lock.locked_sent = true;
        self.locked = true;
        lock.resource.sendLocked();
        self.events.locked.emit(self);
        log.info("session locked: input suppressed for all clients but the lock client", self.io, self.log_cfg, log_tag, .{});
    }

    /// Clear the latch (unlock_and_destroy / forceUnlock) and tell the
    /// server. Idempotent: a no-op when the session is not locked, so a
    /// denied lock that unlocks is harmless.
    fn sessionUnlocked(self: *SessionLock) void {
        if (!self.locked) return;
        self.locked = false;
        self.events.unlocked.emit(self);
        log.info("session unlocked", self.io, self.log_cfg, log_tag, .{});
    }

    /// Send `finished` and tear the lock down (wlroots
    /// wlr_session_lock_v1_destroy :381-385): the lock surfaces die with
    /// it and the lock object becomes an inert no-op. The client's wire
    /// resources survive until the client destroys them.
    fn finish(self: *SessionLock, lock: *Lock) void {
        if (self.active == lock) self.active = null;
        lock.finished_sent = true;
        lock.resource.sendFinished();
        self.teardownLock(lock);
        // Inert before the struct is freed, so a late request cannot touch
        // it; the destroy callback is cleared with it (the lock surfaces
        // were freed above, so nothing else needs to run).
        lock.resource.setHandler(?*Lock, deadLockHandler, null, null);
        self.allocator.destroy(lock);
        log.info("session lock finished (lock surfaces released)", self.io, self.log_cfg, log_tag, .{});
    }

    /// ext_session_lock_v1.destroy. Destroying a lock the compositor has
    /// locked is the XML's protocol error (XML:146-147, 160-161 ->
    /// invalid_destroy); wlroots also refuses a destroy of a lock that was
    /// never locked (:355-360), and so does this module — the client has
    /// no legitimate way to end a pending attempt.
    fn destroyRequest(self: *SessionLock, lock: *Lock) void {
        _ = self;
        if (lock.locked_sent) {
            lock.resource.postError(.invalid_destroy, "the session lock may not be destroyed while locked");
        } else {
            lock.resource.postError(.invalid_destroy, "the session lock was never locked; it may not be destroyed");
        }
    }

    /// ext_session_lock_v1.unlock_and_destroy: unlock the session and let
    /// the lock object go. Before `locked` it is a protocol error
    /// (XML:225-227 -> invalid_unlock).
    fn unlockAndDestroy(self: *SessionLock, lock: *Lock) void {
        if (!lock.locked_sent) {
            lock.resource.postError(.invalid_unlock, "unlock_and_destroy before the locked event");
            return;
        }
        self.sessionUnlocked();
        lock.resource.destroy();
    }

    /// Free every lock surface of `lock`, releasing the outputs they cover.
    /// The client keeps its (now inert) ext_session_lock_surface_v1
    /// resources: the XML tells it to destroy them after
    /// unlock_and_destroy (XML:221-223), and wlroots does the same
    /// (lock_surface_destroy :29-47, wl_resource_set_user_data(NULL)).
    fn teardownLock(self: *SessionLock, lock: *Lock) void {
        while (lock.surfaces.items.len > 0) {
            self.destroyLockSurface(lock.surfaces.items[0], true);
        }
        lock.surfaces.deinit(self.allocator);
    }

    /// Release one lock surface: unhook the role, detach the wl_surface and
    /// output listeners, free the state and tell the server the output is no
    /// longer covered. `wire_alive` is false only when the
    /// ext_session_lock_surface_v1 resource is itself being destroyed (the
    /// client's own destroy request, or connection teardown): it is already
    /// dying, so it must not be touched and needs no no-op handler.
    ///
    /// Exactly once, whatever fired: the role destroy hook, the wl_surface
    /// destroy backstop, the output destroy, lock teardown and the client's
    /// own resource destroy are all live at the same time for one lock
    /// surface, and two of them firing for the same state would double free
    /// `sent_serials` and run the gone-signal twice (wlroots frees the role
    /// state once and NULLs the user data, :29-47; `released` is that NULL).
    fn destroyLockSurface(self: *SessionLock, ls: *LockSurface, wire_alive: bool) void {
        if (ls.released) return;
        ls.released = true;
        const allocator = self.allocator;
        const lock = ls.lock;
        if (std.mem.indexOfScalar(*LockSurface, lock.surfaces.items, ls)) |i| {
            _ = lock.surfaces.swapRemove(i);
        }
        // Detach the role: the wl_surface outlives the lock surface object
        // and must not keep calling into the freed state (wlroots releases
        // the role object with the lock surface, :29-47).
        if (ls.surface.role_resource == @as(?*wire.Resource, @ptrCast(ls.resource))) {
            ls.surface.role = null;
            ls.surface.role_resource = null;
        }
        detachListener(*Surface, &ls.surface_destroy_listener);
        detachListener(*output_mod.Output, &ls.output_destroy_listener);
        ls.sent_serials.deinit(allocator);
        if (wire_alive) {
            // Inert with a live no-op handler, and disarm the destroy
            // callback: no request may dereference the freed struct, while
            // the client's own destroy still frees the wire resource.
            ls.resource.setHandler(?*LockSurface, deadLockSurfaceHandler, null, null);
        }
        self.events.lock_surface_gone.emit(ls);
        allocator.destroy(ls);
        log.debug("session lock surface released (output now blank if locked)", self.io, self.log_cfg, log_tag, .{});
    }

    /// The ext_session_lock_v1 resource is gone: the client destroyed it,
    /// unlocked it, or the connection died. The lock surfaces die with it
    /// (XML:139-141: "Existing objects created through this interface
    /// remain valid" — the lock surfaces survive as inert wire objects).
    /// A client that dies while the session is locked does NOT unlock it.
    fn lockDestroy(res: *server.ext.SessionLockV1, lock: *Lock) void {
        _ = res;
        const sl = lock.session_lock;
        const allocator = sl.allocator;
        if (sl.active == lock) sl.active = null;
        if (lock.locked_sent) {
            log.warn(
                "lock client died while the session was locked: the session stays locked (recovery requires an explicit forceUnlock)",
                sl.io,
                sl.log_cfg,
                log_tag,
                .{},
            );
        }
        sl.teardownLock(lock);
        allocator.destroy(lock);
    }

    /// ext_session_lock_v1.get_lock_surface: create the lock surface for
    /// `output_res`. The wire resource is created first and left inert when
    /// the lock or the output is not ours, so a client that raced a denial
    /// stays in sync with the server (wlroots :279-296).
    fn getLockSurface(self: *SessionLock, lock: *Lock, id: u32, surface_res: *server.wl.Surface, output_res: *server.wl.Output) void {
        const res = server.ext.SessionLockSurfaceV1.create(lock.resource.getClient(), lock.resource.getVersion(), id) catch {
            lock.resource.postNoMemory();
            return;
        };
        res.setHandler(?*LockSurface, deadLockSurfaceHandler, null, null);

        // The wl_output must be one of ours: a foreign or dead output gets
        // an inert lock surface (no configure, no role), as in wlroots
        // (wlr_output_from_resource NULL, :290-293).
        const wl_output = resolveOutput(output_res) orelse return;
        for (lock.surfaces.items) |ls| {
            if (ls.output == wl_output.output) {
                lock.resource.postError(.duplicate_output, "session lock surface already created for the given output");
                return;
            }
        }
        // The wl_surface must be fresh, checked in wlroots' order
        // (already_constructed before role, :304-317): no buffer attached
        // or committed, and no role (XML:199-201).
        const surface: *Surface = @ptrCast(@alignCast(surface_res.getUserData() orelse return));
        if (surface.buffer != null or surface.pending.buffer != null) {
            lock.resource.postError(.already_constructed, "wl_surface already has a buffer attached or committed");
            return;
        }
        if (surface.role != null) {
            lock.resource.postError(.role, "wl_surface already has a role");
            return;
        }
        const ls = self.allocator.create(LockSurface) catch {
            lock.resource.postNoMemory();
            return;
        };
        ls.* = .{
            .session_lock = self,
            .lock = lock,
            .resource = res,
            .surface = surface,
            .output = wl_output.output,
            .sent_serials = .empty,
            .surface_destroy_listener = wire.Listener(*Surface).init(onLockSurfaceDestroy),
            .output_destroy_listener = wire.Listener(*output_mod.Output).init(onLockOutputDestroy),
        };
        lock.surfaces.append(self.allocator, ls) catch {
            self.allocator.destroy(ls);
            lock.resource.postNoMemory();
            return;
        };
        // Assigns the "ext_session_lock_surface_v1" role; the check above
        // guarantees it cannot conflict, so the error is unreachable.
        role_mod.assignRole(surface, &lock_surface_role, @as(?*wire.Resource, @ptrCast(res))) catch unreachable;
        res.setHandler(*LockSurface, lockSurfaceRequest, lockSurfaceResourceDestroy, ls);
        surface.events.destroy.add(&ls.surface_destroy_listener);
        wl_output.output.events.destroy.add(&ls.output_destroy_listener);
        // The first configure goes out immediately on binding the interface
        // (XML:245-248); its size is the output's logical size.
        const size = logicalSize(wl_output.output);
        ls.configure(@intCast(size.w), @intCast(size.h));
        self.events.new_lock_surface.emit(ls);
        log.info("session lock surface on wl_output@{d} ({d}x{d})", self.io, self.log_cfg, log_tag, .{
            output_res.getId(),
            size.w,
            size.h,
        });
    }
};

// ---------------------------------------------------------------------------
// Lock: one ext_session_lock_v1 (a lock attempt).
// ---------------------------------------------------------------------------

/// One lock attempt. Created by ext_session_lock_manager_v1.lock; it owns
/// its lock surfaces. `locked_sent` / `finished_sent` mirror wlroots'
/// wlr_session_lock_v1 (types/wlr_session_lock_v1.c:29-63): `locked` and
/// `finished` each go out at most once, and `locked` before `finished`.
/// After `finished` the wire resource is an inert no-op (wlroots NULLs the
/// user data, :383-385; here SessionLock.finish swaps in a no-op handler).
pub const Lock = struct {
    session_lock: *SessionLock,
    resource: *server.ext.SessionLockV1,
    /// The lock surfaces of this lock, in creation order (one per output
    /// at most — a second one posts duplicate_output).
    surfaces: std.ArrayList(*LockSurface) = .empty,
    /// `locked` was sent: the session is locked and may only be released by
    /// unlock_and_destroy (or the compositor recovery hook).
    locked_sent: bool = false,
    /// `finished` was sent; the object is inert.
    finished_sent: bool = false,
};

// ---------------------------------------------------------------------------
// LockSurface: one ext_session_lock_surface_v1 (one output's lock screen).
// ---------------------------------------------------------------------------

/// A lock surface: a wl_surface with the "ext_session_lock_surface_v1"
/// role that covers exactly one output. The wire resource belongs to the
/// client; this state dies with the resource, with the wl_surface, with
/// the output or with the lock, and always leaves the resource inert.
pub const LockSurface = struct {
    session_lock: *SessionLock,
    lock: *Lock,
    resource: *server.ext.SessionLockSurfaceV1,
    /// The wl_surface carrying the lock screen (the client's; the role
    /// resource is `resource`).
    surface: *Surface,
    /// The output this lock surface covers. A surface smaller than the
    /// output leaves the rest uncovered, which the server must blank
    /// (see SessionLock.outputIsBlank).
    output: *output_mod.Output,
    /// The configures sent and not yet consumed, oldest first (wlroots
    /// configure_list, :78-96). ack_configure consumes the acked serial
    /// and every older one.
    sent_serials: std.ArrayList(Configure) = .empty,
    /// The client acked at least one configure: only now may it commit a
    /// buffer (XML:249-250).
    configured: bool = false,
    /// The size of the last acked configure: the exact size the next
    /// commit must match (XML:284-310, 314-325).
    acked_width: u32 = 0,
    acked_height: u32 = 0,
    /// The wl_surface is dying: release the lock surface. A backstop for
    /// the role-destroy hook, which normally gets there first.
    surface_destroy_listener: wire.Listener(*Surface),
    /// The output is dying: the lock surface cannot cover it any more, so
    /// it goes (wlroots lock_surface_handle_output_destroy :203-209).
    output_destroy_listener: wire.Listener(*output_mod.Output),
    /// The state was released by one of the five paths that can end a
    /// lock surface (role destroy hook, wl_surface destroy backstop,
    /// output destroy, lock teardown, the client's own resource destroy).
    /// Latched first in destroyLockSurface so the state is freed exactly
    /// once and no second path can touch the freed struct.
    released: bool = false,

    /// Send a configure with the exact size the client must commit
    /// (wlroots wlr_session_lock_v1_configure :72-96). The serial is
    /// recorded before the event goes out: a configure the client could
    /// not ack would strand the lock surface. Called once at creation
    /// (XML:245-248) and again whenever the output geometry changes.
    pub fn configure(ls: *LockSurface, width: u32, height: u32) void {
        const allocator = ls.session_lock.allocator;
        const serial = ls.session_lock.display.nextSerial();
        ls.sent_serials.append(allocator, .{ .serial = serial, .width = width, .height = height }) catch {
            ls.resource.postNoMemory();
            return;
        };
        ls.resource.sendConfigure(serial, width, height);
        log.info("lock surface configure serial={d} {d}x{d}", ls.session_lock.io, ls.session_lock.log_cfg, log_tag, .{
            serial,
            width,
            height,
        });
    }

    /// ext_session_lock_surface_v1.ack_configure. The serial must name a
    /// configure that is still pending; it consumes that one and every
    /// older one (XML:302-304), so acking the same configure twice — or
    /// one older than the last acked — is a protocol error
    /// (XML:306-309 -> invalid_serial). The acked size becomes the exact
    /// requirement for the next commit (XML:284-300). Only the last ack
    /// before a commit counts, so a repeated ack just overwrites it.
    fn ackConfigure(ls: *LockSurface, serial: u32) void {
        var acked: ?Configure = null;
        for (ls.sent_serials.items) |c| {
            if (c.serial == serial) {
                acked = c;
                break;
            }
        }
        if (acked == null) {
            ls.resource.postError(.invalid_serial, "ack_configure serial matches no pending configure");
            return;
        }
        while (ls.sent_serials.items.len > 0 and ls.sent_serials.items[0].serial <= serial) {
            _ = ls.sent_serials.orderedRemove(0);
        }
        ls.acked_width = acked.?.width;
        ls.acked_height = acked.?.height;
        ls.configured = true;
        log.info("lock surface configured serial={d} {d}x{d}", ls.session_lock.io, ls.session_lock.log_cfg, log_tag, .{
            serial,
            ls.acked_width,
            ls.acked_height,
        });
    }
};

// ---------------------------------------------------------------------------
// Wire handlers.
// ---------------------------------------------------------------------------

fn sessionLockBind(client_wire: *wire.Client, sl: *SessionLock, version: u32, id: u32) void {
    const res = server.ext.SessionLockManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*SessionLock, sessionLockRequest, null, sl);
}

fn sessionLockRequest(
    res: *server.ext.SessionLockManagerV1,
    request: server.ext.SessionLockManagerV1.Request,
    sl: *SessionLock,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do. Locks made
        // through this manager stay valid (XML:53-59).
        .destroy => res.destroy(),
        .lock => |r| sl.createLock(res, r.id),
    }
}

fn lockRequest(res: *server.ext.SessionLockV1, request: server.ext.SessionLockV1.Request, lock: *Lock) void {
    _ = res;
    switch (request) {
        .destroy => lock.session_lock.destroyRequest(lock),
        .get_lock_surface => |r| lock.session_lock.getLockSurface(lock, r.id, r.surface, r.output),
        .unlock_and_destroy => lock.session_lock.unlockAndDestroy(lock),
    }
}

fn lockSurfaceRequest(
    res: *server.ext.SessionLockSurfaceV1,
    request: server.ext.SessionLockSurfaceV1.Request,
    ls: *LockSurface,
) void {
    switch (request) {
        // Destructor: destroying the wire resource runs
        // lockSurfaceResourceDestroy, which releases the compositor state —
        // the output loses its lock surface, so the server must blank it
        // unless another lock surface covers it (XML:277-280). Freeing the
        // state here instead would leave the destroy callback pointing at it.
        .destroy => res.destroy(),
        .ack_configure => |r| ls.ackConfigure(r.serial),
    }
}

/// The client destroyed its ext_session_lock_surface_v1 without the lock
/// being torn down first (or the connection is going away): release the
/// state. The resource is already dying, so it is not touched.
fn lockSurfaceResourceDestroy(res: *server.ext.SessionLockSurfaceV1, ls: *LockSurface) void {
    _ = res;
    ls.session_lock.destroyLockSurface(ls, false);
}

/// Request handler for an inert lock object: a `lock` that was denied with
/// `finished`, or one whose object the compositor already tore down. No
/// state exists, so nothing is dereferenced; destroy just frees the wire
/// resource (a NULL dispatcher would abort the compositor,
/// wayland-server.c wl_closure_invoke).
fn deadLockHandler(res: *server.ext.SessionLockV1, request: server.ext.SessionLockV1.Request, data: ?*Lock) void {
    _ = data;
    switch (request) {
        .destroy => res.destroy(),
        .get_lock_surface => |r| {
            // Keep the client's object table in sync even though the lock is
            // gone: create an inert ext_session_lock_surface_v1, which is
            // what wlroots does before it notices the lock resource is
            // inert ("We always need to create a lock surface resource to
            // stay in sync with the client", :279-283). It never configures
            // and never takes a role.
            const lock_surface = server.ext.SessionLockSurfaceV1.create(res.getClient(), res.getVersion(), r.id) catch {
                res.postNoMemory();
                return;
            };
            lock_surface.setHandler(?*LockSurface, deadLockSurfaceHandler, null, null);
        },
        .unlock_and_destroy => res.destroy(),
    }
}

/// Request handler for an inert lock surface: the lock it belonged to is
/// gone, or the object was refused. Only destroy remains meaningful.
fn deadLockSurfaceHandler(
    res: *server.ext.SessionLockSurfaceV1,
    request: server.ext.SessionLockSurfaceV1.Request,
    data: ?*LockSurface,
) void {
    _ = data;
    switch (request) {
        .destroy => res.destroy(),
        .ack_configure => {},
    }
}

// ---------------------------------------------------------------------------
// The "ext_session_lock_surface_v1" wl_surface role.
// ---------------------------------------------------------------------------

/// The LockSurface that owns `surface`'s role, or null. The role resource
/// is the lock surface's wire object and its user data is this state (the
/// layer-shell lookup, layer_shell.zig:677-680); the surface check makes
/// the invariant explicit — a role resource that somehow points at another
/// lock surface is ignored rather than misused.
fn lockSurfaceFromRole(surface: *Surface) ?*LockSurface {
    const role_resource = surface.role_resource orelse return null;
    const user_data = role_resource.getUserData() orelse return null;
    const ls: *LockSurface = @ptrCast(@alignCast(user_data));
    if (ls.surface != surface) return null;
    return ls;
}

/// Pre-swap commit check for a lock surface, in the XML's order: a commit
/// with no buffer, a commit before the first ack, and a commit that does
/// not match the acked configure are all protocol errors (wlroots
/// lock_surface_role_client_commit :154-181). The size is read from the
/// PENDING state (the swap has not happened yet; surface.zig:518 runs the
/// hook before applyCommit).
fn lockSurfaceClientCommit(surface: *Surface) void {
    const ls = lockSurfaceFromRole(surface) orelse return;
    const size = committedSize(&surface.pending) orelse {
        ls.resource.postError(.null_buffer, "session lock surface committed without a buffer");
        return;
    };
    if (!ls.configured) {
        ls.resource.postError(.commit_before_first_ack, "session lock surface committed before ack_configure");
        return;
    }
    if (size.w != @as(i32, @intCast(ls.acked_width)) or size.h != @as(i32, @intCast(ls.acked_height))) {
        ls.resource.postError(.dimensions_mismatch, "committed dimensions do not match the acked configure");
    }
}

/// Post-swap commit: the first commit that carries a buffer matching the
/// acked configure IS the locked frame, so the session locks here
/// (wlroots maps the surface in this hook, :183-190; sway then calls
/// wlr_session_lock_v1_send_locked). The same conditions are re-checked
/// rather than trusted from client_commit, so a commit that was refused
/// cannot latch the session. `current.buffer` still holds the committed
/// buffer here: the committed slot is NULLed after the role hooks
/// (surface.zig:635, :661).
fn lockSurfaceCommit(surface: *Surface) void {
    const ls = lockSurfaceFromRole(surface) orelse return;
    const lock = ls.lock;
    if (lock.locked_sent or lock.finished_sent) return;
    const size = committedSize(&surface.current) orelse return;
    if (!ls.configured) return;
    if (size.w != @as(i32, @intCast(ls.acked_width)) or size.h != @as(i32, @intCast(ls.acked_height))) return;
    ls.session_lock.sendLocked(lock);
}

/// The wl_surface is dying: the lock surface cannot outlive it (its whole
/// job is to present that surface). The client's lock-surface resource
/// stays alive and inert until it destroys it (wlroots
/// lock_surface_role_destroy :192-199 + lock_surface_destroy).
fn lockSurfaceRoleDestroy(surface: *Surface) void {
    const ls = lockSurfaceFromRole(surface) orelse return;
    ls.session_lock.destroyLockSurface(ls, true);
}

const lock_surface_role: role_mod.SurfaceRole = .{
    .name = "ext_session_lock_surface_v1",
    .client_commit = lockSurfaceClientCommit,
    .commit = lockSurfaceCommit,
    .destroy = lockSurfaceRoleDestroy,
};

/// The lock surface's wl_surface died without the role hook having run
/// first (a disturbed role link): release the state so nothing outlives
/// the surface.
fn onLockSurfaceDestroy(listener: *wire.Listener(*Surface), surface: *Surface) void {
    const ls: *LockSurface = @fieldParentPtr("surface_destroy_listener", listener);
    if (ls.surface != surface) return;
    ls.session_lock.destroyLockSurface(ls, true);
}

/// The covered output died: the lock surface goes with it (wlroots
/// lock_surface_handle_output_destroy :203-209), so the server falls back
/// to a solid color for that output.
fn onLockOutputDestroy(listener: *wire.Listener(*output_mod.Output), output: *output_mod.Output) void {
    const ls: *LockSurface = @fieldParentPtr("output_destroy_listener", listener);
    if (ls.output != output) return;
    ls.session_lock.destroyLockSurface(ls, true);
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// The compositor's wl_output behind a wire wl_output, or null when the
/// argument is foreign or dead (the identity check other protocols take a
/// wl_output for: xdg_output.zig:163-169).
fn resolveOutput(res: *server.wl.Output) ?*wl_output_mod.WlOutput {
    const user_data = res.getUserData() orelse return null;
    const wl_output: *wl_output_mod.WlOutput = @ptrCast(@alignCast(user_data));
    if (!wl_output.owns(res)) return null;
    return wl_output;
}

/// An output's logical size (buffer pixels / scale), the size a lock
/// surface is configured for (wlroots sway uses
/// wlr_output_effective_resolution; this server's xdg_output uses the same
/// division, xdg_output.zig:189-193).
fn logicalSize(output: *const output_mod.Output) geom.Size {
    const scale: i32 = @max(1, @as(i32, @intFromFloat(output.scale)));
    return .{
        .w = @divTrunc(output.width, scale),
        .h = @divTrunc(output.height, scale),
    };
}

/// The surface size a state commits to: the buffer under the transform,
/// divided by the buffer scale (surface.zig:753-757 computes it the same
/// way for wl_surface.invalid_size). Null when the state carries no
/// buffer.
fn committedSize(state: *const surface_mod.State) ?geom.Size {
    const buffer = state.buffer orelse return null;
    const transformed = state.transform.transformedSize(buffer.width, buffer.height);
    return .{
        .w = @divTrunc(transformed.w, state.scale),
        .h = @divTrunc(transformed.h, state.scale),
    };
}

/// Detach a listener that may or may not still be attached: the signal it
/// was added to can remove it first (the surface-destroy / output-destroy
/// paths), and a detached link must not be removed twice.
fn detachListener(comptime T: type, listener: *wire.Listener(T)) void {
    if (listener.link.prev != null and listener.link.prev != &listener.link) {
        listener.link.remove();
    }
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/xdg.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");
const backend_mod = @import("../backend/backend.zig");

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

/// Two outputs: get_lock_surface takes a wl_output, and the uncovered
/// output is what proves the blanking decision (outputIsBlank).
const output_count = 2;
const test_mode: output_mod.Mode = .{ .width = 1920, .height = 1080, .refresh_msec = 16 };

const FakeOutputImpl = struct {
    fn testState(_: *output_mod.Output, _: *const output_mod.Output.State) error{InvalidState}!void {}
    fn commit(_: *output_mod.Output, _: *const output_mod.Output.State) error{CommitFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_output_impl: output_mod.Output.Impl = .{
    .@"test" = FakeOutputImpl.testState,
    .commit = FakeOutputImpl.commit,
    .destroy = FakeOutputImpl.destroy,
};

const FakeBackendImpl = struct {
    fn start(_: *backend_mod.Backend) error{BackendFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_backend_impl: backend_mod.Backend.Impl = .{
    .start = FakeBackendImpl.start,
    .destroy = FakeBackendImpl.destroy,
};

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    shm_name: ?u32 = null,
    lock_name: ?u32 = null,
    output_names: [output_count]?u32 = .{ null, null },

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_shm")) {
                    data.shm_name = g.name;
                } else if (std.mem.eql(u8, name, "ext_session_lock_manager_v1")) {
                    data.lock_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_output")) {
                    for (&data.output_names) |*slot| {
                        if (slot.* == null) {
                            slot.* = g.name;
                            return;
                        }
                    }
                }
            },
            .global_remove => {},
        }
    }
};

/// ext_session_lock_v1 events in wire order: 0 = locked, 1 = finished. The
/// log (not just counters) is what pins down the ORDER the XML requires.
const LockEvents = struct {
    log: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    len: usize = 0,

    fn record(self: *LockEvents, what: u8) void {
        if (self.len < self.log.len) {
            self.log[self.len] = what;
            self.len += 1;
        }
    }

    fn listener(_: *client.ext.SessionLockV1, event: client.ext.SessionLockV1.Event, self: *LockEvents) void {
        switch (event) {
            .locked => self.record(0),
            .finished => self.record(1),
        }
    }
};

/// ext_session_lock_surface_v1.configure capture: the first configure
/// carries the exact size the client must commit.
const LockSurfaceEvents = struct {
    configures: usize = 0,
    serial: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    fn listener(
        _: *client.ext.SessionLockSurfaceV1,
        event: client.ext.SessionLockSurfaceV1.Event,
        self: *LockSurfaceEvents,
    ) void {
        switch (event) {
            .configure => |c| {
                self.configures += 1;
                self.serial = c.serial;
                self.width = c.width;
                self.height = c.height;
            },
        }
    }
};

const ProtocolError = struct { code: c_int, interface: []const u8, id: u32 };

/// A compositor + two wl_outputs + the session lock manager + an in-memory
/// client, for wire roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    backend: ?*backend_mod.Backend = null,
    outputs: [output_count]?*output_mod.Output = .{ null, null },
    session_lock: ?*SessionLock = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_shm: ?*client.wl.Shm = null,
    lock_manager: ?*client.ext.SessionLockManagerV1 = null,
    /// Client-side wl_output proxies, same order as `outputs`.
    c_outputs: [output_count]?*client.wl.Output = .{ null, null },
    /// Extra connections with no globals bound: the input-suppression test
    /// needs a client that does NOT hold the lock.
    idle_clients: std.ArrayList(*wire.Client) = .empty,
    /// The peer ends of those connections, closed by deinit (see
    /// addIdleClient).
    idle_peers: std.ArrayList(posix.socket_t) = .empty,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor and manager all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        ts.backend = try backend_mod.Backend.init(allocator, &ts.io, &ts.log_cfg, &fake_backend_impl, undefined);
        errdefer if (ts.backend) |b| b.destroy();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        // The internal wl_shm global (libwayland) must exist before the
        // client's first registry roundtrip so it can bind it for buffers.
        try ts.display.?.initShm();
        errdefer ts.destroyOutputs();
        for (&ts.outputs) |*slot| {
            const out = try output_mod.Output.create(
                allocator,
                &ts.io,
                &ts.log_cfg,
                ts.backend.?,
                &fake_output_impl,
                undefined,
                test_mode,
            );
            slot.* = out;
            // The wl_output global is freed by its output's destroy signal.
            _ = try wl_output_mod.WlOutput.create(
                allocator,
                &ts.io,
                &ts.log_cfg,
                ts.display.?,
                out,
                "WL-TEST",
                "session lock test output",
            );
        }
        ts.session_lock = try SessionLock.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.session_lock) |sl| sl.deinit();

        // In-memory client connection: one socketpair end for the server,
        // the other for the client library.
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        // Round 1: registry + global announcements.
        const registry = try ts.c_display.?.getRegistry();
        var capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
        try ts.pump();
        if (capture.compositor_name == null or capture.shm_name == null or
            capture.lock_name == null or capture.output_names[0] == null or
            capture.output_names[1] == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor (wl_surface), wl_shm (buffers), both
        // wl_outputs (get_lock_surface's argument) and the lock manager.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wl_shm = try registry.bind(capture.shm_name.?, client.wl.Shm, 1);
        for (&capture.output_names, &ts.c_outputs) |name, *slot| {
            slot.* = try registry.bind(name.?, client.wl.Output, 4);
        }
        ts.lock_manager = try registry.bind(capture.lock_name.?, client.ext.SessionLockManagerV1, 1);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers must run
        // while the session lock module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        for (ts.idle_clients.items) |c| c.destroy();
        for (ts.idle_peers.items) |fd| _ = std.os.linux.close(fd);
        ts.idle_peers.deinit(ts.allocator);
        ts.idle_clients.deinit(ts.allocator);
        if (ts.session_lock) |sl| sl.deinit();
        if (ts.compositor) |c| c.deinit();
        ts.destroyOutputs();
        if (ts.backend) |b| b.destroy();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Destroy every fake output; each one's destroy signal frees its
    /// wl_output global. Idempotent (slots are nulled), so the error path
    /// and deinit can both call it.
    fn destroyOutputs(ts: *TestServer) void {
        for (&ts.outputs) |*slot| {
            if (slot.*) |out| {
                slot.* = null;
                out.destroy();
            }
        }
    }

    /// A second server-side client with no globals bound, for the input
    /// suppression assertions. Its peer end stays open for the harness's
    /// whole life: closing it looks like a disconnect to the server, which
    /// would destroy the client at the next event loop dispatch.
    fn addIdleClient(ts: *TestServer) !*wire.Client {
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        const cli = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse {
            _ = std.os.linux.close(fds[0]);
            _ = std.os.linux.close(fds[1]);
            return error.ClientCreateFailed;
        };
        try ts.idle_peers.append(ts.allocator, fds[1]);
        errdefer _ = ts.idle_peers.pop();
        try ts.idle_clients.append(ts.allocator, cli);
        return cli;
    }

    /// Kill the client connection outright (its resources die, which is
    /// what a lock client crashing looks like to the compositor).
    fn killClient(ts: *TestServer) void {
        if (ts.c_display) |d| d.disconnect();
        ts.c_display = null;
        if (ts.client) |c| c.destroy();
        ts.client = null;
        ts.wl_compositor = null;
        ts.wl_shm = null;
        ts.lock_manager = null;
        ts.c_outputs = .{ null, null };
    }

    /// Client flush -> server event loop dispatch -> server flush ->
    /// client dispatch. Drives one roundtrip without blocking.
    fn pump(ts: *TestServer) !void {
        if (ts.c_display.?.flush() != .SUCCESS) return error.ClientFlushFailed;
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                // Protocol error or disconnect: the server has already
                // destroyed its client (dangling) — forget it for deinit.
                ts.client = null;
                // (the client-side display stays usable: protocolError reads
                // the error code from it).
                return error.ClientDispatchFailed;
            }
        }
    }

    /// The client-side record of the last protocol error (interface + code),
    /// for asserting which resource an error was posted on.
    fn protocolError(ts: *TestServer) ProtocolError {
        var interface: ?*client.wl.Interface = null;
        var id: u32 = 0;
        const code = wl_display_get_protocol_error(ts.c_display.?, @ptrCast(&interface), &id);
        const name = if (interface) |i| std.mem.span(i.name) else "";
        return .{ .code = code, .interface = name, .id = id };
    }
};

/// Create a real ARGB8888 shm buffer for the test client.
fn createShmBuffer(ts: *TestServer, width: i32, height: i32) !*client.wl.Buffer {
    const size: usize = @intCast(width * height * 4);
    // mmap rejects a zero length with EINVAL and std's wrapper asserts on
    // MAP_FAILED, so a mis-sized request must fail the test loudly instead
    // of aborting the whole test runner.
    if (size == 0) return error.EmptyBuffer;
    const fd = try posix.memfd_create("session-lock-test-buffer", std.os.linux.MFD.CLOEXEC);
    defer _ = std.os.linux.close(fd);
    {
        const rc = std.os.linux.ftruncate(fd, @intCast(size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
    }
    // The server maps the fd itself; the client-side mapping is only needed
    // to satisfy the pool creation and can go immediately after.
    const pixels = try posix.mmap(null, size, posix.PROT{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    posix.munmap(pixels);
    const pool = try ts.wl_shm.?.createPool(fd, @intCast(size));
    return pool.createBuffer(0, width, height, width * 4, .argb8888);
}

/// One lock object plus a lock surface on output 0 whose first configure
/// has been captured (not yet acked). It lives in the test's own stack
/// frame: the client listeners store `&session.events`, so the struct must
/// not be copied after it is filled in.
const LockedSession = struct {
    lock: *client.ext.SessionLockV1,
    events: LockEvents,
    surface_events: LockSurfaceEvents,
    lock_surface: *client.ext.SessionLockSurfaceV1,
    wl_surface: *client.wl.Surface,
};

fn beginLock(ts: *TestServer, session: *LockedSession) !void {
    session.* = .{
        .lock = undefined,
        .events = .{},
        .surface_events = .{},
        .lock_surface = undefined,
        .wl_surface = undefined,
    };
    session.lock = try ts.lock_manager.?.lock();
    session.lock.setListener(*LockEvents, LockEvents.listener, &session.events);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    session.wl_surface = wl_surface;
    session.lock_surface = try session.lock.getLockSurface(wl_surface, ts.c_outputs[0].?);
    session.lock_surface.setListener(*LockSurfaceEvents, LockSurfaceEvents.listener, &session.surface_events);
}

/// Commit the lock surface's first buffer: acked and sized like the
/// configure it answers. This commit IS the locked frame.
///
/// The roundtrip that delivers that configure is part of the helper, not
/// left to the caller: the first configure goes out with get_lock_surface
/// (XML:245-248) and a client can only ack a configure it has actually
/// received, so before the first pump `serial` is 0 and the size 0x0 —
/// an ack nothing can satisfy and a buffer nothing can map.
fn commitLockedFrame(ts: *TestServer, session: *const LockedSession) !void {
    try ts.pump();
    if (session.surface_events.configures == 0) return error.ConfigureNotReceived;
    session.lock_surface.ackConfigure(session.surface_events.serial);
    const width: i32 = @intCast(session.surface_events.width);
    const height: i32 = @intCast(session.surface_events.height);
    const buffer = try createShmBuffer(ts, width, height);
    session.wl_surface.attach(buffer, 0, 0);
    session.wl_surface.commit();
    try ts.pump();
}

test "a lock surface that commits no acked buffer never locks the session" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // `lock` alone sends neither event: the client owes the compositor a
    // lock surface first (XML:93-101).
    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), session.events.len);
    try std.testing.expect(!ts.session_lock.?.isLocked());
    try std.testing.expectEqual(@as(usize, 1), ts.session_lock.?.lockSurfaces().len);

    // Binding the lock surface immediately configures it (XML:245-248),
    // sized to the output's logical size.
    try std.testing.expectEqual(@as(usize, 1), session.surface_events.configures);
    try std.testing.expectEqual(@as(u32, 1920), session.surface_events.width);
    try std.testing.expectEqual(@as(u32, 1080), session.surface_events.height);
    try std.testing.expect(!ts.session_lock.?.isLocked());
    try std.testing.expectEqual(@as(usize, 0), session.events.len);

    // Committing a buffer before the first ack_configure is
    // commit_before_first_ack (XML:249-250) — and still no `locked`.
    const buffer = try createShmBuffer(ts, 1920, 1080);
    session.wl_surface.attach(buffer, 0, 0);
    session.wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqualStrings("ext_session_lock_surface_v1", err.interface);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockSurfaceV1.Error.commit_before_first_ack)),
        err.code,
    );
    try std.testing.expectEqual(@as(usize, 0), session.events.len);
    try std.testing.expect(!ts.session_lock.?.isLocked());
}

test "locked arrives on the first acked lock-surface commit, finished follows for a second lock" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), session.surface_events.configures);
    try std.testing.expect(!ts.session_lock.?.isLocked());

    // The acked, correctly sized first buffer IS the locked frame.
    try commitLockedFrame(ts, &session);
    try std.testing.expectEqual(@as(usize, 1), session.events.len);
    try std.testing.expectEqual(@as(u8, 0), session.events.log[0]); // locked
    try std.testing.expect(ts.session_lock.?.isLocked());

    // The server-side state the render gate needs: one lock surface, on
    // output 0; output 1 has none and must be blanked.
    const lock_surfaces = ts.session_lock.?.lockSurfaces();
    try std.testing.expectEqual(@as(usize, 1), lock_surfaces.len);
    try std.testing.expect(ts.session_lock.?.isLockSurface(lock_surfaces[0].surface));
    try std.testing.expect(lock_surfaces[0].output == ts.outputs[0].?);
    try std.testing.expect(ts.session_lock.?.lockSurfaceForOutput(ts.outputs[1].?) == null);
    try std.testing.expect(!ts.session_lock.?.outputIsBlank(ts.outputs[0].?));
    try std.testing.expect(ts.session_lock.?.outputIsBlank(ts.outputs[1].?));

    // A second lock while one is held: the new object is finished right
    // away (XML:170-174), and the live lock is untouched.
    var denied: LockEvents = .{};
    const second = try ts.lock_manager.?.lock();
    second.setListener(*LockEvents, LockEvents.listener, &denied);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), denied.len);
    try std.testing.expectEqual(@as(u8, 1), denied.log[0]); // finished
    try std.testing.expect(ts.session_lock.?.isLocked());
    try std.testing.expectEqual(@as(usize, 1), ts.session_lock.?.lockSurfaces().len);
    // `locked` then `finished`, in that order, on the wire.
    try std.testing.expectEqual(@as(u8, 0), session.events.log[0]);
    second.destroy();

    // unlock_and_destroy releases the session and the lock surfaces.
    session.lock.unlockAndDestroy();
    try ts.pump();
    try std.testing.expect(!ts.session_lock.?.isLocked());
    try std.testing.expectEqual(@as(usize, 0), ts.session_lock.?.lockSurfaces().len);
    try std.testing.expect(ts.session_lock.?.activeLock() == null);
    // Normal content is correct again on every output.
    try std.testing.expect(!ts.session_lock.?.outputIsBlank(ts.outputs[0].?));
    try std.testing.expect(!ts.session_lock.?.outputIsBlank(ts.outputs[1].?));
    // The client's lock-surface object is inert now; destroying it must not
    // touch the freed state.
    session.lock_surface.destroy();
    session.wl_surface.destroy();
    try ts.pump();
}

test "input is suppressed for the whole locked interval and only for other clients" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const other = try ts.addIdleClient();

    // Unlocked: everything is normal.
    try std.testing.expect(!ts.session_lock.?.isLocked());
    try std.testing.expect(ts.session_lock.?.acceptsInput(ts.client.?));
    try std.testing.expect(ts.session_lock.?.acceptsInput(other));

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try commitLockedFrame(ts, &session);
    try std.testing.expect(ts.session_lock.?.isLocked());
    // The lock client keeps its input; every other client loses it.
    try std.testing.expect(ts.session_lock.?.acceptsInput(ts.client.?));
    try std.testing.expect(!ts.session_lock.?.acceptsInput(other));

    // Dropping the lock surface object leaves the session locked: the
    // output goes blank, the latch does not move.
    session.lock_surface.destroy();
    try ts.pump();
    try std.testing.expect(ts.session_lock.?.isLocked());
    try std.testing.expectEqual(@as(usize, 0), ts.session_lock.?.lockSurfaces().len);
    try std.testing.expect(ts.session_lock.?.outputIsBlank(ts.outputs[0].?));
    try std.testing.expect(!ts.session_lock.?.acceptsInput(other));

    // unlock_and_destroy ends the interval: false again for everyone.
    session.lock.unlockAndDestroy();
    try ts.pump();
    try std.testing.expect(!ts.session_lock.?.isLocked());
    try std.testing.expect(ts.session_lock.?.acceptsInput(other));
}

test "a lock client that dies while locked does not unlock the session" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const other = try ts.addIdleClient();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try commitLockedFrame(ts, &session);
    try std.testing.expect(ts.session_lock.?.isLocked());

    // The lock client vanishes (XML:111-115: the compositor must not unlock
    // in response). The session stays locked with no lock object at all.
    ts.killClient();
    try std.testing.expect(ts.session_lock.?.isLocked());
    try std.testing.expect(ts.session_lock.?.activeLock() == null);
    try std.testing.expectEqual(@as(usize, 0), ts.session_lock.?.lockSurfaces().len);
    try std.testing.expect(ts.session_lock.?.outputIsBlank(ts.outputs[0].?));
    try std.testing.expect(!ts.session_lock.?.acceptsInput(other));

    // Only the compositor recovery path can lift it.
    ts.session_lock.?.forceUnlock();
    try std.testing.expect(!ts.session_lock.?.isLocked());
    try std.testing.expect(ts.session_lock.?.acceptsInput(other));
}

test "destroy while locked is invalid_destroy" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try commitLockedFrame(ts, &session);
    try std.testing.expect(ts.session_lock.?.isLocked());

    // XML:146-147: destroying a locked session lock is a protocol error;
    // the client must use unlock_and_destroy. `destroy` is a destructor
    // request, so the proxy is already gone locally when the error comes
    // back and libwayland-client cannot name the interface for it — it logs
    // "[destroyed object]: error 0" (wayland-client.c display_handle_error)
    // and wl_display_get_protocol_error leaves the interface unset. The code
    // and the killed connection are what the protocol pins down here: the
    // dispatch failure below IS the error arriving.
    session.lock.destroy();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockV1.Error.invalid_destroy)),
        err.code,
    );
    // The refused destroy killed the client, so no lock object is left.
    try std.testing.expect(ts.session_lock.?.activeLock() == null);
    try std.testing.expectEqual(@as(usize, 0), ts.session_lock.?.lockSurfaces().len);
    // The session stays locked despite the dying client.
    try std.testing.expect(ts.session_lock.?.isLocked());
}

test "ack_configure with a serial nobody sent is invalid_serial" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    session.lock_surface.ackConfigure(session.surface_events.serial + 1000);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqualStrings("ext_session_lock_surface_v1", err.interface);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockSurfaceV1.Error.invalid_serial)),
        err.code,
    );
}

test "ack_configure twice for the same configure is invalid_serial" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    session.lock_surface.ackConfigure(session.surface_events.serial);
    try ts.pump();
    // The ack consumed that configure (XML:302-309), so the second ack
    // names a configure that no longer exists.
    session.lock_surface.ackConfigure(session.surface_events.serial);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqualStrings("ext_session_lock_surface_v1", err.interface);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockSurfaceV1.Error.invalid_serial)),
        err.code,
    );
}

test "a second lock surface for the same output is duplicate_output" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    const other_surface = try ts.wl_compositor.?.createSurface();
    _ = try session.lock.getLockSurface(other_surface, ts.c_outputs[0].?);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqualStrings("ext_session_lock_v1", err.interface);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockV1.Error.duplicate_output)),
        err.code,
    );
}

test "a wl_surface that already has a role cannot become a lock surface" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    // The same wl_surface for the other output: it already carries the
    // lock-surface role, which the XML refuses (XML:199-201).
    _ = try session.lock.getLockSurface(session.wl_surface, ts.c_outputs[1].?);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqualStrings("ext_session_lock_v1", err.interface);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockV1.Error.role)),
        err.code,
    );
}

test "a wl_surface with a buffer attached is already_constructed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // A plain surface with a committed buffer: not fresh.
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const buffer = try createShmBuffer(ts, 64, 64);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();

    const lock = try ts.lock_manager.?.lock();
    _ = try lock.getLockSurface(wl_surface, ts.c_outputs[0].?);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqualStrings("ext_session_lock_v1", err.interface);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockV1.Error.already_constructed)),
        err.code,
    );
}

test "deny finishes a pending lock without locking the session" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    const lock = ts.session_lock.?.activeLock().?;
    ts.session_lock.?.deny(lock);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), session.events.len);
    try std.testing.expectEqual(@as(u8, 1), session.events.log[0]); // finished
    try std.testing.expect(!ts.session_lock.?.isLocked());
    try std.testing.expect(ts.session_lock.?.activeLock() == null);
    // The client may still destroy its (now inert) objects.
    session.lock.destroy();
    session.lock_surface.destroy();
    try ts.pump();
    // A lock after the denial is accepted again.
    var next: LockedSession = undefined;
    try beginLock(ts, &next);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), next.events.len);
    try std.testing.expectEqual(@as(usize, 1), ts.session_lock.?.lockSurfaces().len);
}

test "a null-buffer commit on a lock surface is null_buffer" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    session.lock_surface.ackConfigure(session.surface_events.serial);
    // attach(null) + commit: committing without a buffer is never legal on
    // a lock surface (XML:250-251).
    session.wl_surface.attach(null, 0, 0);
    session.wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqualStrings("ext_session_lock_surface_v1", err.interface);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockSurfaceV1.Error.null_buffer)),
        err.code,
    );
    try std.testing.expect(!ts.session_lock.?.isLocked());
}

test "a lock surface commit that ignores the acked size is dimensions_mismatch" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try ts.pump();
    session.lock_surface.ackConfigure(session.surface_events.serial);
    const buffer = try createShmBuffer(ts, 800, 600);
    session.wl_surface.attach(buffer, 0, 0);
    session.wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = ts.protocolError();
    try std.testing.expectEqualStrings("ext_session_lock_surface_v1", err.interface);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(server.ext.SessionLockSurfaceV1.Error.dimensions_mismatch)),
        err.code,
    );
    // A refused commit never latches the session.
    try std.testing.expect(!ts.session_lock.?.isLocked());
}

test "a lock surface dies with its wl_surface and the session stays locked" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var session: LockedSession = undefined;
    try beginLock(ts, &session);
    try commitLockedFrame(ts, &session);
    try std.testing.expect(ts.session_lock.?.isLocked());
    try std.testing.expectEqual(@as(usize, 1), ts.session_lock.?.lockSurfaces().len);

    // The wl_surface dies: the lock surface cannot outlive the surface it
    // exists to present (wlroots lock_surface_role_destroy). The client may
    // not cause that itself — wayland.xml:1489-1491 makes destroying the
    // wl_surface before its role object defunct_role_object, and this
    // server refuses it like wlroots (surface.zig:1213-1220) — so the
    // compositor retires the surface itself, which is the same teardown a
    // disconnecting client runs (Surface.destroy is the compositor's own
    // entry point, surface.zig:384).
    const lock_surface = ts.session_lock.?.lockSurfaces()[0];
    lock_surface.surface.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.session_lock.?.lockSurfaces().len);
    try std.testing.expect(ts.session_lock.?.isLocked());
    try std.testing.expect(ts.session_lock.?.outputIsBlank(ts.outputs[0].?));

    session.lock.unlockAndDestroy();
    try ts.pump();
    try std.testing.expect(!ts.session_lock.?.isLocked());
}
