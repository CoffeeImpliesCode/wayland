# Misc breadth — data device, subcompositor, utils — wlroots/smithay

Scope: our modules `src/compositor/data_device.zig`, `src/compositor/subsurface.zig`,
`src/utils/{damage,geom,log}.zig`, `src/compositor/region.zig`, `src/core/{display,wire}.zig`,
`src/server/client.zig` (E2E test client) vs wlroots 0.20.2 and smithay v0.7.0.
Reference clones (READ-ONLY, cited relative to clone root):
wlroots `~/projects/freedesktop-wlroots-wlroots` (tag 0.20.2, commit d7835334);
smithay `~/projects/github-Smithay-smithay` (HEAD 5fb12b87 = v0.7.0-407-g5fb12b87,
i.e. 407 commits past the v0.7.0 tag — all smithay citations below verified at that revision).
Parity notes 101 (display/wire), 107 (subsurface), 108 (data device), 115 (utils) already
compare per-function parity. This note is the breadth inventory: whole features the
references have in these areas that we lack entirely. Seat drag grabs defer to 125;
only the data-device-visible drag surface is listed here. `src/presentation.zig` covered
by 112 — skipped.

## Inventory

Ours (verified by reading):
- `src/compositor/data_device.zig` (547 lines) — DataDeviceManager, DataDevice, DataSource,
  DataOffer. Clipboard selection relay only: `set_selection` stores seat-wide source,
  focus change re-delivers offer+selection (`deliverSelectionToFocus` :270-301).
  `start_drag` cancels the source (:235-241). `offer.accept`/`finish`/`set_actions` no-ops
  (:304-324), `source.set_actions` no-op (:189). No primary selection, no DnD.
- `src/compositor/subsurface.zig` (413 lines) — Subcompositor + Subsurface. Role
  enforcement, `set_position` stored immediately (single-buffered, :234-237), `sync`
  flag tracked but not enforced (:10-14, :246-247), `place_above`/`place_below` ignored
  (:238-245). Server side re-appends child nodes flat above the parent per frame —
  `syncSubsurfaceNodes`, `src/server/main.zig:1376-1397` (position = parent absolute +
  offset, `root.appendChild`).
- `src/utils/damage.zig` — `Damage` (whole flag + rect list) and `DamageRing`
  (buffer-age history, `rotate` never allocates). Parity vs wlr_damage_ring in 115.
- `src/utils/geom.zig` — untyped `Point`/`Size`/`Rect` (i32) + `FPoint`/`FSize`/`FRect`
  (f64) + `Transform` enum. No matrix, no box-transform, no closest-point.
- `src/utils/log.zig` — `Level`, `Config` (per-tag filter), `log/err/warn/info/debug/trace`.
- `src/compositor/region.zig` — wl_region as rect list; `add`, `subtract` (rect splitting),
  `boundingRect` only. No scale/transform/expand/confine.
- `src/core/display.zig` + `wire.zig` — libwayland-server substrate; re-exports `Signal`,
  `Listener`, `list` (wire.zig:19,22-27). Full parity picture in 101.
- `src/server/client.zig` (791 lines) — pure-protocol E2E test client (registry, xdg,
  shm, seat, output, screencopy; CLIENT-OK/ERROR verdicts). No reference analog.

wlroots 0.20.2 (verified by directory listings and reads):
- `types/data_device/` — `wlr_data_device.c` (selection: `wlr_seat_request_set_selection`
  serial+superseded validation :144-165, `wlr_seat_set_selection` :184-215, bind-time
  delivery :226-252; `start_drag` handler :47-87), `wlr_data_source.c` (impl vtable with
  `send/accept/destroy/dnd_drop/dnd_finish/dnd_action` :12-80; `set_actions` validation
  :152-182), `wlr_data_offer.c` (accept/receive/finish with INVALID_FINISH error
  :78-153, `set_actions` negotiation :155-189, `data_offer_update_action` :57-76,
  source-destroy unlink :230-236), `wlr_drag.c` (drag object with started/dropped/
  cancelling + implicit keyboard/pointer/touch grabs :13-121,182-380; drop :213-258;
  drag icon role :402-443; `wlr_drag_create` :444-491; `wlr_seat_start_drag`/
  `start_pointer_drag`/`start_touch_drag` :518-561).
