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
//! damage is (addDamage projects the surface's committed damage through
//! the node and the output's camera).
//!
//! The renderer-specific part — turning the surface's current buffer into
//! a texture — is delegated to the Impl (import + an optional in-place
//! update fast path). Two compositor policy hooks ride the Impl too:
//! before_update (runs before every commit sync, e.g. subsurface orphan
//! recovery) and destroyed (compositor-side cleanup at surface death,
//! e.g. seat focus + presentation feedback).
//!
//! World space is f64 end to end: the node's position, the world rect
//! absolutePosition reports, the raw-buffer crop, and the projection
//! into an output's screen pixels. Narrowing happens once, at the pixel
//! boundary (SceneOutput.projectWorldRect), and never on a coordinate
//! that is still far from the origin.
//!
//! Output membership (note 135 O20): a surface is on EVERY output whose
//! view its node intersects, not just the first one. The binding
//! maintains that whole set — setEntered per output gained, leaveOutput
//! per output lost — and re-evaluates it whenever the node's geometry
//! changes, not only at attach/detach. The surface module emits the
//! enter/leave signals on the change; the binding's listeners send the
//! wl_surface.enter/leave wire events for the ACTUAL output, through that
//! output's own wl_output global, to every bound resource of the same
//! client (a client that never bound wl_output gets none, mirroring
//! wlroots wlr_surface_send_enter/leave, wlr_compositor.c:1071-1128).
//!
//! Imports: utils/*, core/wire.zig, buffers/*, compositor/* (surface,
//! subsurface), output/*, scene/scene.zig.

