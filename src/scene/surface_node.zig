//! SurfaceNode: bind a wl_surface to a scene node (the wlr_scene_surface
//! analogue, types/scene/surface.c). The library's surface→scene table.
//!
//! The binding owns the surface→node lifecycle: trackSurface subscribes
//! the surface's commit/unmap/destroy signals (plus the enter/leave
//! signals the surface module emits), and the node follows the surface —
//! attach a texture node on the first buffer commit, update it on later
//! commits, detach on unmap, full teardown on destroy. The compositor
//! keeps only policy: which surfaces get bindings (the trackSurface call
//! sites), where the nodes are placed (tree/node x/y), and what the
//! damage is (addDamage translates the surface's committed damage through
//! the node).
//!
//! The renderer-specific part — turning the surface's current buffer into
//! a texture — is delegated to the Impl (import + an optional in-place
//! update fast path). Two compositor policy hooks ride the Impl too:
//! before_update (runs before every commit sync, e.g. subsurface orphan
//! recovery) and destroyed (compositor-side cleanup at surface death,
//! e.g. seat focus + presentation feedback).
//!
//! Enter/leave (note 135 O20): the scene knows which output a node is on.
//! At attach the node computes the first scene output whose rect its
//! absolute rect intersects and drives surface.setEntered; at detach it
//! drives setLeft. The surface module emits its enter/leave signals on
//! the change; the binding's listeners send the wl_surface.enter/leave
//! wire events to the surface's client (via the scene's wl_output global;
//! a client that never bound wl_output gets none, mirroring wlroots
//! wlr_surface_send_enter/leave, wlr_compositor.c:1071-1128).
//!
//! Imports: utils/*, core/wire.zig, buffers/*, compositor/* (surface,
//! subsurface), output/*, scene/scene.zig.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const matrix = @import("../utils/matrix.zig");
const scene_mod = @import("scene.zig");
const surface_mod = @import("../compositor/surface.zig");
const subsurface_mod = @import("../compositor/subsurface.zig");
const output_mod = @import("../output/output.zig");
const buffer_mod = @import("../buffers/buffer.zig");
// Imported for the test blocks (fabricated textures).
const texture_mod = @import("../renderer/texture.zig");

const Rect = geom.Rect;
const Scene = scene_mod.Scene;
const SceneNode = scene_mod.SceneNode;
const SceneOutput = scene_mod.SceneOutput;
const Surface = surface_mod.Surface;
const Subcompositor = subsurface_mod.Subcompositor;
const Buffer = buffer_mod.Buffer;
const Texture = texture_mod.Texture;

/// The renderer/texture integration + compositor policy hooks for a
/// SurfaceNode. `ctx` is the compositor's opaque context (the ServerState
/// in the test server).
pub const Impl = struct {
    /// Import the surface's current buffer into a texture owned by the
    /// node (the node destroys it on replacement/unmap). Null when no
    /// texture could be produced: the surface stays without content
    /// (a previous node, if any, is left in place).
    import: *const fn (ctx: *anyopaque, surface: *Surface, buf: *Buffer) ?*Texture,
    /// Update `texture` in place from the surface's current buffer; return
    /// true when the texture now shows the buffer (no re-import needed).
    /// Null = always re-import. The per-frame hot path: same-size commits
    /// avoid the alloc + texture churn.
    update: ?*const fn (ctx: *anyopaque, texture: *Texture, surface: *Surface, buf: *Buffer) bool = null,
    /// Compositor policy before the node syncs from the surface's current
    /// buffer on every commit (e.g. subsurface orphan recovery: re-root a
    /// surface whose wl_subsurface died).
    before_update: ?*const fn (ctx: *anyopaque, sn: *SurfaceNode) void = null,
    /// The surface is being destroyed and its binding is about to tear
    /// down: compositor-side cleanup (seat focus, presentation feedback).
    /// The surface is still valid inside the destroy signal.
    destroyed: ?*const fn (ctx: *anyopaque, surface: *Surface) void = null,
};

