//! A logical device on one GPU: graphics queue, DRM render node, a timeline semaphore
//! tracking GPU progress, the shared Renderer, and per-frame batching: every surface tree
//! bound to this device is rendered with one command buffer, one submit and one sync_file.
//! The queue and command pool are externally synchronized: only one task may use a device at a time.
const Device = @This();

const std = @import("std");
const vk = @import("vulkan");
const c = @import("c");
const Instance = @import("Instance.zig");
const Renderer = @import("Renderer.zig");
const SurfaceTarget = @import("SurfaceTarget.zig");
const wayland = @import("../wayland.zig");
const Allocator = std.mem.Allocator;

/// A presentable format: the Vulkan format we render in, the equivalent DRM fourccs in
/// preference order, and the modifiers this device can render to and export for it.
pub const Format = struct {
    vk: vk.Format,
    drm: []const u32,
    modifiers: []Modifier = &.{},
};

fn formatSpecs() [2]Format {
    return .{
        // 8-bit sRGB; byte order B, G, R, X/A.
        .{ .vk = .b8g8r8a8_srgb, .drm = &.{ c.DRM_FORMAT_XRGB8888, c.DRM_FORMAT_ARGB8888 } },
        // FP16 linear (scRGB HDR); channel order R, G, B, X/A.
        .{ .vk = .r16g16b16a16_sfloat, .drm = &.{ c.DRM_FORMAT_XBGR16161616F, c.DRM_FORMAT_ABGR16161616F } },
    };
}

const frames_in_flight = 3;

const Frame = struct {
    cmd: vk.CommandBuffer,
    /// Binary, SYNC_FD-exportable: its sync_file becomes every presented buffer's acquire fence.
    done: vk.Semaphore,
    /// Device timeline value signalled when this frame's work completes.
    value: u64 = 0,
};

pub const Modifier = struct {
    modifier: u64,
    plane_count: u32,
};

gpa: Allocator,
instance: *Instance,
pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
drm: vk.PhysicalDeviceDrmPropertiesEXT,
queue_family: u32,
vkd: vk.DeviceWrapper,
proxy: vk.DeviceProxy,
queue: vk.QueueProxy,

/// Render node, used for DRM syncobj ioctls.
drm_fd: c_int,
/// Binary syncobj used to stage sync_file imports before transferring them onto a timeline point.
staging_syncobj: u32,

/// Signalled with increasing values by every submission on this device.
timeline: vk.Semaphore,
timeline_value: u64 = 0,

pool: vk.CommandPool,
frames: [frames_in_flight]Frame,
frame_index: usize = 0,
renderer: Renderer,

/// Indexed by wayland.ColorMode.
formats: [2]Format,

