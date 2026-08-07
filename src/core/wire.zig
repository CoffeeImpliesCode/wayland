//! Wire-layer re-export.
//!
//! zig-wayland's generated server core (FFI over libwayland-server).
//! The library builds on this layer, mirroring wlroots on libwayland-server.
//! Everything above this file is this library's own code.

const protocol = @import("protocol");

pub const wl = protocol.server.wl;

pub const Server = wl.Server;
pub const Client = wl.Client;
pub const Global = wl.Global;
pub const Resource = wl.Resource;
pub const EventLoop = wl.EventLoop;
pub const EventSource = wl.EventSource;
pub const ProtocolLogger = wl.ProtocolLogger;
pub const shm = wl.shm;
pub const list = wl.list;
pub const Credentials = wl.Credentials;

pub fn Listener(comptime T: type) type {
    return wl.Listener(T);
}

pub fn Signal(comptime T: type) type {
    return wl.Signal(T);
}
