# Renderer — wlroots/smithay diff

Scope: `src/renderer/{renderer,pass,texture,pixman}.zig` vs wlroots 0.20.2 (`render/wlr_renderer.c`, `render/wlr_texture.c`, `render/pass.c`, `render/pixman/*`, `include/wlr/render/{wlr_renderer.h,wlr_texture.h,pass.h,interface.h}`) and smithay v0.7.0 (`src/backend/renderer/mod.rs`, `src/backend/renderer/pixman/mod.rs`, `src/backend/renderer/color.rs`). All citations file:line relative to each repo root. INFERENCE marks resolved 2026-08-09 (see VERIFIED notes inline).

## Surface

Our public surface (grep `pub const`/`pub fn`):

**renderer.zig**
- `pub const Renderer` (13) — vtable dispatch struct: `impl`/`data`/`allocator`/`io`/`log_cfg`/`formats`
- `Renderer.Impl` (23) — vtable: `begin_pass`, `destroy`
- `Renderer.create` (30), `Renderer.beginPass` (50), `Renderer.destroy` (54)

**pass.zig**
- `pub const Pass` (13) — vtable dispatch struct: `impl`/`data`
- `Pass.Impl` (17) — vtable: `add_texture`, `add_rect`, `submit`
- `Pass.addTexture` (33), `Pass.addRect` (37), `Pass.submit` (41)

**texture.zig**
- `pub const Texture` (11) — `impl`/`data`/`width`/`height`
- `Texture.Impl` (17) — vtable: `destroy` only
- `Texture.destroy` (23)

**pixman.zig** (pixman CPU renderer)
- `pub const format_argb8888` (18)
- `pub const Framebuffer` (21) — in-memory ARGB8888 target: `create` (30), `deinit` (48), `fill` (55), `pixelAt` (66)
- `pub const PixmanRenderer` (105) — `create` (106), `importMemory` (120), `updateMemory` (149)
- private impl fns (invoked through the vtables): `beginPass` (165), `destroyRenderer` (172), `destroyTexture` (177), `addTexture` (185), `addRect` (218), `blendPixel` (247), `submitPass` (262)

## Comparison

### renderer.zig

| Our fn (file:line) | Semantics (ours) | wlroots equivalent | smithay equivalent | Verdict | Note |
|---|---|---|---|---|---|
| `Renderer` (renderer.zig:13) | vtable struct: impl, opaque data, allocator/io/log, `formats: []const u32` | `struct wlr_renderer` (include/wlr/render/wlr_renderer.h:28) — impl + `render_buffer_caps` + `features` (timeline, output_color_transform) | `RendererSuper` trait (mod.rs:385) + `Renderer` trait (mod.rs:402) with assoc Error/TextureId/Framebuffer/Frame | close | wlroots carries buffer caps + feature flags; ours carries a bare format-code list. smithay carries full type-level contract |
| `Renderer.Impl` (renderer.zig:23) | 2 slots: begin_pass, destroy | `struct wlr_renderer_impl` (include/wlr/render/interface.h:26) — 7 slots: get_texture_formats, get_render_formats, destroy, get_drm_fd, texture_from_buffer, begin_buffer_pass, render_timer_create | no vtable; methods on trait objects | close | ours has 2 of 7 wlroots slots; no texture_from_buffer, no formats query, no drm fd, no render timer |
| `Renderer.create` (30) | allocate struct + set fields | `wlr_renderer_init` (render/wlr_renderer.c:31) — sets impl/caps, inits `destroy` + `lost` signals, asserts non-empty caps | `PixmanRenderer::new` (pixman/mod.rs:714) | close | wlroots inits two wl_signal events; ours has no events at all |
| `Renderer.beginPass` (50) | vtable dispatch; null when target unsupported | `wlr_renderer_begin_buffer_pass` (render/wlr_renderer.c:307) — passes `wlr_buffer` + `wlr_buffer_pass_options` (timer, color_transform, signal timeline; include/wlr/render/pass.h:33) | `Bind::bind` (mod.rs:216) target→Framebuffer, then `Renderer::render` (mod.rs:427) framebuffer→Frame | close | ours takes a bare `*anyopaque` target with no options; smithay splits bind vs render into two phases |
| `Renderer.destroy` (54) | impl destroy then free struct | `wlr_renderer_destroy` (render/wlr_renderer.c:46) — emits `destroy` signal, asserts listener lists empty, then impl destroy | N/A — Rust ownership/Drop | close | ours has no destroy/lost signals; no lost-renderer recovery path |

