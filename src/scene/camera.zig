//! Camera for the canvas pass (M4): maps between unbounded world space
//! (f64) and one output viewport (physical px, top-left origin, y down).
//! Math per notes/canvas-compositing.md §1: world→screen is the 2D affine
//!
//!     M = T(W/2, H/2) · S(zoom) · R(−rotation) · T(−center)
//!
//! i.e. p_screen = R(−rotation)·(p_world − center)·zoom + (W/2, H/2), and
//! the inverse is p_world = center + R(rotation)·((p_screen − (W/2,H/2))/zoom)
//! with R(θ) = [cos θ −sin θ; sin θ cos θ] the standard counterclockwise
//! rotation matrix. R(−θ) is R(θ)'s inverse, so the two directions
//! round-trip exactly.
//!
//! Rotation sign convention: `rotation` is in radians; positive rotation
//! is counterclockwise as seen by the viewer — the content rotates
//! counterclockwise on screen (world +y maps toward screen −x).
//! Concretely, at rotation = π/2 the world point just above the viewport
//! center appears at the left edge of the screen.
//!
//! Imports: utils/geom (sibling module).

const std = @import("std");
const testing = std.testing;
const geom = @import("../utils/geom.zig");

const FPoint = geom.FPoint;
const FRect = geom.FRect;

/// A camera view of the canvas onto one output. All fields are f64; the
/// viewport size lives here too so the mapping is self-contained per
/// output (canvas-compositing.md §6: one world, one camera per output).
pub const Camera = struct {
    /// World point shown at the viewport center, in world px.
    center_x: f64,
    center_y: f64,
    /// Scale: 1 world px renders as `zoom` output px (1 = 1:1).
    zoom: f64,
    /// View rotation in radians, positive = counterclockwise (module doc).
    rotation: f64,
    /// Viewport size in output px.
    screen_w: f64,
    screen_h: f64,

    /// Map a world point to viewport px:
    /// p_screen = R(−rotation)·(p_world − center)·zoom + (W/2, H/2).
    pub fn worldToScreen(cam: Camera, wx: f64, wy: f64) FPoint {
        const cos_r = @cos(cam.rotation);
        const sin_r = @sin(cam.rotation);
        const dx = wx - cam.center_x;
        const dy = wy - cam.center_y;
        // R(−θ) = [cos θ  sin θ; −sin θ  cos θ]
        const rx = dx * cos_r + dy * sin_r;
        const ry = -dx * sin_r + dy * cos_r;
        return .{
            .x = rx * cam.zoom + cam.screen_w / 2,
            .y = ry * cam.zoom + cam.screen_h / 2,
        };
    }

    /// Map a viewport px point back to world coords (inverse of
    /// worldToScreen):
    /// p_world = center + R(rotation)·((p_screen − (W/2, H/2)) / zoom).
    pub fn screenToWorld(cam: Camera, sx: f64, sy: f64) FPoint {
        const cos_r = @cos(cam.rotation);
        const sin_r = @sin(cam.rotation);
        const dx = (sx - cam.screen_w / 2) / cam.zoom;
        const dy = (sy - cam.screen_h / 2) / cam.zoom;
        // R(θ) = [cos θ  −sin θ; sin θ  cos θ]
        return .{
            .x = cam.center_x + dx * cos_r - dy * sin_r,
            .y = cam.center_y + dx * sin_r + dy * cos_r,
        };
    }

    /// World-space AABB of the viewport — the culling frustum. At
    /// rotation == 0 this is the exact visible world rect
    /// [center ± (W/2z, H/2z)]; otherwise the 4 screen corners are
    /// back-transformed and their AABB returned, conservative for
    /// rotation (canvas-compositing.md §1).
    pub fn visibleWorldRect(cam: Camera) FRect {
        if (cam.rotation == 0) {
            const hw = cam.screen_w / (2 * cam.zoom);
            const hh = cam.screen_h / (2 * cam.zoom);
            return .{
                .x = cam.center_x - hw,
                .y = cam.center_y - hh,
                .width = cam.screen_w / cam.zoom,
                .height = cam.screen_h / cam.zoom,
            };
        }
        var min_x = std.math.inf(f64);
        var min_y = std.math.inf(f64);
        var max_x = -std.math.inf(f64);
        var max_y = -std.math.inf(f64);
        const corners = [_][2]f64{
            .{ 0, 0 },
            .{ cam.screen_w, 0 },
            .{ 0, cam.screen_h },
            .{ cam.screen_w, cam.screen_h },
        };
        for (corners) |c| {
            const p = cam.screenToWorld(c[0], c[1]);
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }
        return .{
            .x = min_x,
            .y = min_y,
            .width = max_x - min_x,
            .height = max_y - min_y,
        };
    }

    /// True when the camera shows the world unchanged: center at the
    /// origin, zoom 1, no rotation. The viewport size is not part of the
    /// transform, so it is ignored.
    pub fn isIdentity(cam: Camera) bool {
        return cam.center_x == 0 and cam.center_y == 0 and cam.zoom == 1 and cam.rotation == 0;
    }
};

