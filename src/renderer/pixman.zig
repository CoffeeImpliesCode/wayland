//! Pixman-style CPU renderer: compositing in memory, no GPU.
//!
//! Canonical renderer for headless backends and tests; reference
//! implementation of the Pass contract. Draws honour the FULL sampling
//! contract (Pass.TextureOptions): a raw buffer-pixel crop, any of the
//! eight wl_output.transforms, arbitrary destination scaling, and
//! per-op straight-alpha opacity, composited with PREMULTIPLIED alpha:
//! source RGB is premultiplied by source A before the over blend,
//! matching wlr_render_color (include/wlr/render/pass.h:135-137) and
//! smithay Color32F (src/backend/renderer/color.rs:3).
//!
//! # Sampling geometry
//! `TexelMap` is the one mapping every draw shares with the GPU
//! renderer (canvas.zig and gles2.zig sample through the same affine):
//! a destination-normalized coordinate of the draw's dst rect becomes a
//! raw texture texel POSITION. The draw's raw crop enters as its
//! SURFACE extent (`forwardBox`), so crop and transform each apply
//! exactly once.
//!
//! There is ONE convention, and it is the GPU's: a destination pixel is
//! sampled at its CENTRE, and texel `i` occupies `[i, i + 1)` with its
//! centre at `i + 0.5` (so `sampleTexelPosition` converts to the
//! sampler's index frame once, internally). A 1:1 stamp at an integer
//! dst is therefore texel-exact — the pixel centre lands on `i + 0.5`
//! and reads texel `i` whole — and a magnified or fractional draw lands
//! on the same texel here as on the GPU. The CPU used to sample a
//! pixel's top-left corner with origin-aligned taps, which shifted
//! every scaled draw half a texel away from the GPU; that is gone.
//!
//! # Crop edges
//! A raw crop is a WINDOW onto the texture, so the filter may only read
//! texels inside it: `sampleTexelPosition` clamps the sample position to
//! the crop's texel-CENTRE bounds, exactly as gles2.zig's
//! `u_texel_clamp` does in the fragment shader. Without that a
//! magnified crop's outer half texel fades in a neighbour the crop
//! never asked for — a wp_viewport source showing pixels outside
//! itself. Sampling the whole texture uncropped is the degenerate case,
//! where the clamp coincides with the sampler's own edge clamping.
//!
//! Imports: utils/*, renderer/{renderer,pass,texture}.zig.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const log_mod = @import("../utils/log.zig");
const renderer_mod = @import("renderer.zig");
const pass_mod = @import("pass.zig");
const texture_mod = @import("texture.zig");

/// wl_shm format code for ARGB8888 (little-endian bytes: B, G, R, A).
pub const format_argb8888: u32 = 0;

/// Render target: a plain in-memory ARGB8888 buffer.
pub const Framebuffer = struct {
    width: i32,
    height: i32,
    /// Bytes per row.
    stride: i32,
    format: u32,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, w: i32, h: i32) !*Framebuffer {
        if (w <= 0 or h <= 0) return error.InvalidSize;
        const stride = std.math.mul(i32, w, 4) catch return error.InvalidSize;
        const fb = try allocator.create(Framebuffer);
        errdefer allocator.destroy(fb);
        const data = try allocator.alloc(u8, @as(usize, @intCast(stride)) * @as(usize, @intCast(h)));
        @memset(data, 0);
        fb.* = .{
            .width = w,
            .height = h,
            .stride = stride,
            .format = format_argb8888,
            .data = data,
            .allocator = allocator,
        };
        return fb;
    }

    pub fn deinit(fb: *Framebuffer) void {
        const allocator = fb.allocator;
        allocator.free(fb.data);
        allocator.destroy(fb);
    }

    /// Fill the whole framebuffer with a color (test helper).
    pub fn fill(fb: *Framebuffer, color: [4]u8) void {
        // One uniform color across the whole buffer. The u32-pattern
        // store loop is ~4x faster than per-4-byte stores and vectorizes
        // (the background fill runs on every composite). The framebuffer
        // data is NOT guaranteed 4-aligned (pixman layout), so the u32
        // slice path is guarded; the unaligned path falls back to
        // per-4-byte stores.
        const total: usize = @as(usize, @intCast(fb.height)) * @as(usize, @intCast(fb.stride));
        if (@intFromPtr(fb.data.ptr) % @alignOf(u32) == 0) {
            const pattern = std.mem.bytesToValue(u32, &color);
            const words = std.mem.bytesAsSlice(u32, fb.data[0..total]);
            for (words) |*w| w.* = pattern;
        } else {
            var i: usize = 0;
            while (i + 4 <= total) : (i += 4) fb.data[i..][0..4].* = color;
        }
    }

    /// Read one ARGB8888 pixel (test helper).
    pub fn pixelAt(fb: *const Framebuffer, x: i32, y: i32) [4]u8 {
        const off = @as(usize, @intCast(y)) * @as(usize, @intCast(fb.stride)) + @as(usize, @intCast(x)) * 4;
        return fb.data[off..][0..4].*;
    }
};

