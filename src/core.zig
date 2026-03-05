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

    pub const ZERO: IVec2 = .{ .x = 0, .y = 0 };
    pub const ONE: IVec2 = .{ .x = 1, .y = 1 };
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
            else => {
                std.log.err("[0123] - [0123] <= 3", {});
                unreachable;
            },
        };
    }
};

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const ZERO: Vec2 = .{ .x = 0, .y = 0 };
    pub const ONE: Vec2 = .{ .x = 1, .y = 1 };

    pub const DEFAULT: Vec2 = .{
        .x = -3200,
        .y = -3200,
    };

    pub fn rounded(self: Vec2, precision: f32) Vec2 {
        return .{
            .x = std.math.round(self.x * precision) / precision,
            .y = std.math.round(self.y * precision) / precision,
        };
    }

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

    pub fn max_norm(self: Vec2) f32 {
        const ax = @abs(self.x);
        const ay = @abs(self.y);
        return @max(ax, ay);
    }
};

pub const Orientation =
    enum { v, h };

pub const Interval = struct {
    origin: i16,
    len: i16,

    pub fn overlap(self: Interval, rhs: Interval) bool {
        return self.origin < rhs.origin + rhs.len and rhs.origin < self.origin + self.len;
    }

    pub fn expand(self: Interval, amount: i16) Interval {
        return .{
            .origin = self.origin - amount,
            .len = self.origin + 2 * amount,
        };
    }

    pub fn slice(self: Interval, interval: Interval) [3]Interval {
        // 34567890
        //   567
        //
        // parent: 34567890
        // slice: 567
        //
        // parent: 3, 8   [11 - 8]
        // slice:  5, 3
        // A: 34 - (3,2)
        // B: 567  (5,3)
        // C: 890  (8,3)
        //

        if (interval.origin < self.origin or
            interval.len >= self.len or
            interval.origin + interval.len > self.origin + self.len)
        {
            std.log.info("no! {} {}", .{ self, interval });
            unreachable;
        }

        const got: [3]Interval = .{
            .{ .origin = self.origin, .len = interval.origin - self.origin }, interval, .{
                .origin = interval.origin + interval.len,
                .len = self.origin + self.len - (interval.origin + interval.len),
            },
        };
        for (got) |it| {
            if (it.origin < 0 or it.len < 0) {
                std.log.info("yoyoyo {any}", .{got});
                @panic("whaaaa");
            }
        }
        return got;
    }
};

