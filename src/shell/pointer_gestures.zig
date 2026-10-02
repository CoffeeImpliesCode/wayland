//! zwp_pointer_gestures_v1 (unstable/pointer-gestures, v3): swipe, pinch and
//! hold gesture notification for the seat's pointer.
//!
//! wlroots parity (0.20.2). types/wlr_pointer_gestures_v1.c performs NO
//! gesture detection of its own — it forwards the backend's already
//! classified gesture signals, and every send helper follows the same
//! shape: return early when the seat has no focused surface or no focused
//! seat client (:52-54, :80-82, :106-108, :226-228, :293-295); mint a
//! fresh serial through wlr_seat_client_next_serial(focus_seat_client) for
//! begin and end but NOT for update (:57, :111, :173, :231, :298); deliver
//! only to gesture objects whose client is the pointer-focus client
//! (:60-68, :87-95, :119-122, :176-184, :233-242). A gesture object created
//! from a wl_pointer that is not a live seat pointer is left INERT
//! (:260-261, :354-355) and never attached to a seat.
//!
//! WHERE THE THRESHOLDS COME FROM — task premise corrected. The task
//! said the thresholds "live in include/wlr/types/wlr_pointer.h". At
//! wlroots 0.20.2 that header declares only WLR_POINTER_BUTTONS_CAP
//! (line 17) and WLR_POINTER_AXIS_DISCRETE_STEP (line 74); there is no
//! WLR_POINTER_SWIPE_THRESHOLD / WLR_POINTER_PINCH_THRESHOLD /
//! WLR_POINTER_HOLD_THRESHOLD_MS in it, and none in the same header at
//! tags 0.15.0, 0.16.2 or 0.17.2 either. Detection lives in the backend:
//! backend/libinput/pointer.c:186-293 forwards libinput's pre-classified
//! libinput_event_gesture_* events unchanged. This module therefore
//! SYNTHESISES gestures from the seat's pointer motion and button signals
//! (Seat.events.pointer_move / Seat.events.button, seat.zig:495-513), and
//! the constants below are this compositor's own documented policy — named,
//! cited and covered by tests, never magic numbers.
//!
//! Detection policy:
//! - A candidate arms on the 0 -> 1 transition of the seat's physical
//!   pressed-button count (Seat.pressed_count, wlroots button_count,
//!   wlr_seat_pointer.c:471-517). The position at that press is the
//!   origin.
//! - Travel is the exact integer distance from the origin, compared
//!   squared: no float, no rounding.
//! - HOLD: arming starts a hold_threshold_ms timer. If the button is
//!   still down and the pointer travelled no further than hold_slop_px
//!   when the timer fires, the hold begins. Motion past hold_slop_px
//!   cancels the hold instead — the XML's own words: the hold ends
//!   "if the fingers move past an implementation-defined threshold"
//!   (pointer-gestures-unstable-v1.xml:259-261).
//! - SWIPE: travel past swipe_threshold_px promotes the candidate to a
//!   swipe, but only with at least min_swipe_fingers fingers (held
//!   buttons). A swipe is a MULTI-finger gesture (XML:88-92), so one held
//!   button is either a hold or a plain drag, never a swipe.
//! - SLOP BOUND: one motion step larger than max_step_px while the
//!   candidate has not begun kills it outright. A jump that big is a
//!   cursor warp (layout change, unlocking constraint, compositor-driven
//!   move), not finger travel.
//! - END: the release that drains the last held button ends the gesture
//!   with cancelled = 0; cancel() ends it with cancelled = 1. Either way
//!   the state returns to idle and the end event carries a fresh
//!   focus-client serial.
//! - PINCH: the seat carries no pinch source (no scale, no rotation — it
//!   reports absolute positions and button codes only), so pinch is driven
//!   by the backend through pinchBegin/pinchUpdate/pinchEnd, the
//!   compositor-side entry points mirroring wlroots'
//!   wlr_pointer_gestures_v1_send_pinch_begin/update/end
//!   (wlr_pointer_gestures_v1.c:160-185, :187-216, :218-243).
//!   pinchBegin cancels an active swipe or hold first: the XML forbids two
//!   simultaneous gestures on one pointer/seat (XML:96-100, :159-163,
//!   :232-236).
//!
//! Cross-module contract: the manager binds per client
//! (zwp_pointer_gestures_v1); get_swipe_gesture / get_pinch_gesture /
//! get_hold_gesture each create one gesture object bound to the seat live
//! at that moment (inert forever if there is none). Every resource is
//! tracked so deinit destroys it — no handler data outlives the module.
//! setSeat(null) detaches the seat listeners and ends any active gesture
//! with cancelled = 1, so after the seat's events.destroy the module holds
//! no seat pointer and can never call into freed memory (seat.zig:519-525
//! requires exactly this). Finger deltas are i32 pixels converted with
//! Fixed.fromInt (24.8 signed, wayland.xml `fixed`), matching the
//! wl_fixed_from_int of the same pixel distance wlroots sends as
//! wl_fixed_from_double of its double delta (wlr_pointer_gestures_v1.c:94).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const seat_mod = @import("../compositor/seat.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "pointer_gestures";
const Fixed = wire.wl.Fixed;

/// Travel from the press point that promotes a pending candidate to a
/// swipe, in pointer pixels (compositor policy — see the file header for
/// why wlroots 0.20.2 has no equivalent constant).
pub const swipe_threshold_px: i32 = 50;

/// Fingers (held pointer buttons) a swipe needs. The XML calls a swipe a
/// "multi-finger swipe gesture" (XML:88-92).
pub const min_swipe_fingers: u32 = 2;

/// Travel a candidate may accumulate before the hold timer fires and still
/// become a hold. Past this the hold is cancelled instead.
pub const hold_slop_px: i32 = 10;

/// Delay between the press and hold begin, in milliseconds.
pub const hold_threshold_ms: u32 = 180;

