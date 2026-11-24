//! Any wl_surface we present dmabufs to: a window's root surface or a subsurface.
//! Owns its explicit-sync object, viewport (for fractional scaling), color-management
//! object, presentation feedback, and its own dmabuf feedback.
const Surface = @This();

const std = @import("std");
const c = @import("wl_c");
const dmabuf_feedback = @import("dmabuf_feedback");
const geom = @import("geom");
const listener = @import("listener.zig").listener;
const Display = @import("Display.zig");
const Window = @import("Window.zig");
const root = @import("root.zig");

display: *Display,
window: *Window,
parent: ?*Surface,
wl_surface: *c.wl_surface,
subsurface: ?*c.wl_subsurface,
syncobj_surface: *c.wp_linux_drm_syncobj_surface_v1,
viewport: *c.wp_viewport,
feedback_object: *c.zwp_linux_dmabuf_feedback_v1,
color_surface: ?*c.wp_color_management_surface_v1 = null,

/// Logical size and position relative to the parent (decided by the layout).
x: i32 = 0,
y: i32 = 0,
width: u32 = 1,
height: u32 = 1,
/// Buffer size changed (logical size or scale); buffers must be reallocated.
size_changed: bool = true,

stats: root.PresentStats = .{},
/// Outstanding presentation feedback objects, destroyed with the surface so their
/// events can never reach freed memory.
pending_feedback: std.ArrayList(*c.struct_wp_presentation_feedback) = .empty,

feedback: dmabuf_feedback.Feedback,

pub fn create(display: *Display, window: *Window, parent: ?*Surface) !*Surface {
    const gpa = display.gpa;
    const wl_surface = c.wl_compositor_create_surface(display.compositor) orelse return error.WaylandSurface;
    errdefer c.wl_surface_destroy(wl_surface);
    const subsurface: ?*c.wl_subsurface = if (parent) |p|
        c.wl_subcompositor_get_subsurface(display.subcompositor, wl_surface, p.wl_surface) orelse return error.WaylandSubsurface
    else
        null;
    errdefer if (subsurface) |s| c.wl_subsurface_destroy(s);
    const syncobj_surface = c.wp_linux_drm_syncobj_manager_v1_get_surface(display.syncobj_manager, wl_surface) orelse return error.SyncobjSurface;
    errdefer c.wp_linux_drm_syncobj_surface_v1_destroy(syncobj_surface);
    const viewport = c.wp_viewporter_get_viewport(display.viewporter, wl_surface) orelse return error.Viewport;
    errdefer c.wp_viewport_destroy(viewport);
    const feedback_object = c.zwp_linux_dmabuf_v1_get_surface_feedback(display.dmabuf, wl_surface) orelse return error.DmabufFeedback;
    errdefer c.zwp_linux_dmabuf_feedback_v1_destroy(feedback_object);

    const self = try gpa.create(Surface);
    self.* = .{
        .display = display,
        .window = window,
        .parent = parent,
        .wl_surface = wl_surface,
        .subsurface = subsurface,
        .syncobj_surface = syncobj_surface,
        .viewport = viewport,
        .feedback_object = feedback_object,
        .feedback = .init(gpa),
    };
    c.wl_surface_set_user_data(wl_surface, self);
    _ = c.zwp_linux_dmabuf_feedback_v1_add_listener(feedback_object, &feedback_listener, self);
    // Subsurfaces stay in synchronized mode (the default): their commits are applied
    // atomically together with the parent's next commit.
    return self;
}

pub fn destroy(self: *Surface) void {
    const gpa = self.display.gpa;
    if (self.display.pointer_focus == self) self.display.pointer_focus = null;
    for (self.pending_feedback.items) |fb| c.wp_presentation_feedback_destroy(fb);
    self.pending_feedback.deinit(gpa);
    self.feedback.deinit();
    if (self.color_surface) |cs| c.wp_color_management_surface_v1_destroy(cs);
    c.zwp_linux_dmabuf_feedback_v1_destroy(self.feedback_object);
    c.wp_viewport_destroy(self.viewport);
    c.wp_linux_drm_syncobj_surface_v1_destroy(self.syncobj_surface);
    if (self.subsurface) |s| c.wl_subsurface_destroy(s);
    c.wl_surface_destroy(self.wl_surface);
    gpa.destroy(self);
}

/// Blocks until the compositor sent the first complete dmabuf feedback.
pub fn waitForFeedback(self: *Surface) !void {
    while (!self.feedback.received) try self.display.dispatch();
}

/// Logical size; the buffer size follows from the window's fractional scale.
pub fn setSize(self: *Surface, width: u32, height: u32) void {
    const w = @max(width, 1);
    const h = @max(height, 1);
    if (w == self.width and h == self.height) return;
    self.width = w;
    self.height = h;
    self.size_changed = true;
    // Our content is always opaque; this lets the compositor skip blending and
    // makes the surface a better overlay-plane candidate.
    const region = c.wl_compositor_create_region(self.display.compositor);
    c.wl_region_add(region, 0, 0, @intCast(w), @intCast(h));
    c.wl_surface_set_opaque_region(self.wl_surface, region);
    c.wl_region_destroy(region);
}

/// Position relative to the parent surface (logical); applied on the parent's next commit.
pub fn setPosition(self: *Surface, x: i32, y: i32) void {
    self.x = x;
    self.y = y;
    if (self.subsurface) |s| c.wl_subsurface_set_position(s, x, y);
}

/// Top-left of this surface in window logical coordinates.
pub fn windowOrigin(self: *const Surface) [2]f64 {
    var x: f64 = 0;
    var y: f64 = 0;
    var s: *const Surface = self;
    while (s.parent) |p| : (s = p) {
        x += @floatFromInt(s.x);
        y += @floatFromInt(s.y);
    }
    return .{ x, y };
}

