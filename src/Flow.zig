//! Motion estimation between consecutive video frames on NVIDIA's optical flow accelerator
//! (VK_NV_optical_flow), used for motion-compensated frame interpolation.
//!
//! Two estimation slots (own session, vectors and cost) let the pair after the current one
//! be estimated ahead, so vectors are ready by the time a pair is shown.
//!
//! Per frame pair (A shown, B next): the graphics queue renders both frames' luma into
//! `luma[ref]` / `luma[input]` (downscaled), then the optical-flow queue estimates one
//! vector per 4×4 block from B (input) to A (reference), plus a matching cost. All images
//! are CONCURRENT between the two families and stay in GENERAL; ordering is one timeline
//! semaphore: graphics signals `2n+1`, optical flow waits on it and signals `2n+2`, and
//! the draws that sample the vectors wait on `2n+2`.
const Flow = @This();

const std = @import("std");
const vk = @import("vulkan");
const vk_core = @import("vk_core");
const mem = vk_core.memory;

const log = std.log.scoped(.flow);

pub const grid = 4;
/// Flow is estimated at most at this width (the accelerator's cost grows with area, and
/// large motion is found more reliably at lower resolution).
const max_width = 1920;

pub const luma_format: vk.Format = .r8_unorm;
pub const vector_format: vk.Format = .r16g16_sfixed5_nv;
/// Shaders read copies of the vectors in a plain integer format (S10.5 values, /32 in the
/// shader), so how drivers convert SFIXED5 on sampling does not matter.
const sampled_vector_format: vk.Format = .r16g16_sint;
const cost_format: vk.Format = .r8_uint;

pub const ref = 0;
pub const input = 1;

pub const Slot = struct {
    session: vk.OpticalFlowSessionNV = .null,
    /// Forward: B (input) -> A (reference); backward: A -> B, for consistency checks.
    vectors: Target = .{},
    cost: Target = .{},
    back_vectors: Target = .{},
    back_cost: Target = .{},
    /// Integer copies of `vectors` / `back_vectors`, sampled by shaders.
    vectors_int: Target = .{},
    back_vectors_int: Target = .{},
    cmd: vk.CommandBuffer = undefined,
    /// Frame pair (pts of A, B) estimated into this slot, and when it is ready.
    key: [2]i64 = .{ -1, -1 },
    ready: u64 = 0,
};

pub const Target = struct {
    image: vk.Image = .null,
    memory: vk.DeviceMemory = .null,
    /// For optical flow bindings and rendering.
    view: vk.ImageView = .null,
    /// For sampling (vectors/cost), through the descriptor heap.
    slot: ?vk_core.DescriptorHeaps.ImageSlot = null,
};

device: *vk_core.Device,
heaps: *vk_core.DescriptorHeaps,
/// Estimation size (pixels) and the vector grid size (blocks).
width: u32,
height: u32,
luma: [2]Target,
/// Sampled views of the luma images (debug display).
luma_slot: [2]vk_core.DescriptorHeaps.ImageSlot = undefined,
slots: [2]Slot,
pool: vk.CommandPool,
sem: vk.Semaphore,
/// Last value signalled (or to be signalled) on `sem`.
value: u64 = 0,
/// Images still need their first transition to GENERAL.
fresh: bool = true,

pub fn supported(device: *const vk_core.Device) bool {
    return device.flow_queue != null;
}

/// Estimation size for a video of `w`×`h`, inside the accelerator's limits.
pub fn sizeFor(device: *const vk_core.Device, w: u32, h: u32) [2]u32 {
    const p = device.flow_props.?;
    const limit = @min(max_width, p.max_width);
    var fw = @min(w, limit);
    var fh: u32 = @intCast(@as(u64, h) * fw / w);
    if (fh > p.max_height) {
        fh = p.max_height;
        fw = @intCast(@as(u64, w) * fh / h);
    }
    return .{ @max(p.min_width, fw & ~@as(u32, 3)), @max(p.min_height, fh & ~@as(u32, 3)) };
}

