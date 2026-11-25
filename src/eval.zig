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
    };
    defer ev.deinit();
    try ev.run();
}

const Image = enum { truth, a, b, ours };

const Eval = struct {
    gpa: Allocator,
    io: Io,
    device: *vk_core.Device,
    renderer: *Renderer,
    ring: *vk_core.FrameRing,
    decoder: *media.Decoder,
    opts: Options,
    metric: vk_core.ShaderCache.ComputeId,
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
        log.info("evaluating {s}: every {d}th frame kept, {d} intervals at {d}x{d}", .{ self.opts.path, step, self.opts.intervals, self.extent.width, self.extent.height });

        var interval: u32 = 0;
        while (interval < self.opts.intervals) : (interval += 1) {
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
        try self.render(.{ .frame = a, .next = b, .alpha = 0, .interpolation = .on }, .ours, null);
        try self.render(.{ .frame = a }, .a, null);
        try self.render(.{ .frame = b }, .b, null);
        for (1..step) |k| {
            const t: f32 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(step));
            try self.render(.{ .frame = &self.held.items[k] }, .truth, null);
            try self.render(.{ .frame = a, .next = b, .alpha = t, .interpolation = .on }, .ours, .{ .k = @intCast(k), .t = t });
        }
        // One wait per interval, then 4 floats per synthesized frame.
        try self.device.waitValue(self.device.lastValue());
        try self.device.proxy.invalidateMappedMemoryRanges(&.{.{ .memory = self.sums.memory, .offset = 0, .size = vk.WHOLE_SIZE }});
        const pixels: f64 = @floatFromInt(@as(u64, self.extent.width) * self.extent.height * 3);
        const sums = self.sumsSlice();
        if (toDb(sums[4 * 1 + 3] / pixels) < cut_db) {
            self.cuts += 1;
            return;
        }
        for (1..step) |k| {
            const s = sums[4 * k ..][0..4];
            if (s[0] <= 0) self.static_frames += 1;
            self.scores.getPtr(.nearest).add(s[0] / pixels);
            self.scores.getPtr(.crossfade).add(s[1] / pixels);
            self.scores.getPtr(.interpolated).add(s[2] / pixels);
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

    const Measure = struct { k: u32, t: f32 };

    /// Renders one video draw into `into` through the real renderer; with `measure`, also
    /// records the metric pass for synthesized frame k (in the same submission).
    fn render(self: *Eval, spec: DrawSpec, into: Image, measure: ?Measure) !void {
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
        if (measure) |m| {
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
