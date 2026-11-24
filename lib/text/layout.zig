//! Paragraph layout: SheenBidi (UAX #9 levels + visual runs, UAX #24 script runs),
//! fontconfig fallback per codepoint, HarfBuzz shaping, libunibreak line breaking (UAX #14)
//! and grapheme boundaries (UAX #29). Offsets are UTF-8 byte offsets throughout.
const std = @import("std");
const c = @import("text_c");
const FontSystem = @import("FontSystem.zig");
const GlyphCache = @import("GlyphCache.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    size_px: f32,
    /// Wrap at this width (pixels); null = one line per paragraph.
    max_width: ?f32 = null,
    /// Linear, premultiplied RGBA.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    line_height: f32 = 1.25,
    font: FontSystem.FontId = 0,
};

/// One positioned glyph; also the per-instance format text draws carry to the renderer.
pub const Quad = extern struct {
    /// Bitmap top-left relative to the layout origin (pixels, y down).
    x: f32,
    y: f32,
    glyph: u32,
    color: [4]f32,
};

pub const Line = struct {
    start: u32,
    end: u32,
    baseline: f32,
    width: f32,
};

pub const Layout = struct {
    quads: []Quad,
    lines: []Line,
    /// Byte offsets of grapheme cluster boundaries (caret stops), including 0 and len.
    graphemes: []u32,
    width: f32,
    height: f32,
};

const Item = struct { start: u32, end: u32, level: u8, script: c.hb_script_t, font: FontSystem.FontId };

/// Lays out `text` (UTF-8; '\n' separates paragraphs) into `arena`.
pub fn layout(fs: *FontSystem, arena: Allocator, text: []const u8, opts: Options) !Layout {
    var quads: std.ArrayList(Quad) = .empty;
    var lines: std.ArrayList(Line) = .empty;
    const size26: u32 = @intFromFloat(@round(opts.size_px * 64));

    const primary = fs.font(opts.font);
    c.hb_font_set_scale(primary.hb_font, @intCast(size26), @intCast(size26));
    var extents: c.hb_font_extents_t = undefined;
    _ = c.hb_font_get_h_extents(primary.hb_font, &extents);
    const ascent = @as(f32, @floatFromInt(extents.ascender)) / 64;
    const advance_y = opts.size_px * opts.line_height;

    const buf = c.hb_buffer_create() orelse return error.OutOfMemory;
    defer c.hb_buffer_destroy(buf);

    var y: f32 = 0;
    var width: f32 = 0;
    var para_start: usize = 0;
    while (para_start <= text.len) {
        const para_end = std.mem.indexOfScalarPos(u8, text, para_start, '\n') orelse text.len;
        const para = text[para_start..para_end];
        if (para.len == 0) {
            try lines.append(arena, .{ .start = @intCast(para_start), .end = @intCast(para_start), .baseline = y + ascent, .width = 0 });
            y += advance_y;
        } else {
            try layoutParagraph(fs, arena, buf, text, para_start, para, opts, size26, ascent, advance_y, &y, &width, &quads, &lines);
        }
        if (para_end == text.len) break;
        para_start = para_end + 1;
    }

    // Grapheme boundaries for carets/selection.
    var graphemes: std.ArrayList(u32) = .empty;
    try graphemes.append(arena, 0);
    if (text.len > 0) {
        const brks = try arena.alloc(u8, text.len);
        c.set_graphemebreaks_utf8(text.ptr, text.len, "", @ptrCast(brks.ptr));
        for (brks, 0..) |b, i| if (b == c.GRAPHEMEBREAK_BREAK) try graphemes.append(arena, @intCast(i + 1));
    }
    return .{ .quads = quads.items, .lines = lines.items, .graphemes = graphemes.items, .width = width, .height = y };
}

