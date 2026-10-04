const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Scanner = @import("zig_wayland").Scanner;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    // The demo server runs at ReleaseSafe (house directive): Debug is the
    // slow mode (per-pixel loops with safety checks measured 55-70ms/frame
    // vs ~32ms at ReleaseSafe). Pass -Doptimize=Debug for test runs.
    //
    // Not standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe }):
    // that path registers only -Drelease, so -Doptimize is rejected as an
    // unknown option and an unflagged build lands in .Debug. Register the
    // option here and default to the intended mode, mirroring the std
    // switch for the --release=* spellings.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .off => std.builtin.OptimizeMode.ReleaseSafe,
        .fast => std.builtin.OptimizeMode.ReleaseFast,
        .safe => std.builtin.OptimizeMode.ReleaseSafe,
        .small => std.builtin.OptimizeMode.ReleaseSmall,
        .any => {
            std.debug.print(
                "the project defaults to ReleaseSafe; pass " ++
                    "-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n",
                .{},
            );
            std.process.exit(1);
        },
    };

    // zig-cov coverage (see zig-cov README): zig-gate --cov passes these
    const coverage = b.option(bool, "coverage", "Enable zig-cov") orelse false;
    const cov_rt = b.option([]const u8, "coverage-rt", "zig-cov-rt path") orelse null;

    // Protocol codegen: zig-wayland scanner over vendored XML specs
    // (protocols/). The generated bindings (server + client namespaces)
    // compile into the "protocol" module.
    const scanner = Scanner.create(b, .{
        .wayland_xml = b.path("protocols/wayland/wayland.xml"),
        .wayland_protocols = b.path("protocols/wayland-protocols"),
    });
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/presentation-time/presentation-time.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-output/xdg-output-unstable-v1.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
    scanner.addSystemProtocol("staging/tearing-control/tearing-control-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/relative-pointer/relative-pointer-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wlroots/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wlroots/wlr-screencopy-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wlroots/wlr-data-control-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wlroots/wlr-foreign-toplevel-management-unstable-v1.xml"));

    // Maximum versions implemented by this server. Interfaces reachable
    // from these globals (wl_surface, wl_region, xdg_surface, xdg_toplevel,
    // wl_keyboard, wl_pointer, wl_touch, wl_callback, ...) are generated as
    // well; wl_display/wl_registry/wl_buffer always are.
    //
    // Only the top-level global is named per protocol: zig-wayland's
    // Protocol.emit emits a target's global together with global.children,
    // i.e. every interface constructed by one of its requests or events.
    // Naming a child here instead would never match a global and the scanner
    // would abort with "requested global interface '<name>' not found".
    //
    // Each version is the maximum the vendored XML declares. Requesting more
    // aborts the build (Protocol.emit compares target.version against
    // global.interface.version).
    scanner.generate("wl_compositor", 7);
    scanner.generate("wl_shm", 3);
    scanner.generate("wl_seat", 11);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("wl_output", 4);
    scanner.generate("xdg_wm_base", 7);
    scanner.generate("xdg_activation_v1", 1);
    scanner.generate("zxdg_decoration_manager_v1", 2);
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);
    scanner.generate("zxdg_output_manager_v1", 3);
    scanner.generate("zwlr_layer_shell_v1", 5);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("wp_presentation", 2);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 2);
    scanner.generate("zwp_linux_dmabuf_v1", 6);
    scanner.generate("wp_tearing_control_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 2);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.generate("zwp_relative_pointer_manager_v1", 1);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("zwlr_data_control_manager_v1", 2);
    scanner.generate("zwlr_foreign_toplevel_manager_v1", 3);

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
    // xkbcommon: the seat builds the wl_keyboard keymap and tracks
    // modifier/keysym state with it (libxkbcommon is in the devenv
    // packages; the .pc comes from its dev output).
    lib.linkSystemLibrary("xkbcommon", .{});
    // Real pixman library (pixman-0.46.4): SIMD-optimized software
    // compositor for the canvas pass (pixman_image_composite32), replacing
    // the hand-rolled per-pixel bilinear (weston/wlroots use the same). The
    // include path + link come from pkg-config at configure time (nix:
    // nixpkgs#pixman.dev).
    {
        const pixman_c = b.addTranslateC(.{
            .root_source_file = b.path("src/renderer/pixman_c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const cflags = b.run(&.{ "pkg-config", "--cflags", "pixman-1" });
        var it = std.mem.tokenizeAny(u8, cflags, " \t\n");
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-I") and tok.len > 2) {
                pixman_c.addSystemIncludePath(.{ .cwd_relative = b.dupe(tok[2..]) });
            }
        }
        lib.addImport("pixman_c", pixman_c.createModule());
        lib.linkSystemLibrary("pixman-1", .{ .use_pkg_config = .force });
    }
    // DRM/KMS backend (src/backend/drm.zig): libdrm via a translate-c shim
    // (house pattern, cf. raylib_c). The include root + root/libdrm come
    // from pkg-config at configure time (nix: nixpkgs#libdrm.dev).
    {
        const drm_c = b.addTranslateC(.{
            .root_source_file = b.path("src/backend/drm_c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const cflags = b.run(&.{ "pkg-config", "--cflags", "libdrm" });
        var it = std.mem.tokenizeAny(u8, cflags, " \t\n");
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-I") and tok.len > 2) {
                drm_c.addSystemIncludePath(.{ .cwd_relative = b.dupe(tok[2..]) });
            }
        }
        lib.addImport("drm_c", drm_c.createModule());
        lib.linkSystemLibrary("drm", .{ .use_pkg_config = .force });
    }

    // GBM (src/buffers/dmabuf.zig + src/backend/drm.zig): libgbm from
    // nixpkgs#mesa, through a translate-c shim (house pattern, cf.
    // gles2_c/drm_c/raylib_c). There is no gbm.pc on this project's
    // PKG_CONFIG_PATH - nixpkgs#mesa-libgbm ships one but no devenv
    // package propagates it - so the include dir and the link dir are
    // resolved by `gbmDirs` below instead of `pkg-config --cflags gbm`,
    // and linked as raw -I/-L exactly like the DRM shim's flags.
    const gbm = gbmDirs(b);
    const gbm_c = b.addTranslateC(.{
        .root_source_file = b.path("src/buffers/dmabuf_c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gbm_c.addSystemIncludePath(.{ .cwd_relative = gbm.include });
    const gbm_c_mod = gbm_c.createModule();
    lib.addImport("gbm_c", gbm_c_mod);
    linkGbm(b, lib, gbm);
    // libinput backend (src/backend/libinput.zig): udev context, evdev
    // devices; the runtime lib is in the devenv/nix closure.
    lib.linkSystemLibrary("libinput", .{});
    // libinput's udev context needs libudev (ships with systemd; the .pc
    // is libudev.pc from systemd's dev output — link the correct name, so
    // pkg-config resolves the -L/-l flags and the udev_new/udev_unref
    // symbols actually link (linking 'udev' looked for a non-existent
    // udev.pc and left libudev out, giving undefined symbols).
    lib.linkSystemLibrary("libudev", .{ .use_pkg_config = .force });

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
    // libgbm reaches `exe` through the wayland lib module import, but
    // system-link propagation is not automatic - link it explicitly
    // (same pattern as the raylib/egl links below).
    linkGbm(b, exe.root_module, gbm);
    b.installArtifact(exe);

    // GLES2/EGL renderer (src/renderer/gles2.zig): GPU compositor via EGL +
    // GLES2 through a translate-c shim (house pattern, cf. pixman_c/drm_c/
    // raylib_c). Include path + link come from pkg-config at configure time
    // (nix: nixpkgs#libglvnd.dev provides <EGL/egl.h> + <GLES2/gl2.h>;
    // nixpkgs#mesa provides the llvmpipe software GL so it renders headless).
    {
        const gles2_c = b.addTranslateC(.{
            .root_source_file = b.path("src/renderer/gles2_c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const cflags = b.run(&.{ "pkg-config", "--cflags", "egl", "glesv2" });
        var it = std.mem.tokenizeAny(u8, cflags, " \t\n");
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-I") and tok.len > 2) {
                gles2_c.addSystemIncludePath(.{ .cwd_relative = b.dupe(tok[2..]) });
            }
        }
        // The library module (root.zig exports renderer/gles2.zig) needs
        // "gles2_c" and egl/glesv2 linked into every artifact using the
        // library (lib_tests, the demo exe, the test server) — same wiring
        // shape as raylib_c/drm_c.
        const gles2_c_mod = gles2_c.createModule();
        lib.addImport("gles2_c", gles2_c_mod);
        lib.linkSystemLibrary("egl", .{ .use_pkg_config = .force });
        lib.linkSystemLibrary("glesv2", .{ .use_pkg_config = .force });
        exe.root_module.addImport("gles2_c", gles2_c_mod);
        exe.root_module.linkSystemLibrary("egl", .{ .use_pkg_config = .force });
        exe.root_module.linkSystemLibrary("glesv2", .{ .use_pkg_config = .force });
    }

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

    // Raylib debug backend (src/backend/raylib.zig): windowed output
    // visualization for the test server. ON by default. When disabled the
    // server builds without raylib (main.zig guards the import through the
    // build_options module below).
    const enable_raylib = b.option(
        bool,
        "enable_raylib",
        "Link the raylib debug backend into wayland-server",
    ) orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_raylib", enable_raylib);
    // ONE shared module instance: lib + server + tests must see the same
    // "build_options" module, or Zig renames the second instance
    // (build_options0) and root.zig's import collides.
    const build_options_mod = build_options.createModule();
    // root.zig gates its raylib/raylib_input exports' comptime analysis
    // on build_options.enable_raylib (the files import "raylib_c", which
    // only exists with -Denable_raylib).
    lib.addImport("build_options", build_options_mod);

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
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    if (tracy_enabled) {
        server_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        server_exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }
    if (enable_raylib) {
        // Translate the raylib C API through a shim header so the backend
        // imports a small stable namespace ("raylib_c"). The include path
        // comes from pkg-config at configure time: PKG_CONFIG_PATH must
        // list raylib's lib/pkgconfig (nix: nixpkgs#raylib) when building
        // outside the devenv shell. Linking also goes through pkg-config
        // (use_pkg_config = .force), so the same PKG_CONFIG_PATH applies.
        const raylib_c = b.addTranslateC(.{
            .root_source_file = b.path("src/backend/raylib_c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const cflags = b.run(&.{ "pkg-config", "--cflags", "raylib" });
        var it = std.mem.tokenizeAny(u8, cflags, " \t\n");
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-I") and tok.len > 2) {
                raylib_c.addSystemIncludePath(.{ .cwd_relative = b.dupe(tok[2..]) });
                break;
            }
        }
        // The library module (root.zig exports backend/raylib.zig) needs
        // "raylib_c" too, and raylib linked into every artifact using the
        // library (lib_tests, the demo exe) — same wiring shape as drm_c.
        const raylib_c_mod = raylib_c.createModule();
        lib.addImport("raylib_c", raylib_c_mod);
        lib.linkSystemLibrary("raylib", .{ .use_pkg_config = .force });
        server_exe.root_module.addImport("raylib_c", raylib_c_mod);
        server_exe.root_module.linkSystemLibrary("raylib", .{ .use_pkg_config = .force });
    }
    server_exe.root_module.linkSystemLibrary("xkbcommon", .{});
    // gles2 renderer: egl/glesv2 reach server_exe through the wayland lib
    // module import, but system-link propagation is not automatic — link
    // them explicitly (same pattern as the raylib link above).
    server_exe.root_module.linkSystemLibrary("egl", .{ .use_pkg_config = .force });
    server_exe.root_module.linkSystemLibrary("glesv2", .{ .use_pkg_config = .force });
    // libudev: the libinput backend's hotplug monitor calls
    // udev_monitor_* directly (libinput.zig). Same non-propagation trap as
    // egl/glesv2 above — lib links it, the exe does not inherit it, and the
    // undefined symbol only shows up when the exe is LINKED. `zig build
    // check` compiles but never links, so only `zig build` catches this.
    server_exe.root_module.linkSystemLibrary("libudev", .{ .use_pkg_config = .force });
    b.installArtifact(server_exe);
    // libgbm, for the same reason as exe above.
    linkGbm(b, server_exe.root_module, gbm);

    const server_run_step = b.step("run-server", "Run the M1 test server");
    const server_run_cmd = b.addRunArtifact(server_exe);
    server_run_step.dependOn(&server_run_cmd.step);
    server_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| server_run_cmd.addArgs(args);

    // Test client: pure protocol client (libwayland-client via the protocol
    // module). Deliberately does NOT import the compositor library. A test
    // tool: always ReleaseFast (it must not skew E2E timing); the server
    // stays at the session's optimize (ReleaseSafe for demos).
    const client_exe = b.addExecutable(.{
        .name = "wayland-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/client.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "protocol", .module = protocol },
            },
        }),
    });
    client_exe.root_module.addImport("gbm_c", gbm_c_mod);
    linkGbm(b, client_exe.root_module, gbm);
    b.installArtifact(client_exe);

    // Adversarial protocol roundtrip probe: deliberately triggers
    // protocol violations and verifies the compositor's error responses.
    // A test tool; run against a live server (zig build run-rtprobe).
    const probe_exe = b.addExecutable(.{
        .name = "rtprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/rtprobe.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "protocol", .module = protocol },
            },
        }),
    });
    b.installArtifact(probe_exe);
    const probe_run_step = b.step("run-rtprobe", "Run the adversarial protocol probe");
    const probe_run_cmd = b.addRunArtifact(probe_exe);
    probe_run_step.dependOn(&probe_run_cmd.step);
    probe_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| probe_run_cmd.addArgs(args);

    const client_run_step = b.step("run-client", "Run the M1 test client");
    const client_run_cmd = b.addRunArtifact(client_exe);
    client_run_step.dependOn(&client_run_cmd.step);
    client_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| client_run_cmd.addArgs(args);

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    const lib_tests = b.addTest(.{ .root_module = lib });
    if (coverage) {
        lib_tests.use_llvm = true; // required: only the LLVM backend emits sancov counters
        lib_tests.root_module.fuzz = true; // emits __sancov_cntrs + __sancov_pcs1
        lib_tests.root_module.link_libc = true; // atexit handler writes the .zcov
        if (cov_rt) |p| lib_tests.root_module.addObjectFile(.{ .cwd_relative = p });
    }
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // exe_tests: the server executable's root module (src/server/main.zig)
    // declares its own `pub fn main(init: std.process.Init)`, which a test
    // binary built from that root would keep as its entry and then panic
    // on the runner's `--listen=-` protocol args. Give the test step its
    // own root module (src/server/main_test.zig, no main) so the test
    // runner becomes the entry; the comptime import + refAllDecls in that
    // root still force full analysis of main.zig's decls (AGENTS.md
    // gate-5: unused decls still type-check). The module mirrors the
    // server root's imports (zio, tracy, build_options, tracy_impl,
    // raylib_c) and system links.
    const exe_test_module = b.createModule(.{
        .root_source_file = b.path("src/server/main_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const import_names = server_exe.root_module.import_table.keys();
    const import_mods = server_exe.root_module.import_table.values();
    for (import_names, import_mods) |import_name, import_mod| {
        exe_test_module.addImport(import_name, import_mod);
    }
    exe_test_module.linkSystemLibrary("xkbcommon", .{});
    if (enable_raylib) {
        exe_test_module.linkSystemLibrary("raylib", .{ .use_pkg_config = .force });
    }
    // gles2 renderer (via the wayland lib import): system-link propagation
    // is not automatic — link egl/glesv2 explicitly (raylib pattern).
    exe_test_module.linkSystemLibrary("egl", .{ .use_pkg_config = .force });
    exe_test_module.linkSystemLibrary("glesv2", .{ .use_pkg_config = .force });
    // libudev, for the same non-propagation reason as on server_exe.
    exe_test_module.linkSystemLibrary("libudev", .{ .use_pkg_config = .force });
    // libgbm, for the same reason as exe above.
    linkGbm(b, exe_test_module, gbm);
    const exe_tests = b.addTest(.{ .root_module = exe_test_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // House convention (nogui/skript): compile everything without
    // installing — for ZLS build-on-save.
    const check_step = b.step("check", "Check all targets compile (ZLS)");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&lib_tests.step);
    check_step.dependOn(&exe_tests.step);

    // Docs: a static library compile over the compositor-core root module
    // exists only as the autodoc source (the "wayland" library itself is
    // a module wired into the exes/tests above, not an installed artifact).
    const docs_lib = b.addLibrary(.{
        .name = "wayland",
        .root_module = lib,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}

/// Where libgbm's headers and library live.
const GbmDirs = struct {
    include: []const u8,
    lib: []const u8,
};

/// Link libgbm into one module. System-link propagation through a module
/// import is not automatic in Zig 0.16 (the raylib/egl blocks in this file
/// hit the same thing), so every artifact that compiles a file importing
/// `gbm_c` needs the -lgbm, -L and rpath itself.
fn linkGbm(b: *Build, module: *std.Build.Module, dirs: GbmDirs) void {
    _ = b;
    module.linkSystemLibrary("gbm", .{});
    module.addLibraryPath(.{ .cwd_relative = dirs.lib });
    module.addRPath(.{ .cwd_relative = dirs.lib });
}

/// Resolve libgbm's include dir and link dir.
///
/// pkg-config first: on a normal system (and in a devenv that propagates
/// mesa-libgbm) `gbm` resolves from its .pc. This project's devenv does
/// not - nixpkgs#mesa-libgbm ships a gbm.pc, but no devenv package
/// propagates that output onto PKG_CONFIG_PATH, so
/// `pkg-config --variable=includedir gbm` fails even though the header and
/// the shared object are in the closure. The fallback picks the output
/// straight out of the nix store, highest version first so the choice is
/// deterministic, which is the raw -I/-L style the ticket calls for.
fn gbmDirs(b: *Build) GbmDirs {
    const includedir = probeGbm(b, "--variable=includedir") orelse
        return nixGbmDirs(b);
    const libdir = probeGbm(b, "--variable=libdir") orelse
        return nixGbmDirs(b);
    return .{ .include = b.dupe(includedir), .lib = b.dupe(libdir) };
}

/// `pkg-config <arg> gbm`, or null when gbm is not resolvable (the .pc
/// is absent, or the package name is unknown to it).
fn probeGbm(b: *Build, comptime arg: []const u8) ?[]const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "pkg-config", arg, "gbm" }, &code, .ignore) catch return null;
    if (code != 0) return null;
    return std.mem.trim(u8, out, " \t\r\n");
}

/// The mesa-libgbm dev output from /nix/store.
fn nixGbmDirs(b: *Build) GbmDirs {
    const prefix = newestNixOutput(b, "mesa-libgbm", "gbm") orelse @panic(
        "libgbm not found: no gbm.pc on PKG_CONFIG_PATH and no " ++
            "mesa-libgbm output in /nix/store (add nixpkgs#mesa to the " ++
            "devenv packages)",
    );
    return .{
        .include = std.fs.path.join(b.allocator, &.{ prefix, "include" }) catch @panic("OOM"),
        .lib = std.fs.path.join(b.allocator, &.{ prefix, "lib" }) catch @panic("OOM"),
    };
}

/// The highest-versioned /nix/store directory whose name contains
/// `-<output_name>-<version>` and which ships
/// `lib/pkgconfig/<pc_name>`. Requiring the .pc keeps a
/// differently-packaged output (a runtime-only one, say) from being
/// picked; `output_name` and `pc_name` differ because nixpkgs names the
/// derivation `mesa-libgbm` but ships the file as `gbm.pc`.
fn newestNixOutput(b: *Build, output_name: []const u8, pc_name: []const u8) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(b.graph.io, "/nix/store", .{ .iterate = true }) catch return null;
    defer dir.close(b.graph.io);
    const marker = std.fmt.allocPrint(b.allocator, "-{s}-", .{output_name}) catch @panic("OOM");
    const pc_file = std.fmt.allocPrint(b.allocator, "{s}.pc", .{pc_name}) catch @panic("OOM");
    var best: ?[]const u8 = null;
    var best_version: []const u8 = "";
    var it = dir.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        // The d_type is not always populated, so `unknown` has to be
        // accepted too; the .pc probe below is the real filter.
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        const at = std.mem.indexOf(u8, entry.name, marker) orelse continue;
        const version = entry.name[at + marker.len ..];
        if (std.mem.lastIndexOfScalar(u8, version, '.') == null) continue;
        if (!versionNewer(version, best_version)) continue;
        const pc = std.fs.path.join(b.allocator, &.{
            "/nix/store", entry.name, "lib", "pkgconfig", pc_file,
        }) catch @panic("OOM");
        const f = std.Io.Dir.openFileAbsolute(b.graph.io, pc, .{}) catch continue;
        f.close(b.graph.io);
        if (!elfMatchesTarget(b, entry.name)) continue;
        best = std.fmt.allocPrint(b.allocator, "/nix/store/{s}", .{entry.name}) catch @panic("OOM");
        best_version = version;
    }
    return best;
}

/// Is the output's `lib/libgbm.so` an ELF object this build can link?
///
/// The nix store holds one mesa-libgbm per platform the closure ever
/// referenced: on this machine there is an x86-64 build AND an i386 one
/// with the same name and version, and picking the wrong one gives
/// "libgbm.so is incompatible with elf64-x86-64" at link time. The
/// version comparison cannot tell them apart, so the ELF header decides.
fn elfMatchesTarget(b: *Build, store_entry: []const u8) bool {
    const lib = std.fs.path.join(b.allocator, &.{ "/nix/store", store_entry, "lib", "libgbm.so" }) catch
        @panic("OOM");
    var f = std.Io.Dir.openFileAbsolute(b.graph.io, lib, .{}) catch return false;
    defer f.close(b.graph.io);
    var hdr: [20]u8 = undefined;
    const n = f.readStreaming(b.graph.io, &.{&hdr}) catch return false;
    // e_ident: magic, EI_CLASS (2 = ELFCLASS64), EI_DATA (1 = little).
    if (n < hdr.len or !std.mem.eql(u8, hdr[0..4], "\x7fELF")) return false;
    if (hdr[4] != 2 or hdr[5] != 1) return false;
    // e_machine at offset 18, little-endian.
    const machine = std.mem.readInt(u16, hdr[18..20], .little);
    return machine == elfMachineFor(builtin.cpu.arch);
}

fn elfMachineFor(arch: std.Target.Cpu.Arch) u16 {
    return switch (arch) {
        .x86_64 => 62, // EM_X86_64
        .aarch64 => 183, // EM_AARCH64
        .arm => 40, // EM_ARM
        .riscv64 => 243, // EM_RISCV
        .powerpc64 => 21, // EM_PPC64
        .s390x => 22, // EM_S390
        .loongarch64 => 258, // EM_LOONGARCH
        // An arch we do not know the machine number for: refuse rather
        // than link an object for the wrong platform.
        else => 0xffff,
    };
}

/// Dotted-numeric "is `a` newer than `b`" ("" is older than everything, so
/// the first match always wins).
fn versionNewer(a: []const u8, b: []const u8) bool {
    if (b.len == 0) return true;
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const an = ai.next();
        const bn = bi.next();
        if (an == null and bn == null) return false;
        const av = if (an) |v| std.fmt.parseInt(u32, v, 10) catch return false else 0;
        const bv = if (bn) |v| std.fmt.parseInt(u32, v, 10) catch return false else 0;
        if (av != bv) return av > bv;
    }
}
