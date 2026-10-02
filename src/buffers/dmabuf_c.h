// Shim header for translate-c: the DMA-BUF import path
// (src/buffers/dmabuf.zig) and the GBM device it is built on
// (src/backend/drm.zig) import the translated bindings as "gbm_c"
// (wired in build.zig like pixman_c/drm_c/gles2_c/raylib_c: the
// mesa-libgbm include dir and lib dir are passed as raw -I/-L, because
// nixpkgs#mesa-libgbm ships a gbm.pc but no devenv package propagates it
// onto PKG_CONFIG_PATH, so `pkg-config --cflags gbm` finds nothing).
// Keeping the C surface to this single include keeps translate-c fast and
// the imported namespace stable across mesa versions.
//
// The API used (documented contract):
//   device   gbm_create_device / gbm_device_get_backend_name /
//            gbm_device_destroy / gbm_device_get_fd /
//            gbm_device_is_format_supported /
//            gbm_device_get_format_modifier_plane_count
//   import   gbm_bo_import + struct gbm_import_fd_modifier_data
//            (GBM_BO_IMPORT_FD_MODIFIER)
//   bo       gbm_bo_destroy / gbm_bo_get_plane_count /
//            gbm_bo_get_width / gbm_bo_get_height / gbm_bo_get_format /
//            gbm_bo_get_modifier / gbm_bo_get_fd_for_plane /
//            gbm_bo_get_offset / gbm_bo_get_stride_for_plane /
//            gbm_bo_set_user_data / gbm_bo_get_user_data
//   usage    GBM_BO_USE_SCANOUT / GBM_BO_USE_RENDERING
//
// drm_fourcc.h is deliberately NOT included here: the fourccs the
// compositor needs are hard-coded next to their DRM_FORMAT_* names in
// Zig (same house pattern as drm_format_xrgb8888 in backend/drm.zig), so
// this shim needs no libdrm include path of its own.
#include <gbm.h>

// std.posix/std.os.linux have no fstat in Zig 0.16 (buffers/dmabuf.zig
// needs dev_t of the node for the v4+ feedback main_device event).
#include <sys/stat.h>