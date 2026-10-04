//! Scene graph: the plain-desktop form of the canvas-first scene
//! (§2 scene/ of the spec).
//!
//! A Scene is a tree of SceneNodes rooted at an invisible .tree node.
//! Nodes carry an f64 world position (x/y) relative to their parent;
//! absolutePosition() sums the ancestors in f64 and returns the node's
//! world FRect, so a surface can sit at a fractional position and a
//! quarter of a world pixel is a position the compositor can name. Two
//! drawable kinds:
//!   - SceneRectNode: solid rect fill (add_rect);
//!   - SceneBufferNode: texture blit (add_texture), with an optional raw
//!     buffer-pixel src crop, dst size scaling, the surface's buffer
//!     transform and opacity.
//! A SceneOutput is ONE VIEW of that tree onto one output: the output's
//! world origin (x/y, used when the view has no camera) or its camera's
//! visible world rect when it has one. The view composites the tree into
//! the renderer target for that output — nodes outside the view's visible
//! world rect are culled, disabled nodes (and their subtrees) are
//! skipped. Draw order = children order (painter's algorithm).
//!
//! One scene, one SceneOutput per output: each view owns its presented
//! list, its damage ring, its wl_output association and its borrowed
//! camera. Nothing about a view lives on the Scene.
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
const camera_mod = @import("camera.zig");

const Camera = camera_mod.Camera;

const Rect = geom.Rect;
const FRect = geom.FRect;

/// Coordinate space chosen by compositor policy. A local surface without
/// an output is hidden; it must not fall back to the shared world.
pub const SurfacePlacement = union(enum) {
    world,
    output_local: ?*output_mod.Output,
};

/// The scene graph: owns the tree, allocator and logging. One scene is
/// composited by one SceneOutput per output (each view owns its own
/// camera, damage ring, presented list and wl_output association).
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
    /// The scene's output views (SceneOutput.create registers itself):
    /// the surface enter/leave association and the culling rect of
    /// every tracked surface resolve against these.
    scene_outputs: std.ArrayList(*SceneOutput) = .empty,
    /// The compositor's subcompositor: subsurface tree parenting (set by
    /// the compositor; null = no subsurface support).
    subcompositor: ?*subsurface_mod.Subcompositor = null,
    /// Borrowed compositor policy, used for membership, presentation and
    /// damage. Clear it before its context is destroyed.
    placement_ctx: ?*anyopaque = null,
    placement_fn: ?*const fn (?*anyopaque, *surface_mod.Surface) SurfacePlacement = null,
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

    pub fn setSurfacePlacementPolicy(
        self: *Scene,
        ctx: ?*anyopaque,
        classify: ?*const fn (?*anyopaque, *surface_mod.Surface) SurfacePlacement,
    ) void {
        self.placement_ctx = ctx;
        self.placement_fn = classify;
    }

    pub fn surfacePlacement(self: *const Scene, surface: *surface_mod.Surface) SurfacePlacement {
        const classify = self.placement_fn orelse return .world;
        return classify(self.placement_ctx, surface);
    }

    /// Destroy the scene: every tracked surface binding first (their
    /// nodes + surface listeners), then every node and the scene itself.
    /// The compositor may destroy its surfaces after the scene, so the
    /// surface destroy signals must not reach freed bindings.
    pub fn deinit(scene: *Scene) void {
        surface_node_mod.untrackAll(scene);
        scene.surface_nodes.deinit();
        scene.scene_outputs.deinit(scene.allocator);
        scene.root.destroy(scene.allocator);
        const allocator = scene.allocator;
        allocator.destroy(scene);
    }

    /// Topmost drawable node whose world rect contains the f64 world
    /// point (x, y): the seat's hit test. The point arrives in the same
    /// space absolutePosition() reports — the caller converts screen px
    /// through the view's camera first, in f64. Walks children in
    /// reverse draw order (the last child draws on top); skips disabled
    /// and non-pickable nodes and their subtrees. Returns only .buffer
    /// nodes (surface content) — rect nodes are decoration. Null when
    /// the point hits nothing.
    pub fn pick(scene: *Scene, x: f64, y: f64) ?*SceneNode {
        return pickNode(scene.root, x, y);
    }
};

