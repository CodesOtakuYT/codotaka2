//! An xdg toplevel: a root Surface plus any number of subsurfaces (a surface tree).
//! Frame pacing is per tree: one frame callback on the root drives every surface in it.
const Window = @This();

const std = @import("std");
const c = @import("wl_c");
const geom = @import("geom");
const listener = @import("listener.zig").listener;
const Display = @import("Display.zig");
const Surface = @import("Surface.zig");
const wl = @import("root.zig");

pub const PointerHandler = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, ev: wl.PointerEvent) void,
};

pub const KeyHandler = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, ev: wl.KeyEvent) void,
};

display: *Display,
root: *Surface,
subsurfaces: std.ArrayList(*Surface) = .empty,
xdg_surface: *c.xdg_surface,
toplevel: *c.xdg_toplevel,
decoration: ?*c.zxdg_toplevel_decoration_v1 = null,
fractional_scale: *c.wp_fractional_scale_v1,
frame_callback: ?*c.wl_callback = null,
pointer_handler: ?PointerHandler = null,
key_handler: ?KeyHandler = null,

/// Logical window geometry size (includes client-side decorations).
width: u32 = 800,
height: u32 = 600,
scale: geom.Scale = .one,
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

pub fn create(display: *Display, title: [:0]const u8, app_id: [:0]const u8) !*Window {
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
    c.xdg_toplevel_set_app_id(self.toplevel, app_id);
    c.xdg_toplevel_set_min_size(self.toplevel, 240, 160);
    self.root.commit();

    while (!self.configured) try display.dispatch();
    try self.root.waitForFeedback();
    return self;
}

pub fn destroy(self: *Window) void {
    const gpa = self.display.gpa;
    if (self.display.keyboard_focus == self) self.display.keyboardLost();
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

/// Creates a subsurface of `parent` (the root or another subsurface of this window).
pub fn createSubsurface(self: *Window, parent: *Surface) !*Surface {
    try self.subsurfaces.ensureUnusedCapacity(self.display.gpa, 1);
    const s = try Surface.create(self.display, self, parent);
    errdefer s.destroy();
    try s.waitForFeedback();
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

pub fn onPointer(self: *Window, ev: wl.PointerEvent) void {
    if (self.pointer_handler) |h| h.func(h.ctx, ev);
}

pub fn onKey(self: *Window, ev: wl.KeyEvent) void {
    if (self.key_handler) |h| h.func(h.ctx, ev);
}

// Window-management requests (used by client-side decorations).
pub fn move(self: *Window, serial: u32) void {
    if (self.display.seat) |seat| c.xdg_toplevel_move(self.toplevel, seat, serial);
}
pub fn resize(self: *Window, serial: u32, edge: wl.ResizeEdge) void {
    if (self.display.seat) |seat| c.xdg_toplevel_resize(self.toplevel, seat, serial, @intFromEnum(edge));
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
pub fn setCursor(self: *Window, shape: wl.CursorShape) void {
    self.display.setCursor(@intFromEnum(shape));
}

const FrameHandlers = struct {
    pub fn done(self: *Window, cb: ?*c.wl_callback, _: u32) callconv(.c) void {
        c.wl_callback_destroy(cb);
        if (self.frame_callback == cb) self.frame_callback = null;
        self.frame_ready = true;
    }
};

const XdgSurfaceHandlers = struct {
    pub fn configure(self: *Window, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
        c.xdg_surface_ack_configure(xdg_surface, serial);
        self.configured = true;
    }
};

const ToplevelHandlers = struct {
    pub fn configure(self: *Window, _: ?*c.xdg_toplevel, w: i32, h: i32, states: [*c]c.wl_array) callconv(.c) void {
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
    pub fn close(self: *Window, _: ?*c.xdg_toplevel) callconv(.c) void {
        self.should_close = true;
    }
};

const DecorationHandlers = struct {
    pub fn configure(self: *Window, _: ?*c.zxdg_toplevel_decoration_v1, mode: u32) callconv(.c) void {
        const csd = mode == c.ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;
        if (csd != self.csd) {
            self.csd = csd;
            self.layout_dirty = true;
        }
    }
};

const FractionalScaleHandlers = struct {
    pub fn preferred_scale(self: *Window, _: ?*c.wp_fractional_scale_v1, scale: u32) callconv(.c) void {
        if (scale == self.scale.n120) return;
        self.scale = .{ .n120 = scale };
        self.root.size_changed = true;
        for (self.subsurfaces.items) |s| s.size_changed = true;
        self.layout_dirty = true;
    }
};

const xdg_surface_listener = listener(c.xdg_surface_listener, XdgSurfaceHandlers, Window);
const toplevel_listener = listener(c.xdg_toplevel_listener, ToplevelHandlers, Window);
const frame_listener = listener(c.wl_callback_listener, FrameHandlers, Window);
const decoration_listener = listener(c.zxdg_toplevel_decoration_v1_listener, DecorationHandlers, Window);
const fractional_scale_listener = listener(c.wp_fractional_scale_v1_listener, FractionalScaleHandlers, Window);
