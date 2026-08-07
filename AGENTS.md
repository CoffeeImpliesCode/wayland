# Wayland Research

Research-and-prototype repo for a future Wayland compositor on a large 2D/3D canvas. `notes/` holds research. README.md indexes it.

## Project

- Goal: a Wayland compositor rendering onto an infinite 2D/3D canvas.
- Compositor layer: wlroots/smithay-style.
- Usage layer: dynamicland-inspired.
- Usage layer: dynamicland-inspired.
- **Always consult your inspirations** (wlroots/smithay for compositor design, dynamicland for canvas/usage design) before answering design or implementation questions — foreign clones and deepwiki are the reference material.
- Stack: Zig 0.16.0 (stable).
- Status: research. No compositor code yet.
- VCS: jj. Never use git commands.

## Repo Layout

```
wayland/
├── build.zig, build.zig.zon   # scanner wiring (zig-wayland v0.6.0 dep)
├── protocols/                 # vendored protocol XMLs (wayland, wayland-protocols, wlroots)
├── src/                       # root.zig (lib re-exports bindings), main.zig (skeleton)
├── notes/                     # research notes, one topic per file
├── devenv.nix, .envrc         # nix dev shell (sets PKG_CONFIG_PATH for wayland)
└── README.md                  # indexes notes/
```

| Task | Location |
| --- | --- |
| Read research | `notes/*.md`, indexed by README.md |
| Design authority | `notes/zig-compositor-lib-spec.md` — the own zig compositor library spec |
| Verify wlroots claims | `~/projects/freedesktop-wlroots-wlroots` |
| Verify smithay claims | `~/projects/github-Smithay-smithay` |
| Check zig-wayland bindings | `~/projects/codeberg-ifreund-zig-wayland` (v0.6.0, zig 0.16 — refreshed) |
| Architecture questions | deepwiki MCP — smithay and wlroots have wikis |

Foreign clones are read-only references. Never modify them.

## Zig 0.16.0 — API Facts

Training data predates these changes. Check `zig env` and local std sources before trusting old patterns. Reference: https://ziglang.org/download/0.16.0/release-notes.html

### std.Io era

- `std.Io` is the unified I/O interface. Thread `io: std.Io` through every function that does I/O, sleep, random, or time.
- `std.net` is removed. Use `std.Io.net` (requires `io`).
- Prefer `pub fn main(init: std.process.Init) !void`. `init.gpa`, `init.io`, `init.arena`, `init.environ_map`. Env vars and argv exist only through `init` — no globals.
- `std.time.timestamp()/milliTimestamp()/nanoTimestamp()` removed. Use `std.c.clock_gettime(.REALTIME, &ts)` for wall time. Monotonic time (VERIFIED): `std.Io.Clock.now(.awake, io.*)` returns `Io.Timestamp{ nanoseconds: i96 }` (`.awake` = CLOCK_MONOTONIC; no `.monotonic` member); signed math needs `@divTrunc`. Sleep: `std.Io.sleep(io, duration, .clock)` — take `io` BY VALUE everywhere (`io.*` when the param is `*std.Io`).
- `std.Thread.Mutex` / `Condition` / `sleep` removed. Use pthread shims (`std.c.pthread_mutex_*`, `std.c.nanosleep`) or `std.Io.Mutex` / `std.Io.Condition`.
- `std.Thread.Pool` removed. Use `std.Io.Group` with `std.Io.async` / `std.Io.concurrent`.
- `std.Thread.spawn` still exists: `std.Thread.spawn(.{}, fn, args)`.
- `std.crypto.random` removed. Use `std.Io.randomSecure(io, buf)` or `std.os.linux.getrandom`.
- Writers/readers are `std.Io.Writer` / `std.Io.Reader` — non-generic, buffer lives in the interface. Lowercase `std.io` is gone. Files are `std.Io.File`:

  ```zig
  var buf: [4096]u8 = undefined;
  var w = std.Io.File.stdout().writer(io.*, &buf); // Io by value
  try w.interface.print("x = {d}\n", .{x});
  try w.interface.flush(); // always flush
  ```
- Prefer `std.Io.File.stderr().writerStreaming(io.*, &buf)` for logs: the positional `writer` pwrites at offset 0 per call on Io impls like zio's (lines overwrite each other); `writerStreaming` appends.
- `union` is a keyword: quote fn names as `@"union"`.

- Custom `format`: `pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void`. Call it with `{f}`.
- `std.debug.print` works (stderr). Locked stderr: `std.debug.lockStderr(&buf)`.
- File errors renamed: `error.CrossDevice`, `error.FileBusy`, `error.EnvironmentVariableMissing`.

### Memory and containers

