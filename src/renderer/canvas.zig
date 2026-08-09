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
//! - Fast path: common-case items (normal buffer transform, world size
//!   == texture size, opacity 1) composite through the real pixman
//!   library (`pixman_image_composite32`, SIMD-optimized; the
//!   weston/wlroots model), replacing the per-pixel f64 loop (~545ms
//!   full-canvas in the VM). Everything else keeps the hand-rolled
//!   bilinear rasterizer below.
//!
//! Imports: utils/geom, scene/camera, renderer/{pixman,texture}, the
//! pixman_c C binding (build.zig).

const std = @import("std");
const geom = @import("../utils/geom.zig");
const camera_mod = @import("../scene/camera.zig");
const pixman = @import("pixman.zig");
const pixman_c = @import("pixman_c"); // real pixman library (SIMD composite)
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
/// `stride`: pixel sampling stride (1 = full quality; >1 = progressive
/// "fast" mode used while dragging/panning — every stride-th pixel is
/// bilinear-sampled and the stride x stride block is filled with that
/// sample, cutting the per-pixel bilinear cost ~stride² fold so a camera
/// pan stays responsive on a slow CPU. The result is blocky until the
/// interaction ends and a full-quality render replaces it.)
pub fn render(
    allocator: std.mem.Allocator,
    fb: *pixman.Framebuffer,
    camera: *const Camera,
    items: []const CanvasItem,
    stride: u32,
) void {
    _ = allocator;
    // Destination pixman image: wrap the framebuffer bytes ONCE per
    // composite and reuse it across items (pixman_image_create_bits wraps
    // existing memory — no copy). unref releases the wrapper, not the
    // bytes. When wrapping fails, the hand-rolled path below still works
    // (drawItem falls back).
    const dst_img = pixman_c.pixman_image_create_bits(
        pixman_c.PIXMAN_a8r8g8b8,
        fb.width,
        fb.height,
        @ptrCast(@alignCast(fb.data.ptr)),
        fb.stride,
    );
    defer {
        if (dst_img) |img| _ = pixman_c.pixman_image_unref(img);
    }
    for (items) |item| {
        // `!(opacity > 0)` also skips NaN opacity.
        if (!(item.opacity > 0) or item.world_w <= 0 or item.world_h <= 0) continue;
        if (item.texture.width <= 0 or item.texture.height <= 0) continue;
        drawItem(fb, camera, item, stride, dst_img);
    }
}

