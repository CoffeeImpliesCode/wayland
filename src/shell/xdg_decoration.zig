//! zxdg_decoration_manager_v1 (unstable/xdg-decoration): the
//! zxdg_decoration_manager_v1 global plus the xdg_toplevel_decoration
//! state machine.
//!
//! Semantics (audit-verified vs wlroots types/wlr_xdg_decoration_v1.c,
//! smithay shell/xdg/decoration.rs, KWin xdgdecoration_v1.cpp +
//! xdgshellwindow.cpp; XML ground truth
//! protocols/wayland-protocols/unstable/xdg-decoration/
//! xdg-decoration-unstable-v1.xml):
//! - (a) get_toplevel_decoration on a toplevel that already committed a
//!   buffer posts unconfigured_buffer=0 for v1 objects; for v2+ objects
//!   the XML allows it ("creating an xdg_toplevel_decoration from an
//!   xdg_toplevel which has a buffer attached or committed is allowed").
//!   The initial mode of a v2 decoration created on such a toplevel is the
//!   retained mode if a previous decoration was destroyed without a
//!   surface commit in between, else client-side (D3, see (h)).
//! - (b) a second decoration object on the same toplevel posts
//!   already_constructed=1.
//! - (c) a toplevel destroyed before its decoration posts orphaned=2 on
//!   the decoration resource (the client must destroy the decoration
//!   first). The decoration module tracks the toplevel's lifetime through
//!   XdgToplevel.events.destroy.
//! - (d) set_mode with a value outside {client_side, server_side} posts
//!   invalid_mode=3. [Divergence: the XML mandates this error but
//!   wlroots/smithay/KWin do not raise it — this implementation does,
//!   per the XML. See notes/129.]
//! - (e) set_mode/unset_mode are forwarded to the compositor as
//!   `events.request_mode`; the compositor replies by calling
//!   Decoration.sendConfigure(mode), which SCHEDULES a toplevel configure
//!   (XD-1; wlroots wlr_xdg_toplevel_decoration_v1_set_mode, XD:52-58):
//!   the zxdg_toplevel_decoration_v1.configure event rides the same
//!   xdg_surface.configure/ack_configure cycle (sent during the configure
//!   emission, applied when the client acks the matching xdg configure;
//!   wlroots XD:93-146). No initial configure is sent BY THE MODULE: a
//!   client that never sets a mode draws client-side (the XML's default;
//!   wlroots' pending == scheduled initially) unless the compositor
//!   announces one — every decoration creation fires
//!   `events.new_toplevel_decoration` (L2, wlroots XD:237) so the
//!   compositor can call sendConfigure(mode) for a compositor-decided
//!   initial mode.
//! - (f) creation errors (unconfigured_buffer, already_constructed) are
//!   posted on the MANAGER resource (XD-2; wlroots XD:181, XD:190,
//!   smithay smXD:229-243, KWin KWXD:54-65), not on the new decoration.
//! - (g) an orphaned decoration (toplevel destroyed first) posts orphaned
//!   AND destroys the decoration resource (XD-4; wlroots XD:81-91).
//! - (h) v2 mode retention (D3): destroying a decoration that has an
//!   effective (acked) mode records that mode against the toplevel
//!   (RetainedMode). A v2 re-create on the same toplevel seeds the new
//!   decoration's current/pending/scheduled state with it — no configure
//!   is re-sent, the client is already drawing that mode (the XML: "the
//!   previous decoration mode is retained"). The next wl_surface.commit
//!   after the destroy reverts to client-side (the XML's destroy text:
//!   "Switch back to a mode without any server-side decorations at the
//!   next commit, unless a new xdg_toplevel_decoration is created for the
//!   surface first"), and the toplevel's death drops the retention.

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const display_mod = @import("../core/display.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const surface_mod = @import("../compositor/surface.zig");
const xdg_mod = @import("xdg.zig");

const log_tag = "xdg_decoration";

pub const Mode = server.zxdg.ToplevelDecorationV1.Mode;

/// set_mode/unset_mode arrived; the compositor replies with
/// Decoration.sendConfigure. mode == null for unset_mode.
pub const RequestMode = struct {
    decoration: *Decoration,
    mode: ?Mode,
};

/// A configure sent but not yet acked (wlroots configure_list entry,
/// XD:96-113): the mode the client must draw once it acks serial.
const ConfigureEntry = struct {
    serial: u32,
    mode: Mode,
};

pub const Decoration = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    manager: *XdgDecoration,
    resource: *server.zxdg.ToplevelDecorationV1,
    /// The decorated toplevel. Null once the toplevel died (orphaned path)
    /// — invariant: toplevel == null implies all three toplevel listeners
    /// are detached, so the destroy handler never touches freed memory.
    toplevel: ?*xdg_mod.XdgToplevel,
    /// The toplevel's destroy listener (orphaned detection).
    destroy_listener: wire.Listener(*xdg_mod.XdgToplevel),
    /// The toplevel's xdg_surface configure listener (XD-1): sends the
    /// zxdg decoration configure with the scheduled mode during the xdg
    /// configure emission.
    configure_listener: wire.Listener(*xdg_mod.XdgSurface),
    /// The toplevel's xdg_surface ack_configure listener (XD-1): applies
    /// the acked configure's mode.
    ack_listener: wire.Listener(*xdg_mod.XdgSurface),
    /// The mode the compositor last scheduled via sendConfigure (wlroots
    /// scheduled_mode); null = no mode established (client-side default).
    scheduled_mode: ?Mode = null,
    /// The mode of the last configure sent but not yet acked (wlroots
    /// pending.mode); updated at ack.
    pending_mode: ?Mode = null,
    /// The last acked mode (wlroots current.mode): what the client is
    /// drawing with. null = none established.
    current_mode: ?Mode = null,
    /// (serial, mode) pairs for configures sent but not yet acked, in send
    /// order (wlroots configure_list, XD:96-113).
    configure_list: std.ArrayList(ConfigureEntry) = .empty,

    /// The compositor's reply to a request_mode: schedule a toplevel
    /// configure that carries the mode (wlroots
    /// wlr_xdg_toplevel_decoration_v1_set_mode, XD:52-58). The zxdg
    /// decoration configure is sent during the xdg_surface.configure
    /// emission and the mode is applied when the client acks that
    /// configure (XD-1).
    pub fn sendConfigure(dec: *Decoration, mode: Mode) void {
        dec.scheduled_mode = mode;
        const toplevel = dec.toplevel orelse return;
        toplevel.configure(0, 0) catch return;
    }
};

