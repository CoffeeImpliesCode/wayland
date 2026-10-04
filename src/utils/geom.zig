//! Geometry primitives for the compositor library.
//!
//! Two coordinate spaces:
//! - integer types (i32) for pixel/desktop-space geometry;
//! - float types (f64) for canvas/world-space geometry.
//! Conversions snap to pixels explicitly; never implicitly.

pub const Point = struct { x: i32, y: i32 };

pub const Size = struct { w: i32, h: i32 };

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn empty() Rect {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    pub fn isEmpty(r: Rect) bool {
        return r.width <= 0 or r.height <= 0;
    }

    /// Preserve integer pixel geometry in the scene-space draw API.
    pub fn toFloatRect(r: Rect) FRect {
        return .{
            .x = @floatFromInt(r.x),
            .y = @floatFromInt(r.y),
            .width = @floatFromInt(r.width),
            .height = @floatFromInt(r.height),
        };
    }

    pub fn containsPoint(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and
            p.x < addSat(r.x, r.width) and p.y < addSat(r.y, r.height);
    }

    /// Intersection of two rects; null when disjoint. All arithmetic is
    /// saturating: a rect edge past the i32 range is treated as clipped at
    /// the i32 boundary (F41). Client-supplied rects (wl_region, damage)
    /// can carry x + width that overflows i32; trapping on them would
    /// crash the compositor. Matches pixman's int64-in/int32-out region
    /// math and the saturating damage helpers in surface.zig.
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(addSat(a.x, a.width), addSat(b.x, b.width));
        const y1 = @min(addSat(a.y, a.height), addSat(b.y, b.height));
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .width = subSat(x1, x0), .height = subSat(y1, y0) };
    }

    /// Union of two rects (bounding box). Saturating like intersect: a
    /// rect extending past INT32_MAX unions to a box clipped at the i32
    /// boundary instead of trapping (F41).
    pub fn @"union"(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(addSat(a.x, a.width), addSat(b.x, b.width));
        const y1 = @max(addSat(a.y, a.height), addSat(b.y, b.height));
        return .{ .x = x0, .y = y0, .width = subSat(x1, x0), .height = subSat(y1, y0) };
    }
};

/// Saturated i32 add: on overflow the result clamps to the i32 boundary
/// instead of trapping (client-controlled geometry, F41).
pub fn addSat(a: i32, b: i32) i32 {
    return std.math.add(i32, a, b) catch blk: {
        break :blk if (b < 0) std.math.minInt(i32) else std.math.maxInt(i32);
    };
}

/// Saturated i32 subtract: on underflow the result clamps to the i32
/// boundary (client-controlled geometry, F41).
pub fn subSat(a: i32, b: i32) i32 {
    return std.math.sub(i32, a, b) catch blk: {
        break :blk if (a < b) std.math.minInt(i32) else std.math.maxInt(i32);
    };
}

pub const FPoint = struct { x: f64, y: f64 };

pub const FSize = struct { w: f64, h: f64 };

