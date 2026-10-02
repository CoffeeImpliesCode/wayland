//! zwlr_foreign_toplevel_manager_v1 (wlroots/wlr-foreign-toplevel-
//! management-unstable-v1, v3): taskbars and docks get the compositor's
//! xdg toplevels and ask for state changes on them.
//!
//! Scope: the manager global, the per-client
//! zwlr_foreign_toplevel_manager_v1 bindings and the
//! zwlr_foreign_toplevel_handle_v1 objects the compositor hands out.
//! The xdg side (src/shell/xdg.zig) is observed, never edited: the module
//! subscribes to `XdgShell.events.new_toplevel` and, per announced
//! toplevel, to `events.set_title`, `events.set_app_id` and
//! `events.destroy`. Everything the xdg toplevel cannot signal is a
//! compositor hook on this module — `notifyState`, `notifyOutputEnter`,
//! `notifyOutputLeave`, `notifyParent` — and each names the xdg signal
//! (or the absence of one) that motivates it.
//!
//! Identity. zwlr_foreign_toplevel_handle_v1 has no get_id, so the
//! server-side object IS the identity: `Binding.handles` holds exactly
//! one Handle per (binding, xdg toplevel) pair for the whole toplevel
//! lifetime, and every title / app_id / state / output re-send goes out
//! on THAT resource. The client correlates the re-sends with the object
//! the manager introduced in the `toplevel` event and with no other.
//!
//! Batching. `done` "is sent after all changes in the toplevel state have
//! been sent" — it is what the XML calls "seen as atomic". One change
//! (an announcement, a title re-send, a state re-send) marks the handles
//! it touched dirty and then flushes: `done` goes out exactly once per
//! touched handle, never once per property event. A handle that is
//! already `closed` is skipped, so `closed` really is the last event.
//!
//! State. The handle advertises `XdgToplevel.current` — the state the
//! client last acked, which is the state a taskbar must render. wlroots
//! reads `wlr_xdg_toplevel.state` for the same reason.
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, shell/xdg.zig,
//! compositor/seat.zig, compositor/surface.zig.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const seat_mod = @import("../compositor/seat.zig");
const surface_mod = @import("../compositor/surface.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const xdg_mod = @import("xdg.zig");

const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const log_tag = "foreign_toplevel";

pub const ForeignToplevelManager = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The xdg shell whose toplevels this protocol advertises.
    shell: *xdg_mod.XdgShell,
    /// The seat `activate` acts on. Null when the compositor has none:
    /// activate is then ignored — the XML declares no error for it, so it
    /// is never a protocol error.
    seat: ?*seat_mod.Seat,
    /// The manager global, for teardown.
    global: ?*wire.Global = null,
    /// One entry per bound zwlr_foreign_toplevel_manager_v1, in bind
    /// order. A binding is one client's view of the world: it owns the
    /// handles it was told about and nothing else.
    bindings: std.ArrayList(*Binding) = .empty,
    new_toplevel_listener: wire.Listener(*xdg_mod.XdgToplevel),

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        shell: *xdg_mod.XdgShell,
        seat: ?*seat_mod.Seat,
    ) error{ OutOfMemory, GlobalCreateFailed }!*ForeignToplevelManager {
        const self = try allocator.create(ForeignToplevelManager);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .shell = shell,
            .seat = seat,
            .new_toplevel_listener = wire.Listener(*xdg_mod.XdgToplevel).init(onNewToplevel),
        };
        errdefer self.bindings.deinit(allocator);
        self.global = try display.addGlobal(
            server.zwlr.ForeignToplevelManagerV1,
            *ForeignToplevelManager,
            bindManager,
            server.zwlr.ForeignToplevelManagerV1.generated_version,
            self,
        );
        shell.events.new_toplevel.add(&self.new_toplevel_listener);
        log.debug("foreign toplevel manager created", io, log_cfg, log_tag, .{});
        return self;
    }

    pub fn deinit(self: *ForeignToplevelManager) void {
        // The shell outlives the manager (main's defer order): detach
        // before freeing so a later new_toplevel emit cannot call into
        // the freed struct.
        self.new_toplevel_listener.link.remove();
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        // Destroying the binding resources cascades into bindingDestroy,
        // which frees each Binding and closes the handles it announced.
        while (self.bindings.items.len > 0) {
            self.bindings.items[0].resource.destroy();
        }
        self.bindings.deinit(allocator);
        allocator.destroy(self);
    }

    /// The toplevel's state changed: re-send `state` to every binding's
    /// handle for it, closed by one `done`.
    ///
    /// xdg-shell has no "a state changed" signal — a state rides a
    /// configure and lands in `current` when the client acks — so this is
    /// the compositor's hook. A toplevel no client knows about (every
    /// binding sent `stop`) sends nothing.
    pub fn notifyState(self: *ForeignToplevelManager, toplevel: *xdg_mod.XdgToplevel) void {
        for (self.bindings.items) |b| {
            if (b.findHandle(toplevel)) |h| h.sendState();
        }
        self.flushDone();
    }

    /// The toplevel became visible on `output`
    /// (zwlr_foreign_toplevel_handle_v1.output_enter). The xdg toplevel
    /// carries no output list, so this is the compositor's hook. An
    /// output already on the handle is not announced twice: the XML
    /// guarantees one enter per leave, so a repeated enter would break
    /// the pairing.
    pub fn notifyOutputEnter(self: *ForeignToplevelManager, toplevel: *xdg_mod.XdgToplevel, output: *server.wl.Output) void {
        for (self.bindings.items) |b| {
            const h = b.findHandle(toplevel) orelse continue;
            if (h.hasOutput(output)) continue;
            h.outputs.append(self.allocator, output) catch {
                output.getClient().postNoMemory();
                continue;
            };
            h.resource.sendOutputEnter(output);
            h.dirty = true;
        }
        self.flushDone();
    }

    /// The toplevel stopped being visible on `output` (output_leave).
    /// Only sent for an output an enter announced, which is exactly the
    /// XML's guarantee.
    pub fn notifyOutputLeave(self: *ForeignToplevelManager, toplevel: *xdg_mod.XdgToplevel, output: *server.wl.Output) void {
        for (self.bindings.items) |b| {
            const h = b.findHandle(toplevel) orelse continue;
            if (!h.hasOutput(output)) continue;
            if (std.mem.indexOfScalar(*server.wl.Output, h.outputs.items, output)) |idx| {
                _ = h.outputs.orderedRemove(idx);
            }
            h.resource.sendOutputLeave(output);
            h.dirty = true;
        }
        self.flushDone();
    }

    /// The toplevel's xdg parent changed. `parent` is a v3 event and the
    /// parent handle may not exist for this client (another binding, a
    /// client that sent `stop`, or a parent this client was never told
    /// about), in which case NULL is the honest answer.
    ///
    /// xdg_toplevel.set_parent has no signal, so this is the compositor's
    /// hook. The parent is also sent with the handle's first batch, so a
    /// toplevel that never changes its parent needs no call.
    pub fn notifyParent(self: *ForeignToplevelManager, toplevel: *xdg_mod.XdgToplevel) void {
        for (self.bindings.items) |b| {
            if (b.findHandle(toplevel)) |h| h.sendParent();
        }
        self.flushDone();
    }

    /// The rectangle the client last set with set_rectangle, or null when
    /// it set none (or removed it with width = height = 0). Surface-local
    /// geometry — the hint the XML describes for e.g. minimizing.
    pub fn rectangle(self: *ForeignToplevelManager, toplevel: *xdg_mod.XdgToplevel) ?geom.Rect {
        for (self.bindings.items) |b| {
            if (b.findHandle(toplevel)) |h| return h.rect;
        }
        return null;
    }

    /// Tell a binding the compositor is done with it (`finished`). The
    /// event destroys the manager resource, so the client must not send
    /// anything else on it; every handle the binding announced goes inert
    /// with it (bindingDestroy), which is what the XML's "the client
    /// should free any resources associated with it" means.
    pub fn finish(self: *ForeignToplevelManager, res: *server.zwlr.ForeignToplevelManagerV1) void {
        for (self.bindings.items) |b| {
            if (b.resource != res) continue;
            // destroySendFinished posts the event AND destroys the
            // resource, which runs bindingDestroy and unlinks `b`; the
            // return leaves the loop before the shifted slice is read.
            res.destroySendFinished();
            return;
        }
    }

    /// Close the batch: one `done` per handle that has unsent property
    /// events. Every change funnels through here exactly once, which is
    /// what makes `done` mean "all changes so far are visible".
    fn flushDone(mgr: *ForeignToplevelManager) void {
        for (mgr.bindings.items) |b| {
            for (b.handles.items) |h| {
                if (!h.dirty or h.closed) continue;
                h.dirty = false;
                h.resource.sendDone();
            }
        }
    }
};

