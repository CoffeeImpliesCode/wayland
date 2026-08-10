//! wl_region object state, used by wl_surface.set_opaque_region and
//! wl_surface.set_input_region.
//!
//! M1 keeps the region as a plain list of rectangles (a union of rects);
//! add() compacts on insert (contained/absorbed/edge-aligned rects merge,
//! F43) and subtract() splits rects out of the subtracted area. Overlap
//! is otherwise legal — the region is interpreted as the set union of all
//! listed rects, which the compaction never changes. All edge arithmetic
//! saturates (F41): client-supplied rects may overflow i32 and must never
//! trap the compositor.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const server = @import("protocol").server;

const Rect = geom.Rect;
const Allocator = std.mem.Allocator;

pub const Region = struct {
    allocator: std.mem.Allocator,
    /// The wl_region wire resource; its user data is this Region.
    resource: *server.wl.Region,
    /// The region as a union of rectangles.
    rects: std.ArrayList(Rect) = .empty,

    pub fn create(allocator: std.mem.Allocator, resource: *server.wl.Region) Allocator.Error!*Region {
        const r = try allocator.create(Region);
        errdefer allocator.destroy(r);
        r.* = .{
            .allocator = allocator,
            .resource = resource,
        };
        errdefer r.rects.deinit(allocator);
        resource.setHandler(*Region, handleRequest, handleDestroy, r);
        return r;
    }

    /// Frees the region; called from the wire destructor.
    pub fn deinit(r: *Region) void {
        const allocator = r.allocator;
        r.rects.deinit(allocator);
        allocator.destroy(r);
    }

    /// Add a rectangle to the region (union semantics). The list is
    /// compacted on the way in (F43): a rect contained in an existing one
    /// is dropped, an existing rect contained in the new one is absorbed,
    /// and overlapping or touching rects that share an edge alignment
    /// (same y+height or same x+width) merge into their union. Every
    /// merge preserves the represented set exactly — the merged box equals
    /// the union of its inputs, never a looser bounding box — so a client
    /// re-adding the same area cannot grow the list (wlroots normalizes
    /// via pixman; we compact on insert instead).
    pub fn add(r: *Region, rect: Rect) void {
        if (rect.isEmpty()) return;
        var i: usize = 0;
        var merged = rect;
        while (i < r.rects.items.len) {
            const existing = r.rects.items[i];
            if (contains(existing, merged)) return; // fully covered: drop
            if (contains(merged, existing)) {
                // Absorb the existing rect; `merged` may absorb more.
                _ = r.rects.orderedRemove(i);
                continue;
            }
            if (mergeable(existing, merged)) |combined| {
                merged = combined;
                _ = r.rects.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        r.rects.append(r.allocator, merged) catch r.resource.postNoMemory();
    }

    /// Subtract a rectangle from the region. Every listed rect that
    /// intersects `rect` is replaced by the parts outside the
    /// intersection (left/right/top/bottom); the parts may overlap at the
    /// corners, which is harmless under union semantics. All edge
    /// arithmetic saturates (F41): client rects may overflow i32, and
    /// trapping on them would crash the compositor. On OOM the
    /// subtraction is partial and the client is killed via postNoMemory.
    pub fn subtract(r: *Region, rect: Rect) void {
        if (rect.isEmpty()) return;
        var i: usize = 0;
        while (i < r.rects.items.len) {
            const existing = r.rects.items[i];
            const inter = existing.intersect(rect) orelse {
                i += 1;
                continue;
            };
            _ = r.rects.orderedRemove(i);
            // The parts are disjoint from `rect`, so they never intersect
            // it again and the loop terminates.
            if (inter.x > existing.x) {
                r.appendPart(.{
                    .x = existing.x,
                    .y = existing.y,
                    .width = geom.subSat(inter.x, existing.x),
                    .height = existing.height,
                });
            }
            const right_x = geom.addSat(inter.x, inter.width);
            const existing_right = geom.addSat(existing.x, existing.width);
            if (right_x < existing_right) {
                r.appendPart(.{
                    .x = right_x,
                    .y = existing.y,
                    .width = geom.subSat(existing_right, right_x),
                    .height = existing.height,
                });
            }
            if (inter.y > existing.y) {
                r.appendPart(.{
                    .x = existing.x,
                    .y = existing.y,
                    .width = existing.width,
                    .height = geom.subSat(inter.y, existing.y),
                });
            }
            const bottom_y = geom.addSat(inter.y, inter.height);
            const existing_bottom = geom.addSat(existing.y, existing.height);
            if (bottom_y < existing_bottom) {
                r.appendPart(.{
                    .x = existing.x,
                    .y = bottom_y,
                    .width = existing.width,
                    .height = geom.subSat(existing_bottom, bottom_y),
                });
            }
        }
    }

    /// Bounding box of the region; null when empty. The surface snapshots
    /// opaque/input regions into single rects with this (M1).
    pub fn boundingRect(r: *const Region) ?Rect {
        var out: ?Rect = null;
        for (r.rects.items) |rect| {
            out = if (out) |acc| Rect.@"union"(acc, rect) else rect;
        }
        return out;
    }

    fn appendPart(r: *Region, rect: Rect) void {
        if (rect.isEmpty()) return;
        r.rects.append(r.allocator, rect) catch r.resource.postNoMemory();
    }
};

/// Does `a`'s box fully cover `b`'s box? Edges saturate like the rest of
/// the geometry layer (F41), so a rect spilling past INT32_MAX counts as
/// clipped at the boundary.
fn contains(a: Rect, b: Rect) bool {
    return b.x >= a.x and b.y >= a.y and
        geom.addSat(a.x, a.width) >= geom.addSat(b.x, b.width) and
        geom.addSat(a.y, a.height) >= geom.addSat(b.y, b.height);
}

/// When the union of the two rects equals their bounding box (they
/// overlap or touch along a shared edge alignment), return that bounding
/// box; else null. Same y+height merges horizontally, same x+width
/// vertically. The alignment guarantee is what makes the box exactly the
/// union: no corners are invented.
fn mergeable(a: Rect, b: Rect) ?Rect {
    if (a.y == b.y and a.height == b.height) {
        const a1 = geom.addSat(a.x, a.width);
        const b1 = geom.addSat(b.x, b.width);
        if (b.x > a1 or a.x > b1) return null;
        const x0 = @min(a.x, b.x);
        return .{ .x = x0, .y = a.y, .width = geom.subSat(@max(a1, b1), x0), .height = a.height };
    }
    if (a.x == b.x and a.width == b.width) {
        const a1 = geom.addSat(a.y, a.height);
        const b1 = geom.addSat(b.y, b.height);
        if (b.y > a1 or a.y > b1) return null;
        const y0 = @min(a.y, b.y);
        return .{ .x = a.x, .y = y0, .width = a.width, .height = geom.subSat(@max(a1, b1), y0) };
    }
    return null;
}

fn handleRequest(resource: *server.wl.Region, request: server.wl.Region.Request, region: *Region) void {
    switch (request) {
        .add => |a| region.add(.{ .x = a.x, .y = a.y, .width = a.width, .height = a.height }),
        .subtract => |sub| region.subtract(.{ .x = sub.x, .y = sub.y, .width = sub.width, .height = sub.height }),
        // Destructor requests are dispatched to the handler; the handler
        // must destroy the resource (handleDestroy then runs the teardown).
        .destroy => resource.destroy(),
    }
}

fn handleDestroy(resource: *server.wl.Region, region: *Region) void {
    _ = resource;
    region.deinit();
}

const testing = std.testing;

test "region add and boundingRect" {
    const r = try testing.allocator.create(Region);
    r.* = .{
        .allocator = testing.allocator,
        .resource = @as(*server.wl.Region, @ptrFromInt(0x1)), // dummy: never dereferenced
        // rects defaults to .empty
    };
    defer r.deinit();

    try testing.expect(r.boundingRect() == null);

    r.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    r.add(.{ .x = 20, .y = 0, .width = 5, .height = 5 });
    r.add(.{ .x = 0, .y = 0, .width = 0, .height = 0 }); // empty: ignored

    try testing.expectEqual(@as(usize, 2), r.rects.items.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 25, .height = 10 }, r.boundingRect().?);
}

test "region subtract removes the intersection" {
    const r = try testing.allocator.create(Region);
    r.* = .{
        .allocator = testing.allocator,
        .resource = @as(*server.wl.Region, @ptrFromInt(0x1)),
        // rects defaults to .empty
    };
    defer r.deinit();

    r.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    r.subtract(.{ .x = 3, .y = 3, .width = 4, .height = 4 });

    // Split into left/right/top/bottom; the region still covers the full
    // 10x10 box (corners overlap under union semantics).
    try testing.expectEqual(@as(usize, 4), r.rects.items.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 10, .height = 10 }, r.boundingRect().?);

    // A fully covering subtract empties the region.
    r.subtract(.{ .x = -100, .y = -100, .width = 1000, .height = 1000 });
    try testing.expectEqual(@as(usize, 0), r.rects.items.len);
    try testing.expect(r.boundingRect() == null);
}

