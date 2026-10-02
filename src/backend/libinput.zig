//! libinput input backend (evdev path).
//!
//! Feeds the seat from libinput's udev seat enumeration: virtual and real
//! keyboards, mice and touch devices appear as `new_input` announcements
//! and their events translate into seat calls. The structure follows
//! wlroots backend/libinput/backend.c (context lifecycle: create in start,
//! assign seat, drain initial devices, then dispatch on the fd) and
//! smithay src/backend/libinput/mod.rs (dispatch + drain loop).
//!
//! Wiring contract (the server orchestrator owns this, src/server/main.zig):
//!
//!   1. WAYLAND_LIBINPUT=1 selects this backend. The orchestrator creates
//!      it with the seat and the output size:
//!
//!          const base = try libinput_mod.LibinputBackend.create(
//!              allocator, io, &log_cfg, state.seat, "seat0",
//!              output_width, output_height,
//!          );
//!
//!   2. `base.start()` creates the libinput udev context, assigns the seat
//!      and drains the initial DEVICE_ADDED burst (all devices present on
//!      the seat are announced through the backend's `new_input` signal, so
//!      the compositor must attach its listener before start, same as
//!      `new_output`).
//!
//!   3. Poll `libinput_mod.LibinputBackend.fromBackend(base).pollFd()`
//!      (libinput_get_fd) on the event loop and call `dispatch()` when the
//!      fd is readable:
//!
//!          const li = libinput_mod.LibinputBackend.fromBackend(base);
//!          const src = try loop.addFd(*libinput_mod.Libinput, li.pollFd(),
//!              .{ .readable = true }, onLibinputFd, li);
//!
//!          fn onLibinputFd(_: c_int, _: wire.EventMask,
//!              li: *libinput_mod.Libinput) c_int {
//!              li.dispatch() catch {
//!                  log.err("libinput dispatch failed", io, &log_cfg,
//!                      "server", .{});
//!                  return 0;
//!              };
//!              return 1; // keep the source armed
//!          }
//!
//!   4. Devices appearing and disappearing while the server runs: poll
//!      `libinput_mod.LibinputBackend.fromBackend(base).hotplugPollFd()`
//!      (the udev monitor; -1 when the monitor could not be created) and
//!      call `dispatchHotplug()` when it is readable. libinput's own udev
//!      context also posts DEVICE_ADDED/DEVICE_REMOVED for hotplugged
//!      devices (libinput.h:3661-3662) and `dispatch()` consumes those; the
//!      monitor adds the node-identity bookkeeping and the touch-point
//!      cancel a removed touchscreen owes its client (see "Hotplug").
//!
//!   5. `base.destroy()` tears everything down (device registry, context,
//!      udev, udev monitor).
//!
//! Keycode translation: libinput reports evdev scancodes; the seat expects
//! xkb keycodes (evdev + 8), the same offset xkbcommon applies — wlroots
//! does `event->keycode + 8` before xkb_state_update_key
//! (types/wlr_keyboard.c:120). See `evdevToXkb`.
//!
//! Pointer translation:
//!   - relative motion (dx/dy) accumulates into the backend's cursor
//!     position (f64) and feeds seat.pointerMotion rounded to pixels;
//!   - absolute motion (the VM's virtio-mouse, and the uinput test mouse
//!     with ABS_X/ABS_Y 0..0xFFFF) is normalized to 0..1 via
//!     libinput_event_pointer_get_absolute_{x,y}_transformed(ev, 1) — the
//!     exact call wlroots uses for POINTER_MOTION_ABSOLUTE — then scaled
//!     to the output size by `scaleToOutput`;
//!   - buttons pass through as-is (libinput button codes are the linux
//!     BTN_* codes the seat already expects);
//!   - axis: wheel scrolls come from LIBINPUT_EVENT_POINTER_SCROLL_WHEEL,
//!     the libinput 1.19+ event that carries v120-normalized deltas
//!     (libinput_event_pointer_get_scroll_value_v120, ±120 per logical
//!     click — the wlroots choice, backend/libinput/events.c:169-183).
//!     `v120ToNotches` normalizes the v120 delta to the seat's legacy
//!     click convention; the value (degrees, 15.0 per notch) converts via
//!     `axisValueToPixels` to the seat's 10 px per notch. The legacy
//!     LIBINPUT_EVENT_POINTER_AXIS event is consumed only for the
//!     FINGER/CONTINUOUS sources (touchpad/trackpoint): those are
//!     cursor-equivalent units (1.0 = 1 px, passed through as-is,
//!     matching wlroots backend/libinput/pointer.c:146) and their
//!     SCROLL_FINGER/CONTINUOUS twins are ignored to avoid double
//!     delivery (libinput posts both families; libinput.h:811-826). The
//!     source rides along to the seat as wl_pointer.axis_source.
//!
//! Touch translation:
//!   - the touchpoint id is libinput's SEAT SLOT
//!     (libinput_event_touch_get_seat_slot: a non-negative, seat-wide
//!     unique id for an active touch point, libinput.h:1818-1840).
//!     libinput 1.31 has no libinput_event_touch_get_touch_id (the seat
//!     slot replaced it; verified in the 1.31.3 header and its symbol
//!     table), and the seat slot is exactly what wl_touch's per-point id
//!     needs: one id per live point, unique across the seat. A negative
//!     value never comes from a well-formed touch event and would alias a
//!     client's id space, so the event is dropped;
//!   - coordinates use the pointer path's conversion, unchanged:
//!     libinput_event_touch_get_{x,y}_transformed(ev, 1) normalizes to
//!     0..1 and scaleToOutput maps that onto the output. libinput.h:
//!     1880-1919 documents the same value for a screen-width argument, so
//!     this two-step is numerically identical to handing libinput the
//!     output size, and keeps a single conversion in the backend;
//!   - TOUCH_CANCEL is the device-wide cancel (libinput cancels every
//!     active point of the device that sent it), so it maps onto
//!     seat.touchCancel() with no id;
//!   - a device that disappears while points are down still owes its
//!     client a wl_touch.cancel (wayland.xml touch.cancel: sent when the
//!     touch points are removed, which an unplugged touchscreen does), and
//!     that is what the removal path below delivers.
//!
//! Tablet translation: the graphics-tablet half of libinput feeds the
//! zwp_tablet_manager_v2 registry in shell/tablet.zig, which is attached
//! with LibinputBackend.attachTablet before start().
//!
//!   - DEVICE_ADDED registers the hardware: a node with
//!     LIBINPUT_DEVICE_CAP_TABLET_TOOL becomes a zwp_tablet_v2 (name, the
//!     vendor/product ids and the bus type bustype), a node with
//!     LIBINPUT_DEVICE_CAP_TABLET_PAD a zwp_tablet_pad_v2 with one
//!     zwp_tablet_pad_group_v2 per libinput MODE GROUP (buttons, rings,
//!     strips, dials and mode count per group, libinput_tablet_pad_mode_
//!     group_has_*, libinput.h:558-612). Registration happens in
//!     announceDevice — the ONE announcement path — so a tablet already
//!     plugged in when the server starts is registered by the initial
//!     drain, not only on hotplug;
//!   - TABLET_TOOL_PROXIMITY is the tool lifecycle. libinput reports a
//!     tool only from its first proximity_in (libinput.h:2800-2810), so
//!     that is where the zwp_tablet_tool_v2 is created — type,
//!     hardware_serial (only when libinput_tablet_tool_is_unique says the
//!     serial identifies the physical tool), hardware_id_wacom and the
//!     capability burst from libinput_tablet_tool_has_* — and where
//!     proximity_in goes out. The tool stays REGISTERED across
//!     in/out cycles: one pen is one zwp_tablet_tool_v2 for as long as it
//!     is on the tablet, and what matches a later proximity_in to it is
//!     libinput's own identity rule (serial when unique, tool type
//!     otherwise, libinput.h:3086-3125). A pointer to the
//!     libinput_tablet_tool cannot be that key: libinput destroys that
//!     struct on proximity out unless the caller refs it;
//!   - the focus surface of a proximity_in and of a pad enter/leave is
//!     the seat's POINTER focus — where the tablet cursor points, the
//!     surface wlroots feeds a tablet from the cursor focus. A pen that
//!     comes into proximity before anything is focused under the cursor
//!     is entered from the next tablet event instead of being dropped;
//!     a pad has no libinput focus event at all, so it takes focus on
//!     its first event and follows the pointer focus from there;
//!   - removal (either hotplug path) is the reverse order the protocol
//!     requires: a tool in proximity gets proximity_out BEFORE removed
//!     (tablet-v2.xml:361-373), a focused pad gets leave before removed,
//!     and the pad goes before the tablet it hangs off
//!     (tablet-v2.xml:1209-1211);
//!   - TABLET_TOOL_AXIS (motion, pressure, distance, tilt, rotation,
//!     slider, wheel, size), TABLET_TOOL_TIP, TABLET_TOOL_BUTTON and the
//!     pad's ring/strip/dial/button/key data are DROPPED: the vendored
//!     protocol declares them (tablet-v2.xml:414-563, 737-895,
//!     1185-1193, 1264-1290) and wlroots sends them, but
//!     shell/tablet.zig's surface is the announcement tree plus
//!     proximity and pad focus, so there is nothing to relay them to.
//!
//! Frame batching: libinput closes every touch sample with
//! LIBINPUT_EVENT_TOUCH_FRAME (libinput.h:877-881), and a batch still open
//! when the event queue drains is closed at the end of dispatch() — the
//! boundary the pointer batch closes at too (the server closes the pointer
//! batch once per event-loop iteration, right after the libinput dispatch,
//! main.zig:2796-2797). Either way exactly one wl_touch.frame per batch,
//! never one per event: wayland.xml requires the frame to close an input
//! batch. (Seat.pointerFrame also flushes a touch frame still pending,
//! seat.zig:1039, so the close here is what keeps TWO libinput batches
//! inside one dispatch from reaching the client as one frame — and it
//! sends nothing when the batch delivered no touch event.)
//!
//! Hotplug: start() opens a libudev monitor on the "udev" netlink group,
//! filtered to the input subsystem, so devices appearing and disappearing
//! while the server runs are noticed, not just the ones present at
//! startup. Both hotplug paths (libinput's DEVICE_ADDED/REMOVED and the
//! monitor) meet in ONE registry keyed by the kernel node name
//! (libinput_device_get_sysname, "event5"), so a device is announced once
//! whichever path sees it first:
//!   - `add`: the announcement stays with libinput's DEVICE_ADDED, because
//!     InputDevice.kind needs libinput's capability classification of a
//!     libinput_device handle and libinput 1.31 exposes no udev -> device
//!     lookup (no libinput_device_get_device_from_udev_device in the 1.31.3
//!     header or in its symbol table). The monitor logs the appearance and
//!     leaves the announcement to the one path that can classify the
//!     device; the registry's node-name dedup keeps that announcement
//!     single whichever path runs first;
//!   - `remove`: the entry is pruned by node name and the points that
//!     device holds down are cancelled. Idempotent with libinput's own
//!     DEVICE_REMOVED — whichever lands first wins, the other finds
//!     nothing — so a touchscreen unplugged mid-gesture still gets its
//!     wl_touch.cancel.
//!
//! Device removal is announced: Backend.events.input_removed carries the
//! same identity new_input used (backend/backend.zig:36-48) and the seat
//! withdraws a capability on the LAST removal of that kind
//! (Seat.inputDeviceRemoved, compositor/seat.zig). Both hotplug paths
//! meet in removeDeviceAt, so the pair is emitted once whichever path
//! wins the race.
//!
//! Test path: no real devices exist on the dev host, so the pure logic
//! (offset, scaling, axis conversion, event-type mapping, capability
//! mapping, touchpoint translation, frame batching, registry add/remove/
//! dedup, the tablet enums and the tablet mode-group counts) is
//! unit-tested below, and the tablet translation itself is driven
//! against a REAL zwp_tablet_manager_v2 with a real client over a
//! socketpair (shell/tablet.zig's TestServer): a fabricated tool event
//! goes through the same handleTabletToolEvent/focusTabletPad the FFI
//! path uses, and the client-side event log pins the order. The device
//! path is exercised in the VM: scripts/uinput-devices.py creates a
//! virtual keyboard + absolute mouse through /dev/uinput, which udev
//! announces to this backend (a virtual touchscreen or tablet needs the
//! same treatment for the TOUCH_* / TABLET_* paths).
//!
//! Imports: utils/*, backend/backend.zig, compositor/seat.zig and
//! shell/tablet.zig (sibling modules). The libinput C library is linked
//! by the orchestrator (linkSystemLibrary("libinput") + libudev, which
//! ships with systemd).

const std = @import("std");
const log_mod = @import("../utils/log.zig");
const backend = @import("backend.zig");
const seat_mod = @import("../compositor/seat.zig");
const surface_mod = @import("../compositor/surface.zig");
const tablet_mod = @import("../shell/tablet.zig");
const server = @import("protocol").server;

// ---------------------------------------------------------------------------
// Constants — numeric values verified against the real headers:
//   libinput:   /nix/store/25z81mr9anpamdwv7lizq5l56hhq6kmi-libinput-1.31.3-dev/include/libinput.h
//   input codes: /nix/store/1hrk7xhpm6h98n0lg1qixfrr2kb96zqs-linux-headers-6.18.7/include/linux/input-event-codes.h
// ---------------------------------------------------------------------------

/// enum libinput_event_type (libinput.h:775-1040).
pub const event_device_added: c_int = 1;
pub const event_device_removed: c_int = 2;
pub const event_keyboard_key: c_int = 300;
pub const event_pointer_motion: c_int = 400;
pub const event_pointer_motion_absolute: c_int = 401;
pub const event_pointer_button: c_int = 402;
pub const event_pointer_axis: c_int = 403;
pub const event_pointer_scroll_wheel: c_int = 404;
pub const event_pointer_scroll_finger: c_int = 405;
pub const event_pointer_scroll_continuous: c_int = 406;

/// The touch block of enum libinput_event_type (libinput.h:873-881): touch
/// events are their own numeric range, 500..504, separate from the pointer
/// block (400..). The order within the block is DOWN, UP, MOTION, CANCEL,
/// FRAME — motion comes AFTER up, not between down and up.
pub const event_touch_down: c_int = 500;
pub const event_touch_up: c_int = 501;
pub const event_touch_motion: c_int = 502;
pub const event_touch_cancel: c_int = 503;
/// Ends a set of touchpoints of one device sample; carries no coordinate
/// data (libinput.h:877-881). This is the touch batch boundary.
pub const event_touch_frame: c_int = 504;

/// The tablet tool block of enum libinput_event_type (libinput.h:600-603).
/// Motion, pressure, distance, tilt, rotation, slider, wheel and size all
/// arrive as one AXIS event with a per-axis "has changed" accessor
/// (libinput.h:2187-2410) — libinput 1.31 has no separate motion or
/// pressure event — and TIP carries the down/up contact state.
pub const event_tablet_tool_axis: c_int = 600;
pub const event_tablet_tool_proximity: c_int = 601;
pub const event_tablet_tool_tip: c_int = 602;
pub const event_tablet_tool_button: c_int = 603;
/// The tablet pad block (libinput.h:700-704).
pub const event_tablet_pad_button: c_int = 700;
pub const event_tablet_pad_ring: c_int = 701;
pub const event_tablet_pad_strip: c_int = 702;
pub const event_tablet_pad_key: c_int = 703;
pub const event_tablet_pad_dial: c_int = 704;

/// enum libinput_tablet_tool_proximity_state (libinput.h:1329-1352): the
/// tool is over the tablet / has left it.
pub const tablet_proximity_state_out: c_int = 0;
pub const tablet_proximity_state_in: c_int = 1;

/// enum libinput_tablet_tool_type (libinput.h:2888-2909): 1..8 in
/// declaration order. It has NO finger member — fingers on a digitizer
/// arrive as TOUCH_* events from LIBINPUT_DEVICE_CAP_TOUCH — so no
/// libinput tool type maps onto zwp_tablet_tool_v2.type finger here.
pub const tablet_tool_type_pen: c_int = 1;
pub const tablet_tool_type_eraser: c_int = 2;
pub const tablet_tool_type_brush: c_int = 3;
pub const tablet_tool_type_pencil: c_int = 4;
pub const tablet_tool_type_airbrush: c_int = 5;
pub const tablet_tool_type_mouse: c_int = 6;
pub const tablet_tool_type_lens: c_int = 7;
pub const tablet_tool_type_totem: c_int = 8;

/// The BUS_* ids zwp_tablet_v2.bustype enumerates (linux/input.h): the
/// protocol's enum values ARE those numbers (tablet-v2.xml:660-682
/// declares usb = 0x03, bluetooth = 0x05, virtual = 0x06, serial =
/// BUS_I8042 = 0x11, i2c = 0x18), which is what
/// libinput_device_get_id_bustype returns (libinput.h:4343-4352).
pub const bus_usb: c_int = 0x03;
pub const bus_bluetooth: c_int = 0x05;
pub const bus_virtual: c_int = 0x06;
pub const bus_serial: c_int = 0x11;
pub const bus_i2c: c_int = 0x18;

/// enum libinput_key_state (libinput.h:222-225).
pub const key_state_pressed: c_int = 1;
/// enum libinput_button_state (libinput.h:246-249).
pub const button_state_pressed: c_int = 1;

/// enum libinput_pointer_axis (libinput.h:263-266).
pub const pointer_axis_scroll_vertical: c_int = 0;
pub const pointer_axis_scroll_horizontal: c_int = 1;
/// enum libinput_pointer_axis_source (libinput.h:278-302). WHEEL_TILT
/// is deprecated (never sent by any device since libinput 1.16); the
/// others map onto wl_pointer.axis_source via axisSourceFromLibinput.
pub const pointer_axis_source_wheel: c_int = 1;
pub const pointer_axis_source_finger: c_int = 2;
pub const pointer_axis_source_continuous: c_int = 3;
pub const pointer_axis_source_wheel_tilt: c_int = 4;

/// enum libinput_log_priority (libinput.h:195-197).
pub const log_priority_debug: c_int = 10;
pub const log_priority_info: c_int = 20;
pub const log_priority_error: c_int = 30;

/// enum libinput_device_capability (libinput.h:207-213). TABLET_TOOL is the
/// graphics-tablet capability (the digitizer a pen or a finger rides on),
/// TABLET_PAD the pad with buttons/strip/ring.
pub const device_cap_keyboard: c_int = 0;
pub const device_cap_pointer: c_int = 1;
pub const device_cap_touch: c_int = 2;
pub const device_cap_tablet_tool: c_int = 3;
pub const device_cap_tablet_pad: c_int = 4;
pub const device_cap_gesture: c_int = 5;
pub const device_cap_switch: c_int = 6;

