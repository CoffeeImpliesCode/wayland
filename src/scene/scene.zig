//! Scene graph (int mode, M2): the plain-desktop form of the canvas-first
//! scene (§2 scene/ of the spec).
//!
//! A Scene is a tree of SceneNodes rooted at an invisible .tree node.
//! Nodes carry an integer position (x/y) relative to their parent;
//! absolutePosition() sums ancestors. Two drawable kinds:
//!   - SceneRectNode: solid rect fill (add_rect);
//!   - SceneBufferNode: texture blit (add_texture), with optional src crop,
//!     dst size scaling and opacity.
//! A SceneOutput places a wlr_output in scene space (x/y offset) and
//! composites the tree into the renderer target: nodes whose absolute rect
//! does not intersect the output rect are culled; disabled nodes (and their
//! subtrees) are skipped. Draw order = children order (painter's algorithm).
//!
//! Imports: utils/*, renderer/*, output/* (sibling modules).

const std = @import("std");
const geom = @import("../utils/geom.zig");
const damage_mod = @import("../utils/damage.zig");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const backend_mod = @import("../backend/backend.zig");
const output_mod = @import("../output/output.zig");
const renderer_mod = @import("../renderer/renderer.zig");
const pass_mod = @import("../renderer/pass.zig");
const texture_mod = @import("../renderer/texture.zig");
// The surface→scene binding (scene/surface_node.zig): the scene owns the
// tracked-surface registry (like wlr_scene owning its surface list,
// types/scene/surface.c). Scene depends on the compositor surface +
// subsurface types (same direction wlroots takes: wlr_scene includes
// wlr_surface).
const surface_mod = @import("../compositor/surface.zig");
const subsurface_mod = @import("../compositor/subsurface.zig");
const wl_output_mod = @import("../output/wl_output.zig");
const surface_node_mod = @import("surface_node.zig");

const Rect = geom.Rect;
const FRect = geom.FRect;

/// The scene graph: owns the tree, allocator and logging. One scene can be
/// composited by several SceneOutputs (each places it via x/y).
pub const Scene = struct {
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
    root: *SceneNode, // kind .tree, position (0,0)
    /// Tracked surface→node bindings (scene/surface_node.zig): the
    /// library's surface→scene table. The compositor decides which
    /// surfaces get bindings (trackSurface call sites); the bindings own
    /// the surface→node lifecycle.
    surface_nodes: std.AutoHashMap(*surface_mod.Surface, *surface_node_mod.SurfaceNode),
    /// The frame's presented surfaces (presentation feedback targets),
    /// rebuilt per frame by collectPresented.
    presented: std.ArrayList(*surface_mod.Surface) = .empty,
    /// The scene's output views (SceneOutput.create registers itself):
    /// the surface enter/leave association (which output a node is
    /// rendered on) resolves against these.
    scene_outputs: std.ArrayList(*SceneOutput) = .empty,
    /// The compositor's wl_output global: the surface enter/leave wire
    /// events go to the wl_output resources bound by the surface's
    /// client (set by the compositor; null = no wire enter/leave).
    wl_output: ?*wl_output_mod.WlOutput = null,
    /// The compositor's subcompositor: subsurface tree parenting (set by
    /// the compositor; null = no subsurface support).
    subcompositor: ?*subsurface_mod.Subcompositor = null,
    /// A tracked surface committed new content: the compositor should
    /// schedule a render (the commit→present wake — note 137 F1).
    /// Without it the node is synced but no frame is ever composited, so
    /// interactive clients' content starves behind the idle-frame skip.
    events: struct {
        content_dirty: wire.Signal(*Scene) = undefined,
    } = .{},

    pub fn init(allocator: std.mem.Allocator, io: *std.Io, log_cfg: *const log.Config) !*Scene {
        const root = try SceneNode.create(allocator, null, .tree);
        errdefer root.destroy(allocator);
        const self = try allocator.create(Scene);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .log_cfg = log_cfg,
            .root = root,
            .surface_nodes = std.AutoHashMap(*surface_mod.Surface, *surface_node_mod.SurfaceNode).init(allocator),
        };
        self.events.content_dirty.init();
        log.debug("scene created", io, log_cfg, "scene", .{});
        return self;
    }

    /// Destroy the scene: every tracked surface binding first (their
    /// nodes + surface listeners), then every node and the scene itself.
    /// The compositor may destroy its surfaces after the scene, so the
    /// surface destroy signals must not reach freed bindings.
    pub fn deinit(scene: *Scene) void {
        surface_node_mod.untrackAll(scene);
        scene.surface_nodes.deinit();
        scene.presented.deinit(scene.allocator);
        scene.scene_outputs.deinit(scene.allocator);
        scene.root.destroy(scene.allocator);
        const allocator = scene.allocator;
        allocator.destroy(scene);
    }

    /// Topmost drawable node whose absolute rect contains (x, y): the
    /// seat's hit test. Walks children in reverse draw order (the last
    /// child draws on top); skips disabled and non-pickable nodes and
    /// their subtrees. Returns only .buffer nodes (surface content) —
    /// rect nodes are decoration. Null when the point hits nothing.
    pub fn pick(scene: *Scene, x: i32, y: i32) ?*SceneNode {
        return pickNode(scene.root, x, y);
    }
};

