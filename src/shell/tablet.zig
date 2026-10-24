//! zwp_tablet_manager_v2 (stable/tablet-v2): graphics tablets, tablet tools
//! and tablet pads (a set of buttons, rings, strips and dials).
//!
//! Scope: the manager global, the per-client zwp_tablet_seat_v2, and every
//! object the compositor creates below it — zwp_tablet_v2,
//! zwp_tablet_tool_v2, zwp_tablet_pad_v2 and the pad tree
//! (zwp_tablet_pad_group_v2 with its rings, strips and dials). The client
//! creates NOTHING below the seat: the compositor owns every id and
//! announces each object with a capability burst terminated by that
//! interface's `done` (tablet-v2.xml:107-125, 133-182, 1064-1093,
//! 916-1063). The only client-created objects are the manager and the seat.
//!
//! Hardware model: the compositor owns a registry of physical tablets, tools
//! and pads (addTablet / addTool / addPad). A zwp_tablet_seat_v2 is a *view*
//! of that registry: get_tablet_seat announces the hardware registered so
//! far, in registration order, and later registrations are pushed to every
//! live seat (wlroots 0.20.2 get_or_create_tablet_seat + add_tablet_client,
//! types/tablet_v2/wlr_tablet_v2.c:66-200). The hardware comes from the
//! libinput backend: an evdev node with LIBINPUT_DEVICE_CAP_TABLET_TOOL is
//! registered as a zwp_tablet_v2, each tool it reports as a
//! zwp_tablet_tool_v2, and a node with LIBINPUT_DEVICE_CAP_TABLET_PAD as a
//! zwp_tablet_pad_v2 (src/backend/libinput.zig). With no tablet attached the
//! registry is empty and the only protocol-visible consequence is a
//! zwp_tablet_seat_v2 that stays silent, which is a state every real client
//! must already handle.
//!
//! Two levels of entry point, because the protocol is per client while an
//! input backend only knows hardware: proximity_in names one
//! zwp_tablet_tool_v2, one zwp_tablet_v2, one wl_surface and one serial
//! (XML:380-395), so the resource-level functions (toolProximityIn,
//! toolProximityOut, padEnter, padLeave) take a client's objects — which
//! this module owns and does not export. The *Hw functions fan one hardware
//! event out to every client object that hardware was announced to, pairing
//! the tool's and the tablet's object on the SAME seat; that is what
//! src/backend/libinput.zig calls, and what its tests drive.
//!
//! NOT sent here: the tool's axis and button events
//! (zwp_tablet_tool_v2.down/up/motion/pressure/distance/tilt/rotation/
//! slider/wheel/button/frame, XML:414-563), zwp_tablet_pad_v2.button
//! (XML:1185) and the ring/strip/dial axis events (XML:737-780, 851-895,
//! 1264-1290). The vendored protocol declares them and wlroots sends them,
//! but this module's surface is the announcement tree plus proximity and
//! pad focus, so a libinput axis/tip/button/pad-ring event has no home here
//! yet and the backend drops it.
//!
//! Burst ordering (tablet-v2.xml is the authority):
//! - zwp_tablet_v2 (XML:588-682): name?, id?, path*, bustype?(v2), done.
//!   wlroots sends the same order (types/tablet_v2/wlr_tablet_v2_tablet.c:
//!   106-118).
//! - zwp_tablet_tool_v2 (XML:275-358): type, hardware_serial?,
//!   hardware_id_wacom?, capability*, done. wlroots sends
//!   hardware_serial, hardware_id_wacom, type, capability*, done
//!   (wlr_tablet_v2_tool.c:141-158); the XML fixes neither a position nor
//!   an order inside the burst, so this module uses the declaration order.
//! - zwp_tablet_pad_v2 (XML:1129-1175): group+ — each immediately followed
//!   by that group's own complete burst — path?, buttons? (only when the
//!   pad has at least one button), done. wlroots sends buttons, path*,
//!   group+ (wlr_tablet_v2_pad.c:322-336). The XML constrains only that
//!   every group burst precedes zwp_tablet_pad_v2.done (XML:1086-1088),
//!   which both orders satisfy; this module follows the declaration order.
//! - zwp_tablet_pad_group_v2 (XML:948-1063): buttons FIRST (XML:951-963:
//!   "This event is first sent in the initial burst"), then ring*, strip*,
//!   modes (only when more than one mode exists, XML:1000-1001), dial*(v2),
//!   done. DIVERGENCE from wlroots: it sends `modes` before `buttons` and
//!   before any ring/strip (wlr_tablet_v2_pad.c:210-219); the XML says the
//!   opposite, so the XML wins here.
//!
//! Version gating: the seat resource inherits the bound manager version and
//! every object below it inherits the seat's, so a v1 client is never handed
//! a v2-only event. Two events are v2-only and are skipped for a v1 client
//! (the requests of this protocol have no v2-only member):
//! zwp_tablet_v2.bustype (XML:671) and zwp_tablet_pad_group_v2.dial
//! (XML:1052). The gate must be explicit: zig-wayland emits `since = 1` for
//! XML events that merely inherit the interface version, so libwayland does
//! not filter them for us.
//!
//! Removal: zwp_tablet_v2.removed (XML:648), zwp_tablet_tool_v2.removed
//! (XML:361) and zwp_tablet_pad_v2.removed (XML:1212) tell the client the
//! hardware is gone; the client then destroys the object and, for a pad,
//! every ring, strip and group it was offered (XML:1215-1217). The
//! compositor drops its hardware from the registry immediately and detaches
//! the client objects; their resources stay alive until the client destroys
//! them. Removal NEVER cascades from the server side — a client that sends
//! `destroy` for a server-destroyed id would get wl_display.error
//! invalid_object — so a dying pad only marks its groups parentless
//! (GroupClient.pad) and a dying group only marks its aux objects
//! parentless (AuxClient.group).
//!
//! Serials: this module mints its own serials from the display counter for
//! the events that carry one (proximity_in, pad enter/leave, mode_switch)
//! and remembers, per client object, the serial it most recently handed
//! out. zwp_tablet_tool_v2.set_cursor (XML:208) and the
//! wp_cursor_shape_device_v1 that shell/cursor_shape.zig builds on
//! zwp_tablet_tool_v2 (cursor-shape-v1.xml:54-63) both validate against the
//! proximity_in serial, not against the seat's pointer serial ring: the XML
//! names "serial of the proximity_in event" as the only valid value.
//! set_feedback validates against the most recent mode_switch serial of
//! the owning group (XML:1115-1121).
//!
//! Imports: utils/*, core/wire.zig, core/display.zig, compositor/role.zig +
//! compositor/surface.zig (the set_cursor cursor role). No seat, backend or
//! renderer dependency: this module owns protocol state only, so it is
//! correct with no seats, no outputs and no client attached.

