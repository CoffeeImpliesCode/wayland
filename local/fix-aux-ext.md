# fix-aux-ext — presentation-time + screencopy + fractional-scale + viewporter

All O: citations re-verified against current source. Drifts found and corrected inline: surface.zig destroy emit moved to :394-395 (was :396-397); main.zig getFramebuffer moved to :1921-1931 (was :1923-1928); presentation.zig synthetic present is :218-225 (was :219-223); viewporter.zig and fractional_scale.zig line numbers match the comparison as of this read.

### F-AX-1 viewporter use-after-free on wl_surface destroy [CRITICAL] → FIX (Phase 0 — FIRST)
- Files: src/shell/viewporter.zig — `ViewportRes` (:86-91, raw `surface` at :88), `get_viewport` create/append (:104-130), `viewportRequest` set_source (:141-158) / set_destination (:159-171), `viewportDestroy` (:175-183), module doc (:3-15). src/compositor/surface.zig — `s.events.destroy.emit(s)` (:394-395); destroy is legal with a live viewport because only `role_resource != null` is rejected (:1103-1107), and wp_viewport never calls `assignRole` (viewporter.zig has no role wiring).
- Mechanism to reuse (verified): the surface-destroy listener pattern of `presentation.zig` `Feedback` — a `destroy_listener: wire.Listener(*Surface)` field on the state (:336), init at (:160), wired `surface.events.destroy.add(&fb.destroy_listener)` (:172), handler via `@fieldParentPtr("destroy_listener", listener)` (:306-309), and a teardown that detaches the link *before* pruning/freeing (:388-395). Same pattern in surface_node.zig (:98-99, :391-402, :487-491). Use presentation.zig's shape: the state (viewport resource) can outlive the surface, exactly like Feedback.
- Change:
  1. `ViewportRes`: `surface: ?*Surface` (nullable) + `destroy_listener: wire.Listener(*Surface)`.
  2. `get_viewport`: after `res.setHandler(...)` (:128) add `surface.events.destroy.add(&vres.destroy_listener)`.
  3. New handler:
  ```zig
  fn onSurfaceDestroy(listener: *wire.Listener(*Surface), _: *Surface) void {
      const vres: *ViewportRes = @fieldParentPtr("destroy_listener", listener);
      // Detach (a later viewportDestroy must not touch the dead surface's
      // listener list), prune (exists check :106-111 must not false-positive
      // on a recycled address), mark inert (requests post no_surface).
      vres.destroy_listener.link.remove();
      const vp = vres.vp;
      const idx = std.mem.indexOfScalar(*ViewportRes, vp.objects.items, vres) orelse 0;
      if (idx < vp.objects.items.len and vp.objects.items[idx] == vres) {
          _ = vp.objects.orderedRemove(idx);
      }
      vres.surface = null;
  }
  ```
  4. Guard both requests — first line of `.set_source` (:141) and `.set_destination` (:159): `const s = vres.surface orelse { res.postError(.no_surface, "wp_viewport set after wl_surface destroyed"); return; };` and use `s` for the pending writes (F-AX-11 rewrites these bodies; keep the guard). `.destroy` (:140) stays unguarded — the protocol raises no_surface on all requests *except* destroy (viewporter.xml).
  5. `viewportDestroy` (:175-183): add `vres.destroy_listener.link.remove()` before `vp.allocator.destroy(vres)` — covers resource-first death (explicit destroy or client teardown while the surface lives; the freed link must not stay in the surface's listener list before `destroy.emit`). The existing `orelse 0` + identity check (:178-180) already tolerates a pre-pruned entry, so surface-first death needs no change there.
  6. Update the module doc (:3-15): the "double-buffered" / "validated at commit" claims are false today (F-AX-11/12 deliver them); document the inert-after-death + no_surface behavior.
- Test: wire test in viewporter.zig (fixture pattern of xdg.zig `TestServer` :2207-2318 or screencopy.zig `TestServer`): "surface destroy makes the viewport inert: set_destination posts no_surface" — get_viewport on surface A, `A.resource.destroy()`, then send `wp_viewport.set_destination(100, 100)`; assert the viewport resource received `no_surface` (protocolError-style listener), the compositor did not dereference the freed Surface (run under `testing.allocator`), and a second test "destroying the viewport after the surface posts no double free" destroys the wl_surface then the wp_viewport resource and asserts clean teardown.
- Acceptance: destroying wl_surface with a live wp_viewport is safe (no UAF, no leak, no double free under the test allocator); any set_source/set_destination after surface death posts `no_surface` on the viewport resource; the viewport_exists check stays correct; F-AX-13 is closed by this spec.
- Risk: the only double-remove guard is the `orelse 0` identity check in `viewportDestroy` — the handler must prune before any later request can dispatch. Adjacent: F-AX-11/F-AX-12 rewrite the same request bodies in Phase 1 — land this first so the guards are in place before the rewrite.

### F-AX-10 fractional-scale stale ScaleState after surface destroy [MINOR] → FIX (Phase 0)
- Files: src/shell/fractional_scale.zig — `ScaleState` (:82-88, raw `surface` at :85), `get_fractional_scale` exists check (:109-114) + create/append (:115-131), `scaleDestroy` (:156-166), header doc (:1-15) which *claims* teardown frees the state — no code does.
- Change: same listener pattern as F-AX-1 (reuse presentation.zig Feedback shape):
  1. `ScaleState`: `surface: ?*Surface` + `destroy_listener: wire.Listener(*Surface)`.
  2. `get_fractional_scale`: after `res.setHandler(...)` (:131) add `surface.events.destroy.add(&st.destroy_listener)`.
  3. New `onSurfaceDestroy`: detach link, prune from `fs.objects` (`indexOfScalar` + `orderedRemove`, mirroring `scaleDestroy` :159-164), `st.surface = null`.
  4. `scaleDestroy` (:156-166): add `st.destroy_listener.link.remove()` before `fs.allocator.destroy(st)` (resource-first death: client teardown).
  5. No request guards needed: the only request is `.destroy` (:149-154), which never dereferences `st.surface`; the object is inert by construction.
  6. Fix the header doc (:8-11): surface teardown now detaches + marks; the resource destroy frees.
- Test: "surface destroy prunes the fractional-scale entry" — get_fractional_scale for surface A, destroy A's wl_surface, then get_fractional_scale for a new surface (allocated after A, exercising address reuse under the test allocator); assert no `fractional_scale_exists` error and the new object receives its event; teardown (manager + surfaces) is clean with no leak/double-free.
- Acceptance: after wl_surface.destroy the `fs.objects` list holds no entry for it; a surface at a recycled address can bind a fractional-scale object (no false positive); no UAF/leak.
- Risk: minimal — same prune pattern as `scaleDestroy`, whose `orelse 0` identity guard already tolerates a pre-pruned entry.

### F-AX-11 wp_viewport.set_destination single-buffered; viewport destroy never resets [MAJOR] → FIX (Phase 1)
- Files: src/compositor/surface.zig — `State` (:106-176), `Committed` mask (:178-196), `swapState` (:961-1003), `viewport_dst` field (:259-262, removed), `validatePending` (:678-691, math reused by F-AX-12). src/shell/viewporter.zig — set_destination (:159-171), set_source (:141-158), viewportDestroy (:175-183). src/scene/surface_node.zig — `surfaceSize` (:522-536, `viewport_dst` read at :535; verified sole consumer — grep shows no other reads).
- Change (mirror wlroots pending->viewport, wlr_viewporter.c:63-107 and the destroy reset :109-111):
  1. surface.zig `State`: add
  ```zig
  /// wp_viewport crop/scale state (wlroots wlr_surface_state.viewport).
  viewport: Viewport = .{},
  pub const Viewport = struct {
      has_src: bool = false,
      src: geom.FRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
      has_dst: bool = false,
      dst: geom.Size = .{ .w = 0, .h = 0 },
  };
  ```
  2. `Committed`: add `viewport: bool = false`; in `swapState` add `if (pending.committed.viewport) current.viewport = pending.viewport;` (F33 pattern, same as transform/scale). Pending viewport persists across commits; a commit without the bit keeps the current value (correct per protocol).
  3. Delete `viewport_dst` from `Surface` (:259-262) — clean cutover, no aliases.
  4. viewporter set_destination (:159-171) — write pending only:
  ```zig
  .set_destination => |r| {
      const s = vres.surface orelse { res.postError(.no_surface, "..."); return; }; // F-AX-1 guard
      if (r.width == -1 and r.height == -1) {
          s.pending.viewport.has_dst = false;
      } else if (r.width <= 0 or r.height <= 0) {
          res.postError(.bad_value, "wp_viewport.set_destination: non-positive size");
          return;
      } else {
          s.pending.viewport.has_dst = true;
      }
      s.pending.viewport.dst = .{ .w = r.width, .h = r.height };
      s.pending.committed.viewport = true;
  },
  ```
  Do the same move for set_source (:141-158): `has_src`/`src` + committed bit (keep the -1 unset and bad_value checks). Drop `vres.state` from `ViewportRes` (:90) — it becomes redundant; the pending state is the single source of truth.
  5. viewportDestroy (:175-183), before the free, reset the pending viewport so the *next* commit unsets (protocol: "the change will be applied on the next wl_surface.commit"; wlr_viewporter.c:109-111):
  ```zig
  if (vres.surface) |s| {
      s.pending.viewport.has_src = false;
      s.pending.viewport.has_dst = false;
      s.pending.committed.viewport = true;
  }
  ```
  6. surface_node.zig `surfaceSize` (:522-536):
  ```zig
  const vp = s.current.viewport;
  if (vp.has_dst) return vp.dst;
  if (vp.has_src) return .{ .w = @intFromFloat(vp.src.width), .h = @intFromFloat(vp.src.height) };
  return size;
  ```
  (Protocol: size becomes dst if set; else the src rect size when src set and dst unset — crop without scaling; else buffer-derived. The `@intFromFloat` is exact because F-AX-12's bad_size validation guarantees integral src when dst is unset.)
- Test: wire test in viewporter.zig: "set_destination is double-buffered and cleared by viewport destroy" — get_viewport, set_destination(200,100), assert current state has no dst before commit; commit (with a buffer), assert the scene node's `kind.buffer.dst_width/dst_height` == 200x100 (assert style of surface_node.zig :686-687); commit again with no viewport request, assert dst persists; destroy the viewport resource, commit a buffer again, assert node size is back to the buffer-derived size. Second test: "destroy clears only at the next commit" — destroy the viewport, assert size unchanged until the next commit carries the reset bit.
- Acceptance: destination applies only via wl_surface.commit; destroying the wp_viewport returns the surface to buffer-derived size on the next commit; the single-buffered `viewport_dst` write and the stale-after-destroy override are gone.
- Risk: the F33 committed-mask semantics mean a buffer-only commit does not clear an unset dst (correct — matches wlroots and the protocol). `surfaceSize`'s src branch depends on F-AX-12's bad_size guarantee — land both in Phase 1 together or guard with an assert. Damage on dst change flows through the existing node geometry-change path (Previous snapshot + `onCommit` → `update()`, surface_node.zig :463-466) — no new wiring.

### F-AX-12 wp_viewport source crop not validated or applied [MAJOR] → FIX (Phase 1)
- Files: src/shell/viewporter.zig — set_source (:141-158), new client_commit listener wired at get_viewport (:104-130), module doc (:3-15, false "validated at commit" claim). src/compositor/surface.zig — `events.client_commit` (:288, emitted at commit step 3, :512, before the deferral decision :517 and applyCommit — correct ordering for wlroots parity), pending viewport state from F-AX-11, `validatePending` math (:683-690, transformedSize / scale). src/scene/surface_node.zig — `update()` buffer-node geometry (:127-180), `surfaceSize` (:522-536). src/scene/scene.zig — `SceneBufferNode.src: ?FRect` already exists (:290-298) and `renderBuffer` already passes it to `pass.addTexture` (:426-434) — the crop application point exists and is unused by the viewporter.
- Change (mirror wlr_viewporter.c:135-167 — validation lives in the viewporter, not the core surface module):
  1. Add `client_commit_listener: wire.Listener(*Surface)` to `ViewportRes`; wire `surface.events.client_commit.add(&vres.client_commit_listener)` at get_viewport; detach it in the same two teardown paths as F-AX-1 (`onSurfaceDestroy` and `viewportDestroy`).
  2. Validation handler:
  ```zig
  fn onSurfaceClientCommit(listener: *wire.Listener(*Surface), s: *Surface) void {
      const vres: *ViewportRes = @fieldParentPtr("client_commit_listener", listener);
      const vp = &s.pending.viewport;
      // bad_size: fractional src with no dst (wlr_viewporter.c:145-152).
      if (!vp.has_dst and
          (std.math.floor(vp.src.width) != vp.src.width or
           std.math.floor(vp.src.height) != vp.src.height))
      {
          vres.res.postError(.bad_size, "wp_viewport.set_source: fractional source without destination");
          vp.has_src = false;
          vp.has_dst = false;
          return;
      }
      // out_of_buffer: src beyond the pending buffer's surface size
      // (wlr_viewporter.c:135-142, 154-164). Surface size = transformed
      // buffer size / scale; validatePending (:683-690) guarantees integrality.
      if (vp.has_src) {
          if (s.pending.buffer) |b| {
              const size = s.pending.transform.transformedSize(b.width, b.height);
              const w = size.w / s.pending.scale;
              const h = size.h / s.pending.scale;
              if (vp.src.x + vp.src.width > w or vp.src.y + vp.src.height > h) {
                  vres.res.postError(.out_of_buffer, "wp_viewport.set_source: source out of buffer bounds");
                  vp.has_src = false;
                  vp.has_dst = false;
                  return;
              }
          } // NULL buffer: out_of_buffer is NOT raised (protocol, viewporter.xml).
      }
  }
  ```
  post_error is fatal, so clearing the pending viewport fields keeps the aborting commit from applying an invalid crop (wlroots' wlr_surface_reject_pending clears pending state; the client dies either way).
  3. Apply the crop: in surface_node.zig `update()` where dst_width/dst_height are set (:127-155, :179-180), also set the node's src: `bn.src = if (s.current.viewport.has_src) s.current.viewport.src else null;` The protocol defines src in surface-local coordinates (after buffer_transform + buffer_scale, viewporter.xml transform order); texture pixels = src × buffer_scale under the inverse transform — at this compositor's scale 1 / no transform it is a direct pass-through. Add a comment that future scale support must multiply by `current.scale` (and inverse-transform) before setting `bn.src`.
  4. `surfaceSize` (from F-AX-11) already yields src-size-when-no-dst, so crop-without-scale sizes the surface correctly.
  5. Fix the module doc (:3-15) — state the real validation + application behavior.
- Test: two wire tests in viewporter.zig: (a) "out_of_buffer: source outside the buffer is rejected at commit" — attach a 64x64 shm buffer, set_source(0,0,100,100), commit; assert the viewport resource received `out_of_buffer` and the surface's current viewport has_src is false (no crop applied); (b) "bad_size: fractional source without destination" — set_source(0,0,10.5,10) fixed-point, commit; assert `bad_size`. Positive test: "crop is applied to the scene node" — 64x64 buffer, set_source(8,8,32,32) + set_destination(32,32), commit; assert no error and `bn.src` on the scene node equals the rect (and dst_width/dst_height == 32).
- Acceptance: a client requesting a real crop gets it (node src crop; surface size = src rect when dst unset, dst when set); out-of-bounds crops post `out_of_buffer` at commit instead of rendering garbage; fractional src without dst posts `bad_size`; a rejected commit applies no crop state.
- Risk: the src→texture-pixel mapping is scale-1-only (flagged in code). Validation reads the *pending* state via client_commit, which fires before applyCommit (:512 vs :545+) — if the commit pipeline steps are ever reordered, re-verify. Node damage on crop change rides the existing geometry-change path (onCommit → update → Previous snapshot diff), same as F-AX-11.

### F-AX-2 synthetic present not gated on a real display [MAJOR] → DEFER — Trigger: a real output present event lands (backend reports actual scanout/flip completion — note 135 F8). Today `output.events.frame` (output.zig:51) fires synchronously with commit (output.zig:222) and main.zig calls `presentation.present(...)` immediately after commitState with flags 0 (server/main.zig:1510); `present()` synthesizes tv from CLOCK_MONOTONIC at call time (:218-219) with no commit_seq gating. | Prereq: note 135 F8 output present event; then feedback must queue per-output (wlroots presentation_surface_queued_on_output) and deliver presented only when `output_committed && commit_seq == output_commit_seq` (wlroots presentation_time.c:277-301, 311-339); dropped frames must be discarded/superseded, not reported presented. | Scope: present() rework (queueing + commit_seq on Feedback, presentation.zig) + main.zig call-site move to the present event + backend flip-feedback plumbing — 1-2 days.

### F-AX-3 presented flags always 0 [MAJOR] → DEFER — Trigger: the real output present event of F-AX-2. | Prereq: F-AX-2. `present()` already passes flags through (clearing zero_copy, presentation.zig:224-225); the missing piece is a real flags source: the server passes constant 0 (main.zig:1510), where wlroots passes DRM present flags (presentation_time.c:287-301) and KWin sets HW_CLOCK|HW_COMPLETION (+VSYNC for vsync/adaptive-sync, presentationtime.cpp:109-115). | Scope: backend present-result → output present event → main.zig flags plumbing (drm.zig flip event carries the flags) — 2-3 days, largely with F-AX-2.

### F-AX-4 refresh mode-derived, no adaptive-sync zeroing [MINOR] → DEFER — Trigger: the real output present event of F-AX-2. | Prereq: F-AX-2 (present-derived refresh); the version-1 zeroing path additionally needs adaptive-sync support (absent — the zeroing is N/A today). `refresh_ns` is `refresh_msec * 1e6` from the output mode (:221-222, driven by main.zig:1510). | Scope: read refresh from the present event; zero refresh for v1 feedback on adaptive-sync outputs (KWin presentationtime.cpp:116-119) — ~1 day once F-AX-2 exists.

### F-AX-5 screencopy foreign wl_output kills the client [MINOR] → FIX (Phase 2)
- Files: src/screencopy.zig — `capture()` foreign-output branch (:261-265, `cli.postNoMemory()` at :263), the adjacent disabled-output failed-frame pattern to copy (:266-272), the existing test "capturing a disabled output fails the frame" (:1132-1149) as the test model. src/server/main.zig — `outputFromResource` (:1933-1938) is what returns null for a wl_output not owned by this compositor (`wl_output.owns`), making the path reachable.
- Change: replace the kill with the failed-frame pattern already used two lines below (wlroots wlr_screencopy_v1.c:508-511: `output == NULL || !output->enabled` → `send_failed`, never a no_memory disconnect):
  ```zig
  const output = sc.output_from_resource(sc.output_ctx, output_resource) orelse {
      // Foreign wl_output: fail the frame, don't kill the client
      // (wlroots wlr_screencopy_v1.c:508-511).
      const failed = server.zwlr.ScreencopyFrameV1.create(cli, 1, frame_id) catch return;
      failed.sendFailed();
      return;
  };
  ```
  Keep `const cli = output_resource.getClient();` (:261). The `!output.enabled` branch (:266-272) already matches wlroots; only the null branch changes.
- Test: "capturing a foreign wl_output fails the frame" — mirror :1132-1149: bind the manager, create a wl_output resource NOT owned by the compositor's wl_output module (or call the manager request with a bare/unregistered resource), `captureOutput`; pump; assert `events.failed_count == 1`, `events.buffer_count == 0`, AND the client still dispatches (no wire error posted, no disconnect — assert the connection survives a subsequent request round-trip).
- Acceptance: an unknown/foreign wl_output yields a clean `zwlr_screencopy_frame_v1.failed`; the client is not disconnected; the frame is inert (the `state.finished` guards in `frameRequest` :405-407 already make a failed frame safe).
- Risk: minimal — the failed frame is created bare (not inserted into client_state tracking), exactly like the disabled-output path (:269-272); ensure no `client_state.ref` bookkeeping is added.

### F-AX-6 linux_dmabuf missing (shm-only) [MINOR] → DEFER — Reason: deliberate, documented simplification — screencopy advertises only buffer(+buffer_done) and validates a wl_shm buffer of exact size/format/stride (screencopy.zig:359-360, :405-426); dmabuf event negotiation and copy (wlroots wlr_screencopy_v1.c:592-595) require an allocator with dmabuf support, which the pixman/raylib render path does not expose. | Trigger: the compositor gains a dmabuf-capable allocator/render path. | Prereq: allocator/dmabuf support work. | Scope: linux_dmabuf event when supported + frame_handle_copy dmabuf branch + format/modifier filtering — 3-5 days.

### F-AX-7/8 screencopy damage ordering; overlay_cursor handling [INFO] → ACCEPT — Reason: both are deliberate, outcome-equivalent choices. F-AX-7: damage accumulates from the output commit signal with the accumulator listener armed before the frame's copy listener (screencopy.zig :646-650 arm vs :448-449 copy), so the triggering commit's damage is present when the frame checks isEmpty; wlroots uses output_precommit — same result. F-AX-8: overlay_cursor is satisfied by the compositor's cursor-composited display framebuffer vs the cursor-less base framebuffer via the `get_framebuffer` callback flag (screencopy.zig:13-17, :58-61; main.zig `getFramebuffer` :1921-1931), functionally equivalent to wlroots' software-cursor lock for this renderer. Keep both.

### F-AX-9 fractional-scale preferred_scale sent unconditionally, not settable [MINOR] → FIX (Phase 2)
- Files: src/shell/fractional_scale.zig — module const `preferred_scale: u32 = 120` (:32), unconditional `res.sendPreferredScale(preferred_scale)` in get_fractional_scale (:133), `ScaleState` (:82-88). src/server/main.zig — `FractionalScale.init` (:411-412).
- Change (wlroots sends only when a scale was previously notified, wlr_fractional_scale_v1.c:144-146; smithay only when `preferred_scale` is Some):
  1. Delete the const (:32); add a field to `FractionalScale`: `preferred_scale: ?u32 = null` (null = never set, nothing sent).
  2. get_fractional_scale (:133): `if (self.preferred_scale) |scale| res.sendPreferredScale(scale);`
  3. New compositor-facing API:
  ```zig
  /// Advertise the compositor's preferred scale (numerator over 120) and
  /// notify every existing per-surface object (wlroots notify_scale).
  pub fn setPreferredScale(self: *FractionalScale, scale_numerator: u32) void {
      self.preferred_scale = scale_numerator;
      for (self.objects.items) |st| st.res.sendPreferredScale(scale_numerator);
  }
  ```
  4. main.zig after init (:411-412): `fractional_scale.setPreferredScale(120);` — preserves today's scale-1 behavior (foot gets its 120 on bind) while the value becomes a settable, correctable API; a future scale path calls it on output-scale change (wlroots refines to per-surface notify_scale — note as follow-up, not required for scale-1).
- Test: two wire tests in fractional_scale.zig: (a) "preferred_scale is not sent until set" — get_fractional_scale with `preferred_scale == null`; assert no preferred_scale event; (b) "setPreferredScale notifies existing objects" — get_fractional_scale for two surfaces, call `setPreferredScale(120)`, assert both received the event, and a later get_fractional_scale sends it immediately.
- Acceptance: preferred_scale is emitted only after the compositor sets a scale; `setPreferredScale` updates all live per-surface objects; the value is no longer a hardcoded constant; no client-visible change at scale 1 (main.zig still advertises 120).
- Risk: minimal — the send loop does not mutate `fs.objects` (safe iteration); the F-AX-10 prune keeps the loop free of dead entries.

## Area verdict
6 fixable-now task specs (F-AX-1, F-AX-10 Phase 0; F-AX-11, F-AX-12 Phase 1; F-AX-5, F-AX-9 Phase 2), 4 deferred (F-AX-2/3/4 chained on the note-135 output-present-event work, F-AX-6 on dmabuf), 1 accepted pair (F-AX-7/8). First task: F-AX-1 — the viewporter UAF is the only critical reachable crash in the area and everything else in viewporter (F-AX-11/12) rewrites the same request handlers, so the listener + no_surface guard must land first.
