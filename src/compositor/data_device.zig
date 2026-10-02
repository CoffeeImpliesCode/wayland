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
//!   - Offer lifetime mirrors wlroots. A SELECTION offer is destroyed
//!     (its wire resource left inert) whenever the selection is
//!     re-delivered or its source dies. A DRAG offer belongs to the
//!     in-flight drag instead and deliberately survives an accepted drop
//!     for the data transfer, so it — and only it — can outlive its
//!     source: sourceDestroy then nulls offer.source (wlroots
//!     data_offer_handle_source_destroy, wlr_data_offer.c:230-237,
//!     :273-274) and every request on such a DEAD offer raises
//!     wl_data_offer.error.invalid_offer instead of reading freed
//!     source memory.
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
//!   - A cancelled source is inert (F-SEL-3): the replaced/cleared
//!     owner's struct is freed and its wire resource becomes a no-op
//!     (wlroots nulls the resource user data on cancel,
//!     client_data_source_destroy, wlr_data_source.c:114-120). Re-passing
//!     a cancelled source to set_selection behaves exactly like NULL — it
//!     clears the selection.
//!   - set_selection with the current source updates the serial only
//!     (F-SEL-4; wlroots wlr_seat_set_selection early-returns on
//!     selection_source == source, wlr_data_device.c:184-189): no cancel,
//!     no re-delivery.
//!   - Every delivered offer emits wl_data_offer.source_actions (v3+)
//!     between its mime events and the selection event (F-SEL-2,
//!     wayland.xml:710-719); a clipboard source's mask is 0, the future
//!     drag path sends the real mask through the same line.
//!   - get_data_device with an inert or foreign seat argument yields a
//!     dead device (F-SEL-5): the object id stays valid, every request
//!     is a no-op (wlroots wlr_data_device.c:238-244).
//!   - One data device per client: a second get_data_device from the same
//!     client binds its new object to the device that client already has
//!     (DataDevice.objects holds the bound wire objects oldest-first;
//!     events go out on the first one, and when that object dies the next
//!     takes over). wlroots gives every call its own resource
//!     (wlr_data_device.c:226-252), keeps them all linked on
//!     seat_client->data_devices and sends every event on every one that
//!     is still there (seat_client_send_selection :138-141, drag_set_focus
//!     wlr_drag.c:88-109), so its drag creates one offer per object; this
//!     drag tracks a single Drag.offer, so a second device would orphan
//!     the first offer in manager.offers and double every drag event.
//!   - set_selection with a source that advertised DnD actions raises
//!     wl_data_source.error.invalid_source (KWin datadevice.cpp:91-101
//!     hardening; wlroots has no such check).
//!   - DnD action state is stored and negotiated per wlroots
//!     (data_offer_choose_action / data_offer_update_action,
//!     wlr_data_offer.c:22-76): the source's mask, the offer's
//!     mask/preferred action, the compositor-forced action and the
//!     current negotiated action. offer.set_actions stores and re-runs
//!     the negotiation, and the negotiated wl_data_offer.action /
//!     wl_data_source.action events go out with v3 guards. Only a DRAG
//!     offer negotiates — a selection offer raises
//!     wl_data_offer.error.invalid_offer — and drag offers are created
//!     by dragSetFocus with offer_type = .drag.
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
//! Drag-and-drop (start_drag) runs as a real drag (wlroots wlr_drag,
//! wlr_drag.c:22-256): a serial that validates against the seat's
//! pointer grab installs a drag pointer grab (the source is finalized
//! but NOT cancelled), the icon surface takes the wl_data_device-icon
//! role (wlr_data_device.c:65-72, wlr_drag.c:411-415) and is reachable
//! through DataDeviceManager.currentDragIcon, and motion over a surface
//! delivers enter/motion/leave plus a drag offer to that client's data
//! device. Releasing the origin button over an accepted target with a
//! negotiated action drops; anything else finishes the drag cancelled
//! (wlr_drag.c:113-125). Drag offers and selection offers share the
//! manager's offer list but are superseded by different rules: a
//! selection re-delivery destroys only the SELECTION offers, a drag
//! focus change or Drag.end only the DRAG offer (wlroots keeps
//! seat->selection_offers and seat->drag_offers in two lists,
//! wlr_data_offer.c:264-271).
//!
//! start_drag's source is nullable (wayland.xml:965) and TWO wire
//! shapes reach the drag with NO source: a NULL wire source, and a
//! source cancelSource already inerted (F-SEL-3 — the struct is freed
//! and the resource's user data nulled, which is exactly what wlroots
//! reads there, wlr_data_device.c:49-52). Both are the protocol's
//! source-less drag (wayland.xml:938-941): "If source is NULL, enter,
//! leave and motion events are sent only to the client that initiated
//! the drag and the client is expected to handle the data passing
//! internally." So Drag.source is optional and a null one delivers
//! enter/motion/leave to the initiating client ONLY — never to the
//! client under the pointer — with no wl_data_offer (no data passes
//! through the compositor, so there is nothing to offer), no drop, and
//! no dnd_drop_performed/dnd_finished (no source to send them on).
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, compositor/seat.zig.

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const seat_mod = @import("seat.zig");
const compositor_mod = @import("compositor.zig");
const surface_mod = @import("surface.zig");
const role_mod = @import("role.zig");

const server = @import("protocol").server;
const client = @import("protocol").client;
const Fixed = wire.wl.Fixed;

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
    /// Every live offer, selection and drag alike (wlroots keeps
    /// seat->selection_offers and seat->drag_offers in two separate
    /// lists, wlr_data_offer.c:264-271; both kinds share one struct
    /// here). The kinds have DIFFERENT supersession rules, so every
    /// sweep over this list filters on offer_type: a selection
    /// re-delivery or a keyboard focus change destroys only the
    /// SELECTION offers (wlroots seat_client_send_selection,
    /// wlr_data_device.c:125-142), a drag focus change or Drag.end
    /// only the DRAG offer (wlroots drag_set_focus, wlr_drag.c:36-58).
    offers: std.ArrayList(*DataOffer) = .empty,
    /// The in-flight drag, or null. One drag at a time per seat
    /// (wlroots seat->drag, wlr_drag.c:145).
    drag: ?*Drag = null,
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
        // End any in-flight drag first: its grab sits on the seat and
        // its end() clears the pointer grab + frees the drag (the
        // source destruction below would otherwise hit the
        // source-dies-mid-drag path).
        if (self.drag) |drag| drag.end(false);
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
        // Every wire object of every device, not just the one the events
        // go out on: the LAST object's destroy handler is what unlinks the
        // device and frees its struct, so a duplicate left behind here
        // would outlive the manager it links out of.
        while (self.devices.items.len > 0) {
            self.devices.items[0].objects.items[0].destroy();
        }
        self.sources.deinit(allocator);
        self.offers.deinit(allocator);
        self.devices.deinit(allocator);
        allocator.destroy(self);
    }

    /// The icon surface of the in-flight drag, or null when no drag is
    /// running. wl_data_device.start_drag's icon is a wl_surface the
    /// source client keeps alive for the drag (wlroots
    /// wlr_drag_create -> drag_icon_create, wlr_drag.c:424-441); the
    /// server's scene sync reads it here to draw the icon at the
    /// pointer.
    pub fn currentDragIcon(mgr: *DataDeviceManager) ?*surface_mod.Surface {
        const drag = mgr.drag orelse return null;
        return drag.icon;
    }
};

/// A client's data device: one per client per seat.
const DataDevice = struct {
    manager: *DataDeviceManager,
    /// Stored next to `manager` so the wire-object teardown path
    /// (deviceDestroy) can unlink the device and free the struct through
    /// its own fields.
    allocator: std.mem.Allocator,
    /// Every wl_data_device object bound to this device, oldest first: the
    /// object the first get_data_device created, then one entry per
    /// duplicate. The struct lives exactly as long as this list and is in
    /// manager.devices exactly while it is non-empty; its FIRST entry is
    /// the resource every event goes out on (eventResource).
    objects: std.ArrayListUnmanaged(*server.wl.DataDevice) = .empty,

    /// The resource every event goes out on: the oldest wl_data_device
    /// object this client still holds. A dying object is only dropped
    /// from the list, so the next one takes over and a client that still
    /// has an object keeps receiving events — wlroots likewise links
    /// every get_data_device call into seat_client->data_devices, its
    /// resource destroy handler only unlinks the dead object and frees
    /// nothing (data_device_handle_resource_destroy, wlr_data_device.c:
    /// 100-103), and the events then go out on the objects that are left
    /// (seat_client_send_selection :138-141, drag_set_focus wlr_drag.c:
    /// 88-109). Null once the LAST object is gone, and a device with no
    /// object is out of manager.devices, so no send site can reach a
    /// destroyed resource.
    fn eventResource(dev: *const DataDevice) ?*server.wl.DataDevice {
        return if (dev.objects.items.len == 0) null else dev.objects.items[0];
    }
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
    /// invalid_action check against it and the drag negotiation reads it.
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
    /// wlr_data_source.current_dnd_action). 0 = none. Read back by
    /// Drag.end's drop validation.
    current_dnd_action: u32 = 0,
    /// The destination accepted a mime via wl_data_offer.accept: true
    /// for a non-NULL mime, false on NULL/leave (wlroots:
    /// wlr_data_source.accepted). Drives Drag.end's drop validation.
    accepted: bool = false,
};

/// The kind of offer (wlroots enum wlr_data_offer_type): a selection
/// (clipboard) offer created by deliverSelectionToFocus, or a
/// drag-and-drop offer created by dragSetFocus. set_actions, accept and
/// finish only apply to drag offers. The two kinds share one list
/// (DataDeviceManager.offers) but are superseded by different rules, so
/// every sweep over that list filters on offer_type — wlroots keeps
/// selection_offers and drag_offers in two lists for the same reason
/// (wlr_data_offer.c:264-271).
const OfferType = enum { selection, drag };