const std = @import("std");
const geom = @import("../utils/geom.zig");
const log = @import("../utils/log.zig");
const wire = @import("../core/wire.zig");
const matrix = @import("../utils/matrix.zig");
const scene_mod = @import("scene.zig");
const camera_mod = @import("camera.zig");
const surface_mod = @import("../compositor/surface.zig");
const subsurface_mod = @import("../compositor/subsurface.zig");
const role_mod = @import("../compositor/role.zig");
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
    /// wl_surface.map signal listener: a surface can become mapped
    /// without its own commit (a subsurface mapping via parent-chain
    /// propagation), so the output association must be recomputed on map,
    /// not only at attach (which already ran at the buffer commit while
    /// the surface was still hidden).
    map_listener: wire.Listener(*Surface),
    /// wl_surface.enter/leave signal listeners (the surface module emits
    /// the signals on ONE output's membership changing; these send that
    /// output's wl_surface.enter/leave wire events). The signal payload
    /// names the output, so an event for one output never rides
    /// another's global.
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
        // The texture's source crop, in RAW BUFFER pixels: the
        // wp_viewport source is surface-local (F-AX-12), so it is
        // multiplied by buffer_scale and inverse-transformed back into
        // buffer space here, once. The renderer samples buffer texels
        // through `transform`, so the crop is never applied twice.
        const src = rawSrcCrop(s, buf);
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
                        bn.src = src;
                        bn.transform = s.current.transform;
                        node.enable(true);
                        sn.updateOutputs();
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
            bn.src = src;
            bn.transform = s.current.transform;
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
            node.kind.buffer.src = src;
            node.kind.buffer.transform = s.current.transform;
            sn.node = node;
        }
        // The node's geometry can have changed (buffer size, viewport
        // destination, a fresh map), and the compositor moves nodes
        // between commits too, so the output membership is recomputed on
        // every sync — not only when the node appears or disappears.
        // Idempotent: an unchanged membership fires nothing.
        sn.updateOutputs();
    }

    /// Remove (and free) the surface's scene nodes; the binding keeps
    /// tracking the surface for a future remap. Idempotent.
    pub fn detach(sn: *SurfaceNode) void {
        const scene = sn.scene;
        // Node destruction CASCADES into the whole subtree
        // (SceneNode.destroy, scene.zig:239-258; wlr_scene_node_destroy,
        // types/scene/scene.c:829-843). A tree is not private to one
        // SurfaceNode: the compositor nests other surfaces' trees under
        // it as scene policy — a subsurface under its parent
        // (ensureTree), an xdg/layer popup under its parent's tree (the
        // placement pass). Freeing this tree therefore frees those
        // surfaces' nodes while their own bindings still hold the raw
        // pointers, and the next detach on one of them reads freed
        // memory. So lift the foreign trees out first and free only the
        // two nodes this binding owns. On OOM the cascade still frees a
        // tree that could not be lifted — a catastrophic-memory path.
        sn.liftForeignTrees();
        if (sn.node) |node| {
            if (node.kind.buffer.texture) |texture| texture.destroy();
            node.destroy(scene.allocator);
            sn.node = null;
        }
        if (sn.tree) |tree| {
            tree.destroy(scene.allocator);
            sn.tree = null;
        }
        // The nodes are gone, so the surface is on no output: recompute
        // the membership AFTER the world rect stopped existing (setLeft
        // emits events.leave per lost output; idempotent when the
        // surface was never entered).
        sn.updateOutputs();
    }

    /// Move every tree under `sn.tree` that belongs to ANOTHER surface's
    /// SurfaceNode binding to the scene root, so freeing `sn.tree` cannot
    /// free it (see detach). A subsurface tree goes there disabled — its
    /// parent chain is unmapped, so it must not draw (wayland.xml:3254-
    /// 3258); the next syncSubsurfaceNodes pass re-parents and enables it.
    /// The compositor's own placement pass does the same for a popup tree
    /// it lifts (syncPopupNodes).
    fn liftForeignTrees(sn: *SurfaceNode) void {
        const scene = sn.scene;
        const own_tree = sn.tree orelse return;
        var i: usize = own_tree.children.items.len;
        while (i > 0) {
            i -= 1;
            const child = own_tree.children.items[i];
            const child_sn = surfaceNodeOwner(scene, child) orelse continue;
            if (child_sn == sn) continue; // this binding's own buffer node
            const was_subsurface = child_sn.subsurfaceParent() != null;
            scene.root.appendChild(scene.allocator, child) catch |err| {
                // OOM: the cascade below still frees it — a
                // catastrophic-memory path, not a recoverable one.
                log.warn(
                    "nested surface tree lift failed: {s}",
                    scene.io,
                    scene.log_cfg,
                    "surface_node",
                    .{@errorName(err)},
                );
                continue;
            };
            if (was_subsurface) child.enable(false);
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
        sn.map_listener.link.remove();
        sn.enter_listener.link.remove();
        sn.leave_listener.link.remove();
        _ = sn.scene.surface_nodes.remove(sn.surface);
        sn.scene.allocator.destroy(sn);
    }

    const Visibility = union(enum) {
        hidden,
        world: geom.FRect,
        output_local: *output_mod.Output,

        fn visibleOn(self: *const Visibility, so: *const SceneOutput) bool {
            if (!so.live) return false;
            return switch (self.*) {
                .hidden => false,
                .world => |world| so.visibleWorldRect().intersects(world),
                .output_local => |output| so.output == output,
            };
        }
    };

    /// One policy decision for every output in this update. Rendering,
    /// output membership and presentation must agree about hidden trees.
    fn visibility(sn: *const SurfaceNode) Visibility {
        if (!sn.surface.isEffectivelyMapped()) return .hidden;
        const node = sn.node orelse return .hidden;
        var ancestor: ?*SceneNode = node;
        while (ancestor) |parent| : (ancestor = parent.parent) {
            if (!parent.enabled) return .hidden;
        }
        return switch (sn.scene.surfacePlacement(sn.surface)) {
            .world => .{ .world = node.absolutePosition() },
            .output_local => |output| if (output) |pinned|
                .{ .output_local = pinned }
            else
                .hidden,
        };
    }

    /// The node's surface is presented THIS frame on `so`: append it to
    /// that output's presented list. Skipped when it has no node, is not
    /// mapped (a hidden subsurface is skipped even though its scene node
    /// exists — created buffer-driven while hidden,
    /// wayland.xml:3254-3258), or when `so`'s view does not show it.
    /// OOM logs and skips.
    pub fn appendPresented(sn: *SurfaceNode, so: *SceneOutput) void {
        const shown = sn.visibility();
        if (!shown.visibleOn(so)) return;
        so.presented.append(sn.scene.allocator, sn.surface) catch |err| {
            log.warn(
                "presented list append OOM: {s}",
                sn.scene.io,
                sn.scene.log_cfg,
                "surface_node",
                .{@errorName(err)},
            );
        };
    }

    /// Queue this commit's damage for one visible output. World content
    /// uses the view's camera; pinned overlays use its desktop origin
    /// without a camera. Clip in f64 before narrowing to output pixels.
    /// Called once per commit per output, not by every rendered frame.
    pub fn addDamage(sn: *SurfaceNode, so: *SceneOutput) void {
        const shown = sn.visibility();
        if (!shown.visibleOn(so)) return;
        const abs = switch (shown) {
            .world => |world| world,
            .output_local => sn.node.?.absolutePosition(),
            .hidden => unreachable,
        };
        for (sn.surface.current.surface_damage.rects.items) |rect| {
            var damage: geom.FRect = .{
                .x = abs.x + @as(f64, @floatFromInt(rect.x)),
                .y = abs.y + @as(f64, @floatFromInt(rect.y)),
                .width = @floatFromInt(rect.width),
                .height = @floatFromInt(rect.height),
            };
            switch (shown) {
                .world => if (so.projectWorldRect(damage)) |screen| so.addDamage(screen),
                .output_local => {
                    damage.x -= so.x;
                    damage.y -= so.y;
                    if (damage.intersect(so.screenBounds())) |screen| so.addDamage(screen.toPixelRect());
                },
                .hidden => unreachable,
            }
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

    /// Recompute the surface's output association across EVERY scene
    /// output: the surface is on each output whose view shows its node,
    /// and on no other. Per output gained, setEntered fires the enter
    /// signal; per output lost, leaveOutput fires the leave signal (both
    /// idempotent per output, and the listeners below send the wire
    /// events for the output the signal names). A view with no node (or a
    /// view whose visible world rect misses it) drops every membership.
    ///
    /// Called on every commit sync, at map and at detach, and by
    /// updateOutputAssociations after the compositor moves a node or
    /// changes a camera. Idempotent: an unchanged set fires nothing.
    fn updateOutputs(sn: *SurfaceNode) void {
        const s = sn.surface;
        const shown = sn.visibility();
        if (shown == .hidden) {
            s.setLeft();
            return;
        }
        for (sn.scene.scene_outputs.items) |so| {
            if (!so.live) continue;
            if (shown.visibleOn(so)) {
                if (!s.hasOutput(so.output)) s.setEntered(so.output);
            } else if (s.hasOutput(so.output)) {
                s.leaveOutput(so.output);
            }
        }
    }

    /// Send wl_surface.enter/leave for `out` to the surface's client:
    /// the resources of THAT output's global that the client bound —
    /// every one of them, since a client may hold several. A surface's
    /// events go only to its owner, and a client that never bound
    /// wl_output gets none (wlroots wlr_surface_send_enter/leave,
    /// wlr_compositor.c:1071-1128, iterate the output's resources and
    /// match on the client). The event for one output never rides another
    /// output's global: the view is looked up by the output the signal
    /// carried.
    ///
    /// The resources reached through the wl_output stay valid for the
    /// whole output-destroy phase: the wl_output module withdraws its
    /// global there but only frees itself (and only then turns the
    /// resources inert) in Output.events.finalize, which runs after
    /// every destroy listener. So a membership dropped by the output's
    /// own death still reaches the client here. The view must be found
    /// before it drops its wl_output, which is why the scene revokes
    /// memberships while the view is still live (SceneOutput).
    fn sendEnter(sn: *SurfaceNode, out: *output_mod.Output, enter: bool) void {
        const so = sceneOutputFor(sn.scene, out) orelse return;
        const wl_output = so.wl_output orelse return;
        const surface_client = sn.surface.resource.getClient();
        for (wl_output.resources.items) |res| {
            if (res.getClient() != surface_client) continue;
            if (enter) {
                sn.surface.resource.sendEnter(res);
            } else {
                sn.surface.resource.sendLeave(res);
            }
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
        .map_listener = wire.Listener(*Surface).init(onMap),
        .enter_listener = wire.Listener(*output_mod.Output).init(onEnter),
        .leave_listener = wire.Listener(*output_mod.Output).init(onLeave),
    };
    scene.surface_nodes.put(surface, sn) catch |err| {
        // errdefer above destroys sn on this error return — no manual
        // destroy here (that would double-free).
        return err;
    };
    surface.events.commit.add(&sn.commit_listener);
    surface.events.destroy.add(&sn.destroy_listener);
    surface.events.unmap.add(&sn.unmap_listener);
    surface.events.map.add(&sn.map_listener);
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

/// The tracked-surface binding that OWNS `node` — its `node` (the surface's
/// buffer node) or its `tree` (the surface's container). Lets a tree's
/// teardown find the nodes nested under it that belong to OTHER surfaces,
/// so it frees only what it owns; null when the node belongs to no tracked
/// surface (decoration, or an untracked tree).
fn surfaceNodeOwner(scene: *Scene, node: *SceneNode) ?*SurfaceNode {
    var it = scene.surface_nodes.valueIterator();
    while (it.next()) |sn| {
        if (sn.*.node == node or sn.*.tree == node) return sn.*;
    }
    return null;
}

/// The scene output view of `out`, or null when no view carries it (an
/// output without a view is not in the scene's output list).
pub fn sceneOutputFor(scene: *Scene, out: *output_mod.Output) ?*SceneOutput {
    for (scene.scene_outputs.items) |so| {
        if (so.live and so.output == out) return so;
    }
    return null;
}

/// Build ONE output's frame presented list (presentation feedback
/// targets): every tracked surface that is mapped and whose node this
/// output's view shows, into `so.presented` — which is cleared first, and
/// is this output's list alone (a surface shown on two outputs appears in
/// both lists, and one shown on neither appears in neither).
pub fn collectPresented(scene: *Scene, so: *SceneOutput) void {
    so.presented.clearRetainingCapacity();
    var it = scene.surface_nodes.valueIterator();
    while (it.next()) |sn| sn.*.appendPresented(so);
}

/// Recompute every tracked surface's output membership. The compositor
/// calls this after anything that moves nodes or moves a view WITHOUT a
/// commit: a camera pan/zoom/rotation (which changes what every view
/// shows), a node placement, an output hotplug (SceneOutput.create /
/// destroy). Commit, map and unmap already maintain their own surface.
pub fn updateOutputAssociations(scene: *Scene) void {
    var it = scene.surface_nodes.valueIterator();
    while (it.next()) |sn| sn.*.updateOutputs();
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
        const surface = (it.next() orelse break).*;
        scene.surface_nodes.get(surface).?.destroy();
    }
}

/// wl_surface.commit applied: refresh the scene node from the surface's
/// current buffer. A committed buffer means the surface maps (or keeps
/// mapping) with content; a null buffer unmaps it.
fn onCommit(listener: *wire.Listener(*Surface), _: *Surface) void {
    const sn: *SurfaceNode = @fieldParentPtr("commit_listener", listener);
    sn.update();
    for (sn.scene.scene_outputs.items) |so| sn.addDamage(so);
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

/// wl_surface.map signal: the surface became effectively mapped — its own
/// commit OR parent-chain propagation (a subsurface mapping when its
/// parent maps, no commit of its own). Recompute the output association:
/// the scene node already exists (created buffer-driven at the earlier
/// commit), so only the enter tracking needs to catch up.
fn onMap(listener: *wire.Listener(*Surface), _: *Surface) void {
    const sn: *SurfaceNode = @fieldParentPtr("map_listener", listener);
    sn.updateOutputs();
}

/// wl_surface destroyed: run the impl's compositor-side cleanup hook,
/// then tear the binding down. The surface is still valid inside the
/// destroy signal (its buffers are released after the signal).
fn onDestroy(listener: *wire.Listener(*Surface), _: *Surface) void {
    const sn: *SurfaceNode = @fieldParentPtr("destroy_listener", listener);
    if (sn.impl.destroyed) |f| f(sn.ctx, sn.surface);
    sn.destroy();
}

/// wl_surface.enter signal: the surface gained ONE output (fired by the
/// surface module's setEntered for that output): send wl_surface.enter
/// for it to the client.
fn onEnter(listener: *wire.Listener(*output_mod.Output), out: *output_mod.Output) void {
    const sn: *SurfaceNode = @fieldParentPtr("enter_listener", listener);
    sn.sendEnter(out, true);
}

/// wl_surface.leave signal: the surface lost ONE output (fired by
/// leaveOutput/setLeft for that output): send wl_surface.leave for it to
/// the client.
fn onLeave(listener: *wire.Listener(*output_mod.Output), out: *output_mod.Output) void {
    const sn: *SurfaceNode = @fieldParentPtr("leave_listener", listener);
    sn.sendEnter(out, false);
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
    const size: geom.Size = .{
        .w = @divExact(rect.width, s.current.scale),
        .h = @divExact(rect.height, s.current.scale),
    };
    // A wp_viewport overrides the surface size (F-AX-11): the destination
    // size when set; else the source rect size when a crop is set (crop
    // without scaling); else the buffer-derived size. lossyCast is exact
    // here: F-AX-12's bad_size validation guarantees an integral src when
    // no destination is set. foot at scale 1 sets dst == buffer size, a
    // no-op.
    const vp = s.current.viewport;
    if (vp.has_dst) return vp.dst;
    if (vp.has_src) {
        return .{
            .w = std.math.lossyCast(i32, vp.src.width),
            .h = std.math.lossyCast(i32, vp.src.height),
        };
    }
    return size;
}

/// The node's texture source crop in RAW BUFFER pixels: null when the
/// surface has no wp_viewport source (the whole texture).
///
/// A wp_viewport source names SURFACE-local coordinates (after the
/// buffer transform and the buffer scale, viewporter.xml). A texture
/// crop names buffer texels, so the source is scaled up by buffer_scale
/// and then mapped back through the INVERSE transform — the box the
/// compositor presents is the box the renderer samples
/// (utils/matrix.surfaceBoxToBuffer). Doing it once here is what keeps
/// the renderer from applying the crop twice.
fn rawSrcCrop(s: *Surface, buf: *Buffer) ?geom.FRect {
    const vp = s.current.viewport;
    if (!vp.has_src) return null;
    const scale: f64 = @floatFromInt(s.current.scale);
    const surface_local: geom.FRect = .{
        .x = vp.src.x * scale,
        .y = vp.src.y * scale,
        .width = vp.src.width * scale,
        .height = vp.src.height * scale,
    };
    return matrix.surfaceBoxToBuffer(surface_local, s.current.transform, buf.width, buf.height);
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

    sn.addDamage(so);
    so.damage_ring.rotate();
    const rects = so.takeDamage();
    // Translated by the node position; the off-output part is clipped.
    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(Rect{ .x = 101, .y = 52, .width = 3, .height = 4 }, rects[0]);
    try testing.expectEqual(Rect{ .x = 750, .y = 50, .width = 50, .height = 100 }, rects[1]);
}

test "SurfaceNode damage off the far side of the world is dropped, not folded onto the output" {
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

    // Client-controlled damage at the far end of the i32 range: the world
    // rect is f64, so nothing saturates or wraps on the way out, and the
    // screen clip drops the rect that lands nowhere near this output. A
    // narrowing step BEFORE the clip would fold it onto the output's
    // right edge and report damage the output never had.
    try s.current.surface_damage.add(.{
        .x = std.math.maxInt(i32) - 5,
        .y = 10,
        .width = 100,
        .height = 100,
    });
    sn.addDamage(so);
    so.damage_ring.rotate();
    try testing.expectEqual(@as(usize, 0), so.takeDamage().len);
}

test "SurfaceNode damage projects through a rotated camera at a distant world origin" {
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

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    const sn = try trackSurface(scene, s, &test_impl, &ctx);
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();

    // The world is 5e9 px out — where one f64 ulp is ~1e-6 and an f32
    // translation would cancel to nothing — with a quarter-pixel zoom and
    // a 90-degree rotation. The damage must land on the pixels the camera
    // shows, which is only computable if every step stays f64.
    var cam = camera_mod.Camera{
        .center_x = 5_000_000_000.5,
        .center_y = 5_000_000_000.25,
        .zoom = 1,
        .rotation = std.math.pi / 2.0,
        .screen_w = @floatFromInt(out.width),
        .screen_h = @floatFromInt(out.height),
    };
    so.camera = &cam;

    // The node's world origin IS the camera centre, so the whole surface
    // (10x10 surface px, node at (0,0)) is drawn around screen centre
    // (400, 300). Its damage rect (0,0,10,10) rotates with it.
    sn.node.?.setPosition(cam.center_x, cam.center_y);
    try s.current.surface_damage.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    sn.addDamage(so);
    so.damage_ring.rotate();
    const rects = so.takeDamage();
    try testing.expectEqual(@as(usize, 1), rects.len);
    // Under R(-90) a world offset (dx, dy) lands at screen
    // (400 + dy, 300 - dx). The node's 10x10 world rect spans
    // dx,dy in [0,10], so its screen AABB is x 400..410, y 290..300.
    try testing.expectEqual(Rect{ .x = 400, .y = 290, .width = 10, .height = 10 }, rects[0]);

    // Pan the camera away: the surface leaves the view and its damage
    // stops landing on this output entirely (the membership pass the
    // compositor drives after a camera change drops the enter too).
    cam.center_x += 10_000;
    updateOutputAssociations(scene);
    try testing.expect(!s.hasOutput(out));
    s.current.surface_damage.clear();
    try s.current.surface_damage.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    sn.addDamage(so);
    so.damage_ring.rotate();
    try testing.expectEqual(@as(usize, 0), so.takeDamage().len);
}

test "SurfaceNode texture crop is the raw buffer rect: viewport source through scale and transform" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, io, &log_cfg);
    defer scene.deinit();

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    buffer.width = 64;
    buffer.height = 64;
    const sn = try trackSurface(scene, s, &test_impl, &ctx);

    // A plain crop on an untransformed, unscaled surface passes through:
    // surface-local and buffer pixels are the same numbers.
    s.current.viewport = .{
        .has_src = true,
        .src = .{ .x = 8, .y = 8, .width = 32, .height = 32 },
        .has_dst = true,
        .dst = .{ .w = 32, .h = 32 },
    };
    s.attachBuffer(&buffer);
    s.commit();
    const bn = sn.node.?.kind.buffer;
    try testing.expectEqual(geom.FRect{ .x = 8, .y = 8, .width = 32, .height = 32 }, bn.src.?);
    try testing.expectEqual(geom.Transform.normal, bn.transform);

    // buffer_scale 2: the source is surface-local, so each edge is two
    // buffer texels further out. Publishing the unscaled rect here would
    // sample the wrong quadrant of the buffer.
    s.current.scale = 2;
    s.current.viewport = .{
        .has_src = true,
        .src = .{ .x = 4, .y = 4, .width = 16, .height = 16 },
        .has_dst = true,
        .dst = .{ .w = 16, .h = 16 },
    };
    s.commit();
    try testing.expectEqual(
        geom.FRect{ .x = 8, .y = 8, .width = 32, .height = 32 },
        sn.node.?.kind.buffer.src.?,
    );
    try testing.expectEqual(@as(i32, 16), sn.node.?.kind.buffer.dst_width);

    // A 90-degree buffer transform: the crop is still named in buffer
    // pixels, so the surface box is mapped back through the INVERSE
    // transform. Surface (0,0,32,16) on a 64x64 buffer under 90 is buffer
    // (0, 32, 16, 32) — and the node records the transform for the
    // renderer's own mapping.
    s.current.scale = 1;
    s.current.transform = .@"90";
    s.current.viewport = .{
        .has_src = true,
        .src = .{ .x = 0, .y = 0, .width = 32, .height = 16 },
        .has_dst = true,
        .dst = .{ .w = 32, .h = 16 },
    };
    s.commit();
    try testing.expectEqual(
        geom.FRect{ .x = 0, .y = 32, .width = 16, .height = 32 },
        sn.node.?.kind.buffer.src.?,
    );
    try testing.expectEqual(geom.Transform.@"90", sn.node.?.kind.buffer.transform);

    // No wp_viewport source: no crop at all (the whole buffer).
    s.current.transform = .normal;
    s.current.viewport = .{};
    s.commit();
    try testing.expect(sn.node.?.kind.buffer.src == null);
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
    try testing.expect(!s.hasOutput(out));

    // The output covers the node: the next map enters it (the surface
    // module's setEntered fires events.enter; the binding's listener
    // sends the wire event — the fixture's view has no wl_output global,
    // so the wire send is a no-op; the surface module test covers the
    // signal side).
    so.x = 0;
    so.y = 0;
    s.attachBuffer(null);
    s.commit();
    try testing.expect(!s.hasOutput(out));
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.hasOutput(out));

    // Unmap leaves the output.
    s.attachBuffer(null);
    s.commit();
    try testing.expect(!s.mapped);
    try testing.expect(!s.hasOutput(out));
}

test "a surface spanning two outputs is on both, and leaves only the one it leaves" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, io, &log_cfg);
    defer scene.deinit();
    const first = try makeOutput(allocator, io, &log_cfg);
    const second = try makeOutput(allocator, io, &log_cfg);
    // Registered backend-first so LIFO teardown destroys each output
    // BEFORE its backend; the views' own defers, registered later, run
    // before both.
    defer first[1].destroy();
    defer first[0].destroy();
    defer second[1].destroy();
    defer second[0].destroy();

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    // Two views side by side in world space: left (0..800, 0..600) and
    // right (800..1600, 0..600).
    const so_left = try SceneOutput.create(allocator, io, &log_cfg, scene, first[0]);
    defer so_left.destroy();
    const so_right = try SceneOutput.create(allocator, io, &log_cfg, scene, second[0]);
    defer so_right.destroy();
    so_right.x = 800;
    so_right.y = 0;

    const sn = try trackSurface(scene, s, &test_impl, &ctx);
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();

    // The node starts on the left view only.
    try testing.expect(s.hasOutput(first[0]));
    try testing.expect(!s.hasOutput(second[0]));

    // Straddle the seam: a 10px surface at x=795 lands on both views, and
    // it must be entered on BOTH — the first match used to win.
    sn.node.?.setPosition(795, 10);
    updateOutputAssociations(scene);
    try testing.expect(s.hasOutput(first[0]));
    try testing.expect(s.hasOutput(second[0]));

    // Both views present it: the presented lists are per output, so a
    // surface on both appears in both and each list is cleared on its own
    // rebuild.
    collectPresented(scene, so_left);
    collectPresented(scene, so_right);
    try testing.expectEqual(@as(usize, 1), so_left.presented.items.len);
    try testing.expectEqual(@as(usize, 1), so_right.presented.items.len);
    try testing.expect(so_left.presented.items[0] == s);
    try testing.expect(so_right.presented.items[0] == s);

    // Move it fully onto the right view: only the left membership goes,
    // and only the left view stops presenting it.
    sn.node.?.setPosition(900, 10);
    updateOutputAssociations(scene);
    try testing.expect(!s.hasOutput(first[0]));
    try testing.expect(s.hasOutput(second[0]));
    collectPresented(scene, so_left);
    collectPresented(scene, so_right);
    try testing.expectEqual(@as(usize, 0), so_left.presented.items.len);
    try testing.expectEqual(@as(usize, 1), so_right.presented.items.len);

    // Unmapping leaves every output at once.
    sn.node.?.setPosition(795, 10);
    updateOutputAssociations(scene);
    try testing.expect(s.hasOutput(first[0]));
    try testing.expect(s.hasOutput(second[0]));
    s.attachBuffer(null);
    s.commit();
    try testing.expect(!s.hasOutput(first[0]));
    try testing.expect(!s.hasOutput(second[0]));
}

