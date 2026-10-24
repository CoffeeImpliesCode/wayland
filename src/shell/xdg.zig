//! xdg-shell: the xdg_wm_base global plus the XdgSurface / XdgToplevel /
//! XdgPopup state machines (stable/xdg-shell protocol).
//!
//! scope: xdg_wm_base global, XdgSurface (toplevel + popup roles),
//! configure / ack_configure with a payload model (F6/F7), map/unmap,
//! popup constraint adjustment (F1), ping/pong tracking (F3),
//! parenting (F16). Popup grabs (X04b: real seat-grab routing with
//! serial validation + popup_done dismissal + teardown cleanup) and
//! popup stacking/hit-testing (F12); reactive popup reconfigure (X05:
//! compositor-initiated re-place for set_reactive v3+ popups).
//!
//! Server wiring the popup grab needs (main.zig owns both ends):
//! - `setPopupOrigin` every frame from the scene sync, with the popup
//!   node's ABSOLUTE WORLD position (syncPopupNodes).
//! - `XdgShell.setScreenToWorld` once at startup, because the seat
//!   reports pointer input in SCREEN pixels while that origin is a
//!   WORLD coordinate: the two spaces differ by the camera, and camera
//!   zoom/pan are live gestures. Uninstalled means the identity
//!   mapping, which is correct only for an unzoomed, untranslated
//!   view.
//!
//! Mapping semantics: an xdg surface maps when the client commits a buffer
//! after acking a configure. The compositor's commit pipeline performs the
//! map/unmap transition (`mapped = current.buffer != null` plus role map/unmap
//! hooks and signals); `ack_configure` only marks the surface as configured,
//! which is what permits attaching a buffer in the first place (see
//! `xdgSurfaceClientCommit`).
//!
//! Cross-module contract:
//! - compositor/role.zig: `SurfaceRole { name: []const u8,
//!   client_commit: ?*const fn (*Surface) void, commit: ?*const fn (*Surface) void,
//!   map: ?*const fn (*Surface) void, unmap: ?*const fn (*Surface) void,
//!   destroy: ?*const fn (*Surface) void }`;
//!   `assignRole(surface: *Surface, role: *const SurfaceRole, role_resource: ?*wire.Resource) error{RoleConflict}!void`
//!   posts the wl_surface "role" error itself on a role conflict.
//! - compositor/surface.zig: `Surface { mapped: bool, role: ?*const SurfaceRole,
//!   role_resource: ?*wire.Resource, resource: *server.wl.Surface,
//!   current: State, pending: State, events: struct { client_commit, commit,
//!   map, unmap, destroy: wire.Signal(*Surface) } }`, where `State.buffer: ?*Buffer`.
//!   Commit pipeline: validate -> swap pending->current -> release replaced
//!   buffer -> role.client_commit -> frame callbacks -> role.commit ->
//!   client_commit signal -> commit signal -> map/unmap transition.
//!   The wl_surface wire resource user data is the *Surface. Role hooks are
//!   only invoked while `surface.role` points at our role impl.
//! - compositor/compositor.zig: `Compositor { init(allocator, io, log_cfg,
//!   display) !*Compositor, deinit() }` (registers the wl_compositor global).
//! - core/display.zig: `CompositorDisplay { init(allocator, io, log_cfg) !*CompositorDisplay,
//!   addGlobal(comptime T: type, version: u32, comptime DataT: type, data: DataT,
//!   comptime bind: fn (*wire.Client, DataT, u32, u32) void) !*wire.Global,
//!   nextSerial() u32, getServer() *wire.Server, flushClients() }`.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const role_mod = @import("../compositor/role.zig");
const surface_mod = @import("../compositor/surface.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const seat_mod = @import("../compositor/seat.zig");
const display_mod = @import("../core/display.zig");
/// The compositor's view transform. Production code never touches it:
/// the popup grab reaches the camera through the screen→world seam the
/// server installs (XdgShell.setScreenToWorld). The tests back that
/// seam with the real Camera so they exercise the shipped transform.
const camera_mod = @import("../scene/camera.zig");

const log_tag = "xdg";

/// Screen → world conversion for the coordinates the seat hands popup
/// grabs, installed by the compositor (see `XdgShell.setScreenToWorld`).
/// `sx, sy` are the seat's screen (output-local) pixels; the return
/// value is the same point in world pixels.
pub const ScreenToWorldFn = *const fn (ctx: *anyopaque, sx: i32, sy: i32) geom.FPoint;

// ---------------------------------------------------------------------------
// XdgShell: the xdg_wm_base global.
// ---------------------------------------------------------------------------

pub const XdgShell = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    compositor: *compositor_mod.Compositor,
    /// The xdg_wm_base global, for teardown.
    global: ?*wire.Global = null,
    /// All live toplevels (role objects), in creation order.
    toplevels: std.ArrayList(*XdgToplevel),
    /// All live popups (role objects), in creation order.
    popups: std.ArrayList(*XdgPopup),
    /// Screen → world input conversion, installed by the compositor.
    /// Null = the identity mapping, which is what an unzoomed,
    /// untranslated camera does (the server default) — but only that:
    /// camera zoom and pan are live gestures, so a server that never
    /// installs this mis-hit-tests every popup grab as soon as the view
    /// moves. See setScreenToWorld.
    screen_to_world: ?ScreenToWorldFn = null,
    screen_to_world_ctx: ?*anyopaque = null,

    events: struct {
        /// A new xdg_toplevel role object was created.
        new_toplevel: wire.Signal(*XdgToplevel),
        /// A new xdg_popup role object was created.
        new_popup: wire.Signal(*XdgPopup),
        /// A client answered a pending ping (xdg_wm_base.pong matched the
        /// pending serial). Emitted like wlroots' shell events.pong; the
        /// compositor uses it to clear per-client "unresponsive" markers.
        pong: wire.Signal(*XdgShell),
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        compositor: *compositor_mod.Compositor,
    ) !*XdgShell {
        const shell = try allocator.create(XdgShell);
        errdefer allocator.destroy(shell);
        shell.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .compositor = compositor,
            .toplevels = .empty,
            .popups = .empty,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        errdefer {
            shell.toplevels.deinit(allocator);
            shell.popups.deinit(allocator);
        }
        shell.events.new_toplevel.init();
        shell.events.new_popup.init();
        shell.events.pong.init();

        // Register xdg_wm_base at the maximum version we implement.
        shell.global = try display.addGlobal(
            server.xdg.WmBase,
            *XdgShell,
            wmBaseBind,
            server.xdg.WmBase.generated_version,
            shell,
        );
        return shell;
    }

    /// Install the seat's SCREEN → WORLD input conversion, which the
    /// compositor owns (its camera, not this module). Popup grabs
    /// receive pointer input in screen pixels but popup origins are
    /// published in world pixels, so every popup hit-test and every
    /// surface-local coordinate goes through this first.
    ///
    /// Wiring (src/server/main.zig, next to `state.seat.setPick`):
    ///
    ///     state.shell.setScreenToWorld(screenToWorld, state);
    ///
    ///     /// Seat input is in SCREEN coords; scene nodes (and every
    ///     /// popup origin) are in WORLD coords — invert the camera
    ///     /// exactly as pickSurface does, main.zig:3692-3695.
    ///     fn screenToWorld(ctx: *anyopaque, sx: i32, sy: i32) geom.FPoint {
    ///         const self: *ServerState = @ptrCast(@alignCast(ctx));
    ///         return self.camera.screenToWorld(
    ///             @floatFromInt(sx),
    ///             @floatFromInt(sy),
    ///         );
    ///     }
    pub fn setScreenToWorld(self: *XdgShell, to_world: ScreenToWorldFn, ctx: *anyopaque) void {
        self.screen_to_world = to_world;
        self.screen_to_world_ctx = ctx;
    }

    /// The seat's screen coordinates (x, y) in world pixels. Without an
    /// installed conversion this is the identity — see the field doc.
    pub fn worldFromScreen(self: *const XdgShell, x: i32, y: i32) geom.FPoint {
        return if (self.screen_to_world) |f|
            f(self.screen_to_world_ctx.?, x, y)
        else
            .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }

    pub fn deinit(self: *XdgShell) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the wire resources cascades through their destroy
        // handlers, which remove entries from the lists and free the objects.
        while (self.toplevels.items.len > 0) self.toplevels.items[0].resource.destroy();
        while (self.popups.items.len > 0) self.popups.items[0].resource.destroy();
        self.toplevels.deinit(allocator);
        self.popups.deinit(allocator);
        // The wm_base global itself is owned by the display's registry.
        allocator.destroy(self);
    }
};

/// Per xdg_wm_base binding (the wm_base resource's user data). The binding
/// tracks the xdg_surfaces created through it so that wm_base.destroy can
/// enforce the defunct_surfaces check (destroying a bound wm_base with live
/// surfaces is a client error).
const WmBaseState = struct {
    shell: *XdgShell,
    /// The wm_base resource itself; errors that belong to the xdg_wm_base
    /// interface (role, defunct_surfaces, invalid_popup_parent,
    /// invalid_positioner) are posted here so the client attributes them to
    /// the right interface.
    res: *server.xdg.WmBase,
    /// Live xdg_surfaces created through this binding, in creation order.
    surfaces: std.ArrayList(*XdgSurface) = .empty,
    /// The wm_base resource was destroyed (client teardown destroys a
    /// client's resources in object-id order, so the wm_base — created
    /// before its xdg_surfaces — goes first). The state stays allocated
    /// until the last xdg_surface detaches and frees it (see
    /// xdgSurfaceDestroy).
    dead: bool = false,
    /// Serial of the ping currently awaiting a pong, if any. One
    /// outstanding ping per client (wlroots: wlr_xdg_shell.c:81-96); the
    /// timeout policy (timer, unresponsive error) belongs to the
    /// compositor, which checks `pingPending` and posts the error.
    ping_serial: ?u32 = null,

    /// Send a ping on this binding if none is outstanding (wlroots
    /// wlr_xdg_surface_ping, wlr_xdg_surface.c:553-562).
    fn ping(self: *WmBaseState) void {
        if (self.ping_serial != null) return;
        const serial = self.shell.display.nextSerial();
        self.ping_serial = serial;
        self.res.sendPing(serial);
        log.debug("ping sent serial={d}", self.shell.io, self.shell.log_cfg, log_tag, .{serial});
    }

    fn pingPending(self: *WmBaseState) bool {
        return self.ping_serial != null;
    }
};

fn wmBaseBind(client_wire: *wire.Client, shell: *XdgShell, version: u32, id: u32) void {
    const wm_base = server.xdg.WmBase.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    const state = shell.allocator.create(WmBaseState) catch {
        wm_base.postNoMemory();
        return;
    };
    state.* = .{ .shell = shell, .res = wm_base };
    wm_base.setHandler(*WmBaseState, wmBaseRequest, wmBaseDestroy, state);
}

fn wmBaseRequest(wm_base: *server.xdg.WmBase, request: server.xdg.WmBase.Request, state: *WmBaseState) void {
    const shell = state.shell;
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do. Destroying the
        // binding while xdg_surfaces created through it are still alive is
        // illegal (defunct_surfaces); the connection is doomed either way, so
        // the binding stays alive until the client is torn down.
        .destroy => {
            if (state.surfaces.items.len > 0) {
                wm_base.postError(.defunct_surfaces, "xdg_wm_base destroyed with live xdg_surfaces");
                return;
            }
            wm_base.destroy();
        },
        .create_positioner => |r| {
            const res = server.xdg.Positioner.create(wm_base.getClient(), wm_base.getVersion(), r.id) catch {
                wm_base.postNoMemory();
                return;
            };
            const pos_state = shell.allocator.create(PositionerState) catch {
                wm_base.postNoMemory();
                return;
            };
            pos_state.* = .{ .shell = shell };
            res.setHandler(*PositionerState, positionerRequest, positionerDestroy, pos_state);
        },
        .get_xdg_surface => |r| wmBaseGetXdgSurface(wm_base, state, r),
        .pong => |r| {
            // A pong only matters when it matches the pending ping serial
            // (wlroots xdg_shell_handle_pong, wlr_xdg_shell.c:32-39); a
            // stale/unknown serial is ignored.
            if (state.ping_serial == r.serial) {
                state.ping_serial = null;
                shell.events.pong.emit(shell);
            }
            log.debug("xdg_wm_base.pong serial={d}", shell.io, shell.log_cfg, log_tag, .{r.serial});
        },
    }
}

fn wmBaseDestroy(wm_base: *server.xdg.WmBase, state: *WmBaseState) void {
    _ = wm_base;
    // Client teardown destroys resources in object-id order: the wm_base
    // (created before its xdg_surfaces) is destroyed FIRST, while the
    // surfaces still need the state to detach. Defer the free until the
    // last xdg_surface detaches (xdgSurfaceDestroy).
    state.dead = true;
    if (state.surfaces.items.len == 0) {
        state.surfaces.deinit(state.shell.allocator);
        state.shell.allocator.destroy(state);
    }
}

fn wmBaseGetXdgSurface(wm_base: *server.xdg.WmBase, state: *WmBaseState, r: anytype) void {
    const shell = state.shell;
    // The wl_surface resource's user data is the compositor's Surface.
    const surface: *surface_mod.Surface = @ptrCast(@alignCast(r.surface.getUserData()));
    // Creating an xdg_surface for a wl_surface that already has a role is
    // illegal (role error on the wm_base, per the XML's get_xdg_surface
    // text). The role is permanent, so any role — including a previous
    // xdg_surface role — conflicts; role.zig's assignRole would post a
    // wl_surface error instead, so the check happens here.
    if (surface.role != null) {
        wm_base.postError(.role, "wl_surface already has a role");
        return;
    }
    const res = server.xdg.Surface.create(wm_base.getClient(), wm_base.getVersion(), r.id) catch {
        wm_base.postNoMemory();
        return;
    };
    // Creating an xdg_surface from a wl_surface with a buffer attached or
    // committed is a client error (unconfigured_buffer), caught at creation
    // time rather than at the next commit. F32/C-CS-5: the presented
    // content is `surface.buffer` — `current.buffer` is NULLed at commit.
    if (surface.buffer != null or surface.pending.buffer != null) {
        res.postError(.unconfigured_buffer, "wl_surface already has a buffer attached or committed");
        res.destroy();
        return;
    }
    const xdg = shell.allocator.create(XdgSurface) catch {
        res.destroy();
        wm_base.postNoMemory();
        return;
    };
    xdg.* = .{
        .allocator = shell.allocator,
        .io = shell.io,
        .log_cfg = shell.log_cfg,
        .shell = shell,
        .wm_base = state,
        .resource = res,
        .surface = surface,
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    xdg.events.destroy.init();
    xdg.events.configure.init();
    xdg.events.ack_configure.init();
    res.setHandler(*XdgSurface, xdgSurfaceRequest, xdgSurfaceDestroy, xdg);
    role_mod.assignRole(surface, &xdg_surface_role, @as(?*wire.Resource, @ptrCast(res))) catch {
        res.destroy();
        return;
    };
    // Track for the defunct_surfaces check on wm_base.destroy.
    state.surfaces.append(shell.allocator, xdg) catch {
        res.destroy();
        wm_base.postNoMemory();
        return;
    };
    log.info("new xdg_surface for wl_surface {*}", shell.io, shell.log_cfg, log_tag, .{surface});
}

// ---------------------------------------------------------------------------
// XdgSurface: per-wl_surface state shared by both roles.
// ---------------------------------------------------------------------------

pub const XdgSurface = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    shell: *XdgShell,
    /// The wm_base binding that created this xdg_surface; errors that belong
    /// to the xdg_wm_base interface are posted on its resource, and the
    /// binding's surface list tracks this surface until destroy.
    wm_base: *WmBaseState,
    resource: *server.xdg.Surface,
    surface: *surface_mod.Surface,
    /// Which role object this xdg_surface currently has.
    role: enum { none, toplevel, popup } = .none,
    /// True once the client has acked a configure (permits attaching buffers).
    configured: bool = false,
    /// Serial of the last configure event sent.
    configure_serial: u32 = 0,
    /// Serial of the last configure acked by the client, if any.
    acked_serial: ?u32 = null,
    /// Every configure serial sent since the last (re)map, for
    /// ack_configure validation (wlroots-style configure list; wlroots
    /// types/xdg_shell/wlr_xdg_shell.c tracks sent serials and rejects
    /// acks of serials that were never sent).
    sent_serials: std.ArrayList(u32) = .empty,
    /// A configure has been sent at least once since the last (re)map.
    configure_sent: bool = false,
    /// Window geometry from set_window_geometry (double-buffered).
    pending_geometry: geom.Rect = geom.Rect.empty(),
    current_geometry: geom.Rect = geom.Rect.empty(),
    /// Whether the client ever called set_window_geometry.
    geometry_set: bool = false,
    toplevel: ?*XdgToplevel = null,
    popup: ?*XdgPopup = null,
    /// xdg_popup objects created on top of this xdg_surface, in creation
    /// order (X04a): the "has popups on top" check for xdg_popup.grab /
    /// xdg_popup.destroy reads this list (wlroots popup->base->popups).
    /// Only xdg-parented popups are tracked; layer-parented popups
    /// (layer_parent, L1) are not, until F2 owns layer-popup stacking.
    popups: std.ArrayList(*XdgPopup) = .empty,
    events: struct {
        destroy: wire.Signal(*XdgSurface),
        /// A configure event was just sent on this xdg_surface; the serial
        /// is `configure_serial`. Emitted after the wire configure is
        /// queued, so listeners (xdg_decoration's mode configure, XD-1)
        /// can send their own accompanying event in the same roundtrip
        /// (wlroots wlr_xdg_surface events.configure, fired from
        /// wlr_xdg_surface_send_configure).
        configure: wire.Signal(*XdgSurface),
        /// The client acked a configure; `acked_serial` is the acked
        /// serial. Emitted at the end of ack processing (wlroots
        /// wlr_xdg_surface events.ack_configure).
        ack_configure: wire.Signal(*XdgSurface),
    },

    /// Send the xdg_surface.configure event and record the serial.
    fn sendConfigureEvent(xdg: *XdgSurface, serial: u32) void {
        xdg.resource.sendConfigure(serial);
        xdg.configure_serial = serial;
        xdg.configure_sent = true;
        xdg.sent_serials.append(xdg.allocator, serial) catch {
            xdg.resource.postNoMemory();
        };
        // Listeners (xdg_decoration, XD-1) send their accompanying
        // configure here, after the xdg_surface.configure on the wire.
        xdg.events.configure.emit(xdg);
    }

    /// Reset the configure state machine: after an unmap (role object
    /// destroyed or NULL-buffer commit) the client must perform the initial
    /// buffer-less commit again, receive and ack a fresh configure before it
    /// may attach a buffer (xdg-shell "Unmapping" semantics).
    fn resetConfigureState(xdg: *XdgSurface) void {
        xdg.configure_sent = false;
        xdg.configured = false;
        xdg.acked_serial = null;
        xdg.sent_serials.clearRetainingCapacity();
        // X06: the sent payload lists die with the map (wlroots destroys
        // the whole configure list in reset_xdg_surface): a stale payload
        // must never be matchable by a future ack, even if serials wrap.
        // Clear-not-deinit is correct: the destroy paths deinit right
        // after, and remap cycles avoid re-allocation. The role is still
        // attached on the unmap paths; on the destroy paths it has been
        // detached already and the deinit covers the payload list.
        if (xdg.toplevel) |t| t.sent_payloads.clearRetainingCapacity();
        if (xdg.popup) |p| p.sent_payloads.clearRetainingCapacity();
    }

    /// Handle xdg_surface.ack_configure. The serial must have been sent
    /// (present in the sent list) and must be newer than the last acked
    /// one — a client may ack a configure that was superseded by a newer
    /// one, but never one that was not sent or already acked (wlroots
    /// configure-list semantics; re-configures race client acks).
    fn ackConfigure(xdg: *XdgSurface, serial: u32) void {
        // A role must be assigned before any other request on the xdg_surface
        // (XML xdg_surface description).
        if (xdg.role == .none) {
            xdg.resource.postError(.not_constructed, "ack_configure before a role was assigned");
            return;
        }
        if (std.mem.indexOfScalar(u32, xdg.sent_serials.items, serial) == null) {
            xdg.resource.postError(.invalid_serial, "ack_configure: unknown serial");
            return;
        }
        if (xdg.acked_serial != null and serial <= xdg.acked_serial.?) {
            xdg.resource.postError(.invalid_serial, "ack_configure: already-acked serial");
            return;
        }
        xdg.configured = true;
        xdg.acked_serial = serial;
        // Prune the sent list: serials up to and including the acked one
        // can never be acked again.
        while (xdg.sent_serials.items.len > 0 and xdg.sent_serials.items[0] <= serial) {
            _ = xdg.sent_serials.orderedRemove(0);
        }
        // The ack defines what the client committed against: apply the
        // acked configure's payload (width/height/states for toplevels,
        // geometry for popups) to the role's current state (wlroots
        // handle_xdg_toplevel_ack_configure / handle_xdg_popup_ack_configure).
        if (xdg.toplevel) |t| t.applyAckedConfigure(serial);
        if (xdg.popup) |p| p.applyAckedConfigure(serial);
        log.info("surface configured serial={d} role={s}", xdg.io, xdg.log_cfg, log_tag, .{
            serial,
            @tagName(xdg.role),
        });
        // Listeners (xdg_decoration, XD-1) apply their acked state here;
        // `acked_serial` carries the serial that was just acked.
        xdg.events.ack_configure.emit(xdg);
        // Mapping happens on the next commit with a buffer: the compositor's
        // commit pipeline performs the map transition and fires the map hook
        // and signal (see the file header).
    }

    /// Unmap the wl_surface. Used when a role object or the xdg_surface is
    /// destroyed; NULL-buffer commits unmap via the compositor's transition
    /// (which fires the role's unmap hook, xdgSurfaceUnmap).
    fn unmapSurface(xdg: *XdgSurface) void {
        const surface = xdg.surface;
        if (!surface.mapped) return;
        surface.mapped = false;
        if (surface.role) |r| if (r.unmap) |f| f(surface);
        surface.events.unmap.emit(surface);
        // The next commit after a re-map must trigger a fresh configure.
        // (The role hook normally does this; role may already be detached
        // on the destroy path, so reset explicitly here too.)
        xdg.resetConfigureState();
        log.info("surface unmapped role={s}", xdg.io, xdg.log_cfg, log_tag, .{@tagName(xdg.role)});
    }
};

fn xdgSurfaceRequest(xdg_res: *server.xdg.Surface, request: server.xdg.Surface.Request, xdg: *XdgSurface) void {
    switch (request) {
        .destroy => xdgSurfaceDestroyRequest(xdg),
        .get_toplevel => |r| xdgSurfaceGetToplevel(xdg, r.id),
        .get_popup => |r| xdgSurfaceGetPopup(xdg, r),
        .set_window_geometry => |r| {
            // A role must be assigned before any other request on the
            // xdg_surface (XML xdg_surface description).
            if (xdg.role == .none) {
                xdg_res.postError(.not_constructed, "set_window_geometry before a role was assigned");
                return;
            }
            if (r.width <= 0 or r.height <= 0) {
                xdg_res.postError(.invalid_size, "set_window_geometry: width and height must be positive");
                return;
            }
            xdg.pending_geometry = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
            xdg.geometry_set = true;
        },
        .ack_configure => |r| xdg.ackConfigure(r.serial),
    }
}

/// xdg_surface.destroy request. The resource itself is destroyed by the wire
/// layer after dispatch; the actual cleanup happens in `xdgSurfaceDestroy`.
fn xdgSurfaceDestroyRequest(xdg: *XdgSurface) void {
    if (xdg.role != .none) {
        xdg.resource.postError(.defunct_role_object, "xdg_surface destroyed before its role object");
        // Tear the role objects down anyway; the connection is doomed.
        if (xdg.toplevel) |t| t.resource.destroy();
        if (xdg.popup) |p| p.resource.destroy();
    }
    // Destructor: libwayland does not auto-destroy; we do (runs xdgSurfaceDestroy).
    xdg.resource.destroy();
}

