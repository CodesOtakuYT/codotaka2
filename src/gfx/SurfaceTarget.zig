//! A pool of presentable buffers for one wayland.Surface (root or subsurface) on one Device,
//! without VkSwapchainKHR: dmabuf-exportable images with a format+modifier chosen from the
//! surface's own dmabuf feedback tranches, wrapped as wl_buffers and synchronized with the
//! compositor through per-buffer DRM syncobj timelines.
//! It does not decide what is drawn: it only hands out Renderer.Targets.
const SurfaceTarget = @This();

const std = @import("std");
const vk = @import("vulkan");
const c = @import("c");
const Device = @import("Device.zig");
const Renderer = @import("Renderer.zig");
const wayland = @import("../wayland.zig");
const Allocator = std.mem.Allocator;

const buffer_count = 3;

pub const Buffer = struct {
    width: u32,
    height: u32,
    image: vk.Image = .null,
    memory: vk.DeviceMemory = .null,
    view: vk.ImageView = .null,
    wl_buffer: ?*c.wl_buffer = null,

    /// Per-buffer timeline shared with the compositor (acquire < release on the same timeline).
    syncobj: u32 = 0,
    wp_timeline: ?*c.wp_linux_drm_syncobj_timeline_v1 = null,
    last_point: u64 = 0,
    /// 0 = never committed. Otherwise the point the compositor signals when done with the buffer.
    release_point: u64 = 0,
    released: bool = true,
    /// Device timeline value after which our last render into this buffer completed.
    gpu_done_value: u64 = 0,

    fn modifierOf(b: *const Buffer, device: *Device) u64 {
        var props: vk.ImageDrmFormatModifierPropertiesEXT = .{ .drm_format_modifier = 0 };
        device.proxy.getImageDrmFormatModifierPropertiesEXT(b.image, &props) catch return 0;
        return props.drm_format_modifier;
    }
};

pub const Acquired = union(enum) {
    /// Every buffer is still held by the compositor; its release eventfd will fire.
    busy,
    /// A buffer was released but our GPU is still writing it.
    gpu_blocked,
    ready: *Buffer,
};

gpa: Allocator,
device: *Device,
surface: *wayland.Surface,
color: wayland.ColorMode,
/// The next attach must damage the whole buffer (new/reallocated buffers).
full_damage: bool = true,

buffers: []Buffer = &.{},
/// Old-size/old-modifier buffers waiting for the compositor and GPU to let go of them.
retired: std.ArrayList(Buffer) = .empty,

drm_format: u32 = 0,
modifier: u64 = 0,
scanout_tranche: bool = false,

/// Signalled by the kernel when any release point we registered is reached.
release_eventfd: c_int,

/// Fails with error.NoCompatibleTranche if the compositor can't take dmabufs from `device`.
pub fn create(gpa: Allocator, device: *Device, surface: *wayland.Surface, color: wayland.ColorMode) !*SurfaceTarget {
    if (device.format(color).modifiers.len == 0) return error.ColorModeUnsupportedByDevice;
    try surface.setImageDescription(try surface.display.imageDescription(color));

    const efd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    if (efd < 0) return error.EventfdFailed;
    errdefer _ = c.close(efd);

    const self = try gpa.create(SurfaceTarget);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .device = device, .surface = surface, .color = color, .release_eventfd = efd };
    // Only validate here; buffers are allocated on first acquire, once layout has sized
    // the surface.
    const choice = try self.chooseFromFeedback();
    gpa.free(choice.modifiers);
    return self;
}

pub fn destroy(self: *SurfaceTarget) void {
    self.device.waitIdle();
    self.destroyAllBuffers();
    _ = c.close(self.release_eventfd);
    self.gpa.destroy(self);
}

fn destroyAllBuffers(self: *SurfaceTarget) void {
    for (self.buffers) |*b| self.destroyBuffer(b);
    self.gpa.free(self.buffers);
    self.buffers = &.{};
    for (self.retired.items) |*b| self.destroyBuffer(b);
    self.retired.deinit(self.gpa);
}

/// Drains the release eventfd (call after it polled readable).
pub fn drainEventfd(self: *SurfaceTarget) void {
    var v: u64 = 0;
    _ = c.read(self.release_eventfd, &v, @sizeOf(u64));
}

