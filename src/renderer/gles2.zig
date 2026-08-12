//! GLES2/EGL renderer: GPU compositing via libEGL + libGLESv2.
//!
//! Reference implementation of the M2 Pass contract — scaling, cropping
//! and per-op alpha, the features pixman's M1 pass warns about and
//! skips. Composites into an FBO-backed target with a single shader
//! program (unit quad + u_modulate uniform), premultiplied-alpha over
//! blending matching wlr_render_color (include/wlr/render/pass.h:135-137)
//! and pixman.zig's blendPixel.
//!
//! # EGL
//! Renders headless: a surfaceless EGL context (EGL 1.5
//! eglMakeCurrent with EGL_NO_SURFACE; Mesa's llvmpipe software GL
//! supports this). The context is created and bound on the calling
//! thread at create() and stays current until destroy(): this renderer
//! is single-threaded, like the rest of the compositor. All GL objects
//! (textures, targets) must be created/destroyed while the context is
//! current, i.e. between Gles2Renderer.create() and destroy().
//!
//! # Target
//! The render target is a Gles2Target: an FBO with a GL_RGBA color
//! texture (see Gles2Target). begin_pass expects *Gles2Target, exactly
//! as pixman's begin_pass expects *Framebuffer. Each submit() clears the
//! target to transparent black first — a GL texture holds undefined
//! bytes between passes, unlike pixman's zero-initialized Framebuffer —
//! then draws the queued operations. Gles2Target.readPixels returns the
//! content as top-down premultiplied ARGB8888 bytes (B, G, R, A in
//! memory) for scanout: the same byte order as PixmanRenderer's
//! Framebuffer.
//!
//! # Wiring contract
//! The orchestrator wires this module in build.zig like the pixman_c
//! pattern: translate src/renderer/gles2_c.h with addTranslateC (include
//! root from `pkg-config --cflags egl glesv2`, i.e. nixpkgs#libglvnd.dev),
//! import the module as `gles2_c`, and link `egl` + `glesv2`
//! (pkg-config names for libglvnd's libEGL/libGLESv2).
//!
//! Imports: utils/*, renderer/{renderer,pass,texture}.zig, gles2_c.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const log_mod = @import("../utils/log.zig");
const renderer_mod = @import("renderer.zig");
const pass_mod = @import("pass.zig");
const texture_mod = @import("texture.zig");
const c = @import("gles2_c");

/// wl_shm format code for ARGB8888 (little-endian bytes: B, G, R, A).
pub const format_argb8888: u32 = 0;

/// Render target: an FBO with a GL_RGBA color texture. The compositor
/// creates one per output (Gles2Target.create, requires a current GL
/// context) and passes it to renderer.beginPass(); scanout reads it back
/// with readPixels (top-down premultiplied ARGB8888, bytes B,G,R,A in
/// memory — the same layout as PixmanRenderer's Framebuffer).
pub const Gles2Target = struct {
    /// FBO handle; drawing targets this.
    fbo: c.GLuint,
    /// Backing color texture (the FBO's GL_COLOR_ATTACHMENT0).
    tex: c.GLuint,
    width: i32,
    height: i32,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, w: i32, h: i32) !*Gles2Target {
        if (w <= 0 or h <= 0) return error.InvalidSize;
        const self = try allocator.create(Gles2Target);
        errdefer allocator.destroy(self);
        self.* = .{
            .fbo = undefined,
            .tex = undefined,
            .width = w,
            .height = h,
            .allocator = allocator,
        };
        c.glGenFramebuffers(1, &self.fbo);
        errdefer c.glDeleteFramebuffers(1, &self.fbo);
        c.glGenTextures(1, &self.tex);
        errdefer c.glDeleteTextures(1, &self.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        setTextureParams();
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (status != c.GL_FRAMEBUFFER_COMPLETE) return error.FramebufferFailed;
        return self;
    }

    pub fn destroy(self: *Gles2Target) void {
        const allocator = self.allocator;
        c.glDeleteFramebuffers(1, &self.fbo);
        c.glDeleteTextures(1, &self.tex);
        allocator.destroy(self);
    }

    /// Read the target back as top-down premultiplied ARGB8888 bytes
    /// (B, G, R, A in memory) — ready for scanout. The caller frees the
    /// returned slice.
    pub fn readPixels(self: *Gles2Target, allocator: std.mem.Allocator) ![]u8 {
        const w: usize = @intCast(self.width);
        const h: usize = @intCast(self.height);
        const row_bytes = std.math.mul(usize, w, 4) catch return error.InvalidSize;
        const size = std.math.mul(usize, row_bytes, h) catch return error.InvalidSize;
        const out = try allocator.alloc(u8, size);
        errdefer allocator.free(out);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        defer c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
        c.glReadPixels(0, 0, self.width, self.height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, out.ptr);
        // glReadPixels rows are bottom-up (GL origin is bottom-left); flip
        // to top-down, then swap R/B per pixel (RGBA -> BGRA memory bytes).
        const tmp = try allocator.alloc(u8, row_bytes);
        defer allocator.free(tmp);
        var row: usize = 0;
        while (row < h / 2) : (row += 1) {
            const top = row * row_bytes;
            const bottom = (h - 1 - row) * row_bytes;
            @memcpy(tmp, out[top..][0..row_bytes]);
            @memcpy(out[top..][0..row_bytes], out[bottom..][0..row_bytes]);
            @memcpy(out[bottom..][0..row_bytes], tmp);
        }
        var i: usize = 0;
        while (i < size) : (i += 4) {
            const t = out[i];
            out[i] = out[i + 2];
            out[i + 2] = t;
        }
        return out;
    }
};

