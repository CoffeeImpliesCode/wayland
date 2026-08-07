//! Render pass abstraction (wlr_render_pass pattern).
//!
//! A Pass collects draw operations targeting one framebuffer; submit()
//! flushes them. M1: passes apply eagerly (see pixman.zig), submit is a
//! no-op — the contract stays for the M2 gles2 renderer.
//!
//! Imports: utils/geom.zig, renderer/texture.zig.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const texture_mod = @import("texture.zig");

pub const Pass = struct {
    impl: *const Impl,
    data: *anyopaque,

    pub const Impl = struct {
        /// Draw a texture into `dst`, cropping from `src` (null = whole
        /// texture). `alpha` is a straight-alpha opacity in [0, 1].
        add_texture: *const fn (pass: *Pass, texture: *texture_mod.Texture, src: ?geom.FRect, dst: geom.FRect, alpha: f32) void,
        /// Fill `rect` with a straight-alpha RGBA color.
        add_rect: *const fn (pass: *Pass, rect: geom.Rect, color: [4]f32) void,
        /// Flush all queued draw operations.
        submit: *const fn (pass: *Pass) void,
    };

    pub fn addTexture(pass: *Pass, texture: *texture_mod.Texture, src: ?geom.FRect, dst: geom.FRect, alpha: f32) void {
        pass.impl.add_texture(pass, texture, src, dst, alpha);
    }

    pub fn addRect(pass: *Pass, rect: geom.Rect, color: [4]f32) void {
        pass.impl.add_rect(pass, rect, color);
    }

    pub fn submit(pass: *Pass) void {
        pass.impl.submit(pass);
    }
};

const FakePass = struct {
    textures: usize = 0,
    rects: usize = 0,
    submits: usize = 0,

    fn onTexture(pass: *Pass, _: *texture_mod.Texture, _: ?geom.FRect, _: geom.FRect, _: f32) void {
        const self: *FakePass = @ptrCast(@alignCast(pass.data));
        self.textures += 1;
    }

    fn onRect(pass: *Pass, _: geom.Rect, _: [4]f32) void {
        const self: *FakePass = @ptrCast(@alignCast(pass.data));
        self.rects += 1;
    }

    fn onSubmit(pass: *Pass) void {
        const self: *FakePass = @ptrCast(@alignCast(pass.data));
        self.submits += 1;
    }
};

const fake_impl = Pass.Impl{
    .add_texture = FakePass.onTexture,
    .add_rect = FakePass.onRect,
    .submit = FakePass.onSubmit,
};

test "pass dispatches to impl" {
    var fake = FakePass{};
    var tex = texture_mod.Texture{ .impl = undefined, .data = &fake, .width = 1, .height = 1 };
    var pass = Pass{ .impl = &fake_impl, .data = &fake };

    pass.addTexture(&tex, null, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 1.0);
    pass.addRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ 1.0, 0.0, 0.0, 1.0 });
    pass.submit();

    try std.testing.expectEqual(@as(usize, 1), fake.textures);
    try std.testing.expectEqual(@as(usize, 1), fake.rects);
    try std.testing.expectEqual(@as(usize, 1), fake.submits);
}