/// Largest single motion step tolerated while the candidate has not begun.
pub const max_step_px: i32 = 250;

/// Square distance between two pointer positions. Saturating: |dx| reaches
/// 2^32 across the whole i32 range and its square does not fit an i64,
/// while a saturated "very far" is exactly right for a threshold test.
fn squaredDistance(ax: i32, ay: i32, bx: i32, by: i32) u64 {
    const dx: u64 = @abs(@as(i64, ax) - @as(i64, bx));
    const dy: u64 = @abs(@as(i64, ay) - @as(i64, by));
    return dx *| dx +| dy *| dy;
}

/// Exact integer "distance >= threshold" without a sqrt or a float.
fn atLeast(ax: i32, ay: i32, bx: i32, by: i32, threshold: i32) bool {
    const t: u64 = @intCast(threshold);
    return squaredDistance(ax, ay, bx, by) >= t * t;
}

/// Pixel delta -> 24.8 fixed, saturating. Fixed.fromInt takes an i24, whose
/// largest value is 2^23 - 1, so a larger delta would trap @intCast.
fn fixedFromPixels(d: i64) Fixed {
    const limit: i64 = (1 << 23) - 1;
    const clamped: i64 = if (d > limit) limit else if (d < -limit) -limit else d;
    return Fixed.fromInt(@intCast(clamped));
}

/// wlroots wl_fixed_from_double (wlr_pointer_gestures_v1.c:212-214), plus
/// the range guard Fixed.fromDouble's @intFromFloat needs: the value is
/// clamped to the representable pixel range, and NaN maps to zero.
fn fixedFromDouble(d: f64) Fixed {
    if (std.math.isNan(d)) return Fixed.fromInt(0);
    return Fixed.fromDouble(std.math.clamp(d, -8388608.0, 8388607.0));
}

/// The seat's pointer focus, which every gesture event is addressed to
/// (wlroots uses focused_surface + focused_client throughout).
const FocusTarget = struct {
    client: *wire.Client,
    surface: *server.wl.Surface,
};

fn focusTarget(seat: *seat_mod.Seat) ?FocusTarget {
    const focus = seat.pointer_focus orelse return null;
    return .{ .client = focus.resource.getClient(), .surface = focus.resource };
}

/// The detection state machine. The XML forbids two simultaneous gestures
/// on one pointer/seat, so exactly one candidate or gesture exists at a
/// time (XML:96-100).
const Phase = enum {
    /// Nothing tracked.
    idle,
    /// A button is down; the candidate has neither begun nor been killed.
    pending,
    /// A hold is active (no update stage, XML:246-248).
    hold,
    /// A swipe is active; motion becomes update.
    swipe,
    /// A pinch is active; driven through the public pinch* API.
    pinch,
};

/// Per-gesture-object state. `seat` is the seat the object was created
/// for; null makes the object permanently INERT (wlroots
/// wlr_pointer_gestures_v1.c:260-261).
const SwipeState = struct {
    gestures: *PointerGestures,
    seat: ?*seat_mod.Seat,
    res: *server.zwp.PointerGestureSwipeV1,
};

const PinchState = struct {
    gestures: *PointerGestures,
    seat: ?*seat_mod.Seat,
    res: *server.zwp.PointerGesturePinchV1,
};

const HoldState = struct {
    gestures: *PointerGestures,
    seat: ?*seat_mod.Seat,
    res: *server.zwp.PointerGestureHoldV1,
};

