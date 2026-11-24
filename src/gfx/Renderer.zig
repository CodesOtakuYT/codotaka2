//! Device-wide rendering resources shared by every view: one pipeline layout and a
//! pipeline per (kind, target format). Knows nothing about windows, surfaces, scales or
//! presentation: it draws a list of views into any color image in COLOR_ATTACHMENT_OPTIMAL.
const Renderer = @This();

const std = @import("std");
const vk = @import("vulkan");

pub const Kind = enum { triangle, decoration };

/// Target formats we can render to (see Device.formats).
pub const formats = [_]vk.Format{ .b8g8r8a8_srgb, .r16g16b16a16_sfloat };

pub const max_push = 128;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// A draw: which pipeline, and its push-constant block.
pub const Draw = struct {
    kind: Kind,
    push: [max_push]u8 align(4) = undefined,
    push_len: u8 = 0,

    pub fn init(kind: Kind, push: anytype) Draw {
        const T = @TypeOf(push);
        comptime std.debug.assert(@sizeOf(T) <= max_push);
        var d: Draw = .{ .kind = kind, .push_len = @sizeOf(T) };
        @memcpy(d.push[0..@sizeOf(T)], std.mem.asBytes(&push));
        return d;
    }
};

/// One region of one render target showing (part of) a logical viewport, in buffer pixels.
pub const View = struct {
    /// Where the *whole* logical viewport lies in target pixels. It may extend past the
    /// target; together with `scissor` this renders only the visible part, so a viewport can
    /// be split across several targets (e.g. subsurfaces) with continuous content.
    viewport: struct { x: f32, y: f32, width: f32, height: f32 },
    /// The region of the target this view may write to.
    scissor: Rect,
    draw: Draw,
};

pub const Target = struct {
    view: vk.ImageView,
    extent: vk.Extent2D,
    format: vk.Format,
};

dev: vk.DeviceProxy,
layout: vk.PipelineLayout,
pipelines: [std.enums.values(Kind).len][formats.len]vk.Pipeline,

const shaders = struct {
    const triangle_vert align(@alignOf(u32)) = @embedFile("triangle.vert.spv").*;
    const triangle_frag align(@alignOf(u32)) = @embedFile("triangle.frag.spv").*;
    const decoration_vert align(@alignOf(u32)) = @embedFile("decoration.vert.spv").*;
    const decoration_frag align(@alignOf(u32)) = @embedFile("decoration.frag.spv").*;
};

pub fn init(dev: vk.DeviceProxy) !Renderer {
    const push_range = [_]vk.PushConstantRange{.{
        .stage_flags = .{ .vertex = true, .fragment = true },
        .offset = 0,
        .size = max_push,
    }};
    const layout = try dev.createPipelineLayout(&.{
        .push_constant_range_count = push_range.len,
        .p_push_constant_ranges = &push_range,
    }, null);
    errdefer dev.destroyPipelineLayout(layout, null);

    var self: Renderer = .{ .dev = dev, .layout = layout, .pipelines = @splat(@splat(.null)) };
    errdefer self.destroyPipelines();
    for (std.enums.values(Kind)) |kind| {
        const vert, const frag = switch (kind) {
            .triangle => .{ &shaders.triangle_vert, &shaders.triangle_frag },
            .decoration => .{ &shaders.decoration_vert, &shaders.decoration_frag },
        };
        for (formats, 0..) |format, fi| {
            self.pipelines[@intFromEnum(kind)][fi] = try createPipeline(dev, layout, vert, frag, format);
        }
    }
    return self;
}

pub fn deinit(self: *Renderer) void {
    self.destroyPipelines();
    self.dev.destroyPipelineLayout(self.layout, null);
}

fn destroyPipelines(self: *Renderer) void {
    for (self.pipelines) |row| for (row) |p| self.dev.destroyPipeline(p, null);
}

fn formatIndex(format: vk.Format) usize {
    return std.mem.indexOfScalar(vk.Format, &formats, format) orelse unreachable;
}

fn createPipeline(
    dev: vk.DeviceProxy,
    layout: vk.PipelineLayout,
    vert_code: []align(@alignOf(u32)) const u8,
    frag_code: []align(@alignOf(u32)) const u8,
    format: vk.Format,
) !vk.Pipeline {
    const vert = try dev.createShaderModule(&.{ .code_size = vert_code.len, .p_code = @ptrCast(vert_code.ptr) }, null);
    defer dev.destroyShaderModule(vert, null);
    const frag = try dev.createShaderModule(&.{ .code_size = frag_code.len, .p_code = @ptrCast(frag_code.ptr) }, null);
    defer dev.destroyShaderModule(frag, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment = true }, .module = frag, .p_name = "main" },
    };
    const dyn_states = [_]vk.DynamicState{ .viewport, .scissor };
    const blend_attachment = [_]vk.PipelineColorBlendAttachmentState{.{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
    }};
    const color_formats = [_]vk.Format{format};
    const rendering: vk.PipelineRenderingCreateInfo = .{
        .view_mask = 0,
        .color_attachment_count = color_formats.len,
        .p_color_attachment_formats = &color_formats,
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };

    const info = [_]vk.GraphicsPipelineCreateInfo{.{
        .p_next = &rendering,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &.{
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        },
        .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .rasterization_samples = .{ .@"1" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = blend_attachment.len,
            .p_attachments = &blend_attachment,
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{
            .dynamic_state_count = dyn_states.len,
            .p_dynamic_states = &dyn_states,
        },
        .layout = layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    }};
    var pipelines: [1]vk.Pipeline = undefined;
    _ = try dev.createGraphicsPipelines(.null, &info, null, &pipelines);
    return pipelines[0];
}

/// Clears `target` and draws every view into it within one dynamic-rendering pass.
pub fn record(self: *const Renderer, cmd: vk.CommandBufferProxy, target: Target, views: []const View) void {
    const fi = formatIndex(target.format);
    const color_attachment = [_]vk.RenderingAttachmentInfo{.{
        .image_view = target.view,
        .image_layout = .color_attachment_optimal,
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

    var bound: ?Kind = null;
    for (views) |v| {
        const scissor = clip(v.scissor, target.extent) orelse continue;
        if (bound != v.draw.kind) {
            cmd.bindPipeline(.graphics, self.pipelines[@intFromEnum(v.draw.kind)][fi]);
            bound = v.draw.kind;
        }
        cmd.setViewport(0, &.{.{
            .x = v.viewport.x,
            .y = v.viewport.y,
            .width = v.viewport.width,
            .height = v.viewport.height,
            .min_depth = 0,
            .max_depth = 1,
        }});
        cmd.setScissor(0, &.{scissor});
        if (v.draw.push_len > 0)
            cmd.pushConstants(self.layout, .{ .vertex = true, .fragment = true }, 0, v.draw.push_len, &v.draw.push);
        cmd.draw(3, 1, 0, 0);
    }
    cmd.endRendering();
}

pub fn clip(r: Rect, extent: vk.Extent2D) ?vk.Rect2D {
    const x0 = std.math.clamp(r.x, 0, @as(i64, extent.width));
    const y0 = std.math.clamp(r.y, 0, @as(i64, extent.height));
    const x1 = std.math.clamp(@as(i64, r.x) + r.width, 0, @as(i64, extent.width));
    const y1 = std.math.clamp(@as(i64, r.y) + r.height, 0, @as(i64, extent.height));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .offset = .{ .x = @intCast(x0), .y = @intCast(y0) },
        .extent = .{ .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) },
    };
}