/// A node in the scene tree. Position (x/y) is the node's offset from
/// its parent in WORLD pixels: f64, so a surface can be placed between
/// two pixels and a whole chain of fractional offsets still sums exactly.
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
    /// World position relative to the parent, in world px (f64).
    x: f64 = 0,
    y: f64 = 0,

    /// Move the node to a world position relative to its parent. The
    /// placement pass uses this instead of writing x/y directly, so a
    /// move is one call site and the f64 type is stated once.
    pub fn setPosition(node: *SceneNode, x: f64, y: f64) void {
        node.x = x;
        node.y = y;
    }

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
        // Explicit drain: pop each child off the list (detaching it),
        // then destroy it. Destroying a child re-enters the parent
        // through its link, so the pop-destroy form keeps the list
        // mutation visible to static analysis — no child is freed while
        // still referenced by node.children.
        while (node.children.pop()) |child| {
            child.parent = null;
            child.destroy(allocator);
        }
        node.children.deinit(allocator);
        switch (node.kind) {
            .tree => allocator.destroy(node),
            .buffer => |bn| allocator.destroy(bn),
            .rect => |rn| allocator.destroy(rn),
        }
    }

    /// Bounding rect in WORLD space: the sum of all ancestor x/y
    /// (including this node), summed in f64, as origin, sized by the
    /// node's own extent (tree nodes have zero size; buffer nodes use
    /// dst_size, falling back to the texture size; rect nodes use their
    /// width/height). The size is widened from the integer dst/size
    /// fields here — the world boundary is the one place the protocol's
    /// integer geometry becomes f64.
    pub fn absolutePosition(node: *const SceneNode) FRect {
        var x = node.x;
        var y = node.y;
        var parent = node.parent;
        while (parent) |p| : (parent = p.parent) {
            x += p.x;
            y += p.y;
        }
        const size: geom.Size = switch (node.kind) {
            .tree => .{ .w = 0, .h = 0 },
            .buffer => |bn| .{
                .w = if (bn.dst_width != 0) bn.dst_width else if (bn.texture) |texture| texture.width else 0,
                .h = if (bn.dst_height != 0) bn.dst_height else if (bn.texture) |texture| texture.height else 0,
            },
            .rect => |rn| .{ .w = rn.width, .h = rn.height },
        };
        return .{
            .x = x,
            .y = y,
            .width = @floatFromInt(size.w),
            .height = @floatFromInt(size.h),
        };
    }
};

/// Recursive hit test in world space: children in reverse draw order;
/// tree nodes recurse, buffer nodes win on containment (half-open, at
/// the node's fractional edges), rect nodes are skipped.
fn pickNode(node: *SceneNode, x: f64, y: f64) ?*SceneNode {
    var i = node.children.items.len;
    while (i > 0) {
        i -= 1;
        const child = node.children.items[i];
        if (!child.enabled or !child.pickable) continue;
        if (child.kind == .tree) {
            if (pickNode(child, x, y)) |hit| return hit;
            continue;
        }
        if (child.kind == .buffer and child.absolutePosition().containsPoint(x, y)) return child;
    }
    return null;
}

