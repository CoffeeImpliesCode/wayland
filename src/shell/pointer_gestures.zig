//! zwp_pointer_gestures_v1 (unstable/pointer-gestures, v3): swipe, pinch and
//! hold gesture notification for the seat's pointer AND touchscreen.
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
//!   (pointer-gestures-unstable-v1.xml:262-265).
//! - SWIPE: travel past swipe_threshold_px promotes the candidate to a
//!   swipe, but only with at least min_swipe_fingers fingers (held
//!   buttons). A swipe is a MULTI-finger gesture (XML:88-92), so one held
//!   button is either a hold or a plain drag, never a swipe.
//!   Promoting a LIVE hold closes it first, with hold.end and
//!   cancelled = 1: the XML names that exact case, "the hold gesture
//!   changes into a different type of gesture" (XML:262-265), and the
//!   XML forbids two gestures on one pointer at once (XML:96-100), so
//!   swipe.begin may not go out while a hold.begin is still open.
//! - SLOP BOUND: one motion step larger than max_step_px while the
//!   candidate has not begun kills it outright. A jump that big is a
//!   cursor warp (layout change, unlocking constraint, compositor-driven
//!   move), not finger travel.
//! - END: the release that drains the last held button ends the gesture
//!   with cancelled = 0; cancel() ends it with cancelled = 1. Either way
//!   the state returns to idle and the end event carries a fresh
//!   focus-client serial.
//! - GRAB: a compositor pointer grab owns the WHOLE gesture. The grab
//!   gates client delivery (seat.zig:872-882, :1013-1023) while the
//!   seat's own pointer_move / button signals keep firing for
//!   compositor listeners, and a grab never clears pointer_focus — so
//!   without a guard a hold.begin could reach a client that received
//!   neither the press nor any of the travel, breaking the promise the
//!   grab makes (seat.zig:205-213, main.zig:322-325). Under a grab the
//!   module reports nothing: no candidate arms, no gesture begins, no
//!   update is sent. A gesture already live when the grab takes over is
//!   closed once with cancelled = 1 — the grab synthesized a release
//!   for every button the client held (seat.zig:800-823) and leaving a
//!   begin without its end is the same violation this module refuses
//!   everywhere else.
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
//! GESTURE SOURCE (touch and pointer are two ways into one gesture).
//! The premise for this section, corrected. The task described
//! `wlr_pointer_gestures.c` as the place that tracks finger counts
//! across both sources. There is no such file: at wlroots 0.20.2 the
//! whole protocol implementation is `types/wlr_pointer_gestures_v1.c`
//! (433 lines, plus `types/seat/{wlr_seat_pointer,wlr_seat_touch}.c`
//! for the seat and `backend/libinput/pointer.c:186-293` for the
//! events); nothing anywhere in the tree records which device produced
//! a gesture. What upstream DOES have is ONE `fingers` count per
//! gesture event — `libinput_event_gesture_get_finger_count`, filled
//! the same way whether libinput classified a touchpad or a
//! touchscreen (backend/libinput/pointer.c:194, :207, :235, :248,
//! :277) — and one delivery path, `seat->pointer_state.focused_surface`
//! (:160-163, :187-191, :218-222). So upstream's own answer to "which
//! source owns the gesture" is: it does not answer, and the
//! arbitration is left to its caller.
//!
//! This module therefore states the rule it enforces, and the rule is
//! the XML's: "There cannot be multiple simultaneous hold, pinch or
//! swipe gestures on a same pointer/seat" (XML:99-100, :161-163,
//! :232-236) — per SEAT, not per device. The seat admits exactly ONE
//! gesture, and it belongs to the source that armed it:
//! - While a touch gesture is live, pointer motion and buttons are
//!   INERT — they do not arm, promote, update or END it. While a
//!   pointer gesture is live, touch points are inert the same way.
//! - A source that starts while the other owns the gesture is dropped
//!   whole, not queued: the losing source's first real motion is
//!   still gated, because the owner must lift first.
//! - The seat's backend pinch API is the pointer source, all three
//!   calls of it: pinchBegin takes over a live pointer swipe or hold,
//!   exactly as before, and pinchBegin, pinchUpdate AND pinchEnd are
//!   refused while a TOUCH gesture owns the seat — the end included, so
//!   a backend cannot close a touch pinch it never began.
//! A touchscreen that is the only input therefore works from touch
//! ALONE: nothing on the touch path reads pointer_focus or
//! pressed_count, so a seat with no pointer focus anywhere still
//! reports gestures to the touch-focus client.
//!
//! TARGET OF A LIVE GESTURE, one rule for both sources. The client a
//! gesture BEGAN against owns the rest of it — updates and `end`
//! alike — and the target is captured at that begin, never resolved
//! again from the live focus. The seat takes a pointer focus away the
//! moment a motion picks nothing (seat.zig:1125-1126) and the moment
//! the focused surface is destroyed (seat.zig:1929), and it takes the
//! touch focus away the moment it closes a point sequence; every one of
//! those is an ordinary compositor event, not a compositor grab.
//! Resolving live in that window either drops the closing `end` on the
//! floor or hands it to a DIFFERENT client that never received the
//! `begin`, and both leave the first client holding a gesture open for
//! the life of its connection (XML:135-149, :207-222, :259-272 end
//! every gesture that has begun). Capturing at the begin is what makes
//! the promise this module already makes about a grab hold for focus
//! loss too.
//!
//! TOUCH DETECTION, in the pointer path's own terms so the two cannot
//! drift apart:
//! - A candidate arms on the 0 -> 1 transition of the DOWN TOUCH POINTS
//!   (Seat.activeTouchPoints), driven by Seat.events.touch. A second
//!   finger only raises the count.
//! - min_swipe_fingers counts POINTS on this path, not pressed buttons.
//!   One finger is a hold or a drag, never a swipe — the same rule the
//!   pointer path applies to one held button (XML:88-92).
//! - Positions are the point CENTROID: the mean of the live points, so
//!   two fingers sliding together translate the gesture, which is what
//!   a swipe is (XML:127-129: "the logical center of the gesture"). A
//!   finger added to or lifted from a live gesture re-bases the delta
//!   reference and sends NOTHING: the point SET changed, which is not
//!   travel. While the candidate is still PENDING the same change also
//!   re-bases its ORIGIN, so the travel measured is the center's move
//!   since the fingers were last put down — the second finger landing
//!   100 px away moves the center 50 px on its own, which is nobody
//!   swiping anything.
//! - Coordinates are converted to whole pixels ONCE, at the entry
//!   boundary (touchPixel, below), so every threshold on this path is
//!   the pointer path's exact integer square comparison on the same i32
//!   pixel space — no float, no rounding, no second numeric model.
//!   The seat stores whole pixels anyway (`@floatFromInt(p.sx)` of its
//!   i32 pick, Seat.touchDown), so the conversion is the identity for
//!   every point this compositor produces.
//! - TOUCH PINCH: the pair (the two points that were down when the
//!   second finger landed) is PINNED once and its exact squared
//!   separation kept as the denominator of every later scale
//!   (XML:185-206: scale is relative to begin). A candidate promotes
//!   to a pinch when the pair's separation has moved at least
//!   pinch_threshold_px from that baseline — compared as integers
//!   against (base ± threshold)², and only when the logical center has
//!   NOT travelled a full swipe threshold: a center that has is a
//!   swipe (XML:88-92 "fingers moving in the same direction"), a spread
//!   change the center did not travel into is a pinch (XML:154-158
//!   "moving towards each other or away from each other"). Only a
//!   PENDING candidate may become a pinch: once a swipe or a hold has
//!   begun, its deltas have described translation, and a scale taken
//!   from that moment would report travel the client never saw. A pinch
//!   whose pinned point lifts ends — it has no baseline left, and the
//!   XML ends a gesture "when one or more fingers are lifted"
//!   (XML:138-140). Rotation is zero: a touchscreen reports
//!   positions, never an angle.
//! - GRAB: touch obeys grabOwned exactly as the pointer does. The seat
//!   already gates the client side (Seat.touchDown / touchMotion /
//!   touchUp return before emitting anything while a grab is
//!   installed), and the one touch notification that DOES arrive under
//!   a grab — Seat.startPointerGrab's close sequence — reaches this
//!   module with the grab already installed, so it closes a live touch
//!   gesture once with cancelled = 1 and reports nothing else.
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
//! The touch path sends the same 24.8 pixels by the same conversion: a
//! touch position becomes whole pixels once at the entry boundary
//! (touchPixel), and every delta is the same i32 pixel difference
//! `fixedFromPixels` already converts.

const std = @import("std");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
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

/// Fingers a swipe needs. Held POINTER BUTTONS on the pointer path,
/// DOWN TOUCH POINTS on the touch path — the XML's own word is
/// "multi-finger swipe gesture" (XML:88-92) and a finger on glass is a
/// point, not a button.
pub const min_swipe_fingers: u32 = 2;

/// Travel a candidate may accumulate before the hold timer fires and still
/// become a hold. Past this the hold is cancelled instead.
pub const hold_slop_px: i32 = 10;

/// Delay between the press and hold begin, in milliseconds.
pub const hold_threshold_ms: u32 = 180;

/// Largest single motion step tolerated while the candidate has not begun.
pub const max_step_px: i32 = 250;

/// Change in the separation of the pinched touch pair that promotes a
/// pending touch candidate to a pinch, in pixels (compositor policy —
/// see the file header for the TOUCH DETECTION section).
pub const pinch_threshold_px: i32 = 30;

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

