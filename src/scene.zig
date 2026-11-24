//! Scene layer: what is shown where, independent of GPUs and of the Wayland object model.
//!
//! - A `Content` produces draws and says when it changed (damage) or will change (timers).
//! - A `Viewport` is one piece of content with a logical size, shown through `Part`s.
//! - A `Node` is a presentation surface (root or subsurface) with a rect in its parent.
//! - A `Part` maps a region of a node to a sub-rectangle of a viewport, so a viewport can
//!   span several nodes and a node can show several viewports.
//! - A `SceneWindow` owns the tree for one toplevel, runs layout, routes input, and plans
//!   each frame: only nodes touched by dirty viewports are rendered, with damage limited to
//!   the dirty regions, and nothing is committed when nothing changed.
const std = @import("std");
const wayland = @import("wayland.zig");
const Device = @import("gfx/Device.zig");
const Renderer = @import("gfx/Renderer.zig");
const SurfaceTarget = @import("gfx/SurfaceTarget.zig");
const Decoration = @import("decoration.zig").Decoration;
const Allocator = std.mem.Allocator;

pub const Rect = Renderer.Rect;

pub const FrameTime = struct {
    now_ns: i128,
    /// Predicted presentation time of the frame being planned (from wp_presentation).
    target_ns: i128,
    refresh_ns: u32,
};

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
    /// Output value of reference white for the target's color mode.
    white_scale: f32,
    color: wayland.ColorMode,
};

pub const Content = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque, ft: FrameTime) Update,
        draw: *const fn (ptr: *anyopaque, ctx: DrawContext) Renderer.Draw,
    };
};

pub const Node = struct {
    name: []const u8,
    surface: *wayland.Surface,
    target: *SurfaceTarget,
    /// Logical rect relative to the parent node.
    rect: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    /// Redraw everything with full damage on the next frame.
    redraw: bool = true,

    pub fn setRect(n: *Node, rect: Rect) void {
        if (std.meta.eql(n.rect, rect)) return;
        n.rect = rect;
        n.surface.setSize(rect.width, rect.height);
        n.surface.setPosition(rect.x, rect.y);
        n.redraw = true;
    }
};

pub const Part = struct {
    node: *Node,
    /// Region of the node, node-local logical pixels.
    region: Rect,
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

    pub fn clearParts(v: *Viewport) void {
        v.parts.clearRetainingCapacity();
        v.dirty = true;
    }
};

pub const Layout = struct {
    ctx: *anyopaque,
    /// Places nodes and viewports inside `content` (logical, window coordinates).
    layout: *const fn (ctx: *anyopaque, sw: *SceneWindow, content: Rect) anyerror!void,
    /// Pointer events not consumed by the decorations.
    pointer: ?*const fn (ctx: *anyopaque, sw: *SceneWindow, ev: wayland.PointerEvent) void = null,
};

