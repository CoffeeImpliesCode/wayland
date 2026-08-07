//! wl_region object state, used by wl_surface.set_opaque_region and
//! wl_surface.set_input_region.
//!
//! M1 keeps the region as a plain list of rectangles (a union of rects);
//! add() appends and subtract() splits rects out of the subtracted area.
//! Rects are never merged or normalized, and overlapping parts are legal —
//! the region is interpreted as the set union of all listed rects.

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
        r.rects.deinit(r.allocator);
        r.allocator.destroy(r);
    }

    /// Add a rectangle to the region (union semantics).
    pub fn add(r: *Region, rect: Rect) void {
        if (rect.isEmpty()) return;
        r.rects.append(r.allocator, rect) catch r.resource.postNoMemory();
    }

    /// Subtract a rectangle from the region. Every listed rect that
    /// intersects `rect` is replaced by the parts outside the
    /// intersection (left/right/top/bottom); the parts may overlap at the
    /// corners, which is harmless under union semantics. On OOM the
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
                r.appendPart(.{ .x = existing.x, .y = existing.y, .width = inter.x - existing.x, .height = existing.height });
            }
            const right_x = inter.x + inter.width;
            if (right_x < existing.x + existing.width) {
                r.appendPart(.{ .x = right_x, .y = existing.y, .width = existing.x + existing.width - right_x, .height = existing.height });
            }
            if (inter.y > existing.y) {
                r.appendPart(.{ .x = existing.x, .y = existing.y, .width = existing.width, .height = inter.y - existing.y });
            }
            const bottom_y = inter.y + inter.height;
            if (bottom_y < existing.y + existing.height) {
                r.appendPart(.{ .x = existing.x, .y = bottom_y, .width = existing.width, .height = existing.y + existing.height - bottom_y });
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
