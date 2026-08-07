# Wayland Research

Research-and-prototype repo for a future Wayland compositor on a large 2D/3D canvas. `notes/` holds research. README.md indexes it.

## Project

- Goal: a Wayland compositor rendering onto an infinite 2D/3D canvas.
- Compositor layer: wlroots/smithay-style.
- Usage layer: dynamicland-inspired.
- Stack: Zig 0.16.0 (stable).
- Status: research. No compositor code yet.
- VCS: jj. Never use git commands.

## Repo Layout

```
wayland/
├── build.zig, build.zig.zon   # zig-init defaults; extend, do not delete
├── src/                       # main.zig, root.zig — zig-init defaults
├── notes/                     # research notes, one topic per file
└── README.md                  # indexes notes/
```

| Task | Location |
| --- | --- |
| Read research | `notes/*.md`, indexed by README.md |
| Verify wlroots claims | `~/projects/freedesktop-wlroots-wlroots` |
| Verify smithay claims | `~/projects/github-Smithay-smithay` |
| Check zig-wayland bindings | `~/projects/codeberg-ifreund-zig-wayland` (8 months stale — verify upstream first) |
| Architecture questions | deepwiki MCP — smithay and wlroots have wikis |

Foreign clones are read-only references. Never modify them.

## Zig 0.16.0 — API Facts

Training data predates these changes. Check `zig env` and local std sources before trusting old patterns. Reference: https://ziglang.org/download/0.16.0/release-notes.html

### std.Io era

- `std.Io` is the unified I/O interface. Thread `io: std.Io` through every function that does I/O, sleep, random, or time.
- `std.net` is removed. Use `std.Io.net` (requires `io`).
- Prefer `pub fn main(init: std.process.Init) !void`. `init.gpa`, `init.io`, `init.arena`, `init.environ_map`. Env vars and argv exist only through `init` — no globals.
- `std.time.timestamp()/milliTimestamp()/nanoTimestamp()` removed. Use `std.c.clock_gettime(.REALTIME, &ts)` for wall time. Monotonic time: `std.Io.Clock.now(.monotonic, io)` / `std.Io.Timestamp.now(io, .monotonic)`. Sleep: `std.Io.sleep(io, duration, .monotonic)`.
- `std.Thread.Mutex` / `Condition` / `sleep` removed. Use pthread shims (`std.c.pthread_mutex_*`, `std.c.nanosleep`) or `std.Io.Mutex` / `std.Io.Condition`.
- `std.Thread.Pool` removed. Use `std.Io.Group` with `std.Io.async` / `std.Io.concurrent`.
- `std.Thread.spawn` still exists: `std.Thread.spawn(.{}, fn, args)`.
- `std.crypto.random` removed. Use `std.Io.randomSecure(io, buf)` or `std.os.linux.getrandom`.
- Writers/readers are `std.Io.Writer` / `std.Io.Reader` — non-generic, buffer lives in the interface. Lowercase `std.io` is gone. Files are `std.Io.File`:

  ```zig
  var buf: [4096]u8 = undefined;
  var w = std.Io.File.stdout().writer(io, &buf);
  try w.interface.print("x = {d}\n", .{x});
  try w.interface.flush(); // always flush
  ```

- Custom `format`: `pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void`. Call it with `{f}`.
- `std.debug.print` works (stderr). Locked stderr: `std.debug.lockStderr(&buf)`.
- File errors renamed: `error.CrossDevice`, `error.FileBusy`, `error.EnvironmentVariableMissing`.

### Memory and containers

- Allocators are explicit parameters. No global allocator state.
- `defer` cleanup next to acquisition; `errdefer` for error paths.
- `std.ArrayList` is unmanaged by default: methods take the allocator (`list.append(allocator, x)`, `list.deinit(allocator)`). Use `initCapacity(allocator, n)` or `.empty`. The managed variant (`std.array_list.Managed`) is deprecated.
- Hash maps likewise: `var map = std.StringHashMap(u32).empty; try map.put(allocator, k, v); map.deinit(allocator);`
- Init containers with `.empty` / `.init`, never `.{ }`.
- `std.heap.DebugAllocator(.{})` (GPA alias) for leak-checked dev allocation. `ArenaAllocator` is thread-safe in 0.16 — no `ThreadSafe` wrapper.
- Name allocators by contract: `gpa`, `arena`, `scratch`.

### Comptime and language

- `@Type` removed. Use `@Int(.signed, bits)`, `@Struct(...)`, `@Pointer(...)`, `@Fn(...)`, `@Tuple(...)`.
- `@typeInfo` tags are lowercase: `.@"struct"`, `.@"enum"`, `.slice`, `.int`.
- `usingnamespace` and `async`/`await` removed.
- `@branchHint(.cold)` replaces `@setCold`.
- `std.meta.intToEnum` removed; use `std.enums.fromInt(E, v)`.
- Signed division needs `@divTrunc` / `@divFloor` / `@divExact` — plain `/` errors on signed operands.
- Prefer `comptime T: type` over `anytype`. Use `@compileError` for invalid comptime configuration.
- Locals may not shadow module-level `extern fn` declarations — rename the local.

### Build system

