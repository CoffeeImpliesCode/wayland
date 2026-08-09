//! Canvas pass rasterizer (M4): camera-transformed, bilinearly-sampled
//! texture compositing into a pixman framebuffer.
//!
//! Each CanvasItem stamps a texture into a world-space rect. The
//! rasterizer maps the rect through the Camera (worldToScreen), takes the
//! screen-space AABB of the transformed quad, floors/ceils it to integer
//! pixels and clips it to the framebuffer (off-screen culling; per-pixel
//! (u,v) rejection handles the rest of the quad's bounding box). Every
//! covered pixel then inverts the transform (screenToWorld) to find its
//! world point, computes item-local texture coordinates (u, v) and
//! bilinearly samples the texture.
//!
//! Conventions:
//! - Draw order: items composite in array order — each item draws over
//!   all earlier items. The wiring passes items back-to-front
//!   (bottom-most first); the last item in the array is topmost.
//! - Sampling: a pixel at (x, y) samples the texture at its top-left
//!   corner, with texel coordinate (u * width, v * height) — texel (i, j)
//!   spans [i, i+1) in texel space. A texture stamped 1:1 onto world
//!   pixels (identity mapping) therefore lands texel (i, j) on screen
//!   pixel (i, j) exactly.
//! - Blending is premultiplied-over (the wlroots premultiplied
//!   convention, include/wlr/render/pass.h): out = src_premul +
//!   dst * (1 - src_a) per channel, alpha included. Opaque pixels
//!   (a = 255, opacity = 1) are exact copies.
//!
//! Imports: utils/geom, scene/camera, renderer/{pixman,texture}.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const camera_mod = @import("../scene/camera.zig");
const pixman = @import("pixman.zig");
const texture_mod = @import("texture.zig");
const log_mod = @import("../utils/log.zig"); // tests only

const Camera = camera_mod.Camera;

/// A texture stamped into a world-space rect, composited with `opacity`
/// (0..1) over whatever is already in the framebuffer.
pub const CanvasItem = struct {
    texture: *texture_mod.Texture,
    world_x: f64,
    world_y: f64,
    world_w: f64,
    world_h: f64,
    opacity: f32,
};

/// The pixman texture payload (src/renderer/pixman.zig:
/// `PixmanTextureData`, an `extern struct`): `pixels` holds ARGB8888 rows
/// in memory byte order B,G,R,A and `stride` is the bytes-per-row pitch.
/// Casting to pixman's own type (not a local mirror) keeps one definition
/// of the layout — the extern struct pins C-ABI offsets, so the cast is a
/// contract, not a layout coincidence.
/// Composite `items` into `fb` through `camera` (module doc: draw order,
/// sampling and blend conventions). `allocator` is reserved — the
/// rasterizer is allocation-free today.
pub fn render(
    allocator: std.mem.Allocator,
    fb: *pixman.Framebuffer,
    camera: *const Camera,
    items: []const CanvasItem,
) void {
    _ = allocator;
    for (items) |item| {
        // `!(opacity > 0)` also skips NaN opacity.
        if (!(item.opacity > 0) or item.world_w <= 0 or item.world_h <= 0) continue;
        if (item.texture.width <= 0 or item.texture.height <= 0) continue;
        drawItem(fb, camera, item);
    }
}

