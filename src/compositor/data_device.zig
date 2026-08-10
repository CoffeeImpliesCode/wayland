//! wl_data_device_manager: clipboard selection relay (M3/M4).
//!
//! Minimal-but-functional implementation of the core data device
//! protocol: wl_data_device_manager (v3), wl_data_device, wl_data_source
//! and wl_data_offer objects. The compositor stores the selection
//! (set_selection) and delivers it to the keyboard-focused client:
//!
//!   - on set_selection: the old source gets `cancelled`, the new source
//!     is stored; the focused client receives a fresh data_offer (mime
//!     types echoed via offer events) + the selection event.
//!   - data_offer.receive(mime, fd) relays the fd to the owning client's
//!     data_source.send(mime, fd) — the source writes the payload, the
//!     target reads it (memfd relay).
//!   - Offer lifetime mirrors wlroots: an offer is destroyed (its wire
//!     resource left inert) whenever the selection is re-delivered or its
//!     source dies, so an offer never outlives the source it references
//!     and receive() can never read freed source memory.
//!   - set_selection/start_drag validate the serial: it must be the
//!     seat's most recent serial. Stale serials are ignored — never a
//!     protocol error — like wlroots.
//!   - data_source teardown (destroy/cancel) clears the stored selection
//!     and destroys the offers that referenced it.
//!
//! Drag-and-drop (start_drag) is not implemented in M3: the request is
//! accepted, the source is cancelled, no drag icon is shown.
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, compositor/seat.zig.

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const seat_mod = @import("seat.zig");
const compositor_mod = @import("compositor.zig");
const surface_mod = @import("surface.zig");

const server = @import("protocol").server;
const client = @import("protocol").client;

/// wl_data_device_manager protocol version this library implements.
pub const data_device_version: u32 = 3;

pub const DataDeviceManager = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    seat: *seat_mod.Seat,
    global: ?*wire.Global = null,
    /// Per-client data devices (get_data_device).
    devices: std.ArrayList(*DataDevice) = .empty,
    /// The seat-wide selection (wlr_seat.selection_source / smithay
    /// SeatData.clipboard_selection). The manager is per-seat, so one
    /// field holds the selection for the whole seat: a selection set by
    /// one client is delivered to whichever client holds keyboard focus.
    selection_source: ?*DataSource = null,
    /// Every data source created by clients. Clients outlive the manager
    /// at shutdown (main.zig defers the manager before display.deinit
    /// tears down the clients), so deinit destroys these resources while
    /// the manager is still alive: each destroy handler unlinks and frees
    /// its struct, and the later client teardown cannot call into the
    /// freed manager.
    sources: std.ArrayList(*DataSource) = .empty,
    /// Live selection offers, one per data device of the focused client.
    /// An offer is destroyed (struct freed, wire resource inerted)
    /// whenever the selection is re-delivered, the focus moves, or its
    /// source dies — an offer never outlives the source it references
    /// (wlroots: seat->selection_offers, destroyed by
    /// seat_client_send_selection, wlr_data_device.c; an offer dies with
    /// its source, wlr_data_offer.c data_offer_handle_source_destroy).
    offers: std.ArrayList(*DataOffer) = .empty,
    focus_listener: wire.Listener(*seat_mod.Seat),

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        seat: *seat_mod.Seat,
    ) error{ OutOfMemory, GlobalCreateFailed }!*DataDeviceManager {
        const self = try allocator.create(DataDeviceManager);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .seat = seat,
            .devices = .empty,
            .focus_listener = wire.Listener(*seat_mod.Seat).init(onKeyboardFocus),
        };
        errdefer self.devices.deinit(allocator);
        self.global = try display.addGlobal(
            server.wl.DataDeviceManager,
            *DataDeviceManager,
            bindManager,
            data_device_version,
            self,
        );
        // Deliver the selection when the keyboard focus moves.
        seat.events.keyboard_focus.add(&self.focus_listener);
        log.debug("data device manager created", io, log_cfg, "data_device", .{});
        return self;
    }

    pub fn deinit(self: *DataDeviceManager) void {
        // Detach from the seat's focus signal before freeing the struct:
        // the seat outlives the manager (main's defer order) and a later
        // keyboard_focus emit would call into the freed manager.
        self.focus_listener.link.remove();
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        // Clients outlive the manager at shutdown (main.zig defers the
        // manager before display.deinit, which tears down the clients),
        // so destroy every resource this manager owns while the manager
        // is still alive: each destroy handler runs synchronously,
        // unlinks and frees its struct, and the later client teardown
        // cannot call into the freed manager.
        while (self.sources.items.len > 0) {
            self.sources.items[0].resource.destroy();
        }
        while (self.offers.items.len > 0) destroyOffer(self, self.offers.items[0]);
        while (self.devices.items.len > 0) {
            self.devices.items[0].resource.destroy();
        }
        self.sources.deinit(allocator);
        self.offers.deinit(allocator);
        self.devices.deinit(allocator);
        allocator.destroy(self);
    }
};

