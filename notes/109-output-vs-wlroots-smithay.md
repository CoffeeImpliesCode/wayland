# Output — wlroots/smithay diff

Module: src/output/output.zig (Output abstraction), src/output/wl_output.zig (wl_output global, M3).
References: wlroots 0.20.2 (types/output/output.c, include/wlr/types/wlr_output.h), smithay v0.7.0 (src/output.rs, src/wayland/output/mod.rs, src/wayland/output/handlers.rs). Lines relative to each repo root.

## Surface

src/output/output.zig:
- `pub const Mode` — output.zig:19 (width, height, refresh_msec interval)
- `pub const Output` — output.zig:26
  - fields: mode, scale, transform, enabled, width, height, impl, data, allocator, io, log_cfg, backend; events.frame/commit/destroy
  - `pub const State` — output.zig:56; committed_enabled 57, committed_scale 58, committed_transform 59, committed_mode 60, committed_buffer 61
  - `State.init` — output.zig:75; `State.deinit` — output.zig:79
  - `pub const Impl` — output.zig:85 (test, commit, destroy fns)
  - `Output.create` — output.zig:94
  - `Output.destroy` — output.zig:131
  - `Output.commitState` — output.zig:140
  - `Output.sendFrame` — output.zig:162

src/output/wl_output.zig:
- `pub const output_version` — wl_output.zig:23 (= 4)
- `pub const WlOutput` — wl_output.zig:25 (per-output global, resources list, destroy listener)
  - `WlOutput.create` — wl_output.zig:41
  - `WlOutput.owns` — wl_output.zig:74
  - private: sendState 78, bindOutput 105, onOutputDestroy 118, outputRequest 127

## Comparison