/// Texture blit node: draws `texture` at the node's world position,
/// sized dst_width x dst_height (0 = texture size, 1:1), at `opacity`.
pub const SceneBufferNode = struct {
    node: SceneNode,
    texture: ?*texture_mod.Texture = null,
    /// RAW BUFFER-pixel crop of the texture (null = whole texture). A
    /// wp_viewport source arrives surface-local; the binding that
    /// publishes it multiplies by buffer_scale and inverse-transforms it
    /// into buffer pixels, so the renderer samples buffer texels and
    /// never applies the crop twice.
    src: ?FRect = null,
    /// The surface's wl_output_transform for this draw (buffer ->
    /// surface). buffer_scale is already folded into `src` and the dst
    /// size, so this is the raw buffer -> surface map alone.
    transform: geom.Transform = .normal,
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

/// ONE view of the shared scene tree onto one output. Everything that
/// used to be a single-output decision lives here, per output: the world
/// origin (x/y) used when the view has no camera, the camera itself
/// (borrowed), the wl_output global the enter/leave wire events ride,
/// the frame's presented list and the damage ring.
///
/// `render` composites the tree into the renderer target for this
/// output. The damage ring tracks what changed ON THIS OUTPUT: the
/// compositor accumulates per-surface damage via addDamage before
/// render, rotates the ring after render, and reads the frame's rects
/// back via takeDamage for the output commit.
pub const SceneOutput = struct {
    output: *output_mod.Output,
    scene: *Scene,
    damage_ring: damage_mod.DamageRing,
    /// World position of this view's screen (0,0). Used as the view's
    /// world rect origin when no camera is installed.
    x: f64 = 0,
    y: f64 = 0,
    /// The output view's camera, BORROWED from its canonical owner (the
    /// server's per-output view). Null = a camera-less view: world
    /// coordinates are screen coordinates offset by (x, y). Only read.
    camera: ?*const Camera = null,
    /// This output's wl_output global. The surface enter/leave wire
    /// events go to the resources its own client bound here — an event
    /// for output A never rides output B's global.
    wl_output: ?*wl_output_mod.WlOutput = null,
    /// This frame's presented surfaces (presentation feedback targets)
    /// for THIS output, rebuilt per frame by collectPresented.
    presented: std.ArrayList(*surface_mod.Surface) = .empty,
    /// output.events.destroy: the output died, so `output` dangles.
    /// The handler revokes every membership this view carried — while
    /// the view is still resolvable, so the real wl_surface.leave can
    /// ride this output's own wl_output — then tombstones the view and
    /// detaches it from the scene. It does NOT free the view: its owner
    /// frees it exactly once through destroy(), so a listener ordering
    /// difference cannot double-free it.
    destroy_listener: wire.Listener(*output_mod.Output),
    /// False once this view is dead (its output died, or destroy ran).
    /// `output` must not be dereferenced while this is false, and the
    /// view is no longer in the scene's output list.
    live: bool = true,

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
        // The ring owns two allocations (the history slot array and the
        // slot's rect list); acquire it before the struct so a failure
        // here leaks nothing.
        var ring = try damage_mod.DamageRing.init(allocator, 2);
        errdefer ring.deinit();
        self.* = .{
            .output = output,
            .scene = scene,
            .damage_ring = ring,
            .x = 0,
            .y = 0,
            .camera = null,
            .wl_output = null,
            .presented = .empty,
            .destroy_listener = wire.Listener(*output_mod.Output).init(onOutputDestroy),
            .live = true,
        };
        // Join the scene BEFORE the output can call back into this view:
        // a destroy listener left on a view create then failed would run
        // against freed memory when the output is destroyed. Nothing
        // below this append can fail, so no rollback is needed.
        try scene.scene_outputs.append(allocator, self);
        output.events.destroy.add(&self.destroy_listener);
        log.debug(
            "scene output created for output {d}x{d}",
            io,
            log_cfg,
            "scene",
            .{ output.width, output.height },
        );
        return self;
    }

    /// Destroy this output view: revoke the memberships it carried, then
    /// free its damage ring and presented list and drop it from the
    /// scene. The scene tree is NOT freed — a scene is shared across
    /// outputs, call Scene.deinit for that.
    ///
    /// FREES `so`. It is not idempotent: the view's owner calls this
    /// exactly once, whether the output died first or not (after the
    /// output died, live == false and the memberships are already gone).
    pub fn destroy(so: *SceneOutput) void {
        const scene = so.scene;
        const allocator = scene.allocator;
        // The leave events must name THIS output on the wire, so they go
        // out while the view is still live, still registered and still
        // carries its wl_output (see revokeMemberships).
        so.revokeMemberships();
        so.live = false;
        if (so.destroy_listener.link.prev != null) so.destroy_listener.link.remove();
        so.camera = null;
        so.wl_output = null;
        so.damage_ring.deinit();
        so.presented.deinit(allocator);
        // Unregister from the scene (surface enter/leave association and
        // culling iterate scene_outputs).
        so.unregister();
        allocator.destroy(so);
    }

    /// Revoke every tracked surface's membership in THIS view's output.
    ///
    /// Surface.leaveOutput fires the surface's leave signal, and the
    /// surface node's listener turns that into a real wl_surface.leave
    /// naming the output — but only while this view is still resolvable
    /// (sceneOutputFor) and still carries its wl_output. That is why the
    /// revocation runs FIRST, before live=false, before the borrowed
    /// pointers are dropped and before the view leaves the scene.
    ///
    /// The output association also listens for the output's death on its
    /// own; whichever order the two listeners are linked in, the second
    /// one finds nothing left to revoke, so the client hears exactly one
    /// leave per lost output either way. A no-op once the view is dead:
    /// `output` dangles from then on.
    fn revokeMemberships(so: *SceneOutput) void {
        if (!so.live) return;
        const out = so.output;
        var it = so.scene.surface_nodes.valueIterator();
        while (it.next()) |sn| {
            const surface = sn.*.surface;
            if (surface.hasOutput(out)) surface.leaveOutput(out);
        }
    }

    /// Drop this view from the scene's output list. Idempotent.
    fn unregister(so: *SceneOutput) void {
        const scene = so.scene;
        if (std.mem.findScalar(*SceneOutput, scene.scene_outputs.items, so)) |idx| {
            _ = scene.scene_outputs.orderedRemove(idx);
        }
    }

    /// The world rect this view can show: the camera's visible world
    /// rect when it has one (the culling frustum AND the membership
    /// test), else the output's rectangle placed at the view's world
    /// origin.
    pub fn visibleWorldRect(so: *const SceneOutput) FRect {
        if (so.camera) |cam| return cam.visibleWorldRect();
        return .{
            .x = so.x,
            .y = so.y,
            .width = @floatFromInt(so.output.width),
            .height = @floatFromInt(so.output.height),
        };
    }

    /// Map a world point to this output's screen px. With a camera the
    /// subtraction happens inside the f64 transform (so a world point
    /// 1e9 px from the origin never reaches an f32 as an absolute
    /// coordinate); without one the view's world origin is subtracted.
    pub fn worldToScreen(so: *const SceneOutput, wx: f64, wy: f64) geom.FPoint {
        if (so.camera) |cam| return cam.worldToScreen(wx, wy);
        return .{ .x = wx - so.x, .y = wy - so.y };
    }

    /// This output's screen in screen px: (0, 0, width, height).
    pub fn screenBounds(so: *const SceneOutput) FRect {
        return .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(so.output.width),
            .height = @floatFromInt(so.output.height),
        };
    }

    /// Project a WORLD rect into this output's screen pixels: the four
    /// world corners through worldToScreen, their screen-space bounding
    /// box, clipped to the screen in f64, and only then narrowed to whole
    /// pixels (origin floors, far edges ceil).
    ///
    /// The clip-before-narrow order is the contract: a world rect a
    /// billion pixels off-screen saturates onto the screen edge when it
    /// is narrowed first, which would report damage or a drawn quad on an
    /// edge the output never had. Null when nothing lands on screen.
    pub fn projectWorldRect(so: *const SceneOutput, world: FRect) ?Rect {
        if (world.isEmpty()) return null;
        const corners = [_]geom.FPoint{
            so.worldToScreen(world.x, world.y),
            so.worldToScreen(world.right(), world.y),
            so.worldToScreen(world.x, world.bottom()),
            so.worldToScreen(world.right(), world.bottom()),
        };
        var min_x = corners[0].x;
        var min_y = corners[0].y;
        var max_x = corners[0].x;
        var max_y = corners[0].y;
        for (corners[1..]) |c| {
            min_x = @min(min_x, c.x);
            min_y = @min(min_y, c.y);
            max_x = @max(max_x, c.x);
            max_y = @max(max_y, c.y);
        }
        const screen: FRect = .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
        const clipped = screen.intersect(so.screenBounds()) orelse return null;
        return clipped.toPixelRect();
    }

    /// Accumulate `rect` (in output/screen coordinates) into this
    /// frame's damage. Called by the compositor for every damaged
    /// surface region (and cursor move) before render; takeDamage after
    /// rotate carries the frame's region to the output commit
    /// (wlr_damage_ring_add_box, types/wlr_damage_ring.c:40).
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

    /// Composite the scene into the renderer target (framebuffer) for
    /// this output: walk the tree, cull nodes outside this view's
    /// visible world rect, draw rect nodes via add_rect and buffer nodes
    /// via add_texture, submit.
    pub fn render(so: *SceneOutput, renderer: *renderer_mod.Renderer, target: *anyopaque) void {
        std.debug.assert(so.live);
        std.debug.assert(so.output.width > 0);
        std.debug.assert(so.output.height > 0);
        const visible = so.visibleWorldRect();
        const pass = renderer.beginPass(target) orelse {
            log.trace("render: target unsupported, skipping", so.scene.io, so.scene.log_cfg, "scene", .{});
            return;
        };
        defer pass.submit();
        renderNode(pass, so.scene.root, visible, true);
    }
};

