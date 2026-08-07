//! Damage tracking for the compositor library.
//!
//! M1 scope: a simple region accumulator (list of rects + whole flag).
//! Buffer-age rotation (damage ring) arrives with output rendering (M2).

const std = @import("std");
const geom = @import("geom.zig");
const Rect = geom.Rect;

pub const Damage = struct {
    /// Whole-surface damage (covers any rect); rects is then ignored.
    whole: bool = false,
    /// Accumulated damaged rects, in the damage's coordinate space.
    rects: std.ArrayList(Rect) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Damage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(d: *Damage) void {
        d.rects.deinit(d.allocator);
        d.* = undefined;
    }

    pub fn clear(d: *Damage) void {
        d.whole = false;
        d.rects.clearRetainingCapacity();
    }

    pub fn isEmpty(d: *const Damage) bool {
        return !d.whole and d.rects.items.len == 0;
    }

    /// Add a rect. A rect covering everything degenerates to `whole`.
    pub fn add(d: *Damage, r: Rect) !void {
        if (d.whole) return;
        try d.rects.append(d.allocator, r);
    }

    pub fn addWhole(d: *Damage) void {
        d.whole = true;
        d.rects.clearRetainingCapacity();
    }

    /// Union all accumulated rects into one bounding rect; null when empty.
    pub fn boundingRect(d: *const Damage) ?Rect {
        if (d.whole) return null; // whole has no meaningful bounds
        var out: ?Rect = null;
        for (d.rects.items) |r| {
            out = if (out) |acc| Rect.@"union"(acc, r) else r;
        }
        return out;
    }
};

test "damage accumulate and clear" {
    var d = Damage.init(std.testing.allocator);
    defer d.deinit();

    try std.testing.expect(d.isEmpty());
    try d.add(.{ .x = 0, .y = 0, .width = 4, .height = 4 });
    try d.add(.{ .x = 2, .y = 2, .width = 4, .height = 4 });
    try std.testing.expect(!d.isEmpty());

    const b = d.boundingRect().?;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 6, .height = 6 }, b);

    d.addWhole();
    try std.testing.expect(d.boundingRect() == null);

    d.clear();
    try std.testing.expect(d.isEmpty());
}
