//! Cursor rendering helper (compositor/cursor.zig): everything the seat's
//! pointer needs to draw a cursor — the client cursor surface
//! (wl_pointer.set_cursor), the fallback texture, the scene nodes, the
//! position and the damage footprints. The compositor keeps the policy:
//! per-output visibility and WHEN to repaint (the cursor itself only
//! moves/redraws on demand).
//!
//! The cursor is a scene subtree of two non-pickable nodes under the
//! scene root: a fallback rect node (shown when no client cursor surface
//! is set) and a buffer node showing the client cursor surface's current
//! texture (the surface wins when one is set and its buffer can be
//! imported). update() re-appends both nodes to the root each frame so
//! the cursor always draws above every surface (wlroots keeps the cursor
//! as a separate plane; here the scene tree keeps the stacking).
//!
//! The client cursor surface is resolved from the seat's
//! cursor_surface_resource (a wire resource, may belong to any client)
//! into the compositor's surface list. Its pixels are imported into a
//! renderer texture; the import is redone only when the surface changed
//! (the seat's cursor_surface signal) or its buffer changed (a commit) —
//! an unchanged buffer's pixels are identical, so keeping the texture is
//! exact and avoids a per-frame import+destroy.
//!
//! The fallback texture is a 16x16 classic left_ptr arrow (white body,
//! black outline) so the cursor is visible over the canvas and the
//! terminal; the old solid square was nearly invisible. The rest is
//! transparent (alpha 0), so the over-blend leaves the background.
//!
//! Imports: ../utils/*, ../core/*, ../scene/*, ../renderer/*,
//! ../buffers/*, compositor/* (sibling modules).

const std = @import("std");
const geom = @import("../utils/geom.zig");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const display_mod = @import("../core/display.zig");
const scene_mod = @import("../scene/scene.zig");
const camera_mod = @import("../scene/camera.zig");
const canvas_mod = @import("../renderer/canvas.zig");
const pixman_mod = @import("../renderer/pixman.zig");
const renderer_mod = @import("../renderer/renderer.zig");
const texture_mod = @import("../renderer/texture.zig");
const buffer_mod = @import("../buffers/buffer.zig");
const compositor_mod = @import("compositor.zig");
const surface_mod = @import("surface.zig");
const seat_mod = @import("seat.zig");

const Scene = scene_mod.Scene;
const SceneNode = scene_mod.SceneNode;
const Texture = texture_mod.Texture;
const Rect = geom.Rect;
const Allocator = std.mem.Allocator;

/// Fallback cursor size (px): a cursor_size² arrow when no client
/// cursor surface is set.
pub const cursor_size: i32 = 16;
/// Fallback cursor color (straight alpha RGBA).
const cursor_color = [4]f32{ 0.95, 0.95, 0.95, 1.0 };