/// Every capability enum value in order: libinput_device_has_capability
/// takes ONE capability and answers a bool (libinput.h:4338), so a
/// device's full set is read one call at a time into the mask that
/// kindForCaps classifies.
pub const device_cap_all = [_]c_int{
    device_cap_keyboard,
    device_cap_pointer,
    device_cap_touch,
    device_cap_tablet_tool,
    device_cap_tablet_pad,
    device_cap_gesture,
    device_cap_switch,
};

/// enum libinput_led (libinput.h:232-238): the bitmask
/// libinput_device_led_update accepts. The values match the wlroots
/// WLR_LED_* layout (wlr_keyboard.h:22-24), which derives them from the
/// xkb_state led indexes (numlock=0, capslock=1) — see ledsFromModsLocked.
pub const led_num_lock: c_int = 1 << 0;
pub const led_caps_lock: c_int = 1 << 1;
pub const led_scroll_lock: c_int = 1 << 2;

/// linux/input-event-codes.h:357-359 (BTN_*). The seat exports the same
/// values (seat.btn_left == 272); these exist for the registry mapping and
/// tests.
pub const btn_left: u32 = 0x110; // 272
pub const btn_right: u32 = 0x111; // 273
pub const btn_middle: u32 = 0x112; // 274

/// evdev scancode -> xkb keycode offset (xkbcommon adds 8; the seat
/// forwards these codes in wl_keyboard.key).
pub const evdev_to_xkb_offset: u32 = 8;

// ---------------------------------------------------------------------------
// FFI (hand-written extern decls, same style as compositor/xkb.zig)
// ---------------------------------------------------------------------------

const c = struct {
    pub const libinput = opaque {};
    pub const libinput_event = opaque {};
    pub const libinput_event_keyboard = opaque {};
    pub const libinput_event_pointer = opaque {};
    pub const libinput_device = opaque {};
    pub const libinput_event_touch = opaque {};
    pub const udev = opaque {};
    pub const udev_monitor = opaque {};
    pub const udev_device = opaque {};

    /// struct libinput_interface (libinput.h:3604-3621): device fd
    /// open/close callbacks. libinput never opens evdev nodes itself.
    pub const libinput_interface = extern struct {
        open_restricted: *const fn (path: [*:0]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int,
        close_restricted: *const fn (fd: c_int, user_data: ?*anyopaque) callconv(.c) void,
    };

    // Context lifecycle (libinput.h "base" group).
    extern fn libinput_udev_create_context(
        interface: *const libinput_interface,
        user_data: ?*anyopaque,
        udev: ?*udev,
    ) ?*libinput;
    extern fn libinput_udev_assign_seat(li: ?*libinput, seat_id: [*:0]const u8) c_int;
    extern fn libinput_get_fd(li: ?*libinput) c_int;
    extern fn libinput_dispatch(li: ?*libinput) c_int;
    /// Retrieve the next queued event (NULL when the queue is empty).
    /// libinput_next_event in pre-1.0.4 docs; the 1.31 header names it
    /// libinput_get_event (libinput.h:3884).
    extern fn libinput_get_event(li: ?*libinput) ?*libinput_event;
    extern fn libinput_event_destroy(event: ?*libinput_event) void;
    extern fn libinput_unref(li: ?*libinput) ?*libinput;

    // Log handler (libinput.h:4000-4071): the callback receives
    // (context, priority, printf format, va_list) — no user_data — and is
    // installed with libinput_log_set_handler after context creation.
    pub const libinput_log_handler = *const fn (
        li: ?*libinput,
        priority: c_int,
        format: [*:0]const u8,
        args: *std.builtin.VaList,
    ) callconv(.c) void;
    extern fn libinput_log_set_handler(li: ?*libinput, handler: libinput_log_handler) void;
    extern fn libinput_log_set_priority(li: ?*libinput, priority: c_int) void;
    /// libc vsnprintf — the only way to consume the handler's va_list.
    extern fn vsnprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, args: *std.builtin.VaList) c_int;

    // Event accessors (libinput.h "event" group).
    extern fn libinput_event_get_type(event: ?*libinput_event) c_int;
    extern fn libinput_event_get_device(event: ?*libinput_event) ?*libinput_device;
    extern fn libinput_event_get_keyboard_event(event: ?*libinput_event) ?*libinput_event_keyboard;
    extern fn libinput_event_get_pointer_event(event: ?*libinput_event) ?*libinput_event_pointer;

    // Touch events (libinput.h:1138, 1783-1928).
    extern fn libinput_event_get_touch_event(event: ?*libinput_event) ?*libinput_event_touch;
    /// The seat slot: a non-negative, seat-wide unique id for an active
    /// touch point (libinput.h:1818-1840). libinput 1.31 has no
    /// libinput_event_touch_get_touch_id — the seat slot replaced it.
    extern fn libinput_event_touch_get_seat_slot(event: ?*libinput_event_touch) i32;
    /// Coordinates normalized to the `width` argument (the output screen
    /// width; 1 normalizes to 0..1, which is the pointer path's call
    /// shape). libinput.h:1880-1919.
    extern fn libinput_event_touch_get_x_transformed(event: ?*libinput_event_touch, width: u32) f64;
    extern fn libinput_event_touch_get_y_transformed(event: ?*libinput_event_touch, height: u32) f64;

    // Keyboard events (libinput.h:1258-1268).
    extern fn libinput_event_keyboard_get_key(event: ?*libinput_event_keyboard) u32;
    extern fn libinput_event_keyboard_get_key_state(event: ?*libinput_event_keyboard) c_int;

    // Pointer events (libinput.h:1340-1666).
    extern fn libinput_event_pointer_get_dx(event: ?*libinput_event_pointer) f64;
    extern fn libinput_event_pointer_get_dy(event: ?*libinput_event_pointer) f64;
    extern fn libinput_event_pointer_get_absolute_x_transformed(event: ?*libinput_event_pointer, width: u32) f64;
    extern fn libinput_event_pointer_get_absolute_y_transformed(event: ?*libinput_event_pointer, height: u32) f64;
    extern fn libinput_event_pointer_get_button(event: ?*libinput_event_pointer) u32;
    extern fn libinput_event_pointer_get_button_state(event: ?*libinput_event_pointer) c_int;
    extern fn libinput_event_pointer_has_axis(event: ?*libinput_event_pointer, axis: c_int) c_int;
    extern fn libinput_event_pointer_get_axis_value(event: ?*libinput_event_pointer, axis: c_int) f64;
    extern fn libinput_event_pointer_get_axis_value_discrete(event: ?*libinput_event_pointer, axis: c_int) f64;
    extern fn libinput_event_pointer_get_axis_source(event: ?*libinput_event_pointer) c_int;
    // SCROLL_* accessors (libinput.h:1667-1760, @since 1.19): the wheel
    // event's value in degrees and its v120-normalized delta.
    extern fn libinput_event_pointer_get_scroll_value(event: ?*libinput_event_pointer, axis: c_int) f64;
    extern fn libinput_event_pointer_get_scroll_value_v120(event: ?*libinput_event_pointer, axis: c_int) f64;

    // Tablet tool events (libinput.h:1166-1173, 2165-2870, 2888-3260).
    // libinput owns the libinput_tablet_tool and destroys it on proximity
    // out unless the caller refs it (libinput.h:3110-3125), so nothing
    // here holds it past the event that produced it.
    pub const libinput_event_tablet_tool = opaque {};
    pub const libinput_tablet_tool = opaque {};
    extern fn libinput_event_get_tablet_tool_event(event: ?*libinput_event) ?*libinput_event_tablet_tool;
    extern fn libinput_event_tablet_tool_get_tool(event: ?*libinput_event_tablet_tool) ?*libinput_tablet_tool;
    extern fn libinput_event_tablet_tool_get_proximity_state(event: ?*libinput_event_tablet_tool) c_int;
    extern fn libinput_tablet_tool_get_type(tool: ?*libinput_tablet_tool) c_int;
    extern fn libinput_tablet_tool_get_tool_id(tool: ?*libinput_tablet_tool) u64;
    extern fn libinput_tablet_tool_get_serial(tool: ?*libinput_tablet_tool) u64;
    /// Whether the serial identifies this physical tool (libinput.h:3086-
    /// 3104). A tool libinput cannot single out has a shared object per
    /// type, so its serial must not be announced.
    extern fn libinput_tablet_tool_is_unique(tool: ?*libinput_tablet_tool) c_int;
    extern fn libinput_tablet_tool_has_pressure(tool: ?*libinput_tablet_tool) c_int;
    extern fn libinput_tablet_tool_has_distance(tool: ?*libinput_tablet_tool) c_int;
    extern fn libinput_tablet_tool_has_tilt(tool: ?*libinput_tablet_tool) c_int;
    extern fn libinput_tablet_tool_has_rotation(tool: ?*libinput_tablet_tool) c_int;
    extern fn libinput_tablet_tool_has_slider(tool: ?*libinput_tablet_tool) c_int;
    extern fn libinput_tablet_tool_has_wheel(tool: ?*libinput_tablet_tool) c_int;

    // The pad's own data (libinput.h:3280-3440: button number/state, ring
    // position, strip position, dial delta, keys) has no home in
    // zwp_tablet_manager_v2 as shell/tablet.zig implements it, and pad
    // focus is a compositor decision libinput never reports, so none of
    // the tablet_pad_event accessors is declared: the pad events this
    // backend handles say only "this pad is in use".

    // Device accessors (libinput.h:4338, 4490).
    extern fn libinput_device_get_name(device: ?*libinput_device) [*:0]const u8;
    /// Kernel node name ("event5", libinput.h:4321-4322): the device's
    /// identity in the udev stream and the registry's dedup key.
    extern fn libinput_device_get_sysname(device: ?*libinput_device) [*:0]const u8;
    extern fn libinput_device_has_capability(device: ?*libinput_device, capability: c_int) c_int;
    // LED sync (libinput.h:4481): push the keyboard LED state
    // (numlock/capslock) to the device's LEDs (wlroots
    // backend/libinput/keyboard.c keyboard_set_leds).
    extern fn libinput_device_led_update(device: ?*libinput_device, leds: c_int) void;

    // Tablet hardware facts (libinput.h:4343-4375, 456-612, 4590-4641).
    extern fn libinput_device_get_id_vendor(device: ?*libinput_device) c_uint;
    extern fn libinput_device_get_id_product(device: ?*libinput_device) c_uint;
    extern fn libinput_device_get_id_bustype(device: ?*libinput_device) c_uint;
    extern fn libinput_device_tablet_pad_get_num_buttons(device: ?*libinput_device) c_uint;
    extern fn libinput_device_tablet_pad_get_num_rings(device: ?*libinput_device) c_uint;
    extern fn libinput_device_tablet_pad_get_num_strips(device: ?*libinput_device) c_uint;
    extern fn libinput_device_tablet_pad_get_num_dials(device: ?*libinput_device) c_uint;
    pub const libinput_tablet_pad_mode_group = opaque {};
    extern fn libinput_device_tablet_pad_get_num_mode_groups(device: ?*libinput_device) c_int;
    /// `index` is a MODE GROUP index, 0-based (libinput.h:478-485) — not
    /// a mode index. The returned group is unrefcounted and only valid
    /// until the next libinput call, so it is read and dropped.
    extern fn libinput_device_tablet_pad_get_mode_group(device: ?*libinput_device, index: c_uint) ?*libinput_tablet_pad_mode_group;
    extern fn libinput_tablet_pad_mode_group_get_num_modes(group: ?*libinput_tablet_pad_mode_group) c_uint;
    extern fn libinput_tablet_pad_mode_group_has_button(group: ?*libinput_tablet_pad_mode_group, button: c_uint) c_int;
    extern fn libinput_tablet_pad_mode_group_has_ring(group: ?*libinput_tablet_pad_mode_group, ring: c_uint) c_int;
    extern fn libinput_tablet_pad_mode_group_has_strip(group: ?*libinput_tablet_pad_mode_group, strip: c_uint) c_int;
    extern fn libinput_tablet_pad_mode_group_has_dial(group: ?*libinput_tablet_pad_mode_group, dial: c_uint) c_int;

    // libudev: a plain context for device enumeration (libinput needs an
    // initialized udev; wlroots passes its session's).
    extern fn udev_new() ?*udev;
    extern fn udev_unref(udev: ?*udev) ?*udev;

    // libudev monitor: the hotplug watch on the input subsystem. The
    // "udev" netlink group carries the events udevd processed (the
    // "kernel" group would carry the raw kernel uevents before any udev
    // rule ran); a device node is ready to open only after udevd handled
    // it, which is the same stream libinput's own udev context follows.
    extern fn udev_monitor_new_from_netlink(udev: ?*udev, name: [*:0]const u8) ?*udev_monitor;
    /// NULL devtype matches every device of the subsystem (/dev/input's
    /// event nodes and their parents alike).
    extern fn udev_monitor_filter_add_match_subsystem_devtype(monitor: ?*udev_monitor, subsystem: [*:0]const u8, devtype: ?[*:0]const u8) c_int;
    extern fn udev_monitor_enable_receiving(monitor: ?*udev_monitor) c_int;
    extern fn udev_monitor_get_fd(monitor: ?*udev_monitor) c_int;
    /// One queued device event, owned by the caller (unref it), or NULL
    /// when the queue is empty.
    extern fn udev_monitor_receive_device(monitor: ?*udev_monitor) ?*udev_device;
    extern fn udev_monitor_unref(monitor: ?*udev_monitor) ?*udev_monitor;
    /// "add"/"remove"/"change"/... (NULL for an enumerated device that
    /// never had an action).
    extern fn udev_device_get_action(device: ?*udev_device) ?[*:0]const u8;
    extern fn udev_device_get_sysname(device: ?*udev_device) ?[*:0]const u8;
    extern fn udev_device_unref(device: ?*udev_device) ?*udev_device;
};

/// The kind enum of backend.Backend.InputDevice (anonymous in backend.zig;
/// recovered for the registry and announcements).
// SAFETY: type-derivation only; the undefined value is never evaluated at runtime.
const InputKind = @TypeOf(@as(backend.Backend.InputDevice, undefined).kind);

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested below)
// ---------------------------------------------------------------------------

/// evdev scancode -> xkb keycode (the seat's keyEvent contract).
pub fn evdevToXkb(scancode: u32) u32 {
    return scancode + evdev_to_xkb_offset;
}

/// Normalized (0..1) absolute coordinate -> output pixel coordinate.
/// libinput_event_pointer_get_absolute_{x,y}_transformed(ev, 1) yields the
/// normalized form; wlroots then maps it onto the output (wlr_cursor).
pub fn scaleToOutput(normalized: f64, size: u32) f64 {
    return normalized * @as(f64, @floatFromInt(size));
}

/// libinput wheel axis value (degrees, 15.0 per notch) -> the seat's pixel
/// convention (10 px per notch; the raylib input source uses the same
/// wheel * 10.0 formula with wheel in notches).
pub fn axisValueToPixels(value: f64) f64 {
    return value * (10.0 / 15.0);
}

/// libinput discrete axis value (physical wheel clicks) -> i32 notches.
pub fn axisDiscreteToNotches(value: f64) i32 {
    return @intFromFloat(@round(value));
}

/// libinput axis source -> wl_pointer.axis_source. Mirrors wlroots'
/// axis_source_from_libinput (backend/libinput/pointer.c:69-86).
pub fn axisSourceFromLibinput(source: c_int) ?server.wl.Pointer.AxisSource {
    return switch (source) {
        pointer_axis_source_wheel => .wheel,
        pointer_axis_source_finger => .finger,
        pointer_axis_source_continuous => .continuous,
        pointer_axis_source_wheel_tilt => .wheel_tilt,
        else => null,
    };
}

/// Scale a libinput axis value to seat pixels for the given source.
/// WHEEL is degrees (15.0 per notch) -> the seat's 10 px per notch via
/// axisValueToPixels; FINGER/CONTINUOUS are cursor-equivalent units
/// (1.0 = 1 px, libinput.h:1598-1599, 1614-1617) that pass through
/// unscaled, the same pass-through wlroots does
/// (backend/libinput/pointer.c:146).
pub fn axisValueToPixelsSource(source: server.wl.Pointer.AxisSource, value: f64) f64 {
    return switch (source) {
        .wheel, .wheel_tilt => axisValueToPixels(value),
        .finger, .continuous => value,
        _ => unreachable,
    };
}

/// Discrete (notches) for the source: WHEEL counts physical wheel clicks;
/// FINGER/CONTINUOUS discrete is always 0 (libinput.h:1653-1657).
pub fn axisDiscreteForSource(source: server.wl.Pointer.AxisSource, raw: f64) i32 {
    return switch (source) {
        .wheel, .wheel_tilt => axisDiscreteToNotches(raw),
        .finger, .continuous => 0,
        _ => unreachable,
    };
}

/// v120 scroll delta -> legacy notch count. libinput normalizes
/// high-resolution wheel deltas to ±120 per logical click
/// (libinput_event_pointer_get_scroll_value_v120, libinput.h:1712-1760:
/// "a value that is a fraction of ±120 indicates a wheel movement less
/// than one logical click"); one logical click is one legacy notch, so
/// dividing by 120 converts the v120 delta to the seat's legacy click
/// convention (10 px per notch, see axisValueToPixels). wlroots instead
/// forwards the raw v120 as delta_discrete (pointer.c:172-179); the seat
/// contract here is legacy clicks, so the normalization happens in the
/// backend.
pub fn v120ToNotches(v120: f64) i32 {
    return @intFromFloat(@round(v120 / 120.0));
}

/// Whether the zero-device startup check is enabled. Mirrors wlroots
/// env_parse_bool (util/env.c): only the literal "1" is truthy — any
/// other value (or an unset variable) leaves the check on.
pub fn zeroDeviceCheckEnabled(env_value: ?[*:0]const u8) bool {
    const v = env_value orelse return true;
    return !std.mem.eql(u8, std.mem.span(v), "1");
}

/// Keyboard LED bitmask from the seat's locked-modifier state. The seat
/// stores mods_locked in the wl_keyboard.modifiers layout (bit 1 = Lock
/// = Caps Lock, bit 4 = Mod2 = Num Lock; xkb.zig mods() doc). Mirrors
/// wlroots keyboard_led_update (types/wlr_keyboard.c:20-35), which
/// derives the WLR_LED_* bits from the xkb_state led indexes — the
/// standard evdev keymap indexes numlock=0 and capslock=1, so the
/// produced bits align with libinput's enum libinput_led
/// (LIBINPUT_LED_NUM_LOCK=1, LIBINPUT_LED_CAPS_LOCK=2).
pub fn ledsFromModsLocked(mods_locked: u32) c_int {
    var leds: c_int = 0;
    // Lock (bit 1) -> Caps Lock.
    if (mods_locked & (1 << 1) != 0) leds |= led_caps_lock;
    // Mod2 (bit 4) -> Num Lock.
    if (mods_locked & (1 << 4) != 0) leds |= led_num_lock;
    return leds;
}

