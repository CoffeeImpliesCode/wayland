//! zwp_primary_selection_device_manager_v1 (v1): the primary-selection
//! clipboard relay (the X11 PRIMARY analogue).
//!
//! Per-seat module (one seat in this compositor): a global manager
//! creates per-client sources and per-client devices; the module holds
//! the seat-wide primary selection and delivers it to the
//! keyboard-focused client only.
//!
//! Semantics (audit-verified vs wlroots types/wlr_primary_selection_v1.c,
//! smithay selection/primary_selection/, KWin primaryselection*_v1.cpp;
//! XML ground truth protocols/wayland-protocols/unstable/primary-selection/
//! primary-selection-unstable-v1.xml — the protocol has NO error enums, so
//! every violation below is a silent denial, never a protocol error):
//!   - set_selection(source, serial): the caller must be the
//!     keyboard-focused client, else the request is denied silently
//!     (smithay model — the XML is silent, so this is never a protocol
//!     error; the protocol has NO error enums). The serial is validated
//!     for ORDERING only: a set whose serial is older than the current
//!     selection's by more than half the wrap range is superseded and
//!     denied silently (wlroots wlr_seat_request_set_primary_selection,
//!     wlr_primary_selection.c:54-62). Positive serial validity is NOT
//!     checked — the XML calls the serial only "the serial of the event
//!     that triggered this request" (advisory), the seat exposes no
//!     per-client serial ring for this path, and the focus gate already
//!     blocks background hijack. Reference split: wlroots validates
//!     (per-client ring + superseded); smithay ignores the serial
//!     entirely (focus-gated only, primary_selection/device.rs); KWin
//!     checks ordering only (seat.cpp:319-333). Ours: smithay's focus
//!     gate + wlroots' superseded ordering guard.
//!   - A source is used once: set_selection finalizes it BEFORE the
//!     focus/ordering gates (wlroots device_handle_set_selection,
//!     wlr_primary_selection_v1.c:213-216), so a denied set still burns
//!     the source and a second set_selection with the same source is
//!     denied silently. smithay deliberately does NOT enforce used-once
//!     (device.rs) — ours is stricter than smithay, matching wlroots.
//!   - Re-passing the CURRENT selection source updates the serial
//!     silently (F-SEL-4; wlroots wlr_seat_set_primary_selection
//!     early-returns on selection_source == source,
//!     wlr_primary_selection.c:81-86) — the used-once denial does not
//!     fire for it.
//!   - A cancelled source is inert (F-SEL-3): the replaced/cleared
//!     owner's struct is freed and its wire resource becomes a no-op
//!     (wlroots nulls the resource user data on cancel,
//!     wlr_primary_selection_v1.c:110-121). Re-passing a cancelled
//!     source to set_selection behaves exactly like NULL — it clears the
//!     selection.
//!   - get_device with an inert or foreign seat argument yields a dead
//!     device (F-SEL-5): the object id stays valid, every request is a
//!     no-op.
//!   - offer.receive with a mime the source never offered closes the fd
//!     and relays nothing (F-SEL-6, smithay parity — mirrors the DD-7
//!     check in data_device.zig).
//!   - set_selection delivers data_offer + one offer event per mime +
//!     selection to the focused client's devices; a NULL source delivers
//!     selection(NULL).
//!   - The previous owner's source receives cancelled.
//!   - A new device binding gets the current selection immediately when
//!     the binding client is focused (KWin/wlroots).
//!   - On keyboard focus change the previous focused client receives
//!     selection(NULL) (its offer dies with the focus). Deliberate
//!     XML-literal choice: the selection event says the offer is valid
//!     "until the client loses keyboard focus"; wlroots only delivers to
//!     the new focused client and lets old offers linger (TODO comment,
//!     wlr_primary_selection_v1.c:279-280), smithay re-offers the new
//!     client only, KWin destroys old offers without an explicit NULL.
//!   - offer.receive(mime, fd) relays the fd to the source's
//!     send(mime, fd); with no source the fd is closed, no crash.
//!   - source destroy: cancelled + every offer referencing it becomes
//!     inert (a dead offer never reads freed source memory).
//!   - Duplicate source.offer(mime) calls are ignored.
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

/// zwp_primary_selection_device_manager_v1 protocol version implemented.
pub const primary_selection_version: u32 = 1;

