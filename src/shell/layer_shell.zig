//! zwlr_layer_shell_v1 (v5): the layer-shell global plus the LayerSurface
//! state machine (protocols/wlroots/wlr-layer-shell-unstable-v1.xml).
//!
//! State machine (wlroots types/wlr_layer_shell_v1.c semantics; the initial
//! configure is self-contained here — wlroots leaves it to the compositor):
//! - get_layer_surface assigns the "zwlr_layer_surface_v1" role. A role
//!   conflict posts the shell error `role` (0) on the shell resource; an
//!   invalid layer posts `invalid_layer` (1).
//! - The FIRST commit must be buffer-less. A commit that attaches a buffer
//!   while the surface was never configured posts `already_constructed` (2,
//!   shell error enum — the surface enum has no code for it).
//! - The first buffer-less commit makes the compositor send the initial
//!   configure(serial, desired_width, desired_height). The client must ack
//!   it (ack_configure with a serial that was never sent posts
//!   `invalid_surface_state` (0)) before attaching a buffer; after the ack,
//!   a buffer commit maps the surface.
//! - A NULL-buffer commit unmaps the surface and RESETS it to the state it
//!   had right after get_layer_surface: a fresh buffer-less commit +
//!   configure + ack are required to map again (spec: reset).
//! - destroy sends `closed` first, then destroys the object (requests after
//!   that are gone with the resource).
//!
//! The layer state (size, anchor, exclusive zone, margin, keyboard
//! interactivity, layer, exclusive edge) is double-buffered: requests write
//! `pending`, wl_surface.commit applies it to `current`.
//!
//! Out of scope (compositor policy, decided by main.zig consumers):
//! z-ordering/layout of layers against an output, keyboard-focus policy,
//! xdg_popup parenting (get_popup is rejected with wlroots' raw -1 error;
//! parenting is M4 for the popup module).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const role_mod = @import("../compositor/role.zig");
const surface_mod = @import("../compositor/surface.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const display_mod = @import("../core/display.zig");

const log_tag = "layer";

/// Anchor bit values (zwlr_layer_surface_v1.anchor).
const anchor_top: u32 = 1;
const anchor_bottom: u32 = 2;
const anchor_left: u32 = 4;
const anchor_right: u32 = 8;
/// All four valid anchor bits.
const anchor_mask: u32 = anchor_top | anchor_bottom | anchor_left | anchor_right;

const Layer = server.zwlr.LayerShellV1.Layer;

fn layerIsValid(value: c_int) bool {
    return value >= @intFromEnum(Layer.background) and value <= @intFromEnum(Layer.overlay);
}

// ---------------------------------------------------------------------------
// LayerShell: the zwlr_layer_shell_v1 global.
// ---------------------------------------------------------------------------

pub const LayerShell = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    compositor: *compositor_mod.Compositor,
    /// The zwlr_layer_shell_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// All live layer surfaces (role objects), in creation order.
    layer_surfaces: std.ArrayList(*LayerSurface),
    events: struct {
        /// A new layer surface role object was created.
        new_layer_surface: wire.Signal(*LayerSurface),
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        compositor: *compositor_mod.Compositor,
    ) !*LayerShell {
        const shell = try allocator.create(LayerShell);
        errdefer allocator.destroy(shell);
        shell.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .compositor = compositor,
            .layer_surfaces = .empty,
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        errdefer shell.layer_surfaces.deinit(allocator);
        shell.events.new_layer_surface.init();

        // Register zwlr_layer_shell_v1 at the maximum version we implement.
        shell.global = try display.addGlobal(
            server.zwlr.LayerShellV1,
            *LayerShell,
            layerShellBind,
            server.zwlr.LayerShellV1.generated_version,
            shell,
        );
        return shell;
    }

    pub fn deinit(self: *LayerShell) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the wire resources cascades through their destroy
        // handlers, which remove entries from the list and free the objects.
        while (self.layer_surfaces.items.len > 0) self.layer_surfaces.items[0].resource.destroy();
        self.layer_surfaces.deinit(allocator);
        // The layer_shell global itself is owned by the display's registry.
        allocator.destroy(self);
    }
};

fn layerShellBind(client_wire: *wire.Client, shell: *LayerShell, version: u32, id: u32) void {
    const layer_shell = server.zwlr.LayerShellV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    layer_shell.setHandler(*LayerShell, layerShellRequest, null, shell);
}

