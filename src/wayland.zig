const std = @import("std");
const c = @import("c");
const Allocator = std.mem.Allocator;

pub const ColorMode = enum {
    /// sRGB primaries, gamma 2.2 transfer, 8-bit.
    sdr,
    /// Windows-scRGB: sRGB primaries, extended linear, FP16; 1.0 = 80 cd/m².
    hdr_scrgb,
};

pub const PointerEvent = struct {
    kind: enum { enter, leave, motion, button },
    /// Window-relative logical coordinates.
    x: f64 = 0,
    y: f64 = 0,
    button: u32 = 0,
    pressed: bool = false,
    serial: u32 = 0,
    time: u32 = 0,
};

/// A connection to the Wayland compositor, shared by all windows and surfaces.
pub const Display = struct {
    gpa: Allocator,
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_compositor = null,
    subcompositor: ?*c.wl_subcompositor = null,
    wm_base: ?*c.xdg_wm_base = null,
    wm_base_version: u32 = 0,
    decoration_manager: ?*c.zxdg_decoration_manager_v1 = null,
    dmabuf: ?*c.zwp_linux_dmabuf_v1 = null,
    dmabuf_version: u32 = 0,
    syncobj_manager: ?*c.wp_linux_drm_syncobj_manager_v1 = null,
    viewporter: ?*c.wp_viewporter = null,
    fractional_scale_manager: ?*c.wp_fractional_scale_manager_v1 = null,
    presentation: ?*c.wp_presentation = null,
    presentation_clock: u32 = c.CLOCK_MONOTONIC,
    cursor_shape_manager: ?*c.wp_cursor_shape_manager_v1 = null,

    color_manager: ?*c.wp_color_manager_v1 = null,
    color_features: u32 = 0,
    color_tfs: u32 = 0,
    color_primaries: u32 = 0,
    descriptions: std.EnumArray(ColorMode, ?*c.wp_image_description_v1) = .initFill(null),

    seat: ?*c.wl_seat = null,
    pointer: ?*c.wl_pointer = null,
    cursor_shape_device: ?*c.wp_cursor_shape_device_v1 = null,
    pointer_focus: ?*Surface = null,
    pointer_serial: u32 = 0,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,

    pub fn connect(gpa: Allocator) !*Display {
        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(display);
        const registry = c.wl_display_get_registry(display) orelse return error.WaylandRegistry;
        errdefer c.wl_registry_destroy(registry);

        const self = try gpa.create(Display);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .display = display, .registry = registry };

        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        // Two roundtrips: globals, then their initial events (color features, seat caps, clock).
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtrip;
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtrip;
        inline for (.{
            .{ "compositor", error.NoCompositor },
            .{ "subcompositor", error.NoSubcompositor },
            .{ "wm_base", error.NoXdgWmBase },
            .{ "dmabuf", error.NoLinuxDmabufV4 },
            .{ "syncobj_manager", error.NoLinuxDrmSyncobj },
            .{ "viewporter", error.NoViewporter },
            .{ "fractional_scale_manager", error.NoFractionalScale },
            .{ "presentation", error.NoPresentationTime },
        }) |req| {
            if (@field(self, req[0]) == null) return req[1];
        }
        if (self.presentation_clock != c.CLOCK_MONOTONIC)
            std.log.warn("presentation clock is {d}, not CLOCK_MONOTONIC; frame timing will be off", .{self.presentation_clock});
        return self;
    }

    pub fn disconnect(self: *Display) void {
        for (&self.descriptions.values) |*d| if (d.*) |desc| c.wp_image_description_v1_destroy(desc);
        if (self.cursor_shape_device) |d| c.wp_cursor_shape_device_v1_destroy(d);
        if (self.pointer) |p| c.wl_pointer_destroy(p);
        if (self.seat) |s| c.wl_seat_destroy(s);
        if (self.cursor_shape_manager) |m| c.wp_cursor_shape_manager_v1_destroy(m);
        if (self.color_manager) |m| c.wp_color_manager_v1_destroy(m);
        if (self.presentation) |p| c.wp_presentation_destroy(p);
        if (self.fractional_scale_manager) |m| c.wp_fractional_scale_manager_v1_destroy(m);
        if (self.viewporter) |v| c.wp_viewporter_destroy(v);
        if (self.syncobj_manager) |m| c.wp_linux_drm_syncobj_manager_v1_destroy(m);
        if (self.dmabuf) |d| c.zwp_linux_dmabuf_v1_destroy(d);
        if (self.decoration_manager) |m| c.zxdg_decoration_manager_v1_destroy(m);
        if (self.wm_base) |w| c.xdg_wm_base_destroy(w);
        if (self.subcompositor) |s| c.wl_subcompositor_destroy(s);
        if (self.compositor) |comp| c.wl_compositor_destroy(comp);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        self.gpa.destroy(self);
    }

    pub fn flush(self: *Display) void {
        _ = c.wl_display_flush(self.display);
    }

    /// Reads and dispatches Wayland events. With `timeout_ms == 0` this never blocks;
    /// otherwise it sleeps until Wayland traffic arrives, one of `extra_fds` becomes
    /// readable, or the timeout expires (-1 = forever).
    pub fn wait(self: *Display, extra_fds: []const c_int, timeout_ms: c_int) !void {
        while (c.wl_display_prepare_read(self.display) != 0) {
            if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatch;
        }
        _ = c.wl_display_flush(self.display);

        var fds_buf: [64]c.struct_pollfd = undefined;
        const n = @min(extra_fds.len, fds_buf.len - 1) + 1;
        fds_buf[0] = .{ .fd = c.wl_display_get_fd(self.display), .events = c.POLLIN, .revents = 0 };
        for (extra_fds[0 .. n - 1], fds_buf[1..n]) |fd, *p| p.* = .{ .fd = fd, .events = c.POLLIN, .revents = 0 };

        if (c.poll(&fds_buf, @intCast(n), timeout_ms) > 0 and fds_buf[0].revents & c.POLLIN != 0) {
            if (c.wl_display_read_events(self.display) < 0) return error.WaylandRead;
        } else {
            c.wl_display_cancel_read(self.display);
        }
        if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatch;
    }

    /// The compositor-side image description for `mode`, created once and cached.
    /// Returns null for SDR when the compositor has no color management (implicit sRGB).
    pub fn imageDescription(self: *Display, mode: ColorMode) !?*c.wp_image_description_v1 {
        if (self.descriptions.get(mode)) |d| return d;
        const cm = self.color_manager orelse return switch (mode) {
            .sdr => null,
            .hdr_scrgb => error.NoColorManagement,
        };
        const desc = switch (mode) {
            .sdr => blk: {
                const want_feature = bit(c.WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC);
                if (self.color_features & want_feature == 0 or
                    self.color_tfs & bit(c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22) == 0 or
                    self.color_primaries & bit(c.WP_COLOR_MANAGER_V1_PRIMARIES_SRGB) == 0) return null;
                const creator = c.wp_color_manager_v1_create_parametric_creator(cm) orelse return error.ColorCreator;
                c.wp_image_description_creator_params_v1_set_tf_named(creator, c.WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22);
                c.wp_image_description_creator_params_v1_set_primaries_named(creator, c.WP_COLOR_MANAGER_V1_PRIMARIES_SRGB);
                break :blk c.wp_image_description_creator_params_v1_create(creator) orelse return error.ColorCreate;
            },
            .hdr_scrgb => blk: {
                if (self.color_features & bit(c.WP_COLOR_MANAGER_V1_FEATURE_WINDOWS_SCRGB) == 0) return error.NoWindowsScrgb;
                break :blk c.wp_color_manager_v1_create_windows_scrgb(cm) orelse return error.ColorCreate;
            },
        };
        var state: DescriptionState = .pending;
        _ = c.wp_image_description_v1_add_listener(desc, &description_listener, &state);
        while (state == .pending) {
            if (c.wl_display_dispatch(self.display) < 0) return error.WaylandDispatch;
        }
        if (state == .failed) {
            c.wp_image_description_v1_destroy(desc);
            return error.ImageDescriptionFailed;
        }
        self.descriptions.set(mode, desc);
        return desc;
    }

    fn bit(v: anytype) u32 {
        return @as(u32, 1) << @intCast(v);
    }

    const DescriptionState = enum { pending, ready, failed };

    fn descFailed(data: ?*anyopaque, _: ?*c.wp_image_description_v1, _: u32, msg: [*c]const u8) callconv(.c) void {
        const state: *DescriptionState = @ptrCast(@alignCast(data));
        std.log.err("image description failed: {s}", .{msg});
        state.* = .failed;
    }

    fn descReady(data: ?*anyopaque, _: ?*c.wp_image_description_v1, _: u32) callconv(.c) void {
        const state: *DescriptionState = @ptrCast(@alignCast(data));
        state.* = .ready;
    }

    fn descReady2(data: ?*anyopaque, _: ?*c.wp_image_description_v1, _: u32, _: u32) callconv(.c) void {
        const state: *DescriptionState = @ptrCast(@alignCast(data));
        state.* = .ready;
    }

    const description_listener: c.wp_image_description_v1_listener = .{ .failed = descFailed, .ready = descReady, .ready2 = descReady2 };

    pub fn setCursor(self: *Display, shape: u32) void {
        if (self.cursor_shape_device) |d| c.wp_cursor_shape_device_v1_set_shape(d, self.pointer_serial, shape);
    }

    fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, iface_c: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        const iface = std.mem.span(iface_c);
        const is = struct {
            fn f(a: []const u8, i: anytype) bool {
                return std.mem.eql(u8, a, std.mem.span(i.name));
            }
        }.f;
        if (is(iface, c.wl_compositor_interface)) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
        } else if (is(iface, c.wl_subcompositor_interface)) {
            self.subcompositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_subcompositor_interface, 1));
        } else if (is(iface, c.xdg_wm_base_interface)) {
            self.wm_base_version = @min(version, 6);
            self.wm_base = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, self.wm_base_version));
            _ = c.xdg_wm_base_add_listener(self.wm_base, &wm_base_listener, self);
        } else if (is(iface, c.zxdg_decoration_manager_v1_interface)) {
            self.decoration_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zxdg_decoration_manager_v1_interface, 1));
        } else if (is(iface, c.zwp_linux_dmabuf_v1_interface) and version >= 4) {
            self.dmabuf_version = @min(version, 6);
            self.dmabuf = @ptrCast(c.wl_registry_bind(registry, name, &c.zwp_linux_dmabuf_v1_interface, self.dmabuf_version));
        } else if (is(iface, c.wp_linux_drm_syncobj_manager_v1_interface)) {
            self.syncobj_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_linux_drm_syncobj_manager_v1_interface, 1));
        } else if (is(iface, c.wp_viewporter_interface)) {
            self.viewporter = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_viewporter_interface, 1));
        } else if (is(iface, c.wp_fractional_scale_manager_v1_interface)) {
            self.fractional_scale_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_fractional_scale_manager_v1_interface, 1));
        } else if (is(iface, c.wp_presentation_interface)) {
            self.presentation = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_presentation_interface, 1));
            _ = c.wp_presentation_add_listener(self.presentation, &presentation_listener, self);
        } else if (is(iface, c.wp_color_manager_v1_interface)) {
            self.color_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_color_manager_v1_interface, 1));
            _ = c.wp_color_manager_v1_add_listener(self.color_manager, &color_manager_listener, self);
        } else if (is(iface, c.wp_cursor_shape_manager_v1_interface)) {
            self.cursor_shape_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_cursor_shape_manager_v1_interface, 1));
        } else if (is(iface, c.wl_seat_interface) and self.seat == null) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 5)));
            _ = c.wl_seat_add_listener(self.seat, &seat_listener, self);
        }
    }

    fn globalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

    fn ping(_: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
        c.xdg_wm_base_pong(wm_base, serial);
    }

    fn clockId(data: ?*anyopaque, _: ?*c.wp_presentation, clk: u32) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        self.presentation_clock = clk;
    }

    fn cmIntent(_: ?*anyopaque, _: ?*c.wp_color_manager_v1, _: u32) callconv(.c) void {}
    fn cmFeature(data: ?*anyopaque, _: ?*c.wp_color_manager_v1, f: u32) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        if (f < 32) self.color_features |= bit(f);
    }
    fn cmTf(data: ?*anyopaque, _: ?*c.wp_color_manager_v1, f: u32) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        if (f < 32) self.color_tfs |= bit(f);
    }
    fn cmPrimaries(data: ?*anyopaque, _: ?*c.wp_color_manager_v1, f: u32) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        if (f < 32) self.color_primaries |= bit(f);
    }
    fn cmDone(_: ?*anyopaque, _: ?*c.wp_color_manager_v1) callconv(.c) void {}

    fn seatCaps(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        const has_pointer = caps & c.WL_SEAT_CAPABILITY_POINTER != 0;
        if (has_pointer and self.pointer == null) {
            self.pointer = c.wl_seat_get_pointer(seat);
            _ = c.wl_pointer_add_listener(self.pointer, &pointer_listener, self);
            if (self.cursor_shape_manager) |m| self.cursor_shape_device = c.wp_cursor_shape_manager_v1_get_pointer(m, self.pointer);
        } else if (!has_pointer and self.pointer != null) {
            if (self.cursor_shape_device) |d| c.wp_cursor_shape_device_v1_destroy(d);
            self.cursor_shape_device = null;
            c.wl_pointer_release(self.pointer);
            self.pointer = null;
            self.pointer_focus = null;
        }
    }
    fn seatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}

    fn dispatchPointer(self: *Display, ev: PointerEvent) void {
        const s = self.pointer_focus orelse return;
        var e = ev;
        const origin = s.windowOrigin();
        e.x = self.pointer_x + origin[0];
        e.y = self.pointer_y + origin[1];
        s.window.onPointer(e);
    }

    fn ptrEnter(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        const s: ?*Surface = if (surface) |ws| @ptrCast(@alignCast(c.wl_surface_get_user_data(ws))) else null;
        self.pointer_focus = s;
        self.pointer_serial = serial;
        self.pointer_x = c.wl_fixed_to_double(x);
        self.pointer_y = c.wl_fixed_to_double(y);
        self.setCursor(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT);
        self.dispatchPointer(.{ .kind = .enter, .serial = serial });
    }
    fn ptrLeave(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, _: ?*c.wl_surface) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        self.dispatchPointer(.{ .kind = .leave, .serial = serial });
        self.pointer_focus = null;
    }
    fn ptrMotion(data: ?*anyopaque, _: ?*c.wl_pointer, time: u32, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        self.pointer_x = c.wl_fixed_to_double(x);
        self.pointer_y = c.wl_fixed_to_double(y);
        self.dispatchPointer(.{ .kind = .motion, .time = time });
    }
    fn ptrButton(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        const self: *Display = @ptrCast(@alignCast(data));
        self.dispatchPointer(.{
            .kind = .button,
            .button = button,
            .pressed = state == c.WL_POINTER_BUTTON_STATE_PRESSED,
            .serial = serial,
            .time = time,
        });
    }
    fn ptrAxis(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
    fn ptrFrame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {}
    fn ptrAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}
    fn ptrAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn ptrAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}

    const registry_listener: c.wl_registry_listener = .{ .global = global, .global_remove = globalRemove };
    const wm_base_listener: c.xdg_wm_base_listener = .{ .ping = ping };
    const presentation_listener: c.wp_presentation_listener = .{ .clock_id = clockId };
    const color_manager_listener: c.wp_color_manager_v1_listener = .{
        .supported_intent = cmIntent,
        .supported_feature = cmFeature,
        .supported_tf_named = cmTf,
        .supported_primaries_named = cmPrimaries,
        .done = cmDone,
    };
    const seat_listener: c.wl_seat_listener = .{ .capabilities = seatCaps, .name = seatName };
    // Seat is bound at version 5, so newer pointer events are never sent.
    const pointer_listener: c.wl_pointer_listener = .{
        .enter = ptrEnter,
        .leave = ptrLeave,
        .motion = ptrMotion,
        .button = ptrButton,
        .axis = ptrAxis,
        .frame = ptrFrame,
        .axis_source = ptrAxisSource,
        .axis_stop = ptrAxisStop,
        .axis_discrete = ptrAxisDiscrete,
        .axis_value120 = null,
        .axis_relative_direction = null,
        .warp = null,
    };
};

