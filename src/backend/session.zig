//! Session management for the DRM/KMS backend: logind session lifecycle,
//! VT switching, and udev connector hotplug.
//!
//! # What this module owns
//! The DRM backend (backend/drm.zig) needs three things a raw card node
//! cannot give it, and this file is where they live:
//!
//!   1. A **logind session** that owns the seat, so the DRM master is not
//!      yanked back to the console session behind our back. This is the
//!      reason libseat exists at all: libseat opens a logind session and
//!      takes the device on it (libseat/session.c session_logind_create ->
//!      sd_login_open_session + sd_login_take_device).
//!   2. A **VT switch** to a virtual terminal this process controls,
//!      acknowledged by the DRM driver, and restored on shutdown
//!      (libseat session-vt.c session_vt_activate, session_vt_wait_for_ack,
//!      session_vt_restore).
//!   3. A **udev monitor** on the `drm` subsystem, so a connector arriving
//!      or leaving drives the same enumeration the initial modeset used
//!      (wlroots backend/drm/backend.c udev_handle DRM_ADD / DRM_REMOVE /
//!      DRM_CHANGE all call the same init_drm_connector /
//!      destroy_drm_connector pair as the startup path).
//!
//! It owns no compositor state: it reports what the seat says, hands out
//! fds to poll, and calls one callback. backend/drm.zig makes every policy
//! decision (which connector, which plane, when an output goes up or down).
//!
//! # Why the session manager is spoken over sd-bus
//! The libsystemd this project builds against does NOT export the
//! session-management half of sd-login.h. systemd >= 257 split it into
//! libsystemd-login, and nixpkgs#systemd does not build that library;
//! nixpkgs#systemd-minimal-libs ships only libsystemd.so.0 and
//! libudev.so.1. Verified against this closure:
//! `nm -D --defined-only libsystemd.so.0.44.0` exports exactly six
//! `sd_login_*` symbols - all of them `sd_login_monitor_*` - and none of
//! `sd_login_open_session`, `sd_login_take_device` or `sd_login_get_seat`.
//! libudev does not pull libsystemd in either (readelf -d libudev.so.1:
//! NEEDED libc.so.6 only), so even a dlopen by soname needs help finding
//! the object.
//!
//! So the session manager is spoken **directly over sd-bus to
//! org.freedesktop.login1.Manager**, calling the same methods
//! sd_login_open_session() calls internally, with the signatures
//! org.freedesktop.login1(5) documents:
//!   Manager.CreateSession()                       -> (o path, s id)
//!   Manager.ActivateSession(s id)
//!   Manager.TakeDevice(s id, s seat, u minor)
//!   Manager.ReleaseDevice(s id, s seat, u minor)
//!   Manager.SetIdleHint(b idle, s id)
//!   Manager.TerminateSession(s id)
//!   org.freedesktop.DBus.Properties.Set on Session.Type / Session.TTY
//!   signal PrepareForSleep(b)
//! The read-only half comes from libsystemd's file-based API, which IS
//! present and IS exported: sd_pid_get_session, sd_session_get_seat,
//! sd_session_get_vt, sd_seat_get_active, sd_seat_can_tty,
//! sd_seat_can_graphical, sd_seat_can_multi_session - all of which read
//! /run/systemd, as sd-login(7) describes.
//!
//! libsystemd is opened with std.DynLib (dlopen) rather than linked,
//! because build.zig - which this module must not touch - does not put
//! libsystemd on the link line. If the integration owner adds
//! `lib.linkSystemLibrary("systemd")` plus a translate-c shim for
//! <systemd/sd-bus.h>, `Systemd.open` becomes the only thing that changes:
//! every other symbol below already carries its exact Zig signature.
//!
//! # Failure policy (the contract the backend relies on)
//! NOTHING here is required for the compositor to run:
//!   - no libsystemd, or no logind seat -> error.SystemdUnavailable; the
//!     backend runs exactly as it did before, which is the VM case
//!     (/dev/dri/card0, first opener is master, no console to fight over).
//!   - logind says this seat will not host us -> error.SeatUnavailable,
//!     with the reason logged. The backend still starts.
//!   - no system bus -> error.BusUnavailable. Still starts.
//!   - a Manager method refused -> error.LogindRejected, after everything
//!     created so far has been torn down again. Still starts.
//!   - no /dev/tty0 -> there is no console to switch: activateVt answers
//!     error.NoConsole, the session keeps the VT it already had, and the
//!     backend proceeds.
//!   - a VT_ACTIVATE that is never acknowledged -> error.AckTimeout AFTER
//!     the console has been put back; the backend proceeds.
//! The only outcome the backend must treat as "do not take the card" is
//! `Plan.blocked` from `planAcquire` - and even that is reported, not
//! fatal, because the alternative (a compositor that refuses to start
//! because somebody else's session is on the seat) is worse.
//!
//! # Kernel uapi spoken here, cited
//!   VT_ACTIVATE, VT_ACK, VT_RELDISP      uapi/linux/vt.h
//!   struct vt_event                     uapi/linux/vt.h
//!   the VT ack on a DRM fd             drm_fops.c drm_handle_vt_event: the
//!                                      DRM core registers a console
//!                                      notifier per open card and queues a
//!                                      `struct vt_event` to the client,
//!                                      which is the read libseat's
//!                                      session_vt_wait_for_ack() performs.
//!
//! # Imports
//! utils/log.zig and std only. This module deliberately does NOT import the
//! DRM shim, so it stays compilable (and testable) on its own: the DRM
//! backend passes in the card minor and the fd whose VT_ACK to wait for.

const std = @import("std");
const log_mod = @import("../utils/log.zig");

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Why a session could not be established. Every one is non-fatal for the
/// compositor: the DRM backend logs the name and keeps running without a
/// session (see the module's failure policy).
pub const Error = error{
    /// libsystemd could not be dlopen'd, it lacks a symbol this file needs,
    /// or there is no logind seat on this machine. The VM case.
    SystemdUnavailable,
    /// logind knows a seat, but this seat will not host the compositor: it
    /// is not graphics capable, or it cannot share and is occupied.
    SeatUnavailable,
    /// The system bus could not be opened or reached logind on it.
    BusUnavailable,
    /// logind refused a Manager method. Everything created so far has
    /// already been torn down by the time this is returned.
    LogindRejected,
    /// Out of memory.
    OutOfMemory,
};

/// Why the VT half of the session failed. All three are non-fatal: the
/// session runs on the console VT it found, with the old VT restored.
pub const VtError = error{
    /// /dev/tty0 could not be opened: there is no VT to switch to.
    NoConsole,
    /// VT_ACTIVATE was refused by the console driver.
    ActivateFailed,
    /// The DRM driver never acknowledged the switch (or something else was
    /// on the fd, so the ack could not be read).
    AckTimeout,
};