- `types/wlr_subcompositor.c` (439 lines) — ancestor-walk sync check :13-25; pending/
  current parent state via `wlr_surface_synced` :226-250; sync commit caching
  (lock_pending/unlock_cached) :262-294; `place_above`/`place_below` with sibling
  resolution and BAD_SURFACE error :76-152; subsurfaces_below/above lists on the parent
  :95-152; child map rules (`subsurface_consider_map`) :195-209; inert on parent destroy
  :253-260. Plus `types/scene/subsurface_tree.c` — per-surface tree with below/above
  ordering and clip propagation :24-112.
- `types/wlr_primary_selection.c` (seat-side source API, serial validation :51-79,
  set/clear :81-105) + `types/wlr_primary_selection_v1.c` (zwp_primary_selection_v1:
  offer lifecycle :53-76, device_handle_set_selection :198-225, focus-driven delivery
  :250-297).
- `types/wlr_data_control_v1.c` (20.3 KB) + `types/wlr_ext_data_control_v1.c` (20.5 KB)
  — clipboard-manager protocols (listing).
- `util/` (18 files, listing): version, time, array, box, fd, matrix, mem, utf8,
  transform, token, shm, set, region, rect_union, log, global, env, addon.
  Public headers `include/wlr/util/`: addon.h, box.h, transform.h, region.h, log.h,
  edges.h. Internal `include/util/`: matrix.h (identity/multiply/translate/scale/
  transform/project_box + matrix_projection/invert), rect_union.h (disjoint cover),
  array.h, set.h, global.h, env.h, shm.h, token.h, utf8.h, time.h, fd.h, mem.h.
  `wlr_list`: ABSENT from 0.20.2 (grep, zero hits) — wlroots uses wl_list (wayland-util)
  and wl_array. "spherical": ABSENT (grep, zero hits).

smithay v0.7.0+407 (verified by directory listings and reads):
- `src/wayland/selection/` — `mod.rs` (SelectionHandler trait, SelectionTarget,
  SelectionSource), `data_device/` (DataDeviceState::new :580, DataDeviceHandler :119,
  WaylandDndGrabHandler::dnd_requested :131-153, action_choice :119-126,
  default_action_chooser :603, full handle_dnd with InvalidFinish/InvalidAction protocol
  errors :233-347, set_data_device_focus :625, set_data_device_selection :645,
  request_data_device_client_selection :688, clear_data_device_selection :743;
  device.rs DND_ICON_ROLE + StartDrag :63-146), `primary_selection/`
  (PrimarySelectionState::new :128 / new_with_filter :139, set_primary_focus :174,
  set_primary_selection :194, request_primary_client_selection :236,
  current_primary_selection_userdata :272, clear_primary_selection :291),
  `wlr_data_control/` (DataControlHandler :76, DataControlState :83), `ext_data_control/`,
  `offer.rs` (OfferReplySource :33), `source.rs` (SelectionSource :18,
  CompositorSelectionProvider :101), `seat_data.rs` (SeatData: clipboard+primary
  focus/selection :47-125).
- `src/input/dnd/` — `mod.rs` (DndAction, SourceMetadata, Source trait, OfferData),
  `grab.rs` (GrabType :33, DnDGrab :41, new_pointer :85, new_touch :112, DndTarget :135).
- `src/utils/` (13 files, listing): geometry.rs (Coordinate trait; Logical/Physical/
  Buffer/Raw kinds; Scale/Point/Size/Rectangle/FrameExtents/Transform with
  to_physical/to_logical/to_buffer, contains_rect, overlaps, subtract_rect — geometry.rs
  :10-30,385,768,1177,1413-1436), serial.rs (Serial wrap-aware PartialOrd :11-32,
  SerialCounter + global SERIAL_COUNTER :57), signaling.rs (Signaler :30, SignalToken
  :94), user_data.rs (UserData :23, UserDataMap :110), fd.rs (DeviceFd :9),
  clock.rs (Clock/Time, Monotonic/Realtime :9-86), ids.rs, sealed_file.rs,
  alive_tracker.rs, hook.rs, iter.rs, x11rb.rs, mod.rs. NO `regions.rs`, NO `bench.rs`
  (ls + grep verified); wl_region is a plain rect list in
  `src/wayland/compositor/handlers.rs:372-410` (RegionUserData). "spherical": ABSENT
  (grep, zero hits).

