# cmp-aux-ext — Adversarial comparison: presentation-time + screencopy + fractional-scale + viewporter

Implements the surface of 4 interfaces. Sections: implemented surface, API breadth tables (ours vs wlroots 0.20.2 / smithay v0.7.0-407 / KWin master), adversarial correctness findings (numbered), verdict.

References read directly this round: wlroots types/{wlr_presentation_time.c(340),wlr_screencopy_v1.c(719),wlr_fractional_scale_v1.c(223),wlr_viewporter.c(214)}; smithay src/wayland/{presentation,viewporter,fractional_scale}/mod.rs; KWin src/wayland/{presentationtime.cpp,viewporter.cpp,fractionalscale_v1.cpp}. smithay and KWin implement NO zwlr_screencopy (smithay ships ext-image-copy-capture-v1 instead; KWin has none) — screencopy is compared against wlroots only.

## 1. Implemented surface (our files)

- wp_presentation (stable presentation-time v2): src/presentation.zig
- zwlr_screencopy_manager_v1 / zwlr_screencopy_frame_v1 (v3): src/screencopy.zig
- wp_fractional_scale_manager_v1 / wp_fractional_scale_v1 (v1): src/shell/fractional_scale.zig
- wp_viewporter / wp_viewport (v1): src/shell/viewporter.zig

## 2. API breadth

### 2a. wp_presentation (v2)
| object | version | ours | wlroots | smithay | KWin | gaps |
|---|---|---|---|---|---|---|
| wp_presentation | v2 (presentation.zig:63) | requests feedback+destroy; event clock_id=MONOTONIC (341-347) | v2 (presentation_time.c:10) feedback+destroy; clock_id=MONOTONIC (:162) | v2 (mod.rs:108) feedback+destroy; clock_id configurable (:127-139) | v2 (presentationtime.cpp:40) feedback+destroy; clock_id=MONOTONIC | none on the object itself |
| wp_presentation_feedback | (no requests) | events sync_output+presented+discarded; 1 feedback=1 resource | events all; 1 feedback=1:many resources via synced pending/current (:91-139) | events all; callbacks in double-buffered cached state (mod.rs:206-297) | events all; 1:many via wl_list (presentationtime.cpp:64-78) | behavioral parity; storage differs (see F4) |

### 2b. zwlr_screencopy (v3)
| object | version | ours | wlroots | gaps |
|---|---|---|---|---|
| zwlr_screencopy_manager_v1 | v3 (screencopy.zig:29) | capture_output / capture_output_region / destroy | v3 (wlr_screencopy_v1.c:17) same | none |
| zwlr_screencopy_frame_v1 | inherits manager | events buffer, flags, ready, failed, damage(v2+), buffer_done(v3+); NO linux_dmabuf | same + linux_dmabuf(v3) when allocator supports dmabuf (:592-595); copy accepts dmabuf OR shm | linux_dmabuf missing (shm-only) — F6 |

### 2c. wp_fractional_scale (v1)
| object | version | ours | wlroots | smithay | KWin | gaps |
|---|---|---|---|---|---|---|
| wp_fractional_scale_manager_v1 | v1 (generated) | destroy / get_fractional_scale; fractional_scale_exists error | v1 (fractional_scale_v1.c:12) same | v1 (mod.rs:77) same | v1 (fractionalscale_v1.cpp:26) same | none |
| wp_fractional_scale_v1 | v1 | request destroy; event preferred_scale (sent immediately) | same; preferred_scale sent only after a scale was set (:144-146) | same; only if preferred_scale Some (mod.rs:100-106) | same; only if preferredBufferScale set (fractionalscale_v1.cpp:58-60) | timing of first preferred_scale — F9 |

### 2d. wp_viewporter (v1)
| object | version | ours | wlroots | smithay | KWin | gaps |
|---|---|---|---|---|---|---|
| wp_viewporter | v1 (generated) | destroy / get_viewport; viewport_exists error | v1 (viewporter.c:10) same | v1 (mod.rs:68) same | v1 (viewporter.cpp:17) same | none |
| wp_viewport | v1 | destroy / set_source / set_destination; bad_value on negative/non-positive | same + commit-time out_of_buffer (:135-167) and bad_size (non-integer src w/o dst) | same errors: BadValue at set, BadSize in pre-commit hook, OutOfBuffer in ensure_viewport_valid | same errors (source validated at commit) | ours emits NONE of no_surface / out_of_buffer / bad_size and never crops — F11, F12, F13 |

## 3. Adversarial correctness findings