/// The output died: `so.output` dangles from here on. The memberships
/// this view carried are revoked FIRST, while the view is still live,
/// still in the scene's output list and still carries its wl_output, so
/// each surface's client hears a real wl_surface.leave naming THAT
/// output. Then the view is tombstoned: it stops referencing the output
/// and leaves the scene's output list. The view itself stays allocated
/// — its owner frees it through SceneOutput.destroy, so a listener order
/// that frees it before this runs cannot double-free it.
fn onOutputDestroy(listener: *wire.Listener(*output_mod.Output), _: *output_mod.Output) void {
    const so: *SceneOutput = @fieldParentPtr("destroy_listener", listener);
    so.revokeMemberships();
    so.live = false;
    so.camera = null;
    so.wl_output = null;
    so.presented.clearRetainingCapacity();
    so.unregister();
}

fn renderNode(pass: *pass_mod.Pass, node: *SceneNode, visible: FRect, ancestors_enabled: bool) void {
    const shown = ancestors_enabled and node.enabled;
    if (!shown) return;
    switch (node.kind) {
        .tree => {},
        .buffer => |bn| renderBuffer(pass, node, bn, visible),
        .rect => |rn| renderRect(pass, node, rn, visible),
    }
    for (node.children.items) |child| renderNode(pass, child, visible, shown);
}