/// Bit for one libinput capability in a capability mask: bit N is set for
/// capability N, so the mask follows the enum order of libinput.h:207-213.
pub fn capsBit(capability: c_int) u32 {
    return @as(u32, 1) << @intCast(capability);
}

/// Capability mask -> the backend's InputDevice kind. Devices are
/// classified by priority (keyboard > pointer > touch), unchanged for the
/// keyboard and pointer cases: a touchpad has pointer AND touch, so it
/// stays a pointer device and its finger events still arrive as TOUCH_*
/// events (wlroots registers a touchpad as a pointer device with a touch
/// capability too, backend/libinput/device.c:120-140).
///
/// Touch hardware is first class: a touch screen (TOUCH), a graphics
/// tablet (TABLET_TOOL) and a tablet pad (TABLET_PAD) all drive wl_touch,
/// whose events are surface-local points exactly like the digitizer
/// coordinates those devices report, so they map to the touch kind. Only
/// gesture- and switch-only devices stay unannounced: neither drives
/// wl_pointer nor wl_touch (wlroots maps those to no input device at all).
pub fn kindForCaps(caps: u32) ?InputKind {
    if (caps & capsBit(device_cap_keyboard) != 0) return .keyboard;
    if (caps & capsBit(device_cap_pointer) != 0) return .pointer;
    if (caps & capsBit(device_cap_touch) != 0) return .touch;
    if (caps & capsBit(device_cap_tablet_tool) != 0) return .touch;
    if (caps & capsBit(device_cap_tablet_pad) != 0) return .touch;
    return null;
}

/// A device's full capability mask, one libinput_device_has_capability
/// call per member (libinput.h:4338). kindForCaps classifies it; the
/// tablet registration needs it raw, because TABLET_TOOL and TABLET_PAD
/// both collapse to the touch KIND but are different hardware.
pub fn capsMask(dev: ?*c.libinput_device) u32 {
    var caps: u32 = 0;
    for (device_cap_all) |capability| {
        if (c.libinput_device_has_capability(dev, capability) != 0) {
            caps |= capsBit(capability);
        }
    }
    return caps;
}

/// libinput's tablet tool type -> zwp_tablet_tool_v2.type. Seven of the
/// eight libinput tool types (libinput.h:362-372) name one the protocol
/// declares, in the same order (tablet-v2.xml:265-272). The eighth,
/// totem, does not: it is a rotary device with positional and rotation
/// data (libinput.h:371-372) and zwp_tablet_tool_v2.type stops at lens,
/// so a totem has no type to be announced as. Finger is the gap the
/// other way — libinput has no finger tool type at all, a finger
/// arrives as a TOUCH_* event from LIBINPUT_DEVICE_CAP_TOUCH
/// (libinput.h:209). Neither is guessed at: null means the tool is not
/// registered (see addTabletTool).
pub fn tabletToolType(libinput_type: c_int) ?server.zwp.TabletToolV2.Type {
    return switch (libinput_type) {
        tablet_tool_type_pen => .pen,
        tablet_tool_type_eraser => .eraser,
        tablet_tool_type_brush => .brush,
        tablet_tool_type_pencil => .pencil,
        tablet_tool_type_airbrush => .airbrush,
        tablet_tool_type_mouse => .mouse,
        tablet_tool_type_lens => .lens,
        else => null,
    };
}

/// The axes libinput reports for one tool (libinput_tablet_tool_has_*).
pub const TabletToolAxes = struct {
    pressure: bool = false,
    distance: bool = false,
    tilt: bool = false,
    rotation: bool = false,
    slider: bool = false,
    wheel: bool = false,
};

/// zwp_tablet_tool_v2 declares exactly six capabilities (tablet-v2.xml:
/// 325-339), which is what a tool's burst can hold.
pub const tablet_capability_count = 6;

/// The zwp_tablet_tool_v2.capability burst of one tool, written into
/// `out` — which must hold `tablet_capability_count` slots, the number
/// the one caller allocates — and returned as the slice the ToolDesc
/// borrows. Emitted in the enum's own declaration order — tilt,
/// pressure, distance, rotation, slider, wheel (tablet-v2.xml:325-339)
/// — so the same tool always announces the same list in the same order.
/// The slice stays as valid as `out`, which is why the caller keeps the
/// array alive for as long as the tool is registered (see
/// TabletToolBinding).
pub fn tabletToolCapabilities(
    axes: TabletToolAxes,
    out: []server.zwp.TabletToolV2.Capability,
) []const server.zwp.TabletToolV2.Capability {
    var len: usize = 0;
    inline for (.{
        .{ .present = axes.tilt, .capability = server.zwp.TabletToolV2.Capability.tilt },
        .{ .present = axes.pressure, .capability = server.zwp.TabletToolV2.Capability.pressure },
        .{ .present = axes.distance, .capability = server.zwp.TabletToolV2.Capability.distance },
        .{ .present = axes.rotation, .capability = server.zwp.TabletToolV2.Capability.rotation },
        .{ .present = axes.slider, .capability = server.zwp.TabletToolV2.Capability.slider },
        .{ .present = axes.wheel, .capability = server.zwp.TabletToolV2.Capability.wheel },
    }) |entry| {
        if (entry.present) {
            out[len] = entry.capability;
            len += 1;
        }
    }
    return out[0..len];
}

/// BUS_* bus id -> zwp_tablet_v2.bustype. The protocol's enum values ARE
/// the BUS_ numbers, so this is a name lookup with no arithmetic. Null
/// for every bus the protocol does not enumerate: bustype is optional
/// (tablet-v2.xml:660-682) and no event means "unknown", which every
/// client must already handle — announcing a wrong one would not be.
pub fn tabletBustype(bus: c_int) ?server.zwp.TabletV2.Bustype {
    return switch (bus) {
        bus_usb => .usb,
        bus_bluetooth => .bluetooth,
        bus_virtual => .virtual,
        bus_serial => .serial,
        bus_i2c => .i2c,
        else => null,
    };
}

/// How many of `total` indices `owned` claims. libinput answers the
/// per-index question through libinput_tablet_pad_mode_group_has_button /
/// _has_ring / _has_strip / _has_dial (libinput.h:558-612) and the
/// protocol announces only HOW MANY of each a group has
/// (tablet-v2.xml:948-1005), so counting is the whole mapping. The
/// predicate is a parameter so the count is testable without a libinput
/// mode-group handle; the FFI path applies the same rule through
/// modeGroupAxisCount below, which takes the handle itself.
pub fn ownedCount(total: u32, owned: fn (index: u32) bool) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        if (owned(i)) count += 1;
    }
    return count;
}

/// libinput has one per-index predicate per kind of auxiliary axis
/// (libinput.h:558-612), so the three counts differ only in which
/// predicate answers.
const ModeGroupAxis = enum { ring, strip, dial };

/// How many of `total` indices of one kind `mode_group` claims — the
/// same count ownedCount makes, for a caller that holds a real mode
/// group. The handle is a parameter and not a captured local: Zig has
/// no closures, so a struct declared inside the loop that read the
/// groups cannot reach the loop's `mode_group`. `kind` picks the
/// predicate instead of a per-call struct.
fn modeGroupAxisCount(
    mode_group: ?*c.libinput_tablet_pad_mode_group,
    kind: ModeGroupAxis,
    total: u32,
) u32 {
    var count: u32 = 0;
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        if (modeGroupHasAxis(mode_group, kind, index)) count += 1;
    }
    return count;
}

/// Whether `mode_group` claims the axis `index` of one kind.
fn modeGroupHasAxis(
    mode_group: ?*c.libinput_tablet_pad_mode_group,
    kind: ModeGroupAxis,
    index: u32,
) bool {
    return switch (kind) {
        .ring => c.libinput_tablet_pad_mode_group_has_ring(mode_group, index) != 0,
        .strip => c.libinput_tablet_pad_mode_group_has_strip(mode_group, index) != 0,
        .dial => c.libinput_tablet_pad_mode_group_has_dial(mode_group, index) != 0,
    };
}

/// One libinput mode group of a pad: how many of the device's buttons,
/// rings, strips and dials it owns, and how many modes it has.
pub const TabletModeGroupInfo = struct {
    rings: u32 = 0,
    strips: u32 = 0,
    dials: u32 = 0,
    /// A group always has at least one mode; a device that reports none
    /// still has mode 0 (the `modes` event is then never sent,
    /// tablet-v2.xml:1000-1001).
    modes: u32 = 1,
};

/// The tablet facts of one libinput device. Filled from the FFI
/// accessors in readTabletInfo and fabricated by the tests, so the
/// descriptor construction it feeds is exercised without a device.
pub const TabletDeviceInfo = struct {
    /// zwp_tablet_v2.name. libinput's own string, borrowed by the caller
    /// of readTabletInfo and copied by addTablet.
    name: [:0]const u8,
    /// zwp_tablet_v2.id, announced only when `vendor` is non-zero
    /// (tablet-v2.xml:600-618).
    vendor: u32 = 0,
    product: u32 = 0,
    bustype: ?server.zwp.TabletV2.Bustype = null,
    rings: u32 = 0,
    strips: u32 = 0,
    dials: u32 = 0,
    /// One entry per libinput mode group, in mode-group index order.
    groups: []const TabletModeGroupInfo = &.{},
    /// One list per entry of `groups`: the GLOBAL button indices that
    /// group owns. libinput numbers pad buttons 0..n across the whole
    /// device and each belongs to at most one group
    /// (tablet-v2.xml:951-953), so the lists partition the pad.
    group_buttons: []const []const u32 = &.{},
};

/// Release what readTabletInfo allocated. The reader's caller owns it
/// until applyTabletInfo has taken its own copies.
fn freeTabletInfo(allocator: std.mem.Allocator, info: TabletDeviceInfo) void {
    for (info.group_buttons) |list| allocator.free(list);
    allocator.free(info.group_buttons);
    allocator.free(info.groups);
}

/// One translated touchpoint: the wl_touch id plus the coordinates in the
/// seat's f64 convention (output pixels, surface-local once the seat maps
/// them onto the focus surface).
pub const TouchPoint = struct {
    id: c_int,
    x: f64,
    y: f64,
};

/// The wl_touch id for libinput's seat slot (the value of
/// libinput_event_touch_get_seat_slot, libinput.h:1818-1840): non-negative
/// and seat-wide unique for an active touch point, which is exactly what
/// wayland.xml's wl_touch.down `id` must be. libinput 1.31 has no
/// libinput_event_touch_get_touch_id — the seat slot replaced it. A
/// negative value cannot come from a well-formed touch event and would
/// alias the client's id space, so the event is dropped instead.
pub fn touchPointId(seat_slot: i32) ?c_int {
    if (seat_slot < 0) return null;
    return @intCast(seat_slot);
}

/// Translate one libinput touch event into a wl_touch point. `nx`/`ny` are
/// the coordinates normalized to 0..1 by
/// libinput_event_touch_get_{x,y}_transformed(ev, 1) — the pointer path's
/// call shape — and scaleToOutput maps them onto the output, the same
/// conversion onPointerMotionAbsolute uses. Null when the seat slot is not
/// usable as a wl_touch id.
pub fn touchPoint(
    seat_slot: i32,
    nx: f64,
    ny: f64,
    width: u32,
    height: u32,
) ?TouchPoint {
    const id = touchPointId(seat_slot) orelse return null;
    return .{
        .id = id,
        .x = scaleToOutput(nx, width),
        .y = scaleToOutput(ny, height),
    };
}

/// wl_touch frame bookkeeping. libinput delivers a batch of touch events
/// per device sample and closes it with LIBINPUT_EVENT_TOUCH_FRAME; the
/// seat needs exactly one wl_touch.frame per batch, never one per event
/// (wayland.xml: the frame ends an input batch; wlroots
/// wlr_seat_touch_notify_frame, wlr_seat_touch.c:88-99). `flush` reports
/// whether a frame was owed, so an empty batch — and the batch after the
/// frame — both send nothing.
pub const TouchBatcher = struct {
    open: bool = false,

    /// A touch event went to the seat inside the current batch.
    pub fn note(self: *TouchBatcher) void {
        self.open = true;
    }

    /// Close the batch: true when a wl_touch.frame is owed (and the batch
    /// is closed now), false when the batch was empty.
    pub fn flush(self: *TouchBatcher) bool {
        const owed = self.open;
        self.open = false;
        return owed;
    }
};

/// The udev monitor notifications that change which devices exist.
pub const UdevAction = enum { add, remove };

/// udev action string -> UdevAction. Only "add" (the node appeared) and
/// "remove" (it disappeared) are device hotplug; "change" is a property
/// update on a device that is already there (a lid switch toggling, an
/// LED state write), and "bind"/"unbind"/"move"/"online" are driver
/// transitions, not an appearance or a removal.
pub fn udevActionFromName(name: []const u8) ?UdevAction {
    if (std.mem.eql(u8, name, "add")) return .add;
    if (std.mem.eql(u8, name, "remove")) return .remove;
    return null;
}

/// Event type -> name (debug logging and the dispatch mapping test).
pub fn eventTypeName(event_type: c_int) []const u8 {
    return switch (event_type) {
        event_device_added => "device added",
        event_device_removed => "device removed",
        event_keyboard_key => "keyboard key",
        event_pointer_motion => "pointer motion",
        event_pointer_motion_absolute => "pointer motion absolute",
        event_pointer_button => "pointer button",
        event_pointer_axis => "pointer axis",
        event_pointer_scroll_wheel => "pointer scroll wheel",
        event_pointer_scroll_finger => "pointer scroll finger",
        event_pointer_scroll_continuous => "pointer scroll continuous",
        event_touch_down => "touch down",
        event_touch_up => "touch up",
        event_touch_motion => "touch motion",
        event_touch_cancel => "touch cancel",
        event_touch_frame => "touch frame",
        event_tablet_tool_axis => "tablet tool axis",
        event_tablet_tool_proximity => "tablet tool proximity",
        event_tablet_tool_tip => "tablet tool tip",
        event_tablet_tool_button => "tablet tool button",
        event_tablet_pad_button => "tablet pad button",
        event_tablet_pad_ring => "tablet pad ring",
        event_tablet_pad_strip => "tablet pad strip",
        event_tablet_pad_key => "tablet pad key",
        event_tablet_pad_dial => "tablet pad dial",
        else => "other",
    };
}

// ---------------------------------------------------------------------------
// Backend implementation
// ---------------------------------------------------------------------------

/// How libinput identifies one physical tool: by serial when the tool is
/// uniquely identifiable, by tool type otherwise (libinput.h:3086-3125 —
/// "if the tool does not have a unique identifier, libinput creates a
/// single struct per tool type on each tablet"). That is the same
/// distinction zwp_tablet_tool_v2.hardware_serial draws
/// (tablet-v2.xml:286-299), so the same key maps a later proximity_in to
/// the zwp_tablet_tool_v2 already announced for that pen. The
/// libinput_tablet_tool pointer cannot be the key: libinput destroys it
/// on proximity out unless the caller refs it (libinput.h:3110-3125).
const TabletToolIdentity = struct {
    tool_type: c_int,
    serial: u64,
    unique: bool,
};

/// One libinput tablet tool event, reduced to what zwp_tablet_manager_v2
/// can express. The libinput event pointer is opaque C state a test
/// cannot fabricate, so the translation under test starts here:
/// onTabletToolProximity fills this through the FFI accessors and the
/// tests build it directly.
pub const TabletToolEvent = struct {
    /// libinput_event_tablet_tool_get_proximity_state.
    proximity_state: c_int,
    /// libinput_tablet_tool_get_type.
    tool_type: c_int,
    /// libinput_tablet_tool_get_serial; meaningful only when `unique`.
    serial: u64 = 0,
    /// libinput_tablet_tool_is_unique.
    unique: bool = false,
    /// libinput_tablet_tool_get_tool_id, announced as
    /// zwp_tablet_tool_v2.hardware_id_wacom. Zero when the tool has no
    /// tool id, and then no event is sent (tablet-v2.xml:308-318).
    tool_id: u64 = 0,
    /// libinput_tablet_tool_has_*: which axes this tool reports.
    axes: TabletToolAxes = .{},
};

/// Whether the registered tool IS the tool this event is about, by
/// libinput's own identity rule (a unique tool by serial, a shared one by
/// type). A unique tool that shares its type with another unique tool is
/// still its own zwp_tablet_tool_v2: two pens of one tablet differ by
/// serial, and that is the whole point of announcing it.
fn isSameTool(registered: TabletToolIdentity, event: TabletToolEvent) bool {
    if (registered.unique != event.unique) return false;
    if (event.unique) return registered.serial == event.serial;
    return registered.tool_type == event.tool_type;
}

/// One tablet tool this backend registered with the tablet module.
const TabletToolBinding = struct {
    identity: TabletToolIdentity,
    hw: *tablet_mod.ToolHw,
    /// Heap copy of the capability burst. The module keeps the ToolDesc
    /// — and this array is the storage that slice points at — for as long
    /// as the tool is registered, re-reading it for every client that
    /// attaches later (addTool -> announceTo -> sendToolBurst), so a stack
    /// array would dangle as soon as the announce loop returned.
    capabilities: []server.zwp.TabletToolV2.Capability,
    /// True from the proximity_in libinput reported until its proximity
    /// out, whether or not a protocol event could be sent yet.
    in_proximity: bool = false,
    /// The surface the last proximity_in named, or null when the tool is
    /// not entered. Only ever COMPARED against the seat's pointer focus —
    /// a focused-away surface is freed by the seat, so the pointer must
    /// not be dereferenced; the surface a new proximity_in names is the
    /// one the seat handed us.
    focus: ?*surface_mod.Surface = null,
};

/// One tablet pad this backend registered: the zwp object plus the heap
/// arrays its descriptor reads from. PadHw keeps the PadDesc and
/// re-reads it for every client that attaches later (addPad ->
/// announceTo -> sendPadBurst), which is why the group descriptors and
/// their button lists are owned here.
const TabletPadBinding = struct {
    hw: *tablet_mod.PadHw,
    groups: []tablet_mod.GroupDesc,
    /// One slice per group, each pointing into `button_storage`. Every
    /// button belongs to exactly one mode group
    /// (tablet-v2.xml:951-953), so the slices partition the storage.
    group_buttons: []const []const u32,
    button_storage: []u32,
    /// The surface the pad is focused on, or null when it is not entered.
    /// padLeave names the surface it leaves (tablet-v2.xml:1203-1210), so
    /// unlike a tool's this one IS dereferenced — by the module, which
    /// arms a destroy listener on it and forgets it when it dies.
    focus: ?*surface_mod.Surface = null,
};

