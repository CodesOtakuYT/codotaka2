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
const Audio = @import("Audio.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.media);

pub const queue_depth = 6;
/// Compressed video packets buffered between demuxing and decoding (cheap; seconds deep),
/// so a full frame queue never stops the demuxer from feeding audio.
pub const packet_depth = 512;

/// Demux -> video decode messages.
const VideoItem = union(enum) {
    packet: *c.AVPacket,
    /// End of stream: flush the decoder, then continue with timestamps offset by this
    /// (looping), or stop.
    end: ?i64,
};

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

audio: ?AudioTrack = null,

queue: Io.Queue(Frame),
queue_buf: [queue_depth]Frame = undefined,
packets: Io.Queue(VideoItem),
packets_buf: [packet_depth]VideoItem = undefined,
demux_task: ?Io.Future(anyerror!void) = null,
video_task: ?Io.Future(anyerror!void) = null,
wake_fd: linux.fd_t,

/// The stream's audio: software-decoded, resampled to f32 stereo at the output rate.
pub const AudioTrack = struct {
    stream: *c.AVStream,
    codec: *c.AVCodecContext,
    swr: *c.SwrContext,
    ring: Audio.Ring,
    scratch: []f32,
};

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
        .packets = undefined,
        .wake_fd = wake_fd,
    };
    self.queue = .init(&self.queue_buf);
    self.packets = .init(&self.packets_buf);
    codec.*.@"opaque" = self;
    try HwDevice.check(c.avcodec_open2(codec, codec_info, null), "avcodec_open2");
    self.audio = openAudio(gpa, self.fmt, index) catch |err| blk: {
        log.warn("audio disabled: {t}", .{err});
        break :blk null;
    };

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

/// Starts the demux (+ audio decode) and video decode tasks.
pub fn start(self: *Decoder) !void {
    self.video_task = try self.io.concurrent(videoLoop, .{self});
    self.demux_task = try self.io.concurrent(demuxLoop, .{self});
}

fn openAudio(gpa: Allocator, fmt: *c.AVFormatContext, video_index: c_int) !?AudioTrack {
    var dec: ?*const c.AVCodec = null;
    const index = c.av_find_best_stream(fmt, c.AVMEDIA_TYPE_AUDIO, -1, video_index, &dec, 0);
    if (index < 0) return null;
    const stream: *c.AVStream = fmt.streams[@intCast(index)];
    var codec = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
    errdefer c.avcodec_free_context(@ptrCast(&codec));
    try HwDevice.check(c.avcodec_parameters_to_context(codec, stream.codecpar), "avcodec_parameters_to_context(audio)");
    codec.*.pkt_timebase = stream.time_base;
    try HwDevice.check(c.avcodec_open2(codec, dec, null), "avcodec_open2(audio)");

    var out_layout: c.AVChannelLayout = undefined;
    c.av_channel_layout_default(&out_layout, Audio.channels);
    var swr: ?*c.SwrContext = null;
    try HwDevice.check(c.swr_alloc_set_opts2(&swr, &out_layout, c.AV_SAMPLE_FMT_FLT, Audio.rate, &codec.*.ch_layout, codec.*.sample_fmt, codec.*.sample_rate, 0, null), "swr_alloc_set_opts2");
    errdefer c.swr_free(&swr);
    try HwDevice.check(c.swr_init(swr), "swr_init");

    var ring = try Audio.Ring.init(gpa, 2);
    errdefer ring.deinit(gpa);
    const scratch = try gpa.alloc(f32, 16384 * Audio.channels);
    log.info("audio: {s} {d} Hz {d} ch -> f32 {d} Hz stereo", .{ c.avcodec_get_name(codec.*.codec_id), codec.*.sample_rate, codec.*.ch_layout.nb_channels, Audio.rate });
    return .{ .stream = stream, .codec = codec, .swr = swr.?, .ring = ring, .scratch = scratch };
}

/// The audio ring to drain (null if the stream has no usable audio).
pub fn audioRing(self: *Decoder) ?*Audio.Ring {
    return if (self.audio) |*a| &a.ring else null;
}

