//! zwlr_data_control_manager_v1 (wlroots/wlr-data-control-unstable-v1,
//! v2): a privileged client reads and owns the seat's selection without
//! holding keyboard focus.
//!
//! Scope: the manager global, the per-client zwlr_data_control_device_v1,
//! the client-created zwlr_data_control_source_v1 and the
//! zwlr_data_control_offer_v1 objects the compositor hands out. Two
//! directions:
//!
//!   - READ. The compositor is the data SOURCE: a device's `selection`
//!     offer is backed by whatever the real wl_data_device path
//!     (compositor/data_device.zig) currently holds, so a clipboard
//!     manager copies out of the ordinary clipboard without ever owning
//!     a keyboard focus or a wl_data_source of its own. The offer's
//!     MIME list is that source's, and `receive` relays the fd to its
//!     `wl_data_source.send` — the same MIME extraction, fd relay and
//!     unoffered-mime rejection data_device.zig already implements
//!     (offerRequest .receive; smithay offer.rs:165-168 hardening, which
//!     wlroots lacks).
//!   - WRITE. A privileged client takes the clipboard itself with
//!     `set_selection`. The source is used once, the replaced owner is
//!     cancelled (`cancelled` goes out, the resource stays alive so the
//!     client's later `destroy` still reaches us), and setting NULL hands
//!     the selection back to the mirrored seat selection.
//!
//! Shared behaviour, deliberately factored rather than copied: this
//! module owns its own Source/Device/Offer types — data_device.zig
//! declares `const DataSource`, so its source struct is unreachable by
//! name from here — but it reuses that module's semantics verbatim
//! (mime dedup, cancel-then-replace, offer supersession, the dead-source
//! sweep, inert-not-destroyed offer teardown). See
//! `DataControlManager` for the divergence list.
//!
//! Offer classes. Selection offers and primary-selection offers share
//! ONE list (mgr.offers) with DIFFERENT supersession rules, exactly
//! like data_device.zig's selection/drag split (wlroots keeps
//! seat->selection_offers and seat->drag_offers in two lists for the
//! same reason, wlr_data_offer.c:264-271). Every sweep filters on the
//! class, so re-delivering the clipboard never tears down a live
//! primary-selection offer and vice versa. And every offer is made DEAD
//! (origin = null) before the source it points at is freed
//! (freeSource), so a later `receive` can never read a freed source.
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, compositor/seat.zig,
//! compositor/data_device.zig, compositor/primary_selection.zig.

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const seat_mod = @import("seat.zig");
const surface_mod = @import("surface.zig");
const compositor_mod = @import("compositor.zig");
const data_device = @import("data_device.zig");
const primary_selection = @import("primary_selection.zig");

const server = @import("protocol").server;
const client = @import("protocol").client;

const log_tag = "data_control";

/// Which selection an offer carries. The two classes are superseded by
/// different rules, so every sweep over `mgr.offers` filters on this
/// (wlroots wlr_data_offer.c:264-271 keeps two lists for the same
/// reason).
const OfferClass = enum { selection, primary_selection };

/// Where an offer's payload comes from.
const Origin = union(enum) {
    /// A zwlr_data_control_source_v1 this module owns (create_data_source
    /// + set_selection). Module-owned, so freeSource can kill the offer
    /// before the struct goes.
    control: *Source,
    /// The live seat selection mirrored from compositor/data_device.zig
    /// (or compositor/primary_selection.zig for the primary class).
    /// Nothing of the other module's source struct is retained: the
    /// offer stores only its wire id, and every send re-reads the live
    /// source (see resolveBacking).
    seat,
};

/// Everything `receive` needs to answer one offer. The three source
/// interfaces (wl_data_source, zwp_primary_selection_source_v1,
/// zwlr_data_control_source_v1) each take the same `send(mime, fd)`
/// event but are distinct Zig types, and the first two belong to
/// file-private structs in other modules, so the resource is stored
/// erased together with the thunk that marshals its event.
const Backing = struct {
    /// The source's wire resource; `relay` knows how to interpret it.
    resource: *wire.Resource,
    /// The MIME types the offer advertised, borrowed from the source.
    mimes: []const [:0]const u8,
    /// The source's `send(mime, fd)` marshaller.
    relay: *const fn (res: *wire.Resource, mime: [*:0]const u8, fd: i32) void,
    /// The source's wire object id: how an offer recognises that the
    /// source it was minted from is still the live one.
    id: u32,
};

fn relayDataSource(res: *wire.Resource, mime: [*:0]const u8, fd: i32) void {
    const src: *server.wl.DataSource = @ptrCast(res);
    src.sendSend(mime, fd);
}

fn relayPrimarySource(res: *wire.Resource, mime: [*:0]const u8, fd: i32) void {
    const src: *server.zwp.PrimarySelectionSourceV1 = @ptrCast(res);
    src.sendSend(mime, fd);
}

fn relayControlSource(res: *wire.Resource, mime: [*:0]const u8, fd: i32) void {
    const src: *server.zwlr.DataControlSourceV1 = @ptrCast(res);
    src.sendSend(mime, fd);
}

