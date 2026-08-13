//! wp_presentation (stable presentation-time v2): presentation feedback
//! for wl_surfaces.
//!
//! One wp_presentation global per server. On bind, clock_id names the
//! presentation clock. `feedback` (getFeedback) creates a
//! wp_presentation_feedback object bound to a wl_surface; each feedback
//! delivers exactly one outcome — presented (after an output present) or
//! discarded (surface destroyed) — as a destructor event, then is gone.
//!
//! M2 scope: feedback lifecycle + timestamps from the monotonic io clock
//! (std.Io.Clock.now(.awake) = CLOCK_MONOTONIC on Linux). Deliberate
//! simplifications (documented at each site):
//! - presented flags are 0 (no VSYNC/HW guarantees in the headless/pixman
//!   path); the flags argument is plumbed through for the output backend
//!   and ZERO_COPY is cleared (the pixman composite is textured).
//! - seq comes from a per-output counter, not a hardware vblank counter
//!   (the real vblank seq awaits the output present event, note 135 F8).
//! - the feedback module listens to the surface's commit/destroy signals
//!   itself: a new commit supersedes an un-presented feedback, surface
//!   death discards (the compositor's own discard() call is redundant but
//!   harmless).
//!
//! Note: wp_presentation_feedback declares no destroy request (the
//! protocol only has the destructor events). Clients cannot destroy the
//! object over the wire; libwayland rejects any request on it. The
//! Feedback bookkeeping is freed by the resource destroy handler, which
//! runs when the server sends presented/discarded or when the client's
//! connection dies (libwayland destroys every resource of the client).
//!
//! Cross-module contract (types written by the M1 agents; do not drift):
//! - compositor/surface.zig: `Surface { resource: *server.wl.Surface,
//!   ... }`; the wl_surface wire resource user data is the *Surface.
//! - compositor/compositor.zig: `Compositor { surfaces:
//!   std.ArrayList(*Surface), ... }` (tests read it to find surfaces).
//! - core/display.zig: `CompositorDisplay.addGlobal(comptime T: type,
//!   comptime DataT: type, comptime bind, version: u32, data: DataT)
//!   !*wire.Global`.

const std = @import("std");
const wire = @import("core/wire.zig");
const log = @import("utils/log.zig");
const display_mod = @import("core/display.zig");
const compositor_mod = @import("compositor/compositor.zig");
const surface_mod = @import("compositor/surface.zig");
const output_mod = @import("output/output.zig");
const wl_output_mod = @import("output/wl_output.zig");

const protocol = @import("protocol");
const server = protocol.server;
const client = protocol.client;

const log_tag = "presentation";

const Surface = surface_mod.Surface;
const WlOutput = wl_output_mod.WlOutput;

/// The presentation clock named in the clock_id event. All timestamps use
/// std.Io.Clock.now(.awake), which is CLOCK_MONOTONIC on Linux (see
/// surface.zig's commit pipeline and utils/log.zig for the same clock).
/// The protocol requires clock_id to name exactly the clock the
/// timestamps come from; wlroots sends CLOCK_MONOTONIC too
/// (wlr_presentation_time.c:162). The generated bindings take the raw
/// POSIX clockid_t (u32, no enum — verified in wayland.zig
/// `sendClockId(_clk_id: u32)`), so the value comes from std.posix:
/// CLOCK_MONOTONIC = 1 on Linux.
const clock_id_monotonic: u32 = @intFromEnum(std.posix.CLOCK.MONOTONIC);

pub const presentation_version: u32 = server.wp.Presentation.generated_version;