/// Why the udev monitor could not be brought up. Non-fatal: the initial
/// enumeration still runs, connector changes are simply not noticed.
pub const HotplugError = error{
    /// libudev is missing, the netlink monitor could not be created, or the
    /// monitor struct could not be allocated.
    UdevUnavailable,
    /// Out of memory.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// VT constants and the console fd
// ---------------------------------------------------------------------------

/// `VT_ACTIVATE` - make this VT the active one (uapi/linux/vt.h: "Set the
/// virtual terminal to be the active one"). The VT number is the ioctl's
/// unsigned long argument, exactly as libseat passes it.
const vt_activate: u32 = 0x5603;
/// `VT_RELDISP` - "the console is being redrawn"; the notification that
/// precedes VT_ACK during a switch (uapi/linux/vt.h: "#define VT_RELDISP 3").
const vt_reldisp: c_int = 3;
/// `VT_ACK` - "the VT has been switched" (uapi/linux/vt.h:
/// "#define VT_ACK 4"). The `count` a struct vt_event carries when the
/// driver has finished.
const vt_ack: c_int = 4;

/// `struct vt_event` (uapi/linux/vt.h):
///     struct vt_event { int count; int sigio; };
/// Eight bytes, no padding.
const VtEvent = extern struct {
    count: c_int,
    sigio: c_int,
};

/// `/dev/tty0` - the "current foreground VT" alias every VT-aware program
/// opens (fs/console.c registers tty0 for exactly that).
const console_node = "/dev/tty0";
/// Where the kernel publishes the active VT number (drivers/tty/vt.c
/// registers the `active` attribute on tty0).
const active_vt_sysfs = "/sys/class/tty/tty0/active";
/// How long to wait for a VT_ACK before giving up (ms). A real ack lands in
/// well under a millisecond; the timeout exists so a driver that never
/// answers cannot wedge start().
const vt_ack_timeout_ms: i32 = 1000;
/// How many vt_events one switch may consume before the ack is declared
/// lost. A switch produces VT_RELDISP then VT_ACK, and a second VT_ACK when
/// logind activates the session, so a handful is normal; the bound stops a
/// driver that streams events from spinning start().
const max_vt_events: usize = 8;

// ---------------------------------------------------------------------------
// Pure decision logic - no fds, no logind, unit-testable on any machine
// ---------------------------------------------------------------------------

/// The seat as logind describes it. Every string is owned by the Session
/// that read it and lives as long as that Session.
pub const Seat = struct {
    /// logind's seat name ("seat0"). Empty means there is no seat at all -
    /// the VM case, and the reason planAcquire claims nothing about logind.
    name: []const u8 = "",
    /// `Seat.CanTTY` (sd_seat_can_tty): the seat has virtual terminals, so
    /// there is a VT to switch to and a console to hand back.
    can_tty: bool = false,
    /// `Seat.CanGraphical` (sd_seat_can_graphical): the seat exists to show
    /// a graphical session. A compositor may not run on a seat without it.
    can_tty_and_graphical_known: bool = false,
    can_graphical: bool = false,
    /// `Seat.CanMultiSession` (sd_seat_can_multi_session; the sd-login(7)
    /// spelling `sd_login_can_multi_session` takes no seat and is
    /// deprecated). False means logind keeps exactly one session on the
    /// seat and taking its VT logs the incumbent out.
    can_multi_session: bool = false,
    /// Session logind reports as active on the seat (sd_seat_get_active).
    active_session: []const u8 = "",
    /// uid of that session's leader (sd_seat_get_active).
    active_uid: u32 = 0,
    /// The VT the console is showing right now, and the VT `restoreVt` puts
    /// it back on. ONE source for both halves of the VT decision: the live
    /// kernel answer from /sys/class/tty/tty0/active (drivers/tty/vt/vt.c
    /// registers the `active` attribute on tty0) first, logind's cached
    /// `Session.VTNumber` (sd_session_get_vt) when sysfs says nothing.
    /// 0 means "not known", and a switch must not be taken without one
    /// (planVtSwitch).
    active_vt: u16 = 0,
    /// True when `active_session` is this compositor's own session, i.e.
    /// nobody else is holding the console.
    active_is_us: bool = false,
    /// True when this process already has a logind session id of its own.
    have_session_id: bool = false,
};

/// Why planAcquire answered the way it did. Each names the logind fact it
/// follows, so the backend's log line is self-explaining.
pub const Reason = enum {
    /// No logind seat on this machine: the first opener of the card becomes
    /// DRM master (drm_ioctl.c drm_set_master: the first file to open the
    /// device is master by default) and there is no console session to take
    /// the card back. A perfectly good way to run.
    no_session_manager,
    /// The seat is graphics capable and either free, ours, or willing to
    /// host a second session. Carry on.
    seat_available,
    /// The seat cannot host a second session and a foreign one is active on
    /// it. Taking the VT would log the incumbent out from under its user, so
    /// the compositor refuses rather than surprise anybody.
    seat_occupied,
    /// `Seat.CanGraphical` is false: this seat is not for graphical
    /// sessions. A compositor must not modeset on it.
    seat_not_graphical,
    /// The seat is graphics capable but has no TTY, so there is no VT to
    /// activate. The session still exists and still owns the device.
    seat_has_no_tty,
};

/// What must happen, in order, before the compositor may modeset. This is
/// the whole session policy in one value; `Session.open` follows it.
pub const Plan = struct {
    /// Create a logind session, mark it ours (Type=wayland, TTY=ttyN), take
    /// the DRM device on it, and watch PrepareForSleep.
    open_session: bool = false,
    /// VT_ACTIVATE the target VT and wait for the DRM driver's VT_ACK
    /// before taking DRM master. False when there is no VT to switch to, and
    /// false when there is no VT to switch BACK from (planVtSwitch).
    switch_vt: bool = false,
    /// Do not touch the card: logind says this seat will not host us.
    /// Reported, not fatal to the process.
    blocked: bool = false,
    reason: Reason = .no_session_manager,
};

/// Decide what to acquire, from what the seat reports.
///
/// `have_logind` is false when no seat could be identified at all (no
/// session, no XDG_SEAT, no systemd running) - the VM. `our_vt` is the VT
/// this process was started on, 0 when it has no controlling terminal.
///
/// The check order is load-bearing: graphics before multi-session, because
/// logind reports CanMultiSession=false on a serial-console seat too and
/// "this seat has no VTs" is a much weaker objection than "this seat
/// refuses graphical sessions". libseat checks the same two flags in the
/// same order (libseat/logind.c session_logind_can_graphical,
/// session_logind_can_tty).
pub fn planAcquire(seat: Seat, have_logind: bool, our_vt: u16) Plan {
    if (!have_logind or seat.name.len == 0) {
        return .{ .reason = .no_session_manager };
    }
    if (!seat.can_graphical) {
        return .{ .blocked = true, .reason = .seat_not_graphical };
    }
    if (seat.active_session.len != 0 and !seat.active_is_us and !seat.can_multi_session) {
        return .{ .blocked = true, .reason = .seat_occupied };
    }
    return .{
        .open_session = true,
        .switch_vt = planVtSwitch(seat, our_vt, seat.active_vt),
        .reason = if (seat.can_tty) .seat_available else .seat_has_no_tty,
    };
}

/// What `Session.open` holds once it has read the seat and the caller's
/// options: the VT to take, the VT to hand the console back to, and the plan
/// that says whether to switch at all.
///
/// One value, not three separately assigned fields in `Session`, because all
/// three are decided from ONE read of the seat. `open` used to pass the
/// chosen VT to `planAcquire` and drop it on the floor: the plan knew a VT
/// the session did not, `target_vt` kept its default 0, and every VT step
/// below it - Session.TTY, switchVt, restoreVt, reacquire - was unreachable.
/// Deciding all three together is what makes that unrepresentable: there is
/// no way to build a `Plan` without handing over the VT it was made for, and
/// no way to hold a VT the `Plan` was not made for.
pub const Acquire = struct {
    /// The VT to hand the console to; 0 for none.
    target_vt: u16 = 0,
    /// The VT the console is on right now: the number `planVtSwitch`
    /// compared the target against, and the one `restoreVt` puts it back on.
    previous_vt: u16 = 0,
    plan: Plan = .{},
};

/// Decide the VT to hold and the plan that follows from it, from one read of
/// the seat and one look at the caller's options - everything `open` knows
/// before it touches the bus.
pub fn acquireFor(seat: Seat, opts: Options) Acquire {
    const target_vt = chooseTargetVt(opts);
    return .{
        .target_vt = target_vt,
        .previous_vt = seat.active_vt,
        .plan = planAcquire(seat, seat.name.len != 0, target_vt),
    };
}

/// Must the console be switched to `target`?
///
/// No when there is no target (0: no VT of our own, the VM case) and no
/// when the console is already showing it - re-activating the current VT
/// would only produce a redisplay storm.
pub fn needsVtSwitch(active: u16, target: u16) bool {
    return target != 0 and target != active;
}

/// Must the console be moved to `target`, from the seat's side?
///
/// Three gates, all of them necessary:
///
///   1. `Seat.CanTTY` (sd_seat_can_tty): without virtual terminals there is
///      no console to move.
///   2. A known VT to move it back to. This is the gate that a plain
///      "console is not already on our VT" test does not have, and it is the
///      one that keeps the user out of a locked machine: `restoreVt` gives up
///      when it does not know the VT it was on, so a switch taken with
///      `previous` == 0 parks the console on the compositor's VT with no
///      session on it, and every exit path leaves it there. Nothing has to
///      gain from that, so the console stays exactly where it is.
///   3. `needsVtSwitch(previous, target)`: no target, or already there.
///
/// `previous` is the same number `restoreVt` will act on, which is the
/// point - the switch and the restore must not read the VT from different
/// sources, or the one that decided to move the console cannot say where to
/// put it back.
pub fn planVtSwitch(seat: Seat, target: u16, previous: u16) bool {
    if (!seat.can_tty) return false;
    if (previous == 0) return false;
    return needsVtSwitch(previous, target);
}

/// Which VT switch is being done. There are exactly two call sites and they
/// differ in exactly one thing - whether the DRM fd may be read from - so
/// they are named rather than merged.
pub const SwitchMode = enum {
    /// The first takeover, from `Session.open`, before any commit.
    startup,
    /// Re-activation from `reacquire`, after the machine woke up: long
    /// after the first page flip was queued. Not spelled `resume`, which is
    /// a Zig keyword.
    wakeup,
};

/// Must a VT switch in `mode` wait for the driver's VT_ACK on the DRM fd?
///
/// Only the startup switch may. `waitVtAck` reads that fd RAW, and the DRM
/// core queues every event of an open card - page-flip completions and
/// `struct vt_event` alike - onto ONE queue per `drm_file` behind ONE read
/// offset (drm_fops.c drm_queue_event / drm_handle_event; the queue is
/// `struct drm_file_priv`'s `event_list`, drained by drm_read). Before the
/// first flip the VT event is the only thing the fd can produce, which is
/// the window libseat takes for the same reason (libseat session-vt.c
/// session_vt_wait_for_ack). After it, the same raw read either never
/// produces a VT event or stops between two records and leaves the backend's
/// own drmHandleEvent drain (drm.zig dispatch) mid-event.
///
/// So the resume switch does not wait. It does not have to: VT_ACTIVATE is
/// synchronous - the kernel has already moved the console when the ioctl
/// returns (drivers/tty/vt.c do_activate_vt) - and logind activates the
/// session that owns the VT from the kernel's own `SWITCH=1` uevent
/// (vt_switch -> kobject_uevent_env, consumed by src/login/logind-seat.c
/// seat_active_session_changed), which `switchVt` also asks for directly.
/// A switch nobody acked is cosmetic; a flip event eaten by the ack wait is
/// a stuck output.
pub fn waitsForVtAck(mode: SwitchMode) bool {
    return mode == .startup;
}

/// Where the compositor is in the suspend/resume handshake with logind.
///
/// logind emits PrepareForSleep(true) BEFORE the machine sleeps and
/// PrepareForSleep(false) AFTER it wakes (org.freedesktop.login1(5) Manager;
/// systemd drives the signal from the PrepareForSleep target). A
/// compositor that handled only the first would come back with no DRM
/// master and a dead event loop - which is what this state machine exists
/// to make impossible.
pub const Phase = enum {
    /// Before the session is up.
    startup,
    /// Live, session held.
    running,
    /// PrepareForSleep(true) seen, nothing released yet.
    suspending,
    /// Asleep: device released, master dropped.
    suspended,
    /// PrepareForSleep(false) seen, re-acquiring.
    resuming,
};

/// The device work one PrepareForSleep implies.
pub const SleepWork = struct {
    /// Hand the DRM device back to logind (Manager.ReleaseDevice) so the
    /// console session may take it while we sleep.
    release_device: bool = false,
    /// Drop DRM master (DRM_IOCTL_DROP_MASTER). Required on suspend even
    /// without logind: a card whose master is gone is handed to the next
    /// opener, and a suspend that lost the master comes back with the
    /// console sitting on top of our output.
    drop_master: bool = false,
    /// Take the device back, re-activate the VT and wait for its ack, then
    /// re-acquire DRM master and re-arm the flip pipeline.
    reacquire: bool = false,
};

/// One PrepareForSleep, resolved into a phase transition plus the work the
/// backend has to do for it.
pub const SleepPlan = struct {
    work: SleepWork = .{},
    next: Phase = .running,
};

/// Resolve one PrepareForSleep signal.
///
/// `from` is the phase before, `sleeping` the signal's boolean, and
/// `have_logind` whether a session - and therefore a device to release -
/// is held. Idempotent in both directions: a repeated signal does nothing,
/// which matters because a compositor that "handled" the suspend twice
/// would drop the master it had just re-taken.
pub fn planSleep(from: Phase, sleeping: bool, have_logind: bool) SleepPlan {
    if (sleeping) {
        return switch (from) {
            .startup, .running, .resuming => .{
                .work = .{ .release_device = have_logind, .drop_master = true },
                .next = .suspending,
            },
            // Already on the way down: logind repeats the signal when a
            // sleep is cancelled and re-attempted. The pending transition
            // is already the right one.
            .suspending, .suspended => .{ .next = .suspended },
        };
    }
    return switch (from) {
        // We were suspended, or mid-suspend: the machine is awake again.
        .suspending, .suspended => .{
            .work = .{ .reacquire = true },
            .next = .resuming,
        },
        // Waking without having slept: our own suspend was cancelled before
        // we acted. Nothing to undo.
        .startup, .running => .{ .next = .running },
        .resuming => .{ .work = .{ .reacquire = true }, .next = .resuming },
    };
}

/// Apply one PrepareForSleep, in the only order that works.
///
/// `phase` is the session's phase, BY POINTER, because where it sits in the
/// sequence is the whole contract:
///
///   1. `planSleep` resolves the signal against the phase it arrived in.
///   2. `session_work` runs this module's half.
///   3. `backend_work` runs the backend's half - while `phase` STILL holds
///      the pre-transition value. The backend resolves its half through
///      `planSleep(sleepPhase(), ...)` (drm.zig handlePrepareForSleep), so the
///      phase it reads must be the one this plan was made from, or it re-plans
///      a transition that has already happened: a suspend from `.running` was
///      re-read as `.suspending`, which `planSleep` answers with empty work, so
///      `DRM_IOCTL_DROP_MASTER` was never issued - and `is_master` stayed set,
///      which made the resume-side re-acquire a no-op too.
///   4. Only now does the phase advance, so a repeated signal re-plans from
///      the state the machine is really in and does no work twice.
///
/// Its own function because that order must be testable without a bus, an fd
/// or a card. `dispatch` drains the bus and calls this; nothing else.
fn applySleep(
    phase: *Phase,
    sleeping: bool,
    have_logind: bool,
    session_work: OnWork,
    backend_work: OnSleep,
    ctx: ?*anyopaque,
) void {
    const plan = planSleep(phase.*, sleeping, have_logind);
    session_work(ctx, plan.work);
    // `phase` is deliberately unmoved: see step 3 above.
    backend_work(ctx, sleeping);
    phase.* = plan.next;
}

/// This module's half of a transition: the device work the plan resolved,
/// with the same context the backend's half gets. Top-level rather than a
/// `Session` method because `applySleep` takes it as a plain function
/// pointer - Zig resolves a method only as a call, never as a value.
fn sessionWork(ctx: ?*anyopaque, work: SleepWork) void {
    const self: *Session = @ptrCast(@alignCast(ctx.?));
    if (work.release_device) {
        log_mod.info("drm: suspend: releasing the DRM device to logind", self.io, self.log_cfg, "drm", .{});
        self.releaseDevice();
    }
    if (work.reacquire) {
        log_mod.info("drm: resume: re-taking the DRM device and VT", self.io, self.log_cfg, "drm", .{});
        self.reacquire();
    }
}

/// Decode a kernel `tty_nr` (field 7 of /proc/self/stat) into a VT number,
/// or null when it is not a VT.
///
/// The kernel encodes the device as MAJOR(dev) << 8 | MINOR(dev) with the
/// high minor bits folded up (include/linux/fs.h new_encode_dev:
/// `(major << 8) | (minor & 0xff) | ((minor & ~0xff) << 12)`; fs/proc/
/// array.c prints `new_encode_dev(tty_devnum(tty))`). A VT has major 4
/// (TTY_MAJOR), so a pty (136-143), /dev/null (1:3) or "no tty" (0) is not
/// a VT we could activate.
pub fn vtFromTtyNr(tty_nr: u64) ?u16 {
    const minor_bits = (tty_nr & 0xff) | ((tty_nr >> 12) & 0xfff00);
    const major = (tty_nr >> 8) & 0xfff;
    if (major != 4) return null;
    // VTs are numbered from 1; 0 is not a real VT, and the kernel caps the
    // count at 64 (drivers/tty/vt.c MAX_VT 63).
    if (minor_bits == 0 or minor_bits > 63) return null;
    return @intCast(minor_bits);
}

/// Parse the contents of /sys/class/tty/tty0/active into a VT number, or
/// null when that is not something usable.
///
/// The file holds a DEVICE NAME, not a bare number: `show_tty_active`
/// (drivers/tty/vt/vt.c) is `sprintf(buf, "tty%d\n", fg_console + 1)`, so a
/// machine whose console is on VT 2 has the five bytes "tty2\n" in it and
/// has had since the attribute was added. A parser that accepts digits only
/// therefore rejects every value the kernel actually writes, `readActiveVt`
/// answers null on every machine, and `previous_vt` falls back to logind's
/// `Session.VTNumber` - which speaks only for the seat's ACTIVE session. On
/// a seat with no session that is 0, and planVtSwitch then refuses the
/// switch for want of somewhere to put the console back.
///
/// Both spellings are accepted here, so the file's own format and a plain
/// number both work; `targetVtFromEnv` shares this parser for WAYLAND_VT,
/// which wlroots reads with strtoul (backend/session/direct.c
/// getenv("WAYLAND_VT")) and therefore expects bare digits. Everything else
/// - a PTY name, a serial console, "n/a", a number past the kernel's MAX_VT
/// - is refused rather than guessed at: a console moved to a VT nobody
/// asked for is a machine the user cannot log into.
pub fn parseActiveVt(text: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const digits = if (std.mem.startsWith(u8, trimmed, "tty"))
        trimmed["tty".len..]
    else
        trimmed;
    if (digits.len == 0 or digits.len > 2) return null;
    const n = std.fmt.parseUnsigned(u16, digits, 10) catch return null;
    if (n == 0 or n > 63) return null;
    return n;
}

/// The VT to hand the console to, in decreasing priority:
///
///  1. `WAYLAND_VT` - the operator's explicit choice, the same variable
///     wlroots' direct session backend reads (backend/session/direct.c
///     getenv("WAYLAND_VT")).
///  2. The VT of this process's controlling terminal. A compositor started
///     from a login shell owns that VT: it is the one whose console text
///     nobody is reading, which is exactly the one to take over.
///  3. 0 - take over nothing. This is what the VM gets, and it is correct
///     there: there is no console to steal.
pub fn targetVtFromEnv(env_vt: ?[*:0]const u8, tty_nr: ?u64) u16 {
    if (env_vt) |raw| {
        if (parseActiveVt(std.mem.span(raw))) |vt| return vt;
    }
    if (tty_nr) |nr| {
        if (vtFromTtyNr(nr)) |vt| return vt;
    }
    return 0;
}

/// The VT to ask for: the caller's explicit choice, else WAYLAND_VT, else
/// the VT of this process's controlling terminal, else none.
///
/// `opts` is the whole policy, so this is a plain function rather than a
/// `Session` method: the number it returns must be decidable before a
/// Session exists, and it is the one number `acquireFor` makes every other
/// decision from.
pub fn chooseTargetVt(opts: Options) u16 {
    if (opts.target_vt != 0) return opts.target_vt;
    if (!opts.derive_vt) return 0;
    return targetVtFromEnv(std.c.getenv("WAYLAND_VT"), processTtyNr());
}

// ---------------------------------------------------------------------------
// libsystemd, bound at runtime
// ---------------------------------------------------------------------------

/// Opaque sd-bus types: sd-bus.h declares sd_bus, sd_bus_message and
/// sd_bus_slot incomplete and never exposes their layout.
const Bus = opaque {};
const BusMessage = opaque {};
const BusSlot = opaque {};

/// `sd_bus_error` (sd-bus-protocol.h):
///     typedef struct sd_bus_error {
///             const char *name;
///             const char *message;
///             int _need_free;
///     } sd_bus_error;
/// Passed to every call that can fail, so the D-Bus error name and message
/// can be logged instead of a bare errno: "Seat already active" and
/// "Interactive authentication required" are the two answers that tell the
/// operator what to do.
const BusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    _need_free: c_int = 0,
};

