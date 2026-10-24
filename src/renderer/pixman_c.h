// Real pixman library shim (pixman-0.46.4): the SIMD-optimized software
// compositor weston/wlroots use for scaled/blended surface compositing
// (pixman_image_composite32). The M4 canvas pass hand-rolled its own
// per-pixel f64 bilinear rasterizer (~545ms for the full output in the VM);
// this shim exposes pixman's optimized composite to replace it (see
// weston's pixman-renderer.c).
#include <pixman.h>
