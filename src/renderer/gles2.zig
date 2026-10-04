//! GLES2/EGL renderer: GPU compositing via libEGL + libGLESv2.
//!
//! Reference implementation of the Pass contract — scaling, cropping, a
//! per-draw buffer transform and per-op alpha — composited into an
//! FBO-backed target with a single shader program (unit quad +
//! u_modulate), premultiplied-alpha over blending matching wlr_render_color
//! (include/wlr/render/pass.h:135-137) and pixman.zig's blendSample.
//!
//! # EGL
//! Two ways in:
//! - `create` is the surfaceless one (EGL_MESA_platform_surfaceless,
//!   eglGetPlatformDisplay's default fallback): the headless / nested /
//!   test path, with no DRM device behind it. Its renderFormats() is EMPTY,
//!   because GPU scanout needs a device.
//! - `createOnDevice` binds the SAME GBM device the backend allocated its
//!   swapchain from (EGL_PLATFORM_DEVICE_EXT with the DRM node's fd), so
//!   EGL renders on the same GPU the KMS plane scans out of.
//!
//! `eglGetPlatformDisplay` returns the SAME EGLDisplay for two renderers
//! opened on one native device, so a display is reference counted in a
//! process-global registry (`display_registry`): every renderer
//! `eglDestroyContext`s its OWN context, and only the LAST owner runs
//! `eglTerminate` + `eglReleaseThread`. Destroying one renderer therefore
//! cannot tear down a display another renderer still renders on.
//!
//! # Context ownership
//! An EGL context is per-thread current state, not a property of a
//! renderer, and this compositor can hold several renderers at once (two
//! outputs, a test renderer beside the DRM one) and shares its thread
//! with Raylib. So NO method here relies on the context left current by
//! whoever ran last. Every GL entry point — target create/destroy/
//! readback, texture import/update/destroy, pass begin/submit, finish —
//! first calls `Gles2Data.makeCurrent`, which binds the context that
//! OWNS the object it is about to touch. Targets and textures carry that
//! owner (`Gles2Target.owner`, `Gles2TextureData.owner`) rather than
//! trusting a global "current renderer".
//!
//! # Native DMA-BUF import
//! `EGL_EXT_image_dma_buf_import` is a DISPLAY extension (query it with
//! `eglQueryString(dpy, EGL_EXTENSIONS)`, never `EGL_NO_DISPLAY`), and
//! the import is `eglCreateImage(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL,
//! attribs)` — that target token and a NULL buffer, with an EGLAttrib
//! list of EGL_WIDTH/EGL_HEIGHT/EGL_LINUX_DRM_FOURCC_EXT plus per-plane
//! FD/OFFSET/PITCH. There is no EGL_IMAGE_FORMAT_FD attribute; the
//! format travels in the FOURCC attribute. Modifier-capable buffers
//! (EGL_EXT_image_dma_buf_import_modifiers) carry per-plane
//! MODIFIER_LO/HI, and a modifier this EGL cannot import is refused, not
//! silently imported at the wrong layout.
//!
//! # Targets
//! Two kinds, both an FBO you draw into:
//! - `Gles2Target.create`: an FBO over a GL_RGBA texture. GL row 0 is its
//!   BOTTOM row, so `scanout_flip` is false and a scene y of 0 renders to
//!   the texture's top row; readPixelsInto flips it back for a CPU
//!   consumer.
//! - `Gles2Target.fromDmabuf`: an FBO over a native EGL image imported
//!   from a dmabuf (a client's buffer, or a backend scanout slot). Here
//!   row 0 IS the buffer's row 0, which for KMS scanout is its TOP row:
//!   `scanout_flip` is true and the shader flips the viewport step, so a
//!   scene y of 0 lands on the buffer's top row. That is the same texture,
//!   rendered top-down for the scanout engine.
//!
//! `readPixelsInto` gives BOTH kinds the same CPU contract: top-down rows
//! in ARGB8888 memory order (B, G, R, A). `glReadPixels(GL_RGBA, ...)`
//! hands back LOGICAL R,G,B,A bytes whatever the colour attachment is,
//! and the Framebuffer contract is B,G,R,A, so the R/B swap is applied
//! unconditionally — a native EGL image is not a second case.
//!
//! # Transform
//! Every draw passes through one 2D affine uniform, `u_transform` (a
//! column-major GLSL `mat3`, see Affine), mapping SCENE pixels — the space
//! the dst rect of add_texture/add_rect is expressed in (y down,
//! top-left origin, pixels) — to TARGET pixels. It is the identity by
//! default.
//!
//! `setTransform` is effective at the COMMAND POSITION, not merely at
//! submit: a call made while a pass is open appends a transform command
//! and the matrix is uploaded once per change, in order. That is what lets
//! one frame mix spaces — the background and the world surfaces through
//! the camera, then the screen-space cursor through the identity — in a
//! single pass. The buffer transform of an individual texture is NOT part
//! of this matrix: it is a per-draw source mapping (Pass.TextureOptions
//! .transform through pixman.TexelMap), because it changes the texel a
//! quad samples, not where the quad lands.
//!
//! # Sampling
//! A draw's source is resolved into TEXEL coordinates at add_texture
//! time (pixman.TexelMap in the texel-center convention): a
//! destination-normalized coordinate of the dst rect names the filter
//! position in the crop's own frame, where texel centres sit at half
//! integers). The fragment shader clamps that position to the crop's
//! texel-CENTRE bounds and converts to texture space as `uv = t / size`,
//! which is GL's own rule inverted: GL samples the texel sequence at
//! `uv * size - 0.5`, so a texel position needs no offset of ours.
//!
//! The clamp is what makes a crop a crop. GL_CLAMP_TO_EDGE clamps to the
//! TEXTURE edge, so a magnified crop's first and last half texel would
//! otherwise blend in a texel one step outside the crop — a wp_viewport
//! source showing pixels it never asked for. pixman.zig clamps the CPU
//! taps to the crop's texel indices for the same reason, so both
//! backends keep a crop's content inside the crop.
//!
//! # Precision
//! The affine and every scene coordinate are f64. Before anything is
//! uploaded, the renderer subtracts the scene-space point the affine maps
//! to the target's origin (computed in f64), so the numbers the shader
//! sees are viewport-sized: a surface a billion world pixels out keeps its
//! local geometry, where an absolute f32 would be 64 px granular.
//!
//! # Wiring contract
//! The orchestrator wires this module in build.zig like the pixman_c
//! pattern: translate src/renderer/gles2_c.h with addTranslateC (include
//! root from `pkg-config --cflags egl glesv2`, i.e. nixpkgs#libglvnd.dev),
//! import the module as `gles2_c`, and link `egl` + `glesv2`.
//!
//! Imports: utils/*, buffers/{buffer,dmabuf}, renderer/{renderer,pass,
//! pixman,texture}.zig, gles2_c, gbm_c.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const log_mod = @import("../utils/log.zig");
const matrix = @import("../utils/matrix.zig");
const buffer_mod = @import("../buffers/buffer.zig");
const dmabuf = @import("../buffers/dmabuf.zig");
const renderer_mod = @import("renderer.zig");
const pass_mod = @import("pass.zig");
const pixman_mod = @import("pixman.zig");
const texture_mod = @import("texture.zig");
const c = @import("gles2_c");
const gbm_c = @import("gbm_c");

/// wl_shm format code for ARGB8888 (little-endian bytes: B, G, R, A).
pub const format_argb8888: u32 = 0;

/// One live EGLDisplay and how many renderers hold it.
const DisplayEntry = struct {
    dpy: c.EGLDisplay,
    /// Renderers holding this display. Reaching zero terminates it.
    refs: u32 = 0,
    /// Whether this process initialized the display. `eglTerminate` is
    /// only legal on a display `eglInitialize` succeeded for.
    initialized: bool = false,
};

/// Process-global registry of live EGLDisplays.
///
/// `eglGetPlatformDisplay` REF-COUNTS by (platform, native display): two
/// renderers opened on one GBM device get back the very same EGLDisplay
/// handle, and `eglTerminate` kills every context created on it. A
/// renderer that terminated on destroy would therefore pull the GPU out
/// from under a sibling renderer still drawing — and `eglReleaseThread`
/// would drop the thread's EGL state out from under both.
///
/// So teardown is split: EVERY renderer `eglDestroyContext`s its own
/// context, but the display is `eglTerminate`d — and the thread released
/// — only when the LAST reference drops. Entries are touched only by
/// create()/destroy(); the spin lock is the same discipline as the test
/// lock below, because `zig test` runs test bodies on a thread pool.
const DisplayRegistry = struct {
    const capacity = 8;
    lock: std.atomic.Value(bool) = .init(false),
    entries: [capacity]DisplayEntry = @splat(.{ .dpy = null }),

    fn lockRegistry(self: *DisplayRegistry) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            // Yielding is advisory; if the system cannot yield, keep
            // spinning on the CAS — the lock is held only briefly.
            std.Thread.yield() catch continue;
        }
    }

    fn unlockRegistry(self: *DisplayRegistry) void {
        self.lock.store(false, .release);
    }

    /// Take a reference to `dpy`. The result says whether this call is
    /// the one that must `eglInitialize` it; null means every slot is
    /// taken (the caller reports an honest failure rather than running
    /// untracked).
    fn acquire(self: *DisplayRegistry, dpy: c.EGLDisplay) ?bool {
        self.lockRegistry();
        defer self.unlockRegistry();
        for (&self.entries) |*entry| {
            if (entry.refs != 0 and entry.dpy == dpy) {
                entry.refs += 1;
                return false;
            }
        }
        for (&self.entries) |*entry| {
            if (entry.refs == 0) {
                entry.* = .{ .dpy = dpy, .refs = 1 };
                return true;
            }
        }
        return null;
    }

    /// Record that `dpy` initialized successfully.
    fn markInitialized(self: *DisplayRegistry, dpy: c.EGLDisplay) void {
        self.lockRegistry();
        defer self.unlockRegistry();
        for (&self.entries) |*entry| {
            if (entry.refs != 0 and entry.dpy == dpy) {
                entry.initialized = true;
                return;
            }
        }
    }

    /// Drop one reference to `dpy`, reporting whether this was the last
    /// owner (the only case where the caller may terminate) and whether
    /// the display was ever initialized.
    fn release(self: *DisplayRegistry, dpy: c.EGLDisplay) struct { last: bool, initialized: bool } {
        self.lockRegistry();
        defer self.unlockRegistry();
        for (&self.entries) |*entry| {
            if (entry.refs == 0 or entry.dpy != dpy) continue;
            entry.refs -= 1;
            const last = entry.refs == 0;
            const initialized = entry.initialized;
            if (last) entry.* = .{ .dpy = null };
            return .{ .last = last, .initialized = initialized };
        }
        return .{ .last = true, .initialized = false };
    }
};

/// The one registry instance: EGLDisplay handles are process-wide, so
/// their ownership has to be too.
var display_registry: DisplayRegistry = .{};

