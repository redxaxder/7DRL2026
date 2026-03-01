const std = @import("std");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const RenderBuffer = @import("render.zig");
const Sprite = RenderBuffer.Sprite;

const Vec2 = @import("core.zig").Vec2;
const Rect = @import("core.zig").Rect;

var prev_time: f64 = 0;

fn splatString(x: f32, y: f32, text: []const u8, color: u8, size: f32) void {
    var cx = x;
    for (text) |ch| {
        render_buffer.push(.{
            .pos = .{ .x = cx, .y = y },
            .size = .{ .x = size, .y = size },
            .src_idx = ch,
            .color = color,
        });
        cx += size;
    }
}

var render_buffer: RenderBuffer = undefined;
var prng: std.Random.DefaultPrng = undefined;

pub export fn init(buffer_size: i32, screenW: f32, screenH: f32) i32 {
    const allocator = std.heap.wasm_allocator;
    resize(screenW, screenH);

    // TODO: init rng with current time
    prng = std.Random.DefaultPrng.init(12345);

    render_buffer = RenderBuffer.init(allocator, @intCast(buffer_size)) catch return -1;

    return 0;
}

pub export fn resize(w: f32, h: f32) void {
    // TODO
    _ = w;
    _ = h;
}

pub export fn frame(t: f64) void {
    const rawdt = t - prev_time;
    const dt: f32 = @floatCast(@min(20, rawdt));
    prev_time = t;

    audio.tick(dt);
    keyboard.globals.update();
    mouse.globals.update();

    RenderBuffer.clear();

    splatString(10, 10, "hello world", 0, 32);

    render_buffer.flush();
}