pub const Presentation = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    display: *display_mod.CompositorDisplay,
    /// The wp_presentation global, for teardown.
    global: ?*wire.Global = null,
    /// All live feedback objects (one per outstanding request), in
    /// creation order. Entries are removed by the resource destroy
    /// handler, which also frees the Feedback.
    feedbacks: std.ArrayList(*Feedback),
    /// Per-output sequence counters backing presented seq_hi/lo
    /// (wlroots seq comes from the output's present event). Each output
    /// advances its own counter per present; all feedbacks presented on
    /// one output in one present share the value.
    output_seq: std.AutoHashMap(*output_mod.Output, u64),
    /// Fallback sequence counter for present() calls without an output
    /// (tests); keeps the per-output invariant when no output is known.
    seq_fallback: u64 = 0,
    /// Per-output presented-event state (one entry per output with a
    /// real present source). Created lazily on the first queued present;
    /// removed by the output's destroy listener.
    present_states: std.AutoHashMap(*output_mod.Output, *OutputPresentState),

    /// Register the wp_presentation global (version 2).
    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        display: *display_mod.CompositorDisplay,
    ) error{ OutOfMemory, GlobalCreateFailed }!*Presentation {
        const p = try allocator.create(Presentation);
        errdefer allocator.destroy(p);
        p.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .display = display,
            .global = null,
            .feedbacks = .empty,
            .output_seq = std.AutoHashMap(*output_mod.Output, u64).init(allocator),
            .seq_fallback = 0,
            .present_states = std.AutoHashMap(*output_mod.Output, *OutputPresentState).init(allocator),
        };
        errdefer p.feedbacks.deinit(allocator);
        errdefer p.output_seq.deinit();
        errdefer p.present_states.deinit();
        p.global = try display.addGlobal(
            server.wp.Presentation,
            *Presentation,
            bindPresentation,
            presentation_version,
            p,
        );
        log.info(
            "wp_presentation v{d} registered",
            io,
            log_cfg,
            log_tag,
            .{presentation_version},
        );
        return p;
    }

    pub fn deinit(p: *Presentation) void {
        const allocator = p.allocator;
        if (p.global) |g| g.remove();
        // Destroy outstanding feedback resources: each destroy handler
        // removes its bookkeeping from the list and frees it.
        while (p.feedbacks.items.len > 0) p.feedbacks.items[0].resource.destroy();
        // Per-output present state: detach the listeners from the still
        // live outputs' signals, then free. (Destroyed outputs already
        // removed their entries via the destroy listener.)
        var it = p.present_states.iterator();
        while (it.next()) |entry| {
            const st = entry.value_ptr.*;
            st.presented_listener.link.remove();
            st.destroy_listener.link.remove();
            allocator.destroy(st);
        }
        p.present_states.deinit();
        p.feedbacks.deinit(allocator);
        p.output_seq.deinit();
        allocator.destroy(p);
    }

    /// Client feedback request: create the feedback resource on the
    /// surface's client and track it. `version` is the bound
    /// wp_presentation version, `id` the new object id.
    pub fn getFeedback(p: *Presentation, surface: *Surface, version: u32, id: u32) void {
        // The surface's client is the requester (libwayland validates
        // object ids per client), so the feedback lives on that client.
        const client_wire = surface.resource.getClient();
        const resource = server.wp.PresentationFeedback.create(client_wire, version, id) catch {
            surface.resource.postNoMemory();
            return;
        };
        const fb = p.allocator.create(Feedback) catch {
            resource.destroy();
            surface.resource.postNoMemory();
            return;
        };
        fb.* = .{
            .resource = resource,
            .presentation = p,
            .surface = surface,
            .commit_listener = wire.Listener(*Surface).init(onFeedbackSurfaceCommit),
            .destroy_listener = wire.Listener(*Surface).init(onFeedbackSurfaceDestroy),
        };
        p.feedbacks.append(p.allocator, fb) catch {
            p.allocator.destroy(fb);
            resource.destroy();
            surface.resource.postNoMemory();
            return;
        };
        // Track the surface: a commit supersedes an un-presented feedback
        // (F9) and surface death discards it (F10) without compositor
        // cooperation.
        surface.events.commit.add(&fb.commit_listener);
        surface.events.destroy.add(&fb.destroy_listener);
        // Request-less resources get their user data as ?*anyopaque from
        // the generated bindings (unlike request-bearing ones, which pass
        // the typed data); the destroy handler casts it back.
        resource.setHandler(?*anyopaque, feedbackDestroy, fb);
        log.debug(
            "presentation feedback@{d} for wl_surface@{d}",
            p.io,
            p.log_cfg,
            log_tag,
            .{ id, surface.resource.getId() },
        );
    }

    /// The surface is gone (wl_surface destroyed): every feedback bound
    /// to it delivers discarded (destructor event) and is freed.
    pub fn discard(p: *Presentation, surface: *Surface) void {
        // Iterate backwards: each destroyed feedback removes itself from
        // the list (swapRemove) and is freed by its destroy handler.
        var i = p.feedbacks.items.len;
        while (i > 0) {
            i -= 1;
            const fb = p.feedbacks.items[i];
            if (fb.surface == surface) fb.resource.destroySendDiscarded();
        }
    }

    /// A frame was committed for an output and the surfaces drawn in it
    /// are known. Two delivery modes, selected by the output:
    ///
    /// - Real-present output (Output.emits_present, DRM/nested): every
    ///   committed feedback bound to a surface of this frame is queued on
    ///   the output with `commit_seq` (the output's commit sequence of
    ///   this frame) and delivered ONLY by the output's `presented`
    ///   event when its seq matches — the backend actually displayed the
    ///   frame (wlroots presentation_surface_queued_on_output +
    ///   commit_seq check, presentation_time.c:277-301). A frame that
    ///   never presents (dropped/superseded) is discarded, never
    ///   reported as presented. The timestamp, refresh and flags come
    ///   from the present event, not the commit.
    /// - Headless/raylib (no real display): delivered synchronously here,
    ///   as before — the timestamp is taken once from the monotonic io
    ///   clock, refresh_msec becomes the protocol refresh, the seq is
    ///   the output's own counter advancing per present.
    ///
    /// `wl_output` names the compositor's wl_output global for the
    /// output: each feedback's client receives a sync_output for its own
    /// wl_output resource before presented (wlroots presentation_time.c:
    /// 27-40). flags may carry WP_PRESENTATION_FEEDBACK_KIND_*; ZERO_COPY
    /// is cleared because the pixman path composites (textured) rather
    /// than scanning out directly (wlroots clears it for textured
    /// feedback, presentation_time.c:296-298).
    pub fn present(
        p: *Presentation,
        presented: []const *Surface,
        wl_output: ?*WlOutput,
        commit_seq: u64,
        refresh_msec: u32,
        flags: u32,
    ) void {
        const out = if (wl_output) |wo| wo.output else null;
        if (out != null and out.?.emits_present) {
            queueForPresent(p, presented, out.?, wl_output, commit_seq);
            return;
        }

        const now_ns: u64 = @intCast(std.Io.Clock.now(.awake, p.io.*).nanoseconds);
        const tv_sec: u64 = now_ns / std.time.ns_per_s;
        const tv_nsec: u64 = now_ns % std.time.ns_per_s;
        const refresh_ns: u64 = @as(u64, refresh_msec) * std.time.ns_per_ms;
        const seq = nextSeq(p, out);
        var kind: server.wp.PresentationFeedback.Kind = @bitCast(flags);
        kind.zero_copy = false;
        // Iterate backwards: each presented feedback destroys its own
        // resource inside destroySendPresented (the destructor event),
        // whose destroy handler removes + frees it.
        var i = p.feedbacks.items.len;
        while (i > 0) {
            i -= 1;
            const fb = p.feedbacks.items[i];
            if (std.mem.indexOfScalar(*Surface, presented, fb.surface) == null) continue;
            if (wl_output) |wo| sendSyncOutput(wo, fb);
            fb.resource.destroySendPresented(
                @truncate(tv_sec >> 32),
                @truncate(tv_sec),
                @truncate(tv_nsec),
                @truncate(refresh_ns),
                @truncate(seq >> 32),
                @truncate(seq),
                kind,
            );
        }
        log.debug(
            "presented {d} surface(s), {d} feedback(s) pending",
            p.io,
            p.log_cfg,
            log_tag,
            .{ presented.len, p.feedbacks.items.len },
        );
    }
};