/// `wlr_box_transform`'s inverse (surface -> buffer) as a linear map of a
/// SURFACE coordinate: the continuous form, with texel `i` occupying
/// `[i, i+1)` so its CENTRE sits at `i + 0.5`.
///
/// This is `matrix.transformPoint` (utils/matrix.zig, the pixel-granular
/// inverse of `wlr_box_transform`, wlroots util/box.c:105-145) on a
/// zero-extent box, i.e. with the pixel `-1` terms dropped — and it is
/// the ONLY form any backend uses. The GPU filters a fragment at the
/// centre of the pixel it covers, and a CPU rasterizer that samples its
/// pixel's top-left corner instead shifts every scaled draw half a texel
/// away from what the GPU shows. `tw`/`th` are the RAW buffer dimensions.
fn inverseTransform(
    t: geom.Transform,
    x: f64,
    y: f64,
    tw: f64,
    th: f64,
) geom.FPoint {
    return switch (t) {
        .normal => .{ .x = x, .y = y },
        .@"90" => .{ .x = y, .y = th - x },
        .@"180" => .{ .x = tw - x, .y = th - y },
        .@"270" => .{ .x = tw - y, .y = x },
        .flipped => .{ .x = tw - x, .y = y },
        .flipped_90 => .{ .x = y, .y = x },
        .flipped_180 => .{ .x = x, .y = th - y },
        .flipped_270 => .{ .x = tw - y, .y = th - x },
    };
}

/// `wlr_box_transform` (wlroots util/box.c:105-145) on a box, in f64:
/// where a RAW buffer-pixel box lands on the surface.
///
/// The result stays in raw buffer units on purpose. `buffer_scale` runs
/// BEFORE the transform (wl_surface.xml: "the scaling transformation is
/// applied before the transform"), so a scaled buffer's box map is the
/// raw one divided by the scale on both sides — it cancels, and a
/// surface coordinate in raw units maps back to a texel index with no
/// scale term anywhere.
pub fn forwardBox(t: geom.Transform, box: geom.FRect, tw: i32, th: i32) geom.FRect {
    const w: f64 = @floatFromInt(tw);
    const h: f64 = @floatFromInt(th);
    return switch (t) {
        .normal => box,
        .@"90" => .{ .x = h - box.y - box.height, .y = box.x, .width = box.height, .height = box.width },
        .@"180" => .{ .x = w - box.x - box.width, .y = h - box.y - box.height, .width = box.width, .height = box.height },
        .@"270" => .{ .x = box.y, .y = w - box.x - box.width, .width = box.height, .height = box.width },
        .flipped => .{ .x = w - box.x - box.width, .y = box.y, .width = box.width, .height = box.height },
        .flipped_90 => .{ .x = box.y, .y = box.x, .width = box.height, .height = box.width },
        .flipped_180 => .{ .x = box.x, .y = h - box.y - box.height, .width = box.width, .height = box.height },
        // FLIPPED_270: x' = height - y - h, y' = width - x - w, so the
        // surface x axis carries the buffer's y axis, bounded by the
        // buffer HEIGHT, and vice versa.
        .flipped_270 => .{ .x = h - box.y - box.height, .y = w - box.x - box.width, .width = box.height, .height = box.width },
    };
}

/// The destination-normalized -> raw texel affine of one draw, shared
/// by every backend so the CPU canvas, the generic CPU pass and the
/// GLES2 pass place the same texel on the same output pixel.
///
/// `src` is the draw's raw buffer-pixel crop (null = the whole texture;
/// the caller has already multiplied a surface-local viewport source by
/// `buffer_scale` and inverse-transformed it into raw buffer pixels).
/// The crop enters through `forwardBox` — its surface extent — and the
/// draw's destination rect is exactly that extent, so crop and
/// transform each apply ONCE and compose exactly. A 4x4 asymmetric
/// fixture drawn through both backends therefore cannot disagree by a
/// half texel or by a doubled crop.
///
/// The result is a texel POSITION (centres at half-integers), the same
/// quantity the GPU's fragment shader clamps and converts. Callers
/// evaluate it at the pixel's CENTRE: that is what makes a 1:1 stamp
/// land texel-exact (position `i + 0.5` -> index `i`) and a scaled
/// draw land on the same texel in both backends.
pub const TexelMap = struct {
    x_c: f64,
    x_dx: f64,
    x_dy: f64,
    y_c: f64,
    y_dx: f64,
    y_dy: f64,

    pub fn init(
        t: geom.Transform,
        tw: i32,
        th: i32,
        src: geom.FRect,
    ) TexelMap {
        const twf: f64 = @floatFromInt(tw);
        const thf: f64 = @floatFromInt(th);
        const surface = forwardBox(t, src, tw, th);
        const p00 = texel(t, surface, 0, 0, twf, thf);
        const p10 = texel(t, surface, 1, 0, twf, thf);
        const p01 = texel(t, surface, 0, 1, twf, thf);
        return .{
            .x_c = p00.x,
            .x_dx = p10.x - p00.x,
            .x_dy = p01.x - p00.x,
            .y_c = p00.y,
            .y_dx = p10.y - p00.y,
            .y_dy = p01.y - p00.y,
        };
    }

    fn texel(
        t: geom.Transform,
        surface: geom.FRect,
        a: f64,
        b: f64,
        tw: f64,
        th: f64,
    ) geom.FPoint {
        return inverseTransform(t, surface.x + a * surface.width, surface.y + b * surface.height, tw, th);
    }

    /// Texel position for destination-normalized (a, b). Callers pass
    /// the DESTINATION PIXEL's centre.
    pub fn at(map: TexelMap, a: f64, b: f64) geom.FPoint {
        return .{
            .x = map.x_c + map.x_dx * a + map.x_dy * b,
            .y = map.y_c + map.y_dx * a + map.y_dy * b,
        };
    }
};

/// The raw crop a draw samples: the whole texture when `src` is null.
pub fn wholeTexture(tw: i32, th: i32) geom.FRect {
    return .{ .x = 0, .y = 0, .width = @floatFromInt(tw), .height = @floatFromInt(th) };
}