/// The seat's pointer-driven cursor: owns the scene nodes, the client
/// cursor surface texture and the fallback texture, and tracks the
/// damage footprints (old + new rects) across updates.
pub const Cursor = struct {
    allocator: Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    scene: *Scene,
    compositor: *compositor_mod.Compositor,
    seat: *seat_mod.Seat,
    renderer: *renderer_mod.Renderer,

    /// The fallback rect node (cursor_size², cursor_color). Pure state
    /// since M4: the canvas pass draws the fallback TEXTURE, not the
    /// scene rect; the node still carries the footprint rect.
    rect_node: *SceneNode,
    /// The client cursor surface's buffer node (texture + dst size).
    buf_node: *SceneNode,
    /// The client cursor surface's texture, imported from the surface's
    /// current buffer (null while the fallback is shown). Owned here and
    /// freed on replace/deinit.
    texture: ?*Texture = null,
    /// The fallback arrow texture, created lazily on first draw.
    fallback_texture: ?*Texture = null,
    /// The buffer `texture` was imported from. Re-import only when this
    /// changes (or the surface_dirty flag is set): an unchanged buffer
    /// has identical pixels.
    texture_buffer: ?*buffer_mod.Buffer = null,
    /// wl_pointer.set_cursor applied since the last update (the seat's
    /// cursor_surface signal): force a re-import on the next update.
    surface_dirty: bool = false,
    /// Seat listener for the cursor_surface signal.
    cursor_surface_listener: wire.Listener(*seat_mod.Seat),

    /// Old+new footprints across one update: the compositor damages both
    /// (a partial upload must repaint the old and the new position) and
    /// restores both from the persisted base on a hover repaint.
    pub const Footprints = struct {
        old: [2]?Rect,
        new: [2]?Rect,
    };

    pub fn create(
        allocator: Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        scene: *Scene,
        compositor: *compositor_mod.Compositor,
        seat: *seat_mod.Seat,
        renderer: *renderer_mod.Renderer,
    ) error{OutOfMemory}!*Cursor {
        const self = try allocator.create(Cursor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .scene = scene,
            .compositor = compositor,
            .seat = seat,
            .renderer = renderer,
            // SAFETY: assigned below before the seat can emit.
            .rect_node = undefined,
            .buf_node = undefined,
            .cursor_surface_listener = wire.Listener(*seat_mod.Seat).init(onSeatCursorSurface),
        };
        // The cursor nodes: a fallback rect plus a buffer node for the
        // client cursor surface. Both non-pickable (the pointer never
        // targets the cursor) and disabled until the first update.
        const rect = try SceneNode.create(allocator, scene.root, .rect);
        errdefer rect.destroy(allocator);
        rect.pickable = false;
        rect.kind.rect.width = cursor_size;
        rect.kind.rect.height = cursor_size;
        rect.kind.rect.color = cursor_color;
        rect.enable(false);
        self.rect_node = rect;
        const buf = try SceneNode.create(allocator, scene.root, .buffer);
        errdefer buf.destroy(allocator);
        buf.pickable = false;
        buf.enable(false);
        self.buf_node = buf;
        seat.events.cursor_surface.add(&self.cursor_surface_listener);
        return self;
    }

    /// Destroy the cursor: detach the seat listener, free the textures
    /// and the scene nodes. The nodes detach from the scene root, so a
    /// scene that outlives the cursor draws nothing stale; the scene's
    /// own deinit destroys the rest of the tree.
    pub fn deinit(self: *Cursor) void {
        if (self.cursor_surface_listener.link.prev != null) self.cursor_surface_listener.link.remove();
        if (self.texture) |t| t.destroy();
        if (self.fallback_texture) |t| t.destroy();
        self.rect_node.destroy(self.allocator);
        self.buf_node.destroy(self.allocator);
        self.allocator.destroy(self);
    }

    /// Sync the cursor with the seat: capture the previous footprints,
    /// re-append the nodes to the scene root (keep them on top), resolve
    /// + import the client cursor surface (or fall back to the rect),
    /// position at the pointer minus the hotspot. The returned
    /// Footprints carry the OLD rects (captured before the move) and the
    /// NEW rects; the compositor damages/restores both.
    pub fn update(self: *Cursor) Footprints {
        const old = self.footprints();
        const seat = self.seat;
        const x = seat.pointer_x;
        const y = seat.pointer_y;

        // Keep the cursor on top of every surface: re-append both nodes
        // to the scene root (appendChild reparents, moving them to draw
        // last).
        self.scene.root.appendChild(self.allocator, self.rect_node) catch |err| {
            log.warn("cursor z-order failed: {s}", self.io, self.log_cfg, "cursor", .{@errorName(err)});
        };
        self.scene.root.appendChild(self.allocator, self.buf_node) catch |err| {
            log.warn("cursor z-order failed: {s}", self.io, self.log_cfg, "cursor", .{@errorName(err)});
        };

        // Resolve the client cursor surface (wl_pointer.set_cursor) to
        // the compositor surface; the surface may belong to any client.
        // Import its current buffer's pixels as the cursor texture —
        // only when the surface changed (the seat signal) or the buffer
        // changed (a commit): an unchanged buffer's pixels are the same,
        // so the current texture stays exact.
        var surface_texture: ?*Texture = null;
        if (seat.cursorSurface()) |res| {
            for (self.compositor.surfaces.items) |s| {
                if (s.resource != res) continue;
                if (s.buffer) |buf| {
                    if (self.surface_dirty or self.texture_buffer != buf or self.texture == null) {
                        surface_texture = self.importSurfaceTexture(s) orelse null;
                        if (surface_texture != null) self.texture_buffer = buf;
                    } else {
                        surface_texture = self.texture;
                    }
                }
                break;
            }
        }
        self.surface_dirty = false;
        if (self.texture) |t| {
            if (t != surface_texture) t.destroy();
            self.texture = null;
        }
        if (surface_texture) |tex| {
            self.texture = tex;
            const node = self.buf_node;
            node.kind.buffer.texture = tex;
            node.kind.buffer.dst_width = tex.width;
            node.kind.buffer.dst_height = tex.height;
            node.x = x - seat.cursor_hotspot_x;
            node.y = y - seat.cursor_hotspot_y;
            node.enable(true);
            self.rect_node.enable(false);
        } else {
            self.texture_buffer = null;
            self.rect_node.x = x;
            self.rect_node.y = y;
            self.rect_node.enable(true);
            self.buf_node.enable(false);
        }
        return .{ .old = old, .new = self.footprints() };
    }

    /// The cursor nodes' absolute rects (fallback rect + client cursor
    /// buffer), or null for a disabled node.
    pub fn footprints(self: *Cursor) [2]?Rect {
        var out: [2]?Rect = .{ null, null };
        inline for (.{ self.rect_node, self.buf_node }, 0..) |node, i| {
            if (node.enabled) out[i] = node.absolutePosition();
        }
        return out;
    }

    /// Draw the cursor into `fb` at the pointer's current position
    /// (identity camera, constant size): the client cursor texture wins
    /// when one is set, else the fallback arrow texture.
    pub fn draw(self: *Cursor, fb: *pixman_mod.Framebuffer) void {
        const identity: camera_mod.Camera = .{
            .center_x = @as(f64, @floatFromInt(fb.width)) / 2.0,
            .center_y = @as(f64, @floatFromInt(fb.height)) / 2.0,
            .zoom = 1,
            .rotation = 0,
            .screen_w = @floatFromInt(fb.width),
            .screen_h = @floatFromInt(fb.height),
        };
        var cursor_items: [1]canvas_mod.CanvasItem = undefined;
        if (self.texture) |tex| {
            const seat = self.seat;
            cursor_items[0] = .{
                .texture = tex,
                .world_x = @floatFromInt(seat.pointer_x - seat.cursor_hotspot_x),
                .world_y = @floatFromInt(seat.pointer_y - seat.cursor_hotspot_y),
                .world_w = @floatFromInt(tex.width),
                .world_h = @floatFromInt(tex.height),
                .opacity = 1.0,
            };
        } else {
            const tex = self.ensureFallbackTexture() orelse return;
            cursor_items[0] = .{
                .texture = tex,
                .world_x = @floatFromInt(self.seat.pointer_x),
                .world_y = @floatFromInt(self.seat.pointer_y),
                .world_w = @floatFromInt(cursor_size),
                .world_h = @floatFromInt(cursor_size),
                .opacity = 1.0,
            };
        }
        canvas_mod.render(self.allocator, fb, &identity, &cursor_items, 1);
    }

    /// The fallback cursor's texture: a cursor_size² left_ptr arrow
    /// (white body, black outline), created lazily on first draw and
    /// owned here.
    fn ensureFallbackTexture(self: *Cursor) ?*Texture {
        if (self.fallback_texture) |t| return t;
        const n: usize = @intCast(cursor_size * cursor_size);
        var pixels: [n * 4]u8 = undefined;
        // The classic left_ptr arrow, 16x16: '1' = body (white), '2' =
        // outline (black), '.' = transparent. Hotspot is the top-left
        // tip.
        const shape = [_][]const u8{
            "2...............",
            "22..............",
            "212.............",
            "2112............",
            "21112...........",
            "211112..........",
            "2111112.........",
            "21111112........",
            "211111112.......",
            "2111111112......",
            "21111111112.....",
            "211111111112....",
            "2111111111112...",
            "21..21111112....",
            "2...21111112....",
            "....211112......",
        };
        var y: usize = 0;
        while (y < shape.len and y < @as(usize, @intCast(cursor_size))) : (y += 1) {
            var x: usize = 0;
            while (x < shape[y].len and x < @as(usize, @intCast(cursor_size))) : (x += 1) {
                const off = (y * @as(usize, @intCast(cursor_size)) + x) * 4;
                switch (shape[y][x]) {
                    '2' => pixels[off..][0..4].* = .{ 0, 0, 0, 255 },
                    '1' => pixels[off..][0..4].* = .{ 255, 255, 255, 255 },
                    else => pixels[off..][0..4].* = .{ 0, 0, 0, 0 },
                }
            }
        }
        const tex = pixman_mod.PixmanRenderer.importMemory(
            self.renderer,
            cursor_size,
            cursor_size,
            cursor_size * 4,
            &pixels,
        ) catch |err| {
            log.err("cursor fallback texture import failed: {s}", self.io, self.log_cfg, "cursor", .{
                @errorName(err),
            });
            return null;
        };
        self.fallback_texture = tex;
        return tex;
    }

    /// Import the surface's current buffer into a renderer texture via
    /// the shm pixel path (same import the surface nodes use). Null when
    /// the buffer is not shm-readable (e.g. a dmabuf cursor) — the
    /// fallback shows instead.
    fn importSurfaceTexture(self: *Cursor, surface: *surface_mod.Surface) ?*Texture {
        const buf = surface.buffer orelse return null;
        const get_shm = buf.impl.get_shm orelse return null;
        const shm = get_shm(buf) orelse return null;
        const begin = buf.impl.begin_data_ptr_access orelse return null;
        const end = buf.impl.end_data_ptr_access orelse return null;
        const pixels = begin(buf) catch return null;
        defer end(buf);
        const ptr = pixels orelse return null;
        const stride = wire.shm.Buffer.getStride(shm);
        const byte_len = @as(usize, @intCast(stride)) * @as(usize, @intCast(buf.height));
        return pixman_mod.PixmanRenderer.importMemory(
            self.renderer,
            buf.width,
            buf.height,
            stride,
            ptr[0..byte_len],
        ) catch |err| {
            log.err("cursor texture import failed: {s} ({d}x{d} stride={d})", self.io, self.log_cfg, "cursor", .{
                @errorName(err), buf.width, buf.height, stride,
            });
            return null;
        };
    }
};

