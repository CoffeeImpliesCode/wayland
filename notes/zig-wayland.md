# zig-wayland: wayland spec parsing and codegen for Zig 0.16

Research date: 2026-08-07. For: a Zig 0.16 compositor in this repo.

## Status table

| Project | Home | Zig support | Fork / mirror | Status |
|---|---|---|---|---|
| zig-wayland | codeberg.org/ifreund/zig-wayland | Zig 0.16 (min_zig 0.16.0, v0.7.0-dev) | GitHub mirror ifreund/zig-wayland, sr.ht mirror | ACTIVE, pushed 2026-07-14 |
| zig-wlroots | codeberg.org/ifreund/zig-wlroots | Zig 0.16 + wlroots 0.20 | GitHub swaywm/zig-wlroots | ACTIVE, pushed 2026-05-10 |
| river | codeberg.org/riverwm/river | Zig 0.16 | — | Main consumer of both |
| zig-wayland forks | GitHub | — | seanpm2001 (2022), kdchambers (2024), zoriya (2023) | ALL DEAD, no zig version claims |
| wayland.zig (tiawl) | github.com/tiawl/wayland.zig | stable branch, active 2026-08-02 | not a fork; C-headers package | ALTERNATIVE, 5 stars |
| Local clone | ~/projects/codeberg-ifreund-zig-wayland | Zig 0.13 (10 mo old) | — | STALE, do not use |

Local clone confirmed stale: README says "Zig 0.13", src files are 10 months old,
build.zig uses removed 0.13-era API (`root_source_file`, `addCSource` workaround).
Delete or refresh it.

## What zig-wayland is

- Zig scanner and protocol bindings for libwayland. Not a wrapper around
  wayland-scanner; it is its own code generator written in Zig.
- Scanner interface integrated into build.zig. Generates one `wayland.zig`
  module with `client`, `server`, and `common` namespaces.
- Covers wayland core (wl_*), wayland-protocols XMLs (xdg-shell, layer-shell,
  ext-session-lock, color-management-v1, presentation-time, ...), wlr
  protocols, and custom XML. The `wlr` namespace comes from wlroots.xml.
- libwayland C functions are declared as `extern` in generated `ffi` struct
  (src/ffi.zig), or imported from a user module via `ffi_import` option
  (allows dlopen at runtime).
- MIT license.

## Scanner mechanics (current main, Zig 0.16)

Pipeline in build.zig + src/scanner.zig:

1. `Scanner.create(b, .{})` builds `zig-wayland-scanner` executable from
   `src/scanner.zig` and registers a `b.addRunArtifact` step. Output goes to a
   LazyPath named `wayland.zig`.
2. Default spec locations resolved via pkg-config at configure time:
   - `pkg-config --variable=pkgdatadir wayland-scanner` + `wayland.xml`
   - `pkg-config --variable=pkgdatadir wayland-protocols`
   Both overridable with `Options.wayland_xml` / `Options.wayland_protocols`
   (now `Build.LazyPath`, so they can point at vendored files).
3. `scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml")` adds `-i`
   arg relative to wayland-protocols install. `addCustomProtocol(LazyPath)`
   adds any local XML.
4. `scanner.generate("wl_seat", 4)` adds `-g <global> <version>` args. Code is
   generated ONLY for the named global and interfaces reachable from it, up to
   the given version. wl_display, wl_registry, wl_callback, wl_buffer always
   generated. Requesting a version newer than the XML provides is a fatal
   build error (forwards-compat guard).
5. scanner.zig CLI: `-i <xml>` (repeatable), `-g <global> <version>`
   (repeatable), `-o <out>`, `-f <ffi import>`.
6. Parsing: `src/xml.zig` is a hand-written XML parser (event-based, no
   libxml dependency). `Protocol.parseXML` builds a tree: interfaces, requests,
   events, enums, args with types (int, uint, fixed, string, object, new_id,
   fd, array) and since/version attributes.