/// A whole-pixel position in output coordinates — the same space as
/// Seat.pointer_x / pointer_y, so squaredDistance and atLeast below
/// compare touch travel with the pointer path's exact integer
/// arithmetic and the two paths cannot drift apart.
const Point = struct { x: i32, y: i32 };

/// Seat.TouchPoint carries f64, but every comparator in this module is
/// an exact integer square comparison, so a touch position is converted
/// to WHOLE PIXELS exactly once, here, at the entry boundary. The
/// conversion is the IDENTITY for every point this compositor produces
/// — the seat stores `@floatFromInt(p.sx)` of its own i32 pick result
/// (Seat.touchDown) — so the rounding matters only for a backend that
/// reports sub-pixel positions, and it is the rule the seat itself
/// applies to one (Seat.pickCoord, `@intFromFloat(@round(v))`). NaN
/// fails every comparison and maps to zero with an out-of-range value
/// rather than trapping @intFromFloat.
fn touchPixel(v: f64) i32 {
    // The bounds are the pointer path's i32 pixel range, so a converted
    // touch position is the same kind of number squaredDistance and
    // atLeast already take.
    if (!(v >= -2147483648.0 and v <= 2147483647.0)) return 0;
    return @intFromFloat(@round(v));
}

/// The live point `id` in whole pixels, or null when it is no longer
/// down (wayland.xml:2774-2778: an id is only meaningful between its
/// down and its up).
fn touchPixelById(points: []const seat_mod.TouchPoint, id: c_int) ?Point {
    for (points) |p| {
        if (p.id == id) return .{ .x = touchPixel(p.x), .y = touchPixel(p.y) };
    }
    return null;
}

/// The logical center of the gesture (XML:127-129: the swipe's dx/dy
/// are "the relative coordinates of the logical center"): the mean of
/// the live points, truncated toward zero to the whole-pixel grid the
/// comparators work in. The truncation is below a pixel per event and,
/// because a run of deltas telescopes, never accumulates past the
/// number of events.
fn touchCentroid(points: []const seat_mod.TouchPoint) Point {
    if (points.len == 0) return .{ .x = 0, .y = 0 };
    var sum_x: i64 = 0;
    var sum_y: i64 = 0;
    for (points) |p| {
        sum_x += touchPixel(p.x);
        sum_y += touchPixel(p.y);
    }
    const n: i64 = @intCast(points.len);
    // A mean of i32 values is an i32 value, so neither @intCast traps.
    return .{ .x = @intCast(@divTrunc(sum_x, n)), .y = @intCast(@divTrunc(sum_y, n)) };
}

/// The two points whose separation defines a touch pinch's scale, and
/// that separation at the moment the pair was pinned. `base_px` is the
/// baseline as a whole-pixel distance so every threshold test below is
/// an exact integer square comparison against (base ± threshold)²;
/// `base_dist2` is the EXACT squared distance, so the reported scale is
/// a ratio of two exact squared lengths and never inherits the baseline
/// rounding. `base_px` is derived once per pair with @sqrt — the only
/// float in the touch detection path, and never inside a comparator.
const PinchPair = struct {
    a: c_int,
    b: c_int,
    base_px: i32,
    base_dist2: u64,
};

/// True when the pinched pair's separation has moved at least
/// `threshold` pixels away from the separation the pair was pinned at —
/// pulled apart (XML:154-158: fingers "moving towards each other or
/// away from each other"). A pair pinned coincident has no separation
/// to change, so it never opens a pinch.
fn pinchSpreadChanged(spread2: u64, pair: PinchPair, threshold: i32) bool {
    if (pair.base_px == 0) return false;
    const t: i64 = threshold;
    const up: u64 = @intCast(@as(i64, pair.base_px) + t);
    if (spread2 >= up *| up) return true;
    const down_i: i64 = @as(i64, pair.base_px) - t;
    if (down_i > 0) {
        const down: u64 = @intCast(down_i);
        if (spread2 <= down * down) return true;
    }
    // Both fingers came together on one point: the separation collapsed
    // to zero, which is the furthest a pinch can go.
    return spread2 == 0;
}

/// The touch gesture's own bookkeeping (see the file header's TOUCH
/// DETECTION section). Coordinates are whole pixels in the pointer
/// path's space, so every comparator is the same exact integer square
/// comparison the pointer path uses.
const TouchState = struct {
    /// The target the live touch gesture is addressed to: the TOUCH
    /// focus surface's client and surface. Captured when the gesture
    /// BEGINS, because the seat clears the touch focus whenever it
    /// takes the points away (a grab closes them,
    /// Seat.startPointerGrab) and the closing `end` still has to reach
    /// the client whose `begin` is open — the same promise the pointer
    /// path makes about a grab.
    target: ?FocusTarget = null,
    /// Live points the module last saw. It is the record that tells a
    /// motion apart from a finger being added or lifted, so only the
    /// seat emptying the point list clears it.
    count: u32 = 0,
    /// The centroid at the gesture's origin and at the previous touch
    /// event; swipe and pinch deltas are taken against the latter.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    prev_x: i32 = 0,
    prev_y: i32 = 0,
    /// The pinned scale pair, null until a second finger is down.
    pair: ?PinchPair = null,
};

/// Which input owns the seat's single gesture slot. The XML forbids
/// two gestures on one SEAT (XML:99-100, :161-163, :232-236), not two
/// on one device, so a gesture belongs to the source that armed it and
/// the other source is inert until the owner lifts — see the file
/// header's GESTURE SOURCE section, including the correction to the
/// task premise about wlroots.
const Source = enum {
    /// Nothing tracked.
    none,
    /// Held pointer buttons (Seat.pressed_count).
    pointer,
    /// Down touch points (Seat.activeTouchPoints).
    touch,
};

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

/// The seat's TOUCH focus and its client: where a touch gesture is
/// addressed. Touch focus is independent of pointer focus —
/// Seat.touchDown sets it and no pointer button ever does — so this
/// resolves on a seat with no pointer focus at all, which is exactly
/// what a touchscreen-only input looks like.
fn touchFocusTarget(seat: *seat_mod.Seat) ?FocusTarget {
    const focus = seat.touchFocus() orelse return null;
    return .{ .client = focus.resource.getClient(), .surface = focus.resource };
}

