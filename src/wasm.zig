const std = @import("std");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const RenderBuffer = @import("render.zig");
const Sprite = RenderBuffer.Sprite;
const main = @import("main.zig");

const Vec2 = @import("core.zig").Vec2;
const IVec2 = main.IVec2;
const Rect = @import("core.zig").Rect;

pub const std_options: std.Options = .{
    .logFn = log,
};

pub const js = struct {
    pub extern "util" fn log(strPtr: i32, strLen: i32) void;
};

var printBuffer: [8192]u8 = .{0} ** 8192;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = comptime level.asText();
    const slice = std.fmt.bufPrint(printBuffer[0..], prefix ++ ": " ++ format, args) catch {
        std.log.err("log failed: message too long", .{});
        return;
    };
    const len: usize = slice.len;
    const ptr = slice.ptr;
    js.log(@intCast(@intFromPtr(ptr)), @intCast(len));
}

var prev_time: f64 = 0;

var render_buffer: RenderBuffer = undefined;
var prng: std.Random.DefaultPrng = undefined;
var camera: Rect = Rect{
    .x = 0,
    .y = 0,
    .w = 8 * 64,
    .h = 8 * 64,
};

pub export fn init(buffer_size: i32, screenW: f32, screenH: f32) i32 {
    const allocator = std.heap.wasm_allocator;
    resize(screenW, screenH);

    // TODO: init rng with current time
    prng = std.Random.DefaultPrng.init(12345);

    render_buffer = RenderBuffer.init(allocator, @intCast(buffer_size)) catch return -1;

    main.init() catch return -1;

    std.log.info("hello", .{});

    return 0;
}

pub export fn resize(w: f32, h: f32) void {
    // TODO
    _ = w;
    _ = h;
}

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

const SPRITE_DIM = Vec2{ .x = 16, .y = 16 };

fn render_unit(unit: *const main.Unit) void {
    switch (unit.tag) {
        .Player => {
            const render_at = unit.position.float();
            const screen_space = render_at.minus(camera.pos());

            render_buffer.push(.{
                .pos = screen_space.scale(16),
                .size = SPRITE_DIM,
                .color = BLACK,
                .src_idx = 0xDB,
            });
            render_buffer.push(.{
                .pos = screen_space.scale(16),
                .size = SPRITE_DIM,
                .color = WHITE,
                .src_idx = '@',
            });
        },
        else => {
            return;
        },
    }
}

const WHITE = 0;
const BLACK = 13;

pub export fn frame(t: f64) void {
    const rawdt = t - prev_time;
    const dt: f32 = @floatCast(@min(20, rawdt));
    prev_time = t;

    audio.tick(dt);
    keyboard.globals.update();
    mouse.globals.update();

    RenderBuffer.clear();

    if (keyboard.firstJustPressed()) |key| {
        main.logic_tick(key, prng.random());
    }

    // Draw the terrain
    const imin = IVec2{
        .x = @intFromFloat(@floor(camera.x)),
        .y = @intFromFloat(@floor(camera.y)),
    };
    for (0..65) |dx| {
        for (0..65) |dy| {
            const x = imin.x + @as(i16, @intCast(dx));
            const y = imin.y + @as(i16, @intCast(dy));
            const pos = IVec2{
                .x = x * 16,
                .y = y * 16,
            };
            const terrain = main.get_terrain_at(pos) orelse continue;
            const draw_sprite = Sprite{
                .pos = pos.float().minus(camera.pos()),
                .color = WHITE,
                .size = Vec2{ .x = 16, .y = 16 },
                .src_idx = terrain.glyph(),
            };
            render_buffer.push(draw_sprite);
        }
    }
    // The render buffer assumes that all images in the same batch
    // are the same size. So we flush before drawing anything at
    // a different size. (If we don't, that will resize the previous
    // images.)
    render_buffer.flush();

    // Draw units over the terrain
    for (main.globals.units) |u| {
        if (u.tag == .Nil) {
            continue;
        }
        render_unit(&u);
    }
    render_buffer.flush();

    splatString(10, 10, "hello world", 0, 32);

    render_buffer.flush();
}