/// Texture payload. PUBLISHED so other modules cast `Texture.data` to
/// this exact type — never to a locally re-declared mirror. (Zig 0.16
/// lays default structs out by alignment, not declaration order, so two
/// look-alike declarations are NOT guaranteed identical; one shared
/// declaration removes the hazard. `extern struct` is not usable here:
/// `std.mem.Allocator` is not a C-ABI type and this struct never crosses
/// the FFI boundary.)
pub const Gles2TextureData = struct {
    /// GL_TEXTURE_2D handle holding the premultiplied ARGB8888 pixels
    /// (uploaded as GL_RGBA bytes; the shader swizzles .bgra).
    tex: c.GLuint,
    /// Upload stride, bytes per row (kept to mirror pixman's
    /// updateMemory contract: a stride change forces a re-import).
    stride: i32,
    allocator: std.mem.Allocator,
};

/// A deferred draw operation (M2 pass semantics: add_* record, submit
/// draws).
const Cmd = union(enum) {
    texture: struct {
        tex: *texture_mod.Texture,
        /// Source rect in texture pixels, normalized (clamped) to the
        /// texture bounds.
        src: geom.FRect,
        dst: geom.FRect,
        alpha: f32,
    },
    rect: struct {
        rect: geom.Rect,
        color: [4]f32,
    },
};

const Gles2PassData = struct {
    /// Back-pointer to the renderer data (uniform locations, program).
    owner: *Gles2Data,
    target: ?*Gles2Target = null,
    cmds: std.ArrayListUnmanaged(Cmd) = .empty,
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
};

const Gles2Data = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    dpy: c.EGLDisplay,
    ctx: c.EGLContext,
    program: c.GLuint,
    vbo: c.GLuint,
    white_tex: c.GLuint,
    loc_pos: c.GLint,
    loc_uv: c.GLint,
    loc_tex: c.GLint,
    loc_offset: c.GLint,
    loc_scale: c.GLint,
    loc_viewport: c.GLint,
    loc_uv_offset: c.GLint,
    loc_uv_scale: c.GLint,
    loc_modulate: c.GLint,
    pass: pass_mod.Pass,
    pass_data: Gles2PassData,
};

/// Hand-written declaration: translate-c renders the
/// `const GLchar *const *` parameter awkwardly; the C ABI is a simple
/// pointer to an array of null-terminated strings.
extern fn glShaderSource(
    shader: c.GLuint,
    count: c.GLsizei,
    string: [*]const [*:0]const u8,
    length: ?*const c.GLint,
) callconv(.c) void;

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

