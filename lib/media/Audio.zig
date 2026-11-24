//! Audio output and the master clock.
//!
//! The decode task writes f32 interleaved samples into a lock-free SPSC ring; PipeWire's
//! realtime thread reads them and publishes, through a seqlock, which media timestamp will
//! be *heard* at which CLOCK_MONOTONIC time (output latency included). Video asks the clock
//! for the media time at its predicted presentation time, so A/V sync accounts for both
//! the audio path latency and the display pipeline.
const std = @import("std");
const c = @import("pw_c");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.audio);

pub const rate = 48000;
pub const channels = 2;

/// Single-producer single-consumer ring of interleaved frames.
pub const Ring = struct {
    samples: []f32,
    capacity: u64, // frames, power of two
    write_pos: std.atomic.Value(u64) = .init(0),
    read_pos: std.atomic.Value(u64) = .init(0),
    /// Media timestamp of frame 0 (set once by the producer before the first write).
    base_pts_ns: std.atomic.Value(i64) = .init(0),
    has_base: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, seconds: u32) !Ring {
        const frames = std.math.ceilPowerOfTwoAssert(u64, @as(u64, rate) * seconds);
        return .{ .samples = try gpa.alloc(f32, frames * channels), .capacity = frames };
    }

    pub fn deinit(self: *Ring, gpa: Allocator) void {
        gpa.free(self.samples);
    }

    pub fn setBase(self: *Ring, pts_ns: i64) void {
        if (self.has_base.load(.acquire)) return;
        self.base_pts_ns.store(pts_ns, .monotonic);
        self.has_base.store(true, .release);
    }

    /// Producer: writes as many whole frames as fit; returns frames written.
    pub fn write(self: *Ring, interleaved: []const f32) usize {
        const w = self.write_pos.load(.monotonic);
        const r = self.read_pos.load(.acquire);
        const free = self.capacity - (w - r);
        const n: u64 = @min(free, interleaved.len / channels);
        for (0..n) |i| {
            const slot = ((w + i) & (self.capacity - 1)) * channels;
            @memcpy(self.samples[slot..][0..channels], interleaved[i * channels ..][0..channels]);
        }
        self.write_pos.store(w + n, .release);
        return @intCast(n);
    }

    /// Consumer: reads up to out.len / channels frames; returns (first frame index, count).
    pub fn read(self: *Ring, out: []f32) struct { first: u64, frames: usize } {
        const r = self.read_pos.load(.monotonic);
        const w = self.write_pos.load(.acquire);
        const n: u64 = @min(w - r, out.len / channels);
        for (0..n) |i| {
            const slot = ((r + i) & (self.capacity - 1)) * channels;
            @memcpy(out[i * channels ..][0..channels], self.samples[slot..][0..channels]);
        }
        self.read_pos.store(r + n, .release);
        return .{ .first = r, .frames = @intCast(n) };
    }

    pub fn buffered(self: *const Ring) u64 {
        return self.write_pos.load(.acquire) - self.read_pos.load(.acquire);
    }
};

/// "Media time `pts_ns` is heard at monotonic time `heard_ns`", published by the realtime
/// thread with a seqlock (no locks, no torn reads).
pub const Clock = struct {
    seq: std.atomic.Value(u32) = .init(0),
    heard_ns: std.atomic.Value(i64) = .init(0),
    pts_ns: std.atomic.Value(i64) = .init(0),

    fn publish(self: *Clock, heard_ns: i64, pts_ns: i64) void {
        const s = self.seq.load(.monotonic);
        self.seq.store(s +% 1, .monotonic); // odd: writing
        self.heard_ns.store(heard_ns, .release);
        self.pts_ns.store(pts_ns, .release);
        self.seq.store(s +% 2, .release);
    }

    pub const Sample = struct { heard_ns: i64, pts_ns: i64 };

    pub fn read(self: *const Clock) ?Sample {
        while (true) {
            const s1 = self.seq.load(.acquire);
            if (s1 == 0) return null; // never published
            if (s1 & 1 != 0) continue;
            const sample: Sample = .{ .heard_ns = self.heard_ns.load(.acquire), .pts_ns = self.pts_ns.load(.acquire) };
            if (self.seq.load(.acquire) == s1) return sample;
        }
    }

    /// Media time heard at monotonic time `t`.
    pub fn mediaTimeAt(sample: Sample, t: i128) i128 {
        return sample.pts_ns + (t - sample.heard_ns);
    }
};

/// A PipeWire playback stream draining a `Ring`.
pub const Output = struct {
    gpa: Allocator,
    ring: *Ring,
    clock: Clock = .{},
    stream: ?*c.cdk_audio = null,
    underruns: std.atomic.Value(u64) = .init(0),
    /// Output latency (heard time - now) of the latest callback, for diagnostics.
    latency_ns: std.atomic.Value(i64) = .init(0),
    active: bool = true,

    pub fn create(gpa: Allocator, ring: *Ring, name: [:0]const u8) !*Output {
        const self = try gpa.create(Output);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ring = ring };
        self.stream = c.cdk_audio_open(name.ptr, rate, channels, fill, self) orelse return error.PipeWireStream;
        log.info("PipeWire stream: f32 {d} Hz, {d} channels", .{ rate, channels });
        return self;
    }

    /// Stops the realtime thread before anything it reads goes away.
    pub fn destroy(self: *Output) void {
        c.cdk_audio_close(self.stream);
        log.info("output latency {d:.1} ms, {d} underruns", .{
            @as(f64, @floatFromInt(self.latency_ns.load(.monotonic))) / 1e6,
            self.underruns.load(.monotonic),
        });
        self.gpa.destroy(self);
    }

    pub fn setActive(self: *Output, active: bool) void {
        self.active = active;
        c.cdk_audio_set_active(self.stream, active);
    }

    /// Realtime thread: no locks, no allocation.
    fn fill(user: ?*anyopaque, out: [*c]f32, frames: u32, heard_at_ns: i64) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(user));
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        self.latency_ns.store(heard_at_ns - (@as(i64, ts.sec) * std.time.ns_per_s + ts.nsec), .monotonic);
        const dst = out[0 .. @as(usize, frames) * channels];
        const got = self.ring.read(dst);
        @memset(dst[got.frames * channels ..], 0);
        if (got.frames < frames) _ = self.underruns.fetchAdd(1, .monotonic);
        if (got.frames > 0 and self.ring.has_base.load(.acquire)) {
            const pts = self.ring.base_pts_ns.load(.monotonic) + @as(i64, @intCast(@divFloor(got.first * std.time.ns_per_s, rate)));
            self.clock.publish(heard_at_ns, pts);
        }
    }
};
