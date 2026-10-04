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

const client = @import("protocol").client;

const Scene = scene_mod.Scene;
const SceneNode = scene_mod.SceneNode;
const Texture = texture_mod.Texture;
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
    /// The client cursor surface's buffer scale applied at the last
    /// update (surface.current.scale; 1 when no scaled surface is set).
    /// update() renders the texture at its LOGICAL size — buffer pixels
    /// divided by this scale (S6) — and draw() renders the same size.
    client_scale: i32 = 1,
    /// Seat listener for the cursor_surface signal.
    cursor_surface_listener: wire.Listener(*seat_mod.Seat),

    /// Old+new footprints across one update: the compositor damages both
    /// (a partial upload must repaint the old and the new position) and
    /// restores both from the persisted base on a hover repaint.
    ///
    /// WORLD-space f64 rects (see footprints): the compositor projects
    /// them through the view camera and narrows only what lands on the
    /// output.
    pub const Footprints = struct {
        old: [2]?geom.FRect,
        new: [2]?geom.FRect,
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
    /// Footprints carry the OLD world rects (captured before the move)
    /// and the NEW world rects; the compositor damages/restores both.
    pub fn update(self: *Cursor) Footprints {
        const old = self.footprints();
        const seat = self.seat;
        const x: f64 = @floatFromInt(seat.pointer_x);
        const y: f64 = @floatFromInt(seat.pointer_y);

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
        var client_scale: i32 = 1;
        if (seat.cursorSurface()) |res| {
            for (self.compositor.surfaces.items) |s| {
                if (s.resource != res) continue;
                // S6: the cursor image occupies its LOGICAL footprint —
                // the buffer size divided by the surface's buffer scale
                // (the hotspot is in surface-local logical coordinates
                // too, so it stays unscaled, matching the logical-size
                // image). current.scale is validated > 0 at
                // set_buffer_scale (surface.zig:901) and defaults to 1;
                // guard the division anyway.
                client_scale = if (s.current.scale > 1) s.current.scale else 1;
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
        self.client_scale = client_scale;
        self.surface_dirty = false;
        if (self.texture) |t| {
            if (t != surface_texture) t.destroy();
            self.texture = null;
        }
        if (surface_texture) |tex| {
            self.texture = tex;
            const node = self.buf_node;
            node.kind.buffer.texture = tex;
            // Logical size: buffer pixels ÷ buffer scale (S6), clamped to
            // 1 so a tiny buffer cannot produce a 0-size node.
            const scale: i32 = if (self.client_scale > 1) self.client_scale else 1;
            node.kind.buffer.dst_width = @max(1, @divTrunc(tex.width, scale));
            node.kind.buffer.dst_height = @max(1, @divTrunc(tex.height, scale));
            // The node sits in WORLD space, like every other node. The
            // pointer is an output pixel and the hotspot a surface-local
            // logical offset, so both widen here — the subtraction never
            // runs in i32 where a large hotspot could wrap.
            node.setPosition(
                x - @as(f64, @floatFromInt(seat.cursor_hotspot_x)),
                y - @as(f64, @floatFromInt(seat.cursor_hotspot_y)),
            );
            node.enable(true);
            self.rect_node.enable(false);
        } else {
            self.texture_buffer = null;
            self.rect_node.setPosition(x, y);
            self.rect_node.enable(true);
            self.buf_node.enable(false);
        }
        return .{ .old = old, .new = self.footprints() };
    }

    /// The cursor nodes' footprints in WORLD space (fallback rect +
    /// client cursor buffer), or null for a disabled node.
    ///
    /// A footprint is the node's f64 absolute rect: the parent chain
    /// plus the node offset, fraction and far origin included. This is
    /// the only place the cursor's exact world placement is known, so it
    /// is never narrowed here. Converting to output pixels lost that
    /// placement: past the i32 range both ends saturated onto the
    /// boundary, so every far position reported the same empty rect and
    /// the subpixel part vanished before the camera ever saw it. The
    /// compositor projects the world rect through the view camera in
    /// f64 and narrows only the on-screen result.
    pub fn footprints(self: *Cursor) [2]?geom.FRect {
        var out: [2]?geom.FRect = .{ null, null };
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
        // The world position comes from the NODE, not from a second copy
        // of the pointer-minus-hotspot arithmetic: update() already placed
        // it, and the scene pass and this canvas pass then draw the cursor
        // at the same world point by construction.
        var cursor_items: [1]canvas_mod.CanvasItem = undefined;
        if (self.texture) |tex| {
            const node = self.buf_node;
            cursor_items[0] = .{
                .texture = tex,
                .world_x = node.x,
                .world_y = node.y,
                .world_w = @floatFromInt(node.kind.buffer.dst_width),
                .world_h = @floatFromInt(node.kind.buffer.dst_height),
                .opacity = 1.0,
            };
        } else {
            const tex = self.ensureFallbackTexture() orelse return;
            const node = self.rect_node;
            cursor_items[0] = .{
                .texture = tex,
                .world_x = node.x,
                .world_y = node.y,
                .world_w = @floatFromInt(node.kind.rect.width),
                .world_h = @floatFromInt(node.kind.rect.height),
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
const posix = std.posix;

/// The one definition of a test roundtrip (flush the client, dispatch the
/// server's event loop, flush the replies back). See pumpClient below.
const test_pump = @import("../utils/test_pump.zig");

/// Registry names the S6 wire test needs (wl_compositor + wl_shm).
const CursorRegistryCapture = struct {
    compositor_name: ?u32 = null,
    shm_name: ?u32 = null,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *CursorRegistryCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, name, "wl_shm")) {
                    data.shm_name = g.name;
                }
            },
            .global_remove => {},
        }
    }
};

/// Minimal cursor test server: display + compositor + seat + scene +
/// renderer + Cursor. The fallback tests drive the seat's pointer state
/// directly (pointerMotion / cursorSurface fields); the S6 wire test
/// attaches a real client (client + c_display) owned here so deinit can
/// tear it down FIRST (LIFO), before the modules.
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
    /// The S6 test's server-side wire client (null in the fallback-only
    /// tests). Destroyed first in deinit so the resource destroy
    /// handlers run while the compositor/display modules are alive; a
    /// client dropped by a protocol error is nulled by pump (the server
    /// already destroyed it) so deinit never double-destroys (mirrors
    /// data_device.zig's TestServer).
    client: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,

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
        // Tear the wire client down FIRST (LIFO): its resource destroy
        // handlers (Surface.destroy → buffer release) must run while the
        // compositor and display modules are alive. A client dropped by
        // a protocol error has its server-side client already destroyed
        // by the server, so `client` is null and only the client display
        // is disconnected (mirrors data_device.zig's TestServer deinit).
        if (ts.c_display) |d| d.disconnect();
        if (ts.client) |c| c.destroy();
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
    const expected: geom.FRect = .{ .x = 100, .y = 50, .width = @floatFromInt(cursor_size), .height = @floatFromInt(cursor_size) };
    try testing.expectEqual(expected, fp.new[0].?);
    try testing.expect(fp.new[1] == null);
    try testing.expect(cursor.rect_node.enabled);
    try testing.expect(!cursor.buf_node.enabled);
    try testing.expectEqual(expected, cursor.footprints()[0].?);

    // The next update captures the previous footprints BEFORE moving.
    seat.pointerMotion(110, 60);
    const fp2 = cursor.update();
    try testing.expectEqual(fp.new[0].?, fp2.old[0].?);
    const expected2: geom.FRect = .{ .x = 110, .y = 60, .width = @floatFromInt(cursor_size), .height = @floatFromInt(cursor_size) };
    try testing.expectEqual(expected2, fp2.new[0].?);
    try testing.expect(fp2.old[1] == null);
    try testing.expect(fp2.new[1] == null);
}