pub const FRect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn isEmpty(r: FRect) bool {
        return !(r.width > 0) or !(r.height > 0);
    }

    pub fn right(r: FRect) f64 {
        return r.x + r.width;
    }

    pub fn bottom(r: FRect) f64 {
        return r.y + r.height;
    }

    /// Half-open containment (the left/top edge is inside, the
    /// right/bottom edge is not), matching Rect.containsPoint so a
    /// fractional world edge never snaps to a whole pixel.
    pub fn containsPoint(r: FRect, x: f64, y: f64) bool {
        return x >= r.x and y >= r.y and x < r.right() and y < r.bottom();
    }

    pub fn intersects(a: FRect, b: FRect) bool {
        return a.intersect(b) != null;
    }

    /// Intersection in world space; null when disjoint. Empty rects
    /// intersect nothing (they carry no area).
    pub fn intersect(a: FRect, b: FRect) ?FRect {
        if (a.isEmpty() or b.isEmpty()) return null;
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (!(x1 > x0) or !(y1 > y0)) return null;
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }

    /// The pixel box this rect covers: the origin floors and the far
    /// edges ceil, so every touched pixel is inside the result and no
    /// fractional world edge is lost. Both conversions SATURATE at the
    /// i32 boundary — a world rect can sit arbitrarily far from the
    /// origin, and narrowing it must never trap (F41).
    ///
    /// Callers clip to the output screen in f64 BEFORE converting (see
    /// SceneOutput.projectWorldRect): converting a rect 1e9 px away from
    /// the screen first saturates it onto the screen edge and would
    /// report damage the output never had.
    pub fn toPixelRect(r: FRect) Rect {
        const x0 = floorToI32(r.x);
        const y0 = floorToI32(r.y);
        const x1 = ceilToI32(r.right());
        const y1 = ceilToI32(r.bottom());
        return .{
            .x = x0,
            .y = y0,
            // Saturating, and never negative: a rect wider than the i32
            // range (its ends clamped to the boundaries) clamps its width
            // rather than wrapping (F41), and a degenerate rect (no
            // positive extent) contributes no pixels.
            .width = if (x1 > x0) subSat(x1, x0) else 0,
            .height = if (y1 > y0) subSat(y1, y0) else 0,
        };
    }
};

/// Floor f64 -> i32, saturating instead of trapping (F41): client
/// geometry and world coordinates reach far past the i32 range.
pub fn floorToI32(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(@min(@max(@floor(v), @as(f64, std.math.minInt(i32))), @as(f64, std.math.maxInt(i32))));
}

/// Ceil f64 -> i32, saturating instead of trapping (F41).
pub fn ceilToI32(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(@min(@max(@ceil(v), @as(f64, std.math.minInt(i32))), @as(f64, std.math.maxInt(i32))));
}

/// wl_output_transform mapping (values match the protocol enum).
pub const Transform = enum(u32) {
    normal = 0,
    @"90" = 1,
    @"180" = 2,
    @"270" = 3,
    flipped = 4,
    flipped_90 = 5,
    flipped_180 = 6,
    flipped_270 = 7,

    pub fn isFlipped(t: Transform) bool {
        return @intFromEnum(t) >= 4;
    }

    pub fn is90Degrees(t: Transform) bool {
        return t == .@"90" or t == .@"270" or t == .flipped_90 or t == .flipped_270;
    }

    /// Size after applying the transform.
    pub fn transformedSize(t: Transform, w: i32, h: i32) Size {
        return if (t.is90Degrees()) .{ .w = h, .h = w } else .{ .w = w, .h = h };
    }

    /// The transform that undoes `t` (buffer -> surface becomes
    /// surface -> buffer). The flips and the 180 rotation are
    /// self-inverse; 90 and 270 swap. utils/matrix.zig pins the claim:
    /// its inverse round-trip test maps a box through `t` and back
    /// through `t.inverse()` for all eight transforms.
    pub fn inverse(t: Transform) Transform {
        return switch (t) {
            .@"90" => .@"270",
            .@"270" => .@"90",
            else => t,
        };
    }
};

test "rect contains" {
    const r: Rect = .{ .x = 10, .y = 10, .width = 100, .height = 100 };
    try std.testing.expect(r.containsPoint(.{ .x = 10, .y = 10 }));
    try std.testing.expect(r.containsPoint(.{ .x = 109, .y = 109 }));
    try std.testing.expect(!r.containsPoint(.{ .x = 110, .y = 10 }));
    try std.testing.expect(!r.containsPoint(.{ .x = 10, .y = 110 }));
}

test "rect intersect" {
    const a: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b: Rect = .{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const i = a.intersect(b).?;
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .width = 5, .height = 5 }, i);
    const c: Rect = .{ .x = 20, .y = 0, .width = 1, .height = 1 };
    try std.testing.expect(a.intersect(c) == null);
}

