//! Motion estimation between consecutive video frames on NVIDIA's optical flow accelerator
//! (VK_NV_optical_flow), used for motion-compensated frame interpolation.
//!
//! Per frame pair (A shown, B next), the graphics queue renders both frames' luma at the
//! estimation size and at half of it. The optical-flow queue then runs:
//!   1. a coarse pass at half resolution (forward only). Its 4×4-grid vectors line up 1:1
//!      with the full pass's 8×8 hint grid, so the coarse field is bound directly as hints:
//!      the full pass searches around them, which roughly doubles the reachable motion;
//!   2. the full pass: bidirectional 4×4-grid vectors, costs and a global (camera) vector.
//! Results are copied into one of two slots (integer formats, read by shaders), so the
//! pair after the shown one can be estimated ahead. One session per pass sees every pair
//! in order, so the accelerator's temporal hints come from the previous pair.
//!
//! All images are CONCURRENT between the two families and stay in GENERAL; ordering is one
//! timeline semaphore: graphics signals `2n+1`, optical flow waits on it and signals
//! `2n+2`, and draws that sample a slot wait on its `ready` value.
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
/// shader): sampling SFIXED5 directly returns unscaled values on NVIDIA.
const sampled_vector_format: vk.Format = .r16g16_sint;
const cost_format: vk.Format = .r8_uint;

pub const ref = 0;
pub const input = 1;

/// Shader-readable results of one estimation.
pub const Slot = struct {
    /// Forward B (input) -> A (reference), backward A -> B, forward cost, global vector.
    vectors: Target = .{},
    back_vectors: Target = .{},
    cost: Target = .{},
    global: Target = .{},
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
    /// For sampling, through the descriptor heap.
    slot: ?vk_core.DescriptorHeaps.ImageSlot = null,
};

device: *vk_core.Device,
heaps: *vk_core.DescriptorHeaps,
/// Estimation size (pixels); the coarse pass runs at half of it.
width: u32,
height: u32,
luma: [2]Target,
coarse_luma: [2]Target,
/// Sampled views of the luma images (debug display).
luma_slot: [2]vk_core.DescriptorHeaps.ImageSlot = undefined,
coarse_session: vk.OpticalFlowSessionNV = .null,
session: vk.OpticalFlowSessionNV = .null,
/// Coarse vectors, copied into `hints` (an image cannot be both output and hint).
coarse_vectors: Target = .{},
hints: Target = .{},
/// Full-pass outputs, copied into a slot after each run.
out_vectors: Target = .{},
out_back_vectors: Target = .{},
out_cost: Target = .{},
out_back_cost: Target = .{},
out_global: Target = .{},
slots: [2]Slot,
/// Interpolation accumulator: vec4 (color * weight, weight) per estimation pixel.
accum: vk_core.Buffer = .{},
pool: vk.CommandPool = .null,
sem: vk.Semaphore = .null,
/// Last value signalled (or to be signalled) on `sem`.
value: u64 = 0,
/// Images still need their first transition to GENERAL.
fresh: bool = true,

pub fn supported(device: *const vk_core.Device) bool {
    return device.flow_queue != null;
}

/// Estimation size for a video of `w`×`h`, inside the accelerator's limits; a multiple of
/// 16 so the coarse grid and the hint grid line up exactly.
pub fn sizeFor(device: *const vk_core.Device, w: u32, h: u32) [2]u32 {
    const p = device.flow_props.?;
    const limit = @min(max_width, p.max_width);
    var fw = @min(w, limit);
    var fh: u32 = @intCast(@as(u64, h) * fw / w);
    if (fh > p.max_height) {
        fh = p.max_height;
        fw = @intCast(@as(u64, w) * fh / h);
    }
    const min = 2 * @max(p.min_width, p.min_height);
    return .{ @max(min, fw & ~@as(u32, 15)), @max(min, fh & ~@as(u32, 15)) };
}

pub fn gridSize(self: *const Flow) [2]u32 {
    return .{ self.width / grid, self.height / grid };
}