/// Bilinear sample at NORMALIZED texture coordinates (u, v): the texel
/// POSITION is (u·width, v·height).
pub fn sampleBilinear(data: *const PixmanTextureData, tw: i32, th: i32, u: f64, v: f64) [4]f32 {
    return sampleTexelPosition(
        data,
        tw,
        th,
        wholeTexture(tw, th),
        u * @as(f64, @floatFromInt(tw)),
        v * @as(f64, @floatFromInt(th)),
    );
}

/// Bilinear sample at a texel POSITION, over the whole texture: texel
/// `i` spans `[i, i + 1)`, so its centre is at `i + 0.5` and a 1:1
/// stamp's pixel centre lands exactly on one.
/// Returns the color as 0..255 floats in memory byte order (B,G,R,A).
///
/// This is `sampleTexelPosition` over the whole texture; a caller that
/// draws a crop must use that one instead, or the filter reads texels
/// outside the crop.
pub fn sampleBilinearTexel(data: *const PixmanTextureData, tw: i32, th: i32, x_tex: f64, y_tex: f64) [4]f32 {
    return sampleTexelPosition(data, tw, th, wholeTexture(tw, th), x_tex, y_tex);
}

/// Bilinear sample at a texel POSITION, reading only texels inside
/// `crop` — the one sampler both CPU paths use, and the CPU twin of the
/// fragment shader's `u_texel_clamp` (module docs, "# Crop edges").
///
/// The coordinate contract is the GPU's, verbatim: texel `i` spans
/// `[i, i + 1)` and its CENTRE sits at `i + 0.5`, so a fragment (or a
/// CPU pixel) at position `p` is filtered between the two texel centres
/// around it. Concretely, for a 1:1 stamp the pixel centre lands on
/// `i + 0.5` and reads texel `i` whole; a magnified crop's outer half
/// texel resolves to the crop's own edge texel instead of fading in a
/// neighbour the crop never named.
///
/// The centre-to-index conversion happens ONCE here — `p - 0.5`, then
/// the fractional part is the blend weight — so no caller can express
/// the filter in the old origin-aligned frame by accident.
/// Returns the color as 0..255 floats in memory byte order (B,G,R,A).
pub fn sampleTexelPosition(
    data: *const PixmanTextureData,
    tw: i32,
    th: i32,
    crop: geom.FRect,
    x_tex: f64,
    y_tex: f64,
) [4]f32 {
    // Clamp the POSITION to the crop's texel-centre bounds (the crop's
    // own edge texels bound the filter), then convert to the sampler's
    // index frame, where texel centres are integers.
    const lo_x = crop.x + 0.5;
    const lo_y = crop.y + 0.5;
    const px = std.math.clamp(x_tex, lo_x, @max(lo_x, crop.right() - 0.5));
    const py = std.math.clamp(y_tex, lo_y, @max(lo_y, crop.bottom() - 0.5));
    const cx = clampIndex(px - 0.5, tw);
    const cy = clampIndex(py - 0.5, th);
    const ix0: i32 = @intFromFloat(@floor(cx));
    const jy0: i32 = @intFromFloat(@floor(cy));
    const ix1 = @min(ix0 + 1, tw - 1);
    const jy1 = @min(jy0 + 1, th - 1);
    const fx = cx - @as(f64, @floatFromInt(ix0));
    const fy = cy - @as(f64, @floatFromInt(jy0));
    const gx = 1.0 - fx;
    const gy = 1.0 - fy;
    var acc = [4]f32{ 0, 0, 0, 0 };
    addWeighted(&acc, texelAt(data, ix0, jy0), gx * gy);
    addWeighted(&acc, texelAt(data, ix1, jy0), fx * gy);
    addWeighted(&acc, texelAt(data, ix0, jy1), gx * fy);
    addWeighted(&acc, texelAt(data, ix1, jy1), fx * fy);
    return acc;
}

/// Clamp a sampler index coordinate into [0, len - 1] BEFORE the float
/// -> int conversion: a caller may hand this a coordinate just outside
/// the texture (a quad edge under a flipped transform), and ReleaseSafe
/// traps a float -> int conversion that is not exactly representable.
fn clampIndex(v: f64, len: i32) f64 {
    return std.math.clamp(v, 0.0, @as(f64, @floatFromInt(len - 1)));
}