/// Render target: an FBO with a GL texture as its color attachment —
/// either a texture this renderer allocated or one imported from a
/// dmabuf. See the module's "# Targets".
///
/// A target must be destroyed BEFORE its owner renderer: destroy() binds
/// the owning context, which only the renderer keeps alive.
pub const Gles2Target = struct {
    /// FBO handle; drawing targets this.
    fbo: c.GLuint,
    /// Backing color texture (the FBO's GL_COLOR_ATTACHMENT0).
    tex: c.GLuint,
    /// The EGL image backing `tex`, when it came from one (dmabuf).
    /// Destroyed with the target; null for a renderer-owned texture.
    image: ?c.EGLImage,
    /// The EGL display that created `image` (a dmabuf target's), so
    /// destroy() releases it through the right display.
    display: ?c.EGLDisplay,
    width: i32,
    height: i32,
    /// The target's row 0 is the TOP row (a KMS scanout buffer), so the
    /// shader flips the viewport step. False for a GL_RGBA texture, whose
    /// row 0 is GL's bottom row. Never inferred, never hidden: a caller
    /// that hands over a scanout buffer says so here.
    scanout_flip: bool,
    allocator: std.mem.Allocator,
    /// The renderer that created this target. Its EGL context is bound
    /// before every GL call on the target, so a target created by
    /// renderer A is never drawn into or destroyed while renderer B's (or
    /// Raylib's) context happens to be current. Explicit owner, never a
    /// global "current renderer".
    owner: *Gles2Data,

    /// Create an FBO over a freshly allocated GL_RGBA texture of the
    /// OWNING renderer's size.
    ///
    /// `renderer` is required: it names the GL context that owns the
    /// texture and FBO created here, and the context every later call on
    /// this target must bind. A target created without one would depend
    /// on whichever context the caller happened to leave current.
    pub fn create(
        allocator: std.mem.Allocator,
        renderer: *renderer_mod.Renderer,
        w: i32,
        h: i32,
    ) !*Gles2Target {
        const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
        if (w <= 0 or h <= 0) return error.InvalidSize;
        // The texture and FBO below are GL objects: they belong to this
        // renderer's context, which must be current to create them.
        if (!data.makeCurrent()) return error.NoCurrentContext;
        const self = try allocator.create(Gles2Target);
        errdefer allocator.destroy(self);
        self.* = .{
            .fbo = undefined,
            .tex = undefined,
            .image = null,
            .display = null,
            .width = w,
            .height = h,
            .scanout_flip = false,
            .allocator = allocator,
            .owner = data,
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

    /// Import a dmabuf as a renderable target: a native EGL image
    /// (EGL_EXT_image_dma_buf_import + GL_OES_EGL_image) bound as the
    /// FBO's color attachment. Nothing is mapped or copied — the GPU
    /// renders straight into the buffer.
    ///
    /// `scanout_flip` is true: the image's row 0 is the buffer's row 0,
    /// which is what a KMS plane reads as the TOP row.
    ///
    /// The FBO is validated even though the setup probe already passed:
    /// this is a different buffer, possibly a different stride or
    /// modifier, and a driver that cannot render into it must say so here
    /// rather than draw nothing.
    pub fn fromDmabuf(
        allocator: std.mem.Allocator,
        renderer: *renderer_mod.Renderer,
        attrs: *const dmabuf.Attributes,
    ) !*Gles2Target {
        const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
        if (attrs.width <= 0 or attrs.height <= 0) return error.InvalidSize;
        // The EGL image, the texture that names it and the FBO are all
        // objects of this renderer's context, so it must be current
        // before any of them is created.
        if (!data.makeCurrent()) return error.NoCurrentContext;
        const self = try allocator.create(Gles2Target);
        errdefer allocator.destroy(self);
        self.* = .{
            .display = data.dpy,
            .fbo = undefined,
            .tex = undefined,
            .image = undefined,
            .width = attrs.width,
            .height = attrs.height,
            .scanout_flip = true,
            .allocator = allocator,
            .owner = data,
        };
        const img = try eglImageFromAttributes(data, attrs);
        errdefer _ = c.eglDestroyImage(data.dpy, img);
        c.glGenTextures(1, &self.tex);
        errdefer c.glDeleteTextures(1, &self.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        // The parameters must be set BEFORE the target call: the driver
        // may reset them when the image is bound.
        setTextureParams();
        data.image_target_texture.?(c.GL_TEXTURE_2D, img);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glGenFramebuffers(1, &self.fbo);
        errdefer c.glDeleteFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        self.image = img;
        if (status != c.GL_FRAMEBUFFER_COMPLETE) return error.FramebufferFailed;
        return self;
    }

    pub fn destroy(self: *Gles2Target) void {
        const allocator = self.allocator;
        // The FBO and texture are objects of the OWNING context; bind it
        // so this delete cannot land on another renderer's objects.
        if (self.owner.makeCurrent()) {
            c.glDeleteFramebuffers(1, &self.fbo);
            c.glDeleteTextures(1, &self.tex);
            // The EGL image must go with the texture that named it, and
            // the texture must go before the image that backs it.
            if (self.image) |img| {
                if (self.display) |dpy| _ = c.eglDestroyImage(dpy, img);
            }
        }
        allocator.destroy(self);
    }

    /// Read the target into caller-owned CPU storage as top-down
    /// premultiplied ARGB8888 bytes (B, G, R, A in memory) — the layout
    /// pixman.Framebuffer and every scanout consumer already use.
    ///
    /// Both target kinds produce the SAME contract. `glReadPixels` with
    /// GL_RGBA returns LOGICAL R,G,B,A bytes whatever the colour
    /// attachment is (a GL_RGBA texture OR a native EGL image imported
    /// from a dmabuf), while the Framebuffer contract is B,G,R,A in
    /// memory — so the R/B swap is applied unconditionally. Treating the
    /// native case as "already in the DRM format's order" was wrong: the
    /// DRM fourcc describes how the IMAGE is stored, not the byte order
    /// glReadPixels reports.
    ///
    /// Allocation-free: no temporary buffer, no whole-target readback plus
    /// a flip copy. One glReadPixels per row, straight into the row the
    /// caller owns, with the R/B swap applied in place. `scanout_flip` is
    /// honoured, so a caller gets top-down rows from either kind of
    /// target. Size mismatches are an error, never a partial fill.
    pub fn readPixelsInto(self: *Gles2Target, fb: *pixman_mod.Framebuffer) !void {
        if (fb.width != self.width or fb.height != self.height) return error.SizeMismatch;
        const w: usize = @intCast(self.width);
        const row_bytes: usize = w * 4;
        const fb_stride: usize = @intCast(fb.stride);
        if (fb_stride < row_bytes) return error.SizeMismatch;
        // The FBO belongs to the OWNING context; bind it so this read
        // cannot return another renderer's target contents.
        if (!self.owner.makeCurrent()) return error.NoCurrentContext;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        defer c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
        var y: i32 = 0;
        while (y < self.height) : (y += 1) {
            // GL row 0 is the bottom of the framebuffer; for a scanout
            // target it is the buffer's top row instead.
            const gl_row = if (self.scanout_flip) y else self.height - 1 - y;
            const dst = fb.data[@as(usize, @intCast(y)) * fb_stride ..][0..row_bytes];
            c.glReadPixels(0, gl_row, self.width, 1, c.GL_RGBA, c.GL_UNSIGNED_BYTE, dst.ptr);
            var i: usize = 0;
            while (i < row_bytes) : (i += 4) {
                const t = dst[i];
                dst[i] = dst[i + 2];
                dst[i + 2] = t;
            }
        }
    }
};

/// Texture payload. PUBLISHED so other modules cast `Texture.data` to
/// this exact type — never to a locally re-declared mirror.
pub const Gles2TextureData = struct {
    /// GL_TEXTURE_2D handle holding the premultiplied ARGB8888 pixels.
    tex: c.GLuint,
    /// Where the pixels came from, which decides the channel swizzle and
    /// the lifetime rules:
    /// - `memory`: a CPU upload (wl_shm, a framebuffer copy), stored as
    ///   GL_RGBA bytes of ARGB8888 memory order, i.e. BGRA in the file —
    ///   the shader swaps R/B (`bgra`).
    /// - `dmabuf`: a native EGL image (a client's wl_buffer), sampled in
    ///   the DRM format's own RGBA order — NO shader swap. (This is the
    ///   SAMPLE path only: readPixelsInto still swaps, because
    ///   glReadPixels reports logical RGBA bytes either way.)
    kind: enum { memory, dmabuf },
    /// The source Buffer a dmabuf texture holds locked, released by
    /// destroyTexture. null for a memory upload.
    source: ?*buffer_mod.Buffer,
    /// The EGL image backing `tex`, for a dmabuf texture.
    image: ?c.EGLImage,
    /// The EGL display that created `image` (a dmabuf texture's). The
    /// EGLImage is destroyed through it; storing it here beats a global,
    /// because the display belongs to the renderer that imported the
    /// buffer.
    display: ?c.EGLDisplay,
    /// Upload stride, bytes per row (kept to mirror pixman's
    /// updateMemory contract: a stride change forces a re-import).
    stride: i32,
    allocator: std.mem.Allocator,
    /// The renderer that imported this texture. Its EGL context is bound
    /// before updateMemory and destroyTexture touch the GL texture, so
    /// those can never act on another renderer's objects.
    owner: *Gles2Data,
};

/// A 2D affine transform uploaded as the `u_transform` GLSL `mat3`
/// uniform. `m` is COLUMN-major — the order glUniformMatrix3fv reads
/// with transpose = GL_FALSE — so a point maps as
/// p' = (m[0]·x + m[3]·y + m[6], m[1]·x + m[4]·y + m[7]): columns
/// m[0..3] and m[3..6] are the images of the x and y basis vectors,
/// m[6..9] the translation. The bottom row is fixed at (0, 0, 1).
///
/// Coordinate spaces. FROM: scene pixels — the space the `dst` rect of
/// add_texture/add_rect is expressed in (y down, top-left origin,
/// fractional pixels, the same convention as geom.FRect). TO: target
/// pixels — the Gles2Target framebuffer, which for an output transform
/// is the ROTATED size (geom.Transform.transformedSize). Composition
/// order: the shader places the quad in scene space (u_offset plus the
/// unit quad scaled by u_scale), then applies this matrix, then maps
/// target pixels to NDC with u_viewport.
///
/// f64, not f32: the map may carry absolute world coordinates far past
/// an f32's resolution (a surface at 1e9, where f32 steps by 64). The
/// renderer subtracts an f64 scene origin before uploading.
pub const Affine = struct {
    m: [9]f64,

    /// The identity: every existing call site keeps today's pixels.
    pub const identity: Affine = .{ .m = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };

    /// The affine of a wl_output_transform for a `width` x `height`
    /// scene, i.e. buffer -> surface, exactly wlr_box_transform
    /// (wlroots util/box.c:105-155, ported verbatim as
    /// matrix.boxTransform in src/utils/matrix.zig).
    ///
    /// The shader works in continuous pixel-origin coordinates (the
    /// way wlr_fbox and the dst rects do), not pixel indices, so the
    /// derivation samples a ZERO-EXTENT box: on a degenerate box
    /// boxTransform returns the continuous point image, while on a 1x1
    /// box it would return the destination of that pixel's origin
    /// corner and shift the whole map by one pixel.
    pub fn fromTransform(t: geom.Transform, width: i32, height: i32) Affine {
        const o = pointAt(t, 0, 0, width, height);
        const ex = pointAt(t, 1, 0, width, height);
        const ey = pointAt(t, 0, 1, width, height);
        // Linear part: the image of each basis vector, minus the origin.
        const m00: f64 = @floatFromInt(ex.x - o.x); // d x'/d x
        const m10: f64 = @floatFromInt(ex.y - o.y); // d y'/d x
        const m01: f64 = @floatFromInt(ey.x - o.x); // d x'/d y
        const m11: f64 = @floatFromInt(ey.y - o.y); // d y'/d y
        return .{ .m = .{ m00, m10, 0, m01, m11, 0, @floatFromInt(o.x), @floatFromInt(o.y), 1 } };
    }

    /// Composition, `compose(outer, inner)` being the matrix product
    /// outer·inner: a point goes through `inner` first, then `outer`.
    /// The camera's world -> screen map (scene/camera.zig:
    /// T(W/2,H/2)·S(zoom)·R(−rotation)·T(−center)) builds by folding
    /// left to right, outermost factor last.
    pub fn compose(outer: Affine, inner: Affine) Affine {
        // SAFETY: both loops below write every index (col, row) of the
        // 3x3 before compose returns it.
        var out: [9]f64 = undefined;
        for (0..3) |col| {
            for (0..3) |row| {
                out[col * 3 + row] = outer.m[row] * inner.m[col * 3] +
                    outer.m[3 + row] * inner.m[col * 3 + 1] +
                    outer.m[6 + row] * inner.m[col * 3 + 2];
            }
        }
        return .{ .m = out };
    }

    /// Pure translation by (dx, dy) scene px.
    pub fn translate(dx: f64, dy: f64) Affine {
        return .{ .m = .{ 1, 0, 0, 0, 1, 0, dx, dy, 1 } };
    }

    /// Pure scale by (sx, sy), scaling about the scene origin.
    pub fn scale(sx: f64, sy: f64) Affine {
        return .{ .m = .{ sx, 0, 0, 0, sy, 0, 0, 0, 1 } };
    }

    /// Continuous point image of a scene point under `t`.
    fn pointAt(t: geom.Transform, x: i32, y: i32, width: i32, height: i32) geom.Point {
        const p = matrix.boxTransform(.{ .x = x, .y = y, .width = 0, .height = 0 }, t, width, height);
        return .{ .x = p.x, .y = p.y };
    }
};

/// A deferred draw operation (add_* record, submit draws). A `transform`
/// command changes the scene -> target affine for everything after it,
/// so the pass can mix coordinate spaces without a second submit.
const Cmd = union(enum) {
    texture: struct {
        tex: *texture_mod.Texture,
        /// Source mapping in TEXEL coordinates: a destination-normalized
        /// `a_uv` names the filter position `texel_offset +
        /// texel_affine * a_uv`, precomputed from the raw crop and the
        /// buffer transform (pixman.TexelMap). A mat2, not
        /// two scales: a 90-degree transform swaps the axes, so the
        /// destination's x step moves the texel y, which no componentwise
        /// scale can express.
        ///
        /// Texel space, not normalized texture space: the crop clamp below
        /// is stated in texels, so the shader clamps and converts to
        /// texture space in one place instead of the CPU dividing every
        /// step of the map here.
        texel_offset: [2]f32,
        /// Column-major mat2: (d texel.x/d a_uv.x, d texel.y/d a_uv.x,
        /// d texel.x/d a_uv.y, d texel.y/d a_uv.y).
        texel_affine: [4]f32,
        /// The crop's texel-CENTRE bounds (x0 + 0.5, y0 + 0.5, x1 - 0.5,
        /// y1 - 0.5): the filter position is clamped to them, so a
        /// magnified crop's outer half texel repeats the crop's own edge
        /// texel instead of bleeding in a neighbour outside the crop.
        texel_clamp: [4]f32,
        /// 1 / texture size: the shader's texel -> normalized step.
        texel_inv: [2]f32,
        dst: geom.FRect,
        alpha: f32,
        /// Swap R/B: true for a CPU upload (BGRA memory bytes), false
        /// for a native EGL image (already RGBA).
        bgra: bool,
    },
    rect: struct {
        rect: geom.FRect,
        color: [4]f32,
    },
    transform: Affine,
};

const Gles2PassData = struct {
    /// Back-pointer to the renderer data (uniform locations, program).
    owner: *Gles2Data,
    target: ?*Gles2Target = null,
    /// Captured at begin_pass; later transform commands cannot rewrite
    /// the coordinate frame of operations already queued.
    begin_transform: Affine = .identity,
    cmds: std.ArrayListUnmanaged(Cmd) = .empty,
    /// True between begin_pass and submit: setTransform appends a command
    /// instead of only changing the baseline while a pass is open.
    active: bool = false,
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
    loc_transform: c.GLint,
    loc_offset: c.GLint,
    loc_scale: c.GLint,
    loc_viewport: c.GLint,
    loc_texel_offset: c.GLint,
    loc_texel_affine: c.GLint,
    loc_texel_clamp: c.GLint,
    loc_texel_inv: c.GLint,
    loc_modulate: c.GLint,
    loc_flip: c.GLint,
    loc_bgra: c.GLint,
    pass: pass_mod.Pass,
    pass_data: Gles2PassData,
    /// Scene -> target affine every pass starts from. Identity until
    /// setTransform changes it (module docs: "# Transform").
    transform: Affine,
    /// The GBM device a createOnDevice renderer renders on; null for the
    /// surfaceless one. Borrowed, not owned: the backend owns it.
    gbm: ?*dmabuf.GbmDevice,
    /// EGL and GL can import and RENDER TO a dmabuf of this class.
    can_import_dmabuf: bool,
    /// Extension entry points are resolved once; GLVND does not export
    /// this GLES extension as a directly linkable symbol.
    image_target_texture: c.PFNGLEGLIMAGETARGETTEXTURE2DOESPROC = null,
    /// This display advertises EGL_EXT_image_dma_buf_import_modifiers, so
    /// the import attribute list may carry per-plane MODIFIER_LO/HI and a
    /// non-LINEAR buffer can be imported at its real layout. Probed as a
    /// DISPLAY extension like its base extension.
    has_modifier_import: bool,
    /// Owned; freed by destroyRenderer.
    render_formats: []dmabuf.Format,

    /// Bind THIS renderer's EGL context to the calling thread, so every
    /// GL call issued against its objects runs in the context that owns
    /// them.
    ///
    /// This compositor holds more than one renderer at a time (two
    /// outputs, a surfaceless test renderer beside the DRM one) and
    /// shares its thread with Raylib, so "the context left current by
    /// whoever ran last" is not a contract anything may rely on. Callers
    /// name their owner explicitly (`Gles2Target.owner`,
    /// `Gles2TextureData.owner`) and this binds it.
    ///
    /// `eglGetCurrentContext` first: when the context is already ours
    /// (the steady state within one frame) this is a cheap read and no
    /// eglMakeCurrent round trip, which also avoids EGL flushing on a
    /// no-op switch. Surfaced as a bool so a caller can report a real
    /// failure instead of issuing GL into a foreign context.
    fn makeCurrent(self: *Gles2Data) bool {
        if (c.eglGetCurrentContext() == self.ctx) return true;
        if (c.eglMakeCurrent(self.dpy, null, null, self.ctx) != c.EGL_TRUE) {
            log_mod.err(
                "eglMakeCurrent failed for this renderer's context; GL work is skipped",
                self.io,
                self.log_cfg,
                "gles2",
                .{},
            );
            return false;
        }
        return true;
    }
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
    ///
    /// No DRM device behind it: renderFormats() is empty and
    /// importDmabuf fails, because there is nothing to import into or
    /// scan out of. This is the headless / nested / test path.
    pub fn create(allocator: std.mem.Allocator, io: *std.Io, log_cfg: *const log_mod.Config) !*renderer_mod.Renderer {
        return createImpl(allocator, io, log_cfg, null);
    }

    /// Create the renderer on the GBM device the DRM backend allocated
    /// its swapchain from: EGL_PLATFORM_DEVICE_EXT bound to that DRM
    /// node, so imports and KMS scanout are the same GPU. `gbm` is
    /// borrowed (the backend owns it and must outlive the renderer).
    pub fn createOnDevice(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        gbm: *dmabuf.GbmDevice,
    ) !*renderer_mod.Renderer {
        return createImpl(allocator, io, log_cfg, gbm);
    }

    /// The (format, modifier) pairs this renderer can actually RENDER
    /// INTO as an EGL image, owned by the renderer and valid until
    /// destroy(). The backend intersects it with a plane's IN_FORMATS.
    ///
    /// Every pair here was probed at create() time by allocating a real
    /// GBM buffer, importing it as an EGL image and checking the FBO for
    /// completeness, so an importable-but-not-renderable ("external only")
    /// pair is excluded rather than advertised. Empty when the renderer
    /// has no DRM device, or when the EGL/GL pair cannot import DMA-BUF at
    /// all: that is the honest "no GPU path" answer, never a fallback.
    pub fn renderFormats(renderer: *renderer_mod.Renderer) []const dmabuf.Format {
        const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
        return data.render_formats;
    }

    /// Block until this renderer's GPU commands have completed. A native
    /// scanout owner must cancel its writing lease on error, never submit
    /// an unfinished buffer. Source locks remain held through this barrier.
    /// Binds this context first; failures never wait on a foreign context.
    pub fn finishRendering(renderer: *renderer_mod.Renderer) error{ NoCurrentContext, GpuOperationFailed }!void {
        const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
        if (!data.makeCurrent()) return error.NoCurrentContext;
        c.glFinish();
        if (c.glGetError() != c.GL_NO_ERROR) return error.GpuOperationFailed;
    }

    /// Import an ARGB8888 pixel buffer as a GL texture. The pixels are
    /// copied into GPU memory immediately (glTexImage2D). Stored as
    /// delivered: premultiplied ARGB8888 bytes (B, G, R, A in memory),
    /// exactly like pixman's importMemory — no premultiplication here
    /// (wl_buffer, protocols/wayland/wayland.xml:533-536).
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
        // The texture is an object of this renderer's context, which must
        // be current before glGenTextures/glTexImage2D touch it.
        if (!data.makeCurrent()) return error.NoCurrentContext;

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

        tex_data.* = .{
            .tex = gl_tex,
            .kind = .memory,
            .source = null,
            .image = null,
            .display = data.dpy,
            .stride = stride,
            .allocator = data.allocator,
            .owner = data,
        };
        const tex = try data.allocator.create(texture_mod.Texture);
        tex.* = .{ .impl = &texture_impl, .data = tex_data, .width = w, .height = h };
        return tex;
    }

    /// Import a client's dmabuf buffer as a GL texture, WITHOUT mapping
    /// or copying it: the plane descriptors become a native EGL image and
    /// the GPU samples the client's memory in place.
    ///
    /// The source Buffer is LOCKED for the texture's whole life and
    /// unlocked when the texture is destroyed, so the client cannot get
    /// the buffer back while the GPU may still read it. Callers must have
    /// run finishRendering (or otherwise know the GPU is done) before
    /// dropping the texture on a frame boundary.
    pub fn importDmabuf(renderer: *renderer_mod.Renderer, buf: *buffer_mod.Buffer) !*texture_mod.Texture {
        const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
        const get_dmabuf = buf.impl.get_dmabuf orelse return error.NotADmabuf;
        const attrs: *const dmabuf.Attributes = @ptrCast(@alignCast(get_dmabuf(buf) orelse return error.NotADmabuf));
        if (attrs.width <= 0 or attrs.height <= 0) return error.InvalidSize;
        // The EGL image and the texture that names it are objects of
        // this renderer's context.
        if (!data.makeCurrent()) return error.NoCurrentContext;

        try buf.lock();
        errdefer buf.unlock();

        const img = try eglImageFromAttributes(data, attrs);
        errdefer _ = c.eglDestroyImage(data.dpy, img);

        const tex_data = try data.allocator.create(Gles2TextureData);
        errdefer data.allocator.destroy(tex_data);
        var gl_tex: c.GLuint = undefined;
        c.glGenTextures(1, &gl_tex);
        if (gl_tex == 0) return error.TextureCreateFailed;
        errdefer c.glDeleteTextures(1, &gl_tex);
        c.glBindTexture(c.GL_TEXTURE_2D, gl_tex);
        // Params before the target call: the driver may reset them.
        setTextureParams();
        data.image_target_texture.?(c.GL_TEXTURE_2D, img);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        tex_data.* = .{
            .tex = gl_tex,
            .kind = .dmabuf,
            .source = buf,
            .image = img,
            .display = data.dpy,
            // The stride lives in the buffer's own descriptors; updateMemory
            // must not touch a dmabuf texture, and this value is never used.
            .stride = 0,
            .allocator = data.allocator,
            .owner = data,
        };
        const tex = try data.allocator.create(texture_mod.Texture);
        tex.* = .{ .impl = &texture_impl, .data = tex_data, .width = attrs.width, .height = attrs.height };
        return tex;
    }

    /// Overwrite an imported texture's pixels in place (glTexSubImage2D)
    /// when the geometry matches. Returns false when the texture must be
    /// re-imported (size or stride changed, or the texture is a dmabuf,
    /// which has no CPU pixels to update). No allocation, no churn.
    ///
    /// Binds the texture's OWNING context: this entry point takes only
    /// the texture, so the owner recorded at import time is what names
    /// the right context.
    pub fn updateMemory(
        texture: *texture_mod.Texture,
        w: i32,
        h: i32,
        stride: i32,
        pixels: []const u8,
    ) bool {
        const tex_data: *Gles2TextureData = @ptrCast(@alignCast(texture.data));
        if (tex_data.kind != .memory) return false;
        if (texture.width != w or texture.height != h or tex_data.stride != stride) return false;
        const size = @as(usize, @intCast(stride)) * @as(usize, @intCast(h));
        if (pixels.len < size) return false;
        if (!tex_data.owner.makeCurrent()) return false;
        c.glBindTexture(c.GL_TEXTURE_2D, tex_data.tex);
        defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
        updateTexturePixels(tex_data.tex, w, h, stride, pixels);
        return true;
    }

    /// Same-source fast path for a NATIVE (dmabuf) texture: true when
    /// `texture` already IS an import of exactly `buf`, so a re-commit
    /// of the same buffer needs no work at all.
    ///
    /// A wl_buffer's DMA-BUF descriptors are fixed at creation, so the
    /// EGL image already names the very memory the client writes into:
    /// the GPU samples the client's NEW contents with no re-import, no
    /// CPU map and no copy. False means the caller must destroy and
    /// re-import (a different buffer, or a memory texture, which has its
    /// own updateMemory contract).
    ///
    /// The texture's own Buffer lock is untouched, so the buffer stays
    /// held for as long as the texture samples it.
    pub fn updateDmabuf(texture: *texture_mod.Texture, buf: *buffer_mod.Buffer) bool {
        const tex_data: *Gles2TextureData = @ptrCast(@alignCast(texture.data));
        if (tex_data.kind != .dmabuf) return false;
        return tex_data.source == buf;
    }

    /// Set the scene -> target affine drawn by every later pass, and —
    /// while a pass is OPEN — at the position this call happens: the
    /// change takes effect for the draws queued after it, not at the next
    /// submit. Identity by default.
    ///
    /// `affine` maps FROM scene px — the space the `dst` rect of
    /// add_texture/add_rect is given in, y down, top-left origin — TO
    /// target px, the Gles2Target framebuffer. Pass Affine.identity to go
    /// back to screen space (what the cursor is drawn in).
    pub fn setTransform(renderer: *renderer_mod.Renderer, affine: Affine) void {
        const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
        data.transform = affine;
        if (!data.pass_data.active) return;
        // Copy the matrix once per change, not once per draw.
        if (data.pass_data.cmds.items.len != 0) {
            switch (data.pass_data.cmds.items[data.pass_data.cmds.items.len - 1]) {
                .transform => |last| if (std.meta.eql(last, affine)) return,
                else => {},
            }
        }
        data.pass_data.cmds.append(data.allocator, .{ .transform = affine }) catch {
            log_mod.warn("set_transform: out of memory; transform dropped", data.io, data.log_cfg, "gles2", .{});
        };
    }
};

fn createImpl(
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    gbm: ?*dmabuf.GbmDevice,
) !*renderer_mod.Renderer {
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
        .loc_transform = -1,
        .loc_offset = -1,
        .loc_scale = -1,
        .loc_viewport = -1,
        .loc_texel_offset = -1,
        .loc_texel_affine = -1,
        .loc_texel_clamp = -1,
        .loc_texel_inv = -1,
        .loc_modulate = -1,
        .loc_flip = -1,
        .loc_bgra = -1,
        .transform = .identity,
        .gbm = gbm,
        .can_import_dmabuf = false,
        .has_modifier_import = false,
        .render_formats = &.{},
        // SAFETY: pass.impl/data are filled by begin_pass before use.
        .pass = undefined,
        .pass_data = .{ .owner = data, .allocator = allocator, .io = io, .log_cfg = log_cfg },
    };
    try initEgl(data, gbm);
    errdefer {
        if (data.ctx != null) deinitGl(data);
        teardownEgl(data);
    }
    try initGl(data);
    data.can_import_dmabuf = probeDmabufImport(data);
    data.render_formats = try probeRenderFormats(data);
    // The probe result is owned from here: a Renderer.create failure
    // must not leak it.
    errdefer if (data.render_formats.len != 0) allocator.free(data.render_formats);
    return renderer_mod.Renderer.create(allocator, io, log_cfg, &renderer_impl, data, &.{format_argb8888});
}

fn beginPass(renderer: *renderer_mod.Renderer, target: *anyopaque) ?*pass_mod.Pass {
    const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
    const tgt: *Gles2Target = @ptrCast(@alignCast(target));
    // The pass renders into the target's FBO, which belongs to the
    // TARGET's renderer. Bind that context and refuse a pass whose
    // target belongs to a different renderer, rather than drawing
    // another renderer's pixels.
    if (tgt.owner != data) return null;
    if (!data.makeCurrent()) return null;
    data.pass_data.target = tgt;
    data.pass_data.begin_transform = data.transform;
    data.pass_data.cmds.clearRetainingCapacity();
    data.pass_data.active = true;
    // A new pass starts from the transform that is current now, and
    // `clear` defaults to true: a GL texture holds undefined bytes
    // between passes.
    data.pass = .{
        .impl = &pass_impl,
        .data = &data.pass_data,
        .clear = true,
    };
    return &data.pass;
}

fn destroyRenderer(allocator: std.mem.Allocator, data: *anyopaque) void {
    const r: *Gles2Data = @ptrCast(@alignCast(data));
    deinitGl(r);
    teardownEgl(r);
    r.pass_data.cmds.deinit(allocator);
    if (r.render_formats.len != 0) allocator.free(r.render_formats);
    allocator.destroy(r);
}

fn destroyTexture(texture: *texture_mod.Texture) void {
    const tex_data: *Gles2TextureData = @ptrCast(@alignCast(texture.data));
    const allocator = tex_data.allocator;
    // The GL texture belongs to the renderer that imported it; bind that
    // context so this delete can never touch another renderer's objects.
    const bound = tex_data.owner.makeCurrent();
    if (bound) {
        // A native texture samples the CLIENT's memory, and this call
        // drops the Buffer lock that keeps that memory alive. Dropping
        // the lock before the GPU has finished reading the submitted
        // draws would let the client free (and reuse) memory the GPU is
        // still sampling, so drain this renderer's queue first. A memory
        // texture owns a private GPU copy and needs no drain.
        if (tex_data.source != null) c.glFinish();
        c.glDeleteTextures(1, &tex_data.tex);
        // The EGL image must die before the texture that names it, and
        // only after the GPU is done with it.
        if (tex_data.image) |img| {
            if (tex_data.display) |dpy| _ = c.eglDestroyImage(dpy, img);
        }
    }
    if (tex_data.source) |buf| buf.unlock();
    allocator.destroy(tex_data);
    allocator.destroy(texture);
}

fn addTexture(pass: *pass_mod.Pass, texture: *texture_mod.Texture, options: pass_mod.Pass.TextureOptions) void {
    const data: *Gles2PassData = @ptrCast(@alignCast(pass.data));
    if (data.target == null) return;
    // `!(dst.width > 0)` also rejects NaN (and negative) geometry.
    if (!(options.dst.width > 0) or !(options.dst.height > 0) or !(options.alpha > 0)) return;
    if (texture.width <= 0 or texture.height <= 0) return;
    const tw: f64 = @floatFromInt(texture.width);
    const th: f64 = @floatFromInt(texture.height);

    // Clamp the raw crop into the texture (a crop reaching past the
    // texture would name texels that do not exist).
    const want = options.src orelse pixman_mod.wholeTexture(texture.width, texture.height);
    if (std.math.isNan(want.x) or std.math.isNan(want.y) or
        std.math.isNan(want.width) or std.math.isNan(want.height)) return;
    const sx0 = std.math.clamp(want.x, 0.0, tw);
    const sy0 = std.math.clamp(want.y, 0.0, th);
    const sx1 = std.math.clamp(want.x + want.width, 0.0, tw);
    const sy1 = std.math.clamp(want.y + want.height, 0.0, th);
    if (!(sx1 > sx0) or !(sy1 > sy0)) return;
    const crop: geom.FRect = .{ .x = sx0, .y = sy0, .width = sx1 - sx0, .height = sy1 - sy0 };

    // Source mapping: the crop's surface extent through the buffer
    // transform's inverse — the same affine the CPU pass samples, in
    // TEXELS so the shader can clamp the filter to the crop before
    // converting to texture space.
    const map = pixman_mod.TexelMap.init(options.transform, texture.width, texture.height, crop);
    const uv0 = map.at(0, 0);
    const uv1 = map.at(1, 0);
    const uv2 = map.at(0, 1);
    const tex_data: *Gles2TextureData = @ptrCast(@alignCast(texture.data));

    // The crop's texel-CENTRE bounds. A crop narrower than one texel has
    // no interior centre, so both ends collapse onto its own centre and
    // `clamp(lo, hi)` never sees an inverted range.
    const lo_x = sx0 + 0.5;
    const lo_y = sy0 + 0.5;

    data.cmds.append(data.allocator, .{
        .texture = .{
            .tex = texture,
            .texel_offset = .{ @floatCast(uv0.x), @floatCast(uv0.y) },
            .texel_affine = .{
                @floatCast(uv1.x - uv0.x),
                @floatCast(uv1.y - uv0.y),
                @floatCast(uv2.x - uv0.x),
                @floatCast(uv2.y - uv0.y),
            },
            .texel_clamp = .{
                @floatCast(lo_x),
                @floatCast(lo_y),
                @floatCast(@max(lo_x, sx1 - 0.5)),
                @floatCast(@max(lo_y, sy1 - 0.5)),
            },
            .texel_inv = .{ @floatCast(1.0 / tw), @floatCast(1.0 / th) },
            .dst = options.dst,
            .alpha = options.alpha,
            // A CPU upload is BGRA in memory order; a native EGL image is
            // sampled in the DRM format's own RGBA order.
            .bgra = tex_data.kind == .memory,
        },
    }) catch {
        log_mod.warn("add_texture: out of memory; dropping draw op", data.io, data.log_cfg, "gles2", .{});
    };
}

fn addRect(pass: *pass_mod.Pass, rect: geom.FRect, color: [4]f32) void {
    const data: *Gles2PassData = @ptrCast(@alignCast(pass.data));
    if (data.target == null) return;
    // `!(color[3] > 0)` skips zero, negative and NaN alpha.
    if (rect.isEmpty() or !(color[3] > 0)) return;
    data.cmds.append(data.allocator, .{ .rect = .{ .rect = rect, .color = color } }) catch {
        log_mod.warn("add_rect: out of memory; dropping draw op", data.io, data.log_cfg, "gles2", .{});
    };
}

/// Draw the queued operations into the pass target: clear (unless the
/// caller turned it off for a pass that draws over an existing frame),
/// then draw each op with the unit-quad program and premultiplied-over
/// blending. A transform command switches the scene -> target affine
/// where it was queued.
fn submitPass(pass: *pass_mod.Pass) void {
    const data: *Gles2PassData = @ptrCast(@alignCast(pass.data));
    const target = data.target orelse {
        data.cmds.clearRetainingCapacity();
        data.active = false;
        return;
    };
    const r = data.owner;
    // Draw into the target's FBO, so run in the TARGET's context. The
    // pass records it at submit rather than trusting the thread's current
    // context, which another renderer may have changed since begin_pass.
    if (!r.makeCurrent()) {
        data.cmds.clearRetainingCapacity();
        data.active = false;
        return;
    }

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, target.fbo);
    defer c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    c.glViewport(0, 0, target.width, target.height);
    if (pass.clear) {
        c.glClearColor(0.0, 0.0, 0.0, 0.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    }

    c.glUseProgram(r.program);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glUniform1i(r.loc_tex, 0);
    // Pass state, not draw state: one row per target, and the scene ->
    // target affine re-uploaded only where a command changed it.
    c.glUniform1f(r.loc_flip, if (target.scanout_flip) -1.0 else 1.0);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA); // premultiplied over
    c.glBindBuffer(c.GL_ARRAY_BUFFER, r.vbo);
    c.glEnableVertexAttribArray(@intCast(r.loc_pos));
    c.glVertexAttribPointer(@intCast(r.loc_pos), 2, c.GL_FLOAT, c.GL_FALSE, 16, null);
    c.glEnableVertexAttribArray(@intCast(r.loc_uv));
    c.glVertexAttribPointer(@intCast(r.loc_uv), 2, c.GL_FLOAT, c.GL_FALSE, 16, @ptrFromInt(8));

    // The pass starts at the transform that was current at begin_pass.
    var origin = uploadTransform(r, data.begin_transform);
    for (data.cmds.items) |cmd| switch (cmd) {
        .transform => |affine| origin = uploadTransform(r, affine),
        .texture => |t| drawTextureQuad(r, target, origin, t),
        .rect => |rc| drawRectQuad(r, target, origin, rc.rect, rc.color),
    };
    data.cmds.clearRetainingCapacity();
    data.active = false;
}