/// A drag-and-drop operation (wlroots wlr_drag, wlr_drag.c). Lives on
/// the manager (one per seat); installed as a pointer grab on the seat
/// for its lifetime. The grab's data points at this struct; the grab is
/// ended (endPointerGrab) before the struct is freed, so cancel never
/// runs against freed memory (the ended flag also makes the
/// endPointerGrab→cancel→dragEnd recursion safe).
const Drag = struct {
    manager: *DataDeviceManager,
    /// The client that sent start_drag — "the client that initiated the
    /// drag" (wayland.xml:938-941). Recorded because a source-less
    /// drag has no source to name its one event recipient by.
    initiator: *wire.Client,
    /// The drag source, or null for the protocol's source-less drag.
    /// Two wire shapes produce null (wlroots reads the source
    /// resource's user data as-is, so it sees the same two:
    /// wlr_data_device.c:49-52): start_drag(NULL, ...), allowed by
    /// wayland.xml:965, and start_drag on a source cancelSource
    /// already inerted (F-SEL-3 — struct freed, user data nulled).
    ///
    /// A non-null source is finalized at start_drag and never
    /// cancelled while the drag lives (a denied serial keeps it
    /// finalized-but-alive, wlr_data_device.c:82-85).
    source: ?*DataSource,
    /// The drag icon surface (wl_data_device.start_drag icon arg), or
    /// null. It carries the wl_data_device-icon role for the drag's
    /// lifetime; the scene sync reads it through
    /// DataDeviceManager.currentDragIcon to draw it at the pointer.
    icon: ?*surface_mod.Surface = null,
    /// The surface currently under the pointer (drag target).
    focus: ?*surface_mod.Surface = null,
    /// The drag offer delivered to the focus client, or null. ONE slot:
    /// a client has at most one data device (managerRequest), so one
    /// drag delivers exactly one offer. Every path that destroys the
    /// offer clears the slot through the manager's tracked drag
    /// (destroyOffer for the compositor's own teardown, offerDestroy for
    /// the client's wl_data_offer.destroy) — a stale pointer here makes
    /// Drag.end destroy freed memory.
    offer: ?*DataOffer = null,
    /// True once the drop ran: the offer outlives the drag for the data
    /// transfer (wlroots keeps drag offers after drop, drag_set_focus
    /// wlr_drag.c:47-61). It is then the ONLY reason an offer can
    /// outlive its source, which sourceDestroy's sweep covers.
    dropped: bool = false,
    /// True once dragEnd ran: guards the endPointerGrab→cancel→dragEnd
    /// recursion and the destroy-during-cancel ordering.
    ended: bool = false,
    /// The installed pointer grab. SAFETY: `undefined` is read only
    /// after deviceRequest assigns the whole struct right after the Drag
    /// is built, and the seat's pointer_grab points at THIS field for
    /// exactly as long as the drag lives. Drag.end ends the grab (seat.
    /// endPointerGrab) before the Drag is freed, so no path reads it
    /// while undefined.
    grab: seat_mod.PointerGrab = undefined,

    /// End the drag (wlroots drag_destroy, wlr_drag.c:115-145): send
    /// leave, run the drop/finish protocol, end the grab, free.
    fn end(drag: *Drag, drop: bool) void {
        if (drag.ended) return;
        drag.ended = true;
        const mgr = drag.manager;
        const seat = mgr.seat;

        // The drop runs FIRST, against the live focus (wlroots
        // drag_handle_pointer_button drops then destroys the drag,
        // wlr_drag.c:113-125): only an accepted target with a negotiated
        // action gets the drop; anything else is a cancelled drag
        // (dnd_finished without dnd_drop_performed). The dropped offer
        // survives for the transfer (drag_set_focus keeps it,
        // wlr_drag.c:47-61).
        //
        // A source-less drag has none of that: no offer to accept, no
        // negotiated action and no source to carry dnd_drop_performed /
        // dnd_finished — wayland.xml:938-941 puts the data passing in
        // the initiator's hands, so the whole protocol is skipped
        // (wlroots guards the same two events on drag->source,
        // wlr_drag.c:113-125).
        if (drop) {
            if (drag.source) |src| {
                if (drag.targetClient() != null and
                    src.current_dnd_action != 0 and
                    src.accepted)
                {
                    drag.dropped = true;
                    const target_client = drag.targetClient().?;
                    for (mgr.devices.items) |dev| {
                        const res = dev.eventResource() orelse continue;
                        if (res.getClient() != target_client) continue;
                        res.sendDrop();
                    }
                    if (src.resource.getVersion() >= 3) {
                        src.resource.sendDndDropPerformed();
                    }
                }
                // dnd_finished always follows (accepted drop or not).
                if (src.resource.getVersion() >= 3) {
                    src.resource.sendDndFinished();
                }
            }
        }

        // Leave the current target (wlroots drag_set_focus NULL path):
        // the offer dies with the drag unless the drop already ran
        // (dropped offers survive for the transfer). A source-less
        // drag leaves only the client it entered (eventClient).
        if (drag.focus) |focus| {
            if (drag.eventClient(focus)) |target| {
                for (mgr.devices.items) |dev| {
                    const res = dev.eventResource() orelse continue;
                    if (res.getClient() != target) continue;
                    res.sendLeave();
                }
            }
            if (!drag.dropped) {
                if (drag.offer) |offer| destroyOffer(mgr, offer);
            }
        }
        drag.focus = null;

        // End the grab: cancel runs dragGrabCancel → drag.end (no-op via
        // the ended flag), then the seat clears the grab.
        if (seat.pointer_grab == &drag.grab) seat.endPointerGrab();

        if (mgr.drag == drag) mgr.drag = null;
        const allocator = mgr.allocator;
        allocator.destroy(drag);
    }

    /// The drag target's client (the client of the focused surface), or
    /// null when the pointer is over no surface.
    fn targetClient(drag: *const Drag) ?*wire.Client {
        const focus = drag.focus orelse return null;
        return focus.resource.getClient();
    }

    /// The client the drag's enter/motion/leave events go to while the
    /// pointer is over `s`, or null when this drag sends `s`'s client
    /// nothing at all.
    ///
    /// A source-backed drag reaches whichever client owns the surface
    /// (wlroots drag_set_focus, wlr_drag.c:88-109). A source-less drag
    /// reaches only its initiator (wayland.xml:938-941: "If source is
    /// NULL, enter, leave and motion events are sent only to the client
    /// that initiated the drag"), so the pointer over a foreign surface
    /// delivers nothing — that client is not part of this drag.
    fn eventClient(drag: *const Drag, s: *surface_mod.Surface) ?*wire.Client {
        const owner = s.resource.getClient();
        if (drag.source == null and owner != drag.initiator) return null;
        return owner;
    }
};

/// The drag grab's pointer motion: hit-test, enter/leave the target's
/// data device, send motion. Mirrors wlroots drag_handle_pointer_motion
/// + drag_set_focus (wlr_drag.c:47-87, 126-133): the compositor's pick
/// callback answers the hit test; the seat's default grab does the same
/// for normal pointer motion.
fn dragGrabMotion(seat: *seat_mod.Seat, grab: *const seat_mod.PointerGrab, x: i32, y: i32) void {
    const drag: *Drag = @ptrCast(@alignCast(grab.data.?));
    const pick = if (seat.pick_fn) |f| f(seat.pick_ctx.?, x, y) else null;

    if (pick) |p| {
        if (drag.focus != p.surface) {
            // Target changed: leave the old, enter the new.
            dragSetFocus(drag, p.surface, p.sx, p.sy);
        } else {
            // Same target: motion. eventClient drops it for a
            // source-less drag over a foreign surface
            // (wayland.xml:938-941).
            const target = drag.eventClient(drag.focus orelse return) orelse return;
            const time = seat.nowMs();
            for (drag.manager.devices.items) |dev| {
                const res = dev.eventResource() orelse continue;
                if (res.getClient() != target) continue;
                res.sendMotion(@intCast(time), Fixed.fromInt(@intCast(p.sx)), Fixed.fromInt(@intCast(p.sy)));
            }
        }
    } else {
        dragSetFocus(drag, null, 0, 0);
    }
}

/// Set (or clear) the drag target (wlroots drag_set_focus,
/// wlr_drag.c:28-112): leave the old target's device, create a fresh
/// drag offer for the new target's device, enter it.
///
/// A source-less drag enters NOTHING but its own initiator
/// (wayland.xml:938-941) and creates no wl_data_offer: with no source
/// there are no mime types to advertise and no transfer to make —
/// "the client is expected to handle the data passing internally".
/// Its enter carries the NULL offer wayland.xml:1010-1011 allows.
fn dragSetFocus(drag: *Drag, surface: ?*surface_mod.Surface, sx: i32, sy: i32) void {
    const mgr = drag.manager;
    const seat = mgr.seat;
    if (drag.focus == surface) return;

    // Leave the old target; the offer dies with the focus change unless
    // the drop already ran (the dropped offer stays for the transfer).
    if (drag.focus) |old| {
        if (drag.eventClient(old)) |old_client| {
            for (mgr.devices.items) |dev| {
                const res = dev.eventResource() orelse continue;
                if (res.getClient() != old_client) continue;
                res.sendLeave();
            }
        }
        if (!drag.dropped) {
            // destroyOffer clears drag.offer through the manager's
            // tracked drag, so the slot never names a freed struct.
            if (drag.offer) |offer| destroyOffer(mgr, offer);
        }
    }
    drag.focus = null;

    const s = surface orelse return;
    // The client this drag tells about `s`, or null when it tells
    // nobody: every surface's owner for a source-backed drag, the
    // initiator's surfaces only for a source-less one (eventClient,
    // wayland.xml:938-941).
    const target_client = drag.eventClient(s);
    // Focus tracks the surface under the pointer either way, so the
    // next hit-test change leaves the surface the pointer really left.
    drag.focus = s;
    const src = drag.source orelse {
        // Source-less drag over the initiator's own surface: enter with
        // a NULL offer, no data_offer event in front of it (none was
        // created) — there is no data to pass through the compositor.
        const client_wire = target_client orelse return;
        const serial = seat.serialFor(client_wire);
        for (mgr.devices.items) |dev| {
            const res = dev.eventResource() orelse continue;
            if (res.getClient() != client_wire) continue;
            res.sendEnter(serial, s.resource, Fixed.fromInt(@intCast(sx)), Fixed.fromInt(@intCast(sy)), null);
        }
        log.debug("source-less drag entered surface@{d} (initiator only)", mgr.io, mgr.log_cfg, "data_device", .{
            s.resource.getId(),
        });
        return;
    };
    // The drag may target any client's surface (wlroots allows it); only
    // the source client is special. Deliver to the surface's client,
    // which has at most one data device, so exactly one offer is
    // created and exactly one offer slot is filled.
    const client_wire = target_client.?;
    for (mgr.devices.items) |dev| {
        const res = dev.eventResource() orelse continue;
        if (res.getClient() != client_wire) continue;
        const offer = createOffer(mgr, mgr.allocator, res, src, .drag) orelse return;
        // Order: data_offer, per-mime offer, source_actions (v3+),
        // then enter (wlroots wlr_drag.c:93-101).
        res.sendDataOffer(offer.resource);
        for (src.mime_types.items) |m| offer.resource.sendOffer(m.ptr);
        if (offer.resource.getVersion() >= 3) {
            offer.resource.sendSourceActions(@bitCast(src.actions orelse 0));
        }
        const serial = seat.serialFor(client_wire);
        res.sendEnter(serial, s.resource, Fixed.fromInt(@intCast(sx)), Fixed.fromInt(@intCast(sy)), offer.resource);
        drag.offer = offer;
        log.debug("drag entered surface@{d}", mgr.io, mgr.log_cfg, "data_device", .{s.resource.getId()});
    }
}

