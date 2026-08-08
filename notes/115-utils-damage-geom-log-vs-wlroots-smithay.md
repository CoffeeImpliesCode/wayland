# Utils (damage/geom/log) — wlroots/smithay diff

Scope: `src/utils/damage.zig`, `src/utils/geom.zig`, `src/utils/log.zig` vs wlroots 0.20.2 (`types/wlr_damage_ring.c`, `include/wlr/util/box.h`, `util/box.c`, `util/log.c`) and smithay v0.7.0 (`src/utils/geometry.rs`, `src/backend/renderer/damage/`, `src/backend/renderer/utils/mod.rs`). All citations file:line. `[INFERENCE]` marks unverified claims.

NOTE ON PATHS: the assignment cited `wlr/types/wlr_box.h`, `util/damage_ring.c`, and `src/renderer/...`. In this clone the box header is `include/wlr/util/box.h`, the damage ring is `types/wlr_damage_ring.c` (header `include/wlr/types/wlr_damage_ring.h`), and smithay's renderer is under `src/backend/renderer/`. Citations below use the real paths.

## Surface

Our public surface (grep `pub const`/`pub fn`):

**damage.zig**
- `pub const Damage` (damage.zig:13) — whole flag + rect list accumulator
- `Damage.init` (20), `Damage.deinit` (24), `Damage.clear` (29), `Damage.isEmpty` (34), `Damage.add` (39), `Damage.addWhole` (44), `Damage.boundingRect` (50)
- `pub const DamageRing` (72) — buffer-age damage history
- `DamageRing.init` (79), `DamageRing.deinit` (100), `DamageRing.add` (108), `DamageRing.addWhole` (113), `DamageRing.rotate` (119), `DamageRing.isEmpty` (139), `DamageRing.renderDamage` (151)

**geom.zig**
- `pub const Point` (8), `pub const Size` (10), `pub const Rect` (12)
- `Rect.empty` (18), `Rect.isEmpty` (22), `Rect.containsPoint` (26), `Rect.intersect` (32), `Rect.@"union"` (42)
- `pub const FPoint` (53), `pub const FSize` (55), `pub const FRect` (57)
- `pub const Transform` (65) + `isFlipped` (75), `is90Degrees` (79), `transformedSize` (84)

**log.zig**
- `pub const Level` (9) + `label` (17); `pub const Config` (28) + `levelFor` (39)
- `pub fn log` (42), `err` (74), `warn` (78), `info` (82), `debug` (86), `trace` (90)

## Comparison

### damage.zig