pub const DataControlManager = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The seat this protocol mirrors. Null when the compositor has no
    /// seat: no focus listener is installed, `get_data_device` yields a
    /// dead device for any seat argument, and the mirrored read side is
    /// empty. Nothing dereferences it without the null check.
    seat: ?*seat_mod.Seat,
    /// The wl_data_device_manager whose selection readers see. Null
    /// disables the mirrored read side; the write side (a data-control
    /// client holding the clipboard itself) keeps working.
    data_devices: ?*data_device.DataDeviceManager,
    /// The primary-selection manager mirrored for v2's
    /// set_primary_selection / primary_selection. Null when the
    /// compositor has none: set_primary_selection is then ignored, as
    /// the XML requires ("The compositor will ignore this request if it
    /// does not support primary selection").
    primary: ?*primary_selection.PrimarySelection,
    /// The manager global, for teardown.
    global: ?*wire.Global = null,
    /// Every bound zwlr_data_control_device_v1 (get_data_device). One
    /// per resource, not per client: wlroots gives every call its own
    /// resource (data_control_manager_v1_bind) and this protocol has no
    /// drag path whose single offer slot a second device would orphan —
    /// the reason data_device.zig folds duplicates into one struct does
    /// not apply here.
    devices: std.ArrayList(*Device) = .empty,
    /// Every client-created source (create_data_source), a lifetime
    /// mirror of the manager: clients outlive it at shutdown, so deinit
    /// destroys these resources while the manager is still alive.
    sources: std.ArrayList(*Source) = .empty,
    /// Every live offer, both classes. See the module docs on the
    /// class-split invariant.
    offers: std.ArrayList(*Offer) = .empty,
    /// The clipboard a data-control client owns (set_selection), or null
    /// while the mirrored seat selection is the data-control selection.
    selection_source: ?*Source = null,
    /// The same for the primary selection (set_primary_selection).
    primary_source: ?*Source = null,
    /// deinit has begun. Every resource it owns is about to go, so a
    /// destroy handler must not re-announce a selection: a client that
    /// outlives the shutdown would otherwise receive a fresh offer
    /// minted by a dying manager. freeSource still nulls the manager's
    /// pointers and kills the affected offers, so the invariant that an
    /// offer never outlives its source holds during teardown too.
    destroying: bool = false,
    focus_listener: wire.Listener(*seat_mod.Seat),

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        seat: ?*seat_mod.Seat,
        data_devices: ?*data_device.DataDeviceManager,
        primary: ?*primary_selection.PrimarySelection,
    ) error{ OutOfMemory, GlobalCreateFailed }!*DataControlManager {
        const self = try allocator.create(DataControlManager);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .seat = seat,
            .data_devices = data_devices,
            .primary = primary,
            .focus_listener = focusListener(),
        };
        errdefer self.devices.deinit(allocator);
        errdefer self.sources.deinit(allocator);
        errdefer self.offers.deinit(allocator);
        self.global = try display.addGlobal(
            server.zwlr.DataControlManagerV1,
            *DataControlManager,
            bindManager,
            server.zwlr.DataControlManagerV1.generated_version,
            self,
        );
        // Re-announce the clipboard when the keyboard focus moves (the
        // same trigger compositor/data_device.zig uses for its own
        // delivery; see divergence 3).
        if (seat) |s| s.events.keyboard_focus.add(&self.focus_listener);
        log.debug("data control manager created", io, log_cfg, log_tag, .{});
        return self;
    }

    pub fn deinit(self: *DataControlManager) void {
        // Latch the teardown FIRST: destroying a resource runs its
        // destroy handler below, and a source that held the clipboard
        // would otherwise re-announce a selection to devices that are
        // about to be destroyed — the resurrection loop a client dying
        // mid-teardown triggers. It also keeps this loop terminating:
        // the announce path is the only thing that can add offers
        // while the sweep below is running.
        self.destroying = true;
        // Detach before freeing: the seat outlives the manager (main's
        // defer order) and a later keyboard_focus emit would call into
        // the freed struct. Safe with no seat — focusListener link-inits
        // the link, and removing a self-linked link is a no-op.
        self.focus_listener.link.remove();
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        // Clients outlive the manager at shutdown, so destroy every
        // resource it owns while the manager is still alive: each
        // destroy handler unlinks and frees its struct synchronously.
        // A client that already died took its own resources with it and
        // these lists are then empty, so the sweeps are no-ops.
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

    /// Documented divergences from wlroots 0.20.2
    /// (types/wlr_data_control_v1.c, types/data_control/):
    ///
    /// 1. ONE seat-wide selection, not one per device. wlroots stores
    ///    `device->selection_source` on each device; this compositor
    ///    runs a single seat, and the selection a data-control device
    ///    mirrors is the seat's, so a per-device copy could not track
    ///    it. The manager-owned field mirrors how data_device.zig and
    ///    primary_selection.zig already model the same thing.
    /// 2. Clearing returns to the mirror. wlroots leaves the device's
    ///    source NULL, so a data-control client that clears its copy
    ///    reports an empty clipboard. Here NULL means "this client does
    ///    not hold the clipboard", and the seat's real selection — the
    ///    one the client was mirroring in the first place — is the
    ///    honest answer.
    /// 3. Re-delivery is driven by the seat's keyboard-focus signal and
    ///    by get_data_device's bind-time delivery. compositor/
    ///    data_device.zig exposes no selection-changed signal and this
    ///    slice may not add one, so a data-control device observes a
    ///    replacement on the next focus change; until then its offer's
    ///    `receive` re-reads the live source and treats a replaced
    ///    source as dead, never relaying to a freed resource.
    /// 4. A source handed to set_selection is burned even when the
    ///    request is for a primary selection the compositor ignores.
    /// 5. `used_source` is posted for ANY previously used source, not
    ///    only for re-using the device's current one. It is a superset
    ///    of wlroots' check and matches the XML's own summary.
    pub fn finish(self: *DataControlManager, dev_res: *server.zwlr.DataControlDeviceV1) void {
        // Tell a data-control device the compositor will say nothing
        // more on it (`finished`). The device stays alive — the client
        // destroys it — but a later set_selection is refused, because
        // the device no longer describes the compositor's selection
        // (wlroots wlr_data_control_v1_finish sets device->finished and
        // data_control_device_handle_set_selection errors on it).
        for (self.devices.items) |dev| {
            if (dev.resource != dev_res) continue;
            if (dev.finished) return;
            dev.finished = true;
            // The offers die with the device: their payload can no
            // longer be requested through it.
            destroyOffersOfDevice(self, dev);
            dev_res.sendFinished();
            return;
        }
        // Not one of ours (already torn down): still say it, so a client
        // that outlives the device struct is not left waiting.
        dev_res.sendFinished();
    }
};

/// The seat keyboard_focus listener, with its list link initialised.
///
/// zig-wayland's `Listener.init` leaves `link` UNDEFINED — only
/// `Signal.add` ever writes it. This module's seat is OPTIONAL, so
/// with no seat the link is never written and deinit's
/// `focus_listener.link.remove()` dereferences garbage: zig-wayland's
/// `Link.remove` writes through `link.prev.?` (and nulls both pointers
/// afterwards), which faults with a general protection exception.
/// `wl_list_init` before a conditional `wl_list_remove` is the C idiom
/// for "detach, maybe never attached" (wlroots' types/
/// wlr_data_control_v1.c inits every listener link it may remove); a
/// self-linked link removes as a no-op. Never revert this to a bare
/// `Listener.init`.
fn focusListener() wire.Listener(*seat_mod.Seat) {
    var listener = wire.Listener(*seat_mod.Seat).init(onKeyboardFocus);
    listener.link.init();
    return listener;
}

/// One bound zwlr_data_control_device_v1 (get_data_device).
const Device = struct {
    manager: *DataControlManager,
    resource: *server.zwlr.DataControlDeviceV1,
    /// `finished` went out: the device no longer describes the
    /// compositor's selection, so set_selection is refused and no
    /// further offer is delivered.
    finished: bool = false,
};

/// A zwlr_data_control_source_v1 (create_data_source): the clipboard a
/// privileged client hands to set_selection. The MIME list is
/// sentinel-terminated, one entry per `offer` request (sendOffer takes
/// a C string); duplicates are ignored, exactly like data_device.zig's
/// DataSource.
const Source = struct {
    manager: *DataControlManager,
    resource: *server.zwlr.DataControlSourceV1,
    mime_types: std.ArrayList([:0]const u8),
    /// The source was handed to set_selection / set_primary_selection.
    /// Used once: a later offer() is zwlr_data_control_source_v1
    /// .error.invalid_offer ("offer sent after
    /// wlr_data_control_device.set_selection") and a second
    /// set_selection is zwlr_data_control_device_v1.error.used_source.
    used: bool = false,
    /// The source was replaced or cleared: `cancelled` went out and the
    /// selection no longer names it. The struct stays alive (the client
    /// still owns the resource and will send destroy), so a later
    /// `offer` can still be answered with invalid_offer.
    cancelled: bool = false,
};

/// A zwlr_data_control_offer_v1 delivered to one device.
const Offer = struct {
    manager: *DataControlManager,
    resource: *server.zwlr.DataControlOfferV1,
    device: *Device,
    class: OfferClass,
    /// Where the payload comes from; null once the offer is DEAD (its
    /// source was freed or replaced, or its device finished). A dead
    /// offer keeps its wire resource so the client's later `destroy`
    /// neither errors nor is killed, but receive only closes the fd.
    origin: ?Origin,
    /// For a `.seat` origin: the wire id of the mirrored source this
    /// offer was minted from, so a replacement is recognised as death
    /// (see resolveBacking).
    source_id: u32,
};

fn bindManager(client_wire: *wire.Client, mgr: *DataControlManager, version: u32, id: u32) void {
    const resource = server.zwlr.DataControlManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    resource.setHandler(*DataControlManager, managerRequest, null, mgr);
}