/// One bound zwlr_foreign_toplevel_manager_v1: a client's view of the
/// compositor's toplevels.
const Binding = struct {
    manager: *ForeignToplevelManager,
    resource: *server.zwlr.ForeignToplevelManagerV1,
    /// One handle per announced toplevel, in announcement order. The
    /// handle is the protocol identity of that toplevel for this client
    /// (zwlr_foreign_toplevel_handle_v1 has no get_id), so the entry
    /// lives exactly as long as the toplevel does.
    handles: std.ArrayList(*Handle),
    /// The client sent `stop`: it no longer wants toplevel events. The
    /// XML still allows further toplevel events until `finished`, so
    /// existing handles keep working — only the announcement is gated.
    stopped: bool = false,

    /// The handle for `toplevel` in this binding, or null.
    fn findHandle(b: *Binding, toplevel: *xdg_mod.XdgToplevel) ?*Handle {
        for (b.handles.items) |h| {
            if (h.toplevel == toplevel) return h;
        }
        return null;
    }

    /// Introduce `toplevel` to this client: a fresh handle plus the full
    /// first batch. The closing `done` is the caller's flush.
    fn announce(b: *Binding, toplevel: *xdg_mod.XdgToplevel) void {
        if (b.stopped) return;
        const mgr = b.manager;
        const allocator = mgr.allocator;
        const h_res = server.zwlr.ForeignToplevelHandleV1.create(
            b.resource.getClient(),
            b.resource.getVersion(),
            0,
        ) catch {
            b.resource.getClient().postNoMemory();
            return;
        };
        const h = allocator.create(Handle) catch {
            h_res.destroy();
            b.resource.getClient().postNoMemory();
            return;
        };
        h.* = .{
            .binding = b,
            .toplevel = toplevel,
            .resource = h_res,
            .outputs = .empty,
            .title_listener = wire.Listener(*xdg_mod.XdgToplevel).init(onToplevelTitle),
            .app_id_listener = wire.Listener(*xdg_mod.XdgToplevel).init(onToplevelAppId),
            .destroy_listener = wire.Listener(*xdg_mod.XdgToplevel).init(onToplevelDestroy),
        };
        h_res.setHandler(*Handle, handleRequest, handleDestroy, h);
        b.handles.append(allocator, h) catch {
            // No listener is attached yet, so destroying the resource
            // cannot reach the struct.
            h_res.destroy();
            allocator.destroy(h);
            b.resource.getClient().postNoMemory();
            return;
        };
        toplevel.events.set_title.add(&h.title_listener);
        toplevel.events.set_app_id.add(&h.app_id_listener);
        toplevel.events.destroy.add(&h.destroy_listener);
        // The manager introduces the object FIRST: the XML says "All
        // initial details of the toplevel(title, app_id, states, etc.)
        // will be sent immediately after this event". libwayland-client
        // drops events for object ids it does not know yet, so the
        // details must not precede it.
        b.resource.sendToplevel(h_res);
        h.sendTitle();
        h.sendAppId();
        h.sendState();
        h.sendParent();
    }
};

