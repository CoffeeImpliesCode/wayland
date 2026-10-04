//! Backend-owned GPU scanout slot, borrowed by the renderer while leased.

const dmabuf = @import("../buffers/dmabuf.zig");

/// Stable for one backend swapchain generation. The backend owns the plane
/// descriptors and KMS framebuffer; renderer imports must end before teardown.
/// A successful output commit transfers the writing lease to the backend.
/// A failed commit leaves the lease with the caller, which must cancel it.
pub const GpuFrame = struct {
    /// Owned plane fds exported from the slot's BO, not client-borrowed fds.
    attributes: dmabuf.Attributes,
    fb_id: u32,
    /// Backend output identity; commits reject another output's slot.
    owner: *const anyopaque,
    slot: u2,
    /// Changes when the slot or its KMS descriptor lifetime changes.
    generation: u64,
};