fn managerRequest(
    resource: *server.zwlr.DataControlManagerV1,
    request: server.zwlr.DataControlManagerV1.Request,
    mgr: *DataControlManager,
) void {
    switch (request) {
        .create_data_source => |r| {
            // The source interface is v1 whatever the manager was bound
            // at: libwayland refuses a resource created above its
            // interface's version.
            const src_res = server.zwlr.DataControlSourceV1.create(
                resource.getClient(),
                server.zwlr.DataControlSourceV1.generated_version,
                r.id,
            ) catch {
                resource.getClient().postNoMemory();
                return;
            };
            const src = mgr.allocator.create(Source) catch {
                src_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            src.* = .{
                .manager = mgr,
                .resource = src_res,
                .mime_types = .empty,
            };
            src_res.setHandler(*Source, sourceRequest, sourceDestroy, src);
            mgr.sources.append(mgr.allocator, src) catch {
                // Destroying the resource runs sourceDestroy, which
                // frees the source (it is not in the list yet).
                src_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
        },
        .get_data_device => |r| {
            // F-SEL-5 (the XA-5 pattern, data_device.zig get_data_device):
            // the seat argument must map to THIS module's seat. An inert
            // or foreign seat still yields a device resource — the
            // client's object id must stay valid, or its next request
            // kills the client — but the device is dead: no struct, no
            // list entry, no bind-time delivery. The helper keeps the
            // three exit points from repeating the resource creation.
            const seat = mgr.seat;
            const wanted = blk: {
                if (seat) |s| {
                    if (r.seat.getUserData()) |ud| {
                        const arg: *seat_mod.Seat = @ptrCast(@alignCast(ud));
                        if (arg == s) break :blk true;
                    }
                }
                break :blk false;
            };
            if (!wanted) {
                bindDeadDevice(resource, r.id);
                return;
            }
            // The device inherits the manager's bound version, which
            // addGlobal already capped at the device interface's
            // version.
            const dev_res = server.zwlr.DataControlDeviceV1.create(
                resource.getClient(),
                resource.getVersion(),
                r.id,
            ) catch {
                resource.getClient().postNoMemory();
                return;
            };
            const dev = mgr.allocator.create(Device) catch {
                dev_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            dev.* = .{ .manager = mgr, .resource = dev_res };
            dev_res.setHandler(*Device, deviceRequest, deviceDestroy, dev);
            mgr.devices.append(mgr.allocator, dev) catch {
                // setHandler already ran, so destroying the resource
                // reaches the struct through deviceDestroy.
                dev_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            log.info("data control device bound (id {d})", mgr.io, mgr.log_cfg, log_tag, .{r.id});
            // Bind-time delivery: the XML mandates "The first selection
            // event is sent upon binding the
            // wlr_data_control_device object."
            deliverSelection(mgr);
            deliverPrimary(mgr);
        },
        .destroy => resource.destroy(),
    }
}

/// The F-SEL-5 dead device: a valid object id whose requests are no-ops
/// (wlroots leaves the resource with NULL user data for an unbound seat,
/// wlr_data_device.c:238-244).
fn bindDeadDevice(resource: *server.zwlr.DataControlManagerV1, id: u32) void {
    const dev_res = server.zwlr.DataControlDeviceV1.create(
        resource.getClient(),
        resource.getVersion(),
        id,
    ) catch {
        resource.getClient().postNoMemory();
        return;
    };
    dev_res.setHandler(?*Device, deadDeviceHandler, null, null);
}

// ---------------------------------------------------------------------------
// zwlr_data_control_source_v1
// ---------------------------------------------------------------------------

fn sourceRequest(
    src_res: *server.zwlr.DataControlSourceV1,
    request: server.zwlr.DataControlSourceV1.Request,
    src: *Source,
) void {
    switch (request) {
        .offer => |r| {
            const mgr = src.manager;
            // wlr-data-control-unstable-v1.xml zwlr_data_control_
            // source_v1.offer: "Calling this after
            // wlr_data_control_device.set_selection is a protocol
            // error" — the XML's own summary for
            // zwlr_data_control_source_v1.error.invalid_offer is
            // "offer sent after wlr_data_control_device.set_selection".
            // A cancelled source is past set_selection too.
            if (src.used or src.cancelled) {
                src_res.postError(.invalid_offer, "zwlr_data_control_source_v1.offer: the source is already in use");
                return;
            }
            const mime = std.mem.span(r.mime_type);
            // Duplicate offers are ignored (data_device.zig dedups, as
            // does wlroots wlr_data_source.c:201-204).
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
        .destroy => src_res.destroy(),
    }
}

/// The source's resource died: make every offer that names it DEAD,
/// then free the struct. freeSource is the single choke point for
/// source death, so the sweep belongs there — the same invariant
/// data_device.zig's freeSource enforces (wlroots nulls offer->source in
/// data_offer_handle_source_destroy, wlr_data_offer.c:230-237).
fn freeSource(mgr: *DataControlManager, src: *Source) void {
    if (std.mem.indexOfScalar(*Source, mgr.sources.items, src)) |idx| {
        _ = mgr.sources.orderedRemove(idx);
    }
    if (mgr.selection_source == src) mgr.selection_source = null;
    if (mgr.primary_source == src) mgr.primary_source = null;
    for (mgr.offers.items) |offer| {
        switch (offer.origin orelse continue) {
            .control => |backing| {
                if (backing == src) offer.origin = null;
            },
            .seat => {},
        }
    }
    for (src.mime_types.items) |m| mgr.allocator.free(m);
    src.mime_types.deinit(mgr.allocator);
    const allocator = mgr.allocator;
    allocator.destroy(src);
}

fn sourceDestroy(src_res: *server.zwlr.DataControlSourceV1, src: *Source) void {
    _ = src_res;
    const mgr = src.manager;
    // The source held the clipboard and is going away: clear it and
    // re-announce, so no device keeps an offer that can never answer a
    // transfer (data_device.zig sourceDestroy's selection branch). The
    // pointer is cleared either way, because freeSource below must
    // never leave the manager naming a freed source; only the
    // announcement is skipped while deinit is in flight (deinit's own
    // offer sweep collects the rest).
    if (mgr.selection_source == src) {
        mgr.selection_source = null;
        if (!mgr.destroying) deliverSelection(mgr);
    }
    if (mgr.primary_source == src) {
        mgr.primary_source = null;
        if (!mgr.destroying) deliverPrimary(mgr);
    }
    freeSource(mgr, src);
}

// ---------------------------------------------------------------------------
// zwlr_data_control_device_v1
// ---------------------------------------------------------------------------

fn deviceRequest(
    dev_res: *server.zwlr.DataControlDeviceV1,
    request: server.zwlr.DataControlDeviceV1.Request,
    dev: *Device,
) void {
    switch (request) {
        .set_selection => |r| setSelection(dev_res, dev, r.source, .selection),
        .set_primary_selection => |r| setSelection(dev_res, dev, r.source, .primary_selection),
        .destroy => dev_res.destroy(),
    }
}

/// set_selection / set_primary_selection, shared: the two requests differ
/// only in which selection they write and in the version-gated
/// `primary_selection` event that follows.
fn setSelection(
    dev_res: *server.zwlr.DataControlDeviceV1,
    dev: *Device,
    source: ?*server.zwlr.DataControlSourceV1,
    class: OfferClass,
) void {
    const mgr = dev.manager;
    // The XML gates the request on the device still being valid
    // (wlroots device->finished).
    if (dev.finished) {
        if (dev_res.getVersion() >= 2) {
            dev_res.postError(.used_source, "zwlr_data_control_device_v1: the device is no longer valid");
        }
        return;
    }
    var new_source: ?*Source = null;
    if (source) |src_res| {
        const ud = src_res.getUserData() orelse {
            // A source whose struct is gone: freeSource already killed
            // every offer naming it, so there is nothing to install.
            return;
        };
        const src: *Source = @ptrCast(@alignCast(ud));
        // wlr-data-control-unstable-v1.xml: "The given source may not be
        // used in any further set_selection or set_primary_selection
        // requests. Attempting to use a previously used source is a
        // protocol error" (used_source, since v2).
        if (src.used) {
            if (dev_res.getVersion() >= 2) {
                dev_res.postError(.used_source, "zwlr_data_control_device_v1: the source was already used");
            }
            return;
        }
        // The source is burned BEFORE the request is answered, so a
        // request the compositor ignores still consumes it (the same
        // finalize-before-gates order as data_device.zig
        // data_device_set_selection, wlr_data_device.c:34-37).
        src.used = true;
        new_source = src;
    }
    if (class == .primary_selection and mgr.primary == null) {
        // "The compositor will ignore this request if it does not
        // support primary selection" — but the source stays burned.
        log.debug("ignoring set_primary_selection: no primary selection", mgr.io, mgr.log_cfg, log_tag, .{});
        return;
    }
    const previous = if (class == .selection) mgr.selection_source else mgr.primary_source;
    if (new_source) |src| {
        if (previous) |old| {
            if (old != src) cancelSource(old);
        }
        if (class == .selection) mgr.selection_source = src else mgr.primary_source = src;
    } else {
        // NULL clears; clearing hands the selection back to the mirrored
        // seat selection (divergence 2).
        if (previous) |old| cancelSource(old);
        if (class == .selection) mgr.selection_source = null else mgr.primary_source = null;
    }
    if (class == .selection) deliverSelection(mgr) else deliverPrimary(mgr);
}

/// Replace or clear a source: `cancelled` goes out and the source is
/// flagged, but the struct stays alive so the client's later `destroy`
/// still reaches the module (wlroots
/// wlr_data_control_source_v1_cancel only sets `cancelled` and posts the
/// event; data_device.zig additionally frees its struct because its
/// client data source is used once with no owner left).
fn cancelSource(src: *Source) void {
    if (src.cancelled) return;
    src.cancelled = true;
    src.resource.sendCancelled();
}

fn deviceDestroy(dev_res: *server.zwlr.DataControlDeviceV1, dev: *Device) void {
    _ = dev_res;
    const mgr = dev.manager;
    // The offers die with the device (wlroots
    // wlr_data_control_device_v1_destroy walks selection_offers): their
    // payload can only be requested through the device that minted
    // them.
    destroyOffersOfDevice(mgr, dev);
    if (std.mem.indexOfScalar(*Device, mgr.devices.items, dev)) |idx| {
        _ = mgr.devices.orderedRemove(idx);
    }
    const allocator = mgr.allocator;
    allocator.destroy(dev);
}

/// Request handler for inerted devices: no struct exists, so every
/// request is a no-op (wlroots leaves the resource with NULL user data
/// for an unbound seat, wlr_data_device.c:238-244).
fn deadDeviceHandler(
    resource: *server.zwlr.DataControlDeviceV1,
    request: server.zwlr.DataControlDeviceV1.Request,
    data: ?*Device,
) void {
    _ = resource;
    _ = data;
    switch (request) {
        .set_selection => {},
        .set_primary_selection => {},
        .destroy => {},
    }
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

/// Keyboard focus moved: re-announce both selections (divergence 3 —
/// this is the only selection-change trigger compositor/data_device.zig
/// exposes to another module).
fn onKeyboardFocus(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    const mgr: *DataControlManager = @fieldParentPtr("focus_listener", listener);
    _ = seat;
    deliverSelection(mgr);
    deliverPrimary(mgr);
}

/// The data-control clipboard: a source a privileged client owns, or the
/// live wl_data_device selection it mirrors.
fn selectionBacking(mgr: *DataControlManager) ?Backing {
    if (mgr.selection_source) |src| {
        if (src.cancelled) return null;
        return controlBacking(src);
    }
    const dd = mgr.data_devices orelse return null;
    const src = dd.selection_source orelse return null;
    return .{
        .resource = @ptrCast(src.resource),
        .mimes = src.mime_types.items,
        .relay = relayDataSource,
        .id = src.resource.getId(),
    };
}

/// The same for the primary selection.
fn primaryBacking(mgr: *DataControlManager) ?Backing {
    if (mgr.primary_source) |src| {
        if (src.cancelled) return null;
        return controlBacking(src);
    }
    const ps = mgr.primary orelse return null;
    const src = ps.selection_source orelse return null;
    return .{
        .resource = @ptrCast(src.resource),
        .mimes = src.mime_types.items,
        .relay = relayPrimarySource,
        .id = src.resource.getId(),
    };
}

fn controlBacking(src: *Source) Backing {
    return .{
        .resource = @ptrCast(src.resource),
        .mimes = src.mime_types.items,
        .relay = relayControlSource,
        .id = src.resource.getId(),
    };
}

/// Announce the clipboard to every bound device: a fresh offer per
/// device, or selection(NULL) when there is nothing to copy. A
/// re-delivery supersedes every previous SELECTION offer, so the sweep
/// runs first and filters on the class (wlroots
/// wlr_data_control_v1_update_selection destroys the device's selection
/// offers before re-sending).
fn deliverSelection(mgr: *DataControlManager) void {
    destroyOffersOfClass(mgr, .selection);
    const backing = selectionBacking(mgr);
    for (mgr.devices.items) |dev| {
        if (dev.finished) continue;
        if (backing) |b| {
            const offer = createOffer(mgr, dev, .selection, originFor(mgr, .selection), b.id) orelse continue;
            // Order matters (wlroots device_resource_send_selection):
            // introduce the offer via data_offer FIRST, then the per-mime
            // offer events, then selection. libwayland-client drops
            // events for object ids it does not know yet.
            dev.resource.sendDataOffer(offer.resource);
            for (b.mimes) |m| offer.resource.sendOffer(m.ptr);
            dev.resource.sendSelection(offer.resource);
        } else {
            dev.resource.sendSelection(null);
        }
    }
}

/// The same on the primary channel, version-gated: primary_selection is
/// a v2 event and a v1-bound device must never receive it.
fn deliverPrimary(mgr: *DataControlManager) void {
    destroyOffersOfClass(mgr, .primary_selection);
    const backing = primaryBacking(mgr);
    for (mgr.devices.items) |dev| {
        if (dev.finished or dev.resource.getVersion() < 2) continue;
        if (backing) |b| {
            const offer = createOffer(mgr, dev, .primary_selection, originFor(mgr, .primary_selection), b.id) orelse continue;
            dev.resource.sendDataOffer(offer.resource);
            for (b.mimes) |m| offer.resource.sendOffer(m.ptr);
            dev.resource.sendPrimarySelection(offer.resource);
        } else {
            dev.resource.sendPrimarySelection(null);
        }
    }
}

/// Where an announcement of `class` gets its payload: a source a
/// data-control client owns, or the mirrored seat selection.
fn originFor(mgr: *DataControlManager, class: OfferClass) Origin {
    const owned = if (class == .selection) mgr.selection_source else mgr.primary_source;
    if (owned) |src| return .{ .control = src };
    return .seat;
}

fn createOffer(
    mgr: *DataControlManager,
    dev: *Device,
    class: OfferClass,
    origin: Origin,
    source_id: u32,
) ?*Offer {
    // The offer interface is v1 while the device can be v2, so the
    // offer never inherits the device's version (libwayland refuses a
    // resource created above its interface's version).
    const offer_res = server.zwlr.DataControlOfferV1.create(
        dev.resource.getClient(),
        server.zwlr.DataControlOfferV1.generated_version,
        0,
    ) catch return null;
    const offer = mgr.allocator.create(Offer) catch {
        offer_res.destroy();
        return null;
    };
    offer.* = .{
        .manager = mgr,
        .resource = offer_res,
        .device = dev,
        .class = class,
        .origin = origin,
        .source_id = source_id,
    };
    offer_res.setHandler(*Offer, offerRequest, offerDestroy, offer);
    mgr.offers.append(mgr.allocator, offer) catch {
        // offerDestroy unlinks (it is not in the list) and frees the
        // struct; destroying the resource runs it.
        offer_res.destroy();
        return null;
    };
    return offer;
}

// ---------------------------------------------------------------------------
// zwlr_data_control_offer_v1
// ---------------------------------------------------------------------------

fn offerRequest(
    offer_res: *server.zwlr.DataControlOfferV1,
    request: server.zwlr.DataControlOfferV1.Request,
    offer: *Offer,
) void {
    switch (request) {
        .receive => |r| {
            const mgr = offer.manager;
            const backing = resolveBacking(mgr, offer) orelse {
                // A dead offer still took ownership of the fd: close it
                // rather than leak it (data_device.zig's deadOfferHandler
                // does the same).
                log.debug("offer.receive ignored: the offer is dead", mgr.io, mgr.log_cfg, log_tag, .{});
                _ = std.os.linux.close(r.fd);
                return;
            };
            const mime = std.mem.span(r.mime_type);
            // smithay offer.rs:165-168 hardening, which data_device.zig
            // already applies: the mime must be one the offer
            // advertised, or the fd is closed and nothing is relayed
            // (wlroots relays blindly).
            var offered = false;
            for (backing.mimes) |m| {
                if (std.mem.eql(u8, m, mime)) {
                    offered = true;
                    break;
                }
            }
            if (!offered) {
                log.debug("offer.receive denied: mime '{s}' was not offered", mgr.io, mgr.log_cfg, log_tag, .{mime});
                _ = std.os.linux.close(r.fd);
                return;
            }
            backing.relay(backing.resource, r.mime_type, r.fd);
            // The send event transferred the fd to the receiving client;
            // the server's copy of the peer end is closed here.
            _ = std.os.linux.close(r.fd);
            log.debug("offer.receive relayed ({s})", mgr.io, mgr.log_cfg, log_tag, .{mime});
        },
        .destroy => offer_res.destroy(),
    }
}

/// The live source an offer's `receive` answers, or null when the offer
/// is dead.
///
/// A `.seat` origin is re-read from the mirrored manager instead of
/// cached: compositor/data_device.zig frees its source struct when the
/// client drops the wl_data_source and exposes no signal, so a cached
/// pointer would dangle. Comparing the wire id also recognises a
/// replacement — the old source is gone, so the offer is dead.
fn resolveBacking(mgr: *DataControlManager, offer: *const Offer) ?Backing {
    const origin = offer.origin orelse return null;
    switch (origin) {
        .control => |src| {
            if (src.cancelled) return null;
            return controlBacking(src);
        },
        .seat => {
            const b = switch (offer.class) {
                .selection => selectionBacking(mgr) orelse return null,
                .primary_selection => primaryBacking(mgr) orelse return null,
            };
            if (b.id != offer.source_id) return null;
            return b;
        },
    }
}

fn offerDestroy(offer_res: *server.zwlr.DataControlOfferV1, offer: *Offer) void {
    _ = offer_res;
    const mgr = offer.manager;
    if (std.mem.indexOfScalar(*Offer, mgr.offers.items, offer)) |idx| {
        _ = mgr.offers.orderedRemove(idx);
    }
    const allocator = mgr.allocator;
    allocator.destroy(offer);
}

/// Destroy an offer the compositor owns: unlink, make it dead and free
/// the struct, leaving its wire resource alive with a no-op handler.
/// Inerting rather than destroying matters: the object id stays valid,
/// so a well-behaved client that destroys an offer after
/// selection(NULL) neither errors nor is killed, and a
/// NULL-implementation resource would make libwayland abort the
/// compositor on the next request (data_device.zig destroyOffer, with
/// the same reasoning).
fn destroyOffer(mgr: *DataControlManager, offer: *Offer) void {
    if (std.mem.indexOfScalar(*Offer, mgr.offers.items, offer)) |idx| {
        _ = mgr.offers.orderedRemove(idx);
    }
    // Drop the source reference before the struct goes: the source may
    // already be freed.
    offer.origin = null;
    offer.resource.setHandler(?*Offer, deadOfferHandler, null, null);
    mgr.allocator.destroy(offer);
}

/// Request handler for inerted offers: the struct is freed, so nothing
/// is dereferenced. receive's fd is still closed — the request
/// transferred ownership to the server.
fn deadOfferHandler(
    resource: *server.zwlr.DataControlOfferV1,
    request: server.zwlr.DataControlOfferV1.Request,
    data: ?*Offer,
) void {
    _ = resource;
    _ = data;
    switch (request) {
        .receive => |r| _ = std.os.linux.close(r.fd),
        .destroy => {},
    }
}

/// Destroy every live offer of one class. The other class is NOT
/// touched: a clipboard re-delivery must not tear down a live
/// primary-selection offer (wlroots keeps two lists for exactly this
/// reason, wlr_data_offer.c:264-271).
fn destroyOffersOfClass(mgr: *DataControlManager, class: OfferClass) void {
    var i: usize = 0;
    while (i < mgr.offers.items.len) {
        const offer = mgr.offers.items[i];
        if (offer.class != class) {
            i += 1;
            continue;
        }
        // destroyOffer removes the entry with orderedRemove, which
        // shifts the tail left, so this index now holds the next offer.
        destroyOffer(mgr, offer);
    }
}

/// Destroy every offer minted by one device (its device finished or was
/// destroyed).
fn destroyOffersOfDevice(mgr: *DataControlManager, dev: *Device) void {
    var i: usize = 0;
    while (i < mgr.offers.items.len) {
        const offer = mgr.offers.items[i];
        if (offer.device != dev) {
            i += 1;
            continue;
        }
        destroyOffer(mgr, offer);
    }
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
    data_control_name: ?u32 = null,
    primary_selection_name: ?u32 = null,

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
                } else if (std.mem.eql(u8, name, "zwlr_data_control_manager_v1")) {
                    data.data_control_name = g.name;
                } else if (std.mem.eql(u8, name, "zwp_primary_selection_device_manager_v1")) {
                    data.primary_selection_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Records the events a wl_data_source gets.
const SourceEvents = struct {
    send_count: usize = 0,
    cancelled_count: usize = 0,

    fn listener(source: *client.wl.DataSource, event: client.wl.DataSource.Event, data: *SourceEvents) void {
        _ = source;
        switch (event) {
            .send => data.send_count += 1,
            .cancelled => data.cancelled_count += 1,
            // The test client never drags; the arms exist for the
            // exhaustive switch over the wire event enum.
            .action => {},
            .dnd_drop_performed => {},
            .dnd_finished => {},
            .target => {},
        }
    }
};

/// Records the events a zwp_primary_selection_source_v1 gets.
const PrimarySourceEvents = struct {
    send_count: usize = 0,
    cancelled_count: usize = 0,

    fn listener(
        source: *client.zwp.PrimarySelectionSourceV1,
        event: client.zwp.PrimarySelectionSourceV1.Event,
        data: *PrimarySourceEvents,
    ) void {
        _ = source;
        switch (event) {
            .send => data.send_count += 1,
            .cancelled => data.cancelled_count += 1,
        }
    }
};

/// Records the events a zwlr_data_control_source_v1 gets.
const ControlSourceEvents = struct {
    send_count: usize = 0,
    cancelled_count: usize = 0,

    fn listener(
        source: *client.zwlr.DataControlSourceV1,
        event: client.zwlr.DataControlSourceV1.Event,
        data: *ControlSourceEvents,
    ) void {
        _ = source;
        switch (event) {
            .send => data.send_count += 1,
            .cancelled => data.cancelled_count += 1,
        }
    }
};

/// A MIME capture slot: the longest MIME type a test announces
/// ("text/plain;charset=utf-8", 24 bytes) plus the NUL the recorder
/// writes, so nothing the tests compare against is truncated. A longer
/// MIME type IS truncated — a capture buffer, not protocol state — so
/// this must stay larger than the longest announced MIME.
const mime_buf_len = 32;

/// Records a zwlr_data_control_device_v1's events.
///
/// The offer the server introduces arrives as data_offer and the MIME
/// events belong to it; the selection / primary_selection event that
/// closes the batch names that same object again, which is how the
/// capture learns which channel the offer belonged to and how many MIME
/// types it advertised.
const DeviceEvents = struct {
    /// The offer most recently introduced by data_offer, or null.
    pending: ?*client.zwlr.DataControlOfferV1 = null,
    last_selection_offer: ?*client.zwlr.DataControlOfferV1 = null,
    last_primary_offer: ?*client.zwlr.DataControlOfferV1 = null,
    /// MIME strings seen since the last channel event, in send order.
    mimes: [8][mime_buf_len]u8 = undefined,
    mime_count: usize = 0,
    /// MIME count of the last closed batch on each channel.
    selection_mimes: usize = 0,
    primary_mimes: usize = 0,
    selection_count: usize = 0,
    last_selection_null: bool = true,
    primary_count: usize = 0,
    last_primary_null: bool = true,
    finished_count: usize = 0,

    fn listener(
        device: *client.zwlr.DataControlDeviceV1,
        event: client.zwlr.DataControlDeviceV1.Event,
        data: *DeviceEvents,
    ) void {
        _ = device;
        switch (event) {
            .data_offer => |e| {
                data.pending = e.id;
                // The listener must be live before the offer's own MIME
                // events are dispatched in the same round (the server
                // sends data_offer -> mimes -> selection).
                e.id.setListener(*DeviceEvents, offerListener, data);
            },
            .selection => |e| {
                data.selection_count += 1;
                data.last_selection_null = e.id == null;
                data.last_selection_offer = e.id orelse data.last_selection_offer;
                data.selection_mimes = data.mime_count;
                data.mime_count = 0;
                data.pending = null;
            },
            .primary_selection => |e| {
                data.primary_count += 1;
                data.last_primary_null = e.id == null;
                data.last_primary_offer = e.id orelse data.last_primary_offer;
                data.primary_mimes = data.mime_count;
                data.mime_count = 0;
                data.pending = null;
            },
            .finished => data.finished_count += 1,
        }
    }

    fn offerListener(offer: *client.zwlr.DataControlOfferV1, event: client.zwlr.DataControlOfferV1.Event, data: *DeviceEvents) void {
        _ = offer;
        switch (event) {
            .offer => |e| {
                if (data.mime_count >= data.mimes.len) return;
                const src = std.mem.span(e.mime_type);
                const slot = &data.mimes[data.mime_count];
                // Leave room for the NUL the reader slices on; a longer
                // MIME type is truncated, which a capture buffer is free
                // to do.
                const n = @min(src.len, slot.len - 1);
                @memcpy(slot[0..n], src[0..n]);
                slot[n] = 0;
                data.mime_count += 1;
            },
        }
    }

    /// The i-th MIME type of the last closed selection batch, in send
    /// order. sliceTo reads the NUL the recorder wrote, so a fixed-size
    /// capture buffer is safe (std.mem.span would read past it).
    fn selectionMime(data: *const DeviceEvents, i: usize) []const u8 {
        return std.mem.sliceTo(data.mimes[i][0..], 0);
    }
};

/// The one definition of a test roundtrip (flush the client, dispatch the
/// server's event loop, flush the replies back). See pump below.
const test_pump = @import("../utils/test_pump.zig");

/// A compositor + seat + wl_data_device_manager + primary selection +
/// zwlr_data_control_manager_v1, plus one in-memory client that binds
/// all of them.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    data_mgr: ?*data_device.DataDeviceManager = null,
    primary: ?*primary_selection.PrimarySelection = null,
    ctrl: ?*DataControlManager = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_seat: ?*client.wl.Seat = null,
    wl_data_device_manager: ?*client.wl.DataDeviceManager = null,
    wl_primary_manager: ?*client.zwp.PrimarySelectionDeviceManagerV1 = null,
    wl_control_manager: ?*client.zwlr.DataControlManagerV1 = null,
    surface: ?*client.wl.Surface = null,
    /// Mirrors main.zig's onSurfaceDestroy wiring: the seat's focus is
    /// cleared when a test client's surface is destroyed, so the seat
    /// never holds a dangling surface.
    surface_listener: wire.Listener(*surface_mod.Surface),

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor, seat and managers all store it).
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
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();
        ts.data_mgr = try data_device.DataDeviceManager.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.seat.?);
        errdefer if (ts.data_mgr) |m| m.deinit();
        ts.primary = try primary_selection.PrimarySelection.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.seat.?);
        errdefer if (ts.primary) |p| p.deinit();
        ts.ctrl = try DataControlManager.init(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.seat.?,
            ts.data_mgr.?,
            ts.primary.?,
        );
        errdefer if (ts.ctrl) |c| c.deinit();

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
            capture.data_device_manager_name == null or
            capture.data_control_name == null or
            capture.primary_selection_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind everything the tests drive.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.surface = try ts.wl_compositor.?.createSurface();
        ts.wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
        ts.wl_data_device_manager = try registry.bind(
            capture.data_device_manager_name.?,
            client.wl.DataDeviceManager,
            3,
        );
        ts.wl_primary_manager = try registry.bind(
            capture.primary_selection_name.?,
            client.zwp.PrimarySelectionDeviceManagerV1,
            1,
        );
        ts.wl_control_manager = try registry.bind(
            capture.data_control_name.?,
            client.zwlr.DataControlManagerV1,
            2,
        );
        try ts.pump();
        const srv_surface = surfaceForClient(ts, ts.client.?);
        srv_surface.events.destroy.add(&ts.surface_listener);
        return ts;
    }

    /// The test client's surface died (client teardown, or an explicit
    /// wl_surface.destroy): clear the seat's focus so it never dangles
    /// (production: main.zig onSurfaceDestroy -> Seat.surfaceDestroyed).
    fn onSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), surface: *surface_mod.Surface) void {
        const ts: *TestServer = @fieldParentPtr("surface_listener", listener);
        if (ts.seat) |seat| seat.surfaceDestroyed(surface);
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers must
        // run while the data-control module lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.ctrl) |c| c.deinit();
        if (ts.primary) |p| p.deinit();
        if (ts.data_mgr) |m| m.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// One shared roundtrip (utils/test_pump.zig) plus this harness's own
    /// client-side poll and dispatch, so the server's replies reach the
    /// test's listeners before the assertions run. A dispatch failure
    /// nulls the client: the server already destroyed it, so deinit must
    /// not destroy it again.
    fn pump(ts: *TestServer) !void {
        try test_pump.roundtrip(ts.c_display, ts.display.?, 0);
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

/// A display, a wl_seat, one client, and a data-control manager built
/// WITHOUT that seat and without the mirrored managers. TestServer
/// cannot express this: its manager is wired to its seat, and the null
/// seat is the shape that owns the F-SEL-5 dead device and the
/// teardown of a focus listener that was never attached.
const SeatlessServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    seat: ?*seat_mod.Seat = null,
    ctrl: ?*DataControlManager = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_seat: ?*client.wl.Seat = null,
    wl_control_manager: ?*client.zwlr.DataControlManagerV1 = null,

    /// Heap-allocated: the display and every manager store `&self.io`,
    /// which has to outlive this call.
    fn init(allocator: std.mem.Allocator) !*SeatlessServer {
        const ts = try allocator.create(SeatlessServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        // The compositor HAS a seat; the module below is the one built
        // without it, which is the state get_data_device must survive.
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();
        ts.ctrl = try DataControlManager.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, null, null, null);
        errdefer if (ts.ctrl) |c| c.deinit();

        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        const registry = try ts.c_display.?.getRegistry();
        var globals: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &globals);
        try ts.pump();
        if (globals.seat_name == null or globals.data_control_name == null) return error.GlobalMissing;
        ts.wl_seat = try registry.bind(globals.seat_name.?, client.wl.Seat, 7);
        ts.wl_control_manager = try registry.bind(globals.data_control_name.?, client.zwlr.DataControlManagerV1, 2);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *SeatlessServer) void {
        // Client first: its destroy handlers must run while the module
        // lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.ctrl) |c| c.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// One shared roundtrip plus this client's dispatch, the same
    /// sequence TestServer.pump drives.
    fn pump(ts: *SeatlessServer) !void {
        try test_pump.roundtrip(ts.c_display.?, ts.display.?, 0);
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                ts.client = null;
                return error.ClientDispatchFailed;
            }
        }
    }
};