test "rect intersect saturates on client-controlled overflow (F41)" {
    // x + width past INT32_MAX used to trap in the naive formulation;
    // these rects come straight from wl_region.add / wl_surface.damage.
    const a: Rect = .{ .x = std.math.maxInt(i32) - 1, .y = 0, .width = 10, .height = 10 };
    const b: Rect = .{ .x = std.math.maxInt(i32) - 2, .y = 0, .width = 100, .height = 10 };
    // Both right edges saturate to INT32_MAX; the intersection spans from
    // the larger left edge to the boundary.
    const i = a.intersect(b).?;
    try std.testing.expectEqual(std.math.maxInt(i32) - 1, i.x);
    try std.testing.expectEqual(@as(i32, 1), i.width);

    // Leftward overflow (x + width below INT32_MIN) saturates too.
    const c: Rect = .{ .x = std.math.minInt(i32) + 1, .y = 0, .width = -10, .height = 10 };
    const d: Rect = .{ .x = std.math.minInt(i32), .y = 0, .width = 5, .height = 10 };
    try std.testing.expect(c.intersect(d) == null);
    // Union of a rect spilling past INT32_MAX with a negative one: the
    // result width clamps instead of overflowing.
    const u = Rect.@"union"(
        .{ .x = std.math.maxInt(i32) - 1, .y = 0, .width = 10, .height = 10 },
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    );
    try std.testing.expectEqual(std.math.maxInt(i32), u.width);
    try std.testing.expectEqual(@as(i32, 0), u.x);
}

test "rect containsPoint saturates on overflow (F41)" {
    const r: Rect = .{ .x = std.math.maxInt(i32) - 1, .y = 0, .width = 10, .height = 10 };
    // The saturated box ends at INT32_MAX (exclusive): the boundary point
    // is outside, near-boundary points inside — and nothing traps.
    try std.testing.expect(!r.containsPoint(.{ .x = std.math.maxInt(i32), .y = 0 }));
    try std.testing.expect(r.containsPoint(.{ .x = std.math.maxInt(i32) - 1, .y = 0 }));
}

test "transform sizes" {
    try std.testing.expectEqual(Size{ .w = 10, .h = 20 }, Transform.normal.transformedSize(10, 20));
    try std.testing.expectEqual(Size{ .w = 20, .h = 10 }, Transform.@"90".transformedSize(10, 20));
}

test "FRect containment is half-open at fractional world edges" {
    const r: FRect = .{ .x = 4.5, .y = 24.5, .width = 20, .height = 8 };
    // Inside: the left/top edge itself, and any world point up to the
    // far edges.
    try std.testing.expect(r.containsPoint(4.5, 24.5));
    try std.testing.expect(r.containsPoint(15.0, 30.0));
    // Outside: the right/bottom edges are not inside (half-open), and a
    // quarter world px outside the left edge is outside — no rounding of
    // the edge down to a whole pixel.
    try std.testing.expect(!r.containsPoint(24.5, 30.0));
    try std.testing.expect(!r.containsPoint(15.0, 32.5));
    try std.testing.expect(!r.containsPoint(4.25, 30.0));
    try std.testing.expect(!r.containsPoint(15.0, 24.25));
}

test "FRect intersect keeps fractional world edges" {
    const a: FRect = .{ .x = 4.5, .y = 4.5, .width = 20, .height = 20 };
    const b: FRect = .{ .x = 12.5, .y = 12.5, .width = 20, .height = 20 };
    const i = a.intersect(b).?;
    try std.testing.expectEqual(FRect{ .x = 12.5, .y = 12.5, .width = 12.0, .height = 12.0 }, i);
    // Touching but not overlapping: no area, no intersection.
    const touch: FRect = .{ .x = 24.5, .y = 4.5, .width = 5, .height = 5 };
    try std.testing.expect(a.intersect(touch) == null);
    // An empty rect covers nothing, not even a point inside it.
    const empty: FRect = .{ .x = 4.5, .y = 4.5, .width = 0, .height = 20 };
    try std.testing.expect(empty.isEmpty());
    try std.testing.expect(a.intersect(empty) == null);
}

