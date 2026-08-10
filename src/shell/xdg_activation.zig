//! xdg_activation_v1 (staging/xdg-activation): the xdg_activation_v1 global
//! plus the xdg_activation_token_v1 state machine.
//!
//! Flow: get_activation_token -> optional set_serial / set_app_id /
//! set_surface -> commit -> done(random 32-hex token string) -> the client
//! forwards the token out of band -> activate(token, surface) -> the
//! compositor's `events.request_activate` fires with the known token.
//!
//! Model decisions (audit-verified vs wlroots types/wlr_xdg_activation_v1.c,
//! smithay xdg_activation/, KWin xdgactivation_v1.cpp; XML ground truth
//! protocols/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml):
//! - (a) commit is one-shot: any set_serial/set_app_id/set_surface/commit
//!   after commit posts already_used=0.
//! - (b) validation at commit: a set serial must equal the seat's last
//!   serial (data_device.zig model; wlroots keeps a per-client serial ring)
//!   and a set surface must be the seat's current keyboard- or
//!   pointer-focused surface. On failure the done() event still fires, but
//!   with a random token the compositor will never accept, and the token is
//!   dropped from the activation registry (the client cannot distinguish).
//! - (c) activate() with an unknown token is silently ignored (never an
//!   error).
//! - (d) single use: a used token is destroyed (wlroots model); a second
//!   activate() with the same token is ignored.
//! - (e) expiry: a 30s one-shot event-loop timer per token (wire loop
//!   timers, cf. backend/headless.zig re-arming).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const surface_mod = @import("../compositor/surface.zig");
const seat_mod = @import("../compositor/seat.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "xdg_activation";

/// Token validity window, ms (wlroots: 30s, wlr_xdg_activation_v1.c).
const token_timeout_ms = 30_000;

// ---------------------------------------------------------------------------
// XdgActivation: the xdg_activation_v1 global.
// ---------------------------------------------------------------------------

/// activate(token, surface) with a known token. The token string is borrowed
/// from the token and valid only for the duration of the emit; the surface
/// is the compositor's Surface wrapper.
pub const ActivateRequest = struct {
    token: []const u8,
    surface: *surface_mod.Surface,
};

pub const XdgActivation = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The seat whose input serials and focus validate tokens (single-seat
    /// server).
    seat: *seat_mod.Seat,
    /// The compositor: resolves wl_surface resources for activate().
    compositor: *compositor_mod.Compositor,
    /// The xdg_activation_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// Committed, valid, unused tokens, in creation order.
    tokens: std.ArrayList(*ActivationToken),
    /// PRNG seed counter (mixed into the clock seed so rapid commits get
    /// distinct token strings).
    seed_counter: u64 = 0,
    events: struct {
        request_activate: wire.Signal(*ActivateRequest),
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        seat: *seat_mod.Seat,
        compositor: *compositor_mod.Compositor,
    ) !*XdgActivation {
        const activation = try allocator.create(XdgActivation);
        errdefer allocator.destroy(activation);
        activation.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .seat = seat,
            .compositor = compositor,
            .tokens = .empty,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        errdefer activation.tokens.deinit(allocator);
        activation.events.request_activate.init();

        // Register xdg_activation_v1 at the maximum version we implement.
        activation.global = try display.addGlobal(
            server.xdg.ActivationV1,
            *XdgActivation,
            activationBind,
            server.xdg.ActivationV1.generated_version,
            activation,
        );
        return activation;
    }

    pub fn deinit(self: *XdgActivation) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the wire resources cascades through their destroy
        // handlers, which remove entries from the list and free the objects
        // (and cancel their expiry timers).
        while (self.tokens.items.len > 0) self.tokens.items[0].resource.destroy();
        self.tokens.deinit(allocator);
        // The activation global itself is owned by the display's registry.
        allocator.destroy(self);
    }
};

fn activationBind(client_wire: *wire.Client, activation: *XdgActivation, version: u32, id: u32) void {
    const activation_res = server.xdg.ActivationV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    activation_res.setHandler(*XdgActivation, activationRequest, null, activation);
}

fn activationRequest(
    activation_res: *server.xdg.ActivationV1,
    request: server.xdg.ActivationV1.Request,
    activation: *XdgActivation,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => activation_res.destroy(),
        .get_activation_token => |r| {
            const res = server.xdg.ActivationTokenV1.create(
                activation_res.getClient(),
                activation_res.getVersion(),
                r.id,
            ) catch {
                activation_res.postNoMemory();
                return;
            };
            const token = activation.allocator.create(ActivationToken) catch {
                res.destroy();
                activation_res.postNoMemory();
                return;
            };
            token.* = .{
                .allocator = activation.allocator,
                .io = activation.io,
                .log_cfg = activation.log_cfg,
                .activation = activation,
                .resource = res,
            };
            res.setHandler(*ActivationToken, tokenRequest, tokenDestroy, token);
        },
        .activate => |r| activationActivate(activation, std.mem.span(r.token), r.surface),
    }
}