pub fn create(gpa: std.mem.Allocator, device: *vk_core.Device, heaps: *vk_core.DescriptorHeaps, width: u32, height: u32) !*Flow {
    const dev = device.proxy;
    const props = device.flow_props.?;
    if (!props.supported_output_grid_sizes.@"4x4_nv") return error.OpticalFlowGridUnsupported;
    if (props.cost_supported != .true) return error.OpticalFlowCostUnsupported;
    if (props.bidirectional_flow_supported != .true) return error.OpticalFlowBidirectionalUnsupported;
    try checkFormat(device, .{ .input_nv = true }, luma_format);
    try checkFormat(device, .{ .output_nv = true }, vector_format);
    try checkFormat(device, .{ .cost_nv = true }, cost_format);

    const self = try gpa.create(Flow);
    errdefer gpa.destroy(self);
    self.* = .{
        .device = device,
        .heaps = heaps,
        .width = width,
        .height = height,
        .luma = .{ .{}, .{} },
        .slots = .{ .{}, .{} },
        .pool = .null,
        .sem = .null,
    };
    errdefer self.destroyResources();

    const families = [_]u32{ device.queue_family, device.flow_family.? };
    for (&self.luma, &self.luma_slot) |*l, *slot| {
        l.* = try makeTarget(device, &families, .{ .input_nv = true }, luma_format, &.{}, .{ .color_attachment = true, .sampled = true }, width, height);
        slot.* = try heaps.addImageView(viewInfo(l.image, luma_format));
    }
    const gw = (width + grid - 1) / grid;
    const gh = (height + grid - 1) / grid;
    self.pool = try dev.createCommandPool(&.{ .queue_family_index = device.flow_family.? }, null);
    for (&self.slots) |*s| {
        // SFIXED5 is directly sampleable: reads return pixels as floats.
        for ([_]*Target{ &s.vectors, &s.back_vectors }, [_]*Target{ &s.vectors_int, &s.back_vectors_int }) |t, ti| {
            t.* = try makeTarget(device, &families, .{ .output_nv = true }, vector_format, &.{}, .{ .transfer_src = true, .sampled = true, .host_transfer = true }, gw, gh);
            ti.* = try makeTarget(device, &families, null, sampled_vector_format, &.{}, .{ .transfer_dst = true, .sampled = true }, gw, gh);
            ti.slot = try heaps.addImageView(viewInfo(ti.image, sampled_vector_format));
        }
        for ([_]*Target{ &s.cost, &s.back_cost }) |t| {
            t.* = try makeTarget(device, &families, .{ .cost_nv = true }, cost_format, &.{}, .{ .sampled = true }, gw, gh);
            t.slot = try heaps.addImageView(viewInfo(t.image, cost_format));
        }
        try self.initSession(s);
    }

    const type_info: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = .timeline, .initial_value = 0 };
    self.sem = try dev.createSemaphore(&.{ .p_next = &type_info }, null);
    log.info("optical flow {d}x{d} -> {d}x{d} vectors (4x4 grid, cost, bidirectional, 2 slots)", .{ width, height, gw, gh });
    return self;
}

fn initSession(self: *Flow, s: *Slot) !void {
    const dev = self.device.proxy;
    s.session = try dev.createOpticalFlowSessionNV(&.{
        .width = self.width,
        .height = self.height,
        .image_format = luma_format,
        .flow_vector_format = vector_format,
        .cost_format = cost_format,
        .output_grid_size = .{ .@"4x4_nv" = true },
        .performance_level = .medium_nv,
        .flags = .{ .enable_cost_nv = true, .both_directions_nv = true },
    }, null);
    try dev.bindOpticalFlowSessionImageNV(s.session, .input_nv, self.luma[input].view, .general);
    try dev.bindOpticalFlowSessionImageNV(s.session, .reference_nv, self.luma[ref].view, .general);
    try dev.bindOpticalFlowSessionImageNV(s.session, .flow_vector_nv, s.vectors.view, .general);
    try dev.bindOpticalFlowSessionImageNV(s.session, .cost_nv, s.cost.view, .general);
    try dev.bindOpticalFlowSessionImageNV(s.session, .backward_flow_vector_nv, s.back_vectors.view, .general);
    try dev.bindOpticalFlowSessionImageNV(s.session, .backward_cost_nv, s.back_cost.view, .general);

    // The execution never changes (fixed bindings), so it is recorded once and resubmitted.
    var cmd: [1]vk.CommandBuffer = undefined;
    try dev.allocateCommandBuffers(&.{ .command_pool = self.pool, .level = .primary, .command_buffer_count = 1 }, &cmd);
    s.cmd = cmd[0];
    const c = vk.CommandBufferProxy.init(s.cmd, dev.wrapper);
    try c.beginCommandBuffer(&.{ .flags = .{ .simultaneous_use = true } });
    c.opticalFlowExecuteNV(s.session, &.{});
    const gw = (self.width + grid - 1) / grid;
    const gh = (self.height + grid - 1) / grid;
    const mb = [_]vk.MemoryBarrier2{.{
        .src_stage_mask = .{ .optical_flow_nv = true },
        .src_access_mask = .{ .optical_flow_write_nv = true },
        .dst_stage_mask = .{ .copy = true },
        .dst_access_mask = .{ .transfer_read = true },
    }};
    c.pipelineBarrier2(&.{ .memory_barrier_count = mb.len, .p_memory_barriers = &mb });
    const layers: vk.ImageSubresourceLayers = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 };
    for ([_]*const Target{ &s.vectors, &s.back_vectors }, [_]*const Target{ &s.vectors_int, &s.back_vectors_int }) |src, dst| {
        c.copyImage(src.image, .general, dst.image, .general, &.{.{
            .src_subresource = layers,
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = layers,
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = gw, .height = gh, .depth = 1 },
        }});
    }
    try c.endCommandBuffer();
}

