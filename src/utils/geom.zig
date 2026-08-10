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
};

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

const std = @import("std");
