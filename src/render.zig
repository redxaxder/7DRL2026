const std = @import("std");
const Vec2 = @import("core.zig").Vec2;
const Rect = @import("core.zig").Rect;

const Self = @This();

var xform_scale: f32 = 1.0;
var xform_offset: Vec2 = .ZERO;

pub fn setTransform(screen_w: f32, screen_h: f32, virtual_w: f32, virtual_h: f32) void {
    xform_scale = @min(screen_w / virtual_w, screen_h / virtual_h);
    xform_offset = .{
        .x = (screen_w - virtual_w * xform_scale) / 2,
        .y = (screen_h - virtual_h * xform_scale) / 2,
    };
}

fn transformRect(r: Rect) Rect {
    return .{
        .x = r.x * xform_scale + xform_offset.x,
        .y = r.y * xform_scale + xform_offset.y,
        .w = r.w * xform_scale,
        .h = r.h * xform_scale,
    };
}

dest_pos: [*]Vec2,
src_idx: [*]u8,
color: [*]Color,
occupancy: usize,
max: usize,
last_seen_size: Vec2 = .ZERO,

pub const js = struct {
    pub extern "render" fn clear() void;
    pub extern "render" fn draw(dstPtr: i32, srcPtr: i32, colorPtr: i32, count: i32, srcW: i32, srcH: i32, dstW: f32, dstH: f32) void;
    pub extern "render" fn clearRect(x: f32, y: f32, w: f32, h: f32, colorIdx: u8) void;
    pub extern "render" fn scissor(x: f32, y: f32, w: f32, h: f32) void;
    pub extern "render" fn unscissor() void;
};

pub const clear = js.clear;
pub const unscissor = js.unscissor;

pub fn scissor(r: Rect) void {
    const t = transformRect(r);
    js.scissor(t.x, t.y, t.w, t.h);
}

pub fn clear_rect(r: Rect, color: Color) void {
    const t = transformRect(r);
    js.clearRect(t.x, t.y, t.w, t.h, @intFromEnum(color));
}

pub const Color = enum(u8) {
    white = 0,
    green = 1,
    yellow = 2,
    red = 3,
    orange = 4,
    chartreuse = 5,
    green2 = 6,
    teal = 7,
    cyan = 8,
    blue = 9,
    indigo = 10,
    purple = 11,
    magenta = 12,
    black = 13,
    gray = 14,
    dark_gray = 15,
    brown = 16,
    pink = 17,
    dark_red = 18,
    dark_blue = 19,
    dark_green = 20,
};

pub const Sprite = struct {
    pos: Vec2,
    size: Vec2,
    src_idx: u8,
    color: Color,
};

pub fn init(allocator: std.mem.Allocator, max: usize) !Self {
    return .{
        .dest_pos = (try allocator.alloc(Vec2, max)).ptr,
        .src_idx = (try allocator.alloc(u8, max)).ptr,
        .color = (try allocator.alloc(Color, max)).ptr,
        .occupancy = 0,
        .max = max,
    };
}

// assumes that flush is called before pushing a sprite of a different size
// if this isn't true, all other sprites in the batch will be drawn at the new size
pub fn push(self: *Self, sprite: Sprite) void {
    if (self.occupancy >= self.max) {
        self.flush();
    }
    self.last_seen_size = sprite.size;
    self.dest_pos[self.occupancy] = sprite.pos.scaled(xform_scale).plus(xform_offset);
    self.src_idx[self.occupancy] = sprite.src_idx;
    self.color[self.occupancy] = sprite.color;
    self.occupancy += 1;
}

pub fn flush(self: *Self) void {
    const dstPtr: i32 = @intCast(@intFromPtr(self.dest_pos));
    const srcPtr: i32 = @intCast(@intFromPtr(self.src_idx));
    const colorPtr: i32 = @intCast(@intFromPtr(@as([*]u8, @ptrCast(self.color))));
    const count: i32 = @intCast(self.occupancy);
    js.draw(dstPtr, srcPtr, colorPtr, count, 8, 8, self.last_seen_size.x * xform_scale, self.last_seen_size.y * xform_scale);
    self.occupancy = 0;
}
