//! A pool of presentable buffers for one wl.Surface (root or subsurface) on one Presenter,
//! without VkSwapchainKHR: dmabuf-exportable images with a format+modifier chosen from the
//! surface's own dmabuf feedback tranches, wrapped as wl_buffers and synchronized with the
//! compositor through per-buffer DRM syncobj timelines. It does not decide what is drawn.
const SurfaceTarget = @This();

const std = @import("std");
const vk = @import("vulkan");
const vk_core = @import("vk_core");
const drm_sync = @import("drm_sync");
const dmabuf_feedback = @import("dmabuf_feedback");
const geom = @import("geom");
const wl = @import("wl");
const c = wl.c;
const formats = @import("formats.zig");
const Presenter = @import("Presenter.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.present);

const buffer_count = 3;

pub const Buffer = struct {
    presenter: *Presenter,
    image: vk_core.Image = .{},
    wl_buffer: ?*c.wl_buffer = null,
    /// Per-buffer timeline shared with the compositor (acquire < release on the same timeline).
    syncobj: ?drm_sync.Syncobj = null,
    wp_timeline: ?*c.wp_linux_drm_syncobj_timeline_v1 = null,
    last_point: u64 = 0,
    /// 0 = never committed. Otherwise the point the compositor signals when done with it.
    release_point: u64 = 0,
    released: bool = true,
    /// Device timeline value after which our last render into this buffer completed.
    gpu_done_value: u64 = 0,

    fn isReleased(b: *Buffer) bool {
        if (!b.released) b.released = b.syncobj.?.isSignaled(b.release_point);
        return b.released;
    }

    fn destroy(b: *Buffer) void {
        if (b.wl_buffer) |wb| c.wl_buffer_destroy(wb);
        if (b.wp_timeline) |t| c.wp_linux_drm_syncobj_timeline_v1_destroy(t);
        if (b.syncobj) |s| s.destroy();
        b.image.deinit(b.presenter.device);
        b.presenter.gpa.destroy(b);
    }

    fn readyCallback(ctx: *anyopaque) bool {
        const b: *Buffer = @ptrCast(@alignCast(ctx));
        return b.isReleased();
    }

    fn destroyCallback(ctx: *anyopaque) void {
        const b: *Buffer = @ptrCast(@alignCast(ctx));
        b.destroy();
    }
};

pub const Acquired = union(enum) {
    /// Every buffer is still held by the compositor; the release eventfd will fire.
    busy,
    /// A buffer was released but our GPU is still writing it.
    gpu_blocked,
    ready: *Buffer,
};

gpa: Allocator,
presenter: *Presenter,
surface: *wl.Surface,
format: *const formats.Format,
/// The next attach must damage the whole buffer (new/reallocated buffers).
full_damage: bool = true,
buffers: std.ArrayList(*Buffer) = .empty,

drm_format: u32 = 0,
modifier: u64 = 0,
scanout_tranche: bool = false,

/// Signalled by the kernel when any release point we registered is reached.
release_eventfd: drm_sync.EventFd,

/// Fails with error.NoCompatibleTranche if the compositor can't take this presenter's
/// dmabufs for this surface, or error.ColorModeUnsupported. Buffers are allocated lazily.
pub fn create(gpa: Allocator, presenter: *Presenter, surface: *wl.Surface, color: wl.ColorMode, translucent: bool) !*SurfaceTarget {
    const format = formats.forMode(color, translucent);
    surface.setOpaque(!translucent);
    if (!presenter.supportsFormat(format)) return error.ColorModeUnsupported;
    try surface.setImageDescription(try surface.display.imageDescription(color));

    const efd = try drm_sync.EventFd.create();
    errdefer efd.close();
    const self = try gpa.create(SurfaceTarget);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .presenter = presenter, .surface = surface, .format = format, .release_eventfd = efd };

    const choice = try self.choose();
    gpa.free(choice.modifiers);
    return self;
}

/// Buffers are handed to the device's deletion queue; nothing waits.
pub fn destroy(self: *SurfaceTarget) void {
    self.retireAll();
    self.buffers.deinit(self.gpa);
    self.release_eventfd.close();
    self.gpa.destroy(self);
}

