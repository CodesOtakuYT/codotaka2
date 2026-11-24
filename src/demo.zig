//! Demo content and layout. Each content provider only reports itself dirty when its
//! pixels actually change.
const std = @import("std");
const wl = @import("wl");
const scene = @import("scene");
const frame = @import("frame");
const csd = @import("csd");
const text = @import("text");
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

/// sRGB-encoded component -> linear (text colors are linear, premultiplied).
fn linear(v: f32) f32 {
    return std.math.pow(f32, v, 2.2);
}

/// A cached text layout, rebuilt when its inputs change.
const TextBlock = struct {
    arena: std.heap.ArenaAllocator,
    layout: ?text.Layout = null,
    key: struct { version: u64 = 0, scale: f32 = 0, width: f32 = 0 } = .{},

    fn init(gpa: Allocator) TextBlock {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(b: *TextBlock) void {
        b.arena.deinit();
    }

    fn get(b: *TextBlock, fonts: *text.FontSystem, str: []const u8, version: u64, scale: f32, width: f32, opts: text.Options) !text.Layout {
        if (b.layout == null or b.key.version != version or b.key.scale != scale or b.key.width != width) {
            _ = b.arena.reset(.retain_capacity);
            b.layout = try text.layout(fonts, b.arena.allocator(), str, opts);
            b.key = .{ .version = version, .scale = scale, .width = width };
        }
        return b.layout.?;
    }
};

/// Appends a text draw of `l` offset by (x, y) buffer pixels.
fn drawText(out: *frame.DrawList, l: text.Layout, x: f32, y: f32, ctx: scene.DrawContext) !void {
    const quads = try out.arena.alloc(text.Quad, l.quads.len);
    for (l.quads, quads) |q, *o| {
        o.* = q;
        o.x += x;
        o.y += y;
    }
    try out.add(text.draw(@intFromEnum(Program.text), quads, ctx.size_px, ctx.white_scale));
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

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext, out: *frame.DrawList) !void {
        const self: *Spinner = @ptrCast(@alignCast(ptr));
        const intensity = if (ctx.color == .hdr_scrgb) self.intensity else 1.0;
        try out.add(triangle(.{ .angle = self.angle, .intensity = intensity, .white_scale = ctx.white_scale }));
    }
};

const label_text =
    \\Shaped with HarfBuzz, bidi by SheenBidi, breaks by libunibreak, glyphs by FreeType.
    \\English, Ελληνικά, Русский
    \\العربية: مرحبا بالعالم 123
    \\עברית: שלום עולם!
    \\Mixed: abc אבג 123 مرحبا (nested) xyz
    \\हिन्दी, ไทย, 日本語, 한국어
;

/// Static multilingual paragraph, wrapped to the viewport width.
const Label = struct {
    fonts: *text.FontSystem,
    block: TextBlock,

    fn content(self: *Label) scene.Content {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };

    fn update(_: *anyopaque, _: scene.FrameTime) scene.Update {
        return .{};
    }

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext, out: *frame.DrawList) !void {
        const self: *Label = @ptrCast(@alignCast(ptr));
        const margin = @round(12 * ctx.scale);
        const width = ctx.size_px[0] - 2 * margin;
        const l = try self.block.get(self.fonts, label_text, 1, ctx.scale, width, .{
            .size_px = 15 * ctx.scale,
            .max_width = width,
            .color = .{ linear(0.85), linear(0.88), linear(0.95), 1 },
        });
        try drawText(out, l, margin, margin, ctx);
    }
};

