//! Offline quality evaluation of frame interpolation (no window, no compositor).
//!
//! Decodes a high-frame-rate video, keeps every `step`-th frame as the "low frame rate"
//! input and interpolates the frames in between with the real renderer (same shaders, same
//! optical flow path as the player). Each synthesized frame is compared with the real frame
//! that was dropped, next to two baselines: repeating the nearest frame (what a player does
//! without interpolation) and a plain crossfade. Scores are PSNR (dB) of gamma-encoded RGB,
//! averaged over all synthesized frames, plus the worst frame.
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
const cut_db = 18.0;

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

    var ev: Eval = .{ .gpa = gpa, .io = io, .device = device, .renderer = renderer, .ring = &ring, .decoder = decoder, .opts = opts };
    defer ev.deinit();
    try ev.run();
}

const Eval = struct {
    gpa: Allocator,
    io: Io,
    device: *vk_core.Device,
    renderer: *Renderer,
    ring: *vk_core.FrameRing,
    decoder: *media.Decoder,
    opts: Options,
    target: vk_core.Image = .{},
    /// CPU-cached copy of the target (filled by the GPU).
    readback: vk_core.Buffer = .{},
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    pixels: [4][]f16 = .{ &.{}, &.{}, &.{}, &.{} },
    held: std.ArrayList(media.Frame) = .empty,
    scores: std.EnumArray(Method, Score) = .initFill(.{}),
    cuts: u32 = 0,
    static_frames: u32 = 0,

    fn deinit(self: *Eval) void {
        for (self.held.items) |*f| f.release();
        self.held.deinit(self.gpa);
        for (self.pixels) |p| self.gpa.free(p);
        if (self.target.image != .null) self.target.deinit(self.device);
        if (self.readback.buffer != .null) self.readback.deinit(self.device);
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
            try self.io.sleep(.fromMilliseconds(2), .awake);
            idle_ms += 2;
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
        self.target = try vk_core.Image.create(self.device, .{
            .format = .r16g16b16a16_sfloat,
            .extent = self.extent,
            .usage = .{ .color_attachment = true, .transfer_src = true, .host_transfer = true },
        });
        try self.target.hostTransition(self.device, .undefined, .general);
        self.readback = try vk_core.Buffer.create(self.device, .{
            .size = @as(u64, w) * h * 8,
            .usage = .{ .transfer_dst = true },
            .readback = true,
        });
        for (&self.pixels) |*p| p.* = try self.gpa.alloc(f16, @as(usize, w) * h * 4);
    }

    fn evalInterval(self: *Eval) !void {
        const step = self.opts.step;
        const a = &self.held.items[0];
        const b = &self.held.items[step];
        // Estimate the pair's vectors (the first interpolated draw only queues them).
        try self.render(.{ .frame = a, .next = b, .alpha = 0, .interpolation = .on }, null);
        try self.render(.{ .frame = a }, self.pixels[1]);
        try self.render(.{ .frame = b }, self.pixels[2]);
        if (toDb(mse(self.pixels[1], self.pixels[2], null, 0)) < cut_db) {
            self.cuts += 1;
            return;
        }
        for (1..step) |k| {
            const t: f32 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(step));
            try self.render(.{ .frame = &self.held.items[k] }, self.pixels[0]);
            const truth = self.pixels[0];
            const near = mse(truth, if (t < 0.5) self.pixels[1] else self.pixels[2], null, 0);
            if (near <= 1e-12) self.static_frames += 1;
            self.scores.getPtr(.nearest).add(near);
            self.scores.getPtr(.crossfade).add(mse(truth, self.pixels[1], self.pixels[2], t));
            try self.render(.{ .frame = a, .next = b, .alpha = t, .interpolation = .on }, self.pixels[3]);
            self.scores.getPtr(.interpolated).add(mse(truth, self.pixels[3], null, 0));
            if (std.c.getenv("CODOTAKA_EVAL_DEBUG") != null) log.info("k={d} mean truth {d:.4} A {d:.4} B {d:.4} ours {d:.4} | psnr near {d:.2} ours {d:.2}", .{
                k, meanOf(truth), meanOf(self.pixels[1]), meanOf(self.pixels[2]), meanOf(self.pixels[3]),
                toDb(mse(truth, if (t < 0.5) self.pixels[1] else self.pixels[2], null, 0)), toDb(mse(truth, self.pixels[3], null, 0)),
            });
        }
    }

    const DrawSpec = struct {
        frame: *const media.Frame,
        next: ?*const media.Frame = null,
        alpha: f32 = 0,
        interpolation: Renderer.Interpolation = .off,
    };

    /// Renders one video draw into the target through the real renderer and, if `out` is
    /// given, reads it back.
    fn render(self: *Eval, spec: DrawSpec, out: ?[]f16) !void {
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
        const f = (try self.ring.begin(try self.device.completedValue())) orelse blk: {
            try self.device.waitValue(self.device.lastValue());
            break :blk (try self.ring.begin(try self.device.completedValue())).?;
        };
        const cmd = f.commands(self.device);
        try rec.begin_frame(rec.ctx, cmd);
        try rec.record(rec.ctx, cmd, &f.upload, .{ .view = self.target.view, .extent = self.extent, .format = self.target.format }, &views);
        if (out != null) {
            const b = [_]vk.MemoryBarrier2{.{
                .src_stage_mask = .{ .color_attachment_output = true },
                .src_access_mask = .{ .color_attachment_write = true },
                .dst_stage_mask = .{ .copy = true },
                .dst_access_mask = .{ .transfer_read = true },
            }};
            cmd.pipelineBarrier2(&.{ .memory_barrier_count = b.len, .p_memory_barriers = &b });
            cmd.copyImageToBuffer(self.target.image, .general, self.readback.buffer, &.{.{
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
            }});
            const to_host = [_]vk.MemoryBarrier2{.{
                .src_stage_mask = .{ .copy = true },
                .src_access_mask = .{ .transfer_write = true },
                .dst_stage_mask = .{ .host = true },
                .dst_access_mask = .{ .host_read = true },
            }};
            cmd.pipelineBarrier2(&.{ .memory_barrier_count = to_host.len, .p_memory_barriers = &to_host });
        }
        var sync: vk_core.FrameRing.Sync = .{};
        try rec.end_frame(rec.ctx, &sync);
        const value = try self.ring.submit(f, &sync);
        rec.submitted(rec.ctx);
        try self.device.waitValue(value);
        if (out) |pixels| {
            try self.device.proxy.invalidateMappedMemoryRanges(&.{.{ .memory = self.readback.memory, .offset = 0, .size = vk.WHOLE_SIZE }});
            @memcpy(std.mem.sliceAsBytes(pixels), self.readback.mapped.?[0 .. pixels.len * 2]);
        }
    }
};

