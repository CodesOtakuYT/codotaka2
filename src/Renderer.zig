//! The application's programs and the recorder the presenter calls into.
//! Shader objects + descriptor heaps: no pipelines, no layouts, no descriptor sets.
//! Push data is [u64 data address][program push]; per-draw data goes to the frame's
//! transient buffer and is read with buffer_reference.
const Renderer = @This();

const std = @import("std");
const vk = @import("vulkan");
const vk_core = @import("vk_core");
const vk_present = @import("vk_present");
const frame = @import("frame");
const text = @import("text");
const geom = @import("geom");
const media = @import("media");
const Flow = @import("Flow.zig");
const Atlas = @import("Atlas.zig");
const Allocator = std.mem.Allocator;

pub const Program = enum(u32) { triangle, decoration, text, video, rect, luma };

/// Instance layout read by shaders/rect.vert; draws carry `[]RectInstance` as data and
/// `RectPush` as push data.
pub const RectInstance = extern struct { pos: [2]f32, size: [2]f32, color: [4]f32, radius: f32 };
pub const RectPush = extern struct { size_px: [2]f32, white_scale: f32, _pad: f32 = 0 };

pub fn rects(instances: []const RectInstance, size_px: [2]f32, white_scale: f32) frame.Draw {
    var d = frame.Draw.init(@intFromEnum(Program.rect), RectPush{ .size_px = size_px, .white_scale = white_scale });
    d.data = std.mem.sliceAsBytes(instances);
    d.vertex_count = 6;
    d.instance_count = @intCast(instances.len);
    return d;
}

/// Per-draw data of video draws: which decoded frame, and where to put it.
pub const VideoDraw = extern struct {
    frame: *const media.Frame,
    /// Destination rect in NDC (x0, y0, x1, y1).
    dst: [4]f32,
    output_hdr: u32,
    white_scale: f32,
    /// Next frame, for motion-compensated interpolation (optical flow) at `alpha`.
    next: ?*const media.Frame = null,
    /// The frame after `next`, so its vectors can be estimated ahead.
    after: ?*const media.Frame = null,
    alpha: f32 = 0,
    interpolation: Interpolation = .off,
};

pub const Interpolation = enum(u32) { off = 0, on = 1, show_vectors = 2, show_luma = 3 };

const VideoPush = extern struct {
    data: u64 = 0,
    dst: [4]f32,
    uv_max: [2]f32,
    luma: u32,
    chroma: u32,
    smp: u32,
    matrix: u32,
    transfer: u32,
    primaries: u32,
    full_range: u32,
    bit_depth: u32,
    output_hdr: u32,
    white_scale: f32,
    peak: f32,
    mode: u32 = 0,
    luma_b: u32 = 0,
    chroma_b: u32 = 0,
    vectors: u32 = 0,
    cost: u32 = 0,
    alpha: f32 = 0,
    flow_size: [2]f32 = .{ 0, 0 },
    grid_size: [2]f32 = .{ 0, 0 },
    debug_luma: u32 = 0,
    back_vectors: u32 = 0,
    global: u32 = 0,
    splat_z: [3]f32 = .{ 0, 0, 0 },
};

const spv = struct {
    const triangle_vert align(@alignOf(u32)) = @embedFile("triangle.vert.spv").*;
    const triangle_frag align(@alignOf(u32)) = @embedFile("triangle.frag.spv").*;
    const decoration_vert align(@alignOf(u32)) = @embedFile("decoration.vert.spv").*;
    const decoration_frag align(@alignOf(u32)) = @embedFile("decoration.frag.spv").*;
    const text_vert align(@alignOf(u32)) = @embedFile("text.vert.spv").*;
    const text_frag align(@alignOf(u32)) = @embedFile("text.frag.spv").*;
    const video_vert align(@alignOf(u32)) = @embedFile("video.vert.spv").*;
    const rect_vert align(@alignOf(u32)) = @embedFile("rect.vert.spv").*;
    const rect_frag align(@alignOf(u32)) = @embedFile("rect.frag.spv").*;
    const video_frag align(@alignOf(u32)) = @embedFile("video.frag.spv").*;
    const luma_frag align(@alignOf(u32)) = @embedFile("luma.frag.spv").*;
    const splat_comp align(@alignOf(u32)) = @embedFile("splat.comp.spv").*;
};