/// One ARGB8888 texel as 0..255 floats in memory byte order (B,G,R,A).
fn texelAt(data: *const PixmanTextureData, x: i32, y: i32) [4]f32 {
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

/// Premultiplied-alpha over blend (wlroots premultiplied convention,
/// include/wlr/render/pass.h): out = src_premul + dst·(1 − src_a) per
/// channel, alpha included. `sample` is a straight sampled color in
/// memory byte order (B,G,R,A) as 0..255 floats; it is premultiplied by
/// `alpha` here, so opaque texels at alpha 1 are exact copies.
pub fn blendSample(fb: *Framebuffer, x: i32, y: i32, sample: [4]f32, alpha: f32) void {
    const off = @as(usize, @intCast(y)) * @as(usize, @intCast(fb.stride)) + @as(usize, @intCast(x)) * 4;
    const sa = (sample[3] / 255.0) * alpha; // src alpha after opacity, 0..1
    if (sa >= 1.0) {
        // Opaque: the over blend with sa=1 is a pure copy — the source
        // replaces the destination (per-channel `sample*1 + dst*0`).
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
    // Premultiplied alpha is the alpha itself: a * alpha.
    const a = sample[3] * alpha + @as(f32, @floatFromInt(dst[3])) * inv;
    out[3] = @intFromFloat(std.math.round(std.math.clamp(a, 0.0, 255.0)));

    fb.data[off..][0..4].* = out;
}

/// Texture payload. PUBLISHED so other modules cast `Texture.data` to
/// this exact type — never to a locally re-declared mirror. (Zig 0.16
/// lays default structs out by alignment, not declaration order, so two
/// look-alike declarations are NOT guaranteed identical; one shared
/// declaration removes the hazard. `extern struct` is not usable here:
/// `[]u8` is not a C-ABI type and this struct never crosses the FFI
/// boundary.)
pub const PixmanTextureData = struct {
    pixels: []u8,
    stride: i32,
    allocator: std.mem.Allocator,
};

const PixmanPassData = struct {
    fb: ?*Framebuffer = null,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
};

const PixmanData = struct {
    allocator: std.mem.Allocator,
    pass: pass_mod.Pass,
    pass_data: PixmanPassData,
};

const renderer_impl: renderer_mod.Renderer.Impl = .{
    .begin_pass = beginPass,
    .destroy = destroyRenderer,
};

const pass_impl: pass_mod.Pass.Impl = .{
    .add_texture = addTexture,
    .add_rect = addRect,
    .submit = submitPass,
};

const texture_impl: texture_mod.Texture.Impl = .{
    .destroy = destroyTexture,
};

pub const PixmanRenderer = struct {
    pub fn create(allocator: std.mem.Allocator, io: *std.Io, log_cfg: *const log_mod.Config) !*renderer_mod.Renderer {
        const data = try allocator.create(PixmanData);
        errdefer allocator.destroy(data);
        data.* = .{
            .allocator = allocator,
            // SAFETY: pass.impl/data are filled by begin_pass before use.
            .pass = undefined,
            .pass_data = .{ .io = io, .log_cfg = log_cfg },
        };
        return renderer_mod.Renderer.create(allocator, io, log_cfg, &renderer_impl, data, &.{format_argb8888});
    }

    /// Import an ARGB8888 pixel buffer as a texture. The pixels are copied
    /// into renderer-owned memory.
    ///
    /// Pixels are stored as delivered: premultiplied ARGB8888. The Wayland
    /// protocol requires alpha premultiplied into the color values
    /// (wl_buffer, protocols/wayland/wayland.xml:533-536), and wlroots'
    /// pixman renderer wraps client bytes with no conversion
    /// (render/pixman/renderer.c pixman_texture_from_buffer), so no
    /// premultiplication happens here either.
    pub fn importMemory(
        renderer: *renderer_mod.Renderer,
        w: i32,
        h: i32,
        stride: i32,
        pixels: []const u8,
    ) !*texture_mod.Texture {
        if (w <= 0 or h <= 0 or stride <= 0) return error.InvalidSize;
        const data: *PixmanData = @ptrCast(@alignCast(renderer.data));
        const size = @as(usize, @intCast(stride)) * @as(usize, @intCast(h));
        if (pixels.len < size) return error.InvalidSize;

        const owned = try data.allocator.alloc(u8, size);
        errdefer data.allocator.free(owned);
        @memcpy(owned, pixels[0..size]);

        const tex_data = try data.allocator.create(PixmanTextureData);
        errdefer data.allocator.destroy(tex_data);
        tex_data.* = .{ .pixels = owned, .stride = stride, .allocator = data.allocator };

        const tex = try data.allocator.create(texture_mod.Texture);
        tex.* = .{ .impl = &texture_impl, .data = tex_data, .width = w, .height = h };
        return tex;
    }

    /// Overwrite an imported texture's pixels in place when the geometry
    /// matches. Returns false when the texture must be re-imported (size
    /// or stride changed). The hot path for per-frame surface updates:
    /// no allocation, no texture churn.
    pub fn updateMemory(
        texture: *texture_mod.Texture,
        w: i32,
        h: i32,
        stride: i32,
        pixels: []const u8,
    ) bool {
        const tex_data: *PixmanTextureData = @ptrCast(@alignCast(texture.data));
        if (texture.width != w or texture.height != h or tex_data.stride != stride) return false;
        const size = @as(usize, @intCast(stride)) * @as(usize, @intCast(h));
        if (pixels.len < size) return false;
        @memcpy(tex_data.pixels[0..size], pixels[0..size]);
        return true;
    }
};

fn beginPass(renderer: *renderer_mod.Renderer, target: *anyopaque) ?*pass_mod.Pass {
    const data: *PixmanData = @ptrCast(@alignCast(renderer.data));
    data.pass_data.fb = @ptrCast(@alignCast(target));
    data.pass = .{ .impl = &pass_impl, .data = &data.pass_data };
    return &data.pass;
}

fn destroyRenderer(allocator: std.mem.Allocator, data: *anyopaque) void {
    const d: *PixmanData = @ptrCast(@alignCast(data));
    allocator.destroy(d);
}

fn destroyTexture(texture: *texture_mod.Texture) void {
    const tex_data: *PixmanTextureData = @ptrCast(@alignCast(texture.data));
    const allocator = tex_data.allocator;
    allocator.free(tex_data.pixels);
    allocator.destroy(tex_data);
    allocator.destroy(texture);
}

fn addTexture(pass: *pass_mod.Pass, texture: *texture_mod.Texture, options: pass_mod.Pass.TextureOptions) void {
    const data: *PixmanPassData = @ptrCast(@alignCast(pass.data));
    const fb = data.fb orelse return;
    const tex_data: *PixmanTextureData = @ptrCast(@alignCast(texture.data));
    const dst = options.dst;
    // `!(x > 0)` also rejects NaN.
    if (!(dst.width > 0) or !(dst.height > 0) or !(options.alpha > 0)) return;
    if (texture.width <= 0 or texture.height <= 0) return;

    // Destination-normalized -> raw texel POSITION, through the buffer
    // transform's inverse and the raw crop (TexelMap).
    const crop = options.src orelse wholeTexture(texture.width, texture.height);
    const map = TexelMap.init(options.transform, texture.width, texture.height, crop);
    const inv_w = 1.0 / dst.width;
    const inv_h = 1.0 / dst.height;

    // Integer pixel bounds of the dst rect, clipped to the framebuffer.
    // Clamping before the conversion keeps a far-off-screen rect from
    // trapping a float -> int conversion.
    const fb_w: f64 = @floatFromInt(fb.width);
    const fb_h: f64 = @floatFromInt(fb.height);
    const x0: i32 = @intFromFloat(std.math.clamp(@floor(dst.x), 0.0, fb_w));
    const y0: i32 = @intFromFloat(std.math.clamp(@floor(dst.y), 0.0, fb_h));
    const x1: i32 = @intFromFloat(std.math.clamp(@ceil(dst.x + dst.width), 0.0, fb_w));
    const y1: i32 = @intFromFloat(std.math.clamp(@ceil(dst.y + dst.height), 0.0, fb_h));
    if (x0 >= x1 or y0 >= y1) return;

    var y = y0;
    while (y < y1) : (y += 1) {
        // A pixel samples at its CENTRE — the same point a GPU fragment
        // covers, so a texture stamped 1:1 at an integer dst lands texel
        // for texel and a scaled one lands on the same texel in both
        // backends.
        const b = (@as(f64, @floatFromInt(y)) + 0.5 - dst.y) * inv_h;
        var x = x0;
        while (x < x1) : (x += 1) {
            const a = (@as(f64, @floatFromInt(x)) + 0.5 - dst.x) * inv_w;
            // Reject on the DESTINATION side: a pixel whose centre falls
            // outside the quad keeps the framebuffer, and the clamped
            // taps inside it never read past the texture (no ReleaseSafe
            // trap, and no smear from an edge clamp on a rotated quad's
            // bounding box).
            if (a < 0 or a >= 1 or b < 0 or b >= 1) continue;
            const t = map.at(a, b);
            // Crop-aware: the filter stays inside the draw's raw crop, so
            // a magnified crop never fades in a texel outside it.
            const sample = sampleTexelPosition(tex_data, texture.width, texture.height, crop, t.x, t.y);
            blendSample(fb, x, y, sample, options.alpha);
        }
    }
}

fn addRect(pass: *pass_mod.Pass, rect: geom.FRect, color: [4]f32) void {
    const data: *PixmanPassData = @ptrCast(@alignCast(pass.data));
    const fb = data.fb orelse return;

    if (rect.isEmpty() or !(color[3] > 0) or
        !std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.right()) or !std.math.isFinite(rect.bottom())) return;
    // Clip in f64 before narrowing. A covered pixel's centre lies in the
    // half-open rectangle, matching textured draws and GPU coverage.
    const width: f64 = @floatFromInt(fb.width);
    const height: f64 = @floatFromInt(fb.height);
    const x0: i32 = @intFromFloat(std.math.clamp(@ceil(rect.x - 0.5), 0, width));
    const y0: i32 = @intFromFloat(std.math.clamp(@ceil(rect.y - 0.5), 0, height));
    const x1: i32 = @intFromFloat(std.math.clamp(@ceil(rect.right() - 0.5), 0, width));
    const y1: i32 = @intFromFloat(std.math.clamp(@ceil(rect.bottom() - 0.5), 0, height));
    if (x0 >= x1 or y0 >= y1) return;

    // The Pass API takes a straight-alpha color (pass.zig), while the
    // framebuffer and blendPixel are premultiplied (wlr_render_color
    // convention, include/wlr/render/pass.h:135-137): premultiply RGB by
    // alpha here. The framebuffer is ARGB8888 little-endian memory bytes
    // B,G,R,A, so the RGBA color is stored with B first, alpha at index 3.
    const a = std.math.clamp(color[3], 0.0, 1.0);
    const src: [4]u8 = .{
        @intFromFloat(@round(std.math.clamp(color[2] * a, 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(color[1] * a, 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(color[0] * a, 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(a * 255.0)),
    };

    const fb_stride: usize = @intCast(fb.stride);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = fb.data[@as(usize, @intCast(y)) * fb_stride ..];
        var x = x0;
        while (x < x1) : (x += 1) {
            blendPixel(row[@as(usize, @intCast(x)) * 4 ..][0..4], src);
        }
    }
}

/// Premultiplied-alpha over composite: out = src + dst*(1-src.a) per
/// channel, src's RGB already multiplied by src.a (so src[i] <= src[3]).
/// Channels are in memory byte order (B,G,R,A), alpha at index 3; the
/// alpha channel formula reduces to src.a + dst.a*(1-src.a). The result
/// stays <= 255 for valid premultiplied input. Opaque sources replace,
/// fully transparent sources are skipped.
fn blendPixel(dst: *[4]u8, src: [4]u8) void {
    const a: u32 = src[3];
    if (a == 255) {
        dst.* = src;
        return;
    }
    if (a == 0) return;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const s: u32 = src[i];
        const d: u32 = dst[i];
        dst[i] = @intCast((s * 255 + d * (255 - a) + 127) / 255);
    }
}

fn submitPass(pass: *pass_mod.Pass) void {
    const data: *PixmanPassData = @ptrCast(@alignCast(pass.data));
    log_mod.trace("submit: no-op (CPU blits are eager)", data.io, data.log_cfg, "pixman", .{});
}

test "framebuffer create and fill" {
    const allocator = std.testing.allocator;
    const fb = try Framebuffer.create(allocator, 4, 3);
    defer fb.deinit();

    try std.testing.expectEqual(@as(i32, 4), fb.width);
    try std.testing.expectEqual(@as(i32, 3), fb.height);
    try std.testing.expectEqual(@as(i32, 16), fb.stride);
    try std.testing.expectEqual(format_argb8888, fb.format);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(1, 1));

    fb.fill(.{ 9, 8, 7, 255 });
    try std.testing.expectEqual([4]u8{ 9, 8, 7, 255 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 9, 8, 7, 255 }, fb.pixelAt(3, 2));
}

test "texture import copies pixels" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    var pixels = [_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,
        9, 10, 11, 12, 13, 14, 15, 16,
    }; // 2x2, stride 8
    const tex = try PixmanRenderer.importMemory(renderer, 2, 2, 8, &pixels);
    defer tex.destroy();

    try std.testing.expectEqual(@as(i32, 2), tex.width);
    try std.testing.expectEqual(@as(i32, 2), tex.height);

    const tex_data: *PixmanTextureData = @ptrCast(@alignCast(tex.data));
    try std.testing.expectEqualSlices(u8, &pixels, tex_data.pixels);

    // The import owns a copy: clobber the source, the texture is unchanged.
    pixels[0] = 0;
    try std.testing.expectEqual(@as(u8, 1), tex_data.pixels[0]);
}

test "1:1 blit" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();

    const pattern = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    const tex = try PixmanRenderer.importMemory(renderer, 2, 2, 8, &pattern);
    defer tex.destroy();

    const pass = renderer.beginPass(fb).?;
    pass.addTexture(tex, .{ .dst = .{ .x = 1, .y = 1, .width = 2, .height = 2 } });
    pass.submit();

    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(1, 1));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(2, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(1, 2));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, fb.pixelAt(2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));
}

