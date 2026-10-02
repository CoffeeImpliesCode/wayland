//! wp_tearing_control_manager_v1 (staging/tearing-control): lets a client
//! say that a wl_surface's content is suitable for asynchronous page
//! flips (tearing) instead of a vsync-synchronized present.
//!
//! Scope: the manager global + the per-surface wp_tearing_control_v1
//! objects. `get_tearing_control(surface)` attaches an object to a
//! wl_surface (at most one per surface — `tearing_control_exists`, the
//! XML's only declared error), `set_presentation_hint(hint)` records the
//! client's request, and `destroy` releases the object.
//!
//! Keying: by SURFACE, because that is what the protocol extends — the
//! request takes a `wl_surface`, never an output (tearing-control-v1.xml
//! :58-68). wlroots keys the same way: the object is a `wlr_addon` on
//! `wlr_surface->addons` (wlr_tearing_control_v1.c:138) and the lookup
//! `wlr_tearing_control_manager_v1_surface_hint_from_surface`
//! (:217-229) walks that surface's addons. Two consequences this module
//! enforces: (a) wl_surface death drops the entry through a destroy
//! listener, so a recycled Surface address never inherits a dead
//! client's hint; (b) a different role always means a different wl_surface
//! (wayland.xml: the role is assigned once and wl_surface.assign_role
//! refuses a second role, surface.zig/role.zig:57-59), so pruning on
//! wl_surface death is exactly the "role reuse" reset.
//!
//! Double buffering (XML: "This state is double-buffered, see
//! wl_surface.commit"): each object keeps `pending` (the client's latest
//! set_presentation_hint) and `current` (what the compositor honours).
//! `current` moves only at a wl_surface.commit that is actually applied.
//! wlroots gets that from `wlr_surface_synced`, whose state move runs
//! inside `surface_state_move` (wlr_compositor.c:377-383) before the
//! commit signal that `hint_handle_surface_commit`
//! (wlr_tearing_control_v1.c:86-94) listens to; this module runs the same
//! move on `Surface.events.commit`, emitted at the corresponding point of
//! `applyCommit` (surface.zig:636). A commit deferred by a sync subsurface
//! (`cached_state_locks`) does not move the hint, matching wlroots'
//! deferred `surface_cache_pending`.
//!
//! An unknown hint value (one a FUTURE protocol version adds — the XML
//! warns that backward compatible changes come with a version bump,
//! tearing-control-v1.xml:39-42) is stored verbatim, like wlroots
//! (`surface_hint->pending = hint`, no validation,
//! wlr_tearing_control_v1.c:70-75), and classifies as `.vsync`. That
//! keeps the only tearing trigger an explicit `.async`: a client can
//! never reach tearing with a value this server does not understand.
//!
//! OUTPUT GATE (the server wiring must not pretend tearing is free):
//! a `.async` hint is a PERMISSION from the client, not a command. wlroots
//! only takes the asynchronous page-flip path for outputs actually
//! configured for it (the DRM commit must carry
//! DRM_MODE_PAGE_FLIP_ASYNC; without it the flip is vsync'd and the hint
//! has no effect). The present path owns that decision — see the
//! `hintFor` contract. Nothing in this module can or should claim an
//! output tears just because a client asked.
//!
//! Version note: the vendored XML is wp_tearing_control_v1 version 1 and
//! `set_presentation_hint` carries exactly ONE argument, `hint`
//! (tearing-control-v1.xml:103-113; the generated payload is
//! `{ hint: PresentationHint }`). There is NO `sync` boolean and NO
//! `delay_ms` argument anywhere in this version — `delay_ms` only exists
//! in a later interface version, which is why the global is registered at
//! `TearingControlManagerV1.generated_version` and every object is
//! created at the manager's bound version. A client therefore cannot send
//! an argument this server does not decode. Bumping build.zig's
//! `scanner.generate("wp_tearing_control_manager_v1", N)` to a version
//! that adds `delay_ms` must come with handling it here.
//!
//! Cross-module contract: the manager binds per client;
//! get_tearing_control creates a wp_tearing_control_v1 for a wl_surface;
//! surface teardown detaches both listeners and prunes the entry — the
//! state goes inert (its surface is nulled; set_presentation_hint only
//! writes the pending hint and destroy never dereferences it). The
//! resource destroy frees the state (explicit tearing_control.destroy or
//! client teardown; the resource user data carries the state).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const surface_mod = @import("../compositor/surface.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "tearing_control";

