// GLES2/EGL shim header for translate-c: the gles2 renderer
// (src/renderer/gles2.zig) imports the translated bindings as "gles2_c"
// (wired in build.zig like pixman_c/drm_c/raylib_c). Keeping the C
// surface to these includes keeps translate-c fast and the imported
// namespace stable across libglvnd versions.
//
// EGL_NO_X11 forces the generic EGLNativeDisplayType (void*): the
// renderer is headless and must not drag in X11 headers, and `null` is
// then the EGL_DEFAULT_DISPLAY value.
//
// eglext.h is what supplies every token and function the GPU data path
// uses, and it is the ONLY source for them. Nothing here may define an
// EGL token of its own:
//
//   - EGL_EXT_image_dma_buf_import (eglext.h:761-785) supplies the import
//     target EGL_LINUX_DMA_BUF_EXT (0x3270), EGL_LINUX_DRM_FOURCC_EXT and
//     the per-plane EGL_DMA_BUF_PLANE{0,1,2}_{FD,OFFSET,PITCH}_EXT.
//   - EGL_EXT_image_dma_buf_import_modifiers (eglext.h:787-806) adds plane
//     3 and the per-plane EGL_DMA_BUF_PLANE{0..3}_MODIFIER_{LO,HI}_EXT.
//   - EGL_MESA_platform_surfaceless (eglext.h:1092-1095) supplies
//     EGL_PLATFORM_SURFACELESS_MESA (0x31DD); EGL_EXT_device_base
//     (eglext.h:888) supplies EGL_PLATFORM_DEVICE_EXT (0x313F).
//
// There is deliberately NO local #define for any of those. An earlier
// revision of this file defined a made-up EGL_IMAGE_FORMAT_FD and a
// fallback EGL_PLATFORM_SURFACELESS_MESA with the wrong value; both are
// gone, because a header that invents tokens hides the real API instead
// of exposing it. The import path uses the registry's own attribute list
// (EGL_WIDTH / EGL_HEIGHT / fourcc + per-plane fd/offset/pitch), which
// needs no such token.
//
// GL_GLEXT_PROTOTYPES brings in GL_OES_EGL_image's
// glEGLImageTargetTexture2DOES, which turns an EGLImage into a samplable
// GL_TEXTURE_2D — the second half of the DMA-BUF import. Without it the
// renderer's GPU data path has no C surface at all.
#define EGL_NO_X11 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#define GL_GLEXT_PROTOTYPES 1
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
