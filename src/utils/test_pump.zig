//! The one definition of a test-server roundtrip.
//!
//! Every module's `TestServer` carries a private `pump` that drives a
//! single socket roundtrip: flush the client, dispatch the server's event
//! loop once so the request is handled, then flush the server's replies
//! back to the client. That core sequence was duplicated verbatim across a
//! dozen files, where it could drift independently. Harnesses with more than
//! one client keep their own extra flushes and poll loops and call this for
//! the common part.
//!
//! Test-only. It IS reachable from the shipped library graph, because
//! `src/root.zig` re-exports it as `wayland.utils.test_pump`: the server
//! module's path root is `src/server/`, so `src/server/*` cannot import
//! `src/utils/*` directly and reaches this through the library module like
//! every other library file. Nothing on a production path calls it.

const display_mod = @import("../core/display.zig");
const protocol = @import("protocol");
const client = protocol.client;

/// Drive one roundtrip: flush the client, dispatch the server's event loop
/// once, flush the server's replies back to the clients.
///
/// `c_display` may be null: a client that has not connected yet, or one a
/// protocol error already dropped. The server half always runs, so an event
/// the SERVER initiated still reaches its client.
///
/// `timeout_ms` is the event loop's blocking budget; 0 never blocks, which is
/// what every existing harness passes.
///
/// Errors: `ClientFlushFailed` when a client's outgoing buffer would not
/// flush, plus whatever the server's event loop reports from `dispatch`
/// (`posix.UnexpectedError` on an epoll failure). The set is inferred rather
/// than spelled out so it cannot drift from `dispatch`.
pub fn roundtrip(
    c_display: ?*client.wl.Display,
    display: *display_mod.CompositorDisplay,
    timeout_ms: c_int,
) !void {
    try dispatchOnce(c_display, display, timeout_ms);
    flushServers(display);
}

/// Flush the client and dispatch the server's event loop once, WITHOUT
/// pushing the server's replies out yet.
///
/// A harness that must emit server-side events BETWEEN the dispatch and the
/// flush uses this plus `flushServers` instead of `roundtrip`, so those
/// events reach the client in the same roundtrip they used to. The seat's
/// per-batch `wl_pointer.frame` is the case that matters — `Seat.pointerFrame`
/// sends a real frame event, so moving it after the flush would delay it by
/// one roundtrip.
pub fn dispatchOnce(
    c_display: ?*client.wl.Display,
    display: *display_mod.CompositorDisplay,
    timeout_ms: c_int,
) !void {
    if (c_display) |d| {
        if (d.flush() != .SUCCESS) return error.ClientFlushFailed;
    }
    try display.dispatch(timeout_ms);
}

/// Push the server's buffered replies to every client.
pub fn flushServers(display: *display_mod.CompositorDisplay) void {
    display.flushClients();
}
