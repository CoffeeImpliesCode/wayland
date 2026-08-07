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
//!   - data_source teardown (destroy/cancel) clears the stored selection.
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

const server = @import("protocol").server;

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
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        self.devices.deinit(allocator);
        allocator.destroy(self);
    }
};

/// A client's data device (one per client per seat).
const DataDevice = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataDevice,
    /// The current selection source, if set by this device.
    selection_source: ?*DataSource = null,
};

/// A data source (the client offering clipboard content).
const DataSource = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataSource,
    /// Mime types offered (data_source.offer events), sentinel-terminated
    /// (wl_data_offer.offer takes a C string).
    mime_types: std.ArrayList([:0]const u8),
    /// True while this source is the stored selection.
    selected: bool = false,
};

/// A data offer delivered to a target client.
const DataOffer = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataOffer,
    source: *DataSource,
};

fn bindManager(client: *wire.Client, mgr: *DataDeviceManager, version: u32, id: u32) void {
    const resource = server.wl.DataDeviceManager.create(client, version, id) catch {
        client.postNoMemory();
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
        .set_actions => {}, // tracked but unused in M3
        .destroy => src_res.destroy(),
    }
}

fn sourceDestroy(src_res: *server.wl.DataSource, src: *DataSource) void {
    _ = src_res;
    const mgr = src.manager;
    // If this source was the stored selection, clear it and cancel.
    for (mgr.devices.items) |dev| {
        if (dev.selection_source == src) {
            dev.selection_source = null;
            src.selected = false;
            break;
        }
    }
    if (src.selected) src.resource.sendCancelled();
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
            if (r.source) |src_res| {
                const src: *DataSource = @ptrCast(@alignCast(src_res.getUserData()));
                // A new selection: cancel the previous one.
                if (dev.selection_source) |old| {
                    if (old != src) old.resource.sendCancelled();
                    old.selected = false;
                }
                dev.selection_source = src;
                src.selected = true;
                log.debug("selection set with {d} mime types", mgr.io, mgr.log_cfg, "data_device", .{
                    src.mime_types.items.len,
                });
            } else {
                // Null source: clear the selection.
                if (dev.selection_source) |old| {
                    old.selected = false;
                    old.resource.sendCancelled();
                }
                dev.selection_source = null;
            }
            deliverSelectionToFocus(mgr);
        },
        .start_drag => |r| {
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
    if (dev.selection_source) |src| {
        src.selected = false;
        src.resource.sendCancelled();
    }
    const idx = std.mem.indexOfScalar(*DataDevice, mgr.devices.items, dev) orelse 0;
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

/// For the focused client's data device: create a fresh offer for the
/// stored selection and send offer/selection events.
fn deliverSelectionToFocus(mgr: *DataDeviceManager) void {
    const focus = mgr.seat.keyboard_focus orelse return;
    const focus_client = focus.resource.getClient();
    for (mgr.devices.items) |dev| {
        if (dev.resource.getClient() != focus_client) continue;
        const src = dev.selection_source orelse break;
        const offer_res = server.wl.DataOffer.create(focus_client, 3, 0) catch return;
        const offer = mgr.allocator.create(DataOffer) catch {
            offer_res.destroy();
            return;
        };
        offer.* = .{
            .manager = mgr,
            .resource = offer_res,
            .source = src,
        };
        offer_res.setHandler(*DataOffer, offerRequest, offerDestroy, offer);
        for (src.mime_types.items) |m| offer_res.sendOffer(m.ptr);
        dev.resource.sendDataOffer(offer_res);
        dev.resource.sendSelection(offer_res);
        log.debug("selection delivered to focused client ({d} mimes)", mgr.io, mgr.log_cfg, "data_device", .{
            src.mime_types.items.len,
        });
        break; // one device per client
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
            // payload into it, the target reads it.
            const src = offer.source;
            src.resource.sendSend(r.mime_type, r.fd);
            _ = std.os.linux.close(r.fd);
            log.debug("offer.receive relayed ({s})", offer.manager.io, offer.manager.log_cfg, "data_device", .{
                std.mem.span(r.mime_type),
            });
        },
        .destroy => offer_res.destroy(),
        .finish => {},
        .set_actions => |r| {
            _ = r;
            // Ignored in M3.
        },
    }
}

fn offerDestroy(offer_res: *server.wl.DataOffer, offer: *DataOffer) void {
    _ = offer_res;
    const allocator = offer.manager.allocator;
    allocator.destroy(offer);
}
