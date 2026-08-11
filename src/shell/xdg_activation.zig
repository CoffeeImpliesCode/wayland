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
//! - (b) validation at commit: a set serial must have been given to the
//!   token's client (the seat's per-client serial ring,
//!   seat.validateEventSerial; wlroots wlr_seat_client_validate_event_serial).
//!   The surface-focus constraint applies only when a serial was set — a
//!   set surface must then be the seat's current keyboard- or
//!   pointer-focused surface (wlroots checks focus only inside
//!   `if (token->seat != NULL)`, wlr_xdg_activation_v1.c:108-123; A1), and
//!   a surface destroyed before commit drops the constraint (XA-2, wlroots
//!   surface-destroy listener). On failure the done() event still fires,
//!   but with a random token the compositor will never accept, and the
//!   token is dropped from the activation registry (the client cannot
//!   distinguish).
//! - (c) activate() with an unknown token is silently ignored (never an
//!   error).
//! - (d) single use: a used token is consumed (wlroots model): the object
//!   is freed and the creating client's token resource is made inert with
//!   a no-op handler, so the client's later destroy is a silent no-op
//!   (wlroots inerts the resource, wlr_xdg_activation_v1.c:104-106; A2); a
//!   second activate() with the same token is ignored.
//! - (e) expiry: a 30s one-shot event-loop timer per token (wire loop
//!   timers, cf. backend/headless.zig re-arming).
//! - (f) a successfully committed token fires `events.new_token` before
//!   done() (wlroots events.new_token, XA:141): the compositor can observe
//!   token creation (app_id allowlists, telemetry). Failed commits do not
//!   fire it.
//! - (g) compositor-side external tokens (XA-3): createToken()/addToken()
//!   make tokens with no wire resource (wlroots
//!   wlr_xdg_activation_token_v1_create / wlr_xdg_activation_v1_add_token)
//!   for portal-style activation; they register immediately and are
//!   consumed by activateToken() or findToken(). createToken() starts the
//!   30s expiry; addToken() does not (wlroots parity).
//! - (h) set_serial's seat argument is validated (XA-5): an inert or
//!   foreign seat resource rejects the set_serial (wlroots XA:186-199) —
//!   the serial is not stored, so commit validates nothing.

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
    events: struct {
        request_activate: wire.Signal(*ActivateRequest),
        /// A token was created and committed successfully (before done()).
        /// The token is already in the registry; the compositor may read
        /// its name/app_id/surface (wlroots events.new_token, XA:141).
        new_token: wire.Signal(*ActivationToken),
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
        activation.events.new_token.init();

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
        // (and cancel their expiry timers). Compositor-created tokens (no
        // wire resource) are freed directly.
        while (self.tokens.items.len > 0) {
            const token = self.tokens.items[0];
            if (token.resource) |res| {
                res.destroy();
            } else {
                destroyToken(token);
            }
        }
        self.tokens.deinit(allocator);
        // The activation global itself is owned by the display's registry.
        allocator.destroy(self);
    }

    /// Compositor-side token creation (wlroots
    /// wlr_xdg_activation_token_v1_create): a token with a fresh CSPRNG
    /// name and the 30s expiry, no wire resource (model decision (g)).
    pub fn createToken(self: *XdgActivation) !*ActivationToken {
        const token = try self.allocator.create(ActivationToken);
        errdefer self.allocator.destroy(token);
        token.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .log_cfg = self.log_cfg,
            .activation = self,
            .resource = null,
            .surface_listener = wire.Listener(*surface_mod.Surface).init(onTokenSurfaceDestroy),
        };
        const token_str = generateToken(token) orelse return error.RandomUnavailable;
        token.token_buf = token_str;
        try self.registerToken(token);
        return token;
    }

    /// Compositor-side external token with a known name (wlroots
    /// wlr_xdg_activation_v1_add_token, XA:422-435): portal-style tokens
    /// arrive out of band. The name must be the 32-hex format; unlike
    /// createToken no expiry timer is started (wlroots parity).
    pub fn addToken(self: *XdgActivation, token_str: []const u8) !*ActivationToken {
        if (token_str.len != 32) return error.InvalidTokenName;
        const token = try self.allocator.create(ActivationToken);
        errdefer self.allocator.destroy(token);
        token.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .log_cfg = self.log_cfg,
            .activation = self,
            .resource = null,
            .surface_listener = wire.Listener(*surface_mod.Surface).init(onTokenSurfaceDestroy),
        };
        @memcpy(token.token_buf[0..32], token_str[0..32]);
        self.tokens.append(self.allocator, token) catch return error.OutOfMemory;
        return token;
    }

    /// Registry lookup by token name (wlroots wlr_xdg_activation_v1_find_token).
    pub fn findToken(self: *XdgActivation, token_str: []const u8) ?*ActivationToken {
        for (self.tokens.items) |token| {
            if (std.mem.eql(u8, token_str, token.token_buf[0..32])) return token;
        }
        return null;
    }

    /// Compositor-side activate (wlroots wlr_xdg_activation_v1_activate):
    /// deliver the token's activation request and consume the token
    /// (single-use, model decision (d)).
    pub fn activateToken(self: *XdgActivation, token: *ActivationToken, surface: *surface_mod.Surface) void {
        var req: ActivateRequest = .{
            .token = token.token_buf[0..32],
            .surface = surface,
        };
        self.events.request_activate.emit(&req);
        if (token.resource) |res| {
            res.destroy();
        } else {
            destroyToken(token);
        }
    }

    /// Register a token in the registry and start its 30s expiry timer
    /// (wlroots token_init, XA:63-91). On failure the timer is cancelled.
    fn registerToken(self: *XdgActivation, token: *ActivationToken) !void {
        const timer = self.display.getServer().getEventLoop().addTimer(*ActivationToken, tokenTimeout, token) catch {
            return error.AddTimerFailed;
        };
        timer.timerUpdate(token_timeout_ms) catch {
            timer.remove();
            return error.AddTimerFailed;
        };
        token.timer = timer;
        self.tokens.append(self.allocator, token) catch {
            timer.remove();
            token.timer = null;
            return error.OutOfMemory;
        };
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
                .surface_listener = wire.Listener(*surface_mod.Surface).init(onTokenSurfaceDestroy),
            };
            res.setHandler(*ActivationToken, tokenRequest, tokenDestroy, token);
        },
        .activate => |r| activationActivate(activation, std.mem.span(r.token), r.surface),
    }
}