fn layerShellRequest(
    layer_shell: *server.zwlr.LayerShellV1,
    request: server.zwlr.LayerShellV1.Request,
    shell: *LayerShell,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => layer_shell.destroy(),
        .get_layer_surface => |r| layerShellGetLayerSurface(layer_shell, shell, r),
    }
}

fn layerShellGetLayerSurface(layer_shell: *server.zwlr.LayerShellV1, shell: *LayerShell, r: anytype) void {
    // Validate the layer before creating anything (wlroots order).
    if (!layerIsValid(@intFromEnum(r.layer))) {
        layer_shell.postError(.invalid_layer, "invalid layer value");
        return;
    }
    // The wl_surface resource's user data is the compositor's Surface.
    const surface: *surface_mod.Surface = @ptrCast(@alignCast(r.surface.getUserData()));
    const res = server.zwlr.LayerSurfaceV1.create(layer_shell.getClient(), layer_shell.getVersion(), r.id) catch {
        layer_shell.postNoMemory();
        return;
    };
    const ls = shell.allocator.create(LayerSurface) catch {
        res.destroy();
        layer_shell.postNoMemory();
        return;
    };
    ls.* = .{
        .allocator = shell.allocator,
        .io = shell.io,
        .log_cfg = shell.log_cfg,
        .shell = shell,
        .resource = res,
        .shell_resource = layer_shell,
        .surface = surface,
        .output = r.output,
        .namespace = null,
        // The initial layer applies immediately (wlroots sets both).
        .pending = .{ .layer = r.layer },
        .current = .{ .layer = r.layer },
        // SAFETY: initialized via .init() immediately after construction, before any emit.
        .events = undefined,
    };
    ls.events.destroy.init();
    res.setHandler(*LayerSurface, layerSurfaceRequest, layerSurfaceDestroy, ls);
    ls.namespace = shell.allocator.dupe(u8, std.mem.span(r.namespace)) catch {
        res.destroy();
        layer_shell.postNoMemory();
        return;
    };
    // Assigns the "zwlr_layer_surface_v1" role. Any pre-existing role is a
    // conflict: post the shell error enum's `role` (0) on the shell resource
    // (the error's XML home) and drop the new object.
    if (surface.role != null) {
        layer_shell.postError(.role, "wl_surface already has a role");
        res.destroy();
        return;
    }
    role_mod.assignRole(surface, &layer_surface_role, @as(?*wire.Resource, @ptrCast(res))) catch unreachable;
    shell.layer_surfaces.append(shell.allocator, ls) catch {
        // OOM: drop the role object (its destroy handler detaches the role
        // and frees `ls`).
        layer_shell.postNoMemory();
        res.destroy();
        return;
    };
    shell.events.new_layer_surface.emit(ls);
    log.info("new layer surface on wl_surface {*} layer={d} namespace={s}", shell.io, shell.log_cfg, log_tag, .{
        surface,
        @intFromEnum(ls.current.layer),
        ls.namespace.?,
    });
}

// ---------------------------------------------------------------------------
// LayerSurface: per-wl_surface layer state.
// ---------------------------------------------------------------------------

const Margin = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
};

/// Double-buffered layer surface state (wlroots wlr_layer_surface_v1_state).
const LayerState = struct {
    /// Desired size from set_size (0 = the compositor assigns that axis).
    desired_width: u32 = 0,
    desired_height: u32 = 0,
    /// Anchor bitfield (top=1, bottom=2, left=4, right=8).
    anchor: u32 = 0,
    /// Exclusive zone from set_exclusive_zone.
    exclusive_zone: i32 = 0,
    /// Explicit exclusive edge from set_exclusive_edge (0 = unset).
    exclusive_edge: u32 = 0,
    /// Margins from set_margin.
    margin: Margin = .{},
    /// Keyboard interactivity (0/1, or 2 = on_demand on v4+).
    keyboard_interactive: u32 = 0,
    /// The layer this surface is rendered in.
    layer: Layer = .background,
};

