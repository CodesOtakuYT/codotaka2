//! The frame plan: what the scene asks the presenter to draw. Shared vocabulary between
//! producers (scene) and consumers (presenter/renderer), owned by neither.
const std = @import("std");
const geom = @import("geom");
const wl = @import("wl");

pub const max_push = 128;

/// A draw: which program (an id the renderer understands) and its push-constant block.
pub const Draw = struct {
    program: u32,
    push: [max_push]u8 align(4) = undefined,
    push_len: u8 = 0,

    pub fn init(program: u32, push: anytype) Draw {
        const T = @TypeOf(push);
        comptime std.debug.assert(@sizeOf(T) <= max_push);
        var d: Draw = .{ .program = program, .push_len = @sizeOf(T) };
        @memcpy(d.push[0..@sizeOf(T)], std.mem.asBytes(&push));
        return d;
    }

    pub fn bytes(d: *const Draw) []const u8 {
        return d.push[0..d.push_len];
    }
};

/// One region of one target showing (part of) a logical viewport, in buffer pixels.
pub const View = struct {
    /// Where the *whole* logical viewport lies in target pixels; may extend past the target,
    /// so a viewport split across several targets renders with continuous content.
    viewport: geom.BufferRectF,
    /// The region of the target this view may write to.
    scissor: geom.BufferRect,
    draw: Draw,
};

pub fn TargetWork(comptime Target: type) type {
    return struct {
        target: *Target,
        views: []const View,
        /// Changed regions; empty = the whole buffer.
        damage: []const geom.BufferRect,
    };
}

/// A surface tree presented atomically. `targets` lists only surfaces that changed; the
/// root is always committed so subsurface state applies.
pub fn TreeWork(comptime Target: type) type {
    return struct {
        window: *wl.Window,
        targets: []const TargetWork(Target),
        /// Set to true by the presenter if the tree was committed this frame.
        committed: *bool,
    };
}