/// A tracked wl_surface: its scene tree container (`tree`, under
/// scene.root for plain surfaces, under the PARENT surface's tree for
/// subsurfaces) and its buffer node (`node`, the tree's first child —
/// what the seat picks and the canvas draws). Both null while unmapped.
///
/// The scene registry (Scene.surface_nodes) owns the bindings: track
/// surfaces with trackSurface, tear down with destroy (the destroy
/// listener) or Scene.deinit (untrackAll).
pub const SurfaceNode = struct {
    scene: *Scene,
    surface: *Surface,
    impl: *const Impl,
    ctx: *anyopaque,
    /// The .tree container holding `node` (and, for non-subsurfaces, the
    /// subtrees of this surface's subsurfaces). Null while unmapped.
    tree: ?*SceneNode = null,
    /// The surface's buffer node (the tree's first child). Null while
    /// unmapped.
    node: ?*SceneNode = null,
    commit_listener: wire.Listener(*Surface),
    destroy_listener: wire.Listener(*Surface),
    /// wl_surface.unmap signal listener: drops the scene node when the
    /// surface stops being mapped. Covers the forced-unmap path (a
    /// destroyed wl_subsurface unmaps its child, note 132 F6) that has
    /// no commit to carry it; idempotent with the commit path (detach
    /// nulls the node/tree slots).
    unmap_listener: wire.Listener(*Surface),
    /// wl_surface.enter/leave signal listeners (the surface module emits
    /// the signals on the output association changing; these send the
    /// wl_surface.enter/leave wire events — the per-output enter/leave
    /// emission hook).
    enter_listener: wire.Listener(*output_mod.Output),
    leave_listener: wire.Listener(*output_mod.Output),

    /// Sync the scene node from the surface's current buffer: update the
    /// texture in place when the impl's fast path succeeds, re-import
    /// otherwise, and create the tree + node on the first map. A null
    /// buffer detaches. Called from the commit listener and at
    /// trackSurface (the surface may have committed before being
    /// tracked).
    pub fn update(sn: *SurfaceNode) void {
        if (sn.impl.before_update) |f| f(sn.ctx, sn);
        const s = sn.surface;
        const buf = s.buffer orelse {
            log.debug("surfnode: no buffer", sn.scene.io, sn.scene.log_cfg, "surface_node", .{});
            sn.detach();
            return;
        };
        const size = surfaceSize(s, buf);
        if (sn.node) |node| {
            // Same-size commit: update the texture in place (no alloc, no
            // texture churn — the per-frame hot path). The dst rect is
            // still refreshed: scale/transform can change on a commit
            // that reuses the same buffer.
            const bn = node.kind.buffer;
            if (bn.texture) |tex| {
                if (sn.impl.update) |f| {
                    if (f(sn.ctx, tex, s, buf)) {
                        bn.dst_width = size.w;
                        bn.dst_height = size.h;
                        node.enable(true);
                        return;
                    }
                }
                tex.destroy();
                bn.texture = null;
            }
        }
        const texture = sn.impl.import(sn.ctx, s, buf) orelse return;
        if (sn.node) |node| {
            // Update in place: swap in the new texture (dst = surface
            // size).
            const bn = node.kind.buffer;
            if (bn.texture) |old| old.destroy();
            bn.texture = texture;
            bn.dst_width = size.w;
            bn.dst_height = size.h;
            node.enable(true);
        } else {
            // First map: create the tree container (under the parent
            // surface's tree for a subsurface, scene.root otherwise),
            // then the buffer node as its first child.
            sn.ensureTree();
            const tree = sn.tree orelse {
                texture.destroy();
                log.warn("scene tree create failed", sn.scene.io, sn.scene.log_cfg, "surface_node", .{});
                return;
            };
            const node = SceneNode.create(sn.scene.allocator, tree, .buffer) catch |err| {
                texture.destroy();
                log.warn(
                    "scene node create failed: {s}",
                    sn.scene.io,
                    sn.scene.log_cfg,
                    "surface_node",
                    .{@errorName(err)},
                );
                return;
            };
            node.kind.buffer.texture = texture;
            node.kind.buffer.dst_width = size.w;
            node.kind.buffer.dst_height = size.h;
            sn.node = node;

            // The surface maps on the output(s) its node intersects:
            // drive the surface's enter tracking (setEntered emits
            // events.enter on the change; the enter listener sends the
            // wire event). Idempotent — node creation happens exactly
            // once per map.
            sn.updateOutputs();
        }
    }

    /// Remove (and free) the surface's scene nodes; the binding keeps
    /// tracking the surface for a future remap. Idempotent.
    pub fn detach(sn: *SurfaceNode) void {
        const scene = sn.scene;
        // Detach this surface's subsurface trees first: node.destroy
        // cascades into the whole subtree, which would free the
        // children's nodes out from under their bindings. Reparent them
        // to the root, disabled; they re-enter the parent's tree when
        // the parent maps again. (On append OOM the cascade still frees
        // them — a catastrophic-memory path.)
        if (scene.subcompositor) |sub| {
            for (sub.subsurfaces.items) |ss| {
                if (ss.parent != sn.surface) continue;
                const child_sn = scene.surface_nodes.get(ss.surface) orelse continue;
                const child_tree = child_sn.tree orelse continue;
                if (child_tree.parent != scene.root) {
                    scene.root.appendChild(scene.allocator, child_tree) catch |err| {
                        log.warn(
                            "subsurface detach failed: {s}",
                            scene.io,
                            scene.log_cfg,
                            "surface_node",
                            .{@errorName(err)},
                        );
                    };
                    child_tree.enable(false);
                }
            }
        }
        // The surface left the output(s): drive the surface's leave
        // tracking (setLeft emits events.leave on the change; idempotent
        // when the surface was never entered).
        sn.updateOutputs();
        if (sn.node) |node| {
            if (node.kind.buffer.texture) |texture| texture.destroy();
            node.destroy(scene.allocator);
            sn.node = null;
        }
        if (sn.tree) |tree| {
            tree.destroy(scene.allocator);
            sn.tree = null;
        }
    }

    /// Full teardown: detach the nodes, unhook the surface listeners,
    /// unregister from the scene and free the binding. Called by the
    /// destroy listener (the surface died) and Scene.deinit (untrackAll).
    pub fn destroy(sn: *SurfaceNode) void {
        sn.detach();
        sn.commit_listener.link.remove();
        sn.destroy_listener.link.remove();
        sn.unmap_listener.link.remove();
        sn.enter_listener.link.remove();
        sn.leave_listener.link.remove();
        _ = sn.scene.surface_nodes.remove(sn.surface);
        sn.scene.allocator.destroy(sn);
    }

    /// The node's surface is presented this frame (it has an active
    /// node): append it to the frame's presented list. OOM logs and
    /// skips.
    pub fn appendPresented(sn: *SurfaceNode, list: *std.ArrayList(*Surface)) void {
        if (sn.node == null) return;
        list.append(sn.scene.allocator, sn.surface) catch |err| {
            log.warn(
                "presented list append OOM: {s}",
                sn.scene.io,
                sn.scene.log_cfg,
                "surface_node",
                .{@errorName(err)},
            );
        };
    }

    /// Translate the surface's committed damage (surface coordinates) by
    /// the node's absolute position into output coordinates, clipped to
    /// the output (damage is a hint; clipping is safe).
    pub fn addDamage(sn: *SurfaceNode, so: *SceneOutput, out_rect: Rect) void {
        const node = sn.node orelse return;
        const abs = node.absolutePosition();
        for (sn.surface.current.surface_damage.rects.items) |rect| {
            const translated: Rect = .{
                .x = addSat(abs.x, rect.x),
                .y = addSat(abs.y, rect.y),
                .width = rect.width,
                .height = rect.height,
            };
            if (out_rect.intersect(translated)) |visible| so.addDamage(visible);
        }
    }

    /// Create the surface's tree container if it does not exist yet. A
    /// non-subsurface gets its tree under scene.root; a subsurface gets
    /// its tree under the PARENT surface's tree, or a disabled root
    /// placeholder when the parent is not mapped yet (the compositor's
    /// per-frame subsurface sync reparents it into place once the parent
    /// maps).
    fn ensureTree(sn: *SurfaceNode) void {
        if (sn.tree != null) return;
        const scene = sn.scene;
        var parent_tree: ?*SceneNode = null;
        if (sn.subsurfaceParent()) |parent| {
            if (scene.surface_nodes.get(parent)) |parent_sn| {
                parent_tree = parent_sn.tree;
            }
        }
        const tree = SceneNode.create(scene.allocator, parent_tree orelse scene.root, .tree) catch |err| {
            log.warn("scene tree create failed: {s}", scene.io, scene.log_cfg, "surface_node", .{@errorName(err)});
            return;
        };
        // A placeholder subsurface tree (parent unmapped) stays hidden
        // until the compositor's subsurface sync moves it under the
        // parent and enables it.
        if (parent_tree == null and sn.subsurfaceParent() != null) tree.enable(false);
        sn.tree = tree;
    }

    /// The wl_subsurface parent of the tracked surface, or null when it
    /// is not a subsurface (the surface-side link; subsurface.zig
    /// records surface/parent and tears the entry down when either
    /// surface dies).
    fn subsurfaceParent(sn: *SurfaceNode) ?*Surface {
        const sub = sn.scene.subcompositor orelse return null;
        for (sub.subsurfaces.items) |ss| {
            if (ss.surface == sn.surface) return ss.parent;
        }
        return null;
    }

    /// Recompute the surface's output association: the first scene
    /// output whose rect the node's absolute rect intersects (the
    /// surface is being rendered on it). Drives the surface module's
    /// enter/leave tracking (setEntered/setLeft emit the enter/leave
    /// signals on the change; the listeners below send the wire events).
    /// Called at attach and detach; idempotent.
    fn updateOutputs(sn: *SurfaceNode) void {
        const s = sn.surface;
        var on_output: ?*output_mod.Output = null;
        if (sn.node) |node| {
            const rect = node.absolutePosition();
            for (sn.scene.scene_outputs.items) |so| {
                const out_rect: Rect = .{
                    .x = so.x,
                    .y = so.y,
                    .width = so.output.width,
                    .height = so.output.height,
                };
                if (out_rect.intersect(rect) != null) {
                    on_output = so.output;
                    break;
                }
            }
        }
        if (on_output) |out| s.setEntered(out) else s.setLeft();
    }

    /// Send wl_surface.enter/leave to the surface's client: the wl_output
    /// resource that client bound. A surface's events go only to its
    /// owner, and a client that never bound wl_output gets none (wlroots
    /// wlr_surface_send_enter/leave, wlr_compositor.c:1071-1128, iterate
    /// the output's resources and match on the client). Single-output
    /// scene: the one WlOutput is the only output that can enter/leave.
    fn sendEnter(sn: *SurfaceNode, enter: bool) void {
        const wl_output = sn.scene.wl_output orelse return;
        const client = sn.surface.resource.getClient();
        for (wl_output.resources.items) |res| {
            if (res.getClient() != client) continue;
            if (enter) {
                sn.surface.resource.sendEnter(res);
            } else {
                sn.surface.resource.sendLeave(res);
            }
            break;
        }
    }
};

