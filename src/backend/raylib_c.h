// Shim header for translate-c: the raylib debug backend
// (src/backend/raylib.zig) imports the translated bindings as "raylib_c"
// (wired in build.zig when -Denable_raylib is on). Keeping the C surface
// to this single include keeps translate-c fast and the imported
// namespace stable across raylib versions.
#include <raylib.h>

// Direct GL_BGRA upload: the pixman framebuffer is ARGB8888 u32 (BGRA
// bytes in little-endian memory). raylib's UpdateTexture only accepts
// RGBA bytes, forcing a per-frame CPU byte-swap (bgraToRgba — ~20-40%
// of the compositor CPU in the perf profiles). Uploading the BGRA bytes
// as GL_BGRA lets the GL driver do the swizzle for free.
// The function pointers are GLAD's (raylib links GLAD; the raylib lib
// exports the glad_gl* pointers).
#define RL_GL_TEXTURE_2D 0x0DE1
#define RL_GL_TEXTURE_BINDING_2D 0x8069
#define RL_GL_BGRA 0x80E1
#define RL_GL_UNSIGNED_BYTE 0x1401
#define RL_GL_UNPACK_ROW_LENGTH 0x0CF2

extern void (*glad_glBindTexture)(unsigned int, unsigned int);
extern void (*glad_glGetIntegerv)(unsigned int, int*);
extern void (*glad_glPixelStorei)(unsigned int, int);
extern void (*glad_glTexSubImage2D)(unsigned int, int, int, int, int, int,
                                    unsigned int, unsigned int, const void*);