fn surfaceForClient(ts: *TestServer, client_wire: *wire.Client) *surface_mod.Surface {
    for (ts.compositor.?.surfaces.items) |s| {
        if (s.resource.getClient() == client_wire) return s;
    }
    unreachable;
}

/// Focus the test client's surface and return a serial the seat handed
/// to it (the focus event mints one; wlroots' model is a per-client
/// serial ring).
fn focusAndMintSerial(ts: *TestServer) u32 {
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client.?));
    return ts.seat.?.last_serial;
}

/// Set the real clipboard through the wl_data_device path.
fn setRealClipboard(ts: *TestServer, events: *SourceEvents) !void {
    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    src.offer("text/html");
    src.setListener(*SourceEvents, SourceEvents.listener, events);
    device.setSelection(src, focusAndMintSerial(ts));
    try ts.pump();
    try testing.expect(ts.data_mgr.?.selection_source != null);
}

/// Set the real primary selection through the zwp path.
fn setRealPrimary(ts: *TestServer, events: *PrimarySourceEvents) !void {
    const device = try ts.wl_primary_manager.?.getDevice(ts.wl_seat.?);
    const src = try ts.wl_primary_manager.?.createSource();
    src.offer("text/plain");
    src.setListener(*PrimarySourceEvents, PrimarySourceEvents.listener, events);
    device.setSelection(src, focusAndMintSerial(ts));
    try ts.pump();
    try testing.expect(ts.primary.?.selection_source != null);
}