/// `sd_bus_message_handler_t` (sd-bus-protocol.h):
///     typedef int (*sd_bus_message_handler_t)(sd_bus_message *m,
///                                            void *userdata,
///                                            sd_bus_error *reterr_error);
const MessageHandler = *const fn (*BusMessage, ?*anyopaque, ?*BusError) callconv(.c) c_int;

/// `sd_bus_call_method` (sd-bus.h), variadic in its argument types.
const CallMethod = *const fn (bus: *Bus, destination: ?[*:0]const u8, path: ?[*:0]const u8, interface: ?[*:0]const u8, member: ?[*:0]const u8, reterr_error: ?*BusError, ret_reply: *?*BusMessage, types: ?[*:0]const u8, ...) callconv(.c) c_int;

/// Every libsystemd entry point this module calls, with the exact Zig
/// signature of its C prototype (sd-bus.h and sd-login.h, systemd 261).
///
/// Two argument orders differ from systemd < 250 and are transcribed as the
/// installed headers have them: `sd_bus_call` is
/// `(bus, m, usec, reterr_error, ret_reply)` and `sd_bus_process` is
/// `(bus, ret_processed)`. Transcribing the header rather than remembering
/// an older release is deliberate - a swapped pair of pointers is a silent
/// memory bug, not a link error.
const Systemd = struct {
    /// Owns the dlopen handle; must outlive every call made through the
    /// pointers below, so it is released last in `Session.release`.
    lib: std.DynLib,

    // --- sd-bus.h -------------------------------------------------------
    open_system: *const fn (*?*Bus) callconv(.c) c_int,
    flush_close_unref: *const fn (*Bus) callconv(.c) c_int,
    get_fd: *const fn (*Bus) callconv(.c) c_int,
    get_events: *const fn (*Bus) callconv(.c) c_int,
    get_timeout: *const fn (*Bus, *u64) callconv(.c) c_int,
    process: *const fn (*Bus, *?*BusMessage) callconv(.c) c_int,
    add_match: *const fn (*Bus, *?*BusSlot, ?[*:0]const u8, MessageHandler, ?*anyopaque) callconv(.c) c_int,
    call_method: CallMethod,
    message_read: *const fn (*BusMessage, [*:0]const u8, ...) callconv(.c) c_int,
    message_unref: *const fn (*BusMessage) callconv(.c) ?*BusMessage,
    error_free: *const fn (*BusError) callconv(.c) void,

    // --- sd-login.h, the file-based half (reads /run/systemd) ------------
    pid_get_session: *const fn (std.os.linux.pid_t, *?[*:0]u8) callconv(.c) c_int,
    session_get_seat: *const fn ([*:0]const u8, *?[*:0]u8) callconv(.c) c_int,
    session_get_vt: *const fn ([*:0]const u8, *c_uint) callconv(.c) c_int,
    seat_get_active: *const fn ([*:0]const u8, *?[*:0]u8, *u32) callconv(.c) c_int,
    seat_can_tty: *const fn ([*:0]const u8) callconv(.c) c_int,
    seat_can_graphical: *const fn ([*:0]const u8) callconv(.c) c_int,
    seat_can_multi_session: *const fn ([*:0]const u8) callconv(.c) c_int,

    /// Bind libsystemd. All or nothing: a partial binding would turn a
    /// missing feature into a jump through null at the worst possible
    /// moment, so one absent symbol fails the whole open.
    fn open(io: *std.Io, log_cfg: *const log_mod.Config) error{SystemdUnavailable}!Systemd {
        var lib = openSystemdLib(io, log_cfg) orelse {
            log_mod.info(
                "drm: libsystemd not available; DRM runs without a logind session",
                io,
                log_cfg,
                "drm",
                .{},
            );
            return error.SystemdUnavailable;
        };
        errdefer lib.close();
        // SAFETY: `lib` is a live handle from std.DynLib.open; lookup
        // returns null only for a symbol the loaded object does not define,
        // which is the only failure handled here.
        const self: Systemd = .{
            .lib = lib,
            .open_system = lib.lookup(*const fn (*?*Bus) callconv(.c) c_int, "sd_bus_open_system") orelse return missing(io, log_cfg, "sd_bus_open_system"),
            .flush_close_unref = lib.lookup(*const fn (*Bus) callconv(.c) c_int, "sd_bus_flush_close_unref") orelse return missing(io, log_cfg, "sd_bus_flush_close_unref"),
            .get_fd = lib.lookup(*const fn (*Bus) callconv(.c) c_int, "sd_bus_get_fd") orelse return missing(io, log_cfg, "sd_bus_get_fd"),
            .get_events = lib.lookup(*const fn (*Bus) callconv(.c) c_int, "sd_bus_get_events") orelse return missing(io, log_cfg, "sd_bus_get_events"),
            .get_timeout = lib.lookup(*const fn (*Bus, *u64) callconv(.c) c_int, "sd_bus_get_timeout") orelse return missing(io, log_cfg, "sd_bus_get_timeout"),
            .process = lib.lookup(*const fn (*Bus, *?*BusMessage) callconv(.c) c_int, "sd_bus_process") orelse return missing(io, log_cfg, "sd_bus_process"),
            .add_match = lib.lookup(*const fn (*Bus, *?*BusSlot, ?[*:0]const u8, MessageHandler, ?*anyopaque) callconv(.c) c_int, "sd_bus_add_match") orelse return missing(io, log_cfg, "sd_bus_add_match"),
            .call_method = lib.lookup(CallMethod, "sd_bus_call_method") orelse return missing(io, log_cfg, "sd_bus_call_method"),
            .message_read = lib.lookup(*const fn (*BusMessage, [*:0]const u8, ...) callconv(.c) c_int, "sd_bus_message_read") orelse return missing(io, log_cfg, "sd_bus_message_read"),
            .message_unref = lib.lookup(*const fn (*BusMessage) callconv(.c) ?*BusMessage, "sd_bus_message_unref") orelse return missing(io, log_cfg, "sd_bus_message_unref"),
            .error_free = lib.lookup(*const fn (*BusError) callconv(.c) void, "sd_bus_error_free") orelse return missing(io, log_cfg, "sd_bus_error_free"),
            .pid_get_session = lib.lookup(*const fn (std.os.linux.pid_t, *?[*:0]u8) callconv(.c) c_int, "sd_pid_get_session") orelse return missing(io, log_cfg, "sd_pid_get_session"),
            .session_get_seat = lib.lookup(*const fn ([*:0]const u8, *?[*:0]u8) callconv(.c) c_int, "sd_session_get_seat") orelse return missing(io, log_cfg, "sd_session_get_seat"),
            .session_get_vt = lib.lookup(*const fn ([*:0]const u8, *c_uint) callconv(.c) c_int, "sd_session_get_vt") orelse return missing(io, log_cfg, "sd_session_get_vt"),
            .seat_get_active = lib.lookup(*const fn ([*:0]const u8, *?[*:0]u8, *u32) callconv(.c) c_int, "sd_seat_get_active") orelse return missing(io, log_cfg, "sd_seat_get_active"),
            .seat_can_tty = lib.lookup(*const fn ([*:0]const u8) callconv(.c) c_int, "sd_seat_can_tty") orelse return missing(io, log_cfg, "sd_seat_can_tty"),
            .seat_can_graphical = lib.lookup(*const fn ([*:0]const u8) callconv(.c) c_int, "sd_seat_can_graphical") orelse return missing(io, log_cfg, "sd_seat_can_graphical"),
            .seat_can_multi_session = lib.lookup(*const fn ([*:0]const u8) callconv(.c) c_int, "sd_seat_can_multi_session") orelse return missing(io, log_cfg, "sd_seat_can_multi_session"),
        };
        log_mod.info("drm: libsystemd bound; logind session management available", io, log_cfg, "drm", .{});
        return self;
    }

    /// Release the dlopen handle. Only legal once no Bus, BusMessage or
    /// BusSlot obtained through this binding is still alive.
    fn close(self: *Systemd) void {
        self.lib.close();
    }

    fn missing(io: *std.Io, log_cfg: *const log_mod.Config, name: []const u8) error{SystemdUnavailable} {
        log_mod.warn(
            "drm: libsystemd lacks {s}; DRM runs without a logind session",
            io,
            log_cfg,
            "drm",
            .{name},
        );
        return error.SystemdUnavailable;
    }
};

/// The sonames dlopen accepts, in order: the SONAME first (the spelling a
/// runtime loader is guaranteed to resolve), the linker name second.
const systemd_sonames = [_][:0]const u8{ "libsystemd.so.0", "libsystemd.so" };

fn openSystemdLib(io: *std.Io, log_cfg: *const log_mod.Config) ?std.DynLib {
    for (systemd_sonames) |soname| {
        if (std.DynLib.open(soname)) |lib| {
            log_mod.debug("drm: dlopened {s}", io, log_cfg, "drm", .{soname});
            return lib;
        } else |_| {}
    }
    // Not on the loader's search path. Every systemd build that ships both
    // libraries ships them from one output directory, and libudev is already
    // mapped here (the compositor links it for libinput), so the sibling
    // path works where the bare soname does not - which is the Nix case,
    // where the /nix/store lib dirs only reach the loader through paths
    // something else already pulled in.
    var buf: [16 * 1024]u8 = undefined;
    const sibling = siblingSystemdPath(&buf) orelse return null;
    return std.DynLib.open(sibling) catch null;
}

/// "<directory of the mapped libudev.so>/libsystemd.so.0", found by reading
/// /proc/self/maps. Null when libudev is not mapped, or when the match sits
/// on a map line with no path (impossible for a shared object).
fn siblingSystemdPath(buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        "/proc/self/maps",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    ) catch return null;
    defer _ = std.os.linux.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.posix.read(fd, buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    const maps = buf[0..len];
    const hit = std.mem.indexOf(u8, maps, "libudev.so") orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, maps[0..hit], '\n')) |i| i + 1 else 0;
    const slash = std.mem.lastIndexOfScalar(u8, maps[line_start..hit], '/') orelse return null;
    // bufPrint writes strictly behind the bytes it reads (output starts at
    // line_start, the directory it copies starts at line_start + slash), so
    // formatting in place cannot clobber its own source.
    return std.fmt.bufPrint(buf[line_start..], "{s}/libsystemd.so.0", .{
        maps[line_start .. line_start + slash],
    }) catch null;
}

// ---------------------------------------------------------------------------
// The logind session
// ---------------------------------------------------------------------------

/// org.freedesktop.login1(5): the bus name, object path and interfaces the
/// Manager methods and the Session properties are reached through.
const login1_name: [:0]const u8 = "org.freedesktop.login1";
const login1_path: [:0]const u8 = "/org/freedesktop/login1";
const login1_manager: [:0]const u8 = "org.freedesktop.login1.Manager";
const login1_session: [:0]const u8 = "org.freedesktop.login1.Session";
const dbus_properties: [:0]const u8 = "org.freedesktop.DBus.Properties";

