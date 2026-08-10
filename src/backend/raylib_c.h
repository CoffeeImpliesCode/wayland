// Shim header for translate-c: the raylib debug backend
// (src/backend/raylib.zig) imports the translated bindings as "raylib_c"
// (wired in build.zig when -Denable_raylib is on). Keeping the C surface
// to this single include keeps translate-c fast and the imported
// namespace stable across raylib versions.
#include <raylib.h>