/// Track `surface` in `scene`: create its binding, subscribe the
/// commit/unmap/destroy/enter/leave listeners and sync the node from the
/// surface's current state (the surface may have committed before
/// tracking). Idempotent: returns the existing binding. The compositor
/// decides which surfaces get bindings (policy); the binding owns the
/// surface→node lifecycle from here on.
pub fn trackSurface(
    scene: *Scene,
    surface: *Surface,
    impl: *const Impl,
    ctx: *anyopaque,
) error{OutOfMemory}!*SurfaceNode {
    if (scene.surface_nodes.get(surface)) |existing| return existing;
    const sn = try scene.allocator.create(SurfaceNode);
    errdefer scene.allocator.destroy(sn);
    sn.* = .{
        .scene = scene,
        .surface = surface,
        .impl = impl,
        .ctx = ctx,
        .tree = null,
        .node = null,
        .commit_listener = wire.Listener(*Surface).init(onCommit),
        .destroy_listener = wire.Listener(*Surface).init(onDestroy),
        .unmap_listener = wire.Listener(*Surface).init(onUnmap),
        .enter_listener = wire.Listener(*output_mod.Output).init(onEnter),
        .leave_listener = wire.Listener(*output_mod.Output).init(onLeave),
    };
    scene.surface_nodes.put(surface, sn) catch |err| {
        scene.allocator.destroy(sn);
        return err;
    };
    surface.events.commit.add(&sn.commit_listener);
    surface.events.destroy.add(&sn.destroy_listener);
    surface.events.unmap.add(&sn.unmap_listener);
    surface.events.enter.add(&sn.enter_listener);
    surface.events.leave.add(&sn.leave_listener);
    // The surface may have committed its buffer before we subscribed (the
    // commit fired before tracking); sync the node now.
    sn.update();
    return sn;
}

