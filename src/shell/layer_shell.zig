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
//! - destroy/close sends `closed`, then makes the wire resource inert
//!   (later client requests are silent no-ops; the client's own destroy
//!   destroys the wire resource — wlroots wlr_layer_surface_v1_destroy:
//!   closed first, then layer_surface_destroy inerts the resource) and
//!   tears the object down; the resource stays alive until the client
//!   disconnects.
//!
//! The layer state (size, anchor, exclusive zone, margin, keyboard
//! interactivity, layer, exclusive edge) is double-buffered: requests write
//! `pending`, wl_surface.commit applies it to `current`.
//!
//! Out of scope (compositor policy, decided by main.zig consumers):
//! z-ordering/layout of layers against an output (incl. the popup offset
//! application), keyboard-focus policy. get_popup parenting is implemented
//! (L1): the xdg_popup keeps its NULL xdg parent and is parented to this
//! layer surface (XdgPopup.layer_parent = the layer wl_surface, wlroots
//! parity), tracked here so unmap/destroy dismiss it with popup_done.

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
// Imported for get_popup: the xdg_popup role object the client created with
// a NULL parent. xdg.zig does not import this module (no cycle).
const xdg_mod = @import("xdg.zig");

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
        /// An xdg_popup was parented to a layer surface via get_popup. The
        /// popup is fully parented when the signal fires (layer_parent set,
        /// list insert + destroy listener attached) — listeners may touch
        /// it safely (wlroots: insert into parent->popups then
        /// wl_signal_emit_mutable(&parent->events.new_popup, popup),
        /// wlr_layer_shell_v1.c:256-257). Distinct from the xdg-shell
        /// shell.events.new_popup signal (different type, different path).
        new_popup: wire.Signal(*xdg_mod.XdgPopup),
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
        shell.events.new_popup.init();

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
    ls.events.initial_commit.init();
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
    /// Size of the last acked configure (wlroots pending.actual_width/height,
    /// set at ack_configure from the configure list entry, applied to
    /// `current` at the next commit). Lets the compositor compare what it
    /// assigned vs what the client committed against (L6).
    actual_width: u32 = 0,
    actual_height: u32 = 0,
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

/// One sent configure: the serial plus the size it carried, so ack_configure
/// can store the acked size (wlroots wlr_layer_surface_v1_configure).
const Configure = struct {
    serial: u32,
    width: u32,
    height: u32,
};

/// Per-popup destroy hook: prunes the popup from the layer surface's list
/// when the client destroys the popup (or it dies with its wl_surface), so
/// the list never holds a freed XdgPopup.
const PopupLink = struct {
    popup: *xdg_mod.XdgPopup,
    ls: *LayerSurface,
    destroy_listener: wire.Listener(*wire.Resource),

    fn onDestroy(listener: *wire.Listener(*wire.Resource), res: *wire.Resource) void {
        _ = res;
        const link: *PopupLink = @fieldParentPtr("destroy_listener", listener);
        if (std.mem.findScalar(*xdg_mod.XdgPopup, link.ls.popups.items, link.popup)) |i| {
            _ = link.ls.popups.swapRemove(i);
        }
        link.ls.allocator.destroy(link);
    }
};

