//! wp_cursor_shape_manager_v1 (staging/cursor-shape-v1): the enumerated
//! alternative to wl_pointer.set_cursor — "set this device's cursor to
//! shape N" instead of "use this wl_surface as the cursor".
//!
//! Scope: the manager global and the per-device
//! wp_cursor_shape_device_v1 objects, for both kinds of device the protocol
//! names: a wl_pointer (get_pointer, version 1) and a zwp_tablet_tool_v2
//! (get_tablet_tool_v2, version 2, cursor-shape-v1.xml:54-63).
//!
//! THE SERIAL HANDSHAKE. wp_cursor_shape_device_v1 has NO events at all —
//! neither in the vendored protocols/wayland-protocols/staging/cursor-shape/
//! cursor-shape-v1.xml nor in upstream
//! gitlab.freedesktop.org/wayland/wayland-protocols `main`
//! (common.wp.cursor_shape_device_v1 in the generated bindings has
//! `event_count = 0`). There is no `shape`, no `enter_serial` and no
//! `leave` event to send; the ack of a successful set_shape is implicit.
//! The whole handshake is therefore the serial validation the XML states in
//! set_shape: "The serial parameter must match the latest wl_pointer.enter
//! or zwp_tablet_tool_v2.proximity_in serial number sent to the client.
//! Otherwise the request will be ignored." (cursor-shape-v1.xml:156-159).
//! This module tracks that serial per device:
//! - a pointer device gets it from `enterPointer` / loses it on
//!   `leavePointer`, which the server wiring calls from the same place it
//!   sends wl_pointer.enter / wl_pointer.leave (compositor/seat.zig:1573-1622);
//! - a tablet-tool device resolves it live from shell/tablet.zig, whose
//!   proximity_in serial it is — no duplicated bookkeeping, and the device
//!   goes inert by itself when the tool leaves proximity or is unplugged
//!   ("When the zwp_tablet_tool_v2 is removed, the wp_cursor_shape_device_v1
//!   object becomes inert", cursor-shape-v1.xml:59-61).
//!
//! Version gating. The interface is at version 2. get_tablet_tool_v2 exists
//! only from version 2, but zig-wayland emits `since = 1` for XML requests
//! that merely inherit the interface version, so libwayland does NOT reject
//! it on a v1 client and the server must. The XML declares no error enum on
//! wp_cursor_shape_manager_v1, so the rejection uses libwayland's own
//! `wl_display.error.invalid_method` (wayland.xml:93-94, "method doesn't
//! exist on the specified interface or malformed request") — the same code
//! wl_closure_invoke raises for a version-mismatched method
//! (wayland-server.c, wl_closure_invoke). The two v2-only shapes,
//! `dnd_ask` (35) and `all_resize` (36) (cursor-shape-v1.xml:113-117), are
//! rejected on a v1 device with wp_cursor_shape_device_v1.error
//! invalid_shape, mirroring wlroots' version-aware
//! wp_cursor_shape_device_v1_shape_is_valid check
//! (types/wlr_cursor_shape_v1.c:51-55).
//!
//! DIVERGENCE — a shape the compositor cannot draw. This compositor renders
//! exactly one cursor image (compositor/cursor.zig draws a fixed
//! cursor_size sprite for the pointer; there is no per-shape artwork). A
//! client that sets, say, .ew_resize therefore gets:
//! - no protocol error and no reply of any kind (set_shape has no reply);
//! - its request recorded: `device.shape` and `shapeOf()` report it, and
//!   `events.shape_changed` fires so the server can react;
//! - but the same single image on screen, because the renderer has no art
//!   for that shape. `isDrawableShape` is the honest predicate: it answers
//!   "will this compositor actually paint a different image for this
//!   shape?", and the cursor module keeps its default sprite for every
//!   shape it answers false for.
//! In other words the client observes exactly the same wire behaviour it
//! would observe against a compositor that did draw the shape; it cannot
//! tell from the protocol that the image did not change. That is inherent
//! to cursor-shape-v1: it has no acknowledgement to compare against.
//!
//! Imports: utils/*, core/wire.zig, core/display.zig and shell/tablet.zig
//! for the tablet tool registry. No seat, surface or renderer dependency:
//! this module owns protocol state only, so it is correct with no seats, no
//! outputs and no client attached, and it never dereferences a wl_surface.

const std = @import("std");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const display_mod = @import("../core/display.zig");
const tablet_mod = @import("./tablet.zig");