// ---------------------------------------------------------------------------
// TearingControl: the wp_tearing_control_manager_v1 global.
// ---------------------------------------------------------------------------

/// What the client asks for, as the present path sees it
/// (wp_tearing_control_v1.presentation_hint). `.async` is the only value
/// that permits tearing; `.vsync` covers both an explicit vsync request
/// and any value a newer protocol version adds (see the module comment).
pub const Hint = enum(u32) {
    /// tearing-control-v1.xml:88-94 — synchronized to the vertical blank.
    vsync = 0,
    /// tearing-control-v1.xml:95-100 — minimal latency, tearing acceptable.
    async = 1,
};

pub const TearingControl = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The manager global, for teardown.
    global: ?*wire.Global = null,
    /// Per-surface tearing-control objects, for the exists check and the
    /// hint lookup. Entries live as long as their resource; a dead
    /// wl_surface prunes its entry (the object outlives the surface, the
    /// presentation Feedback pattern).
    objects: std.ArrayList(*TearState) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) !*TearingControl {
        const tc = try allocator.create(TearingControl);
        errdefer allocator.destroy(tc);
        tc.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .objects = .empty,
        };
        errdefer tc.objects.deinit(allocator);
        tc.global = try display.addGlobal(
            server.wp.TearingControlManagerV1,
            *TearingControl,
            tearingBind,
            server.wp.TearingControlManagerV1.generated_version,
            tc,
        );
        return tc;
    }

    pub fn deinit(self: *TearingControl) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the resources cascades through their destroy
        // handlers, which free the states and prune the list.
        while (self.objects.items.len > 0) self.objects.items[0].res.destroy();
        self.objects.deinit(allocator);
        allocator.destroy(self);
    }

    /// The committed presentation hint for `surface` — the value the
    /// present path acts on. `vsync` when the surface has no tearing
    /// object (wlroots returns VSYNC for a surface without an addon,
    /// wlr_tearing_control_v1.c:222-224).
    ///
    /// Contract for the present path:
    /// - WHO calls it: the frame loop, once per surface per frame, for
    ///   every surface it is about to scan out. It is a pure read — no
    ///   side effects, no listener, safe from any thread that already
    ///   owns the surface list.
    /// - WHAT it means: `.async` = this surface's content may be shown
    ///   with tearing. `.vsync` = present synchronized to vblank.
    /// - COST: one linear walk of the tearing objects, i.e. bounded by
    ///   the number of clients that actually opted in (normally zero —
    ///   the empty list returns on the first iteration). The same shape
    ///   as wlroots' addon lookup.
    /// - WHEN A HINT IS CONSUMED: never. The hint is NOT one-shot — it
    ///   persists over every following present until the client changes
    ///   it, reverts it by destroying its object, or the surface dies.
    ///   Reading it must not clear it: a client that asks for `.async`
    ///   once means "every frame from here", which is what wlroots does
    ///   (nothing consumes the hint; a consumer compares it per frame,
    ///   the sway check in sway/desktop/output.c against
    ///   WP_TEARING_CONTROL_V1_PRESENTATION_HINT_ASYNC). Only the CLIENT
    ///   retires a hint, through set_presentation_hint or destroy.
    /// - OUTPUT GATE: honour `.async` only when the output is configured
    ///   for tearing. On an output that is not, the flip must stay
    ///   vsync'd and the hint is ignored — the permission is not an
    ///   instruction (see the module comment). That decision belongs to
    ///   the present path, not here.
    /// - DOUBLE BUFFERED: this returns the COMMITTED hint. A
    ///   set_presentation_hint with no following wl_surface.commit is
    ///   still pending and invisible here.
    pub fn hintFor(self: *TearingControl, surface: *surface_mod.Surface) Hint {
        for (self.objects.items) |st| {
            // Inert states (dead wl_surface) carry a null surface, so
            // they can never match.
            if (st.surface == surface) return classify(st.current);
        }
        return .vsync;
    }

    /// The present path's one-line form: does this surface ask for
    /// asynchronous presentation? Same contract as `hintFor` — a pure,
    /// non-consuming read.
    pub fn hintingSurface(self: *TearingControl, surface: *surface_mod.Surface) bool {
        return self.hintFor(surface) == .async;
    }
};

