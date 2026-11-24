//! CPU-side rasterized glyphs (8-bit coverage), keyed by font/glyph/size/subpixel offset.
//! Ids are stable for the lifetime of the cache; GPU atlases upload from here on demand.
const GlyphCache = @This();

const std = @import("std");
const c = @import("text_c");
const Allocator = std.mem.Allocator;

pub const GlyphId = enum(u32) { _ };

/// Horizontal subpixel positions per pixel.
pub const subpixel_bins = 4;

pub const Key = struct {
    font: u16,
    glyph: u32,
    /// Pixel size in 26.6 fixed point.
    size: u32,
    bin: u8,
};

pub const Entry = struct {
    width: u16,
    height: u16,
    /// Offset of the bitmap's top-left from the pen position (y down).
    left: i16,
    top: i16,
    offset: u32,
};

gpa: Allocator,
map: std.AutoHashMapUnmanaged(Key, GlyphId) = .empty,
entries: std.ArrayList(Entry) = .empty,
pixels: std.ArrayList(u8) = .empty,

pub fn init(gpa: Allocator) GlyphCache {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *GlyphCache) void {
    self.map.deinit(self.gpa);
    self.entries.deinit(self.gpa);
    self.pixels.deinit(self.gpa);
}

pub fn entry(self: *const GlyphCache, id: GlyphId) Entry {
    return self.entries.items[@intFromEnum(id)];
}

pub fn bitmap(self: *const GlyphCache, id: GlyphId) []const u8 {
    const e = self.entry(id);
    return self.pixels.items[e.offset..][0 .. @as(usize, e.width) * e.height];
}

pub fn count(self: *const GlyphCache) usize {
    return self.entries.items.len;
}

/// Returns the glyph, rasterizing it with FreeType on first use.
pub fn get(self: *GlyphCache, face: c.FT_Face, key: Key) !GlyphId {
    const gop = try self.map.getOrPut(self.gpa, key);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer _ = self.map.remove(key);

    if (c.FT_Set_Char_Size(face, 0, key.size, 72, 72) != 0) return error.FontSize;
    const load_target_light = 1 << 16; // FT_LOAD_TARGET_LIGHT: vertical-only hinting
    if (c.FT_Load_Glyph(face, key.glyph, load_target_light) != 0) return error.GlyphLoad;
    const slot = face.*.glyph;
    if (slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE and key.bin != 0)
        c.FT_Outline_Translate(&slot.*.outline, @as(c.FT_Pos, key.bin) * (64 / subpixel_bins), 0);
    if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) return error.GlyphRender;

    const bm = slot.*.bitmap;
    const offset: u32 = @intCast(self.pixels.items.len);
    const w: usize = bm.width;
    const h: usize = bm.rows;
    try self.pixels.ensureUnusedCapacity(self.gpa, w * h);
    for (0..h) |row| {
        const src: [*]const u8 = @ptrCast(bm.buffer);
        const start: isize = @as(isize, @intCast(row)) * bm.pitch;
        self.pixels.appendSliceAssumeCapacity(src[@intCast(if (bm.pitch < 0) start + @as(isize, @intCast(w * (h - 1))) else start)..][0..w]);
    }
    try self.entries.append(self.gpa, .{
        .width = @intCast(w),
        .height = @intCast(h),
        .left = @intCast(slot.*.bitmap_left),
        .top = @intCast(slot.*.bitmap_top),
        .offset = offset,
    });
    gop.value_ptr.* = @enumFromInt(self.entries.items.len - 1);
    return gop.value_ptr.*;
}