/// The detection state machine. The XML forbids two simultaneous gestures
/// on one pointer/seat, so exactly one candidate or gesture exists at a
/// time (XML:96-100).
const Phase = enum {
    /// Nothing tracked.
    idle,
    /// The first button press / first touch point is down; the
    /// candidate has neither begun nor been killed.
    pending,
    /// A hold is active (no update stage, XML:246-248).
    hold,
    /// A swipe is active; motion becomes update.
    swipe,
    /// A pinch is active: the seat's backend pinch API on the pointer
    /// path, the pinned touch pair on the touch path.
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
    /// The seat whose pointer and touchscreen drive the gestures; null
    /// when the compositor has no seat yet — the global still binds and
    /// every gesture object is inert.
    seat: ?*seat_mod.Seat,
    /// The zwp_pointer_gestures_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// Bound zwp_pointer_gestures_v1 resources (one per client bind).
    managers: std.ArrayList(*server.zwp.PointerGesturesV1) = .empty,
    swipes: std.ArrayList(*SwipeState) = .empty,
    pinches: std.ArrayList(*PinchState) = .empty,
    holds: std.ArrayList(*HoldState) = .empty,

    /// Seat motion/button/touch/seat-destroy listeners. They live
    /// exactly as long as the module (removed by setSeat and deinit)
    /// and the module owns the seat pointer they dereference.
    motion_listener: wire.Listener(*seat_mod.Seat),
    button_listener: wire.Listener(*seat_mod.Seat),
    touch_listener: wire.Listener(*seat_mod.Seat),
    seat_destroy_listener: wire.Listener(*seat_mod.Seat),

    // Detection state (see the file header).
    phase: Phase = .idle,
    /// Which input owns the seat's single gesture slot; the other one
    /// is inert until this one lifts (GESTURE SOURCE, file header).
    source: Source = .none,
    /// Press point, in output coordinates.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    /// Previous motion position; swipe update deltas are taken against it.
    prev_x: i32 = 0,
    prev_y: i32 = 0,
    /// The touch path's own bookkeeping, in the same whole-pixel space.
    touch: TouchState = .{},
    /// The target a live POINTER gesture's events are addressed to,
    /// captured when the gesture BEGINS. The seat clears pointer_focus
    /// the moment the pointer leaves every surface (Seat.pointerMotion,
    /// :1125-1126) and when the focused surface is destroyed
    /// (Seat.surfaceDestroyed, :1929), so the closing `end` — and the
    /// updates before it — still have to reach the client whose
    /// `begin` is open, exactly as the touch path already guarantees
    /// through TouchState.target.
    pointer_target: ?FocusTarget = null,
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
            .touch_listener = wire.Listener(*seat_mod.Seat).init(onSeatTouch),
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

    /// Attach (or detach, with null) the seat whose pointer and
    /// touchscreen drive the gestures. Re-attaching the same seat is a
    /// no-op. Detaching ends an active gesture with cancelled = 1 and
    /// drops a pending candidate.
    pub fn setSeat(self: *PointerGestures, seat: ?*seat_mod.Seat) void {
        if (self.seat == seat) return;
        if (self.seat != null) {
            // wire.Signal has no remove(); the links are live exactly
            // while self.seat != null (added below, removed here).
            self.motion_listener.link.remove();
            self.touch_listener.link.remove();
            self.button_listener.link.remove();
            self.seat_destroy_listener.link.remove();
        }
        // Cancel while self.seat is still the old seat: the end event needs
        // its focus and mints a serial from it.
        self.cancel(true);
        self.cancelHoldTimer();
        self.phase = .idle;
        // The touch bookkeeping belongs to the OLD seat's point list,
        // which this module is no longer watching.
        self.touch.count = 0;
        self.seat = seat;
        if (seat) |s| {
            s.events.pointer_move.add(&self.motion_listener);
            s.events.button.add(&self.button_listener);
            s.events.destroy.add(&self.seat_destroy_listener);
            s.events.touch.add(&self.touch_listener);
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
            self.resetGesture();
            return;
        };
        switch (self.phase) {
            .idle => {},
            .pending => self.cancelHoldTimer(),
            .hold => self.sendHoldEnd(seat, cancelled),
            .swipe => self.sendSwipeEnd(seat, cancelled),
            .pinch => self.sendPinchEnd(seat, seat.nowMs(), cancelled),
        }
        self.resetGesture();
    }

    /// Idle and source-less: the state every entry point expects to
    /// find before it arms anything, and the only way the gesture slot
    /// is handed back to the other input source. `touch.count` is
    /// deliberately NOT cleared — it is the module's record of how many
    /// points the last seat notification carried, and only the seat
    /// emptying the point list (handleTouch) may clear it.
    fn resetGesture(self: *PointerGestures) void {
        self.phase = .idle;
        self.source = .none;
        self.pointer_target = null;
        self.touch.target = null;
        self.touch.origin_x = 0;
        self.touch.origin_y = 0;
        self.touch.prev_x = 0;
        self.touch.prev_y = 0;
        self.touch.pair = null;
    }

    /// wlroots wlr_pointer_gestures_v1_send_pinch_begin
    /// (wlr_pointer_gestures_v1.c:160-185). Cancels an active swipe or
    /// hold first — the XML forbids two simultaneous gestures on one
    /// pointer/seat. With no pointer focus nothing is sent and no pinch
    /// becomes active (wlroots :165-170). Under a compositor pointer
    /// grab the whole call is dropped: the grab owns the pointer, so a
    /// pinch would reach a client that received no motion at all.
    ///
    /// This is the POINTER source's pinch (a backend that classifies
    /// gestures from a pointer device, wlroots' own path). A live TOUCH
    /// gesture owns the seat's single gesture slot and is NOT taken
    /// over — the rule is the XML's per-seat rule, not a per-API
    /// exception (XML:99-100, :161-163; see GESTURE SOURCE, file
    /// header).
    pub fn pinchBegin(self: *PointerGestures, time_ms: u32, fingers: u32) void {
        const seat = self.seat orelse return;
        if (self.grabOwned(seat)) return;
        if (self.source == .touch) return;
        self.cancelHoldTimer();
        if (self.phase == .swipe or self.phase == .hold) self.cancel(true);
        const focus = focusTarget(seat) orelse {
            self.resetGesture();
            return;
        };
        self.phase = .pinch;
        self.source = .pointer;
        // Captured for the same reason the touch path captures its
        // target: the seat may drop its pointer focus before pinchEnd
        // arrives, and the end has to reach the client the begin went
        // to.
        self.pointer_target = focus;
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
    /// Dropped under a compositor pointer grab for the same reason
    /// pinchBegin is: the client under the pointer sees no motion, so a
    /// pinch update would describe travel it never witnessed.
    pub fn pinchUpdate(
        self: *PointerGestures,
        time_ms: u32,
        dx: f64,
        dy: f64,
        scale: f64,
        rotation: f64,
    ) void {
        const seat = self.seat orelse return;
        if (self.grabOwned(seat)) return;
        if (self.phase != .pinch) return;
        // A touch pinch is a different gesture driven by touch points;
        // the backend's own pinch may not update it (GESTURE SOURCE).
        if (self.source != .pointer) return;
        const focus = self.gestureTarget(seat) orelse return;
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
    ///
    /// This is the POINTER source's end, like pinchBegin and
    /// pinchUpdate, and the same rule applies: a touch pinch belongs to
    /// the points that armed it and ends when a point lifts, when the
    /// module cancels it, or when a grab takes over. A backend whose
    /// pinch_end arrives while the points own the seat must not close a
    /// gesture it never began — that would end the client's open begin
    /// with a serial and an outcome describing a different gesture.
    pub fn pinchEnd(self: *PointerGestures, time_ms: u32, cancelled: bool) void {
        const seat = self.seat orelse return;
        if (self.phase != .pinch) return;
        if (self.source != .pointer) return;
        self.sendPinchEnd(seat, time_ms, cancelled);
        self.resetGesture();
    }

    /// True while a gesture is being tracked (pending or active). Test and
    /// compositor hooks read this instead of reaching into the state.
    pub fn tracking(self: *const PointerGestures) bool {
        return self.phase != .idle;
    }

    /// A compositor pointer grab owns the whole gesture, so the caller
    /// must report nothing. `Seat.pointerMotion` returns right after the
    /// grab handler and still emits pointer_move (seat.zig:878-881),
    /// `pressed_count` is bumped before the grab branch
    /// (seat.zig:967-970) and `events.button` fires unconditionally
    /// (seat.zig:1066) — while `Seat.pointerButton` sends the client
    /// nothing at all (seat.zig:1013-1023) and a grab never clears
    /// pointer_focus, the only thing `focusTarget` requires. So every
    /// detection entry point gates here, exactly as a pointer
    /// constraint refuses to activate under one (pointer_constraints.zig:432).
    ///
    /// Touch obeys the same gate, by the same mechanism and not by a
    /// second rule: Seat.touchDown / touchMotion / touchUp return before
    /// emitting anything while a grab is installed, and the ONE touch
    /// notification that does arrive under a grab — Seat.startPointerGrab's
    /// close sequence — reaches this function with the grab installed,
    /// so the live gesture is closed once here and nothing else is
    /// reported.
    fn grabOwned(self: *PointerGestures, seat: *seat_mod.Seat) bool {
        if (seat.pointer_grab == null) return false;
        // A gesture live when the grab took over is closed once, here:
        // startPointerGrab synthesized a release for every button the
        // client held (seat.zig:800-823), so the client's gesture is
        // over and an open begin would never be answered.
        self.cancel(true);
        return true;
    }

    // --- detection -----------------------------------------------------

    fn handleButton(self: *PointerGestures, seat: *seat_mod.Seat) void {
        if (self.grabOwned(seat)) return;
        // A touch gesture owns the seat's single gesture slot: the
        // pointer neither starts nor ends one while it runs
        // (GESTURE SOURCE, file header).
        if (self.source == .touch) return;
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
        if (self.grabOwned(seat)) return;
        // Same rule as handleButton: while a touch gesture runs, the
        // pointer moves nobody's gesture.
        if (self.source == .touch) return;
        const x = seat.pointer_x;
        const y = seat.pointer_y;
        switch (self.phase) {
            .idle, .pinch => return,
            .hold => {
                if (atLeast(x, y, self.origin_x, self.origin_y, swipe_threshold_px)) {
                    // "the hold gesture changes into a different type of
                    // gesture" (XML:262-265): the hold is OVER, so close
                    // it before the swipe opens. cancel(true) is the same
                    // handover pinchBegin uses (:358) — it sends
                    // hold.end with cancelled = 1 and leaves the phase
                    // idle, which is the state promoteToSwipe expects,
                    // so NEITHER of its exits (too few fingers, no focus)
                    // can reach a client that still holds an open hold.
                    self.cancel(true);
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
                    self.resetGesture();
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
                    self.resetGesture();
                }
            },
            .swipe => {
                const dx = fixedFromPixels(@as(i64, x) - @as(i64, self.prev_x));
                const dy = fixedFromPixels(@as(i64, y) - @as(i64, self.prev_y));
                self.prev_x = x;
                self.prev_y = y;
                const focus = self.gestureTarget(seat) orelse return;
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
        self.source = .pointer;
        self.origin_x = seat.pointer_x;
        self.origin_y = seat.pointer_y;
        self.prev_x = seat.pointer_x;
        self.prev_y = seat.pointer_y;
        self.startHoldTimer();
    }

    /// Arm the hold delay. Shared by both sources: the timer only ever
    /// runs holdTimeout, which asks the module which source owns the
    /// pending candidate.
    fn startHoldTimer(self: *PointerGestures) void {
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
            self.resetGesture();
            return;
        }
        self.prev_x = seat.pointer_x;
        self.prev_y = seat.pointer_y;
        const focus = focusTarget(seat) orelse {
            self.resetGesture();
            return;
        };
        // The slot is the pointer's for the whole gesture, including
        // when the swipe was promoted out of a live hold — cancel()
        // above cleared the source, and a swipe that did not reclaim
        // it would let a finger re-base a pointer gesture's deltas.
        self.phase = .swipe;
        self.source = .pointer;
        // The client that receives this begin owns the rest of the
        // gesture, updates and end included: the seat can drop its
        // pointer focus mid-swipe, and resolving the target live would
        // then send the end to a client that got no begin.
        self.pointer_target = focus;
        const serial = seat.serialFor(focus.client);
        for (self.swipes.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendBegin(serial, seat.nowMs(), focus.surface, seat.pressed_count);
        }
    }

    // --- touch detection ------------------------------------------------
    //
    // The touch path is the pointer path with two substitutions and no
    // new geometry: the pointer position becomes the live points'
    // centroid, and pressed_count becomes the number of down points.
    // Every comparator below is the pointer path's own
    // squaredDistance / atLeast on whole pixels.

    /// Seat.events.touch fired. The seat has already applied the event:
    /// a down appended its point, a motion moved it, an up removed it,
    /// and a cancel / grab close sequence emptied the list (every one of
    /// Seat.touchDown, touchMotion, touchUp, touchCancel and
    /// Seat.startPointerGrab's close sequence emits). The point COUNT
    /// is therefore the record of what just happened: unchanged means
    /// the fingers moved, changed means one joined or left.
    fn handleTouch(self: *PointerGestures, seat: *seat_mod.Seat) void {
        const points = seat.activeTouchPoints();
        const count: u32 = @intCast(points.len);
        const previous_count = self.touch.count;
        // Synced before the grab gate so the count always matches the
        // seat, including on the close sequence a grab start emits.
        self.touch.count = count;
        if (self.grabOwned(seat)) return;
        // A pointer gesture owns the seat's single gesture slot until
        // it lifts (GESTURE SOURCE, file header).
        if (self.source == .pointer) return;

        if (count == 0) {
            // Every point is gone. EXACTLY ONE of them vanishing in one
            // step is the last finger lifting, which is the XML's own
            // end condition and ends the gesture normally
            // (XML:138-140). Two or more at once is the seat taking the
            // gesture away (touchCancel, the capability drop, the focus
            // surface's death): the client never saw those fingers lift,
            // so it must undo. A single-point teardown is
            // indistinguishable from a lift here and is reported as
            // one, which costs a client nothing: the gesture ends and
            // no update can follow. The one teardown that DOES carry a
            // decision — the grab's close sequence — is decided by
            // grabOwned above, before this branch, because it arrives
            // with the grab already installed.
            const cancelled = previous_count != 1;
            if (self.phase != .idle) self.cancel(cancelled);
            return;
        }

        const centroid = touchCentroid(points);
        // The point SET changed: a finger went down or lifted. That is
        // not travel, so the delta reference is re-based and nothing
        // is sent — a finger joining a swipe must not appear as a jump
        // in its deltas.
        if (count != previous_count) {
            if (self.phase == .idle) {
                // Only the FIRST point of a gesture arms a candidate,
                // exactly as only the 0 -> 1 pressed-button transition
                // arms the pointer one. A second finger raises the
                // count, which is read at emit time. A gesture the
                // module already killed (a warp, a too-few-finger
                // promotion) is NOT re-armed: like the pointer, it
                // needs every finger to lift first.
                if (previous_count == 0 and count == 1) {
                    self.armTouch(centroid);
                } else {
                    self.touch.prev_x = centroid.x;
                    self.touch.prev_y = centroid.y;
                }
                return;
            }
            self.touch.prev_x = centroid.x;
            self.touch.prev_y = centroid.y;
            if (self.phase == .pending) {
                // A candidate measures its travel from where the
                // fingers were LAST put down or lifted, not from the
                // first finger's own position: the second finger
                // landing 100 px away moves the logical center 50 px
                // on its own, which is not the user swiping anything.
                // Once the gesture has begun the origin is history —
                // only the live gesture's own hold slop still reads
                // it — so it is left alone from here.
                self.touch.origin_x = centroid.x;
                self.touch.origin_y = centroid.y;
            }
            self.updateTouchPair(points);
            return;
        }

        // Pure motion: the swipe delta and the pinch scale are both
        // taken against the previous position of THIS point set.
        const from = Point{ .x = self.touch.prev_x, .y = self.touch.prev_y };
        self.touch.prev_x = centroid.x;
        self.touch.prev_y = centroid.y;
        self.touchTravel(seat, points, from, centroid);
    }

    fn armTouch(self: *PointerGestures, at: Point) void {
        self.phase = .pending;
        self.source = .touch;
        self.touch.origin_x = at.x;
        self.touch.origin_y = at.y;
        self.touch.prev_x = at.x;
        self.touch.prev_y = at.y;
        self.touch.target = null;
        self.touch.pair = null;
        self.startHoldTimer();
    }

    fn touchTravel(
        self: *PointerGestures,
        seat: *seat_mod.Seat,
        points: []const seat_mod.TouchPoint,
        from: Point,
        to: Point,
    ) void {
        switch (self.phase) {
            .idle => {},
            .pinch => {
                const spread2 = self.pinchSpread(points) orelse {
                    // The pinned pair is gone between two events: the
                    // scale has no baseline left to be measured from.
                    self.cancel(true);
                    return;
                };
                // Widened BEFORE the subtraction, exactly like the
                // sibling swipe updates at :843-844 and :1115-1116:
                // `to` and `from` are i32 pixels, and the logical
                // center can sit at either end of that range
                // (touchPixel takes the whole range, touchCentroid
                // averages over it), so a center crossing from one end
                // to the other between two pure-motion events does not
                // fit an i32. The .pinch arm has no max_step_px guard —
                // the SLOP bound lives only in .pending (:1081-1087) —
                // so nothing upstream has ruled that step out.
                self.sendTouchPinchUpdate(
                    seat,
                    spread2,
                    @as(i64, to.x) - @as(i64, from.x),
                    @as(i64, to.y) - @as(i64, from.y),
                );
            },
            .hold => {
                if (atLeast(to.x, to.y, self.touch.origin_x, self.touch.origin_y, swipe_threshold_px)) {
                    // Same handover as the pointer path
                    // (handleMotion, .hold): the hold is OVER, so it
                    // closes before the swipe opens (XML:262-265).
                    self.cancel(true);
                    self.promoteTouchToSwipe(seat);
                    return;
                }
                if (atLeast(to.x, to.y, self.touch.origin_x, self.touch.origin_y, hold_slop_px)) {
                    self.cancel(true);
                    return;
                }
            },
            .pending => {
                // SLOP BOUND, the pointer path's rule verbatim: one
                // step this large is a warp, not finger travel.
                if (atLeast(to.x, to.y, from.x, from.y, max_step_px)) {
                    self.cancelHoldTimer();
                    self.resetGesture();
                    return;
                }
                // SWIPE BEFORE PINCH, and the order is the policy: a
                // logical center that has travelled a full swipe
                // threshold is a swipe, whatever the fingers did to
                // their spacing on the way (XML:88-92: a swipe is
                // "fingers moving in the same direction"; XML:151-158:
                // a pinch is "fingers moving towards each other or
                // away from each other"). Two fingers sliding together
                // translate the gesture, and translation is the
                // swipe; a spread change the center did not travel
                // into is the pinch.
                if (atLeast(to.x, to.y, self.touch.origin_x, self.touch.origin_y, swipe_threshold_px)) {
                    self.promoteTouchToSwipe(seat);
                    return;
                }
                if (self.pinchPending(points)) {
                    self.promoteToTouchPinch(seat);
                    return;
                }
                if (atLeast(to.x, to.y, self.touch.origin_x, self.touch.origin_y, hold_slop_px)) {
                    // Moved too far to still be a hold, too little to
                    // be a swipe: this is a drag, not a gesture.
                    self.cancelHoldTimer();
                    self.resetGesture();
                }
            },
            .swipe => {
                const focus = self.gestureTarget(seat) orelse return;
                const dx = fixedFromPixels(@as(i64, to.x) - @as(i64, from.x));
                const dy = fixedFromPixels(@as(i64, to.y) - @as(i64, from.y));
                for (self.swipes.items) |st| {
                    if (st.seat != seat) continue;
                    if (st.res.getClient() != focus.client) continue;
                    st.res.sendUpdate(seat.nowMs(), dx, dy);
                }
            },
        }
    }

    fn promoteTouchToSwipe(self: *PointerGestures, seat: *seat_mod.Seat) void {
        self.cancelHoldTimer();
        // A swipe is multi-finger (XML:88-92, :111-120) and a finger on
        // glass is a POINT: with fewer than min_swipe_fingers live
        // points the travel is a plain drag and no gesture is reported.
        if (self.touch.count < min_swipe_fingers) {
            self.resetGesture();
            return;
        }
        const focus = touchFocusTarget(seat) orelse {
            self.resetGesture();
            return;
        };
        self.touch.target = focus;
        self.phase = .swipe;
        self.source = .touch;
        const serial = seat.serialFor(focus.client);
        for (self.swipes.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendBegin(serial, seat.nowMs(), focus.surface, self.touch.count);
        }
    }

    /// Keep the pinch pair consistent with the live point set. The pair
    /// is pinned when a SECOND finger goes down, because only then does
    /// the gesture have a scale baseline; a set that drops below two
    /// points has none. A third finger joining leaves the baseline
    /// alone — re-pinning it would make the scale jump by the new
    /// point's distance. A live pinch whose pair disappears ends,
    /// because a scale measured against a finger that is no longer
    /// down describes nothing the client can apply.
    fn updateTouchPair(self: *PointerGestures, points: []const seat_mod.TouchPoint) void {
        if (points.len < 2) {
            self.touch.pair = null;
            if (self.phase == .pinch) self.cancel(false);
            return;
        }
        if (self.touch.pair) |pair| {
            // Still both down: keep the baseline.
            if (touchPixelById(points, pair.a) != null and touchPixelById(points, pair.b) != null) return;
            // The pinned PAIR lost a finger while other fingers are
            // still down: the point count is still at least two, so the
            // branch above did not take the gesture down. A live pinch
            // ends here — its scale is ABSOLUTE against begin
            // (XML:200-206), so re-pinning against the survivors would
            // silently divide the next update by a fresh baseline and
            // report a scale the client never pinched to (and a
            // coincident survivor pair pins base_dist2 = 0, which the
            // send helper then reports as 1.0 forever). Re-pinning is
            // only meaningful while the candidate is still PENDING,
            // which has told the client nothing yet.
            if (self.phase == .pinch) {
                self.touch.pair = null;
                self.cancel(false);
                return;
            }
        }
        const a = points[0];
        const b = points[1];
        const dist2 = squaredDistance(
            touchPixel(a.x),
            touchPixel(a.y),
            touchPixel(b.x),
            touchPixel(b.y),
        );
        self.touch.pair = .{
            .a = a.id,
            .b = b.id,
            // Clamped before the conversion for the same reason
            // fixedFromPixels clamps: a saturated u64 distance squares
            // out past i32, and @intFromFloat would trap.
            .base_px = @intFromFloat(std.math.clamp(
                @sqrt(@as(f64, @floatFromInt(dist2))),
                0.0,
                2147483647.0,
            )),
            .base_dist2 = dist2,
        };
    }

    /// True when the pinned fingers have pulled apart (or together) by
    /// at least pinch_threshold_px from the separation they were pinned
    /// at, and there are enough of them for a multi-finger gesture
    /// (XML:151-158). Only a PENDING candidate is asked: once a swipe
    /// or a hold has begun, its events have described translation and
    /// a scale taken from that moment would report travel the client
    /// never saw.
    fn pinchPending(self: *PointerGestures, points: []const seat_mod.TouchPoint) bool {
        if (self.touch.count < min_swipe_fingers) return false;
        const pair = self.touch.pair orelse return false;
        const spread2 = self.pinchSpread(points) orelse return false;
        return pinchSpreadChanged(spread2, pair, pinch_threshold_px);
    }

    /// The pinned pair's exact squared separation, or null when either
    /// point is no longer down.
    fn pinchSpread(self: *const PointerGestures, points: []const seat_mod.TouchPoint) ?u64 {
        const pair = self.touch.pair orelse return null;
        const a = touchPixelById(points, pair.a) orelse return null;
        const b = touchPixelById(points, pair.b) orelse return null;
        return squaredDistance(a.x, a.y, b.x, b.y);
    }

    fn promoteToTouchPinch(self: *PointerGestures, seat: *seat_mod.Seat) void {
        self.cancelHoldTimer();
        if (self.touch.pair == null) {
            self.resetGesture();
            return;
        }
        const focus = touchFocusTarget(seat) orelse {
            self.resetGesture();
            return;
        };
        self.touch.target = focus;
        self.phase = .pinch;
        self.source = .touch;
        const serial = seat.serialFor(focus.client);
        for (self.pinches.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendBegin(serial, seat.nowMs(), focus.surface, self.touch.count);
        }
    }

    /// dx/dy are the logical center's travel since the previous event,
    /// as i64 PIXEL deltas — not i32 ones, because they are the
    /// difference of two i32 centroids and that difference spans twice
    /// the i32 range (see touchTravel's .pinch arm). fixedFromPixels
    /// does the saturating conversion to the 24.8 the wire carries,
    /// exactly like the pointer path's swipe update (XML:191-206).
    /// `scale` is ABSOLUTE against begin (XML:200-206) and is the ratio
    /// of two EXACT squared separations, so it never inherits the
    /// whole-pixel baseline's rounding; a pair pinned coincident has no
    /// scale at all, and the identity is then the only honest value.
    /// `rotation` is zero: a touchscreen reports positions, never an
    /// angle — the same missing rotation source the file header records
    /// for the pointer path.
    fn sendTouchPinchUpdate(self: *PointerGestures, seat: *seat_mod.Seat, spread2: u64, dx: i64, dy: i64) void {
        const focus = self.gestureTarget(seat) orelse return;
        const pair = self.touch.pair orelse return;
        const scale: f64 = if (pair.base_dist2 == 0)
            1.0
        else
            @as(f64, @floatFromInt(spread2)) / @as(f64, @floatFromInt(pair.base_dist2));
        const fdx = fixedFromPixels(dx);
        const fdy = fixedFromPixels(dy);
        const fscale = fixedFromDouble(scale);
        for (self.pinches.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendUpdate(seat.nowMs(), fdx, fdy, fscale, Fixed.fromInt(0));
        }
    }

    /// Where the live gesture's events are addressed. A touch gesture
    /// goes to the TOUCH focus and its client — `Seat.touchFocus()`,
    /// which a finger sets and no pointer button ever sets — so a
    /// touchscreen-only seat with no pointer focus anywhere still
    /// reports gestures. A pointer gesture goes to the pointer focus.
    ///
    /// Both sources then keep the target their gesture BEGAN against,
    /// updates and `end` alike. The seat drops a pointer focus on any
    /// motion that picks nothing (seat.zig:1125-1126) and on the
    /// destruction of the focused surface (seat.zig:1929), and it drops
    /// the touch focus the moment it closes a sequence
    /// (Seat.touchLeave). Resolving live in that window sends the
    /// closing `end` nowhere at all, or to a DIFFERENT client that never
    /// got the `begin` — either way the client's gesture stays open for
    /// the life of the connection, where the XML ends every gesture that
    /// has begun (pointer-gestures-unstable-v1.xml:135-149, :207-222,
    /// :259-272). So the promise is the one this module already makes
    /// about a compositor grab: whatever took the focus away, the client
    /// that was told `begin` is the client that is told `end`.
    ///
    /// The `orelse` fallbacks cover the PRE-BEGIN direction: a pending
    /// candidate has no captured target yet, so the live focus is the
    /// only thing there is to resolve when the hold fires.
    fn gestureTarget(self: *PointerGestures, seat: *seat_mod.Seat) ?FocusTarget {
        return switch (self.source) {
            .touch => self.touch.target orelse touchFocusTarget(seat),
            .pointer => self.pointer_target orelse focusTarget(seat),
            .none => focusTarget(seat),
        };
    }

    fn sendHoldEnd(self: *PointerGestures, seat: *seat_mod.Seat, cancelled: bool) void {
        const focus = self.gestureTarget(seat) orelse return;
        const serial = seat.serialFor(focus.client);
        for (self.holds.items) |st| {
            if (st.seat != seat) continue;
            if (st.res.getClient() != focus.client) continue;
            st.res.sendEnd(serial, seat.nowMs(), @intFromBool(cancelled));
        }
    }

    fn sendSwipeEnd(self: *PointerGestures, seat: *seat_mod.Seat, cancelled: bool) void {
        const focus = self.gestureTarget(seat) orelse return;
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
        const focus = self.gestureTarget(seat) orelse return;
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
/// A grab installed between the arming and this callback owns the input
/// by then, so the candidate is dropped instead of becoming a hold
/// (grabOwned). Which source armed the candidate decides which travel
/// is measured, which target the begin goes to and how many fingers it
/// reports — the same hold, on either input.
fn holdTimeout(self: *PointerGestures) c_int {
    self.cancelHoldTimer();
    const seat = self.seat orelse {
        self.resetGesture();
        return 1;
    };
    if (self.grabOwned(seat)) return 1;
    if (self.phase != .pending) return 1;
    const fingers: u32 = switch (self.source) {
        .pointer => blk: {
            if (atLeast(self.prev_x, self.prev_y, self.origin_x, self.origin_y, hold_slop_px)) return 1;
            break :blk seat.pressed_count;
        },
        .touch => blk: {
            if (atLeast(self.touch.prev_x, self.touch.prev_y, self.touch.origin_x, self.touch.origin_y, hold_slop_px)) return 1;
            break :blk self.touch.count;
        },
        // Nothing armed the candidate; the slot is free for either
        // input again.
        .none => {
            self.resetGesture();
            return 1;
        },
    };
    const focus = self.gestureTarget(seat) orelse {
        self.resetGesture();
        return 1;
    };
    // The begin's client owns the rest of the gesture, the end
    // included: the seat can drop the focus it resolved here before the
    // buttons release, so the capture is what makes hold.end reachable.
    if (self.source == .touch) self.touch.target = focus else self.pointer_target = focus;
    self.phase = .hold;
    const serial = seat.serialFor(focus.client);
    for (self.holds.items) |st| {
        if (st.seat != seat) continue;
        if (st.res.getClient() != focus.client) continue;
        st.res.sendBegin(serial, seat.nowMs(), focus.surface, fingers);
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

fn onSeatTouch(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    const self: *PointerGestures = @fieldParentPtr("touch_listener", listener);
    self.handleTouch(seat);
}

/// The seat is dying: drop it and end any live gesture with cancelled = 1
/// while the seat is still valid (seat.zig:519-525 emits at the top of
/// Seat.deinit, "while the seat memory is still valid").
fn onSeatDestroy(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    _ = seat;
    const self: *PointerGestures = @fieldParentPtr("seat_destroy_listener", listener);
    self.cancel(true);
    self.cancelHoldTimer();
    self.resetGesture();
    // The point count belongs to the seat that is going away.
    self.touch.count = 0;
    // Every link attached while self.seat was non-null goes: the seat is
    // about to free its signal lists and the module may outlive it.
    self.motion_listener.link.remove();
    self.button_listener.link.remove();
    self.touch_listener.link.remove();
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
    /// Needed by every touch test: Seat.touchMotion returns BEFORE it
    /// updates the point and emits events.touch when no wl_touch of
    /// the focus surface's client received the motion, so a client with
    /// no wl_touch is invisible to this module.
    wl_touch: ?*client.wl.Touch = null,
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
            ts.wl_touch = try ts.wl_seat.?.getTouch();
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

    /// `test_pump.dispatchOnce` (whose `timeout_ms` bounds the server
    /// dispatch so a test can wait for the hold timer), then the seat batch
    /// close, then the server flush — so the wl_pointer.frame the close
    /// queues still reaches the client in this roundtrip, as it did before
    /// the shared helper existed. Then a client dispatch.
    fn pumpWith(ts: *TestServer, timeout_ms: c_int) !void {
        try test_pump.dispatchOnce(ts.c_display.?, ts.display.?, timeout_ms);
        if (ts.seat) |s| s.pointerFrame();
        test_pump.flushServers(ts.display.?);
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

    /// Create the test's wl_surface and make the seat's hit test return
    /// it, WITHOUT moving the pointer. Touch tests need the state a
    /// touchscreen-only input produces: a hit-testable surface, a
    /// touch focus and NO pointer focus at all, because Seat.touchDown
    /// never moves the pointer focus.
    fn touchSurface(ts: *TestServer) !*client.wl.Surface {
        const s = try ts.wl_compositor.?.createSurface();
        try ts.pump();
        const surface = ts.compositor.?.surfaces.items[ts.compositor.?.surfaces.items.len - 1];
        ts.surface = s;
        ts.pick_state.surface = surface;
        try ts.pump();
        return s;
    }
};

/// Every seat-backed test needs a real Seat, which needs xkbcommon and a
/// keymap; the seat's own tests skip with the same diagnostic when the
/// keymap source is unavailable. Callers turn the failure into
/// `error.SkipZigTest` rather than a bare `return`, so an environment
/// that cannot run the harness is reported as a skip instead of a pass
/// that asserted nothing (src/buffers/dmabuf.zig does the same).
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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

test "a swipe's end reaches the client that got its begin after the pointer focus is cleared" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    try std.testing.expect(seat.pointer_focus != null);

    // The pointer leaves every surface while both buttons are still
    // held. The seat drops its focus here (Seat.pointerMotion's null-pick
    // branch, seat.zig:1125-1126) — an ordinary motion event, not a
    // grab — so the module has no live focus to resolve any more.
    ts.pick_state.surface = null;
    seat.pointerMotion(400, 400);
    try ts.pump();
    try std.testing.expect(seat.pointer_focus == null);
    try std.testing.expect(ts.gestures.?.tracking());

    // The gesture is still live, and the very motion that took the
    // focus away is still an update for the client that got the begin:
    // it is 400 - 150 px from the promotion point. (Once the focus is
    // already null the seat stops emitting pointer_move altogether —
    // seat.zig:1127-1128 "no focus, no motion target" — so this is the
    // last event that can carry one.)
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expectEqual(@as(i32, 250), ev.last_dx.toInt());

    // Releasing the last button must close the gesture at the client
    // whose begin is open. Resolving the target live would find no
    // focus at all and drop the end, leaving the client's swipe open
    // for the life of the connection.
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(seat.validateEventSerial(ts.client.?, ev.end_serial));
    try std.testing.expect(!ts.gestures.?.tracking());
}

test "a swipe's end reaches the client that got its begin when the focused surface is destroyed" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
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

    // The surface the swipe began on dies under the pointer. This is
    // the second way a focus goes away (Seat.surfaceDestroyed,
    // seat.zig:1929), and the one that arrives with no input event at
    // all: nothing here can be mistaken for a grab.
    const focused = ts.pick_state.surface.?;
    seat.surfaceDestroyed(focused);
    try ts.pump();
    try std.testing.expect(seat.pointer_focus == null);
    try std.testing.expect(ts.gestures.?.tracking());

    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(seat.validateEventSerial(ts.client.?, ev.end_serial));
    try std.testing.expect(!ts.gestures.?.tracking());
}

test "a hold's end reaches the client that got its begin when the focused surface is destroyed" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
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

    // holdTimeout resolved the focus out of the pending candidate, so
    // the hold's end depends on that resolution being captured: the
    // surface can die before the button is released.
    const focused = ts.pick_state.surface.?;
    seat.surfaceDestroyed(focused);
    try ts.pump();
    try std.testing.expect(seat.pointer_focus == null);
    try std.testing.expect(ts.gestures.?.tracking());

    seat.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());
}

test "a pinch's update and end follow its begin when the focused surface is destroyed" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var ev: PinchEvents = .{};
    pinch.setListener(*PinchEvents, PinchEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    const gestures = ts.gestures.?;
    gestures.pinchBegin(1000, 2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);

    const focused = ts.pick_state.surface.?;
    seat.surfaceDestroyed(focused);
    try ts.pump();
    try std.testing.expect(seat.pointer_focus == null);
    try std.testing.expect(gestures.tracking());

    // `scale` is ABSOLUTE against begin (XML:200-206), so an update
    // after the focus is gone must still be the same client's, and the
    // backend's own pinchEnd must still find the client to close.
    gestures.pinchUpdate(1010, 5, 5, 2, 0);
    gestures.pinchEnd(1020, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expectEqual(@as(i32, 5), ev.dx.toInt());
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(!gestures.tracking());
}

test "hold begins after the delay and ends on release" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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

test "a live hold past the slop but short of the swipe threshold is cancelled" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
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

    // A live hold that moves past the slop ends as cancelled (XML:262-265).
    seat.pointerMotion(100 + hold_slop_px + 1, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 1), ev.cancelled);
}

test "a live hold that reaches the swipe threshold ends with hold.end, one finger" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var hold_ev: HoldEvents = .{};
    var swipe_ev: SwipeEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &hold_ev);
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &swipe_ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 1), hold_ev.begins);

    // Past the swipe threshold, but a swipe needs min_swipe_fingers
    // fingers (XML:88-92). The hold is still over: it changes into a
    // different type of gesture, so hold.end MUST go out (XML:262-265)
    // before the travel is reported as the plain drag it is.
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), hold_ev.ends);
    try std.testing.expectEqual(@as(i32, 1), hold_ev.cancelled);
    try std.testing.expectEqual(@as(usize, 0), swipe_ev.begins);
    try std.testing.expect(!ts.gestures.?.tracking());

    // The release that follows ends nothing a second time.
    seat.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), hold_ev.ends);
    try std.testing.expectEqual(@as(usize, 0), swipe_ev.begins);
}

