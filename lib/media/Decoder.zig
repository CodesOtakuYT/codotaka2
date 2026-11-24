//! Demux + Vulkan Video decode with FFmpeg, running as an `Io.concurrent` task that feeds
//! decoded frames (VkImages on our device) into a bounded `Io.Queue`. The queue gives
//! backpressure; an eventfd wakes the presenting thread when frames arrive.
const Decoder = @This();

const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;
const vk = @import("vulkan");
const c = @import("av_c");
const HwDevice = @import("HwDevice.zig");
const Frame = @import("Frame.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.media);

pub const queue_depth = 6;

pub const Options = struct {
    /// Seek back to the start at end of stream.
    loop: bool = true,
};

gpa: Allocator,
io: Io,
hw: *HwDevice,
fmt: *c.AVFormatContext,
codec: *c.AVCodecContext,
stream: *c.AVStream,
opts: Options,

queue: Io.Queue(Frame),
queue_buf: [queue_depth]Frame = undefined,
task: ?Io.Future(anyerror!void) = null,
wake_fd: linux.fd_t,

pub fn open(gpa: Allocator, io: Io, hw: *HwDevice, path: [:0]const u8, opts: Options) !*Decoder {
    var fmt: ?*c.AVFormatContext = null;
    try HwDevice.check(c.avformat_open_input(&fmt, path.ptr, null, null), "avformat_open_input");
    errdefer c.avformat_close_input(&fmt);
    try HwDevice.check(c.avformat_find_stream_info(fmt, null), "avformat_find_stream_info");

    var default_codec: ?*const c.AVCodec = null;
    const index = c.av_find_best_stream(fmt, c.AVMEDIA_TYPE_VIDEO, -1, -1, &default_codec, 0);
    try HwDevice.check(index, "av_find_best_stream");
    const stream: *c.AVStream = fmt.?.*.streams[@intCast(index)];
    // The default decoder may be software-only (e.g. libdav1d for AV1); use one that can
    // decode through Vulkan.
    const codec_info = vulkanDecoder(stream.codecpar.*.codec_id) orelse {
        log.err("no Vulkan-capable decoder for {s}", .{c.avcodec_get_name(stream.codecpar.*.codec_id)});
        return error.NoVulkanDecoder;
    };

    var codec = c.avcodec_alloc_context3(codec_info) orelse return error.OutOfMemory;
    errdefer c.avcodec_free_context(@ptrCast(&codec));
    try HwDevice.check(c.avcodec_parameters_to_context(codec, stream.codecpar), "avcodec_parameters_to_context");
    codec.*.hw_device_ctx = c.av_buffer_ref(hw.ref);
    codec.*.get_format = getFormat;
    codec.*.pkt_timebase = stream.time_base;

    const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(efd_rc) != .SUCCESS) return error.EventfdFailed;
    const wake_fd: linux.fd_t = @intCast(efd_rc);
    errdefer _ = linux.close(wake_fd);

    const self = try gpa.create(Decoder);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .hw = hw,
        .fmt = fmt.?,
        .codec = codec,
        .stream = stream,
        .opts = opts,
        .queue = undefined,
        .wake_fd = wake_fd,
    };
    self.queue = .init(&self.queue_buf);
    codec.*.@"opaque" = self;
    try HwDevice.check(c.avcodec_open2(codec, codec_info, null), "avcodec_open2");

    const par = stream.codecpar.*;
    log.info("{s}: {s} {d}x{d} {s}, {d:.3} fps", .{
        std.fs.path.basename(path),
        c.avcodec_get_name(par.codec_id),
        par.width,
        par.height,
        pixFmtName(par.format),
        c.av_q2d(stream.avg_frame_rate),
    });
    return self;
}

/// Starts decoding on its own concurrent task.
pub fn start(self: *Decoder) !void {
    self.task = try self.io.concurrent(run, .{self});
}

pub fn close(self: *Decoder) void {
    if (self.task) |*t| {
        self.queue.close(self.io);
        _ = t.cancel(self.io) catch {};
    }
    var buf: [queue_depth]Frame = undefined;
    while (true) {
        const n = self.queue.getUncancelable(self.io, &buf, 0) catch break;
        if (n == 0) break;
        for (buf[0..n]) |*f| f.release();
    }
    c.avcodec_free_context(@ptrCast(&self.codec));
    var fmt: ?*c.AVFormatContext = self.fmt;
    c.avformat_close_input(&fmt);
    _ = linux.close(self.wake_fd);
    self.gpa.destroy(self);
}

/// Non-blocking: moves up to `out.len` decoded frames out of the queue.
pub fn poll(self: *Decoder, out: []Frame) usize {
    var v: u64 = 0;
    _ = linux.read(self.wake_fd, std.mem.asBytes(&v).ptr, @sizeOf(u64));
    return self.queue.getUncancelable(self.io, out, 0) catch 0;
}

/// Readable when frames were queued (for the event loop).
pub fn eventFd(self: *const Decoder) linux.fd_t {
    return self.wake_fd;
}