pub fn create(gpa: std.mem.Allocator, device: *vk_core.Device, heaps: *vk_core.DescriptorHeaps, width: u32, height: u32) !*Flow {
    const dev = device.proxy;
    const props = device.flow_props.?;
    if (!props.supported_output_grid_sizes.@"4x4_nv") return error.OpticalFlowGridUnsupported;
    if (!props.supported_hint_grid_sizes.@"8x8_nv" or props.hint_supported != .true) return error.OpticalFlowHintUnsupported;
    if (props.cost_supported != .true) return error.OpticalFlowCostUnsupported;
    if (props.bidirectional_flow_supported != .true) return error.OpticalFlowBidirectionalUnsupported;
    if (props.global_flow_supported != .true) return error.OpticalFlowGlobalUnsupported;
    try checkFormat(device, .{ .input_nv = true }, luma_format);
    try checkFormat(device, .{ .output_nv = true }, vector_format);
    try checkFormat(device, .{ .hint_nv = true }, vector_format);
    try checkFormat(device, .{ .global_flow_nv = true }, vector_format);
    try checkFormat(device, .{ .cost_nv = true }, cost_format);

    const self = try gpa.create(Flow);
    errdefer gpa.destroy(self);
    self.* = .{
        .device = device,
        .heaps = heaps,
        .width = width,
        .height = height,
        .luma = .{ .{}, .{} },
        .coarse_luma = .{ .{}, .{} },
        .slots = .{ .{}, .{} },
    };
    errdefer self.destroyResources();

    const families = [_]u32{ device.queue_family, device.flow_family.? };
    const g = self.gridSize();
    for (&self.luma, &self.coarse_luma, &self.luma_slot) |*l, *cl, *slot| {
        l.* = try makeTarget(device, &families, .{ .input_nv = true }, luma_format, .{ .color_attachment = true, .sampled = true }, width, height);
        cl.* = try makeTarget(device, &families, .{ .input_nv = true }, luma_format, .{ .color_attachment = true }, width / 2, height / 2);
        slot.* = try heaps.addImageView(viewInfo(l.image, luma_format));
    }
    const out: vk.ImageUsageFlags = .{ .transfer_src = true, .sampled = true, .host_transfer = true };
    self.coarse_vectors = try makeTarget(device, &families, .{ .output_nv = true }, vector_format, .{ .transfer_src = true, .sampled = true }, g[0] / 2, g[1] / 2);
    self.hints = try makeTarget(device, &families, .{ .hint_nv = true }, vector_format, .{ .transfer_dst = true, .sampled = true }, g[0] / 2, g[1] / 2);
    self.out_vectors = try makeTarget(device, &families, .{ .output_nv = true }, vector_format, out, g[0], g[1]);
    self.out_back_vectors = try makeTarget(device, &families, .{ .output_nv = true }, vector_format, out, g[0], g[1]);
    self.out_cost = try makeTarget(device, &families, .{ .cost_nv = true }, cost_format, out, g[0], g[1]);
    self.out_back_cost = try makeTarget(device, &families, .{ .cost_nv = true }, cost_format, out, g[0], g[1]);
    self.out_global = try makeTarget(device, &families, .{ .global_flow_nv = true }, vector_format, out, 1, 1);

    const copy_dst: vk.ImageUsageFlags = .{ .transfer_dst = true, .sampled = true };
    for (&self.slots) |*s| {
        s.vectors = try makeTarget(device, &families, null, sampled_vector_format, copy_dst, g[0], g[1]);
        s.back_vectors = try makeTarget(device, &families, null, sampled_vector_format, copy_dst, g[0], g[1]);
        s.cost = try makeTarget(device, &families, null, cost_format, copy_dst, g[0], g[1]);
        s.global = try makeTarget(device, &families, null, sampled_vector_format, copy_dst, 1, 1);
        for ([_]*Target{ &s.vectors, &s.back_vectors, &s.cost, &s.global }) |t| t.slot = try heaps.addImageView(viewInfo(t.image, if (t == &s.cost) cost_format else sampled_vector_format));
    }

    self.accum = try vk_core.Buffer.create(device, .{
        .size = (@as(u64, width) * height + 1) * 16, // + frame-level reliability counter
        .usage = .{ .storage_buffer = true, .transfer_dst = true, .shader_device_address = true },
    });

    // Coarse pass: half resolution, forward vectors only (the full pass's hints).
    self.coarse_session = try dev.createOpticalFlowSessionNV(&.{
        .width = width / 2,
        .height = height / 2,
        .image_format = luma_format,
        .flow_vector_format = vector_format,
        .cost_format = .undefined,
        .output_grid_size = .{ .@"4x4_nv" = true },
        .performance_level = .medium_nv,
    }, null);
    try dev.bindOpticalFlowSessionImageNV(self.coarse_session, .input_nv, self.coarse_luma[input].view, .general);
    try dev.bindOpticalFlowSessionImageNV(self.coarse_session, .reference_nv, self.coarse_luma[ref].view, .general);
    try dev.bindOpticalFlowSessionImageNV(self.coarse_session, .flow_vector_nv, self.coarse_vectors.view, .general);

    // Full pass: hinted, bidirectional, with costs and the global vector.
    self.session = try dev.createOpticalFlowSessionNV(&.{
        .width = width,
        .height = height,
        .image_format = luma_format,
        .flow_vector_format = vector_format,
        .cost_format = cost_format,
        .output_grid_size = .{ .@"4x4_nv" = true },
        .hint_grid_size = .{ .@"8x8_nv" = true },
        .performance_level = .slow_nv,
        .flags = .{ .enable_hint_nv = true, .enable_cost_nv = true, .both_directions_nv = true, .enable_global_flow_nv = true },
    }, null);
    const bindings = [_]struct { vk.OpticalFlowSessionBindingPointNV, vk.ImageView }{
        .{ .input_nv, self.luma[input].view },
        .{ .reference_nv, self.luma[ref].view },
        .{ .hint_nv, self.hints.view },
        .{ .flow_vector_nv, self.out_vectors.view },
        .{ .backward_flow_vector_nv, self.out_back_vectors.view },
        .{ .cost_nv, self.out_cost.view },
        .{ .backward_cost_nv, self.out_back_cost.view },
        .{ .global_flow_nv, self.out_global.view },
    };
    for (bindings) |b| try dev.bindOpticalFlowSessionImageNV(self.session, b[0], b[1], .general);

    // Both passes and the copy into a slot never change, so they are recorded once per
    // slot and resubmitted.
    self.pool = try dev.createCommandPool(&.{ .queue_family_index = device.flow_family.? }, null);
    for (&self.slots) |*s| try self.record(s);

    const type_info: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = .timeline, .initial_value = 0 };
    self.sem = try dev.createSemaphore(&.{ .p_next = &type_info }, null);
    log.info("optical flow {d}x{d} (hinted by {d}x{d}) -> {d}x{d} vectors (4x4 grid, bidirectional, cost, global)", .{ width, height, width / 2, height / 2, g[0], g[1] });
    return self;
}