fn isReleased(self: *SurfaceTarget, b: *Buffer) bool {
    if (b.released) return true;
    var h = b.syncobj;
    var p = b.release_point;
    // timeout 0: pure query, never blocks.
    if (c.drmSyncobjTimelineWait(self.device.drm_fd, &h, &p, 1, 0, 0, null) == 0) b.released = true;
    return b.released;
}

/// Whether the next acquire will reallocate (size, scale or feedback changed); the caller
/// must then redraw everything on this target.
pub fn needsRealloc(self: *const SurfaceTarget) bool {
    return self.surface.feedback_changed or self.surface.size_changed;
}

/// Picks a free buffer without blocking. Reallocates when the surface size or the
/// compositor's dmabuf feedback for this surface changed.
pub fn acquire(self: *SurfaceTarget, completed: u64) !Acquired {
    var i: usize = 0;
    while (i < self.retired.items.len) {
        const b = &self.retired.items[i];
        if (self.isReleased(b) and completed >= b.gpu_done_value) {
            self.destroyBuffer(b);
            _ = self.retired.swapRemove(i);
        } else i += 1;
    }

    if (self.surface.feedback_changed or self.surface.size_changed) {
        self.surface.size_changed = false;
        try self.reallocate();
    }

    var gpu_blocked = false;
    for (self.buffers) |*b| {
        if (!self.isReleased(b)) continue;
        if (completed < b.gpu_done_value) {
            gpu_blocked = true;
            continue;
        }
        return .{ .ready = b };
    }
    return if (gpu_blocked) .gpu_blocked else .busy;
}

const Choice = struct {
    tranche: *const wayland.Tranche,
    format: u32,
    modifiers: []u64,
};

/// Walks the tranches in compositor preference order (scanout tranches come first when the
/// compositor can scan us out directly) and picks the first one targeting our GPU that
/// shares a format+modifier with what the device can render and export.
fn chooseFromFeedback(self: *SurfaceTarget) !Choice {
    const format = self.device.format(self.color);
    for (self.surface.tranches.items) |*t| {
        if (!self.device.matchesDevT(t.target_device)) continue;
        for (format.drm) |fmt| {
            var mods: std.ArrayList(u64) = .empty;
            errdefer mods.deinit(self.gpa);
            for (t.formats.items) |fm| {
                if (fm.format != fmt) continue;
                if (Device.supportedModifier(format, fm.modifier) == null) continue;
                if (std.mem.indexOfScalar(u64, mods.items, fm.modifier) != null) continue;
                try mods.append(self.gpa, fm.modifier);
            }
            if (mods.items.len > 0) return .{ .tranche = t, .format = fmt, .modifiers = try mods.toOwnedSlice(self.gpa) };
            mods.deinit(self.gpa);
        }
    }
    return error.NoCompatibleTranche;
}

fn reallocate(self: *SurfaceTarget) !void {
    self.surface.feedback_changed = false;
    self.surface.size_changed = false;
    const choice = try self.chooseFromFeedback();
    defer self.gpa.free(choice.modifiers);

    // Retire current buffers; they are destroyed once released and idle.
    try self.retired.ensureUnusedCapacity(self.gpa, self.buffers.len);
    for (self.buffers) |b| self.retired.appendAssumeCapacity(b);
    self.gpa.free(self.buffers);
    self.buffers = &.{};

    const buffers = try self.gpa.alloc(Buffer, buffer_count);
    var created: usize = 0;
    errdefer {
        for (buffers[0..created]) |*b| self.destroyBuffer(b);
        self.gpa.free(buffers);
    }
    for (buffers) |*b| {
        b.* = .{ .width = self.surface.bufferWidth(), .height = self.surface.bufferHeight() };
        errdefer self.destroyBuffer(b);
        try self.createBuffer(b, choice);
        created += 1;
    }
    self.buffers = buffers;
    self.drm_format = choice.format;
    self.modifier = self.buffers[0].modifierOf(self.device);
    self.scanout_tranche = choice.tranche.scanout();
    self.full_damage = true;

    const fourcc: [4]u8 = @bitCast(choice.format);
    std.log.debug("surface {*}: {d}x{d} buffer for {d}x{d} logical, {s} modifier 0x{x:0>16}{s}", .{
        self.surface,         self.buffers[0].width, self.buffers[0].height, self.surface.width, self.surface.height,
        &fourcc,              self.modifier,
        if (self.scanout_tranche) " (scanout tranche)" else "",
    });
}

