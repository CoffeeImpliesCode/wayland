//! Texture abstraction (wlr_texture pattern).
//!
//! A Texture is an imported pixel buffer a renderer can draw. Ownership of
//! all resources (including the Texture struct itself) lives with the impl;
//! destroy() hands them back.
//!
//! Imports: std only.

const std = @import("std");

pub const Texture = struct {
    impl: *const Impl,
    data: *anyopaque,
    width: i32,
    height: i32,

    pub const Impl = struct {
        /// Release all resources owned by this texture, including the
        /// Texture struct itself.
        destroy: *const fn (texture: *Texture) void,
    };

    pub fn destroy(texture: *Texture) void {
        texture.impl.destroy(texture);
    }
};

const FakeTexture = struct {
    destroyed: bool = false,

    fn onDestroy(texture: *Texture) void {
        const self: *FakeTexture = @ptrCast(@alignCast(texture.data));
        self.destroyed = true;
    }
};

const fake_impl = Texture.Impl{ .destroy = FakeTexture.onDestroy };

test "texture destroy dispatches to impl" {
    var fake = FakeTexture{};
    var tex = Texture{ .impl = &fake_impl, .data = &fake, .width = 2, .height = 2 };
    tex.destroy();
    try std.testing.expect(fake.destroyed);
}