test "a destroyed output detaches its view and drops every membership through it" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    const scene = try makeScene(allocator, io, &log_cfg);
    defer scene.deinit();
    const created = try makeOutput(allocator, io, &log_cfg);
    const out = created[0];
    defer created[1].destroy();

    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    defer allocator.destroy(comp);
    defer tw.deinit();
    const s = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    const so = try SceneOutput.create(allocator, io, &log_cfg, scene, out);
    const sn = try trackSurface(scene, s, &test_impl, &ctx);
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.hasOutput(out));
    try testing.expectEqual(@as(usize, 1), scene.scene_outputs.items.len);

    // Unplug: the output dies first. Its view must leave the scene's
    // output list at once, so nothing iterates a dangling output, and the
    // surface must not stay entered on an output that no longer exists.
    // The view itself is freed by its owner afterwards, which is what
    // keeps this free in one place whatever the listener order is.
    out.destroy();
    try testing.expect(!so.live);
    try testing.expectEqual(@as(usize, 0), scene.scene_outputs.items.len);
    try testing.expect(!s.hasOutput(out));

    // The freed view leaves nothing behind: the scene is still usable and
    // the surface stays unmapped until the next commit.
    so.destroy();
    sn.updateOutputs();
    try testing.expect(!s.hasOutput(out));
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.mapped);
    try testing.expect(!s.hasOutput(out));
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
        .parent_map_listener = wire.Listener(*Surface).init(noopSurfaceListener),
        .parent_unmap_listener = wire.Listener(*Surface).init(noopSurfaceListener),
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