fn renderBuffer(pass: *pass_mod.Pass, node: *const SceneNode, bn: *SceneBufferNode, visible: FRect) void {
    const texture = bn.texture orelse return;
    const world = node.absolutePosition();
    // Cull in world space in f64: a node whose fractional rect misses the
    // view is dropped, and one that only half lands still draws with its
    // exact world rect (dst is never narrowed here — the renderer owns
    // the projection into its target).
    if (!visible.intersects(world)) return;
    pass.addTexture(texture, .{
        .src = bn.src,
        .dst = world,
        .alpha = bn.opacity,
        .transform = bn.transform,
    });
}

fn renderRect(pass: *pass_mod.Pass, node: *const SceneNode, rn: *SceneRectNode, visible: FRect) void {
    if (rn.width <= 0 or rn.height <= 0) return;
    const world = node.absolutePosition();
    if (!visible.intersects(world)) return;
    pass.addRect(world, rn.color);
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
    t1.setPosition(10, 20);

    // Buffer: position + texture size when dst unset.
    var dummy: DummyTexture = .{};
    var tex: texture_mod.Texture = .{ .impl = &dummy_texture_impl, .data = &dummy, .width = 64, .height = 32 };
    const buf = try SceneNode.create(allocator, t1, .buffer);
    buf.setPosition(5, 7);
    buf.kind.buffer.texture = &tex;
    try testing.expectEqual(FRect{ .x = 15, .y = 27, .width = 64, .height = 32 }, buf.absolutePosition());

    // dst_size overrides the texture size.
    buf.kind.buffer.dst_width = 128;
    buf.kind.buffer.dst_height = 96;
    try testing.expectEqual(FRect{ .x = 15, .y = 27, .width = 128, .height = 96 }, buf.absolutePosition());
    buf.kind.buffer.dst_width = 0;
    buf.kind.buffer.dst_height = 0;

    // Rect: position + own size.
    const rect_node = try SceneNode.create(allocator, t1, .rect);
    rect_node.setPosition(3, 4);
    rect_node.kind.rect.width = 100;
    rect_node.kind.rect.height = 50;
    try testing.expectEqual(FRect{ .x = 13, .y = 24, .width = 100, .height = 50 }, rect_node.absolutePosition());

    // Tree nodes have zero size.
    try testing.expectEqual(FRect{ .x = 10, .y = 20, .width = 0, .height = 0 }, t1.absolutePosition());
    try testing.expectEqual(FRect{ .x = 0, .y = 0, .width = 0, .height = 0 }, scene.root.absolutePosition());

    // Negative and fractional offsets accumulate too: the world is f64,
    // so a node placed between pixels keeps its fraction.
    const t2 = try SceneNode.create(allocator, scene.root, .tree);
    t2.setPosition(-10.5, -10.25);
    try testing.expectEqual(FRect{ .x = -10.5, .y = -10.25, .width = 0, .height = 0 }, t2.absolutePosition());
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

test "two outputs keep independent views, damage and projection" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();
    const first = try makeOutput(allocator, &io, &log_cfg);
    const second = try makeOutput(allocator, &io, &log_cfg);
    // Registered backend-first so LIFO teardown destroys each output
    // BEFORE its backend (the views' own defers, registered later, run
    // before both).
    defer first[1].destroy();
    defer first[0].destroy();
    defer second[1].destroy();
    defer second[0].destroy();

    // The left view is camera-less at the world origin; the right one
    // pans its camera to the far side of the world. Neither shares state
    // with the other: separate cameras, separate damage rings, separate
    // presented lists.
    // Not deferred: the test destroys this view explicitly at the end to
    // observe the survivor, and a double free is worse than a leak report
    // on an early test failure.
    const so_left = try SceneOutput.create(allocator, &io, &log_cfg, scene, first[0]);
    var cam: Camera = .{
        .center_x = 5_000_000_000.5,
        .center_y = 0,
        .zoom = 1,
        .rotation = 0,
        .screen_w = 800,
        .screen_h = 600,
    };
    const so_right = try SceneOutput.create(allocator, &io, &log_cfg, scene, second[0]);
    defer so_right.destroy();
    so_right.camera = &cam;
    try testing.expectEqual(@as(usize, 2), scene.scene_outputs.items.len);
    try testing.expect(so_left.camera == null);
    try testing.expect(so_right.camera == &cam);

    // The camera-less view's world rect is its origin rectangle; the
    // camera view's is the camera's frustum (centred on the far world
    // point, not the origin).
    try testing.expectEqual(
        FRect{ .x = 0, .y = 0, .width = 800, .height = 600 },
        so_left.visibleWorldRect(),
    );
    try testing.expect(so_right.visibleWorldRect().x > 4_999_999_600);

    // A world rect at the origin lands on the left view's screen but not
    // the right one (whose camera is 5e9 away).
    const origin_rect: FRect = .{ .x = 10, .y = 20, .width = 100, .height = 50 };
    try testing.expectEqual(
        Rect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        so_left.projectWorldRect(origin_rect).?,
    );
    try testing.expect(so_right.projectWorldRect(origin_rect) == null);
    // ...and a rect at the camera's far world centre lands on the right
    // view's screen but not the left.
    const far_rect: FRect = .{
        .x = cam.center_x,
        .y = 0,
        .width = 100,
        .height = 50,
    };
    try testing.expect(so_left.projectWorldRect(far_rect) == null);
    // The camera centre maps to the screen centre (400, 300); the rect is
    // 100x50 extending right and down from it.
    try testing.expectEqual(
        Rect{ .x = 400, .y = 300, .width = 100, .height = 50 },
        so_right.projectWorldRect(far_rect).?,
    );

    // A fractional world edge covers the pixel box that contains it.
    const frac: FRect = .{ .x = 10.25, .y = 20.75, .width = 3.5, .height = 2.5 };
    try testing.expectEqual(
        Rect{ .x = 10, .y = 20, .width = 4, .height = 4 },
        so_left.projectWorldRect(frac).?,
    );

    // Damage rings are per view: damaging the left one leaves the right
    // one empty.
    so_left.addDamage(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    so_right.addDamage(.{ .x = 50, .y = 60, .width = 7, .height = 8 });
    so_left.damage_ring.rotate();
    so_right.damage_ring.rotate();
    try testing.expectEqual(@as(usize, 1), so_left.takeDamage().len);
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .width = 3, .height = 4 }, so_left.takeDamage()[0]);
    try testing.expectEqual(@as(usize, 1), so_right.takeDamage().len);
    try testing.expectEqual(Rect{ .x = 50, .y = 60, .width = 7, .height = 8 }, so_right.takeDamage()[0]);

    // Destroying one view leaves the other and the scene intact.
    so_left.destroy();
    try testing.expectEqual(@as(usize, 1), scene.scene_outputs.items.len);
    try testing.expect(so_right.live);
}

