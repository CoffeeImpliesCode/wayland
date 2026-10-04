//! Matrix/box transform helpers: wl_output_transform mappings between
//! buffer space and surface space.
//!
//! A transform describes how a buffer's pixels map onto a surface
//! (buffer -> surface). `boxTransform` moves a box the same direction the
//! compositor presents buffers, and `transformPoint` is its exact inverse
//! (surface -> buffer) for hit-testing. Both take `width`/`height` as the
//! *buffer* dimensions; a transform of the 90-degree family therefore puts
//! the result inside a `height` x `width` region on the surface.
//!
//! `boxTransformF` is the f64 twin of `boxTransform` for boxes with a
//! sub-pixel edge, and `surfaceBoxToBuffer` is its inverse direction (a
//! surface-space box back to buffer pixels) — the mapping a renderer
//! texture crop needs, since the crop is named in buffer texels while a
//! wp_viewport source arrives surface-local.
//!
//! `boxTransform` is a 1:1 port of wlrroots' `wlr_box_transform`
//! (freedesktop-wlroots util/box.c:105-145): same switch, same arithmetic.

const std = @import("std");
const geom = @import("geom.zig");

/// Transform a buffer-space box into surface space.
///
/// `width`/`height` are the buffer dimensions. The result is the region the
/// box occupies on the surface after applying `transform`.
pub fn boxTransform(box: geom.Rect, transform: geom.Transform, width: i32, height: i32) geom.Rect {
    var out = box;
    if (transform.is90Degrees()) {
        out.width = box.height;
        out.height = box.width;
    } else {
        out.width = box.width;
        out.height = box.height;
    }

    switch (transform) {
        .normal => {
            out.x = box.x;
            out.y = box.y;
        },
        .@"90" => {
            out.x = height - box.y - box.height;
            out.y = box.x;
        },
        .@"180" => {
            out.x = width - box.x - box.width;
            out.y = height - box.y - box.height;
        },
        .@"270" => {
            out.x = box.y;
            out.y = width - box.x - box.width;
        },
        .flipped => {
            out.x = width - box.x - box.width;
            out.y = box.y;
        },
        .flipped_90 => {
            out.x = box.y;
            out.y = box.x;
        },
        .flipped_180 => {
            out.x = box.x;
            out.y = height - box.y - box.height;
        },
        .flipped_270 => {
            out.x = height - box.y - box.height;
            out.y = width - box.x - box.width;
        },
    }
    return out;
}

/// Transform a FRACTIONAL buffer-space box into surface space: the f64
/// twin of `boxTransform`, for boxes that carry a sub-pixel edge (a
/// wp_viewport source is fractional by protocol). Same switch, same
/// arithmetic, same `width`/`height` meaning (the buffer dimensions).
pub fn boxTransformF(
    box: geom.FRect,
    transform: geom.Transform,
    width: i32,
    height: i32,
) geom.FRect {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    var out = box;
    if (transform.is90Degrees()) {
        out.width = box.height;
        out.height = box.width;
    }
    switch (transform) {
        .normal => {
            out.x = box.x;
            out.y = box.y;
        },
        .@"90" => {
            out.x = h - box.y - box.height;
            out.y = box.x;
        },
        .@"180" => {
            out.x = w - box.x - box.width;
            out.y = h - box.y - box.height;
        },
        .@"270" => {
            out.x = box.y;
            out.y = w - box.x - box.width;
        },
        .flipped => {
            out.x = w - box.x - box.width;
            out.y = box.y;
        },
        .flipped_90 => {
            out.x = box.y;
            out.y = box.x;
        },
        .flipped_180 => {
            out.x = box.x;
            out.y = h - box.y - box.height;
        },
        .flipped_270 => {
            out.x = h - box.y - box.height;
            out.y = w - box.x - box.width;
        },
    }
    return out;
}