pub const Gles2Renderer = struct {
    /// Create the renderer: initialize a surfaceless EGL display/context
    /// (EGL 1.5, EGL_MESA_platform_surfaceless with eglGetDisplay
    /// fallback), compile the shader program, and bind the context on
    /// the calling thread. The context stays current until destroy().
    pub fn create(allocator: std.mem.Allocator, io: *std.Io, log_cfg: *const log_mod.Config) !*renderer_mod.Renderer {
        const data = try allocator.create(Gles2Data);
        errdefer allocator.destroy(data);
        data.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .dpy = null,
            .ctx = null,
            .program = 0,
            .vbo = 0,
            .white_tex = 0,
            .loc_pos = -1,
            .loc_uv = -1,
            .loc_tex = -1,
            .loc_offset = -1,
            .loc_scale = -1,
            .loc_viewport = -1,
            .loc_uv_offset = -1,
            .loc_uv_scale = -1,
            .loc_modulate = -1,
            // SAFETY: pass.impl/data are filled by begin_pass before use.
            .pass = undefined,
            .pass_data = .{ .owner = data, .allocator = allocator, .io = io, .log_cfg = log_cfg },
        };
        try initEgl(data);
        errdefer {
            if (data.ctx != null) deinitGl(data);
            teardownEgl(data);
        }
        try initGl(data);
        return renderer_mod.Renderer.create(allocator, io, log_cfg, &renderer_impl, data, &.{format_argb8888});
    }

    /// Import an ARGB8888 pixel buffer as a GL texture. The pixels are
    /// copied into GPU memory immediately (glTexImage2D). Stored as
    /// delivered: premultiplied ARGB8888 bytes (B, G, R, A in memory),
    /// exactly like pixman's importMemory — no premultiplication here
    /// (wl_buffer, protocols/wayland/wayland.xml:533-536; wlroots
    /// render/pixman/renderer.c pixman_texture_from_buffer).
    pub fn importMemory(
        renderer: *renderer_mod.Renderer,
        w: i32,
        h: i32,
        stride: i32,
        pixels: []const u8,
    ) !*texture_mod.Texture {
        if (w <= 0 or h <= 0 or stride <= 0) return error.InvalidSize;
        const tight = std.math.mul(i32, w, 4) catch return error.InvalidSize;
        if (stride < tight) return error.InvalidSize;
        const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
        const size = @as(usize, @intCast(stride)) * @as(usize, @intCast(h));
        if (pixels.len < size) return error.InvalidSize;

        const tex_data = try data.allocator.create(Gles2TextureData);
        errdefer data.allocator.destroy(tex_data);
        var gl_tex: c.GLuint = undefined;
        c.glGenTextures(1, &gl_tex);
        if (gl_tex == 0) return error.TextureCreateFailed;
        errdefer c.glDeleteTextures(1, &gl_tex);

        c.glBindTexture(c.GL_TEXTURE_2D, gl_tex);
        defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
        setTextureParams();
        uploadTexturePixels(gl_tex, w, h, stride, pixels[0..size]);

        tex_data.* = .{ .tex = gl_tex, .stride = stride, .allocator = data.allocator };
        const tex = try data.allocator.create(texture_mod.Texture);
        tex.* = .{ .impl = &texture_impl, .data = tex_data, .width = w, .height = h };
        return tex;
    }

    /// Overwrite an imported texture's pixels in place (glTexSubImage2D)
    /// when the geometry matches. Returns false when the texture must be
    /// re-imported (size or stride changed) — the same hot-path contract
    /// as pixman's updateMemory. No allocation, no texture churn.
    pub fn updateMemory(
        texture: *texture_mod.Texture,
        w: i32,
        h: i32,
        stride: i32,
        pixels: []const u8,
    ) bool {
        const tex_data: *Gles2TextureData = @ptrCast(@alignCast(texture.data));
        if (texture.width != w or texture.height != h or tex_data.stride != stride) return false;
        const size = @as(usize, @intCast(stride)) * @as(usize, @intCast(h));
        if (pixels.len < size) return false;
        c.glBindTexture(c.GL_TEXTURE_2D, tex_data.tex);
        defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
        updateTexturePixels(tex_data.tex, w, h, stride, pixels);
        return true;
    }
};

fn beginPass(renderer: *renderer_mod.Renderer, target: *anyopaque) ?*pass_mod.Pass {
    const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
    data.pass_data.target = @as(*Gles2Target, @ptrCast(@alignCast(target)));
    data.pass_data.cmds.clearRetainingCapacity();
    data.pass = .{ .impl = &pass_impl, .data = &data.pass_data };
    return &data.pass;
}

fn destroyRenderer(allocator: std.mem.Allocator, data: *anyopaque) void {
    const r: *Gles2Data = @ptrCast(@alignCast(data));
    deinitGl(r);
    teardownEgl(r);
    r.pass_data.cmds.deinit(allocator);
    allocator.destroy(r);
}

fn destroyTexture(texture: *texture_mod.Texture) void {
    const tex_data: *Gles2TextureData = @ptrCast(@alignCast(texture.data));
    const allocator = tex_data.allocator;
    c.glDeleteTextures(1, &tex_data.tex);
    allocator.destroy(tex_data);
    allocator.destroy(texture);
}

fn addTexture(pass: *pass_mod.Pass, texture: *texture_mod.Texture, src: ?geom.FRect, dst: geom.FRect, alpha: f32) void {
    const data: *Gles2PassData = @ptrCast(@alignCast(pass.data));
    if (data.target == null) return;
    // `!(dst.width > 0)` also rejects NaN (and negative) geometry.
    if (!(dst.width > 0) or !(dst.height > 0) or !(alpha > 0)) return;
    const tw: f64 = @floatFromInt(texture.width);
    const th: f64 = @floatFromInt(texture.height);
    const s = src orelse geom.FRect{ .x = 0, .y = 0, .width = tw, .height = th };
    // NaN source geometry would smear the clamp math; reject it. Positive
    // width/height checked here, then the intersection check below.
    if (std.math.isNan(s.x) or std.math.isNan(s.y)) return;
    if (!(s.width > 0) or !(s.height > 0)) return;
    // Clamp the source rect into the texture (the sampler CLAMP_TO_EDGE
    // would smear edge texels for out-of-bounds sources; cropping to the
    // valid region is the correct crop).
    const sx0 = std.math.clamp(s.x, 0.0, tw);
    const sy0 = std.math.clamp(s.y, 0.0, th);
    const sx1 = std.math.clamp(s.x + s.width, 0.0, tw);
    const sy1 = std.math.clamp(s.y + s.height, 0.0, th);
    if (sx1 <= sx0 or sy1 <= sy0) return;
    const norm: geom.FRect = .{ .x = sx0, .y = sy0, .width = sx1 - sx0, .height = sy1 - sy0 };
    data.cmds.append(data.allocator, .{
        .texture = .{ .tex = texture, .src = norm, .dst = dst, .alpha = alpha },
    }) catch {
        log_mod.warn("add_texture: out of memory; dropping draw op", data.io, data.log_cfg, "gles2", .{});
    };
}

