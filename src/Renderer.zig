//! The application's programs and the recorder the presenter calls into. Program ids in
//! `frame.Draw` map to entries registered here; pipelines are created lazily per format.
const Renderer = @This();

const std = @import("std");
const vk = @import("vulkan");
const vk_core = @import("vk_core");
const vk_present = @import("vk_present");
const frame = @import("frame");
const Allocator = std.mem.Allocator;

pub const Program = enum(u32) { triangle, decoration };

const spv = struct {
    const triangle_vert align(@alignOf(u32)) = @embedFile("triangle.vert.spv").*;
    const triangle_frag align(@alignOf(u32)) = @embedFile("triangle.frag.spv").*;
    const decoration_vert align(@alignOf(u32)) = @embedFile("decoration.vert.spv").*;
    const decoration_frag align(@alignOf(u32)) = @embedFile("decoration.frag.spv").*;
};

pipelines: vk_core.PipelineCache,
ids: std.EnumArray(Program, vk_core.PipelineCache.ProgramId),

pub fn init(gpa: Allocator, device: *vk_core.Device) !Renderer {
    var pipelines = try vk_core.PipelineCache.init(gpa, device.proxy);
    errdefer pipelines.deinit();
    var ids: std.EnumArray(Program, vk_core.PipelineCache.ProgramId) = undefined;
    ids.set(.triangle, try pipelines.register(.{ .vert = &spv.triangle_vert, .frag = &spv.triangle_frag }));
    ids.set(.decoration, try pipelines.register(.{ .vert = &spv.decoration_vert, .frag = &spv.decoration_frag }));
    return .{ .pipelines = pipelines, .ids = ids };
}

pub fn deinit(self: *Renderer) void {
    self.pipelines.deinit();
}

pub fn recorder(self: *Renderer) vk_present.Presenter.Recorder {
    return .{ .ctx = self, .record = record };
}

/// Clears the target and draws every view into it within one dynamic-rendering pass.
fn record(ctx: *anyopaque, cmd: vk.CommandBufferProxy, target: vk_present.Presenter.Recorder.Target, views: []const frame.View) !void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));
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
    defer cmd.endRendering();

    const bounds: @import("geom").BufferRect = .{ .width = target.extent.width, .height = target.extent.height };
    var bound: ?u32 = null;
    for (views) |v| {
        const scissor = v.scissor.intersect(bounds) orelse continue;
        if (bound != v.draw.program) {
            const id = self.ids.get(@enumFromInt(v.draw.program));
            cmd.bindPipeline(.graphics, try self.pipelines.get(id, target.format));
            bound = v.draw.program;
        }
        cmd.setViewport(0, &.{.{
            .x = v.viewport.x,
            .y = v.viewport.y,
            .width = v.viewport.width,
            .height = v.viewport.height,
            .min_depth = 0,
            .max_depth = 1,
        }});
        cmd.setScissor(0, &.{.{
            .offset = .{ .x = scissor.x, .y = scissor.y },
            .extent = .{ .width = scissor.width, .height = scissor.height },
        }});
        const push = v.draw.bytes();
        if (push.len > 0) cmd.pushConstants(self.pipelines.layout, .{ .vertex = true, .fragment = true }, 0, @intCast(push.len), push.ptr);
        cmd.draw(3, 1, 0, 0);
    }
}
