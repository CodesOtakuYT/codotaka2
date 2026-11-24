//! A decoded frame: an owned AVFrame whose data is an AVVkFrame (a VkImage on our device
//! plus the timeline semaphore that orders every access to it).
const Frame = @This();

const std = @import("std");
const vk = @import("vulkan");
const c = @import("av_c");

av: *c.AVFrame,
/// Presentation timestamp (stream time, ns; keeps increasing across loops).
pts_ns: i64,
duration_ns: i64,

pub fn release(self: *Frame) void {
    var f: ?*c.AVFrame = self.av;
    c.av_frame_free(&f);
}

pub fn vkFrame(self: *const Frame) *c.AVVkFrame {
    return @ptrCast(@alignCast(self.av.data[0]));
}

pub fn framesContext(self: *const Frame) *c.AVHWFramesContext {
    return @ptrCast(@alignCast(self.av.hw_frames_ctx.*.data));
}

fn vulkanFrames(self: *const Frame) *c.AVVulkanFramesContext {
    return @ptrCast(@alignCast(self.framesContext().hwctx));
}

/// Identifies the frame pool (changes when the decoder reinitializes, e.g. on resize).
pub fn poolId(self: *const Frame) usize {
    return @intFromPtr(self.av.hw_frames_ctx.*.data);
}

pub fn image(self: *const Frame) vk.Image {
    return @enumFromInt(@intFromPtr(self.vkFrame().img[0]));
}

pub fn format(self: *const Frame) vk.Format {
    return @enumFromInt(self.vulkanFrames().format[0]);
}

/// Visible size.
pub fn width(self: *const Frame) u32 {
    return @intCast(self.av.width);
}
pub fn height(self: *const Frame) u32 {
    return @intCast(self.av.height);
}
/// Allocated (coded) size of the pool images; >= visible size.
pub fn codedWidth(self: *const Frame) u32 {
    return @intCast(self.framesContext().width);
}
pub fn codedHeight(self: *const Frame) u32 {
    return @intCast(self.framesContext().height);
}

/// FFmpeg's frame lock: hold it while reading/updating layout, access and semaphore values,
/// from recording until the submit that uses them is queued.
pub fn lock(self: *const Frame) void {
    const fc = self.framesContext();
    self.vulkanFrames().lock_frame.?(fc, self.vkFrame());
}
pub fn unlock(self: *const Frame) void {
    const fc = self.framesContext();
    self.vulkanFrames().unlock_frame.?(fc, self.vkFrame());
}

pub const Matrix = enum(u32) { bt601 = 0, bt709 = 1, bt2020 = 2 };
pub const Transfer = enum(u32) { sdr = 0, pq = 1, hlg = 2 };
pub const Primaries = enum(u32) { bt709 = 0, bt2020 = 1 };

pub const Colorimetry = struct {
    matrix: Matrix,
    transfer: Transfer,
    primaries: Primaries,
    full_range: bool,
    bit_depth: u32,
};

/// How to interpret the samples, with sensible defaults for unspecified streams.
pub fn colorimetry(self: *const Frame) Colorimetry {
    const av = self.av;
    const hd = self.height() > 576;
    const matrix: Matrix = switch (av.colorspace) {
        c.AVCOL_SPC_BT709 => .bt709,
        c.AVCOL_SPC_BT2020_NCL, c.AVCOL_SPC_BT2020_CL => .bt2020,
        c.AVCOL_SPC_BT470BG, c.AVCOL_SPC_SMPTE170M => .bt601,
        else => if (hd) .bt709 else .bt601,
    };
    const transfer: Transfer = switch (av.color_trc) {
        c.AVCOL_TRC_SMPTE2084 => .pq,
        c.AVCOL_TRC_ARIB_STD_B67 => .hlg,
        else => .sdr,
    };
    const primaries: Primaries = switch (av.color_primaries) {
        c.AVCOL_PRI_BT2020 => .bt2020,
        else => .bt709,
    };
    const desc = c.av_pix_fmt_desc_get(self.framesContext().sw_format);
    return .{
        .matrix = matrix,
        .transfer = transfer,
        .primaries = primaries,
        .full_range = av.color_range == c.AVCOL_RANGE_JPEG,
        .bit_depth = if (desc) |d| @intCast(d.*.comp[0].depth) else 8,
    };
}

/// Single-plane view formats for the luma and chroma planes of a 2-plane 4:2:0 format.
pub fn planeFormats(fmt: vk.Format) ?[2]vk.Format {
    return switch (fmt) {
        .g8_b8r8_2plane_420_unorm => .{ .r8_unorm, .r8g8_unorm },
        .g10x6_b10x6r10x6_2plane_420_unorm_3pack16 => .{ .r10x6_unorm_pack16, .r10x6g10x6_unorm_2pack16 },
        .g12x4_b12x4r12x4_2plane_420_unorm_3pack16 => .{ .r12x4_unorm_pack16, .r12x4g12x4_unorm_2pack16 },
        .g16_b16r16_2plane_420_unorm => .{ .r16_unorm, .r16g16_unorm },
        else => null,
    };
}