test "a live hold promoted to a swipe ends the hold before the swipe begins" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var hold_ev: HoldEvents = .{};
    var swipe_ev: SwipeEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &hold_ev);
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &swipe_ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 1), hold_ev.begins);
    try std.testing.expectEqual(min_swipe_fingers, @as(u32, hold_ev.fingers));

    // Two fingers plus a full threshold is a promotion. The hold closes
    // FIRST and with cancelled = 1 — swipe.begin while hold.begin is
    // still open is exactly the two-gestures-at-once the XML forbids
    // (XML:96-100, :262-265).
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), hold_ev.ends);
    try std.testing.expectEqual(@as(i32, 1), hold_ev.cancelled);
    try std.testing.expectEqual(@as(usize, 1), swipe_ev.begins);
    try std.testing.expectEqual(min_swipe_fingers, swipe_ev.begin_fingers);
    try std.testing.expect(ts.gestures.?.tracking());

    // The swipe owns the gesture from here; the hold is not ended again.
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), hold_ev.ends);
    try std.testing.expectEqual(@as(usize, 1), swipe_ev.ends);
    try std.testing.expectEqual(@as(i32, 0), swipe_ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());
}

test "a compositor pointer grab reaches no client as a gesture" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var hold_ev: HoldEvents = .{};
    var swipe_ev: SwipeEvents = .{};
    var pinch_ev: PinchEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &hold_ev);
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &swipe_ev);
    pinch.setListener(*PinchEvents, PinchEvents.listener, &pinch_ev);
    try ts.pump();

    const seat = ts.seat.?;
    // The interactive move / camera pan takes the pointer
    // (main.zig:659-662, :2114). The seat keeps emitting pointer_move
    // and button for compositor listeners and keeps pointer_focus, so
    // nothing but the module's own gate stops detection here.
    seat.startPointerGrab(&seat_mod.swallow_pointer_grab);
    try ts.pump();
    try std.testing.expect(seat.pointer_focus != null);
    try std.testing.expect(!ts.gestures.?.tracking());

    // A two-finger press and a full-threshold drag under the grab: the
    // client saw neither the press nor the travel, so no candidate may
    // arm and no swipe may open.
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expect(!ts.gestures.?.tracking());
    try std.testing.expectEqual(@as(usize, 0), swipe_ev.begins);

    // The hold timer would fire hold_threshold_ms after the press: the
    // candidate is gone, so nothing is sent.
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 0), hold_ev.begins);

    // The backend pinch API is gated the same way.
    ts.gestures.?.pinchBegin(2000, 2);
    ts.gestures.?.pinchUpdate(2010, 1, 1, 1, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), pinch_ev.begins);
    try std.testing.expectEqual(@as(usize, 0), pinch_ev.updates);
    try std.testing.expect(!ts.gestures.?.tracking());

    // More travel and the releases change nothing.
    seat.pointerMotion(400, 100);
    seat.pointerButton(seat_mod.btn_right, false);
    seat.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), hold_ev.begins);
    try std.testing.expectEqual(@as(usize, 0), hold_ev.ends);
    try std.testing.expectEqual(@as(usize, 0), swipe_ev.begins);
    try std.testing.expectEqual(@as(usize, 0), swipe_ev.updates);
    try std.testing.expectEqual(@as(usize, 0), pinch_ev.begins);
    try std.testing.expect(!ts.gestures.?.tracking());

    // With the grab released the very same input is detected again: the
    // gate is the grab, not a detector that stopped working.
    seat.endPointerGrab();
    seat.pointerMotion(100, 100);
    try ts.pump();
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), swipe_ev.begins);
    try std.testing.expect(ts.gestures.?.tracking());
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), swipe_ev.ends);
}