fn record(self: *Flow, s: *Slot) !void {
    const dev = self.device.proxy;
    var cmd: [1]vk.CommandBuffer = undefined;
    try dev.allocateCommandBuffers(&.{ .command_pool = self.pool, .level = .primary, .command_buffer_count = 1 }, &cmd);
    s.cmd = cmd[0];
    const c = vk.CommandBufferProxy.init(s.cmd, dev.wrapper);
    try c.beginCommandBuffer(&.{ .flags = .{ .simultaneous_use = true } });
    const layers: vk.ImageSubresourceLayers = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 };
    const g = self.gridSize();
    c.opticalFlowExecuteNV(self.coarse_session, &.{});
    memoryBarrier(c, .{ .optical_flow_nv = true }, .{ .optical_flow_write_nv = true }, .{ .copy = true }, .{ .transfer_read = true });
    c.copyImage(self.coarse_vectors.image, .general, self.hints.image, .general, &.{.{
        .src_subresource = layers,
        .src_offset = .{ .x = 0, .y = 0, .z = 0 },
        .dst_subresource = layers,
        .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
        .extent = .{ .width = g[0] / 2, .height = g[1] / 2, .depth = 1 },
    }});
    memoryBarrier(c, .{ .copy = true }, .{ .transfer_write = true }, .{ .optical_flow_nv = true }, .{ .optical_flow_read_nv = true });
    c.opticalFlowExecuteNV(self.session, &.{});
    memoryBarrier(c, .{ .optical_flow_nv = true }, .{ .optical_flow_write_nv = true }, .{ .copy = true }, .{ .transfer_read = true });
    const copies = [_]struct { *const Target, *const Target, [2]u32 }{
        .{ &self.out_vectors, &s.vectors, g },
        .{ &self.out_back_vectors, &s.back_vectors, g },
        .{ &self.out_cost, &s.cost, g },
        .{ &self.out_global, &s.global, .{ 1, 1 } },
    };
    for (copies) |cp| c.copyImage(cp[0].image, .general, cp[1].image, .general, &.{.{
        .src_subresource = layers,
        .src_offset = .{ .x = 0, .y = 0, .z = 0 },
        .dst_subresource = layers,
        .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
        .extent = .{ .width = cp[2][0], .height = cp[2][1], .depth = 1 },
    }});
    try c.endCommandBuffer();
}