/// xdg_activation_v1.activate: forward a known token to the compositor.
/// Unknown tokens are silently ignored; a used token is destroyed after its
/// single delivery (model decisions (c) and (d)).
fn activationActivate(activation: *XdgActivation, token_str: []const u8, surface_res: *server.wl.Surface) void {
    const token = findToken(activation, token_str) orelse {
        log.debug("activate: unknown token ignored", activation.io, activation.log_cfg, log_tag, .{});
        return;
    };
    // Resolve the wire surface to the compositor's Surface wrapper. A
    // surface the compositor no longer knows is treated like an unknown
    // token (the client cannot legitimately produce one).
    const surface = surfaceForResource(activation, surface_res) orelse {
        token.resource.destroy();
        return;
    };
    var req: ActivateRequest = .{
        .token = token_str,
        .surface = surface,
    };
    activation.events.request_activate.emit(&req);
    // Single use: the token is destroyed after the delivery (wlroots model).
    token.resource.destroy();
}

// ---------------------------------------------------------------------------
// ActivationToken: xdg_activation_token_v1.
// ---------------------------------------------------------------------------

const ActivationToken = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    activation: *XdgActivation,
    resource: *server.xdg.ActivationTokenV1,
    /// Whether commit already ran: further set_*/commit posts already_used.
    committed: bool = false,
    /// The token string (32 hex chars + NUL), set at commit.
    token_buf: [32:0]u8 = undefined,
    /// Validation failed at commit: done() was sent with this random token
    /// but the token was dropped from the registry (model decision (b)).
    invalid: bool = false,
    /// Pending (pre-commit) fields.
    serial: ?u32 = null,
    surface_res: ?*server.wl.Surface = null,
    /// Pending app_id (owned; set_app_id before commit).
    app_id: ?[]const u8 = null,
    /// The 30s expiry timer (created at commit, model decision (e)).
    timer: ?*wire.EventSource = null,
};

fn tokenRequest(
    token_res: *server.xdg.ActivationTokenV1,
    request: server.xdg.ActivationTokenV1.Request,
    token: *ActivationToken,
) void {
    switch (request) {
        .set_serial => |r| {
            // Model decision (a): commit is one-shot.
            if (token.committed) {
                token.resource.postError(.already_used, "set_serial after commit");
                return;
            }
            token.serial = r.serial;
        },
        .set_app_id => |r| {
            if (token.committed) {
                token.resource.postError(.already_used, "set_app_id after commit");
                return;
            }
            const copy = token.allocator.dupe(u8, std.mem.span(r.app_id)) catch {
                token.resource.postNoMemory();
                return;
            };
            if (token.app_id) |old| token.allocator.free(old);
            token.app_id = copy;
        },
        .set_surface => |r| {
            if (token.committed) {
                token.resource.postError(.already_used, "set_surface after commit");
                return;
            }
            token.surface_res = r.surface;
        },
        .commit => tokenCommit(token),
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => token_res.destroy(),
    }
}

fn tokenDestroy(token_res: *server.xdg.ActivationTokenV1, token: *ActivationToken) void {
    _ = token_res;
    const activation = token.activation;
    if (std.mem.findScalar(*ActivationToken, activation.tokens.items, token)) |i| {
        _ = activation.tokens.swapRemove(i);
    }
    if (token.timer) |timer| timer.remove();
    if (token.app_id) |app_id| token.allocator.free(app_id);
    token.allocator.destroy(token);
}

/// xdg_activation_token_v1.commit: generate the token, validate the pending
/// parameters, register the token and send done() (model decisions (a)/(b)).
fn tokenCommit(token: *ActivationToken) void {
    if (token.committed) {
        token.resource.postError(.already_used, "commit after commit");
        return;
    }
    token.committed = true;

    // A random-looking token is always generated; on validation failure the
    // done() event still carries one, but the token is not registered, so
    // activate() of it is silently ignored (model decision (b)).
    const token_str = generateToken(token);
    if (!tokenValid(token)) {
        token.invalid = true;
        log.debug("commit: invalid token parameters, dropping token", token.io, token.log_cfg, log_tag, .{});
        token.resource.sendDone(&token_str);
        return;
    }
    token.token_buf = token_str;
    const activation = token.activation;

    // 30s expiry timer (model decision (e)): a one-shot source; the
    // callback removes it and drops the token.
    const timer = activation.display.getServer().getEventLoop().addTimer(*ActivationToken, tokenTimeout, token) catch {
        token.resource.postNoMemory();
        return;
    };
    timer.timerUpdate(token_timeout_ms) catch {
        timer.remove();
        token.resource.postNoMemory();
        return;
    };
    token.timer = timer;

    activation.tokens.append(activation.allocator, token) catch {
        timer.remove();
        token.timer = null;
        token.resource.postNoMemory();
        return;
    };
    log.info("commit: token registered, app_id={s}", token.io, token.log_cfg, log_tag, .{
        token.app_id orelse "(none)",
    });
    token.resource.sendDone(&token.token_buf);
}