pub fn create(gpa: Allocator, instance: *Instance, candidate: Instance.Candidate) !*Device {
    const self = try gpa.create(Device);
    errdefer gpa.destroy(self);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/dev/dri/renderD{d}", .{candidate.drm.render_minor}, 0);
    const drm_fd = c.open(path.ptr, c.O_RDWR | c.O_CLOEXEC);
    if (drm_fd < 0) return error.OpenRenderNode;
    errdefer _ = c.close(drm_fd);

    var cap: u64 = 0;
    if (c.drmGetCap(drm_fd, c.DRM_CAP_SYNCOBJ_TIMELINE, &cap) != 0 or cap == 0) return error.NoSyncobjTimeline;

    var staging: u32 = 0;
    if (c.drmSyncobjCreate(drm_fd, 0, &staging) != 0) return error.SyncobjCreate;
    errdefer _ = c.drmSyncobjDestroy(drm_fd, staging);

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
        .enabled_extension_count = Instance.device_extensions.len,
        .pp_enabled_extension_names = &Instance.device_extensions,
    }, null);

    self.* = .{
        .gpa = gpa,
        .instance = instance,
        .pdev = candidate.pdev,
        .props = candidate.props,
        .drm = candidate.drm,
        .queue_family = candidate.queue_family,
        .vkd = vk.DeviceWrapper.load(handle, instance.vki.dispatch.vkGetDeviceProcAddr.?),
        .proxy = undefined,
        .queue = undefined,
        .drm_fd = drm_fd,
        .staging_syncobj = staging,
        .timeline = .null,
        .pool = .null,
        .frames = @splat(.{ .cmd = undefined, .done = .null }),
        .renderer = undefined,
        .formats = formatSpecs(),
    };
    self.proxy = vk.DeviceProxy.init(handle, &self.vkd);
    errdefer self.proxy.destroyDevice(null);
    self.queue = vk.QueueProxy.init(self.proxy.getDeviceQueue(self.queue_family, 0), &self.vkd);

    const type_info: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = .timeline, .initial_value = 0 };
    self.timeline = try self.proxy.createSemaphore(&.{ .p_next = &type_info }, null);
    errdefer self.proxy.destroySemaphore(self.timeline, null);

    self.pool = try self.proxy.createCommandPool(&.{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = self.queue_family,
    }, null);
    errdefer self.proxy.destroyCommandPool(self.pool, null);

    var cmds: [frames_in_flight]vk.CommandBuffer = undefined;
    try self.proxy.allocateCommandBuffers(&.{
        .command_pool = self.pool,
        .level = .primary,
        .command_buffer_count = frames_in_flight,
    }, &cmds);
    errdefer for (&self.frames) |*f| self.proxy.destroySemaphore(f.done, null);
    for (&self.frames, cmds) |*f, cmd| {
        const export_sem: vk.ExportSemaphoreCreateInfo = .{ .handle_types = .{ .sync_fd = true } };
        f.* = .{ .cmd = cmd, .done = try self.proxy.createSemaphore(&.{ .p_next = &export_sem }, null) };
    }

    self.renderer = try Renderer.init(self.proxy);
    errdefer self.renderer.deinit();

    errdefer for (self.formats) |f| gpa.free(f.modifiers);
    for (&self.formats) |*f| f.modifiers = try self.queryModifiers(f.vk);
    if (self.formats[0].modifiers.len == 0) return error.NoRenderableDmabufModifiers;
    return self;
}

pub fn destroy(self: *Device) void {
    self.waitIdle();
    for (self.formats) |f| self.gpa.free(f.modifiers);
    self.renderer.deinit();
    for (self.frames) |f| self.proxy.destroySemaphore(f.done, null);
    self.proxy.destroyCommandPool(self.pool, null);
    self.proxy.destroySemaphore(self.timeline, null);
    self.proxy.destroyDevice(null);
    _ = c.drmSyncobjDestroy(self.drm_fd, self.staging_syncobj);
    _ = c.close(self.drm_fd);
    self.gpa.destroy(self);
}

pub fn name(self: *const Device) []const u8 {
    return std.mem.sliceTo(&self.props.device_name, 0);
}