/// An asymmetric 4x4 fixture: every texel a different opaque color, so
/// a wrong crop, scale, flip or rotation shows a DIFFERENT pixel rather
/// than a symmetric coincidence. Memory bytes are B,G,R,A.
const ramp4x4 = blk: {
    var buf: [4 * 4 * 4]u8 = undefined;
    var y: i32 = 0;
    while (y < 4) : (y += 1) {
        var x: i32 = 0;
        while (x < 4) : (x += 1) {
            const i = y * 4 + x;
            buf[i * 4 + 0] = @intCast(i * 16 + 1);
            buf[i * 4 + 1] = @intCast(255 - 11 * (i + 1));
            buf[i * 4 + 2] = @intCast(3 * i + 5);
            buf[i * 4 + 3] = 255;
        }
    }
    break :blk buf;
};

fn rampTexel(x: i32, y: i32) [4]u8 {
    const off: usize = @intCast((y * 4 + x) * 4);
    return ramp4x4[off..][0..4].*;
}

/// The bilinear blend of the four texels of the crop (1,1)-(3,3), with
/// `wx`/`wy` the weight of the crop's SECOND column/row (1 - w goes to
/// the first), rounded the way the framebuffer stores a blend. The
/// weights come from the sampling contract — texel centres at half
/// integers, a destination pixel sampled at its centre, the filter
/// clamped to the crop's centre bounds — not from the rasterizer.
fn cropBlend(wx: f64, wy: f64) [4]u8 {
    const w00 = (1.0 - wx) * (1.0 - wy);
    const w10 = wx * (1.0 - wy);
    const w01 = (1.0 - wx) * wy;
    const w11 = wx * wy;
    var out: [4]u8 = undefined;
    for (0..4) |ch| {
        const v = w00 * @as(f64, @floatFromInt(rampTexel(1, 1)[ch])) +
            w10 * @as(f64, @floatFromInt(rampTexel(2, 1)[ch])) +
            w01 * @as(f64, @floatFromInt(rampTexel(1, 2)[ch])) +
            w11 * @as(f64, @floatFromInt(rampTexel(2, 2)[ch]));
        out[ch] = @intFromFloat(std.math.round(v));
    }
    return out;
}

