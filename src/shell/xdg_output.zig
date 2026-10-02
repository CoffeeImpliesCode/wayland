//! zxdg_output_manager_v1 (unstable/xdg-output): lets clients know an
//! output's LOGICAL geometry (position/size in global compositor space)
//! plus a stable name/description, independent of wl_output's physical
//! mode/scale/transform.
//!
//! Scope: the manager global + per-wl_output zxdg_output_v1 objects.
//! Each get_xdg_output sends logical_position (0,0 for the single-output
//! server — the output is the whole layout), logical_size (the mode size
//! in logical pixels = mode / scale), then name + description (since v2),
//! then done. The values are snapshots at get_xdg_output time; a later
//! mode/scale change re-sends position/size + done (clients like grim
//! read these to place captures; the re-send keeps them current).
//!
//! Cross-module contract: the manager binds per client; get_xdg_output
//! creates a zxdg_output_v1 for a wl_output resource. Each get creates a
//! new zxdg_output — zxdg_output_manager_v1 declares no errors at all
//! (xdg-output-unstable-v1.xml:57-78), so there is no duplicate-output
//! error to post. The zxdg_output dies with its wl_output (the
//! output_destroy listener) and with the client; the resource destroy
//! frees the state. The wl_output argument must map to a live WlOutput
//! of this server (the get on a foreign/dead output is inerted — the
//! resource carries no state, so no events ever arrive and no request
//! dereferences anything).

const std = @import("std");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const display_mod = @import("../core/display.zig");
const output_mod = @import("../output/output.zig");
const wl_output_mod = @import("../output/wl_output.zig");

const log_tag = "xdg_output";

/// zxdg_output_manager_v1 protocol version this library implements.
pub const xdg_output_version: u32 = 3;

pub const XdgOutput = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    global: ?*wire.Global = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) !*XdgOutput {
        const xo = try allocator.create(XdgOutput);
        errdefer allocator.destroy(xo);
        xo.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
        };
        xo.global = try display.addGlobal(
            server.zxdg.OutputManagerV1,
            *XdgOutput,
            bindManager,
            xdg_output_version,
            xo,
        );
        log.debug("xdg_output manager created", io, log_cfg, log_tag, .{});
        return xo;
    }

    pub fn deinit(self: *XdgOutput) void {
        if (self.global) |g| g.remove();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn bindManager(client_wire: *wire.Client, xo: *XdgOutput, version: u32, id: u32) void {
    const resource = server.zxdg.OutputManagerV1.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    resource.setHandler(*XdgOutput, managerRequest, null, xo);
}

fn managerRequest(
    resource: *server.zxdg.OutputManagerV1,
    request: server.zxdg.OutputManagerV1.Request,
    xo: *XdgOutput,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_xdg_output => |r| {
            // The wl_output argument must be one of ours (identity check
            // via the wl_output module's resource list). A foreign/dead
            // output gets an inert zxdg_output: no events, no state.
            const ud = r.output.getUserData() orelse {
                const inert = server.zxdg.OutputV1.create(
                    resource.getClient(),
                    resource.getVersion(),
                    r.id,
                ) catch return;
                inert.setHandler(?*XdgOutputState, deadHandler, null, null);
                return;
            };
            const wl_out: *wl_output_mod.WlOutput = @ptrCast(@alignCast(ud));
            if (!wlOutputOwns(wl_out, r.output)) {
                const inert = server.zxdg.OutputV1.create(
                    resource.getClient(),
                    resource.getVersion(),
                    r.id,
                ) catch return;
                inert.setHandler(?*XdgOutputState, deadHandler, null, null);
                return;
            }
            const state = xo.allocator.create(XdgOutputState) catch {
                resource.getClient().postNoMemory();
                return;
            };
            state.* = .{
                .allocator = xo.allocator,
                // SAFETY: assigned immediately after `state.* = .{...}`,
                // before the resource is created and before any listener
                // can run. The create's catch block destroys state, so no
                // path reads the field while it is undefined.
                .resource = undefined,
                .wl_output = wl_out,
                .output_destroy_listener = wire.Listener(*output_mod.Output).init(onWlOutputDestroy),
            };
            const res = server.zxdg.OutputV1.create(resource.getClient(), resource.getVersion(), r.id) catch {
                xo.allocator.destroy(state);
                resource.getClient().postNoMemory();
                return;
            };
            state.resource = res;
            res.setHandler(*XdgOutputState, stateRequest, stateDestroy, state);
            // The zxdg_output dies with its wl_output (wlroots
            // xdg_output_handle_destroy of the source output; the client
            // is expected to bind zxdg_output again after a wl_output
            // re-create).
            wl_out.output.events.destroy.add(&state.output_destroy_listener);
            sendState(state);
            log.debug(
                "xdg_output for wl_output@{d} ({s}): logical {d}x{d} at 0,0",
                xo.io,
                xo.log_cfg,
                log_tag,
                .{
                    r.output.getId(),
                    wl_out.name,
                    wl_out.output.width,
                    wl_out.output.height,
                },
            );
        },
    }
}

