//! Test root for the server executable (src/server/main.zig).
//!
//! exe_tests cannot reuse the executable's root module directly: main.zig
//! declares its own `pub fn main(init: std.process.Init)`, which a test
//! binary built from that root would keep as its entry and then panic on
//! the runner's `--listen=-` protocol args. This root declares no main, so
//! the test runner becomes the entry. The comptime import plus the
//! refAllDecls test below still force full analysis of main.zig's decls
//! (AGENTS.md gate-5: unused decls still type-check), and any `test`
//! blocks added to main.zig run here.
//!
//! The module deps (wayland, zio, tracy, build_options, tracy_impl,
//! raylib_c) mirror server_exe.root_module's imports; build.zig wires them
//! before this file is compiled.

const std = @import("std");
const main_mod = @import("main.zig");

comptime {
    _ = main_mod;
}

test {
    std.testing.refAllDecls(main_mod);
}