fn drawItem(fb: *pixman.Framebuffer, camera: *const Camera, item: CanvasItem) void {
    // Transformed quad and its screen-space AABB.
    const corners = [4]geom.FPoint{
        camera.worldToScreen(item.world_x, item.world_y),
        camera.worldToScreen(item.world_x + item.world_w, item.world_y),
        camera.worldToScreen(item.world_x, item.world_y + item.world_h),
        camera.worldToScreen(item.world_x + item.world_w, item.world_y + item.world_h),
    };
    var min_x = corners[0].x;
    var min_y = corners[0].y;
    var max_x = corners[0].x;
    var max_y = corners[0].y;
    for (corners[1..]) |c| {
        min_x = @min(min_x, c.x);
        min_y = @min(min_y, c.y);
        max_x = @max(max_x, c.x);
        max_y = @max(max_y, c.y);
    }

    // Floor/ceil the AABB to integer pixels and clip to the framebuffer;
    // empty after clipping means fully off-screen. Clamping keeps the
    // float→int casts in range for far-off-screen quads.
    const fb_w: f64 = @floatFromInt(fb.width);
    const fb_h: f64 = @floatFromInt(fb.height);
    const x0: i32 = @intFromFloat(std.math.clamp(@floor(min_x), 0.0, fb_w));
    const y0: i32 = @intFromFloat(std.math.clamp(@floor(min_y), 0.0, fb_h));
    const x1: i32 = @intFromFloat(std.math.clamp(@ceil(max_x), 0.0, fb_w));
    const y1: i32 = @intFromFloat(std.math.clamp(@ceil(max_y), 0.0, fb_h));
    if (x0 >= x1 or y0 >= y1) return;

    const tex_data: *pixman.PixmanTextureData = @ptrCast(@alignCast(item.texture.data));

    var y = y0;
    while (y < y1) : (y += 1) {
        const sy: f64 = @floatFromInt(y);
        var x = x0;
        while (x < x1) : (x += 1) {
            const sx: f64 = @floatFromInt(x);
            const p = camera.screenToWorld(sx, sy);
            const u = (p.x - item.world_x) / item.world_w;
            const v = (p.y - item.world_y) / item.world_h;
            if (u < 0 or u >= 1 or v < 0 or v >= 1) continue;
            const sample = sampleBilinear(tex_data, item.texture.width, item.texture.height, u, v);
            blendPremultiplied(fb, x, y, sample, item.opacity);
        }
    }
}

/// Bilinear sample at normalized texture coordinates (u, v) in [0, 1).
/// Texel coordinate is (u * width, v * height); taps outside the texture
/// contribute 0 (the u,v rejection above keeps the base tap in range).
/// Returns the color as 0..255 floats in memory byte order (B,G,R,A).
fn sampleBilinear(data: *pixman.PixmanTextureData, tw: i32, th: i32, u: f64, v: f64) [4]f32 {
    const x_tex = u * @as(f64, @floatFromInt(tw));
    const y_tex = v * @as(f64, @floatFromInt(th));
    const ix0: i32 = @intFromFloat(@floor(x_tex));
    const jx0: i32 = @intFromFloat(@floor(y_tex));
    const fx = x_tex - @as(f64, @floatFromInt(ix0));
    const fy = y_tex - @as(f64, @floatFromInt(jx0));
    const w0x = 1.0 - fx;
    const w0y = 1.0 - fy;

    var acc = [4]f32{ 0, 0, 0, 0 };
    addWeighted(&acc, texelAt(data, ix0, jx0), w0x * w0y);
    if (ix0 + 1 < tw) addWeighted(&acc, texelAt(data, ix0 + 1, jx0), fx * w0y);
    if (jx0 + 1 < th) addWeighted(&acc, texelAt(data, ix0, jx0 + 1), w0x * fy);
    if (ix0 + 1 < tw and jx0 + 1 < th) addWeighted(&acc, texelAt(data, ix0 + 1, jx0 + 1), fx * fy);
    return acc;
}

/// One ARGB8888 texel as 0..255 floats in memory byte order (B,G,R,A).
fn texelAt(data: *pixman.PixmanTextureData, x: i32, y: i32) [4]f32 {
    const off = @as(usize, @intCast(y)) * @as(usize, @intCast(data.stride)) + @as(usize, @intCast(x)) * 4;
    const px = data.pixels[off..][0..4];
    return .{ @floatFromInt(px[0]), @floatFromInt(px[1]), @floatFromInt(px[2]), @floatFromInt(px[3]) };
}

fn addWeighted(acc: *[4]f32, color: [4]f32, weight: f64) void {
    const w: f32 = @floatCast(weight);
    acc[0] += color[0] * w;
    acc[1] += color[1] * w;
    acc[2] += color[2] * w;
    acc[3] += color[3] * w;
}

/// Premultiplied-over blend (wlroots premultiplied convention,
/// include/wlr/render/pass.h): out = src_premul + dst * (1 - src_a) per
/// channel, alpha included. `sample` is the straight sampled color in
/// memory byte order (B,G,R,A) as 0..255 floats; it is premultiplied by
/// (a * opacity) here, so opaque texels at opacity 1 are exact copies.
fn blendPremultiplied(fb: *pixman.Framebuffer, x: i32, y: i32, sample: [4]f32, opacity: f32) void {
    const dst = fb.pixelAt(x, y);
    const sa = (sample[3] / 255.0) * opacity; // src alpha after opacity, 0..1
    const inv = 1.0 - sa;
    var out: [4]u8 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const v = sample[i] * sa + @as(f32, @floatFromInt(dst[i])) * inv;
        out[i] = @intFromFloat(std.math.round(std.math.clamp(v, 0.0, 255.0)));
    }
    // Premultiplied alpha is the alpha itself: a * opacity.
    const a = sample[3] * opacity + @as(f32, @floatFromInt(dst[3])) * inv;
    out[3] = @intFromFloat(std.math.round(std.math.clamp(a, 0.0, 255.0)));

    const off = @as(usize, @intCast(y)) * @as(usize, @intCast(fb.stride)) + @as(usize, @intCast(x)) * 4;
    fb.data[off..][0..4].* = out;
}