fn memoryBarrier(c: vk.CommandBufferProxy, src_stage: vk.PipelineStageFlags2, src_access: vk.AccessFlags2, dst_stage: vk.PipelineStageFlags2, dst_access: vk.AccessFlags2) void {
    const mb = [_]vk.MemoryBarrier2{.{ .src_stage_mask = src_stage, .src_access_mask = src_access, .dst_stage_mask = dst_stage, .dst_access_mask = dst_access }};
    c.pipelineBarrier2(&.{ .memory_barrier_count = mb.len, .p_memory_barriers = &mb });
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

fn targets(self: *Flow) [4 + 7 + 4 * 2]*Target {
    var t: [4 + 7 + 4 * 2]*Target = undefined;
    t[0..11].* = .{ &self.luma[0], &self.luma[1], &self.coarse_luma[0], &self.coarse_luma[1], &self.coarse_vectors, &self.hints, &self.out_vectors, &self.out_back_vectors, &self.out_cost, &self.out_back_cost, &self.out_global };
    for (&self.slots, 0..) |*s, i| t[11 + 4 * i ..][0..4].* = .{ &s.vectors, &s.back_vectors, &s.cost, &s.global };
    return t;
}

fn destroyResources(self: *Flow) void {
    const dev = self.device.proxy;
    dev.destroySemaphore(self.sem, null);
    self.accum.deinit(self.device);
    dev.destroyCommandPool(self.pool, null);
    dev.destroyOpticalFlowSessionNV(self.session, null);
    dev.destroyOpticalFlowSessionNV(self.coarse_session, null);
    for (self.targets()) |t| {
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
    for (self.targets()) |t| {
        if (t.image == .null) continue;
        vk_core.barrier.image(cmd, .{
            .image = t.image,
            .old_layout = .undefined,
            .new_layout = .general,
            .dst_stage = .{ .all_commands = true },
            .dst_access = .{ .memory_read = true, .memory_write = true },
        });
    }
}

/// Reserves the semaphore values of one estimation: graphics signals `.luma_done` after
/// writing the luma images; `.flow_done` is reached when the slot is filled.
pub fn reserve(self: *Flow) struct { luma_done: u64, flow_done: u64 } {
    self.value += 2;
    return .{ .luma_done = self.value - 1, .flow_done = self.value };
}

/// Queues the estimation into `s` (after the graphics submission that signals `luma_done`).
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

/// Debug: waits for `s` and logs statistics of the full pass's raw forward vectors
/// (int16 S10.5) and the global vector, plus how long the estimation took.
pub fn dumpStats(self: *Flow, s: *const Slot) void {
    const dev = self.device.proxy;
    _ = dev.waitSemaphores(&.{ .semaphore_count = 1, .p_semaphores = &.{self.sem}, .p_values = &.{s.ready} }, std.math.maxInt(u64)) catch return;
    const g = self.gridSize();
    const buf = std.heap.page_allocator.alloc([2]i16, g[0] * g[1]) catch return;
    defer std.heap.page_allocator.free(buf);
    var global: [2]i16 = undefined;
    for ([_]struct { *const Target, *anyopaque, [2]u32 }{ .{ &self.out_vectors, buf.ptr, g }, .{ &self.out_global, &global, .{ 1, 1 } } }) |r| {
        dev.copyImageToMemory(&.{
            .src_image = r[0].image,
            .src_image_layout = .general,
            .region_count = 1,
            .p_regions = &.{.{
                .p_host_pointer = r[1],
                .memory_row_length = 0,
                .memory_image_height = 0,
                .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .image_extent = .{ .width = r[2][0], .height = r[2][1], .depth = 1 },
            }},
        }) catch |err| {
            log.err("dump: {t}", .{err});
            return;
        };
    }
    var max: i32 = 0;
    var sum: f64 = 0;
    for (buf) |v| {
        const m: i32 = @intCast(@max(@abs(@as(i32, v[0])), @abs(@as(i32, v[1]))));
        max = @max(max, m);
        sum += @floatFromInt(m);
    }
    log.info("vectors: max {d:.1} px, mean {d:.2} px, global ({d:.1}, {d:.1}) px", .{
        @as(f64, @floatFromInt(max)) / 32.0,
        sum / @as(f64, @floatFromInt(buf.len)) / 32.0,
        @as(f64, @floatFromInt(global[0])) / 32.0,
        @as(f64, @floatFromInt(global[1])) / 32.0,
    });
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
    const of_info: vk.OpticalFlowImageFormatInfoNV = .{ .usage = of_usage orelse .{} };
    t.image = try dev.createImage(&.{
        .p_next = if (of_usage != null) &of_info else null,
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