/// xdg_activation_v1.activate: forward a known token to the compositor.
/// Unknown tokens are silently ignored; a used token is consumed after its
/// single delivery — the creating client's token resource is made inert
/// (wlroots inerts the resource, wlr_xdg_activation_v1.c:104-106) so the
/// client's later destroy is a silent no-op (model decisions (c) and (d)).
fn activationActivate(activation: *XdgActivation, token_str: []const u8, surface_res: *server.wl.Surface) void {
    const token = activation.findToken(token_str) orelse {
        log.debug("activate: unknown token ignored", activation.io, activation.log_cfg, log_tag, .{});
        return;
    };
    // Resolve the wire surface to the compositor's Surface wrapper. A
    // surface the compositor no longer knows is treated like an unknown
    // token (the client cannot legitimately produce one); the token is
    // consumed here too (inert + free, same as the delivery path).
    const surface = surfaceForResource(activation, surface_res) orelse {
        if (token.resource) |res| {
            // Inert with a live no-op handler before freeing the struct: a
            // null dispatcher would make libwayland abort the compositor on
            // the client's next request (wayland-server.c wl_closure_invoke).
            res.setHandler(?*ActivationToken, deadTokenHandler, null, null);
        }
        destroyToken(token);
        return;
    };
    var req: ActivateRequest = .{
        .token = token_str,
        .surface = surface,
    };
    activation.events.request_activate.emit(&req);
    // Single use: the token is consumed after the delivery (wlroots model).
    // Inert the creating client's resource BEFORE freeing the object — with
    // a live no-op handler, not a null dispatcher (a null dispatcher makes
    // libwayland abort the compositor on the client's next request,
    // wayland-server.c wl_closure_invoke; the live handler keeps the
    // client's later destroy a silent destroy of the wire resource) — then
    // destroyToken (registry unlink, timer cancel, free).
    if (token.resource) |res| {
        res.setHandler(?*ActivationToken, deadTokenHandler, null, null);
    }
    destroyToken(token);
}