test "scene rendering respects visibility and pixel-centre rectangle coverage" {
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

    const hidden_tree = try SceneNode.create(allocator, scene.root, .tree);
    hidden_tree.enable(false);
    const hidden = try SceneNode.create(allocator, hidden_tree, .rect);
    hidden.kind.rect.width = 4;
    hidden.kind.rect.height = 4;
    hidden.kind.rect.color = .{ 0, 1, 0, 1 };
    const empty = try SceneNode.create(allocator, scene.root, .rect);
    empty.kind.rect.color = .{ 0, 0, 1, 1 };
    const visible = try SceneNode.create(allocator, scene.root, .rect);
    visible.setPosition(0.75, 0.75);
    visible.kind.rect.width = 2;
    visible.kind.rect.height = 2;
    visible.kind.rect.color = .{ 1, 0, 0, 1 };

    const pixman = @import("../renderer/pixman.zig");
    const renderer = try pixman.PixmanRenderer.create(allocator, &io, &log_cfg);
    defer renderer.destroy();
    const fb = try pixman.Framebuffer.create(allocator, 4, 4);
    defer fb.deinit();
    so.render(renderer, fb);
    for (0..4) |y| {
        for (0..4) |x| {
            const want: [4]u8 = if (x >= 1 and x <= 2 and y >= 1 and y <= 2)
                .{ 0, 0, 255, 255 }
            else
                .{ 0, 0, 0, 0 };
            try testing.expectEqual(want, fb.pixelAt(@intCast(x), @intCast(y)));
        }
    }
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

fn allocationFailureOutputLifecycle(allocator: std.mem.Allocator) !void {
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };
    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();
    const created = try makeOutput(allocator, &io, &log_cfg);
    defer created[1].destroy();
    const out = created[0];
    var output_live = true;
    defer if (output_live) out.destroy();
    const so = try SceneOutput.create(allocator, &io, &log_cfg, scene, out);
    defer so.destroy();

    so.x = 5_000_000_000.25;
    so.y = -5_000_000_000.5;
    const projected = so.projectWorldRect(.{
        .x = 5_000_000_007.5,
        .y = -4_999_999_996.0,
        .width = 10.5,
        .height = 7.5,
    }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Rect{ .x = 7, .y = 4, .width = 11, .height = 8 }, projected);
    out.destroy();
    output_live = false;
    try testing.expect(!so.live);
}

