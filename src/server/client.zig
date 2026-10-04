//! M1+ test client: drives the compositor test server end to end.
//!
//! Pure protocol client (generated `client.*` bindings + libwayland-client,
//! no compositor library import):
//!   1. connect via WAYLAND_DISPLAY, roundtrip
//!   2. bind wl_compositor (v7), wl_shm (server v2, bound at the
//!      advertised version), xdg_wm_base (v7), wl_seat, wl_output,
//!      zwlr_screencopy_manager_v1
//!   3. xdg toplevel "m1-test"; empty commit; wait for configure, ack it
//!   4. shm buffer (memfd, output-sized x4, red gradient), attach, damage, commit
//!   5. one frame callback; on done -> CLIENT-OK, exit 0
//!   6. M3 (WAYLAND_SYNTH_INPUT=1 on the server): waits for the pointer
//!      enter + keyboard focus + key press, then captures the output via
//!      zwlr_screencopy_v1 and verifies the composited pixels: gradient
//!      probes plus the cursor overlay at the position the wire pointer
//!      coordinates, the output's mode and that output's camera put it.
//!   7. M4: waits for the server's synth wheel zoom and re-verifies the
//!      gradient under the new camera.
//!   8. Buffer-transform acceptance (opt-in, WAYLAND_CLIENT_TRANSFORMS=1):
//!      all eight wl_output transforms, wl_surface.set_buffer_scale and a
//!      wp_viewport crop/destination, each checked against an oracle the
//!      client computes from its OWN asymmetric buffer. See "Buffer
//!      transform acceptance" below.
//!   9. DMA-BUF qualification (opt-in, WAYLAND_CLIENT_DMABUF=1): see
//!      "DMA-BUF qualification" at the bottom of this file.
//!  10. Connector + input-device qualification (opt-in,
//!      WAYLAND_CLIENT_HOTPLUG=1): waits for the harness to unplug one
//!      DRM connector and the guest's input devices, and proves on the
//!      wire and in the pixels that one output global went, one survivor
//!      did not move, a new one came back, and a real key and a real
//!      pointer event followed the device that produced them.
//!
//! On failure prints CLIENT-ERROR/CLIENT-TIMEOUT and exits nonzero.
//! All progress lines go to stderr; the CLIENT-* verdicts to stdout.

const std = @import("std");
const protocol = @import("protocol");

const client = protocol.client;
const wl = client.wl;
const xdg = client.xdg;

// The translated libgbm surface. Only the DMA-BUF qualification needs
// it (a client allocates a real DMA-BUF with GBM); build.zig wires the
// same "gbm_c" module the compositor library uses into this executable.
const gbm_c = @import("gbm_c");

const bytes_per_pixel: usize = 4;
/// Fallback surface size, used only if the wl_output mode event has not
/// been dispatched before the shm buffer setup (defensive; the mode event
/// normally arrives during the initial configure wait).
const fallback_width: i32 = 1280;
const fallback_height: i32 = 720;
const timeout_ms: i64 = 5000;

/// Set from main so the step/verdict log helpers can read the clock
/// (0.16 has no std.time.milliTimestamp; the Io provides it).
// SAFETY: assigned from the runtime (init.io in main) before first use.
var client_io: std.Io = undefined;

const ClientState = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    toplevel: ?*xdg.Toplevel = null,
    shm_pool: ?*wl.ShmPool = null,
    buffer: ?*wl.Buffer = null,

    got_configure: bool = false,
    configure_serial: ?u32 = null,
    frame_done: bool = false,

    // M3: seat + output + screencopy coverage.
    seat: ?*wl.Seat = null,
    output: ?*wl.Output = null,
    screencopy_mgr: ?*client.zwlr.ScreencopyManagerV1 = null,
    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,
    seat_caps: u32 = 0,
    keymap_ok: bool = false,
    keyboard_entered: bool = false,
    got_pointer_enter: bool = false,
    got_pointer_motion: bool = false,
    got_button: bool = false,
    got_key_press: bool = false,
    got_key_release: bool = false,
    output_mode: ?OutputMode = null,
    /// Surface size resolved from the advertised output mode (fallback
    /// constants if the mode event had not arrived at setup time).
    surface_width: i32 = 0,
    surface_height: i32 = 0,
    /// WAYLAND_CAMERA verbatim, parsed per OUTPUT into a ViewCamera: the
    /// world→screen mapping every camera-aware expectation below is
    /// computed from. Null is the server's default (each view centres its
    /// own origin, so world→screen is the identity).
    camera_env: ?[]const u8 = null,
    /// The pointer's position in THIS surface's own coordinates, in the
    /// f64 the wire carried (wl_pointer.enter/motion are 24.8 fixed).
    /// The cursor placement and every input/display cross-check are
    /// derived from it, never from an assumed pointer location.
    pointer_surface_x: f64 = 0,
    pointer_surface_y: f64 = 0,
    /// Camera phase when the last pointer coordinates were received.
    /// A stationary pointer retains its pre-zoom datum until a new event.
    synth_zoom_settled: bool = false,
    pointer_after_zoom: bool = false,
    pointer_focused: bool = false,
    /// The serial of the last wl_pointer.enter: the one the server expects
    /// a serial-bearing request to echo, and the proof that the motion
    /// below arrived on the surface this client entered.
    pointer_enter_serial: u32 = 0,
    /// True once wl_surface.enter named an output for this surface.
    surface_entered: bool = false,
    /// WAYLAND_CLIENT_TRANSFORMS=1: run the buffer-transform acceptance
    /// (all eight transforms, buffer scale, wp_viewport crop/destination).
    /// Off by default so the plain shm E2E stays one flow; on, every case
    /// is checked in the pixels or the run fails.
    transforms_qual: bool = false,
    /// wp_viewporter, bound only in the transform acceptance: it is a
    /// separate global from wl_compositor and only that phase needs it.
    viewporter: ?*client.wp.Viewporter = null,
    /// The transform phase's own buffer (asymmetric fixture), separate
    /// from `buffer` so the M1 gradient survives the round trip.
    fixture_pool: ?*wl.ShmPool = null,
    fixture_buffer: ?*wl.Buffer = null,
    fixture_fd: std.posix.fd_t = -1,
    fixture_pixels: ?[]align(std.heap.page_size_min) u8 = null,
    /// zwp_linux_dmabuf_v1 when the compositor advertises it (only the
    /// DRM backend with a live GBM device does). Null is a failure in the
    /// qualification mode, never a silent fallback to shm.
    dmabuf: ?*client.zwp.LinuxDmabufV1 = null,
    /// The version the global was bound at: below v4 the advertised
    /// (format, modifier) pairs arrive as legacy events, from v4 on they
    /// come from a feedback object.
    dmabuf_version: u32 = 0,
    /// wp_presentation, the signal that separates "the commit was
    /// accepted" from "the frame reached the output".
    presentation: ?*client.wp.Presentation = null,
    /// wp_presentation_feedback outcomes so far.
    presented: u32 = 0,
    discarded: u32 = 0,
    /// wl_buffer.release events: the compositor handing a buffer back.
    released: u32 = 0,
    /// presented/release counters snapshotted before a commit, so a wait
    /// can tell "this commit's event arrived" from "an earlier one did".
    presented_mark: u32 = 0,
    release_mark: u32 = 0,
    /// The GBM device the phase allocated on, so the screencopy
    /// destination can be allocated on the same one.
    gbm: ?*gbm_c.gbm_device = null,
    /// WAYLAND_DRM_DEVICE: the explicit DRM node the client allocates
    /// on, the same override the server honours. Null means discover it.
    drm_device: ?[]const u8 = null,
    /// WAYLAND_CLIENT_DMABUF: run the real DMA-BUF qualification after
    /// the shm flow. Off by default, so the shm E2E stays runnable on a
    /// machine with no DRM device; on, every missing piece of hardware
    /// or protocol support is a reported failure, never a silent skip.
    dmabuf_qual: bool = false,
    /// WAYLAND_CLIENT_HOTPLUG: run the connector off/on and input-device
    /// removal qualification. Off by default. The transitions belong to
    /// scripts/vm-drm-e2e.sh (a guest-kernel connector force plus a real
    /// uevent) and to the host's QMP socket (a real PCI hot-unplug); this
    /// client only observes the wire and the pixels.
    hotplug_qual: bool = false,
    /// Every wl_output global bound, in announcement order. The connector
    /// scenario is only meaningful with more than one of them.
    outputs: [max_bound_outputs]BoundOutput = @splat(.{}),
    outputs_len: usize = 0,
    /// wl_registry.global_remove events for a bound wl_output, and the
    /// wl_registry.global events seen. Counters, not flags: a second
    /// removal has to be visible rather than absorbed by the first.
    output_removals: u32 = 0,
    output_globals: u32 = 0,
    /// Marks the waits above compare against, so "an event arrived since"
    /// cannot be satisfied by an event from an earlier phase.
    removals_mark: u32 = 0,
    additions_mark: u32 = 0,
    /// The output that survived the removal, or max_bound_outputs until
    /// one is observed to survive.
    survivor: usize = max_bound_outputs,
    /// Pixel fingerprint of the surviving output, taken before the removal.
    survivor_fp: [fingerprint_points][4]u8 = @splat(@splat(0)),
    survivor_fp_len: usize = 0,
    /// The output whose mode event the re-add wait is watching.
    waiting: ?*BoundOutput = null,
    /// Key presses per watched keycode, plus the index and mark the wait
    /// reads. A watched keycode can never be the synth key 30.
    key_counts: [qual_keys.len]u32 = @splat(0),
    watch_key: usize = 0,
    watch_key_mark: u32 = 0,
    /// wl_pointer.motion events, and the last surface-local point.
    motions: u32 = 0,
    motion_mark: u32 = 0,
    last_motion_x: i32 = 0,
    last_motion_y: i32 = 0,
    /// wl_seat.capabilities events seen, plus the mask and mark the
    /// withdrawal and restoration waits read. A capability that loses its
    /// last device is the client-visible proof that a DEVICE went away,
    /// not just that the protocol changed.
    caps_seen: u32 = 0,
    caps_mark: u32 = 0,
    watch_cap_mask: u32 = 0,
    /// The advertised (format, modifier) pairs, in the order the server
    /// sent them.
    formats: [max_format_pairs]FormatPair = undefined,
    formats_len: usize = 0,
    /// The format table a v4+ feedback object handed over.
    format_table: ?FormatTable = null,
    /// Set when that feedback object's `done` arrived.
    feedback_done: bool = false,
    /// The zwp_linux_buffer_params_v1 whose created/failed event the next
    /// wait watches. One params object is ever in flight (the flow
    /// creates them one at a time), so this needs no table.
    params: ?*client.zwp.LinuxBufferParamsV1 = null,
    created: ?*wl.Buffer = null,
    create_failed: bool = false,
    /// The screencopy frame being copied into a DMA-BUF destination.
    dmabuf_cap: ?DmabufCapture = null,
    /// Screencopy capture state (filled when the frame advertises its
    /// buffer and completed on ready).
    capture: ?CaptureState = null,
};

/// Why the capture wait ended with failed=true (reported by the CLIENT-
/// ERROR verdict so a local failure is not misreported as a timeout).
const CaptureFailure = enum {
    /// The server sent the failed event.
    server,
    /// Creating the advertised shm buffer failed.
    buffer_create,
    /// Flushing the copy request failed.
    flush,
};

const CaptureState = struct {
    frame: *client.zwlr.ScreencopyFrameV1,
    fd: std.posix.fd_t,
    pixels: []align(std.heap.page_size_min) u8,
    pool: *wl.ShmPool,
    buffer: *wl.Buffer,
    stride: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    sent_copy: bool = false,
    ready: bool = false,
    failed: bool = false,
    failure: CaptureFailure = .server,
};

pub fn main(init: std.process.Init) !void {
    client_io = init.io;
    const display_name = init.environ_map.get("WAYLAND_DISPLAY");
    if (display_name == null or display_name.?.len == 0) {
        verdict("CLIENT-ERROR", "WAYLAND_DISPLAY is not set", .{});
        return error.WaylandDisplayUnset;
    }
    step("connecting to {s}", .{display_name.?});

    // connect(null) uses WAYLAND_DISPLAY from the environment (validated above).
    const display = wl.Display.connect(null) catch |err| {
        verdict("CLIENT-ERROR", "wl_display_connect failed: {s}", .{@errorName(err)});
        return err;
    };
    defer wl.Display.disconnect(display);

    if (wl.Display.roundtrip(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "initial roundtrip failed", .{});
        return error.RoundtripFailed;
    }

    const registry = try display.getRegistry();
    var state: ClientState = .{ .display = display, .registry = registry };
    registry.setListener(*ClientState, onRegistryEvent, &state);
    // The camera the server was started with, kept verbatim and parsed
    // per output in ViewCamera.forOutput: one WAYLAND_CAMERA maps onto
    // every output with THAT output's own size.
    state.camera_env = init.environ_map.get("WAYLAND_CAMERA");

    // The DMA-BUF node override the server itself honours, and the
    // opt-in switches for the qualification phases. All read here so the
    // phases below need nothing but the state.
    state.drm_device = init.environ_map.get("WAYLAND_DRM_DEVICE");
    state.dmabuf_qual = envFlag(init.environ_map, "WAYLAND_CLIENT_DMABUF");
    state.hotplug_qual = envFlag(init.environ_map, "WAYLAND_CLIENT_HOTPLUG");
    state.transforms_qual = envFlag(init.environ_map, "WAYLAND_CLIENT_TRANSFORMS");

    // Collect globals: another roundtrip processes the registry burst.
    if (wl.Display.roundtrip(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "registry roundtrip failed", .{});
        return error.RoundtripFailed;
    }
    if (state.compositor == null or state.shm == null or state.wm_base == null) {
        verdict("CLIENT-ERROR", "missing globals (compositor={} shm={} xdg={})", .{
            state.compositor != null, state.shm != null, state.wm_base != null,
        });
        return error.MissingGlobals;
    }
    if (state.seat == null or state.output == null or state.screencopy_mgr == null) {
        verdict("CLIENT-ERROR", "missing M3 globals (seat={} output={} screencopy={})", .{
            state.seat != null, state.output != null, state.screencopy_mgr != null,
        });
        return error.MissingGlobals;
    }
    step("bound wl_compositor, wl_shm, xdg_wm_base, wl_seat, wl_output, screencopy", .{});

    // --- M3 seat + output ------------------------------------------------
    const seat = state.seat.?;
    seat.setListener(*ClientState, onSeatEvent, &state);
    state.keyboard = seat.getKeyboard() catch null;
    if (state.keyboard) |kbd| kbd.setListener(*ClientState, onKeyboardEvent, &state);
    state.pointer = seat.getPointer() catch null;
    if (state.pointer) |ptr| ptr.setListener(*ClientState, onPointerEvent, &state);
    step("seat+output listeners attached (caps so far: 0x{x})", .{state.seat_caps});

    // --- xdg toplevel -----------------------------------------------------
    const surface = try state.compositor.?.createSurface();
    state.surface = surface;
    // wl_surface.enter is what says the surface this client draws is on
    // an output at all; the pointer datum below is only meaningful
    // against the surface that was entered.
    surface.setListener(*ClientState, onSurfaceEvent, &state);
    const xdg_surface = try state.wm_base.?.getXdgSurface(surface);
    state.xdg_surface = xdg_surface;
    xdg_surface.setListener(*ClientState, onXdgSurfaceEvent, &state);
    const toplevel = try xdg_surface.getToplevel();
    state.toplevel = toplevel;
    toplevel.setListener(*ClientState, onToplevelEvent, &state);
    toplevel.setTitle("m1-test");
    toplevel.setAppId("m1-test");
    step("created xdg_toplevel, title=m1-test", .{});

    // Empty commit: the server answers with the initial configure. Flush so
    // the request leaves the client's outgoing buffer before we poll.
    surface.commit();
    if (wl.Display.flush(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "flush after empty commit failed", .{});
        return error.FlushFailed;
    }

    if (!try waitForEvent(hasConfigure, &state, timeout_ms)) {
        verdict("CLIENT-TIMEOUT", "no xdg configure within {d}ms", .{timeout_ms});
        return error.ClientTimeout;
    }
    step("received configure serial={d}", .{state.configure_serial.?});

    // --- shm buffer -------------------------------------------------------
    // The configure is acked from the event handler (every configure,
    // including the second size configure at first map, is acked there).
    // Size the surface from the advertised output mode.
    resolveSurfaceSize(&state);
    const pool_size: usize = @as(usize, @intCast(state.surface_width)) *
        @as(usize, @intCast(state.surface_height)) * bytes_per_pixel;
    const fd = try std.posix.memfd_create("m1-test-buffer", std.os.linux.MFD.CLOEXEC);
    defer _ = std.os.linux.close(fd);
    {
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) {
            verdict("CLIENT-ERROR", "ftruncate failed", .{});
            return error.FtruncateFailed;
        }
    }
    const pixels = try std.posix.mmap(
        null,
        pool_size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(pixels);
    fillPattern(pixels, state.surface_width, state.surface_height);

    state.shm_pool = try state.shm.?.createPool(fd, @intCast(pool_size));
    state.buffer = try state.shm_pool.?.createBuffer(
        0,
        state.surface_width,
        state.surface_height,
        state.surface_width * 4,
        .argb8888,
    );
    step("created shm buffer {d}x{d}", .{ state.surface_width, state.surface_height });

    // --- map: attach + damage + frame + commit ----------------------------
    const frame_cb = try surface.frame();
    frame_cb.setListener(*ClientState, onFrameDone, &state);
    surface.attach(state.buffer, 0, 0);
    surface.damage(0, 0, state.surface_width, state.surface_height);
    surface.commit();
    if (wl.Display.flush(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "flush after buffer commit failed", .{});
        return error.FlushFailed;
    }
    step("committed buffer, waiting for frame callback", .{});

    if (!try waitForEvent(hasFrame, &state, timeout_ms)) {
        verdict("CLIENT-TIMEOUT", "no frame callback within {d}ms", .{timeout_ms});
        return error.ClientTimeout;
    }
    step("frame callback done", .{});

    // Hold the mapped surface briefly so the compositor renders it at least
    // once (the server logs render frames with the surface count).
    std.Io.sleep(client_io, .fromMilliseconds(700), .awake) catch |err| {
        verdict("CLIENT-ERROR", "hold sleep failed: {s}", .{@errorName(err)});
        return err;
    };

    // --- M3: synth input + screencopy verification ------------------------
    if (!try waitForEvent(hasPointerEnter, &state, timeout_ms)) {
        verdict("CLIENT-TIMEOUT", "no pointer enter (server synth input?)", .{});
        return error.ClientTimeout;
    }
    if (!try waitForEvent(hasKeyPress, &state, timeout_ms)) {
        verdict("CLIENT-TIMEOUT", "no key press (click-to-focus?)", .{});
        return error.ClientTimeout;
    }
    if (!state.keyboard_entered or !state.got_button or !state.got_pointer_motion) {
        verdict("CLIENT-ERROR", "missing input events (kbd_enter={} button={} motion={})", .{
            state.keyboard_entered, state.got_button, state.got_pointer_motion,
        });
        return error.InputEventsMissing;
    }
    if (!state.keymap_ok) {
        verdict("CLIENT-ERROR", "keymap event missing or malformed", .{});
        return error.KeymapBad;
    }
    const mode = state.output_mode orelse {
        verdict("CLIENT-ERROR", "no wl_output mode received", .{});
        return error.OutputModeMissing;
    };
    if (mode.width != state.surface_width or mode.height != state.surface_height) {
        verdict("CLIENT-ERROR", "unexpected output mode {d}x{d} (surface sized {d}x{d})", .{
            mode.width, mode.height, state.surface_width, state.surface_height,
        });
        return error.OutputModeBad;
    }
    if (!try waitForEvent(hasSurfaceEntered, &state, timeout_ms)) {
        verdict("CLIENT-ERROR", "the surface was never entered on an output: its pixels cannot be located in a capture", .{});
        return error.SurfaceNotEntered;
    }
    step("input verified: pointer enter+motion, button, key 30, keymap, output {d}x{d}, surface entered", .{
        mode.width, mode.height,
    });

    // Screencopy: capture the whole output, verify composited pixels.
    const frame = try setupCapture(&state);
    frame.setListener(*ClientState, onCaptureFrameEvent, &state);
    step("screencopy frame requested", .{});
    if (wl.Display.flush(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "flush after capture failed", .{});
        return error.FlushFailed;
    }
    if (!try waitForEvent(hasCaptureDone, &state, timeout_ms)) {
        verdict("CLIENT-TIMEOUT", "no screencopy ready/failed within {d}ms", .{timeout_ms});
        return error.ClientTimeout;
    }
    const cap = &state.capture.?;
    if (cap.failed or !cap.ready) {
        // The failure flag makes the wait end with a specific CLIENT-ERROR
        // instead of timing out (a failed copy sends no ready event).
        switch (cap.failure) {
            .server => verdict("CLIENT-ERROR", "screencopy failed", .{}),
            .buffer_create => verdict("CLIENT-ERROR", "capture buffer creation failed", .{}),
            .flush => verdict("CLIENT-ERROR", "flush after capture copy failed", .{}),
        }
        return error.CaptureFailed;
    }
    try verifyCapturePixels(cap, &state, ViewCamera.forOutput(state.camera_env, mode));
    destroyCapture(&state);

    // M4 Phase B: the server's synth wheel zoom (2 -> 2.5 under the E2E
    // camera) lands at frame 100; wait for it with a bounded
    // capture-retry loop.
    try verifyZoomLanding(&state);

    // Buffer-transform acceptance (opt-in). It runs right after the zoom
    // has landed, so all thirteen surface states are drawn in one known
    // camera, and it restores the plain shm surface before the phases
    // below.
    if (state.transforms_qual) try runTransformQualification(&state);

    // DMA-BUF qualification (opt-in). It runs after the transform phase,
    // which leaves the plain shm surface committed again: the server's
    // synth camera is stable, so the pattern expectations below use one
    // known camera for every capture of the phase.
    if (state.dmabuf_qual) try runDmabufQualification(&state);

    // Connector and input-device qualification (opt-in). Last, like the
    // DMA-BUF phase: it drives real hardware transitions, so it must not
    // run on a compositor that already failed a cheaper check.
    if (state.hotplug_qual) try runHotplugQualification(&state);

    // Drain remaining events so the server sees a clean client teardown.
    if (wl.Display.roundtrip(display) != .SUCCESS) {
        verdict("CLIENT-ERROR", "final roundtrip failed", .{});
        return error.RoundtripFailed;
    }
    verdict("CLIENT-OK", "roundtrip complete", .{});
}