/// The drag grab's button: releasing the ORIGIN button ends the drag —
/// drop when the target accepted + an action is negotiated, else
/// dnd_finished without drop (wlroots drag_handle_pointer_button,
/// wlr_drag.c:113-125).
fn dragGrabButton(seat: *seat_mod.Seat, grab: *const seat_mod.PointerGrab, button: u32, pressed: bool) void {
    const drag: *Drag = @ptrCast(@alignCast(grab.data.?));
    if (pressed) return;
    // Only the origin button's release ends the drag.
    if (button != seat.grab_button and seat.pressed_count > 0) return;
    drag.end(true);
}

/// The drag swallow for axis events (wlroots blanks the axis handler,
/// wlr_drag.c:133-137).
fn dragGrabAxis(
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

/// The drag grab was replaced or the seat ended it: end the drag
/// without a drop (wlroots drag_handle_pointer_cancel, wlr_drag.c:141).
fn dragGrabCancel(seat: *seat_mod.Seat, grab: *const seat_mod.PointerGrab) void {
    _ = seat;
    const drag: *Drag = @ptrCast(@alignCast(grab.data.?));
    drag.end(false);
}

/// A data offer delivered to a target client.
const DataOffer = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataOffer,
    /// The offering client's source, or null once the offer is DEAD.
    /// Nulled when the offer is destroyed (the source may already be
    /// freed) and when the source itself dies under a dropped drag offer
    /// (sourceDestroy's sweep), so a dead offer never reads freed source
    /// memory (wlroots nulls offer->source in
    /// data_offer_handle_source_destroy, wlr_data_offer.c:230-237).
    source: ?*DataSource,
    offer_type: OfferType = .selection,
    /// The destination's supported action mask
    /// (wl_data_offer.set_actions; wlroots data_offer->actions).
    actions: u32 = 0,
    /// The destination's preferred action
    /// (wl_data_offer.set_actions; wlroots data_offer->preferred_action).
    preferred_action: u32 = 0,
    /// The negotiated action is .ask (F-SEL-7): while an ask
    /// negotiation is pending, action events are suppressed on both
    /// sides (wlroots data_offer->in_ask, wlr_data_device.h:43 — the
    /// field exists but is never set in 0.20.2; smithay models the
    /// suppression). The client resolves ask by sending a follow-up
    /// set_actions with a concrete action.
    in_ask: bool = false,
};

/// Create the wl_data_offer resource and its DataOffer struct for one
/// delivery to `dev_res` — the device object the events go out on — and
/// link the struct into mgr.offers. Returns null when either allocation
/// fails, with NOTHING left behind: the resource is destroyed and the
/// struct freed on both paths (wlroots data_offer_create, wlr_data_offer.c:
/// 239-284, frees its calloc before returning NULL for the same reason,
/// and likewise takes the DEVICE resource, so the offer inherits that
/// object's client and version). `allocator` is a parameter so a test can
/// drive the out-of-memory paths with a FailingAllocator; production
/// always passes mgr.allocator.
fn createOffer(
    mgr: *DataDeviceManager,
    allocator: std.mem.Allocator,
    dev_res: *server.wl.DataDevice,
    src: *DataSource,
    offer_type: OfferType,
) ?*DataOffer {
    const offer_res = server.wl.DataOffer.create(dev_res.getClient(), dev_res.getVersion(), 0) catch return null;
    const offer = allocator.create(DataOffer) catch {
        // No handler is installed yet: destroying the resource cannot
        // reach the struct, so free it here or it leaks.
        offer_res.destroy();
        return null;
    };
    offer.* = .{
        .manager = mgr,
        .resource = offer_res,
        .source = src,
        .offer_type = offer_type,
    };
    offer_res.setHandler(*DataOffer, offerRequest, offerDestroy, offer);
    mgr.offers.append(allocator, offer) catch {
        // offerDestroy unlinks (it is not in the list) and frees the
        // struct; destroying the resource runs it.
        offer_res.destroy();
        return null;
    };
    return offer;
}

/// wl_data_device_manager.dnd_action bits (wayland.xml).
const dnd_action_none: u32 = 0;
const dnd_action_copy: u32 = 1;
const dnd_action_move: u32 = 2;
const dnd_action_ask: u32 = 4;

/// The role a drag icon surface carries for the drag's lifetime (wlroots
/// drag_icon_surface_role, wlr_drag.c:411-415, assigned by
/// data_device_start_drag, wlr_data_device.c:65-72). Only the name is
/// protocol-visible; the commit hook is empty because the icon is mapped
/// by the client's own commit and drawn by the scene sync.
const drag_icon_role: role_mod.SurfaceRole = .{ .name = "wl_data_device-icon" };

