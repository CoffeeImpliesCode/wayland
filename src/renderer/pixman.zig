//! Pixman-style CPU renderer: compositing in memory, no GPU.
//!
//! Canonical renderer for headless backends and tests; reference
//! implementation of the Pass contract. M1 scope: 1:1 texture blits and
//! straight-alpha rect fills. Scaling, cropping and texture alpha arrive
//! with M2.
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
        const row_len: usize = @intCast(fb.width * 4);
        var y: usize = 0;
        while (y < @as(usize, @intCast(fb.height))) : (y += 1) {
            const row = fb.data[y * @as(usize, @intCast(fb.stride)) ..][0..row_len];
            var x: usize = 0;
            while (x < row_len) : (x += 4) row[x..][0..4].* = color;
        }
    }

    /// Read one ARGB8888 pixel (test helper).
    pub fn pixelAt(fb: *const Framebuffer, x: i32, y: i32) [4]u8 {
        const off = @as(usize, @intCast(y)) * @as(usize, @intCast(fb.stride)) + @as(usize, @intCast(x)) * 4;
        return fb.data[off..][0..4].*;
    }
};

const PixmanTextureData = struct {
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
};

fn beginPass(renderer: *renderer_mod.Renderer, target: *anyopaque) ?*pass_mod.Pass {
    const data: *PixmanData = @ptrCast(@alignCast(renderer.data));
    data.pass_data.fb = @ptrCast(@alignCast(target));
    data.pass = .{ .impl = &pass_impl, .data = &data.pass_data };
    return &data.pass;
}

fn destroyRenderer(renderer: *renderer_mod.Renderer) void {
    const data: *PixmanData = @ptrCast(@alignCast(renderer.data));
    renderer.allocator.destroy(data);
}

fn destroyTexture(texture: *texture_mod.Texture) void {
    const tex_data: *PixmanTextureData = @ptrCast(@alignCast(texture.data));
    const allocator = tex_data.allocator;
    allocator.free(tex_data.pixels);
    allocator.destroy(tex_data);
    allocator.destroy(texture);
}

fn addTexture(pass: *pass_mod.Pass, texture: *texture_mod.Texture, src: ?geom.FRect, dst: geom.FRect, alpha: f32) void {
    const data: *PixmanPassData = @ptrCast(@alignCast(pass.data));
    const fb = data.fb orelse return;
    const tex_data: *PixmanTextureData = @ptrCast(@alignCast(texture.data));
    _ = alpha; // M1: straight blit; alpha compositing arrives with M2.

    const tw: f64 = @floatFromInt(texture.width);
    const th: f64 = @floatFromInt(texture.height);
    const src_whole = if (src) |s| s.x == 0 and s.y == 0 and s.width == tw and s.height == th else true;
    if (!src_whole or dst.width != tw or dst.height != th or dst.x != @floor(dst.x) or dst.y != @floor(dst.y)) {
        log_mod.warn("add_texture: scaling/cropping unsupported (M2); skipping", data.io, data.log_cfg, "pixman", .{});
        return;
    }

    const dst_x: i32 = @intFromFloat(dst.x);
    const dst_y: i32 = @intFromFloat(dst.y);
    const x0 = @max(dst_x, 0);
    const y0 = @max(dst_y, 0);
    const x1 = @min(dst_x + texture.width, fb.width);
    const y1 = @min(dst_y + texture.height, fb.height);
    if (x0 >= x1 or y0 >= y1) return;

    const fb_stride: usize = @intCast(fb.stride);
    const tex_stride: usize = @intCast(tex_data.stride);
    var row = y0;
    while (row < y1) : (row += 1) {
        const src_off = @as(usize, @intCast(row - dst_y)) * tex_stride + @as(usize, @intCast(x0 - dst_x)) * 4;
        const dst_off = @as(usize, @intCast(row)) * fb_stride + @as(usize, @intCast(x0)) * 4;
        const n: usize = @intCast((x1 - x0) * 4);
        @memcpy(fb.data[dst_off..][0..n], tex_data.pixels[src_off..][0..n]);
    }
}

fn addRect(pass: *pass_mod.Pass, rect: geom.Rect, color: [4]f32) void {
    const data: *PixmanPassData = @ptrCast(@alignCast(pass.data));
    const fb = data.fb orelse return;

    const x0 = @max(rect.x, 0);
    const y0 = @max(rect.y, 0);
    const x1 = @min(rect.x + rect.width, fb.width);
    const y1 = @min(rect.y + rect.height, fb.height);
    if (x0 >= x1 or y0 >= y1) return;

    const src: [4]u8 = .{
        @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0)),
        @intFromFloat(@round(std.math.clamp(color[3], 0.0, 1.0) * 255.0)),
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

/// Straight-alpha blend: dst = src*a + dst*(1-a) per channel.
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
        dst[i] = @intCast((s * a + d * (255 - a) + 127) / 255);
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
    pass.addTexture(tex, null, .{ .x = 1, .y = 1, .width = 2, .height = 2 }, 1.0);
    pass.submit();

    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(1, 1));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(2, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(1, 2));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, fb.pixelAt(2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));
}

test "scaled texture blit is skipped" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const fb = try Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();

    const pattern = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const tex = try PixmanRenderer.importMemory(renderer, 2, 2, 8, &pattern);
    defer tex.destroy();

    // dst size != texture size: M1 skips with a warning, framebuffer untouched.
    const pass = renderer.beginPass(fb).?;
    pass.addTexture(tex, null, .{ .x = 0, .y = 0, .width = 3, .height = 2 }, 1.0);
    pass.submit();

    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(2, 1));
}

test "rect fill and alpha blend" {
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    // Opaque fill.
    const fb = try Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();
    const pass = renderer.beginPass(fb).?;
    pass.addRect(.{ .x = 1, .y = 1, .width = 2, .height = 2 }, .{ 1.0, 0.0, 0.0, 1.0 });
    pass.submit();

    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(1, 1));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));

    // Straight-alpha blend: half blue over white.
    const fb2 = try Framebuffer.create(allocator, 4, 4);
    defer fb2.deinit();
    fb2.fill(.{ 255, 255, 255, 255 });
    const pass2 = renderer.beginPass(fb2).?;
    pass2.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ 0.0, 0.0, 1.0, 0.5 });
    pass2.submit();

    // dst = src*a + dst*(1-a), a = 128:
    // R,G: (0*128 + 255*127 + 127)/255 = 127;  B: (255*128 + 255*127 + 127)/255 = 255
    // A: (128*128 + 255*127 + 127)/255 = 191
    try std.testing.expectEqual([4]u8{ 127, 127, 255, 191 }, fb2.pixelAt(1, 1));
}