/// The binding for `surface`, or null when it is not tracked.
pub fn surfaceNodeFor(scene: *Scene, surface: *Surface) ?*SurfaceNode {
    return scene.surface_nodes.get(surface);
}

/// The tracked surface whose node is `node` (back-mapping the seat's
/// pick result), or null when the node belongs to no surface.
pub fn surfaceForNode(scene: *Scene, node: *SceneNode) ?*Surface {
    var it = scene.surface_nodes.valueIterator();
    while (it.next()) |sn| {
        if (sn.*.node == node) return sn.*.surface;
    }
    return null;
}

/// Build the frame's presented list (presentation feedback targets):
/// every tracked surface with an active node, into `scene.presented`
/// (cleared first). The compositor reads scene.presented after this.
pub fn collectPresented(scene: *Scene) void {
    scene.presented.clearRetainingCapacity();
    var it = scene.surface_nodes.valueIterator();
    while (it.next()) |sn| sn.*.appendPresented(&scene.presented);
}

/// The per-frame surface damage pass: translate every presented node's
/// committed damage into `so`'s output coordinates, clipped to
/// `out_rect`, and accumulate it into `so`'s damage ring. Mirrors the
/// old compositor-side loop (wlr_scene_output_commit's damage
/// translation); the node provides the translation.
pub fn addSurfaceDamage(scene: *Scene, so: *SceneOutput, out_rect: Rect) void {
    var it = scene.surface_nodes.valueIterator();
    while (it.next()) |sn| sn.*.addDamage(so, out_rect);
}