/// Transform a surface-space box back into BUFFER space — the exact
/// inverse of `boxTransformF` for the same buffer and transform.
///
/// `width`/`height` are the BUFFER dimensions; the surface-space region
/// the buffer covers is `transform.transformedSize(width, height)`, so
/// that region is what the inverse map is fed. A renderer texture crop
/// is named in buffer pixels, so this is the direction a surface-local
/// wp_viewport source has to travel (see scene/surface_node.zig).
pub fn surfaceBoxToBuffer(
    box: geom.FRect,
    transform: geom.Transform,
    width: i32,
    height: i32,
) geom.FRect {
    const surface = transform.transformedSize(width, height);
    return boxTransformF(box, transform.inverse(), surface.w, surface.h);
}

/// Transform a surface-space point back into buffer space.
///
/// The exact inverse of `boxTransform` at pixel granularity: a surface point
/// inside the transformed buffer region (a `height` x `width` region for the
/// 90-degree family) maps to the buffer pixel whose 1x1 transformed box
/// contains it. The `-1` terms account for a pixel covering `[p, p + 1)`.
pub fn transformPoint(x: i32, y: i32, transform: geom.Transform, width: i32, height: i32) geom.Point {
    return switch (transform) {
        .normal => .{ .x = x, .y = y },
        .@"90" => .{ .x = y, .y = height - 1 - x },
        .@"180" => .{ .x = width - 1 - x, .y = height - 1 - y },
        .@"270" => .{ .x = width - 1 - y, .y = x },
        .flipped => .{ .x = width - 1 - x, .y = y },
        .flipped_90 => .{ .x = y, .y = x },
        .flipped_180 => .{ .x = x, .y = height - 1 - y },
        .flipped_270 => .{ .x = width - 1 - y, .y = height - 1 - x },
    };
}

test "boxTransform: full buffer" {
    // Mandated case: box (0,0,100,50) in a 100x50 buffer. Hand-computed
    // from wlr_box_transform (util/box.c:105-145) with width=100, height=50:
    //   90 family: w/h swap (50x100); each rotation/flip origin evaluates
    //   to 0 because the box spans the full buffer (e.g. 90: x = 50 - 0 - 50,
    //   180: x = 100 - 0 - 100, ...).
    const buffer: geom.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 50 };
    const cases = [_]struct { t: geom.Transform, want: geom.Rect }{
        .{ .t = .normal, .want = .{ .x = 0, .y = 0, .width = 100, .height = 50 } },
        .{ .t = .@"90", .want = .{ .x = 0, .y = 0, .width = 50, .height = 100 } },
        .{ .t = .@"180", .want = .{ .x = 0, .y = 0, .width = 100, .height = 50 } },
        .{ .t = .@"270", .want = .{ .x = 0, .y = 0, .width = 50, .height = 100 } },
        .{ .t = .flipped, .want = .{ .x = 0, .y = 0, .width = 100, .height = 50 } },
        .{ .t = .flipped_90, .want = .{ .x = 0, .y = 0, .width = 50, .height = 100 } },
        .{ .t = .flipped_180, .want = .{ .x = 0, .y = 0, .width = 100, .height = 50 } },
        .{ .t = .flipped_270, .want = .{ .x = 0, .y = 0, .width = 50, .height = 100 } },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.want, boxTransform(buffer, c.t, 100, 50));
    }
}

test "boxTransform: offset box" {
    // Box (10,20,30,15) in a 100x50 buffer: every transform yields a
    // distinct surface box, hand-computed from wlr_box_transform
    // (util/box.c:105-145). Examples:
    //   90:         x = 50 - 20 - 15 = 15,  y = 10
    //   180:        x = 100 - 10 - 30 = 60, y = 50 - 20 - 15 = 15
    //   flipped_90: x = 20, y = 10
    const box: geom.Rect = .{ .x = 10, .y = 20, .width = 30, .height = 15 };
    const cases = [_]struct { t: geom.Transform, want: geom.Rect }{
        .{ .t = .normal, .want = .{ .x = 10, .y = 20, .width = 30, .height = 15 } },
        .{ .t = .@"90", .want = .{ .x = 15, .y = 10, .width = 15, .height = 30 } },
        .{ .t = .@"180", .want = .{ .x = 60, .y = 15, .width = 30, .height = 15 } },
        .{ .t = .@"270", .want = .{ .x = 20, .y = 60, .width = 15, .height = 30 } },
        .{ .t = .flipped, .want = .{ .x = 60, .y = 20, .width = 30, .height = 15 } },
        .{ .t = .flipped_90, .want = .{ .x = 20, .y = 10, .width = 15, .height = 30 } },
        .{ .t = .flipped_180, .want = .{ .x = 10, .y = 15, .width = 30, .height = 15 } },
        .{ .t = .flipped_270, .want = .{ .x = 15, .y = 60, .width = 15, .height = 30 } },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.want, boxTransform(box, c.t, 100, 50));
    }
}

