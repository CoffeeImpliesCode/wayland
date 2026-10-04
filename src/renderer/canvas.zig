//! Canvas pass rasterizer: camera-transformed, bilinearly-sampled
//! texture compositing into a pixman framebuffer.
//!
//! Each CanvasItem stamps a texture into a world-space rect. The
//! rasterizer maps the rect through the Camera (worldToScreen), takes the
//! screen-space AABB of the transformed quad, floors/ceils it to integer
//! pixels and clips it to the framebuffer (off-screen culling; per-pixel
//! (u,v) rejection handles the rest of the quad's bounding box). Every
//! covered pixel then inverts the transform (screenToWorld) to find its
//! world point, computes the item's surface-normalized (u, v) and
//! bilinearly samples the texture through pixman.TexelMap.
//!
//! Conventions:
//! - Spaces: an item declares whether its rect is WORLD (camera
//!   transformed) or SCREEN (the framebuffer's own pixels, drawn through
//!   the identity mapping over it — see CanvasItem.Space). Draw order is
//!   the array order either way, and the last item is topmost.
//! - Draw order: items composite in array order — each item draws over
//!   all earlier items. The wiring passes items back-to-front
//!   (bottom-most first); the last item in the array is topmost.
//! - Sampling: the ONE contract, shared with the GLES2 pass — a
//!   destination pixel (x, y) samples the texture at its own CENTRE.
//!   The camera inverse is therefore evaluated at (x + 0.5, y + 0.5),
//!   and the raw texture centre that comes out is a texel POSITION
//!   (texel i spans [i, i+1), centre at i + 0.5), converted to a texel
//!   index exactly once, by the same crop-aware sampler the generic CPU
//!   pass uses. A texture stamped 1:1 onto pixels (identity mapping)
//!   lands texel (i, j) on pixel (i, j) exactly, and a magnified draw
//!   lands where the GPU fragment shader lands it — one contract, so a
//!   scaled, cropped, rotated or mirrored surface shows the same texel
//!   whichever renderer drew it.
//! - Geometry: an item's rect is its SURFACE rect (the buffer size
//!   under the committed transform divided by `buffer_scale`, or the
//!   wp_viewport destination size), `src` is the RAW buffer-pixel crop
//!   (null = whole texture) and `transform` is the surface's
//!   wl_output_transform (buffer -> surface). Crop and transform each
//!   apply exactly once, so a scaled, cropped, rotated or mirrored
//!   surface shows the texel each of its own pixels displays.
//! - Blending is premultiplied-over (the wlroots premultiplied
//!   convention, include/wlr/render/pass.h): out = src_premul +
//!   dst * (1 - src_a) per channel, alpha included. Opaque pixels
//!   (a = 255, opacity = 1) are exact copies.
//! - Fast path: common-case items (whole texture, normal buffer
//!   transform, world size == texture size, opacity 1) composite through
//!   the real pixman library (`pixman_image_composite32`, SIMD-optimized;
//!   the weston/wlroots model), replacing the per-pixel f64 loop
//!   (~545ms full-canvas in the VM). Everything else keeps the
//!   hand-rolled bilinear rasterizer below.
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

/// The coordinate space an item's rect is expressed in. Both spaces use
/// the same four f64 fields; what they MEAN differs, and the rasterizer
/// picks the mapping from this one tag.
pub const Space = enum {
    /// World (scene) coordinates: `render`'s camera maps them onto the
    /// framebuffer. Ordinary surface content — an xdg_toplevel, a popup,
    /// a subsurface — lives here, because the desktop IS the world.
    world,
    /// The framebuffer's OWN pixels, drawn through the identity mapping
    /// over it (`screenCamera`): the canvas camera never rotates,
    /// scales or slides it. Output-local policy belongs here — a
    /// session-lock screen or a layer surface must COVER its output, and
    /// a drag icon must sit AT the pointer, whatever the camera is doing.
    /// Passing an axis-aligned overlay through the world camera instead
    /// would slide and shrink it off the output it has to cover.
    screen,
};