pub const IRect = struct {
    x: i16 = -3200,
    y: i16 = -3200,
    w: i16 = 0,
    h: i16 = 0,

    pub fn intervals(self: IRect) [2]Interval {
        return .{
            .{ .origin = self.x, .len = self.w },
            .{ .origin = self.y, .len = self.h },
        };
    }
    pub fn from_intervals(xyintervals: [2]Interval) IRect {
        return .{
            .x = xyintervals[0].origin,
            .y = xyintervals[1].origin,
            .w = xyintervals[0].len,
            .h = xyintervals[1].len,
        };
    }

    pub fn slice(self: IRect, orientation: Orientation, interval: Interval) [3]IRect {
        const h, const v = self.intervals();
        var result: [3]IRect = undefined;
        switch (orientation) {
            .v => {
                for (h.slice(interval), &result) |hslice, *out| {
                    out.* = from_intervals(.{ hslice, v });
                }
            },
            .h => {
                for (v.slice(interval), &result) |vslice, *out| {
                    out.* = from_intervals(.{ h, vslice });
                }
            },
        }
        return result;
    }

    pub fn bounding_box(positions: []const IVec2) IRect {
        var min_x = positions[0].x;
        var min_y = positions[0].y;
        var max_x = positions[0].x;
        var max_y = positions[0].y;
        for (positions[1..]) |p| {
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }
        return .{
            .x = min_x,
            .y = min_y,
            .w = max_x - min_x,
            .h = max_y - min_y,
        };
    }
    pub fn float(self: IRect) Rect {
        return .{
            .x = @floatFromInt(self.x),
            .y = @floatFromInt(self.y),
            .w = @floatFromInt(self.w),
            .h = @floatFromInt(self.h),
        };
    }

    pub fn ivec(self: IRect) IVec2 {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn vertical(self: IRect) Interval {
        return .{ .origin = self.y, .len = self.h };
    }
    pub fn horizontal(self: IRect) Interval {
        return .{ .origin = self.x, .len = self.w };
    }

    pub fn contains(self: IRect, p: IVec2) bool {
        return p.x >= self.x and p.x < self.x + self.w and
            p.y >= self.y and p.y < self.y + self.h;
    }

    pub fn contains_rect(self: IRect, r: IRect) bool {
        return r.x >= self.x and r.x + r.w <= self.x + self.w and
            r.y >= self.y and r.y + r.h <= self.y + self.h;
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

    pub fn from_linear_index(self: IRect, index: usize) IVec2 {
        const w: usize = @intCast(self.w);
        const ix: i16 = @intCast(index % w);
        const iy: i16 = @intCast(index / w);
        return .{ .x = self.x + ix, .y = self.y + iy };
    }

    pub fn intersects(self: IRect, other: IRect) bool {
        return self.x < other.x + other.w and other.x < self.x + self.w and
            self.y < other.y + other.h and other.y < self.y + self.h;
    }

    pub fn expand(self: IRect, amount: i16) IRect {
        return .{
            .x = self.x - amount,
            .y = self.y - amount,
            .w = self.w + 2 * amount,
            .h = self.h + 2 * amount,
        };
    }

    pub fn displace(self: IRect, displacement: IVec2) IRect {
        return .{ .x = self.x + displacement.x, .y = self.y + displacement.y, .w = self.w, .h = self.h };
    }

    pub fn distance(self: IRect, other: IRect) IVec2 {
        const most_left: IRect = if (self.x < other.x) self else other;
        const most_right: IRect = if (self.x < other.x) other else self;
        var xDiff: i16 = if (most_left.x == most_right.x) 0 else most_right.x - (most_left.x + most_left.w);
        xDiff = if (xDiff > 0) xDiff else 0;

        const most_up: IRect = if (self.y < other.y) self else other;
        const most_down: IRect = if (self.y < other.y) other else self;
        var yDiff: i16 = if (most_up.y == most_down.y) 0 else most_down.y - (most_up.y + most_up.h);
        yDiff = if (yDiff > 0) yDiff else 0;

        return .{ .x = xDiff, .y = yDiff };
    }

    pub fn point_distance(self: IRect, point: IVec2) IVec2 {
        return self.distance(IRect.singleton(point));
    }

    pub fn slide(self: IRect, dir: Dir4, dist: i16) SlideIterator {
        const step = dir.ivec();
        const abs_x: i16 = @intCast(@abs(step.x));
        const abs_y: i16 = @intCast(@abs(step.y));
        const edge = IRect{
            .x = self.x + @max(step.x, 0) * (self.w - 1),
            .y = self.y + @max(step.y, 0) * (self.h - 1),
            .w = abs_x + self.w * abs_y,
            .h = abs_y + self.h * abs_x,
        };
        return .{ .edge = edge, .step = step, .remaining = dist };
    }

    pub const SlideIterator = struct {
        edge: IRect,
        step: IVec2,
        remaining: i16,

        pub fn next(self: *SlideIterator) ?IRect {
            if (self.remaining <= 0) return null;
            self.remaining -= 1;
            self.edge = self.edge.displace(self.step);
            return self.edge;
        }
    };

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

    pub fn expand_vertically(self: IRect, n: i16) IRect {
        return .{
            .x = self.x,
            .y = self.y - n,
            .w = self.w,
            .h = self.h + 2 * n,
        };
    }

    pub fn expand_horizontally(self: IRect, n: i16) IRect {
        return .{
            .x = self.x - n,
            .y = self.y,
            .w = self.w + 2 * n,
            .h = self.h,
        };
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn pos(self: Rect) Vec2 {
        return Vec2{ .x = self.x, .y = self.y };
    }
    pub fn center(self: Rect) Vec2 {
        return .{
            .x = self.x + self.w / 2,
            .y = self.y + self.h / 2,
        };
    }
    pub fn scaled(self: Rect, scale: f32) Rect {
        return .{
            .x = self.x * scale,
            .y = self.y * scale,
            .w = self.w * scale,
            .h = self.h * scale,
        };
    }

    pub fn expand(self: Rect, amount: f32) Rect {
        return .{
            .x = self.x - amount,
            .y = self.y - amount,
            .w = self.w + 2 * amount,
            .h = self.h + 2 * amount,
        };
    }

    pub fn xmax(self: Rect) f32 {
        return self.x + self.w;
    }
    pub fn ymax(self: Rect) f32 {
        return self.y + self.h;
    }
    pub fn irect(self: Rect) IRect {
        return .{
            .x = @as(i16, @intFromFloat(self.x)),
            .y = @as(i16, @intFromFloat(self.y)),
            .w = @as(i16, @intFromFloat(self.w)),
            .h = @as(i16, @intFromFloat(self.h)),
        };
    }
};