/// One entry of the dmabuf feedback format table.
pub const FormatModifier = extern struct {
    format: u32,
    _pad: u32,
    modifier: u64,
};

/// A preference tranche from zwp_linux_dmabuf_feedback_v1, in compositor preference order.
pub const Tranche = struct {
    target_device: u64,
    flags: u32,
    formats: std.ArrayList(FormatModifier),

    pub fn scanout(t: Tranche) bool {
        return t.flags & c.ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SCANOUT != 0;
    }

    pub fn sampling(t: Tranche) bool {
        return t.flags & 2 != 0; // ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SAMPLING (v6)
    }
};

pub const PresentStats = struct {
    presented: u64 = 0,
    zero_copy: u64 = 0,
    discarded: u64 = 0,
    last_present_ns: i128 = 0,
    refresh_ns: u32 = 0,
};

/// Any wl_surface we present dmabufs to: a window's root surface or a subsurface.
/// Owns its explicit-sync object, viewport (for fractional scaling), color-management
/// object, and its own dmabuf feedback.
pub const Surface = struct {
    display: *Display,
    window: *Window,
    parent: ?*Surface,
    wl_surface: *c.wl_surface,
    subsurface: ?*c.wl_subsurface,
    syncobj_surface: *c.wp_linux_drm_syncobj_surface_v1,
    viewport: *c.wp_viewport,
    feedback: *c.zwp_linux_dmabuf_feedback_v1,
    color_surface: ?*c.wp_color_management_surface_v1 = null,

    /// Logical size and position relative to the parent (decided by the layout).
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 1,
    height: u32 = 1,
    /// Buffer size changed (logical size or scale); buffers must be reallocated.
    size_changed: bool = true,

    stats: PresentStats = .{},
    /// Outstanding presentation feedback objects (destroyed with the surface, so their
    /// events can never reach freed memory).
    pending_feedback: std.ArrayList(*c.struct_wp_presentation_feedback) = .empty,

    tranches: std.ArrayList(Tranche) = .empty,
    feedback_changed: bool = false,
    feedback_received: bool = false,

    table: ?[]align(std.heap.page_size_min) const u8 = null,
    pending_tranches: std.ArrayList(Tranche) = .empty,
    pending_tranche: ?Tranche = null,

    fn create(display: *Display, window: *Window, parent: ?*Surface) !*Surface {
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
        const feedback = c.zwp_linux_dmabuf_v1_get_surface_feedback(display.dmabuf, wl_surface) orelse return error.DmabufFeedback;
        errdefer c.zwp_linux_dmabuf_feedback_v1_destroy(feedback);

        const self = try gpa.create(Surface);
        self.* = .{
            .display = display,
            .window = window,
            .parent = parent,
            .wl_surface = wl_surface,
            .subsurface = subsurface,
            .syncobj_surface = syncobj_surface,
            .viewport = viewport,
            .feedback = feedback,
        };
        c.wl_surface_set_user_data(wl_surface, self);
        _ = c.zwp_linux_dmabuf_feedback_v1_add_listener(feedback, &feedback_listener, self);
        // Subsurfaces stay in synchronized mode (the default): their commits are applied
        // atomically together with the parent's next commit.
        return self;
    }

    fn destroy(self: *Surface) void {
        const gpa = self.display.gpa;
        if (self.display.pointer_focus == self) self.display.pointer_focus = null;
        for (self.pending_feedback.items) |fb| c.wp_presentation_feedback_destroy(fb);
        self.pending_feedback.deinit(gpa);
        freeTranches(gpa, &self.tranches);
        self.tranches.deinit(gpa);
        freeTranches(gpa, &self.pending_tranches);
        self.pending_tranches.deinit(gpa);
        if (self.pending_tranche) |*t| t.formats.deinit(gpa);
        if (self.table) |t| _ = c.munmap(@constCast(@ptrCast(t.ptr)), t.len);
        if (self.color_surface) |cs| c.wp_color_management_surface_v1_destroy(cs);
        c.zwp_linux_dmabuf_feedback_v1_destroy(self.feedback);
        c.wp_viewport_destroy(self.viewport);
        c.wp_linux_drm_syncobj_surface_v1_destroy(self.syncobj_surface);
        if (self.subsurface) |s| c.wl_subsurface_destroy(s);
        c.wl_surface_destroy(self.wl_surface);
        gpa.destroy(self);
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
        var s: ?*const Surface = self;
        while (s) |cur| : (s = cur.parent) {
            if (cur.parent == null) break;
            x += @floatFromInt(cur.x);
            y += @floatFromInt(cur.y);
        }
        return .{ x, y };
    }

    pub fn bufferWidth(self: *const Surface) u32 {
        return self.window.toBuffer(self.width);
    }

    pub fn bufferHeight(self: *const Surface) u32 {
        return self.window.toBuffer(self.height);
    }

    pub fn setImageDescription(self: *Surface, desc: ?*c.wp_image_description_v1) !void {
        const d = desc orelse return;
        if (self.color_surface == null) {
            const cm = self.display.color_manager orelse return error.NoColorManagement;
            self.color_surface = c.wp_color_manager_v1_get_surface(cm, self.wl_surface) orelse return error.ColorSurface;
        }
        c.wp_color_management_surface_v1_set_image_description(self.color_surface, d, c.WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);
    }

    /// Attaches `buffer` with explicit-sync points and damage (buffer pixels; empty = all),
    /// and requests presentation feedback. Does not commit.
    /// Called from render tasks: libwayland requests are thread-safe and events are only
    /// dispatched on the main thread.
    pub fn attach(
        self: *Surface,
        buffer: *c.wl_buffer,
        timeline: *c.wp_linux_drm_syncobj_timeline_v1,
        acquire_point: u64,
        release_point: u64,
        damage: []const [4]i32,
    ) void {
        c.wp_linux_drm_syncobj_surface_v1_set_acquire_point(self.syncobj_surface, timeline, @truncate(acquire_point >> 32), @truncate(acquire_point));
        c.wp_linux_drm_syncobj_surface_v1_set_release_point(self.syncobj_surface, timeline, @truncate(release_point >> 32), @truncate(release_point));
        c.wl_surface_attach(self.wl_surface, buffer, 0, 0);
        c.wp_viewport_set_destination(self.viewport, @intCast(self.width), @intCast(self.height));
        if (damage.len == 0) {
            c.wl_surface_damage_buffer(self.wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        } else for (damage) |d| {
            c.wl_surface_damage_buffer(self.wl_surface, d[0], d[1], d[2], d[3]);
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

    fn pfSyncOutput(_: ?*anyopaque, _: ?*c.struct_wp_presentation_feedback, _: ?*c.wl_output) callconv(.c) void {}
    fn pfPresented(data: ?*anyopaque, fb: ?*c.struct_wp_presentation_feedback, sec_hi: u32, sec_lo: u32, nsec: u32, refresh: u32, _: u32, _: u32, flags: u32) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.forgetFeedback(fb);
        const sec = (@as(u64, sec_hi) << 32) | sec_lo;
        self.stats.presented += 1;
        if (flags & c.WP_PRESENTATION_FEEDBACK_KIND_ZERO_COPY != 0) self.stats.zero_copy += 1;
        self.stats.last_present_ns = @as(i128, sec) * std.time.ns_per_s + nsec;
        if (refresh != 0) self.stats.refresh_ns = refresh;
    }
    fn pfDiscarded(data: ?*anyopaque, fb: ?*c.struct_wp_presentation_feedback) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.forgetFeedback(fb);
        self.stats.discarded += 1;
    }

    fn freeTranches(gpa: Allocator, list: *std.ArrayList(Tranche)) void {
        for (list.items) |*t| t.formats.deinit(gpa);
        list.clearRetainingCapacity();
    }

    fn fbDone(data: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data));
        freeTranches(self.display.gpa, &self.tranches);
        std.mem.swap(std.ArrayList(Tranche), &self.tranches, &self.pending_tranches);
        self.feedback_changed = true;
        self.feedback_received = true;
    }

    fn fbFormatTable(data: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, fd: i32, size: u32) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data));
        defer _ = c.close(fd);
        if (self.table) |t| _ = c.munmap(@constCast(@ptrCast(t.ptr)), t.len);
        self.table = null;
        const ptr = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (ptr == c.MAP_FAILED) {
            std.log.err("failed to mmap dmabuf format table", .{});
            return;
        }
        self.table = @as([*]align(std.heap.page_size_min) const u8, @ptrCast(@alignCast(ptr)))[0..size];
    }

    fn fbMainDevice(_: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, _: [*c]c.wl_array) callconv(.c) void {}

    fn fbTrancheDone(data: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data));
        if (self.pending_tranche) |t| {
            self.pending_tranches.append(self.display.gpa, t) catch {
                var tt = t;
                tt.formats.deinit(self.display.gpa);
            };
        }
        self.pending_tranche = null;
    }

    fn pending(self: *Surface) *Tranche {
        if (self.pending_tranche == null) self.pending_tranche = .{ .target_device = 0, .flags = 0, .formats = .empty };
        return &self.pending_tranche.?;
    }

    fn fbTrancheTargetDevice(data: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, arr: [*c]c.wl_array) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data));
        if (arr.*.size != @sizeOf(u64)) return;
        self.pending().target_device = @as(*align(1) const u64, @ptrCast(arr.*.data)).*;
    }

    fn fbTrancheFormats(data: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, arr: [*c]c.wl_array) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data));
        const table = self.table orelse return;
        const entries = std.mem.bytesAsSlice(FormatModifier, table[0 .. table.len / @sizeOf(FormatModifier) * @sizeOf(FormatModifier)]);
        const indices = @as([*]align(1) const u16, @ptrCast(arr.*.data))[0 .. arr.*.size / 2];
        const t = self.pending();
        for (indices) |i| {
            if (i >= entries.len) continue;
            t.formats.append(self.display.gpa, entries[i]) catch return;
        }
    }

    fn fbTrancheFlags(data: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, flags: u32) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.pending().flags = flags;
    }

    const feedback_listener: c.zwp_linux_dmabuf_feedback_v1_listener = .{
        .done = fbDone,
        .format_table = fbFormatTable,
        .main_device = fbMainDevice,
        .tranche_done = fbTrancheDone,
        .tranche_target_device = fbTrancheTargetDevice,
        .tranche_formats = fbTrancheFormats,
        .tranche_flags = fbTrancheFlags,
    };
    const presentation_feedback_listener: c.wp_presentation_feedback_listener = .{
        .sync_output = pfSyncOutput,
        .presented = pfPresented,
        .discarded = pfDiscarded,
    };
};