/// Upload the affine and return the scene-space ORIGIN it was rebased
/// on: the point the affine maps to the target's origin. Every later
/// scene coordinate is measured from there, so the values that reach the
/// shader are viewport-sized even when the scene is absolute world
/// coordinates at 1e9 (where an f32 steps by 64).
fn uploadTransform(r: *Gles2Data, a: Affine) geom.FPoint {
    const det = a.m[0] * a.m[4] - a.m[3] * a.m[1];
    const origin: geom.FPoint = if (det == 0 or !std.math.isFinite(det))
        .{ .x = 0, .y = 0 }
    else
        .{
            .x = (a.m[3] * a.m[7] - a.m[4] * a.m[6]) / det,
            .y = (a.m[6] * a.m[1] - a.m[0] * a.m[7]) / det,
        };
    var m: [9]f32 = undefined;
    // Linear part: rotation and scale, both small by construction.
    for (0..6) |i| m[i] = @floatCast(a.m[i]);
    // Translation: folded with the origin in f64 FIRST, so the two large
    // terms cancel before the narrowing instead of being rounded apart.
    m[6] = @floatCast(a.m[0] * origin.x + a.m[3] * origin.y + a.m[6]);
    m[7] = @floatCast(a.m[1] * origin.x + a.m[4] * origin.y + a.m[7]);
    m[8] = @floatCast(a.m[8]);
    c.glUniformMatrix3fv(r.loc_transform, 1, c.GL_FALSE, m[0..].ptr);
    return origin;
}

fn drawTextureQuad(
    r: *Gles2Data,
    target: *Gles2Target,
    origin: geom.FPoint,
    t: @FieldType(Cmd, "texture"),
) void {
    const tex_data: *Gles2TextureData = @ptrCast(@alignCast(t.tex.data));
    // The texture texel is already premultiplied; scaling all four
    // channels by the opacity keeps it premultiplied.
    const modulate = [4]f32{ t.alpha, t.alpha, t.alpha, t.alpha };
    // The scene rect, rebased on the origin the current transform uses.
    const dst: geom.FRect = .{
        .x = t.dst.x - origin.x,
        .y = t.dst.y - origin.y,
        .width = t.dst.width,
        .height = t.dst.height,
    };
    drawQuad(r, target, tex_data.tex, .{
        .offset = t.texel_offset,
        .affine = t.texel_affine,
        .clamp = t.texel_clamp,
        .inv_size = t.texel_inv,
    }, dst, modulate, t.bgra);
}

fn drawRectQuad(
    r: *Gles2Data,
    target: *Gles2Target,
    origin: geom.FPoint,
    rect: geom.FRect,
    color: [4]f32,
) void {
    // The Pass API takes a straight-alpha color (pass.zig) while the
    // pipeline blends premultiplied (wlr_render_color, pixman.zig
    // addRect): premultiply RGB by alpha here; the shader applies the
    // resulting u_modulate.
    const a = std.math.clamp(color[3], 0.0, 1.0);
    const modulate = [4]f32{ color[0] * a, color[1] * a, color[2] * a, a };
    const dst: geom.FRect = .{
        .x = rect.x - origin.x,
        .y = rect.y - origin.y,
        .width = rect.width,
        .height = rect.height,
    };
    // The 1x1 white texture sampled at its own single texel centre: the
    // identity affine over a degenerate crop whose centre bounds are that
    // one centre, so every fragment lands on the same texel.
    drawQuad(r, target, r.white_tex, .{
        .offset = .{ 0, 0 },
        .affine = .{ 0, 0, 0, 0 },
        .clamp = .{ 0.5, 0.5, 0.5, 0.5 },
        .inv_size = .{ 1, 1 },
    }, dst, modulate, false);
}

/// The source mapping one draw samples: a destination-normalized
/// coordinate becomes a TEXEL position (texel centres at half-integers),
/// clamped to the crop's texel-centre bounds and converted to texture
/// space by the fragment shader.
const SourceMap = struct {
    offset: [2]f32,
    affine: [4]f32,
    clamp: [4]f32,
    inv_size: [2]f32,
};

