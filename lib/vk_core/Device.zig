//! A logical device with one internally synchronized graphics queue, a timeline semaphore
//! tracking GPU progress, the memory allocator and the deletion queue.
//!
//! Baseline (required, see `baseline_extensions` / `supportsBaseline`):
//!   Vulkan 1.4 with timeline semaphores, buffer device address, scalar layout,
//!   synchronization2, dynamic rendering, host image copy, maintenance5/6;
//!   VK_EXT_descriptor_heap + VK_KHR_shader_untyped_pointers (shaders index the heaps
//!   directly via the ResourceHeapEXT/SamplerHeapEXT built-ins; no sets, layouts or mappings),
//!   VK_EXT_shader_object (no pipelines), VK_KHR_unified_image_layouts (GENERAL everywhere),
//!   VK_KHR_internally_synchronized_queues (submit from any thread), robustness2 null descriptors.
const Device = @This();

const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");
const DeletionQueue = @import("DeletionQueue.zig");
const Memory = @import("memory.zig").Memory;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.vk);

pub const baseline_extensions = [_][*:0]const u8{
    vk.device_extensions.ext_descriptor_heap.name,
    vk.device_extensions.khr_shader_untyped_pointers.name,
    vk.device_extensions.ext_shader_object.name,
    vk.device_extensions.khr_unified_image_layouts.name,
    vk.device_extensions.khr_internally_synchronized_queues.name,
    vk.device_extensions.khr_robustness_2.name,
};

gpa: Allocator,
instance: *Instance,
pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
heap_props: vk.PhysicalDeviceDescriptorHeapPropertiesEXT,
queue_family: u32,
vkd: vk.DeviceWrapper,
proxy: vk.DeviceProxy,
/// Internally synchronized: any thread may submit.
queue: vk.QueueProxy,
memory: Memory,
deletion: DeletionQueue = .{},

/// Signalled with increasing values by every submission on this device.
timeline: vk.Semaphore = .null,
/// Last value handed out for a submission.
timeline_value: std.atomic.Value(u64) = .init(0),

pub const Options = struct {
    /// Extensions beyond `baseline_extensions`.
    extensions: []const [*:0]const u8 = &.{},
};

/// The feature chain for the baseline; used both to query and to enable.
const Features = struct {
    core: vk.PhysicalDeviceFeatures2 = .{ .features = .{} },
    f11: vk.PhysicalDeviceVulkan11Features = .{},
    f12: vk.PhysicalDeviceVulkan12Features = .{},
    f13: vk.PhysicalDeviceVulkan13Features = .{},
    f14: vk.PhysicalDeviceVulkan14Features = .{},
    heap: vk.PhysicalDeviceDescriptorHeapFeaturesEXT = .{},
    untyped: vk.PhysicalDeviceShaderUntypedPointersFeaturesKHR = .{},
    shader_object: vk.PhysicalDeviceShaderObjectFeaturesEXT = .{},
    unified: vk.PhysicalDeviceUnifiedImageLayoutsFeaturesKHR = .{},
    sync_queues: vk.PhysicalDeviceInternallySynchronizedQueuesFeaturesKHR = .{},
    robustness2: vk.PhysicalDeviceRobustness2FeaturesKHR = .{},

    /// Links the chain; returns the PhysicalDeviceFeatures2 head.
    fn link(f: *Features) *vk.PhysicalDeviceFeatures2 {
        f.core.p_next = &f.f11;
        f.f11.p_next = &f.f12;
        f.f12.p_next = &f.f13;
        f.f13.p_next = &f.f14;
        f.f14.p_next = &f.heap;
        f.heap.p_next = &f.untyped;
        f.untyped.p_next = &f.shader_object;
        f.shader_object.p_next = &f.unified;
        f.unified.p_next = &f.sync_queues;
        f.sync_queues.p_next = &f.robustness2;
        f.robustness2.p_next = null;
        return &f.core;
    }

    fn required() Features {
        return .{
            .core = .{ .features = .{ .shader_int_64 = .true } },
            .f11 = .{ .shader_draw_parameters = .true },
            .f12 = .{
                .timeline_semaphore = .true,
                .buffer_device_address = .true,
                .scalar_block_layout = .true,
                .shader_sampled_image_array_non_uniform_indexing = .true,
            },
            .f13 = .{ .dynamic_rendering = .true, .synchronization_2 = .true, .maintenance_4 = .true },
            .f14 = .{ .host_image_copy = .true, .maintenance_5 = .true, .maintenance_6 = .true },
            .heap = .{ .descriptor_heap = .true },
            .untyped = .{ .shader_untyped_pointers = .true },
            .shader_object = .{ .shader_object = .true },
            .unified = .{ .unified_image_layouts = .true },
            .sync_queues = .{ .internally_synchronized_queues = .true },
            .robustness2 = .{ .null_descriptor = .true },
        };
    }

    /// Names of required features `have` lacks.
    fn missing(have: *const Features, out: *std.ArrayList([]const u8), gpa: Allocator) !void {
        const want = required();
        if (want.core.features.shader_int_64 == .true and have.core.features.shader_int_64 != .true) try out.append(gpa, "shaderInt64");
        inline for (.{ "f11", "f12", "f13", "f14", "heap", "untyped", "shader_object", "unified", "sync_queues", "robustness2" }) |group| {
            const W = @TypeOf(@field(want, group));
            const info = @typeInfo(W).@"struct";
            inline for (info.field_names, info.field_types) |field, T| {
                if (T == vk.Bool32 and @field(@field(want, group), field) == .true and @field(@field(have, group), field) != .true)
                    try out.append(gpa, field);
            }
        }
    }
};

