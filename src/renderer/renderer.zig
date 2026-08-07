//! Renderer abstraction (wlr_renderer pattern).
//!
//! A Renderer owns the drawing backend. beginPass(target) opens a render
//! pass against a backend-defined target (for pixman: a Framebuffer);
//! targets the renderer cannot draw to yield null.
//!
//! Imports: utils/log.zig, renderer/pass.zig, renderer/texture.zig.

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const pass_mod = @import("pass.zig");

pub const Renderer = struct {
    impl: *const Impl,
    data: *anyopaque,
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    /// Pixel formats this renderer accepts (wl_shm format codes).
    /// Points at impl-owned static data; not freed by the renderer.
    formats: []const u32,

    pub const Impl = struct {
        /// Begin a render pass targeting `target`; null when unsupported.
        begin_pass: *const fn (renderer: *Renderer, target: *anyopaque) ?*pass_mod.Pass,
        /// Release renderer-owned resources (not the Renderer struct).
        destroy: *const fn (renderer: *Renderer) void,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        impl: *const Impl,
        data: *anyopaque,
        formats: []const u32,
    ) !*Renderer {
        const self = try allocator.create(Renderer);
        self.* = .{
            .impl = impl,
            .data = data,
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .formats = formats,
        };
        return self;
    }

    pub fn beginPass(renderer: *Renderer, target: *anyopaque) ?*pass_mod.Pass {
        return renderer.impl.begin_pass(renderer, target);
    }

    pub fn destroy(renderer: *Renderer) void {
        renderer.impl.destroy(renderer);
        const allocator = renderer.allocator;
        allocator.destroy(renderer);
    }
};

const FakeRenderer = struct {
    begins: usize = 0,
    destroyed: bool = false,

    fn onBeginPass(renderer: *Renderer, _: *anyopaque) ?*pass_mod.Pass {
        const self: *FakeRenderer = @ptrCast(@alignCast(renderer.data));
        self.begins += 1;
        return null;
    }

    fn onDestroy(renderer: *Renderer) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(renderer.data));
        self.destroyed = true;
    }
};

const fake_impl = Renderer.Impl{
    .begin_pass = FakeRenderer.onBeginPass,
    .destroy = FakeRenderer.onDestroy,
};

test "renderer lifecycle" {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg = log_mod.Config{};
    const allocator = std.testing.allocator;

    var fake = FakeRenderer{};
    const formats = [_]u32{ 0, 1 };
    const renderer = try Renderer.create(allocator, &io, &log_cfg, &fake_impl, &fake, &formats);
    defer renderer.destroy();

    try std.testing.expectEqual(@as(usize, 2), renderer.formats.len);
    var dummy: u8 = 0;
    try std.testing.expect(renderer.beginPass(&dummy) == null);
    try std.testing.expectEqual(@as(usize, 1), fake.begins);
    try std.testing.expect(!fake.destroyed);
}