/// Match rule for PrepareForSleep (org.freedesktop.login1(5) Manager:
/// "emitted with a boolean argument when the system is about to go to sleep,
/// or has finished waking up"). sender/interface/member are pinned so that
/// no other service on the bus can drive the compositor's suspend path.
const prepare_for_sleep_match: [:0]const u8 = "type='signal',sender='org.freedesktop.login1'," ++
    "interface='org.freedesktop.login1.Manager',member='PrepareForSleep'";

/// The session type a compositor declares (org.freedesktop.login1(5)
/// Session.Type: "one of tty, x11, wayland, mir, web"). `wayland` is what
/// makes logind treat us as a graphical session for shutdown and reboot
/// purposes.
const session_type_wayland: [:0]const u8 = "wayland";

/// Called from `Session.dispatch` when logind announces a sleep: the
/// backend's half of the handshake (drop DRM master going down, re-acquire
/// it and re-arm the flip pipeline coming up).
pub const OnSleep = *const fn (ctx: ?*anyopaque, sleeping: bool) void;

/// This module's own half of a transition - `sessionWork` - in the shape
/// `OnSleep` has, so `applySleep` can hand one context to both halves.
const OnWork = *const fn (ctx: ?*anyopaque, work: SleepWork) void;

/// What the backend hands to `Session.open`.
pub const Options = struct {
    /// DRM primary minor of the card being modeset ("cardN" -> N). Passed to
    /// Manager.TakeDevice/ReleaseDevice so logind knows which device this
    /// session holds, and keeps the console's session off it.
    drm_minor: u32 = 0,
    /// The DRM fd. A VT switch is acknowledged by a `struct vt_event`
    /// carrying VT_ACK on this fd, because the DRM core registers a console
    /// notifier for every open card (drm_fops.c drm_handle_vt_event).
    /// -1 with `target_vt` == 0 is the normal VM case.
    vt_ack_fd: std.posix.fd_t = -1,
    /// VT to hand the console to. 0 means "decide": WAYLAND_VT, else the VT
    /// of this process's controlling terminal, else no switch at all.
    target_vt: u16 = 0,
    /// Decide the VT when `target_vt` is 0. False for a caller with no
    /// business moving a console.
    derive_vt: bool = true,
    /// Not optional: the suspend handshake is not something a backend may
    /// leave unhandled, so there is no default no-op to forget to fill in.
    on_sleep: OnSleep,
    /// Passed back to `on_sleep` untouched.
    ctx: ?*anyopaque = null,
};