/// Debug: waits for `s` and logs statistics of its raw forward vectors (int16 S10.5).
pub fn dumpStats(self: *Flow, s: *const Slot) void {
    const dev = self.device.proxy;
    _ = dev.waitSemaphores(&.{ .semaphore_count = 1, .p_semaphores = &.{self.sem}, .p_values = &.{s.ready} }, std.math.maxInt(u64)) catch return;
    const gw = (self.width + grid - 1) / grid;
    const gh = (self.height + grid - 1) / grid;
    const buf = std.heap.page_allocator.alloc([2]i16, gw * gh) catch return;
    defer std.heap.page_allocator.free(buf);
    dev.copyImageToMemory(&.{
        .src_image = s.vectors.image,
        .src_image_layout = .general,
        .region_count = 1,
        .p_regions = &.{.{
            .p_host_pointer = buf.ptr,
            .memory_row_length = 0,
            .memory_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = gw, .height = gh, .depth = 1 },
        }},
    }) catch |err| {
        log.err("dump: {t}", .{err});
        return;
    };
    var max: i32 = 0;
    var sum: f64 = 0;
    var zero: usize = 0;
    for (buf) |v| {
        const m = @max(@abs(@as(i32, v[0])), @abs(@as(i32, v[1])));
        max = @max(max, @as(i32, @intCast(m)));
        sum += @floatFromInt(m);
        if (m == 0) zero += 1;
    }
    const c = buf[(gh / 2) * gw + gw / 2];
    log.info("vectors raw: max |v| {d} ({d:.1} px), mean {d:.2} px, {d}% zero, center ({d}, {d})", .{
        max, @as(f64, @floatFromInt(max)) / 32.0, sum / @as(f64, @floatFromInt(buf.len)) / 32.0, zero * 100 / buf.len, c[0], c[1],
    });
}

/// The slot holding vectors for `key`, if estimated (or being estimated).
pub fn find(self: *Flow, key: [2]i64) ?*Slot {
    for (&self.slots) |*s| if (std.mem.eql(i64, &s.key, &key)) return s;
    return null;
}

/// The device must not be using any of it.
pub fn destroy(self: *Flow, gpa: std.mem.Allocator) void {
    self.destroyResources();
    gpa.destroy(self);
}

fn destroyResources(self: *Flow) void {
    const dev = self.device.proxy;
    dev.destroySemaphore(self.sem, null);
    dev.destroyCommandPool(self.pool, null);
    for (&self.slots) |*s| dev.destroyOpticalFlowSessionNV(s.session, null);
    for (self.luma_slot) |slot| self.heaps.removeImage(slot);
    var targets: [2 + 6 * 2]*Target = undefined;
    targets[0] = &self.luma[0];
    targets[1] = &self.luma[1];
    for (&self.slots, 0..) |*s, i| {
        targets[2 + 6 * i ..][0..6].* = .{ &s.vectors, &s.cost, &s.back_vectors, &s.back_cost, &s.vectors_int, &s.back_vectors_int };
    }
    for (targets) |t| {
        if (t.slot) |s| self.heaps.removeImage(s);
        dev.destroyImageView(t.view, null);
        dev.destroyImage(t.image, null);
        dev.freeMemory(t.memory, null);
    }
}