/// Draw one textured quad. `dst` is in SCENE pixels (y down), already
/// rebased on `origin`; the vertex shader maps it to NDC inside the
/// viewport, applying the renderer's scene -> target affine (u_transform)
/// between the two. The fragment shader samples the crop through
/// `source` (crop, scale and buffer transform, resolved at add_texture
/// time) and multiplies by the premultiplied u_modulate.
fn drawQuad(
    r: *Gles2Data,
    target: *Gles2Target,
    gl_tex: c.GLuint,
    source: SourceMap,
    dst: geom.FRect,
    modulate: [4]f32,
    bgra: bool,
) void {
    c.glBindTexture(c.GL_TEXTURE_2D, gl_tex);
    c.glUniform2f(r.loc_texel_offset, source.offset[0], source.offset[1]);
    c.glUniformMatrix2fv(r.loc_texel_affine, 1, c.GL_FALSE, source.affine[0..].ptr);
    c.glUniform4f(r.loc_texel_clamp, source.clamp[0], source.clamp[1], source.clamp[2], source.clamp[3]);
    c.glUniform2f(r.loc_texel_inv, source.inv_size[0], source.inv_size[1]);
    c.glUniform2f(r.loc_offset, @floatCast(dst.x), @floatCast(dst.y));
    c.glUniform2f(r.loc_scale, @floatCast(dst.width), @floatCast(dst.height));
    c.glUniform2f(r.loc_viewport, @floatFromInt(target.width), @floatFromInt(target.height));
    c.glUniform4f(r.loc_modulate, modulate[0], modulate[1], modulate[2], modulate[3]);
    c.glUniform1f(r.loc_bgra, if (bgra) 1.0 else 0.0);
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

const vs_src =
    \\attribute vec2 a_pos;
    \\attribute vec2 a_uv;
    \\uniform mat3 u_transform;
    \\uniform vec2 u_offset;
    \\uniform vec2 u_scale;
    \\uniform vec2 u_viewport;
    \\uniform float u_flip;
    \\varying vec2 v_uv;
    \\void main() {
    \\    v_uv = a_uv;
    \\    // Order, scene px -> target px -> NDC:
    \\    //   1. the dst rect, in scene px (u_offset + unit quad * u_scale)
    \\    //   2. u_transform, the scene -> target affine
    \\    //   3. the viewport step, target px -> NDC (the y flip)
    \\    // The three are all affine, but they do not commute: u_scale
    \\    // must land before u_transform or a rotated quad loses its dst
    \\    // aspect, the viewport step must stay last because it is the
    \\    // only y-flip, and u_transform must multiply the point from the
    \\    // LEFT — u_transform is a column-major mat3, so writing
    \\    // vec3(scene, 1.0) * u_transform would transpose it, turning
    \\    // every rotation into its inverse and reinterpreting the
    \\    // translation column as a scale: a silent shear, not a
    \\    // compile error.
    \\    vec2 scene = u_offset + a_pos * u_scale;
    \\    vec2 px = (u_transform * vec3(scene, 1.0)).xy;
    \\    vec2 ndc = vec2(px.x * 2.0 / u_viewport.x - 1.0,
    \\                    u_flip * (1.0 - px.y * 2.0 / u_viewport.y));
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

const fs_src =
    \\precision mediump float;
    \\uniform sampler2D u_tex;
    \\uniform vec2 u_texel_offset;
    \\uniform mat2 u_texel_affine;
    \\uniform vec4 u_texel_clamp;
    \\uniform vec2 u_texel_inv;
    \\uniform vec4 u_modulate;
    \\uniform float u_bgra;
    \\varying vec2 v_uv;
    \\void main() {
    \\    // Destination-normalized -> texel position, the crop's own
    \\    // frame: texel i spans [i, i+1), so its centre is at i + 0.5.
    \\    // Clamped to the crop's texel-CENTRE bounds, so the filter of a
    \\    // magnified crop never reaches a texel outside it: GL's own
    \\    // CLAMP_TO_EDGE would clamp to the TEXTURE edge, half a texel
    \\    // further out, and bleed a neighbour the crop never named into
    \\    // the draw's outer half texel.
    \\    vec2 texel = u_texel_offset + u_texel_affine * v_uv;
    \\    texel = clamp(texel, u_texel_clamp.xy, u_texel_clamp.zw);
    \\    // GL samples the texel sequence at `uv * size - 0.5`, which is
    \\    // the texel ORIGIN that position falls on — so texel position t
    \\    // is exactly `uv = t / size`, with no offset of our own.
    \\    vec2 uv = texel * u_texel_inv;
    \\    vec4 texel_rgba = texture2D(u_tex, uv);
    \\    // A CPU upload holds premultiplied ARGB8888 bytes, i.e. BGRA in
    \\    // memory order uploaded as GL_RGBA: .bgra restores RGBA. A
    \\    // native EGL image (dmabuf) is already sampled in the DRM
    \\    // format's own RGBA order and must not be swapped.
    \\    vec4 rgba = mix(texel_rgba, texel_rgba.bgra, u_bgra);
    \\    gl_FragColor = rgba * u_modulate;
    \\}
;

/// Initialize EGL. With `gbm` the display is the DRM device's own node
/// (EGL_PLATFORM_DEVICE_EXT, so imports and KMS scanout are the same
/// GPU); without it, surfaceless (EGL_MESA_platform_surfaceless with
/// eglGetDisplay's default fallback). ES2 config, context, and make
/// current with NO surface (EGL 1.5 core).
fn initEgl(r: *Gles2Data, gbm: ?*dmabuf.GbmDevice) !void {
    var dpy: c.EGLDisplay = null;
    if (gbm) |dev| {
        // EGL_EXT_platform_device wants the DRM node's fd as a
        // pointer-sized handle (wlroots does the same for its
        // create_from_drm_fd). eglGetPlatformDisplay takes a MUTABLE
        // void* (EGL/egl.h:320), so this is an untyped handle, never a
        // pointer to the borrowed fd.
        const handle: *anyopaque = @ptrFromInt(@as(usize, @intCast(dev.fd)));
        dpy = c.eglGetPlatformDisplay(c.EGL_PLATFORM_DEVICE_EXT, handle, null);
    }
    if (dpy == null) dpy = c.eglGetPlatformDisplay(c.EGL_PLATFORM_SURFACELESS_MESA, null, null);
    if (dpy == null) dpy = c.eglGetDisplay(null);
    if (dpy == null) {
        log_mod.err("eglGetPlatformDisplay/eglGetDisplay failed (no EGL?)", r.io, r.log_cfg, "gles2", .{});
        return error.EglInitFailed;
    }
    r.dpy = dpy;

    // eglGetPlatformDisplay REF-COUNTS by (platform, native display), so
    // a second renderer on the same device gets back THIS SAME display
    // handle. Claim it in the registry: the first claimer initializes it,
    // and teardownEgl terminates it only for the last holder. Without
    // this, one renderer destroying itself would eglTerminate (and
    // eglReleaseThread) a display a sibling renderer is still drawing on.
    //
    // No local errdefer releases the claim: a failure below leaves `dpy`
    // recorded on `r`, so the caller's teardownEgl drops exactly the one
    // claim this call took. Releasing here as well would corrupt the
    // count and terminate a display a sibling renderer still holds.
    const first_claim = display_registry.acquire(dpy) orelse {
        r.dpy = null;
        log_mod.err("EGL display registry is full; refusing to run an untracked display", r.io, r.log_cfg, "gles2", .{});
        return error.EglInitFailed;
    };

    if (first_claim) {
        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(dpy, &major, &minor) != c.EGL_TRUE) {
            log_mod.err("eglInitialize failed", r.io, r.log_cfg, "gles2", .{});
            return error.EglInitFailed;
        }
        display_registry.markInitialized(dpy);
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
    if (!r.makeCurrent()) return error.NoCurrentContext;
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
    r.loc_transform = c.glGetUniformLocation(program, "u_transform");
    r.loc_offset = c.glGetUniformLocation(program, "u_offset");
    r.loc_scale = c.glGetUniformLocation(program, "u_scale");
    r.loc_viewport = c.glGetUniformLocation(program, "u_viewport");
    r.loc_texel_offset = c.glGetUniformLocation(program, "u_texel_offset");
    r.loc_texel_affine = c.glGetUniformLocation(program, "u_texel_affine");
    r.loc_texel_clamp = c.glGetUniformLocation(program, "u_texel_clamp");
    r.loc_texel_inv = c.glGetUniformLocation(program, "u_texel_inv");
    r.loc_modulate = c.glGetUniformLocation(program, "u_modulate");
    r.loc_flip = c.glGetUniformLocation(program, "u_flip");
    r.loc_bgra = c.glGetUniformLocation(program, "u_bgra");
    if (r.loc_pos < 0 or r.loc_uv < 0 or r.loc_tex < 0 or r.loc_offset < 0 or
        r.loc_scale < 0 or r.loc_viewport < 0 or r.loc_transform < 0 or
        r.loc_texel_offset < 0 or r.loc_texel_affine < 0 or r.loc_texel_clamp < 0 or
        r.loc_texel_inv < 0 or r.loc_modulate < 0 or
        r.loc_flip < 0 or r.loc_bgra < 0)
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

/// Delete GL objects created by initGl. Binds the owning context first,
/// because these handles belong to it and the thread may have run
/// another renderer since. 0-guards make partial init safe.
fn deinitGl(r: *Gles2Data) void {
    if (r.program == 0 and r.vbo == 0 and r.white_tex == 0) return;
    if (!r.makeCurrent()) return;
    if (r.program != 0) c.glDeleteProgram(r.program);
    if (r.vbo != 0) c.glDeleteBuffers(1, &r.vbo);
    if (r.white_tex != 0) c.glDeleteTextures(1, &r.white_tex);
}

/// Destroy THIS renderer's context, then drop its display claim.
///
/// A display can be SHARED: `eglGetPlatformDisplay` returns the same
/// handle for a second renderer on the same device. So the context is
/// always destroyed — it is this renderer's alone — but `eglTerminate`
/// and `eglReleaseThread` run only for the LAST reference. Terminating
/// (or releasing the thread) while a sibling renderer still holds the
/// display would destroy its context's state out from under it.
fn teardownEgl(r: *Gles2Data) void {
    const dpy = r.dpy orelse return;
    const ctx = r.ctx;
    r.dpy = null;
    r.ctx = null;
    if (ctx != null) {
        // Unbind only if OUR context is the current one; a sibling
        // renderer may legitimately have made its own context current
        // since, and clearing that would break it.
        if (c.eglGetCurrentContext() == ctx) {
            _ = c.eglMakeCurrent(dpy, null, null, null);
        }
        _ = c.eglDestroyContext(dpy, ctx);
    }
    const released = display_registry.release(dpy);
    if (!released.last) return;
    if (released.initialized) _ = c.eglTerminate(dpy);
    // Only the last owner releases the thread's EGL state, for the same
    // reason: it is process-wide, not per-renderer.
    _ = c.eglReleaseThread();
}

/// Does this EGL DISPLAY advertise `name`?
///
/// `EGL_EXT_image_dma_buf_import` and its `_modifiers` companion are
/// DISPLAY extensions, so they are read from
/// `eglQueryString(dpy, EGL_EXTENSIONS)`. Querying `EGL_NO_DISPLAY`
/// instead returns the CLIENT extension list, which never contains
/// them — that mistake reported every device as unable to import DMA-BUF
/// and silently disabled the whole GPU path.
fn eglHasDisplayExtension(r: *Gles2Data, name: []const u8) bool {
    const dpy = r.dpy orelse return false;
    const list = c.eglQueryString(dpy, c.EGL_EXTENSIONS) orelse return false;
    return extensionListed(@as([*:0]const u8, @ptrCast(list)), name);
}

/// Does this GL context advertise `name`? Purely a GL string query, so
/// it needs no renderer.
fn glHasExtension(name: []const u8) bool {
    const list = c.glGetString(c.GL_EXTENSIONS) orelse return false;
    return extensionListed(@as([*:0]const u8, @ptrCast(list)), name);
}

/// Split a space-separated extension string into a lookup.
fn extensionListed(list: [*:0]const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, std.mem.span(list), " ");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, name)) return true;
    }
    return false;
}