/// How many offers of one class the module currently holds.
fn offersOfClass(ts: *TestServer, class: OfferClass) usize {
    var n: usize = 0;
    for (ts.ctrl.?.offers.items) |offer| {
        if (offer.class == class) n += 1;
    }
    return n;
}

/// The wire id of the module's one offer of `class`, or 0 when it holds
/// none. The two classes interleave in one list, so a test that needs a
/// specific offer's identity asks for it by class.
fn offerIdOfClass(ts: *TestServer, class: OfferClass) u32 {
    for (ts.ctrl.?.offers.items) |offer| {
        if (offer.class == class) return offer.resource.getId();
    }
    return 0;
}

/// A socketpair whose server copy the module must close: after the
/// relay (or the rejection) both ends of the peer must be gone, so a
/// write on the other end is EPIPE. Raw syscall with MSG_NOSIGNAL keeps
/// it an error instead of a SIGPIPE (0.16 has no std.posix.write;
/// linux.sendto returns a negated errno).
fn expectPeerClosed(peer: posix.socket_t) !void {
    const rc = std.os.linux.sendto(peer, "x", 1, std.os.linux.MSG.NOSIGNAL, null, 0);
    try testing.expectEqual(std.os.linux.E.PIPE, std.os.linux.errno(rc));
    _ = std.os.linux.close(peer);
}