/// The parent whose mapped flag the test gate consults (the surface the
/// fake Subsurface links the child to). SAFETY: test fixture; set before
/// use, only read by testGateMapped during the test body.
var test_gate_parent: ?*Surface = null;

/// Simulates the real subsurface mapped_gate (subsurface.zig
/// subsurfaceMappedGate): the child maps only when its parent is mapped.
fn testGateMapped(_: *Surface) bool {
    const p = test_gate_parent orelse return true;
    return p.mapped;
}

test "hidden subsurface is not presented" {
    const allocator = testing.allocator;
    var io_storage = std.Io.Threaded.global_single_threaded.io();
    const io: *std.Io = &io_storage;
    var log_cfg: log.Config = .{ .min_level = .err };

    // Teardown order (LIFO), same as the nesting test: the client (and
    // with it every surface) dies while comp + fake_sub are alive, then
    // the scene, then the fake registry, then the compositor.
    const scene = try makeScene(allocator, io, &log_cfg);
    var tw = try surface_mod.TestWire.init();
    const comp = try surface_mod.testCompositor(allocator, io, &log_cfg);
    const parent = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    const child = try surface_mod.testSurface(allocator, io, &log_cfg, comp, &tw);
    var ctx: TestCtx = .{ .allocator = allocator };

    // A fake subcompositor registry: one Subsurface entry linking
    // child -> parent (the scene only reads the list).
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
        .parent_map_listener = wire.Listener(*Surface).init(noopSurfaceListener),
        .parent_unmap_listener = wire.Listener(*Surface).init(noopSurfaceListener),
    };
    fake_sub.subsurfaces.append(allocator, ss) catch unreachable;

    defer allocator.destroy(comp);
    defer allocator.destroy(ss);
    defer allocator.destroy(fake_sub);
    defer fake_sub.subsurfaces.deinit(allocator);
    defer scene.deinit();
    defer tw.deinit();

    // An output covers the origin (the node's position): a mapped child
    // would enter it.
    const created = try makeOutput(allocator, io, &log_cfg);
    const out = created[0];
    defer out.destroy();
    defer created[1].destroy();
    const so = try SceneOutput.create(allocator, io, &log_cfg, scene, out);
    defer so.destroy();
    try testing.expectEqual(@as(usize, 1), scene.scene_outputs.items.len);

    // Gate the child's mapped state on the parent chain, mirroring the
    // real subsurface role's mapped_gate (subsurface.zig).
    var gate_role: role_mod.SurfaceRole = .{ .name = "test-subsurface-gate", .mapped_gate = testGateMapped };
    test_gate_parent = parent;
    try role_mod.assignRole(child, &gate_role, null);

    const child_sn = try trackSurface(scene, child, &test_impl, &ctx);
    const parent_sn = try trackSurface(scene, parent, &test_impl, &ctx);

    // The child commits a buffer while the parent is unmapped: it does
    // NOT map (parent gate), so it gets no enter and is not presented —
    // even though its scene node exists (created buffer-driven).
    var child_buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &child_buffer);
    child.attachBuffer(&child_buffer);
    child.commit();
    try testing.expect(!child.mapped);
    try testing.expect(child_sn.node != null);
    try testing.expect(!child.hasOutput(out));
    collectPresented(scene, so);
    try testing.expectEqual(@as(usize, 0), so.presented.items.len);

    // The parent maps: the child's effective map follows (the real
    // subsurface parent_map_listener drives child.updateMapped here), the
    // map signal recomputes the enter tracking, and the child is
    // presented.
    var parent_buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &parent_buffer);
    parent.attachBuffer(&parent_buffer);
    parent.commit();
    try testing.expect(parent.mapped);
    // The compositor's subsurface placement pass moves the disabled
    // placeholder under its now-mapped parent before presentation.
    try parent_sn.tree.?.appendChild(allocator, child_sn.tree.?);
    child_sn.tree.?.enable(true);
    child.updateMapped();
    try testing.expect(child.mapped);
    try testing.expect(child.hasOutput(out));
    collectPresented(scene, so);
    var child_presented = false;
    for (so.presented.items) |p| {
        if (p == child) child_presented = true;
    }
    try testing.expect(child_presented);

    // The parent unmaps: the child unmaps with it (recursive rule) and
    // drops out of the presented list.
    parent.attachBuffer(null);
    parent.commit();
    try testing.expect(!parent.mapped);
    child.updateMapped();
    try testing.expect(!child.mapped);
    try testing.expect(!child.hasOutput(out));
    collectPresented(scene, so);
    try testing.expectEqual(@as(usize, 0), so.presented.items.len);
}

