//! Collects what the app may sleep on for one iteration — fds and the earliest deadline —
//! then waits through the Wayland display so Wayland events are never starved.
const EventLoop = @This();

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl");
const Allocator = std.mem.Allocator;

pub const Source = enum { buffer_release, decoder };

gpa: Allocator,
fds: std.ArrayList(linux.fd_t) = .empty,
sources: std.ArrayList(Source) = .empty,
/// Wake-up reasons since the last report.
wakes: std.EnumArray(enum { wayland, buffer_release, decoder, timeout, immediate }, u64) = .initFill(0),
deadline_ns: ?i128 = null,
/// Poll at most this often (ms) when something can only be checked by polling.
poll_interval_ms: ?i32 = null,

pub fn deinit(self: *EventLoop) void {
    self.fds.deinit(self.gpa);
    self.sources.deinit(self.gpa);
}

pub fn reset(self: *EventLoop) void {
    self.fds.clearRetainingCapacity();
    self.sources.clearRetainingCapacity();
    self.deadline_ns = null;
    self.poll_interval_ms = null;
}

pub fn addFd(self: *EventLoop, fd: linux.fd_t, source: Source) !void {
    try self.fds.append(self.gpa, fd);
    try self.sources.append(self.gpa, source);
}

pub fn addDeadline(self: *EventLoop, t: i128) void {
    self.deadline_ns = if (self.deadline_ns) |d| @min(d, t) else t;
}

pub fn pollEvery(self: *EventLoop, ms: i32) void {
    self.poll_interval_ms = if (self.poll_interval_ms) |p| @min(p, ms) else ms;
}

/// Sleeps until Wayland traffic, a registered fd, the deadline or the poll interval.
pub fn wait(self: *EventLoop, display: *wl.Display, now_ns: i128) !void {
    var timeout: i32 = -1;
    if (self.deadline_ns) |d| {
        const ms = @divFloor(d - now_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        timeout = @intCast(std.math.clamp(ms, 0, std.math.maxInt(i32)));
    }
    if (self.poll_interval_ms) |p| timeout = if (timeout < 0) p else @min(timeout, p);
    const r = try display.wait(self.fds.items, timeout);
    if (timeout == 0) self.wakes.getPtr(.immediate).* += 1;
    if (r.wayland) self.wakes.getPtr(.wayland).* += 1;
    if (r.timed_out) self.wakes.getPtr(.timeout).* += 1;
    for (self.sources.items, 0..) |src, i| if (i < 64 and r.ready & (@as(u64, 1) << @intCast(i)) != 0) {
        self.wakes.getPtr(switch (src) {
            .buffer_release => .buffer_release,
            .decoder => .decoder,
        }).* += 1;
    };
}

pub fn reportWakes(self: *EventLoop) void {
    const log = std.log.scoped(.metrics);
    log.info("wakes: wayland {d}, buffer release {d}, decoder {d}, timeout {d}, immediate {d}", .{
        self.wakes.get(.wayland), self.wakes.get(.buffer_release), self.wakes.get(.decoder), self.wakes.get(.timeout), self.wakes.get(.immediate),
    });
    self.wakes = .initFill(0);
}