pub const PrimarySelection = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    seat: *seat_mod.Seat,
    /// The global manager, for teardown.
    global: ?*wire.Global = null,
    /// Per-client primary selection devices (get_device).
    devices: std.ArrayList(*PrimarySelectionDevice) = .empty,
    /// The seat-wide primary selection. The manager is per-seat, so one
    /// field holds the selection for the whole seat: a selection set by
    /// one client is delivered to whichever client holds keyboard focus.
    selection_source: ?*PrimarySelectionSource = null,
    /// The serial the current selection was set with (wlr_seat
    /// .primary_selection_serial). A set_selection whose serial is older
    /// than this by more than half the wrap range is superseded and
    /// rejected (wlroots
    /// wlr_seat_request_set_primary_selection,
    /// wlr_primary_selection.c:54-62).
    selection_serial: u32 = 0,
    /// Every source created by clients (lifetime mirror of the manager;
    /// see DataDeviceManager.sources in data_device.zig).
    sources: std.ArrayList(*PrimarySelectionSource) = .empty,
    /// Live selection offers, one per device of the focused client. An
    /// offer is destroyed (struct freed, wire resource inerted) whenever
    /// the selection is re-delivered, the focus moves, or its source
    /// dies — an offer never outlives the source it references.
    offers: std.ArrayList(*PrimarySelectionOffer) = .empty,
    /// The client that currently holds keyboard focus, tracked across the
    /// seat's keyboard_focus signal so the previous focused client can be
    /// told selection(NULL) when the focus moves (the seat has already
    /// switched keyboard_focus when the signal fires). Stale only when a
    /// focused client dies without a focus change (surfaceDestroyed does
    /// not emit the signal): its devices are gone by then, so the
    /// stale-delivery loop finds nothing.
    focus_client: ?*wire.Client = null,
    focus_listener: wire.Listener(*seat_mod.Seat),

    events: struct {
        /// A source was set as the primary selection.
        selection_set: wire.Signal(*PrimarySelection),
        /// The primary selection was cleared (NULL source).
        selection_cleared: wire.Signal(*PrimarySelection),
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        seat: *seat_mod.Seat,
    ) error{ OutOfMemory, GlobalCreateFailed }!*PrimarySelection {
        const self = try allocator.create(PrimarySelection);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .seat = seat,
            .devices = .empty,
            .focus_listener = wire.Listener(*seat_mod.Seat).init(onKeyboardFocus),
            // SAFETY: initialized via .init() immediately after
            // construction, before any emit.
            .events = undefined,
        };
        errdefer self.devices.deinit(allocator);
        self.events.selection_set.init();
        self.events.selection_cleared.init();
        self.global = try display.addGlobal(
            server.zwp.PrimarySelectionDeviceManagerV1,
            *PrimarySelection,
            bindManager,
            primary_selection_version,
            self,
        );
        // Deliver the selection when the keyboard focus moves.
        seat.events.keyboard_focus.add(&self.focus_listener);
        log.debug("primary selection manager created", io, log_cfg, "primary_selection", .{});
        return self;
    }

    pub fn deinit(self: *PrimarySelection) void {
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

/// A client's primary selection device (one per client per seat).
const PrimarySelectionDevice = struct {
    manager: *PrimarySelection,
    resource: *server.zwp.PrimarySelectionDeviceV1,
};

/// A primary selection source (the client offering the selection).
const PrimarySelectionSource = struct {
    manager: *PrimarySelection,
    resource: *server.zwp.PrimarySelectionSourceV1,
    /// Mime types offered (source.offer), sentinel-terminated
    /// (offer.sendOffer takes a C string). Duplicate offers are ignored.
    mime_types: std.ArrayList([:0]const u8),
    /// Whether the source was already used in a successful
    /// set_selection. A source can only be used once (wlroots
    /// finalizes it); a second set_selection with it is denied silently.
    finalized: bool = false,
};

/// A primary selection offer delivered to a target client.
const PrimarySelectionOffer = struct {
    manager: *PrimarySelection,
    resource: *server.zwp.PrimarySelectionOfferV1,
    /// The offering client's source. Nulled when the offer is destroyed
    /// (the source may already be freed), so a dead offer never reads
    /// freed source memory.
    source: ?*PrimarySelectionSource,
};

fn bindManager(client_wire: *wire.Client, mgr: *PrimarySelection, version: u32, id: u32) void {
    const resource = server.zwp.PrimarySelectionDeviceManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    resource.setHandler(*PrimarySelection, managerRequest, null, mgr);
}

fn managerRequest(
    resource: *server.zwp.PrimarySelectionDeviceManagerV1,
    request: server.zwp.PrimarySelectionDeviceManagerV1.Request,
    mgr: *PrimarySelection,
) void {
    switch (request) {
        .create_source => |r| {
            const src_res = server.zwp.PrimarySelectionSourceV1.create(resource.getClient(), 1, r.id) catch {
                resource.getClient().postNoMemory();
                return;
            };
            const src = mgr.allocator.create(PrimarySelectionSource) catch {
                src_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            src.* = .{
                .manager = mgr,
                .resource = src_res,
                .mime_types = .empty,
            };
            src_res.setHandler(*PrimarySelectionSource, sourceRequest, sourceDestroy, src);
            mgr.sources.append(mgr.allocator, src) catch {
                // Destroying the resource runs sourceDestroy, which frees
                // the source (it is not in the list yet).
                src_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
        },
        .get_device => |r| {
            // The seat argument: only our seat's device matters (one seat).
            const dev_res = server.zwp.PrimarySelectionDeviceV1.create(resource.getClient(), 1, r.id) catch {
                resource.getClient().postNoMemory();
                return;
            };
            // F-SEL-5: the seat argument must map to a live seat (the
            // XA-5 pattern, xdg_activation.zig:369-380). An inert or
            // foreign seat still yields a device resource — the client's
            // object id must stay valid, or the next request kills the
            // client — but the device is dead: no struct, no list entry,
            // no bind-time delivery (wlroots: NULL user data for a dead
            // seat client, wlr_primary_selection_v1.c).
            const seat_ud = r.seat.getUserData() orelse {
                dev_res.setHandler(?*PrimarySelectionDevice, deadDeviceHandler, null, null);
                return;
            };
            const seat: *seat_mod.Seat = @ptrCast(@alignCast(seat_ud));
            if (seat != mgr.seat) {
                dev_res.setHandler(?*PrimarySelectionDevice, deadDeviceHandler, null, null);
                return;
            }
            const dev = mgr.allocator.create(PrimarySelectionDevice) catch {
                dev_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            dev.* = .{
                .manager = mgr,
                .resource = dev_res,
            };
            dev_res.setHandler(*PrimarySelectionDevice, deviceRequest, deviceDestroy, dev);
            mgr.devices.append(mgr.allocator, dev) catch {
                dev_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            // Bind-time delivery: a new device of the focused client
            // immediately receives the current selection (KWin/wlroots:
            // the device sends the current selection right after bind).
            if (mgr.seat.keyboard_focus) |focus| {
                if (focus.resource.getClient() == dev_res.getClient()) {
                    deliverToFocusedClient(mgr, dev_res.getClient());
                }
            }
        },
        .destroy => resource.destroy(),
    }
}

// ---------------------------------------------------------------------------
// zwp_primary_selection_source_v1
// ---------------------------------------------------------------------------

fn sourceRequest(
    src_res: *server.zwp.PrimarySelectionSourceV1,
    request: server.zwp.PrimarySelectionSourceV1.Request,
    src: *PrimarySelectionSource,
) void {
    switch (request) {
        .offer => |r| {
            const mime = std.mem.span(r.mime_type);
            // Duplicate offers are ignored (never delivered twice).
            for (src.mime_types.items) |m| {
                if (std.mem.eql(u8, m, mime)) return;
            }
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
        .destroy => src_res.destroy(),
    }
}

/// Unlink a primary selection source from the manager and free it (mime
/// list + struct). Shared by cancelSource and sourceDestroy.
fn freeSource(mgr: *PrimarySelection, src: *PrimarySelectionSource) void {
    if (std.mem.findScalar(*PrimarySelectionSource, mgr.sources.items, src)) |idx| {
        _ = mgr.sources.orderedRemove(idx);
    }
    for (src.mime_types.items) |m| mgr.allocator.free(m);
    src.mime_types.deinit(mgr.allocator);
    const allocator = mgr.allocator;
    allocator.destroy(src);
}

/// Cancel a source and inert it: the cancelled event goes out, the wire
/// resource's user data is dropped (its requests become no-ops via
/// deadSourceHandler, so a later client request cannot touch the freed
/// struct) and the struct is freed (wlroots nulls the source resource's
/// user data on cancel, wlr_primary_selection_v1.c:110-121). A cancelled
/// source re-passed to set_selection extracts to null and behaves
/// exactly like NULL — it clears the selection.
fn cancelSource(mgr: *PrimarySelection, src: *PrimarySelectionSource) void {
    src.resource.sendCancelled();
    src.resource.setHandler(?*PrimarySelectionSource, deadSourceHandler, null, null);
    freeSource(mgr, src);
}

/// Request handler for inerted (cancelled) primary selection sources:
/// the struct is freed, so nothing is dereferenced — every request is a
/// no-op. The destroy callback is null, so client teardown cannot call
/// into the freed struct.
fn deadSourceHandler(
    resource: *server.zwp.PrimarySelectionSourceV1,
    request: server.zwp.PrimarySelectionSourceV1.Request,
    data: ?*PrimarySelectionSource,
) void {
    _ = resource;
    _ = data;
    switch (request) {
        .offer => {},
        .destroy => {},
    }
}

fn sourceDestroy(src_res: *server.zwp.PrimarySelectionSourceV1, src: *PrimarySelectionSource) void {
    _ = src_res;
    const mgr = src.manager;
    if (mgr.selection_source == src) {
        // The selected source died: clear the seat-wide selection and
        // cancel the (already dying) source. The re-delivery below
        // destroys every offer that referenced it, so no offer can read
        // the freed source.
        mgr.selection_source = null;
        src.resource.sendCancelled();
        if (mgr.focus_client) |fc| deliverToFocusedClient(mgr, fc);
    }
    freeSource(mgr, src);
}

// ---------------------------------------------------------------------------
// zwp_primary_selection_device_v1
// ---------------------------------------------------------------------------

fn deviceRequest(
    dev_res: *server.zwp.PrimarySelectionDeviceV1,
    request: server.zwp.PrimarySelectionDeviceV1.Request,
    dev: *PrimarySelectionDevice,
) void {
    switch (request) {
        .set_selection => |r| {
            const mgr = dev.manager;
            const caller = dev.resource.getClient();
            // Extract the source with null tolerance (F-SEL-3): a
            // cancelled source's resource is inert (null user data) and
            // behaves exactly like NULL — it clears the selection
            // instead of dereferencing the freed struct.
            var new_source: ?*PrimarySelectionSource = null;
            if (r.source) |src_res| {
                if (src_res.getUserData()) |ud| {
                    new_source = @ptrCast(@alignCast(ud));
                }
            }
            // F-SEL-4: re-passing the CURRENT selection source updates
            // the serial silently — no cancel, no re-delivery, and the
            // used-once denial below does not fire (wlroots
            // wlr_seat_set_primary_selection early-returns on
            // selection_source == source, wlr_primary_selection.c:81-86;
            // wlroots has no used-once gate at all — ours stays for
            // non-current finalized sources).
            if (new_source) |src| {
                if (mgr.selection_source == src) {
                    mgr.selection_serial = r.serial;
                    return;
                }
            }
            // The source is finalized (used once) BEFORE the focus and
            // ordering gates, per wlroots device_handle_set_selection
            // (wlr_primary_selection_v1.c:213-216): a request the gates
            // reject still burns the source. A second set_selection with
            // the same used-once (non-current) source is denied
            // silently.
            if (new_source) |src| {
                if (src.finalized) {
                    log.debug(
                        "denying primary selection: source already used",
                        mgr.io,
                        mgr.log_cfg,
                        "primary_selection",
                        .{},
                    );
                    return;
                }
                src.finalized = true;
            }
            // Only the keyboard-focused client may set the primary
            // selection; everyone else is denied silently (smithay:
            // selection/primary_selection.rs denies a set_selection from
            // a client without keyboard focus; the XML is silent, so
            // this is never a protocol error).
            const focus = mgr.seat.keyboard_focus orelse {
                log.debug(
                    "denying primary selection: no keyboard focus",
                    mgr.io,
                    mgr.log_cfg,
                    "primary_selection",
                    .{},
                );
                return;
            };
            if (focus.resource.getClient() != caller) {
                log.debug(
                    "denying primary selection: caller is not keyboard-focused",
                    mgr.io,
                    mgr.log_cfg,
                    "primary_selection",
                    .{},
                );
                return;
            }
            // Ordering guard (wlroots
            // wlr_seat_request_set_primary_selection,
            // wlr_primary_selection.c:54-62): a serial older than the
            // current selection's by more than half the wrap range is
            // superseded and denied silently. Positive serial validity
            // is not checked (no per-client ring for this path; the
            // focus gate above blocks background hijack — see the module
            // doc for the reference split).
            if (mgr.selection_source != null and
                r.serial -% mgr.selection_serial > std.math.maxInt(u32) / 2)
            {
                log.debug(
                    "denying primary selection: serial {d} indicates superseded (selection at {d})",
                    mgr.io,
                    mgr.log_cfg,
                    "primary_selection",
                    .{ r.serial, mgr.selection_serial },
                );
                return;
            }
            if (new_source) |src| {
                // A new selection: cancel the previous owner (inerting
                // it — the cancelled source's struct is freed and its
                // wire resource becomes a no-op, F-SEL-3).
                if (mgr.selection_source) |old| {
                    if (old != src) cancelSource(mgr, old);
                }
                mgr.selection_source = src;
                mgr.selection_serial = r.serial;
                log.debug("primary selection set with {d} mime types", mgr.io, mgr.log_cfg, "primary_selection", .{
                    src.mime_types.items.len,
                });
                mgr.events.selection_set.emit(mgr);
            } else {
                // Null source — or a cancelled (inert) source: clear the
                // selection.
                if (mgr.selection_source) |old| cancelSource(mgr, old);
                mgr.selection_source = null;
                mgr.selection_serial = r.serial;
                log.debug("primary selection cleared", mgr.io, mgr.log_cfg, "primary_selection", .{});
                mgr.events.selection_cleared.emit(mgr);
            }
            deliverToFocusedClient(mgr, caller);
        },
        .destroy => dev_res.destroy(),
    }
}

/// Request handler for inerted (dead) primary selection devices: no
/// struct exists, so every request is a no-op. The destroy callback is
/// null, so client teardown cannot call into a freed struct.
fn deadDeviceHandler(
    resource: *server.zwp.PrimarySelectionDeviceV1,
    request: server.zwp.PrimarySelectionDeviceV1.Request,
    data: ?*PrimarySelectionDevice,
) void {
    _ = resource;
    _ = data;
    switch (request) {
        .set_selection => {},
        .destroy => {},
    }
}

fn deviceDestroy(dev_res: *server.zwp.PrimarySelectionDeviceV1, dev: *PrimarySelectionDevice) void {
    _ = dev_res;
    const mgr = dev.manager;
    // The seat-wide selection is owned by the manager, not the device:
    // it survives the device.
    const idx = std.mem.findScalar(*PrimarySelectionDevice, mgr.devices.items, dev) orelse 0;
    if (idx < mgr.devices.items.len and mgr.devices.items[idx] == dev) {
        _ = mgr.devices.orderedRemove(idx);
    }
    const allocator = mgr.allocator;
    allocator.destroy(dev);
}

/// Keyboard focus moved: the previous focused client's offer dies
/// (selection(NULL), g), then the current selection is delivered to the
/// new focused client.
fn onKeyboardFocus(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    const mgr: *PrimarySelection = @fieldParentPtr("focus_listener", listener);
    // The seat has already updated keyboard_focus before emitting.
    const new_client = if (seat.keyboard_focus) |s| s.resource.getClient() else null;
    if (mgr.focus_client) |old| {
        if (old != new_client) {
            // (g) The previous focused client's offer is void once it
            // loses keyboard focus (primary-selection XML: the offer is
            // valid "until the client loses keyboard focus").
            for (mgr.devices.items) |dev| {
                if (dev.resource.getClient() == old) dev.resource.sendSelection(null);
            }
        }
    }
    mgr.focus_client = new_client;
    if (new_client) |nc| deliverToFocusedClient(mgr, nc);
}

/// For the focused client's devices: destroy the previous offers and
/// deliver the current selection — a fresh offer per device when a
/// selection exists, selection(NULL) when it was cleared.
fn deliverToFocusedClient(mgr: *PrimarySelection, client_wire: *wire.Client) void {
    // A re-delivery (new/cleared selection, focus change, source death)
    // supersedes every previous offer: destroy them all first, so no
    // stale offer outlives the selection it advertises.
    destroyAllOffers(mgr);
    const src = mgr.selection_source;
    for (mgr.devices.items) |dev| {
        if (dev.resource.getClient() != client_wire) continue;
        if (src) |s| {
            const offer_res = server.zwp.PrimarySelectionOfferV1.create(client_wire, 1, 0) catch return;
            const offer = mgr.allocator.create(PrimarySelectionOffer) catch {
                offer_res.destroy();
                return;
            };
            offer.* = .{
                .manager = mgr,
                .resource = offer_res,
                .source = s,
            };
            offer_res.setHandler(*PrimarySelectionOffer, offerRequest, offerDestroy, offer);
            mgr.offers.append(mgr.allocator, offer) catch {
                // offerDestroy frees the offer (it is not in the list).
                offer_res.destroy();
                return;
            };
            // Order matters (wlroots primary_selection_device_send_selection,
            // wlr_primary_selection_v1.c): introduce the offer via
            // data_offer FIRST, then the per-mime offer events, then
            // selection. libwayland-client discards events for object ids
            // it does not know yet (queue_event, wayland-client.c), so
            // sending the mimes before data_offer would silently drop them.
            dev.resource.sendDataOffer(offer_res);
            for (s.mime_types.items) |m| offer_res.sendOffer(m.ptr);
            dev.resource.sendSelection(offer_res);
            log.debug(
                "primary selection delivered to focused client ({d} mimes)",
                mgr.io,
                mgr.log_cfg,
                "primary_selection",
                .{s.mime_types.items.len},
            );
        } else {
            // No selection: the focused client's offer is void.
            dev.resource.sendSelection(null);
        }
    }
}

// ---------------------------------------------------------------------------
// zwp_primary_selection_offer_v1
// ---------------------------------------------------------------------------

fn offerRequest(
    offer_res: *server.zwp.PrimarySelectionOfferV1,
    request: server.zwp.PrimarySelectionOfferV1.Request,
    offer: *PrimarySelectionOffer,
) void {
    switch (request) {
        .receive => |r| {
            // Relay the fd to the owning client: the source writes the
            // payload into it, the target reads it. A live offer always
            // has a live source (the source is nulled only when the
            // offer is destroyed, which also removes it from the
            // manager's list); the guard closes the fd and returns
            // (wlroots closes the fd when the offer is gone,
            // wlr_primary_selection_v1.c).
            const src = offer.source orelse {
                _ = std.os.linux.close(r.fd);
                return;
            };
            // F-SEL-6: smithay hardening (selection/offer.rs:177 — the
            // receive dispatch covers DataDeviceKind::Primary at
            // offer.rs:148-152): a mime the source never offered is
            // denied — the fd is closed and no send is relayed (mirrors
            // the DD-7 check in data_device.zig; wlroots relays blindly).
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
                    "primary selection offer.receive denied: mime '{s}' was not offered",
                    offer.manager.io,
                    offer.manager.log_cfg,
                    "primary_selection",
                    .{mime},
                );
                _ = std.os.linux.close(r.fd);
                return;
            }
            src.resource.sendSend(r.mime_type, r.fd);
            _ = std.os.linux.close(r.fd);
            log.debug(
                "primary selection offer.receive relayed ({s})",
                offer.manager.io,
                offer.manager.log_cfg,
                "primary_selection",
                .{mime},
            );
        },
        .destroy => offer_res.destroy(),
    }
}

fn offerDestroy(offer_res: *server.zwp.PrimarySelectionOfferV1, offer: *PrimarySelectionOffer) void {
    _ = offer_res;
    const mgr = offer.manager;
    // The client destroyed its offer (or the offer's resource died with
    // the client): unlink and free.
    if (std.mem.findScalar(*PrimarySelectionOffer, mgr.offers.items, offer)) |idx| {
        _ = mgr.offers.orderedRemove(idx);
    }
    const allocator = mgr.allocator;
    allocator.destroy(offer);
}

/// Request handler for inerted (dead) offers: the offer struct is freed,
/// so nothing is dereferenced. receive's fd is closed — the request still
/// transferred ownership to the server.
fn deadOfferHandler(
    resource: *server.zwp.PrimarySelectionOfferV1,
    request: server.zwp.PrimarySelectionOfferV1.Request,
    data: ?*PrimarySelectionOffer,
) void {
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
/// neither errors nor is killed.
fn destroyOffer(mgr: *PrimarySelection, offer: *PrimarySelectionOffer) void {
    if (std.mem.findScalar(*PrimarySelectionOffer, mgr.offers.items, offer)) |idx| {
        _ = mgr.offers.orderedRemove(idx);
    }
    // Drop the source reference before freeing: the source may already be
    // gone (sourceDestroy clears the selection before the offers). The
    // dead offer must never read it.
    offer.source = null;
    offer.resource.setHandler(?*PrimarySelectionOffer, deadOfferHandler, null, null);
    mgr.allocator.destroy(offer);
}

/// Destroy every live selection offer.
fn destroyAllOffers(mgr: *PrimarySelection) void {
    while (mgr.offers.items.len > 0) destroyOffer(mgr, mgr.offers.items[0]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const posix = std.posix;

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,
    primary_selection_manager_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "zwp_primary_selection_device_manager_v1")) {
                    data.primary_selection_manager_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Counts the cancelled/send events delivered to a primary selection
/// source.
const SourceEvents = struct {
    cancelled_count: usize = 0,
    send_count: usize = 0,

    fn listener(
        source: *client.zwp.PrimarySelectionSourceV1,
        event: client.zwp.PrimarySelectionSourceV1.Event,
        data: *SourceEvents,
    ) void {
        _ = source;
        switch (event) {
            .cancelled => data.cancelled_count += 1,
            .send => data.send_count += 1,
        }
    }
};

/// Counts the offer (mime) events delivered on an offer object.
const OfferMimeCounter = struct {
    mime_count: usize = 0,

    fn listener(
        offer: *client.zwp.PrimarySelectionOfferV1,
        event: client.zwp.PrimarySelectionOfferV1.Event,
        data: *OfferMimeCounter,
    ) void {
        _ = offer;
        switch (event) {
            .offer => data.mime_count += 1,
        }
    }
};

/// Records the client-side device events: how many selections were
/// delivered and whether the last one was a null (cleared) selection.
const DeviceEvents = struct {
    selection_count: usize = 0,
    last_selection_null: bool = false,
    /// The offer of the most recent non-null selection (valid until a
    /// selection(NULL) or a new offer supersedes it).
    last_offer: ?*client.zwp.PrimarySelectionOfferV1 = null,
    /// Mime events observed on the offers this device received. The offer
    /// listener is attached from inside the data_offer handler so it is
    /// live before the offer's own events are dispatched in the same
    /// round (the server sends data_offer -> mimes -> selection).
    mimes: OfferMimeCounter = .{},

    fn listener(
        device: *client.zwp.PrimarySelectionDeviceV1,
        event: client.zwp.PrimarySelectionDeviceV1.Event,
        data: *DeviceEvents,
    ) void {
        _ = device;
        switch (event) {
            .data_offer => |e| e.offer.setListener(*OfferMimeCounter, OfferMimeCounter.listener, &data.mimes),
            .selection => |e| {
                data.selection_count += 1;
                data.last_selection_null = e.id == null;
                if (e.id) |offer| data.last_offer = offer;
            },
        }
    }
};

/// Observes the module's own selection_set / selection_cleared signals.
const SelectionEventCapture = struct {
    set_count: usize = 0,
    cleared_count: usize = 0,
    listener_set: wire.Listener(*PrimarySelection),
    listener_cleared: wire.Listener(*PrimarySelection),

    fn onSet(listener: *wire.Listener(*PrimarySelection), _: *PrimarySelection) void {
        @as(*SelectionEventCapture, @fieldParentPtr("listener_set", listener)).set_count += 1;
    }
    fn onCleared(listener: *wire.Listener(*PrimarySelection), _: *PrimarySelection) void {
        @as(*SelectionEventCapture, @fieldParentPtr("listener_cleared", listener)).cleared_count += 1;
    }
};

/// One in-memory client connection: its own socketpair, registry round,
/// compositor/seat/manager bindings and one focusable surface.
const TestClient = struct {
    client: *wire.Client,
    c_display: *client.wl.Display,
    wl_compositor: *client.wl.Compositor,
    wl_seat: *client.wl.Seat,
    wl_manager: *client.zwp.PrimarySelectionDeviceManagerV1,
    surface: *client.wl.Surface,
};

/// A compositor + seat + primary selection manager + two in-memory
/// clients, for wire roundtrips of the primary selection flow.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    mgr: ?*PrimarySelection = null,
    client_a: ?TestClient = null,
    client_b: ?TestClient = null,
    /// Mirrors main.zig's onSurfaceDestroy wiring: the seat's focus is
    /// cleared when a test client's surface is destroyed (client
    /// teardown), so the seat never holds a dangling surface.
    surface_listener_a: wire.Listener(*surface_mod.Surface),
    surface_listener_b: wire.Listener(*surface_mod.Surface),

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, seat and manager all store it).
    fn init(allocator: std.mem.Allocator) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
            .surface_listener_a = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroyA),
            .surface_listener_b = wire.Listener(*surface_mod.Surface).init(onSurfaceDestroyB),
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();
        ts.mgr = try PrimarySelection.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.seat.?);
        errdefer if (ts.mgr) |m| m.deinit();

        ts.client_a = try connectClient(ts);
        ts.client_b = try connectClient(ts);
        // Production clears the seat focus from main.zig's
        // onSurfaceDestroy; this harness drives the protocol directly, so
        // wire the seat's surfaceDestroyed to each client's surface here.
        const srv_a = surfaceForClient(ts, ts.client_a.?.client);
        srv_a.events.destroy.add(&ts.surface_listener_a);
        const srv_b = surfaceForClient(ts, ts.client_b.?.client);
        srv_b.events.destroy.add(&ts.surface_listener_b);
        return ts;
    }

    fn onSurfaceDestroyA(listener: *wire.Listener(*surface_mod.Surface), surface: *surface_mod.Surface) void {
        const ts: *TestServer = @fieldParentPtr("surface_listener_a", listener);
        if (ts.seat) |seat| seat.surfaceDestroyed(surface);
    }

    fn onSurfaceDestroyB(listener: *wire.Listener(*surface_mod.Surface), surface: *surface_mod.Surface) void {
        const ts: *TestServer = @fieldParentPtr("surface_listener_b", listener);
        if (ts.seat) |seat| seat.surfaceDestroyed(surface);
    }

    /// One full client connection on its own socketpair: registry round,
    /// compositor/seat/manager bindings and one focusable surface. Uses
    /// connectPump, not pump: the connecting client is not yet in
    /// ts.client_a/client_b, so the shared pump would never poll its fd
    /// and the registry globals would sit undelivered (GlobalMissing).
    fn connectClient(ts: *TestServer) !TestClient {
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        const wire_client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        const c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        // Round 1: registry + global announcements.
        const registry = try c_display.getRegistry();
        var capture: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &capture);
        try connectPump(ts, c_display);
        if (capture.compositor_name == null or
            capture.seat_name == null or
            capture.primary_selection_manager_name == null)
        {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor (to create a focusable surface),
        // wl_seat and the primary selection manager.
        const wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        const surface = try wl_compositor.createSurface();
        const wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
        const wl_manager = try registry.bind(
            capture.primary_selection_manager_name.?,
            client.zwp.PrimarySelectionDeviceManagerV1,
            1,
        );
        try connectPump(ts, c_display);
        return .{
            .client = wire_client,
            .c_display = c_display,
            .wl_compositor = wl_compositor,
            .wl_seat = wl_seat,
            .wl_manager = wl_manager,
            .surface = surface,
        };
    }

    /// Flush this client, dispatch the server, flush, then dispatch this
    /// client's fd. Drives one roundtrip for a client that is still
    /// connecting (not yet registered in the shared pump's list).
    fn connectPump(ts: *TestServer, c_display: *client.wl.Display) !void {
        if (c_display.flush() != .SUCCESS) return error.ClientFlushFailed;
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        var fds = [_]posix.pollfd{
            .{ .fd = c_display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (c_display.dispatch() != .SUCCESS) return error.ClientDispatchFailed;
        }
    }

    fn deinit(ts: *TestServer) void {
        // Tear the clients down first: their resource destroy handlers
        // (sourceDestroy/deviceDestroy) must run while the manager lives.
        if (ts.client_b) |b| {
            b.c_display.disconnect();
            b.client.destroy();
        }
        if (ts.client_a) |a| {
            a.c_display.disconnect();
            a.client.destroy();
        }
        if (ts.mgr) |m| m.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// Client flush -> server event loop dispatch -> server flush ->
    /// client dispatch. Drives one roundtrip without blocking. Tolerates
    /// a client that has not connected yet (connectClient pumps with
    /// only client A live) and a client dropped by a protocol error.
    fn pump(ts: *TestServer) !void {
        if (ts.client_a) |a| {
            if (a.c_display.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        if (ts.client_b) |b| {
            if (b.c_display.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        try ts.display.?.getServer().getEventLoop().dispatch(0);
        ts.display.?.flushClients();
        var fds: [2]posix.pollfd = undefined;
        var count: usize = 0;
        if (ts.client_a) |a| {
            fds[count] = .{ .fd = a.c_display.getFd(), .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        if (ts.client_b) |b| {
            fds[count] = .{ .fd = b.c_display.getFd(), .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        if (count == 0) return;
        if (try posix.poll(fds[0..count], 0) > 0) {
            for (fds[0..count]) |fd| {
                if (fd.revents & posix.POLL.IN == 0) continue;
                const is_a = ts.client_a != null and fd.fd == ts.client_a.?.c_display.getFd();
                if ((if (is_a) ts.client_a.?.c_display else ts.client_b.?.c_display).dispatch() != .SUCCESS) {
                    // Protocol error or disconnect: the server has already
                    // destroyed its client (dangling) — forget it for deinit.
                    if (is_a) {
                        ts.client_a = null;
                    } else {
                        ts.client_b = null;
                    }
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

/// Focus the test client's surface (drives the seat's keyboard_focus
/// signal through the manager).
fn focusClient(ts: *TestServer, tc: *TestClient) void {
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, tc.client));
}

test "primary selection: focused set_selection (serial ignored) delivers to the focused client and follows focus" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;
    const b = &ts.client_b.?;

    var capture: SelectionEventCapture = .{
        .listener_set = wire.Listener(*PrimarySelection).init(SelectionEventCapture.onSet),
        .listener_cleared = wire.Listener(*PrimarySelection).init(SelectionEventCapture.onCleared),
    };
    ts.mgr.?.events.selection_set.add(&capture.listener_set);
    ts.mgr.?.events.selection_cleared.add(&capture.listener_cleared);

    focusClient(ts, a);
    const device_a = try a.wl_manager.getDevice(a.wl_seat);
    const device_b = try b.wl_manager.getDevice(b.wl_seat);
    var events_a: DeviceEvents = .{};
    var events_b: DeviceEvents = .{};
    device_a.setListener(*DeviceEvents, DeviceEvents.listener, &events_a);
    device_b.setListener(*DeviceEvents, DeviceEvents.listener, &events_b);
    try ts.pump();

    // serial=0 is accepted: the primary-selection XML's serial is
    // advisory ("serial of the event that triggered this request").
    // Positive validity is not checked (no per-client ring; the focus
    // gate guards instead); only ordering — a superseded serial — is
    // rejected (PS-1; wlroots wlr_primary_selection.c:54-62). With the
    // first set, selection_serial is 0, so 0 is not superseded.
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    device_a.setSelection(src, 0);
    try ts.pump();
    try testing.expect(ts.mgr.?.selection_source != null);
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 1), capture.set_count);
    try testing.expectEqual(@as(usize, 0), capture.cleared_count);
    try testing.expectEqual(@as(usize, 0), src_events.cancelled_count);
    // The focused client received offer + selection, with one offer
    // event per mime.
    try testing.expectEqual(@as(usize, 2), events_a.selection_count); // bind-time NULL + the new selection
    try testing.expect(!events_a.last_selection_null);
    try testing.expectEqual(@as(usize, 1), events_a.mimes.mime_count);
    // The unfocused client saw nothing yet.
    try testing.expectEqual(@as(usize, 0), events_b.selection_count);

    // Focus moves to the other bound client: it receives offer+selection,
    // the previous focused client receives selection(NULL).
    focusClient(ts, b);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.selection_count);
    try testing.expect(!events_b.last_selection_null);
    try testing.expectEqual(@as(usize, 3), events_a.selection_count);
    try testing.expect(events_a.last_selection_null);
}

test "primary selection: non-focused set_selection is denied silently" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;
    const b = &ts.client_b.?;

    focusClient(ts, a);
    const device_a = try a.wl_manager.getDevice(a.wl_seat);
    const device_b = try b.wl_manager.getDevice(b.wl_seat);
    var events_a: DeviceEvents = .{};
    device_a.setListener(*DeviceEvents, DeviceEvents.listener, &events_a);
    try ts.pump();
    const baseline = events_a.selection_count;

    // The unfocused client tries to set the selection: denied silently —
    // no selection stored, no delivery to the focused client, and the
    // source is not cancelled (it was never accepted). The source IS
    // burned though (PS-2: wlroots finalizes before the seat checks,
    // wlr_primary_selection_v1.c:213-216).
    const src_b = try b.wl_manager.createSource();
    src_b.offer("text/plain");
    var src_b_events: SourceEvents = .{};
    src_b.setListener(*SourceEvents, SourceEvents.listener, &src_b_events);
    device_b.setSelection(src_b, 0);
    try ts.pump();
    try testing.expectEqual(@as(?*PrimarySelectionSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(baseline, events_a.selection_count);
    try testing.expectEqual(@as(usize, 0), src_b_events.cancelled_count);
    try testing.expect(ts.mgr.?.sources.items[0].finalized);
    // The client survived (no protocol error — the protocol has no error
    // enum, and the denial is silent).
    device_a.setSelection(null, 0); // still functional
    try ts.pump();
    try testing.expectEqual(baseline + 1, events_a.selection_count);
}

test "primary selection: set_selection(NULL) clears and cancels the previous owner" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    var capture: SelectionEventCapture = .{
        .listener_set = wire.Listener(*PrimarySelection).init(SelectionEventCapture.onSet),
        .listener_cleared = wire.Listener(*PrimarySelection).init(SelectionEventCapture.onCleared),
    };
    ts.mgr.?.events.selection_set.add(&capture.listener_set);
    ts.mgr.?.events.selection_cleared.add(&capture.listener_cleared);

    focusClient(ts, a);
    const device = try a.wl_manager.getDevice(a.wl_seat);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    try ts.pump();

    device.setSelection(src, 0);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), src_events.cancelled_count);

    // Null source: the focused client receives selection(NULL) and the
    // previous owner's source is cancelled.
    device.setSelection(null, 0);
    try ts.pump();
    try testing.expectEqual(@as(?*PrimarySelectionSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(@as(usize, 1), src_events.cancelled_count);
    try testing.expect(events.last_selection_null);
    try testing.expectEqual(@as(usize, 1), capture.cleared_count);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);
}

test "primary selection: offer.receive with no source closes the fd, no crash" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    focusClient(ts, a);
    const device = try a.wl_manager.getDevice(a.wl_seat);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    try ts.pump();

    device.setSelection(src, 0);
    try ts.pump();
    const offer = events.last_offer.?;

    // The selection is cleared: the offer is destroyed (struct freed,
    // resource inerted, source reference nulled).
    device.setSelection(null, 0);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);

    // receive() on the dead offer: the fd is closed, no send is relayed,
    // and the client survives.
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    offer.receive("text/plain", fds[0]);
    offer.destroy();
    try ts.pump();
    _ = std.os.linux.close(fds[0]);
    _ = std.os.linux.close(fds[1]);
    try testing.expectEqual(@as(usize, 0), src_events.send_count);
    // The client survived: a further selection roundtrip succeeds.
    const src2 = try a.wl_manager.createSource();
    src2.offer("text/plain");
    device.setSelection(src2, 0);
    try ts.pump();
    try testing.expect(!events.last_selection_null);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
}

test "primary selection: source destroy cancels and inerts the offer" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    focusClient(ts, a);
    const device = try a.wl_manager.getDevice(a.wl_seat);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    try ts.pump();

    device.setSelection(src, 0);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    const offer = events.last_offer.?;

    // The owner destroys its source: the selection is cleared, the offer
    // is destroyed (resource inerted) and the focused client is told
    // selection(NULL).
    src.destroy();
    try ts.pump();
    try testing.expectEqual(@as(?*PrimarySelectionSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);
    try testing.expect(events.last_selection_null);

    // The dead offer is inert: receive() and destroy() from the client
    // neither crash the compositor (no dangling source dereference) nor
    // kill the client.
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    offer.receive("text/plain", fds[0]);
    offer.destroy();
    try ts.pump();
    _ = std.os.linux.close(fds[0]);
    _ = std.os.linux.close(fds[1]);
    try testing.expectEqual(@as(usize, 0), src_events.send_count);
}

test "primary selection: new device binding gets the current selection" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    focusClient(ts, a);
    const device1 = try a.wl_manager.getDevice(a.wl_seat);
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    try ts.pump();

    device1.setSelection(src, 0);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);

    // A second device bound while the client is focused immediately
    // receives the current selection (KWin/wlroots bind-time delivery).
    const device2 = try a.wl_manager.getDevice(a.wl_seat);
    var events2: DeviceEvents = .{};
    device2.setListener(*DeviceEvents, DeviceEvents.listener, &events2);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events2.selection_count);
    try testing.expect(!events2.last_selection_null);
    // Exactly one live offer per device of the focused client.
    try testing.expectEqual(@as(usize, 2), ts.mgr.?.offers.items.len);
}

test "primary selection: duplicate source.offer is ignored" {
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    focusClient(ts, a);
    const device = try a.wl_manager.getDevice(a.wl_seat);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    src.offer("text/plain");
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items.len);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items[0].mime_types.items.len);

    device.setSelection(src, 0);
    try ts.pump();
    try testing.expect(events.last_offer != null);
    // One offer event per distinct mime — the duplicate was not
    // delivered twice.
    try testing.expectEqual(@as(usize, 1), events.mimes.mime_count);
}

test "primary selection: a superseded serial is denied silently" {
    // PS-1: the serial is validated for ordering only — wlroots
    // wlr_seat_request_set_primary_selection (wlr_primary_selection.c:
    // 54-62) rejects a serial older than the current selection's by
    // more than half the wrap range. Positive validity is not checked
    // (no per-client ring; the focus gate guards instead) — see the
    // module doc for the reference split.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    focusClient(ts, a);
    const device = try a.wl_manager.getDevice(a.wl_seat);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    try ts.pump();

    device.setSelection(src, 0);
    try ts.pump();
    try testing.expectEqual(@as(u32, 0), ts.mgr.?.selection_serial);
    try testing.expect(ts.mgr.?.selection_source != null);
    try testing.expectEqual(@as(usize, 2), events.selection_count); // bind NULL + the set

    // Simulate the selection having been set with a serial half a wrap
    // in the future (unreachable through the wire in a test session):
    // any request serial is now superseded and denied silently — no
    // selection change, no cancel, no delivery.
    ts.mgr.?.selection_serial = 0x8000_0000;
    const src2 = try a.wl_manager.createSource();
    src2.offer("text/plain");
    var src2_events: SourceEvents = .{};
    src2.setListener(*SourceEvents, SourceEvents.listener, &src2_events);
    device.setSelection(src2, 0);
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 0), src2_events.cancelled_count);
    try testing.expectEqual(@as(usize, 2), events.selection_count);
    // The source was still burned (PS-2: finalize before the gates).
    try testing.expect(ts.mgr.?.sources.items[1].finalized);
}