/// A client's data device (one per client per seat).
const DataDevice = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataDevice,
};

/// A data source (the client offering clipboard content).
const DataSource = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataSource,
    /// Mime types offered (data_source.offer events), sentinel-terminated
    /// (wl_data_offer.offer takes a C string).
    mime_types: std.ArrayList([:0]const u8),
    /// DnD actions the source supports (wl_data_source.set_actions).
    /// Clipboard selection never uses actions, but the mask is validated
    /// and stored so wl_data_offer.set_actions can run its
    /// invalid_action check against it (wlr_data_offer.c).
    actions: u32 = 0,
};

/// A data offer delivered to a target client.
const DataOffer = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataOffer,
    /// The offering client's source. Nulled when the offer is destroyed
    /// (the source may already be freed), so a dead offer never reads
    /// freed source memory (wlroots nulls offer->source in
    /// data_offer_handle_source_destroy, wlr_data_offer.c).
    source: ?*DataSource,
};

fn bindManager(client_wire: *wire.Client, mgr: *DataDeviceManager, version: u32, id: u32) void {
    const resource = server.wl.DataDeviceManager.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    resource.setHandler(*DataDeviceManager, managerRequest, null, mgr);
}

fn managerRequest(
    resource: *server.wl.DataDeviceManager,
    request: server.wl.DataDeviceManager.Request,
    mgr: *DataDeviceManager,
) void {
    switch (request) {
        .create_data_source => |r| {
            const src_res = server.wl.DataSource.create(resource.getClient(), 3, r.id) catch {
                resource.getClient().postNoMemory();
                return;
            };
            const src = mgr.allocator.create(DataSource) catch {
                src_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            src.* = .{
                .manager = mgr,
                .resource = src_res,
                .mime_types = .empty,
            };
            src_res.setHandler(*DataSource, sourceRequest, sourceDestroy, src);
            mgr.sources.append(mgr.allocator, src) catch {
                // Destroying the resource runs sourceDestroy, which frees
                // the source (it is not in the list yet).
                src_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
        },
        .get_data_device => |r| {
            // The seat argument: only our seat's device matters (one seat).
            const dev_res = server.wl.DataDevice.create(resource.getClient(), 3, r.id) catch {
                resource.getClient().postNoMemory();
                return;
            };
            const dev = mgr.allocator.create(DataDevice) catch {
                dev_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            dev.* = .{
                .manager = mgr,
                .resource = dev_res,
            };
            dev_res.setHandler(*DataDevice, deviceRequest, deviceDestroy, dev);
            mgr.devices.append(mgr.allocator, dev) catch {
                dev_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            // Bind-time delivery: a new device of the focused client
            // immediately receives the current selection (wlroots
            // seat_client_send_selection, wlr_seat.c; KWin seat.cpp:
            // 159-177). The device is already in the list, so
            // deliverSelectionToFocus re-delivers to every device of the
            // focused client, including this one.
            if (mgr.seat.keyboard_focus) |focus| {
                if (focus.resource.getClient() == dev_res.getClient()) {
                    deliverSelectionToFocus(mgr);
                }
            }
        },
    }
}

// ---------------------------------------------------------------------------
// wl_data_source
// ---------------------------------------------------------------------------

fn sourceRequest(src_res: *server.wl.DataSource, request: server.wl.DataSource.Request, src: *DataSource) void {
    switch (request) {
        .offer => |r| {
            const mime = std.mem.span(r.mime_type);
            const copy = src.manager.allocator.dupeZ(u8, mime) catch {
                src_res.postNoMemory();
                return;
            };
            src.mime_types.append(src.manager.allocator, copy) catch {
                src.manager.allocator.free(copy);
                src_res.postNoMemory();
                return;
            };
        },
        .set_actions => |r| {
            // wayland.xml wl_data_source.set_actions: the source side may
            // only offer copy and move (ask is destination-only); any
            // other bit raises the invalid_action_mask protocol error
            // (wlroots data_source_handle_set_actions, wlr_data_source.c).
            const valid: u32 = 1 | 2; // copy | move
            const dnd_actions: u32 = @bitCast(r.dnd_actions);
            if (dnd_actions & ~valid != 0) {
                src_res.postError(.invalid_action_mask, "wl_data_source.set_actions: invalid dnd_actions");
                return;
            }
            src.actions = dnd_actions;
        },
        .destroy => src_res.destroy(),
    }
}

fn sourceDestroy(src_res: *server.wl.DataSource, src: *DataSource) void {
    _ = src_res;
    const mgr = src.manager;
    if (mgr.selection_source == src) {
        // The selected source died: clear the seat-wide selection and
        // cancel the (already dying) source. The re-delivery below
        // destroys every offer that referenced it, so no offer can read
        // the freed source (wlroots: seat_handle_selection_source_destroy
        // clears the selection and re-sends selection to the focused
        // client, which first destroys all selection offers,
        // wlr_data_device.c; an offer dies with its source,
        // wlr_data_offer.c data_offer_handle_source_destroy).
        mgr.selection_source = null;
        src.resource.sendCancelled();
        deliverSelectionToFocus(mgr);
    }
    if (std.mem.findScalar(*DataSource, mgr.sources.items, src)) |idx| {
        _ = mgr.sources.orderedRemove(idx);
    }
    for (src.mime_types.items) |m| mgr.allocator.free(m);
    src.mime_types.deinit(mgr.allocator);
    const allocator = mgr.allocator;
    allocator.destroy(src);
}

// ---------------------------------------------------------------------------
// wl_data_device
// ---------------------------------------------------------------------------

fn deviceRequest(dev_res: *server.wl.DataDevice, request: server.wl.DataDevice.Request, dev: *DataDevice) void {
    switch (request) {
        .set_selection => |r| {
            const mgr = dev.manager;
            // Serial validation: the serial must be the seat's most
            // recent one — the client can only act on the input event it
            // just received. wlroots validates with
            // wlr_seat_client_validate_event_serial and silently ignores
            // a stale serial (never a protocol error),
            // wlr_seat.c:266-277; the same equality rule gates start_drag
            // via the pointer grab serial, wlr_seat_pointer.c:603-617.
            // [Simplification: wlroots accepts any serial recently
            // delivered to the requesting client; this single-seat
            // implementation accepts only the seat's last serial.]
            if (r.serial != mgr.seat.last_serial) {
                log.debug(
                    "rejecting set_selection: serial {d} is not the seat's last ({d})",
                    mgr.io,
                    mgr.log_cfg,
                    "data_device",
                    .{ r.serial, mgr.seat.last_serial },
                );
                return;
            }
            if (r.source) |src_res| {
                const src: *DataSource = @ptrCast(@alignCast(src_res.getUserData()));
                // A new selection: cancel the previous one.
                if (mgr.selection_source) |old| {
                    if (old != src) old.resource.sendCancelled();
                }
                mgr.selection_source = src;
                log.debug("selection set with {d} mime types", mgr.io, mgr.log_cfg, "data_device", .{
                    src.mime_types.items.len,
                });
            } else {
                // Null source: clear the selection.
                if (mgr.selection_source) |old| {
                    old.resource.sendCancelled();
                }
                mgr.selection_source = null;
            }
            deliverSelectionToFocus(mgr);
        },
        .start_drag => |r| {
            const mgr = dev.manager;
            // The drag serial must be the seat's last (wlroots: the
            // pointer grab serial, wlr_seat_pointer.c:603-617). A denied
            // drag leaves the source alone — the client keeps it
            // (smithay logs "denying drag from client without implicit
            // grab" and returns, data_device/device.rs).
            if (r.serial != mgr.seat.last_serial) {
                log.debug(
                    "rejecting start_drag: serial {d} is not the seat's last ({d})",
                    mgr.io,
                    mgr.log_cfg,
                    "data_device",
                    .{ r.serial, mgr.seat.last_serial },
                );
                return;
            }
            // No DnD in M3: the source is cancelled.
            if (r.source) |src_res| {
                const src: *DataSource = @ptrCast(@alignCast(src_res.getUserData()));
                src.resource.sendCancelled();
            }
        },
        .release => dev_res.destroy(),
    }
}

fn deviceDestroy(dev_res: *server.wl.DataDevice, dev: *DataDevice) void {
    _ = dev_res;
    const mgr = dev.manager;
    // The seat-wide selection is owned by the manager, not the device: it
    // survives the device (wlr_seat keeps the selection when the device
    // dies; the source stays valid for the focused client).
    const idx = std.mem.findScalar(*DataDevice, mgr.devices.items, dev) orelse 0;
    if (idx < mgr.devices.items.len and mgr.devices.items[idx] == dev) {
        _ = mgr.devices.orderedRemove(idx);
    }
    const allocator = mgr.allocator;
    allocator.destroy(dev);
}

/// Keyboard focus moved: deliver the stored selection to the focused
/// client (or clear it on unfocus).
fn onKeyboardFocus(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    const mgr: *DataDeviceManager = @fieldParentPtr("focus_listener", listener);
    _ = seat;
    deliverSelectionToFocus(mgr);
}

/// For the focused client's data devices: destroy the previous offers and
/// deliver the stored selection — a fresh offer per device when a
/// selection exists, selection(NULL) when it was cleared (wlroots:
/// seat_client_send_selection / device_resource_send_selection,
/// wlr_data_device.c).
fn deliverSelectionToFocus(mgr: *DataDeviceManager) void {
    // A re-delivery (new/cleared selection, focus change, source death)
    // supersedes every previous offer: destroy them all first, so no
    // stale offer outlives the selection it advertises (wlroots destroys
    // all seat selection offers before re-sending, wlr_data_device.c).
    destroyAllOffers(mgr);
    // The seat never holds a dangling focus: Seat.surfaceDestroyed clears
    // keyboard_focus when the surface dies (wired by main.zig's
    // onSurfaceDestroy in production, by the TestServer's surface
    // listener in the tests below), so a non-null focus is always a live
    // surface. The null-guard is still the safety net for the no-focus
    // seat — never dereference past it without that invariant.
    const focus = mgr.seat.keyboard_focus orelse return;
    const focus_client = focus.resource.getClient();
    // The selection is seat-wide: any client may be the owner, so read it
    // from the manager, not from the focused client's own device.
    const src = mgr.selection_source;
    for (mgr.devices.items) |dev| {
        if (dev.resource.getClient() != focus_client) continue;
        if (src) |s| {
            const offer_res = server.wl.DataOffer.create(focus_client, 3, 0) catch return;
            const offer = mgr.allocator.create(DataOffer) catch {
                offer_res.destroy();
                return;
            };
            offer.* = .{
                .manager = mgr,
                .resource = offer_res,
                .source = s,
            };
            offer_res.setHandler(*DataOffer, offerRequest, offerDestroy, offer);
            mgr.offers.append(mgr.allocator, offer) catch {
                // offerDestroy frees the offer (it is not in the list).
                offer_res.destroy();
                return;
            };
            // Order matters (wlroots device_resource_send_selection,
            // wlr_data_device.c): introduce the offer via data_offer
            // FIRST, then the per-mime offer events, then selection.
            // libwayland-client discards events for object ids it does
            // not know yet (queue_event, wayland-client.c), so sending
            // the mimes before data_offer would silently drop them.
            dev.resource.sendDataOffer(offer_res);
            for (s.mime_types.items) |m| offer_res.sendOffer(m.ptr);
            dev.resource.sendSelection(offer_res);
            log.debug("selection delivered to focused client ({d} mimes)", mgr.io, mgr.log_cfg, "data_device", .{
                s.mime_types.items.len,
            });
        } else {
            // No selection: the focused client's offer is void
            // (wlroots: wl_data_device_send_selection(device, NULL),
            // device_resource_send_selection).
            dev.resource.sendSelection(null);
        }
    }
}

// ---------------------------------------------------------------------------
// wl_data_offer
// ---------------------------------------------------------------------------

fn offerRequest(offer_res: *server.wl.DataOffer, request: server.wl.DataOffer.Request, offer: *DataOffer) void {
    switch (request) {
        .accept => |r| {
            _ = r;
            // Ignored in M3 (action negotiation is not implemented).
        },
        .receive => |r| {
            // Relay the fd to the owning client: the source writes the
            // payload into it, the target reads it. A live offer always
            // has a live source (the source is nulled only when the
            // offer is destroyed, which also removes it from the
            // manager's list); the guard is defensive.
            const src = offer.source orelse {
                _ = std.os.linux.close(r.fd);
                return;
            };
            src.resource.sendSend(r.mime_type, r.fd);
            _ = std.os.linux.close(r.fd);
            log.debug("offer.receive relayed ({s})", offer.manager.io, offer.manager.log_cfg, "data_device", .{
                std.mem.span(r.mime_type),
            });
        },
        .destroy => offer_res.destroy(),
        .finish => {
            // wayland.xml: "If wl_data_offer.finish request is received
            // for a non drag and drop operation, the invalid_finish
            // protocol error is raised." Our offers are always clipboard
            // offers (DnD is not implemented), so finish is never
            // eligible.
            offer_res.postError(.invalid_finish, "wl_data_offer.finish: not a drag-and-drop offer");
        },
        .set_actions => |r| {
            // wayland.xml wl_data_offer.set_actions (wlroots
            // data_offer_handle_set_actions, wlr_data_offer.c):
            //   - dnd_actions must contain only dnd_action enum values
            //     and preferred_action must be a single one of them,
            //     else invalid_action_mask;
            //   - a preferred action the source does not support (a
            //     source without action support has mask 0) is
            //     invalid_action.
            const valid: u32 = 1 | 2 | 4; // copy | move | ask
            const dnd_actions: u32 = @bitCast(r.dnd_actions);
            const preferred_action: u32 = @bitCast(r.preferred_action);
            if ((dnd_actions & ~valid) != 0 or
                (preferred_action & ~valid) != 0 or
                (preferred_action != 0 and (preferred_action & (preferred_action - 1)) != 0))
            {
                offer_res.postError(.invalid_action_mask, "wl_data_offer.set_actions: invalid action mask");
                return;
            }
            const src = offer.source orelse {
                offer_res.postError(.invalid_action, "wl_data_offer.set_actions: offer has no source");
                return;
            };
            if (preferred_action != 0 and (src.actions & preferred_action) == 0) {
                offer_res.postError(
                    .invalid_action,
                    "wl_data_offer.set_actions: preferred action not supported by the source",
                );
                return;
            }
        },
    }
}

fn offerDestroy(offer_res: *server.wl.DataOffer, offer: *DataOffer) void {
    _ = offer_res;
    const mgr = offer.manager;
    // The client destroyed its offer (or the offer's resource died with
    // the client): unlink and free.
    if (std.mem.findScalar(*DataOffer, mgr.offers.items, offer)) |idx| {
        _ = mgr.offers.orderedRemove(idx);
    }
    const allocator = mgr.allocator;
    allocator.destroy(offer);
}

/// Request handler for inerted (dead) offers: the offer struct is freed,
/// so nothing is dereferenced. receive's fd is closed — the request still
/// transferred ownership to the server (wlroots closes the fd when the
/// offer is gone, data_offer_handle_receive, wlr_data_offer.c).
fn deadOfferHandler(resource: *server.wl.DataOffer, request: server.wl.DataOffer.Request, data: ?*DataOffer) void {
    _ = resource;
    _ = data;
    switch (request) {
        .receive => |r| _ = std.os.linux.close(r.fd),
        else => {},
    }
}

/// Destroy a selection offer the compositor owns (the selection was
/// re-delivered, the focus moved, or the source died): unlink and free
/// the offer, and leave its wire resource inert with a no-op handler.
/// Inerting — not destroying — matters: the object id stays valid, so a
/// well-behaved client that destroys its offer after selection(NULL)
/// neither errors nor is killed, and a NULL-implementation resource would
/// make libwayland abort the compositor on the next request (wlroots
/// inerts: data_offer_destroy, wlr_data_offer.c; wayland-server.c
/// wl_closure_invoke aborts on NULL implementation).
fn destroyOffer(mgr: *DataDeviceManager, offer: *DataOffer) void {
    if (std.mem.findScalar(*DataOffer, mgr.offers.items, offer)) |idx| {
        _ = mgr.offers.orderedRemove(idx);
    }
    // Drop the source reference before freeing: the source may already be
    // gone (sourceDestroy clears the selection before the offers). The
    // dead offer must never read it (wlroots nulls offer->source in
    // data_offer_handle_source_destroy).
    offer.source = null;
    offer.resource.setHandler(?*DataOffer, deadOfferHandler, null, null);
    mgr.allocator.destroy(offer);
}

/// Destroy every live selection offer.
fn destroyAllOffers(mgr: *DataDeviceManager) void {
    while (mgr.offers.items.len > 0) destroyOffer(mgr, mgr.offers.items[0]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const posix = std.posix;

/// libwayland-client >= 1.18: return the code of the last protocol error.
extern fn wl_display_get_protocol_error(display: *client.wl.Display, interface: ?*anyopaque, id: ?*u32) c_int;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,
    data_device_manager_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_data_device_manager")) {
                    data.data_device_manager_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Counts the cancelled events delivered to a wl_data_source.
const SourceEvents = struct {
    cancelled_count: usize = 0,

    fn listener(source: *client.wl.DataSource, event: client.wl.DataSource.Event, data: *SourceEvents) void {
        _ = source;
        switch (event) {
            .cancelled => data.cancelled_count += 1,
            else => {},
        }
    }
};

/// Records the client-side data device events: how many selections were
/// delivered and whether the last one was a null (cleared) selection, so
/// tests can observe delivery and the offer after selection(NULL).
const DeviceEvents = struct {
    selection_count: usize = 0,
    last_selection_null: bool = false,
    /// The offer of the most recent non-null selection (valid until a
    /// selection(NULL) or a new offer supersedes it).
    last_offer: ?*client.wl.DataOffer = null,

    fn listener(device: *client.wl.DataDevice, event: client.wl.DataDevice.Event, data: *DeviceEvents) void {
        _ = device;
        switch (event) {
            .selection => |e| {
                data.selection_count += 1;
                data.last_selection_null = e.id == null;
                if (e.id) |offer| data.last_offer = offer;
            },
            .data_offer => {},
            // DnD events: the test client never drags; the arms exist for
            // exhaustive switch over the wire event enum.
            .enter => {},
            .leave => {},
            .motion => {},
            .drop => {},
        }
    }
};

/// A compositor + seat + data device manager + in-memory client, for wire
/// roundtrips of the selection flow.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    mgr: ?*DataDeviceManager = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_seat: ?*client.wl.Seat = null,
    wl_data_device_manager: ?*client.wl.DataDeviceManager = null,
    surface: ?*client.wl.Surface = null,
    /// Mirrors main.zig's onSurfaceDestroy wiring: the seat's focus is
    /// cleared when the test client's surface is destroyed (client
    /// teardown, or an explicit wl_surface.destroy), so the seat never
    /// holds a dangling surface and deliverSelectionToFocus never reads
    /// freed surface memory (production calls Seat.surfaceDestroyed from
    /// onSurfaceDestroy, main.zig; the TestServer drives the protocol
    /// directly, so the wiring must be replicated here).
    surface_listener: wire.Listener(*surface_mod.Surface),

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, seat and manager all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
            .surface_listener = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroy),
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.seat) |s| s.deinit();
        ts.mgr = try DataDeviceManager.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.seat.?);
        errdefer if (ts.mgr) |m| m.deinit();

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
            capture.data_device_manager_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor (to create a focusable surface),
        // wl_seat and wl_data_device_manager.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.surface = try ts.wl_compositor.?.createSurface();
        ts.wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
        ts.wl_data_device_manager = try registry.bind(
            capture.data_device_manager_name.?,
            client.wl.DataDeviceManager,
            3,
        );
        try ts.pump();
        // Production clears the seat focus from main.zig's
        // onSurfaceDestroy; this harness drives the protocol directly, so
        // wire the seat's surfaceDestroyed to the client's surface here
        // (same effect: the focus never outlives its surface).
        const srv_surface = surfaceForClient(ts, ts.client.?);
        srv_surface.events.destroy.add(&ts.surface_listener);
        return ts;
    }

    /// The test client's surface died (client teardown or an explicit
    /// wl_surface.destroy): clear the seat's focus so the seat — and
    /// deliverSelectionToFocus — never reads freed surface memory
    /// (production: main.zig onSurfaceDestroy → Seat.surfaceDestroyed).
    fn onSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), surface: *surface_mod.Surface) void {
        const ts: *TestServer = @fieldParentPtr("surface_listener", listener);
        if (ts.seat) |seat| seat.surfaceDestroyed(surface);
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers
        // (sourceDestroy/deviceDestroy) must run while the manager lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.mgr) |m| m.deinit();
        if (ts.seat) |s| s.deinit();
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
};