fn xdgSurfaceGetToplevel(xdg: *XdgSurface, id: u32) void {
    if (xdg.role != .none) {
        xdg.resource.postError(.already_constructed, "xdg_surface already has a role object");
        return;
    }
    const shell = xdg.shell;
    const res = server.xdg.Toplevel.create(xdg.resource.getClient(), xdg.resource.getVersion(), id) catch {
        xdg.resource.postNoMemory();
        return;
    };
    const t = xdg.allocator.create(XdgToplevel) catch {
        xdg.resource.postNoMemory();
        return;
    };
    t.* = .{
        .allocator = xdg.allocator,
        .io = xdg.io,
        .log_cfg = xdg.log_cfg,
        .xdg_surface = xdg,
        .resource = res,
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    t.events.request_move.init();
    t.events.request_resize.init();
    t.events.request_maximize.init();
    t.events.request_fullscreen.init();
    t.events.request_minimize.init();
    t.events.request_show_window_menu.init();
    t.events.set_title.init();
    t.events.set_app_id.init();
    t.events.initial_commit.init();
    t.events.destroy.init();
    res.setHandler(*XdgToplevel, toplevelRequest, toplevelDestroy, t);
    // F4: the first configure must carry wm_capabilities (wlroots seeds
    // the default set at role creation, create_xdg_toplevel:299-309); the
    // configure() gate on the client version decides whether it is sent.
    if (res.getVersion() >= 5) {
        t.setWmCapabilities(.{
            .window_menu = true,
            .maximize = true,
            .fullscreen = true,
            .minimize = true,
        });
    }
    xdg.toplevel = t;
    xdg.role = .toplevel;
    shell.toplevels.append(shell.allocator, t) catch {
        // OOM: drop the role object (its destroy handler frees `t`).
        xdg.resource.postNoMemory();
        xdg.toplevel = null;
        xdg.role = .none;
        res.destroy();
        return;
    };
    shell.events.new_toplevel.emit(t);
    log.info("new xdg_toplevel on wl_surface {*}", xdg.io, xdg.log_cfg, log_tag, .{xdg.surface});
}

fn xdgSurfaceGetPopup(xdg: *XdgSurface, r: anytype) void {
    if (xdg.role != .none) {
        xdg.resource.postError(.already_constructed, "xdg_surface already has a role object");
        return;
    }
    const shell = xdg.shell;
    // The parent, if given, must itself carry an xdg_surface-based role;
    // a bare xdg_surface without a role object is not a valid parent
    // (invalid_popup_parent on the wm_base).
    if (r.parent) |parent_res| {
        const parent_xdg: *XdgSurface = @ptrCast(@alignCast(parent_res.getUserData()));
        if (parent_xdg.role == .none) {
            xdg.wm_base.res.postError(.invalid_popup_parent, "xdg_popup parent has no role");
            return;
        }
    }
    const positioner: *PositionerState = @ptrCast(@alignCast(r.positioner.getUserData()));
    // F13: completeness requires positive size AND a positive anchor rect
    // (a zero-size anchor rect is degenerate; wlroots
    // wlr_xdg_positioner_is_complete, wlr_xdg_positioner.c:216).
    if (!positioner.isComplete()) {
        // invalid_positioner belongs to the xdg_wm_base interface; posting
        // its code on the xdg_surface resource would make the client read
        // xdg_surface.invalid_size (code 5 collides).
        xdg.wm_base.res.postError(
            .invalid_positioner,
            "xdg_positioner is incomplete: set_size and set_anchor_rect are required",
        );
        return;
    }
    const res = server.xdg.Popup.create(xdg.resource.getClient(), xdg.resource.getVersion(), r.id) catch {
        xdg.resource.postNoMemory();
        return;
    };
    const popup = xdg.allocator.create(XdgPopup) catch {
        xdg.resource.postNoMemory();
        return;
    };
    popup.* = .{
        .allocator = xdg.allocator,
        .io = xdg.io,
        .log_cfg = xdg.log_cfg,
        .xdg_surface = xdg,
        .resource = res,
        .geometry = positioner.geometry(),
        .positioner_rules = positioner.*,
        .parent = if (r.parent) |p|
            @as(*XdgSurface, @ptrCast(@alignCast(p.getUserData())))
        else
            null,
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    popup.events.destroy.init();
    popup.events.initial_commit.init();
    res.setHandler(*XdgPopup, popupRequest, popupDestroy, popup);
    xdg.popup = popup;
    xdg.role = .popup;
    shell.popups.append(shell.allocator, popup) catch {
        xdg.resource.postNoMemory();
        xdg.popup = null;
        xdg.role = .none;
        res.destroy();
        return;
    };
    // X04a: track the popup as a child of its parent xdg_surface; the
    // topmost check for grab/destroy reads the parent's child list. A
    // null parent (bare xdg_surface) and layer parents are not tracked.
    if (popup.parent) |parent_xdg| {
        parent_xdg.popups.append(parent_xdg.allocator, popup) catch {
            // Roll back the shell-list entry (the popup is its last item).
            _ = shell.popups.swapRemove(shell.popups.items.len - 1);
            xdg.resource.postNoMemory();
            xdg.popup = null;
            xdg.role = .none;
            res.destroy();
            return;
        };
    }
    shell.events.new_popup.emit(popup);
    log.info("new xdg_popup on wl_surface {*} at ({d},{d}) {d}x{d}", xdg.io, xdg.log_cfg, log_tag, .{
        xdg.surface,
        popup.geometry.x,
        popup.geometry.y,
        popup.geometry.width,
        popup.geometry.height,
    });
}

/// xdg_surface resource destroyed (client destroy request, disconnect, or the
/// wl_surface going away via the role destroy hook). Root of the teardown.
fn xdgSurfaceDestroy(res: *server.xdg.Surface, xdg: *XdgSurface) void {
    _ = res;
    const shell = xdg.shell;
    // Detach from the binding. The wm_base may already be destroyed (client
    // teardown destroys resources in object-id order, wm_base first): when
    // this was the last surface, free the binding state. `xdg.wm_base` is
    // not dereferenced again after this.
    if (std.mem.findScalar(*XdgSurface, xdg.wm_base.surfaces.items, xdg)) |i| {
        _ = xdg.wm_base.surfaces.swapRemove(i);
    }
    if (xdg.wm_base.dead and xdg.wm_base.surfaces.items.len == 0) {
        const wm_state = xdg.wm_base;
        wm_state.surfaces.deinit(shell.allocator);
        shell.allocator.destroy(wm_state);
    }
    // X04a: detach child popups while this surface is still alive — they
    // reference it as their parent, and a later popupDestroy of a child
    // must never dereference freed memory (client teardown destroys
    // ancestors first, in object-id order). Mirror of the toplevel child
    // detach in toplevelDestroy.
    for (xdg.popups.items) |child| {
        child.parent = null;
    }
    xdg.popups.clearRetainingCapacity();
    // Destroy role objects first: their destroy handlers detach from `xdg`.
    if (xdg.toplevel) |t| t.resource.destroy();
    if (xdg.popup) |p| p.resource.destroy();
    const surface = xdg.surface;
    if (surface.role_resource == @as(?*wire.Resource, @ptrCast(xdg.resource))) {
        // Detach the role so the commit pipeline never calls our hooks again
        // (the client may keep the wl_surface alive for a new role).
        surface.role = null;
        surface.role_resource = null;
    }
    xdg.unmapSurface();
    xdg.events.destroy.emit(xdg);
    xdg.sent_serials.deinit(shell.allocator);
    xdg.popups.deinit(shell.allocator);
    shell.allocator.destroy(xdg);
}

// ---------------------------------------------------------------------------
// XdgToplevel.
// ---------------------------------------------------------------------------

/// Compositor-advertised wm_capabilities (xdg_toplevel.wm_capabilities,
/// since v5; XML enum values 1..4). A bool struct rather than the wire
/// enum: the generated enum is non-exhaustive, so a set is cleaner.
pub const WmCapabilities = struct {
    window_menu: bool = false,
    maximize: bool = false,
    fullscreen: bool = false,
    minimize: bool = false,

    /// Serialize into the wire array, in enum value order (window_menu=1,
    /// maximize=2, fullscreen=3, minimize=4; at most 4 entries).
    pub fn toArray(c: WmCapabilities, out: *[4]u32) []u32 {
        var n: usize = 0;
        if (c.window_menu) {
            out[n] = @backingInt(server.xdg.Toplevel.WmCapabilities.window_menu);
            n += 1;
        }
        if (c.maximize) {
            out[n] = @backingInt(server.xdg.Toplevel.WmCapabilities.maximize);
            n += 1;
        }
        if (c.fullscreen) {
            out[n] = @backingInt(server.xdg.Toplevel.WmCapabilities.fullscreen);
            n += 1;
        }
        if (c.minimize) {
            out[n] = @backingInt(server.xdg.Toplevel.WmCapabilities.minimize);
            n += 1;
        }
        return out[0..n];
    }
};

/// One xdg_toplevel.configure that was sent and not yet superseded: the
/// payload the client acks against (F6/F7). The state is the scheduled
/// state the configure carried.
pub const ConfigurePayload = struct {
    serial: u32,
    width: i32,
    height: i32,
    state: ToplevelState,
};

/// One xdg_popup.configure that was sent: the geometry the client acks
/// against (F7).
pub const PopupConfigurePayload = struct {
    serial: u32,
    geometry: geom.Rect,
};

/// Payload of the XdgToplevel request_move signal: the seat whose serial
/// the client echoed (F11).
pub const MoveRequest = struct {
    toplevel: *XdgToplevel,
    seat: *seat_mod.Seat,
    serial: u32,
};

/// Payload of the XdgToplevel request_fullscreen signal: the client's
/// requested fullscreen state plus the output it named, if any (F10).
pub const FullscreenRequest = struct {
    toplevel: *XdgToplevel,
    fullscreen: bool,
    output: ?*server.wl.Output,
};

/// Payload of the XdgToplevel request_show_window_menu signal: the seat,
/// serial and surface-local coordinates for the menu (F11).
pub const ShowWindowMenuRequest = struct {
    toplevel: *XdgToplevel,
    seat: *seat_mod.Seat,
    serial: u32,
    x: i32,
    y: i32,
};

pub const ToplevelState = struct {
    maximized: bool = false,
    fullscreen: bool = false,
    resizing: bool = false,
    activated: bool = false,
    tiled_left: bool = false,
    tiled_right: bool = false,
    tiled_top: bool = false,
    tiled_bottom: bool = false,
    suspended: bool = false,
    constrained_left: bool = false,
    constrained_right: bool = false,
    constrained_top: bool = false,
    constrained_bottom: bool = false,
    /// Current/pending window geometry size (0 = client decides).
    width: i32 = 0,
    height: i32 = 0,
    min_size: geom.Size = .{ .w = 0, .h = 0 },
    max_size: geom.Size = .{ .w = 0, .h = 0 },
    /// Recommended window-geometry bounds (xdg_toplevel.configure_bounds,
    /// since v4); written by setConfigureBounds. An explicit 0,0 is legal
    /// and sent as-is when the bit is armed (X07).
    bounds_width: i32 = 0,
    bounds_height: i32 = 0,
    /// Compositor-advertised wm_capabilities (since v5): which interactive
    /// requests the compositor supports. Written by setWmCapabilities; an
    /// empty set is legal and announced as a zero-length array (X07).
    wm_capabilities: WmCapabilities = .{},
    /// Client requested minimization (xdg_toplevel.set_minimized). Not a
    /// wire state; recorded for the compositor's minimize policy.
    minimized: bool = false,
};

/// Which optional per-configure payloads the compositor asked for on the
/// NEXT configure (X07): configure_bounds and wm_capabilities are sent
/// only when the corresponding bit is armed (via setConfigureBounds /
/// setWmCapabilities), and each bit clears after its send (wlroots
/// configure->fields, wlr_xdg_toplevel.c:36-63).
const ConfigureFields = packed struct {
    configure_bounds: bool = false,
    wm_capabilities: bool = false,
};

/// Payload of the XdgToplevel request_resize signal: the seat whose
/// serial the client echoed plus the validated resize_edge value (none is
/// legal) (F11).
pub const ResizeRequest = struct {
    toplevel: *XdgToplevel,
    seat: *seat_mod.Seat,
    serial: u32,
    edges: server.xdg.Toplevel.ResizeEdge,
};

pub const XdgToplevel = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    xdg_surface: *XdgSurface,
    resource: *server.xdg.Toplevel,
    /// Last title sent by the client (owned; UTF-8).
    title: ?[]const u8 = null,
    /// Last app_id sent by the client (owned; UTF-8).
    app_id: ?[]const u8 = null,
    /// Last-acked state: what the client committed against (wlroots
    /// toplevel->pending after handle_xdg_toplevel_ack_configure). The
    /// compositor reads min/max size and the acked geometry here.
    current: ToplevelState = .{},
    /// Double-buffered client-requested state; applied to `current` by
    /// policy on commit.
    pending: ToplevelState = .{},
    /// Per-field state the NEXT configure will carry (F6): the compositor
    /// writes fields here (size, maximized, ...) and calls `configure`;
    /// the ack then applies the payload to `current`.
    scheduled: ToplevelState = .{},
    /// Size from the last configure event sent.
    configured_size: geom.Size = .{ .w = 0, .h = 0 },
    /// Configure payloads sent since the last (re)map, in send order; the
    /// acked payload is applied to `current` (F7).
    sent_payloads: std.ArrayList(ConfigurePayload) = .empty,
    /// The parent toplevel (xdg_toplevel.set_parent, F16); null = no
    /// parent. Only toplevels (no children) may be parented.
    parent: ?*XdgToplevel = null,
    /// Toplevels whose `parent` is this toplevel, in set order. Kept so
    /// parent destruction/unmap can reparent or clear the children's
    /// pointers (no dangling references).
    children: std.ArrayList(*XdgToplevel) = .empty,
    /// Per-payload request bits for the NEXT configure (X07): armed by
    /// setConfigureBounds / setWmCapabilities, consumed (and cleared) by
    /// configure().
    fields: ConfigureFields = .{},
    events: struct {
        /// Client requested an interactive move; the payload carries the
        /// seat + serial the client echoed (F11).
        request_move: wire.Signal(*MoveRequest),
        /// Client requested an interactive resize; the payload carries the
        /// seat + serial + validated resize_edge (F11).
        request_resize: wire.Signal(*ResizeRequest),
        /// Client requested maximize/unmaximize.
        request_maximize: wire.Signal(*XdgToplevel),
        /// Client requested fullscreen/unfullscreen; the payload carries
        /// the state and the output the client named (F10).
        request_fullscreen: wire.Signal(*FullscreenRequest),
        /// Client requested minimization (F10).
        request_minimize: wire.Signal(*XdgToplevel),
        /// Client asked the compositor to show a window menu at (x, y)
        /// with a seat + serial (F11).
        request_show_window_menu: wire.Signal(*ShowWindowMenuRequest),
        /// The client changed the title (F14).
        set_title: wire.Signal(*XdgToplevel),
        /// The client changed the app_id (F14).
        set_app_id: wire.Signal(*XdgToplevel),
        /// The client performed the initial (buffer-less) commit after the
        /// role object was created (X08): the compositor must reply with a
        /// configure so the client can map (wlroots: tinywl's commit
        /// listener checks base->initial_commit and calls
        /// wlr_xdg_toplevel_set_size / schedule_configure). The module
        /// never self-configures; the compositor calls scheduleConfigure
        /// from this signal.
        initial_commit: wire.Signal(*XdgToplevel),
        /// The role object was destroyed.
        destroy: wire.Signal(*XdgToplevel),
    },

    /// Request configure_bounds (w, h) on the next configure (X07): the
    /// event is sent only when this bit is armed and the client version is
    /// >= 4; the bit clears after the send. An explicit 0,0 is legal and
    /// is sent as-is (wlroots: the compositor requests the payload per
    /// configure rather than the value changing).
    pub fn setConfigureBounds(t: *XdgToplevel, w: i32, h: i32) void {
        t.scheduled.bounds_width = w;
        t.scheduled.bounds_height = h;
        t.fields.configure_bounds = true;
    }

    /// Request a wm_capabilities announcement on the next configure (X07):
    /// sent only when this bit is armed and the client version is >= 5;
    /// the bit clears after the send. An empty set is legal and is
    /// announced as a zero-length array.
    pub fn setWmCapabilities(t: *XdgToplevel, caps: WmCapabilities) void {
        t.scheduled.wm_capabilities = caps;
        t.fields.wm_capabilities = true;
    }

    /// Send a configure event for this toplevel: optional configure_bounds
    /// and wm_capabilities (version-gated, F4), then xdg_toplevel.configure
    /// with the states derived from `scheduled`, then xdg_surface.configure
    /// with the serial. `width`/`height` are window-geometry hints; 0 means
    /// "client decides".
    pub fn configure(t: *XdgToplevel, width: i32, height: i32) !void {
        const xdg = t.xdg_surface;
        const serial = xdg.shell.display.nextSerial();
        const version = t.resource.getVersion();
        // configure_bounds (since v4): sent when the compositor armed the
        // bit via setConfigureBounds; the bit clears after the send
        // (wlroots sends iff configure->fields has the bounds bit,
        // wlr_xdg_toplevel.c:36-47).
        if (version >= 4 and t.fields.configure_bounds) {
            t.resource.sendConfigureBounds(t.scheduled.bounds_width, t.scheduled.bounds_height);
            t.fields.configure_bounds = false;
        }
        // wm_capabilities (since v5): sent when armed via
        // setWmCapabilities, including an empty set; the bit clears after
        // the send (wlroots wlr_xdg_toplevel.c:44-63).
        if (version >= 5 and t.fields.wm_capabilities) {
            var cap_buf: [4]u32 = undefined;
            const cap_values = t.scheduled.wm_capabilities.toArray(&cap_buf);
            var cap_array: server.wl.Array = .{
                .size = cap_values.len * @sizeOf(u32),
                .alloc = cap_buf.len * @sizeOf(u32),
                .data = &cap_buf,
            };
            t.resource.sendWmCapabilities(&cap_array);
            t.fields.wm_capabilities = false;
        }
        var buf: [13]u32 = undefined;
        const states = stateValues(&t.scheduled, &buf, version);
        // libwayland marshals the array synchronously; a stack buffer is safe.
        var array: server.wl.Array = .{
            .size = states.len * @sizeOf(u32),
            .alloc = buf.len * @sizeOf(u32),
            .data = &buf,
        };
        t.resource.sendConfigure(width, height, &array);
        xdg.sendConfigureEvent(serial);
        t.configured_size = .{ .w = width, .h = height };
        // Record the payload the client will ack against (F7).
        t.sent_payloads.append(t.allocator, .{
            .serial = serial,
            .width = width,
            .height = height,
            .state = t.scheduled,
        }) catch {
            t.resource.postNoMemory();
        };
        log.info("toplevel configure serial={d} {d}x{d} states={d}", xdg.io, xdg.log_cfg, log_tag, .{
            serial, width, height, states.len,
        });
    }

    /// Compositor-driven configure (X08): send a configure with the
    /// current scheduled size/states — the reply to the client's initial
    /// commit, or a re-configure after a policy change. Called from the
    /// initial_commit signal (or any arrange pass); the module never
    /// self-configures (wlroots: the compositor drives
    /// wlr_xdg_toplevel_configure / schedule_configure).
    pub fn scheduleConfigure(t: *XdgToplevel) !void {
        try t.configure(t.scheduled.width, t.scheduled.height);
    }

    /// Apply the acked configure payload to `current` (wlroots
    /// handle_xdg_toplevel_ack_configure): the acked size/states are what
    /// the client committed against. Payloads up to and including the
    /// acked serial are dropped (they can never be acked again).
    fn applyAckedConfigure(t: *XdgToplevel, serial: u32) void {
        var i: usize = 0;
        while (i < t.sent_payloads.items.len) {
            const payload = t.sent_payloads.items[i];
            if (payload.serial == serial) {
                t.current.width = payload.width;
                t.current.height = payload.height;
                t.current.maximized = payload.state.maximized;
                t.current.fullscreen = payload.state.fullscreen;
                t.current.resizing = payload.state.resizing;
                t.current.activated = payload.state.activated;
                t.current.tiled_left = payload.state.tiled_left;
                t.current.tiled_right = payload.state.tiled_right;
                t.current.tiled_top = payload.state.tiled_top;
                t.current.tiled_bottom = payload.state.tiled_bottom;
                t.current.suspended = payload.state.suspended;
                t.current.constrained_left = payload.state.constrained_left;
                t.current.constrained_right = payload.state.constrained_right;
                t.current.constrained_top = payload.state.constrained_top;
                t.current.constrained_bottom = payload.state.constrained_bottom;
            }
            if (payload.serial <= serial) {
                _ = t.sent_payloads.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Ping this toplevel's client (xdg_wm_base.ping). No-op when a ping
    /// is already outstanding on the binding (wlroots wlr_xdg_surface_ping).
    pub fn ping(t: *XdgToplevel) void {
        t.xdg_surface.wm_base.ping();
    }

    /// Whether a ping on this toplevel's client is awaiting a pong.
    pub fn pingPending(t: *XdgToplevel) bool {
        return t.xdg_surface.wm_base.pingPending();
    }

    /// The xdg_wm_base resource owning this toplevel's surface, for
    /// posting the unresponsive error from compositor policy.
    pub fn wmBaseResource(t: *XdgToplevel) *server.xdg.WmBase {
        return t.xdg_surface.wm_base.res;
    }

    /// Ask the client to close the window (xdg_toplevel.close).
    pub fn sendClose(t: *XdgToplevel) void {
        t.resource.sendClose();
    }

    fn setTitle(t: *XdgToplevel, title: [*:0]const u8) void {
        // The XML requires UTF-8 ("The string must be encoded in UTF-8")
        // but defines no error code for a violation; reject the value with a
        // log instead of storing garbage (wlroots posts error -1, which has
        // no XML backing; ours keeps the connection — deliberate
        // divergence, documented in notes/133).
        const span = std.mem.span(title);
        if (!std.unicode.utf8ValidateSlice(span)) {
            log.warn("xdg_toplevel.set_title: title is not valid UTF-8; rejected", t.io, t.log_cfg, log_tag, .{});
            return;
        }
        const copy = t.allocator.dupe(u8, span) catch {
            t.resource.postNoMemory();
            return;
        };
        if (t.title) |old| t.allocator.free(old);
        t.title = copy;
        t.events.set_title.emit(t);
    }

    fn setAppId(t: *XdgToplevel, app_id: [*:0]const u8) void {
        const copy = t.allocator.dupe(u8, std.mem.span(app_id)) catch {
            t.resource.postNoMemory();
            return;
        };
        if (t.app_id) |old| t.allocator.free(old);
        t.app_id = copy;
        t.events.set_app_id.emit(t);
    }

    /// Reset the per-map toplevel metadata on unmap (wlroots
    /// reset_xdg_toplevel, wlr_xdg_toplevel.c:523-541): title/app_id are
    /// per-map, and the parent link dies with the map (the XML: "If a
    /// surface becomes unmapped, its children's parent is set to the
    /// parent of the now-unmapped surface"). Children are reparented to
    /// this toplevel's parent (the grandparent) so no child ever holds a
    /// stale pointer.
    fn resetOnUnmap(t: *XdgToplevel) void {
        if (t.title) |title| t.allocator.free(title);
        t.title = null;
        if (t.app_id) |app_id| t.allocator.free(app_id);
        t.app_id = null;
        const grandparent = t.parent;
        if (grandparent) |parent| {
            if (std.mem.findScalar(*XdgToplevel, parent.children.items, t)) |i| {
                _ = parent.children.swapRemove(i);
            }
        }
        t.parent = null;
        // Index loop: the append targets the GRANDPARENT's children list
        // (a different list than t.children, which the loop reads); the
        // index form also keeps zbc's reentrant-grow analysis quiet.
        var i: usize = 0;
        while (i < t.children.items.len) : (i += 1) {
            const child = t.children.items[i];
            child.parent = grandparent;
            if (grandparent) |gp| gp.children.append(t.allocator, child) catch |err| {
                // OOM: the child keeps a valid parent pointer but is not
                // tracked; acceptable degradation.
                log.debug("reparent on unmap: {s}", t.io, t.log_cfg, log_tag, .{@errorName(err)});
            };
        }
        t.children.clearRetainingCapacity();
    }
};

/// Serialize the states set in `st` into `out`, in protocol enum value
/// order (maximized=1 .. constrained_bottom=13; at most 13 entries),
/// filtering out states the client's binding version does not know
/// (F5): tiled_* since v2, suspended since v6, constrained_* since v7
/// (xdg-shell.xml since annotations; wlroots gates per state in
/// send_xdg_toplevel_configure, wlr_xdg_toplevel.c:83-124).
fn stateValues(st: *const ToplevelState, out: *[13]u32, version: u32) []u32 {
    var n: usize = 0;
    if (st.maximized) {
        out[n] = @backingInt(server.xdg.Toplevel.State.maximized);
        n += 1;
    }
    if (st.fullscreen) {
        out[n] = @backingInt(server.xdg.Toplevel.State.fullscreen);
        n += 1;
    }
    if (st.resizing) {
        out[n] = @backingInt(server.xdg.Toplevel.State.resizing);
        n += 1;
    }
    if (st.activated) {
        out[n] = @backingInt(server.xdg.Toplevel.State.activated);
        n += 1;
    }
    if (version >= 2) {
        if (st.tiled_left) {
            out[n] = @backingInt(server.xdg.Toplevel.State.tiled_left);
            n += 1;
        }
        if (st.tiled_right) {
            out[n] = @backingInt(server.xdg.Toplevel.State.tiled_right);
            n += 1;
        }
        if (st.tiled_top) {
            out[n] = @backingInt(server.xdg.Toplevel.State.tiled_top);
            n += 1;
        }
        if (st.tiled_bottom) {
            out[n] = @backingInt(server.xdg.Toplevel.State.tiled_bottom);
            n += 1;
        }
    }
    if (version >= 6) {
        if (st.suspended) {
            out[n] = @backingInt(server.xdg.Toplevel.State.suspended);
            n += 1;
        }
    }
    if (version >= 7) {
        if (st.constrained_left) {
            out[n] = @backingInt(server.xdg.Toplevel.State.constrained_left);
            n += 1;
        }
        if (st.constrained_right) {
            out[n] = @backingInt(server.xdg.Toplevel.State.constrained_right);
            n += 1;
        }
        if (st.constrained_top) {
            out[n] = @backingInt(server.xdg.Toplevel.State.constrained_top);
            n += 1;
        }
        if (st.constrained_bottom) {
            out[n] = @backingInt(server.xdg.Toplevel.State.constrained_bottom);
            n += 1;
        }
    }
    return out[0..n];
}

/// Recover the compositor Seat from a wl_seat wire resource (the seat
/// module stores the *Seat as the resource user data, seat.zig:494).
fn seatFromResource(res: *server.wl.Seat) *seat_mod.Seat {
    return @ptrCast(@alignCast(res.getUserData()));
}

fn toplevelRequest(toplevel_res: *server.xdg.Toplevel, request: server.xdg.Toplevel.Request, t: *XdgToplevel) void {
    const xdg = t.xdg_surface;
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do (runs toplevelDestroy).
        .destroy => t.resource.destroy(),
        .set_parent => |r| setToplevelParent(t, toplevel_res, r.parent),
        .set_title => |r| t.setTitle(r.title),
        .set_app_id => |r| t.setAppId(r.app_id),
        .show_window_menu => |r| {
            // Interactive requests need a configured (constructed) surface.
            if (!xdg.configured) {
                xdg.resource.postError(.not_constructed, "show_window_menu before the surface is configured");
                return;
            }
            var req: ShowWindowMenuRequest = .{
                .toplevel = t,
                .seat = seatFromResource(r.seat),
                .serial = r.serial,
                .x = r.x,
                .y = r.y,
            };
            t.events.request_show_window_menu.emit(&req);
        },
        .move => |r| {
            if (!xdg.configured) {
                xdg.resource.postError(.not_constructed, "move before the surface is configured");
                return;
            }
            var req: MoveRequest = .{ .toplevel = t, .seat = seatFromResource(r.seat), .serial = r.serial };
            t.events.request_move.emit(&req);
        },
        .resize => |r| {
            if (!xdg.configured) {
                xdg.resource.postError(.not_constructed, "resize before the surface is configured");
                return;
            }
            // Values not matching a resize_edge variant are an error
            // (invalid_resize_edge on the toplevel); valid: none, top,
            // bottom, left, top_left, bottom_left, right, top_right,
            // bottom_right (XML enum values 0,1,2,4,5,6,8,9,10).
            const edge = @backingInt(r.edges);
            switch (edge) {
                0, 1, 2, 4, 5, 6, 8, 9, 10 => {},
                else => {
                    toplevel_res.postError(.invalid_resize_edge, "xdg_toplevel.resize: invalid resize edge");
                    return;
                },
            }
            var req: ResizeRequest = .{
                .toplevel = t,
                .seat = seatFromResource(r.seat),
                .serial = r.serial,
                .edges = r.edges,
            };
            t.events.request_resize.emit(&req);
        },
        .set_max_size => |r| {
            t.pending.max_size = .{ .w = r.width, .h = r.height };
            // Validated at commit, in xdgSurfaceClientCommit (wlroots order).
        },
        .set_min_size => |r| {
            t.pending.min_size = .{ .w = r.width, .h = r.height };
        },
        .set_maximized => {
            t.pending.maximized = true;
            t.events.request_maximize.emit(t);
        },
        .unset_maximized => {
            t.pending.maximized = false;
            t.events.request_maximize.emit(t);
        },
        .set_fullscreen => |r| {
            t.pending.fullscreen = true;
            var req: FullscreenRequest = .{ .toplevel = t, .fullscreen = true, .output = r.output };
            t.events.request_fullscreen.emit(&req);
        },
        // unset_fullscreen carries no output argument (xdg-shell.xml;
        // only set_fullscreen names an output).
        .unset_fullscreen => {
            t.pending.fullscreen = false;
            var req: FullscreenRequest = .{ .toplevel = t, .fullscreen = false, .output = null };
            t.events.request_fullscreen.emit(&req);
        },
        .set_minimized => {
            t.pending.minimized = true;
            t.events.request_minimize.emit(t);
        },
    }
}

/// xdg_toplevel.set_parent: store the parent and reject cycles (F16).
/// Only the toplevel itself (invalid_parent) and descendant cycles are
/// invalid; the parent's unmap reparents children (see resetOnUnmap).
fn setToplevelParent(t: *XdgToplevel, toplevel_res: *server.xdg.Toplevel, parent: ?*server.xdg.Toplevel) void {
    // Resolve the requested parent to its XdgToplevel, if any.
    var new_parent: ?*XdgToplevel = if (parent) |res|
        @ptrCast(@alignCast(res.getUserData()))
    else
        null;
    if (new_parent) |np| {
        if (np == t) {
            toplevel_res.postError(.invalid_parent, "xdg_toplevel cannot be its own parent");
            return;
        }
        // Cycle check: walking up from the requested parent must never
        // reach `t` (the XML: "The parent toplevel must not be one of the
        // child toplevel's descendants"). wlroots walks the parent chain
        // the same way (wlr_xdg_toplevel.c:178-204).
        var cursor: ?*XdgToplevel = np.parent;
        while (cursor) |c| {
            if (c == t) {
                toplevel_res.postError(.invalid_parent, "xdg_toplevel parent would create a cycle");
                return;
            }
            cursor = c.parent;
        }
    }
    // X03: an unmapped toplevel cannot be a parent (wlroots
    // wlr_xdg_toplevel.c:193-199 installs the parent only when it is
    // mapped). The map state is read once at set_parent time; a later
    // map of the parent requires a fresh set_parent request.
    if (new_parent != null and !new_parent.?.xdg_surface.surface.mapped) {
        new_parent = null;
    }
    // Drop the old link before installing the new one.
    if (t.parent) |old| {
        if (std.mem.findScalar(*XdgToplevel, old.children.items, t)) |i| {
            _ = old.children.swapRemove(i);
        }
    }
    if (new_parent) |np| {
        np.children.append(t.allocator, t) catch {
            toplevel_res.postNoMemory();
            return;
        };
    }
    t.parent = new_parent;
    log.debug(
        "xdg_toplevel.set_parent -> {s}",
        t.io,
        t.log_cfg,
        log_tag,
        .{if (new_parent) |_| "set" else "cleared"},
    );
}

fn toplevelDestroy(toplevel_res: *server.xdg.Toplevel, t: *XdgToplevel) void {
    _ = toplevel_res;
    const shell = t.xdg_surface.shell;
    if (std.mem.findScalar(*XdgToplevel, shell.toplevels.items, t)) |i| {
        _ = shell.toplevels.swapRemove(i);
    }
    t.events.destroy.emit(t);
    const xdg = t.xdg_surface;
    xdg.toplevel = null;
    xdg.role = .none;
    // F8: role-object destruction resets the configure state machine even
    // when the surface never mapped (unmapSurface early-returns on
    // !mapped, so the reset must run explicitly).
    xdg.resetConfigureState();
    xdg.unmapSurface();
    // Parent-link cleanup. On the mapped path, resetOnUnmap (via the unmap
    // hook) already reparented the children to the grandparent and cleared
    // the child list; the unmapped path needs the manual detach here.
    if (t.parent) |parent| {
        if (std.mem.findScalar(*XdgToplevel, parent.children.items, t)) |i| {
            _ = parent.children.swapRemove(i);
        }
        t.parent = null;
    }
    for (t.children.items) |child| child.parent = null;
    t.children.deinit(t.allocator);
    t.sent_payloads.deinit(t.allocator);
    if (t.title) |title| t.allocator.free(title);
    if (t.app_id) |app_id| t.allocator.free(app_id);
    shell.allocator.destroy(t);
}

// ---------------------------------------------------------------------------
// XdgPopup.
// ---------------------------------------------------------------------------

pub const XdgPopup = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    xdg_surface: *XdgSurface,
    resource: *server.xdg.Popup,
    /// Position relative to the top-left of the parent's window geometry,
    /// derived from the xdg_positioner at get_popup time and re-derived
    /// on configure/reposition (F1).
    geometry: geom.Rect = geom.Rect.empty(),
    /// This surface's absolute origin in scene coordinates, kept
    /// current by the compositor's scene sync through setPopupOrigin.
    /// The seat reports pointer input in scene coordinates while
    /// wl_pointer carries surface-local ones (wayland.xml:2224-2232),
    /// so the popup grab subtracts this origin from every event it
    /// forwards. (0,0) until the first sync, which leaves the
    /// conversion a no-op: a popup the scene has not placed yet is
    /// treated as sitting at the scene's top-left.
    origin: geom.FPoint = .{ .x = 0, .y = 0 },
    /// The xdg_surface this popup is attached to (null = layer-shell parent).
    parent: ?*XdgSurface = null,
    /// The layer surface this popup is attached to when the parent is a
    /// zwlr_layer_surface_v1 (L1; set by layer_shell.zig's get_popup).
    layer_parent: ?*surface_mod.Surface = null,
    /// The positioner rules copied at get_popup/reposition time; the
    /// constraint adjustment and reactive re-placement read these (F1).
    // SAFETY: written before any read — the get_popup construction
    // (xdgSurfaceGetPopup) copies the validated positioner into this
    // field before the popup is published to the shell list, and
    // xdg_popup.reposition copies a fresh PositionerState over it
    // before recomputeGeometry reads it back.
    positioner_rules: PositionerState = undefined,
    /// The compositor-supplied usable area the popup must stay within
    /// (output or parent-toplevel box, in parent-surface-local coords).
    /// Null = no constraint adjustment (F1). Applied at configure time.
    constraint_box: ?geom.Rect = null,
    /// Popup configure payloads sent since the last (re)map; the acked
    /// one records the geometry the client committed against (F7).
    sent_payloads: std.ArrayList(PopupConfigurePayload) = .empty,
    /// Geometry of the last acked configure, if any (F7).
    acked_geometry: ?geom.Rect = null,
    /// The active (or ended-but-not-yet-freed) popup seat grab, if this
    /// popup ever called xdg_popup.grab (X04b). Non-null from grab
    /// install until popupDestroy frees the state; `active` on the state
    /// says whether the seat still carries the grabs.
    grab_state: ?*PopupGrab = null,
    events: struct {
        destroy: wire.Signal(*XdgPopup),
        /// The client performed the initial (buffer-less) commit after the
        /// role object was created (X08): the compositor must reply with a
        /// configure so the client can map (wlroots: tinywl's popup commit
        /// listener calls wlr_xdg_surface_schedule_configure). The module
        /// never self-configures; the compositor calls scheduleConfigure
        /// from this signal.
        initial_commit: wire.Signal(*XdgPopup),
    },

    /// Recompute `geometry` from the positioner rules, applying the
    /// constraint adjustment when a constraint box is set (F1).
    fn recomputeGeometry(p: *XdgPopup) void {
        p.geometry = if (p.constraint_box) |box|
            p.positioner_rules.constrainedGeometry(box)
        else
            p.positioner_rules.geometry();
    }

    /// Set the compositor-side usable area for this popup. When a box is
    /// set, the next configure (and any reposition) places the popup
    /// within it per the positioner's constraint_adjustment bits.
    pub fn setConstraintBox(p: *XdgPopup, box: geom.Rect) void {
        p.constraint_box = box;
    }

    /// Record where the popup surface sits in the scene, in WORLD
    /// pixels. The SERVER's scene sync calls this every frame, after
    /// resolving the popup's absolute position (call site:
    /// `syncPopupNodes` in src/server/main.zig, which owns the layout
    /// this module cannot see). The popup grab needs it because the
    /// seat hands input events in SCREEN coordinates while
    /// wl_pointer.enter/motion carry surface-local ones
    /// (wayland.xml:2224-2232) — the two spaces differ by the camera,
    /// which the popup grab converts through before subtracting
    /// (see localPointFromScreen).
    pub fn setPopupOrigin(popup: *XdgPopup, x: f64, y: f64) void {
        popup.origin = .{ .x = x, .y = y };
    }

    /// The popup's absolute rectangle in WORLD coordinates: the synced
    /// origin plus the configured size. `geometry.x/y` are parent-
    /// relative and are NOT added here — the origin already absorbs
    /// the parent's own scene position.
    fn absoluteRect(popup: *const XdgPopup) geom.FRect {
        return .{
            .x = popup.origin.x,
            .y = popup.origin.y,
            .width = @floatFromInt(popup.geometry.width),
            .height = @floatFromInt(popup.geometry.height),
        };
    }

    /// The seat's SCREEN coordinates `x, y` expressed in this popup's
    /// surface-local space. The seat reports pointer input in output
    /// pixels while `origin` is a WORLD coordinate (SceneNode.
    /// absolutePosition), so the point is converted screen → world
    /// first — the same order `pickSurface` uses (main.zig:3692-3695).
    /// Subtracting the two spaces directly is invisible under the
    /// default identity camera and wrong under any zoom or pan: the
    /// hit-test would then judge a different rectangle than the one the
    /// user sees, and a click visibly inside the popup would dismiss
    /// it.
    ///
    /// Negative results are normal: a pointer left of or above the
    /// popup still has a well-defined surface-local position, and the
    /// protocol carries it as such (wayland.xml:2206-2209, the enter
    /// event's "surface-local x coordinate").
    fn localPointFromScreen(popup: *const XdgPopup, x: i32, y: i32) geom.FPoint {
        const world = popup.xdg_surface.shell.worldFromScreen(x, y);
        return .{ .x = world.x - popup.origin.x, .y = world.y - popup.origin.y };
    }

    /// Send the initial/popup configure: xdg_popup.configure with the
    /// positioner-derived (and constraint-adjusted) geometry, then
    /// xdg_surface.configure with the serial.
    pub fn configure(p: *XdgPopup) !void {
        const xdg = p.xdg_surface;
        p.recomputeGeometry();
        const serial = xdg.shell.display.nextSerial();
        p.resource.sendConfigure(p.geometry.x, p.geometry.y, p.geometry.width, p.geometry.height);
        xdg.sendConfigureEvent(serial);
        p.sent_payloads.append(p.allocator, .{ .serial = serial, .geometry = p.geometry }) catch {
            p.resource.postNoMemory();
        };
        log.info("popup configure serial={d} at ({d},{d}) {d}x{d}", xdg.io, xdg.log_cfg, log_tag, .{
            serial,
            p.geometry.x,
            p.geometry.y,
            p.geometry.width,
            p.geometry.height,
        });
    }

    /// Compositor-driven configure (X08): re-place and re-send the
    /// configure — the reply to the client's initial commit, or a
    /// reactive re-configure after a constraint/positioner change.
    /// Called from the initial_commit signal (or any arrange pass); the
    /// module never self-configures (wlroots: the compositor drives
    /// wlr_xdg_surface_schedule_configure).
    pub fn scheduleConfigure(p: *XdgPopup) !void {
        try p.configure();
    }

    /// Apply the acked configure's geometry (wlroots
    /// handle_xdg_popup_ack_configure): the acked geometry is what the
    /// client committed against. Payloads up to the acked serial are
    /// dropped.
    fn applyAckedConfigure(p: *XdgPopup, serial: u32) void {
        var i: usize = 0;
        while (i < p.sent_payloads.items.len) {
            const payload = p.sent_payloads.items[i];
            if (payload.serial == serial) p.acked_geometry = payload.geometry;
            if (payload.serial <= serial) {
                _ = p.sent_payloads.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Dismiss the popup from the compositor side (xdg_popup.popup_done).
    pub fn sendPopupDone(p: *XdgPopup) void {
        p.resource.sendPopupDone();
    }

    /// Compositor-initiated reactive reconfigure (X05): recompute the
    /// geometry from the current positioner rules (reusing the F1
    /// constraint machinery) and re-send the configure sequence with a
    /// fresh reposition token.
    ///
    /// Re-configuration is only permitted for popups bound at v3+ whose
    /// positioner requested `set_reactive` — the smithay model
    /// (shell/xdg/mod.rs:1909-1923) checks the last-acked positioner's
    /// reactive flag; our `positioner_rules` are the rules in effect
    /// (they change only at get_popup/reposition, both of which are
    /// followed by acks before a reconfigure), so the two agree. A
    /// non-reactive or below-v3 popup is refused with `error.NotReactive`
    /// — there is no `not_reactive` wire error in the protocol, so the
    /// rejection is compositor-side (smithay returns
    /// `PopupConfigureError::NotReactive` the same way). The v3 gate also
    /// keeps `repositioned` (since v3) structurally unreachable below v3
    /// (X09).
    ///
    /// The compositor-driven trigger (parent move/resize re-sends) is a
    /// follow-up: XdgSurface has no move/resize signal, so the request
    /// path (xdg_popup.reposition) is the only wired trigger; this is
    /// the API the follow-up trigger will call.
    pub fn reconfigure(p: *XdgPopup, token: u32) error{NotReactive}!void {
        if (p.resource.getVersion() < 3 or !p.positioner_rules.reactive) {
            return error.NotReactive;
        }
        p.recomputeGeometry();
        // X09: repositioned is since v3; reconfigure already requires
        // v3, so this is defense-in-depth (same pattern as the
        // reposition handler).
        if (p.resource.getVersion() >= 3) {
            p.resource.sendRepositioned(token);
        }
        p.configure() catch p.resource.postNoMemory();
    }
};

// ---------------------------------------------------------------------------
// Popup seat grab (X04b): xdg_popup.grab installs pointer + keyboard grabs
// that route input to the popup's client until the grab is dismissed.
// ---------------------------------------------------------------------------

/// Per-popup grab state (allocated on xdg_popup.grab, freed in
/// popupDestroy). One allocation backs BOTH the pointer grab and the
/// keyboard grab (`data` of each points here): a single `active` flag
/// makes ending idempotent — the seat's end*Grab invokes the grab's
/// cancel handler, and the cancel path must not recurse or dismiss
/// twice (wlroots' xdg_popup_grab_end relies on the default-grab swap
/// for the same property, wlr_xdg_popup.c:41-51).
const PopupGrab = struct {
    popup: *XdgPopup,
    /// Null once the seat is gone (seat_destroy_listener): teardown must
    /// not call into a freed seat (main.zig frees the seat BEFORE the
    /// shell's popups, main.zig:446-453).
    seat: ?*seat_mod.Seat,
    /// The grabs are installed on the seat. Cleared exactly once, by
    /// popupGrabEnd; every later end/cancel becomes a no-op.
    active: bool = true,
    /// The popup's client received a pointer enter for the popup surface
    /// (the seat never hit-tests while a grab is installed, so the grab
    /// delivers the enter itself on the first motion). Cleared when
    /// popupGrabEnd sends the leave that balances it — an enter with no
    /// leave leaves the client holding the popup surface as its pointer
    /// focus forever (wayland.xml:2212-2218).
    pointer_entered: bool = false,
    /// The seat's grab slots this state owns. No defaults: the install
    /// literal in popupRequest writes both, and a default would be dead
    /// state — nothing reads either slot before the seat is handed a
    /// pointer to it.
    pointer_grab: seat_mod.PointerGrab,
    keyboard_grab: seat_mod.KeyboardGrab,
    /// The last SCREEN coordinates this grab's motion handler saw. The
    /// seat's own pointer_x/pointer_y are module-private, and
    /// every motion routes through popupGrabMotion while the grab is
    /// installed, so this is the position a button event belongs to.
    /// has_position stays false until the first motion: a button that
    /// arrives before one has no known position, and the grab never
    /// delivers a press at coordinates it invented.
    last_x: i32 = 0,
    last_y: i32 = 0,
    has_position: bool = false,
    /// Buttons whose press reached the popup client and whose release
    /// is still owed to it. A client must never see a release whose
    /// press it never got, and the seat's own held-button set is only
    /// maintained on the default delivery path (seat.zig records it
    /// in pointerButton, never for grab-routed events), so the grab
    /// keeps its own — same shape as the seat's, seat.zig:339-340.
    // SAFETY: only the first held_button_count entries are ever read;
    // both fields start at 0 and every write is guarded by the count.
    held_buttons: [16]u32 = undefined,
    held_button_count: usize = 0,

    /// Fires when the seat dies first: clears the seat reference so
    /// popupDestroy never touches freed seat memory.
    seat_destroy_listener: wire.Listener(*seat_mod.Seat),
};

/// Remember that a press for `button` reached the popup client, so its
/// release is delivered to the same client. The set is small and
/// duplicate-free: one entry per physical button the client holds.
fn notePopupGrabPress(g: *PopupGrab, button: u32) void {
    if (g.held_button_count >= g.held_buttons.len) return;
    if (std.mem.indexOfScalar(u32, g.held_buttons[0..g.held_button_count], button) != null) return;
    g.held_buttons[g.held_button_count] = button;
    g.held_button_count += 1;
}

/// Drop the press for `button`, reporting whether it had been
/// delivered. False means this grab never sent the press, so it must
/// not send the matching release.
fn takePopupGrabPress(g: *PopupGrab, button: u32) bool {
    const idx = std.mem.indexOfScalar(u32, g.held_buttons[0..g.held_button_count], button) orelse return false;
    g.held_buttons[idx] = g.held_buttons[g.held_button_count - 1];
    g.held_button_count -= 1;
    return true;
}

/// End the popup grab (dismiss or teardown). Sends popup_done when
/// `dismiss` — a grab-owned dismissal (a press outside the popup, or
/// the grab being cancelled/replaced); teardown paths have already
/// sent popup_done or need none. Idempotent: only the first call acts,
/// so the cancel handlers that run inside end*Grab (which call back
/// into this) cannot recurse.
///
/// Grabs are ended by OWNERSHIP, not by seat: a grab another
/// subsystem installed after this one must survive (a keyboard grab
/// armed while the popup grab was live replaces the seat's keyboard
/// slot, and ending it here would cancel a grab this popup never
/// owned — the same check Drag.end makes, data_device.zig:335).
fn popupGrabEnd(g: *PopupGrab, dismiss: bool) void {
    if (!g.active) return;
    g.active = false;
    if (dismiss) g.popup.sendPopupDone();
    const seat = g.seat orelse return;
    // The owed pointer events go out BEFORE the grabs end: once the
    // seat's default path is back it delivers the release of a still
    // held button to whatever `pointer_focus` happens to hold — a value
    // this grab never re-picked, because the seat does not hit-test
    // under a grab (seat.zig:877-883). That release would reach a client
    // that never saw the press, or nobody at all when the focus is null
    // (the seat delivers to the focus only, seat.zig:1015), stranding
    // the button down on the popup client.
    popupGrabFlushPointer(g);
    if (seat.pointer_grab == &g.pointer_grab) seat.endPointerGrab();
    if (seat.keyboard_grab == &g.keyboard_grab) seat.endKeyboardGrab();
}

/// Close out the grab's pointer stream: `button(released)` for every
/// press this grab delivered whose physical release never arrived, then
/// the `wl_pointer.leave` that balances the enter this grab sent.
///
/// Both are owed to the popup's CLIENT, and both are per the protocol
/// non-optional once the matching enter/press went out:
///  - `wl_pointer.button` carries no surface, so its position and its
///    pairing are read off "the last motion, warp or enter event"
///    (wayland.xml:2244-2252) — a release delivered after the leave
///    that ended that enter belongs to no surface the client holds.
///  - `wl_pointer.leave` "is sent before the enter notification for
///    the new focus" (wayland.xml:2212-2218), so the popup's enter
///    must be closed by one; a client left with a dangling enter keeps
///    the popup surface as its pointer focus forever. wlroots sends
///    this leave when the popup grab ends (wlr_xdg_popup.c
///    xdg_pointer_grab_end).
///
/// Only what this grab actually delivered is sent: the press must have
/// reached the client and the enter must have been sent — a grab that
/// never entered owes no leave, and a press the client never saw owes
/// no release.
fn popupGrabFlushPointer(g: *PopupGrab) void {
    const seat = g.seat orelse return;
    const popup = g.popup;
    const wl_client = popup.resource.getClient();
    const held = g.held_button_count;
    g.held_button_count = 0;
    var i: usize = 0;
    while (i < held) : (i += 1) {
        const serial = seat.serialFor(wl_client);
        sendPopupGrabButton(seat, wl_client, serial, g.held_buttons[i], .released);
    }
    if (!g.pointer_entered) return;
    g.pointer_entered = false;
    const serial = seat.serialFor(wl_client);
    var delivered = false;
    for (seat.pointers.items) |ptr| {
        if (ptr.getClient() != wl_client) continue;
        ptr.sendLeave(serial, popup.xdg_surface.surface.resource);
        delivered = true;
    }
    if (delivered) seat.markFramePending(wl_client);
}

/// The pointer grab was cancelled (replaced by another grab or ended):
/// dismiss the popup (wlroots xdg_pointer_grab_cancel ->
/// xdg_popup_grab_end, wlr_xdg_popup.c:95-97). Also runs when the popup
/// grab itself ends, where popupGrabEnd's active flag makes it a no-op.
fn popupGrabPointerCancel(seat: *seat_mod.Seat, grab: *const seat_mod.PointerGrab) void {
    _ = seat;
    const g: *PopupGrab = @ptrCast(@alignCast(grab.data.?));
    popupGrabEnd(g, true);
}

/// The keyboard grab was cancelled: same dismissal as the pointer
/// cancel (wlroots xdg_keyboard_grab_cancel, wlr_xdg_popup.c:133-136).
fn popupGrabKeyboardCancel(seat: *seat_mod.Seat, grab: *const seat_mod.KeyboardGrab) void {
    _ = seat;
    const g: *PopupGrab = @ptrCast(@alignCast(grab.data.?));
    popupGrabEnd(g, true);
}

/// Route pointer motion to the popup's client's pointer resources
/// (wlroots xdg_pointer_grab_motion, wlr_xdg_popup.c:64-66). The seat
/// never hit-tests under a grab, so the grab delivers the enter for the
/// popup surface itself on the first motion.
///
/// Coordinates go out SURFACE-LOCAL, as the protocol requires
/// (wayland.xml:2224-2232, "the location relative to the focused
/// surface"), so the seat's SCREEN coordinates are converted to world
/// space and then through the popup's synced origin (setPopupOrigin)
/// before the 24.8 fixed-point encoding. The conversion is unclamped:
/// a pointer left of or above the popup has a negative surface-local
/// coordinate, which is what the wire carries.
fn popupGrabMotion(seat: *seat_mod.Seat, grab: *const seat_mod.PointerGrab, x: i32, y: i32) void {
    const g: *PopupGrab = @ptrCast(@alignCast(grab.data.?));
    if (!g.active) return;
    // The seat's own pointer_x/pointer_y are module-private and every
    // motion routes here while the grab is installed, so this is where
    // a later button event's position comes from.
    g.last_x = x;
    g.last_y = y;
    g.has_position = true;
    const popup = g.popup;
    const wl_client = popup.resource.getClient();
    const local = popup.localPointFromScreen(x, y);
    const fx = wire.wl.Fixed.fromDouble(local.x);
    const fy = wire.wl.Fixed.fromDouble(local.y);
    if (!g.pointer_entered) {
        g.pointer_entered = true;
        const serial = seat.serialFor(wl_client);
        var delivered = false;
        for (seat.pointers.items) |ptr| {
            if (ptr.getClient() != wl_client) continue;
            ptr.sendEnter(serial, popup.xdg_surface.surface.resource, fx, fy);
            delivered = true;
        }
        if (delivered) seat.markFramePending(wl_client);
    }
    const time = seat.nowMs();
    var delivered = false;
    for (seat.pointers.items) |ptr| {
        if (ptr.getClient() != wl_client) continue;
        ptr.sendMotion(time, fx, fy);
        delivered = true;
    }
    if (delivered) seat.markFramePending(wl_client);
}

/// Send a button event to every pointer resource of `wl_client` and
/// mark the input batch, so the batch closes with the next
/// wl_pointer.frame (wlroots wlr_seat_pointer.c:394-402). Only the
/// receiving client's pointers are iterated — the same set the seat's
/// own default path walks (seat.zig:969-974, mirroring wlroots'
/// wlr_seat_pointer_send_button).
fn sendPopupGrabButton(
    seat: *seat_mod.Seat,
    wl_client: *wire.Client,
    serial: u32,
    button: u32,
    state: server.wl.Pointer.ButtonState,
) void {
    const time = seat.nowMs();
    var delivered = false;
    for (seat.pointers.items) |ptr| {
        if (ptr.getClient() != wl_client) continue;
        ptr.sendButton(serial, time, button, state);
        delivered = true;
    }
    if (delivered) seat.markFramePending(wl_client);
}

/// Whether `wl_client` still has a pointer resource able to receive the
/// event (wlroots sends to focused_client->pointers only, the same set
/// the seat's default path walks — seat.zig:969-974).
fn seatHasPointerFor(seat: *seat_mod.Seat, wl_client: *wire.Client) bool {
    for (seat.pointers.items) |ptr| {
        if (ptr.getClient() == wl_client) return true;
    }
    return false;
}

/// A press INSIDE the popup reaches the popup's client and the grab
/// stays (wlroots xdg_pointer_button: the press is delivered when the
/// pointer is inside the popup's geometry, and the grab ends only when
/// it is not, wlr_xdg_popup.c:69-80). A press outside the popup — or
/// one the client cannot receive at all — dismisses with popup_done.
///
/// A release is delivered only for a press this grab delivered: a
/// client must never see a release whose press it never got. The seat
/// already synthesizes releases for the buttons held when the grab was
/// installed (seat.zig:766-784), so those presses are accounted for
/// before the grab takes over.
fn popupGrabButton(seat: *seat_mod.Seat, grab: *const seat_mod.PointerGrab, button: u32, pressed: bool) void {
    const g: *PopupGrab = @ptrCast(@alignCast(grab.data.?));
    if (!g.active) return;
    const popup = g.popup;
    const wl_client = popup.resource.getClient();
    if (!pressed) {
        // No delivered press, no release.
        if (!takePopupGrabPress(g, button)) return;
        const serial = seat.serialFor(wl_client);
        sendPopupGrabButton(seat, wl_client, serial, button, .released);
        return;
    }
    // Inside is judged in the popup's own WORLD rect (absoluteRect) with
    // the pointer converted into that space first: mixing the seat's
    // screen pixels with a world origin would test a rectangle the user
    // never sees.
    const rect = popup.absoluteRect();
    const local = popup.localPointFromScreen(g.last_x, g.last_y);
    const inside = g.has_position and
        local.x >= 0 and local.x < rect.width and
        local.y >= 0 and local.y < rect.height;
    if (!inside or !seatHasPointerFor(seat, wl_client)) {
        popupGrabEnd(g, true);
        return;
    }
    const serial = seat.serialFor(wl_client);
    sendPopupGrabButton(seat, wl_client, serial, button, .pressed);
    notePopupGrabPress(g, button);
}

/// Axis events are swallowed during the popup grab: the X04b routing
/// scope is enter/motion/button/frame, and the v120/source accumulation
/// the seat does for the focused path is not replicated here (scroll
/// during a menu grab is a compositor-policy follow-up, like wlroots'
/// own axis forwarding).
fn popupGrabAxis(
    seat: *seat_mod.Seat,
    grab: *const seat_mod.PointerGrab,
    axis: server.wl.Pointer.Axis,
    source: server.wl.Pointer.AxisSource,
    value: f64,
    discrete: i32,
    direction: server.wl.Pointer.AxisRelativeDirection,
) void {
    _ = seat;
    _ = grab;
    _ = axis;
    _ = source;
    _ = value;
    _ = discrete;
    _ = direction;
}

/// Route a key event to the popup's client's keyboards (wlroots
/// xdg_keyboard_grab_key, wlr_xdg_popup.c:121-125). The wire keycode is
/// the evdev scancode (xkb keycode minus 8), same as the seat's own
/// delivery.
fn popupGrabKey(seat: *seat_mod.Seat, grab: *const seat_mod.KeyboardGrab, keycode: u32, pressed: bool) void {
    const g: *PopupGrab = @ptrCast(@alignCast(grab.data.?));
    if (!g.active) return;
    const popup = g.popup;
    const wl_client = popup.resource.getClient();
    const serial = seat.serialFor(wl_client);
    const time = seat.nowMs();
    const state: server.wl.Keyboard.KeyState = if (pressed) .pressed else .released;
    for (seat.keyboards.items) |kbd| {
        if (kbd.getClient() != wl_client) continue;
        kbd.sendKey(serial, time, keycode - 8, state);
    }
}

/// Route a modifier change to the popup's client's keyboards (wlroots
/// xdg_keyboard_grab_modifiers, wlr_xdg_popup.c:127-131). The seat's
/// modifier state is already updated before the grab runs.
fn popupGrabModifiers(seat: *seat_mod.Seat, grab: *const seat_mod.KeyboardGrab) void {
    const g: *PopupGrab = @ptrCast(@alignCast(grab.data.?));
    if (!g.active) return;
    const popup = g.popup;
    const wl_client = popup.resource.getClient();
    const serial = seat.serialFor(wl_client);
    for (seat.keyboards.items) |kbd| {
        if (kbd.getClient() != wl_client) continue;
        kbd.sendModifiers(serial, seat.mods_depressed, seat.mods_latched, seat.mods_locked, seat.mods_group);
    }
}

/// The seat is being destroyed: its grab fields die with it, so the
/// popup side must stop calling into it (the seat can die before the
/// shell's popups at server shutdown). Detach the listener — the link
/// would otherwise dangle into the freed signal list (wlroots
/// xdg_popup_grab_handle_seat_destroy, wlr_xdg_popup.c:204-216).
fn onPopupGrabSeatDestroy(listener: *wire.Listener(*seat_mod.Seat), _: *seat_mod.Seat) void {
    const g: *PopupGrab = @fieldParentPtr("seat_destroy_listener", listener);
    g.seat = null;
    g.seat_destroy_listener.link.remove();
}

fn popupRequest(popup_res: *server.xdg.Popup, request: server.xdg.Popup.Request, popup: *XdgPopup) void {
    _ = popup_res;
    switch (request) {
        // X04a: destroying a non-topmost popup is an error (wlroots
        // xdg_popup_handle_destroy, wlr_xdg_popup.c:351-355): popups
        // created on top of this one must be destroyed first, deepest
        // first. The check reads this surface's child list.
        .destroy => {
            if (popup.xdg_surface.popups.items.len != 0) {
                popup.xdg_surface.wm_base.res.postError(
                    .not_the_topmost_popup,
                    "xdg_popup was not created on the topmost popup",
                );
                return;
            }
            // Destructor: libwayland does not auto-destroy; we do (runs popupDestroy).
            popup.resource.destroy();
        },
        // X04a error surface + X04b real grabs (wlroots
        // xdg_popup_handle_grab, wlr_xdg_popup.c:288-313): a mapped
        // popup cannot grab (invalid_grab on the popup), a non-topmost
        // popup cannot grab (not_the_topmost_popup on the wm_base); a
        // valid grab installs pointer + keyboard grabs routing to the
        // popup's client.
        .grab => |r| {
            if (popup.xdg_surface.surface.mapped) {
                popup.resource.postError(.invalid_grab, "xdg_popup is already mapped");
                return;
            }
            if (popup.xdg_surface.popups.items.len != 0) {
                popup.xdg_surface.wm_base.res.postError(
                    .not_the_topmost_popup,
                    "xdg_popup was not created on the topmost popup",
                );
                return;
            }
            // X04b: the request must echo a serial the seat recently
            // handed to THIS client (the XML: grab must be issued in
            // response to a user action). Same validation as main.zig's
            // move handler (main.zig:1055); an invalid serial ignores
            // the request — never a protocol error (wlroots
            // wlr_seat_client_validate_event_serial semantics).
            const seat = seatFromResource(r.seat);
            if (!seat.validateEventSerial(popup.resource.getClient(), r.serial)) {
                log.debug(
                    "xdg_popup.grab ignored: serial {d} not issued to this client",
                    popup.io,
                    popup.log_cfg,
                    log_tag,
                    .{r.serial},
                );
                return;
            }
            // A second grab on the same (unmapped) popup is a client
            // bug: keep the first.
            if (popup.grab_state != null) return;
            const g = popup.allocator.create(PopupGrab) catch {
                popup.resource.postNoMemory();
                return;
            };
            g.* = .{
                .popup = popup,
                .seat = seat,
                .pointer_grab = .{
                    .data = g,
                    .motion = popupGrabMotion,
                    .button = popupGrabButton,
                    .axis = popupGrabAxis,
                    .cancel = popupGrabPointerCancel,
                },
                .keyboard_grab = .{
                    .data = g,
                    .key = popupGrabKey,
                    .modifiers = popupGrabModifiers,
                    .cancel = popupGrabKeyboardCancel,
                },
                .seat_destroy_listener = wire.Listener(*seat_mod.Seat).init(onPopupGrabSeatDestroy),
            };
            g.seat_destroy_listener.link.prev = null;
            g.seat_destroy_listener.link.next = null;
            seat.events.destroy.add(&g.seat_destroy_listener);
            popup.grab_state = g;
            seat.startPointerGrab(&g.pointer_grab);
            seat.startKeyboardGrab(&g.keyboard_grab);
            log.info("xdg_popup.grab installed serial={d}", popup.io, popup.log_cfg, log_tag, .{r.serial});
        },
        .reposition => |r| {
            // Per the XML, the positioner must be complete; an incomplete
            // one is invalid_positioner on the wm_base (wlroots
            // xdg_popup_handle_reposition, wlr_xdg_popup.c:317-343).
            const positioner: *PositionerState = @ptrCast(@alignCast(r.positioner.getUserData()));
            if (!positioner.isComplete()) {
                popup.xdg_surface.wm_base.res.postError(
                    .invalid_positioner,
                    "xdg_popup.reposition: positioner object is not complete",
                );
                return;
            }
            // Copy the new rules and re-place (wlroots: rules + geometry
            // into scheduled, then configure; ours is synchronous).
            popup.positioner_rules = positioner.*;
            popup.recomputeGeometry();
            // X09: repositioned is since v3 (xdg-shell.xml:1398); a
            // below-v3 binding must never receive it. The request itself
            // is also v3+, and X05's reconfigure requires v3 the same
            // way, so this is defense-in-depth.
            if (popup.resource.getVersion() >= 3) {
                popup.resource.sendRepositioned(r.token);
            }
            popup.configure() catch popup.resource.postNoMemory();
        },
    }
}

fn popupDestroy(popup_res: *server.xdg.Popup, popup: *XdgPopup) void {
    _ = popup_res;
    const shell = popup.xdg_surface.shell;
    // F12: destroy descendant popups first (wlroots wlr_xdg_popup_destroy
    // recurses children before the parent, wlr_xdg_popup.c:485-499 — the
    // compositor-side teardown; the client-side destroy REQUEST rejects
    // non-topmost popups via the X04a check). A child popup Q created on
    // top of P is tracked in P.xdg_surface.popups (Q's parent IS P's
    // xdg_surface); each child's destructor recurses in turn, deepest
    // first. The loop drains the list because each child's destructor
    // detaches it.
    while (popup.xdg_surface.popups.items.len > 0) {
        popup.xdg_surface.popups.items[0].resource.destroy();
    }
    if (std.mem.findScalar(*XdgPopup, shell.popups.items, popup)) |i| {
        _ = shell.popups.swapRemove(i);
    }
    // X04a: detach from the parent's child list (swap-remove like the
    // shell list above); layer-parented popups are not tracked.
    if (popup.parent) |parent_xdg| {
        if (std.mem.findScalar(*XdgPopup, parent_xdg.popups.items, popup)) |i| {
            _ = parent_xdg.popups.swapRemove(i);
        }
    }
    // X04b: end any active grab BEFORE freeing the popup — the seat's
    // grab.data would dangle (wlroots reset_xdg_popup, wlr_xdg_popup.c:
    // 444-464). `dismiss` is false: every path into popupDestroy has
    // already sent popup_done (parent unmap) or needs none (client
    // destroy / disconnect / teardown), so the grab end must not send a
    // duplicate. When the seat died first, its grabs are gone and
    // popupGrabEnd skips the seat calls (seat == null).
    if (popup.grab_state) |g| {
        popupGrabEnd(g, false);
        // The seat-destroy listener may still be attached (seat alive);
        // when the seat died, the handler already detached it.
        if (g.seat_destroy_listener.link.prev != null) g.seat_destroy_listener.link.remove();
        popup.allocator.destroy(g);
        popup.grab_state = null;
    }
    popup.events.destroy.emit(popup);
    const xdg = popup.xdg_surface;
    xdg.popup = null;
    xdg.role = .none;
    // F8: role-object destruction resets the configure state machine even
    // when the surface never mapped (unmapSurface early-returns on
    // !mapped, so the reset must run explicitly).
    xdg.resetConfigureState();
    xdg.unmapSurface();
    popup.sent_payloads.deinit(shell.allocator);
    shell.allocator.destroy(popup);
}

// ---------------------------------------------------------------------------
// XdgPositioner: client-side rules captured per xdg_positioner object.
// ---------------------------------------------------------------------------

const PositionerState = struct {
    shell: *XdgShell,
    size: geom.Size = .{ .w = 0, .h = 0 },
    size_set: bool = false,
    anchor_rect: geom.Rect = geom.Rect.empty(),
    anchor_rect_set: bool = false,
    anchor: server.xdg.Positioner.Anchor = .none,
    gravity: server.xdg.Positioner.Gravity = .none,
    offset: geom.Point = .{ .x = 0, .y = 0 },
    constraint_adjustment: server.xdg.Positioner.ConstraintAdjustment = .{},
    reactive: bool = false,
    parent_size: geom.Size = .{ .w = 0, .h = 0 },
    parent_configure_serial: u32 = 0,

    /// Compute the popup geometry from the positioner rules: the anchor point
    /// of the anchor rect, the gravity offset, then the surface offset.
    /// Matches wlr_xdg_positioner_rules_get_geometry (wlr_xdg_positioner.c:221).
    pub fn geometry(self: *const PositionerState) geom.Rect {
        var box: geom.Rect = .{
            .x = self.offset.x,
            .y = self.offset.y,
            .width = self.size.w,
            .height = self.size.h,
        };
        const ae = positionerEdges(@backingInt(self.anchor));
        if (ae.top) {
            box.y += self.anchor_rect.y;
        } else if (ae.bottom) {
            box.y += self.anchor_rect.y + self.anchor_rect.height;
        } else {
            box.y += self.anchor_rect.y + @divTrunc(self.anchor_rect.height, 2);
        }
        if (ae.left) {
            box.x += self.anchor_rect.x;
        } else if (ae.right) {
            box.x += self.anchor_rect.x + self.anchor_rect.width;
        } else {
            box.x += self.anchor_rect.x + @divTrunc(self.anchor_rect.width, 2);
        }
        const ge = positionerEdges(@backingInt(self.gravity));
        if (ge.top) {
            box.y -= box.height;
        } else if (!ge.bottom) {
            box.y -= @divTrunc(box.height, 2);
        }
        if (ge.left) {
            box.x -= box.width;
        } else if (!ge.right) {
            box.x -= @divTrunc(box.width, 2);
        }
        return box;
    }

    /// The positioner is complete when set_size and set_anchor_rect were
    /// called with positive values (F13). wlroots requires
    /// `size.width > 0 && anchor_rect.width > 0`
    /// (wlr_xdg_positioner_is_complete, wlr_xdg_positioner.c:216); we
    /// additionally require a positive anchor-rect height so a degenerate
    /// 0-height anchor rect cannot produce a zero-area popup. The XML
    /// only says "set_size and set_anchor_rect must be called"; the
    /// zero-size anchor rect is undefined territory and wlroots is
    /// stricter than the XML text.
    pub fn isComplete(self: *const PositionerState) bool {
        return self.size_set and self.anchor_rect_set and
            self.size.w > 0 and self.size.h > 0 and
            self.anchor_rect.width > 0 and self.anchor_rect.height > 0;
    }

    /// Raw placement geometry constrained to `constraint`: applies the
    /// client's constraint_adjustment bits in the wlroots order — flip,
    /// then slide, then resize; a step that fully unconstrains wins (F1,
    /// wlr_xdg_positioner.c:500-518).
    pub fn constrainedGeometry(self: *const PositionerState, constraint: geom.Rect) geom.Rect {
        var box = self.geometry();
        unconstrainBox(self, constraint, &box);
        return box;
    }
};

/// Distances from each edge of `box` to the corresponding edge of
/// `constraint`. Positive = the box edge is outside the constraint;
/// negative = inside (wlroots constraint_offsets,
/// wlr_xdg_positioner.c:327-340).
const ConstraintOffsets = struct {
    top: i32,
    bottom: i32,
    left: i32,
    right: i32,
};

fn constrainedBoxOffsets(constraint: geom.Rect, box: geom.Rect) ConstraintOffsets {
    return .{
        .left = constraint.x - box.x,
        .right = box.x + box.width - constraint.x - constraint.width,
        .top = constraint.y - box.y,
        .bottom = box.y + box.height - constraint.y - constraint.height,
    };
}

fn isUnconstrained(offsets: ConstraintOffsets) bool {
    return offsets.top <= 0 and offsets.bottom <= 0 and
        offsets.left <= 0 and offsets.right <= 0;
}

/// The flip step (F1): flip the anchor/gravity on an axis when exactly one
/// edge of that axis is constrained and the client requested flip_*;
/// only apply a flip that actually helps (wlroots
/// xdg_positioner_rules_unconstrain_by_flip, wlr_xdg_positioner.c:340-385).
fn unconstrainByFlip(
    rules: *const PositionerState,
    constraint: geom.Rect,
    box: *geom.Rect,
    offsets: *ConstraintOffsets,
) bool {
    const adj = adjustmentBits(rules.constraint_adjustment);
    const flip_x = ((offsets.left > 0) != (offsets.right > 0)) and (adj & flip_x_bit) != 0;
    const flip_y = ((offsets.top > 0) != (offsets.bottom > 0)) and (adj & flip_y_bit) != 0;
    if (!flip_x and !flip_y) return false;

    var flipped = rules.*;
    if (flip_x) {
        flipped.anchor = anchorInvertX(flipped.anchor);
        flipped.gravity = gravityInvertX(flipped.gravity);
    }
    if (flip_y) {
        flipped.anchor = anchorInvertY(flipped.anchor);
        flipped.gravity = gravityInvertY(flipped.gravity);
    }
    const flipped_box = flipped.geometry();
    const flipped_offsets = constrainedBoxOffsets(constraint, flipped_box);
    // Only apply a flip that helps on the axis (wlroots comment: "Only
    // apply flipping if it helps").
    if (flipped_offsets.left <= 0 and flipped_offsets.right <= 0) {
        box.x = flipped_box.x;
        offsets.left = flipped_offsets.left;
        offsets.right = flipped_offsets.right;
    }
    if (flipped_offsets.top <= 0 and flipped_offsets.bottom <= 0) {
        box.y = flipped_box.y;
        offsets.top = flipped_offsets.top;
        offsets.bottom = flipped_offsets.bottom;
    }
    return isUnconstrained(offsets.*);
}

/// The slide step (F1): shift the box the minimum distance that
/// unconstrains one edge or constrains another; when the box fully
/// contains the anchor rect, slide toward the gravity (falling back to
/// right/bottom, GTK-compatible) (wlroots
/// xdg_positioner_rules_unconstrain_by_slide, wlr_xdg_positioner.c:386-453).
fn unconstrainBySlide(
    rules: *const PositionerState,
    constraint: geom.Rect,
    box: *geom.Rect,
    offsets: *ConstraintOffsets,
) bool {
    const adj = adjustmentBits(rules.constraint_adjustment);
    const ge = positionerEdges(@backingInt(rules.gravity));
    const slide_x = (offsets.left > 0 or offsets.right > 0) and (adj & slide_x_bit) != 0;
    const slide_y = (offsets.top > 0 or offsets.bottom > 0) and (adj & slide_y_bit) != 0;
    if (!slide_x and !slide_y) return false;

    if (slide_x) {
        if (offsets.left > 0 and offsets.right > 0) {
            // The box is bigger than the anchor rect and completely
            // includes it: slide toward the gravity (wlroots: the second
            // slide would fail immediately).
            if (ge.left) {
                box.x -= offsets.right;
            } else {
                box.x += offsets.left;
            }
        } else {
            // Slide the minimal distance that satisfies one edge.
            const abs_left = if (offsets.left > 0) offsets.left else -offsets.left;
            const abs_right = if (offsets.right > 0) offsets.right else -offsets.right;
            if (abs_left < abs_right) {
                box.x += offsets.left;
            } else {
                box.x -= offsets.right;
            }
        }
    }
    if (slide_y) {
        if (offsets.top > 0 and offsets.bottom > 0) {
            if (ge.top) {
                box.y -= offsets.bottom;
            } else {
                box.y += offsets.top;
            }
        } else {
            const abs_top = if (offsets.top > 0) offsets.top else -offsets.top;
            const abs_bottom = if (offsets.bottom > 0) offsets.bottom else -offsets.bottom;
            if (abs_top < abs_bottom) {
                box.y += offsets.top;
            } else {
                box.y -= offsets.bottom;
            }
        }
    }
    offsets.* = constrainedBoxOffsets(constraint, box.*);
    return isUnconstrained(offsets.*);
}

/// The resize step (F1): clip the box to the constraint on the requested
/// axes; give up when the result would be empty (wlroots
/// xdg_positioner_rules_unconstrain_by_resize, wlr_xdg_positioner.c:454-498).
fn unconstrainByResize(
    rules: *const PositionerState,
    constraint: geom.Rect,
    box: *geom.Rect,
    offsets: *ConstraintOffsets,
) bool {
    const adj = adjustmentBits(rules.constraint_adjustment);
    const resize_x = (offsets.left > 0 or offsets.right > 0) and (adj & resize_x_bit) != 0;
    const resize_y = (offsets.top > 0 or offsets.bottom > 0) and (adj & resize_y_bit) != 0;
    if (!resize_x and !resize_y) return false;

    var clamped = offsets.*;
    if (clamped.left < 0) clamped.left = 0;
    if (clamped.right < 0) clamped.right = 0;
    if (clamped.top < 0) clamped.top = 0;
    if (clamped.bottom < 0) clamped.bottom = 0;

    var resized = box.*;
    if (resize_x) {
        resized.x += clamped.left;
        resized.width -= clamped.left + clamped.right;
    }
    if (resize_y) {
        resized.y += clamped.top;
        resized.height -= clamped.top + clamped.bottom;
    }
    if (resized.isEmpty()) return false;

    box.* = resized;
    offsets.* = constrainedBoxOffsets(constraint, box.*);
    return isUnconstrained(offsets.*);
}

/// Constraint-adjustment bit positions (wlroots uses a bitmask; the wire
/// values are the same as the XML bitfield).
const slide_x_bit: u32 = 1;
const slide_y_bit: u32 = 2;
const flip_x_bit: u32 = 4;
const flip_y_bit: u32 = 8;
const resize_x_bit: u32 = 16;
const resize_y_bit: u32 = 32;

fn adjustmentBits(adj: server.xdg.Positioner.ConstraintAdjustment) u32 {
    return @bitCast(adj);
}

/// Apply the client's constraint adjustment to `box` in the wlroots order
/// (flip → slide → resize; the first step that unconstrains wins) (F1,
/// wlr_xdg_positioner_rules_unconstrain_box, wlr_xdg_positioner.c:500-518).
fn unconstrainBox(rules: *const PositionerState, constraint: geom.Rect, box: *geom.Rect) void {
    var offsets = constrainedBoxOffsets(constraint, box.*);
    if (isUnconstrained(offsets)) return;
    if (unconstrainByFlip(rules, constraint, box, &offsets)) return;
    if (unconstrainBySlide(rules, constraint, box, &offsets)) return;
    if (unconstrainByResize(rules, constraint, box, &offsets)) return;
}

/// Invert an anchor value across the X axis (wlroots
/// xdg_positioner_anchor_invert_x, wlr_xdg_positioner.c:182-201).
fn anchorInvertX(anchor: server.xdg.Positioner.Anchor) server.xdg.Positioner.Anchor {
    return switch (anchor) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => anchor,
    };
}

/// Invert a gravity value across the X axis (gravity and anchor share
/// their value layout).
fn gravityInvertX(gravity: server.xdg.Positioner.Gravity) server.xdg.Positioner.Gravity {
    return switch (gravity) {
        .left => .right,
        .right => .left,
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
        else => gravity,
    };
}

/// Invert an anchor value across the Y axis (wlroots
/// xdg_positioner_anchor_invert_y).
fn anchorInvertY(anchor: server.xdg.Positioner.Anchor) server.xdg.Positioner.Anchor {
    return switch (anchor) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => anchor,
    };
}

/// Invert a gravity value across the Y axis.
fn gravityInvertY(gravity: server.xdg.Positioner.Gravity) server.xdg.Positioner.Gravity {
    return switch (gravity) {
        .top => .bottom,
        .bottom => .top,
        .top_left => .bottom_left,
        .bottom_left => .top_left,
        .top_right => .bottom_right,
        .bottom_right => .top_right,
        else => gravity,
    };
}

const EdgeSet = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
};

/// Map an xdg_positioner anchor/gravity value to edge bits. The enum values
/// are not bitmasks, so this is an explicit switch (Anchor and Gravity share
/// their value layout). Invalid values behave as none.
fn positionerEdges(value: c_int) EdgeSet {
    return switch (value) {
        1 => .{ .top = true }, // top
        5 => .{ .top = true, .left = true }, // top_left
        7 => .{ .top = true, .right = true }, // top_right
        2 => .{ .bottom = true }, // bottom
        6 => .{ .bottom = true, .left = true }, // bottom_left
        8 => .{ .bottom = true, .right = true }, // bottom_right
        3 => .{ .left = true }, // left
        4 => .{ .right = true }, // right
        else => .{},
    };
}

fn positionerRequest(
    pos_res: *server.xdg.Positioner,
    request: server.xdg.Positioner.Request,
    state: *PositionerState,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do (runs positionerDestroy).
        .destroy => pos_res.destroy(),
        .set_size => |r| {
            if (r.width <= 0 or r.height <= 0) {
                pos_res.postError(.invalid_input, "xdg_positioner.set_size: width and height must be positive");
                return;
            }
            state.size = .{ .w = r.width, .h = r.height };
            state.size_set = true;
        },
        .set_anchor_rect => |r| {
            if (r.width < 0 or r.height < 0) {
                pos_res.postError(
                    .invalid_input,
                    "xdg_positioner.set_anchor_rect: width and height must not be negative",
                );
                return;
            }
            state.anchor_rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
            state.anchor_rect_set = true;
        },
        .set_anchor => |r| {
            // Valid anchors are the 9 enum values 0..8 (none..bottom_right).
            if (@backingInt(r.anchor) > @backingInt(server.xdg.Positioner.Anchor.bottom_right)) {
                pos_res.postError(.invalid_input, "xdg_positioner.set_anchor: value not in the anchor enum");
                return;
            }
            state.anchor = r.anchor;
        },
        .set_gravity => |r| {
            // The XML explicitly requires invalid_input when the gravity is
            // not in the gravity enum (values 0..8).
            if (@backingInt(r.gravity) > @backingInt(server.xdg.Positioner.Gravity.bottom_right)) {
                pos_res.postError(.invalid_input, "xdg_positioner.set_gravity: value not in the gravity enum");
                return;
            }
            state.gravity = r.gravity;
        },
        .set_constraint_adjustment => |r| {
            // Valid bits per the XML bitfield: slide_x=1, slide_y=2,
            // flip_x=4, flip_y=8, resize_x=16, resize_y=32 (mask 0x3F).
            const bits = @as(u32, @bitCast(r.constraint_adjustment));
            if (bits & ~@as(u32, 0b11_1111) != 0) {
                pos_res.postError(.invalid_input, "xdg_positioner.set_constraint_adjustment: invalid adjustment bits");
                return;
            }
            state.constraint_adjustment = r.constraint_adjustment;
        },
        .set_offset => |r| state.offset = .{ .x = r.x, .y = r.y },
        .set_reactive => state.reactive = true,
        .set_parent_size => |r| state.parent_size = .{ .w = r.parent_width, .h = r.parent_height },
        .set_parent_configure => |r| state.parent_configure_serial = r.serial,
    }
}

fn positionerDestroy(pos_res: *server.xdg.Positioner, state: *PositionerState) void {
    _ = pos_res;
    state.shell.allocator.destroy(state);
}

// ---------------------------------------------------------------------------
// The "xdg_surface" wl_surface role implementation.
// ---------------------------------------------------------------------------

/// Recover the XdgSurface from the wl_surface in a role hook, or null
/// when the surface carries no xdg_surface role.
///
/// The ROLE CHECK is load-bearing wherever the surface did not acquire
/// the role through us: `role_resource` is whatever wire resource
/// granted the surface its CURRENT role, so a layer surface's, a lock
/// surface's or a wl_subsurface's resource would be read as an
/// `*XdgSurface` and its user data dereferenced as one. Only the role
/// hooks are guaranteed to run with our own resource, and they are the
/// callers below the accessors.
fn xdgFromSurface(surface: *surface_mod.Surface) ?*XdgSurface {
    if (surface.role != &xdg_surface_role) return null;
    const role_resource = surface.role_resource orelse return null;
    return @ptrCast(@alignCast(role_resource.getUserData() orelse return null));
}

/// The wl_surface an xdg_popup `surface` is parented to — the xdg_surface
/// it was created from, or the layer surface it was attached to with
/// zwlr_layer_shell_v1's get_popup — or null when `surface` carries no
/// xdg_popup role (a plain surface, or an xdg_toplevel, or an xdg_surface
/// whose role object is already gone).
///
/// This is the ROLE-PARENT link a compositor policy needs: whether a
/// surface is composited WITH its parent (a popup of an output-local
/// overlay inherits that overlay's placement, and must never be treated
/// as ordinary world content) cannot be answered from the surface alone.
/// It is CONSTANT TIME — the xdg_surface is the user data of the wire
/// resource the surface's role was assigned with, and the popup hangs off
/// that object — so a compositor can walk a whole chain per surface per
/// frame without a registry scan.
pub fn parentSurfaceOf(surface: *surface_mod.Surface) ?*surface_mod.Surface {
    const xdg = xdgFromSurface(surface) orelse return null;
    const popup = xdg.popup orelse return null;
    if (popup.parent) |p| return p.surface;
    return popup.layer_parent;
}

/// Runs after the pending state has been applied, on every commit. Performs
/// the protocol checks that must happen at commit time.
fn xdgSurfaceClientCommit(surface: *surface_mod.Surface) void {
    const xdg = xdgFromSurface(surface) orelse return;
    // A popup created with a NULL parent must be given one through another
    // protocol before its initial commit (XML get_popup: "before committing
    // the initial state"); a layer-shell parent counts (L1).
    if (xdg.role == .popup) if (xdg.popup) |p| {
        if (p.parent == null and p.layer_parent == null) {
            xdg.resource.postError(.not_constructed, "xdg_popup committed without a parent");
            return;
        }
    };
    // Protocol: attaching a buffer before the surface is configured is an
    // error. This hook runs pre-swap (wlroots moves client_commit before
    // the state swap), so the buffer being committed is `pending`'s.
    if (!xdg.configured and surface.pending.buffer != null) {
        xdg.resource.postError(.unconfigured_buffer, "xdg_surface committed a buffer before ack_configure");
        return;
    }
    // Toplevel min/max size validation at commit (wlroots order: the values
    // are double-buffered, so they are validated when applied).
    if (xdg.role == .toplevel) if (xdg.toplevel) |t| {
        const min = t.pending.min_size;
        const max = t.pending.max_size;
        if (min.w < 0 or min.h < 0 or max.w < 0 or max.h < 0 or
            (max.w != 0 and max.w < min.w) or (max.h != 0 and max.h < min.h))
        {
            t.resource.postError(.invalid_size, "xdg_toplevel: invalid min or max size");
            return;
        }
        // F9: the validated constraints become the compositor-readable
        // current state (wlroots synced move pending -> current).
        t.current.min_size = min;
        t.current.max_size = max;
    };
    // F15: window geometry applies at COMMIT (wlroots synced state), not
    // at ack. The extents clamp (effective geometry =
    // surface extents ∩ window geometry, wlr_xdg_surface.c:259-280) needs
    // the compositor surface-extent API; without it we apply the client's
    // window geometry as-is (the ack-before-commit order makes the timing
    // identical in practice).
    if (xdg.geometry_set) {
        xdg.current_geometry = xdg.pending_geometry;
    }
}

/// Runs after the pending state has been applied, on every commit.
fn xdgSurfaceCommit(surface: *surface_mod.Surface) void {
    const xdg = xdgFromSurface(surface) orelse return;
    switch (xdg.role) {
        .none => {},
        .toplevel => if (xdg.toplevel) |t| {
            // X08: the initial configure is compositor-driven (wlroots:
            // tinywl's commit listener schedules it). The module emits
            // initial_commit on the client's first (buffer-less) commit
            // after the role exists; the compositor replies with
            // scheduleConfigure so the client can map.
            if (!xdg.configure_sent) {
                t.events.initial_commit.emit(t);
            }
        },
        .popup => if (xdg.popup) |p| {
            if (!xdg.configure_sent) {
                p.events.initial_commit.emit(p);
            }
        },
    }
    // NULL-buffer commits unmap via the compositor's own transition
    // (mapped = current.buffer != null), which fires role.unmap and the
    // unmap signal; nothing to do here.
}

/// The compositor's map transition ran (a buffer was committed after an ack).
fn xdgSurfaceMap(surface: *surface_mod.Surface) void {
    const xdg = xdgFromSurface(surface) orelse return;
    // Window geometry was applied at ack_configure; nothing else to do in M1.
    log.info("surface mapped role={s}", xdg.io, xdg.log_cfg, log_tag, .{@tagName(xdg.role)});
}

/// The compositor's unmap transition ran (a NULL-buffer commit): reset the
/// configure state machine so the client must redo the initial buffer-less
/// commit, receive and ack a fresh configure before it may map again
/// (xdg-shell "Unmapping" semantics; the same reset as the destroy paths).
fn xdgSurfaceUnmap(surface: *surface_mod.Surface) void {
    const xdg = xdgFromSurface(surface) orelse return;
    xdg.resetConfigureState();
    // X04b: the popup's OWN grab ends with the surface it grabbed. A
    // NULL-buffer commit unmaps WITHOUT destroying the role object, so
    // none of popupGrabEnd's other paths runs: not popupDestroy (the
    // xdg_popup lives on), not the pointer/keyboard cancel (nobody
    // replaced the grab) and not the press-outside check. Both seat
    // slots would stay installed for the life of the connection — the
    // press the grab delivered is never released, its wl_pointer.enter
    // is never left, and Seat.keyEvent keeps routing every keystroke
    // into popupGrabKey (seat.zig:1698-1707): one client capturing the
    // keyboard from every other client.
    //
    // wlroots ends it here too: reset_xdg_surface takes the popup role
    // down on unmap (wlr_xdg_surface.c:26-45) and wlr_xdg_popup_destroy
    // ends the grab on the way out (wlr_xdg_popup.c:444-464) — exactly
    // the ending popupDestroy performs. Ours keeps the role, because
    // the client may remap the same xdg_popup, so the grab end is made
    // explicit here.
    //
    // `dismiss` is false for the same reason it is false in popupDestroy:
    // the client unmapped its own popup, so nothing was dismissed. The
    // XML reserves popup_done for a compositor dismissal — "sent out
    // when a popup is dismissed by the compositor", after which "the
    // client should destroy the xdg_popup object" (xdg-shell.xml:
    // 1358-1363) — and that object is still valid for a remap.
    //
    // It runs BEFORE the child-popup loop, while this surface is still
    // the one being unmapped: the owed button(released) and
    // wl_pointer.leave are addressed to the popup's own wl_surface,
    // which an unmap does not destroy (only the destroy paths do), so
    // the client is still there to receive them. popupGrabEnd is
    // idempotent (the grab's `active` flag), so an already-ended grab
    // — one a CHILD of this surface holds and popupDestroy is about to
    // clean up, or one another subsystem already replaced — is a no-op.
    if (xdg.role == .popup) if (xdg.popup) |p| if (p.grab_state) |g| popupGrabEnd(g, false);

    // F12: parent unmap dismisses child popups (wlroots reset_xdg_surface
    // destroys the popups in surface->popups, wlr_xdg_surface.c:26-45 —
    // popup_done first, then the resource dies; wlr_xdg_popup_destroy
    // recursion, wlr_xdg_popup.c:485-499). The client sees popup_done and
    // then the object going away, so its popup state cannot survive a
    // parent that unmaps (menus must not outlive their toplevel).
    while (xdg.popups.items.len > 0) {
        const child = xdg.popups.items[0];
        child.sendPopupDone();
        child.resource.destroy();
    }
    // F14/F16: title/app_id are per-map and the parent link dies with the
    // map (wlroots reset_xdg_toplevel on unmap).
    if (xdg.role == .toplevel) if (xdg.toplevel) |t| t.resetOnUnmap();
    log.info("surface unmapped via NULL buffer role={s}", xdg.io, xdg.log_cfg, log_tag, .{@tagName(xdg.role)});
}

/// The wl_surface is going away; tear down the xdg_surface (which cascades
/// through xdgSurfaceDestroy and frees everything).
fn xdgSurfaceRoleDestroy(surface: *surface_mod.Surface) void {
    const xdg = xdgFromSurface(surface) orelse return;
    xdg.resource.destroy();
}

const xdg_surface_role: role_mod.SurfaceRole = .{
    .name = "xdg_surface",
    .client_commit = xdgSurfaceClientCommit,
    .commit = xdgSurfaceCommit,
    .map = xdgSurfaceMap,
    .unmap = xdgSurfaceUnmap,
    .destroy = xdgSurfaceRoleDestroy,
};

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "positioner geometry" {
    var pos: PositionerState = .{ .shell = undefined };
    pos.size = .{ .w = 100, .h = 50 };
    pos.anchor_rect = .{ .x = 10, .y = 20, .width = 200, .height = 100 };

    // Anchor bottom-right, gravity bottom-right: the surface extends down and
    // right from the anchor point (its top-left corner sits at it).
    pos.anchor = .bottom_right;
    pos.gravity = .bottom_right;
    try std.testing.expectEqual(
        geom.Rect{ .x = 210, .y = 120, .width = 100, .height = 50 },
        pos.geometry(),
    );

    // Anchor top-left, gravity top-left: the surface extends up and left from
    // the anchor point (its bottom-right corner sits at it).
    pos.anchor = .top_left;
    pos.gravity = .top_left;
    try std.testing.expectEqual(
        geom.Rect{ .x = -90, .y = -30, .width = 100, .height = 50 },
        pos.geometry(),
    );

    // No anchor/gravity: centered over the anchor rect, offset applied.
    pos.anchor = .none;
    pos.gravity = .none;
    pos.offset = .{ .x = 3, .y = -4 };
    try std.testing.expectEqual(
        geom.Rect{ .x = 63, .y = 41, .width = 100, .height = 50 },
        pos.geometry(),
    );
}

test "positioner edge mapping" {
    try std.testing.expectEqual(EdgeSet{}, positionerEdges(@backingInt(server.xdg.Positioner.Anchor.none)));
    try std.testing.expectEqual(
        EdgeSet{ .top = true },
        positionerEdges(@backingInt(server.xdg.Positioner.Anchor.top)),
    );
    try std.testing.expectEqual(
        EdgeSet{ .top = true, .left = true },
        positionerEdges(@backingInt(server.xdg.Positioner.Anchor.top_left)),
    );
    try std.testing.expectEqual(
        EdgeSet{ .bottom = true, .right = true },
        positionerEdges(@backingInt(server.xdg.Positioner.Gravity.bottom_right)),
    );
}

test "toplevel state values" {
    var buf: [13]u32 = undefined;
    const empty = stateValues(&.{}, &buf, 7);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const st: ToplevelState = .{ .maximized = true, .activated = true };
    const vals = stateValues(&st, &buf, 7);
    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqual(@as(u32, 1), vals[0]); // maximized
    try std.testing.expectEqual(@as(u32, 4), vals[1]); // activated

    // Full state set at v7: 13 entries in XML enum value order (1..13).
    const all: ToplevelState = .{
        .maximized = true,
        .fullscreen = true,
        .resizing = true,
        .activated = true,
        .tiled_left = true,
        .tiled_right = true,
        .tiled_top = true,
        .tiled_bottom = true,
        .suspended = true,
        .constrained_left = true,
        .constrained_right = true,
        .constrained_top = true,
        .constrained_bottom = true,
    };
    const all_vals = stateValues(&all, &buf, 7);
    try std.testing.expectEqual(@as(usize, 13), all_vals.len);
    for (all_vals, 1..) |v, i| try std.testing.expectEqual(@as(u32, @intCast(i)), v);
}

test "toplevel state values filtered by client version (F5)" {
    var buf: [13]u32 = undefined;
    const all: ToplevelState = .{
        .maximized = true,
        .tiled_left = true,
        .suspended = true,
        .constrained_top = true,
        .constrained_bottom = true,
    };

    // v1: only maximized (since 1); tiled (2), suspended (6) and
    // constrained (7) are filtered out.
    const v1 = stateValues(&all, &buf, 1);
    try std.testing.expectEqual(@as(usize, 1), v1.len);
    try std.testing.expectEqual(@as(u32, 1), v1[0]);

    // v2: tiled appears (since 2), suspended/constrained still filtered.
    const v2 = stateValues(&all, &buf, 2);
    try std.testing.expectEqual(@as(usize, 2), v2.len);
    try std.testing.expectEqual(@as(u32, 5), v2[1]); // tiled_left

    // v6: suspended appears (since 6), constrained filtered (since 7).
    const v6 = stateValues(&all, &buf, 6);
    try std.testing.expectEqual(@as(usize, 3), v6.len);
    try std.testing.expectEqual(@as(u32, 9), v6[2]); // suspended

    // v7: everything. constrained enum values (xdg-shell.xml):
    // constrained_left=10, constrained_right=11, constrained_top=12,
    // constrained_bottom=13 — emitted left, right, top, bottom.
    const v7 = stateValues(&all, &buf, 7);
    try std.testing.expectEqual(@as(usize, 5), v7.len);
    try std.testing.expectEqual(@as(u32, 12), v7[3]); // constrained_top
    try std.testing.expectEqual(@as(u32, 13), v7[4]); // constrained_bottom
}

// --- socketpair roundtrip harness (no filesystem server socket) ------------

const posix = std.posix;

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

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    wm_base_name: ?u32 = null,
    shm_name: ?u32 = null,
    seat_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "xdg_wm_base")) {
                    data.wm_base_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_shm")) {
                    data.shm_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

const ToplevelEvents = struct {
    configure_count: usize = 0,
    width: i32 = 0,
    height: i32 = 0,
    states_len: usize = 0,
    states: [13]u32 = @splat(0),
    bounds_count: usize = 0,
    bounds_width: i32 = 0,
    bounds_height: i32 = 0,
    caps_count: usize = 0,
    caps_len: usize = 0,
    caps: [4]u32 = @splat(0),

    fn listener(toplevel: *client.xdg.Toplevel, event: client.xdg.Toplevel.Event, data: *ToplevelEvents) void {
        _ = toplevel;
        switch (event) {
            .configure => |c| {
                data.configure_count += 1;
                data.width = c.width;
                data.height = c.height;
                const s = c.states.slice(u32);
                const n = @min(s.len, data.states.len);
                data.states_len = s.len;
                @memcpy(data.states[0..n], s[0..n]);
            },
            .close => {},
            .configure_bounds => |c| {
                data.bounds_count += 1;
                data.bounds_width = c.width;
                data.bounds_height = c.height;
            },
            .wm_capabilities => |c| {
                data.caps_count += 1;
                const s = c.capabilities.slice(u32);
                const n = @min(s.len, data.caps.len);
                data.caps_len = s.len;
                @memcpy(data.caps[0..n], s[0..n]);
            },
        }
    }
};

const XdgSurfaceEvents = struct {
    configure_count: usize = 0,
    serial: u32 = 0,

    fn listener(xdg_surface: *client.xdg.Surface, event: client.xdg.Surface.Event, data: *XdgSurfaceEvents) void {
        _ = xdg_surface;
        switch (event) {
            .configure => |c| {
                data.configure_count += 1;
                data.serial = c.serial;
            },
        }
    }
};

const PopupEvents = struct {
    configure_count: usize = 0,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    done_count: usize = 0,
    repositioned_count: usize = 0,
    repositioned_token: u32 = 0,

    fn listener(popup: *client.xdg.Popup, event: client.xdg.Popup.Event, data: *PopupEvents) void {
        _ = popup;
        switch (event) {
            .configure => |c| {
                data.configure_count += 1;
                data.x = c.x;
                data.y = c.y;
                data.width = c.width;
                data.height = c.height;
            },
            .popup_done => {
                data.done_count += 1;
            },
            .repositioned => |r| {
                data.repositioned_count += 1;
                data.repositioned_token = r.token;
            },
        }
    }
};

const NewToplevelCapture = struct {
    count: usize = 0,
    listener: wire.Listener(*XdgToplevel),

    fn notify(listener: *wire.Listener(*XdgToplevel), toplevel: *XdgToplevel) void {
        _ = toplevel;
        @as(*NewToplevelCapture, @fieldParentPtr("listener", listener)).count += 1;
    }
};

/// Per-role auto-configure listeners (X08): the compositor's production
/// replica — every new toplevel/popup replies to its initial commit with
/// scheduleConfigure. One heap struct per role; freed by its destroy
/// listener.
pub const AutoConfigureListeners = struct {
    initial_commit: wire.Listener(*XdgToplevel),
    destroy: wire.Listener(*XdgToplevel),
    popup_initial_commit: wire.Listener(*XdgPopup),
    popup_destroy: wire.Listener(*XdgPopup),

    fn onToplevelInitial(listener: *wire.Listener(*XdgToplevel), t: *XdgToplevel) void {
        _ = listener;
        t.scheduleConfigure() catch t.resource.postNoMemory();
    }
    fn onToplevelDestroy(listener: *wire.Listener(*XdgToplevel), t: *XdgToplevel) void {
        const acl: *AutoConfigureListeners = @fieldParentPtr("destroy", listener);
        const allocator = t.allocator;
        acl.initial_commit.link.remove();
        acl.destroy.link.remove();
        allocator.destroy(acl);
    }
    fn onPopupInitial(listener: *wire.Listener(*XdgPopup), p: *XdgPopup) void {
        _ = listener;
        p.scheduleConfigure() catch p.resource.postNoMemory();
    }
    fn onPopupDestroy(listener: *wire.Listener(*XdgPopup), p: *XdgPopup) void {
        const acl: *AutoConfigureListeners = @fieldParentPtr("popup_destroy", listener);
        const allocator = p.allocator;
        acl.popup_initial_commit.link.remove();
        acl.popup_destroy.link.remove();
        allocator.destroy(acl);
    }
};

/// X08 compositor wiring: a watcher that subscribes to a shell's
/// new_toplevel/new_popup and, for each role, installs per-role
/// initial_commit → scheduleConfigure listeners (the module never
/// self-configures). Each per-role listener struct is freed by the role's
/// destroy listener. Test harnesses keep the watcher alive to replicate
/// main.zig's production wiring.
pub const AutoConfigureWatcher = struct {
    new_toplevel: wire.Listener(*XdgToplevel),
    new_popup: wire.Listener(*XdgPopup),

    /// Wire `self` into `shell`'s new_toplevel/new_popup signals. The
    /// watcher must live as long as the shell (its listeners sit in the
    /// shell's signal lists); initialize in place — never by-value return
    /// from a stack copy, or the signal lists dangle.
    pub fn init(self: *AutoConfigureWatcher, shell: *XdgShell) void {
        self.* = .{
            .new_toplevel = wire.Listener(*XdgToplevel).init(onNewToplevel),
            .new_popup = wire.Listener(*XdgPopup).init(onNewPopup),
        };
        shell.events.new_toplevel.add(&self.new_toplevel);
        shell.events.new_popup.add(&self.new_popup);
    }

    fn onNewToplevel(listener: *wire.Listener(*XdgToplevel), t: *XdgToplevel) void {
        _ = listener;
        const acl = t.allocator.create(AutoConfigureListeners) catch return;
        acl.* = .{
            .initial_commit = wire.Listener(*XdgToplevel).init(AutoConfigureListeners.onToplevelInitial),
            .destroy = wire.Listener(*XdgToplevel).init(AutoConfigureListeners.onToplevelDestroy),
            .popup_initial_commit = wire.Listener(*XdgPopup).init(AutoConfigureListeners.onPopupInitial),
            .popup_destroy = wire.Listener(*XdgPopup).init(AutoConfigureListeners.onPopupDestroy),
        };
        t.events.initial_commit.add(&acl.initial_commit);
        t.events.destroy.add(&acl.destroy);
    }

    fn onNewPopup(listener: *wire.Listener(*XdgPopup), p: *XdgPopup) void {
        _ = listener;
        const acl = p.allocator.create(AutoConfigureListeners) catch return;
        acl.* = .{
            .initial_commit = wire.Listener(*XdgToplevel).init(AutoConfigureListeners.onToplevelInitial),
            .destroy = wire.Listener(*XdgToplevel).init(AutoConfigureListeners.onToplevelDestroy),
            .popup_initial_commit = wire.Listener(*XdgPopup).init(AutoConfigureListeners.onPopupInitial),
            .popup_destroy = wire.Listener(*XdgPopup).init(AutoConfigureListeners.onPopupDestroy),
        };
        p.events.initial_commit.add(&acl.popup_initial_commit);
        p.events.destroy.add(&acl.popup_destroy);
    }
};

/// X08 harness wiring: a new toplevel role gets its initial_commit
/// auto-configured (the module never self-configures; the harness
/// mirrors main.zig's production listener).
fn onTestNewToplevel(listener: *wire.Listener(*XdgToplevel), t: *XdgToplevel) void {
    const ts: *TestServer = @fieldParentPtr("new_toplevel_auto", listener);
    const acl = ts.allocator.create(AutoConfigureListeners) catch return;
    acl.* = .{
        .initial_commit = wire.Listener(*XdgToplevel).init(AutoConfigureListeners.onToplevelInitial),
        .destroy = wire.Listener(*XdgToplevel).init(AutoConfigureListeners.onToplevelDestroy),
        .popup_initial_commit = wire.Listener(*XdgPopup).init(AutoConfigureListeners.onPopupInitial),
        .popup_destroy = wire.Listener(*XdgPopup).init(AutoConfigureListeners.onPopupDestroy),
    };
    t.events.initial_commit.add(&acl.initial_commit);
    t.events.destroy.add(&acl.destroy);
}

/// X08 harness wiring: a new popup role gets its initial_commit
/// auto-configured.
fn onTestNewPopup(listener: *wire.Listener(*XdgPopup), p: *XdgPopup) void {
    const ts: *TestServer = @fieldParentPtr("new_popup_auto", listener);
    const acl = ts.allocator.create(AutoConfigureListeners) catch return;
    acl.* = .{
        .initial_commit = wire.Listener(*XdgToplevel).init(AutoConfigureListeners.onToplevelInitial),
        .destroy = wire.Listener(*XdgToplevel).init(AutoConfigureListeners.onToplevelDestroy),
        .popup_initial_commit = wire.Listener(*XdgPopup).init(AutoConfigureListeners.onPopupInitial),
        .popup_destroy = wire.Listener(*XdgPopup).init(AutoConfigureListeners.onPopupDestroy),
    };
    p.events.initial_commit.add(&acl.popup_initial_commit);
    p.events.destroy.add(&acl.popup_destroy);
}

const NewPopupCapture = struct {
    count: usize = 0,
    listener: wire.Listener(*XdgPopup),

    fn notify(listener: *wire.Listener(*XdgPopup), popup: *XdgPopup) void {
        _ = popup;
        @as(*NewPopupCapture, @fieldParentPtr("listener", listener)).count += 1;
    }
};

/// A full compositor + shell + seat + in-memory client, for wire roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    shell: ?*XdgShell = null,
    seat: ?*seat_mod.Seat = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wm_base: ?*client.xdg.WmBase = null,
    shm: ?*client.wl.Shm = null,
    wl_seat: ?*client.wl.Seat = null,
    /// Lazily-created shm pool + buffer for mapping surfaces in tests; the
    /// pool is retained so the buffer stays valid across re-attaches.
    shm_pool: ?*client.wl.ShmPool = null,
    buffer: ?*client.wl.Buffer = null,
    /// X08: the harness replicates main.zig's production wiring — the
    /// compositor drives the initial configure. Each new toplevel/popup
    /// gets an initial_commit listener that calls scheduleConfigure (the
    /// module never self-configures). The per-role listener structs are
    /// freed by the role's own destroy listener (AutoConfigureListeners).
    new_toplevel_auto: wire.Listener(*XdgToplevel),
    new_popup_auto: wire.Listener(*XdgPopup),

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor, shell and seat all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        return initAtVersion(allocator, 7);
    }

    /// init with xdg_wm_base bound at an explicit version, for the
    /// legacy-version conformance tests (a v5 client speaks an older wire).
    fn initAtVersion(allocator: std.mem.Allocator, wm_base_version: u32) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
            .new_toplevel_auto = wire.Listener(*XdgToplevel).init(onTestNewToplevel),
            .new_popup_auto = wire.Listener(*XdgPopup).init(onTestNewPopup),
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        // The internal wl_shm global (libwayland) must exist before the
        // client's first registry roundtrip so it can bind it for buffers.
        try ts.display.?.initShm();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.shell = try XdgShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
        errdefer if (ts.shell) |s| s.deinit();
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();

        // In-memory client connection: one socketpair end for the server, the
        // other for the client library.
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
            capture.wm_base_name == null or
            capture.shm_name == null or
            capture.seat_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor, xdg_wm_base, wl_shm and wl_seat.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wm_base = try registry.bind(capture.wm_base_name.?, client.xdg.WmBase, wm_base_version);
        ts.shm = try registry.bind(capture.shm_name.?, client.wl.Shm, 1);
        ts.wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
        try ts.pump();
        // X08: replicate the production wiring — the compositor drives the
        // initial configure (scheduleConfigure on initial_commit).
        ts.shell.?.events.new_toplevel.add(&ts.new_toplevel_auto);
        ts.shell.?.events.new_popup.add(&ts.new_popup_auto);
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.shell) |s| s.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Create a 64x64 ARGB8888 wl_shm buffer for mapping the test surface.
    /// The pool is retained so the buffer stays valid for later re-attaches.
    fn createBuffer(ts: *TestServer) !*client.wl.Buffer {
        if (ts.buffer) |b| return b;
        const width: i32 = 64;
        const height: i32 = 64;
        const fd = try std.posix.memfd_create("xdg-test-buffer", std.os.linux.MFD.CLOEXEC);
        defer _ = std.os.linux.close(fd);
        const pool_size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
        ts.shm_pool = try ts.shm.?.createPool(fd, @intCast(pool_size));
        ts.buffer = try ts.shm_pool.?.createBuffer(0, width, height, width * 4, .argb8888);
        return ts.buffer.?;
    }

    /// A second independent buffer (fresh pool) for tests that map two
    /// surfaces with distinct content (F12: a popup over its parent).
    fn createBuffer2(ts: *TestServer) !*client.wl.Buffer {
        const width: i32 = 64;
        const height: i32 = 64;
        const fd = try std.posix.memfd_create("xdg-test-buffer-2", std.os.linux.MFD.CLOEXEC);
        defer _ = std.os.linux.close(fd);
        const pool_size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        const rc = std.os.linux.ftruncate(fd, @intCast(pool_size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
        const pool = try ts.shm.?.createPool(fd, @intCast(pool_size));
        return pool.createBuffer(0, width, height, width * 4, .argb8888);
    }

    /// The shared `test_pump.roundtrip` (client flush -> server dispatch ->
    /// server flush) plus a client dispatch, which runs only when the server
    /// actually wrote to the socket. Never blocks.
    fn pump(ts: *TestServer) !void {
        try test_pump.roundtrip(ts.c_display.?, ts.display.?, 0);
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
};

test "xdg toplevel configure/ack roundtrip" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var new_toplevel: NewToplevelCapture = .{
        .listener = wire.Listener(*XdgToplevel).init(NewToplevelCapture.notify),
    };
    ts.shell.?.events.new_toplevel.add(&new_toplevel.listener);

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();

    var tl_events: ToplevelEvents = .{};
    toplevel.setListener(*ToplevelEvents, ToplevelEvents.listener, &tl_events);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);

    toplevel.setTitle("hello");
    try ts.pump();

    // get_toplevel handled: role object created and announced.
    try std.testing.expectEqual(@as(usize, 1), ts.shell.?.toplevels.items.len);
    try std.testing.expectEqual(@as(usize, 1), new_toplevel.count);
    const t = ts.shell.?.toplevels.items[0];
    try std.testing.expectEqualStrings("hello", t.title.?);
    try std.testing.expect(t.xdg_surface.role == .toplevel);
    try std.testing.expect(!t.xdg_surface.configured);

    // Initial buffer-less commit: the compositor replies with the first
    // configure (0x0 = client decides, no states). F4: the first configure
    // carries wm_capabilities (seeded at role creation for v5+ clients).
    wl_surface.commit();
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), tl_events.configure_count);
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
    try std.testing.expectEqual(@as(usize, 0), tl_events.states_len);
    try std.testing.expectEqual(@as(usize, 1), tl_events.caps_count);
    try std.testing.expectEqual(@as(usize, 4), tl_events.caps_len);
    try std.testing.expectEqual(@as(u32, 1), tl_events.caps[0]); // window_menu
    try std.testing.expectEqual(@as(u32, 2), tl_events.caps[1]); // maximize
    try std.testing.expectEqual(@as(u32, 3), tl_events.caps[2]); // fullscreen
    try std.testing.expectEqual(@as(u32, 4), tl_events.caps[3]); // minimize
    const xdg = t.xdg_surface;
    const serial1 = xs_events.serial;
    try std.testing.expectEqual(serial1, xdg.configure_serial);
    try std.testing.expect(!xdg.configured);

    // Ack the configure and commit (NULL buffer): the surface is configured.
    xdg_surface.ackConfigure(serial1);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();

    try std.testing.expect(xdg.configured);
    try std.testing.expectEqual(serial1, xdg.acked_serial.?);

    // Compositor side: schedule a new size with the maximized state (F6:
    // policy writes the scheduled state) and announce new bounds (F4; the
    // X07 setter arms the per-configure payload bit).
    t.scheduled.maximized = true;
    t.setConfigureBounds(1000, 700);
    try t.configure(800, 600);
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 2), tl_events.configure_count);
    try std.testing.expectEqual(@as(i32, 800), tl_events.width);
    try std.testing.expectEqual(@as(i32, 600), tl_events.height);
    try std.testing.expectEqual(@as(usize, 1), tl_events.states_len);
    try std.testing.expectEqual(@as(u32, 1), tl_events.states[0]); // maximized
    try std.testing.expectEqual(geom.Size{ .w = 800, .h = 600 }, t.configured_size);
    // configure_bounds arrives before this configure (and is not re-sent
    // unless re-armed: the bit clears after the send).
    try std.testing.expectEqual(@as(usize, 1), tl_events.bounds_count);
    try std.testing.expectEqual(@as(i32, 1000), tl_events.bounds_width);
    try std.testing.expectEqual(@as(i32, 700), tl_events.bounds_height);
    // wm_capabilities is not re-sent when the bit is not re-armed.
    try std.testing.expectEqual(@as(usize, 1), tl_events.caps_count);
    const serial2 = xs_events.serial;
    try std.testing.expect(serial2 != serial1);

    // Ack the second configure (not the first: a stale ack is an error).
    xdg_surface.ackConfigure(serial2);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(serial2, xdg.acked_serial.?);
    // F7: the acked payload defines what the client committed against.
    try std.testing.expect(t.current.maximized);
    try std.testing.expectEqual(@as(i32, 800), t.current.width);
    try std.testing.expectEqual(@as(i32, 600), t.current.height);

    // Acking an unknown serial is a protocol error (invalid_serial = 4); the
    // server destroys the client, so pump fails with ClientDispatchFailed.
    xdg_surface.ackConfigure(12345);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    // The client library records the protocol error code (invalid_serial = 4).
    try std.testing.expectEqual(@as(c_int, 4), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

/// initial_commit capture for the X08 contract test.
const CommitCapture = struct {
    count: usize = 0,
    listener: wire.Listener(*XdgToplevel),
    fn on(l: *wire.Listener(*XdgToplevel), t: *XdgToplevel) void {
        _ = t;
        @as(*CommitCapture, @fieldParentPtr("listener", l)).count += 1;
    }
};

test "initial_commit drives exactly one compositor-scheduled configure (X08)" {
    // X08: the module never self-configures — the first (buffer-less)
    // commit emits initial_commit, and the compositor's listener
    // (the TestServer's production replica) replies with scheduleConfigure.
    // A role without a listener gets NO configure at all: the signal IS
    // the contract.
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    var tl_events: ToplevelEvents = .{};
    toplevel.setListener(*ToplevelEvents, ToplevelEvents.listener, &tl_events);
    try ts.pump();
    var capture: CommitCapture = .{ .listener = wire.Listener(*XdgToplevel).init(CommitCapture.on) };
    const t = ts.shell.?.toplevels.items[0];
    t.events.initial_commit.add(&capture.listener);

    // First buffer-less commit: initial_commit fires; the harness's
    // scheduleConfigure listener sends exactly one configure.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
    try std.testing.expectEqual(@as(usize, 1), tl_events.configure_count);

    // A second commit does NOT re-fire initial_commit (configure_sent
    // gates it): the compositor schedules, the module never re-emits.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
}

test "xdg popup configure and positioner errors" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var new_popup: NewPopupCapture = .{
        .listener = wire.Listener(*XdgPopup).init(NewPopupCapture.notify),
    };
    ts.shell.?.events.new_popup.add(&new_popup.listener);

    // The popup needs a parent with an xdg_surface role: a toplevel.
    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    var popup_events: PopupEvents = .{};

    // Complete positioner: a 100x50 popup anchored at the bottom-right corner
    // of a 200x100 anchor rect at (10, 20), gravity bottom-right.
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    positioner.setOffset(0, 0);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy(); // rules were copied at get_popup
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), ts.shell.?.popups.items.len);
    try std.testing.expectEqual(@as(usize, 1), new_popup.count);
    const p = ts.shell.?.popups.items[0];
    try std.testing.expect(p.xdg_surface.role == .popup);
    try std.testing.expectEqual(
        geom.Rect{ .x = 210, .y = 120, .width = 100, .height = 50 },
        p.geometry,
    );

    // Initial commit: popup configure + xdg_surface configure.
    wl_surface.commit();
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), popup_events.configure_count);
    try std.testing.expectEqual(@as(i32, 210), popup_events.x);
    try std.testing.expectEqual(@as(i32, 120), popup_events.y);
    try std.testing.expectEqual(@as(i32, 100), popup_events.width);
    try std.testing.expectEqual(@as(i32, 50), popup_events.height);
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
    const serial = xs_events.serial;
    try std.testing.expectEqual(serial, p.xdg_surface.configure_serial);

    // Ack + commit: the popup is configured.
    xdg_surface.ackConfigure(serial);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(p.xdg_surface.configured);

    // Destroy the popup: role object torn down, surface unmapped.
    const server_xdg_surface = p.xdg_surface;
    popup.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.shell.?.popups.items.len);
    try std.testing.expect(server_xdg_surface.role == .none);

    // An incomplete positioner (size never set) is rejected with the wm_base
    // invalid_positioner error (code 5) posted on the xdg_wm_base resource —
    // posting it on the xdg_surface would read as xdg_surface.invalid_size.
    const wl_surface2 = try ts.wl_compositor.?.createSurface();
    const xdg_surface2 = try ts.wm_base.?.getXdgSurface(wl_surface2);
    const bad_positioner = try ts.wm_base.?.createPositioner();
    bad_positioner.setAnchorRect(0, 0, 10, 10);
    _ = try xdg_surface2.getPopup(null, bad_positioner);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 5), err.code); // invalid_positioner
    try std.testing.expectEqualStrings("xdg_wm_base", err.interface);
}