/// A texture stamped into a rect, composited with `opacity` (0..1) over
/// whatever is already in the framebuffer.
///
/// The rect is the SURFACE-space rect (surface size, not buffer size —
/// `wl_surface.buffer_scale` divides the buffer out), which is also the
/// rect a wp_viewport destination stretches its crop into. `src` is the
/// raw BUFFER-pixel crop (null = the whole texture): the caller
/// multiplies a surface-local viewport source by the scale and
/// inverse-transforms it into raw buffer pixels, and this pass applies
/// it exactly once. `transform` is the surface's wl_output_transform
/// (buffer -> surface), so a rotated or mirrored surface samples the
/// texel each of its own pixels displays. `space` says whether the four
/// coordinates are world or screen (see Space above).
pub const CanvasItem = struct {
    texture: *texture_mod.Texture,
    world_x: f64,
    world_y: f64,
    world_w: f64,
    world_h: f64,
    opacity: f32,
    /// Raw buffer-pixel crop; null = the whole texture.
    src: ?geom.FRect = null,
    transform: geom.Transform = .normal,
    /// Which space `world_x/y/w/h` are in. `.world` (the default) is
    /// every surface node's rect; `.screen` is the output-local overlay
    /// case above.
    space: Space = .world,
};

/// The identity mapping over `fb`: the camera a `.screen` item is drawn
/// through, so a point at (x, y) lands on pixel (x, y) whatever the
/// canvas camera does. A compositing caller's cursor overlay and every
/// output-local policy overlay go through exactly this.
pub fn screenCamera(fb: *const pixman.Framebuffer) Camera {
    return .{
        .center_x = @as(f64, @floatFromInt(fb.width)) / 2.0,
        .center_y = @as(f64, @floatFromInt(fb.height)) / 2.0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = @floatFromInt(fb.width),
        .screen_h = @floatFromInt(fb.height),
    };
}

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
    // A `.screen` item is stamped in the framebuffer's own pixels, so it
    // goes through the identity mapping over THIS framebuffer rather than
    // through the canvas camera. Built once per call, and only when the
    // frame really carries one.
    var screen_cam: Camera = undefined;
    var have_screen_cam = false;
    for (items) |item| {
        // `!(opacity > 0)` also skips NaN opacity.
        if (!(item.opacity > 0) or item.world_w <= 0 or item.world_h <= 0) continue;
        if (item.texture.width <= 0 or item.texture.height <= 0) continue;
        if (item.space == .screen) {
            if (!have_screen_cam) {
                screen_cam = screenCamera(fb);
                have_screen_cam = true;
            }
            drawItem(fb, &screen_cam, item, stride, dst_img);
            continue;
        }
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
    const tw = item.texture.width;
    const th = item.texture.height;

    // Fast path: the common case — the WHOLE texture sampled 1:1 (no
    // crop, normal transform, surface size == texture size, fully
    // opaque) — composites through the real pixman library instead of
    // the per-pixel f64 loop. Pixman's SIMD bilinear + fixed-point
    // precision differs slightly from the f64 loop (pixel output
    // changes; tests carry pixman's exact values). A crop, a
    // transformed, scaled or translucent surface keeps the hand-rolled
    // loop below (the stride/fast-mode logic only exists there; pixman
    // does not need it — measured: pixman at full res beats the
    // hand-rolled stride-3 loop ~2-3x even during camera drags).
    if (item.transform == .normal and
        item.src == null and
        item.opacity == 1.0 and
        item.world_w == @as(f64, @floatFromInt(tw)) and
        item.world_h == @as(f64, @floatFromInt(th)))
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
    // Every term is f64 and the world origin is subtracted from the
    // camera centre BEFORE the division, so a surface a billion pixels
    // out keeps its local geometry (an f32 cannot hold 1e9 + a unit).
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
    const u_c = (ccx - wx - sw2 * inv_zoom * cos_r + sh2 * inv_zoom * sin_r) * inv_ww;
    const u_dx = inv_zoom * cos_r * inv_ww;
    const u_dy = -inv_zoom * sin_r * inv_ww;
    const v_c = (ccy - wy - sw2 * inv_zoom * sin_r - sh2 * inv_zoom * cos_r) * inv_wh;
    const v_dx = inv_zoom * sin_r * inv_wh;
    const v_dy = inv_zoom * cos_r * inv_wh;

    // Surface-normalized (u, v) -> raw texel: the buffer transform's
    // inverse composed with the item's raw crop, through the SAME
    // affine the generic CPU pass and the GLES2 pass use (pixman.
    // TexelMap). One asymmetric fixture therefore lands on the same
    // texel whichever renderer drew it, and a rotated camera or a
    // flipped surface cannot land outside the texture (every tap is
    // clamped, so no float -> int conversion ever sees an
    // unrepresentable value).
    //
    // The crop is held as its own value, not folded away: the sampler
    // needs it to clamp against the item's own rect instead of the whole
    // texture, and that is the difference between a wp_viewport crop
    // sampling correctly at its edges and smearing the buffer's far side.
    const crop: geom.FRect = item.src orelse pixman.wholeTexture(tw, th);
    const map = pixman.TexelMap.init(item.transform, tw, th, crop);

    const st: i32 = @intCast(@max(stride, 1));
    var y = y0;
    while (y < y1) : (y += st) {
        const sy: f64 = @floatFromInt(y);
        var x = x0;
        while (x < x1) : (x += st) {
            const sx: f64 = @floatFromInt(x);
            // The pixel CENTRE, not its corner: the same point the GPU
            // fragment shader reads, which is what makes a magnified
            // canvas identical on both paths.
            const cx = sx + 0.5;
            const cy = sy + 0.5;
            const u = u_c + u_dx * cx + u_dy * cy;
            const v = v_c + v_dx * cx + v_dy * cy;
            // Reject on the DESTINATION side: a pixel outside the item's
            // quad keeps the framebuffer, and the clamped taps inside it
            // never read past the texture.
            if (u < 0 or u >= 1 or v < 0 or v >= 1) continue;
            const t = map.at(u, v);
            const sample = pixman.sampleTexelPosition(tex_data, tw, th, crop, t.x, t.y);
            // Full quality: write the pixel. Fast mode: fill the
            // stride x stride block with this sample (blocky until the
            // interaction ends).
            if (st == 1) {
                pixman.blendSample(fb, x, y, sample, item.opacity);
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
                        pixman.blendSample(fb, x + bx, y + by, sample, item.opacity);
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

/// An asymmetric 4x4 fixture whose every channel is a multiple of 4: the
/// average of any 2x2 bilinear tap is then an exact integer, so an
/// expectation computed here never depends on a rounding tie, and every
/// texel is a different colour, so a wrong scale, crop, flip or rotation
/// shows a DIFFERENT pixel rather than a symmetric coincidence. Memory
/// bytes are B,G,R,A.
const ramp4x4 = blk: {
    var buf: [4 * 4 * 4]u8 = undefined;
    var y: i32 = 0;
    while (y < 4) : (y += 1) {
        var x: i32 = 0;
        while (x < 4) : (x += 1) {
            const i = y * 4 + x;
            buf[i * 4 + 0] = @intCast(4 * i);
            buf[i * 4 + 1] = @intCast(4 * (15 - i));
            buf[i * 4 + 2] = @intCast(4 * i + 8);
            buf[i * 4 + 3] = 255;
        }
    }
    break :blk buf;
};

fn rampAt(x: i32, y: i32) [4]u8 {
    const off: usize = @intCast((y * 4 + x) * 4);
    return ramp4x4[off..][0..4].*;
}

/// The 2x2 bilinear tap at a fractional texel POSITION, in f64: texel
/// `i` spans `[i, i + 1)`, so its centre is at `i + 0.5` and the filter
/// indexes the position minus that half — the same conversion
/// pixman.sampleTexelPosition makes, on the same frame the GPU's
/// u_texel_clamp clamps. Edge taps are clamped exactly as the rasterizer
/// clamps them (a whole-texture crop's centre bounds coincide with the
/// texture's edge texel centres). The rasterizer accumulates the same
/// four taps in f32, so a comparison against this allows one unit per
/// channel.
fn rampBilinear(px: f64, py: f64) [4]u8 {
    const u = std.math.clamp(px - 0.5, 0.0, 3.0);
    const v = std.math.clamp(py - 0.5, 0.0, 3.0);
    const ix: i32 = @intFromFloat(@floor(u));
    const iy: i32 = @intFromFloat(@floor(v));
    const ix1 = @min(ix + 1, 3);
    const iy1 = @min(iy + 1, 3);
    const fx = u - @as(f64, @floatFromInt(ix));
    const fy = v - @as(f64, @floatFromInt(iy));
    const gx = 1.0 - fx;
    const gy = 1.0 - fy;
    var out: [4]u8 = undefined;
    for (0..4) |ch| {
        const p00 = @as(f64, @floatFromInt(rampAt(ix, iy)[ch]));
        const p10 = @as(f64, @floatFromInt(rampAt(ix1, iy)[ch]));
        const p01 = @as(f64, @floatFromInt(rampAt(ix, iy1)[ch]));
        const p11 = @as(f64, @floatFromInt(rampAt(ix1, iy1)[ch]));
        const value = gx * gy * p00 + fx * gy * p10 + gx * fy * p01 + fx * fy * p11;
        out[ch] = @intFromFloat(std.math.round(std.math.clamp(value, 0.0, 255.0)));
    }
    return out;
}

/// The four texels of the crop (1,1)-(3,3) blended with `wx`/`wy` the
/// weight of the crop's SECOND column/row (1 - w goes to the first),
/// in the memory byte order the framebuffer stores.
fn cropBlend(wx: f64, wy: f64) [4]u8 {
    const w00 = (1.0 - wx) * (1.0 - wy);
    const w10 = wx * (1.0 - wy);
    const w01 = (1.0 - wx) * wy;
    const w11 = wx * wy;
    var out: [4]u8 = undefined;
    for (0..4) |ch| {
        const v = w00 * @as(f64, @floatFromInt(rampAt(1, 1)[ch])) +
            w10 * @as(f64, @floatFromInt(rampAt(2, 1)[ch])) +
            w01 * @as(f64, @floatFromInt(rampAt(1, 2)[ch])) +
            w11 * @as(f64, @floatFromInt(rampAt(2, 2)[ch]));
        out[ch] = @intFromFloat(std.math.round(v));
    }
    return out;
}

/// The buffer texel POSITION a surface point samples under `t`, from the
/// wl_output.transform definition (buffer -> surface, so this is its
/// continuous inverse) rather than from the map under test: texel `i`
/// spans `[i, i + 1)`, so the inverse carries no pixel `-1` terms, and a
/// 1:1 stamp is exact because the surface pixel's centre lands on
/// `i + 0.5`. `sx`/`sy` are fractional surface coordinates over a 4x4
/// buffer.
fn rampSurfaceTexel(t: geom.Transform, sx: f64, sy: f64) geom.FPoint {
    return switch (t) {
        .normal => .{ .x = sx, .y = sy },
        .@"90" => .{ .x = sy, .y = 4 - sx },
        .@"180" => .{ .x = 4 - sx, .y = 4 - sy },
        .@"270" => .{ .x = 4 - sy, .y = sx },
        .flipped => .{ .x = 4 - sx, .y = sy },
        .flipped_90 => .{ .x = sy, .y = sx },
        .flipped_180 => .{ .x = sx, .y = 4 - sy },
        // FLIPPED_270 (wlr_box_transform util/box.c:143-146): x' =
        // height - y - h, y' = width - x - w, so the surface x axis
        // maps to the buffer's y axis, bounded by the buffer HEIGHT.
        .flipped_270 => .{ .x = 4 - sy, .y = 4 - sx },
    };
}

test "canvas: a buffer_scale 2 surface filters the buffer at pixel centres" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try pixman.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try pixman.Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();
    const tex = try pixman.PixmanRenderer.importMemory(renderer, 4, 4, 16, &ramp4x4);
    defer tex.destroy();

    // Identity-mapping camera: world (0,0) renders at framebuffer (0,0).
    const camera: Camera = .{ .center_x = 2, .center_y = 2, .zoom = 1, .rotation = 0, .screen_w = 4, .screen_h = 4 };
    // A 4x4 buffer at buffer_scale 2 is a 2x2 SURFACE (the surface size
    // is the buffer size divided by the scale, wayland.xml
    // set_buffer_scale). Each destination pixel centre samples halfway
    // between four buffer texel centres. Ignoring the scale would draw
    // different colours and a different surface size.
    const items = [_]CanvasItem{
        .{ .texture = tex, .world_x = 0, .world_y = 0, .world_w = 2, .world_h = 2, .opacity = 1.0 },
    };
    render(allocator, fb, &camera, &items, 1);

    var j: i32 = 0;
    while (j < 2) : (j += 1) {
        var i: i32 = 0;
        while (i < 2) : (i += 1) {
            const want = rampBilinear(@as(f64, @floatFromInt(2 * i + 1)), @as(f64, @floatFromInt(2 * j + 1)));
            try std.testing.expectEqual(want, fb.pixelAt(i, j));
        }
    }
    // The surface really is 2x2: one pixel past its edge is background.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(2, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 2));
}

test "canvas: a raw src crop is stretched into the item rect" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try pixman.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try pixman.Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();
    const tex = try pixman.PixmanRenderer.importMemory(renderer, 4, 4, 16, &ramp4x4);
    defer tex.destroy();

    // wp_viewport.set_source's middle 2x2 as a RAW buffer crop, magnified
    // 2x into a 4x4 surface. Drawing the whole texture instead would show
    // a different quadrant at every pixel.
    const camera: Camera = .{ .center_x = 2, .center_y = 2, .zoom = 1, .rotation = 0, .screen_w = 4, .screen_h = 4 };
    const items = [_]CanvasItem{
        .{
            .texture = tex,
            .world_x = 0,
            .world_y = 0,
            .world_w = 4,
            .world_h = 4,
            .opacity = 1.0,
            .src = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
        },
    };
    render(allocator, fb, &camera, &items, 1);

    // The rasterizer samples each destination pixel at its CENTRE (the
    // one contract every backend follows), so pixel (i, j) reads crop
    // texel position (1 + (i + 0.5)/2, 1 + (j + 0.5)/2), and the
    // crop-edge clamp pins that to the crop's texel centres [1.5, 2.5]:
    // the two outer pixel columns and rows show the crop's edge texels
    // WHOLE, and the interior blends them 3:1 and 1:3. `weight` is the
    // weight of the crop's SECOND column/row, read off those positions
    // (index 1.0, 1.25, 1.75, 2.0).
    const weight = [_]f64{ 0.0, 0.25, 0.75, 1.0 };
    var j: i32 = 0;
    while (j < 4) : (j += 1) {
        var i: i32 = 0;
        while (i < 4) : (i += 1) {
            const want = cropBlend(weight[@intCast(i)], weight[@intCast(j)]);
            std.testing.expectEqual(want, fb.pixelAt(i, j)) catch |err| {
                std.debug.print("crop stretched 2x at ({d}, {d}): composited {any}, expected {any}\n", .{
                    i, j, fb.pixelAt(i, j), want,
                });
                return err;
            };
        }
    }
    // Spelled out: the corners are the crop's own texels, and (1, 1) is
    // the 3:1 blend of the four crop texels (1,1) {20,40,28},
    // (2,1) {24,36,32}, (1,2) {36,24,44}, (2,2) {40,20,48} —
    //   B 0.5625·20 + 0.1875·24 + 0.1875·36 + 0.0625·40 = 25
    //   G 0.5625·40 + 0.1875·36 + 0.1875·24 + 0.0625·20 = 35
    //   R 0.5625·28 + 0.1875·32 + 0.1875·44 + 0.0625·48 = 33
    // in memory order B,G,R,A.
    try std.testing.expectEqual(rampAt(1, 1), fb.pixelAt(0, 0));
    try std.testing.expectEqual(rampAt(2, 2), fb.pixelAt(3, 3));
    try std.testing.expectEqual([4]u8{ 25, 35, 33, 255 }, fb.pixelAt(1, 1));
}

test "canvas: a rotated and a distant camera keep every transform's texels" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try pixman.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try pixman.Framebuffer.create(allocator, 8, 8);
    defer fb.deinit();
    const tex = try pixman.PixmanRenderer.importMemory(renderer, 4, 4, 16, &ramp4x4);
    defer tex.destroy();

    // Panned, zoomed AND rotated: the camera's own three factors, so a
    // probe only lands on the right texel when the whole world -> screen
    // affine is applied, and every float -> int conversion in the
    // rasterizer sees a rotated, non-integral bounding box.
    const rotated: Camera = .{
        .center_x = 6,
        .center_y = 5,
        .zoom = 1.5,
        .rotation = 0.3,
        .screen_w = 8,
        .screen_h = 8,
    };
    // A world origin a billion px out with a FRACTIONAL centre: at 1e9
    // an f32's spacing is 64, so any path that narrows an absolute world
    // coordinate before the camera centre is subtracted puts the surface
    // tens of pixels from where Camera.worldToScreen says.
    const distant: Camera = .{
        .center_x = 1_000_000_008.5,
        .center_y = 1_000_000_041.25,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 8,
        .screen_h = 8,
    };
    const cameras = [_]Camera{ rotated, distant };

    const transforms = [_]geom.Transform{
        .normal,   .@"90",      .@"180",      .@"270",
        .flipped,  .flipped_90, .flipped_180, .flipped_270,
    };

    for (cameras) |cam| {
        for (transforms) |t| {
            fb.fill(.{ 0, 0, 0, 0 });
            // The item's top-left lands half a pixel before the
            // framebuffer's origin, so pixel (0, 0) samples well inside
            // the quad — one pixel clear of the edge, where the
            // destination-side rejection could hide a bug.
            const anchor = cam.screenToWorld(-0.5, -0.5);
            const items = [_]CanvasItem{
                .{
                    .texture = tex,
                    .world_x = anchor.x,
                    .world_y = anchor.y,
                    .world_w = 4,
                    .world_h = 4,
                    .opacity = 1.0,
                    // An explicit whole-texture crop (identical to a null
                    // src) keeps every case on the f64 rasterizer rather
                    // than the pixman fast path, whose own tests pin its
                    // output. This test is about the world -> screen
                    // mapping the GPU path matches.
                    .src = pixman.wholeTexture(4, 4),
                    .transform = t,
                },
            };
            render(allocator, fb, &cam, &items, 1);

            // The expectation: framebuffer pixel (0, 0) is sampled at
            // its CENTRE — screen (0.5, 0.5) — whose world point is two
            // steps into the item (the anchor sits half a pixel before
            // the screen origin); that surface point names a buffer texel
            // POSITION through the protocol's own transform definition,
            // and the tap is filtered there.
            const world = cam.screenToWorld(0.5, 0.5);
            const texel = rampSurfaceTexel(t, world.x - anchor.x, world.y - anchor.y);
            const want = rampBilinear(texel.x, texel.y);
            const got = fb.pixelAt(0, 0);
            for (0..4) |ch| {
                const diff = if (want[ch] > got[ch]) want[ch] - got[ch] else got[ch] - want[ch];
                std.testing.expect(diff <= 1) catch |err| {
                    std.debug.print(
                        "transform {s}, camera centre ({d}, {d}): channel {d} composited {any}, expected {any}\n",
                        .{ @tagName(t), cam.center_x, cam.center_y, ch, got, want },
                    );
                    return err;
                };
            }
        }
    }
}
