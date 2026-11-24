//! Deferred destruction keyed on the device timeline, with an optional external condition
//! (e.g. "the compositor released this buffer"). Replaces ad-hoc retire lists and
//! `vkDeviceWaitIdle` before destroying things.
const DeletionQueue = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    /// Destroy once the device timeline has reached this value.
    after_value: u64,
    ctx: *anyopaque,
    /// Extra condition, polled without blocking. Null = only the timeline matters.
    ready: ?*const fn (ctx: *anyopaque) bool = null,
    destroy: *const fn (ctx: *anyopaque) void,
};

entries: std.ArrayList(Entry) = .empty,

pub fn deinit(q: *DeletionQueue, gpa: Allocator) void {
    std.debug.assert(q.entries.items.len == 0); // call flush() first
    q.entries.deinit(gpa);
}

pub fn push(q: *DeletionQueue, gpa: Allocator, entry: Entry) !void {
    try q.entries.append(gpa, entry);
}

/// Destroys every entry whose conditions are met. Returns how many remain.
pub fn collect(q: *DeletionQueue, completed_value: u64) usize {
    var i: usize = 0;
    while (i < q.entries.items.len) {
        const e = q.entries.items[i];
        if (completed_value >= e.after_value and (if (e.ready) |r| r(e.ctx) else true)) {
            _ = q.entries.swapRemove(i);
            e.destroy(e.ctx);
        } else i += 1;
    }
    return q.entries.items.len;
}

/// Destroys everything unconditionally (device must be idle).
pub fn flush(q: *DeletionQueue) void {
    for (q.entries.items) |e| e.destroy(e.ctx);
    q.entries.clearRetainingCapacity();
}