/// The server-side Surface created by `client` (each test client creates
/// exactly one surface).
fn surfaceForClient(ts: *TestServer, client_wire: *wire.Client) *surface_mod.Surface {
    for (ts.compositor.?.surfaces.items) |s| {
        if (s.resource.getClient() == client_wire) return s;
    }
    unreachable;
}

test "selection is stored seat-wide and replaced selections are cancelled" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src_a = try ts.wl_data_device_manager.?.createDataSource();
    const src_b = try ts.wl_data_device_manager.?.createDataSource();

    var events_a: SourceEvents = .{};
    var events_b: SourceEvents = .{};
    src_a.setListener(*SourceEvents, SourceEvents.listener, &events_a);
    src_b.setListener(*SourceEvents, SourceEvents.listener, &events_b);

    // No selection yet.
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);

    // Client sets the selection: stored on the manager (seat-wide), not on
    // the device; the source is not cancelled.
    device.setSelection(src_a, 0);
    try ts.pump();
    try testing.expect(ts.mgr.?.selection_source != null);
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 0), events_a.cancelled_count);

    // Replacing with a different source cancels the previous owner.
    device.setSelection(src_b, 0);
    try ts.pump();
    try testing.expectEqual(src_b.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 1), events_a.cancelled_count);
    try testing.expectEqual(@as(usize, 0), events_b.cancelled_count);

    // Null source clears the seat-wide selection and cancels the owner.
    device.setSelection(null, 0);
    try ts.pump();
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(@as(usize, 1), events_b.cancelled_count);
}