/// Whether a dev_t from dmabuf feedback refers to this GPU (either its primary or render node).
/// dev_t values can't be compared directly; compare major/minor instead.
pub fn matchesDevT(self: *const Device, dev: u64) bool {
    const major: i64 = @intCast(((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(u64, 0xfff)));
    const minor: i64 = @intCast((dev & 0xff) | ((dev >> 12) & ~@as(u64, 0xff)));
    if (self.drm.has_render == .true and self.drm.render_major == major and self.drm.render_minor == minor) return true;
    if (self.drm.has_primary == .true and self.drm.primary_major == major and self.drm.primary_minor == minor) return true;
    return false;
}

pub fn format(self: *Device, mode: wayland.ColorMode) *Format {
    return &self.formats[@intFromEnum(mode)];
}

pub fn supportedModifier(fmt: *const Format, modifier: u64) ?Modifier {
    for (fmt.modifiers) |m| if (m.modifier == modifier) return m;
    return null;
}

/// GPU progress, without blocking.
pub fn completedValue(self: *Device) !u64 {
    return self.proxy.getSemaphoreCounterValue(self.timeline);
}

pub fn waitIdle(self: *Device) void {
    _ = self.proxy.waitSemaphores(&.{
        .semaphore_count = 1,
        .p_semaphores = &.{self.timeline},
        .p_values = &.{self.timeline_value},
    }, std.math.maxInt(u64)) catch {};
    self.queue.waitIdle() catch {};
}

fn queryModifiers(self: *Device, vk_format: vk.Format) ![]Modifier {
    const instance = self.instance.proxy;
    var list: vk.DrmFormatModifierPropertiesList2EXT = .{};
    var fp: vk.FormatProperties2 = .{ .p_next = &list, .format_properties = undefined };
    instance.getPhysicalDeviceFormatProperties2(self.pdev, vk_format, &fp);

    const all = try self.gpa.alloc(vk.DrmFormatModifierProperties2EXT, list.drm_format_modifier_count);
    defer self.gpa.free(all);
    list.p_drm_format_modifier_properties = all.ptr;
    instance.getPhysicalDeviceFormatProperties2(self.pdev, vk_format, &fp);

    var out: std.ArrayList(Modifier) = .empty;
    errdefer out.deinit(self.gpa);
    for (all[0..list.drm_format_modifier_count]) |m| {
        if (!m.drm_format_modifier_tiling_features.color_attachment) continue;

        const mod_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{
            .drm_format_modifier = m.drm_format_modifier,
            .sharing_mode = .exclusive,
        };
        const ext_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
            .p_next = &mod_info,
            .handle_type = .{ .dma_buf_ext = true },
        };
        var ext_props: vk.ExternalImageFormatProperties = .{ .external_memory_properties = .{
            .external_memory_features = .{},
            .compatible_handle_types = .{},
        } };
        var img_props: vk.ImageFormatProperties2 = .{ .p_next = &ext_props, .image_format_properties = undefined };
        instance.getPhysicalDeviceImageFormatProperties2(self.pdev, &.{
            .p_next = &ext_info,
            .format = vk_format,
            .type = .@"2d",
            .tiling = .drm_format_modifier_ext,
            .usage = .{ .color_attachment = true },
        }, &img_props) catch continue;
        if (!ext_props.external_memory_properties.external_memory_features.exportable) continue;

        try out.append(self.gpa, .{ .modifier = m.drm_format_modifier, .plane_count = m.drm_format_modifier_plane_count });
    }
    std.log.info("{s}: {d} renderable+exportable modifiers for {s}", .{ self.name(), out.items.len, @tagName(vk_format) });
    return out.toOwnedSlice(self.gpa);
}

pub const FrameStats = struct {
    /// Number of surfaces presented.
    submitted: usize = 0,
    /// Number of trees committed.
    committed: usize = 0,
    /// Some tree wanted a frame but was waiting only on our GPU.
    gpu_blocked: bool = false,
};

/// What one surface in a tree should show this frame.
pub const TargetWork = struct {
    target: *SurfaceTarget,
    views: []const Renderer.View,
    /// Changed regions in buffer pixels (x, y, w, h); empty = whole buffer.
    damage: []const [4]i32,
};

/// A surface tree (window) presented atomically. `targets` lists only the surfaces that
/// changed; the root is always committed so subsurface state applies.
pub const TreeWork = struct {
    window: *wayland.Window,
    targets: []const TargetWork,
    /// Set to true if this tree was rendered and committed this frame.
    committed: *bool,
};