/// A logind session that owns a seat and, when logind allows it, the DRM
/// device on it.
///
/// Lifecycle: `open` -> poll/dispatch -> `close`. `close` is the only way
/// out, and it is the one that puts the console back on the VT it was on.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log_mod.Config,
    /// Owns the dlopen handle; released LAST in `release`, after every
    /// sd_bus call made through it.
    sysd: Systemd,
    /// The system bus, or null when it was lost (a broken connection is
    /// dropped rather than polled forever).
    conn: ?*Bus = null,
    on_sleep: OnSleep,
    ctx: ?*anyopaque = null,

    /// The seat as logind describes it. `seat.name` empty means no seat.
    seat: Seat = .{},
    /// What planAcquire decided; kept for logs and for the VT step.
    plan: Plan = .{},
    phase: Phase = .startup,

    /// DRM primary minor we took the device for.
    drm_minor: u32 = 0,
    device_taken: bool = false,

    /// The VT we asked for (0 for none), and the VT the console was on when
    /// the session opened - the one `restoreVt` puts it back on, read from
    /// the same place `planVtSwitch` read it.
    target_vt: u16 = 0,
    previous_vt: u16 = 0,
    /// /dev/tty0 for VT_ACTIVATE. Holds at most one descriptor for the life
    /// of the session, whoever asks.
    console: Console = .{},
    /// The DRM fd a VT_ACK arrives on; -1 disables the ack wait.
    ack_fd: std.posix.fd_t = -1,

    /// Every heap string this session owns, in allocation order. Each is
    /// `[:0]const u8` because every one of them is handed to libsystemd or
    /// D-Bus as a C string, and each holds `len + 1` bytes (the NUL
    /// `dupeZ` added) - which is exactly what `release` hands back.
    /// One list rather than five fields: teardown cannot forget one.
    owned: std.ArrayListUnmanaged([:0]const u8) = .empty,
    /// The session id logind gave us, "" until CreateSession answers.
    /// Borrowed from `owned`.
    own_session_id: [:0]const u8 = "",
    /// Our session's object path, where Type and TTY are set. Borrowed.
    own_session_path: [:0]const u8 = "",
    /// The TTY we claimed on the session. Borrowed; "" when we claimed none.
    own_tty: [:0]const u8 = "",

    /// The slot from sd_bus_add_match. Kept so the slot outlives the call;
    /// the bus owns it and frees it with the connection.
    sleep_slot: ?*BusSlot = null,
    /// Set by the D-Bus signal handler, consumed by `dispatch`.
    pending_sleep: ?bool = null,
    /// Set once `release` ran, so a second call cannot double-close the
    /// dlopen handle.
    closed: bool = false,

    /// The fd the compositor must poll for PrepareForSleep, or -1.
    pub fn pollFd(self: *Session) std.posix.fd_t {
        const bus = self.conn orelse return -1;
        return self.sysd.get_fd(bus);
    }

    /// The poll mask for `pollFd` (sd_bus_get_events): POLLIN when the
    /// connection has work queued, POLLOUT when it must flush a write.
    pub fn pollEvents(self: *Session) i16 {
        const bus = self.conn orelse return 0;
        return @intCast(self.sysd.get_events(bus));
    }

    /// The connection's next timeout in usec relative to CLOCK_MONOTONIC
    /// (sd_bus_get_timeout), or null with no bus or no deadline. The
    /// server's loop uses it as its own wakeup time.
    pub fn pollTimeoutUs(self: *Session) ?u64 {
        const bus = self.conn orelse return null;
        var usec: u64 = 0;
        if (self.sysd.get_timeout(bus, &usec) < 0) return null;
        return usec;
    }

    /// Drain the bus and run one suspend/resume step if logind asked for
    /// one. Non-fatal: a bus error drops the connection and logs, so the
    /// server stops polling it instead of spinning.
    pub fn dispatch(self: *Session) void {
        const bus = self.conn orelse return;
        // Initialized, so sd_bus_process has somewhere valid to write even
        // though we never read the result.
        var processed: ?*BusMessage = null;
        if (self.sysd.process(bus, &processed) < 0) {
            log_mod.err(
                "drm: sd_bus_process failed; logind session events are lost",
                self.io,
                self.log_cfg,
                "drm",
                .{},
            );
            self.dropBus();
            return;
        }
        const sleeping = self.pending_sleep orelse return;
        self.pending_sleep = null;
        applySleep(&self.phase, sleeping, self.plan.open_session, sessionWork, self.on_sleep, self.ctx);
    }

    /// Mark this session idle (or not) in logind's accounting
    /// (Manager.SetIdleHint). A compositor is idle whenever it is not
    /// driving an animation, and logind uses the hint to decide whether a
    /// session may be locked.
    pub fn setIdleHint(self: *Session, idle: bool) void {
        const bus = self.conn orelse return;
        var err: BusError = .{};
        var reply: ?*BusMessage = null;
        const hint: c_int = if (idle) 1 else 0;
        const rc = self.sysd.call_method(
            bus,
            login1_name,
            login1_path,
            login1_manager,
            "SetIdleHint",
            &err,
            &reply,
            "bs",
            hint,
            self.own_session_id.ptr,
        );
        defer self.freeReply(reply);
        if (rc < 0) self.logDbus("SetIdleHint", &err);
    }

    /// The phase of the suspend handshake, for logs and tests.
    pub fn sleepPhase(self: *const Session) Phase {
        return self.phase;
    }

    /// True when the DRM device is currently held from logind.
    pub fn holdsDevice(self: *const Session) bool {
        return self.device_taken;
    }

    /// The session id logind gave us, "" when there is none.
    pub fn sessionId(self: *const Session) []const u8 {
        return self.own_session_id;
    }

    /// Put the console back on the VT it was on when the session opened.
    ///
    /// Called from `close`, and safe to call twice. Best-effort by design:
    /// a console left on the wrong VT locks the user out of their machine,
    /// so a failure is logged as an error - but it is never allowed to stop
    /// the rest of the teardown (device release, session termination, bus
    /// close), which would leave the seat worse off than before.
    pub fn restoreVt(self: *Session) void {
        defer self.console.close();
        if (self.console.fd < 0) return;
        if (self.previous_vt == 0) return;
        if (self.target_vt == 0 or self.target_vt == self.previous_vt) return;
        activateVt(self, self.previous_vt) catch {
            log_mod.err(
                "drm: could not put the console back on tty{d}; switch to it by hand",
                self.io,
                self.log_cfg,
                "drm",
                .{self.previous_vt},
            );
            return;
        };
        log_mod.info(
            "drm: console restored to tty{d}",
            self.io,
            self.log_cfg,
            "drm",
            .{self.previous_vt},
        );
    }

    /// Release everything and free the struct. Idempotent.
    pub fn close(self: *Session) void {
        self.release();
        self.allocator.destroy(self);
    }

    /// Give the device back, put the console back, end the session, drop
    /// the bus, free the strings, release libsystemd - in that order.
    ///
    /// The order IS the contract: the console is restored BEFORE the
    /// session ends, so there is no window in which a VT is held by a
    /// session that no longer exists. Null-safe and idempotent.
    fn release(self: *Session) void {
        if (self.closed) return;
        self.closed = true;
        if (self.conn != null) {
            self.releaseDevice();
            self.restoreVt();
            self.terminateSession();
            self.dropBus();
        } else {
            // Even a lost bus must not cost the user their console.
            self.restoreVt();
        }
        for (self.owned.items) |s| self.allocator.free(s[0 .. s.len + 1]);
        self.owned.deinit(self.allocator);
        self.own_session_id = "";
        self.own_session_path = "";
        self.own_tty = "";
        self.sysd.close();
    }

    /// Establish the session against logind over its own D-Bus API.
    ///
    /// Non-fatal everywhere: `SystemdUnavailable` (no libsystemd or no
    /// seat), `SeatUnavailable` (logind says this seat will not host us),
    /// `BusUnavailable` (no system bus) and `LogindRejected` (a method was
    /// refused) all leave the process free to run on the card with no
    /// session - which is what the VM does today.
    pub fn open(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log_mod.Config,
        opts: Options,
    ) Error!*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .sysd = try Systemd.open(io, log_cfg),
            .on_sleep = opts.on_sleep,
            .ctx = opts.ctx,
            .drm_minor = opts.drm_minor,
            .ack_fd = opts.vt_ack_fd,
        };
        // One teardown for every failure below; it runs before
        // allocator.destroy because errdefers unwind in reverse.
        errdefer self.release();

        self.seat = try self.readSeat();
        // The VT to take, the VT the console is on now, and the plan that
        // follows: decided together, from one read of the seat, and stored
        // together. Handing planAcquire a chosen VT without keeping it left
        // target_vt at 0 for the life of the session, and everything below
        // that reads it - Session.TTY, switchVt, restoreVt, reacquire - was
        // dead code behind a field that read as load-bearing.
        const acq = acquireFor(self.seat, opts);
        self.target_vt = acq.target_vt;
        self.previous_vt = acq.previous_vt;
        self.plan = acq.plan;
        if (self.plan.blocked) {
            log_mod.warn(
                "drm: seat {s} will not host a compositor ({s}); running without a session",
                io,
                log_cfg,
                "drm",
                .{ self.seat.name, @tagName(self.plan.reason) },
            );
            return error.SeatUnavailable;
        }
        if (!self.plan.open_session) {
            log_mod.info(
                "drm: no logind seat; the first card opener is DRM master and no VT is switched",
                io,
                log_cfg,
                "drm",
                .{},
            );
            return error.SystemdUnavailable;
        }

        try self.openBus();
        try self.createSession();
        // TTY before the VT switch: logind decides which session owns a VT
        // from Session.TTY (org.freedesktop.login1(5) Session.TTY), and the
        // VT is only ours to take once our session claims it. Without this
        // the VT switch would hand the VT to whatever getty owns it.
        if (self.target_vt != 0) {
            // "ttyN" is the name logind's Session.TTY expects
            // (org.freedesktop.login1(5) Session.TTY: "the TTY of the
            // session, like tty2"); the kernel's VT devices are named
            // "tty%d" (drivers/tty/vt.c), and a VT is at most 2 digits.
            var buf: [8]u8 = undefined;
            const tty = std.fmt.bufPrintZ(&buf, "tty{d}", .{self.target_vt}) catch unreachable;
            self.own_tty = try self.own(tty);
            try self.setProperty("TTY", self.own_tty);
        }
        try self.setProperty("Type", session_type_wayland);
        self.setIdleHint(true);
        try self.watchPrepareForSleep();
        self.takeDevice();
        openConsole(self);

        // Only now is it safe to move the console: the session owns the VT,
        // logind knows about it, and any failure leaves the console exactly
        // where it was (restoreVt runs from the errdefer).
        //
        // The VT to move it BACK to came from the same read as the plan's,
        // so the switch and the restore cannot disagree about where the
        // console was left.
        // A switch the seat wanted and the restore target forbids: neither
        // logind nor sysfs ever named a VT, so there is none to put the
        // console back on. restoreVt gives up on previous_vt == 0, so moving
        // it now would park the console on the compositor's VT with no
        // session on it and leave it there on every exit path - which is
        // what "locked out of my machine" looks like. Worth a line: the
        // operator asked for a VT and is not getting one.
        const wanted_switch = self.seat.can_tty and needsVtSwitch(self.previous_vt, self.target_vt);
        if (wanted_switch and !self.plan.switch_vt) {
            log_mod.warn(
                "drm: no VT to put the console back on; leaving it where it is rather than taking tty{d}",
                io,
                log_cfg,
                "drm",
                .{self.target_vt},
            );
        }
        if (self.plan.switch_vt) {
            self.switchVt(.startup) catch |err| {
                log_mod.warn(
                    "drm: VT switch to tty{d} failed ({s}); continuing on the current VT",
                    io,
                    log_cfg,
                    "drm",
                    .{ self.target_vt, @errorName(err) },
                );
            };
        }
        self.phase = .running;
        log_mod.info(
            "drm: logind session {s} on {s} (vt={d}, device={s})",
            io,
            log_cfg,
            "drm",
            .{
                self.own_session_id,
                self.seat.name,
                self.target_vt,
                if (self.device_taken) "taken" else "not taken",
            },
        );
        return self;
    }

    /// Read the seat logind knows about, through libsystemd's file-based
    /// API (sd-login(7): these read /run/systemd/sessions and
    /// /run/systemd/seats, no bus involved).
    fn readSeat(self: *Session) Error!Seat {
        // malloc'd by libsystemd; freed on every exit path.
        var session_raw: ?[*:0]u8 = null;
        defer if (session_raw) |p| {
            std.c.free(p);
        };
        const have_session = self.sysd.pid_get_session(0, &session_raw) >= 0 and session_raw != null;

        var seat_raw: ?[*:0]u8 = null;
        defer if (seat_raw) |p| {
            std.c.free(p);
        };
        if (have_session) {
            if (self.sysd.session_get_seat(session_raw.?, &seat_raw) < 0) seat_raw = null;
        }
        // No logind session for this process (a bare shell, or a VM with no
        // systemd): XDG_SEAT is the documented fallback, the variable
        // logind's own PAM stack exports into every session it starts
        // (pam_systemd(8)).
        const name: ?[:0]const u8 = if (seat_raw) |p| std.mem.span(p) else envSeat();
        const seat_z = name orelse return .{};
        if (seat_z.len == 0) return .{};

        var active_raw: ?[*:0]u8 = null;
        defer if (active_raw) |p| {
            std.c.free(p);
        };
        var active_uid: u32 = 0;
        const have_active = self.sysd.seat_get_active(seat_z, &active_raw, &active_uid) >= 0 and active_raw != null;

        // The VT the console is on, from ONE source for the whole module:
        // sysfs first, because it is the kernel's live answer and the thing
        // `restoreVt` must put back; logind's cached Session.VTNumber only
        // when sysfs says nothing (a container, an unreadable
        // /sys/class/tty/tty0/active). `session_get_vt` answers for the
        // ACTIVE SESSION, so on a seat with no session it says nothing at
        // all - and a console moved on that answer has nowhere to go back
        // to.
        var active_vt: u16 = 0;
        if (have_active) {
            var vt: c_uint = 0;
            if (self.sysd.session_get_vt(active_raw.?, &vt) >= 0 and vt <= 63) active_vt = @intCast(vt);
        }
        active_vt = readActiveVt() orelse active_vt;

        const active_session = try self.own(if (have_active) std.mem.span(active_raw.?) else "");
        const seat_name = try self.own(seat_z);

        return .{
            .name = seat_name,
            .can_tty = self.sysd.seat_can_tty(seat_z) > 0,
            .can_graphical = self.sysd.seat_can_graphical(seat_z) > 0,
            .can_multi_session = self.sysd.seat_can_multi_session(seat_z) > 0,
            .active_session = active_session,
            .active_uid = active_uid,
            .active_vt = active_vt,
            .active_is_us = have_session and have_active and
                std.mem.eql(u8, std.mem.span(session_raw.?), std.mem.span(active_raw.?)),
            .have_session_id = have_session,
        };
    }

    /// Copy `text` into a NUL-terminated allocation this session owns, so
    /// a libsystemd string can outlive the call that produced it.
    fn own(self: *Session, text: []const u8) Error![:0]const u8 {
        const copy = try self.allocator.dupeZ(u8, text);
        errdefer self.allocator.free(copy[0 .. copy.len + 1]);
        try self.owned.append(self.allocator, copy);
        return copy;
    }

    fn openBus(self: *Session) Error!void {
        var bus: ?*Bus = null;
        if (self.sysd.open_system(&bus) < 0 or bus == null) {
            log_mod.warn("drm: no system bus; running without a logind session", self.io, self.log_cfg, "drm", .{});
            return error.BusUnavailable;
        }
        self.conn = bus;
    }

    /// Manager.CreateSession() -> (o path, s id). The object path is where
    /// the session's properties (Type, TTY) live; the id is what
    /// TakeDevice and ActivateSession take.
    fn createSession(self: *Session) Error!void {
        const bus = self.conn.?;
        var err: BusError = .{};
        var reply: ?*BusMessage = null;
        const rc = self.sysd.call_method(
            bus,
            login1_name,
            login1_path,
            login1_manager,
            "CreateSession",
            &err,
            &reply,
            "",
        );
        if (rc < 0) {
            self.logDbus("CreateSession", &err);
            return error.LogindRejected;
        }
        defer self.freeReply(reply);
        // "(os)": the session object path and the session id.
        var path: ?[*:0]u8 = null;
        var id: ?[*:0]u8 = null;
        if (self.sysd.message_read(reply.?, "(os)", &path, &id) < 0 or path == null or id == null) {
            log_mod.warn(
                "drm: logind CreateSession returned an unreadable reply",
                self.io,
                self.log_cfg,
                "drm",
                .{},
            );
            return error.LogindRejected;
        }
        self.own_session_path = try self.own(std.mem.span(path.?));
        self.own_session_id = try self.own(std.mem.span(id.?));
    }

    /// org.freedesktop.DBus.Properties.Set on our own session object. Only
    /// the session's leader may set these, and CreateSession recorded our
    /// pid as the leader.
    fn setProperty(self: *Session, name: [:0]const u8, value: [:0]const u8) Error!void {
        const bus = self.conn.?;
        var err: BusError = .{};
        var reply: ?*BusMessage = null;
        // "sss" is Set(s interface, s property, v value) with a string
        // inside the variant.
        const rc = self.sysd.call_method(
            bus,
            login1_name,
            self.own_session_path,
            dbus_properties,
            "Set",
            &err,
            &reply,
            "sss",
            login1_session.ptr,
            name.ptr,
            value.ptr,
        );
        defer self.freeReply(reply);
        if (rc < 0) {
            log_mod.warn(
                "drm: logind rejected Session.{s}",
                self.io,
                self.log_cfg,
                "drm",
                .{name},
            );
            self.logDbus("Properties.Set", &err);
            return error.LogindRejected;
        }
    }

    /// Subscribe to PrepareForSleep. Without this match the connection
    /// would never wake the compositor for a suspend and the DRM master
    /// would be lost across it silently.
    fn watchPrepareForSleep(self: *Session) Error!void {
        const bus = self.conn.?;
        var slot: ?*BusSlot = null;
        if (self.sysd.add_match(bus, &slot, prepare_for_sleep_match, onPrepareForSleep, self) < 0) {
            log_mod.warn(
                "drm: cannot watch PrepareForSleep; suspend is unmanaged",
                self.io,
                self.log_cfg,
                "drm",
                .{},
            );
            return error.BusUnavailable;
        }
        self.sleep_slot = slot;
    }

    /// Manager.TakeDevice(s id, s seat, u minor) - the call that stops the
    /// console session from taking the card back. While a session holds the
    /// device, logind does not hand the DRM master to anyone else
    /// (org.freedesktop.login1(5) Manager.TakeDevice: the device is locked
    /// to the session).
    fn takeDevice(self: *Session) void {
        if (self.device_taken) return;
        const bus = self.conn orelse return;
        var err: BusError = .{};
        var reply: ?*BusMessage = null;
        const rc = self.sysd.call_method(
            bus,
            login1_name,
            login1_path,
            login1_manager,
            "TakeDevice",
            &err,
            &reply,
            "ssi",
            self.own_session_id.ptr,
            self.seat.name.ptr,
            self.drm_minor,
        );
        defer self.freeReply(reply);
        if (rc < 0) {
            log_mod.warn(
                "drm: logind refused the DRM device; another session may take the master",
                self.io,
                self.log_cfg,
                "drm",
                .{},
            );
            self.logDbus("TakeDevice", &err);
            return;
        }
        self.device_taken = true;
    }

    /// Manager.ReleaseDevice - the mirror of `takeDevice`, run before the
    /// machine sleeps and again in `release`.
    fn releaseDevice(self: *Session) void {
        if (!self.device_taken) return;
        self.device_taken = false;
        const bus = self.conn orelse return;
        var err: BusError = .{};
        var reply: ?*BusMessage = null;
        const rc = self.sysd.call_method(
            bus,
            login1_name,
            login1_path,
            login1_manager,
            "ReleaseDevice",
            &err,
            &reply,
            "ssi",
            self.own_session_id.ptr,
            self.seat.name.ptr,
            self.drm_minor,
        );
        defer self.freeReply(reply);
        if (rc < 0) {
            log_mod.warn("drm: logind ReleaseDevice failed", self.io, self.log_cfg, "drm", .{});
            self.logDbus("ReleaseDevice", &err);
        }
    }

    /// Manager.TerminateSession - end the session so logind stops listing
    /// it and lets go of anything it still holds.
    fn terminateSession(self: *Session) void {
        const bus = self.conn orelse return;
        if (self.own_session_id.len == 0) return;
        var err: BusError = .{};
        var reply: ?*BusMessage = null;
        const rc = self.sysd.call_method(
            bus,
            login1_name,
            login1_path,
            login1_manager,
            "TerminateSession",
            &err,
            &reply,
            "s",
            self.own_session_id.ptr,
        );
        defer self.freeReply(reply);
        if (rc < 0) {
            log_mod.warn("drm: logind TerminateSession failed", self.io, self.log_cfg, "drm", .{});
            self.logDbus("TerminateSession", &err);
        }
    }

    /// Drop the bus: the connection is unusable, and polling a broken one
    /// spins the event loop. The session stays on logind's side until
    /// release() terminates it, and logind garbage-collects sessions whose
    /// leader has exited anyway.
    fn dropBus(self: *Session) void {
        if (self.conn) |bus| {
            _ = self.sysd.flush_close_unref(bus);
            self.conn = null;
        }
    }

    /// Take the device back and put the console back on our VT. Both halves
    /// are best-effort: a resume that cannot get the VT still gets the
    /// device, and the backend re-takes DRM master either way.
    fn reacquire(self: *Session) void {
        self.takeDevice();
        if (self.target_vt == 0) return;
        // The same veto as the startup switch: this VT is ours to move back
        // to only if there is one to move it back from. With no known
        // previous VT the console was never moved at startup either
        // (planVtSwitch said no), so a resume must not move it now - it
        // would take a VT it cannot hand back.
        if (self.previous_vt == 0) return;
        openConsole(self);
        self.switchVt(.wakeup) catch |err| {
            log_mod.warn(
                "drm: could not re-activate tty{d} after resume ({s})",
                self.io,
                self.log_cfg,
                "drm",
                .{ self.target_vt, @errorName(err) },
            );
        };
    }

    /// VT_ACTIVATE the target VT, wait for the DRM driver's VT_ACK, then ask
    /// logind to make this session the seat's active one.
    ///
    /// Whether the ack is waited for at all is `mode`'s decision, and it is
    /// the only thing the two call sites differ in: `waitsForVtAck` says
    /// why a raw read on the DRM fd is sound during start() and unsound
    /// during a resume.
    fn switchVt(self: *Session, mode: SwitchMode) VtError!void {
        try activateVt(self, self.target_vt);
        if (waitsForVtAck(mode)) try waitVtAck(self);
        // logind's own activation of the session that now owns the VT is a
        // separate, asynchronous step. Asking for it explicitly makes the
        // takeover deterministic instead of waiting for the seat uevent the
        // kernel emits from a VT switch (drivers/tty/vt.c vt_switch ->
        // kobject_uevent_env(..., "SWITCH=1"), which logind acts on in
        // src/login/logind-seat.c seat_active_session_changed).
        const bus = self.conn orelse return;
        var err: BusError = .{};
        var reply: ?*BusMessage = null;
        const rc = self.sysd.call_method(
            bus,
            login1_name,
            login1_path,
            login1_manager,
            "ActivateSession",
            &err,
            &reply,
            "s",
            self.own_session_id.ptr,
        );
        defer self.freeReply(reply);
        if (rc < 0) {
            log_mod.warn(
                "drm: logind ActivateSession failed; the VT is ours but the seat may not be",
                self.io,
                self.log_cfg,
                "drm",
                .{},
            );
            self.logDbus("ActivateSession", &err);
        }
    }

    fn freeReply(self: *Session, reply: ?*BusMessage) void {
        if (reply) |r| _ = self.sysd.message_unref(r);
    }

    /// Log a logind failure with the D-Bus error name and message, which is
    /// what actually says why ("Seat already active", "Interactive
    /// authentication required", ...).
    fn logDbus(self: *Session, comptime what: []const u8, err: *BusError) void {
        defer self.sysd.error_free(err);
        const name = if (err.name) |n| std.mem.span(n) else "(no name)";
        const message = if (err.message) |m| std.mem.span(m) else "(no message)";
        log_mod.warn(
            "drm: logind {s}: {s}: {s}",
            self.io,
            self.log_cfg,
            "drm",
            .{ what, name, message },
        );
    }
};

