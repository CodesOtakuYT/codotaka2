//! Video player window: Vulkan Video decode (FFmpeg) on our device, frames sampled straight
//! from the decoder's images, presented through dmabuf + explicit sync. The video is scene
//! content, so it is damage-driven: only frames that change are rendered.
const std = @import("std");
const wl = @import("wl");
const scene = @import("scene");
const frame = @import("frame");
const csd = @import("csd");
const text = @import("text");
const media = @import("media");
const vk_present = @import("vk_present");
const Renderer = @import("Renderer.zig");
const Program = Renderer.Program;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.player);

pub const Scene = scene.Scene(vk_present.SurfaceTarget);
const Decoration = csd.Decoration(Scene);

pub const Stats = struct {
    shown: u64 = 0,
    dropped: u64 = 0,
    /// A/V error of shown frames against the audio clock at their predicted presentation.
    sync_samples: u64 = 0,
    sync_abs_sum_ns: i128 = 0,
    sync_max_abs_ns: i128 = 0,

    fn addSync(s: *Stats, err_ns: i128) void {
        const a: i128 = @intCast(@abs(err_ns));
        s.sync_samples += 1;
        s.sync_abs_sum_ns += a;
        s.sync_max_abs_ns = @max(s.sync_max_abs_ns, a);
    }
};

const lookahead = 2;

/// Picks the decoded frame for each predicted presentation time.
const VideoView = struct {
    gpa: Allocator,
    decoder: *media.Decoder,
    /// Master clock when the stream has audio.
    audio: ?*media.Audio.Output = null,
    pending: std.ArrayList(media.Frame) = .empty,
    current: ?media.Frame = null,
    /// Monotonic time at which pts 0 is presented (set from the first frame).
    anchor_ns: ?i128 = null,
    paused_at: ?i128 = null,
    /// Audio clock samples published before this (stale, from before a pause) are ignored.
    clock_valid_after: i128 = 0,
    stats: Stats = .{},
    dirty: bool = false,

    fn deinit(self: *VideoView) void {
        for (self.pending.items) |*f| f.release();
        self.pending.deinit(self.gpa);
        if (self.current) |*f| f.release();
    }

    fn content(self: *VideoView) scene.Content {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };

    fn togglePause(self: *VideoView, now_ns: i128) void {
        if (self.paused_at) |p| {
            if (self.anchor_ns) |*a| a.* += now_ns - p; // resume where we stopped
            self.paused_at = null;
            self.clock_valid_after = now_ns;
        } else self.paused_at = now_ns;
        if (self.audio) |a| a.setActive(self.paused_at == null);
    }

    /// Media time presented at monotonic time `t`: from the audio clock (which already
    /// includes the audio output latency) when available, else from the local anchor.
    /// Null while the audio clock has no fresh sample (startup, right after resume): the
    /// current frame is held instead of extrapolating a stale clock across the pause.
    fn mediaTimeAt(self: *VideoView, t: i128) ?i128 {
        if (self.audio) |a| {
            const sample = a.clock.read() orelse return null;
            if (sample.heard_ns < self.clock_valid_after) return null;
            return media.Audio.Clock.mediaTimeAt(sample, t);
        }
        return if (self.anchor_ns) |anchor| t - anchor else null;
    }

    fn update(ptr: *anyopaque, ft: scene.FrameTime) scene.Update {
        const self: *VideoView = @ptrCast(@alignCast(ptr));
        // Take only the next few frames; the rest stay in the decoder's bounded queue,
        // which is what blocks the decoder (backpressure) instead of it racing ahead.
        if (self.pending.items.len < lookahead) {
            var buf: [lookahead]media.Frame = undefined;
            const n = self.decoder.poll(buf[0 .. lookahead - self.pending.items.len]);
            self.pending.appendSlice(self.gpa, buf[0..n]) catch for (buf[0..n]) |*f| f.release();
        }
        if (self.paused_at != null or self.pending.items.len == 0) {
            defer self.dirty = false;
            return .{ .dirty = self.dirty };
        }

        if (self.anchor_ns == null) self.anchor_ns = ft.target_ns - self.pending.items[0].pts_ns;
        const media_time = self.mediaTimeAt(ft.target_ns) orelse {
            // No usable clock yet: show the first frame so the window isn't empty, then
            // hold until audio publishes a fresh clock sample (within one audio quantum).
            if (self.current == null) {
                self.current = self.pending.items[0];
                _ = self.pending.orderedRemove(0);
                return .{ .dirty = true, .next_wake_ns = ft.now_ns + std.time.ns_per_ms * 5 };
            }
            return .{ .dirty = false, .next_wake_ns = ft.now_ns + std.time.ns_per_ms * 5 };
        };
        // Newest frame due by the predicted presentation time; older ones are dropped.
        var pick: ?usize = null;
        for (self.pending.items, 0..) |f, i| {
            if (f.pts_ns <= media_time + @divFloor(@as(i128, ft.refresh_ns), 2)) pick = i;
        }
        var dirty = self.dirty;
        self.dirty = false;
        if (pick) |p| {
            for (self.pending.items[0..p]) |*f| f.release();
            self.stats.dropped += p;
            if (self.current) |*old| old.release();
            self.current = self.pending.items[p];
            self.pending.replaceRange(self.gpa, 0, p + 1, &.{}) catch unreachable;
            self.stats.shown += 1;
            if (self.audio != null and ft.refresh_ns != 0) self.stats.addSync(self.current.?.pts_ns - media_time);
            dirty = true;
        }
        // Wake when the next frame becomes due at the predicted vsync (converted from media
        // time to monotonic time); if none is decoded yet, the decoder's eventfd wakes us.
        const next: ?i128 = if (self.pending.items.len > 0) blk: {
            const due_media = self.pending.items[0].pts_ns - @divFloor(@as(i128, ft.refresh_ns), 2);
            break :blk ft.wakeToPresentAt(ft.target_ns + (due_media - media_time));
        } else null;
        return .{ .dirty = dirty, .next_wake_ns = next };
    }

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext, out: *frame.DrawList) !void {
        const self: *VideoView = @ptrCast(@alignCast(ptr));
        const f = if (self.current) |*cur| cur else return;
        // Letterbox: fit the frame's aspect inside the viewport.
        const fw: f32 = @floatFromInt(f.width());
        const fh: f32 = @floatFromInt(f.height());
        const scale = @min(ctx.size_px[0] / fw, ctx.size_px[1] / fh);
        const w = fw * scale / ctx.size_px[0];
        const h = fh * scale / ctx.size_px[1];
        const vd = try out.arena.create(Renderer.VideoDraw);
        vd.* = .{
            .frame = f,
            .dst = .{ -w, -h, w, h },
            .output_hdr = @intFromBool(ctx.color == .hdr_scrgb),
            .white_scale = ctx.white_scale,
        };
        var d = frame.Draw.init(@intFromEnum(Program.video), [_]u32{0});
        d.data = std.mem.asBytes(vd);
        d.vertex_count = 6;
        try out.add(d);
    }
};