pub const LayerSurface = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    shell: *LayerShell,
    resource: *server.zwlr.LayerSurfaceV1,
    /// The zwlr_layer_shell_v1 resource of the creating client (same
    /// client); hosts the shell error enum's invalid_layer error.
    shell_resource: *server.zwlr.LayerShellV1,
    surface: *surface_mod.Surface,
    /// The output the client named (null = the compositor decides).
    output: ?*server.wl.Output = null,
    /// Namespace string from get_layer_surface (owned; UTF-8).
    namespace: ?[]const u8 = null,
    /// True once the client acked a configure; permits attaching buffers.
    configured: bool = false,
    /// A configure has been sent since the last reset. A buffer-less commit
    /// with it false triggers a fresh configure; with it true it unmaps.
    configure_sent: bool = false,
    /// Serial of the last configure event sent.
    configure_serial: u32 = 0,
    /// Every configure serial sent since the last (re)map, in order, for
    /// ack_configure validation (wlroots configure-list semantics).
    sent_serials: std.ArrayList(u32) = .empty,
    /// Double-buffered layer state; requests write `pending`,
    /// wl_surface.commit applies it to `current`.
    pending: LayerState = .{},
    current: LayerState = .{},
    /// `closed` was sent; the object is inert.
    closed: bool = false,
    events: struct {
        destroy: wire.Signal(*LayerSurface),
    },

    /// Send layer_surface.configure with the desired size (0,0 = client
    /// decides) and record the serial for ack_configure validation.
    fn sendConfigure(ls: *LayerSurface) void {
        const serial = ls.shell.display.nextSerial();
        ls.resource.sendConfigure(serial, ls.current.desired_width, ls.current.desired_height);
        ls.configure_serial = serial;
        ls.configure_sent = true;
        ls.sent_serials.append(ls.allocator, serial) catch {
            ls.resource.postNoMemory();
        };
        log.info("layer surface configure serial={d} {d}x{d}", ls.io, ls.log_cfg, log_tag, .{
            serial,
            ls.current.desired_width,
            ls.current.desired_height,
        });
    }

    /// Handle layer_surface.ack_configure. The serial must be one we sent
    /// (present in the sent list); acking removes it and every older serial
    /// (wlroots configure-list semantics: only the last configure matters).
    fn ackConfigure(ls: *LayerSurface, serial: u32) void {
        if (std.mem.indexOfScalar(u32, ls.sent_serials.items, serial) == null) {
            ls.resource.postError(.invalid_surface_state, "wrong configure serial");
            return;
        }
        while (ls.sent_serials.items.len > 0 and ls.sent_serials.items[0] <= serial) {
            _ = ls.sent_serials.orderedRemove(0);
        }
        ls.configured = true;
        log.info("layer surface configured serial={d}", ls.io, ls.log_cfg, log_tag, .{serial});
    }

    /// Reset to the initial (post-get_layer_surface) state: a fresh
    /// buffer-less commit + configure + ack are required to map again.
    fn reset(ls: *LayerSurface) void {
        ls.configured = false;
        ls.configure_sent = false;
        ls.sent_serials.clearRetainingCapacity();
    }

    /// Unmap the wl_surface (no-op when already unmapped). The compositor's
    /// commit pipeline performs the map/unmap transition for NULL-buffer
    /// commits; this is the destroy-path equivalent (xdg.zig pattern).
    fn unmapSurface(ls: *LayerSurface) void {
        const surface = ls.surface;
        if (!surface.mapped) return;
        surface.mapped = false;
        if (surface.role) |r| if (r.unmap) |f| f(surface);
        surface.events.unmap.emit(surface);
    }

    /// Destroy the layer surface from the compositor side: send `closed`
    /// first, then destroy the wire resource (cascades through
    /// layerSurfaceDestroy). Idempotent.
    pub fn close(ls: *LayerSurface) void {
        if (ls.closed) return;
        ls.closed = true;
        ls.resource.sendClosed();
        ls.resource.destroy();
    }

    /// The single output edge this surface occupies with its exclusive zone,
    /// or null. Deduced from the anchors — a single edge, or an edge plus
    /// both perpendicular edges; an explicit set_exclusive_edge overrides
    /// the deduction (wlroots wlr_layer_surface_v1_get_exclusive_edge). A
    /// non-positive zone occupies no edge.
    pub fn exclusiveEdge(ls: *const LayerSurface) ?Edge {
        return deducedEdge(ls.current.exclusive_zone, ls.current.anchor, ls.current.exclusive_edge);
    }

    /// Handle set_keyboard_interactivity. v4+ validates the enum value;
    /// v3 and older coerce any nonzero value to exclusive (on_demand does
    /// not exist there; wlroots: pending.keyboard_interactive = !!value).
    fn setKeyboardInteractivity(ls: *LayerSurface, value: server.zwlr.LayerSurfaceV1.KeyboardInteractivity) void {
        const v: c_int = @intFromEnum(value);
        if (ls.resource.getVersion() < 4) {
            ls.pending.keyboard_interactive = if (v != 0) 1 else 0;
            return;
        }
        if (v < 0 or v > @intFromEnum(server.zwlr.LayerSurfaceV1.KeyboardInteractivity.on_demand)) {
            ls.resource.postError(.invalid_keyboard_interactivity, "wrong keyboard interactivity value");
            return;
        }
        ls.pending.keyboard_interactive = @intCast(v);
    }

    /// Handle get_popup. xdg_popup parenting from layer surfaces is out of
    /// scope (M4 for the popup module); the XML requires a popup with a NULL
    /// parent and get_popup before its initial commit. Reject with wlroots'
    /// raw -1 implementation error and do not create anything.
    fn getPopup(ls: *LayerSurface, popup: *server.xdg.Popup) void {
        _ = popup;
        const raw: *wire.Resource = @ptrCast(ls.resource);
        raw.postError(@bitCast(@as(i32, -1)), "xdg_popup on a layer surface is not supported");
    }
};

