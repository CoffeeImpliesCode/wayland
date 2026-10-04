// Shim header for translate-c: the DRM/KMS backend
// (src/backend/drm.zig) imports the translated bindings as "drm_c"
// (wired in build.zig: pkg-config --cflags --libs libdrm provides the
// include paths and the link line, mirroring the raylib_c pattern in
// src/server/). Keeping the C surface to these five includes keeps
// translate-c fast and the imported namespace stable across libdrm
// versions.
//
// The API used from drm.zig (documented contract):
//   enumeration   drmModeGetResources/Connector/Encoder/Crtc/Plane* +
//                 drmModeGetPlaneResources;
//                 drmModeGetProperty/ObjectGetProperties + Free* pairs
//   properties    drmModeCreatePropertyBlob/DestroyPropertyBlob/
//                 GetPropertyBlob (the primary plane's IN_FORMATS blob,
//                 which is where a plane's real (format, modifier) list
//                 comes from)
//   atomic        drmModeAtomicAlloc/Free/AddProperty/Commit
//   event         drmHandleEvent + drmEventContext (page_flip_handler2)
//   caps          drmSetClientCap (DRM_CLIENT_CAP_ATOMIC)
//   ioctl         drmIoctl (DRM_IOCTL_MODE_CREATE_DUMB / MAP_DUMB /
//                 DESTROY_DUMB / ADDFB2 / SET_MASTER / DROP_MASTER)
//   fourcc        DRM_FORMAT_XRGB8888 (drm_fourcc.h)
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm.h>
#include <drm_mode.h>
#include <drm_fourcc.h>