/// A device announced to the compositor and tracked in the registry.
const Device = struct {
    handle: *c.libinput_device,
    kind: InputKind,
    /// Owned copy of libinput_device_get_name (the libinput-owned name is
    /// only valid for the lifetime of the event/device).
    name: [:0]u8,
    /// Owned copy of libinput_device_get_sysname ("event5"): the kernel
    /// node identity the udev hotplug monitor reports, and the registry's
    /// dedup key. Empty when libinput cannot name the node, and then the
    /// entry never matches a hotplug notification.
    sysname: [:0]u8,
    /// Touchpoints this device currently holds down, so a device that
    /// disappears mid-gesture still owes its client a wl_touch.cancel.
    touch_points: u16 = 0,
    /// The device's capability mask, read once at registration. The kind
    /// collapses TABLET_TOOL and TABLET_PAD into .touch, so the tablet
    /// hardware below is decided from the raw mask, not the kind.
    caps: u32 = 0,
    /// The zwp_tablet_v2 this device registered. A node with
    /// LIBINPUT_DEVICE_CAP_TABLET_TOOL is a digitizer; a node with only
    /// LIBINPUT_DEVICE_CAP_TABLET_PAD still gets one, because a pad's
    /// enter event names the tablet it is attached to
    /// (tablet-v2.xml:1194-1202) and there would be nothing to name.
    tablet: ?*tablet_mod.TabletHw = null,
    /// The pad hardware of this device, when it has any.
    pad: ?TabletPadBinding = null,
    /// The tools libinput reported on this device. libinput posts a
    /// proximity_in per tool and no "tool left the tablet" event, so a
    /// tool stays registered until the DEVICE is removed: one pen is one
    /// zwp_tablet_tool_v2 for as long as it is on the tablet.
    tools: std.ArrayList(TabletToolBinding) = .empty,
};

/// Release an entry's owned strings. Ownership moves into the registry on
/// a successful insert; after a duplicate or a failed insert the caller
/// still owns its copies and frees them here (see announceDevice).
fn freeDevice(allocator: std.mem.Allocator, name: [:0]u8, sysname: [:0]u8) void {
    allocator.free(name);
    allocator.free(sysname);
}

/// Release the arrays one device's tablet registration owns, WITHOUT
/// touching the tablet module: the zwp objects belong to it and it frees
/// them in its own deinit, which at backend teardown may already have
/// run (the server tears the seat modules down independently). What
/// belongs to this backend is only the memory it allocated for the
/// descriptors the module still points at.
///
/// The entry comes in by pointer because the tool list is emptied through
/// its own deinit, and an ArrayList is a value: a const copy of the entry
/// cannot be handed to it.
fn freeTabletBinding(allocator: std.mem.Allocator, device: *Device) void {
    for (device.tools.items) |binding| allocator.free(binding.capabilities);
    device.tools.deinit(allocator);
    if (device.pad) |pad| {
        allocator.free(pad.groups);
        allocator.free(pad.group_buttons);
        allocator.free(pad.button_storage);
    }
}

/// Whether a disappearing device owes its client a wl_touch.cancel:
/// wayland.xml sends cancel "when the touch points are removed", which
/// includes the touch device itself going away with points down — a
/// touchscreen unplugged mid-gesture leaves the client's points down
/// forever otherwise (wlroots cancels them in the device-destroy path,
/// wlr_seat_touch.c:143-160).
fn owesTouchCancel(device: Device) bool {
    return device.touch_points != 0;
}

/// The backend's copy of what the compositor knows about the seat's input
/// devices, and the single place both hotplug paths (libinput's
/// DEVICE_ADDED/DEVICE_REMOVED and the udev monitor) register and prune.
/// It owns every entry's name and sysname copies. Free of FFI and seat
/// state, so the add/dedup/remove rules are unit-testable without a live
/// libinput context.
const DeviceRegistry = struct {
    items: std.ArrayList(Device) = .empty,

    /// Register a device. False when the node is already registered: the
    /// sysname is the kernel's identity of the event node, so one
    /// physical device is announced once whichever hotplug path saw it
    /// first (an entry with no sysname never matches, so two unnameable
    /// devices both register). The caller keeps ownership of `entry` and
    /// its strings until this returns true.
    fn insert(
        self: *DeviceRegistry,
        allocator: std.mem.Allocator,
        entry: Device,
    ) error{OutOfMemory}!bool {
        if (self.findBySysname(entry.sysname) != null) return false;
        try self.items.append(allocator, entry);
        return true;
    }

    fn findBySysname(self: *const DeviceRegistry, sysname: []const u8) ?usize {
        if (sysname.len == 0) return null;
        for (self.items.items, 0..) |d, i| {
            if (std.mem.eql(u8, d.sysname, sysname)) return i;
        }
        return null;
    }

    fn findByHandle(self: *const DeviceRegistry, handle: *c.libinput_device) ?usize {
        for (self.items.items, 0..) |d, i| {
            if (d.handle == handle) return i;
        }
        return null;
    }

    /// Drop entry `i` and hand it to the caller, which logs it, releases
    /// the touch points it still holds and frees its strings — the seat
    /// side of the removal lives there.
    fn takeAt(self: *DeviceRegistry, i: usize) Device {
        return self.items.orderedRemove(i);
    }

    fn deinit(self: *DeviceRegistry, allocator: std.mem.Allocator) void {
        for (self.items.items) |*d| {
            freeTabletBinding(allocator, d);
            freeDevice(allocator, d.name, d.sysname);
        }
        self.items.deinit(allocator);
    }
};