/// wl_pointer.set_cursor applied: the next update re-imports the client
/// cursor surface (a new surface or hotspot may be pending).
fn onSeatCursorSurface(listener: *wire.Listener(*seat_mod.Seat), _: *seat_mod.Seat) void {
    const self: *Cursor = @fieldParentPtr("cursor_surface_listener", listener);
    self.surface_dirty = true;
}

const testing = std.testing;

/// Minimal cursor test server: display + compositor + seat + scene +
/// renderer + Cursor. No wire clients; the seat's pointer state is
/// driven directly (pointerMotion / cursorSurface fields).
const TestCursorServer = struct {
    allocator: Allocator,
    io: std.Io,
    log_cfg: log.Config,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    seat: ?*seat_mod.Seat = null,
    scene: ?*Scene = null,
    renderer: ?*renderer_mod.Renderer = null,
    cursor: ?*Cursor = null,

    fn init(allocator: Allocator) !*TestCursorServer {
        const ts = try allocator.create(TestCursorServer);
        ts.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
        };
        errdefer ts.deinit();
        ts.display = try display_mod.CompositorDisplay.init(allocator, &ts.io, &ts.log_cfg);
        ts.compositor = try compositor_mod.Compositor.init(allocator, &ts.io, &ts.log_cfg, ts.display.?);
        ts.seat = try seat_mod.Seat.init(allocator, &ts.io, &ts.log_cfg, ts.display.?, .{});
        ts.scene = try Scene.init(allocator, &ts.io, &ts.log_cfg);
        ts.renderer = try pixman_mod.PixmanRenderer.create(allocator, &ts.io, &ts.log_cfg);
        ts.cursor = try Cursor.create(
            allocator,
            &ts.io,
            &ts.log_cfg,
            ts.scene.?,
            ts.compositor.?,
            ts.seat.?,
            ts.renderer.?,
        );
        return ts;
    }

    fn deinit(ts: *TestCursorServer) void {
        if (ts.cursor) |c| c.deinit();
        if (ts.renderer) |r| r.destroy();
        if (ts.scene) |s| s.deinit();
        if (ts.seat) |s| s.deinit();
        if (ts.compositor) |c| c.deinit();
        if (ts.display) |d| d.deinit();
        const allocator = ts.allocator;
        allocator.destroy(ts);
    }
};

