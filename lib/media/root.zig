//! Media: FFmpeg demux + Vulkan Video decode on our own VkDevice (zero copy: decoded
//! frames are VkImages the renderer samples directly, ordered by FFmpeg's timeline
//! semaphores).
pub const c = @import("av_c");
pub const HwDevice = @import("HwDevice.zig");
pub const Decoder = @import("Decoder.zig");
pub const Frame = @import("Frame.zig");
