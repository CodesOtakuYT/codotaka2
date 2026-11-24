//! Scene layer: what is shown where, independent of GPUs.
//!
//! - A `Content` produces draws and says when it changed (damage) or will change (timers).
//! - A `Viewport` is one piece of content with a logical size, shown through `Part`s.
//! - A `Node` is a presentation surface (root or subsurface) with a rect in its parent.
//! - A `Part` maps a region of a node to a sub-rectangle of a viewport, so a viewport can
//!   span several nodes and a node can show several viewports.
//! - A `SceneWindow` owns the tree for one toplevel, runs layout, routes input, and plans
//!   each frame: only nodes touched by dirty viewports are rendered, with damage limited
//!   to the dirty regions, and nothing is committed when nothing changed.
//!
//! Nodes and viewports are referenced by generation-checked ids, so removing one can
//! never leave dangling references behind.
const std = @import("std");
const wl = @import("wl");
const geom = @import("geom");
const frame = @import("frame");
const SlotMap = @import("slot_map").SlotMap;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.scene);

pub const LogicalRect = geom.LogicalRect;

pub const FrameTime = struct {
    now_ns: i128,
    /// Predicted presentation time of the frame being planned (from wp_presentation).
    target_ns: i128,
    refresh_ns: u32,

    /// When to wake so that the predicted presentation time is >= `t`. Presentation times
    /// move on the vsync grid, so waking at `t - refresh` can be too early (and then the
    /// deadline is in the past while the content is not due yet: a busy loop).
    pub fn wakeToPresentAt(ft: FrameTime, t: i128) i128 {
        if (ft.refresh_ns == 0) return t;
        const r: i128 = ft.refresh_ns;
        if (t <= ft.target_ns) return ft.now_ns; // due already
        // The first vsync at or after t (on the grid through target_ns) becomes the
        // predicted target exactly one refresh before it.
        const steps = std.math.divCeil(i128, t - ft.target_ns, r) catch unreachable;
        return ft.target_ns + steps * r - r;
    }
};

test "wakeToPresentAt snaps to the vsync grid" {
    // 10 ms refresh; now = 1, next predicted vsync at 10.
    const ft: FrameTime = .{ .now_ns = 1, .target_ns = 10, .refresh_ns = 10 };
    try std.testing.expectEqual(@as(i128, 1), ft.wakeToPresentAt(10)); // due at this vsync
    try std.testing.expectEqual(@as(i128, 10), ft.wakeToPresentAt(15)); // vsync 20 is predicted from t=10
    try std.testing.expectEqual(@as(i128, 10), ft.wakeToPresentAt(20));
    try std.testing.expectEqual(@as(i128, 20), ft.wakeToPresentAt(21));
}

pub const Update = struct {
    dirty: bool = false,
    /// When this content will next change on its own (absolute, CLOCK_MONOTONIC ns).
    next_wake_ns: ?i128 = null,
};

pub const DrawContext = struct {
    /// Size of the whole viewport in buffer pixels.
    size_px: [2]f32,
    /// Buffer pixels per logical pixel.
    scale: f32,
    /// Output value of reference white for the target's color encoding.
    white_scale: f32,
    color: wl.ColorMode,
};

pub const Content = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque, ft: FrameTime) Update,
        /// Appends this content's draws (in order) for the viewport.
        draw: *const fn (ptr: *anyopaque, ctx: DrawContext, out: *frame.DrawList) anyerror!void,
    };
};