test "region subtract with disjoint rect leaves it alone" {
    const r = try testing.allocator.create(Region);
    r.* = .{
        .allocator = testing.allocator,
        .resource = @as(*server.wl.Region, @ptrFromInt(0x1)),
        // rects defaults to .empty
    };
    defer r.deinit();

    r.add(.{ .x = 0, .y = 0, .width = 5, .height = 5 });
    r.subtract(.{ .x = 5, .y = 0, .width = 5, .height = 5 }); // adjacent, no overlap

    try testing.expectEqual(@as(usize, 1), r.rects.items.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 5, .height = 5 }, r.rects.items[0]);
}

test "region add compacts overlapping, contained and adjacent rects (F43)" {
    const r = try testing.allocator.create(Region);
    r.* = .{
        .allocator = testing.allocator,
        .resource = @as(*server.wl.Region, @ptrFromInt(0x1)),
        // rects defaults to .empty
    };
    defer r.deinit();

    // A client re-adding the same area must not grow the list.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        r.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    }
    try testing.expectEqual(@as(usize, 1), r.rects.items.len);

    // A rect contained in an existing one is dropped entirely.
    r.add(.{ .x = 2, .y = 2, .width = 4, .height = 4 });
    try testing.expectEqual(@as(usize, 1), r.rects.items.len);

    // A containing rect absorbs the existing one.
    r.add(.{ .x = 0, .y = 0, .width = 20, .height = 10 });
    try testing.expectEqual(@as(usize, 1), r.rects.items.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 20, .height = 10 }, r.rects.items[0]);

    // Adjacent rects sharing an edge alignment merge into their union.
    r.add(.{ .x = 20, .y = 0, .width = 5, .height = 10 });
    try testing.expectEqual(@as(usize, 1), r.rects.items.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 25, .height = 10 }, r.rects.items[0]);

    // Disjoint rects stay separate: the union is not a bounding box.
    r.add(.{ .x = 100, .y = 100, .width = 5, .height = 5 });
    try testing.expectEqual(@as(usize, 2), r.rects.items.len);

    // Merged sets still subtract correctly: the wide rect splits into
    // two parts around the subtracted band.
    r.subtract(.{ .x = 10, .y = 0, .width = 5, .height = 10 });
    try testing.expectEqual(@as(usize, 3), r.rects.items.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 105, .height = 105 }, r.boundingRect().?);
}