/// Can this EGL + GL pair import a dmabuf at all? Both halves are needed:
/// EGL_EXT_image_dma_buf_import creates the image, GL_OES_EGL_image turns
/// it into a texture. Either one missing means no GPU path — reported
/// honestly as an empty renderFormats and a failing importDmabuf, never
/// as a CPU fallback.
///
/// Both are queried where they actually live: the EGL one as a DISPLAY
/// extension, the GL one from the current context.
fn probeDmabufImport(r: *Gles2Data) bool {
    r.has_modifier_import = eglHasDisplayExtension(r, "EGL_EXT_image_dma_buf_import_modifiers");
    if (!eglHasDisplayExtension(r, "EGL_EXT_image_dma_buf_import") or
        !glHasExtension("GL_OES_EGL_image")) return false;
    r.image_target_texture = @ptrCast(c.eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    return r.image_target_texture != null;
}

/// A fixed-capacity EGLAttrib list written in place. The import path runs
/// per client buffer and per scanout slot, so it allocates nothing: the
/// list is a stack array and this is just a bounds-checked cursor over it.
const AttribList = struct {
    items: []c.EGLAttrib,
    n: usize = 0,

    fn put(self: *AttribList, key: c.EGLAttrib, value: c.EGLAttrib) void {
        self.items[self.n] = key;
        self.n += 1;
        self.items[self.n] = value;
        self.n += 1;
    }

    fn terminate(self: *AttribList) void {
        self.items[self.n] = c.EGL_NONE;
        self.n += 1;
    }

    fn slice(self: *const AttribList) [*c]const c.EGLAttrib {
        return self.items[0..self.n].ptr;
    }
};

/// A native EGL image over a dmabuf's planes: the real DMA-BUF import
/// (no map, no copy). `attrs`' descriptors are borrowed for the call.
///
/// The call is EGL_EXT_image_dma_buf_import's own form:
///
///     eglCreateImage(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attribs)
///
/// with `attribs` an EGLAttrib list of EGL_WIDTH / EGL_HEIGHT /
/// EGL_LINUX_DRM_FOURCC_EXT followed by per-plane FD / OFFSET / PITCH
/// (EGL/eglext.h:761-785). There is NO EGL_IMAGE_FORMAT_FD attribute and
/// no EGL_IMAGE_* attribute of any kind: the fourcc carries the format
/// and the plane descriptors carry the memory. Targeting
/// EGL_GL_TEXTURE_2D with a NULL buffer, as an earlier revision did,
/// describes no importable object, and the invented FORMAT_FD token in
/// the list made the call fail on every driver.
///
/// `EGLAttrib` (not `EGLint`): core EGL 1.5 `eglCreateImage` takes
/// `const EGLAttrib *` (EGL/egl.h:329), and that is the entry point used
/// here — `eglCreateImageKHR` is the EGL_KHR_image spelling of the same
/// call with an `EGLint` list.
///
/// Modifier handling is honest in both directions: a TILED buffer can
/// only be imported when the display advertises
/// EGL_EXT_image_dma_buf_import_modifiers, because only that extension
/// defines the per-plane MODIFIER_LO/HI attributes (eglext.h:787-806).
/// With it, the real modifier travels in the list and the buffer imports
/// at its actual layout. Without it, a non-LINEAR buffer is REFUSED
/// rather than imported as if it were linear — which would sample the
/// wrong bytes and paint garbage. Plane 3 descriptors need the same
/// extension, because PLANE3_FD/OFFSET/PITCH are defined there too.
fn eglImageFromAttributes(r: *Gles2Data, attrs: *const dmabuf.Attributes) !c.EGLImage {
    if (!r.can_import_dmabuf) return error.DmabufImportUnsupported;
    const dpy = r.dpy orelse return error.EglInitFailed;
    const carry_modifier = r.has_modifier_import;
    if (attrs.modifier != dmabuf.drm_format_mod_linear and !carry_modifier) {
        return error.UnsupportedModifier;
    }
    if (attrs.width <= 0 or attrs.height <= 0) return error.InvalidSize;
    if (attrs.n_planes == 0 or attrs.n_planes > dmabuf.max_planes) return error.InvalidSize;
    if (attrs.n_planes > 3 and !carry_modifier) return error.UnsupportedPlaneCount;

    // Three fixed pairs (WIDTH, HEIGHT, FOURCC) plus, per plane, FD /
    // OFFSET / PITCH and — with the modifiers extension — MODIFIER_LO /
    // MODIFIER_HI. Then the EGL_NONE terminator.
    var storage: [2 * (3 + 5 * dmabuf.max_planes) + 1]c.EGLAttrib = undefined;
    var list = AttribList{ .items = &storage };
    list.put(c.EGL_WIDTH, @intCast(attrs.width));
    list.put(c.EGL_HEIGHT, @intCast(attrs.height));
    list.put(c.EGL_LINUX_DRM_FOURCC_EXT, @intCast(attrs.format));
    var i: u8 = 0;
    while (i < attrs.n_planes) : (i += 1) {
        const plane = attrs.planes[i];
        const tokens = planeAttribTokens(i);
        list.put(tokens[0], @intCast(plane.fd));
        list.put(tokens[1], @intCast(plane.offset));
        list.put(tokens[2], @intCast(plane.stride));
        if (carry_modifier) {
            const modifier_tokens = planeModifierTokens(i);
            list.put(modifier_tokens[0], @intCast(attrs.modifier & 0xffff_ffff));
            list.put(modifier_tokens[1], @intCast(attrs.modifier >> 32));
        }
    }
    list.terminate();

    // EGL_EXT_image_dma_buf_import requires EGL_NO_CONTEXT; the owning
    // GL context is used separately when binding this image to a texture.
    const img = c.eglCreateImage(dpy, c.EGL_NO_CONTEXT, c.EGL_LINUX_DMA_BUF_EXT, null, list.slice());
    if (img == null) {
        log_mod.warn(
            "eglCreateImage(dmabuf) failed for {d}x{d} fourcc 0x{x}",
            r.io,
            r.log_cfg,
            "gles2",
            .{ attrs.width, attrs.height, attrs.format },
        );
        return error.EglImageFailed;
    }
    return img;
}

/// The (FD, OFFSET, PITCH) attribute tokens of plane `i`
/// (EGL_EXT_image_dma_buf_import, eglext.h:765-773 and 789-791).
fn planeAttribTokens(i: u8) [3]c.EGLAttrib {
    return switch (i) {
        0 => .{ c.EGL_DMA_BUF_PLANE0_FD_EXT, c.EGL_DMA_BUF_PLANE0_OFFSET_EXT, c.EGL_DMA_BUF_PLANE0_PITCH_EXT },
        1 => .{ c.EGL_DMA_BUF_PLANE1_FD_EXT, c.EGL_DMA_BUF_PLANE1_OFFSET_EXT, c.EGL_DMA_BUF_PLANE1_PITCH_EXT },
        2 => .{ c.EGL_DMA_BUF_PLANE2_FD_EXT, c.EGL_DMA_BUF_PLANE2_OFFSET_EXT, c.EGL_DMA_BUF_PLANE2_PITCH_EXT },
        else => .{ c.EGL_DMA_BUF_PLANE3_FD_EXT, c.EGL_DMA_BUF_PLANE3_OFFSET_EXT, c.EGL_DMA_BUF_PLANE3_PITCH_EXT },
    };
}

/// The (MODIFIER_LO, MODIFIER_HI) attribute tokens of plane `i`
/// (EGL_EXT_image_dma_buf_import_modifiers, eglext.h:792-799). The
/// modifier is split into two 32-bit halves because the attribute values
/// are EGLint-sized.
fn planeModifierTokens(i: u8) [2]c.EGLAttrib {
    return switch (i) {
        0 => .{ c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, c.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT },
        1 => .{ c.EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT, c.EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT },
        2 => .{ c.EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, c.EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT },
        else => .{ c.EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT, c.EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT },
    };
}

/// The (format, modifier) pairs this renderer can render INTO, proved
/// at create() time and owned by the renderer.
///
/// Modifier-capable EGL displays supply their real candidates through
/// eglQueryDmaBufModifiersEXT, resolved with eglGetProcAddress. External-only
/// layouts cannot be render targets. Without that extension, only LINEAR
/// can be represented by the base import API and is independently proved.
///
/// Proof, not assertion: candidates are filtered by GBM (scanout +
/// rendering, one plane at that modifier), then a small buffer is
/// allocated, exported, imported as a real EGL image and its FBO checked
/// for completeness. An importable-but-not-renderable ("external only")
/// pair is dropped here rather than advertised. Everything here happens
/// once, at create; a frame never allocates.
fn probeRenderFormats(r: *Gles2Data) error{OutOfMemory}![]dmabuf.Format {
    const dev = r.gbm orelse return &.{};
    if (!r.can_import_dmabuf) return &.{};
    // Probe real integer formats rather than inferring renderability
    // from unrelated floating-point colour-buffer extensions.
    const candidates = [_]u32{
        dmabuf.drm_format_xrgb8888,
        dmabuf.drm_format_argb8888,
        dmabuf.drm_format_xrgb2101010,
        dmabuf.drm_format_argb2101010,
    };
    const query_modifiers: c.PFNEGLQUERYDMABUFMODIFIERSEXTPROC =
        if (r.has_modifier_import) @ptrCast(c.eglGetProcAddress("eglQueryDmaBufModifiersEXT")) else null;
    if (r.has_modifier_import and query_modifiers == null) return &.{};
    // Scratch capacity is reused between formats; capability probing is
    // startup-only and never allocates on a frame.
    var modifiers: std.ArrayList(c.EGLuint64KHR) = .empty;
    defer modifiers.deinit(r.allocator);
    var external_only: std.ArrayList(c.EGLBoolean) = .empty;
    defer external_only.deinit(r.allocator);

    var found: std.ArrayListUnmanaged(dmabuf.Format) = .empty;
    errdefer found.deinit(r.allocator);
    for (candidates) |format| {
        if (query_modifiers) |query| {
            var count: c.EGLint = 0;
            if (query(r.dpy, @bitCast(format), 0, null, null, &count) == c.EGL_FALSE or count <= 0) continue;
            try modifiers.resize(r.allocator, @intCast(count));
            try external_only.resize(r.allocator, @intCast(count));
            var returned: c.EGLint = 0;
            if (query(r.dpy, @bitCast(format), count, modifiers.items.ptr, external_only.items.ptr, &returned) == c.EGL_FALSE or
                returned < 0 or returned > count) continue;
            const n: usize = @intCast(returned);
            for (modifiers.items[0..n], external_only.items[0..n]) |modifier, external| {
                if (external == c.EGL_TRUE) continue;
                if (probeRenderableFormat(r, dev, format, modifier)) {
                    try found.append(r.allocator, .{ .format = format, .modifier = modifier });
                }
            }
        } else if (probeRenderableFormat(r, dev, format, dmabuf.drm_format_mod_linear)) {
            try found.append(r.allocator, .{ .format = format, .modifier = dmabuf.drm_format_mod_linear });
        }
    }
    if (found.items.len == 0) {
        log_mod.warn(
            "no dmabuf format is importable AND renderable on this device; the GPU path is unavailable",
            r.io,
            r.log_cfg,
            "gles2",
            .{},
        );
        return &.{};
    }
    log_mod.info(
        "gles2: {d} renderable dmabuf format(s) on the {s} device",
        r.io,
        r.log_cfg,
        "gles2",
        .{ found.items.len, dev.backendName() },
    );
    return found.toOwnedSlice(r.allocator);
}

/// One candidate: GBM must be able to allocate it for scanout and
/// rendering at the specified modifier with a single plane, the exported
/// buffer must import as an EGL image, and an FBO over that image must
/// be complete. The probe buffer is destroyed on every path.
fn probeRenderableFormat(r: *Gles2Data, dev: *dmabuf.GbmDevice, format: u32, modifier: u64) bool {
    const usage: u32 = gbm_c.GBM_BO_USE_SCANOUT | gbm_c.GBM_BO_USE_RENDERING;
    // The EGL image and the FBO below belong to this renderer's context.
    if (!r.makeCurrent()) return false;
    if (gbm_c.gbm_device_is_format_supported(dev.device, format, usage) == 0) return false;
    if (gbm_c.gbm_device_get_format_modifier_plane_count(dev.device, format, modifier) != 1) return false;
    const bo = gbm_c.gbm_bo_create_with_modifiers2(
        dev.device,
        probe_size,
        probe_size,
        format,
        &[_]u64{modifier},
        1,
        usage,
    ) orelse return false;
    defer gbm_c.gbm_bo_destroy(bo);
    // A driver may hand back a different modifier; the pitch-based import
    // would then read the wrong layout.
    if (gbm_c.gbm_bo_get_modifier(bo) != modifier) return false;
    if (gbm_c.gbm_bo_get_plane_count(bo) != 1) return false;
    const fd = gbm_c.gbm_bo_get_fd_for_plane(bo, 0);
    if (fd < 0) return false;
    defer _ = std.os.linux.close(fd);

    var attrs: dmabuf.Attributes = .{
        .width = probe_size,
        .height = probe_size,
        .format = format,
        .modifier = modifier,
        .n_planes = 1,
    };
    attrs.planes[0] = .{
        // A borrowed descriptor: the EGL image is destroyed before this
        // function returns, so no double close.
        .fd = @intCast(fd),
        .offset = gbm_c.gbm_bo_get_offset(bo, 0),
        .stride = gbm_c.gbm_bo_get_stride_for_plane(bo, 0),
    };

    const img = eglImageFromAttributes(r, &attrs) catch return false;
    defer _ = c.eglDestroyImage(r.dpy, img);
    var tex: c.GLuint = undefined;
    c.glGenTextures(1, &tex);
    defer c.glDeleteTextures(1, &tex);
    c.glBindTexture(c.GL_TEXTURE_2D, tex);
    setTextureParams();
    r.image_target_texture.?(c.GL_TEXTURE_2D, img);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    var fbo: c.GLuint = undefined;
    c.glGenFramebuffers(1, &fbo);
    defer c.glDeleteFramebuffers(1, &fbo);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, tex, 0);
    const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    return status == c.GL_FRAMEBUFFER_COMPLETE;
}

/// The probe buffer's edge, in pixels. Small enough to be cheap, large
/// enough that no driver special-cases a 1x1.
const probe_size: u32 = 16;

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

/// Read a target into a fresh CPU framebuffer (test helper).
fn readTarget(allocator: std.mem.Allocator, target: *Gles2Target) !*pixman_mod.Framebuffer {
    const fb = try pixman_mod.Framebuffer.create(allocator, target.width, target.height);
    errdefer fb.deinit();
    try target.readPixelsInto(fb);
    return fb;
}

/// An asymmetric 4x4 fixture (memory bytes B,G,R,A) with every texel a
/// different colour and every channel a multiple of 4, so a wrong
/// crop, scale, flip or rotation shows a DIFFERENT pixel and an exact
/// expectation never lands on a rounding tie.
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

/// The GPU's value where a fragment samples the crop at texel position
/// (tx, ty): GL_LINEAR over the ramp with the filter clamped to the
/// CROP's texel-centre bounds, which is what the fragment shader's
/// u_texel_clamp states (module docs, "# Sampling"). The tap rule comes
/// from `sampleBilinear` (texel centres at half-integers), not from the
/// shader's own arithmetic. GL accumulates the same four taps at
/// `mediump` precision, so a comparison against this allows one unit per
/// channel.
fn cropTap(crop: geom.FRect, tx: f64, ty: f64) [4]u8 {
    const lo_x = crop.x + 0.5;
    const lo_y = crop.y + 0.5;
    const x = std.math.clamp(tx, lo_x, @max(lo_x, crop.right() - 0.5));
    const y = std.math.clamp(ty, lo_y, @max(lo_y, crop.bottom() - 0.5));
    return sampleBilinear(&ramp4x4, 4, 4, x - 0.5, y - 0.5);
}

/// The continuous (no `-1`) surface -> buffer map of a
/// wl_output.transform, written from the transform definition rather
/// than from the map under test.
fn inverseContinuous(t: geom.Transform, x: f64, y: f64, tw: f64, th: f64) geom.FPoint {
    return switch (t) {
        .normal => .{ .x = x, .y = y },
        .@"90" => .{ .x = y, .y = th - x },
        .@"180" => .{ .x = tw - x, .y = th - y },
        .@"270" => .{ .x = tw - y, .y = x },
        .flipped => .{ .x = tw - x, .y = y },
        .flipped_90 => .{ .x = y, .y = x },
        .flipped_180 => .{ .x = x, .y = th - y },
        // FLIPPED_270 (wlr_box_transform util/box.c:143-146): x' =
        // height - y - h, y' = width - x - w, so the surface x axis
        // maps to the buffer's y axis, bounded by the buffer HEIGHT.
        .flipped_270 => .{ .x = tw - y, .y = th - x },
    };
}

/// The buffer texel destination pixel (x, y) samples under `t` in a
/// quad that covers the whole (untwisted) surface. GL reads a FRAGMENT
/// CENTRE, so the surface coordinate is (x + 0.5, y + 0.5) and the
/// texel is the floor of the continuous map — the same texel the CPU
/// canvas's corner-sampled, `-1`-offset map names for that pixel.
fn expectedTexel(t: geom.Transform, x: i32, y: i32, tw: i32, th: i32) geom.Point {
    const p = inverseContinuous(
        t,
        @as(f64, @floatFromInt(x)) + 0.5,
        @as(f64, @floatFromInt(y)) + 0.5,
        @floatFromInt(tw),
        @floatFromInt(th),
    );
    return .{ .x = @intFromFloat(@floor(p.x)), .y = @intFromFloat(@floor(p.y)) };
}

/// CPU reference for a whole-canvas draw of `texel` (tw x th, BGRA
/// memory bytes) under output transform `t`, a magnification of `scale`
/// target px per scene px and a final shift of (tx, ty) target px: the
/// shape of the one mat3 the renderer uploads, i.e.
/// `Affine.translate(tx, ty) * Affine.scale(scale, scale) *
/// Affine.fromTransform(t, tw, th)`.
///
/// It models the GL pipeline, which is NOT a point-wise map of scene
/// pixels onto target pixels:
///
///   1. The rasteriser fills the TRANSFORMED quad, so one scene pixel
///      covers a scale x scale block of target pixels and the fragment
///      centre of target pixel (x, y) is the point (x + 0.5, y + 0.5).
///   2. That centre maps back to a scene point
///      `bufferPoint(t, (x + 0.5 - tx) / scale, (y + 0.5 - ty) / scale)`,
///      which at any scale other than 1 lands BETWEEN texels.
///   3. GL_LINEAR blends the texels around it, and GL_CLAMP_TO_EDGE
///      makes an off-texture tap return the edge texel whole instead of
///      fading out.
///
/// Only a magnification of 1 puts every fragment centre on a texel
/// centre, and only then does the reference degenerate to a plain
/// point map. At 2x the centres sit a quarter texel off, so the
/// interior of every block is a 75/25 blend of neighbouring texels and
/// a reference that reads one texel per scene pixel would disagree
/// with the GPU on most of the image. All weights here are binary
/// fractions of whole bytes, so the float arithmetic is exact, and
/// GL's float -> unorm8 conversion rounds to nearest (GL ES 3.0
/// §2.1.2, "converted to fixed-point").
///
/// The draw is opaque (alpha 1.0) onto the pass's transparent clear,
/// so submitPass's premultiplied-over blend copies the sample.
fn expectedMapped(
    texel: []const u8,
    tw: i32,
    th: i32,
    t: geom.Transform,
    tx: i32,
    ty: i32,
    scale: i32,
    width: i32,
    height: i32,
    out: []u8,
) void {
    @memset(out, 0);
    const s: f64 = @floatFromInt(scale);
    const w: f64 = @floatFromInt(tw);
    const h: f64 = @floatFromInt(th);
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            const a = (@as(f64, @floatFromInt(x)) + 0.5 - @as(f64, @floatFromInt(tx))) / s;
            const b = (@as(f64, @floatFromInt(y)) + 0.5 - @as(f64, @floatFromInt(ty))) / s;
            const p = bufferPoint(t, a, b, w, h);
            // Outside the quad the rasteriser produced no fragment; the
            // pixel keeps the pass's transparent clear.
            if (p.x < 0 or p.y < 0 or p.x >= w or p.y >= h) continue;
            setPx(out, width, x, y, sampleBilinear(texel, tw, th, p.x - 0.5, p.y - 0.5));
        }
    }
}

/// Continuous buffer-space image of a surface point (a, b): the
/// inverse of wlr_box_transform (wlroots util/box.c:105-155) on a
/// zero-extent box, so it is `matrix.transformPoint` with the
/// pixel-centre `-1` terms dropped — that function reports the buffer
/// pixel whose centre sits at the queried surface pixel's centre.
/// `width`/`height` are the BUFFER size.
fn bufferPoint(t: geom.Transform, a: f64, b: f64, width: f64, height: f64) geom.FPoint {
    return switch (t) {
        .normal => .{ .x = a, .y = b },
        .@"90" => .{ .x = b, .y = height - a },
        .@"180" => .{ .x = width - a, .y = height - b },
        .@"270" => .{ .x = width - b, .y = a },
        .flipped => .{ .x = width - a, .y = b },
        .flipped_90 => .{ .x = b, .y = a },
        .flipped_180 => .{ .x = a, .y = height - b },
        .flipped_270 => .{ .x = height - b, .y = width - a },
    };
}

/// One GL_LINEAR tap: the bilinear blend of the texels around (u, v) in
/// texel-index space (texel centres sit at half-integers, so u is the
/// scene coordinate minus 0.5), with GL_CLAMP_TO_EDGE on the
/// coordinate — clamping the coordinate and clamping the indices are
/// the same thing for a bilinear filter.
fn sampleBilinear(texel: []const u8, tw: i32, th: i32, u: f64, v: f64) [4]u8 {
    const cx = std.math.clamp(u, 0.0, @as(f64, @floatFromInt(tw - 1)));
    const cy = std.math.clamp(v, 0.0, @as(f64, @floatFromInt(th - 1)));
    const x0: i32 = @intFromFloat(@floor(cx));
    const y0: i32 = @intFromFloat(@floor(cy));
    const x1 = @min(x0 + 1, tw - 1);
    const y1 = @min(y0 + 1, th - 1);
    const fx = cx - @as(f64, @floatFromInt(x0));
    const fy = cy - @as(f64, @floatFromInt(y0));
    const gx = 1.0 - fx;
    const gy = 1.0 - fy;
    const p00 = px(texel, tw, x0, y0);
    const p10 = px(texel, tw, x1, y0);
    const p01 = px(texel, tw, x0, y1);
    const p11 = px(texel, tw, x1, y1);
    var out: [4]u8 = undefined;
    for (0..4) |ch| {
        const blend = gx * gy * @as(f64, @floatFromInt(p00[ch])) +
            fx * gy * @as(f64, @floatFromInt(p10[ch])) +
            gx * fy * @as(f64, @floatFromInt(p01[ch])) +
            fx * fy * @as(f64, @floatFromInt(p11[ch]));
        // The clamp keeps a one-ulp overshoot above 255 out of
        // @intFromFloat; the + 0.5 is GL's round-to-nearest.
        out[ch] = @intFromFloat(@floor(std.math.clamp(blend, 0.0, 255.0) + 0.5));
    }
    return out;
}

