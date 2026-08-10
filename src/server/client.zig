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
//!      zwlr_screencopy_v1 and verifies the composited pixels (gradient,
//!      cursor overlay).
//!
//! On failure prints CLIENT-ERROR/CLIENT-TIMEOUT and exits nonzero.
//! All progress lines go to stderr; the CLIENT-* verdicts to stdout.

const std = @import("std");
const protocol = @import("protocol");

const client = protocol.client;
const wl = client.wl;
const xdg = client.xdg;

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
    output_mode: ?struct { width: i32, height: i32 } = null,
    /// Surface size resolved from the advertised output mode (fallback
    /// constants if the mode event had not arrived at setup time).
    surface_width: i32 = 0,
    surface_height: i32 = 0,
    /// M4: the server's camera, parsed from WAYLAND_CAMERA at startup —
    /// the world→screen mapping used for the camera-aware gradient
    /// expectations. Identity defaults (cx=cy=0, zoom=1): world x ==
    /// screen x, today's behavior.
    camera_cx: f64 = 0,
    camera_cy: f64 = 0,
    camera_zoom: f64 = 1,
    /// True when WAYLAND_CAMERA was present (even if partially parsed):
    /// mirrors the server, where a present-but-missing cx/cy means 0.
    camera_env_set: bool = false,
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
    // M4: the server camera (WAYLAND_CAMERA) drives the camera-aware
    // gradient expectations in verifyCapturePixels.
    parseCameraEnv(&state, init.environ_map);

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
    const out = state.output.?;
    out.setListener(*ClientState, onOutputEvent, &state);
    step("seat+output listeners attached (caps so far: 0x{x})", .{state.seat_caps});

    // --- xdg toplevel -----------------------------------------------------
    const surface = try state.compositor.?.createSurface();
    state.surface = surface;
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
    step("input verified: pointer enter+motion, button, key 30, keymap, output {d}x{d}", .{
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
    try verifyCapturePixels(cap, &state);
    destroyCapture(&state);

    // M4 Phase B: the server's synth wheel zoom (2 -> 2.5 under the E2E
    // camera) lands at frame 100; wait for it with a bounded
    // capture-retry loop.
    try verifyZoomLanding(&state);

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
            } else if (std.mem.eql(u8, name, "wl_output") and state.output == null) {
                state.output = registry.bind(g.name, wl.Output, 4) catch null;
            } else if (std.mem.eql(u8, name, "zwlr_screencopy_manager_v1") and state.screencopy_mgr == null) {
                state.screencopy_mgr = registry.bind(g.name, client.zwlr.ScreencopyManagerV1, 3) catch null;
            }
        },
        .global_remove => {},
    }
}