test "footprints keep far subpixel world positions across a move" {
    const allocator = testing.allocator;
    const ts = TestCursorServer.init(allocator) catch |err| {
        std.debug.print("cursor test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();
    const cursor = ts.cursor.?;
    const seat = ts.seat.?;
    const scene = ts.scene.?;

    // The scene root a terabyte from the origin, a quarter pixel and
    // three quarters off it: the cursor nodes inherit that offset
    // through their parent chain. A footprint that reached the damage
    // ring as output pixels saturated onto the i32 boundary here — every
    // far position became the same empty rect, and the subpixel part was
    // gone before the camera ever saw it.
    const far_x: f64 = 0x1p40 + 0.25;
    const far_y: f64 = 0x1p40 + 0.75;
    scene.root.setPosition(far_x, far_y);
    const size: f64 = @floatFromInt(cursor_size);

    // No client cursor surface: the fallback rect follows the pointer.
    seat.pointerMotion(10, 20);
    const fp = cursor.update();
    try testing.expect(fp.old[0] == null);
    try testing.expect(fp.new[1] == null);
    const first = fp.new[0].?;
    try testing.expectEqual(far_x + 10, first.x);
    try testing.expectEqual(far_y + 20, first.y);
    try testing.expectEqual(size, first.width);
    try testing.expectEqual(size, first.height);
    // The subpixel part survives the whole path.
    try testing.expectEqual(@as(f64, 0.25), first.x - @floor(first.x));
    try testing.expectEqual(@as(f64, 0.75), first.y - @floor(first.y));

    // Move: old and new are DISTINCT far world rects — the property a
    // saturating pixel conversion cannot express.
    seat.pointerMotion(11, 21);
    const fp2 = cursor.update();
    const second = fp2.new[0].?;
    try testing.expectEqual(far_x + 11, second.x);
    try testing.expectEqual(far_y + 21, second.y);
    try testing.expectEqual(first, fp2.old[0].?);
    try testing.expect(first.x != second.x);
    try testing.expect(first.y != second.y);

    // The client-cursor slot carries its own world rect: the node
    // enabled here stands in for an imported cursor surface, whose
    // logical size differs from the fallback rect's.
    cursor.buf_node.setPosition(11, 21);
    cursor.buf_node.kind.buffer.dst_width = 24;
    cursor.buf_node.kind.buffer.dst_height = 8;
    cursor.buf_node.enable(true);
    const client_fp = cursor.footprints();
    try testing.expectEqual(
        geom.FRect{ .x = far_x + 11, .y = far_y + 21, .width = 24, .height = 8 },
        client_fp[1].?,
    );
    // The rect slot keeps the fallback's own world rect beside it.
    try testing.expectEqual(second, client_fp[0].?);
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
    const expected: geom.FRect = .{ .x = 20, .y = 20, .width = @floatFromInt(cursor_size), .height = @floatFromInt(cursor_size) };
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
        geom.FRect{ .x = 30, .y = 30, .width = @floatFromInt(cursor_size), .height = @floatFromInt(cursor_size) },
        fp3.new[0].?,
    );
}

test "scale-2 client cursor surface renders at its logical size (S6)" {
    const allocator = testing.allocator;
    const ts = TestCursorServer.init(allocator) catch |err| {
        std.debug.print("cursor test init failed: {s} (xkeyboard-config missing?)\n", .{@errorName(err)});
        return;
    };
    defer ts.deinit();
    const cursor = ts.cursor.?;
    const seat = ts.seat.?;

    // Real wire client: bind wl_compositor + wl_shm, create a 32x32
    // opaque-white shm buffer, a surface with buffer_scale 2, attach +
    // commit. Only this path yields a surface with an importable buffer
    // (a real wire.shm.Buffer); the compositor registers the surface and
    // the commit publishes current.scale = 2 + s.buffer.
    try ts.display.?.initShm();
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
    // Owned by the harness: deinit destroys the client FIRST (LIFO) so
    // the resource destroy handlers run while the modules live, and
    // pump nulls the pointer on a dispatch failure (the server already
    // destroyed the client — a dangling re-destroy would log libwayland's
    // "re-entrant client destruction").
    ts.client = wire.Client.create(ts.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
    ts.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;

    // A local struct, not a TestCursorServer method: only this test has a
    // live wire client, and the roundtrip it needs is the shared one.
    const pumpClient = struct {
        fn pump(ts2: *TestCursorServer) !void {
            const disp = ts2.c_display.?;
            try test_pump.roundtrip(disp, ts2.display.?, 0);
            var pfds = [_]posix.pollfd{
                .{ .fd = disp.getFd(), .events = posix.POLL.IN, .revents = 0 },
            };
            if (try posix.poll(&pfds, 0) > 0) {
                if (disp.dispatch() != .SUCCESS) {
                    // Protocol error or disconnect: the server has already
                    // destroyed its client (dangling) — forget it for deinit.
                    ts2.client = null;
                    return error.ClientDispatchFailed;
                }
            }
        }
    }.pump;

    // Round 1: registry + global announcements.
    const registry = try ts.c_display.?.getRegistry();
    var capture: CursorRegistryCapture = .{};
    registry.setListener(*CursorRegistryCapture, CursorRegistryCapture.listener, &capture);
    try pumpClient(ts);
    if (capture.compositor_name == null or capture.shm_name == null) return error.GlobalMissing;

    // Round 2: bind wl_compositor + wl_shm, make the 32x32 buffer.
    const wl_compositor = try registry.bind(capture.compositor_name.?, client.wl.Compositor, 7);
    const shm = try registry.bind(capture.shm_name.?, client.wl.Shm, 1);
    const width: i32 = 32;
    const height: i32 = 32;
    const fd = try std.posix.memfd_create("cursor-test-buffer", std.os.linux.MFD.CLOEXEC);
    defer _ = std.os.linux.close(fd);
    const pool_size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const trc = std.os.linux.ftruncate(fd, @intCast(pool_size));
    if (std.os.linux.errno(trc) != .SUCCESS) return error.FtruncateFailed;
    // Fill the pool with opaque white (ARGB8888: every byte 0xFF) so the
    // rendered footprint is observable in the framebuffer.
    const pool_map = try std.posix.mmap(
        null,
        pool_size,
        std.posix.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    @memset(pool_map, 0xFF);
    std.posix.munmap(pool_map);
    const pool = try shm.createPool(fd, @intCast(pool_size));
    defer pool.destroy();
    const buffer = try pool.createBuffer(0, width, height, width * 4, .argb8888);
    defer buffer.destroy();

    // The cursor surface: buffer_scale 2, 32x32 buffer attached + committed.
    const wl_surface = try wl_compositor.createSurface();
    wl_surface.setBufferScale(2);
    wl_surface.attach(buffer, 0, 0);
    wl_surface.commit();
    try pumpClient(ts);

    const surface = for (ts.compositor.?.surfaces.items) |s| {
        if (s.resource.getClient() == ts.client.?) break s;
    } else unreachable;
    try testing.expectEqual(@as(i32, 2), surface.current.scale);
    try testing.expect(surface.buffer != null);

    // set_cursor with hotspot (5, 6) at pointer (30, 40), then update.
    seat.pointerMotion(30, 40);
    seat.cursor_surface_resource = surface.resource;
    seat.cursor_hotspot_x = 5;
    seat.cursor_hotspot_y = 6;
    seat.events.cursor_surface.emit(seat);
    const fp = cursor.update();

    // The texture is imported and the node lands at pointer - hotspot
    // (the hotspot is logical and the image is logical-sized, S6).
    try testing.expect(cursor.texture != null);
    try testing.expect(cursor.buf_node.enabled);
    try testing.expectEqual(@as(f64, 25), cursor.buf_node.x);
    try testing.expectEqual(@as(f64, 34), cursor.buf_node.y);
    try testing.expectEqual(@as(i32, 2), cursor.client_scale);
    // 32x32 buffer at scale 2 renders 16x16 (clamped to >= 1).
    try testing.expectEqual(@as(i32, 16), cursor.buf_node.kind.buffer.dst_width);
    try testing.expectEqual(@as(i32, 16), cursor.buf_node.kind.buffer.dst_height);
    // The update footprint covers the logical 16x16 rect.
    const expected: geom.FRect = .{ .x = 25, .y = 34, .width = 16, .height = 16 };
    try testing.expectEqual(expected, fp.new[1].?);

    // The draw path renders the same 16x16 footprint: opaque white over
    // the red base exactly where the hotspot puts it (world == fb coords
    // for the identity camera, as the fallback test asserts).
    const fb = try pixman_mod.Framebuffer.create(allocator, 64, 64);
    defer fb.deinit();
    fb.fill(.{ 0, 0, 255, 255 });
    cursor.draw(fb);
    const stride: usize = @intCast(fb.stride);
    const at = struct {
        fn pixel(f: *pixman_mod.Framebuffer, s: usize, x: usize, y: usize) [4]u8 {
            return f.data[y * s + x * 4 ..][0..4].*;
        }
    }.pixel;
    // Inside the 16x16 footprint: white (the scale-2 image).
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(fb, stride, 33, 42));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(fb, stride, 25, 34));
    // Outside it: the red base (a scale-1 render would have painted
    // twice as far right/down).
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(fb, stride, 24, 34));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(fb, stride, 41, 42));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(fb, stride, 48, 48));

    // Release the attached buffer: destroy the server-side surface NOW,
    // while the wl_buffer resource is still alive. Client teardown
    // (ts.deinit → client.destroy) destroys the wl_buffer BEFORE the
    // wl_surface (libwayland's object-map iteration is id order), and the
    // surface's F42 buffer-resource listener then nulls the current slot
    // without freeing the wrapper — with no ShmState wired the wrapper is
    // untracked and surface-owned, so it would leak (Buffer + ShmBufferData).
    // Surface.destroy runs the same release path as the wire destructor
    // (drop/unlock/destroy the untracked wrapper) and inertizes the
    // resource, so the later client teardown destroys an inert resource.
    surface.destroy();
}