pub const PointerHandler = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, ev: PointerEvent) void,
};

/// An xdg toplevel: a root Surface plus any number of subsurfaces (a surface tree).
/// Frame pacing is per tree: one frame callback on the root drives every surface in it.
pub const Window = struct {
    display: *Display,
    root: *Surface,
    subsurfaces: std.ArrayList(*Surface) = .empty,
    xdg_surface: *c.xdg_surface,
    toplevel: *c.xdg_toplevel,
    decoration: ?*c.zxdg_toplevel_decoration_v1 = null,
    fractional_scale: *c.wp_fractional_scale_v1,
    frame_callback: ?*c.wl_callback = null,
    pointer_handler: ?PointerHandler = null,

    /// Logical window geometry size (includes client-side decorations).
    width: u32 = 800,
    height: u32 = 600,
    /// Fractional scale in 120ths (120 = 1.0).
    scale_120: u32 = 120,
    /// We draw decorations ourselves; false if the compositor insists on server-side.
    csd: bool = true,
    maximized: bool = false,
    fullscreen: bool = false,
    activated: bool = false,
    tiled: bool = false,

    configured: bool = false,
    /// Size, scale, decoration mode or toplevel state changed since the last layout.
    layout_dirty: bool = true,
    should_close: bool = false,
    /// Set when the compositor wants a new frame for this tree; cleared on commit.
    frame_ready: bool = true,

    pub fn create(display: *Display, title: [:0]const u8) !*Window {
        const gpa = display.gpa;
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .display = display, .root = undefined, .xdg_surface = undefined, .toplevel = undefined, .fractional_scale = undefined };

        self.root = try Surface.create(display, self, null);
        errdefer self.root.destroy();
        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(display.wm_base, self.root.wl_surface) orelse return error.XdgSurface;
        errdefer c.xdg_surface_destroy(self.xdg_surface);
        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse return error.XdgToplevel;
        errdefer c.xdg_toplevel_destroy(self.toplevel);
        self.fractional_scale = c.wp_fractional_scale_manager_v1_get_fractional_scale(display.fractional_scale_manager, self.root.wl_surface) orelse
            return error.FractionalScale;
        errdefer c.wp_fractional_scale_v1_destroy(self.fractional_scale);

        _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);
        _ = c.xdg_toplevel_add_listener(self.toplevel, &toplevel_listener, self);
        _ = c.wp_fractional_scale_v1_add_listener(self.fractional_scale, &fractional_scale_listener, self);
        if (display.decoration_manager) |dm| {
            self.decoration = c.zxdg_decoration_manager_v1_get_toplevel_decoration(dm, self.toplevel);
            _ = c.zxdg_toplevel_decoration_v1_add_listener(self.decoration, &decoration_listener, self);
            c.zxdg_toplevel_decoration_v1_set_mode(self.decoration, c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
        }
        c.xdg_toplevel_set_title(self.toplevel, title);
        c.xdg_toplevel_set_app_id(self.toplevel, "codotaka");
        c.xdg_toplevel_set_min_size(self.toplevel, 240, 160);
        self.root.commit();

        while (!self.configured or !self.root.feedback_received) {
            if (c.wl_display_dispatch(display.display) < 0) return error.WaylandDispatch;
        }
        return self;
    }

    pub fn destroy(self: *Window) void {
        const gpa = self.display.gpa;
        if (self.frame_callback) |cb| c.wl_callback_destroy(cb);
        for (self.subsurfaces.items) |s| s.destroy();
        self.subsurfaces.deinit(gpa);
        if (self.decoration) |d| c.zxdg_toplevel_decoration_v1_destroy(d);
        c.wp_fractional_scale_v1_destroy(self.fractional_scale);
        c.xdg_toplevel_destroy(self.toplevel);
        c.xdg_surface_destroy(self.xdg_surface);
        self.root.destroy();
        gpa.destroy(self);
    }

    /// Logical -> buffer pixels for this window's fractional scale.
    pub fn toBuffer(self: *const Window, v: anytype) switch (@TypeOf(v)) {
        u32 => u32,
        i32 => i32,
        else => f32,
    } {
        return switch (@TypeOf(v)) {
            u32 => @intCast(@max(1, (@as(u64, v) * self.scale_120 + 60) / 120)),
            i32 => @intFromFloat(@round(@as(f64, @floatFromInt(v)) * @as(f64, @floatFromInt(self.scale_120)) / 120.0)),
            else => @as(f32, v) * @as(f32, @floatFromInt(self.scale_120)) / 120.0,
        };
    }

    /// Creates a subsurface of `parent` (the root or another subsurface of this window).
    pub fn createSubsurface(self: *Window, parent: *Surface) !*Surface {
        try self.subsurfaces.ensureUnusedCapacity(self.display.gpa, 1);
        const s = try Surface.create(self.display, self, parent);
        errdefer s.destroy();
        while (!s.feedback_received) {
            if (c.wl_display_dispatch(self.display.display) < 0) return error.WaylandDispatch;
        }
        self.subsurfaces.appendAssumeCapacity(s);
        return s;
    }

    /// Destroys a subsurface; it disappears with the parent's next commit.
    pub fn destroySubsurface(self: *Window, s: *Surface) void {
        if (std.mem.indexOfScalar(*Surface, self.subsurfaces.items, s)) |i| _ = self.subsurfaces.orderedRemove(i);
        s.destroy();
    }

    pub fn setGeometry(self: *Window) void {
        c.xdg_surface_set_window_geometry(self.xdg_surface, 0, 0, @intCast(self.width), @intCast(self.height));
    }

    /// Commits the whole tree atomically: subsurfaces first (cached, synchronized mode),
    /// then the root with a frame callback for pacing.
    pub fn commitTree(self: *Window) void {
        var i = self.subsurfaces.items.len;
        while (i > 0) {
            i -= 1;
            self.subsurfaces.items[i].commit();
        }
        if (self.frame_callback) |old| c.wl_callback_destroy(old);
        const cb = c.wl_surface_frame(self.root.wl_surface);
        _ = c.wl_callback_add_listener(cb, &frame_listener, self);
        self.frame_callback = cb;
        self.frame_ready = false;
        self.root.commit();
    }

    pub fn onPointer(self: *Window, ev: PointerEvent) void {
        if (self.pointer_handler) |h| h.func(h.ctx, ev);
    }

    // Window-management requests used by client-side decorations.
    pub fn move(self: *Window, serial: u32) void {
        if (self.display.seat) |seat| c.xdg_toplevel_move(self.toplevel, seat, serial);
    }
    pub fn resize(self: *Window, serial: u32, edge: u32) void {
        if (self.display.seat) |seat| c.xdg_toplevel_resize(self.toplevel, seat, serial, edge);
    }
    pub fn toggleMaximized(self: *Window) void {
        if (self.maximized) c.xdg_toplevel_unset_maximized(self.toplevel) else c.xdg_toplevel_set_maximized(self.toplevel);
    }
    pub fn minimize(self: *Window) void {
        c.xdg_toplevel_set_minimized(self.toplevel);
    }
    pub fn close(self: *Window) void {
        self.should_close = true;
    }
    pub fn showMenu(self: *Window, serial: u32, x: i32, y: i32) void {
        if (self.display.seat) |seat| c.xdg_toplevel_show_window_menu(self.toplevel, seat, serial, x, y);
    }

    fn frameDone(data: ?*anyopaque, cb: ?*c.wl_callback, _: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        c.wl_callback_destroy(cb);
        if (self.frame_callback == cb) self.frame_callback = null;
        self.frame_ready = true;
    }

    fn surfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        c.xdg_surface_ack_configure(xdg_surface, serial);
        self.configured = true;
    }

    fn toplevelConfigure(data: ?*anyopaque, _: ?*c.xdg_toplevel, w: i32, h: i32, states: [*c]c.wl_array) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        var maximized = false;
        var fullscreen = false;
        var activated = false;
        var tiled = false;
        const list = @as([*]align(1) const u32, @ptrCast(states.*.data))[0 .. states.*.size / 4];
        for (list) |s| switch (s) {
            c.XDG_TOPLEVEL_STATE_MAXIMIZED => maximized = true,
            c.XDG_TOPLEVEL_STATE_FULLSCREEN => fullscreen = true,
            c.XDG_TOPLEVEL_STATE_ACTIVATED => activated = true,
            c.XDG_TOPLEVEL_STATE_TILED_LEFT, c.XDG_TOPLEVEL_STATE_TILED_RIGHT, c.XDG_TOPLEVEL_STATE_TILED_TOP, c.XDG_TOPLEVEL_STATE_TILED_BOTTOM => tiled = true,
            else => {},
        };
        if (maximized != self.maximized or fullscreen != self.fullscreen or activated != self.activated or tiled != self.tiled) {
            self.maximized = maximized;
            self.fullscreen = fullscreen;
            self.activated = activated;
            self.tiled = tiled;
            self.layout_dirty = true;
        }
        if (w > 0 and h > 0) {
            const nw: u32 = @intCast(w);
            const nh: u32 = @intCast(h);
            if (nw != self.width or nh != self.height) {
                self.width = nw;
                self.height = nh;
                self.layout_dirty = true;
            }
        }
    }

    fn toplevelClose(data: ?*anyopaque, _: ?*c.xdg_toplevel) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        self.should_close = true;
    }

    fn toplevelBounds(_: ?*anyopaque, _: ?*c.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
    fn toplevelCaps(_: ?*anyopaque, _: ?*c.xdg_toplevel, _: [*c]c.wl_array) callconv(.c) void {}

    fn decorationConfigure(data: ?*anyopaque, _: ?*c.zxdg_toplevel_decoration_v1, mode: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        const csd = mode == c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;
        if (csd != self.csd) {
            self.csd = csd;
            self.layout_dirty = true;
        }
    }

    fn preferredScale(data: ?*anyopaque, _: ?*c.wp_fractional_scale_v1, scale: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        if (scale == self.scale_120) return;
        self.scale_120 = scale;
        self.root.size_changed = true;
        for (self.subsurfaces.items) |s| s.size_changed = true;
        self.layout_dirty = true;
    }

    const xdg_surface_listener: c.xdg_surface_listener = .{ .configure = surfaceConfigure };
    const toplevel_listener: c.xdg_toplevel_listener = .{
        .configure = toplevelConfigure,
        .close = toplevelClose,
        .configure_bounds = toplevelBounds,
        .wm_capabilities = toplevelCaps,
    };
    const frame_listener: c.wl_callback_listener = .{ .done = frameDone };
    const decoration_listener: c.zxdg_toplevel_decoration_v1_listener = .{ .configure = decorationConfigure };
    const fractional_scale_listener: c.wp_fractional_scale_v1_listener = .{ .preferred_scale = preferredScale };
};