pub const PointerGestures = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The seat whose pointer drives the gestures; null when the
    /// compositor has no seat yet — the global still binds and every
    /// gesture object is inert.
    seat: ?*seat_mod.Seat,
    /// The zwp_pointer_gestures_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// Bound zwp_pointer_gestures_v1 resources (one per client bind).
    managers: std.ArrayList(*server.zwp.PointerGesturesV1) = .empty,
    swipes: std.ArrayList(*SwipeState) = .empty,
    pinches: std.ArrayList(*PinchState) = .empty,
    holds: std.ArrayList(*HoldState) = .empty,

    /// Seat motion/button/seat-destroy listeners. They live exactly as
    /// long as the module (removed by setSeat and deinit) and the module
    /// owns the seat pointer they dereference.
    motion_listener: wire.Listener(*seat_mod.Seat),
    button_listener: wire.Listener(*seat_mod.Seat),
    seat_destroy_listener: wire.Listener(*seat_mod.Seat),

    // Detection state (see the file header).
    phase: Phase = .idle,
    /// Press point, in output coordinates.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    /// Previous motion position; swipe update deltas are taken against it.
    prev_x: i32 = 0,
    prev_y: i32 = 0,
    /// The hold delay timer; live only while phase == .pending.
    hold_timer: ?*wire.EventSource = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        seat: ?*seat_mod.Seat,
    ) error{ OutOfMemory, GlobalCreateFailed }!*PointerGestures {
        const self = try allocator.create(PointerGestures);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .seat = null,
            // SAFETY: the links are put in the detached state by setSeat
            // below (and stay there while self.seat is null) before any
            // seat can reach them, so Listener.init leaving them
            // undefined is never observed.
            .motion_listener = wire.Listener(*seat_mod.Seat).init(onSeatMotion),
            .button_listener = wire.Listener(*seat_mod.Seat).init(onSeatButton),
            .seat_destroy_listener = wire.Listener(*seat_mod.Seat).init(onSeatDestroy),
        };
        errdefer self.managers.deinit(allocator);
        errdefer self.swipes.deinit(allocator);
        errdefer self.pinches.deinit(allocator);
        errdefer self.holds.deinit(allocator);
        self.global = try display.addGlobal(
            server.zwp.PointerGesturesV1,
            *PointerGestures,
            gesturesBind,
            server.zwp.PointerGesturesV1.generated_version,
            self,
        );
        self.setSeat(seat);
        return self;
    }

    pub fn deinit(self: *PointerGestures) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Detach from the seat and drop the hold timer FIRST: both refer
        // to state that must not outlive the module.
        self.setSeat(null);
        // Destroying the gesture objects cascades through their destroy
        // handlers, which free the states and prune the lists.
        while (self.swipes.items.len > 0) self.swipes.items[0].res.destroy();
        while (self.pinches.items.len > 0) self.pinches.items[0].res.destroy();
        while (self.holds.items.len > 0) self.holds.items[0].res.destroy();
        while (self.managers.items.len > 0) self.managers.items[0].destroy();
        self.swipes.deinit(allocator);
        self.pinches.deinit(allocator);
        self.holds.deinit(allocator);
        self.managers.deinit(allocator);
        allocator.destroy(self);
    }

    /// Attach (or detach, with null) the seat whose pointer drives the
    /// gestures. Re-attaching the same seat is a no-op. Detaching ends an
    /// active gesture with cancelled = 1 and drops a pending candidate.
    pub fn setSeat(self: *PointerGestures, seat: ?*seat_mod.Seat) void {
        if (self.seat == seat) return;
        if (self.seat != null) {
            // wire.Signal has no remove(); the links are live exactly
            // while self.seat != null (added below, removed here).
            self.motion_listener.link.remove();
            self.button_listener.link.remove();
            self.seat_destroy_listener.link.remove();
        }
        // Cancel while self.seat is still the old seat: the end event needs
        // its focus and mints a serial from it.
        self.cancel(true);
        self.cancelHoldTimer();
        self.phase = .idle;
        self.seat = seat;
        if (seat) |s| {
            s.events.pointer_move.add(&self.motion_listener);
            s.events.button.add(&self.button_listener);
            s.events.destroy.add(&self.seat_destroy_listener);
        }
    }

    /// End any active gesture (cancelled = 1) and drop any pending
    /// candidate. The `cancelled` argument reaches the client as the end
    /// event's `cancelled` argument (XML:135-149, :207-222, :259-272):
    /// the compositor decides the outcome, exactly as wlroots'
    /// wlr_pointer_gestures_v1_send_swipe_end takes it
    /// (wlr_pointer_gestures_v1.c:98-123).
    pub fn cancel(self: *PointerGestures, cancelled: bool) void {
        const seat = self.seat orelse {
            self.phase = .idle;
            return;
        };
        switch (self.phase) {
            .idle => {},
            .pending => self.cancelHoldTimer(),
            .hold => self.sendHoldEnd(seat, cancelled),
            .swipe => self.sendSwipeEnd(seat, cancelled),
            .pinch => self.sendPinchEnd(seat, seat.nowMs(), cancelled),
        }
        self.phase = .idle;
    }

    /// wlroots wlr_pointer_gestures_v1_send_pinch_begin
    /// (wlr_pointer_gestures_v1.c:160-185). Cancels an active swipe or
    /// hold first — the XML forbids two simultaneous gestures on one
    /// pointer/seat. With no pointer focus nothing is sent and no pinch
    /// becomes active (wlroots :165-170).
    pub fn pinchBegin(self: *PointerGestures, time_ms: u32, fingers: u32) void {
        const seat = self.seat orelse return;
        self.cancelHoldTimer();
        if (self.phase == .swipe or self.phase == .hold) self.cancel(true);
        const focus = focusTarget(seat) orelse {
            self.phase = .idle;
            return;
        };
        self.phase = .pinch;
        self.prev_x = seat.pointer_x;
        self.prev_y = seat.pointer_y;
        const serial = seat.serialFor(focus.client);
        for (self.pinches.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendBegin(serial, time_ms, focus.surface, fingers);
        }
    }

    /// wlroots wlr_pointer_gestures_v1_send_pinch_update
    /// (wlr_pointer_gestures_v1.c:187-216): `scale` is ABSOLUTE against
    /// begin and `rotation` is the RELATIVE clockwise angle in degrees
    /// against the previous begin/update (XML:185-206).
    pub fn pinchUpdate(
        self: *PointerGestures,
        time_ms: u32,
        dx: f64,
        dy: f64,
        scale: f64,
        rotation: f64,
    ) void {
        const seat = self.seat orelse return;
        if (self.phase != .pinch) return;
        const focus = focusTarget(seat) orelse return;
        const fdx = fixedFromDouble(dx);
        const fdy = fixedFromDouble(dy);
        const fscale = fixedFromDouble(scale);
        const frot = fixedFromDouble(rotation);
        for (self.pinches.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendUpdate(time_ms, fdx, fdy, fscale, frot);
        }
    }

    /// wlroots wlr_pointer_gestures_v1_send_pinch_end
    /// (wlr_pointer_gestures_v1.c:218-243).
    pub fn pinchEnd(self: *PointerGestures, time_ms: u32, cancelled: bool) void {
        const seat = self.seat orelse return;
        if (self.phase != .pinch) return;
        self.sendPinchEnd(seat, time_ms, cancelled);
        self.phase = .idle;
    }

    /// True while a gesture is being tracked (pending or active). Test and
    /// compositor hooks read this instead of reaching into the state.
    pub fn tracking(self: *const PointerGestures) bool {
        return self.phase != .idle;
    }

    // --- detection -----------------------------------------------------

    fn handleButton(self: *PointerGestures, seat: *seat_mod.Seat) void {
        if (seat.pressed_count == 0) {
            // The release that drains the last held button ends the
            // gesture normally (cancelled = 0): "one or more fingers are
            // lifted" (XML:135-141).
            if (self.phase != .idle) self.cancel(false);
            return;
        }
        // A press while nothing is tracked arms the candidate. Further
        // presses only raise the finger count, which is read at emit time.
        if (self.phase != .idle or seat.pressed_count != 1) return;
        self.arm(seat);
    }

    fn handleMotion(self: *PointerGestures, seat: *seat_mod.Seat) void {
        const x = seat.pointer_x;
        const y = seat.pointer_y;
        switch (self.phase) {
            .idle, .pinch => return,
            .hold => {
                if (atLeast(x, y, self.origin_x, self.origin_y, swipe_threshold_px)) {
                    // "the hold gesture changes into a different type of
                    // gesture" (XML:259-261): hand over to the swipe.
                    self.prev_x = x;
                    self.prev_y = y;
                    self.promoteToSwipe(seat);
                    return;
                }
                if (atLeast(x, y, self.origin_x, self.origin_y, hold_slop_px)) {
                    self.cancel(true);
                    return;
                }
                self.prev_x = x;
                self.prev_y = y;
            },
            .pending => {
                // SLOP BOUND: one step this large is a warp, not travel.
                if (atLeast(x, y, self.prev_x, self.prev_y, max_step_px)) {
                    self.cancelHoldTimer();
                    self.phase = .idle;
                    return;
                }
                self.prev_x = x;
                self.prev_y = y;
                if (atLeast(x, y, self.origin_x, self.origin_y, swipe_threshold_px)) {
                    self.promoteToSwipe(seat);
                    return;
                }
                if (atLeast(x, y, self.origin_x, self.origin_y, hold_slop_px)) {
                    // Moved too far to still be a hold, too little to be
                    // a swipe: this is a drag, not a gesture.
                    self.cancelHoldTimer();
                    self.phase = .idle;
                }
            },
            .swipe => {
                const dx = fixedFromPixels(@as(i64, x) - @as(i64, self.prev_x));
                const dy = fixedFromPixels(@as(i64, y) - @as(i64, self.prev_y));
                self.prev_x = x;
                self.prev_y = y;
                const focus = focusTarget(seat) orelse return;
                for (self.swipes.items) |st| {
                    if (st.seat != seat) continue;
                    if (st.res.getClient() != focus.client) continue;
                    st.res.sendUpdate(seat.nowMs(), dx, dy);
                }
            },
        }
    }

    fn arm(self: *PointerGestures, seat: *seat_mod.Seat) void {
        self.phase = .pending;
        self.origin_x = seat.pointer_x;
        self.origin_y = seat.pointer_y;
        self.prev_x = seat.pointer_x;
        self.prev_y = seat.pointer_y;
        const loop = self.display.getServer().getEventLoop();
        const timer = loop.addTimer(*PointerGestures, holdTimeout, self) catch {
            // No timer source: the hold never fires, the swipe path is
            // unaffected (motion driven). Degraded, but not silently.
            log.warn("hold timer unavailable; hold gestures disabled", self.io, self.log_cfg, log_tag, .{});
            return;
        };
        timer.timerUpdate(hold_threshold_ms) catch {
            timer.remove();
            log.warn("hold timer arm failed; hold gestures disabled", self.io, self.log_cfg, log_tag, .{});
            return;
        };
        self.hold_timer = timer;
    }

    fn cancelHoldTimer(self: *PointerGestures) void {
        if (self.hold_timer) |timer| {
            timer.remove();
            self.hold_timer = null;
        }
    }

    fn promoteToSwipe(self: *PointerGestures, seat: *seat_mod.Seat) void {
        self.cancelHoldTimer();
        // A swipe is multi-finger (XML:88-92): with fewer than
        // min_swipe_fingers the travel is a plain drag and no gesture is
        // reported at all.
        if (seat.pressed_count < min_swipe_fingers) {
            self.phase = .idle;
            return;
        }
        self.prev_x = seat.pointer_x;
        self.prev_y = seat.pointer_y;
        const focus = focusTarget(seat) orelse {
            self.phase = .idle;
            return;
        };
        self.phase = .swipe;
        const serial = seat.serialFor(focus.client);
        for (self.swipes.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendBegin(serial, seat.nowMs(), focus.surface, seat.pressed_count);
        }
    }

    fn sendHoldEnd(self: *PointerGestures, seat: *seat_mod.Seat, cancelled: bool) void {
        const focus = focusTarget(seat) orelse return;
        const serial = seat.serialFor(focus.client);
        for (self.holds.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendEnd(serial, seat.nowMs(), @intFromBool(cancelled));
        }
    }

    fn sendSwipeEnd(self: *PointerGestures, seat: *seat_mod.Seat, cancelled: bool) void {
        const focus = focusTarget(seat) orelse return;
        const serial = seat.serialFor(focus.client);
        for (self.swipes.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendEnd(serial, seat.nowMs(), @intFromBool(cancelled));
        }
    }

    /// `time_ms` is the caller's gesture timestamp, exactly like begin
    /// and update: the backend that opened the pinch owns the clock
    /// (wlr_pointer_gestures_v1_send_pinch_end takes one,
    /// wlr_pointer_gestures_v1.c:218-221). cancel() has no backend
    /// timestamp and passes the seat's own.
    fn sendPinchEnd(self: *PointerGestures, seat: *seat_mod.Seat, time_ms: u32, cancelled: bool) void {
        const focus = focusTarget(seat) orelse return;
        const serial = seat.serialFor(focus.client);
        for (self.pinches.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendEnd(serial, time_ms, @intFromBool(cancelled));
        }
    }

    /// The seat a wl_pointer belongs to, or null for an INERT gesture
    /// object (wlroots wlr_seat_client_from_pointer_resource returning
    /// NULL, wlr_pointer_gestures_v1.c:252-261). A wl_pointer created while
    /// the seat's pointer capability was disabled never enters
    /// Seat.pointers (seat.zig:1778), so it lands here too.
    fn seatFor(self: *PointerGestures, ptr: *server.wl.Pointer) ?*seat_mod.Seat {
        const seat = self.seat orelse return null;
        if (std.mem.indexOfScalar(*server.wl.Pointer, seat.pointers.items, ptr) == null) return null;
        return seat;
    }
};