/// The live data device of `client_wire`, or null. There is at most one
/// per client: a duplicate get_data_device binds its wire object to the
/// existing device (managerRequest).
fn deviceForClient(mgr: *DataDeviceManager, client_wire: *wire.Client) ?*DataDevice {
    for (mgr.devices.items) |dev| {
        const res = dev.eventResource() orelse continue;
        if (res.getClient() == client_wire) return dev;
    }
    return null;
}

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
            // F-SEL-5: the seat argument must map to a live seat (the
            // XA-5 pattern, xdg_activation.zig:369-380). An inert or
            // foreign seat still yields a device resource — the client's
            // object id must stay valid, or the next request kills the
            // client — but the device is dead: no struct, no list entry,
            // no bind-time delivery (wlroots creates the resource with
            // NULL user data when the seat client is NULL and skips
            // linking, wlr_data_device.c:238-244).
            const seat_ud = r.seat.getUserData() orelse {
                dev_res.setHandler(?*DataDevice, deadDeviceHandler, null, null);
                return;
            };
            const seat: *seat_mod.Seat = @ptrCast(@alignCast(seat_ud));
            if (seat != mgr.seat) {
                dev_res.setHandler(?*DataDevice, deadDeviceHandler, null, null);
                return;
            }
            // One device per client. wlroots keys the device off
            // seat_client but still hands EVERY get_data_device call its
            // own wire resource (wlr_data_device.c:226-252); its drag
            // then creates one offer per object (wlr_drag.c:88-109).
            // Ours tracks a single Drag.offer, so a second device would
            // orphan the first offer in mgr.offers — a live wl_data_offer
            // resource holding a live source long after the drag ended —
            // and deliver two data_offer/enter/drop sequences for one
            // drag. Bind the duplicate object to the existing device
            // instead: deviceRequest keeps no state in its own resource
            // (it reads the client and runs the same request logic), so
            // the requests work, only the device's oldest live object
            // ever receives events — and when that object dies the
            // duplicate takes over (deviceDestroy).
            if (deviceForClient(mgr, resource.getClient())) |dev| {
                dev.objects.append(dev.allocator, dev_res) catch {
                    // No handler is installed yet, so destroying the
                    // resource cannot reach the device.
                    dev_res.destroy();
                    resource.getClient().postNoMemory();
                    return;
                };
                dev_res.setHandler(*DataDevice, deviceRequest, deviceDestroy, dev);
                return;
            }
            const dev = mgr.allocator.create(DataDevice) catch {
                dev_res.destroy();
                resource.getClient().postNoMemory();
                return;
            };
            dev.* = .{
                .manager = mgr,
                .allocator = mgr.allocator,
            };
            dev.objects.append(dev.allocator, dev_res) catch {
                dev_res.destroy();
                mgr.allocator.destroy(dev);
                resource.getClient().postNoMemory();
                return;
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

/// Unlink a data source from the manager and free it (mime list +
/// struct). Shared by cancelSource and sourceDestroy.
fn freeSource(mgr: *DataDeviceManager, src: *DataSource) void {
    if (std.mem.findScalar(*DataSource, mgr.sources.items, src)) |idx| {
        _ = mgr.sources.orderedRemove(idx);
    }
    // No offer may outlive the source it points at. freeSource is the
    // single choke point for source death (cancelSource and
    // sourceDestroy both funnel here), so the sweep belongs here: every
    // offer that referenced this source becomes DEAD (source = null)
    // before the struct goes. wlroots reaches the same state from the
    // offer side — every offer registers
    // data_offer_handle_source_destroy, which nulls offer->source
    // (wlr_data_offer.c:230-237, :273-274). A live drag's offer is
    // destroyed before this runs (sourceDestroy ends the drag); only a
    // dropped drag offer survives to be swept here.
    for (mgr.offers.items) |offer| {
        if (offer.source == src) offer.source = null;
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
/// user data on cancel, client_data_source_destroy, wlr_data_source.c:
/// 114-120). A cancelled source re-passed to set_selection extracts to
/// null and behaves exactly like NULL — it clears the selection.
fn cancelSource(mgr: *DataDeviceManager, src: *DataSource) void {
    src.resource.sendCancelled();
    src.resource.setHandler(?*DataSource, deadSourceHandler, null, null);
    freeSource(mgr, src);
}

/// Request handler for inerted (cancelled) data sources: the struct is
/// freed, so nothing is dereferenced — every request is a no-op
/// (wlroots: wl_resource_set_user_data(NULL) on cancel). The destroy
/// callback is null, so client teardown cannot call into the freed
/// struct.
fn deadSourceHandler(resource: *server.wl.DataSource, request: server.wl.DataSource.Request, data: ?*DataSource) void {
    _ = resource;
    _ = data;
    switch (request) {
        .offer => {},
        .set_actions => {},
        .destroy => {},
    }
}

fn sourceDestroy(src_res: *server.wl.DataSource, src: *DataSource) void {
    _ = src_res;
    const mgr = src.manager;
    // F-SEL-1: a drag source dying mid-drag ends the drag (its offer
    // would reference the freed source; end() destroys the offer via
    // the focus-clear path).
    if (mgr.drag) |drag| {
        if (drag.source == src) drag.end(false);
    }
    if (mgr.selection_source == src) {
        // The selected source died: clear the seat-wide selection and
        // cancel the (already dying) source. The re-delivery below
        // destroys every SELECTION offer that referenced it (wlroots:
        // seat_handle_selection_source_destroy clears the selection and
        // re-sends selection to the focused client, which first destroys
        // all selection offers, wlr_data_device.c:167-178, :125-142).
        mgr.selection_source = null;
        src.resource.sendCancelled();
        deliverSelectionToFocus(mgr);
    }
    // A surviving DRAG offer (the dropped one Drag.end keeps for the
    // transfer) is made DEAD by freeSource's sweep below: a live drag
    // was ended above, and that offer is the only thing that can outlive
    // its source.
    freeSource(mgr, src);
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
            // gates reject still burns the source. Extraction is
            // null-tolerant (F-SEL-3): a cancelled source's resource is
            // inert (null user data), and behaves exactly like NULL —
            // the clear branch below.
            var new_source: ?*DataSource = null;
            if (r.source) |src_res| {
                if (src_res.getUserData()) |ud| {
                    const src: *DataSource = @ptrCast(@alignCast(ud));
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
                    new_source = src;
                }
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
            // F-SEL-4: re-passing the current live source updates the
            // serial only — no cancel, no re-delivery (wlroots
            // wlr_seat_set_selection early-returns on
            // selection_source == source, updating only selection_serial,
            // wlr_data_device.c:184-189).
            if (new_source) |src| {
                if (mgr.selection_source) |cur| {
                    if (src == cur) {
                        mgr.selection_serial = r.serial;
                        return;
                    }
                }
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
                log.debug("selection set with {d} mime types", mgr.io, mgr.log_cfg, "data_device", .{
                    src.mime_types.items.len,
                });
            } else {
                // Null source — or a cancelled (inert) source: clear the
                // selection.
                if (mgr.selection_source) |old| cancelSource(mgr, old);
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
            // grab", data_device/device.rs). Extraction is
            // null-tolerant, and BOTH wire shapes that carry no live
            // source collapse to the same null (wlroots reads the
            // source resource's user data as-is, so it sees the same
            // two, wlr_data_device.c:49-52): a NULL wire source
            // (allow-null, wayland.xml:965) and a source cancelSource
            // already inerted (F-SEL-3 — struct freed, user data
            // nulled). That null is NOT an early-out: it is the
            // protocol's source-less drag (wayland.xml:938-941), so
            // Drag.source is optional and Drag.eventClient confines the
            // enter/motion/leave events to the initiating client.
            const src: ?*DataSource = if (r.source) |src_res|
                if (src_res.getUserData()) |ud|
                    @ptrCast(@alignCast(ud))
                else
                    null
            else
                null;
            if (src) |s| s.finalized = true;

            // The drag origin: the surface the pointer was over when the
            // press happened (wlroots validates the pointer grab serial
            // against the seat's grab state, wlr_seat_pointer.c:603-617).
            const origin_ud = r.origin.getUserData() orelse return;
            const origin: *surface_mod.Surface = @ptrCast(@alignCast(origin_ud));

            // The icon surface takes the drag-icon role (wlroots
            // data_device_start_drag assigns it before it builds the
            // drag, wlr_data_device.c:65-72; the role is
            // drag_icon_surface_role, wlr_drag.c:411-415). A role
            // conflict drops the request outright, exactly like
            // wlroots' WL_DATA_DEVICE_ERROR_ROLE path: assignRole has
            // already posted the error to the offending surface.
            var icon: ?*surface_mod.Surface = null;
            if (r.icon) |icon_res| {
                if (icon_res.getUserData()) |ud| {
                    const icon_surface: *surface_mod.Surface = @ptrCast(@alignCast(ud));
                    role_mod.assignRole(icon_surface, &drag_icon_role, null) catch {
                        log.debug(
                            "start_drag: icon surface@{d} already has a role: no drag icon",
                            mgr.io,
                            mgr.log_cfg,
                            "data_device",
                            .{icon_surface.resource.getId()},
                        );
                        return;
                    };
                    icon = icon_surface;
                }
            }
            // F-SEL-1: validate via the seat's grab serial (S-F5): the
            // client must be holding exactly one button, the serial must
            // be the one minted for that press, and the pointer must
            // still be over the origin surface.
            if (!mgr.seat.validatePointerGrabSerial(origin, r.serial)) {
                log.debug(
                    "rejecting start_drag: no valid pointer grab serial",
                    mgr.io,
                    mgr.log_cfg,
                    "data_device",
                    .{},
                );
                return;
            }

            const drag = mgr.allocator.create(Drag) catch {
                dev_res.getClient().postNoMemory();
                return;
            };
            errdefer mgr.allocator.destroy(drag);
            drag.* = .{
                .manager = mgr,
                .initiator = dev_res.getClient(),
                .source = src,
                .icon = icon,
            };
            drag.grab = .{
                .data = drag,
                .motion = dragGrabMotion,
                .button = dragGrabButton,
                .axis = dragGrabAxis,
                .cancel = dragGrabCancel,
            };

            // Install the grab BEFORE exposing the drag: the grab's
            // cancel path (a pre-existing grab being replaced) ends the
            // drag cleanly. One drag at a time (wlroots seat->drag).
            if (mgr.drag) |old| old.end(false);
            mgr.drag = drag;
            mgr.seat.startPointerGrab(&drag.grab);

            log.info("start_drag: grab installed (origin surface@{d})", mgr.io, mgr.log_cfg, "data_device", .{
                origin.resource.getId(),
            });
        },
        .release => dev_res.destroy(),
    }
}

/// Request handler for inerted (dead) data devices: no struct exists, so
/// every request is a no-op (wlroots: the resource carries NULL user
/// data, wlr_data_device.c:238-244). The destroy callback is null, so
/// client teardown cannot call into a freed struct.
fn deadDeviceHandler(resource: *server.wl.DataDevice, request: server.wl.DataDevice.Request, data: ?*DataDevice) void {
    _ = resource;
    _ = data;
    switch (request) {
        .set_selection => {},
        .start_drag => {},
        .release => {},
    }
}

/// Teardown of ANY bound wl_data_device object — the one the first
/// get_data_device created or a duplicate. The object leaves the device's
/// list and the next one takes over as the event resource, so no event is
/// ever sent on a destroyed resource and a client that still holds an
/// object keeps receiving them (wlroots drops the dead object's link and
/// nothing else, data_device_handle_resource_destroy, wlr_data_device.c:
/// 100-103). The seat-wide selection is owned by the manager, not the
/// device: it survives the device (wlr_seat keeps the selection when the
/// device dies; the source stays valid for the focused client). The LAST
/// object takes the device out of manager.devices and frees the struct.
///
/// Every bound object carries this handler, so the one that empties the
/// list always runs while the manager is alive: DataDeviceManager.deinit
/// destroys every object of every device before it frees itself.
fn deviceDestroy(dev_res: *server.wl.DataDevice, dev: *DataDevice) void {
    // Bound by construction: the handler is installed together with the
    // entry, so the dying resource is always in the list.
    const idx = std.mem.indexOfScalar(
        *server.wl.DataDevice,
        dev.objects.items,
        dev_res,
    ) orelse unreachable;
    _ = dev.objects.orderedRemove(idx);
    if (dev.objects.items.len > 0) return;
    unlinkDevice(dev.manager, dev);
    dev.objects.deinit(dev.allocator);
    dev.allocator.destroy(dev);
}

/// Drop the device from the manager's device list. No-op when it is
/// already out (the append-failure path in managerRequest frees a
/// device that never got linked).
fn unlinkDevice(mgr: *DataDeviceManager, dev: *DataDevice) void {
    if (std.mem.findScalar(*DataDevice, mgr.devices.items, dev)) |idx| {
        _ = mgr.devices.orderedRemove(idx);
    }
}

/// Keyboard focus moved: deliver the stored selection to the focused
/// client (or clear it on unfocus).
fn onKeyboardFocus(listener: *wire.Listener(*seat_mod.Seat), seat: *seat_mod.Seat) void {
    const mgr: *DataDeviceManager = @fieldParentPtr("focus_listener", listener);
    _ = seat;
    deliverSelectionToFocus(mgr);
}

/// For the focused client's data device: destroy the previous selection
/// offers and deliver the stored selection — a fresh offer when a
/// selection exists, selection(NULL) when it was cleared (wlroots:
/// seat_client_send_selection / device_resource_send_selection,
/// wlr_data_device.c:105-142).
fn deliverSelectionToFocus(mgr: *DataDeviceManager) void {
    // A re-delivery (new/cleared selection, focus change, source death)
    // supersedes every previous SELECTION offer: destroy them all first,
    // so no stale offer outlives the selection it advertises (wlroots
    // destroys all seat selection offers before re-sending,
    // wlr_data_device.c:131-136). Drag offers are NOT selection offers
    // and are left alone — a keyboard focus change happens mid-drag all
    // the time (Seat.pointerButton moves focus before it dispatches the
    // grab, seat.zig:974-992).
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
        const res = dev.eventResource() orelse continue;
        if (res.getClient() != focus_client) continue;
        if (src) |s| {
            // The offer is introduced in a data_device event, so its
            // version follows the device's (wlroots: data_offer_create,
            // wl_resource_get_version(device_resource),
            // wlr_data_offer.c:249-251) — never the module maximum.
            const offer = createOffer(mgr, mgr.allocator, res, s, .selection) orelse return;
            const offer_res = offer.resource;
            // Order matters (wlroots device_resource_send_selection,
            // wlr_data_device.c): introduce the offer via data_offer
            // FIRST, then the per-mime offer events, then selection.
            // libwayland-client discards events for object ids it does
            // not know yet (queue_event, wayland-client.c), so sending
            // the mimes before data_offer would silently drop them.
            res.sendDataOffer(offer_res);
            for (s.mime_types.items) |m| offer_res.sendOffer(m.ptr);
            // F-SEL-2: wl_data_offer.source_actions is mandated
            // "immediately after creating the wl_data_offer object"
            // (wayland.xml:710-719) — the emission sits between the
            // per-mime offer events and the selection event, v3+ only.
            // The payload is the source's action mask: 0 for a clipboard
            // source (the KWin invalid_source gate rejects
            // action-advertising sources at set_selection); dragSetFocus
            // sends the real mask through this same line for a drag
            // offer (wlroots wlr_drag.c:98-101).
            if (offer_res.getVersion() >= 3) offer_res.sendSourceActions(@bitCast(s.actions orelse 0));
            res.sendSelection(offer_res);
            log.debug("selection delivered to focused client ({d} mimes)", mgr.io, mgr.log_cfg, "data_device", .{
                s.mime_types.items.len,
            });
        } else {
            // No selection: the focused client's offer is void
            // (wlroots: wl_data_device_send_selection(device, NULL),
            // device_resource_send_selection).
            res.sendSelection(null);
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
/// wlr_data_offer.c:57-76). The source's current action is stored so
/// Drag.end's drop validation can read it back. Only a live drag offer
/// gets here — a selection offer is refused with invalid_offer before
/// this runs — and `source` is null only once the source died, in which
/// case there is nobody left to negotiate with. A source-less drag
/// (wayland.xml:938-941) creates no offer at all, so there is nothing
/// to negotiate and no action event goes anywhere.
/// wlroots also suppresses
/// the events during "ask" negotiation (offer->in_ask, declared in
/// wlr_data_device.h:43 but never set in 0.20.2); this models that
/// suppression from the negotiated action itself.
fn updateAction(offer: *DataOffer) void {
    const src = offer.source orelse return;
    const action = chooseAction(offer);
    // F-SEL-7: while the negotiation is in ask, neither side sees
    // action events — the destination resolves ask with a follow-up
    // set_actions carrying a concrete action (wlroots data_offer->in_ask
    // suppression, wlr_data_device.h:43; smithay models the same). The
    // STATE still updates so the drop/finish path reads the resolved
    // action.
    offer.in_ask = action == dnd_action_ask;
    if (src.current_dnd_action == action) return;
    src.current_dnd_action = action;
    if (offer.in_ask) return;
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
            // payload into it, the target reads it. A DEAD offer — one
            // whose source died under it, which only a dropped drag
            // offer can be, sourceDestroy's sweep nulls it — has nobody
            // to relay to: raise invalid_offer, "offer doesn't accept
            // this request" (wayland.xml:588-589), the same refusal
            // set_actions makes below. wlroots instead inerts the whole
            // offer (data_offer_destroy, wlr_data_offer.c:211-214) so
            // receive() silently closes the fd and the target blocks
            // forever on a pipe nobody will write. The fd arrived with
            // the request either way, so both paths close it.
            const src = offer.source orelse {
                offer_res.postError(.invalid_offer, "wl_data_offer.receive: offer has no source");
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
            // protocol error is raised." Drag offers (F-SEL-1) accept
            // finish: the target declares the transfer complete and the
            // offer is destroyed client-side (wlroots
            // data_offer_handle_finish, wlr_data_offer.c).
            if (offer.offer_type != .drag) {
                offer_res.postError(.invalid_finish, "wl_data_offer.finish: not a drag-and-drop offer");
                return;
            }
            offer_res.destroy();
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
    // the client): unlink and free. If this was the drag's current
    // offer, clear the drag's pointer — a later drag.end() (source
    // teardown) must never destroyOffer a freed struct (double free).
    if (mgr.drag) |drag| {
        if (drag.offer == offer) drag.offer = null;
    }
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

/// Destroy an offer the compositor owns: unlink and free it, and leave
/// its wire resource inert with a no-op handler. Inerting — not
/// destroying — matters: the object id stays valid, so a well-behaved
/// client that destroys its offer after selection(NULL) neither errors
/// nor is killed, and a NULL-implementation resource would make
/// libwayland abort the compositor on the next request (wlroots inerts:
/// data_offer_destroy, wlr_data_offer.c:191-215; wayland-server.c
/// wl_closure_invoke aborts on NULL implementation).
fn destroyOffer(mgr: *DataDeviceManager, offer: *DataOffer) void {
    if (std.mem.findScalar(*DataOffer, mgr.offers.items, offer)) |idx| {
        _ = mgr.offers.orderedRemove(idx);
    }
    // The live drag tracks the offer it delivered to its focus client so
    // it can destroy that offer on a focus change or at drag end. Clear
    // the slot HERE, not only in offerDestroy: this path frees the offer
    // from under the drag, and a stale Drag.offer makes Drag.end (or the
    // next dragSetFocus) destroy freed memory.
    if (mgr.drag) |drag| {
        if (drag.offer == offer) drag.offer = null;
    }
    // Drop the source reference before freeing: the source may already
    // be gone (sourceDestroy clears the selection before the offers).
    // The dead offer must never read it (wlroots nulls offer->source in
    // data_offer_handle_source_destroy, wlr_data_offer.c:230-237).
    offer.source = null;
    offer.resource.setHandler(?*DataOffer, deadOfferHandler, null, null);
    mgr.allocator.destroy(offer);
}

/// Destroy every live SELECTION offer. Drag offers are NOT touched: they
/// belong to the in-flight drag, not to the selection, and a selection
/// re-delivery must not tear a live drag's offer down — wlroots keeps
/// seat->selection_offers and seat->drag_offers in two lists for exactly
/// this reason (wlr_data_offer.c:264-271) and only walks the selection
/// one in seat_client_send_selection (wlr_data_device.c:131-136).
fn destroyAllOffers(mgr: *DataDeviceManager) void {
    var i: usize = 0;
    while (i < mgr.offers.items.len) {
        const offer = mgr.offers.items[i];
        if (offer.offer_type != .selection) {
            i += 1;
            continue;
        }
        // destroyOffer removes the entry with orderedRemove, which
        // shifts the tail left, so this index now holds the next offer.
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

/// The seat hit-test context: which surface the pick returns (DnD drag
/// enter/motion routing + the S-F5 grab_serial mint need a pick that
/// answers).
const PickState = struct {
    surface: ?*surface_mod.Surface = null,
};

fn testPick(ctx: *anyopaque, x: i32, y: i32) ?seat_mod.Seat.PickResult {
    const st: *PickState = @ptrCast(@alignCast(ctx));
    if (st.surface) |s| return .{ .surface = s, .sx = x, .sy = y };
    return null;
}

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
            // arms exist for the exhaustive switch over the wire enum.
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

/// Records the delivery order of one offer's events: mime offers (0),
/// source_actions (1) and the device's selection (2), so the F-SEL-2
/// emission point (between the mime events and the selection event,
/// wayland.xml:710-719) can be asserted. The offer listener is attached
/// from inside the data_offer handler so it is live before the offer's
/// own events are dispatched in the same round (the server sends
/// data_offer -> mimes -> source_actions -> selection,
/// deliverSelectionToFocus).
const SourceActionsSequence = struct {
    /// Event kinds in delivery order (0 = mime offer, 1 = source_actions,
    /// 2 = selection). Fixed-size: a test delivers at most one offer with
    /// one mime; the initial focus delivery contributes one NULL
    /// selection at most.
    kinds: [8]u8 = [_]u8{0} ** 8,
    kind_count: usize = 0,
    source_actions_count: usize = 0,
    last_source_actions: u32 = 0,

    fn record(data: *SourceActionsSequence, kind: u8) void {
        if (data.kind_count < data.kinds.len) {
            data.kinds[data.kind_count] = kind;
            data.kind_count += 1;
        }
    }

    fn deviceListener(
        device: *client.wl.DataDevice,
        event: client.wl.DataDevice.Event,
        data: *SourceActionsSequence,
    ) void {
        _ = device;
        switch (event) {
            .data_offer => |e| {
                e.id.setListener(*SourceActionsSequence, SourceActionsSequence.offerListener, data);
            },
            .selection => record(data, 2),
            // DnD events: the test client never drags; the arms exist for
            // exhaustive switch over the wire event enum.
            .enter => {},
            .leave => {},
            .motion => {},
            .drop => {},
        }
    }

    fn offerListener(offer: *client.wl.DataOffer, event: client.wl.DataOffer.Event, data: *SourceActionsSequence) void {
        _ = offer;
        switch (event) {
            .offer => record(data, 0),
            .source_actions => |e| {
                data.source_actions_count += 1;
                const v: u32 = @bitCast(e.source_actions);
                data.last_source_actions = v;
                record(data, 1);
            },
            .action => {},
        }
    }
};

/// The one definition of a test roundtrip (flush the client, dispatch the
/// server's event loop, flush the replies back). See pump below.
const test_pump = @import("../utils/test_pump.zig");

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
    /// The seat hit-test context for DnD tests: which surface the pick
    /// returns (drag enter/motion routing + the S-F5 grab_serial mint
    /// need a pick that answers).
    pick_state: PickState = .{},
    pick_fn: *const fn (ctx: *anyopaque, x: i32, y: i32) ?seat_mod.Seat.PickResult = testPick,

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
        // The seat's hit-test callback (DnD tests: drag enter/motion
        // routing + the S-F5 grab_serial mint need a pick that answers).
        ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);

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

    /// Roundtrip for both clients. The two client flushes and the poll
    /// loop are this harness's own — they are per-client and tolerate a
    /// client that has not connected yet (initAtVersion connects B with
    /// only client A live) and one dropped by a protocol error. The
    /// server half is the shared helper, called with a null client so it
    /// does not re-flush: it must run only after every live client has
    /// flushed (utils/test_pump.zig).
    fn pump(ts: *TestServer) !void {
        if (ts.c_display) |d| {
            if (d.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        if (ts.c_display_b) |d| {
            if (d.flush() != .SUCCESS) return error.ClientFlushFailed;
        }
        try test_pump.roundtrip(null, ts.display.?, 0);
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

test "a data device bound by the focused client receives the current selection at bind time" {
    // wlroots sends the current selection at bind time when the binding
    // client is the focused one (data_device_manager_get_data_device ->
    // device_resource_send_selection, wlr_data_device.c:247-251; KWin
    // seat.cpp:159-177).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device_a = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    try ts.pump();

    // Focus A and give the seat a live selection.
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client.?));
    try ts.pump();
    device_a.setSelection(src, ts.seat.?.last_serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);

    // B takes the focus: A's offer is superseded with the focus and B
    // has no data device yet, so nothing is delivered.
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client_b.?));
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);

    // B binds its device while focused: the current selection arrives
    // with no focus change after it.
    const device_b = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    var dev_b_events: DeviceEvents = .{};
    device_b.setListener(*DeviceEvents, DeviceEvents.listener, &dev_b_events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), dev_b_events.selection_count);
    try testing.expect(!dev_b_events.last_selection_null);
    // One live offer per focused client.
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
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
    /// DnD routing counters (F-SEL-1 drag over a target surface).
    data_offer_count: usize = 0,
    enter_count: usize = 0,
    motion_count: usize = 0,
    leave_count: usize = 0,
    drop_count: usize = 0,
    /// Enters that carried a NULL wl_data_offer — the signature of a
    /// source-less drag (wayland.xml:938-941, :1010-1011).
    enter_null_offer_count: usize = 0,
    /// The offer of the most recent enter (the drag offer the target
    /// accepts/negotiates on).
    last_offer_id: ?*client.wl.DataOffer = null,
    /// The offer proxy a listener was last registered on (ids are
    /// reused after inerting; register once per proxy).
    listened_offer: ?*client.wl.DataOffer = null,

    fn listener(device: *client.wl.DataDevice, event: client.wl.DataDevice.Event, data: *FocusEvents) void {
        _ = device;
        switch (event) {
            .selection => |e| {
                data.selection_count += 1;
                data.last_selection_null = e.id == null;
            },
            .data_offer => |e| {
                data.data_offer_count += 1;
                // The server inerts (frees the id of) the old drag offer
                // on leave; libwayland reuses freed ids, so a later drag
                // offer can arrive on a proxy that already has a
                // listener. addDispatcher asserts on double-registration,
                // so register once per proxy.
                const offer: ?*client.wl.DataOffer = e.id;
                if (offer) |o| {
                    if (data.listened_offer != offer) {
                        o.setListener(*FocusEvents, FocusEvents.offerListener, data);
                        data.listened_offer = o;
                    }
                }
            },
            .enter => |e| {
                data.enter_count += 1;
                if (e.id) |offer| {
                    data.last_offer_id = offer;
                } else {
                    // enter with no wl_data_offer (wayland.xml:1010-1011
                    // allows a null id): a source-less drag, where no
                    // data passes through the compositor at all
                    // (wayland.xml:938-941).
                    data.enter_null_offer_count += 1;
                }
            },
            .leave => data.leave_count += 1,
            .motion => data.motion_count += 1,
            .drop => data.drop_count += 1,
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
    // DD-3: start_drag finalizes the source (wlroots
    // wlr_data_device.c:82-85). F-SEL-1: with the DnD state machine the
    // drag runs for real — a valid grab serial installs the pointer
    // grab and the source is NOT cancelled.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    try ts.pump();

    // A valid drag origin: the pointer presses over the origin surface
    // (minting grab_serial), then start_drag validates against it.
    const origin = surfaceForClient(ts, ts.client.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    try testing.expectEqual(@as(u32, 1), ts.seat.?.pressed_count);
    const serial = ts.seat.?.last_serial;

    device.startDrag(src, ts.surface.?, null, serial);
    try ts.pump();
    try testing.expect(ts.mgr.?.sources.items[0].finalized);
    try testing.expect(ts.mgr.?.drag != null);
    // The real drag does NOT cancel the source.
    try testing.expectEqual(@as(usize, 0), src_events.cancelled_count);

    const DndAction = client.wl.DataDeviceManager.DndAction;
    src.setActions(@as(DndAction, @bitCast(@as(u32, 1))));
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
    try std.testing.expectEqual(@as(c_int, 0), wl_display_get_protocol_error(ts.c_display.?, null, null));
}

test "start_drag with a stale serial installs no drag and keeps the source" {
    // F-SEL-1: the origin check (S-F5 grab_serial) rejects a drag whose
    // serial was never minted for a held button — no grab, no offer,
    // and the source stays finalized-but-alive (wlroots denies the
    // drag, wlr_data_device.c:47-87).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    try ts.pump();

    const origin = surfaceForClient(ts, ts.client.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    const serial = ts.seat.?.last_serial;
    // Release the button: the grab_serial window closes (pressed_count
    // 0), so the echo of the press serial no longer validates.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();

    device.startDrag(src, ts.surface.?, null, serial);
    try ts.pump();
    try testing.expect(ts.mgr.?.sources.items[0].finalized);
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
    try testing.expectEqual(@as(usize, 0), src_events.cancelled_count);
}

test "drag enter/motion/leave/drop routes to the target's data device (F-SEL-1)" {
    // The observable DnD contract: a drag over client B's surface
    // delivers enter (with the offer + mimes), motion, then leave when
    // the pointer leaves; releasing the origin button over an accepted
    // target with a negotiated action drops.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Client A starts the drag; client B is the drop target.
    const device_a = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const device_b = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var events_b: FocusEvents = .{};
    device_b.setListener(*FocusEvents, FocusEvents.listener, &events_b);
    try ts.pump();

    // Press over A's surface (origin): mints grab_serial.
    const origin = surfaceForClient(ts, ts.client.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    const serial = ts.seat.?.last_serial;

    // The source advertises copy BEFORE the drag (set_actions after
    // start_drag is a protocol error); the target negotiates it.
    src.setActions(@bitCast(@as(u32, 1)));
    device_a.startDrag(src, ts.surface.?, null, serial);
    try ts.pump();
    try testing.expect(ts.mgr.?.drag != null);

    // Move over B's surface: enter with the offer + mimes.
    const target = surfaceForClient(ts, ts.client_b.?);
    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.enter_count);
    try testing.expectEqual(@as(usize, 1), events_b.mime_count);
    try testing.expect(events_b.has_text_plain);
    try testing.expectEqual(@as(?*DataOffer, ts.mgr.?.drag.?.offer), ts.mgr.?.drag.?.offer);

    // Motion within the target: motion events.
    ts.seat.?.pointerMotion(55, 65);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.motion_count);

    // Leave the target (pick null): leave, offer destroyed.
    ts.pick_state.surface = null;
    ts.seat.?.pointerMotion(200, 200);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.leave_count);

    // Back over the target + accept + actions + release the origin
    // button: the drop runs (drop_performed + drop + finished).
    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), events_b.enter_count);
    // The target accepts and negotiates copy (the source already
    // advertised copy before the drag).
    const offer = events_b.last_offer_id.?;
    offer.setActions(@bitCast(@as(u32, 1)), @bitCast(@as(u32, 1)));
    offer.accept(0, "text/plain");
    try ts.pump();
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.drop_count);
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
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
    // DD-2: white-box negotiation over a drag offer. The protocol path
    // creates drag offers too (dragSetFocus); this test uses the shorter
    // selection-offer route and flips its type so the negotiation can be
    // driven without a second client. The negotiated action goes to both
    // the destination (wl_data_offer.action) and the source
    // (wl_data_source.action), version-guarded (v3 offers here).
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
    try testing.expectEqual(@as(u32, 1), ts.mgr.?.devices.items[0].eventResource().?.getVersion());
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
    try testing.expectEqual(@as(u32, 3), ts.mgr.?.devices.items[0].eventResource().?.getVersion());
}

test "selection offer carries source_actions after the mime events, before selection" {
    // F-SEL-2: wayland.xml mandates wl_data_offer.source_actions
    // "immediately after creating the wl_data_offer object"
    // (wayland.xml:710-719). The emission sits between the per-mime
    // offer events and the selection event, v3+ only. A clipboard
    // source carries mask 0: its actions were never set, and the KWin
    // invalid_source gate rejects action-advertising sources at
    // set_selection anyway.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var seq: SourceActionsSequence = .{};
    device.setListener(*SourceActionsSequence, SourceActionsSequence.deviceListener, &seq);
    try ts.pump();
    const serial = focusAndMintSerial(ts);

    device.setSelection(src, serial);
    try ts.pump();

    // Exactly one source_actions event on the delivered offer, value 0
    // for a clipboard source.
    try testing.expectEqual(@as(usize, 1), seq.source_actions_count);
    try testing.expectEqual(@as(u32, 0), seq.last_source_actions);
    // Delivery order: the focus delivery's selection(NULL) first, then
    // mime offer (0), source_actions (1), selection (2).
    try testing.expectEqual(@as(usize, 4), seq.kind_count);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 1, 2 }, seq.kinds[0..seq.kind_count]);
}

test "offer source_actions payload reflects the source's action mask (white-box)" {
    // F-SEL-2 white-box: the emission line reads src.actions — set a
    // real mask on the source and deliver, asserting the payload
    // bitcasts to it. Mirrors the drag simulation (the offer is flipped
    // to a drag offer, as the future F-SEL-1 drag-offer creation would
    // create it): the wire set_actions on a source that then went
    // through set_selection would trip the KWin invalid_source gate, so
    // the selection is placed white-box instead.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    const DndAction = client.wl.DataDeviceManager.DndAction;
    src.setActions(@as(DndAction, @bitCast(@as(u32, 1 | 2)))); // copy | move
    var seq: SourceActionsSequence = .{};
    device.setListener(*SourceActionsSequence, SourceActionsSequence.deviceListener, &seq);
    try ts.pump();
    try testing.expectEqual(@as(?u32, 3), ts.mgr.?.sources.items[0].actions);

    // White-box: place the source as the seat-wide selection (bypasses
    // the KWin invalid_source gate) and deliver via the keyboard focus,
    // then flip the offer to a drag offer like the drag negotiation
    // test does.
    ts.mgr.?.selection_source = ts.mgr.?.sources.items[0];
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client.?));
    try ts.pump();
    ts.mgr.?.offers.items[0].offer_type = .drag;

    // Exactly one source_actions event, the payload bitcast to the mask.
    try testing.expectEqual(@as(usize, 1), seq.source_actions_count);
    try testing.expectEqual(@as(u32, 3), seq.last_source_actions);
    // Delivery order: mime offer (0), source_actions (1), selection (2).
    try testing.expectEqual(@as(usize, 3), seq.kind_count);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, seq.kinds[0..seq.kind_count]);
}