/// Instance layout read by shaders/text.vert.
const GpuGlyph = extern struct { pos: [2]f32, size: [2]f32, uv0: [2]f32, uv1: [2]f32, color: [4]f32 };
const TextPush = extern struct {
    data: u64,
    size_px: [2]f32,
    white_scale: f32,
    pad: f32 = 0,
    atlas: u32,
    sampler: u32,
    atlas_inv_size: [2]f32,
};

gpa: Allocator,
device: *vk_core.Device,
heaps: vk_core.DescriptorHeaps,
shaders: vk_core.ShaderCache,
ids: std.EnumArray(Program, vk_core.ShaderCache.ProgramId),
splat_id: vk_core.ShaderCache.ComputeId = undefined,
/// Splat importance weights (color agreement, forward-backward consistency, motion
/// contrast); tuned with codotaka-eval, overridable via CODOTAKA_SPLAT="c,f,m".
splat_z: [3]f32 = .{ 24, 1, 0 },
linear_sampler: vk_core.DescriptorHeaps.SamplerSlot,
atlas: Atlas,
/// Shared CPU glyph cache; read-only while render tasks run.
glyphs: *const text.GlyphCache,
scratch: std.ArrayList(GpuGlyph) = .empty,

/// Plane descriptors for decoder pool images, rebuilt when the pool changes.
video_pool: usize = 0,
video_slots: std.AutoHashMapUnmanaged(vk.Image, [2]vk_core.DescriptorHeaps.ImageSlot) = .empty,
retired_slots: std.ArrayList(struct { slot: vk_core.DescriptorHeaps.ImageSlot, after: u64 }) = .empty,
/// Decoded frames used by the frame being recorded: locked until its submit is queued.
locked: std.ArrayList(*const media.Frame) = .empty,
sync_waits: std.ArrayList(struct { sem: vk.Semaphore, value: u64 }) = .empty,

/// Optical flow for frame interpolation (created on first use, NVIDIA only).
flow: ?*Flow = null,
/// This frame: luma written for a new pair; signal this value and then run the estimation
/// into `flow_slot`.
flow_luma_done: ?u64 = null,
flow_slot: ?*const Flow.Slot = null,
/// This frame samples these vectors (waits for the slot's `ready` value).
flow_use: ?*const Flow.Slot = null,
flow_stats: struct { estimated: u64 = 0, reused: u64 = 0 } = .{},

pub fn create(gpa: Allocator, device: *vk_core.Device, glyphs: *const text.GlyphCache) !*Renderer {
    const self = try gpa.create(Renderer);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .device = device,
        .heaps = try .init(gpa, device, .{}),
        .shaders = .init(gpa, device),
        .ids = undefined,
        .linear_sampler = undefined,
        .atlas = undefined,
        .glyphs = glyphs,
    };
    errdefer self.heaps.deinit();
    errdefer self.shaders.deinit();
    self.ids.set(.triangle, try self.shaders.register(.{ .vert = &spv.triangle_vert, .frag = &spv.triangle_frag }));
    self.ids.set(.decoration, try self.shaders.register(.{ .vert = &spv.decoration_vert, .frag = &spv.decoration_frag }));
    self.ids.set(.text, try self.shaders.register(.{ .vert = &spv.text_vert, .frag = &spv.text_frag }));
    self.ids.set(.video, try self.shaders.register(.{ .vert = &spv.video_vert, .frag = &spv.video_frag }));
    self.ids.set(.rect, try self.shaders.register(.{ .vert = &spv.rect_vert, .frag = &spv.rect_frag }));
    self.ids.set(.luma, try self.shaders.register(.{ .vert = &spv.video_vert, .frag = &spv.luma_frag }));
    self.splat_id = try self.shaders.registerCompute(&spv.splat_comp);
    if (std.c.getenv("CODOTAKA_SPLAT")) |v| {
        var it = std.mem.splitScalar(u8, std.mem.span(v), ',');
        for (&self.splat_z) |*z| z.* = std.fmt.parseFloat(f32, it.next() orelse break) catch z.*;
        std.log.info("splat weights {any}", .{self.splat_z});
    }
    self.linear_sampler = try self.heaps.addSampler(.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    });
    self.atlas = try .init(gpa, device, &self.heaps);
    return self;
}