test "destroying the selected source clears the seat-wide selection" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();

    var events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &events);

    device.setSelection(src, 0);
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());

    // The owner destroys its source: the seat-wide selection is cleared.
    // (The cancelled event is a server-side courtesy on self-destroy;
    // libwayland has already dropped the client proxy, so it is not
    // observable here.)
    src.destroy();
    try ts.pump();
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);
}

test "device release keeps the seat-wide selection" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();

    var events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &events);

    device.setSelection(src, 0);
    try ts.pump();

    // The selection is owned by the manager (per seat), not the device:
    // releasing the device must not cancel it (wlr_seat semantics).
    device.release();
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 0), events.cancelled_count);
}

test "stale set_selection serials are ignored, not errored" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();

    var events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &events);

    // No input yet: the seat's last serial is 0, so 0 validates.
    device.setSelection(src, 0);
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());

    // A serial the seat never issued: the request is ignored, the
    // selection is untouched and the source is not cancelled (wlroots
    // logs and returns, wlr_seat.c wlr_seat_request_set_selection — it
    // never posts a protocol error).
    const stale = ts.seat.?.display.nextSerial();
    try testing.expect(stale != 0);
    device.setSelection(null, stale);
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 0), events.cancelled_count);

    // Clearing with the valid serial still works.
    device.setSelection(null, 0);
    try ts.pump();
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(@as(usize, 1), events.cancelled_count);
}