test "transformPoint inverts boxTransform" {
    // For every transform and every buffer pixel, the pixel's surface
    // position (origin of its transformed 1x1 box) maps back to the same
    // pixel. Covers the four corners and the center of a 100x50 buffer.
    const points = [_]geom.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 99, .y = 0 },
        .{ .x = 0, .y = 49 },
        .{ .x = 99, .y = 49 },
        .{ .x = 50, .y = 25 },
    };
    const transforms = [_]geom.Transform{
        .normal,  .@"90",      .@"180",      .@"270",
        .flipped, .flipped_90, .flipped_180, .flipped_270,
    };
    for (transforms) |t| {
        for (points) |p| {
            const surface = boxTransform(.{ .x = p.x, .y = p.y, .width = 1, .height = 1 }, t, 100, 50);
            const back: geom.Point = transformPoint(surface.x, surface.y, t, 100, 50);
            try std.testing.expectEqual(p, back);
        }
    }
}

test "transformPoint: surface -> buffer direction" {
    // Direct surface->buffer mapping on the four rotations, using surface
    // points inside each transformed region. Hand-computed inverse of
    // wlr_box_transform, e.g. 90: surface (25,50) is buffer pixel
    // (50, 50 - 1 - 25) = (50, 24); forward check:
    //   x = 50 - 24 - 1 = 25, y = 50.
    const cases = [_]struct { t: geom.Transform, sx: i32, sy: i32, want: geom.Point }{
        .{ .t = .normal, .sx = 37, .sy = 11, .want = .{ .x = 37, .y = 11 } },
        .{ .t = .@"90", .sx = 25, .sy = 50, .want = .{ .x = 50, .y = 24 } },
        .{ .t = .@"180", .sx = 37, .sy = 11, .want = .{ .x = 62, .y = 38 } },
        .{ .t = .@"270", .sx = 25, .sy = 50, .want = .{ .x = 49, .y = 25 } },
        .{ .t = .flipped, .sx = 37, .sy = 11, .want = .{ .x = 62, .y = 11 } },
        .{ .t = .flipped_90, .sx = 25, .sy = 50, .want = .{ .x = 50, .y = 25 } },
        .{ .t = .flipped_180, .sx = 37, .sy = 11, .want = .{ .x = 37, .y = 38 } },
        .{ .t = .flipped_270, .sx = 25, .sy = 50, .want = .{ .x = 49, .y = 24 } },
    };
    for (cases) |c| {
        const got: geom.Point = transformPoint(c.sx, c.sy, c.t, 100, 50);
        try std.testing.expectEqual(c.want, got);
    }
}