/// Two texels blended with weight `w` on the second, rounded as the
/// framebuffer stores a blend.
fn blendPair(a: [4]u8, b: [4]u8, w: f64) [4]u8 {
    var out: [4]u8 = undefined;
    for (0..4) |ch| {
        const av: f64 = @floatFromInt(a[ch]);
        const bv: f64 = @floatFromInt(b[ch]);
        out[ch] = @intFromFloat(std.math.round(av + (bv - av) * w));
    }
    return out;
}

test "scaled and cropped texture blits sample the texture" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try Framebuffer.create(allocator, 8, 4);
    defer fb.deinit();
    const tex = try PixmanRenderer.importMemory(renderer, 4, 4, 16, &ramp4x4);
    defer tex.destroy();

    // Halving maps each destination pixel centre halfway between four
    // buffer texel centres; all four contribute equally.
    const small = renderer.beginPass(fb).?;
    small.addTexture(tex, .{ .dst = .{ .x = 0, .y = 0, .width = 2, .height = 2 } });
    small.submit();
    for (0..2) |j| {
        for (0..2) |i| {
            const x: i32 = @intCast(i * 2);
            const y: i32 = @intCast(j * 2);
            var want: [4]u8 = undefined;
            for (0..4) |ch| {
                const sum = @as(u16, rampTexel(x, y)[ch]) +
                    rampTexel(x + 1, y)[ch] + rampTexel(x, y + 1)[ch] +
                    rampTexel(x + 1, y + 1)[ch];
                want[ch] = @intCast((sum + 2) / 4);
            }
            try std.testing.expectEqual(want, fb.pixelAt(@intCast(i), @intCast(j)));
        }
    }

    // Raw crop (1,1)-(3,3) at 1:1 is an exact copy of that block.
    fb.fill(.{ 0, 0, 0, 0 });
    const cropped = renderer.beginPass(fb).?;
    cropped.addTexture(tex, .{
        .src = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
        .dst = .{ .x = 4, .y = 0, .width = 2, .height = 2 },
    });
    cropped.submit();
    try std.testing.expectEqual(rampTexel(1, 1), fb.pixelAt(4, 0));
    try std.testing.expectEqual(rampTexel(2, 2), fb.pixelAt(5, 1));
    // ... and nothing outside the dst rect moved.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(6, 0));

    // Magnify the crop 2x. Pixel (i, j) is sampled at its CENTRE, so its
    // texel position is 1 + (i + 0.5)/2 and the crop-edge clamp pins that
    // to [1.5, 2.5]: columns 0 and 3 read the crop's edge texels WHOLE,
    // the interior columns blend them 3:1 and 1:3 — the same weights down
    // each row. (`weight` is the weight of the crop's second
    // column/row, read off the index positions 1.0, 1.25, 1.75, 2.0.)
    const weight = [_]f64{ 0.0, 0.25, 0.75, 1.0 };
    fb.fill(.{ 0, 0, 0, 0 });
    const big = renderer.beginPass(fb).?;
    big.addTexture(tex, .{
        .src = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
        .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
    });
    big.submit();
    for (0..4) |j| {
        for (0..4) |i| {
            const want = cropBlend(weight[i], weight[j]);
            std.testing.expectEqual(want, fb.pixelAt(@intCast(i), @intCast(j))) catch |err| {
                std.debug.print("magnified crop at ({d}, {d}): composited {any}, expected {any}\n", .{
                    i, j, fb.pixelAt(@intCast(i), @intCast(j)), want,
                });
                return err;
            };
        }
    }
    // Spelled out: the corners are the crop's own texels, and (1, 1) is
    // the 3:1 blend of the four crop texels —
    // 0.5625·(1,1) + 0.1875·(2,1) + 0.1875·(1,2) + 0.0625·(2,2):
    //   B 0.5625·81 + 0.1875·97 + 0.1875·145 + 0.0625·161 = 101
    //   G 0.5625·189 + 0.1875·178 + 0.1875·145 + 0.0625·134 = 175.25
    //   R 0.5625·20 + 0.1875·23 + 0.1875·32 + 0.0625·35 = 23.75
    // rounded as the framebuffer stores a blend.
    try std.testing.expectEqual(rampTexel(1, 1), fb.pixelAt(0, 0));
    try std.testing.expectEqual(rampTexel(2, 2), fb.pixelAt(3, 3));
    try std.testing.expectEqual([4]u8{ 101, 175, 24, 255 }, fb.pixelAt(1, 1));
}