const std = @import("std");
const log = @import("../utils/log.zig");
const test_pump = @import("../utils/test_pump.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const display_mod = @import("../core/display.zig");
const role_mod = @import("../compositor/role.zig");
const surface_mod = @import("../compositor/surface.zig");

const log_tag = "tablet";

/// zwp_tablet_manager_v2 version this library implements.
pub const tablet_v2_version: u32 = 2;

/// The cursor surface a tool shows while it is in proximity. A null surface
/// means "hide the cursor" (zwp_tablet_tool_v2.set_cursor with surface =
/// null, tablet-v2.xml:219-220).
pub const ToolCursor = struct {
    surface: ?*surface_mod.Surface = null,
    hotspot_x: i32 = 0,
    hotspot_y: i32 = 0,
};

// Empty descriptor defaults, declared once so the descriptor structs can
// default to them without repeating an `&.{}` coercion at every use site.
const no_paths: []const []const u8 = &.{};
const no_capabilities: []const server.zwp.TabletToolV2.Capability = &.{};
const no_group_buttons: []const u32 = &.{};
const no_groups: []const GroupDesc = &.{};

/// Physical tablet characteristics. The strings are borrowed: addTablet
/// copies what it keeps, so the caller keeps ownership of `desc`.
pub const TabletDesc = struct {
    /// zwp_tablet_v2.name. Skipped when null (XML:594-596).
    name: ?[]const u8 = null,
    /// zwp_tablet_v2.id. Skipped when `vid` is 0 (XML:606-608): a device
    /// with no vendor/product id sends no id event.
    vid: u32 = 0,
    pid: u32 = 0,
    /// zwp_tablet_v2.path, one event per entry, in order (XML:614-617).
    paths: []const []const u8 = no_paths,
    /// zwp_tablet_v2.bustype. Version 2 only (XML:671); never sent to a
    /// v1 client.
    bustype: ?server.zwp.TabletV2.Bustype = null,
};

/// Physical tool characteristics: one pen, eraser, finger, ...
pub const ToolDesc = struct {
    tool_type: server.zwp.TabletToolV2.Type,
    /// zwp_tablet_tool_v2.hardware_serial, split into hi/lo. Skipped when
    /// null (XML:286-299). A tool without a serial is tied to the first
    /// tablet it is used on.
    hardware_serial: ?u64 = null,
    /// zwp_tablet_tool_v2.hardware_id_wacom. Skipped when null (XML:308-318).
    hardware_id_wacom: ?u64 = null,
    /// zwp_tablet_tool_v2.capability, one event per entry (XML:340-344).
    capabilities: []const server.zwp.TabletToolV2.Capability = no_capabilities,
};

/// One zwp_tablet_pad_group_v2: the buttons, rings, strips and dials of a
/// positional (sub)set of the pad (XML:918-921).
pub const GroupDesc = struct {
    /// Button indices owned by this group; a button belongs to at most one
    /// group (XML:951-953). The event is sent even when empty, because a
    /// group whose buttons are all reserved by the compositor must still
    /// announce an empty array (XML:959-963).
    buttons: []const u32 = no_group_buttons,
    ring_count: u32 = 0,
    strip_count: u32 = 0,
    /// zwp_tablet_pad_group_v2.dial objects. Version 2 only (XML:1052): a
    /// v1 client is told about none of them, not even the count.
    dial_count: u32 = 0,
    /// zwp_tablet_pad_group_v2.modes. The `modes` event is sent only when
    /// this is greater than 1 (XML:1000-1001); mode 0 stays current until
    /// a mode_switch says otherwise.
    modes: u32 = 1,
};

/// Physical pad characteristics.
pub const PadDesc = struct {
    /// zwp_tablet_pad_v2.path. Skipped when null.
    path: ?[]const u8 = null,
    /// zwp_tablet_pad_v2.buttons. The event is sent only when this is at
    /// least 1 (XML:1168-1171).
    buttons: u32 = 0,
    /// At least one group is required: "all pads have at least one group"
    /// (XML:1083). A pad with no groups still gets a valid burst; the
    /// client sees only the pad's `done`.
    groups: []const GroupDesc = no_groups,
};

// ---------------------------------------------------------------------------
// Hardware registry objects
// ---------------------------------------------------------------------------

/// A physical tablet registered with the module. Created by
/// Tablet.addTablet, retired by Tablet.removeTablet.
pub const TabletHw = struct {
    manager: *Tablet,
    /// Owned NUL-terminated copies of the descriptor's strings. They
    /// outlive the burst because wl_resource_post_event reads them when it
    /// marshals.
    name: ?[:0]const u8 = null,
    paths: []const [:0]const u8 = &.{},
    desc: TabletDesc,
    /// Per-client zwp_tablet_v2 objects, in announce order.
    clients: std.ArrayList(*TabletClient) = .empty,

    fn announceTo(self: *TabletHw, seat: *SeatClient) !void {
        const allocator = self.manager.allocator;
        const res = try server.zwp.TabletV2.create(seat.res.getClient(), seat.res.getVersion(), 0);
        const tc = allocator.create(TabletClient) catch |err| {
            res.destroy();
            return err;
        };
        tc.* = .{ .manager = self.manager, .seat = seat, .hw = self, .res = res };
        self.clients.append(allocator, tc) catch |err| {
            allocator.destroy(tc);
            res.destroy();
            return err;
        };
        seat.tablets.append(allocator, tc) catch |err| {
            _ = self.clients.pop();
            allocator.destroy(tc);
            res.destroy();
            return err;
        };
        // From here the resource owns tc: a failure below must destroy the
        // resource, never the state a second time.
        res.setHandler(*TabletClient, tabletRequest, tabletDestroy, tc);
        seat.res.sendTabletAdded(res);
        sendTabletBurst(tc);
    }

    fn release(self: *TabletHw) void {
        const allocator = self.manager.allocator;
        if (self.name) |name| allocator.free(name);
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
        self.clients.deinit(allocator);
        allocator.destroy(self);
    }
};

/// A physical tablet tool registered with the module.
pub const ToolHw = struct {
    manager: *Tablet,
    desc: ToolDesc,
    clients: std.ArrayList(*ToolClient) = .empty,

    fn announceTo(self: *ToolHw, seat: *SeatClient) !void {
        const allocator = self.manager.allocator;
        const res = try server.zwp.TabletToolV2.create(seat.res.getClient(), seat.res.getVersion(), 0);
        const tc = allocator.create(ToolClient) catch |err| {
            res.destroy();
            return err;
        };
        tc.* = .{
            .manager = self.manager,
            .seat = seat,
            .hw = self,
            .res = res,
            .cursor_destroy_listener = detachedListener(*surface_mod.Surface, onCursorSurfaceDestroy),
        };
        self.clients.append(allocator, tc) catch |err| {
            allocator.destroy(tc);
            res.destroy();
            return err;
        };
        seat.tools.append(allocator, tc) catch |err| {
            _ = self.clients.pop();
            allocator.destroy(tc);
            res.destroy();
            return err;
        };
        // From here the resource owns tc.
        res.setHandler(*ToolClient, toolRequest, toolDestroy, tc);
        seat.res.sendToolAdded(res);
        sendToolBurst(tc);
    }

    fn release(self: *ToolHw) void {
        const allocator = self.manager.allocator;
        self.clients.deinit(allocator);
        allocator.destroy(self);
    }
};

/// A physical tablet pad registered with the module.
pub const PadHw = struct {
    manager: *Tablet,
    /// Owned NUL-terminated copy of `desc.path`, or null.
    path: ?[:0]const u8 = null,
    desc: PadDesc,
    clients: std.ArrayList(*PadClient) = .empty,

    fn announceTo(self: *PadHw, seat: *SeatClient) !void {
        const allocator = self.manager.allocator;
        const res = try server.zwp.TabletPadV2.create(seat.res.getClient(), seat.res.getVersion(), 0);
        const pc = allocator.create(PadClient) catch |err| {
            res.destroy();
            return err;
        };
        pc.* = .{
            .manager = self.manager,
            .seat = seat,
            .hw = self,
            .res = res,
            .focus_destroy_listener = detachedListener(*surface_mod.Surface, onFocusSurfaceDestroy),
        };
        self.clients.append(allocator, pc) catch |err| {
            allocator.destroy(pc);
            res.destroy();
            return err;
        };
        seat.pads.append(allocator, pc) catch |err| {
            _ = self.clients.pop();
            allocator.destroy(pc);
            res.destroy();
            return err;
        };
        // From here the resource owns pc.
        res.setHandler(*PadClient, padRequest, padDestroy, pc);
        seat.res.sendPadAdded(res);
        try sendPadBurst(pc);
    }

    fn release(self: *PadHw) void {
        const allocator = self.manager.allocator;
        if (self.path) |path| allocator.free(path);
        self.clients.deinit(allocator);
        allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Per-client objects
// ---------------------------------------------------------------------------

/// One client's zwp_tablet_seat_v2 and its own zwp_tablet_v2 /
/// zwp_tablet_tool_v2 / zwp_tablet_pad_v2 objects. `inert` marks a seat
/// created for a foreign wl_seat: the resource exists (the client's id is
/// allocated) but the seat announces nothing and holds no state, exactly
/// like wlroots' `if (seat == NULL) return` after
/// wl_resource_set_implementation (wlr_tablet_v2.c:150-154).
const SeatClient = struct {
    manager: *Tablet,
    res: *server.zwp.TabletSeatV2,
    /// The wl_seat this zwp_tablet_seat_v2 was created for; null when the
    /// argument was not a live seat of this server (see `inert`).
    wl_seat: ?*server.wl.Seat,
    inert: bool = false,
    tablets: std.ArrayList(*TabletClient) = .empty,
    tools: std.ArrayList(*ToolClient) = .empty,
    pads: std.ArrayList(*PadClient) = .empty,

    /// Announce the whole hardware registry, in the order the seat's own
    /// events are declared: tablet_added, tool_added, pad_added
    /// (XML:147-182).
    fn announceAll(self: *SeatClient) void {
        if (self.inert) return;
        for (self.manager.tablets.items) |hw| hw.announceTo(self) catch {
            self.manager.postOutOfMemory(self);
            return;
        };
        for (self.manager.tools.items) |hw| hw.announceTo(self) catch {
            self.manager.postOutOfMemory(self);
            return;
        };
        for (self.manager.pads.items) |hw| hw.announceTo(self) catch {
            self.manager.postOutOfMemory(self);
            return;
        };
    }
};

const TabletClient = struct {
    manager: *Tablet,
    seat: *SeatClient,
    /// Null after Tablet.removeTablet: the client still owns the resource
    /// (it must destroy it), but it no longer maps to hardware.
    hw: ?*TabletHw,
    res: *server.zwp.TabletV2,
};

const ToolClient = struct {
    manager: *Tablet,
    seat: *SeatClient,
    hw: ?*ToolHw,
    res: *server.zwp.TabletToolV2,
    /// Serial of the most recent zwp_tablet_tool_v2.proximity_in, or null
    /// while the tool is out of proximity. set_cursor and cursor-shape
    /// set_shape echo this value and are ignored otherwise (tablet-v2.xml:
    /// 215, cursor-shape-v1.xml:156-159).
    cursor_serial: ?u32 = null,
    /// The tool-specific cursor surface set by set_cursor.
    cursor: ToolCursor = .{},
    cursor_destroy_listener: wire.Listener(*surface_mod.Surface),
};

const PadClient = struct {
    manager: *Tablet,
    seat: *SeatClient,
    hw: ?*PadHw,
    res: *server.zwp.TabletPadV2,
    groups: std.ArrayList(*GroupClient) = .empty,
    /// The surface the pad currently has focus on, or null. A pad carries
    /// its own focus, independent of the seat's pointer focus
    /// (tablet-v2.xml:103-105).
    focus: ?*surface_mod.Surface = null,
    focus_destroy_listener: wire.Listener(*surface_mod.Surface),
};

/// Which auxiliary pad object a resource is, so the shared feedback path
/// and the prune-from-parent path can dispatch on it.
const AuxKind = enum { ring, strip, dial };

/// A zwp_tablet_pad_ring_v2 / _strip_v2 / _dial_v2 for one client. All
/// three carry only set_feedback plus destroy, so they share one state and
/// differ only in the typed request handler they need.
const AuxClient = struct {
    /// The module's allocator, kept here because the aux resource can
    /// outlive its group and must still free itself.
    allocator: std.mem.Allocator,
    /// Null once the owning group resource died first (the client may
    /// destroy the group and its rings in any order).
    group: ?*GroupClient,
    kind: AuxKind,
    res: *wire.Resource,
};

const GroupClient = struct {
    manager: *Tablet,
    /// Null once the pad resource died first; the group then outlives its
    /// parent and simply stops reporting feedback.
    pad: ?*PadClient,
    res: *server.zwp.TabletPadGroupV2,
    /// Backing store for the zwp_tablet_pad_group_v2.buttons event. The
    /// wire array points at it, so it must stay alive and unmutated until
    /// the event is marshalled (the seat has the same rule for its keys
    /// array, compositor/seat.zig:766-772). Nothing appends after the
    /// burst.
    buttons: std.ArrayList(u32) = .empty,
    rings: std.ArrayList(*AuxClient) = .empty,
    strips: std.ArrayList(*AuxClient) = .empty,
    dials: std.ArrayList(*AuxClient) = .empty,
    /// zwp_tablet_pad_group_v2.modes (1 for a single-mode group, in which
    /// case the `modes` event is skipped).
    modes: u32 = 1,
    /// The mode currently in effect, announced again by mode_switch after
    /// every zwp_tablet_pad_v2.enter (XML:1041-1044).
    mode: u32 = 0,
    /// Serial of the most recent zwp_tablet_pad_group_v2.mode_switch, or
    /// null when none was ever sent. Every set_feedback request of this
    /// group's buttons, rings, strips and dials must carry it (XML:715-719,
    /// 833-838, 1250-1256); anything else is ignored.
    mode_serial: ?u32 = null,
};

// ---------------------------------------------------------------------------
// The module
// ---------------------------------------------------------------------------

pub const Tablet = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The zwp_tablet_manager_v2 global, for teardown.
    global: ?*wire.Global = null,
    /// Live client zwp_tablet_seat_v2 objects.
    seats: std.ArrayList(*SeatClient) = .empty,
    /// Physical hardware, in registration order (which is also the
    /// announce order).
    tablets: std.ArrayList(*TabletHw) = .empty,
    tools: std.ArrayList(*ToolHw) = .empty,
    pads: std.ArrayList(*PadHw) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) !*Tablet {
        const tablet = try allocator.create(Tablet);
        errdefer allocator.destroy(tablet);
        tablet.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
        };
        errdefer tablet.seats.deinit(allocator);
        errdefer tablet.tablets.deinit(allocator);
        errdefer tablet.tools.deinit(allocator);
        errdefer tablet.pads.deinit(allocator);
        tablet.global = try display.addGlobal(
            server.zwp.TabletManagerV2,
            *Tablet,
            tabletBind,
            tablet_v2_version,
            tablet,
        );
        log.debug("zwp_tablet_manager_v2 global created (v{d})", io, log_cfg, log_tag, .{tablet_v2_version});
        return tablet;
    }

    pub fn deinit(self: *Tablet) void {
        const allocator = self.allocator;
        if (self.global) |global| global.remove();
        // Destroying the seat resources cascades: each seat destroys its
        // tablet, tool and pad resources, each of which frees its own
        // state and prunes itself from the hardware registry. When this
        // loop ends every hardware object's client list is empty, so
        // release() cannot leak and no event is sent during shutdown.
        // seatClientDestroy removes the seat from this very list, which is
        // what ends the loop.
        while (self.seats.items.len > 0) self.seats.items[0].res.destroy();
        self.seats.deinit(allocator);
        // release() DESTROYS the hardware object, so its entry has to
        // leave the registry first. A loop that kept re-reading items[0]
        // would walk the stale pointer and free the same TabletHw, its
        // name and its paths over and over — that double free was what
        // crashed every teardown that still had hardware registered.
        // pop() shortens the list first, so each object is released once.
        while (self.tablets.items.len > 0) self.tablets.pop().?.release();
        self.tablets.deinit(allocator);
        while (self.tools.items.len > 0) self.tools.pop().?.release();
        self.tools.deinit(allocator);
        while (self.pads.items.len > 0) self.pads.pop().?.release();
        self.pads.deinit(allocator);
        allocator.destroy(self);
    }

    /// A fresh serial from the display counter. Every serial-bearing event
    /// this module sends uses one, and the value is recorded on the client
    /// object so a matching request can be validated later.
    fn nextSerial(self: *Tablet) u32 {
        return self.display.nextSerial();
    }

    /// Tell the seat's client the compositor ran out of memory.
    ///
    /// `getClient().postNoMemory()` is `wl_client_post_no_memory`, which
    /// only WRITES the no_memory error: in libwayland 1.26 it is a tail
    /// call into `wl_resource_post_error` on the client's dummy
    /// resource, and `wl_resource_post_no_memory` is the same tail call.
    /// Neither destroys the client. The display's event loop does, on
    /// its next dispatch, once it sees the flagged client
    /// (wl_display_run's `if (client->error) wl_client_destroy`).
    ///
    /// Two consequences the announce paths rely on: a seat stays in
    /// `self.seats` for the rest of the current loop (so walking the
    /// live `items` slice cannot be invalidated from here), and a
    /// half-announced object keeps its state until the client's destroy
    /// handlers run — which is why the announce path never unwinds it.
    ///
    /// Do NOT substitute `resource.postNoMemory()` or a
    /// `wl_resource_destroy`: in this libwayland neither kills the
    /// client either, and only the destroy path frees the structs.
    fn postOutOfMemory(_: *Tablet, seat: *SeatClient) void {
        seat.res.getClient().postNoMemory();
    }

    // -- hardware registration ------------------------------------------------

    /// Register a physical tablet and announce it to every live seat
    /// (tablet_added + the full capability burst). The descriptor's
    /// strings are copied, so the caller keeps ownership of `desc`.
    /// The libinput backend calls this once per evdev node with
    /// LIBINPUT_DEVICE_CAP_TABLET_TOOL.
    pub fn addTablet(self: *Tablet, desc: TabletDesc) !*TabletHw {
        const allocator = self.allocator;
        const hw = try allocator.create(TabletHw);
        errdefer allocator.destroy(hw);
        hw.* = .{ .manager = self, .desc = desc };
        if (desc.name) |name| {
            hw.name = try allocator.dupeSentinel(u8, name, 0);
        }
        errdefer if (hw.name) |name| allocator.free(name);
        // TabletHw.paths is []const [:0]const u8, so its elements are
        // const: `|dst|` would capture a copy of that const slice into a
        // const temporary and `dst.* = ...` would assign to a constant.
        // Fill the freshly allocated array through its MUTABLE binding
        // and publish it to the field afterwards, so the copy stays
        // immutable for the object's lifetime (release, tablet.zig:221).
        // A descriptor with no paths keeps the comptime empty slice:
        // alloc(T, 0) hands back a block that free(_, 0) never gives back
        // (std.mem.Allocator.free returns early on a zero-length slice),
        // and the wire never sees a path event anyway (XML:614-617).
        var paths: []const [:0]const u8 = &.{};
        if (desc.paths.len != 0) {
            const buffer = try allocator.alloc([:0]const u8, desc.paths.len);
            paths = buffer;
            errdefer allocator.free(buffer);
            // Entries 0..copied-1 belong to THIS function until hw.paths is
            // published, so a dupeZ that fails halfway down the descriptor
            // has to hand back the copies already taken: the errdefer
            // above only knows about the array itself.
            var copied: usize = 0;
            errdefer for (buffer[0..copied]) |path| allocator.free(path);
            for (desc.paths) |src| {
                buffer[copied] = try allocator.dupeSentinel(u8, src, 0);
                copied += 1;
            }
        }
        hw.paths = paths;
        try self.tablets.append(allocator, hw);
        // The seat list cannot change under this loop: postOutOfMemory
        // only posts the error (see above), and nothing here dispatches
        // the client that would run seatClientDestroy.
        for (self.seats.items) |seat| hw.announceTo(seat) catch {
            self.postOutOfMemory(seat);
        };
        log.debug("tablet announced to {d} seat(s)", self.io, self.log_cfg, log_tag, .{self.seats.items.len});
        return hw;
    }

    /// Unplug a tablet: every client object gets zwp_tablet_v2.removed and
    /// is detached from the hardware, then the hardware is freed. The
    /// client destroys its resource (XML:653-654).
    pub fn removeTablet(self: *Tablet, hw: *TabletHw) void {
        for (hw.clients.items) |tc| {
            tc.hw = null;
            tc.res.sendRemoved();
        }
        const idx = indexOfPtr(*TabletHw, self.tablets.items, hw) orelse return;
        _ = self.tablets.orderedRemove(idx);
        hw.release();
        log.debug("tablet removed", self.io, self.log_cfg, log_tag, .{});
    }

    /// Register a physical tablet tool and announce it to every live seat
    /// (tool_added + the full capability burst).
    pub fn addTool(self: *Tablet, desc: ToolDesc) !*ToolHw {
        const allocator = self.allocator;
        const hw = try allocator.create(ToolHw);
        errdefer allocator.destroy(hw);
        hw.* = .{ .manager = self, .desc = desc };
        try self.tools.append(allocator, hw);
        for (self.seats.items) |seat| hw.announceTo(seat) catch {
            self.postOutOfMemory(seat);
        };
        log.debug("tablet tool announced to {d} seat(s)", self.io, self.log_cfg, log_tag, .{self.seats.items.len});
        return hw;
    }

    /// Unplug a tool. A tool that is in proximity gets proximity_out first
    /// (XML:361-369); then every client object gets removed.
    pub fn removeTool(self: *Tablet, hw: *ToolHw) void {
        for (hw.clients.items) |tc| {
            if (tc.cursor_serial != null) {
                tc.cursor_serial = null;
                clearToolCursor(tc);
                tc.res.sendProximityOut();
            }
            tc.hw = null;
            tc.res.sendRemoved();
        }
        const idx = indexOfPtr(*ToolHw, self.tools.items, hw) orelse return;
        _ = self.tools.orderedRemove(idx);
        hw.release();
        log.debug("tablet tool removed", self.io, self.log_cfg, log_tag, .{});
    }

    /// Register a physical pad and announce it to every live seat
    /// (pad_added + the pad/group/ring/strip/dial burst).
    pub fn addPad(self: *Tablet, desc: PadDesc) !*PadHw {
        const allocator = self.allocator;
        const hw = try allocator.create(PadHw);
        errdefer allocator.destroy(hw);
        hw.* = .{ .manager = self, .desc = desc };
        if (desc.path) |path| {
            hw.path = try allocator.dupeSentinel(u8, path, 0);
        }
        errdefer if (hw.path) |path| allocator.free(path);
        try self.pads.append(allocator, hw);
        for (self.seats.items) |seat| hw.announceTo(seat) catch {
            self.postOutOfMemory(seat);
        };
        log.debug("tablet pad announced to {d} seat(s)", self.io, self.log_cfg, log_tag, .{self.seats.items.len});
        return hw;
    }

    /// Unplug a pad: every client object gets zwp_tablet_pad_v2.removed and
    /// is detached. The client destroys the pad and the whole group tree it
    /// was offered (XML:1215-1217).
    pub fn removePad(self: *Tablet, hw: *PadHw) void {
        for (hw.clients.items) |pc| {
            detachFocus(pc);
            pc.hw = null;
            pc.res.sendRemoved();
        }
        const idx = indexOfPtr(*PadHw, self.pads.items, hw) orelse return;
        _ = self.pads.orderedRemove(idx);
        hw.release();
        log.debug("tablet pad removed", self.io, self.log_cfg, log_tag, .{});
    }

    // -- tool focus and cursor ------------------------------------------------

    /// Bring a tool into proximity of `tablet_res` over `surface` and hand
    /// the client the proximity_in serial. That serial is what
    /// zwp_tablet_tool_v2.set_cursor and a tablet-tool
    /// wp_cursor_shape_device_v1.set_shape must echo; a second call
    /// without an intervening proximity_out returns the live serial and
    /// sends nothing.
    pub fn toolProximityIn(
        self: *Tablet,
        tool_res: *server.zwp.TabletToolV2,
        tablet_res: *server.zwp.TabletV2,
        surface: *surface_mod.Surface,
    ) ?u32 {
        const tc = self.findTool(tool_res) orelse return null;
        if (tc.cursor_serial) |live| return live;
        const serial = self.nextSerial();
        tc.res.sendProximityIn(serial, tablet_res, surface.resource);
        tc.cursor_serial = serial;
        log.debug("tablet tool@{d} proximity_in serial={d}", self.io, self.log_cfg, log_tag, .{
            tool_res.getId(),
            serial,
        });
        return serial;
    }

    /// Take a tool out of proximity. Clears the tool's cursor surface and
    /// the recorded serial, so a later set_cursor/set_shape is ignored
    /// until the next proximity_in.
    pub fn toolProximityOut(self: *Tablet, tool_res: *server.zwp.TabletToolV2) void {
        const tc = self.findTool(tool_res) orelse return;
        if (tc.cursor_serial == null) return;
        tc.cursor_serial = null;
        clearToolCursor(tc);
        tc.res.sendProximityOut();
        log.debug("tablet tool@{d} proximity_out", self.io, self.log_cfg, log_tag, .{tool_res.getId()});
    }

    // -- hardware-level proximity ------------------------------------------

    /// The zwp_tablet_v2 object `hw` was announced to on `seat`, or null.
    /// A client that owns one of `tool`'s objects owns one of `hw`'s on
    /// the same seat too (announceTo appends to both lists), so this
    /// pairs objects of one client and never crosses clients.
    fn tabletClientOn(hw: *TabletHw, seat: *SeatClient) ?*TabletClient {
        for (hw.clients.items) |tc| {
            if (tc.seat == seat) return tc;
        }
        return null;
    }

    /// toolProximityIn for one hardware tool, on every client it was
    /// announced to: what an input backend calls when its pen comes into
    /// proximity (wlroots does the same fan-out in
    /// wlr_tablet_v2_tool_notify_proximity_in, types/tablet_v2/
    /// wlr_tablet_v2_tool.c).
    pub fn toolProximityInHw(
        self: *Tablet,
        tool: *ToolHw,
        tablet: *TabletHw,
        surface: *surface_mod.Surface,
    ) void {
        for (tool.clients.items) |tc| {
            const partner = tabletClientOn(tablet, tc.seat) orelse continue;
            _ = self.toolProximityIn(tc.res, partner.res, surface);
        }
    }

    /// toolProximityOut for one hardware tool, on every client it was
    /// announced to. A tool that never went in sends nothing: the
    /// per-client proximity serial is what gates it, exactly as for one
    /// client at a time (XML:397-412).
    pub fn toolProximityOutHw(self: *Tablet, tool: *ToolHw) void {
        for (tool.clients.items) |tc| self.toolProximityOut(tc.res);
    }

    /// The proximity_in serial this client currently holds for `tool_res`,
    /// or null when the tool is out of proximity or is not one of ours.
    /// This is the registry entry shell/cursor_shape.zig consumes: a
    /// wp_cursor_shape_device_v1 built on a zwp_tablet_tool_v2 validates
    /// set_shape against it (cursor-shape-v1.xml:156-159).
    pub fn toolCursorSerial(self: *Tablet, tool_res: *server.zwp.TabletToolV2) ?u32 {
        const tc = self.findTool(tool_res) orelse return null;
        return tc.cursor_serial;
    }

    /// The tool's current cursor surface and hotspot, or null when the
    /// client never called set_cursor or asked for the cursor to be
    /// hidden. The renderer reads this while the tool is in proximity.
    pub fn toolCursor(self: *Tablet, tool_res: *server.zwp.TabletToolV2) ?ToolCursor {
        const tc = self.findTool(tool_res) orelse return null;
        if (tc.cursor.surface == null) return null;
        return tc.cursor;
    }

    /// Locate the client object for one of our zwp_tablet_tool_v2
    /// resources. Scans the seats instead of casting the resource's user
    /// data, so a caller that passes a foreign resource can never make us
    /// dereference it as something else.
    fn findTool(self: *Tablet, tool_res: *server.zwp.TabletToolV2) ?*ToolClient {
        for (self.seats.items) |seat| {
            for (seat.tools.items) |tc| {
                if (tc.res == tool_res) return tc;
            }
        }
        return null;
    }

    // -- pad focus ------------------------------------------------------------

    /// Focus a pad on `surface`. Sends zwp_tablet_pad_v2.enter followed by
    /// one zwp_tablet_pad_group_v2.mode_switch per group, which the XML
    /// requires ("The compositor will also send this event after
    /// zwp_tablet_pad_v2.enter on each group in order to notify of the
    /// current mode", XML:1041-1044). `time` is the mode_switch time
    /// argument, in milliseconds.
    pub fn padEnter(
        self: *Tablet,
        pad_res: *server.zwp.TabletPadV2,
        tablet_res: *server.zwp.TabletV2,
        surface: *surface_mod.Surface,
        time: u32,
    ) void {
        const pc = self.findPad(pad_res) orelse return;
        const serial = self.nextSerial();
        attachFocus(pc, surface);
        pc.res.sendEnter(serial, tablet_res, surface.resource);
        for (pc.groups.items) |gc| {
            gc.mode_serial = serial;
            gc.res.sendModeSwitch(time, serial, gc.mode);
        }
        log.debug("tablet pad@{d} enter serial={d}", self.io, self.log_cfg, log_tag, .{
            pad_res.getId(),
            serial,
        });
    }

    /// Unfocus a pad: zwp_tablet_pad_v2.leave. The per-group mode serial
    /// is kept, so a set_feedback that follows the leave but quotes the
    /// last mode_switch still validates — the XML ties the serial to the
    /// mode, not to the focus.
    pub fn padLeave(
        self: *Tablet,
        pad_res: *server.zwp.TabletPadV2,
        surface: *surface_mod.Surface,
    ) void {
        const pc = self.findPad(pad_res) orelse return;
        const serial = self.nextSerial();
        pc.res.sendLeave(serial, surface.resource);
        detachFocus(pc);
        log.debug("tablet pad@{d} leave serial={d}", self.io, self.log_cfg, log_tag, .{
            pad_res.getId(),
            serial,
        });
    }

    // -- hardware-level pad focus ------------------------------------------

    /// padEnter for one hardware pad, on every client it was announced
    /// to. `time` is the mode_switch time argument in milliseconds, the
    /// same value padEnter takes per client.
    pub fn padEnterHw(
        self: *Tablet,
        pad: *PadHw,
        tablet: *TabletHw,
        surface: *surface_mod.Surface,
        time: u32,
    ) void {
        for (pad.clients.items) |pc| {
            const partner = tabletClientOn(tablet, pc.seat) orelse continue;
            self.padEnter(pc.res, partner.res, surface, time);
        }
    }

    /// padLeave for one hardware pad, on every client it was announced
    /// to. `surface` is the surface the pad is focused on, which the
    /// event names (XML:1203-1210).
    pub fn padLeaveHw(self: *Tablet, pad: *PadHw, surface: *surface_mod.Surface) void {
        for (pad.clients.items) |pc| self.padLeave(pc.res, surface);
    }

    fn findPad(self: *Tablet, pad_res: *server.zwp.TabletPadV2) ?*PadClient {
        for (self.seats.items) |seat| {
            for (seat.pads.items) |pc| {
                if (pc.res == pad_res) return pc;
            }
        }
        return null;
    }
};

