//! linux-dmabuf-v1 feedback (v4+) parsing and format/modifier negotiation.
//! Independent of libwayland: feed it the event payloads, get preference tranches out.
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.dmabuf);

/// One entry of the format table.
pub const FormatModifier = extern struct {
    format: u32,
    _pad: u32,
    modifier: u64,
};

pub const Tranche = struct {
    target_device: DevT,
    flags: u32,
    formats: std.ArrayList(FormatModifier),

    pub const flag_scanout = 1;
    pub const flag_sampling = 2; // v6

    pub fn scanout(t: Tranche) bool {
        return t.flags & flag_scanout != 0;
    }

    pub fn sampling(t: Tranche) bool {
        return t.flags & flag_sampling != 0;
    }
};

/// A Linux dev_t. Two dev_t values from different sources must be compared by
/// major/minor, never directly (the protocol says so explicitly).
pub const DevT = struct {
    raw: u64,

    pub fn major(d: DevT) u64 {
        return ((d.raw >> 8) & 0xfff) | ((d.raw >> 32) & ~@as(u64, 0xfff));
    }

    pub fn minor(d: DevT) u64 {
        return (d.raw & 0xff) | ((d.raw >> 12) & ~@as(u64, 0xff));
    }

    pub fn is(d: DevT, maj: i64, min: i64) bool {
        return maj >= 0 and min >= 0 and d.major() == @as(u64, @intCast(maj)) and d.minor() == @as(u64, @intCast(min));
    }
};

/// Accumulates feedback events; `tranches` holds the last complete set.
pub const Feedback = struct {
    gpa: Allocator,
    tranches: std.ArrayList(Tranche) = .empty,
    /// A new complete set of tranches arrived since this was last cleared.
    changed: bool = false,
    received: bool = false,

    table: ?[]align(std.heap.page_size_min) const u8 = null,
    pending: std.ArrayList(Tranche) = .empty,
    current: ?Tranche = null,

    pub fn init(gpa: Allocator) Feedback {
        return .{ .gpa = gpa };
    }

    pub fn deinit(f: *Feedback) void {
        freeAll(f.gpa, &f.tranches);
        f.tranches.deinit(f.gpa);
        freeAll(f.gpa, &f.pending);
        f.pending.deinit(f.gpa);
        if (f.current) |*t| t.formats.deinit(f.gpa);
        f.unmapTable();
    }

    fn freeAll(gpa: Allocator, list: *std.ArrayList(Tranche)) void {
        for (list.items) |*t| t.formats.deinit(gpa);
        list.clearRetainingCapacity();
    }

    fn unmapTable(f: *Feedback) void {
        if (f.table) |t| _ = linux.munmap(t.ptr, t.len);
        f.table = null;
    }

    fn cur(f: *Feedback) *Tranche {
        if (f.current == null) f.current = .{ .target_device = .{ .raw = 0 }, .flags = 0, .formats = .empty };
        return &f.current.?;
    }

    /// `format_table` event. Takes ownership of `fd`.
    pub fn onFormatTable(f: *Feedback, fd: linux.fd_t, size: u32) void {
        defer _ = linux.close(fd);
        f.unmapTable();
        const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (linux.errno(rc) != .SUCCESS) {
            log.err("mmap format table: {t}", .{linux.errno(rc)});
            return;
        }
        f.table = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(rc))[0..size];
    }

    /// `tranche_target_device` event payload (a dev_t in a wl_array).
    pub fn onTrancheTargetDevice(f: *Feedback, bytes: []const u8) void {
        if (bytes.len != @sizeOf(u64)) return;
        f.cur().target_device = .{ .raw = std.mem.readInt(u64, bytes[0..8], .little) };
    }

    /// `tranche_formats` event payload (u16 indices into the format table).
    pub fn onTrancheFormats(f: *Feedback, bytes: []const u8) void {
        const table = f.table orelse return;
        const entries = std.mem.bytesAsSlice(FormatModifier, table[0 .. table.len / @sizeOf(FormatModifier) * @sizeOf(FormatModifier)]);
        const t = f.cur();
        var i: usize = 0;
        while (i + 2 <= bytes.len) : (i += 2) {
            const index = std.mem.readInt(u16, bytes[i..][0..2], .little);
            if (index >= entries.len) continue;
            t.formats.append(f.gpa, entries[index]) catch return;
        }
    }

    pub fn onTrancheFlags(f: *Feedback, flags: u32) void {
        f.cur().flags = flags;
    }

    pub fn onTrancheDone(f: *Feedback) void {
        if (f.current) |t| {
            f.pending.append(f.gpa, t) catch {
                var tt = t;
                tt.formats.deinit(f.gpa);
            };
        }
        f.current = null;
    }

    pub fn onDone(f: *Feedback) void {
        freeAll(f.gpa, &f.tranches);
        std.mem.swap(std.ArrayList(Tranche), &f.tranches, &f.pending);
        f.changed = true;
        f.received = true;
    }
};

pub const Choice = struct {
    tranche: *const Tranche,
    format: u32,
    /// Owned by the caller.
    modifiers: []u64,
};

/// Walks the tranches in compositor preference order and returns the first one targeting
/// the device identified by `is_device`, with the first of `formats` (in caller preference
/// order) that has at least one modifier accepted by `supported`.
pub fn choose(
    gpa: Allocator,
    tranches: []const Tranche,
    formats: []const u32,
    ctx: anytype,
    comptime is_device: fn (@TypeOf(ctx), DevT) bool,
    comptime supported: fn (@TypeOf(ctx), u64) bool,
) !?Choice {
    for (tranches) |*t| {
        if (!is_device(ctx, t.target_device)) continue;
        for (formats) |fmt| {
            var mods: std.ArrayList(u64) = .empty;
            errdefer mods.deinit(gpa);
            for (t.formats.items) |fm| {
                if (fm.format != fmt or !supported(ctx, fm.modifier)) continue;
                if (std.mem.indexOfScalar(u64, mods.items, fm.modifier) != null) continue;
                try mods.append(gpa, fm.modifier);
            }
            if (mods.items.len > 0) return .{ .tranche = t, .format = fmt, .modifiers = try mods.toOwnedSlice(gpa) };
            mods.deinit(gpa);
        }
    }
    return null;
}

pub fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

test "dev_t major/minor" {
    // makedev(226, 128) with glibc encoding
    const d: DevT = .{ .raw = (226 << 8) | 128 };
    try std.testing.expect(d.is(226, 128));
    try std.testing.expect(!d.is(226, 1));
}

test "fourcc" {
    try std.testing.expectEqual(@as(u32, 0x34325258), fourcc("XR24"));
}