/// Per-wl_surface tearing-control state.
const TearState = struct {
    tc: *TearingControl,
    /// The compositor's Surface the object was created for; null once the
    /// surface is destroyed (the state goes inert — set_presentation_hint
    /// only writes the pending hint and destroy never dereferences it).
    surface: ?*surface_mod.Surface,
    /// The wp_tearing_control_v1 resource.
    res: *server.wp.TearingControlV1,
    /// The client's latest set_presentation_hint, not yet committed (the
    /// XML's double-buffered state, wlroots' `pending`).
    pending: u32 = @intFromEnum(Hint.vsync),
    /// The committed hint the present path reads (wlroots' `current`).
    current: u32 = @intFromEnum(Hint.vsync),
    /// Surface-destroy listener: wl_surface death prunes the entry (the
    /// exists check must not false-positive on a recycled address) and
    /// marks the state inert.
    destroy_listener: wire.Listener(*surface_mod.Surface),
    /// Surface-commit listener: moves pending into current, the point the
    /// hint becomes the compositor's answer (wlroots'
    /// hint_handle_surface_commit, wlr_tearing_control_v1.c:86-94).
    commit_listener: wire.Listener(*surface_mod.Surface),
};

/// Classify a stored raw wire value. Only `async` (1) tears; every other
/// value — an explicit vsync and any value a future protocol version adds
/// — is `vsync`, so an unknown value can never enable tearing.
fn classify(raw: u32) Hint {
    return if (raw == @intFromEnum(Hint.async)) .async else .vsync;
}

fn tearingBind(client_wire: *wire.Client, tc: *TearingControl, version: u32, id: u32) void {
    log.info("tearing bind v{d} id={d}", tc.io, tc.log_cfg, log_tag, .{ version, id });
    const manager = server.wp.TearingControlManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    manager.setHandler(*TearingControl, tearingRequest, tearingDestroy, tc);
}

fn tearingRequest(
    manager: *server.wp.TearingControlManagerV1,
    request: server.wp.TearingControlManagerV1.Request,
    tc: *TearingControl,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do. The
        // manager's destruction leaves live wp_tearing_control_v1 objects
        // alone (XML :45-51).
        .destroy => manager.destroy(),
        .get_tearing_control => |r| {
            // The wl_surface resource's user data is the compositor's Surface.
            const surface: *surface_mod.Surface = @ptrCast(@alignCast(r.surface.getUserData()));
            for (tc.objects.items) |st| {
                if (st.surface == surface) {
                    // tearing-control-v1.xml:63-64; wlroots posts the same
                    // error from the same check (wlr_tearing_control_v1.c:102-107).
                    manager.postError(.tearing_control_exists, "wl_surface already has a tearing control object");
                    return;
                }
            }
            // Created at the manager's bound version, so an object can never
            // carry an argument the server does not decode.
            const res = server.wp.TearingControlV1.create(manager.getClient(), manager.getVersion(), r.id) catch {
                manager.postNoMemory();
                return;
            };
            const st = tc.allocator.create(TearState) catch {
                res.destroy();
                manager.postNoMemory();
                return;
            };
            st.* = .{
                .tc = tc,
                .surface = surface,
                .res = res,
                .destroy_listener = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroy),
                .commit_listener = wire.Listener(*surface_mod.Surface).init(onSurfaceCommit),
            };
            // Listener.init leaves the intrusive link undefined; put it in
            // the detached state (prev == next == &link) so the
            // attached-or-not check in detach() is well-defined even for a
            // listener that was never added (surface.zig:374-377).
            st.destroy_listener.link.init();
            st.commit_listener.link.init();
            tc.objects.append(tc.allocator, st) catch {
                tc.allocator.destroy(st);
                res.destroy();
                manager.postNoMemory();
                return;
            };
            res.setHandler(*TearState, tearRequest, tearDestroy, st);
            // Track the surface: wl_surface death must prune this entry
            // and mark the state inert, since the object outlives the
            // surface (presentation Feedback pattern). The commit listener
            // is the double-buffer apply point.
            surface.events.destroy.add(&st.destroy_listener);
            surface.events.commit.add(&st.commit_listener);
            log.debug("tearing control for surface@{d}", tc.io, tc.log_cfg, log_tag, .{
                surface.resource.getId(),
            });
        },
    }
}