/// Per-output presented-event state: the listeners wired to the output's
/// signals (attached once per output, on the first queued present) and
/// the back-pointer to run delivery.
const OutputPresentState = struct {
    presentation: *Presentation,
    /// The output's presented event: deliver seq-matched queued feedbacks.
    presented_listener: wire.Listener(*output_mod.Output.PresentEvent),
    /// The output's destroy event: drop this output's state (the signal
    /// lists die with the output; the listeners never fire again).
    destroy_listener: wire.Listener(*output_mod.Output),
};

/// Attach the output's presented listener (once per output): feedback
/// delivery rides the real present event for real-display backends. On
/// allocation failure there is no listener, so the frame's feedbacks stay
/// queued until a later commit supersedes them — never falsely presented
/// (a catastrophic-memory path, matching nextSeq's handling).
fn ensureOutputPresentState(p: *Presentation, out: *output_mod.Output) void {
    if (p.present_states.contains(out)) return;
    const st = p.allocator.create(OutputPresentState) catch return;
    st.* = .{
        .presentation = p,
        .presented_listener = wire.Listener(*output_mod.Output.PresentEvent).init(onOutputPresented),
        .destroy_listener = wire.Listener(*output_mod.Output).init(onOutputDestroyed),
    };
    p.present_states.put(out, st) catch {
        p.allocator.destroy(st);
        return;
    };
    out.events.presented.add(&st.presented_listener);
    out.events.destroy.add(&st.destroy_listener);
}

/// Real-present path: attach this frame's committed feedbacks to the
/// output's next present (wlroots presentation_surface_queued_on_output).
/// The seq is the output's commit sequence of this frame — main.zig
/// passes out.commit_seq right after commitState.
fn queueForPresent(
    p: *Presentation,
    presented: []const *Surface,
    out: *output_mod.Output,
    wl_output: ?*WlOutput,
    commit_seq: u64,
) void {
    ensureOutputPresentState(p, out);
    var i = p.feedbacks.items.len;
    while (i > 0) {
        i -= 1;
        const fb = p.feedbacks.items[i];
        if (!fb.committed) continue;
        if (std.mem.indexOfScalar(*Surface, presented, fb.surface) == null) continue;
        fb.queued_output = out;
        fb.wl_output = wl_output;
        fb.commit_seq = commit_seq;
    }
    log.debug(
        "queued {d} surface(s) for output present seq={d}",
        p.io,
        p.log_cfg,
        log_tag,
        .{ presented.len, commit_seq },
    );
}

/// The output displayed a frame: deliver every feedback queued for it
/// whose commit seq matches the presented frame, with the presented
/// event's timestamp, flags and refresh (wlroots presentation_time.c:
/// feedback_handle_output_present, 311-339). A feedback whose frame was
/// NOT this present (seq mismatch — the output displayed another frame)
/// is left waiting: it is never presented for the wrong frame, and is
/// destroyed only by its surface's next commit (supersede, the synced
/// move), the surface dying, or the output dying — a dropped frame is
/// never reported as presented.
fn deliverPresented(p: *Presentation, ev: *output_mod.Output.PresentEvent) void {
    const out = ev.output;
    var i = p.feedbacks.items.len;
    while (i > 0) {
        i -= 1;
        const fb = p.feedbacks.items[i];
        if (fb.queued_output != out) continue;
        if (fb.commit_seq != ev.seq) continue;
        var kind: server.wp.PresentationFeedback.Kind = @bitCast(ev.flags);
        kind.zero_copy = false;
        if (fb.wl_output) |wo| sendSyncOutput(wo, fb);
        fb.resource.destroySendPresented(
            @truncate(ev.when_ns / std.time.ns_per_s >> 32),
            @truncate(ev.when_ns / std.time.ns_per_s),
            @truncate(ev.when_ns % std.time.ns_per_s),
            @truncate(ev.refresh_ns),
            @truncate(ev.seq >> 32),
            @truncate(ev.seq),
            kind,
        );
    }
    log.debug(
        "output present seq={d}: delivered seq-matched feedbacks, {d} pending",
        p.io,
        p.log_cfg,
        log_tag,
        .{ ev.seq, p.feedbacks.items.len },
    );
}

fn onOutputPresented(
    listener: *wire.Listener(*output_mod.Output.PresentEvent),
    ev: *output_mod.Output.PresentEvent,
) void {
    const st: *OutputPresentState = @fieldParentPtr("presented_listener", listener);
    deliverPresented(st.presentation, ev);
}

