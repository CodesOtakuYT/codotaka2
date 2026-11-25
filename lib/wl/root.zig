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

pub const Modifiers = bitpack struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    _: u3 = 0,
};

pub const KeyEvent = struct {
    kind: enum { press, release, repeat },
    /// xkb keysym (see xkbcommon-keysyms.h, re-exported as `wl.keysym`).
    keysym: u32,
    /// UTF-8 text produced by this key (after compose), if any.
    text_buf: [16]u8 = undefined,
    text_len: u8 = 0,
    mods: Modifiers = .{},
    serial: u32 = 0,
    time: u32 = 0,

    pub fn text(e: *const KeyEvent) []const u8 {
        return e.text_buf[0..e.text_len];
    }
};

/// Common keysyms.
pub const keysym = struct {
    pub const BackSpace: u32 = c.XKB_KEY_BackSpace;
    pub const Return: u32 = c.XKB_KEY_Return;
    pub const KP_Enter: u32 = c.XKB_KEY_KP_Enter;
    pub const Escape: u32 = c.XKB_KEY_Escape;
    pub const Tab: u32 = c.XKB_KEY_Tab;
    pub const Delete: u32 = c.XKB_KEY_Delete;
    pub const q: u32 = c.XKB_KEY_q;
    pub const f: u32 = c.XKB_KEY_f;
    pub const space: u32 = c.XKB_KEY_space;
    pub const Left: u32 = c.XKB_KEY_Left;
    pub const Right: u32 = c.XKB_KEY_Right;
    pub const Home: u32 = c.XKB_KEY_Home;
    pub const i: u32 = c.XKB_KEY_i;
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