test "pre-v3 offers receive no source_actions event" {
    // F-SEL-2 version guard: the source_actions event is since-3; a v2
    // device's offer must not carry it (a since-3 event against a client
    // that never agreed to v3 would be a wire violation).
    const allocator = testing.allocator;
    var ts = try TestServer.initAtVersion(allocator, 2);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var seq: SourceActionsSequence = .{};
    device.setListener(*SourceActionsSequence, SourceActionsSequence.deviceListener, &seq);
    try ts.pump();
    const serial = focusAndMintSerial(ts);

    device.setSelection(src, serial);
    try ts.pump();

    try testing.expectEqual(@as(usize, 0), seq.source_actions_count);
    // The offer delivery still carries the mime and the selection.
    try testing.expectEqualSlices(u8, &.{ 2, 0, 2 }, seq.kinds[0..seq.kind_count]);
}

test "a cancelled source is inert: re-passing it clears the selection" {
    // F-SEL-3: a replaced selection's source is cancelled AND inerted —
    // the struct is freed and the wire resource's requests become no-ops
    // (wlroots nulls the source resource's user data on cancel,
    // client_data_source_destroy, wlr_data_source.c:114-120). Re-passing
    // the cancelled source to set_selection behaves exactly like passing
    // NULL: the selection is cleared, the current owner is cancelled,
    // no crash on the freed struct.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src_a = try ts.wl_data_device_manager.?.createDataSource();
    const src_b = try ts.wl_data_device_manager.?.createDataSource();
    var events_a: SourceEvents = .{};
    src_a.setListener(*SourceEvents, SourceEvents.listener, &events_a);
    var events_b: SourceEvents = .{};
    src_b.setListener(*SourceEvents, SourceEvents.listener, &events_b);
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);
    try ts.pump();
    const serial = focusAndMintSerial(ts);

    device.setSelection(src_a, serial);
    try ts.pump();
    try testing.expectEqual(src_a.getId(), ts.mgr.?.selection_source.?.resource.getId());

    // Replacing with B cancels A and inerts it: the struct is freed and
    // unlinked from the manager's source list.
    device.setSelection(src_b, serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_a.cancelled_count);
    try testing.expectEqual(src_b.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items.len);

    // Re-passing the cancelled source with a valid serial behaves like
    // NULL: the selection is cleared (selection(NULL) to the focused
    // client), the current owner is cancelled, and no offer remains.
    device.setSelection(src_a, serial);
    try ts.pump();
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);
    try testing.expect(dev_events.last_selection_null);
    try testing.expectEqual(@as(usize, 1), events_b.cancelled_count);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.sources.items.len);
}