/// The edge a layer surface's exclusive zone applies to.
pub const Edge = enum { top, bottom, left, right };

/// Pure exclusive-edge deduction (see LayerSurface.exclusiveEdge).
fn deducedEdge(zone: i32, anchor: u32, exclusive_edge: u32) ?Edge {
    if (zone <= 0) return null;
    var a = anchor;
    if (exclusive_edge != 0) a = exclusive_edge;
    const lr = anchor_left | anchor_right;
    const tb = anchor_top | anchor_bottom;
    if (a == anchor_top or a == lr | anchor_top) return .top;
    if (a == anchor_bottom or a == lr | anchor_bottom) return .bottom;
    if (a == anchor_left or a == tb | anchor_left) return .left;
    if (a == anchor_right or a == tb | anchor_right) return .right;
    return null;
}

fn layerSurfaceRequest(
    ls_res: *server.zwlr.LayerSurfaceV1,
    request: server.zwlr.LayerSurfaceV1.Request,
    ls: *LayerSurface,
) void {
    _ = ls_res;
    switch (request) {
        .destroy => ls.close(),
        .set_size => |r| {
            ls.pending.desired_width = r.width;
            ls.pending.desired_height = r.height;
        },
        .set_anchor => |r| {
            const bits: u32 = @bitCast(r.anchor);
            if ((bits & ~anchor_mask) != 0) {
                ls.resource.postError(.invalid_anchor, "invalid anchor bitfield");
                return;
            }
            ls.pending.anchor = bits;
        },
        .set_exclusive_zone => |r| ls.pending.exclusive_zone = r.zone,
        .set_margin => |r| {
            ls.pending.margin = .{ .top = r.top, .right = r.right, .bottom = r.bottom, .left = r.left };
        },
        .set_keyboard_interactivity => |r| ls.setKeyboardInteractivity(r.keyboard_interactivity),
        .get_popup => |r| ls.getPopup(r.popup),
        .ack_configure => |r| ls.ackConfigure(r.serial),
        .set_layer => |r| {
            if (!layerIsValid(@intFromEnum(r.layer))) {
                // invalid_layer lives on the shell error enum; post it on the
                // shell resource (its XML home). wlroots posts on the surface
                // resource instead (types/wlr_layer_shell_v1.c XXX comment).
                ls.shell_resource.postError(.invalid_layer, "invalid layer value");
                return;
            }
            ls.pending.layer = r.layer;
        },
        .set_exclusive_edge => |r| {
            const bits: u32 = @bitCast(r.edge);
            // The edge must be a single anchor bit: an edge "the surface is
            // anchored to" (XML) — one bit disambiguates a corner.
            if (bits == 0 or (bits & (bits - 1)) != 0 or (bits & ~anchor_mask) != 0) {
                ls.resource.postError(.invalid_exclusive_edge, "invalid exclusive edge");
                return;
            }
            ls.pending.exclusive_edge = bits;
        },
    }
}

