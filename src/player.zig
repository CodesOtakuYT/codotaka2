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

/// Decoded frames held ahead of the shown one (interpolation needs the next two).
const lookahead = 3;

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
    /// Waiting for the first frame after a seek.
    seeking: bool = false,
    /// First frame after a seek is up; buffering frames before audio restarts.
    prerolling: bool = false,
    /// Audio clock samples published before this (stale, from before a pause) are ignored.
    clock_valid_after: i128 = 0,
    /// After a seek, clock samples for media time before the new position are stale.
    clock_min_pts: i128 = std.math.minInt(i64),
    /// Generation of frames to show (the latest requested seek).
    generation: u32 = 0,
    /// Target of the in-flight seek (stream ns).
    seek_target: i64 = 0,
    stats: Stats = .{},
    dirty: bool = false,
    /// Motion-compensated interpolation (optical flow) between `current` and the next frame.
    interpolation: Renderer.Interpolation = .off,
    /// Position between `current` (0) and the next frame (1) at the predicted presentation.
    alpha: f32 = 0,
    /// Stable copy of the next frame for the renderer (owned by `pending`).
    next_view: media.Frame = undefined,
    after_view: media.Frame = undefined,

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
        self.syncAudioActive();
    }

    /// Audio runs only while playing and not pre-rolling a seek (audio is the clock, so
    /// it must not run ahead while video is still decoding up to the target).
    fn syncAudioActive(self: *VideoView) void {
        if (self.audio) |a| a.setActive(self.paused_at == null and !self.seeking and !self.prerolling);
    }

    /// Media time presented at monotonic time `t`: from the audio clock (which already
    /// includes the audio output latency) when available, else from the local anchor.
    /// Null while the audio clock has no fresh sample (startup, right after resume): the
    /// current frame is held instead of extrapolating a stale clock across the pause.
    fn mediaTimeAt(self: *VideoView, t: i128) ?i128 {
        if (self.audio) |a| {
            const sample = a.clock.read() orelse return null;
            if (sample.heard_ns < self.clock_valid_after or sample.pts_ns < self.clock_min_pts) return null;
            return media.Audio.Clock.mediaTimeAt(sample, t);
        }
        return if (self.anchor_ns) |anchor| t - anchor else null;
    }

    /// Seeks to a position in the file; the current frame stays up until the new one is due.
    fn seekTo(self: *VideoView, stream_ns: i64, now_ns: i128) void {
        log.info("seek to {d:.1} s", .{@as(f64, @floatFromInt(@max(stream_ns, 0))) / 1e9});
        self.generation = self.decoder.seek(stream_ns);
        self.seek_target = @max(stream_ns, 0);
        for (self.pending.items) |*f| f.release();
        self.pending.clearRetainingCapacity();
        self.anchor_ns = null;
        self.clock_valid_after = now_ns; // ignore audio clock samples from before the seek
        self.seeking = true;
        self.prerolling = false;
        self.syncAudioActive();
        self.dirty = true;
    }

    /// Position of the frame on screen (stream ns).
    fn position(self: *const VideoView) i64 {
        if (self.seeking) return self.seek_target;
        return if (self.current) |f| f.stream_ns else 0;
    }

    fn update(ptr: *anyopaque, ft: scene.FrameTime) scene.Update {
        const self: *VideoView = @ptrCast(@alignCast(ptr));
        // Frames from before a seek are stale; dropping them (even while paused) also
        // unblocks the decoder.
        const gen = self.generation;
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].generation != gen) {
                self.pending.items[i].release();
                _ = self.pending.orderedRemove(i);
            } else i += 1;
        }
        if (self.seeking) {
            var buf: [media.Decoder.queue_depth]media.Frame = undefined;
            const n = self.decoder.poll(&buf);
            for (buf[0..n]) |*f| {
                if (f.generation == gen) {
                    self.pending.append(self.gpa, f.*) catch f.release();
                } else f.release();
            }
            if (self.pending.items.len > 0) {
                // First frame of the new position: show it right away (also while paused).
                if (self.current) |*old| old.release();
                self.current = self.pending.orderedRemove(0);
                self.seeking = false;
                // Audio of the new position starts at about the same media time.
                self.clock_min_pts = self.current.?.pts_ns - 100 * std.time.ns_per_ms;
                self.prerolling = self.audio != null;
                self.anchor_ns = null;
                return .{ .dirty = true, .next_wake_ns = ft.now_ns + 5 * std.time.ns_per_ms };
            }
            return .{ .dirty = false, .next_wake_ns = ft.now_ns + 5 * std.time.ns_per_ms };
        }
        // Take only the next few frames; the rest stay in the decoder's bounded queue,
        // which is what blocks the decoder (backpressure) instead of it racing ahead.
        if (self.pending.items.len < lookahead) {
            var buf: [lookahead]media.Frame = undefined;
            const n = self.decoder.poll(buf[0 .. lookahead - self.pending.items.len]);
            for (buf[0..n]) |*f| {
                if (f.generation == gen) {
                    self.pending.append(self.gpa, f.*) catch f.release();
                } else f.release();
            }
        }
        if (self.prerolling) {
            // Restart audio once the decoder has caught up to the seek target.
            if (self.pending.items.len < lookahead) return .{ .dirty = false, .next_wake_ns = ft.now_ns + 5 * std.time.ns_per_ms };
            self.prerolling = false;
            self.clock_valid_after = ft.now_ns;
            self.syncAudioActive();
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
        // Interpolating, a frame becomes current once its time has come (the in-between
        // images are synthesized); otherwise the nearest vsync rounds to the closest frame.
        const interpolating = self.interpolation != .off and ft.refresh_ns != 0;
        const slack: i128 = if (interpolating) 0 else @divFloor(@as(i128, ft.refresh_ns), 2);
        var pick: ?usize = null;
        for (self.pending.items, 0..) |f, idx| {
            if (f.pts_ns <= media_time + slack) pick = idx;
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
            if (self.audio != null and @abs(self.current.?.pts_ns - media_time) > 20 * std.time.ns_per_ms) log.debug("sync err {d} ms pts {d} p={d} pending={d}", .{ @divTrunc(self.current.?.pts_ns - media_time, std.time.ns_per_ms), @divTrunc(self.current.?.stream_ns, std.time.ns_per_ms), p, self.pending.items.len });
            dirty = true;
        }
        if (interpolating) if (self.current) |cur| if (self.pending.items.len > 0) {
            // Every vsync shows a new in-between image.
            const nxt = self.pending.items[0];
            const span: f64 = @floatFromInt(nxt.pts_ns - cur.pts_ns);
            const a: f32 = if (span > 0) @floatCast(std.math.clamp(@as(f64, @floatFromInt(media_time - cur.pts_ns)) / span, 0, 1)) else 0;
            if (a != self.alpha) dirty = true;
            self.alpha = a;
            return .{ .dirty = dirty, .next_wake_ns = ft.wakeToPresentAt(ft.target_ns + ft.refresh_ns) };
        };
        self.alpha = 0;
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
        if (self.interpolation != .off and self.pending.items.len > 0 and self.paused_at == null and !self.seeking) {
            self.next_view = self.pending.items[0];
            vd.next = &self.next_view;
            if (self.pending.items.len > 1) {
                self.after_view = self.pending.items[1];
                vd.after = &self.after_view;
            }
            vd.alpha = self.alpha;
            vd.interpolation = self.interpolation;
        }
        var d = frame.Draw.init(@intFromEnum(Program.video), [_]u32{0});
        d.data = std.mem.asBytes(vd);
        d.vertex_count = 6;
        try out.add(d);
    }
};