/// Stop the audio output (which reads the ring) before calling this.
pub fn close(self: *Decoder) void {
    self.queue.close(self.io);
    self.packets.close(self.io);
    if (self.demux_task) |*t| _ = t.cancel(self.io) catch {};
    if (self.video_task) |*t| _ = t.cancel(self.io) catch {};
    var buf: [queue_depth]Frame = undefined;
    while (true) {
        const n = self.queue.getUncancelable(self.io, &buf, 0) catch break;
        if (n == 0) break;
        for (buf[0..n]) |*f| f.release();
    }
    var items: [32]VideoItem = undefined;
    while (true) {
        const n = self.packets.getUncancelable(self.io, &items, 0) catch break;
        if (n == 0) break;
        for (items[0..n]) |it| if (it == .packet) {
            var p: ?*c.AVPacket = it.packet;
            c.av_packet_free(&p);
        };
    }
    c.avcodec_free_context(@ptrCast(&self.codec));
    if (self.audio) |*a| {
        c.avcodec_free_context(@ptrCast(&a.codec));
        var swr: ?*c.SwrContext = a.swr;
        c.swr_free(&swr);
        a.ring.deinit(self.gpa);
        self.gpa.free(a.scratch);
    }
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

/// Reads packets: audio is decoded here (into the ring), video packets are queued for
/// `videoLoop`. Loops the file by seeking back and offsetting timestamps.
fn demuxLoop(self: *Decoder) anyerror!void {
    defer self.packets.close(self.io);
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
    var video_end_ns: i64 = 0; // end of the latest video packet in this pass
    while (true) {
        const rc = c.av_read_frame(self.fmt, pkt);
        if (rc == c.AVERROR_EOF) {
            if (self.audio) |*a| {
                _ = c.avcodec_send_packet(a.codec, null);
                try self.drainAudio(a, frame, loop_offset_ns);
                c.avcodec_flush_buffers(a.codec);
            }
            if (!self.opts.loop) {
                try self.packets.putOne(self.io, .{ .end = null });
                return;
            }
            // Restart seamlessly: keep timestamps increasing across loops. (Audio keeps
            // counting samples, so its clock stays continuous too.)
            loop_offset_ns = video_end_ns;
            try self.packets.putOne(self.io, .{ .end = loop_offset_ns });
            try HwDevice.check(c.av_seek_frame(self.fmt, self.stream.index, 0, c.AVSEEK_FLAG_BACKWARD), "av_seek_frame");
            continue;
        }
        try HwDevice.check(rc, "av_read_frame");
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == self.stream.index) {
            if (pkt.*.pts != c.AV_NOPTS_VALUE)
                video_end_ns = @max(video_end_ns, loop_offset_ns + self.toNs(pkt.*.pts + pkt.*.duration));
            const owned = c.av_packet_clone(pkt) orelse return error.OutOfMemory;
            self.packets.putOne(self.io, .{ .packet = owned }) catch |err| {
                var p: ?*c.AVPacket = owned;
                c.av_packet_free(&p);
                return err;
            };
        } else if (self.audio) |*a| if (pkt.*.stream_index == a.stream.index) {
            if (c.avcodec_send_packet(a.codec, pkt) >= 0) try self.drainAudio(a, frame, loop_offset_ns);
        };
    }
}

/// Decodes queued video packets into the frame queue (Vulkan Video).
fn videoLoop(self: *Decoder) anyerror!void {
    defer self.queue.close(self.io);
    const frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer {
        var f: ?*c.AVFrame = frame;
        c.av_frame_free(&f);
    }
    var loop_offset_ns: i64 = 0;
    var last_pts_ns: i64 = 0;
    while (true) {
        const item = self.packets.getOne(self.io) catch |err| switch (err) {
            error.Closed => return,
            else => return err,
        };
        switch (item) {
            .packet => |pkt| {
                defer {
                    var p: ?*c.AVPacket = pkt;
                    c.av_packet_free(&p);
                }
                try HwDevice.check(c.avcodec_send_packet(self.codec, pkt), "avcodec_send_packet");
                try self.drain(frame, loop_offset_ns, &last_pts_ns);
            },
            .end => |next_offset| {
                try HwDevice.check(c.avcodec_send_packet(self.codec, null), "avcodec_send_packet(flush)");
                try self.drain(frame, loop_offset_ns, &last_pts_ns);
                const offset = next_offset orelse return;
                c.avcodec_flush_buffers(self.codec);
                loop_offset_ns = offset;
            },
        }
    }
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

/// Decodes, resamples and pushes audio into the ring, waiting (cancelably) while it is full.
fn drainAudio(self: *Decoder, a: *AudioTrack, frame: *c.AVFrame, offset_ns: i64) !void {
    while (true) {
        const rc = c.avcodec_receive_frame(a.codec, frame);
        if (rc == c.AVERROR(c.EAGAIN) or rc == c.AVERROR_EOF) return;
        if (rc < 0) return; // corrupt audio is skipped, video continues
        defer c.av_frame_unref(frame);
        if (frame.pts != c.AV_NOPTS_VALUE)
            a.ring.setBase(offset_ns + c.av_rescale_q(frame.pts, a.stream.time_base, .{ .num = 1, .den = 1_000_000_000 }));
        var out: [*c]u8 = @ptrCast(a.scratch.ptr);
        const max_frames: c_int = @intCast(a.scratch.len / Audio.channels);
        const n = c.swr_convert(a.swr, &out, max_frames, @ptrCast(frame.extended_data), frame.nb_samples);
        if (n <= 0) continue;
        var pending = a.scratch[0 .. @as(usize, @intCast(n)) * Audio.channels];
        while (pending.len > 0) {
            const written = a.ring.write(pending);
            pending = pending[written * Audio.channels ..];
            if (pending.len > 0) try self.io.sleep(.fromMilliseconds(5), .awake);
        }
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