test "output view allocation failures leave output destruction safe" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailureOutputLifecycle, .{});
}



test "absolutePosition keeps fractional world coords at far-from-origin nodes" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    // World coordinates carry fractions at ANY magnitude. The world is
    // 5e9 px from the origin — past INT32_MAX, where an integer world
    // cannot even hold the position, let alone a quarter pixel inside
    // it — and every level of the tree carries a fraction, so the sum
    // is right only if all of them are. At 5e9 one f64 ulp is ~1e-6, so
    // the tolerance below is a few ulp: orders of magnitude tighter than
    // the whole-pixel snap an integer world imposes.
    const far_x: f64 = 5_000_000_000.5;
    const far_y: f64 = -5_000_000_000.75;
    const half: f64 = 0.5;
    const quarter: f64 = 0.25;
    const eighth: f64 = 0.125;

    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();

    var dummy: DummyTexture = .{};
    var tex: texture_mod.Texture = .{ .impl = &dummy_texture_impl, .data = &dummy, .width = 64, .height = 32 };

    // root -> far -> quarter -> eighth -> buffer.
    const far = try SceneNode.create(allocator, scene.root, .tree);
    far.setPosition(far_x, far_y);
    const quarter_tree = try SceneNode.create(allocator, far, .tree);
    quarter_tree.setPosition(quarter, quarter);
    const eighth_tree = try SceneNode.create(allocator, quarter_tree, .tree);
    eighth_tree.setPosition(eighth, eighth);
    const buf = try SceneNode.create(allocator, eighth_tree, .buffer);
    buf.setPosition(quarter, eighth);
    buf.kind.buffer.texture = &tex;

    // x: 5000000000.5 + 0.25 + 0.125 + 0.25 = 5000000001.125
    // y: -5000000000.75 + 0.25 + 0.125 + 0.125 = -5000000000.25
    const abs = buf.absolutePosition();
    try testing.expectApproxEqAbs(5_000_000_001.125, abs.x, 1e-3);
    try testing.expectApproxEqAbs(-5_000_000_000.25, abs.y, 1e-3);
    // The world really is past the old integer limit — the case an
    // integer accumulator could not represent at all.
    try testing.expect(abs.x > @as(f64, std.math.maxInt(i32)));
    try testing.expect(abs.y < @as(f64, std.math.minInt(i32)));
    // The node's own extent is exact: it comes from the integer dst
    // fields, widened once at the world boundary.
    try testing.expectEqual(@as(f64, 64), abs.width);
    try testing.expectEqual(@as(f64, 32), abs.height);

    // The same accumulation near the origin, where every value is
    // exactly representable: 0.5 + 0.25 + 0.125 must not collapse to a
    // whole pixel.
    const near = try SceneNode.create(allocator, scene.root, .tree);
    near.setPosition(half, half);
    const near_mid = try SceneNode.create(allocator, near, .tree);
    near_mid.setPosition(quarter, quarter);
    const near_buf = try SceneNode.create(allocator, near_mid, .buffer);
    near_buf.setPosition(eighth, eighth);
    near_buf.kind.buffer.dst_width = 12;
    near_buf.kind.buffer.dst_height = 8;

    const near_abs = near_buf.absolutePosition();
    try testing.expectEqual(@as(f64, 0.875), near_abs.x);
    try testing.expectEqual(@as(f64, 0.875), near_abs.y);
    try testing.expectEqual(@as(f64, 12), near_abs.width);
    try testing.expectEqual(@as(f64, 8), near_abs.height);
}