const Libinput = struct {
    base: *backend.Backend,
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    seat: *seat_mod.Seat,
    /// Seat id passed to libinput_udev_assign_seat ("seat0"). Borrowed;
    /// the caller keeps it alive (it is a literal in practice).
    seat_name: [:0]const u8,
    /// Output size in pixels; absolute pointers scale to it.
    output_width: u32,
    output_height: u32,
    /// Created in start(), freed in destroy().
    udev: ?*c.udev = null,
    /// The udev hotplug monitor (input subsystem), opened in start() and
    /// unref'd in destroy(); null when the monitor could not be created.
    hotplug: ?*c.udev_monitor = null,
    ctx: ?*c.libinput = null,
    devices: DeviceRegistry = .{},
    /// Cursor position accumulated from relative motion (f64 so subpixel
    /// deltas do not get lost per event).
    cursor_x: f64 = 0,
    cursor_y: f64 = 0,
    /// Last LED bitmask pushed to devices (libinput_device_led_update).
    /// The seat's LED state is global to the keyboard, so one cache
    /// serves all devices; -1 forces the first key event to sync
    /// (wlroots caches kb->leds the same way, wlr_keyboard.c:188-196).
    last_leds: c_int = -1,
    /// Touch batch bookkeeping: one wl_touch.frame per libinput touch
    /// batch, never one per event (see TouchBatcher).
    touch_batch: TouchBatcher = .{},
    /// The zwp_tablet_manager_v2 registry this backend announces tablet
    /// hardware to (shell/tablet.zig), installed by attachTablet. Null
    /// when the server runs without it: the device is still announced
    /// through new_input like any other, and its tablet events translate
    /// to nothing.
    tablet: ?*tablet_mod.Tablet = null,

    /// The libinput fd to poll (libinput_get_fd). Only valid after start().
    pub fn pollFd(self: *Libinput) c_int {
        std.debug.assert(self.ctx != null);
        return c.libinput_get_fd(self.ctx);
    }

    /// libinput_dispatch + drain every queued event into the seat.
    /// Called when pollFd() is readable (and once in start() to pick up
    /// the initial DEVICE_ADDED burst). A negative libinput_dispatch rc
    /// is fatal for the context (libinput.h:3869-3870), so it surfaces
    /// as BackendFailed and the caller tears the backend down.
    pub fn dispatch(self: *Libinput) error{BackendFailed}!void {
        std.debug.assert(self.ctx != null);
        if (c.libinput_dispatch(self.ctx) < 0) return error.BackendFailed;
        while (c.libinput_get_event(self.ctx)) |event| {
            self.handleEvent(event);
            c.libinput_event_destroy(event);
        }
        // End of the input batch: a touch batch libinput did not close
        // with its TOUCH_FRAME event (the queue drained mid-sample, or the
        // device was removed mid-gesture) still gets its one frame here.
        // A batch already closed by TOUCH_FRAME flushed already, so this
        // can never send a second frame for it.
        self.closeTouchFrame();
    }

    fn handleEvent(self: *Libinput, event: *c.libinput_event) void {
        const event_type = c.libinput_event_get_type(event);
        switch (event_type) {
            event_device_added => self.onDeviceAdded(event),
            event_device_removed => self.onDeviceRemoved(event),
            event_keyboard_key => self.onKey(event),
            event_pointer_motion => self.onPointerMotion(event),
            event_pointer_motion_absolute => self.onPointerMotionAbsolute(event),
            event_pointer_button => self.onPointerButton(event),
            event_pointer_axis => self.onPointerAxis(event),
            // Wheel scrolls arrive here with v120-normalized deltas
            // (libinput >= 1.19; wlroots consumes exactly this event,
            // events.c:169-183). The legacy POINTER_AXIS twin of a wheel
            // event is skipped in onPointerAxis, so no double delivery.
            event_pointer_scroll_wheel => self.onPointerScrollWheel(event),
            // SCROLL_FINGER/CONTINUOUS carry the same data as their
            // POINTER_AXIS twins (libinput posts both families,
            // libinput.h:811-826); the AXIS handler consumes those, so
            // these stay ignored to avoid double delivery.
            event_pointer_scroll_finger, event_pointer_scroll_continuous => {},
            event_touch_down => self.onTouchDown(event),
            event_touch_motion => self.onTouchMotion(event),
            event_touch_up => self.onTouchUp(event),
            // The device-wide cancel: libinput cancels every active point
            // of the device that sent it (a contact lifted off a
            // multitouch surface, the palm rejected, the device removed),
            // which is exactly what wl_touch.cancel means.
            event_touch_cancel => self.onTouchCancel(event),
            // The batch boundary. A batch is closed here and once more at
            // the end of the drain, but only an OPEN batch sends a frame,
            // so exactly one wl_touch.frame leaves per batch.
            event_touch_frame => self.closeTouchFrame(),
            // The pen's proximity: the whole tool lifecycle, in and out.
            event_tablet_tool_proximity => self.onTabletToolProximity(event),
            // AXIS (motion, pressure, distance, tilt, rotation, slider,
            // wheel, size), TIP and BUTTON carry no zwp_tablet_manager_v2
            // event this server sends: the vendored protocol declares
            // them (tablet-v2.xml:414-563) and wlroots sends them, but
            // shell/tablet.zig relays the announcement tree, proximity and
            // pad focus only. What they DO mean is that a pen is over the
            // tablet, which is when a proximity deferred for want of a
            // focused surface can finally be sent.
            event_tablet_tool_axis, event_tablet_tool_tip, event_tablet_tool_button => self.onTabletToolIdle(event),
            // A pad event likewise carries nothing to relay (the ring,
            // strip and dial axis events and zwp_tablet_pad_v2.button
            // have no home in the module either, tablet-v2.xml:737-1290);
            // what it means is that the pad is in use, which is when it
            // takes focus.
            event_tablet_pad_button, event_tablet_pad_ring, event_tablet_pad_strip, event_tablet_pad_key, event_tablet_pad_dial => self.onTabletPadEvent(event),
            // Gestures and switches: not implemented.
            else => log_mod.debug(
                "unhandled libinput event {s} ({d})",
                self.io,
                self.log_cfg,
                "libinput",
                .{ eventTypeName(event_type), event_type },
            ),
        }
    }

    fn onDeviceAdded(self: *Libinput, event: *c.libinput_event) void {
        const dev = c.libinput_event_get_device(event) orelse return;
        const caps = capsMask(dev);
        const kind = kindForCaps(caps) orelse return;
        // Fresh keyboard: LEDs start off (wlroots init_device_keyboard
        // calls libinput_device_led_update(handle, 0),
        // backend/libinput/keyboard.c:38-44). libinput no-ops for
        // devices without LED support.
        if (kind == .keyboard) {
            _ = c.libinput_device_led_update(dev, 0);
        }
        const entry = self.makeDevice(dev, kind, caps) orelse return;
        self.announceDevice(entry);
    }

    /// Build the registry entry for a libinput device: owned copies of its
    /// name and sysname. Both strings belong to libinput and are only
    /// valid while the device lives, so the registry cannot borrow them.
    /// Null when a copy fails; nothing is announced then.
    fn makeDevice(self: *Libinput, dev: *c.libinput_device, kind: InputKind, caps: u32) ?Device {
        const name_slice = std.mem.span(c.libinput_device_get_name(dev));
        const name = if (name_slice.len == 0) "unknown" else name_slice;
        const owned_name = self.allocator.dupeZ(u8, name) catch {
            log_mod.warn("device {s}: name allocation failed", self.io, self.log_cfg, "libinput", .{name});
            return null;
        };
        errdefer self.allocator.free(owned_name);
        const sysname_slice = std.mem.span(c.libinput_device_get_sysname(dev));
        const owned_sysname = self.allocator.dupeZ(u8, sysname_slice) catch {
            log_mod.warn("device {s}: sysname allocation failed", self.io, self.log_cfg, "libinput", .{name});
            return null;
        };
        return .{ .handle = dev, .kind = kind, .name = owned_name, .sysname = owned_sysname, .caps = caps };
    }

    /// Register a device and announce it through `new_input`. This is the
    /// ONE announcement path: libinput's DEVICE_ADDED is the only event
    /// carrying a libinput_device handle, and the handle is what
    /// classifies the kind — the udev hotplug monitor cannot announce and
    /// only prunes on remove. A node already in the registry is dropped
    /// here and its strings freed, so a node both hotplug paths saw is
    /// announced exactly once.
    fn announceDevice(self: *Libinput, entry: Device) void {
        const stored = self.devices.insert(self.allocator, entry) catch {
            // Free the owned strings here: `catch` returns without error,
            // so makeDevice's errdefers are already done.
            freeDevice(self.allocator, entry.name, entry.sysname);
            return;
        };
        if (!stored) {
            log_mod.debug("input device already announced: {s}", self.io, self.log_cfg, "libinput", .{entry.name});
            freeDevice(self.allocator, entry.name, entry.sysname);
            return;
        }
        // The announcement borrows the registry's name copy, which outlives
        // the event (libinput's own name pointer does not).
        // SAFETY: the string copy below (dupe) always succeeds before use.
        var announced: backend.Backend.InputDevice = .{ .kind = entry.kind, .name = entry.name };
        self.base.emitNewInput(&announced);
        log_mod.info("input device added: {s}", self.io, self.log_cfg, "libinput", .{entry.name});
        // Tablet hardware goes out through the same path, so the initial
        // drain in start() registers a tablet that was already plugged
        // in exactly like a hotplugged one. findByHandle re-reads the
        // entry the insert just appended; nothing dispatches a client in
        // between, so the list cannot have moved.
        if (self.devices.findByHandle(entry.handle)) |index| {
            self.registerTablet(&self.devices.items.items[index]);
        }
    }

    /// Register the tablet hardware of one device with the tablet module.
    /// A no-op without a module (a server built without one) and on any
    /// node that is neither a digitizer nor a pad.
    fn registerTablet(self: *Libinput, entry: *Device) void {
        const has_digitizer = entry.caps & capsBit(device_cap_tablet_tool) != 0;
        const has_pad = entry.caps & capsBit(device_cap_tablet_pad) != 0;
        if (!has_digitizer and !has_pad) return;
        const info = self.readTabletInfo(entry.handle, has_pad) orelse return;
        defer freeTabletInfo(self.allocator, info);
        self.applyTabletInfo(entry, info);
    }

    /// Read the tablet facts of a libinput device through the FFI
    /// accessors. Split from applyTabletInfo so the descriptor
    /// construction — the part with protocol meaning — runs without a
    /// libinput handle and the FFI stays a thin adapter.
    fn readTabletInfo(self: *Libinput, dev: *c.libinput_device, has_pad: bool) ?TabletDeviceInfo {
        var info: TabletDeviceInfo = .{
            .name = std.mem.span(c.libinput_device_get_name(dev)),
            .vendor = c.libinput_device_get_id_vendor(dev),
            .product = c.libinput_device_get_id_product(dev),
            .bustype = tabletBustype(@intCast(c.libinput_device_get_id_bustype(dev))),
        };
        if (!has_pad) return info;
        info.rings = c.libinput_device_tablet_pad_get_num_rings(dev);
        info.strips = c.libinput_device_tablet_pad_get_num_strips(dev);
        info.dials = c.libinput_device_tablet_pad_get_num_dials(dev);
        const buttons = c.libinput_device_tablet_pad_get_num_buttons(dev);
        const num_groups: usize = @intCast(c.libinput_device_tablet_pad_get_num_mode_groups(dev));
        const groups = self.allocator.alloc(TabletModeGroupInfo, num_groups) catch {
            self.tabletRegistrationFailed(info.name, "mode group allocation failed");
            return null;
        };
        errdefer self.allocator.free(groups);
        const button_lists = self.allocator.alloc([]const u32, num_groups) catch {
            self.tabletRegistrationFailed(info.name, "mode group button allocation failed");
            return null;
        };
        errdefer self.allocator.free(button_lists);
        for (groups, button_lists, 0..) |*group, *list, group_index| {
            // `group_index` is the MODE GROUP index (libinput.h:478-485),
            // and the group handle is unrefcounted: it is read here and
            // dropped, never kept.
            const mode_group = c.libinput_device_tablet_pad_get_mode_group(dev, @intCast(group_index));
            const owned = self.allocator.alloc(u32, buttons) catch {
                self.tabletRegistrationFailed(info.name, "mode group button allocation failed");
                return null;
            };
            errdefer self.allocator.free(owned);
            var count: u32 = 0;
            var index: u32 = 0;
            while (index < buttons) : (index += 1) {
                if (c.libinput_tablet_pad_mode_group_has_button(mode_group, index) == 0) continue;
                owned[count] = index;
                count += 1;
            }
            list.* = owned[0..count];
            group.* = .{
                .rings = modeGroupAxisCount(mode_group, .ring, info.rings),
                .strips = modeGroupAxisCount(mode_group, .strip, info.strips),
                .dials = modeGroupAxisCount(mode_group, .dial, info.dials),
                // The modes event is sent only when a group has more than
                // one mode (tablet-v2.xml:1000-1001), and a device that
                // reports none still has mode 0.
                .modes = if (mode_group != null)
                    c.libinput_tablet_pad_mode_group_get_num_modes(mode_group)
                else
                    1,
            };
        }
        info.groups = groups;
        info.group_buttons = button_lists;
        return info;
    }

    /// Register a device's tablet hardware from the facts read above: the
    /// digitizer as a zwp_tablet_v2, and the pad as a zwp_tablet_pad_v2
    /// with one zwp_tablet_pad_group_v2 per libinput mode group.
    ///
    /// A pad-only node gets a zwp_tablet_v2 too: zwp_tablet_pad_v2.enter
    /// names "the tablet the pad is attached to" (tablet-v2.xml:1194-1202)
    /// and there would otherwise be nothing to name.
    fn applyTabletInfo(self: *Libinput, entry: *Device, info: TabletDeviceInfo) void {
        const tablet = self.tablet orelse return;
        const allocator = self.allocator;
        entry.tablet = tablet.addTablet(.{
            .name = info.name,
            .vid = info.vendor,
            .pid = info.product,
            .bustype = info.bustype,
        }) catch |err| {
            self.tabletRegistrationFailed(info.name, @errorName(err));
            return;
        };
        if (info.groups.len == 0) return;

        // Copies of what the module KEEPS: PadHw holds the descriptor and
        // re-reads it for every client that attaches later (addPad ->
        // announceTo -> sendPadBurst), so these outlive this function.
        const groups = allocator.alloc(tablet_mod.GroupDesc, info.groups.len) catch {
            self.tabletRegistrationFailed(info.name, "pad descriptor allocation failed");
            return;
        };
        const button_lists = allocator.alloc([]const u32, info.groups.len) catch {
            allocator.free(groups);
            self.tabletRegistrationFailed(info.name, "pad descriptor allocation failed");
            return;
        };
        var total: usize = 0;
        for (info.group_buttons) |list| total += list.len;
        const storage = allocator.alloc(u32, total) catch {
            allocator.free(button_lists);
            allocator.free(groups);
            self.tabletRegistrationFailed(info.name, "pad descriptor allocation failed");
            return;
        };
        var cursor: usize = 0;
        for (info.groups, info.group_buttons, 0..) |src, list, i| {
            @memcpy(storage[cursor..][0..list.len], list);
            button_lists[i] = storage[cursor..][0..list.len];
            cursor += list.len;
            groups[i] = .{
                .buttons = button_lists[i],
                .ring_count = src.rings,
                .strip_count = src.strips,
                .dial_count = src.dials,
                .modes = @max(src.modes, 1),
            };
        }
        const hw = tablet.addPad(.{ .buttons = @intCast(total), .groups = groups }) catch |err| {
            allocator.free(storage);
            allocator.free(button_lists);
            allocator.free(groups);
            self.tabletRegistrationFailed(info.name, @errorName(err));
            return;
        };
        entry.pad = TabletPadBinding{
            .hw = hw,
            .groups = groups,
            .group_buttons = button_lists,
            .button_storage = storage,
        };
    }

    /// One log line for every way tablet registration can give up: a
    /// client that has already seen the device through new_input must be
    /// able to tell the registry skipped it.
    fn tabletRegistrationFailed(self: *Libinput, name: []const u8, reason: []const u8) void {
        log_mod.warn("tablet {s}: registration failed: {s}", self.io, self.log_cfg, "libinput", .{ name, reason });
    }

    fn onDeviceRemoved(self: *Libinput, event: *c.libinput_event) void {
        const dev = c.libinput_event_get_device(event) orelse return;
        const index = self.devices.findByHandle(dev) orelse return;
        self.removeDeviceAt(index);
    }

    /// Drop the device at `index`. Touch points it still holds down are
    /// cancelled first — a touchscreen unplugged mid-gesture otherwise
    /// leaves the client's points down forever — then the tablet hardware
    /// it registered is retired, then the removal is announced through
    /// Backend.events.input_removed, and finally the entry's strings are
    /// freed. Both removal paths (libinput's DEVICE_REMOVED and the udev
    /// monitor) funnel here, so whichever lands first wins and the other
    /// finds nothing.
    fn removeDeviceAt(self: *Libinput, index: usize) void {
        var device = self.devices.takeAt(index);
        if (owesTouchCancel(device)) {
            log_mod.warn(
                "input device {s} disappeared with {d} touch point(s) down",
                self.io,
                self.log_cfg,
                "libinput",
                .{ device.name, device.touch_points },
            );
            self.seat.touchCancel();
            self.closeTouchFrame();
        }
        self.unregisterTablet(&device);
        // The pair listeners match on: the identity the new_input
        // announcement used, which the registry's name copy still backs
        // (the seat copies what it keeps, backend.zig:114-120).
        var removed: backend.Backend.InputDevice = .{ .kind = device.kind, .name = device.name };
        self.base.emitInputRemoved(&removed);
        log_mod.info("input device removed: {s}", self.io, self.log_cfg, "libinput", .{device.name});
        freeTabletBinding(self.allocator, &device);
        freeDevice(self.allocator, device.name, device.sysname);
    }

    /// Retire the tablet hardware of a device that is going away, in the
    /// order the protocol requires. A tool libinput last reported in
    /// proximity gets proximity_out BEFORE removed (tablet-v2.xml:361-373
    /// — a removed tool that is in proximity must still leave), a focused
    /// pad gets leave before removed (tablet-v2.xml:1203-1210), and the
    /// pad goes before the tablet it is attached to (tablet-v2.xml:1209-
    /// 1211: "When a tablet is removed its pad(s) will be removed too").
    fn unregisterTablet(self: *Libinput, device: *const Device) void {
        const tablet = self.tablet orelse return;
        // Read only: the binding's state dies with the entry (removeDeviceAt
        // frees it right after), and the protocol event is what the client
        // sees.
        for (device.tools.items) |binding| {
            if (binding.focus != null) tablet.toolProximityOutHw(binding.hw);
            tablet.removeTool(binding.hw);
        }
        if (device.pad) |pad| {
            if (pad.focus) |surface| tablet.padLeaveHw(pad.hw, surface);
            tablet.removePad(pad.hw);
        }
        if (device.tablet) |tablet_hw| tablet.removeTablet(tablet_hw);
    }

    /// The registry entry of the device that sent this event, or null for
    /// a device this backend never announced (a gesture- or switch-only
    /// node on the same seat).
    fn deviceOf(self: *Libinput, event: *c.libinput_event) ?*Device {
        const dev = c.libinput_event_get_device(event) orelse return null;
        const index = self.devices.findByHandle(dev) orelse return null;
        return &self.devices.items.items[index];
    }

    /// Extract the touchpoint (wl_touch id plus output-pixel coordinates)
    /// from a TOUCH_DOWN/MOTION event.
    fn touchPointFor(self: *Libinput, event: *c.libinput_event) ?TouchPoint {
        const tevent = c.libinput_event_get_touch_event(event) orelse return null;
        return touchPoint(
            c.libinput_event_touch_get_seat_slot(tevent),
            c.libinput_event_touch_get_x_transformed(tevent, 1),
            c.libinput_event_touch_get_y_transformed(tevent, 1),
            self.output_width,
            self.output_height,
        );
    }

    fn onTouchDown(self: *Libinput, event: *c.libinput_event) void {
        const point = self.touchPointFor(event) orelse return;
        if (self.deviceOf(event)) |device| device.touch_points +|= 1;
        self.seat.touchDown(point.id, point.x, point.y);
        self.touch_batch.note();
    }

    fn onTouchMotion(self: *Libinput, event: *c.libinput_event) void {
        const point = self.touchPointFor(event) orelse return;
        self.seat.touchMotion(point.id, point.x, point.y);
        self.touch_batch.note();
    }

    fn onTouchUp(self: *Libinput, event: *c.libinput_event) void {
        const tevent = c.libinput_event_get_touch_event(event) orelse return;
        const id = touchPointId(c.libinput_event_touch_get_seat_slot(tevent)) orelse return;
        // Saturating: an up without a tracked down (the down landed before
        // the device was announced) must not underflow into a huge count
        // that would owe a cancel at removal forever.
        if (self.deviceOf(event)) |device| device.touch_points -|= 1;
        self.seat.touchUp(id);
        self.touch_batch.note();
    }

    /// The device-wide cancel: libinput sends it for every active point of
    /// the device that produced it (a contact lifted off a multitouch
    /// surface, the palm rejected, the device removed), which is what
    /// wl_touch.cancel means.
    fn onTouchCancel(self: *Libinput, event: *c.libinput_event) void {
        if (self.deviceOf(event)) |device| device.touch_points = 0;
        self.seat.touchCancel();
        self.touch_batch.note();
    }

    /// Close the open touch batch with its single wl_touch.frame. Called
    /// at libinput's TOUCH_FRAME and at the end of the event drain. An
    /// empty batch sends nothing, so a delivered batch never gets a
    /// second frame, and the seat's per-client pending flag makes the
    /// close a no-op when nothing was delivered (Seat.pointerFrame
    /// flushes touch too, seat.zig:1039 — this call adds the libinput
    /// batch boundary, it does not duplicate the server's flush).
    fn closeTouchFrame(self: *Libinput) void {
        if (!self.touch_batch.flush()) return;
        self.seat.touchFrame();
    }

    // Tablet events ------------------------------------------------------

    /// TABLET_TOOL_PROXIMITY: the whole tool lifecycle, in and out.
    fn onTabletToolProximity(self: *Libinput, event: *c.libinput_event) void {
        const tevent = c.libinput_event_get_tablet_tool_event(event) orelse return;
        const device = self.deviceOf(event) orelse return;
        const libinput_tool = c.libinput_event_tablet_tool_get_tool(tevent) orelse return;
        self.handleTabletToolEvent(device, .{
            .proximity_state = c.libinput_event_tablet_tool_get_proximity_state(tevent),
            .tool_type = c.libinput_tablet_tool_get_type(libinput_tool),
            .serial = c.libinput_tablet_tool_get_serial(libinput_tool),
            .unique = c.libinput_tablet_tool_is_unique(libinput_tool) != 0,
            .tool_id = c.libinput_tablet_tool_get_tool_id(libinput_tool),
            .axes = .{
                .pressure = c.libinput_tablet_tool_has_pressure(libinput_tool) != 0,
                .distance = c.libinput_tablet_tool_has_distance(libinput_tool) != 0,
                .tilt = c.libinput_tablet_tool_has_tilt(libinput_tool) != 0,
                .rotation = c.libinput_tablet_tool_has_rotation(libinput_tool) != 0,
                .slider = c.libinput_tablet_tool_has_slider(libinput_tool) != 0,
                .wheel = c.libinput_tablet_tool_has_wheel(libinput_tool) != 0,
            },
        });
    }

    /// TABLET_TOOL_AXIS / _TIP / _BUTTON: no zwp_tablet_manager_v2 event
    /// carries them in this server (see the dispatch switch), but they do
    /// mean a pen is over the tablet — which is when a proximity deferred
    /// for want of a focused surface can go out.
    fn onTabletToolIdle(self: *Libinput, event: *c.libinput_event) void {
        const device = self.deviceOf(event) orelse return;
        self.syncToolProximity(device);
    }

    /// The per-device half of onTabletToolIdle, and of a pad event that
    /// finds its device by handle.
    fn syncToolProximity(self: *Libinput, device: *Device) void {
        for (device.tools.items) |*binding| {
            self.tryToolProximity(device, binding);
        }
    }

    /// Any tablet pad event: libinput has no pad focus event, so the pad
    /// takes focus the first time it is used and follows the pointer
    /// focus from there.
    fn onTabletPadEvent(self: *Libinput, event: *c.libinput_event) void {
        const device = self.deviceOf(event) orelse return;
        self.focusTabletPad(device);
    }

    /// One libinput tool event for a registered device: proximity in
    /// registers the tool the first time and enters it, proximity out
    /// leaves it. The tool stays registered across in/out cycles — one
    /// pen is one zwp_tablet_tool_v2 for as long as it is on the tablet —
    /// and libinput's identity rule is what finds it again.
    fn handleTabletToolEvent(self: *Libinput, device: *Device, event: TabletToolEvent) void {
        const tablet = self.tablet orelse return;
        if (device.tablet == null) return;
        var index = findToolBinding(device, event);
        if (index == null and event.proximity_state == tablet_proximity_state_in) {
            // libinput reports a tool only from its first proximity_in
            // (libinput.h:2800-2810), so this is where one is born.
            index = self.addTabletTool(device, event);
        }
        const i = index orelse return;
        const binding = &device.tools.items[i];
        if (event.proximity_state == tablet_proximity_state_in) {
            binding.in_proximity = true;
            self.tryToolProximity(device, binding);
            return;
        }
        // Proximity out. A tool that never went in sends nothing, which
        // is why this is gated on the FOCUS and not on in_proximity.
        if (binding.focus == null) {
            binding.in_proximity = false;
            return;
        }
        tablet.toolProximityOutHw(binding.hw);
        binding.focus = null;
        binding.in_proximity = false;
    }

    /// Register one tool with the tablet module and remember the
    /// descriptor arrays the module keeps. Nothing to announce without a
    /// surface only applies to proximity, not to the registration: the
    /// tool exists as hardware whether or not anything is focused.
    fn addTabletTool(self: *Libinput, device: *Device, event: TabletToolEvent) ?usize {
        const tablet = self.tablet orelse return null;
        const tool_type = tabletToolType(event.tool_type) orelse {
            log_mod.warn(
                "tablet tool type {d} has no zwp_tablet_tool_v2.type; not registered",
                self.io,
                self.log_cfg,
                "libinput",
                .{event.tool_type},
            );
            return null;
        };
        const capabilities = self.allocator.alloc(server.zwp.TabletToolV2.Capability, tablet_capability_count) catch {
            self.tabletRegistrationFailed(device.name, "tool capability allocation failed");
            return null;
        };
        // The ToolDesc borrows this array and the module keeps the
        // descriptor, so the binding owns it until the tool is removed.
        const list = tabletToolCapabilities(event.axes, capabilities);
        const hw = tablet.addTool(.{
            .tool_type = tool_type,
            // hardware_serial names the physical tool; libinput only
            // guarantees a serial for a uniquely identifiable one
            // (libinput.h:3086-3104), and a serial that does not identify
            // anything must not be announced (tablet-v2.xml:286-299).
            .hardware_serial = if (event.unique and event.serial != 0) event.serial else null,
            .hardware_id_wacom = if (event.tool_id != 0) event.tool_id else null,
            .capabilities = list,
        }) catch |err| {
            self.allocator.free(capabilities);
            self.tabletRegistrationFailed(device.name, @errorName(err));
            return null;
        };
        device.tools.append(self.allocator, .{
            .identity = .{ .tool_type = event.tool_type, .serial = event.serial, .unique = event.unique },
            .hw = hw,
            .capabilities = capabilities,
        }) catch |err| {
            tablet.removeTool(hw);
            self.allocator.free(capabilities);
            self.tabletRegistrationFailed(device.name, @errorName(err));
            return null;
        };
        log_mod.info(
            "tablet tool registered on {s}: {s}",
            self.io,
            self.log_cfg,
            "libinput",
            .{ device.name, @tagName(tool_type) },
        );
        return device.tools.items.len - 1;
    }

    /// Send the proximity_in a tool libinput holds in proximity is owed,
    /// once there is a surface to focus. A pen that comes into proximity
    /// while nothing is focused under the cursor — before the first
    /// pointer motion of a session, or over a gap between surfaces —
    /// must still be entered when a surface appears: the protocol names
    /// the surface on proximity_in (tablet-v2.xml:380-395), so the event
    /// waits instead of being dropped. A tool that moved from one surface
    /// to another gets the leave for the old one first, which is what the
    /// same event is for (tablet-v2.xml:384-386).
    fn tryToolProximity(self: *Libinput, device: *Device, binding: *TabletToolBinding) void {
        if (!binding.in_proximity) return;
        const tablet = self.tablet orelse return;
        const tablet_hw = device.tablet orelse return;
        const surface = self.seat.pointer_focus;
        if (binding.focus == surface) return;
        if (binding.focus != null) tablet.toolProximityOutHw(binding.hw);
        if (surface) |focused| tablet.toolProximityInHw(binding.hw, tablet_hw, focused);
        binding.focus = surface;
    }

    /// Focus the pad of a device on the surface the pointer is over, and
    /// refocus it when that surface changes. The pad focus follows the
    /// tablet's focus surface in wlroots (the compositor sets both from
    /// the cursor focus), and zwp_tablet_pad_v2.enter names the surface
    /// (tablet-v2.xml:1194-1202).
    fn focusTabletPad(self: *Libinput, device: *Device) void {
        const tablet = self.tablet orelse return;
        const tablet_hw = device.tablet orelse return;
        const surface = self.seat.pointer_focus;
        // A digitizer with no pad is the common case and sends nothing.
        if (device.pad) |*pad| {
            if (pad.focus == surface) return;
            // padLeave NAMES the surface it leaves (tablet-v2.xml:1203-
            // 1210), so the module dereferences this pointer: it only
            // reaches here from a pad event, and the seat drops its own
            // focus when the surface dies, so a freed surface cannot be
            // named twice.
            if (pad.focus) |old| tablet.padLeaveHw(pad.hw, old);
            if (surface) |focused| tablet.padEnterHw(pad.hw, tablet_hw, focused, self.seat.nowMs());
            pad.focus = surface;
        }
    }

    /// The index of the tool `event` is about, or null when this device
    /// has not registered it.
    fn findToolBinding(device: *const Device, event: TabletToolEvent) ?usize {
        for (device.tools.items, 0..) |binding, i| {
            if (isSameTool(binding.identity, event)) return i;
        }
        return null;
    }

    fn onKey(self: *Libinput, event: *c.libinput_event) void {
        const kevent = c.libinput_event_get_keyboard_event(event) orelse return;
        const key = c.libinput_event_keyboard_get_key(kevent);
        const pressed = c.libinput_event_keyboard_get_key_state(kevent) == key_state_pressed;
        // libinput reports evdev scancodes; the seat expects xkb keycodes.
        self.seat.keyEvent(evdevToXkb(key), pressed);
        // Push the seat's LED state (numlock/capslock, updated by
        // keyEvent) to the device's LEDs — wlroots keyboard_set_leds
        // (backend/libinput/keyboard.c:31-35) + keyboard_led_update
        // (types/wlr_keyboard.c:20-35), with the same skip-when-unchanged
        // cache (wlr_keyboard.c:188-196).
        const leds = ledsFromModsLocked(self.seat.mods_locked);
        if (leds != self.last_leds) {
            self.last_leds = leds;
            if (c.libinput_event_get_device(event)) |dev| {
                _ = c.libinput_device_led_update(dev, leds);
            }
        }
    }

    fn onPointerMotion(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        self.cursor_x += c.libinput_event_pointer_get_dx(pevent);
        self.cursor_y += c.libinput_event_pointer_get_dy(pevent);
        self.seat.pointerMotion(
            @intFromFloat(@round(self.cursor_x)),
            @intFromFloat(@round(self.cursor_y)),
        );
    }

    fn onPointerMotionAbsolute(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        // Normalize to 0..1 (wlroots' handle_pointer_motion_abs uses the
        // same call with 1), then scale onto the output.
        const nx = c.libinput_event_pointer_get_absolute_x_transformed(pevent, 1);
        const ny = c.libinput_event_pointer_get_absolute_y_transformed(pevent, 1);
        self.cursor_x = scaleToOutput(nx, self.output_width);
        self.cursor_y = scaleToOutput(ny, self.output_height);
        self.seat.pointerMotion(
            @intFromFloat(@round(self.cursor_x)),
            @intFromFloat(@round(self.cursor_y)),
        );
    }

    fn onPointerButton(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        const button = c.libinput_event_pointer_get_button(pevent);
        const pressed = c.libinput_event_pointer_get_button_state(pevent) == button_state_pressed;
        // libinput button codes are the linux BTN_* codes the seat expects.
        self.seat.pointerButton(button, pressed);
    }

    fn onPointerAxis(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        // The axis value's units depend on the source
        // (libinput.h:1598-1617); the source is required to interpret it.
        const source = axisSourceFromLibinput(c.libinput_event_pointer_get_axis_source(pevent)) orelse return;
        // Wheel data now arrives via LIBINPUT_EVENT_POINTER_SCROLL_WHEEL
        // (v120-normalized, libinput 1.19+). The legacy AXIS event is
        // still posted alongside SCROLL_WHEEL for hi-res devices, so
        // consuming it here would double every wheel click — wheel
        // sources are handled in onPointerScrollWheel only (wlroots
        // events.c:167-169 ignores the AXIS event for the same reason).
        if (source == .wheel or source == .wheel_tilt) return;
        // wlroots iterates both scroll axes (handle_pointer_axis,
        // backend/libinput/pointer.c:114-148).
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_vertical) != 0) {
            self.sendAxis(pevent, source, .vertical_scroll);
        }
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_horizontal) != 0) {
            self.sendAxis(pevent, source, .horizontal_scroll);
        }
    }

    /// A LIBINPUT_EVENT_POINTER_SCROLL_WHEEL event: wheel scroll with a
    /// v120-normalized delta (libinput 1.19+; wlroots
    /// handle_pointer_axis_value120, pointer.c:149-186). The value is in
    /// degrees (15.0 per logical click) and converts via
    /// axisValueToPixels; the discrete is the v120 delta normalized to
    /// legacy clicks via v120ToNotches.
    fn onPointerScrollWheel(self: *Libinput, event: *c.libinput_event) void {
        const pevent = c.libinput_event_get_pointer_event(event) orelse return;
        // wlroots iterates both scroll axes.
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_vertical) != 0) {
            self.sendAxisV120(pevent, .vertical_scroll);
        }
        if (c.libinput_event_pointer_has_axis(pevent, pointer_axis_scroll_horizontal) != 0) {
            self.sendAxisV120(pevent, .horizontal_scroll);
        }
    }

    /// Forward one SCROLL_WHEEL axis to the seat: value in degrees -> the
    /// seat's 10 px per notch convention, discrete v120-normalized to
    /// legacy clicks.
    fn sendAxisV120(
        self: *Libinput,
        pevent: *c.libinput_event_pointer,
        axis: server.wl.Pointer.Axis,
    ) void {
        const libinput_axis: c_int = switch (axis) {
            .vertical_scroll => pointer_axis_scroll_vertical,
            .horizontal_scroll => pointer_axis_scroll_horizontal,
            else => return, // unknown wire axis: nothing to forward
        };
        const value = c.libinput_event_pointer_get_scroll_value(pevent, libinput_axis);
        const v120 = c.libinput_event_pointer_get_scroll_value_v120(pevent, libinput_axis);
        self.seat.pointerAxis(
            axis,
            .wheel,
            axisValueToPixels(value),
            v120ToNotches(v120),
        );
    }

    /// Forward one scroll axis to the seat, scaled per source (see
    /// axisValueToPixelsSource/axisDiscreteForSource for the semantics).
    fn sendAxis(
        self: *Libinput,
        pevent: *c.libinput_event_pointer,
        source: server.wl.Pointer.AxisSource,
        axis: server.wl.Pointer.Axis,
    ) void {
        const libinput_axis: c_int = switch (axis) {
            .vertical_scroll => pointer_axis_scroll_vertical,
            .horizontal_scroll => pointer_axis_scroll_horizontal,
            else => return, // unknown wire axis: nothing to forward
        };
        const value = c.libinput_event_pointer_get_axis_value(pevent, libinput_axis);
        const raw_discrete = c.libinput_event_pointer_get_axis_value_discrete(pevent, libinput_axis);
        self.seat.pointerAxis(
            axis,
            source,
            axisValueToPixelsSource(source, value),
            axisDiscreteForSource(source, raw_discrete),
        );
    }

    // Hotplug ------------------------------------------------------------

    /// The udev monitor fd to poll next to pollFd(): it becomes readable
    /// when an input device appears or disappears. -1 when the monitor
    /// could not be created (an environment without udevd); libinput's
    /// own udev context still posts DEVICE_ADDED/DEVICE_REMOVED there,
    /// so dispatch() alone still covers hotplug.
    pub fn hotplugPollFd(self: *Libinput) c_int {
        const monitor = self.hotplug orelse return -1;
        return c.udev_monitor_get_fd(monitor);
    }

    /// Drain the udev monitor, translating each notification into the same
    /// registry paths libinput's DEVICE_ADDED/DEVICE_REMOVED use. Called
    /// when hotplugPollFd() is readable.
    pub fn dispatchHotplug(self: *Libinput) void {
        const monitor = self.hotplug orelse return;
        while (c.udev_monitor_receive_device(monitor)) |device| {
            self.onHotplugDevice(device);
            _ = c.udev_device_unref(device);
        }
    }

    fn onHotplugDevice(self: *Libinput, device: *c.udev_device) void {
        const action_name = c.udev_device_get_action(device) orelse return;
        const action = udevActionFromName(std.mem.span(action_name)) orelse return;
        const sysname_name = c.udev_device_get_sysname(device) orelse return;
        const sysname = std.mem.span(sysname_name);
        switch (action) {
            .add => {
                // Deliberately no registry work. The announcement needs
                // InputDevice.kind, which needs libinput's capability
                // classification, which needs the libinput_device handle
                // only DEVICE_ADDED carries — libinput 1.31 has no
                // udev -> device lookup. The node reaches the registry
                // through that one path; this notification only says one
                // is on its way, and one physical device is announced
                // once because the registry dedups on the node name.
                log_mod.debug("input node {s} appeared (libinput announces it)", self.io, self.log_cfg, "libinput", .{sysname});
            },
            .remove => {
                // Idempotent with libinput's DEVICE_REMOVED: whichever
                // path lands first prunes the entry (cancelling the touch
                // points it holds down), the other finds nothing.
                const index = self.devices.findBySysname(sysname) orelse {
                    log_mod.debug("input node {s} removed (never announced)", self.io, self.log_cfg, "libinput", .{sysname});
                    return;
                };
                self.removeDeviceAt(index);
            },
        }
    }
};