fn layoutParagraph(
    fs: *FontSystem,
    arena: Allocator,
    buf: *c.hb_buffer_t,
    text: []const u8,
    para_start: usize,
    para: []const u8,
    opts: Options,
    size26: u32,
    ascent: f32,
    advance_y: f32,
    y: *f32,
    width: *f32,
    quads: *std.ArrayList(Quad),
    lines: *std.ArrayList(Line),
) !void {
    var seq: c.SBCodepointSequence = .{ .stringEncoding = c.SBStringEncodingUTF8, .stringBuffer = @constCast(para.ptr), .stringLength = para.len };
    const algorithm = c.SBAlgorithmCreate(&seq) orelse return error.OutOfMemory;
    defer c.SBAlgorithmRelease(algorithm);
    const paragraph = c.SBAlgorithmCreateParagraph(algorithm, 0, para.len, c.SBLevelDefaultLTR) orelse return error.OutOfMemory;
    defer c.SBParagraphRelease(paragraph);
    const levels = c.SBParagraphGetLevelsPtr(paragraph);
    const base_rtl = c.SBParagraphGetBaseLevel(paragraph) & 1 == 1;

    // Itemize: maximal ranges with the same bidi level, script and font.
    const items = try itemize(fs, arena, para, levels, opts.font);

    // Measure: shape each item once, attribute advances to cluster start bytes.
    const advances = try arena.alloc(f32, para.len);
    @memset(advances, 0);
    for (items) |it| {
        const glyphs = shape(fs, buf, para, it, size26);
        for (glyphs.infos, glyphs.positions) |info, pos| advances[info.cluster] += @as(f32, @floatFromInt(pos.x_advance)) / 64;
    }

    // Break lines greedily at UAX #14 opportunities.
    const brks = try arena.alloc(u8, para.len);
    c.set_linebreaks_utf8(para.ptr, para.len, "", @ptrCast(brks.ptr));
    var line_start: usize = 0;
    var line_width: f32 = 0;
    var candidate: ?struct { pos: usize, width: f32 } = null;
    var breaks: std.ArrayList(usize) = .empty;
    for (0..para.len) |i| {
        line_width += advances[i];
        if (opts.max_width) |max| if (line_width > max) if (candidate) |cand| if (cand.pos > line_start) {
            try breaks.append(arena, cand.pos);
            line_start = cand.pos;
            line_width -= cand.width;
            candidate = null;
        };
        if (brks[i] == c.LINEBREAK_ALLOWBREAK) candidate = .{ .pos = i + 1, .width = line_width };
    }
    try breaks.append(arena, para.len);

    // Place each line: SheenBidi gives visual runs; within a run, items in visual order.
    var start: usize = 0;
    for (breaks.items) |end| {
        defer start = end;
        const line = c.SBParagraphCreateLine(paragraph, start, end - start) orelse return error.OutOfMemory;
        defer c.SBLineRelease(line);
        const runs = c.SBLineGetRunsPtr(line)[0..c.SBLineGetRunCount(line)];

        var pen: f32 = 0;
        const first_quad = quads.items.len;
        const baseline = y.* + ascent;
        for (runs) |run| {
            const rtl = run.level & 1 == 1;
            var k: usize = 0;
            while (k < items.len) : (k += 1) {
                const it = items[if (rtl) items.len - 1 - k else k];
                const s = @max(it.start, run.offset);
                const e = @min(it.end, run.offset + run.length);
                if (s >= e) continue;
                var piece = it;
                piece.start = @intCast(s);
                piece.end = @intCast(e);
                const glyphs = shape(fs, buf, para, piece, size26);
                for (glyphs.infos, glyphs.positions) |info, pos| {
                    const x = pen + @as(f32, @floatFromInt(pos.x_offset)) / 64;
                    const fx = @floor(x);
                    const bin: u8 = @intFromFloat(@floor((x - fx) * GlyphCache.subpixel_bins));
                    const id = try fs.glyphs.get(fs.font(piece.font).face, .{ .font = piece.font, .glyph = info.codepoint, .size = size26, .bin = bin });
                    const e2 = fs.glyphs.entry(id);
                    if (e2.width > 0 and e2.height > 0) try quads.append(arena, .{
                        .x = fx + @as(f32, @floatFromInt(e2.left)),
                        .y = @round(baseline - @as(f32, @floatFromInt(pos.y_offset)) / 64) - @as(f32, @floatFromInt(e2.top)),
                        .glyph = @intFromEnum(id),
                        .color = opts.color,
                    });
                    pen += @as(f32, @floatFromInt(pos.x_advance)) / 64;
                }
            }
        }
        // RTL paragraphs align to the end of the wrap width.
        if (base_rtl) if (opts.max_width) |max| for (quads.items[first_quad..]) |*q| {
            q.x += @floor(max - pen);
        };
        try lines.append(arena, .{ .start = @intCast(para_start + start), .end = @intCast(para_start + end), .baseline = baseline, .width = pen });
        width.* = @max(width.*, pen);
        y.* += advance_y;
    }
    _ = text;
}

