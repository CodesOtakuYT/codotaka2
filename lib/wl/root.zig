//! Wayland client layer: display, surface trees (toplevel + subsurfaces), input, and the
//! protocol objects needed for dmabuf/explicit-sync presentation.
const std = @import("std");

pub const c = @import("wl_c");
pub const listener = @import("listener.zig").listener;
pub const Display = @import("Display.zig");
pub const Surface = @import("Surface.zig");
pub const Window = @import("Window.zig");

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

pub const Button = struct {
    pub const left: u32 = c.BTN_LEFT;
    pub const right: u32 = c.BTN_RIGHT;
    pub const middle: u32 = c.BTN_MIDDLE;
};

pub const ResizeEdge = enum(u32) {
    none = c.XDG_TOPLEVEL_RESIZE_EDGE_NONE,
    top = c.XDG_TOPLEVEL_RESIZE_EDGE_TOP,
    bottom = c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM,
    left = c.XDG_TOPLEVEL_RESIZE_EDGE_LEFT,
    top_left = c.XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT,
    bottom_left = c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT,
    right = c.XDG_TOPLEVEL_RESIZE_EDGE_RIGHT,
    top_right = c.XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT,
    bottom_right = c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT,
};

pub const CursorShape = enum(u32) {
    default = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT,
    n_resize = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_N_RESIZE,
    s_resize = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_S_RESIZE,
    e_resize = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_E_RESIZE,
    w_resize = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_W_RESIZE,
    ne_resize = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NE_RESIZE,
    nw_resize = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NW_RESIZE,
    se_resize = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SE_RESIZE,
    sw_resize = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SW_RESIZE,
};

pub const PresentStats = struct {
    presented: u64 = 0,
    zero_copy: u64 = 0,
    discarded: u64 = 0,
    last_present_ns: i128 = 0,
    refresh_ns: u32 = 0,
};