| Our item | Ours (semantics) | wlroots (file:line) | smithay (file:line) | Verdict |
|---|---|---|---|---|
| Mode (output.zig:19) | fixed mode, refresh as ms interval | `wlr_output_mode` wlr_output.h:31-36; refresh in mHz:33; preferred flag:34 | `Mode` output.rs:80-84; refresh in mHz:83; Copy+Eq | close; unit differs (ours interval ms vs mHz rate), ours lacks preferred flag |
| Output struct (output.zig:26) | mode/scale/transform/enabled/size, impl ptr, events frame/commit/destroy | `wlr_output` wlr_output.h:179-274; adds modes list, current_mode, commit_seq:223, frame_pending:217, needs_frame:215, subpixel, adaptive_sync, render_format, swapchain:253-268, cursors, layers | `Output` output.rs:245-247 Arc+Mutex handle; `Inner` output.rs:218-236 (name, description, physical, location, modes, current/preferred, instances, surfaces) | divergent; ours is a plain struct, ~1/4 the state of wlroots |
| State (output.zig:56) | 5 committed bits: enabled/scale/transform/mode/buffer; damage rides along | `wlr_output_state` wlr_output.h:114-140; 14 fields incl. layers, timelines, color transform, image description, tearing, allow_reconfiguration (enum wlr_output.h:65-75) | no state object; `change_current_state` output.rs:380-407 takes per-field Options | divergent; ours covers core subset only |
| State.init/deinit (output.zig:75/79) | alloc + free damage region | `wlr_output_state_init/finish` wlr_output.h:468/472 | N/A (no state object) | close for our field set; wlroots state owns buffer/layer refs |
| Impl (output.zig:85) | test and commit both mandatory | impl->test optional: test_state returns true when NULL output.c:731-734; impl->commit asserted wlr_output_init output.c:345 | N/A (backend delegates, no vtable) | divergent; ours cannot skip validation |
| Output.create (output.zig:94) | alloc + set mode/impl/data + init signals | `wlr_output_init` output.c:342-379; applies initial state:376-378 | `Output::new` output.rs:261-292 (name + PhysicalProperties) | close; ours takes mode instead of physical props |
| Output.destroy (output.zig:131) | emit destroy, call impl.destroy, free | `wlr_output_destroy` output.c:443 + `wlr_output_finish` output.c:391-432 (tears down cursors, layers, swapchains, idle sources) | no destroy; Arc refcount, `WeakOutput::upgrade` output.rs:456-458, `is_alive`:462 | close; ours skips cursor/layer/swapchain teardown (none exist) |
| Output.commitState (output.zig:140) | impl.test then impl.commit, apply fields, emit commit | split: `wlr_output_test_state` output.c:718-745 + `wlr_output_commit_state` output.c:793-830 | `change_current_state` output.rs:380-407 (no backend test; updates Inner then rebroadcasts) | divergent; see Gaps 1-4, 6 |
| Output.sendFrame (output.zig:162) | unconditional emit | `wlr_output_send_frame` output.c:833-837 (clears frame_pending:834, only emits if enabled:835); `wlr_output_schedule_frame` output.c:848-861 (idle timer + pending no-op:854-856) | N/A (no frame scheduling in output module) | divergent; no frame_pending guard, no enabled check, no coalescing |
| WlOutput.create (wl_output.zig:41) | one global per Output; destroy listener | `wlr_output_create_global` output.c:123-137; `output_bind` output.c:82-116 | `Output::create_global` mod.rs:203-211 (version 4:210); bind in handlers.rs:29-84 | close role; ours has no bind event/callback |
| WlOutput.owns (wl_output.zig:74) | resource identity by list membership | N/A (uses user_data: `wlr_output_from_resource` output.c:178-181) | `Output::owns` mod.rs:263-272 (compares resource id) | close; same intent, different mechanism |
| sendState (wl_output.zig:78) | geometry hardcoded 0,0,0,0/unknown/"wayland"/.normal:83-92; single mode current+preferred:93-98; scale hardcoded 1:99; name:100, description:101, done:102 | bind order output.c:100-106; geometry from phys dims+subpixel+transform output.c:17-22; current mode only, no preferred flag output.c:24-35; scale ceil(output->scale) output.c:37-42; desc NULL-safe:53-59 | bind order handlers.rs:44-84; geometry from location+physical+transform mod.rs:166-176; ALL modes with per-mode Current/Preferred flags handlers.rs:56-63; scale integer_scale:74-79; surface.enter replay:80-85; output_bound callback:86 | divergent; ours fabricates geometry/scale/preferred, sends one mode, no enter replay |
| output_version (wl_output.zig:23) | 4 | OUTPUT_VERSION 4 output.c:15 | create_global version 4 mod.rs:210 | same |
| onOutputDestroy (wl_output.zig:118) | remove global, deinit resources, free module | `wlr_output_destroy_global` output.c:139-156 makes resources inert (user_data NULL:145-151) | global drop; `leave_all` mod.rs:327-345 on disable | divergent; ours destroys rather than inerts — RESOLVED 2026-08-09: the wire behaviors differ (libwayland wayland-server.c:443-447 posts WL_DISPLAY_ERROR_INVALID_OBJECT + kills the client on a request to a destroyed object; an inerted resource dispatches with NULL user data), both safe in practice |esource fate depends on external wire lib] |
| release request (wl_output.zig:127-130) | destroy resource | `output_handle_release` output.c:73-76 | no-op request handlers.rs:104-113 | same |
| commit signal payload (output.zig:153-158) | bare `*Output` | `wlr_output_event_commit` wlr_output.h:288-291 (output+when+state), emitted output.c:779-789 | N/A (no commit signal) | divergent; listeners get no state/timestamp |

## Gaps