## Breadth table

| wlroots/smithay feature | reference location | ours? same/partial/missing | what it does | verdict for the canvas compositor: in-scope / optional / out-of-scope |
|---|---|---|---|---|
| Drag-and-drop lifecycle (drag object, started/dropped/cancelling, implicit grabs) | wlroots types/data_device/wlr_drag.c:444-561; smithay src/input/dnd/grab.rs:41-133, data_device/device.rs:63-146 | missing — start_drag cancels the source (data_device.zig:235-241) | request → start → grabs → drop → finish; source gets dnd_drop_performed/dnd_finished | optional — spec seat.drag hook exists (zig-compositor-lib-spec §2 input/seat.zig) but no milestone; needs pointer/touch grabs (125) |
| Drag offers + drop zones (enter/leave/motion per pointer move, accept) | wlroots types/data_device/wlr_drag.c:30-121,213-258; smithay data_device/mod.rs:233-297 | missing | hit-tests the drop target per motion; sends wl_data_device enter/leave/motion | optional — same dependency as DnD |
| Drag icons (client surface follows pointer) | wlroots types/data_device/wlr_drag.c:402-443 + types/scene/drag_icon.c; smithay DND_ICON_ROLE (data_device/device.rs:11) | missing | wl_surface with drag_icon role rendered under the cursor | out-of-scope — the canvas draws its own cursor; icon adds nothing |
| DnD action negotiation (set_actions, action event, preferred_action, action_choice) | wlroots types/data_device/wlr_data_offer.c:57-76,155-189, wlr_data_source.c:152-182; smithay data_device/mod.rs:298-347,603-622 | missing — set_actions/finish/accept no-ops (data_device.zig:189,305,320-324) | copy/move/ask negotiation source↔target; INVALID_FINISH/INVALID_ACTION errors | out-of-scope unless DnD ships; no-ops also miss protocol errors on selection offers |
| Primary selection (zwp_primary_selection_v1 + seat API) | wlroots types/wlr_primary_selection_v1.c (offer lifecycle :53-76, focus delivery :250-297), types/wlr_primary_selection.c; smithay selection/primary_selection/mod.rs | missing entirely | second selection for middle-click paste, delivered to keyboard focus | optional — foot (the target client) binds it; small protocol, cheap to add |
| Selection-offer lifecycle (destroy stale offers, source-destroy unlink, selection(NULL)) | wlroots types/data_device/wlr_data_device.c:105-143, wlr_data_offer.c:191-236; smithay seat_data.rs:125-217 | partial — new offer per focus, old ones never destroyed, no source-destroy listener (data_device.zig:270-301) | keeps offer list correct; frees offers when source dies | in-scope — dangling-source hazard is a memory-safety bug (108 gaps 3-4) |
| Clipboard-manager protocols (wlr_data_control_v1 / ext_data_control_v1) | wlroots types/wlr_data_control_v1.c, types/wlr_ext_data_control_v1.c; smithay selection/wlr_data_control/, selection/ext_data_control/ | missing | external clipboard managers read/write both selections | out-of-scope — spec M8 extras; desktop-compositor feature |
| Selection-request validation (serial + superseded check / focus check) | wlroots types/data_device/wlr_data_device.c:144-165; smithay data_device/device.rs:103-123 | missing — request serial ignored (data_device.zig:212-234) | rejects stale/spoofed set_selection | in-scope — cheap; correctness (108 gap 2, parity note) |
| Subsurface sync commit caching (apply on parent commit; ancestor-walk sync check) | wlroots types/wlr_subcompositor.c:13-25,262-294; smithay compositor/cache.rs, handlers.rs:498-534 | missing — sync flag tracked, every commit immediate (subsurface.zig:10-14,246-247) | batches child state into the parent frame; no tearing | in-scope — foot scrollback uses sync subsurfaces; today content can tear |
| Subsurface stacking (place_above/below, sibling resolution, below/above lists, scene order) | wlroots types/wlr_subcompositor.c:76-152 + types/scene/subsurface_tree.c:66-112; smithay handlers.rs:486-560 | missing — ignored; child always re-appended above parent (main.zig:1376-1397) | relative z-order of sibling subsurfaces + BAD_SURFACE error | optional — foot has one subsurface; canvas z-order handled by its own scene |
| Subsurface position apply-on-parent-commit (pending/current) | wlroots types/wlr_subcompositor.c:65-74,226-250 | partial — set_position immediate, single-buffered (subsurface.zig:234-237) | position batches with the parent frame | optional — foot sets position once at map |
| Child map/unmap rules (map iff parent mapped + buffer; new_subsurface event) | wlroots types/wlr_subcompositor.c:195-209 + types/scene/subsurface_tree.c:180-196 | partial — child renders whenever parent has a node; no map/unmap events | visibility tracks parent lifecycle | in-scope — visibility correctness (107 gap 3) |
| Subsurface clipping to parent extent | wlroots types/scene/subsurface_tree.c:36-65 | missing | children outside the parent box are clipped | optional — protocol leaves it to the compositor; a canvas compositor may prefer overflow |
| wlr_box helpers (closest_point, intersection, contains_box, box/fbox_transform, equal) | wlroots include/wlr/util/box.h + util/box.c | partial — intersect/union/containsPoint/isEmpty/transformedSize only (geom.zig:26-50,84) | geometry math incl. output-transform box mapping | in-scope — canvas transform math; spec §2 utils/matrix.zig planned |
| wlr_region helpers (scale/scale_xy/transform/expand/rotated_bounds/confine) | wlroots include/wlr/util/region.h + util/region.c | missing — region.zig has add/subtract/boundingRect only | pixman region ops for damage/input scaling | optional — damage is whole/rect based today; confine belongs with pointer constraints (125) |
| Matrix helpers (identity/multiply/translate/scale/transform/project_box, projection, invert) | wlroots include/util/matrix.h + util/matrix.c | missing — no matrix code; server renders with an identity camera (main.zig:924-927,954) | 3x3 matrices for output transforms + projection | in-scope — spec §2 utils/matrix.zig is a named component; camera math needs it |
| rect_union (disjoint cover of a rect union) | wlroots include/util/rect_union.h + util/rect_union.c | missing | coalesces overlapping damage rects | optional — bounding-rect damage is the canvas default (canvas-compositing.md §3) |
| wlr_addon (tagged per-object data registry) | wlroots include/wlr/util/addon.h + util/addon.c | missing — typed role/user-data pointers instead | attach typed side data to any object | out-of-scope — zig's type system and setHandler user-data replace it |
| wlr_log verbosity/callback init, file:line, errno macro | wlroots include/wlr/util/log.h + util/log.c | partial — per-tag filter config; no runtime callback install, no file:line (log.zig:28-72) | global log config + callback | same — our per-tag config is strictly more useful; nothing to take |
| wlr_edges bitmask | wlroots include/wlr/util/edges.h | missing — trivial 4-bit enum | resize edge detection | out-of-scope — no resize path; trivial when needed |
| wl_list / wlr_list | wlroots: wlr_list ABSENT in 0.20.2 (grep, 0 hits); wl_list + wl_array instead; ours re-exports wl.list (wire.zig:19) + std.ArrayList | same | intrusive linked list vs typed array list | N/A — no gap; both references sit on the same libwayland list primitives |
| smithay typed geometry (Coordinate kinds, to_physical/logical/buffer, subtract_rect, contains_rect) | smithay src/utils/geometry.rs:10-30,385,768,1177,1413-1436 | missing — untyped i32/f64 (geom.zig:8-57) | compile-time coordinate-space safety + scale conversion | optional — the canvas is world-space f64 anyway (115 flagged the gap) |
| smithay Serial wrap-aware ordering + global SERIAL_COUNTER | smithay src/utils/serial.rs:11-57 | partial — display.nextSerial() only (display.zig:117) | serials compare correctly across wrap-around | optional — useful for input serial validation (125) |
| smithay Signaler/SignalToken, UserDataMap | smithay src/utils/signaling.rs:30-94, user_data.rs:23-190 | same — wire.Signal/Listener (wire.zig:22-27) | signal fan-out + typed per-object data | same — zig-wayland provides the wlroots-equivalent substrate |
| smithay regions.rs / bench.rs | ABSENT in this clone (ls + grep; wl_region is a rect list, compositor/handlers.rs:372-410) | N/A | — | no gap |
| "spherical" util | ABSENT in both clones (grep, zero hits) | N/A | — | no gap — task probe resolved, never existed here |
| E2E test client | wlroots: no analog (no tests/ dir; examples/ + tinywl/ only); smithay: no analog | ours-only | in-memory protocol client drives the full wire stack, CLIENT-OK/ERROR verdicts | keep — ours-only; validates the stack without an external client (foot/weston do that job separately) |
| Display/wire breadth | wl_display substrate is the same libwayland object for wlroots and us; smithay reimplements it | same | — | no new breadth at display level; 101 covers it |