/// The wire resource is gone (client destroy request, disconnect, or the
/// wl_surface going away via the role destroy hook). Root of the teardown.
fn layerSurfaceDestroy(res: *server.zwlr.LayerSurfaceV1, ls: *LayerSurface) void {
    _ = res;
    const shell = ls.shell;
    const surface = ls.surface;
    if (surface.role_resource == @as(?*wire.Resource, @ptrCast(ls.resource))) {
        // Detach the role so the commit pipeline never calls our hooks again
        // (the client may keep the wl_surface alive for a new role).
        surface.role = null;
        surface.role_resource = null;
    }
    ls.unmapSurface();
    ls.events.destroy.emit(ls);
    if (std.mem.findScalar(*LayerSurface, shell.layer_surfaces.items, ls)) |i| {
        _ = shell.layer_surfaces.swapRemove(i);
    }
    ls.sent_serials.deinit(shell.allocator);
    if (ls.namespace) |ns| shell.allocator.free(ns);
    shell.allocator.destroy(ls);
}

// ---------------------------------------------------------------------------
// The "zwlr_layer_surface_v1" wl_surface role implementation.
// ---------------------------------------------------------------------------

/// Recover the LayerSurface from the wl_surface in a role hook. The hooks
/// only fire while the surface's role is ours, so role_resource is the
/// layer surface wire resource and its user data is our LayerSurface.
fn layerFromSurface(surface: *surface_mod.Surface) ?*LayerSurface {
    const role_resource = surface.role_resource orelse return null;
    return @ptrCast(@alignCast(role_resource.getUserData()));
}

/// Runs after the pending state has been applied, on every commit. Applies
/// the double-buffered layer state and performs the commit-time protocol
/// checks (wlroots layer_surface_role_client_commit order).
fn layerSurfaceClientCommit(surface: *surface_mod.Surface) void {
    const ls = layerFromSurface(surface) orelse return;
    ls.current = ls.pending;

    // Protocol: attaching a buffer before the surface is ever configured is
    // an error. already_constructed is in the shell error enum (the surface
    // enum has no code for it); wlroots posts it on the layer surface.
    if (!ls.configured and surface.current.buffer != null) {
        const raw: *wire.Resource = @ptrCast(ls.resource);
        raw.postError(
            @intFromEnum(server.zwlr.LayerShellV1.Error.already_constructed),
            "layer_surface has a buffer before being configured",
        );
        return;
    }
    // Protocol: a 0 width requires both horizontal anchors, a 0 height both
    // vertical ones ("You must set your anchor to opposite edges in the
    // dimensions you omit").
    const horiz = anchor_left | anchor_right;
    const vert = anchor_top | anchor_bottom;
    if (ls.current.desired_width == 0 and (ls.current.anchor & horiz) != horiz) {
        ls.resource.postError(.invalid_size, "width 0 requested without left and right anchors");
        return;
    }
    if (ls.current.desired_height == 0 and (ls.current.anchor & vert) != vert) {
        ls.resource.postError(.invalid_size, "height 0 requested without top and bottom anchors");
        return;
    }
    // Protocol: the exclusive edge must be part of the anchor at commit.
    const edge = ls.current.exclusive_edge;
    if (edge != 0 and (ls.current.anchor & edge) != edge) {
        ls.resource.postError(.invalid_exclusive_edge, "exclusive edge is invalid given the surface anchors");
        return;
    }
}

/// Runs after client_commit, on every commit. The first buffer-less commit
/// triggers the configure the client must ack; a later NULL-buffer commit
/// unmaps and resets the surface to its initial state (the map/unmap
/// transition itself is performed by the compositor's commit pipeline).
fn layerSurfaceCommit(surface: *surface_mod.Surface) void {
    const ls = layerFromSurface(surface) orelse return;
    if (surface.current.buffer == null) {
        if (!ls.configure_sent) {
            ls.sendConfigure();
        } else {
            ls.reset();
            log.info("layer surface reset (unmapped)", ls.io, ls.log_cfg, log_tag, .{});
        }
    }
}

/// The wl_surface is going away; tear down the layer surface (cascades
/// through layerSurfaceDestroy).
fn layerSurfaceRoleDestroy(surface: *surface_mod.Surface) void {
    const ls = layerFromSurface(surface) orelse return;
    ls.resource.destroy();
}