/// Shared setup for the toplevel adversarial tests: surface + xdg_surface +
/// toplevel, first configure sent and acked (configured == true).
fn setupConfiguredToplevel(ts: *TestServer, xs_events: *XdgSurfaceEvents) !*client.xdg.Toplevel {
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, xs_events);
    const toplevel = try xdg_surface.getToplevel();
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(xdgSurfaceConfigured(ts));
    return toplevel;
}

/// True when the server-side XdgSurface for the test client's toplevel is
/// configured (helper: the shell keeps exactly the toplevels we create).
fn xdgSurfaceConfigured(ts: *TestServer) bool {
    return ts.shell.?.toplevels.items[0].xdg_surface.configured;
}

test "unmap via null buffer resets the configure state machine" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    _ = try xdg_surface.getToplevel();
    const buffer = try ts.createBuffer();

    // Map: initial commit -> configure, ack, attach buffer, commit.
    wl_surface.commit();
    try ts.pump();
    const serial1 = xs_events.serial;
    xdg_surface.ackConfigure(serial1);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    const srv = ts.shell.?.toplevels.items[0].xdg_surface;
    try std.testing.expect(srv.surface.mapped);
    try std.testing.expect(srv.configured);

    // Two further configures (neither acked): the sent payloads survive
    // until the unmap resets them (X06).
    const t = ts.shell.?.toplevels.items[0];
    try t.configure(0, 0);
    try t.configure(0, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), t.sent_payloads.items.len);
    try std.testing.expectEqual(@as(usize, 2), srv.sent_serials.items.len);

    // Unmap via NULL buffer: the configure state machine resets.
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(!srv.surface.mapped);
    try std.testing.expect(!srv.configured);
    try std.testing.expect(!srv.configure_sent);
    try std.testing.expect(srv.acked_serial == null);
    // X06: the sent payload lists are cleared with the reset.
    try std.testing.expectEqual(@as(usize, 0), t.sent_payloads.items.len);
    try std.testing.expectEqual(@as(usize, 0), srv.sent_serials.items.len);

    // Re-map requires a fresh configure: a buffer-less commit first...
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 4), xs_events.configure_count);
    const serial2 = xs_events.serial;
    try std.testing.expect(serial2 != serial1);
    xdg_surface.ackConfigure(serial2);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(srv.surface.mapped);
    try std.testing.expect(srv.configured);

    // ...and committing a buffer without the fresh configure is an error:
    // unmap again, then attach a buffer and commit before any configure.
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(!srv.surface.mapped);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 3), err.code); // unconfigured_buffer
    try std.testing.expectEqualStrings("xdg_surface", err.interface);
}