/// Whether `res` is a resource of `wl_out` (the identity check for the
/// wl_output argument; screencopy does the same via the resource list).
fn wlOutputOwns(wl_out: *wl_output_mod.WlOutput, res: *server.wl.Output) bool {
    for (wl_out.resources.items) |r| {
        if (r == res) return true;
    }
    return false;
}

/// Per (client, wl_output) zxdg_output_v1 state.
const XdgOutputState = struct {
    allocator: std.mem.Allocator,
    resource: *server.zxdg.OutputV1,
    wl_output: *wl_output_mod.WlOutput,
    output_destroy_listener: wire.Listener(*output_mod.Output),
};

/// Send the full logical state (position/size/name/description/done).
/// Called at get_xdg_output and on output commit (mode/scale changes).
fn sendState(state: *XdgOutputState) void {
    const wl_out = state.wl_output;
    const res = state.resource;
    const version = res.getVersion();
    // logical_position: the output's origin in the global layout. This
    // server has one output at the origin (the whole canvas layout).
    res.sendLogicalPosition(0, 0);
    // logical_size: the mode size divided by the scale (logical pixels).
    // Round down like wlroots output_handle_done's logical_size
    // (wlr_xdg_output_v1.c:81-87).
    const scale: u32 = @intFromFloat(wl_out.output.scale);
    const w: i32 = @divTrunc(wl_out.output.width, @as(i32, @intCast(scale)));
    const h: i32 = @divTrunc(wl_out.output.height, @as(i32, @intCast(scale)));
    res.sendLogicalSize(w, h);
    if (version >= 2) {
        res.sendName(wl_out.name);
        res.sendDescription(wl_out.description);
    }
    res.sendDone();
}

/// The wl_output died: destroy this zxdg_output (the client must not
/// keep using it — its wl_output is gone).
fn onWlOutputDestroy(listener: *wire.Listener(*output_mod.Output), output: *output_mod.Output) void {
    _ = output;
    const state: *XdgOutputState = @fieldParentPtr("output_destroy_listener", listener);
    state.resource.destroy();
}

fn stateRequest(
    res: *server.zxdg.OutputV1,
    request: server.zxdg.OutputV1.Request,
    state: *XdgOutputState,
) void {
    _ = state;
    switch (request) {
        .destroy => res.destroy(),
    }
}

fn stateDestroy(res: *server.zxdg.OutputV1, state: *XdgOutputState) void {
    _ = res;
    state.output_destroy_listener.link.remove();
    const allocator = state.allocator;
    allocator.destroy(state);
}

/// Inert zxdg_output (foreign/dead wl_output): no events ever arrive,
/// the only request (destroy) is a no-op that just frees the resource.
fn deadHandler(
    res: *server.zxdg.OutputV1,
    request: server.zxdg.OutputV1.Request,
    data: ?*XdgOutputState,
) void {
    _ = data;
    switch (request) {
        .destroy => res.destroy(),
    }
}
