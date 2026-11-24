//! A connection to the Wayland compositor: globals, seat/pointer, color descriptions,
//! and the poll loop integration. Shared by all windows and surfaces.
const Display = @This();

const std = @import("std");
const linux = std.os.linux;
const c = @import("wl_c");
const listener = @import("listener.zig").listener;
const Surface = @import("Surface.zig");
const root = @import("root.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.wl);

gpa: Allocator,
display: *c.wl_display,
registry: *c.wl_registry,
compositor: ?*c.wl_compositor = null,
subcompositor: ?*c.wl_subcompositor = null,
wm_base: ?*c.xdg_wm_base = null,
decoration_manager: ?*c.zxdg_decoration_manager_v1 = null,
dmabuf: ?*c.zwp_linux_dmabuf_v1 = null,
dmabuf_version: u32 = 0,
syncobj_manager: ?*c.wp_linux_drm_syncobj_manager_v1 = null,
viewporter: ?*c.wp_viewporter = null,
fractional_scale_manager: ?*c.wp_fractional_scale_manager_v1 = null,
presentation: ?*c.wp_presentation = null,
presentation_clock: u32 = @intFromEnum(linux.CLOCK.MONOTONIC),
cursor_shape_manager: ?*c.wp_cursor_shape_manager_v1 = null,

color_manager: ?*c.wp_color_manager_v1 = null,
color_features: u32 = 0,
color_tfs: u32 = 0,
color_primaries: u32 = 0,
descriptions: std.EnumArray(root.ColorMode, ?*c.wp_image_description_v1) = .initFill(null),

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
    try self.roundtrip();
    try self.roundtrip();
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
        if (@field(self, req[0]) == null) {
            log.err("compositor lacks a required global ({s})", .{req[0]});
            return req[1];
        }
    }
    if (self.presentation_clock != @intFromEnum(linux.CLOCK.MONOTONIC))
        log.warn("presentation clock is {d}, not CLOCK_MONOTONIC; frame timing will be off", .{self.presentation_clock});
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

pub fn roundtrip(self: *Display) !void {
    if (c.wl_display_roundtrip(self.display) < 0) return error.WaylandRoundtrip;
}

/// Blocks until at least one event was dispatched.
pub fn dispatch(self: *Display) !void {
    if (c.wl_display_dispatch(self.display) < 0) return error.WaylandDispatch;
}

pub fn flush(self: *Display) void {
    _ = c.wl_display_flush(self.display);
}

/// Reads and dispatches Wayland events. With `timeout_ms == 0` this never blocks;
/// otherwise it sleeps until Wayland traffic arrives, one of `extra_fds` becomes
/// readable, or the timeout expires (-1 = forever).
pub fn wait(self: *Display, extra_fds: []const linux.fd_t, timeout_ms: i32) !void {
    while (c.wl_display_prepare_read(self.display) != 0) {
        if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatch;
    }
    _ = c.wl_display_flush(self.display);

    var fds_buf: [64]linux.pollfd = undefined;
    const n = @min(extra_fds.len, fds_buf.len - 1) + 1;
    fds_buf[0] = .{ .fd = c.wl_display_get_fd(self.display), .events = linux.POLL.IN, .revents = 0 };
    for (extra_fds[0 .. n - 1], fds_buf[1..n]) |fd, *p| p.* = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };

    const rc = linux.poll(&fds_buf, n, timeout_ms);
    if (linux.errno(rc) == .SUCCESS and rc > 0 and fds_buf[0].revents & linux.POLL.IN != 0) {
        if (c.wl_display_read_events(self.display) < 0) return error.WaylandRead;
    } else {
        c.wl_display_cancel_read(self.display);
    }
    if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatch;
}