test "re-setting the current selection source updates the serial only" {
    // F-SEL-4: wlroots wlr_seat_set_selection early-returns when the
    // incoming source is already the selection, updating only
    // selection_serial (wlr_data_device.c:184-189) — no cancel, no
    // re-delivery round-trip.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);
    try ts.pump();
    const serial1 = focusAndMintSerial(ts);

    device.setSelection(src, serial1);
    try ts.pump();
    try testing.expectEqual(serial1, ts.mgr.?.selection_serial);
    const selection_count = dev_events.selection_count;

    // A second serial handed to the same client: a key event to the
    // focused client mints one (re-focusing the same surface is a no-op
    // in Seat.setKeyboardFocus).
    ts.seat.?.keyEvent(38, true); // 'a'
    ts.seat.?.keyEvent(38, false);
    const serial2 = ts.seat.?.last_serial;
    try testing.expect(serial2 != serial1);

    // Re-set the same source: serial advanced, no re-delivery, no
    // cancel, the live offer untouched.
    device.setSelection(src, serial2);
    try ts.pump();
    try testing.expectEqual(serial2, ts.mgr.?.selection_serial);
    try testing.expectEqual(selection_count, dev_events.selection_count);
    try testing.expectEqual(@as(usize, 0), src_events.cancelled_count);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
}