fn tearingDestroy(manager: *server.wp.TearingControlManagerV1, tc: *TearingControl) void {
    _ = manager;
    _ = tc;
    // The manager resource dies with the client teardown; per-surface
    // states are freed by their own resource destroy handlers.
}

/// The wl_surface commit was applied: pending becomes current, the point
/// where the client's hint becomes the compositor's answer (wlroots'
/// hint_handle_surface_commit, wlr_tearing_control_v1.c:86-94 — there it
/// only emits a change signal; the state move itself already happened in
/// surface_state_move, wlr_compositor.c:377-383, i.e. just before this
/// signal). An inert state is not on any surface's signal any more.
fn onSurfaceCommit(listener: *wire.Listener(*surface_mod.Surface), _: *surface_mod.Surface) void {
    const st: *TearState = @fieldParentPtr("commit_listener", listener);
    st.current = st.pending;
}

fn tearRequest(res: *server.wp.TearingControlV1, request: server.wp.TearingControlV1.Request, st: *TearState) void {
    switch (request) {
        // tearing-control-v1.xml:115-120: destroying the object reverts the
        // hint to vsync. Dropping the entry achieves exactly that for the
        // lookup: a surface with no object reads vsync
        // (wlr_tearing_control_v1.c:222-224).
        .destroy => res.destroy(),
        .set_presentation_hint => |r| {
            // The payload is the single `hint` argument of this XML
            // version (tearing-control-v1.xml:103-113). c_int back to the
            // raw wire bits, so a value this version does not define is
            // kept verbatim instead of being clamped by the enum's
            // non-exhaustive `_` member (wlroots stores it raw too,
            // wlr_tearing_control_v1.c:74). Still pending until the
            // surface commits.
            st.pending = @bitCast(@as(i32, @intFromEnum(r.hint)));
            log.debug("tearing hint for surface@{d}: {s} (pending)", st.tc.io, st.tc.log_cfg, log_tag, .{
                if (st.surface) |surface| surface.resource.getId() else 0,
                @tagName(classify(st.pending)),
            });
        },
    }
}

/// The wl_surface was destroyed: detach both listeners (a later
/// tearDestroy must not touch the dead surface's listener lists), prune
/// the entry (the exists check must not false-positive on a recycled
/// address) and mark the state inert. The resource is not destroyed — the
/// client owns it; the only remaining requests touch no surface.
fn onSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), _: *surface_mod.Surface) void {
    const st: *TearState = @fieldParentPtr("destroy_listener", listener);
    st.destroy_listener.link.remove();
    // The commit listener lives in this state, which outlives the surface:
    // unlink it now so nothing can walk the freed list (the surface is
    // freed right after this signal).
    detach(&st.commit_listener);
    const tc = st.tc;
    prune(tc, st);
    st.surface = null;
}

fn tearDestroy(res: *server.wp.TearingControlV1, st: *TearState) void {
    _ = res;
    // Detach the surface listeners (resource-first death: client teardown
    // or an explicit destroy while the surface lives — the freed links
    // must not stay in the surface's listener lists). Surface-first death
    // (onSurfaceDestroy) already removed them; the attached-or-not check
    // makes the second remove a no-op.
    detach(&st.destroy_listener);
    detach(&st.commit_listener);
    // Prune the state from the manager's list and free it.
    const tc = st.tc;
    prune(tc, st);
    tc.allocator.destroy(st);
}

/// Remove `listener` from its signal if it is attached. Listener.init
/// leaves the link in the detached state (prev == next == &link), which
/// is how a second remove is recognised (surface.zig:413-417).
fn detach(listener: *wire.Listener(*surface_mod.Surface)) void {
    // `link` IS the intrusive Link, so the self-comparison is against
    // &listener.link — the same helper as session_lock.zig:956.
    if (listener.link.prev != null and listener.link.prev != &listener.link) {
        listener.link.remove();
    }
}

