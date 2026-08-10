# Output/Presentation/Screencopy/Backends — function-level f2f (round 2)

Modules: src/output/wl_output.zig, src/output/output.zig, src/presentation.zig,
src/screencopy.zig, src/backend/{headless,drm,libinput,backend}.zig.
References (all read directly this round):
- wlroots 0.20.2: types/output/output.c (1020), include/wlr/backend.h,
  backend/headless/{backend,output}.c, backend/drm/{backend,drm,atomic,properties}.c,
  backend/libinput/{backend,events,pointer}.c, types/wlr_presentation_time.c (339),
  types/wlr_screencopy_v1.c (718), include/wlr/backend/interface.h.
- smithay v0.7.0-407-g5fb12b87 (v0.7.0 + 407 commits; file lines cited): src/wayland/
  output/{mod,handlers}.rs, src/wayland/presentation/mod.rs, src/backend/libinput/
  mod.rs, src/backend/drm/{dumb.rs,surface/atomic.rs,device/atomic.rs}.
  NO headless backend exists in smithay v0.7.0 (src/backend/ = allocator, drm, egl,
  input, libei, libinput, renderer, session, udev.rs, vulkan, winit, x11) — headless
  rows are wlroots-only.
- KWin master 573c16d (2026-08-08): src/wayland/output.cpp (347), output.h.
- raylib backend (src/server/raylib*.zig): ours-only, not in any reference; noted.

Version facts: ours wl_output=4 (wl_output.zig:23) = wlroots OUTPUT_VERSION 4
(output.c:13) = smithay create_global v4 (mod.rs:210) = KWin s_version 4
(output.cpp:47). presentation v2 = wlroots PRESENTATION_VERSION 2
(presentation_time.c:10) = smithay global v2 (mod.rs:108). screencopy v3 =
wlroots SCREENCOPY_MANAGER_VERSION 3 (wlr_screencopy_v1.c:17).

## 1. wl_output — function table

| Ours | Ours (what it does) | wlroots | smithay | KWin | Verdict |
|---|---|---|---|---|---|
| Mode (output.zig:19) | width/height/refresh_msec interval | wlr_output_mode wlr_output.h:31-36 (refresh mHz, preferred flag) | Mode output.rs:80-84 (mHz) | modeSize+refreshRate output.cpp:60-62 | same shape; unit differs, no preferred flag |
| Output struct (output.zig:26) | mode/scale/transform/enabled/size + impl + 3 signals | wlr_output wlr_output.h:179-274 (modes, commit_seq, frame_pending, needs_frame, swapchains, cursors, layers) | Output output.rs:245-247 Arc+Mutex + Inner (instances, surfaces, handle) | OutputInterface output.cpp:49-66 | ours ~1/4 state; no commit_seq/frame_pending |
| Output.State (output.zig:56) | 5 committed bits | wlr_output_state wlr_output.h:114-140 (14 fields) | no state object; per-field change_current_state output.rs:380-407 | N/A (signal-driven) | core subset only |
| State.init/deinit (output.zig:75/79) | damage region alloc/free | wlr_output_state_init/finish wlr_output.h:468/472 | N/A | N/A | close for our fields |
| Impl (output.zig:85) | test+commit+destroy, all mandatory | impl->test OPTIONAL (output.c:731-734); commit asserted (output.c:345) | N/A (no vtable) | N/A | ours cannot skip test |
| Output.create (output.zig:94) | alloc, set mode, init signals | wlr_output_init output.c:342-379 + applies initial state:376-378 | Output::new output.rs:261-292 | OutputInterface ctor output.cpp:87-150 | close; ours takes mode not physical props |
| Output.destroy (output.zig:131) | emit destroy, impl.destroy, free | wlr_output_destroy output.c:443 + finish output.c:391-432 (cursors/layers/swapchain/idle teardown) | Drop/WeakOutput output.rs:456-462 | ~OutputInterface output.cpp:196-200 | close; no swapchain/cursor teardown (none exist) |
| Output.commitState (output.zig:140) | test then commit then apply fields then emit commit | split test_state output.c:718-745 + commit_state output.c:793-830 (unchanged-strip output.c:535-583, ensure_buffer, precommit, unlock) | change_current_state output.rs:380-407 | N/A | divergent, see F2-F4 |
| Output.sendFrame (output.zig:162) | unconditional emit | wlr_output_send_frame output.c:833-837: frame_pending=false, emit only if enabled; schedule_frame output.c:848-861 idle-coalesced | N/A | N/A | no guard, no schedule (F4) |
| WlOutput.create (wl_output.zig:41) | one global per Output + destroy listener | wlr_output_create_global output.c:123-137 + output_bind output.c:82-116 | Output::create_global mod.rs:203-211; bind handlers.rs:29-84 | wl_output global ctor output.cpp:87+ | close; ours has no bind event |
| WlOutput.owns (wl_output.zig:74) | list-membership identity | wlr_output_from_resource output.c:178-181 (user_data) | Output::owns mod.rs:263-272 (resource id) | N/A | same intent |
| sendState (wl_output.zig:78) | bind-time only: geom(0,0,0,0,unknown,"wayland"/"wayland-m2",normal) 83-92; ONE mode current+preferred 93-98; scale 1 (99); name/desc (100-101); done (102) | bind order output.c:100-106: geometry(phys,subpixel,transform) 17-22, current mode 24-35 (NO preferred flag), scale ceil 37-42, name 45-51, desc 53-59, done 61-66; rebroadcast on change output.c:274-308 + schedule_done 169-176 | bind handlers.rs:44-84: geometry 44-49, ALL modes with real Current/Preferred 56-63, name/desc v4 65-68, scale v2 70-74, done 75, enter replay 80-85, output_bound 86; rebroadcast wl_change_current_state mod.rs:218-256 | bind output.cpp:139-149: name(v4) 140-141, desc 142, mode 143, scale 144, geometry 145, done 146; rebroadcast via LogicalOutput signals 150-194 + doneTimer batch 96-105 | divergent: ours fabricates geometry/scale/preferred, one mode, no rebroadcast (F5, F6) |
| bindOutput (wl_output.zig:105) | create resource, append list, sendState | output_bind output.c:82-116 + bind event 107-112 | bind handlers.rs:29-86 | output_bind_resource output.cpp:139-149 | ours: no bind signal |
| onOutputDestroy (wl_output.zig:118) | remove global, deinit list, free module; resources NOT inerted | wlr_output_destroy_global output.c:139-156 inerts resources (user_data=NULL) | leave_all on disable mod.rs:327-345 | remove() output.cpp:208+ | [RESOLVED 109:12] wire-safe but different |
| outputRequest (wl_output.zig:127) | release → destroy | output_handle_release output.c:73-76 | no-op request handlers.rs:104-113 | output_release output.cpp:121-123 | same |
| commit signal payload (output.zig:153-158) | bare *Output | wlr_output_event_commit wlr_output.h:288-291 (output+when+state), emitted output.c:775-789 | N/A | N/A | listeners get no state/when (F8) |

