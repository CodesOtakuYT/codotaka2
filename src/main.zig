const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wl = @import("wl");
const vk_core = @import("vk_core");
const vk_present = @import("vk_present");
const text = @import("text");
const Gpu = @import("Gpu.zig");
const EventLoop = @import("EventLoop.zig");
const metrics = @import("metrics.zig");
const demo = @import("demo.zig");
const player = @import("player.zig");
const media = @import("media");

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

/// Validation messages from FFmpeg 9.1's Vulkan Video decode on this driver: reproducible
/// with the plain `ffmpeg -hwaccel vulkan` CLI, so not caused by our interop.
var known_issues = [_]vk_core.Instance.KnownIssue{
    .{ .vuid = "VUID-VkImageCreateInfo-pNext-06811", .reason = "FFmpeg Vulkan decode image flags" },
    .{ .vuid = "VUID-VkVideoBeginCodingInfoKHR-flags-07244", .reason = "FFmpeg Vulkan decode reference slots" },
    .{ .vuid = "VUID-VkVideoBeginCodingInfoKHR-pPictureResource-07240", .reason = "FFmpeg Vulkan decode reference slots" },
    .{ .vuid = "VUID-vkCmdDecodeVideoKHR-pDecodeInfo-07142", .reason = "FFmpeg Vulkan decode reference slots" },
};

const usage =
    \\Usage: codotaka [--hdr] [window-count]      demo windows
    \\       codotaka [--hdr] <video-file>        video player (Vulkan Video, zero copy)
    \\  --hdr   render FP16 scRGB and tag surfaces with the Windows-scRGB image description
    \\Player keys: space pause, f fullscreen, q/Esc quit.
    \\Middle-click the top-left view to promote/demote it to its own subsurface.
    \\Type into the bottom field; Ctrl+Q closes a window.
    \\
;

pub fn main(init: std.process.Init) !void {
    var window_count: usize = 2;
    var video: ?[:0]const u8 = null;
    var color: wl.ColorMode = .sdr;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--hdr")) {
            color = .hdr_scrgb;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(usage, .{});
            return;
        } else if (std.fmt.parseInt(usize, arg, 10)) |n| {
            window_count = n;
        } else |_| {
            video = arg;
        }
    }

    var app = try App.init(init.gpa, init.io, if (video) |v| .{ .player = v } else .{ .demo = window_count }, color);
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
    fn createTarget(ctx: *anyopaque, surface: *wl.Surface, translucent: bool) anyerror!*vk_present.SurfaceTarget {
        const self: *Binding = @ptrCast(@alignCast(ctx));
        return vk_present.SurfaceTarget.create(self.gpa, self.gpu.presenter, surface, self.color, translucent);
    }
    fn destroyTarget(_: *anyopaque, target: *vk_present.SurfaceTarget) void {
        target.destroy();
    }
};

const Entry = struct {
    kind: union(enum) {
        demo: *demo.Window,
        player: struct { window: *player.Window, decoder: *media.Decoder },
    },
    binding: *Binding,

    fn sw(e: Entry) *Scene.SceneWindow {
        return switch (e.kind) {
            .demo => |d| d.sw,
            .player => |p| p.window.sw,
        };
    }
};

const Mode = union(enum) {
    demo: usize,
    player: [:0]const u8,
};