## Gaps

1. Drag-and-drop is absent end to end. `start_drag` cancels the source
   (src/compositor/data_device.zig:235-241); there are no drag offers, no drop zones,
   no drag icon role, no dnd_drop_performed/dnd_finished events. wlroots implements the
   whole lifecycle in types/data_device/wlr_drag.c (444-561) with implicit
   keyboard/pointer/touch grabs (:182-380); smithay exposes it as
   `WaylandDndGrabHandler::dnd_requested` + `DnDGrab` (src/wayland/selection/data_device/
   mod.rs:131-153; src/input/dnd/grab.rs:41-133). Why it matters: it is the largest
   missing interaction surface of wl_data_device, and the spec's seat already reserves a
   `.drag` slot (zig-compositor-lib-spec §2 input/seat.zig) — but it depends on pointer
   grabs, which belong to the seat note (125).
2. Primary selection (zwp_primary_selection_v1) is missing entirely. wlroots:
   types/wlr_primary_selection_v1.c (offer lifecycle :53-76, focus-driven delivery
   :250-297) on top of types/wlr_primary_selection.c (serial validation
   :51-79); smithay: selection/primary_selection/mod.rs incl. a per-client visibility
   filter (new_with_filter :139). Why it matters: middle-click paste is standard for
   terminals; foot, the E2E target client, binds the protocol when advertised. Small,
   self-contained protocol — the cheapest breadth win here.
