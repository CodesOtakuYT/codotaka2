//! Collects what the app may sleep on for one iteration — fds and the earliest deadline —
//! then waits through the Wayland display so Wayland events are never starved.
const EventLoop = @This();

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl");
const Allocator = std.mem.Allocator;

gpa: Allocator,
fds: std.ArrayList(linux.fd_t) = .empty,
deadline_ns: ?i128 = null,
/// Poll at most this often (ms) when something can only be checked by polling.
poll_interval_ms: ?i32 = null,

pub fn deinit(self: *EventLoop) void {
    self.fds.deinit(self.gpa);
}

pub fn reset(self: *EventLoop) void {
    self.fds.clearRetainingCapacity();
    self.deadline_ns = null;
    self.poll_interval_ms = null;
}

pub fn addFd(self: *EventLoop, fd: linux.fd_t) !void {
    try self.fds.append(self.gpa, fd);
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
    try display.wait(self.fds.items, timeout);
}