const log_tag = "cursor_shape";

/// wp_cursor_shape_manager_v1 version this library implements.
pub const cursor_shape_manager_version: u32 = 2;

/// wp_cursor_shape_device_v1.shape.
pub const Shape = server.wp.CursorShapeDeviceV1.Shape;

/// The lowest shape value introduced by cursor-shape v2.
/// cursor-shape-v1.xml marks exactly two shapes `since="2"`:
/// `dnd_ask` = 35 and `all_resize` = 36 (XML:113-117); everything below is
/// valid from version 1.
const first_v2_shape: c_int = 35;

/// The input device a wp_cursor_shape_device_v1 was created for
/// (cursor-shape-v1.xml:42-63).
pub const DeviceKind = union(enum) {
    /// A wl_pointer of this server's wl_seat. Its serial comes from
    /// wl_pointer.enter and is dropped on wl_pointer.leave.
    pointer: *server.wl.Pointer,
    /// A zwp_tablet_tool_v2 of shell/tablet.zig. Its serial is that
    /// module's zwp_tablet_tool_v2.proximity_in serial.
    tablet_tool: *server.zwp.TabletToolV2,
};

/// What the server observes when a set_shape is accepted. Emitted through
/// `CursorShape.events.shape_changed` after `DeviceState.shape` is updated.
pub const ShapeChange = struct {
    device: *DeviceState,
    kind: DeviceKind,
    shape: Shape,
    /// The enter / proximity_in serial the request matched.
    serial: u32,
};

/// Per-device state. Owned by its wp_cursor_shape_device_v1 resource: the
/// resource's destroy handler frees it (wlroots
/// device_handle_resource_destroy, types/wlr_cursor_shape_v1.c:78-81).
pub const DeviceState = struct {
    cs: *CursorShape,
    res: *server.wp.CursorShapeDeviceV1,
    kind: DeviceKind,
    /// The shape the client last set, or null while unset (the state a
    /// freshly created device is in — nothing has been requested yet).
    shape: ?Shape = null,
    /// wl_pointer.enter serial for a pointer device; null when the pointer
    /// is not focused on a surface. Always null for a tablet-tool device:
    /// that serial belongs to shell/tablet.zig and is resolved per request.
    pointer_serial: ?u32 = null,
};

