//! A 2D image with its own memory and a color view; optionally DRM-modifier tiled and
//! exportable as a dmabuf.
const Image = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const mem = @import("memory.zig");

image: vk.Image = .null,
memory: vk.DeviceMemory = .null,
view: vk.ImageView = .null,
format: vk.Format = .undefined,
extent: vk.Extent2D = .{ .width = 0, .height = 0 },

pub const Options = struct {
    format: vk.Format,
    extent: vk.Extent2D,
    usage: vk.ImageUsageFlags,
    /// When set, tiling is DRM_FORMAT_MODIFIER_EXT and the driver picks one of these.
    drm_modifiers: ?[]const u64 = null,
    /// Export the memory as a dmabuf (dedicated allocation).
    export_dma_buf: bool = false,
};

pub const color_range: vk.ImageSubresourceRange = .{
    .aspect_mask = .{ .color = true },
    .base_mip_level = 0,
    .level_count = 1,
    .base_array_layer = 0,
    .layer_count = 1,
};

pub fn create(device: *Device, opts: Options) !Image {
    const dev = device.proxy;
    var self: Image = .{ .format = opts.format, .extent = opts.extent };
    errdefer self.deinit(device);

    const mod_list: vk.ImageDrmFormatModifierListCreateInfoEXT = .{
        .drm_format_modifier_count = if (opts.drm_modifiers) |m| @intCast(m.len) else 0,
        .p_drm_format_modifiers = if (opts.drm_modifiers) |m| m.ptr else undefined,
    };
    const external: vk.ExternalMemoryImageCreateInfo = .{
        .p_next = if (opts.drm_modifiers != null) &mod_list else null,
        .handle_types = .{ .dma_buf_ext = opts.export_dma_buf },
    };
    const p_next: ?*const anyopaque = if (opts.export_dma_buf) &external else if (opts.drm_modifiers != null) &mod_list else null;

    self.image = try dev.createImage(&.{
        .p_next = p_next,
        .image_type = .@"2d",
        .format = opts.format,
        .extent = .{ .width = opts.extent.width, .height = opts.extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = if (opts.drm_modifiers != null) .drm_format_modifier_ext else .optimal,
        .usage = opts.usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);

    var dedicated_reqs: vk.MemoryDedicatedRequirements = .{ .prefers_dedicated_allocation = .false, .requires_dedicated_allocation = .false };
    var reqs: vk.MemoryRequirements2 = .{ .p_next = &dedicated_reqs, .memory_requirements = undefined };
    dev.getImageMemoryRequirements2(&.{ .image = self.image }, &reqs);
    const dedicated = opts.export_dma_buf or dedicated_reqs.prefers_dedicated_allocation == .true or dedicated_reqs.requires_dedicated_allocation == .true;

    self.memory = try mem.allocate(dev, &device.memory, reqs.memory_requirements, .{
        .dedicated_image = if (dedicated) self.image else .null,
        .export_handle_types = .{ .dma_buf_ext = opts.export_dma_buf },
    });
    try dev.bindImageMemory(self.image, self.memory, 0);

    self.view = try dev.createImageView(&.{
        .image = self.image,
        .view_type = .@"2d",
        .format = opts.format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = color_range,
    }, null);
    return self;
}

pub fn deinit(self: *Image, device: *Device) void {
    const dev = device.proxy;
    dev.destroyImageView(self.view, null);
    dev.destroyImage(self.image, null);
    dev.freeMemory(self.memory, null);
    self.* = .{};
}

/// The modifier the driver chose (DRM_FORMAT_MODIFIER_EXT tiling only).
pub fn drmModifier(self: *const Image, device: *Device) !u64 {
    var props: vk.ImageDrmFormatModifierPropertiesEXT = .{ .drm_format_modifier = 0 };
    try device.proxy.getImageDrmFormatModifierPropertiesEXT(self.image, &props);
    return props.drm_format_modifier;
}

pub const PlaneLayout = struct { offset: u64, row_pitch: u64 };

/// Layout of memory plane `plane` (DRM_FORMAT_MODIFIER_EXT tiling only).
pub fn planeLayout(self: *const Image, device: *Device, plane: u32) !PlaneLayout {
    const aspect: vk.ImageAspectFlags = switch (plane) {
        0 => .{ .memory_plane_0_ext = true },
        1 => .{ .memory_plane_1_ext = true },
        2 => .{ .memory_plane_2_ext = true },
        3 => .{ .memory_plane_3_ext = true },
        else => return error.TooManyPlanes,
    };
    const l = device.proxy.getImageSubresourceLayout(self.image, &.{ .aspect_mask = aspect, .mip_level = 0, .array_layer = 0 });
    return .{ .offset = l.offset, .row_pitch = l.row_pitch };
}

/// Exports the memory as a dmabuf fd (caller owns it).
pub fn exportDmaBuf(self: *const Image, device: *Device) !std.os.linux.fd_t {
    return device.proxy.getMemoryFdKHR(&.{ .memory = self.memory, .handle_type = .{ .dma_buf_ext = true } });
}