/// One zwlr_foreign_toplevel_handle_v1: the protocol identity of one xdg
/// toplevel for one client.
const Handle = struct {
    binding: *Binding,
    toplevel: *xdg_mod.XdgToplevel,
    resource: *server.zwlr.ForeignToplevelHandleV1,
    /// The toplevel is gone: `closed` went out and the resource answers
    /// `destroy` only. The XML's own rule: "The toplevel itself becomes
    /// inert so any requests will be ignored except the destroy
    /// request."
    closed: bool = false,
    /// Property events went out on this handle and the batch that closes
    /// them has not sent its `done` yet.
    dirty: bool = false,
    /// Outputs this handle was told it is visible on, in enter order.
    outputs: std.ArrayList(*server.wl.Output),
    /// The last rectangle set with set_rectangle, in surface-local
    /// coordinates; null when none is set.
    rect: ?geom.Rect = null,
    /// The xdg listeners are attached when the handle is announced and
    /// detached exactly once, by teardown.
    detached: bool = false,
    title_listener: wire.Listener(*xdg_mod.XdgToplevel),
    app_id_listener: wire.Listener(*xdg_mod.XdgToplevel),
    destroy_listener: wire.Listener(*xdg_mod.XdgToplevel),

    fn hasOutput(h: *const Handle, output: *server.wl.Output) bool {
        return std.mem.indexOfScalar(*server.wl.Output, h.outputs.items, output) != null;
    }

    fn sendTitle(h: *Handle) void {
        if (h.closed) return;
        // The title is per-map in xdg-shell: a toplevel whose client has
        // not sent set_title yet has none, and the empty string is the
        // honest wire value.
        const z = h.zeroTerminated(h.toplevel.title) orelse return;
        defer h.binding.manager.allocator.free(z);
        h.resource.sendTitle(z);
        h.dirty = true;
    }

    fn sendAppId(h: *Handle) void {
        if (h.closed) return;
        const z = h.zeroTerminated(h.toplevel.app_id) orelse return;
        defer h.binding.manager.allocator.free(z);
        h.resource.sendAppId(z);
        h.dirty = true;
    }

    /// The NUL-terminated copy a string property (title, app_id) needs,
    /// or null when the copy could not be made.
    ///
    /// xdg-shell owns both properties as plain []const u8 (xdg.zig:822-825
    /// — it frees the previous copy with allocator.free, so neither is
    /// sentinel-terminated), while a Wayland string argument IS
    /// NUL-terminated (wayland.xml <arg type="string"/>: "a string is
    /// NUL-terminated") — that is what the generated sendTitle/sendAppId
    /// take [*:0]const u8. The bytes therefore go out on a copy that
    /// lives exactly as long as the send: wl_resource_post_event_array
    /// (what the generated send calls) marshals into the connection
    /// buffer before it returns, so the copy is dead afterwards and no
    /// permanent NUL copy is kept per handle — the title changes on
    /// every keystroke of some editors and the handle list can be long.
    ///
    /// Failing to copy is out of memory, which libwayland answers by
    /// killing the client; no property event goes out, so the handle
    /// stays clean and its pending `done` is not opened.
    fn zeroTerminated(h: *Handle, text: ?[]const u8) ?[:0]const u8 {
        return h.binding.manager.allocator.dupeZ(u8, text orelse "") catch {
            h.resource.getClient().postNoMemory();
            return null;
        };
    }

    /// The state set the handle advertises, derived from the xdg
    /// toplevel's last-acked state. Entries go out in protocol enum
    /// order, the same convention xdg.zig uses for
    /// xdg_toplevel.configure; fullscreen is a v2 event and is filtered
    /// out for older clients.
    fn sendState(h: *Handle) void {
        if (h.closed) return;
        const st = &h.toplevel.current;
        // SAFETY: only the first `n` entries are read; sendState fills
        // exactly those from the four states below before it marshals.
        var buf: [4]u32 = undefined;
        var n: usize = 0;
        if (st.maximized) {
            buf[n] = @intFromEnum(server.zwlr.ForeignToplevelHandleV1.State.maximized);
            n += 1;
        }
        if (st.minimized) {
            buf[n] = @intFromEnum(server.zwlr.ForeignToplevelHandleV1.State.minimized);
            n += 1;
        }
        if (st.activated) {
            buf[n] = @intFromEnum(server.zwlr.ForeignToplevelHandleV1.State.activated);
            n += 1;
        }
        if (h.resource.getVersion() >= 2 and st.fullscreen) {
            buf[n] = @intFromEnum(server.zwlr.ForeignToplevelHandleV1.State.fullscreen);
            n += 1;
        }
        // libwayland marshals the array synchronously; a stack buffer is
        // safe (xdg.zig configure does the same).
        var array: server.wl.Array = .{
            .size = n * @sizeOf(u32),
            .alloc = buf.len * @sizeOf(u32),
            .data = &buf,
        };
        h.resource.sendState(&array);
        h.dirty = true;
    }

    /// The parent handle for the toplevel's xdg parent, or NULL. A
    /// parent this client was never told about has no handle, and the
    /// XML's "No event is emitted when the parent handle is destroyed by
    /// the client" makes NULL the right answer for it.
    fn sendParent(h: *Handle) void {
        if (h.closed or h.resource.getVersion() < 3) return;
        const parent = if (h.toplevel.parent) |p| h.binding.findHandle(p) else null;
        h.resource.sendParent(if (parent) |p| p.resource else null);
        h.dirty = true;
    }

    /// The toplevel is gone: announce `closed`, stop observing it and
    /// drop the struct, leaving the wire resource alive and inert.
    fn close(h: *Handle) void {
        if (h.closed) return;
        h.closed = true;
        h.resource.sendClosed();
        h.teardown();
        const allocator = h.binding.manager.allocator;
        h.resource.setHandler(?*Handle, deadHandleHandler, null, null);
        allocator.destroy(h);
    }

    /// Detach from the xdg toplevel, unlink from the binding and free
    /// the per-handle lists. Idempotent: `close` and the resource's own
    /// destroy handler can both reach a handle, and only the first one
    /// frees the struct.
    fn teardown(h: *Handle) void {
        if (!h.detached) {
            h.detached = true;
            h.title_listener.link.remove();
            h.app_id_listener.link.remove();
            h.destroy_listener.link.remove();
        }
        const b = h.binding;
        if (std.mem.indexOfScalar(*Handle, b.handles.items, h)) |idx| {
            _ = b.handles.orderedRemove(idx);
        }
        const allocator = b.manager.allocator;
        h.outputs.deinit(allocator);
    }
};