// --- Real-wire output teardown --------------------------------------------
//
// wl_surface.leave is the only way a client learns an output went away, and
// it must name THAT output's wl_output object — never another output's, and
// never nothing. The harness below is deliberately wire-level: a real
// display, real wl_compositor and wl_output globals, a real libwayland
// client that binds every output and owns the wl_surface, and a client-side
// listener that decodes every enter/leave by the wl_output object it named.
// A copied Signal payload would still pass while the wire event is dropped.

const client = @import("protocol").client;
const display_mod = @import("../core/display.zig");
const compositor_mod = @import("../compositor/compositor.zig");
const wl_output_mod = @import("../output/wl_output.zig");
const test_pump = @import("../utils/test_pump.zig");
const posix = std.posix;

/// Outputs the harness runs: two monitors, plus one replugged later.
const wire_slots = 3;

fn ignoreWireOutputEvents(_: *client.wl.Output, _: client.wl.Output.Event, _: *u8) void {}

/// The client's registry listener: the globals this harness must bind.
/// wl_output globals are recorded in announcement order, which is the order
/// the server created them in.
const WireCapture = struct {
    compositor_name: ?u32 = null,
    output_names: [wire_slots]u32 = undefined,
    output_count: usize = 0,

    fn listener(registry: *client.wl.Registry, event: client.wl.Registry.Event, data: *WireCapture) void {
        _ = registry;
        switch (event) {
            .global => |g| {
                const iface = std.mem.span(g.interface);
                if (std.mem.eql(u8, iface, "wl_compositor")) {
                    data.compositor_name = g.name;
                } else if (std.mem.eql(u8, iface, "wl_output")) {
                    if (data.output_count < data.output_names.len) {
                        data.output_names[data.output_count] = g.name;
                        data.output_count += 1;
                    }
                }
            },
            // A withdrawn global says nothing about the surface; the
            // wl_surface.leave that follows it is what the test reads.
            .global_remove => {},
        }
    }
};