test "a fractional destination scale samples between texels" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try Framebuffer.create(allocator, 4, 1);
    defer fb.deinit();

    // 2x1: red left, green right (memory bytes B,G,R,A).
    const pattern = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 };
    const tex = try PixmanRenderer.importMemory(renderer, 2, 1, 8, &pattern);
    defer tex.destroy();

    // Stretched 2x, sampled at each pixel's CENTRE (module docs,
    // "# Sampling geometry", the GPU's convention): pixel i reads texel
    // position (i + 0.5)/2 — 0.25, 0.75, 1.25, 1.75 — which the
    // whole-texture clamp pins to [0.5, 1.5]. Pixel 0 is therefore texel
    // 0 whole, pixel 1 three quarters red (0.25*255 = 63.75 rounds to
    // 64, 0.75*255 = 191.25 to 191), pixel 2 three quarters green and
    // pixel 3 texel 1 whole. The GPU filters exactly this, so the two
    // backends agree on a stretched draw instead of half a texel apart.
    const pass = renderer.beginPass(fb).?;
    pass.addTexture(tex, .{ .dst = .{ .x = 0, .y = 0, .width = 4, .height = 1 } });
    pass.submit();

    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 64, 191, 255 }, fb.pixelAt(1, 0));
    try std.testing.expectEqual([4]u8{ 0, 191, 64, 255 }, fb.pixelAt(2, 0));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(3, 0));
}

test "every buffer transform is sampled through its inverse" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try Framebuffer.create(allocator, 8, 8);
    defer fb.deinit();
    const tex = try PixmanRenderer.importMemory(renderer, 4, 4, 16, &ramp4x4);
    defer tex.destroy();

    // Each case: the transform, the destination rect (the surface the
    // transform implies: a 90-family swaps the axes) and, per surface
    // pixel (sx, sy), the buffer texel it must display — written from
    // the wl_output.transform definition, not from the map under test.
    const cases = [_]struct {
        transform: geom.Transform,
        dst: geom.FRect,
        texel: *const fn (sx: i32, sy: i32) geom.Point,
    }{
        .{ .transform = .normal, .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .texel = struct {
            fn f(sx: i32, sy: i32) geom.Point {
                return .{ .x = sx, .y = sy };
            }
        }.f },
        .{ .transform = .@"90", .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .texel = struct {
            fn f(sx: i32, sy: i32) geom.Point {
                return .{ .x = sy, .y = 3 - sx };
            }
        }.f },
        .{ .transform = .@"180", .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .texel = struct {
            fn f(sx: i32, sy: i32) geom.Point {
                return .{ .x = 3 - sx, .y = 3 - sy };
            }
        }.f },
        .{ .transform = .@"270", .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .texel = struct {
            fn f(sx: i32, sy: i32) geom.Point {
                return .{ .x = 3 - sy, .y = sx };
            }
        }.f },
        .{ .transform = .flipped, .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .texel = struct {
            fn f(sx: i32, sy: i32) geom.Point {
                return .{ .x = 3 - sx, .y = sy };
            }
        }.f },
        .{ .transform = .flipped_90, .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .texel = struct {
            fn f(sx: i32, sy: i32) geom.Point {
                return .{ .x = sy, .y = sx };
            }
        }.f },
        .{ .transform = .flipped_180, .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .texel = struct {
            fn f(sx: i32, sy: i32) geom.Point {
                return .{ .x = sx, .y = 3 - sy };
            }
        }.f },
        // FLIPPED_270 (wlr_box_transform util/box.c:143-146): x' =
        // height - y - h, y' = width - x - w, so the surface x axis
        // maps to the buffer's y axis, bounded by the buffer HEIGHT.
        .{ .transform = .flipped_270, .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .texel = struct {
            fn f(sx: i32, sy: i32) geom.Point {
                return .{ .x = 3 - sy, .y = 3 - sx };
            }
        }.f },
    };
    for (cases) |c| {
        fb.fill(.{ 0, 0, 0, 0 });
        const pass = renderer.beginPass(fb).?;
        pass.addTexture(tex, .{ .dst = c.dst, .transform = c.transform });
        pass.submit();
        var j: i32 = 0;
        while (j < 4) : (j += 1) {
            var i: i32 = 0;
            while (i < 4) : (i += 1) {
                const t = c.texel(i, j);
                try std.testing.expectEqual(rampTexel(t.x, t.y), fb.pixelAt(i, j));
            }
        }
    }
}