/// v2 mode retention (D3, XML get_toplevel_decoration): a decoration
/// destroyed with an effective mode leaves this entry keyed by its
/// toplevel; a re-created v2 decoration inherits the mode. The entry dies
/// on the next wl_surface.commit after the destroy (the XML's destroy
/// text: "Switch back to a mode without any server-side decorations at the
/// next commit, unless a new xdg_toplevel_decoration is created for the
/// surface first"), or with the toplevel (no re-create can follow).
const RetainedMode = struct {
    manager: *XdgDecoration,
    toplevel: *xdg_mod.XdgToplevel,
    mode: Mode,
    /// Fires on the next surface commit after the destroy: the retention
    /// expires and the mode reverts to client-side.
    commit_listener: wire.Listener(*surface_mod.Surface),
    /// The toplevel died with the retention pending: drop the entry so it
    /// cannot outlive its key (the surface may be reused by another role).
    destroy_listener: wire.Listener(*xdg_mod.XdgToplevel),
};

// ---------------------------------------------------------------------------
// XdgDecoration: the zxdg_decoration_manager_v1 global.
// ---------------------------------------------------------------------------

pub const XdgDecoration = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The xdg shell whose toplevels this manager decorates (the toplevel
    /// destroy tracking hooks XdgToplevel.events.destroy).
    shell: *xdg_mod.XdgShell,
    /// The zxdg_decoration_manager_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// All live decorations, in creation order.
    decorations: std.ArrayList(*Decoration),
    /// v2 mode retention (D3): pending retained modes keyed by toplevel —
    /// a destroyed decoration's effective mode awaiting a re-create. See
    /// RetainedMode.
    retained_modes: std.AutoHashMap(*xdg_mod.XdgToplevel, *RetainedMode),
    events: struct {
        request_mode: wire.Signal(*RequestMode),
        /// A decoration was created and inserted into `decorations`
        /// (wlroots manager->events.new_toplevel_decoration,
        /// wlr_xdg_decoration_v1.c:237; smithay new_decoration; KWin
        /// decorationCreated). The compositor can announce a
        /// compositor-decided initial mode via Decoration.sendConfigure.
        new_toplevel_decoration: wire.Signal(*Decoration),
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        shell: *xdg_mod.XdgShell,
    ) !*XdgDecoration {
        const deco = try allocator.create(XdgDecoration);
        errdefer allocator.destroy(deco);
        deco.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .shell = shell,
            .decorations = .empty,
            .retained_modes = std.AutoHashMap(*xdg_mod.XdgToplevel, *RetainedMode).init(allocator),
            // SAFETY: initialized via .init() immediately after construction, before any emit.
            .events = undefined,
        };
        errdefer deco.decorations.deinit(allocator);
        errdefer deco.retained_modes.deinit();
        deco.events.request_mode.init();
        deco.events.new_toplevel_decoration.init();

        // Register zxdg_decoration_manager_v1 at the maximum version we
        // implement (v2: creation on a committed toplevel is allowed, with
        // mode retention across a re-create — D3; the unconfigured_buffer
        // error survives for v1 objects).
        deco.global = try display.addGlobal(
            server.zxdg.DecorationManagerV1,
            *XdgDecoration,
            decorationBind,
            server.zxdg.DecorationManagerV1.generated_version,
            deco,
        );
        return deco;
    }

    pub fn deinit(self: *XdgDecoration) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the wire resources cascades through their destroy
        // handlers, which remove entries from the list and free the objects
        // (and detach their toplevel destroy listeners).
        while (self.decorations.items.len > 0) self.decorations.items[0].resource.destroy();
        // v2: the destroyed decorations may have left retention entries
        // (each with live surface-commit/toplevel-destroy listeners); drop
        // them all before the map dies.
        while (self.retained_modes.count() > 0) {
            var it = self.retained_modes.keyIterator();
            retainedClear(self, it.next().?.*);
        }
        self.retained_modes.deinit();
        self.decorations.deinit(allocator);
        // The decoration global itself is owned by the display's registry.
        allocator.destroy(self);
    }
};