fn px(buf: []const u8, w: i32, x: i32, y: i32) [4]u8 {
    const off = (@as(usize, @intCast(y)) * @as(usize, @intCast(w)) + @as(usize, @intCast(x))) * 4;
    return buf[off..][0..4].*;
}

fn setPx(buf: []u8, w: i32, x: i32, y: i32, color: [4]u8) void {
    const off = (@as(usize, @intCast(y)) * @as(usize, @intCast(w)) + @as(usize, @intCast(x))) * 4;
    buf[off..][0..4].* = color;
}

/// Test-only: draw `tex` (whole source) at `dst` into a fresh w x h
/// target through the renderer's CURRENT scene -> target transform,
/// then return the CPU framebuffer read back from it. Runs under the
/// caller's GL lock.
fn renderBlit(
    renderer: *renderer_mod.Renderer,
    allocator: std.mem.Allocator,
    w: i32,
    h: i32,
    tex: *texture_mod.Texture,
    dst: geom.FRect,
) !*pixman_mod.Framebuffer {
    const target = try Gles2Target.create(allocator, renderer, w, h);
    defer target.destroy();
    const pass = renderer.beginPass(target).?;
    pass.addTexture(tex, .{ .dst = dst });
    pass.submit();
    return readTarget(allocator, target);
}

const NoDmabufImpl = buffer_mod.Impl{
    .destroy = struct {
        fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
            _ = allocator;
            _ = data;
        }
    }.destroy,
};

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
    // A surfaceless renderer has no DRM device behind it, so it advertises
    // NO GPU scanout formats rather than pretending a CPU path is one.
    try std.testing.expectEqual(@as(usize, 0), Gles2Renderer.renderFormats(renderer).len);
}

test "gles2 refuses a buffer with no dma-buf descriptors, without leaking a lock" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    var backing: u8 = 0;
    const buf = try buffer_mod.Buffer.init(allocator, &NoDmabufImpl, &backing, 4, 4);
    defer buf.destroy();

    try std.testing.expectError(error.NotADmabuf, Gles2Renderer.importDmabuf(renderer, buf));
    // The failed import must leave the buffer exactly as it found it.
    try std.testing.expectEqual(@as(u32, 0), buf.n_locks);
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

    const target = try Gles2Target.create(allocator, renderer, 2, 2);
    defer target.destroy();

    // A submit with no ops still clears: GL texture storage holds
    // undefined bytes between passes, so the pass owns the target
    // contents (mirrors pixman's zero-initialized Framebuffer).
    const pass = renderer.beginPass(target).?;
    pass.submit();

    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(1, 1));
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
    const target = try Gles2Target.create(allocator, renderer, 2, 2);
    defer target.destroy();
    const pass = renderer.beginPass(target).?;
    pass.addTexture(tex, .{ .dst = .{ .x = 0, .y = 0, .width = 2, .height = 2 } });
    pass.submit();
    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(1, 1));
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
    const target = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target.destroy();
    const pass = renderer.beginPass(target).?;
    pass.addRect(.{ .x = 1, .y = 1, .width = 2, .height = 2 }, .{ 1.0, 0.0, 0.0, 1.0 });
    pass.submit();

    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(1, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));

    // Premultiplied-over blend: blue at 0.4 over white. Both rects must
    // go in ONE pass — submitPass clears the target on every clearing
    // pass, so a second pass would wipe the white fill underneath. The
    // blend leaves B=255, A=255 and G/R=0.6*255=153 (GL rounds
    // float->unorm8).
    const target2 = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target2.destroy();
    const pass_blend = renderer.beginPass(target2).?;
    pass_blend.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ 1.0, 1.0, 1.0, 1.0 });
    pass_blend.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ 0.0, 0.0, 1.0, 0.4 });
    pass_blend.submit();
    const fb2 = try readTarget(allocator, target2);
    defer fb2.deinit();
    try std.testing.expectEqual([4]u8{ 255, 153, 153, 255 }, fb2.pixelAt(1, 1));
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

    const target = try Gles2Target.create(allocator, renderer, 4, 4);
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
    pass.addTexture(tex, .{ .dst = .{ .x = 1, .y = 1, .width = 2, .height = 2 } });
    pass.submit();

    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(1, 1));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(2, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(1, 2));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, fb.pixelAt(2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(3, 3));
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

    const target = try Gles2Target.create(allocator, renderer, 2, 2);
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
    // block.
    const pass = renderer.beginPass(target).?;
    pass.addTexture(tex, .{
        .src = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
        .dst = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
    });
    pass.submit();

    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, fb.pixelAt(1, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 1));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, fb.pixelAt(1, 1));
}

test "gles2 every buffer transform draws the texels its own pixels name" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const target = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target.destroy();
    const tex = try Gles2Renderer.importMemory(renderer, 4, 4, 16, &ramp4x4);
    defer tex.destroy();

    // Each wl_output.transform, drawn 1:1 into a 4x4 target: the whole
    // texture fills the target and every destination pixel must show the
    // texel that pixel's own surface coordinate names. The fixture has
    // a different colour in every one of its 16 texels, so a transform
    // that was ignored, or applied with the wrong axis bounds, cannot
    // pass.
    const transforms = [_]geom.Transform{
        .normal,   .@"90",      .@"180",      .@"270",
        .flipped,  .flipped_90, .flipped_180, .flipped_270,
    };
    for (transforms) |t| {
        const pass = renderer.beginPass(target).?;
        pass.addTexture(tex, .{
            .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .transform = t,
        });
        pass.submit();
        const fb = try readTarget(allocator, target);
        defer fb.deinit();
        var y: i32 = 0;
        while (y < 4) : (y += 1) {
            var x: i32 = 0;
            while (x < 4) : (x += 1) {
                const t_texel = expectedTexel(t, x, y, 4, 4);
                const want = rampAt(t_texel.x, t_texel.y);
                std.testing.expectEqual(want, fb.pixelAt(x, y)) catch |err| {
                    std.debug.print("transform {s} at ({d}, {d})\n", .{ @tagName(t), x, y });
                    return err;
                };
            }
        }
    }
}

test "gles2 a raw src crop is stretched into the destination quad" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const target = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target.destroy();
    const tex = try Gles2Renderer.importMemory(renderer, 4, 4, 16, &ramp4x4);
    defer tex.destroy();

    // A wp_viewport destination stretches the crop: the raw crop
    // (1,1)-(3,3) is drawn 2x into the 4x4 quad. Drawing the whole
    // texture instead would put a different quadrant on screen. GL reads
    // a FRAGMENT CENTRE, so destination pixel (i, j) samples the crop at
    // texel position (1 + (i + 0.5)/2, 1 + (j + 0.5)/2), clamped by the
    // crop-edge rule to the crop's texel centres (1.5 .. 2.5): the two
    // outer pixel columns therefore show the crop's edge texels WHOLE,
    // and only the two interior columns blend. Without that clamp the
    // outer columns fade in texels (0,0) and (3,3) — a wp_viewport
    // source showing pixels outside itself.
    const crop: geom.FRect = .{ .x = 1, .y = 1, .width = 2, .height = 2 };
    const pass = renderer.beginPass(target).?;
    pass.addTexture(tex, .{
        .src = crop,
        .dst = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
    });
    pass.submit();

    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    var j: i32 = 0;
    while (j < 4) : (j += 1) {
        var i: i32 = 0;
        while (i < 4) : (i += 1) {
            const want = cropTap(crop, 1 + (@as(f64, @floatFromInt(i)) + 0.5) / 2.0, 1 + (@as(f64, @floatFromInt(j)) + 0.5) / 2.0);
            const got = fb.pixelAt(i, j);
            for (0..4) |ch| {
                const diff = if (want[ch] > got[ch]) want[ch] - got[ch] else got[ch] - want[ch];
                std.testing.expect(diff <= 1) catch |err| {
                    std.debug.print("crop stretched 2x at ({d}, {d}): composited {any}, expected {any}\n", .{
                        i, j, got, want,
                    });
                    return err;
                };
            }
        }
    }
    // The clamp, spelled out: the four corner pixels are exact crop
    // texels — (1,1) top-left, (2,2) bottom-right — not blends with the
    // texels just outside the crop.
    try std.testing.expectEqual(rampAt(1, 1), fb.pixelAt(0, 0));
    try std.testing.expectEqual(rampAt(2, 1), fb.pixelAt(3, 0));
    try std.testing.expectEqual(rampAt(1, 2), fb.pixelAt(0, 3));
    try std.testing.expectEqual(rampAt(2, 2), fb.pixelAt(3, 3));
}

/// Draw the same fixture through both backends: the CPU pass takes the
/// destination rect directly, the GPU the same rect plus the scene ->
/// target affine. Everything else — crop, buffer transform — is shared,
/// so a difference is a sampling-contract difference, not a wiring one.
fn drawOnBoth(
    cpu: *renderer_mod.Renderer,
    cpu_fb: *pixman_mod.Framebuffer,
    gpu: *renderer_mod.Renderer,
    gpu_target: *Gles2Target,
    tex_cpu: *texture_mod.Texture,
    tex_gpu: *texture_mod.Texture,
    affine: Affine,
    cpu_dst: geom.FRect,
    gpu_dst: geom.FRect,
    src: ?geom.FRect,
    transform: geom.Transform,
) !void {
    const cpu_pass = cpu.beginPass(cpu_fb).?;
    cpu_pass.addTexture(tex_cpu, .{ .src = src, .dst = cpu_dst, .transform = transform });
    cpu_pass.submit();
    Gles2Renderer.setTransform(gpu, affine);
    const gpu_pass = gpu.beginPass(gpu_target).?;
    gpu_pass.addTexture(tex_gpu, .{ .src = src, .dst = gpu_dst, .transform = transform });
    gpu_pass.submit();
}

/// Every pixel of both targets must match within ONE unit per channel:
/// the GPU accumulates the same four taps at `mediump` precision, so one
/// unit is quantization, and anything larger is a different texel or a
/// different weight.
fn expectBackendsAgree(
    gpu_fb: *const pixman_mod.Framebuffer,
    cpu_fb: *const pixman_mod.Framebuffer,
    label: []const u8,
) !void {
    try std.testing.expectEqual(cpu_fb.width, gpu_fb.width);
    try std.testing.expectEqual(cpu_fb.height, gpu_fb.height);
    var y: i32 = 0;
    while (y < gpu_fb.height) : (y += 1) {
        var x: i32 = 0;
        while (x < gpu_fb.width) : (x += 1) {
            const g = gpu_fb.pixelAt(x, y);
            const cpu_pixel = cpu_fb.pixelAt(x, y);
            for (0..4) |ch| {
                const diff = if (g[ch] > cpu_pixel[ch]) g[ch] - cpu_pixel[ch] else cpu_pixel[ch] - g[ch];
                std.testing.expect(diff <= 1) catch |err| {
                    std.debug.print("{s} at ({d}, {d}) channel {d}: GPU {any}, CPU {any}\n", .{
                        label, x, y, ch, g, cpu_pixel,
                    });
                    return err;
                };
            }
        }
    }
}

// The GPU and the CPU pass must place the same texel on the same output
// pixel. Both sample a destination pixel at its CENTRE, in the same
// texel frame (texel i spans [i, i+1), centre at i + 0.5), with the
// filter clamped to the crop's centre bounds — tested exactly where
// the two used to disagree by half a texel: a non-integer
// magnification (1.25x), all eight buffer transforms at 1:1, a raw
// crop stretched non-integrally (2.5x), and a camera-like fractional
// scene->target translate.
//
// The absolute pixel values come from the sampling contract spelled out
// per case in the comments below (destination-normalized centre ->
// texel position -> crop clamp -> bilinear weights), never from either
// renderer's own output.
test "gles2 and the CPU pass agree on an asymmetric fixture at scale, transforms, crop and camera" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const cpu = try pixman_mod.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer cpu.destroy();
    const gpu = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer gpu.destroy();
    const tex_cpu = try pixman_mod.PixmanRenderer.importMemory(cpu, 4, 4, 16, &ramp4x4);
    defer tex_cpu.destroy();
    const tex_gpu = try Gles2Renderer.importMemory(gpu, 4, 4, 16, &ramp4x4);
    defer tex_gpu.destroy();

    // 1. Non-integer magnification: 4x4 into 5x5 at an INTEGER origin,
    //    1.25x, so no fragment centre lands on a quad edge (centres are
    //    half-integers, the edges whole pixels) — an edge-exact centre is
    //    the one place the GPU's fill rule and a half-open CPU test
    //    could legitimately disagree, and it is not what this contract
    //    is about. Pixel (i, j)'s centre sits at destination position
    //    ((i + 0.5 - 1)/5, (j + 0.5 - 1)/5) of the quad, i.e. texel
    //    position (4(i - 0.5)/5, 4(j - 0.5)/5), which the
    //    whole-texture clamp pins to [0.5, 3.5]:
    //      (1,1) position (0.4, 0.4) -> clamped to 0.5 -> texel (0,0)
    //      (3,3) position (2.0, 2.0) -> index (1.5, 1.5) -> a quarter of
    //           each of texels (1,1), (2,1), (1,2), (2,2):
    //           B (20+24+36+40)/4 = 30,  G (40+36+24+20)/4 = 30,
    //           R (28+32+44+48)/4 = 38
    //      (5,5) position (3.6, 3.6) -> clamped to 3.5 -> texel (3,3)
    //      (0,0) centre at -0.1 of the quad: outside it, so the pass's
    //           transparent clear shows through.
    {
        const dst: geom.FRect = .{ .x = 1, .y = 1, .width = 5, .height = 5 };
        const cpu_fb = try pixman_mod.Framebuffer.create(allocator, 7, 7);
        defer cpu_fb.deinit();
        const target = try Gles2Target.create(allocator, gpu, 7, 7);
        defer target.destroy();
        try drawOnBoth(cpu, cpu_fb, gpu, target, tex_cpu, tex_gpu, .identity, dst, dst, null, .normal);
        const gpu_fb = try readTarget(allocator, target);
        defer gpu_fb.deinit();
        try expectBackendsAgree(gpu_fb, cpu_fb, "1.25x at (1, 1)");
        try std.testing.expectEqual(rampAt(0, 0), gpu_fb.pixelAt(1, 1));
        try std.testing.expectEqual([4]u8{ 30, 30, 38, 255 }, gpu_fb.pixelAt(3, 3));
        try std.testing.expectEqual(rampAt(3, 3), gpu_fb.pixelAt(5, 5));
        try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, gpu_fb.pixelAt(0, 0));
        try std.testing.expectEqual(rampAt(0, 0), cpu_fb.pixelAt(1, 1));
        try std.testing.expectEqual([4]u8{ 30, 30, 38, 255 }, cpu_fb.pixelAt(3, 3));
    }

    // 2. Every buffer transform, 1:1: pixel (i, j)'s centre sits on the
    //    surface pixel (i, j), whose texel is the hand-written table
    //    `expectedTexel` names — the same pin the uncropped GL test uses.
    {
        const dst: geom.FRect = .{ .x = 0, .y = 0, .width = 4, .height = 4 };
        const transforms = [_]geom.Transform{
            .normal,   .@"90",      .@"180",      .@"270",
            .flipped,  .flipped_90, .flipped_180, .flipped_270,
        };
        const cpu_fb = try pixman_mod.Framebuffer.create(allocator, 4, 4);
        defer cpu_fb.deinit();
        const target = try Gles2Target.create(allocator, gpu, 4, 4);
        defer target.destroy();
        for (transforms) |t| {
            try drawOnBoth(cpu, cpu_fb, gpu, target, tex_cpu, tex_gpu, .identity, dst, dst, null, t);
            const gpu_fb = try readTarget(allocator, target);
            defer gpu_fb.deinit();
            try expectBackendsAgree(gpu_fb, cpu_fb, @tagName(t));
            var y: i32 = 0;
            while (y < 4) : (y += 1) {
                var x: i32 = 0;
                while (x < 4) : (x += 1) {
                    const texel = expectedTexel(t, x, y, 4, 4);
                    std.testing.expectEqual(rampAt(texel.x, texel.y), gpu_fb.pixelAt(x, y)) catch |err| {
                        std.debug.print("{s} at ({d}, {d})\n", .{ @tagName(t), x, y });
                        return err;
                    };
                    std.testing.expectEqual(rampAt(texel.x, texel.y), cpu_fb.pixelAt(x, y)) catch |err| {
                        std.debug.print("cpu {s} at ({d}, {d})\n", .{ @tagName(t), x, y });
                        return err;
                    };
                }
            }
        }
    }

    // 3. A raw crop (1,1)-(3,3) stretched 2.5x into 5x5 at (1, 1):
    //    pixel (i, j)'s centre is at texel position
    //    (1 + 2(i - 0.5)/5, 1 + 2(j - 0.5)/5) of the buffer, which the
    //    crop's centre bounds [1.5, 2.5] pin:
    //      (1,1) position (1.2, 1.2) -> clamped to (1.5, 1.5) -> texel (1,1)
    //      (3,3) position (2.0, 2.0) -> index (1.5, 1.5) -> a quarter of
    //           each of the crop's four texels -> {30, 30, 38}
    //      (5,5) position (2.8, 2.8) -> clamped to 2.5 -> texel (2,2)
    {
        const crop: geom.FRect = .{ .x = 1, .y = 1, .width = 2, .height = 2 };
        const dst: geom.FRect = .{ .x = 1, .y = 1, .width = 5, .height = 5 };
        const cpu_fb = try pixman_mod.Framebuffer.create(allocator, 7, 7);
        defer cpu_fb.deinit();
        const target = try Gles2Target.create(allocator, gpu, 7, 7);
        defer target.destroy();
        try drawOnBoth(cpu, cpu_fb, gpu, target, tex_cpu, tex_gpu, .identity, dst, dst, crop, .normal);
        const gpu_fb = try readTarget(allocator, target);
        defer gpu_fb.deinit();
        try expectBackendsAgree(gpu_fb, cpu_fb, "crop 2.5x at (1, 1)");
        try std.testing.expectEqual(rampAt(1, 1), gpu_fb.pixelAt(1, 1));
        try std.testing.expectEqual([4]u8{ 30, 30, 38, 255 }, gpu_fb.pixelAt(3, 3));
        try std.testing.expectEqual(rampAt(2, 2), gpu_fb.pixelAt(5, 5));
        try std.testing.expectEqual(rampAt(1, 1), cpu_fb.pixelAt(1, 1));
        try std.testing.expectEqual([4]u8{ 30, 30, 38, 255 }, cpu_fb.pixelAt(3, 3));
    }

    // 4. Camera: a fractional scene -> target translate. The GPU carries
    //    it in the affine; the CPU pass has no affine, so the same
    //    offset rides on the destination rect — the two must land the
    //    same texels. Target pixel (x, y)'s centre maps back to the
    //    scene point (x + 0.5 - 1.25, y + 0.5 - 0.75):
    //      (1,1) scene (0.25, 0.75) -> texel position (0.25, 0.75),
    //           clamped to (0.5, 0.75) -> index (0, 0.25): 75% texel 0
    //           and 25% texel 1 down each column:
    //           B 0.75*0 + 0.25*16 = 4,  G 0.75*60 + 0.25*44 = 56,
    //           R 0.75*8 + 0.25*24 = 12
    //      (2,2) scene (1.25, 1.75) -> texel position (1.25, 1.75) ->
    //           index (0.75, 1.25) -> {23, 37, 31}
    //      (1,0) scene (0.25, -0.25) -> above the quad's top edge: the
    //           clear.
    {
        const gpu_dst: geom.FRect = .{ .x = 0, .y = 0, .width = 4, .height = 4 };
        const cpu_dst: geom.FRect = .{ .x = 1.25, .y = 0.75, .width = 4, .height = 4 };
        const cpu_fb = try pixman_mod.Framebuffer.create(allocator, 6, 5);
        defer cpu_fb.deinit();
        const target = try Gles2Target.create(allocator, gpu, 6, 5);
        defer target.destroy();
        try drawOnBoth(cpu, cpu_fb, gpu, target, tex_cpu, tex_gpu, Affine.translate(1.25, 0.75), cpu_dst, gpu_dst, null, .normal);
        const gpu_fb = try readTarget(allocator, target);
        defer gpu_fb.deinit();
        try expectBackendsAgree(gpu_fb, cpu_fb, "camera translate (1.25, 0.75)");
        try std.testing.expectEqual([4]u8{ 4, 56, 12, 255 }, gpu_fb.pixelAt(1, 1));
        try std.testing.expectEqual([4]u8{ 23, 37, 31, 255 }, gpu_fb.pixelAt(2, 2));
        try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, gpu_fb.pixelAt(1, 0));
        try std.testing.expectEqual([4]u8{ 4, 56, 12, 255 }, cpu_fb.pixelAt(1, 1));
        try std.testing.expectEqual([4]u8{ 23, 37, 31, 255 }, cpu_fb.pixelAt(2, 2));
    }
}

