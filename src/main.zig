const std = @import("std");
const c = @import("c");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wayland = @import("wayland.zig");
const scene = @import("scene.zig");
const Instance = @import("gfx/Instance.zig");
const Device = @import("gfx/Device.zig");
const Renderer = @import("gfx/Renderer.zig");

// Let vulkan-zig use the real libwayland types for its platform structs.
pub const wl_display = c.wl_display;
pub const wl_surface = c.wl_surface;

pub const std_options: std.Options = .{ .log_level = .info };

const usage =
    \\Usage: codotaka [--hdr] [window-count]
    \\  --hdr   render FP16 scRGB and tag surfaces with the Windows-scRGB image description
    \\Middle-click the top-left view to promote/demote it to its own subsurface.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var window_count: usize = 2;
    var color: wayland.ColorMode = .sdr;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--hdr")) {
            color = .hdr_scrgb;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(usage, .{});
            return;
        } else {
            window_count = std.fmt.parseInt(usize, arg, 10) catch {
                std.debug.print(usage, .{});
                return error.InvalidArgument;
            };
        }
    }

    var app = try App.init(gpa, io, window_count, color);
    defer app.deinit();
    try app.run();
}

// ---------------------------------------------------------------------------------------
// Demo content providers. Each only reports itself dirty when its pixels actually change.

const TrianglePush = extern struct { angle: f32, intensity: f32, white_scale: f32 };

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

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext) Renderer.Draw {
        const self: *Spinner = @ptrCast(@alignCast(ptr));
        const intensity = if (ctx.color == .hdr_scrgb) self.intensity else 1.0;
        return .init(.triangle, TrianglePush{ .angle = self.angle, .intensity = intensity, .white_scale = ctx.white_scale });
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

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext) Renderer.Draw {
        const self: *Ticker = @ptrCast(@alignCast(ptr));
        const angle: f32 = @floatFromInt(@mod(self.step, 12));
        return .init(.triangle, TrianglePush{ .angle = angle * std.math.pi / 6.0, .intensity = 1, .white_scale = ctx.white_scale });
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
    fn draw(_: *anyopaque, ctx: scene.DrawContext) Renderer.Draw {
        return .init(.triangle, TrianglePush{ .angle = 0, .intensity = 1, .white_scale = ctx.white_scale });
    }
};

// ---------------------------------------------------------------------------------------

/// Demo layout. Content area (below the title bar):
///   top:    [ spinner (promotable) | static ]   on the root, or spinner on its own subsurface
///   bottom: one ticker viewport spanning two subsurfaces side by side
const Demo = struct {
    sw: *scene.SceneWindow = undefined,
    spinner: Spinner,
    ticker: Ticker = .{},
    static: Static = .{},

    spinner_view: ?*scene.Viewport = null,
    static_view: ?*scene.Viewport = null,
    ticker_view: ?*scene.Viewport = null,
    promoted: ?*scene.Node = null,
    bottom_left: ?*scene.Node = null,
    bottom_right: ?*scene.Node = null,
    want_promoted: bool = true,

    fn hooks(self: *Demo) scene.Layout {
        return .{ .ctx = self, .layout = layout, .pointer = pointer };
    }

    fn layout(ctx: *anyopaque, sw: *scene.SceneWindow, area: scene.Rect) !void {
        const self: *Demo = @ptrCast(@alignCast(ctx));
        if (self.spinner_view == null) self.spinner_view = try sw.addViewport(self.spinner.content());
        if (self.static_view == null) self.static_view = try sw.addViewport(self.static.content());
        if (self.ticker_view == null) self.ticker_view = try sw.addViewport(self.ticker.content());
        if (self.bottom_left == null) self.bottom_left = try sw.addNode("bottom-left", sw.root);
        if (self.bottom_right == null) self.bottom_right = try sw.addNode("bottom-right", sw.root);
        if (self.want_promoted and self.promoted == null) self.promoted = try sw.addNode("promoted", sw.root);
        if (!self.want_promoted and self.promoted != null) {
            sw.removeNode(self.promoted.?);
            self.promoted = null;
        }

        const w = area.width;
        const top_h = area.height * 3 / 5;
        const bottom_h = area.height - top_h;
        const left_w = w / 2;
        const right_w = w - left_w;
        const y0 = area.y;
        const y1 = y0 + @as(i32, @intCast(top_h));

        // Top-left: spinner, on its own subsurface (overlay-plane candidate) or on the root.
        const sv = self.spinner_view.?;
        sv.width = left_w;
        sv.height = top_h;
        sv.clearParts();
        if (self.promoted) |n| {
            n.setRect(.{ .x = 0, .y = y0, .width = left_w, .height = top_h });
            try sw.place(sv, .{ .node = n, .region = .{ .x = 0, .y = 0, .width = left_w, .height = top_h } });
        } else {
            try sw.place(sv, .{ .node = sw.root, .region = .{ .x = 0, .y = y0, .width = left_w, .height = top_h } });
        }

        // Top-right: static content on the root.
        const st = self.static_view.?;
        st.width = right_w;
        st.height = top_h;
        st.clearParts();
        try sw.place(st, .{ .node = sw.root, .region = .{ .x = @intCast(left_w), .y = y0, .width = right_w, .height = top_h } });

        // Bottom: one viewport spanning two subsurfaces.
        const bl = self.bottom_left.?;
        const br = self.bottom_right.?;
        bl.setRect(.{ .x = 0, .y = y1, .width = left_w, .height = bottom_h });
        br.setRect(.{ .x = @intCast(left_w), .y = y1, .width = right_w, .height = bottom_h });
        const tv = self.ticker_view.?;
        tv.width = w;
        tv.height = bottom_h;
        tv.clearParts();
        try sw.place(tv, .{ .node = bl, .region = .{ .x = 0, .y = 0, .width = left_w, .height = bottom_h } });
        try sw.place(tv, .{ .node = br, .region = .{ .x = 0, .y = 0, .width = right_w, .height = bottom_h }, .offset_x = @intCast(left_w) });
    }

    fn pointer(ctx: *anyopaque, sw: *scene.SceneWindow, ev: wayland.PointerEvent) void {
        const self: *Demo = @ptrCast(@alignCast(ctx));
        if (ev.kind == .button and ev.pressed and ev.button == c.BTN_MIDDLE) {
            self.want_promoted = !self.want_promoted;
            sw.window.layout_dirty = true;
            std.log.info("spinner viewport {s}", .{if (self.want_promoted) "promoted to its own subsurface" else "merged into the root surface"});
        }
    }
};

