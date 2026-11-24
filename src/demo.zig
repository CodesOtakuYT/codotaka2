//! Demo content and layout. Each content provider only reports itself dirty when its
//! pixels actually change.
const std = @import("std");
const wl = @import("wl");
const scene = @import("scene");
const frame = @import("frame");
const csd = @import("csd");
const vk_present = @import("vk_present");
const Program = @import("Renderer.zig").Program;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.demo);

pub const Scene = scene.Scene(vk_present.SurfaceTarget);
const Decoration = csd.Decoration(Scene);

const TrianglePush = extern struct { angle: f32, intensity: f32, white_scale: f32 };

fn triangle(push: TrianglePush) frame.Draw {
    return .init(@intFromEnum(Program.triangle), push);
}

/// Continuously rotating; in HDR it also pulses above reference white.
const Spinner = struct {
    speed: f32,
    phase: f32,
    angle: f32 = 0,
    intensity: f32 = 1,

    fn content(self: *Spinner) scene.Content {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };

    fn update(ptr: *anyopaque, ft: scene.FrameTime) scene.Update {
        const self: *Spinner = @ptrCast(@alignCast(ptr));
        // Animate for the predicted presentation time, not "now".
        const t: f32 = @floatCast(@as(f64, @floatFromInt(ft.target_ns)) / std.time.ns_per_s);
        self.angle = self.phase + t * self.speed;
        self.intensity = 1.0 + 1.5 * (0.5 + 0.5 * @sin(t * 2.0));
        return .{ .dirty = true };
    }

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext) frame.Draw {
        const self: *Spinner = @ptrCast(@alignCast(ptr));
        const intensity = if (ctx.color == .hdr_scrgb) self.intensity else 1.0;
        return triangle(.{ .angle = self.angle, .intensity = intensity, .white_scale = ctx.white_scale });
    }
};

/// Steps once per second: dirty one frame per second, otherwise idle with a timer.
const Ticker = struct {
    step: i128 = -1,

    fn content(self: *Ticker) scene.Content {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };

    fn update(ptr: *anyopaque, ft: scene.FrameTime) scene.Update {
        const self: *Ticker = @ptrCast(@alignCast(ptr));
        const step = @divFloor(ft.now_ns, std.time.ns_per_s);
        const dirty = step != self.step;
        self.step = step;
        return .{ .dirty = dirty, .next_wake_ns = (step + 1) * std.time.ns_per_s };
    }

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext) frame.Draw {
        const self: *Ticker = @ptrCast(@alignCast(ptr));
        const angle: f32 = @floatFromInt(@mod(self.step, 12));
        return triangle(.{ .angle = angle * std.math.pi / 6.0, .intensity = 1, .white_scale = ctx.white_scale });
    }
};

/// Never changes: only redrawn when its node is (resize, scale, reallocation).
const Static = struct {
    fn content(self: *Static) scene.Content {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };
    fn update(_: *anyopaque, _: scene.FrameTime) scene.Update {
        return .{};
    }
    fn draw(_: *anyopaque, ctx: scene.DrawContext) frame.Draw {
        return triangle(.{ .angle = 0, .intensity = 1, .white_scale = ctx.white_scale });
    }
};