Ordering note: wlroots/ours/smithay send geometry FIRST then mode; KWin sends
name/description FIRST (output.cpp:139-143). All five end with done. KWin and
wlroots both batch done via a 0ms timer (KWin doneTimer output.cpp:96-105;
wlroots idle timer output.c:169-176) — the "schedule_done" pattern ours lacks.

## 2. wp_presentation — function table

Reference: wlroots types/wlr_presentation_time.c; smithay src/wayland/presentation/mod.rs (exists, 348 lines).

| Ours | Ours (what it does) | wlroots | smithay | Verdict |
|---|---|---|---|---|
| presentation_version (presentation.zig:63) | v2 (generated) | PRESENTATION_VERSION 2 :10 | global v2 mod.rs:108 | same |
| Presentation.init (presentation.zig:82) | register global; bind sends clock_id | wlr_presentation_create :177-201 (takes backend, unused); bind :148-163 sends CLOCK_MONOTONIC :162 | PresentationState::new(display, clk_id) mod.rs:99-116; bind sends self.clk_id :127-139 | close; clock hardcoded MONOTONIC ours+wlroots, configurable smithay |
| getFeedback (presentation.zig:130) | flat-list Feedback, 1:1 per resource | presentation_handle_feedback :91-139: per-surface addon + synced state, MERGED 1:many (feedback->resources :115-126) | request handler :151-166: pushes callback into surface cached_state pending | divergent storage (F10); wire-equivalent per resource [VERIFIED 112:9] |
| discard (presentation.zig:169) | author-called on surface death; main.zig:1573 is the ONLY call site | structural: addon destroy :58-67, synced finish_state :73-76 destroys feedback → sends discarded :227-241 | Drop for CachedState :340-347 discards; presented upgrades Weak :245-251 | ours is opt-in (F11) |
| present (presentation.zig:186) | one clock-read tv, refresh=msec*1e6, seq=per-presentation counter++, flags passthrough(0), flat broadcast | no direct equiv: compositor calls surface_sampled :210 + feedback_send_presented :201 with wlr_presentation_event from output present (from_output :243-252); seq/refresh/tv per-output | callback.presented(output, time, refresh, seq, flags) :234-285; tv/refresh/seq caller-supplied per output; refresh semantics per version :264-273 | divergent (F7, F9, F12) |
| Feedback (presentation.zig:223) | resource + presentation + surface; freed by destroy handler | wlr_presentation_feedback header 33-48 (resources list, output, commit tracking) | PresentationFeedbackCallback mod.rs:196-200 (Weak surface) | close; ours 1:1, wlroots 1:many |
| sync_output | NEVER sent (documented :13; test swallows it :344) | sent per client output before presented :27-40 (:34) | sent per client output in presented :260-262 | MISSING (F7, open from 112) |
| deinit (presentation.zig:117) | remove global, destroy all feedbacks (each sends nothing, destroy handler frees) | handle_display_destroy :167-175 destroys global (feedbacks owned by surfaces) | Drop PresentationState removes global; callbacks owned by surface state | close effect |

## 3. zwlr_screencopy — function table

Reference: wlroots types/wlr_screencopy_v1.c. smithay: no zwlr_screencopy
(only ext-image-copy-capture-v1, src/wayland/mod.rs:71) — N/A everywhere.