7. Emission: per protocol namespace (e.g. `wl`, `xdg_shell`, `wlr`) the scanner
   writes `pub const client.<ns>`, `pub const server.<ns>`, `const
   common.<ns>`. The `wl` namespace embeds hand-written cores
   (wayland_client_core.zig, wayland_server_core.zig, common_core.zig).
   Generated types are structs of zig-wayland's own design: Base, Listener,
   Requests, Events, Version, etc., with `void`/struct-style message
   signatures (no C ABI structs).
8. Sanity pass: generated source is re-parsed with `std.zig.Ast.parse` and
   re-rendered; parse errors abort the build with `error.ParseError`.
9. Tests: `test/snapshot.zig` diffs generated output against
   `test/snapshot_expected.zig` (needs `--enable-tests`); `test/ref_all.zig`
   compiles all generated code against real libwayland.
10. The old `scanner.addCSource(exe)` workaround for zig issue #131 is GONE
    in current main. The 0.16 build.zig only links `wayland-client` etc.
    The 0.13-era workaround used `wayland-scanner private-code` to emit C
    protocol tables; current main generates everything in Zig.

Limitation (README): scanner does no strict XML validation and gives poor
errors on malformed XML; README recommends `wayland-scanner --strict` for
debugging protocol XML.

## Zig version support and forks

- Main repo tracks current Zig: build.zig.zon says `.minimum_zig_version =
  "0.16.0"`, version 0.7.0-dev, dependency name `.wayland`. README: "Zig 0.16
  bindings and protocol scanner for libwayland." No fork needed for 0.16.
- Fork survey (all stale): seanpm2001/IFreund_Zig-WayLand (2022 archive copy),
  kdchambers/zig-wayland (2024), zoriya/zig-wayland (2023 "nightly" fork,
  dead). None carries 0.16 claims; upstream is the maintained line.
- Alternative: tiawl/wayland.zig packages freedesktop C headers for Zig
  (translate-c style, unlicense, 5 stars, active). Different approach (header
  bindings vs XML scanner); not a zig-wayland fork.
- zig version churn is the real risk: each Zig release historically broke the
  scanner build (0.13 -> 0.14 -> 0.16 all required updates). Pin the
  dependency and update deliberately.

## wlroots bindings story

- zig-wlroots: idiomatic Zig bindings for wlroots, Zig 0.16 + wlroots 0.20.
  Version scheme `major.minor.revision` matches the wlroots release (e.g.
  0.20.x). Depends on zig-wayland, zig-xkbcommon, zig-pixman.