test "a grab installed mid-hold closes the open hold exactly once" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
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

    // The compositor takes the pointer mid-hold. startPointerGrab
    // synthesized a release for the button the client held
    // (seat.zig:800-823), so the gesture is over for the client: it is
    // closed here, never abandoned with its begin unanswered. The nudge
    // below stays UNDER hold_slop_px on purpose, so the hold's own
    // slop branch cannot produce that end by accident — only the grab
    // takeover can.
    seat.startPointerGrab(&seat_mod.swallow_pointer_grab);
    seat.pointerMotion(100 + hold_slop_px - 1, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 1), ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());

    // Nothing further is reported for the rest of the grab.
    seat.pointerMotion(300, 100);
    seat.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    // The hold began once and is not begun again for the rest of the grab.
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
}

test "pinch runs on the compositor API with exact 24.8 encoding" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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
    var ts = testServer(allocator) catch return error.SkipZigTest;
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

// ---------------------------------------------------------------------------
// Touch: the same gestures from fingers on glass. See the file header's
// GESTURE SOURCE and TOUCH DETECTION sections for the policy under test.
// ---------------------------------------------------------------------------

test "a two-finger touch swipe reaches the touch-focus client with no pointer at all" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    const surface_res = try ts.touchSurface();
    const seat = ts.seat.?;
    // A touchscreen-only input: no pointer focus anywhere, and a
    // gesture object the client could only create from its wl_pointer
    // (the protocol has no other way to make one).
    try std.testing.expect(seat.pointer_focus == null);

    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();

    // The first finger arms the candidate, the second supplies the
    // fingers a multi-finger swipe needs (XML:88-92). Nothing about
    // this reads pointer_focus or pressed_count.
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 100, 140);
    try std.testing.expect(ts.gestures.?.tracking());
    try std.testing.expect(seat.pointer_focus == null);

    // Travel past the threshold promotes the candidate. The candidate's
    // origin was re-based when the second finger landed, so the travel
    // measured is the logical center's move since then.
    seat.touchMotion(1, 210, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(min_swipe_fingers, ev.begin_fingers);
    try std.testing.expect(ev.begin_surface != null);
    try std.testing.expect(ev.begin_surface.? == surface_res);
    try std.testing.expect(seat.validateEventSerial(ts.client.?, ev.begin_serial));

    // Further travel is an update: the delta of the logical center
    // against the previous event, in exact pixels. Point 2 slides 40 px
    // right while point 1 stays put, so the center moves half of that.
    seat.touchMotion(2, 180, 140);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expectEqual(@as(i32, 40), ev.last_dx.toInt());
    try std.testing.expectEqual(@as(i32, 0), ev.last_dy.toInt());

    // The release of the last point ends it normally: "one or more
    // fingers are lifted" (XML:138-140).
    seat.touchUp(1);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.ends);
    seat.touchUp(2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(seat.validateEventSerial(ts.client.?, ev.end_serial));
    try std.testing.expect(!ts.gestures.?.tracking());
    try std.testing.expect(seat.pointer_focus == null);

    // A motion with no point down reports nothing.
    seat.touchMotion(1, 400, 400);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
}

