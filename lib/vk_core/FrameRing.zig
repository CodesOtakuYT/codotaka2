//! A ring of per-frame command buffers, each with a binary "done" semaphore and the device
//! timeline value it signals. Reuse is gated on the timeline, never on fences.
const FrameRing = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const Buffer = @import("Buffer.zig");

pub const frames_in_flight = 3;

pub const Frame = struct {
    cmd: vk.CommandBuffer,
    /// Binary semaphore signalled with the frame (optionally SYNC_FD-exportable).
    done: vk.Semaphore,
    /// Device timeline value signalled when this frame's work completes.
    value: u64 = 0,
    /// Per-frame transient data (instances, uniforms) addressed from shaders by device
    /// address; reset when the frame is reused.
    upload: Buffer.Linear,

    pub fn commands(f: *const Frame, device: *Device) vk.CommandBufferProxy {
        return vk.CommandBufferProxy.init(f.cmd, &device.vkd);
    }
};

device: *Device,
pool: vk.CommandPool,
frames: [frames_in_flight]Frame,
index: usize = 0,
signal_done: bool = true,

pub const Options = struct {
    /// Make `Frame.done` exportable as a sync_file.
    export_sync_fd: bool = false,
    /// Size of each frame's transient upload buffer.
    upload_size: u64 = 4 << 20,
    /// Signal each frame's binary `done` semaphore (consumed by presentation); offscreen
    /// users only need the device timeline.
    signal_done: bool = true,
};

pub fn init(device: *Device, opts: Options) !FrameRing {
    const dev = device.proxy;
    const pool = try dev.createCommandPool(&.{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = device.queue_family,
    }, null);
    errdefer dev.destroyCommandPool(pool, null);

    var cmds: [frames_in_flight]vk.CommandBuffer = undefined;
    try dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = frames_in_flight,
    }, &cmds);

    var self: FrameRing = .{ .device = device, .pool = pool, .frames = undefined, .signal_done = opts.signal_done };
    var created: usize = 0;
    errdefer for (self.frames[0..created]) |*f| destroyFrame(device, f);
    const export_info: vk.ExportSemaphoreCreateInfo = .{ .handle_types = .{ .sync_fd = true } };
    for (&self.frames, cmds) |*f, cmd| {
        var upload = try Buffer.create(device, .{
            .size = opts.upload_size,
            .usage = .{ .storage_buffer = true, .shader_device_address = true },
            .host_visible = true,
        });
        errdefer upload.deinit(device);
        f.* = .{
            .cmd = cmd,
            .done = try dev.createSemaphore(&.{ .p_next = if (opts.export_sync_fd) &export_info else null }, null),
            .upload = .{ .buffer = upload },
        };
        created += 1;
    }
    return self;
}

fn destroyFrame(device: *Device, f: *Frame) void {
    device.proxy.destroySemaphore(f.done, null);
    f.upload.buffer.deinit(device);
}

/// The device must be idle.
pub fn deinit(self: *FrameRing) void {
    for (&self.frames) |*f| destroyFrame(self.device, f);
    self.device.proxy.destroyCommandPool(self.pool, null);
}

/// The next frame if its previous use has completed, with its command buffer reset and
/// begun; null if the GPU is still busy with it.
pub fn begin(self: *FrameRing, completed_value: u64) !?*Frame {
    const f = &self.frames[self.index];
    if (completed_value < f.value) return null;
    f.upload.reset();
    const cmd = f.commands(self.device);
    try cmd.resetCommandBuffer(.{});
    try cmd.beginCommandBuffer(&.{ .flags = .{ .one_time_submit = true } });
    return f;
}

/// Extra semaphores for a frame's submission (e.g. other libraries' timelines).
pub const Sync = struct {
    pub const max = 32;
    waits: [max]vk.SemaphoreSubmitInfo = undefined,
    wait_count: u32 = 0,
    signals: [max]vk.SemaphoreSubmitInfo = undefined,
    signal_count: u32 = 0,

    pub fn wait(s: *Sync, semaphore: vk.Semaphore, value: u64, stage: vk.PipelineStageFlags2) !void {
        if (s.wait_count == max) return error.TooManySemaphores;
        s.waits[s.wait_count] = .{ .semaphore = semaphore, .value = value, .stage_mask = stage, .device_index = 0 };
        s.wait_count += 1;
    }

    pub fn signal(s: *Sync, semaphore: vk.Semaphore, value: u64) !void {
        if (s.signal_count + 2 >= max) return error.TooManySemaphores;
        s.signals[s.signal_count] = .{ .semaphore = semaphore, .value = value, .stage_mask = .{ .all_commands = true }, .device_index = 0 };
        s.signal_count += 1;
    }
};

/// Ends and submits `f` (from `begin`), signalling its `done` semaphore and the device
/// timeline plus anything in `extra`. Returns the timeline value marking its completion.
pub fn submit(self: *FrameRing, f: *Frame, extra: *Sync) !u64 {
    const device = self.device;
    try f.commands(device).endCommandBuffer();
    f.value = device.nextValue();
    if (self.signal_done) try extra.signal(f.done, 0);
    try extra.signal(device.timeline, f.value);
    try device.queue.submit2(&.{.{
        .wait_semaphore_info_count = extra.wait_count,
        .p_wait_semaphore_infos = &extra.waits,
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &.{.{ .command_buffer = f.cmd, .device_mask = 0 }},
        .signal_semaphore_info_count = extra.signal_count,
        .p_signal_semaphore_infos = &extra.signals,
    }}, .null);
    self.index = (self.index + 1) % frames_in_flight;
    return f.value;
}