/// A demo window: CSD title bar plus
///   top:    [ spinner (promotable) | static ]   spinner on its own subsurface or the root
///   bottom: one ticker viewport spanning two subsurfaces side by side
pub const Window = struct {
    gpa: Allocator,
    sw: *Scene.SceneWindow,
    decoration: *Decoration,
    spinner: Spinner,
    ticker: Ticker = .{},
    static: Static = .{},

    spinner_view: ?Scene.ViewportId = null,
    static_view: ?Scene.ViewportId = null,
    ticker_view: ?Scene.ViewportId = null,
    promoted: ?Scene.NodeId = null,
    bottom_left: ?Scene.NodeId = null,
    bottom_right: ?Scene.NodeId = null,
    want_promoted: bool = true,

    /// `sw_create.call(hooks)` builds the SceneWindow; it is the last fallible step, so on
    /// error the caller still owns whatever it passed to `sw_create`.
    pub fn create(gpa: Allocator, index: usize, title: []const u8, sw_create: anytype) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const decoration = try Decoration.create(gpa, @intFromEnum(Program.decoration), title);
        errdefer decoration.destroy();
        self.* = .{
            .gpa = gpa,
            .sw = undefined,
            .decoration = decoration,
            .spinner = .{ .speed = if (index % 2 == 0) 1.0 else -0.7, .phase = @floatFromInt(index) },
        };
        self.sw = try sw_create.call(.{ .ctx = self, .layout = layout, .pointer = pointer });
        decoration.attach(self.sw);
        return self;
    }

    pub fn destroy(self: *Window) void {
        self.decoration.destroy();
        self.sw.destroy();
        self.gpa.destroy(self);
    }

    pub fn togglePromotion(self: *Window) void {
        self.want_promoted = !self.want_promoted;
        self.sw.window.layout_dirty = true;
        log.info("spinner viewport {s}", .{if (self.want_promoted) "promoted to its own subsurface" else "merged into the root surface"});
    }

    fn layout(ctx: *anyopaque, sw: *Scene.SceneWindow) !void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        const area = try self.decoration.layout();

        if (self.spinner_view == null) self.spinner_view = try sw.addViewport(self.spinner.content());
        if (self.static_view == null) self.static_view = try sw.addViewport(self.static.content());
        if (self.ticker_view == null) self.ticker_view = try sw.addViewport(self.ticker.content());
        if (self.bottom_left == null) self.bottom_left = try sw.addNode("bottom-left", sw.root);
        if (self.bottom_right == null) self.bottom_right = try sw.addNode("bottom-right", sw.root);
        if (self.want_promoted and self.promoted == null) self.promoted = try sw.addNode("promoted", sw.root);
        if (!self.want_promoted) if (self.promoted) |n| {
            sw.removeNode(n);
            self.promoted = null;
        };

        const w = area.width;
        const top_h = area.height * 3 / 5;
        const bottom_h = area.height - top_h;
        const left_w = w / 2;
        const right_w = w - left_w;
        const y0 = area.y;
        const y1 = y0 + @as(i32, @intCast(top_h));

        // Top-left: spinner, on its own subsurface (overlay-plane candidate) or on the root.
        const sv = self.spinner_view.?;
        sw.resetViewport(sv, left_w, top_h);
        if (self.promoted) |n| {
            sw.setNodeRect(n, .{ .y = y0, .width = left_w, .height = top_h });
            try sw.place(sv, .{ .node = n, .region = .{ .width = left_w, .height = top_h } });
        } else {
            try sw.place(sv, .{ .node = sw.root, .region = .{ .y = y0, .width = left_w, .height = top_h } });
        }

        // Top-right: static content on the root.
        sw.resetViewport(self.static_view.?, right_w, top_h);
        try sw.place(self.static_view.?, .{ .node = sw.root, .region = .{ .x = @intCast(left_w), .y = y0, .width = right_w, .height = top_h } });

        // Bottom: one viewport spanning two subsurfaces.
        const bl = self.bottom_left.?;
        const br = self.bottom_right.?;
        sw.setNodeRect(bl, .{ .y = y1, .width = left_w, .height = bottom_h });
        sw.setNodeRect(br, .{ .x = @intCast(left_w), .y = y1, .width = right_w, .height = bottom_h });
        const tv = self.ticker_view.?;
        sw.resetViewport(tv, w, bottom_h);
        try sw.place(tv, .{ .node = bl, .region = .{ .width = left_w, .height = bottom_h } });
        try sw.place(tv, .{ .node = br, .region = .{ .width = right_w, .height = bottom_h }, .offset_x = @intCast(left_w) });
    }

    fn pointer(ctx: *anyopaque, _: *Scene.SceneWindow, ev: wl.PointerEvent) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (self.decoration.pointer(ev)) return;
        if (ev.kind == .button and ev.pressed and ev.button == wl.Button.middle) self.togglePromotion();
    }
};
