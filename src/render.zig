const std = @import("std");
const Vec2 = @import("core.zig").Vec2;

const Self = @This();

dest_pos: [*]Vec2,
src_idx: [*]u8,
color: [*]u8,
occupancy: usize,
max: usize,
last_seen_size: Vec2 = .ZERO,

pub const js = struct {
    pub extern "render" fn clear() void;
    pub extern "render" fn draw(dstPtr: i32, srcPtr: i32, colorPtr: i32, count: i32, srcW: i32, srcH: i32, dstW: f32, dstH: f32) void;
};

pub fn clear() void {
    js.clear();
}

pub const Sprite = struct {
    pos: Vec2,
    size: Vec2,
    src_idx: u8,
    color: u8,
};

pub fn init(allocator: std.mem.Allocator, max: usize) !Self {
    return .{
        .dest_pos = (try allocator.alloc(Vec2, max)).ptr,
        .src_idx = (try allocator.alloc(u8, max)).ptr,
        .color = (try allocator.alloc(u8, max)).ptr,
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
    self.dest_pos[self.occupancy] = sprite.pos;
    self.src_idx[self.occupancy] = sprite.src_idx;
    self.color[self.occupancy] = sprite.color;
    self.occupancy += 1;
}

pub fn flush(self: *Self) void {
    const dstPtr: i32 = @intCast(@intFromPtr(self.dest_pos));
    const srcPtr: i32 = @intCast(@intFromPtr(self.src_idx));
    const colorPtr: i32 = @intCast(@intFromPtr(self.color));
    const count: i32 = @intCast(self.occupancy);
    js.draw(dstPtr, srcPtr, colorPtr, count, 8, 8, self.last_seen_size.x, self.last_seen_size.y);
    self.occupancy = 0;
}