/// Model decision (b): a set serial must be the seat's most recent serial
/// (data_device.zig equality rule), and a set surface must be the seat's
/// current keyboard- or pointer-focused surface.
fn tokenValid(token: *ActivationToken) bool {
    const activation = token.activation;
    if (token.serial) |serial| {
        if (serial != activation.seat.last_serial) return false;
    }
    if (token.surface_res) |surface_res| {
        const surface = surfaceForResource(activation, surface_res) orelse return false;
        const seat = activation.seat;
        if (seat.keyboard_focus != surface and seat.pointer_focus != surface) return false;
    }
    return true;
}

/// The 30s window expired: drop the token (wlroots destroys the token on
/// timeout). The loop ignores the return value for timers (libwayland
/// 1.24 disarms before dispatch); headless.zig's frame callback also
/// returns 1.
fn tokenTimeout(token: *ActivationToken) c_int {
    if (token.timer) |timer| timer.remove();
    token.timer = null;
    token.resource.destroy();
    return 1;
}

fn findToken(activation: *XdgActivation, token_str: []const u8) ?*ActivationToken {
    for (activation.tokens.items) |token| {
        if (std.mem.eql(u8, token_str, token.token_buf[0..32])) return token;
    }
    return null;
}

/// Resolve a wl_surface wire resource to the compositor's Surface wrapper.
fn surfaceForResource(activation: *XdgActivation, surface_res: *server.wl.Surface) ?*surface_mod.Surface {
    for (activation.compositor.surfaces.items) |s| {
        if (s.resource == surface_res) return s;
    }
    return null;
}

/// Generate a 32-lowercase-hex token string (16 random bytes). [INFERENCE:
/// wlroots uses getrandom(2); this server has no direct CSPRNG access in
/// zig 0.16 std (std.crypto.random removed), so Xoshiro256 seeded from the
/// monotonic clock + a counter stands in.]
fn generateToken(token: *ActivationToken) [32:0]u8 {
    token.activation.seed_counter +%= 1;
    const now_ns: u64 = @intCast(std.Io.Clock.now(.awake, token.io.*).nanoseconds);
    var prng = std.Random.DefaultPrng.init(now_ns ^ (token.activation.seed_counter *% 0x9E3779B97F4A7C15));
    var bytes: [16]u8 = undefined;
    prng.fill(&bytes);
    var out: [32:0]u8 = undefined;
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

// --- socketpair roundtrip harness (pattern: src/shell/xdg.zig) ------------

const posix = std.posix;

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,
    activation_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "xdg_activation_v1")) {
                    data.activation_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

const TokenEvents = struct {
    done_count: usize = 0,
    /// The last done() token (NUL-terminated copy).
    token: [33]u8 = undefined,

    fn listener(
        token: *client.xdg.ActivationTokenV1,
        event: client.xdg.ActivationTokenV1.Event,
        data: *TokenEvents,
    ) void {
        _ = token;
        switch (event) {
            .done => |d| {
                data.done_count += 1;
                const s = std.mem.span(d.token);
                const n = @min(s.len, data.token.len - 1);
                @memcpy(data.token[0..n], s[0..n]);
                data.token[n] = 0;
            },
        }
    }
};

const ActivateCapture = struct {
    count: usize = 0,
    /// The last request_activate token (NUL-terminated copy).
    token: [33]u8 = undefined,
    surface: ?*surface_mod.Surface = null,
    listener: wire.Listener(*ActivateRequest),

    fn notify(listener: *wire.Listener(*ActivateRequest), req: *ActivateRequest) void {
        const cap: *ActivateCapture = @fieldParentPtr("listener", listener);
        cap.count += 1;
        const n = @min(req.token.len, cap.token.len - 1);
        @memcpy(cap.token[0..n], req.token[0..n]);
        cap.token[n] = 0;
        cap.surface = req.surface;
    }
};

/// A full compositor + seat + activation + in-memory client, for wire
/// roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    activation: ?*XdgActivation = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_seat: ?*client.wl.Seat = null,
    activation_client: ?*client.xdg.ActivationV1 = null,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor and shell all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.seat) |s| s.deinit();
        ts.activation = try XdgActivation.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.seat.?,
            ts.compositor.?,
        );
        errdefer if (ts.activation) |a| a.deinit();

        // In-memory client connection: one socketpair end for the server,
        // the other for the client library.
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        // Round 1: registry + global announcements.
        const registry = try ts.c_display.?.getRegistry();
        var capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
        try ts.pump();
        if (capture.compositor_name == null or
            capture.seat_name == null or
            capture.activation_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor, wl_seat and xdg_activation_v1.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
        ts.activation_client = try registry.bind(capture.activation_name.?, client.xdg.ActivationV1, 1);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.activation) |a| a.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Client flush -> server event loop dispatch -> server flush -> client
    /// dispatch. Drives one roundtrip without blocking.
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

    /// The server-side Surface created by the client for `wl_surface`.
    fn surfaceForClient(ts: *TestServer, wl_surface: *client.wl.Surface) *surface_mod.Surface {
        for (ts.compositor.?.surfaces.items) |s| {
            if (s.resource.getId() == wl_surface.getId()) return s;
        }
        unreachable;
    }
};