// ---------------------------------------------------------------------------
// Event listeners
// ---------------------------------------------------------------------------

fn onRegistryEvent(registry: *wl.Registry, event: wl.Registry.Event, state: *ClientState) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            if (std.mem.eql(u8, name, "wl_compositor") and state.compositor == null) {
                state.compositor = registry.bind(g.name, wl.Compositor, 7) catch null;
            } else if (std.mem.eql(u8, name, "wl_shm") and state.shm == null) {
                state.shm = registry.bind(g.name, wl.Shm, g.version) catch null;
            } else if (std.mem.eql(u8, name, "xdg_wm_base") and state.wm_base == null) {
                state.wm_base = registry.bind(g.name, xdg.WmBase, 7) catch null;
            } else if (std.mem.eql(u8, name, "wl_seat") and state.seat == null) {
                state.seat = registry.bind(g.name, wl.Seat, 7) catch null;
            } else if (std.mem.eql(u8, name, "wl_output")) {
                // Every output is bound: the hotplug phase needs a
                // survivor to compare the removed one against.
                bindWlOutput(state, g.name, g.version);
            } else if (std.mem.eql(u8, name, "zwlr_screencopy_manager_v1") and state.screencopy_mgr == null) {
                state.screencopy_mgr = registry.bind(g.name, client.zwlr.ScreencopyManagerV1, 3) catch null;
            } else if (std.mem.eql(u8, name, "zwp_linux_dmabuf_v1") and state.dmabuf == null) {
                // Bound at the advertised version, capped by what the
                // generated bindings implement. The listener goes on
                // immediately: a v3 bind answers with the format/modifier
                // events, and those arrive after this handler returns.
                const version = @min(g.version, client.zwp.LinuxDmabufV1.generated_version);
                if (registry.bind(g.name, client.zwp.LinuxDmabufV1, version)) |linux| {
                    state.dmabuf = linux;
                    state.dmabuf_version = version;
                    linux.setListener(*ClientState, onDmabufEvent, state);
                    step("bound zwp_linux_dmabuf_v1 v{d}", .{version});
                } else |err| {
                    step("zwp_linux_dmabuf_v1 bind failed: {s}", .{@errorName(err)});
                }
            } else if (std.mem.eql(u8, name, "wp_presentation") and state.presentation == null) {
                const version = @min(g.version, client.wp.Presentation.generated_version);
                if (registry.bind(g.name, client.wp.Presentation, version)) |pres| {
                    state.presentation = pres;
                    pres.setListener(*ClientState, onPresentationEvent, state);
                    step("bound wp_presentation v{d}", .{version});
                } else |err| {
                    step("wp_presentation bind failed: {s}", .{@errorName(err)});
                }
            } else if (std.mem.eql(u8, name, "wp_viewporter") and
                state.viewporter == null and state.transforms_qual)
            {
                // Bound only for the transform acceptance: it is a
                // separate global from wl_compositor, and no other phase
                // in this client crops or scales a surface.
                const version = @min(g.version, client.wp.Viewporter.generated_version);
                if (registry.bind(g.name, client.wp.Viewporter, version)) |vp| {
                    state.viewporter = vp;
                    step("bound wp_viewporter v{d}", .{version});
                } else |err| {
                    step("wp_viewporter bind failed: {s}", .{@errorName(err)});
                }
            }
        },
        .global_remove => |removed| {
            if (removed.name == 0) return;
            onOutputGlobalRemoved(state, removed.name);
        },
    }
}

fn onSeatEvent(seat: *wl.Seat, event: wl.Seat.Event, state: *ClientState) void {
    _ = seat;
    switch (event) {
        .capabilities => |c| {
            state.seat_caps = @as(u32, @bitCast(c.capabilities));
            state.caps_seen += 1;
            step("seat capabilities=0x{x} (event {d})", .{ state.seat_caps, state.caps_seen });
        },
        .name => |n| step("seat name={s}", .{std.mem.span(n.name)}),
    }
}

fn onKeyboardEvent(keyboard: *wl.Keyboard, event: wl.Keyboard.Event, state: *ClientState) void {
    _ = keyboard;
    switch (event) {
        .keymap => |k| {
            // Verify the payload is an XKB keymap: read the fd (the
            // server rewound it to 0) and check the header.
            var buf: [32]u8 = undefined;
            const n = std.os.linux.read(k.fd, &buf, buf.len);
            // A real read returns 1..32 bytes; a negated errno is huge.
            if (n <= buf.len and n > 0) {
                const head = buf[0..n];
                state.keymap_ok = std.mem.startsWith(u8, head, "xkb_keymap");
            }
            _ = std.os.linux.close(k.fd);
            step("keymap event format={d} size={d} ok={}", .{ @intFromEnum(k.format), k.size, state.keymap_ok });
        },
        .enter => |e| {
            state.keyboard_entered = true;
            step("keyboard enter serial={d} keys={d}", .{ e.serial, e.keys.size });
        },
        .leave => {},
        .key => |k| {
            // The wire keycode is the evdev scancode (F1, note 132): the
            // server sends keycode-8, so 'a' (xkb 38) arrives as 30.
            if (k.key == 30) {
                if (@intFromEnum(k.state) == 1) state.got_key_press = true else state.got_key_release = true;
                step("key 30 state={d} time={d}", .{ @intFromEnum(k.state), k.time });
            }
            // Counted per watched keycode so the input phase can tell
            // "a key arrived after the unplug" from "one arrived before".
            if (qualKeyIndex(k.key)) |index| state.key_counts[index] += 1;
        },
        .modifiers => |m| step("modifiers dep=0x{x} lat=0x{x} lock=0x{x}", .{
            m.mods_depressed, m.mods_latched, m.mods_locked,
        }),
        .repeat_info => |r| step("repeat_info rate={d} delay={d}", .{ r.rate, r.delay }),
    }
}

fn onPointerEvent(pointer: *wl.Pointer, event: wl.Pointer.Event, state: *ClientState) void {
    _ = pointer;
    switch (event) {
        .enter => |e| {
            state.got_pointer_enter = true;
            state.pointer_enter_serial = e.serial;
            state.pointer_surface_x = e.surface_x.toDouble();
            state.pointer_surface_y = e.surface_y.toDouble();
            state.pointer_focused = e.surface == state.surface;
            state.pointer_after_zoom = state.synth_zoom_settled;
            step("pointer enter serial={d} at {d},{d} ({d}.{d} fixed)", .{
                e.serial,
                e.surface_x.toInt(),
                e.surface_y.toInt(),
                state.pointer_surface_x,
                state.pointer_surface_y,
            });
        },
        .leave => state.pointer_focused = false,
        .motion => |m| {
            state.got_pointer_motion = true;
            state.motions += 1;
            state.last_motion_x = m.surface_x.toInt();
            state.last_motion_y = m.surface_y.toInt();
            state.pointer_surface_x = m.surface_x.toDouble();
            state.pointer_surface_y = m.surface_y.toDouble();
            state.pointer_after_zoom = state.synth_zoom_settled;
            step("pointer motion to {d},{d}", .{ m.surface_x.toInt(), m.surface_y.toInt() });
        },
        .button => |b| {
            if (b.button == 272 and @intFromEnum(b.state) == 1) state.got_button = true;
            step("pointer button {d} state={d}", .{ b.button, @intFromEnum(b.state) });
        },
        .axis => |a| step("pointer axis {d} value={d}", .{ @intFromEnum(a.axis), a.value.toInt() }),
        .frame => {},
        .axis_source => |s| step("axis_source={d}", .{@intFromEnum(s.axis_source)}),
        .axis_stop => |s| step("axis_stop {d}", .{@intFromEnum(s.axis)}),
        .axis_discrete => |d| step("axis_discrete {d} ticks={d}", .{ @intFromEnum(d.axis), d.discrete }),
        .axis_relative_direction => |d| step("axis_relative_direction {d}", .{@intFromEnum(d.direction)}),
        .axis_value120 => |v| step("axis_value120 {d} v120={d}", .{ @intFromEnum(v.axis), v.value120 }),
        .warp => |w| step("warp {d},{d}", .{ w.surface_x.toInt(), w.surface_y.toInt() }),
    }
}

fn onBoundOutputEvent(output: *wl.Output, event: wl.Output.Event, slot: *OutputSlot) void {
    _ = output;
    const state = slot.state;
    switch (event) {
        .geometry => |g| step("output {d} geometry {s} {s} transform={d}", .{
            slot.slot.index, std.mem.span(g.make), std.mem.span(g.model), @intFromEnum(g.transform),
        }),
        .mode => |m| {
            slot.slot.mode = .{ .width = m.width, .height = m.height };
            // The first output stays the M3 flow's reference mode: the
            // surface is sized from it and every output in this run
            // advertises the same one.
            if (slot.slot.index == 0) state.output_mode = slot.slot.mode;
            step("output {d} mode {d}x{d}@{d} flags=0x{x}", .{
                slot.slot.index, m.width, m.height, m.refresh, @as(u32, @bitCast(m.flags)),
            });
        },
        .done => {},
        .scale => |s| step("output {d} scale={d}", .{ slot.slot.index, s.factor }),
        .name => |n| step("output {d} name={s}", .{ slot.slot.index, std.mem.span(n.name) }),
        .description => |d| step("output {d} description={s}", .{ slot.slot.index, std.mem.span(d.description) }),
    }
}

fn onCaptureFrameEvent(
    frame: *client.zwlr.ScreencopyFrameV1,
    event: client.zwlr.ScreencopyFrameV1.Event,
    state: *ClientState,
) void {
    switch (event) {
        .buffer => |b| {
            // Advertised shm buffer: allocate it and send the copy request.
            const cap = &state.capture.?;
            cap.width = b.width;
            cap.height = b.height;
            cap.stride = b.stride;
            cap.buffer = cap.pool.createBuffer(
                0,
                @intCast(b.width),
                @intCast(b.height),
                @intCast(b.stride),
                .argb8888,
            ) catch |err| {
                // Flag the failure: no copy is sent, so the server sends
                // no ready/failed and the wait must not report a timeout.
                cap.failed = true;
                cap.failure = .buffer_create;
                step("capture buffer creation failed: {s}", .{@errorName(err)});
                return;
            };
            cap.sent_copy = true;
            frame.copy(cap.buffer);
            if (wl.Display.flush(state.display) != .SUCCESS) {
                cap.failed = true;
                cap.failure = .flush;
                step("flush after capture copy failed", .{});
                return;
            }
            step("capture buffer {d}x{d} stride={d}, copy sent", .{ b.width, b.height, b.stride });
        },
        .linux_dmabuf => |d| step("capture linux_dmabuf {d}x{d}", .{ d.width, d.height }),
        .buffer_done => {},
        .damage => |d| step("capture damage {d}x{d}@{d},{d}", .{ d.width, d.height, d.x, d.y }),
        .flags => |f| step("capture flags=0x{x}", .{@as(u32, @bitCast(f.flags))}),
        .ready => |r| {
            const cap = &state.capture.?;
            cap.ready = true;
            step("capture ready ts={d},{d},{d}", .{ r.tv_sec_hi, r.tv_sec_lo, r.tv_nsec });
        },
        .failed => {
            state.capture.?.failed = true;
            step("capture failed", .{});
        },
    }
}

fn onXdgSurfaceEvent(surface: *xdg.Surface, event: xdg.Surface.Event, state: *ClientState) void {
    _ = surface;
    switch (event) {
        .configure => |c| {
            state.configure_serial = c.serial;
            state.got_configure = true;
            // Ack every configure immediately: the server sends a second
            // size configure at first map that a single pre-commit ack
            // would never cover (the client commits only once).
            state.xdg_surface.?.ackConfigure(c.serial);
        },
    }
}

/// wl_surface.enter/leave. Only the enter is load-bearing: it is the
/// compositor saying this surface is on an output, which is what makes
/// the pointer coordinates below meaningful to place anything in a
/// capture.
fn onSurfaceEvent(surface: *wl.Surface, event: wl.Surface.Event, state: *ClientState) void {
    _ = surface;
    switch (event) {
        .enter => {
            state.surface_entered = true;
            step("wl_surface.enter: the surface is on an output", .{});
        },
        .leave => step("wl_surface.leave", .{}),
        // These are preferences; this protocol client selects each scale
        // and transform explicitly for its pixel and input qualification.
        .preferred_buffer_scale, .preferred_buffer_transform => {},
    }
}

fn onToplevelEvent(toplevel: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *ClientState) void {
    _ = toplevel;
    _ = state;
    switch (event) {
        .configure => |c| step("toplevel.configure {d}x{d} states={d}", .{ c.width, c.height, c.states.size }),
        .close => {},
        .configure_bounds => {},
        .wm_capabilities => {},
    }
}