// ---------------------------------------------------------------------------
// ActivationToken: xdg_activation_token_v1 (+ compositor-created tokens).
// ---------------------------------------------------------------------------

pub const ActivationToken = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    activation: *XdgActivation,
    /// The wire resource, or null for compositor-created tokens (XA-3,
    /// model decision (g)).
    resource: ?*server.xdg.ActivationTokenV1 = null,
    /// Whether commit already ran: further set_*/commit posts already_used
    /// (internal tokens only).
    committed: bool = false,
    /// The token string (32 hex chars + NUL), set at commit / creation.
    token_buf: [32:0]u8 = undefined,
    /// Validation failed at commit: done() was sent with this random token
    /// but the token was dropped from the registry (model decision (b)).
    invalid: bool = false,
    /// Pending (pre-commit) fields.
    serial: ?u32 = null,
    /// The seat from set_serial's seat argument (XA-5); null = not set
    /// (or the seat was inert/foreign and the set_serial was rejected).
    seat: ?*seat_mod.Seat = null,
    /// The surface the token is bound to, if set and alive (XA-2); the
    /// surface-destroy listener nulls it, dropping the focus constraint
    /// (wlroots XA:202-208).
    surface: ?*surface_mod.Surface = null,
    /// The surface's destroy listener (attached while `surface` != null).
    surface_listener: wire.Listener(*surface_mod.Surface),
    /// Pending app_id (owned; set_app_id before commit).
    app_id: ?[]const u8 = null,
    /// The 30s expiry timer (created at commit / createToken, model
    /// decision (e)).
    timer: ?*wire.EventSource = null,

    /// The token's name (32 hex chars) (wlroots
    /// wlr_xdg_activation_token_v1_get_name, XA:417-420).
    pub fn getName(token: *const ActivationToken) []const u8 {
        return token.token_buf[0..32];
    }
};

/// The surface the token was bound to was destroyed before commit: drop the
/// constraint (XA-2, wlroots token_handle_surface_destroy XA:202-208) — the
/// token stays valid.
fn onTokenSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), surface: *surface_mod.Surface) void {
    _ = surface;
    const token: *ActivationToken = @fieldParentPtr("surface_listener", listener);
    token.surface_listener.link.remove();
    token.surface = null;
}

/// Request handler for inerted (consumed) activation tokens: the
/// ActivationToken struct is freed, so nothing is dereferenced — every
/// request is a silent no-op (wlroots inerts the resource on activate,
/// wlr_xdg_activation_v1.c:104-106). The destroy callback is null, so
/// client teardown cannot call into the freed struct; the client's own
/// destroy destroys the wire resource (libwayland dispatches the
/// destructor like any other request — a NULL dispatcher would abort the
/// compositor, wayland-server.c wl_closure_invoke).
fn deadTokenHandler(
    token_res: *server.xdg.ActivationTokenV1,
    request: server.xdg.ActivationTokenV1.Request,
    data: ?*ActivationToken,
) void {
    _ = data;
    switch (request) {
        .destroy => token_res.destroy(),
        .set_serial => {},
        .set_app_id => {},
        .set_surface => {},
        .commit => {},
    }
}

