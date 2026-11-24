//! Bindless descriptors with VK_EXT_descriptor_heap: one resource heap and one sampler heap
//! per device, written directly from the host (no descriptor sets, pools or layouts).
//!
//! Shaders access the heaps directly (GL_EXT_descriptor_heap -> SPV_EXT_descriptor_heap +
//! SPV_KHR_untyped_pointers), with descriptors packed from offset 0 at the device's
//! descriptor size, so a slot is simply an array index:
//!   layout(descriptor_heap) uniform texture2D textures[];  // ResourceHeapEXT
//!   layout(descriptor_heap) uniform sampler   samplers[];  // SamplerHeapEXT
//! Slots are passed to shaders through push data.
const DescriptorHeaps = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");
const mem = @import("memory.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.vk);

pub const ImageSlot = enum(u32) { _ };
pub const SamplerSlot = enum(u32) { _ };

gpa: Allocator,
device: *Device,
props: vk.PhysicalDeviceDescriptorHeapPropertiesEXT,

resource: Buffer,
resource_reserved_offset: u64,
image_capacity: u32,
image_free: std.ArrayList(u32) = .empty,
image_next: u32 = 0,

sampler: Buffer,
sampler_reserved_offset: u64,
sampler_capacity: u32,
sampler_next: u32 = 0,

pub const Options = struct {
    image_capacity: u32 = 4096,
    sampler_capacity: u32 = 64,
};

pub fn init(gpa: Allocator, device: *Device, opts: Options) !DescriptorHeaps {
    const props = device.heap_props;
    // [descriptors][implementation-reserved range]
    const image_stride = props.image_descriptor_size;
    const res_reserved = mem.alignForward(@as(u64, opts.image_capacity) * image_stride, @max(props.image_descriptor_alignment, props.buffer_descriptor_alignment));
    const res_size = res_reserved + props.min_resource_heap_reserved_range;
    const smp_reserved = mem.alignForward(@as(u64, opts.sampler_capacity) * props.sampler_descriptor_size, props.sampler_descriptor_alignment);
    const smp_size = smp_reserved + props.min_sampler_heap_reserved_range;
    if (res_size > props.max_resource_heap_size or smp_size > props.max_sampler_heap_size) return error.DescriptorHeapTooLarge;

    const usage: vk.BufferUsageFlags = .{ .descriptor_heap_ext = true, .shader_device_address = true };
    var resource = try Buffer.create(device, .{ .size = res_size, .usage = usage, .host_visible = true });
    errdefer resource.deinit(device);
    var sampler = try Buffer.create(device, .{ .size = smp_size, .usage = usage, .host_visible = true });
    errdefer sampler.deinit(device);
    if (resource.address % props.resource_heap_alignment != 0 or sampler.address % props.sampler_heap_alignment != 0)
        return error.DescriptorHeapMisaligned;

    log.info("descriptor heaps: {d} image slots ({d} B each, {d} KiB), {d} sampler slots, push data {d} B", .{
        opts.image_capacity, image_stride, res_size / 1024, opts.sampler_capacity, props.max_push_data_size,
    });
    return .{
        .gpa = gpa,
        .device = device,
        .props = props,
        .resource = resource,
        .resource_reserved_offset = res_reserved,
        .image_capacity = opts.image_capacity,
        .sampler = sampler,
        .sampler_reserved_offset = smp_reserved,
        .sampler_capacity = opts.sampler_capacity,
    };
}

/// The device must be idle.
pub fn deinit(self: *DescriptorHeaps) void {
    self.image_free.deinit(self.gpa);
    self.resource.deinit(self.device);
    self.sampler.deinit(self.device);
}

/// Writes a sampled-image descriptor for `image` (in GENERAL) and returns its slot.
pub fn addImage(self: *DescriptorHeaps, image: *const Image) !ImageSlot {
    return self.addImageView(image.viewInfo());
}

/// Writes a sampled-image descriptor for any view description (e.g. one plane of a
/// multi-planar image, created by another library) and returns its slot.
pub fn addImageView(self: *DescriptorHeaps, view: vk.ImageViewCreateInfo) !ImageSlot {
    const index = self.image_free.pop() orelse blk: {
        if (self.image_next == self.image_capacity) return error.DescriptorHeapFull;
        self.image_next += 1;
        break :blk self.image_next - 1;
    };
    errdefer self.image_free.append(self.gpa, index) catch {};
    const info: vk.ImageDescriptorInfoEXT = .{ .p_view = &view, .layout = .general };
    const stride = self.props.image_descriptor_size;
    try self.device.proxy.writeResourceDescriptorsEXT(&.{.{
        .type = .sampled_image,
        .data = .{ .p_image = &info },
    }}, &.{.{ .address = self.resource.mapped.? + index * stride, .size = stride }});
    return @enumFromInt(index);
}

/// Releases a slot. Only call once no submitted work can still read it
/// (e.g. from a `Device.deferDestroy` callback).
pub fn removeImage(self: *DescriptorHeaps, slot: ImageSlot) void {
    self.image_free.append(self.gpa, @intFromEnum(slot)) catch {};
}

pub fn addSampler(self: *DescriptorHeaps, info: vk.SamplerCreateInfo) !SamplerSlot {
    if (self.sampler_next == self.sampler_capacity) return error.DescriptorHeapFull;
    const index = self.sampler_next;
    const stride = self.props.sampler_descriptor_size;
    try self.device.proxy.writeSamplerDescriptorsEXT(&.{info}, &.{.{ .address = self.sampler.mapped.? + index * stride, .size = stride }});
    self.sampler_next += 1;
    return @enumFromInt(index);
}

/// Binds both heaps; invalidates all descriptor-set state (we never use any).
pub fn bind(self: *const DescriptorHeaps, cmd: vk.CommandBufferProxy) void {
    cmd.bindResourceHeapEXT(&.{
        .heap_range = .{ .address = self.resource.address, .size = self.resource.size },
        .reserved_range_offset = self.resource_reserved_offset,
        .reserved_range_size = self.props.min_resource_heap_reserved_range,
    });
    cmd.bindSamplerHeapEXT(&.{
        .heap_range = .{ .address = self.sampler.address, .size = self.sampler.size },
        .reserved_range_offset = self.sampler_reserved_offset,
        .reserved_range_size = self.props.min_sampler_heap_reserved_range,
    });
}