fn itemize(fs: *FontSystem, arena: Allocator, para: []const u8, levels: [*c]const u8, primary: FontSystem.FontId) ![]Item {
    // Script runs (UAX #24) from SheenBidi.
    var seq: c.SBCodepointSequence = .{ .stringEncoding = c.SBStringEncodingUTF8, .stringBuffer = @constCast(para.ptr), .stringLength = para.len };
    const locator = c.SBScriptLocatorCreate() orelse return error.OutOfMemory;
    defer c.SBScriptLocatorRelease(locator);
    c.SBScriptLocatorLoadCodepoints(locator, &seq);
    const scripts = try arena.alloc(c.hb_script_t, para.len);
    while (c.SBScriptLocatorMoveNext(locator) != 0) {
        const agent = c.SBScriptLocatorGetAgent(locator);
        const tag = c.SBScriptGetUnicodeTag(agent.*.script);
        @memset(scripts[agent.*.offset..][0..agent.*.length], c.hb_script_from_iso15924_tag(tag));
    }

    var items: std.ArrayList(Item) = .empty;
    var it = std.unicode.Utf8Iterator{ .bytes = para, .i = 0 };
    var pos: u32 = 0;
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch 0xFFFD;
        const f = fs.fontFor(cp, primary);
        const next: u32 = pos + @as(u32, @intCast(slice.len));
        const level = levels[pos];
        const script = scripts[pos];
        if (items.items.len > 0) {
            const last = &items.items[items.items.len - 1];
            if (last.level == level and last.script == script and last.font == f) {
                last.end = next;
                pos = next;
                continue;
            }
        }
        try items.append(arena, .{ .start = pos, .end = next, .level = level, .script = script, .font = f });
        pos = next;
    }
    return items.items;
}

const Shaped = struct {
    infos: []const c.hb_glyph_info_t,
    positions: []const c.hb_glyph_position_t,
};

/// Shapes `item` with the whole paragraph as context. Results live in `buf` until reuse.
fn shape(fs: *FontSystem, buf: *c.hb_buffer_t, para: []const u8, item: Item, size26: u32) Shaped {
    const f = fs.font(item.font);
    c.hb_font_set_scale(f.hb_font, @intCast(size26), @intCast(size26));
    c.hb_buffer_clear_contents(buf);
    c.hb_buffer_add_utf8(buf, para.ptr, @intCast(para.len), item.start, @intCast(item.end - item.start));
    c.hb_buffer_set_direction(buf, if (item.level & 1 == 1) c.HB_DIRECTION_RTL else c.HB_DIRECTION_LTR);
    c.hb_buffer_set_script(buf, item.script);
    c.hb_buffer_set_language(buf, c.hb_language_get_default());
    c.hb_buffer_set_cluster_level(buf, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    c.hb_shape(f.hb_font, buf, null, 0);
    var n: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(buf, &n);
    const positions = c.hb_buffer_get_glyph_positions(buf, null);
    return .{ .infos = infos[0..n], .positions = positions[0..n] };
}

/// Byte offset of the grapheme boundary before `pos` (UAX #29), e.g. for Backspace.
pub fn prevGrapheme(arena: Allocator, text: []const u8, pos: usize) !usize {
    if (pos == 0) return 0;
    const brks = try arena.alloc(u8, pos);
    c.set_graphemebreaks_utf8(text.ptr, pos, "", @ptrCast(brks.ptr));
    // brks[i] == BREAK means a boundary after byte i; the last entry is the end itself.
    var i: usize = pos - 1;
    while (i > 0) : (i -= 1) {
        if (brks[i - 1] == c.GRAPHEMEBREAK_BREAK) return i;
    }
    return 0;
}
