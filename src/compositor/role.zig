//! Surface role enforcement (wlr_surface_role pattern).
//!
//! A wl_surface receives its role from a shell/cursor/drag protocol
//! request (get_xdg_surface, wl_pointer.set_cursor, ...). The role is
//! permanent for the surface's whole lifetime: assigning a different role
//! later is a protocol violation and posts a wl_surface error to the
//! client. Re-assigning the same role is allowed.

const std = @import("std");
const wire = @import("../core/wire.zig");
const surface_mod = @import("surface.zig");

const Surface = surface_mod.Surface;

/// Role implementation (wlr_surface_role pattern). The fn-pointer hooks
/// are called by the surface state machine at the matching points of the
/// commit pipeline; each hook receives only the surface. The role object
/// is reached through `surface.role_resource` (getUserData) or a registry
/// owned by the shell implementation.
pub const SurfaceRole = struct {
    /// Human-readable role name, for logs and error messages.
    name: []const u8,
    /// Called at commit after the pending state is applied, before
    /// role.commit. Role-specific processing of the freshly committed
    /// state goes here (e.g. xdg configure accounting).
    client_commit: ?*const fn (surface: *Surface) void = null,
    /// Called at commit after client_commit; the role applies its own
    /// double-buffered state here.
    commit: ?*const fn (surface: *Surface) void = null,
    /// Called when the surface becomes mapped (first buffer commit).
    map: ?*const fn (surface: *Surface) void = null,
    /// Called when the surface stops being mapped (null-buffer commit or
    /// destroy).
    unmap: ?*const fn (surface: *Surface) void = null,
    /// Called when the surface is destroyed, before the destroy signal.
    destroy: ?*const fn (surface: *Surface) void = null,
};

pub const RoleError = error{ RoleConflict };

/// wl_surface protocol error code posted for an illegal role switch. The
/// wl_surface error enum has no dedicated "role" member (generated enum:
/// invalid_scale=0, invalid_transform=1, invalid_size=2, invalid_offset=3,
/// defunct_role_object=4, no_buffer=5); per the M1 assignment, code 1 is
/// used with a descriptive message.
pub const role_error_code: u32 = 1;

/// Assign `role` to `surface`. Re-assigning the current role is allowed
/// and refreshes the stored role resource. Switching to a different role
/// posts a wl_surface protocol error to the client and fails with
/// error.RoleConflict; the surface keeps its previous role.
pub fn assignRole(surface: *Surface, role: *const SurfaceRole, role_resource: ?*wire.Resource) RoleError!void {
    if (surface.role) |current| {
        if (current != role) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrintZ(
                &buf,
                "cannot assign role '{s}' to wl_surface@{d}, already has role '{s}'",
                .{ role.name, surface.resource.getId(), current.name },
            ) catch "role conflict";
            @as(*wire.Resource, @ptrCast(surface.resource)).postError(role_error_code, msg);
            return error.RoleConflict;
        }
        // Same role again: allowed; refresh the role resource.
        surface.role_resource = role_resource;
        return;
    }
    surface.role = role;
    surface.role_resource = role_resource;
}

const testing = std.testing;
const log = @import("../utils/log.zig");

test "assign role and re-assign the same role" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg = log.Config{ .min_level = .err };

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);

    var role_a = SurfaceRole{ .name = "role-a" };
    var role_b = SurfaceRole{ .name = "role-b" };

    try assignRole(s, &role_a, null);
    try testing.expect(s.role == &role_a);

    // Re-assigning the current role is legal.
    try assignRole(s, &role_a, null);
    try testing.expect(s.role == &role_a);

    // Switching to a different role posts a protocol error and fails.
    try testing.expectError(error.RoleConflict, assignRole(s, &role_b, null));
    try testing.expect(s.role == &role_a);
}
