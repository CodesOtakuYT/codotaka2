//! codotaka-eval: offline frame-interpolation quality tool (see eval.zig).
const std = @import("std");
const builtin = @import("builtin");
const wl = @import("wl");
const vk_core = @import("vk_core");
const vk_present = @import("vk_present");
const eval = @import("eval.zig");

// vulkan-zig's platform structs use the real libwayland types (as in main.zig).
pub const wl_display = wl.c.wl_display;
pub const wl_surface = wl.c.wl_surface;

pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{
        .{ .scope = .present, .level = .warn },
        .{ .scope = .vk, .level = .warn },
        .{ .scope = .media, .level = .warn },
        .{ .scope = .text, .level = .warn },
        .{ .scope = .drm, .level = .warn },
    },
};

const known_issues = &@import("known_issues.zig").list;

const usage =
    \\Usage: codotaka-eval <video> [options]
    \\Drops frames from a high-frame-rate video, interpolates them back with codotaka's
    \\renderer and scores the result against the real frames (PSNR), next to
    \\repeat-nearest and crossfade baselines.
    \\  --step N        keep every Nth frame (default 6: 60 -> 10 fps)
    \\  --intervals N   number of kept-frame intervals to evaluate (default 40)
    \\  --start S       start at S seconds
    \\  --width W       evaluation width in pixels (default 1920)
    \\  --csv FILE      per-frame scores as CSV
    \\  --worst DIR     write heat maps of the worst interpolated frames into DIR
    \\  --worst-count N how many worst frames to keep (default 8)
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        std.debug.print(usage, .{});
        return;
    }
    var opts: eval.Options = .{ .path = args[1] };
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const k = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, k, "--step")) {
            opts.step = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, k, "--intervals")) {
            opts.intervals = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, k, "--start")) {
            opts.start_s = try std.fmt.parseFloat(f64, v);
        } else if (std.mem.eql(u8, k, "--width")) {
            opts.width = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, k, "--csv")) {
            opts.csv = v;
        } else if (std.mem.eql(u8, k, "--worst")) {
            opts.worst_dir = v;
        } else if (std.mem.eql(u8, k, "--worst-count")) {
            opts.worst_count = try std.fmt.parseInt(u32, v, 10);
        } else {
            std.debug.print("unknown option {s}\n{s}", .{ k, usage });
            return error.InvalidArguments;
        }
    }
    if (i < args.len) {
        std.debug.print("option {s} needs a value\n", .{args[i]});
        return error.InvalidArguments;
    }
    const gpa = init.gpa;
    const instance = try vk_core.Instance.create(gpa, .{ .app_name = "codotaka-eval", .validation = builtin.mode == .debug, .known_issues = known_issues });
    defer instance.destroy();
    const candidates = try instance.findCandidates(gpa, &vk_present.device_extensions, {}, vk_present.acceptDevice);
    defer gpa.free(candidates);
    if (candidates.len == 0) return error.NoVulkanDevice;
    try eval.run(gpa, init.io, instance, candidates[0], opts);
    vk_core.Instance.reportKnownIssues(known_issues);
}