1. Test/commit split. wlroots exposes `wlr_output_test_state` (output.c:718) and `wlr_output_commit_state` (output.c:793) as separate calls so a compositor can probe without applying, and impl->test is optional (output.c:731-734). Ours fuses both into `commitState` (output.zig:140) and requires test in the vtable (output.zig:87).
2. No unchanged-state short-circuit. wlroots `output_compare_state` (output.c:535-583) strips fields identical to current state before basic test and impl->test/commit (output.c:719-720, 795-796). Ours always runs test+commit with the full state (output.zig:141-142).
3. No buffer lifecycle. wlroots auto-attaches an empty buffer for modesets/enable (`output_ensure_buffer` types/output/render.c:81-126), keeps a per-output swapchain (wlr_output.h:253-268) and unlocks the pending buffer after commit (output.c:826-830, 739-743). Ours hands `state.buffer` to impl.commit and keeps no current-buffer slot (output.zig:156-157).
4. No frame_pending guard. wlroots sets frame_pending=true on commit of an enabled output (output.c:774-776), clears it in send_frame (output.c:834), and `wlr_output_schedule_frame` is a no-op while pending, using an idle timer (output.c:848-861). Ours `sendFrame` emits unconditionally (output.zig:162-164) and there is no schedule/coalesce path.
5. No client rebroadcast on state change. wlroots `output_apply_state` re-sends current mode/geometry/scale to all resources and schedules a done (output.c:274-308; `wlr_output_schedule_done` output.c:169-176). smithay rebroadcasts mode/geometry/scale per instance with done last (mod.rs:218-256; xdg-output updated before wl_output:223-226). Ours sends state only at bind (wl_output.zig:78-103); a committed mode/scale change is never pushed to clients.
6. Bind-time fidelity. Ours hardcodes geometry 0,0,0,0, subpixel unknown, make/model "wayland", transform normal (wl_output.zig:83-92), scale 1 (99), and a fabricated preferred flag (94). wlroots sends phys dims/subpixel/transform (output.c:17-22), ceil(scale) (output.c:37-42), no preferred flag (output.c:24-35). smithay sends location+physical+transform (mod.rs:166-176) and the full mode list with real Current/Preferred flags (handlers.rs:56-63).
7. Missing events and sequencing. wlroots: precommit (output.c:747-770), present + commit_seq (wlr_output.h:223, 308-323), needs_frame (wlr_output.h:215, 233), bind event (output.c:107-112; wlr_output.h:325-328), request_state, description (wlr_output.h:241-244), and commit carries state+timestamp (wlr_output.h:288-291). Ours: frame/commit/destroy only, commit payload bare.
8. No surface enter/leave tracking. smithay tracks surfaces per output and sends wl_surface.enter on bind (handlers.rs:80-85), enter/leave/leave_all (mod.rs:287-345). Ours has no surface tracking in the output module.
9. No xdg-output support. smithay wires zxdg_output_manager_v1 (OutputManagerState::new_with_xdg_output mod.rs:128-139; handlers.rs:131-229). Ours implements wl_output only.
10. No weak/user-data model. smithay Output is Arc-cloneable with UserDataMap, downgrade/upgrade, WeakOutput (output.rs:411-464); wlroots carries `void *data` plus addon set (wlr_output.h:270-274). Ours uses one owning pointer + impl-owned data (output.zig:33-34).
11. No fractional/per-client scale. smithay Scale enum with integer_scale/fractional_scale (output.rs:177-212) and per-client scale re-send (mod.rs:181-186; handlers.rs:44-50). Ours stores f32 and always sends 1 (wl_output.zig:99).
12. Destroy does not inert resources. wlroots nulls user_data on bound wl_output resources (output.c:145-151) so late requests are safe. Ours deinits the resource list and frees the module (wl_output.zig:118-125); bound resources are neither inerted nor destroyed by this code [RESOLVED 2026-08-09: a late request then hits the destroyed-object path — libwayland posts INVALID_OBJECT and kills the client (wayland-server.c:443-447) — a different but safe wire outcome; no NULL-data dispatch hazard].vior delegated to external wire library, not verifiable here].

## Verdict

~40% parity: the atomic-state core (committed bitmask, test/commit hooks, transform-size update) mirrors wlroots 0.20.2, and the wl_output global shape matches both references; protocol version 4 matches. Riskiest divergences: (1) fusing test+commit and missing the unchanged-state short-circuit makes every commit go through the backend, inviting needless modesets; (2) no frame_pending guard means duplicate frame events per vblank; (3) no rebroadcast of committed mode/scale to clients, so a scale or mode change leaves clients stale until rebind; (4) fabricated bind-time geometry/scale/preferred, which is the client-visible contract. Gap 12 (resource inerting on destroy) needs verification against the external wire library before the module can claim destroy safety.