fn bindManager(client_wire: *wire.Client, mgr: *ForeignToplevelManager, version: u32, id: u32) void {
    const resource = server.zwlr.ForeignToplevelManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    const b = mgr.allocator.create(Binding) catch {
        resource.destroy();
        client_wire.postNoMemory();
        return;
    };
    b.* = .{ .manager = mgr, .resource = resource, .handles = .empty };
    resource.setHandler(*Binding, managerRequest, bindingDestroy, b);
    mgr.bindings.append(mgr.allocator, b) catch {
        // setHandler already ran, so destroying the resource reaches the
        // struct through bindingDestroy.
        resource.destroy();
        client_wire.postNoMemory();
        return;
    };
    log.info("foreign toplevel manager bound (id {d})", mgr.io, mgr.log_cfg, log_tag, .{id});
    // The client is told about the toplevels that ALREADY exist: the
    // protocol is framed as a list, not as a stream of new windows, so a
    // panel that binds late still gets the full list.
    for (mgr.shell.toplevels.items) |t| b.announce(t);
    mgr.flushDone();
}

fn managerRequest(
    resource: *server.zwlr.ForeignToplevelManagerV1,
    request: server.zwlr.ForeignToplevelManagerV1.Request,
    b: *Binding,
) void {
    _ = resource;
    switch (request) {
        // "Indicates the client no longer wishes to receive events for
        // new toplevels. However the compositor may emit further
        // toplevel_created events, until the finished event is emitted.
        // The client must not send any more requests after this one" —
        // and stop is the interface's only request, so nothing follows.
        .stop => {
            b.stopped = true;
            log.debug("foreign toplevel manager: client stopped", b.manager.io, b.manager.log_cfg, log_tag, .{});
        },
    }
}

fn bindingDestroy(resource: *server.zwlr.ForeignToplevelManagerV1, b: *Binding) void {
    _ = resource;
    const mgr = b.manager;
    // Every handle this binding announced goes with it: the client was
    // told the manager is finished, so a handle it still holds is inert.
    // close() unlinks, which is what makes this loop terminate.
    while (b.handles.items.len > 0) b.handles.items[0].close();
    if (std.mem.indexOfScalar(*Binding, mgr.bindings.items, b)) |idx| {
        _ = mgr.bindings.orderedRemove(idx);
    }
    const allocator = mgr.allocator;
    b.handles.deinit(allocator);
    allocator.destroy(b);
}

// ---------------------------------------------------------------------------
// xdg signals
// ---------------------------------------------------------------------------

fn onNewToplevel(listener: *wire.Listener(*xdg_mod.XdgToplevel), toplevel: *xdg_mod.XdgToplevel) void {
    const mgr: *ForeignToplevelManager = @fieldParentPtr("new_toplevel_listener", listener);
    for (mgr.bindings.items) |b| b.announce(toplevel);
    mgr.flushDone();
}

fn onToplevelTitle(listener: *wire.Listener(*xdg_mod.XdgToplevel), toplevel: *xdg_mod.XdgToplevel) void {
    _ = toplevel;
    const h: *Handle = @fieldParentPtr("title_listener", listener);
    h.sendTitle();
    h.binding.manager.flushDone();
}

fn onToplevelAppId(listener: *wire.Listener(*xdg_mod.XdgToplevel), toplevel: *xdg_mod.XdgToplevel) void {
    _ = toplevel;
    const h: *Handle = @fieldParentPtr("app_id_listener", listener);
    h.sendAppId();
    h.binding.manager.flushDone();
}

fn onToplevelDestroy(listener: *wire.Listener(*xdg_mod.XdgToplevel), toplevel: *xdg_mod.XdgToplevel) void {
    _ = toplevel;
    const h: *Handle = @fieldParentPtr("destroy_listener", listener);
    h.close();
}

// ---------------------------------------------------------------------------
// zwlr_foreign_toplevel_handle_v1
// ---------------------------------------------------------------------------

fn handleRequest(
    res: *server.zwlr.ForeignToplevelHandleV1,
    request: server.zwlr.ForeignToplevelHandleV1.Request,
    h: *Handle,
) void {
    if (h.closed) {
        // Inert: only destroy is honoured, the XML's own rule for a
        // handle whose toplevel is gone.
        switch (request) {
            .destroy => res.destroy(),
            else => {},
        }
        return;
    }
    switch (request) {
        .set_maximized => applyMaximized(h, true),
        .unset_maximized => applyMaximized(h, false),
        .set_minimized => applyMinimized(h, true),
        .unset_minimized => applyMinimized(h, false),
        .activate => |r| activate(h, r.seat),
        .close => h.toplevel.sendClose(),
        .set_rectangle => |r| {
            // "Setting width=height=0 removes the already-set rectangle",
            // and zwlr_foreign_toplevel_handle_v1.error.invalid_rectangle
            // is "the provided rectangle is invalid": a negative extent
            // is the only shape the XML rules out.
            if (r.width < 0 or r.height < 0) {
                res.postError(.invalid_rectangle, "zwlr_foreign_toplevel_handle_v1.set_rectangle: negative size");
                return;
            }
            if (r.width == 0 and r.height == 0) {
                h.rect = null;
                return;
            }
            h.rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
        },
        .destroy => res.destroy(),
        .set_fullscreen => applyFullscreen(h, true),
        .unset_fullscreen => applyFullscreen(h, false),
    }
}

/// The client asked for a maximize state change. The request arrives
/// from a shell panel, so the COMPOSITOR is the one deciding: the state
/// goes into `scheduled` and a configure carries it, the same direction
/// main.zig's onToplevelMaximize uses when the client asks the other way
/// round. The handle only advertises the change once the client acks it
/// (that is `current`, and the compositor calls `notifyState`), which is
/// what the XML promises: "If the maximized state actually changes, this
/// will be indicated by the state event."
fn applyMaximized(h: *Handle, want: bool) void {
    const t = h.toplevel;
    t.scheduled.maximized = want;
    // Leaving maximize hands the geometry back to the client: there is no
    // stored pre-maximize size, the same reason main.zig zeroes it.
    if (!want) {
        t.scheduled.width = 0;
        t.scheduled.height = 0;
    }
    t.scheduleConfigure() catch {
        log.warn("foreign toplevel: maximize configure failed", h.binding.manager.io, h.binding.manager.log_cfg, log_tag, .{});
    };
}