fn retireAll(self: *SurfaceTarget) void {
    for (self.buffers.items) |b| {
        self.presenter.device.deferDestroy(b, Buffer.readyCallback, Buffer.destroyCallback) catch {
            self.presenter.device.waitIdle();
            b.destroy();
        };
    }
    self.buffers.clearRetainingCapacity();
}

pub fn eventFd(self: *const SurfaceTarget) std.os.linux.fd_t {
    return self.release_eventfd.fd;
}

pub fn drainEventFd(self: *SurfaceTarget) void {
    self.release_eventfd.drain();
}

/// Whether the next acquire will reallocate (size, scale or feedback changed); the caller
/// must then redraw everything on this target.
pub fn needsRealloc(self: *const SurfaceTarget) bool {
    return self.surface.feedback.changed or self.surface.size_changed or self.buffers.items.len == 0;
}

/// Picks a free buffer without blocking, reallocating first if needed.
pub fn acquire(self: *SurfaceTarget, completed: u64) !Acquired {
    if (self.needsRealloc()) try self.reallocate();
    var gpu_blocked = false;
    for (self.buffers.items) |b| {
        if (!b.isReleased()) continue;
        if (completed < b.gpu_done_value) {
            gpu_blocked = true;
            continue;
        }
        return .{ .ready = b };
    }
    return if (gpu_blocked) .gpu_blocked else .busy;
}

const Ctx = struct {
    presenter: *const Presenter,
    format: *const formats.Format,

    fn isDevice(ctx: Ctx, dev: dmabuf_feedback.DevT) bool {
        return ctx.presenter.isDevice(dev);
    }
    fn supported(ctx: Ctx, modifier: u64) bool {
        return ctx.presenter.supportedModifier(ctx.format, modifier) != null;
    }
};

/// Tranches in compositor preference order (scanout tranches first when direct scanout is
/// possible); first one targeting our GPU with a format+modifier we can render and export.
fn choose(self: *SurfaceTarget) !dmabuf_feedback.Choice {
    return try dmabuf_feedback.choose(
        self.gpa,
        self.surface.feedback.tranches.items,
        self.format.drm,
        Ctx{ .presenter = self.presenter, .format = self.format },
        Ctx.isDevice,
        Ctx.supported,
    ) orelse error.NoCompatibleTranche;
}

fn reallocate(self: *SurfaceTarget) !void {
    self.surface.feedback.changed = false;
    self.surface.size_changed = false;
    const choice = try self.choose();
    defer self.gpa.free(choice.modifiers);

    self.retireAll();
    try self.buffers.ensureTotalCapacity(self.gpa, buffer_count);
    for (0..buffer_count) |_| {
        const b = try self.createBuffer(choice);
        self.buffers.appendAssumeCapacity(b);
    }
    self.drm_format = choice.format;
    self.modifier = try self.buffers.items[0].image.drmModifier(self.presenter.device);
    self.scanout_tranche = choice.tranche.scanout();
    self.full_damage = true;

    log.debug("surface {*}: {d}x{d} for {d}x{d} logical, {s} modifier 0x{x:0>16}{s}", .{
        self.surface,                                  self.surface.bufferWidth(), self.surface.bufferHeight(),
        self.surface.width,                            self.surface.height,
        &formats.fourccName(choice.format),            self.modifier,
        if (self.scanout_tranche) " (scanout tranche)" else "",
    });
}

