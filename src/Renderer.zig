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
const Atlas = @import("Atlas.zig");
const Allocator = std.mem.Allocator;

pub const Program = enum(u32) { triangle, decoration, text };

const spv = struct {
    const triangle_vert align(@alignOf(u32)) = @embedFile("triangle.vert.spv").*;
    const triangle_frag align(@alignOf(u32)) = @embedFile("triangle.frag.spv").*;
    const decoration_vert align(@alignOf(u32)) = @embedFile("decoration.vert.spv").*;
    const decoration_frag align(@alignOf(u32)) = @embedFile("decoration.frag.spv").*;
    const text_vert align(@alignOf(u32)) = @embedFile("text.vert.spv").*;
    const text_frag align(@alignOf(u32)) = @embedFile("text.frag.spv").*;
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
    self.atlas.deinit();
    self.shaders.deinit();
    self.heaps.deinit();
    self.gpa.destroy(self);
}

pub fn recorder(self: *Renderer) vk_present.Presenter.Recorder {
    return .{ .ctx = self, .begin_frame = beginFrame, .record = record };
}

fn beginFrame(ctx: *anyopaque, cmd: vk.CommandBufferProxy) !void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));
    self.heaps.bind(cmd);
}

/// Clears the target and draws every view into it within one dynamic-rendering pass.
fn record(ctx: *anyopaque, cmd: vk.CommandBufferProxy, upload: *vk_core.Buffer.Linear, target: vk_present.Presenter.Recorder.Target, views: []const frame.View) !void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));

    // Resolve glyphs first so all new ones are uploaded (host copy) before recording.
    for (views) |v| if (v.draw.program == @intFromEnum(Program.text)) {
        for (std.mem.bytesAsSlice(text.Quad, @as([]align(4) const u8, @alignCast(v.draw.data)))) |q| _ = try self.atlas.ensure(self.glyphs, q.glyph);
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
        if (program == .text) {
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
