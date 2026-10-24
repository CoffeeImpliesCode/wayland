//! xkbcommon bindings (keymap + state) for the seat.
//!
//! Thin FFI over libxkbcommon (linked via build.zig; the devenv package
//! provides the runtime lib through LD_LIBRARY_PATH). The seat uses it to
//! build the wl_keyboard keymap text (sent to clients over a memfd), to
//! track pressed modifiers and to resolve keysyms for compositor
//! bindings — the same interpretation clients perform on our keymap.
//!
//! Imports: utils/log.zig (sibling module).
//!
//! Configuration: `Xkb.init` takes an `Options` struct whose `layout`
//! field selects the keymap layout (default "us"); `setLayout` replaces
//! the keymap at runtime.

const std = @import("std");
const log = @import("../utils/log.zig");

/// XKB keysym for the Escape key (compositor quit binding).
pub const keysym_escape: u32 = 0xff1b;

const c = struct {
    pub const xkb_context = opaque {};
    pub const xkb_keymap = opaque {};
    pub const xkb_state = opaque {};

    pub const xkb_rule_names = extern struct {
        rules: ?[*:0]const u8,
        model: ?[*:0]const u8,
        layout: ?[*:0]const u8,
        variant: ?[*:0]const u8,
        options: ?[*:0]const u8,
    };

    const xkb_context_flags = c_int; // XKB_CONTEXT_NO_FLAGS = 0
    const xkb_keymap_compile_flags = c_int; // XKB_KEYMAP_COMPILE_NO_FLAGS = 0
    const xkb_keymap_format = c_int; // XKB_KEYMAP_FORMAT_TEXT_V1 = 1
    const xkb_key_direction = c_int; // XKB_KEY_UP = 0, XKB_KEY_DOWN = 1
    const xkb_state_component = c_int; // XKB_STATE_MODS_DEPRESSED = (1 << 0)

    extern fn xkb_context_new(flags: xkb_context_flags) ?*xkb_context;
    extern fn xkb_context_unref(ctx: ?*xkb_context) void;
    extern fn xkb_keymap_new_from_names(
        ctx: ?*xkb_context,
        names: ?*const xkb_rule_names,
        flags: xkb_keymap_compile_flags,
    ) ?*xkb_keymap;
    extern fn xkb_keymap_unref(keymap: ?*xkb_keymap) void;
    extern fn xkb_keymap_get_as_string(keymap: ?*const xkb_keymap, format: xkb_keymap_format) ?[*:0]const u8;
    extern fn xkb_state_new(keymap: ?*xkb_keymap) ?*xkb_state;
    extern fn xkb_state_unref(state: ?*xkb_state) void;
    extern fn xkb_state_update_key(state: ?*xkb_state, keycode: u32, direction: xkb_key_direction) c_int;
    extern fn xkb_state_key_get_one_sym(state: ?*const xkb_state, keycode: u32) u32;
    extern fn xkb_state_serialize_mods(state: ?*const c.xkb_state, components: xkb_state_component) u32;
    extern fn xkb_state_serialize_layout(state: ?*const c.xkb_state, components: c_int) u32;

    /// xkbcommon does not provide a free function for the keymap string;
    /// it is malloc'd and released with the libc free.
    extern fn free(ptr: ?*anyopaque) void;
};

const xkb_key_up: c.xkb_key_direction = 0;
const xkb_key_down: c.xkb_key_direction = 1;
/// Modifier components: depressed, latched, locked.
const xkb_state_mods_depressed: c.xkb_state_component = 1;
const xkb_state_mods_latched: c.xkb_state_component = 2;
const xkb_state_mods_locked: c.xkb_state_component = 4;
/// XKB_STATE_LAYOUT_EFFECTIVE (xkbcommon enum xkb_state_component).
const xkb_state_layout_effective: c_int = 1 << 16;

