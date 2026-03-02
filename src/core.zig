const std = @import("std");
const animation = @import("animation.zig");

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
};

pub const Vec2 = extern struct {
    x: f32,
    y: f32,

    pub const ZERO: Vec2 = .{ .x = 0, .y = 0 };

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