/// A node in the scene tree. Position (x/y) is relative to the parent.
/// Only .tree nodes may have children appended. Disabled nodes and their
/// subtrees are skipped at render time.
pub const SceneNode = struct {
    kind: union(enum) { tree, buffer: *SceneBufferNode, rect: *SceneRectNode },
    parent: ?*SceneNode,
    children: std.ArrayList(*SceneNode) = .empty,
    enabled: bool = true,
    /// Pickable by the seat's hit test. Decoration nodes (the cursor)
    /// disable this so the pointer never targets them.
    pickable: bool = true,
    x: i32 = 0,
    y: i32 = 0,

    /// Creation tag for create().
    pub const Kind = enum { tree, buffer, rect };

    /// Allocate a node of `kind`, optionally appending it to `parent`
    /// (which must be a .tree node).
    pub fn create(
        allocator: std.mem.Allocator,
        parent: ?*SceneNode,
        kind: Kind,
    ) error{OutOfMemory}!*SceneNode {
        std.debug.assert(parent == null or parent.?.kind == .tree);
        const node = switch (kind) {
            .tree => blk: {
                const n = try allocator.create(SceneNode);
                n.* = .{
                    .kind = .tree,
                    .parent = parent,
                    .children = .empty,
                    .enabled = true,
                    .x = 0,
                    .y = 0,
                };
                break :blk n;
            },
            .buffer => blk: {
                const bn = try allocator.create(SceneBufferNode);
                errdefer allocator.destroy(bn);
                bn.* = .{
                    .node = .{
                        .kind = .{ .buffer = bn },
                        .parent = parent,
                        .children = .empty,
                        .enabled = true,
                        .x = 0,
                        .y = 0,
                    },
                    .texture = null,
                    .src = null,
                    .dst_width = 0,
                    .dst_height = 0,
                    .opacity = 1.0,
                };
                break :blk &bn.node;
            },
            .rect => blk: {
                const rn = try allocator.create(SceneRectNode);
                errdefer allocator.destroy(rn);
                rn.* = .{
                    .node = .{
                        .kind = .{ .rect = rn },
                        .parent = parent,
                        .children = .empty,
                        .enabled = true,
                        .x = 0,
                        .y = 0,
                    },
                    .color = .{ 1.0, 1.0, 1.0, 1.0 },
                    .width = 0,
                    .height = 0,
                };
                break :blk &rn.node;
            },
        };
        if (parent) |p| {
            p.appendChild(allocator, node) catch {
                node.destroy(allocator);
                return error.OutOfMemory;
            };
        }
        return node;
    }

    /// Append `child` as the last child (top of the draw order). If `child`
    /// already has a parent it is reparented. `node` must be a .tree node.
    /// Rejects with error.CycleDetected when `child` is `node` or an
    /// ancestor of `node` (the append would make `node` its own ancestor);
    /// the tree is left unchanged.
    pub fn appendChild(
        node: *SceneNode,
        allocator: std.mem.Allocator,
        child: *SceneNode,
    ) error{ OutOfMemory, CycleDetected }!void {
        std.debug.assert(node.kind == .tree);
        // A node cannot become its own ancestor: reject when `child` is
        // `node` or already on `node`'s ancestor chain. Mirrors
        // wlr_scene_node_reparent's ancestor walk (wlr_scene.c:1316-1319);
        // unlike wlroots we surface it as an error, not an assert, so the
        // check holds in release builds too.
        var ancestor: ?*SceneNode = node;
        while (ancestor) |a| : (ancestor = a.parent) {
            if (a == child) return error.CycleDetected;
        }
        if (child.parent) |p| p.removeChild(child);
        try node.children.append(allocator, child);
        child.parent = node;
    }

    /// Detach `child` from `node` (no-op when it is not a child).
    /// Child order is preserved (draw order matters).
    pub fn removeChild(node: *SceneNode, child: *SceneNode) void {
        std.debug.assert(node.kind == .tree);
        const idx = std.mem.indexOfScalar(*SceneNode, node.children.items, child) orelse return;
        _ = node.children.orderedRemove(idx);
        child.parent = null;
    }

    pub fn enable(node: *SceneNode, enabled: bool) void {
        node.enabled = enabled;
    }

    /// Destroy this node and its whole subtree. The node detaches itself
    /// from its parent first.
    pub fn destroy(node: *SceneNode, allocator: std.mem.Allocator) void {
        if (node.parent) |p| p.removeChild(node);
        while (node.children.items.len > 0) {
            node.children.items[0].destroy(allocator);
        }
        node.children.deinit(allocator);
        switch (node.kind) {
            .tree => allocator.destroy(node),
            .buffer => |bn| allocator.destroy(bn),
            .rect => |rn| allocator.destroy(rn),
        }
    }

    /// Bounding rect in scene space: the sum of all ancestor x/y (including
    /// this node) as origin, sized by the node's own extent (tree nodes have
    /// zero size; buffer nodes use dst_size, falling back to the texture
    /// size; rect nodes use their width/height).
    pub fn absolutePosition(node: *const SceneNode) Rect {
        var x = node.x;
        var y = node.y;
        var parent = node.parent;
        while (parent) |p| : (parent = p.parent) {
            x += p.x;
            y += p.y;
        }
        return .{ .x = x, .y = y, .width = nodeWidth(node), .height = nodeHeight(node) };
    }
};

