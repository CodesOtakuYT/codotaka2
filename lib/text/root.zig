//! Text: fonts (fontconfig + FreeType + HarfBuzz), bidi and script itemization (SheenBidi),
//! segmentation (libunibreak), layout, and a CPU glyph cache. GPU-agnostic: layouts produce
//! `Quad`s referencing `GlyphCache` ids that a renderer uploads to its own atlas.
pub const FontSystem = @import("FontSystem.zig");
pub const GlyphCache = @import("GlyphCache.zig");
const layout_mod = @import("layout.zig");
pub const layout = layout_mod.layout;
pub const Options = layout_mod.Options;
pub const Layout = layout_mod.Layout;
pub const Quad = layout_mod.Quad;
pub const Line = layout_mod.Line;
pub const prevGrapheme = layout_mod.prevGrapheme;

const std = @import("std");
const frame = @import("frame");

/// Push data of text draws (after the renderer's data address); data is `[]Quad`.
/// The renderer resolves glyph ids to its atlas and appends its own fields.
pub const DrawPush = extern struct {
    size_px: [2]f32,
    white_scale: f32,
    _pad: f32 = 0,
};

/// A text draw for `program` (the renderer's text program): 6 vertices per quad, one
/// instance per quad, quads as per-draw data. `quads` must outlive the frame (use the arena).
pub fn draw(program: u32, quads: []const Quad, size_px: [2]f32, white_scale: f32) frame.Draw {
    var d = frame.Draw.init(program, DrawPush{ .size_px = size_px, .white_scale = white_scale });
    d.data = std.mem.sliceAsBytes(quads);
    d.vertex_count = 6;
    d.instance_count = @intCast(quads.len);
    return d;
}