const backend_impl: backend.Backend.Impl = .{
    .start = start,
    .destroy = destroy,
};

/// The libinput log handler callback carries no user_data
/// (libinput.h:4049-4053), so the logging context is stashed module-wide
/// while the backend runs. The server is single-threaded; start() sets
/// both before the context is created, destroy() clears them.
var handler_io: ?*std.Io = null;
var handler_cfg: ?*const log_mod.Config = null;

/// libinput log handler (libinput.h:4049-4053): forwards libinput's
/// printf-style messages to log_mod under the "libinput" tag, mapped by
/// priority (libinput.h:195-197). Installed at ERROR priority in start()
/// (the same choice as wlroots backend.c:104-105).
fn libinputLogHandler(
    li: ?*c.libinput,
    priority: c_int,
    format: [*:0]const u8,
    args: *std.builtin.VaList,
) callconv(.c) void {
    _ = li;
    const io = handler_io orelse return;
    const cfg = handler_cfg orelse return;
    const level: log_mod.Level = switch (priority) {
        log_priority_debug => .debug,
        log_priority_info => .info,
        log_priority_error => .err,
        else => return,
    };
    // The only way to consume a C va_list: vsnprintf into a stack buffer.
    var buf: [1024]u8 = undefined;
    const n = c.vsnprintf(&buf, buf.len, format, args);
    if (n < 0) return;
    const len: usize = @min(@as(usize, @intCast(n)), buf.len);
    log_mod.log("{s}", io, cfg, level, "libinput", .{buf[0..len]});
}

/// open_restricted: plain open of the evdev node (no logind session in the
/// VM). libinput passes open(2) flags; evdev always opens
/// O_RDWR|O_NONBLOCK|O_CLOEXEC, so the passed flags are ignored (the
/// session-based wlroots impl effectively does the same for input devices).
fn openRestricted(path: [*:0]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = flags;
    _ = user_data;
    const o: std.os.linux.O = .{
        .ACCMODE = .RDWR,
        .NONBLOCK = true,
        .CLOEXEC = true,
        .NOCTTY = true,
    };
    // std.posix.open is gone in 0.16; the raw syscall returns the fd or a
    // negated errno (std.os.linux.write/close are used the same way in
    // compositor/xkb.zig).
    const rc = std.os.linux.open(path, o, 0);
    if (rc > std.math.maxInt(usize) / 2) {
        // The libinput_interface contract: negative errno on failure.
        return -@as(c_int, @intFromEnum(std.os.linux.errno(rc)));
    }
    return @intCast(rc);
}

fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    _ = std.os.linux.close(fd);
}

const libinput_interface_impl: c.libinput_interface = .{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

/// Open the udev hotplug monitor on the input subsystem. The "udev"
/// netlink group carries the events udevd has already processed (the
/// "kernel" group is the raw uevent stream, in which a /dev/input node
/// may not exist yet) — the same stream libinput's own udev context
/// follows. The in-kernel filter drops everything that is not the input
/// subsystem, so hotplugPollFd() only wakes for input devices.
fn createHotplug(self: *Libinput) !*c.udev_monitor {
    const udev = self.udev orelse return error.BackendFailed;
    const monitor = c.udev_monitor_new_from_netlink(udev, "udev") orelse return error.BackendFailed;
    errdefer _ = c.udev_monitor_unref(monitor);
    if (c.udev_monitor_filter_add_match_subsystem_devtype(monitor, "input", null) < 0) {
        return error.BackendFailed;
    }
    if (c.udev_monitor_enable_receiving(monitor) < 0) return error.BackendFailed;
    log_mod.info("udev hotplug monitor armed on the input subsystem", self.io, self.log_cfg, "libinput", .{});
    return monitor;
}

fn start(base: *backend.Backend) error{BackendFailed}!void {
    const self: *Libinput = @ptrCast(@alignCast(base.data));
    std.debug.assert(self.ctx == null);

    self.udev = c.udev_new() orelse return error.BackendFailed;
    errdefer {
        _ = c.udev_unref(self.udev);
        self.udev = null;
    }

    // Context lifecycle follows wlroots backend_start (backend.c): create
    // the udev context, assign the seat, then drain the initial events.
    // The log handler goes in right after creation so libinput-side
    // diagnostics land in the compositor log (wlroots backend.c:104-105).
    handler_io = self.io;
    handler_cfg = self.log_cfg;
    self.ctx = c.libinput_udev_create_context(&libinput_interface_impl, self, self.udev) orelse
        return error.BackendFailed;
    errdefer {
        _ = c.libinput_unref(self.ctx);
        self.ctx = null;
    }
    c.libinput_log_set_handler(self.ctx, libinputLogHandler);
    c.libinput_log_set_priority(self.ctx, log_priority_error);

    if (c.libinput_udev_assign_seat(self.ctx, self.seat_name.ptr) != 0) {
        log_mod.err("libinput seat assign failed (seat {s})", self.io, self.log_cfg, "libinput", .{self.seat_name});
        return error.BackendFailed;
    }

    // Hotplug watch, opened AFTER the seat assignment on purpose: libinput
    // is armed from here on and posts DEVICE_ADDED/DEVICE_REMOVED for
    // every device that appears later, so the window where this monitor
    // is not listening yet is covered by libinput. The reverse order
    // would leave a window in which only this monitor can see a device —
    // and it does not announce (see onHotplugDevice).
    self.hotplug = createHotplug(self) catch null;
    if (self.hotplug == null) {
        log_mod.warn(
            "udev hotplug monitor unavailable; device add/remove still arrives through libinput's own udev context",
            self.io,
            self.log_cfg,
            "libinput",
            .{},
        );
    }

    // Assigning the seat queues DEVICE_ADDED for every device on it; they
    // arrive on the first dispatch (wlroots drains in backend_start too).
    self.dispatch() catch {
        log_mod.err("libinput initial dispatch failed", self.io, self.log_cfg, "libinput", .{});
        return error.BackendFailed;
    };

    // Zero-device check (wlroots backend.c:112-116): an empty registry
    // usually means a broken udev/seat config, and a healthy-looking
    // backend with no devices is worse than a failed start.
    // WLR_LIBINPUT_NO_DEVICES=1 suppresses the check.
    if (zeroDeviceCheckEnabled(std.c.getenv("WLR_LIBINPUT_NO_DEVICES")) and
        self.devices.items.items.len == 0)
    {
        log_mod.err(
            "libinput: no input devices found; set WLR_LIBINPUT_NO_DEVICES=1 to suppress this check",
            self.io,
            self.log_cfg,
            "libinput",
            .{},
        );
        return error.BackendFailed;
    }

    log_mod.info("libinput backend started (seat {s}, output {d}x{d})", self.io, self.log_cfg, "libinput", .{
        self.seat_name, self.output_width, self.output_height,
    });
}

fn destroy(allocator: std.mem.Allocator, data: *anyopaque) void {
    const self: *Libinput = @ptrCast(@alignCast(data));
    // The monitor was built from the udev context and owns its socket fd,
    // so it goes before that context.
    if (self.hotplug) |monitor| _ = c.udev_monitor_unref(monitor);
    self.devices.deinit(allocator);
    if (self.ctx) |ctx| _ = c.libinput_unref(ctx);
    if (self.udev) |udev| _ = c.udev_unref(udev);
    handler_io = null;
    handler_cfg = null;
    allocator.destroy(self);
}

pub const LibinputBackend = struct {
    /// Create the libinput backend. The libinput context is created in
    /// start() (Backend.Impl.start), not here, matching wlroots.
    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        seat: *seat_mod.Seat,
        seat_name: [:0]const u8,
        output_width: u32,
        output_height: u32,
    ) !*backend.Backend {
        std.debug.assert(output_width > 0);
        std.debug.assert(output_height > 0);

        const self = try allocator.create(Libinput);
        errdefer allocator.destroy(self);
        self.* = .{
            // SAFETY: assigned right after Backend.init, before any use.
            .base = undefined,
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .seat = seat,
            .seat_name = seat_name,
            .output_width = output_width,
            .output_height = output_height,
        };

        const base = try backend.Backend.init(allocator, io, log_cfg, &backend_impl, self);
        errdefer base.destroy();
        self.base = base;
        return base;
    }

    /// Recover the Libinput impl from the Backend for pollFd()/dispatch().
    pub fn fromBackend(base: *backend.Backend) *Libinput {
        return @ptrCast(@alignCast(base.data));
    }

    /// Announce tablet hardware to `tablet` (shell/tablet.zig) instead of
    /// dropping it: a node with LIBINPUT_DEVICE_CAP_TABLET_TOOL or
    /// _TABLET_PAD is registered as a zwp_tablet_v2 (and, for a pad, a
    /// zwp_tablet_pad_v2), and its tool and pad events are translated
    /// from there on.
    ///
    /// Call it BEFORE start(): the initial udev drain inside start() is
    /// what registers a tablet that was already plugged in, and it is the
    /// same path a hotplug takes. The module must outlive the backend —
    /// the backend calls into it for as long as it dispatches.
    pub fn attachTablet(base: *backend.Backend, tablet: *tablet_mod.Tablet) void {
        LibinputBackend.fromBackend(base).tablet = tablet;
    }
};

// ---------------------------------------------------------------------------
// Tests — pure logic only (no real devices; the device path is
// VM-verified with scripts/uinput-devices.py)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "evdev to xkb offset" {
    // KEY_A scancode 30 -> xkb keycode 38; KEY_ESC 1 -> 9.
    try testing.expectEqual(@as(u32, 38), evdevToXkb(30));
    try testing.expectEqual(@as(u32, 9), evdevToXkb(1));
    try testing.expectEqual(evdev_to_xkb_offset, evdevToXkb(0));
}

test "absolute coordinate scaling" {
    try testing.expectApproxEqAbs(@as(f64, 400.0), scaleToOutput(0.5, 800), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 800.0), scaleToOutput(1.0, 800), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), scaleToOutput(0.0, 800), 0.0001);
    // 0..0xFFFF device range normalized then scaled: midpoint maps to the
    // output midpoint.
    try testing.expectApproxEqAbs(@as(f64, 400.0), scaleToOutput(@as(f64, 0x8000) / @as(f64, 0xFFFF), 800), 0.01);
}

test "axis conversion" {
    // One wheel click: libinput reports 15.0 degrees; the seat convention
    // is 10 px per notch.
    try testing.expectApproxEqAbs(@as(f64, 10.0), axisValueToPixels(15.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, -10.0), axisValueToPixels(-15.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), axisValueToPixels(0.0), 0.0001);
    try testing.expectEqual(@as(i32, 1), axisDiscreteToNotches(1.0));
    try testing.expectEqual(@as(i32, 0), axisDiscreteToNotches(0.4));
    try testing.expectEqual(@as(i32, -2), axisDiscreteToNotches(-1.6));
}

