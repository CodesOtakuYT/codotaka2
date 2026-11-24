//! Fonts: discovery and per-codepoint fallback via fontconfig, faces via FreeType (for
//! rasterization) and HarfBuzz (for shaping, scale-independent OpenType funcs), plus the
//! CPU glyph cache. Single-threaded: use from one thread (the planning thread).
const FontSystem = @This();

const std = @import("std");
const c = @import("text_c");
const GlyphCache = @import("GlyphCache.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.text);

pub const FontId = u16;

pub const Font = struct {
    path: [:0]u8,
    index: c_int,
    face: c.FT_Face,
    hb_face: *c.hb_face_t,
    hb_font: *c.hb_font_t,
};

gpa: Allocator,
ft: c.FT_Library,
fonts: std.ArrayList(Font) = .empty,
/// codepoint -> font that covers it (fallback cache; primary font coverage is checked first)
fallback: std.AutoHashMapUnmanaged(u21, FontId) = .empty,
glyphs: GlyphCache,

/// Loads the default font for `family` (e.g. "sans-serif") as font 0.
pub fn create(gpa: Allocator, family: [:0]const u8) !*FontSystem {
    if (c.FcInit() == 0) return error.FontconfigInit;
    var ft: c.FT_Library = null;
    if (c.FT_Init_FreeType(&ft) != 0) return error.FreeTypeInit;
    errdefer _ = c.FT_Done_FreeType(ft);
    c.init_linebreak();
    c.init_graphemebreak();
    c.init_wordbreak();

    const self = try gpa.create(FontSystem);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .ft = ft, .glyphs = .init(gpa) };
    errdefer self.deinitFonts();

    const pattern = c.FcNameParse(family.ptr) orelse return error.FontPattern;
    defer c.FcPatternDestroy(pattern);
    _ = try self.matchAndLoad(pattern) orelse return error.NoDefaultFont;
    log.info("default font: {s}", .{self.fonts.items[0].path});
    return self;
}

pub fn destroy(self: *FontSystem) void {
    self.glyphs.deinit();
    self.fallback.deinit(self.gpa);
    self.deinitFonts();
    _ = c.FT_Done_FreeType(self.ft);
    self.gpa.destroy(self);
}

fn deinitFonts(self: *FontSystem) void {
    for (self.fonts.items) |f| {
        c.hb_font_destroy(f.hb_font);
        c.hb_face_destroy(f.hb_face);
        _ = c.FT_Done_Face(f.face);
        self.gpa.free(f.path);
    }
    self.fonts.deinit(self.gpa);
}

pub fn font(self: *const FontSystem, id: FontId) *const Font {
    return &self.fonts.items[id];
}

pub fn hasGlyph(self: *const FontSystem, id: FontId, cp: u21) bool {
    return c.FT_Get_Char_Index(self.fonts.items[id].face, cp) != 0;
}

/// The font to use for `cp`: `primary` if it covers it, else a fontconfig fallback.
pub fn fontFor(self: *FontSystem, cp: u21, primary: FontId) FontId {
    if (self.hasGlyph(primary, cp) or isFormatOrSpace(cp)) return primary;
    if (self.fallback.get(cp)) |f| return f;
    const found = self.findFallback(cp) catch null;
    const result = found orelse primary;
    self.fallback.put(self.gpa, cp, result) catch {};
    return result;
}

fn isFormatOrSpace(cp: u21) bool {
    return cp <= 0x20 or (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069);
}

fn findFallback(self: *FontSystem, cp: u21) !?FontId {
    const pattern = c.FcNameParse("sans-serif") orelse return null;
    defer c.FcPatternDestroy(pattern);
    const cs = c.FcCharSetCreate() orelse return null;
    defer c.FcCharSetDestroy(cs);
    _ = c.FcCharSetAddChar(cs, cp);
    _ = c.FcPatternAddCharSet(pattern, c.FC_CHARSET, cs);
    const id = try self.matchAndLoad(pattern) orelse return null;
    if (!self.hasGlyph(id, cp)) return null;
    return id;
}

/// fontconfig match for `pattern`; loads the font (deduplicated by file + index).
fn matchAndLoad(self: *FontSystem, pattern: *c.FcPattern) !?FontId {
    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);
    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pattern, &result) orelse return null;
    defer c.FcPatternDestroy(match);
    var file: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file) != c.FcResultMatch) return null;
    var index: c_int = 0;
    _ = c.FcPatternGetInteger(match, c.FC_INDEX, 0, &index);
    const path = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
    for (self.fonts.items, 0..) |f, i| {
        if (f.index == index and std.mem.eql(u8, f.path, path)) return @intCast(i);
    }
    return try self.load(path, index);
}

fn load(self: *FontSystem, path: []const u8, index: c_int) !FontId {
    const owned = try self.gpa.dupeSentinel(u8, path, 0);
    errdefer self.gpa.free(owned);
    var face: c.FT_Face = null;
    if (c.FT_New_Face(self.ft, owned.ptr, index, &face) != 0) return error.FontLoad;
    errdefer _ = c.FT_Done_Face(face);
    const blob = c.hb_blob_create_from_file(owned.ptr) orelse return error.FontLoad;
    defer c.hb_blob_destroy(blob);
    const hb_face = c.hb_face_create(blob, @intCast(index)) orelse return error.FontLoad;
    errdefer c.hb_face_destroy(hb_face);
    const hb_font = c.hb_font_create(hb_face) orelse return error.FontLoad;
    try self.fonts.append(self.gpa, .{ .path = owned, .index = index, .face = face, .hb_face = hb_face, .hb_font = hb_font });
    log.debug("loaded font {s}#{d}", .{ path, index });
    return @intCast(self.fonts.items.len - 1);
}