fn onFrameDone(callback: *wl.Callback, event: wl.Callback.Event, state: *ClientState) void {
    _ = callback;
    switch (event) {
        .done => |d| {
            step("wl_callback.done time={d}", .{d.callback_data});
            state.frame_done = true;
        },
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn hasConfigure(state: *const ClientState) bool {
    return state.got_configure;
}

fn hasFrame(state: *const ClientState) bool {
    return state.frame_done;
}

fn hasPointerEnter(state: *const ClientState) bool {
    return state.got_pointer_enter;
}

fn hasSurfaceEntered(state: *const ClientState) bool {
    return state.surface_entered;
}

fn hasKeyPress(state: *const ClientState) bool {
    return state.got_key_press;
}

fn hasCaptureDone(state: *const ClientState) bool {
    const cap = state.capture orelse return false;
    return cap.ready or cap.failed;
}

/// Resolve the surface size from the advertised output mode. Called once
/// before the shm buffer setup; by then the mode event has been dispatched
/// (the global binds are flushed together with the empty commit, so the
/// server's bind-time output state arrives during the configure wait).
/// Falls back to the legacy constants with a warning if the mode event is
/// still missing.
fn resolveSurfaceSize(state: *ClientState) void {
    if (state.output_mode) |m| {
        state.surface_width = m.width;
        state.surface_height = m.height;
    } else {
        state.surface_width = fallback_width;
        state.surface_height = fallback_height;
        step("WARNING: no wl_output mode yet; using fallback size {d}x{d}", .{
            fallback_width, fallback_height,
        });
    }
}

/// Allocate the capture buffer (second memfd + shm pool) and the frame
/// state for `output`, the frame object the screencopy manager creates.
/// The pool is sized from THAT output's advertised mode, never from the
/// first output's: a capture of a second, differently sized output would
/// otherwise be too small for the frame the server is about to send.
fn setupCaptureFor(
    state: *ClientState,
    output: *wl.Output,
    mode: OutputMode,
) !*client.zwlr.ScreencopyFrameV1 {
    const pool_size: usize = @as(usize, @intCast(mode.width)) *
        @as(usize, @intCast(mode.height)) * bytes_per_pixel;
    const fd = try std.posix.memfd_create("m3-capture", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    {
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
    }
    const pixels = try std.posix.mmap(
        null,
        pool_size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(pixels);
    const pool = try state.shm.?.createPool(fd, @intCast(pool_size));
    errdefer pool.destroy();
    const frame = try state.screencopy_mgr.?.captureOutput(1, output);
    state.capture = .{
        .frame = frame,
        .fd = fd,
        .pixels = pixels,
        .pool = pool,
        // SAFETY: the buffer event fills this field before any read.
        .buffer = undefined,
        .stride = 0,
    };
    return frame;
}

/// The M3 capture: the first output this client bound, at the mode that
/// output announced. Every other capture in this file names its own
/// output AND its own mode through setupCaptureFor.
fn setupCapture(state: *ClientState) !*client.zwlr.ScreencopyFrameV1 {
    const mode = state.output_mode orelse return error.OutputModeMissing;
    return setupCaptureFor(state, state.output.?, mode);
}

// ---------------------------------------------------------------------------
// Geometry: what each output view must be showing
// ---------------------------------------------------------------------------
//
// Four OBSERVED inputs decide every expectation in this file: the pointer
// coordinates the wire delivered, the mode each wl_output announced, the
// WAYLAND_CAMERA the server was started with, and the pixels this client
// itself drew into its own buffer. No check below carries a remembered
// screen coordinate. The cursor follows the pointer through the camera,
// the gradient probes are placed from the surface rectangle and the
// cursor box, and every colour is predicted by evaluating the protocol's
// sampling chain over the client's own texels.

/// A point in the f64 the geometry here is computed in.
const FPoint = struct { x: f64, y: f64 };

/// A rectangle in the same f64 (a wp_viewport source is fractional by
/// protocol, so none of these edges is an integer).
const FRect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    fn right(r: FRect) f64 {
        return r.x + r.width;
    }

    fn bottom(r: FRect) f64 {
        return r.y + r.height;
    }
};

/// One output view's world -> that view's own pixels mapping.
///
/// "World" here means a coordinate in THIS view: the compositor puts a
/// surface's tree at its view's desktop origin and shifts that view's
/// camera centre by the same origin, so a client's surface-local
/// coordinates and this camera share one frame and the origin cancels.
const ViewCamera = struct {
    center_x: f64,
    center_y: f64,
    zoom: f64,
    rotation: f64,
    screen_w: f64,
    screen_h: f64,

    /// The camera an output of `mode` runs with, parsed from the same
    /// string the server parsed (server/main.zig parseCameraEnv over
    /// scene/camera.zig parseEnv). Unset and malformed values both yield
    /// the default — the view's own centre, zoom 1, no rotation, i.e.
    /// world -> screen is the identity. A set value parses strictly: a
    /// field it does not name stays 0/1/0 and `rot` is in degrees.
    fn forOutput(raw: ?[]const u8, mode: OutputMode) ViewCamera {
        const w: f64 = @floatFromInt(mode.width);
        const h: f64 = @floatFromInt(mode.height);
        const default: ViewCamera = .{
            .center_x = w / 2.0,
            .center_y = h / 2.0,
            .zoom = 1,
            .rotation = 0,
            .screen_w = w,
            .screen_h = h,
        };
        const value = raw orelse return default;
        var cam: ViewCamera = .{
            .center_x = 0,
            .center_y = 0,
            .zoom = 1,
            .rotation = 0,
            .screen_w = w,
            .screen_h = h,
        };
        // An EMPTY value is not the default: parseEnv returns the
        // identity camera before it looks at any field, which centres
        // the world ORIGIN rather than the view.
        if (value.len == 0) return cam;
        var fields = std.mem.splitScalar(u8, value, ',');
        while (fields.next()) |field| {
            if (field.len == 0) return default;
            const eq = std.mem.indexOfScalar(u8, field, '=') orelse return default;
            const val = std.fmt.parseFloat(f64, field[eq + 1 ..]) catch return default;
            const key = field[0..eq];
            if (std.mem.eql(u8, key, "cx")) {
                cam.center_x = val;
            } else if (std.mem.eql(u8, key, "cy")) {
                cam.center_y = val;
            } else if (std.mem.eql(u8, key, "zoom")) {
                cam.zoom = val;
            } else if (std.mem.eql(u8, key, "rot")) {
                cam.rotation = val * (std.math.pi / 180.0);
            } else return default;
        }
        return cam;
    }

    /// world -> this view's pixels (scene/camera.zig worldToScreen):
    /// p_screen = R(-rotation) * (p_world - center) * zoom + viewport/2.
    fn worldToScreen(cam: ViewCamera, wx: f64, wy: f64) FPoint {
        const cos_r = @cos(cam.rotation);
        const sin_r = @sin(cam.rotation);
        const dx = wx - cam.center_x;
        const dy = wy - cam.center_y;
        return .{
            .x = (dx * cos_r + dy * sin_r) * cam.zoom + cam.screen_w / 2.0,
            .y = (-dx * sin_r + dy * cos_r) * cam.zoom + cam.screen_h / 2.0,
        };
    }

    /// this view's pixels -> world (scene/camera.zig screenToWorld), the
    /// exact inverse of worldToScreen.
    fn screenToWorld(cam: ViewCamera, sx: f64, sy: f64) FPoint {
        const cos_r = @cos(cam.rotation);
        const sin_r = @sin(cam.rotation);
        const ux = (sx - cam.screen_w / 2.0) / cam.zoom;
        const uy = (sy - cam.screen_h / 2.0) / cam.zoom;
        return .{
            .x = cam.center_x + ux * cos_r - uy * sin_r,
            .y = cam.center_y + ux * sin_r + uy * cos_r,
        };
    }
};

/// The cursor overlay's footprint in one view's own pixels. A cursor is
/// drawn in SCREEN space (server/main.zig cursorScreenRect): the pointer
/// minus the cursor image's hotspot, at the image's constant logical size,
/// never rotated or scaled by the canvas camera. With no client cursor
/// surface set the image is the built-in 16x16 arrow whose hotspot is its
/// top-left tip, so the box starts exactly AT the pointer.
const CursorBox = struct {
    x: i64,
    y: i64,
    width: i64 = cursor_overlay_size,
    height: i64 = cursor_overlay_size,

    /// True for a pixel the overlay covers, grown by one pixel so a probe
    /// on the sprite's own edge still counts as "on the cursor".
    fn covers(box: CursorBox, px: i64, py: i64) bool {
        return px >= box.x - 1 and px <= box.x + box.width and
            py >= box.y - 1 and py <= box.y + box.height;
    }

    /// True when the whole sprite lies inside a capture of this size,
    /// which is what locating it from its body needs: a sprite clipped by
    /// the view edge has no visible top-left corner.
    fn wholeInside(box: CursorBox, w: u32, h: u32) bool {
        return box.x >= 0 and box.y >= 0 and
            box.x + box.width <= @as(i64, w) and box.y + box.height <= @as(i64, h);
    }
};

/// Where the pointer is in this view's own pixels, DERIVED from what the
/// wire and the output said rather than assumed anywhere:
///
///   * the compositor aims its synthesized click at the mapped surface's
///     centre, projects that world point through the view's camera and
///     adds the view's desktop origin, so the pointer's desktop pixel is
///     view.rect.origin + floor(worldToScreen(centre));
///   * the same point reaches this client as the surface-local offset the
///     hit test produced — pointer_surface_x/y, kept as the f64 the 24.8
///     fixed coordinates carried;
///   * worldToScreen is affine, so mapping that offset back through this
///     view's camera reproduces the pointer's view pixel: the view origin
///     the surface tree sits on cancels against the same origin in the
///     camera centre, which is why no surface placement is assumed.
///
/// Null when the pointer is outside this view's rectangle: a view draws
/// its cursor only while the pointer is on it, so this output is one the
/// cursor check must not expect anything from.
fn derivedCursorBox(state: *const ClientState, mode: OutputMode) ?CursorBox {
    if (!state.got_pointer_motion) return null;
    var cam = ViewCamera.forOutput(state.camera_env, mode);
    if (state.pointer_after_zoom) cam.zoom *= synth_zoom_step;
    const at = cam.worldToScreen(state.pointer_surface_x, state.pointer_surface_y);
    const w: f64 = @floatFromInt(mode.width);
    const h: f64 = @floatFromInt(mode.height);
    // Compared BEFORE narrowing: a camera this client cannot model (a
    // WAYLAND_CAMERA zoom of zero, say, which the server would also fail
    // to render) must be reported, never turned into a pixel index. Every
    // comparison is false for a NaN, so that case lands here too.
    if (!(at.x >= -1 and at.x <= w + 1 and at.y >= -1 and at.y <= h + 1)) return null;
    const x: i64 = @intFromFloat(@floor(at.x));
    const y: i64 = @intFromFloat(@floor(at.y));
    if (x < 0 or y < 0 or x >= @as(i64, mode.width) or y >= @as(i64, mode.height)) return null;
    return .{ .x = x, .y = y };
}

/// The buffer content a surface is drawn from, as THIS CLIENT wrote it:
/// every expectation below is computed from these texels, so nothing is
/// pinned to what the compositor happened to draw.
const Texels = struct {
    /// RAW buffer dimensions the sampler indexes into.
    width: i64,
    height: i64,
    /// The raw buffer-pixel crop the filter is bounded by: the whole
    /// texture when the surface carries no wp_viewport source.
    crop: FRect,
    /// The M1 red gradient, or the transform phase's asymmetric fixture.
    kind: enum { gradient, fixture },

    /// The texel at (x, y) in memory byte order (B, G, R, A).
    fn at(t: Texels, x: i64, y: i64) [4]u8 {
        return switch (t.kind) {
            // fillPattern: B ramps with the buffer x, G is 0, R and A
            // are opaque. G=0 also means the gradient can never be read
            // as the cursor's white body.
            .gradient => .{ @intCast(@divTrunc(x * 255, t.width)), 0, 255, 255 },
            .fixture => fixtureTexel(x, y),
        };
    }
};

fn wholeCrop(width: i64, height: i64) FRect {
    return .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) };
}

/// A surface coordinate -> raw buffer texel POSITION: the continuous
/// inverse of wlr_box_transform (utils/matrix.zig, renderer/pixman.zig)
/// with texel i spanning [i, i+1), so its centre sits at i + 0.5.
/// `transform` is the wire value of wl_surface.set_buffer_transform.
fn surfaceToBufferTexel(transform: u32, x: f64, y: f64, buf_w: i64, buf_h: i64) FPoint {
    const w: f64 = @floatFromInt(buf_w);
    const h: f64 = @floatFromInt(buf_h);
    return switch (transform) {
        0 => .{ .x = x, .y = y },
        1 => .{ .x = y, .y = h - x },
        2 => .{ .x = w - x, .y = h - y },
        3 => .{ .x = w - y, .y = x },
        4 => .{ .x = w - x, .y = y },
        5 => .{ .x = y, .y = x },
        6 => .{ .x = x, .y = h - y },
        else => .{ .x = h - y, .y = w - x },
    };
}

/// What the compositor must have written at view pixel (px, py) for one
/// surface of `size_w` x `size_h` view-local pixels drawn from `texels`
/// through `transform` — the sampling chain the renderers document
/// (renderer/pixman.zig, renderer/canvas.zig), stated once:
///
///   1. the DESTINATION PIXEL'S CENTRE goes through the camera inverse;
///   2. destination-normalized coordinates outside the quad are not drawn;
///   3. the buffer transform's inverse gives a raw texel POSITION;
///   4. that position is clamped to the crop's texel-centre bounds;
///   5. ONE subtraction of 0.5 turns it into the sampler's index frame;
///   6. the four taps blend bilinearly over the client's own texels.
///
/// Null when the pixel centre is outside the surface: the compositor keeps
/// the background there and draws nothing.
fn expectedPixel(
    cam: ViewCamera,
    size_w: f64,
    size_h: f64,
    transform: u32,
    texels: Texels,
    px: i64,
    py: i64,
) ?[4]u8 {
    const at = cam.screenToWorld(
        @as(f64, @floatFromInt(px)) + 0.5,
        @as(f64, @floatFromInt(py)) + 0.5,
    );
    // Written as a positive test so a NaN (a camera this client cannot
    // model) falls out here instead of reaching the narrowing below.
    if (!(at.x / size_w >= 0 and at.x / size_w < 1 and at.y / size_h >= 0 and at.y / size_h < 1)) return null;
    const texel = surfaceToBufferTexel(transform, at.x, at.y, texels.width, texels.height);
    const lo_x = texels.crop.x + 0.5;
    const lo_y = texels.crop.y + 0.5;
    const pos_x = std.math.clamp(texel.x, lo_x, @max(lo_x, texels.crop.right() - 0.5));
    const pos_y = std.math.clamp(texel.y, lo_y, @max(lo_y, texels.crop.bottom() - 0.5));
    const cx = std.math.clamp(pos_x - 0.5, 0.0, @as(f64, @floatFromInt(texels.width - 1)));
    const cy = std.math.clamp(pos_y - 0.5, 0.0, @as(f64, @floatFromInt(texels.height - 1)));
    const ix0: i64 = @intFromFloat(@floor(cx));
    const iy0: i64 = @intFromFloat(@floor(cy));
    const ix1 = @min(ix0 + 1, texels.width - 1);
    const iy1 = @min(iy0 + 1, texels.height - 1);
    const fx = cx - @as(f64, @floatFromInt(ix0));
    const fy = cy - @as(f64, @floatFromInt(iy0));
    const gx = 1.0 - fx;
    const gy = 1.0 - fy;
    var out: [4]u8 = undefined;
    inline for (0..4) |ch| {
        const value = @as(f64, @floatFromInt(texels.at(ix0, iy0)[ch])) * gx * gy +
            @as(f64, @floatFromInt(texels.at(ix1, iy0)[ch])) * fx * gy +
            @as(f64, @floatFromInt(texels.at(ix0, iy1)[ch])) * gx * fy +
            @as(f64, @floatFromInt(texels.at(ix1, iy1)[ch])) * fx * fy;
        out[ch] = @intFromFloat(@round(std.math.clamp(value, 0.0, 255.0)));
    }
    return out;
}

/// Fractional positions along each axis probes are taken from: spread so
/// a probe never lands on a sprite edge or on the surface's first pixel,
/// and ordered so one geometry always yields the same probes.
const probe_fractions = [_]f64{ 0.125, 0.375, 0.625, 0.875, 0.25, 0.75, 0.0625, 0.9375 };

/// How many probes one surface check reads.
const max_probes: usize = 8;

/// A pixel a surface check reads, with the surface-local point it came
/// from, so a failure can name both sides of the mapping.
const Probe = struct {
    x: i64,
    y: i64,
    sx: f64,
    sy: f64,
};

/// Probe pixels for one surface in one capture: positions on the surface
/// whose view pixel (a) exists in the capture, (b) is strictly inside the
/// surface quad so it reads the surface rather than the background, and
/// (c) is not covered by the cursor overlay. All three come from the
/// geometry — the surface rectangle, the camera and the derived cursor
/// box — which is what keeps a probe from landing on the cursor after a
/// camera or pointer position moves it there.
fn surfaceProbes(
    cam: ViewCamera,
    size_w: f64,
    size_h: f64,
    cursor: ?CursorBox,
    cap_w: u32,
    cap_h: u32,
    out: *[max_probes]Probe,
) usize {
    const w: f64 = @floatFromInt(cap_w);
    const h: f64 = @floatFromInt(cap_h);
    var count: usize = 0;
    var fx_index: usize = 0;
    while (fx_index < probe_fractions.len and count < max_probes) : (fx_index += 1) {
        var fy_index: usize = 0;
        while (fy_index < probe_fractions.len and count < max_probes) : (fy_index += 1) {
            const sx = probe_fractions[fx_index] * size_w;
            const sy = probe_fractions[fy_index] * size_h;
            const at = cam.worldToScreen(sx, sy);
            // Bounded BEFORE narrowing: a camera this client cannot model
            // (a NaN, a zero zoom) drops the probe instead of trapping the
            // float -> int conversion. Every comparison is false for a
            // NaN, so that case lands here as well.
            if (!(at.x >= 0 and at.x < w and at.y >= 0 and at.y < h)) continue;
            const px: i64 = @intFromFloat(@floor(at.x));
            const py: i64 = @intFromFloat(@floor(at.y));
            if (cursor) |box| {
                if (box.covers(px, py)) continue;
            }
            var duplicate = false;
            for (out[0..count]) |seen| {
                if (seen.x == px and seen.y == py) duplicate = true;
            }
            if (duplicate) continue;
            out[count] = .{ .x = px, .y = py, .sx = sx, .sy = sy };
            count += 1;
        }
    }
    return count;
}

/// Per-channel tolerance of a surface check. The default surface is
/// composited through the real pixman library (renderer/canvas.zig's
/// whole-texture fast path), whose fixed-point transform and SIMD filter
/// can land a unit away from this f64 oracle on the ramp's plateau
/// boundaries; every transformed, scaled or cropped surface goes through
/// the f64 loop instead and matches to one unit.
const pixman_tolerance: u8 = 2;
const sampling_tolerance: u8 = 1;

/// Read every probe of this surface out of `cap` and compare it with the
/// pixel the client's own texels predict. The first mismatch names the
/// geometry it was taken at, so a failure says WHICH pixel of WHICH
/// surface was wrong rather than just "mismatch"; the count of matching
/// probes comes back for the verdict.
fn verifySurfacePixels(
    cap: *const CaptureState,
    cam: ViewCamera,
    size_w: f64,
    size_h: f64,
    transform: u32,
    texels: Texels,
    cursor: ?CursorBox,
    tolerance: u8,
    comptime tag: []const u8,
) !usize {
    var probes: [max_probes]Probe = undefined;
    const total = surfaceProbes(cam, size_w, size_h, cursor, cap.width, cap.height, &probes);
    if (total == 0) {
        verdict(tag, "no probe of the {d:.0}x{d:.0} surface fits this {d}x{d} capture", .{
            size_w, size_h, cap.width, cap.height,
        });
        return error.TooFewProbes;
    }
    var matched: usize = 0;
    for (probes[0..total], 0..) |probe, index| {
        const want = expectedPixel(cam, size_w, size_h, transform, texels, probe.x, probe.y);
        const got = pxAtI64(cap, probe.x, probe.y);
        if (want == null or got == null) {
            verdict(tag, "probe {d} at view ({d},{d}) is outside the capture or the surface", .{
                index, probe.x, probe.y,
            });
            return error.PixelMismatch;
        }
        if (pixelNearTol(got.?, want.?, tolerance)) {
            matched += 1;
            continue;
        }
        verdict(tag, "view pixel ({d},{d}) [surface {d:.1},{d:.1}] = {d},{d},{d},{d}, expected {d},{d},{d},{d} (+/-{d})", .{
            probe.x,      probe.y,    probe.sx,          probe.sy,
            got.?[0],     got.?[1],   got.?[2],           got.?[3],
            want.?[0],    want.?[1],  want.?[2],          want.?[3],
            tolerance,
        });
        return error.PixelMismatch;
    }
    return matched;
}

/// Verify one capture of this client's surface under `cam`: the gradient
/// at probes derived from the surface rectangle, that camera and the
/// derived cursor box, and the cursor overlay itself at the position the
/// pointer datum and that same camera put it.
fn verifyCapturePixels(
    cap: *const CaptureState,
    state: *const ClientState,
    cam: ViewCamera,
) !void {
    const mode = state.output_mode orelse {
        verdict("CLIENT-ERROR", "no wl_output mode received", .{});
        return error.OutputModeMissing;
    };
    if (cap.width != @as(u32, @intCast(mode.width)) or
        cap.height != @as(u32, @intCast(mode.height)))
    {
        verdict("CLIENT-ERROR", "capture {d}x{d} is not this output's advertised mode {d}x{d}", .{
            cap.width, cap.height, mode.width, mode.height,
        });
        return error.CaptureSizeBad;
    }
    if (!state.surface_entered) {
        verdict("CLIENT-ERROR", "the surface was never entered on an output", .{});
        return error.SurfaceNotEntered;
    }
    const cursor = derivedCursorBox(state, mode) orelse {
        verdict("CLIENT-ERROR", "the derived pointer ({d:.1},{d:.1}) is outside the {d}x{d} output: it carries no cursor overlay to check", .{
            state.pointer_surface_x, state.pointer_surface_y, mode.width, mode.height,
        });
        return error.CursorOffOutput;
    };
    const matched = try verifySurfacePixels(
        cap,
        cam,
        @floatFromInt(state.surface_width),
        @floatFromInt(state.surface_height),
        0,
        gradientTexels(state),
        cursor,
        pixman_tolerance,
        "CLIENT-ERROR",
    );
    try verifyCursorOverlay(cap, cursor, "CLIENT-ERROR");
    verdict("CLIENT-CAPTURE", "{d} gradient probes + cursor overlay at {d},{d} (camera zoom {d:.2})", .{
        matched, cursor.x, cursor.y, cam.zoom,
    });
}

/// The M1 gradient as Texels: the whole output-sized buffer, unscaled,
/// untransformed and uncropped.
fn gradientTexels(state: *const ClientState) Texels {
    const w: i64 = state.surface_width;
    const h: i64 = state.surface_height;
    return .{ .width = w, .height = h, .crop = wholeCrop(w, h), .kind = .gradient };
}

/// The captured pixel's BGRA bytes at (x, y) in the framebuffer.
fn pxAt(cap: *const CaptureState, x: usize, y: usize) [4]u8 {
    const off = y * cap.stride + x * 4;
    return .{ cap.pixels[off], cap.pixels[off + 1], cap.pixels[off + 2], cap.pixels[off + 3] };
}

/// The captured pixel at (x, y), or null when it lies outside the
/// capture. Everything that walks a capture by derived coordinates uses
/// this one; pxAt stays for the fixed coordinates the hotplug phase
/// fingerprints.
fn pxAtI64(cap: *const CaptureState, x: i64, y: i64) ?[4]u8 {
    if (x < 0 or y < 0 or x >= @as(i64, cap.width) or y >= @as(i64, cap.height)) return null;
    const at = @as(usize, @intCast(y)) * cap.stride + @as(usize, @intCast(x)) * bytes_per_pixel;
    if (at + bytes_per_pixel > cap.pixels.len) return null;
    return .{ cap.pixels[at], cap.pixels[at + 1], cap.pixels[at + 2], cap.pixels[at + 3] };
}

// --- The cursor overlay, located in the capture --------------------------

/// The built-in cursor's edge length in view pixels. compositor/cursor.zig
/// draws it as a cursor_size² arrow whose hotspot is its top-left tip, at
/// constant size whatever the canvas camera does.
const cursor_overlay_size: i64 = 16;

/// A pixel belongs to the cursor's white body at or above this in every
/// channel. The body is opaque white (255); the M1 gradient has G = 0, the
/// transform fixture caps R and G at 200, and the compositor's background
/// is dark — so nothing else this client draws can be read as the cursor.
const cursor_white: u8 = 220;

/// An inclusive pixel rectangle: the bounding box of the cursor's body.
const BodyBox = struct {
    x0: i64,
    y0: i64,
    x1: i64,
    y1: i64,
};

/// The sprite pixel the built-in arrow's body starts at, relative to the
/// pointer: row 2, column 1 of the 16x16 shape. The outline's tip — the
/// hotspot pixel — is (0,0), so it sits one up-left of that.
const cursor_body_offset_x: i64 = 1;
const cursor_body_offset_y: i64 = 2;

/// The bounding box of the cursor's white body inside a small window
/// around `box`, or null when no such pixel exists (no cursor drawn here).
/// The window is the sprite box grown by two pixels, so a cursor placed a
/// little off is still found and its offset is measurable rather than
/// assumed away.
fn locateCursorBody(cap: *const CaptureState, box: CursorBox) ?BodyBox {
    const lo_x = @max(@as(i64, 0), box.x - 2);
    const hi_x = @min(@as(i64, cap.width), box.x + cursor_overlay_size + 2);
    const lo_y = @max(@as(i64, 0), box.y - 2);
    const hi_y = @min(@as(i64, cap.height), box.y + cursor_overlay_size + 2);
    var body: BodyBox = undefined;
    var found = false;
    var y = lo_y;
    while (y < hi_y) : (y += 1) {
        var x = lo_x;
        while (x < hi_x) : (x += 1) {
            const p = pxAtI64(cap, x, y) orelse continue;
            if (p[0] < cursor_white or p[1] < cursor_white or p[2] < cursor_white) continue;
            if (!found) {
                body = .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y };
                found = true;
                continue;
            }
            body.x0 = @min(body.x0, x);
            body.x1 = @max(body.x1, x);
            body.y0 = @min(body.y0, y);
            body.y1 = @max(body.y1, y);
        }
    }
    return if (found) body else null;
}