test "a two-finger touch pinch reports a scale away from 1.0" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.touchSurface();
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var ev: PinchEvents = .{};
    pinch.setListener(*PinchEvents, PinchEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    // 100 px apart: the pair is pinned here and that exact squared
    // separation becomes the denominator of the scale.
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 200, 100);
    try std.testing.expect(ts.gestures.?.tracking());
    try std.testing.expectEqual(@as(usize, 0), ev.begins);

    // Pulling the pair 40 px apart is past pinch_threshold_px and far
    // short of the swipe threshold, so it is a pinch and not a swipe.
    seat.touchMotion(2, 240, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(min_swipe_fingers, ev.fingers);
    try std.testing.expect(ts.gestures.?.tracking());

    // 160 px apart against a 100 px baseline: scale 2.56, which is
    // emphatically not the 1.0 a fresh gesture reports.
    seat.touchMotion(2, 260, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expect(ev.scale.toDouble() > 1.5);
    try std.testing.expectEqual(@as(i32, 655), @as(i32, @intFromEnum(ev.scale)));
    // The logical center still travels: dx is the centroid delta.
    try std.testing.expectEqual(@as(i32, 10), ev.dx.toInt());
    // A touchscreen reports positions, never an angle.
    try std.testing.expectEqual(@as(i32, 0), @as(i32, @intFromEnum(ev.rotation)));

    seat.touchUp(1);
    seat.touchUp(2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());
}

test "a touch pinch ends when the pinned pair lifts while other fingers stay down" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.touchSurface();
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var ev: PinchEvents = .{};
    pinch.setListener(*PinchEvents, PinchEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    // Fingers 1 and 2 land 100 px apart, which pins the pair (1, 2);
    // finger 3 then joins far below, so it changes the logical center
    // but not the baseline (updateTouchPair keeps a pair whose two
    // fingers are still down).
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 200, 100);
    seat.touchDown(3, 150, 500);
    // Pulling the pinned pair 40 px wider is past the pinch threshold
    // and short of the swipe threshold, so the pinch begins at scale
    // against a 100 px baseline.
    seat.touchMotion(2, 240, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    seat.touchMotion(2, 260, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expect(ev.scale.toDouble() > 1.5);

    // Finger 2 — half of the PINNED pair — lifts while fingers 1 and 3
    // are still down. The point count stays at two, so this is not the
    // "fewer than two points" teardown; it is the baseline losing a
    // finger, and `scale` is absolute against begin (XML:200-206).
    // Re-pinning against the survivors would divide the next update by
    // a FRESH baseline and report a scale the client never pinched to.
    seat.touchUp(2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());

    // The survivors keep moving. Nothing may follow the end: a gesture
    // the module closed cannot report another update, and a scale jump
    // would be the client seeing one.
    seat.touchMotion(3, 150, 560);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expectEqual(@as(usize, 1), ev.ends);

    seat.touchUp(1);
    seat.touchUp(3);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expect(!ts.gestures.?.tracking());
}

test "a touch pinch delta across the whole i32 range saturates instead of overflowing" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.touchSurface();
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var ev: PinchEvents = .{};
    pinch.setListener(*PinchEvents, PinchEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    const gestures = ts.gestures.?;
    // A real pinch, begun through the ordinary path, so the update
    // below travels the same send helper every client update does.
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 200, 100);
    seat.touchMotion(2, 240, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(@as(usize, 0), ev.updates);

    // The module's own numeric envelope: touchPixel accepts the whole
    // i32 range and touchCentroid averages over it, so the logical
    // center can sit at either extreme, and a live pinch has no
    // max_step_px guard to rule out the step between them (.pinch has
    // no such check; only .pending does). The seat cannot hand the
    // module such a pair — its own wl_touch encoding saturates long
    // before the pixel range is exhausted — so the two extremes are
    // handed to the travel stage directly, which is exactly the
    // boundary under test: the DELTA between two centers.
    const extremes = [_]seat_mod.TouchPoint{
        .{ .id = 1, .x = -2147483648.0, .y = 0.0 },
        .{ .id = 2, .x = 2147483647.0, .y = 0.0 },
    };
    // Their center is 0: (-2^31 + 2^31 - 1) / 2 truncates toward zero.
    // Measured against the far negative extreme the delta is 2^31,
    // which does not fit an i32: computed in one it is a safety panic
    // in ReleaseSafe and a wrapped negative in ReleaseFast. Widened to
    // i64 first, it saturates at fixedFromPixels' 24.8 ceiling.
    gestures.touchTravel(
        seat,
        &extremes,
        Point{ .x = -2147483648, .y = 0 },
        Point{ .x = 0, .y = 0 },
    );
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.updates);
    try std.testing.expectEqual(@as(i32, (1 << 23) - 1), ev.dx.toInt());
    try std.testing.expectEqual(@as(i32, 0), ev.dy.toInt());
}

test "one touch point never swipes: min_swipe_fingers counts points, not buttons" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.touchSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    // A full swipe-threshold of travel on ONE finger: the step is well
    // under max_step_px, so this is ordinary travel, not a warp, and
    // the promotion is decided purely by the finger count.
    seat.touchDown(1, 100, 100);
    seat.touchMotion(1, 100 + swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.begins);
    try std.testing.expectEqual(@as(usize, 0), ev.updates);
    try std.testing.expect(!ts.gestures.?.tracking());

    // A SECOND finger is what satisfies min_swipe_fingers. The killed
    // candidate is deliberately NOT re-armed by the second finger —
    // the pointer path needs a fresh press too — so lift the first and
    // start again with two points down.
    seat.touchUp(1);
    try ts.pump();
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 100, 140);
    seat.touchMotion(1, 210, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(min_swipe_fingers, ev.begin_fingers);
    try std.testing.expect(ts.gestures.?.tracking());
    seat.touchUp(1);
    seat.touchUp(2);
    try ts.pump();
}

