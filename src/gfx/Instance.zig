//! The Vulkan instance plus discovery of GPUs usable for dmabuf + explicit-sync presentation.
//! There is no VkSurfaceKHR/VkSwapchainKHR anywhere: presentation is done directly through
//! linux-dmabuf-v1 and linux-drm-syncobj-v1.
const Instance = @This();

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

gpa: Allocator,
vkb: vk.BaseWrapper,
vki: vk.InstanceWrapper,
proxy: vk.InstanceProxy,

const validation_layer = "VK_LAYER_KHRONOS_validation";

pub const device_extensions = [_][*:0]const u8{
    vk.device_extensions.khr_external_memory_fd.name,
    vk.device_extensions.ext_external_memory_dma_buf.name,
    vk.device_extensions.ext_image_drm_format_modifier.name,
    vk.device_extensions.khr_external_semaphore_fd.name,
    vk.device_extensions.ext_queue_family_foreign.name,
    vk.device_extensions.ext_physical_device_drm.name,
};

extern fn vkGetInstanceProcAddr(instance: ?vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction;

pub const Candidate = struct {
    pdev: vk.PhysicalDevice,
    queue_family: u32,
    props: vk.PhysicalDeviceProperties,
    drm: vk.PhysicalDeviceDrmPropertiesEXT,
};

pub fn create(gpa: Allocator) !*Instance {
    const self = try gpa.create(Instance);
    errdefer gpa.destroy(self);
    self.gpa = gpa;
    self.vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);

    const layers = [_][*:0]const u8{validation_layer};
    const use_validation = builtin.mode == .debug and try self.hasLayer(validation_layer);
    if (!use_validation and builtin.mode == .debug) std.log.warn("{s} not available", .{validation_layer});

    const handle = try self.vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "codotaka",
            .application_version = 0,
            .engine_version = 0,
            .api_version = vk.API_VERSION_1_4.toU32(),
        },
        .enabled_layer_count = if (use_validation) layers.len else 0,
        .pp_enabled_layer_names = &layers,
    }, null);
    self.vki = vk.InstanceWrapper.load(handle, self.vkb.dispatch.vkGetInstanceProcAddr.?);
    self.proxy = vk.InstanceProxy.init(handle, &self.vki);
    return self;
}

pub fn destroy(self: *Instance) void {
    self.proxy.destroyInstance(null);
    self.gpa.destroy(self);
}

fn hasLayer(self: *Instance, name: []const u8) !bool {
    const props = try self.vkb.enumerateInstanceLayerPropertiesAlloc(self.gpa);
    defer self.gpa.free(props);
    for (props) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.layer_name, 0), name)) return true;
    }
    return false;
}

/// Every Vulkan 1.4 GPU with a DRM render node, a graphics queue, all dmabuf/explicit-sync
/// extensions, and exportable SYNC_FD semaphores. Discrete GPUs first. Caller owns the slice.
pub fn findCandidates(self: *Instance, gpa: Allocator) ![]Candidate {
    const pdevs = try self.proxy.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(pdevs);

    var list: std.ArrayList(Candidate) = .empty;
    errdefer list.deinit(gpa);

    for (pdevs) |pd| {
        const props = self.proxy.getPhysicalDeviceProperties(pd);
        const name = std.mem.sliceTo(&props.device_name, 0);
        if (props.api_version < vk.API_VERSION_1_4.toU32()) continue;

        if (!try self.hasDeviceExtensions(gpa, pd)) {
            std.log.info("skipping {s}: missing dmabuf/explicit-sync extensions", .{name});
            continue;
        }

        var drm: vk.PhysicalDeviceDrmPropertiesEXT = .{
            .has_primary = .false,
            .has_render = .false,
            .primary_major = 0,
            .primary_minor = 0,
            .render_major = 0,
            .render_minor = 0,
        };
        var props2: vk.PhysicalDeviceProperties2 = .{ .p_next = &drm, .properties = undefined };
        self.proxy.getPhysicalDeviceProperties2(pd, &props2);
        if (drm.has_render != .true) {
            std.log.info("skipping {s}: no DRM render node", .{name});
            continue;
        }

        var sem_props: vk.ExternalSemaphoreProperties = .{ .export_from_imported_handle_types = .{}, .compatible_handle_types = .{} };
        self.proxy.getPhysicalDeviceExternalSemaphoreProperties(pd, &.{ .handle_type = .{ .sync_fd = true } }, &sem_props);
        if (!sem_props.external_semaphore_features.exportable) {
            std.log.info("skipping {s}: SYNC_FD semaphores not exportable", .{name});
            continue;
        }

        const families = try self.proxy.getPhysicalDeviceQueueFamilyPropertiesAlloc(pd, gpa);
        defer gpa.free(families);
        for (families, 0..) |q, i| {
            if (q.queue_flags.graphics) {
                try list.append(gpa, .{ .pdev = pd, .queue_family = @intCast(i), .props = props, .drm = drm });
                break;
            }
        }
    }

    std.mem.sort(Candidate, list.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.props.device_type == .discrete_gpu and b.props.device_type != .discrete_gpu;
        }
    }.lessThan);

    if (list.items.len == 0) return error.NoSuitableDevice;
    return list.toOwnedSlice(gpa);
}

fn hasDeviceExtensions(self: *Instance, gpa: Allocator, pd: vk.PhysicalDevice) !bool {
    const available = try self.proxy.enumerateDeviceExtensionPropertiesAlloc(pd, null, gpa);
    defer gpa.free(available);
    for (device_extensions) |want| {
        for (available) |a| {
            if (std.mem.eql(u8, std.mem.span(want), std.mem.sliceTo(&a.extension_name, 0))) break;
        } else return false;
    }
    return true;
}
