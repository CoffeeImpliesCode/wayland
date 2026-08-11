# 139: Fix plan — triaged remediation of the 138 adversarial findings

Audit date: 2026-08-11. No code changed yet — this is the plan only. Source:
notes/138 (61 findings across 6 areas) + the six working sections
`local/fix-<area>.md` (per-fix task specs with verified line numbers,
tests, acceptance, risks). Every O: citation in the fix sections was
re-verified against the current tree; several audit line numbers had
drifted and were corrected inline (noted in each section).

Verdict: 31 findings get fixes now (2 wire-safety criticals, 8 major
module-local, 21 parity/minor/hook), 15 are deferred structural backlog
with explicit triggers, 15 are accepted as deliberate/positive
divergences. Fix order is dependency-driven: lifetime safety first, then
major protocol-contract violations, then parity minors, then compositor
hooks; the structural items (DnD, grabs, compositor-driven configure,
real present event) stay behind their prerequisites.

## 1. Triage table (all 61 findings)

Disposition: FIX (do now, phase given) / DEFER (structural or gated,
with trigger) / ACCEPT (deliberate or positive, reason). IDs are the 138
finding keys. Phase: 0 = wire-safety critical, 1 = major module-local,
2 = parity minors + hooks, 3 = structural backlog (deferred).

| ID | Severity | Area | Disposition | Phase |
|---|---|---|---|---|
| F-AX-1 | CRITICAL | viewporter UAF on surface destroy | FIX (no_surface + listener; closes F-AX-13) | 0 |
| F-AX-10 | MINOR | fractional-scale stale entry | FIX (surface-destroy prune, same pattern) | 0 |
| F-AX-11 | MAJOR | viewport dst single-buffered, never reset | FIX | 1 |
| F-AX-12 | MAJOR | viewport src unvalidated/unapplied | FIX | 1 |
| F-AX-2 | MAJOR | synthetic presentation present | DEFER (real present event, note 135 F8) | 3 |
| F-AX-3 | MAJOR | presented flags always 0 | DEFER (with F-AX-2) | 3 |
| F-AX-4 | MINOR | refresh mode-derived | DEFER (with F-AX-2) | 3 |
| F-AX-5 | MINOR | screencopy foreign output kills client | FIX (failed instead of no_memory) | 2 |
| F-AX-6 | MINOR | screencopy shm-only | DEFER (dmabuf allocator) | 3 |
| F-AX-7/8 | INFO | damage ordering / overlay_cursor | ACCEPT (equivalent) | — |
| F-AX-9 | MINOR | fractional-scale send-on-set API | FIX | 2 |
| C-CS-1 | MAJOR | subsurface destroyed vs inert on parent death | FIX | 1 |
| C-CS-2 | MAJOR | subsurface map not parent-coupled | FIX | 1 |
| C-CS-3 | MINOR | rejected-commit signal ordering | ACCEPT (ours cleaner; doc note) | — |
| C-CS-4 | MINOR | damage not clipped | FIX | 2 |
| C-CS-5 | MINOR | unlocked current.buffer model | DEFER (F32 texture cache) | 3 |
| C-CS-6 | INFO | restack sub-frame timing | ACCEPT (low value) | — |
| C-CS-7 | INFO | get_release positive delta | ACCEPT | — |
| C-CS-8 | INFO | invalid_transform more compliant | ACCEPT | — |
| C-CS-9 | INFO | cursor-role size exemption | DEFER (cursor roles) | 3 |
| S-F1 | MAJOR | v10 repeat contract (rate 0 + repeated) | FIX | 1 |
| S-F2 | MAJOR | grab leaks axis/release | FIX | 1 |
| S-F3 | MED | touch dead object + caps broadcast | FIX (error + API; touch impl DEFER) | 2 |
| S-F4 | MED | selection not re-sent on focus | FIX (mechanism exists; add test) | 1 |
| S-F5 | MAJOR | grab_serial drag validation | DEFER (grab layer, prior F3) | 3 |
| S-F6 | INFO | cursor hotspot ignores scale | FIX | 2 |
| S-F7 | MINOR | repeat first-tick jitter | FIX | 1 |
| S-F8 | INFO | set_cursor ring-wide serial | ACCEPT (matches wlroots) | — |
| X01 | MINOR | ack error interface | ACCEPT (spec-literal, note 129) | — |
| X03 | MINOR | set_parent unmapped clears | FIX | 2 |
| X04a | MAJOR | grab error surface (invalid_grab/topmost) | FIX | 2 |
| X04b | MAJOR | real popup grab routing | DEFER (F2 seat grabs) | 3 |
| X05 | MAJOR | reactive popup reconfigure | DEFER (F12 popup compositing) | 3 |
| X06 | INFO | sent_payloads not cleared on reset | FIX | 2 |
| X07 | MINOR | bounds/caps flag-driven sends | FIX | 2 |
| X08 | MAJOR | compositor-driven configure | DEFER (pairs 137 F2/G3) | 3 |
| X09 | INFO | repositioned version gate | FIX | 2 |
| L-D1 | MAJOR | layer new_popup signal | FIX (emission; rendering DEFER F12) | 2 |
| L-D2 | MAJOR | decoration new_toplevel_decoration signal | FIX (+ main.zig initial mode) | 2 |
| L-D3 | MINOR | layer close destroys resource | FIX (inert) | 2 |
| L-D4 | MINOR | set_size overflow wire -1 | FIX (implementation error) | 2 |
| L-D5 | MINOR | same-role rejection | ACCEPT (deliberate, note 129) | — |
| L-D6 | INFO | module-auto initial configure | DEFER (with X08) | 3 |
| L-D7 | INFO | kbd-interactivity focus policy | DEFER (documented out of scope) | 3 |
| D-D2 | MINOR | invalid_mode strictness | ACCEPT (XML-mandated) | — |
| D-D3 | MINOR | decoration v2 | DEFER (client need trigger) | 3 |
| D-D4 | INFO | orphaned-at-creation safety | ACCEPT (safer than wlroots) | — |
| D-D5 | INFO | request_mode signal shape | ACCEPT | — |
| D-A1 | MINOR | activation focus check gating | FIX | 2 |
| D-A2 | MINOR | activate destroys token resource | FIX (inert) | 2 |
| D-A3/4/5 | INFO | activation internals | ACCEPT (match wlroots) | — |
| F-SEL-1 | CRITICAL | DnD state machine | DEFER (largest structural) | 3 |
| F-SEL-2 | MAJOR | source_actions never emitted | FIX | 2 |
| F-SEL-3 | MINOR | cancelled source not inert | FIX | 2 |
| F-SEL-4 | MINOR | same-source re-delivery | FIX | 2 |
| F-SEL-5 | MINOR | bogus-seat device live | FIX (inert device) | 2 |
| F-SEL-6 | MINOR | primary mime validation | FIX | 2 |
| F-SEL-7 | MINOR | in_ask suppression | DEFER (with F-SEL-1) | 3 |
| F-SEL-8 | MINOR | dead-offer defensive branch | ACCEPT | — |