fn onSeatEvent(seat: *wl.Seat, event: wl.Seat.Event, state: *ClientState) void {
    _ = seat;
    switch (event) {
        .capabilities => |c| {
            state.seat_caps = @as(u32, @bitCast(c.capabilities));
            step("seat capabilities=0x{x}", .{state.seat_caps});
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
            step("pointer enter at {d},{d}", .{ e.surface_x.toInt(), e.surface_y.toInt() });
        },
        .leave => {},
        .motion => |m| {
            state.got_pointer_motion = true;
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

fn onOutputEvent(output: *wl.Output, event: wl.Output.Event, state: *ClientState) void {
    _ = output;
    switch (event) {
        .geometry => |g| step("output geometry {s} {s} transform={d}", .{
            std.mem.span(g.make), std.mem.span(g.model), @intFromEnum(g.transform),
        }),
        .mode => |m| {
            state.output_mode = .{ .width = m.width, .height = m.height };
            step("output mode {d}x{d}@{d} flags=0x{x}", .{ m.width, m.height, m.refresh, @as(u32, @bitCast(m.flags)) });
        },
        .done => {},
        .scale => |s| step("output scale={d}", .{s.factor}),
        .name => |n| step("output name={s}", .{std.mem.span(n.name)}),
        .description => |d| step("output description={s}", .{std.mem.span(d.description)}),
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
    // Mirror the server's default camera: no WAYLAND_CAMERA env -> the
    // server centers the world origin on the viewport center (zoom 1).
    // The client's identity defaults must match or the zoom verification
    // expects the wrong world point (cx=0 vs cx=W/2).
    if (!state.camera_env_set) {
        state.camera_cx = @as(f64, @floatFromInt(state.surface_width)) / 2.0;
        state.camera_cy = @as(f64, @floatFromInt(state.surface_height)) / 2.0;
    }
}

/// Allocate the capture buffer (second memfd + shm pool) and the frame
/// state; the frame object is created by captureOutput afterwards.
fn setupCapture(state: *ClientState) !*client.zwlr.ScreencopyFrameV1 {
    const pool_size: usize = @as(usize, @intCast(state.surface_width)) *
        @as(usize, @intCast(state.surface_height)) * bytes_per_pixel;
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
    const frame = try state.screencopy_mgr.?.captureOutput(1, state.output.?);
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

/// Verify the captured framebuffer: the client's red gradient (R=255,
/// B ramping with world x) plus the compositor's fallback cursor (a light
/// rect at the synth pointer position 50,50). The gradient checks are
/// camera-aware: the server stamps the surface into world space and
/// renders it through WAYLAND_CAMERA, so screen (x, y) samples the client
/// buffer at world x = cx + (x - cx)/zoom (the server's own inverse is
/// center + (x - W/2)/zoom; the two coincide for the E2E camera, cx =
/// W/2). The cursor stays screen-space at constant size (unchanged).
fn verifyCapturePixels(cap: *const CaptureState, state: *const ClientState) !void {
    if (cap.width != @as(u32, @intCast(state.surface_width)) or
        cap.height != @as(u32, @intCast(state.surface_height)))
    {
        verdict("CLIENT-ERROR", "capture size {d}x{d} != {d}x{d}", .{
            cap.width, cap.height, state.surface_width, state.surface_height,
        });
        return error.CaptureSizeBad;
    }
    // (5,5): gradient colors at the world point under (5,5) — B ramps
    // with world x (identity: x=5 -> B=0; E2E cx=640,zoom=2: world x =
    // 322.5 -> B=64), while R=255, G=0, A=255 hold across the gradient.
    if (!gradientPixelMatches(cap, state, 5, 5, state.camera_zoom)) {
        const g = pxAt(cap, 5, 5);
        verdict("CLIENT-ERROR", "pixel (5,5) = {d},{d},{d},{d}, expected B={d}", .{
            g[0], g[1], g[2], g[3], gradientB(state, 5),
        });
        return error.PixelMismatch;
    }
    // (1000,600): gradient B at the world point under (1000,600) — at
    // identity world x = 1000 -> B = 199; under cx=640,zoom=2 world x =
    // 640 + (1000-640)/2 = 820 -> B = 163.
    const expected_b = gradientB(state, 1000);
    if (!gradientPixelMatches(cap, state, 1000, 600, state.camera_zoom)) {
        const m = pxAt(cap, 1000, 600);
        verdict("CLIENT-ERROR", "pixel (1000,600) = {d},{d},{d},{d}, expected B={d}", .{
            m[0], m[1], m[2], m[3], expected_b,
        });
        return error.PixelMismatch;
    }
    // (51,53): inside the 16x16 pointer-arrow cursor's white body (tip at
    // (50,50), row 3 col 1 is the '1' fill) -> white.
    const c = pxAt(cap, 51, 53);
    if (c[0] < 200 or c[1] < 200 or c[2] < 200) {
        verdict(
            "CLIENT-ERROR",
            "cursor pixel (51,53) = {d},{d},{d},{d}, expected white (arrow body)",
            .{ c[0], c[1], c[2], c[3] },
        );
        return error.PixelMismatch;
    }
    verdict("CLIENT-CAPTURE", "pixels verified: gradient + cursor overlay", .{});
}

/// The client buffer's B value at the world point under screen x: the
/// server stamps the buffer into world space 1:1, so the world point
/// samples buffer pixel (world_x, ...), whose intensity is
/// (world_x * 255) / surface_width (fillPattern). world_x follows the
/// server camera: cx + (x - cx)/zoom with the parsed WAYLAND_CAMERA
/// (identity defaults cx=0, zoom=1 -> world_x = x, the pre-M4 check).
fn gradientB(state: *const ClientState, screen_x: usize) u8 {
    return gradientBAt(state, screen_x, state.camera_zoom);
}

/// gradientB under an explicit camera zoom: the zoom-landing phase
/// checks the 1.25x post-scroll zoom, which the client derives from its
/// env camera + the zoom rule (the server state is not directly
/// observable).
fn gradientBAt(state: *const ClientState, screen_x: usize, zoom: f64) u8 {
    const sx: f64 = @floatFromInt(screen_x);
    const world_x = state.camera_cx + (sx - state.camera_cx) / zoom;
    const wx: usize = @intFromFloat(@floor(world_x));
    return @intCast((wx * 255) / @as(usize, @intCast(state.surface_width)));
}

/// The captured pixel's BGRA bytes at (x, y) in the framebuffer.
fn pxAt(cap: *const CaptureState, x: usize, y: usize) [4]u8 {
    const off = y * cap.stride + x * 4;
    return .{ cap.pixels[off], cap.pixels[off + 1], cap.pixels[off + 2], cap.pixels[off + 3] };
}

/// True when the captured pixel at (screen_x, screen_y) shows the
/// gradient under `zoom`: R=255, G=0, A=255 and B at the world point
/// cx + (screen_x - cx)/zoom. B allows a small tolerance: the real pixman
/// bilinear samples at the pixel CENTER, so the ramp can differ by 1-2
/// from the exact floor formula (R/G/A are exact).
fn gradientPixelMatches(
    cap: *const CaptureState,
    state: *const ClientState,
    screen_x: usize,
    screen_y: usize,
    zoom: f64,
) bool {
    const p = pxAt(cap, screen_x, screen_y);
    const b = gradientBAt(state, screen_x, zoom);
    const b_lo = if (b >= 2) b - 2 else 0;
    const b_hi = if (b <= 253) b + 2 else 255;
    return p[2] == 255 and p[1] == 0 and p[3] == 255 and p[0] >= b_lo and p[0] <= b_hi;
}

/// M4 Phase B: wait for the server's synth wheel zoom to land, then
/// verify the camera-moved gradient. The scroll fires once 100 frames
/// have rendered (2 -> 2.5 under the E2E camera); the compositor
/// re-renders fully and sends frame_done every frame, so a fresh
/// screencopy capture shows the new zoom within a frame of the scroll.
/// Timing-tolerant: capture -> check -> 250ms sleep -> retry, up to 30
/// attempts (7.5s total); CLIENT-ERROR if the zoom never lands.
fn verifyZoomLanding(state: *ClientState) !void {
    const zoom_after = state.camera_zoom * 1.25;
    const expected_b = gradientBAt(state, 1000, zoom_after);
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
        const b = pxAt(cap, 1000, 600)[0];
        if (gradientPixelMatches(cap, state, 1000, 600, zoom_after)) {
            verdict("CLIENT-ZOOM", "zoom landed: {d} -> {d} (B={d} at (1000,600))", .{
                state.camera_zoom, zoom_after, b,
            });
            destroyCapture(state);
            return;
        }
        step("zoom not landed yet (attempt {d}): B={d} at (1000,600), expected {d}", .{
            attempt + 1, b, expected_b,
        });
        destroyCapture(state);
        std.Io.sleep(client_io, .fromMilliseconds(250), .awake) catch |err| {
            verdict("CLIENT-ERROR", "zoom retry sleep failed: {s}", .{@errorName(err)});
            return err;
        };
    }
    verdict("CLIENT-ERROR", "zoom never landed after 30 captures (expected B={d} at (1000,600))", .{
        expected_b,
    });
    return error.ZoomNotLanded;
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

/// Parse WAYLAND_CAMERA ("cx=…,cy=…,zoom=…,rot=…") into the camera state
/// the gradient expectations use. Mirrors the server's parseEnv
/// (scene/camera.zig) but stays self-contained — the client imports no
/// compositor library. Missing or malformed fields keep the identity
/// defaults (cx=cy=0, zoom=1). Rotation is unused by the checks (the
/// gradient varies only in x and the E2E camera has no rotation).
fn parseCameraEnv(state: *ClientState, environ_map: *std.process.Environ.Map) void {
    const value = environ_map.get("WAYLAND_CAMERA") orelse return;
    state.camera_env_set = true;
    var fields = std.mem.splitScalar(u8, value, ',');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..eq];
        const val = std.fmt.parseFloat(f64, field[eq + 1 ..]) catch continue;
        if (std.mem.eql(u8, key, "cx")) {
            state.camera_cx = val;
        } else if (std.mem.eql(u8, key, "cy")) {
            state.camera_cy = val;
        } else if (std.mem.eql(u8, key, "zoom")) {
            state.camera_zoom = val;
        }
    }
}

/// Poll the display fd (bounded by the deadline) and dispatch until
/// `predicate` returns true. Returns false on timeout.
fn waitForEvent(
    comptime predicate: fn (*const ClientState) bool,
    state: *const ClientState,
    ms: i64,
) !bool {
    const display = state.display;
    const start_ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
    const start_ms: i64 = @intCast(@divTrunc(start_ns, std.time.ns_per_ms));
    const deadline = start_ms + ms;
    while (!predicate(state)) {
        const now_ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
        const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
        const remaining = deadline - now_ms;
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
    const now_ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
    const now_ms: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}.{d:0>3} client] " ++ fmt ++ "\n", .{
        now_ms / 1000,
        now_ms % 1000,
    } ++ args) catch return;
    writeFd(std.posix.STDERR_FILENO, line);
}

/// Verdict line, to stdout (parseable), mirrored to stderr.
fn verdict(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    const now_ns = std.Io.Clock.now(.awake, client_io).nanoseconds;
    const now_ms: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
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
