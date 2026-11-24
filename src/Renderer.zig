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
const Atlas = @import("Atlas.zig");
const Allocator = std.mem.Allocator;

pub const Program = enum(u32) { triangle, decoration, text, video };

/// Per-draw data of video draws: which decoded frame, and where to put it.
pub const VideoDraw = extern struct {
    frame: *const media.Frame,
    /// Destination rect in NDC (x0, y0, x1, y1).
    dst: [4]f32,
    output_hdr: u32,
    white_scale: f32,
};

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
};

const spv = struct {
    const triangle_vert align(@alignOf(u32)) = @embedFile("triangle.vert.spv").*;
    const triangle_frag align(@alignOf(u32)) = @embedFile("triangle.frag.spv").*;
    const decoration_vert align(@alignOf(u32)) = @embedFile("decoration.vert.spv").*;
    const decoration_frag align(@alignOf(u32)) = @embedFile("decoration.frag.spv").*;
    const text_vert align(@alignOf(u32)) = @embedFile("text.vert.spv").*;
    const text_frag align(@alignOf(u32)) = @embedFile("text.frag.spv").*;
    const video_vert align(@alignOf(u32)) = @embedFile("video.vert.spv").*;
    const video_frag align(@alignOf(u32)) = @embedFile("video.frag.spv").*;
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
}

fn submitted(ctx: *anyopaque) void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));
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

/// Clears the target and draws every view into it within one dynamic-rendering pass.
fn record(ctx: *anyopaque, cmd: vk.CommandBufferProxy, upload: *vk_core.Buffer.Linear, target: vk_present.Presenter.Recorder.Target, views: []const frame.View) !void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));

    // Before the rendering pass: upload new glyphs (host copy) and acquire video frames.
    for (views) |v| switch (@as(Program, @enumFromInt(v.draw.program))) {
        .text => for (std.mem.bytesAsSlice(text.Quad, @as([]align(4) const u8, @alignCast(v.draw.data)))) |q| {
            _ = try self.atlas.ensure(self.glyphs, q.glyph);
        },
        .video => try self.acquireVideoFrame(cmd, std.mem.bytesToValue(VideoDraw, v.draw.data).frame),
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
        .clear_value = .{ .color = .{ .float_32 = .{ 0.002, 0.002, 0.003, 1.0 } } },
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
            self.shaders.bind(cmd, self.ids.get(program));
            vk_core.ShaderCache.setBlend(cmd, if (program == .text) .premultiplied else .none);
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

        var push: [8 + frame.max_push]u8 align(8) = undefined;
        var push_len: usize = 8;
        if (program == .video) {
            const vd = std.mem.bytesToValue(VideoDraw, v.draw.data);
            const f = vd.frame;
            const slots = try self.videoSlots(f);
            const col = f.colorimetry();
            const vp: VideoPush = .{
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