/// Editable text (keyboard via xkbcommon) over a background that ticks once a second.
/// Spans two subsurfaces: the layout is shared, each part draws its half.
const Editor = struct {
    gpa: Allocator,
    fonts: *text.FontSystem,
    buffer: std.ArrayList(u8) = .empty,
    version: u64 = 1,
    block: TextBlock,
    focused: bool = false,
    caret_on: bool = true,
    step: i128 = -1,
    dirty: bool = true,

    fn deinit(self: *Editor) void {
        self.buffer.deinit(self.gpa);
        self.block.deinit();
    }

    fn content(self: *Editor) scene.Content {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };

    fn changed(self: *Editor) void {
        self.version += 1;
        self.caret_on = true;
        self.dirty = true;
    }

    fn key(self: *Editor, ev: wl.KeyEvent) !void {
        if (ev.kind == .release) return;
        switch (ev.keysym) {
            wl.keysym.BackSpace => {
                var scratch: std.heap.ArenaAllocator = .init(self.gpa);
                defer scratch.deinit();
                const to = try text.prevGrapheme(scratch.allocator(), self.buffer.items, self.buffer.items.len);
                self.buffer.shrinkRetainingCapacity(to);
            },
            wl.keysym.Return, wl.keysym.KP_Enter => try self.buffer.append(self.gpa, '\n'),
            else => {
                if (ev.mods.ctrl or ev.mods.alt or ev.text().len == 0) return;
                for (ev.text()) |b| if (b < 0x20 or b == 0x7f) return;
                try self.buffer.appendSlice(self.gpa, ev.text());
            },
        }
        self.changed();
    }

    fn update(ptr: *anyopaque, ft: scene.FrameTime) scene.Update {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        // Background tick and caret blink both run on the half-second grid.
        const step = @divFloor(ft.now_ns, std.time.ns_per_s / 2);
        if (step != self.step) {
            self.step = step;
            self.caret_on = @mod(step, 2) == 0;
            self.dirty = true;
        }
        const dirty = self.dirty;
        self.dirty = false;
        return .{ .dirty = dirty, .next_wake_ns = (step + 1) * (std.time.ns_per_s / 2) };
    }

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext, out: *frame.DrawList) !void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        const angle: f32 = @floatFromInt(@mod(@divFloor(self.step, 2), 12));
        try out.add(triangle(.{ .angle = angle * std.math.pi / 6.0, .intensity = 0.25, .white_scale = ctx.white_scale }));

        const margin = @round(12 * ctx.scale);
        const width = ctx.size_px[0] - 2 * margin;
        const hint = "Type here (any language, bidi, compose/dead keys). Backspace removes a grapheme.";
        const empty = self.buffer.items.len == 0;
        // The caret is a glyph appended to the text, so bidi places it naturally.
        const caret = if (self.focused and self.caret_on) "▏" else "";
        const shown = if (empty) try std.mem.concat(out.arena, u8, &.{ caret, hint }) else try std.mem.concat(out.arena, u8, &.{ self.buffer.items, caret });
        const v = self.version * 2 + @intFromBool(self.focused and self.caret_on) + if (empty) @as(u64, 1) << 40 else 0;
        const tone: f32 = if (empty) 0.35 else 0.95;
        const l = try self.block.get(self.fonts, shown, v, ctx.scale, width, .{
            .size_px = 18 * ctx.scale,
            .max_width = width,
            .color = .{ linear(tone), linear(tone), linear(tone), 1 },
        });
        try drawText(out, l, margin, margin, ctx);
    }
};