test "wm_base.destroy with live surfaces posts defunct_surfaces" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getToplevel();
    try ts.pump();

    ts.wm_base.?.destroy();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 1), err.code); // defunct_surfaces
    // The interface name is NOT asserted: the client destroyed its wm_base
    // proxy before the error arrived, so libwayland-client cannot map the
    // object to the xdg_wm_base interface anymore.
}

test "get_xdg_surface on a surface with a role posts wm_base role error" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getToplevel();
    try ts.pump();

    // The wl_surface already carries the xdg_surface role: a second
    // get_xdg_surface is a role error on the wm_base, not a wl_surface
    // error (role.zig's assignRole would post the wrong resource).
    _ = try ts.wm_base.?.getXdgSurface(wl_surface);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 0), err.code); // role
    try std.testing.expectEqualStrings("xdg_wm_base", err.interface);
}

test "ack_configure before a role is assigned posts not_constructed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    try ts.pump();

    xdg_surface.ackConfigure(1);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 1), err.code); // not_constructed
    try std.testing.expectEqualStrings("xdg_surface", err.interface);
}

test "set_window_geometry before a role is assigned posts not_constructed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    try ts.pump();

    xdg_surface.setWindowGeometry(0, 0, 100, 100);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 1), err.code); // not_constructed
    try std.testing.expectEqualStrings("xdg_surface", err.interface);
}