test "surfaceBoxToBuffer inverts boxTransformF for every transform" {
    // Buffer 100x50, an offset fractional buffer box, and every standard
    // transform: the surface box the compositor presents, mapped back,
    // must be the box it started from — the wp_viewport crop depends on
    // exactly this, at sub-pixel precision.
    const buffer: geom.FRect = .{ .x = 10.25, .y = 20.75, .width = 30.5, .height = 15.25 };
    const transforms = [_]geom.Transform{
        .normal,  .@"90",       .@"180",      .@"270",
        .flipped, .flipped_90,  .flipped_180, .flipped_270,
    };
    for (transforms) |t| {
        const surface = boxTransformF(buffer, t, 100, 50);
        const back = surfaceBoxToBuffer(surface, t, 100, 50);
        try std.testing.expectApproxEqRel(buffer.x, back.x, 1e-12);
        try std.testing.expectApproxEqRel(buffer.y, back.y, 1e-12);
        try std.testing.expectApproxEqRel(buffer.width, back.width, 1e-12);
        try std.testing.expectApproxEqRel(buffer.height, back.height, 1e-12);
    }
    // The full buffer maps onto the full surface region in both
    // directions, for every transform (the region the buffer covers is
    // the one the inverse is fed).
    for (transforms) |t| {
        const size = t.transformedSize(100, 50);
        const full: geom.FRect = .{ .x = 0, .y = 0, .width = 100, .height = 50 };
        const surface = boxTransformF(full, t, 100, 50);
        try std.testing.expectEqual(geom.FRect{ .x = 0, .y = 0, .width = size.w, .height = size.h }, surface);
        const back = surfaceBoxToBuffer(surface, t, 100, 50);
        try std.testing.expectEqual(full, back);
    }
    // Rotating swaps the region: a 90-degree surface crop lives in the
    // 50x100 surface region, and its buffer crop lies inside the 100x50
    // buffer. Inverting wlr_box_transform's 90 branch (util/box.c:125-128)
    // on BOXES rather than points — forward s.x = height - b.y - b.h,
    // s.y = b.x, s.w = b.h, s.h = b.w, so b.y = H - s.x - s.WIDTH,
    // b.x = s.y, b.w = s.h, b.h = s.w — for surface (10,10,20,30) in a
    // 50x100 region: b.x = 10, b.y = 50 - 10 - 20 = 20, b.w = 30,
    // b.h = 20. The subtracted term is the surface box's WIDTH: the
    // rotated box's extent along x is the source box's height, so the
    // inverse must consume the extent, never the other axis.
    // Forward check: boxTransformF({10,20,30,20}, .@"90", 100, 50) is
    // x = 50 - 20 - 20 = 10, y = 10, w = 20, h = 30 — the box it came
    // from.
    const crop: geom.FRect = .{ .x = 10, .y = 10, .width = 20, .height = 30 };
    try std.testing.expectEqual(
        geom.FRect{ .x = 10, .y = 20, .width = 30, .height = 20 },
        surfaceBoxToBuffer(crop, .@"90", 100, 50),
    );
}

test "surfaceBoxToBuffer names the buffer pixel transformPoint names" {
    // The two entry points answer the same question at pixel
    // granularity — which buffer pixel a surface pixel shows — through
    // different arithmetic: `transformPoint` is the hand-pinned
    // pixel-granular inverse table of wlr_box_transform, and
    // `surfaceBoxToBuffer` is the box form of the same map. For a unit
    // surface box they must agree on every pixel of the region the
    // buffer covers, for all eight transforms including the flipped
    // ones, whose axis bounds are easy to get subtly wrong.
    const width = 7;
    const height = 3;
    const transforms = [_]geom.Transform{
        .normal,  .@"90",       .@"180",      .@"270",
        .flipped, .flipped_90,  .flipped_180, .flipped_270,
    };
    for (transforms) |t| {
        const region = t.transformedSize(width, height);
        var sy: i32 = 0;
        while (sy < region.h) : (sy += 1) {
            var sx: i32 = 0;
            while (sx < region.w) : (sx += 1) {
                const unit: geom.FRect = .{ .x = @floatFromInt(sx), .y = @floatFromInt(sy), .width = 1, .height = 1 };
                const got = surfaceBoxToBuffer(unit, t, width, height);
                const want = transformPoint(sx, sy, t, width, height);
                std.testing.expectEqual(want.x, @as(i32, @intFromFloat(@floor(got.x)))) catch |err| {
                    std.debug.print("{s} surface ({d}, {d})\n", .{ @tagName(t), sx, sy });
                    return err;
                };
                std.testing.expectEqual(want.y, @as(i32, @intFromFloat(@floor(got.y)))) catch |err| {
                    std.debug.print("{s} surface ({d}, {d})\n", .{ @tagName(t), sx, sy });
                    return err;
                };
            }
        }
    }
}