test "get_data_device with an inert seat yields a dead device" {
    // F-SEL-5: the seat argument must map to a live seat (the XA-5
    // pattern, xdg_activation.zig:369-380). An inert seat still yields
    // a device resource — the client's object id must stay valid — but
    // the device is dead: no struct, no list entry, every request a
    // no-op (wlroots creates the resource with NULL user data when the
    // seat client is NULL, wlr_data_device.c:238-244).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Inert the server-side wl_seat resource (the XA-5 recipe,
    // xdg_activation.zig:1003-1006).
    const seat_res = ts.client.?.getObject(ts.wl_seat.?.getId()).?;
    seat_res.setDispatcher(null, null, null, null);

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    var dev_events: DeviceEvents = .{};
    device.setListener(*DeviceEvents, DeviceEvents.listener, &dev_events);
    try ts.pump();

    // The inert path wires a dead handler without appending to the
    // manager's device list.
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.devices.items.len);

    // set_selection on the dead device is a silent no-op: nothing is
    // stored, nothing is delivered, no protocol error, no crash. The
    // source stays unfinalized (the request never reaches the gates).
    device.setSelection(src, focusAndMintSerial(ts));
    try ts.pump();
    try testing.expectEqual(@as(?*DataSource, null), ts.mgr.?.selection_source);
    try testing.expectEqual(@as(usize, 0), dev_events.selection_count);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items.len);
    try testing.expect(!ts.mgr.?.sources.items[0].finalized);

    // release on the dead device works (the object id stays valid).
    device.release();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.devices.items.len);
}

test "a keyboard focus change during a drag keeps the drag offer alive" {
    // P0-1: Seat.pointerButton moves keyboard focus BEFORE it hands the
    // button to the pointer grab (seat.zig:974-992 then :1014-1016), so a
    // second button press mid-drag emits keyboard_focus and re-delivers
    // the selection. Only SELECTION offers may be superseded by that: a
    // drag offer belongs to the in-flight drag (wlroots keeps
    // seat->selection_offers and seat->drag_offers apart,
    // wlr_data_offer.c:264-271). Before the fix the sweep freed the live
    // drag offer and the next Drag.end destroyed it a second time.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device_a = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const device_b = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var events_b: FocusEvents = .{};
    device_b.setListener(*FocusEvents, FocusEvents.listener, &events_b);
    try ts.pump();

    // Press over A's surface (origin): mints grab_serial.
    const origin = surfaceForClient(ts, ts.client.?);
    const target = surfaceForClient(ts, ts.client_b.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    device_a.startDrag(src, ts.surface.?, null, ts.seat.?.last_serial);
    try ts.pump();
    try testing.expect(ts.mgr.?.drag != null);

    // Move over B: the drag offer is delivered and tracked.
    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.enter_count);
    const drag_offer = ts.mgr.?.drag.?.offer.?;
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);

    // Press a second button over the target: click-to-focus moves the
    // keyboard focus, the focus listener re-delivers the (empty)
    // selection, and the drag offer must come out the other side alive.
    ts.seat.?.pointerButton(seat_mod.btn_right, true);
    try ts.pump();
    try testing.expectEqual(surfaceForClient(ts, ts.client_b.?), ts.seat.?.keyboard_focus.?);
    try testing.expect(ts.mgr.?.drag != null);
    try testing.expectEqual(drag_offer, ts.mgr.?.drag.?.offer.?);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    try testing.expect(drag_offer.source != null);

    // The drag ends afterwards: the offer is destroyed exactly once (the
    // test allocator reports a double free).
    ts.seat.?.pointerButton(seat_mod.btn_right, false);
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);
}

test "a dropped drag offer whose source client exits refuses receive" {
    // P0-2: Drag.end keeps the dropped offer for the transfer and clears
    // mgr.drag, so when the source client's wl_data_source dies there is
    // no drag left to destroy that offer — sourceDestroy's sweep is the
    // only thing that keeps the target from reading freed source memory
    // (wlroots data_offer_handle_source_destroy, wlr_data_offer.c:230-237,
    // :273-274). Before the fix the surviving offer dangled.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device_a = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const device_b = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var src_events: SourceEvents = .{};
    src.setListener(*SourceEvents, SourceEvents.listener, &src_events);
    var events_b: FocusEvents = .{};
    device_b.setListener(*FocusEvents, FocusEvents.listener, &events_b);
    try ts.pump();

    const origin = surfaceForClient(ts, ts.client.?);
    const target = surfaceForClient(ts, ts.client_b.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    const serial = ts.seat.?.last_serial;
    src.setActions(@bitCast(@as(u32, 1)));
    device_a.startDrag(src, ts.surface.?, null, serial);
    try ts.pump();

    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    const offer = events_b.last_offer_id.?;
    offer.setActions(@bitCast(@as(u32, 1)), @bitCast(@as(u32, 1)));
    offer.accept(0, "text/plain");
    try ts.pump();

    // Release over the accepted target: the drop runs, and the offer is
    // KEPT for the transfer while the drag itself is gone.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.drop_count);
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    const srv_offer = ts.mgr.?.offers.items[0];
    try testing.expectEqual(OfferType.drag, srv_offer.offer_type);
    try testing.expect(srv_offer.source != null);

    // The source client exits: its wl_data_source dies with it.
    ts.c_display.?.disconnect();
    ts.client.?.destroy();
    ts.client = null;
    ts.c_display = null;
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.sources.items.len);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    try testing.expectEqual(@as(?*DataSource, null), srv_offer.source);

    // The dead offer refuses the transfer rather than reading freed
    // source memory: wl_data_offer.error.invalid_offer ("offer doesn't
    // accept this request", wayland.xml:588-589) kills the target, and
    // nothing was relayed to the source.
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    offer.receive("text/plain", fds[0]);
    try testing.expectError(error.ClientDispatchFailed, ts.pump());
    _ = std.os.linux.close(fds[0]);
    _ = std.os.linux.close(fds[1]);
    try testing.expectEqual(@as(usize, 0), src_events.send_count);
}

test "a second get_data_device binds to the client's existing device" {
    // P2-10: one device per client. The protocol has no object aliasing,
    // so the duplicate object id exists, but it is the SAME device: one
    // manager entry, events on the first object, and both objects running
    // the same request logic (managerRequest, DataDevice.objects).
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device_b1 = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const device_b2 = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    var dev1_events: DeviceEvents = .{};
    device_b1.setListener(*DeviceEvents, DeviceEvents.listener, &dev1_events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items.len);
    try testing.expectEqual(device_b1.getId(), ts.mgr.?.devices.items[0].eventResource().?.getId());
    try testing.expectEqual(@as(usize, 2), ts.mgr.?.devices.items[0].objects.items.len);

    // The duplicate object is the same device: a set_selection through it
    // is the seat's selection, delivered ONCE, on the first object. The
    // source has to be B's own — a Wayland object id names an object on
    // the connection that created it, so libwayland refuses to marshal
    // another client's object into this request.
    const src = try ts.wl_data_device_manager_b.?.createDataSource();
    src.offer("text/plain");
    try ts.pump();
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client_b.?));
    try ts.pump();
    device_b2.setSelection(src, ts.seat.?.last_serial);
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 2), dev1_events.selection_count); // focus NULL + the selection

    // Releasing the duplicate takes down one wire object only: the device,
    // its event resource and the stored selection all survive.
    device_b2.release();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items.len);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items[0].objects.items.len);
    try testing.expectEqual(device_b1.getId(), ts.mgr.?.devices.items[0].eventResource().?.getId());
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());

    // The remaining object still drives the seat: a new selection goes
    // out on it, on the same device the released duplicate belonged to.
    const src2 = try ts.wl_data_device_manager_b.?.createDataSource();
    src2.offer("text/plain");
    try ts.pump();
    device_b1.setSelection(src2, ts.seat.?.last_serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 3), dev1_events.selection_count);
    try testing.expectEqual(src2.getId(), ts.mgr.?.selection_source.?.resource.getId());

    // Releasing the last object takes the device out and frees it.
    device_b1.release();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.devices.items.len);
}

test "a released first device object hands the device to its duplicate" {
    // wl_data_device has no destroy request: an object dies when the
    // client releases it (wlroots data_device_release ->
    // wl_resource_destroy, wlr_data_device.c:89-92), on a protocol error,
    // or with the client. When the object the events go out on dies first
    // the duplicate takes over, exactly as wlroots only unlinks the dead
    // object's link and leaves the rest of seat_client->data_devices
    // live (data_device_handle_resource_destroy, wlr_data_device.c:
    // 100-103) — a client that still holds an object must keep receiving
    // the selection rather than lose it to a freed resource.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device_b1 = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const device_b2 = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    var dev1_events: DeviceEvents = .{};
    var dev2_events: DeviceEvents = .{};
    device_b1.setListener(*DeviceEvents, DeviceEvents.listener, &dev1_events);
    device_b2.setListener(*DeviceEvents, DeviceEvents.listener, &dev2_events);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items.len);

    // Focus lands on B while the first object is still the event object.
    ts.seat.?.setKeyboardFocus(surfaceForClient(ts, ts.client_b.?));
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), dev1_events.selection_count);
    try testing.expectEqual(@as(usize, 0), dev2_events.selection_count);

    // The first object goes away with the duplicate still bound: the
    // device lives on and now speaks through the duplicate.
    device_b1.release();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items.len);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items[0].objects.items.len);
    try testing.expectEqual(device_b2.getId(), ts.mgr.?.devices.items[0].eventResource().?.getId());

    // A selection set through the promoted object is delivered on it.
    const src = try ts.wl_data_device_manager_b.?.createDataSource();
    src.offer("text/plain");
    try ts.pump();
    device_b2.setSelection(src, ts.seat.?.last_serial);
    try ts.pump();
    try testing.expectEqual(src.getId(), ts.mgr.?.selection_source.?.resource.getId());
    try testing.expectEqual(@as(usize, 1), dev2_events.selection_count);
    try testing.expect(!dev2_events.last_selection_null);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    // The dead object never receives anything again.
    try testing.expectEqual(@as(usize, 1), dev1_events.selection_count);

    // The last object goes: the device is unlinked and freed.
    device_b2.release();
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.devices.items.len);
}