/// The output died: its queued feedbacks can never present — discard
/// them (wlroots feedback_handle_output_destroy, presentation_time.c:
/// 301-308), then drop the present state. Freeing the listener struct
/// inside its own notify is safe — the emit cursor has moved past it
/// (same pattern as wl_output's onOutputDestroy). The presented listener
/// is still linked into the dying signal's list, which is never
/// traversed again.
fn onOutputDestroyed(listener: *wire.Listener(*output_mod.Output), out: *output_mod.Output) void {
    const st: *OutputPresentState = @fieldParentPtr("destroy_listener", listener);
    const p = st.presentation;
    // Iterate backwards: each destroyed feedback removes itself from the
    // list (swapRemove) and is freed by its destroy handler.
    var i = p.feedbacks.items.len;
    while (i > 0) {
        i -= 1;
        const fb = p.feedbacks.items[i];
        if (fb.queued_output == out) fb.resource.destroySendDiscarded();
    }
    _ = p.present_states.remove(out);
    p.allocator.destroy(st);
}

/// Per-output sequence: the output's counter, advanced once per present
/// on it. Falls back to a global counter when no output is given. On
/// allocation failure the counter cannot persist and the seq may repeat —
/// a catastrophic-memory path.
fn nextSeq(p: *Presentation, output: ?*output_mod.Output) u64 {
    if (output) |out| {
        const prev = p.output_seq.get(out) orelse 0;
        const next = prev + 1;
        p.output_seq.put(out, next) catch |err| {
            log.debug(
                "output seq put failed: {s}",
                p.io,
                p.log_cfg,
                log_tag,
                .{@errorName(err)},
            );
        };
        return next;
    }
    p.seq_fallback += 1;
    return p.seq_fallback;
}

/// Send sync_output for every wl_output resource the feedback's client
/// bound on the presented output (wlroots feedback_resource_send_presented,
/// presentation_time.c:27-40).
fn sendSyncOutput(wl_output: *WlOutput, fb: *Feedback) void {
    const cli = fb.resource.getClient();
    for (wl_output.resources.items) |res| {
        if (res.getClient() != cli) continue;
        fb.resource.sendSyncOutput(res);
    }
}

/// The surface committed again before this feedback's frame presented:
/// the feedback is superseded and discarded (wlroots synced-state move
/// destroys the previous current feedback, presentation_time.c:73-81;
/// smithay merge_into, mod.rs:323-337). A feedback created since the
/// last commit (not yet committed itself) survives and becomes current.
fn onFeedbackSurfaceCommit(listener: *wire.Listener(*Surface), _: *Surface) void {
    const fb: *Feedback = @fieldParentPtr("commit_listener", listener);
    if (fb.committed) {
        discardFeedback(fb);
    } else {
        fb.committed = true;
    }
}

/// The surface died: every feedback bound to it is discarded (wlroots
/// addon destroy + synced finish, presentation_time.c:58-76). Idempotent
/// with the compositor's own discard() call.
fn onFeedbackSurfaceDestroy(listener: *wire.Listener(*Surface), _: *Surface) void {
    const fb: *Feedback = @fieldParentPtr("destroy_listener", listener);
    discardFeedback(fb);
}

/// Send the discarded destructor event; the resource destroy handler
/// removes the bookkeeping and frees it.
fn discardFeedback(fb: *Feedback) void {
    fb.resource.destroySendDiscarded();
}

/// One outstanding wp_presentation_feedback. Lives until the resource is
/// destroyed (presented/discarded sent, or client connection teardown).
pub const Feedback = struct {
    /// The wp_presentation_feedback wire resource; its destroy handler
    /// (set in getFeedback) receives this struct as user data.
    resource: *server.wp.PresentationFeedback,
    /// Owning presentation, to reach the tracked list on destroy.
    presentation: *Presentation,
    /// The surface the feedback was requested for.
    surface: *Surface,
    /// True once the surface committed with this feedback outstanding:
    /// the feedback describes that committed frame and awaits its
    /// present. A further commit supersedes it (discard).
    committed: bool = false,
    /// Real-present path (outputs with a presented event source): the
    /// output this feedback was queued on, awaiting the seq-matched
    /// present. Null while unqueued or on the synthetic (headless) path.
    queued_output: ?*output_mod.Output = null,
    /// The compositor's wl_output of the queued frame, for sync_output
    /// at delivery (wlroots presentation_surface_queued_on_output).
    wl_output: ?*WlOutput = null,
    /// The output's commit sequence number the queued feedback rode on:
    /// delivered only by the presented event carrying this seq
    /// (presentation_time.c:277-301).
    commit_seq: u64 = 0,
    /// Surface commit listener: supersede an un-presented feedback when
    /// the surface commits again.
    commit_listener: wire.Listener(*Surface),
    /// Surface destroy listener: discard the feedback when the surface
    /// dies (wlroots synced finish, presentation_time.c:58-76).
    destroy_listener: wire.Listener(*Surface),
};

/// A client bound the wp_presentation global.
fn bindPresentation(client_wire: *wire.Client, p: *Presentation, version: u32, id: u32) void {
    const resource = server.wp.Presentation.create(client_wire, version, id) catch {
        client_wire.postNoMemory();
        return;
    };
    resource.setHandler(*Presentation, handleRequest, handleDestroy, p);
    // Name the presentation clock (CLOCK_MONOTONIC, see above).
    resource.sendClockId(clock_id_monotonic);
}

fn handleRequest(resource: *server.wp.Presentation, request: server.wp.Presentation.Request, p: *Presentation) void {
    switch (request) {
        .feedback => |r| {
            const surface = surfaceFromResource(r.surface) orelse {
                // Unreachable in this library (every wl_surface carries
                // its Surface wrapper); be defensive rather than crash.
                log.warn("feedback request for untracked wl_surface ignored", p.io, p.log_cfg, log_tag, .{});
                return;
            };
            p.getFeedback(surface, resource.getVersion(), r.callback);
        },
        // Destructor requests are dispatched to the handler; the handler
        // must destroy the resource (handleDestroy then runs).
        .destroy => resource.destroy(),
    }
}

