//! Graphics programs as VK_EXT_shader_object pairs (vertex + fragment) that access the
//! descriptor heaps directly through untyped pointers. No pipelines, no layouts, no binding
//! mappings, no per-format variants: all state is dynamic (`setDefaultState` + caller).
const ShaderCache = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const Allocator = std.mem.Allocator;

pub const Program = struct {
    vert: []align(@alignOf(u32)) const u8,
    frag: []align(@alignOf(u32)) const u8,
};

pub const ProgramId = enum(u32) { _ };

/// Fragment variants per output encoding (specialization constant 0 in shaders/output.glsl).
pub const output_variants = 2;

const Shaders = struct { vert: vk.ShaderEXT, frag: [output_variants]vk.ShaderEXT };

gpa: Allocator,
device: *Device,
programs: std.ArrayList(Shaders) = .empty,

pub fn init(gpa: Allocator, device: *Device) ShaderCache {
    return .{ .gpa = gpa, .device = device };
}

/// The device must be idle.
pub fn deinit(self: *ShaderCache) void {
    for (self.programs.items) |p| {
        self.device.proxy.destroyShaderEXT(p.vert, null);
        for (p.frag) |f| self.device.proxy.destroyShaderEXT(f, null);
    }
    self.programs.deinit(self.gpa);
}

pub fn register(self: *ShaderCache, program: Program) !ProgramId {
    try self.programs.ensureUnusedCapacity(self.gpa, 1);
    const flags: vk.ShaderCreateFlagsEXT = .{ .descriptor_heap_ext = true };
    const values = [output_variants]u32{ 0, 1 };
    const entry = [_]vk.SpecializationMapEntry{.{ .constant_id = 0, .offset = 0, .size = @sizeOf(u32) }};
    var specs: [output_variants]vk.SpecializationInfo = undefined;
    var infos: [1 + output_variants]vk.ShaderCreateInfoEXT = undefined;
    infos[0] = .{
        .flags = flags,
        .stage = .{ .vertex = true },
        .next_stage = .{ .fragment = true },
        .code_type = .spirv_ext,
        .code_size = program.vert.len,
        .p_code = program.vert.ptr,
        .p_name = "main",
    };
    for (&specs, &values, infos[1..]) |*spec, *value, *info| {
        spec.* = .{ .map_entry_count = entry.len, .p_map_entries = &entry, .data_size = @sizeOf(u32), .p_data = value };
        info.* = .{
            .flags = flags,
            .stage = .{ .fragment = true },
            .code_type = .spirv_ext,
            .code_size = program.frag.len,
            .p_code = program.frag.ptr,
            .p_name = "main",
            .p_specialization_info = spec,
        };
    }
    var shaders: [1 + output_variants]vk.ShaderEXT = undefined;
    _ = try self.device.proxy.createShadersEXT(&infos, null, &shaders);
    self.programs.appendAssumeCapacity(.{ .vert = shaders[0], .frag = shaders[1..].* });
    return @enumFromInt(self.programs.items.len - 1);
}

/// Binds a program with the fragment variant for `output_variant` (target encoding).
pub fn bind(self: *const ShaderCache, cmd: vk.CommandBufferProxy, id: ProgramId, output_variant: u32) void {
    const p = self.programs.items[@intFromEnum(id)];
    cmd.bindShadersEXT(&.{ .{ .vertex = true }, .{ .fragment = true } }, &.{ p.vert, p.frag[output_variant] });
}

pub const Blend = enum { none, premultiplied };

/// All dynamic state shader objects require for a single-color-attachment triangle draw
/// without depth/stencil. Call once per rendering pass, then adjust (e.g. `setBlend`).
pub fn setDefaultState(cmd: vk.CommandBufferProxy) void {
    cmd.setVertexInputEXT(null, null);
    cmd.setPrimitiveTopology(.triangle_list);
    cmd.setPrimitiveRestartEnable(.false);
    cmd.setRasterizerDiscardEnable(.false);
    cmd.setPolygonModeEXT(.fill);
    cmd.setCullMode(.{});
    cmd.setFrontFace(.counter_clockwise);
    cmd.setRasterizationSamplesEXT(.{ .@"1" = true });
    cmd.setSampleMaskEXT(.{ .@"1" = true }, &[_]vk.SampleMask{0xffff_ffff});
    cmd.setAlphaToCoverageEnableEXT(.false);
    cmd.setDepthTestEnable(.false);
    cmd.setDepthWriteEnable(.false);
    cmd.setDepthBiasEnable(.false);
    cmd.setStencilTestEnable(.false);
    cmd.setColorWriteMaskEXT(0, &.{.{ .r = true, .g = true, .b = true, .a = true }});
    setBlend(cmd, .none);
}

pub fn setBlend(cmd: vk.CommandBufferProxy, blend: Blend) void {
    cmd.setColorBlendEnableEXT(0, &.{if (blend == .none) .false else .true});
    cmd.setColorBlendEquationEXT(0, &.{.{
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
    }});
}