test "a real wl_data_source selection is read back through a data-control device" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var src_events: SourceEvents = .{};
    try setRealClipboard(ts, &src_events);

    // A privileged client binds a data-control device: the XML mandates
    // the first selection event on bind.
    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();

    try testing.expectEqual(@as(usize, 1), events.selection_count);
    try testing.expect(!events.last_selection_null);
    try testing.expectEqual(@as(usize, 2), events.selection_mimes);
    try testing.expectEqualStrings("text/plain", events.selectionMime(0));
    try testing.expectEqualStrings("text/html", events.selectionMime(1));
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);
    // The offer is backed by the mirrored seat source, not by a
    // data-control source of our own.
    try testing.expectEqual(OfferClass.selection, ts.ctrl.?.offers.items[0].class);
    try testing.expect(ts.ctrl.?.offers.items[0].origin.? == .seat);

    // An unoffered mime closes the fd and relays nothing (smithay
    // hardening, shared with data_device.zig).
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    events.last_selection_offer.?.receive("application/x-unknown", fds[0]);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), src_events.send_count);
    // The client transfers ownership of its copy; libwayland-client
    // does not close it for us.
    _ = std.os.linux.close(fds[0]);
    try expectPeerClosed(fds[1]);

    // An offered mime relays the fd to the wl_data_source's send.
    var fds2: [2]posix.socket_t = undefined;
    const rc2 = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds2);
    if (posix.errno(rc2) != .SUCCESS) return error.SocketpairFailed;
    events.last_selection_offer.?.receive("text/html", fds2[0]);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), src_events.send_count);
    _ = std.os.linux.close(fds2[0]);
    _ = std.os.linux.close(fds2[1]);
}