| Our fn (file:line) | Semantics (ours) | wlroots equivalent | smithay equivalent | Verdict | Note |
|---|---|---|---|---|---|
| `Damage` (damage.zig:13) | Region accumulator: `whole` bool + rect `ArrayList` | no direct type; `pixman_region32_t` used inline in `wlr_damage_ring` (types/wlr_damage_ring.c:16) | no accumulator type; `DamageSnapshot` (backend/renderer/utils/mod.rs:73) stores per-commit damage deque | close | `whole` bool replaces a full-extent pixman rect; smithay has no "whole" flag, it stores full-size rects instead `[INFERENCE]` |
| `Damage.init` (20) | allocates empty rect list | `wlr_damage_ring_init` pixman_region32_init (types/wlr_damage_ring.c:16) | `DamageSnapshot::new` (impl ~mod.rs:179) | close | |
| `Damage.deinit` (24) | frees rect list | `wlr_damage_ring_finish` (types/wlr_damage_ring.c:21) | drop of `DamageSnapshot` | close | |
| `Damage.clear` (29) | resets whole + rects, keeps capacity | `pixman_region32_clear` (types/wlr_damage_ring.c:111) | `reset()` clears deque + increments CommitCounter (mod.rs:198) | close | smithay couples clear to a commit counter; ours is bare clear |
| `Damage.isEmpty` (34) | true iff no whole and no rects | `pixman_region32_not_empty` (no direct call; damage ring doesn't expose) | N/A (no whole flag; empty = no rects) | ours-only | `[INFERENCE]` smithay infers emptiness from rect count |
| `Damage.add` (39) | append one rect (ignored if whole) | `wlr_damage_ring_add_box` unions rect into current region (types/wlr_damage_ring.c:40) | `DamageBag::add` accumulates into newest damage set (backend/renderer/utils/mod.rs:278) | close | ours stores each rect as a list element; pixman unions/covers overlap; smithay `DamageSnapshot::add` dedups rects (mod.rs:238-246) |
| `Damage.addWhole` (44) | set whole flag, drop rects | `wlr_damage_ring_add_whole` unions full buffer extents (types/wlr_damage_ring.c:47) | N/A — whole damage is just a full-size rect pushed via `add`; resizing forces full damage via `reset` (mod.rs:198) | close | our whole flag is an O(1) dominate-all; wlroots computes max buffer w/h; smithay uses a full rect |
| `Damage.boundingRect` (50) | union of rects; null if whole | no direct; pixman extents via `pixman_region32_extents` (types/wlr_damage_ring.c:127) | `Rectangle::merge`/`bounding_box` (geometry.rs:1384,1402) | close | |
| `DamageRing` (72) | current + history[N-1] per-buffer-age | `struct wlr_damage_ring` (types/wlr_damage_ring.c:16) | no ring; `OutputDamageTracker` recomputes damage from element CommitCounters (damage/mod.rs:570-582) | close | smithay architecture differs: it tracks per-element commit damage, not a per-buffer ring (below) |
| `DamageRing.init` (79) | pre-reserve N-1 history slots, assert N>=1 | `wlr_damage_ring_init` (types/wlr_damage_ring.c:16) | N/A | close | ours pre-allocates so rotate never allocates; wlroots lazy-links buffers |
| `DamageRing.deinit` (100) | free all slots | `wlr_damage_ring_finish` (types/wlr_damage_ring.c:21) | N/A | close | |
| `DamageRing.add` (108) | add rect to current | `wlr_damage_ring_add_box` (types/wlr_damage_ring.c:40) | `OutputDamageTracker` accumulates element damage into self.damage (damage/mod.rs:570-582) | close | |
| `DamageRing.addWhole` (113) | set current whole | `wlr_damage_ring_add_whole` (types/wlr_damage_ring.c:47) | full-size damage / geometry-change reset (damage/mod.rs:675-678) | close | |
| `DamageRing.rotate` (119) | age current into history[0], drop oldest, clear current; N==1 discards | `wlr_damage_ring_rotate_buffer` (types/wlr_damage_ring.c:103) | N/A — no rotation; damage is per CommitCounter distance | **divergent** | wlroots rotates per-buffer (2-ring semantics: current + linked buffer entries, squash on destroy via entry_squash_damage types/wlr_damage_ring.c:50). Ours is a fixed pre-allocated ring keyed by age, not by the actual buffer. wlroots keeps `WLR_DAMAGE_RING_MAX_RECTS`=20 rects and squashes to extents (types/wlr_damage_ring.c:13,119); ours never squashes rect count. This is the riskiest divergence (below). |
| `DamageRing.isEmpty` (139) | no damage in current nor history | `pixman_region32_not_empty` over ring | N/A | close | `[INFERENCE]` |
| `DamageRing.renderDamage` (151) | union of current + ALL history; null if whole or empty | `wlr_damage_ring_rotate_buffer` computes damage = current + every OTHER buffer's damage, clipped to buffer size (types/wlr_damage_ring.c:103-121) | `render_output` collects damage and clips to output via intersections (damage/mod.rs:500-582) | **divergent** | ours unions ALL history into one rect (approximation for repaint-all); wlroots excludes the currently-presented buffer's own damage and clips to buffer bounds; smithay clips damage to the output and subtracts opaque regions. Our renderDamage returns a single bounding rect, losing multi-rect precision. |

### geom.zig

| Our fn (file:line) | Semantics (ours) | wlroots equivalent | smithay equivalent | Verdict | Note |
|---|---|---|---|---|---|
| `Point` (geom.zig:8) | i32 point | `wlr_box` has no standalone point; used inline | `Point<N,Kind>` with Coordinate + Logical/Physical/Buffer markers (geometry.rs:385,10,19,23) | **divergent** | ours has NO Logical/Physical coordinate kind distinction; smithay statically enforces it at type level. Our i32 Point is untyped. |
| `Size` (geom.zig:10) | i32 size | wlr_box width/height fields | `Size<N,Kind>` (geometry.rs:768) | **divergent** | same missing kind-tag issue. smithay `Size::is_empty` (geometry.rs:862) checks `== 0` only, not negative |
| `Rect` (geom.zig:12) | i32 rect | `struct wlr_box {int x,y,width,height}` (include/wlr/util/box.h:29) | `Rectangle<N,Kind>` (geometry.rs:1177) | close | ours mirrors wlr_box field-for-field; smithay nests loc+size |
| `Rect.empty` (18) | zero rect | `(struct wlr_box){0}` | `Rectangle::zero` (geometry.rs:1279) | close | |
| `Rect.isEmpty` (22) | width<=0 or height<=0 | `wlr_box_empty` (util/box.c:49) — identical, also NULL->empty | `Rectangle::is_empty` (geometry.rs:1220) — checks size.w==0 only | close | ours matches wlroots (<=0); smithay treats negatives as non-empty `[INFERENCE]` |
| `Rect.containsPoint` (26) | point in [x, x+w) x [y, y+h) | `wlr_box_contains_point` (util/box.c:78) — identical half-open semantics | `Rectangle::contains` (geometry.rs:1313) — identical | same | |
| `Rect.intersect` (32) | null when disjoint; else intersection | `wlr_box_intersection` (util/box.c:55) — returns bool + zeroes dest when empty | `Rectangle::intersection` (geometry.rs:1369) — returns Option, uses `overlaps` (geometry.rs:1341) | same | ours returns null via half-open check; wlroots returns false + zero box |
| `Rect.@"union"` (42) | bounding box, empty operand skipped | no wlr_box union helper `[INFERENCE]`; wlroots uses pixman_region32_union | `Rectangle::merge` (geometry.rs:1402) via `bounding_box` (1384) | close | ours skips empty operands; smithay merge assumes non-empty rects `[INFERENCE]` |
| `FPoint`/`FSize`/`FRect` (53/55/57) | f64 float geometry | `struct wlr_fbox {double ...}` (include/wlr/util/box.h:40) + `wlr_fbox_empty`/`wlr_fbox_transform` (util/box.c:110,121) | smithay uses `Rectangle<f64, Kind>` via generic Coordinate `to_f64` (geometry.rs:1187) | close | ours FRect is a bare struct with NO methods (no empty/intersect/union); wlr_fbox has empty+transform. Method gap noted below. |
| `Transform` (65) | wl_output_transform enum | `enum wl_output_transform` from wayland-server-protocol (include/wlr/util/box.h:96 decl) | `Transform` enum (geometry.rs:1869) | close | same 8 values |
| `Transform.isFlipped` (75) | value>=4 | `wlr_box_transform` switch handles flipped cases (util/box.c:97) | `Transform::flipped` (geometry.rs:1970) | close | |
| `Transform.is90Degrees` (79) | 90/270/flipped_90/flipped_270 | implicit in transform switch (util/box.c:104 `transform % 2`) | `Transform::degrees`/`transform_size` (geometry.rs:1927,1979) | close | |
| `Transform.transformedSize` (84) | swap w/h if 90° | `wlr_box_transform` width/height swap (util/box.c:104-106) | `Transform::transform_size` (geometry.rs:1927) | same | |

### log.zig

| Our fn (file:line) | Semantics (ours) | wlroots equivalent | smithay equivalent | Verdict | Note |
|---|---|---|---|---|---|
| `Level` (log.zig:9) | err/warn/info/debug/trace enum | `enum wlr_log_importance` WLR_SILENT/ERROR/INFO/DEBUG (util/log.c:28) | `tracing` Level (error/warn/info/debug/trace), external crate | close | ours adds a `trace` level wlroots lacks (wlroots stops at DEBUG); smithay has all five |
| `Level.label` (17) | "ERR".."TRC" | `verbosity_headers` array (util/log.c:24) | N/A (tracing subscriber formats) | close | |
| `Config` (28) | global min_level + per-tag override table | `static log_importance` set by `wlr_log_init` (util/log.c:95,22) | `tracing_subscriber::filter::EnvFilter` (extern, compositor-side) | **divergent** | ours supports per-tag overrides and a single global level; wlroots has only ONE global importance, no tags. smithay defers filtering to EnvFilter. Our tag table is ours-only. |
| `Config.levelFor` (39) | per-tag lookup, fallback min_level | N/A | N/A | ours-only | wlroots/smithay have no per-tag minimum table |
| `log` (42) | gated write to stderr, monotonic timestamp, `[SSS.mmm LVL tag] fmt` | `log_stderr` (util/log.c:28) — colored, monotonic timestamp `HH:MM:SS.mmm` relative to start | `tracing::event!` / `#[instrument]` spans (e.g. damage/mod.rs:433) | close | ours is Io-generic (explicit `io: *std.Io`, no globals); wlroots uses static globals + `wl_log_set_handler_server` (util/log.c:101); smithay uses global `tracing` macros with structured fields and spans — a fundamentally different model (no manual format string; structured key=value fields) |
| `err` (74) | log at .err | `_wlr_log(WLR_ERROR,...)` via `wlr_log` (util/log.c:112) | `tracing::error!` | close | |
| `warn` (78) | log at .warn | N/A (wlroots has no warn importance; ERROR covers it) | `tracing::warn!` | close | ours adds a warn level wlroots lacks `[INFERENCE]` |
| `info` (82) | log at .info | `_wlr_log(WLR_INFO,...)` (util/log.c:112) | `tracing::info!` | close | |
| `debug` (86) | log at .debug | `_wlr_log(WLR_DEBUG,...)` | `tracing::debug!` | close | |
| `trace` (90) | log at .trace | N/A (no trace in wlroots) | `tracing::trace!` (damage/mod.rs:676,2293) | close | maps to smithay's trace; no wlroots counterpart |

## Gaps

Behaviors wlroots/smithay have that we lack:
1. **Per-buffer damage rotation (wlroots 2-ring)**: `wlr_damage_ring_rotate_buffer` keys history entries to the ACTUAL presented `wlr_buffer`, clips damage to that buffer's size, squashes the previous buffer's damage into its predecessor on destroy, and collapses >20 rects to extents (types/wlr_damage_ring.c:103-131,50,13). Our `DamageRing.rotate` (damage.zig:119) rotates by age only and never bounds/clips to a buffer. Risk: repaint over-reporting and no destroy-time squash.
2. **Multi-rect damage precision**: wlroots keeps up to 20 disjoint pixman rects and only collapses at the limit (types/wlr_damage_ring.c:119-125). Our `renderDamage` (damage.zig:151) collapses to a single bounding rect every frame, over-painting on sparse damage. smithay keeps per-commit `DamageSet` smallvec of rects (backend/renderer/utils/mod.rs:296-298) and clips per-element to the output (damage/mod.rs:580-582).
3. **Opaque-region / visibility culling**: smithay's `OutputDamageTracker` subtracts opaque regions and skips fully-hidden elements before emitting damage (damage/mod.rs:513-530). Our ring has no culling concept.
4. **Logical/Physical/Buffer coordinate type distinction**: smithay enforces coordinate kinds and scale conversion at the type level — `Point<N,Kind>`, `Size<N,Kind>`, `to_physical`/`to_logical`/`to_buffer`, `Scale` (geometry.rs:10-27,385,768,560,639,972). Our `Point`/`Size`/`Rect` (geom.zig:8,10,12) are bare i32 with no kind or scale conversion, risking silent logical/physical mixing.
5. **Float-geometry methods**: `wlr_fbox_empty` and `wlr_fbox_transform` operate on float boxes (util/box.c:110,121); smithay's `Rectangle<f64>` supports to_i32_round/floor/ceil conversion (geometry.rs:1229-1248). Our `FRect` (geom.zig:57) is a data-only struct with no methods and no int-conversion helpers.
6. **Box equality / contains-box / closest-point / subtract**: wlroots has `wlr_box_equal` (util/box.c:117), `wlr_box_contains_box` (util/box.c:86), `wlr_box_closest_point` (util/box.c:14); smithay has `Rectangle::subtract_rects` (geometry.rs:1419). Our `Rect` (geom.zig:12) lacks all four. `[INFERENCE]` subtract is used by smithay's opaque culling (damage/mod.rs:519).
7. **Rect-count/whole damage in smithay**: smithay has no "whole" flag; whole-surface damage is a full-size rect and resize forces full damage via `reset` (backend/renderer/utils/mod.rs:198). Ours uses a whole flag; the two model whole-damage differently but ours matches wlroots' `add_whole` more closely.
8. **Logging model gap**: wlroots supports callback injection (`wlr_log_init` with `wlr_log_func_t`, util/log.c:95-100) and hooks the wayland server logger (util/log.c:101). smithay uses structured `tracing` spans with `#[instrument]` and field capture (e.g. damage/mod.rs:433,676). Ours is a plain printf-style formatter with per-tag filter (log.zig:42) — no callback injection, no wayland-server log hook, no structured fields, no spans.

## Verdict

- **DamageRing**: partial parity. Core rotate/render semantics match wlroots' age-based repainting intent, but the fixed-age ring diverges from wlroots' per-buffer rotation (no buffer clipping, no destroy-squash, no rect-count cap) and from smithay's per-element CommitCounter damage model. **Riskiest: single-bounding-rect renderDamage over-paints and whole-flag aging.**
- **geom**: close parity with wlroots box ops (empty/contains/intersect/union/transform all match), but missing type-level Logical/Physical distinction (smithay's headline feature) and missing fbox methods / contains_box / closest_point / subtract / equal.
- **log**: functional parity on levels, but a different architecture — ours is Io-generic with per-tag filters (ours-only strength) vs wlroots' single-global-level + callback injection and smithay's structured `tracing` spans. No structured logging; no wayland-server hook.
- Overall: acceptable for the canvas-first design (which favors whole-rect over precision), but the DamageRing buffer-clipping gap and the geom coordinate-kind gap are the two most likely sources of real bugs during scale/rotation work.