pub const LayerSurface = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    shell: *LayerShell,
    resource: *server.zwlr.LayerSurfaceV1,
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
    /// Every configure sent since the last (re)map, in order (serial + size),
    /// for ack_configure validation and the acked-size storage (wlroots
    /// configure-list semantics).
    sent_serials: std.ArrayList(Configure) = .empty,
    /// Double-buffered layer state; requests write `pending`,
    /// wl_surface.commit applies it to `current`.
    pending: LayerState = .{},
    current: LayerState = .{},
    /// The xdg_popups parented to this layer surface via get_popup, in
    /// creation order. Dismissed (popup_done + role destroy) when the layer
    /// surface resets or is destroyed (wlroots layer_surface_reset parity).
    popups: std.ArrayList(*xdg_mod.XdgPopup) = .empty,
    /// Compositor-assigned fallback for the zero desired dimensions,
    /// supplied by main.zig (the output size) via setFallbackSize; the
    /// initial configure carries it so clients asking for an auto-assigned
    /// size learn their real size (L2; the protocol: "the compositor will
    /// assign it and inform you of the assignment in the configure event").
    fallback_width: u32 = 0,
    fallback_height: u32 = 0,
    /// `closed` was sent; the object is inert.
    closed: bool = false,
    events: struct {
        destroy: wire.Signal(*LayerSurface),
        /// The client performed the initial (buffer-less) commit (L-D6):
        /// the compositor must reply with a configure so the client can
        /// map (wlroots: wlr_layer_surface_v1_configure asserts
        /// initialized; the compositor drives it). The module never
        /// self-configures; the compositor calls arrange from this signal.
        initial_commit: wire.Signal(*LayerSurface),
    },

    /// Compositor-driven configure (L-D6): send layer_surface.configure
    /// with the size the compositor assigns — the desired size per axis,
    /// or the compositor-supplied fallback (the output size from main.zig)
    /// where the client left the dimension 0. Called from the
    /// initial_commit signal (or any arrange pass); the module never
    /// self-configures (wlroots: wlr_layer_surface_v1_configure asserts
    /// initialized, wlr_layer_shell_v1.c:316-336 — the compositor calls
    /// it). The serial + size are recorded for ack_configure validation.
    pub fn arrange(ls: *LayerSurface) void {
        const serial = ls.shell.display.nextSerial();
        const width: u32 = if (ls.current.desired_width == 0) ls.fallback_width else ls.current.desired_width;
        const height: u32 = if (ls.current.desired_height == 0) ls.fallback_height else ls.current.desired_height;
        ls.resource.sendConfigure(serial, width, height);
        ls.configure_serial = serial;
        ls.configure_sent = true;
        ls.sent_serials.append(ls.allocator, .{ .serial = serial, .width = width, .height = height }) catch {
            ls.resource.postNoMemory();
        };
        log.info("layer surface configure serial={d} {d}x{d}", ls.io, ls.log_cfg, log_tag, .{
            serial,
            width,
            height,
        });
    }

    /// Handle layer_surface.ack_configure. The serial must be one we sent
    /// (present in the sent list); acking removes it and every older serial
    /// (wlroots configure-list semantics: only the last configure matters)
    /// and stores the acked configure's size so the compositor can read the
    /// size the client committed against (L6, wlroots
    /// layer_surface_handle_ack_configure: pending.actual_width/height).
    fn ackConfigure(ls: *LayerSurface, serial: u32) void {
        var acked: ?Configure = null;
        for (ls.sent_serials.items) |c| {
            if (c.serial == serial) {
                acked = c;
                break;
            }
        }
        if (acked == null) {
            ls.resource.postError(.invalid_surface_state, "wrong configure serial");
            return;
        }
        while (ls.sent_serials.items.len > 0 and ls.sent_serials.items[0].serial <= serial) {
            _ = ls.sent_serials.orderedRemove(0);
        }
        ls.pending.actual_width = acked.?.width;
        ls.pending.actual_height = acked.?.height;
        ls.configured = true;
        log.info("layer surface configured serial={d} {d}x{d}", ls.io, ls.log_cfg, log_tag, .{
            serial,
            acked.?.width,
            acked.?.height,
        });
    }

    /// Supply the compositor-assigned fallback size (the output size in
    /// main.zig); zero desired dimensions in the configure are replaced with
    /// it (L2). Replaced by the client's desired size once set.
    pub fn setFallbackSize(ls: *LayerSurface, width: u32, height: u32) void {
        ls.fallback_width = width;
        ls.fallback_height = height;
    }

    /// Reset to the initial (post-get_layer_surface) state: a fresh
    /// buffer-less commit + configure + ack are required to map again.
    /// The layer state (size/anchor/margins/zone/layer) is deliberately KEPT:
    /// wlroots layer_surface_reset (wlr_layer_shell_v1.c:33-46) also keeps
    /// it, both diverging from the XML's "returns to the state it had right
    /// after get_layer_surface" (L5, verified 2026-08-10; smithay/KWin do
    /// reset the state, which is the divergence).
    fn reset(ls: *LayerSurface) void {
        // The parented popups die with the layer surface: popup_done, then
        // destroy the role object (wlroots layer_surface_reset destroys the
        // popups the same way). The per-popup destroy listener prunes the
        // list as each resource goes away.
        while (ls.popups.items.len > 0) {
            const popup = ls.popups.items[0];
            popup.sendPopupDone();
            popup.resource.destroy();
        }
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

    /// Destroy the layer surface from the compositor side: send `closed`,
    /// then make the wire resource inert (later client requests are silent
    /// no-ops, wlroots parity: wlr_layer_shell_v1.c:331-337 then :58
    /// wl_resource_set_user_data(resource, NULL)) and tear the object down
    /// directly. The resource stays alive on the wire until the client
    /// disconnects; layerSurfaceDestroy never destroys it (it is the
    /// handler body). Idempotent.
    pub fn close(ls: *LayerSurface) void {
        if (ls.closed) return;
        ls.closed = true;
        ls.resource.sendClosed();
        // Inert with a live no-op handler, not a null dispatcher: the
        // struct is freed below, so no request may dereference it, while
        // the client's own destroy must still destroy the wire resource.
        // A null dispatcher makes libwayland abort the compositor on the
        // next request (wayland-server.c wl_closure_invoke). The destroy
        // callback stays null so resource teardown cannot call into the
        // freed struct.
        ls.resource.setHandler(?*LayerSurface, deadLayerSurfaceHandler, null, null);
        layerSurfaceDestroy(ls.resource, ls); // teardown + free, resource stays alive
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

    /// Handle get_popup. The client created the xdg_popup via
    /// xdg_surface.get_popup with a NULL parent (xdg-shell.xml: "If null is
    /// passed as a parent, a parent surface must be specified using some
    /// other protocol, before committing the initial state"); this request
    /// makes the layer surface that parent (wlroots
    /// layer_surface_handle_get_popup sets popup->parent to the layer
    /// surface's wl_surface, inserts it into the layer surface's popups list
    /// and emits new_popup). The popup is dismissed with the layer surface
    /// (see reset). An already-parented popup is an implementation error
    /// (raw -1 on the layer surface resource, wlroots).
    fn getPopup(ls: *LayerSurface, popup_res: *server.xdg.Popup) void {
        const popup: *xdg_mod.XdgPopup = @ptrCast(@alignCast(popup_res.getUserData() orelse return));
        if (popup.parent != null or popup.layer_parent != null) {
            const raw: *wire.Resource = @ptrCast(ls.resource);
            raw.postError(@bitCast(@as(i32, -1)), "xdg_popup already has a parent");
            return;
        }
        popup.layer_parent = ls.surface;
        const link = ls.allocator.create(PopupLink) catch {
            ls.resource.postNoMemory();
            return;
        };
        link.* = .{
            .popup = popup,
            .ls = ls,
            .destroy_listener = wire.Listener(*wire.Resource).init(PopupLink.onDestroy),
        };
        ls.popups.append(ls.allocator, popup) catch {
            ls.allocator.destroy(link);
            ls.resource.postNoMemory();
            return;
        };
        const raw_popup: *wire.Resource = @ptrCast(popup_res);
        raw_popup.addDestroyListener(&link.destroy_listener);
        // The popup is fully parented (layer_parent set, list insert +
        // destroy listener attached): emit the compositor signal (wlroots
        // layer_surface_handle_get_popup emits after inserting into
        // parent->popups, wlr_layer_shell_v1.c:256-257; smithay
        // WlrLayerShellHandler::new_popup; KWin popupPrivate->attachTo).
        ls.shell.events.new_popup.emit(popup);
        log.info("xdg_popup {*} parented to layer surface on wl_surface {*}", ls.io, ls.log_cfg, log_tag, .{
            popup,
            ls.surface,
        });
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

/// Request handler for inerted (closed) layer surfaces: the LayerSurface
/// struct is freed, so nothing is dereferenced — every request is a silent
/// no-op (wlroots: wl_resource_set_user_data(resource, NULL) on close).
/// The destroy callback is null, so client teardown cannot call into the
/// freed struct; the client's own destroy destroys the wire resource
/// (libwayland dispatches the destructor like any other request — a NULL
/// dispatcher would abort the compositor, wayland-server.c
/// wl_closure_invoke).
fn deadLayerSurfaceHandler(
    ls_res: *server.zwlr.LayerSurfaceV1,
    request: server.zwlr.LayerSurfaceV1.Request,
    data: ?*LayerSurface,
) void {
    _ = data;
    switch (request) {
        .destroy => ls_res.destroy(),
        .set_size => {},
        .set_anchor => {},
        .set_exclusive_zone => {},
        .set_margin => {},
        .set_keyboard_interactivity => {},
        .get_popup => {},
        .ack_configure => {},
        .set_layer => {},
        .set_exclusive_edge => {},
    }
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
            // wlroots rejects sizes beyond INT32_MAX with a client-level
            // implementation error (wl_client_post_implementation_error,
            // wlr_layer_shell_v1.c:128-151; the XML defines no error code
            // for it) — libwayland delivers it as the global
            // WL_DISPLAY_ERROR_IMPLEMENTATION error on the wl_display
            // resource (never a layer-shell error code, L4) — and skips the
            // state write when nothing changed.
            if (r.width > std.math.maxInt(i32) or r.height > std.math.maxInt(i32)) {
                ls.resource.getClient().postImplementationError(
                    "zwlr_layer_surface_v1.set_size: width/height exceed INT32_MAX",
                );
                return;
            }
            if (ls.pending.desired_width == r.width and ls.pending.desired_height == r.height) return;
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
                // invalid_layer lives on the shell error enum, but wlroots,
                // smithay and KWin all post it on the layer-surface resource
                // ("XXX: this sends a zwlr_layer_shell_v1 error to a
                // zwlr_layer_surface_v1 object", wlr_layer_shell_v1.c:260);
                // GTK-style clients expect it there. L4, 2026-08-10.
                const raw: *wire.Resource = @ptrCast(ls.resource);
                raw.postError(@intFromEnum(server.zwlr.LayerShellV1.Error.invalid_layer), "invalid layer value");
                return;
            }
            ls.pending.layer = r.layer;
        },
        .set_exclusive_edge => |r| {
            const bits: u32 = @bitCast(r.edge);
            // wlroots accepts any valid anchor bitset here
            // (zwlr_layer_surface_v1_anchor_is_valid, wlr_layer_shell_v1.c:284)
            // and defers the subset-of-anchor check to commit (L7, 2026-08-10:
            // matched to wlroots per the task brief; smithay/KWin keep the
            // stricter single-bit rule). A corner value with matching anchors
            // is accepted and simply occupies no exclusive edge.
            if ((bits & ~anchor_mask) != 0) {
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
    // The parented popups are dismissed with the layer surface (popup_done +
    // role destroy, same as the unmap reset).
    ls.reset();
    ls.events.destroy.emit(ls);
    if (std.mem.findScalar(*LayerSurface, shell.layer_surfaces.items, ls)) |i| {
        _ = shell.layer_surfaces.swapRemove(i);
    }
    ls.sent_serials.deinit(shell.allocator);
    ls.popups.deinit(shell.allocator);
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
    // The check reads the PENDING buffer: the client_commit hook runs before
    // the pending->current swap (wlroots layer_surface_role_client_commit
    // checks wlr_surface->pending; W2 F36 moved the hook pre-swap).
    if (!ls.configured and surface.pending.buffer != null) {
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
            // L-D6: the initial configure is compositor-driven (wlroots
            // never self-configures); the module emits initial_commit on
            // the first buffer-less commit and the compositor replies
            // with arrange().
            ls.events.initial_commit.emit(ls);
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
    wm_base_name: ?u32 = null,

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
                } else if (std.mem.eql(u8, name, "xdg_wm_base")) {
                    data.wm_base_name = g.name;
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

const NewLayerPopupCapture = struct {
    count: usize = 0,
    popup: ?*xdg_mod.XdgPopup = null,
    listener: wire.Listener(*xdg_mod.XdgPopup),

    fn notify(listener: *wire.Listener(*xdg_mod.XdgPopup), popup: *xdg_mod.XdgPopup) void {
        const cap: *NewLayerPopupCapture = @fieldParentPtr("listener", listener);
        cap.count += 1;
        cap.popup = popup;
    }
};

const ProtocolError = struct { code: c_int, interface: []const u8, id: u32 };

/// The client-side record of the last protocol error (interface + code),
/// for asserting which resource an error was posted on.
fn protocolError(ts: *TestServer) ProtocolError {
    var interface: ?*client.wl.Interface = null;
    var id: u32 = 0;
    const code = wl_display_get_protocol_error(ts.c_display.?, @ptrCast(&interface), &id);
    const name = if (interface) |i| std.mem.span(i.name) else "";
    return .{ .code = code, .interface = name, .id = id };
}

/// xdg_surface.configure capture (the popup's xdg_surface), for acking the
/// popup configure in the layer-popup roundtrip.
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

/// xdg_popup.configure/popup_done capture for the layer-popup roundtrip.
const PopupEvents = struct {
    configure_count: usize = 0,
    width: i32 = 0,
    height: i32 = 0,
    done_count: usize = 0,

    fn listener(popup: *client.xdg.Popup, event: client.xdg.Popup.Event, data: *PopupEvents) void {
        _ = popup;
        switch (event) {
            .configure => |c| {
                data.configure_count += 1;
                data.width = c.width;
                data.height = c.height;
            },
            .popup_done => data.done_count += 1,
            .repositioned => {},
        }
    }
};

/// A full compositor + layer shell + in-memory client, for wire roundtrips.
/// L-D6 harness wiring: subscribe to new_layer_surface and auto-arrange
/// each new layer surface's initial commit (the module never
/// self-configures; mirrors main.zig's production listener). The
/// per-surface listener struct is freed by the surface's destroy.
const LayerAutoArranger = struct {
    new_surface: wire.Listener(*LayerSurface),

    pub fn init(self: *LayerAutoArranger, shell: *LayerShell) void {
        self.* = .{ .new_surface = wire.Listener(*LayerSurface).init(onNewSurface) };
        shell.events.new_layer_surface.add(&self.new_surface);
    }

    fn onNewSurface(listener: *wire.Listener(*LayerSurface), ls: *LayerSurface) void {
        _ = listener;
        const holder = ls.allocator.create(ArrangerHolder) catch return;
        holder.* = .{
            .initial_commit = wire.Listener(*LayerSurface).init(onInitialCommit),
            .destroy = wire.Listener(*LayerSurface).init(onDestroy),
        };
        ls.events.initial_commit.add(&holder.initial_commit);
        ls.events.destroy.add(&holder.destroy);
    }

    fn onInitialCommit(listener: *wire.Listener(*LayerSurface), ls: *LayerSurface) void {
        _ = listener;
        ls.arrange();
    }

    fn onDestroy(listener: *wire.Listener(*LayerSurface), ls: *LayerSurface) void {
        const holder: *ArrangerHolder = @fieldParentPtr("destroy", listener);
        const allocator = ls.allocator;
        allocator.destroy(holder);
    }
};

/// Per-layer-surface arrange listeners (freed by the surface's destroy).
const ArrangerHolder = struct {
    initial_commit: wire.Listener(*LayerSurface),
    destroy: wire.Listener(*LayerSurface),
};

const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    shell: ?*LayerShell = null,
    /// xdg_wm_base (for the get_popup layer-popup tests).
    xdg_shell: ?*xdg_mod.XdgShell = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_shm: ?*client.wl.Shm = null,
    layer_shell: ?*client.zwlr.LayerShellV1 = null,
    wm_base: ?*client.xdg.WmBase = null,
    /// X08: compositor-driven initial configure (production replica).
    auto_configure: xdg_mod.AutoConfigureWatcher = undefined,
    /// L-D6: harness replica of the production wiring — every new layer
    /// surface replies to its initial commit with arrange().
    auto_arrange: LayerAutoArranger = undefined,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor and shell all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        return initAtVersion(allocator, 5);
    }

    /// init with zwlr_layer_shell_v1 bound at an explicit version, for the
    /// legacy-version conformance tests (a v3 client speaks an older wire).
    fn initAtVersion(allocator: std.mem.Allocator, layer_shell_version: u32) !*TestServer {
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
        // xdg_wm_base: only the layer-popup (get_popup) tests use it.
        ts.xdg_shell = try xdg_mod.XdgShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
        errdefer if (ts.xdg_shell) |s| s.deinit();

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
            capture.layer_shell_name == null or
            capture.shm_name == null or
            capture.wm_base_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor, wl_shm, zwlr_layer_shell_v1 and
        // xdg_wm_base.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wl_shm = try registry.bind(capture.shm_name.?, client.wl.Shm, 1);
        ts.layer_shell = try registry.bind(capture.layer_shell_name.?, client.zwlr.LayerShellV1, layer_shell_version);
        ts.wm_base = try registry.bind(capture.wm_base_name.?, client.xdg.WmBase, 7);
        try ts.pump();
        xdg_mod.AutoConfigureWatcher.init(&ts.auto_configure, ts.xdg_shell.?);
        LayerAutoArranger.init(&ts.auto_arrange, ts.shell.?);
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.shell) |s| s.deinit();
        if (ts.xdg_shell) |s| s.deinit();
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

test "layer surface v3 client: legacy flow, set_layer, keyboard interactivity coercion" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.initAtVersion(allocator, 3);
    defer ts.deinit();

    // The client bound zwlr_layer_shell_v1 at v3.
    try std.testing.expectEqual(@as(u32, 3), ts.layer_shell.?.getVersion());

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    var ls_events: LayerSurfaceEvents = .{};
    layer_surface.setListener(*LayerSurfaceEvents, LayerSurfaceEvents.listener, &ls_events);
    // 0x0 size with all four anchors satisfies the zero-dimension rules.
    layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
    try ts.pump();

    const ls = ts.shell.?.layer_surfaces.items[0];
    // The role object carries the shell binding's version.
    try std.testing.expectEqual(@as(u32, 3), ls.resource.getVersion());

    // set_layer is since 2: valid at v3; the new layer is double-buffered.
    layer_surface.setLayer(.overlay);
    // set_keyboard_interactivity is since 1; on a v<4 binding the value goes
    // through the bool coercion (any nonzero -> exclusive=1).
    layer_surface.setKeyboardInteractivity(.exclusive);
    try ts.pump();
    try std.testing.expectEqual(Layer.overlay, ls.pending.layer);
    try std.testing.expectEqual(@as(u32, 1), ls.pending.keyboard_interactive);

    // First commit is buffer-less: the compositor replies with the initial
    // configure and applies the pending layer/keyboard state.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ls_events.configure_count);
    try std.testing.expectEqual(@as(u32, 0), ls_events.width);
    try std.testing.expectEqual(@as(u32, 0), ls_events.height);
    try std.testing.expectEqual(Layer.overlay, ls.current.layer);
    try std.testing.expectEqual(@as(u32, 1), ls.current.keyboard_interactive);
    const serial = ls_events.serial;
    try std.testing.expectEqual(serial, ls.configure_serial);

    // Ack the configure, then a buffer commit maps the surface.
    layer_surface.ackConfigure(serial);
    const buffer = try createShmBuffer(ts);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(ls.configured);
    try std.testing.expect(ls.surface.mapped);

    // The coercion is real, not an enum round-trip: on_demand (2) does not
    // exist at v3, so the wire value must be coerced to exclusive (1), never
    // stored as 2. Re-attach so the commit is a normal buffer commit.
    layer_surface.setKeyboardInteractivity(.on_demand);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 1), ls.current.keyboard_interactive);

    // Over the v3 surface's whole life it receives exactly one configure and
    // one closed event (both since 1; the layer surface protocol defines no
    // event newer than v1, so there is nothing newer to leak).
    ls.close();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ls_events.closed_count);
    try std.testing.expectEqual(@as(usize, 1), ls_events.configure_count);
}