fn decorationBind(client_wire: *wire.Client, deco: *XdgDecoration, version: u32, id: u32) void {
    const manager_res = server.zxdg.DecorationManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    manager_res.setHandler(*XdgDecoration, managerRequest, null, deco);
}

fn managerRequest(
    manager_res: *server.zxdg.DecorationManagerV1,
    request: server.zxdg.DecorationManagerV1.Request,
    deco: *XdgDecoration,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => manager_res.destroy(),
        .get_toplevel_decoration => |r| {
            const res = server.zxdg.ToplevelDecorationV1.create(
                manager_res.getClient(),
                manager_res.getVersion(),
                r.id,
            ) catch {
                manager_res.postNoMemory();
                return;
            };
            getToplevelDecoration(deco, manager_res, res, r.toplevel);
        },
    }
}

/// Post an xdg_toplevel_decoration error code on the manager resource
/// (XD-2). The error enum lives on the decoration interface, but wlroots
/// posts creation errors on the manager (XD:181, XD:190) so the client
/// attributes them to the object it called.
fn managerPostError(
    manager_res: *server.zxdg.DecorationManagerV1,
    code: server.zxdg.ToplevelDecorationV1.Error,
    message: [*:0]const u8,
) void {
    const res: *server.wl.Resource = @ptrCast(manager_res);
    res.postError(@intCast(@intFromEnum(code)), message);
}

/// zxdg_decoration_manager_v1.get_toplevel_decoration. Creation validation
/// errors post on the MANAGER resource (XD-2); the freshly created
/// decoration resource is destroyed.
fn getToplevelDecoration(
    deco: *XdgDecoration,
    manager_res: *server.zxdg.DecorationManagerV1,
    res: *server.zxdg.ToplevelDecorationV1,
    toplevel_res: *server.xdg.Toplevel,
) void {
    // The xdg_toplevel resource's user data is the XdgToplevel role
    // object; null means the toplevel was already destroyed.
    const toplevel_ud = toplevel_res.getUserData() orelse {
        res.postError(.orphaned, "xdg_toplevel_decoration created after its xdg_toplevel was destroyed");
        res.destroy();
        return;
    };
    const toplevel: *xdg_mod.XdgToplevel = @ptrCast(@alignCast(toplevel_ud));
    // Model decision (a), version-gated (D3): at v1 a toplevel that
    // already committed a buffer must not be decorated (wlroots posts
    // unconfigured_buffer on the manager resource); at v2+ the XML allows
    // it ("creating an xdg_toplevel_decoration from an xdg_toplevel which
    // has a buffer attached or committed is allowed").
    if (res.getVersion() < 2) {
        if (toplevel.xdg_surface.surface.buffer != null) {
            managerPostError(
                manager_res,
                .unconfigured_buffer,
                "xdg_toplevel_decoration must not be created after a buffer was committed",
            );
            res.destroy();
            return;
        }
    }
    // Model decision (b): one decoration per toplevel.
    for (deco.decorations.items) |existing| {
        if (existing.toplevel == toplevel) {
            managerPostError(manager_res, .already_constructed, "xdg_toplevel already has an xdg_toplevel_decoration");
            res.destroy();
            return;
        }
    }
    const dec = deco.allocator.create(Decoration) catch {
        res.destroy();
        manager_res.postNoMemory();
        return;
    };
    dec.* = .{
        .allocator = deco.allocator,
        .io = deco.io,
        .log_cfg = deco.log_cfg,
        .manager = deco,
        .resource = res,
        .toplevel = toplevel,
        .destroy_listener = wire.Listener(*xdg_mod.XdgToplevel).init(onToplevelDestroy),
        .configure_listener = wire.Listener(*xdg_mod.XdgSurface).init(onSurfaceConfigure),
        .ack_listener = wire.Listener(*xdg_mod.XdgSurface).init(onAckConfigure),
    };
    res.setHandler(*Decoration, decorationRequest, decorationDestroy, dec);
    // Model decision (c): the module needs the toplevel's lifetime to post
    // orphaned when the toplevel dies first, and (XD-1) the xdg configure
    // emission to ride the mode configure on the same cycle.
    toplevel.events.destroy.add(&dec.destroy_listener);
    toplevel.xdg_surface.events.configure.add(&dec.configure_listener);
    toplevel.xdg_surface.events.ack_configure.add(&dec.ack_listener);
    deco.decorations.append(deco.allocator, dec) catch {
        dec.destroy_listener.link.remove();
        dec.configure_listener.link.remove();
        dec.ack_listener.link.remove();
        dec.toplevel = null; // the listeners are detached; decorationDestroy skips them
        res.destroy();
        manager_res.postNoMemory();
        return;
    };
    // v2 mode retention (D3): a decoration destroyed without a surface
    // commit leaves its effective mode; the re-created decoration inherits
    // it (the XML: "the previous decoration mode is retained"). The client
    // is already drawing that mode, so the state is seeded as
    // current/pending/scheduled — a same-mode compositor announce
    // dedupes (onSurfaceConfigure), a different one reconfigures.
    if (res.getVersion() >= 2) {
        if (deco.retained_modes.fetchRemove(toplevel)) |kv| {
            const ret = kv.value;
            const mode = ret.mode;
            ret.commit_listener.link.remove();
            ret.destroy_listener.link.remove();
            deco.allocator.destroy(ret);
            dec.scheduled_mode = mode;
            dec.pending_mode = mode;
            dec.current_mode = mode;
        }
    }
    // L2: the decoration is live (inserted + listeners attached) — notify
    // the compositor so it can announce a compositor-decided initial mode
    // (wlroots emits after inserting into manager->decorations,
    // wlr_xdg_decoration_v1.c:237).
    deco.events.new_toplevel_decoration.emit(dec);
    if (dec.current_mode) |mode| {
        const mode_desc = if (mode == .server_side) "server-side" else "client-side";
        log.debug("new toplevel decoration (mode retained: {s})", deco.io, deco.log_cfg, log_tag, .{mode_desc});
    } else {
        log.debug("new toplevel decoration (mode unset; client-side default)", deco.io, deco.log_cfg, log_tag, .{});
    }
}