/// The device must be idle.
pub fn destroy(self: *Renderer) void {
    if (self.flow) |f| f.destroy(self.gpa);
    if (self.flow_stats.estimated > 0) std.log.info("optical flow: {d} estimations, {d} interpolated draws", .{ self.flow_stats.estimated, self.flow_stats.reused });
    self.scratch.deinit(self.gpa);
    self.video_slots.deinit(self.gpa);
    self.retired_slots.deinit(self.gpa);
    self.locked.deinit(self.gpa);
    self.sync_waits.deinit(self.gpa);
    self.atlas.deinit();
    self.shaders.deinit();
    self.heaps.deinit();
    self.gpa.destroy(self);
}

pub fn recorder(self: *Renderer) vk_present.Presenter.Recorder {
    return .{ .ctx = self, .begin_frame = beginFrame, .record = record, .end_frame = endFrame, .submitted = submitted };
}

fn beginFrame(ctx: *anyopaque, cmd: vk.CommandBufferProxy) !void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));
    self.heaps.bind(cmd);
    self.flow_luma_done = null;
    self.flow_use = null;
    // Free plane descriptors of old decoder pools once no submitted work can use them.
    const completed = try self.device.completedValue();
    var i: usize = 0;
    while (i < self.retired_slots.items.len) {
        const r = self.retired_slots.items[i];
        if (completed >= r.after) {
            self.heaps.removeImage(r.slot);
            _ = self.retired_slots.swapRemove(i);
        } else i += 1;
    }
}

fn endFrame(ctx: *anyopaque, sync: *vk_core.FrameRing.Sync) !void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));
    for (self.sync_waits.items) |w| {
        try sync.wait(w.sem, w.value, .{ .fragment_shader = true });
        try sync.signal(w.sem, w.value + 1);
    }
    if (self.flow) |f| {
        if (self.flow_use) |slot| try sync.wait(f.sem, slot.ready, .{ .compute_shader = true, .fragment_shader = true });
        if (self.flow_luma_done) |v| {
            // The previous estimation must be done reading the luma images we overwrote.
            if (v > 1) try sync.wait(f.sem, v - 1, .{ .all_commands = true });
            try sync.signal(f.sem, v);
        }
    }
}

fn submitted(ctx: *anyopaque) void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));
    if (self.flow_luma_done) |v| self.flow.?.execute(self.flow_slot.?, v) catch |err| std.log.err("optical flow submit: {t}", .{err});
    self.flow_luma_done = null;
    for (self.locked.items) |f| f.unlock();
    self.locked.clearRetainingCapacity();
    self.sync_waits.clearRetainingCapacity();
}