pub fn bufferWidth(self: *const Surface) u32 {
    return self.window.scale.length(self.width);
}

pub fn bufferHeight(self: *const Surface) u32 {
    return self.window.scale.length(self.height);
}

pub fn setImageDescription(self: *Surface, desc: ?*c.wp_image_description_v1) !void {
    const d = desc orelse return;
    if (self.color_surface == null) {
        const cm = self.display.color_manager orelse return error.NoColorManagement;
        self.color_surface = c.wp_color_manager_v1_get_surface(cm, self.wl_surface) orelse return error.ColorSurface;
    }
    c.wp_color_management_surface_v1_set_image_description(self.color_surface, d, c.WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
}

/// Attaches `buffer` with explicit-sync points and damage (empty = whole buffer), and
/// requests presentation feedback. Does not commit.
/// Safe to call from render tasks: libwayland requests are thread-safe and events are
/// only dispatched on the main thread.
pub fn attach(
    self: *Surface,
    buffer: *c.wl_buffer,
    timeline: *c.wp_linux_drm_syncobj_timeline_v1,
    acquire_point: u64,
    release_point: u64,
    damage: []const geom.BufferRect,
) void {
    c.wp_linux_drm_syncobj_surface_v1_set_acquire_point(self.syncobj_surface, timeline, @truncate(acquire_point >> 32), @truncate(acquire_point));
    c.wp_linux_drm_syncobj_surface_v1_set_release_point(self.syncobj_surface, timeline, @truncate(release_point >> 32), @truncate(release_point));
    c.wl_surface_attach(self.wl_surface, buffer, 0, 0);
    c.wp_viewport_set_destination(self.viewport, @intCast(self.width), @intCast(self.height));
    if (damage.len == 0) {
        c.wl_surface_damage_buffer(self.wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    } else for (damage) |d| {
        c.wl_surface_damage_buffer(self.wl_surface, d.x, d.y, @intCast(d.width), @intCast(d.height));
    }
    const fb = c.wp_presentation_feedback(self.display.presentation, self.wl_surface) orelse return;
    self.pending_feedback.append(self.display.gpa, fb) catch {
        c.wp_presentation_feedback_destroy(fb);
        return;
    };
    _ = c.wp_presentation_feedback_add_listener(fb, &presentation_feedback_listener, self);
}

pub fn commit(self: *Surface) void {
    c.wl_surface_commit(self.wl_surface);
}

fn forgetFeedback(self: *Surface, fb: ?*c.struct_wp_presentation_feedback) void {
    if (std.mem.indexOfScalar(*c.struct_wp_presentation_feedback, self.pending_feedback.items, fb.?)) |i|
        _ = self.pending_feedback.swapRemove(i);
    c.wp_presentation_feedback_destroy(fb);
}

const PresentationFeedbackHandlers = struct {
    pub fn presented(self: *Surface, fb: ?*c.struct_wp_presentation_feedback, sec_hi: u32, sec_lo: u32, nsec: u32, refresh: u32, _: u32, _: u32, flags: u32) callconv(.c) void {
        self.forgetFeedback(fb);
        const sec = (@as(u64, sec_hi) << 32) | sec_lo;
        self.stats.presented += 1;
        if (flags & c.WP_PRESENTATION_FEEDBACK_KIND_ZERO_COPY != 0) self.stats.zero_copy += 1;
        self.stats.last_present_ns = @as(i128, sec) * std.time.ns_per_s + nsec;
        if (refresh != 0) self.stats.refresh_ns = refresh;
    }
    pub fn discarded(self: *Surface, fb: ?*c.struct_wp_presentation_feedback) callconv(.c) void {
        self.forgetFeedback(fb);
        self.stats.discarded += 1;
    }
};

fn arrayBytes(arr: [*c]c.wl_array) []const u8 {
    return @as([*]const u8, @ptrCast(arr.*.data))[0..arr.*.size];
}

const FeedbackHandlers = struct {
    pub fn done(self: *Surface, _: ?*c.zwp_linux_dmabuf_feedback_v1) callconv(.c) void {
        self.feedback.onDone();
    }
    pub fn format_table(self: *Surface, _: ?*c.zwp_linux_dmabuf_feedback_v1, fd: i32, size: u32) callconv(.c) void {
        self.feedback.onFormatTable(fd, size);
    }
    pub fn tranche_done(self: *Surface, _: ?*c.zwp_linux_dmabuf_feedback_v1) callconv(.c) void {
        self.feedback.onTrancheDone();
    }
    pub fn tranche_target_device(self: *Surface, _: ?*c.zwp_linux_dmabuf_feedback_v1, arr: [*c]c.wl_array) callconv(.c) void {
        self.feedback.onTrancheTargetDevice(arrayBytes(arr));
    }
    pub fn tranche_formats(self: *Surface, _: ?*c.zwp_linux_dmabuf_feedback_v1, arr: [*c]c.wl_array) callconv(.c) void {
        self.feedback.onTrancheFormats(arrayBytes(arr));
    }
    pub fn tranche_flags(self: *Surface, _: ?*c.zwp_linux_dmabuf_feedback_v1, flags: u32) callconv(.c) void {
        self.feedback.onTrancheFlags(flags);
    }
};

const feedback_listener = listener(c.zwp_linux_dmabuf_feedback_v1_listener, FeedbackHandlers, Surface);
const presentation_feedback_listener = listener(c.wp_presentation_feedback_listener, PresentationFeedbackHandlers, Surface);