- Allocators are explicit parameters. No global allocator state.
- `defer` cleanup next to acquisition; `errdefer` for error paths.
- `std.ArrayList` is unmanaged by default: methods take the allocator (`list.append(allocator, x)`, `list.deinit(allocator)`). Use `initCapacity(allocator, n)` or `.empty`. The managed variant (`std.array_list.Managed`) is deprecated.
- Hash maps (VERIFIED): `std.StringHashMapUnmanaged(u32) = .empty; try map.put(allocator, k, v); map.deinit(allocator);` — `StringHashMap` is the MANAGED variant without `.empty`.
- Init containers with `.empty` / `.init`, never `.{ }`.
- Test collection (VERIFIED): `zig test` runs tests only from ANALYZED declarations — a root that only `pub const`-imports modules collects 0 tests. Add `comptime { _ = module; }` for each module in the root to force analysis (pattern used in src/root.zig).
- Enum relational ops are illegal: compare with `@intFromEnum`.
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
- Fetch deps: `zig build` auto-fetches; `zig build --fetch` fetches only; `zig fetch <url>` prints the hash to paste. Fetched deps land in local `zig-pkg/` — commit them (house convention; hermetic builds).
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

- `AGENTS.md` updates are welcome. Keep this file under 260 lines.
- `notes/`: one topic per file. Name as `NNN-topic.md`.
- Note style: facts first, terse STE prose, no fluff, no emojis.
- Cite sources: URL inline or a per-section source list. Unverified claims get `[INFERENCE]`. Never fabricate.
- `web_search` can hang in subagents. Prefer `read` on URLs for web content;
  use web_search sparingly in the main session only.
- Foreign clones in `~/projects/<host>-<owner>-<repo>` are read-only:
  - `freedesktop-wlroots-wlroots` (0.20.2), `github-Smithay-smithay` (v0.7.0),
    `codeberg-ifreund-zig-wayland` (v0.6.0, zig 0.16) — refreshed 2026-08-07.
  - `freedesktop-wayland-wayland` (1.26.0), `freedesktop-wayland-wayland-protocols`
    (1.49), `freedesktop-wayland-weston` (16.0.0), `codeberg-ifreund-zig-wlroots`
    (v0.20.1), `codeberg-river-river` (v0.4.0), `github-WayfireWM-wayfire`
    (v0.11.0), `github-YaLTeR-niri` (v26.04), `github-swaywm-sway` (1.11-rc2),
    `github-labwc-labwc` (0.20.1), `github-wayvr-org-wayvr` (v26.7.1).
  - To use a zig dependency override, match its fingerprint and pass `zig build --fork`.

## Development

- Use `edit` for changes. Prefer narrow reads (`grep`/`glob`) over whole files.
- Delegate: research topics to scouts/librarians, edits to task agents.
- Notes are the deliverable. Do not run `zig build` or tests to validate a note.
- jj only: `jj commit -m "..."`. No git commands.

## Commands

```bash
zig version                              # expect 0.16.0
zig build                                # fetches zig-wayland, runs scanner, builds
zig build test                           # includes bindings compile-check test
devenv shell -c "zig build"              # or rely on direnv; PKG_CONFIG_PATH set there
zig translate-c -I include/ wlroots.h    # inspect C header translation
pkg-config --cflags --libs wlroots       # wlroots link flags
jj st / jj log                           # review changes
```

Generated bindings (from the scanner) live in `.zig-cache/` — never commit or
edit them. `protocols/` is the vendored spec source; regenerate by building.


## Hardcore quality bar (2026-08)

Applies Tiger Style (loose) + aggressive linting/coverage/verification +
mandatory post-implementation review. Read before coding:
`zig-tiger-style`, `zig-best-practices`, `zig-project`, `zig-linting`,
`zig-coverage`, `zig-testing`, `verification-before-completion`,
`code-review`, `jj-core`, `using-git-worktrees`.

- **Research repo**: notes are the deliverable — no build/test gates
  for note-only changes; gates apply once code exists.
- Foreign clones stay read-only references.
- Line-limit convention above updated from 200 to 260 for this section.