test "offer dies with its source and tolerates later client use" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);

    // Flush the get_data_device/create_data_source requests: the server
    // must have registered the device before the focus change below, or
    // deliverSelectionToFocus iterates an empty device list and the
    // client never receives the selection(NULL) event.
    try ts.pump();

    // Focus the client's surface so the selection is delivered as an offer.
    const surface = surfaceForClient(ts, ts.client.?);
    ts.seat.?.setKeyboardFocus(surface);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), dev_events.selection_count);
    try testing.expect(dev_events.last_selection_null);

    const serial = ts.seat.?.last_serial;
    device.setSelection(src, serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    try testing.expectEqual(@as(usize, 2), dev_events.selection_count);
    try testing.expect(!dev_events.last_selection_null);
    const offer = dev_events.last_offer.?;

    // The owner destroys its source: the selection is cleared, the offer
    // is destroyed (struct freed, resource inerted) and the focused
    // client is told selection(NULL) (wlroots:
    // seat_handle_selection_source_destroy, wlr_data_device.c).
    src.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(@as(usize, 3), dev_events.selection_count);
    try testing.expect(dev_events.last_selection_null);

    // The dead offer is inert: receive() and destroy() from the client
    // neither crash the compositor (no dangling source dereference) nor
    // kill the client (wlroots inerts instead of destroying, so the
    // object id stays valid: data_offer_destroy, wlr_data_offer.c).
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    offer.receive("text/plain", fds[0]);
    offer.destroy();
    try ts.pump();
    _ = std.os.linux.close(fds[0]);
    _ = std.os.linux.close(fds[1]);

    // The client survived: a further selection roundtrip succeeds.
    device.setSelection(null, serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 4), dev_events.selection_count);
    try testing.expect(dev_events.last_selection_null);
}