test "update positions the fallback rect at the pointer and tracks footprints" {
    const allocator = testing.allocator;
    const ts = TestCursorServer.init(allocator) catch |err| {
        std.debug.print("cursor test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();
    const cursor = ts.cursor.?;
    const seat = ts.seat.?;

    // No client cursor surface: the fallback rect follows the pointer.
    seat.pointerMotion(100, 50);
    const fp = cursor.update();
    // First update: nothing was drawn before (both nodes disabled).
    try testing.expect(fp.old[0] == null);
    try testing.expect(fp.old[1] == null);
    // New: the rect node at the pointer, the buffer node still off.
    const expected: Rect = .{ .x = 100, .y = 50, .width = cursor_size, .height = cursor_size };
    try testing.expectEqual(expected, fp.new[0].?);
    try testing.expect(fp.new[1] == null);
    try testing.expect(cursor.rect_node.enabled);
    try testing.expect(!cursor.buf_node.enabled);
    try testing.expectEqual(expected, cursor.footprints()[0].?);

    // The next update captures the previous footprints BEFORE moving.
    seat.pointerMotion(110, 60);
    const fp2 = cursor.update();
    try testing.expectEqual(fp.new[0].?, fp2.old[0].?);
    const expected2: Rect = .{ .x = 110, .y = 60, .width = cursor_size, .height = cursor_size };
    try testing.expectEqual(expected2, fp2.new[0].?);
    try testing.expect(fp2.old[1] == null);
    try testing.expect(fp2.new[1] == null);
}

test "draw renders the fallback arrow texture at the pointer" {
    const allocator = testing.allocator;
    const ts = TestCursorServer.init(allocator) catch |err| {
        std.debug.print("cursor test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();
    const cursor = ts.cursor.?;
    const seat = ts.seat.?;

    const fb = try pixman_mod.Framebuffer.create(allocator, 64, 64);
    defer fb.deinit();
    // Red base: the over-blend must leave it under the transparent
    // texels and replace it under the arrow's opaque ones.
    fb.fill(.{ 0, 0, 255, 255 });

    seat.pointerMotion(8, 8);
    _ = cursor.update();
    cursor.draw(fb);

    const stride: usize = @intCast(fb.stride);
    const at = struct {
        fn pixel(f: *pixman_mod.Framebuffer, s: usize, x: usize, y: usize) [4]u8 {
            return f.data[y * s + x * 4 ..][0..4].*;
        }
    }.pixel;
    // The arrow tip (hotspot): shape[0][0] = '2' (black outline).
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, at(fb, stride, 8, 8));
    // shape[2][1] = '1' (white body).
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(fb, stride, 9, 10));
    // shape[15][15] = '.' (transparent): the red base stays.
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(fb, stride, 23, 23));
    // Outside the 16x16 arrow: still the red base.
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(fb, stride, 40, 40));

    // The fallback texture is created lazily and owned by the cursor.
    try testing.expect(cursor.fallback_texture != null);
}