fn handleDestroy(resource: *server.wp.Presentation, p: *Presentation) void {
    _ = resource;
    _ = p;
    // The wp_presentation object is a per-client view of the global; the
    // Presentation itself outlives its client resources. Outstanding
    // feedbacks are unaffected (protocol: "Existing objects created by
    // this object are not affected").
}

/// The wl_surface wire resource user data is its *Surface wrapper.
fn surfaceFromResource(resource: *server.wl.Surface) ?*Surface {
    const ud = resource.getUserData() orelse return null;
    return @ptrCast(@alignCast(ud));
}

/// Resource destroyed (presented/discarded sent, server teardown, or the
/// client's connection died): detach the surface listeners, stop tracking
/// and free the bookkeeping. The surface is still alive here: its destroy
/// signal always fires before the Surface is freed, and it is the only
/// path that discards this feedback while the surface dies.
fn feedbackDestroy(resource: *server.wp.PresentationFeedback, data: ?*anyopaque) void {
    _ = resource;
    const fb: *Feedback = @ptrCast(@alignCast(data.?));
    const p = fb.presentation;
    fb.commit_listener.link.remove();
    fb.destroy_listener.link.remove();
    const idx = std.mem.indexOfScalar(*Feedback, p.feedbacks.items, fb) orelse return;
    _ = p.feedbacks.swapRemove(idx);
    p.allocator.destroy(fb);
}

// ---------------------------------------------------------------------------
// Tests: socketpair roundtrip harness (same pattern as shell/xdg.zig).
// ---------------------------------------------------------------------------

const posix = std.posix;
const backend_mod = @import("backend/backend.zig");

const RegistryCapture = struct {
    compositor_name: ?u32 = null,
    presentation_name: ?u32 = null,
    output_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *RegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wp_presentation")) {
                    data.presentation_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_output")) {
                    data.output_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

const PresentationEvents = struct {
    clock_id: ?u32 = null,

    fn listener(
        presentation: *client.wp.Presentation,
        event: client.wp.Presentation.Event,
        data: *PresentationEvents,
    ) void {
        _ = presentation;
        switch (event) {
            .clock_id => |e| data.clock_id = e.clk_id,
        }
    }
};

const FeedbackEvents = struct {
    presented: bool = false,
    discarded: bool = false,
    sync_output_count: usize = 0,
    tv_sec: u64 = 0,
    tv_nsec: u32 = 0,
    refresh: u32 = 0,
    seq: u64 = 0,
    flags: u32 = 0,

    fn listener(
        feedback: *client.wp.PresentationFeedback,
        event: client.wp.PresentationFeedback.Event,
        data: *FeedbackEvents,
    ) void {
        _ = feedback;
        switch (event) {
            .sync_output => data.sync_output_count += 1,
            .presented => |e| {
                data.presented = true;
                data.tv_sec = (@as(u64, e.tv_sec_hi) << 32) | e.tv_sec_lo;
                data.tv_nsec = e.tv_nsec;
                data.refresh = e.refresh;
                data.seq = (@as(u64, e.seq_hi) << 32) | e.seq_lo;
                data.flags = @bitCast(e.flags);
            },
            .discarded => data.discarded = true,
        }
    }
};

/// A full compositor + presentation + in-memory client, for wire
/// roundtrips. The bind round is NOT pumped here: tests attach their
/// listeners (e.g. for clock_id) before the first pump.
const FakeBackendImpl = struct {
    fn start(_: *backend_mod.Backend) error{BackendFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_backend_impl: backend_mod.Backend.Impl = .{
    .start = FakeBackendImpl.start,
    .destroy = FakeBackendImpl.destroy,
};

const FakeOutputImpl = struct {
    fn testState(_: *output_mod.Output, _: *const output_mod.Output.State) error{InvalidState}!void {}
    fn commit(_: *output_mod.Output, _: *const output_mod.Output.State) error{CommitFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_output_impl: output_mod.Output.Impl = .{
    .@"test" = FakeOutputImpl.testState,
    .commit = FakeOutputImpl.commit,
    .destroy = FakeOutputImpl.destroy,
};

const TestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    presentation: ?*Presentation = null,
    backend: ?*backend_mod.Backend = null,
    output: ?*output_mod.Output = null,
    wl_output: ?*WlOutput = null,
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    wl_compositor: ?*client.wl.Compositor = null,
    wp_presentation: ?*client.wp.Presentation = null,
    wl_output_client: ?*client.wl.Output = null,
    /// Dummy listener data for the wl_output proxy: the bind response
    /// events must be consumed or libwayland-client aborts on the
    /// listener-less opcode (the sync_output test asserts the feedback's
    /// sync_output event, not the wl_output state dump).
    output_listener_data: u8 = 0,

    /// Heap-allocated (the `io` pointer must outlive the stack frame; the
    /// display, compositor and presentation all store it).
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
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.compositor) |c| c.deinit();
        ts.presentation = try Presentation.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        errdefer if (ts.presentation) |p| p.deinit();

        // One fake output for sync_output: the presentation module needs
        // the compositor's wl_output global to name the output per client.
        ts.backend = try backend_mod.Backend.init(allocator, &ts.io, &ts.log_cfg, &fake_backend_impl, undefined);
        errdefer if (ts.backend) |b| b.destroy();
        ts.output = try output_mod.Output.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.backend.?,
            &fake_output_impl,
            undefined,
            .{ .width = 1920, .height = 1080, .refresh_msec = 16 },
        );
        errdefer if (ts.output) |o| o.destroy();
        // Freed by onOutputDestroy when the output is destroyed.
        ts.wl_output = try WlOutput.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.display.?,
            ts.output.?,
            "WL-1",
            "wayland debug output",
        );

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
        if (capture.compositor_name == null or capture.presentation_name == null or capture.output_name == null) {
            return error.GlobalMissing;
        }

        // Round 2: bind wl_compositor and wp_presentation. No pump here:
        // the clock_id event must reach a listener attached by the test.
        ts.wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
        ts.wp_presentation = try registry.bind(capture.presentation_name.?, client.wp.Presentation, 2);
        ts.wl_output_client = try registry.bind(capture.output_name.?, client.wl.Output, 4);
        ts.wl_output_client.?.setListener(*u8, ignoreOutputEvents, &ts.output_listener_data);
        return ts;
    }

    /// Consume the wl_output bind-time state dump.
    fn ignoreOutputEvents(_: *client.wl.Output, _: client.wl.Output.Event, _: *u8) void {}

    fn deinit(ts: *TestServer) void {
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
        if (ts.presentation) |p| p.deinit();
        // Destroying the output frees the WlOutput via its destroy listener.
        if (ts.output) |o| o.destroy();
        if (ts.backend) |b| b.destroy();
        if (ts.compositor) |c| c.deinit();
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

test "bind wp_presentation sends clock_id" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    var events: PresentationEvents = .{};
    ts.wp_presentation.?.setListener(*PresentationEvents, PresentationEvents.listener, &events);
    try ts.pump();

    // The presentation clock is CLOCK_MONOTONIC, the clock the library
    // timestamps with (std.Io.Clock.now(.awake)).
    try std.testing.expectEqual(@as(?u32, @intFromEnum(std.posix.CLOCK.MONOTONIC)), events.clock_id);
}

test "get_feedback then present delivers presented" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_feedback = try ts.wp_presentation.?.feedback(wl_surface);
    var fe: FeedbackEvents = .{};
    c_feedback.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe);
    try ts.pump();

    // The server created the feedback resource and tracked it.
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);
    const surface = ts.compositor.?.surfaces.items[0];

    // Present with a 60 Hz refresh (16.67 ms -> 16,666,667 ns). Capture
    // the clock window: the presented timestamp must fall inside it.
    const t0_ns: u64 = @intCast(std.Io.Clock.now(.awake, ts.io).nanoseconds);
    ts.presentation.?.present(&[_]*Surface{surface}, null, 0, 16, 0);
    const t1_ns: u64 = @intCast(std.Io.Clock.now(.awake, ts.io).nanoseconds);
    try ts.pump();

    try std.testing.expect(fe.presented);
    try std.testing.expect(!fe.discarded);
    // Plausible tv: seconds part reasonable, nsec in range, timestamp
    // within the present() clock window.
    try std.testing.expect(fe.tv_sec > 0);
    try std.testing.expect(fe.tv_nsec < std.time.ns_per_s);
    const tv_ns = fe.tv_sec * std.time.ns_per_s + fe.tv_nsec;
    try std.testing.expect(tv_ns >= t0_ns);
    try std.testing.expect(tv_ns <= t1_ns);
    // refresh: 16 ms -> ns; seq: first present; flags: 0 for M2.
    try std.testing.expectEqual(@as(u32, 16 * std.time.ns_per_ms), fe.refresh);
    try std.testing.expectEqual(@as(u64, 1), fe.seq);
    try std.testing.expectEqual(@as(u32, 0), fe.flags);

    // The presented event is a destructor: the bookkeeping is gone.
    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.feedbacks.items.len);
}

