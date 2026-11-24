const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wl = @import("wl");
const vk_core = @import("vk_core");
const vk_present = @import("vk_present");
const Gpu = @import("Gpu.zig");
const EventLoop = @import("EventLoop.zig");
const metrics = @import("metrics.zig");
const demo = @import("demo.zig");

// Let vulkan-zig use the real libwayland types for its platform structs.
pub const wl_display = wl.c.wl_display;
pub const wl_surface = wl.c.wl_surface;

pub const std_options: std.Options = .{
    .log_level = .info,
    // Per-subsystem verbosity: .drm, .dmabuf, .wl, .vk, .present, .scene, .metrics, .demo
    .log_scope_levels = &.{
        .{ .scope = .present, .level = .info },
        .{ .scope = .drm, .level = .warn },
    },
};

const log = std.log.scoped(.app);

const usage =
    \\Usage: codotaka [--hdr] [window-count]
    \\  --hdr   render FP16 scRGB and tag surfaces with the Windows-scRGB image description
    \\Middle-click the top-left view to promote/demote it to its own subsurface.
    \\
;

pub fn main(init: std.process.Init) !void {
    var window_count: usize = 2;
    var color: wl.ColorMode = .sdr;
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

    var app = try App.init(init.gpa, init.io, window_count, color);
    defer app.deinit();
    try app.run();
}

const Scene = demo.Scene;
const TreeWork = vk_present.Presenter.TreeWork;

/// Glue between a scene window and the GPU it lives on.
const Binding = struct {
    gpa: Allocator,
    gpu: *Gpu,
    color: wl.ColorMode,

    fn factory(self: *Binding) Scene.TargetFactory {
        return .{ .ctx = self, .create = createTarget, .destroy = destroyTarget };
    }
    fn createTarget(ctx: *anyopaque, surface: *wl.Surface) anyerror!*vk_present.SurfaceTarget {
        const self: *Binding = @ptrCast(@alignCast(ctx));
        return vk_present.SurfaceTarget.create(self.gpa, self.gpu.presenter, surface, self.color);
    }
    fn destroyTarget(_: *anyopaque, target: *vk_present.SurfaceTarget) void {
        target.destroy();
    }
};

const Entry = struct {
    window: *demo.Window,
    binding: *Binding,
};

