# zig-wayland: wayland spec parsing and codegen for Zig 0.16

Research date: 2026-08-07. For: a Zig 0.16 compositor in this repo. Upstream
facts re-verified 2026-08-07 via codeberg/GitHub APIs, raw file reads, and
git ls-remote. No [UNVERIFIED] markers remain.

## Status table

| Project | Home | Zig support | Fork / mirror | Status |
|---|---|---|---|---|
| zig-wayland | codeberg.org/ifreund/zig-wayland | Zig 0.16 (min_zig 0.16.0; last tag v0.6.0, main v0.7.0-dev) | GitHub mirror ifreund/zig-wayland, sr.ht mirror | ACTIVE, not archived; 6 releases (v0.1.0..v0.6.0); GH mirror pushed 2026-07-14, codeberg updated 2026-07-29 |
| zig-wlroots | codeberg.org/ifreund/zig-wlroots | Zig 0.16 + wlroots 0.20 (last tag v0.20.1, 2026-04-25; master v0.20.2-dev) | GitHub mirror swaywm/zig-wlroots, sr.ht mirror | ACTIVE, pushed 2026-05-10 |
| river | codeberg.org/riverwm/river | Zig 0.16 | — | Main consumer of both; pins zig-wlroots v0.20.1 |
| zig-wayland forks | GitHub | — | seanpm2001/IFreund_Zig-WayLand (push 2022-06-02), kdchambers (2024-08-13), zoriya (2023-12-22) | ALL DEAD (none archived, unpushed >= 2 y, no 0.16 claims) |
| wayland.zig (tiawl) | github.com/tiawl/wayland.zig | stable branch, active 2026-08-02 | not a fork; C-headers package | ALTERNATIVE, 5 stars |
| Local clone | ~/projects/codeberg-ifreund-zig-wayland | Zig 0.13 (10 mo old) | — | STALE, do not use |

Local clone confirmed stale: README says "Zig 0.13", src files are 10 months
old, build.zig uses removed 0.13-era API (`root_source_file`, `addCSource`). Delete or refresh it.

## What zig-wayland is

- Zig scanner and protocol bindings for libwayland (MIT). Not a wrapper around wayland-scanner; its own code generator written in Zig.
- Scanner integrated into build.zig; generates one `wayland.zig` with `client` and `server` namespaces (`common` went non-public in v0.3.0).
- Covers wayland core (wl_*), wayland-protocols XMLs (xdg-shell, layer-shell, ext-session-lock, color-management-v1, presentation-time, ...), wlr protocols (`wlr` namespace from wlroots.xml), and custom XML.
- libwayland C functions declared `extern` in generated `ffi` struct (src/ffi.zig), or imported via `ffi_import` option (allows dlopen).

## Scanner mechanics (current main, Zig 0.16)

