//! Rectangles tagged with their coordinate space, so logical and buffer pixels can't be
//! mixed up, plus the fractional scale that converts between them.
const std = @import("std");

pub const Space = enum { logical, buffer };

pub fn Rect(comptime space: Space) type {
    return struct {
        const Self = @This();
        pub const coordinate_space = space;

        x: i32 = 0,
        y: i32 = 0,
        width: u32 = 0,
        height: u32 = 0,

        pub fn right(r: Self) i64 {
            return @as(i64, r.x) + r.width;
        }

        pub fn bottom(r: Self) i64 {
            return @as(i64, r.y) + r.height;
        }

        pub fn isEmpty(r: Self) bool {
            return r.width == 0 or r.height == 0;
        }

        pub fn translate(r: Self, dx: i32, dy: i32) Self {
            return .{ .x = r.x + dx, .y = r.y + dy, .width = r.width, .height = r.height };
        }

        pub fn intersect(a: Self, b: Self) ?Self {
            const x0 = @max(@as(i64, a.x), b.x);
            const y0 = @max(@as(i64, a.y), b.y);
            const x1 = @min(a.right(), b.right());
            const y1 = @min(a.bottom(), b.bottom());
            if (x1 <= x0 or y1 <= y0) return null;
            return .{ .x = @intCast(x0), .y = @intCast(y0), .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
        }

        pub fn unite(a: Self, b: Self) Self {
            if (a.isEmpty()) return b;
            if (b.isEmpty()) return a;
            const x0 = @min(@as(i64, a.x), b.x);
            const y0 = @min(@as(i64, a.y), b.y);
            return .{
                .x = @intCast(x0),
                .y = @intCast(y0),
                .width = @intCast(@max(a.right(), b.right()) - x0),
                .height = @intCast(@max(a.bottom(), b.bottom()) - y0),
            };
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
        }
    };
}

pub const LogicalRect = Rect(.logical);
pub const BufferRect = Rect(.buffer);

/// A float rectangle in buffer pixels (e.g. a Vulkan viewport that may extend off-target).
pub const BufferRectF = struct { x: f32, y: f32, width: f32, height: f32 };

/// Fractional scale in 120ths (wp_fractional_scale_v1), 120 = 1.0.
pub const Scale = struct {
    n120: u32 = 120,

    pub const one: Scale = .{};

    pub fn factor(s: Scale) f32 {
        return @as(f32, @floatFromInt(s.n120)) / 120.0;
    }

    /// Rounds like the fractional-scale protocol: buffer = round(logical * scale).
    pub fn length(s: Scale, v: u32) u32 {
        return @intCast(@max(1, (@as(u64, v) * s.n120 + 60) / 120));
    }

    pub fn coord(s: Scale, v: i32) i32 {
        return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * @as(f64, @floatFromInt(s.n120)) / 120.0));
    }

    pub fn coordF(s: Scale, v: i32) f32 {
        return @as(f32, @floatFromInt(v)) * s.factor();
    }

    /// Edges are rounded individually, so adjacent rects stay adjacent after scaling.
    pub fn rect(s: Scale, r: LogicalRect) BufferRect {
        const x0 = s.coord(r.x);
        const y0 = s.coord(r.y);
        const x1 = s.coord(r.x + @as(i32, @intCast(r.width)));
        const y1 = s.coord(r.y + @as(i32, @intCast(r.height)));
        return .{ .x = x0, .y = y0, .width = @intCast(@max(0, x1 - x0)), .height = @intCast(@max(0, y1 - y0)) };
    }
};

test "adjacent rects stay adjacent under fractional scale" {
    const s: Scale = .{ .n120 = 150 }; // 1.25
    const a = s.rect(.{ .x = 0, .y = 0, .width = 401, .height = 10 });
    const b = s.rect(.{ .x = 401, .y = 0, .width = 399, .height = 10 });
    try std.testing.expectEqual(a.right(), b.x);
}

test "intersect and unite" {
    const a: LogicalRect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b: LogicalRect = .{ .x = 5, .y = 5, .width = 10, .height = 10 };
    try std.testing.expect(a.intersect(b).?.eql(.{ .x = 5, .y = 5, .width = 5, .height = 5 }));
    try std.testing.expect(a.unite(b).eql(.{ .x = 0, .y = 0, .width = 15, .height = 15 }));
}
