//! Everything the app keeps per GPU: the device, its presenter and renderer, and a
//! per-frame scratch arena owned by that GPU's render task.
const Gpu = @This();

const std = @import("std");
const vk_core = @import("vk_core");
const vk_present = @import("vk_present");
const text = @import("text");
const Renderer = @import("Renderer.zig");
const Allocator = std.mem.Allocator;

gpa: Allocator,
device: *vk_core.Device,
presenter: *vk_present.Presenter,
renderer: *Renderer,
/// Reset at the start of each frame; only touched by this GPU's task.
arena: std.heap.ArenaAllocator,

pub fn create(gpa: Allocator, instance: *vk_core.Instance, candidate: vk_core.Instance.Candidate, glyphs: *const text.GlyphCache, video_decode: bool) !*Gpu {
    const device = try vk_core.Device.create(gpa, instance, candidate, .{ .extensions = &vk_present.device_extensions, .video_decode = video_decode, .optical_flow = video_decode });
    errdefer device.destroy();
    const presenter = try vk_present.Presenter.create(gpa, device, vk_present.drmInfo(instance, candidate.pdev));
    errdefer presenter.destroy();
    const renderer = try Renderer.create(gpa, device, glyphs);
    errdefer renderer.destroy();

    const self = try gpa.create(Gpu);
    self.* = .{ .gpa = gpa, .device = device, .presenter = presenter, .renderer = renderer, .arena = .init(gpa) };
    return self;
}

/// All surface targets on this GPU must be destroyed first.
pub fn destroy(self: *Gpu) void {
    self.device.waitIdle();
    self.renderer.destroy();
    self.presenter.destroy();
    self.device.destroy();
    self.arena.deinit();
    self.gpa.destroy(self);
}

pub fn name(self: *const Gpu) []const u8 {
    return self.device.name();
}

pub fn renderFrame(self: *Gpu, trees: []const vk_present.Presenter.TreeWork, stats: *vk_present.Presenter.Stats) !void {
    _ = self.arena.reset(.retain_capacity);
    try self.presenter.renderFrame(self.arena.allocator(), trees, self.renderer.recorder(), stats);
}