fn indexOfPtr(comptime T: type, items: []T, needle: T) ?usize {
    for (items, 0..) |item, i| {
        if (item == needle) return i;
    }
    return null;
}

/// A listener that is on no signal. zig-wayland's `Listener.init` leaves
/// `link` UNDEFINED (the generated `wl.Listener(T).init` starts from
/// `var self: Self = undefined` and only writes `notify`), so a listener
/// that has never been added to a signal must be put in the detached state
/// by hand: `detachListener` and the destroy callbacks below test
/// `link.prev`, and `wl_list_remove` on an undefined link dereferences a
/// wild pointer. compositor/subsurface.zig:325-339 does the same.
fn detachedListener(comptime T: type, comptime notify: wire.Listener(T).NotifyFn) wire.Listener(T) {
    var listener = wire.Listener(T).init(notify);
    listener.link = .{ .prev = null, .next = null };
    return listener;
}

/// Detach a listener only when it is still linked. A detached listener's
/// link is {null, null} (detachedListener), and wl_list_remove on such a
/// node would corrupt the neighbouring list.
fn detachListener(comptime T: type, listener: *wire.Listener(T)) void {
    if (listener.link.prev != null) listener.link.remove();
}

// ---------------------------------------------------------------------------
// Manager global
// ---------------------------------------------------------------------------