const App = struct {
    gpa: Allocator,
    io: Io,
    color: wl.ColorMode,
    display: *wl.Display,
    instance: *vk_core.Instance,
    gpus: []*Gpu,
    entries: std.ArrayList(Entry) = .empty,
    history: metrics.SurfaceHistory = .{},
    totals: metrics.Totals = .{},

    fn init(gpa: Allocator, io: Io, window_count: usize, color: wl.ColorMode) !App {
        const display = try wl.Display.connect(gpa);
        errdefer display.disconnect();
        const instance = try vk_core.Instance.create(gpa, .{ .app_name = "codotaka", .validation = builtin.mode == .debug });
        errdefer instance.destroy();

        const candidates = try instance.findCandidates(gpa, &vk_present.device_extensions, {}, vk_present.acceptDevice);
        defer gpa.free(candidates);

        var gpus: std.ArrayList(*Gpu) = .empty;
        errdefer {
            for (gpus.items) |g| g.destroy();
            gpus.deinit(gpa);
        }
        for (candidates) |cand| {
            try gpus.ensureUnusedCapacity(gpa, 1);
            gpus.appendAssumeCapacity(try Gpu.create(gpa, instance, cand));
        }

        var app: App = .{
            .gpa = gpa,
            .io = io,
            .color = color,
            .display = display,
            .instance = instance,
            .gpus = try gpus.toOwnedSlice(gpa),
        };
        errdefer app.deinit();
        try app.entries.ensureTotalCapacity(gpa, window_count);
        for (0..window_count) |i| app.entries.appendAssumeCapacity(try app.openWindow(i));
        return app;
    }

    fn deinit(app: *App) void {
        for (app.entries.items) |e| app.closeEntry(e);
        app.entries.deinit(app.gpa);
        app.history.deinit(app.gpa);
        for (app.gpus) |g| g.destroy();
        app.gpa.free(app.gpus);
        app.instance.destroy();
        app.display.disconnect();
        app.* = undefined;
    }

    /// Opens a demo window on the first GPU (starting round-robin at `index`) whose dmabufs
    /// the compositor accepts for it.
    fn openWindow(app: *App, index: usize) !Entry {
        const gpa = app.gpa;
        var title_buf: [64]u8 = undefined;
        const title = try std.fmt.bufPrintSentinel(&title_buf, "codotaka #{d}{s}", .{ index, if (app.color == .hdr_scrgb) " (HDR scRGB)" else "" }, 0);
        const window = try wl.Window.create(app.display, title, "codotaka");
        var window_owned = true;
        errdefer if (window_owned) window.destroy();

        const binding = try gpa.create(Binding);
        errdefer gpa.destroy(binding);
        const root_target = for (0..app.gpus.len) |offset| {
            const gpu = app.gpus[(index + offset) % app.gpus.len];
            binding.* = .{ .gpa = gpa, .gpu = gpu, .color = app.color };
            break vk_present.SurfaceTarget.create(gpa, gpu.presenter, window.root, app.color) catch |err| switch (err) {
                error.NoCompatibleTranche, error.ColorModeUnsupported => continue,
                else => return err,
            };
        } else return error.NoCompatibleDevice;

        const Creator = struct {
            gpa: Allocator,
            window: *wl.Window,
            root_target: *vk_present.SurfaceTarget,
            binding: *Binding,
            pub fn call(c: @This(), hooks: Scene.Hooks) !*Scene.SceneWindow {
                return Scene.SceneWindow.create(c.gpa, c.window, c.root_target, c.binding.color, vk_present.formats.forMode(c.binding.color).white_scale, c.binding.factory(), hooks);
            }
        };
        const dw = demo.Window.create(gpa, index, title, Creator{ .gpa = gpa, .window = window, .root_target = root_target, .binding = binding }) catch |err| {
            root_target.destroy();
            return err;
        };
        window_owned = false;
        log.info("window #{d} -> {s}, csd={}", .{ index, binding.gpu.name(), window.csd });
        return .{ .window = dw, .binding = binding };
    }

    fn closeEntry(app: *App, e: Entry) void {
        var it = e.window.sw.nodeList();
        while (it.next()) |n| app.history.forget(n.surface);
        e.window.destroy();
        app.gpa.destroy(e.binding);
    }

    fn nowNs(app: *App) i128 {
        return Io.Timestamp.now(app.io, .awake).nanoseconds;
    }

    fn run(app: *App) !void {
        const gpa = app.gpa;
        const io = app.io;
        const results = try gpa.alloc(anyerror!void, app.gpus.len);
        defer gpa.free(results);
        const stats = try gpa.alloc(vk_present.Presenter.Stats, app.gpus.len);
        defer gpa.free(stats);
        const trees = try gpa.alloc(std.ArrayList(TreeWork), app.gpus.len);
        defer gpa.free(trees);

        // Planning scratch (views, damage, tree lists), reset every iteration.
        var plan_arena: std.heap.ArenaAllocator = .init(gpa);
        defer plan_arena.deinit();
        var loop: EventLoop = .{ .gpa = gpa };
        defer loop.deinit();
        const report_interval = 5 * std.time.ns_per_s;
        var last_report = app.nowNs();
        const start = last_report;

        while (app.entries.items.len > 0) {
            try app.display.wait(&.{}, 0);

            var i: usize = 0;
            while (i < app.entries.items.len) {
                if (app.entries.items[i].window.sw.window.should_close) {
                    app.closeEntry(app.entries.swapRemove(i));
                } else i += 1;
            }
            if (app.entries.items.len == 0) break;

            if (builtin.mode == .debug) if (std.c.getenv("CODOTAKA_EXIT_AFTER")) |v| {
                // Test hook: close every window after N seconds (exercises full teardown and
                // the debug allocator's leak check).
                const secs = std.fmt.parseInt(i64, std.mem.span(v), 10) catch 3;
                if (app.nowNs() - start >= @as(i128, secs) * std.time.ns_per_s) {
                    for (app.entries.items) |e| e.window.sw.window.close();
                }
            };
            if (builtin.mode == .debug and std.c.getenv("CODOTAKA_TOGGLE_TEST") != null) {
                // Stress test for runtime node creation/removal: toggles promotion every second.
                const want = @mod(@divFloor(app.nowNs(), std.time.ns_per_s), 2) == 0;
                for (app.entries.items) |e| if (e.window.want_promoted != want) e.window.togglePromotion();
            }

            _ = plan_arena.reset(.retain_capacity);
            const arena = plan_arena.allocator();
            const now = app.nowNs();
            loop.reset();

            for (trees) |*t| t.* = .empty;
            for (app.entries.items) |e| {
                const sw = e.window.sw;
                if (try sw.plan(arena, sw.frameTime(now))) |tree| {
                    const gi = std.mem.indexOfScalar(*Gpu, app.gpus, e.binding.gpu).?;
                    try trees[gi].append(arena, tree);
                }
                if (sw.next_wake_ns) |t| loop.addDeadline(t);
            }

            // One task per GPU: a queue must not be used from two tasks at once, but
            // different GPUs render in parallel. Each task issues one batched submit.
            var group: Io.Group = .init;
            defer group.cancel(io);
            for (app.gpus, results, stats, trees) |gpu, *result, *st, t| {
                result.* = {};
                st.* = .{};
                group.async(io, renderGpu, .{ gpu, t.items, st, result });
            }
            try group.await(io);
            for (results) |r| try r;
            for (app.entries.items) |e| e.window.sw.afterFrame();
            app.display.flush();

            var frame_metrics: metrics.Frame = .{};
            for (stats) |st| frame_metrics.add(st);
            app.totals.add(frame_metrics);

            if (now - last_report >= report_interval) {
                try app.report(@as(f64, @floatFromInt(now - last_report)) / std.time.ns_per_s);
                last_report = now;
            }
            if (frame_metrics.trees_committed > 0) continue;

            // Nothing presentable right now: sleep until the compositor asks for a frame,
            // a buffer is released, input arrives, or a content timer fires.
            if (frame_metrics.gpu_blocked) loop.pollEvery(1);
            loop.addDeadline(last_report + report_interval);
            for (app.entries.items) |e| {
                var it = e.window.sw.nodeList();
                while (it.next()) |n| try loop.addFd(n.target.eventFd());
            }
            try loop.wait(app.display, app.nowNs());
            for (app.entries.items) |e| {
                var it = e.window.sw.nodeList();
                while (it.next()) |n| n.target.drainEventFd();
            }
        }
    }

    fn report(app: *App, seconds: f64) !void {
        metrics.reportTotals(&app.totals, seconds);
        for (app.entries.items, 0..) |e, wi| {
            const w = e.window.sw.window;
            const refresh = w.root.stats.refresh_ns;
            log.info("window #{d} on {s}: scale {d:.2}, refresh {d:.1} Hz", .{
                wi,
                e.binding.gpu.name(),
                w.scale.factor(),
                if (refresh > 0) 1e9 / @as(f64, @floatFromInt(refresh)) else 0,
            });
            var it = e.window.sw.nodeList();
            while (it.next()) |n| metrics.reportSurface(n.name, try app.history.delta(app.gpa, n.surface), n.target);
        }
    }

    fn renderGpu(gpu: *Gpu, trees: []const TreeWork, stats: *vk_present.Presenter.Stats, result: *anyerror!void) void {
        gpu.renderFrame(trees, stats) catch |err| {
            result.* = err;
        };
    }
};