1. [CRITICAL] Use-after-free in viewporter on wl_surface destroy.
   Ours: viewporter.zig stores a raw `surface: *Surface` in ViewportRes (viewporter.zig:86) and never adds a surface.destroy listener; `ViewportRes` is only pruned by `viewportDestroy` (143-153). wl_surface.destroy is legal because the viewport is not a role (`assignRole` is never called; surface.zig:1103-1107 only rejects destroy when `role_resource != null`), and `Surface.destroy` emits then frees the Surface (surface.zig:396-397). A client that destroys its wl_surface but keeps the wp_viewport resource leaves `vres.surface` dangling; a later `set_destination` writes `vres.surface.viewport_dst = ...` (viewporter.zig:161-170) through freed memory. wlroots ties the viewport to the surface via an addon whose destroy handler frees it (wlr_viewporter.c:122-126). Severity: critical (reachable UAF via wire).

2. [MAJOR] wp_presentation present is synthetic and not gated on a real display.
   Ours: server calls presentation.present(...) immediately after output commitState, before the DRM flip completes (server/main.zig:1510); presentation synthesizes tv from CLOCK_MONOTONIC at call time and a per-output counter seq (presentation.zig:219-223). wlroots: feedback is queued on the output (presentation_surface_queued_on_output, presentation_time.c:311-339) and presented only from the output present event when `output_committed && commit_seq == output_commit_seq` (presentation_time.c:277-301); a dropped frame (flip never presents) never delivers presented — it is superseded/discarded. Consequence: a frame that fails to scan out is still reported presented; timestamps are commit time, not display time; latency/frame-drop tooling reads wrong data. Severity: major.

3. [MAJOR] presented flags are always 0 — never VSYNC / HW_CLOCK / HW_COMPLETION.
   Ours clears ZERO_COPY and passes caller flags through, but the server passes 0 (presentation.zig:224-225; server/main.zig:1510). wlroots passes through the DRM present flags (feedback_handle_output_present, presentation_time.c:287-301); KWin explicitly sets HW_CLOCK|HW_COMPLETION and VSYNC for vsync/adaptive-sync modes (presentationtime.cpp:109-115). Consequence: presentation-time clients (e.g. frame-paced video, benchmarkers) cannot tell the difference between hw-completed/vsync frames and software estimates — they are all 0. Severity: major.

4. [MINOR] refresh is mode-derived, not present-derived; no adaptive-sync v1 zeroing.
   Ours: refresh = refresh_msec*1e6 (presentation.zig:222) from the output mode (server/main.zig:1510). wlroots reads refresh from the actual present event (presentation_time.c:288-292) and zeroes it for version-1 clients on an adaptive-sync output; KWin does the same (presentationtime.cpp:116-119). Ours has no adaptive sync so the zeroing path is N/A today, but the refresh value is the mode's nominal rate even when the real presented refresh differs. Severity: minor.