test "layer surface: close inerts the resource; post-close requests are no-ops" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    var ls_events: LayerSurfaceEvents = .{};
    layer_surface.setListener(*LayerSurfaceEvents, LayerSurfaceEvents.listener, &ls_events);
    layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
    try ts.pump();
    const ls = ts.shell.?.layer_surfaces.items[0];

    // Map the layer surface normally (configure + ack + buffer commit).
    wl_surface.commit();
    try ts.pump();
    layer_surface.ackConfigure(ls.configure_serial);
    const buffer = try createShmBuffer(ts);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(ls.surface.mapped);

    // Compositor close: `closed` is sent, then the resource is inerted and
    // the object torn down (wlroots parity, L3).
    ls.close();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ls_events.closed_count);
    try std.testing.expectEqual(@as(usize, 0), ts.shell.?.layer_surfaces.items.len);

    // A post-close set_size on the inert resource is a silent no-op (the
    // connection stays healthy).
    layer_surface.setSize(200, 100);
    try ts.pump();

    // The client's own destroy destroys the wire resource via the dead
    // handler: no abort (the resource keeps a real dispatcher), no protocol
    // error, the connection stays healthy.
    layer_surface.destroy();
    try ts.pump();
}

test "layer surface: get_popup parents a NULL-parent xdg_popup; layer unmap dismisses it" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Map the layer surface normally first (unmap-reset only runs once a
    // configure was sent).
    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
    try ts.pump();
    const ls = ts.shell.?.layer_surfaces.items[0];
    wl_surface.commit();
    try ts.pump();
    const layer_serial = ls.configure_serial;
    layer_surface.ackConfigure(layer_serial);
    const layer_buffer = try createShmBuffer(ts);
    wl_surface.attach(layer_buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(ls.surface.mapped);

    // The popup: its own wl_surface + xdg_surface, get_popup with NULL
    // parent, then layer_surface.get_popup before the popup's first commit.
    const popup_surface = try ts.wl_compositor.?.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(popup_surface);
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(10, 10, 20, 20);
    const popup = try xdg_surface.getPopup(null, positioner);
    var popup_events: PopupEvents = .{};
    popup.setListener(*PopupEvents, PopupEvents.listener, &popup_events);
    var xdg_events: XdgSurfaceEvents = .{};
    xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xdg_events);
    // L1: the compositor signal fires with the parented popup.
    var new_popup_capture: NewLayerPopupCapture = .{
        .listener = wire.Listener(*xdg_mod.XdgPopup).init(NewLayerPopupCapture.notify),
    };
    ts.shell.?.events.new_popup.add(&new_popup_capture.listener);
    try ts.pump();

    layer_surface.getPopup(popup);
    try ts.pump();

    // The layer surface is now the popup's parent: the popup keeps its NULL
    // xdg parent and is tracked for dismissal.
    try std.testing.expectEqual(@as(usize, 1), ls.popups.items.len);
    const server_popup = ls.popups.items[0];
    try std.testing.expect(server_popup.parent == null);
    try std.testing.expect(server_popup.layer_parent != null);
    try std.testing.expectEqual(ls.surface, server_popup.layer_parent.?);

    // The new_popup signal observed the creation with the SAME, fully
    // parented object (L1; wlroots emits after the list insert).
    try std.testing.expectEqual(@as(usize, 1), new_popup_capture.count);
    try std.testing.expectEqual(server_popup, new_popup_capture.popup.?);
    try std.testing.expectEqual(ls.surface, new_popup_capture.popup.?.layer_parent.?);

    // The popup's first buffer-less commit triggers popup.configure (with the
    // positioner geometry) + xdg_surface.configure.
    popup_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), popup_events.configure_count);
    try std.testing.expectEqual(@as(usize, 1), xdg_events.configure_count);
    try std.testing.expectEqual(@as(i32, 100), popup_events.width);
    try std.testing.expectEqual(@as(i32, 50), popup_events.height);

    // Ack + buffer commit maps the popup.
    xdg_surface.ackConfigure(xdg_events.serial);
    const popup_buffer = try createShmBuffer(ts);
    popup_surface.attach(popup_buffer, 0, 0);
    popup_surface.commit();
    try ts.pump();
    try std.testing.expect(server_popup.xdg_surface.surface.mapped);

    // Unmapping the layer surface dismisses the popup with it: popup_done,
    // then the popup role object goes away (wlroots layer_surface_reset).
    wl_surface.attach(null, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), popup_events.done_count);
    try std.testing.expectEqual(@as(usize, 0), ls.popups.items.len);
    try std.testing.expect(!server_popup.xdg_surface.surface.mapped);
}