test "axis source mapping and per-source scaling" {
    // libinput source -> wl_pointer.axis_source (wlroots
    // backend/libinput/pointer.c:69-86).
    try testing.expectEqual(
        @as(?server.wl.Pointer.AxisSource, .wheel),
        axisSourceFromLibinput(pointer_axis_source_wheel),
    );
    try testing.expectEqual(
        @as(?server.wl.Pointer.AxisSource, .finger),
        axisSourceFromLibinput(pointer_axis_source_finger),
    );
    try testing.expectEqual(
        @as(?server.wl.Pointer.AxisSource, .continuous),
        axisSourceFromLibinput(pointer_axis_source_continuous),
    );
    try testing.expectEqual(
        @as(?server.wl.Pointer.AxisSource, .wheel_tilt),
        axisSourceFromLibinput(pointer_axis_source_wheel_tilt),
    );
    try testing.expectEqual(@as(?server.wl.Pointer.AxisSource, null), axisSourceFromLibinput(0));

    // WHEEL: degrees, 15.0 per click -> 10 px per notch.
    try testing.expectApproxEqAbs(@as(f64, 10.0), axisValueToPixelsSource(.wheel, 15.0), 0.0001);
    // FINGER/CONTINUOUS: cursor-equivalent units, 1.0 = 1 px (pass-through).
    try testing.expectApproxEqAbs(@as(f64, 3.5), axisValueToPixelsSource(.finger, 3.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, -2.0), axisValueToPixelsSource(.continuous, -2.0), 0.0001);
    // Discrete: wheel clicks rounded; finger/continuous always 0
    // (libinput.h:1653-1657).
    try testing.expectEqual(@as(i32, -2), axisDiscreteForSource(.wheel, -1.6));
    try testing.expectEqual(@as(i32, 0), axisDiscreteForSource(.finger, 1.6));
    try testing.expectEqual(@as(i32, 0), axisDiscreteForSource(.continuous, 1.6));
}

test "v120 deltas normalize to legacy clicks" {
    // B28: libinput high-resolution wheel deltas are ±120 per logical
    // click; the seat contract is legacy clicks (10 px per notch).
    try testing.expectEqual(@as(i32, 1), v120ToNotches(120.0));
    try testing.expectEqual(@as(i32, 2), v120ToNotches(240.0));
    try testing.expectEqual(@as(i32, -1), v120ToNotches(-120.0));
    try testing.expectEqual(@as(i32, -3), v120ToNotches(-360.0));
    // Fractional deltas (hi-res sub-notch, e.g. one third of a click):
    // the value carries the fraction; the discrete rounds to whole
    // notches (round-half-away-from-zero).
    try testing.expectEqual(@as(i32, 1), v120ToNotches(60.0));
    try testing.expectEqual(@as(i32, 0), v120ToNotches(40.0));
    try testing.expectEqual(@as(i32, 0), v120ToNotches(-40.0));
    try testing.expectEqual(@as(i32, 0), v120ToNotches(0.0));
}

test "zero-device check honors WLR_LIBINPUT_NO_DEVICES" {
    // B29: the startup check stays on unless the env var is exactly "1"
    // (wlroots env_parse_bool, util/env.c).
    try testing.expect(zeroDeviceCheckEnabled(null));
    try testing.expect(zeroDeviceCheckEnabled(""));
    try testing.expect(zeroDeviceCheckEnabled("0"));
    try testing.expect(zeroDeviceCheckEnabled("true"));
    try testing.expect(!zeroDeviceCheckEnabled("1"));
}

test "LED state derives from locked modifiers" {
    // B30: wl_keyboard.modifiers layout — Lock (bit 1) -> Caps Lock,
    // Mod2 (bit 4) -> Num Lock; bits match libinput's enum libinput_led.
    try testing.expectEqual(@as(c_int, 0), ledsFromModsLocked(0));
    try testing.expectEqual(@as(c_int, led_caps_lock), ledsFromModsLocked(1 << 1));
    try testing.expectEqual(@as(c_int, led_num_lock), ledsFromModsLocked(1 << 4));
    try testing.expectEqual(@as(c_int, led_caps_lock | led_num_lock), ledsFromModsLocked((1 << 1) | (1 << 4)));
    // Non-LED locked modifiers (Shift = bit 0, Mod4 = bit 6) contribute
    // nothing.
    try testing.expectEqual(@as(c_int, 0), ledsFromModsLocked((1 << 0) | (1 << 6)));
}

test "capability to kind mapping" {
    // capsMask queries the real libinput per capability (bool per cap) and
    // kindForCaps classifies the mask, so the unit level covers the whole
    // classification and the VM E2E exercises the FFI against real
    // devices.
    try testing.expectEqual(device_cap_keyboard, 0);
    try testing.expectEqual(device_cap_pointer, 1);
    try testing.expectEqual(device_cap_touch, 2);
    try testing.expectEqual(device_cap_tablet_tool, 3);
    try testing.expectEqual(device_cap_tablet_pad, 4);

    // Keyboard and pointer keep their priority.
    try testing.expectEqual(@as(?InputKind, .keyboard), kindForCaps(capsBit(device_cap_keyboard)));
    try testing.expectEqual(@as(?InputKind, .pointer), kindForCaps(capsBit(device_cap_pointer)));
    // Touch hardware is no longer dropped: a touch screen, a graphics
    // tablet and a tablet pad all classify as touch and are announced.
    try testing.expectEqual(@as(?InputKind, .touch), kindForCaps(capsBit(device_cap_touch)));
    try testing.expectEqual(@as(?InputKind, .touch), kindForCaps(capsBit(device_cap_tablet_tool)));
    try testing.expectEqual(@as(?InputKind, .touch), kindForCaps(capsBit(device_cap_tablet_pad)));
    try testing.expectEqual(
        @as(?InputKind, .touch),
        kindForCaps(capsBit(device_cap_tablet_tool) | capsBit(device_cap_tablet_pad)),
    );
    // A touchpad (pointer + touch + gesture) stays a pointer device; its
    // finger events still arrive as TOUCH_* events.
    try testing.expectEqual(
        @as(?InputKind, .pointer),
        kindForCaps(capsBit(device_cap_pointer) | capsBit(device_cap_touch) | capsBit(device_cap_gesture)),
    );
    try testing.expectEqual(
        @as(?InputKind, .pointer),
        kindForCaps(capsBit(device_cap_pointer) | capsBit(device_cap_touch)),
    );
    try testing.expectEqual(
        @as(?InputKind, .keyboard),
        kindForCaps(capsBit(device_cap_keyboard) | capsBit(device_cap_touch)),
    );
    // A gesture-only or switch-only node drives neither wl_pointer nor
    // wl_touch, so it stays unannounced.
    try testing.expectEqual(@as(?InputKind, null), kindForCaps(capsBit(device_cap_gesture)));
    try testing.expectEqual(@as(?InputKind, null), kindForCaps(capsBit(device_cap_switch)));
    try testing.expectEqual(@as(?InputKind, null), kindForCaps(0));
}

test "event type dispatch mapping" {
    try testing.expectEqualStrings("device added", eventTypeName(event_device_added));
    try testing.expectEqualStrings("device removed", eventTypeName(event_device_removed));
    try testing.expectEqualStrings("keyboard key", eventTypeName(event_keyboard_key));
    try testing.expectEqualStrings("pointer motion", eventTypeName(event_pointer_motion));
    try testing.expectEqualStrings("pointer motion absolute", eventTypeName(event_pointer_motion_absolute));
    try testing.expectEqualStrings("pointer button", eventTypeName(event_pointer_button));
    try testing.expectEqualStrings("pointer axis", eventTypeName(event_pointer_axis));
    // libinput 1.19+ scroll events: SCROLL_WHEEL is consumed (v120 wheel
    // path); SCROLL_FINGER/CONTINUOUS are ignored (their POINTER_AXIS
    // twins carry the data).
    try testing.expectEqualStrings("pointer scroll wheel", eventTypeName(event_pointer_scroll_wheel));
    // The touch block (libinput.h:873-881) has its own numeric range,
    // 500..504, and its frame event closes a touch batch.
    try testing.expectEqual(@as(c_int, 500), event_touch_down);
    try testing.expectEqual(@as(c_int, 501), event_touch_up);
    try testing.expectEqual(@as(c_int, 502), event_touch_motion);
    try testing.expectEqual(@as(c_int, 503), event_touch_cancel);
    try testing.expectEqual(@as(c_int, 504), event_touch_frame);
    try testing.expectEqualStrings("touch down", eventTypeName(event_touch_down));
    try testing.expectEqualStrings("touch up", eventTypeName(event_touch_up));
    try testing.expectEqualStrings("touch motion", eventTypeName(event_touch_motion));
    try testing.expectEqualStrings("touch cancel", eventTypeName(event_touch_cancel));
    try testing.expectEqualStrings("touch frame", eventTypeName(event_touch_frame));
    try testing.expectEqualStrings("other", eventTypeName(5000)); // outside every named range
}

test "button constants match the seat" {
    try testing.expectEqual(seat_mod.btn_left, btn_left);
    try testing.expectEqual(seat_mod.btn_right, btn_right);
    try testing.expectEqual(seat_mod.btn_middle, btn_middle);
}

test "touch events translate to seat points" {
    // The wl_touch id is libinput's seat slot, forwarded unchanged...
    try testing.expectEqual(@as(?c_int, 0), touchPointId(0));
    try testing.expectEqual(@as(?c_int, 7), touchPointId(7));
    try testing.expectEqual(@as(?c_int, 1234), touchPointId(1234));
    // ... and a negative slot (which libinput never sends) is dropped
    // rather than aliasing a live id in the client's id space.
    try testing.expectEqual(@as(?c_int, null), touchPointId(-1));

    // Coordinates: the pointer path's conversion, `_transformed(ev, 1)`
    // normalized to 0..1 and scaleToOutput onto the output.
    const center = touchPoint(3, 0.5, 0.5, 800, 600).?;
    try testing.expectEqual(@as(c_int, 3), center.id);
    try testing.expectApproxEqAbs(@as(f64, 400.0), center.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 300.0), center.y, 0.0001);

    const origin = touchPoint(0, 0.0, 0.0, 1280, 800).?;
    try testing.expectApproxEqAbs(@as(f64, 0.0), origin.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), origin.y, 0.0001);
    const far = touchPoint(0, 1.0, 1.0, 1280, 800).?;
    try testing.expectApproxEqAbs(@as(f64, 1280.0), far.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 800.0), far.y, 0.0001);
    // A real digitizer range (0..0xFFFF normalized to 0..1) lands on the
    // output midpoint.
    const digitizer = touchPoint(9, @as(f64, 0x8000) / @as(f64, 0xFFFF), 0.25, 800, 600).?;
    try testing.expectApproxEqAbs(@as(f64, 400.0), digitizer.x, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 150.0), digitizer.y, 0.0001);

    // No usable id, no point at all.
    try testing.expectEqual(@as(?TouchPoint, null), touchPoint(-1, 0.5, 0.5, 800, 600));
}

test "exactly one touch frame per batch" {
    var batch: TouchBatcher = .{};

    // An empty batch — a bare TOUCH_FRAME, or a dispatch that carried no
    // touch event at all — sends no frame.
    try testing.expect(!batch.flush());

    // Down, two motions, up: three delivered events, one frame when the
    // batch closes.
    batch.note();
    batch.note();
    batch.note();
    try testing.expect(batch.flush());
    // The close at the end of the event drain must not send a SECOND
    // frame for the batch libinput's own TOUCH_FRAME already closed.
    try testing.expect(!batch.flush());

    // The next sample (a second finger on the surface) is a new batch:
    // exactly one more frame.
    batch.note();
    try testing.expect(batch.flush());
    try testing.expect(!batch.flush());

    // A batch the queue cut short (the device vanished mid-sample) is
    // still closed once, at the end of the drain.
    batch.note();
    try testing.expect(batch.flush());
    try testing.expect(!batch.flush());
}

test "udev hotplug maps only add and remove" {
    try testing.expectEqual(@as(?UdevAction, .add), udevActionFromName("add"));
    try testing.expectEqual(@as(?UdevAction, .remove), udevActionFromName("remove"));
    // A property update on a node that is already there (a lid switch
    // toggling, an LED write) and the driver transitions are not device
    // hotplug. The match is exact, like udev's own action strings.
    try testing.expectEqual(@as(?UdevAction, null), udevActionFromName("change"));
    try testing.expectEqual(@as(?UdevAction, null), udevActionFromName("bind"));
    try testing.expectEqual(@as(?UdevAction, null), udevActionFromName("unbind"));
    try testing.expectEqual(@as(?UdevAction, null), udevActionFromName("move"));
    try testing.expectEqual(@as(?UdevAction, null), udevActionFromName(""));
    try testing.expectEqual(@as(?UdevAction, null), udevActionFromName("Add"));
}

test "a node is registered once and pruned on removal" {
    const allocator = testing.allocator;
    var registry: DeviceRegistry = .{};
    defer registry.deinit(allocator);

    // Fabricated handles: the registry only compares the pointer (the
    // DEVICE_REMOVED event carries the handle the entry was registered
    // with) and never dereferences it.
    const touch_handle: *c.libinput_device = @ptrFromInt(0x1000);
    const mouse_handle: *c.libinput_device = @ptrFromInt(0x2000);

    // A touch screen classifies as touch hardware, so it reaches the
    // registry (and the new_input announcement right behind the insert)
    // instead of being dropped.
    const touch_name = try allocator.dupeZ(u8, "Virtual Touchscreen");
    const touch_sysname = try allocator.dupeZ(u8, "event5");
    try testing.expect(try registry.insert(allocator, .{
        .handle = touch_handle,
        .kind = kindForCaps(capsBit(device_cap_touch)).?,
        .name = touch_name,
        .sysname = touch_sysname,
    }));
    try testing.expectEqual(@as(usize, 1), registry.items.items.len);
    try testing.expectEqual(@as(?usize, 0), registry.findBySysname("event5"));
    try testing.expectEqual(@as(?usize, 0), registry.findByHandle(touch_handle));

    // The same node seen a second time (libinput's udev context and this
    // backend's monitor both watch udev) must not become a second entry:
    // one physical device, one announcement.
    const dup_name = try allocator.dupeZ(u8, "Virtual Touchscreen");
    const dup_sysname = try allocator.dupeZ(u8, "event5");
    try testing.expect(!try registry.insert(allocator, .{
        .handle = @ptrFromInt(0x3000),
        .kind = .touch,
        .name = dup_name,
        .sysname = dup_sysname,
    }));
    // A rejected entry's strings stay owned by the caller.
    freeDevice(allocator, dup_name, dup_sysname);
    try testing.expectEqual(@as(usize, 1), registry.items.items.len);
    try testing.expectEqual(@as(?usize, null), registry.findByHandle(@ptrFromInt(0x3000)));

    // A second node registers beside it, so a removal targets exactly one
    // device.
    const mouse_name = try allocator.dupeZ(u8, "Virtual Mouse");
    const mouse_sysname = try allocator.dupeZ(u8, "event6");
    try testing.expect(try registry.insert(allocator, .{
        .handle = mouse_handle,
        .kind = .pointer,
        .name = mouse_name,
        .sysname = mouse_sysname,
    }));
    try testing.expectEqual(@as(usize, 2), registry.items.items.len);

    // Two fingers down on the touchscreen: its disappearance owes the
    // client a wl_touch.cancel.
    registry.items.items[0].touch_points = 2;
    try testing.expect(!owesTouchCancel(registry.items.items[1]));

    // The udev remove path prunes by node name.
    const index = registry.findBySysname("event5").?;
    const removed = registry.takeAt(index);
    try testing.expect(owesTouchCancel(removed));
    try testing.expectEqual(@as(u16, 2), removed.touch_points);
    try testing.expectEqualStrings("Virtual Touchscreen", removed.name);
    freeDevice(allocator, removed.name, removed.sysname);
    try testing.expectEqual(@as(usize, 1), registry.items.items.len);
    try testing.expectEqual(@as(?usize, null), registry.findBySysname("event5"));
    // libinput's DEVICE_REMOVED twin of the same device, arriving after
    // the monitor already pruned it, finds nothing (idempotent).
    try testing.expectEqual(@as(?usize, null), registry.findByHandle(touch_handle));
    // The surviving device is untouched by the neighbour's removal.
    try testing.expectEqual(@as(?usize, 0), registry.findByHandle(mouse_handle));
    // A node that was never announced (libinput ignores devices that are
    // not on this seat) is not the removal of anything.
    try testing.expectEqual(@as(?usize, null), registry.findBySysname("event9"));
    // An entry with no node name cannot be correlated with a hotplug
    // notification and never matches.
    try testing.expectEqual(@as(?usize, null), registry.findBySysname(""));
}

test "tablet enums map from libinput" {
    // The libinput tool types, in enum order (libinput.h:2888-2909).
    try testing.expectEqual(@as(c_int, 600), event_tablet_tool_axis);
    try testing.expectEqual(@as(c_int, 601), event_tablet_tool_proximity);
    try testing.expectEqual(@as(c_int, 602), event_tablet_tool_tip);
    try testing.expectEqual(@as(c_int, 603), event_tablet_tool_button);
    try testing.expectEqual(@as(c_int, 700), event_tablet_pad_button);
    try testing.expectEqual(@as(c_int, 701), event_tablet_pad_ring);
    try testing.expectEqual(@as(c_int, 702), event_tablet_pad_strip);
    try testing.expectEqual(@as(c_int, 703), event_tablet_pad_key);
    try testing.expectEqual(@as(c_int, 704), event_tablet_pad_dial);
    try testing.expectEqualStrings("tablet tool proximity", eventTypeName(event_tablet_tool_proximity));
    try testing.expectEqualStrings("tablet pad dial", eventTypeName(event_tablet_pad_dial));

    // Every tool type zwp_tablet_tool_v2.type enumerates, in the same
    // order (tablet-v2.xml:265-272).
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, .pen), tabletToolType(tablet_tool_type_pen));
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, .eraser), tabletToolType(tablet_tool_type_eraser));
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, .brush), tabletToolType(tablet_tool_type_brush));
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, .pencil), tabletToolType(tablet_tool_type_pencil));
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, .airbrush), tabletToolType(tablet_tool_type_airbrush));
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, .mouse), tabletToolType(tablet_tool_type_mouse));
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, .lens), tabletToolType(tablet_tool_type_lens));
    // Totem is a libinput tool type the protocol does not enumerate
    // (libinput.h:371-372), so it has no type to be announced as.
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, null), tabletToolType(tablet_tool_type_totem));
    // An unknown value is not guessed at: the tool is not registered.
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, null), tabletToolType(0));
    try testing.expectEqual(@as(?server.zwp.TabletToolV2.Type, null), tabletToolType(9));

    // The five buses zwp_tablet_v2.bustype enumerates, and only those.
    try testing.expectEqual(@as(?server.zwp.TabletV2.Bustype, .usb), tabletBustype(bus_usb));
    try testing.expectEqual(@as(?server.zwp.TabletV2.Bustype, .bluetooth), tabletBustype(bus_bluetooth));
    try testing.expectEqual(@as(?server.zwp.TabletV2.Bustype, .virtual), tabletBustype(bus_virtual));
    try testing.expectEqual(@as(?server.zwp.TabletV2.Bustype, .serial), tabletBustype(bus_serial));
    try testing.expectEqual(@as(?server.zwp.TabletV2.Bustype, .i2c), tabletBustype(bus_i2c));
    // BUS_PCI and every other bus the protocol does not name: bustype is
    // optional, so no event is the right answer.
    try testing.expectEqual(@as(?server.zwp.TabletV2.Bustype, null), tabletBustype(0x01));
    try testing.expectEqual(@as(?server.zwp.TabletV2.Bustype, null), tabletBustype(0));

    // The mode-group counts: libinput answers per index, the protocol
    // announces how many.
    try testing.expectEqual(@as(u32, 0), ownedCount(0, struct {
        fn has(_: u32) bool {
            return true;
        }
    }.has));
    try testing.expectEqual(@as(u32, 4), ownedCount(4, struct {
        fn has(_: u32) bool {
            return true;
        }
    }.has));
    try testing.expectEqual(@as(u32, 2), ownedCount(4, struct {
        fn has(index: u32) bool {
            return index % 2 == 0;
        }
    }.has));
    try testing.expectEqual(@as(u32, 0), ownedCount(4, struct {
        fn has(_: u32) bool {
            return false;
        }
    }.has));
}

