# Presentation — wlroots/smithay diff

Module: src/presentation.zig (wp_presentation v2, stable presentation-time).
References: wlroots 0.20.2 types/wlr_presentation_time.c + include/wlr/types/wlr_presentation_time.h; smithay v0.7.0 src/wayland/presentation/mod.rs.
All three implement wp_presentation v2 (wlroots: PRESENTATION_VERSION 2, types/wlr_presentation_time.c:10; smithay: global version 2, mod.rs:108; ours: presentation_version = generated_version = 2, src/presentation.zig:63).

## Surface

Our module public surface (src/presentation.zig):
- `presentation_version` pub const, line 63.
- `Presentation` struct, line 65:
  - `init` pub fn, line 82 — register wp_presentation global; bind sends clock_id.
  - `deinit` pub fn, line 117 — remove global, destroy outstanding feedbacks.
  - `getFeedback` pub fn, line 130 — client feedback request; create feedback resource on surface's client.
  - `discard` pub fn, line 169 — surface gone: every feedback bound to it sends discarded.
  - `present` pub fn, line 186 — surfaces presented: send presented (tv from monotonic clock, refresh, seq, flags); seq++ per call.
- `Feedback` struct, line 223 — resource, owning presentation, surface.

Callers (server/main.zig): `present` called once per frame with all drawn surfaces, refresh in msec, flags 0 (line 620); `discard` on surface removal (line 688).

## Comparison

Rows: our item vs wlroots vs smithay.

1. `presentation_version` (ours:63).
   - wlroots: `#define PRESENTATION_VERSION 2`, types/wlr_presentation_time.c:10.
   - smithay: `PresentationState::new` creates global version 2, mod.rs:108.
   - Verdict: same.

2. `Presentation.init` global + bind + clock_id (ours:82, bind sends CLOCK_MONOTONIC via `resource.sendClockId(clock_id_monotonic)`, line 239-241).
   - wlroots: `wlr_presentation_create(display, backend, version)` creates global and hooks display destroy, types/wlr_presentation_time.c:177; bind sends `wp_presentation_send_clock_id(resource, CLOCK_MONOTONIC)`, line 152-163, line 162. Takes a backend argument (used only for the destroy-signal pattern, not stored — VERIFIED 2026-08-09: signature at wlr_presentation_time.c:177-179; the backend param is passed to wl_display_add_destroy_listener, not retained)CE] from the .c body: backend is unused in the function).
   - smithay: `PresentationState::new(display, clk_id)` creates global version 2 with caller-supplied clock id, mod.rs:99-110; bind sends `interface.clock_id(self.clk_id)`, mod.rs:129-139.
   - Verdict: close. Same wire behavior; clock is hardcoded CLOCK_MONOTONIC in ours and wlroots, configurable in smithay. Ours takes the compositor display directly, no backend parameter.

3. `Presentation.getFeedback` (ours:130) — create feedback resource on the requester's client, track in a flat global list; each feedback delivers exactly one outcome.
   - wlroots: `presentation_handle_feedback`, types/wlr_presentation_time.c:91 — attaches the feedback to the surface via a per-surface addon with `wlr_surface_synced` double-buffered pending/current state (lines 12-18, 91-139); multiple wire resources per commit share one `wlr_presentation_feedback` (line 115-126).
   - smithay: request handler pushes the callback into the surface's `PresentationFeedbackCachedState` pending state, mod.rs:156-166; one callback object per wire resource.
   - Verdict: divergent. Ours stores a flat list of Feedback on the Presentation; wlroots attaches feedback to the surface through synced state (sampled on commit), smithay stores it in the surface's cached state. Ours has no per-surface attachment, so present() must match surfaces by pointer against the whole list (ours:200).