### pass.zig

| Our fn (file:line) | Semantics (ours) | wlroots equivalent | smithay equivalent | Verdict | Note |
|---|---|---|---|---|---|
| `Pass` (pass.zig:13) | vtable struct for one framebuffer's draw ops | `struct wlr_render_pass` (include/wlr/render/interface.h:90), init via `wlr_render_pass_init` (render/pass.c:5) | `Frame` trait (mod.rs:270) | close | concept equal; smithay name is Frame |
| `Pass.Impl` (17) | 3 slots: add_texture, add_rect, submit | `struct wlr_render_pass_impl` (include/wlr/render/interface.h:96) — same 3 | Frame methods: clear (mod.rs:286), draw_solid (289), render_texture_at (300), render_texture_from_to (332), wait (352), finish (362) | close | smithay has no submit; finish returns a SyncPoint; ours has no clear/wait |
| `Pass.addTexture` (33) | src crop (null=whole), dst rect, straight-alpha opacity f32 | `wlr_render_pass_add_texture` (render/pass.c:17) with `wlr_render_texture_options` (include/wlr/render/pass.h:80): src_box, dst_box, alpha ptr, clip region, transform, filter, blend mode, transfer function, primaries, color encoding/range, luminance, wait timeline | `Frame::render_texture_from_to` (mod.rs:332) — src/dst rect, damage, opaque_regions, src_transform, alpha | close | signature matches src/dst/alpha; semantics diverge in the impl (below) |
| `Pass.addRect` (37) | rect + straight-alpha RGBA color | `wlr_render_pass_add_rect` (render/pass.c:31); `wlr_render_color` is PREMULTIPLIED (include/wlr/render/pass.h:135-137) | `Frame::draw_solid` (mod.rs:289); `Color32F` is premultiplied (color.rs:3) | **divergent** | color convention: ours straight, theirs premultiplied (see Gaps 6) |
| `Pass.submit` (41) | flush draw ops | `wlr_render_pass_submit` (render/pass.c:13) — returns bool; pass unusable after; pixman impl unlocks target + ends data access (render/pixman/pass.c:19-24) | `Frame::finish` (mod.rs:362) — returns SyncPoint; Drop also finishes (pixman/mod.rs:686) | **divergent** | ours is a trace-only no-op (pass.zig:8-10 M1 eager design); no resource release, no sync point |

### texture.zig

| Our fn (file:line) | Semantics (ours) | wlroots equivalent | smithay equivalent | Verdict | Note |
|---|---|---|---|---|---|
| `Texture` (texture.zig:11) | impl/data/width/height | `struct wlr_texture` (include/wlr/render/wlr_texture.h:24) — impl, width, height u32, `renderer` backref | `Texture` trait (mod.rs:233) — width()/height()/format()/size() | close | ours lacks renderer backref and format query; i32 vs u32 dims |
| `Texture.Impl` (17) | destroy only | `struct wlr_texture_impl` (include/wlr/render/interface.h:61) — update_from_buffer, read_pixels, preferred_read_format, destroy | trait-based; format() (mod.rs:233-246) | **divergent** | ours has no read_pixels, no preferred_read_format, no update_from_buffer slot |
| `Texture.destroy` (23) | vtable destroy | `wlr_texture_destroy` (wlr_texture.c:23) — impl destroy or free | no destroy; refcounted Arc handle (pixman/mod.rs:145) | close | smithay textures are cloneable handles; ours single-owner |

### pixman.zig