fn drawItem(
    fb: *pixman.Framebuffer,
    camera: *const Camera,
    item: CanvasItem,
    stride: u32,
    dst_img: ?*pixman_c.pixman_image_t,
) void {
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

    // Fast path: the common case — normal buffer transform, 1:1 scale
    // (world rect == texture size), fully opaque — composites through the
    // real pixman library instead of the per-pixel f64 loop. Pixman's
    // SIMD bilinear + fixed-point precision differs slightly from the f64
    // loop (pixel output changes; tests carry pixman's exact values).
    // Non-normal transforms, scaled surfaces, and fractional opacity keep
    // the hand-rolled loop below (the stride/fast-mode logic only exists
    // there; pixman does not need it).
    if (item.transform == .normal and
        item.opacity == 1.0 and
        item.world_w == @as(f64, @floatFromInt(item.texture.width)) and
        item.world_h == @as(f64, @floatFromInt(item.texture.height)))
    {
        if (dst_img) |dst| {
            compositePixman(dst, camera, item, tex_data, x0, y0, x1, y1);
            return;
        }
    }

    // Precompute the surface-space affine for the item: u = u_c + u_dx*sx +
    // u_dy*sy (and v), folding the camera transform (screenToWorld) + the
    // world-rect normalization into per-item constants. This eliminates the
    // per-pixel divisions by zoom and world_w/h — ~6 divisions per pixel
    // were the dominant cost of the full-canvas composite (~450ms in the
    // VM), far more than the trig (already hoisted) or the bilinear.
    const cos_r = @cos(camera.rotation);
    const sin_r = @sin(camera.rotation);
    const inv_zoom = 1.0 / camera.zoom;
    const sw2 = camera.screen_w / 2;
    const sh2 = camera.screen_h / 2;
    const ccx = camera.center_x;
    const ccy = camera.center_y;
    const wx = item.world_x;
    const wy = item.world_y;
    const ww = item.world_w;
    const wh = item.world_h;
    const inv_ww = 1.0 / ww;
    const inv_wh = 1.0 / wh;
    const u_c = (ccx - sw2 * inv_zoom * cos_r + sh2 * inv_zoom * sin_r - wx) * inv_ww;
    const u_dx = inv_zoom * cos_r * inv_ww;
    const u_dy = -inv_zoom * sin_r * inv_ww;
    const v_c = (ccy - sw2 * inv_zoom * sin_r - sh2 * inv_zoom * cos_r - wy) * inv_wh;
    const v_dx = inv_zoom * sin_r * inv_wh;
    const v_dy = inv_zoom * cos_r * inv_wh;
    const tex_w: f64 = @floatFromInt(item.texture.width);
    const tex_h: f64 = @floatFromInt(item.texture.height);
    // Fold the surface->texture map (surfaceToTexture, normal transform) —
    // the common case (a terminal at scale 1): tu = u * world_w / tex_w.
    const scale_w = ww / tex_w;
    const scale_h = wh / tex_h;

    const st: i32 = @intCast(@max(stride, 1));
    var y = y0;
    while (y < y1) : (y += st) {
        const sy: f64 = @floatFromInt(y);
        var x = x0;
        while (x < x1) : (x += st) {
            const sx: f64 = @floatFromInt(x);
            const u = u_c + u_dx * sx + u_dy * sy;
            const v = v_c + v_dx * sx + v_dy * sy;
            if (u < 0 or u >= 1 or v < 0 or v >= 1) continue;
            // Surface-space (u, v) -> texture-space (tu, tv): the inverse
            // of the buffer transform. Identity (normal) is (u, v) scaled
            // by world_w/tex_w (folded above); other transforms use
            // surfaceToTexture (rare: rotated/flipped surfaces).
            var tu = u * scale_w;
            var tv = v * scale_h;
            if (item.transform != .normal) {
                // Rotated/flipped surface: the full surfaceToTexture map.
                const t = surfaceToTexture(item.transform, u, v, ww, wh, item.texture.width, item.texture.height);
                tu = t.u;
                tv = t.v;
            }
            const sample = sampleBilinear(tex_data, item.texture.width, item.texture.height, tu, tv);
            // Full quality: write the pixel. Fast mode: fill the
            // stride x stride block with this sample (blocky until the
            // interaction ends).
            if (st == 1) {
                blendPremultiplied(fb, x, y, sample, item.opacity);
            } else if ((sample[3] / 255.0) * item.opacity >= 1.0) {
                // Opaque fill: the over blend is a copy. Compute the 4
                // output bytes ONCE + memcpy the block — the per-pixel
                // round was the fast-mode floor (~4M rounds/frame).
                const out: [4]u8 = .{
                    @intFromFloat(std.math.round(std.math.clamp(sample[0], 0.0, 255.0))),
                    @intFromFloat(std.math.round(std.math.clamp(sample[1], 0.0, 255.0))),
                    @intFromFloat(std.math.round(std.math.clamp(sample[2], 0.0, 255.0))),
                    @intFromFloat(std.math.round(std.math.clamp(sample[3], 0.0, 255.0))),
                };
                const fb_stride: usize = @intCast(fb.stride);
                var by: i32 = 0;
                while (by < st and y + by < y1) : (by += 1) {
                    var bx: i32 = 0;
                    while (bx < st and x + bx < x1) : (bx += 1) {
                        const off = @as(usize, @intCast(y + by)) * fb_stride + @as(usize, @intCast(x + bx)) * 4;
                        fb.data[off..][0..4].* = out;
                    }
                }
            } else {
                var by: i32 = 0;
                while (by < st and y + by < y1) : (by += 1) {
                    var bx: i32 = 0;
                    while (bx < st and x + bx < x1) : (bx += 1) {
                        blendPremultiplied(fb, x + bx, y + by, sample, item.opacity);
                    }
                }
            }
        }
    }
}