fn run(self: *Decoder) anyerror!void {
    const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer {
        var p: ?*c.AVPacket = pkt;
        c.av_packet_free(&p);
    }
    const frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer {
        var f: ?*c.AVFrame = frame;
        c.av_frame_free(&f);
    }

    var loop_offset_ns: i64 = 0;
    var last_pts_ns: i64 = 0;
    while (true) {
        const rc = c.av_read_frame(self.fmt, pkt);
        if (rc == c.AVERROR_EOF) {
            try HwDevice.check(c.avcodec_send_packet(self.codec, null), "avcodec_send_packet(flush)");
            try self.drain(frame, loop_offset_ns, &last_pts_ns);
            if (!self.opts.loop) break;
            // Restart seamlessly: keep timestamps increasing across loops.
            loop_offset_ns = last_pts_ns + self.frameDurationNs();
            try HwDevice.check(c.av_seek_frame(self.fmt, self.stream.index, 0, c.AVSEEK_FLAG_BACKWARD), "av_seek_frame");
            c.avcodec_flush_buffers(self.codec);
            continue;
        }
        try HwDevice.check(rc, "av_read_frame");
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index != self.stream.index) continue;
        try HwDevice.check(c.avcodec_send_packet(self.codec, pkt), "avcodec_send_packet");
        try self.drain(frame, loop_offset_ns, &last_pts_ns);
    }
    self.queue.close(self.io);
}

fn drain(self: *Decoder, frame: *c.AVFrame, offset_ns: i64, last_pts_ns: *i64) !void {
    while (true) {
        const rc = c.avcodec_receive_frame(self.codec, frame);
        if (rc == c.AVERROR(c.EAGAIN) or rc == c.AVERROR_EOF) return;
        try HwDevice.check(rc, "avcodec_receive_frame");
        if (frame.format != c.AV_PIX_FMT_VULKAN) {
            c.av_frame_unref(frame);
            log.err("decoder produced a software frame; Vulkan decode unavailable for this stream", .{});
            return error.NotHardwareDecoded;
        }
        const owned = c.av_frame_alloc() orelse return error.OutOfMemory;
        c.av_frame_move_ref(owned, frame);
        const pts = if (owned.*.best_effort_timestamp != c.AV_NOPTS_VALUE) owned.*.best_effort_timestamp else owned.*.pts;
        const pts_ns = offset_ns + self.toNs(pts);
        last_pts_ns.* = pts_ns;
        var f: Frame = .{ .av = owned, .pts_ns = pts_ns, .duration_ns = self.frameDurationNs() };
        self.queue.putOne(self.io, f) catch |err| {
            f.release();
            return err; // Canceled or Closed: shutting down
        };
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
    }
}

fn toNs(self: *const Decoder, ts: i64) i64 {
    const tb = self.stream.time_base;
    return c.av_rescale_q(ts, tb, .{ .num = 1, .den = 1_000_000_000 });
}

pub fn frameDurationNs(self: *const Decoder) i64 {
    const r = self.stream.avg_frame_rate;
    if (r.num <= 0 or r.den <= 0) return std.time.ns_per_s / 30;
    return @divFloor(@as(i64, r.den) * std.time.ns_per_s, r.num);
}

/// Picks Vulkan output and creates the frames context ourselves, so decoded images can be
/// viewed per plane (MUTABLE_FORMAT + EXTENDED_USAGE) and sampled from descriptor heaps.
fn getFormat(ctx: [*c]c.AVCodecContext, formats: [*c]const c.AVPixelFormat) callconv(.c) c.AVPixelFormat {
    var i: usize = 0;
    while (formats[i] != c.AV_PIX_FMT_NONE) : (i += 1) {
        if (formats[i] != c.AV_PIX_FMT_VULKAN) continue;
        var frames_ref: ?*c.AVBufferRef = null;
        if (c.avcodec_get_hw_frames_parameters(ctx, ctx.*.hw_device_ctx, c.AV_PIX_FMT_VULKAN, &frames_ref) < 0) break;
        const fc: *c.AVHWFramesContext = @ptrCast(@alignCast(frames_ref.?.*.data));
        const vkfc: *c.AVVulkanFramesContext = @ptrCast(@alignCast(fc.hwctx));
        // Exactly the flags the decode-output format properties allow (FFmpeg's default
        // ALIAS_BIT is not among them on all drivers).
        vkfc.img_flags |= c.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT | c.VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;
        vkfc.usage |= c.VK_IMAGE_USAGE_SAMPLED_BIT;
        if (c.av_hwframe_ctx_init(frames_ref) < 0) {
            c.av_buffer_unref(&frames_ref);
            break;
        }
        ctx.*.hw_frames_ctx = frames_ref;
        log.info("Vulkan Video decode: {s} -> {s}, pool {d}x{d}", .{
            pixFmtName(fc.sw_format),
            @tagName(@as(vk.Format, @enumFromInt(vkfc.format[0]))),
            fc.width,
            fc.height,
        });
        return c.AV_PIX_FMT_VULKAN;
    }
    log.err("Vulkan decode not offered for this stream", .{});
    return c.AV_PIX_FMT_NONE;
}

fn pixFmtName(fmt: c_int) []const u8 {
    const name: [*c]const u8 = c.av_get_pix_fmt_name(fmt);
    return if (name == null) "?" else std.mem.span(name);
}

fn supportsVulkan(codec: *const c.AVCodec) bool {
    var i: c_int = 0;
    while (c.avcodec_get_hw_config(codec, i)) |cfg| : (i += 1) {
        if (cfg.*.device_type == c.AV_HWDEVICE_TYPE_VULKAN and cfg.*.methods & c.AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX != 0) return true;
    }
    return false;
}

/// A decoder for `id` that supports Vulkan hardware decoding.
fn vulkanDecoder(id: c.AVCodecID) ?*const c.AVCodec {
    var it: ?*anyopaque = null;
    while (c.av_codec_iterate(&it)) |codec| {
        if (codec.*.id == id and c.av_codec_is_decoder(codec) != 0 and supportsVulkan(codec)) return codec;
    }
    return null;
}