/// xdg_toplevel has no minimized STATE (xdg-shell.xml set_minimized:
/// "There is no way to tell the client that it is minimized"), so there
/// is no configure to ride and no ack to wait for. The record IS the
/// compositor's decision, so both buffers are written: `current` is what
/// the handle advertises, `scheduled` keeps the two in step for a later
/// policy read.
fn applyMinimized(h: *Handle, want: bool) void {
    const mgr = h.binding.manager;
    const t = h.toplevel;
    t.scheduled.minimized = want;
    t.current.minimized = want;
    h.sendState();
    mgr.flushDone();
}

/// Fullscreen: the compositor owns the geometry, so the state is
/// scheduled and configured; `current` follows on the ack. Leaving
/// fullscreen hands the size back to the client (main.zig's
/// onToplevelFullscreen makes the same choice). The output the request
/// named is a hint the XML calls optional, and this compositor has one
/// output, so no box is derived here.
fn applyFullscreen(h: *Handle, want: bool) void {
    const t = h.toplevel;
    t.scheduled.fullscreen = want;
    t.scheduled.width = 0;
    t.scheduled.height = 0;
    t.scheduleConfigure() catch {
        log.warn("foreign toplevel: fullscreen configure failed", h.binding.manager.io, h.binding.manager.log_cfg, log_tag, .{});
    };
}

/// activate: focus the toplevel's surface on the named seat. The seat
/// argument must be the compositor's own (the F-SEL-5 pattern,
/// data_device.zig get_data_device); a foreign or inert seat is ignored
/// — the XML declares no error for it, and killing a panel over a bad
/// seat argument would be worse than doing nothing. The activated state
/// itself arrives with the ordinary focus configure, so no state event is
/// sent here.
fn activate(h: *Handle, seat_res: *server.wl.Seat) void {
    const mgr = h.binding.manager;
    const seat = mgr.seat orelse return;
    const ud = seat_res.getUserData() orelse return;
    const arg: *seat_mod.Seat = @ptrCast(@alignCast(ud));
    if (arg != seat) return;
    seat.setKeyboardFocus(h.toplevel.xdg_surface.surface);
}

fn handleDestroy(res: *server.zwlr.ForeignToplevelHandleV1, h: *Handle) void {
    _ = res;
    // The client dropped the handle (or it died with the client): stop
    // observing the toplevel and drop the struct. A handle that was
    // already closed has a dead handler, so this only ever runs on a
    // live one.
    h.teardown();
    const allocator = h.binding.manager.allocator;
    allocator.destroy(h);
}

