//! DRM syncobj timelines and sync_file bridging via raw ioctls (no libdrm, no libc).
//!
//! Typical explicit-sync client flow:
//!   - `Syncobj.create` + `exportFd` -> hand the timeline to the compositor
//!   - after a GPU submit, export its fence as a sync_file and `importSyncFile` it into a
//!     binary staging syncobj, then `transfer` it onto a timeline point
//!   - `query`/`registerEventfd` to learn when the compositor signals a release point
const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.drm);

pub const Error = error{DrmIoctlFailed};

/// A DRM device node (typically /dev/dri/renderD*), owning its file descriptor.
pub const Node = struct {
    fd: linux.fd_t,

    pub fn openRender(minor: i64) !Node {
        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "/dev/dri/renderD{d}", .{minor}, 0);
        const rc = linux.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) {
            log.err("open {s}: {t}", .{ path, linux.errno(rc) });
            return error.OpenRenderNode;
        }
        return .{ .fd = @intCast(rc) };
    }

    pub fn close(n: Node) void {
        _ = linux.close(n.fd);
    }

    pub fn getCap(n: Node, cap: u64) Error!u64 {
        var arg: GetCap = .{ .capability = cap, .value = 0 };
        try n.ioctl(ioctl_get_cap, &arg, "GET_CAP");
        return arg.value;
    }

    pub fn supportsTimelines(n: Node) bool {
        return (n.getCap(cap_syncobj_timeline) catch 0) != 0;
    }

    fn ioctl(n: Node, request: u32, arg: anytype, comptime name: []const u8) Error!void {
        while (true) {
            const rc = linux.ioctl(n.fd, request, @intFromPtr(arg));
            switch (linux.errno(rc)) {
                .SUCCESS => return,
                .INTR, .AGAIN => continue,
                else => |e| {
                    log.debug("DRM_IOCTL_{s}: {t}", .{ name, e });
                    return error.DrmIoctlFailed;
                },
            }
        }
    }

    /// Like `ioctl` but reports the errno instead of logging it (for expected failures).
    fn ioctlErrno(n: Node, request: u32, arg: anytype) linux.E {
        while (true) {
            const rc = linux.ioctl(n.fd, request, @intFromPtr(arg));
            const e = linux.errno(rc);
            if (e != .INTR and e != .AGAIN) return e;
        }
    }
};

/// A syncobj handle on a DRM node. Binary or timeline depending on how it is used.
pub const Syncobj = struct {
    node: Node,
    handle: u32,

    pub fn create(node: Node) Error!Syncobj {
        var arg: Create = .{ .handle = 0, .flags = 0 };
        try node.ioctl(ioctl_create, &arg, "SYNCOBJ_CREATE");
        return .{ .node = node, .handle = arg.handle };
    }

    pub fn destroy(s: Syncobj) void {
        var arg: Destroy = .{ .handle = s.handle, .pad = 0 };
        s.node.ioctl(ioctl_destroy, &arg, "SYNCOBJ_DESTROY") catch {};
    }

    /// Exports the syncobj itself as an fd (e.g. for wp_linux_drm_syncobj_manager_v1.import_timeline).
    /// Caller owns the fd.
    pub fn exportFd(s: Syncobj) Error!linux.fd_t {
        var arg: Handle = .{ .handle = s.handle, .flags = 0, .fd = -1, .pad = 0, .point = 0 };
        try s.node.ioctl(ioctl_handle_to_fd, &arg, "SYNCOBJ_HANDLE_TO_FD");
        return arg.fd;
    }

    /// Replaces this (binary) syncobj's fence with the one in `sync_file`.
    pub fn importSyncFile(s: Syncobj, sync_file: linux.fd_t) Error!void {
        var arg: Handle = .{ .handle = s.handle, .flags = fd_to_handle_import_sync_file, .fd = sync_file, .pad = 0, .point = 0 };
        try s.node.ioctl(ioctl_fd_to_handle, &arg, "SYNCOBJ_FD_TO_HANDLE");
    }

    /// Copies `src`'s fence at `src_point` (0 = binary) onto this syncobj at `point`.
    pub fn transfer(dst: Syncobj, point: u64, src: Syncobj, src_point: u64) Error!void {
        var arg: Transfer = .{ .src_handle = src.handle, .dst_handle = dst.handle, .src_point = src_point, .dst_point = point, .flags = 0, .pad = 0 };
        try dst.node.ioctl(ioctl_transfer, &arg, "SYNCOBJ_TRANSFER");
    }

    /// Signals a binary syncobj immediately.
    pub fn signal(s: Syncobj) Error!void {
        var h = s.handle;
        var arg: Array = .{ .handles = @intFromPtr(&h), .count_handles = 1, .pad = 0 };
        try s.node.ioctl(ioctl_signal, &arg, "SYNCOBJ_SIGNAL");
    }

    /// Signals a timeline point immediately.
    pub fn signalPoint(s: Syncobj, point: u64) Error!void {
        var h = s.handle;
        var p = point;
        var arg: TimelineArray = .{ .handles = @intFromPtr(&h), .points = @intFromPtr(&p), .count_handles = 1, .flags = 0 };
        try s.node.ioctl(ioctl_timeline_signal, &arg, "SYNCOBJ_TIMELINE_SIGNAL");
    }

    /// Non-blocking: has `point` been signaled? (False also if no fence was submitted yet.)
    pub fn isSignaled(s: Syncobj, point: u64) bool {
        var h = s.handle;
        var p = point;
        var arg: TimelineWait = .{
            .handles = @intFromPtr(&h),
            .points = @intFromPtr(&p),
            .timeout_nsec = 0,
            .count_handles = 1,
            .flags = 0,
            .first_signaled = 0,
            .pad = 0,
            .deadline_nsec = 0,
        };
        return s.node.ioctlErrno(ioctl_timeline_wait, &arg) == .SUCCESS;
    }

    /// Asks the kernel to signal `eventfd` once `point` is signaled (Linux 6.6+).
    pub fn registerEventfd(s: Syncobj, point: u64, eventfd: linux.fd_t) Error!void {
        var arg: Eventfd = .{ .handle = s.handle, .flags = 0, .point = point, .fd = eventfd, .pad = 0 };
        try s.node.ioctl(ioctl_eventfd, &arg, "SYNCOBJ_EVENTFD");
    }
};

