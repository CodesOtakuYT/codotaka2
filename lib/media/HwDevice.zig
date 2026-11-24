//! An FFmpeg Vulkan hardware device wrapping *our* VkDevice, so decoded frames are images
//! on the device we render and present with: no copies between devices or APIs.
//! Queues are internally synchronized (VK_KHR_internally_synchronized_queues), which
//! FFmpeg 9 uses instead of its deprecated queue locks.
const HwDevice = @This();

const std = @import("std");
const vk = @import("vulkan");
const vk_core = @import("vk_core");
const c = @import("av_c");

const log = std.log.scoped(.media);

ref: *c.AVBufferRef,
device: *vk_core.Device,

pub fn create(device: *vk_core.Device) !HwDevice {
    if (device.decode_family == null) return error.NoVideoDecodeQueue;
    const ref = c.av_hwdevice_ctx_alloc(c.AV_HWDEVICE_TYPE_VULKAN) orelse return error.OutOfMemory;
    errdefer {
        var r: ?*c.AVBufferRef = ref;
        c.av_buffer_unref(&r);
    }
    const hw: *c.AVHWDeviceContext = @ptrCast(@alignCast(ref.*.data));
    const ctx: *c.AVVulkanDeviceContext = @ptrCast(@alignCast(hw.hwctx));

    const instance = device.instance;
    ctx.get_proc_addr = @ptrCast(&vk_core.Instance.getProcAddr);
    ctx.inst = @ptrCast(instance.proxy.handle);
    ctx.phys_dev = @ptrCast(device.pdev);
    ctx.act_dev = @ptrCast(device.proxy.handle);
    // The exact feature chain the device was created with (kept alive by vk_core).
    ctx.device_features = @as(*const c.VkPhysicalDeviceFeatures2, @ptrCast(&device.features.core)).*;
    ctx.enabled_inst_extensions = @ptrCast(instance.enabled_extensions.ptr);
    ctx.nb_enabled_inst_extensions = @intCast(instance.enabled_extensions.len);
    ctx.enabled_dev_extensions = @ptrCast(device.enabled_extensions.ptr);
    ctx.nb_enabled_dev_extensions = @intCast(device.enabled_extensions.len);
    for (device.queue_families, 0..) |fam, i| {
        ctx.qf[i] = .{
            .idx = @intCast(fam.index),
            .num = 1,
            .flags = @intCast(fam.flags.toInt()),
            .video_caps = @intCast(fam.video_ops.toInt()),
        };
    }
    ctx.nb_qf = @intCast(device.queue_families.len);
    ctx.queue_flags = c.VK_DEVICE_QUEUE_CREATE_INTERNALLY_SYNCHRONIZED_BIT_KHR;

    try check(c.av_hwdevice_ctx_init(ref), "av_hwdevice_ctx_init");
    log.info("FFmpeg Vulkan device on our VkDevice (decode family {d})", .{device.decode_family.?.index});
    return .{ .ref = ref, .device = device };
}

pub fn destroy(self: *HwDevice) void {
    var r: ?*c.AVBufferRef = self.ref;
    c.av_buffer_unref(&r);
}

pub fn check(rc: c_int, comptime what: []const u8) !void {
    if (rc >= 0) return;
    var buf: [128]u8 = undefined;
    _ = c.av_strerror(rc, &buf, buf.len);
    log.err("{s}: {s}", .{ what, std.mem.sliceTo(&buf, 0) });
    return error.FFmpeg;
}