fn tabletBind(client_wire: *wire.Client, tablet: *Tablet, version: u32, id: u32) void {
    log.debug("tablet bind v{d} id={d}", tablet.io, tablet.log_cfg, log_tag, .{ version, id });
    const res = server.zwp.TabletManagerV2.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    res.setHandler(*Tablet, managerRequest, null, tablet);
}

fn managerRequest(
    res: *server.zwp.TabletManagerV2,
    request: server.zwp.TabletManagerV2.Request,
    tablet: *Tablet,
) void {
    switch (request) {
        .destroy => res.destroy(),
        .get_tablet_seat => |r| {
            const sc = tablet.allocator.create(SeatClient) catch {
                res.getClient().postNoMemory();
                return;
            };
            // A wl_seat with no user data is not a live seat of this
            // server: hand the client an inert zwp_tablet_seat_v2 — the id
            // is allocated, nothing is ever announced, and the state is
            // freed by the resource's own destroy handler — exactly like
            // wlroots' `if (seat == NULL) return`
            // (types/tablet_v2/wlr_tablet_v2.c:150-154).
            sc.* = .{
                .manager = tablet,
                // SAFETY: assigned by `sc.res = seat_res` below, before the
                // resource exists and before any handler can run for it.
                .res = undefined,
                .wl_seat = r.seat,
                .inert = r.seat.getUserData() == null,
            };
            const seat_res = server.zwp.TabletSeatV2.create(res.getClient(), res.getVersion(), r.tablet_seat) catch {
                tablet.allocator.destroy(sc);
                res.getClient().postNoMemory();
                return;
            };
            sc.res = seat_res;
            if (!sc.inert) {
                tablet.seats.append(tablet.allocator, sc) catch {
                    seat_res.destroy();
                    tablet.allocator.destroy(sc);
                    res.getClient().postNoMemory();
                    return;
                };
            }
            seat_res.setHandler(?*SeatClient, seatClientRequest, seatClientDestroy, sc);
            if (sc.inert) return;
            sc.announceAll();
        },
    }
}

// ---------------------------------------------------------------------------
// Capability bursts
// ---------------------------------------------------------------------------

/// zwp_tablet_v2: name?, id?, path*, bustype?(v2), done (XML:588-682).
fn sendTabletBurst(tc: *TabletClient) void {
    const hw = tc.hw orelse return;
    const res = tc.res;
    if (hw.name) |name| res.sendName(name);
    if (hw.desc.vid != 0) res.sendId(hw.desc.vid, hw.desc.pid);
    for (hw.paths) |path| res.sendPath(path);
    // bustype is a version 2 addition (XML:671) and a v1 client has no
    // such event; libwayland will not filter it for us.
    if (hw.desc.bustype) |bustype| {
        if (res.getVersion() >= 2) res.sendBustype(bustype);
    }
    res.sendDone();
}

/// zwp_tablet_tool_v2: type, hardware_serial?, hardware_id_wacom?,
/// capability*, done (XML:275-358).
fn sendToolBurst(tc: *ToolClient) void {
    const hw = tc.hw orelse return;
    const res = tc.res;
    res.sendType(hw.desc.tool_type);
    if (hw.desc.hardware_serial) |serial| {
        res.sendHardwareSerial(@truncate(serial >> 32), @truncate(serial));
    }
    if (hw.desc.hardware_id_wacom) |id| {
        res.sendHardwareIdWacom(@truncate(id >> 32), @truncate(id));
    }
    for (hw.desc.capabilities) |capability| res.sendCapability(capability);
    res.sendDone();
}

/// zwp_tablet_pad_v2: group+ (each followed by the group's complete
/// burst), path?, buttons?, done (XML:1129-1175).
fn sendPadBurst(pc: *PadClient) !void {
    const hw = pc.hw orelse return;
    const res = pc.res;
    for (hw.desc.groups) |desc| try createGroup(pc, desc);
    if (hw.path) |path| res.sendPath(path);
    // The buttons event announces the pad's total button count and is only
    // sent when there is at least one button (XML:1168-1171).
    if (hw.desc.buttons > 0) res.sendButtons(hw.desc.buttons);
    res.sendDone();
}

/// zwp_tablet_pad_group_v2: buttons first, ring*, strip*, modes (only when
/// more than one), dial*(v2), done (XML:948-1063).
fn createGroup(pc: *PadClient, desc: GroupDesc) !void {
    const manager = pc.manager;
    const allocator = manager.allocator;
    const res = try server.zwp.TabletPadGroupV2.create(pc.res.getClient(), pc.res.getVersion(), 0);
    const gc = allocator.create(GroupClient) catch |err| {
        res.destroy();
        return err;
    };
    gc.* = .{ .manager = manager, .pad = pc, .res = res, .modes = desc.modes };
    pc.groups.append(allocator, gc) catch |err| {
        allocator.destroy(gc);
        res.destroy();
        return err;
    };
    // From here the group resource owns gc: a failure below destroys the
    // resource (which frees gc) and nothing else.
    res.setHandler(*GroupClient, groupRequest, groupDestroy, gc);

    // `group` allocates the client-side object; its burst must follow the
    // group event and precede the pad's done (XML:925-926, 1086-1088).
    pc.res.sendGroup(res);

    // The buttons array is sent even when empty: a group whose buttons are
    // all reserved by the compositor announces an empty array
    // (XML:959-963).
    gc.buttons.appendSlice(allocator, desc.buttons) catch |err| {
        res.destroy();
        return err;
    };
    var buttons: wire.wl.Array = .{
        .size = gc.buttons.items.len * @sizeOf(u32),
        .alloc = 0,
        .data = if (gc.buttons.items.len == 0) null else @as(?*anyopaque, @ptrCast(gc.buttons.items.ptr)),
    };
    res.sendButtons(&buttons);

    var i: u32 = 0;
    while (i < desc.ring_count) : (i += 1) {
        const aux = try newAux(gc, .ring);
        gc.rings.append(allocator, aux) catch |err| {
            aux.res.destroy();
            return err;
        };
        gc.res.sendRing(@as(*server.zwp.TabletPadRingV2, @ptrCast(aux.res)));
    }
    i = 0;
    while (i < desc.strip_count) : (i += 1) {
        const aux = try newAux(gc, .strip);
        gc.strips.append(allocator, aux) catch |err| {
            aux.res.destroy();
            return err;
        };
        gc.res.sendStrip(@as(*server.zwp.TabletPadStripV2, @ptrCast(aux.res)));
    }
    // The modes event announces that the group MAY switch modes; it is only
    // sent when more than one mode exists (XML:1000-1001). A single-mode
    // group still reports mode 0 through mode_switch after every
    // zwp_tablet_pad_v2.enter (XML:1041-1044).
    if (desc.modes > 1) res.sendModes(desc.modes);
    // dials are a version 2 addition (XML:1052): a v1 client is told about
    // none of them, not even the count.
    if (gc.res.getVersion() >= 2) {
        i = 0;
        while (i < desc.dial_count) : (i += 1) {
            const aux = try newAux(gc, .dial);
            gc.dials.append(allocator, aux) catch |err| {
                aux.res.destroy();
                return err;
            };
            gc.res.sendDial(@as(*server.zwp.TabletPadDialV2, @ptrCast(aux.res)));
        }
    }
    res.sendDone();
}

fn newAux(gc: *GroupClient, kind: AuxKind) !*AuxClient {
    const allocator = gc.manager.allocator;
    const client_wire = gc.pad.?.res.getClient();
    const version = gc.pad.?.res.getVersion();
    const res: *wire.Resource = switch (kind) {
        .ring => @ptrCast(try server.zwp.TabletPadRingV2.create(client_wire, version, 0)),
        .strip => @ptrCast(try server.zwp.TabletPadStripV2.create(client_wire, version, 0)),
        .dial => @ptrCast(try server.zwp.TabletPadDialV2.create(client_wire, version, 0)),
    };
    const aux = allocator.create(AuxClient) catch |err| {
        // Nothing owns `res` until setHandler below; drop it here or the
        // wl_resource (and the client-side object it announced) leaks.
        res.destroy();
        return err;
    };
    aux.* = .{ .allocator = allocator, .group = gc, .kind = kind, .res = res };
    // From here the aux resource owns aux.
    switch (kind) {
        .ring => @as(*server.zwp.TabletPadRingV2, @ptrCast(res)).setHandler(*AuxClient, ringRequest, ringDestroy, aux),
        .strip => @as(*server.zwp.TabletPadStripV2, @ptrCast(res)).setHandler(*AuxClient, stripRequest, stripDestroy, aux),
        .dial => @as(*server.zwp.TabletPadDialV2, @ptrCast(res)).setHandler(*AuxClient, dialRequest, dialDestroy, aux),
    }
    return aux;
}

// ---------------------------------------------------------------------------
// Seat object
// ---------------------------------------------------------------------------

fn seatClientRequest(res: *server.zwp.TabletSeatV2, request: server.zwp.TabletSeatV2.Request, _: ?*SeatClient) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

/// The seat client is gone: tear down every object it owns (wlroots
/// tablet_seat_client_v2_destroy, types/tablet_v2/wlr_tablet_v2.c:104-126)
/// and free the state. Destroying the child resources runs their own
/// destroy handlers, which prune themselves from both this seat's lists
/// and the hardware registries, so the lists are empty afterwards.
fn seatClientDestroy(_: *server.zwp.TabletSeatV2, sc: ?*SeatClient) void {
    const seat = sc orelse return;
    const manager = seat.manager;
    while (seat.tablets.items.len > 0) seat.tablets.items[0].res.destroy();
    while (seat.tools.items.len > 0) seat.tools.items[0].res.destroy();
    while (seat.pads.items.len > 0) seat.pads.items[0].res.destroy();
    if (indexOfPtr(*SeatClient, manager.seats.items, seat)) |i| _ = manager.seats.orderedRemove(i);
    const allocator = manager.allocator;
    seat.tablets.deinit(allocator);
    seat.tools.deinit(allocator);
    seat.pads.deinit(allocator);
    allocator.destroy(seat);
}