/// The D-Bus half of a PrepareForSleep signal. sd-bus calls it from
/// `sd_bus_process`, i.e. from `Session.dispatch`, so it only records the
/// boolean; the work happens in the caller, where it can log and recover.
fn onPrepareForSleep(
    m: *BusMessage,
    userdata: ?*anyopaque,
    reterr_error: ?*BusError,
) callconv(.c) c_int {
    _ = reterr_error;
    const self: *Session = @ptrCast(@alignCast(userdata.?));
    // "b": the signal's boolean argument.
    var sleeping: c_int = 0;
    if (self.sysd.message_read(m, "b", &sleeping) < 0) {
        log_mod.warn(
            "drm: PrepareForSleep carried no readable argument",
            self.io,
            self.log_cfg,
            "drm",
            .{},
        );
        return 0;
    }
    self.pending_sleep = sleeping != 0;
    return 0;
}

// ---------------------------------------------------------------------------
// VT plumbing
// ---------------------------------------------------------------------------

/// VT_ACTIVATE on the console fd. The ioctl goes through std.os.linux's
/// syscall wrapper: the same syscall glibc issues, and this module already
/// depends on raw syscalls (dlopen, /proc reads).
fn activateVt(self: *Session, vt: u16) VtError!void {
    if (self.console.fd < 0) return error.NoConsole;
    const rc = std.os.linux.ioctl(self.console.fd, vt_activate, vt);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| {
            log_mod.err(
                "drm: VT_ACTIVATE tty{d} failed ({s})",
                self.io,
                self.log_cfg,
                "drm",
                .{ vt, @tagName(err) },
            );
            return error.ActivateFailed;
        },
    }
}

/// Read the console's VT notifications until VT_ACK.
///
/// VT_RELDISP arrives first ("the console is being redrawn") and VT_ACK
/// after it means the new VT is really live (uapi/linux/vt.h: "#define
/// VT_ACK 4" is sent when the VT switch has completed). The loop accepts at
/// most `max_vt_events` notifications and then gives up, so a driver that
/// never acknowledges cannot wedge start().
///
/// This reads the ack fd RAW, which is only sound before the first page
/// flip: `waitsForVtAck` is where that is decided, and it is why a resume
/// never reaches this function.
fn waitVtAck(self: *Session) VtError!void {
    if (self.ack_fd < 0) return;
    var fds = [_]std.posix.pollfd{.{
        .fd = self.ack_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var seen: usize = 0;
    while (seen < max_vt_events) : (seen += 1) {
        fds[0].revents = 0;
        const ready = std.posix.poll(&fds, vt_ack_timeout_ms) catch return error.AckTimeout;
        if (ready == 0) return error.AckTimeout;
        // SAFETY: `ev` is fully written by std.posix.read before use; the
        // struct is two c_int with no padding, so a full read fills it.
        var ev: VtEvent = undefined;
        const n = std.posix.read(self.ack_fd, std.mem.asBytes(&ev)) catch return error.AckTimeout;
        if (n != @sizeOf(VtEvent)) return error.AckTimeout;
        if (ev.count == vt_ack) {
            log_mod.debug(
                "drm: VT_ACK after {d} console event(s)",
                self.io,
                self.log_cfg,
                "drm",
                .{seen + 1},
            );
            return;
        }
        if (ev.count != vt_reldisp) {
            // Not a console notification: something else is queued on this
            // fd. Stop rather than consume more of it.
            return error.AckTimeout;
        }
    }
    return error.AckTimeout;
}

/// The /dev/tty0 descriptor the VT_ACTIVATE ioctls go through.
///
/// At most one, for the life of the session, whoever asks: `reacquire` runs
/// on every resume and the only closer is `restoreVt`, which closes one
/// descriptor. An open that did not check first leaked a /dev/tty0 per
/// suspend/resume cycle until RLIMIT_NOFILE ran out, and from then on the
/// open failed, `activateVt` answered error.NoConsole and VT re-activation
/// stopped working - the precise outcome `reacquire` is written to avoid.
const Console = struct {
    /// -1 when there is no console to talk to.
    fd: std.posix.fd_t = -1,

    /// Open `node` unless a console is already open. True when this Console
    /// holds a usable descriptor afterwards.
    fn ensure(self: *Console, node: []const u8) bool {
        if (self.fd >= 0) return true;
        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            node,
            .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
            0,
        ) catch return false;
        self.fd = fd;
        return true;
    }

    /// Close the console, if one is open. Idempotent, like everything in
    /// teardown.
    fn close(self: *Console) void {
        if (self.fd < 0) return;
        _ = std.os.linux.close(self.fd);
        self.fd = -1;
    }
};

/// Open /dev/tty0 for VT_ACTIVATE. Best-effort: a machine with no VT (a
/// container, a kernel built without virtual terminals) simply does not get
/// a switch, and says so whenever it finds none.
fn openConsole(self: *Session) void {
    // Already open (the common case on a resume): nothing to do, and no
    // second descriptor to leak.
    if (self.console.fd >= 0) return;
    if (self.console.ensure(console_node)) return;
    log_mod.info(
        "drm: no {s}; VT switching disabled",
        self.io,
        self.log_cfg,
        "drm",
        .{console_node},
    );
}

/// The VT the console is showing right now, from /sys/class/tty/tty0/active
/// (drivers/tty/vt/vt.c registers the `active` attribute on tty0 and
/// `show_tty_active` writes the foreground VT into it). Null when sysfs is
/// unreadable or says nothing usable.
fn readActiveVt() ?u16 {
    var buf: [16]u8 = undefined;
    const n = readSmallFile(active_vt_sysfs, &buf) orelse return null;
    return parseActiveVt(buf[0..n]);
}

/// /proc/self/stat field 7 (tty_nr): the device this process's controlling
/// terminal is. Null when there is no controlling terminal.
fn processTtyNr() ?u64 {
    var buf: [4096]u8 = undefined;
    const n = readSmallFile("/proc/self/stat", &buf) orelse return null;
    return ttyNrFromStat(buf[0..n]);
}

/// Read up to `buf.len` bytes of a small file. Null when it cannot be
/// opened or read at all; a short read is a successful one, since these
/// files are a few bytes long and every parser here is defensive about a
/// truncated tail.
fn readSmallFile(path: []const u8, buf: []u8) ?usize {
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    ) catch return null;
    defer _ = std.os.linux.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.posix.read(fd, buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    return len;
}

/// Field 7 of /proc/self/stat, counted after the comm field: the kernel
/// writes `pid (comm) state ppid pgrp session tty_nr ...` and comm may
/// contain spaces and parentheses, so counting starts after the LAST ')'
/// (fs/proc/array.c do_task_stat).
fn ttyNrFromStat(text: []const u8) ?u64 {
    const close_paren = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, text[close_paren + 1 ..], ' ');
    // state, ppid, pgrp, session, tty_nr
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const tok = it.next() orelse return null;
        if (i == 4) return std.fmt.parseUnsigned(u64, tok, 10) catch null;
    }
    return null;
}

/// The seat from the environment, when there is one: logind's PAM stack
/// exports XDG_SEAT into every session it starts (pam_systemd(8)).
fn envSeat() ?[:0]const u8 {
    const raw = std.c.getenv("XDG_SEAT") orelse return null;
    const text = std.mem.span(raw);
    if (text.len == 0) return null;
    return text;
}
// ---------------------------------------------------------------------------
// udev connector hotplug
// ---------------------------------------------------------------------------

/// libudev's types, opaque in libudev.h.
const Udev = opaque {};
const UdevMonitor = opaque {};
const UdevDevice = opaque {};

/// libudev's ABI is declared here rather than through a translate-c shim
/// because build.zig - which this module must not touch - already links
/// libudev (for libinput's udev context) but wires no <libudev.h> shim.
/// These are libudev.h's exact prototypes; the ABI is frozen at LIBUDEV_183
/// (2012) and every symbol below is exported by libudev.so.1.
extern fn udev_new() ?*Udev;
extern fn udev_unref(udev: *Udev) ?*Udev;
extern fn udev_monitor_new_from_netlink(udev: *Udev, name: ?[*:0]const u8) ?*UdevMonitor;
extern fn udev_monitor_filter_add_match_subsystem_devtype(
    udev_monitor: *UdevMonitor,
    subsystem: ?[*:0]const u8,
    devtype: ?[*:0]const u8,
) c_int;
extern fn udev_monitor_enable_receiving(udev_monitor: *UdevMonitor) c_int;
extern fn udev_monitor_get_fd(udev_monitor: *UdevMonitor) c_int;
extern fn udev_monitor_receive_device(udev_monitor: *UdevMonitor) ?*UdevDevice;
extern fn udev_monitor_unref(udev_monitor: *UdevMonitor) ?*UdevMonitor;
extern fn udev_device_get_action(udev_device: *UdevDevice) ?[*:0]const u8;
extern fn udev_device_get_devnode(udev_device: *UdevDevice) ?[*:0]const u8;
extern fn udev_device_get_sysname(udev_device: *UdevDevice) ?[*:0]const u8;
extern fn udev_device_get_devtype(udev_device: *UdevDevice) ?[*:0]const u8;
extern fn udev_device_unref(udev_device: *UdevDevice) ?*UdevDevice;

/// The DRM subsystem, the only thing this monitor filters on: connectors
/// live in it (drivers/gpu/drm/drm_sysfs.c gives each connector its own
/// sysfs entry) and plugging a cable produces an event on it.
const drm_subsystem: [:0]const u8 = "drm";
/// The udev netlink group name (libudev.h: udev_monitor_new_from_netlink's
/// `name` is "udev" for the userspace-filtered group, "kernel" for the raw
/// one). "udev" is what wlroots uses (backend/drm/backend.c).
const udev_netlink_name: [:0]const u8 = "udev";
/// The devtype the kernel gives a DRM connector (its uevent carries
/// DEVTYPE=drm_connector). Exact when present, so it is checked first.
const drm_connector_devtype: [:0]const u8 = "drm_connector";

/// What udev says happened to a `drm` device.
pub const Action = enum {
    /// The device appeared ("add").
    add,
    /// The device disappeared ("remove") - a card, or an entire connector,
    /// went away.
    remove,
    /// The device changed ("change"). This is what plugging a cable into a
    /// connector the kernel already knows produces: the connector's sysfs
    /// entry stays and its status flips from disconnected to connected
    /// (drivers/gpu/drm/drm_connector.c connector_detect ->
    /// drm_sysfs_connector_status), and the uevent that follows is a
    /// change. Watching "add" alone would miss every plug.
    change,
    /// move/bind/unbind, and whatever a future udev adds. The caller
    /// ignores these; decoding one as a connect would modeset on nothing.
    other,

    /// Decode a udev action string. libudev.h documents the set as "add",
    /// "remove", "change", "move", "bind", "unbind", "owner"; anything else
    /// is `other` rather than a guess.
    pub fn fromStr(text: []const u8) Action {
        if (std.mem.eql(u8, text, "add")) return .add;
        if (std.mem.eql(u8, text, "remove")) return .remove;
        if (std.mem.eql(u8, text, "change")) return .change;
        return .other;
    }
};

/// One decoded udev event for a `drm` device.
pub const HotplugEvent = struct {
    action: Action,
    /// sysfs name: "card0", "card0-DP-1", "renderD128". Borrowed from the
    /// monitor - valid until the next `Hotplug.next` call.
    sysname: []const u8 = "",
    /// The device node, "" for a device with none (a connector has none).
    devnode: []const u8 = "",
    /// DEVTYPE from the uevent, "" when the kernel sent none.
    devtype: []const u8 = "",

    /// Is this a connector rather than a card or a render node?
    ///
    /// DRM names connector sysfs entries "<card>-<connector>" (the
    /// connector's dev_name, drm_sysfs.c: "%s-%s" of the card and the
    /// connector name). The devtype is checked first because it is exact;
    /// the name shape is the fallback for kernels that send no DEVTYPE.
    pub fn isConnector(self: HotplugEvent) bool {
        if (self.devtype.len != 0) return std.mem.eql(u8, self.devtype, drm_connector_devtype);
        if (!std.mem.startsWith(u8, self.sysname, "card")) return false;
        return std.mem.indexOfScalar(u8, self.sysname, '-') != null;
    }

    /// The connector name without its card prefix ("card0-DP-1" ->
    /// "DP-1"), or null when the event is not a connector. This is the name
    /// a KMS connector's sysfs entry carries after the card, and it is what
    /// the backend matches its outputs against.
    pub fn connectorName(self: HotplugEvent) ?[]const u8 {
        if (!self.isConnector()) return null;
        const dash = std.mem.indexOfScalar(u8, self.sysname, '-') orelse return null;
        return self.sysname[dash + 1 ..];
    }
};