/// Whether `pdev` supports every baseline feature (extensions are checked by Instance).
pub fn supportsBaseline(instance: *Instance, pdev: vk.PhysicalDevice) bool {
    var have: Features = .{};
    instance.proxy.getPhysicalDeviceFeatures2(pdev, have.link());
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(instance.gpa);
    have.missing(&missing, instance.gpa) catch return false;
    if (missing.items.len > 0) {
        const dev_name = std.mem.sliceTo(&instance.proxy.getPhysicalDeviceProperties(pdev).device_name, 0);
        for (missing.items) |m| log.info("skipping {s}: feature {s} unsupported", .{ dev_name, m });
        return false;
    }
    return true;
}

pub fn create(gpa: Allocator, instance: *Instance, candidate: Instance.Candidate, opts: Options) !*Device {
    const self = try gpa.create(Device);
    errdefer gpa.destroy(self);

    const extensions = try std.mem.concat(gpa, [*:0]const u8, &.{ &baseline_extensions, opts.extensions });
    defer gpa.free(extensions);

    var features = Features.required();
    const priority = [_]f32{1.0};
    const handle = try instance.proxy.createDevice(candidate.pdev, &.{
        .p_next = features.link(),
        .queue_create_info_count = 1,
        .p_queue_create_infos = &.{.{
            .flags = .{ .internally_synchronized_khr = true },
            .queue_family_index = candidate.queue_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        }},
        .enabled_extension_count = @intCast(extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
    }, null);

    var heap_props: vk.PhysicalDeviceDescriptorHeapPropertiesEXT = undefined;
    heap_props.s_type = .physical_device_descriptor_heap_properties_ext;
    heap_props.p_next = null;
    var props2: vk.PhysicalDeviceProperties2 = .{ .p_next = &heap_props, .properties = undefined };
    instance.proxy.getPhysicalDeviceProperties2(candidate.pdev, &props2);

    self.* = .{
        .gpa = gpa,
        .instance = instance,
        .pdev = candidate.pdev,
        .props = candidate.props,
        .heap_props = heap_props,
        .queue_family = candidate.queue_family,
        .vkd = vk.DeviceWrapper.load(handle, instance.vki.dispatch.vkGetDeviceProcAddr.?),
        .proxy = undefined,
        .queue = undefined,
        .memory = .init(instance.proxy, candidate.pdev),
    };
    self.proxy = vk.DeviceProxy.init(handle, &self.vkd);
    errdefer self.proxy.destroyDevice(null);
    // Internally synchronized queues must be fetched with the matching create flags.
    self.queue = vk.QueueProxy.init(self.proxy.getDeviceQueue2(&.{
        .flags = .{ .internally_synchronized_khr = true },
        .queue_family_index = self.queue_family,
        .queue_index = 0,
    }), &self.vkd);

    const type_info: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = .timeline, .initial_value = 0 };
    self.timeline = try self.proxy.createSemaphore(&.{ .p_next = &type_info }, null);
    log.info("device: {s}", .{self.name()});
    return self;
}

/// Waits for the GPU, runs all pending deletions, and destroys the device.
pub fn destroy(self: *Device) void {
    self.waitIdle();
    self.deletion.flush();
    self.deletion.deinit(self.gpa);
    self.proxy.destroySemaphore(self.timeline, null);
    self.proxy.destroyDevice(null);
    self.gpa.destroy(self);
}

pub fn name(self: *const Device) []const u8 {
    return std.mem.sliceTo(&self.props.device_name, 0);
}

/// GPU progress, without blocking.
pub fn completedValue(self: *Device) !u64 {
    return self.proxy.getSemaphoreCounterValue(self.timeline);
}

/// Reserves the timeline value the next submission will signal.
pub fn nextValue(self: *Device) u64 {
    return self.timeline_value.fetchAdd(1, .monotonic) + 1;
}

pub fn lastValue(self: *const Device) u64 {
    return self.timeline_value.load(.monotonic);
}

/// Blocks until the timeline reaches `value`.
pub fn waitValue(self: *Device, value: u64) !void {
    _ = try self.proxy.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = &.{self.timeline},
        .p_values = &.{value},
    }, std.math.maxInt(u64));
}

pub fn waitIdle(self: *Device) void {
    self.waitValue(self.lastValue()) catch {};
    self.queue.waitIdle() catch {};
}

/// Defers destruction until all work submitted so far has completed and `ready` holds.
pub fn deferDestroy(
    self: *Device,
    ctx: *anyopaque,
    ready: ?*const fn (*anyopaque) bool,
    destroy_fn: *const fn (*anyopaque) void,
) !void {
    try self.deletion.push(self.gpa, .{ .after_value = self.lastValue(), .ctx = ctx, .ready = ready, .destroy = destroy_fn });
}

/// Runs deferred destructions whose conditions are met. Never blocks.
pub fn collectGarbage(self: *Device) !void {
    _ = self.deletion.collect(try self.completedValue());
}