fn createBuffer(self: *SurfaceTarget, b: *Buffer, choice: Choice) !void {
    const dev = self.device.proxy;
    const instance = self.device.instance.proxy;

    const mod_list: vk.ImageDrmFormatModifierListCreateInfoEXT = .{
        .drm_format_modifier_count = @intCast(choice.modifiers.len),
        .p_drm_format_modifiers = choice.modifiers.ptr,
    };
    const ext_image: vk.ExternalMemoryImageCreateInfo = .{
        .p_next = &mod_list,
        .handle_types = .{ .dma_buf_ext = true },
    };
    b.image = try dev.createImage(&.{
        .p_next = &ext_image,
        .image_type = .@"2d",
        .format = self.device.format(self.color).vk,
        .extent = .{ .width = b.width, .height = b.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .color_attachment = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);

    // Exported dmabufs get a dedicated allocation (required by NVIDIA for dmabuf export).
    var dedicated_reqs: vk.MemoryDedicatedRequirements = .{ .prefers_dedicated_allocation = .false, .requires_dedicated_allocation = .false };
    var reqs: vk.MemoryRequirements2 = .{ .p_next = &dedicated_reqs, .memory_requirements = undefined };
    dev.getImageMemoryRequirements2(&.{ .image = b.image }, &reqs);

    const mem_props = instance.getPhysicalDeviceMemoryProperties(self.device.pdev);
    const type_index = blk: {
        for (mem_props.memory_types[0..mem_props.memory_type_count], 0..) |t, i| {
            if (reqs.memory_requirements.memory_type_bits & (@as(u32, 1) << @intCast(i)) != 0 and t.property_flags.device_local)
                break :blk @as(u32, @intCast(i));
        }
        return error.NoDeviceLocalMemoryType;
    };

    const dedicated: vk.MemoryDedicatedAllocateInfo = .{ .image = b.image };
    const export_info: vk.ExportMemoryAllocateInfo = .{ .p_next = &dedicated, .handle_types = .{ .dma_buf_ext = true } };
    b.memory = try dev.allocateMemory(&.{
        .p_next = &export_info,
        .allocation_size = reqs.memory_requirements.size,
        .memory_type_index = type_index,
    }, null);
    try dev.bindImageMemory(b.image, b.memory, 0);

    b.view = try dev.createImageView(&.{
        .image = b.image,
        .view_type = .@"2d",
        .format = self.device.format(self.color).vk,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = color_range,
    }, null);

    // DRM syncobj timeline, shared with the compositor.
    if (c.drmSyncobjCreate(self.device.drm_fd, 0, &b.syncobj) != 0) return error.SyncobjCreate;
    var timeline_fd: c_int = -1;
    if (c.drmSyncobjHandleToFD(self.device.drm_fd, b.syncobj, &timeline_fd) != 0) return error.SyncobjExport;
    defer _ = c.close(timeline_fd);
    b.wp_timeline = c.wp_linux_drm_syncobj_manager_v1_import_timeline(self.surface.display.syncobj_manager, timeline_fd) orelse
        return error.SyncobjImportTimeline;

    // Describe the dmabuf to the compositor.
    const modifier = b.modifierOf(self.device);
    const plane_count = (Device.supportedModifier(self.device.format(self.color), modifier) orelse return error.UnexpectedModifier).plane_count;
    const mem_fd = try dev.getMemoryFdKHR(&.{ .memory = b.memory, .handle_type = .{ .dma_buf_ext = true } });
    defer _ = c.close(mem_fd);

    const params = c.zwp_linux_dmabuf_v1_create_params(self.surface.display.dmabuf) orelse return error.DmabufParams;
    defer c.zwp_linux_buffer_params_v1_destroy(params);
    for (0..plane_count) |plane| {
        const aspect: vk.ImageAspectFlags = switch (plane) {
            0 => .{ .memory_plane_0_ext = true },
            1 => .{ .memory_plane_1_ext = true },
            2 => .{ .memory_plane_2_ext = true },
            3 => .{ .memory_plane_3_ext = true },
            else => return error.TooManyPlanes,
        };
        const layout = dev.getImageSubresourceLayout(b.image, &.{ .aspect_mask = aspect, .mip_level = 0, .array_layer = 0 });
        c.zwp_linux_buffer_params_v1_add(params, mem_fd, @intCast(plane), @intCast(layout.offset), @intCast(layout.row_pitch), @truncate(modifier >> 32), @truncate(modifier));
    }
    if (self.surface.display.dmabuf_version >= 6 and choice.tranche.sampling()) {
        var dev_t = choice.tranche.target_device;
        var arr: c.wl_array = .{ .size = @sizeOf(u64), .alloc = @sizeOf(u64), .data = &dev_t };
        c.zwp_linux_buffer_params_v1_set_sampling_device(params, &arr);
    }
    b.wl_buffer = c.zwp_linux_buffer_params_v1_create_immed(params, @intCast(b.width), @intCast(b.height), choice.format, 0) orelse
        return error.DmabufCreateBuffer;
}

fn destroyBuffer(self: *SurfaceTarget, b: *Buffer) void {
    const dev = self.device.proxy;
    if (b.wl_buffer) |wb| c.wl_buffer_destroy(wb);
    if (b.wp_timeline) |t| c.wp_linux_drm_syncobj_timeline_v1_destroy(t);
    if (b.syncobj != 0) _ = c.drmSyncobjDestroy(self.device.drm_fd, b.syncobj);
    dev.destroyImageView(b.view, null);
    dev.destroyImage(b.image, null);
    dev.freeMemory(b.memory, null);
    b.* = .{ .width = 0, .height = 0 };
}

const color_range: vk.ImageSubresourceRange = .{
    .aspect_mask = .{ .color = true },
    .base_mip_level = 0,
    .level_count = 1,
    .base_array_layer = 0,
    .layer_count = 1,
};

fn barrier(
    cmd: vk.CommandBufferProxy,
    image: vk.Image,
    old: vk.ImageLayout,
    new: vk.ImageLayout,
    src_family: u32,
    dst_family: u32,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
) void {
    const b = [_]vk.ImageMemoryBarrier2{.{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .old_layout = old,
        .new_layout = new,
        .src_queue_family_index = src_family,
        .dst_queue_family_index = dst_family,
        .image = image,
        .subresource_range = color_range,
    }};
    cmd.pipelineBarrier2(&.{ .image_memory_barrier_count = b.len, .p_image_memory_barriers = &b });
}

/// Takes ownership of `b` from the compositor and makes it renderable.
pub fn begin(self: *SurfaceTarget, cmd: vk.CommandBufferProxy, b: *Buffer) Renderer.Target {
    // Contents are discarded (UNDEFINED): the renderer clears the whole target.
    barrier(cmd, b.image, .undefined, .color_attachment_optimal, vk.QUEUE_FAMILY_FOREIGN_EXT, self.device.queue_family, .{}, .{}, .{ .color_attachment_output = true }, .{ .color_attachment_write = true });
    return .{ .view = b.view, .extent = .{ .width = b.width, .height = b.height }, .format = self.device.format(self.color).vk };
}

/// Hands `b` back to the compositor's (foreign) queue family.
pub fn end(self: *SurfaceTarget, cmd: vk.CommandBufferProxy, b: *Buffer) void {
    barrier(cmd, b.image, .color_attachment_optimal, .general, self.device.queue_family, vk.QUEUE_FAMILY_FOREIGN_EXT, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{}, .{});
}

/// After the submit that rendered `b`: places the frame's completion fence (already imported
/// into the device's staging syncobj) on this buffer's acquire point and attaches it.
/// The caller commits the surface tree.
pub fn attach(self: *SurfaceTarget, b: *Buffer, gpu_done_value: u64, damage: []const [4]i32) !void {
    const acquire_point = b.last_point + 1;
    const release_point = b.last_point + 2;
    b.last_point = release_point;
    b.gpu_done_value = gpu_done_value;

    try self.device.stagingToTimeline(b.syncobj, acquire_point);
    self.surface.attach(b.wl_buffer.?, b.wp_timeline.?, acquire_point, release_point, if (self.full_damage) &.{} else damage);
    self.full_damage = false;
    b.release_point = release_point;
    b.released = false;

    if (c.drmSyncobjEventfd(self.device.drm_fd, b.syncobj, release_point, self.release_eventfd, 0) != 0)
        return error.SyncobjEventfd;
}
