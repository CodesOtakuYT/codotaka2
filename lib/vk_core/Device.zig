//! A logical device with one graphics queue, a timeline semaphore tracking GPU progress,
//! the memory allocator and the deletion queue.
//! The queue is externally synchronized: only one task may submit at a time.
const Device = @This();

const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");
const DeletionQueue = @import("DeletionQueue.zig");
const Memory = @import("memory.zig").Memory;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.vk);

gpa: Allocator,
instance: *Instance,
pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
queue_family: u32,
vkd: vk.DeviceWrapper,
proxy: vk.DeviceProxy,
queue: vk.QueueProxy,
memory: Memory,
deletion: DeletionQueue = .{},

/// Signalled with increasing values by every submission on this device.
timeline: vk.Semaphore = .null,
/// Last value handed out for a submission.
timeline_value: u64 = 0,

pub const Options = struct {
    extensions: []const [*:0]const u8 = &.{},
};

/// Baseline features: timeline semaphores, synchronization2 and dynamic rendering.
pub fn create(gpa: Allocator, instance: *Instance, candidate: Instance.Candidate, opts: Options) !*Device {
    const self = try gpa.create(Device);
    errdefer gpa.destroy(self);

    const priority = [_]f32{1.0};
    var features13: vk.PhysicalDeviceVulkan13Features = .{
        .dynamic_rendering = .true,
        .synchronization_2 = .true,
    };
    const features12: vk.PhysicalDeviceVulkan12Features = .{
        .p_next = &features13,
        .timeline_semaphore = .true,
    };
    const handle = try instance.proxy.createDevice(candidate.pdev, &.{
        .p_next = &features12,
        .queue_create_info_count = 1,
        .p_queue_create_infos = &.{.{
            .queue_family_index = candidate.queue_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        }},
        .enabled_extension_count = @intCast(opts.extensions.len),
        .pp_enabled_extension_names = opts.extensions.ptr,
    }, null);

    self.* = .{
        .gpa = gpa,
        .instance = instance,
        .pdev = candidate.pdev,
        .props = candidate.props,
        .queue_family = candidate.queue_family,
        .vkd = vk.DeviceWrapper.load(handle, instance.vki.dispatch.vkGetDeviceProcAddr.?),
        .proxy = undefined,
        .queue = undefined,
        .memory = .init(instance.proxy, candidate.pdev),
    };
    self.proxy = vk.DeviceProxy.init(handle, &self.vkd);
    errdefer self.proxy.destroyDevice(null);
    self.queue = vk.QueueProxy.init(self.proxy.getDeviceQueue(self.queue_family, 0), &self.vkd);

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
    self.timeline_value += 1;
    return self.timeline_value;
}

pub fn waitIdle(self: *Device) void {
    _ = self.proxy.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = &.{self.timeline},
        .p_values = &.{self.timeline_value},
    }, std.math.maxInt(u64)) catch {};
    self.queue.waitIdle() catch {};
}

/// Defers destruction until all work submitted so far has completed and `ready` holds.
pub fn deferDestroy(
    self: *Device,
    ctx: *anyopaque,
    ready: ?*const fn (*anyopaque) bool,
    destroy_fn: *const fn (*anyopaque) void,
) !void {
    try self.deletion.push(self.gpa, .{ .after_value = self.timeline_value, .ctx = ctx, .ready = ready, .destroy = destroy_fn });
}

/// Runs deferred destructions whose conditions are met. Never blocks.
pub fn collectGarbage(self: *Device) !void {
    _ = self.deletion.collect(try self.completedValue());
}
