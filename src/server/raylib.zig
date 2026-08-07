//! Raylib debug backend: one windowed output, frames paced by the wire
//! event loop timer (same pattern as backend/headless.zig), presented
//! through a raylib window.
//!
//! The output's framebuffer (pixman ARGB8888 = BGRA bytes on
//! little-endian) is uploaded into a raylib texture on every commit and
//! drawn full-screen. This is a *debug* view: no DRM, no vsync
//! synchronization, one window.
//!
//! Input (M3): each commit polls raylib input events and calls the
//! server-installed poll hook (raylib_input.zig) which feeds the seat —
//! keyboard, pointer motion/buttons and the wheel.
//!
//! On environments without a display/GL context, create() returns
//! error.WindowInitFailed; the test server then falls back to the
//! headless backend with a warning instead of crashing.
//!
//! Imports: the "wayland" library module (utils, wire, backend, output,
//! pixman) and the translated raylib C bindings ("raylib_c", wired in
//! build.zig when -Denable_raylib).

const std = @import("std");
const wayland = @import("wayland");
const raylib = @import("raylib_c");

const log_mod = wayland.utils.log;
const wire = wayland.wire;
const backend = wayland.backend;
const output = wayland.output;
const pixman = wayland.pixman;

const Raylib = struct {
    loop: *wire.EventLoop,
    timer: ?*wire.EventSource,
    out: *output.Output,
    mode: output.Mode,
    /// Input poll hook: called right after PollInputEvents in every
    /// commit (server-side raylib_input.zig feeds the seat from it).
    poll_hook: ?*const fn (ctx: *anyopaque) void = null,
    poll_ctx: ?*anyopaque = null,
};

/// Per-output raylib state: the window texture the compositor framebuffer
/// is uploaded into on each commit.
const RaylibOutputData = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    texture: raylib.Texture2D,
    /// BGRA-in-memory (ARGB8888 u32) -> RGBA byte swap scratch for the
    /// R8G8B8A8 raylib texture; width*height*4 bytes.
    scratch: []u8,
};

const backend_impl: backend.Backend.Impl = .{
    .start = start,
    .destroy = destroy,
};

const output_impl: output.Output.Impl = .{
    .@"test" = testState,
    .commit = commit,
    .destroy = destroyOutput,
};

pub const RaylibBackend = struct {
    /// Install the per-frame input poll hook (see raylib_input.zig). The
    /// hook runs after PollInputEvents in each commit, on the main thread.
    pub fn setInputHook(base: *backend.Backend, hook: ?*const fn (ctx: *anyopaque) void, ctx: ?*anyopaque) void {
        const rl: *Raylib = @ptrCast(@alignCast(base.data));
        rl.poll_hook = hook;
        rl.poll_ctx = ctx;
    }

    /// Create a single-output raylib backend running at `mode`, with the
    /// window titled `title`. Frames are paced by a wire event loop timer
    /// at `mode.refresh_msec` (like the headless backend); the window
    /// itself targets 60 fps via SetTargetFPS.
    ///
    /// error.WindowInitFailed when the window cannot open (no display or
    /// no GL context); error.TextureLoadFailed when the framebuffer
    /// texture cannot be allocated. Callers fall back to headless.
    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        loop: *wire.EventLoop,
        mode: output.Mode,
        title: [:0]const u8,
    ) error{ OutOfMemory, WindowInitFailed, TextureLoadFailed }!*backend.Backend {
        std.debug.assert(mode.width > 0);
        std.debug.assert(mode.height > 0);
        std.debug.assert(mode.refresh_msec > 0);

        // raylib 6.0 aborts the process when its window backend cannot
        // reach a display (no X11 or Wayland server), so probe the
        // environment first: an X11 DISPLAY or a Wayland socket name must
        // be present. Without one, report error.WindowInitFailed and let
        // the caller fall back to headless instead of crashing.
        const display_env = std.mem.span(std.c.getenv("DISPLAY") orelse "");
        const wayland_env = std.mem.span(std.c.getenv("WAYLAND_DISPLAY") orelse "");
        if (display_env.len == 0 and wayland_env.len == 0) {
            log_mod.warn(
                "raylib: no DISPLAY/WAYLAND_DISPLAY in the environment; cannot open a window",
                io,
                log_cfg,
                "raylib",
                .{},
            );
            return error.WindowInitFailed;
        }

        raylib.InitWindow(mode.width, mode.height, title.ptr);
        errdefer raylib.CloseWindow();
        if (!raylib.IsWindowReady()) return error.WindowInitFailed;
        raylib.SetTargetFPS(60);

        // Blank RGBA8888 texture (GenImageColor produces
        // UNCOMPRESSED_R8G8B8A8) the framebuffer is uploaded into per
        // commit. Unload the CPU-side image once the GPU texture exists.
        const image = raylib.GenImageColor(mode.width, mode.height, blank);
        defer raylib.UnloadImage(image);
        const texture = raylib.LoadTextureFromImage(image);
        if (texture.id == 0) return error.TextureLoadFailed;

        const rl = try allocator.create(Raylib);
        errdefer allocator.destroy(rl);
        rl.* = .{
            .loop = loop,
            .timer = null,
            // SAFETY: assigned below via `rl.out = out`.
            .out = undefined,
            .mode = mode,
        };

        const out_data = try allocator.create(RaylibOutputData);
        errdefer allocator.destroy(out_data);
        const scratch = try allocator.alloc(
            u8,
            @as(usize, @intCast(mode.width)) * @as(usize, @intCast(mode.height)) * 4,
        );
        errdefer allocator.free(scratch);
        out_data.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .texture = texture,
            .scratch = scratch,
        };

        const base = try backend.Backend.init(allocator, io, log_cfg, &backend_impl, rl);
        errdefer base.destroy();
        const out = try output.Output.create(allocator, io, log_cfg, base, &output_impl, out_data, mode);
        rl.out = out;
        return base;
    }
};