3. Action negotiation and protocol-error behavior on offers are no-ops: `offer.accept`,
   `offer.finish`, `offer.set_actions`, `source.set_actions` store nothing and post no
   errors (src/compositor/data_device.zig:189,305,320-324). wlroots computes a negotiated
   action (types/data_device/wlr_data_offer.c:57-76,155-189) and posts
   INVALID_FINISH/INVALID_ACTION (wlr_data_offer.c:123-153); smithay validates the same
   (data_device/mod.rs:233-347). Why it matters: only with DnD, but the missing protocol
   errors are wrong even today for selection offers (silently accepting invalid client
   requests instead of killing the connection per protocol).
4. Offer lifecycle is unmanaged: every focus change allocates a fresh wl_data_offer and
   old offers accumulate; a live offer holds a raw `source` pointer with no source-destroy
   listener (src/compositor/data_device.zig:270-301,304-324). wlroots destroys all old
   selection offers before re-sending (types/data_device/wlr_data_device.c:125-143) and
   nulls the source via listener (types/data_device/wlr_data_offer.c:230-236). Why it
   matters: memory safety — receive() after the source died dereferences freed memory.
5. Subsurface sync is not enforced: the `sync` flag is tracked but every commit is
   treated as desync'd (src/compositor/subsurface.zig:10-14,246-247). wlroots caches
   child commits (wlr_surface_lock_pending/unlock_cached) and applies them on the parent's
   commit, with an ancestor-walk sync check (types/wlr_subcompositor.c:13-25,262-294).
   Why it matters: foot's scrollback buffer lives in sync subsurfaces; today an update
   can show half-committed content (tearing). This is the correctness gap in the
   subcompositor area.