fn decorationRequest(
    dec_res: *server.zxdg.ToplevelDecorationV1,
    request: server.zxdg.ToplevelDecorationV1.Request,
    dec: *Decoration,
) void {
    switch (request) {
        // Destructor: libwayland does not auto-destroy; we do.
        .destroy => dec_res.destroy(),
        .set_mode => |r| {
            // Model decision (d): the XML mandates invalid_mode for any mode
            // outside {client_side, server_side}; wlroots/smithay/KWin do
            // not raise it, this implementation does.
            if (r.mode != .client_side and r.mode != .server_side) {
                dec_res.postError(.invalid_mode, "set_mode: mode must be client_side (1) or server_side (2)");
                return;
            }
            emitRequestMode(dec, r.mode);
        },
        .unset_mode => emitRequestMode(dec, null),
    }
}

/// Forward the mode preference to the compositor; it replies with
/// sendConfigure (which schedules a toplevel configure, model decision (e)).
fn emitRequestMode(dec: *Decoration, mode: ?Mode) void {
    var req: RequestMode = .{
        .decoration = dec,
        .mode = mode,
    };
    dec.manager.events.request_mode.emit(&req);
}

fn decorationDestroy(dec_res: *server.zxdg.ToplevelDecorationV1, dec: *Decoration) void {
    _ = dec_res;
    const deco = dec.manager;
    // v2 mode retention (D3): a decoration destroyed with an effective
    // mode leaves it for a v2 re-create, until the next surface commit or
    // the toplevel's death (the XML: destroyed "without a surface commit,
    // the previous decoration mode is retained"). Orphaned decorations
    // (toplevel == null) cannot be re-created, so nothing is recorded.
    if (dec.toplevel != null and dec.resource.getVersion() >= 2) {
        if (dec.current_mode) |mode| retainedRecord(deco, dec.toplevel.?, mode);
    }
    if (std.mem.findScalar(*Decoration, deco.decorations.items, dec)) |i| {
        _ = deco.decorations.swapRemove(i);
    }
    // Invariant: toplevel != null means all three toplevel listeners are
    // still attached (and the toplevel is alive).
    if (dec.toplevel != null) {
        dec.destroy_listener.link.remove();
        dec.configure_listener.link.remove();
        dec.ack_listener.link.remove();
    }
    dec.configure_list.deinit(dec.allocator);
    deco.allocator.destroy(dec);
}

/// The toplevel died before the decoration (model decision (c) + XD-4):
/// detach and forget the toplevel first, then post orphaned AND destroy
/// the decoration resource (wlroots XD:81-91). The destroy handler runs
/// with toplevel == null (no touch of the freed toplevel).
fn onToplevelDestroy(listener: *wire.Listener(*xdg_mod.XdgToplevel), toplevel: *xdg_mod.XdgToplevel) void {
    const dec: *Decoration = @fieldParentPtr("destroy_listener", listener);
    dec.destroy_listener.link.remove();
    dec.configure_listener.link.remove();
    dec.ack_listener.link.remove();
    dec.toplevel = null;
    _ = toplevel;
    dec.resource.postError(.orphaned, "xdg_toplevel_decoration must be destroyed before its xdg_toplevel");
    dec.resource.destroy();
}