test "toplevel move before configured posts not_constructed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();
    try ts.pump();

    // Role assigned but never configured: interactive requests are errors.
    toplevel.move(ts.wl_seat.?, 1);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 1), err.code); // not_constructed
    try std.testing.expectEqualStrings("xdg_surface", err.interface);
}

const ResizeCapture = struct {
    count: usize = 0,
    edges: server.xdg.Toplevel.ResizeEdge = .none,
    seat: ?*seat_mod.Seat = null,
    serial: u32 = 0,
    listener: wire.Listener(*ResizeRequest),

    fn notify(listener: *wire.Listener(*ResizeRequest), req: *ResizeRequest) void {
        const self: *ResizeCapture = @fieldParentPtr("listener", listener);
        self.count += 1;
        self.edges = req.edges;
        self.seat = req.seat;
        self.serial = req.serial;
    }
};

test "resize with an invalid edge posts invalid_resize_edge" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var xs_events: XdgSurfaceEvents = .{};
    const toplevel = try setupConfiguredToplevel(ts, &xs_events);

    // 3 is not a resize_edge variant (none=0, top=1, bottom=2, left=4, ...).
    toplevel.resize(ts.wl_seat.?, 2, @fromBackingInt(@intCast(3)));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 0), err.code); // invalid_resize_edge
    try std.testing.expectEqualStrings("xdg_toplevel", err.interface);
}