/// On-screen display: translucent panel with progress bar and time, on its own subsurface
/// above the video. Damage-driven: it only re-renders when what it shows changes.
const Osd = struct {
    gpa: Allocator,
    fonts: *text.FontSystem,
    video: *VideoView,
    /// Visible until this time (monotonic ns); always visible while paused or seeking.
    visible_until: i128 = 0,
    shown: bool = false,
    /// What was last drawn (only redraw on change).
    drawn_label: [64]u8 = undefined,
    drawn_label_len: usize = 0,
    drawn_progress: f32 = -1,
    dirty: bool = true,
    label_arena: std.heap.ArenaAllocator,
    label_layout: ?text.Layout = null,
    label_scale: f32 = 0,

    const height = 56; // logical
    const margin = 16;
    const hide_after_ns = 2500 * std.time.ns_per_ms;

    fn content(self: *Osd) scene.Content {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: scene.Content.VTable = .{ .update = update, .draw = draw };

    fn poke(self: *Osd, now_ns: i128) void {
        self.visible_until = now_ns + hide_after_ns;
        if (!self.shown) self.dirty = true;
    }

    fn duration(self: *const Osd) i64 {
        return self.video.decoder.duration_ns;
    }

    fn progress(self: *const Osd) f32 {
        const d = self.duration();
        if (d <= 0) return 0;
        return std.math.clamp(@as(f32, @floatFromInt(self.video.position())) / @as(f32, @floatFromInt(d)), 0, 1);
    }

    fn formatTime(buf: []u8, ns: i64) []const u8 {
        const total_ds = @divFloor(@max(ns, 0), 100 * std.time.ns_per_ms);
        const minutes = @divFloor(total_ds, 600);
        const seconds = @divFloor(@mod(total_ds, 600), 10);
        const tenths = @mod(total_ds, 10);
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d}", .{ minutes, seconds, tenths }) catch buf[0..0];
    }

    fn label(self: *const Osd, buf: []u8) []const u8 {
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        const paused = self.video.paused_at != null;
        return std.fmt.bufPrint(buf, "{s}{s} / {s}", .{
            if (paused) "⏸  " else "",
            formatTime(&a, self.video.position()),
            formatTime(&b, self.duration()),
        }) catch buf[0..0];
    }

    fn update(ptr: *anyopaque, ft: scene.FrameTime) scene.Update {
        const self: *Osd = @ptrCast(@alignCast(ptr));
        const visible = self.video.paused_at != null or self.video.seeking or ft.now_ns < self.visible_until;
        var dirty = self.dirty or visible != self.shown;
        self.dirty = false;
        self.shown = visible;
        if (visible) {
            var buf: [64]u8 = undefined;
            const l = self.label(&buf);
            if (!std.mem.eql(u8, l, self.drawn_label[0..self.drawn_label_len]) or @abs(self.progress() - self.drawn_progress) > 0.0005) dirty = true;
        }
        return .{ .dirty = dirty, .next_wake_ns = if (visible and self.video.paused_at == null) self.visible_until else null };
    }

    fn draw(ptr: *anyopaque, ctx: scene.DrawContext, out: *frame.DrawList) !void {
        const self: *Osd = @ptrCast(@alignCast(ptr));
        if (!self.shown) return; // fully transparent buffer: the OSD is invisible
        const s = ctx.scale;
        const w = ctx.size_px[0];
        const h = ctx.size_px[1];
        const p = self.progress();
        self.drawn_progress = p;

        const pad = 14 * s;
        const track_y = h - 16 * s;
        const track_x = pad;
        const track_w = w - 2 * pad;
        const fill_w = track_w * p;
        const rects = try out.arena.alloc(Renderer.RectInstance, 4);
        rects[0] = .{ .pos = .{ 0, 0 }, .size = .{ w, h }, .color = premul(0, 0, 0, 0.55), .radius = 12 * s };
        rects[1] = .{ .pos = .{ track_x, track_y - 2 * s }, .size = .{ track_w, 4 * s }, .color = premul(1, 1, 1, 0.25), .radius = 2 * s };
        rects[2] = .{ .pos = .{ track_x, track_y - 2 * s }, .size = .{ fill_w, 4 * s }, .color = premul(1, 1, 1, 0.9), .radius = 2 * s };
        rects[3] = .{ .pos = .{ track_x + fill_w - 6 * s, track_y - 6 * s }, .size = .{ 12 * s, 12 * s }, .color = premul(1, 1, 1, 1), .radius = 6 * s };
        try out.add(Renderer.rects(rects, ctx.size_px, ctx.white_scale));

        var buf: [64]u8 = undefined;
        const l = self.label(&buf);
        @memcpy(self.drawn_label[0..l.len], l);
        self.drawn_label_len = l.len;
        _ = self.label_arena.reset(.retain_capacity);
        const layout_result = try text.layout(self.fonts, self.label_arena.allocator(), l, .{ .size_px = 14 * s, .color = premul(1, 1, 1, 1) });
        const quads = try out.arena.alloc(text.Quad, layout_result.quads.len);
        for (layout_result.quads, quads) |q, *o| {
            o.* = q;
            o.x += pad;
            o.y += 10 * s;
        }
        try out.add(text.draw(@intFromEnum(Program.text), quads, ctx.size_px, ctx.white_scale));
    }

    fn premul(r: f32, g: f32, b: f32, a: f32) [4]f32 {
        return .{ r * a, g * a, b * a, a };
    }
};

