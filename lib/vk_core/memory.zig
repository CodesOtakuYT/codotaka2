//! Device memory: memory-type selection and allocation in one place.
const std = @import("std");
const vk = @import("vulkan");

pub const Memory = struct {
    props: vk.PhysicalDeviceMemoryProperties,

    pub fn init(instance: vk.InstanceProxy, pdev: vk.PhysicalDevice) Memory {
        return .{ .props = instance.getPhysicalDeviceMemoryProperties(pdev) };
    }

    /// First memory type allowed by `type_bits` that has all `required` flags,
    /// preferring types that also have `preferred`.
    pub fn findType(m: *const Memory, type_bits: u32, required: vk.MemoryPropertyFlags, preferred: vk.MemoryPropertyFlags) ?u32 {
        var fallback: ?u32 = null;
        for (m.props.memory_types[0..m.props.memory_type_count], 0..) |t, i| {
            if (type_bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            if (!t.property_flags.contains(required)) continue;
            if (t.property_flags.contains(preferred)) return @intCast(i);
            if (fallback == null) fallback = @intCast(i);
        }
        return fallback;
    }
};

pub const AllocOptions = struct {
    required: vk.MemoryPropertyFlags = .{ .device_local = true },
    preferred: vk.MemoryPropertyFlags = .{},
    /// Dedicated allocation for this image (required for exported dmabufs on some drivers).
    dedicated_image: vk.Image = .null,
    /// External handle types this allocation can be exported as.
    export_handle_types: vk.ExternalMemoryHandleTypeFlags = .{},
};

pub fn allocate(dev: vk.DeviceProxy, memory: *const Memory, reqs: vk.MemoryRequirements, opts: AllocOptions) !vk.DeviceMemory {
    const type_index = memory.findType(reqs.memory_type_bits, opts.required, opts.preferred) orelse
        return error.NoSuitableMemoryType;
    const dedicated: vk.MemoryDedicatedAllocateInfo = .{ .image = opts.dedicated_image };
    const exporting: vk.ExportMemoryAllocateInfo = .{
        .p_next = if (opts.dedicated_image != .null) &dedicated else null,
        .handle_types = opts.export_handle_types,
    };
    const p_next: ?*const anyopaque = if (opts.export_handle_types.toInt() != 0)
        &exporting
    else if (opts.dedicated_image != .null)
        &dedicated
    else
        null;
    return dev.allocateMemory(&.{
        .p_next = p_next,
        .allocation_size = reqs.size,
        .memory_type_index = type_index,
    }, null);
}