/// Parse the WAYLAND_CAMERA env value "cx=…,cy=…,zoom=…,rot=…" into a
/// Camera. `rot` is in DEGREES and converted to radians; missing fields
/// default to the identity camera's values (center (0,0), zoom 1, rot 0).
/// The viewport size is taken from (w, h): the env string carries no
/// geometry. Returns null when any field is malformed, empty, or unknown;
/// an empty value parses to the identity camera.
pub fn parseEnv(value: []const u8, w: u32, h: u32) ?Camera {
    var cam: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = @floatFromInt(w),
        .screen_h = @floatFromInt(h),
    };
    if (value.len == 0) return cam; // no fields → all identity defaults
    var fields = std.mem.splitScalar(u8, value, ',');
    while (fields.next()) |field| {
        if (field.len == 0) return null; // empty field, e.g. "a,,b" or trailing comma
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return null;
        const key = field[0..eq];
        const val = std.fmt.parseFloat(f64, field[eq + 1 ..]) catch return null;
        if (std.mem.eql(u8, key, "cx")) {
            cam.center_x = val;
        } else if (std.mem.eql(u8, key, "cy")) {
            cam.center_y = val;
        } else if (std.mem.eql(u8, key, "zoom")) {
            cam.zoom = val;
        } else if (std.mem.eql(u8, key, "rot")) {
            cam.rotation = val * (std.math.pi / 180.0);
        } else {
            return null; // unknown key
        }
    }
    return cam;
}

test "camera identity round-trip" {
    const cam: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    try testing.expect(cam.isIdentity());
    // Identity transform: world p renders at screen p + (W/2, H/2).
    const s = cam.worldToScreen(123.0, -456.0);
    try testing.expectEqual(FPoint{ .x = 523.0, .y = -156.0 }, s);
    const w = cam.screenToWorld(s.x, s.y);
    try testing.expectApproxEqAbs(123.0, w.x, 1e-9);
    try testing.expectApproxEqAbs(-456.0, w.y, 1e-9);
}

test "camera zoom round-trip" {
    const cam: Camera = .{
        .center_x = 10,
        .center_y = 20,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    // World (35, 70) is 25 right / 50 below the center → screen (400+50, 300+100).
    const s = cam.worldToScreen(35.0, 70.0);
    try testing.expectEqual(FPoint{ .x = 450.0, .y = 400.0 }, s);
    const w = cam.screenToWorld(s.x, s.y);
    try testing.expectApproxEqAbs(35.0, w.x, 1e-9);
    try testing.expectApproxEqAbs(70.0, w.y, 1e-9);
    // Zoom 2 shows half the world rect.
    try testing.expectEqual(FRect{ .x = -190.0, .y = -130.0, .width = 400.0, .height = 300.0 }, cam.visibleWorldRect());
}

test "camera pan maps center to viewport center" {
    const cam: Camera = .{
        .center_x = -100,
        .center_y = 300,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 640,
        .screen_h = 480,
    };
    const s = cam.worldToScreen(-100.0, 300.0);
    try testing.expectEqual(FPoint{ .x = 320.0, .y = 240.0 }, s);
    const w = cam.screenToWorld(320.0, 240.0);
    try testing.expectApproxEqAbs(-100.0, w.x, 1e-9);
    try testing.expectApproxEqAbs(300.0, w.y, 1e-9);
}

test "camera 90 degree rotation sign" {
    // θ = π/2, positive = content counterclockwise. The screen top-right
    // corner (W, 0) then looks at world center + (H/2z, W/2z):
    // R(π/2)·(W/2z, −H/2z) = (H/2z, W/2z) for the CCW matrix of the module
    // doc. (A clockwise convention would negate both components.)
    const cam: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 1,
        .rotation = std.math.pi / 2.0,
        .screen_w = 800,
        .screen_h = 600,
    };
    const w = cam.screenToWorld(800.0, 0.0);
    try testing.expectApproxEqAbs(300.0, w.x, 1e-9); // H/2z
    try testing.expectApproxEqAbs(400.0, w.y, 1e-9); // W/2z
    // Round trip: that world point renders back at the top-right corner.
    const s = cam.worldToScreen(w.x, w.y);
    try testing.expectApproxEqAbs(800.0, s.x, 1e-9);
    try testing.expectApproxEqAbs(0.0, s.y, 1e-9);
}