test "primary selection: a denied set_selection still finalizes the source" {
    // PS-2: wlroots finalizes the source BEFORE the seat checks
    // (device_handle_set_selection, wlr_primary_selection_v1.c:213-216)
    // — a request the focus gate rejects still burns the source, and
    // the used-once rule then blocks a later set with the same source.
    // smithay deliberately does NOT enforce used-once at all (device.rs);
    // ours is stricter, matching wlroots.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;
    const b = &ts.client_b.?;

    focusClient(ts, a);
    const device_b = try b.wl_manager.getDevice(b.wl_seat);
    try ts.pump();

    // b is not focused: the set is denied by the focus gate, but the
    // source is burned before the gate.
    const src_b = try b.wl_manager.createSource();
    src_b.offer("text/plain");
    device_b.setSelection(src_b, 0);
    try ts.pump();
    try testing.expectEqual(@as(?*PrimarySelectionSource, null), ts.mgr.?.selection_source);
    try testing.expect(ts.mgr.?.sources.items[0].finalized);

    // The used-once rule now blocks b from setting it even when focused.
    focusClient(ts, b);
    var events_b: DeviceEvents = .{};
    device_b.setListener(*DeviceEvents, DeviceEvents.listener, &events_b);
    try ts.pump();
    const baseline = events_b.selection_count;
    device_b.setSelection(src_b, 0);
    try ts.pump();
    try testing.expectEqual(@as(?*PrimarySelectionSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(baseline, events_b.selection_count);
    try testing.expectEqual(@as(usize, 0), events_b.mimes.mime_count);
}

test "primary selection: focus change delivers selection(NULL) to the previous focused client" {
    // PS-3: deliberate XML-literal choice — the selection event says the
    // offer is valid "until the client loses keyboard focus"
    // (primary-selection-unstable-v1.xml), so the previously focused
    // client receives selection(NULL) when the focus moves. wlroots only
    // delivers to the new client and lets old offers linger (TODO,
    // wlr_primary_selection_v1.c:279-280); smithay re-offers the new
    // client only; KWin destroys old offers without an explicit NULL.
    // Kept by decision — see the module doc.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;
    const b = &ts.client_b.?;

    focusClient(ts, a);
    const device_a = try a.wl_manager.getDevice(a.wl_seat);
    const device_b = try b.wl_manager.getDevice(b.wl_seat);
    var events_a: DeviceEvents = .{};
    var events_b: DeviceEvents = .{};
    device_a.setListener(*DeviceEvents, DeviceEvents.listener, &events_a);
    device_b.setListener(*DeviceEvents, DeviceEvents.listener, &events_b);
    try ts.pump();

    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    device_a.setSelection(src, 0);
    try ts.pump();
    // a was focused at bind time: bind NULL (1) + the set (2).
    try testing.expectEqual(@as(usize, 2), events_a.selection_count);
    try testing.expect(!events_a.last_selection_null);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);

    // Focus moves to b: a's offer dies with the focus — selection(NULL)
    // — and b receives the offer.
    focusClient(ts, b);
    try ts.pump();
    try testing.expectEqual(@as(usize, 3), events_a.selection_count);
    try testing.expect(events_a.last_selection_null);
    try testing.expectEqual(@as(usize, 1), events_b.selection_count);
    try testing.expect(!events_b.last_selection_null);
}

test "primary selection: a cancelled source is inert; re-passing it clears" {
    // F-SEL-3: a replaced primary selection's source is cancelled AND
    // inerted — the struct is freed and the wire resource's requests
    // become no-ops (wlroots nulls the source resource's user data on
    // cancel, wlr_primary_selection_v1.c:110-121). Re-passing the
    // cancelled source to set_selection behaves exactly like passing
    // NULL: the selection is cleared and the current owner is cancelled
    // (the null-tolerant extraction must not deref the freed struct).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    focusClient(ts, a);
    const device = try a.wl_manager.getDevice(a.wl_seat);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    const src_a = try a.wl_manager.createSource();
    src_a.offer("text/plain");
    var events_a: SourceEvents = .{};
    src_a.setListener(*SourceEvents, SourceEvents.listener, &events_a);
    try ts.pump();

    device.setSelection(src_a, 0);
    try ts.pump();
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());
    // src_b is created only after the first set: the sources list holds
    // exactly the live sources, so with a single source it is [src_a]
    // (len 1) here. The unlink is covered below — replacing A with B
    // frees A and drops the list to [src_b] (len 1).
    const src_b = try a.wl_manager.createSource();
    src_b.offer("text/plain");
    var events_b: SourceEvents = .{};
    src_b.setListener(*SourceEvents, SourceEvents.listener, &events_b);
    try ts.pump();

    // Replacing with B cancels A and inerts it (struct freed, unlinked).
    device.setSelection(src_b, 0);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_a.cancelled_count);
    try testing.expectEqual(src_b.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items.len);

    // Re-passing the cancelled source behaves like NULL: cleared, the
    // current owner is cancelled, no crash on the freed struct.
    device.setSelection(src_a, 0);
    try ts.pump();
    try testing.expectEqual(@as(?*PrimarySelectionSource, null), ts.mgr.?.selection_source);
    try testing.expect(events.last_selection_null);
    try testing.expectEqual(@as(usize, 1), events_b.cancelled_count);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.sources.items.len);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);
}