/// A udev monitor over the `drm` subsystem.
///
/// Owns nothing but the monitor and its udev context: the caller decides
/// what an event means for its outputs. Poll `pollFd` for `pollEvents`, then
/// drain with `next` until it returns null.
pub const Hotplug = struct {
    allocator: std.mem.Allocator,
    udev: *Udev,
    monitor: *UdevMonitor,
    /// The device whose strings the last `next` handed out; unreffed on the
    /// next call, which is what keeps those borrows valid.
    held: ?*UdevDevice = null,

    /// Bring up the monitor. error.UdevUnavailable is non-fatal: the
    /// compositor keeps running and simply does not react to connector
    /// changes.
    pub fn open(allocator: std.mem.Allocator) HotplugError!*Hotplug {
        const udev = udev_new() orelse return error.UdevUnavailable;
        errdefer _ = udev_unref(udev);
        const monitor = udev_monitor_new_from_netlink(udev, udev_netlink_name) orelse return error.UdevUnavailable;
        errdefer _ = udev_monitor_unref(monitor);
        // Subsystem-only filter: the devtype stays null because a connector
        // arrives as a change on its own entry, and pinning a devtype would
        // miss the card-level events that say the driver came back.
        if (udev_monitor_filter_add_match_subsystem_devtype(monitor, drm_subsystem, null) < 0) {
            return error.UdevUnavailable;
        }
        // Nothing arrives until receiving is enabled (libudev.h: the filter
        // only takes effect after this call).
        if (udev_monitor_enable_receiving(monitor) < 0) return error.UdevUnavailable;
        // The monitor holds a borrowed pointer to the context (libudev.h:
        // udev_monitor_get_udev "returns the udev context this monitor is
        // bound to"), so both are owned here and released together.
        const self = try allocator.create(Hotplug);
        self.* = .{ .allocator = allocator, .udev = udev, .monitor = monitor };
        return self;
    }

    /// The fd to poll. libudev documents it as pollable for POLLIN
    /// (libudev.h: udev_monitor_get_fd returns the file descriptor that
    /// "can be polled for incoming events").
    pub fn pollFd(self: *Hotplug) std.posix.fd_t {
        return udev_monitor_get_fd(self.monitor);
    }

    /// The poll mask for `pollFd`: POLLIN. This libudev exports no
    /// udev_monitor_get_events, and a udev monitor fd only ever signals in
    /// that direction anyway.
    pub fn pollEvents(self: *Hotplug) i16 {
        _ = self;
        return std.posix.POLL.IN;
    }

    /// The next event, or null when the queue is empty. One call consumes
    /// exactly one event; the caller drains until null.
    pub fn next(self: *Hotplug) ?HotplugEvent {
        if (self.held) |dev| {
            _ = udev_device_unref(dev);
            self.held = null;
        }
        const dev = udev_monitor_receive_device(self.monitor) orelse return null;
        self.held = dev;
        const action_raw = udev_device_get_action(dev) orelse return null;
        return .{
            .action = Action.fromStr(std.mem.span(action_raw)),
            .sysname = spanOrEmpty(udev_device_get_sysname(dev)),
            .devnode = spanOrEmpty(udev_device_get_devnode(dev)),
            .devtype = spanOrEmpty(udev_device_get_devtype(dev)),
        };
    }

    /// Close the monitor and the udev context. Idempotent.
    pub fn close(self: *Hotplug) void {
        if (self.held) |dev| {
            _ = udev_device_unref(dev);
            self.held = null;
        }
        _ = udev_monitor_unref(self.monitor);
        _ = udev_unref(self.udev);
        self.allocator.destroy(self);
    }
};

fn spanOrEmpty(ptr: ?[*:0]const u8) []const u8 {
    const p = ptr orelse return "";
    return std.mem.span(p);
}

// ---------------------------------------------------------------------------
// Tests (pure logic; the device paths need a card)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "no seat: the VM path claims nothing and blocks nothing" {
    // What readSeat returns on a machine with no logind session at all.
    const seat: Seat = .{};
    const plan = planAcquire(seat, false, 0);
    try testing.expect(!plan.open_session);
    try testing.expect(!plan.switch_vt);
    try testing.expect(!plan.blocked);
    try testing.expectEqual(Reason.no_session_manager, plan.reason);

    // A seat name with have_logind false is still the VM path: the caller
    // reports what it knows and nothing more.
    const named = planAcquire(.{ .name = "seat0" }, false, 0);
    try testing.expect(!named.open_session);
    try testing.expectEqual(Reason.no_session_manager, named.reason);
}

test "a seat that is not graphical blocks the compositor" {
    const seat: Seat = .{
        .name = "seat0",
        .can_tty = true,
        .can_graphical = false,
        .can_multi_session = true,
    };
    const plan = planAcquire(seat, true, 2);
    try testing.expect(plan.blocked);
    try testing.expect(!plan.open_session);
    try testing.expect(!plan.switch_vt);
    try testing.expectEqual(Reason.seat_not_graphical, plan.reason);
}

test "an occupied single-session seat is refused, a shareable one is not" {
    // logind will not host a second session and someone else is active:
    // taking VT 2 would log them out, so refuse.
    const blocked = planAcquire(.{
        .name = "seat0",
        .can_tty = true,
        .can_graphical = true,
        .active_session = "c3",
        .active_vt = 1,
    }, true, 2);
    try testing.expect(blocked.blocked);
    try testing.expectEqual(Reason.seat_occupied, blocked.reason);

    // Same seat, but it can host a second session: take it, and switch the
    // console because the active VT (1) is not ours (2).
    const shareable = planAcquire(.{
        .name = "seat0",
        .can_tty = true,
        .can_graphical = true,
        .can_multi_session = true,
        .active_session = "c3",
        .active_vt = 1,
    }, true, 2);
    try testing.expect(!shareable.blocked);
    try testing.expect(shareable.open_session);
    try testing.expect(shareable.switch_vt);
    try testing.expectEqual(Reason.seat_available, shareable.reason);
}

test "our own session needs no VT switch, a seat without TTY has none to switch" {
    // We are the active session already: the console is on our VT.
    const mine = planAcquire(.{
        .name = "seat0",
        .can_tty = true,
        .can_graphical = true,
        .can_multi_session = true,
        .active_session = "c3",
        .active_is_us = true,
        .active_vt = 2,
    }, true, 2);
    try testing.expect(mine.open_session);
    try testing.expect(!mine.switch_vt);
    try testing.expectEqual(Reason.seat_available, mine.reason);

    // A different VT of ours: switch to it.
    const other = planAcquire(.{
        .name = "seat0",
        .can_tty = true,
        .can_graphical = true,
        .can_multi_session = true,
        .active_session = "c3",
        .active_vt = 2,
    }, true, 4);
    try testing.expect(other.open_session);
    try testing.expect(other.switch_vt);

    // A seat with no TTY has no VT to switch, but the session is still made.
    const no_tty = planAcquire(.{ .name = "seat0", .can_graphical = true }, true, 4);
    try testing.expect(no_tty.open_session);
    try testing.expect(!no_tty.switch_vt);
    try testing.expectEqual(Reason.seat_has_no_tty, no_tty.reason);
}

test "needsVtSwitch only for a real, different target" {
    try testing.expect(needsVtSwitch(1, 2));
    // No target: the VM case, nothing to steal.
    try testing.expect(!needsVtSwitch(1, 0));
    try testing.expect(!needsVtSwitch(0, 0));
    // Already there: re-activating would only redraw.
    try testing.expect(!needsVtSwitch(3, 3));
}

test "no VT to restore: the console is not moved, and the plan says so" {
    // A graphics seat with a TTY, but nothing anywhere that says which VT
    // the console is on: logind has no session on it (so Session.VTNumber
    // answers for nobody) and sysfs was unreadable. Moving the console here
    // would take a VT that restoreVt cannot hand back, and every exit path
    // leaves the console stranded on the compositor's own VT with no
    // session on it.
    const seat: Seat = .{
        .name = "seat0",
        .can_tty = true,
        .can_graphical = true,
        .can_multi_session = true,
        .active_session = "",
        .active_vt = 0,
    };
    try testing.expect(!planVtSwitch(seat, 2, 0));

    // The plan Session.open acts on must agree, or the console still moves.
    const plan = planAcquire(seat, true, 2);
    try testing.expect(plan.open_session);
    try testing.expect(!plan.switch_vt);
    try testing.expectEqual(Reason.seat_available, plan.reason);

    // With a known VT - which is what readSeat fills in, from sysfs or from
    // logind - the same seat switches exactly as before.
    const known: Seat = .{ .name = seat.name, .can_tty = true, .can_graphical = true, .can_multi_session = true, .active_session = "c3", .active_vt = 1 };
    try testing.expect(planVtSwitch(known, 2, 1));
    try testing.expect(planAcquire(known, true, 2).switch_vt);
    // Already there: nothing to move, nothing to restore.
    try testing.expect(!planVtSwitch(seat, 2, 2));
    // No target of our own (a daemon, a pty): nothing to steal.
    try testing.expect(!planVtSwitch(seat, 0, 1));
    // A seat without a TTY has no console to move, whatever the numbers say.
    try testing.expect(!planVtSwitch(.{ .name = "seat0", .can_graphical = true }, 2, 1));
}

/// Stands in for the backend's sleep callback: `acquireFor` never calls it,
/// and a required field with no default still has to be filled in.
fn probeOnSleep(ctx: ?*anyopaque, sleeping: bool) void {
    _ = ctx;
    _ = sleeping;
}

test "the VT the session holds is the one its plan was made from" {
    const seat: Seat = .{
        .name = "seat0",
        .can_tty = true,
        .can_graphical = true,
        .can_multi_session = true,
        .active_session = "c3",
        .active_vt = 1,
    };
    // An explicit request is decided from `opts` alone: chooseTargetVt
    // reaches for the environment and /proc only on the derive path.
    const opts: Options = .{ .target_vt = 2, .on_sleep = probeOnSleep };
    const acq = acquireFor(seat, opts);

    // The VT held is the VT that was chosen...
    try testing.expectEqual(chooseTargetVt(opts), acq.target_vt);
    try testing.expectEqual(@as(u16, 2), acq.target_vt);
    // ...and the plan the session will act on is the one THAT number makes.
    // These two used to disagree: the plan moved a VT while the field kept
    // its default, so no switch, no restore and no resume ever happened.
    try testing.expectEqual(planAcquire(seat, true, acq.target_vt), acq.plan);
    try testing.expect(acq.plan.switch_vt);
    // A plan made from the dropped number would say otherwise, which is why
    // this comparison is not a tautology.
    try testing.expect(!planAcquire(seat, true, 0).switch_vt);

    // The console moves only because it is on a known VT, and it goes back
    // to that same number.
    try testing.expectEqual(seat.active_vt, acq.previous_vt);
    try testing.expectEqual(@as(u16, 1), acq.previous_vt);
    try testing.expect(needsVtSwitch(acq.previous_vt, acq.target_vt));

    // A caller with no business moving a console decides 0, and 0 produces
    // the plan that moves nothing.
    const quiet = acquireFor(seat, .{ .derive_vt = false, .on_sleep = probeOnSleep });
    try testing.expectEqual(@as(u16, 0), quiet.target_vt);
    try testing.expectEqual(planAcquire(seat, true, 0), quiet.plan);
    try testing.expect(!quiet.plan.switch_vt);

    // No seat: the VT is still chosen and still held - it is what the
    // session would claim - but there is no session to claim it on, and no
    // known VT to move the console back to, so nothing moves.
    const vm = acquireFor(.{}, .{ .target_vt = 2, .on_sleep = probeOnSleep });
    try testing.expectEqual(@as(u16, 2), vm.target_vt);
    try testing.expectEqual(@as(u16, 0), vm.previous_vt);
    try testing.expect(!vm.plan.open_session);
    try testing.expect(!vm.plan.switch_vt);
    try testing.expectEqual(Reason.no_session_manager, vm.plan.reason);
}

test "only the startup switch waits for the VT ack" {
    // start() runs before the first commit, so the DRM fd can only produce
    // the console's VT event (drm_fops.c queues one event list per drm_file,
    // and no flip has been committed yet). The ack is worth reading.
    try testing.expect(waitsForVtAck(.startup));

    // A resume runs long after the first flip was queued: the same fd also
    // carries page-flip completions behind the same read offset, so the raw
    // read would either never see the VT event or stop between records and
    // break the backend's own drmHandleEvent drain. VT_ACTIVATE is
    // synchronous and logind re-activates the VT from the kernel's uevent,
    // so nothing is waited for.
    try testing.expect(!waitsForVtAck(.wakeup));
}