/// The next wl_surface.commit after a decoration destroy (D3): the
/// retention expires and the mode reverts to client-side (the XML's
/// destroy text).
fn onRetainedCommit(listener: *wire.Listener(*surface_mod.Surface), surface: *surface_mod.Surface) void {
    const ret: *RetainedMode = @fieldParentPtr("commit_listener", listener);
    _ = surface;
    retainedClear(ret.manager, ret.toplevel);
}

/// The toplevel died with retention pending (D3): no re-create can follow,
/// drop the entry so it cannot outlive its key. Fires after the surviving
/// decoration's onToplevelDestroy (listener insertion order), while the
/// xdg_surface is still being reset — detaching the commit listener is
/// safe.
fn onRetainedToplevelDestroy(listener: *wire.Listener(*xdg_mod.XdgToplevel), toplevel: *xdg_mod.XdgToplevel) void {
    const ret: *RetainedMode = @fieldParentPtr("destroy_listener", listener);
    _ = toplevel;
    retainedClear(ret.manager, ret.toplevel);
}

/// Drop and free the retention entry for `toplevel`, if any (detaches its
/// surface-commit/toplevel-destroy listeners). Called from the entry's own
/// handlers, from a re-create, and from teardown.
fn retainedClear(deco: *XdgDecoration, toplevel: *xdg_mod.XdgToplevel) void {
    const kv = deco.retained_modes.fetchRemove(toplevel) orelse return;
    kv.value.commit_listener.link.remove();
    kv.value.destroy_listener.link.remove();
    deco.allocator.destroy(kv.value);
}

/// Record the effective mode of a destroyed decoration for a v2 re-create
/// (D3). A stale entry cannot normally exist (one decoration per toplevel;
/// the entry is consumed at re-create and cleared by commit/toplevel
/// death), but replace defensively.
fn retainedRecord(deco: *XdgDecoration, toplevel: *xdg_mod.XdgToplevel, mode: Mode) void {
    retainedClear(deco, toplevel);
    const ret = deco.allocator.create(RetainedMode) catch return;
    ret.* = .{
        .manager = deco,
        .toplevel = toplevel,
        .mode = mode,
        .commit_listener = wire.Listener(*surface_mod.Surface).init(onRetainedCommit),
        .destroy_listener = wire.Listener(*xdg_mod.XdgToplevel).init(onRetainedToplevelDestroy),
    };
    toplevel.xdg_surface.surface.events.commit.add(&ret.commit_listener);
    toplevel.events.destroy.add(&ret.destroy_listener);
    deco.retained_modes.put(toplevel, ret) catch {
        // OOM: drop the retention (detach + free); the mode reverts to
        // client-side, which the XML allows as the fallback.
        ret.commit_listener.link.remove();
        ret.destroy_listener.link.remove();
        deco.allocator.destroy(ret);
    };
}

/// The toplevel's xdg_surface.configure was sent (XD-1): if the compositor
/// scheduled a mode different from the last acked one, send the
/// zxdg_toplevel_decoration_v1.configure in the same roundtrip and record
/// the (serial, mode) pair for the ack (wlroots
/// toplevel_decoration_handle_surface_configure, XD:93-113).
fn onSurfaceConfigure(listener: *wire.Listener(*xdg_mod.XdgSurface), xdg: *xdg_mod.XdgSurface) void {
    const dec: *Decoration = @fieldParentPtr("configure_listener", listener);
    const mode = dec.scheduled_mode orelse return;
    if (dec.pending_mode == dec.scheduled_mode) return;
    dec.configure_list.append(dec.allocator, .{ .serial = xdg.configure_serial, .mode = mode }) catch return;
    dec.resource.sendConfigure(mode);
}