/// Recursive hit test: children in reverse draw order; tree nodes recurse,
/// buffer nodes win on containment, rect nodes are skipped.
fn pickNode(node: *SceneNode, x: i32, y: i32) ?*SceneNode {
    var i = node.children.items.len;
    while (i > 0) {
        i -= 1;
        const child = node.children.items[i];
        if (!child.enabled or !child.pickable) continue;
        if (child.kind == .tree) {
            if (pickNode(child, x, y)) |hit| return hit;
            continue;
        }
        if (child.kind == .buffer and child.absolutePosition().containsPoint(.{ .x = x, .y = y })) return child;
    }
    return null;
}

/// Texture blit node: draws `texture` (cropped to `src`, null = whole
/// texture) at the absolute position, sized dst_width x dst_height
/// (0 = texture size, 1:1), at `opacity`.
pub const SceneBufferNode = struct {
    node: SceneNode,
    texture: ?*texture_mod.Texture = null,
    src: ?FRect = null, // crop; null = whole texture
    dst_width: i32 = 0, // 0 = texture size (1:1)
    dst_height: i32 = 0,
    opacity: f32 = 1.0,
};

/// Solid rect node: fills its absolute rect (position + width/height) with
/// a straight-alpha RGBA color.
pub const SceneRectNode = struct {
    node: SceneNode,
    color: [4]f32,
    width: i32 = 0, // nothing drawn while width/height <= 0
    height: i32 = 0,
};

