//! The single table of presentable formats: Vulkan format, equivalent DRM fourccs (in
//! preference order), and how color values are encoded.
const std = @import("std");
const vk = @import("vulkan");
const wl = @import("wl");
const fourcc = @import("dmabuf_feedback").fourcc;

/// How shaders must encode output for a format (see ShaderCache output variants).
pub const Encode = enum(u32) {
    /// The format stores what shaders write (sRGB formats encode in hardware; FP16 is linear).
    none = 0,
    /// UNORM storage for translucent SDR: encode to gamma 2.2 and premultiply in encoded
    /// ("electrical") space, which is what compositors blend with.
    gamma22_premultiplied = 1,
};

pub const Format = struct {
    color: wl.ColorMode,
    /// Has meaningful alpha (translucent surfaces).
    alpha: bool,
    vk: vk.Format,
    drm: []const u32,
    /// Output value of reference white.
    white_scale: f32,
    encode: Encode = .none,

    pub fn name(f: *const Format) []const u8 {
        return @tagName(f.vk);
    }
};

pub const table = [_]Format{
    // Opaque 8-bit, sRGB-encoded on store; byte order B, G, R, X.
    .{ .color = .sdr, .alpha = false, .vk = .b8g8r8a8_srgb, .drm = &.{ fourcc("XR24"), fourcc("AR24") }, .white_scale = 1.0 },
    // Opaque FP16 linear scRGB; 1.0 = 80 cd/m², reference white at 203 cd/m² (BT.2408).
    .{ .color = .hdr_scrgb, .alpha = false, .vk = .r16g16b16a16_sfloat, .drm = &.{ fourcc("XB4H"), fourcc("AB4H") }, .white_scale = 203.0 / 80.0 },
    // Translucent 8-bit: premultiplied alpha in encoded space (encoded by the shader).
    .{ .color = .sdr, .alpha = true, .vk = .b8g8r8a8_unorm, .drm = &.{fourcc("AR24")}, .white_scale = 1.0, .encode = .gamma22_premultiplied },
    // Translucent FP16: linear transfer, so premultiplied linear is already "electrical".
    .{ .color = .hdr_scrgb, .alpha = true, .vk = .r16g16b16a16_sfloat, .drm = &.{fourcc("AB4H")}, .white_scale = 203.0 / 80.0 },
};

pub fn forMode(mode: wl.ColorMode, alpha: bool) *const Format {
    for (&table) |*f| if (f.color == mode and f.alpha == alpha) return f;
    unreachable;
}

pub fn fourccName(code: u32) [4]u8 {
    return @bitCast(code);
}

comptime {
    for (std.enums.values(wl.ColorMode)) |m| {
        _ = forMode(m, false);
        _ = forMode(m, true);
    }
}