/// The compositor-side image description for `mode`, created once and cached.
/// Returns null for SDR when the compositor has no color management (implicit sRGB).
pub fn imageDescription(self: *Display, mode: root.ColorMode) !?*c.wp_image_description_v1 {
    if (self.descriptions.get(mode)) |d| return d;
    const cm = self.color_manager orelse return switch (mode) {
        .sdr => null,
        .hdr_scrgb => error.NoColorManagement,
    };
    const desc = switch (mode) {
        .sdr => blk: {
            if (self.color_features & bit(c.WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC) == 0 or
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
    while (state == .pending) try self.dispatch();
    if (state == .failed) {
        c.wp_image_description_v1_destroy(desc);
        return error.ImageDescriptionFailed;
    }
    self.descriptions.set(mode, desc);
    return desc;
}

pub fn setCursor(self: *Display, shape: u32) void {
    if (self.cursor_shape_device) |d| c.wp_cursor_shape_device_v1_set_shape(d, self.pointer_serial, shape);
}

fn bit(v: anytype) u32 {
    return @as(u32, 1) << @intCast(v);
}

fn dispatchPointer(self: *Display, ev: root.PointerEvent) void {
    const s = self.pointer_focus orelse return;
    var e = ev;
    const origin = s.windowOrigin();
    e.x = self.pointer_x + origin[0];
    e.y = self.pointer_y + origin[1];
    s.window.onPointer(e);
}

const DescriptionState = enum { pending, ready, failed };

const DescriptionHandlers = struct {
    pub fn failed(state: *DescriptionState, _: ?*c.wp_image_description_v1, _: u32, msg: [*c]const u8) callconv(.c) void {
        log.err("image description failed: {s}", .{msg});
        state.* = .failed;
    }
    pub fn ready(state: *DescriptionState, _: ?*c.wp_image_description_v1, _: u32) callconv(.c) void {
        state.* = .ready;
    }
    pub fn ready2(state: *DescriptionState, _: ?*c.wp_image_description_v1, _: u32, _: u32) callconv(.c) void {
        state.* = .ready;
    }
};

const RegistryHandlers = struct {
    pub fn global(self: *Display, registry: ?*c.wl_registry, name: u32, iface_c: [*c]const u8, version: u32) callconv(.c) void {
        const iface = std.mem.span(iface_c);
        const bind = struct {
            fn f(r: ?*c.wl_registry, n: u32, comptime T: type, comptime interface: *const c.wl_interface, v: u32) ?*T {
                return @ptrCast(c.wl_registry_bind(r, n, interface, v));
            }
        }.f;
        if (is(iface, &c.wl_compositor_interface)) {
            self.compositor = bind(registry, name, c.wl_compositor, &c.wl_compositor_interface, @min(version, 4));
        } else if (is(iface, &c.wl_subcompositor_interface)) {
            self.subcompositor = bind(registry, name, c.wl_subcompositor, &c.wl_subcompositor_interface, 1);
        } else if (is(iface, &c.xdg_wm_base_interface)) {
            self.wm_base = bind(registry, name, c.xdg_wm_base, &c.xdg_wm_base_interface, @min(version, 6));
            _ = c.xdg_wm_base_add_listener(self.wm_base, &wm_base_listener, self);
        } else if (is(iface, &c.zxdg_decoration_manager_v1_interface)) {
            self.decoration_manager = bind(registry, name, c.zxdg_decoration_manager_v1, &c.zxdg_decoration_manager_v1_interface, 1);
        } else if (is(iface, &c.zwp_linux_dmabuf_v1_interface) and version >= 4) {
            self.dmabuf_version = @min(version, 6);
            self.dmabuf = bind(registry, name, c.zwp_linux_dmabuf_v1, &c.zwp_linux_dmabuf_v1_interface, self.dmabuf_version);
        } else if (is(iface, &c.wp_linux_drm_syncobj_manager_v1_interface)) {
            self.syncobj_manager = bind(registry, name, c.wp_linux_drm_syncobj_manager_v1, &c.wp_linux_drm_syncobj_manager_v1_interface, 1);
        } else if (is(iface, &c.wp_viewporter_interface)) {
            self.viewporter = bind(registry, name, c.wp_viewporter, &c.wp_viewporter_interface, 1);
        } else if (is(iface, &c.wp_fractional_scale_manager_v1_interface)) {
            self.fractional_scale_manager = bind(registry, name, c.wp_fractional_scale_manager_v1, &c.wp_fractional_scale_manager_v1_interface, 1);
        } else if (is(iface, &c.wp_presentation_interface)) {
            self.presentation = bind(registry, name, c.wp_presentation, &c.wp_presentation_interface, 1);
            _ = c.wp_presentation_add_listener(self.presentation, &presentation_listener, self);
        } else if (is(iface, &c.wp_color_manager_v1_interface)) {
            self.color_manager = bind(registry, name, c.wp_color_manager_v1, &c.wp_color_manager_v1_interface, 1);
            _ = c.wp_color_manager_v1_add_listener(self.color_manager, &color_manager_listener, self);
        } else if (is(iface, &c.wp_cursor_shape_manager_v1_interface)) {
            self.cursor_shape_manager = bind(registry, name, c.wp_cursor_shape_manager_v1, &c.wp_cursor_shape_manager_v1_interface, 1);
        } else if (is(iface, &c.wl_seat_interface) and self.seat == null) {
            // Version 5: newer pointer events (value120, relative direction, warp) are never sent.
            self.seat = bind(registry, name, c.wl_seat, &c.wl_seat_interface, @min(version, 5));
            _ = c.wl_seat_add_listener(self.seat, &seat_listener, self);
        }
    }

    pub fn is(name: []const u8, interface: *const c.wl_interface) bool {
        return std.mem.eql(u8, name, std.mem.span(interface.name));
    }
};

const WmBaseHandlers = struct {
    pub fn ping(_: *Display, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
        c.xdg_wm_base_pong(wm_base, serial);
    }
};

const PresentationHandlers = struct {
    pub fn clock_id(self: *Display, _: ?*c.wp_presentation, clk: u32) callconv(.c) void {
        self.presentation_clock = clk;
    }
};

const ColorManagerHandlers = struct {
    pub fn supported_feature(self: *Display, _: ?*c.wp_color_manager_v1, f: u32) callconv(.c) void {
        if (f < 32) self.color_features |= bit(f);
    }
    pub fn supported_tf_named(self: *Display, _: ?*c.wp_color_manager_v1, f: u32) callconv(.c) void {
        if (f < 32) self.color_tfs |= bit(f);
    }
    pub fn supported_primaries_named(self: *Display, _: ?*c.wp_color_manager_v1, f: u32) callconv(.c) void {
        if (f < 32) self.color_primaries |= bit(f);
    }
};

const SeatHandlers = struct {
    pub fn capabilities(self: *Display, seat: ?*c.wl_seat, caps: u32) callconv(.c) void {
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
};

const PointerHandlers = struct {
    pub fn enter(self: *Display, _: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
        self.pointer_focus = if (surface) |ws| @ptrCast(@alignCast(c.wl_surface_get_user_data(ws))) else null;
        self.pointer_serial = serial;
        self.pointer_x = c.wl_fixed_to_double(x);
        self.pointer_y = c.wl_fixed_to_double(y);
        self.setCursor(c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT);
        self.dispatchPointer(.{ .kind = .enter, .serial = serial });
    }
    pub fn leave(self: *Display, _: ?*c.wl_pointer, serial: u32, _: ?*c.wl_surface) callconv(.c) void {
        self.dispatchPointer(.{ .kind = .leave, .serial = serial });
        self.pointer_focus = null;
    }
    pub fn motion(self: *Display, _: ?*c.wl_pointer, time: u32, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
        self.pointer_x = c.wl_fixed_to_double(x);
        self.pointer_y = c.wl_fixed_to_double(y);
        self.dispatchPointer(.{ .kind = .motion, .time = time });
    }
    pub fn button(self: *Display, _: ?*c.wl_pointer, serial: u32, time: u32, btn: u32, state: u32) callconv(.c) void {
        self.dispatchPointer(.{
            .kind = .button,
            .button = btn,
            .pressed = state == c.WL_POINTER_BUTTON_STATE_PRESSED,
            .serial = serial,
            .time = time,
        });
    }
};

const registry_listener = listener(c.wl_registry_listener, RegistryHandlers, Display);
const wm_base_listener = listener(c.xdg_wm_base_listener, WmBaseHandlers, Display);
const presentation_listener = listener(c.wp_presentation_listener, PresentationHandlers, Display);
const color_manager_listener = listener(c.wp_color_manager_v1_listener, ColorManagerHandlers, Display);
const seat_listener = listener(c.wl_seat_listener, SeatHandlers, Display);
const pointer_listener = listener(c.wl_pointer_listener, PointerHandlers, Display);
const description_listener = listener(c.wp_image_description_v1_listener, DescriptionHandlers, DescriptionState);
