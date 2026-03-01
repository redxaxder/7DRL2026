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

const CameraWidth = 65;
const CameraHeight = 65;

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

const SPRITE_SCALE = 16;
const SPRITE_DIM = Vec2{ .x = SPRITE_SCALE, .y = SPRITE_SCALE };

const DrawOptions = struct {
    clear_back: bool = false,
    size: u8 = 1,
    color: u8 = WHITE,
};
// accepts a position in world coordinates, it converts it to camera coordinates and adds a render buffer item
pub fn draw_world_glyph(world_pos: Vec2, src_idx: u8, options: DrawOptions) void {
    const screen_pos = world_pos.minus(camera.pos()).scale(SPRITE_SCALE);
    const dim = SPRITE_DIM.scale(@floatFromInt(options.size));

    if (options.clear_back) {
        render_buffer.push(.{
            .pos = screen_pos,
            .size = dim,
            .color = BLACK,
            .src_idx = 0xDB,
        });
    }
    render_buffer.push(.{
        .pos = screen_pos,
        .size = dim,
        .color = options.color,
        .src_idx = src_idx,
    });
}

fn render_kaiju(kaiju: *const main.Unit) void {
    // Box-drawing layout for a size-N kaiju (dim = 2*N+1):
    //   ┌─…─┐
    //   │   │
    //   │ K │
    //   │   │
    //   └─…─┘
    const s: i16 = @intCast(kaiju.size);
    const dim: i16 = 2 * s + 1;
    var dy: i16 = 0;
    while (dy < dim) : (dy += 1) {
        var dx: i16 = 0;
        while (dx < dim) : (dx += 1) {
            const pos = kaiju.position.plus(.{ .x = dx, .y = dy });
            const is_top = dy == 0;
            const is_bottom = dy == dim - 1;
            const is_left = dx == 0;
            const is_right = dx == dim - 1;
            const is_center = dx == s and dy == s;

            const glyph: u8 = if (is_center)
                'K'
            else if (is_top and is_left)
                0xDA // ┌
            else if (is_top and is_right)
                0xBF // ┐
            else if (is_bottom and is_left)
                0xC0 // └
            else if (is_bottom and is_right)
                0xD9 // ┘
            else if (is_top or is_bottom)
                0xC4 // ─
            else if (is_left or is_right)
                0xB3 // │
            else
                ' ';

            const color: u8 = if (is_center) 3 else 1; // red K, green border
            draw_world_glyph(pos.float(), glyph, .{ .clear_back = true, .color = color, .size = @as(u8, @intCast(s)) - 2 });
        }
    }
}
fn render_unit(unit: *const main.Unit) void {
    switch (unit.tag) {
        .Player => {
            draw_world_glyph(
                unit.position.float(),
                '@',
                .{ .clear_back = true },
            );
        },
        .Motorcycle => {
            const p0 = unit.position;
            const p1 = p0.plus(unit.orientation.ivec());
            draw_world_glyph(p0.float(), 'o', .{ .clear_back = true });

            draw_world_glyph(p1.float(), '%', .{ .clear_back = true });
        },
        .Kaiju => render_kaiju(unit),
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
    for (0..CameraWidth) |dx| {
        for (0..CameraHeight) |dy| {
            const x = imin.x + @as(i16, @intCast(dx));
            const y = imin.y + @as(i16, @intCast(dy));
            const draw_pos = IVec2{
                .x = x * SPRITE_SCALE,
                .y = y * SPRITE_SCALE,
            };
            const world_pos = IVec2{
                .x = x,
                .y = y,
            };
            const terrain = main.get_terrain_at(world_pos) orelse continue;
            const draw_sprite = Sprite{
                .pos = draw_pos.float().minus(camera.pos()),
                .color = WHITE,
                .size = Vec2{ .x = SPRITE_SCALE, .y = SPRITE_SCALE },
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
    {
        var i: u16 = @intCast(main.globals.units.len);
        while (i > 1) {
            i -= 1;
            const u = main.globals.unit(i);
            if (u.tag == .Nil) {
                continue;
            }
            render_unit(u);
        }
    }
    render_buffer.flush();

    splatString(10, 10, "hello world", 0, 32);

    render_buffer.flush();
}