/// Composite a common-case item (normal transform, world size == texture
/// size, opacity 1) into `dst` through the real pixman library
/// (pixman_image_composite32, SIMD; the weston/wlroots model — cf.
/// libweston/pixman-renderer.c composite_whole and
/// render/pixman/pass.c render_pass_add_texture). The texture memory is
/// wrapped in a pixman image (no copy); the composite region is the
/// item's screen AABB (x0,y0)-(x1,y1) clipped to the framebuffer.
///
/// The source transform maps DESTINATION pixels to texture coordinates:
/// pixman applies a source image's transform to the destination
/// coordinate system (pixman-bits-image.c
/// __bits_image_fetch_affine_no_alpha: sample = M · dest; weston sets
/// output_to_buffer_matrix, wlroots builds the dst→src map). For the
/// camera affine this is the exact inverse of worldToScreen restricted
/// to the item (a = z·cos, b = −z·sin, c = z·sin, d = z·cos forward):
///   sample_x = cos/z·dx − sin/z·dy + cx − world_x − cos·(W/2)/z + sin·(H/2)/z
///   sample_y = sin/z·dx + cos/z·dy + cy − world_y − sin·(W/2)/z − cos·(H/2)/z
/// which is the hand-rolled loop's u/v affine, byte for byte.
///
/// src_x/src_y are passed EQUAL to the dest origin: pixman's src iterator
/// walks src_x + i and applies the transform to that coordinate, so src_x
/// must be the dest origin for the transform to see dest pixel
/// coordinates (weston composite_whole passes 0,0 with dest 0,0 for the
/// same reason).
///
/// Repeat NONE: samples outside the texture are (0,0,0,0) — transparent,
/// matching the hand-rolled loop's u/v rejection (weston composite_clipped
/// hardcodes NONE for the same reason; PAD would smear edge texels into
/// the rotated-quad AABB corners).
fn compositePixman(
    dst: *pixman_c.pixman_image_t,
    camera: *const Camera,
    item: CanvasItem,
    tex_data: *pixman.PixmanTextureData,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
) void {
    const cos_r = @cos(camera.rotation);
    const sin_r = @sin(camera.rotation);
    const inv_z = 1.0 / camera.zoom;
    const sw2 = camera.screen_w / 2;
    const sh2 = camera.screen_h / 2;

    var transform: pixman_c.pixman_transform_t = undefined;
    transform.matrix[0][0] = pixmanFixed(cos_r * inv_z);
    transform.matrix[0][1] = pixmanFixed(-sin_r * inv_z);
    transform.matrix[0][2] = pixmanFixed(
        camera.center_x - item.world_x - cos_r * sw2 * inv_z + sin_r * sh2 * inv_z,
    );
    transform.matrix[1][0] = pixmanFixed(sin_r * inv_z);
    transform.matrix[1][1] = pixmanFixed(cos_r * inv_z);
    transform.matrix[1][2] = pixmanFixed(
        camera.center_y - item.world_y - sin_r * sw2 * inv_z - cos_r * sh2 * inv_z,
    );
    transform.matrix[2][0] = 0;
    transform.matrix[2][1] = 0;
    transform.matrix[2][2] = pixmanFixed(1.0);

    const src_img = pixman_c.pixman_image_create_bits(
        pixman_c.PIXMAN_a8r8g8b8,
        item.texture.width,
        item.texture.height,
        @ptrCast(@alignCast(tex_data.pixels.ptr)),
        tex_data.stride,
    ) orelse return;
    defer _ = pixman_c.pixman_image_unref(src_img);

    _ = pixman_c.pixman_image_set_transform(src_img, &transform);
    _ = pixman_c.pixman_image_set_filter(src_img, pixman_c.PIXMAN_FILTER_BILINEAR, null, 0);
    pixman_c.pixman_image_set_repeat(src_img, pixman_c.PIXMAN_REPEAT_NONE);

    pixman_c.pixman_image_composite32(
        pixman_c.PIXMAN_OP_OVER,
        src_img,
        null, // no mask: opacity is 1 on this path
        dst,
        x0,
        y0, // src origin == dest origin (see doc)
        0,
        0, // mask origin (unused)
        x0,
        y0, // dest origin: the clipped AABB
        x1 - x0,
        y1 - y0,
    );
}