fn tokenRequest(
    token_res: *server.xdg.ActivationTokenV1,
    request: server.xdg.ActivationTokenV1.Request,
    token: *ActivationToken,
) void {
    switch (request) {
        .set_serial => |r| {
            // Model decision (a): commit is one-shot.
            if (token.committed) {
                token.resource.?.postError(.already_used, "set_serial after commit");
                return;
            }
            // XA-5: the seat argument must map to a live seat (wlroots
            // XA:186-199). An inert or foreign seat rejects the set_serial:
            // no serial is stored, so commit validates nothing.
            const seat_ud = r.seat.getUserData() orelse {
                log.debug("set_serial: seat is inert, ignoring", token.io, token.log_cfg, log_tag, .{});
                return;
            };
            const seat: *seat_mod.Seat = @ptrCast(@alignCast(seat_ud));
            if (seat != token.activation.seat) {
                log.debug("set_serial: seat is not the server seat, ignoring", token.io, token.log_cfg, log_tag, .{});
                return;
            }
            token.seat = seat;
            token.serial = r.serial;
        },
        .set_app_id => |r| {
            if (token.committed) {
                token.resource.?.postError(.already_used, "set_app_id after commit");
                return;
            }
            const copy = token.allocator.dupe(u8, std.mem.span(r.app_id)) catch {
                token.resource.?.postNoMemory();
                return;
            };
            if (token.app_id) |old| token.allocator.free(old);
            token.app_id = copy;
        },
        .set_surface => |r| {
            if (token.committed) {
                token.resource.?.postError(.already_used, "set_surface after commit");
                return;
            }
            // XA-2: track the surface's lifetime (wlroots XA:202-208); a
            // surface destroyed before commit drops the constraint instead
            // of failing it. The resource is live at dispatch, so the
            // compositor Surface exists.
            const surface = surfaceForResource(token.activation, r.surface) orelse {
                token.surface = null;
                return;
            };
            if (token.surface) |old| {
                if (old == surface) return;
                token.surface_listener.link.remove();
            }
            token.surface = surface;
            surface.events.destroy.add(&token.surface_listener);
        },
        .commit => tokenCommit(token),
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => token_res.destroy(),
    }
}

/// Free a token: unlink from the registry, detach the surface listener,
/// cancel the timer, free owned strings and the object. Valid when the
/// wire resource is already destroyed (internal tokens, invoked from the
/// resource destroy handler), absent (external tokens), or made inert
/// first (activate(), A2 — the live-but-inert resource keeps the client's
/// later destroy a silent no-op).
fn destroyToken(token: *ActivationToken) void {
    const activation = token.activation;
    if (std.mem.findScalar(*ActivationToken, activation.tokens.items, token)) |i| {
        _ = activation.tokens.swapRemove(i);
    }
    if (token.timer) |timer| timer.remove();
    if (token.surface != null) {
        token.surface_listener.link.remove();
        token.surface = null;
    }
    if (token.app_id) |app_id| token.allocator.free(app_id);
    token.allocator.destroy(token);
}

/// Resource destroy handler (internal tokens): the resource is already
/// being destroyed; only the object needs cleanup.
fn tokenDestroy(token_res: *server.xdg.ActivationTokenV1, token: *ActivationToken) void {
    _ = token_res;
    destroyToken(token);
}

/// xdg_activation_token_v1.commit: generate the token, validate the pending
/// parameters, register the token and send done() (model decisions (a)/(b)).
fn tokenCommit(token: *ActivationToken) void {
    if (token.committed) {
        token.resource.?.postError(.already_used, "commit after commit");
        return;
    }
    token.committed = true;
    const res = token.resource orelse return; // external tokens never commit

    // A random-looking token is always generated; on validation failure the
    // done() event still carries one, but the token is not registered, so
    // activate() of it is silently ignored (model decision (b)).
    const token_str = generateToken(token) orelse {
        res.postNoMemory();
        return;
    };
    if (!tokenValid(token)) {
        token.invalid = true;
        log.debug("commit: invalid token parameters, dropping token", token.io, token.log_cfg, log_tag, .{});
        res.sendDone(&token_str);
        return;
    }
    token.token_buf = token_str;
    const activation = token.activation;

    // 30s expiry timer + registry insert (model decision (e)).
    activation.registerToken(token) catch {
        res.postNoMemory();
        return;
    };
    log.info("commit: token registered, app_id={s}", token.io, token.log_cfg, log_tag, .{
        token.app_id orelse "(none)",
    });
    // XA-1: compositor-visible token-creation hook (wlroots
    // events.new_token, XA:141), emitted before done() and only for
    // successful commits.
    activation.events.new_token.emit(token);
    res.sendDone(&token.token_buf);
}