/// Plane descriptors (luma, chroma) for a decoder image, created on first use.
fn videoSlots(self: *Renderer, f: *const media.Frame) ![2]vk_core.DescriptorHeaps.ImageSlot {
    if (f.poolId() != self.video_pool) {
        const after = self.device.lastValue() + 1;
        var it = self.video_slots.valueIterator();
        while (it.next()) |slots| for (slots) |s| try self.retired_slots.append(self.gpa, .{ .slot = s, .after = after });
        self.video_slots.clearRetainingCapacity();
        self.video_pool = f.poolId();
    }
    const image = f.image();
    if (self.video_slots.get(image)) |s| return s;
    const planes = media.Frame.planeFormats(f.format()) orelse return error.UnsupportedVideoFormat;
    var slots: [2]vk_core.DescriptorHeaps.ImageSlot = undefined;
    const aspects = [2]vk.ImageAspectFlags{ .{ .plane_0 = true }, .{ .plane_1 = true } };
    for (&slots, planes, aspects) |*slot, fmt, aspect| {
        const usage: vk.ImageViewUsageCreateInfo = .{ .usage = .{ .sampled = true } };
        slot.* = try self.heaps.addImageView(.{
            .p_next = &usage,
            .image = image,
            .view_type = .@"2d",
            .format = fmt,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{ .aspect_mask = aspect, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        });
    }
    try self.video_slots.put(self.gpa, image, slots);
    return slots;
}

/// Makes a decoded frame readable by this frame's shaders: takes FFmpeg's frame lock (held
/// until submission), transitions it to GENERAL after the decoder's writes, and orders our
/// submit on the frame's timeline (wait sem_value, signal sem_value + 1).
fn acquireVideoFrame(self: *Renderer, cmd: vk.CommandBufferProxy, f: *const media.Frame) !void {
    for (self.locked.items) |l| if (l == f) return;
    f.lock();
    try self.locked.append(self.gpa, f);
    const vkf = f.vkFrame();
    if (vkf.queue_family[0] != vk.QUEUE_FAMILY_IGNORED and vkf.queue_family[0] != self.device.queue_family)
        return error.ExclusiveVideoFrameOwnership; // FFmpeg allocates CONCURRENT images
    vk_core.barrier.image(cmd, .{
        .image = f.image(),
        .old_layout = @enumFromInt(vkf.layout[0]),
        .new_layout = .general,
        .src_stage = .{ .all_commands = true },
        .src_access = .{ .memory_write = true },
        .dst_stage = .{ .fragment_shader = true },
        .dst_access = .{ .shader_sampled_read = true },
        .range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    });
    vkf.layout[0] = @intFromEnum(vk.ImageLayout.general);
    vkf.access[0] = @bitCast(vk.AccessFlags2{ .shader_sampled_read = true });
    try self.sync_waits.append(self.gpa, .{ .sem = @enumFromInt(@intFromPtr(vkf.sem[0])), .value = vkf.sem_value[0] });
    vkf.sem_value[0] += 1;
}

/// Makes vectors for the shown pair (a, b) available, estimating them now if needed
/// (usable from the next frame), otherwise estimating the following pair (b, c) ahead so
/// it is ready when shown.
fn prepareFlow(self: *Renderer, cmd: vk.CommandBufferProxy, a: *const media.Frame, b: *const media.Frame, c: ?*const media.Frame) !void {
    if (!Flow.supported(self.device)) return;
    const size = Flow.sizeFor(self.device, a.width(), a.height());
    if (self.flow) |f| if (f.width != size[0] or f.height != size[1]) {
        self.device.waitIdle();
        f.destroy(self.gpa);
        self.flow = null;
    };
    if (self.flow == null) self.flow = Flow.create(self.gpa, self.device, &self.heaps, size[0], size[1]) catch |err| {
        std.log.err("optical flow unavailable: {t}", .{err});
        return err;
    };
    const f = self.flow.?;
    const key = [2]i64{ a.pts_ns, b.pts_ns };
    if (f.find(key)) |slot| {
        self.flow_use = slot;
        self.flow_stats.reused += 1;
        if (self.flow_stats.reused % 60 == 0 and std.c.getenv("CODOTAKA_FLOW_DUMP") != null) f.dumpStats(slot);
        if (c) |cc| {
            const ahead = [2]i64{ b.pts_ns, cc.pts_ns };
            if (f.find(ahead) == null) try self.estimate(cmd, f, b, cc, if (slot == &f.slots[0]) &f.slots[1] else &f.slots[0]);
        }
        return;
    }
    try self.estimate(cmd, f, a, b, &f.slots[0]);
}

fn estimate(self: *Renderer, cmd: vk.CommandBufferProxy, f: *Flow, a: *const media.Frame, b: *const media.Frame, slot: *Flow.Slot) !void {
    if (self.flow_luma_done != null) return; // one estimation per frame
    self.flow_stats.estimated += 1;
    f.initLayouts(cmd);
    // Full and half resolution luma of both frames (the half-size pair feeds the coarse pass).
    const Pass = struct { src: *const media.Frame, target: *const Flow.Target, w: u32, h: u32 };
    const passes = [_]Pass{
        .{ .src = a, .target = &f.luma[Flow.ref], .w = f.width, .h = f.height },
        .{ .src = b, .target = &f.luma[Flow.input], .w = f.width, .h = f.height },
        .{ .src = a, .target = &f.coarse_luma[Flow.ref], .w = f.width / 2, .h = f.height / 2 },
        .{ .src = b, .target = &f.coarse_luma[Flow.input], .w = f.width / 2, .h = f.height / 2 },
    };
    for (passes) |pass| {
        const src = pass.src;
        const slots = try self.videoSlots(src);
        const attachment = [_]vk.RenderingAttachmentInfo{.{
            .image_view = pass.target.view,
            .image_layout = .general,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .dont_care,
            .store_op = .store,
            .clear_value = undefined,
        }};
        const extent: vk.Extent2D = .{ .width = pass.w, .height = pass.h };
        cmd.beginRendering(&.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = &attachment,
        });
        vk_core.ShaderCache.setDefaultState(cmd);
        self.shaders.bind(cmd, self.ids.get(.luma), 0);
        vk_core.ShaderCache.setBlend(cmd, .none);
        cmd.setViewportWithCount(&.{.{ .x = 0, .y = 0, .width = @floatFromInt(pass.w), .height = @floatFromInt(pass.h), .min_depth = 0, .max_depth = 1 }});
        cmd.setScissorWithCount(&.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = extent }});
        var vp = std.mem.zeroes(VideoPush);
        vp.dst = .{ -1, -1, 1, 1 };
        vp.uv_max = .{
            @as(f32, @floatFromInt(src.width())) / @as(f32, @floatFromInt(src.codedWidth())),
            @as(f32, @floatFromInt(src.height())) / @as(f32, @floatFromInt(src.codedHeight())),
        };
        vp.luma = @intFromEnum(slots[0]);
        vp.chroma = @intFromEnum(slots[1]);
        vp.smp = @intFromEnum(self.linear_sampler);
        cmd.pushDataEXT(&.{ .offset = 0, .data = .{ .address = &vp, .size = @sizeOf(VideoPush) } });
        cmd.draw(6, 1, 0, 0);
        cmd.endRendering();
    }
    const values = f.reserve();
    self.flow_luma_done = values.luma_done;
    self.flow_slot = slot;
    slot.key = .{ a.pts_ns, b.pts_ns };
    slot.ready = values.flow_done;
}

