//! Client-side decorations drawn with Vulkan (no libdecor, no server-side decorations).
//! The title bar is an ordinary scene node + viewport, so it is damage-driven, fractionally
//! scaled and color-managed like any other content. Edges of the window resize it.
const std = @import("std");
const c = @import("c");
const wayland = @import("wayland.zig");
const scene = @import("scene.zig");
const Renderer = @import("gfx/Renderer.zig");
const Allocator = std.mem.Allocator;

/// Title bar height, logical pixels.
pub const bar_height = 32;
/// Width of the invisible resize border inside the window edges, logical pixels.
const border = 6;
const double_click_ms = 400;

const Button = enum(u32) { none = 0, minimize = 1, maximize = 2, close = 3 };

/// Push constants for shaders/decoration.frag.
const Push = extern struct {
    size: [2]f32,
    scale: f32,
    white_scale: f32,
    hover: u32,
    flags: u32,
    title_len: u32,
    pad: u32 = 0,
    chars: [16]u32,
};

pub const Decoration = struct {
    gpa: Allocator,
    sw: *scene.SceneWindow,
    node: ?*scene.Node = null,
    viewport: ?*scene.Viewport = null,
    title: [64]u8 = undefined,
    title_len: usize = 0,

    hover: Button = .none,
    pressed: Button = .none,
    /// Drawn state differs from the last frame.
    dirty: bool = true,
    drawn_focused: bool = false,
    drawn_maximized: bool = false,
    last_click_ms: ?u32 = null,
    cursor: u32 = 0,

    pub fn create(gpa: Allocator, sw: *scene.SceneWindow, title: []const u8) !*Decoration {
        const self = try gpa.create(Decoration);
        self.* = .{ .gpa = gpa, .sw = sw };
        self.title_len = @min(title.len, self.title.len);
        @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
        return self;
    }

    pub fn destroy(self: *Decoration) void {
        self.gpa.destroy(self);
    }

    fn visible(self: *const Decoration) bool {
        const w = self.sw.window;
        return w.csd and !w.fullscreen;
    }

    /// Creates, updates or removes the title bar node. Returns the bar height used.
    pub fn layout(self: *Decoration) !u32 {
        const sw = self.sw;
        if (!self.visible()) {
            if (self.viewport) |v| sw.removeViewport(v);
            if (self.node) |n| sw.removeNode(n);
            self.viewport = null;
            self.node = null;
            return 0;
        }
        if (self.node == null) self.node = try sw.addNode("titlebar", sw.root);
        if (self.viewport == null) self.viewport = try sw.addViewport(.{ .ptr = self, .vtable = &vtable });

        const w = sw.window.width;
        self.node.?.setRect(.{ .x = 0, .y = 0, .width = w, .height = bar_height });
        const v = self.viewport.?;
        v.width = w;
        v.height = bar_height;
        v.clearParts();
        try sw.place(v, .{ .node = self.node.?, .region = .{ .x = 0, .y = 0, .width = w, .height = bar_height } });
        self.dirty = true;
        return bar_height;
    }

    const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };

    fn update(ptr: *anyopaque, _: scene.FrameTime) scene.Update {
        const self: *Decoration = @ptrCast(@alignCast(ptr));
        const w = self.sw.window;
        if (w.activated != self.drawn_focused or w.maximized != self.drawn_maximized) self.dirty = true;
        const dirty = self.dirty;
        self.dirty = false;
        return .{ .dirty = dirty };
    }

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext) Renderer.Draw {
        const self: *Decoration = @ptrCast(@alignCast(ptr));
        const w = self.sw.window;
        self.drawn_focused = w.activated;
        self.drawn_maximized = w.maximized;
        var push: Push = .{
            .size = ctx.size_px,
            .scale = ctx.scale,
            .white_scale = ctx.white_scale,
            .hover = @intFromEnum(self.hover),
            .flags = @as(u32, @intFromBool(w.activated)) |
                (@as(u32, @intFromBool(w.maximized)) << 1) |
                (@as(u32, @intFromBool(self.pressed != .none and self.pressed == self.hover)) << 2),
            .title_len = @intCast(self.title_len),
            .chars = @splat(0),
        };
        @memcpy(std.mem.sliceAsBytes(&push.chars)[0..self.title_len], self.title[0..self.title_len]);
        return .init(.decoration, push);
    }

    fn buttonAt(self: *const Decoration, x: f64, y: f64) Button {
        if (y < 0 or y >= bar_height) return .none;
        const w: f64 = @floatFromInt(self.sw.window.width);
        const h: f64 = bar_height;
        if (x >= w - h) return .close;
        if (x >= w - 2 * h) return .maximize;
        if (x >= w - 3 * h) return .minimize;
        return .none;
    }

    fn edgeAt(self: *const Decoration, x: f64, y: f64) u32 {
        const w = self.sw.window;
        if (w.maximized or w.fullscreen or w.tiled) return c.XDG_TOPLEVEL_RESIZE_EDGE_NONE;
        const fw: f64 = @floatFromInt(w.width);
        const fh: f64 = @floatFromInt(w.height);
        var edge: u32 = 0;
        if (y < border) edge |= c.XDG_TOPLEVEL_RESIZE_EDGE_TOP;
        if (y >= fh - border) edge |= c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM;
        if (x < border) edge |= c.XDG_TOPLEVEL_RESIZE_EDGE_LEFT;
        if (x >= fw - border) edge |= c.XDG_TOPLEVEL_RESIZE_EDGE_RIGHT;
        return edge;
    }

    fn cursorFor(edge: u32) u32 {
        return switch (edge) {
            c.XDG_TOPLEVEL_RESIZE_EDGE_TOP => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_N_RESIZE,
            c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_S_RESIZE,
            c.XDG_TOPLEVEL_RESIZE_EDGE_LEFT => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_W_RESIZE,
            c.XDG_TOPLEVEL_RESIZE_EDGE_RIGHT => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_E_RESIZE,
            c.XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NW_RESIZE,
            c.XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NE_RESIZE,
            c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SW_RESIZE,
            c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SE_RESIZE,
            else => c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT,
        };
    }

    fn setHover(self: *Decoration, b: Button) void {
        if (b == self.hover) return;
        self.hover = b;
        self.dirty = true;
    }

    fn setCursor(self: *Decoration, shape: u32) void {
        if (shape == self.cursor) return;
        self.cursor = shape;
        self.sw.window.display.setCursor(shape);
    }

    /// Handles a pointer event. Returns true if it was consumed by the decorations.
    pub fn pointer(self: *Decoration, ev: wayland.PointerEvent) bool {
        const w = self.sw.window;
        if (ev.kind == .leave) {
            self.setHover(.none);
            self.pressed = .none;
            self.cursor = 0;
            return false;
        }
        if (ev.kind == .enter) self.cursor = 0; // the display reset the cursor on enter

        const edge = if (w.csd) self.edgeAt(ev.x, ev.y) else c.XDG_TOPLEVEL_RESIZE_EDGE_NONE;
        const on_bar = self.visible() and ev.y < bar_height;
        const button = if (on_bar and edge == c.XDG_TOPLEVEL_RESIZE_EDGE_NONE) self.buttonAt(ev.x, ev.y) else .none;

        switch (ev.kind) {
            .enter, .motion => {
                self.setHover(button);
                self.setCursor(cursorFor(edge));
                return edge != c.XDG_TOPLEVEL_RESIZE_EDGE_NONE or on_bar;
            },
            .button => {
                if (ev.pressed and ev.button == c.BTN_LEFT and edge != c.XDG_TOPLEVEL_RESIZE_EDGE_NONE) {
                    w.resize(ev.serial, edge);
                    return true;
                }
                if (!on_bar) {
                    if (!ev.pressed and self.pressed != .none) {
                        self.pressed = .none;
                        self.dirty = true;
                    }
                    return false;
                }
                switch (ev.button) {
                    c.BTN_LEFT => if (ev.pressed) {
                        if (button != .none) {
                            self.pressed = button;
                            self.dirty = true;
                        } else if (self.last_click_ms) |t| if (ev.time -% t < double_click_ms) {
                            self.last_click_ms = null;
                            w.toggleMaximized();
                        } else {
                            self.last_click_ms = ev.time;
                            w.move(ev.serial);
                        } else {
                            self.last_click_ms = ev.time;
                            w.move(ev.serial);
                        }
                    } else {
                        if (self.pressed != .none and self.pressed == button) switch (button) {
                            .close => w.close(),
                            .maximize => w.toggleMaximized(),
                            .minimize => w.minimize(),
                            .none => {},
                        };
                        self.pressed = .none;
                        self.dirty = true;
                    },
                    c.BTN_RIGHT => if (ev.pressed) w.showMenu(ev.serial, @intFromFloat(ev.x), @intFromFloat(ev.y)),
                    else => {},
                }
                return true;
            },
            .leave => unreachable,
        }
    }
};