pub const Window = struct {
    gpa: Allocator,
    sw: *Scene.SceneWindow,
    decoration: *Decoration,
    video: VideoView,
    osd: Osd,
    video_node: ?Scene.NodeId = null,
    video_view: ?Scene.ViewportId = null,
    osd_node: ?Scene.NodeId = null,
    osd_view: ?Scene.ViewportId = null,
    /// OSD rect in window coordinates (for clicks).
    osd_rect: scene.LogicalRect = .{},

    pub fn create(gpa: Allocator, fonts: *text.FontSystem, decoder: *media.Decoder, title: []const u8, sw_create: anytype) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const decoration = try Decoration.create(gpa, .{
            .decoration = @intFromEnum(Program.decoration),
            .text = @intFromEnum(Program.text),
        }, fonts, title);
        errdefer decoration.destroy();
        self.* = .{
            .gpa = gpa,
            .sw = undefined,
            .decoration = decoration,
            .video = .{ .gpa = gpa, .decoder = decoder },
            .osd = .{ .gpa = gpa, .fonts = fonts, .video = undefined, .label_arena = .init(gpa) },
        };
        self.osd.video = &self.video;
        // Initial interpolation mode (debug/testing): off, on, show_vectors, show_luma.
        if (std.c.getenv("CODOTAKA_INTERPOLATION")) |v| if (std.meta.stringToEnum(Renderer.Interpolation, std.mem.span(v))) |m| {
            self.video.interpolation = m;
        };
        errdefer self.osd.label_arena.deinit();
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
        self.osd.label_arena.deinit();
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

        // The OSD floats above the video's bottom edge on a translucent subsurface.
        if (self.osd_node == null) self.osd_node = try sw.addNodeWith("osd", sw.root, .{ .translucent = true });
        if (self.osd_view == null) self.osd_view = try sw.addViewport(self.osd.content());
        const osd_w = area.width -| 2 * Osd.margin;
        self.osd_rect = .{
            .x = Osd.margin,
            .y = area.y + @as(i32, @intCast(area.height -| (Osd.height + Osd.margin))),
            .width = osd_w,
            .height = Osd.height,
        };
        sw.setNodeRect(self.osd_node.?, self.osd_rect);
        sw.resetViewport(self.osd_view.?, osd_w, Osd.height);
        try sw.place(self.osd_view.?, .{ .node = self.osd_node.?, .region = .{ .width = osd_w, .height = Osd.height } });
    }

    fn pointer(ctx: *anyopaque, _: *Scene.SceneWindow, ev: wl.PointerEvent) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (self.decoration.pointer(ev)) return;
        const now = wl.Display.monotonicNs();
        if (ev.kind == .motion or ev.kind == .enter) self.osd.poke(now);
        if (ev.kind == .button and ev.pressed and ev.button == wl.Button.left and self.osd.shown) {
            const r = self.osd_rect;
            const x = ev.x - @as(f64, @floatFromInt(r.x));
            const y = ev.y - @as(f64, @floatFromInt(r.y));
            if (x >= 0 and y >= 0 and x < @as(f64, @floatFromInt(r.width)) and y < @as(f64, @floatFromInt(r.height))) {
                // Click on the panel: seek to that fraction of the track.
                const pad: f64 = 14;
                const frac = std.math.clamp((x - pad) / (@as(f64, @floatFromInt(r.width)) - 2 * pad), 0, 1);
                const target: i64 = @intFromFloat(frac * @as(f64, @floatFromInt(self.video.decoder.duration_ns)));
                self.video.seekTo(target, now);
                self.osd.poke(now);
            }
        }
    }

    fn seekBy(self: *Window, delta_ns: i64) void {
        const now = wl.Display.monotonicNs();
        self.video.seekTo(self.video.position() + delta_ns, now);
        self.osd.poke(now);
    }

    fn key(ctx: *anyopaque, sw: *Scene.SceneWindow, ev: wl.KeyEvent) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (ev.kind != .press) return;
        switch (ev.keysym) {
            wl.keysym.q, wl.keysym.Escape => sw.window.close(),
            wl.keysym.f => sw.window.toggleFullscreen(),
            wl.keysym.space => {
                self.video.togglePause(wl.Display.monotonicNs());
                self.osd.poke(wl.Display.monotonicNs());
                log.info("{s}", .{if (self.video.paused_at != null) "paused" else "playing"});
            },
            wl.keysym.Left => self.seekBy(-5 * std.time.ns_per_s),
            wl.keysym.Right => self.seekBy(5 * std.time.ns_per_s),
            wl.keysym.Home => self.seekBy(-self.video.position()),
            wl.keysym.i => {
                self.video.interpolation = switch (self.video.interpolation) {
                    .off => .on,
                    .on => .show_vectors,
                    .show_vectors => .show_luma,
                    .show_luma => .off,
                };
                self.video.dirty = true;
                log.info("interpolation: {t}", .{self.video.interpolation});
            },
            else => {},
        }
    }

    pub fn syncFocus(_: *Window) void {}
};