/// Mean squared error of `test_a` (or of mix(test_a, test_b, t) when test_b is given)
/// against `truth`, over gamma-2.2-encoded RGB in [0, 1].
fn mse(truth: []const f16, test_a: []const f16, test_b: ?[]const f16, t: f32) f64 {
    var se: f64 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < truth.len) : (i += 4) {
        for (0..3) |c| {
            var v: f32 = test_a[i + c];
            if (test_b) |b| v = v * (1 - t) + @as(f32, b[i + c]) * t;
            const d = encode(truth[i + c]) - encode(v);
            se += d * d;
            n += 1;
        }
    }
    return se / @as(f64, @floatFromInt(n));
}

/// Gamma 2.2 encoding of every f16 value (bit pattern -> encoded), built once.
var encode_table: [65536]f32 = undefined;
var encode_table_ready = false;

fn encode(x: anytype) f64 {
    if (!encode_table_ready) {
        for (&encode_table, 0..) |*e, bits| {
            const v: f16 = @bitCast(@as(u16, @intCast(bits)));
            const f: f64 = @floatCast(v);
            e.* = if (std.math.isNan(f)) 0 else @floatCast(std.math.pow(f64, std.math.clamp(f, 0, 1), 1.0 / 2.2));
        }
        encode_table_ready = true;
    }
    const h: f16 = @floatCast(x);
    return encode_table[@as(u16, @bitCast(h))];
}

fn meanOf(px: []const f16) f64 {
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < px.len) : (i += 4) sum += @floatCast(px[i + 1]);
    return sum / @as(f64, @floatFromInt(px.len / 4));
}