const layer_surface_role: role_mod.SurfaceRole = .{
    .name = "zwlr_layer_surface_v1",
    .client_commit = layerSurfaceClientCommit,
    .commit = layerSurfaceCommit,
    .map = null,
    .unmap = null,
    .destroy = layerSurfaceRoleDestroy,
};

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "layer exclusive edge deduction" {
    // Zone <= 0 occupies no edge, even with anchors.
    try std.testing.expectEqual(@as(?Edge, null), deducedEdge(0, anchor_top, 0));
    try std.testing.expectEqual(@as(?Edge, null), deducedEdge(-1, anchor_top, 0));

    // Single edge.
    try std.testing.expectEqual(@as(?Edge, .top), deducedEdge(10, anchor_top, 0));
    // Edge plus both perpendicular edges.
    try std.testing.expectEqual(@as(?Edge, .bottom), deducedEdge(10, anchor_left | anchor_right | anchor_bottom, 0));
    // Corner: no single edge deducible.
    try std.testing.expectEqual(@as(?Edge, null), deducedEdge(10, anchor_top | anchor_left, 0));
    // Explicit exclusive edge overrides the corner deduction.
    try std.testing.expectEqual(@as(?Edge, .top), deducedEdge(10, anchor_top | anchor_left, anchor_top));
    // Zone <= 0 ignores even an explicit exclusive edge (wlroots order).
    try std.testing.expectEqual(@as(?Edge, null), deducedEdge(0, anchor_top | anchor_left, anchor_top));
}

// --- socketpair roundtrip harness (no filesystem server socket) ------------

const posix = std.posix;

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    layer_shell_name: ?u32 = null,
    shm_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "zwlr_layer_shell_v1")) {
                    data.layer_shell_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_shm")) {
                    data.shm_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

const LayerSurfaceEvents = struct {
    configure_count: usize = 0,
    serial: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    closed_count: usize = 0,

    fn listener(
        layer_surface: *client.zwlr.LayerSurfaceV1,
        event: client.zwlr.LayerSurfaceV1.Event,
        data: *LayerSurfaceEvents,
    ) void {
        _ = layer_surface;
        switch (event) {
            .configure => |c| {
                data.configure_count += 1;
                data.serial = c.serial;
                data.width = c.width;
                data.height = c.height;
            },
            .closed => data.closed_count += 1,
        }
    }
};

const NewLayerSurfaceCapture = struct {
    count: usize = 0,
    listener: wire.Listener(*LayerSurface),

    fn notify(listener: *wire.Listener(*LayerSurface), layer_surface: *LayerSurface) void {
        _ = layer_surface;
        @as(*NewLayerSurfaceCapture, @fieldParentPtr("listener", listener)).count += 1;
    }
};

/// A full compositor + layer shell + in-memory client, for wire roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    shell: ?*LayerShell = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_shm: ?*client.wl.Shm = null,
    layer_shell: ?*client.zwlr.LayerShellV1 = null,

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
        // wl_shm (internal libwayland global) so test clients can attach
        // real buffers; buffers resolve through the untracked stateless path.
        try ts.display.?.initShm();
        ts.shell = try LayerShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
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
        if (capture.compositor_name == null or capture.layer_shell_name == null or capture.shm_name == null) {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor, wl_shm and zwlr_layer_shell_v1.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wl_shm = try registry.bind(capture.shm_name.?, client.wl.Shm, 1);
        ts.layer_shell = try registry.bind(capture.layer_shell_name.?, client.zwlr.LayerShellV1, 5);
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

/// Create a real 64x64 ARGB8888 shm buffer for the test client.
fn createShmBuffer(ts: *TestServer) !*client.wl.Buffer {
    const size: usize = 64 * 64 * 4;
    const fd = try posix.memfd_create("layer-test-buffer", std.os.linux.MFD.CLOEXEC);
    defer _ = std.os.linux.close(fd);
    {
        const rc = std.os.linux.ftruncate(fd, @intCast(size));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.FtruncateFailed;
    }
    // The server maps the fd itself; the client-side mapping is only needed
    // to satisfy the pool creation and can go immediately after.
    const pixels = try posix.mmap(null, size, posix.PROT{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    posix.munmap(pixels);
    const pool = try ts.wl_shm.?.createPool(fd, @intCast(size));
    return pool.createBuffer(0, 64, 64, 64 * 4, .argb8888);
}

test "layer surface: buffer before first configure is already_constructed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    // The proxy is intentionally discarded: the error kills the client
    // before any further request on it could be sent.
    _ = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.shell.?.layer_surfaces.items.len);
    const ls = ts.shell.?.layer_surfaces.items[0];
    try std.testing.expect(!ls.configured);

    // A buffer commit before any configure: already_constructed (2).
    const buffer = try createShmBuffer(ts);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 2), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "layer surface: zero size without opposing anchors is invalid_size" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    try ts.pump();

    // Width 0 without left|right anchors at commit: invalid_size (1).
    layer_surface.setSize(0, 100);
    wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "layer surface: acking a never-sent serial is invalid_surface_state" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    try ts.pump();

    layer_surface.ackConfigure(12345);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "layer surface: invalid anchor bitfield is invalid_anchor" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    try ts.pump();

    // Bit 4 is outside {top,bottom,left,right}: invalid_anchor (2).
    layer_surface.setAnchor(@bitCast(@as(u32, 0x10)));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 2), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "layer surface: invalid keyboard interactivity is invalid_keyboard_interactivity" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    try ts.pump();

    // on_demand (2) is the highest valid value on v4+; 3 is invalid (3).
    layer_surface.setKeyboardInteractivity(@enumFromInt(3));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 3), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "layer surface: bufferless commit, configure, ack, buffer commit maps" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var new_surface: NewLayerSurfaceCapture = .{
        .listener = wire.Listener(*LayerSurface).init(NewLayerSurfaceCapture.notify),
    };
    ts.shell.?.events.new_layer_surface.add(&new_surface.listener);

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .overlay, "test");
    var ls_events: LayerSurfaceEvents = .{};
    layer_surface.setListener(*LayerSurfaceEvents, LayerSurfaceEvents.listener, &ls_events);
    // 0x0 size with all four anchors satisfies the zero-dimension rules
    // (wlroots checks desired size vs opposing anchors on every commit).
    layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), new_surface.count);
    try std.testing.expectEqual(@as(usize, 1), ts.shell.?.layer_surfaces.items.len);
    const ls = ts.shell.?.layer_surfaces.items[0];
    try std.testing.expectEqual(Layer.overlay, ls.current.layer);
    try std.testing.expectEqualStrings("test", ls.namespace.?);
    try std.testing.expect(!ls.configured);

    // First commit is buffer-less: the compositor answers with the initial
    // configure (0x0 = client decides both dimensions).
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ls_events.configure_count);
    try std.testing.expectEqual(@as(u32, 0), ls_events.width);
    try std.testing.expectEqual(@as(u32, 0), ls_events.height);
    const serial = ls_events.serial;
    try std.testing.expectEqual(serial, ls.configure_serial);
    try std.testing.expect(!ls.configured);

    // Ack the configure, then a buffer commit maps the surface.
    layer_surface.ackConfigure(serial);
    const buffer = try createShmBuffer(ts);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(ls.configured);
    try std.testing.expect(ls.surface.mapped);
    try std.testing.expectEqual(@as(usize, 0), ls.sent_serials.items.len);
}