test "present only affects the listed surfaces" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_a = try ts.wl_compositor.?.createSurface();
    const wl_b = try ts.wl_compositor.?.createSurface();
    const c_fb_a = try ts.wp_presentation.?.feedback(wl_a);
    const c_fb_b = try ts.wp_presentation.?.feedback(wl_b);
    var fe_a: FeedbackEvents = .{};
    var fe_b: FeedbackEvents = .{};
    c_fb_a.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe_a);
    c_fb_b.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe_b);
    try ts.pump();

    const surface_a = ts.compositor.?.surfaces.items[0];
    const surface_b = ts.compositor.?.surfaces.items[1];
    try std.testing.expectEqual(@as(usize, 2), ts.presentation.?.feedbacks.items.len);

    ts.presentation.?.present(&[_]*Surface{surface_a}, null, 0, 16, 0);
    try ts.pump();

    try std.testing.expect(fe_a.presented);
    try std.testing.expect(!fe_b.presented);
    try std.testing.expect(!fe_b.discarded);
    // Surface B's feedback is still pending.
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);
    try std.testing.expectEqual(surface_b, ts.presentation.?.feedbacks.items[0].surface);

    // A later present covers it too (seq advances per present).
    ts.presentation.?.present(&[_]*Surface{surface_b}, null, 0, 16, 0);
    try ts.pump();
    try std.testing.expect(fe_b.presented);
    try std.testing.expectEqual(@as(u64, 2), fe_b.seq);
    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.feedbacks.items.len);
}

test "surface destroy discards its feedbacks" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_a = try ts.wl_compositor.?.createSurface();
    const wl_b = try ts.wl_compositor.?.createSurface();
    const c_fb_a = try ts.wp_presentation.?.feedback(wl_a);
    const c_fb_b = try ts.wp_presentation.?.feedback(wl_b);
    var fe_a: FeedbackEvents = .{};
    var fe_b: FeedbackEvents = .{};
    c_fb_a.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe_a);
    c_fb_b.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe_b);
    try ts.pump();

    const surface_a = ts.compositor.?.surfaces.items[0];

    // The surface died: the integration calls discard() for it.
    ts.presentation.?.discard(surface_a);
    try ts.pump();

    try std.testing.expect(fe_a.discarded);
    try std.testing.expect(!fe_a.presented);
    try std.testing.expect(!fe_b.discarded);
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);

    // The surface itself then goes away over the wire; no crash, no leak.
    wl_a.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.compositor.?.surfaces.items.len);
}