/// Detach and free every tracked binding (the scene's teardown). The
/// compositor may destroy its surfaces after the scene, so the surface
/// destroy signals must not reach freed bindings.
pub fn untrackAll(scene: *Scene) void {
    // destroy() removes the binding from the map, so take a fresh first
    // key each iteration (a single keyIterator would skip entries the
    // remove shifts).
    while (scene.surface_nodes.count() > 0) {
        var it = scene.surface_nodes.keyIterator();
        const surface = it.next().?.*;
        scene.surface_nodes.get(surface).?.destroy();
    }
}

/// wl_surface.commit applied: refresh the scene node from the surface's
/// current buffer. A committed buffer means the surface maps (or keeps
/// mapping) with content; a null buffer unmaps it.
fn onCommit(listener: *wire.Listener(*Surface), _: *Surface) void {
    const sn: *SurfaceNode = @fieldParentPtr("commit_listener", listener);
    sn.update();
    // The commit→present wake (note 137 F1): a content commit must
    // schedule a composite, or interactive clients' updates starve
    // behind the idle-frame skip (the frame_kick would present the
    // previous framebuffer). The compositor listens and calls its
    // requestRender.
    sn.scene.events.content_dirty.emit(sn.scene);
}

/// wl_surface.unmap signal: the surface stopped being mapped — a
/// null-buffer commit, destroy, or the forced unmap of a destroyed
/// wl_subsurface's child (note 132 F6). Detach the node so the surface
/// disappears; the binding stays (a later buffer commit remaps it).
/// Idempotent with the commit path (detach nulls node/tree).
fn onUnmap(listener: *wire.Listener(*Surface), _: *Surface) void {
    const sn: *SurfaceNode = @fieldParentPtr("unmap_listener", listener);
    sn.detach();
}

/// wl_surface destroyed: run the impl's compositor-side cleanup hook,
/// then tear the binding down. The surface is still valid inside the
/// destroy signal (its buffers are released after the signal).
fn onDestroy(listener: *wire.Listener(*Surface), _: *Surface) void {
    const sn: *SurfaceNode = @fieldParentPtr("destroy_listener", listener);
    if (sn.impl.destroyed) |f| f(sn.ctx, sn.surface);
    sn.destroy();
}

/// wl_surface.enter signal (the surface gained the output; fired by the
/// surface module at attach): send wl_surface.enter to the client.
fn onEnter(listener: *wire.Listener(*output_mod.Output), _: *output_mod.Output) void {
    const sn: *SurfaceNode = @fieldParentPtr("enter_listener", listener);
    sn.sendEnter(true);
}

/// wl_surface.leave signal (the surface lost the output; fired at
/// detach): send wl_surface.leave to the client.
fn onLeave(listener: *wire.Listener(*output_mod.Output), _: *output_mod.Output) void {
    const sn: *SurfaceNode = @fieldParentPtr("leave_listener", listener);
    sn.sendEnter(false);
}

/// Saturating i32 add: surface damage rects are client-controlled and may
/// overflow when translated by the node position. Damage is a hint, so a
/// saturated value is a safe over-report (clipped to the output below).
fn addSat(a: i32, b: i32) i32 {
    return std.math.add(i32, a, b) catch blk: {
        break :blk if (b < 0) std.math.minInt(i32) else std.math.maxInt(i32);
    };
}

/// The surface size of `buf` under the surface's committed transform and
/// scale: boxTransform of the buffer rect (buffer -> surface per
/// wl_output_transform, wlroots util/box.c:105-145) divided by the
/// scale. The commit validation (surface.zig validatePending) guarantees
/// the transformed buffer size is divisible by the scale, so the
/// division is exact.
fn surfaceSize(s: *Surface, buf: *Buffer) geom.Size {
    const rect = matrix.boxTransform(
        .{ .x = 0, .y = 0, .width = buf.width, .height = buf.height },
        s.current.transform,
        buf.width,
        buf.height,
    );
    return .{ .w = @divExact(rect.width, s.current.scale), .h = @divExact(rect.height, s.current.scale) };
}

// --- Tests --------------------------------------------------------------

