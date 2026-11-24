//! A ring of per-frame command buffers, each with a binary "done" semaphore and the device
//! timeline value it signals. Reuse is gated on the timeline, never on fences.
const FrameRing = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");

pub const frames_in_flight = 3;

pub const Frame = struct {
    cmd: vk.CommandBuffer,
    /// Binary semaphore signalled with the frame (optionally SYNC_FD-exportable).
    done: vk.Semaphore,
    /// Device timeline value signalled when this frame's work completes.
    value: u64 = 0,

    pub fn commands(f: *const Frame, device: *Device) vk.CommandBufferProxy {
        return vk.CommandBufferProxy.init(f.cmd, &device.vkd);
    }
};

device: *Device,
pool: vk.CommandPool,
frames: [frames_in_flight]Frame,
index: usize = 0,

pub const Options = struct {
    /// Make `Frame.done` exportable as a sync_file.
    export_sync_fd: bool = false,
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

    var self: FrameRing = .{ .device = device, .pool = pool, .frames = undefined };
    var created: usize = 0;
    errdefer for (self.frames[0..created]) |f| dev.destroySemaphore(f.done, null);
    const export_info: vk.ExportSemaphoreCreateInfo = .{ .handle_types = .{ .sync_fd = true } };
    for (&self.frames, cmds) |*f, cmd| {
        f.* = .{
            .cmd = cmd,
            .done = try dev.createSemaphore(&.{ .p_next = if (opts.export_sync_fd) &export_info else null }, null),
        };
        created += 1;
    }
    return self;
}

/// The device must be idle.
pub fn deinit(self: *FrameRing) void {
    const dev = self.device.proxy;
    for (self.frames) |f| dev.destroySemaphore(f.done, null);
    dev.destroyCommandPool(self.pool, null);
}

/// The next frame if its previous use has completed, with its command buffer reset and
/// begun; null if the GPU is still busy with it.
pub fn begin(self: *FrameRing, completed_value: u64) !?*Frame {
    const f = &self.frames[self.index];
    if (completed_value < f.value) return null;
    const cmd = f.commands(self.device);
    try cmd.resetCommandBuffer(.{});
    try cmd.beginCommandBuffer(&.{ .flags = .{ .one_time_submit = true } });
    return f;
}

/// Ends and submits `f` (from `begin`), signalling its `done` semaphore and the device
/// timeline. Returns the timeline value that marks its completion.
pub fn submit(self: *FrameRing, f: *Frame) !u64 {
    const device = self.device;
    try f.commands(device).endCommandBuffer();
    f.value = device.nextValue();
    const signals = [_]vk.SemaphoreSubmitInfo{
        .{ .semaphore = f.done, .value = 0, .stage_mask = .{ .all_commands = true }, .device_index = 0 },
        .{ .semaphore = device.timeline, .value = f.value, .stage_mask = .{ .all_commands = true }, .device_index = 0 },
    };
    try device.queue.submit2(&.{.{
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &.{.{ .command_buffer = f.cmd, .device_mask = 0 }},
        .signal_semaphore_info_count = signals.len,
        .p_signal_semaphore_infos = &signals,
    }}, .null);
    self.index = (self.index + 1) % frames_in_flight;
    return f.value;
}