test "primary selection: re-setting the current source updates the serial only" {
    // F-SEL-4: wlroots wlr_seat_set_primary_selection early-returns when
    // the incoming source is already the selection, updating only the
    // serial (wlr_primary_selection.c:81-86) — no cancel, no
    // re-delivery, and the used-once denial does not fire. Observable
    // via the superseded gate: after the silent re-set advances the
    // serial to 2, a set with serial 1 is denied and the selection
    // stays A.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    var capture: SelectionEventCapture = .{
        .listener_set = wire.Listener(*PrimarySelection).init(SelectionEventCapture.onSet),
        .listener_cleared = wire.Listener(*PrimarySelection).init(SelectionEventCapture.onCleared),
    };
    ts.mgr.?.events.selection_set.add(&capture.listener_set);
    ts.mgr.?.events.selection_cleared.add(&capture.listener_cleared);

    focusClient(ts, a);
    const device = try a.wl_manager.getDevice(a.wl_seat);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    const src_a = try a.wl_manager.createSource();
    src_a.offer("text/plain");
    const src_b = try a.wl_manager.createSource();
    src_b.offer("text/plain");
    var events_a: SourceEvents = .{};
    src_a.setListener(*SourceEvents, SourceEvents.listener, &events_a);
    try ts.pump();

    // Set A with serial 1.
    device.setSelection(src_a, 1);
    try ts.pump();
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(u32, 1), ts.mgr.?.selection_serial);
    try testing.expectEqual(@as(usize, 1), capture.set_count);
    const selection_count = events.selection_count;

    // Re-set A with serial 2: silent serial update — no new selection
    // events, no cancel, no selection_set signal.
    device.setSelection(src_a, 2);
    try ts.pump();
    try testing.expectEqual(@as(u32, 2), ts.mgr.?.selection_serial);
    try testing.expectEqual(@as(usize, 1), capture.set_count);
    try testing.expectEqual(selection_count, events.selection_count);
    try testing.expectEqual(@as(usize, 0), events_a.cancelled_count);

    // The advanced serial now supersedes older requests: set B with
    // serial 1 is denied silently (1 -% 2 > maxInt/2) and the selection
    // stays A.
    device.setSelection(src_b, 1);
    try ts.pump();
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(u32, 2), ts.mgr.?.selection_serial);
    try testing.expectEqual(@as(usize, 1), capture.set_count);
    try testing.expectEqual(selection_count, events.selection_count);
    // The denied source was still burned (finalize before the gates).
    try testing.expect(ts.mgr.?.sources.items[1].finalized);
}

