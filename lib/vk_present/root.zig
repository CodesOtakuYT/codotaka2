//! Vulkan presentation to Wayland without VkSwapchainKHR: dmabuf images chosen from
//! per-surface feedback tranches, explicit sync through DRM syncobj timelines, and one
//! batched submit per device per frame.
const std = @import("std");
const vk = @import("vulkan");
const vk_core = @import("vk_core");

pub const formats = @import("formats.zig");
pub const Presenter = @import("Presenter.zig");
pub const SurfaceTarget = @import("SurfaceTarget.zig");

const log = std.log.scoped(.present);

pub const device_extensions = [_][*:0]const u8{
    vk.device_extensions.khr_external_memory_fd.name,
    vk.device_extensions.ext_external_memory_dma_buf.name,
    vk.device_extensions.ext_image_drm_format_modifier.name,
    vk.device_extensions.khr_external_semaphore_fd.name,
    vk.device_extensions.ext_queue_family_foreign.name,
    vk.device_extensions.ext_physical_device_drm.name,
};

pub fn drmInfo(instance: *vk_core.Instance, pdev: vk.PhysicalDevice) Presenter.DrmInfo {
    var drm: Presenter.DrmInfo = .{
        .has_primary = .false,
        .has_render = .false,
        .primary_major = 0,
        .primary_minor = 0,
        .render_major = 0,
        .render_minor = 0,
    };
    var props2: vk.PhysicalDeviceProperties2 = .{ .p_next = &drm, .properties = undefined };
    instance.proxy.getPhysicalDeviceProperties2(pdev, &props2);
    return drm;
}

/// Device filter for `vk_core.Instance.findCandidates`: needs a DRM render node and
/// exportable SYNC_FD semaphores (in addition to `device_extensions`).
pub fn acceptDevice(_: void, instance: *vk_core.Instance, pdev: vk.PhysicalDevice) bool {
    const name = std.mem.sliceTo(&instance.proxy.getPhysicalDeviceProperties(pdev).device_name, 0);
    if (drmInfo(instance, pdev).has_render != .true) {
        log.info("skipping {s}: no DRM render node", .{name});
        return false;
    }
    var sem_props: vk.ExternalSemaphoreProperties = .{ .export_from_imported_handle_types = .{}, .compatible_handle_types = .{} };
    instance.proxy.getPhysicalDeviceExternalSemaphoreProperties(pdev, &.{ .handle_type = .{ .sync_fd = true } }, &sem_props);
    if (!sem_props.external_semaphore_features.exportable) {
        log.info("skipping {s}: SYNC_FD semaphores not exportable", .{name});
        return false;
    }
    return true;
}