const testing = std.testing;
const Subsurface = subsurface_mod.Subsurface;

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

const backend_mod = @import("../backend/backend.zig");

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

/// Test impl state: import/update counts plus a flag forcing the
/// update-in-place fast path.
const TestCtx = struct {
    allocator: std.mem.Allocator,
    imports: usize = 0,
    updates: usize = 0,
    before_updates: usize = 0,
    destroyed: usize = 0,
    fast_update: bool = false,
};

const FakeTexData = struct {
    allocator: std.mem.Allocator,
    destroyed: bool = false,
};

fn fakeTexDestroy(texture: *Texture) void {
    const data: *FakeTexData = @ptrCast(@alignCast(texture.data));
    data.destroyed = true;
    const allocator = data.allocator;
    allocator.destroy(data);
    allocator.destroy(texture);
}

const fake_tex_impl: Texture.Impl = .{ .destroy = fakeTexDestroy };

fn testImport(ctx: *anyopaque, _: *Surface, buf: *Buffer) ?*Texture {
    const self: *TestCtx = @ptrCast(@alignCast(ctx));
    self.imports += 1;
    const data = self.allocator.create(FakeTexData) catch return null;
    data.* = .{ .allocator = self.allocator };
    const tex = self.allocator.create(Texture) catch {
        self.allocator.destroy(data);
        return null;
    };
    tex.* = .{ .impl = &fake_tex_impl, .data = data, .width = buf.width, .height = buf.height };
    return tex;
}

fn testUpdate(ctx: *anyopaque, _: *Texture, _: *Surface, _: *Buffer) bool {
    const self: *TestCtx = @ptrCast(@alignCast(ctx));
    self.updates += 1;
    return self.fast_update;
}

fn testBeforeUpdate(ctx: *anyopaque, _: *SurfaceNode) void {
    const self: *TestCtx = @ptrCast(@alignCast(ctx));
    self.before_updates += 1;
}

fn testDestroyed(ctx: *anyopaque, _: *Surface) void {
    const self: *TestCtx = @ptrCast(@alignCast(ctx));
    self.destroyed += 1;
}

const test_impl: Impl = .{
    .import = testImport,
    .update = testUpdate,
    .before_update = testBeforeUpdate,
    .destroyed = testDestroyed,
};

test "trackSurface binds a surface: attach on map, detach on unmap, teardown on destroy" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    // LIFO: the client (and with it every surface) must die while the
    // compositor is still alive — Surface.destroy calls
    // compositor.removeSurface.
    defer allocator.destroy(comp);
    defer tw.deinit();
    const scene = try makeScene(allocator, io, &log_cfg);
    defer scene.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    const sn = try trackSurface(scene, s, &test_impl, &ctx);
    try testing.expect(sn == scene.surface_nodes.get(s).?);
    // Idempotent: tracking twice returns the same binding.
    try testing.expect(try trackSurface(scene, s, &test_impl, &ctx) == sn);
    try testing.expectEqual(@as(usize, 1), scene.surface_nodes.count());

    // Before any buffer commit: no node.
    try testing.expect(sn.node == null);
    try testing.expect(sn.tree == null);

    // First buffer commit maps the surface: tree + node appear, the node
    // shows the imported texture at the surface size.
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.mapped);
    try testing.expect(sn.node != null);
    try testing.expect(sn.tree != null);
    try testing.expect(sn.node.?.enabled);
    try testing.expect(sn.node.?.kind.buffer.texture != null);
    try testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_width);
    try testing.expectEqual(@as(i32, 10), sn.node.?.kind.buffer.dst_height);
    try testing.expectEqual(@as(usize, 1), ctx.imports);
    // The hook ran once at trackSurface (the catch-up update) and once at
    // the commit.
    try testing.expectEqual(@as(usize, 2), ctx.before_updates);
    // The tree is under the scene root for a plain surface.
    try testing.expect(sn.tree.?.parent == scene.root);

    // Null-buffer commit unmaps: node + tree detached, binding stays.
    s.attachBuffer(null);
    s.commit();
    try testing.expect(!s.mapped);
    try testing.expect(sn.node == null);
    try testing.expect(sn.tree == null);
    try testing.expectEqual(@as(usize, 1), scene.surface_nodes.count());

    // Remap after unmap: fresh tree + node.
    var buffer2: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer2);
    s.attachBuffer(&buffer2);
    s.commit();
    try testing.expect(sn.node != null);
    try testing.expectEqual(@as(usize, 2), ctx.imports);

    // The surface dies: the destroyed hook runs, the binding tears itself
    // down (listeners unhooked, registry entry freed).
    s.resource.destroy();
    try testing.expectEqual(@as(usize, 1), ctx.destroyed);
    try testing.expectEqual(@as(usize, 0), scene.surface_nodes.count());
}