/// Renders every tree that wants a frame and has a free buffer on all of its surfaces,
/// using one command buffer and one vkQueueSubmit2 for the whole device, exports one
/// sync_file, fans it out to each buffer's acquire point, and commits each tree
/// (subsurfaces first, root last). Never blocks on the GPU or the compositor.
pub fn renderFrame(self: *Device, trees: []const TreeWork, stats: *FrameStats) !void {
    const gpa = self.gpa;
    const completed = try self.completedValue();

    const frame = &self.frames[self.frame_index];
    if (completed < frame.value) {
        stats.gpu_blocked = true;
        return;
    }

    const Slot = struct { target: *SurfaceTarget, buffer: *SurfaceTarget.Buffer, views: []const Renderer.View, damage: []const [4]i32 };
    var slots: std.ArrayList(Slot) = .empty;
    defer slots.deinit(gpa);
    var ready_trees: std.ArrayList(*wayland.Window) = .empty;
    defer ready_trees.deinit(gpa);

    tree: for (trees) |tree| {
        if (!tree.window.frame_ready) continue;
        const start = slots.items.len;
        for (tree.targets) |tw| {
            if (tw.target.device != self) return error.TargetOnOtherDevice;
            switch (try tw.target.acquire(completed)) {
                .ready => |b| try slots.append(gpa, .{ .target = tw.target, .buffer = b, .views = tw.views, .damage = tw.damage }),
                .gpu_blocked, .busy => |_, tag| {
                    // All-or-nothing per tree, so subsurfaces never show mismatched frames.
                    if (tag == .gpu_blocked) stats.gpu_blocked = true;
                    slots.shrinkRetainingCapacity(start);
                    continue :tree;
                },
            }
        }
        try ready_trees.append(gpa, tree.window);
        tree.committed.* = true;
    }
    if (ready_trees.items.len == 0) return;
    if (slots.items.len == 0) {
        // Only layout/state changes (e.g. subsurface moves): commit without new buffers.
        for (ready_trees.items) |w| w.commitTree();
        stats.committed += ready_trees.items.len;
        return;
    }

    const cmd = vk.CommandBufferProxy.init(frame.cmd, &self.vkd);
    try cmd.resetCommandBuffer(.{});
    try cmd.beginCommandBuffer(&.{ .flags = .{ .one_time_submit = true } });
    for (slots.items) |slot| {
        const target = slot.target.begin(cmd, slot.buffer);
        self.renderer.record(cmd, target, slot.views);
        slot.target.end(cmd, slot.buffer);
    }
    try cmd.endCommandBuffer();

    self.timeline_value += 1;
    frame.value = self.timeline_value;
    const signals = [_]vk.SemaphoreSubmitInfo{
        .{ .semaphore = frame.done, .value = 0, .stage_mask = .{ .all_commands = true }, .device_index = 0 },
        .{ .semaphore = self.timeline, .value = frame.value, .stage_mask = .{ .all_commands = true }, .device_index = 0 },
    };
    try self.queue.submit2(&.{.{
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &.{.{ .command_buffer = frame.cmd, .device_mask = 0 }},
        .signal_semaphore_info_count = signals.len,
        .p_signal_semaphore_infos = &signals,
    }}, .null);
    self.frame_index = (self.frame_index + 1) % frames_in_flight;

    try self.importToStaging(frame.done);
    for (slots.items) |slot| try slot.target.attach(slot.buffer, frame.value, slot.damage);
    for (ready_trees.items) |w| w.commitTree();
    stats.submitted += slots.items.len;
    stats.committed += ready_trees.items.len;
}

/// Exports the submitted binary semaphore as a sync_file and imports it into the staging
/// syncobj. OPAQUE_FD semaphore payloads are not guaranteed to be DRM syncobjs (notably on
/// NVIDIA), while SYNC_FD export + syncobj import/transfer is portable.
fn importToStaging(self: *Device, semaphore: vk.Semaphore) !void {
    const fd = try self.proxy.getSemaphoreFdKHR(&.{ .semaphore = semaphore, .handle_type = .{ .sync_fd = true } });
    if (fd < 0) {
        // -1 means "already signaled".
        var h = self.staging_syncobj;
        if (c.drmSyncobjSignal(self.drm_fd, &h, 1) != 0) return error.SyncobjSignal;
        return;
    }
    defer _ = c.close(fd);
    if (c.drmSyncobjImportSyncFile(self.drm_fd, self.staging_syncobj, fd) != 0) return error.SyncobjImportSyncFile;
}

/// Copies the staging fence onto `syncobj` at `point`.
pub fn stagingToTimeline(self: *Device, syncobj: u32, point: u64) !void {
    if (c.drmSyncobjTransfer(self.drm_fd, syncobj, point, self.staging_syncobj, 0, 0) != 0) return error.SyncobjTransfer;
}