/// The hold delay elapsed. libwayland 1.24 disarms a timer before
/// dispatching it, so the source is removed here (xdg_activation.zig:558-571).
fn holdTimeout(self: *PointerGestures) c_int {
    self.cancelHoldTimer();
    const seat = self.seat orelse {
        self.phase = .idle;
        return 1;
    };
    if (self.phase != .pending) return 1;
    if (atLeast(self.prev_x, self.prev_y, self.origin_x, self.origin_y, hold_slop_px)) return 1;
    const focus = focusTarget(seat) orelse {
        self.phase = .idle;
        return 1;
    };
    self.phase = .hold;
    const serial = seat.serialFor(focus.client);
    for (self.holds.items) |st| {
        if (st.seat != seat) continue;
        if (st.res.getClient() != focus.client) continue;
        st.res.sendBegin(serial, seat.nowMs(), focus.surface, seat.pressed_count);
    }
    return 1;
}

fn onSeatMotion(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    const self: *PointerGestures = @fieldParentPtr("motion_listener", listener);
    self.handleMotion(seat);
}

fn onSeatButton(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    const self: *PointerGestures = @fieldParentPtr("button_listener", listener);
    self.handleButton(seat);
}

/// The seat is dying: drop it and end any live gesture with cancelled = 1
/// while the seat is still valid (seat.zig:519-525 emits at the top of
/// Seat.deinit, "while the seat memory is still valid").
fn onSeatDestroy(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    _ = seat;
    const self: *PointerGestures = @fieldParentPtr("seat_destroy_listener", listener);
    self.cancel(true);
    self.cancelHoldTimer();
    self.phase = .idle;
    // Every link attached while self.seat was non-null goes: the seat is
    // about to free its signal lists and the module may outlive it.
    self.motion_listener.link.remove();
    self.button_listener.link.remove();
    listener.link.remove();
    self.seat = null;
}