/// The client acked an xdg_surface.configure (XD-1): apply the mode that
/// configure carried and drop entries that can never be acked (wlroots
/// toplevel_decoration_handle_surface_ack_configure, XD:115-146).
fn onAckConfigure(listener: *wire.Listener(*xdg_mod.XdgSurface), xdg: *xdg_mod.XdgSurface) void {
    const dec: *Decoration = @fieldParentPtr("ack_listener", listener);
    const acked = xdg.acked_serial orelse return;
    var idx: ?usize = null;
    for (dec.configure_list.items, 0..) |entry, i| {
        if (entry.serial == acked) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return;
    const mode = dec.configure_list.items[i].mode;
    // Serials up to and including the acked one can never be acked again
    // (xdg-shell enforces strictly increasing acks).
    var n: usize = 0;
    while (n <= i) : (n += 1) {
        _ = dec.configure_list.orderedRemove(0);
    }
    dec.pending_mode = mode;
    dec.current_mode = mode;
}

// --- socketpair roundtrip harness (pattern: src/shell/xdg.zig) ------------

const posix = std.posix;

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    wm_base_name: ?u32 = null,
    decoration_manager_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "xdg_wm_base")) {
                    data.wm_base_name = g.name;
                } else if (std.mem.eql(u8, name, "zxdg_decoration_manager_v1")) {
                    data.decoration_manager_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

const DecorationEvents = struct {
    configure_count: usize = 0,
    mode: i32 = 0,

    fn listener(
        dec: *client.zxdg.ToplevelDecorationV1,
        event: client.zxdg.ToplevelDecorationV1.Event,
        data: *DecorationEvents,
    ) void {
        _ = dec;
        switch (event) {
            .configure => |c| {
                data.configure_count += 1;
                data.mode = @intFromEnum(c.mode);
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

const RequestModeCapture = struct {
    count: usize = 0,
    mode: i32 = 0,
    listener: wire.Listener(*RequestMode),

    fn notify(listener: *wire.Listener(*RequestMode), req: *RequestMode) void {
        const cap: *RequestModeCapture = @fieldParentPtr("listener", listener);
        cap.count += 1;
        // The compositor's reply: echo the requested mode back via
        // sendConfigure (the happy-path policy in main.zig is the same,
        // keyed on focus).
        const mode = req.mode orelse .client_side;
        cap.mode = @intFromEnum(mode);
        req.decoration.sendConfigure(mode);
    }
};

const NewDecorationCapture = struct {
    count: usize = 0,
    decoration: ?*Decoration = null,
    listener: wire.Listener(*Decoration),

    fn notify(listener: *wire.Listener(*Decoration), dec: *Decoration) void {
        const cap: *NewDecorationCapture = @fieldParentPtr("listener", listener);
        cap.count += 1;
        cap.decoration = dec;
    }
};

/// A full compositor + shell + decoration manager + in-memory client, for
/// wire roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    shell: ?*xdg_mod.XdgShell = null,
    decoration: ?*XdgDecoration = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wm_base: ?*client.xdg.WmBase = null,
    decoration_client: ?*client.zxdg.DecorationManagerV1 = null,

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
        ts.shell = try xdg_mod.XdgShell.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.compositor.?);
        errdefer if (ts.shell) |s| s.deinit();
        ts.decoration = try XdgDecoration.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.shell.?);
        errdefer if (ts.decoration) |d| d.deinit();

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
            capture.wm_base_name == null or
            capture.decoration_manager_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor, xdg_wm_base and the decoration
        // manager.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wm_base = try registry.bind(capture.wm_base_name.?, client.xdg.WmBase, 7);
        ts.decoration_client = try registry.bind(capture.decoration_manager_name.?, client.zxdg.DecorationManagerV1, 1);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers must
        // run while the decoration manager and shell still live.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.decoration) |d| d.deinit();
        if (ts.shell) |s| s.deinit();
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

    /// Create an xdg_toplevel for the test client.
    fn createToplevel(ts: *TestServer) !struct {
        surface: *client.wl.Surface,
        xdg_surface: *client.xdg.Surface,
        toplevel: *client.xdg.Toplevel,
    } {
        const wl_surface = try ts.wl_compositor.?.createSurface();
        const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
        const toplevel = try xdg_surface.getToplevel();
        try ts.pump();
        return .{ .surface = wl_surface, .xdg_surface = xdg_surface, .toplevel = toplevel };
    }

    /// Bind the decoration manager at an explicit version (init binds v1;
    /// the v2 tests re-bind the global at 2). A second registry is fine —
    /// wl_display.get_registry is repeatable.
    fn bindDecorationManager(ts: *TestServer, version: u32) !*client.zxdg.DecorationManagerV1 {
        const registry = try ts.c_display.?.getRegistry();
        var capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
        try ts.pump();
        if (capture.decoration_manager_name == null) return error.GlobalMissing;
        return registry.bind(capture.decoration_manager_name.?, client.zxdg.DecorationManagerV1, version);
    }
};

test "decoration happy path: get -> set_mode -> request_mode -> configure" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: RequestModeCapture = .{
        .listener = wire.Listener(*RequestMode).init(RequestModeCapture.notify),
    };
    ts.decoration.?.events.request_mode.add(&capture.listener);

    const tl = try ts.createToplevel();
    const dec = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    var dec_events: DecorationEvents = .{};
    dec.setListener(*DecorationEvents, DecorationEvents.listener, &dec_events);
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);

    // set_mode(server_side) -> request_mode fires with the mode -> the
    // compositor (capture) replies with sendConfigure(server_side).
    dec.setMode(.server_side);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(i32, 2), capture.mode); // server_side
    try std.testing.expectEqual(@as(usize, 1), dec_events.configure_count);
    try std.testing.expectEqual(@as(i32, 2), dec_events.mode);

    // unset_mode -> request_mode with no mode -> client_side configure.
    dec.unsetMode();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(@as(i32, 1), capture.mode); // client_side
    try std.testing.expectEqual(@as(usize, 2), dec_events.configure_count);
    try std.testing.expectEqual(@as(i32, 1), dec_events.mode);

    // Client destroys the decoration cleanly.
    dec.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.decoration.?.decorations.items.len);
}