pub const CursorShape = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The tablet module whose zwp_tablet_tool_v2 objects get_tablet_tool_v2
    /// accepts. Null when the server runs without tablets: a tablet-tool
    /// device is then created but never resolves a serial, so every
    /// set_shape on it is ignored (correctly inert).
    tablet: ?*tablet_mod.Tablet,
    /// The wp_cursor_shape_manager_v1 global, for teardown.
    global: ?*wire.Global = null,
    /// Live wp_cursor_shape_device_v1 objects, for teardown.
    devices: std.ArrayList(*DeviceState) = .empty,
    events: struct {
        /// A set_shape was accepted: the device's shape changed to
        /// `change.shape`. The server decides whether it can draw it (see
        /// the module docs: this compositor draws one cursor image for
        /// every shape).
        shape_changed: wire.Signal(*ShapeChange),
    },

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
        tablet: ?*tablet_mod.Tablet,
    ) !*CursorShape {
        const cs = try allocator.create(CursorShape);
        errdefer allocator.destroy(cs);
        cs.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .tablet = tablet,
            // SAFETY: shape_changed.init() runs before init() returns and
            // before any device can emit on it.
            .events = undefined,
        };
        errdefer cs.devices.deinit(allocator);
        cs.events.shape_changed.init();
        cs.global = try display.addGlobal(
            server.wp.CursorShapeManagerV1,
            *CursorShape,
            cursorShapeBind,
            cursor_shape_manager_version,
            cs,
        );
        log.debug("wp_cursor_shape_manager_v1 global created (v{d})", io, log_cfg, log_tag, .{cursor_shape_manager_version});
        return cs;
    }

    pub fn deinit(self: *CursorShape) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // The resource destroy handlers prune themselves from the list and
        // free their state.
        while (self.devices.items.len > 0) self.devices.items[0].res.destroy();
        self.devices.deinit(allocator);
        allocator.destroy(self);
    }

    // -- wiring the server calls ---------------------------------------------

    /// The wl_pointer was sent a wl_pointer.enter with `serial`: record it
    /// so a matching set_shape is accepted. The server wiring calls this
    /// where it sends the event (compositor/seat.zig:1581-1594).
    pub fn enterPointer(self: *CursorShape, pointer: *server.wl.Pointer, serial: u32) void {
        for (self.devices.items) |dev| {
            switch (dev.kind) {
                .pointer => |p| {
                    if (p == pointer) dev.pointer_serial = serial;
                },
                .tablet_tool => {},
            }
        }
    }

    /// The wl_pointer was sent a wl_pointer.leave: drop the serial. The
    /// device's shape is deliberately KEPT — leaving a surface does not
    /// reset the shape the client asked for, and cursor-shape-v1.xml:146-148
    /// says a new shape "replaces the previous cursor image (surface or
    /// shape)", not that losing focus resets it. With no serial, every
    /// later set_shape is ignored until the next enter.
    pub fn leavePointer(self: *CursorShape, pointer: *server.wl.Pointer) void {
        for (self.devices.items) |dev| {
            switch (dev.kind) {
                .pointer => |p| {
                    if (p == pointer) dev.pointer_serial = null;
                },
                .tablet_tool => {},
            }
        }
    }

    /// The shape the client last set on `device_res`, or null when unset.
    /// This is the compositor-side view the renderer consults; it is
    /// recorded whether or not the shape can actually be drawn.
    pub fn shapeOf(self: *CursorShape, device_res: *server.wp.CursorShapeDeviceV1) ?Shape {
        for (self.devices.items) |dev| {
            if (dev.res == device_res) return dev.shape;
        }
        return null;
    }

    /// The serial a set_shape must currently quote for `device`, or null
    /// when the device holds none (pointer out of focus, tablet tool out
    /// of proximity, or a tablet-tool device on a server without the
    /// tablet module).
    pub fn deviceSerial(self: *CursorShape, device: *DeviceState) ?u32 {
        switch (device.kind) {
            .pointer => return device.pointer_serial,
            .tablet_tool => |tool| {
                const tablet = self.tablet orelse return null;
                return tablet.toolCursorSerial(tool);
            },
        }
    }

    /// Whether this compositor actually paints a different image for
    /// `shape`. It draws exactly one cursor sprite
    /// (compositor/cursor.zig), so only the default shape has artwork; every
    /// other shape is recorded and acknowledged but drawn as that sprite.
    /// Exposed so the cursor module and the tests can state the divergence
    /// instead of pretending the shape was drawn.
    pub fn isDrawableShape(shape: Shape) bool {
        return shape == .default;
    }

    fn newDevice(
        self: *CursorShape,
        mgr: *server.wp.CursorShapeManagerV1,
        id: u32,
        kind: DeviceKind,
    ) void {
        const res = server.wp.CursorShapeDeviceV1.create(mgr.getClient(), mgr.getVersion(), id) catch {
            mgr.postNoMemory();
            return;
        };
        const dev = self.allocator.create(DeviceState) catch {
            res.destroy();
            mgr.postNoMemory();
            return;
        };
        dev.* = .{ .cs = self, .res = res, .kind = kind };
        self.devices.append(self.allocator, dev) catch {
            self.allocator.destroy(dev);
            res.destroy();
            mgr.postNoMemory();
            return;
        };
        // From here the resource owns dev: a failure above must never free
        // it twice.
        res.setHandler(*DeviceState, deviceRequest, deviceDestroy, dev);
        log.debug("cursor shape device@{d} for {s}", self.io, self.log_cfg, log_tag, .{ res.getId(), @tagName(kind) });
    }
};