test "region extreme coordinates never trap (F41)" {
    const r = try testing.allocator.create(Region);
    r.* = .{
        .allocator = testing.allocator,
        .resource = @as(*server.wl.Region, @ptrFromInt(0x1)),
    };
    defer r.deinit();

    // Rects whose x + width overflow i32: add, subtract across the
    // boundary and bounding-rect must all saturate instead of trapping.
    r.add(.{ .x = std.math.maxInt(i32) - 1, .y = 0, .width = 10, .height = 10 });
    r.add(.{ .x = std.math.minInt(i32), .y = 0, .width = 5, .height = 10 });
    r.add(.{ .x = std.math.maxInt(i32), .y = std.math.maxInt(i32), .width = 1, .height = 1 });
    r.subtract(.{ .x = std.math.maxInt(i32) - 2, .y = 0, .width = 5, .height = 5 });
    r.subtract(.{ .x = std.math.minInt(i32), .y = std.math.minInt(i32), .width = 2, .height = 2 });
    _ = r.boundingRect();
    // Reaching here without trapping is the assertion; the allocator
    // additionally checks for leaks.
}

test "fuzz region subtract" {
    try testing.fuzz({}, fuzzSubtract, .{});
}

/// Invariant: after subtracting `b`, no listed rect may intersect the
/// interior of `b` (edge contact reports as null via zero-area
/// intersection). Leak-checked by std.testing.allocator.
fn fuzzSubtract(context: void, smith: *testing.Smith) anyerror!void {
    _ = context;
    const r = try testing.allocator.create(Region);
    r.* = .{
        .allocator = testing.allocator,
        .resource = @as(*server.wl.Region, @ptrFromInt(0x1)),
    };
    defer r.deinit();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        // Mix in overflowing rects (F41): the geometry must saturate, and
        // the invariant must still hold because part edges are exact.
        const a = if (i % 8 == 0) randExtremeRect(smith) else randRect(smith);
        const b = if (i % 11 == 0) randExtremeRect(smith) else randRect(smith);
        r.add(a);
        r.subtract(b);
        for (r.rects.items) |part| {
            if (part.intersect(b) != null) return error.SubtractLeftOverlap;
        }
    }
}

fn randRect(smith: *testing.Smith) Rect {
    return .{
        .x = smith.valueRangeLessThan(i32, -100, 101),
        .y = smith.valueRangeLessThan(i32, -100, 101),
        .width = smith.valueRangeLessThan(i32, 0, 51),
        .height = smith.valueRangeLessThan(i32, 0, 51),
    };
}

/// Rects near the i32 boundaries whose edges overflow x + width.
fn randExtremeRect(smith: *testing.Smith) Rect {
    const extremes = [_]i32{
        std.math.maxInt(i32) - 1,
        std.math.maxInt(i32) - 5,
        std.math.minInt(i32) + 1,
        std.math.minInt(i32),
        0,
        -1,
    };
    return .{
        .x = extremes[smith.valueRangeLessThan(u32, 0, @intCast(extremes.len))],
        .y = extremes[smith.valueRangeLessThan(u32, 0, @intCast(extremes.len))],
        .width = smith.valueRangeLessThan(i32, 1, 11),
        .height = smith.valueRangeLessThan(i32, 1, 11),
    };
}
