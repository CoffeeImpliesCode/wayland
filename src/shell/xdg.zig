//! xdg-shell: the xdg_wm_base global plus the XdgSurface / XdgToplevel /
//! XdgPopup state machines (stable/xdg-shell protocol).
//!
//! M1 scope: xdg_wm_base global, XdgSurface (toplevel + popup roles),
//! configure / ack_configure, map/unmap. No seat interaction, no popup grabs
//! (M3), no constraint adjustment / reactive repositioning (M4).
//!
//! Mapping semantics: an xdg surface maps when the client commits a buffer
//! after acking a configure. The compositor's commit pipeline performs the
//! map/unmap transition (`mapped = current.buffer != null` plus role map/unmap
//! hooks and signals); `ack_configure` only marks the surface as configured,
//! which is what permits attaching a buffer in the first place (see
//! `xdgSurfaceClientCommit`).
//!
//! Cross-module contract (types written by other M1 agents; do not drift):
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
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const role_mod = @import("../compositor/role.zig");
const surface_mod = @import("../compositor/surface.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "xdg";

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
    events: struct {
        /// A new xdg_toplevel role object was created.
        new_toplevel: wire.Signal(*XdgToplevel),
        /// A new xdg_popup role object was created.
        new_popup: wire.Signal(*XdgPopup),
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

fn wmBaseBind(client_wire: *wire.Client, shell: *XdgShell, version: u32, id: u32) void {
    const wm_base = server.xdg.WmBase.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    wm_base.setHandler(*XdgShell, wmBaseRequest, null, shell);
}

fn wmBaseRequest(wm_base: *server.xdg.WmBase, request: server.xdg.WmBase.Request, shell: *XdgShell) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => wm_base.destroy(),
        .create_positioner => |r| {
            const res = server.xdg.Positioner.create(wm_base.getClient(), wm_base.getVersion(), r.id) catch {
                wm_base.postNoMemory();
                return;
            };
            const state = shell.allocator.create(PositionerState) catch {
                wm_base.postNoMemory();
                return;
            };
            state.* = .{ .shell = shell };
            res.setHandler(*PositionerState, positionerRequest, positionerDestroy, state);
        },
        .get_xdg_surface => |r| wmBaseGetXdgSurface(wm_base, shell, r),
        .pong => |r| log.debug("xdg_wm_base.pong serial={d}", shell.io, shell.log_cfg, log_tag, .{r.serial}),
    }
}