/// A view of the scene onto one output: the output rect in scene space is
/// (x, y, output.width, output.height). render() composites the tree into
/// the renderer target for this output. The damage ring tracks what
/// changed on this output: the compositor accumulates per-surface damage
/// via addDamage before render, rotates the ring after render, and reads
/// the frame's rects back via takeDamage for the output commit.
pub const SceneOutput = struct {
    output: *output_mod.Output,
    scene: *Scene,
    damage_ring: damage_mod.DamageRing,
    x: i32 = 0, // position in scene space
    y: i32 = 0,

    /// `allocator` must be the scene's allocator: destroy() recovers it
    /// from the scene.
    pub fn create(
        allocator: std.mem.Allocator,
        io: *std.Io,
        log_cfg: *const log.Config,
        scene: *Scene,
        output: *output_mod.Output,
    ) !*SceneOutput {
        const self = try allocator.create(SceneOutput);
        errdefer allocator.destroy(self);
        self.* = .{
            .output = output,
            .scene = scene,
            .damage_ring = damage_mod.DamageRing.init(allocator, 2),
            .x = 0,
            .y = 0,
        };
        // (the errdefer frees self on failure)
        try scene.scene_outputs.append(allocator, self);
        log.debug(
            "scene output created for output {d}x{d}",
            io,
            log_cfg,
            "scene",
            .{ output.width, output.height },
        );
        return self;
    }

    /// Destroy this output view (and its damage ring). The scene tree is
    /// NOT freed: a scene can be shared across outputs — call Scene.deinit
    /// to destroy the tree.
    pub fn destroy(so: *SceneOutput) void {
        const scene = so.scene;
        const allocator = scene.allocator;
        so.damage_ring.deinit();
        // Unregister from the scene (surface enter/leave association).
        if (std.mem.findScalar(*SceneOutput, scene.scene_outputs.items, so)) |idx| {
            _ = scene.scene_outputs.orderedRemove(idx);
        }
        allocator.destroy(so);
    }

    /// Accumulate `rect` (in output coordinates) into this frame's
    /// damage. Called by the compositor for every damaged surface region
    /// (and cursor move) before render; takeDamage after rotate carries
    /// the frame's region to the output commit (wlr_damage_ring_add_box,
    /// types/wlr_damage_ring.c:40).
    pub fn addDamage(so: *SceneOutput, rect: geom.Rect) void {
        so.damage_ring.add(rect) catch {
            // Out of memory: whole-output damage is the conservative
            // fallback (the full region gets repainted/uploaded).
            so.damage_ring.addWhole();
        };
    }

    /// The rects accumulated for the frame that was just rotated out —
    /// i.e. THIS frame's damage after `damage_ring.rotate()`. Empty when
    /// the frame carried no rect damage (nothing, or whole damage that
    /// degenerates to a full repaint); callers fall back to whole-output
    /// damage then. The returned slice is valid until the next
    /// add/rotate on this output.
    pub fn takeDamage(so: *SceneOutput) []const geom.Rect {
        const ring = &so.damage_ring;
        // rotate() moved this frame's accumulation into the newest history
        // slot; num_buffers=1 disables history entirely (no slot).
        if (ring.history.items.len == 0) return &.{};
        const frame = &ring.history.items[0];
        if (frame.whole) return &.{};
        return frame.rects.items;
    }

    /// Composite the scene into the renderer target (framebuffer) for this
    /// output: walk the tree, cull nodes outside the output rect, draw rect
    /// nodes via add_rect and buffer nodes via add_texture, submit.
    pub fn render(so: *SceneOutput, renderer: *renderer_mod.Renderer, target: *anyopaque) void {
        std.debug.assert(so.output.width > 0);
        std.debug.assert(so.output.height > 0);
        const out_rect: Rect = .{
            .x = so.x,
            .y = so.y,
            .width = so.output.width,
            .height = so.output.height,
        };
        const pass = renderer.beginPass(target) orelse {
            log.trace("render: target unsupported, skipping", so.scene.io, so.scene.log_cfg, "scene", .{});
            return;
        };
        defer pass.submit();
        renderNode(pass, so.scene.root, out_rect, true);
    }
};

fn renderNode(pass: *pass_mod.Pass, node: *SceneNode, out_rect: Rect, ancestors_enabled: bool) void {
    const visible = ancestors_enabled and node.enabled;
    if (!visible) return;
    switch (node.kind) {
        .tree => {},
        .buffer => |bn| renderBuffer(pass, node, bn, out_rect),
        .rect => |rn| renderRect(pass, node, rn, out_rect),
    }
    for (node.children.items) |child| renderNode(pass, child, out_rect, visible);
}

fn renderBuffer(pass: *pass_mod.Pass, node: *const SceneNode, bn: *SceneBufferNode, out_rect: Rect) void {
    const texture = bn.texture orelse return;
    const rect = node.absolutePosition();
    if (out_rect.intersect(rect) == null) return;
    pass.addTexture(texture, bn.src, .{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .width = @floatFromInt(rect.width),
        .height = @floatFromInt(rect.height),
    }, bn.opacity);
}

fn renderRect(pass: *pass_mod.Pass, node: *const SceneNode, rn: *SceneRectNode, out_rect: Rect) void {
    if (rn.width <= 0 or rn.height <= 0) return;
    const rect = node.absolutePosition();
    if (out_rect.intersect(rect) == null) return;
    pass.addRect(rect, rn.color);
}

fn nodeWidth(node: *const SceneNode) i32 {
    return switch (node.kind) {
        .tree => 0,
        .buffer => |bn| if (bn.dst_width != 0) bn.dst_width else (if (bn.texture) |t| t.width else 0),
        .rect => |rn| rn.width,
    };
}

