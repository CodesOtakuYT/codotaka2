//! Client-side decorations as ordinary scene content (no libdecor, no server-side
//! decorations): a title bar node + viewport drawn by `shaders/decoration.frag` (bar and
//! buttons) plus a shaped text title, and resize edges. Drawing goes through program ids
//! the application registers for the decoration shaders and for text.
const std = @import("std");
const wl = @import("wl");
const frame = @import("frame");
const scene = @import("scene");
const text = @import("text");
const Allocator = std.mem.Allocator;

/// Title bar height, logical pixels.
pub const bar_height = 32;
/// Width of the resize border inside the window edges, logical pixels.
const border = 6;
const double_click_ms = 400;

const Button = enum(u32) { none = 0, minimize = 1, maximize = 2, close = 3 };

/// Push data for shaders/decoration.frag (after the renderer's 8-byte data address).
pub const Push = extern struct {
    size: [2]f32,
    scale: f32,
    white_scale: f32,
    hover: u32,
    flags: u32,
};

pub const Programs = struct { decoration: u32, text: u32 };
const title_size = 14;

pub fn Decoration(comptime S: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        /// Set with `attach` before the first layout.
        sw: *S.SceneWindow = undefined,
        programs: Programs,
        fonts: *text.FontSystem,
        /// Title layout cache (rebuilt when the scale changes).
        title_layout: ?text.Layout = null,
        title_scale: f32 = 0,
        title_arena: std.heap.ArenaAllocator,
        node: ?S.NodeId = null,
        viewport: ?S.ViewportId = null,
        title: [64]u8 = undefined,
        title_len: usize = 0,

        hover: Button = .none,
        pressed: Button = .none,
        /// Drawn state differs from the last frame.
        dirty: bool = true,
        drawn_focused: bool = false,
        drawn_maximized: bool = false,
        last_click_ms: ?u32 = null,
        cursor: ?wl.CursorShape = null,

        pub fn create(gpa: Allocator, programs: Programs, fonts: *text.FontSystem, title: []const u8) !*Self {
            const self = try gpa.create(Self);
            self.* = .{ .gpa = gpa, .programs = programs, .fonts = fonts, .title_arena = .init(gpa) };
            self.title_len = @min(title.len, self.title.len);
            @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
            return self;
        }

        pub fn attach(self: *Self, sw: *S.SceneWindow) void {
            self.sw = sw;
        }

        /// The scene's nodes/viewports are owned by the SceneWindow.
        pub fn destroy(self: *Self) void {
            self.title_arena.deinit();
            self.gpa.destroy(self);
        }

        fn visible(self: *const Self) bool {
            const w = self.sw.window;
            return w.csd and !w.fullscreen;
        }

        /// Creates, updates or removes the title bar. Returns the content area below it.
        pub fn layout(self: *Self) !scene.LogicalRect {
            const sw = self.sw;
            const w = sw.window;
            if (!self.visible()) {
                if (self.viewport) |v| sw.removeViewport(v);
                if (self.node) |n| sw.removeNode(n);
                self.viewport = null;
                self.node = null;
                return .{ .width = w.width, .height = w.height };
            }
            if (self.node == null) self.node = try sw.addNode("titlebar", sw.root);
            if (self.viewport == null) self.viewport = try sw.addViewport(.{ .ptr = self, .vtable = &vtable });

            const bar: scene.LogicalRect = .{ .width = w.width, .height = bar_height };
            sw.setNodeRect(self.node.?, bar);
            sw.resetViewport(self.viewport.?, w.width, bar_height);
            try sw.place(self.viewport.?, .{ .node = self.node.?, .region = bar });
            self.dirty = true;
            return .{ .y = bar_height, .width = w.width, .height = w.height -| bar_height };
        }

        const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };

        fn update(ptr: *anyopaque, _: scene.FrameTime) scene.Update {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const w = self.sw.window;
            if (w.activated != self.drawn_focused or w.maximized != self.drawn_maximized) self.dirty = true;
            const dirty = self.dirty;
            self.dirty = false;
            return .{ .dirty = dirty };
        }

        fn draw(ptr: *anyopaque, ctx: scene.DrawContext, out: *frame.DrawList) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const w = self.sw.window;
            self.drawn_focused = w.activated;
            self.drawn_maximized = w.maximized;
            try out.add(.init(self.programs.decoration, Push{
                .size = ctx.size_px,
                .scale = ctx.scale,
                .white_scale = ctx.white_scale,
                .hover = @intFromEnum(self.hover),
                .flags = @as(u32, @intFromBool(w.activated)) |
                    (@as(u32, @intFromBool(w.maximized)) << 1) |
                    (@as(u32, @intFromBool(self.pressed != .none and self.pressed == self.hover)) << 2),
            }));

            // Title: shaped once per scale, clipped before the buttons.
            if (self.title_layout == null or self.title_scale != ctx.scale) {
                _ = self.title_arena.reset(.retain_capacity);
                const gray: f32 = 0.79; // ~sRGB 0.9
                self.title_layout = try text.layout(self.fonts, self.title_arena.allocator(), self.title[0..self.title_len], .{
                    .size_px = title_size * ctx.scale,
                    .max_width = null,
                    .color = .{ gray, gray, gray, 1 },
                });
                self.title_scale = ctx.scale;
            }
            const l = self.title_layout.?;
            if (l.lines.len == 0) return;
            const origin_x = @round(10 * ctx.scale);
            const origin_y = @round((ctx.size_px[1] - l.lines[0].baseline * 2 + title_size * ctx.scale * 0.25) / 2);
            const limit = ctx.size_px[0] - 3 * bar_height * ctx.scale - origin_x;
            const dim: f32 = if (w.activated) 1 else 0.6;
            var quads: std.ArrayList(text.Quad) = .empty;
            for (l.quads) |q| {
                if (q.x > limit) continue;
                var moved = q;
                moved.x += origin_x;
                moved.y += origin_y;
                for (&moved.color) |*ch| ch.* *= dim;
                try quads.append(out.arena, moved);
            }
            try out.add(text.draw(self.programs.text, quads.items, ctx.size_px, ctx.white_scale));
        }

        fn buttonAt(self: *const Self, x: f64, y: f64) Button {
            if (y < 0 or y >= bar_height) return .none;
            const w: f64 = @floatFromInt(self.sw.window.width);
            const h: f64 = bar_height;
            if (x >= w - h) return .close;
            if (x >= w - 2 * h) return .maximize;
            if (x >= w - 3 * h) return .minimize;
            return .none;
        }

        fn edgeAt(self: *const Self, x: f64, y: f64) wl.ResizeEdge {
            const w = self.sw.window;
            if (!w.csd or w.maximized or w.fullscreen or w.tiled) return .none;
            const fw: f64 = @floatFromInt(w.width);
            const fh: f64 = @floatFromInt(w.height);
            var bits: u32 = 0;
            if (y < border) bits |= @intFromEnum(wl.ResizeEdge.top);
            if (y >= fh - border) bits |= @intFromEnum(wl.ResizeEdge.bottom);
            if (x < border) bits |= @intFromEnum(wl.ResizeEdge.left);
            if (x >= fw - border) bits |= @intFromEnum(wl.ResizeEdge.right);
            return @enumFromInt(bits);
        }

        fn cursorFor(edge: wl.ResizeEdge) wl.CursorShape {
            return switch (edge) {
                .none => .default,
                .top => .n_resize,
                .bottom => .s_resize,
                .left => .w_resize,
                .right => .e_resize,
                .top_left => .nw_resize,
                .top_right => .ne_resize,
                .bottom_left => .sw_resize,
                .bottom_right => .se_resize,
            };
        }

        fn setHover(self: *Self, b: Button) void {
            if (b == self.hover) return;
            self.hover = b;
            self.dirty = true;
        }

        fn setCursor(self: *Self, shape: wl.CursorShape) void {
            if (self.cursor == shape) return;
            self.cursor = shape;
            self.sw.window.setCursor(shape);
        }

        /// Handles a pointer event. Returns true if consumed by the decorations.
        pub fn pointer(self: *Self, ev: wl.PointerEvent) bool {
            const w = self.sw.window;
            switch (ev.kind) {
                .leave => {
                    self.setHover(.none);
                    self.pressed = .none;
                    self.cursor = null;
                    return false;
                },
                .enter => self.cursor = null, // the display reset the cursor on enter
                else => {},
            }

            const edge = self.edgeAt(ev.x, ev.y);
            const on_bar = self.visible() and ev.y < bar_height;
            const button = if (on_bar and edge == .none) self.buttonAt(ev.x, ev.y) else .none;

            switch (ev.kind) {
                .enter, .motion => {
                    self.setHover(button);
                    self.setCursor(cursorFor(edge));
                    return edge != .none or on_bar;
                },
                .button => {
                    if (ev.pressed and ev.button == wl.Button.left and edge != .none) {
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
                    if (ev.button == wl.Button.left) {
                        if (ev.pressed) {
                            if (button != .none) {
                                self.pressed = button;
                                self.dirty = true;
                            } else if (self.last_click_ms != null and ev.time -% self.last_click_ms.? < double_click_ms) {
                                self.last_click_ms = null;
                                w.toggleMaximized();
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
                        }
                    } else if (ev.button == wl.Button.right and ev.pressed) {
                        w.showMenu(ev.serial, @intFromFloat(ev.x), @intFromFloat(ev.y));
                    }
                    return true;
                },
                .leave => unreachable,
            }
        }
    };
}