/// A demo window: CSD title bar plus
///   top:    [ spinner (promotable) | multilingual label ]
///   bottom: one editable text viewport spanning two subsurfaces side by side
pub const Window = struct {
    gpa: Allocator,
    sw: *Scene.SceneWindow,
    decoration: *Decoration,
    spinner: Spinner,
    label: Label,
    editor: Editor,

    spinner_view: ?Scene.ViewportId = null,
    label_view: ?Scene.ViewportId = null,
    editor_view: ?Scene.ViewportId = null,
    promoted: ?Scene.NodeId = null,
    bottom_left: ?Scene.NodeId = null,
    bottom_right: ?Scene.NodeId = null,
    want_promoted: bool = true,

    /// `sw_create.call(hooks)` builds the SceneWindow; it is the last fallible step, so on
    /// error the caller still owns whatever it passed to `sw_create`.
    pub fn create(gpa: Allocator, fonts: *text.FontSystem, index: usize, title: []const u8, sw_create: anytype) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const decoration = try Decoration.create(gpa, .{
            .decoration = @intFromEnum(Program.decoration),
            .text = @intFromEnum(Program.text),
        }, fonts, title);
        errdefer decoration.destroy();
        self.* = .{
            .gpa = gpa,
            .sw = undefined,
            .decoration = decoration,
            .spinner = .{ .speed = if (index % 2 == 0) 1.0 else -0.7, .phase = @floatFromInt(index) },
            .label = .{ .fonts = fonts, .block = .init(gpa) },
            .editor = .{ .gpa = gpa, .fonts = fonts, .block = .init(gpa) },
        };
        errdefer {
            self.label.block.deinit();
            self.editor.deinit();
        }
        self.sw = try sw_create.call(.{ .ctx = self, .layout = layout, .pointer = pointer, .key = key });
        decoration.attach(self.sw);
        return self;
    }

    pub fn destroy(self: *Window) void {
        self.decoration.destroy();
        self.sw.destroy();
        self.label.block.deinit();
        self.editor.deinit();
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
        if (self.label_view == null) self.label_view = try sw.addViewport(self.label.content());
        if (self.editor_view == null) self.editor_view = try sw.addViewport(self.editor.content());
        if (self.bottom_left == null) self.bottom_left = try sw.addNode("bottom-left", sw.root);
        if (self.bottom_right == null) self.bottom_right = try sw.addNode("bottom-right", sw.root);
        if (self.want_promoted and self.promoted == null) self.promoted = try sw.addNode("promoted", sw.root);
        if (!self.want_promoted) if (self.promoted) |n| {
            sw.removeNode(n);
            self.promoted = null;
        };

        const w = area.width;
        const top_h = area.height / 2;
        const bottom_h = area.height - top_h;
        const left_w = w / 3;
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

        // Top-right: multilingual label on the root.
        sw.resetViewport(self.label_view.?, right_w, top_h);
        try sw.place(self.label_view.?, .{ .node = sw.root, .region = .{ .x = @intCast(left_w), .y = y0, .width = right_w, .height = top_h } });

        // Bottom: the editor spanning two subsurfaces (split in the middle).
        const half = w / 2;
        const bl = self.bottom_left.?;
        const br = self.bottom_right.?;
        sw.setNodeRect(bl, .{ .y = y1, .width = half, .height = bottom_h });
        sw.setNodeRect(br, .{ .x = @intCast(half), .y = y1, .width = w - half, .height = bottom_h });
        const ev = self.editor_view.?;
        sw.resetViewport(ev, w, bottom_h);
        try sw.place(ev, .{ .node = bl, .region = .{ .width = half, .height = bottom_h } });
        try sw.place(ev, .{ .node = br, .region = .{ .width = w - half, .height = bottom_h }, .offset_x = @intCast(half) });
    }

    fn pointer(ctx: *anyopaque, _: *Scene.SceneWindow, ev: wl.PointerEvent) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (self.decoration.pointer(ev)) return;
        if (ev.kind == .button and ev.pressed and ev.button == wl.Button.middle) self.togglePromotion();
    }

    fn key(ctx: *anyopaque, sw: *Scene.SceneWindow, ev: wl.KeyEvent) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (ev.kind == .press and ev.mods.ctrl and ev.keysym == wl.keysym.q) {
            sw.window.close();
            return;
        }
        self.editor.key(ev) catch |err| log.err("editor: {t}", .{err});
        if (self.editor_view) |v| sw.markDirty(v);
    }

    /// Keyboard focus changes (the caret only shows in the focused window).
    pub fn syncFocus(self: *Window) void {
        const focused = self.sw.window.display.keyboard_focus == self.sw.window;
        if (focused != self.editor.focused) {
            log.debug("keyboard focus {s}", .{if (focused) "gained" else "lost"});
            self.editor.focused = focused;
            self.editor.dirty = true;
        }
    }
};