fn nodeHeight(node: *const SceneNode) i32 {
    return switch (node.kind) {
        .tree => 0,
        .buffer => |bn| if (bn.dst_height != 0) bn.dst_height else (if (bn.texture) |t| t.height else 0),
        .rect => |rn| rn.height,
    };
}

const testing = std.testing;

fn makeScene(allocator: std.mem.Allocator, io: *std.Io, log_cfg: *const log.Config) !*Scene {
    return Scene.init(allocator, io, log_cfg);
}

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

const FakeBackendImpl = struct {
    fn start(_: *backend_mod.Backend) error{BackendFailed}!void {}
    fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
};

const fake_backend_impl: backend_mod.Backend.Impl = .{
    .start = FakeBackendImpl.start,
    .destroy = FakeBackendImpl.destroy,
};

fn makeOutput(
    allocator: std.mem.Allocator,
    io: *std.Io,
    log_cfg: *const log.Config,
) !struct { *output_mod.Output, *backend_mod.Backend } {
    var backend_dummy: u8 = 0;
    const backend = try backend_mod.Backend.init(allocator, io, log_cfg, &fake_backend_impl, &backend_dummy);
    errdefer backend.destroy();
    var out_dummy: u8 = 0;
    const mode: output_mod.Mode = .{ .width = 800, .height = 600, .refresh_msec = 16 };
    const out = try output_mod.Output.create(allocator, io, log_cfg, backend, &fake_output_impl, &out_dummy, mode);
    return .{ out, backend };
}

const DummyTexture = struct { destroyed: bool = false };

fn dummyTextureDestroy(texture: *texture_mod.Texture) void {
    const self: *DummyTexture = @ptrCast(@alignCast(texture.data));
    self.destroyed = true;
}

const dummy_texture_impl: texture_mod.Texture.Impl = .{ .destroy = dummyTextureDestroy };

const RecordedRect = struct { rect: Rect, color: [4]f32 };

const RecordedTexture = struct {
    texture: *texture_mod.Texture,
    src: ?FRect,
    dst: FRect,
    alpha: f32,
};

const Recorder = struct {
    allocator: std.mem.Allocator,
    rects: std.ArrayList(RecordedRect) = .empty,
    textures: std.ArrayList(RecordedTexture) = .empty,
    submits: usize = 0,

    fn deinit(r: *Recorder) void {
        r.rects.deinit(r.allocator);
        r.textures.deinit(r.allocator);
    }
};

const RecorderData = struct {
    rec: *Recorder,
    pass: pass_mod.Pass,
};

const recorder_pass_impl: pass_mod.Pass.Impl = .{
    .add_texture = onTexture,
    .add_rect = onRect,
    .submit = onSubmit,
};

const recorder_renderer_impl: renderer_mod.Renderer.Impl = .{
    .begin_pass = onBeginPass,
    .destroy = onRendererDestroy,
};

fn onTexture(pass: *pass_mod.Pass, texture: *texture_mod.Texture, src: ?FRect, dst: FRect, alpha: f32) void {
    const rd: *RecorderData = @ptrCast(@alignCast(pass.data));
    rd.rec.textures.append(rd.rec.allocator, .{
        .texture = texture,
        .src = src,
        .dst = dst,
        .alpha = alpha,
    }) catch return;
}

fn onRect(pass: *pass_mod.Pass, rect: Rect, color: [4]f32) void {
    const rd: *RecorderData = @ptrCast(@alignCast(pass.data));
    rd.rec.rects.append(rd.rec.allocator, .{ .rect = rect, .color = color }) catch return;
}

fn onSubmit(pass: *pass_mod.Pass) void {
    const rd: *RecorderData = @ptrCast(@alignCast(pass.data));
    rd.rec.submits += 1;
}

fn onBeginPass(renderer: *renderer_mod.Renderer, _: *anyopaque) ?*pass_mod.Pass {
    const rd: *RecorderData = @ptrCast(@alignCast(renderer.data));
    rd.pass = .{ .impl = &recorder_pass_impl, .data = rd };
    return &rd.pass;
}

fn onRendererDestroy(_: std.mem.Allocator, _: *anyopaque) void {}