/// Verify the cursor overlay a capture must be carrying at `box`.
///
/// The sprite is located IN the capture and everything is then anchored to
/// what was found, so the check states two independent facts: the overlay
/// is where the pointer datum and the camera put it (its body's top-left
/// is the arrow's own (1,2) at that pointer, within one pixel — the width
/// of the fixed-point coordinate the wire delivered), and it is drawn
/// correctly there (the hotspot pixel is the black outline the arrow is
/// built around, the middle of the body is opaque white, and the body is a
/// body rather than a speck). A cursor that is missing, somewhere else, or
/// drawn at another size fails here; nothing about where the pointer "is
/// supposed to be" is hardcoded.
fn verifyCursorOverlay(cap: *const CaptureState, box: CursorBox, comptime tag: []const u8) !void {
    const body = locateCursorBody(cap, box) orelse {
        verdict(tag, "no cursor body in the 20x20 window at ({d},{d}) of this {d}x{d} capture", .{
            box.x, box.y, cap.width, cap.height,
        });
        return error.CursorMissing;
    };
    const want_x = box.x + cursor_body_offset_x;
    const want_y = box.y + cursor_body_offset_y;
    if (@abs(body.x0 - want_x) > 1 or @abs(body.y0 - want_y) > 1) {
        verdict(tag, "cursor body starts at ({d},{d}); a pointer at ({d},{d}) puts it at ({d},{d})", .{
            body.x0, body.y0, box.x, box.y, want_x, want_y,
        });
        return error.CursorMisplaced;
    }
    if (body.x1 - body.x0 < 5 or body.y1 - body.y0 < 7) {
        verdict(tag, "cursor body is {d}x{d} px at ({d},{d}), too small to be the {d}px arrow", .{
            body.x1 - body.x0 + 1, body.y1 - body.y0 + 1, body.x0, body.y0, cursor_overlay_size,
        });
        return error.CursorTooSmall;
    }
    const tip = pxAtI64(cap, body.x0 - cursor_body_offset_x, body.y0 - cursor_body_offset_y) orelse {
        verdict(tag, "the cursor's hotspot pixel is outside the capture", .{});
        return error.CursorMissing;
    };
    if (tip[0] >= 64 or tip[1] >= 64 or tip[2] >= 64) {
        verdict(tag, "cursor hotspot ({d},{d}) = {d},{d},{d},{d}, expected the arrow's black outline", .{
            body.x0 - cursor_body_offset_x, body.y0 - cursor_body_offset_y,
            tip[0], tip[1], tip[2], tip[3],
        });
        return error.CursorPixelMismatch;
    }
    const mid = pxAtI64(cap, body.x0 + 4, body.y0 + 8) orelse {
        verdict(tag, "the cursor's body centre is outside the capture", .{});
        return error.CursorMissing;
    };
    if (mid[0] < cursor_white or mid[1] < cursor_white or mid[2] < cursor_white) {
        verdict(tag, "cursor body ({d},{d}) = {d},{d},{d},{d}, expected opaque white", .{
            body.x0 + 4, body.y0 + 8, mid[0], mid[1], mid[2], mid[3],
        });
        return error.CursorPixelMismatch;
    }
    step("cursor at ({d},{d}): body ({d},{d})-({d},{d}), hotspot and body pixels verified", .{
        box.x, box.y, body.x0, body.y0, body.x1, body.y1,
    });
}

/// M4 Phase B: wait for the server's synth wheel zoom to land, then
/// verify the gradient under the new camera. The notch multiplies the
/// view's zoom by one step (server/main.zig onSeatAxis) once the server
/// has served a capture, so the camera this client predicts afterwards is
/// its own camera with that one step applied — derived, not observed.
/// The compositor re-renders fully after the axis event, so a fresh
/// screencopy shows the new zoom within a frame of the notch: capture ->
/// check -> 250ms -> retry, bounded, and CLIENT-ERROR if it never lands.
fn verifyZoomLanding(state: *ClientState) !void {
    const mode = state.output_mode orelse return error.OutputModeMissing;
    const before = ViewCamera.forOutput(state.camera_env, mode);
    var after = before;
    after.zoom = before.zoom * synth_zoom_step;
    const cursor = derivedCursorBox(state, mode);
    var attempt: u32 = 0;
    while (attempt < 30) : (attempt += 1) {
        const frame = try setupCapture(state);
        frame.setListener(*ClientState, onCaptureFrameEvent, state);
        if (wl.Display.flush(state.display) != .SUCCESS) {
            verdict("CLIENT-ERROR", "flush after zoom capture failed", .{});
            return error.FlushFailed;
        }
        if (!try waitForEvent(hasCaptureDone, state, timeout_ms)) {
            verdict("CLIENT-TIMEOUT", "no zoom capture ready/failed within {d}ms", .{timeout_ms});
            return error.ClientTimeout;
        }
        const cap = &state.capture.?;
        if (cap.failed or !cap.ready) {
            // The failure flag makes the wait end with a specific
            // CLIENT-ERROR instead of timing out (no ready event).
            switch (cap.failure) {
                .server => verdict("CLIENT-ERROR", "zoom screencopy failed", .{}),
                .buffer_create => verdict("CLIENT-ERROR", "zoom capture buffer creation failed", .{}),
                .flush => verdict("CLIENT-ERROR", "flush after zoom capture copy failed", .{}),
            }
            return error.CaptureFailed;
        }
        const matched = surfaceProbeMatches(cap, after, gradientTexels(state), cursor, pixman_tolerance);
        if (matched > 0) {
            verdict("CLIENT-ZOOM", "zoom landed: {d:.2} -> {d:.2} ({d} gradient probes match the new camera)", .{
                before.zoom, after.zoom, matched,
            });
            destroyCapture(state);
            state.synth_zoom_settled = true;
            return;
        }
        step("zoom not landed yet (attempt {d}): the gradient still reads the {d:.2}x camera", .{
            attempt + 1, before.zoom,
        });
        destroyCapture(state);
        std.Io.sleep(client_io, .fromMilliseconds(250), .awake) catch |err| {
            verdict("CLIENT-ERROR", "zoom retry sleep failed: {s}", .{@errorName(err)});
            return err;
        };
    }
    verdict("CLIENT-ERROR", "the camera never reached the post-notch zoom {d:.2} (started at {d:.2})", .{
        after.zoom, before.zoom,
    });
    return error.ZoomNotLanded;
}

/// The M1 surface under one camera, as an answer rather than an error:
/// the zoom phase asks "does this capture already show the new camera?"
/// until it does, and every failure of the underlying check means exactly
/// "not yet" — so this prints NOTHING (CLIENT-ZOOM is the success marker
/// and must not appear before the zoom has landed). It returns the probe
/// count only when every probe matched, and 0 otherwise.
fn surfaceProbeMatches(
    cap: *const CaptureState,
    cam: ViewCamera,
    texels: Texels,
    cursor: ?CursorBox,
    tolerance: u8,
) usize {
    const width: f64 = @floatFromInt(texels.width);
    const height: f64 = @floatFromInt(texels.height);
    var probes: [max_probes]Probe = undefined;
    const total = surfaceProbes(cam, width, height, cursor, cap.width, cap.height, &probes);
    if (total == 0) return 0;
    var matched: usize = 0;
    for (probes[0..total]) |probe| {
        const want = expectedPixel(cam, width, height, 0, texels, probe.x, probe.y) orelse return 0;
        const got = pxAtI64(cap, probe.x, probe.y) orelse return 0;
        if (!pixelNearTol(got, want, tolerance)) return 0;
        matched += 1;
    }
    return matched;
}

/// Free a finished capture's client-side resources (frame object, shm
/// pool + buffer, memfd, mapping). Called between retries so the bounded
/// loop does not leak a memfd + mapping per attempt; the server has sent
/// ready (or the capture failed before any buffer), so destroying the
/// frame object is safe (wlr-screencopy: "can be sent at any time").
fn destroyCapture(state: *ClientState) void {
    const cap = &state.capture.?;
    cap.frame.destroy();
    // buffer is only valid once the buffer event arrived and the copy
    // was sent (setupCapture leaves it undefined).
    if (cap.sent_copy) cap.buffer.destroy();
    cap.pool.destroy();
    _ = std.os.linux.close(cap.fd);
    std.posix.munmap(cap.pixels);
}

/// Poll the display fd (bounded by the deadline) and dispatch until
/// `predicate` returns true. Returns false on timeout.
fn waitForEvent(
    comptime predicate: fn (*const ClientState) bool,
    state: *const ClientState,
    ms: i64,
) !bool {
    const display = state.display;
    const start_ms = nowMs();
    const deadline = start_ms + ms;
    while (!predicate(state)) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) return false;

        var pfd = [_]std.posix.pollfd{
            .{ .fd = wl.Display.getFd(display), .events = std.posix.POLL.IN, .revents = 0 },
        };
        // EINTR is retried inside std.posix.poll itself (std/posix.zig:
        // errno(.INTR) => continue), so a signal never aborts the wait
        // here; the remaining PollError members (NetworkDown /
        // SystemResources / Unexpected) are fatal and propagate.
        _ = std.posix.poll(&pfd, @intCast(remaining)) catch |err| {
            verdict("CLIENT-ERROR", "poll failed: {s}", .{@errorName(err)});
            return err;
        };
        if (pfd[0].revents & std.posix.POLL.IN != 0) {
            if (wl.Display.dispatch(display) != .SUCCESS) {
                verdict("CLIENT-ERROR", "dispatch failed", .{});
                return error.DispatchFailed;
            }
        } else if (pfd[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
            verdict("CLIENT-ERROR", "display connection closed by server", .{});
            return error.ConnectionClosed;
        }
    }
    return true;
}

/// Fill the buffer with a red gradient (ARGB8888: bytes B,G,R,A).
fn fillPattern(pixels: []align(std.heap.page_size_min) u8, w: i32, h: i32) void {
    const stride: usize = @intCast(w * 4);
    var y: usize = 0;
    while (y < @as(usize, @intCast(h))) : (y += 1) {
        const row = pixels[y * stride ..][0..stride];
        var x: usize = 0;
        while (x < @as(usize, @intCast(w))) : (x += 1) {
            const intensity: u8 = @intCast((x * 255) / @as(usize, @intCast(w)));
            const off = x * 4;
            row[off + 0] = intensity; // B
            row[off + 1] = 0; // G
            row[off + 2] = 255; // R
            row[off + 3] = 255; // A
        }
    }
}

/// Timestamped client step, to stderr.
fn step(comptime fmt: []const u8, args: anytype) void {
    const now_ms: u64 = @intCast(nowMs());
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}.{d:0>3} client] " ++ fmt ++ "\n", .{
        now_ms / 1000,
        now_ms % 1000,
    } ++ args) catch return;
    writeFd(std.posix.STDERR_FILENO, line);
}

/// Verdict line, to stdout (parseable), mirrored to stderr.
fn verdict(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    const now_ms: u64 = @intCast(nowMs());
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, tag ++ ": " ++ fmt ++ "\n", args) catch return;
    writeFd(std.posix.STDOUT_FILENO, line);
    var err_buf: [512]u8 = undefined;
    const err_line = std.fmt.bufPrint(&err_buf, "[{d}.{d:0>3} client] " ++ tag ++ ": " ++ fmt ++ "\n", .{
        now_ms / 1000,
        now_ms % 1000,
    } ++ args) catch return;
    writeFd(std.posix.STDERR_FILENO, err_line);
}

/// Best-effort raw fd write (0.16 has no std.posix.write; test client
/// output must not fail the run).
fn writeFd(fd: i32, bytes: []const u8) void {
    const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
    _ = std.os.linux.errno(rc);
}

// ---------------------------------------------------------------------------
// Buffer-transform acceptance (opt-in: WAYLAND_CLIENT_TRANSFORMS=1)
// ---------------------------------------------------------------------------
//
// What this phase proves, per case, in the pixels of a real capture:
//   1. the surface size follows the protocol — the buffer transformed by
//      wl_surface.set_buffer_transform, divided by set_buffer_scale,
//      overridden by a wp_viewport destination, else by a viewport
//      source's own size;
//   2. the pixels drawn for it are THIS CLIENT'S buffer sampled where the
//      protocol says (see expectedPixel: destination pixel centre ->
//      surface-local -> raw texel position -> crop-centre clamp -> one
//      0.5 -> bilinear), under this output's camera;
//   3. the cursor overlay still lands exactly where the pointer datum and
//      that same camera put it, so the surface-local input coordinate and
//      the displayed pixel agree under every transform;
//   4. the ordinary shm surface renders correctly again afterwards (the
//      transform, scale and viewport state are all committed back off).
//
// The fixture is asymmetric on purpose: R ramps with x, G with y, and B
// is a non-repeating hash of the pair, so a sample one texel off,
// mirrored or swapped shows a different colour rather than a plausible
// one. R and G stop at 200, so no fixture pixel can ever be read as the
// cursor's white.
//
// The camera is not what this phase tests, it is the frame the cases are
// drawn in, and WAYLAND_CAMERA picks it (pan, zoom and rot all work: the
// oracle applies the camera first). Run it with a camera that leaves the
// fixture inside the view — e.g. WAYLAND_CAMERA="cx=420,cy=300,zoom=1.5"
// on a 1280x720 output.

/// The fixture buffer's RAW dimensions: even in both directions, so every
/// buffer scale under test divides exactly, and big enough that a
/// zoomed-out view still shows a good part of it.
const fixture_width: i64 = 512;
const fixture_height: i64 = 384;

/// One committed surface state, spelled the way a client spells it:
/// `transform` is a wl_output.transform wire value, `scale` a
/// wl_surface.set_buffer_scale value, and the crop/destination the
/// wp_viewport requests in surface-local and surface pixels.
const TransformCase = struct {
    name: []const u8,
    transform: u32 = 0,
    scale: i32 = 1,
    src: ?[4]f64 = null,
    dst: ?[2]i32 = null,
};

/// The cases, in the order they run: the eight buffer transforms, then
/// buffer scale, then a crop, a stretched crop, a fractional crop origin
/// (which the protocol only allows together with a destination), and a
/// transform combined with a scale and a crop.
const transform_cases = [_]TransformCase{
    .{ .name = "normal" },
    .{ .name = "90", .transform = 1 },
    .{ .name = "180", .transform = 2 },
    .{ .name = "270", .transform = 3 },
    .{ .name = "flipped", .transform = 4 },
    .{ .name = "flipped_90", .transform = 5 },
    .{ .name = "flipped_180", .transform = 6 },
    .{ .name = "flipped_270", .transform = 7 },
    .{ .name = "scale2", .scale = 2 },
    .{ .name = "crop", .src = .{ 64, 32, 192, 128 } },
    .{ .name = "crop+dst", .src = .{ 64, 32, 192, 128 }, .dst = .{ 384, 256 } },
    .{ .name = "crop fractional origin", .src = .{ 16.5, 24.25, 192, 128 }, .dst = .{ 192, 128 } },
    .{ .name = "90+scale2+crop", .transform = 1, .scale = 2, .src = .{ 32, 16, 160, 160 }, .dst = .{ 320, 320 } },
};

/// A size in surface pixels, f64 because the arithmetic around a crop is
/// (a wp_viewport source may be fractional by protocol).
const Size = struct {
    w: f64,
    h: f64,
};

/// Whether this transform swaps the axes, which is what makes the
/// transformed buffer (and so the surface) change shape
/// (wlr_box_transform, utils/matrix.zig).
fn swapsAxes(transform: u32) bool {
    return transform == 1 or transform == 3 or transform == 5 or transform == 7;
}

/// The transform that undoes `transform` (utils/geom.zig Transform.
/// inverse): 90 and 270 swap, everything else is self-inverse.
fn inverseTransform(transform: u32) u32 {
    return switch (transform) {
        1 => 3,
        3 => 1,
        else => transform,
    };
}

/// wlr_box_transform on a FRACTIONAL box (utils/matrix.zig boxTransformF):
/// buffer space to surface space, or back with the inverse transform and
/// the TRANSFORMED size.
fn boxTransformF(box: FRect, transform: u32, width: f64, height: f64) FRect {
    var out = box;
    if (swapsAxes(transform)) {
        out.width = box.height;
        out.height = box.width;
    }
    switch (transform) {
        0 => {},
        1 => {
            out.x = height - box.y - box.height;
            out.y = box.x;
        },
        2 => {
            out.x = width - box.x - box.width;
            out.y = height - box.y - box.height;
        },
        3 => {
            out.x = box.y;
            out.y = width - box.x - box.width;
        },
        4 => {
            out.x = width - box.x - box.width;
            out.y = box.y;
        },
        5 => {
            out.x = box.y;
            out.y = box.x;
        },
        6 => {
            out.x = box.x;
            out.y = height - box.y - box.height;
        },
        else => {
            out.x = height - box.y - box.height;
            out.y = width - box.x - box.width;
        },
    }
    return out;
}

/// The surface size a case's committed state produces
/// (scene/surface_node.zig surfaceSize): the buffer box after the
/// transform, divided by the buffer scale, overridden by a viewport
/// destination, else by a viewport source's own size.
fn caseSurfaceSize(c: TransformCase) Size {
    const bw = if (swapsAxes(c.transform)) fixture_height else fixture_width;
    const bh = if (swapsAxes(c.transform)) fixture_width else fixture_height;
    const scale = @as(f64, @floatFromInt(c.scale));
    if (c.dst) |d| return .{ .w = @floatFromInt(d[0]), .h = @floatFromInt(d[1]) };
    if (c.src) |s| return .{ .w = s[2], .h = s[3] };
    return .{ .w = @as(f64, @floatFromInt(bw)) / scale, .h = @as(f64, @floatFromInt(bh)) / scale };
}

/// The raw buffer-pixel crop the renderer bounds its filter by
/// (scene/surface_node.zig rawSrcCrop through utils/matrix.zig
/// surfaceBoxToBuffer): the SURFACE-local source scaled by the buffer
/// scale and mapped back through the transform's inverse over the
/// transformed buffer size. Null when the case sets no source, which
/// means the whole texture.
fn caseRawCrop(c: TransformCase) ?FRect {
    const src = c.src orelse return null;
    const scale = @as(f64, @floatFromInt(c.scale));
    const raw = FRect{
        .x = src[0] * scale,
        .y = src[1] * scale,
        .width = src[2] * scale,
        .height = src[3] * scale,
    };
    const surface_w: f64 = if (swapsAxes(c.transform)) fixture_height else fixture_width;
    const surface_h: f64 = if (swapsAxes(c.transform)) fixture_width else fixture_height;
    return boxTransformF(raw, inverseTransform(c.transform), surface_w, surface_h);
}

/// The fixture texel at (x, y) in memory byte order (B, G, R, A). R ramps
/// with x and G with y, both under the cursor's white so a fixture pixel
/// can never be read as the overlay; B is a non-repeating hash of the
/// pair, so any shift, mirror or swap of the sample position moves B by
/// tens while a correct sample matches to the unit.
fn fixtureTexel(x: i64, y: i64) [4]u8 {
    const r: i64 = @divTrunc(x * 200, fixture_width);
    const g: i64 = @divTrunc(y * 200, fixture_height);
    const b: i64 = @mod(@divTrunc(x * 1103515245 + y * 40503 + x * y * 7919, 16), 251);
    return .{ @intCast(b), @intCast(g), @intCast(r), 255 };
}

/// Fill the fixture buffer with fixtureTexel.
fn fillFixture(pixels: []align(std.heap.page_size_min) u8, stride: usize) void {
    var y: usize = 0;
    while (y < @as(usize, @intCast(fixture_height))) : (y += 1) {
        var x: usize = 0;
        while (x < @as(usize, @intCast(fixture_width))) : (x += 1) {
            const off = y * stride + x * bytes_per_pixel;
            pixels[off..][0..bytes_per_pixel].* = fixtureTexel(@intCast(x), @intCast(y));
        }
    }
}

