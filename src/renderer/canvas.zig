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
//! - Transform: an item's world rect is its SURFACE rect; `transform` is
//!   the surface's wl_output_transform (buffer -> surface). Sampling
//!   maps the surface point through the inverse transform first
//!   (surfaceToTexture), so a rotated surface shows each buffer texel
//!   where the transform places it. Identity (.normal) is the
//!   pre-transform sampling, byte for byte.
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
///
/// The world rect is the SURFACE-space rect (surface size, not buffer
/// size). `transform` is the surface's buffer transform
/// (wl_output_transform, buffer -> surface): the rasterizer samples the
/// texture at the point the surface rect maps back to in buffer space, so
/// a rotated/scaled surface draws correctly. .normal is the identity —
/// the sampling math is skipped and the pass is byte-identical to the
/// pre-transform rasterizer.
pub const CanvasItem = struct {
    texture: *texture_mod.Texture,
    world_x: f64,
    world_y: f64,
    world_w: f64,
    world_h: f64,
    opacity: f32,
    transform: geom.Transform = .normal,
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

    // Hoist the camera transform's invariants out of the pixel loop.
    // screenToWorld recomputes @cos/@sin per call — 2 trig ops per pixel,
    // the dominant cost of a full-canvas composite (~500ms in the VM for
    // a zoomed foot). Everything below is the SAME arithmetic screenToWorld
    // performs, with only the per-item constants pulled out; the per-pixel
    // divisions by camera.zoom and world_w/h are kept (not inverted) so the
    // result is bit-identical to the direct form.
    const cos_r = @cos(camera.rotation);
    const sin_r = @sin(camera.rotation);
    const sw2 = camera.screen_w / 2;
    const sh2 = camera.screen_h / 2;
    const ccx = camera.center_x;
    const ccy = camera.center_y;
    const wz = camera.zoom;
    const wx = item.world_x;
    const wy = item.world_y;
    const ww = item.world_w;
    const wh = item.world_h;

    var y = y0;
    while (y < y1) : (y += 1) {
        const sy: f64 = @floatFromInt(y);
        var x = x0;
        while (x < x1) : (x += 1) {
            const sx: f64 = @floatFromInt(x);
            const dx = (sx - sw2) / wz;
            const dy = (sy - sh2) / wz;
            const u = (ccx + dx * cos_r - dy * sin_r - wx) / ww;
            const v = (ccy + dx * sin_r + dy * cos_r - wy) / wh;
            if (u < 0 or u >= 1 or v < 0 or v >= 1) continue;
            // Surface-space (u, v) -> texture-space (tu, tv): the inverse
            // of the buffer transform (transform maps buffer -> surface
            // per wl_output_transform). Identity (normal) is (u, v)
            // unchanged — the pre-transform sampling, byte for byte.
            const t = surfaceToTexture(
                item.transform,
                u,
                v,
                item.world_w,
                item.world_h,
                item.texture.width,
                item.texture.height,
            );
            const sample = sampleBilinear(tex_data, item.texture.width, item.texture.height, t.u, t.v);
            blendPremultiplied(fb, x, y, sample, item.opacity);
        }
    }
}