const white: raylib.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const blank: raylib.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

fn start(base: *backend.Backend) error{BackendFailed}!void {
    const rl: *Raylib = @ptrCast(@alignCast(base.data));
    std.debug.assert(rl.timer == null);

    const timer = rl.loop.addTimer(*Raylib, frameCb, rl) catch return error.BackendFailed;
    errdefer timer.remove();
    timer.timerUpdate(rl.mode.refresh_msec) catch return error.BackendFailed;
    rl.timer = timer;

    log_mod.info("started {d}x{d} @ {d}ms (raylib window)", base.io, base.log_cfg, "raylib", .{
        rl.mode.width, rl.mode.height, rl.mode.refresh_msec,
    });
    base.emitNewOutput(rl.out);
}

fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const rl: *Raylib = @ptrCast(@alignCast(data));
    // Stop the timer first so no callback can run against a torn-down output.
    if (rl.timer) |timer| timer.remove();
    rl.out.destroy();
    raylib.CloseWindow();
    allocator.destroy(rl);
}

fn frameCb(rl: *Raylib) c_int {
    rl.out.sendFrame();
    // libwayland does not re-arm timer sources after they fire; re-arm for
    // the next period. On failure, drop the source (return 0).
    rl.timer.?.timerUpdate(rl.mode.refresh_msec) catch return 0;
    return 1;
}

fn testState(_: *output.Output, _: *const output.Output.State) error{InvalidState}!void {}

/// Upload the committed framebuffer into the window texture and draw it.
/// No-op (beyond logging) when the state carries no buffer.
fn commit(out: *output.Output, state: *const output.Output.State) error{CommitFailed}!void {
    const od: *RaylibOutputData = @ptrCast(@alignCast(out.data));
    if (state.buffer) |buf| {
        const fb: *pixman.Framebuffer = @ptrCast(@alignCast(buf));
        // ARGB8888 u32 (BGRA bytes in little-endian memory) -> RGBA bytes
        // for the R8G8B8A8 raylib texture.
        const pixels = std.mem.bytesAsSlice(u32, fb.data);
        for (pixels, 0..) |px, i| {
            od.scratch[i * 4 + 0] = @truncate(px >> 16);
            od.scratch[i * 4 + 1] = @truncate(px >> 8);
            od.scratch[i * 4 + 2] = @truncate(px);
            od.scratch[i * 4 + 3] = @truncate(px >> 24);
        }
        raylib.PollInputEvents();
        const rl: *Raylib = @ptrCast(@alignCast(out.backend.data));
        if (rl.poll_hook) |hook| hook(rl.poll_ctx.?);
        raylib.UpdateTexture(od.texture, od.scratch.ptr);
        raylib.BeginDrawing();
        raylib.ClearBackground(white);
        raylib.DrawTexture(od.texture, 0, 0, white);
        raylib.EndDrawing();
    }
    log_mod.info("commit: bits=0x{x} enabled={} scale={d} damage_rects={d}", out.io, out.log_cfg, "raylib", .{
        state.committed, state.enabled, state.scale, state.damage.rects.items.len,
    });
}

fn destroyOutput(allocator: std.mem.Allocator, data: *anyopaque) void {
    const od: *RaylibOutputData = @ptrCast(@alignCast(data));
    raylib.UnloadTexture(od.texture);
    allocator.free(od.scratch);
    allocator.destroy(od);
}