test "primary selection: get_device with an inert seat yields a dead device" {
    // F-SEL-5: the seat argument must map to a live seat (the XA-5
    // pattern, xdg_activation.zig:369-380). An inert seat still yields
    // a device resource — the client's object id must stay valid — but
    // the device is dead: no struct, no list entry, every request a
    // no-op.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    // Inert the server-side wl_seat resource (the XA-5 recipe,
    // xdg_activation.zig:1003-1006).
    const seat_res = a.client.getObject(a.wl_seat.getId()).?;
    seat_res.setDispatcher(null, null, null, null);

    const device = try a.wl_manager.getDevice(a.wl_seat);
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();

    // The inert path wires a dead handler without appending to the
    // manager's device list.
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.devices.items.len);

    // set_selection on the dead device is a silent no-op: nothing is
    // stored, nothing is delivered, no protocol error, no crash. The
    // source stays unfinalized (the request never reaches the gates).
    device.setSelection(src, 0);
    try ts.pump();
    try testing.expectEqual(@as(?*PrimarySelectionSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(@as(usize, 0), events.selection_count);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items.len);
    try testing.expect(!ts.mgr.?.sources.items[0].finalized);

    // destroy on the dead device works (the object id stays valid).
    device.destroy();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.devices.items.len);
}

test "primary selection: offer.receive with an unoffered mime closes the fd and relays nothing" {
    // F-SEL-6: mirrors the DD-7 check in data_device.zig — receive()
    // validates the mime against the offered list; an unknown mime
    // closes the fd and never relays a send (smithay selection/
    // offer.rs:177 validates for ALL offer kinds including primary,
    // offer.rs:148-152; wlroots relays blindly).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    const a = &ts.client_a.?;

    focusClient(ts, a);
    const device = try a.wl_manager.getDevice(a.wl_seat);
    const src = try a.wl_manager.createSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    var events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &events);
    try ts.pump();

    device.setSelection(src, 0);
    try ts.pump();
    const offer = events.last_offer.?;

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
    // peer end gone, sending on the other end is EPIPE (raw syscall
    // with MSG_NOSIGNAL keeps it an error instead of a SIGPIPE).
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