test "feedback dies with the client connection (no leak)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_feedback = try ts.wp_presentation.?.feedback(wl_surface);
    var fe: FeedbackEvents = .{};
    c_feedback.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);

    // wp_presentation_feedback has no destroy request; the client gives
    // up by dropping the proxy and disconnecting. libwayland then
    // destroys every resource of the client, firing the feedback destroy
    // handler (remove + free).
    c_feedback.destroy();
    ts.c_display.?.disconnect();
    // Server processes the EOF and tears the client down.
    try ts.display.?.getServer().getEventLoop().dispatch(0);
    ts.display.?.flushClients();

    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.feedbacks.items.len);
    // The server destroyed its client object; forget it for deinit.
    ts.client = null;
    ts.c_display = null;
}

test "deinit with outstanding feedbacks is safe" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    _ = try ts.wp_presentation.?.feedback(wl_surface);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);

    // Teardown with the feedback still outstanding: deinit destroys the
    // resource (handler removes + frees) — leak-checked allocator proves
    // no leak.
    ts.presentation.?.deinit();
    ts.presentation = null;
}

test "presented feedback carries sync_output for the client's wl_output" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_feedback = try ts.wp_presentation.?.feedback(wl_surface);
    var fe: FeedbackEvents = .{};
    c_feedback.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe);
    try ts.pump();

    const surface = ts.compositor.?.surfaces.items[0];

    // Present with the compositor's wl_output: the feedback's client (the
    // same in-memory client, which bound wl_output) gets one sync_output
    // before presented (wlroots presentation_time.c:27-40).
    ts.presentation.?.present(&[_]*Surface{surface}, ts.wl_output, 0, 16, 0);
    try ts.pump();

    try std.testing.expect(fe.presented);
    try std.testing.expectEqual(@as(usize, 1), fe.sync_output_count);

    // A second present on the same output advances the OUTPUT's counter
    // (per-output seq), not a global one.
    const wl_b = try ts.wl_compositor.?.createSurface();
    const c_fb_b = try ts.wp_presentation.?.feedback(wl_b);
    var fe_b: FeedbackEvents = .{};
    c_fb_b.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe_b);
    try ts.pump();
    const surface_b = ts.compositor.?.surfaces.items[1];
    ts.presentation.?.present(&[_]*Surface{surface_b}, ts.wl_output, 0, 16, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(u64, 2), fe_b.seq);
}

test "commit supersedes an un-presented feedback" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_fb1 = try ts.wp_presentation.?.feedback(wl_surface);
    var fe1: FeedbackEvents = .{};
    c_fb1.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe1);
    try ts.pump();
    const surface = ts.compositor.?.surfaces.items[0];

    // First commit: fb1 becomes the committed (current) feedback.
    wl_surface.commit();
    try ts.pump();

    // A second feedback, then another commit: fb1 is superseded and
    // discarded (wlroots synced-state move, presentation_time.c:73-81);
    // fb2 survives and awaits its present.
    const c_fb2 = try ts.wp_presentation.?.feedback(wl_surface);
    var fe2: FeedbackEvents = .{};
    c_fb2.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe2);
    try ts.pump();
    wl_surface.commit();
    try ts.pump();

    try std.testing.expect(fe1.discarded);
    try std.testing.expect(!fe1.presented);
    try std.testing.expect(!fe2.discarded);
    try std.testing.expect(!fe2.presented);
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);

    // The surviving feedback presents normally.
    ts.presentation.?.present(&[_]*Surface{surface}, null, 0, 16, 0);
    try ts.pump();
    try std.testing.expect(fe2.presented);
    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.feedbacks.items.len);
}

test "surface destroy auto-discards its feedbacks (no manual discard)" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();

    const wl_a = try ts.wl_compositor.?.createSurface();
    const wl_b = try ts.wl_compositor.?.createSurface();
    const c_fb_a = try ts.wp_presentation.?.feedback(wl_a);
    const c_fb_b = try ts.wp_presentation.?.feedback(wl_b);
    var fe_a: FeedbackEvents = .{};
    var fe_b: FeedbackEvents = .{};
    c_fb_a.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe_a);
    c_fb_b.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe_b);
    try ts.pump();

    // The surface dies over the wire: the presentation module's own
    // destroy listener discards its feedback — no compositor call.
    wl_a.destroy();
    try ts.pump();

    try std.testing.expect(fe_a.discarded);
    try std.testing.expect(!fe_a.presented);
    try std.testing.expect(!fe_b.discarded);
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);
    try std.testing.expectEqual(@as(usize, 1), ts.compositor.?.surfaces.items.len);
}