test "resize carries the validated edges in the signal payload" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var xs_events: XdgSurfaceEvents = .{};
    const toplevel = try setupConfiguredToplevel(ts, &xs_events);

    var capture: ResizeCapture = .{ .listener = wire.Listener(*ResizeRequest).init(ResizeCapture.notify) };
    ts.shell.?.toplevels.items[0].events.request_resize.add(&capture.listener);

    toplevel.resize(ts.wl_seat.?, 2, .top_left);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(server.xdg.Toplevel.ResizeEdge.top_left, capture.edges);
    // F11: the payload carries the seat + serial the client echoed.
    try std.testing.expect(capture.seat == ts.seat);
    try std.testing.expectEqual(@as(u32, 2), capture.serial);
}

test "positioner rejects invalid anchor, gravity and constraint adjustments" {
    const allocator = std.testing.allocator;

    // Anchor out of range (valid values 0..8).
    {
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const positioner = try ts.wm_base.?.createPositioner();
        positioner.setAnchor(@fromBackingInt(@intCast(99)));
        try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
        const err = protocolError(ts);
        try std.testing.expectEqual(@as(c_int, 0), err.code); // invalid_input
        try std.testing.expectEqualStrings("xdg_positioner", err.interface);
    }

    // Gravity out of range.
    {
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const positioner = try ts.wm_base.?.createPositioner();
        positioner.setGravity(@fromBackingInt(@intCast(99)));
        try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
        const err = protocolError(ts);
        try std.testing.expectEqual(@as(c_int, 0), err.code); // invalid_input
        try std.testing.expectEqualStrings("xdg_positioner", err.interface);
    }

    // Constraint adjustment bits outside slide/flip/resize (mask 0x3F).
    {
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const positioner = try ts.wm_base.?.createPositioner();
        positioner.setConstraintAdjustment(@bitCast(@as(u32, 64)));
        try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
        const err = protocolError(ts);
        try std.testing.expectEqual(@as(c_int, 0), err.code); // invalid_input
        try std.testing.expectEqualStrings("xdg_positioner", err.interface);
    }
}

test "get_popup with a parent without a role posts invalid_popup_parent" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface); // no role object
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    try ts.pump();

    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(0, 0, 10, 10);
    _ = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 3), err.code); // invalid_popup_parent
    try std.testing.expectEqualStrings("xdg_wm_base", err.interface);
}

test "popup with a null parent posts not_constructed at commit" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    try ts.pump();

    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(0, 0, 10, 10);
    _ = try xdg_surface.getPopup(null, positioner);

    // Committing the initial state without a parent is an error.
    wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 1), err.code); // not_constructed
    try std.testing.expectEqualStrings("xdg_surface", err.interface);
}

test "set_parent to itself posts invalid_parent" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();
    try ts.pump();

    toplevel.setParent(toplevel);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 1), err.code); // invalid_parent
    try std.testing.expectEqualStrings("xdg_toplevel", err.interface);
}

test "get_xdg_surface on a surface with a committed buffer posts unconfigured_buffer" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const buffer = try ts.createBuffer();
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();

    _ = try ts.wm_base.?.getXdgSurface(wl_surface);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 3), err.code); // unconfigured_buffer
    try std.testing.expectEqualStrings("xdg_surface", err.interface);
}

test "second role object on one xdg_surface posts already_constructed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getToplevel();
    try ts.pump();

    // A second role object: already_constructed on the xdg_surface (kept
    // over wlroots' cross-interface role post; see notes/129).
    _ = try xdg_surface.getToplevel();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 2), err.code); // already_constructed
    try std.testing.expectEqualStrings("xdg_surface", err.interface);
}

test "invalid utf-8 title is rejected without storing" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();
    try ts.pump();

    // 0xFF is not valid UTF-8; the title must be rejected, not stored.
    toplevel.setTitle("\xff\xfe");
    try ts.pump();
    const t = ts.shell.?.toplevels.items[0];
    try std.testing.expect(t.title == null);
    // The connection survives: a well-formed title still works.
    toplevel.setTitle("ok");
    try ts.pump();
    try std.testing.expectEqualStrings("ok", t.title.?);
}

test "xdg_wm_base v5 client: legacy toplevel roundtrip with since<=5 states only" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.initAtVersion(allocator, 5);
    defer ts.deinit();

    // The client bound xdg_wm_base at v5 (the version old toolkits speak).
    try std.testing.expectEqual(@as(u32, 5), ts.wm_base.?.getVersion());

    var new_toplevel: NewToplevelCapture = .{
        .listener = wire.Listener(*XdgToplevel).init(NewToplevelCapture.notify),
    };
    ts.shell.?.events.new_toplevel.add(&new_toplevel.listener);

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();

    var tl_events: ToplevelEvents = .{};
    toplevel.setListener(*ToplevelEvents, ToplevelEvents.listener, &tl_events);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    try ts.pump();

    // set_maximized is since 1: a v5 client may send it.
    toplevel.setMaximized();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.shell.?.toplevels.items.len);
    const t = ts.shell.?.toplevels.items[0];
    try std.testing.expect(t.pending.maximized);

    // Initial buffer-less commit: the compositor replies with the first
    // configure (0x0 = client decides, no states).
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), tl_events.configure_count);
    try std.testing.expectEqual(@as(usize, 0), tl_events.states_len);
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
    const serial1 = xs_events.serial;
    try std.testing.expectEqual(serial1, t.xdg_surface.configure_serial);
    try std.testing.expect(!t.xdg_surface.configured);

    // Ack the configure and commit a real buffer: the surface maps.
    xdg_surface.ackConfigure(serial1);
    const buffer = try ts.createBuffer();
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(t.xdg_surface.configured);
    try std.testing.expect(t.xdg_surface.surface.mapped);

    // Compositor-side configure carrying states valid at v5: maximized (1,
    // since 1) and tiled_left (5, since 2). States newer than v5
    // (suspended=9 since 6, constrained_*=10..13 since 7) must not appear
    // in a configure sent to this client (F5).
    t.scheduled.maximized = true;
    t.scheduled.tiled_left = true;
    t.scheduled.suspended = true;
    t.scheduled.constrained_top = true;
    try t.configure(800, 600);
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 2), tl_events.configure_count);
    try std.testing.expectEqual(@as(i32, 800), tl_events.width);
    try std.testing.expectEqual(@as(i32, 600), tl_events.height);
    try std.testing.expectEqual(@as(usize, 2), tl_events.states_len);
    try std.testing.expectEqual(@as(u32, 1), tl_events.states[0]); // maximized
    try std.testing.expectEqual(@as(u32, 5), tl_events.states[1]); // tiled_left
    // Every received state must be since <= 5 (xdg-shell.xml state enum:
    // maximized/fullscreen/resizing/activated = 1, tiled_* = 2,
    // suspended = 6, constrained_* = 7).
    for (tl_events.states[0..tl_events.states_len]) |state| {
        const since: u32 = switch (state) {
            1, 2, 3, 4 => 1,
            5, 6, 7, 8 => 2,
            9 => 6,
            10, 11, 12, 13 => 7,
            else => unreachable,
        };
        try std.testing.expect(since <= 5);
    }
    const serial2 = xs_events.serial;
    try std.testing.expect(serial2 != serial1);
    try std.testing.expectEqual(geom.Size{ .w = 800, .h = 600 }, t.configured_size);

    // The v5 client acks and stays mapped (re-attach: a commit with no
    // pending buffer is a NULL-buffer commit and would unmap).
    xdg_surface.ackConfigure(serial2);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(serial2, t.xdg_surface.acked_serial.?);
    try std.testing.expect(t.xdg_surface.surface.mapped);
}

// ---------------------------------------------------------------------------
// F1-F16 regression tests (2026-08-10 fixing round).
// ---------------------------------------------------------------------------

test "positioner constraint adjustment math (F1)" {
    var pos: PositionerState = .{ .shell = undefined };
    const constraint: geom.Rect = .{ .x = 0, .y = 0, .width = 200, .height = 200 };

    // Slide: a popup placed left of the anchor rect is inside the parent
    // rect; the raw geometry hangs off the left edge (-100). slide_x moves
    // it the minimal distance (100) into the constraint.
    pos.size = .{ .w = 100, .h = 50 };
    pos.anchor_rect = .{ .x = 0, .y = 100, .width = 100, .height = 100 };
    pos.anchor = .top_left;
    pos.gravity = .top_left;
    pos.constraint_adjustment = @bitCast(@as(u32, 1)); // slide_x
    try std.testing.expectEqual(
        geom.Rect{ .x = -100, .y = 50, .width = 100, .height = 50 },
        pos.geometry(),
    );
    try std.testing.expectEqual(
        geom.Rect{ .x = 0, .y = 50, .width = 100, .height = 50 },
        pos.constrainedGeometry(constraint),
    );

    // Flip: a popup with anchor/gravity top placed at the top edge extends
    // above it (y = -50). flip_y inverts both to bottom, placing it below
    // the anchor point (y = 100) — inside the constraint.
    pos = .{ .shell = undefined };
    pos.size = .{ .w = 100, .h = 50 };
    pos.anchor_rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
    pos.anchor = .top;
    pos.gravity = .top;
    pos.constraint_adjustment = @bitCast(@as(u32, 8)); // flip_y
    try std.testing.expectEqual(
        geom.Rect{ .x = 50, .y = -50, .width = 100, .height = 50 },
        pos.geometry(),
    );
    try std.testing.expectEqual(
        geom.Rect{ .x = 50, .y = 100, .width = 100, .height = 50 },
        pos.constrainedGeometry(constraint),
    );

    // Resize: a popup larger than the constraint on both axes is clipped
    // (resize_x|resize_y), shifting and shrinking to fit.
    pos = .{ .shell = undefined };
    pos.size = .{ .w = 250, .h = 250 };
    pos.anchor_rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    pos.anchor = .bottom_right;
    pos.gravity = .bottom_right;
    pos.constraint_adjustment = @bitCast(@as(u32, 16 | 32)); // resize_x | resize_y
    try std.testing.expectEqual(
        geom.Rect{ .x = 100, .y = 100, .width = 250, .height = 250 },
        pos.geometry(),
    );
    // The box spans 100..350; the constraint is 0..200, so the clip keeps
    // the visible 100..200 slice: x stays 100, width shrinks to 100
    // (wlroots: x += clamped left offset, width -= left + right offsets).
    try std.testing.expectEqual(
        geom.Rect{ .x = 100, .y = 100, .width = 100, .height = 100 },
        pos.constrainedGeometry(constraint),
    );

    // No adjustment bits: the raw (off-screen) geometry is unchanged.
    pos.constraint_adjustment = .{};
    try std.testing.expectEqual(
        geom.Rect{ .x = 100, .y = 100, .width = 250, .height = 250 },
        pos.constrainedGeometry(constraint),
    );
}

test "popup configure applies the constraint box (F1)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    var popup_events: PopupEvents = .{};

    // slide_x popup that would hang off the left edge of the constraint.
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(0, 100, 100, 100);
    positioner.setAnchor(.top_left);
    positioner.setGravity(.top_left);
    positioner.setConstraintAdjustment(@bitCast(@as(u32, 1))); // slide_x
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy();
    try ts.pump();

    // Raw geometry before the constraint is applied.
    const p = ts.shell.?.popups.items[0];
    try std.testing.expectEqual(
        geom.Rect{ .x = -100, .y = 50, .width = 100, .height = 50 },
        p.geometry,
    );

    // The compositor supplies the usable area; the configure then carries
    // the constraint-adjusted placement.
    p.setConstraintBox(.{ .x = 0, .y = 0, .width = 200, .height = 200 });
    wl_surface.commit();
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), popup_events.configure_count);
    try std.testing.expectEqual(@as(i32, 0), popup_events.x);
    try std.testing.expectEqual(@as(i32, 50), popup_events.y);
    try std.testing.expectEqual(@as(i32, 100), popup_events.width);
    try std.testing.expectEqual(@as(i32, 50), popup_events.height);
    try std.testing.expectEqual(
        geom.Rect{ .x = 0, .y = 50, .width = 100, .height = 50 },
        p.geometry,
    );
    const serial = xs_events.serial;
    xdg_surface.ackConfigure(serial);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(p.xdg_surface.configured);
    // F7: the acked popup payload records the geometry it was configured at.
    try std.testing.expectEqual(
        geom.Rect{ .x = 0, .y = 50, .width = 100, .height = 50 },
        p.acked_geometry.?,
    );
}

test "parent unmap dismisses child popups with popup_done (F12)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Map a toplevel.
    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    var parent_events: XdgSurfaceEvents = .{};
    parent_xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &parent_events);
    const buffer = try ts.createBuffer();
    // Map: initial commit -> configure, ack, attach buffer, commit.
    try ts.pump();
    parent_wl_surface.commit();
    try ts.pump();
    parent_xdg_surface.ackConfigure(parent_events.serial);
    parent_wl_surface.attach(buffer, 0, 0);
    parent_wl_surface.commit();
    try ts.pump();
    try std.testing.expect(ts.shell.?.toplevels.items[0].xdg_surface.surface.mapped);

    // Create + map a popup on the toplevel.
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    var popup_events: PopupEvents = .{};
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy();
    const popup_buffer = try ts.createBuffer2();
    try ts.pump();
    wl_surface.commit();
    try ts.pump();
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(popup_buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    const p = ts.shell.?.popups.items[0];
    try std.testing.expect(p.xdg_surface.surface.mapped);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);

    // Parent unmaps via NULL buffer: the child popup gets popup_done and
    // is destroyed (wlroots reset_xdg_surface, wlr_xdg_surface.c:26-45;
    // the client then destroys the object, so the role detaches too).
    parent_wl_surface.attach(null, 0, 0);
    parent_wl_surface.commit();
    try ts.pump();
    try std.testing.expect(!ts.shell.?.toplevels.items[0].xdg_surface.surface.mapped);
    try std.testing.expectEqual(@as(usize, 1), popup_events.done_count);
    try std.testing.expectEqual(@as(usize, 0), ts.shell.?.popups.items.len);
    // Surface/role teardown runs in ts.deinit (the client destroys the
    // wl_surface + xdg_surface; the server frees the rest).
}

const WmBasePingEvents = struct {
    ping_count: usize = 0,
    serial: u32 = 0,

    fn listener(wm_base: *client.xdg.WmBase, event: client.xdg.WmBase.Event, data: *WmBasePingEvents) void {
        _ = wm_base;
        switch (event) {
            .ping => |p| {
                data.ping_count += 1;
                data.serial = p.serial;
            },
        }
    }
};

const PongCapture = struct {
    count: usize = 0,
    listener: wire.Listener(*XdgShell),

    fn notify(listener: *wire.Listener(*XdgShell), _: *XdgShell) void {
        @as(*PongCapture, @fieldParentPtr("listener", listener)).count += 1;
    }
};

test "ping/pong roundtrip and unresponsive tracking (F3)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var ping_events: WmBasePingEvents = .{};
    ts.wm_base.?.setListener(*WmBasePingEvents, WmBasePingEvents.listener, &ping_events);
    var pong_cap: PongCapture = .{ .listener = wire.Listener(*XdgShell).init(PongCapture.notify) };
    ts.shell.?.events.pong.add(&pong_cap.listener);

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getToplevel();
    try ts.pump();
    const t = ts.shell.?.toplevels.items[0];

    // Compositor pings: the client receives xdg_wm_base.ping.
    t.ping();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ping_events.ping_count);
    try std.testing.expectEqual(ping_events.serial, t.xdg_surface.wm_base.ping_serial.?);
    try std.testing.expect(t.pingPending());

    // A second ping while one is outstanding is a no-op (wlroots: one
    // pending ping per client).
    t.ping();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ping_events.ping_count);

    // A pong with the wrong serial does not clear the pending ping.
    ts.wm_base.?.pong(ping_events.serial + 1);
    try ts.pump();
    try std.testing.expect(t.pingPending());
    try std.testing.expectEqual(@as(usize, 0), pong_cap.count);

    // The matching pong clears it and emits the shell pong signal.
    ts.wm_base.?.pong(ping_events.serial);
    try ts.pump();
    try std.testing.expect(!t.pingPending());
    try std.testing.expectEqual(@as(usize, 1), pong_cap.count);

    // Ping again: fresh serial, pending again (the compositor's timer then
    // decides the timeout and posts the unresponsive error, error code 6 —
    // exercised in main.zig policy, not here).
    t.ping();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ping_events.ping_count);
    try std.testing.expect(t.pingPending());
}

test "wm_capabilities and configure_bounds version gating (F4)" {
    const allocator = std.testing.allocator;
    // A v4 client: configure_bounds exists (since 4) but wm_capabilities
    // (since 5) must never be sent.
    var ts = try TestServer.initAtVersion(allocator, 4);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();
    var tl_events: ToplevelEvents = .{};
    toplevel.setListener(*ToplevelEvents, ToplevelEvents.listener, &tl_events);
    try ts.pump();

    wl_surface.commit();
    try ts.pump();
    // First configure: no wm_capabilities at v4.
    try std.testing.expectEqual(@as(usize, 1), tl_events.configure_count);
    try std.testing.expectEqual(@as(usize, 0), tl_events.caps_count);
    // configure_bounds still works at v4 (the X07 setter arms the bit).
    const t = ts.shell.?.toplevels.items[0];
    t.setConfigureBounds(640, 480);
    try t.configure(0, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), tl_events.bounds_count);
    try std.testing.expectEqual(@as(i32, 640), tl_events.bounds_width);
    try std.testing.expectEqual(@as(i32, 480), tl_events.bounds_height);
}