| Our fn (file:line) | Semantics (ours) | wlroots equivalent | smithay equivalent | Verdict | Note |
|---|---|---|---|---|---|
| `format_argb8888` (18) | wl_shm code 0, the only supported format | `DRM_FORMAT_ARGB8888` ↔ `PIXMAN_a8r8g8b8` entry (render/pixman/pixel_format.c:13) | `DrmFourcc::Argb8888` in SUPPORTED_FORMATS (pixman/mod.rs:47) | same | ours supports 1 of 13 wlroots / 13 smithay formats (Gaps 12) |
| `Framebuffer` (21) + `create` (30) | own in-memory ARGB8888 buffer, zeroed via `@memset` (36), stride = w*4 | no framebuffer type; renders into `wlr_buffer` through `wlr_pixman_buffer` wrapper (include/render/pixman.h:24) | `PixmanTarget` (pixman/mod.rs:72) wraps Dmabuf or `pixman::Image`; `Offscreen::create_buffer` (mod.rs:454, impl 1255) | **divergent** | ours is a private test-target, no buffer abstraction, no dmabuf target |
| `Framebuffer.deinit` (48) | free data + struct | N/A — buffer lifetime managed by wl_buffer refcounts (wlr_buffer_lock/unlock) | N/A — Rust Drop | ours-only | target lifetime in ours is plain allocator ownership (Gaps 1) |
| `Framebuffer.fill` (55), `pixelAt` (66) | test helpers | `pixman_image_create_solid_fill` + `composite32` (render/pixman/pass.c:215-225); read via `wlr_texture_read_pixels` (wlr_texture.c:56) | `ExportMem::map_texture` (pixman/mod.rs:1086) | ours-only | no production read-back in ours (Gaps 7) |
| `PixmanRenderer` (105) + `create` (106) | alloc PixmanData; advertises `{format_argb8888}` | `wlr_pixman_renderer_create` (render/pixman/renderer.c:322) — drm_format_set of 13 formats x {INVALID, LINEAR} mods, caps WLR_BUFFER_CAP_DATA_PTR (renderer.c:328-335) | `PixmanRenderer::new` (pixman/mod.rs:714) — filter/debug state + caches | close | ours advertises one format; no caps concept |
| `importMemory` (120) | copy pixels into renderer-owned memory | `wlr_texture_from_pixels` (wlr_texture.c:73) wraps data in `readonly_data_buffer`, then `pixman_texture_from_buffer` (renderer.c:244) — pixman wraps the CALLER's data pointer, no copy; buffer locked | `ImportMem::import_memory` (mod.rs:515; impl 897) — copies into a new pixman Image via copy_nonoverlapping (mod.rs:913) | close | copy semantics match smithay; wlroots pixman zero-copies + locks. Ours has no lock (Gaps 1) |
| `updateMemory` (149) | in-place full overwrite when w/h/stride match; else false | N/A — wlroots pixman texture_impl has no update_from_buffer (render/pixman/renderer.c:107-113); `wlr_texture_update_from_buffer` returns false (wlr_texture.c:122-123); re-import required | `ImportMem::update_memory` (mod.rs:537; impl 930) — region update via `composite32` SRC (pixman/mod.rs:970-981) | ours-only vs wlroots; close vs smithay | ours is a superset of wlroots pixman but full-buffer only; smithay updates a sub-region |
| `beginPass` (165) | stash target pointer into pass_data, return pass | `pixman_begin_buffer_pass` (renderer.c:295) — get/create `wlr_pixman_buffer`, then `begin_pixman_render_pass` (render/pixman/pass.c:235) = begin_data_ptr_access READ\|WRITE + `wlr_buffer_lock` | `Renderer::render` (pixman/mod.rs:857) — dmabuf sync START READ\|WRITE (mod.rs:862-869); `Bind::bind` (1212) | **divergent** | ours does NO locking, NO data-ptr access, NO dmabuf sync (Gaps 1) |
| `destroyRenderer` (172) | free PixmanData only | `pixman_destroy` (renderer.c:277) — walks and destroys all cached buffers + textures, finishes format set | Drop of renderer caches | **divergent** | ours leaks any live textures; wlroots force-destroys them |
| `destroyTexture` (177) | free pixels, tex_data, struct | `texture_destroy` (renderer.c:83) — pixman_image_unref, wlr_buffer_unlock, free data | Arc drop (pixman/mod.rs:145) | close | |
| `addTexture` (185) | 1:1 row `@memcpy` (214); skips with warning on scaling/crop/transform (196-201); `_ = alpha` (191) | `render_pass_add_texture` (render/pixman/pass.c:39) — blend op select (29-37), clip region, src box rounding, full pixman transform pipeline for scale/rotate/flip (pass.c:95-144), alpha mask solid fill, `pixman_image_composite32` OVER/SRC (pass.c:129-156) | `render_texture_from_to` (pixman/mod.rs:395) — transform composition (486-590), clip region (582-594), filter (596-601), OVER if format has alpha else SRC (605-607), alpha mask (609-613), `composite32` (616-630) | **divergent** | ours overwrites dst with raw rows; theirs composite with OVER + alpha mask. No blending, no alpha, no scaling/crop/transform/filter/clip in ours (Gaps 2,3,4) |
| `addRect` (218) | per-pixel scalar blend loop, straight-alpha | `render_pass_add_rect` (render/pixman/pass.c:202) — solid fill + `composite32`, SRC when color.a==1 else OVER (pass.c:207-208) | `draw_solid` (pixman/mod.rs:380) — SRC when opaque else OVER (387-389), clip to damage, `composite32` (331) | close math, divergent convention | blend math matches for straight inputs, but ours takes straight while both take premultiplied (Gaps 6); perf scalar vs pixman SIMD (Gaps 10) |
| `blendPixel` (247) | dst = src*a + dst*(255-a) +127 over 255; fast paths a==255/0 (249-253) | inside pixman `composite32` OVER (pass.c:129-156) — pixman's SIMD `over_8888_8888` | `Operation::Over` composite32 (mod.rs:616) | close | same rounding formula; pixman OVER expects premultiplied source, ours feeds straight alpha |
| `submitPass` (262) | trace no-op | `render_pass_submit` (render/pixman/pass.c:19) — end_data_ptr_access + wlr_buffer_unlock + free pass; returns true | `finish_internal` (pixman/mod.rs:668) — dmabuf sync END READ\|WRITE, returns signaled SyncPoint | **divergent** | eager apply (pass.zig:8-10) makes submit meaningless; no resource release, no sync (Gaps 8) |