test "a mirrored offer is dead once its wl_data_source is replaced" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var src_events: SourceEvents = .{};
    try setRealClipboard(ts, &src_events);
    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    const offer = events.last_selection_offer.?;
    const old_id = ts.ctrl.?.offers.items[0].source_id;
    try testing.expect(old_id != 0);

    // The clipboard source is replaced with no focus change (the seat's
    // setKeyboardFocus on the same surface is a no-op, so no
    // keyboard_focus signal fires). The module has no selection-changed
    // signal to listen to either, so the offer stays on the wire still
    // naming the source that is now GONE: the stale id is what makes a
    // transfer on it resolve to nothing instead of touching a resource
    // the dead source no longer owns.
    const dd_device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src_b = try ts.wl_data_device_manager.?.createDataSource();
    src_b.offer("text/plain");
    src_b.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    dd_device.setSelection(src_b, focusAndMintSerial(ts));
    try ts.pump();
    try testing.expectEqual(old_id, ts.ctrl.?.offers.items[0].source_id);

    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    const before = src_events.send_count;
    offer.receive("text/plain", fds[0]);
    try ts.pump();
    try testing.expectEqual(before, src_events.send_count);
    _ = std.os.linux.close(fds[0]);
    try expectPeerClosed(fds[1]);
}

test "a data-control source's death kills its offers before the struct goes" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    // No clipboard: the bind-time delivery is selection(NULL).
    try testing.expectEqual(@as(usize, 1), events.selection_count);
    try testing.expect(events.last_selection_null);

    // A privileged client takes the clipboard with its own source.
    const src = try ts.wl_control_manager.?.createDataSource();
    src.offer("text/plain");
    var src_events: ControlSourceEvents = .{};
    src.setListener(*ControlSourceEvents, ControlSourceEvents.listener, &src_events);
    device.setSelection(src);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), events.selection_count);
    try testing.expect(!events.last_selection_null);
    try testing.expectEqual(@as(usize, 1), events.selection_mimes);
    try testing.expectEqualStrings("text/plain", events.selectionMime(0));
    try testing.expect(ts.ctrl.?.selection_source != null);
    try testing.expect(ts.ctrl.?.offers.items[0].origin.? == .control);

    // The source dies mid-transfer: every offer naming it must be DEAD
    // before the struct is freed, and its selection must be released.
    const offer = events.last_selection_offer.?;
    src.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.sources.items.len);
    try testing.expect(ts.ctrl.?.selection_source == null);
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);

    // The offer the client still holds is inert: receive closes the fd
    // and relays nothing.
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    offer.receive("text/plain", fds[0]);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), src_events.send_count);
    _ = std.os.linux.close(fds[0]);
    try expectPeerClosed(fds[1]);
}

test "replacing the data-control selection cancels the old owner" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();

    const src_a = try ts.wl_control_manager.?.createDataSource();
    src_a.offer("text/plain");
    var a_events: ControlSourceEvents = .{};
    src_a.setListener(*ControlSourceEvents, ControlSourceEvents.listener, &a_events);
    device.setSelection(src_a);
    try ts.pump();

    const src_b = try ts.wl_control_manager.?.createDataSource();
    src_b.offer("text/plain;charset=utf-8");
    var b_events: ControlSourceEvents = .{};
    src_b.setListener(*ControlSourceEvents, ControlSourceEvents.listener, &b_events);
    device.setSelection(src_b);
    try ts.pump();

    // The replaced owner is cancelled; the new one is not. The
    // superseded offer is gone and a fresh one carries the new mimes.
    try testing.expectEqual(@as(usize, 1), a_events.cancelled_count);
    try testing.expectEqual(@as(usize, 0), b_events.cancelled_count);
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);
    try testing.expectEqual(@as(usize, 1), events.selection_mimes);
    try testing.expectEqualStrings("text/plain;charset=utf-8", events.selectionMime(0));

    // Clearing hands the selection back to the mirrored seat selection
    // (divergence 2): with no real clipboard that is selection(NULL).
    device.setSelection(null);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), b_events.cancelled_count);
    try testing.expect(ts.ctrl.?.selection_source == null);
    try testing.expect(events.last_selection_null);
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);
}

test "clearing the data-control selection re-exposes the real clipboard" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var src_events: SourceEvents = .{};
    try setRealClipboard(ts, &src_events);

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), events.selection_mimes);

    // A data-control client takes the clipboard: the offer is now backed
    // by its source, not the mirrored one.
    const src = try ts.wl_control_manager.?.createDataSource();
    src.offer("image/png");
    var c_events: ControlSourceEvents = .{};
    src.setListener(*ControlSourceEvents, ControlSourceEvents.listener, &c_events);
    device.setSelection(src);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.selection_mimes);
    try testing.expectEqualStrings("image/png", events.selectionMime(0));
    try testing.expect(ts.ctrl.?.offers.items[0].origin.? == .control);

    // Handing it back re-mirrors the real clipboard.
    device.setSelection(null);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), c_events.cancelled_count);
    try testing.expect(ts.ctrl.?.selection_source == null);
    try testing.expectEqual(@as(usize, 2), events.selection_mimes);
    try testing.expectEqualStrings("text/plain", events.selectionMime(0));
    try testing.expectEqualStrings("text/html", events.selectionMime(1));
    try testing.expect(ts.ctrl.?.offers.items[0].origin.? == .seat);
}

