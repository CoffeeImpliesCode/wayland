const std = @import("std");
const Build = std.Build;
const Scanner = @import("zig_wayland").Scanner;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Protocol codegen: zig-wayland scanner over vendored XML specs
    // (protocols/). The generated bindings (server + client namespaces)
    // compile into the "protocol" module.
    const scanner = Scanner.create(b, .{
        .wayland_xml = b.path("protocols/wayland/wayland.xml"),
        .wayland_protocols = b.path("protocols/wayland-protocols"),
    });
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wlroots/wlr-layer-shell-unstable-v1.xml"));

    // Maximum versions implemented by this server. Interfaces reachable
    // from these globals (wl_surface, wl_region, xdg_surface, xdg_toplevel,
    // wl_keyboard, wl_pointer, wl_touch, wl_callback, ...) are generated as
    // well; wl_display/wl_registry/wl_buffer always are.
    scanner.generate("wl_compositor", 7);
    scanner.generate("wl_shm", 3);
    scanner.generate("wl_seat", 11);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 7);
    scanner.generate("zwlr_layer_shell_v1", 5);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);

    const protocol = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    protocol.linkSystemLibrary("wayland-server", .{});
    protocol.linkSystemLibrary("wayland-client", .{});

    // The library: compositor core. Re-exports the generated protocol
    // bindings from src/root.zig.
    const lib = b.addModule("wayland", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
        },
    });

    const exe = b.addExecutable(.{
        .name = "wayland",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayland", .module = lib },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ------------------------------------------------------------------
    // M1 test server + test client (src/server/).
    // ------------------------------------------------------------------

    // zio: the event loop driving the server.
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    // Tracy profiler. OFF by default: the enabled path needs a C++ toolchain.
    const tracy = b.dependency("tracy", .{ .target = target, .optimize = optimize });
    const tracy_enabled = b.option(bool, "enable_tracy", "Enable the Tracy profiler") orelse false;

    const server_exe = b.addExecutable(.{
        .name = "wayland-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayland", .module = lib },
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "tracy", .module = tracy.module("tracy") },
            },
        }),
    });
    if (tracy_enabled) {
        server_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        server_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }
    b.installArtifact(server_exe);

    const server_run_step = b.step("run-server", "Run the M1 test server");
    const server_run_cmd = b.addRunArtifact(server_exe);
    server_run_step.dependOn(&server_run_cmd.step);
    server_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| server_run_cmd.addArgs(args);

    // Test client: pure protocol client (libwayland-client via the protocol
    // module). Deliberately does NOT import the compositor library.
    const client_exe = b.addExecutable(.{
        .name = "wayland-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol },
            },
        }),
    });
    b.installArtifact(client_exe);

    const client_run_step = b.step("run-client", "Run the M1 test client");
    const client_run_cmd = b.addRunArtifact(client_exe);
    client_run_step.dependOn(&client_run_cmd.step);
    client_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| client_run_cmd.addArgs(args);

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    const lib_tests = b.addTest(.{ .root_module = lib });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