test "scene tree construction, append, remove, enable" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();

    try testing.expectEqual(@as(usize, 0), scene.root.children.items.len);
    try testing.expect(scene.root.kind == .tree);
    try testing.expect(scene.root.parent == null);

    // create() with a parent appends automatically.
    const a = try SceneNode.create(allocator, scene.root, .tree);
    const b = try SceneNode.create(allocator, scene.root, .buffer);
    try testing.expectEqual(@as(usize, 2), scene.root.children.items.len);
    try testing.expect(scene.root.children.items[0] == a);
    try testing.expect(scene.root.children.items[1] == b);
    try testing.expect(a.parent == scene.root);
    try testing.expect(b.parent == scene.root);
    try testing.expect(b.kind.buffer.node.parent == scene.root);

    // create() without a parent, then appendChild.
    const c = try SceneNode.create(allocator, null, .rect);
    try testing.expect(c.parent == null);
    try a.appendChild(allocator, c);
    try testing.expectEqual(@as(usize, 1), a.children.items.len);
    try testing.expect(c.parent == a);

    // removeChild detaches and preserves order.
    a.removeChild(c);
    try testing.expectEqual(@as(usize, 0), a.children.items.len);
    try testing.expect(c.parent == null);
    a.removeChild(c); // not a child: no-op

    // Reparenting through appendChild.
    try a.appendChild(allocator, c);
    try scene.root.appendChild(allocator, c);
    try testing.expectEqual(@as(usize, 0), a.children.items.len);
    try testing.expect(c.parent == scene.root);

    // enable toggles the flag.
    try testing.expect(c.enabled);
    c.enable(false);
    try testing.expect(!c.enabled);
    c.enable(true);
    try testing.expect(c.enabled);
}

test "appendChild rejects self-subtree cycles and leaves the tree unchanged" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();

    // root -> a -> b -> c
    const a = try SceneNode.create(allocator, scene.root, .tree);
    const b = try SceneNode.create(allocator, a, .tree);
    const c = try SceneNode.create(allocator, b, .tree);

    // Appending `a` under its own descendant `c` would make `a` its own
    // ancestor (a -> b -> c -> a): rejected, tree unchanged.
    try testing.expectError(error.CycleDetected, c.appendChild(allocator, a));
    try testing.expect(a.parent == scene.root);
    try testing.expect(b.parent == a);
    try testing.expect(c.parent == b);
    try testing.expectEqual(@as(usize, 1), scene.root.children.items.len);
    try testing.expectEqual(@as(usize, 1), a.children.items.len);
    try testing.expectEqual(@as(usize, 1), b.children.items.len);
    try testing.expectEqual(@as(usize, 0), c.children.items.len);
    try testing.expect(scene.root.children.items[0] == a);
    try testing.expect(a.children.items[0] == b);
    try testing.expect(b.children.items[0] == c);

    // Direct self-append is a cycle too.
    try testing.expectError(error.CycleDetected, a.appendChild(allocator, a));
    try testing.expectEqual(@as(usize, 1), a.children.items.len);

    // Appending a direct parent under its own child (b under c).
    try testing.expectError(error.CycleDetected, c.appendChild(allocator, b));
    try testing.expect(b.parent == a);
    try testing.expectEqual(@as(usize, 1), b.children.items.len);

    // Reparenting within the same subtree is still fine: no cycle.
    try a.appendChild(allocator, c);
    try testing.expect(c.parent == a);
    try testing.expectEqual(@as(usize, 0), b.children.items.len);
    try testing.expectEqual(@as(usize, 2), a.children.items.len);
}

test "absolutePosition sums nested offsets" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();

    const t1 = try SceneNode.create(allocator, scene.root, .tree);
    t1.x = 10;
    t1.y = 20;

    // Buffer: position + texture size when dst unset.
    var dummy: DummyTexture = .{};
    var tex: texture_mod.Texture = .{ .impl = &dummy_texture_impl, .data = &dummy, .width = 64, .height = 32 };
    const buf = try SceneNode.create(allocator, t1, .buffer);
    buf.x = 5;
    buf.y = 7;
    buf.kind.buffer.texture = &tex;
    try testing.expectEqual(Rect{ .x = 15, .y = 27, .width = 64, .height = 32 }, buf.absolutePosition());

    // dst_size overrides the texture size.
    buf.kind.buffer.dst_width = 128;
    buf.kind.buffer.dst_height = 96;
    try testing.expectEqual(Rect{ .x = 15, .y = 27, .width = 128, .height = 96 }, buf.absolutePosition());
    buf.kind.buffer.dst_width = 0;
    buf.kind.buffer.dst_height = 0;

    // Rect: position + own size.
    const rect_node = try SceneNode.create(allocator, t1, .rect);
    rect_node.x = 3;
    rect_node.y = 4;
    rect_node.kind.rect.width = 100;
    rect_node.kind.rect.height = 50;
    try testing.expectEqual(Rect{ .x = 13, .y = 24, .width = 100, .height = 50 }, rect_node.absolutePosition());

    // Tree nodes have zero size.
    try testing.expectEqual(Rect{ .x = 10, .y = 20, .width = 0, .height = 0 }, t1.absolutePosition());
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 0, .height = 0 }, scene.root.absolutePosition());

    // Negative offsets accumulate too.
    const t2 = try SceneNode.create(allocator, scene.root, .tree);
    t2.x = -10;
    t2.y = -10;
    try testing.expectEqual(Rect{ .x = -10, .y = -10, .width = 0, .height = 0 }, t2.absolutePosition());
}