fn createBuffer(self: *SurfaceTarget, choice: dmabuf_feedback.Choice) !*Buffer {
    const presenter = self.presenter;
    const device = presenter.device;
    const display = self.surface.display;

    const b = try self.gpa.create(Buffer);
    b.* = .{ .presenter = presenter };
    errdefer b.destroy();

    b.image = try vk_core.Image.create(device, .{
        .format = self.format.vk,
        .extent = .{ .width = self.surface.bufferWidth(), .height = self.surface.bufferHeight() },
        .usage = .{ .color_attachment = true },
        .drm_modifiers = choice.modifiers,
        .export_dma_buf = true,
    });

    // Timeline shared with the compositor.
    const syncobj = try drm_sync.Syncobj.create(presenter.drm);
    b.syncobj = syncobj;
    const timeline_fd = try syncobj.exportFd();
    defer drm_sync.closeFd(timeline_fd);
    b.wp_timeline = c.wp_linux_drm_syncobj_manager_v1_import_timeline(display.syncobj_manager, timeline_fd) orelse
        return error.SyncobjImportTimeline;

    // Describe the dmabuf to the compositor.
    const modifier = try b.image.drmModifier(device);
    const plane_count = (presenter.supportedModifier(self.format, modifier) orelse return error.UnexpectedModifier).plane_count;
    const mem_fd = try b.image.exportDmaBuf(device);
    defer drm_sync.closeFd(mem_fd);

    const params = c.zwp_linux_dmabuf_v1_create_params(display.dmabuf) orelse return error.DmabufParams;
    defer c.zwp_linux_buffer_params_v1_destroy(params);
    for (0..plane_count) |plane| {
        const layout = try b.image.planeLayout(device, @intCast(plane));
        c.zwp_linux_buffer_params_v1_add(params, mem_fd, @intCast(plane), @intCast(layout.offset), @intCast(layout.row_pitch), @truncate(modifier >> 32), @truncate(modifier));
    }
    if (display.dmabuf_version >= 6 and choice.tranche.sampling()) {
        var dev_t = choice.tranche.target_device.raw;
        var arr: c.wl_array = .{ .size = @sizeOf(u64), .alloc = @sizeOf(u64), .data = &dev_t };
        c.zwp_linux_buffer_params_v1_set_sampling_device(params, &arr);
    }
    b.wl_buffer = c.zwp_linux_buffer_params_v1_create_immed(params, @intCast(b.image.extent.width), @intCast(b.image.extent.height), choice.format, 0) orelse
        return error.DmabufCreateBuffer;
    return b;
}

/// Makes `b` renderable. Its previous contents are discarded (we redraw everything), so
/// per the spec the ownership acquire from the compositor is skipped: a plain
/// UNDEFINED -> GENERAL transition suffices. With unified image layouts, GENERAL is the
/// only layout these images ever use.
pub fn begin(self: *SurfaceTarget, cmd: vk.CommandBufferProxy, b: *Buffer) Presenter.Recorder.Target {
    vk_core.barrier.image(cmd, .{
        .image = b.image.image,
        .old_layout = .undefined,
        .new_layout = .general,
        .dst_stage = .{ .color_attachment_output = true },
        .dst_access = .{ .color_attachment_write = true, .color_attachment_read = true },
    });
    return .{ .view = b.image.view, .extent = b.image.extent, .format = self.format.vk, .translucent = self.format.alpha, .encode = self.format.encode };
}

/// Releases `b` to the compositor (foreign queue family). Layout stays GENERAL; the
/// release is what makes the memory match the advertised DRM modifier.
pub fn end(self: *SurfaceTarget, cmd: vk.CommandBufferProxy, b: *Buffer) void {
    vk_core.barrier.image(cmd, .{
        .image = b.image.image,
        .old_layout = .general,
        .new_layout = .general,
        .src_stage = .{ .color_attachment_output = true },
        .src_access = .{ .color_attachment_write = true },
        .src_queue_family = self.presenter.device.queue_family,
        .dst_queue_family = vk.QUEUE_FAMILY_FOREIGN_EXT,
    });
}

/// After the submit that rendered `b`: copies the frame fence (staged by the presenter)
/// onto this buffer's acquire point and attaches it. The caller commits the tree.
pub fn attach(self: *SurfaceTarget, b: *Buffer, gpu_done_value: u64, damage: []const geom.BufferRect) !void {
    const acquire_point = b.last_point + 1;
    const release_point = b.last_point + 2;
    b.last_point = release_point;
    b.gpu_done_value = gpu_done_value;

    const syncobj = b.syncobj.?;
    try syncobj.transfer(acquire_point, self.presenter.staging, 0);
    self.surface.attach(b.wl_buffer.?, b.wp_timeline.?, acquire_point, release_point, if (self.full_damage) &.{} else damage);
    self.full_damage = false;
    b.release_point = release_point;
    b.released = false;
    try syncobj.registerEventfd(release_point, self.release_eventfd.fd);
}