fn addRect(pass: *pass_mod.Pass, rect: geom.Rect, color: [4]f32) void {
    const data: *Gles2PassData = @ptrCast(@alignCast(pass.data));
    if (data.target == null) return;
    // `!(color[3] > 0)` skips zero, negative and NaN alpha.
    if (rect.isEmpty() or !(color[3] > 0)) return;
    data.cmds.append(data.allocator, .{ .rect = .{ .rect = rect, .color = color } }) catch {
        log_mod.warn("add_rect: out of memory; dropping draw op", data.io, data.log_cfg, "gles2", .{});
    };
}

/// Draw the queued operations into the pass target. Clears the target to
/// transparent black first (see the module docs), then draws each op
/// with the unit-quad program and premultiplied-over blending.
fn submitPass(pass: *pass_mod.Pass) void {
    const data: *Gles2PassData = @ptrCast(@alignCast(pass.data));
    const target = data.target orelse return;
    const r = data.owner;

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, target.fbo);
    defer c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glViewport(0, 0, target.width, target.height);
    c.glClearColor(0.0, 0.0, 0.0, 0.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    c.glUseProgram(r.program);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glUniform1i(r.loc_tex, 0);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA); // premultiplied over
    c.glBindBuffer(c.GL_ARRAY_BUFFER, r.vbo);
    c.glEnableVertexAttribArray(@intCast(r.loc_pos));
    c.glVertexAttribPointer(@intCast(r.loc_pos), 2, c.GL_FLOAT, c.GL_FALSE, 16, null);
    c.glEnableVertexAttribArray(@intCast(r.loc_uv));
    c.glVertexAttribPointer(@intCast(r.loc_uv), 2, c.GL_FLOAT, c.GL_FALSE, 16, @ptrFromInt(8));

    for (data.cmds.items) |cmd| switch (cmd) {
        .texture => |t| drawTextureQuad(r, target, t.tex, t.src, t.dst, t.alpha),
        .rect => |rc| drawRectQuad(r, target, rc.rect, rc.color),
    };
    data.cmds.clearRetainingCapacity();
}

fn drawTextureQuad(
    r: *Gles2Data,
    target: *Gles2Target,
    tex: *texture_mod.Texture,
    src: geom.FRect,
    dst: geom.FRect,
    alpha: f32,
) void {
    const tex_data: *Gles2TextureData = @ptrCast(@alignCast(tex.data));
    const tw: f64 = @floatFromInt(tex.width);
    const th: f64 = @floatFromInt(tex.height);
    const uv_offset = [2]f32{ @floatCast(src.x / tw), @floatCast(src.y / th) };
    const uv_scale = [2]f32{ @floatCast(src.width / tw), @floatCast(src.height / th) };
    // The texture texel is already premultiplied; scaling all four
    // channels by the opacity keeps it premultiplied.
    const modulate = [4]f32{ alpha, alpha, alpha, alpha };
    drawQuad(r, target, tex_data.tex, uv_offset, uv_scale, dst, modulate);
}

fn drawRectQuad(r: *Gles2Data, target: *Gles2Target, rect: geom.Rect, color: [4]f32) void {
    // The Pass API takes a straight-alpha color (pass.zig) while the
    // pipeline blends premultiplied (wlr_render_color, pixman.zig
    // addRect): premultiply RGB by alpha here; the shader applies the
    // resulting u_modulate.
    const a = std.math.clamp(color[3], 0.0, 1.0);
    const modulate = [4]f32{ color[0] * a, color[1] * a, color[2] * a, a };
    const dst: geom.FRect = .{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .width = @floatFromInt(rect.width),
        .height = @floatFromInt(rect.height),
    };
    drawQuad(r, target, r.white_tex, .{ 0, 0 }, .{ 1, 1 }, dst, modulate);
}

