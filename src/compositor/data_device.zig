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
//!   - set_selection/start_drag validate the serial against the seat's
//!     per-client serial ring (Seat.validateEventSerial, the wlroots
//!     model — a serial handed to ANY other client is invalid) plus a
//!     superseded window against the serial the current selection was
//!     set with (serial - selection_serial > UINT32_MAX/2 is rejected,
//!     wlr_data_device.c:148-153). Stale serials are ignored — never a
//!     protocol error — like wlroots.
//!   - A data source is used once (wayland.xml wl_data_device.set_selection:
//!     "The given source may not be used in any further set_selection or
//!     start_drag requests"): set_selection/start_drag finalize the source
//!     BEFORE serial validation (wlroots wlr_data_device.c:34-37, :82-85),
//!     so a rejected request still burns it; set_actions on a finalized
//!     source — or a second set_actions — raises invalid_action_mask
//!     (wlr_data_source.c:166-178).
//!   - set_selection with a source that advertised DnD actions raises
//!     wl_data_source.error.invalid_source (KWin datadevice.cpp:91-101
//!     hardening; wlroots has no such check).
//!   - DnD action state is stored and negotiated per wlroots
//!     (data_offer_choose_action / data_offer_update_action,
//!     wlr_data_offer.c:22-76): the source's mask, the offer's
//!     mask/preferred action, the compositor-forced action and the
//!     current negotiated action. offer.set_actions stores and re-runs
//!     the negotiation, and the negotiated wl_data_offer.action /
//!     wl_data_source.action events go out with v3 guards. No drag offer
//!     exists while start_drag is a stub (DnD deferred), so the events
//!     wait for the DnD state machine; the offer action STATE and
//!     negotiation are live.
//!   - offer.set_actions on a clipboard (non-drag) offer raises
//!     wl_data_offer.error.invalid_offer (wayland.xml: "This request can
//!     only be made on drag-and-drop offers, a protocol error will be
//!     raised otherwise"; wlroots data_offer_handle_set_actions).
//!   - offer.receive relays the fd to the source only when the requested
//!     mime type was actually offered; an unknown mime closes the fd
//!     without a relay (smithay offer.rs hardening; wlroots relays
//!     blindly).
//!   - data_source teardown (destroy/cancel) clears the stored selection
//!     and destroys the offers that referenced it.
//!
//! Drag-and-drop (start_drag) is not implemented in M3: the request is
//! accepted, the source is cancelled, no drag icon is shown. The
//! action-negotiation machinery above is wired for the future drag
//! state machine (drag offers would be created with offer_type = .drag).
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
    /// The serial the current selection was set with (wlr_seat
    /// .selection_serial). A set_selection whose serial is older than
    /// this by more than half the wrap range is superseded and rejected
    /// (wlroots wlr_seat_request_set_selection, wlr_data_device.c:148-153).
    selection_serial: u32 = 0,
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
    /// null = never set — the wlroots -1 sentinel; the negotiation
    /// treats such a source as copy-only (wlr_data_offer.c:32-37).
    /// Clipboard selection never uses actions, but the mask is validated
    /// and stored so wl_data_offer.set_actions can run its
    /// invalid_action check against it and the future drag negotiation
    /// can read it.
    actions: ?u32 = null,
    /// The source was handed to wl_data_device.set_selection or
    /// start_drag: it is used once (wlroots finalizes it,
    /// wlr_data_device.c:34-37, :82-85). After finalize, set_actions
    /// raises invalid_action_mask (wlr_data_source.c:173-178) and
    /// offer() only logs.
    finalized: bool = false,
    /// The action the compositor forces for a drag (wlroots:
    /// wlr_data_source.compositor_action). 0 = none. Wins the
    /// negotiation when the source and destination both support it.
    /// Set by the compositor before the drag starts.
    compositor_action: u32 = 0,
    /// The currently negotiated action for the in-flight drag (wlroots:
    /// wlr_data_source.current_dnd_action). 0 = none. Read back by the
    /// drop/finish paths of the future DnD state machine.
    current_dnd_action: u32 = 0,
    /// The destination accepted a mime via wl_data_offer.accept: true
    /// for a non-NULL mime, false on NULL/leave (wlroots:
    /// wlr_data_source.accepted). Drives the finish validation in the
    /// future DnD state machine.
    accepted: bool = false,
};

/// The kind of offer (wlroots enum wlr_data_offer_type): a selection
/// (clipboard) offer or a drag-and-drop offer. set_actions and accept
/// only apply to drag offers; with DnD deferred, every offer created
/// today is a selection offer and the future drag state machine creates
/// drag offers.
const OfferType = enum { selection, drag };

/// A data offer delivered to a target client.
const DataOffer = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataOffer,
    /// The offering client's source. Nulled when the offer is destroyed
    /// (the source may already be freed), so a dead offer never reads
    /// freed source memory (wlroots nulls offer->source in
    /// data_offer_handle_source_destroy, wlr_data_offer.c).
    source: ?*DataSource,
    offer_type: OfferType = .selection,
    /// The destination's supported action mask
    /// (wl_data_offer.set_actions; wlroots data_offer->actions).
    actions: u32 = 0,
    /// The destination's preferred action
    /// (wl_data_offer.set_actions; wlroots data_offer->preferred_action).
    preferred_action: u32 = 0,
};