/// The client's wl_surface listener: which wl_output object each real
/// enter/leave event named. Object identity is the whole point — a leave
/// carrying the wrong output, or none at all, is the defect.
const WireSurfaceEvents = struct {
    entered: [8]?*client.wl.Output = @splat(null),
    enter_count: usize = 0,
    left: [8]?*client.wl.Output = @splat(null),
    leave_count: usize = 0,

    fn entersFor(e: *const WireSurfaceEvents, name: *client.wl.Output) usize {
        return countNamed(e.entered[0..e.enter_count], name);
    }

    fn leavesFor(e: *const WireSurfaceEvents, name: *client.wl.Output) usize {
        return countNamed(e.left[0..e.leave_count], name);
    }

    fn countNamed(list: []const ?*client.wl.Output, name: *client.wl.Output) usize {
        var n: usize = 0;
        for (list) |o| {
            if (o == name) n += 1;
        }
        return n;
    }

    fn listener(surface: *client.wl.Surface, event: client.wl.Surface.Event, data: *WireSurfaceEvents) void {
        _ = surface;
        switch (event) {
            .enter => |e| {
                if (data.enter_count < data.entered.len) {
                    data.entered[data.enter_count] = e.output;
                    data.enter_count += 1;
                }
            },
            .leave => |e| {
                if (data.leave_count < data.left.len) {
                    data.left[data.leave_count] = e.output;
                    data.leave_count += 1;
                }
            },
            else => {},
        }
    }
};

/// Display + compositor + two monitors (each with a wl_output global) + the
/// scene + one in-memory client that binds every output and owns the
/// wl_surface under test. The harness owns the whole graph because its
/// teardown order is the contract: views, then the scene, then the client
/// (whose wl_surface destructor runs the binding teardown), then the
/// outputs, then the display.
const WireHarness = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log_cfg: log.Config,
    ctx: TestCtx,
    /// Backing byte for the fake output/backend impls; never dereferenced.
    dummy: u8 = 0,
    display: ?*display_mod.CompositorDisplay = null,
    compositor: ?*compositor_mod.Compositor = null,
    compositor_proxy: ?*client.wl.Compositor = null,
    scene: ?*Scene = null,
    client_wire: ?*wire.Client = null,
    c_display: ?*client.wl.Display = null,
    registry: ?*client.wl.Registry = null,
    capture: WireCapture = .{},
    /// Listener data for the bound wl_output proxies (ignored).
    proxy_data: u8 = 0,
    out: [wire_slots]?*output_mod.Output = @splat(null),
    backend: [wire_slots]?*backend_mod.Backend = @splat(null),
    wl_output: [wire_slots]?*wl_output_mod.WlOutput = @splat(null),
    view: [wire_slots]?*SceneOutput = @splat(null),
    /// The client's wl_output proxies, in bind order.
    proxy: [wire_slots]?*client.wl.Output = @splat(null),
    events: WireSurfaceEvents = .{},
    surface: ?*Surface = null,

    fn init(allocator: std.mem.Allocator) !*WireHarness {
        const h = try allocator.create(WireHarness);
        h.* = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .log_cfg = .{ .min_level = .err },
            .ctx = .{ .allocator = allocator },
        };
        // deinit frees h, so it is the only teardown errdefer.
        errdefer h.deinit();
        h.display = try display_mod.CompositorDisplay.init(allocator, &h.io, &h.log_cfg);
        try h.display.?.initShm();
        h.compositor = try compositor_mod.Compositor.init(allocator, &h.io, &h.log_cfg, h.display.?);
        h.scene = try makeScene(allocator, &h.io, &h.log_cfg);
        try h.addOutput(0);
        try h.addOutput(1);

        var fds: [2]posix.socket_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (posix.errno(rc) != .SUCCESS) return error.SocketpairFailed;
        h.client_wire = wire.Client.create(h.display.?.getServer(), fds[0]) orelse return error.ClientCreateFailed;
        h.c_display = client.wl.Display.connectToFd(fds[1]) catch return error.ClientConnectFailed;
        h.registry = try h.c_display.?.getRegistry();
        h.registry.?.setListener(*WireCapture, WireCapture.listener, &h.capture);
        try h.pump();
        const compositor_name = h.capture.compositor_name orelse return error.GlobalMissing;
        if (h.capture.output_count < 2) return error.GlobalMissing;
        h.compositor_proxy = try h.registry.?.bind(compositor_name, client.wl.Compositor, 7);
        try h.bindOutput(0);
        try h.bindOutput(1);
        try h.pump();
        return h;
    }

    fn deinit(h: *WireHarness) void {
        const allocator = h.allocator;
        // Views first: each SceneOutput reads the scene's allocator and its
        // own output, so both must still be live.
        for (&h.view) |*slot| {
            if (slot.*) |so| {
                slot.* = null;
                so.destroy();
            }
        }
        // Then the scene, while its bindings still exist.
        if (h.scene) |s| {
            h.scene = null;
            s.deinit();
        }
        // The client next: its wl_surface destructor runs the surface
        // teardown against the live compositor.
        if (h.c_display) |d| d.disconnect();
        if (h.client_wire) |c| {
            h.client_wire = null;
            c.destroy();
        }
        if (h.compositor) |c| {
            h.compositor = null;
            c.deinit();
        }
        // Outputs: each destroy withdraws its wl_output global and then
        // frees it in the finalize phase, after every destroy listener.
        // Backends go last.
        for (&h.out) |*slot| {
            if (slot.*) |out| {
                slot.* = null;
                out.destroy();
            }
        }
        for (&h.backend) |*slot| {
            if (slot.*) |b| {
                slot.* = null;
                b.destroy();
            }
        }
        if (h.display) |d| {
            h.display = null;
            d.deinit();
        }
        allocator.destroy(h);
    }

    fn addOutput(h: *WireHarness, index: usize) !void {
        const backend = try backend_mod.Backend.init(h.allocator, &h.io, &h.log_cfg, &fake_backend_impl, &h.dummy);
        h.backend[index] = backend;
        h.out[index] = try output_mod.Output.create(
            h.allocator,
            &h.io,
            &h.log_cfg,
            backend,
            &fake_output_impl,
            &h.dummy,
            .{ .width = 800, .height = 600, .refresh_msec = 16 },
        );
        h.wl_output[index] = try wl_output_mod.WlOutput.create(
            h.allocator,
            &h.io,
            &h.log_cfg,
            h.display.?,
            h.out[index].?,
            "WL-1",
            "scene wire test output",
        );
    }

    fn bindOutput(h: *WireHarness, index: usize) !void {
        const proxy = try h.registry.?.bind(
            h.capture.output_names[index],
            client.wl.Output,
            wl_output_mod.output_version,
        );
        proxy.setListener(*u8, ignoreWireOutputEvents, &h.proxy_data);
        h.proxy[index] = proxy;
    }

    /// The SceneOutput view of slot `index`, placed at world (x, y), with
    /// that output's wl_output global attached: the enter/leave events for
    /// this output ride this object and no other.
    fn addView(h: *WireHarness, index: usize, x: f64, y: f64) !*SceneOutput {
        const so = try SceneOutput.create(h.allocator, &h.io, &h.log_cfg, h.scene.?, h.out[index].?);
        h.view[index] = so;
        so.x = x;
        so.y = y;
        so.wl_output = h.wl_output[index];
        return so;
    }

    /// The client creates the wl_surface on the wire; the server side is
    /// the Compositor's Surface, whose resource belongs to this client.
    fn createSurface(h: *WireHarness) !*Surface {
        const proxy = try h.compositor_proxy.?.createSurface();
        proxy.setListener(*WireSurfaceEvents, WireSurfaceEvents.listener, &h.events);
        try h.pump();
        const c = h.compositor.?;
        if (c.surfaces.items.len == 0) return error.SurfaceMissing;
        h.surface = c.surfaces.items[c.surfaces.items.len - 1];
        return h.surface.?;
    }

    fn destroyOutput(h: *WireHarness, index: usize) void {
        const out = h.out[index].?;
        h.out[index] = null;
        out.destroy();
    }

    /// The view's owner frees the view (its output is gone or going).
    fn destroyView(h: *WireHarness, index: usize) void {
        const so = h.view[index].?;
        h.view[index] = null;
        so.destroy();
    }

    fn pump(h: *WireHarness) !void {
        try test_pump.roundtrip(h.c_display, h.display.?, 0);
        if (h.c_display) |d| {
            var fds = [_]posix.pollfd{.{ .fd = d.getFd(), .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&fds, 0) > 0) {
                if (d.dispatch() != .SUCCESS) {
                    // The server already destroyed this client.
                    h.client_wire = null;
                    return error.ClientDispatchFailed;
                }
            }
        }
    }
};

