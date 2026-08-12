//! Damage tracking for the compositor library.
//!
//! `Damage` is a region accumulator (list of rects + whole flag) for a
//! single frame's damage. `DamageRing` adds buffer-age bookkeeping on top
//! (wlr_damage_ring pattern): damage accumulates in `current`, and each
//! `rotate()` ages it into `history` so it survives `num_buffers - 1`
//! further presents before dropping out.

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

/// Union two optional bounding rects; a null operand contributes nothing.
fn unionRects(a: ?Rect, b: ?Rect) ?Rect {
    const ra = a orelse return b;
    const rb = b orelse return ra;
    return Rect.@"union"(ra, rb);
}

/// Damage ring for buffer-age based repaint tracking (wlr_damage_ring
/// pattern, simplified). Damage accumulates in `current`; `rotate()` ages
/// it into `history[0]` and drops the oldest slot, so damage survives
/// `num_buffers - 1` further presents. `num_buffers == 1` disables the
/// history entirely.
pub const DamageRing = struct {
    /// Current frame's accumulated damage.
    current: Damage,
    /// Per-buffer-age historical damage (num_buffers-1 entries).
    history: std.ArrayList(Damage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_buffers: u32) error{OutOfMemory}!DamageRing {
        std.debug.assert(num_buffers >= 1);
        // Reserve the ring slots up front so rotate() (frame-paced) never
        // allocates. The reservation is num_buffers - 1 structs — bounded
        // and tiny; propagate the failure so the caller can unwind (the
        // compositor handles OOM at setup like any other error).
        var history = try std.ArrayList(Damage).initCapacity(allocator, num_buffers - 1);
        // Pre-fill the ring with empty slots: rotate() then only moves
        // Damage values (no growth, no allocation).
        var i: usize = 0;
        while (i < num_buffers - 1) : (i += 1) {
            history.appendAssumeCapacity(Damage.init(allocator));
        }
        return .{
            .current = Damage.init(allocator),
            .history = history,
            .allocator = allocator,
        };
    }

    pub fn deinit(r: *DamageRing) void {
        r.current.deinit();
        for (r.history.items) |*slot| slot.deinit();
        r.history.deinit(r.allocator);
        r.* = undefined;
    }

    /// Accumulate a rect into the current frame's damage.
    pub fn add(r: *DamageRing, rect: geom.Rect) !void {
        try r.current.add(rect);
    }

    /// Damage the whole surface; dominates any partial damage.
    pub fn addWhole(r: *DamageRing) void {
        r.current.addWhole();
    }

    /// Age the frame: current becomes the newest history slot, the oldest
    /// drops out, and current is cleared. Never allocates.
    pub fn rotate(r: *DamageRing) void {
        const n = r.history.items.len;
        if (n == 0) {
            // num_buffers == 1: no history slots; discard the frame's damage.
            r.current.clear();
            return;
        }
        // Drop the oldest slot; this frees the rects it accumulated.
        var oldest = r.history.orderedRemove(n - 1);
        oldest.deinit();
        // Age the current frame into the newest slot. Capacity for
        // num_buffers - 1 entries was reserved by init, so the shift never
        // allocates. The swap is the ownership transfer: the old
        // `current` (with its rects buffer) lands in the history slot,
        // and `current` takes the slot's fresh empty Damage — no handle
        // is dropped without its owner.
        r.history.insertAssumeCapacity(0, Damage.init(r.allocator));
        std.mem.swap(Damage, &r.history.items[0], &r.current);
    }

    /// True when no damage is tracked at all (neither current nor history).
    /// Distinguishes "nothing to repaint" from whole damage, which has no
    /// bounding rect and also makes renderDamage() return null.
    pub fn isEmpty(r: *const DamageRing) bool {
        if (!r.current.isEmpty()) return false;
        for (r.history.items) |*slot| {
            if (!slot.isEmpty()) return false;
        }
        return true;
    }

    /// Damage to repaint for the next present: union of current + ALL
    /// history entries. Null when empty, or when any entry is whole damage
    /// (whole covers the entire surface and has no meaningful bounds —
    /// distinguish from empty via isEmpty() and repaint everything).
    pub fn renderDamage(r: *const DamageRing) ?geom.Rect {
        if (r.current.whole) return null;
        for (r.history.items) |*slot| {
            if (slot.whole) return null;
        }
        var out: ?geom.Rect = null;
        out = unionRects(out, r.current.boundingRect());
        for (r.history.items) |*slot| {
            out = unionRects(out, slot.boundingRect());
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

test "damage ring accumulate and renderDamage bounding" {
    var ring = try DamageRing.init(std.testing.allocator, 3);
    defer ring.deinit();

    try std.testing.expect(ring.isEmpty());
    try std.testing.expect(ring.renderDamage() == null);

    // Two rects in one frame union into their bounding box.
    try ring.add(.{ .x = 0, .y = 0, .width = 4, .height = 4 });
    try ring.add(.{ .x = 2, .y = 2, .width = 4, .height = 4 });
    try std.testing.expect(!ring.isEmpty());
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 6, .height = 6 }, ring.renderDamage().?);

    // Damage from earlier frames still needs repainting until it ages out.
    ring.rotate();
    try ring.add(.{ .x = 10, .y = 0, .width = 2, .height = 2 });
    ring.rotate();
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 12, .height = 6 }, ring.renderDamage().?);

    // One more rotate drops the oldest frame's damage (num_buffers=3).
    ring.rotate();
    try std.testing.expectEqual(Rect{ .x = 10, .y = 0, .width = 2, .height = 2 }, ring.renderDamage().?);
}