test "re-delivering the selection supersedes the previous offer" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src_a = try ts.wl_data_device_manager.?.createDataSource();
    const src_b = try ts.wl_data_device_manager.?.createDataSource();
    var events_a: SourceEvents = .{};
    var events_b: SourceEvents = .{};
    src_a.setListener(*SourceEvents, SourceEvents.listener, &events_a);
    src_b.setListener(*SourceEvents, SourceEvents.listener, &events_b);

    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client.?));
    try ts.pump();
    const serial = ts.seat.?.last_serial;

    device.setSelection(src_a, serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());

    // Replacing the selection re-delivers: the previous offer is
    // destroyed, exactly one fresh offer exists (wlroots:
    // seat_client_send_selection destroys all offers before re-sending,
    // wlr_data_device.c).
    device.setSelection(src_b, serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    try testing.expectEqual(src_b.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 1), events_a.cancelled_count);
    try testing.expectEqual(@as(usize, 0), events_b.cancelled_count);
}

test "new data device binding receives the current selection at bind time" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device1 = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var dev1_events: DeviceEvents = .{};
    device1.setListener(*DeviceEvents, DeviceEvents.listener, &dev1_events);
    try ts.pump();

    // Focus the client so the selection can be set and delivered.
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client.?));
    try ts.pump();
    const serial = ts.seat.?.last_serial;

    device1.setSelection(src, serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), dev1_events.selection_count); // focus NULL + the selection
    try testing.expect(!dev1_events.last_selection_null);

    // A second device bound while the client is focused immediately
    // receives the current selection (wlroots seat_client_send_selection
    // on bind, wlr_seat.c; KWin seat.cpp:159-177).
    const device2 = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    var dev2_events: DeviceEvents = .{};
    device2.setListener(*DeviceEvents, DeviceEvents.listener, &dev2_events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), dev2_events.selection_count);
    try testing.expect(!dev2_events.last_selection_null);
    // One live offer per device of the focused client.
    try testing.expectEqual(@as(usize, 2), ts.mgr.?.offers.items.len);
}

test "offer.finish on a clipboard offer raises invalid_finish" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);
    try ts.pump();

    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client.?));
    try ts.pump();
    const serial = ts.seat.?.last_serial;
    device.setSelection(src, serial);
    try ts.pump();
    try testing.expect(dev_events.last_offer != null);

    // finish on a non drag-and-drop (clipboard) offer: invalid_finish
    // (0) is raised on the wl_data_offer (wayland.xml), killing the
    // connection.
    dev_events.last_offer.?.finish();
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "source.set_actions with invalid bits raises invalid_action_mask" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const src = try ts.wl_data_device_manager.?.createDataSource();
    try ts.pump();

    // A bit outside {copy, move}: invalid_action_mask (0) on the
    // wl_data_source (wayland.xml: the source side may only offer copy
    // and move; wlroots data_source_handle_set_actions,
    // wlr_data_source.c).
    const DndAction = client.wl.DataDeviceManager.DndAction;
    src.setActions(@as(DndAction, @bitCast(@as(u32, 8))));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}