/// wl_data_device_manager.dnd_action bits (wayland.xml).
const dnd_action_none: u32 = 0;
const dnd_action_copy: u32 = 1;
const dnd_action_move: u32 = 2;
const dnd_action_ask: u32 = 4;

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
            // The child inherits the manager's bound version (wlroots:
            // client_data_source_create(client,
            // wl_resource_get_version(manager_resource), ...,
            // wlr_data_device.c:259). The wire carries only the object id,
            // so libwayland-server never sets the child version — a v1
            // manager client must get v1 children, or since-3 requests
            // would be accepted against a client that never agreed to them.
            const src_res = server.wl.DataSource.create(resource.getClient(), resource.getVersion(), r.id) catch {
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
            // The device inherits the manager's bound version (wlroots:
            // data_device_manager_get_data_device,
            // wl_resource_get_version(manager_resource),
            // wlr_data_device.c:232-234).
            const dev_res = server.wl.DataDevice.create(resource.getClient(), resource.getVersion(), r.id) catch {
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
            const mgr = src.manager;
            // wlroots logs a debug message when a finalized source offers
            // more mimes (wlr_data_source.c:199-200); the offer is still
            // accepted and delivered.
            if (src.finalized) {
                log.debug(
                    "offering additional mime type after wl_data_device.set_selection/start_drag",
                    mgr.io,
                    mgr.log_cfg,
                    "data_device",
                    .{},
                );
            }
            const mime = std.mem.span(r.mime_type);
            // Duplicate offers are ignored (wlroots dedups,
            // wlr_data_source.c:201-204; primary_selection.zig does the
            // same).
            for (src.mime_types.items) |m| {
                if (std.mem.eql(u8, m, mime)) return;
            }
            const copy = mgr.allocator.dupeZ(u8, mime) catch {
                src_res.postNoMemory();
                return;
            };
            src.mime_types.append(mgr.allocator, copy) catch {
                mgr.allocator.free(copy);
                src_res.postNoMemory();
                return;
            };
        },
        .set_actions => |r| {
            // wayland.xml wl_data_source.set_actions, per wlroots
            // data_source_set_actions (wlr_data_source.c:152-182):
            //   1. once-only: a second set_actions is invalid_action_mask
            //      (wlroots: actions >= 0 sentinel);
            //   2. the source side may only offer copy and move (ask is
            //      destination-only); any other bit is
            //      invalid_action_mask;
            //   3. a finalized source (already handed to set_selection or
            //      start_drag) cannot change actions:
            //      invalid_action_mask.
            if (src.actions != null) {
                src_res.postError(
                    .invalid_action_mask,
                    "wl_data_source.set_actions: cannot set actions more than once",
                );
                return;
            }
            const valid: u32 = 1 | 2; // copy | move
            const dnd_actions: u32 = @bitCast(r.dnd_actions);
            if (dnd_actions & ~valid != 0) {
                src_res.postError(.invalid_action_mask, "wl_data_source.set_actions: invalid dnd_actions");
                return;
            }
            if (src.finalized) {
                src_res.postError(
                    .invalid_action_mask,
                    "wl_data_source.set_actions: invalid action change after wl_data_device.set_selection/start_drag",
                );
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
            // The source is finalized (used once) BEFORE the serial
            // validation, per wlroots data_device_set_selection
            // (wlr_data_device.c:24-45: finalize at :34-37, then
            // wlr_seat_request_set_selection validates): a request the
            // gates reject still burns the source.
            if (r.source) |src_res| {
                const src: *DataSource = @ptrCast(@alignCast(src_res.getUserData()));
                // KWin hardening: a source that advertised DnD actions
                // cannot be a clipboard source — invalid_source on the
                // source (KWin data_device_set_selection,
                // datadevice.cpp:91-101; wlroots has no such check).
                if ((src.actions orelse 0) != 0) {
                    src_res.postError(
                        .invalid_source,
                        "wl_data_source.set_selection: data source is for drag and drop",
                    );
                    return;
                }
                src.finalized = true;
            }
            // Serial validation (wlroots wlr_seat_request_set_selection,
            // wlr_data_device.c:144-165): the serial must have been
            // handed to THIS client recently (per-client ring,
            // Seat.validateEventSerial), and must not be superseded by
            // the current selection's serial. A stale serial is silently
            // ignored — never a protocol error — like wlroots.
            if (!mgr.seat.validateEventSerial(dev_res.getClient(), r.serial)) {
                log.debug(
                    "rejecting set_selection: serial {d} was never given to this client",
                    mgr.io,
                    mgr.log_cfg,
                    "data_device",
                    .{r.serial},
                );
                return;
            }
            if (mgr.selection_source != null and
                r.serial -% mgr.selection_serial > std.math.maxInt(u32) / 2)
            {
                log.debug(
                    "rejecting set_selection: serial {d} indicates superseded (selection at {d})",
                    mgr.io,
                    mgr.log_cfg,
                    "data_device",
                    .{ r.serial, mgr.selection_serial },
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
                mgr.selection_serial = r.serial;
                log.debug("selection set with {d} mime types", mgr.io, mgr.log_cfg, "data_device", .{
                    src.mime_types.items.len,
                });
            } else {
                // Null source: clear the selection.
                if (mgr.selection_source) |old| {
                    old.resource.sendCancelled();
                }
                mgr.selection_source = null;
                mgr.selection_serial = r.serial;
            }
            deliverSelectionToFocus(mgr);
        },
        .start_drag => |r| {
            const mgr = dev.manager;
            // The source is finalized before the serial check (wlroots
            // data_device_start_drag, wlr_data_device.c:47-87:
            // finalize at :82-85, then wlr_seat_request_start_drag
            // validates the pointer grab serial): a denied drag still
            // burns the source, but leaves it alive — the client keeps
            // it (smithay "denying drag from client without implicit
            // grab", data_device/device.rs).
            if (r.source) |src_res| {
                const src: *DataSource = @ptrCast(@alignCast(src_res.getUserData()));
                src.finalized = true;
            }
            // The drag serial must have been handed to THIS client
            // (wlroots validates the pointer grab serial via the
            // per-client ring, wlr_seat_pointer.c:603-617).
            if (!mgr.seat.validateEventSerial(dev_res.getClient(), r.serial)) {
                log.debug(
                    "rejecting start_drag: serial {d} was never given to this client",
                    mgr.io,
                    mgr.log_cfg,
                    "data_device",
                    .{r.serial},
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
            // The offer is introduced in a data_device event, so its
            // version follows the device's (wlroots: data_offer_create,
            // wl_resource_get_version(device_resource),
            // wlr_data_offer.c:249-251) — never the module maximum.
            const offer_res = server.wl.DataOffer.create(focus_client, dev.resource.getVersion(), 0) catch return;
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

/// The compositor-chosen action for a drag offer, per wlroots
/// data_offer_choose_action (wlr_data_offer.c:22-55) on raw state:
/// the intersection of the destination's mask and the source's actions
/// (a source that never called set_actions is copy-only); the
/// compositor-forced action wins when both sides support it, then the
/// destination's preferred action, then the lowest common action bit.
fn chooseActionRaw(
    offer_actions: u32,
    source_actions: ?u32,
    compositor_action: u32,
    preferred_action: u32,
) u32 {
    const src_actions = source_actions orelse dnd_action_copy;
    const available = offer_actions & src_actions;
    if (available == 0) return dnd_action_none;
    if (compositor_action & available != 0) return compositor_action;
    if (preferred_action & available != 0) return preferred_action;
    // First found action, in bit order (wlroots: 1 << (ffs(available) - 1);
    // available & -available is the lowest set bit).
    return available & -%available;
}

fn chooseAction(offer: *DataOffer) u32 {
    const src = offer.source orelse return dnd_action_none;
    // Pre-v3 offers cannot send set_actions; wlroots treats their mask
    // as copy-only (wlr_data_offer.c:28-31).
    const offer_actions = if (offer.resource.getVersion() >= 3) offer.actions else dnd_action_copy;
    return chooseActionRaw(offer_actions, src.actions, src.compositor_action, offer.preferred_action);
}

/// Recompute the negotiated action for a drag offer and emit it to both
/// sides when it changed (wlroots data_offer_update_action,
/// wlr_data_offer.c:57-76). The source's current action is stored so the
/// drop/finish paths of the future DnD state machine can read it back.
/// Emission only happens for drag offers; with DnD deferred (DD-1) no
/// drag offer exists yet, so the wl_data_offer.action /
/// wl_data_source.action events wait for the drag state machine. wlroots
/// also suppresses the events during "ask" negotiation (offer->in_ask,
/// declared in wlr_data_device.h:43 but never set in 0.20.2); not
/// modeled here.
fn updateAction(offer: *DataOffer) void {
    const src = offer.source orelse return;
    const action = chooseAction(offer);
    if (src.current_dnd_action == action) return;
    src.current_dnd_action = action;
    if (src.resource.getVersion() >= 3) {
        src.resource.sendAction(@bitCast(action));
    }
    if (offer.resource.getVersion() >= 3) {
        offer.resource.sendAction(@bitCast(action));
    }
}

fn offerRequest(offer_res: *server.wl.DataOffer, request: server.wl.DataOffer.Request, offer: *DataOffer) void {
    switch (request) {
        .accept => |r| {
            // wlroots data_offer_handle_accept (wlr_data_offer.c:78-92):
            // only drag offers relay accept feedback to the source;
            // selection offers ignore it. The relay records the source's
            // accepted state and forwards the mime as
            // wl_data_source.target (a since-3 event, version-guarded).
            if (offer.offer_type != .drag) return;
            const src = offer.source orelse return;
            src.accepted = r.mime_type != null;
            if (src.resource.getVersion() >= 3) {
                src.resource.sendTarget(r.mime_type);
            }
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
            // smithay hardening (selection/offer.rs:165-168): a mime the
            // source never offered is denied — the fd is closed and no
            // send is relayed (wlroots relays blindly).
            const mime = std.mem.span(r.mime_type);
            var offered = false;
            for (src.mime_types.items) |m| {
                if (std.mem.eql(u8, m, mime)) {
                    offered = true;
                    break;
                }
            }
            if (!offered) {
                log.debug(
                    "offer.receive denied: mime '{s}' was not offered",
                    offer.manager.io,
                    offer.manager.log_cfg,
                    "data_device",
                    .{mime},
                );
                _ = std.os.linux.close(r.fd);
                return;
            }
            src.resource.sendSend(r.mime_type, r.fd);
            _ = std.os.linux.close(r.fd);
            log.debug("offer.receive relayed ({s})", offer.manager.io, offer.manager.log_cfg, "data_device", .{
                mime,
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
            // data_offer_handle_set_actions, wlr_data_offer.c:155-189):
            //   - dnd_actions must contain only dnd_action enum values
            //     and preferred_action must be a single one of them,
            //     else invalid_action_mask;
            //   - a preferred action the source does not support (a
            //     source without action support has mask 0) is
            //     invalid_action;
            //   - only drag-and-drop offers accept set_actions; a
            //     clipboard offer raises invalid_offer (wayland.xml:
            //     "This request can only be made on drag-and-drop
            //     offers, a protocol error will be raised otherwise";
            //     wlroots data_offer_handle_set_actions O:178-182).
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
            if (preferred_action != 0 and ((src.actions orelse 0) & preferred_action) == 0) {
                offer_res.postError(
                    .invalid_action,
                    "wl_data_offer.set_actions: preferred action not supported by the source",
                );
                return;
            }
            if (offer.offer_type != .drag) {
                offer_res.postError(.invalid_offer, "wl_data_offer.set_actions: not a drag-and-drop offer");
                return;
            }
            // A drag offer stores the destination's mask/preference and
            // re-runs the negotiation (wlroots O:184-189).
            offer.actions = dnd_actions;
            offer.preferred_action = preferred_action;
            updateAction(offer);
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
    send_count: usize = 0,
    /// wl_data_source.action events (the negotiated DnD action, emitted
    /// for drag offers).
    action_count: usize = 0,
    last_action: u32 = 0,
    /// wl_data_source.target events (accept feedback, drag offers only).
    target_count: usize = 0,
    last_target: []const u8 = "",

    fn listener(source: *client.wl.DataSource, event: client.wl.DataSource.Event, data: *SourceEvents) void {
        _ = source;
        switch (event) {
            .cancelled => data.cancelled_count += 1,
            .send => data.send_count += 1,
            .action => |e| {
                data.action_count += 1;
                const v: u32 = @bitCast(e.dnd_action);
                data.last_action = v;
            },
            .target => |e| {
                data.target_count += 1;
                data.last_target = if (e.mime_type) |m| std.mem.span(m) else "";
            },
            // DnD lifecycle events: the test client never drags; the
            // arms exist for the exhaustive switch over the wire enum
            // (the future DnD state machine would emit them).
            .dnd_drop_performed => {},
            .dnd_finished => {},
        }
    }
};

/// Records wl_data_offer.action events (the negotiated DnD action).
const OfferEvents = struct {
    action_count: usize = 0,
    last_action: u32 = 0,

    fn listener(offer: *client.wl.DataOffer, event: client.wl.DataOffer.Event, data: *OfferEvents) void {
        _ = offer;
        switch (event) {
            .action => |e| {
                data.action_count += 1;
                const v: u32 = @bitCast(e.dnd_action);
                data.last_action = v;
            },
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
    /// A second client on its own socketpair, for focus-move tests:
    /// client A owns the selection, client B gains keyboard focus and
    /// must receive the re-delivered offer (the seat and primary
    /// selection tests use the same two-client shape). B binds the same
    /// globals and creates its own focusable surface, but never a data
    /// device unless a test asks for one, so the single-client tests'
    /// device/source/offer counts are unaffected.
    client_b: ?*wire.Client = null,
    c_display_b: ?*client.wl.Display = null,
    wl_compositor_b: ?*client.wl.Compositor = null,
    wl_seat_b: ?*client.wl.Seat = null,
    wl_data_device_manager_b: ?*client.wl.DataDeviceManager = null,
    surface_b: ?*client.wl.Surface = null,
    /// Mirrors main.zig's onSurfaceDestroy wiring: the seat's focus is
    /// cleared when a test client's surface is destroyed (client
    /// teardown, or an explicit wl_surface.destroy), so the seat never
    /// holds a dangling surface and deliverSelectionToFocus never reads
    /// freed surface memory (production calls Seat.surfaceDestroyed from
    /// onSurfaceDestroy, main.zig; the TestServer drives the protocol
    /// directly, so the wiring must be replicated here). One listener
    /// per client surface.
    surface_listener: wire.Listener(*surface_mod.Surface),
    surface_listener_b: wire.Listener(*surface_mod.Surface),

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, seat and manager all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        return initAtVersion(allocator, 3);
    }

    /// init with wl_data_device_manager bound at an explicit version, for
    /// the legacy-version conformance tests (a v1 manager client speaks an
    /// older wire: its child objects must be created at v1, not at the
    /// module maximum).
    fn initAtVersion(allocator: std.mem.Allocator, ddm_version: u32) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
            .surface_listener = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroy),
            .surface_listener_b = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroyB),
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
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
            ddm_version,
        );
        try ts.pump();
        // Production clears the seat focus from main.zig's
        // onSurfaceDestroy; this harness drives the protocol directly, so
        // wire the seat's surfaceDestroyed to the client's surface here
        // (same effect: the focus never outlives its surface).
        const srv_surface = surfaceForClient(ts, ts.client.?);
        srv_surface.events.destroy.add(&ts.surface_listener);

        // Second client: B binds the same globals on its own socketpair
        // and creates its own focusable surface. Connected before the
        // harness returns so every test can move keyboard focus between
        // two clients (same two-client shape as the seat and primary
        // selection tests).
        var fds_b: [2]posix.socket_t = undefined;
        const rc_b = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds_b);
        if (posix.errno(rc_b) != .SUCCESS) return error.SocketpairFailed;
        ts.client_b = wire.Client.create(ts.display.?.getServer(), fds_b[0]) orelse return error.ClientCreateFailed;
        ts.c_display_b = client.wl.Display.connectToFd(fds_b[1]) catch return error.ClientConnectFailed;

        // Round 1: registry + global announcements.
        const registry_b = try ts.c_display_b.?.getRegistry();
        var capture_b: RegistryCapture = .{};
        registry_b.setListener(*RegistryCapture, RegistryCapture.listener, &capture_b);
        try ts.pump();
        if (capture_b.compositor_name == null or
            capture_b.seat_name == null or
            capture_b.data_device_manager_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor (to create a focusable surface),
        // wl_seat and wl_data_device_manager.
        ts.wl_compositor_b = try registry_b.bind(capture_b.compositor_name.?, client.wl.Compositor, 7);
        ts.surface_b = try ts.wl_compositor_b.?.createSurface();
        ts.wl_seat_b = try registry_b.bind(capture_b.seat_name.?, client.wl.Seat, 7);
        ts.wl_data_device_manager_b = try registry_b.bind(
            capture_b.data_device_manager_name.?,
            client.wl.DataDeviceManager,
            ddm_version,
        );
        try ts.pump();
        const srv_surface_b = surfaceForClient(ts, ts.client_b.?);
        srv_surface_b.events.destroy.add(&ts.surface_listener_b);
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

    /// Client B's surface died: clear the seat's focus for B's surface
    /// too (same wiring as onSurfaceDestroy; a focus held on B's surface
    /// at teardown must not dangle).
    fn onSurfaceDestroyB(listener: *wire.Listener(*surface_mod.Surface), surface: *surface_mod.Surface) void {
        const ts: *TestServer = @fieldParentPtr("surface_listener_b", listener);
        if (ts.seat) |seat| seat.surfaceDestroyed(surface);
    }

    fn deinit(ts: *TestServer) void {
        // Tear the clients down first (LIFO): their resource destroy
        // handlers (sourceDestroy/deviceDestroy) must run while the
        // manager lives. A client dropped by a protocol error has its
        // server-side resource already destroyed by the server, so its
        // `client` pointer is null and only the display is disconnected.
        if (ts.c_display_b) |d| d.disconnect();
        if (ts.client_b) |c| c.destroy();
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
    /// client dispatch. Drives one roundtrip without blocking. Tolerates
    /// a client that has not connected yet (initAtVersion connects B
    /// with only client A live) and a client dropped by a protocol error.
    fn pump(ts: *TestServer) !void {
        if (ts.c_display) |d| {
            if (d.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        if (ts.c_display_b) |d| {
            if (d.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        var fds: [2]posix.pollfd = undefined;
        var count: usize = 0;
        if (ts.c_display) |d| {
            fds[count] = .{ .fd = d.getFd(), .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        if (ts.c_display_b) |d| {
            fds[count] = .{ .fd = d.getFd(), .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        if (count == 0) return;
        if (try posix.poll(fds[0..count], 0) > 0) {
            for (fds[0..count]) |fd| {
                if (fd.revents & posix.POLL.IN == 0) continue;
                const is_a = ts.c_display != null and fd.fd == ts.c_display.?.getFd();
                const disp = if (is_a) ts.c_display.? else ts.c_display_b.?;
                if (disp.dispatch() != .SUCCESS) {
                    // Protocol error or disconnect: the server has already
                    // destroyed its client (dangling) — forget it for deinit.
                    if (is_a) ts.client = null else ts.client_b = null;
                    return error.ClientDispatchFailed;
                }
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

/// Focus the test client's surface and return a serial that validates
/// for it. The seat records a serial in the receiving client's ring on
/// every input delivery (seat.zig serialFor); keyboard focus is one, so
/// the focus serial is the one to echo back in set_selection/start_drag.
fn focusAndMintSerial(ts: *TestServer) u32 {
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client.?));
    return ts.seat.?.last_serial;
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

    // A serial the seat handed to this client (the seat's per-client
    // ring rejects everything else, wlroots model).
    const serial = focusAndMintSerial(ts);

    // Client sets the selection: stored on the manager (seat-wide), not on
    // the device; the source is not cancelled.
    device.setSelection(src_a, serial);
    try ts.pump();
    try testing.expect(ts.mgr.?.selection_source != null);
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 0), events_a.cancelled_count);

    // Replacing with a different source cancels the previous owner.
    device.setSelection(src_b, serial);
    try ts.pump();
    try testing.expectEqual(src_b.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 1), events_a.cancelled_count);
    try testing.expectEqual(@as(usize, 0), events_b.cancelled_count);

    // Null source clears the seat-wide selection and cancels the owner.
    device.setSelection(null, serial);
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

    device.setSelection(src, focusAndMintSerial(ts));
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

    device.setSelection(src, focusAndMintSerial(ts));
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

    // A serial the seat handed to this client: accepted (the seat's
    // per-client ring, wlroots wlr_seat_client_validate_event_serial).
    const serial = focusAndMintSerial(ts);
    device.setSelection(src, serial);
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());

    // A serial the seat never issued to this client: the request is
    // ignored, the selection is untouched and the source is not
    // cancelled (wlroots logs and returns — it never posts a protocol
    // error). serial 0 is rejected too: the ring is empty of 0 once
    // real serials exist (wlroots parity).
    const stale = ts.seat.?.display.nextSerial();
    try testing.expect(stale != serial);
    device.setSelection(null, stale);
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 0), events.cancelled_count);

    // Clearing with the valid serial still works.
    device.setSelection(null, serial);
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

/// Device events for the focus-move test: counts selections and captures
/// the mime list of each received offer. The offer listener is attached
/// from inside the data_offer handler so it is live before the offer's
/// own events are dispatched in the same round (the server sends
/// data_offer -> mimes -> selection, deliverSelectionToFocus). This
/// struct is test-local because attaching an offer listener from the
/// device listener would collide with tests that setListener the same
/// offer proxy again (wl_proxy_add_dispatcher asserts on a second
/// listener).
const FocusEvents = struct {
    selection_count: usize = 0,
    last_selection_null: bool = false,
    mime_count: usize = 0,
    has_text_plain: bool = false,

    fn listener(device: *client.wl.DataDevice, event: client.wl.DataDevice.Event, data: *FocusEvents) void {
        _ = device;
        switch (event) {
            .selection => |e| {
                data.selection_count += 1;
                data.last_selection_null = e.id == null;
            },
            .data_offer => |e| e.id.setListener(*FocusEvents, FocusEvents.offerListener, data),
            // DnD events: the test client never drags; the arms exist for
            // exhaustive switch over the wire event enum.
            .enter => {},
            .leave => {},
            .motion => {},
            .drop => {},
        }
    }

    fn offerListener(offer: *client.wl.DataOffer, event: client.wl.DataOffer.Event, data: *FocusEvents) void {
        _ = offer;
        switch (event) {
            .offer => |e| {
                data.mime_count += 1;
                if (std.mem.eql(u8, std.mem.span(e.mime_type), "text/plain")) data.has_text_plain = true;
            },
            // DnD negotiation events: the test client never negotiates
            // (offers are clipboard offers); the arm exists for the
            // exhaustive switch over the wire event enum.
            .action => |e| {
                const v: u32 = @bitCast(e.dnd_action);
                _ = v;
            },
            .source_actions => |e| {
                const v: u32 = @bitCast(e.source_actions);
                _ = v;
            },
        }
    }
};

test "selection is re-delivered to the newly focused client on keyboard focus enter" {
    // S4: the seat re-emits keyboard_focus AFTER enter+modifiers when
    // focus moves (seat.zig:858), and data_device re-delivers the
    // stored seat-wide selection to the newly focused client on that
    // signal (onKeyboardFocus -> deliverSelectionToFocus): a live
    // non-null selection set by client A must reach client B as a fresh
    // data_offer + selection when B gains keyboard focus, with B's
    // offer carrying A's mime and A's previous offer destroyed (one
    // live offer total; wlroots seat_client_send_selection destroys
    // all offers before re-sending, wlr_data_device.c).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Client A (the owner) and client B (the focus target): each binds
    // its own data device.
    const device_a = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const device_b = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var events_a: FocusEvents = .{};
    var events_b: FocusEvents = .{};
    device_a.setListener(*FocusEvents, FocusEvents.listener, &events_a);
    device_b.setListener(*FocusEvents, FocusEvents.listener, &events_b);
    try ts.pump();

    // Focus client A and set a live selection.
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client.?));
    try ts.pump();
    const serial = ts.seat.?.last_serial;
    device_a.setSelection(src, serial);
    try ts.pump();
    // A holds the only offer (focus-enter NULL delivery + the selection
    // delivery); B, never focused, has received nothing.
    try testing.expectEqual(@as(usize, 2), events_a.selection_count);
    try testing.expect(!events_a.last_selection_null);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    try testing.expectEqual(@as(usize, 0), events_b.selection_count);

    // Focus moves to client B: the stored selection is re-delivered.
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client_b.?));
    try ts.pump();

    // B receives exactly one data_offer + selection, and the offer
    // carries A's mime ("text/plain").
    try testing.expectEqual(@as(usize, 1), events_b.selection_count);
    try testing.expect(!events_b.last_selection_null);
    try testing.expectEqual(@as(usize, 1), events_b.mime_count);
    try testing.expect(events_b.has_text_plain);

    // A's previous offer was destroyed: exactly one live offer remains
    // (B's), referencing A's source, and A receives no new events.
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    try testing.expectEqual(src.getId(), ts.mgr.?.offers.items[0].source.?.resource.getId());
    try testing.expectEqual(@as(usize, 2), events_a.selection_count);
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

test "source finalized at set_selection: later set_actions raises invalid_action_mask" {
    // DD-3: a source handed to set_selection is used once (wlroots
    // finalizes it, wlr_data_device.c:34-37); wayland.xml: "The given
    // source may not be used in any further set_selection or start_drag
    // requests". set_actions on a finalized source raises
    // invalid_action_mask (wlroots data_source_set_actions,
    // wlr_data_source.c:173-178).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    try ts.pump();
    const serial = focusAndMintSerial(ts);

    device.setSelection(src, serial);
    try ts.pump();
    try testing.expectEqual(serial, ts.mgr.?.selection_serial);
    try testing.expect(ts.mgr.?.sources.items[0].finalized);

    const DndAction = client.wl.DataDeviceManager.DndAction;
    src.setActions(@as(DndAction, @bitCast(@as(u32, 1))));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "source finalized at start_drag: later set_actions raises invalid_action_mask" {
    // DD-3: start_drag finalizes the source too (wlroots
    // wlr_data_device.c:82-85), even though our start_drag is a stub
    // that cancels the source.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    try ts.pump();
    const serial = focusAndMintSerial(ts);

    device.startDrag(src, ts.surface.?, null, serial);
    try ts.pump();
    try testing.expect(ts.mgr.?.sources.items[0].finalized);
    // The M3 stub cancels the (accepted) drag source.
    try testing.expectEqual(@as(usize, 1), src_events.cancelled_count);

    const DndAction = client.wl.DataDeviceManager.DndAction;
    src.setActions(@as(DndAction, @bitCast(@as(u32, 1))));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "a serial-rejected set_selection still finalizes the source" {
    // DD-3 + DD-4 ordering: wlroots finalizes BEFORE validating the
    // serial (wlr_data_device.c:24-45), so a request the serial gate
    // rejects burns the source anyway — its set_actions now errors.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    try ts.pump();
    _ = focusAndMintSerial(ts);
    const stale = ts.seat.?.display.nextSerial(); // never handed to the client

    device.setSelection(src, stale);
    try ts.pump();
    // Nothing was selected...
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);
    // ...but the source was burned (wlroots parity).
    try testing.expect(ts.mgr.?.sources.items[0].finalized);

    const DndAction = client.wl.DataDeviceManager.DndAction;
    src.setActions(@as(DndAction, @bitCast(@as(u32, 1))));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "superseded set_selection serials are rejected" {
    // DD-4: wlroots wlr_seat_request_set_selection (wlr_data_device.c:
    // 148-153) rejects a serial older than the current selection's by
    // more than half the wrap range, even when it validates.
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
    try ts.pump();
    const serial = focusAndMintSerial(ts);

    device.setSelection(src_a, serial);
    try ts.pump();
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());

    // Simulate the selection having been set with a serial half a wrap
    // in the future (unreachable through the wire in a test session):
    // any request serial is now superseded. The request is rejected —
    // selection unchanged, no cancel — but the source is still burned
    // (finalize before the gates, wlroots).
    ts.mgr.?.selection_serial = serial +% 0x8000_0000;
    device.setSelection(src_b, serial);
    try ts.pump();
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 0), events_a.cancelled_count);
    try testing.expectEqual(@as(usize, 0), events_b.cancelled_count);
    try testing.expect(ts.mgr.?.sources.items[1].finalized);

    // Restore the recorded serial: a normal re-set works and cancels
    // the previous owner.
    ts.mgr.?.selection_serial = serial;
    device.setSelection(src_b, serial);
    try ts.pump();
    try testing.expectEqual(src_b.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 1), events_a.cancelled_count);
    try testing.expectEqual(@as(usize, 0), events_b.cancelled_count);
}

test "set_actions on a clipboard offer raises invalid_offer" {
    // DD-5: wayland.xml wl_data_offer.set_actions — "This request can
    // only be made on drag-and-drop offers, a protocol error will be
    // raised otherwise"; wlroots posts WL_DATA_OFFER_ERROR_INVALID_OFFER
    // (3) after the mask/preferred checks (wlr_data_offer.c:178-182).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);
    try ts.pump();
    const serial = focusAndMintSerial(ts);
    device.setSelection(src, serial);
    try ts.pump();
    try testing.expect(dev_events.last_offer != null);

    const DndAction = client.wl.DataDeviceManager.DndAction;
    dev_events.last_offer.?.setActions(
        @as(DndAction, @bitCast(@as(u32, 1))),
        @as(DndAction, @bitCast(@as(u32, 0))),
    );
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 3), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "set_selection with a DnD-action source raises invalid_source" {
    // DD-6: KWin hardening — a source that advertised DnD actions
    // cannot be a clipboard source (KWin data_device_set_selection,
    // datadevice.cpp:91-101): wl_data_source.error.invalid_source (1)
    // on the source. wlroots has no such check.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    const DndAction = client.wl.DataDeviceManager.DndAction;
    src.setActions(@as(DndAction, @bitCast(@as(u32, 1))));
    try ts.pump();

    // The serial never matters: the KWin check fires before any serial
    // validation.
    device.setSelection(src, 0);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, null));
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);
}

test "offer.receive with an unoffered mime closes the fd and relays nothing" {
    // DD-7: smithay hardening (selection/offer.rs:165-168) — receive()
    // validates the mime against the offered list; an unknown mime
    // closes the fd and never relays a send (wlroots relays blindly).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);
    try ts.pump();
    const serial = focusAndMintSerial(ts);
    device.setSelection(src, serial);
    try ts.pump();
    const offer = dev_events.last_offer.?;

    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    offer.receive("application/x-unknown", fds[0]);
    try ts.pump();
    // No send relayed to the source...
    try testing.expectEqual(@as(usize, 0), src_events.send_count);
    // The client transfers ownership of its copy (protocol semantics);
    // libwayland-client does not close it for us.
    _ = std.os.linux.close(fds[0]);
    // ...and the server closed ITS copy too: with both copies of the
    // peer end gone, sending on the other end is EPIPE. Raw syscall with
    // MSG_NOSIGNAL keeps it an error instead of a SIGPIPE (0.16 has no
    // std.posix.write; linux.sendto returns a negated errno).
    const send_rc = std.os.linux.sendto(fds[1], "x", 1, std.os.linux.MSG.NOSIGNAL, null, 0);
    try testing.expectEqual(std.os.linux.E.PIPE, std.os.linux.errno(send_rc));
    _ = std.os.linux.close(fds[1]);

    // An offered mime still relays.
    var fds2: [2]posix.socket_t = undefined;
    const rc2 = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds2);
    if (posix.errno(rc2) != .SUCCESS) return error.SocketpairFailed;
    offer.receive("text/plain", fds2[0]);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), src_events.send_count);
    _ = std.os.linux.close(fds2[0]);
    _ = std.os.linux.close(fds2[1]);
}

test "action negotiation matrix matches wlroots data_offer_choose_action" {
    // DD-2: direct unit test of the negotiation against the wlroots
    // algorithm (data_offer_choose_action, wlr_data_offer.c:22-55):
    // mask intersection, compositor-forced action, destination
    // preferred, lowest-bit fallback, copy default for unset source
    // actions.
    // No intersection -> none.
    try testing.expectEqual(@as(u32, 0), chooseActionRaw(dnd_action_move, dnd_action_copy, 0, 0));
    // A source that never called set_actions is copy-only.
    try testing.expectEqual(@as(u32, 1), chooseActionRaw(dnd_action_copy, null, 0, 0));
    try testing.expectEqual(@as(u32, 0), chooseActionRaw(dnd_action_move, null, 0, 0));
    // The compositor-forced action wins when both sides support it.
    try testing.expectEqual(@as(u32, 2), chooseActionRaw(3, 3, dnd_action_move, dnd_action_copy));
    // ...and is ignored when either side lacks it.
    try testing.expectEqual(@as(u32, 1), chooseActionRaw(3, 3, dnd_action_ask, dnd_action_copy));
    // The destination's preferred action wins when in the intersection.
    try testing.expectEqual(@as(u32, 4), chooseActionRaw(7, 7, 0, dnd_action_ask));
    try testing.expectEqual(@as(u32, 1), chooseActionRaw(7, 7, 0, 8)); // preferred outside -> fallback
    // Fallback: the lowest common action bit.
    try testing.expectEqual(@as(u32, 2), chooseActionRaw(6, 6, 0, 0));
    try testing.expectEqual(@as(u32, 1), chooseActionRaw(7, 7, 0, 0));
}

test "drag offer action negotiation stores state and emits action to both sides" {
    // DD-2: white-box drag simulation — with DnD deferred (DD-1) no
    // drag offer can be created through the protocol; the test flips
    // the delivered selection offer to a drag offer (as the future drag
    // state machine would create it) and drives the negotiation over
    // the wire. The negotiated action goes to both the destination
    // (wl_data_offer.action) and the source (wl_data_source.action),
    // version-guarded (v3 offers here).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);
    try ts.pump();
    const serial = focusAndMintSerial(ts);
    device.setSelection(src, serial);
    try ts.pump();
    const offer = dev_events.last_offer.?;

    const srv_offer = ts.mgr.?.offers.items[0];
    srv_offer.offer_type = .drag;

    const DndAction = client.wl.DataDeviceManager.DndAction;
    offer.setActions(@as(DndAction, @bitCast(@as(u32, 1))), @as(DndAction, @bitCast(@as(u32, 0))));
    var offer_events: OfferEvents = .{};
    offer.setListener(*OfferEvents, OfferEvents.listener, &offer_events);
    try ts.pump();

    // Negotiation: the source never called set_actions -> copy-only;
    // copy & copy = copy; no preferred; lowest bit = copy. The action is
    // stored on the offer and the source, and emitted to both sides.
    try testing.expectEqual(@as(u32, 1), srv_offer.actions);
    try testing.expectEqual(@as(u32, 0), srv_offer.preferred_action);
    try testing.expectEqual(@as(u32, 1), ts.mgr.?.selection_source.?.current_dnd_action);
    try testing.expectEqual(@as(usize, 1), offer_events.action_count);
    try testing.expectEqual(@as(u32, 1), offer_events.last_action);
    try testing.expectEqual(@as(usize, 1), src_events.action_count);
    try testing.expectEqual(@as(u32, 1), src_events.last_action);

    // A re-set that does not change the negotiated action emits nothing
    // (wlroots data_offer_update_action early-returns on an unchanged
    // action, wlr_data_offer.c:57-76). copy|move with no preferred still
    // negotiates copy (the source is copy-only), so no new events.
    offer.setActions(@as(DndAction, @bitCast(@as(u32, 3))), @as(DndAction, @bitCast(@as(u32, 0))));
    try ts.pump();
    try testing.expectEqual(@as(u32, 3), srv_offer.actions);
    try testing.expectEqual(@as(usize, 1), offer_events.action_count);
    try testing.expectEqual(@as(usize, 1), src_events.action_count);
}

test "drag offer accept relays the mime to the source as target" {
    // DD-2: wlroots data_offer_handle_accept (wlr_data_offer.c:78-92) —
    // a drag offer relays accept feedback to the source: the accepted
    // state is stored and the mime is forwarded as wl_data_source.target
    // (since-3, version-guarded). Selection offers ignore accept.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);
    try ts.pump();
    const serial = focusAndMintSerial(ts);
    device.setSelection(src, serial);
    try ts.pump();
    const offer = dev_events.last_offer.?;
    ts.mgr.?.offers.items[0].offer_type = .drag;

    offer.accept(serial, "text/plain");
    try ts.pump();
    try testing.expect(ts.mgr.?.selection_source.?.accepted);
    try testing.expectEqual(@as(usize, 1), src_events.target_count);
    try testing.expectEqualStrings("text/plain", src_events.last_target);

    // A NULL accept resets the accepted state and forwards target(NULL).
    offer.accept(serial, null);
    try ts.pump();
    try testing.expect(!ts.mgr.?.selection_source.?.accepted);
    try testing.expectEqual(@as(usize, 2), src_events.target_count);
    try testing.expectEqual(@as(usize, 0), src_events.last_target.len);
}

test "a second source.set_actions raises invalid_action_mask" {
    // DD-3 companion: wlroots once-only rule (wlr_data_source.c:166-170)
    // — set_actions may be called at most once, invalid_action_mask
    // otherwise (wayland.xml: the source side sets the actions once).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const src = try ts.wl_data_device_manager.?.createDataSource();
    const DndAction = client.wl.DataDeviceManager.DndAction;
    src.setActions(@as(DndAction, @bitCast(@as(u32, 1))));
    try ts.pump();
    try testing.expectEqual(@as(?u32, 1), ts.mgr.?.sources.items[0].actions);

    src.setActions(@as(DndAction, @bitCast(@as(u32, 2))));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "v1 manager creates v1 children" {
    // A client binding wl_data_device_manager at v1 must get v1
    // wl_data_source and wl_data_device children. The wire carries only
    // the object id — libwayland-server never sets the child version, so
    // a hardcoded 3 would accept since-3 requests (finish, set_actions)
    // against a client that never agreed to them.
    const allocator = testing.allocator;
    var ts = try TestServer.initAtVersion(allocator, 1);
    defer ts.deinit();

    _ = try ts.wl_data_device_manager.?.createDataSource();
    _ = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items.len);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items.len);
    try testing.expectEqual(@as(u32, 1), ts.mgr.?.sources.items[0].resource.getVersion());
    try testing.expectEqual(@as(u32, 1), ts.mgr.?.devices.items[0].resource.getVersion());
}

test "v3 manager creates v3 children" {
    // The default bind (module maximum 3): children carry version 3
    // server-side, so the since-3 requests stay available to a v3 client.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    _ = try ts.wl_data_device_manager.?.createDataSource();
    _ = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items.len);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items.len);
    try testing.expectEqual(@as(u32, 3), ts.mgr.?.sources.items[0].resource.getVersion());
    try testing.expectEqual(@as(u32, 3), ts.mgr.?.devices.items[0].resource.getVersion());
}