pub const SceneWindow = struct {
    gpa: Allocator,
    window: *wayland.Window,
    device: *Device,
    color: wayland.ColorMode,
    root: *Node,
    /// All nodes including the root.
    nodes: std.ArrayList(*Node) = .empty,
    viewports: std.ArrayList(*Viewport) = .empty,
    decoration: *Decoration,
    user: Layout,

    next_wake_ns: ?i128 = null,
    committed: bool = false,

    pub fn create(
        gpa: Allocator,
        display: *wayland.Display,
        devices: []const *Device,
        preferred_device: usize,
        title: [:0]const u8,
        color: wayland.ColorMode,
        user: Layout,
    ) !*SceneWindow {
        const self = try gpa.create(SceneWindow);
        errdefer gpa.destroy(self);
        const window = try wayland.Window.create(display, title);
        errdefer window.destroy();
        self.* = .{
            .gpa = gpa,
            .window = window,
            .device = undefined,
            .color = color,
            .root = undefined,
            .decoration = undefined,
            .user = user,
        };

        // The whole tree lives on one device (one submit per tree). Pick the first device,
        // starting at `preferred_device`, whose dmabufs the compositor accepts for this window.
        var root_target: ?*SurfaceTarget = null;
        for (0..devices.len) |offset| {
            const dev = devices[(preferred_device + offset) % devices.len];
            root_target = SurfaceTarget.create(gpa, dev, window.root, color) catch |err| switch (err) {
                error.NoCompatibleTranche, error.ColorModeUnsupportedByDevice => continue,
                else => return err,
            };
            self.device = dev;
            break;
        }
        const target = root_target orelse return error.NoCompatibleDevice;
        errdefer target.destroy();

        self.root = try gpa.create(Node);
        errdefer gpa.destroy(self.root);
        self.root.* = .{ .name = "root", .surface = window.root, .target = target };
        try self.nodes.append(gpa, self.root);
        errdefer self.nodes.deinit(gpa);

        self.decoration = try Decoration.create(gpa, self, title);
        window.pointer_handler = .{ .ctx = self, .func = onPointer };
        return self;
    }

    pub fn destroy(self: *SceneWindow) void {
        self.decoration.destroy();
        for (self.viewports.items) |v| {
            v.parts.deinit(self.gpa);
            self.gpa.destroy(v);
        }
        self.viewports.deinit(self.gpa);
        // Children first, root last.
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const n = self.nodes.items[i];
            n.target.destroy();
            self.gpa.destroy(n);
        }
        self.nodes.deinit(self.gpa);
        self.window.destroy();
        self.gpa.destroy(self);
    }

    /// Adds a subsurface node under `parent`, on this window's device.
    pub fn addNode(self: *SceneWindow, name: []const u8, parent: *Node) !*Node {
        try self.nodes.ensureUnusedCapacity(self.gpa, 1);
        const surface = try self.window.createSubsurface(parent.surface);
        errdefer self.window.destroySubsurface(surface);
        const target = try SurfaceTarget.create(self.gpa, self.device, surface, self.color);
        errdefer target.destroy();
        const node = try self.gpa.create(Node);
        node.* = .{ .name = name, .surface = surface, .target = target };
        self.nodes.appendAssumeCapacity(node);
        return node;
    }

    /// Removes a subsurface node; parts showing it are dropped. Its parent is redrawn.
    pub fn removeNode(self: *SceneWindow, node: *Node) void {
        std.debug.assert(node != self.root);
        for (self.viewports.items) |v| {
            var i: usize = 0;
            while (i < v.parts.items.len) {
                if (v.parts.items[i].node == node) {
                    _ = v.parts.orderedRemove(i);
                    v.dirty = true;
                } else i += 1;
            }
        }
        if (std.mem.indexOfScalar(*Node, self.nodes.items, node)) |i| _ = self.nodes.orderedRemove(i);
        node.target.destroy();
        self.window.destroySubsurface(node.surface);
        self.gpa.destroy(node);
        self.root.redraw = true;
    }

    pub fn addViewport(self: *SceneWindow, content: Content) !*Viewport {
        try self.viewports.ensureUnusedCapacity(self.gpa, 1);
        const v = try self.gpa.create(Viewport);
        v.* = .{ .content = content };
        self.viewports.appendAssumeCapacity(v);
        return v;
    }

    pub fn removeViewport(self: *SceneWindow, v: *Viewport) void {
        for (v.parts.items) |p| p.node.redraw = true;
        if (std.mem.indexOfScalar(*Viewport, self.viewports.items, v)) |i| _ = self.viewports.orderedRemove(i);
        v.parts.deinit(self.gpa);
        self.gpa.destroy(v);
    }

    pub fn place(self: *SceneWindow, v: *Viewport, part: Part) !void {
        try v.parts.append(self.gpa, part);
        v.dirty = true;
    }

    fn onPointer(ctx: *anyopaque, ev: wayland.PointerEvent) void {
        const self: *SceneWindow = @ptrCast(@alignCast(ctx));
        if (self.decoration.pointer(ev)) return;
        if (self.user.pointer) |f| f(self.user.ctx, self, ev);
    }

    fn relayout(self: *SceneWindow) !void {
        const w = self.window;
        w.layout_dirty = false;
        w.setGeometry();
        self.root.setRect(.{ .x = 0, .y = 0, .width = w.width, .height = w.height });
        const bar = try self.decoration.layout();
        try self.user.layout(self.user.ctx, self, .{
            .x = 0,
            .y = @intCast(bar),
            .width = w.width,
            .height = w.height -| bar,
        });
        for (self.viewports.items) |v| v.dirty = true;
        for (self.nodes.items) |n| n.redraw = true;
    }

    fn whiteScale(self: *const SceneWindow) f32 {
        return switch (self.color) {
            .sdr => 1.0,
            // scRGB 1.0 = 80 cd/m²; map reference white to 203 cd/m² (BT.2408).
            .hdr_scrgb => 203.0 / 80.0,
        };
    }

    /// Predicts when the next frame will be presented, from the root's presentation feedback.
    pub fn frameTime(self: *const SceneWindow, now_ns: i128) FrameTime {
        const st = self.window.root.stats;
        if (st.refresh_ns == 0 or st.last_present_ns == 0) return .{ .now_ns = now_ns, .target_ns = now_ns, .refresh_ns = 0 };
        const refresh: i128 = st.refresh_ns;
        const elapsed = @max(0, now_ns - st.last_present_ns);
        const frames = @divFloor(elapsed, refresh) + 1;
        return .{ .now_ns = now_ns, .target_ns = st.last_present_ns + frames * refresh, .refresh_ns = st.refresh_ns };
    }

    /// Plans this window's frame. Returns null when nothing needs to be presented now.
    pub fn plan(self: *SceneWindow, arena: Allocator, ft: FrameTime) !?Device.TreeWork {
        self.committed = false;
        self.next_wake_ns = null;
        if (self.window.layout_dirty) try self.relayout();

        for (self.viewports.items) |v| {
            const u = v.content.vtable.update(v.content.ptr, ft);
            if (u.dirty) v.dirty = true;
            if (u.next_wake_ns) |t| self.next_wake_ns = if (self.next_wake_ns) |cur| @min(cur, t) else t;
        }
        if (!self.window.frame_ready) return null;

        const win = self.window;
        const scale = win.toBuffer(@as(f32, 1.0));
        var work: std.ArrayList(Device.TargetWork) = .empty;
        for (self.nodes.items) |n| {
            const full = n.redraw or n.target.needsRealloc();
            var touched = full;
            for (self.viewports.items) |v| {
                if (!v.dirty) continue;
                for (v.parts.items) |p| touched = touched or p.node == n;
            }
            if (!touched) continue;

            var views: std.ArrayList(Renderer.View) = .empty;
            var damage: std.ArrayList([4]i32) = .empty;
            for (self.viewports.items) |v| {
                for (v.parts.items) |p| {
                    if (p.node != n) continue;
                    const size_px = [2]f32{ win.toBuffer(@as(f32, @floatFromInt(v.width))), win.toBuffer(@as(f32, @floatFromInt(v.height))) };
                    const scissor: Rect = .{
                        .x = win.toBuffer(p.region.x),
                        .y = win.toBuffer(p.region.y),
                        .width = win.toBuffer(p.region.width),
                        .height = win.toBuffer(p.region.height),
                    };
                    try views.append(arena, .{
                        .viewport = .{
                            .x = win.toBuffer(@as(f32, @floatFromInt(p.region.x - p.offset_x))),
                            .y = win.toBuffer(@as(f32, @floatFromInt(p.region.y - p.offset_y))),
                            .width = size_px[0],
                            .height = size_px[1],
                        },
                        .scissor = scissor,
                        .draw = v.content.vtable.draw(v.content.ptr, .{
                            .size_px = size_px,
                            .scale = scale,
                            .white_scale = self.whiteScale(),
                            .color = self.color,
                        }),
                    });
                    if (!full and v.dirty) try damage.append(arena, .{ scissor.x, scissor.y, @intCast(scissor.width), @intCast(scissor.height) });
                }
            }
            try work.append(arena, .{ .target = n.target, .views = views.items, .damage = if (full) &.{} else damage.items });
        }
        if (work.items.len == 0) return null;
        return .{ .window = win, .targets = work.items, .committed = &self.committed };
    }

    /// Call after the frame was submitted; clears damage state if this tree was committed.
    pub fn afterFrame(self: *SceneWindow) void {
        if (!self.committed) return;
        for (self.viewports.items) |v| v.dirty = false;
        for (self.nodes.items) |n| n.redraw = false;
    }
};