test "gles2 a transform set inside a pass applies from that point on" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const target = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target.destroy();

    // One pass, two coordinate spaces: a fill through a camera-like
    // translate, then a screen-space quad through the identity. A pass
    // that only applied the LAST transform would put the fill's pixels
    // under the cursor's quad; a pass that applied the FIRST to both
    // would move the second quad 2 px right.
    const pass = renderer.beginPass(target).?;
    Gles2Renderer.setTransform(renderer, Affine.translate(2, 0));
    pass.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ 1.0, 0.0, 0.0, 1.0 });
    Gles2Renderer.setTransform(renderer, .identity);
    pass.addRect(.{ .x = 0, .y = 0, .width = 2, .height = 4 }, .{ 0.0, 0.0, 1.0, 1.0 });
    pass.submit();

    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    // Columns 0..1: the screen-space blue over red.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, fb.pixelAt(1, 3));
    // Columns 2..3: red only, where the translated fill reached.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(2, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(3, 3));
}

/// One labelled pixel expectation that dumps the WHOLE target when it
/// fails. Which pass lost (or misplaced) a draw is the only thing a
/// multi-pass failure can tell us, and a bare byte compare reports only
/// that two four-byte values differ.
fn expectLabelledPixel(
    fb: *const pixman_mod.Framebuffer,
    stage: []const u8,
    x: i32,
    y: i32,
    want: [4]u8,
) !void {
    std.testing.expectEqual(want, fb.pixelAt(x, y)) catch |err| {
        std.debug.print("after the {s} pass: ({d}, {d}) is {any}, expected {any}. Whole target (B,G,R,A):\n", .{
            stage, x, y, fb.pixelAt(x, y), want,
        });
        var gy: i32 = 0;
        while (gy < fb.height) : (gy += 1) {
            var gx: i32 = 0;
            while (gx < fb.width) : (gx += 1) {
                std.debug.print("    ({d}, {d}) {any}\n", .{ gx, gy, fb.pixelAt(gx, gy) });
            }
        }
        return err;
    };
}

/// Every pixel of `fb` must hold `want`, each one labelled by stage so a
/// failure says WHICH pass went wrong and where its pixels landed.
fn expectWholeTarget(fb: *const pixman_mod.Framebuffer, stage: []const u8, want: [4]u8) !void {
    var y: i32 = 0;
    while (y < fb.height) : (y += 1) {
        var x: i32 = 0;
        while (x < fb.width) : (x += 1) {
            try expectLabelledPixel(fb, stage, x, y, want);
        }
    }
}

test "gles2 a pass that does not clear keeps the pixels already drawn" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const target = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target.destroy();
    // Framebuffer bytes are B,G,R,A, the shader colours straight-alpha
    // RGBA: pass red {1,0,0,1} is bytes {0,0,255,255} and pass blue
    // {0,0,1,1} is bytes {255,0,0,255}.
    const base_bytes: [4]u8 = .{ 0, 0, 255, 255 };
    const cursor_bytes: [4]u8 = .{ 255, 0, 0, 255 };

    // The composited base: one clearing pass, the whole target red.
    const base = renderer.beginPass(target).?;
    base.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ 1.0, 0.0, 0.0, 1.0 });
    base.submit();
    {
        const fb = try readTarget(allocator, target);
        defer fb.deinit();
        try expectWholeTarget(fb, "base (clearing)", base_bytes);
    }

    // ... then the screen-space cursor drawn OVER it in a second pass. A
    // hidden clear here would erase the base outside the cursor; a lost
    // draw would leave the base everywhere.
    const over = renderer.beginPass(target).?;
    over.clear = false;
    over.addRect(.{ .x = 1, .y = 1, .width = 2, .height = 2 }, .{ 0.0, 0.0, 1.0, 1.0 });
    over.submit();

    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    // Only the cursor's own 2x2 rect may differ: the cursor's colour
    // inside it, the composited base everywhere else. Every pixel is
    // checked, so a quad that landed somewhere else shows up as the
    // cursor's colour there and the base inside the rect.
    var y: i32 = 0;
    while (y < 4) : (y += 1) {
        var x: i32 = 0;
        while (x < 4) : (x += 1) {
            const in_cursor = x >= 1 and x < 3 and y >= 1 and y < 3;
            try expectLabelledPixel(fb, "cursor overlay", x, y, if (in_cursor) cursor_bytes else base_bytes);
        }
    }
}

test "gles2 readPixelsInto writes caller-owned storage top-down" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    const target = try Gles2Target.create(allocator, renderer, 4, 2);
    defer target.destroy();
    const pass = renderer.beginPass(target).?;
    pass.addRect(.{ .x = 0, .y = 0, .width = 4, .height = 1 }, .{ 1.0, 0.0, 0.0, 1.0 });
    pass.submit();

    // The caller's own framebuffer, filled in place: GL's origin is
    // bottom-left, the CPU contract is top-down, so the drawn TOP row
    // must be row 0 here.
    const fb = try pixman_mod.Framebuffer.create(allocator, 4, 2);
    defer fb.deinit();
    try target.readPixelsInto(fb);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, fb.pixelAt(3, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, fb.pixelAt(0, 1));

    // A storage size that does not match the target is refused outright,
    // never partially filled.
    const wrong = try pixman_mod.Framebuffer.create(allocator, 2, 2);
    defer wrong.deinit();
    try std.testing.expectError(error.SizeMismatch, target.readPixelsInto(wrong));
}

test "gles2 scene->target transform defaults to identity" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    // A caller that never sets a transform gets the pre-transform
    // renderer: the matrix uniform starts at the identity.
    const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
    try std.testing.expectEqual(Affine.identity, data.transform);

    // BGRA bytes: red, green / blue, white (the "1:1 texture blit"
    // pattern).
    const pattern = [_]u8{
        0,   0,   255, 255,
        0,   255, 0,   255,
        255, 0,   0,   255,
        255, 255, 255, 255,
    };
    const tex = try Gles2Renderer.importMemory(renderer, 2, 2, 8, &pattern);
    defer tex.destroy();
    const dst: geom.FRect = .{ .x = 1, .y = 1, .width = 2, .height = 2 };

    const unset = try renderBlit(renderer, allocator, 4, 4, tex, dst);
    defer unset.deinit();

    // Setting the identity explicitly must be byte-identical to the
    // unset default: the matrix is live in the shader and it moves
    // nothing at identity.
    Gles2Renderer.setTransform(renderer, .identity);
    const explicit = try renderBlit(renderer, allocator, 4, 4, tex, dst);
    defer explicit.deinit();
    try std.testing.expectEqualSlices(u8, unset.data, explicit.data);

    // ... and those are the pre-change pixels, unchanged. dst
    // (1,1,2,2) shows the pattern's texels (0,0)..(1,1), i.e. red,
    // green / blue, white in memory bytes B,G,R,A.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, unset.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, unset.pixelAt(1, 1)); // red
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, unset.pixelAt(2, 1)); // green
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, unset.pixelAt(1, 2)); // blue
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, unset.pixelAt(2, 2)); // white
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, unset.pixelAt(3, 3));
}

test "gles2 output transform 90 matches the CPU reference" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    // 4x2 source, eight distinct opaque colors (memory bytes B,G,R,A):
    // red, green, blue, white / cyan, magenta, brown, slate.
    const pattern = [_]u8{
        0,   0,   255, 255,
        0,   255, 0,   255,
        255, 0,   0,   255,
        255, 255, 255, 255,
        0,   255, 255, 255,
        255, 0,   255, 255,
        128, 64,  32,  255,
        32,  32,  128, 255,
    };
    const tex = try Gles2Renderer.importMemory(renderer, 4, 2, 16, &pattern);
    defer tex.destroy();

    // Whole scene at dst (0,0,4,2), rotated 90 degrees about the
    // scene origin and then shifted down one target px. The rotated
    // target is the ROTATED size, transformedSize(4, 2) = 2x4 (wlroots
    // wlr_output_transformed_resolution, types/output/output.c:456):
    // u_viewport is the target's size and runs after the transform.
    // The extra row makes the shift observable — an image left at the
    // origin would start at row 0.
    const whole: geom.FRect = .{ .x = 0, .y = 0, .width = 4, .height = 2 };
    Gles2Renderer.setTransform(
        renderer,
        Affine.compose(Affine.translate(0, 1), Affine.fromTransform(.@"90", 4, 2)),
    );
    const gpu = try renderBlit(renderer, allocator, 2, 5, tex, whole);
    defer gpu.deinit();

    const want = try allocator.alloc(u8, 2 * 5 * 4);
    defer allocator.free(want);
    expectedMapped(&pattern, 4, 2, .@"90", 0, 1, 1, 2, 5, want);
    try std.testing.expectEqualSlices(u8, want, gpu.data);

    // Hand-computed against wlr_box_transform (util/box.c:125-128,
    // x' = height - y - 1, y' = x) plus the one-pixel shift: scene
    // (0,0) -> target (1,1), scene (3,1) -> target (0,4).
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, gpu.pixelAt(1, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, gpu.pixelAt(1, 1)); // red
    try std.testing.expectEqual([4]u8{ 32, 32, 128, 255 }, gpu.pixelAt(0, 4)); // slate
}

test "gles2 transform composes rotate, scale and translate" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    // BGRA bytes: red, green / blue, white.
    const pattern = [_]u8{
        0,   0,   255, 255,
        0,   255, 0,   255,
        255, 0,   0,   255,
        255, 255, 255, 255,
    };
    const tex = try Gles2Renderer.importMemory(renderer, 2, 2, 8, &pattern);
    defer tex.destroy();

    // Scene -> target map, in the order the shader applies it: rotate
    // 90 about the scene origin, magnify 2x, then shift by (1,1) target
    // px. The quad lands on target x,y in [1, 5); an 8x8 target keeps
    // that clear of the edges, so a transform that moved or rescaled
    // wrongly shows up as a shifted or clipped image.
    const affine = Affine.compose(
        Affine.translate(1, 1),
        Affine.compose(Affine.scale(2, 2), Affine.fromTransform(.@"90", 2, 2)),
    );
    Gles2Renderer.setTransform(renderer, affine);
    const whole: geom.FRect = .{ .x = 0, .y = 0, .width = 2, .height = 2 };
    const gpu = try renderBlit(renderer, allocator, 8, 8, tex, whole);
    defer gpu.deinit();

    const want = try allocator.alloc(u8, 8 * 8 * 4);
    defer allocator.free(want);
    expectedMapped(&pattern, 2, 2, .@"90", 1, 1, 2, 8, 8, want);
    try std.testing.expectEqualSlices(u8, want, gpu.data);

    // Spot checks, hand-computed from that map (target_x = 5 - 2·scene_y,
    // target_y = 2·scene_x + 1): the quad covers target [1,5)² and
    // scene texel (0,0) red owns the 2x2 block x in [3,5), y in [1,3).
    // At 2x only the four image corners tap a single texel — every
    // interior fragment centre sits a quarter texel off and GL_LINEAR
    // blends two of them — so those are the pixels that pin the
    // placement, plus one blended pixel that pins the magnification.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, gpu.pixelAt(0, 0));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, gpu.pixelAt(1, 1)); // blue
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, gpu.pixelAt(4, 1)); // red
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, gpu.pixelAt(1, 4)); // white
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, gpu.pixelAt(4, 4)); // green
    // 1/4 red over 3/4 blue: 0.25*255 = 63.75 -> 64, 0.75*255 = 191.25
    // -> 191 (GL rounds float -> unorm8 to nearest).
    try std.testing.expectEqual([4]u8{ 0xBF, 0, 0x40, 0xFF }, gpu.pixelAt(2, 1));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, gpu.pixelAt(5, 5));
}