test "layer surface: get_popup on an already-parented xdg_popup posts -1" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // A toplevel to serve as the popup's xdg parent.
    const parent_wl = try ts.wl_compositor.?.createSurface();
    const parent_xdg = try ts.wm_base.?.getXdgSurface(parent_wl);
    _ = try parent_xdg.getToplevel();
    try ts.pump();

    const popup_wl = try ts.wl_compositor.?.createSurface();
    const popup_xdg = try ts.wm_base.?.getXdgSurface(popup_wl);
    const positioner = try ts.wm_base.?.createPositioner();
    positioner.setSize(100, 50);
    positioner.setAnchorRect(0, 0, 10, 10);
    const popup = try popup_xdg.getPopup(parent_xdg, positioner);
    try ts.pump();

    // The popup already has an xdg parent: wlroots posts raw -1 on the
    // layer-surface resource ("xdg_popup already has a parent").
    const layer_wl = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(layer_wl, null, .top, "test");
    try ts.pump();
    layer_surface.getPopup(popup);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, -1), err.code);
    try std.testing.expectEqualStrings("zwlr_layer_surface_v1", err.interface);
}

test "layer surface: initial configure carries the assigned fallback size" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    var ls_events: LayerSurfaceEvents = .{};
    layer_surface.setListener(*LayerSurfaceEvents, LayerSurfaceEvents.listener, &ls_events);
    layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
    // Width 0 = compositor assigns (the output width from main.zig); height
    // 100 stays the client's desired size.
    layer_surface.setSize(0, 100);
    try ts.pump();
    const ls = ts.shell.?.layer_surfaces.items[0];
    ls.setFallbackSize(640, 30);

    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ls_events.configure_count);
    try std.testing.expectEqual(@as(u32, 640), ls_events.width);
    try std.testing.expectEqual(@as(u32, 100), ls_events.height);
}

