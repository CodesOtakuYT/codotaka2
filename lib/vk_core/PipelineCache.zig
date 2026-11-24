//! Graphics pipelines created on first use, keyed by (program, color format), all sharing
//! one layout with a push-constant block. New content kinds register a program; nothing
//! else needs to know about them.
const PipelineCache = @This();

const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

pub const max_push = 128;

pub const Program = struct {
    vert: []align(@alignOf(u32)) const u8,
    frag: []align(@alignOf(u32)) const u8,
};

pub const ProgramId = enum(u32) { _ };

const Key = struct { program: ProgramId, format: vk.Format };

gpa: Allocator,
dev: vk.DeviceProxy,
layout: vk.PipelineLayout,
programs: std.ArrayList(Program) = .empty,
pipelines: std.AutoHashMapUnmanaged(Key, vk.Pipeline) = .empty,

pub fn init(gpa: Allocator, dev: vk.DeviceProxy) !PipelineCache {
    const push_range = [_]vk.PushConstantRange{.{
        .stage_flags = .{ .vertex = true, .fragment = true },
        .offset = 0,
        .size = max_push,
    }};
    const layout = try dev.createPipelineLayout(&.{
        .push_constant_range_count = push_range.len,
        .p_push_constant_ranges = &push_range,
    }, null);
    return .{ .gpa = gpa, .dev = dev, .layout = layout };
}

pub fn deinit(self: *PipelineCache) void {
    var it = self.pipelines.valueIterator();
    while (it.next()) |p| self.dev.destroyPipeline(p.*, null);
    self.pipelines.deinit(self.gpa);
    self.programs.deinit(self.gpa);
    self.dev.destroyPipelineLayout(self.layout, null);
}

pub fn register(self: *PipelineCache, program: Program) !ProgramId {
    try self.programs.append(self.gpa, program);
    return @enumFromInt(self.programs.items.len - 1);
}

pub fn get(self: *PipelineCache, program: ProgramId, format: vk.Format) !vk.Pipeline {
    const gop = try self.pipelines.getOrPut(self.gpa, .{ .program = program, .format = format });
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer self.pipelines.removeByPtr(gop.key_ptr);
    gop.value_ptr.* = try self.create(self.programs.items[@intFromEnum(program)], format);
    return gop.value_ptr.*;
}

fn create(self: *PipelineCache, program: Program, format: vk.Format) !vk.Pipeline {
    const dev = self.dev;
    const vert = try dev.createShaderModule(&.{ .code_size = program.vert.len, .p_code = @ptrCast(program.vert.ptr) }, null);
    defer dev.destroyShaderModule(vert, null);
    const frag = try dev.createShaderModule(&.{ .code_size = program.frag.len, .p_code = @ptrCast(program.frag.ptr) }, null);
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
        .p_input_assembly_state = &.{ .topology = .triangle_list, .primitive_restart_enable = .false },
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
        .p_dynamic_state = &.{ .dynamic_state_count = dyn_states.len, .p_dynamic_states = &dyn_states },
        .layout = self.layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    }};
    var pipelines: [1]vk.Pipeline = undefined;
    _ = try dev.createGraphicsPipelines(.null, &info, null, &pipelines);
    return pipelines[0];
}