test "touch and pointer cannot run competing gestures at once" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.focusSurface();
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var ev: SwipeEvents = .{};
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    const gestures = ts.gestures.?;

    // --- TOUCH FIRST -------------------------------------------------------
    // Touch owns the seat's single gesture slot.
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 100, 140);
    seat.touchMotion(1, 260, 140);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(@as(usize, 0), ev.ends);
    try std.testing.expect(gestures.tracking());

    // --- POINTER AFTER TOUCH: refused --------------------------------------
    // Two pressed buttons and a full-threshold pointer drag while the
    // touch swipe is live: the pointer arms nothing, promotes nothing
    // and does NOT end the touch gesture.
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + 2 * swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(@as(usize, 0), ev.ends);
    try std.testing.expect(gestures.tracking());

    // Releasing the buttons changes nothing either — a pointer release
    // cannot end a touch gesture.
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(@as(usize, 0), ev.ends);
    try std.testing.expect(gestures.tracking());

    // The touch owner lifts; the slot is free for the pointer again,
    // which proves the gate is the policy and not a dead detector.
    seat.touchUp(1);
    seat.touchUp(2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(!gestures.tracking());

    // --- POINTER FIRST -----------------------------------------------------
    // The other direction, which the run above alone does not prove: the
    // very same two buttons open the ONE swipe the seat admits.
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + 3 * swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ev.begins);
    try std.testing.expect(gestures.tracking());

    // --- TOUCH AFTER POINTER: refused --------------------------------------
    // A fresh two-finger touch swipe reaches no client until the
    // pointer's buttons are released. The touch swipe that ended above
    // already spent `ev.ends`, so the proof is that NONE of the three
    // counters moved — an absolute zero here would be a counter that
    // contradicts the end this same test already observed.
    const ends_before_touch = ev.ends;
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 100, 140);
    seat.touchMotion(1, 260, 140);
    seat.touchMotion(2, 260, 180);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ev.begins);
    try std.testing.expectEqual(@as(usize, 0), ev.updates);
    try std.testing.expectEqual(ends_before_touch, ev.ends);
    try std.testing.expect(gestures.tracking());

    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    seat.touchUp(1);
    seat.touchUp(2);
    try ts.pump();
    try std.testing.expectEqual(ends_before_touch + 1, ev.ends);
    try std.testing.expect(!gestures.tracking());

    // --- AN EXPLICIT CANCEL IS NOT A COMPETING GESTURE ---------------------
    // cancel() is the current gesture ending, not a second one starting,
    // so it must reach the client from EITHER source. A naive early
    // return on the source field would swallow both of these silently.

    // Pointer source: a live swipe closed with cancelled = 1.
    seat.pointerButton(seat_mod.btn_left, true);
    seat.pointerButton(seat_mod.btn_right, true);
    seat.pointerMotion(100 + 4 * swipe_threshold_px, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 3), ev.begins);
    try std.testing.expect(gestures.tracking());
    gestures.cancel(true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 3), ev.ends);
    try std.testing.expectEqual(@as(i32, 1), ev.cancelled);
    try std.testing.expect(!gestures.tracking());
    // The buttons are still held, and a release after the cancel ends
    // nothing: there is no second end for one gesture.
    seat.pointerButton(seat_mod.btn_left, false);
    seat.pointerButton(seat_mod.btn_right, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 3), ev.ends);

    // Touch source: identical, from the other side of the gate.
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 100, 140);
    seat.touchMotion(1, 260, 140);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 4), ev.begins);
    try std.testing.expect(gestures.tracking());
    gestures.cancel(true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 4), ev.ends);
    try std.testing.expectEqual(@as(i32, 1), ev.cancelled);
    try std.testing.expect(!gestures.tracking());
    // Same again for the points: lifting them after the cancel is not a
    // second end.
    seat.touchUp(1);
    seat.touchUp(2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 4), ev.ends);
    try std.testing.expect(!gestures.tracking());
}

