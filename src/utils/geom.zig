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
            p.x < r.x + r.width and p.y < r.y + r.height;
    }

    /// Intersection of two rects; null when disjoint.
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.width, b.x + b.width);
        const y1 = @min(a.y + a.height, b.y + b.height);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }

    /// Union of two rects (bounding box).
    pub fn @"union"(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.width, b.x + b.width);
        const y1 = @max(a.y + a.height, b.y + b.height);
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }
};

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
    const r = Rect{ .x = 10, .y = 10, .width = 100, .height = 100 };
    try std.testing.expect(r.containsPoint(.{ .x = 10, .y = 10 }));
    try std.testing.expect(r.containsPoint(.{ .x = 109, .y = 109 }));
    try std.testing.expect(!r.containsPoint(.{ .x = 110, .y = 10 }));
    try std.testing.expect(!r.containsPoint(.{ .x = 10, .y = 110 }));
}

test "rect intersect" {
    const a = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = Rect{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const i = a.intersect(b).?;
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .width = 5, .height = 5 }, i);
    const c = Rect{ .x = 20, .y = 0, .width = 1, .height = 1 };
    try std.testing.expect(a.intersect(c) == null);
}

test "transform sizes" {
    try std.testing.expectEqual(Size{ .w = 10, .h = 20 }, Transform.normal.transformedSize(10, 20));
    try std.testing.expectEqual(Size{ .w = 20, .h = 10 }, Transform.@"90".transformedSize(10, 20));
}

const std = @import("std");