/// Whether `shape` is a value a device of `version` may ask for: it must
/// be a declared enum entry, and not one of the two `since="2"` shapes on a
/// v1 device. wlroots does the same with its generated
/// wp_cursor_shape_device_v1_shape_is_valid(shape, version)
/// (types/wlr_cursor_shape_v1.c:51-55).
fn shapeValid(shape: Shape, version: u32) bool {
    // cursor-shape-v1.xml:137-140: "The 'shape' argument must be a valid
    // enum entry". zig-wayland closes the generated Shape enum with a bare
    // `_` field for the values a FUTURE protocol version adds, so an
    // undeclared wire value decodes to a tag with no name — it has no
    // `._` member to switch on, and `@intFromEnum` on it is not a
    // membership test. `tagName` returning null IS that membership test:
    // null for exactly the undeclared values, and it is the std-blessed
    // forward-compatible-enum probe (wlroots does the same by searching
    // its own generated shape table, types/wlr_cursor_shape_v1.c:51-55).
    if (std.enums.tagName(Shape, shape) == null) return false;
    // The remaining check is the interface version: dnd_ask = 35 and
    // all_resize = 36 are the only `since="2"` shapes
    // (cursor-shape-v1.xml:113-117).
    if (version < Shape.dnd_ask_since_version and @intFromEnum(shape) >= first_v2_shape) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Manager global
// ---------------------------------------------------------------------------

fn cursorShapeBind(client_wire: *wire.Client, cs: *CursorShape, version: u32, id: u32) void {
    log.debug("cursor shape bind v{d} id={d}", cs.io, cs.log_cfg, log_tag, .{ version, id });
    const res = server.wp.CursorShapeManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*CursorShape, managerRequest, null, cs);
}

fn managerRequest(
    res: *server.wp.CursorShapeManagerV1,
    request: server.wp.CursorShapeManagerV1.Request,
    cs: *CursorShape,
) void {
    switch (request) {
        .destroy => res.destroy(),
        .get_pointer => |r| cs.newDevice(res, r.cursor_shape_device, .{ .pointer = r.pointer }),
        .get_tablet_tool_v2 => |r| {
            // Version 2 addition (cursor-shape-v1.xml:54-63). zig-wayland
            // emits since = 1 for it, so a v1 client would otherwise be
            // served a request its interface version does not have.
            if (res.getVersion() < 2) {
                const raw: *wire.Resource = @ptrCast(res);
                raw.postError(
                    @intCast(@intFromEnum(server.wl.Display.Error.invalid_method)),
                    "wp_cursor_shape_manager_v1.get_tablet_tool_v2 requires version 2",
                );
                log.debug("cursor shape: rejected get_tablet_tool_v2 on a v{d} client", cs.io, cs.log_cfg, log_tag, .{
                    res.getVersion(),
                });
                return;
            }
            cs.newDevice(res, r.cursor_shape_device, .{ .tablet_tool = r.tablet_tool });
        },
    }
}

// ---------------------------------------------------------------------------
// Device object
// ---------------------------------------------------------------------------

fn deviceRequest(res: *server.wp.CursorShapeDeviceV1, request: server.wp.CursorShapeDeviceV1.Request, dev: *DeviceState) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_shape => |r| {
            const cs = dev.cs;
            const version = res.getVersion();
            if (!shapeValid(r.shape, version)) {
                // cursor-shape-v1.xml:137-140: "The 'shape' argument must be
                // a valid enum entry, otherwise the invalid_shape protocol
                // error is raised." This is checked BEFORE the serial: an
                // invalid enum value is a protocol error even when the
                // serial would have been ignored.
                res.postError(.invalid_shape, "shape value is not a valid wp_cursor_shape_device_v1.shape for this version");
                return;
            }
            // cursor-shape-v1.xml:156-159: the serial must match the latest
            // wl_pointer.enter / zwp_tablet_tool_v2.proximity_in serial.
            // Anything else is IGNORED — never a protocol error, exactly
            // like wl_pointer.set_cursor (compositor/seat.zig:1863-1866).
            const serial = cs.deviceSerial(dev) orelse {
                log.debug("cursor shape device@{d}: set_shape ignored, no enter/proximity_in serial held", cs.io, cs.log_cfg, log_tag, .{
                    res.getId(),
                });
                return;
            };
            if (serial != r.serial) {
                log.debug("cursor shape device@{d}: set_shape with stale serial {d}, ignored", cs.io, cs.log_cfg, log_tag, .{
                    res.getId(),
                    r.serial,
                });
                return;
            }
            dev.shape = r.shape;
            var change: ShapeChange = .{
                .device = dev,
                .kind = dev.kind,
                .shape = r.shape,
                .serial = r.serial,
            };
            cs.events.shape_changed.emit(&change);
            log.debug("cursor shape device@{d}: shape set to {s} (serial={d}, drawn={})", cs.io, cs.log_cfg, log_tag, .{
                res.getId(),
                @tagName(r.shape),
                r.serial,
                CursorShape.isDrawableShape(r.shape),
            });
        },
    }
}