/// Non-blocking, close-on-exec eventfd for `Syncobj.registerEventfd`.
pub const EventFd = struct {
    fd: linux.fd_t,

    pub fn create() !EventFd {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventfdFailed;
        return .{ .fd = @intCast(rc) };
    }

    pub fn close(e: EventFd) void {
        _ = linux.close(e.fd);
    }

    /// Clears the counter after the fd polled readable.
    pub fn drain(e: EventFd) void {
        var v: u64 = 0;
        _ = linux.read(e.fd, std.mem.asBytes(&v).ptr, @sizeOf(u64));
    }
};

pub fn closeFd(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

// Kernel UAPI (include/uapi/drm/drm.h).

const cap_syncobj_timeline = 0x14;
const fd_to_handle_import_sync_file = 1 << 0;

const GetCap = extern struct { capability: u64, value: u64 };
const Create = extern struct { handle: u32, flags: u32 };
const Destroy = extern struct { handle: u32, pad: u32 };
const Handle = extern struct { handle: u32, flags: u32, fd: i32, pad: u32, point: u64 };
const Transfer = extern struct { src_handle: u32, dst_handle: u32, src_point: u64, dst_point: u64, flags: u32, pad: u32 };
const TimelineWait = extern struct {
    handles: u64,
    points: u64,
    timeout_nsec: i64,
    count_handles: u32,
    flags: u32,
    first_signaled: u32,
    pad: u32,
    deadline_nsec: u64,
};
const Array = extern struct { handles: u64, count_handles: u32, pad: u32 };
const TimelineArray = extern struct { handles: u64, points: u64, count_handles: u32, flags: u32 };
const Eventfd = extern struct { handle: u32, flags: u32, point: u64, fd: i32, pad: u32 };

const IOWR = linux.IOCTL.IOWR;
const ioctl_get_cap = IOWR('d', 0x0c, GetCap);
const ioctl_create = IOWR('d', 0xBF, Create);
const ioctl_destroy = IOWR('d', 0xC0, Destroy);
const ioctl_handle_to_fd = IOWR('d', 0xC1, Handle);
const ioctl_fd_to_handle = IOWR('d', 0xC2, Handle);
const ioctl_signal = IOWR('d', 0xC5, Array);
const ioctl_timeline_wait = IOWR('d', 0xCA, TimelineWait);
const ioctl_transfer = IOWR('d', 0xCC, Transfer);
const ioctl_timeline_signal = IOWR('d', 0xCD, TimelineArray);
const ioctl_eventfd = IOWR('d', 0xCF, Eventfd);

test "uapi struct sizes" {
    try std.testing.expectEqual(16, @sizeOf(GetCap));
    try std.testing.expectEqual(24, @sizeOf(Handle));
    try std.testing.expectEqual(32, @sizeOf(Transfer));
    try std.testing.expectEqual(48, @sizeOf(TimelineWait));
    try std.testing.expectEqual(24, @sizeOf(Eventfd));
}