test "the backend pinch API cannot close a live touch pinch" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.touchSurface();
    const pinch = try ts.wl_gestures.?.getPinchGesture(ts.wl_pointer.?);
    var ev: PinchEvents = .{};
    pinch.setListener(*PinchEvents, PinchEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    const gestures = ts.gestures.?;

    // The pair is pinned 100 px apart and pulled 40 px wider, so the
    // touch points — not the backend — own the seat's single pinch.
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 200, 100);
    seat.touchMotion(2, 240, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expect(gestures.tracking());

    // All THREE halves of the backend pinch API are the pointer
    // source's, the end included: a pinchEnd that arrived here would
    // close a gesture the backend never began, ending the client's
    // open begin with an outcome that describes a different gesture.
    gestures.pinchBegin(2000, 2);
    gestures.pinchUpdate(2010, 0, 0, 1, 0);
    gestures.pinchEnd(2020, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(@as(usize, 0), ev.updates);
    try std.testing.expectEqual(@as(usize, 0), ev.ends);
    try std.testing.expect(gestures.tracking());

    // The points still own it: the pinned pair's lift ends the pinch
    // exactly once, and the last point adds no second end.
    seat.touchUp(1);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(!gestures.tracking());
    seat.touchUp(2);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expect(!gestures.tracking());
}

test "a compositor pointer grab suppresses touch gestures exactly as it suppresses pointer ones" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.touchSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    const swipe = try ts.wl_gestures.?.getSwipeGesture(ts.wl_pointer.?);
    var hold_ev: HoldEvents = .{};
    var swipe_ev: SwipeEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &hold_ev);
    swipe.setListener(*SwipeEvents, SwipeEvents.listener, &swipe_ev);
    try ts.pump();

    const seat = ts.seat.?;
    // The interactive move / camera pan takes the pointer. Touch shares
    // the grab gate (Seat.startPointerGrab, Seat.touchDown), so the
    // client sees neither the points nor the travel.
    seat.startPointerGrab(&seat_mod.swallow_pointer_grab);
    try ts.pump();

    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 100, 140);
    seat.touchMotion(1, 100 + swipe_threshold_px, 100);
    seat.touchMotion(2, 100 + swipe_threshold_px, 140);
    seat.touchUp(1);
    seat.touchUp(2);
    try ts.pump();
    try std.testing.expect(!ts.gestures.?.tracking());
    try std.testing.expectEqual(@as(usize, 0), swipe_ev.begins);
    try std.testing.expectEqual(@as(usize, 0), swipe_ev.updates);
    try std.testing.expectEqual(@as(usize, 0), swipe_ev.ends);

    // The hold timer would fire hold_threshold_ms after the point went
    // down; no candidate ever armed, so nothing is sent.
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 0), hold_ev.begins);

    // With the grab released the very same input is detected again: the
    // gate is the grab, not a detector that stopped working.
    seat.endPointerGrab();
    seat.touchDown(1, 100, 100);
    seat.touchDown(2, 100, 140);
    seat.touchMotion(1, 260, 140);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), swipe_ev.begins);
    try std.testing.expect(ts.gestures.?.tracking());

    // A grab installed mid-swipe closes the open swipe exactly once,
    // with cancelled = 1 — the seat synthesized an up for every point
    // the client held (Seat.startPointerGrab's close sequence), so
    // leaving the begin unanswered would be the violation this module
    // refuses everywhere else. Identical to the pointer path's
    // mid-hold case.
    seat.startPointerGrab(&seat_mod.swallow_pointer_grab);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), swipe_ev.ends);
    try std.testing.expectEqual(@as(i32, 1), swipe_ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());

    // Nothing further is reported for the rest of the grab.
    seat.touchDown(3, 100, 100);
    seat.touchDown(4, 100, 140);
    seat.touchMotion(3, 400, 400);
    seat.touchUp(3);
    seat.touchUp(4);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), swipe_ev.begins);
    try std.testing.expectEqual(@as(usize, 1), swipe_ev.ends);
}

test "a single touch point holds: the hold comes from fingers too" {
    const allocator = std.testing.allocator;
    var ts = testServer(allocator) catch return error.SkipZigTest;
    defer ts.deinit();

    _ = try ts.touchSurface();
    const hold = try ts.wl_gestures.?.getHoldGesture(ts.wl_pointer.?);
    var ev: HoldEvents = .{};
    hold.setListener(*HoldEvents, HoldEvents.listener, &ev);
    try ts.pump();

    const seat = ts.seat.?;
    seat.touchDown(1, 100, 100);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ev.begins);

    // Wait past the hold delay: the timer fires on the server's loop and
    // reports ONE finger — the live point count, not pressed buttons.
    try ts.pumpWith(2 * @as(c_int, @intCast(hold_threshold_ms)));
    try std.testing.expectEqual(@as(usize, 1), ev.begins);
    try std.testing.expectEqual(@as(u32, 1), ev.fingers);

    // The lift ends it normally.
    seat.touchUp(1);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ev.ends);
    try std.testing.expectEqual(@as(i32, 0), ev.cancelled);
    try std.testing.expect(!ts.gestures.?.tracking());
}