/// Allocate the fixture's memfd, its mapping and the wl_buffer the
/// compositor imports it as.
fn createFixtureBuffer(state: *ClientState) !void {
    const stride: usize = @intCast(fixture_width * @as(i64, bytes_per_pixel));
    const pool_size: usize = stride * @as(usize, @intCast(fixture_height));
    const fd = try std.posix.memfd_create("m1-transform-fixture", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.os.linux.close(fd);
    {
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
    }
    const pixels = try std.posix.mmap(
        null,
        pool_size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(pixels);
    fillFixture(pixels, stride);
    const pool = try state.shm.?.createPool(fd, @intCast(pool_size));
    errdefer pool.destroy();
    const buffer = try pool.createBuffer(
        0,
        @intCast(fixture_width),
        @intCast(fixture_height),
        @intCast(stride),
        .argb8888,
    );
    state.fixture_pool = pool;
    state.fixture_buffer = buffer;
    state.fixture_fd = fd;
    state.fixture_pixels = pixels;
}

/// Free the fixture's client side. The wl_buffer has already been
/// detached by the restore commit, so nothing references it here.
fn destroyFixtureBuffer(state: *ClientState) void {
    if (state.fixture_buffer) |buffer| {
        buffer.destroy();
        state.fixture_buffer = null;
    }
    if (state.fixture_pool) |pool| {
        pool.destroy();
        state.fixture_pool = null;
    }
    if (state.fixture_pixels) |pixels| {
        std.posix.munmap(pixels);
        state.fixture_pixels = null;
    }
    if (state.fixture_fd >= 0) {
        _ = std.os.linux.close(state.fixture_fd);
        state.fixture_fd = -1;
    }
}

/// Commit one case the way a client would: the transform and scale
/// requests, then the viewport's source and destination (both cleared
/// when the case names neither — wp_viewporter keeps them until told
/// otherwise), then the single commit that applies all of it. The frame
/// callback is the compositor's answer that it drew the result.
fn commitTransformCase(state: *ClientState, viewport: anytype, c: TransformCase) !void {
    const surface = state.surface.?;
    surface.setBufferTransform(@enumFromInt(c.transform));
    surface.setBufferScale(c.scale);
    if (c.src) |src| {
        viewport.setSource(
            client.wl.Fixed.fromDouble(src[0]),
            client.wl.Fixed.fromDouble(src[1]),
            client.wl.Fixed.fromDouble(src[2]),
            client.wl.Fixed.fromDouble(src[3]),
        );
    } else {
        viewport.setSource(
            client.wl.Fixed.fromInt(-1),
            client.wl.Fixed.fromInt(-1),
            client.wl.Fixed.fromInt(-1),
            client.wl.Fixed.fromInt(-1),
        );
    }
    if (c.dst) |d| {
        viewport.setDestination(d[0], d[1]);
    } else {
        viewport.setDestination(-1, -1);
    }
    state.frame_done = false;
    const frame_cb = try surface.frame();
    frame_cb.setListener(*ClientState, onFrameDone, state);
    surface.attach(state.fixture_buffer.?, 0, 0);
    surface.damage(0, 0, @intCast(fixture_width), @intCast(fixture_height));
    surface.commit();
    if (wl.Display.flush(state.display) != .SUCCESS) return error.FlushFailed;
    if (!try waitForEvent(hasFrame, state, timeout_ms)) return error.ClientTimeout;
}

/// Commit the M1 shm buffer with the plain surface state — no transform,
/// no scale, no viewport — so every phase after this one sees the flow it
/// expects.
fn commitPlainShm(state: *ClientState, viewport: anytype) !void {
    const surface = state.surface.?;
    surface.setBufferTransform(@enumFromInt(0));
    surface.setBufferScale(1);
    viewport.setSource(
        client.wl.Fixed.fromInt(-1),
        client.wl.Fixed.fromInt(-1),
        client.wl.Fixed.fromInt(-1),
        client.wl.Fixed.fromInt(-1),
    );
    viewport.setDestination(-1, -1);
    state.frame_done = false;
    const frame_cb = try surface.frame();
    frame_cb.setListener(*ClientState, onFrameDone, state);
    surface.attach(state.buffer.?, 0, 0);
    surface.damage(0, 0, state.surface_width, state.surface_height);
    surface.commit();
    if (wl.Display.flush(state.display) != .SUCCESS) return error.FlushFailed;
    if (!try waitForEvent(hasFrame, state, timeout_ms)) return error.ClientTimeout;
}

/// Verify one committed case: the surface's pixels against this client's
/// own texels through the documented sampling chain, and the cursor
/// overlay at the position the pointer datum and the camera put it.
/// Returns how many probes matched; the caller prints the per-case
/// verdict from it.
fn verifyTransformCase(
    state: *ClientState,
    cap: *const CaptureState,
    cam: ViewCamera,
    cursor: ?CursorBox,
    c: TransformCase,
) !usize {
    if (cap.width != @as(u32, @intCast(state.surface_width)) or
        cap.height != @as(u32, @intCast(state.surface_height)))
    {
        verdict("CLIENT-TRANSFORM-ERROR", "{s}: capture {d}x{d} is not this output's mode {d}x{d}", .{
            c.name, cap.width, cap.height, state.surface_width, state.surface_height,
        });
        return error.CaptureSizeBad;
    }
    const size = caseSurfaceSize(c);
    const texels = Texels{
        .width = fixture_width,
        .height = fixture_height,
        .crop = caseRawCrop(c) orelse wholeCrop(fixture_width, fixture_height),
        .kind = .fixture,
    };
    const matched = try verifySurfacePixels(
        cap,
        cam,
        size.w,
        size.h,
        c.transform,
        texels,
        cursor,
        sampling_tolerance,
        "CLIENT-TRANSFORM-ERROR",
    );
    if (cursor) |box| {
        if (box.wholeInside(cap.width, cap.height)) {
            verifyCursorOverlay(cap, box, "CLIENT-TRANSFORM-ERROR") catch |err| {
                verdict("CLIENT-TRANSFORM-ERROR", "{s}: the cursor left the pixel the surface-local pointer coordinate maps to ({s})", .{
                    c.name, @errorName(err),
                });
                return err;
            };
        } else {
            step("{s}: the cursor box is clipped by this view's edge (the first capture covered it)", .{c.name});
        }
    }
    return matched;
}

/// The whole acceptance. It runs after the synth wheel notch has landed,
/// so every case is drawn in one known camera per output, and it leaves
/// the plain shm surface committed so the phases below see the M1 flow.
fn runTransformQualification(state: *ClientState) !void {
    step("buffer-transform acceptance: on", .{});
    const mode = state.output_mode orelse return error.OutputModeMissing;
    const viewporter = state.viewporter orelse return error.ViewporterMissing;
    // One wp_viewport per wl_surface is all the protocol allows, so every
    // case below updates this one object rather than making a new one.
    const viewport = try viewporter.getViewport(state.surface.?);
    try createFixtureBuffer(state);
    defer destroyFixtureBuffer(state);
    step("fixture {d}x{d} created, wp_viewport bound to the surface", .{ fixture_width, fixture_height });

    const cam = settledCamera(state, mode);
    step("cases run at camera zoom {d:.2} on a {d}x{d} output", .{ cam.zoom, mode.width, mode.height });

    var index: usize = 0;
    while (index < transform_cases.len) : (index += 1) {
        const c = transform_cases[index];
        state.motion_mark = state.motions;
        try commitTransformCase(state, viewport, c);
        if (!try waitForEvent(hasMotionMoved, state, timeout_ms)) {
            verdict("CLIENT-TRANSFORM-ERROR", "{s}: no fresh pointer motion after commit; start the server with WAYLAND_SYNTH_INPUT=2", .{c.name});
            return error.InputEventsMissing;
        }
        const size = caseSurfaceSize(c);
        if (!state.pointer_focused or
            !(state.pointer_surface_x >= 0 and state.pointer_surface_x < size.w and
                state.pointer_surface_y >= 0 and state.pointer_surface_y < size.h))
        {
            verdict("CLIENT-TRANSFORM-ERROR", "{s}: pointer ({d:.3},{d:.3}) is not on this {d:.0}x{d:.0} surface", .{
                c.name, state.pointer_surface_x, state.pointer_surface_y, size.w, size.h,
            });
            return error.InputCoordinatesBad;
        }
        const cursor = derivedCursorBox(state, mode) orelse return error.InputCoordinatesBad;
        const matched = blk: {
            const cap = try captureShmOnce(state, "CLIENT-TRANSFORM-ERROR");
            defer destroyCapture(state);
            break :blk try verifyTransformCase(state, cap, cam, cursor, c);
        };
        verdict("CLIENT-TRANSFORM", "{s}: {d} probes match (surface {d:.0}x{d:.0}, transform {d}, scale {d})", .{
            c.name, matched, size.w, size.h, c.transform, c.scale,
        });
    }

    // The plain surface must come back exactly as the first capture found
    // it, cursor included: the round trip through thirteen other surface
    // states cannot have left anything behind.
    state.motion_mark = state.motions;
    try commitPlainShm(state, viewport);
    if (!try waitForEvent(hasMotionMoved, state, timeout_ms)) return error.InputEventsMissing;
    const cursor = derivedCursorBox(state, mode) orelse return error.InputCoordinatesBad;
    const restored = blk: {
        const cap = try captureShmOnce(state, "CLIENT-TRANSFORM-ERROR");
        defer destroyCapture(state);
        const matched = verifySurfacePixels(
            cap,
            cam,
            @floatFromInt(state.surface_width),
            @floatFromInt(state.surface_height),
            0,
            gradientTexels(state),
            cursor,
            pixman_tolerance,
            "CLIENT-TRANSFORM-ERROR",
        ) catch |err| {
            verdict("CLIENT-TRANSFORM-ERROR", "the plain shm surface did not come back ({s})", .{@errorName(err)});
            return err;
        };
        verifyCursorOverlay(cap, cursor, "CLIENT-TRANSFORM-ERROR") catch |err| {
            verdict("CLIENT-TRANSFORM-ERROR", "the cursor did not come back after the round trip ({s})", .{@errorName(err)});
            return err;
        };
        break :blk matched;
    };
    verdict("CLIENT-TRANSFORM-OK", "all {d} transform/scale/viewport cases verified, plain shm surface restored ({d} gradient probes + cursor)", .{
        transform_cases.len, restored,
    });
}

// ---------------------------------------------------------------------------
// DMA-BUF qualification (opt-in: WAYLAND_CLIENT_DMABUF=1)
// ---------------------------------------------------------------------------
//
// What this phase proves, in the order it proves it:
//   1. the compositor advertises zwp_linux_dmabuf_v1, with a
//      (format, modifier) pair this client can actually allocate;
//   2. a DMA-BUF the CLIENT allocated with GBM is imported: the
//      zwp_linux_buffer_params_v1.created event carries a wl_buffer the
//      compositor built from our fd;
//   3. attaching that buffer and committing is really PRESENTED: both
//      the frame callback and a wp_presentation_feedback.presented
//      event arrive;
//   4. the composited output carries the client's pixels: a screencopy
//      whose DESTINATION is itself a real DMA-BUF reads the pattern back;
//   5. detaching, destroying that wl_buffer and importing a second
//      DMA-BUF with the inverted pattern is visible too, so no stale
//      buffer survives the ownership churn;
//   6. the shm buffer goes back and the gradient AND the cursor verify
//      again, so the compositor is still correct after the DMA-BUF round
//      trip.
//
// Every check reads real pixels out of a real DMA-BUF. Nothing here
// fabricates a buffer: no DRM node, no GBM device, a missing global, a
// refused import, a missed presentation or a wrong pixel is reported as
// CLIENT-DMABUF-ERROR with a nonzero exit. The harness keys on the
// CLIENT-DMABUF-* verdict lines, so a run that skipped a step cannot look
// like a run that passed it.

/// DRM_FORMAT_XRGB8888 / DRM_FORMAT_ARGB8888 as fourcc character packs:
/// the gbm shim deliberately does not include drm_fourcc.h, so the two
/// codes this qualification can allocate are spelled out here exactly as
/// buffers/dmabuf.zig spells them.
const drm_format_xrgb8888: u32 = 0x34325258;
const drm_format_argb8888: u32 = 0x34325241;
/// DRM_FORMAT_MOD_LINEAR (drm_fourcc.h): no tiling, no compression. The
/// only modifier this compositor advertises (backend/drm.zig's
/// queryGbmFormats) and the only one it will validate a create against.
const drm_format_mod_linear: u64 = 0;

/// One advertised (format, modifier) pair. A `create` is validated
/// against exactly these, so a client that guesses is wrong by protocol,
/// not by luck.
const FormatPair = struct {
    format: u32,
    modifier: u64,
};

/// zwp_linux_dmabuf_feedback_v1.format_table: a tightly packed array of
/// 16-byte {format: u32, pad: u32, modifier: u64} entries in native
/// endianness (linux-dmabuf-v1.xml, format_table event). Bounded so the
/// client needs no allocator: a table larger than this is reported, not
/// truncated.
const table_entry_size: usize = 16;
const max_format_pairs: usize = 64;

/// The format table one feedback object handed over, read at the
/// format_table event (the fd belongs to the client from that event).
const FormatTable = struct {
    pairs: [max_format_pairs]FormatPair,
    len: usize,
};

/// Edge length of one qualification pattern cell, in buffer pixels. A
/// cell is flat, so the renderer's bilinear sample at a cell centre is
/// the cell colour, while a wrong camera, a stale buffer or a sheared
/// stride all move the colour read there.
const pattern_cell: u32 = 64;

/// How many sample points a capture must yield before its verdict means
/// anything. The pattern cells are 64 buffer pixels and a capture shows
/// only what the camera's visible world rect covers, so a camera model
/// that does not describe what the client is looking at leaves fewer than
/// this; anything under it is reported instead of scored.
const min_qual_samples: usize = 8;

/// The server's synth wheel zoom step per notch (server/main.zig
/// onSeatAxis), the same rule verifyZoomLanding derives: one notch has
/// landed by the time the phases below run, so every capture of them runs
/// at this zoom. settledCamera applies it.
const synth_zoom_step: f64 = 1.25;

/// One output's camera in a phase that runs after the synth wheel notch
/// has landed (verifyZoomLanding has observed it): this output's own
/// camera with that one zoom step applied. Every phase after it uses this,
/// so a capture is always checked against the camera it was taken under.
fn settledCamera(state: *const ClientState, mode: OutputMode) ViewCamera {
    var cam = ViewCamera.forOutput(state.camera_env, mode);
    cam.zoom *= synth_zoom_step;
    return cam;
}

/// A DMA-BUF screencopy that produced no verifiable frame, and why.
const DmabufFailure = enum {
    /// The compositor answered `failed`.
    server,
    /// No linux_dmabuf event: this frame never offered a DMA-BUF type.
    not_offered,
    /// The destination object could not be allocated on the client's GBM
    /// device.
    alloc,
    /// The compositor would not import the destination (params failed,
    /// or no created event at all).
    params,
    /// Flushing the copy request failed.
    flush,
};

/// One screencopy frame whose destination is a real DMA-BUF.
const DmabufCapture = struct {
    frame: *client.zwlr.ScreencopyFrameV1,
    /// What the compositor said it accepts, from its linux_dmabuf event.
    /// The fourcc is the one thing a client cannot guess: the copy fails
    /// the frame (rather than erroring) when the destination does not
    /// carry it.
    offered: ?struct { format: u32, width: u32, height: u32 } = null,
    /// The wl_buffer the compositor built from the client's object.
    buffer: ?*wl.Buffer = null,
    ready: bool = false,
    failed: bool = false,
    failure: DmabufFailure = .server,
};

/// How many sample points a captured frame had, and how many carried the
/// expected pattern colour.
const PatternMatch = struct {
    total: usize,
    matched: usize,
};

/// One client-allocated DMA-BUF: a GBM buffer object plus the dma-buf
/// fd handed to the compositor. The object outlives the wl_buffer on
/// purpose: the compositor holds its own reference to the same memory
/// through its import, so destroying the wl_buffer and importing again
/// is an ownership test rather than a use-after-free.
const QualBo = struct {
    bo: *gbm_c.gbm_bo,
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    format: u32,
    modifier: u64,
    stride: u32,
    offset: u32,
    /// The live gbm_bo_map mapping, if any.
    map_data: ?*anyopaque = null,
    map_stride: usize = 0,

    const OpenError = error{
        BoAllocFailed,
        BoFdFailed,
        ModifierNotLinear,
        StrideTooSmall,
        PlaneCountBad,
    };

    /// Allocate a single-plane linear object on `device` and export its
    /// dma-buf. Nothing here is a fallback the caller may ignore: every
    /// way this can fail is an error out.
    fn create(device: *gbm_c.gbm_device, width: u32, height: u32, format: u32) OpenError!QualBo {
        // SCANOUT | RENDERING | LINEAR first: exactly what the
        // compositor's importer asks for (buffers/dmabuf.zig's
        // import_usage), which a GBM backend that checks the source
        // object's usage requires. The LINEAR-only allocation is the one
        // any client can make; which of the two the driver took is
        // logged rather than assumed.
        const usages = [_]u32{
            gbm_c.GBM_BO_USE_SCANOUT | gbm_c.GBM_BO_USE_RENDERING | gbm_c.GBM_BO_USE_LINEAR,
            gbm_c.GBM_BO_USE_LINEAR,
        };
        var object: ?*gbm_c.gbm_bo = null;
        var usage_index: usize = 0;
        while (usage_index < usages.len) : (usage_index += 1) {
            object = gbm_c.gbm_bo_create(device, width, height, format, usages[usage_index]);
            if (object != null) {
                step("gbm_bo_create {d}x{d} fmt=0x{x} usage=0x{x}", .{
                    width, height, format, usages[usage_index],
                });
                break;
            }
        }
        const bo = object orelse return error.BoAllocFailed;
        errdefer gbm_c.gbm_bo_destroy(bo);
        if (gbm_c.gbm_bo_get_plane_count(bo) != 1) return error.PlaneCountBad;
        // The compositor validates the (format, modifier) pair against
        // what it advertised, so a layout the driver picked on its own is
        // reported here instead of being sent as a create that comes back
        // invalid_format.
        const modifier = gbm_c.gbm_bo_get_modifier(bo);
        if (modifier != drm_format_mod_linear) return error.ModifierNotLinear;
        const fd = gbm_c.gbm_bo_get_fd_for_plane(bo, 0);
        if (fd < 0) return error.BoFdFailed;
        // The stride the client reports must cover a row of the frame:
        // screencopy walks the destination with it.
        const stride = gbm_c.gbm_bo_get_stride_for_plane(bo, 0);
        if (@as(u64, stride) < @as(u64, width) * @as(u64, bytes_per_pixel)) return error.StrideTooSmall;
        return .{
            .bo = bo,
            .fd = fd,
            .width = width,
            .height = height,
            .format = format,
            .modifier = modifier,
            .stride = stride,
            .offset = gbm_c.gbm_bo_get_offset(bo, 0),
        };
    }

    /// Map the whole object for the CPU: `write` for filling the source
    /// pattern, false for reading a composited frame back out of a
    /// screencopy destination. Returns `map_stride` rows of pixels.
    fn map(self: *QualBo, write: bool) error{BoMapFailed}![]u8 {
        std.debug.assert(self.map_data == null);
        var stride_out: u32 = 0;
        var map_data: ?*anyopaque = null;
        const ptr = gbm_c.gbm_bo_map(
            self.bo,
            0,
            0,
            self.width,
            self.height,
            @intCast(if (write) gbm_c.GBM_BO_TRANSFER_WRITE else gbm_c.GBM_BO_TRANSFER_READ),
            &stride_out,
            &map_data,
        ) orelse return error.BoMapFailed;
        self.map_data = map_data;
        self.map_stride = stride_out;
        const pixels: [*]u8 = @ptrCast(ptr);
        return pixels[0 .. @as(usize, stride_out) * self.height];
    }

    /// Hand the mapping back. gbm_bo_unmap is also where a staged
    /// mapping is copied into the object, so this must run after the
    /// writes (buffers/dmabuf.zig, endWrite).
    fn unmap(self: *QualBo) void {
        if (self.map_data) |token| {
            gbm_c.gbm_bo_unmap(self.bo, token);
            self.map_data = null;
            self.map_stride = 0;
        }
    }

    /// Release the client side: mapping, dma-buf fd, object.
    fn deinit(self: *QualBo) void {
        self.unmap();
        gbm_c.gbm_bo_destroy(self.bo);
        _ = std.os.linux.close(self.fd);
        self.bo = undefined;
        self.fd = -1;
    }
};

/// The client's own GBM device, on a DRM node it discovered rather than
/// one it assumed (a host whose card is card1 must still qualify).
const QualGbm = struct {
    fd: std.posix.fd_t,
    device: *gbm_c.gbm_device,
    /// The node path, owned: the discovery below fills its own scratch
    /// table, and a slice into that would dangle the moment it returns.
    node: [max_drm_path]u8 = undefined,
    node_len: usize = 0,

    fn path(self: *const QualGbm) []const u8 {
        return self.node[0..self.node_len];
    }

    fn backendName(self: QualGbm) []const u8 {
        return std.mem.span(gbm_c.gbm_device_get_backend_name(self.device));
    }

    fn deinit(self: QualGbm) void {
        gbm_c.gbm_device_destroy(self.device);
        _ = std.os.linux.close(self.fd);
    }
};

/// The (format, modifier) the client allocates its own buffers with: the
/// advertised pair that is ARGB8888 with the linear modifier, else
/// XRGB8888 with it. ARGB8888 is preferred because its alpha byte
/// survives the round trip, so a lost or reordered plane shows up in the
/// verified pixels instead of hiding behind an ignored byte.
///
/// An advertised set with neither is an error: the qualification must not
/// quietly allocate something the compositor never promised to import.
fn pickSourceFormat(state: *const ClientState) error{NoUsableFormat}!FormatPair {
    var index: usize = 0;
    var xrgb: ?FormatPair = null;
    while (index < state.formats_len) : (index += 1) {
        const pair = state.formats[index];
        if (pair.modifier != drm_format_mod_linear) continue;
        if (pair.format == drm_format_argb8888) return pair;
        if (pair.format == drm_format_xrgb8888) xrgb = pair;
    }
    return xrgb orelse error.NoUsableFormat;
}

/// The advertised pairs, from wherever this version of the protocol
/// carries them: the format table a v4+ feedback object hands over, or
/// the legacy format/modifier events below v4 (both are deprecated from
/// v4 on precisely because the table replaced them).
fn collectAdvertisedFormats(state: *ClientState) !void {
    const linux = state.dmabuf.?;
    state.formats_len = 0;
    state.format_table = null;
    if (state.dmabuf_version >= client.zwp.LinuxDmabufV1.get_default_feedback_since_version) {
        state.feedback_done = false;
        const feedback = try linux.getDefaultFeedback();
        feedback.setListener(*ClientState, onDmabufFeedback, state);
        _ = feedback.getId();
        if (wl.Display.flush(state.display) != .SUCCESS) return error.FlushFailed;
        if (!try waitForEvent(hasFeedback, state, timeout_ms)) return error.ClientTimeout;
        const table = state.format_table orelse return error.FormatTableMissing;
        state.formats = table.pairs;
        state.formats_len = table.len;
        if (state.formats_len == 0) return error.NoFormatsAdvertised;
        return;
    }
    // v3 and below: one event per pair, sent at bind time and already
    // dispatched by the registry roundtrip in main.
    if (state.formats_len == 0) return error.NoFormatsAdvertised;
}

/// Read the feedback format table. The fd belongs to the client from the
/// event that carried it and is closed here; the compositor never mutates
/// the table, so reading it once is enough.
fn readFormatTable(state: *ClientState, fd: i32, size: u32) void {
    defer _ = std.os.linux.close(fd);
    const wanted: usize = size;
    if (wanted == 0 or wanted % table_entry_size != 0 or
        wanted > max_format_pairs * table_entry_size)
    {
        step("format table of {d} bytes rejected (not whole pairs, or too many)", .{size});
        return;
    }
    var raw: [max_format_pairs * table_entry_size]u8 = undefined;
    const got = readExact(fd, raw[0..wanted]) orelse {
        step("format table read failed", .{});
        return;
    };
    var table: FormatTable = .{ .pairs = undefined, .len = 0 };
    var at: usize = 0;
    while (at + table_entry_size <= got.len) : (at += table_entry_size) {
        const entry = got[at..][0..table_entry_size];
        table.pairs[table.len] = .{
            .format = std.mem.readInt(u32, entry[0..4], .native),
            .modifier = std.mem.readInt(u64, entry[8..16], .native),
        };
        table.len += 1;
    }
    step("format table: {d} pairs", .{table.len});
    state.format_table = table;
}

/// Read exactly `buf.len` bytes, or null on an error or a short read. A
/// short table must not be parsed as if it were the whole thing.
fn readExact(fd: std.posix.fd_t, buf: []u8) ?[]u8 {
    var done: usize = 0;
    while (done < buf.len) {
        const n = std.os.linux.read(fd, buf.ptr + done, buf.len - done);
        if (std.os.linux.errno(n) != .SUCCESS) return null;
        if (n <= 0) break;
        done += @intCast(n);
    }
    return buf[0..done];
}

/// Open a GBM device for the qualification. The DRM nodes are read from
/// /dev/dri (render nodes first: that is what a client allocates on, cf.
/// buffers/dmabuf.zig's hardware test) so a host whose card is not card0
/// is qualified rather than silently skipped; WAYLAND_DRM_DEVICE, the
/// override the server itself honours, wins when it is set. Every node
/// refused on the way is logged, so "no GBM device" can never be mistaken
/// for "the first node worked".
fn openQualGbm(state: *ClientState) !QualGbm {
    var nodes: [max_drm_nodes][max_drm_path]u8 = undefined;
    var lengths: [max_drm_nodes]usize = undefined;
    var count: usize = 0;

    if (state.drm_device) |explicit| {
        if (explicit.len < max_drm_path) {
            @memcpy(nodes[0][0..explicit.len], explicit);
            lengths[0] = explicit.len;
            count = 1;
            step("drm node from WAYLAND_DRM_DEVICE: {s}", .{explicit});
        } else {
            step("WAYLAND_DRM_DEVICE path too long ({d} bytes), ignored", .{explicit.len});
        }
    } else {
        // Two passes so a render node always wins over a primary node.
        collectDrmNodes("renderD", &nodes, &lengths, &count);
        collectDrmNodes("card", &nodes, &lengths, &count);
    }

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const path = nodes[index][0..lengths[index]];
        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            path,
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        ) catch |err| {
            step("drm node {s}: open failed ({s})", .{ path, @errorName(err) });
            continue;
        };
        const device = gbm_c.gbm_create_device(fd) orelse {
            step("drm node {s}: gbm_create_device returned null", .{path});
            _ = std.os.linux.close(fd);
            continue;
        };
        if (gbm_c.gbm_device_get_format_modifier_plane_count(
            device,
            drm_format_argb8888,
            drm_format_mod_linear,
        ) < 1) {
            step("drm node {s}: no linear ARGB8888 support", .{path});
            gbm_c.gbm_device_destroy(device);
            _ = std.os.linux.close(fd);
            continue;
        }
        var opened: QualGbm = .{ .fd = fd, .device = device };
        @memcpy(opened.node[0..path.len], path);
        opened.node_len = path.len;
        return opened;
    }
    return error.NoGbmDevice;
}