test "SurfaceNode update-in-place fast path skips the re-import" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    // LIFO: the client (and with it every surface) must die while the
    // compositor is still alive — Surface.destroy calls
    // compositor.removeSurface.
    defer allocator.destroy(comp);
    defer tw.deinit();
    const scene = try makeScene(allocator, io, &log_cfg);
    defer scene.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator, .fast_update = true };

    const sn = try trackSurface(scene, s, &test_impl, &ctx);
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    const first_tex = sn.node.?.kind.buffer.texture;

    // A second commit with a fresh buffer: the in-place update succeeds,
    // so the same texture object survives and no new import happens.
    var buffer2: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer2);
    s.attachBuffer(&buffer2);
    s.commit();
    try testing.expect(sn.node.?.kind.buffer.texture == first_tex);
    try testing.expectEqual(@as(usize, 1), ctx.imports);
    try testing.expectEqual(@as(usize, 1), ctx.updates);

    // The fast path failing falls back to a re-import (new texture).
    ctx.fast_update = false;
    var buffer3: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer3);
    s.attachBuffer(&buffer3);
    s.commit();
    try testing.expect(sn.node.?.kind.buffer.texture != first_tex);
    try testing.expectEqual(@as(usize, 2), ctx.imports);
    try testing.expectEqual(@as(usize, 2), ctx.updates);
}

test "SurfaceNode damage translation: position offset, output clipping, overflow" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, io, &log_cfg);
    defer scene.deinit();
    const created = try makeOutput(allocator, io, &log_cfg);
    const out = created[0];
    defer out.destroy();
    defer created[1].destroy();
    const so = try SceneOutput.create(allocator, io, &log_cfg, scene, out);
    defer so.destroy();
    const out_rect: Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    // LIFO: the client (and with it every surface) must die while the
    // compositor is still alive — Surface.destroy calls
    // compositor.removeSurface.
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    const sn = try trackSurface(scene, s, &test_impl, &ctx);
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();

    // Compositor placement policy: the node sits at (100, 50).
    sn.node.?.x = 100;
    sn.node.?.y = 50;
    // Committed damage in surface coordinates (bypassing the request
    // path; the surface module owns that pipeline — see its tests).
    try s.current.surface_damage.add(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    // Spills 500px past the right edge: clipped to the output (damage is
    // a hint; clipping is safe). A rect starting AT the right edge has
    // zero area and is dropped (geom.intersect, x1 <= x0).
    try s.current.surface_damage.add(.{ .x = 650, .y = 0, .width = 500, .height = 100 });

    sn.addDamage(so, out_rect);
    so.damage_ring.rotate();
    const rects = so.takeDamage();
    // Translated by the node position; the off-output part is clipped.
    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(Rect{ .x = 101, .y = 52, .width = 3, .height = 4 }, rects[0]);
    try testing.expectEqual(Rect{ .x = 750, .y = 50, .width = 50, .height = 100 }, rects[1]);
}

test "SurfaceNode damage translation saturates on overflow" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, io, &log_cfg);
    defer scene.deinit();
    const created = try makeOutput(allocator, io, &log_cfg);
    const out = created[0];
    defer out.destroy();
    defer created[1].destroy();
    const so = try SceneOutput.create(allocator, io, &log_cfg, scene, out);
    defer so.destroy();
    const out_rect: Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    // LIFO: the client (and with it every surface) must die while the
    // compositor is still alive — Surface.destroy calls
    // compositor.removeSurface.
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    const sn = try trackSurface(scene, s, &test_impl, &ctx);
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();

    // Client-controlled damage near i32 max: the translation saturates
    // instead of trapping, and the (fully off-output) rect is dropped by
    // the output clip — the same handling the old compositor-side loop
    // had (addSat only prevents the wrap trap; the hint then clips).
    try s.current.surface_damage.add(.{
        .x = std.math.maxInt(i32) - 5,
        .y = 10,
        .width = 100,
        .height = 100,
    });
    sn.addDamage(so, out_rect);
    so.damage_ring.rotate();
    try testing.expectEqual(@as(usize, 0), so.takeDamage().len);
}