/// Request handler for inerted handles (the toplevel is gone, or its
/// manager finished). Nothing is dereferenced; `destroy` still works.
fn deadHandleHandler(
    resource: *server.zwlr.ForeignToplevelHandleV1,
    request: server.zwlr.ForeignToplevelHandleV1.Request,
    data: ?*Handle,
) void {
    _ = data;
    switch (request) {
        .set_maximized => {},
        .unset_maximized => {},
        .set_minimized => {},
        .unset_minimized => {},
        .activate => {},
        .close => {},
        .set_rectangle => {},
        .set_fullscreen => {},
        .unset_fullscreen => {},
        .destroy => resource.destroy(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const posix = std.posix;

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

/// Longest string a test capture keeps, plus its NUL.
const str_cap = 32;

/// How many surfaces one test may create (one listener slot each).
const max_surfaces = 4;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    wm_base_name: ?u32 = null,
    seat_name: ?u32 = null,
    foreign_toplevel_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "xdg_wm_base")) {
                    data.wm_base_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "zwlr_foreign_toplevel_manager_v1")) {
                    data.foreign_toplevel_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Client-side capture of a zwlr_foreign_toplevel_handle_v1.
const HandleEvents = struct {
    // SAFETY: written by record() up to title_count, NUL-terminated;
    // title() slices on that NUL, so no slot is ever read uninitialised.
    titles: [4][str_cap]u8 = undefined,
    title_count: usize = 0,
    // SAFETY: written by record() up to app_id_count, NUL-terminated;
    // appId() slices on that NUL.
    app_ids: [4][str_cap]u8 = undefined,
    app_id_count: usize = 0,
    state_count: usize = 0,
    /// The states of the most recent state event as a bit set (bit n set
    /// = state value n present), so a change is observable without
    /// depending on the array order the compositor chose.
    last_states: u8 = 0,
    done_count: usize = 0,
    closed_count: usize = 0,
    output_enter_count: usize = 0,
    output_leave_count: usize = 0,
    parent_count: usize = 0,
    last_parent_null: bool = true,

    fn listener(handle: *client.zwlr.ForeignToplevelHandleV1, event: client.zwlr.ForeignToplevelHandleV1.Event, data: *HandleEvents) void {
        _ = handle;
        switch (event) {
            .title => |e| record(&data.titles, &data.title_count, e.title),
            .app_id => |e| record(&data.app_ids, &data.app_id_count, e.app_id),
            .state => |e| {
                data.state_count += 1;
                var bits: u8 = 0;
                for (e.state.slice(u32)) |v| {
                    if (v >= @bitSizeOf(u8)) continue;
                    bits |= @as(u8, 1) << @intCast(v);
                }
                data.last_states = bits;
            },
            .done => data.done_count += 1,
            .closed => data.closed_count += 1,
            .output_enter => data.output_enter_count += 1,
            .output_leave => data.output_leave_count += 1,
            .parent => |e| {
                data.parent_count += 1;
                data.last_parent_null = e.parent == null;
            },
        }
    }

    /// The i-th captured string. sliceTo reads the NUL the recorder
    /// wrote, so a fixed-size capture buffer is safe (std.mem.span would
    /// read past it).
    fn title(data: *const HandleEvents, i: usize) []const u8 {
        return std.mem.sliceTo(data.titles[i][0..], 0);
    }

    fn appId(data: *const HandleEvents, i: usize) []const u8 {
        return std.mem.sliceTo(data.app_ids[i][0..], 0);
    }
};

fn record(buf: *[4][str_cap]u8, count: *usize, value: [*:0]const u8) void {
    if (count.* >= buf.len) return;
    const src = std.mem.span(value);
    // Leave room for the NUL the reader slices on; a longer string is
    // truncated, which a capture buffer is free to do.
    const n = @min(src.len, buf[count.*].len - 1);
    @memcpy(buf[count.*][0..n], src[0..n]);
    buf[count.*][n] = 0;
    count.* += 1;
}

/// Client-side capture of a zwlr_foreign_toplevel_manager_v1. The
/// listener on each announced handle is attached from inside the
/// `toplevel` handler so it is live for the details that follow in the
/// same batch.
const ManagerEvents = struct {
    toplevel_count: usize = 0,
    finished_count: usize = 0,
    last: ?*client.zwlr.ForeignToplevelHandleV1 = null,
    handles: HandleEvents = .{},

    fn listener(resource: *client.zwlr.ForeignToplevelManagerV1, event: client.zwlr.ForeignToplevelManagerV1.Event, data: *ManagerEvents) void {
        _ = resource;
        switch (event) {
            .toplevel => |e| {
                data.toplevel_count += 1;
                e.toplevel.setListener(*HandleEvents, HandleEvents.listener, &data.handles);
                data.last = e.toplevel;
            },
            .finished => data.finished_count += 1,
        }
    }
};

/// Client-side capture of the xdg_toplevel the handle's `close` must
/// reach.
const ClientToplevelEvents = struct {
    close_count: usize = 0,
    configure_count: usize = 0,

    fn listener(t: *client.xdg.Toplevel, event: client.xdg.Toplevel.Event, data: *ClientToplevelEvents) void {
        _ = t;
        switch (event) {
            .close => data.close_count += 1,
            .configure => data.configure_count += 1,
            // The harness binds xdg_wm_base at the newest version, so the
            // client sees these; the arms exist for the exhaustive switch
            // over the wire event enum.
            .configure_bounds => {},
            .wm_capabilities => {},
        }
    }
};

/// One surface-destroy listener slot. main.zig's ToplevelListeners is the
/// same shape (a back pointer plus the listeners): @fieldParentPtr walks
/// up from the listener FIELD to its owner, and an array field has no way
/// back to the struct that holds it, so the array holds these slots
/// instead of bare listeners.
const SurfaceListenerSlot = struct {
    ts: *TestServer,
    listener: wire.Listener(*surface_mod.Surface),
};

/// A compositor + xdg shell + seat + foreign-toplevel manager and one
/// in-memory client, for wire roundtrips.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    shell: ?*xdg_mod.XdgShell = null,
    seat: ?*seat_mod.Seat = null,
    ft: ?*ForeignToplevelManager = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wm_base: ?*client.xdg.WmBase = null,
    wl_seat: ?*client.wl.Seat = null,
    /// The registry proxy, kept so a test can bind the panel global at
    /// the moment it wants the panel to see the world.
    registry: ?*client.wl.Registry = null,
    foreign_toplevel_name: ?u32 = null,
    /// One surface-destroy listener per surface the tests create:
    /// mirrors main.zig's onSurfaceDestroy wiring, so the seat's focus
    /// never outlives the surface it points at.
    // SAFETY: only slots below surface_count were ever initialized.
    surface_listeners: [max_surfaces]SurfaceListenerSlot = undefined,
    surface_count: usize = 0,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor, shell and manager all store it).
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
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();
        ts.ft = try ForeignToplevelManager.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.shell.?, ts.seat.?);
        errdefer if (ts.ft) |f| f.deinit();

        // In-memory client connection: one socketpair end for the server,
        // the other for the client library.
        // SAFETY: socketpair fills both entries or the call is abandoned.
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
            capture.seat_name == null or
            capture.foreign_toplevel_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor, xdg_wm_base and wl_seat. The
        // panel global is NOT bound here: a test binds it itself (see
        // bindPanel) so the bind-time announcement of the toplevels that
        // already exist is observable at a chosen moment.
        ts.registry = registry;
        ts.foreign_toplevel_name = capture.foreign_toplevel_name;
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wm_base = try registry.bind(capture.wm_base_name.?, client.xdg.WmBase, 7);
        ts.wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
        try ts.pump();
        return ts;
    }

    /// The test client's surface died (client teardown, or an explicit
    /// wl_surface.destroy): clear the seat's focus so it never dangles
    /// (production: main.zig onSurfaceDestroy -> Seat.surfaceDestroyed).
    fn onSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), surface: *surface_mod.Surface) void {
        // wl.Listener carries no user data, so the owner is reached with
        // @fieldParentPtr — which names the parent of the FIELD, and the
        // listener lives in a slot struct (see SurfaceListenerSlot).
        const slot: *SurfaceListenerSlot = @fieldParentPtr("listener", listener);
        if (slot.ts.seat) |seat| seat.surfaceDestroyed(surface);
    }

    /// Create a wl_surface for the test client and wire the seat's
    /// surface-destroy hook on it. The roundtrip is pumped here: the
    /// server-side Surface only exists once wl_compositor.create_surface
    /// has been dispatched, and the hook has to be in place before the
    /// test can focus it.
    fn createSurface(ts: *TestServer) !*client.wl.Surface {
        if (ts.surface_count >= ts.surface_listeners.len) return error.TooManySurfaces;
        const surface = try ts.wl_compositor.?.createSurface();
        try ts.pump();
        const slot = ts.surface_count;
        ts.surface_count += 1;
        ts.surface_listeners[slot] = .{
            .ts = ts,
            .listener = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroy),
        };
        serverSurface(ts).events.destroy.add(&ts.surface_listeners[slot].listener);
        return surface;
    }

    /// Bind zwlr_foreign_toplevel_manager_v1 the way a panel does. The
    /// compositor answers the bind with the toplevels that already
    /// exist, so a test calls this at the moment it wants that list
    /// observed, attaches its listener, and pumps.
    fn bindPanel(ts: *TestServer) !*client.zwlr.ForeignToplevelManagerV1 {
        return ts.registry.?.bind(
            ts.foreign_toplevel_name.?,
            client.zwlr.ForeignToplevelManagerV1,
            3,
        );
    }

    fn deinit(ts: *TestServer) void {
        // The client first: its resource destroy handlers (the manager's
        // bindingDestroy and the handle destroys) must run while the
        // module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.ft) |f| f.deinit();
        if (ts.shell) |s| s.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

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

    /// The xdg toplevel the client created most recently.
    fn lastToplevel(ts: *TestServer) *xdg_mod.XdgToplevel {
        return ts.shell.?.toplevels.items[ts.shell.?.toplevels.items.len - 1];
    }
};