### Gates — definition of done (evidence in the same turn)
1. `zig fmt --check .` — zero diffs.
2. `zig build` Debug — exit 0.
3. `zig build test` Debug — all green, zero leaks (`std.testing.allocator`).
4. `zig ast-check` on every changed `.zig`.
5. `test { std.testing.refAllDecls(@This()); }` in each root — unused decls still type-check.
6. Linter — **ziglint** (project linter, house convention): `nix shell nixpkgs#ziglint -c ziglint src` — zero findings (Bugs + Style, minus unsafe-undefined; Z-rules, no .ziglint.zon, defaults).
7. Coverage on 0.16 = **kcov** (zcov/zig-cov needs 0.17-dev): `kcov kcov-out $(find ~/.cache/zig/o -name test -type f | head -1)` — every uncovered path is test / refactor / accept-with-written-reason.
8. Optional: `-fsanitize-c=full`, `-fsanitize-thread`, valgrind (`-fvalgrind`).
9. Parser/decoder changes: `zig build test --fuzz=<bounded>` (e.g. `--fuzz=10K`, Smith generators: value/valueRangeLessThan/eos/bytes/slice; crash inputs auto-replayed) — no crashes.
10. `zig build test --test-timeout 500ms` — catches hanging tests (run in CI/gates).

Density rule: 12/357 covered paths is noise; 352/357 makes each missing
path a judgment call. Coverage guides, never gates alone.

### Analysis tools (local binaries, verified 2026-08-07)
1. **ziglint** — `~/.local/bin/ziglint src --ignore Z030` (0.5.3; same version
   as nixpkgs#ziglint). Z030 (poison-as-last-statement) is excluded per house
   rule: on self-freeing deinits its only compliant form is a write through
   freed memory (proven by 10 test crashes); the Z-rules otherwise apply with
   defaults (no .ziglint.zon).
2. **zlint** (zlinter 0.16.x) — `cd src && ~/.local/bin/zlint` (bare: scans
   cwd; the dir argument is broken in this build; stdin mode
   `find src -name '*.zig' | zlint -S` also works). Rules:
   - `unsafe-undefined`: a `// SAFETY: <reason>` comment must sit on the line
     DIRECTLY ABOVE each intentional `undefined` — one comment does NOT cover
     the next line, and inline/trailing disable comments do NOT work. `= undefined`
     field defaults are forbidden — construct explicitly.
   - `avoid-as` → typed annotations; `no-print` → `std.log`.
3. **zbc** — `~/.local/bin/zbc src/ --disable=use_undefined` (lifetime/escape
   analyzer). `use_undefined` is disabled with justification: the signal
   init-later pattern (`.events = undefined` + `.init()`) is the wire-layer
   contract — `list.Head.init` sets self-referential links, so no zero-state
   exists and the analyzer-satisfying local-first variant is a latent
   use-after-scope (proven: 10 crashes). All other rules stay active:
   `heap-double-free`/`heap-use-after-free` are covered by the
   `impl.destroy(allocator, data)` ownership contract (impl frees only its
   data; the module frees the wrapper); `intfromfloat-without-clamp` →
   `std.math.lossyCast`; `forced-unwrap-iterator-next` → `orelse` forms.

### Reviewer workflow (mandatory after every implementation)
1. Run the gates; attach raw output (exit codes, counts) — no summaries.
2. Standards: tiger rules + Fowler smells (mysterious names, duplication,
   feature envy, primitive obsession, repeated switches, shotgun surgery,
   speculative generality, message chains, middle man, refused bequest).
   Repo rules override; smells are judgment calls.
3. Spec: re-read the task — missing requirements, scope creep, wrong
   implementations; quote the spec line per finding.
4. Spawn a reviewer subagent for non-trivial diffs; it re-runs gates
   1–3, 6–7 and both axes independently.
5. Fix at root cause; re-run failed gates.
6. Report shape:
   `GATES: fmt=… test=… leaks=… lint=… coverage=… | REVIEW: Standards N | Spec N | FIXED: … | SKIPPED (reason): … | DEBT: (ceiling + trigger)`
   3 failed fix attempts on one file → stop, escalate.

### Clean environment (jj)
- New work starts on a clean change. Dirty? `jj commit -m "wip: ..."`
  (checkpoint) or a fresh change — jj snapshots the working copy, so a
  dirty tree mixes new work with WIP and restore/abandon sweeps both.
- Parallel/risky work: `jj worktree add <path>`; detect existing
  isolation first, never nest. Editing subagents get their own isolated
  worktree/change.
- Baseline tests must pass before the first edit — a red suite is
  provably yours.

### AI-slop guard
- Obvious comments → remove; KEEP why-comments. Over-defensive checks →
  prove redundancy (keep boundary validation). Nesting >3 / god fns
  (>50 lines) / long param lists → restructure. Needless abstraction →
  delete. Dead code (unused decls, `std.debug.print` in non-test) →
  remove. Duplication → extract only shared intent. Missing tests → add
  the narrowest regression test, never remove code. >250 pure LOC
  modules → split by responsibility (never `utils.zig`). Performance
  equivalences → only when provably equivalent; unsure → SKIP. Silent
  skips forbidden; report `N/A` explicitly.