## Gaps

Behaviors wlroots/smithay have that we lack:

1. **No buffer locking/refcount/lifetime protocol**: wlroots locks the target for the pass duration (`wlr_buffer_lock` in begin_pixman_render_pass, render/pixman/pass.c:245-249; unlock in submit pass.c:22-23) and re-creates its pixman image when the shm pool is resized (renderer.c:26-60). smithay syncs dmabuf planes at render start (pixman/mod.rs:862-869) and guards shm-buffer SIGPIPE with `with_buffer_contents` (pixman/mod.rs:190-200). Ours stores a raw `*anyopaque` target (pixman.zig:165-170) with zero protection — destroying a target mid-pass is a use-after-free.
2. **Alpha compositing of textures**: our `addTexture` memcpys rows and ignores both the texture's alpha channel and the `alpha` argument (pixman.zig:191,214). wlroots composites `PIXMAN_OP_OVER` with an alpha mask (render/pixman/pass.c:129-156); smithay picks OVER/SRC by format alpha and applies the mask (pixman/mod.rs:605-628). Partial-alpha textures (shadows, rounded corners, cursors) render wrong: dst is replaced, not blended.
3. **No scaling/cropping/transform/filter**: ours warns and skips the draw when src isn't whole or dst size differs (pixman.zig:196-201). wlroots implements the full pixman transform pipeline (rotate/flip/scale, bilinear/nearest) (render/pixman/pass.c:95-144); smithay likewise (pixman/mod.rs:486-590).
4. **No clip region / damage clipping**: `wlr_render_texture_options.clip` (include/wlr/render/pass.h:88) applied via `pixman_image_set_clip_region32` (render/pixman/pass.c:52); smithay clips to output + damage rects (pixman/mod.rs:582-594). Our Pass API has no clip parameter.
5. **No color management**: transfer function, primaries, color encoding/range, luminance multiplier (include/wlr/render/pass.h:95-107) and buffer-pass color_transform (pass.h:36-39) are absent. VERIFIED 2026-08-09: wlroots pixman disables output_color_transform (`features.output_color_transform = false`, render/pixman/renderer.c:328-330) — the pixman renderer itself does no color management, matching ours; smithay's color pipeline lives in the gles renderer (color.rs:3). Our renderer has no color concept at all.
6. **Premultiplied vs straight color convention**: wlroots `wlr_render_color` is premultiplied (include/wlr/render/pass.h:135-137); smithay `Color32F` is premultiplied (color.rs:3). Our `addRect`/`blendPixel` (pixman.zig:218,247) expect straight alpha. A caller that feeds premultiplied colors (as wlroots/smithay callers do) double-multiplies through our blend.
7. **No texture read-back**: wlroots `wlr_texture_read_pixels` (wlr_texture.c:56) with pixman impl (renderer.c:92) and `preferred_read_format` (wlr_texture.c:65); smithay `ExportMem` copy_framebuffer/copy_texture/map_texture (mod.rs:734; pixman impl 1012-1097). Ours only has the `pixelAt` test helper (pixman.zig:66).
8. **No render timing or sync**: `wlr_render_timer_create` (render/wlr_renderer.c:317) and signal/wait timelines in pass options (pass.h:41-47,110-116); smithay `SyncPoint` + `Frame::wait`/`finish` (mod.rs:352,362). Ours: nothing; submit returns void.
9. **No formats query API**: wlroots `wlr_renderer_get_texture_formats`/`get_render_formats` (render/wlr_renderer.c:63,68); smithay `supported_formats` (mod.rs:224), `mem_formats` (mod.rs:498), `dmabuf_formats` (mod.rs:664). Ours stores a static `formats` slice at create time (renderer.zig:19, pixman.zig:106-117) — wl_shm negotiation would need the query [VERIFIED 2026-08-09: both wlroots getters exist (wlr_renderer.c:63-68); the gap is API shape only — ours is fixed at create].
10. **Performance: scalar loops vs pixman SIMD**: our `addRect`/`blendPixel` are per-pixel Zig loops (pixman.zig:218-260); wlroots and smithay delegate to `pixman_image_composite32`, pixman's SIMD-optimized C (SSE2/NEON fast paths). Our `addTexture` 1:1 memcpy (pixman.zig:214) is fast but semantically wrong (Gaps 2). The create-time `@memset` zero-fill (pixman.zig:36) covers clear-to-transparent cheaply — a minor advantage, not a substitute for compositing.
11. **No DMA-BUF import/rendering**: wlroots pixman renders any `wlr_buffer` incl. dmabuf via data-ptr access (renderer.c:26-60,244-275); smithay imports dmabufs with plane sync (pixman/mod.rs:743-799,1176-1208). Ours: CPU memory only.
12. **Single pixel format**: ours advertises only ARGB8888 (pixman.zig:18); wlroots supports 13 formats (render/pixman/pixel_format.c:11-105), smithay 13 (pixman/mod.rs:44-62). RGB565, 10-bit, 16-bit formats unsupported.
13. **Eager vs deferred execution**: our ops apply at add-time and submit is a no-op (pass.zig:8-10, pixman.zig:262-265); wlroots accumulates ops until submit, which also releases the target lock (pass.c:19-24). Behaviorally equivalent for a CPU renderer, but the eager model cannot batch, cannot fail, and blocks the M2 GPU renderer path by design.

## Verdict

- Interface parity: high. The vtable renderer/pass/texture pattern (renderer.zig:13, pass.zig:13, texture.zig:11) mirrors wlroots' impl/struct split, and the traits map 1:1 to smithay's Renderer/Frame/Texture.
- Behavioral parity: only for 1:1 opaque blits and opaque rect fills. The pixman backend is an M1 subset: one format, no buffer protocol, no alpha on textures, no scaling/crop/transform/clip.
- Riskiest divergences: (1) `addTexture` raw memcpy drops texture alpha and the alpha parameter — silently wrong output for any partial-alpha texture; (2) straight- vs premultiplied color convention (pixman.zig:247 vs pass.h:137, color.rs:3); (3) no buffer locking/refcount — a lifetime landmine once targets outlive the pass; (4) scalar blend loops vs pixman SIMD composite32.
- Ours-only strengths: in-place `updateMemory` (wlroots pixman has none) and zero-copy-free import semantics matching smithay.
- Overall: acceptable as a reference implementation for a headless/test compositor; it must not back a real output path before alpha compositing, buffer locking, and scaling are implemented.