test "decoration new_toplevel_decoration fires at creation; module sends no configure" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // L2: the compositor hook fires with the inserted Decoration.
    var capture: NewDecorationCapture = .{
        .listener = wire.Listener(*Decoration).init(NewDecorationCapture.notify),
    };
    ts.decoration.?.events.new_toplevel_decoration.add(&capture.listener);

    const tl = try ts.createToplevel();
    const dec = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    var dec_events: DecorationEvents = .{};
    dec.setListener(*DecorationEvents, DecorationEvents.listener, &dec_events);
    try ts.pump();

    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(ts.decoration.?.decorations.items[0], capture.decoration.?);
    // The module alone never self-configures: without a compositor
    // sendConfigure (the announce is the compositor's job via the signal),
    // no zxdg configure is sent — the existing happy-path tests keep their
    // client-driven configures.
    try std.testing.expectEqual(@as(usize, 0), dec_events.configure_count);
}

test "decoration second decoration on a toplevel -> already_constructed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const tl = try ts.createToplevel();
    _ = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);

    // Model decision (b): a second decoration object posts
    // already_constructed=1 and the client is killed. XD-2: creation
    // errors post on the MANAGER resource (wlroots XD:190), not the new
    // decoration.
    _ = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    var err_id: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, &err_id));
    try std.testing.expectEqual(ts.decoration_client.?.getId(), err_id);
}

test "decoration set_mode with invalid mode -> invalid_mode" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const tl = try ts.createToplevel();
    const dec = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try ts.pump();

    // Model decision (d): the XML mandates invalid_mode=3 for any mode
    // outside {1, 2}; wlroots/smithay/KWin do not raise it (documented
    // divergence).
    dec.setMode(@enumFromInt(3));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 3), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "decoration toplevel destroyed first -> orphaned" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const tl = try ts.createToplevel();
    const dec = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);

    // Model decision (c) + XD-4: the toplevel died before the decoration —
    // the orphaned=2 error is posted on the decoration resource AND the
    // resource is destroyed (wlroots XD:81-91), so the decorations list is
    // emptied.
    tl.toplevel.destroy();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 2), wl_display_get_protocol_error(ts.c_display.?, null, null));
    try std.testing.expectEqual(@as(usize, 0), ts.decoration.?.decorations.items.len);
    _ = dec;
}

test "decoration on a toplevel with a committed buffer -> unconfigured_buffer" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const tl = try ts.createToplevel();

    // Model decision (a), v1 semantics: a toplevel that already committed a
    // buffer must not be decorated. White-box: the client has no buffer
    // machinery here, so set the server-side committed-buffer mirror
    // directly (Surface.buffer mirrors current.buffer; the check only
    // tests presence).
    const srv_surface = ts.shell.?.toplevels.items[0].xdg_surface.surface;
    const fake: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    srv_surface.buffer = @ptrCast(@alignCast(fake));

    _ = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    var err_id: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, &err_id));
    // XD-2: the error posts on the manager resource (wlroots XD:181).
    try std.testing.expectEqual(ts.decoration_client.?.getId(), err_id);
}

test "decoration v2: get_toplevel_decoration on a committed toplevel is allowed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // D3: the v2 relaxations apply to v2-bound clients. The default init
    // bind is v1; re-bind the global at 2.
    const deco_client = try ts.bindDecorationManager(2);
    const tl = try ts.createToplevel();

    // White-box (same as the v1 test): the client has no buffer machinery
    // here, so set the server-side committed-buffer mirror directly.
    const srv_surface = ts.shell.?.toplevels.items[0].xdg_surface.surface;
    const fake: *anyopaque = @ptrFromInt(@as(usize, 0x1000));
    srv_surface.buffer = @ptrCast(@alignCast(fake));

    // v2: creation on a committed toplevel succeeds — no
    // unconfigured_buffer error (the XML: "creating an
    // xdg_toplevel_decoration from an xdg_toplevel which has a buffer
    // attached or committed is allowed"). A protocol error would fail the
    // pump with ClientDispatchFailed.
    _ = try deco_client.getToplevelDecoration(tl.toplevel);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);
}