// ---------------------------------------------------------------------------
// Tablet object
// ---------------------------------------------------------------------------

fn tabletRequest(res: *server.zwp.TabletV2, request: server.zwp.TabletV2.Request, _: *TabletClient) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn tabletDestroy(_: *server.zwp.TabletV2, tc: *TabletClient) void {
    if (tc.hw) |hw| {
        if (indexOfPtr(*TabletClient, hw.clients.items, tc)) |i| _ = hw.clients.orderedRemove(i);
    }
    if (indexOfPtr(*TabletClient, tc.seat.tablets.items, tc)) |i| _ = tc.seat.tablets.orderedRemove(i);
    tc.manager.allocator.destroy(tc);
}

// ---------------------------------------------------------------------------
// Tool object
// ---------------------------------------------------------------------------

fn toolRequest(res: *server.zwp.TabletToolV2, request: server.zwp.TabletToolV2.Request, tc: *ToolClient) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_cursor => |r| {
            // "This request only takes effect if the tool is in proximity
            // of one of the requesting client's surfaces" — the serial is
            // the half we can evaluate: it must be the proximity_in serial
            // this client holds (tablet-v2.xml:215). A request that fails
            // is ignored, never a protocol error (wlroots leaves the same
            // check to the cursor consumer, wlr_tablet_v2_tool.c).
            if (tc.cursor_serial == null or tc.cursor_serial.? != r.serial) {
                log.debug("tablet tool@{d} set_cursor: serial {d} is not the proximity_in serial, ignored", tc.manager.io, tc.manager.log_cfg, log_tag, .{ res.getId(), r.serial });
                return;
            }
            const surface_res = r.surface orelse {
                // surface = null hides the cursor image (tablet-v2.xml:
                // 219-220).
                clearToolCursor(tc);
                return;
            };
            // The wl_surface user data is the compositor's Surface; null
            // means the surface is inert (already destroyed) — ignore.
            const ud = surface_res.getUserData() orelse return;
            const surface: *surface_mod.Surface = @ptrCast(@alignCast(ud));
            // "A surface may only ever be used as the cursor surface for
            // one zwp_tablet_tool_v2. If the surface already has another
            // role or has previously been used as cursor surface for a
            // different tool, a protocol error is raised"
            // (tablet-v2.xml:242-246).
            const tool_resource: *wire.Resource = @ptrCast(res);
            if (surface.role) |current| {
                const same_tool = surface.role_resource == null or surface.role_resource == tool_resource;
                if (current != &tool_cursor_role or !same_tool) {
                    res.postError(.role, "wl_surface already has another role or is another tool's cursor surface");
                    return;
                }
            } else {
                surface.role = &tool_cursor_role;
            }
            surface.role_resource = tool_resource;
            setToolCursorSurface(tc, surface);
            tc.cursor.hotspot_x = r.hotspot_x;
            tc.cursor.hotspot_y = r.hotspot_y;
            log.debug("tablet tool@{d} cursor surface set (serial={d})", tc.manager.io, tc.manager.log_cfg, log_tag, .{
                res.getId(),
                r.serial,
            });
        },
    }
}

fn toolDestroy(res: *server.zwp.TabletToolV2, tc: *ToolClient) void {
    // The cursor surface outlives this request: drop the listener before
    // the state goes away so the surface's destroy list never points at
    // freed memory, and clear the back-pointer it holds on the surface —
    // but only ours, another tool may already have claimed it.
    detachListener(*surface_mod.Surface, &tc.cursor_destroy_listener);
    if (tc.cursor.surface) |surface| {
        if (surface.role_resource == @as(*wire.Resource, @ptrCast(res))) surface.role_resource = null;
    }
    if (tc.hw) |hw| {
        if (indexOfPtr(*ToolClient, hw.clients.items, tc)) |i| _ = hw.clients.orderedRemove(i);
    }
    if (indexOfPtr(*ToolClient, tc.seat.tools.items, tc)) |i| _ = tc.seat.tools.orderedRemove(i);
    tc.manager.allocator.destroy(tc);
}

/// The cursor surface was destroyed: forget it. The tool keeps its
/// proximity serial, so a later set_cursor may name a new surface.
fn onCursorSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), _: *surface_mod.Surface) void {
    const tc: *ToolClient = @fieldParentPtr("cursor_destroy_listener", listener);
    listener.link.remove();
    tc.cursor.surface = null;
}

fn setToolCursorSurface(tc: *ToolClient, surface: *surface_mod.Surface) void {
    if (tc.cursor.surface == surface) return;
    detachListener(*surface_mod.Surface, &tc.cursor_destroy_listener);
    tc.cursor.surface = surface;
    surface.events.destroy.add(&tc.cursor_destroy_listener);
}

/// Drop the cursor surface and its hotspot (proximity_out, or an explicit
/// set_cursor with a null surface).
fn clearToolCursor(tc: *ToolClient) void {
    detachListener(*surface_mod.Surface, &tc.cursor_destroy_listener);
    tc.cursor.surface = null;
    tc.cursor.hotspot_x = 0;
    tc.cursor.hotspot_y = 0;
}

const tool_cursor_role: role_mod.SurfaceRole = .{ .name = "zwp_tablet_tool_v2.cursor" };

// ---------------------------------------------------------------------------
// Pad object
// ---------------------------------------------------------------------------

fn padRequest(res: *server.zwp.TabletPadV2, request: server.zwp.TabletPadV2.Request, pc: *PadClient) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_feedback => |r| {
            // "The serial argument will be that of the last
            // zwp_tablet_pad_group_v2.mode_switch event received for the
            // group of this button. Requests providing other serials than
            // the most recent one will be ignored" (XML:1115-1121). A
            // button the compositor reserved (it belongs to no group) is
            // ignored too (XML:1098-1101).
            const gc = groupForButton(pc, r.button) orelse return;
            if (gc.mode_serial == null or gc.mode_serial.? != r.serial) {
                log.debug("tablet pad@{d} button {d}: stale feedback serial {d}, ignored", pc.manager.io, pc.manager.log_cfg, log_tag, .{ res.getId(), r.button, r.serial });
                return;
            }
            log.debug("tablet pad@{d} button {d} feedback accepted (serial={d})", pc.manager.io, pc.manager.log_cfg, log_tag, .{ res.getId(), r.button, r.serial });
        },
    }
}

fn padDestroy(_: *server.zwp.TabletPadV2, pc: *PadClient) void {
    // The group tree is NOT destroyed from here. The client owns those
    // resources (and destroys them after zwp_tablet_pad_v2.removed,
    // XML:1215-1217), and a server-side destroy would make the client's
    // later destroy fail with wl_display.error invalid_object. The groups
    // are only marked parentless; each frees itself when the client lets
    // go. wlroots keeps NULL sentinels in the pad's arrays for the same
    // reason (types/tablet_v2/wlr_tablet_v2_pad.c:25-35, 124-134).
    const allocator = pc.manager.allocator;
    detachListener(*surface_mod.Surface, &pc.focus_destroy_listener);
    for (pc.groups.items) |gc| gc.pad = null;
    // The group's own state belongs to its resource, but the LIST of them
    // belongs to the pad: without this the backing array outlives pc.
    pc.groups.deinit(allocator);
    if (pc.hw) |hw| {
        if (indexOfPtr(*PadClient, hw.clients.items, pc)) |i| _ = hw.clients.orderedRemove(i);
    }
    if (indexOfPtr(*PadClient, pc.seat.pads.items, pc)) |i| _ = pc.seat.pads.orderedRemove(i);
    allocator.destroy(pc);
}

/// The focused surface died: forget it. No zwp_tablet_pad_v2.leave is
/// sent — libwayland rejects an event that carries a destroyed resource.
fn onFocusSurfaceDestroy(listener: *wire.Listener(*surface_mod.Surface), _: *surface_mod.Surface) void {
    const pc: *PadClient = @fieldParentPtr("focus_destroy_listener", listener);
    listener.link.remove();
    pc.focus = null;
}

fn attachFocus(pc: *PadClient, surface: *surface_mod.Surface) void {
    if (pc.focus == surface) return;
    detachListener(*surface_mod.Surface, &pc.focus_destroy_listener);
    pc.focus = surface;
    surface.events.destroy.add(&pc.focus_destroy_listener);
}

fn detachFocus(pc: *PadClient) void {
    detachListener(*surface_mod.Surface, &pc.focus_destroy_listener);
    pc.focus = null;
}

/// The group owning a button index, or null when the compositor reserved
/// that button (it belongs to no group, XML:1098-1101).
fn groupForButton(pc: *PadClient, button: u32) ?*GroupClient {
    for (pc.groups.items) |gc| {
        for (gc.buttons.items) |index| {
            if (index == button) return gc;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Pad group and its rings / strips / dials
// ---------------------------------------------------------------------------

fn groupRequest(res: *server.zwp.TabletPadGroupV2, request: server.zwp.TabletPadGroupV2.Request, _: *GroupClient) void {
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn groupDestroy(_: *server.zwp.TabletPadGroupV2, gc: *GroupClient) void {
    const manager = gc.manager;
    const allocator = manager.allocator;
    // Mark the aux objects parentless so their own destroy handlers do not
    // touch this freed state; the client may destroy the group before its
    // rings, strips and dials.
    for (gc.rings.items) |aux| aux.group = null;
    for (gc.strips.items) |aux| aux.group = null;
    for (gc.dials.items) |aux| aux.group = null;
    if (gc.pad) |pc| {
        if (indexOfPtr(*GroupClient, pc.groups.items, gc)) |i| _ = pc.groups.orderedRemove(i);
    }
    gc.buttons.deinit(allocator);
    gc.rings.deinit(allocator);
    gc.strips.deinit(allocator);
    gc.dials.deinit(allocator);
    allocator.destroy(gc);
}

fn ringRequest(res: *server.zwp.TabletPadRingV2, request: server.zwp.TabletPadRingV2.Request, aux: *AuxClient) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_feedback => |r| acceptAuxFeedback(aux, r.serial),
    }
}

fn stripRequest(res: *server.zwp.TabletPadStripV2, request: server.zwp.TabletPadStripV2.Request, aux: *AuxClient) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_feedback => |r| acceptAuxFeedback(aux, r.serial),
    }
}

fn dialRequest(res: *server.zwp.TabletPadDialV2, request: server.zwp.TabletPadDialV2.Request, aux: *AuxClient) void {
    switch (request) {
        .destroy => res.destroy(),
        .set_feedback => |r| acceptAuxFeedback(aux, r.serial),
    }
}

/// Same rule as zwp_tablet_pad_v2.set_feedback: the serial must be the most
/// recent zwp_tablet_pad_group_v2.mode_switch of the owning group
/// (XML:715-719, 833-838, 1250-1256).
fn acceptAuxFeedback(aux: *AuxClient, serial: u32) void {
    const gc = aux.group orelse return;
    if (gc.mode_serial == null or gc.mode_serial.? != serial) return;
    log.debug("tablet pad {s} feedback accepted (serial={d})", gc.manager.io, gc.manager.log_cfg, log_tag, .{
        @tagName(aux.kind),
        serial,
    });
}

fn ringDestroy(_: *server.zwp.TabletPadRingV2, aux: *AuxClient) void {
    auxDestroy(aux);
}

fn stripDestroy(_: *server.zwp.TabletPadStripV2, aux: *AuxClient) void {
    auxDestroy(aux);
}

fn dialDestroy(_: *server.zwp.TabletPadDialV2, aux: *AuxClient) void {
    auxDestroy(aux);
}

fn auxDestroy(aux: *AuxClient) void {
    if (aux.group) |gc| {
        const list = auxList(gc, aux.kind);
        if (indexOfPtr(*AuxClient, list.items, aux)) |i| _ = list.orderedRemove(i);
    }
    aux.allocator.destroy(aux);
}