/// Append every /dev/dri entry whose name starts with `prefix`, as a full
/// path. The directory is read rather than guessed, so a host with a
/// second graphics card qualifies on that one too.
fn collectDrmNodes(
    prefix: []const u8,
    nodes: *[max_drm_nodes][max_drm_path]u8,
    lengths: *[max_drm_nodes]usize,
    count: *usize,
) void {
    var dir = std.Io.Dir.openDirAbsolute(client_io, "/dev/dri", .{ .iterate = true }) catch {
        step("/dev/dri is not readable", .{});
        return;
    };
    defer dir.close(client_io);
    var it = dir.iterate();
    while (it.next(client_io) catch null) |entry| {
        if (count.* >= nodes.len) return;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const at: usize = drm_dir_prefix.len;
        if (at + entry.name.len > nodes[count.*].len) continue;
        @memcpy(nodes[count.*][0..at], drm_dir_prefix);
        @memcpy(nodes[count.*][at..][0..entry.name.len], entry.name);
        lengths[count.*] = at + entry.name.len;
        count.* += 1;
    }
}

/// Import `bo` through zwp_linux_dmabuf_v1 and wait for the compositor's
/// answer: `created` carries the wl_buffer it built from our fd,
/// `failed` (or nothing at all) means it will not take it. One params
/// object is ever in flight, so the pending answer lives on the state.
fn importAsBuffer(state: *ClientState, bo: *const QualBo) !*wl.Buffer {
    const linux = state.dmabuf.?;
    state.created = null;
    state.create_failed = false;
    const params = try linux.createParams();
    params.setListener(*ClientState, onParamsEvent, state);
    params.add(
        bo.fd,
        0,
        bo.offset,
        bo.stride,
        @intCast(bo.modifier >> 32),
        @truncate(bo.modifier),
    );
    params.create(@intCast(bo.width), @intCast(bo.height), bo.format, .{});
    _ = params.getId();
    if (wl.Display.flush(state.display) != .SUCCESS) return error.FlushFailed;
    if (!try waitForEvent(hasCreateDone, state, timeout_ms)) return error.ClientTimeout;
    // The XML says the params object is done once the buffer exists.
    params.destroy();
    if (state.create_failed) return error.ImportRejected;
    const buffer = state.created orelse return error.ImportRejected;
    state.created = null;
    buffer.setListener(*ClientState, onBufferEvent, state);
    return buffer;
}

/// Commit `buffer` (null detaches) as the surface content and wait for
/// both signals a client can observe: the frame callback, which says the
/// compositor finished the commit, and a wp_presentation_feedback event,
/// which says the frame reached the output. `want_presented` is false for
/// the detach commit, where the superseded update legitimately reports
/// discarded instead of presented.
fn commitAndWait(state: *ClientState, buffer: ?*wl.Buffer, want_presented: bool) !void {
    const surface = state.surface.?;
    const presentation = state.presentation.?;
    state.frame_done = false;
    state.presented_mark = state.presented;
    const frame_cb = try surface.frame();
    frame_cb.setListener(*ClientState, onFrameDone, state);
    // Asked for BEFORE the commit, so it covers the update this commit
    // submits (wp_presentation: "the current content submission").
    const feedback = try presentation.feedback(surface);
    feedback.setListener(*ClientState, onPresentationFeedback, state);
    surface.attach(buffer, 0, 0);
    surface.damage(0, 0, state.surface_width, state.surface_height);
    surface.commit();
    if (wl.Display.flush(state.display) != .SUCCESS) return error.FlushFailed;
    if (!try waitForEvent(hasFrame, state, timeout_ms)) return error.ClientTimeout;
    if (!want_presented) return;
    if (!try waitForEvent(hasPresented, state, timeout_ms)) return error.PresentationTimeout;
}

/// Fill `bo` with the qualification pattern for `variant`. Variant 0 is
/// the base pattern, variant 1 the same cell layout with a red channel no
/// base pattern can produce, so "the second buffer is on screen" cannot be
/// confused with "the first one is still on screen".
fn fillQualPattern(bo: *QualBo, variant: u8) !void {
    const pixels = try bo.map(true);
    defer bo.unmap();
    const stride = bo.map_stride;
    var y: usize = 0;
    while (y < bo.height) : (y += 1) {
        var x: usize = 0;
        while (x < bo.width) : (x += 1) {
            const color = qualPatternColor(@intCast(x), @intCast(y), variant);
            const at = y * stride + x * bytes_per_pixel;
            pixels[at + 0] = color[0];
            pixels[at + 1] = color[1];
            pixels[at + 2] = color[2];
            pixels[at + 3] = color[3];
        }
    }
}

/// The pattern colour at buffer pixel (x, y): a function of the CELL it
/// falls in, so a shifted camera, a stale buffer or a sheared stride all
/// change the colour read at a sample point. Bytes are B, G, R, A —
/// ARGB8888 in memory, the order verifyCapturePixels reads.
fn qualPatternColor(x: u32, y: u32, variant: u8) [4]u8 {
    const cell_x = x / pattern_cell;
    const cell_y = y / pattern_cell;
    const alternating: u8 = @intCast((cell_x + cell_y) % 2);
    const red: u8 = if (variant == 0) 128 + alternating * 127 else 1 + alternating * 20;
    return .{
        @truncate(cell_x * 17),
        @truncate(cell_y * 29),
        red,
        255,
    };
}

/// Compare a captured frame with the pattern the client attached.
///
/// Every sample point is a cell centre projected through THIS output's
/// camera — the same mapping the gradient checks use, derived from
/// WAYLAND_CAMERA and that output's announced mode — so a wrong camera, a
/// stale buffer or a wrong stride all show up here. Sample points that
/// land on the cursor overlay are skipped, using the cursor box derived
/// from the pointer datum rather than an assumed pointer position. The
/// first mismatch is reported; the counts come back so the caller can tell
/// "all of it" from "none of it".
fn verifyPattern(
    pixels: []const u8,
    stride: usize,
    state: *const ClientState,
    cam: ViewCamera,
    cursor: ?CursorBox,
    variant: u8,
) error{TooFewSamples}!PatternMatch {
    const width: f64 = cam.screen_w;
    const height: f64 = cam.screen_h;
    const cells_x = (@as(u32, @intCast(state.surface_width)) + pattern_cell - 1) / pattern_cell;
    const cells_y = (@as(u32, @intCast(state.surface_height)) + pattern_cell - 1) / pattern_cell;
    var result: PatternMatch = .{ .total = 0, .matched = 0 };
    var reported = false;
    var cell_x: u32 = 0;
    while (cell_x < cells_x) : (cell_x += 1) {
        var cell_y: u32 = 0;
        while (cell_y < cells_y) : (cell_y += 1) {
            const buffer_x = cell_x * pattern_cell + pattern_cell / 2;
            const buffer_y = cell_y * pattern_cell + pattern_cell / 2;
            if (@as(f64, @floatFromInt(buffer_x)) >= width) continue;
            if (@as(f64, @floatFromInt(buffer_y)) >= height) continue;
            // The surface sits at this view's own origin, so a buffer
            // coordinate is the world coordinate this camera maps.
            const at = cam.worldToScreen(@floatFromInt(buffer_x), @floatFromInt(buffer_y));
            // Bounded before narrowing, and written so a NaN (a camera
            // this client cannot model) drops the sample point instead of
            // trapping the float -> int conversion.
            if (!(at.x >= 2 and at.y >= 2)) continue;
            if (!(at.x < width - 2 and at.y < height - 2)) continue;
            const px: i64 = @intFromFloat(@floor(at.x));
            const py: i64 = @intFromFloat(@floor(at.y));
            // Inside the cursor overlay the capture shows the cursor,
            // whatever the surface underneath holds.
            if (cursor) |box| {
                if (box.covers(px, py)) continue;
            }
            const at_bytes = @as(usize, @intCast(py)) * stride +
                @as(usize, @intCast(px)) * bytes_per_pixel;
            if (at_bytes + bytes_per_pixel > pixels.len) continue;
            result.total += 1;
            const want = qualPatternColor(buffer_x, buffer_y, variant);
            const got = pxAtBytes(pixels, stride, @intCast(px), @intCast(py));
            if (pixelNear(got, want)) {
                result.matched += 1;
            } else if (!reported) {
                reported = true;
                verdict("CLIENT-DMABUF-PIXELS", "view ({d},{d}) = {d},{d},{d},{d}, expected {d},{d},{d},{d}", .{
                    px, py, got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3],
                });
            }
        }
    }
    if (result.total < min_qual_samples) return error.TooFewSamples;
    return result;
}

/// Per-channel comparison with a tolerance. The exact sample lands on a
/// flat cell centre, so the tolerance only absorbs the sub-pixel rounding
/// of the camera arithmetic; a wrong buffer or a wrong camera moves a
/// channel by tens.
fn pixelNearTol(got: [4]u8, want: [4]u8, tolerance: u8) bool {
    for (got, want) |a, b| {
        const diff = if (a > b) a - b else b - a;
        if (diff > tolerance) return false;
    }
    return true;
}

/// The DMA-BUF qualification's own tolerance (see pixelNearTol).
fn pixelNear(got: [4]u8, want: [4]u8) bool {
    return pixelNearTol(got, want, 2);
}

/// The BGRA bytes at (x, y) of a framebuffer with this stride.
fn pxAtBytes(pixels: []const u8, stride: usize, x: usize, y: usize) [4]u8 {
    const at = y * stride + x * bytes_per_pixel;
    return .{ pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3] };
}


/// How many /dev/dri entries the node discovery will consider, and how
/// long a path may be. A host with more nodes than this still
/// qualifies: render nodes are collected first.
const max_drm_nodes = 16;
const max_drm_path = 64;
const drm_dir_prefix = "/dev/dri/";



/// Read a boolean-ish environment flag: "1", "true", "yes" and "on" are
/// true, everything else (including an unset variable) is false. The
/// qualification is opt-in, so anything ambiguous stays off rather than
/// turning a run into a hardware demand nobody asked for.
fn envFlag(map: *std.process.Environ.Map, name: []const u8) bool {
    const value = map.get(name) orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on");
}

/// The DMA-BUF qualification. Runs after the shm flow (and after the
/// zoom has landed, so the camera is stable), and fails the run on
/// anything the compositor, the driver or the hardware cannot do: this
/// mode exists to prove the real path, not to be forgiving about it.
fn runDmabufQualification(state: *ClientState) !void {
    step("dmabuf qualification: on", .{});
    if (state.dmabuf == null) return qualFail(
        "CLIENT-DMABUF-ERROR",
        "no zwp_linux_dmabuf_v1 global: the compositor has no dma-buf import device",
        .{},
    );
    if (state.presentation == null) return qualFail(
        "CLIENT-DMABUF-ERROR",
        "no wp_presentation global: presentation cannot be observed",
        .{},
    );

    collectAdvertisedFormats(state) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "no advertised (format, modifier) pairs: {s}", .{@errorName(err)});
        return err;
    };
    const source = pickSourceFormat(state) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "no usable advertised format (want ARGB8888 or XRGB8888, linear): {s}", .{
            @errorName(err),
        });
        return err;
    };
    step("source format 0x{x} modifier 0x{x} (of {d} advertised pairs)", .{
        source.format, source.modifier, state.formats_len,
    });

    var gbm = openQualGbm(state) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "no GBM device on any DRM node: {s}", .{@errorName(err)});
        return err;
    };
    defer gbm.deinit();
    state.gbm = gbm.device;
    step("gbm node {s} backend {s}", .{ gbm.path(), gbm.backendName() });

    const width: u32 = @intCast(state.surface_width);
    const height: u32 = @intCast(state.surface_height);
    // The zoom has already landed once (verifyZoomLanding ran before
    // this), so every capture of this phase runs at that camera: this
    // output's own camera with the notch's zoom step applied. The cursor
    // box comes from the same derivation the shm checks use, so a sample
    // point that lands on the overlay is skipped wherever it is.
    const mode = state.output_mode orelse return error.OutputModeMissing;
    const cam = settledCamera(state, mode);
    const cursor = derivedCursorBox(state, mode);

    // --- buffer A: allocate, import, attach, present ---------------------
    var bo_a = QualBo.create(gbm.device, width, height, source.format) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "gbm allocation of the source buffer failed: {s}", .{@errorName(err)});
        return err;
    };
    defer bo_a.deinit();
    fillQualPattern(&bo_a, 0) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "writing the source pattern failed: {s}", .{@errorName(err)});
        return err;
    };
    const buffer_a = importAsBuffer(state, &bo_a) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "the compositor refused the client's dma-buf: {s}", .{@errorName(err)});
        return err;
    };
    const buffer_a_id = buffer_a.getId();
    step("imported {d}x{d} fmt=0x{x} dma-buf as wl_buffer {d}", .{
        width, height, source.format, buffer_a_id,
    });
    commitAndWait(state, buffer_a, true) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "the dmabuf buffer was not presented: {s}", .{@errorName(err)});
        return err;
    };
    verdict("CLIENT-DMABUF-IMPORT", "{d}x{d} client dma-buf imported, attached and presented", .{
        width, height,
    });

    // --- the pixels are on the output, read back from a DMA-BUF ---------
    try verifyInDmabuf(state, cam, cursor, 0, "A");

    // --- detach: the pattern must disappear from the output -------------
    try detachAndVerify(state, cam, cursor, 0);

    // --- destroy the wl_buffer, then reuse the same device --------------
    buffer_a.destroy();
    step("destroyed wl_buffer {d} ({d} releases seen)", .{ buffer_a_id, state.released });

    // --- buffer B: a second import with the inverted pattern ------------
    var bo_b = QualBo.create(gbm.device, width, height, source.format) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "second gbm allocation failed: {s}", .{@errorName(err)});
        return err;
    };
    defer bo_b.deinit();
    fillQualPattern(&bo_b, 1) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "writing the second pattern failed: {s}", .{@errorName(err)});
        return err;
    };
    const buffer_b = importAsBuffer(state, &bo_b) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "the compositor refused the second dma-buf: {s}", .{@errorName(err)});
        return err;
    };
    defer buffer_b.destroy();
    commitAndWait(state, buffer_b, true) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "the second dmabuf buffer was not presented: {s}", .{@errorName(err)});
        return err;
    };
    verdict("CLIENT-DMABUF-REUSE", "second dma-buf imported after the first was destroyed", .{});
    try verifyInDmabuf(state, cam, cursor, 1, "B");

    // --- the compositor is still correct afterwards ---------------------
    try restoreShm(state, cam, cursor);
    verdict("CLIENT-DMABUF-OK", "dma-buf qualified: import, present, capture, detach, destroy, reuse", .{});
}

/// Copy the whole output into a destination that is itself a real
/// DMA-BUF and verify the pattern in it.
///
/// The destination goes through zwp_linux_dmabuf_v1 as well: the
/// compositor resolves a copy destination through its own import path,
/// so a wl_buffer nobody imported is not a destination it can write.
fn verifyInDmabuf(
    state: *ClientState,
    cam: ViewCamera,
    cursor: ?CursorBox,
    variant: u8,
    tag: []const u8,
) !void {
    const cap = try openDmabufCapture(state);
    const offered = cap.offered.?;
    const device = state.gbm orelse return error.NoGbmDevice;
    var bo = QualBo.create(device, offered.width, offered.height, offered.format) catch |err| {
        cap.failed = true;
        cap.failure = .alloc;
        verdict("CLIENT-DMABUF-ERROR", "{s}: destination allocation failed: {s}", .{ tag, @errorName(err) });
        return err;
    };
    defer bo.deinit();
    const buffer = importAsBuffer(state, &bo) catch |err| {
        cap.failed = true;
        cap.failure = .params;
        verdict("CLIENT-DMABUF-ERROR", "{s}: destination import failed: {s}", .{ tag, @errorName(err) });
        return err;
    };
    cap.buffer = buffer;
    // The release mark is taken BEFORE the copy, so the wait below
    // cannot be satisfied by an event from an earlier capture.
    state.release_mark = state.released;
    cap.frame.copy(buffer);
    if (wl.Display.flush(state.display) != .SUCCESS) {
        cap.failed = true;
        cap.failure = .flush;
        verdict("CLIENT-DMABUF-ERROR", "{s}: flush after the copy failed", .{tag});
        return error.FlushFailed;
    }
    if (!try waitForEvent(hasDmabufCaptureDone, state, timeout_ms)) {
        return qualFail("CLIENT-DMABUF-ERROR", "{s}: no copy ready/failed within {d}ms", .{ tag, timeout_ms });
    }
    if (cap.failed or !cap.ready) {
        return qualFail("CLIENT-DMABUF-ERROR", "{s}: screencopy into the dmabuf failed ({s})", .{
            tag, @tagName(cap.failure),
        });
    }
    const pixels = bo.map(false) catch |err| {
        return qualFail("CLIENT-DMABUF-ERROR", "{s}: destination map for readback failed: {s}", .{
            tag, @errorName(err),
        });
    };
    const matched = verifyPattern(pixels, bo.map_stride, state, cam, cursor, variant) catch |err| {
        bo.unmap();
        return qualFail("CLIENT-DMABUF-ERROR", "{s}: too few sample points to judge the capture ({s})", .{
            tag, @errorName(err),
        });
    };
    bo.unmap();
    if (matched.matched != matched.total) {
        return qualFail("CLIENT-DMABUF-ERROR", "{s}: {d}/{d} sample points in the dmabuf destination carry the pattern", .{
            tag, matched.matched, matched.total,
        });
    }
    verdict("CLIENT-DMABUF-CAPTURE", "{s}: {d}x{d} fmt=0x{x} copy verified in a dmabuf destination ({d}/{d} points)", .{
        tag, offered.width, offered.height, offered.format, matched.matched, matched.total,
    });

    // The compositor hands the destination back when it is done with it;
    // a driver that never releases it is logged, not waited on forever.
    if (try waitForEvent(hasRelease, state, 2000)) {
        step("{s}: destination wl_buffer released", .{tag});
    } else {
        step("{s}: destination wl_buffer not released within 2000ms (destroying anyway)", .{tag});
    }
    const buffer_id = buffer.getId();
    buffer.destroy();
    cap.frame.destroy();
    state.dmabuf_cap = null;
    step("{s}: destroyed destination wl_buffer {d}", .{ tag, buffer_id });
}