/// The server-side Surface of the test client's most recent wl_surface.
fn serverSurface(ts: *TestServer) *surface_mod.Surface {
    const client_wire = ts.client orelse unreachable;
    var found: ?*surface_mod.Surface = null;
    for (ts.compositor.?.surfaces.items) |s| {
        if (s.resource.getClient() == client_wire) found = s;
    }
    return found.?;
}

test "an empty compositor answers an empty list" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    // The binding exists, but no toplevel was ever announced: the
    // protocol is a list, and the compositor's list is empty.
    try testing.expectEqual(@as(usize, 1), ts.ft.?.bindings.items.len);
    try testing.expectEqual(@as(usize, 0), ts.ft.?.bindings.items[0].handles.items.len);
    try testing.expectEqual(@as(usize, 0), events.toplevel_count);
    try testing.expectEqual(@as(usize, 0), events.handles.done_count);
}

test "a new toplevel produces a handle whose whole first batch is one done" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const client_tl = try xdg_surface.getToplevel();
    try ts.pump();

    // One handle, introduced with the details known at that moment (a
    // fresh toplevel has no title or app_id yet) and closed by exactly
    // one done — four property events, one done.
    try testing.expectEqual(@as(usize, 1), events.toplevel_count);
    try testing.expectEqual(@as(usize, 1), ts.ft.?.bindings.items[0].handles.items.len);
    try testing.expectEqual(@as(usize, 1), events.handles.done_count);
    try testing.expectEqual(@as(usize, 1), events.handles.title_count);
    try testing.expectEqualStrings("", events.handles.title(0));
    try testing.expectEqual(@as(usize, 1), events.handles.app_id_count);
    try testing.expectEqualStrings("", events.handles.appId(0));
    try testing.expectEqual(@as(usize, 1), events.handles.state_count);
    // No state is set on a fresh toplevel, so the array is empty.
    try testing.expectEqual(@as(u8, 0), events.handles.last_states);
    // The parent is announced with the first batch (v3), and a toplevel
    // with no parent is NULL.
    try testing.expectEqual(@as(usize, 1), events.handles.parent_count);
    try testing.expect(events.handles.last_parent_null);

    // The handle is the stable identity: the same object every later
    // re-send goes out on.
    const handle_id = events.last.?.getId();
    client_tl.setTitle("hello");
    try ts.pump();
    try testing.expectEqual(handle_id, events.last.?.getId());
    try testing.expectEqual(@as(usize, 2), events.handles.title_count);
    try testing.expectEqualStrings("hello", events.handles.title(1));
    try testing.expectEqual(@as(usize, 2), events.handles.done_count);
}

test "a late binding is answered with the toplevels that already exist" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // A toplevel exists before any panel binds.
    const wl_surface = try ts.createSurface();
    _ = try (try ts.wm_base.?.getXdgSurface(wl_surface)).getToplevel();
    try ts.pump();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.toplevel_count);
    try testing.expectEqual(@as(usize, 1), events.handles.done_count);
}

test "title, app_id and state changes produce one done each" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const client_tl = try xdg_surface.getToplevel();
    try ts.pump();
    const base_done = events.handles.done_count;

    // A title re-send: one title, one done.
    client_tl.setTitle("second");
    try ts.pump();
    try testing.expectEqual(base_done + 1, events.handles.done_count);
    try testing.expectEqual(@as(usize, 2), events.handles.title_count);
    try testing.expectEqualStrings("second", events.handles.title(1));

    // An app_id re-send: one app_id, one done.
    client_tl.setAppId("org.example.Bar");
    try ts.pump();
    try testing.expectEqual(base_done + 2, events.handles.done_count);
    try testing.expectEqual(@as(usize, 2), events.handles.app_id_count);
    try testing.expectEqualStrings("org.example.Bar", events.handles.appId(1));

    // A compositor-recorded state change: one state, one done, and the
    // state set is the xdg toplevel's last-acked state.
    const t = ts.lastToplevel();
    t.current.maximized = true;
    t.current.fullscreen = true;
    ts.ft.?.notifyState(t);
    try ts.pump();
    try testing.expectEqual(base_done + 3, events.handles.done_count);
    try testing.expectEqual(@as(usize, 2), events.handles.state_count);
    // maximized = 0, fullscreen = 3.
    try testing.expectEqual(@as(u8, (1 << 0) | (1 << 3)), events.handles.last_states);

    // A repeat with nothing changed still re-sends the full set (the
    // protocol has no diffing) but must not open a second batch.
    ts.ft.?.notifyState(t);
    try ts.pump();
    try testing.expectEqual(base_done + 4, events.handles.done_count);
    try testing.expectEqual(@as(usize, 3), events.handles.state_count);
}

test "toplevel destruction removes the handle and closes it" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const client_tl = try xdg_surface.getToplevel();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.ft.?.bindings.items[0].handles.items.len);
    const handle = events.last.?;
    const done_before = events.handles.done_count;

    client_tl.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.shell.?.toplevels.items.len);
    try testing.expectEqual(@as(usize, 0), ts.ft.?.bindings.items[0].handles.items.len);
    try testing.expectEqual(@as(usize, 1), events.handles.closed_count);
    // closed is the last event on the handle: the pending done of the
    // announce batch already went out and nothing follows.
    try testing.expectEqual(done_before, events.handles.done_count);

    // The handle is inert but still destroyable (the XML's rule).
    handle.close();
    handle.setMaximized();
    try ts.pump();
    try testing.expectEqual(done_before, events.handles.done_count);
    handle.destroy();
    try ts.pump();
}

test "close reaches the xdg toplevel" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const client_tl = try xdg_surface.getToplevel();
    var tl_events: ClientToplevelEvents = .{};
    client_tl.setListener(*ClientToplevelEvents, ClientToplevelEvents.listener, &tl_events);
    try ts.pump();

    events.last.?.close();
    try ts.pump();
    // close is only a request: the app decides, so the toplevel lives and
    // the handle is not closed.
    try testing.expectEqual(@as(usize, 1), tl_events.close_count);
    try testing.expectEqual(@as(usize, 1), ts.shell.?.toplevels.items.len);
    try testing.expectEqual(@as(usize, 0), events.handles.closed_count);
}