fn deviceDestroy(_: *server.wp.CursorShapeDeviceV1, dev: *DeviceState) void {
    const cs = dev.cs;
    // indexOfScalar is the repo's list-membership probe (tearing_control.zig,
    // fractional_scale.zig); a local helper duplicating it is not worth its
    // own arity to keep in sync.
    if (std.mem.indexOfScalar(*DeviceState, cs.devices.items, dev)) |i| {
        _ = cs.devices.orderedRemove(i);
    }
    cs.allocator.destroy(dev);
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/tablet.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");
const seat_mod = @import("../compositor/seat.zig");
const surface_mod = @import("../compositor/surface.zig");

/// The shapes a test accepted, in order, with the serial each was accepted
/// for.
const ShapeLog = struct {
    allocator: std.mem.Allocator,
    shapes: std.ArrayList(Shape) = .empty,
    serials: std.ArrayList(u32) = .empty,
    listener: wire.Listener(*ShapeChange),

    fn init(allocator: std.mem.Allocator) ShapeLog {
        return .{
            .allocator = allocator,
            .listener = wire.Listener(*ShapeChange).init(notify),
        };
    }

    fn deinit(self: *ShapeLog) void {
        self.shapes.deinit(self.allocator);
        self.serials.deinit(self.allocator);
    }

    fn notify(listener: *wire.Listener(*ShapeChange), change: *ShapeChange) void {
        const self: *ShapeLog = @fieldParentPtr("listener", listener);
        // A signal handler may not fail: a capture that cannot grow
        // traps instead of silently dropping an accepted shape.
        self.shapes.append(self.allocator, change.shape) catch unreachable;
        self.serials.append(self.allocator, change.serial) catch unreachable;
    }
};

// ---------------------------------------------------------------------------
// Client-side protocol error
// ---------------------------------------------------------------------------

/// The protocol error a client connection ended with: a healthy session
/// reports 0, which is what every "no error was raised" assertion checks.
///
/// libwayland hands the wl_display proxy its own C dispatcher when the
/// display is created, and `wl_proxy_add_dispatcher` refuses to install a
/// second one (wayland-client.h:198-200; measured on libwayland 1.26.0,
/// where the call returns -1 for the display proxy and 0 for every other
/// one). A wl_display.error event therefore NEVER reaches a Zig listener,
/// and the generated setListener asserts on that -1 — a listener on the
/// display is not a bug to work around, it is a mechanism libwayland does
/// not offer. The code is read back through
/// `wl_display_get_protocol_error` (wayland-client-core.h:284-287), which
/// is not in the generated bindings, so the harness declares it. Note the
/// neighbouring `wl_display_get_error`, which zig-wayland does bind as
/// Display.getError(), reports the errno side of the failure (EPROTO for
/// any protocol error) and NOT the protocol error code. The error MESSAGE
/// is unreachable: libwayland-client logs it and keeps nothing else, so the
/// tests assert on the code plus what the connection did instead.
extern fn wl_display_get_protocol_error(
    display: *client.wl.Display,
    interface: ?*const ?*const client.wl.Interface,
    id: ?*u32,
) u32;

fn protocolErrorCode(display: *client.wl.Display) u32 {
    return wl_display_get_protocol_error(display, null, null);
}

/// Client-side capture of the tablet seat: keeps the first tool object the
/// compositor announces so a test can pass it to get_tablet_tool_v2.
const TabletTools = struct {
    tool: ?*client.zwp.TabletToolV2 = null,

    fn seat(_: *client.zwp.TabletSeatV2, event: client.zwp.TabletSeatV2.Event, self: *TabletTools) void {
        switch (event) {
            .tool_added => |e| self.tool = e.id,
            .tablet_added, .pad_added => {},
        }
    }
};

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,
    tablet_name: ?u32 = null,
    cursor_shape_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_seat")) {
                    data.seat_name = g.name;
                } else if (std.mem.eql(u8, name, "zwp_tablet_manager_v2")) {
                    data.tablet_name = g.name;
                } else if (std.mem.eql(u8, name, "wp_cursor_shape_manager_v1")) {
                    data.cursor_shape_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    tablet: ?*tablet_mod.Tablet = null,
    cursor_shape: ?*CursorShape = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_seat: ?*client.wl.Seat = null,
    tablet_manager: ?*client.zwp.TabletManagerV2 = null,
    shape_manager: ?*client.wp.CursorShapeManagerV1 = null,
    tablet_tools: TabletTools = .{},
    /// The server-side Surface created for a client wl_surface, so
    /// toolProximityIn has somewhere to focus.
    surface: ?*surface_mod.Surface = null,

    /// Heap-allocated: the `io` pointer must outlive the stack frame.
    /// `manager_version` is the wp_cursor_shape_manager_v1 version the test
    /// client binds.
    fn init(allocator: std.mem.Allocator, manager_version: u32) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        try ts.display.?.initShm();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();
        ts.tablet = try tablet_mod.Tablet.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.tablet) |t| t.deinit();
        ts.cursor_shape = try CursorShape.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, ts.tablet.?);
        errdefer if (ts.cursor_shape) |cs| cs.deinit();

        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        const registry = try ts.c_display.?.getRegistry();
        var globals: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &globals);
        try ts.pump();
        if (globals.compositor_name == null or globals.seat_name == null or
            globals.tablet_name == null or globals.cursor_shape_name == null)
        {
            return error.GlobalMissing;
        }
        ts.wl_compositor = try registry.bind(globals.compositor_name.?, client.wl.Compositor, 7);
        ts.wl_seat = try registry.bind(globals.seat_name.?, client.wl.Seat, 7);
        ts.tablet_manager = try registry.bind(globals.tablet_name.?, client.zwp.TabletManagerV2, tablet_mod.tablet_v2_version);
        ts.shape_manager = try registry.bind(globals.cursor_shape_name.?, client.wp.CursorShapeManagerV1, manager_version);
        try ts.pump();
        return ts;
    }

    fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers must
        // run while both modules live.
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.cursor_shape) |cs| cs.deinit();
        if (ts.tablet) |t| t.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }

    /// The shared `test_pump.roundtrip` (client flush -> server dispatch ->
    /// server flush) plus a client dispatch, which runs only when the server
    /// actually wrote to the socket. Never blocks.
    fn pump(ts: *TestServer) !void {
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

    /// A client wl_surface and the compositor Surface behind it.
    fn makeSurface(ts: *TestServer) !struct { proxy: *client.wl.Surface, surface: *surface_mod.Surface } {
        const proxy = try ts.wl_compositor.?.createSurface();
        // The wl_surface resource only exists server-side once the request
        // has been flushed and dispatched.
        try ts.pump();
        for (ts.compositor.?.surfaces.items) |s| {
            if (s.resource.getId() == proxy.getId()) {
                ts.surface = s;
                return .{ .proxy = proxy, .surface = s };
            }
        }
        return error.SurfaceMissing;
    }

    /// get_pointer on the client's wl_pointer: the client proxy, the
    /// server-side device state, and the wl_pointer resource it names.
    fn getPointerDevice(ts: *TestServer) !struct {
        device: *client.wp.CursorShapeDeviceV1,
        state: *DeviceState,
        pointer: *server.wl.Pointer,
    } {
        const proxy = try ts.wl_seat.?.getPointer();
        try ts.pump();
        const pointer = ts.findPointerResource(proxy.getId()) orelse return error.PointerMissing;
        const device = try ts.shape_manager.?.getPointer(proxy);
        try ts.pump();
        return .{ .device = device, .state = ts.newestDevice(), .pointer = pointer };
    }

    /// The server-side wl_pointer resource for a client proxy id. Only the
    /// client and the server agree on WHICH object a given proxy is; the
    /// numeric ids live in separate namespaces.
    fn findPointerResource(ts: *TestServer, proxy_id: u32) ?*server.wl.Pointer {
        for (ts.seat.?.pointers.items) |ptr| {
            if (ptr.getId() == proxy_id) return ptr;
        }
        return null;
    }

    /// The device state created by the most recent get_pointer /
    /// get_tablet_tool_v2.
    fn newestDevice(ts: *TestServer) *DeviceState {
        const devices = ts.cursor_shape.?.devices.items;
        return devices[devices.len - 1];
    }

    /// get_tablet_tool_v2 for a zwp_tablet_tool_v2 the compositor announced.
    fn getToolDevice(ts: *TestServer) !struct {
        device: *client.wp.CursorShapeDeviceV1,
        state: *DeviceState,
    } {
        const tablet_seat = try ts.tablet_manager.?.getTabletSeat(ts.wl_seat.?);
        tablet_seat.setListener(*TabletTools, TabletTools.seat, &ts.tablet_tools);
        try ts.pump();
        const tool = ts.tablet_tools.tool orelse return error.ToolMissing;
        const device = try ts.shape_manager.?.getTabletToolV2(tool);
        try ts.pump();
        return .{ .device = device, .state = ts.newestDevice() };
    }

    /// The protocol error this connection died with, or 0 for a healthy one.
    /// Valid once dispatch has failed: libwayland only records the error
    /// when it decodes the error event.
    fn protocolError(ts: *TestServer) u32 {
        return protocolErrorCode(ts.c_display.?);
    }
};