/// `Target` must provide `fn needsRealloc(*const Target) bool` (redraw everything when true).
pub fn Scene(comptime Target: type) type {
    return struct {
        pub const TargetWork = frame.TargetWork(Target);
        pub const TreeWork = frame.TreeWork(Target);

        /// Creates/destroys targets for new nodes (e.g. on the window's GPU).
        pub const TargetFactory = struct {
            ctx: *anyopaque,
            create: *const fn (ctx: *anyopaque, surface: *wl.Surface) anyerror!*Target,
            destroy: *const fn (ctx: *anyopaque, target: *Target) void,
        };

        pub const Node = struct {
            name: []const u8,
            surface: *wl.Surface,
            target: *Target,
            /// Logical rect relative to the parent node.
            rect: LogicalRect = .{ .width = 1, .height = 1 },
            /// Redraw everything with full damage on the next frame.
            redraw: bool = true,
        };

        pub const Part = struct {
            node: NodeId,
            /// Region of the node, node-local logical pixels.
            region: LogicalRect,
            /// Where `region`'s top-left lies inside the viewport (logical).
            offset_x: i32 = 0,
            offset_y: i32 = 0,
        };

        pub const Viewport = struct {
            content: Content,
            width: u32 = 1,
            height: u32 = 1,
            parts: std.ArrayList(Part) = .empty,
            dirty: bool = true,
        };

        const Nodes = SlotMap(*Node);
        const Viewports = SlotMap(*Viewport);
        pub const NodeId = Nodes.Id;
        pub const ViewportId = Viewports.Id;

        pub const Hooks = struct {
            ctx: *anyopaque,
            /// Places nodes and viewports for the current window size/state.
            layout: *const fn (ctx: *anyopaque, sw: *SceneWindow) anyerror!void,
            pointer: ?*const fn (ctx: *anyopaque, sw: *SceneWindow, ev: wl.PointerEvent) void = null,
            key: ?*const fn (ctx: *anyopaque, sw: *SceneWindow, ev: wl.KeyEvent) void = null,
        };

        pub const SceneWindow = struct {
            gpa: Allocator,
            window: *wl.Window,
            color: wl.ColorMode,
            white_scale: f32,
            factory: TargetFactory,
            hooks: Hooks,
            nodes: Nodes = .empty,
            /// Creation order (parents before children), for commit and teardown order.
            node_order: std.ArrayList(NodeId) = .empty,
            viewports: Viewports = .empty,
            root: NodeId,

            next_wake_ns: ?i128 = null,
            committed: bool = false,

            /// Takes ownership of `window` and `root_target`.
            pub fn create(
                gpa: Allocator,
                window: *wl.Window,
                root_target: *Target,
                color: wl.ColorMode,
                white_scale: f32,
                factory: TargetFactory,
                hooks: Hooks,
            ) !*SceneWindow {
                const self = try gpa.create(SceneWindow);
                errdefer gpa.destroy(self);
                self.* = .{
                    .gpa = gpa,
                    .window = window,
                    .color = color,
                    .white_scale = white_scale,
                    .factory = factory,
                    .hooks = hooks,
                    .root = undefined,
                };
                const root_node = try gpa.create(Node);
                errdefer gpa.destroy(root_node);
                root_node.* = .{ .name = "root", .surface = window.root, .target = root_target };
                self.root = try self.nodes.insert(gpa, root_node);
                try self.node_order.append(gpa, self.root);
                window.pointer_handler = .{ .ctx = self, .func = onPointer };
                window.key_handler = .{ .ctx = self, .func = onKey };
                return self;
            }

            pub fn destroy(self: *SceneWindow) void {
                var vit = self.viewports.iterator();
                while (vit.next()) |e| {
                    e.value.*.parts.deinit(self.gpa);
                    self.gpa.destroy(e.value.*);
                }
                self.viewports.deinit(self.gpa);
                // Children before parents.
                var i = self.node_order.items.len;
                while (i > 0) {
                    i -= 1;
                    const n = self.nodes.get(self.node_order.items[i]).?.*;
                    self.factory.destroy(self.factory.ctx, n.target);
                    self.gpa.destroy(n);
                }
                self.node_order.deinit(self.gpa);
                self.nodes.deinit(self.gpa);
                self.window.destroy();
                self.gpa.destroy(self);
            }

            pub fn node(self: *SceneWindow, id: NodeId) ?*Node {
                return if (self.nodes.get(id)) |n| n.* else null;
            }

            pub fn viewport(self: *SceneWindow, id: ViewportId) ?*Viewport {
                return if (self.viewports.get(id)) |v| v.* else null;
            }

            pub fn rootNode(self: *SceneWindow) *Node {
                return self.node(self.root).?;
            }

            /// Iterates live nodes in creation order.
            pub fn nodeList(self: *SceneWindow) NodeIterator {
                return .{ .sw = self };
            }

            pub const NodeIterator = struct {
                sw: *SceneWindow,
                i: usize = 0,
                pub fn next(it: *NodeIterator) ?*Node {
                    while (it.i < it.sw.node_order.items.len) {
                        const id = it.sw.node_order.items[it.i];
                        it.i += 1;
                        if (it.sw.node(id)) |n| return n;
                    }
                    return null;
                }
            };

            /// Adds a subsurface node under `parent`.
            pub fn addNode(self: *SceneWindow, name: []const u8, parent: NodeId) !NodeId {
                const p = self.node(parent) orelse return error.StaleNode;
                try self.node_order.ensureUnusedCapacity(self.gpa, 1);
                const surface = try self.window.createSubsurface(p.surface);
                errdefer self.window.destroySubsurface(surface);
                const target = try self.factory.create(self.factory.ctx, surface);
                errdefer self.factory.destroy(self.factory.ctx, target);
                const n = try self.gpa.create(Node);
                errdefer self.gpa.destroy(n);
                n.* = .{ .name = name, .surface = surface, .target = target };
                const id = try self.nodes.insert(self.gpa, n);
                self.node_order.appendAssumeCapacity(id);
                return id;
            }

            /// Removes a subsurface node. Parts showing it become inert; the root redraws.
            pub fn removeNode(self: *SceneWindow, id: NodeId) void {
                std.debug.assert(!id.eql(self.root));
                const n = self.nodes.remove(id) orelse return;
                for (self.node_order.items, 0..) |o, i| if (o.eql(id)) {
                    _ = self.node_order.orderedRemove(i);
                    break;
                };
                var vit = self.viewports.iterator();
                while (vit.next()) |e| {
                    const v = e.value.*;
                    var i: usize = 0;
                    while (i < v.parts.items.len) {
                        if (v.parts.items[i].node.eql(id)) {
                            _ = v.parts.orderedRemove(i);
                            v.dirty = true;
                        } else i += 1;
                    }
                }
                self.factory.destroy(self.factory.ctx, n.target);
                self.window.destroySubsurface(n.surface);
                self.gpa.destroy(n);
                self.rootNode().redraw = true;
            }

            pub fn setNodeRect(self: *SceneWindow, id: NodeId, rect: LogicalRect) void {
                const n = self.node(id) orelse return;
                if (n.rect.eql(rect)) return;
                n.rect = rect;
                n.surface.setSize(rect.width, rect.height);
                n.surface.setPosition(rect.x, rect.y);
                n.redraw = true;
            }

            pub fn addViewport(self: *SceneWindow, content: Content) !ViewportId {
                const v = try self.gpa.create(Viewport);
                errdefer self.gpa.destroy(v);
                v.* = .{ .content = content };
                return self.viewports.insert(self.gpa, v);
            }

            pub fn removeViewport(self: *SceneWindow, id: ViewportId) void {
                const v = self.viewports.remove(id) orelse return;
                for (v.parts.items) |p| if (self.node(p.node)) |n| {
                    n.redraw = true;
                };
                v.parts.deinit(self.gpa);
                self.gpa.destroy(v);
            }

            /// Sets a viewport's logical size and drops its parts (re-`place` them).
            pub fn resetViewport(self: *SceneWindow, id: ViewportId, width: u32, height: u32) void {
                const v = self.viewport(id) orelse return;
                v.width = width;
                v.height = height;
                v.parts.clearRetainingCapacity();
                v.dirty = true;
            }

            pub fn place(self: *SceneWindow, id: ViewportId, part: Part) !void {
                const v = self.viewport(id) orelse return error.StaleViewport;
                try v.parts.append(self.gpa, part);
                v.dirty = true;
            }

            pub fn markDirty(self: *SceneWindow, id: ViewportId) void {
                if (self.viewport(id)) |v| v.dirty = true;
            }

            fn onPointer(ctx: *anyopaque, ev: wl.PointerEvent) void {
                const self: *SceneWindow = @ptrCast(@alignCast(ctx));
                if (self.hooks.pointer) |f| f(self.hooks.ctx, self, ev);
            }

            fn onKey(ctx: *anyopaque, ev: wl.KeyEvent) void {
                const self: *SceneWindow = @ptrCast(@alignCast(ctx));
                if (self.hooks.key) |f| f(self.hooks.ctx, self, ev);
            }

            fn relayout(self: *SceneWindow) !void {
                const w = self.window;
                w.layout_dirty = false;
                w.setGeometry();
                self.setNodeRect(self.root, .{ .width = w.width, .height = w.height });
                try self.hooks.layout(self.hooks.ctx, self);
                var vit = self.viewports.iterator();
                while (vit.next()) |e| e.value.*.dirty = true;
                var nit = self.nodeList();
                while (nit.next()) |n| n.redraw = true;
            }

            /// Predicts when the next frame will be presented, from the root's feedback.
            pub fn frameTime(self: *const SceneWindow, now_ns: i128) FrameTime {
                const st = self.window.root.stats;
                if (st.refresh_ns == 0 or st.last_present_ns == 0) return .{ .now_ns = now_ns, .target_ns = now_ns, .refresh_ns = 0 };
                const refresh: i128 = st.refresh_ns;
                const elapsed = @max(0, now_ns - st.last_present_ns);
                return .{
                    .now_ns = now_ns,
                    .target_ns = st.last_present_ns + (@divFloor(elapsed, refresh) + 1) * refresh,
                    .refresh_ns = st.refresh_ns,
                };
            }

            /// Plans this window's frame into `arena`. Null when nothing needs presenting now.
            pub fn plan(self: *SceneWindow, arena: Allocator, ft: FrameTime) !?TreeWork {
                self.committed = false;
                self.next_wake_ns = null;
                if (self.window.layout_dirty) try self.relayout();

                var vit = self.viewports.iterator();
                while (vit.next()) |e| {
                    const v = e.value.*;
                    const u = v.content.vtable.update(v.content.ptr, ft);
                    if (u.dirty) v.dirty = true;
                    if (u.next_wake_ns) |t| self.next_wake_ns = if (self.next_wake_ns) |cur| @min(cur, t) else t;
                }
                // Waiting for the compositor's frame callback: it wakes us; content deadlines
                // that already passed must not turn the event loop into a busy wait.
                if (!self.window.frame_ready) {
                    self.next_wake_ns = null;
                    return null;
                }

                const scale = self.window.scale;
                var work: std.ArrayList(TargetWork) = .empty;
                for (self.node_order.items) |nid| {
                    const n = self.node(nid) orelse continue;
                    const full = n.redraw or n.target.needsRealloc();
                    var touched = full;
                    var it = self.viewports.iterator();
                    while (it.next()) |e| {
                        if (!e.value.*.dirty) continue;
                        for (e.value.*.parts.items) |p| touched = touched or p.node.eql(nid);
                    }
                    if (!touched) continue;

                    var views: std.ArrayList(frame.View) = .empty;
                    var damage: std.ArrayList(geom.BufferRect) = .empty;
                    it = self.viewports.iterator();
                    while (it.next()) |e| {
                        const v = e.value.*;
                        for (v.parts.items) |p| {
                            if (!p.node.eql(nid)) continue;
                            const scissor = scale.rect(p.region);
                            const size_px = [2]f32{ scale.coordF(@intCast(v.width)), scale.coordF(@intCast(v.height)) };
                            var list: frame.DrawList = .{ .arena = arena };
                            try v.content.vtable.draw(v.content.ptr, .{
                                .size_px = size_px,
                                .scale = scale.factor(),
                                .white_scale = self.white_scale,
                                .color = self.color,
                            }, &list);
                            for (list.draws.items) |d| try views.append(arena, .{
                                .viewport = .{
                                    .x = scale.coordF(p.region.x - p.offset_x),
                                    .y = scale.coordF(p.region.y - p.offset_y),
                                    .width = size_px[0],
                                    .height = size_px[1],
                                },
                                .scissor = scissor,
                                .draw = d,
                            });
                            if (!full and v.dirty) try damage.append(arena, scissor);
                        }
                    }
                    try work.append(arena, .{ .target = n.target, .views = views.items, .damage = if (full) &.{} else damage.items });
                }
                if (work.items.len == 0) return null;
                return .{ .window = self.window, .targets = work.items, .committed = &self.committed };
            }

            /// Call after the frame; clears damage state if this tree was committed.
            pub fn afterFrame(self: *SceneWindow) void {
                if (!self.committed) return;
                var vit = self.viewports.iterator();
                while (vit.next()) |e| e.value.*.dirty = false;
                var nit = self.nodeList();
                while (nit.next()) |n| n.redraw = false;
            }
        };
    };
}