/// Push data for drawing (or splatting) a video draw, including the interpolation inputs
/// when this frame has vectors for the shown pair.
fn videoPush(self: *Renderer, vd: VideoDraw) !VideoPush {
    const f = vd.frame;
    const slots = try self.videoSlots(f);
    const col = f.colorimetry();
    var vp: VideoPush = .{
        .dst = vd.dst,
        .uv_max = .{
            @as(f32, @floatFromInt(f.width())) / @as(f32, @floatFromInt(f.codedWidth())),
            @as(f32, @floatFromInt(f.height())) / @as(f32, @floatFromInt(f.codedHeight())),
        },
        .luma = @intFromEnum(slots[0]),
        .chroma = @intFromEnum(slots[1]),
        .smp = @intFromEnum(self.linear_sampler),
        .matrix = @intFromEnum(col.matrix),
        .transfer = @intFromEnum(col.transfer),
        .primaries = @intFromEnum(col.primaries),
        .full_range = @intFromBool(col.full_range),
        .bit_depth = col.bit_depth,
        .output_hdr = vd.output_hdr,
        .white_scale = vd.white_scale,
        .peak = 1000.0 / 203.0,
    };
    if (self.flow_use != null and vd.next != null and vd.interpolation != .off) {
        const fl = self.flow.?;
        const fs = self.flow_use.?;
        const nslots = try self.videoSlots(vd.next.?);
        vp.mode = @intFromEnum(vd.interpolation);
        vp.luma_b = @intFromEnum(nslots[0]);
        vp.chroma_b = @intFromEnum(nslots[1]);
        vp.vectors = @intFromEnum(fs.vectors.slot.?);
        vp.global = @intFromEnum(fs.global.slot.?);
        vp.cost = @intFromEnum(fs.cost.slot.?);
        vp.debug_luma = @intFromEnum(fl.luma_slot[Flow.input]);
        vp.back_vectors = @intFromEnum(fs.back_vectors.slot.?);
        vp.alpha = vd.alpha;
        vp.flow_size = .{ @floatFromInt(fl.width), @floatFromInt(fl.height) };
        vp.grid_size = .{ @floatFromInt(fl.gridSize()[0]), @floatFromInt(fl.gridSize()[1]) };
    }
    return vp;
}