| Ours | Ours (what it does) | wlroots | Verdict |
|---|---|---|---|
| screencopy_version (:29) | 3 | :17 | same |
| Screencopy.init (:53) | global + callbacks (fb source, output ownership, clock) | wlr_screencopy_manager_v1_create :696-718 | close |
| deinit (:92) | remove global | handle_display_destroy :684-694 + manager destroy :649-654 | close |
| bindManager (:112) | per-client resource, no per-client state | manager_bind :658-680: per-client struct with damage list + refcount | ours lacks per-client damage list (F14) |
| managerRequest (:120) | capture_output / capture_output_region / destroy | manager_handle_* :607-648 | same |
| capture (:132) | clamp region to fb; fail via sendFailed when no fb; ARGB8888 + tight stride :198; buffer_done v3 :199 | capture_output :486-606: fails disabled output :508-511; renderer preferred_read_format :543; transform+scale on box :576-580; min_stride :585; linux_dmabuf v3 :592-595; buffer_done :596 | divergent (F15, F16, F17); version gates verified by tests (v1 vs v3) screencopy.zig:557+ |
| frameRequest (:208) | copy / copy_with_damage → BOTH call copyFrame; destroy | frame_impl :377-382: copy_with_damage sets with_damage then copy :366-375 | copy_with_damage is a no-op (F14, open from 113) |
| copyFrame (:226) | synchronous row @memcpy of current fb :289; stride recomputed (never validated) :284; damage v2 :299, flags, ready with clock callback | frame_handle_copy :347-376 validates dmabuf/shm/stride :381-421; defers to next output commit (output_commit listener :434-435, needs_frame :440, lock_attach_render :442); actual copy in frame_handle_output_commit :283-347; shm copy :193-231, dma :234-281; flags 0 :334, per-box damage :156-181, ready with commit when :337; failed on errors :341-345 | divergent: timing, damage, stride, dmabuf (F13-F17) |
| FrameState (:99) | region + used guard; already_used error | frame->buffer != NULL → ALREADY_USED :409-414 | same |
| overlay_cursor | dropped in managerRequest; documented as already composited :5-6 | honored: locks software cursors :443-446, unlock in frame_destroy :142-144 | missing effect (F18, open from 113) |
| output-enabled | never checked (owns_output checks identity only) | fails disabled outputs at capture :508-511 and copy :364-367 | missing (F19) |

## 4. Backends — function tables

### 4a. backend.zig interface vs wlr_backend

| Ours | Ours (what it does) | wlroots | Verdict |
|---|---|---|---|
| Backend.init (:49) | alloc + 3 signals (new_output, new_input, destroy) | wlr_backend_init (interface.h:56-58); wlr_backend has same 3 signals (backend.h:28-30) | same signal set |
| Backend.start (:73) | impl.start | wlr_backend_start; may signal new_input/new_output during start (backend.h:76-80 doc) | same |
| Backend.destroy (:77) | emit destroy, impl.destroy, free | wlr_backend_finish + impl->destroy (interface.h:61-64, backend.h:82-86) | same |
| emitNewOutput/emitNewInput (:85/:90) | signal emit | new_output/new_input events (backend.h:28-30) | same |
| Impl (:36) | start + destroy | backend_impl: start, destroy, get_drm_fd, test, commit (interface.h:31-37) | ours lacks multi-output test/commit + get_drm_fd (F24) |
| InputDevice (:43) | kind enum + name | wlr_input_device: type + name + vendor/product/serial (types/wlr_input_device.h) | minimal subset |

### 4b. headless.zig vs wlroots backend/headless/ (smithay: none)

| Ours | Ours (what it does) | wlroots | Verdict |
|---|---|---|---|
| HeadlessBackend.create (:41) | one output at fixed mode | wlr_headless_backend_create (backend.c:86-121) + wlr_headless_add_output (output.c:150-195); outputs added LATER by compositor | ours: fixed single output |
| start (:77) | timer + emitNewOutput | backend_start (backend.c:38-52): emit new_output per output | same announce timing |
| destroy (:92) | timer remove + out.destroy | backend_destroy (backend.c:54-75) + output_destroy (output.c:80-91) | same |
| frameCb (:102) | sendFrame + re-arm timer | signal_frame (output.c:113-117): send_frame, return 0 (wlroots timer is one-shot too; re-armed by commit :76) | ours re-arms itself; wlroots re-arms on next commit |
| testState (:110) | no-op accepts everything | output_test (output.c:34-54): rejects unsupported state mask (SUPPORTED_OUTPUT_STATE :10-14), asserts custom mode | ours validates nothing (F20) |
| commit (:112) | log only; ignores mode change for pacing | output_commit (output.c:56-78): updates frame_delay from custom_mode.refresh :66, timer_update :76, defers present event :74 | ours never re-paces on mode commit (F21); no present event (F22) |
| destroyOutput (:138) | no-op | output_destroy (output.c:91-99): wlr_output_finish + timer remove | same ownership split |

### 4c. drm.zig vs wlroots backend/drm/ + smithay