test "empty wm_capabilities and 0,0 bounds are legal sendable payloads (X07)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const toplevel = try xdg_surface.getToplevel();
    var tl_events: ToplevelEvents = .{};
    toplevel.setListener(*ToplevelEvents, ToplevelEvents.listener, &tl_events);
    try ts.pump();

    // First configure carries the seeded default capabilities (F4).
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), tl_events.configure_count);
    try std.testing.expectEqual(@as(usize, 1), tl_events.caps_count);
    try std.testing.expectEqual(@as(usize, 4), tl_events.caps_len);

    // Re-arm: an empty capability set is announced as a zero-length array,
    // and an explicit 0,0 bounds pair is sent as-is (X07 flag semantics:
    // the payload is compositor-requested, not value-derived).
    const t = ts.shell.?.toplevels.items[0];
    t.setWmCapabilities(.{});
    t.setConfigureBounds(0, 0);
    try t.configure(0, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), tl_events.configure_count);
    try std.testing.expectEqual(@as(usize, 2), tl_events.caps_count);
    try std.testing.expectEqual(@as(usize, 0), tl_events.caps_len);
    try std.testing.expectEqual(@as(usize, 1), tl_events.bounds_count);
    try std.testing.expectEqual(@as(i32, 0), tl_events.bounds_width);
    try std.testing.expectEqual(@as(i32, 0), tl_events.bounds_height);

    // Re-arm semantics: the bits clear after the send, so a configure
    // without a fresh setter call emits neither payload again.
    try t.configure(0, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 3), tl_events.configure_count);
    try std.testing.expectEqual(@as(usize, 2), tl_events.caps_count);
    try std.testing.expectEqual(@as(usize, 1), tl_events.bounds_count);
}

test "role-object destroy before map resets the configure machine (F8)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    var tl_events: ToplevelEvents = .{};
    const toplevel = try xdg_surface.getToplevel();
    toplevel.setListener(*ToplevelEvents, ToplevelEvents.listener, &tl_events);
    try ts.pump();

    // First role: commit (configure sent), ack it — the surface is
    // configured but never maps (no buffer ever attached).
    wl_surface.commit();
    try ts.pump();
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    const srv = ts.shell.?.toplevels.items[0].xdg_surface;
    try std.testing.expect(srv.configured);

    // A fresh configure that is never acked: its payload must not survive
    // the role destroy (X06).
    const t = ts.shell.?.toplevels.items[0];
    try t.configure(0, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), t.sent_payloads.items.len);
    try std.testing.expectEqual(@as(usize, 1), srv.sent_serials.items.len);

    // Destroy the role object while the surface is unmapped: the configure
    // state machine must reset (F8) — the old acked state must not survive
    // into the next role.
    toplevel.destroy();
    try ts.pump();
    try std.testing.expect(ts.shell.?.toplevels.items.len == 0);
    try std.testing.expect(!srv.configured);
    try std.testing.expect(srv.acked_serial == null);

    // A fresh role on the same wl_surface: attaching a buffer before the
    // new configure handshake is an error (would have mapped silently
    // without the F8 reset).
    _ = try xdg_surface.getToplevel();
    try ts.pump();
    // X06: the fresh role starts with no stale configure payloads (the
    // destroyed role's payload list was emptied before its deinit).
    try std.testing.expectEqual(@as(usize, 0), ts.shell.?.toplevels.items[0].sent_payloads.items.len);
    const buffer = try ts.createBuffer();
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 3), err.code); // unconfigured_buffer
    try std.testing.expectEqualStrings("xdg_surface", err.interface);
}

test "client min/max size is applied to current at commit (F9)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    const toplevel = try xdg_surface.getToplevel();
    try ts.pump();
    wl_surface.commit();
    try ts.pump();
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();

    toplevel.setMinSize(100, 50);
    toplevel.setMaxSize(500, 400);
    const t = ts.shell.?.toplevels.items[0];
    try std.testing.expectEqual(geom.Size{ .w = 0, .h = 0 }, t.current.min_size);
    try std.testing.expectEqual(geom.Size{ .w = 0, .h = 0 }, t.current.max_size);

    // Double-buffered: nothing applies until the commit.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(geom.Size{ .w = 100, .h = 50 }, t.current.min_size);
    try std.testing.expectEqual(geom.Size{ .w = 500, .h = 400 }, t.current.max_size);

    // Invalid constraints still error at commit (existing check).
    toplevel.setMinSize(600, 50); // > max width
    wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 2), err.code); // invalid_size
    try std.testing.expectEqualStrings("xdg_toplevel", err.interface);
}

const MinimizeCapture = struct {
    count: usize = 0,
    listener: wire.Listener(*XdgToplevel),

    fn notify(listener: *wire.Listener(*XdgToplevel), _: *XdgToplevel) void {
        @as(*MinimizeCapture, @fieldParentPtr("listener", listener)).count += 1;
    }
};

const FullscreenCapture = struct {
    count: usize = 0,
    fullscreen: bool = false,
    output: ?*server.wl.Output = null,
    listener: wire.Listener(*FullscreenRequest),

    fn notify(listener: *wire.Listener(*FullscreenRequest), req: *FullscreenRequest) void {
        const self: *FullscreenCapture = @fieldParentPtr("listener", listener);
        self.count += 1;
        self.fullscreen = req.fullscreen;
        self.output = req.output;
    }
};

test "set_fullscreen carries the output; set_minimized emits a signal (F10)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var xs_events: XdgSurfaceEvents = .{};
    const toplevel = try setupConfiguredToplevel(ts, &xs_events);
    const t = ts.shell.?.toplevels.items[0];

    var fs_capture: FullscreenCapture = .{
        .listener = wire.Listener(*FullscreenRequest).init(FullscreenCapture.notify),
    };
    var min_capture: MinimizeCapture = .{ .listener = wire.Listener(*XdgToplevel).init(MinimizeCapture.notify) };
    t.events.request_fullscreen.add(&fs_capture.listener);
    t.events.request_minimize.add(&min_capture.listener);

    // No wl_output object in the test harness: null output is legal and
    // must reach the payload.
    toplevel.setFullscreen(null);
    toplevel.setMinimized();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), fs_capture.count);
    try std.testing.expect(fs_capture.fullscreen);
    try std.testing.expect(fs_capture.output == null);
    try std.testing.expectEqual(@as(usize, 1), min_capture.count);

    toplevel.unsetFullscreen();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), fs_capture.count);
    try std.testing.expect(!fs_capture.fullscreen);
}

const MoveCapture = struct {
    count: usize = 0,
    seat: ?*seat_mod.Seat = null,
    serial: u32 = 0,
    listener: wire.Listener(*MoveRequest),

    fn notify(listener: *wire.Listener(*MoveRequest), req: *MoveRequest) void {
        const self: *MoveCapture = @fieldParentPtr("listener", listener);
        self.count += 1;
        self.seat = req.seat;
        self.serial = req.serial;
    }
};

const WindowMenuCapture = struct {
    count: usize = 0,
    seat: ?*seat_mod.Seat = null,
    serial: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    listener: wire.Listener(*ShowWindowMenuRequest),

    fn notify(listener: *wire.Listener(*ShowWindowMenuRequest), req: *ShowWindowMenuRequest) void {
        const self: *WindowMenuCapture = @fieldParentPtr("listener", listener);
        self.count += 1;
        self.seat = req.seat;
        self.serial = req.serial;
        self.x = req.x;
        self.y = req.y;
    }
};

test "move and show_window_menu carry seat + serial (F11)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var xs_events: XdgSurfaceEvents = .{};
    const toplevel = try setupConfiguredToplevel(ts, &xs_events);
    const t = ts.shell.?.toplevels.items[0];

    var move_capture: MoveCapture = .{ .listener = wire.Listener(*MoveRequest).init(MoveCapture.notify) };
    var menu_capture: WindowMenuCapture = .{
        .listener = wire.Listener(*ShowWindowMenuRequest).init(WindowMenuCapture.notify),
    };
    t.events.request_move.add(&move_capture.listener);
    t.events.request_show_window_menu.add(&menu_capture.listener);

    toplevel.move(ts.wl_seat.?, 7);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), move_capture.count);
    try std.testing.expect(move_capture.seat == ts.seat);
    try std.testing.expectEqual(@as(u32, 7), move_capture.serial);

    toplevel.showWindowMenu(ts.wl_seat.?, 9, 12, 34);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), menu_capture.count);
    try std.testing.expect(menu_capture.seat == ts.seat);
    try std.testing.expectEqual(@as(u32, 9), menu_capture.serial);
    try std.testing.expectEqual(@as(i32, 12), menu_capture.x);
    try std.testing.expectEqual(@as(i32, 34), menu_capture.y);
}

test "zero-size anchor rect positioner is incomplete (F13)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    try ts.pump();

    // 0x0 anchor rect: size set, anchor rect set, but degenerate — the
    // completeness check must reject it (wlroots checks width > 0; we also
    // require a positive height).
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(0, 0, 0, 0);
    _ = try xdg_surface.getPopup(null, positioner);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 5), err.code); // invalid_positioner
    try std.testing.expectEqualStrings("xdg_wm_base", err.interface);

    // 10x0 anchor rect: width positive, height zero — still incomplete.
    var ts2 = try TestServer.init(allocator);
    defer ts2.deinit();
    const wl_surface2 = try ts2.wl_compositor.?.createSurface();
    const xdg_surface2 = try ts2.wm_base.?.getXdgSurface(wl_surface2);
    try ts2.pump();
    const positioner2 = try ts2.wm_base.?.createPositioner();
    positioner2.setSize(100, 50);
    positioner2.setAnchorRect(0, 0, 10, 0);
    _ = try xdg_surface2.getPopup(null, positioner2);
    try std.testing.expectError(error.ClientDispatchFailed, ts2.pump());
    const err2 = protocolError(ts2);
    try std.testing.expectEqual(@as(c_int, 5), err2.code);
    try std.testing.expectEqualStrings("xdg_wm_base", err2.interface);
}

const TitleCapture = struct {
    count: usize = 0,
    listener: wire.Listener(*XdgToplevel),

    fn notify(listener: *wire.Listener(*XdgToplevel), _: *XdgToplevel) void {
        @as(*TitleCapture, @fieldParentPtr("listener", listener)).count += 1;
    }
};

test "title/app_id change events; unmap clears metadata (F14)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    const toplevel = try xdg_surface.getToplevel();
    try ts.pump();
    const t = ts.shell.?.toplevels.items[0];

    var title_capture: TitleCapture = .{ .listener = wire.Listener(*XdgToplevel).init(TitleCapture.notify) };
    var appid_capture: TitleCapture = .{ .listener = wire.Listener(*XdgToplevel).init(TitleCapture.notify) };
    t.events.set_title.add(&title_capture.listener);
    t.events.set_app_id.add(&appid_capture.listener);

    toplevel.setTitle("hello");
    toplevel.setAppId("org.example.Foo");
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), title_capture.count);
    try std.testing.expectEqual(@as(usize, 1), appid_capture.count);
    try std.testing.expectEqualStrings("hello", t.title.?);

    // Invalid UTF-8: rejected, no event, connection survives.
    toplevel.setTitle("\xff\xfe");
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), title_capture.count);
    try std.testing.expectEqualStrings("hello", t.title.?);

    // Map, then unmap via NULL buffer: title/app_id are per-map.
    wl_surface.commit();
    try ts.pump();
    xdg_surface.ackConfigure(xs_events.serial);
    const buffer = try ts.createBuffer();
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(t.xdg_surface.surface.mapped);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(!t.xdg_surface.surface.mapped);
    try std.testing.expect(t.title == null);
    try std.testing.expect(t.app_id == null);
}

test "window geometry applies at commit, not ack (F15)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    _ = try xdg_surface.getToplevel();
    try ts.pump();

    wl_surface.commit();
    try ts.pump();
    const srv = ts.shell.?.toplevels.items[0].xdg_surface;

    // set_window_geometry is double-buffered: the ack alone must not apply
    // it (F15 — applied at commit).
    xdg_surface.setWindowGeometry(5, 7, 100, 100);
    xdg_surface.ackConfigure(xs_events.serial);
    try ts.pump();
    try std.testing.expectEqual(geom.Rect.empty(), srv.current_geometry);
    try std.testing.expectEqual(geom.Rect{ .x = 5, .y = 7, .width = 100, .height = 100 }, srv.pending_geometry);

    // The commit applies the pending window geometry.
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(geom.Rect{ .x = 5, .y = 7, .width = 100, .height = 100 }, srv.current_geometry);
}

test "set_parent stores the parent and rejects descendant cycles (F16)" {
    const allocator = std.testing.allocator;

    // Direct cycle: A.parent = B, then B.parent = A closes A -> B -> A.
    {
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const wl_surface_a = try ts.wl_compositor.?.createSurface();
        const xdg_surface_a = try ts.wm_base.?.getXdgSurface(wl_surface_a);
        var xs_events_a: XdgSurfaceEvents = .{};
        xdg_surface_a.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events_a);
        const a = try xdg_surface_a.getToplevel();
        const wl_surface_b = try ts.wl_compositor.?.createSurface();
        const xdg_surface_b = try ts.wm_base.?.getXdgSurface(wl_surface_b);
        var xs_events_b: XdgSurfaceEvents = .{};
        xdg_surface_b.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events_b);
        const b = try xdg_surface_b.getToplevel();
        try ts.pump();
        const t_a = ts.shell.?.toplevels.items[0];
        const t_b = ts.shell.?.toplevels.items[1];

        // X03: the parent link installs only when the parent is mapped —
        // map A and B (commit -> configure, ack, attach buffer, commit).
        const buffer = try ts.createBuffer();
        wl_surface_a.commit();
        try ts.pump();
        xdg_surface_a.ackConfigure(xs_events_a.serial);
        wl_surface_a.attach(buffer, 0, 0);
        wl_surface_a.commit();
        try ts.pump();
        wl_surface_b.commit();
        try ts.pump();
        xdg_surface_b.ackConfigure(xs_events_b.serial);
        wl_surface_b.attach(buffer, 0, 0);
        wl_surface_b.commit();
        try ts.pump();
        try std.testing.expect(t_a.xdg_surface.surface.mapped);
        try std.testing.expect(t_b.xdg_surface.surface.mapped);

        // A.parent = B: stored and exposed; B tracks A as a child.
        a.setParent(b);
        try ts.pump();
        try std.testing.expect(t_a.parent == t_b);
        try std.testing.expect(t_b.children.items.len == 1);
        try std.testing.expect(t_b.children.items[0] == t_a);

        // B.parent = A closes the cycle: invalid_parent on the toplevel.
        b.setParent(a);
        try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
        const err = protocolError(ts);
        try std.testing.expectEqual(@as(c_int, 1), err.code); // invalid_parent
        try std.testing.expectEqualStrings("xdg_toplevel", err.interface);
    }

    // Deeper cycle: C.parent = A (chain C -> A -> B), then A.parent = C
    // closes C -> A -> C.
    {
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const wl_surface_a = try ts.wl_compositor.?.createSurface();
        const xdg_surface_a = try ts.wm_base.?.getXdgSurface(wl_surface_a);
        var xs_events_a: XdgSurfaceEvents = .{};
        xdg_surface_a.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events_a);
        const a = try xdg_surface_a.getToplevel();
        const wl_surface_b = try ts.wl_compositor.?.createSurface();
        const xdg_surface_b = try ts.wm_base.?.getXdgSurface(wl_surface_b);
        var xs_events_b: XdgSurfaceEvents = .{};
        xdg_surface_b.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events_b);
        const b = try xdg_surface_b.getToplevel();
        const wl_surface_c = try ts.wl_compositor.?.createSurface();
        const xdg_surface_c = try ts.wm_base.?.getXdgSurface(wl_surface_c);
        var xs_events_c: XdgSurfaceEvents = .{};
        xdg_surface_c.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events_c);
        const c = try xdg_surface_c.getToplevel();
        try ts.pump();
        const t_a = ts.shell.?.toplevels.items[0];
        const t_c = ts.shell.?.toplevels.items[2];

        // Map A, B and C (X03: the parent must be mapped to install).
        const buffer = try ts.createBuffer();
        wl_surface_a.commit();
        try ts.pump();
        xdg_surface_a.ackConfigure(xs_events_a.serial);
        wl_surface_a.attach(buffer, 0, 0);
        wl_surface_a.commit();
        try ts.pump();
        wl_surface_b.commit();
        try ts.pump();
        xdg_surface_b.ackConfigure(xs_events_b.serial);
        wl_surface_b.attach(buffer, 0, 0);
        wl_surface_b.commit();
        try ts.pump();
        wl_surface_c.commit();
        try ts.pump();
        xdg_surface_c.ackConfigure(xs_events_c.serial);
        wl_surface_c.attach(buffer, 0, 0);
        wl_surface_c.commit();
        try ts.pump();
        try std.testing.expect(t_a.xdg_surface.surface.mapped);
        try std.testing.expect(t_c.xdg_surface.surface.mapped);

        a.setParent(b);
        c.setParent(a);
        try ts.pump();
        try std.testing.expect(t_c.parent == t_a);
        try std.testing.expect(t_a.children.items.len == 1);

        a.setParent(c);
        try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
        const err = protocolError(ts);
        try std.testing.expectEqual(@as(c_int, 1), err.code); // invalid_parent
        try std.testing.expectEqualStrings("xdg_toplevel", err.interface);
    }
}

test "set_parent to an unmapped toplevel clears the parent (X03)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface_a = try ts.wl_compositor.?.createSurface();
    const xdg_surface_a = try ts.wm_base.?.getXdgSurface(wl_surface_a);
    var xs_events_a: XdgSurfaceEvents = .{};
    xdg_surface_a.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events_a);
    const a = try xdg_surface_a.getToplevel();
    const wl_surface_b = try ts.wl_compositor.?.createSurface();
    const xdg_surface_b = try ts.wm_base.?.getXdgSurface(wl_surface_b);
    var xs_events_b: XdgSurfaceEvents = .{};
    xdg_surface_b.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events_b);
    const b = try xdg_surface_b.getToplevel();
    try ts.pump();
    const t_a = ts.shell.?.toplevels.items[0];
    const t_b = ts.shell.?.toplevels.items[1];

    // Neither toplevel is mapped: the parent link is not installed (the
    // request is treated as null, wlroots wlr_xdg_toplevel.c:193-199).
    a.setParent(b);
    try ts.pump();
    try std.testing.expect(t_a.parent == null);
    try std.testing.expect(t_b.children.items.len == 0);

    // Map B, then re-issue set_parent: the link installs.
    const buffer = try ts.createBuffer();
    wl_surface_b.commit();
    try ts.pump();
    xdg_surface_b.ackConfigure(xs_events_b.serial);
    wl_surface_b.attach(buffer, 0, 0);
    wl_surface_b.commit();
    try ts.pump();
    try std.testing.expect(t_b.xdg_surface.surface.mapped);

    a.setParent(b);
    try ts.pump();
    try std.testing.expect(t_a.parent == t_b);
    try std.testing.expect(t_b.children.items.len == 1);
    try std.testing.expect(t_b.children.items[0] == t_a);
}

test "grab on a mapped popup posts invalid_grab (X04a)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Map the parent toplevel first.
    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    var parent_xs_events: XdgSurfaceEvents = .{};
    parent_xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &parent_xs_events);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();
    parent_wl_surface.commit();
    try ts.pump();
    parent_xdg_surface.ackConfigure(parent_xs_events.serial);

    // Create the popup and map it.
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    positioner.destroy();
    try ts.pump();

    // The shared test buffer: created AFTER the popup surface so the
    // server-side teardown (a protocol error destroys the client's
    // resources in creation order) kills the popup's wl_surface before
    // the wl_buffer resource. Otherwise the F42 buffer-death listener
    // clears the popup's current slot first and the untracked wrapper is
    // orphaned (ShmBufferData + Buffer leak).
    const buffer = try ts.createBuffer();
    parent_wl_surface.attach(buffer, 0, 0);
    parent_wl_surface.commit();
    try ts.pump();
    try std.testing.expect(ts.shell.?.toplevels.items[0].xdg_surface.surface.mapped);
    wl_surface.commit();
    try ts.pump();
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    const p = ts.shell.?.popups.items[0];
    try std.testing.expect(p.xdg_surface.surface.mapped);

    // Grab on the mapped popup: invalid_grab (code 0) on the xdg_popup.
    popup.grab(ts.wl_seat.?, 1);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 0), err.code); // invalid_grab
    try std.testing.expectEqualStrings("xdg_popup", err.interface);
}

test "grab on a non-topmost popup posts not_the_topmost_popup (X04a)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();

    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);

    // P1 on the toplevel; P2 on top of P1: P1 is no longer topmost.
    const wl_surface_p1 = try ts.wl_compositor.?.createSurface();
    const xdg_surface_p1 = try ts.wm_base.?.getXdgSurface(wl_surface_p1);
    const popup1 = try xdg_surface_p1.getPopup(parent_xdg_surface, positioner);
    const wl_surface_p2 = try ts.wl_compositor.?.createSurface();
    const xdg_surface_p2 = try ts.wm_base.?.getXdgSurface(wl_surface_p2);
    const popup2 = try xdg_surface_p2.getPopup(xdg_surface_p1, positioner);
    _ = popup2;
    positioner.destroy();
    try ts.pump();

    // P2 is tracked as a child of P1's xdg_surface.
    const p1 = ts.shell.?.popups.items[0];
    const p2 = ts.shell.?.popups.items[1];
    try std.testing.expectEqual(@as(usize, 1), p1.xdg_surface.popups.items.len);
    try std.testing.expectEqual(@as(usize, 0), p2.xdg_surface.popups.items.len);

    // Grab on the non-topmost, unmapped P1: not_the_topmost_popup (code 2)
    // on the xdg_wm_base (not the popup).
    popup1.grab(ts.wl_seat.?, 1);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 2), err.code); // not_the_topmost_popup
    try std.testing.expectEqualStrings("xdg_wm_base", err.interface);
}

test "destroy of a non-topmost popup posts not_the_topmost_popup (X04a)" {
    const allocator = std.testing.allocator;

    // Destroying a non-topmost popup is an error on the wm_base.
    {
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const parent_wl_surface = try ts.wl_compositor.?.createSurface();
        const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
        _ = try parent_xdg_surface.getToplevel();
        try ts.pump();
        const positioner = try ts.wm_base.?.createPositioner();
        positioner.setSize(100, 50);
        positioner.setAnchorRect(10, 20, 200, 100);
        positioner.setAnchor(.bottom_right);
        positioner.setGravity(.bottom_right);
        const wl_surface_p1 = try ts.wl_compositor.?.createSurface();
        const xdg_surface_p1 = try ts.wm_base.?.getXdgSurface(wl_surface_p1);
        const popup1 = try xdg_surface_p1.getPopup(parent_xdg_surface, positioner);
        const wl_surface_p2 = try ts.wl_compositor.?.createSurface();
        const xdg_surface_p2 = try ts.wm_base.?.getXdgSurface(wl_surface_p2);
        const popup2 = try xdg_surface_p2.getPopup(xdg_surface_p1, positioner);
        _ = popup2;
        positioner.destroy();
        try ts.pump();

        popup1.destroy();
        try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
        const err = protocolError(ts);
        try std.testing.expectEqual(@as(c_int, 2), err.code); // not_the_topmost_popup
        try std.testing.expectEqualStrings("xdg_wm_base", err.interface);
    }

    // Destroying the topmost popup succeeds: P2 goes away and P1's child
    // list empties.
    {
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const parent_wl_surface = try ts.wl_compositor.?.createSurface();
        const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
        _ = try parent_xdg_surface.getToplevel();
        try ts.pump();
        const positioner = try ts.wm_base.?.createPositioner();
        positioner.setSize(100, 50);
        positioner.setAnchorRect(10, 20, 200, 100);
        positioner.setAnchor(.bottom_right);
        positioner.setGravity(.bottom_right);
        const wl_surface_p1 = try ts.wl_compositor.?.createSurface();
        const xdg_surface_p1 = try ts.wm_base.?.getXdgSurface(wl_surface_p1);
        const popup1 = try xdg_surface_p1.getPopup(parent_xdg_surface, positioner);
        const wl_surface_p2 = try ts.wl_compositor.?.createSurface();
        const xdg_surface_p2 = try ts.wm_base.?.getXdgSurface(wl_surface_p2);
        const popup2 = try xdg_surface_p2.getPopup(xdg_surface_p1, positioner);
        positioner.destroy();
        try ts.pump();
        const p1 = ts.shell.?.popups.items[0];

        popup2.destroy();
        try ts.pump();
        try std.testing.expectEqual(@as(usize, 1), ts.shell.?.popups.items.len);
        try std.testing.expectEqual(@as(usize, 0), p1.xdg_surface.popups.items.len);

        // P1 is topmost again: destroying it succeeds too.
        popup1.destroy();
        try ts.pump();
        try std.testing.expectEqual(@as(usize, 0), ts.shell.?.popups.items.len);
    }
}

test "popup reposition re-places and acknowledges the token (F1/F7)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    var popup_events: PopupEvents = .{};

    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy();
    try ts.pump();
    const p = ts.shell.?.popups.items[0];

    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), popup_events.configure_count);
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(p.xdg_surface.configured);
    try std.testing.expectEqual(
        geom.Rect{ .x = 210, .y = 120, .width = 100, .height = 50 },
        p.acked_geometry.?,
    );

    // Reposition with a new positioner: repositioned(token) then a fresh
    // configure with the new placement.
    const positioner2 = try ts.wm_base.?.createPositioner();
    positioner2.setSize(100, 50);
    positioner2.setAnchorRect(0, 0, 50, 50);
    positioner2.setAnchor(.bottom_right);
    positioner2.setGravity(.bottom_right);
    popup.reposition(positioner2, 42);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), popup_events.configure_count);
    try std.testing.expectEqual(@as(i32, 50), popup_events.x);
    try std.testing.expectEqual(@as(i32, 50), popup_events.y);

    // Acking the reposition configure updates the acked geometry (F7).
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(
        geom.Rect{ .x = 50, .y = 50, .width = 100, .height = 50 },
        p.acked_geometry.?,
    );

    // An incomplete positioner on reposition is invalid_positioner (size
    // set but no anchor rect: complete-set but incomplete).
    const bad_positioner = try ts.wm_base.?.createPositioner();
    bad_positioner.setSize(100, 50);
    popup.reposition(bad_positioner, 43);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 5), err.code); // invalid_positioner
    try std.testing.expectEqualStrings("xdg_wm_base", err.interface);
}

// --- X04b: popup seat-grab routing -----------------------------------------

/// Event log for the popup client's wl_pointer during a grab.
const PopupGrabPointerEvents = struct {
    entered: bool = false,
    /// The enter's surface-local position as the client decoded it.
    enter_x: i24 = 0,
    enter_y: i24 = 0,
    motion: usize = 0,
    /// The last motion's surface-local position as the client decoded it.
    motion_x: i24 = 0,
    motion_y: i24 = 0,
    presses: usize = 0,
    releases: usize = 0,
    /// Leaves the client received. Every enter the grab sends must be
    /// balanced by exactly one of these when the grab ends.
    leaves: usize = 0,
    frame: usize = 0,

    fn listener(pointer: *client.wl.Pointer, event: client.wl.Pointer.Event, data: *PopupGrabPointerEvents) void {
        _ = pointer;
        switch (event) {
            .enter => |e| {
                data.entered = true;
                data.enter_x = e.surface_x.toInt();
                data.enter_y = e.surface_y.toInt();
            },
            .motion => |m| {
                data.motion += 1;
                data.motion_x = m.surface_x.toInt();
                data.motion_y = m.surface_y.toInt();
            },
            .button => |b| switch (b.state) {
                .pressed => data.presses += 1,
                .released => data.releases += 1,
                else => {},
            },
            .frame => data.frame += 1,
            .leave => data.leaves += 1,
            .axis, .axis_stop, .axis_discrete, .axis_source, .axis_value120, .axis_relative_direction => {
                // Not routed by the popup grab (wlroots xdg_popup scope).
            },
            .warp => {},
        }
    }
};