/// Which of the two output-destroy listeners runs first. Both link onto the
/// SAME output.events.destroy signal, and the order they were added in
/// decides whether the membership is revoked while the view is still
/// resolvable. The client's leave must not depend on it.
const LeaveOrder = enum { view_first, membership_first };

fn runUnplugLeaves(allocator: std.mem.Allocator, order: LeaveOrder) !void {
    var h = try WireHarness.init(allocator);
    defer h.deinit();
    const scene = h.scene.?;

    const out0 = h.out[0].?;
    const out1 = h.out[1].?;
    const proxy0 = h.proxy[0].?;
    const proxy1 = h.proxy[1].?;

    const s = try h.createSurface();
    const sn = try trackSurface(scene, s, &test_impl, &h.ctx);

    if (order == .view_first) {
        // Both views exist before the surface maps, so each SceneOutput's
        // destroy listener is linked on its output BEFORE the surface's
        // own output association is.
        _ = try h.addView(0, 0, 0);
        _ = try h.addView(1, 800, 0);
    }

    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    try testing.expect(s.mapped);

    if (order == .membership_first) {
        // The membership forms while the output still has no view, so the
        // association's destroy listener is linked BEFORE the
        // SceneOutput's. The view arrives a moment later, as a hotplug
        // does; the order must not change what the client is told.
        s.setEntered(out0);
        _ = try h.addView(0, 0, 0);
        _ = try h.addView(1, 800, 0);
    }

    // The surviving view, so the post-unplug assertions can read it.
    const so1 = h.view[1].?;

    // Straddle the seam: a 10px node at x=795 lands on both views.
    sn.node.?.setPosition(795, 10);
    updateOutputAssociations(scene);
    try testing.expect(s.hasOutput(out0));
    try testing.expect(s.hasOutput(out1));

    try h.pump();
    // The client really is on output 1: an enter named its own wl_output.
    try testing.expectEqual(@as(usize, 1), h.events.entersFor(proxy1));
    // In the view-first order output 0's view existed too, so that enter
    // was a real wire event as well.
    if (order == .view_first) try testing.expectEqual(@as(usize, 1), h.events.entersFor(proxy0));
    try testing.expectEqual(@as(usize, 0), h.events.leave_count);

    // Unplug: the output dies first. Its view detaches, the membership
    // through it goes, and the client must hear about it on THAT output's
    // wl_output object.
    h.destroyOutput(0);
    try testing.expect(!s.hasOutput(out0));
    try testing.expect(s.hasOutput(out1));
    try testing.expectEqual(@as(usize, 1), scene.scene_outputs.items.len);

    try h.pump();
    try testing.expectEqual(@as(usize, 1), h.events.leavesFor(proxy0));
    try testing.expectEqual(@as(usize, 0), h.events.leavesFor(proxy1));
    try testing.expectEqual(@as(usize, 1), h.events.leave_count);

    // The surviving view still presents the surface: one output leaving
    // must not take the other output's membership with it.
    collectPresented(scene, so1);
    try testing.expectEqual(@as(usize, 1), so1.presented.items.len);
    try testing.expect(so1.presented.items[0] == s);

    // The view's owner frees the view now that its output is gone.
    h.destroyView(0);

    // Replug: a fresh output at the left with its own wl_output global and
    // a fresh view. The surface enters it again with a real enter event,
    // so the teardown above did not leave the enter path dead.
    try h.addOutput(2);
    try h.pump();
    try h.bindOutput(2);
    // The bind must reach the server before the enter: the enter names
    // the server-side resource this bind creates.
    try h.pump();
    _ = try h.addView(2, 0, 0);
    updateOutputAssociations(scene);
    try testing.expect(s.hasOutput(h.out[2].?));
    try h.pump();
    try testing.expectEqual(@as(usize, 1), h.events.entersFor(h.proxy[2].?));
    // The unplug produced no further leave on either remaining output.
    try testing.expectEqual(@as(usize, 1), h.events.leave_count);
    try testing.expectEqual(@as(usize, 0), h.events.leavesFor(proxy1));
}