test "a client with two data devices receives one offer for one drag" {
    // P2-10: with a single tracked Drag.offer, a second device used to
    // orphan the first offer in mgr.offers and double every drag event.
    // One device per client makes the delivery exactly-once.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device_a = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const device_b1 = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const device_b2 = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    var events_b: FocusEvents = .{};
    device_b1.setListener(*FocusEvents, FocusEvents.listener, &events_b);
    try ts.pump();
    // A's device plus B's one device.
    try testing.expectEqual(@as(usize, 2), ts.mgr.?.devices.items.len);

    const origin = surfaceForClient(ts, ts.client.?);
    const target = surfaceForClient(ts, ts.client_b.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    const serial = ts.seat.?.last_serial;
    src.setActions(@bitCast(@as(u32, 1)));
    device_a.startDrag(src, ts.surface.?, null, serial);
    try ts.pump();

    // One drag, one target: exactly one data_offer + enter, even though
    // the target bound two device objects.
    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.data_offer_count);
    try testing.expectEqual(@as(usize, 1), events_b.enter_count);
    try testing.expectEqual(@as(usize, 1), events_b.mime_count);

    // ... and exactly one drop, with one offer left for the transfer.
    const offer = events_b.last_offer_id.?;
    offer.setActions(@bitCast(@as(u32, 1)), @bitCast(@as(u32, 1)));
    offer.accept(0, "text/plain");
    try ts.pump();
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.drop_count);
    try testing.expectEqual(@as(usize, 1), events_b.leave_count);
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);

    // The duplicate object really was a second get_data_device call on
    // B's manager: releasing it takes down that wire object only, the
    // device and the transferred offer stay.
    device_b2.release();
    try ts.pump();
    try testing.expectEqual(@as(usize, 2), ts.mgr.?.devices.items.len);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
}

test "a failed offer allocation leaks neither the wl_data_offer nor its struct" {
    // P2-11: both out-of-memory paths in createOffer must tear down what
    // they already built. The test allocator turns a leak into a failure
    // at TestServer.deinit.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    _ = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    _ = try ts.wl_data_device_manager.?.createDataSource();
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.devices.items.len);
    const srv_device = ts.mgr.?.devices.items[0];
    const srv_source = ts.mgr.?.sources.items[0];
    const srv_resource = srv_device.eventResource().?;

    // The DataOffer allocation fails: the wl_data_offer resource dies and
    // nothing is linked.
    var fail_create: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 0 });
    try testing.expect(
        createOffer(ts.mgr.?, fail_create.allocator(), srv_resource, srv_source, .drag) == null,
    );
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);

    // The mgr.offers append fails: offerDestroy frees the struct through
    // the resource it is installed on.
    var fail_append: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 1 });
    try testing.expect(
        createOffer(ts.mgr.?, fail_append.allocator(), srv_resource, srv_source, .drag) == null,
    );
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);

    // The manager's own allocator still produces a working offer, and the
    // test allocator reports nothing leaked at deinit.
    const offer = createOffer(ts.mgr.?, ts.mgr.?.allocator, srv_resource, srv_source, .selection).?;
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    try testing.expectEqual(srv_resource.getClient(), offer.resource.getClient());
}

test "the drag icon surface takes the drag-icon role and is readable while the drag lives" {
    // The icon is not decoration: wlroots claims it with
    // drag_icon_surface_role (wlr_data_device.c:65-72, wlr_drag.c:411-415)
    // and the scene sync draws it, so currentDragIcon must hand out the
    // live surface for exactly the drag's lifetime.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    const icon = try ts.wl_compositor.?.createSurface();
    try ts.pump();

    // No drag yet: no icon.
    try testing.expectEqual(@as(?*surface_mod.Surface, null), ts.mgr.?.currentDragIcon());

    const origin = surfaceForClient(ts, ts.client.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    device.startDrag(src, ts.surface.?, icon, ts.seat.?.last_serial);
    try ts.pump();
    try testing.expect(ts.mgr.?.drag != null);

    // The icon surface is A's second surface (surfaceForClient returns
    // the first) and it carries the drag-icon role.
    var icon_surface: ?*surface_mod.Surface = null;
    for (ts.compositor.?.surfaces.items) |s| {
        if (s == origin) continue;
        icon_surface = s;
    }
    try testing.expectEqual(icon_surface, ts.mgr.?.currentDragIcon());
    try testing.expect(ts.mgr.?.currentDragIcon().?.role.? == &drag_icon_role);

    // The drag ends: the icon goes with it.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
    try testing.expectEqual(@as(?*surface_mod.Surface, null), ts.mgr.?.currentDragIcon());
}

test "start_drag with a NULL source drives a source-less drag to the initiator only" {
    // wayland.xml:965 — start_drag's source is allow-null — and
    // wayland.xml:938-941 defines what a NULL source means: "If source
    // is NULL, enter, leave and motion events are sent only to the
    // client that initiated the drag and the client is expected to
    // handle the data passing internally." A conforming client may
    // therefore send start_drag(NULL, ...) with a button held; the
    // compositor must run that drag, not abort on it.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    // Client A initiates the drag; client B is a bystander target.
    const device_a = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const device_b = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    var events_a: FocusEvents = .{};
    device_a.setListener(*FocusEvents, FocusEvents.listener, &events_a);
    var events_b: FocusEvents = .{};
    device_b.setListener(*FocusEvents, FocusEvents.listener, &events_b);
    try ts.pump();

    // A valid drag origin: the press over A's own surface mints the
    // grab serial start_drag validates against (F-SEL-1).
    const origin = surfaceForClient(ts, ts.client.?);
    const target = surfaceForClient(ts, ts.client_b.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    const serial = ts.seat.?.last_serial;

    device_a.startDrag(null, ts.surface.?, null, serial);
    try ts.pump();
    // The drag runs with no source: no crash, the pointer grab is
    // installed, and the initiator is recorded for the event routing.
    const drag = ts.mgr.?.drag.?;
    try testing.expectEqual(@as(?*DataSource, null), drag.source);
    try testing.expectEqual(ts.client.?, drag.initiator);

    // Over B's surface: B is not the initiating client, so B sees
    // NOTHING — no enter, no motion, no leave, no wl_data_offer.
    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), events_b.enter_count);
    try testing.expectEqual(@as(usize, 0), events_b.motion_count);
    try testing.expectEqual(@as(usize, 0), events_b.leave_count);
    try testing.expectEqual(@as(usize, 0), events_b.data_offer_count);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);

    // Back over A's own surface: A is the initiating client, so it
    // gets enter — with a NULL offer, since no data passes through the
    // compositor (wayland.xml:938-941, :1010-1011).
    ts.pick_state.surface = origin;
    ts.seat.?.pointerMotion(10, 10);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_a.enter_count);
    try testing.expectEqual(@as(usize, 1), events_a.enter_null_offer_count);
    try testing.expectEqual(@as(usize, 0), events_a.data_offer_count);

    // Motion within A's surface reaches A.
    ts.seat.?.pointerMotion(12, 12);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_a.motion_count);

    // Leaving A's surface leaves A, and still tells B nothing.
    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_a.leave_count);
    try testing.expectEqual(@as(usize, 0), events_b.enter_count);
    try testing.expectEqual(@as(usize, 0), events_b.leave_count);

    // Releasing the origin button ends the drag. There is no source to
    // negotiate with and nobody to drop on, so no drop event goes out
    // and the drag is simply gone.
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), events_b.drop_count);
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
    try testing.expectEqual(@as(usize, 0), ts.mgr.?.offers.items.len);

    // The compositor survived it: a real, source-backed drag still
    // enters B with an offer afterwards.
    const src = try ts.wl_data_device_manager.?.createDataSource();
    src.offer("text/plain");
    src.setActions(@bitCast(@as(u32, 1)));
    ts.pick_state.surface = origin;
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    device_a.startDrag(src, ts.surface.?, null, ts.seat.?.last_serial);
    try ts.pump();
    try testing.expect(ts.mgr.?.drag.?.source != null);

    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_b.enter_count);
    try testing.expectEqual(@as(usize, 1), events_b.data_offer_count);
    try testing.expectEqual(@as(usize, 0), events_b.enter_null_offer_count);
    try testing.expect(events_b.last_offer_id != null);

    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
}

test "start_drag on a cancelled source runs a source-less drag" {
    // F-SEL-3 meets start_drag: cancelSource frees the source struct and
    // nulls its resource user data (wlroots nulls it on cancel,
    // wlr_data_source.c:114-120), and wlroots reads that user data
    // directly (wlr_data_device.c:49-52) — so start_drag on a cancelled
    // source is the protocol's source-less drag (wayland.xml:938-941),
    // never a dereference of the freed struct.
    const allocator = testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const device_a = try ts.wl_data_device_manager.?.getDataDevice(ts.wl_seat.?);
    const device_b = try ts.wl_data_device_manager_b.?.getDataDevice(ts.wl_seat_b.?);
    const src_a = try ts.wl_data_device_manager.?.createDataSource();
    const src_b = try ts.wl_data_device_manager.?.createDataSource();
    var events_a: SourceEvents = .{};
    src_a.setListener(*SourceEvents, SourceEvents.listener, &events_a);
    var drag_events_b: FocusEvents = .{};
    device_b.setListener(*FocusEvents, FocusEvents.listener, &drag_events_b);
    try ts.pump();

    const origin = surfaceForClient(ts, ts.client.?);
    const target = surfaceForClient(ts, ts.client_b.?);
    ts.pick_state.surface = origin;
    ts.seat.?.setPick(ts.pick_fn, &ts.pick_state);
    ts.seat.?.pointerMotion(10, 10);
    ts.seat.?.pointerButton(seat_mod.btn_left, true);
    try ts.pump();
    const serial = ts.seat.?.last_serial;

    // Replacing the selection cancels and inerts src_a.
    device_a.setSelection(src_a, serial);
    try ts.pump();
    device_a.setSelection(src_b, serial);
    try ts.pump();
    try testing.expectEqual(@as(usize, 1), events_a.cancelled_count);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.sources.items.len);

    // start_drag on the inert source: a source-less drag, no crash.
    device_a.startDrag(src_a, ts.surface.?, null, serial);
    try ts.pump();
    const drag = ts.mgr.?.drag.?;
    try testing.expectEqual(@as(?*DataSource, null), drag.source);
    try testing.expectEqual(ts.client.?, drag.initiator);
    try testing.expectEqual(@as(?*DataOffer, null), ts.mgr.?.drag.?.offer);
    // The only live offer is the clipboard one src_b's selection
    // delivered: the source-less drag created none.
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
    // The inert resource's requests are no-ops: no second cancelled.
    try testing.expectEqual(@as(usize, 1), events_a.cancelled_count);

    // The source-less routing holds: B is not the initiator.
    ts.pick_state.surface = target;
    ts.seat.?.pointerMotion(50, 60);
    try ts.pump();
    try testing.expectEqual(@as(usize, 0), drag_events_b.enter_count);
    try testing.expectEqual(@as(usize, 0), drag_events_b.data_offer_count);

    ts.pick_state.surface = origin;
    ts.seat.?.pointerMotion(10, 10);
    try ts.pump();
    ts.seat.?.pointerButton(seat_mod.btn_left, false);
    try ts.pump();
    try testing.expectEqual(@as(?*Drag, null), ts.mgr.?.drag);
    try testing.expectEqual(@as(usize, 1), ts.mgr.?.offers.items.len);
}
