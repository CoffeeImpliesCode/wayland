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
    /// Null until create() succeeds: the impl destroy runs from an
    /// errdefer on a failed create() too, and must not deref a wrapper
    /// that was never created.
    out: ?*output.Output,
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
    /// WAYLAND_PERF=1: log present-stage timings.
    perf: bool = false,
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
        // Unload the GPU texture on any failure below; on success it is
        // owned by out_data (destroyOutput unloads it).
        errdefer raylib.UnloadTexture(texture);

        // Per-output state and its scratch first: their allocation-failure
        // cleanup (errdefers below) is independent of the backend, so a
        // failure cannot leak `rl`.
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
            .perf = std.mem.eql(
                u8,
                std.mem.span(std.c.getenv("WAYLAND_PERF") orelse ""),
                "1",
            ),
        };

        const rl = try allocator.create(Raylib);
        rl.* = .{
            .loop = loop,
            .timer = null,
            // SAFETY: assigned below via `rl.out = out` once the output
            // exists; null until then (the impl destroy guards it).
            .out = null,
            .mode = mode,
        };

        // Backend.init does not take ownership of rl on failure, so free
        // it here; every failure path then frees rl exactly once. After
        // init succeeds, the backend impl destroy owns rl.
        const base = backend.Backend.init(allocator, io, log_cfg, &backend_impl, rl) catch |err| {
            allocator.destroy(rl);
            return err;
        };
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
    base.emitNewOutput(rl.out.?);
}

fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const rl: *Raylib = @ptrCast(@alignCast(data));
    // Stop the timer first so no callback can run against a torn-down output.
    if (rl.timer) |timer| timer.remove();
    // The output wrapper may never have been created when destroy runs
    // from a failed create() errdefer (rl.out is null then).
    if (rl.out) |out| out.destroy();
    raylib.CloseWindow();
    allocator.destroy(rl);
}

fn frameCb(rl: *Raylib) c_int {
    const t0 = frameMs();
    rl.out.?.sendFrame();
    // libwayland does not re-arm timer sources after they fire; re-arm so
    // the NEXT fire lands refresh_msec after THIS callback started (the
    // fixed-period re-arm drifts by the frame work: period = work + 16ms).
    // On failure, drop the source (return 0).
    const elapsed: i32 = @intCast(@max(frameMs() - t0, 0));
    const remain: u32 = @intCast(@max(rl.mode.refresh_msec - elapsed, 1));
    rl.timer.?.timerUpdate(@intCast(remain)) catch return 0;
    return 1;
}

