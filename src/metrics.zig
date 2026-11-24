//! Per-frame and per-surface metrics in one place: collected each frame, reported
//! periodically as deltas.
const std = @import("std");
const wl = @import("wl");
const vk_present = @import("vk_present");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.metrics);

pub const Frame = struct {
    surfaces_presented: usize = 0,
    trees_committed: usize = 0,
    gpu_blocked: bool = false,

    pub fn add(f: *Frame, s: vk_present.Presenter.Stats) void {
        f.surfaces_presented += s.submitted;
        f.trees_committed += s.committed;
        f.gpu_blocked = f.gpu_blocked or s.gpu_blocked;
    }
};

pub const Totals = struct {
    loop_iterations: u64 = 0,
    frames_with_work: u64 = 0,
    surfaces_presented: u64 = 0,
    idle_waits: u64 = 0,

    pub fn add(t: *Totals, f: Frame) void {
        t.loop_iterations += 1;
        t.surfaces_presented += f.surfaces_presented;
        if (f.trees_committed > 0) t.frames_with_work += 1 else t.idle_waits += 1;
    }
};

/// Remembers previous per-surface counters so reports show deltas.
pub const SurfaceHistory = struct {
    last: std.AutoHashMapUnmanaged(*const wl.Surface, wl.PresentStats) = .empty,

    pub fn deinit(h: *SurfaceHistory, gpa: Allocator) void {
        h.last.deinit(gpa);
    }

    pub fn forget(h: *SurfaceHistory, s: *const wl.Surface) void {
        _ = h.last.remove(s);
    }

    pub fn delta(h: *SurfaceHistory, gpa: Allocator, s: *const wl.Surface) !wl.PresentStats {
        const cur = s.stats;
        const prev = h.last.get(s) orelse wl.PresentStats{};
        try h.last.put(gpa, s, cur);
        return .{
            .presented = cur.presented -| prev.presented,
            .zero_copy = cur.zero_copy -| prev.zero_copy,
            .discarded = cur.discarded -| prev.discarded,
            .last_present_ns = cur.last_present_ns,
            .refresh_ns = cur.refresh_ns,
        };
    }
};

pub fn reportTotals(t: *Totals, seconds: f64) void {
    log.info("loop: {d} iterations, {d} with work, {d} idle waits, {d} surfaces presented in {d:.1}s", .{
        t.loop_iterations, t.frames_with_work, t.idle_waits, t.surfaces_presented, seconds,
    });
    t.* = .{};
}

pub fn reportSurface(name: []const u8, d: wl.PresentStats, target: *const vk_present.SurfaceTarget) void {
    log.info("  {s:<13} presented {d:>4}  zero-copy {d:>4}  discarded {d:>3}  {s} modifier 0x{x:0>16}{s}", .{
        name,
        d.presented,
        d.zero_copy,
        d.discarded,
        &vk_present.formats.fourccName(target.drm_format),
        target.modifier,
        if (target.scanout_tranche) " scanout-tranche" else "",
    });
}