test "a transform and a raw crop compose exactly once" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();
    const tex = try PixmanRenderer.importMemory(renderer, 4, 4, 16, &ramp4x4);
    defer tex.destroy();

    // A 180-degree surface showing the raw crop (0,1)-(4,3): the crop is
    // the buffer's middle rows, mirrored horizontally. Applying the
    // crop twice would show a different pair of rows.
    const pass = renderer.beginPass(fb).?;
    pass.addTexture(tex, .{
        .src = .{ .x = 0, .y = 1, .width = 4, .height = 2 },
        .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .transform = .@"180",
    });
    pass.submit();
    // Derived from the sampling contract, not from the rasterizer: the
    // crop's surface extent is the full 4x4 quad, so destination pixel
    // (i, j) — sampled at its CENTRE — lands on surface position
    // (i + 0.5, j + 0.5), and the 180-degree inverse maps that to
    // texel position (3.5 - i, 3 - (j + 0.5)/2). Converting to texel
    // indices (position - 0.5) and clamping the position to the crop's
    // centre bounds y in [1.5, 2.5] gives, per pixel:
    //   (0,0) column 3 at row 2.0 -> texel (3,2) whole
    //   (3,0) column 0 at row 2.0 -> texel (0,2) whole
    //   (0,1) column 3 at row 2.25 -> 25% row 1 + 75% row 2
    //   (0,2) column 3 at row 1.75 -> 75% row 1 + 25% row 2
    //   (0,3) column 3 at row 1.5 -> texel (3,1) whole (clamped)
    try std.testing.expectEqual(rampTexel(3, 2), fb.pixelAt(0, 0));
    try std.testing.expectEqual(rampTexel(0, 2), fb.pixelAt(3, 0));
    try std.testing.expectEqual(blendPair(rampTexel(3, 1), rampTexel(3, 2), 0.75), fb.pixelAt(0, 1));
    try std.testing.expectEqual(blendPair(rampTexel(3, 1), rampTexel(3, 2), 0.25), fb.pixelAt(0, 2));
    // The crop spans the buffer's full width, so destination x lands
    // exactly on buffer column `3 - x`: the same two rows, one column
    // over.
    try std.testing.expectEqual(blendPair(rampTexel(2, 1), rampTexel(2, 2), 0.75), fb.pixelAt(1, 1));
    try std.testing.expectEqual(blendPair(rampTexel(0, 1), rampTexel(0, 2), 0.25), fb.pixelAt(3, 2));
    // The last surface row samples row 1.25, which is OUTSIDE the crop
    // (it holds buffer rows 1 and 2 only). The crop-edge clamp pulls it
    // to the crop's first row centre, so the row shows that row whole
    // instead of fading in buffer row 0 — the behaviour a wp_viewport
    // source needs, and what the GPU's u_texel_clamp does.
    try std.testing.expectEqual(rampTexel(3, 1), fb.pixelAt(0, 3));
    try std.testing.expectEqual(rampTexel(0, 1), fb.pixelAt(3, 3));
}

test "rect fill and alpha blend" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    // Opaque fill. Memory bytes are B,G,R,A, so red is [0,0,255,255].
    const fb = try Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();
    const pass = renderer.beginPass(fb).?;
    pass.addRect(.{ .x = 1, .y = 1, .width = 2, .height = 2 }, .{ 1.0, 0.0, 0.0, 1.0 });
    pass.submit();

    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(1, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));

    // Premultiplied-over blend: half blue over white.
    const fb2 = try Framebuffer.create(allocator, 4, 4);
    defer fb2.deinit();
    fb2.fill(.{ 255, 255, 255, 255 });
    const pass2 = renderer.beginPass(fb2).?;
    pass2.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ 0.0, 0.0, 1.0, 0.5 });
    pass2.submit();

    // addRect premultiplies the straight color: a = round(0.5*255) = 128,
    // B = round(1.0*0.5*255) = 128 -> src bytes B,G,R,A = {128, 0, 0, 128}.
    // Over white with out = src + dst*(1-a); bytes in memory order B,G,R,A:
    // B: (128*255 + 255*127 + 127)/255 = 255;  G,R: (0*255 + 255*127 + 127)/255 = 127
    // A: (128*255 + 255*127 + 127)/255 = 255
    try std.testing.expectEqual([4]u8{ 255, 127, 127, 255 }, fb2.pixelAt(1, 1));
}