test "FRect toPixelRect floors the origin, ceils the far edges, saturates far away" {
    // A world rect a third of a pixel in on every edge covers exactly
    // the one pixel box that contains it.
    const r: FRect = .{ .x = 10.25, .y = 20.75, .width = 3.5, .height = 2.5 };
    try std.testing.expectEqual(
        Rect{ .x = 10, .y = 20, .width = 4, .height = 4 },
        r.toPixelRect(),
    );
    // Pixel-aligned: an exact integer rect is its own pixel box.
    const aligned: FRect = .{ .x = 10, .y = 20, .width = 4, .height = 4 };
    try std.testing.expectEqual(
        Rect{ .x = 10, .y = 20, .width = 4, .height = 4 },
        aligned.toPixelRect(),
    );
    // Far past the i32 range: saturation, never a trap. The rect starts
    // beyond INT32_MAX and ends further out still, so both edges clamp
    // to the boundary and the width collapses to zero.
    const far: FRect = .{ .x = 1e12, .y = -1e12, .width = 10, .height = 10 };
    const clipped = far.toPixelRect();
    try std.testing.expectEqual(std.math.maxInt(i32), clipped.x);
    try std.testing.expectEqual(std.math.minInt(i32), clipped.y);
    try std.testing.expectEqual(@as(i32, 0), clipped.width);
    try std.testing.expectEqual(@as(i32, 0), clipped.height);
    // A rect spanning the WHOLE i32 range: its ends clamp to the
    // boundaries and the width is the saturated difference, not a wrap
    // (INT32_MAX - INT32_MIN is 2^32 - 1, which does not fit i32).
    const whole: FRect = .{
        .x = -3e9,
        .y = -3e9,
        .width = 6e9,
        .height = 6e9,
    };
    const full = whole.toPixelRect();
    try std.testing.expectEqual(std.math.minInt(i32), full.x);
    try std.testing.expectEqual(std.math.minInt(i32), full.y);
    try std.testing.expectEqual(std.math.maxInt(i32), full.width);
    try std.testing.expectEqual(std.math.maxInt(i32), full.height);
    // Invalid geometry covers no pixels; do not pin the representation
    // of an empty rectangle.
    try std.testing.expect((FRect{
        .x = std.math.nan(f64), .y = 0, .width = 1, .height = 1,
    }).toPixelRect().isEmpty());
}

test "Transform.inverse undoes every standard transform" {
    // The 90-degree family swaps; the flips and 180 are their own
    // inverse. Rotating by 90 and by 270 must disagree.
    try std.testing.expectEqual(Transform.normal, Transform.normal.inverse());
    try std.testing.expectEqual(Transform.@"180", Transform.@"180".inverse());
    try std.testing.expectEqual(Transform.flipped, Transform.flipped.inverse());
    try std.testing.expectEqual(Transform.flipped_90, Transform.flipped_90.inverse());
    try std.testing.expectEqual(Transform.flipped_180, Transform.flipped_180.inverse());
    try std.testing.expectEqual(Transform.flipped_270, Transform.flipped_270.inverse());
    try std.testing.expectEqual(Transform.@"270", Transform.@"90".inverse());
    try std.testing.expectEqual(Transform.@"90", Transform.@"270".inverse());
    // Involutive: inverting twice is the identity transform.
    const all = [_]Transform{
        .normal,       .@"90",       .@"180",      .@"270",
        .flipped,     .flipped_90,  .flipped_180, .flipped_270,
    };
    for (all) |t| try std.testing.expectEqual(t, t.inverse().inverse());
}

const std = @import("std");