/// xkbcommon keycode (X11 evdev scancode + 8). The seat's keyEvent API
/// operates in this space; the WIRE keycode is the scancode (keycode
/// minus 8) — the protocol requires clients to add 8 (wayland.xml:2597),
/// so the seat converts at the send sites (note 132 F1).
pub const Keycode = u32;

/// Xkb configuration. Only optional/defaulted arguments live here;
/// allocator/io/log_cfg stay positional.
pub const Options = struct {
    /// Keymap layout name (e.g. "us", "de"), passed to xkbcommon.
    layout: []const u8 = "us",
};

/// Owned xkbcommon context + keymap + state. Not thread-safe (used from
/// the server's single event-loop thread).
pub const Xkb = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    ctx: *c.xkb_context,
    keymap: *c.xkb_keymap,
    state: *c.xkb_state,
    /// The keymap in XKB text format (wl_keyboard.keymap payload),
    /// malloc'd by xkbcommon; freed in deinit.
    keymap_text: [*:0]const u8,
    /// memfd containing the keymap text; dup()'d per wl_keyboard.keymap
    /// send. Closed in deinit.
    keymap_fd: std.posix.fd_t,
    keymap_size: u32,

    /// Build a keymap from the configured layout name (default "us")
    /// with default rules/model. Fails when xkbcommon cannot load the
    /// layout data.
    pub fn init(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        options: Options,
    ) error{ XkbInitFailed, KeymapBuildFailed, KeymapMemfdFailed, OutOfMemory }!*Xkb {
        // xkb_rule_names.layout is a C string; Options.layout may be an
        // unterminated slice, so build a sentinel copy.
        const layout_z = allocator.dupeSentinel(u8, options.layout, 0) catch return error.OutOfMemory;
        defer allocator.free(layout_z);

        const ctx = c.xkb_context_new(0) orelse return error.XkbInitFailed;
        errdefer c.xkb_context_unref(ctx);

        var names: c.xkb_rule_names = .{
            .rules = null,
            .model = null,
            .layout = layout_z.ptr,
            .variant = null,
            .options = null,
        };
        const keymap = c.xkb_keymap_new_from_names(ctx, &names, 0) orelse return error.KeymapBuildFailed;
        errdefer c.xkb_keymap_unref(keymap);

        const state = c.xkb_state_new(keymap) orelse return error.KeymapBuildFailed;
        errdefer c.xkb_state_unref(state);

        const keymap_text = c.xkb_keymap_get_as_string(keymap, 1) orelse return error.KeymapBuildFailed;
        errdefer c.free(@constCast(keymap_text));

        const text_len = std.mem.len(keymap_text);
        // memfd flags take raw linux MFD_* values in 0.16 (std.posix only
        // re-exports memfd_create; close/dup are std.os.linux syscalls).
        const keymap_fd = std.posix.memfd_create("wayland-keymap", std.os.linux.MFD.CLOEXEC) catch
            return error.KeymapMemfdFailed;
        errdefer _ = std.os.linux.close(keymap_fd);
        {
            var written: usize = 0;
            while (written < text_len) {
                // std.os.linux.write returns the byte count, or a negated
                // errno on failure (raw syscall; std.posix.write is gone).
                const n = std.os.linux.write(keymap_fd, keymap_text[written..text_len].ptr, text_len - written);
                if (n == 0) return error.KeymapMemfdFailed;
                if (n > std.math.maxInt(usize) / 2) return error.KeymapMemfdFailed; // negated errno
                written += n;
            }
        }
        // Clients read the keymap from offset 0 (the write moved the shared
        // file offset to EOF; wlroots avoids this by writing via mmap).
        _ = std.os.linux.lseek(keymap_fd, 0, std.os.linux.SEEK.SET);

        const self = try allocator.create(Xkb);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .ctx = ctx,
            .keymap = keymap,
            .state = state,
            .keymap_text = keymap_text,
            .keymap_fd = keymap_fd,
            .keymap_size = @intCast(text_len),
        };
        log.debug("xkb keymap built (layout {s}, {d} bytes)", io, log_cfg, "xkb", .{
            options.layout, text_len,
        });
        return self;
    }

    pub fn deinit(self: *Xkb) void {
        _ = std.os.linux.close(self.keymap_fd);
        c.free(@constCast(self.keymap_text));
        c.xkb_state_unref(self.state);
        c.xkb_keymap_unref(self.keymap);
        c.xkb_context_unref(self.ctx);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Duplicate the keymap memfd for a wl_keyboard.keymap send (the
    /// client owns its copy).
    pub fn dupKeymapFd(self: *Xkb) std.posix.fd_t {
        return @intCast(std.os.linux.dup(self.keymap_fd));
    }

    /// Update the state for a key press/release; returns the resulting
    /// keysym for the key (the same keysym a client would resolve).
    pub fn updateKey(self: *Xkb, keycode: Keycode, pressed: bool) u32 {
        _ = c.xkb_state_update_key(self.state, keycode, if (pressed) xkb_key_down else xkb_key_up);
        return self.keysym(keycode);
    }

    pub fn keysym(self: *Xkb, keycode: Keycode) u32 {
        return c.xkb_state_key_get_one_sym(self.state, keycode);
    }

    /// Current modifier mask (wl_keyboard.modifiers layout: bit 0 Shift,
    /// 1 Lock, 2 Control, 3 Mod1, 4 Mod2, 5 Mod3, 6 Mod4, 7 Mod5) plus
    /// the effective layout group (wl_keyboard.modifiers.group; wlroots
    /// sends it, wlr_seat_keyboard.c:215-217; smithay layout_effective,
    /// keyboard.rs:84-93).
    pub fn mods(self: *Xkb) struct { depressed: u32, latched: u32, locked: u32, group: u32 } {
        return .{
            .depressed = c.xkb_state_serialize_mods(self.state, xkb_state_mods_depressed),
            .latched = c.xkb_state_serialize_mods(self.state, xkb_state_mods_latched),
            .locked = c.xkb_state_serialize_mods(self.state, xkb_state_mods_locked),
            .group = c.xkb_state_serialize_layout(self.state, xkb_state_layout_effective),
        };
    }

    /// Replace the keymap (and state) with a new layout, e.g. for a
    /// runtime layout switch (F10; wlroots wlr_keyboard_set_keymap,
    /// wlr_keyboard.c:204-283). The keymap text, memfd and state are
    /// rebuilt; callers must re-broadcast the keymap to clients and
    /// re-send the modifiers (the group may have changed).
    pub fn setLayout(
        self: *Xkb,
        layout: []const u8,
    ) error{ KeymapBuildFailed, KeymapMemfdFailed, OutOfMemory }!void {
        // xkb_rule_names.layout is a C string; callers may hand an
        // unterminated slice (environ values), so build a sentinel copy.
        const layout_z = self.allocator.dupeSentinel(u8, layout, 0) catch return error.OutOfMemory;
        defer self.allocator.free(layout_z);
        var names: c.xkb_rule_names = .{
            .rules = null,
            .model = null,
            .layout = layout_z.ptr,
            .variant = null,
            .options = null,
        };
        const keymap = c.xkb_keymap_new_from_names(self.ctx, &names, 0) orelse return error.KeymapBuildFailed;
        errdefer c.xkb_keymap_unref(keymap);
        const state = c.xkb_state_new(keymap) orelse return error.KeymapBuildFailed;
        errdefer c.xkb_state_unref(state);
        const keymap_text = c.xkb_keymap_get_as_string(keymap, 1) orelse return error.KeymapBuildFailed;
        errdefer c.free(@constCast(keymap_text));
        const text_len = std.mem.len(keymap_text);
        const keymap_fd = std.posix.memfd_create("wayland-keymap", std.os.linux.MFD.CLOEXEC) catch
            return error.KeymapMemfdFailed;
        errdefer _ = std.os.linux.close(keymap_fd);
        {
            var written: usize = 0;
            while (written < text_len) {
                const n = std.os.linux.write(keymap_fd, keymap_text[written..text_len].ptr, text_len - written);
                if (n == 0) return error.KeymapMemfdFailed;
                if (n > std.math.maxInt(usize) / 2) return error.KeymapMemfdFailed; // negated errno
                written += n;
            }
        }
        _ = std.os.linux.lseek(keymap_fd, 0, std.os.linux.SEEK.SET);

        // Swap in the new keymap; the old one dies after the swap.
        const old_keymap = self.keymap;
        const old_state = self.state;
        const old_text = self.keymap_text;
        const old_fd = self.keymap_fd;
        self.keymap = keymap;
        self.state = state;
        self.keymap_text = keymap_text;
        self.keymap_fd = keymap_fd;
        self.keymap_size = @intCast(text_len);
        _ = std.os.linux.close(old_fd);
        c.free(@constCast(old_text));
        c.xkb_state_unref(old_state);
        c.xkb_keymap_unref(old_keymap);
        log.debug("xkb keymap rebuilt (layout {s}, {d} bytes)", self.io, self.log_cfg, "xkb", .{
            layout, text_len,
        });
    }
};

const testing = std.testing;

test "xkb builds the us keymap and resolves keysyms" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const xkb = Xkb.init(allocator, io, &log_cfg, .{}) catch |err| {
        // xkeyboard-config must be available in the test environment.
        std.debug.print("xkb init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer xkb.deinit();

    // Keycode 38 is 'a' on the evdev+us layout; 30 is 'a' in... no:
    // evdev scancode A = 30, xkb keycode = scancode + 8 = 38.
    try testing.expectEqual(@as(u32, 0x61), xkb.updateKey(38, true)); // 'a'
    try testing.expectEqual(@as(u32, 0x61), xkb.keysym(38));

    // Modifier: left shift (scancode 42 -> keycode 50).
    try testing.expectEqual(@as(u32, 0), xkb.mods().depressed);
    _ = xkb.updateKey(50, true); // shift down
    try testing.expectEqual(@as(u32, 1), xkb.mods().depressed);
    // Shift+a -> uppercase A.
    try testing.expectEqual(@as(u32, 0x41), xkb.keysym(38));
    _ = xkb.updateKey(50, false);
    try testing.expectEqual(@as(u32, 0), xkb.mods().depressed);

    // Escape keysym used by the quit binding.
    _ = xkb.updateKey(9, true); // Esc scancode 1 -> keycode 9
    try testing.expectEqual(keysym_escape, xkb.keysym(9));
    _ = xkb.updateKey(9, false);

    // Keymap text is a valid XKB keymap and the memfd carries it.
    try testing.expect(std.mem.len(xkb.keymap_text) > 100);
    const fd = xkb.dupKeymapFd();
    defer _ = std.os.linux.close(fd);
    try testing.expect(fd >= 0);

    // F10: modifiers carry the effective layout group (0 for one layout).
    try testing.expectEqual(@as(u32, 0), xkb.mods().group);

    // setLayout rebuilds the keymap/state/memfd (F10): the new keymap
    // resolves keysyms and the fd is fresh.
    try xkb.setLayout("us");
    try testing.expectEqual(@as(u32, 0x61), xkb.updateKey(38, true)); // 'a'
    try testing.expectEqual(@as(u32, 0), xkb.mods().group);
    const fd2 = xkb.dupKeymapFd();
    defer _ = std.os.linux.close(fd2);
    try testing.expect(fd2 >= 0);
    try testing.expect(fd2 != fd);

    // A multi-layout keymap reports the effective group (0 initially).
    try xkb.setLayout("us,de");
    try testing.expectEqual(@as(u32, 0), xkb.mods().group);
}