5. [MINOR] screencopy: foreign wl_output kills the client instead of failing the frame.
   Ours: `output_from_resource(...) orelse { cli.postNoMemory(); return; }` (screencopy.zig:261-264) — a fatal no_memory error disconnects the client. wlroots: `output == NULL || !output->enabled` sends `failed` on the frame (wlr_screencopy_v1.c:508-511). Consequence: a client that passes a wl_output not owned by this compositor is killed for a benign mistake instead of getting a clean `failed`. Severity: minor (path hard to reach: clients only bind this compositor's outputs), but the kill behavior is disproportionate.

6. [MINOR] screencopy is shm-only: no linux_dmabuf, no dmabuf copy.
   Ours advertises only `buffer`(+`buffer_done`) and rejects dmabuf buffers in copy (screencopy.zig:359-360; copyRequest validates a wl_shm buffer, 405+). wlroots v3 sends linux_dmabuf when the allocator supports it (:592-595) and copies dmabuf buffers (frame_handle_copy, dmabuf branch). Consequence: a client that captures via dmabuf (zero-copy path) gets invalid_buffer; breadth gap. Severity: minor (documented simplification of a shm-only compositor).

7. [INFO] screencopy damage accumulation order is correct but wired to commit, not precommit.
   Ours accumulates from the output commit signal (onClientOutputCommit, screencopy.zig:650) with the accumulator listener added before the frame's copy listener at copyRequest (clientArmDamage 646 then 448), so the triggering commit's damage is present when the frame checks `isEmpty()`. wlroots accumulates from output_precommit (screencopy_damage_handle_output_precommit). Equivalent outcome; no defect.

8. [INFO] screencopy overlay_cursor handled via composited framebuffer, not a cursor lock.
   Ours selects the cursor-composited vs cursor-less base framebuffer (screencopy.zig:13-17; server/main.zig:1923-1928). wlroots locks software cursors to force them into the front buffer (:443-446). Functionally equivalent for our renderer; no defect.

9. [MINOR] fractional-scale preferred_scale is sent immediately and unconditionally at get_fractional_scale.
   Ours: `res.sendPreferredScale(preferred_scale)` on object creation (fractional_scale.zig:132-133). wlroots sends only when a scale was previously notified (`info->scale != 0`, wlr_fractional_scale_v1.c:144-146); smithay only when `preferred_scale` is Some (mod.rs:100-106); KWin only when preferredBufferScale is set (fractionalscale_v1.cpp:58-60). Ours hardcodes 120/120 and has no compositor API to update it, so it can never change. Since this compositor is scale 1, the immediate 120 is harmless (arguably more helpful than the refs' 'nothing yet'), but it diverges from the refs' 'only when a scale is known' timing and cannot ever correct if scale support lands. Severity: minor.

10. [MINOR] fractional-scale leaves a stale ScaleState entry after surface destroy.
    ScaleState holds a `surface: *Surface` (fractional_scale.zig:98) with no surface.destroy listener; on wl_surface.destroy the entry stays in fs.objects pointing at freed memory until manager teardown. Only ever pointer-compared in get_fractional_scale (109-111, no deref), so no UAF — a stale entry that also makes the exists check wrong (a re-bound surface at the same address would false-positive). wlroots destroys the object via its surface addon (fractional_scale_v1.c:38-55). Severity: minor.

11. [MAJOR] wp_viewport.set_destination is single-buffered (applied immediately), and viewport destroy never resets it.
    Ours writes `vres.surface.viewport_dst` on the request, not into double-buffered pending state (viewporter.zig:161-170), and `viewportDestroy` leaves it set (143-153). wlroots writes pending state applied at commit and `viewport_destroy` resets has_dst=false so the next commit unsets (wlr_viewporter.c:81-82, 109-111); KWin writes to pending and resets on destroy (viewporter.cpp:93-100); smithay uses the double-buffered cached state and resets on destroy (mod.rs:185-192, 230-233). Consequence: the destination override persists after the viewport is destroyed (a client that destroys its viewport expects the surface to return to buffer-derived size on the next commit — ours keeps the override); and the value takes effect even if the carrying commit never happens. Severity: major (protocol double-buffer violation, observable via viewport.destroy).

12. [MAJOR] wp_viewport source crop is neither validated nor applied.
    Ours records src in set_source (viewporter.zig:127-136) but has no commit listener, never raises out_of_buffer or bad_size, and the renderer draws the whole buffer. The doc comment claims "the source is validated against the buffer at commit like wlroots" — no such validation exists anywhere ([INFERENCE] confirmed: no out_of_buffer/bad_size/reject in src/). wlroots checks source-bounds against the buffer and integer-source-without-dst at commit, rejecting with OUT_OF_BUFFER / BAD_SIZE (wlr_viewporter.c:135-167); smithay does the same (pre_commit_hook + ensure_viewport_valid). Consequence: a client requesting a real crop gets the whole buffer (wrong output) with no error; a client that crops out of bounds is silently served garbage instead of rejected. Severity: major.

13. [INFO] wp_viewport no_surface error not implemented.
    wlroots/smithay/KWin raise NO_SURFACE if a set_source/set_destination arrives after the wl_surface died (wlr_viewporter.c:71-77; smithay mod.rs:210-223). Ours would deref the dangling `surface` (see F1) rather than posting the error. Severity: info (subsumed by the F1 UAF).

## 4. Verdict

Breadth: all four interfaces advertise the same versions as wlroots/smithay/KWin (presentation v2, screencopy v3, fractional-scale v1, viewporter v1). Requests/events are complete except: screencopy omits linux_dmabuf (shm-only) and the viewport error set (no_surface / out_of_buffer / bad_size) is not implemented. smithay and KWin have no zwlr_screencopy, so that table is wlroots-only.

Correctness: weakest in viewporter — a reachable UAF (F1, critical), single-buffered destination that destroy fails to reset (F11), and an unvalidated+unapplied source crop (F12). presentation is functional and the sync_output/supersede/discard lifecycle now matches, but the present path is synthetic with no commit_seq gating (F2) and flat flags (F3) — a consequence of the deferred F8 output-present-event work, so presentation timestamps cannot be trusted for latency/frame-drop measurement until a real present event lands. screencopy is clean on buffer constraints and release ordering (exact-stride rejection, release-after-ready match wlroots), with only the shm-only breadth gap and the foreign-output no_memory-kill (F5) as defects. fractional-scale is benign at constant scale 1 but cannot ever update its scale and leaks a stale object on surface death.

Recommended priorities: (1) wire viewporter to surface destroy (fix F1 UAF first), (2) double-buffer viewport state + reset on destroy + commit-time source validation, (3) add a real output present event to drive presentation timestamps/flags/commit_seq (closes F2/F3 and the deferred 135 F8).