test "layer surface: set_size beyond INT32_MAX is an implementation error" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    try ts.pump();

    const too_big: u32 = @as(u32, @intCast(std.math.maxInt(i32))) + 1;
    layer_surface.setSize(too_big, 0);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    // wlroots parity (L4): the oversized size kills the client via a
    // SERVER-side implementation error (wl_client_post_implementation_error,
    // wlr_layer_shell_v1.c:137-141). libwayland delivers it as the global
    // WL_DISPLAY_ERROR_IMPLEMENTATION (3) error on the wl_display resource
    // (verified in wayland-server.c: wl_client_post_implementation_error ->
    // wl_resource_post_error_vargs(display_resource, ...)) — not the raw -1
    // on the layer-surface resource the old code posted, and never a
    // layer-shell error code.
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 3), err.code); // WL_DISPLAY_ERROR_IMPLEMENTATION
    try std.testing.expectEqualStrings("wl_display", err.interface);
    // The error fires before any state write (the guard returns first), and
    // posting it destroys the client (libwayland-server tears down errored
    // clients after the dispatch), so no server-side state survives to read.
}

test "layer surface: repeated identical set_size is a no-op" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    try ts.pump();
    const ls = ts.shell.?.layer_surfaces.items[0];

    // The second identical set_size is a no-op (no error, state unchanged);
    // the surface stays usable and the commit goes through.
    layer_surface.setSize(100, 50);
    layer_surface.setSize(100, 50);
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 100), ls.pending.desired_width);
    try std.testing.expectEqual(@as(u32, 50), ls.pending.desired_height);

    layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 100), ls.current.desired_width);
    try std.testing.expectEqual(@as(u32, 50), ls.current.desired_height);
}