Counts: 31 FIX (2 phase-0, 8 phase-1, 21 phase-2), 15 DEFER (phase 3),
15 ACCEPT. Folded: F-AX-13 into F-AX-1, D1 into L2, F-AX-7/8 and
D-A3/4/5 counted once.

## 2. Phase 0 — wire-safety criticals (do first, sequential)

Both fixes use the same surface-destroy listener pattern (presentation.zig
Feedback shape: `destroy_listener: wire.Listener(*Surface)` + prune before
free + `orelse 0` identity guard). Land F-AX-1 before F-AX-10 only
because F-AX-11/12 rewrite the same viewporter handlers.

1. **F-AX-1** viewporter UAF — `ViewportRes.surface` nullable + destroy
   listener; set_source/set_destination post `no_surface` after surface
   death; viewportDestroy detaches link before free. Closes F-AX-13.
2. **F-AX-10** fractional-scale stale entry — same listener pattern;
   prune `fs.objects` on surface destroy; no false-positive exists check.

Files: src/shell/viewporter.zig, src/shell/fractional_scale.zig.

## 3. Phase 1 — major module-local contract fixes

Ordered by dependency within the phase (C1 before C2 — C1's
role-clearing defines C2's gate semantics; S1 before S2 — same seat.zig
state machine; F-AX-11+12 together — shared pending-state rewrite).

1. **C-CS-1** subsurface inert on parent destroy (subsurface.zig).
2. **C-CS-2** subsurface mapped state parent-coupled — `mapped_gate`
   role hook + recursive gate + parent map/unmap listeners + scene
   enter/present gating (role.zig, surface.zig, subsurface.zig,
   surface_node.zig).
3. **S-F1** v10 repeat contract — per-resource repeat_info (rate 0 to
   v10) + `KEY_STATE_REPEATED` send path (seat.zig).
4. **S-F2** implicit grab gates axis + button-release, synthetic
   releases on grab start (seat.zig).
5. **S-F7** repeat first-tick jitter — arm against seat deadline
   (main.zig + seat.zig).
6. **S-F4** selection re-sent on focus — mechanism already wired;
   add the missing wire test (data_device.zig).
7. **F-AX-11** viewport dst double-buffered + destroy reset — pending
   `Viewport` state + committed bit + surfaceSize consumer
   (surface.zig, viewporter.zig, surface_node.zig).
