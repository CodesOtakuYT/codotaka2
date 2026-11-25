const vk_core = @import("vk_core");

/// Validation messages from FFmpeg 9.1's Vulkan Video decode on this driver: reproducible
/// with the plain `ffmpeg -hwaccel vulkan` CLI, so not caused by our interop.
pub var list = [_]vk_core.Instance.KnownIssue{
    .{ .vuid = "VUID-VkImageCreateInfo-pNext-06811", .reason = "FFmpeg Vulkan decode image flags" },
    .{ .vuid = "VUID-VkVideoBeginCodingInfoKHR-flags-07244", .reason = "FFmpeg Vulkan decode reference slots" },
    .{ .vuid = "VUID-VkVideoBeginCodingInfoKHR-pPictureResource-07240", .reason = "FFmpeg Vulkan decode reference slots" },
    .{ .vuid = "VUID-vkCmdDecodeVideoKHR-pDecodeInfo-07142", .reason = "FFmpeg Vulkan decode reference slots" },
};