1. Consumer build.zig: `const Scanner = @import("wayland").Scanner` (the dep's build.zig, named `.wayland` in the zon — Zig 0.16 mechanism). `Scanner.create(b, .{})` builds the `zig-wayland-scanner` executable from src/scanner.zig (via `b.dependencyFromBuildZig` as a dep), registers `b.addRunArtifact`; output is a LazyPath named `wayland.zig`.
2. Spec locations via pkg-config at configure time: `pkg-config --variable=pkgdatadir wayland-scanner` + `wayland.xml`, and the wayland-protocols pkgdatadir. Overridable with `Options.wayland_xml` / `Options.wayland_protocols` (`Build.LazyPath`, vendoring). `PKG_CONFIG` env var honored (v0.5.0).
3. `addSystemProtocol("stable/xdg-shell/xdg-shell.xml")` adds `-i` relative to the wayland-protocols install; `addCustomProtocol(LazyPath)` any local XML.
4. `generate("wl_seat", 4)` adds `-g <global> <version>`: code only for the named global and interfaces reachable from it, up to that version. wl_display, wl_registry, wl_callback, wl_buffer always generated. Requesting a version newer than the XML declares is a fatal build error (forwards-compat guard, build.zig doc). CLI: `-i` (repeatable), `-g` (repeatable), `-o <out>`, `-f <ffi import>`.
5. Parsing: `src/xml.zig`, hand-written event-based XML parser (no libxml); builds interfaces, requests, events, enums, args (int, uint, fixed, string, object, new_id, fd, array) with since/version attrs.
6. Emission: per protocol namespace (`wl`, `xdg_shell`, `wlr`) writes `pub const client.<ns>` / `pub const server.<ns>`; the `wl` namespace embeds hand-written cores (wayland_client_core.zig, wayland_server_core.zig, common_core.zig). Types are zig-wayland structs (Base, Listener, Requests, Events, Version...), `void`/struct-style messages, no C ABI.
7. Sanity: output re-parsed with `std.zig.Ast.parse`; errors abort the build. Tests: `test/snapshot.zig` diffs vs `snapshot_expected.zig`; `ref_all.zig` compiles all generated code against real libwayland.
8. The `addCSource` workaround for zig issue #131 is GONE (removed v0.3.0, 2025-03-07); current main generates everything in Zig.

Limitation (README): no strict XML validation, poor errors on malformed XML; README recommends `wayland-scanner --strict` for debugging protocol XML.

## Build integration recipe (verified 2026-08-07, upstream README + build.zig)

Dependency entry in build.zig.zon — the exact pin used by both river and zig-wlroots:

```zig
.wayland = .{
    .url = "https://codeberg.org/ifreund/zig-wayland/archive/v0.6.0.tar.gz",
    .hash = "wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX",
},
```

plus `.fingerprint = 0xa8d655e92b50695` in the root zon. Path alternative: example/hello uses `.wayland = .{ .path = "../.." }`.

build.zig wiring (upstream README snippet, current 0.16 API):

```zig
const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/private_foobar.xml"));

    // Pass the maximum version you implement; newer requests/events/enums
    // are not generated (forwards compatibility with newer protocol XML).
    scanner.generate("wl_seat", 4);
    scanner.generate("xdg_wm_base", 3);

    const exe = b.addExecutable(.{
        .name = "foobar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("foobar.zig"),
            .target = target, .optimize = optimize, .link_libc = true,
        }),
    });
    exe.root_module.addImport("wayland", wayland);
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    b.installArtifact(exe);
}
```

Options: `.wayland_xml`, `.wayland_protocols` (`?Build.LazyPath`, null -> pkg-config), `.ffi_import` (`?[]const u8`, module providing libwayland functions, e.g. dlopen). `generate()` also emits every interface creatable from the global at that version (wl_seat -> wl_keyboard, wl_pointer, ...).

Generated code: one file `wayland.zig`; `const wayland = @import("wayland"); const wl = wayland.client.wl;`. Server side from the same scan; link `wayland-server` instead of `wayland-client`.

Where protocol XMLs live:
- wayland.xml: gitlab.freedesktop.org/wayland/wayland (protocol/wayland.xml), via `pkg-config --variable=pkgdatadir wayland-scanner`.
- wayland-protocols: gitlab.freedesktop.org/wayland/wayland-protocols (stable/, staging/, unstable/), via `pkg-config --variable=pkgdatadir wayland-protocols`.
- wlroots.xml: assembled from protocol/*.xml in the wlroots repo (gitlab.freedesktop.org/wlroots/wlroots).

NixOS / hermetic: `PKG_CONFIG` env var honored, so dev-shells exporting it work. For hermetic builds, vendor wayland.xml + wayland-protocols and pass `Options.wayland_xml` / `Options.wayland_protocols` (zig-wayland vendors wayland.xml for its own snapshot tests — proof the pattern). Alternative: vendor the generated wayland.zig itself (no pkg-config at configure time; manual regeneration on spec/Zig upgrades).

## Zig version support and forks

- Releases track Zig exactly: v0.1.0 2024-05-19 (Zig 0.12), v0.2.0 2024-06-07 (0.13), v0.3.0 2025-03-07 (0.14; addCSource removed, snapshot tests), v0.4.0 2025-08-22 (0.15), v0.5.0 2026-03-15 (0.15; ffi_import), v0.6.0 2026-04-25 (0.16). main = v0.7.0-dev. No fork needed for 0.16.
- Fork survey (GitHub API 2026-08-07): seanpm2001/IFreund_Zig-WayLand (fork 2022-06-06, push 2022-06-02, 1 star, archive snapshot), kdchambers (fork 2022-07-06, push 2024-08-13, 1 star), zoriya (fork 2023-12-22, push same day, 0 stars, "forked to update to zig's nightly"). None archived; none with 0.16 claims.
- C-table / zig issue #131 RESOLVED: v0.3.0 removed `addCSource` ("no longer necessary"); current main and example/hello build without it.
- Alternative: tiawl/wayland.zig packages freedesktop C headers (translate-c style, unlicense, 5 stars, active). Different approach; not a fork.

## wlroots bindings story

- zig-wlroots: idiomatic Zig bindings for wlroots. Version scheme `major.minor.revision` mirrors the wlroots release; revision bumps per zig-wlroots release. Deps (build.zig.zon): zig-wayland v0.6.0, zig-pixman v0.3.0, zig-xkbcommon v0.3.0.
- wlroots 0.20 IS a released series, not a branch/master target: gitlab tags 0.20.0, 0.20.1, 0.20.2 exist (latest 0.20.2). Current zig-wlroots line: v0.20.1 (2026-04-25, "updates the required Zig version to 0.16"), master v0.20.2-dev. river pins zig-wlroots v0.20.1 (river build.zig.zon) <-> wlroots 0.20.x.
- A wlroots 0.18 binding line EXISTS (v0.18.0 2024-07-22, v0.18.1 2024-12-09, v0.18.2 2025-03-07) but is Zig 0.13/0.14-era, not usable with Zig 0.16. The local wlroots clone (0.18.3) predates the pin; refresh to 0.20.x.
- Hand-written against wlroots C headers, added as river needs them (README: "I only personally add bindings for new parts of the wlroots API as required by river"). Recent additions: ext-foreign-toplevel-list-v1 (v0.19.2), Swapchain + ext-data-control-v1 (v0.19.4), xdg-foreign-v2 (v0.20.1).
- wlrfx/zig-wlroots is a scenefx fork (Zig 0.11 + wlroots 0.16, rounded corners/shadows) — stale and off-version, do not use.
- wlroots protocols (wlr-layer-shell, wlr-foreign-toplevel-management, wlr-screencopy, wlr-data-control, wlr-virtual-pointer, wlr-output-power-management, wlr-gamma-control, wlr-export-dmabuf, wlr-input-inhibitor, wlr-output-layout) are plain wayland XML in the wlroots repo (protocol/*.xml), built into one installed `wlroots.xml` and scanned like any other XML.

## Usage patterns

- Generate only what you use: one `generate()` per global at the version you implement; the scanner trims to reachable interfaces (compile time, binary size).
- Prefer `addSystemProtocol` over `addCustomProtocol` (spec versions pinned by system packages); use `Options.wayland_xml` / `Options.wayland_protocols` for vendored XMLs on NixOS.
- Or vendor the generated wayland.zig into the repo. Tradeoff: manual regeneration on spec/Zig upgrades.

## Recommendation for this repo

- Use upstream ifreund/zig-wayland (v0.6.0 tag or newer main) as a pinned build.zig.zon dependency; the only maintained line, already targets Zig 0.16.0, matching this repo's toolchain.
- Take zig-wlroots v0.20.x (Zig 0.16 + wlroots 0.20) unless the plan is a from-scratch compositor; river + tinywl are working references.
- Server-side protocol handling comes from the same scan (client + server namespaces), so xdg-shell / layer-shell / wlr protocols need no extra step.
- Do NOT use the stale local clone (~/projects/codeberg-ifreund-zig-wayland, Zig 0.13) as a reference; read upstream main instead.

## Risks

- Zig churn: every Zig release historically forces a zig-wayland (and zig-wlroots) release. Evidence (tags): 0.13 -> v0.2.0 (2024-06-07), 0.14 -> v0.3.0 (2025-03-07), 0.15 -> v0.4.0 (2025-08-22), 0.16 -> v0.6.0 (2026-04-25); lag weeks to ~9 months. Mitigate: pin hash, upgrade deliberately.
- Zero strict XML validation: malformed spec XML yields poor errors; validate with `wayland-scanner --strict` first (README).
- Version pinning: generated code only as new as the installed wayland-protocols / wlroots; stale system packages silently produce older interfaces.
- zig-wlroots coverage is river-driven: bindings for wlroots APIs river does not use may be missing (added by hand). The wlroots C API is unstable (`WLR_USE_UNSTABLE`) and changes per release; the binding track must be bumped per wlroots release.
- Build-time codegen needs pkg-config at configure time (wayland-scanner, wayland-protocols present); vendored XMLs + LazyPath options remove this.
- Minor: zig-wlroots build.zig.zon says `minimum_zig_version = "0.14.0"` while v0.20.1 requires Zig 0.16 — trust the README/changelog, not the zon.

## Sources

- codeberg.org/api/v1/repos/ifreund/zig-wayland and .../tags — status, release dates, changelogs (verified 2026-08-07)
- api.github.com/repos/ifreund/zig-wayland — mirror, pushed 2026-07-14
- api.github.com/repos/seanpm2001/IFreund_Zig-WayLand, .../kdchambers, .../zoriya — fork dates
- raw.githubusercontent.com/ifreund/zig-wayland/main/{README.md, build.zig, build.zig.zon} — recipe, Options API, versioning
- api.github.com/search/repositories?q=zig-wlroots — swaywm/zig-wlroots (pushed 2026-05-10); raw.../swaywm/zig-wlroots/master/{README.md, build.zig.zon} — versioning, pins
- codeberg.org/api/v1/repos/ifreund/zig-wlroots/tags — release-line history
- raw.githubusercontent.com/riverwm/river/master/build.zig.zon — v0.20.1 pin
- `git ls-remote --tags` gitlab.freedesktop.org/wlroots/wlroots.git — tags incl. 0.20.0/0.20.1/0.20.2
- `git -C ~/projects/freedesktop-wlroots-wlroots describe --tags` — clone at 0.18.3
- github.com/tiawl/wayland.zig
- Local: ~/projects/codeberg-ifreund-zig-wayland — stale clone
