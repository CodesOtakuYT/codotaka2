//! The single table of presentable formats: Vulkan format, equivalent DRM fourccs (in
//! preference order), and how color values are encoded.
const std = @import("std");
const vk = @import("vulkan");
const wl = @import("wl");
const fourcc = @import("dmabuf_feedback").fourcc;

pub const Format = struct {
    color: wl.ColorMode,
    vk: vk.Format,
    drm: []const u32,
    /// Output value of reference white.
    white_scale: f32,

    pub fn name(f: *const Format) []const u8 {
        return @tagName(f.vk);
    }
};

pub const table = [_]Format{
    // 8-bit, sRGB-encoded on store; byte order B, G, R, X/A.
    .{ .color = .sdr, .vk = .b8g8r8a8_srgb, .drm = &.{ fourcc("XR24"), fourcc("AR24") }, .white_scale = 1.0 },
    // FP16 linear scRGB; 1.0 = 80 cd/m², reference white at 203 cd/m² (BT.2408).
    .{ .color = .hdr_scrgb, .vk = .r16g16b16a16_sfloat, .drm = &.{ fourcc("XB4H"), fourcc("AB4H") }, .white_scale = 203.0 / 80.0 },
};

pub fn forMode(mode: wl.ColorMode) *const Format {
    for (&table) |*f| if (f.color == mode) return f;
    unreachable;
}

pub fn fourccName(code: u32) [4]u8 {
    return @bitCast(code);
}

comptime {
    for (std.enums.values(wl.ColorMode)) |m| _ = forMode(m);
}