// --- wire plumbing -------------------------------------------------------

fn gesturesBind(client_wire: *wire.Client, self: *PointerGestures, version: u32, id: u32) void {
    log.debug("gestures bind v{d} id={d}", self.io, self.log_cfg, log_tag, .{ version, id });
    const res = server.zwp.PointerGesturesV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    self.managers.append(self.allocator, res) catch {
        res.destroy();
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*PointerGestures, gesturesRequest, managerDestroy, self);
}

fn gesturesRequest(
    res: *server.zwp.PointerGesturesV1,
    request: server.zwp.PointerGesturesV1.Request,
    self: *PointerGestures,
) void {
    switch (request) {
        // Destructor: libwayland dispatches it to the handler, which must
        // destroy the resource (managerDestroy then runs the teardown).
        // zwp_pointer_gestures_v1 names it `release`, not `destroy`
        // (pointer-gestures-unstable-v1.xml, signature "2").
        .release => res.destroy(),
        .get_swipe_gesture => |r| createSwipe(self, res, r.id, r.pointer),
        .get_pinch_gesture => |r| createPinch(self, res, r.id, r.pointer),
        .get_hold_gesture => |r| createHold(self, res, r.id, r.pointer),
    }
}

fn managerDestroy(_res: *server.zwp.PointerGesturesV1, self: *PointerGestures) void {
    const idx = std.mem.indexOfScalar(*server.zwp.PointerGesturesV1, self.managers.items, _res) orelse return;
    _ = self.managers.swapRemove(idx);
}

fn createSwipe(
    self: *PointerGestures,
    manager: *server.zwp.PointerGesturesV1,
    id: u32,
    ptr: *server.wl.Pointer,
) void {
    const res = server.zwp.PointerGestureSwipeV1.create(manager.getClient(), manager.getVersion(), id) catch {
        manager.postNoMemory();
        return;
    };
    const st = self.allocator.create(SwipeState) catch {
        res.destroy();
        manager.postNoMemory();
        return;
    };
    st.* = .{ .gestures = self, .seat = self.seatFor(ptr), .res = res };
    self.swipes.append(self.allocator, st) catch {
        self.allocator.destroy(st);
        res.destroy();
        manager.postNoMemory();
        return;
    };
    res.setHandler(*SwipeState, swipeRequest, swipeDestroy, st);
}

fn createPinch(
    self: *PointerGestures,
    manager: *server.zwp.PointerGesturesV1,
    id: u32,
    ptr: *server.wl.Pointer,
) void {
    const res = server.zwp.PointerGesturePinchV1.create(manager.getClient(), manager.getVersion(), id) catch {
        manager.postNoMemory();
        return;
    };
    const st = self.allocator.create(PinchState) catch {
        res.destroy();
        manager.postNoMemory();
        return;
    };
    st.* = .{ .gestures = self, .seat = self.seatFor(ptr), .res = res };
    self.pinches.append(self.allocator, st) catch {
        self.allocator.destroy(st);
        res.destroy();
        manager.postNoMemory();
        return;
    };
    res.setHandler(*PinchState, pinchRequest, pinchDestroy, st);
}

fn createHold(
    self: *PointerGestures,
    manager: *server.zwp.PointerGesturesV1,
    id: u32,
    ptr: *server.wl.Pointer,
) void {
    const res = server.zwp.PointerGestureHoldV1.create(manager.getClient(), manager.getVersion(), id) catch {
        manager.postNoMemory();
        return;
    };
    const st = self.allocator.create(HoldState) catch {
        res.destroy();
        manager.postNoMemory();
        return;
    };
    st.* = .{ .gestures = self, .seat = self.seatFor(ptr), .res = res };
    self.holds.append(self.allocator, st) catch {
        self.allocator.destroy(st);
        res.destroy();
        manager.postNoMemory();
        return;
    };
    res.setHandler(*HoldState, holdRequest, holdDestroy, st);
}

fn swipeRequest(res: *server.zwp.PointerGestureSwipeV1, request: server.zwp.PointerGestureSwipeV1.Request, _: *SwipeState) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn swipeDestroy(_: *server.zwp.PointerGestureSwipeV1, st: *SwipeState) void {
    const self = st.gestures;
    const idx = std.mem.indexOfScalar(*SwipeState, self.swipes.items, st) orelse return;
    _ = self.swipes.swapRemove(idx);
    self.allocator.destroy(st);
}