/// Event counts for the popup client's wl_keyboard during a grab.
const PopupGrabKeyboardEvents = struct {
    key: usize = 0,
    modifiers: usize = 0,

    fn listener(keyboard: *client.wl.Keyboard, event: client.wl.Keyboard.Event, data: *PopupGrabKeyboardEvents) void {
        _ = keyboard;
        switch (event) {
            .key => data.key += 1,
            .modifiers => data.modifiers += 1,
            .keymap => |e| {
                // The fd is owned by the receiving client: close it.
                _ = std.os.linux.close(e.fd);
            },
            .enter, .leave, .repeat_info => {},
        }
    }
};

/// Stand up the fixture the X04b routing tests share: a toplevel
/// parent, a 100x50 popup on it with `popup_events` attached, and
/// `xdg_popup.grab` installed over it. The caller's wl_pointer and
/// wl_keyboard listeners must already be attached — the grab routes to
/// those resources. Returns the shell-side popup.
fn installTestPopupGrab(ts: *TestServer, popup_events: *PopupEvents) !*XdgPopup {
    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();

    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, popup_events);
    positioner.destroy();
    try ts.pump();

    // Grab the unmapped, topmost popup with a serial the client was
    // just handed: the keyboard focus change mints one (xdg_popup.grab
    // is only valid in response to a user action).
    const p = ts.shell.?.popups.items[0];
    ts.seat.?.setKeyboardFocus(p.xdg_surface.surface);
    popup.grab(ts.wl_seat.?, ts.seat.?.last_serial);
    try ts.pump();
    return p;
}

/// A keyboard grab owned by a different subsystem. Its cancel clears
/// the seat's slot exactly as the seat's endKeyboardGrab does, so a
/// popup ending a grab it never installed is directly observable.
const foreign_keyboard_grab: seat_mod.KeyboardGrab = .{
    .data = null,
    .key = foreignGrabKey,
    .modifiers = foreignGrabModifiers,
    .cancel = foreignGrabCancel,
};

fn foreignGrabKey(_: *seat_mod.Seat, _: *const seat_mod.KeyboardGrab, _: u32, _: bool) void {}

fn foreignGrabModifiers(_: *seat_mod.Seat, _: *const seat_mod.KeyboardGrab) void {}

fn foreignGrabCancel(seat: *seat_mod.Seat, grab: *const seat_mod.KeyboardGrab) void {
    if (seat.keyboard_grab == grab) seat.keyboard_grab = null;
}

test "xdg_popup.grab installs pointer + keyboard grabs routing to the popup client (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // The popup client's seat resources: the grab routes to these.
    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    const wl_keyboard = try ts.wl_seat.?.getKeyboard();
    var kbd_events: PopupGrabKeyboardEvents = .{};
    wl_keyboard.setListener(*PopupGrabKeyboardEvents, PopupGrabKeyboardEvents.listener, &kbd_events);
    try ts.pump();

    var popup_events: PopupEvents = .{};
    const p = try installTestPopupGrab(ts, &popup_events);
    // No protocol error; the grabs are installed (a grab echoed with a
    // serial the client never received is ignored — see the test below).
    try std.testing.expect(p.grab_state != null);
    try std.testing.expect(ts.seat.?.pointer_grab != null);
    try std.testing.expect(ts.seat.?.keyboard_grab != null);

    // Motion routes to the popup client's pointer: the grab delivers the
    // enter (the seat never picks under a grab) and then the motion. The
    // xdg TestServer does not auto-flush pointer frames, so close the
    // batch explicitly.
    ts.seat.?.pointerMotion(100, 120);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expect(ptr_events.entered);
    try std.testing.expectEqual(@as(usize, 1), ptr_events.motion);
    try std.testing.expectEqual(@as(usize, 1), ptr_events.frame);

    // A key event routes to the popup client's keyboard regardless of the
    // seat's keyboard focus, and a modifier change routes too. (Reset
    // first: the pre-grab setKeyboardFocus delivered its own modifiers
    // event to this keyboard.)
    kbd_events = .{};
    ts.seat.?.keyEvent(38, true); // 'a'
    ts.seat.?.keyEvent(50, true); // Shift_L: also a modifier change
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), kbd_events.key);
    try std.testing.expectEqual(@as(usize, 1), kbd_events.modifiers);

    // The pointer is outside the popup: the unsynced origin is (0,0), so
    // the popup's absolute rect spans x 0..100 and y 0..50, which
    // (100,120) misses. The press dismisses: popup_done, no button
    // event, then both grabs end.
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), popup_events.done_count);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.presses);
    try std.testing.expect(ts.seat.?.pointer_grab == null);
    try std.testing.expect(ts.seat.?.keyboard_grab == null);
    try std.testing.expect(!p.grab_state.?.active);

    // The grab is gone and the seat has no pointer focus, so the release
    // reaches nobody: the client never got the press.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ptr_events.releases);

    // After the grab ends the seat is back to default delivery: another
    // press is not an error and sends no duplicate popup_done.
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), popup_events.done_count);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.presses);
}

test "popup grab delivers an inside press and its release to the popup client (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    try ts.pump();
    var popup_events: PopupEvents = .{};
    const p = try installTestPopupGrab(ts, &popup_events);

    // The scene sync placed the popup's surface origin at (100,200), so
    // its absolute rect spans x 100..200 and y 200..250. geometry.x/y are
    // parent-relative and are NOT added on top of that origin.
    p.setPopupOrigin(100, 200);

    // Inside the popup: the press reaches the client, and the grab stays
    // so the click can complete (a menu that dismissed on the press
    // could never activate an item).
    ts.seat.?.pointerMotion(150, 220);
    ts.seat.?.pointerFrame();
    try ts.pump();
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.presses);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);
    try std.testing.expect(p.grab_state.?.active);
    try std.testing.expect(ts.seat.?.pointer_grab != null);

    // The matching release reaches the same client.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);
    try std.testing.expect(p.grab_state.?.active);

    // A release for a button the grab never pressed is swallowed: a
    // client must never see a release whose press it never got.
    ts.seat.?.pointerButton(seat_mod.btn_right, false);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.releases);
    try std.testing.expect(p.grab_state.?.active);
}

test "popup grab dismisses on a press outside the popup (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    try ts.pump();
    var popup_events: PopupEvents = .{};
    const p = try installTestPopupGrab(ts, &popup_events);
    p.setPopupOrigin(100, 200);

    // The popup's rect is half-open: (200,225) is its right edge, not
    // its interior, so the press dismisses rather than reaching the
    // client.
    ts.seat.?.pointerMotion(200, 225);
    ts.seat.?.pointerFrame();
    try ts.pump();
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), popup_events.done_count);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.presses);
    try std.testing.expect(ts.seat.?.pointer_grab == null);
    try std.testing.expect(ts.seat.?.keyboard_grab == null);
    try std.testing.expect(!p.grab_state.?.active);

    // The release of that press never reaches the popup client: the grab
    // that never sent the press is gone, and the seat's default path has
    // no pointer focus to fall back on.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 1), popup_events.done_count);
}

test "popup grab converts seat coordinates to surface-local ones (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    try ts.pump();
    var popup_events: PopupEvents = .{};
    const p = try installTestPopupGrab(ts, &popup_events);

    // The scene has not placed the popup yet: the origin defaults to
    // (0,0), so seat coordinates pass through unchanged.
    ts.seat.?.pointerMotion(7, 9);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expect(ptr_events.entered);
    try std.testing.expectEqual(@as(i24, 7), ptr_events.enter_x);
    try std.testing.expectEqual(@as(i24, 9), ptr_events.enter_y);
    try std.testing.expectEqual(@as(i24, 7), ptr_events.motion_x);
    try std.testing.expectEqual(@as(i24, 9), ptr_events.motion_y);

    // After the scene sync places the popup, motion carries
    // surface-local coordinates — a pointer left of and above the
    // popup's top-left corner is negative, not clamped
    // (wayland.xml:2206-2209, the enter event's "surface-local x
    // coordinate").
    p.setPopupOrigin(100, 200);
    ts.seat.?.pointerMotion(90, 190);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ptr_events.motion);
    try std.testing.expectEqual(@as(i24, -10), ptr_events.motion_x);
    try std.testing.expectEqual(@as(i24, -10), ptr_events.motion_y);
    // The enter is sent once, so it still carries the unsynced origin.
    try std.testing.expectEqual(@as(i24, 7), ptr_events.enter_x);

    // The origin is re-synced every frame: the conversion follows it.
    p.setPopupOrigin(4, 5);
    ts.seat.?.pointerMotion(14, 15);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(i24, 10), ptr_events.motion_x);
    try std.testing.expectEqual(@as(i24, 10), ptr_events.motion_y);
}

/// The compositor's screen → world conversion, in the shape
/// `XdgShell.setScreenToWorld` takes: the seat's output pixels in, the
/// same point in world pixels out. Backed by the real Camera, so the
/// test exercises the same transform main.zig installs.
fn testCameraScreenToWorld(ctx: *anyopaque, sx: i32, sy: i32) geom.FPoint {
    const cam: *const camera_mod.Camera = @ptrCast(@alignCast(ctx));
    return cam.screenToWorld(@floatFromInt(sx), @floatFromInt(sy));
}

test "screen to world conversion preserves distant fractional positions" {
    const ts = try TestServer.init(std.testing.allocator);
    defer ts.deinit();
    var camera: camera_mod.Camera = .{
        .center_x = 1099511627776.25,
        .center_y = -1099511627776.5,
        .zoom = 4,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    ts.shell.?.setScreenToWorld(testCameraScreenToWorld, &camera);
    const point = ts.shell.?.worldFromScreen(401, 302);
    try std.testing.expectEqual(@as(f64, 1099511627776.5), point.x);
    try std.testing.expectEqual(@as(f64, -1099511627776.0), point.y);
}

/// The output pixel at which `cam` renders the world point (wx, wy) —
/// the seat coordinate a user clicking that point produces.
fn screenPointOf(cam: camera_mod.Camera, wx: f64, wy: f64) geom.Point {
    const s = cam.worldToScreen(wx, wy);
    return .{ .x = @intFromFloat(s.x), .y = @intFromFloat(s.y) };
}

test "popup grab hit-tests in world coordinates under a zoomed camera (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    try ts.pump();
    var popup_events: PopupEvents = .{};

    // The view is zoomed 2x on an 800x600 viewport. Camera zoom and pan
    // are live gestures, so the seat's coordinates and the popup's
    // world origin live in different spaces from here on.
    var cam: camera_mod.Camera = .{
        .center_x = 0,
        .center_y = 0,
        .zoom = 2,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    ts.shell.?.setScreenToWorld(testCameraScreenToWorld, &cam);
    const p = try installTestPopupGrab(ts, &popup_events);

    // The scene sync publishes the popup's ABSOLUTE WORLD position
    // (syncPopupNodes reads SceneNode.absolutePosition): world rect
    // (100,200)-(200,250).
    p.setPopupOrigin(100, 200);

    // A click that visibly lands in the middle of the popup. Under the
    // identity camera this would be the seat point (150,220); the zoom
    // moves it, and the grab has to follow.
    const click = screenPointOf(cam, 150, 220);
    try std.testing.expect(click.x != 150 or click.y != 220);
    ts.seat.?.pointerMotion(click.x, click.y);
    ts.seat.?.pointerFrame();
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    ts.seat.?.pointerFrame();
    try ts.pump();

    // Surface-local, not screen: (150,220) - (100,200) = (50,20).
    try std.testing.expectEqual(@as(i24, 50), ptr_events.enter_x);
    try std.testing.expectEqual(@as(i24, 20), ptr_events.enter_y);
    // The click is inside the popup: it reaches the client and the grab
    // stays. Reading the seat's raw pixels against the world origin
    // would call this point far outside and dismiss the menu under the
    // user's finger.
    try std.testing.expectEqual(@as(usize, 1), ptr_events.presses);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);
    try std.testing.expect(p.grab_state.?.active);

    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.releases);

    // The same click with the view turned a quarter turn. The surface
    // axes no longer line up with the screen ones, so only a real
    // camera inverse can find the popup; the exact local coordinate is
    // not asserted because the world→screen→world round trip through
    // integer output pixels can differ by one.
    cam.rotation = std.math.pi / 2.0;
    const rotated = screenPointOf(cam, 140, 225);
    ts.seat.?.pointerMotion(rotated.x, rotated.y);
    ts.seat.?.pointerFrame();
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ptr_events.motion);
    try std.testing.expect(ptr_events.motion_x >= 0 and ptr_events.motion_x < 100);
    try std.testing.expect(ptr_events.motion_y >= 0 and ptr_events.motion_y < 50);
    try std.testing.expectEqual(@as(usize, 2), ptr_events.presses);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);
    try std.testing.expect(p.grab_state.?.active);
}

test "popup grab leaves the popup surface when a dismissal ends it (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    try ts.pump();
    var popup_events: PopupEvents = .{};
    const p = try installTestPopupGrab(ts, &popup_events);
    p.setPopupOrigin(100, 200);

    // The grab's own enter for the popup surface: the seat never
    // hit-tests under a grab, so the grab sends it itself.
    ts.seat.?.pointerMotion(150, 220);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expect(ptr_events.entered);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.leaves);

    // Moving off the popup does not leave it: the grab keeps routing
    // motion, and that enter is still open.
    ts.seat.?.pointerMotion(400, 400);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ptr_events.leaves);

    // A press outside dismisses. The enter the grab sent must be
    // balanced by a leave in the same batch, or the client keeps the
    // popup surface as its pointer focus forever (wayland.xml:
    // 2212-2218). Nothing is owed for the outside press itself: it was
    // never delivered, so no release may be invented for it.
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), popup_events.done_count);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.presses);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 1), ptr_events.leaves);
    try std.testing.expect(ts.seat.?.pointer_grab == null);

    // Idempotent: the cancel path that runs inside endPointerGrab
    // calls back into popupGrabEnd, and no second leave is sent.
    popupGrabEnd(p.grab_state.?, false);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.leaves);
}

test "popup grab releases a held button to its client when the popup is destroyed (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    try ts.pump();
    var popup_events: PopupEvents = .{};

    // The fixture is inlined rather than installTestPopupGrab because
    // this test needs the client-side proxy to destroy the popup.
    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy();
    try ts.pump();
    const p = ts.shell.?.popups.items[0];
    ts.seat.?.setKeyboardFocus(p.xdg_surface.surface);
    popup.grab(ts.wl_seat.?, ts.seat.?.last_serial);
    try ts.pump();
    p.setPopupOrigin(100, 200);

    // The menu-item flow: a press inside the popup reaches the client
    // and the grab stays so the click can complete.
    ts.seat.?.pointerMotion(150, 220);
    ts.seat.?.pointerFrame();
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.presses);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 1), p.grab_state.?.held_button_count);

    // The client destroys the popup while the button is still down. The
    // release belongs to the client that got the press; the seat's
    // default path is not an alternative, because it delivers to a
    // pointer focus this grab never re-picked (seat.zig:877-883) — and
    // with no pick installed that focus is null, so the release would
    // reach nobody and the client would be left with a button stuck
    // down for the rest of the session.
    popup.destroy();
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 1), ptr_events.leaves);
    try std.testing.expect(ts.seat.?.pointer_grab == null);
    try std.testing.expect(ts.seat.?.keyboard_grab == null);
    // Teardown never dismisses (popup_done is not sent here).
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);

    // The physical release that follows finds an empty set: no second
    // release is invented for a button that is already up.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);
}

test "popup grab ends when the popup's own surface unmaps (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // The popup client's seat resources: the grab routes to these, so
    // both streams are countable after the unmap.
    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    const wl_keyboard = try ts.wl_seat.?.getKeyboard();
    var kbd_events: PopupGrabKeyboardEvents = .{};
    wl_keyboard.setListener(*PopupGrabKeyboardEvents, PopupGrabKeyboardEvents.listener, &kbd_events);
    try ts.pump();

    // The fixture is inlined rather than installTestPopupGrab because
    // this test needs the client-side proxies to map and unmap.
    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    var parent_events: XdgSurfaceEvents = .{};
    parent_xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &parent_events);
    const parent_buffer = try ts.createBuffer();
    try ts.pump();
    parent_wl_surface.commit();
    try ts.pump();
    parent_xdg_surface.ackConfigure(parent_events.serial);
    parent_wl_surface.attach(parent_buffer, 0, 0);
    parent_wl_surface.commit();
    try ts.pump();

    var popup_events: PopupEvents = .{};
    var xs_events: XdgSurfaceEvents = .{};
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy();
    const popup_buffer = try ts.createBuffer2();
    try ts.pump();

    // Grab the unmapped popup with a serial the client was just handed:
    // the keyboard focus change mints one.
    const p = ts.shell.?.popups.items[0];
    ts.seat.?.setKeyboardFocus(p.xdg_surface.surface);
    popup.grab(ts.wl_seat.?, ts.seat.?.last_serial);
    try ts.pump();
    try std.testing.expect(p.grab_state != null);

    // Nothing else holds the keyboard, so the grab is the ONLY route a
    // keystroke can take. With it stuck past the popup's map, this one
    // client captures the keyboard from every other client for the rest
    // of the connection. (The pre-grab focus sent its own modifiers,
    // hence the reset.)
    ts.seat.?.setKeyboardFocus(null);
    kbd_events = .{};

    // Map: initial commit -> configure -> ack -> attach -> commit.
    wl_surface.commit();
    try ts.pump();
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(popup_buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(p.xdg_surface.surface.mapped);

    // The grab survives the map. The seat never hit-tests under a grab,
    // so the enter for the popup surface is the grab's own, delivered on
    // the first motion; the press inside then reaches the client.
    p.setPopupOrigin(100, 200);
    ts.seat.?.pointerMotion(150, 220);
    ts.seat.?.pointerFrame();
    try ts.pump();
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expect(ptr_events.entered);
    try std.testing.expectEqual(@as(usize, 1), ptr_events.presses);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);
    try std.testing.expect(p.grab_state.?.active);
    // A key is routed by the grab while it lives.
    ts.seat.?.keyEvent(38, true); // 'a'
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), kbd_events.key);

    // The client commits attach(null): the popup unmaps, and its
    // xdg_popup object survives. No client destroy, no grab cancel and
    // no press outside, so nothing else reaches popupGrabEnd.
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expect(!p.xdg_surface.surface.mapped);

    // Both seat slots are free again — the grab must not outlive the
    // surface it grabbed.
    try std.testing.expect(ts.seat.?.pointer_grab == null);
    try std.testing.expect(ts.seat.?.keyboard_grab == null);
    try std.testing.expect(!p.grab_state.?.active);

    // The press the grab delivered is released to the client that got
    // it, and the enter it sent is balanced by a leave. Both are owed
    // BEFORE the seat's default path takes over, which would deliver
    // the release to a pointer focus this grab never picked
    // (seat.zig:877-883) and leave the button stuck down.
    try std.testing.expectEqual(@as(usize, 1), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 1), ptr_events.leaves);
    // No popup_done: the client unmapped its own popup, so nothing was
    // dismissed (xdg-shell.xml:1358-1363).
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);

    // The keyboard is free: with no grab and no focus, the key reaches
    // nobody — the popup client no longer captures it.
    ts.seat.?.keyEvent(39, true); // 's'
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), kbd_events.key);

    // The physical release that follows finds an empty set: no second
    // release is invented, and the enter is not left twice.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 1), ptr_events.leaves);
}

test "a popup that unmaps with no grab installed is unaffected (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    const wl_keyboard = try ts.wl_seat.?.getKeyboard();
    var kbd_events: PopupGrabKeyboardEvents = .{};
    wl_keyboard.setListener(*PopupGrabKeyboardEvents, PopupGrabKeyboardEvents.listener, &kbd_events);
    try ts.pump();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();
    var popup_events: PopupEvents = .{};
    var xs_events: XdgSurfaceEvents = .{};
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy();
    const popup_buffer = try ts.createBuffer2();
    try ts.pump();

    // Map: initial commit -> configure -> ack -> attach -> commit. No
    // xdg_popup.grab anywhere: this popup owns no grab to end.
    wl_surface.commit();
    try ts.pump();
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(popup_buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    const p = ts.shell.?.popups.items[0];
    try std.testing.expect(p.xdg_surface.surface.mapped);
    try std.testing.expect(p.grab_state == null);

    // Unmap. The role hook now ends an own-surface grab, and there is
    // none: nothing is invented for a grab that never delivered a
    // press or an enter.
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    ts.seat.?.pointerFrame();
    try ts.pump();
    try std.testing.expect(!p.xdg_surface.surface.mapped);
    try std.testing.expect(p.grab_state == null);
    try std.testing.expect(ts.seat.?.pointer_grab == null);
    try std.testing.expect(ts.seat.?.keyboard_grab == null);
    try std.testing.expect(!ptr_events.entered);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.presses);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.releases);
    try std.testing.expectEqual(@as(usize, 0), ptr_events.leaves);
    try std.testing.expectEqual(@as(usize, 0), kbd_events.key);

    // The role survives an own-surface unmap (only a PARENT unmap
    // destroys a child popup), and the unmap is not a dismissal.
    try std.testing.expectEqual(@as(usize, 1), ts.shell.?.popups.items.len);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);

    // And the same xdg_popup maps again: the client redoes the initial
    // commit, acks the fresh configure and attaches a buffer.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), popup_events.configure_count);
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(popup_buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(p.xdg_surface.surface.mapped);
}

test "popupGrabEnd leaves a keyboard grab it does not own installed (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_pointer = try ts.wl_seat.?.getPointer();
    var ptr_events: PopupGrabPointerEvents = .{};
    wl_pointer.setListener(*PopupGrabPointerEvents, PopupGrabPointerEvents.listener, &ptr_events);
    try ts.pump();
    var popup_events: PopupEvents = .{};
    const p = try installTestPopupGrab(ts, &popup_events);

    // Another subsystem owns the seat's keyboard slot while the popup
    // grab is live.
    ts.seat.?.keyboard_grab = &foreign_keyboard_grab;

    // The popup's grab ends. It must end the pointer grab it installed
    // and leave the foreign keyboard grab alone: ending a grab it does
    // not own cancels someone else's grab, and every key event is lost
    // until its owner re-arms (the same ownership check Drag.end makes,
    // data_device.zig:335).
    popupGrabEnd(p.grab_state.?, false);
    try std.testing.expect(!p.grab_state.?.active);
    try std.testing.expect(ts.seat.?.pointer_grab == null);
    try std.testing.expect(ts.seat.?.keyboard_grab == &foreign_keyboard_grab);

    // A second end is a no-op (the cancel handlers call back into it).
    popupGrabEnd(p.grab_state.?, false);
    try std.testing.expect(ts.seat.?.keyboard_grab == &foreign_keyboard_grab);
    try std.testing.expectEqual(@as(usize, 0), popup_events.done_count);
}

test "xdg_popup.grab with a serial the client never received is ignored (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    positioner.destroy();
    try ts.pump();

    // No serial was ever handed to this client: the grab is ignored —
    // not a protocol error (the connection survives; same semantics as
    // wl_pointer.set_cursor's serial check).
    popup.grab(ts.wl_seat.?, 12345);
    try ts.pump();
    const p = ts.shell.?.popups.items[0];
    try std.testing.expect(p.grab_state == null);
    try std.testing.expect(ts.seat.?.pointer_grab == null);
    try std.testing.expect(ts.seat.?.keyboard_grab == null);
}

test "popup destroy ends an active grab before freeing (X04b)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    positioner.destroy();
    try ts.pump();

    const p = ts.shell.?.popups.items[0];
    ts.seat.?.setKeyboardFocus(p.xdg_surface.surface);
    const serial = ts.seat.?.last_serial;
    popup.grab(ts.wl_seat.?, serial);
    try ts.pump();
    try std.testing.expect(ts.seat.?.pointer_grab != null);

    // Client-initiated destroy: the grab must be ended (the seat must
    // not keep a dangling data pointer) before the popup is freed.
    popup.destroy();
    try ts.pump();
    try std.testing.expect(ts.seat.?.pointer_grab == null);
    try std.testing.expect(ts.seat.?.keyboard_grab == null);
    try std.testing.expectEqual(@as(usize, 0), ts.shell.?.popups.items.len);
}

// --- X05: reactive popup reconfigure ----------------------------------------

test "reactive popup reconfigure re-places and echoes the token (X05)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var xs_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    var popup_events: PopupEvents = .{};

    // Reactive slide_x popup: the raw geometry hangs off the left edge.
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(0, 100, 100, 100);
    positioner.setAnchor(.top_left);
    positioner.setGravity(.top_left);
    positioner.setConstraintAdjustment(@bitCast(@as(u32, 1))); // slide_x
    positioner.setReactive();
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy();
    try ts.pump();
    const p = ts.shell.?.popups.items[0];
    // set_reactive was captured into the positioner rules at get_popup.
    try std.testing.expect(p.positioner_rules.reactive);
    try std.testing.expectEqual(
        geom.Rect{ .x = -100, .y = 50, .width = 100, .height = 50 },
        p.geometry,
    );

    // Map the popup: initial configure at the raw (unconstrained) geometry.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), popup_events.configure_count);
    try std.testing.expectEqual(@as(i32, -100), popup_events.x);
    xdg_surface.ackConfigure(xs_events.serial);
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(p.xdg_surface.configured);

    // Compositor-initiated reconfigure with a fresh constraint box:
    // recomputed geometry, a fresh configure, and repositioned(token).
    p.setConstraintBox(.{ .x = 0, .y = 0, .width = 200, .height = 200 });
    try p.reconfigure(99);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), popup_events.configure_count);
    try std.testing.expectEqual(@as(i32, 0), popup_events.x);
    try std.testing.expectEqual(@as(i32, 50), popup_events.y);
    try std.testing.expectEqual(@as(usize, 1), popup_events.repositioned_count);
    try std.testing.expectEqual(@as(u32, 99), popup_events.repositioned_token);
    try std.testing.expectEqual(
        geom.Rect{ .x = 0, .y = 50, .width = 100, .height = 50 },
        p.geometry,
    );
}

test "non-reactive popup reconfigure returns NotReactive (X05)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    var popup_events: PopupEvents = .{};
    const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    positioner.destroy();
    try ts.pump();

    // No set_reactive: the compositor may not re-place the popup. The
    // rejection is compositor-side (error.NotReactive) — there is no
    // not_reactive wire error in the protocol (smithay returns
    // PopupConfigureError::NotReactive the same way).
    const p = ts.shell.?.popups.items[0];
    try std.testing.expectError(error.NotReactive, p.reconfigure(7));
    try ts.pump();
    // Nothing was sent: no configure, no repositioned.
    try std.testing.expectEqual(@as(usize, 0), popup_events.configure_count);
    try std.testing.expectEqual(@as(usize, 0), popup_events.repositioned_count);
}

test "reconfigure on a v2-bound popup returns NotReactive (X05 version gate)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.initAtVersion(allocator, 2);
    defer ts.deinit();

    const parent_wl_surface = try ts.wl_compositor.?.createSurface();
    const parent_xdg_surface = try ts.wm_base.?.getXdgSurface(parent_wl_surface);
    _ = try parent_xdg_surface.getToplevel();
    try ts.pump();
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 20, 200, 100);
    positioner.setAnchor(.bottom_right);
    positioner.setGravity(.bottom_right);
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getPopup(parent_xdg_surface, positioner);
    positioner.destroy();
    try ts.pump();

    // xdg_popup.configure's re-send and xdg_popup.repositioned are both
    // since v3, and there is no xdg_popup.reconfigure REQUEST in the
    // protocol at all (reposition, since 3, is the only client re-place
    // path), so the wire is unreachable below v3 by construction. The
    // compositor-facing reconfigure enforces the same gate: a v2 popup
    // is refused and nothing is marshalled.
    const p = ts.shell.?.popups.items[0];
    try std.testing.expectEqual(@as(u32, 2), p.resource.getVersion());
    try std.testing.expectError(error.NotReactive, p.reconfigure(3));
}
