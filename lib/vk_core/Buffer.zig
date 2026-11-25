//! A buffer with its own memory, optionally host-mapped and/or device-addressable.
const Buffer = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const mem = @import("memory.zig");

buffer: vk.Buffer = .null,
memory: vk.DeviceMemory = .null,
size: u64 = 0,
/// Host mapping (host-visible buffers only).
mapped: ?[*]u8 = null,
/// Device address (when created with `shader_device_address` usage).
address: vk.DeviceAddress = 0,

pub const Options = struct {
    size: u64,
    usage: vk.BufferUsageFlags,
    /// Persistently map (host-visible + coherent memory).
    host_visible: bool = false,
    /// Prefer device-local memory even when host-visible (ReBAR).
    prefer_device_local: bool = true,
    /// GPU -> CPU readback: host-visible *cached* memory (CPU reads of uncached or
    /// device-local memory are very slow).
    readback: bool = false,
};

pub fn create(device: *Device, opts: Options) !Buffer {
    const dev = device.proxy;
    var self: Buffer = .{ .size = opts.size };
    errdefer self.deinit(device);

    self.buffer = try dev.createBuffer(&.{
        .size = opts.size,
        .usage = opts.usage,
        .sharing_mode = .exclusive,
    }, null);
    const reqs = dev.getBufferMemoryRequirements(self.buffer);
    const device_address = opts.usage.shader_device_address;
    self.memory = try mem.allocate(dev, &device.memory, reqs, .{
        .required = if (opts.readback)
            .{ .host_visible = true, .host_cached = true }
        else if (opts.host_visible) .{ .host_visible = true, .host_coherent = true } else .{ .device_local = true },
        .preferred = if (opts.readback) .{ .host_coherent = true } else if (opts.prefer_device_local) .{ .device_local = true } else .{},
        .device_address = device_address,
    });
    try dev.bindBufferMemory(self.buffer, self.memory, 0);
    if (opts.host_visible or opts.readback) self.mapped = @ptrCast(try dev.mapMemory(self.memory, 0, vk.WHOLE_SIZE, .{}));
    if (device_address) self.address = dev.getBufferDeviceAddress(&.{ .buffer = self.buffer });
    return self;
}

pub fn deinit(self: *Buffer, device: *Device) void {
    const dev = device.proxy;
    if (self.mapped != null) dev.unmapMemory(self.memory);
    dev.destroyBuffer(self.buffer, null);
    dev.freeMemory(self.memory, null);
    self.* = .{};
}

pub fn bytes(self: *const Buffer) []u8 {
    return self.mapped.?[0..self.size];
}

/// Bump allocator over a host-visible, device-addressable buffer; reset per use cycle.
pub const Linear = struct {
    buffer: Buffer,
    used: u64 = 0,

    pub fn reset(l: *Linear) void {
        l.used = 0;
    }

    /// Copies `data` in and returns its device address.
    pub fn push(l: *Linear, data: []const u8, alignment: u64) !vk.DeviceAddress {
        const offset = mem.alignForward(l.used, alignment);
        if (offset + data.len > l.buffer.size) return error.TransientBufferFull;
        @memcpy(l.buffer.bytes()[offset..][0..data.len], data);
        l.used = offset + data.len;
        return l.buffer.address + offset;
    }
};