test "tool capability burst follows the axes libinput reports" {
    const Capability = server.zwp.TabletToolV2.Capability;
    var out: [tablet_capability_count]Capability = undefined;
    // expectEqual on a slice compares the POINTER and the length, never
    // the elements, so the order this test exists to pin is compared with
    // expectEqualSlices.
    const none: []const Capability = &.{};
    const pressure_only: []const Capability = &.{.pressure};
    // The XML's own order (tilt, pressure, distance, rotation, slider,
    // wheel), not the order the axes struct happens to list them in.
    const airbrush: []const Capability = &.{ .tilt, .pressure, .slider };
    const everything: []const Capability = &.{ .tilt, .pressure, .distance, .rotation, .slider, .wheel };

    // A tool with no axis announces no capability (the burst can be empty,
    // tablet-v2.xml:340-344).
    try testing.expectEqualSlices(Capability, none, tabletToolCapabilities(.{}, &out));
    // A plain pen: pressure only.
    try testing.expectEqualSlices(Capability, pressure_only, tabletToolCapabilities(.{ .pressure = true }, &out));
    // An airbrush: tilt, pressure and slider, in the protocol's order.
    try testing.expectEqualSlices(
        Capability,
        airbrush,
        tabletToolCapabilities(.{ .slider = true, .pressure = true, .tilt = true }, &out),
    );
    // Everything a tool can have, and nothing more: the array is sized by
    // the protocol's own six capabilities.
    const all = tabletToolCapabilities(.{
        .pressure = true,
        .distance = true,
        .tilt = true,
        .rotation = true,
        .slider = true,
        .wheel = true,
    }, &out);
    try testing.expectEqual(@as(usize, tablet_capability_count), all.len);
    try testing.expectEqualSlices(Capability, everything, all);
}

// ---------------------------------------------------------------------------
// The tablet translation against a REAL zwp_tablet_manager_v2: a client on
// the other end of a socketpair reads the events, so the assertions below
// are what a Wayland client would see, in order.
// ---------------------------------------------------------------------------

/// A libinput backend with no libinput context. The tablet paths read only
/// the registry, the seat and the tablet module, so they run without one;
/// start() is not called because it would need a live udev context.
const tablet_test_impl: backend.Backend.Impl = .{
    .start = struct {
        fn start(_: *backend.Backend) error{BackendFailed}!void {}
    }.start,
    .destroy = struct {
        fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
    }.destroy,
};

/// A libinput backend attached to a real tablet module, its seat, its
/// client-facing log, and one registered device the tests feed fabricated
/// tablet events to.
const TabletFixture = struct {
    allocator: std.mem.Allocator,
    /// The tablet module's own test server: display, compositor, seat,
    /// tablet module and a client that reads the wire.
    test_server: *tablet_mod.TestServer,
    libinput: *Libinput,
    base: *backend.Backend,
    surface: *surface_mod.Surface,
    /// Whether the hit test finds the surface. Clearing it models the
    /// pointer leaving every surface, which is how a tablet tool and a pad
    /// lose their focus surface.
    hits: bool = true,

    fn init(allocator: std.mem.Allocator) !*TabletFixture {
        const ts = try tablet_mod.TestServer.init(allocator, tablet_mod.tablet_v2_version);
        errdefer ts.deinit();
        // A live zwp_tablet_seat_v2: everything below is announced to it.
        _ = try ts.getTabletSeat();
        const made = try ts.makeSurface();

        const self = try allocator.create(TabletFixture);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .test_server = ts,
            .libinput = undefined,
            .base = undefined,
            .surface = made.surface,
        };
        // The seat has no compositor hit test here; one surface covers
        // every point, which is all a tablet focus needs.
        ts.seat.?.setPick(pickTestSurface, self);
        ts.seat.?.pointerMotion(10, 20);

        const libinput = try allocator.create(Libinput);
        errdefer allocator.destroy(libinput);
        libinput.* = .{
            // SAFETY: Backend.init writes base.data and the field below is
            // assigned from it before any method can run.
            .base = undefined,
            .allocator = allocator,
            .io = &ts.io,
            .log_cfg = &ts.log_cfg,
            .seat = ts.seat.?,
            .seat_name = "seat0",
            .output_width = 800,
            .output_height = 600,
            .tablet = ts.tablet.?,
        };
        self.libinput = libinput;
        const base = try backend.Backend.init(allocator, &ts.io, &ts.log_cfg, &tablet_test_impl, libinput);
        errdefer base.destroy();
        libinput.base = base;
        self.base = base;
        return self;
    }

    /// Release the backend (which frees the registry's strings and the
    /// tablet descriptor arrays) and then the server, which frees the
    /// zwp objects the tablet module still holds. That order matters:
    /// the module's own deinit is what frees the hardware.
    fn deinit(self: *TabletFixture) void {
        self.base.destroy();
        self.libinput.devices.deinit(self.allocator);
        self.allocator.destroy(self.libinput);
        self.test_server.deinit();
        self.allocator.destroy(self);
    }

    /// Deliver what the server wrote and read it back into the client's
    /// event log.
    fn pump(self: *TabletFixture) !void {
        try self.test_server.pump();
    }

    /// The client's event log so far. EventLog.text is not `pub` in
    /// src/shell/tablet.zig (declared at its line 1475, in the harness
    /// exported for exactly this file), so the log's own exported
    /// buffer is read directly here. The fix belongs to that file:
    /// `pub fn text`, after which this is event_log.text() again.
    fn log(self: *TabletFixture) []const u8 {
        return self.test_server.event_log.buf[0..self.test_server.event_log.len];
    }

    /// Register one device with the tablet hardware `caps` implies. The
    /// libinput_device handle is fabricated — the registry only ever
    /// compares it, and reading it is the FFI half that readTabletInfo
    /// covers — while the descriptors handed to the tablet module are the
    /// same ones applyTabletInfo builds from a real device.
    fn addDevice(self: *TabletFixture, caps: u32) !usize {
        const name = try self.allocator.dupeZ(u8, "Wacom Intuos Pro M");
        errdefer self.allocator.free(name);
        const sysname = try self.allocator.dupeZ(u8, "event7");
        errdefer self.allocator.free(sysname);
        var entry: Device = .{
            .handle = @ptrFromInt(0x1000),
            .kind = kindForCaps(caps) orelse return error.Unclassified,
            .name = name,
            .sysname = sysname,
            .caps = caps,
        };
        if (caps & capsBit(device_cap_tablet_pad) != 0) {
            // Two mode groups, as a Wacom Cintiq reports (libinput.h:443-450
            // — "devices such as the Wacom Cintiq 22HD provide two mode
            // groups"): the first owns the ring and buttons 0 and 1, the
            // second buttons 2 and 3 and nothing else.
            const lists: []const []const u32 = &.{ &[_]u32{ 0, 1 }, &[_]u32{ 2, 3 } };
            self.libinput.applyTabletInfo(&entry, .{
                .name = entry.name,
                .vendor = 0x56a,
                .product = 0x0357,
                .bustype = .usb,
                .rings = 1,
                .groups = &.{
                    .{ .rings = 1, .modes = 1 },
                    .{ .modes = 3 },
                },
                .group_buttons = lists,
            });
        } else {
            self.libinput.applyTabletInfo(&entry, .{
                .name = entry.name,
                .vendor = 0x56a,
                .product = 0x0357,
                .bustype = .usb,
            });
        }
        if (!try self.libinput.devices.insert(self.allocator, entry)) return error.Duplicate;
        return self.libinput.devices.items.items.len - 1;
    }

    fn device(self: *TabletFixture, index: usize) *Device {
        return &self.libinput.devices.items.items[index];
    }

    /// Send one fabricated tool event through the same handler the FFI
    /// path uses.
    fn toolEvent(self: *TabletFixture, index: usize, event: TabletToolEvent) void {
        self.libinput.handleTabletToolEvent(self.device(index), event);
    }

    fn pickTestSurface(ctx: *anyopaque, _: i32, _: i32) ?seat_mod.Seat.PickResult {
        const self: *TabletFixture = @ptrCast(@alignCast(ctx));
        if (!self.hits) return null;
        return .{ .surface = self.surface, .sx = 0, .sy = 0 };
    }
};

test "a pen arrives, hovers, moves, leaves and its node dies in proximity" {
    const allocator = testing.allocator;
    const fixture = try TabletFixture.init(allocator);
    defer fixture.deinit();
    const index = try fixture.addDevice(capsBit(device_cap_tablet_tool));

    // The digitizer is announced on its own: libinput reports a tool only
    // from its first proximity_in, so nothing is announced yet.
    try fixture.pump();
    try testing.expectEqualStrings("tablet_added name id bustype done ", fixture.log());
    try testing.expectEqual(@as(usize, 0), fixture.device(index).tools.items.len);

    // Proximity in: the tool is registered (type, the hardware serial that
    // identifies this physical pen, the Wacom tool id and its two axes)
    // and entered on the focused surface.
    const pen: TabletToolEvent = .{
        .proximity_state = tablet_proximity_state_in,
        .tool_type = tablet_tool_type_pen,
        .serial = 0x1234,
        .unique = true,
        .tool_id = 0x802,
        .axes = .{ .pressure = true, .tilt = true },
    };
    fixture.toolEvent(index, pen);
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type hardware_serial hardware_id_wacom capability capability done proximity_in ",
        fixture.log(),
    );
    try testing.expectEqual(@as(usize, 1), fixture.device(index).tools.items.len);

    // Motion while the pen is down: an axis event carries no
    // zwp_tablet_manager_v2 event, so the tool stays entered and the log
    // does not move.
    fixture.libinput.syncToolProximity(fixture.device(index));
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type hardware_serial hardware_id_wacom capability capability done proximity_in ",
        fixture.log(),
    );

    // Proximity out, then in again: the SAME zwp_tablet_tool_v2 comes
    // back (one pen is one tool object for as long as it is on the
    // tablet), matched by the serial libinput reports it unique under.
    fixture.toolEvent(index, .{ .proximity_state = tablet_proximity_state_out, .tool_type = pen.tool_type, .serial = pen.serial, .unique = true });
    fixture.toolEvent(index, pen);
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type hardware_serial hardware_id_wacom capability capability done proximity_in proximity_out proximity_in ",
        fixture.log(),
    );
    try testing.expectEqual(@as(usize, 1), fixture.device(index).tools.items.len);

    // The node goes away with the pen still over the tablet: proximity_out
    // BEFORE removed (tablet-v2.xml:361-373), and the tablet itself is
    // removed after its tool.
    fixture.libinput.removeDeviceAt(index);
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type hardware_serial hardware_id_wacom capability capability done proximity_in proximity_out proximity_in proximity_out removed removed ",
        fixture.log(),
    );
    // Nothing is left in the registry, and the tablet module's own
    // registry is empty again.
    try testing.expectEqual(@as(usize, 0), fixture.libinput.devices.items.items.len);
    try testing.expectEqual(@as(usize, 0), fixture.test_server.tablet.?.tools.items.len);
    try testing.expectEqual(@as(usize, 0), fixture.test_server.tablet.?.tablets.items.len);
}

test "a second pen of the same type is its own tool" {
    const allocator = testing.allocator;
    const fixture = try TabletFixture.init(allocator);
    defer fixture.deinit();
    const index = try fixture.addDevice(capsBit(device_cap_tablet_tool));

    // A pen libinput cannot single out has no hardware_serial at all
    // (tablet-v2.xml:286-299), and libinput itself shares one object per
    // tool type — so two proximity cycles of one such pen are one
    // zwp_tablet_tool_v2...
    const generic: TabletToolEvent = .{
        .proximity_state = tablet_proximity_state_in,
        .tool_type = tablet_tool_type_pen,
        .serial = 0,
        .unique = false,
    };
    fixture.toolEvent(index, generic);
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type done proximity_in ",
        fixture.log(),
    );

    // ...while two pens that libinput DOES tell apart are two objects.
    fixture.toolEvent(index, .{
        .proximity_state = tablet_proximity_state_in,
        .tool_type = tablet_tool_type_pen,
        .serial = 0xaaaa,
        .unique = true,
    });
    fixture.toolEvent(index, .{
        .proximity_state = tablet_proximity_state_in,
        .tool_type = tablet_tool_type_pen,
        .serial = 0xbbbb,
        .unique = true,
    });
    try fixture.pump();
    try testing.expectEqual(@as(usize, 3), fixture.device(index).tools.items.len);
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type done proximity_in tool_added type hardware_serial done proximity_in tool_added type hardware_serial done proximity_in ",
        fixture.log(),
    );
}

test "a pad takes focus on its first event and leaves when the pointer does" {
    const allocator = testing.allocator;
    const fixture = try TabletFixture.init(allocator);
    defer fixture.deinit();
    const index = try fixture.addDevice(capsBit(device_cap_tablet_pad));

    // A pad-only node still gets the zwp_tablet_v2 its enter event will
    // name (tablet-v2.xml:1194-1202), and the pad is announced with one
    // group per libinput mode group: buttons, ring, strip, dial, done.
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done pad_added group buttons ring group_done group buttons modes group_done pad_buttons pad_done ",
        fixture.log(),
    );
    // The LAST group burst is the one the capture keeps: two buttons,
    // starting at index 2 — the mode groups partition the pad's buttons.
    try testing.expectEqual(@as(usize, 2), fixture.test_server.capture.group_buttons);
    try testing.expectEqual(@as(u32, 2), fixture.test_server.capture.first_button);

    // The pad is announced, not focused: no enter until it is used.
    fixture.libinput.focusTabletPad(fixture.device(index));
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done pad_added group buttons ring group_done group buttons modes group_done pad_buttons pad_done enter mode_switch mode_switch ",
        fixture.log(),
    );

    // The pointer leaves every surface and the pad is used again: the
    // leave names the surface it was focused on.
    fixture.hits = false;
    fixture.test_server.seat.?.pointerMotion(400, 300);
    fixture.libinput.focusTabletPad(fixture.device(index));
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done pad_added group buttons ring group_done group buttons modes group_done pad_buttons pad_done enter mode_switch mode_switch leave ",
        fixture.log(),
    );

    // Focus again, then the node goes away: leave before the pad's
    // removed, and the tablet it hangs off is removed last
    // (tablet-v2.xml:1209-1211).
    fixture.hits = true;
    fixture.test_server.seat.?.pointerMotion(20, 30);
    fixture.libinput.focusTabletPad(fixture.device(index));
    fixture.libinput.removeDeviceAt(index);
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done pad_added group buttons ring group_done group buttons modes group_done pad_buttons pad_done enter mode_switch mode_switch leave enter mode_switch mode_switch leave removed removed ",
        fixture.log(),
    );
    try testing.expectEqual(@as(usize, 0), fixture.test_server.tablet.?.pads.items.len);
    try testing.expectEqual(@as(usize, 0), fixture.test_server.tablet.?.tablets.items.len);
}

test "a tablet node removed through the hotplug path takes its tool with it" {
    const allocator = testing.allocator;
    const fixture = try TabletFixture.init(allocator);
    defer fixture.deinit();
    const index = try fixture.addDevice(capsBit(device_cap_tablet_tool));

    fixture.toolEvent(index, .{
        .proximity_state = tablet_proximity_state_in,
        .tool_type = tablet_tool_type_eraser,
        .serial = 0x99,
        .unique = true,
        .axes = .{ .pressure = true },
    });
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type hardware_serial capability done proximity_in ",
        fixture.log(),
    );

    // The udev monitor's remove path: it finds the entry by node name and
    // hands it to the same removeDeviceAt libinput's DEVICE_REMOVED uses,
    // so the tool is retired here too — and the client's eraser gets its
    // proximity_out before the removed.
    const found = fixture.libinput.devices.findBySysname("event7").?;
    fixture.libinput.removeDeviceAt(found);
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type hardware_serial capability done proximity_in proximity_out removed removed ",
        fixture.log(),
    );
    // The monitor's notification and libinput's own DEVICE_REMOVED race by
    // design: whichever lands second finds no entry to prune and sends
    // nothing at all.
    if (fixture.libinput.devices.findBySysname("event7")) |again| {
        fixture.libinput.removeDeviceAt(again);
    }
    try fixture.pump();
    try testing.expectEqualStrings(
        "tablet_added name id bustype done tool_added type hardware_serial capability done proximity_in proximity_out removed removed ",
        fixture.log(),
    );
}

test "without a tablet module a tablet node registers nothing" {
    const allocator = testing.allocator;
    const fixture = try TabletFixture.init(allocator);
    defer fixture.deinit();
    // A server built without the tablet module: the device is still
    // announced through new_input like any other, but nothing is
    // registered and no event is translated — never a crash on the null
    // module.
    fixture.libinput.tablet = null;
    const index = try fixture.addDevice(capsBit(device_cap_tablet_tool) | capsBit(device_cap_tablet_pad));

    try fixture.pump();
    try testing.expectEqualStrings("", fixture.log());
    try testing.expect(fixture.device(index).tablet == null);
    try testing.expect(fixture.device(index).pad == null);

    fixture.toolEvent(index, .{
        .proximity_state = tablet_proximity_state_in,
        .tool_type = tablet_tool_type_pen,
        .serial = 1,
        .unique = true,
    });
    fixture.libinput.focusTabletPad(fixture.device(index));
    fixture.libinput.syncToolProximity(fixture.device(index));
    fixture.libinput.removeDeviceAt(index);
    try fixture.pump();
    try testing.expectEqualStrings("", fixture.log());
    try testing.expectEqual(@as(usize, 0), fixture.libinput.devices.items.items.len);
}