test "SurfaceNode drives enter at attach and leave at detach (output association)" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, io, &log_cfg);
    defer scene.deinit();
    const created = try makeOutput(allocator, io, &log_cfg);
    const out = created[0];
    defer out.destroy();
    defer created[1].destroy();

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    // LIFO: the client (and with it every surface) must die while the
    // compositor is still alive — Surface.destroy calls
    // compositor.removeSurface.
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    // The output is far outside the node's position: the surface never
    // enters it.
    const so = try SceneOutput.create(allocator, io, &log_cfg, scene, out);
    defer so.destroy();
    so.x = 10000;
    so.y = 10000;
    try testing.expectEqual(@as(usize, 1), scene.scene_outputs.items.len);

    _ = try trackSurface(scene, s, &test_impl, &ctx);
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.outputs == null);

    // The output covers the node: the next map enters it (the surface
    // module's setEntered fires events.enter; the binding's listener
    // sends the wire event — scene.wl_output is null in this fixture, so
    // the wire send is a no-op; the surface module test covers the
    // signal side).
    so.x = 0;
    so.y = 0;
    s.attachBuffer(null);
    s.commit();
    try testing.expect(s.outputs == null);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.outputs == out);

    // Unmap leaves the output.
    s.attachBuffer(null);
    s.commit();
    try testing.expect(!s.mapped);
    try testing.expect(s.outputs == null);
}

test "SurfaceNode subsurface trees nest under the parent's tree" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    // Teardown order (LIFO): the client (and with it every surface) must
    // die while the compositor AND the fake subcompositor are still alive
    // — Surface.destroy calls compositor.removeSurface, and the binding's
    // detach iterates scene.subcompositor.subsurfaces. The scene dies
    // next (its bindings were freed by the surface destroys), then the
    // fake registry, then the compositor.
    const scene = try makeScene(allocator, io, &log_cfg);
    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    const parent = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    const child = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    // A fake subcompositor registry: one Subsurface entry linking
    // child -> parent. The scene only reads the list.
    const fake_sub = try allocator.create(Subcompositor);
    fake_sub.* = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = &log_cfg,
        // SAFETY: test fixture; never dereferenced.
        .display = @ptrFromInt(0x10),
        .compositor = comp,
        .subsurfaces = .empty,
    };
    scene.subcompositor = fake_sub;

    const ss = try allocator.create(Subsurface);
    ss.* = .{
        .allocator = allocator,
        .io = io,
        .log_cfg = &log_cfg,
        .subcompositor = fake_sub,
        // SAFETY: test fixture; the resource is never dereferenced.
        .resource = @ptrFromInt(0x20),
        .surface = child,
        .parent = parent,
        .surface_listener = wire.Listener(*Surface).init(noopSurfaceListener),
        .parent_listener = wire.Listener(*Surface).init(noopSurfaceListener),
        .client_commit_listener = wire.Listener(*Surface).init(noopSurfaceListener),
        .parent_commit_listener = wire.Listener(*Surface).init(noopSurfaceListener),
    };
    fake_sub.subsurfaces.append(allocator, ss) catch unreachable;

    // Deferred teardown, LIFO: tw.deinit runs FIRST (surfaces die while
    // comp + fake_sub are alive and the bindings are still hooked), then
    // scene.deinit, then the fake registry + entry, then the compositor.
    defer allocator.destroy(comp);
    defer allocator.destroy(ss);
    defer allocator.destroy(fake_sub);
    defer fake_sub.subsurfaces.deinit(allocator);
    defer scene.deinit();
    defer tw.deinit();

    const parent_sn = try trackSurface(scene, parent, &test_impl, &ctx);
    const child_sn = try trackSurface(scene, child, &test_impl, &ctx);

    var parent_buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &parent_buffer);
    parent.attachBuffer(&parent_buffer);
    parent.commit();
    try testing.expect(parent_sn.tree != null);
    try testing.expect(parent_sn.tree.?.parent == scene.root);

    // The child maps after its parent: its tree nests under the parent's
    // tree, not the root.
    var child_buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &child_buffer);
    child.attachBuffer(&child_buffer);
    child.commit();
    try testing.expect(child_sn.tree != null);
    try testing.expect(child_sn.tree.?.parent == parent_sn.tree);
    try testing.expect(child_sn.tree.?.enabled);

    // Detaching the parent reparents the child's tree to the root,
    // disabled — node.destroy must not free the child's nodes.
    parent.attachBuffer(null);
    parent.commit();
    try testing.expect(child_sn.tree != null);
    try testing.expect(child_sn.tree.?.parent == scene.root);
    try testing.expect(!child_sn.tree.?.enabled);
    try testing.expect(child_sn.node != null);
}

fn noopSurfaceListener(_: *wire.Listener(*Surface), _: *Surface) void {}