test "client cursor surface without an importable buffer falls back to the rect" {
    const allocator = testing.allocator;
    const ts = TestCursorServer.init(allocator) catch |err| {
        std.debug.print("cursor test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();
    const cursor = ts.cursor.?;
    const seat = ts.seat.?;

    // A real wl_surface (wire resource on a scratch server) set as the
    // client cursor; its buffer is a test fixture WITHOUT the shm pixel
    // path, so the import fails and the fallback rect stays (a dmabuf
    // cursor behaves the same today).
    var tw = try surface_mod.TestWire.init();
    defer tw.deinit();
    // TestWire.deinit destroys the client, which destroys the surface
    // (removing it from the compositor list); no explicit destroy here.
    const surface = try surface_mod.testSurface(allocator, &ts.io, &ts.log_cfg, ts.compositor.?, &tw);
    try ts.compositor.?.surfaces.append(allocator, surface);
    var buf: buffer_mod.Buffer = undefined;
    surface_mod.testBuffer(allocator, &buf);
    surface.buffer = &buf;

    seat.pointerMotion(20, 20);
    seat.cursor_surface_resource = surface.resource;
    seat.events.cursor_surface.emit(seat);
    const fp = cursor.update();

    // Unimportable: the fallback rect shows, the buffer node stays off.
    try testing.expect(cursor.texture == null);
    try testing.expect(cursor.rect_node.enabled);
    try testing.expect(!cursor.buf_node.enabled);
    const expected: Rect = .{ .x = 20, .y = 20, .width = cursor_size, .height = cursor_size };
    try testing.expectEqual(expected, fp.new[0].?);
    try testing.expect(fp.new[1] == null);

    // Idempotent: a second update with the same surface keeps the
    // fallback (the signal-driven re-import retries and fails again).
    seat.events.cursor_surface.emit(seat);
    const fp2 = cursor.update();
    try testing.expect(cursor.texture == null);
    try testing.expectEqual(expected, fp2.new[0].?);
    try testing.expectEqual(fp.new[0].?, fp2.old[0].?);

    // Clearing the cursor surface (set_cursor with null) also falls
    // back — the rect just follows the pointer.
    seat.cursor_surface_resource = null;
    seat.pointerMotion(30, 30);
    const fp3 = cursor.update();
    try testing.expect(cursor.texture == null);
    try testing.expectEqual(
        Rect{ .x = 30, .y = 30, .width = cursor_size, .height = cursor_size },
        fp3.new[0].?,
    );
}