/// Map a surface point (normalized u, v in [0, 1)) to the normalized
/// texture (buffer) coordinates it samples, given the surface's buffer
/// transform.
///
/// wl_output_transform maps buffer space -> surface space; sampling needs
/// the inverse. Surface pixel coords are (sx, sy) = (u·world_w, v·world_h);
/// the sample is `matrix.transformPoint(sx, sy)` — the exact
/// pixel-granularity inverse of wlr_box_transform (wlroots util/box.c:
/// 105-145) — extended linearly to fractional surface coords. The `-1`
/// terms are what make a 1:1 rotated stamp exact: they keep the sample
/// inside the texture (never on the far edge), so surface pixel (i, j)
/// shows buffer texel transformPoint(i, j), and the bilinear weights
/// stay well-formed. The identity transform reduces to (u, v) — the
/// pre-transform pass, byte for byte.
fn surfaceToTexture(
    transform: geom.Transform,
    u: f64,
    v: f64,
    world_w: f64,
    world_h: f64,
    tw: i32,
    th: i32,
) struct { u: f64, v: f64 } {
    const sx = u * world_w;
    const sy = v * world_h;
    const tex_w: f64 = @floatFromInt(tw);
    const tex_h: f64 = @floatFromInt(th);
    return switch (transform) {
        .normal => .{ .u = sx / tex_w, .v = sy / tex_h },
        .@"90" => .{ .u = sy / tex_w, .v = (tex_h - 1.0 - sx) / tex_h },
        .@"180" => .{ .u = (tex_w - 1.0 - sx) / tex_w, .v = (tex_h - 1.0 - sy) / tex_h },
        .@"270" => .{ .u = (tex_w - 1.0 - sy) / tex_w, .v = sx / tex_h },
        .flipped => .{ .u = (tex_w - 1.0 - sx) / tex_w, .v = sy / tex_h },
        .flipped_90 => .{ .u = sy / tex_w, .v = sx / tex_h },
        .flipped_180 => .{ .u = sx / tex_w, .v = (tex_h - 1.0 - sy) / tex_h },
        .flipped_270 => .{ .u = (tex_w - 1.0 - sy) / tex_w, .v = (tex_h - 1.0 - sx) / tex_h },
    };
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
    const off = @as(usize, @intCast(y)) * @as(usize, @intCast(fb.stride)) + @as(usize, @intCast(x)) * 4;
    const sa = (sample[3] / 255.0) * opacity; // src alpha after opacity, 0..1
    if (sa >= 1.0) {
        // Opaque: the over blend with sa=1 is a pure copy — the source
        // replaces the destination (per-channel `sample*1 + dst*0`).
        // Skips the per-pixel f32 blend for opaque surfaces (foot); the
        // result is byte-identical to the general blend.
        fb.data[off + 0] = @intFromFloat(std.math.round(std.math.clamp(sample[0], 0.0, 255.0)));
        fb.data[off + 1] = @intFromFloat(std.math.round(std.math.clamp(sample[1], 0.0, 255.0)));
        fb.data[off + 2] = @intFromFloat(std.math.round(std.math.clamp(sample[2], 0.0, 255.0)));
        fb.data[off + 3] = @intFromFloat(std.math.round(std.math.clamp(sample[3], 0.0, 255.0)));
        return;
    }
    if (sa <= 0.0) return; // fully transparent: the source contributes nothing

    const dst = fb.pixelAt(x, y);
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

test "canvas: 90-degree transform samples the rotated buffer" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try pixman.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try pixman.Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();

    // 2x1 opaque texture, memory bytes B,G,R,A: left texel red, right green.
    const pattern = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 };
    const tex = try pixman.PixmanRenderer.importMemory(renderer, 2, 1, 8, &pattern);
    defer tex.destroy();

    // Transform .90 (buffer rotated 90° clockwise, wl_output_transform):
    // a 2x1 buffer becomes a 1x2 surface. The pixel-exact inverse
    // (transformPoint: surface (sx, sy) -> buffer (sy, H-1-sx)) puts the
    // left texel (red) on the top surface pixel — surface (0,0) samples
    // texture (0, 0) — and the right (green) on the bottom: surface (0,1)
    // samples (1, 0). Camera centered on (W/2, H/2) at zoom 1: the
    // identity mapping (world (0,0) renders at screen (0,0)).
    const camera: Camera = .{ .center_x = 2, .center_y = 2, .zoom = 1, .rotation = 0, .screen_w = 4, .screen_h = 4 };
    const items = [_]CanvasItem{
        .{
            .texture = tex,
            .world_x = 0,
            .world_y = 0,
            .world_w = 1,
            .world_h = 2,
            .opacity = 1.0,
            .transform = .@"90",
        },
    };
    render(allocator, fb, &camera, &items);

    // The 1x2 surface rect fills fb pixels (0,0)..(1,2).
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0)); // top: red
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(0, 1)); // bottom: green

    // .270 is the opposite rotation: red bottom, green top.
    fb.fill(.{ 0, 0, 0, 0 });
    var rotated = items;
    rotated[0].transform = .@"270";
    render(allocator, fb, &camera, &rotated);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(0, 0)); // top: green
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 1)); // bottom: red
}

test "canvas: 180 and flipped transforms mirror the buffer" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try pixman.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try pixman.Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();

    // 2x1 texture: red left, green right.
    const pattern = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 };
    const tex = try pixman.PixmanRenderer.importMemory(renderer, 2, 1, 8, &pattern);
    defer tex.destroy();

    // .180 on a 2x1 surface (buffer rotated 180°): red right, green left.
    // Identity-mapping camera (center W/2,H/2): the 2x1 world rect fills
    // fb pixels (0,0) and (1,0).
    const camera: Camera = .{ .center_x = 2, .center_y = 2, .zoom = 1, .rotation = 0, .screen_w = 4, .screen_h = 4 };
    var items = [_]CanvasItem{
        .{
            .texture = tex,
            .world_x = 0,
            .world_y = 0,
            .world_w = 2,
            .world_h = 1,
            .opacity = 1.0,
            .transform = .@"180",
        },
    };
    render(allocator, fb, &camera, &items);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(0, 0)); // left: green
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(1, 0)); // right: red

    // .flipped (horizontal mirror): red right, green left — same pixels as
    // 180 for this symmetric 1-row texture, so use .flipped_180 instead
    // (vertical mirror): unchanged — red left, green right.
    fb.fill(.{ 0, 0, 0, 0 });
    items[0].transform = .flipped_180;
    render(allocator, fb, &camera, &items);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0)); // left: red
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(1, 0)); // right: green

    // .flipped on a 2x1 surface mirrors horizontally: red right, green left.
    fb.fill(.{ 0, 0, 0, 0 });
    items[0].transform = .flipped;
    render(allocator, fb, &camera, &items);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(0, 0)); // left: green
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(1, 0)); // right: red

    // .flipped_90 (wlr_box_transform util/box.c:143-146: x_s = y_b,
    // y_s = x_b): the surface is 1x2 and the pixel-exact inverse is
    // (u', v') = (sy/W, sx/H). Surface pixel (0, 0) samples texture
    // (0, 0) = red; (0, 1) samples (1/2, 0) = green. So top red, bottom
    // green (buffer texel (0,0) red maps to surface (0, 0)).
    fb.fill(.{ 0, 0, 0, 0 });
    const cam90: Camera = .{ .center_x = 2, .center_y = 2, .zoom = 1, .rotation = 0, .screen_w = 4, .screen_h = 4 };
    var f90 = items;
    f90[0].transform = .flipped_90;
    f90[0].world_w = 1;
    f90[0].world_h = 2;
    render(allocator, fb, &cam90, &f90);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0)); // top: red
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(0, 1)); // bottom: green
}