test "pointer device: set_shape only applies on the wl_pointer.enter serial" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, cursor_shape_manager_version);
    defer ts.deinit();

    var accepted: ShapeLog = ShapeLog.init(allocator);
    defer accepted.deinit();
    ts.cursor_shape.?.events.shape_changed.add(&accepted.listener);

    const got = try ts.getPointerDevice();
    const cs = ts.cursor_shape.?;
    try std.testing.expectEqual(@as(usize, 1), cs.devices.items.len);
    // Nothing has been requested yet: the device's shape is unset.
    try std.testing.expectEqual(@as(?Shape, null), cs.shapeOf(got.state.res));

    // No enter yet: every set_shape is ignored, and never an error.
    got.device.setShape(1, .pointer);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), accepted.shapes.items.len);
    try std.testing.expectEqual(@as(?Shape, null), got.state.shape);

    // enter: the serial becomes valid.
    const enter_serial = ts.seat.?.serialFor(ts.client.?);
    cs.enterPointer(got.pointer, enter_serial);
    try std.testing.expectEqual(@as(?u32, enter_serial), got.state.pointer_serial);

    // A serial that is not the enter serial is ignored.
    got.device.setShape(enter_serial + 1, .text);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), accepted.shapes.items.len);

    // The enter serial applies and fires shape_changed.
    got.device.setShape(enter_serial, .text);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), accepted.shapes.items.len);
    try std.testing.expectEqual(Shape.text, accepted.shapes.items[0]);
    try std.testing.expectEqual(enter_serial, accepted.serials.items[0]);
    try std.testing.expectEqual(@as(?Shape, .text), cs.shapeOf(got.state.res));
    // This compositor draws one cursor image: the shape is recorded, not
    // drawn (the documented divergence).
    try std.testing.expect(!CursorShape.isDrawableShape(.text));

    // leave: the serial dies with the focus. The shape is kept, but no new
    // set_shape is accepted.
    cs.leavePointer(got.pointer);
    try std.testing.expectEqual(@as(?u32, null), got.state.pointer_serial);
    got.device.setShape(enter_serial, .grab);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), accepted.shapes.items.len);
    try std.testing.expectEqual(@as(?Shape, .text), got.state.shape);

    // A later enter restores the handshake with a fresh serial.
    const reenter = ts.seat.?.serialFor(ts.client.?);
    cs.enterPointer(got.pointer, reenter);
    got.device.setShape(reenter, .grab);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 2), accepted.shapes.items.len);
    try std.testing.expectEqual(Shape.grab, accepted.shapes.items[1]);
    // shapeOf is keyed by the SERVER resource; got.device is the client
    // proxy and lives in a different id namespace (see findPointerResource).
    try std.testing.expectEqual(@as(?Shape, .grab), cs.shapeOf(got.state.res));
    try std.testing.expectEqual(@as(u32, 0), ts.protocolError());

    // destroy frees the device; the module's list shrinks.
    got.device.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), cs.devices.items.len);
}