4. `Presentation.present` (ours:186) — send presented with tv from the monotonic io clock taken at call time, refresh_ns = refresh_msec * 1e6, seq from a per-presentation counter incremented once per call, flags passthrough (0 from server/main.zig:620).
   - wlroots: no direct equivalent; the compositor calls `wlr_presentation_surface_sampled` (types/wlr_presentation_time.c:210) or `_textured/_scanned_out_on_output` (lines 311-338), then `wlr_presentation_feedback_send_presented` (line 201) with a `wlr_presentation_event` filled from the output present event via `wlr_presentation_event_from_output` (line 243) — tv/seq/refresh/flags all per-output, from the output's vblank data.
   - smithay: compositor drains `PresentationFeedbackCachedState.current().callbacks` after commit and calls `PresentationFeedbackCallback::presented(output, time, refresh, seq, flags)` per callback, mod.rs:58-68, 234-285 — tv, refresh, seq, flags all caller-supplied per output; refresh rate semantics per client version (mod.rs:264-273).
   - Verdict: divergent. Same wire event, but ours fakes the timestamp (clock at call time, not the output present time), seq from a per-presentation counter instead of per-output vblank counter, refresh from a single msec argument, no per-output association, flags 0. Ours is a flat-list broadcast: all listed surfaces share one tv and one seq.

5. `Presentation.discard` (ours:169) — compositor author calls it when a wl_surface dies (server/main.zig:688); module does not listen to surface signals itself.
   - wlroots: no equivalent function; discard is driven structurally. `wlr_presentation_feedback_destroy` sends discarded to all resources (types/wlr_presentation_time.c:227-241, line 235); the synced state's `finish_state` destroys the feedback when the surface state is finished (lines 73-76), and the surface addon destroy frees the per-surface state (lines 58-67). The addon destroy runs when the surface is destroyed.
   - smithay: same shape as ours but automatic — `Drop for PresentationFeedbackCachedState` discards all pending callbacks when the cached state goes away (mod.rs:340-347), and `presented` upgrades the Weak surface and discards if the surface is dead (mod.rs:245-251).
   - Verdict: divergent. Behavior matches when the author remembers to call discard; wlroots/smithay do it automatically via surface-lifetime machinery. Ours is opt-in.

6. `Feedback` struct (ours:223) — resource + owning presentation + surface; freed by resource destroy handler (feedbackDestroy, ours:278).
   - wlroots: `wlr_presentation_feedback` struct with a list of wire resources, output association and commit tracking, header wlr_presentation_time.h:33-48; one feedback may have many resources (all requests on one commit).
   - smithay: `PresentationFeedbackCallback` with Weak surface, clk_id, one wire resource, mod.rs:196-200.
   - Verdict: close. Same lifecycle (destroy handler frees bookkeeping); ours is 1:1 resource, wlroots is 1:many, smithay 1:1.

7. sync_output (protocol event) — ours: never sent (documented at src/presentation.zig:13; test listens but ignores it, line 344).
   - wlroots: sent before presented to every output resource of the client on the presenting output, types/wlr_presentation_time.c:27-40 (line 34).
   - smithay: `presented` sends sync_output for each of the client's outputs on the output, mod.rs:260-262.
   - Verdict: missing (ours-only gap).

8. Presented flags / ZERO_COPY — ours: flags always 0 (server/main.zig:620), passthrough plumbed but unused.
   - wlroots: event flags come from the output present event (line 297); clears ZERO_COPY when the buffer was textured, not scanned out (line 296-298).
   - smithay: compositor passes `Kind` flags explicitly per callback, mod.rs:240, 283-284.
   - Verdict: ours-only simplification; no zero-copy tracking anywhere in ours.

9. Adaptive-sync / v1 refresh zeroing — ours: no version-dependent refresh handling.
   - wlroots: for version-1 clients with adaptive sync enabled, refresh forced to 0, types/wlr_presentation_time.c:292-295.
   - smithay: `Refresh::Variable` sends the minimum rate only to clients >= version 2, else refresh 0, mod.rs:86, 264-273.
   - Verdict: missing in ours (no VRR at all, M2).

## Gaps

Numbered behaviors we lack vs wlroots/smithay, with evidence:

1. No sync_output events. Ours never sends the event (src/presentation.zig:13; no code path emits it; test handler swallows it, src/presentation.zig:344). wlroots sends it per client output (types/wlr_presentation_time.c:34), smithay per client output (mod.rs:261). Clients that use sync_output cannot track which output presented.
2. No per-output present association. Ours broadcasts one tv/seq/flags across all listed surfaces (src/presentation.zig:186-200). wlroots binds each feedback to the specific output it was queued on and fires from that output's commit/present sequence (types/wlr_presentation_time.c:311-327, 277-302); smithay takes an `&Output` per presented callback (mod.rs:236, 260). Result: our tv/seq are not the output's real present time/vblank counter.
3. No supersede-discard semantics. When a surface commits new content before the previous frame is presented, the older feedback must be discarded ("user did not see the content"). Ours keeps all feedbacks until present/discard (src/presentation.zig:75-78); smithay discards superseded callbacks on commit merge (mod.rs:323-337) and on cached-state drop (mod.rs:340-347); wlroots discards via synced-state finish/move (types/wlr_presentation_time.c:73-81, 227-241). Ours can deliver presented for a frame that was never shown.
4. Feedback not attached to surface state; discard is manual. Ours requires the compositor author to call discard() on surface death (server/main.zig:688; src/presentation.zig:169). wlroots destroys feedback through the surface addon (types/wlr_presentation_time.c:58-67) and synced state; smithay through Drop + Weak upgrade (mod.rs:245-251, 340-347). If a surface dies through a path that does not call discard, ours leaks a stale feedback that can present for a dead surface.
5. seq is not a per-output vblank counter. Ours increments a single counter per present() call (src/presentation.zig:76-79, 190), shared by all feedbacks of that call. wlroots seq comes from the output event seq (types/wlr_presentation_time.c:243-252, header 50-59); smithay takes seq per callback from the compositor (mod.rs:239). Clients using seq to detect missed frames get a synthetic counter.
6. Timestamp not the hardware present time. Ours takes the clock at present() call (src/presentation.zig:187). wlroots uses the output present event's `when` (types/wlr_presentation_time.c:244-248); smithay takes `time` from the compositor (mod.rs:237, 275). Our tv drifts from the true scanout time by scheduling latency.
7. No ZERO_COPY flag handling (src/presentation.zig:14-15; flags always 0 at server/main.zig:620). wlroots sets/clears it from the scanout path (types/wlr_presentation_time.c:296-298); smithay lets the compositor pass Kind (mod.rs:240).
8. No v1 adaptive-sync refresh zeroing (neither ours nor, notably, smithay's Dispatch2 path — smithay has it in presented, mod.rs:264-273; wlroots in feedback_handle_output_present, types/wlr_presentation_time.c:292-295). Ours sends the same refresh to all versions (src/presentation.zig:183, 190). Latent until VRR exists.
9. Feedback objects are not merged per commit. wlroots groups all feedback requests of one commit into one object with several resources (types/wlr_presentation_time.c:115-126); smithay and ours are 1:1 per resource (mod.rs:157; src/presentation.zig:130-166). Wire-visible difference: none (each resource still gets its own events), so this is an internal-structure divergence, not a protocol gap [VERIFIED 2026-08-09: wlroots' merge is one feedback object per surface-commit with a `wl_list resources` (wlr_presentation_time.c:115-126, `feedback->resources`); each resource receives its own events, so per-resource wire behavior is identical to ours].

## Verdict

Core path parity: global/bind/clock_id, getFeedback, presented/discarded destructor events, per-feedback 1:1 lifecycle with destroy-handler cleanup, and surface-list present matching are all wire-equivalent. Protocol gaps are confined to optional-but-standard behavior: sync_output (never sent), superseded-callback discard on commit (absent), per-output present association with real tv/seq/flags (replaced by one synthetic timestamp, a per-presentation counter, and flags 0).

Riskiest divergences: (1) missing supersede-discard semantics can report presented for content the user never saw — a spec violation clients like compositor benchmarks can detect; (2) no sync_output means clients cannot associate feedback with an output; (3) manual discard on surface death is a leak/stale-feedback hazard on any surface-destruction path that forgets the call; (4) synthetic tv/seq break latency measurement and frame-drop detection. These are documented M2 simplifications (src/presentation.zig:10-17) and are acceptable for the headless/pixman path, but they must be closed (per-output association + sync_output + commit-merge discard) before any real-output milestone.