test "decoration v2: mode retained across destroy/re-create" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: RequestModeCapture = .{
        .listener = wire.Listener(*RequestMode).init(RequestModeCapture.notify),
    };
    ts.decoration.?.events.request_mode.add(&capture.listener);

    const deco_client = try ts.bindDecorationManager(2);
    const tl = try ts.createToplevel();
    var xs_events: XdgSurfaceEvents = .{};
    tl.xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    const dec = try deco_client.getToplevelDecoration(tl.toplevel);
    var dec_events: DecorationEvents = .{};
    dec.setListener(*DecorationEvents, DecorationEvents.listener, &dec_events);
    try ts.pump();

    // Establish server_side: set_mode -> compositor reply (capture) ->
    // configure -> ack.
    dec.setMode(.server_side);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
    tl.xdg_surface.ackConfigure(xs_events.serial);
    try ts.pump();
    try std.testing.expectEqual(@as(?Mode, .server_side), ts.decoration.?.decorations.items[0].current_mode);

    // Destroy WITHOUT a surface commit: the mode is retained (D3).
    dec.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.decoration.?.decorations.items.len);

    // Re-create: the new decoration inherits the retained mode — the
    // current/pending/scheduled state is seeded, so no configure is
    // re-sent (the client already draws the retained mode).
    const dec2 = try deco_client.getToplevelDecoration(tl.toplevel);
    var dec2_events: DecorationEvents = .{};
    dec2.setListener(*DecorationEvents, DecorationEvents.listener, &dec2_events);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);
    const dec_obj2 = ts.decoration.?.decorations.items[0];
    try std.testing.expectEqual(@as(?Mode, .server_side), dec_obj2.current_mode);
    try std.testing.expectEqual(@as(?Mode, .server_side), dec_obj2.pending_mode);
    try std.testing.expectEqual(@as(?Mode, .server_side), dec_obj2.scheduled_mode);
    try std.testing.expectEqual(@as(usize, 0), dec2_events.configure_count);
}

test "decoration v2: a commit after destroy clears the retained mode" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: RequestModeCapture = .{
        .listener = wire.Listener(*RequestMode).init(RequestModeCapture.notify),
    };
    ts.decoration.?.events.request_mode.add(&capture.listener);

    const deco_client = try ts.bindDecorationManager(2);
    const tl = try ts.createToplevel();
    var xs_events: XdgSurfaceEvents = .{};
    tl.xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    const dec = try deco_client.getToplevelDecoration(tl.toplevel);
    var dec_events: DecorationEvents = .{};
    dec.setListener(*DecorationEvents, DecorationEvents.listener, &dec_events);
    try ts.pump();

    // Establish server_side, then destroy (retention recorded).
    dec.setMode(.server_side);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), dec_events.configure_count);
    tl.xdg_surface.ackConfigure(xs_events.serial);
    try ts.pump();
    try std.testing.expectEqual(@as(?Mode, .server_side), ts.decoration.?.decorations.items[0].current_mode);
    dec.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.decoration.?.decorations.items.len);

    // The next surface commit after the destroy reverts to client-side
    // (the XML's destroy text) — the retention expires.
    tl.surface.commit();
    try ts.pump();

    // Re-create: no retained mode — the decoration starts unset.
    _ = try deco_client.getToplevelDecoration(tl.toplevel);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.decoration.?.decorations.items.len);
    const dec_obj2 = ts.decoration.?.decorations.items[0];
    try std.testing.expectEqual(@as(?Mode, null), dec_obj2.current_mode);
    try std.testing.expectEqual(@as(?Mode, null), dec_obj2.pending_mode);
    try std.testing.expectEqual(@as(?Mode, null), dec_obj2.scheduled_mode);
}

test "decoration mode configure rides the xdg configure/ack cycle (XD-1)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var capture: RequestModeCapture = .{
        .listener = wire.Listener(*RequestMode).init(RequestModeCapture.notify),
    };
    ts.decoration.?.events.request_mode.add(&capture.listener);

    const tl = try ts.createToplevel();
    var xs_events: XdgSurfaceEvents = .{};
    tl.xdg_surface.setListener(*XdgSurfaceEvents, XdgSurfaceEvents.listener, &xs_events);
    const dec = try ts.decoration_client.?.getToplevelDecoration(tl.toplevel);
    var dec_events: DecorationEvents = .{};
    dec.setListener(*DecorationEvents, DecorationEvents.listener, &dec_events);
    try ts.pump();

    // set_mode(server_side) -> the compositor schedules a toplevel
    // configure; the zxdg decoration configure arrives in the SAME
    // roundtrip as the xdg_surface.configure (XD-1, wlroots XD:93-113).
    dec.setMode(.server_side);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), xs_events.configure_count);
    try std.testing.expectEqual(@as(usize, 1), dec_events.configure_count);
    try std.testing.expectEqual(@as(i32, 2), dec_events.mode); // server_side

    // The mode is NOT applied until the client acks the xdg configure.
    const dec_obj = ts.decoration.?.decorations.items[0];
    try std.testing.expectEqual(@as(?Mode, null), dec_obj.current_mode);
    try std.testing.expectEqual(@as(usize, 1), dec_obj.configure_list.items.len);

    // Ack the matching xdg configure: the mode is applied (wlroots
    // XD:115-146).
    tl.xdg_surface.ackConfigure(xs_events.serial);
    try ts.pump();
    try std.testing.expectEqual(@as(?Mode, .server_side), dec_obj.current_mode);
    try std.testing.expectEqual(@as(?Mode, .server_side), dec_obj.pending_mode);
    try std.testing.expectEqual(@as(usize, 0), dec_obj.configure_list.items.len);
}