test "destroying an output sends the client wl_surface.leave for that output only (view destroy listener linked first)" {
    try runUnplugLeaves(testing.allocator, .view_first);
}

test "destroying an output sends the client wl_surface.leave for that output only (membership destroy listener linked first)" {
    try runUnplugLeaves(testing.allocator, .membership_first);
}

fn runViewDestroyLeaves(allocator: std.mem.Allocator) !void {
    var h = try WireHarness.init(allocator);
    defer h.deinit();
    const scene = h.scene.?;

    const out0 = h.out[0].?;
    const out1 = h.out[1].?;
    const proxy0 = h.proxy[0].?;
    const proxy1 = h.proxy[1].?;

    const s = try h.createSurface();
    const sn = try trackSurface(scene, s, &test_impl, &h.ctx);
    _ = try h.addView(0, 0, 0);
    const so1 = try h.addView(1, 800, 0);

    var buffer: Buffer = undefined;
    surface_mod.testBuffer(allocator, &buffer);
    s.attachBuffer(&buffer);
    s.commit();
    sn.node.?.setPosition(795, 10);
    updateOutputAssociations(scene);
    try testing.expect(s.hasOutput(out0));
    try testing.expect(s.hasOutput(out1));

    try h.pump();
    try testing.expectEqual(@as(usize, 1), h.events.entersFor(proxy0));
    try testing.expectEqual(@as(usize, 1), h.events.entersFor(proxy1));
    try testing.expectEqual(@as(usize, 0), h.events.leave_count);

    // The view's owner tears the view down while the output is still
    // alive: the membership it carried must be revoked with a leave on
    // that output's own wl_output, not dropped on the floor.
    h.destroyView(0);
    try testing.expectEqual(@as(usize, 1), scene.scene_outputs.items.len);

    try h.pump();
    try testing.expectEqual(@as(usize, 1), h.events.leavesFor(proxy0));
    try testing.expectEqual(@as(usize, 0), h.events.leavesFor(proxy1));
    try testing.expectEqual(@as(usize, 1), h.events.leave_count);
    try testing.expect(!s.hasOutput(out0));
    try testing.expect(s.hasOutput(out1));
    collectPresented(scene, so1);
    try testing.expectEqual(@as(usize, 1), so1.presented.items.len);
    try testing.expect(so1.presented.items[0] == s);

    // Unplug afterwards: the membership is already gone, so there is
    // nothing left to tell the client a second time.
    h.destroyOutput(0);
    try h.pump();
    try testing.expectEqual(@as(usize, 1), h.events.leave_count);
    try testing.expectEqual(@as(usize, 0), h.events.leavesFor(proxy1));
}

test "destroying the scene output view sends the client wl_surface.leave for that output only" {
    try runViewDestroyLeaves(testing.allocator);
}

test "output-local membership, presentation and damage follow pinning and ancestor visibility" {
    const h = try WireHarness.init(testing.allocator);
    defer h.deinit();
    const scene = h.scene.?;
    const first = try h.addView(0, 0, 0);
    const second = try h.addView(1, 800, 0);
    var camera = camera_mod.Camera{
        .center_x = 1e12,
        .center_y = -1e12,
        .zoom = 2,
        .rotation = std.math.pi / 2.0,
        .screen_w = 800,
        .screen_h = 600,
    };
    first.camera = &camera;
    second.camera = &camera;
    const Pin = struct {
        output: ?*output_mod.Output,

        fn classify(ctx: ?*anyopaque, _: *Surface) scene_mod.SurfacePlacement {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return .{ .output_local = self.output };
        }
    };
    var pin = Pin{ .output = h.out[0].? };
    scene.setSurfacePlacementPolicy(&pin, Pin.classify);
    defer scene.setSurfacePlacementPolicy(null, null);
    const surface = try h.createSurface();
    const sn = try trackSurface(scene, surface, &test_impl, &h.ctx);
    var buffer: Buffer = undefined;
    surface_mod.testBuffer(testing.allocator, &buffer);
    surface.attachBuffer(&buffer);
    surface.commit();
    try h.pump();
    try testing.expectEqual(@as(usize, 1), h.events.entersFor(h.proxy[0].?));
    try testing.expectEqual(@as(usize, 0), h.events.entersFor(h.proxy[1].?));
    collectPresented(scene, first);
    collectPresented(scene, second);
    try testing.expectEqualSlices(*Surface, &.{surface}, first.presented.items);
    try testing.expectEqualSlices(*Surface, &.{}, second.presented.items);

    camera.center_x += 1000;
    updateOutputAssociations(scene);
    try h.pump();
    try testing.expectEqual(@as(usize, 1), h.events.entersFor(h.proxy[0].?));
    try testing.expectEqual(@as(usize, 0), h.events.leave_count);

    // A commit queues only the damaged local pixels on the pinned output,
    // independent of the camera and without replacing unrelated damage.
    const partial = Rect{ .x = 4, .y = 5, .width = 2, .height = 3 };
    first.addDamage(partial);
    second.addDamage(partial);
    try surface.pending.surface_damage.add(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    surface.commit();
    first.damage_ring.rotate();
    second.damage_ring.rotate();
    const Damage = struct {
        fn contains(rects: []const Rect, x: i32, y: i32) bool {
            // This is the output consumer's whole-damage representation.
            if (rects.len == 0) return true;
            for (rects) |rect| {
                if (rect.containsPoint(.{ .x = x, .y = y })) return true;
            }
            return false;
        }
    };
    const damage = first.takeDamage();
    try testing.expect(Damage.contains(damage, 1, 2));
    try testing.expect(Damage.contains(damage, 3, 5));
    try testing.expect(Damage.contains(damage, 4, 5));
    try testing.expect(!Damage.contains(damage, 0, 0));
    try testing.expect(!Damage.contains(damage, 6, 5));
    try testing.expectEqualSlices(Rect, &.{partial}, second.takeDamage());

    const container = try SceneNode.create(testing.allocator, scene.root, .tree);
    try container.appendChild(testing.allocator, sn.tree.?);
    container.enable(false);
    updateOutputAssociations(scene);
    try h.pump();
    try testing.expectEqual(@as(usize, 1), h.events.leavesFor(h.proxy[0].?));
    collectPresented(scene, first);
    try testing.expectEqualSlices(*Surface, &.{}, first.presented.items);
    first.addDamage(partial);
    sn.addDamage(first);
    first.damage_ring.rotate();
    try testing.expectEqualSlices(Rect, &.{partial}, first.takeDamage());

    container.enable(true);
    updateOutputAssociations(scene);
    try h.pump();
    try testing.expectEqual(@as(usize, 2), h.events.entersFor(h.proxy[0].?));
    pin.output = null;
    updateOutputAssociations(scene);
    try h.pump();
    try testing.expectEqual(@as(usize, 2), h.events.leavesFor(h.proxy[0].?));
    collectPresented(scene, first);
    collectPresented(scene, second);
    try testing.expectEqualSlices(*Surface, &.{}, first.presented.items);
    try testing.expectEqualSlices(*Surface, &.{}, second.presented.items);
}