test "gles2 two renderer contexts keep their own pixels" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};

    // TWO independent renderer contexts. eglGetPlatformDisplay returns
    // the SAME EGLDisplay handle for both, so this is also the case where
    // a stray eglTerminate (or an implicit "whatever context happens to
    // be current") would corrupt the other renderer's pixels or tear
    // down a display the other still renders on.
    // Every owner is nullable with a defer, so an assertion failure
    // part way through still releases what it created — a test that only
    // frees on the success path reports the leak the failure already
    // explains, and hides it. The renderers' defers are registered FIRST
    // so the LIFO order destroys both targets before either renderer.
    var renderer_a: ?*renderer_mod.Renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer if (renderer_a) |r| r.destroy();
    var renderer_b: ?*renderer_mod.Renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer if (renderer_b) |r| r.destroy();

    // Asymmetric fixtures: each target's four quadrants carry four
    // DIFFERENT colours, and no colour is shared between the two
    // renderers. A readback served by the wrong context, a stale FBO
    // binding or a leaked pixel therefore shows a different colour, and
    // never accidentally the expected one.
    var target_a: ?*Gles2Target = try Gles2Target.create(allocator, renderer_a.?, 4, 4);
    defer if (target_a) |t| t.destroy();
    var target_b: ?*Gles2Target = try Gles2Target.create(allocator, renderer_b.?, 4, 4);
    defer if (target_b) |t| t.destroy();

    const fill = struct {
        fn draw(renderer: *renderer_mod.Renderer, target: *Gles2Target, quads: [4][4]f32) !void {
            const pass = renderer.beginPass(target) orelse return error.NoPass;
            for (quads, 0..) |color, i| {
                const x: f64 = @floatFromInt((i % 2) * 2);
                const y: f64 = @floatFromInt((i / 2) * 2);
                pass.addRect(.{ .x = x, .y = y, .width = 2, .height = 2 }, color);
            }
            pass.submit();
        }
    }.draw;

    // A: red / green / blue / white. B: cyan / magenta / amber / indigo.
    // B's partial intensities are eighths, quarters and three quarters:
    // every one is exact in the fragment shader's mediump float and lands
    // on a byte GL cannot round the wrong way (0.125·255 = 31.875,
    // 0.25·255 = 63.75, 0.75·255 = 191.25). A HALF would land exactly on
    // .5, where float->unorm8 rounding is the driver's choice and a
    // 127 for an expected 128 is legal, not a defect.
    const quads_a = [4][4]f32{
        .{ 1.0, 0.0, 0.0, 1.0 }, .{ 0.0, 1.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0, 1.0 }, .{ 1.0, 1.0, 1.0, 1.0 },
    };
    const quads_b = [4][4]f32{
        .{ 0.0, 1.0, 1.0, 1.0 }, .{ 1.0, 0.0, 1.0, 1.0 },
        .{ 0.125, 0.25, 0.75, 1.0 }, .{ 0.75, 0.125, 0.25, 1.0 },
    };

    const expectA = [4][4]u8{
        .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 255 },
        .{ 255, 0, 0, 255 }, .{ 255, 255, 255, 255 },
    };
    const expectB = [4][4]u8{
        .{ 255, 255, 0, 255 }, .{ 255, 0, 255, 255 },
        .{ 191, 64, 32, 255 }, .{ 64, 32, 191, 255 },
    };

    const expect = struct {
        fn quadrants(fb: *const pixman_mod.Framebuffer, want: [4][4]u8) !void {
            for (want, 0..) |expected, i| {
                const x: i32 = @intCast(i % 2 * 2);
                const y: i32 = @intCast(i / 2 * 2);
                std.testing.expectEqual(expected, fb.pixelAt(x, y)) catch |err| {
                    std.debug.print("quadrant {d} at ({d}, {d}): composited {any}, expected {any}\n", .{
                        i, x, y, fb.pixelAt(x, y), expected,
                    });
                    return err;
                };
            }
        }
    }.quadrants;

    const readA = struct {
        fn go(alloc: std.mem.Allocator, target: *Gles2Target) !*pixman_mod.Framebuffer {
            const fb = try pixman_mod.Framebuffer.create(alloc, target.width, target.height);
            errdefer fb.deinit();
            try target.readPixelsInto(fb);
            return fb;
        }
    }.go;

    // Interleaved: draw into A, draw into B, read A, read B, draw into A
    // again. Every readback must show that renderer's OWN colours.
    try fill(renderer_a.?, target_a.?, quads_a);
    try fill(renderer_b.?, target_b.?, quads_b);
    {
        const fb_a = try readA(allocator, target_a.?);
        defer fb_a.deinit();
        try expect(fb_a, expectA);
    }
    {
        const fb_b = try readA(allocator, target_b.?);
        defer fb_b.deinit();
        try expect(fb_b, expectB);
    }
    try fill(renderer_a.?, target_a.?, quads_a);
    {
        const fb_a = try readA(allocator, target_a.?);
        defer fb_a.deinit();
        try expect(fb_a, expectA);
    }

    // Destroying A's GL objects and A's renderer must NOT terminate the
    // EGLDisplay B still renders on: B draws and reads its own pixels
    // afterwards. Each destroy nulls its owner, so the defers above do
    // not free it twice.
    if (target_a) |t| {
        t.destroy();
        target_a = null;
    }
    if (renderer_a) |r| {
        r.destroy();
        renderer_a = null;
    }
    try fill(renderer_b.?, target_b.?, quads_b);
    {
        const fb_b = try readA(allocator, target_b.?);
        defer fb_b.deinit();
        try expect(fb_b, expectB);
    }

    // And the reverse: destroying B (the last owner of the shared
    // display) tears everything down cleanly.
    if (target_b) |t| {
        t.destroy();
        target_b = null;
    }
    if (renderer_b) |r| {
        r.destroy();
        renderer_b = null;
    }
}

test "gles2 readback is top-down BGRA for every row" {
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();

    // Four ROWS of four distinct colours. glReadPixels(GL_RGBA) hands
    // back LOGICAL R,G,B,A bytes, and the Framebuffer contract is
    // ARGB8888 memory order (B,G,R,A), so every row needs the R/B swap —
    // and the bottom-up GL row order must land on the CPU's top-down
    // rows. Both mistakes are visible here because no colour repeats and
    // no two rows are alike.
    const target = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target.destroy();
    const rows = [4][4]f32{
        .{ 1.0, 0.0, 0.0, 1.0 }, .{ 0.0, 1.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0, 1.0 }, .{ 1.0, 1.0, 0.0, 1.0 },
    };
    const want = [4][4]u8{
        .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 255 },
        .{ 255, 0, 0, 255 }, .{ 0, 255, 255, 255 },
    };
    const pass = renderer.beginPass(target).?;
    for (rows, 0..) |color, i| {
        pass.addRect(.{ .x = 0, .y = @floatFromInt(i), .width = 4, .height = 1 }, color);
    }
    pass.submit();

    const fb = try pixman_mod.Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();
    try target.readPixelsInto(fb);
    for (want, 0..) |expected, i| {
        const y: i32 = @intCast(i);
        std.testing.expectEqual(expected, fb.pixelAt(0, y)) catch |err| {
            std.debug.print("readback row {d}: composited {any}, expected {any}\n", .{
                y, fb.pixelAt(0, y), expected,
            });
            return err;
        };
        // The whole row, not just its first pixel.
        try std.testing.expectEqual(expected, fb.pixelAt(3, y));
    }
}

/// Four quadrant colours, each exactly representable: pure channels plus
/// an eighth / quarter / three-quarter triple (31.875, 63.75, 191.25),
/// so the float -> unorm8 conversion never lands on a tie.
const native_quads = [4][4]f32{
    .{ 1.0, 0.0, 0.0, 1.0 },  // red
    .{ 0.0, 1.0, 0.0, 1.0 },  // green
    .{ 0.0, 0.0, 1.0, 1.0 },  // blue
    .{ 0.125, 0.25, 0.75, 1.0 }, // asymmetric channel mixture
};
const native_quad_bytes = [4][4]u8{
    .{ 0, 0, 255, 255 }, .{ 0, 255, 0, 255 },
    .{ 255, 0, 0, 255 }, .{ 191, 64, 32, 255 },
};

fn drawNativeQuadrants(
    renderer: *renderer_mod.Renderer,
    target: *Gles2Target,
    size: i32,
    texture: ?*texture_mod.Texture,
) !void {
    const pass = renderer.beginPass(target) orelse return error.NoPass;
    if (texture) |tex| {
        // 1:1 over the whole target: the fragment centre of target pixel
        // (i, j) lands on the texel centre of the source's (i, j).
        pass.addTexture(tex, .{ .dst = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(size),
            .height = @floatFromInt(size),
        } });
    } else {
        const half: f64 = @floatFromInt(@divExact(size, 2));
        for (native_quads, 0..) |color, i| {
            pass.addRect(.{
                .x = @as(f64, @floatFromInt(i % 2)) * half,
                .y = @as(f64, @floatFromInt(i / 2)) * half,
                .width = half,
                .height = half,
            }, color);
        }
    }
    pass.submit();
}

fn expectNativeQuadrants(fb: *const pixman_mod.Framebuffer, size: i32) !void {
    const half: i32 = @divExact(size, 2);
    for (native_quad_bytes, 0..) |want, i| {
        const x: i32 = @as(i32, @intCast(i % 2)) * half;
        const y: i32 = @as(i32, @intCast(i / 2)) * half;
        std.testing.expectEqual(want, fb.pixelAt(x, y)) catch |err| {
            std.debug.print("native quadrant {d} at ({d}, {d}): read back {any}, expected {any}\n", .{
                i, x, y, fb.pixelAt(x, y), want,
            });
            return err;
        };
        // The whole quadrant, not just its first pixel.
        try std.testing.expectEqual(want, fb.pixelAt(x + half - 1, y + half - 1));
    }
}

// The real native GPU path, opt-in through
// `WAYLAND_GLES2_TEST_DRM_NODE` (a DRM node this process may open).
// Unset: skipped — there is no node to open, and pretending otherwise
// would report a hardware proof this run did not produce. Set: every
// step is required, and a device that cannot import AND render DMA-BUF
// FAILS the test instead of quietly passing as "no GPU".
//
// What only a real GPU can show:
//   1. GBM allocates a buffer in a (format, modifier) this renderer
//      PROVED at create() time, and `Device.import` turns it into a
//      compositor Buffer that exports its own descriptors — the
//      wl_buffer path, not a test double.
//   2. `Gles2Target.fromDmabuf` RENDERS INTO that buffer through a
//      native EGL image: the readback shows the quads the GPU wrote
//      into the client's memory, with no map or upload.
//   3. `importDmabuf` turns the SAME buffer into a source texture and a
//      second target draws it 1:1 — the pixels come back out of the
//      client's buffer through the native source path.
//   4. The buffer's plane descriptor survives the producer's
//      `destroy()` while the native texture holds it, and dies only
//      when that last texture is destroyed. Nothing dereferences the
//      buffer or its descriptors after that point.
test "gles2 native dmabuf render and source draw on a real GPU (opt-in)" {
    const env = std.c.getenv("WAYLAND_GLES2_TEST_DRM_NODE") orelse return error.SkipZigTest;
    const node = std.mem.span(env);
    lockGles2Test();
    defer unlockGles2Test();

    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{};
    const size: i32 = 4;

    const dev = try dmabuf.GbmDevice.create(allocator, node);
    defer dev.deinit();
    const renderer = try Gles2Renderer.createOnDevice(allocator, &io, &log_cfg, dev);
    defer renderer.destroy();

    // A renderer on a real device must have proved at least one pair it
    // can import AND render into; an empty set is a capability failure
    // now, not a skip.
    const pairs = Gles2Renderer.renderFormats(renderer);
    if (pairs.len == 0) return error.NoProvenNativeFormat;
    const pair = pairs[0];

    // A real GBM bo in the proven layout, exported and imported through
    // the same Device a wl_buffer takes. `import` consumes the
    // descriptors it is handed on every path, so the bo's export is never
    // closed here.
    const usage: u32 = gbm_c.GBM_BO_USE_SCANOUT | gbm_c.GBM_BO_USE_RENDERING;
    const bo = gbm_c.gbm_bo_create_with_modifiers2(
        dev.device,
        @intCast(size),
        @intCast(size),
        pair.format,
        &[_]u64{pair.modifier},
        1,
        usage,
    ) orelse return error.NativeAllocFailed;
    defer gbm_c.gbm_bo_destroy(bo);
    const plane_fd = gbm_c.gbm_bo_get_fd_for_plane(bo, 0);
    if (plane_fd < 0) return error.NativeNoPlaneFd;
    var attrs: dmabuf.Attributes = .{
        .width = size,
        .height = size,
        .format = pair.format,
        .modifier = pair.modifier,
        .n_planes = 1,
    };
    attrs.planes[0] = .{
        .fd = @intCast(plane_fd),
        .offset = gbm_c.gbm_bo_get_offset(bo, 0),
        .stride = gbm_c.gbm_bo_get_stride_for_plane(bo, 0),
    };

    var buf: ?*buffer_mod.Buffer = try dev.iface.import(allocator, attrs);
    defer if (buf) |b| b.destroy();
    const get_dmabuf = buf.?.impl.get_dmabuf orelse return error.NotADmabuf;
    const buf_attrs: *const dmabuf.Attributes = @ptrCast(@alignCast(get_dmabuf(buf.?) orelse return error.NotADmabuf));
    // The descriptor the WRAPPER owns, and the one its teardown closes.
    const tracked_fd = buf_attrs.planes[0].fd;
    try std.testing.expect(tracked_fd >= 0);

    // 1. Render into the client's buffer: the native FBO is an EGL image
    // over that buffer, so this is GPU memory being written in place.
    var native_target: ?*Gles2Target = try Gles2Target.fromDmabuf(allocator, renderer, buf_attrs);
    defer if (native_target) |t| t.destroy();
    try drawNativeQuadrants(renderer, native_target.?, size, null);
    {
        const fb = try readTarget(allocator, native_target.?);
        defer fb.deinit();
        try expectNativeQuadrants(fb, size);
    }
    // The target's EGL image has served its purpose; drop it before the
    // descriptor bookkeeping below, which must see only the texture.
    native_target.?.destroy();
    native_target = null;

    // 2. The same buffer as a SOURCE texture, drawn 1:1 into a second
    // (renderer-owned) target. The quads reappear from the client's
    // memory — nothing on this path maps, uploads or copies.
    var tex: ?*texture_mod.Texture = try Gles2Renderer.importDmabuf(renderer, buf.?);
    defer if (tex) |t| t.destroy();
    try std.testing.expectEqual(@as(u32, 1), buf.?.n_locks);
    const target = try Gles2Target.create(allocator, renderer, size, size);
    defer target.destroy();
    try drawNativeQuadrants(renderer, target, size, tex.?);
    {
        const fb = try readTarget(allocator, target);
        defer fb.deinit();
        try expectNativeQuadrants(fb, size);
    }

    // 3. The producer is gone; the texture still holds the buffer, so
    // its descriptor must still be open and its memory still readable by
    // the GPU. `buf` and `buf_attrs` are dead from here on — nothing
    // below may dereference them.
    buf.?.destroy();
    buf = null;
    try std.testing.expectEqual(
        std.os.linux.E.SUCCESS,
        std.os.linux.errno(std.os.linux.fcntl(tracked_fd, std.os.linux.F.GETFD, 0)),
    );
    try drawNativeQuadrants(renderer, target, size, tex.?);
    {
        const fb = try readTarget(allocator, target);
        defer fb.deinit();
        try expectNativeQuadrants(fb, size);
    }

    // 4. Releasing the last native texture drops the lock, the buffer's
    // teardown runs and closes that descriptor: now, and only now, it is
    // gone.
    tex.?.destroy();
    tex = null;
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        std.os.linux.errno(std.os.linux.fcntl(tracked_fd, std.os.linux.F.GETFD, 0)),
    );
}

test "gles2 scene rectangles retain distant fractional placement" {
    lockGles2Test();
    defer unlockGles2Test();
    const scene_mod = @import("../scene/scene.zig");
    const backend_mod = @import("../backend/backend.zig");
    const output_mod = @import("../output/output.zig");
    const camera_mod = @import("../scene/camera.zig");
    const fixture = struct {
        fn start(_: *backend_mod.Backend) error{BackendFailed}!void {}
        fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
        fn testState(_: *output_mod.Output, _: *const output_mod.Output.State) error{InvalidState}!void {}
        fn commit(_: *output_mod.Output, _: *const output_mod.Output.State) error{CommitFailed}!void {}
    };
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    var marker: u8 = 0;
    const scene = try scene_mod.Scene.init(allocator, &io, &log_cfg);
    defer scene.deinit();
    const backend = try backend_mod.Backend.init(allocator, &io, &log_cfg, &.{
        .start = fixture.start, .destroy = fixture.destroy,
    }, &marker);
    defer backend.destroy();
    const output = try output_mod.Output.create(allocator, &io, &log_cfg, backend, &.{
        .@"test" = fixture.testState, .commit = fixture.commit, .destroy = fixture.destroy,
    }, &marker, .{ .width = 4, .height = 4, .refresh_msec = 16 });
    defer output.destroy();
    const view = try scene_mod.SceneOutput.create(allocator, &io, &log_cfg, scene, output);
    defer view.destroy();
    const base: f64 = 0x1p40;
    const camera: camera_mod.Camera = .{
        .center_x = base + 2, .center_y = -base + 2, .zoom = 1, .rotation = 0,
        .screen_w = 4, .screen_h = 4,
    };
    view.camera = &camera;
    const node = try scene_mod.SceneNode.create(allocator, scene.root, .rect);
    node.kind.rect.width = 2;
    node.kind.rect.height = 2;
    node.kind.rect.color = .{ 1, 0, 0, 1 };
    node.setPosition(base + 0.25, -base + 0.25);
    const renderer = try Gles2Renderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();
    const target = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target.destroy();
    Gles2Renderer.setTransform(renderer, Affine.translate(-base, base));
    view.render(renderer, target);
    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    for (0..4) |y| {
        for (0..4) |x| {
            const want: [4]u8 = if (x < 2 and y < 2) .{ 0, 0, 255, 255 } else .{ 0, 0, 0, 0 };
            try std.testing.expectEqual(want, fb.pixelAt(@intCast(x), @intCast(y)));
        }
    }
}

test "a pass preserves its starting transform when a later draw changes it" {
    lockGles2Test();
    defer unlockGles2Test();
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    const renderer = Gles2Renderer.create(allocator, &io, &log_cfg) catch
        return error.SkipZigTest;
    defer renderer.destroy();
    const target = try Gles2Target.create(allocator, renderer, 4, 4);
    defer target.destroy();
    Gles2Renderer.setTransform(renderer, Affine.translate(2, 0));
    const pass = renderer.beginPass(target).?;
    pass.addRect(.{ .x = 0, .y = 0, .width = 2, .height = 4 }, .{ 1, 0, 0, 1 });
    Gles2Renderer.setTransform(renderer, .identity);
    pass.addRect(.{ .x = 0, .y = 0, .width = 2, .height = 4 }, .{ 0, 0, 1, 1 });
    pass.submit();
    const fb = try readTarget(allocator, target);
    defer fb.deinit();
    for (0..4) |y| {
        for (0..4) |x| {
            const want: [4]u8 = if (x < 2) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
            try std.testing.expectEqual(want, fb.pixelAt(@intCast(x), @intCast(y)));
        }
    }
}

test "the native present barrier reports a real EGL bind failure" {
    lockGles2Test();
    defer unlockGles2Test();
    const allocator = std.testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log_mod.Config = .{ .min_level = .err };
    const renderer = Gles2Renderer.create(allocator, &io, &log_cfg) catch
        return error.SkipZigTest;
    defer renderer.destroy();
    const data: *Gles2Data = @ptrCast(@alignCast(renderer.data));
    const display = data.dpy;
    try std.testing.expect(c.eglMakeCurrent(display, null, null, null) == c.EGL_TRUE);
    data.dpy = null;
    defer data.dpy = display;
    try std.testing.expectError(error.NoCurrentContext, Gles2Renderer.finishRendering(renderer));
}