| Ours | Ours (what it does) | wlroots | smithay | Verdict |
|---|---|---|---|---|
| DrmBackend.create (:185) | alloc data + Backend.init; all device work in start | wlr_drm_backend_create backend.c:201-302: session open, caps, init_drm_resources at CREATE; start only scans connectors (backend.c:41-45) | DrmDevice::new device/mod.rs:180+ | ours defers enumeration to start; wlroots inits caps+resources at create (F23, low) |
| fromBackend (:203) | data pointer recover | get_drm_backend_from_backend backend.c:32-35 (assert is_drm) | N/A | same |
| pollFd (:209) | fd or -1 | backend_get_drm_fd backend.c:72-75 | AsFd/EventSource device/mod.rs:525-547 | same role |
| dispatch (:219) | drmHandleEvent v3; error → BackendFailed; main.zig:934-943 stops loop | handle_drm_event drm.c:2089-2103: v3 + handler2; destroys backend on failure :2094-2100 | DrmDeviceNotifier decodes PageFlip device/mod.rs:525-547 | same fatality, different mechanism [116:7 CLOSED] |
| start/startInner (:237/:245) | open + SET_MASTER + ATOMIC cap only (:263-268); connector/mode/crtc/plane; 2 dumb buffers (:337-393); mode blob (:396-403); blocking atomic modeset (:409-518); announce + first frame (:523-524) | drm_open (session); check_drm_features drm.c:51-140 (UNIVERSAL_PLANES then ATOMIC, LEGACY fallback :106-110); scan → connect_drm_connector drm.c:1627-1771 | UniversalPlanes+Atomic, Legacy fallback device/mod.rs:194-256 | ATOMIC-only, no legacy fallback [116:6 open]; fine on virtio-gpu |
| destroy (:528) | out.destroy + drmTeardown + free | backend_destroy backend.c:34-70 (connectors leaving CRTCs on, page flips, fbs, session close) | Drop restores previous KMS state device/atomic.rs:238-275 | ours does NOT restore KMS state on exit [116 open] |
| testState (:545) | rejects transform/scale; mode size must match; fb size+stride | drm_connector_prepare drm.c:838-925: unsupported mask, enable-without-mode, adaptive sync, mgpu buffer import | test_state surface/atomic.rs:694-744 | ours closed the accept-transform gap [116:5 CLOSED]; still no unsupported-mask |
| commit (:568) | flip_pending guard → CommitFailed; copyRows into non-displayed buffer; FB_ID + full-fb damage blob; PAGE_FLIP_EVENT|NONBLOCK; flip_index toggle | drm_connector_commit_state drm.c:926-1012: "a page-flip is already pending" :993-996; nonblock = !modeset && BUFFER :955-956; PAGE_FLIP_EVENT when active :1002-1006 | page_flip surface/atomic.rs:868-930: PAGE_FLIP_EVENT|NONBLOCK :899-903; fresh framebuffer per frame | guard matches; A/B swapchain closes [116:2]; no present event (F22) |
| destroyOutput (:657) | no-op (backend owns) | drm_connector_destroy_output drm.c:1244-1260 | N/A | same split |
| findConnectorMode (:674) | PREFERRED else first mode; connector's own encoder only; first CRTC bit | connector_get_current_mode drm.c:1591-1625 — CURRENT mode from CRTC, NOT preferred; encoder/CRTC matching across connectors realloc_crtcs drm.c:1399-1453 | compositor picks mode | mode policy divergent [116:4 open: no encoder fallback]; ours modesets to preferred (VM-ok) |
| findPrimaryPlane (:751) | possible_crtcs + type PRIMARY + XRGB8888 in plane formats | init_plane drm.c:160-262 (same + IN_FORMATS blob) | planes() mod.rs:152-216 + formats | format check now present [116:3 CLOSED] |
| scanPropIds/scanPlaneProps (:814/:842) | name match, all-or-nothing; FB_DAMAGE_CLIPS optional | properties.c scan_properties :40-53, :81-122 (same table) | PropMapping device/atomic.rs:92-190 | same |
| modeToOutput (:940) | vrefresh or clock/(htotal*vtotal) | calculate_refresh_rate drm.c:2005-2007 (mhz_to_nsec :2005) | Mode output.rs:80-84 | same |
| copyRows (:966) | pitch-aware row copy | (GBM path; no dumb in 0.20.2) | dumb.rs scans out pitch-padded :143+ | matches smithay dumb |
| drmTeardown (:978) | RmFB/destroy-dumb/munmap/DROP_MASTER/close, idempotent | session close backend.c:68; fbs via drm_fb | DumbFramebuffer Drop dumb.rs:35-42 | leak-free; no state restore |
| pageFlipHandler (:1014) | clear flip_pending + sendFrame | handle_page_flip drm.c:2009-2088: pop flip, move queued_fb→current, send PRESENT (commit_seq, when, seq, refresh, flags :2063-2078), then send_frame when session active :2083-2086 | Event::PageFlip → present chain | ours sends NO present event — root cause of presentation.zig synthetic tv/seq (F22) |

### 4d. libinput.zig vs wlroots backend/libinput/ + smithay src/backend/libinput/mod.rs