/// Draw one textured quad. `dst` is in target pixels (y down); the
/// vertex shader maps it to NDC (y flipped) inside the viewport. The
/// fragment shader samples `uv_offset + v_uv * uv_scale` (crop/scale in
/// texture space) and swizzles .bgra (uploaded GL_RGBA bytes are BGRA in
/// memory), then multiplies by the premultiplied u_modulate.
fn drawQuad(
    r: *Gles2Data,
    target: *Gles2Target,
    gl_tex: c.GLuint,
    uv_offset: [2]f32,
    uv_scale: [2]f32,
    dst: geom.FRect,
    modulate: [4]f32,
) void {
    c.glBindTexture(c.GL_TEXTURE_2D, gl_tex);
    c.glUniform2f(r.loc_uv_offset, uv_offset[0], uv_offset[1]);
    c.glUniform2f(r.loc_uv_scale, uv_scale[0], uv_scale[1]);
    c.glUniform2f(r.loc_offset, @floatCast(dst.x), @floatCast(dst.y));
    c.glUniform2f(r.loc_scale, @floatCast(dst.width), @floatCast(dst.height));
    c.glUniform2f(r.loc_viewport, @floatFromInt(target.width), @floatFromInt(target.height));
    c.glUniform4f(r.loc_modulate, modulate[0], modulate[1], modulate[2], modulate[3]);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
}

/// GL_LINEAR filtering + CLAMP_TO_EDGE wrapping, applied to every
/// texture (imported textures and the target's backing color texture).
fn setTextureParams() void {
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
}

/// Upload `pixels` (stride*h bytes) into `gl_tex`, allocating storage
/// (glTexImage2D). Tight rows (stride == w*4) upload in one call; padded
/// rows fall back to row-by-row glTexSubImage2D — GL_UNPACK_ROW_LENGTH
/// is not core GLES2.
fn uploadTexturePixels(gl_tex: c.GLuint, w: i32, h: i32, stride: i32, pixels: []const u8) void {
    const tight = std.math.mul(i32, w, 4) catch return;
    if (tight == stride) {
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
    } else {
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        uploadTextureRows(gl_tex, w, h, stride, pixels);
    }
}

/// In-place upload over existing storage (glTexSubImage2D).
fn updateTexturePixels(gl_tex: c.GLuint, w: i32, h: i32, stride: i32, pixels: []const u8) void {
    const tight = std.math.mul(i32, w, 4) catch return;
    if (tight == stride) {
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, w, h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
    } else {
        uploadTextureRows(gl_tex, w, h, stride, pixels);
    }
}

fn uploadTextureRows(_: c.GLuint, w: i32, h: i32, stride: i32, pixels: []const u8) void {
    const row_bytes: usize = @intCast(std.math.mul(i32, w, 4) catch return);
    const stride_us: usize = @intCast(stride);
    var row: i32 = 0;
    while (row < h) : (row += 1) {
        const off: usize = @as(usize, @intCast(row)) * stride_us;
        c.glTexSubImage2D(
            c.GL_TEXTURE_2D,
            0,
            0,
            row,
            w,
            1,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            pixels[off..][0..row_bytes].ptr,
        );
    }
}

/// Initialize EGL: surfaceless display (EGL_MESA_platform_surfaceless,
/// falling back to eglGetDisplay's default platform), ES2 config,
/// context, and bind it with no surface (EGL 1.5 core).
fn initEgl(r: *Gles2Data) !void {
    var dpy = c.eglGetPlatformDisplay(c.EGL_PLATFORM_SURFACELESS_MESA, null, null);
    if (dpy == null) dpy = c.eglGetDisplay(null);
    if (dpy == null) {
        log_mod.err("eglGetPlatformDisplay/eglGetDisplay failed (no EGL?)", r.io, r.log_cfg, "gles2", .{});
        return error.EglInitFailed;
    }
    r.dpy = dpy;
    var major: c.EGLint = 0;
    var minor: c.EGLint = 0;
    if (c.eglInitialize(dpy, &major, &minor) != c.EGL_TRUE) {
        log_mod.err("eglInitialize failed", r.io, r.log_cfg, "gles2", .{});
        return error.EglInitFailed;
    }
    if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE) {
        log_mod.err("eglBindAPI(EGL_OPENGL_ES_API) failed", r.io, r.log_cfg, "gles2", .{});
        return error.EglInitFailed;
    }
    const config_attribs = [_]c.EGLint{
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
        c.EGL_SURFACE_TYPE,    c.EGL_PBUFFER_BIT,
        c.EGL_NONE,
    };
    var config: c.EGLConfig = null;
    var num_config: c.EGLint = 0;
    if (c.eglChooseConfig(dpy, &config_attribs, &config, 1, &num_config) != c.EGL_TRUE or
        config == null or
        num_config < 1)
    {
        log_mod.err("eglChooseConfig failed (no ES2 config?)", r.io, r.log_cfg, "gles2", .{});
        return error.EglInitFailed;
    }
    const ctx_attribs = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 2, c.EGL_NONE };
    const ctx = c.eglCreateContext(dpy, config, null, &ctx_attribs);
    if (ctx == null) {
        log_mod.err("eglCreateContext failed", r.io, r.log_cfg, "gles2", .{});
        return error.EglInitFailed;
    }
    r.ctx = ctx;
    // EGL 1.5: surfaceless rendering — no EGL surface needed.
    if (c.eglMakeCurrent(dpy, null, null, ctx) != c.EGL_TRUE) {
        log_mod.err("eglMakeCurrent (surfaceless) failed", r.io, r.log_cfg, "gles2", .{});
        return error.EglInitFailed;
    }
}