test "suspend releases, resume re-acquires, repeats do nothing" {
    // Going down from running: give the device back and drop the master.
    const down = planSleep(.running, true, true);
    try testing.expect(down.work.release_device);
    try testing.expect(down.work.drop_master);
    try testing.expect(!down.work.reacquire);
    try testing.expectEqual(Phase.suspending, down.next);

    // No logind session: still drop the master, nothing to release.
    const vm = planSleep(.running, true, false);
    try testing.expect(!vm.work.release_device);
    try testing.expect(vm.work.drop_master);

    // Coming back up: re-take everything.
    const up = planSleep(.suspended, false, true);
    try testing.expect(up.work.reacquire);
    try testing.expect(!up.work.drop_master);
    try testing.expectEqual(Phase.resuming, up.next);

    // A repeated suspend must not drop the master twice, and a repeated
    // resume must not re-take the device twice.
    const again = planSleep(.suspending, true, true);
    try testing.expect(!again.work.drop_master);
    const up_again = planSleep(.resuming, false, true);
    try testing.expect(up_again.work.reacquire);

    // Waking without having slept: nothing to undo.
    const cancelled = planSleep(.running, false, true);
    try testing.expect(!cancelled.work.reacquire);
    try testing.expect(!cancelled.work.drop_master);
    try testing.expectEqual(Phase.running, cancelled.next);
}

test "planSleep answers every phase, for both signals" {
    inline for ([_]Phase{ .startup, .running, .suspending, .suspended, .resuming }) |from| {
        // Sleeping. From anywhere but the bottom of the ladder the machine
        // really goes to sleep: the device goes back to logind and the DRM
        // master is dropped. From the bottom, logind is repeating a signal
        // we have already answered, and the plan must be empty - that is
        // what stops a second DROP_MASTER.
        const down = planSleep(from, true, true);
        switch (from) {
            .startup, .running, .resuming => {
                try testing.expect(down.work.release_device);
                try testing.expect(down.work.drop_master);
                try testing.expectEqual(Phase.suspending, down.next);
            },
            .suspending, .suspended => {
                try testing.expectEqual(SleepWork{}, down.work);
                try testing.expectEqual(Phase.suspended, down.next);
            },
        }

        // Waking. Everything that could have been given up is given back,
        // except a wake from a phase that never slept.
        const up = planSleep(from, false, true);
        switch (from) {
            .startup, .running => {
                try testing.expectEqual(SleepWork{}, up.work);
                try testing.expectEqual(Phase.running, up.next);
            },
            .suspending, .suspended, .resuming => {
                try testing.expect(up.work.reacquire);
                try testing.expect(!up.work.drop_master);
                try testing.expectEqual(Phase.resuming, up.next);
            },
        }

        // Without a logind session there is no device to release, but the
        // master is still dropped - and the phase still moves the same way.
        const no_logind = planSleep(from, true, false);
        try testing.expectEqual(down.next, no_logind.next);
        if (down.work.release_device) try testing.expect(!no_logind.work.release_device);
        if (down.work.drop_master) try testing.expect(no_logind.work.drop_master);
    }
}

/// What the backend half of a transition observed: the phase it read - the
/// LIVE one, exactly as drm.zig's handlePrepareForSleep reads it through
/// `sleepPhase()` - and how many times it ran.
const SleepProbe = struct {
    phase: *Phase,
    seen_phase: Phase = .startup,
    calls: usize = 0,
};

/// Stands in for the backend half of a transition.
fn probeBackendSleep(ctx: ?*anyopaque, sleeping: bool) void {
    const probe: *SleepProbe = @ptrCast(@alignCast(ctx.?));
    _ = sleeping;
    probe.seen_phase = probe.phase.*;
    probe.calls += 1;
}

/// This module's half is a no-op here: releasing and re-taking the device
/// needs a logind bus, and the work it would be given is planSleep's, which
/// the test below pins.
fn probeSessionWork(ctx: ?*anyopaque, work: SleepWork) void {
    _ = ctx;
    _ = work;
}

test "the backend half runs while the phase still reports the plan's own starting point" {
    var phase: Phase = .running;
    var probe: SleepProbe = .{ .phase = &phase };

    // Suspend. The backend resolves its half through
    // planSleep(sleepPhase(), ...), so the phase it reads has to be the one
    // the plan was made from - otherwise it re-plans a transition that has
    // already run, which for a suspend means no work at all and no
    // DRM_IOCTL_DROP_MASTER.
    applySleep(&phase, true, true, probeSessionWork, probeBackendSleep, &probe);
    try testing.expectEqual(Phase.running, probe.seen_phase);
    try testing.expectEqual(Phase.suspending, phase);
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expect(planSleep(probe.seen_phase, true, true).work.drop_master);

    // Because the phase moved, logind repeating the signal is a REPEAT and
    // not a second suspend: no second drop, no second release.
    applySleep(&phase, true, true, probeSessionWork, probeBackendSleep, &probe);
    try testing.expectEqual(Phase.suspending, probe.seen_phase);
    try testing.expectEqual(SleepWork{}, planSleep(probe.seen_phase, true, true).work);
    try testing.expectEqual(Phase.suspended, phase);

    // The wake is acted on for real: the backend sees the transition that
    // actually re-takes DRM master and re-arms the flip pipeline.
    applySleep(&phase, false, true, probeSessionWork, probeBackendSleep, &probe);
    try testing.expectEqual(Phase.suspended, probe.seen_phase);
    try testing.expect(planSleep(probe.seen_phase, false, true).work.reacquire);
    try testing.expectEqual(Phase.resuming, phase);

    // A second wake repeats the work, which the backend absorbs (becomeMaster
    // early-returns while it holds the master), and the phase stays put.
    applySleep(&phase, false, true, probeSessionWork, probeBackendSleep, &probe);
    try testing.expectEqual(Phase.resuming, probe.seen_phase);
    try testing.expect(planSleep(probe.seen_phase, false, true).work.reacquire);
    try testing.expectEqual(Phase.resuming, phase);
    try testing.expectEqual(@as(usize, 4), probe.calls);
}

test "the console descriptor is opened once, however often it is asked for" {
    // /dev/null stands in for /dev/tty0: what matters is the descriptor
    // COUNT, not which node it points at, and /dev/null opens on a machine
    // with no console at all (a container, a CI box).
    var console: Console = .{};
    const before = countOpenFds() orelse return error.SkipZigTest;

    try testing.expect(console.ensure("/dev/null"));
    const first = console.fd;
    try testing.expect(first >= 0);
    try testing.expectEqual(before + 1, countOpenFds().?);

    // Every resume asks again - that is the path that used to leak one
    // /dev/tty0 per suspend/resume cycle until RLIMIT_NOFILE ran out.
    try testing.expect(console.ensure("/dev/null"));
    try testing.expect(console.ensure("/dev/null"));
    try testing.expectEqual(first, console.fd);
    try testing.expectEqual(before + 1, countOpenFds().?);

    // One closer, one descriptor: the count goes back where it started.
    console.close();
    try testing.expectEqual(before, countOpenFds().?);
    try testing.expectEqual(@as(std.posix.fd_t, -1), console.fd);
    console.close();
    try testing.expectEqual(before, countOpenFds().?);
}

/// How many descriptors this process holds, from the kernel's own
/// per-process table (/proc/self/fd, fs/proc/fd.c). Null when it cannot be
/// read, which is the only case where a leak count cannot be believed.
fn countOpenFds() ?usize {
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, "/proc/self/fd", .{ .iterate = true }) catch return null;
    defer dir.close(std.testing.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(std.testing.io) catch null) |_| n += 1;
    return n;
}

test "VT number decoding" {
    // tty2: new_encode_dev(4 << 8 | 2) == (4 << 8) | 2.
    try testing.expectEqual(@as(?u16, 2), vtFromTtyNr((4 << 8) | 2));
    try testing.expectEqual(@as(?u16, 7), vtFromTtyNr((4 << 8) | 7));
    // A pty (major 136, minor 1) is not a VT.
    try testing.expectEqual(@as(?u16, null), vtFromTtyNr((136 << 8) | 1));
    // /dev/null (1:3) and "no tty" (0) are not VTs.
    try testing.expectEqual(@as(?u16, null), vtFromTtyNr((1 << 8) | 3));
    try testing.expectEqual(@as(?u16, null), vtFromTtyNr(0));
    // Past the kernel's MAX_VT (63) is out of range.
    try testing.expectEqual(@as(?u16, null), vtFromTtyNr((4 << 8) | 64));
}

test "active VT parsing is strict, and reads the kernel's own spelling" {
    // What show_tty_active writes: "tty7\n", the name of the VT the console
    // is on. This is the whole point of the test - a digits-only parser
    // rejects every value the kernel emits, and the VT path goes quiet.
    try testing.expectEqual(@as(?u16, 7), parseActiveVt("tty7\n"));
    try testing.expectEqual(@as(?u16, 2), parseActiveVt("tty2"));
    try testing.expectEqual(@as(?u16, 63), parseActiveVt("tty63\n"));
    // A bare number is accepted too: it is what WAYLAND_VT carries, and
    // this one parser reads both.
    try testing.expectEqual(@as(?u16, 7), parseActiveVt("7\n"));
    try testing.expectEqual(@as(?u16, 3), parseActiveVt("3"));
    // 0 is not a VT; 64 is past the kernel's MAX_VT, named or bare.
    try testing.expectEqual(@as(?u16, null), parseActiveVt("0\n"));
    try testing.expectEqual(@as(?u16, null), parseActiveVt("64\n"));
    try testing.expectEqual(@as(?u16, null), parseActiveVt("tty0\n"));
    try testing.expectEqual(@as(?u16, null), parseActiveVt("tty64\n"));
    // Garbage is not guessed at, and neither is a console that is not a VT:
    // a serial or virtual console is a name this parser must refuse, not
    // a number to switch to.
    try testing.expectEqual(@as(?u16, null), parseActiveVt(""));
    try testing.expectEqual(@as(?u16, null), parseActiveVt("tty"));
    try testing.expectEqual(@as(?u16, null), parseActiveVt("pts/3\n"));
    try testing.expectEqual(@as(?u16, null), parseActiveVt("ttyAMA0\n"));
    try testing.expectEqual(@as(?u16, null), parseActiveVt("100"));
    try testing.expectEqual(@as(?u16, null), parseActiveVt("tty100\n"));
}

test "target VT: environment wins, then the controlling tty, then none" {
    // WAYLAND_VT is explicit.
    try testing.expectEqual(@as(u16, 5), targetVtFromEnv("5", (4 << 8) | 2));
    // A nonsense WAYLAND_VT falls through to the tty rather than switching
    // the console to nowhere.
    try testing.expectEqual(@as(u16, 2), targetVtFromEnv("99", (4 << 8) | 2));
    try testing.expectEqual(@as(u16, 2), targetVtFromEnv(null, (4 << 8) | 2));
    // No VT anywhere (a daemon, or a pty): nothing to steal.
    try testing.expectEqual(@as(u16, 0), targetVtFromEnv(null, null));
    try testing.expectEqual(@as(u16, 0), targetVtFromEnv("0", null));
}

test "tty_nr field of /proc/self/stat is read after the last paren" {
    // The comm field may contain spaces and parentheses, so the count must
    // start after the LAST ')'.
    const stat = "1234 (my (weird) name) S 1200 1200 1200 34816 0 0 -1 4194560";
    try testing.expectEqual(@as(?u64, 34816), ttyNrFromStat(stat));
    // A tty2 encoding: (4 << 8) | 2 == 1026.
    const on_tty2 = "1234 (bash) S 1200 1200 1234 1026 0 0 -1 4194560";
    try testing.expectEqual(@as(?u64, 1026), ttyNrFromStat(on_tty2));
    // Truncated input yields null rather than a wrong number.
    try testing.expectEqual(@as(?u64, null), ttyNrFromStat("1234 (bash) S 1200"));
    try testing.expectEqual(@as(?u64, null), ttyNrFromStat("no parens here"));
}

test "udev action decoding" {
    try testing.expectEqual(Action.add, Action.fromStr("add"));
    try testing.expectEqual(Action.remove, Action.fromStr("remove"));
    try testing.expectEqual(Action.change, Action.fromStr("change"));
    // move/bind/unbind are not connector events, and a future udev action
    // must not be guessed into one.
    try testing.expectEqual(Action.other, Action.fromStr("move"));
    try testing.expectEqual(Action.other, Action.fromStr("bind"));
    try testing.expectEqual(Action.other, Action.fromStr("owner"));
    try testing.expectEqual(Action.other, Action.fromStr(""));
}

test "connector events are told apart from card and render nodes" {
    // The exact devtype wins.
    const typed = HotplugEvent{
        .action = .change,
        .sysname = "card0-DP-1",
        .devtype = drm_connector_devtype,
    };
    try testing.expect(typed.isConnector());
    try testing.expectEqualStrings("DP-1", typed.connectorName().?);

    // Without a devtype the sysfs name shape decides.
    const by_name = HotplugEvent{ .action = .change, .sysname = "card0-DP-1" };
    try testing.expect(by_name.isConnector());
    try testing.expectEqualStrings("DP-1", by_name.connectorName().?);

    // A card and a render node are not connectors, so a card-level event
    // must not be mistaken for a cable.
    const card = HotplugEvent{ .action = .add, .sysname = "card0", .devnode = "/dev/dri/card0" };
    try testing.expect(!card.isConnector());
    try testing.expectEqual(@as(?[]const u8, null), card.connectorName());
    const render = HotplugEvent{ .action = .add, .sysname = "renderD128", .devnode = "/dev/dri/renderD128" };
    try testing.expect(!render.isConnector());
    try testing.expectEqual(@as(?[]const u8, null), render.connectorName());
}