| Ours | Ours (what it does) | wlroots | smithay | Verdict |
|---|---|---|---|---|
| evdevToXkb (:236) | scancode + 8 | +8 in wlr_keyboard_notify_key types/wlr_keyboard.c:120 (backend passes raw) | mod.rs:116 | same offset |
| scaleToOutput (:243) | normalized 0..1 → px | compositor-side (wlr_cursor) | position traits mod.rs:292-320 | same |
| axisValueToPixels (:250) | 15° → 10 px | WLR_POINTER_AXIS_DISCRETE_STEP pointer.c:137-141 | amount_v120 mod.rs:213-222 | ours wheel-only convention |
| axisSourceFromLibinput (:261) | source enum map | axis_source_from_libinput pointer.c:69-86 | source() mod.rs:226-232 | same mapping |
| axisValueToPixelsSource (:277) / axisDiscreteForSource (:287) | per-source scale (wheel 10/15, finger/continuous 1:1); discrete 0 for finger/continuous | pointer.c:146 pass-through; discrete *= step pointer.c:137-141 | per-event accessors | [117:2 CLOSED] |
| kindForDevice (:302) | keyboard > pointer, else null (touch deliberately unannounced) | per-capability announces events.c:84-121 | compositor queries has_capability mod.rs:59-70 | policy; touch/tablet/switch absent (F27) |
| pollFd (:360) | libinput_get_fd | wl_event_loop_add_fd backend.c:119-120 (internal) | AsFd mod.rs:702-705 | same integration |
| dispatch (:370) | libinput_dispatch < 0 → BackendFailed; drain loop | handle_libinput_readable backend.c:37-60: destroys backend on failure :51-57 | process_events mod.rs:707-738 propagates :723 | ours fatal via main.zig:918-923 stop loop [117:8 CLOSED] |
| handleEvent (:379) | switch: device/key/pointer/axis; SCROLL_* ignored :416-417; touch/gesture/tablet → debug :418-420 | events.c:124-196: SCROLL_* consumed via value120 :172-183; touch 5 events :184-194; gestures/tablets/switch :195-240 | mod.rs:725-830 forwards every event incl. touch+gesture | ours drops touch/gesture/tablet (F27, F28) |
| onDeviceAdded (:403) | dupe name, registry append, ONE emitNewInput | handle_device_added events.c:64-126: ref, user_data, ONE emit PER capability | DeviceAdded callback mod.rs:730-738 | single-announce policy [117:7 open] |
| onDeviceRemoved (:429) | linear handle scan, free name | events.c:128-136 unref via user_data | DeviceRemoved mod.rs:734-736 | O(1) vs O(n), irrelevant |
| onKey (:441) | keyEvent(evdev+8) | keyboard.c:48-68 | mod.rs:114-120 | same |
| onPointerMotion (:449) | accumulate f64, round, pointerMotion | pointer.c:15-40 same accumulation | mod.rs:275-290 | same |
| onPointerMotionAbsolute (:459) | transformed(ev,1) then scale | pointer.c:49-50 identical call | mod.rs:308-320 | same |
| onPointerButton (:473) | pass BTN_* through | pointer.c:28-58 + frame | mod.rs:255-263 | same; ours has no pointer frame concept |
| onPointerAxis (:481) + sendAxis (:498) | legacy POINTER_AXIS only, source read, per-source scale, both axes | opposite choice: legacy ignored, SCROLL_* value120 (events.c:169-183) | SCROLL_WHEEL/FINGER/CONTINUOUS mod.rs:782-805 | event-choice split OK; source now handled [117:2 CLOSED]; v120 not normalized |
| libinputLogHandler (:536) | vsnprintf → log_mod at ERROR | log_libinput backend.c:63-75, ERROR priority :104-105 | N/A | [117:4 CLOSED] |
| openRestricted (:563) | plain open O_RDWR|NONBLOCK|CLOEXEC|NOCTTY | session open backend.c:18-27 | passes flags to session mod.rs:688-691 | same effect (VM) |
| start (:593) | udev_new, ctx, seat, log handler, initial drain; NO zero-device check | backend_start backend.c:90-121: same + WLR_LIBINPUT_NO_DEVICES check :112-116 | context created by caller | zero-device check absent [117:5 open] |
| destroy (:635) | free names, unref ctx then udev | backend_destroy backend.c:123-145 | N/A | balanced [117:10 OK] |

## Findings

1. [HIGH, NEEDS-wiring] No wl_output rebroadcast on state change — open from 109:5.
   Ours: wl_output.zig:78-103 sends state only at bind; a committed mode/scale/
   transform change never reaches clients. References: wlroots output_apply_state
   output.c:274-308 re-sends mode/geometry/scale per resource and schedule_done
   output.c:169-176 (idle-coalesced); smithay wl_change_current_state
   mod.rs:218-256 (xdg before wl_output, done last); KWin LogicalOutput signal
   handlers output.cpp:150-194 + doneTimer output.cpp:96-105. Why: clients (e.g.
   buffers-size policy, fractional scale) keep stale geometry; any future modeset
   is invisible. Fix shape: Output.commitState (output.zig:140) must push changed
   fields to WlOutput resources after apply, with a coalesced done.

2. [HIGH, FIXABLE-in-module] No frame_pending guard — open from 109:4.
   Ours: Output.sendFrame (output.zig:162-164) emits unconditionally; callers
   headless frameCb (headless.zig:102-108) and main.zig:1055 can fire while a
   frame is in flight; server re-render guard (main.zig:227-232) is a separate
   manual flag. wlroots: frame_pending set on commit of enabled output
   (output_apply_commit output.c:771-780), cleared in wlr_output_send_frame
   output.c:833-837, emit gated on enabled; wlr_output_schedule_frame no-ops
   while pending (output.c:848-861). Why: duplicate frame events per vblank;
   DRM commit() already defends with flip_pending (drm.zig:568+) but headless
   does not. Fix: add frame_pending to Output, set in commitState, clear+gate in
   sendFrame.

3. [MED, FIXABLE-in-module] Test/commit fused, impl->test mandatory — open from
   109:1. Ours: commitState (output.zig:140) always runs test then commit;
   Impl.@"test" (output.zig:87) required. wlroots: wlr_output_test_state
   output.c:718-745 separate probe; impl->test optional (output.c:731-734);
   unchanged fields stripped via output_compare_state output.c:535-583 before
   test/commit (output.c:719-720, 795-796). Why: every commit (incl. repeated
   identical frames) hits the backend; no probe path for the server. Fix:
   add unchanged-field compare + make test optional (empty state skips).

4. [MED, FIXABLE-in-module] Headless commit ignores mode changes — ours-only
   Ours: headless commit (headless.zig:112-124) logs only; the frame timer
   keeps the START mode's refresh_msec (frameCb headless.zig:102-108). wlroots:
   output_commit (headless/output.c:56-78) updates frame_delay from
   custom_mode.refresh (:66) and re-arms the timer (:76); also defers a present
   event (:66-72). Why: a committed mode change produces no pacing change; the headless
   output never emits present, starving presentation feedback of per-output
   events (ties to F22).

5. [MED, FIXABLE-in-module] No unsupported-state mask in backends' test hooks —
   open analog of 109:1/116. Ours: headless testState (headless.zig:110) accepts
   everything; drm testState (drm.zig:545) rejects transform/scale/mode-size only
   [116:5 CLOSED]. wlroots: headless output_test (headless/output.c:35-55) masks
   SUPPORTED_OUTPUT_STATE; drm_connector_prepare masks drm.c:838-840. Why: a
   scale/transform commit passes headless test and mutates output.width/height
   (updateSize output.zig:168-173) with no backend effect — silent divergence.