/// Compile shaders, link the program, build the unit-quad VBO and the
/// 1x1 white texture. The EGL context must be current.
fn initGl(r: *Gles2Data) !void {
    if (c.glGetString(c.GL_VERSION)) |ver| {
        const v: [*:0]const u8 = @ptrCast(ver);
        log_mod.info("gles2: GL_VERSION {s}", r.io, r.log_cfg, "gles2", .{std.mem.span(v)});
    }
    const vs = try compileShader(r, c.GL_VERTEX_SHADER, vs_src);
    defer c.glDeleteShader(vs);
    const fs = try compileShader(r, c.GL_FRAGMENT_SHADER, fs_src);
    defer c.glDeleteShader(fs);
    const program = try linkProgram(r, vs, fs);
    r.program = program;

    r.loc_pos = c.glGetAttribLocation(program, "a_pos");
    r.loc_uv = c.glGetAttribLocation(program, "a_uv");
    r.loc_tex = c.glGetUniformLocation(program, "u_tex");
    r.loc_offset = c.glGetUniformLocation(program, "u_offset");
    r.loc_scale = c.glGetUniformLocation(program, "u_scale");
    r.loc_viewport = c.glGetUniformLocation(program, "u_viewport");
    r.loc_uv_offset = c.glGetUniformLocation(program, "u_uv_offset");
    r.loc_uv_scale = c.glGetUniformLocation(program, "u_uv_scale");
    r.loc_modulate = c.glGetUniformLocation(program, "u_modulate");
    if (r.loc_pos < 0 or r.loc_uv < 0 or r.loc_tex < 0 or r.loc_offset < 0 or
        r.loc_scale < 0 or r.loc_viewport < 0 or r.loc_uv_offset < 0 or
        r.loc_uv_scale < 0 or r.loc_modulate < 0)
    {
        log_mod.err("shader link: attribute/uniform locations not found", r.io, r.log_cfg, "gles2", .{});
        return error.ShaderLinkFailed;
    }

    // Unit quad: two triangles, position + uv interleaved (stride 16,
    // uv at offset 8). One VBO serves every draw.
    c.glGenBuffers(1, &r.vbo);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, r.vbo);
    const quad = [_]f32{
        0, 0, 0, 0,
        1, 0, 1, 0,
        1, 1, 1, 1,
        0, 0, 0, 0,
        1, 1, 1, 1,
        0, 1, 0, 1,
    };
    const quad_bytes: c.GLsizeiptr = @intCast(quad.len * @sizeOf(f32));
    c.glBufferData(c.GL_ARRAY_BUFFER, quad_bytes, &quad, c.GL_STATIC_DRAW);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);

    // 1x1 white texture: solid-color rects sample it with u_modulate.
    c.glGenTextures(1, &r.white_tex);
    c.glBindTexture(c.GL_TEXTURE_2D, r.white_tex);
    const white_px = [_]u8{ 255, 255, 255, 255 };
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 1, 1, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &white_px);
    setTextureParams();
    c.glBindTexture(c.GL_TEXTURE_2D, 0);

    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    if (c.glGetError() != c.GL_NO_ERROR) {
        log_mod.warn("gles2: GL errors during renderer init", r.io, r.log_cfg, "gles2", .{});
    }
}

fn compileShader(r: *Gles2Data, kind: c.GLenum, src: [*:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(kind);
    if (shader == 0) return error.ShaderCompileFailed;
    errdefer c.glDeleteShader(shader);
    const src_ptrs = [_][*:0]const u8{src};
    glShaderSource(shader, 1, &src_ptrs, null);
    c.glCompileShader(shader);
    var status: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var len: c.GLsizei = 0;
        var info: [512]u8 = undefined;
        c.glGetShaderInfoLog(shader, info.len, &len, info[0..].ptr);
        const n: usize = @intCast(len);
        log_mod.err("shader compile failed: {s}", r.io, r.log_cfg, "gles2", .{info[0..n]});
        return error.ShaderCompileFailed;
    }
    return shader;
}