const App = struct {
    gpa: Allocator,
    io: Io,
    color: wl.ColorMode,
    display: *wl.Display,
    fonts: *text.FontSystem,
    instance: *vk_core.Instance,
    gpus: []*Gpu,
    /// FFmpeg devices on our GPUs (player mode), parallel to `gpus`.
    hw_devices: []?media.HwDevice = &.{},
    entries: std.ArrayList(Entry) = .empty,
    history: metrics.SurfaceHistory = .{},
    totals: metrics.Totals = .{},

    fn init(gpa: Allocator, io: Io, mode: Mode, color: wl.ColorMode) !App {
        const display = try wl.Display.connect(gpa);
        errdefer display.disconnect();
        const fonts = try text.FontSystem.create(gpa, "sans-serif");
        errdefer fonts.destroy();
        const instance = try vk_core.Instance.create(gpa, .{ .app_name = "codotaka", .validation = builtin.mode == .debug, .known_issues = &known_issues });
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
            gpus.appendAssumeCapacity(try Gpu.create(gpa, instance, cand, &fonts.glyphs, mode == .player));
        }

        var app: App = .{
            .gpa = gpa,
            .io = io,
            .color = color,
            .display = display,
            .fonts = fonts,
            .instance = instance,
            .gpus = try gpus.toOwnedSlice(gpa),
        };
        errdefer app.deinit();
        app.hw_devices = try gpa.alloc(?media.HwDevice, app.gpus.len);
        @memset(app.hw_devices, null);
        switch (mode) {
            .demo => |count| {
                try app.entries.ensureTotalCapacity(gpa, count);
                for (0..count) |i| app.entries.appendAssumeCapacity(try app.openWindow(i, null));
            },
            .player => |path| try app.entries.append(gpa, try app.openWindow(0, path)),
        }
        return app;
    }

    fn deinit(app: *App) void {
        for (app.entries.items) |e| app.closeEntry(e);
        app.entries.deinit(app.gpa);
        app.history.deinit(app.gpa);
        for (app.hw_devices) |*h| if (h.*) |*d| d.destroy();
        app.gpa.free(app.hw_devices);
        for (app.gpus) |g| g.destroy();
        app.gpa.free(app.gpus);
        vk_core.Instance.reportKnownIssues(&known_issues);
        app.instance.destroy();
        app.fonts.destroy();
        app.display.disconnect();
        app.* = undefined;
    }

    /// Opens a demo window (or a player for `video`) on the first GPU, starting round-robin
    /// at `index`, whose dmabufs the compositor accepts for it.
    fn openWindow(app: *App, index: usize, video: ?[:0]const u8) !Entry {
        const gpa = app.gpa;
        var title_buf: [256]u8 = undefined;
        const hdr_note = if (app.color == .hdr_scrgb) " (HDR scRGB)" else "";
        const title = if (video) |v|
            try std.fmt.bufPrintSentinel(&title_buf, "{s}{s}", .{ std.fs.path.basename(v), hdr_note }, 0)
        else
            try std.fmt.bufPrintSentinel(&title_buf, "codotaka #{d}{s}", .{ index, hdr_note }, 0);
        const window = try wl.Window.create(app.display, title, "codotaka");
        var window_owned = true;
        errdefer if (window_owned) window.destroy();

        const binding = try gpa.create(Binding);
        errdefer gpa.destroy(binding);
        const root_target = for (0..app.gpus.len) |offset| {
            const gpu = app.gpus[(index + offset) % app.gpus.len];
            binding.* = .{ .gpa = gpa, .gpu = gpu, .color = app.color };
            break vk_present.SurfaceTarget.create(gpa, gpu.presenter, window.root, app.color, false) catch |err| switch (err) {
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
                return Scene.SceneWindow.create(c.gpa, c.window, c.root_target, c.binding.color, vk_present.formats.forMode(c.binding.color, false).white_scale, c.binding.factory(), hooks);
            }
        };
        const creator: Creator = .{ .gpa = gpa, .window = window, .root_target = root_target, .binding = binding };
        errdefer if (window_owned) root_target.destroy();
        const entry: Entry = if (video) |path| blk: {
            const gi = std.mem.indexOfScalar(*Gpu, app.gpus, binding.gpu).?;
            if (app.hw_devices[gi] == null) app.hw_devices[gi] = try media.HwDevice.create(binding.gpu.device);
            const decoder = try media.Decoder.open(gpa, app.io, &app.hw_devices[gi].?, path, .{});
            errdefer decoder.close();
            const pw = try player.Window.create(gpa, app.fonts, decoder, title, creator);
            window_owned = false;
            decoder.start() catch |err| {
                pw.destroy();
                decoder.close();
                return err;
            };
            break :blk .{ .kind = .{ .player = .{ .window = pw, .decoder = decoder } }, .binding = binding };
        } else blk: {
            const dw = try demo.Window.create(gpa, app.fonts, index, title, creator);
            window_owned = false;
            break :blk .{ .kind = .{ .demo = dw }, .binding = binding };
        };
        log.info("window #{d} -> {s}, csd={}", .{ index, binding.gpu.name(), window.csd });
        return entry;
    }

    fn closeEntry(app: *App, e: Entry) void {
        var it = e.sw().nodeList();
        while (it.next()) |n| app.history.forget(n.surface);
        switch (e.kind) {
            .demo => |d| d.destroy(),
            .player => |p| {
                // Releasing frames can destroy FFmpeg's pool images: let the GPU finish
                // with them first, then stop decoding, then tear the scene down.
                e.binding.gpu.device.waitIdle();
                p.window.stopAudio();
                p.decoder.close();
                const st = p.window.stats();
                log.info("player: {d} frames shown, {d} dropped", .{ st.shown, st.dropped });
                if (st.sync_samples > 0) log.info("A/V sync vs audio clock: mean |error| {d:.2} ms, max {d:.2} ms over {d} frames", .{
                    @as(f64, @floatFromInt(@divFloor(st.sync_abs_sum_ns, st.sync_samples))) / 1e6,
                    @as(f64, @floatFromInt(st.sync_max_abs_ns)) / 1e6,
                    st.sync_samples,
                });
                p.window.destroy();
            },
        }
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
            _ = try app.display.wait(&.{}, 0);
            app.display.tickRepeat(app.nowNs());

            var i: usize = 0;
            while (i < app.entries.items.len) {
                if (app.entries.items[i].sw().window.should_close) {
                    app.closeEntry(app.entries.swapRemove(i));
                } else i += 1;
            }
            if (app.entries.items.len == 0) break;

            if (builtin.mode == .debug) if (std.c.getenv("CODOTAKA_EXIT_AFTER")) |v| {
                // Test hook: close every window after N seconds (exercises full teardown and
                // the debug allocator's leak check).
                const secs = std.fmt.parseInt(i64, std.mem.span(v), 10) catch 3;
                if (app.nowNs() - start >= @as(i128, secs) * std.time.ns_per_s) {
                    for (app.entries.items) |e| e.sw().window.close();
                }
            };
            if (builtin.mode == .debug and std.c.getenv("CODOTAKA_TOGGLE_TEST") != null) {
                // Stress test for runtime node creation/removal: toggles promotion every second.
                const want = @mod(@divFloor(app.nowNs(), std.time.ns_per_s), 2) == 0;
                for (app.entries.items) |e| if (e.kind == .demo and e.kind.demo.want_promoted != want) e.kind.demo.togglePromotion();
            }

            _ = plan_arena.reset(.retain_capacity);
            const arena = plan_arena.allocator();
            const now = app.nowNs();
            loop.reset();

            for (trees) |*t| t.* = .empty;
            if (app.display.repeatDeadline()) |t| loop.addDeadline(t);
            for (app.entries.items) |e| {
                if (e.kind == .demo) e.kind.demo.syncFocus();
                const sw = e.sw();
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
            for (app.entries.items) |e| e.sw().afterFrame();
            app.display.flush();

            var frame_metrics: metrics.Frame = .{};
            for (stats) |st| frame_metrics.add(st);
            app.totals.add(frame_metrics);

            if (now - last_report >= report_interval) {
                try app.report(@as(f64, @floatFromInt(now - last_report)) / std.time.ns_per_s);
                loop.reportWakes();
                last_report = now;
            }
            if (frame_metrics.trees_committed > 0) continue;

            // Nothing presentable right now: sleep until the compositor asks for a frame,
            // a buffer is released, input arrives, or a content timer fires.
            if (frame_metrics.gpu_blocked) loop.pollEvery(1);
            loop.addDeadline(last_report + report_interval);
            for (app.entries.items) |e| {
                var it = e.sw().nodeList();
                while (it.next()) |n| try loop.addFd(n.target.eventFd(), .buffer_release);
                if (e.kind == .player and e.kind.player.window.wantsFrames())
                    try loop.addFd(e.kind.player.decoder.eventFd(), .decoder);
            }
            try loop.wait(app.display, app.nowNs());
            for (app.entries.items) |e| {
                var it = e.sw().nodeList();
                while (it.next()) |n| n.target.drainEventFd();
            }
        }
    }

    fn report(app: *App, seconds: f64) !void {
        metrics.reportTotals(&app.totals, seconds);
        for (app.entries.items, 0..) |e, wi| {
            const w = e.sw().window;
            const refresh = w.root.stats.refresh_ns;
            log.info("window #{d} on {s}: scale {d:.2}, refresh {d:.1} Hz", .{
                wi,
                e.binding.gpu.name(),
                w.scale.factor(),
                if (refresh > 0) 1e9 / @as(f64, @floatFromInt(refresh)) else 0,
            });
            var it = e.sw().nodeList();
            while (it.next()) |n| metrics.reportSurface(n.name, try app.history.delta(app.gpa, n.surface), n.target);
        }
    }

    fn renderGpu(gpu: *Gpu, trees: []const TreeWork, stats: *vk_present.Presenter.Stats, result: *anyerror!void) void {
        gpu.renderFrame(trees, stats) catch |err| {
            result.* = err;
        };
    }
};