6. [MED, FIXABLE-in-module] Bind-time fidelity — open from 109:6. Ours:
   sendState hardcodes geometry 0,0,0,0 / subpixel unknown / make "wayland" /
   model "wayland-m2" / transform normal (wl_output.zig:83-92), scale 1 (:99),
   and fabricates preferred on the single mode (:94). wlroots: real phys dims +
   subpixel + transform (output.c:17-22), ceil(scale) :37-42, no preferred flag
   :24-35. smithay: location+physical+transform (mod.rs:166-176), full mode list
   with real Current/Preferred (handlers.rs:56-63). Why: client-visible contract;
   a client can draw at the wrong density. Note ours runs scale 1 / normal
   transform only, so values are honest for the current fixed config; they will
   be wrong the day scale changes.

7. [MED, NEEDS-wiring] sync_output never sent — open from 112:1. Ours:
   presentation.zig:13 documents absence; present() (presentation.zig:186) sends
   no sync_output; test swallows the event :344. wlroots: per-client output
   resources before presented (presentation_time.c:27-40); smithay: per client
   output (mod.rs:260-262). Why: clients cannot associate feedback with an
   output; latency tooling (e.g. presenting-API clients) breaks. Fix: present()
   needs an Output argument + the client's wl_output resource list (WlOutput
   resources already tracked wl_output.zig:34-38).

8. [MED, STRUCTURAL] No per-output present event anywhere — root cause of
   112:2/5/6. Ours: drm pageFlipHandler (drm.zig:1014-1024) clears flip_pending
   and sends frame only; Output has no present signal (output.zig:26-44);
   presentation.present (main.zig:1225) synthesizes tv from CLOCK_MONOTONIC at
   call time and seq from a per-presentation counter (presentation.zig:76-79).
   wlroots: handle_page_flip builds wlr_output_event_present with commit_seq,
   hw timestamp, vblank seq, refresh, flags (drm.c:2063-2078); presentation
   consumes via from_output (presentation_time.c:243-252) gated on commit_seq
   (:277-302). smithay: compositor passes output/time/refresh/seq per callback
   (mod.rs:234-285). Why: presented tv/seq are synthetic; frame-drop detection
   and latency measurement are wrong; flags can never carry VSYNC/ZERO_COPY.
   Fix: add events.present to Output, fill from the flip event, thread through
   presentation.present.

9. [MED, FIXABLE-in-module] No supersede-discard — open from 112:3. Ours:
   feedbacks accumulate until present/discard (presentation.zig:75-78); a
   surface committing new content before the old frame presents gets presented
   for content never shown. smithay: merge_into discards superseded callbacks
   (mod.rs:323-337); wlroots: synced-state move/finish destroys (presentation_time.c:73-81).
   Why: spec violation detectable by compositor benchmarks. Fix: hook surface
   commit, discard feedbacks bound to a surface when it commits again before
   present.

10. [MED, FIXABLE-in-module] Manual discard on surface death — open from 112:4.
    Ours: main.zig:1573 is the only discard call site; any other destruction
    path leaks a stale feedback that can present for a dead surface. wlroots:
    addon destroy + synced finish (presentation_time.c:58-76); smithay: Drop +
    Weak upgrade (mod.rs:245-251, 340-347). Fix: Presentation should listen to
    the surface destroy signal, or present() must upgrade a Weak surface and
    discard when dead (smithay pattern).

11. [LOW, FIXABLE-in-module] No per-output vblank seq — open from 112:5/6.
    Ours: seq is a per-presentation counter (presentation.zig:76-79, 190); tv is
    the present() call clock (presentation.zig:187). wlroots seq/tv come from the
    output present event (presentation_time.c:243-252); smithay takes them per
    callback (mod.rs:237-239). Closes automatically with F8.

12. [LOW, FIXABLE-in-module] ZERO_COPY and v1-adaptive-sync refresh handling
    absent — open from 112:7/8. Ours: flags always 0 (main.zig:1225); no
    version-dependent refresh. wlroots: clears ZERO_COPY when textured
    (presentation_time.c:296-298), refresh 0 for v1+VRR (:292-295); smithay:
    Refresh::Variable gates v2 (mod.rs:264-273). Latent until VRR/scanout flags
    exist (F8).

13. [HIGH, FIXABLE-in-module] Synchronous screencopy copy at request time —
    open from 113:1. Ours: copyFrame (screencopy.zig:226) memcpys the CURRENT
    framebuffer inside the copy request. wlroots: copy deferred to the next
    output commit (wlr_screencopy_v1.c:434-435), requests a frame via
    wlr_output_update_needs_frame :440 and lock_attach_render :442; copy in
    frame_handle_output_commit :283-347. Why: ours can sample a mid-render or
    stale frame; wlroots guarantees a presented frame. Fix: queue the frame,
    copy from the committed state.buffer at commit time.

14. [MED, FIXABLE-in-module] copy_with_damage is a no-op — open from 113:2.
    Ours: frameRequest (screencopy.zig:208-210) routes it to copyFrame; damage
    semantics ignored; per-box damage never sent (full rect always,
    screencopy.zig:299). wlroots: sets with_damage :456, waits for accumulated
    damage :302-308, sends per-box damage :156-181 via per-client accumulated
    region (screencopy_damage_accumulate :47-61 on precommit). Fix: per-client
    damage accumulation on output precommit + box loop; requires Output damage
    to be real (ours full-rect today — honest but useless).

