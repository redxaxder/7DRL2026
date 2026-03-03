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

    pub const ZERO: IVec2 = .{
        .x = 0,
        .y = 0,
    };
    pub const DEFAULT: IVec2 = .{
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

    pub fn scan(self: IVec2, dir: Dir4, distance: i16) ScanIterator {
        return .{ .pos = self, .step = dir.ivec(), .remaining = distance };
    }

    pub fn principal_dir(self: IVec2) Dir4 {
        const ax = @abs(self.x);
        const ay = @abs(self.y);
        if (ax >= ay) {
            if (self.x >= 0) {
                return .Right;
            } else {
                return .Left;
            }
        } else {
            if (self.y >= 0) {
                return .Down;
            } else {
                return .Up;
            }
        }
    }

    pub fn facing(self: IVec2, other: IVec2) Dir4 {
        return principal_dir(other.minus(self));
    }
};

pub const ScanIterator = struct {
    pos: IVec2,
    step: IVec2,
    remaining: i16,

    pub fn next(self: *ScanIterator) ?IVec2 {
        if (self.remaining <= 0) return null;
        self.pos = self.pos.plus(self.step);
        self.remaining -= 1;
        return self.pos;
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
    pub const ONE: Vec2 = .{ .x = 1, .y = 1 };

    pub const DEFAULT: Vec2 = .{
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

    pub fn scaled(self: Vec2, c: f32) Vec2 {
        return .{
            .x = self.x * c,
            .y = self.y * c,
        };
    }

    pub fn linear(x0: Vec2, x1: Vec2, target: *Vec2, time: animation.Time) animation.Exit!void {
        const t = time.progress();
        target.* = x0.scaled(1 - t).plus(x1.scaled(t));
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

pub const IRect = struct {
    x: i16 = -3200,
    y: i16 = -3200,
    w: i16 = 0,
    h: i16 = 0,

    pub fn contains(self: IRect, p: IVec2) bool {
        return p.x >= self.x and p.x < self.x + self.w and
            p.y >= self.y and p.y < self.y + self.h;
    }

    pub fn iter(self: IRect) LocationIterator {
        return .{ .rect = self };
    }

    pub fn from(loc: IVec2, size: IVec2) IRect {
        return .{ .x = loc.x, .y = loc.y, .w = size.x, .h = size.y };
    }

    pub fn singleton(pos: IVec2) IRect {
        return .{ .x = pos.x, .y = pos.y, .w = 1, .h = 1 };
    }

    pub fn intersects(self: IRect, other: IRect) bool {
        return self.x < other.x + other.w and other.x < self.x + self.w and
            self.y < other.y + other.h and other.y < self.y + self.h;
    }

    pub fn displace(self: IRect, displacement: IVec2) IRect {
        return .{ .x = self.x + displacement.x, .y = self.y + displacement.y, .w = self.w, .h = self.h };
    }

    pub fn distance(self: IRect, other: IRect) IVec2 {
        const most_left: IRect = if (self.x < other.x) self else other;
        const most_right: IRect = if (self.x < other.x) other else self;
        var xDiff: i16 = if (most_left.x == most_right.x) 0 else 1 + most_right.x - (most_left.x + most_left.w);
        xDiff = if (xDiff > 0) xDiff else 0;

        const most_up: IRect = if (self.y < other.y) self else other;
        const most_down: IRect = if (self.y < other.y) other else self;
        var yDiff: i16 = if (most_up.y == most_down.y) 0 else 1 + most_down.y - (most_up.y + most_up.h);
        yDiff = if (yDiff > 0) yDiff else 0;

        return .{ .x = xDiff, .y = yDiff };
    }

    pub fn point_distance(self: IRect, point: IVec2) IVec2 {
        const l: i16 = self.x;
        const t: i16 = self.y;
        const r: i16 = self.x + self.w - 1;
        const b: i16 = self.x + self.h - 1;

        var xDist: i16 = undefined;
        var yDist: i16 = undefined;

        if (point.x > r) {
            xDist = point.x - r;
        } else if (point.x < l) {
            xDist = l - point.x;
        } else {
            xDist = 0;
        }

        if (point.y > b) {
            yDist = point.y - b;
        } else if (point.y < t) {
            yDist = t - point.y;
        } else {
            yDist = 0;
        }

        return .{ .x = xDist, .y = yDist };
    }

    pub const LocationIterator = struct {
        rect: IRect,
        ix: i16 = 0,
        iy: i16 = 0,

        pub fn next(self: *LocationIterator) ?IVec2 {
            if (self.iy >= self.rect.h) return null;
            const result = IVec2{
                .x = self.rect.x + self.ix,
                .y = self.rect.y + self.iy,
            };
            self.ix += 1;
            if (self.ix >= self.rect.w) {
                self.ix = 0;
                self.iy += 1;
            }
            return result;
        }
    };
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