/// Model decision (b): a set serial must have been given to the token's
/// client (the seat's per-client serial ring, seat.validateEventSerial —
/// wlroots wlr_seat_client_validate_event_serial). The surface-focus
/// constraint applies ONLY when a serial was set: wlroots checks focus
/// only inside `if (token->seat != NULL)` (wlr_xdg_activation_v1.c:
/// 108-123), so a launcher binding a surface without a serial still
/// activates (A1). A surface destroyed before commit drops the constraint
/// (XA-2, wlroots XA:202-208, XA:109-114).
fn tokenValid(token: *ActivationToken) bool {
    if (token.serial) |serial| {
        // The seat is the one from set_serial's seat argument (XA-5).
        const seat = token.seat orelse return false;
        if (!seat.validateEventSerial(token.resource.?.getClient(), serial)) return false;
        // Focus gate (A1): only a serial-bearing token must name the seat's
        // current keyboard- or pointer-focused surface.
        if (token.surface) |surface| {
            if (seat.keyboard_focus != surface and seat.pointer_focus != surface) return false;
        }
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
    if (token.resource) |res| {
        res.destroy();
    } else {
        destroyToken(token);
    }
    return 1;
}

/// Resolve a wl_surface wire resource to the compositor's Surface wrapper.
fn surfaceForResource(activation: *XdgActivation, surface_res: *server.wl.Surface) ?*surface_mod.Surface {
    for (activation.compositor.surfaces.items) |s| {
        if (s.resource == surface_res) return s;
    }
    return null;
}

/// Generate a 32-lowercase-hex token string (16 random bytes). XA-4:
/// wlroots uses getrandom(2) (util/token.c); zig 0.16 removed
/// std.crypto.random, so std.Io.randomSecure (getrandom under the hood)
/// stands in. Returns null if the CSPRNG fails.
fn generateToken(token: *ActivationToken) ?[32:0]u8 {
    var bytes: [16]u8 = undefined;
    std.Io.randomSecure(token.io.*, &bytes) catch return null;
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

const NewTokenCapture = struct {
    count: usize = 0,
    /// The last new_token's name (NUL-terminated copy).
    token: [33]u8 = undefined,
    listener: wire.Listener(*ActivationToken),

    fn notify(listener: *wire.Listener(*ActivationToken), token: *ActivationToken) void {
        const cap: *NewTokenCapture = @fieldParentPtr("listener", listener);
        cap.count += 1;
        const name = token.getName();
        const n = @min(name.len, cap.token.len - 1);
        @memcpy(cap.token[0..n], name[0..n]);
        cap.token[n] = 0;
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
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
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

test "activation activate inerts the token resource; client destroy is a no-op (A2)" {
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

    token.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.activation.?.tokens.items.len);

    // activate consumes the token: request_activate fires once and the
    // token leaves the registry (single-use preserved).
    ts.activation_client.?.activate(@ptrCast(&token_events.token), surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(usize, 0), ts.activation.?.tokens.items.len);

    // The creating client can still destroy its token resource: activate
    // inerted it with a no-op handler (wlroots parity, A2), so the destroy
    // is a silent no-op — the pump SUCCEEDS with no abort, no protocol
    // error, and the connection stays healthy.
    token.destroy();
    try ts.pump();
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

    // No input has ever occurred, so the seat's per-client serial ring is
    // empty; a serial the seat never gave this client fails validation at
    // commit.
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

test "activation set_surface without set_serial is valid and activates (A1)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: ActivateCapture = .{
        .listener = wire.Listener(*ActivateRequest).init(ActivateCapture.notify),
    };
    ts.activation.?.events.request_activate.add(&capture.listener);
    var new_capture: NewTokenCapture = .{
        .listener = wire.Listener(*ActivationToken).init(NewTokenCapture.notify),
    };
    ts.activation.?.events.new_token.add(&new_capture.listener);

    // The bound surface is NOT the seat's focus (nothing is focused).
    const surface = try ts.wl_compositor.?.createSurface();
    var token_events: TokenEvents = .{};
    const token = try ts.activation_client.?.getActivationToken();
    token.setListener(*TokenEvents, TokenEvents.listener, &token_events);

    // The launcher flow: set_surface with NO set_serial. wlroots checks
    // focus only inside `if (token->seat != NULL)` (A1), so the token
    // commits valid, fires new_token, and activates — today the focus check
    // dropped it.
    token.setSurface(surface);
    token.commit();
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), token_events.done_count);
    try std.testing.expectEqual(@as(usize, 32), std.mem.sliceTo(&token_events.token, 0).len);
    try std.testing.expectEqual(@as(usize, 1), ts.activation.?.tokens.items.len);
    try std.testing.expectEqual(@as(usize, 1), new_capture.count);

    const target = try ts.wl_compositor.?.createSurface();
    ts.activation_client.?.activate(@ptrCast(&token_events.token), target);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings(
        std.mem.sliceTo(&token_events.token, 0),
        std.mem.sliceTo(&capture.token, 0),
    );
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

test "activation new_token hook fires on successful commit only (XA-1)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var new_capture: NewTokenCapture = .{
        .listener = wire.Listener(*ActivationToken).init(NewTokenCapture.notify),
    };
    ts.activation.?.events.new_token.add(&new_capture.listener);

    var token_events: TokenEvents = .{};
    const token = try ts.activation_client.?.getActivationToken();
    token.setListener(*TokenEvents, TokenEvents.listener, &token_events);

    // Successful commit: new_token fired with the same name done() carries,
    // and before done().
    token.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), new_capture.count);
    try std.testing.expectEqualStrings(
        std.mem.sliceTo(&token_events.token, 0),
        std.mem.sliceTo(&new_capture.token, 0),
    );

    // A failed commit (bogus serial) must not fire new_token.
    var bad_events: TokenEvents = .{};
    const bad = try ts.activation_client.?.getActivationToken();
    bad.setListener(*TokenEvents, TokenEvents.listener, &bad_events);
    bad.setSerial(1, ts.wl_seat.?);
    bad.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), bad_events.done_count);
    try std.testing.expectEqual(@as(usize, 1), new_capture.count);
}