test "render composites background rect and buffer nodes" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();
    const created = try makeOutput(allocator, &io, &log_cfg);
    const out = created[0];
    defer out.destroy();
    defer created[1].destroy();

    const so = try SceneOutput.create(allocator, &io, &log_cfg, scene, out);
    defer so.destroy();
    try testing.expectEqual(@as(i32, 0), so.x);
    try testing.expectEqual(@as(i32, 0), so.y);
    try testing.expect(so.damage_ring.isEmpty());

    // Background rect covering the whole output.
    const bg = try SceneNode.create(allocator, scene.root, .rect);
    bg.kind.rect.width = 800;
    bg.kind.rect.height = 600;
    bg.kind.rect.color = .{ 0.1, 0.2, 0.3, 1.0 };

    // Scaled, cropped, translucent buffer on top.
    var dummy: DummyTexture = .{};
    var tex: texture_mod.Texture = .{ .impl = &dummy_texture_impl, .data = &dummy, .width = 64, .height = 32 };
    const buf = try SceneNode.create(allocator, scene.root, .buffer);
    buf.x = 100;
    buf.y = 100;
    buf.kind.buffer.texture = &tex;
    buf.kind.buffer.src = .{ .x = 0, .y = 0, .width = 32, .height = 32 };
    buf.kind.buffer.dst_width = 128;
    buf.kind.buffer.dst_height = 64;
    buf.kind.buffer.opacity = 0.5;

    // 1:1 buffer: no src, no dst -> texture size at the absolute position.
    const buf2 = try SceneNode.create(allocator, scene.root, .buffer);
    buf2.x = 300;
    buf2.y = 50;
    buf2.kind.buffer.texture = &tex;

    var rec: Recorder = .{ .allocator = allocator };
    defer rec.deinit();
    var rd: RecorderData = .{
        .rec = &rec,
        // SAFETY: pass is filled by onBeginPass before any use.
        .pass = undefined,
    };
    const renderer = try renderer_mod.Renderer.create(allocator, &io, &log_cfg, &recorder_renderer_impl, &rd, &.{});
    defer renderer.destroy();
    var target: u8 = 0;

    so.render(renderer, &target);

    try testing.expectEqual(@as(usize, 1), rec.rects.items.len);
    try testing.expectEqual(RecordedRect{
        .rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .color = .{ 0.1, 0.2, 0.3, 1.0 },
    }, rec.rects.items[0]);

    try testing.expectEqual(@as(usize, 2), rec.textures.items.len);
    try testing.expectEqual(RecordedTexture{
        .texture = &tex,
        .src = .{ .x = 0, .y = 0, .width = 32, .height = 32 },
        .dst = .{ .x = 100, .y = 100, .width = 128, .height = 64 },
        .alpha = 0.5,
    }, rec.textures.items[0]);
    try testing.expectEqual(RecordedTexture{
        .texture = &tex,
        .src = null,
        .dst = .{ .x = 300, .y = 50, .width = 64, .height = 32 },
        .alpha = 1.0,
    }, rec.textures.items[1]);

    try testing.expectEqual(@as(usize, 1), rec.submits);
}

test "SceneOutput damage ring accumulates and takeDamage returns the frame's rects" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();
    const created = try makeOutput(allocator, &io, &log_cfg);
    const out = created[0];
    defer out.destroy();
    defer created[1].destroy();

    const so = try SceneOutput.create(allocator, &io, &log_cfg, scene, out);
    defer so.destroy();
    try testing.expect(so.damage_ring.isEmpty());

    // Frame A: two rects accumulate; rotate ages them out of current.
    so.addDamage(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    so.addDamage(.{ .x = 5, .y = 6, .width = 7, .height = 8 });
    so.damage_ring.rotate();
    const rects = so.takeDamage();
    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .width = 3, .height = 4 }, rects[0]);
    try testing.expectEqual(Rect{ .x = 5, .y = 6, .width = 7, .height = 8 }, rects[1]);

    // Frame B: no damage -> empty takeDamage (caller falls back to whole).
    so.damage_ring.rotate();
    try testing.expectEqual(@as(usize, 0), so.takeDamage().len);

    // Frame C: whole damage degenerates to empty too.
    so.damage_ring.addWhole();
    so.damage_ring.rotate();
    try testing.expectEqual(@as(usize, 0), so.takeDamage().len);
}