8. **F-AX-12** viewport src commit-time validation (bad_size /
   out_of_buffer) + crop applied to scene node (viewporter.zig,
   surface_node.zig; `SceneBufferNode.src` exists and is unused).

## 4. Phase 2 — parity minors and compositor hooks

Independent, parallelizable (21 fixes). Group by file for efficiency:

- viewporter/surface (already in Phase 0/1 files): none extra.
- **C-CS-4** damage clipping (surface.zig).
- **S-F3** get_touch MISSING_CAPABILITY error + setCapabilities/setName
  broadcast API (seat.zig; touch impl stays deferred).
- **S-F6** cursor hotspot scale (cursor.zig).
- **X03** set_parent unmapped clears (xdg.zig + F16 test rework).
- **X04a** grab error surface + topmost tracking (xdg.zig).
- **X06** sent_payloads cleared on reset (xdg.zig).
- **X07** flag-driven configure_bounds/wm_capabilities + setter API
  (xdg.zig + two test migrations).
- **X09** repositioned version gate (xdg.zig).
- **L-D1** layer new_popup signal (layer_shell.zig + main.zig listener).
- **L-D2** decoration new_toplevel_decoration signal + main.zig initial
  mode announce (xdg_decoration.zig + main.zig + main_test E2E).
- **L-D3** layer close inerts resource (layer_shell.zig).
- **L-D4** set_size overflow implementation error (layer_shell.zig).
- **D-A1** activation focus check gated behind serial (xdg_activation.zig).
- **D-A2** activate inerts token resource (xdg_activation.zig).
- **F-SEL-2** source_actions at offer creation (data_device.zig).
- **F-SEL-3 + F-SEL-4** cancelled-source inert + same-source
  early-return — SAME extraction block, one pass (data_device.zig,
  primary_selection.zig).
- **F-SEL-5** inert device for bogus/dead seat (data_device.zig,
  primary_selection.zig).
- **F-SEL-6** primary mime validation (primary_selection.zig).
- **F-AX-5** screencopy failed instead of no_memory (screencopy.zig).
- **F-AX-9** fractional-scale setPreferredScale API (fractional_scale.zig
  + main.zig init call).

## 5. Phase 3 — deferred structural backlog (triggers)

| ID | Item | Trigger | Prereq |
|---|---|---|---|
| F-SEL-1 | DnD state machine (CRITICAL breadth) | DnD milestone | F-SEL-2; own plan later |
| F-SEL-7 | in_ask suppression | with F-SEL-1 | F-SEL-1 |
| S-F5 | grab_serial drag validation | real drag path | grab-layer rework (prior F3) |
| X04b | real popup grab routing | seat grab machinery | notes/133 F2 + F12 |
| X05 | reactive popup reconfigure | popup compositing | F12 |
| X08 | compositor-driven configure | real window management | pairs 137 F2/G3 |
| L-D6 | module-auto initial configure | with X08 | X08 |
| L-D7 | kbd-interactivity focus policy | layer focus routing | seat focus policy |
| D-D3 | decoration v2 | client needs v2 relaxations | build.zig bump + relax |
| F-AX-2 | real present event | backend flip feedback | note 135 F8 |
| F-AX-3 | presented flags | with F-AX-2 | F-AX-2 |
| F-AX-4 | present-derived refresh | with F-AX-2 | F-AX-2 |
| F-AX-6 | dmabuf screencopy | dmabuf allocator | allocator work |
| C-CS-5 | unlocked current.buffer | F32 texture cache | F32 redesign |
| C-CS-9 | cursor-role size exemption | cursor roles added | role plumbing |

## 6. Accepted register (15)

Deliberate or positive divergences; no action. Reasons in the fix
sections; highlights: X01 (spec-literal ack error — refs post on the
wrong interface), D-D2 (XML-mandated invalid_mode), C-CS-7/8 (positive
breadth/compliance), C-CS-3 (ours cleaner than a latent wlroots bug),
S-F8, L-D5, D-D4, D-D5, F-SEL-8, F-AX-7/8, C-CS-6, D-A3/4/5.

## 7. Execution contract

- Each fix's full spec (verified files+lines, change, wire test,
  acceptance, risks) lives in `local/fix-<area>.md`.
- Workflows: each fix = one change; write the wire test first (they
  fail pre-fix), then the implementation, then `zig build test`.
- Gates (repo hardcore bar): `zig fmt --check .`, `zig build`,
  `zig build test` (zero leaks), `zig ast-check`, ziglint, kcov on
  changed modules.
- Order rules: Phase 0 before anything; C1 before C2; S1 before S2;
  F-AX-11+12 together (and after F-AX-1); F-SEL-3+4 together; X07 last
  in its file group (X08 will reshape configure()).
- Structural backlog items get their own plans at trigger time; do not
  start them in this round.