test "activation surface destroyed before commit keeps the token valid (XA-2)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: ActivateCapture = .{
        .listener = wire.Listener(*ActivateRequest).init(ActivateCapture.notify),
    };
    ts.activation.?.events.request_activate.add(&capture.listener);

    const doomed = try ts.wl_compositor.?.createSurface();
    var token_events: TokenEvents = .{};
    const token = try ts.activation_client.?.getActivationToken();
    token.setListener(*TokenEvents, TokenEvents.listener, &token_events);

    // Bind the token to a surface, then destroy the surface before commit.
    // wlroots drops the surface constraint (XA:202-208); the token must
    // still commit valid.
    token.setSurface(doomed);
    doomed.destroy();
    try ts.pump();
    token.commit();
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), token_events.done_count);
    try std.testing.expectEqual(@as(usize, 1), ts.activation.?.tokens.items.len);

    // ...and the token activates normally.
    const surface = try ts.wl_compositor.?.createSurface();
    ts.activation_client.?.activate(@ptrCast(&token_events.token), surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
}

test "activation external tokens: create/activate and add/find (XA-3)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: ActivateCapture = .{
        .listener = wire.Listener(*ActivateRequest).init(ActivateCapture.notify),
    };
    ts.activation.?.events.request_activate.add(&capture.listener);

    const surface = try ts.wl_compositor.?.createSurface();
    // The server must process the create_surface request before the
    // compositor-side Surface exists (surfaceForClient resolves it).
    try ts.pump();
    const srv_surface = ts.surfaceForClient(surface);

    // Compositor-created token: no client object, immediate validity.
    const ext = try ts.activation.?.createToken();
    try std.testing.expectEqual(@as(usize, 1), ts.activation.?.tokens.items.len);
    try std.testing.expectEqual(@as(usize, 32), ext.getName().len);
    try std.testing.expect(ext.resource == null);

    ts.activation.?.activateToken(ext, srv_surface);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings(ext.getName(), std.mem.sliceTo(&capture.token, 0));
    try std.testing.expectEqual(@as(usize, 0), ts.activation.?.tokens.items.len);

    // addToken: a known out-of-band name, findable and activatable.
    const name = "aabbccddeeff00112233445566778899";
    const ext2 = try ts.activation.?.addToken(name);
    try std.testing.expectEqual(@as(usize, 1), ts.activation.?.tokens.items.len);
    try std.testing.expectEqual(@as(?*ActivationToken, ext2), ts.activation.?.findToken(name));
    try std.testing.expectEqual(
        @as(?*ActivationToken, null),
        ts.activation.?.findToken("00000000000000000000000000000000"),
    );
    ts.activation.?.activateToken(ext2, srv_surface);
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqualStrings(name, std.mem.sliceTo(&capture.token, 0));
    try std.testing.expectEqual(@as(usize, 0), ts.activation.?.tokens.items.len);

    // A non-32-hex external name is rejected.
    try std.testing.expectError(error.InvalidTokenName, ts.activation.?.addToken("short"));
}