/// Drop `st` from the manager's object list. Tolerates an entry that is
/// already gone (the surface pruned it, or the list was rebuilt), so both
/// death orders converge on one code path.
fn prune(tc: *TearingControl, st: *TearState) void {
    const idx = std.mem.indexOfScalar(*TearState, tc.objects.items, st) orelse return;
    _ = tc.objects.orderedRemove(idx);
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/fractional_scale.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    tearing_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wp_tearing_control_manager_v1")) {
                    data.tearing_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// A compositor + tearing-control manager + in-memory client, for wire
/// roundtrips. The client binds wl_compositor (to create wl_surfaces)
/// and wp_tearing_control_manager_v1.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    tc: ?*TearingControl = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    registry: ?*client.wl.Registry = null,
    /// Registry names seen in the first roundtrip; null when the module
    /// under test did not advertise its global.
    compositor_name: ?u32 = null,
    tearing_name: ?u32 = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_tc_manager: ?*client.wp.TearingControlManagerV1 = null,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor and manager all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        try ts.initDisplay();
        errdefer if (ts.display) |d| d.deinit();
        // The internal wl_shm global (libwayland) must exist before the
        // client's first registry roundtrip so it can bind it for buffers.
        try ts.display.?.initShm();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.tc = try TearingControl.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.tc) |tc| tc.deinit();
        try ts.connect();
        if (ts.compositor_name == null or ts.tearing_name == null) return error.GlobalMissing;
        try ts.bindGlobals();
        return ts;
    }

    /// The same display + tearing manager but with NO client connected:
    /// the state the compositor is in before the first client arrives.
    /// The module must advertise its global and answer lookups on an
    /// empty registry.
    fn initNoClient(allocator: std.mem.Allocator) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        try ts.initDisplay();
        errdefer if (ts.display) |d| d.deinit();
        try ts.display.?.initShm();
        ts.tc = try TearingControl.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.tc) |tc| tc.deinit();
        return ts;
    }

    fn initDisplay(ts: *TestServer) !void {
        ts.display = try display_mod.CompositorDisplay.init(ts.allocator, &ts.io, &ts.log_cfg);
    }

    /// In-memory client connection: one socketpair end for the server,
    /// the other for the client library, plus the registry roundtrip that
    /// records the advertised global names.
    fn connect(ts: *TestServer) !void {
        // SAFETY: written by socketpair() on success, which the errno check
        // below proves before either end is used.
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        const registry = try ts.c_display.?.getRegistry();
        ts.registry = registry;
        var capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
        try ts.pump();
        ts.compositor_name = capture.compositor_name;
        ts.tearing_name = capture.tearing_name;
    }

    /// Bind wl_compositor (for wl_surface) and the tearing-control
    /// manager at the maximum version this XML declares (1).
    fn bindGlobals(ts: *TestServer) !void {
        if (ts.compositor_name) |name| {
            ts.wl_compositor = try ts.registry.?.bind(name, client.wl.Compositor, 7);
        }
        ts.wl_tc_manager = try ts.registry.?.bind(
            ts.tearing_name.?,
            client.wp.TearingControlManagerV1,
            server.wp.TearingControlManagerV1.generated_version,
        );
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers (the
        // tearDestroy for every outstanding object) must run while the
        // tearing-control module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.tc) |tc| tc.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Client flush -> server event loop dispatch -> server flush ->
    /// client dispatch. Drives one roundtrip without blocking.
    fn pump(ts: *TestServer) !void {
        if (ts.c_display.?.flush() != .SUCCESS) return error.ClientFlushFailed;
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                // Protocol error or disconnect: the server has already
                // destroyed its client (dangling) — forget it for deinit.
                ts.client = null;
                return error.ClientDispatchFailed;
            }
        }
    }

    /// The compositor's Surface wrapper behind a client wl_surface.
    fn serverSurface(ts: *TestServer, wl_surface: *client.wl.Surface) *surface_mod.Surface {
        for (ts.compositor.?.surfaces.items) |s| {
            if (s.resource.getId() == wl_surface.getId()) return s;
        }
        unreachable;
    }
};

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

/// The (code, interface name, object id) of the client's last protocol
/// error. Call after ts.pump() failed with ClientDispatchFailed.
const ProtocolError = struct { code: c_int, interface: []const u8, id: u32 };