test "canvas: identity camera blits a 2x2 texture exactly" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try pixman.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try pixman.Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();

    // 2x2 opaque texture, memory bytes B,G,R,A: red, green, blue, white.
    const pattern = [_]u8{
        0,   0, 255, 255, 0,   255, 0,   255,
        255, 0, 0,   255, 255, 255, 255, 255,
    };
    const tex = try pixman.PixmanRenderer.importMemory(renderer, 2, 2, 8, &pattern);
    defer tex.destroy();

    // Camera centered on the world-space screen origin (W/2, H/2) with
    // zoom 1 and no rotation: worldToScreen is the identity mapping, so
    // the world rect (0,0)-(2,2) lands on fb pixels (0,0)..(2,2).
    const camera: Camera = .{ .center_x = 2, .center_y = 2, .zoom = 1, .rotation = 0, .screen_w = 4, .screen_h = 4 };
    const items = [_]CanvasItem{
        .{ .texture = tex, .world_x = 0, .world_y = 0, .world_w = 2, .world_h = 2, .opacity = 1.0 },
    };
    render(allocator, fb, &camera, &items);

    // 1:1 blit: each texture texel lands exactly on its screen pixel.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(1, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(0, 1));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, fb.pixelAt(1, 1));
    // Outside the item's quad: untouched.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(2, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));

    // Fully off-screen item: culled by the AABB clip, fb untouched.
    const offscreen = [_]CanvasItem{
        .{ .texture = tex, .world_x = 10, .world_y = 10, .world_w = 2, .world_h = 2, .opacity = 1.0 },
    };
    render(allocator, fb, &camera, &offscreen);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));

    // Premultiplied-over blend: half-opacity red over white →
    // B,G,R,A = (127.5, 127.5, 255, 255), so B and G round to 128 (±1).
    fb.fill(.{ 255, 255, 255, 255 });
    var faded = items;
    faded[0].opacity = 0.5;
    render(allocator, fb, &camera, &faded);
    const blended = fb.pixelAt(0, 0);
    try std.testing.expect(@abs(@as(i32, blended[0]) - 128) <= 1);
    try std.testing.expect(@abs(@as(i32, blended[1]) - 128) <= 1);
    try std.testing.expectEqual(@as(u8, 255), blended[2]);
    try std.testing.expectEqual(@as(u8, 255), blended[3]);

    // Zero-opacity items are skipped: the framebuffer is unchanged.
    const before = fb.pixelAt(1, 0);
    var hidden = items;
    hidden[0].opacity = 0.0;
    render(allocator, fb, &camera, &hidden);
    try std.testing.expectEqual(before, fb.pixelAt(1, 0));
}

test "canvas: zoomed camera samples the bilinear midpoint" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try pixman.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try pixman.Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();

    const pattern = [_]u8{
        0,   0, 255, 255, 0,   255, 0,   255,
        255, 0, 0,   255, 255, 255, 255, 255,
    };
    const tex = try pixman.PixmanRenderer.importMemory(renderer, 2, 2, 8, &pattern);
    defer tex.destroy();

    // Zoom 2 centered on the texture center (1,1): the 2x2 texture exactly
    // fills the 4x4 fb. Pixel (1,1) samples the world point (0.5,0.5) —
    // the midpoint of the four texels — so the bilinear tap is their mean:
    // (red + green + blue + white)/4 = (128,128,128,255) in B,G,R,A (±1).
    const camera: Camera = .{ .center_x = 1, .center_y = 1, .zoom = 2, .rotation = 0, .screen_w = 4, .screen_h = 4 };
    const items = [_]CanvasItem{
        .{ .texture = tex, .world_x = 0, .world_y = 0, .world_w = 2, .world_h = 2, .opacity = 1.0 },
    };
    render(allocator, fb, &camera, &items);

    const got = fb.pixelAt(1, 1);
    for (got[0..3]) |b| try std.testing.expect(@abs(@as(i32, b) - 128) <= 1);
    try std.testing.expectEqual(@as(u8, 255), got[3]);
}