/// Records the first-use transition of all images to GENERAL (graphics queue).
pub fn initLayouts(self: *Flow, cmd: vk.CommandBufferProxy) void {
    if (!self.fresh) return;
    self.fresh = false;
    var images: [2 + 6 * 2]vk.Image = undefined;
    images[0] = self.luma[0].image;
    images[1] = self.luma[1].image;
    for (&self.slots, 0..) |*s, i| {
        images[2 + 6 * i ..][0..6].* = .{ s.vectors.image, s.cost.image, s.back_vectors.image, s.back_cost.image, s.vectors_int.image, s.back_vectors_int.image };
    }
    for (images) |img| {
        vk_core.barrier.image(cmd, .{
            .image = img,
            .old_layout = .undefined,
            .new_layout = .general,
            .dst_stage = .{ .all_commands = true },
            .dst_access = .{ .memory_read = true, .memory_write = true },
        });
    }
}

/// Reserves the semaphore values of one estimation: graphics signals `.luma_done` after
/// writing the luma images; `.flow_done` is reached when the vectors are ready.
pub fn reserve(self: *Flow) struct { luma_done: u64, flow_done: u64 } {
    self.value += 2;
    return .{ .luma_done = self.value - 1, .flow_done = self.value };
}

/// Queues the estimation (after the graphics submission that signals `luma_done`).
pub fn execute(self: *Flow, s: *const Slot, luma_done: u64) !void {
    const q = self.device.flow_queue.?;
    try q.submit2(&.{.{
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = &.{.{ .semaphore = self.sem, .value = luma_done, .stage_mask = .{ .all_commands = true }, .device_index = 0 }},
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &.{.{ .command_buffer = s.cmd, .device_mask = 0 }},
        .signal_semaphore_info_count = 1,
        .p_signal_semaphore_infos = &.{.{ .semaphore = self.sem, .value = luma_done + 1, .stage_mask = .{ .all_commands = true }, .device_index = 0 }},
    }}, .null);
}

fn checkFormat(device: *vk_core.Device, usage: vk.OpticalFlowUsageFlagsNV, want: vk.Format) !void {
    const vki = device.instance.proxy;
    var count: u32 = 0;
    _ = try vki.getPhysicalDeviceOpticalFlowImageFormatsNV(device.pdev, &.{ .usage = usage }, &count, null);
    var buf: [32]vk.OpticalFlowImageFormatPropertiesNV = undefined;
    for (&buf) |*b| b.* = .{ .format = .undefined };
    count = @min(count, buf.len);
    _ = try vki.getPhysicalDeviceOpticalFlowImageFormatsNV(device.pdev, &.{ .usage = usage }, &count, &buf);
    for (buf[0..count]) |p| if (p.format == want) return;
    for (buf[0..count]) |p| log.info("optical flow usage {any}: supports {t}", .{ usage, p.format });
    return error.OpticalFlowFormatUnsupported;
}

fn viewInfo(image: vk.Image, format: vk.Format) vk.ImageViewCreateInfo {
    return .{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = vk_core.Image.color_range,
    };
}

fn makeTarget(
    device: *vk_core.Device,
    families: []const u32,
    of_usage: ?vk.OpticalFlowUsageFlagsNV,
    format: vk.Format,
    view_formats: []const vk.Format,
    usage: vk.ImageUsageFlags,
    width: u32,
    height: u32,
) !Target {
    const dev = device.proxy;
    var t: Target = .{};
    errdefer {
        dev.destroyImageView(t.view, null);
        dev.destroyImage(t.image, null);
        dev.freeMemory(t.memory, null);
    }
    var formats_buf: [4]vk.Format = undefined;
    formats_buf[0] = format;
    @memcpy(formats_buf[1..][0..view_formats.len], view_formats);
    const format_list: vk.ImageFormatListCreateInfo = .{ .view_format_count = @intCast(1 + view_formats.len), .p_view_formats = &formats_buf };
    const list_next: ?*const anyopaque = if (view_formats.len > 0) &format_list else null;
    const of_info: vk.OpticalFlowImageFormatInfoNV = .{
        .p_next = @constCast(list_next),
        .usage = of_usage orelse .{},
    };
    t.image = try dev.createImage(&.{
        .p_next = if (of_usage != null) &of_info else list_next,
        .flags = .{ .mutable_format = view_formats.len > 0 },
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .concurrent,
        .queue_family_index_count = @intCast(families.len),
        .p_queue_family_indices = families.ptr,
        .initial_layout = .undefined,
    }, null);
    const reqs = dev.getImageMemoryRequirements(t.image);
    t.memory = try mem.allocate(dev, &device.memory, reqs, .{});
    try dev.bindImageMemory(t.image, t.memory, 0);
    t.view = try dev.createImageView(&viewInfo(t.image, format), null);
    return t;
}