test "layer surface: NULL commit unmaps and resets; remap needs a fresh configure" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    var ls_events: LayerSurfaceEvents = .{};
    layer_surface.setListener(*LayerSurfaceEvents, LayerSurfaceEvents.listener, &ls_events);
    // 0x0 size with all four anchors satisfies the zero-dimension rules.
    layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
    try ts.pump();
    const ls = ts.shell.?.layer_surfaces.items[0];

    // Map normally.
    wl_surface.commit();
    try ts.pump();
    const serial1 = ls_events.serial;
    layer_surface.ackConfigure(serial1);
    const buffer = try createShmBuffer(ts);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(ls.surface.mapped);

    // NULL-buffer commit: unmap + reset to the initial state.
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(!ls.surface.mapped);
    try std.testing.expect(!ls.configured);
    try std.testing.expect(!ls.configure_sent);
    try std.testing.expectEqual(@as(usize, 0), ls.sent_serials.items.len);

    // Re-map requires a fresh buffer-less commit + configure + ack.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), ls_events.configure_count);
    const serial2 = ls_events.serial;
    try std.testing.expect(serial2 != serial1);
    layer_surface.ackConfigure(serial2);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(ls.surface.mapped);
    try std.testing.expect(ls.configured);

    // The reset is real: after another unmap, a buffer commit without a
    // fresh configure is already_constructed again.
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(!ls.surface.mapped);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 2), wl_display_get_protocol_error(ts.c_display.?, null, null));
}
