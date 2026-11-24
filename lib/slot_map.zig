//! Generational slot map: stable handles that detect use-after-remove.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Id = struct {
            index: u32,
            generation: u32,

            pub fn eql(a: Id, b: Id) bool {
                return a.index == b.index and a.generation == b.generation;
            }
        };

        const Slot = struct {
            generation: u32 = 0,
            value: ?T = null,
        };

        slots: std.ArrayList(Slot) = .empty,
        free: std.ArrayList(u32) = .empty,
        len: usize = 0,

        pub const empty: Self = .{};

        pub fn deinit(m: *Self, gpa: Allocator) void {
            m.slots.deinit(gpa);
            m.free.deinit(gpa);
        }

        pub fn insert(m: *Self, gpa: Allocator, value: T) !Id {
            try m.free.ensureUnusedCapacity(gpa, 1); // so remove() can't fail
            if (m.free.pop()) |index| {
                const slot = &m.slots.items[index];
                slot.value = value;
                m.len += 1;
                return .{ .index = index, .generation = slot.generation };
            }
            try m.slots.append(gpa, .{ .value = value });
            m.len += 1;
            return .{ .index = @intCast(m.slots.items.len - 1), .generation = 0 };
        }

        pub fn get(m: *Self, id: Id) ?*T {
            if (id.index >= m.slots.items.len) return null;
            const slot = &m.slots.items[id.index];
            if (slot.generation != id.generation) return null;
            return if (slot.value) |*v| v else null;
        }

        pub fn contains(m: *Self, id: Id) bool {
            return m.get(id) != null;
        }

        pub fn remove(m: *Self, id: Id) ?T {
            const v = m.get(id) orelse return null;
            const value = v.*;
            const slot = &m.slots.items[id.index];
            slot.value = null;
            slot.generation +%= 1;
            m.free.appendAssumeCapacity(id.index);
            m.len -= 1;
            return value;
        }

        pub const Iterator = struct {
            map: *Self,
            index: u32 = 0,

            pub const Entry = struct { id: Id, value: *T };

            pub fn next(it: *Iterator) ?Entry {
                while (it.index < it.map.slots.items.len) {
                    const i = it.index;
                    it.index += 1;
                    const slot = &it.map.slots.items[i];
                    if (slot.value) |*v| return .{ .id = .{ .index = i, .generation = slot.generation }, .value = v };
                }
                return null;
            }
        };

        /// Iterates in slot order. Removing the current entry while iterating is allowed.
        pub fn iterator(m: *Self) Iterator {
            return .{ .map = m };
        }
    };
}

test "stale ids are rejected" {
    const gpa = std.testing.allocator;
    var m: SlotMap(u32) = .empty;
    defer m.deinit(gpa);
    const a = try m.insert(gpa, 1);
    try std.testing.expectEqual(@as(u32, 1), m.get(a).?.*);
    _ = m.remove(a);
    const b = try m.insert(gpa, 2);
    try std.testing.expectEqual(a.index, b.index);
    try std.testing.expect(m.get(a) == null);
    try std.testing.expectEqual(@as(u32, 2), m.get(b).?.*);
}