- Not generated from XML: bindings are hand-written against wlroots C
  headers, added as river needs them ("I only personally add bindings for new
  parts of the wlroots API as required by river").
- river is the proof of completeness: a full compositor on these bindings.
- wlrfx/zig-wlroots is a scenefx fork (Zig 0.11 + wlroots 0.16, adds rounded
  corners / shadows) — stale and off-version, do not use.
- wlroots protocols (wlr-layer-shell, wlr-foreign-toplevel-management,
  wlr-screencopy, wlr-data-control, wlr-virtual-pointer, wlr-output-power-
  management, wlr-gamma-control, wlr-export-dmabuf, wlr-input-inhibitor,
  wlr-output-layout) are plain wayland XML in the wlroots repo
  (protocol/*.xml), built into a single installed `wlroots.xml` and scanned
  by zig-wayland like any other XML.

## Where specs live

- wayland.xml: source at gitlab.freedesktop.org/wayland/wayland
  (protocol/wayland.xml); installed via the `wayland` package, found through
  `pkg-config --variable=pkgdatadir wayland-scanner`.
- wayland-protocols XMLs: gitlab.freedesktop.org/wayland/wayland-protocols;
  installed under stable/, staging/, unstable/; found via
  `pkg-config --variable=pkgdatadir wayland-protocols`.
- wlroots.xml: assembled in the wlroots repo from protocol/*.xml
  (gitlab.freedesktop.org/wlroots/wlroots).
- On NixOS, pkg-config paths resolve inside the dev output; for hermetic
  builds vendor the XMLs and pass `Options.wayland_xml` /
  `Options.wayland_protocols` (LazyPaths).

## Usage patterns

- As build.zig.zon dependency: `.name = .wayland`, version 0.7.0-dev or a
  tagged release, fingerprint 0xa8d655e92b50695. Import as a module:
  `const wayland = b.dependency("wayland", .{}); const scanner =
  wayland.module("scanner").create(b, .{});` then
  `b.createModule(.{ .root_source_file = scanner.result })` (mirror the
  example in example/hello, which shows the current 0.16 build.zig.zon
  wiring).
- Generate only what you use: `scanner.generate("wl_compositor", 5)` etc.
  per global; the scanner trims to reachable interfaces, keeping compile
  time and binary size down.
- Alternative: vendor the generated wayland.zig into the repo (run scanner
  once, commit output) for hermetic builds with no pkg-config dependency at
  configure time. Tradeoff: manual regeneration on spec/zig upgrades.

## Recommendation for this repo

- Use upstream ifreund/zig-wayland (main, v0.7.0-dev or newer) as a
  build.zig.zon dependency. It is the only maintained line and already
  targets Zig 0.16.0, matching this repo's toolchain.
- For the compositor, also take zig-wlroots (Zig 0.16 + wlroots 0.20) unless
  the plan is a from-scratch compositor; river + tinywl are working
  references.
- For server-side protocol handling, zig-wayland generates both client and
  server namespaces, so xdg-shell / layer-shell / wlr protocols come from the
  same scan.
- Prefer addSystemProtocol over addCustomProtocol: keep spec versions pinned
  by the system packages; use Options.wayland_xml/wayland_protocols to point
  at vendored XMLs for NixOS hermeticity.
- Do NOT use the stale local clone (~/projects/codeberg-ifreund-zig-wayland,
  Zig 0.13) as a reference; read upstream main instead.

## Risks

- Zig churn: scanner breaks on each new Zig release until upstream updates
  (historically lagged). Mitigate: pin dependency hash, upgrade deliberately.
- Zero strict XML validation: malformed spec XML yields poor errors; validate
  with `wayland-scanner --strict` first.
- Version pinning: generated code is only as new as the installed
  wayland-protocols / wlroots versions; stale system packages silently
  produce older interfaces.
- zig-wlroots coverage is river-driven: bindings for wlroots APIs river does
  not use may be missing (must be added by hand).
- Build-time codegen adds a pkg-config dependency at configure time
  (wayland-scanner, wayland-protocols must be present); vendored XMLs +
  LazyPath options remove this.
- [UNVERIFIED] Whether the 0.16 toolchain still needs the C-table workaround
  (zig issue #131) for exotic protocols; current main and example/hello
  build without addCSource, so assume it is resolved.

## Sources

- github.com/ifreund/zig-wayland (README, files, build.zig, build.zig.zon)
- codeberg.org/ifreund/zig-wayland (canonical repo, issue tracker)
- api.github.com/search/repositories?q=zig-wayland+in:name
- api.github.com/repos/ifreund/zig-wayland/forks
- raw.githubusercontent.com/ifreund/zig-wayland/main/src/scanner.zig
- raw.githubusercontent.com/ifreund/zig-wayland/main/build.zig
- swaywm/zig-wlroots README; wlrfx/zig-wlroots README
- api.github.com/search/repositories?q=zig-wlroots
- github.com/tiawl/wayland.zig
- Local: ~/projects/codeberg-ifreund-zig-wayland (README.md, build.zig, src/)
- gitlab.freedesktop.org/wayland/wayland, /wayland/wayland-protocols,
  /wlroots/wlroots (spec locations)
