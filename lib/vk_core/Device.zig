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

pub const QueueFamily = struct {
    index: u32,
    flags: vk.QueueFlags,
    video_ops: vk.VideoCodecOperationFlagsKHR = .{},
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
/// Families with a created queue (graphics first), e.g. for handing to FFmpeg.
queue_families: []QueueFamily,
/// Video decode family, if requested and available.
decode_family: ?QueueFamily = null,
/// NVIDIA optical flow (VK_NV_optical_flow) queue, if requested and available.
flow_family: ?u32 = null,
flow_queue: ?vk.QueueProxy = null,
flow_props: ?vk.PhysicalDeviceOpticalFlowPropertiesNV = null,
/// Everything enabled at creation, kept alive for interop (FFmpeg wants both).
enabled_extensions: [][*:0]const u8,
features: *Features,
memory: Memory,
deletion: DeletionQueue = .{},

/// Signalled with increasing values by every submission on this device.
timeline: vk.Semaphore = .null,
/// Last value handed out for a submission.
timeline_value: std.atomic.Value(u64) = .init(0),

pub const Options = struct {
    /// Extensions beyond `baseline_extensions`.
    extensions: []const [*:0]const u8 = &.{},
    /// Also create a video-decode queue and enable Vulkan Video decode for every codec the
    /// device supports (H.264, H.265, AV1, VP9).
    video_decode: bool = false,
    /// Also create an optical-flow queue (VK_NV_optical_flow) when the device has one.
    optical_flow: bool = false,
};

const video_codec_extensions = .{
    .{ "decode_h264_khr", vk.device_extensions.khr_video_decode_h_264.name },
    .{ "decode_h265_khr", vk.device_extensions.khr_video_decode_h_265.name },
    .{ "decode_av1_khr", vk.device_extensions.khr_video_decode_av_1.name },
    .{ "decode_vp9_khr", vk.device_extensions.khr_video_decode_vp_9.name },
};

/// The feature chain for the baseline; used both to query and to enable.
pub const Features = struct {
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
    /// Only linked when video decode is enabled.
    video_maintenance1: vk.PhysicalDeviceVideoMaintenance1FeaturesKHR = .{},
    /// Only linked when VP9 decode is supported.
    video_vp9: vk.PhysicalDeviceVideoDecodeVP9FeaturesKHR = .{},
    /// Only linked when optical flow is enabled.
    optical_flow: vk.PhysicalDeviceOpticalFlowFeaturesNV = .{},

    /// Appends an optional feature struct to the end of the linked chain.
    fn append(f: *Features, node: anytype) void {
        var tail: *vk.BaseOutStructure = @ptrCast(&f.core);
        while (tail.p_next) |n| tail = n;
        tail.p_next = @ptrCast(node);
    }

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

/// The first queue family that can decode video, with the codecs it supports.
pub fn findDecodeFamily(instance: *Instance, gpa: Allocator, pdev: vk.PhysicalDevice) !?QueueFamily {
    var count: u32 = 0;
    instance.proxy.getPhysicalDeviceQueueFamilyProperties2(pdev, &count, null);
    const props = try gpa.alloc(vk.QueueFamilyProperties2, count);
    defer gpa.free(props);
    const video = try gpa.alloc(vk.QueueFamilyVideoPropertiesKHR, count);
    defer gpa.free(video);
    for (props, video) |*p, *v| {
        v.* = .{ .video_codec_operations = .{} };
        p.* = .{ .p_next = v, .queue_family_properties = undefined };
    }
    instance.proxy.getPhysicalDeviceQueueFamilyProperties2(pdev, &count, props.ptr);
    for (props, video, 0..) |p, v, i| {
        if (p.queue_family_properties.queue_flags.video_decode_khr and v.video_codec_operations.toInt() != 0)
            return .{ .index = @intCast(i), .flags = p.queue_family_properties.queue_flags, .video_ops = v.video_codec_operations };
    }
    return null;
}

/// The optical-flow queue family and limits, if the device supports VK_NV_optical_flow.
fn findOpticalFlow(instance: *Instance, gpa: Allocator, pdev: vk.PhysicalDevice) !?struct { family: u32, props: vk.PhysicalDeviceOpticalFlowPropertiesNV } {
    const exts = try instance.proxy.enumerateDeviceExtensionPropertiesAlloc(pdev, null, gpa);
    defer gpa.free(exts);
    for (exts) |e| {
        if (std.mem.eql(u8, std.mem.sliceTo(&e.extension_name, 0), vk.device_extensions.nv_optical_flow.name)) break;
    } else return null;
    var have: vk.PhysicalDeviceOpticalFlowFeaturesNV = .{};
    var f2: vk.PhysicalDeviceFeatures2 = .{ .p_next = &have, .features = .{} };
    instance.proxy.getPhysicalDeviceFeatures2(pdev, &f2);
    if (have.optical_flow != .true) return null;
    var props: vk.PhysicalDeviceOpticalFlowPropertiesNV = undefined;
    props.s_type = .physical_device_optical_flow_properties_nv;
    props.p_next = null;
    var p2: vk.PhysicalDeviceProperties2 = .{ .p_next = &props, .properties = undefined };
    instance.proxy.getPhysicalDeviceProperties2(pdev, &p2);
    const families = try instance.proxy.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, gpa);
    defer gpa.free(families);
    for (families, 0..) |fam, i| if (fam.queue_flags.optical_flow_nv) return .{ .family = @intCast(i), .props = props };
    return null;
}

pub fn create(gpa: Allocator, instance: *Instance, candidate: Instance.Candidate, opts: Options) !*Device {
    const self = try gpa.create(Device);
    errdefer gpa.destroy(self);

    var extensions: std.ArrayList([*:0]const u8) = .empty;
    errdefer extensions.deinit(gpa);
    try extensions.appendSlice(gpa, &baseline_extensions);
    try extensions.appendSlice(gpa, opts.extensions);

    const features = try gpa.create(Features);
    errdefer gpa.destroy(features);
    features.* = Features.required();
    const head = features.link();

    var families: std.ArrayList(QueueFamily) = .empty;
    errdefer families.deinit(gpa);
    try families.append(gpa, .{ .index = candidate.queue_family, .flags = .{ .graphics = true, .compute = true, .transfer = true } });

    var decode: ?QueueFamily = null;
    if (opts.video_decode) {
        if (try findDecodeFamily(instance, gpa, candidate.pdev)) |fam| {
            decode = fam;
            try families.append(gpa, fam);
            try extensions.appendSlice(gpa, &.{
                vk.device_extensions.khr_video_queue.name,
                vk.device_extensions.khr_video_decode_queue.name,
                vk.device_extensions.khr_video_maintenance_1.name,
            });
            inline for (video_codec_extensions) |e| if (@field(fam.video_ops, e[0])) try extensions.append(gpa, e[1]);
            features.f11.sampler_ycbcr_conversion = .true;
            features.video_maintenance1 = .{ .video_maintenance_1 = .true };
            features.append(&features.video_maintenance1);
            // VP9 decode is gated by a feature in addition to its extension.
            if (fam.video_ops.decode_vp9_khr) {
                features.video_vp9 = .{ .video_decode_vp9 = .true };
                features.append(&features.video_vp9);
            }
        } else log.warn("no video decode queue on {s}", .{std.mem.sliceTo(&candidate.props.device_name, 0)});
    }

    var flow_family: ?u32 = null;
    var flow_props: ?vk.PhysicalDeviceOpticalFlowPropertiesNV = null;
    if (opts.optical_flow) if (try findOpticalFlow(instance, gpa, candidate.pdev)) |found| {
        flow_family = found.family;
        flow_props = found.props;
        try families.append(gpa, .{ .index = found.family, .flags = .{ .optical_flow_nv = true } });
        try extensions.appendSlice(gpa, &.{ vk.device_extensions.nv_optical_flow.name, vk.device_extensions.khr_format_feature_flags_2.name });
        features.optical_flow = .{ .optical_flow = .true };
        features.append(&features.optical_flow);
    };

    const priority = [_]f32{1.0};
    var queue_infos: [3]vk.DeviceQueueCreateInfo = undefined;
    for (families.items, 0..) |fam, i| queue_infos[i] = .{
        .flags = .{ .internally_synchronized_khr = true },
        .queue_family_index = fam.index,
        .queue_count = 1,
        .p_queue_priorities = &priority,
    };
    const handle = try instance.proxy.createDevice(candidate.pdev, &.{
        .p_next = head,
        .queue_create_info_count = @intCast(families.items.len),
        .p_queue_create_infos = &queue_infos,
        .enabled_extension_count = @intCast(extensions.items.len),
        .pp_enabled_extension_names = extensions.items.ptr,
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
        .queue_families = try families.toOwnedSlice(gpa),
        .decode_family = decode,
        .flow_family = flow_family,
        .flow_props = flow_props,
        .enabled_extensions = try extensions.toOwnedSlice(gpa),
        .features = features,
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

    if (flow_family) |fam| self.flow_queue = vk.QueueProxy.init(self.proxy.getDeviceQueue2(&.{
        .flags = .{ .internally_synchronized_khr = true },
        .queue_family_index = fam,
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
    self.gpa.free(self.queue_families);
    self.gpa.free(self.enabled_extensions);
    self.gpa.destroy(self.features);
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
    if (self.flow_queue) |q| q.waitIdle() catch {};
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