/// Monotonic milliseconds for the frame-pacing feedback.
fn frameMs() i64 {
    return std.Io.Clock.now(.awake, std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

fn testState(_: *output.Output, _: *const output.Output.State) error{InvalidState}!void {}

/// Upload the committed framebuffer into the window texture and draw it.
/// No-op (beyond logging) when the state carries no buffer. When the
/// state's damage rects union into a box smaller than the framebuffer,
/// only that box is byte-swapped and uploaded (UpdateTextureRec); whole,
/// empty, or full-screen damage keeps the full UpdateTexture path.
fn commit(out: *output.Output, state: *const output.Output.State) error{CommitFailed}!void {
    const od: *RaylibOutputData = @ptrCast(@alignCast(out.data));
    if (state.buffer) |buf| {
        const fb: *pixman.Framebuffer = @ptrCast(@alignCast(buf));
        const perf_t0 = perfNs(out.io);
        // ARGB8888 u32 (BGRA bytes in little-endian memory) -> RGBA bytes
        // for the R8G8B8A8 raylib texture.
        const scratch = std.mem.bytesAsSlice(u32, od.scratch);
        const fb_px = std.mem.bytesAsSlice(u32, fb.data);
        const full_w: usize = @intCast(fb.width);
        const upload = uploadRegion(&state.damage, fb.width, fb.height);
        if (upload) |region| {
            // Byte-swap only the damaged box's rows into the scratch
            // (offset into fb.data; tight w*h rows), then upload the box.
            bgraToRgbaRegion(
                scratch[0 .. region.w * region.h],
                fb_px,
                full_w,
                region.x,
                region.y,
                region.w,
                region.h,
            );
        } else {
            bgraToRgba(out.io, out.log_cfg, scratch, fb_px);
        }
        const perf_t_poll = perfNs(out.io);
        raylib.PollInputEvents();
        const rl_b: *Raylib = @ptrCast(@alignCast(out.backend.data));
        if (rl_b.poll_hook) |hook| hook(rl_b.poll_ctx.?);
        const perf_t_swap = perfNs(out.io);
        if (upload) |region| {
            raylib.UpdateTextureRec(od.texture, .{
                .x = @floatFromInt(region.x),
                .y = @floatFromInt(region.y),
                .width = @floatFromInt(region.w),
                .height = @floatFromInt(region.h),
            }, scratch.ptr);
        } else {
            raylib.UpdateTexture(od.texture, od.scratch.ptr);
        }
        const perf_t_upload = perfNs(out.io);
        raylib.BeginDrawing();
        raylib.ClearBackground(white);
        raylib.DrawTexture(od.texture, 0, 0, white);
        raylib.EndDrawing();
        const perf_t_draw = perfNs(out.io);
        if (od.perf) {
            log_mod.info(perf_raylib_fmt, out.io, out.log_cfg, "perf", .{
                (perf_t_poll - perf_t0) / 1000,
                (perf_t_swap - perf_t_poll) / 1000,
                (perf_t_upload - perf_t_swap) / 1000,
                (perf_t_draw - perf_t_upload) / 1000,
                (perf_t_draw - perf_t0) / 1000,
            });
        }
    }
    log_mod.info("commit: bits=0x{x} enabled={} scale={d} damage_rects={d}", out.io, out.log_cfg, "raylib", .{
        state.committed, state.enabled, state.scale, state.damage.rects.items.len,
    });
}

/// The upload region for this commit: the damage rects' bounding box
/// clamped to the framebuffer, when it is non-empty and smaller than the
/// full framebuffer. Null means the full UpdateTexture path: whole or
/// empty damage, damage covering everything, or all damage off-screen
/// (the visible framebuffer content is then unchanged).
const UploadRegion = struct { x: usize, y: usize, w: usize, h: usize };

fn uploadRegion(damage: *const wayland.utils.damage.Damage, fb_w: i32, fb_h: i32) ?UploadRegion {
    if (damage.whole) return null;
    const box = damage.boundingRect() orelse return null;
    // Saturate the box edges in i64: damage rects are a hint and can lie
    // outside the framebuffer or overflow i32 arithmetic.
    const x0: i64 = @max(@as(i64, box.x), 0);
    const y0: i64 = @max(@as(i64, box.y), 0);
    const x1: i64 = @min(x0 + @as(i64, box.width), fb_w);
    const y1: i64 = @min(y0 + @as(i64, box.height), fb_h);
    if (x1 <= x0 or y1 <= y0) return null;
    const w: i64 = x1 - x0;
    const h: i64 = y1 - y0;
    if (w * h >= @as(i64, fb_w) * @as(i64, fb_h)) return null;
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .w = @intCast(w),
        .h = @intCast(h),
    };
}

/// ARGB8888 u32 (BGRA bytes in little-endian memory) -> RGBA bytes for
/// the R8G8B8A8 raylib texture. The present hot path (921k pixels/frame):
/// runtime safety is disabled so the shuffle compiles to plain stores —
/// the slices are sized by the fixed 1280x720 framebuffer and scratch.
/// SAFETY NET: a framebuffer larger than the create-time scratch would
/// overflow dst below (safety is off in the loop); guard it first.
fn bgraToRgba(io: *std.Io, log_cfg: *const log_mod.Config, dst: []align(1) u32, src: []align(1) const u32) void {
    if (src.len > dst.len) {
        log_mod.err(
            "raylib: framebuffer {d} px exceeds scratch capacity {d} px; skipping upload",
            io,
            log_cfg,
            "raylib",
            .{ src.len, dst.len },
        );
        return;
    }
    @setRuntimeSafety(false);
    for (src, 0..) |px, i| {
        dst[i] = (px & 0xFF00FF00) | ((px & 0x000000FF) << 16) | ((px >> 16) & 0x000000FF);
    }
}

/// Region variant of bgraToRgba: byte-swaps only the box (x, y, w, h)
/// within `src` (stride `src_stride` pixels per row) into the first w*h
/// entries of `dst` — the layout UpdateTextureRec expects for a sub-rect
/// upload (tight rows). Same hot-path safety profile: the box is clamped
/// to the framebuffer by uploadRegion and the slices are fixed-size.
fn bgraToRgbaRegion(
    dst: []align(1) u32,
    src: []align(1) const u32,
    src_stride: usize,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
) void {
    @setRuntimeSafety(false);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const src_row = src[(y + row) * src_stride + x ..][0..w];
        const dst_row = dst[row * w ..][0..w];
        for (src_row, 0..) |px, i| {
            dst_row[i] = (px & 0xFF00FF00) | ((px & 0x000000FF) << 16) | ((px >> 16) & 0x000000FF);
        }
    }
}

/// Present-stage perf trace format (WAYLAND_PERF=1).
const perf_raylib_fmt = "perf raylib pre={d}us poll={d}us swap={d}us upload={d}us draw={d}us";

/// Monotonic nanoseconds for the perf trace.
fn perfNs(io: *std.Io) u64 {
    return @intCast(@max(std.Io.Clock.now(.awake, io.*).toNanoseconds(), 0));
}

fn destroyOutput(allocator: std.mem.Allocator, data: *anyopaque) void {
    const od: *RaylibOutputData = @ptrCast(@alignCast(data));
    raylib.UnloadTexture(od.texture);
    allocator.free(od.scratch);
    allocator.destroy(od);
}
