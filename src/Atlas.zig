//! Per-GPU glyph atlas: an R8 image filled straight from the CPU glyph cache with
//! VK_EXT_host_image_copy (no staging buffers, no transfer commands), sampled bindlessly
//! from the descriptor heap. Always in GENERAL layout (unified image layouts).
const Atlas = @This();

const std = @import("std");
const vk_core = @import("vk_core");
const text = @import("text");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.atlas);

pub const size = 2048;
/// Empty texels around each glyph so bilinear filtering never reads a neighbour.
const pad = 1;

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

gpa: Allocator,
device: *vk_core.Device,
image: vk_core.Image,
slot: vk_core.DescriptorHeaps.ImageSlot,
rects: std.AutoHashMapUnmanaged(u32, Rect) = .empty,
pending: std.ArrayList(u32) = .empty,
shelf_x: u32 = 0,
shelf_y: u32 = 0,
shelf_h: u32 = 0,
/// Device timeline value of the last submission that may sample the atlas.
last_use: u64 = 0,
stalls: u64 = 0,

pub fn init(gpa: Allocator, device: *vk_core.Device, heaps: *vk_core.DescriptorHeaps) !Atlas {
    var image = try vk_core.Image.create(device, .{
        .format = .r8_unorm,
        .extent = .{ .width = size, .height = size },
        .usage = .{ .sampled = true, .host_transfer = true },
        .no_view = true,
    });
    errdefer image.deinit(device);
    try image.hostTransition(device, .undefined, .general);
    // Start from zero coverage everywhere (padding included).
    const zeros = try gpa.alloc(u8, size * 64);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    var y: i32 = 0;
    while (y < size) : (y += 64) try image.copyFromHost(device, &.{.{ .pixels = zeros, .x = 0, .y = y, .width = size, .height = 64 }});
    const slot = try heaps.addImage(&image);
    return .{ .gpa = gpa, .device = device, .image = image, .slot = slot };
}

/// The device must be idle.
pub fn deinit(self: *Atlas) void {
    self.rects.deinit(self.gpa);
    self.pending.deinit(self.gpa);
    self.image.deinit(self.device);
}

/// Where `glyph` lives in the atlas, scheduling an upload if it is new.
pub fn ensure(self: *Atlas, glyphs: *const text.GlyphCache, glyph: u32) !Rect {
    if (self.rects.get(glyph)) |r| return r;
    const e = glyphs.entry(@enumFromInt(glyph));
    const w: u32 = e.width + 2 * pad;
    const h: u32 = e.height + 2 * pad;
    if (self.shelf_x + w > size) {
        self.shelf_y += self.shelf_h;
        self.shelf_x = 0;
        self.shelf_h = 0;
    }
    if (self.shelf_y + h > size) return error.AtlasFull;
    const r: Rect = .{ .x = @intCast(self.shelf_x + pad), .y = @intCast(self.shelf_y + pad), .w = e.width, .h = e.height };
    self.shelf_x += w;
    self.shelf_h = @max(self.shelf_h, h);
    try self.rects.put(self.gpa, glyph, r);
    try self.pending.append(self.gpa, glyph);
    return r;
}

/// Copies pending glyphs into the image from the host. New glyphs land in texels no
/// submitted work samples, but tiled images can share memory between neighbouring texels,
/// so wait for the last frame that used the atlas first (only happens when glyphs are new).
pub fn flush(self: *Atlas, glyphs: *const text.GlyphCache) !void {
    if (self.pending.items.len == 0) return;
    // Only submitted work can be reading; the frame being recorded hasn't reached the GPU.
    const in_flight = @min(self.last_use, self.device.lastValue());
    if (try self.device.completedValue() < in_flight) {
        self.stalls += 1;
        try self.device.waitValue(in_flight);
    }
    var regions: std.ArrayList(vk_core.Image.HostRegion) = .empty;
    defer regions.deinit(self.gpa);
    for (self.pending.items) |g| {
        const r = self.rects.get(g).?;
        if (r.w == 0 or r.h == 0) continue;
        try regions.append(self.gpa, .{ .pixels = glyphs.bitmap(@enumFromInt(g)), .x = r.x, .y = r.y, .width = r.w, .height = r.h });
    }
    try self.image.copyFromHost(self.device, regions.items);
    log.debug("uploaded {d} glyphs ({d} total, {d} stalls)", .{ self.pending.items.len, self.rects.count(), self.stalls });
    self.pending.clearRetainingCapacity();
}