test "activation token commit -> done -> activate fires once" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: ActivateCapture = .{
        .listener = wire.Listener(*ActivateRequest).init(ActivateCapture.notify),
    };
    ts.activation.?.events.request_activate.add(&capture.listener);

    const surface = try ts.wl_compositor.?.createSurface();
    var token_events: TokenEvents = .{};
    const token = try ts.activation_client.?.getActivationToken();
    token.setListener(*TokenEvents, TokenEvents.listener, &token_events);

    // No serial/surface set: the token validates trivially.
    token.commit();
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), token_events.done_count);
    try std.testing.expectEqual(@as(usize, 32), std.mem.sliceTo(&token_events.token, 0).len);
    const token_str = std.mem.sliceTo(&token_events.token, 0);
    try std.testing.expectEqual(@as(usize, 1), ts.activation.?.tokens.items.len);

    // activate with the known token: request_activate fires once.
    ts.activation_client.?.activate(@ptrCast(&token_events.token), surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings(token_str, std.mem.sliceTo(&capture.token, 0));
    try std.testing.expectEqual(ts.surfaceForClient(surface), capture.surface);

    // The token was consumed: a second activate with the same token is
    // ignored, and the token list is empty.
    ts.activation_client.?.activate(@ptrCast(&token_events.token), surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(usize, 0), ts.activation.?.tokens.items.len);
}

test "activation bogus serial -> invalid done token, activate ignored" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: ActivateCapture = .{
        .listener = wire.Listener(*ActivateRequest).init(ActivateCapture.notify),
    };
    ts.activation.?.events.request_activate.add(&capture.listener);

    const surface = try ts.wl_compositor.?.createSurface();
    var token_events: TokenEvents = .{};
    const token = try ts.activation_client.?.getActivationToken();
    token.setListener(*TokenEvents, TokenEvents.listener, &token_events);

    // No input has ever occurred, so the seat's last serial is 0; a serial
    // the seat never issued fails validation at commit.
    token.setSerial(1, ts.wl_seat.?);
    token.commit();
    try ts.pump();

    // done() still fires with a random-looking token...
    try std.testing.expectEqual(@as(usize, 1), token_events.done_count);
    try std.testing.expectEqual(@as(usize, 32), std.mem.sliceTo(&token_events.token, 0).len);
    // ...but the token was dropped (bogus serial).
    try std.testing.expectEqual(@as(usize, 0), ts.activation.?.tokens.items.len);

    // activate() of the invalid token is silently ignored.
    ts.activation_client.?.activate(@ptrCast(&token_events.token), surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), capture.count);
}

test "activation post-commit set_app_id -> already_used" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const token = try ts.activation_client.?.getActivationToken();
    token.commit();
    try ts.pump();

    // Model decision (a): commit is one-shot; any later setter posts
    // already_used=0 and the client is killed.
    token.setAppId("com.example.app");
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "activation unknown token -> no error, no event" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: ActivateCapture = .{
        .listener = wire.Listener(*ActivateRequest).init(ActivateCapture.notify),
    };
    ts.activation.?.events.request_activate.add(&capture.listener);

    const surface = try ts.wl_compositor.?.createSurface();
    // A token the compositor never issued: silently ignored (model
    // decision (c)); the connection stays healthy.
    ts.activation_client.?.activate("deadbeefdeadbeefdeadbeefdeadbeef", surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expectEqual(@as(usize, 0), ts.activation.?.tokens.items.len);
}
