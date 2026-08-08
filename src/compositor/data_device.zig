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
};

/// A data source (the client offering clipboard content).
const DataSource = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataSource,
    /// Mime types offered (data_source.offer events), sentinel-terminated
    /// (wl_data_offer.offer takes a C string).
    mime_types: std.ArrayList([:0]const u8),
};

/// A data offer delivered to a target client.
const DataOffer = struct {
    manager: *DataDeviceManager,
    resource: *server.wl.DataOffer,
    source: *DataSource,
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
    if (mgr.selection_source == src) {
        mgr.selection_source = null;
        src.resource.sendCancelled();
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
    // The selection is seat-wide: any client may be the owner, so read it
    // from the manager, not from the focused client's own device.
    const src = mgr.selection_source orelse return;
    for (mgr.devices.items) |dev| {
        if (dev.resource.getClient() != focus_client) continue;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const posix = std.posix;

const RegistryCapture = struct {
    seat_name: ?u32 = null,
    data_device_manager_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_seat")) {
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

/// A compositor + seat + data device manager + in-memory client, for wire
/// roundtrips of the selection flow.
const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    seat: ?*seat_mod.Seat = null,
    mgr: ?*DataDeviceManager = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_seat: ?*client.wl.Seat = null,
    wl_data_device_manager: ?*client.wl.DataDeviceManager = null,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, seat and manager all store it).
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
        if (capture.seat_name == null or capture.data_device_manager_name == null) return error.GlobalMissing;

        // Round 2: bind wl_seat and wl_data_device_manager.
        ts.wl_seat = try registry.bind(capture.seat_name.?, client.wl.Seat, 7);
        ts.wl_data_device_manager = try registry.bind(
            capture.data_device_manager_name.?,
            client.wl.DataDeviceManager,
            3,
        );
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers
        // (sourceDestroy/deviceDestroy) must run while the manager lives.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.mgr) |m| m.deinit();
        if (ts.seat) |s| s.deinit();
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