test "pick hit-tests fractional world placement and returns the topmost node" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    // The literals are the world points and edges the hit test must use.
    // A world rect is half-open: the left/top edge is inside, the
    // right/bottom edge is not.
    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();

    var dummy: DummyTexture = .{};
    var tex: texture_mod.Texture = .{ .impl = &dummy_texture_impl, .data = &dummy, .width = 64, .height = 32 };

    // World rects: back [4.5, 24.5)², front [12.5, 32.5)²,
    // nested [111, 121) x [220.375, 230.375).
    // Two overlapping surfaces; front is appended last, so it draws on
    // top and owns the overlap.
    const back = try SceneNode.create(allocator, scene.root, .buffer);
    back.setPosition(4.5, 4.5);
    back.kind.buffer.texture = &tex;
    back.kind.buffer.dst_width = 20;
    back.kind.buffer.dst_height = 20;

    const front = try SceneNode.create(allocator, scene.root, .buffer);
    front.setPosition(12.5, 12.5);
    front.kind.buffer.texture = &tex;
    front.kind.buffer.dst_width = 20;
    front.kind.buffer.dst_height = 20;

    // A surface nested under an offset tree: the hit test must add the
    // ancestors' fractions, not just the node's own.
    const tree = try SceneNode.create(allocator, scene.root, .tree);
    tree.setPosition(100.5, 200.25);
    const nested = try SceneNode.create(allocator, tree, .buffer);
    nested.setPosition(10.5, 20.125);
    nested.kind.buffer.texture = &tex;
    nested.kind.buffer.dst_width = 10;
    nested.kind.buffer.dst_height = 10;

    // The overlap belongs to the topmost drawable node.
    try testing.expect(scene.pick(15.0, 15.0) == front);
    // A band only one node covers selects that node.
    try testing.expect(scene.pick(5.0, 5.0) == back);
    try testing.expect(scene.pick(111.0, 220.375) == nested);

    // The fractional left/top edge is inside the rect; the right/bottom
    // edge is not (the rect is half-open).
    try testing.expect(scene.pick(4.5, 5.0) == back);
    try testing.expect(scene.pick(24.5, 5.0) == null);
    // A quarter world px left of that edge is outside it: the hit test
    // must not round a node's edge down to a whole pixel.
    try testing.expect(scene.pick(4.25, 5.0) == null);

    // The nested chain, same two rules against the fractional origin
    // the ancestor offsets produce (100.5 + 10.5 = 111,
    // 200.25 + 20.125 = 220.375).
    try testing.expect(scene.pick(121.0, 220.5) == null);
    try testing.expect(scene.pick(110.5, 220.5) == null);

    // Decoration is not a hit target: a rect drawn over the overlap does
    // not steal the seat's pick.
    const decoration = try SceneNode.create(allocator, scene.root, .rect);
    decoration.setPosition(15.0, 15.0);
    decoration.kind.rect.width = 200;
    decoration.kind.rect.height = 200;
    try testing.expect(scene.pick(15.0, 15.0) == front);

    // A disabled or non-pickable surface is transparent to the seat:
    // the node below it is the hit.
    front.enable(false);
    try testing.expect(scene.pick(15.0, 15.0) == back);
    front.enable(true);
    front.pickable = false;
    try testing.expect(scene.pick(15.0, 15.0) == back);
}

test "pick hit-tests a surface far from the origin at fractional edges" {
    const allocator = testing.allocator;
    var io_impl: std.Io.Threaded = .init_single_threaded;
    var io = io_impl.io();
    var log_cfg: log.Config = .{ .min_level = .err };

    // A surface 7e9 px from the origin, where one f64 ulp is ~1e-6 and
    // an integer world cannot hold the position at all. Every probe sits
    // a quarter world pixel from one of its edges: narrowing either side
    // first collapses each probe onto the edge and the hit test has no
    // answer left.
    const scene = try makeScene(allocator, &io, &log_cfg);
    defer scene.deinit();

    var dummy: DummyTexture = .{};
    var tex: texture_mod.Texture = .{ .impl = &dummy_texture_impl, .data = &dummy, .width = 64, .height = 32 };

    const origin_x: f64 = 7_000_000_000.5;
    const origin_y: f64 = -3_000_000_000.25;
    const far = try SceneNode.create(allocator, scene.root, .buffer);
    far.setPosition(origin_x, origin_y);
    far.kind.buffer.texture = &tex;
    far.kind.buffer.dst_width = 40;
    far.kind.buffer.dst_height = 40;

    // Inside: a quarter world px inside the far edge is a hit.
    try testing.expect(scene.pick(origin_x + 39.75, origin_y + 39.75) == far);
    // The edge itself and a quarter pixel beyond it are not.
    try testing.expect(scene.pick(origin_x + 40, origin_y + 20) == null);
    try testing.expect(scene.pick(origin_x + 40.25, origin_y + 20) == null);
    // The same rules on the near edges.
    try testing.expect(scene.pick(origin_x + 0.25, origin_y + 20) == far);
    try testing.expect(scene.pick(origin_x - 0.25, origin_y + 20) == null);
}