fn pinchRequest(res: *server.zwp.PointerGesturePinchV1, request: server.zwp.PointerGesturePinchV1.Request, _: *PinchState) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn pinchDestroy(_: *server.zwp.PointerGesturePinchV1, st: *PinchState) void {
    const self = st.gestures;
    const idx = std.mem.indexOfScalar(*PinchState, self.pinches.items, st) orelse return;
    _ = self.pinches.swapRemove(idx);
    self.allocator.destroy(st);
}

fn holdRequest(res: *server.zwp.PointerGestureHoldV1, request: server.zwp.PointerGestureHoldV1.Request, _: *HoldState) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn holdDestroy(_: *server.zwp.PointerGestureHoldV1, st: *HoldState) void {
    const self = st.gestures;
    const idx = std.mem.indexOfScalar(*HoldState, self.holds.items, st) orelse return;
    _ = self.holds.swapRemove(idx);
    self.allocator.destroy(st);
}
// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/fractional_scale.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");
const surface_mod = @import("../compositor/surface.zig");

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,
    gestures_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "zwp_pointer_gestures_v1")) {
                    data.gestures_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Client-side capture of zwp_pointer_gesture_swipe_v1.
const SwipeEvents = struct {
    begins: usize = 0,
    updates: usize = 0,
    ends: usize = 0,
    begin_serial: u32 = 0,
    begin_fingers: u32 = 0,
    begin_surface: ?*client.wl.Surface = null,
    end_serial: u32 = 0,
    cancelled: i32 = 0,
    last_dx: Fixed = Fixed.fromInt(0),
    last_dy: Fixed = Fixed.fromInt(0),

    fn listener(_: *client.zwp.PointerGestureSwipeV1, event: client.zwp.PointerGestureSwipeV1.Event, data: *SwipeEvents) void {
        switch (event) {
            .begin => |e| {
                data.begins += 1;
                data.begin_serial = e.serial;
                data.begin_fingers = e.fingers;
                data.begin_surface = e.surface;
            },
            .update => |e| {
                data.updates += 1;
                data.last_dx = e.dx;
                data.last_dy = e.dy;
            },
            .end => |e| {
                data.ends += 1;
                data.end_serial = e.serial;
                data.cancelled = e.cancelled;
            },
        }
    }
};

/// Client-side capture of zwp_pointer_gesture_pinch_v1.
const PinchEvents = struct {
    begins: usize = 0,
    updates: usize = 0,
    ends: usize = 0,
    fingers: u32 = 0,
    dx: Fixed = Fixed.fromInt(0),
    dy: Fixed = Fixed.fromInt(0),
    scale: Fixed = Fixed.fromInt(0),
    rotation: Fixed = Fixed.fromInt(0),
    cancelled: i32 = 0,

    fn listener(_: *client.zwp.PointerGesturePinchV1, event: client.zwp.PointerGesturePinchV1.Event, data: *PinchEvents) void {
        switch (event) {
            .begin => |e| {
                data.begins += 1;
                data.fingers = e.fingers;
            },
            .update => |e| {
                data.updates += 1;
                data.dx = e.dx;
                data.dy = e.dy;
                data.scale = e.scale;
                data.rotation = e.rotation;
            },
            .end => |e| {
                data.ends += 1;
                data.cancelled = e.cancelled;
            },
        }
    }
};

/// Client-side capture of zwp_pointer_gesture_hold_v1 (begin + end only).
const HoldEvents = struct {
    begins: usize = 0,
    ends: usize = 0,
    fingers: u32 = 0,
    cancelled: i32 = 0,

    fn listener(_: *client.zwp.PointerGestureHoldV1, event: client.zwp.PointerGestureHoldV1.Event, data: *HoldEvents) void {
        switch (event) {
            .begin => |e| {
                data.begins += 1;
                data.fingers = e.fingers;
            },
            .end => |e| {
                data.ends += 1;
                data.cancelled = e.cancelled;
            },
        }
    }
};

/// The seat's hit-test stub: the pointer is always over `surface` or over
/// nothing, exactly like the seat's own tests.
const PickState = struct {
    surface: ?*surface_mod.Surface = null,
};

fn testPick(ctx: *anyopaque, x: i32, y: i32) ?seat_mod.Seat.PickResult {
    const st: *PickState = @ptrCast(@alignCast(ctx));
    if (st.surface) |s| return .{ .surface = s, .sx = x, .sy = y };
    return null;
}

/// A compositor + seat + pointer-gestures module + one in-memory client.
/// `with_seat` false builds the module with NO seat at all — the global
/// still binds and the module still tears down cleanly.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    gestures: ?*PointerGestures = null,
    pick_state: PickState = .{},
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_seat: ?*client.wl.Seat = null,
    wl_pointer: ?*client.wl.Pointer = null,
    wl_gestures: ?*client.zwp.PointerGesturesV1 = null,
    surface: ?*client.wl.Surface = null,
    /// The registry listener target lives HERE, not in init's frame: a
    /// libwayland proxy keeps the listener data pointer for the life of
    /// the proxy, so a stack local would dangle after init returns.
    capture: RegistryCapture = .{},
    registry: ?*client.wl.Registry = null,
    gestures_v: u32 = 0,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor, seat and module all store it).
    fn init(allocator: std.mem.Allocator, with_seat: bool) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        // deinit() frees ts itself, so it is the only teardown errdefer.
        errdefer ts.deinit();
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        // The internal wl_shm global (libwayland) must exist before the
        // client's first registry roundtrip.
        try ts.display.?.initShm();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        if (with_seat) {
            ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
            ts.seat.?.setPick(testPick, &ts.pick_state);
        }
        ts.gestures = try PointerGestures.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.seat);

        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        // Round 1: registry + global announcements.
        ts.registry = try ts.c_display.?.getRegistry();
        ts.registry.?.setListener(*RegistryCapture, RegistryCapture.listener, &ts.capture);
        try ts.pump();
        if (ts.capture.compositor_name == null or ts.capture.gestures_name == null) return error.GlobalMissing;
        if (with_seat and ts.capture.seat_name == null) return error.SeatMissing;

        // Round 2: bind wl_compositor + zwp_pointer_gestures_v1 (and the
        // seat's wl_seat when there is a seat).
        ts.wl_compositor = try ts.registry.?.bind(ts.capture.compositor_name.?, client.wl.Compositor, 7);
        ts.gestures_v = server.zwp.PointerGesturesV1.generated_version;
        ts.wl_gestures = try ts.registry.?.bind(ts.capture.gestures_name.?, client.zwp.PointerGesturesV1, ts.gestures_v);
        if (with_seat) {
            ts.wl_seat = try ts.registry.?.bind(ts.capture.seat_name.?, client.wl.Seat, seat_mod.seat_version);
            ts.wl_pointer = try ts.wl_seat.?.getPointer();
        }
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // The client goes first: its resource destroy handlers (the
        // per-gesture prune callbacks) must run while the module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        // The module releases the seat listeners before the seat dies.
        if (ts.gestures) |g| g.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Client flush -> server dispatch -> seat batch close -> server flush
    /// -> client dispatch. `timeout_ms` bounds the server dispatch, so a
    /// test can wait for the hold timer.
    fn pumpWith(ts: *TestServer, timeout_ms: c_int) !void {
        if (ts.c_display.?.flush() != .SUCCESS) return error.ClientFlushFailed;
        try ts.display.?.getServer().getEventLoop().dispatch(timeout_ms);
        if (ts.seat) |s| s.pointerFrame();
        ts.display.?.flushClients();
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                // Protocol error or disconnect: the server already
                // destroyed this client (dangling) — forget it for deinit.
                ts.client = null;
                return error.ClientDispatchFailed;
            }
        }
    }

    fn pump(ts: *TestServer) !void {
        try ts.pumpWith(0);
    }

    /// Create the test's wl_surface and make the seat's hit test return it,
    /// then move the pointer over it so the gesture events have a focus.
    fn focusSurface(ts: *TestServer) !*client.wl.Surface {
        const s = try ts.wl_compositor.?.createSurface();
        try ts.pump();
        const surface = ts.compositor.?.surfaces.items[ts.compositor.?.surfaces.items.len - 1];
        ts.surface = s;
        ts.pick_state.surface = surface;
        ts.seat.?.pointerMotion(100, 100);
        try ts.pump();
        return s;
    }
};

