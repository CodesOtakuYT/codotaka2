//! Per-device presentation: DRM render node, explicit-sync bridge, renderable+exportable
//! modifiers per format, and batched frames. Every surface tree on this device is rendered
//! with one command buffer, one submit and one sync_file per frame.
//! Not thread-safe: one task per Presenter at a time.
const Presenter = @This();

const std = @import("std");
const vk = @import("vulkan");
const vk_core = @import("vk_core");
const drm_sync = @import("drm_sync");
const dmabuf_feedback = @import("dmabuf_feedback");
const frame = @import("frame");
const formats = @import("formats.zig");
const SurfaceTarget = @import("SurfaceTarget.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.present);

pub const Modifier = struct {
    modifier: u64,
    plane_count: u32,
};

pub const TreeWork = frame.TreeWork(SurfaceTarget);

/// What the presenter needs to know about the GPU's DRM nodes.
pub const DrmInfo = vk.PhysicalDeviceDrmPropertiesEXT;

/// Records the views of one target. Called inside the presenter's command buffer, with the
/// target in COLOR_ATTACHMENT_OPTIMAL layout.
pub const Recorder = struct {
    ctx: *anyopaque,
    record: *const fn (ctx: *anyopaque, cmd: vk.CommandBufferProxy, target: Target, views: []const frame.View) anyerror!void,

    pub const Target = struct {
        view: vk.ImageView,
        extent: vk.Extent2D,
        format: vk.Format,
    };
};

pub const Stats = struct {
    /// Number of surfaces presented.
    submitted: usize = 0,
    /// Number of trees committed.
    committed: usize = 0,
    /// Some tree wanted a frame but was waiting only on our GPU.
    gpu_blocked: bool = false,
};

gpa: Allocator,
device: *vk_core.Device,
drm_info: DrmInfo,
drm: drm_sync.Node,
/// Binary syncobj staging each frame's sync_file before it is copied onto timelines.
staging: drm_sync.Syncobj,
ring: vk_core.FrameRing,
/// Renderable + dmabuf-exportable modifiers, indexed like `formats.table`.
modifiers: [formats.table.len][]Modifier,

pub fn create(gpa: Allocator, device: *vk_core.Device, drm_info: DrmInfo) !*Presenter {
    const self = try gpa.create(Presenter);
    errdefer gpa.destroy(self);

    const node = try drm_sync.Node.openRender(drm_info.render_minor);
    errdefer node.close();
    if (!node.supportsTimelines()) return error.NoSyncobjTimeline;
    const staging = try drm_sync.Syncobj.create(node);
    errdefer staging.destroy();

    var ring = try vk_core.FrameRing.init(device, .{ .export_sync_fd = true });
    errdefer ring.deinit();

    self.* = .{
        .gpa = gpa,
        .device = device,
        .drm_info = drm_info,
        .drm = node,
        .staging = staging,
        .ring = ring,
        .modifiers = @splat(&.{}),
    };
    errdefer for (self.modifiers) |m| gpa.free(m);
    for (&formats.table, &self.modifiers) |*f, *m| m.* = try self.queryModifiers(f.vk);
    if (self.modifiers[0].len == 0) return error.NoRenderableDmabufModifiers;
    return self;
}

/// Destroy all SurfaceTargets first.
pub fn destroy(self: *Presenter) void {
    self.device.waitIdle();
    self.device.deletion.flush();
    self.ring.deinit();
    for (self.modifiers) |m| self.gpa.free(m);
    self.staging.destroy();
    self.drm.close();
    self.gpa.destroy(self);
}

pub fn supportedModifier(self: *const Presenter, format: *const formats.Format, modifier: u64) ?Modifier {
    const i = (@intFromPtr(format) - @intFromPtr(&formats.table)) / @sizeOf(formats.Format);
    for (self.modifiers[i]) |m| if (m.modifier == modifier) return m;
    return null;
}

pub fn supportsFormat(self: *const Presenter, format: *const formats.Format) bool {
    const i = (@intFromPtr(format) - @intFromPtr(&formats.table)) / @sizeOf(formats.Format);
    return self.modifiers[i].len > 0;
}

/// Whether a dev_t from dmabuf feedback refers to this GPU (primary or render node).
pub fn isDevice(self: *const Presenter, dev: dmabuf_feedback.DevT) bool {
    const d = self.drm_info;
    return (d.has_render == .true and dev.is(d.render_major, d.render_minor)) or
        (d.has_primary == .true and dev.is(d.primary_major, d.primary_minor));
}

fn queryModifiers(self: *Presenter, vk_format: vk.Format) ![]Modifier {
    const instance = self.device.instance.proxy;
    const pdev = self.device.pdev;
    var list: vk.DrmFormatModifierPropertiesList2EXT = .{};
    var fp: vk.FormatProperties2 = .{ .p_next = &list, .format_properties = undefined };
    instance.getPhysicalDeviceFormatProperties2(pdev, vk_format, &fp);

    const all = try self.gpa.alloc(vk.DrmFormatModifierProperties2EXT, list.drm_format_modifier_count);
    defer self.gpa.free(all);
    list.p_drm_format_modifier_properties = all.ptr;
    instance.getPhysicalDeviceFormatProperties2(pdev, vk_format, &fp);

    var out: std.ArrayList(Modifier) = .empty;
    errdefer out.deinit(self.gpa);
    for (all[0..list.drm_format_modifier_count]) |m| {
        if (!m.drm_format_modifier_tiling_features.color_attachment) continue;
        const mod_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{
            .drm_format_modifier = m.drm_format_modifier,
            .sharing_mode = .exclusive,
        };
        const ext_info: vk.PhysicalDeviceExternalImageFormatInfo = .{ .p_next = &mod_info, .handle_type = .{ .dma_buf_ext = true } };
        var ext_props: vk.ExternalImageFormatProperties = .{ .external_memory_properties = .{
            .external_memory_features = .{},
            .compatible_handle_types = .{},
        } };
        var img_props: vk.ImageFormatProperties2 = .{ .p_next = &ext_props, .image_format_properties = undefined };
        instance.getPhysicalDeviceImageFormatProperties2(pdev, &.{
            .p_next = &ext_info,
            .format = vk_format,
            .type = .@"2d",
            .tiling = .drm_format_modifier_ext,
            .usage = .{ .color_attachment = true },
        }, &img_props) catch continue;
        if (!ext_props.external_memory_properties.external_memory_features.exportable) continue;
        try out.append(self.gpa, .{ .modifier = m.drm_format_modifier, .plane_count = m.drm_format_modifier_plane_count });
    }
    log.info("{s}: {d} renderable+exportable modifiers for {t}", .{ self.device.name(), out.items.len, vk_format });
    return out.toOwnedSlice(self.gpa);
}

/// Renders every tree that wants a frame and has a free buffer on all of its changed
/// surfaces, using one command buffer and one submit, exports one sync_file, fans it out
/// to each buffer's acquire point, and commits each tree (subsurfaces first, root last).
/// Never blocks on the GPU or the compositor. `arena` is per-frame scratch for this task.
pub fn renderFrame(self: *Presenter, arena: Allocator, trees: []const TreeWork, recorder: Recorder, stats: *Stats) !void {
    try self.device.collectGarbage();
    const completed = try self.device.completedValue();

    const Slot = struct { target: *SurfaceTarget, buffer: *SurfaceTarget.Buffer, work: frame.TargetWork(SurfaceTarget) };
    var slots: std.ArrayList(Slot) = .empty;
    var ready: std.ArrayList(TreeWork) = .empty;

    tree: for (trees) |tree| {
        if (!tree.window.frame_ready) continue;
        const start = slots.items.len;
        for (tree.targets) |tw| {
            if (tw.target.presenter != self) return error.TargetOnOtherDevice;
            switch (try tw.target.acquire(completed)) {
                .ready => |b| try slots.append(arena, .{ .target = tw.target, .buffer = b, .work = tw }),
                .gpu_blocked, .busy => |_, tag| {
                    // All-or-nothing per tree, so subsurfaces never show mismatched frames.
                    if (tag == .gpu_blocked) stats.gpu_blocked = true;
                    slots.shrinkRetainingCapacity(start);
                    continue :tree;
                },
            }
        }
        try ready.append(arena, tree);
    }
    if (ready.items.len == 0) return;

    if (slots.items.len > 0) {
        const f = try self.ring.begin(completed) orelse {
            stats.gpu_blocked = true;
            return;
        };
        const cmd = f.commands(self.device);
        for (slots.items) |slot| {
            const target = slot.target.begin(cmd, slot.buffer);
            try recorder.record(recorder.ctx, cmd, target, slot.work.views);
            slot.target.end(cmd, slot.buffer);
        }
        const value = try self.ring.submit(f);
        try self.stageFence(f.done);
        for (slots.items) |slot| try slot.target.attach(slot.buffer, value, slot.work.damage);
    }
    for (ready.items) |tree| {
        tree.window.commitTree();
        tree.committed.* = true;
    }
    stats.submitted += slots.items.len;
    stats.committed += ready.items.len;
}

/// Exports the submitted binary semaphore as a sync_file and imports it into the staging
/// syncobj. OPAQUE_FD semaphore payloads are not guaranteed to be DRM syncobjs (notably on
/// NVIDIA), while SYNC_FD export + syncobj import/transfer is portable.
fn stageFence(self: *Presenter, semaphore: vk.Semaphore) !void {
    const fd = try self.device.proxy.getSemaphoreFdKHR(&.{ .semaphore = semaphore, .handle_type = .{ .sync_fd = true } });
    if (fd < 0) return self.staging.signal(); // -1 means "already signaled"
    defer drm_sync.closeFd(fd);
    try self.staging.importSyncFile(fd);
}