/// pixman_double_to_fixed: 16.16 fixed point. The C macro casts with UB
/// on overflow; saturating instead keeps pathological zooms from
/// trapping (they draw garbage either way, exactly like weston).
fn pixmanFixed(v: f64) pixman_c.pixman_fixed_t {
    return @intFromFloat(std.math.clamp(v * 65536.0, -2147483648.0, 2147483647.0));
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
    render(allocator, fb, &camera, &items, 1);

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
    render(allocator, fb, &camera, &offscreen, 1);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));

    // Premultiplied-over blend: half-opacity red over white →
    // B,G,R,A = (127.5, 127.5, 255, 255), so B and G round to 128 (±1).
    fb.fill(.{ 255, 255, 255, 255 });
    var faded = items;
    faded[0].opacity = 0.5;
    render(allocator, fb, &camera, &faded, 1);
    const blended = fb.pixelAt(0, 0);
    try std.testing.expect(@abs(@as(i32, blended[0]) - 128) <= 1);
    try std.testing.expect(@abs(@as(i32, blended[1]) - 128) <= 1);
    try std.testing.expectEqual(@as(u8, 255), blended[2]);
    try std.testing.expectEqual(@as(u8, 255), blended[3]);

    // Zero-opacity items are skipped: the framebuffer is unchanged.
    const before = fb.pixelAt(1, 0);
    var hidden = items;
    hidden[0].opacity = 0.0;
    render(allocator, fb, &camera, &hidden, 1);
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
    // fills the 4x4 fb. This item is the pixman fast path (normal
    // transform, scale 1, opaque), and pixman's bilinear samples the
    // destination pixel center: pixel (1,1) samples its center (1.5,1.5),
    // which maps to world (0.75,0.75) — not the texel midpoint the
    // hand-rolled corner-sampling loop produced. The bilinear weights are
    // 0.75 on the base texel, 0.25 on its neighbors: R = 255·0.75² +
    // 255·0.25² = 159.375 → 159, G = B = 255·0.25 = 63.75 → 63, A = 255.
    // These are pixman's exact fixed-point outputs, byte for byte.
    const camera: Camera = .{ .center_x = 1, .center_y = 1, .zoom = 2, .rotation = 0, .screen_w = 4, .screen_h = 4 };
    const items = [_]CanvasItem{
        .{ .texture = tex, .world_x = 0, .world_y = 0, .world_w = 2, .world_h = 2, .opacity = 1.0 },
    };
    render(allocator, fb, &camera, &items, 1);

    try std.testing.expectEqual([4]u8{ 63, 63, 159, 255 }, fb.pixelAt(1, 1));
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
    render(allocator, fb, &camera, &items, 1);

    // The 1x2 surface rect fills fb pixels (0,0)..(1,2).
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0)); // top: red
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(0, 1)); // bottom: green

    // .270 is the opposite rotation: red bottom, green top.
    fb.fill(.{ 0, 0, 0, 0 });
    var rotated = items;
    rotated[0].transform = .@"270";
    render(allocator, fb, &camera, &rotated, 1);
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
    render(allocator, fb, &camera, &items, 1);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(0, 0)); // left: green
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(1, 0)); // right: red

    // .flipped (horizontal mirror): red right, green left — same pixels as
    // 180 for this symmetric 1-row texture, so use .flipped_180 instead
    // (vertical mirror): unchanged — red left, green right.
    fb.fill(.{ 0, 0, 0, 0 });
    items[0].transform = .flipped_180;
    render(allocator, fb, &camera, &items, 1);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0)); // left: red
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(1, 0)); // right: green

    // .flipped on a 2x1 surface mirrors horizontally: red right, green left.
    fb.fill(.{ 0, 0, 0, 0 });
    items[0].transform = .flipped;
    render(allocator, fb, &camera, &items, 1);
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
    render(allocator, fb, &cam90, &f90, 1);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0)); // top: red
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(0, 1)); // bottom: green
}