fn linkProgram(r: *Gles2Data, vs: c.GLuint, fs: c.GLuint) !c.GLuint {
    const program = c.glCreateProgram();
    if (program == 0) return error.ShaderLinkFailed;
    errdefer c.glDeleteProgram(program);
    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    c.glLinkProgram(program);
    var status: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &status);
    if (status == 0) {
        var len: c.GLsizei = 0;
        var info: [512]u8 = undefined;
        c.glGetProgramInfoLog(program, info.len, &len, info[0..].ptr);
        const n: usize = @intCast(len);
        log_mod.err("program link failed: {s}", r.io, r.log_cfg, "gles2", .{info[0..n]});
        return error.ShaderLinkFailed;
    }
    return program;
}

/// Delete GL objects created by initGl. Requires a current context (the
/// caller runs it before EGL teardown); 0-guards make partial init safe.
fn deinitGl(r: *Gles2Data) void {
    if (r.program != 0) c.glDeleteProgram(r.program);
    if (r.vbo != 0) c.glDeleteBuffers(1, &r.vbo);
    if (r.white_tex != 0) c.glDeleteTextures(1, &r.white_tex);
}

fn teardownEgl(r: *Gles2Data) void {
    if (r.dpy) |dpy| {
        _ = c.eglMakeCurrent(dpy, null, null, null);
        _ = c.eglTerminate(dpy);
        r.dpy = null;
    }
    _ = c.eglReleaseThread();
}

const vs_src =
    \\attribute vec2 a_pos;
    \\attribute vec2 a_uv;
    \\uniform vec2 u_offset;
    \\uniform vec2 u_scale;
    \\uniform vec2 u_viewport;
    \\varying vec2 v_uv;
    \\void main() {
    \\    v_uv = a_uv;
    \\    vec2 px = u_offset + a_pos * u_scale;
    \\    vec2 ndc = vec2(px.x * 2.0 / u_viewport.x - 1.0,
    \\                    1.0 - px.y * 2.0 / u_viewport.y);
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

const fs_src =
    \\precision mediump float;
    \\uniform sampler2D u_tex;
    \\uniform vec2 u_uv_offset;
    \\uniform vec2 u_uv_scale;
    \\uniform vec4 u_modulate;
    \\varying vec2 v_uv;
    \\void main() {
    \\    vec2 uv = u_uv_offset + v_uv * u_uv_scale;
    \\    // Uploaded GL_RGBA bytes are BGRA in memory (premultiplied
    \\    // ARGB8888); .bgra restores RGBA channel order.
    \\    vec4 texel = texture2D(u_tex, uv).bgra;
    \\    gl_FragColor = texel * u_modulate;
    \\}
;

fn px(buf: []const u8, w: i32, x: i32, y: i32) [4]u8 {
    const off = (@as(usize, @intCast(y)) * @as(usize, @intCast(w)) + @as(usize, @intCast(x))) * 4;
    return buf[off..][0..4].*;
}

fn setPx(buf: []u8, w: i32, x: i32, y: i32, color: [4]u8) void {
    const off = (@as(usize, @intCast(y)) * @as(usize, @intCast(w)) + @as(usize, @intCast(x))) * 4;
    buf[off..][0..4].* = color;
}

// ---------------------------------------------------------------------------
// Test-only: EGL/GLES2 is single-threaded per process. The default display's
// current context is process-global — create() eglMakeCurrents it and any
// other thread's create()/destroy() steals it, so concurrent GL calls abort
// (the M5 "readPixels ABRT" failures). `zig test` runs test blocks on a
// thread pool, so serialize the GL-using test bodies with a process-global
// lock. (std.Thread.Mutex was removed in 0.16; a spin lock over
// std.atomic.Value is the std-only equivalent.)
var gles2_test_lock: std.atomic.Value(bool) = .init(false);

fn lockGles2Test() void {
    while (gles2_test_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        // Yielding is advisory; if the system cannot yield, keep spinning
        // on the CAS — the lock is held only briefly by test GL ops.
        std.Thread.yield() catch continue;
    }
}

fn unlockGles2Test() void {
    gles2_test_lock.store(false, .release);
}

test "gles2 renderer lifecycle" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    try std.testing.expectEqual(@as(usize, 1), renderer.formats.len);
    try std.testing.expectEqual(format_argb8888, renderer.formats[0]);
}

test "gles2 empty pass clears the target" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const target = try Gles2Target.create(allocator, 2, 2);
    defer target.destroy();

    // A submit with no ops still clears: GL texture storage holds
    // undefined bytes between passes, so the pass owns the target
    // contents (mirrors pixman's zero-initialized Framebuffer).
    const pass = renderer.beginPass(target).?;
    pass.submit();

    const buf = try target.readPixels(allocator);
    defer allocator.free(buf);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(buf, 2, 0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(buf, 2, 1, 1));
}