15. [MED, FIXABLE-in-module] No stride validation — open from 113:4. Ours:
    copyFrame (screencopy.zig:226) recomputes dst_stride = width*4 (:284) and
    never checks the client buffer's real stride; a padded client shm buffer is
    silently mis-copied row-by-row. wlroots: rejects stride != frame->shm_stride
    (wlr_screencopy_v1.c:418-421); advertises min_stride :585. Fix: read the
    buffer's actual stride and either use it (loop with it) or post
    invalid_buffer.

16. [LOW, FIXABLE-in-module] Fixed ARGB8888 vs renderer preferred format; no
    linux_dmabuf path — open from 113:3. Ours: capture sends argb8888 + tight
    stride (screencopy.zig:198), rejects any other format (:254-257). wlroots:
    preferred_read_format :543, linux_dmabuf event for v3 :592-595, dma copy
    :234-281. Fine while the renderer is pixman-only.

17. [LOW, FIXABLE-in-module] Region mapping ignores scale/transform; clamps
    instead of failing — open from 113:5. Ours: capture clamps to fb
    (screencopy.zig:148-173). wlroots: transforms box by transform+scale
    :576-580, fails when box exceeds source :313-319. Correct at fixed scale
    1/normal [VERIFIED 113:5]; breaks if scale/transform become dynamic.

18. [LOW, FIXABLE-in-module] overlay_cursor has no effect — open from 113:6.
    Ours: dropped (screencopy.zig:120-123, doc :5-6). wlroots: locks software
    cursors :443-446. Currently correct because the scene composites the cursor
    into the framebuffer (main.zig drawCursor); the flag should be honored when
    cursor surfaces become separate.

19. [LOW, FIXABLE-in-module] No output-enabled check at capture/copy — open
    from 113:7. Ours: owns_output verifies identity only (screencopy.zig:43-46);
    framebuffer presence is the only liveness proxy. wlroots: fails disabled
    outputs at capture :508-511 and copy :364-367. Harmless while the server has
    exactly one always-enabled output.

20. [LOW, NEEDS-wiring] No surface enter/leave tracking — open from 109:8.
    Ours: no surface sets in the output module. smithay: enter/leave/leave_all
    mod.rs:287-345 + enter replay at bind handlers.rs:80-85. Why: clients never
    learn which output a surface is on (wl_surface.enter); wl_output-based
    clients can't place buffers. Needs the scene to report surface→output
    association.

21. [LOW, NEEDS-wiring] No xdg-output; no fractional/per-client scale — open
    from 109:9/11. smithay new_with_xdg_output mod.rs:128-139; Scale enum
    output.rs:177-212 with per-client re-send (handlers.rs:44-50, mod.rs:181-186).
    Ours: wl_output only, scale f32 fixed 1 (wl_output.zig:99).

22. [LOW, STRUCTURAL] No weak/user-data model — open from 109:10. smithay:
    WeakOutput output.rs:411-464; wlroots: void* data + addon set (wlr_output.h:270-274).
    Ours: one owning pointer + impl data (output.zig:33-34). Fine for the current
    single-owner lifetime; blocks independent listener ownership.

23. [LOW, FIXABLE-in-module] DRM: no legacy interface fallback — open from
    116:6. Ours: ATOMIC cap hard-required (drm.zig:263-268). wlroots: legacy
    fallback drm.c:106-110; smithay: LegacyDrmDevice device/mod.rs:252-256.
    Fine on virtio-gpu (ATOMIC+UNIVERSAL_PLANES implied per kernel v6.6
    drm_ioctl.c:341-352 [VERIFIED 116]).

24. [LOW, FIXABLE-in-module] DRM: no encoder fallback — open from 116:4.
    Ours: findConnectorMode (drm.zig:674) uses the connector's own encoder; if
    its possible_crtcs == 0 the connector is skipped without trying sibling
    encoders. wlroots: matches across the encoder union (realloc_crtcs
    drm.c:1399-1453). Single-encoder virtio-gpu unaffected.

25. [LOW, STRUCTURAL] DRM teardown does not restore previous KMS state — open
    from 116 (verdict). Ours: drmTeardown (drm.zig:978) releases everything but
    leaves the fb modeset. smithay: AtomicDrmDevice Drop restores captured
    properties with ALLOW_MODESET (device/atomic.rs:238-275). Moot on a VM, real
    on a session.

26. [LOW, NEEDS-wiring] Backend.Impl lacks multi-output test/commit and
    get_drm_fd — open analog of 114. Ours: Backend.Impl (backend.zig:36) = start
    + destroy. wlroots: backend_impl (interface.h:31-37) adds get_drm_fd, test,
    commit over wlr_backend_output_state arrays; drm implements them
    (backend.c:72-75, 78-93). Why: no atomic multi-output config (test/apply
    across outputs) at the backend level; pollFd-per-backend replaces get_drm_fd.
    Structural only when multi-output arrives.

27. [LOW, NEEDS-wiring] Touch/gesture/tablet/switch events absent — open from
    117:3. Ours: kindForDevice (libinput.zig:302) never announces touch; dispatch
    (libinput.zig:379-401) drops TOUCH_* and gesture events to debug log.
    wlroots: touch events.c:184-194, gestures :195-240, tablet_tool.c,
    tablet_pad.c, switch.c; smithay forwards all (mod.rs:725-830). The seat has
    no touch protocol support, so wiring is compositor-side. Low until a
    touchscreen target.