test "damage ring rotate ages damage" {
    var ring = try DamageRing.init(std.testing.allocator, 2);
    defer ring.deinit();

    // Frame A is the current damage.
    try ring.add(.{ .x = 0, .y = 0, .width = 4, .height = 4 });
    ring.rotate();
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 4 }, ring.renderDamage().?);

    // Frame B lands while A is still in history: both must be repainted.
    try ring.add(.{ .x = 8, .y = 8, .width = 4, .height = 4 });
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 12, .height = 12 }, ring.renderDamage().?);

    // num_buffers=2 keeps one history slot: B ages in and A drops out.
    ring.rotate();
    try std.testing.expectEqual(Rect{ .x = 8, .y = 8, .width = 4, .height = 4 }, ring.renderDamage().?);
}

test "damage ring addWhole dominates" {
    var ring = try DamageRing.init(std.testing.allocator, 2);
    defer ring.deinit();

    ring.addWhole();
    // Partial additions are ignored while whole damage is set.
    try ring.add(.{ .x = 0, .y = 0, .width = 4, .height = 4 });
    // Whole damage covers the entire surface: no bounding rect, not empty.
    try std.testing.expect(ring.renderDamage() == null);
    try std.testing.expect(!ring.isEmpty());

    // Whole damage ages like any other: it dominates history too.
    ring.rotate();
    try ring.add(.{ .x = 8, .y = 8, .width = 4, .height = 4 });
    try std.testing.expect(ring.renderDamage() == null);

    // After num_buffers-1 rotates it drops out and partials govern again.
    ring.rotate();
    try std.testing.expectEqual(Rect{ .x = 8, .y = 8, .width = 4, .height = 4 }, ring.renderDamage().?);
}

test "damage ring num_buffers=1" {
    var ring = try DamageRing.init(std.testing.allocator, 1);
    defer ring.deinit();

    try ring.add(.{ .x = 0, .y = 0, .width = 4, .height = 4 });
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 4 }, ring.renderDamage().?);

    // No history: rotate discards the current frame's damage.
    ring.rotate();
    try std.testing.expect(ring.renderDamage() == null);
    try std.testing.expect(ring.isEmpty());

    try ring.add(.{ .x = 1, .y = 1, .width = 2, .height = 2 });
    try std.testing.expectEqual(Rect{ .x = 1, .y = 1, .width = 2, .height = 2 }, ring.renderDamage().?);
}

test "damage ring rotate stress" {
    var ring = try DamageRing.init(std.testing.allocator, 4);
    defer ring.deinit();

    // 500 frames mixing whole and partial damage; the allocator detects any
    // leak from dropped slots.
    var frame: usize = 0;
    while (frame < 500) : (frame += 1) {
        if (frame % 10 == 0) {
            ring.addWhole();
        } else {
            try ring.add(.{ .x = @intCast(frame), .y = 0, .width = 1, .height = 1 });
        }
        ring.rotate();
    }

    // The last three frames (498-499 plus the final rect) are partial and
    // still in history; the frame-490 whole damage has aged out.
    try ring.add(.{ .x = 7, .y = 7, .width = 3, .height = 3 });
    ring.rotate();
    const dmg = ring.renderDamage().?;
    try std.testing.expectEqual(Rect{ .x = 7, .y = 0, .width = 493, .height = 10 }, dmg);
    try std.testing.expect(!ring.isEmpty());
}