test "camera visibleWorldRect at zero rotation" {
    const base: Camera = .{
        .center_x = 10,
        .center_y = 20,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    try testing.expectEqual(
        FRect{ .x = -390.0, .y = -280.0, .width = 800.0, .height = 600.0 },
        base.visibleWorldRect(),
    );
    const zoomed: Camera = .{
        .center_x = 10,
        .center_y = 20,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    try testing.expectEqual(
        FRect{ .x = -190.0, .y = -130.0, .width = 400.0, .height = 300.0 },
        zoomed.visibleWorldRect(),
    );
}

test "camera visibleWorldRect conservative at 45 degrees" {
    // Square viewport: rotating by 45° grows the visible AABB to half-extent
    // 50·√2 ≈ 70.71, so it strictly contains the θ=0 rect.
    const rot: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 1,
        .rotation = std.math.pi / 4.0,
        .screen_w = 100,
        .screen_h = 100,
    };
    const r = rot.visibleWorldRect();
    const half = 50.0 * @sqrt(2.0);
    try testing.expectApproxEqAbs(half, r.width / 2, 1e-9);
    try testing.expectApproxEqAbs(half, r.height / 2, 1e-9);

    const flat: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 100,
        .screen_h = 100,
    };
    const r0 = flat.visibleWorldRect();
    try testing.expect(r.x <= r0.x and r.y <= r0.y);
    try testing.expect(r.x + r.width >= r0.x + r0.width and r.y + r.height >= r0.y + r0.height);
}

test "camera non-trivial round-trip" {
    const cam: Camera = .{
        .center_x = -123.5,
        .center_y = 456.25,
        .zoom = 0.5,
        .rotation = 0.3,
        .screen_w = 1920,
        .screen_h = 1080,
    };
    const points = [_][2]f64{ .{ 0.0, 0.0 }, .{ 1e3, -2e3 }, .{ -7.25, 3.5 }, .{ 1e5, 1e5 } };
    for (points) |p| {
        const s = cam.worldToScreen(p[0], p[1]);
        const w = cam.screenToWorld(s.x, s.y);
        try testing.expectApproxEqAbs(p[0], w.x, 1e-9);
        try testing.expectApproxEqAbs(p[1], w.y, 1e-9);
    }
}

test "camera isIdentity" {
    const id: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    try testing.expect(id.isIdentity());
    // Viewport size does not affect identity; any transform change does.
    const other_w: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 1,
        .screen_h = 1,
    };
    try testing.expect(other_w.isIdentity());
    const shifted: Camera = .{
        .center_x = 1,
        .center_y = 0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    try testing.expect(!shifted.isIdentity());
    const zoomed: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    try testing.expect(!zoomed.isIdentity());
    const rotated: Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 1,
        .rotation = 0.1,
        .screen_w = 800,
        .screen_h = 600,
    };
    try testing.expect(!rotated.isIdentity());
}

test "parseEnv full" {
    const cam = parseEnv("cx=10.5,cy=-20,zoom=2,rot=90", 800, 600).?;
    try testing.expectApproxEqAbs(10.5, cam.center_x, 1e-9);
    try testing.expectApproxEqAbs(-20.0, cam.center_y, 1e-9);
    try testing.expectApproxEqAbs(2.0, cam.zoom, 1e-9);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, cam.rotation, 1e-9); // 90° → radians
    try testing.expectEqual(@as(f64, 800.0), cam.screen_w);
    try testing.expectEqual(@as(f64, 600.0), cam.screen_h);
}

test "parseEnv defaults and empty" {
    const cam = parseEnv("zoom=3", 800, 600).?;
    try testing.expect(!cam.isIdentity());
    try testing.expectApproxEqAbs(0.0, cam.center_x, 1e-9);
    try testing.expectApproxEqAbs(0.0, cam.center_y, 1e-9);
    try testing.expectApproxEqAbs(3.0, cam.zoom, 1e-9);
    try testing.expectApproxEqAbs(0.0, cam.rotation, 1e-9);

    // Empty value: no fields at all → identity camera.
    const id = parseEnv("", 800, 600).?;
    try testing.expect(id.isIdentity());
    try testing.expectEqual(@as(f64, 800.0), id.screen_w);
    try testing.expectEqual(@as(f64, 600.0), id.screen_h);
}

test "parseEnv rejects garbage" {
    try testing.expect(parseEnv("cx=abc", 800, 600) == null); // bad float
    try testing.expect(parseEnv("zoom=", 800, 600) == null); // empty value
    try testing.expect(parseEnv("foo=1", 800, 600) == null); // unknown key
    try testing.expect(parseEnv("=1", 800, 600) == null); // empty key
    try testing.expect(parseEnv("cx=1.5,zoom", 800, 600) == null); // missing '='
    try testing.expect(parseEnv("cx=1.5,,zoom=2", 800, 600) == null); // empty field
    try testing.expect(parseEnv("cx=1.5;zoom=2", 800, 600) == null); // wrong separator
}

