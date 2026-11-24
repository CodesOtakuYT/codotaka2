//! Image layout / ownership transitions (synchronization2).
const vk = @import("vulkan");
const Image = @import("Image.zig");

pub const ImageTransition = struct {
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2 = .{},
    src_access: vk.AccessFlags2 = .{},
    dst_stage: vk.PipelineStageFlags2 = .{},
    dst_access: vk.AccessFlags2 = .{},
    /// Queue family ownership transfer; IGNORED on both sides means none.
    src_queue_family: u32 = vk.QUEUE_FAMILY_IGNORED,
    dst_queue_family: u32 = vk.QUEUE_FAMILY_IGNORED,
    range: vk.ImageSubresourceRange = Image.color_range,
};

pub fn image(cmd: vk.CommandBufferProxy, t: ImageTransition) void {
    const b = [_]vk.ImageMemoryBarrier2{.{
        .src_stage_mask = t.src_stage,
        .src_access_mask = t.src_access,
        .dst_stage_mask = t.dst_stage,
        .dst_access_mask = t.dst_access,
        .old_layout = t.old_layout,
        .new_layout = t.new_layout,
        .src_queue_family_index = t.src_queue_family,
        .dst_queue_family_index = t.dst_queue_family,
        .image = t.image,
        .subresource_range = t.range,
    }};
    cmd.pipelineBarrier2(&.{ .image_memory_barrier_count = b.len, .p_image_memory_barriers = &b });
}