const Entry = struct {
    sw: *scene.SceneWindow,
    demo: *Demo,
    last_stats: std.StringHashMapUnmanaged(wayland.PresentStats) = .empty,
};

const App = struct {
    gpa: Allocator,
    io: Io,
    display: *wayland.Display,
    instance: *Instance,
    devices: []*Device,
    entries: std.ArrayList(Entry) = .empty,

    fn init(gpa: Allocator, io: Io, window_count: usize, color: wayland.ColorMode) !App {
        const display = try wayland.Display.connect(gpa);
        errdefer display.disconnect();
        const instance = try Instance.create(gpa);
        errdefer instance.destroy();

        const candidates = try instance.findCandidates(gpa);
        defer gpa.free(candidates);

        var devices: std.ArrayList(*Device) = .empty;
        errdefer {
            for (devices.items) |d| d.destroy();
            devices.deinit(gpa);
        }
        for (candidates) |cand| {
            const dev = try Device.create(gpa, instance, cand);
            devices.append(gpa, dev) catch |err| {
                dev.destroy();
                return err;
            };
            std.log.info("device {d}: {s}", .{ devices.items.len - 1, dev.name() });
        }

        var app: App = .{
            .gpa = gpa,
            .io = io,
            .display = display,
            .instance = instance,
            .devices = try devices.toOwnedSlice(gpa),
        };
        errdefer app.deinit();

        try app.entries.ensureTotalCapacity(gpa, window_count);
        for (0..window_count) |i| {
            const demo = try gpa.create(Demo);
            errdefer gpa.destroy(demo);
            demo.* = .{ .spinner = .{ .speed = if (i % 2 == 0) 1.0 else -0.7, .phase = @floatFromInt(i) } };

            var title_buf: [64]u8 = undefined;
            const title = try std.fmt.bufPrintSentinel(&title_buf, "codotaka #{d}{s}", .{ i, if (color == .hdr_scrgb) " (HDR scRGB)" else "" }, 0);
            const sw = try scene.SceneWindow.create(gpa, display, app.devices, i, title, color, demo.hooks());
            demo.sw = sw;
            std.log.info("window #{d} -> {s}, csd={}", .{ i, sw.device.name(), sw.window.csd });
            app.entries.appendAssumeCapacity(.{ .sw = sw, .demo = demo });
        }
        return app;
    }

    fn deinit(app: *App) void {
        for (app.entries.items) |*e| app.closeEntry(e);
        app.entries.deinit(app.gpa);
        for (app.devices) |d| d.destroy();
        app.gpa.free(app.devices);
        app.instance.destroy();
        app.display.disconnect();
        app.* = undefined;
    }

    fn closeEntry(app: *App, e: *Entry) void {
        e.sw.destroy();
        app.gpa.destroy(e.demo);
        e.last_stats.deinit(app.gpa);
    }

    fn nowNs(app: *App) i128 {
        return Io.Timestamp.now(app.io, .awake).nanoseconds;
    }

    fn run(app: *App) !void {
        const gpa = app.gpa;
        const io = app.io;
        const results = try gpa.alloc(anyerror!void, app.devices.len);
        defer gpa.free(results);
        const stats = try gpa.alloc(Device.FrameStats, app.devices.len);
        defer gpa.free(stats);
        const trees = try gpa.alloc(std.ArrayList(Device.TreeWork), app.devices.len);
        defer gpa.free(trees);

        // Per-frame scratch (view lists, damage, ...), reset every iteration.
        var frame_arena: std.heap.ArenaAllocator = .init(gpa);
        defer frame_arena.deinit();
        var wait_fds: std.ArrayList(c_int) = .empty;
        defer wait_fds.deinit(gpa);
        var next_report = app.nowNs() + 5 * std.time.ns_per_s;

        while (app.entries.items.len > 0) {
            try app.display.wait(&.{}, 0);

            var i: usize = 0;
            while (i < app.entries.items.len) {
                if (app.entries.items[i].sw.window.should_close) {
                    app.closeEntry(&app.entries.items[i]);
                    _ = app.entries.swapRemove(i);
                } else i += 1;
            }
            if (app.entries.items.len == 0) break;

            _ = frame_arena.reset(.retain_capacity);
            const arena = frame_arena.allocator();
            const now = app.nowNs();

            for (trees) |*t| t.* = .empty;
            var next_wake: ?i128 = null;
            for (app.entries.items) |e| {
                const ft = e.sw.frameTime(now);
                if (try e.sw.plan(arena, ft)) |tree| {
                    const di = std.mem.indexOfScalar(*Device, app.devices, e.sw.device).?;
                    try trees[di].append(arena, tree);
                }
                if (e.sw.next_wake_ns) |t| next_wake = if (next_wake) |cur| @min(cur, t) else t;
            }

            // One task per device: a device's queue must not be used from two tasks at once,
            // but different devices render in parallel. Each task issues one batched submit.
            var group: Io.Group = .init;
            defer group.cancel(io);
            for (app.devices, results, stats, trees) |dev, *result, *st, t| {
                result.* = {};
                st.* = .{};
                group.async(io, renderDevice, .{ dev, t.items, st, result });
            }
            try group.await(io);
            for (results) |r| try r;
            for (app.entries.items) |e| e.sw.afterFrame();
            app.display.flush();

            if (now >= next_report) {
                next_report = now + 5 * std.time.ns_per_s;
                try app.report();
            }

            var committed: usize = 0;
            var gpu_blocked = false;
            for (stats) |st| {
                committed += st.committed;
                gpu_blocked = gpu_blocked or st.gpu_blocked;
            }
            if (committed > 0) continue;

            // Nothing presentable right now: sleep until the compositor asks for a frame,
            // a buffer is released (syncobj eventfd), input arrives, or a content timer fires.
            var timeout_ms: c_int = -1;
            if (next_wake) |t| timeout_ms = @intCast(std.math.clamp(@divFloor(t - app.nowNs() + std.time.ns_per_ms - 1, std.time.ns_per_ms), 0, 60_000));
            if (gpu_blocked) timeout_ms = if (timeout_ms < 0) 1 else @min(timeout_ms, 1);
            timeout_ms = @min(if (timeout_ms < 0) 60_000 else timeout_ms, @as(c_int, @intCast(@max(0, @divFloor(next_report - app.nowNs(), std.time.ns_per_ms)))));

            wait_fds.clearRetainingCapacity();
            for (app.entries.items) |e| {
                for (e.sw.nodes.items) |n| try wait_fds.append(gpa, n.target.release_eventfd);
            }
            try app.display.wait(wait_fds.items, timeout_ms);
            for (app.entries.items) |e| {
                for (e.sw.nodes.items) |n| n.target.drainEventfd();
            }
        }
    }

    /// Per-surface presentation statistics since the last report, from wp_presentation.
    fn report(app: *App) !void {
        for (app.entries.items, 0..) |*e, wi| {
            const refresh = e.sw.window.root.stats.refresh_ns;
            std.log.info("window #{d} scale {d:.2} refresh {d:.1} Hz", .{
                wi,
                @as(f32, @floatFromInt(e.sw.window.scale_120)) / 120.0,
                if (refresh > 0) 1e9 / @as(f64, @floatFromInt(refresh)) else 0,
            });
            for (e.sw.nodes.items) |n| {
                const cur = n.surface.stats;
                const prev = e.last_stats.get(n.name) orelse wayland.PresentStats{};
                try e.last_stats.put(app.gpa, n.name, cur);
                std.log.info("  {s:<13} presented {d:>4}  zero-copy {d:>4}  discarded {d:>3}  modifier 0x{x:0>16}{s}", .{
                    n.name,
                    cur.presented -| prev.presented,
                    cur.zero_copy -| prev.zero_copy,
                    cur.discarded -| prev.discarded,
                    n.target.modifier,
                    if (n.target.scanout_tranche) " scanout-tranche" else "",
                });
            }
        }
    }

    fn renderDevice(device: *Device, trees: []const Device.TreeWork, stats: *Device.FrameStats, result: *anyerror!void) void {
        device.renderFrame(trees, stats) catch |err| {
            result.* = err;
        };
    }
};