fn auxList(gc: *GroupClient, kind: AuxKind) *std.ArrayList(*AuxClient) {
    return switch (kind) {
        .ring => &gc.rings,
        .strip => &gc.strips,
        .dial => &gc.dials,
    };
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/xdg.zig and
// shell/fractional_scale.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const compositor_mod = @import("../compositor/compositor.zig");
const seat_mod = @import("../compositor/seat.zig");

/// The harness below (EventLog, Capture, Peer, TestServer) is exported
/// because src/backend/libinput.zig drives a REAL zwp_tablet_manager_v2
/// through it: the backend's tablet translation is proven against a real
/// client reading a real socketpair, not against a stub, and duplicating
/// this harness in the backend would be a second copy of the same rig.
///
/// Ordered record of the events the test client received, as one flat
/// string: `"tablet_added name id path bustype done "`. Comparing the whole
/// string is what pins the XML's burst order.
pub const EventLog = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn add(self: *EventLog, comptime name: []const u8) void {
        if (self.len + name.len + 1 > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..name.len], name);
        self.len += name.len;
        self.buf[self.len] = ' ';
        self.len += 1;
    }

    fn text(self: *EventLog) []const u8 {
        return self.buf[0..self.len];
    }

    fn clear(self: *EventLog) void {
        self.len = 0;
    }
};

/// Client-side capture: appends every event name to one log and keeps the
/// newest object of each kind so a test can send requests back. A new_id
/// that arrives in an event gets its listener attached inside the parent
/// listener, before libwayland dispatches the events that follow it.
pub const Capture = struct {
    log: *EventLog,
    tool: ?*client.zwp.TabletToolV2 = null,
    /// Every announced zwp_tablet_tool_v2 in announcement order. `tool`
    /// alone is only the NEWEST one, which is the wrong proxy as soon as a
    /// test drives more than one tool (the cursor-role test does).
    tools: [8]?*client.zwp.TabletToolV2 = @splat(null),
    tool_count: usize = 0,
    pad: ?*client.zwp.TabletPadV2 = null,
    /// Serial of the most recent proximity_in / enter / mode_switch.
    serial: u32 = 0,
    /// Time argument of the most recent mode_switch, in milliseconds.
    mode_time: u32 = 0,
    /// Decoded contents of the most recent pad-group buttons array.
    group_buttons: usize = 0,
    first_button: u32 = 0,

    /// The nth announced zwp_tablet_tool_v2, in announcement order.
    fn toolAt(self: *Capture, index: usize) *client.zwp.TabletToolV2 {
        std.debug.assert(index < self.tool_count);
        return self.tools[index] orelse unreachable;
    }

    fn seat(_: *client.zwp.TabletSeatV2, event: client.zwp.TabletSeatV2.Event, self: *Capture) void {
        switch (event) {
            .tablet_added => |e| {
                self.log.add("tablet_added");
                e.id.setListener(*Capture, onTablet, self);
            },
            .tool_added => |e| {
                self.log.add("tool_added");
                if (self.tool_count < self.tools.len) {
                    self.tools[self.tool_count] = e.id;
                    self.tool_count += 1;
                }
                self.tool = e.id;
                e.id.setListener(*Capture, onTool, self);
            },
            .pad_added => |e| {
                self.log.add("pad_added");
                self.pad = e.id;
                e.id.setListener(*Capture, onPad, self);
            },
        }
    }

    fn onTablet(_: *client.zwp.TabletV2, event: client.zwp.TabletV2.Event, self: *Capture) void {
        switch (event) {
            .name => self.log.add("name"),
            .id => self.log.add("id"),
            .path => self.log.add("path"),
            .bustype => self.log.add("bustype"),
            .done => self.log.add("done"),
            .removed => self.log.add("removed"),
        }
    }

    fn onTool(_: *client.zwp.TabletToolV2, event: client.zwp.TabletToolV2.Event, self: *Capture) void {
        switch (event) {
            .type => self.log.add("type"),
            .hardware_serial => self.log.add("hardware_serial"),
            .hardware_id_wacom => self.log.add("hardware_id_wacom"),
            .capability => self.log.add("capability"),
            .done => self.log.add("done"),
            .removed => self.log.add("removed"),
            .proximity_in => |e| {
                self.log.add("proximity_in");
                self.serial = e.serial;
            },
            .proximity_out => self.log.add("proximity_out"),
            // The axis/button relay has no driver here: a hand-built
            // tablet has no input backend feeding it.
            else => {},
        }
    }

    fn onPad(_: *client.zwp.TabletPadV2, event: client.zwp.TabletPadV2.Event, self: *Capture) void {
        switch (event) {
            .group => |e| {
                self.log.add("group");
                e.pad_group.setListener(*Capture, onGroup, self);
            },
            .path => self.log.add("pad_path"),
            .buttons => self.log.add("pad_buttons"),
            .done => self.log.add("pad_done"),
            .enter => |e| {
                self.log.add("enter");
                self.serial = e.serial;
            },
            .leave => self.log.add("leave"),
            .removed => self.log.add("removed"),
            else => {},
        }
    }

    fn onGroup(_: *client.zwp.TabletPadGroupV2, event: client.zwp.TabletPadGroupV2.Event, self: *Capture) void {
        switch (event) {
            .buttons => |e| {
                self.log.add("buttons");
                self.group_buttons = e.buttons.size / @sizeOf(u32);
                self.first_button = if (e.buttons.data) |data|
                    @as([*]const u32, @ptrCast(@alignCast(data)))[0]
                else
                    0;
            },
            .ring => self.log.add("ring"),
            .strip => self.log.add("strip"),
            .modes => self.log.add("modes"),
            .dial => self.log.add("dial"),
            .done => self.log.add("group_done"),
            .mode_switch => |e| {
                self.log.add("mode_switch");
                self.serial = e.serial;
                self.mode_time = e.time;
            },
        }
    }
};

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    seat_name: ?u32 = null,
    tablet_name: ?u32 = null,

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
                }
            },
            .global_remove => {},
        }
    }
};

pub const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    tablet: ?*Tablet = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wl_seat: ?*client.wl.Seat = null,
    tablet_manager: ?*client.zwp.TabletManagerV2 = null,
    event_log: EventLog = .{},
    capture: Capture = .{ .log = undefined },
    /// Extra clients added by addPeer, torn down with this server.
    peers: std.ArrayList(*Peer) = .empty,

    /// Heap-allocated: the `io` pointer must outlive the stack frame, and
    /// `capture` holds a pointer into this struct, so it must be stable
    /// too. `manager_version` is the zwp_tablet_manager_v2 version the
    /// test client binds.
    pub fn init(allocator: std.mem.Allocator, manager_version: u32) !*TestServer {
        const ts = try allocator.create(TestServer);
        errdefer allocator.destroy(ts);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        ts.capture = .{ .log = &ts.event_log };
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        errdefer if (ts.display) |d| d.deinit();
        // The internal wl_shm global (libwayland) must exist before the
        // client's first registry roundtrip.
        try ts.display.?.initShm();
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        errdefer if (ts.seat) |s| s.deinit();
        ts.tablet = try Tablet.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.tablet) |t| t.deinit();

        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        const registry = try ts.c_display.?.getRegistry();
        var globals: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &globals);
        try ts.pump();
        if (globals.compositor_name == null or globals.seat_name == null or globals.tablet_name == null) {
            return error.GlobalMissing;
        }
        ts.wl_compositor = try registry.bind(globals.compositor_name.?, client.wl.Compositor, 7);
        ts.wl_seat = try registry.bind(globals.seat_name.?, client.wl.Seat, 7);
        ts.tablet_manager = try registry.bind(globals.tablet_name.?, client.zwp.TabletManagerV2, manager_version);
        try ts.pump();
        return ts;
    }

    /// A second, third, ... connection with its own zwp_tablet_seat_v2
    /// and its own event log. See Peer for why the out-of-memory
    /// announce test needs one seat per client.
    fn addPeer(ts: *TestServer, manager_version: u32) !*Peer {
        const peer = try ts.allocator.create(Peer);
        errdefer ts.allocator.destroy(peer);
        // SAFETY: every field below is written before the peer is read;
        // only `ts` has to be right for the error paths, and they only
        // free the struct.
        peer.* = .{
            .ts = ts,
            .client = undefined,
            .c_display = undefined,
            .tablet_manager = undefined,
            .seat = undefined,
        };
        peer.capture = .{ .log = &peer.log };
        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        peer.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        peer.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

        const registry = try peer.c_display.getRegistry();
        var globals: RegistryCapture = .{};
        registry.setListener(*RegistryCapture, RegistryCapture.listener, &globals);
        try peer.pump();
        if (globals.seat_name == null or globals.tablet_name == null) return error.GlobalMissing;
        const wl_seat = try registry.bind(globals.seat_name.?, client.wl.Seat, 7);
        peer.tablet_manager = try registry.bind(globals.tablet_name.?, client.zwp.TabletManagerV2, manager_version);
        try peer.pump();
        peer.seat = try peer.tablet_manager.getTabletSeat(wl_seat);
        peer.seat.setListener(*Capture, Capture.seat, &peer.capture);
        try peer.pump();
        try ts.peers.append(ts.allocator, peer);
        return peer;
    }

    pub fn deinit(ts: *TestServer) void {
        // Tear the client down first: its resource destroy handlers must
        // run while the tablet module lives.
        if (ts.c_display) |d| d.disconnect();
        for (ts.peers.items) |peer| peer.deinit();
        ts.peers.deinit(ts.allocator);
        if (ts.client) |c| c.destroy();
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
    pub fn pump(ts: *TestServer) !void {
        try test_pump.roundtrip(ts.c_display.?, ts.display.?, 0);
        var fds = [_]posix.pollfd{
            .{ .fd = ts.c_display.?.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (ts.c_display.?.dispatch() != .SUCCESS) {
                // A protocol error or disconnect: the server already
                // destroyed the client, so forget it for deinit.
                ts.client = null;
                return error.ClientDispatchFailed;
            }
        }
    }

    /// get_tablet_seat for the client's own wl_seat, wired to the log.
    pub fn getTabletSeat(ts: *TestServer) !*client.zwp.TabletSeatV2 {
        const seat = try ts.tablet_manager.?.getTabletSeat(ts.wl_seat.?);
        seat.setListener(*Capture, Capture.seat, &ts.capture);
        try ts.pump();
        return seat;
    }

    /// A client wl_surface plus the compositor Surface behind it.
    pub fn makeSurface(ts: *TestServer) !struct { proxy: *client.wl.Surface, surface: *surface_mod.Surface } {
        const proxy = try ts.wl_compositor.?.createSurface();
        // The wl_surface resource only exists server-side once the request
        // has been flushed and dispatched.
        try ts.pump();
        return .{ .proxy = proxy, .surface = ts.surfaceFor(proxy) };
    }

    /// The server-side Surface created for `proxy`.
    pub fn surfaceFor(ts: *TestServer, proxy: *client.wl.Surface) *surface_mod.Surface {
        for (ts.compositor.?.surfaces.items) |s| {
            if (s.resource.getId() == proxy.getId()) return s;
        }
        unreachable;
    }
};

/// A second, third, ... test client: its own socketpair, its own
/// zwp_tablet_seat_v2 and its own event log, so a test can tell whose
/// announcements reached whom.
///
/// The out-of-memory announce path needs one seat per CLIENT. The failure
/// handler posts wl_resource_post_no_memory, which destroys the whole
/// connection — three seats on one client would all die with the first
/// failure, and the test could no longer tell whether the announce loop
/// went on to the seats behind the dead one.
pub const Peer = struct {
    ts: *TestServer,
    client: *wire.Client,
    c_display: *client.wl.Display,
    tablet_manager: *client.zwp.TabletManagerV2,
    seat: *client.zwp.TabletSeatV2,
    log: EventLog = .{},
    capture: Capture = .{ .log = undefined },
    /// False once the server destroyed this connection (a no_memory
    /// post, or a protocol error): deinit must not destroy the wire
    /// client again, the same rule TestServer.deinit follows through its
    /// nullable `client`.
    alive: bool = true,

    fn pump(self: *Peer) !void {
        try test_pump.roundtrip(self.c_display, self.ts.display.?, 0);
        var fds = [_]posix.pollfd{
            .{ .fd = self.c_display.getFd(), .events = posix.POLL.IN, .revents = 0 },
        };
        if (try posix.poll(&fds, 0) > 0) {
            if (self.c_display.dispatch() != .SUCCESS) {
                self.alive = false;
                return error.ClientDispatchFailed;
            }
        }
    }

    fn deinit(self: *Peer) void {
        self.c_display.disconnect();
        if (self.alive) self.client.destroy();
        const allocator = self.ts.allocator;
        allocator.destroy(self);
    }
};

test "tablet manager binds with no tablet present and tears down clean" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();

    // The client's only valid state today: a silent zwp_tablet_seat_v2.
    const seat = try ts.getTabletSeat();
    try std.testing.expectEqualStrings("", ts.event_log.text());
    try std.testing.expectEqual(@as(usize, 1), ts.tablet.?.seats.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.tablet.?.tablets.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.tablet.?.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.tablet.?.pads.items.len);

    // A second get_tablet_seat gets its own view of the same (empty)
    // registry; the two must stay independent.
    const seat2 = try ts.tablet_manager.?.getTabletSeat(ts.wl_seat.?);
    seat2.setListener(*Capture, Capture.seat, &ts.capture);
    try ts.pump();
    try std.testing.expectEqualStrings("", ts.event_log.text());
    try std.testing.expectEqual(@as(usize, 2), ts.tablet.?.seats.items.len);

    seat.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.tablet.?.seats.items.len);
    seat2.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.tablet.?.seats.items.len);
}