test "render culls nodes outside the output rect" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();
    const created = try makeOutput(allocator, &io, &log_cfg);
    const out = created[0];
    defer out.destroy();
    defer created[1].destroy();

    // Output placed at (100, 50): its rect is (100, 50, 800, 600).
    const so = try SceneOutput.create(allocator, &io, &log_cfg, scene, out);
    defer so.destroy();
    so.x = 100;
    so.y = 50;

    var dummy: DummyTexture = .{};
    var tex: texture_mod.Texture = .{ .impl = &dummy_texture_impl, .data = &dummy, .width = 64, .height = 32 };

    // Outside the output rect: culled.
    const outside = try SceneNode.create(allocator, scene.root, .buffer);
    outside.x = 2000;
    outside.y = 2000;
    outside.kind.buffer.texture = &tex;

    const outside_rect = try SceneNode.create(allocator, scene.root, .rect);
    outside_rect.x = -500;
    outside_rect.y = -500;
    outside_rect.kind.rect.width = 10;
    outside_rect.kind.rect.height = 10;

    // Inside, but undrawable: skipped.
    const no_texture = try SceneNode.create(allocator, scene.root, .buffer);
    no_texture.x = 150;
    no_texture.y = 150;

    const zero_size = try SceneNode.create(allocator, scene.root, .rect);
    zero_size.x = 150;
    zero_size.y = 150;

    const hidden = try SceneNode.create(allocator, scene.root, .rect);
    hidden.x = 150;
    hidden.y = 150;
    hidden.kind.rect.width = 50;
    hidden.kind.rect.height = 50;
    hidden.enable(false);

    // Disabled subtree with a visible child: skipped entirely.
    const hidden_tree = try SceneNode.create(allocator, scene.root, .tree);
    hidden_tree.enable(false);
    const hidden_child = try SceneNode.create(allocator, hidden_tree, .buffer);
    hidden_child.x = 150;
    hidden_child.y = 150;
    hidden_child.kind.buffer.texture = &tex;

    // In rect: drawn.
    const visible = try SceneNode.create(allocator, scene.root, .rect);
    visible.x = 200;
    visible.y = 100;
    visible.kind.rect.width = 10;
    visible.kind.rect.height = 10;
    visible.kind.rect.color = .{ 0.5, 0.5, 0.5, 1.0 };

    var rec: Recorder = .{ .allocator = allocator };
    defer rec.deinit();
    var rd: RecorderData = .{
        .rec = &rec,
        // SAFETY: pass is filled by onBeginPass before any use.
        .pass = undefined,
    };
    const renderer = try renderer_mod.Renderer.create(allocator, &io, &log_cfg, &recorder_renderer_impl, &rd, &.{});
    defer renderer.destroy();
    var target: u8 = 0;

    so.render(renderer, &target);

    try testing.expectEqual(@as(usize, 0), rec.textures.items.len);
    try testing.expectEqual(@as(usize, 1), rec.rects.items.len);
    try testing.expectEqual(RecordedRect{
        .rect = .{ .x = 200, .y = 100, .width = 10, .height = 10 },
        .color = .{ 0.5, 0.5, 0.5, 1.0 },
    }, rec.rects.items[0]);
    try testing.expectEqual(@as(usize, 1), rec.submits);
}

test "SceneOutput destroy and Scene deinit free the tree" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, &io, &log_cfg);
    const created = try makeOutput(allocator, &io, &log_cfg);
    const out = created[0];

    const t1 = try SceneNode.create(allocator, scene.root, .tree);
    const bg = try SceneNode.create(allocator, scene.root, .rect);
    bg.kind.rect.width = 800;
    bg.kind.rect.height = 600;
    const buf = try SceneNode.create(allocator, t1, .buffer);
    buf.kind.buffer.texture = null;

    const so = try SceneOutput.create(allocator, &io, &log_cfg, scene, out);
    so.destroy(); // frees the SceneOutput and its damage ring

    scene.deinit(); // frees every node and the scene
    out.destroy();
    created[1].destroy(); // frees the backend
    // testing.allocator reports any leak above.
}