/// Every seat-backed test needs a real Seat, which needs xkbcommon and a
/// keymap; the seat's own tests skip with the same diagnostic when the
/// keymap source is unavailable.
fn testServer(allocator: std.mem.Allocator) !*TestServer {
    return TestServer.init(allocator, true) catch |err| {
        std.debug.print("pointer_gestures test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return err;
    };
}

test "gestures init and teardown with no seat and no client" {
    const allocator = std.testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const display = try display_mod.CompositorDisplay.init(allocator, io, &log_cfg);
    defer display.deinit();

    // No seat, no client, no compositor: the global still registers and
    // the module tears down with nothing bound.
    const gestures = try PointerGestures.init(allocator, io, &log_cfg, display, null);
    try std.testing.expectEqual(@as(usize, 0), gestures.managers.items.len);
    try std.testing.expect(!gestures.tracking());
    // The compositor-side pinch API is inert without a seat.
    gestures.pinchBegin(0, 2);
    gestures.pinchUpdate(0, 1, 0, 1, 0);
    gestures.pinchEnd(0, false);
    gestures.cancel(true);
    try std.testing.expect(!gestures.tracking());
    gestures.deinit();
}

test "a client binds and releases the manager with no seat behind it" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, false);
    defer ts.deinit();

    // The manager global is advertised even with no seat; release() (the
    // destructor since v2) destroys it without touching any state.
    ts.wl_gestures.?.release();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.gestures.?.managers.items.len);

    // The global is still advertised, so a second bind registers a new
    // manager resource after the first one was released.
    try std.testing.expect(ts.capture.gestures_name != null);
    _ = try ts.registry.?.bind(ts.capture.gestures_name.?, client.zwp.PointerGesturesV1, ts.gestures_v);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.managers.items.len);
}

test "swipe lifecycle: begin, update, end with exact deltas and serials" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    const surface_res = try ts.focusSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.swipes.items.len);

    const seat = ts.seat.?;
    // One button arms the candidate; the second one supplies the fingers a
    // multi-finger swipe needs.
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    try std.testing.expect(ts.gestures.?.tracking());

    // Travel past the threshold promotes the candidate: begin, addressed to
    // the focused client, with the pointer-focus surface.
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(min_swipe_fingers, ev.begin_fingers);
    try std.testing.expect(ev.begin_surface != null);
    try std.testing.expect(ev.begin_surface.? == surface_res);
    // Begin mints a serial through Seat.serialFor, so it lands in the
    // client's serial ring (wlroots wlr_seat_client_next_serial).
    try std.testing.expect(seat.validateEventSerial(ts.client.?, ev.begin_serial));

    // Every further motion is an update; the delta is the exact pixel
    // distance in 24.8 fixed (wayland.xml `fixed`).
    seat.pointerMotion(170, 103);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expectEqual(@as(i32, 20), ev.last_dx.toInt());
    try std.testing.expectEqual(@as(i32, 3), ev.last_dy.toInt());
    try std.testing.expectEqual(@as(i32, 20 * 256), @as(i32, @intFromEnum(ev.last_dx)));

    // The release that drains the last held button ends the gesture.
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(seat.validateEventSerial(ts.client.?, ev.end_serial));
    try std.testing.expect(!ts.gestures.?.tracking());

    // A motion after the end reports nothing.
    seat.pointerMotion(400, 400);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
}

