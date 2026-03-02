const std = @import("std");
const animation = @import("animation.zig");

// draws a discretized ellipse into grid
// x and y radius must fit within grid dimensions
pub fn splat(x_radius: f64, y_radius: f64, grid_size: i16, grid: []bool) void {
    for (0..@as(usize, @intCast(grid_size))) |rix| {
        for (0..@as(usize, @intCast(grid_size))) |cix| {
            const x: f64 = @as(f64, @floatFromInt(rix)) - @as(f64, @floatFromInt(grid_size)) / 2.0;
            const y: f64 = @as(f64, @floatFromInt(cix)) - @as(f64, @floatFromInt(grid_size)) / 2.0;
            const ix: usize = @as(usize, @intCast(grid_size)) * rix + cix;
            const lhs: f64 = (x * x) / (x_radius * x_radius) + (y * y) / (y_radius * y_radius);
            if (lhs <= 1.0) {
                grid[ix] = true;
            } else {
                grid[ix] = false;
            }
        }
    }
}

pub const IVec2 = struct {
    x: i16 = 0,
    y: i16 = 0,

    pub const zero: IVec2 = .{
        .x = 0,
        .y = 0,
    };
    pub const default: IVec2 = .{
        .x = -3200,
        .y = -3200,
    };

    pub fn float(self: IVec2) Vec2 {
        return .{ .x = @floatFromInt(self.x), .y = @floatFromInt(self.y) };
    }

    pub fn plus(self: IVec2, rhs: IVec2) IVec2 {
        return .{
            .x = self.x + rhs.x,
            .y = self.y + rhs.y,
        };
    }

    pub fn minus(self: IVec2, rhs: IVec2) IVec2 {
        return .{
            .x = self.x - rhs.x,
            .y = self.y - rhs.y,
        };
    }

    pub fn scaled(self: IVec2, c: i16) IVec2 {
        return .{
            .x = self.x * c,
            .y = self.y * c,
        };
    }

    pub fn eq(self: IVec2, rhs: IVec2) bool {
        return self.x == rhs.x and self.y == rhs.y;
    }

    pub fn times(self: IVec2, rhs: IVec2) IVec2 {
        return .{
            .x = self.x * rhs.x,
            .y = self.y * rhs.y,
        };
    }

    pub fn max_norm(self: IVec2) i16 {
        return @intCast(@max(@abs(self.x), @abs(self.y)));
    }

    pub fn max_norm_distance(self: IVec2, other: IVec2) i16 {
        return self.minus(other).max_norm();
    }

    pub fn projection(self: IVec2, dir: Dir4) IVec2 {
        return self.times(dir.ivec());
    }

    pub fn facing(self: IVec2, other: IVec2) Dir4 {
        const diff: IVec2 = other.minus(self);
        std.log.info("diff x {} y {}", .{ diff.x, diff.y });
        if (diff.x > 0 and @abs(diff.x) >= @abs(diff.y)) {
            return .Right;
        } else if (diff.y < 0 and @abs(diff.y) >= @abs(diff.x)) {
            return .Up;
        } else if (diff.x < 0 and @abs(diff.x) >= @abs(diff.x)) {
            return .Left;
        } else {
            return .Down;
        }
    }
};

pub const Dir4 = enum {
    Right,
    Up,
    Left,
    Down,
    pub fn ivec(self: Dir4) IVec2 {
        return switch (self) {
            .Right => IVec2{ .x = 1 },
            .Left => IVec2{ .x = -1 },
            .Down => IVec2{ .y = 1 },
            .Up => IVec2{ .y = -1 },
        };
    }

    pub fn turn(self: Dir4, rd: RelativeDir) Dir4 {
        const uself: u8 = @intFromEnum(self);
        const urd: u8 = @intFromEnum(rd);
        const combined: u2 = @truncate(uself + urd);
        return @enumFromInt(combined);
    }
};

pub const RelativeDir = enum {
    Forward,
    Left,
    Reverse,
    Right,

    // This new direction is ____ compared to the starting dir
    pub fn from(new: Dir4, root: Dir4) RelativeDir {
        const inew: i8 = @intCast(@intFromEnum(new));
        const iroot: i8 = @intCast(@intFromEnum(root));
        return switch (inew - iroot) {
            -3 => .Left,
            -2 => .Reverse,
            -1 => .Right,
            0 => .Forward,
            1 => .Left,
            2 => .Reverse,
            3 => .Right,
            else => unreachable,
        };
    }
};

pub const Vec2 = extern struct {
    x: f32,
    y: f32,

    pub const ZERO: Vec2 = .{ .x = 0, .y = 0 };

    pub const default: Vec2 = .{
        .x = -3200,
        .y = -3200,
    };

    pub fn plus(self: Vec2, rhs: Vec2) Vec2 {
        return .{
            .x = self.x + rhs.x,
            .y = self.y + rhs.y,
        };
    }
    pub fn minus(self: Vec2, rhs: Vec2) Vec2 {
        return .{
            .x = self.x - rhs.x,
            .y = self.y - rhs.y,
        };
    }

    pub fn scale(self: Vec2, c: f32) Vec2 {
        return .{
            .x = self.x * c,
            .y = self.y * c,
        };
    }

    pub fn linear(x0: Vec2, x1: Vec2, target: *Vec2, time: animation.Time) animation.Exit!void {
        const t = time.progress();
        target.* = x0.scale(1 - t).plus(x1.scale(t));
    }

    pub fn cubic(x0: Vec2, dx0: Vec2, x1: Vec2, dx1: Vec2, target: *Vec2, time: animation.Time) animation.Exit!void {
        const t = time.progress();
        target.*.x = animation.eval_hermite(.{
            .h00 = x0.x,
            .h01 = x1.x,
            .h10 = dx0.x,
            .h11 = dx1.x,
        }, t);
        target.*.y = animation.eval_hermite(.{
            .h00 = x0.y,
            .h01 = x1.y,
            .h10 = dx0.y,
            .h11 = dx1.y,
        }, t);
    }

    pub fn distance(self: Vec2, rhs: Vec2) f32 {
        const dx = self.x - rhs.x;
        const dy = self.y - rhs.y;
        const ssq = dx * dx + dy * dy;
        return std.math.sqrt(ssq);
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn pos(self: Rect) Vec2 {
        return Vec2{ .x = self.x, .y = self.y };
    }

    pub fn xmax(self: Rect) f32 {
        return self.x + self.w;
    }
    pub fn ymax(self: Rect) f32 {
        return self.y + self.h;
    }
};