fn protocolError(ts: *TestServer) ProtocolError {
    var interface: ?*client.wl.Interface = null;
    var id: u32 = 0;
    const code = wl_display_get_protocol_error(ts.c_display.?, @ptrCast(&interface), &id);
    const name = if (interface) |i| std.mem.span(i.name) else "";
    return .{ .code = code, .interface = name, .id = id };
}

test "hint set, committed, read back — and it survives presents" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const tear = try ts.wl_tc_manager.?.getTearingControl(wl_surface);
    try ts.pump();
    const surface = ts.serverSurface(wl_surface);

    // Default is vsync: the object exists but the client asked for nothing.
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface));
    try std.testing.expect(!ts.tc.?.hintingSurface(surface));

    // A hint is double-buffered: set_presentation_hint alone does not
    // change what the compositor honours (XML: "This state is
    // double-buffered, see wl_surface.commit").
    tear.setPresentationHint(.async);
    try ts.pump();
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface));

    // The commit applies it.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface));
    try std.testing.expect(ts.tc.?.hintingSurface(surface));

    // THE READ-API CONTRACT: the hint is not one-shot. Two reads (two
    // presents) return the same value; reading does not consume it.
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface));
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface));

    // Only the client retires it: back to vsync, again via a commit.
    tear.setPresentationHint(.vsync);
    try ts.pump();
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface));
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface));
    try std.testing.expect(!ts.tc.?.hintingSurface(surface));
}

test "destroying the tearing object reverts the hint to vsync" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const tear = try ts.wl_tc_manager.?.getTearingControl(wl_surface);
    tear.setPresentationHint(.async);
    wl_surface.commit();
    try ts.pump();
    const surface = ts.serverSurface(wl_surface);
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface));
    try std.testing.expectEqual(@as(usize, 1), ts.tc.?.objects.items.len);

    // wp_tearing_control_v1.destroy: "revert the presentation hint to
    // vsync" (XML :115-120). Dropping the object makes the lookup answer
    // vsync, the same result wlroots gets from a surface with no addon.
    tear.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.tc.?.objects.items.len);
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface));
    try std.testing.expect(!ts.tc.?.hintingSurface(surface));

    // The surface itself is untouched and usable; a fresh object can be
    // created for it (the exists check must not false-positive).
    _ = try ts.wl_tc_manager.?.getTearingControl(wl_surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.tc.?.objects.items.len);
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface));
}

test "surface destroy drops the hint (no dangling entry, no recycled-address leak)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface_a = try ts.wl_compositor.?.createSurface();
    const tear_a = try ts.wl_tc_manager.?.getTearingControl(wl_surface_a);
    tear_a.setPresentationHint(.async);
    wl_surface_a.commit();
    try ts.pump();
    const surface_a = ts.serverSurface(wl_surface_a);
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface_a));
    try std.testing.expectEqual(@as(usize, 1), ts.tc.?.objects.items.len);

    // wl_surface death: both listeners detach and the entry is pruned. The
    // resource outlives the surface, so the state stays (inert) until the
    // client destroys it.
    wl_surface_a.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.tc.?.objects.items.len);

    // A new surface (the allocator may recycle A's address, and a new
    // wl_surface always means a new role) must start clean: vsync, and
    // the exists check must not reject it.
    const wl_surface_b = try ts.wl_compositor.?.createSurface();
    _ = try ts.wl_tc_manager.?.getTearingControl(wl_surface_b);
    try ts.pump();
    const surface_b = ts.serverSurface(wl_surface_b);
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface_b));
    try std.testing.expectEqual(@as(usize, 1), ts.tc.?.objects.items.len);

    // The client's late destroy of the inert object must not touch the
    // dead surface's listener lists.
    tear_a.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.tc.?.objects.items.len);
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface_b));
}