pub const Window = struct {
    gpa: Allocator,
    sw: *Scene.SceneWindow,
    decoration: *Decoration,
    video: VideoView,
    video_node: ?Scene.NodeId = null,
    video_view: ?Scene.ViewportId = null,

    pub fn create(gpa: Allocator, fonts: *text.FontSystem, decoder: *media.Decoder, title: []const u8, sw_create: anytype) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const decoration = try Decoration.create(gpa, .{
            .decoration = @intFromEnum(Program.decoration),
            .text = @intFromEnum(Program.text),
        }, fonts, title);
        errdefer decoration.destroy();
        self.* = .{ .gpa = gpa, .sw = undefined, .decoration = decoration, .video = .{ .gpa = gpa, .decoder = decoder } };
        if (decoder.audioRing()) |ring| self.video.audio = media.Audio.Output.create(gpa, ring, "codotaka") catch |err| blk: {
            log.warn("no audio output: {t}", .{err});
            break :blk null;
        };
        errdefer self.stopAudio();
        self.sw = try sw_create.call(.{ .ctx = self, .layout = layout, .pointer = pointer, .key = key });
        decoration.attach(self.sw);
        return self;
    }

    /// Stops the realtime audio thread (it reads the decoder's ring).
    pub fn stopAudio(self: *Window) void {
        if (self.video.audio) |a| a.destroy();
        self.video.audio = null;
    }

    pub fn destroy(self: *Window) void {
        self.stopAudio();
        self.decoration.destroy();
        self.sw.destroy();
        self.video.deinit();
        self.gpa.destroy(self);
    }

    /// Whether the view is waiting for decoded frames (then the decoder's eventfd should
    /// wake the loop; otherwise it stays readable while frames sit in the queue).
    pub fn wantsFrames(self: *const Window) bool {
        return self.video.paused_at == null and self.video.pending.items.len < lookahead;
    }

    pub fn stats(self: *const Window) Stats {
        return self.video.stats;
    }

    fn layout(ctx: *anyopaque, sw: *Scene.SceneWindow) !void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        const area = try self.decoration.layout();
        // The video gets its own subsurface: an overlay-plane candidate, and the only
        // surface that re-renders during playback.
        if (self.video_node == null) self.video_node = try sw.addNode("video", sw.root);
        if (self.video_view == null) self.video_view = try sw.addViewport(self.video.content());
        const rect: scene.LogicalRect = .{ .y = area.y, .width = area.width, .height = area.height };
        sw.setNodeRect(self.video_node.?, rect);
        sw.resetViewport(self.video_view.?, area.width, area.height);
        try sw.place(self.video_view.?, .{ .node = self.video_node.?, .region = .{ .width = area.width, .height = area.height } });
    }

    fn pointer(ctx: *anyopaque, _: *Scene.SceneWindow, ev: wl.PointerEvent) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        _ = self.decoration.pointer(ev);
    }

    fn key(ctx: *anyopaque, sw: *Scene.SceneWindow, ev: wl.KeyEvent) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (ev.kind != .press) return;
        switch (ev.keysym) {
            wl.keysym.q, wl.keysym.Escape => sw.window.close(),
            wl.keysym.f => sw.window.toggleFullscreen(),
            wl.keysym.space => {
                self.video.togglePause(wl.Display.monotonicNs());
                log.info("{s}", .{if (self.video.paused_at != null) "paused" else "playing"});
            },
            else => {},
        }
    }

    pub fn syncFocus(_: *Window) void {}
};