- `root_source_file` is gone. Pass `root_module = b.createModule(.{...})` to `addExecutable` / `addTest` / `addLibrary`.
- Libraries: `b.addLibrary(.{ .linkage = .dynamic, ... })`. `addSharedLibrary` is gone.
- C-linkage methods moved to the module: `root_module.addIncludePath(...)`, `root_module.linkSystemLibrary("wlroots", .{})` (two-arg form), `root_module.addCSourceFile(.{...})`. Link libc via `.link_libc = true` in `createModule`.
- build.zig.zon: `.name` is an enum literal (`.wayland`, not `"wayland"`), `.fingerprint` required, dependencies use `.url` + `name-version-<hash>` hash.
- Fetch deps: `zig build` auto-fetches; `zig build --fetch` fetches only; `zig fetch <url>` prints the hash to paste. Fetched deps land in local `zig-pkg/` — do not commit.
- Local override: `zig build --fork=/path/to/fork` swaps any dependency with matching name + fingerprint.
- Add a dep:

  ```zig
  const dep = b.dependency("name", .{ .target = target, .optimize = optimize });
  exe.root_module.addImport("name", dep.module("name"));
  ```

- Build options: `b.option(T, "name", "desc")` + `b.addOptions()` + `root_module.addOptions("build_options", opts)`. Read via `@import("build_options")`.

### Testing

- Test blocks live next to the code. Run `zig build test` or `zig test src/foo.zig`. Filter with `--test-filter "name"`.
- Per-test timeout: `zig build test --test-timeout 500ms`.
- Use `std.testing.allocator` in tests — it reports leaks.
- Assertions: `expectEqual`, `expectEqualStrings`, `expectApproxEqAbs`, `expectError`, `expect`.
- Fuzz: test body calls `std.testing.fuzz(void, testFn, .{})`; the fuzz fn takes `*std.testing.Smith`. Run `zig build test --fuzz` or `--fuzz=10K`.
- No coverage tooling on stock 0.16 (kcov via DWARF works; zcov needs 0.17-dev).

### TigerStyle

- Safety > performance > developer experience.
- Simple explicit control flow. Loops have fixed upper bounds. No unbounded recursion.
- All errors handled. Never discard an error with `_`. Explicit error sets, not `anyerror`.
- Assert programmer errors at entry. Split compound asserts. Pair assertions.
- Naming: functions `camelCase`, types `PascalCase`, variables `snake_case`. Acronyms capitalized (`VSRState`). Append units/qualifiers: `latency_ms_max`. No abbreviated names. `gpa` / `arena` beat generic `allocator`.
- Explicitly sized integers (`u32`), not bare `usize` where avoidable.
- No hidden or unnecessary allocation. Init large structs via out pointers.
- `zig fmt` output, 100-column lines, 4-space indent. Braces on multi-line `if`.
- Zero-dependency policy where reasonable; wlroots/wayland bindings are the planned exception.

### Compiler, debugging, cross-compilation

- Modes: Debug (default; safety checks), ReleaseSafe (optimized + checks), ReleaseFast (no checks), ReleaseSmall. Validate under ReleaseSafe before ReleaseFast.
- `zig build -Doptimize=ReleaseFast test` catches UB that Debug misses.
- Debug: `std.debug.print` (stderr), `zig build run`. Panics carry source locations; error return traces show the `try` chain.
- gdb works on Debug builds (DWARF). Break `__zig_panic_start` to catch panics.
- `zig fmt --check`, `zig ast-check` for quick checks.
- Cross-compilation is built in: `zig build -Dtarget=aarch64-linux-gnu`, `zig cc` as a hermetic C compiler (musl bundled). No sysroot needed for pure Zig.

### C interop (wlroots is C)

- `@cImport` is deprecated in 0.16. Use `b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), ... })` in build.zig and import its module as `@import("c")`. The translator is arocc (not libclang); some headers regressed (GTK/glib) — verify your headers with `zig translate-c`.
- For small ABI-critical structs, hand-write `extern struct` (exact C layout) instead of translating whole headers. `packed struct` for bitfields; `opaque {}` for forward-declared C handles.
- C type mapping: `c_int`, `usize`/`isize` for size_t/ssize_t, `[*:0]const u8` for `const char*`, `*anyopaque` for `void*`. String literals coerce to `[*:0]const u8`.
- wlroots, wayland-server, wayland-client, xkbcommon are pkg-config libraries. Link via `root_module.linkSystemLibrary(...)`; add include dirs via `addIncludePath`. Check `pkg-config --cflags --libs wlroots` for the exact list.
- Match C ABI exactly: same field order and widths, `extern` layout. Verify with comptime `@sizeOf` / `@offsetOf` asserts.

## Repo Conventions

- `AGENTS.md` updates are welcome. Keep this file under 200 lines.
- `notes/`: one topic per file. Name as `NNN-topic.md`.
- Note style: facts first, terse STE prose, no fluff, no emojis.
- Cite sources: URL inline or a per-section source list. Unverified claims get `[INFERENCE]`. Never fabricate.
- Foreign clones in `~/projects/<host>-<owner>-<repo>` are read-only:
  - `freedesktop-wlroots-wlroots`, `github-Smithay-smithay` — fresh clones.
  - `codeberg-ifreund-zig-wayland` — 8 months stale. Check upstream state before trusting anything in it. To use it as a dependency override, match its fingerprint and pass `zig build --fork`.

## Development

- Use `edit` for changes. Prefer narrow reads (`grep`/`glob`) over whole files.
- Delegate: research topics to scouts/librarians, edits to task agents.
- Notes are the deliverable. Do not run `zig build` or tests to validate a note.
- jj only: `jj commit -m "..."`. No git commands.

## Commands

```bash
zig version                              # expect 0.16.0
zig translate-c -I include/ wlroots.h    # inspect C header translation
pkg-config --cflags --libs wlroots       # wlroots link flags
zig build test                           # when code exists
jj st / jj log                           # review changes
```