test "camera far from the origin keeps sub-pixel world offsets" {
    // A world 5e9 px from the origin, where one f64 ulp is already ~1e-6:
    // an integer world cannot reach this position at all, let alone hold
    // a quarter-pixel offset in it. Both mapping directions carry it.
    const cam: Camera = .{
        .center_x = 5_000_000_000.5,
        .center_y = -5_000_000_000.25,
        .zoom = 0.25,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    // The camera centre is the viewport centre at any world magnitude.
    const c = cam.worldToScreen(cam.center_x, cam.center_y);
    try testing.expectApproxEqAbs(400.0, c.x, 1e-9);
    try testing.expectApproxEqAbs(300.0, c.y, 1e-9);

    // Forward: a quarter world px off the centre is 1/16 of a screen px
    // at this zoom — a whole-pixel result would mean the fraction was
    // dropped on the way out.
    const s = cam.worldToScreen(cam.center_x + 0.25, cam.center_y - 0.5);
    try testing.expectApproxEqAbs(400.0 + 0.0625, s.x, 1e-9);
    try testing.expectApproxEqAbs(300.0 - 0.125, s.y, 1e-9);

    // Inverse: the same point comes back at its offset from the centre,
    // not snapped onto it. The tolerance is the coordinate's own
    // representation resolution at 5e9 (a few ulp) — far tighter than
    // the whole-pixel snap an integer world imposes.
    const w = cam.screenToWorld(s.x, s.y);
    try testing.expectApproxEqAbs(cam.center_x + 0.25, w.x, 1e-4);
    try testing.expectApproxEqAbs(cam.center_y - 0.5, w.y, 1e-4);

    // The culling rect keeps the same fractional edges: zoom 0.25 shows
    // 800/0.25 = 3200 world px across.
    const vis = cam.visibleWorldRect();
    try testing.expectApproxEqAbs(cam.center_x - 1600.0, vis.x, 1e-4);
    try testing.expectApproxEqAbs(cam.center_y - 1200.0, vis.y, 1e-4);
    try testing.expectApproxEqAbs(3200.0, vis.width, 1e-4);
    try testing.expectApproxEqAbs(2400.0, vis.height, 1e-4);
}

test "camera rotated far from the origin: forward and inverse agree within representation error" {
    const cam: Camera = .{
        .center_x = -7_000_000_000.5,
        .center_y = 3_000_000_000.75,
        .zoom = 0.25,
        .rotation = 0.7,
        .screen_w = 1920,
        .screen_h = 1080,
    };
    // At 7e9 one f64 ulp is ~1e-6, so the round trip agrees to a few ulp
    // rather than to the 1e-9 the near-origin cameras reach, and stays
    // orders of magnitude tighter than the whole-pixel resolution an
    // integer world would impose.
    const tol = 1e-4;
    const probes = [_][2]f64{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 1, 1 },
        .{ -1, 1 },
        .{ 0.25, -0.5 },
        .{ 100, -100 },
    };
    for (probes) |d| {
        const wx = cam.center_x + d[0];
        const wy = cam.center_y + d[1];
        const s = cam.worldToScreen(wx, wy);
        const w = cam.screenToWorld(s.x, s.y);
        try testing.expectApproxEqAbs(wx, w.x, tol);
        try testing.expectApproxEqAbs(wy, w.y, tol);
    }

    // Rotation does not snap the offset away: a quarter world px on the
    // x axis lands a quarter zoom px off the viewport centre, rotated.
    const off = cam.worldToScreen(cam.center_x + 0.25, cam.center_y);
    try testing.expectApproxEqAbs(960.0 + 0.25 * 0.25 * @cos(cam.rotation), off.x, 1e-9);
    try testing.expectApproxEqAbs(540.0 - 0.25 * 0.25 * @sin(cam.rotation), off.y, 1e-9);

    // The input path and the cull path read the same transform: every
    // viewport corner back-transforms inside the visible world rect.
    // The margin is a few ulp at this magnitude (re-deriving the AABB
    // edge from min+width rounds), still far below a whole world px.
    const vis = cam.visibleWorldRect();
    const eps = 1e-4;
    const corners = [_][2]f64{
        .{ 0, 0 },
        .{ 1920, 0 },
        .{ 0, 1080 },
        .{ 1920, 1080 },
    };
    for (corners) |k| {
        const corner = cam.screenToWorld(k[0], k[1]);
        try testing.expect(corner.x >= vis.x - eps and corner.x <= vis.x + vis.width + eps);
        try testing.expect(corner.y >= vis.y - eps and corner.y <= vis.y + vis.height + eps);
    }
}