test "a client-destroyed handle stops the observation" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const client_tl = try xdg_surface.getToplevel();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.ft.?.bindings.items[0].handles.items.len);
    const done_before = events.handles.done_count;

    events.last.?.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.ft.?.bindings.items[0].handles.items.len);

    // The toplevel is still alive: a later title change reaches nobody,
    // and a compositor hook on it must not touch a freed struct.
    client_tl.setTitle("after");
    try ts.pump();
    try testing.expectEqual(done_before, events.handles.done_count);
    ts.ft.?.notifyState(ts.lastToplevel());
    try ts.pump();
    try testing.expectEqual(done_before, events.handles.done_count);
}

test "set_rectangle rejects a negative size" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getToplevel();
    try ts.pump();

    // zwlr_foreign_toplevel_handle_v1.error.invalid_rectangle = 0: "the
    // provided rectangle is invalid".
    events.last.?.setRectangle(wl_surface, 0, 0, -1, 10);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "set_rectangle stores the hint and zero removes it" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getToplevel();
    try ts.pump();
    const t = ts.lastToplevel();
    const handle = events.last.?;

    try testing.expect(ts.ft.?.rectangle(t) == null);
    handle.setRectangle(wl_surface, 4, 5, 120, 80);
    try ts.pump();
    const rect = ts.ft.?.rectangle(t).?;
    try testing.expectEqual(@as(i32, 4), rect.x);
    try testing.expectEqual(@as(i32, 5), rect.y);
    try testing.expectEqual(@as(i32, 120), rect.width);
    try testing.expectEqual(@as(i32, 80), rect.height);
    // "Setting width=height=0 removes the already-set rectangle."
    handle.setRectangle(wl_surface, 0, 0, 0, 0);
    try ts.pump();
    try testing.expect(ts.ft.?.rectangle(t) == null);
}

test "maximize, fullscreen and minimize requests reach the xdg toplevel" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getToplevel();
    try ts.pump();
    const t = ts.lastToplevel();
    const handle = events.last.?;

    // set_maximized configures with the state scheduled; the handle only
    // advertises it once the state is current, which is the compositor's
    // call to notifyState.
    handle.setMaximized();
    try ts.pump();
    try testing.expect(t.scheduled.maximized);
    try testing.expectEqual(@as(u8, 0), events.handles.last_states);
    handle.unsetMaximized();
    try ts.pump();
    try testing.expect(!t.scheduled.maximized);
    try testing.expectEqual(@as(i32, 0), t.scheduled.width);
    try testing.expectEqual(@as(i32, 0), t.scheduled.height);

    // Fullscreen takes the same route.
    handle.setFullscreen(null);
    try ts.pump();
    try testing.expect(t.scheduled.fullscreen);
    handle.unsetFullscreen();
    try ts.pump();
    try testing.expect(!t.scheduled.fullscreen);

    // Minimized has no xdg state to configure, so the record is
    // immediate and the handle advertises it in the same round.
    handle.setMinimized();
    try ts.pump();
    try testing.expect(t.current.minimized);
    // minimized = 1.
    try testing.expectEqual(@as(u8, 1 << 1), events.handles.last_states);
    handle.unsetMinimized();
    try ts.pump();
    try testing.expect(!t.current.minimized);
    try testing.expectEqual(@as(u8, 0), events.handles.last_states);
}

test "activate focuses the toplevel on the compositor's seat" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    _ = try xdg_surface.getToplevel();
    try ts.pump();
    const surface = serverSurface(ts);
    try testing.expect(ts.seat.?.keyboard_focus == null);

    events.last.?.activate(ts.wl_seat.?);
    try ts.pump();
    try testing.expect(ts.seat.?.keyboard_focus == surface);
}

test "stop silences new toplevels but keeps the handles" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface_a = try ts.createSurface();
    _ = try (try ts.wm_base.?.getXdgSurface(wl_surface_a)).getToplevel();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.toplevel_count);
    const handle = events.last.?;

    panel.stop();
    try ts.pump();

    // A new toplevel is not announced any more.
    const wl_surface_b = try ts.createSurface();
    _ = try (try ts.wm_base.?.getXdgSurface(wl_surface_b)).getToplevel();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.toplevel_count);
    try testing.expectEqual(@as(usize, 1), ts.ft.?.bindings.items[0].handles.items.len);

    // The old handle still works: `stop` only silences new toplevel
    // events until `finished`.
    ts.ft.?.notifyState(ts.shell.?.toplevels.items[0]);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), events.handles.state_count);
    try testing.expectEqual(handle.getId(), events.last.?.getId());
}

test "finished tears the binding down and makes its handles inert" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: ManagerEvents = .{};
    const panel = try ts.bindPanel();
    panel.setListener(*ManagerEvents, ManagerEvents.listener, &events);
    try ts.pump();

    const wl_surface = try ts.createSurface();
    const xdg_surface = try ts.wm_base.?.getXdgSurface(wl_surface);
    const client_tl = try xdg_surface.getToplevel();
    try ts.pump();
    const handle = events.last.?;

    ts.ft.?.finish(ts.ft.?.bindings.items[0].resource);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.finished_count);
    try testing.expectEqual(@as(usize, 0), ts.ft.?.bindings.items.len);

    // The handle is inert: only destroy is honoured, and the toplevel is
    // untouched.
    handle.setMaximized();
    handle.close();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.shell.?.toplevels.items.len);
    handle.destroy();
    try ts.pump();
    // The toplevel outlives the module's observation: destroying it
    // finds no handle and no stale listener.
    client_tl.destroy();
    try ts.pump();
}

test "a manager with no seat and no client still comes up and tears down" {
    const allocator = testing.allocator;
    var io = std.Io.Threaded.global_single_threaded.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const display = try display_mod.CompositorDisplay.init(allocator, &io, &log_cfg);
    defer display.deinit();
    const compositor = try compositor_mod.Compositor.init(allocator, &io, &log_cfg, display);
    defer compositor.deinit();
    const shell = try xdg_mod.XdgShell.init(allocator, &io, &log_cfg, display, compositor);
    defer shell.deinit();
    // No seat: activate is a no-op (it is never a protocol error) and no
    // client ever binds, so the module has no handle to close.
    const mgr = try ForeignToplevelManager.init(allocator, &io, &log_cfg, display, shell, null);
    try testing.expect(mgr.seat == null);
    try testing.expectEqual(@as(usize, 0), mgr.bindings.items.len);
    mgr.deinit();
}