test "real-present output: feedbacks deliver only on the seq-matched presented event" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    // The DRM/nested backends set this: the output's presented event is
    // the real present source.
    ts.output.?.emits_present = true;

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_fb1 = try ts.wp_presentation.?.feedback(wl_surface);
    var fe1: FeedbackEvents = .{};
    c_fb1.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe1);
    try ts.pump();
    const surface = ts.compositor.?.surfaces.items[0];

    // Frame 1: commit + present (output seq 1). Queued, NOT delivered:
    // the output has not presented yet (no synthesized timestamp).
    wl_surface.commit();
    try ts.pump();
    ts.presentation.?.present(&[_]*Surface{surface}, ts.wl_output, 1, 16, 0);
    try ts.pump();
    try std.testing.expect(!fe1.presented);
    try std.testing.expect(!fe1.discarded);
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);

    // Frame 2: a second feedback; the commit supersedes fb1 (its frame
    // was never presented), fb2 becomes current.
    const c_fb2 = try ts.wp_presentation.?.feedback(wl_surface);
    var fe2: FeedbackEvents = .{};
    c_fb2.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe2);
    try ts.pump();
    wl_surface.commit();
    try ts.pump();
    ts.presentation.?.present(&[_]*Surface{surface}, ts.wl_output, 2, 16, 0);
    try ts.pump();
    try std.testing.expect(fe1.discarded);
    try std.testing.expect(!fe1.presented);

    // The backend displays frame 2 (page flip / parent frame done) with
    // ITS flags, refresh and scanout time: only fb2 delivers, carrying
    // the presented event's data — not the commit-time synthesis.
    const when_ns: u64 = 1234 * std.time.ns_per_s + 567_000_000;
    ts.output.?.firePresented(2, 0x1 | 0x2 | 0x4, 8_333_333, when_ns);
    try ts.pump();

    try std.testing.expect(fe2.presented);
    try std.testing.expect(!fe2.discarded);
    try std.testing.expectEqual(@as(u64, 1234), fe2.tv_sec);
    try std.testing.expectEqual(@as(u32, 567_000_000), fe2.tv_nsec);
    try std.testing.expectEqual(@as(u32, 8_333_333), fe2.refresh);
    try std.testing.expectEqual(@as(u64, 2), fe2.seq);
    // The backend's flags pass through with ZERO_COPY cleared (0x8): the
    // pixman composite is textured, not zero-copy scanned out.
    try std.testing.expectEqual(@as(u32, 0x1 | 0x2 | 0x4), fe2.flags);
    // The feedback's client bound wl_output: one sync_output precedes
    // presented (wlroots presentation_time.c:27-40).
    try std.testing.expectEqual(@as(usize, 1), fe2.sync_output_count);
    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.feedbacks.items.len);
}

test "real-present output: a dropped frame's feedback is never presented" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    ts.output.?.emits_present = true;

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_fb = try ts.wp_presentation.?.feedback(wl_surface);
    var fe: FeedbackEvents = .{};
    c_fb.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe);
    try ts.pump();
    const surface = ts.compositor.?.surfaces.items[0];

    // Commit + present (seq 1): queued, awaiting the real present.
    wl_surface.commit();
    try ts.pump();
    ts.presentation.?.present(&[_]*Surface{surface}, ts.wl_output, 1, 16, 0);
    try ts.pump();
    try std.testing.expect(!fe.presented);
    try std.testing.expect(!fe.discarded);

    // The frame never presents (dropped): the next commit supersedes the
    // queued feedback — discarded, never reported as presented.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(fe.discarded);
    try std.testing.expect(!fe.presented);
    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.feedbacks.items.len);
}

test "real-present output: a newer present leaves the older feedback waiting, never presented" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    ts.output.?.emits_present = true;

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_fb = try ts.wp_presentation.?.feedback(wl_surface);
    var fe: FeedbackEvents = .{};
    c_fb.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe);
    try ts.pump();
    const surface = ts.compositor.?.surfaces.items[0];

    // Commit + present (seq 1); then the output presents seq 2 — the
    // displayed frame is NOT the one the feedback rode on. wlroots
    // behavior (presentation_time.c:311-339): the feedback is left
    // waiting — never presented for the wrong frame, not discarded
    // either. The next surface commit supersedes it (synced move).
    wl_surface.commit();
    try ts.pump();
    ts.presentation.?.present(&[_]*Surface{surface}, ts.wl_output, 1, 16, 0);
    try ts.pump();

    ts.output.?.firePresented(2, 0x2 | 0x4, 16_666_667, 2 * std.time.ns_per_s);
    try ts.pump();
    try std.testing.expect(!fe.presented);
    try std.testing.expect(!fe.discarded);
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.feedbacks.items.len);

    // A matching present would deliver it; a newer commit supersedes.
    wl_surface.commit();
    try ts.pump();
    try std.testing.expect(fe.discarded);
    try std.testing.expect(!fe.presented);
    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.feedbacks.items.len);
}

test "real-present output teardown: output destroy drops the present state" {
    const allocator = std.testing.allocator;
    var ts = try TestServer.init(allocator);
    defer ts.deinit();
    ts.output.?.emits_present = true;

    const wl_surface = try ts.wl_compositor.?.createSurface();
    const c_fb = try ts.wp_presentation.?.feedback(wl_surface);
    var fe: FeedbackEvents = .{};
    c_fb.setListener(*FeedbackEvents, FeedbackEvents.listener, &fe);
    try ts.pump();
    const surface = ts.compositor.?.surfaces.items[0];

    // Queue on the output: attaches the presented + destroy listeners.
    wl_surface.commit();
    try ts.pump();
    ts.presentation.?.present(&[_]*Surface{surface}, ts.wl_output, 1, 16, 0);
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 1), ts.presentation.?.present_states.count());

    // The output dies (deinit order in TestServer: presentation first —
    // so destroy the output manually here, then re-init the server state
    // so deinit skips it). The destroy listener removes the state AND
    // discards the queued feedback — its frame can never present now
    // (wlroots feedback_handle_output_destroy).
    const out = ts.output.?;
    ts.output = null;
    ts.wl_output = null;
    out.destroy();
    try ts.pump();
    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.present_states.count());
    try std.testing.expectEqual(@as(usize, 0), ts.presentation.?.feedbacks.items.len);
    try std.testing.expect(fe.discarded);
    try std.testing.expect(!fe.presented);
}