test "a clipboard re-delivery sweeps only the selection offers" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var p_events: PrimarySourceEvents = .{};
    try setRealPrimary(ts, &p_events);

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    // The primary channel answers with its own offer.
    try testing.expectEqual(@as(usize, 1), events.primary_count);
    try testing.expect(!events.last_primary_null);
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);
    try testing.expectEqual(OfferClass.primary_selection, ts.ctrl.?.offers.items[0].class);
    const primary_offer_id = ts.ctrl.?.offers.items[0].resource.getId();

    // The client also owns the clipboard: set_selection re-announces
    // the clipboard channel ONLY, so the primary offer survives with the
    // very same wire object — the class split data_device.zig makes
    // between selection and drag offers (a selection re-delivery destroys
    // only the selection offers, wlr_data_offer.c:264-271).
    const src = try ts.wl_control_manager.?.createDataSource();
    src.offer("text/plain");
    device.setSelection(src);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), ts.ctrl.?.offers.items.len);
    try testing.expectEqual(@as(usize, 1), offersOfClass(ts, .selection));
    try testing.expectEqual(@as(usize, 1), offersOfClass(ts, .primary_selection));
    try testing.expectEqual(primary_offer_id, events.last_primary_offer.?.getId());

    // A focus change re-announces both channels: each keeps exactly one
    // offer and the clipboard offer is a fresh object.
    const old_selection_id = offerIdOfClass(ts, .selection);
    ts.seat.?.setKeyboardFocus(null);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), ts.ctrl.?.offers.items.len);
    try testing.expectEqual(@as(usize, 1), offersOfClass(ts, .selection));
    try testing.expectEqual(@as(usize, 1), offersOfClass(ts, .primary_selection));
    try testing.expect(offerIdOfClass(ts, .selection) != old_selection_id);
    // bind-time NULL selection, the set_selection announcement, the
    // focus re-delivery: three selection events; the primary channel
    // answered at bind and again on the same focus change.
    try testing.expectEqual(@as(usize, 3), events.selection_count);
    try testing.expectEqual(@as(usize, 2), events.primary_count);
}

test "the primary channel answers on its own events and clears back to the mirror" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    // No primary selection anywhere: the bind-time delivery is
    // primary_selection(NULL) on a v2 device.
    try testing.expectEqual(@as(usize, 1), events.primary_count);
    try testing.expect(events.last_primary_null);

    const psrc = try ts.wl_control_manager.?.createDataSource();
    psrc.offer("text/plain");
    var p_events: ControlSourceEvents = .{};
    psrc.setListener(*ControlSourceEvents, ControlSourceEvents.listener, &p_events);
    device.setPrimarySelection(psrc);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), events.primary_count);
    try testing.expect(!events.last_primary_null);
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);
    try testing.expectEqual(OfferClass.primary_selection, ts.ctrl.?.offers.items[0].class);
    try testing.expectEqual(@as(usize, 1), events.primary_mimes);

    // Clearing hands the channel back to the mirrored zwp selection,
    // which nothing has set here.
    device.setPrimarySelection(null);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), p_events.cancelled_count);
    try testing.expect(events.last_primary_null);
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);
}

test "destroying a device kills the offers it minted" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var src_events: SourceEvents = .{};
    try setRealClipboard(ts, &src_events);

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);

    // The client drops its device while the offer is still live.
    device.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.devices.items.len);

    // The module survives: a fresh bind is served again.
    const device2 = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events2: DeviceEvents = .{};
    device2.setListener(*DeviceEvents, DeviceEvents.listener, &events2);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events2.selection_count);
    try testing.expect(!events2.last_selection_null);
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);
}

test "a client-destroyed offer leaves the module with no live offer" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var src_events: SourceEvents = .{};
    try setRealClipboard(ts, &src_events);

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);
    events.last_selection_offer.?.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);
    // The module is still healthy and still serving the device.
    ts.seat.?.setKeyboardFocus(null);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);
}

test "finished stops the device and refuses a later set_selection" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var src_events: SourceEvents = .{};
    try setRealClipboard(ts, &src_events);

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.offers.items.len);

    // The compositor retires the device: finished goes out, the offers
    // die, and no further selection is announced.
    const srv_device = ts.ctrl.?.devices.items[0];
    ts.ctrl.?.finish(srv_device.resource);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events.finished_count);
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);

    const before = events.selection_count;
    ts.seat.?.setKeyboardFocus(null);
    try ts.pump();
    try testing.expectEqual(before, events.selection_count);
    try testing.expect(srv_device.finished);

    // A set_selection on the retired device is the used_source error
    // (the XML's only device error, since v2).
    const src = try ts.wl_control_manager.?.createDataSource();
    src.offer("text/plain");
    device.setSelection(src);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "offer after set_selection raises invalid_offer" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();

    const src = try ts.wl_control_manager.?.createDataSource();
    src.offer("text/plain");
    device.setSelection(src);
    try ts.pump();
    // The XML: "Calling this after wlr_data_control_device.set_selection
    // is a protocol error" (zwlr_data_control_source_v1.error.
    // invalid_offer = 1).
    src.offer("text/html");
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "offer after cancellation raises invalid_offer" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();

    const src_a = try ts.wl_control_manager.?.createDataSource();
    src_a.offer("text/plain");
    device.setSelection(src_a);
    try ts.pump();
    // Replacing it cancels it; a cancelled source is past set_selection,
    // so a late offer is the same protocol error.
    const src_b = try ts.wl_control_manager.?.createDataSource();
    src_b.offer("text/plain");
    device.setSelection(src_b);
    try ts.pump();
    src_a.offer("text/html");
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "re-using a consumed source raises used_source" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();

    const src = try ts.wl_control_manager.?.createDataSource();
    src.offer("text/plain");
    device.setSelection(src);
    try ts.pump();
    // The XML: "The given source may not be used in any further
    // set_selection or set_primary_selection requests."
    device.setSelection(src);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    try testing.expectEqual(@as(c_int, 1), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "a bound device is told the selection and primary selection are empty" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Neither the clipboard nor the primary selection holds anything:
    // the XML still mandates "The first selection event is sent upon
    // binding the wlr_data_control_device object", so the device must
    // be told the selection is EMPTY rather than left waiting for an
    // event that never comes. Both delivery paths are load-bearing
    // here — an empty one would leave the client with a device it has
    // heard nothing on.
    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();

    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.devices.items.len);
    try testing.expectEqual(@as(usize, 1), events.selection_count);
    try testing.expect(events.last_selection_null);
    try testing.expectEqual(@as(usize, 1), events.primary_count);
    try testing.expect(events.last_primary_null);
    // An empty selection mints no offer on either channel.
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);
}

test "a manager with no seat hands out a dead device and leaks nothing" {
    const allocator = testing.allocator;
    var ts = try SeatlessServer.init(allocator);
    defer ts.deinit();

    // F-SEL-5: the client's object id must stay valid whatever the seat
    // argument, or its next request would kill the client. The device
    // carries no state, so the module announces nothing on it.
    const device = try ts.wl_control_manager.?.getDataDevice(ts.wl_seat.?);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.devices.items.len);
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);
    try testing.expectEqual(@as(usize, 0), events.selection_count);
    try testing.expectEqual(@as(usize, 0), events.primary_count);

    // Its requests are no-ops (deadDeviceHandler): a module that ran
    // them as if the device were live would take this client down. The
    // source below is a real one, so a device that DID install it
    // would leave selection_source set — the assertions distinguish
    // "swallowed" from "handled as live".
    const src = try ts.wl_control_manager.?.createDataSource();
    src.offer("text/plain");
    device.setSelection(src);
    device.setPrimarySelection(src);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.ctrl.?.sources.items.len);
    try testing.expect(ts.ctrl.?.selection_source == null);
    try testing.expect(ts.ctrl.?.primary_source == null);
    try testing.expectEqual(@as(usize, 0), ts.ctrl.?.offers.items.len);

    // deinit tears down a module that never had a seat behind it: the
    // global, the manager and the never-attached focus listener link
    // all have to go, and the testing allocator fails this test if any
    // of them is left behind.
}
