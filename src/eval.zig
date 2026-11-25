//! Offline quality evaluation of frame interpolation (no window, no compositor).
//!
//! Decodes a high-frame-rate video, keeps every `step`-th frame as the "low frame rate"
//! input and interpolates the frames in between with the real renderer (same shaders, same
//! optical flow path as the player). Each synthesized frame is compared with the real frame
//! that was dropped, next to two baselines: repeating the nearest frame (what a player does
//! without interpolation) and a plain crossfade.
//!
//! Everything stays on the GPU: the candidates are rendered into offscreen images and a
//! compute pass (shaders/metric.comp) sums their squared errors; the CPU reads 4 floats per
//! synthesized frame, once per interval. Scores are PSNR of gamma-encoded RGB from the mean
//! squared error over all frames, plus the worst frame.
const std = @import("std");
const vk = @import("vulkan");
const vk_core = @import("vk_core");
const vk_present = @import("vk_present");
const frame = @import("frame");
const text = @import("text");
const media = @import("media");
const Renderer = @import("Renderer.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.eval);

/// C stdio for the report files (libc is linked anyway).
const cio = struct {
    const FILE = opaque {};
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern "c" fn fclose(f: *FILE) c_int;
    extern "c" fn fprintf(f: *FILE, fmt: [*:0]const u8, ...) c_int;
    extern "c" fn fwrite(ptr: *const anyopaque, size: usize, n: usize, f: *FILE) usize;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
};

pub const Options = struct {
    path: [:0]const u8,
    /// Keep every step-th frame (60 fps / 6 = 10 fps).
    step: u32 = 6,
    /// Number of input intervals (pairs of kept frames) to evaluate.
    intervals: u32 = 40,
    /// Skip this many seconds from the start (titles are static).
    start_s: f64 = 0,
    /// Evaluation resolution (frames are scaled to this width).
    width: u32 = 1920,
    /// Per-frame scores as CSV.
    csv: ?[:0]const u8 = null,
    /// Heat maps (PPM) of the worst interpolated frames go here.
    worst_dir: ?[:0]const u8 = null,
    worst_count: u32 = 8,
};

const Method = enum { nearest, crossfade, interpolated };

/// Errors are averaged as MSE and converted to PSNR once (averaging dB would let static,
/// pixel-identical frames dominate).
const Score = struct {
    sum_mse: f64 = 0,
    worst_mse: f64 = 0,
    count: u32 = 0,

    fn add(s: *Score, e: f64) void {
        s.sum_mse += e;
        s.worst_mse = @max(s.worst_mse, e);
        s.count += 1;
    }
    fn mean(s: Score) f64 {
        return if (s.count == 0) 0 else toDb(s.sum_mse / @as(f64, @floatFromInt(s.count)));
    }
    fn worst(s: Score) f64 {
        return toDb(s.worst_mse);
    }
};

fn toDb(e: f64) f64 {
    return if (e <= 1e-12) 99 else 10 * std.math.log10(1 / e);
}

/// Intervals whose endpoints differ this much (PSNR) contain a scene cut: excluded, since
/// no interpolation can recover a cut from its two sides.
const cut_db = 12.0;

const metric_spv align(@alignOf(u32)) = @embedFile("metric.comp.spv").*;
const heat_spv align(@alignOf(u32)) = @embedFile("heat.comp.spv").*;

const HeatPush = extern struct { out_pixels: u64, truth: u32, ours: u32 };

const MetricPush = extern struct {
    out_sums: u64,
    truth: u32,
    a: u32,
    b: u32,
    ours: u32,
    t: f32,
};

pub fn run(gpa: Allocator, io: Io, instance: *vk_core.Instance, candidate: vk_core.Instance.Candidate, opts: Options) !void {
    const device = try vk_core.Device.create(gpa, instance, candidate, .{ .extensions = &vk_present.device_extensions, .video_decode = true, .optical_flow = true });
    defer device.destroy();
    if (device.flow_queue == null) return error.OpticalFlowUnavailable;
    const fonts = try text.FontSystem.create(gpa, "sans-serif");
    defer fonts.destroy();
    const renderer = try Renderer.create(gpa, device, &fonts.glyphs);
    defer renderer.destroy();
    var ring = try vk_core.FrameRing.init(device, .{ .signal_done = false });
    defer ring.deinit();

    var hw = try media.HwDevice.create(device);
    defer hw.destroy();
    const decoder = try media.Decoder.open(gpa, io, &hw, opts.path, .{ .loop = false, .audio = false, .extra_frames = opts.step + 2 + media.Decoder.queue_depth });
    defer decoder.close();
    if (opts.start_s > 0) _ = decoder.seek(@intFromFloat(opts.start_s * std.time.ns_per_s));
    try decoder.start();

    var ev: Eval = .{
        .gpa = gpa,
        .io = io,
        .device = device,
        .renderer = renderer,
        .ring = &ring,
        .decoder = decoder,
        .opts = opts,
        .metric = try renderer.shaders.registerCompute(&metric_spv),
        .heat = try renderer.shaders.registerCompute(&heat_spv),
    };
    if (opts.csv) |path| {
        ev.csv = cio.fopen(path, "w") orelse return error.CannotWriteCsv;
        _ = cio.fprintf(ev.csv.?, "interval,k,t,time_s,endpoint_db,nearest_db,crossfade_db,interpolated_db,scene_cut\n");
    }
    defer ev.deinit();
    try ev.run();
}

const Image = enum { truth, a, b, ours };

const Worst = struct { mse: f64, path: [256]u8, path_len: usize };

const Eval = struct {
    gpa: Allocator,
    io: Io,
    device: *vk_core.Device,
    renderer: *Renderer,
    ring: *vk_core.FrameRing,
    decoder: *media.Decoder,
    opts: Options,
    metric: vk_core.ShaderCache.ComputeId,
    heat: vk_core.ShaderCache.ComputeId,
    csv: ?*cio.FILE = null,
    /// Worst interpolated frames so far (heat maps written), by squared error.
    worst: std.ArrayList(Worst) = .empty,
    heat_pixels: vk_core.Buffer = .{},
    interval_index: u32 = 0,
    /// Source frame duration.
    frame_ns: i64 = 0,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    images: std.EnumArray(Image, vk_core.Image) = .initFill(.{}),
    slots: std.EnumArray(Image, vk_core.DescriptorHeaps.ImageSlot) = undefined,
    /// 4 sums per synthesized frame of the current interval (host-cached, GPU atomics).
    sums: vk_core.Buffer = .{},
    held: std.ArrayList(media.Frame) = .empty,
    scores: std.EnumArray(Method, Score) = .initFill(.{}),
    cuts: u32 = 0,
    static_frames: u32 = 0,

    fn deinit(self: *Eval) void {
        self.device.waitIdle();
        for (self.held.items) |*f| f.release();
        self.held.deinit(self.gpa);
        for (&self.images.values) |*img| if (img.image != .null) img.deinit(self.device);
        if (self.sums.buffer != .null) self.sums.deinit(self.device);
        if (self.heat_pixels.buffer != .null) self.heat_pixels.deinit(self.device);
        self.worst.deinit(self.gpa);
        if (self.csv) |f| _ = cio.fclose(f);
    }

    /// Next decoded frame (of the current seek generation), or null at the end.
    fn next(self: *Eval) !?media.Frame {
        var idle_ms: u32 = 0;
        while (idle_ms < 3000) {
            var buf: [1]media.Frame = undefined;
            if (self.decoder.poll(&buf) == 1) {
                if (buf[0].generation == self.decoder.currentGeneration()) return buf[0];
                buf[0].release();
                continue;
            }
            try self.io.sleep(.fromMilliseconds(1), .awake);
            idle_ms += 1;
        }
        return null;
    }

    fn run(self: *Eval) !void {
        const step = self.opts.step;
        // held[0] = A, held[1..step] = the frames to synthesize, held[step] = B.
        while (self.held.items.len < step + 1) {
            const f = try self.next() orelse return error.VideoTooShort;
            try self.held.append(self.gpa, f);
        }
        try self.setup(&self.held.items[0]);
        self.frame_ns = self.held.items[1].pts_ns - self.held.items[0].pts_ns;
        log.info("evaluating {s}: every {d}th frame kept, {d} intervals at {d}x{d}", .{ self.opts.path, step, self.opts.intervals, self.extent.width, self.extent.height });

        var interval: u32 = 0;
        while (interval < self.opts.intervals) : (interval += 1) {
            self.interval_index = interval;
            try self.evalInterval();
            // Slide: B becomes the next A.
            for (self.held.items[0..step]) |*f| f.release();
            self.held.replaceRange(self.gpa, 0, step, &.{}) catch unreachable;
            while (self.held.items.len < step + 1) {
                const f = try self.next() orelse break;
                try self.held.append(self.gpa, f);
            }
            if (self.held.items.len < step + 1) break;
        }
        const total = self.scores.get(.interpolated).count;
        log.info("results over {d} synthesized frames ({d} static), {d} intervals with scene cuts excluded", .{ total, self.static_frames, self.cuts });
        log.info("PSNR of gamma-encoded RGB (from mean MSE; higher is better):", .{});
        for (std.enums.values(Method)) |m| {
            const s = self.scores.get(m);
            log.info("  {t:<13} {d:6.2} dB   worst frame {d:6.2} dB", .{ m, s.mean(), s.worst() });
        }
        if (self.opts.csv) |path| log.info("per-frame scores: {s}", .{path});
        if (self.opts.worst_dir) |dir| log.info("heat maps of the {d} worst frames: {s}/", .{ self.worst.items.len, dir });
    }

    fn setup(self: *Eval, sample: *const media.Frame) !void {
        const w = @min(self.opts.width, sample.width());
        const h: u32 = @intCast(@as(u64, sample.height()) * w / sample.width());
        self.extent = .{ .width = w, .height = h };
        for (std.enums.values(Image)) |which| {
            const img = self.images.getPtr(which);
            img.* = try vk_core.Image.create(self.device, .{
                .format = .r16g16b16a16_sfloat,
                .extent = self.extent,
                .usage = .{ .color_attachment = true, .sampled = true, .host_transfer = true },
            });
            try img.hostTransition(self.device, .undefined, .general);
            self.slots.set(which, try self.renderer.heaps.addImage(img));
        }
        if (self.opts.worst_dir != null) self.heat_pixels = try vk_core.Buffer.create(self.device, .{
            .size = @as(u64, w) * 2 * h * 4,
            .usage = .{ .storage_buffer = true, .shader_device_address = true },
            .readback = true,
        });
        self.sums = try vk_core.Buffer.create(self.device, .{
            .size = @as(u64, self.opts.step) * 4 * @sizeOf(f32),
            .usage = .{ .storage_buffer = true, .transfer_dst = true, .shader_device_address = true },
            .readback = true,
        });
    }

    fn evalInterval(self: *Eval) !void {
        const step = self.opts.step;
        const a = &self.held.items[0];
        const b = &self.held.items[step];
        @memset(self.sumsSlice(), 0);
        try self.device.proxy.flushMappedMemoryRanges(&.{.{ .memory = self.sums.memory, .offset = 0, .size = vk.WHOLE_SIZE }});
        // Queue the pair's vector estimation (usable by the next submission), and render
        // both endpoints; nothing here waits for the GPU.
        try self.render(.{ .frame = a, .next = b, .alpha = 0, .interpolation = .on }, .ours, .none);
        try self.render(.{ .frame = a }, .a, .none);
        try self.render(.{ .frame = b }, .b, .none);
        for (1..step) |k| {
            const t = self.tOf(k);
            try self.render(.{ .frame = &self.held.items[k] }, .truth, .none);
            try self.render(.{ .frame = a, .next = b, .alpha = t, .interpolation = .on }, .ours, .{ .metric = .{ .k = @intCast(k), .t = t } });
        }
        // One wait per interval, then 4 floats per synthesized frame.
        try self.device.waitValue(self.device.lastValue());
        try self.device.proxy.invalidateMappedMemoryRanges(&.{.{ .memory = self.sums.memory, .offset = 0, .size = vk.WHOLE_SIZE }});
        const pixels: f64 = @floatFromInt(@as(u64, self.extent.width) * self.extent.height * 3);
        const sums = self.sumsSlice();
        const endpoint_db = toDb(sums[4 * 1 + 3] / pixels);
        const cut = endpoint_db < cut_db;
        if (self.csv) |f| for (1..step) |k| {
            const s = sums[4 * k ..][0..4];
            const time_s = self.opts.start_s + @as(f64, @floatFromInt(@as(u64, self.interval_index) * step + k)) * @as(f64, @floatFromInt(self.frame_ns)) / std.time.ns_per_s;
            _ = cio.fprintf(f, "%u,%u,%.4f,%.3f,%.3f,%.3f,%.3f,%.3f,%d\n", self.interval_index, @as(c_uint, @intCast(k)), @as(f64, self.tOf(k)), time_s, endpoint_db, toDb(s[0] / pixels), toDb(s[1] / pixels), toDb(s[2] / pixels), @as(c_int, @intFromBool(cut)));
        };
        if (cut) {
            self.cuts += 1;
            return;
        }
        var worst_k: usize = 1;
        for (1..step) |k| {
            const s = sums[4 * k ..][0..4];
            if (s[0] <= 0) self.static_frames += 1;
            self.scores.getPtr(.nearest).add(s[0] / pixels);
            self.scores.getPtr(.crossfade).add(s[1] / pixels);
            self.scores.getPtr(.interpolated).add(s[2] / pixels);
            if (s[2] > sums[4 * worst_k + 2]) worst_k = k;
        }
        if (self.opts.worst_dir != null) try self.keepIfWorst(worst_k, sums[4 * worst_k + 2] / pixels);
    }

    fn tOf(self: *const Eval, k: usize) f32 {
        return @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(self.opts.step));
    }

    /// Writes a heat map of synthesized frame k if it is among the worst so far (replacing
    /// the least bad one once the list is full).
    fn keepIfWorst(self: *Eval, k: usize, frame_mse: f64) !void {
        var replace: ?usize = null;
        if (self.worst.items.len >= self.opts.worst_count) {
            var least: usize = 0;
            for (self.worst.items, 0..) |w, i| if (w.mse < self.worst.items[least].mse) {
                least = i;
            };
            if (frame_mse <= self.worst.items[least].mse) return;
            replace = least;
        }
        const t = self.tOf(k);
        try self.render(.{ .frame = &self.held.items[k] }, .truth, .none);
        try self.render(.{ .frame = &self.held.items[0], .next = &self.held.items[self.opts.step], .alpha = t, .interpolation = .on }, .ours, .heat);
        try self.device.waitValue(self.device.lastValue());
        try self.device.proxy.invalidateMappedMemoryRanges(&.{.{ .memory = self.heat_pixels.memory, .offset = 0, .size = vk.WHOLE_SIZE }});

        var entry: Worst = .{ .mse = frame_mse, .path = undefined, .path_len = 0 };
        const path = try std.fmt.bufPrintSentinel(&entry.path, "{s}/worst_{d:0>4}_{d}_{d:.1}dB.ppm", .{ self.opts.worst_dir.?, self.interval_index, k, toDb(frame_mse) }, 0);
        entry.path_len = path.len;
        try self.writePpm(path);
        if (replace) |i| {
            _ = cio.unlink(@ptrCast(&self.worst.items[i].path));
            self.worst.items[i] = entry;
        } else try self.worst.append(self.gpa, entry);
    }

    fn writePpm(self: *Eval, path: [:0]const u8) !void {
        const w = self.extent.width * 2;
        const h = self.extent.height;
        const f = cio.fopen(path, "wb") orelse return error.CannotWriteHeatMap;
        defer _ = cio.fclose(f);
        _ = cio.fprintf(f, "P6\n%u %u\n255\n", w, h);
        const px = @as([*]const u32, @ptrCast(@alignCast(self.heat_pixels.mapped.?)))[0 .. @as(usize, w) * h];
        var row: [8192 * 3]u8 = undefined;
        for (0..h) |y| {
            for (px[y * w ..][0..w], 0..) |p, x| {
                row[x * 3 + 0] = @truncate(p);
                row[x * 3 + 1] = @truncate(p >> 8);
                row[x * 3 + 2] = @truncate(p >> 16);
            }
            _ = cio.fwrite(&row, 1, @as(usize, w) * 3, f);
        }
    }

    fn sumsSlice(self: *Eval) []f32 {
        return @as([*]f32, @ptrCast(@alignCast(self.sums.mapped.?)))[0 .. self.opts.step * 4];
    }

    const DrawSpec = struct {
        frame: *const media.Frame,
        next: ?*const media.Frame = null,
        alpha: f32 = 0,
        interpolation: Renderer.Interpolation = .off,
    };

    const After = union(enum) {
        none,
        /// Score synthesized frame k (metric pass into the sums buffer).
        metric: struct { k: u32, t: f32 },
        /// Write the heat map of `truth` vs. `ours`.
        heat,
    };

    /// Renders one video draw into `into` through the real renderer, then records `after`
    /// in the same submission.
    fn render(self: *Eval, spec: DrawSpec, into: Image, after: After) !void {
        const vd: Renderer.VideoDraw = .{
            .frame = spec.frame,
            .dst = .{ -1, -1, 1, 1 },
            .output_hdr = 0,
            .white_scale = 1,
            .next = spec.next,
            .alpha = spec.alpha,
            .interpolation = spec.interpolation,
        };
        var d = frame.Draw.init(@intFromEnum(Renderer.Program.video), [_]u32{0});
        d.data = std.mem.asBytes(&vd);
        d.vertex_count = 6;
        const w: f32 = @floatFromInt(self.extent.width);
        const h: f32 = @floatFromInt(self.extent.height);
        const views = [_]frame.View{.{
            .viewport = .{ .x = 0, .y = 0, .width = w, .height = h },
            .scissor = .{ .width = self.extent.width, .height = self.extent.height },
            .draw = d,
        }};
        const rec = self.renderer.recorder();
        const f = while (true) {
            if (try self.ring.begin(try self.device.completedValue())) |f| break f;
            try self.device.waitValue((try self.device.completedValue()) + 1);
        };
        const cmd = f.commands(self.device);
        try rec.begin_frame(rec.ctx, cmd);
        // Earlier submissions may still read this image (metric pass) or write it.
        barrier(cmd, .{ .all_commands = true }, .{ .memory_read = true, .memory_write = true }, .{ .color_attachment_output = true }, .{ .color_attachment_write = true });
        const target = self.images.getPtr(into);
        try rec.record(rec.ctx, cmd, &f.upload, .{ .view = target.view, .extent = self.extent, .format = target.format }, &views);
        if (after == .heat) {
            barrier(cmd, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .compute_shader = true }, .{ .shader_sampled_read = true });
            self.renderer.shaders.bindCompute(cmd, self.heat);
            const push: HeatPush = .{ .out_pixels = self.heat_pixels.address, .truth = @intFromEnum(self.slots.get(.truth)), .ours = @intFromEnum(self.slots.get(.ours)) };
            cmd.pushDataEXT(&.{ .offset = 0, .data = .{ .address = &push, .size = @sizeOf(HeatPush) } });
            cmd.dispatch((self.extent.width + 15) / 16, (self.extent.height + 15) / 16, 1);
            barrier(cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .host = true }, .{ .host_read = true });
        }
        if (after == .metric) {
            const m = after.metric;
            barrier(cmd, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .compute_shader = true }, .{ .shader_sampled_read = true });
            self.renderer.shaders.bindCompute(cmd, self.metric);
            const push: MetricPush = .{
                .out_sums = self.sums.address + @as(u64, m.k) * 4 * @sizeOf(f32),
                .truth = @intFromEnum(self.slots.get(.truth)),
                .a = @intFromEnum(self.slots.get(.a)),
                .b = @intFromEnum(self.slots.get(.b)),
                .ours = @intFromEnum(self.slots.get(.ours)),
                .t = m.t,
            };
            cmd.pushDataEXT(&.{ .offset = 0, .data = .{ .address = &push, .size = @sizeOf(MetricPush) } });
            cmd.dispatch((self.extent.width + 15) / 16, (self.extent.height + 15) / 16, 1);
            barrier(cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .host = true }, .{ .host_read = true });
        }
        var sync: vk_core.FrameRing.Sync = .{};
        try rec.end_frame(rec.ctx, &sync);
        _ = try self.ring.submit(f, &sync);
        rec.submitted(rec.ctx);
    }
};

fn barrier(cmd: vk.CommandBufferProxy, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2) void {
    const b = [_]vk.MemoryBarrier2{.{ .src_stage_mask = src_stage, .src_access_mask = src_access, .dst_stage_mask = dst_stage, .dst_access_mask = dst_access }};
    cmd.pipelineBarrier2(&.{ .memory_barrier_count = b.len, .p_memory_barriers = &b });
}