test "activation tokens are 32 lowercase hex and distinct (XA-4)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var seen: [4][32]u8 = undefined;
    var n: usize = 0;
    while (n < seen.len) : (n += 1) {
        var token_events: TokenEvents = .{};
        const token = try ts.activation_client.?.getActivationToken();
        token.setListener(*TokenEvents, TokenEvents.listener, &token_events);
        token.commit();
        try ts.pump();

        const s = std.mem.sliceTo(&token_events.token, 0);
        try std.testing.expectEqual(@as(usize, 32), s.len);
        // Every character is a lowercase hex digit.
        for (s) |c| {
            try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
        }
        // No repeated token across commits.
        for (seen[0..n]) |prev| {
            try std.testing.expect(!std.mem.eql(u8, &prev, s));
        }
        @memcpy(seen[n][0..32], s[0..32]);
    }
}

test "activation set_serial with an inert seat is ignored (XA-5)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: ActivateCapture = .{
        .listener = wire.Listener(*ActivateRequest).init(ActivateCapture.notify),
    };
    ts.activation.?.events.request_activate.add(&capture.listener);

    // Inert the server-side wl_seat resource (same effect as wlroots'
    // wlr_seat_client_from_resource returning NULL, XA:186-199).
    const seat_res = ts.client.?.getObject(ts.wl_seat.?.getId()).?;
    seat_res.setDispatcher(null, null, null, null);

    const surface = try ts.wl_compositor.?.createSurface();
    var token_events: TokenEvents = .{};
    const token = try ts.activation_client.?.getActivationToken();
    token.setListener(*TokenEvents, TokenEvents.listener, &token_events);

    // The inert seat rejects the set_serial: no serial is stored, so commit
    // validates nothing and the token is valid. Contrast the live-seat
    // bogus-serial test, where the token is dropped.
    token.setSerial(1, ts.wl_seat.?);
    token.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), token_events.done_count);
    try std.testing.expectEqual(@as(usize, 1), ts.activation.?.tokens.items.len);

    ts.activation_client.?.activate(@ptrCast(&token_events.token), surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
}