test "two surfaces hold independent hints" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface_a = try ts.wl_compositor.?.createSurface();
    const wl_surface_b = try ts.wl_compositor.?.createSurface();
    const tear_a = try ts.wl_tc_manager.?.getTearingControl(wl_surface_a);
    const tear_b = try ts.wl_tc_manager.?.getTearingControl(wl_surface_b);
    tear_a.setPresentationHint(.async);
    wl_surface_a.commit();
    try ts.pump();
    const surface_a = ts.serverSurface(wl_surface_a);
    const surface_b = ts.serverSurface(wl_surface_b);

    // Only A committed: B's object exists with the default hint.
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface_a));
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface_b));
    try std.testing.expectEqual(@as(usize, 2), ts.tc.?.objects.items.len);

    // B commits its own hint; A is unaffected.
    tear_b.setPresentationHint(.async);
    wl_surface_b.commit();
    try ts.pump();
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface_a));
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface_b));

    // Destroying B's object leaves A tearing and B vsync.
    tear_b.destroy();
    try ts.pump();
    try std.testing.expectEqual(Hint.async, ts.tc.?.hintFor(surface_a));
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface_b));

    // A's own object is untouched: destroying it clears the last entry.
    tear_a.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.tc.?.objects.items.len);
}

test "a second get_tearing_control on one surface is tearing_control_exists" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    _ = try ts.wl_tc_manager.?.getTearingControl(wl_surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.tc.?.objects.items.len);

    // tearing-control-v1.xml:63-64 — the second object raises the
    // manager's only declared error.
    _ = try ts.wl_tc_manager.?.getTearingControl(wl_surface);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 0), err.code); // tearing_control_exists
    try std.testing.expectEqualStrings("wp_tearing_control_manager_v1", err.interface);
}

test "no client: the manager registers and lookups default to vsync" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.initNoClient(allocator);
    defer ts.deinit();

    // The module is up with no compositor, no seat, no output and no
    // surface registered.
    try std.testing.expect(ts.tc.?.global != null);
    try std.testing.expectEqual(@as(usize, 0), ts.tc.?.objects.items.len);

    // An unknown surface reads vsync and never tears. The pointer is only
    // ever compared, never dereferenced: hintFor returns on the first
    // mismatch and the empty list never compares at all.
    const unknown: *surface_mod.Surface = @ptrFromInt(0x100);
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(unknown));
    try std.testing.expect(!ts.tc.?.hintingSurface(unknown));

    // The global is advertised even with no compositor: a first client
    // must be able to bind it.
    try ts.connect();
    try std.testing.expect(ts.tearing_name != null);
    try std.testing.expectEqual(@as(usize, 0), ts.tc.?.objects.items.len);
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(unknown));
}

test "an unknown hint value never tears (forward-compatible enum growth)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const tear = try ts.wl_tc_manager.?.getTearingControl(wl_surface);
    try ts.pump();
    const surface = ts.serverSurface(wl_surface);

    // 7 is not in this XML's presentation_hint enum. The XML warns that a
    // future version may add values (XML :39-42), so a v1 server must not
    // treat an unknown value as a tearing request.
    tear.setPresentationHint(@enumFromInt(7));
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(Hint.vsync, ts.tc.?.hintFor(surface));
    try std.testing.expect(!ts.tc.?.hintingSurface(surface));

    // The raw value is kept verbatim rather than clamped, like wlroots.
    try std.testing.expectEqual(@as(u32, 7), ts.tc.?.objects.items[0].pending);
    try std.testing.expectEqual(@as(u32, 7), ts.tc.?.objects.items[0].current);
}

test "this XML is version 1: no sync boolean and no delay_ms argument" {
    // The vendored tearing-control-v1.xml declares interface version 1 and
    // set_presentation_hint with exactly one argument, `hint`. If the
    // generated protocol is ever bumped past v1 the payload gains fields
    // this server does not decode — fail here instead of silently ignoring
    // what a client sent.
    try std.testing.expectEqual(@as(u32, 1), server.wp.TearingControlManagerV1.generated_version);
    try std.testing.expectEqual(@as(u32, 1), server.wp.TearingControlV1.generated_version);

    const payload = @FieldType(server.wp.TearingControlV1.Request, "set_presentation_hint");
    const has_hint = @hasField(payload, "hint");
    const has_sync = @hasField(payload, "sync");
    const has_delay_ms = @hasField(payload, "delay_ms");
    try std.testing.expect(has_hint);
    try std.testing.expect(!has_sync);
    try std.testing.expect(!has_delay_ms);

    // wp_tearing_control_manager_v1 declares exactly one error,
    // tearing_control_exists = 0 (XML :53-56).
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(server.wp.TearingControlManagerV1.Error.tearing_control_exists));
}
