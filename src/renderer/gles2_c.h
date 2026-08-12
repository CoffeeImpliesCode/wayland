// GLES2/EGL shim header for translate-c: the gles2 renderer
// (src/renderer/gles2.zig) imports the translated bindings as "gles2_c"
// (wired in build.zig like pixman_c/drm_c/raylib_c). Keeping the C
// surface to these two includes keeps translate-c fast and the imported
// namespace stable across libglvnd versions.
//
// EGL_NO_X11 forces the generic EGLNativeDisplayType (void*): the
// renderer is headless and must not drag in X11 headers, and `null` is
// then the EGL_DEFAULT_DISPLAY value. EGL_PLATFORM_SURFACELESS_MESA is
// defined defensively (eglmesaext.h may or may not be pulled in by
// egl.h); eglGetPlatformDisplay needs it for headless surfaceless
// rendering on Mesa's software (llvmpipe) driver.
#define EGL_NO_X11 1
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DA
#endif
