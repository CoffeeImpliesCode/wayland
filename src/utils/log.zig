//! Structured logging for the compositor library.
//!
//! The library is Io-generic: every logging call takes `io: *std.Io`
//! explicitly (zig 0.16 std.Io era). The compositor author passes the Io
//! implementation of their choice (std's, zio's, ...). No globals.

const std = @import("std");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn label(l: Level) []const u8 {
        return switch (l) {
            .err => "ERR",
            .warn => "WRN",
            .info => "INF",
            .debug => "DBG",
            .trace => "TRC",
        };
    }
};

/// Log filter: minimum level shown, per-tag override table.
pub const Config = struct {
    /// Minimum level emitted globally.
    min_level: Level = .info,
    /// Optional per-tag minimums ("compositor" -> .debug). Empty = all use min_level.
    tags: std.StringHashMapUnmanaged(Level) = .empty,

    pub fn levelFor(cfg: *const Config, tag: []const u8) Level {
        if (cfg.tags.get(tag)) |l| return l;
        return cfg.min_level;
    }
};

/// Emit a log line to stderr with a monotonic timestamp.
/// `tag` is a short module name, e.g. "compositor", "server".
pub fn log(
    comptime fmt: []const u8,
    io: *std.Io,
    cfg: *const Config,
    level: Level,
    tag: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(cfg.levelFor(tag))) return;

    const now_ns = std.Io.Clock.now(.awake, io.*).nanoseconds;
    const now_ms: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));

    var buf: [1024]u8 = undefined;
    // writerStreaming appends at the file offset (the positional `writer`
    // would pwrite each line at offset 0 on Io impls like zio's).
    var w = std.Io.File.stderr().writerStreaming(io.*, &buf);
    w.interface.print("[{d}.{d:0>3} {s} {s}] " ++ fmt ++ "\n", .{
        now_ms / 1000,
        now_ms % 1000,
        level.label(),
        tag,
    } ++ args) catch {
        // stderr is unavailable; there is no fallback sink, so drop the line.
        return;
    };
    w.interface.flush() catch {
        // stderr is unavailable; there is no fallback sink, so drop the line.
        return;
    };
}

pub fn err(comptime fmt: []const u8, io: *std.Io, cfg: *const Config, tag: []const u8, args: anytype) void {
    log(fmt, io, cfg, .err, tag, args);
}

pub fn warn(comptime fmt: []const u8, io: *std.Io, cfg: *const Config, tag: []const u8, args: anytype) void {
    log(fmt, io, cfg, .warn, tag, args);
}

pub fn info(comptime fmt: []const u8, io: *std.Io, cfg: *const Config, tag: []const u8, args: anytype) void {
    log(fmt, io, cfg, .info, tag, args);
}

pub fn debug(comptime fmt: []const u8, io: *std.Io, cfg: *const Config, tag: []const u8, args: anytype) void {
    log(fmt, io, cfg, .debug, tag, args);
}

pub fn trace(comptime fmt: []const u8, io: *std.Io, cfg: *const Config, tag: []const u8, args: anytype) void {
    log(fmt, io, cfg, .trace, tag, args);
}