test "tablet capability burst follows the XML order: name, id, path*, bustype, done" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();

    // Hardware registered before the client binds must be announced by
    // get_tablet_seat.
    const hw = try ts.tablet.?.addTablet(.{
        .name = "Wacom Intuos S",
        .vid = 0x056a,
        .pid = 0x0378,
        .paths = &.{ "/dev/input/event3", "/dev/input/event4" },
        .bustype = .usb,
    });
    _ = try ts.getTabletSeat();
    try std.testing.expectEqualStrings(
        "tablet_added name id path path bustype done ",
        ts.event_log.text(),
    );
    try std.testing.expectEqual(@as(usize, 1), hw.clients.items.len);

    // Every optional event is skipped when the hardware has nothing to
    // say: the burst is then name-less, id-less, path-less.
    ts.event_log.clear();
    _ = try ts.tablet.?.addTablet(.{});
    try ts.pump();
    try std.testing.expectEqualStrings("tablet_added done ", ts.event_log.text());
}

test "bustype is a v2 event and is never sent to a v1 client" {
    const allocator = std.testing.allocator;
    var ts1 = try TestServer.init(allocator, 1);
    defer ts1.deinit();
    const hw = try ts1.tablet.?.addTablet(.{ .name = "v1 tablet", .bustype = .bluetooth });
    _ = try ts1.getTabletSeat();
    try std.testing.expectEqualStrings("tablet_added name done ", ts1.event_log.text());
    try std.testing.expectEqual(@as(usize, 1), hw.clients.items.len);
}

test "tool capability burst follows the XML order: type, serial, id_wacom, capability*, done" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();
    _ = try ts.getTabletSeat();

    _ = try ts.tablet.?.addTool(.{
        .tool_type = .pen,
        .hardware_serial = 0x1234_5678_9abc_def0,
        .hardware_id_wacom = 0x802,
        .capabilities = &.{ .pressure, .tilt, .distance },
    });
    try ts.pump();
    try std.testing.expectEqualStrings(
        "tool_added type hardware_serial hardware_id_wacom capability capability capability done ",
        ts.event_log.text(),
    );

    // A tool with no serial and no extra capability sends type + done.
    ts.event_log.clear();
    _ = try ts.tablet.?.addTool(.{ .tool_type = .finger });
    try ts.pump();
    try std.testing.expectEqualStrings("tool_added type done ", ts.event_log.text());
}

test "pad tree burst: each group burst completes before the pad's done" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();
    _ = try ts.getTabletSeat();

    const groups = [_]GroupDesc{
        .{ .buttons = &.{ 0, 1, 2 }, .ring_count = 2, .strip_count = 1, .dial_count = 1, .modes = 3 },
        // A group whose buttons are all reserved by the compositor: the
        // buttons event is still sent, with an empty array (XML:959-963).
        .{ .buttons = &.{}, .modes = 1 },
    };
    const hw = try ts.tablet.?.addPad(.{
        .path = "/dev/input/event9",
        .buttons = 8,
        .groups = &groups,
    });
    try ts.pump();
    try std.testing.expectEqualStrings(
        "pad_added " ++
            "group buttons ring ring strip modes dial group_done " ++
            "group buttons group_done " ++
            "pad_path pad_buttons pad_done ",
        ts.event_log.text(),
    );

    const pc = hw.clients.items[0];
    try std.testing.expectEqual(@as(usize, 2), pc.groups.items.len);
    try std.testing.expectEqual(@as(u32, 3), pc.groups.items[0].modes);
    try std.testing.expectEqual(@as(usize, 2), pc.groups.items[0].rings.items.len);
    try std.testing.expectEqual(@as(usize, 1), pc.groups.items[0].strips.items.len);
    try std.testing.expectEqual(@as(usize, 1), pc.groups.items[0].dials.items.len);
    try std.testing.expectEqual(@as(u32, 1), pc.groups.items[1].modes);
    try std.testing.expectEqual(@as(usize, 0), pc.groups.items[1].dials.items.len);
}

test "pad group buttons array carries the group's own indices" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();
    _ = try ts.getTabletSeat();

    const groups = [_]GroupDesc{.{ .buttons = &.{ 4, 5, 6 }, .modes = 1 }};
    const hw = try ts.tablet.?.addPad(.{ .buttons = 7, .groups = &groups });
    try ts.pump();
    // The client decoded three buttons starting at index 4.
    try std.testing.expectEqual(@as(usize, 3), ts.capture.group_buttons);
    try std.testing.expectEqual(@as(u32, 4), ts.capture.first_button);
    try std.testing.expectEqualSlices(
        u32,
        &.{ 4, 5, 6 },
        hw.clients.items[0].groups.items[0].buttons.items,
    );
}

test "dials are a v2 addition and are skipped for a v1 client" {
    const allocator = std.testing.allocator;
    const groups = [_]GroupDesc{.{ .buttons = &.{0}, .dial_count = 2, .modes = 2 }};

    var ts2 = try TestServer.init(allocator, tablet_v2_version);
    defer ts2.deinit();
    _ = try ts2.getTabletSeat();
    _ = try ts2.tablet.?.addPad(.{ .buttons = 1, .groups = &groups });
    try ts2.pump();
    try std.testing.expectEqualStrings(
        "pad_added group buttons modes dial dial group_done pad_buttons pad_done ",
        ts2.event_log.text(),
    );

    var ts1 = try TestServer.init(allocator, 1);
    defer ts1.deinit();
    _ = try ts1.getTabletSeat();
    _ = try ts1.tablet.?.addPad(.{ .buttons = 1, .groups = &groups });
    try ts1.pump();
    try std.testing.expectEqualStrings(
        "pad_added group buttons modes group_done pad_buttons pad_done ",
        ts1.event_log.text(),
    );
}

test "pad enter reports every group's current mode; leave and removed follow" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();

    const groups = [_]GroupDesc{
        .{ .buttons = &.{ 0, 1 }, .modes = 2 },
        .{ .buttons = &.{2}, .modes = 1 },
    };
    const tablet_hw = try ts.tablet.?.addTablet(.{ .name = "intuos" });
    const pad_hw = try ts.tablet.?.addPad(.{ .buttons = 3, .groups = &groups });
    _ = try ts.getTabletSeat();

    const made = try ts.makeSurface();
    const pc = pad_hw.clients.items[0];
    const tc = tablet_hw.clients.items[0];

    ts.event_log.clear();
    ts.tablet.?.padEnter(pc.res, tc.res, made.surface, 4242);
    try ts.pump();
    // Every group reports mode_switch after enter, single-mode groups
    // included (XML:1041-1044).
    try std.testing.expectEqualStrings("enter mode_switch mode_switch ", ts.event_log.text());
    try std.testing.expectEqual(@as(u32, 4242), ts.capture.mode_time);
    try std.testing.expectEqual(ts.capture.serial, pc.groups.items[0].mode_serial.?);
    try std.testing.expectEqual(pc.groups.items[0].mode_serial.?, pc.groups.items[1].mode_serial.?);

    // The client echoes the mode_switch serial: accepted. A stale serial
    // and a button the compositor reserved are ignored, and neither is a
    // protocol error — the connection survives.
    ts.capture.pad.?.setFeedback(0, "undo", pc.groups.items[0].mode_serial.?);
    ts.capture.pad.?.setFeedback(1, "redo", pc.groups.items[0].mode_serial.? + 1);
    ts.capture.pad.?.setFeedback(99, "reserved", pc.groups.items[0].mode_serial.?);
    try ts.pump();

    ts.event_log.clear();
    ts.tablet.?.padLeave(pc.res, made.surface);
    try ts.pump();
    try std.testing.expectEqualStrings("leave ", ts.event_log.text());
    try std.testing.expectEqual(@as(?*surface_mod.Surface, null), pc.focus);

    // Unplug: removed, the pad is detached from the hardware but alive
    // until the client destroys it.
    ts.event_log.clear();
    ts.tablet.?.removePad(pad_hw);
    try ts.pump();
    try std.testing.expectEqualStrings("removed ", ts.event_log.text());
    try std.testing.expectEqual(@as(?*PadHw, null), pc.hw);
    try std.testing.expectEqual(@as(usize, 0), ts.tablet.?.pads.items.len);

    // The group tree the client was offered is still valid; only the pad
    // lost its hardware. Destroying the groups first must not touch the
    // freed pad.
    while (pc.groups.items.len > 0) pc.groups.items[0].res.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), pc.groups.items.len);
    pc.res.destroy();
    try ts.pump();
}

test "tablet and tool removal send removed and the client's destroy is safe" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();
    _ = try ts.getTabletSeat();

    // vid/pid are set so the burst carries zwp_tablet_v2.id too: the
    // expectation below pins the WHOLE session, burst included, so the
    // log must not be cleared between the announcement and the removal.
    const tablet_hw = try ts.tablet.?.addTablet(.{ .name = "pen display", .vid = 0x056a, .pid = 0x0378 });
    const tool_hw = try ts.tablet.?.addTool(.{ .tool_type = .pen, .hardware_serial = 7 });
    try ts.pump();

    ts.tablet.?.removeTablet(tablet_hw);
    // Pump between the two removals: libwayland buffers events until the
    // server flushes, so without it both `removed` events share one flush
    // and the log cannot say the tablet's came first.
    try ts.pump();
    ts.tablet.?.removeTool(tool_hw);
    try ts.pump();
    try std.testing.expectEqualStrings(
        "tablet_added name id done tool_added type hardware_serial done removed removed ",
        ts.event_log.text(),
    );
    try std.testing.expectEqual(@as(usize, 0), ts.tablet.?.tablets.items.len);
    try std.testing.expectEqual(@as(usize, 0), ts.tablet.?.tools.items.len);

    // The client still owns both resources and destroys them; the detached
    // states must free without touching the freed hardware.
    const seat = ts.tablet.?.seats.items[0];
    while (seat.tablets.items.len > 0) seat.tablets.items[0].res.destroy();
    while (seat.tools.items.len > 0) seat.tools.items[0].res.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), seat.tablets.items.len);
    try std.testing.expectEqual(@as(usize, 0), seat.tools.items.len);
}

test "removing a tool in proximity sends proximity_out before removed" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();
    const tablet_hw = try ts.tablet.?.addTablet(.{ .name = "intuos" });
    const tool_hw = try ts.tablet.?.addTool(.{ .tool_type = .pen });
    _ = try ts.getTabletSeat();

    const made = try ts.makeSurface();
    const tool_res = tool_hw.clients.items[0].res;
    try std.testing.expectEqual(@as(?u32, null), ts.tablet.?.toolCursorSerial(tool_res));

    const serial = ts.tablet.?.toolProximityIn(tool_res, tablet_hw.clients.items[0].res, made.surface);
    try std.testing.expect(serial != null);
    try ts.pump();
    try std.testing.expectEqualStrings("tablet_added name done tool_added type done proximity_in ", ts.event_log.text());
    try std.testing.expectEqual(serial.?, ts.capture.serial);

    ts.event_log.clear();
    ts.tablet.?.removeTool(tool_hw);
    try ts.pump();
    try std.testing.expectEqualStrings("proximity_out removed ", ts.event_log.text());
    // The detached tool object survives until the client destroys it.
    try std.testing.expectEqual(@as(?u32, null), ts.tablet.?.toolCursorSerial(tool_res));
}