test "tablet tool device: the serial comes from the tablet module's proximity_in" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, cursor_shape_manager_version);
    defer ts.deinit();

    var accepted: ShapeLog = ShapeLog.init(allocator);
    defer accepted.deinit();
    ts.cursor_shape.?.events.shape_changed.add(&accepted.listener);

    const tablet_hw = try ts.tablet.?.addTablet(.{ .name = "intuos" });
    const tool_hw = try ts.tablet.?.addTool(.{ .tool_type = .pen });
    const made = try ts.makeSurface();
    const got = try ts.getToolDevice();

    const cs = ts.cursor_shape.?;
    const tool_res = tool_hw.clients.items[0].res;
    try std.testing.expectEqual(@as(?u32, null), cs.deviceSerial(got.state));

    // Out of proximity: no serial, so set_shape is ignored.
    got.device.setShape(1, .crosshair);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), accepted.shapes.items.len);

    const serial = ts.tablet.?.toolProximityIn(tool_res, tablet_hw.clients.items[0].res, made.surface).?;
    try ts.pump();
    try std.testing.expectEqual(serial, cs.deviceSerial(got.state));

    // A stale serial is ignored; the proximity_in serial applies.
    got.device.setShape(serial + 7, .crosshair);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), accepted.shapes.items.len);
    got.device.setShape(serial, .crosshair);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), accepted.shapes.items.len);
    try std.testing.expectEqual(Shape.crosshair, accepted.shapes.items[0]);
    try std.testing.expectEqual(@as(?Shape, .crosshair), cs.shapeOf(got.state.res));

    // proximity_out: the device goes inert by itself — no cursor_shape
    // bookkeeping is involved, the tablet module simply holds no serial.
    ts.tablet.?.toolProximityOut(tool_res);
    try ts.pump();
    try std.testing.expectEqual(@as(?u32, null), cs.deviceSerial(got.state));
    got.device.setShape(serial, .pointer);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), accepted.shapes.items.len);

    // Unplugging the tool removes it from the registry; the device survives
    // (the client owns it) and stays inert.
    ts.tablet.?.removeTool(tool_hw);
    try ts.pump();
    try std.testing.expectEqual(@as(?u32, null), cs.deviceSerial(got.state));
    got.device.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), cs.devices.items.len);
}