test "layer surface: invalid set_layer posts invalid_layer on the surface resource" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    try ts.pump();

    // 99 is outside {background..overlay}: invalid_layer (1), posted on the
    // LAYER SURFACE resource (wlroots/smithay/KWin parity, L4).
    layer_surface.setLayer(@enumFromInt(99));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    const err = protocolError(ts);
    try std.testing.expectEqual(@as(c_int, 1), err.code);
    try std.testing.expectEqualStrings("zwlr_layer_surface_v1", err.interface);
}

test "layer surface: ack_configure stores the actual configure size" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
    var ls_events: LayerSurfaceEvents = .{};
    layer_surface.setListener(*LayerSurfaceEvents, LayerSurfaceEvents.listener, &ls_events);
    layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
    try ts.pump();
    const ls = ts.shell.?.layer_surfaces.items[0];
    ls.setFallbackSize(640, 30);

    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 640), ls_events.width);
    try std.testing.expectEqual(@as(u32, 30), ls_events.height);
    const serial = ls_events.serial;

    layer_surface.ackConfigure(serial);
    try ts.pump();
    // The acked configure's size lands in pending at ack (wlroots parity)...
    try std.testing.expectEqual(@as(u32, 640), ls.pending.actual_width);
    try std.testing.expectEqual(@as(u32, 30), ls.pending.actual_height);

    // ...and in current once the buffer commit applies the double-buffered
    // state, so the compositor can read the size the client committed
    // against.
    const buffer = try createShmBuffer(ts);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try ts.pump();
    try std.testing.expectEqual(@as(u32, 640), ls.current.actual_width);
    try std.testing.expectEqual(@as(u32, 30), ls.current.actual_height);
    try std.testing.expect(ls.surface.mapped);
}

