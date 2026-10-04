//! Render pass abstraction (wlr_render_pass pattern).
//!
//! A Pass collects draw operations targeting one framebuffer; submit()
//! flushes them. Passes apply eagerly in the CPU renderer (see pixman.zig)
//! and at submit in the GLES2 renderer.
//!
//! # Texture geometry
//! `TextureOptions` is the whole sampling contract of one draw:
//! - `dst` is a SCENE-space rectangle (f64 pixels, y down, top-left
//!   origin) — the space `Gles2Renderer.setTransform` maps to the target.
//! - `src` is a RAW BUFFER-pixel crop (null = the whole texture). A
//!   wp_viewport source is surface-local, so the caller multiplies it by
//!   `wl_surface.buffer_scale` and inverse-transforms it into raw buffer
//!   pixels before passing it; the crop is applied exactly once.
//! - `transform` is the surface's `wl_output.transform` (buffer ->
//!   surface). Destination-normalized coordinates are mapped to
//!   source-normalized coordinates through its INVERSE, so all eight
//!   standard transforms are expressible by any backend.
//!
//! # One sampling contract
//! Every backend resolves a draw the same way, the GPU's way: a
//! destination pixel is sampled at its CENTRE, and texel `i` occupies
//! `[i, i + 1)` with its centre at `i + 0.5`. A 1:1 stamp at an integer
//! dst is therefore texel-exact in every backend, and a scaled,
//! cropped, transformed or fractional draw lands on the same texel on
//! the GPU and on the CPU (pixman.TexelMap, and its module docs for the
//! frame those coordinates live in).
//!
//! # Crop edges
//! A crop is a window, and the filter may not read past it: every
//! backend clamps the sample to the crop (gles2.zig at the crop's
//! texel-centre bounds, pixman.zig in `sampleTexelPosition`), so a
//! magnified crop repeats its own edge texel instead of fading in a
//! neighbour the crop never named. Sampling the whole texture (src ==
//! null) is the degenerate case, and there the rule coincides with the
//! sampler's own edge clamping.
//!
//! Imports: utils/geom.zig, renderer/texture.zig.

const geom = @import("../utils/geom.zig");
const texture_mod = @import("texture.zig");

pub const Pass = struct {
    impl: *const Impl,
    data: *anyopaque,
    /// Clear the target before drawing the queued operations. GLES2
    /// targets hold undefined bytes between passes, so their passes
    /// clear by default; set this to false for a pass that draws OVER an
    /// already rendered frame (the screen-space cursor over a composited
    /// base), where a clear would erase it. The CPU renderer never clears
    /// (its framebuffer persists) and ignores the flag.
    clear: bool = true,

    /// One textured draw. See the module docs for the geometry.
    pub const TextureOptions = struct {
        /// Raw buffer-pixel crop; null = the whole texture.
        src: ?geom.FRect = null,
        /// Destination rect in scene pixels.
        dst: geom.FRect,
        /// Straight-alpha opacity in [0, 1].
        alpha: f32 = 1,
        /// wl_output.transform of the source buffer (buffer -> surface).
        transform: geom.Transform = .normal,
    };

    pub const Impl = struct {
        /// Draw `texture` into `options.dst`, sampling `options.src`
        /// (null = whole texture) through `options.transform` at
        /// `options.alpha` straight-alpha opacity.
        add_texture: *const fn (
            pass: *Pass,
            texture: *texture_mod.Texture,
            options: TextureOptions,
        ) void,
        /// Fill a scene-space f64 rectangle with straight-alpha RGBA.
        /// Coverage follows destination pixel centres, like textures.
        add_rect: *const fn (pass: *Pass, rect: geom.FRect, color: [4]f32) void,
        /// Flush all queued draw operations.
        submit: *const fn (pass: *Pass) void,
    };

    pub fn addTexture(pass: *Pass, texture: *texture_mod.Texture, options: TextureOptions) void {
        pass.impl.add_texture(pass, texture, options);
    }

    pub fn addRect(pass: *Pass, rect: geom.FRect, color: [4]f32) void {
        pass.impl.add_rect(pass, rect, color);
    }

    pub fn submit(pass: *Pass) void {
        pass.impl.submit(pass);
    }
};