6. Subsurface stacking is flat: `place_above`/`place_below` are ignored and the server
   re-appends the child above the parent every frame (src/server/main.zig:1376-1397).
   wlroots keeps subsurfaces_below/above lists on the parent, resolves siblings with a
   BAD_SURFACE protocol error (types/wlr_subcompositor.c:76-152), and mirrors the order
   in the scene tree (types/scene/subsurface_tree.c:66-112). Why it matters: multiple
   sibling subsurfaces (menus, tooltips layered over one surface) will render in creation
   order, not requested order — cosmetic today (foot has one subsurface), structural
   later.
7. Map/unmap rules for subsurfaces are absent: a child renders whenever the parent has a
   scene node, with no map-iff-parent-mapped+buffer rule and no unmap on parent unmap
   (wlroots: types/wlr_subcompositor.c:195-209). Why it matters: visibility correctness
   when a parent surface unmaps (107 gap 3).
8. No box/region/matrix helper libraries. `wlr_box_*` (closest_point, contains_box,
   box/fbox_transform — include/wlr/util/box.h), `wlr_region_*` (scale/scale_xy/
   transform/expand/rotated_bounds/confine — include/wlr/util/region.h), and the 3x3
   matrix set (identity/multiply/translate/scale/transform/project_box/projection/invert —
   include/util/matrix.h) have no analogs; our geom.zig stops at intersection/union and
   the server renders with an identity camera (src/server/main.zig:924-927,954).
   Why it matters: the
   canvas camera (canvas-compositing.md §1: M = T·S·R·T, f64 3x3) is exactly the matrix
   math wlr_matrix provides, and the spec already names utils/matrix.zig as a component
   (zig-compositor-lib-spec §2). Box-transform is needed for output-rotation math.
9. Selection-request validation is absent: `set_selection`'s serial is ignored
   (src/compositor/data_device.zig:212-234). wlroots validates serial + superseded order
   (types/data_device/wlr_data_device.c:144-165); smithay requires keyboard focus
   (data_device/device.rs:103-123). Why it matters: a client can claim input it never
   received; cheap to add with the display serial counter (display.zig:117).

## Verdict

The references hold substantial additional functionality in this area, but almost all of
it is interaction surface, not compositing surface. The whole-feature gaps: drag-and-drop
(with offers, drop zones, action negotiation, drag icons), primary selection, clipboard-
manager protocols, subsurface sync/stacking/map semantics, and the box/region/matrix
utility libraries. For a canvas-first compositor the split is clear: worth taking is the
small, correctness-flavored set — selection-offer lifecycle management (memory safety),
selection-request serial validation, subsurface sync commit caching and map rules
(foot-scrollback tearing and visibility), and the matrix + box-transform helpers (the
camera math in canvas-compositing.md §1 and spec §2 utils/matrix.zig are literally this).
Primary selection is a cheap, self-contained optional that directly benefits the target
client (foot middle-click paste). The heavy interaction machinery — DnD grabs and drop
zones — is optional and gated on the seat's pointer grabs (125); drag icons, action
negotiation, and the clipboard-manager protocols are out of scope for a canvas compositor
(the canvas owns cursor rendering and z-order, and there is no desktop clipboard-manager
ecosystem to serve). Utility breadth is thin where it matters: wlr_list no longer exists
in 0.20.2 (wl_list + wl_array serve both us and wlroots), smithay has no regions.rs or
bench.rs, and neither clone has any "spherical" util — the only util feature worth
building is the matrix set. Our E2E test client remains ours-only with no reference
analog and is the correct pattern to keep.