test "set_cursor needs the proximity_in serial and takes the tool cursor role" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();
    const tablet_hw = try ts.tablet.?.addTablet(.{ .name = "intuos" });
    const tool_hw = try ts.tablet.?.addTool(.{ .tool_type = .pen });
    _ = try ts.getTabletSeat();

    const made = try ts.makeSurface();
    const tool_res = tool_hw.clients.items[0].res;

    // Out of proximity: a set_cursor can never match, so the cursor stays
    // unset and the connection is untouched (an ignored request is never a
    // protocol error).
    ts.capture.tool.?.setCursor(1, made.proxy, 0, 0);
    try ts.pump();
    try std.testing.expect(ts.tablet.?.toolCursor(tool_res) == null);

    const serial = ts.tablet.?.toolProximityIn(tool_res, tablet_hw.clients.items[0].res, made.surface).?;
    try ts.pump();

    // A serial the seat never handed out is ignored...
    ts.capture.tool.?.setCursor(serial - 1, made.proxy, 1, 2);
    try ts.pump();
    try std.testing.expect(ts.tablet.?.toolCursor(tool_res) == null);

    // ...the proximity_in serial applies, hotspot included.
    ts.capture.tool.?.setCursor(serial, made.proxy, 7, 9);
    try ts.pump();
    const cursor = ts.tablet.?.toolCursor(tool_res).?;
    try std.testing.expectEqual(@as(?*surface_mod.Surface, made.surface), cursor.surface);
    try std.testing.expectEqual(@as(i32, 7), cursor.hotspot_x);
    try std.testing.expectEqual(@as(i32, 9), cursor.hotspot_y);
    try std.testing.expect(made.surface.role.? == &tool_cursor_role);

    // proximity_out drops the surface; a later set_cursor is ignored
    // again because no serial is held.
    ts.tablet.?.toolProximityOut(tool_res);
    try ts.pump();
    try std.testing.expect(ts.tablet.?.toolCursor(tool_res) == null);
    try std.testing.expectEqual(@as(?u32, null), ts.tablet.?.toolCursorSerial(tool_res));
}

test "a surface already another tool's cursor raises zwp_tablet_tool_v2.role" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();
    const tablet_hw = try ts.tablet.?.addTablet(.{ .name = "intuos" });
    const first = try ts.tablet.?.addTool(.{ .tool_type = .pen });
    const second = try ts.tablet.?.addTool(.{ .tool_type = .eraser });
    _ = try ts.getTabletSeat();

    const made = try ts.makeSurface();
    const tablet_res = tablet_hw.clients.items[0].res;
    const first_serial = ts.tablet.?.toolProximityIn(first.clients.items[0].res, tablet_res, made.surface).?;
    try ts.pump();
    // capture.tool is the NEWEST announced tool (the eraser); the pen's own
    // proxy is the one that has to carry the cursor here.
    ts.capture.toolAt(0).setCursor(first_serial, made.proxy, 0, 0);
    try ts.pump();
    try std.testing.expect(ts.tablet.?.toolCursor(first.clients.items[0].res) != null);

    // The second tool reuses the same surface: the XML raises a protocol
    // error on the zwp_tablet_tool_v2 resource, which kills the client.
    const second_serial = ts.tablet.?.toolProximityIn(second.clients.items[0].res, tablet_res, made.surface).?;
    try ts.pump();
    ts.capture.toolAt(1).setCursor(second_serial, made.proxy, 0, 0);
    try std.testing.expectError(error.ClientDispatchFailed, ts.pump());
}

/// Pass-through allocator that keeps the byte count it has handed out and
/// not yet been given back. `live` therefore answers "how much did the
/// caller still own", which is what a partial-failure leak test needs: the
/// std.testing.allocator only reports a leak at the END of the test, when
/// the module under test is long gone.
const LiveBytes = struct {
    inner: std.mem.Allocator,
    live: usize = 0,
    /// Refuse the allocation with this index, ONCE. The counting above
    /// is what makes that possible: std.testing's FailingAllocator
    /// leaves `alloc_index` where it was when it refuses, so EVERY
    /// later allocation fails as well — one refused announce would then
    /// take down all the seats behind it, and the test could no longer
    /// tell which of them the module actually failed.
    fail_index: usize = std.math.maxInt(usize),
    allocs: usize = 0,

    fn allocator(self: *LiveBytes) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LiveBytes = @ptrCast(@alignCast(ctx));
        const index = self.allocs;
        self.allocs += 1;
        if (index == self.fail_index) return null;
        const ptr = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += len;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LiveBytes = @ptrCast(@alignCast(ctx));
        if (!self.inner.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live = self.live - memory.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LiveBytes = @ptrCast(@alignCast(ctx));
        const ptr = self.inner.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live = self.live - memory.len + new_len;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LiveBytes = @ptrCast(@alignCast(ctx));
        self.live -= memory.len;
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

test "addTablet gives back every path copy when a later allocation fails" {
    var io = std.Io.Threaded.global_single_threaded.io();
    const log_cfg = log.Config{ .min_level = .err };
    const display = try display_mod.CompositorDisplay.init(std.testing.allocator, &io, &log_cfg);
    defer display.deinit();
    try display.initShm();

    // With a name and two paths, addTablet takes, in order: the TabletHw,
    // the name, the paths array, one copy per path, and the registry slot.
    // Failing at 4 is the partial-copy failure (the second dupeZ, after the
    // first copy already exists); failing at 5 is the registry append,
    // where both copies exist but nothing owns them yet. Neither may leave
    // a copy behind — an errdefer that only frees the array loses every one
    // of them.
    inline for (.{ 4, 5 }) |fail_index| {
        var live = LiveBytes{ .inner = std.testing.allocator };
        var failing = std.testing.FailingAllocator.init(live.allocator(), .{ .fail_index = fail_index });
        const tablet = try Tablet.init(failing.allocator(), &io, &log_cfg, display);
        defer tablet.deinit();
        const baseline = live.live;

        try std.testing.expectError(error.OutOfMemory, tablet.addTablet(.{
            .name = "Wacom Intuos S",
            .vid = 0x056a,
            .pid = 0x0378,
            .paths = &.{ "/dev/input/event3", "/dev/input/event4" },
            .bustype = .usb,
        }));
        try std.testing.expectEqual(baseline, live.live);
        try std.testing.expectEqual(@as(usize, 0), tablet.tablets.items.len);
    }
}

test "addTablet keeps a path-less descriptor on the comptime empty slice" {
    var io = std.Io.Threaded.global_single_threaded.io();
    const log_cfg = log.Config{ .min_level = .err };
    const display = try display_mod.CompositorDisplay.init(std.testing.allocator, &io, &log_cfg);
    defer display.deinit();
    try display.initShm();

    var live = LiveBytes{ .inner = std.testing.allocator };
    const baseline = live.live;
    {
        const tablet = try Tablet.init(live.allocator(), &io, &log_cfg, display);
        // No paths and no name: alloc(T, 0) would hand back a block that
        // free(_, 0) never returns, so the object must stay on &.{}.
        const hw = try tablet.addTablet(.{ .vid = 0x056a, .pid = 0x0378 });
        try std.testing.expectEqual(@as(usize, 0), hw.paths.len);
        // Every byte addTablet took must come back with the hardware and
        // the module: a leaked zero-length path array would show here.
        tablet.deinit();
    }
    try std.testing.expectEqual(baseline, live.live);
}

test "an OOM tablet announce fails one client and still serves every other seat once" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();

    // Three seats on three CONNECTIONS, in bind order: the FIRST seat's
    // announce runs out of memory, which is the only way one announce
    // failure could disturb the ones behind it.
    const a = try ts.addPeer(tablet_v2_version);
    const b = try ts.addPeer(tablet_v2_version);
    const c = try ts.addPeer(tablet_v2_version);
    try std.testing.expectEqual(@as(usize, 3), ts.tablet.?.seats.items.len);

    // Every allocation addTablet makes through the module allocator, in
    // order: 0 the TabletHw, 1 the name copy, 2 the registry slot,
    // 3 the TabletClient for the FIRST seat. Only that one is refused,
    // so the two announces behind it still have memory: an earlier
    // failure aborts addTablet and announces to nobody, which is what
    // keeps this index honest.
    var live = LiveBytes{ .inner = allocator, .fail_index = 3 };
    ts.tablet.?.allocator = live.allocator();
    _ = try ts.tablet.?.addTablet(.{ .name = "intuos" });
    ts.tablet.?.allocator = allocator;

    // The failure really was a's announce: it got no zwp_tablet_v2, so
    // the module holds a client object for the two survivors only.
    try std.testing.expectEqual(@as(usize, 2), ts.tablet.?.tablets.items[0].clients.items.len);
    // postOutOfMemory only POSTS the error, so the seat is still listed
    // when addTablet returns — the announce loop walked a list that
    // could not move under it.
    try std.testing.expectEqual(@as(usize, 3), ts.tablet.?.seats.items.len);

    // The error reaches a's connection. Its seat leaves the registry
    // only when the compositor's run loop sweeps an errored client
    // (wl_display_run's `if (client->error) wl_client_destroy`), which
    // the harness's wl_event_loop_dispatch never does — and which, in
    // production, still never runs inside an announce loop.
    try std.testing.expectError(error.ClientDispatchFailed, a.pump());
    try std.testing.expectEqual(@as(usize, 3), ts.tablet.?.seats.items.len);

    // Both survivors were announced exactly once each. A loop that lost
    // its place here — skipping the seat behind the dead one and giving
    // the last one a second burst — would fail on these two strings.
    try b.pump();
    try c.pump();
    try std.testing.expectEqualStrings("tablet_added name done ", b.log.text());
    try std.testing.expectEqualStrings("tablet_added name done ", c.log.text());
}

test "an OOM tool announce fails one client and still serves every other seat once" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();

    const a = try ts.addPeer(tablet_v2_version);
    const b = try ts.addPeer(tablet_v2_version);
    const c = try ts.addPeer(tablet_v2_version);

    // Same order as addTablet without the name copy: 0 the ToolHw,
    // 1 the registry slot, 2 the ToolClient for the FIRST seat.
    var live = LiveBytes{ .inner = allocator, .fail_index = 2 };
    ts.tablet.?.allocator = live.allocator();
    _ = try ts.tablet.?.addTool(.{ .tool_type = .pen });
    ts.tablet.?.allocator = allocator;

    try std.testing.expectEqual(@as(usize, 2), ts.tablet.?.tools.items[0].clients.items.len);
    // postOutOfMemory only posts, so a's seat is still listed here.
    try std.testing.expectEqual(@as(usize, 3), ts.tablet.?.seats.items.len);
    try std.testing.expectError(error.ClientDispatchFailed, a.pump());
    try std.testing.expectEqual(@as(usize, 3), ts.tablet.?.seats.items.len);
    try b.pump();
    try c.pump();
    try std.testing.expectEqualStrings("tool_added type done ", b.log.text());
    try std.testing.expectEqualStrings("tool_added type done ", c.log.text());
}

test "an OOM pad announce fails one client and still serves every other seat once" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator, tablet_v2_version);
    defer ts.deinit();

    const a = try ts.addPeer(tablet_v2_version);
    const b = try ts.addPeer(tablet_v2_version);
    const c = try ts.addPeer(tablet_v2_version);

    // No path, so the descriptor copy is skipped: 0 the PadHw, 1 the
    // registry slot, 2 the PadClient for the FIRST seat.
    var live = LiveBytes{ .inner = allocator, .fail_index = 2 };
    ts.tablet.?.allocator = live.allocator();
    _ = try ts.tablet.?.addPad(.{ .buttons = 1 });
    ts.tablet.?.allocator = allocator;

    try std.testing.expectEqual(@as(usize, 2), ts.tablet.?.pads.items[0].clients.items.len);
    // postOutOfMemory only posts, so a's seat is still listed here.
    try std.testing.expectEqual(@as(usize, 3), ts.tablet.?.seats.items.len);
    try std.testing.expectError(error.ClientDispatchFailed, a.pump());
    try std.testing.expectEqual(@as(usize, 3), ts.tablet.?.seats.items.len);
    try b.pump();
    try c.pump();
    try std.testing.expectEqualStrings("pad_added pad_buttons pad_done ", b.log.text());
    try std.testing.expectEqualStrings("pad_added pad_buttons pad_done ", c.log.text());
}