test "get_tablet_tool_v2 is rejected on a v1 client" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, 1);
    defer ts.deinit();

    _ = try ts.tablet.?.addTool(.{ .tool_type = .pen });
    try std.testing.expectError(error.ClientDispatchFailed, ts.getToolDevice());

    // wl_display.error.invalid_method is the XML's rejection for a method a
    // v1 interface does not have (wayland.xml:93-94). The request was
    // rejected, not served: no wp_cursor_shape_device_v1 exists for it.
    try std.testing.expectEqual(
        @as(u32, @intCast(@intFromEnum(server.wl.Display.Error.invalid_method))),
        ts.protocolError(),
    );
    try std.testing.expectEqual(@as(usize, 0), ts.cursor_shape.?.devices.items.len);
}

test "a v2-only shape raises invalid_shape on a v1 device and is accepted on a v2 one" {
    const allocator = std.testing.allocator;
    var ts2 = try TestServer.init(allocator, cursor_shape_manager_version);
    defer ts2.deinit();

    var accepted: ShapeLog = ShapeLog.init(allocator);
    defer accepted.deinit();
    ts2.cursor_shape.?.events.shape_changed.add(&accepted.listener);

    const got2 = try ts2.getPointerDevice();
    const serial2 = ts2.seat.?.serialFor(ts2.client.?);
    ts2.cursor_shape.?.enterPointer(got2.pointer, serial2);
    got2.device.setShape(serial2, .all_resize);
    try ts2.pump();
    try std.testing.expectEqual(@as(usize, 1), accepted.shapes.items.len);
    try std.testing.expectEqual(Shape.all_resize, accepted.shapes.items[0]);
    try std.testing.expectEqual(@as(u32, 0), ts2.protocolError());

    var ts1 = try TestServer.init(allocator, 1);
    defer ts1.deinit();
    var accepted1: ShapeLog = ShapeLog.init(allocator);
    defer accepted1.deinit();
    ts1.cursor_shape.?.events.shape_changed.add(&accepted1.listener);
    const got1 = try ts1.getPointerDevice();
    const serial1 = ts1.seat.?.serialFor(ts1.client.?);
    ts1.cursor_shape.?.enterPointer(got1.pointer, serial1);
    got1.device.setShape(serial1, .all_resize);
    try std.testing.expectError(error.ClientDispatchFailed, ts1.pump());
    try std.testing.expectEqual(@as(usize, 0), accepted1.shapes.items.len);
    try std.testing.expectEqual(
        @as(u32, @intFromEnum(server.wp.CursorShapeDeviceV1.Error.invalid_shape)),
        ts1.protocolError(),
    );
    // The shape was refused on the device the client already had: it is
    // still unset.
    try std.testing.expectEqual(@as(?Shape, null), ts1.cursor_shape.?.shapeOf(got1.state.res));
}

test "the default shape is the only one this compositor can actually draw" {
    try std.testing.expect(CursorShape.isDrawableShape(.default));
    try std.testing.expect(!CursorShape.isDrawableShape(.pointer));
    try std.testing.expect(!CursorShape.isDrawableShape(.not_allowed));
}