/// Renders the in-between frame into the accumulator: forward splats of A and of B.
fn splatFrame(self: *Renderer, cmd: vk.CommandBufferProxy, vd: VideoDraw) !void {
    const f = self.flow.?;
    var vp = try self.videoPush(vd);
    if (vp.mode != @intFromEnum(Interpolation.on)) return;
    vp.data = f.accum.address;
    vp.splat_z = self.splat_z;
    const all: vk.PipelineStageFlags2 = .{ .all_commands = true };
    const rw: vk.AccessFlags2 = .{ .memory_read = true, .memory_write = true };
    memoryBarrier(cmd, all, rw, .{ .clear = true }, .{ .transfer_write = true });
    cmd.fillBuffer(f.accum.buffer, 0, vk.WHOLE_SIZE, 0);
    memoryBarrier(cmd, .{ .clear = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, rw);
    self.shaders.bindCompute(cmd, self.splat_id);
    const groups = [2]u32{ (f.width + 15) / 16, (f.height + 15) / 16 };
    for ([_]u32{ 0, 1 }) |side| {
        vp.mode = side;
        cmd.pushDataEXT(&.{ .offset = 0, .data = .{ .address = &vp, .size = @sizeOf(VideoPush) } });
        cmd.dispatch(groups[0], groups[1], 1);
    }
    memoryBarrier(cmd, .{ .compute_shader = true }, .{ .memory_write = true }, .{ .fragment_shader = true }, .{ .memory_read = true });
}

fn memoryBarrier(cmd: vk.CommandBufferProxy, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2) void {
    const mb = [_]vk.MemoryBarrier2{.{ .src_stage_mask = src_stage, .src_access_mask = src_access, .dst_stage_mask = dst_stage, .dst_access_mask = dst_access }};
    cmd.pipelineBarrier2(&.{ .memory_barrier_count = mb.len, .p_memory_barriers = &mb });
}

/// Clears the target and draws every view into it within one dynamic-rendering pass.
fn record(ctx: *anyopaque, cmd: vk.CommandBufferProxy, upload: *vk_core.Buffer.Linear, target: vk_present.Presenter.Recorder.Target, views: []const frame.View) !void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));

    // Before the rendering pass: upload new glyphs (host copy) and acquire video frames.
    for (views) |v| switch (@as(Program, @enumFromInt(v.draw.program))) {
        .text => for (std.mem.bytesAsSlice(text.Quad, @as([]align(4) const u8, @alignCast(v.draw.data)))) |q| {
            _ = try self.atlas.ensure(self.glyphs, q.glyph);
        },
        .video => {
            const vd = std.mem.bytesToValue(VideoDraw, v.draw.data);
            try self.acquireVideoFrame(cmd, vd.frame);
            if (vd.interpolation != .off) if (vd.next) |next| {
                try self.acquireVideoFrame(cmd, next);
                if (vd.after) |after| try self.acquireVideoFrame(cmd, after);
                try self.prepareFlow(cmd, vd.frame, next, vd.after);
                if (self.flow_use != null) try self.splatFrame(cmd, vd);
            };
        },
        else => {},
    };
    try self.atlas.flush(self.glyphs);

    const color_attachment = [_]vk.RenderingAttachmentInfo{.{
        .image_view = target.view,
        .image_layout = .general,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = if (target.translucent) .{ 0, 0, 0, 0 } else .{ 0.002, 0.002, 0.003, 1.0 } } },
    }};
    cmd.beginRendering(&.{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = target.extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = color_attachment.len,
        .p_color_attachments = &color_attachment,
    });
    defer cmd.endRendering();
    vk_core.ShaderCache.setDefaultState(cmd);

    const bounds: geom.BufferRect = .{ .width = target.extent.width, .height = target.extent.height };
    var bound: ?u32 = null;
    for (views) |v| {
        const scissor = v.scissor.intersect(bounds) orelse continue;
        if (v.draw.instance_count == 0) continue;
        const program: Program = @enumFromInt(v.draw.program);
        if (bound != v.draw.program) {
            self.shaders.bind(cmd, self.ids.get(program), @intFromEnum(target.encode));
            vk_core.ShaderCache.setBlend(cmd, if (program == .text or program == .rect) .premultiplied else .none);
            bound = v.draw.program;
        }
        cmd.setViewportWithCount(&.{.{
            .x = v.viewport.x,
            .y = v.viewport.y,
            .width = v.viewport.width,
            .height = v.viewport.height,
            .min_depth = 0,
            .max_depth = 1,
        }});
        cmd.setScissorWithCount(&.{.{
            .offset = .{ .x = scissor.x, .y = scissor.y },
            .extent = .{ .width = scissor.width, .height = scissor.height },
        }});

        var push: [256]u8 align(8) = undefined; // device push data limit (>= 256 B)
        var push_len: usize = 8;
        if (program == .video) {
            const vd = std.mem.bytesToValue(VideoDraw, v.draw.data);
            var vp = try self.videoPush(vd);
            if (vp.mode == @intFromEnum(Interpolation.on)) vp.data = self.flow.?.accum.address;
            @memcpy(push[0..@sizeOf(VideoPush)], std.mem.asBytes(&vp));
            push_len = @sizeOf(VideoPush);
        } else if (program == .text) {
            const p = std.mem.bytesToValue(text.DrawPush, v.draw.bytes());
            const tp: TextPush = .{
                .data = try self.uploadGlyphs(upload, v.draw.data),
                .size_px = p.size_px,
                .white_scale = p.white_scale,
                .atlas = @intFromEnum(self.atlas.slot),
                .sampler = @intFromEnum(self.linear_sampler),
                .atlas_inv_size = .{ 1.0 / @as(f32, Atlas.size), 1.0 / @as(f32, Atlas.size) },
            };
            @memcpy(push[0..@sizeOf(TextPush)], std.mem.asBytes(&tp));
            push_len = @sizeOf(TextPush);
        } else {
            const address: u64 = if (v.draw.data.len > 0) try upload.push(v.draw.data, 16) else 0;
            @memcpy(push[0..8], std.mem.asBytes(&address));
            @memcpy(push[8..][0..v.draw.push_len], v.draw.bytes());
            push_len += v.draw.push_len;
        }
        cmd.pushDataEXT(&.{ .offset = 0, .data = .{ .address = &push, .size = std.mem.alignForward(usize, push_len, 4) } });
        cmd.draw(v.draw.vertex_count, v.draw.instance_count, 0, 0);
    }
    self.atlas.last_use = self.device.lastValue() + 1;
}

/// Converts text quads (glyph ids) into GPU instances (atlas rects) in transient memory.
fn uploadGlyphs(self: *Renderer, upload: *vk_core.Buffer.Linear, data: []const u8) !u64 {
    const quads = std.mem.bytesAsSlice(text.Quad, @as([]align(4) const u8, @alignCast(data)));
    self.scratch.clearRetainingCapacity();
    try self.scratch.ensureTotalCapacity(self.gpa, quads.len);
    for (quads) |q| {
        const r = try self.atlas.ensure(self.glyphs, q.glyph);
        const x: f32 = @floatFromInt(r.x);
        const y: f32 = @floatFromInt(r.y);
        const w: f32 = @floatFromInt(r.w);
        const h: f32 = @floatFromInt(r.h);
        self.scratch.appendAssumeCapacity(.{ .pos = .{ q.x, q.y }, .size = .{ w, h }, .uv0 = .{ x, y }, .uv1 = .{ x + w, y + h }, .color = q.color });
    }
    return upload.push(std.mem.sliceAsBytes(self.scratch.items), 16);
}