test "layer surface: set_exclusive_edge accepts valid anchor subsets (wlroots parity)" {
    const allocator = std.testing.allocator;
    {
        // A corner (multi-bit) value is accepted at request time; with
        // matching anchors the commit goes through.
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const wl_surface = try ts.wl_compositor.?.createSurface();
        const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
        layer_surface.setAnchor(@bitCast(anchor_top | anchor_bottom | anchor_left | anchor_right));
        layer_surface.setExclusiveEdge(@bitCast(anchor_top | anchor_left));
        try ts.pump();
        const ls = ts.shell.?.layer_surfaces.items[0];
        try std.testing.expectEqual(@as(u32, anchor_top | anchor_left), ls.pending.exclusive_edge);
        wl_surface.commit();
        try ts.pump();
        try std.testing.expectEqual(@as(u32, anchor_top | anchor_left), ls.current.exclusive_edge);
    }
    {
        // An out-of-mask bit is still invalid_exclusive_edge (4).
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const wl_surface = try ts.wl_compositor.?.createSurface();
        const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
        try ts.pump();
        layer_surface.setExclusiveEdge(@bitCast(@as(u32, 0x10)));
        try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
        const err = protocolError(ts);
        try std.testing.expectEqual(@as(c_int, 4), err.code);
        try std.testing.expectEqualStrings("zwlr_layer_surface_v1", err.interface);
    }
    {
        // A valid edge not covered by the anchors still errors at commit
        // (the subset check stayed at commit time, wlroots order).
        var ts = try TestServer.init(allocator);
        defer ts.deinit();
        const wl_surface = try ts.wl_compositor.?.createSurface();
        const layer_surface = try ts.layer_shell.?.getLayerSurface(wl_surface, null, .top, "test");
        // left|right only: a top edge is not part of the anchor.
        layer_surface.setAnchor(@bitCast(anchor_left | anchor_right));
        layer_surface.setSize(100, 100);
        layer_surface.setExclusiveEdge(@bitCast(anchor_top));
        try ts.pump();
        wl_surface.commit();
        try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
        const err = protocolError(ts);
        try std.testing.expectEqual(@as(c_int, 4), err.code);
        try std.testing.expectEqualStrings("zwlr_layer_surface_v1", err.interface);
    }
}