28. [LOW, FIXABLE-in-module] Wheel v120 normalization absent; legacy
    POINTER_AXIS choice — open from 117 (policy). Ours: legacy event consumed
    (libinput.zig:481-496), SCROLL_* ignored (:416-417); wlroots consumes
    SCROLL_* with value120 (events.c:169-183), smithay same (mod.rs:782-805).
    Both legal per libinput.h:811-826 [VERIFIED 117]; hi-res wheel data is
    carried in discrete, just not v120-normalized.

29. [LOW, FIXABLE-in-module] libinput: no zero-device check at start — open
    from 117:5. Ours: start (libinput.zig:593) succeeds with an empty registry.
    wlroots: fails unless WLR_LIBINPUT_NO_DEVICES=1 (backend.c:112-116). A
    broken udev/seat config looks healthy.

30. [LOW, FIXABLE-in-module] libinput: no LED sync — open from 117:6. wlroots:
    libinput_device_led_update (keyboard.c:31-35); smithay: LedState mapping
    (mod.rs:674-688). Ours: no LED path. Cosmetic on the VM path.

## Re-audit of previous open items

- sync_output (112 gap 1): STILL OPEN. presentation.zig:13, no emit path, test
  swallows at :344. Blocked on F7 (needs wl_output resource list + Output arg).
- copy_with_damage (113 gap 2): STILL OPEN. screencopy.zig:208-210 routes to
  copyFrame; no damage accumulation (F14).
- axis source handling (117 gap 2): CLOSED. libinput.zig:481-496 reads
  get_axis_source, sendAxis (:498) scales per source via
  axisValueToPixelsSource (:277)/axisDiscreteForSource (:287); seat.pointerAxis
  (seat.zig:276-316) sends axis_source + axis_discrete + axis for v5 clients and
  axis_stop on zero. Matches wlroots' per-source semantics (pointer.c:146) and
  the wlr_seat_pointer_send_axis shape (seat.zig:268-274 doc).
- Also closed since the last notes: 116:1 (byte order — pixman.zig:261-266
  stores B,G,R,A matching XRGB8888), 116:2 (single-buffer tear — A/B swapchain
  drm.zig:96, commit :568+ alternates FB_ID), 116:3 (plane format check —
  drm.zig:751-812), 116:5 (testState accepts transform/scale — drm.zig:545-547
  now rejects), 116:7 (drmHandleEvent failure fatal — main.zig:934-943 stops
  loop), 117:1 (name leak on append — libinput.zig:403-427 frees in catch),
  117:4 (libinput log handler — libinput.zig:536 + set at ERROR :593+),
  117:8 (dispatch failure policy — main.zig:918-923 stops loop), 117:9 (dead
  FFI decls — path_create_context/path_add_device/device_get_seat gone from the
  extern block; get_axis_source now used).
- Still open from 116: encoder fallback (F24), atomic-only (F23), KMS-state
  restore (F25). Still open from 117: touch/gesture (F27), zero-device check
  (F29), LED sync (F30), single-announce policy (117:7 — by design), SCROLL_*
  vs legacy choice (F28).

## Fixability summary

- FIXABLE-in-module (19): F2, F3, F4, F5, F6, F9, F10, F11, F12, F13, F14, F15,
  F16, F17, F18, F19, F23, F24, F28, F29, F30.
- NEEDS-wiring (5): F1, F7, F20, F21, F26, F27 (needs Output/wl_output data or
  seat/scene cooperation).
- STRUCTURAL (4): F8 (present signal + presentation association — spans output,
  drm, presentation), F22 (weak refs), F25 (KMS restore — backend-lifecycle
  scope), plus smithay-absent features (xdg-output is F21).

## OK areas (parity confirmed)

- wl_output wire: version 4, event order (geometry→mode→scale→name→description
  →done) identical to wlroots (output.c:100-106) and smithay (handlers.rs:44-84)
  at bind; KWin's name-first order is the outlier (output.cpp:139-149) and is a
  legal order per the protocol.
- Output atomic-state core: committed bitmask, test-before-commit, apply-after-
  commit, transform-size update (output.zig:140-160) mirror wlroots
  output_apply_state/output_apply_commit (output.c:274-308, 774-776).
- DRM: property set, 16.16 SRC, blocking modeset + ALLOW_MODESET, non-blocking
  flip + PAGE_FLIP_EVENT, flip-pending guard, FB_DAMAGE_CLIPS blob layout
  (drm.zig:896-918, 568-655 vs atomic.c:452-477, 494-568, 600-606, drm.c:955-1006);
  leak-free reverse-order teardown (drm.zig:978-1012); v3 event context
  (drm.zig:219-235 vs drm.c:2089-2097).
- Libinput FFI: 30/30 externs match libinput 1.31.3 [VERIFIED 117]; lifecycle
  (udev create/assign/drain, errdefer cleanup, ctx-before-udev teardown)
  mirrors wlroots backend_start (backend.c:90-121); keycode +8 and
  absolute-motion normalization match wlroots exactly.
- Screencopy: capture lifecycle, already_used/invalid_buffer error codes,
  v1/v2/v3 opcode gating (buffer_done v3, damage v2) — verified by tests
  (screencopy.zig:557-651); flags/damage/ready ordering matches wlroots
  (:334-337) except the timestamp source.
- Presentation: global/bind/clock_id, 1:1 feedback lifecycle with destroy-
  handler cleanup, presented/discarded destructor events all wire-equivalent
  [VERIFIED 112].
- Backend.zig signal set (new_output/new_input/destroy) matches wlr_backend
  (backend.h:28-30); headless announce-at-start timing matches wlroots
  (headless/backend.c:38-52).