test "a single held button never swipes: it is a drag" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerMotion(100 + swipe_threshold_px * 2, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.begins);
    try std.testing.expectEqual(@as(usize, 0), ev.updates);
    // The candidate is gone: further travel cannot start anything.
    try std.testing.expect(!ts.gestures.?.tracking());
    seat.pointerMotion(500, 500);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.begins);
}

test "a warp (one step past max_step_px) cancels the candidate" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    // One step over the slop bound: a warp, not finger travel.
    seat.pointerMotion(100 + max_step_px + 1, 100);
    try ts.pump();
    try std.testing.expect(!ts.gestures.?.tracking());
    try std.testing.expectEqual(@as(usize, 0), ev.begins);

    // Ordinary travel afterwards starts nothing: the candidate is gone.
    seat.pointerMotion(700, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.begins);
}

test "cancel() ends a live swipe with cancelled = 1" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);

    ts.gestures.?.cancel(true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 1), ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());

    // The buttons are still down; their release must not end anything twice.
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
}

test "hold begins after the delay and ends on release" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    var ev: HoldEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.begins);

    // Wait past the hold delay: the timer fires on the server's loop.
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(@as(u32, 1), ev.fingers);

    // The release ends it normally.
    seat.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
}

test "motion past the hold slop cancels the pending hold" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    var ev: HoldEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    // Just past the slop but short of the swipe threshold: a drag.
    seat.pointerMotion(100 + hold_slop_px + 1, 100);
    try ts.pump();
    try std.testing.expect(!ts.gestures.?.tracking());

    // The hold timer is gone, so waiting changes nothing.
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 0), ev.begins);
}

test "a hold that moves too far is cancelled with cancelled = 1" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    var ev: HoldEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 1), ev.begins);

    // A live hold that moves past the slop ends as cancelled (XML:259-261).
    seat.pointerMotion(100 + hold_slop_px + 1, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 1), ev.cancelled);
}

test "pinch runs on the compositor API with exact 24.8 encoding" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var ev: PinchEvents = .{};
    pinch.setListener(*PinchEvents, PinchEvents.listener, &ev);
    try ts.pump();

    const g = ts.gestures.?;
    g.pinchBegin(1000, 2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(@as(u32, 2), ev.fingers);

    // Values that are exact in 24.8: 1.5 -> 384, -2.25 -> -576,
    // scale 2.0 -> 512, rotation 90 degrees -> 23040.
    g.pinchUpdate(1010, 1.5, -2.25, 2.0, 90.0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expectEqual(@as(i32, 384), @as(i32, @intFromEnum(ev.dx)));
    try std.testing.expectEqual(@as(i32, -576), @as(i32, @intFromEnum(ev.dy)));
    try std.testing.expectEqual(@as(i32, 512), @as(i32, @intFromEnum(ev.scale)));
    try std.testing.expectEqual(@as(i32, 23040), @as(i32, @intFromEnum(ev.rotation)));

    g.pinchEnd(1020, true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 1), ev.cancelled);
    try std.testing.expect(!g.tracking());

    // An update outside a pinch is dropped.
    g.pinchUpdate(1030, 1.0, 1.0, 1.0, 0.0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
}

test "pinchBegin cancels a live hold: only one gesture at a time" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var hold_ev: HoldEvents = .{};
    var pinch_ev: PinchEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &hold_ev);
    pinch.setListener(*PinchEvents, PinchEvents.listener, &pinch_ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 1), hold_ev.begins);

    ts.gestures.?.pinchBegin(2000, 2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), hold_ev.ends);
    try std.testing.expectEqual(@as(i32, 1), hold_ev.cancelled);
    try std.testing.expectEqual(@as(usize, 1), pinch_ev.begins);
}

test "gesture objects survive the manager's release" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.managers.items.len);

    // release() destroys zwp_pointer_gestures_v1 only: "Swipe, pinch and
    // hold objects created via this gesture object remain valid"
    // (pointer-gestures-unstable-v1.xml:68-70).
    ts.wl_gestures.?.release();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.gestures.?.managers.items.len);
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.swipes.items.len);

    // The gesture object still works.
    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);

    swipe.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.gestures.?.swipes.items.len);
    // The module is still usable after a gesture object died mid-gesture.
    seat.pointerMotion(140, 100);
    try ts.pump();
}

test "destroying a gesture object mid-gesture stops delivery" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.swipes.items.len);
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.holds.items.len);
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.pinches.items.len);

    // Destroy all three while a gesture is live: the destroy handlers prune
    // the lists and free the states, so no listener outlives its resource.
    swipe.destroy();
    hold.destroy();
    pinch.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.gestures.?.swipes.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.gestures.?.holds.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.gestures.?.pinches.items.len);

    // The detection state survives and keeps working with no observers.
    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.begins);
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
}

test "setSeat(null) ends a live gesture and detaches the listeners" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    // The request must REACH the server before the press: the buttons and
    // the motion below are fed straight into the seat, so a module that
    // has not seen get_swipe_gesture yet tracks nothing.
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.swipes.items.len);

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);

    ts.gestures.?.setSeat(null);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 1), ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());
    try std.testing.expect(ts.gestures.?.seat == null);

    // Motion and buttons no longer reach the module: nothing tracks.
    seat.pointerMotion(900, 900);
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(usize, 0), ev.updates);
}

test "module teardown releases every live gesture object" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, true);
    defer ts.deinit();

    _ = try ts.focusSurface();
    // The proxies themselves are owned by the client display; the module
    // holds the server resources, which is what deinit must release.
    _ = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    _ = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    _ = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.swipes.items.len);
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.holds.items.len);
    try std.testing.expectEqual(@as(usize, 1), ts.gestures.?.pinches.items.len);

    // Tear the module down while the client still holds every resource:
    // deinit destroys them all (the client sees the delete_ids) and the
    // seat listeners go with it.
    ts.gestures.?.deinit();
    ts.gestures = null;
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerMotion(400, 400);
    try ts.pump();
}