fn wmBaseGetXdgSurface(wm_base: *server.xdg.WmBase, shell: *XdgShell, r: anytype) void {
    // The wl_surface resource's user data is the compositor's Surface.
    const surface: *surface_mod.Surface = @ptrCast(@alignCast(r.surface.getUserData()));
    const res = server.xdg.Surface.create(wm_base.getClient(), wm_base.getVersion(), r.id) catch {
        wm_base.postNoMemory();
        return;
    };
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
        .resource = res,
        .surface = surface,
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    xdg.events.destroy.init();
    res.setHandler(*XdgSurface, xdgSurfaceRequest, xdgSurfaceDestroy, xdg);
    // Assigns the "xdg_surface" role to the wl_surface. On a role conflict
    // assignRole posts the wl_surface role error; drop the new object.
    role_mod.assignRole(surface, &xdg_surface_role, @as(?*wire.Resource, @ptrCast(res))) catch {
        res.destroy();
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
    /// A configure has been sent at least once since the last (re)map.
    configure_sent: bool = false,
    /// Window geometry from set_window_geometry (double-buffered).
    pending_geometry: geom.Rect = geom.Rect.empty(),
    current_geometry: geom.Rect = geom.Rect.empty(),
    /// Whether the client ever called set_window_geometry.
    geometry_set: bool = false,
    toplevel: ?*XdgToplevel = null,
    popup: ?*XdgPopup = null,
    events: struct {
        destroy: wire.Signal(*XdgSurface),
    },

    /// Send the xdg_surface.configure event and record the serial.
    fn sendConfigureEvent(xdg: *XdgSurface, serial: u32) void {
        xdg.resource.sendConfigure(serial);
        xdg.configure_serial = serial;
        xdg.configure_sent = true;
    }

    /// Handle xdg_surface.ack_configure. Only the most recent configure serial
    /// may be acked, and only once (matching the wlroots acked-serial list).
    fn ackConfigure(xdg: *XdgSurface, serial: u32) void {
        if (serial != xdg.configure_serial or (xdg.acked_serial != null and xdg.acked_serial.? == serial)) {
            xdg.resource.postError(.invalid_serial, "ack_configure: invalid or already-acked serial");
            return;
        }
        xdg.configured = true;
        xdg.acked_serial = serial;
        if (xdg.geometry_set) xdg.current_geometry = xdg.pending_geometry;
        log.info("surface configured serial={d} role={s}", xdg.io, xdg.log_cfg, log_tag, .{
            serial,
            @tagName(xdg.role),
        });
        // Mapping happens on the next commit with a buffer: the compositor's
        // commit pipeline performs the map transition and fires the map hook
        // and signal (see the file header).
    }

    /// Unmap the wl_surface. Used when a role object or the xdg_surface is
    /// destroyed; NULL-buffer commits unmap via the compositor's transition.
    fn unmapSurface(xdg: *XdgSurface) void {
        const surface = xdg.surface;
        if (!surface.mapped) return;
        surface.mapped = false;
        if (surface.role) |r| if (r.unmap) |f| f(surface);
        surface.events.unmap.emit(surface);
        // The next commit after a re-map must trigger a fresh configure.
        xdg.configure_sent = false;
        xdg.acked_serial = null;
        log.info("surface unmapped role={s}", xdg.io, xdg.log_cfg, log_tag, .{@tagName(xdg.role)});
    }
};

fn xdgSurfaceRequest(xdg_res: *server.xdg.Surface, request: server.xdg.Surface.Request, xdg: *XdgSurface) void {
    switch (request) {
        .destroy => xdgSurfaceDestroyRequest(xdg),
        .get_toplevel => |r| xdgSurfaceGetToplevel(xdg, r.id),
        .get_popup => |r| xdgSurfaceGetPopup(xdg, r),
        .set_window_geometry => |r| {
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
    t.events.destroy.init();
    res.setHandler(*XdgToplevel, toplevelRequest, toplevelDestroy, t);
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
    const positioner: *PositionerState = @ptrCast(@alignCast(r.positioner.getUserData()));
    if (!positioner.size_set or !positioner.anchor_rect_set) {
        // wlroots posts the wm_base invalid_positioner error on the
        // xdg_surface resource; the xdg_surface error enum has no code for it.
        xdg.resource.postError(
            @enumFromInt(@intFromEnum(server.xdg.WmBase.Error.invalid_positioner)),
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
        .parent = if (r.parent) |p|
            @as(*XdgSurface, @ptrCast(@alignCast(p.getUserData())))
        else
            null,
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    popup.events.destroy.init();
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
    shell.allocator.destroy(xdg);
}

// ---------------------------------------------------------------------------
// XdgToplevel.
// ---------------------------------------------------------------------------

pub const ToplevelState = struct {
    maximized: bool = false,
    fullscreen: bool = false,
    resizing: bool = false,
    activated: bool = false,
    /// Current/pending window geometry size (0 = client decides).
    width: i32 = 0,
    height: i32 = 0,
    min_size: geom.Size = .{ .w = 0, .h = 0 },
    max_size: geom.Size = .{ .w = 0, .h = 0 },
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
    /// Applied state. The compositor author reads this and updates it
    /// (e.g. `current.maximized = true`) before calling `configure`.
    current: ToplevelState = .{},
    /// Double-buffered client-requested state; applied by policy on commit.
    pending: ToplevelState = .{},
    /// Size from the last configure event sent.
    configured_size: geom.Size = .{ .w = 0, .h = 0 },
    events: struct {
        /// Client requested an interactive move (seat serials land in M3).
        request_move: wire.Signal(*XdgToplevel),
        /// Client requested an interactive resize.
        request_resize: wire.Signal(*XdgToplevel),
        /// Client requested maximize/unmaximize.
        request_maximize: wire.Signal(*XdgToplevel),
        /// Client requested fullscreen/unfullscreen.
        request_fullscreen: wire.Signal(*XdgToplevel),
        /// The role object was destroyed.
        destroy: wire.Signal(*XdgToplevel),
    },

    /// Send a configure event for this toplevel: xdg_toplevel.configure with
    /// the states derived from `current`, followed by xdg_surface.configure
    /// with the serial. `width`/`height` are window-geometry hints; 0 means
    /// "client decides".
    pub fn configure(t: *XdgToplevel, width: i32, height: i32) !void {
        const xdg = t.xdg_surface;
        const serial = xdg.shell.display.nextSerial();
        var buf: [4]u32 = undefined;
        const states = stateValues(&t.current, &buf);
        // libwayland marshals the array synchronously; a stack buffer is safe.
        var array: server.wl.Array = .{
            .size = states.len * @sizeOf(u32),
            .alloc = buf.len * @sizeOf(u32),
            .data = &buf,
        };
        t.resource.sendConfigure(width, height, &array);
        xdg.sendConfigureEvent(serial);
        t.configured_size = .{ .w = width, .h = height };
        log.info("toplevel configure serial={d} {d}x{d} states={d}", xdg.io, xdg.log_cfg, log_tag, .{
            serial, width, height, states.len,
        });
    }

    /// Ask the client to close the window (xdg_toplevel.close).
    pub fn sendClose(t: *XdgToplevel) void {
        t.resource.sendClose();
    }

    fn setTitle(t: *XdgToplevel, title: [*:0]const u8) void {
        const copy = t.allocator.dupe(u8, std.mem.span(title)) catch {
            t.resource.postNoMemory();
            return;
        };
        if (t.title) |old| t.allocator.free(old);
        t.title = copy;
    }

    fn setAppId(t: *XdgToplevel, app_id: [*:0]const u8) void {
        const copy = t.allocator.dupe(u8, std.mem.span(app_id)) catch {
            t.resource.postNoMemory();
            return;
        };
        if (t.app_id) |old| t.allocator.free(old);
        t.app_id = copy;
    }
};

/// Serialize the states set in `st` into `out` (at most 4 entries, in protocol
/// enum value order: maximized, fullscreen, resizing, activated).
fn stateValues(st: *const ToplevelState, out: *[4]u32) []u32 {
    var n: usize = 0;
    if (st.maximized) {
        out[n] = @intFromEnum(server.xdg.Toplevel.State.maximized);
        n += 1;
    }
    if (st.fullscreen) {
        out[n] = @intFromEnum(server.xdg.Toplevel.State.fullscreen);
        n += 1;
    }
    if (st.resizing) {
        out[n] = @intFromEnum(server.xdg.Toplevel.State.resizing);
        n += 1;
    }
    if (st.activated) {
        out[n] = @intFromEnum(server.xdg.Toplevel.State.activated);
        n += 1;
    }
    return out[0..n];
}

fn toplevelRequest(toplevel_res: *server.xdg.Toplevel, request: server.xdg.Toplevel.Request, t: *XdgToplevel) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do (runs toplevelDestroy).
        .destroy => t.resource.destroy(),
        .set_parent => log.debug("xdg_toplevel.set_parent ignored in M1", t.io, t.log_cfg, log_tag, .{}),
        .set_title => |r| t.setTitle(r.title),
        .set_app_id => |r| t.setAppId(r.app_id),
        .show_window_menu => log.debug(
            "xdg_toplevel.show_window_menu ignored (seat is M3)",
            t.io,
            t.log_cfg,
            log_tag,
            .{},
        ),
        .move => t.events.request_move.emit(t),
        .resize => t.events.request_resize.emit(t),
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
        .set_fullscreen => {
            t.pending.fullscreen = true;
            t.events.request_fullscreen.emit(t);
        },
        .unset_fullscreen => {
            t.pending.fullscreen = false;
            t.events.request_fullscreen.emit(t);
        },
        .set_minimized => log.debug("xdg_toplevel.set_minimized ignored in M1", t.io, t.log_cfg, log_tag, .{}),
    }
    _ = toplevel_res;
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
    xdg.unmapSurface();
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
    /// derived from the xdg_positioner at get_popup time.
    geometry: geom.Rect = geom.Rect.empty(),
    /// The xdg_surface this popup is attached to (null = layer-shell parent,
    /// M4).
    parent: ?*XdgSurface = null,
    events: struct {
        destroy: wire.Signal(*XdgPopup),
    },

    /// Send the initial/popup configure: xdg_popup.configure with the
    /// positioner-derived geometry, then xdg_surface.configure with the serial.
    pub fn configure(p: *XdgPopup) !void {
        const xdg = p.xdg_surface;
        const serial = xdg.shell.display.nextSerial();
        p.resource.sendConfigure(p.geometry.x, p.geometry.y, p.geometry.width, p.geometry.height);
        xdg.sendConfigureEvent(serial);
        log.info("popup configure serial={d} at ({d},{d}) {d}x{d}", xdg.io, xdg.log_cfg, log_tag, .{
            serial,
            p.geometry.x,
            p.geometry.y,
            p.geometry.width,
            p.geometry.height,
        });
    }

    /// Dismiss the popup from the compositor side (xdg_popup.popup_done).
    pub fn sendPopupDone(p: *XdgPopup) void {
        p.resource.sendPopupDone();
    }
};

fn popupRequest(popup_res: *server.xdg.Popup, request: server.xdg.Popup.Request, popup: *XdgPopup) void {
    _ = popup_res;
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do (runs popupDestroy).
        .destroy => popup.resource.destroy(),
        .grab => log.debug("xdg_popup.grab ignored (popup grabs are M3)", popup.io, popup.log_cfg, log_tag, .{}),
        .reposition => log.debug(
            "xdg_popup.reposition ignored (constraint adjustment is M4)",
            popup.io,
            popup.log_cfg,
            log_tag,
            .{},
        ),
    }
}

fn popupDestroy(popup_res: *server.xdg.Popup, popup: *XdgPopup) void {
    _ = popup_res;
    const shell = popup.xdg_surface.shell;
    if (std.mem.findScalar(*XdgPopup, shell.popups.items, popup)) |i| {
        _ = shell.popups.swapRemove(i);
    }
    popup.events.destroy.emit(popup);
    const xdg = popup.xdg_surface;
    xdg.popup = null;
    xdg.role = .none;
    xdg.unmapSurface();
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
    /// (M1: no constraint adjustment; matches xdg-shell's placement rules.)
    pub fn geometry(self: *const PositionerState) geom.Rect {
        var box: geom.Rect = .{
            .x = self.offset.x,
            .y = self.offset.y,
            .width = self.size.w,
            .height = self.size.h,
        };
        const ae = positionerEdges(@intFromEnum(self.anchor));
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
        const ge = positionerEdges(@intFromEnum(self.gravity));
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
};

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
        .set_anchor => |r| state.anchor = r.anchor,
        .set_gravity => |r| state.gravity = r.gravity,
        .set_constraint_adjustment => |r| state.constraint_adjustment = r.constraint_adjustment,
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

/// Recover the XdgSurface from the wl_surface in a role hook. The hooks only
/// fire while the surface's role is ours, so role_resource is the xdg_surface
/// wire resource and its user data is our XdgSurface.
fn xdgFromSurface(surface: *surface_mod.Surface) ?*XdgSurface {
    const role_resource = surface.role_resource orelse return null;
    return @ptrCast(@alignCast(role_resource.getUserData()));
}

/// Runs after the pending state has been applied, on every commit. Performs
/// the protocol checks that must happen at commit time.
fn xdgSurfaceClientCommit(surface: *surface_mod.Surface) void {
    const xdg = xdgFromSurface(surface) orelse return;
    // Protocol: attaching a buffer before the surface is configured is an error.
    if (!xdg.configured and surface.current.buffer != null) {
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
    };
}

/// Runs after the pending state has been applied, on every commit.
fn xdgSurfaceCommit(surface: *surface_mod.Surface) void {
    const xdg = xdgFromSurface(surface) orelse return;
    switch (xdg.role) {
        .none => {},
        .toplevel => if (xdg.toplevel) |t| {
            // Protocol: the initial configure is sent in reply to the client's
            // first (buffer-less) commit after the role object exists.
            if (!xdg.configure_sent) {
                t.configure(t.current.width, t.current.height) catch {
                    t.resource.postNoMemory();
                };
            }
        },
        .popup => if (xdg.popup) |p| {
            if (!xdg.configure_sent) {
                p.configure() catch p.resource.postNoMemory();
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
    .unmap = null,
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
    try std.testing.expectEqual(EdgeSet{}, positionerEdges(@intFromEnum(server.xdg.Positioner.Anchor.none)));
    try std.testing.expectEqual(
        EdgeSet{ .top = true },
        positionerEdges(@intFromEnum(server.xdg.Positioner.Anchor.top)),
    );
    try std.testing.expectEqual(
        EdgeSet{ .top = true, .left = true },
        positionerEdges(@intFromEnum(server.xdg.Positioner.Anchor.top_left)),
    );
    try std.testing.expectEqual(
        EdgeSet{ .bottom = true, .right = true },
        positionerEdges(@intFromEnum(server.xdg.Positioner.Gravity.bottom_right)),
    );
}

test "toplevel state values" {
    var buf: [4]u32 = undefined;
    const empty = stateValues(&.{}, &buf);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const st: ToplevelState = .{ .maximized = true, .activated = true };
    const vals = stateValues(&st, &buf);
    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqual(@as(u32, 1), vals[0]); // maximized
    try std.testing.expectEqual(@as(u32, 4), vals[1]); // activated
}

// --- socketpair roundtrip harness (no filesystem server socket) ------------

const posix = std.posix;

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    wm_base_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "xdg_wm_base")) {
                    data.wm_base_name = g.name;
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
    states: [4]u32 = [_]u32{0} ** 4,

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
            .configure_bounds => {},
            .wm_capabilities => {},
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
            .popup_done => {},
            .repositioned => {},
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

const NewPopupCapture = struct {
    count: usize = 0,
    listener: wire.Listener(*XdgPopup),

    fn notify(listener: *wire.Listener(*XdgPopup), popup: *XdgPopup) void {
        _ = popup;
        @as(*NewPopupCapture, @fieldParentPtr("listener", listener)).count += 1;
    }
};

/// A full compositor + shell + in-memory client, for wire roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    shell: ?*XdgShell = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wm_base: ?*client.xdg.WmBase = null,

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
        ts.shell = try XdgShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
        errdefer if (ts.shell) |s| s.deinit();

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
        if (capture.compositor_name == null or capture.wm_base_name == null) return error.GlobalMissing;

        // Round 2: bind wl_compositor and xdg_wm_base.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wm_base = try registry.bind(capture.wm_base_name.?, client.xdg.WmBase, 7);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.shell) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Client flush -> server event loop dispatch -> server flush -> client
    /// dispatch. Drives one roundtrip without blocking: the client only
    /// dispatches when the server actually wrote events to the socket.
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
    // configure (0x0 = client decides, no states).
    wl_surface.commit();
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), tl_events.configure_count);
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
    try std.testing.expectEqual(@as(usize, 0), tl_events.states_len);
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

    // Compositor side: configure a new size with the maximized state.
    t.current.maximized = true;
    try t.configure(800, 600);
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 2), tl_events.configure_count);
    try std.testing.expectEqual(@as(i32, 800), tl_events.width);
    try std.testing.expectEqual(@as(i32, 600), tl_events.height);
    try std.testing.expectEqual(@as(usize, 1), tl_events.states_len);
    try std.testing.expectEqual(@as(u32, 1), tl_events.states[0]); // maximized
    try std.testing.expectEqual(geom.Size{ .w = 800, .h = 600 }, t.configured_size);
    const serial2 = xs_events.serial;
    try std.testing.expect(serial2 != serial1);

    // Ack the second configure (not the first: a stale ack is an error).
    xdg_surface.ackConfigure(serial2);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(serial2, xdg.acked_serial.?);

    // Acking an unknown serial is a protocol error (invalid_serial = 4); the
    // server destroys the client, so pump fails with ClientDispatchFailed.
    xdg_surface.ackConfigure(12345);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    // The client library records the protocol error code (invalid_serial = 4).
    try std.testing.expectEqual(@as(c_int, 4), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "xdg popup configure and positioner errors" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var new_popup: NewPopupCapture = .{
        .listener = wire.Listener(*XdgPopup).init(NewPopupCapture.notify),
    };
    ts.shell.?.events.new_popup.add(&new_popup.listener);

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
    const popup = try xdg_surface.getPopup(null, positioner);
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
    popup.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.shell.?.popups.items.len);
    try std.testing.expect(p.xdg_surface.role == .none);

    // An incomplete positioner (size never set) is rejected with the wm_base
    // invalid_positioner error (code 5) on the xdg_surface resource.
    const wl_surface2 = try ts.wl_compositor.?.createSurface();
    const xdg_surface2 = try ts.wm_base.?.getXdgSurface(wl_surface2);
    const bad_positioner = try ts.wm_base.?.createPositioner();
    bad_positioner.setAnchorRect(0, 0, 10, 10);
    _ = try xdg_surface2.getPopup(null, bad_positioner);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    // invalid_positioner (wm_base error code 5).
    try std.testing.expectEqual(@as(c_int, 5), wl_display_get_protocol_error(ts.c_display.?, null, null));
}