test "gles2 texture import and update" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    // BGRA bytes: red.
    const red = [_]u8{ 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255 };
    const tex = try Gles2Renderer.importMemory(renderer, 2, 2, 8, &red);
    defer tex.destroy();
    try std.testing.expectEqual(@as(i32, 2), tex.width);
    try std.testing.expectEqual(@as(i32, 2), tex.height);

    // In-place update with matching geometry: glTexSubImage2D.
    const blue = [_]u8{ 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255 };
    try std.testing.expect(Gles2Renderer.updateMemory(tex, 2, 2, 8, &blue));
    // Geometry mismatch (size or stride): caller must re-import.
    try std.testing.expect(!Gles2Renderer.updateMemory(tex, 3, 2, 12, &blue));
    try std.testing.expect(!Gles2Renderer.updateMemory(tex, 2, 2, 16, &blue));

    // The update landed: blit reads back blue.
    const target = try Gles2Target.create(allocator, 2, 2);
    defer target.destroy();
    const pass = renderer.beginPass(target).?;
    pass.addTexture(tex, null, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, 1.0);
    pass.submit();
    const buf = try target.readPixels(allocator);
    defer allocator.free(buf);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(buf, 2, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(buf, 2, 1, 1));
}

test "gles2 rect fill and alpha blend" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    // Opaque red fill. Memory bytes are B,G,R,A, so red is {0,0,255,255}.
    const target = try Gles2Target.create(allocator, 4, 4);
    defer target.destroy();
    const pass = renderer.beginPass(target).?;
    pass.addRect(.{ .x = 1, .y = 1, .width = 2, .height = 2 }, .{ 1.0, 0.0, 0.0, 1.0 });
    pass.submit();

    const buf = try target.readPixels(allocator);
    defer allocator.free(buf);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(buf, 4, 0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(buf, 4, 1, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(buf, 4, 2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(buf, 4, 3, 3));

    // Premultiplied-over blend: blue at 0.4 over white. Both rects must
    // go in ONE pass — submitPass clears the target on every submit, so a
    // second pass would wipe the white fill underneath. The blend leaves
    // B=255, A=255 and G/R=0.6*255=153 (GL rounds float->unorm8).
    const target2 = try Gles2Target.create(allocator, 4, 4);
    defer target2.destroy();
    const pass_blend = renderer.beginPass(target2).?;
    pass_blend.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ 1.0, 1.0, 1.0, 1.0 });
    pass_blend.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ 0.0, 0.0, 1.0, 0.4 });
    pass_blend.submit();
    const buf2 = try target2.readPixels(allocator);
    defer allocator.free(buf2);
    try std.testing.expectEqual([4]u8{ 255, 153, 153, 255 }, px(buf2, 4, 1, 1));
}

test "gles2 1:1 texture blit" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const target = try Gles2Target.create(allocator, 4, 4);
    defer target.destroy();

    // BGRA bytes: red, green / blue, white (same pattern as the pixman
    // "1:1 blit" test).
    const pattern = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    const tex = try Gles2Renderer.importMemory(renderer, 2, 2, 8, &pattern);
    defer tex.destroy();

    const pass = renderer.beginPass(target).?;
    pass.addTexture(tex, null, .{ .x = 1, .y = 1, .width = 2, .height = 2 }, 1.0);
    pass.submit();

    const buf = try target.readPixels(allocator);
    defer allocator.free(buf);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(buf, 4, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(buf, 4, 1, 1));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px(buf, 4, 2, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(buf, 4, 1, 2));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, px(buf, 4, 2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(buf, 4, 3, 3));
}

test "gles2 texture crop" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const target = try Gles2Target.create(allocator, 2, 2);
    defer target.destroy();

    // 4x4 texture: a 2x2 colored block at (1,1), black elsewhere.
    var texture_px: [64]u8 = @splat(0);
    setPx(&texture_px, 4, 1, 1, .{ 255, 0, 0, 255 }); // red
    setPx(&texture_px, 4, 2, 1, .{ 0, 255, 0, 255 }); // green
    setPx(&texture_px, 4, 1, 2, .{ 0, 0, 255, 255 }); // blue
    setPx(&texture_px, 4, 2, 2, .{ 255, 255, 255, 255 }); // white
    const tex = try Gles2Renderer.importMemory(renderer, 4, 4, 16, &texture_px);
    defer tex.destroy();

    // Crop src (1,1,2,2) -> dst (0,0,2,2): 1:1 texel-exact copy of the
    // block (M2 crop support, the path pixman's M1 pass skips).
    const pass = renderer.beginPass(target).?;
    pass.addTexture(
        tex,
        .{ .x = 1, .y = 1, .width = 2, .height = 2 },
        .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        1.0,
    );
    pass.submit();

    const buf = try target.readPixels(allocator);
    defer allocator.free(buf);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(buf, 2, 0, 0));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px(buf, 2, 1, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(buf, 2, 0, 1));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, px(buf, 2, 1, 1));
}