/// Detach the surface content and prove the pattern is gone: the capture
/// must stop showing it. A solid background matches at most a couple of
/// sample points by coincidence, while a surface that still shows the
/// buffer matches every one of them, so the threshold sits far from both.
fn detachAndVerify(
    state: *ClientState,
    cam: ViewCamera,
    cursor: ?CursorBox,
    variant: u8,
) !void {
    state.release_mark = state.released;
    commitAndWait(state, null, false) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "detach commit failed: {s}", .{@errorName(err)});
        return err;
    };
    if (!try waitForEvent(hasRelease, state, timeout_ms)) {
        return qualFail("CLIENT-DMABUF-ERROR", "the compositor never released the detached dmabuf buffer", .{});
    }
    const cap = try captureShmOnce(state, "CLIENT-DMABUF-ERROR");
    const matched = verifyPattern(cap.pixels, cap.stride, state, cam, cursor, variant) catch |err| {
        destroyCapture(state);
        return qualFail("CLIENT-DMABUF-ERROR", "detach capture yielded too few sample points ({s})", .{
            @errorName(err),
        });
    };
    destroyCapture(state);
    if (matched.matched * 4 > matched.total) {
        return qualFail(
            "CLIENT-DMABUF-ERROR",
            "the detached dmabuf is still on the output ({d}/{d} points still show the pattern)",
            .{ matched.matched, matched.total },
        );
    }
    verdict("CLIENT-DMABUF-DETACH", "detached: {d}/{d} points still show the pattern (buffer released)", .{
        matched.matched, matched.total,
    });
}

/// Put the shm buffer back and check the gradient is on the output again:
/// after a DMA-BUF import/destroy round trip the compositor must still
/// render an ordinary wl_shm client correctly, under the same camera and
/// with the cursor still where the pointer datum says it is.
fn restoreShm(state: *ClientState, cam: ViewCamera, cursor: ?CursorBox) !void {
    commitAndWait(state, state.buffer, false) catch |err| {
        verdict("CLIENT-DMABUF-ERROR", "re-attaching the shm buffer failed: {s}", .{@errorName(err)});
        return err;
    };
    const cap = try captureShmOnce(state, "CLIENT-DMABUF-ERROR");
    defer destroyCapture(state);
    const matched = verifySurfacePixels(
        cap,
        cam,
        @floatFromInt(state.surface_width),
        @floatFromInt(state.surface_height),
        0,
        gradientTexels(state),
        cursor,
        pixman_tolerance,
        "CLIENT-DMABUF-ERROR",
    ) catch |err| {
        return qualFail(
            "CLIENT-DMABUF-ERROR",
            "shm gradient lost after the dmabuf round trip: {s}",
            .{@errorName(err)},
        );
    };
    if (cursor) |box| {
        verifyCursorOverlay(cap, box, "CLIENT-DMABUF-ERROR") catch |err| {
            return qualFail("CLIENT-DMABUF-ERROR", "cursor overlay wrong after the round trip: {s}", .{
                @errorName(err),
            });
        };
    }
    verdict("CLIENT-DMABUF-RESTORE", "shm buffer re-attached, {d} gradient probes + cursor verified at the settled camera", .{
        matched,
    });
}

/// Start a screencopy and wait for the frame to say it accepts a DMA-BUF
/// destination. The listener only records events: a listener that blocked
/// would re-enter the event loop it is dispatched from, so the
/// destination is allocated by the caller afterwards.
fn openDmabufCapture(state: *ClientState) !*DmabufCapture {
    const frame = try state.screencopy_mgr.?.captureOutput(1, state.output.?);
    state.dmabuf_cap = .{ .frame = frame };
    const cap = &state.dmabuf_cap.?;
    frame.setListener(*ClientState, onDmabufCapture, state);
    if (wl.Display.flush(state.display) != .SUCCESS) return error.FlushFailed;
    if (!try waitForEvent(hasDmabufOffer, state, timeout_ms)) {
        cap.failed = true;
        cap.failure = .not_offered;
        return qualFail("CLIENT-DMABUF-ERROR", "screencopy never offered a linux_dmabuf destination", .{});
    }
    return cap;
}

/// One screencopy into a wl_shm destination, through the same path the
/// M3 capture uses. The caller frees it with destroyCapture.
fn captureShmOnce(state: *ClientState, comptime tag: []const u8) !*CaptureState {
    const frame = try setupCapture(state);
    frame.setListener(*ClientState, onCaptureFrameEvent, state);
    if (wl.Display.flush(state.display) != .SUCCESS) return error.FlushFailed;
    if (!try waitForEvent(hasCaptureDone, state, timeout_ms)) {
        return qualFail(tag, "shm capture produced no ready/failed within {d}ms", .{timeout_ms});
    }
    const cap = &state.capture.?;
    if (cap.failed or !cap.ready) {
        switch (cap.failure) {
            .server => verdict(tag, "shm capture failed on the server", .{}),
            .buffer_create => verdict(tag, "shm capture buffer creation failed", .{}),
            .flush => verdict(tag, "flush after the shm capture failed", .{}),
        }
        return error.CaptureFailed;
    }
    return cap;
}

// --- qualification listeners ----------------------------------------------

fn onDmabufEvent(linux: *client.zwp.LinuxDmabufV1, event: client.zwp.LinuxDmabufV1.Event, state: *ClientState) void {
    _ = linux;
    switch (event) {
        // Deprecated from v4 on, which is exactly when a client that can
        // read the feedback format table stops seeing them.
        .format => |f| {
            step("linux_dmabuf: format 0x{x} (implicit modifier)", .{f.format});
            pushFormat(state, f.format, drm_format_mod_linear);
        },
        .modifier => |m| {
            const modifier = (@as(u64, m.modifier_hi) << 32) | @as(u64, m.modifier_lo);
            step("linux_dmabuf: format 0x{x} modifier 0x{x}", .{ m.format, modifier });
            pushFormat(state, m.format, modifier);
        },
    }
}

fn onDmabufFeedback(fb: *client.zwp.LinuxDmabufFeedbackV1, event: client.zwp.LinuxDmabufFeedbackV1.Event, state: *ClientState) void {
    switch (event) {
        .format_table => |t| readFormatTable(state, t.fd, t.size),
        // The indices address the LAST table received (each index refers
        // to a pair in the last format_table event).
        .tranche_formats => |tr| {
            const table = state.format_table orelse return;
            for (tr.indices.slice(u16)) |index| {
                if (index >= table.len) {
                    step("tranche index {d} outside the {d}-entry table", .{ index, table.len });
                    continue;
                }
                pushFormat(state, table.pairs[index].format, table.pairs[index].modifier);
            }
        },
        .tranche_target_device => {},
        .tranche_flags => {},
        .tranche_done => {},
        .main_device => {},
        .done => {
            state.feedback_done = true;
            // The feedback object has said everything it will say.
            fb.destroy();
        },
    }
}

fn onDmabufCapture(frame: *client.zwlr.ScreencopyFrameV1, event: client.zwlr.ScreencopyFrameV1.Event, state: *ClientState) void {
    _ = frame;
    const cap = &state.dmabuf_cap.?;
    switch (event) {
        // The shm type is offered too; this frame is copied into the
        // DMA-BUF one, so the allocation happens in the caller.
        .buffer => |b| step("screencopy also offers shm {d}x{d}", .{ b.width, b.height }),
        .linux_dmabuf => |d| {
            cap.offered = .{ .format = d.format, .width = d.width, .height = d.height };
            step("screencopy offers linux_dmabuf 0x{x} {d}x{d}", .{ d.format, d.width, d.height });
        },
        .buffer_done => {},
        .damage => |d| step("screencopy damage {d}x{d}@{d},{d}", .{ d.width, d.height, d.x, d.y }),
        .flags => |f| step("screencopy flags=0x{x}", .{@as(u32, @bitCast(f.flags))}),
        .ready => |r| {
            cap.ready = true;
            step("screencopy ready into the dmabuf destination ts={d},{d},{d}", .{
                r.tv_sec_hi, r.tv_sec_lo, r.tv_nsec,
            });
        },
        .failed => {
            cap.failed = true;
            cap.failure = .server;
            step("screencopy into the dmabuf destination failed", .{});
        },
    }
}

fn onParamsEvent(params: *client.zwp.LinuxBufferParamsV1, event: client.zwp.LinuxBufferParamsV1.Event, state: *ClientState) void {
    _ = params;
    switch (event) {
        .created => |e| {
            _ = e.buffer.getId();
            state.created = e.buffer;
            step("linux_buffer_params: created wl_buffer {d}", .{e.buffer.getId()});
        },
        .failed => {
            state.create_failed = true;
            step("linux_buffer_params: failed", .{});
        },
    }
}

fn onBufferEvent(buffer: *wl.Buffer, event: wl.Buffer.Event, state: *ClientState) void {
    _ = buffer;
    switch (event) {
        .release => {
            state.released += 1;
            step("wl_buffer.release ({d} so far)", .{state.released});
        },
    }
}

fn onPresentationEvent(presentation: *client.wp.Presentation, event: client.wp.Presentation.Event, state: *ClientState) void {
    _ = presentation;
    _ = state;
    switch (event) {
        .clock_id => |c| step("presentation clock_id={d}", .{c.clk_id}),
    }
}

fn onPresentationFeedback(fb: *client.wp.PresentationFeedback, event: client.wp.PresentationFeedback.Event, state: *ClientState) void {
    _ = fb;
    switch (event) {
        .sync_output => {},
        .presented => |p| {
            state.presented += 1;
            step("presentation presented at {d}.{d}.{d} seq={d}.{d}", .{
                p.tv_sec_hi, p.tv_sec_lo, p.tv_nsec, p.seq_hi, p.seq_lo,
            });
        },
        .discarded => {
            state.discarded += 1;
            step("presentation discarded", .{});
        },
    }
}

/// Record one advertised pair, refusing to grow past the bound the rest
/// of the flow assumes.
fn pushFormat(state: *ClientState, format: u32, modifier: u64) void {
    if (state.formats_len >= max_format_pairs) {
        step("advertised pair 0x{x}/0x{x} dropped (bound of {d} reached)", .{
            format, modifier, max_format_pairs,
        });
        return;
    }
    state.formats[state.formats_len] = .{ .format = format, .modifier = modifier };
    state.formats_len += 1;
}

// --- qualification predicates ----------------------------------------------

fn hasFeedback(state: *const ClientState) bool {
    return state.feedback_done;
}

fn hasCreateDone(state: *const ClientState) bool {
    return state.created != null or state.create_failed;
}

fn hasPresented(state: *const ClientState) bool {
    return state.presented > state.presented_mark;
}

fn hasRelease(state: *const ClientState) bool {
    return state.released > state.release_mark;
}

fn hasDmabufOffer(state: *const ClientState) bool {
    const cap = state.dmabuf_cap orelse return false;
    return cap.offered != null;
}

fn hasDmabufCaptureDone(state: *const ClientState) bool {
    const cap = state.dmabuf_cap orelse return false;
    return cap.ready or cap.failed;
}

// --- qualification verdict helper -----------------------------------------
/// Report a qualification failure: the verdict line goes to stdout and
/// stderr, and the error out ends the run with a nonzero status, so a
/// failed qualification can never read as a pass.
fn qualFail(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) error{QualificationFailed} {
    verdict(tag, fmt, args);
    return error.QualificationFailed;
}

// ---------------------------------------------------------------------------
// Connector and input-device qualification (opt-in: WAYLAND_CLIENT_HOTPLUG=1)
// ---------------------------------------------------------------------------
//
// The transitions themselves belong to the harness, and deliberately so.
//
//   * Connector off/on: scripts/vm-drm-e2e.sh writes the DRM connector
//     debugfs `force` file of ONE connector on the guest's virtio-gpu
//     card ("off", then "unspecified") and raises a real change uevent
//     for it. The kernel then reports that connector disconnected (the
//     generic DRM probe honours `force`), so the compositor's own udev
//     reconcile destroys that output and its wl_output global, and the
//     reverse transition brings a new one up. QEMU's virtio-gpu has no
//     per-connector runtime switch - its only connector properties
//     (`max_outputs`, `outputs`) are realize-time - so this is the
//     supported guest-side way to take one connector away.
//   * Input device removal: the host runner hot-unplugs the guest's
//     virtio-keyboard-pci and virtio-mouse-pci over QMP (device_del,
//     device_add) and injects real events with input-send-event.
//
// This client only observes the wire and reads real pixels back. Every
// observation is asymmetric, so a faked transition would have to fake
// both halves of a pair:
//
//   * exactly ONE bound wl_output global disappears while the other is
//     untouched and still captures byte-identical pixels;
//   * the cursor overlay is on exactly ONE view — the one the pointer is
//     on — before and after the removal, never on all of them and never
//     on none of them;
//   * after the connector returns, a wl_output global this client never
//     saw before appears, and its view either renders the client's
//     surface (checked pixel for pixel) or reports that this view's
//     camera shows none of it;
//   * a keyboard capability that vanishes comes back;
//   * a pointer that moved before its device went away stays silent
//     while the device is gone, and moves again after it returns.
//
// A transition that does not happen is a failure naming the observation
// that never arrived, never a skip.

/// Mailbox between this client and scripts/vm-drm-e2e.sh. Both halves run
/// in the same guest on tmpfs, so neither ever reads a stale 9p view.
const phase_dir = "/tmp/wlvm-phase";

/// How long one phase waits for the harness and then for the compositor
/// before the transition counts as missing. Generous on purpose: a
/// modeset plus a reconcile is not instant, and a slow machine must not
/// read as a broken one.
const phase_timeout_ms: i64 = 20000;

/// How long the pointer must stay silent after its device was unplugged.
/// Nothing else in the guest moves it: the compositor's synth click
/// happened before this phase and no host pointer event exists, so a
/// single motion here would mean the device never really went away.
const pointer_quiet_ms: i64 = 1200;

/// The wire keycodes the input phase watches: 38 is 'a' and 56 is 'b'
/// (a wl keycode is the evdev code plus 8, so evdev 30/48, which are
/// Q_KEY_CODE_A and Q_KEY_CODE_B in QEMU's input-send-event table).
/// Neither is the key 30 the server's own synth input sends, so a synth
/// event can never pass for one this phase asked the harness to inject.
const qual_keys = [_]u32{ 38, 56 };

/// wl_seat capability bits (wayland.xml: pointer 1, touch 2, keyboard 4),
/// spelled out on the wire the same way this file spells out evdev
/// keycode offsets.
const seat_cap_pointer: u32 = 1;
const seat_cap_keyboard: u32 = 4;

/// The fingerprint lattice: 4 columns by 6 rows of pixels compared byte
/// for byte across the connector removal.
const fingerprint_grid_x: usize = 4;
const fingerprint_grid_y: usize = 6;
const fingerprint_points: usize = fingerprint_grid_x * fingerprint_grid_y;

/// How many wl_output globals the client binds at once. The guest runs at
/// most a handful of scanouts; a global beyond this is reported rather
/// than bound, so the phase never pretends it saw the whole desktop.
const max_bound_outputs: usize = 8;

/// One wl_output global this client bound, and what it announced.
/// The removal is proven against these: the survivor keeps its mode and
/// its pixels, the removed one is destroyed, and the replugged one is a
/// global name this client has never seen.
const BoundOutput = struct {
    /// The registry name. A global_remove event carries exactly this, so
    /// it is the only identity a removal can be matched by.
    global_name: u32 = 0,
    resource: ?*wl.Output = null,
    mode: ?OutputMode = null,
    /// The index of this slot inside ClientState.outputs, so a listener
    /// that only holds the slot can find the state again.
    index: usize = 0,
    removed: bool = false,
    /// Listener data, stored in the slot so its address outlives bind.
    listener: OutputSlot = undefined,
};

const OutputMode = struct { width: i32, height: i32 };

/// Listener data of one bound wl_output: the slot a mode event belongs to
/// plus the state, so a second output's mode cannot overwrite the first's.
const OutputSlot = struct {
    slot: *BoundOutput,
    state: *ClientState,
};

/// Bind one wl_output global and record it. Every output is bound, not
/// just the first: a connector that disappears is only provable next to
/// one that does not, so the M3 flow keeps `state.output` as the first
/// and the table as the whole desktop.
fn bindWlOutput(state: *ClientState, global_name: u32, version: u32) void {
    state.output_globals += 1;
    if (state.outputs_len >= state.outputs.len) {
        step("wl_output global {d} not bound: the table holds {d}", .{ global_name, state.outputs.len });
        return;
    }
    const slot = &state.outputs[state.outputs_len];
    slot.* = .{ .global_name = global_name, .index = state.outputs_len };
    slot.listener = .{ .slot = slot, .state = state };
    const resource = state.registry.bind(global_name, wl.Output, @min(version, wl.Output.generated_version)) catch |err| {
        step("wl_output global {d} bind failed: {s}", .{ global_name, @errorName(err) });
        return;
    };
    slot.resource = resource;
    resource.setListener(*OutputSlot, onBoundOutputEvent, &slot.listener);
    state.outputs_len += 1;
    if (state.output == null) state.output = resource;
    step("bound wl_output global {d} as object {d} ({d} bound)", .{ global_name, resource.getId(), state.outputs_len });
}

/// A wl_output global this client bound is gone: remember which one, drop
/// the proxy (the protocol says a client stops using a removed global),
/// and count the event so a second removal cannot hide behind the first.
fn onOutputGlobalRemoved(state: *ClientState, global_name: u32) void {
    for (state.outputs[0..state.outputs_len]) |*slot| {
        if (slot.removed or slot.global_name != global_name) continue;
        slot.removed = true;
        state.output_removals += 1;
        if (slot.resource) |resource| {
            const id = resource.getId();
            resource.destroy();
            slot.resource = null;
            if (state.output == resource) state.output = null;
            step("wl_output global {d} (object {d}) removed; proxy destroyed", .{ global_name, id });
        }
        return;
    }
    step("wl_output global {d} removed (it was never bound here)", .{global_name});
}

/// The first bound output that is still alive. The connector scenario
/// needs one: an output with nothing next to it proves nothing about the
/// others being left alone.
fn firstLiveOutput(state: *const ClientState) ?usize {
    for (state.outputs[0..state.outputs_len], 0..) |slot, index| {
        if (!slot.removed and slot.resource != null) return index;
    }
    return null;
}

/// Capture one named output at ITS OWN announced mode, through the same
/// screencopy path the M3 capture uses. `setupCapture` is this with the
/// first output.
fn captureOutputOn(
    state: *ClientState,
    output: *wl.Output,
    mode: OutputMode,
) !*CaptureState {
    const frame = try setupCaptureFor(state, output, mode);
    frame.setListener(*ClientState, onCaptureFrameEvent, state);
    if (wl.Display.flush(state.display) != .SUCCESS) return error.FlushFailed;
    if (!try waitForEvent(hasCaptureDone, state, timeout_ms)) return error.ClientTimeout;
    const cap = &state.capture.?;
    if (cap.failed or !cap.ready) {
        switch (cap.failure) {
            .server => verdict("CLIENT-HOTPLUG-ERROR", "screencopy failed on the server", .{}),
            .buffer_create => verdict("CLIENT-HOTPLUG-ERROR", "capture buffer creation failed", .{}),
            .flush => verdict("CLIENT-HOTPLUG-ERROR", "flush after the capture copy failed", .{}),
        }
        return error.CaptureFailed;
    }
    return cap;
}

/// What one output's capture proved about this client's surface.
const OutputCheck = struct {
    /// The cursor overlay is drawn on THIS view.
    cursor_present: bool,
    /// The surface projects into this view at all, so its pixels had to
    /// be right here.
    surface_visible: bool,
};

/// The view pixels this surface's four corners project to, as an
/// axis-aligned box. Under a rotated camera this is the box around the
/// rotated quad, so "does this view show any of the surface" is answered
/// conservatively — a rotated surface can only ever be judged inside it.
fn projectedBounds(cam: ViewCamera, size_w: f64, size_h: f64) FRect {
    const corners = [_]FPoint{
        cam.worldToScreen(0, 0),
        cam.worldToScreen(size_w, 0),
        cam.worldToScreen(0, size_h),
        cam.worldToScreen(size_w, size_h),
    };
    var min_x = corners[0].x;
    var min_y = corners[0].y;
    var max_x = corners[0].x;
    var max_y = corners[0].y;
    for (corners[1..]) |corner| {
        min_x = @min(min_x, corner.x);
        min_y = @min(min_y, corner.y);
        max_x = @max(max_x, corner.x);
        max_y = @max(max_y, corner.y);
    }
    return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
}

/// Verify ONE output's capture: it must be this output's advertised mode,
/// and — when this view can see the surface at all — it must carry the
/// client's gradient at probes derived from the surface and THIS output's
/// own camera, plus the cursor overlay at the position the pointer datum
/// and that camera put it.
///
/// Returns what was proven. A cursor belongs to exactly one view (the
/// compositor only paints the one the pointer is on), so the caller adds
/// the answers up across every output instead of asking one by index. An
/// output whose camera shows none of the surface is reported, not
/// silently passed: the caller prints how many outputs showed it.
fn verifyOutputCapture(
    state: *ClientState,
    cap: *const CaptureState,
    slot: *const BoundOutput,
    comptime tag: []const u8,
) !OutputCheck {
    const mode = slot.mode orelse return hotplugFail("{s}: no wl_output mode was announced for this output", .{tag});
    if (cap.width != @as(u32, @intCast(mode.width)) or
        cap.height != @as(u32, @intCast(mode.height)))
    {
        return hotplugFail("{s}: capture {d}x{d} is not this output's advertised mode {d}x{d}", .{
            tag, cap.width, cap.height, mode.width, mode.height,
        });
    }
    const cam = settledCamera(state, mode);
    const cursor = derivedCursorBox(state, mode);
    const bounds = projectedBounds(cam, @floatFromInt(state.surface_width), @floatFromInt(state.surface_height));
    if (bounds.right() <= 0 or bounds.bottom() <= 0 or
        bounds.x >= @as(f64, @floatFromInt(cap.width)) or
        bounds.y >= @as(f64, @floatFromInt(cap.height)))
    {
        step("{s}: output {d}: the client's surface projects to ({d:.0},{d:.0})-({d:.0},{d:.0}), entirely outside this view", .{
            tag, slot.index, bounds.x, bounds.y, bounds.right(), bounds.bottom(),
        });
        return .{ .cursor_present = false, .surface_visible = false };
    }
    _ = verifySurfacePixels(
        cap,
        cam,
        @floatFromInt(state.surface_width),
        @floatFromInt(state.surface_height),
        0,
        gradientTexels(state),
        cursor,
        pixman_tolerance,
        tag,
    ) catch |err| {
        return hotplugFail("{s}: output {d} shows the surface but not its gradient ({s})", .{
            tag, slot.index, @errorName(err),
        });
    };
    const box = cursor orelse return .{ .cursor_present = false, .surface_visible = true };
    if (!box.wholeInside(cap.width, cap.height)) {
        step("{s}: output {d}: the derived cursor box is clipped by this view's edge", .{ tag, slot.index });
        return .{ .cursor_present = false, .surface_visible = true };
    }
    if (locateCursorBody(cap, box) == null) return .{ .cursor_present = false, .surface_visible = true };
    verifyCursorOverlay(cap, box, tag) catch |err| {
        return hotplugFail("{s}: output {d}: cursor overlay {s}", .{ tag, slot.index, @errorName(err) });
    };
    return .{ .cursor_present = true, .surface_visible = true };
}

/// Remember the survivor's pixels on the fingerprint lattice. Points the
/// derived cursor box covers are left out: the cursor is drawn there and
/// this phase moves the pointer later, so keeping them would compare two
/// different things at once.
fn fingerprintOutput(
    state: *ClientState,
    cap: *const CaptureState,
    slot: *const BoundOutput,
    cursor: ?CursorBox,
) !usize {
    const mode = slot.mode orelse return hotplugFail("fingerprint: output {d} announced no mode", .{slot.index});
    var stored: usize = 0;
    for (0..fingerprint_grid_x) |ix| {
        for (0..fingerprint_grid_y) |iy| {
            const x = (ix + 1) * @as(usize, @intCast(mode.width)) / (fingerprint_grid_x + 1);
            const y = (iy + 1) * @as(usize, @intCast(mode.height)) / (fingerprint_grid_y + 1);
            if (cursor) |box| {
                if (box.covers(@intCast(x), @intCast(y))) continue;
            }
            state.survivor_fp[stored] = pxAt(cap, x, y);
            stored += 1;
        }
    }
    if (stored < fingerprint_points / 2) {
        return hotplugFail("fingerprint: only {d} sample points on output {d}", .{ stored, slot.index });
    }
    return stored;
}

/// The survivor must look exactly the way it did before its neighbour was
/// unplugged: a compositor that reflowed the desktop, dropped the surface
/// or re-rendered a stale framebuffer fails here on a single byte.
fn compareSurvivorFingerprint(
    state: *ClientState,
    cap: *const CaptureState,
    slot: *const BoundOutput,
    cursor: ?CursorBox,
) !void {
    const mode = slot.mode orelse return hotplugFail("fingerprint: output {d} announced no mode", .{slot.index});
    var seen: usize = 0;
    for (0..fingerprint_grid_x) |ix| {
        for (0..fingerprint_grid_y) |iy| {
            const x = (ix + 1) * @as(usize, @intCast(mode.width)) / (fingerprint_grid_x + 1);
            const y = (iy + 1) * @as(usize, @intCast(mode.height)) / (fingerprint_grid_y + 1);
            if (cursor) |box| {
                if (box.covers(@intCast(x), @intCast(y))) continue;
            }
            if (seen >= state.survivor_fp_len) break;
            const got = pxAt(cap, x, y);
            const want = state.survivor_fp[seen];
            if (!std.mem.eql(u8, &got, &want)) {
                return hotplugFail("survivor output {d} pixel ({d},{d}) changed across the removal: {d},{d},{d},{d} -> {d},{d},{d},{d}", .{
                    slot.index, x, y, want[0], want[1], want[2], want[3], got[0], got[1], got[2], got[3],
                });
            }
            seen += 1;
        }
    }
    if (seen != state.survivor_fp_len) {
        return hotplugFail("fingerprint compared {d} of {d} pixels", .{ seen, state.survivor_fp_len });
    }
}

/// The index in qual_keys of a watched wire keycode, or null.
fn qualKeyIndex(key: u32) ?usize {
    for (qual_keys, 0..) |watched, index| {
        if (watched == key) return index;
    }
    return null;
}

fn phasePath(buf: []u8, phase: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ phase_dir, phase });
}

fn fileExists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return false;
    _ = std.os.linux.close(fd);
    return true;
}

/// Announce that this client's half of a phase is done and it is waiting
/// for the harness to perform the transition.
fn writeMarker(phase: []const u8) void {
    var buf: [96]u8 = undefined;
    const path = phasePath(&buf, phase) catch {
        step("phase {s}: marker path does not fit", .{phase});
        return;
    };
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644) catch |err| {
        step("phase {s}: marker {s} not created ({s})", .{ phase, path, @errorName(err) });
        return;
    };
    _ = std.os.linux.close(fd);
    step("phase {s}: reported done", .{phase});
}

fn waitMarker(phase: []const u8) !void {
    var buf: [96]u8 = undefined;
    const path = phasePath(&buf, phase) catch return error.MarkerPathTooLong;
    const started = nowMs();
    while (!fileExists(path)) {
        if (nowMs() - started >= phase_timeout_ms) return error.MarkerTimeout;
        std.Io.sleep(client_io, .fromMilliseconds(20), .awake) catch |err| return err;
    }
    step("phase {s}: harness released us after {d}ms", .{ phase, nowMs() - started });
}

/// The whole qualification. Runs after the DMA-BUF phase, so a run that
/// asked for both reports a DMA-BUF failure first and never reaches a
/// connector step on a compositor that was already wrong.
/// The VM phase-directory service creates the shared mailbox before the
/// compositor starts; a missing mailbox is a qualification failure.
fn runHotplugQualification(state: *ClientState) !void {
    step("connector + input-device qualification: on", .{});

    writeMarker("start");
    waitMarker("start") catch |err| {
        return hotplugFail("no harness handshake ({s}): {s} is not shared with the harness", .{
            @errorName(err), phase_dir,
        });
    };

    // --- baseline: every output captured, the first one fingerprinted ---
    if (state.outputs_len < 2) {
        return hotplugFail("{d} wl_output global(s) bound: the connector scenario needs a surviving output next to the one that goes away", .{
            state.outputs_len,
        });
    }
    // The synth wheel zoom has already landed by now, so every capture of
    // this phase runs at one known camera per output.
    var cursor_views: usize = 0;
    var cursor_owner: usize = max_bound_outputs;
    var visible_views: usize = 0;
    for (state.outputs[0..state.outputs_len]) |*slot| {
        const resource = slot.resource orelse continue;
        const mode = slot.mode orelse return hotplugFail(
            "baseline: output {d} announced no mode",
            .{slot.index},
        );
        const cursor = derivedCursorBox(state, mode);
        const cap = try captureOutputOn(state, resource, mode);
        const check = try verifyOutputCapture(state, cap, slot, "baseline");
        if (check.surface_visible) visible_views += 1;
        if (check.cursor_present) {
            cursor_views += 1;
            cursor_owner = slot.index;
        }
        if (slot.index == 0) {
            state.survivor_fp_len = try fingerprintOutput(state, cap, slot, cursor);
        }
        destroyCapture(state);
    }
    // One pointer, one view: a cursor on every output, or on none, would
    // both mean the overlay is not per-output at all.
    if (cursor_views != 1) {
        return hotplugFail("{d} of {d} outputs carry the cursor overlay; exactly one may (the view the pointer is on)", .{
            cursor_views, state.outputs_len,
        });
    }
    verdict("CLIENT-HOTPLUG-BASELINE", "{d} outputs captured ({d} show the client's surface); cursor overlay on output {d} only; {d} pixels fingerprinted on output 0", .{
        state.outputs_len, visible_views, cursor_owner, state.survivor_fp_len,
    });
    // The mark is taken BEFORE the harness is released, so a transition
    // that lands while the client is still reading the mailbox is counted
    // instead of being absorbed by the mark.
    state.removals_mark = state.output_removals;
    writeMarker("connector-off");
    waitMarker("connector-off") catch |err| {
        return hotplugFail("the harness never took a connector off ({s})", .{@errorName(err)});
    };

    // --- the connector goes away: exactly one global, one survivor ------
    if (!try waitForEvent(hasOutputRemoval, state, phase_timeout_ms)) {
        return hotplugFail("no wl_registry.global_remove for any output within {d}ms of the connector being forced off", .{
            phase_timeout_ms,
        });
    }
    const removed_now = state.output_removals - state.removals_mark;
    if (removed_now != 1) {
        return hotplugFail("{d} output globals removed, exactly one expected: which connector went away is ambiguous", .{removed_now});
    }
    state.survivor = firstLiveOutput(state) orelse {
        return hotplugFail("every bound output was removed: there is no survivor to preserve", .{});
    };
    verdict("CLIENT-HOTPLUG-REMOVE", "one wl_output global withdrawn; output {d} survives", .{state.survivor});

    const survivor_slot = &state.outputs[state.survivor];
    const survivor = survivor_slot.resource orelse {
        return hotplugFail("survivor output {d} has no usable proxy", .{state.survivor});
    };
    const survivor_mode = survivor_slot.mode orelse return hotplugFail(
        "survivor output {d} announced no mode",
        .{state.survivor},
    );
    const survivor_cursor = derivedCursorBox(state, survivor_mode);
    const survivor_cap = try captureOutputOn(state, survivor, survivor_mode);
    const survivor_check = try verifyOutputCapture(state, survivor_cap, survivor_slot, "survivor");
    // The pointer did not move, so the overlay must still be on the view
    // that had it — unless that view is the one that went away.
    if (survivor_check.cursor_present != (state.survivor == cursor_owner)) {
        return hotplugFail("survivor output {d} {s} the cursor after the removal, but output {d} held it before", .{
            state.survivor,
            if (survivor_check.cursor_present) "still carries" else "no longer carries",
            cursor_owner,
        });
    }
    try compareSurvivorFingerprint(state, survivor_cap, survivor_slot, survivor_cursor);
    destroyCapture(state);
    verdict("CLIENT-HOTPLUG-SURVIVOR", "output {d} kept its view: {d} pixels byte-identical across the removal", .{
        state.survivor, state.survivor_fp_len,
    });
    state.additions_mark = state.output_globals;
    const len_mark = state.outputs_len;
    writeMarker("connector-on");
    waitMarker("connector-on") catch |err| {
        return hotplugFail("the harness never put the connector back ({s})", .{@errorName(err)});
    };

    // --- the connector comes back as a new global -----------------------
    if (!try waitForEvent(hasOutputAddition, state, phase_timeout_ms)) {
        return hotplugFail("no wl_registry.global for a returning connector within {d}ms", .{phase_timeout_ms});
    }
    if (state.outputs_len <= len_mark) {
        return hotplugFail("a wl_output global arrived but nothing could be bound: the compositor may be announcing an output it cannot drive", .{});
    }
    const fresh = &state.outputs[state.outputs_len - 1];
    for (state.outputs[0..len_mark]) |slot| {
        if (slot.global_name == fresh.global_name) {
            return hotplugFail("global {d} was re-announced instead of a new one: the removed output was reused", .{fresh.global_name});
        }
    }
    state.waiting = fresh;
    if (!try waitForEvent(hasWatchedMode, state, phase_timeout_ms)) {
        return hotplugFail("the re-announced output {d} sent no wl_output.mode within {d}ms", .{ fresh.global_name, phase_timeout_ms });
    }
    state.waiting = null;
    const fresh_resource = fresh.resource orelse {
        return hotplugFail("the re-announced output {d} has no usable proxy", .{fresh.global_name});
    };
    const readded_mode = fresh.mode orelse return hotplugFail(
        "re-announced output {d} announced no mode",
        .{fresh.global_name},
    );
    const fresh_cap = try captureOutputOn(state, fresh_resource, readded_mode);
    const readded_check = try verifyOutputCapture(state, fresh_cap, fresh, "readded");
    destroyCapture(state);
    verdict("CLIENT-HOTPLUG-READD", "output global {d} added as object {d}, {d}x{d}, its view {s} the client's surface", .{
        fresh.global_name,
        fresh_resource.getId(),
        readded_mode.width,
        readded_mode.height,
        if (readded_check.surface_visible) "shows" else "does not show",
    });
    state.watch_key = 0;
    state.watch_key_mark = state.key_counts[0];
    writeMarker("key-press");
    waitMarker("key-press") catch |err| {
        return hotplugFail("the harness never injected a key ({s})", .{@errorName(err)});
    };

    // --- a real key from a device that is about to be unplugged ---------
    if (!try waitForEvent(hasWatchedKey, state, phase_timeout_ms)) {
        return hotplugFail("no key {d} arrived within {d}ms of the harness injecting it into the guest's keyboard device", .{
            qual_keys[0], phase_timeout_ms,
        });
    }
    verdict("CLIENT-HOTPLUG-KEY", "key {d} delivered while the keyboard device was still plugged in", .{qual_keys[0]});
    state.watch_cap_mask = seat_cap_keyboard;
    state.caps_mark = state.caps_seen;
    writeMarker("keyboard-del");
    waitMarker("keyboard-del") catch |err| {
        return hotplugFail("the harness never removed the keyboard device ({s})", .{@errorName(err)});
    };

    // --- the keyboard DEVICE is gone: the capability must go with it -----
    if (!try waitForEvent(hasSeatLostWatched, state, phase_timeout_ms)) {
        return hotplugFail("wl_seat.capabilities still advertises the keyboard {d}ms after its only device was unplugged", .{
            phase_timeout_ms,
        });
    }
    verdict("CLIENT-HOTPLUG-KEYBOARD-GONE", "keyboard capability withdrawn (caps=0x{x}); the pointer capability stayed at bit {d}", .{
        state.seat_caps, seat_cap_pointer,
    });

    state.caps_mark = state.caps_seen;
    state.watch_key = 1;
    state.watch_key_mark = state.key_counts[1];
    writeMarker("keyboard-add");
    waitMarker("keyboard-add") catch |err| {
        return hotplugFail("the harness never replugged the keyboard ({s})", .{@errorName(err)});
    };

    // --- and back: the capability returns, with a DIFFERENT key ----------
    if (!try waitForEvent(hasSeatGainedWatched, state, phase_timeout_ms)) {
        return hotplugFail("wl_seat.capabilities did not regain the keyboard {d}ms after the device was replugged", .{phase_timeout_ms});
    }
    if (!try waitForEvent(hasWatchedKey, state, phase_timeout_ms)) {
        return hotplugFail("no key {d} arrived from the replugged keyboard device", .{qual_keys[1]});
    }
    verdict("CLIENT-HOTPLUG-KEYBOARD-BACK", "keyboard capability restored (caps=0x{x}) and key {d} delivered by the new device", .{
        state.seat_caps, qual_keys[1],
    });
    // Marks are taken BEFORE the harness is released, so an event that
    // lands while the client is still reading the mailbox is counted
    // instead of being absorbed by the mark.
    state.motion_mark = state.motions;
    writeMarker("mouse-del");
    waitMarker("mouse-del") catch |err| {
        return hotplugFail("the harness never removed the pointer device ({s})", .{@errorName(err)});
    };

    // --- the pointer DEVICE is gone: nothing may move it any more -------
    // The usb-tablet the qemu-vm module adds has no qdev id, so it cannot
    // be unplugged and the pointer CAPABILITY must stay; what proves the
    // device is gone is that the pointer stops moving. The wait keeps
    // dispatching, so a motion that had already arrived is read here
    // rather than being counted later.
    const quiet_until = nowMs() + pointer_quiet_ms;
    while (nowMs() < quiet_until) {
        _ = try waitForEvent(hasMotionMoved, state, 50);
        if (state.motions != state.motion_mark) {
            return hotplugFail("{d} pointer motion event(s) arrived after the mouse device was unplugged: the device never went away", .{
                state.motions - state.motion_mark,
            });
        }
    }
    verdict("CLIENT-HOTPLUG-POINTER-GONE", "no pointer motion for {d}ms after the mouse device was unplugged (motions={d})", .{
        pointer_quiet_ms, state.motions,
    });
    state.motion_mark = state.motions;
    writeMarker("mouse-add");
    waitMarker("mouse-add") catch |err| {
        return hotplugFail("the harness never replugged the pointer ({s})", .{@errorName(err)});
    };

    // --- and back: the pointer moves again -------------------------------
    if (!try waitForEvent(hasMotionMoved, state, phase_timeout_ms)) {
        return hotplugFail("no pointer motion within {d}ms of the mouse device being replugged and driven", .{phase_timeout_ms});
    }
    verdict("CLIENT-HOTPLUG-POINTER-BACK", "pointer at {d},{d} again after the device was replugged", .{
        state.last_motion_x, state.last_motion_y,
    });
    verdict("CLIENT-HOTPLUG-OK", "connector off/on and input-device removal qualified on {d} outputs: one global withdrawn and one survivor byte-identical, one re-added, keyboard capability withdrawn and restored with real keys, pointer silent while absent and moving after return", .{
        state.outputs_len,
    });
}

/// Report a failure of this phase: the verdict line goes to stdout and
/// stderr and the error out ends the run nonzero, so a transition that
/// did not happen can never read as a pass.
fn hotplugFail(comptime fmt: []const u8, args: anytype) error{HotplugQualificationFailed} {
    verdict("CLIENT-HOTPLUG-ERROR", fmt, args);
    return error.HotplugQualificationFailed;
}

// --- connector/input predicates -------------------------------------------

fn hasOutputRemoval(state: *const ClientState) bool {
    return state.output_removals > state.removals_mark;
}

fn hasOutputAddition(state: *const ClientState) bool {
    return state.output_globals > state.additions_mark;
}

fn hasWatchedMode(state: *const ClientState) bool {
    const slot = state.waiting orelse return false;
    return slot.mode != null;
}

fn hasWatchedKey(state: *const ClientState) bool {
    return state.key_counts[state.watch_key] > state.watch_key_mark;
}

fn hasSeatLostWatched(state: *const ClientState) bool {
    if (state.caps_seen <= state.caps_mark) return false;
    return state.seat_caps & state.watch_cap_mask == 0;
}

fn hasSeatGainedWatched(state: *const ClientState) bool {
    if (state.caps_seen <= state.caps_mark) return false;
    return state.seat_caps & state.watch_cap_mask != 0;
}

fn hasMotionMoved(state: *const ClientState) bool {
    return state.motions > state.motion_mark;
}

/// Monotonic milliseconds, the one clock every wait and log line uses.
fn nowMs() i64 {
    const ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}
