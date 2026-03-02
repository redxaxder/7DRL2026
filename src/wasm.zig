const std = @import("std");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const RenderBuffer = @import("render.zig");
const Sprite = RenderBuffer.Sprite;
const main = @import("main.zig");

const Vec2 = @import("core.zig").Vec2;
const IVec2 = @import("core.zig").IVec2;
const Rect = @import("core.zig").Rect;

const CameraWidth = 65;
const CameraHeight = 65;

pub const std_options: std.Options = .{
    .logFn = log,
};

pub const js = struct {
    pub extern "util" fn log(strPtr: i32, strLen: i32) void;
    pub extern "util" fn time() u64;
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
    .w = 64,
    .h = 64,
};

pub export fn init(buffer_size: i32, screenW: f32, screenH: f32) i32 {
    const allocator = std.heap.wasm_allocator;
    resize(screenW, screenH);

    // TODO: init rng with current time
    prng = std.Random.DefaultPrng.init(@bitCast(js.time()));

    render_buffer = RenderBuffer.init(allocator, @intCast(buffer_size)) catch return -1;

    main.init(prng.random()) catch return -1;

    std.log.info("hello", .{});

    return 0;
}

pub export fn resize(w: f32, h: f32) void {
    // TODO
    _ = w;
    _ = h;
}

fn splatString(x: f32, y: f32, text: []const u8, color: Color, size: f32) void {
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
    color: Color = .white,
};
pub fn draw_world_glyph(world_pos: Vec2, src_idx: u8, options: DrawOptions) void {
    const screen_pos = world_pos.minus(camera.pos()).scale(SPRITE_SCALE);
    const dim = SPRITE_DIM.scale(@floatFromInt(options.size));

    if (options.clear_back) {
        render_buffer.push(.{
            .pos = screen_pos,
            .size = dim,
            .color = .black,
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
    // Box-drawing layout for a size-N kaiju
    //   ┌─…─┐
    //   │   │
    //   │ K │
    //   │   │
    //   └─…─┘
    // Draw border and interior spaces at size=1
    var dy: i16 = 0;
    while (dy < kaiju.size) : (dy += 1) {
        var dx: i16 = 0;
        while (dx < kaiju.size) : (dx += 1) {
            const pos = kaiju.position.plus(.{ .x = dx, .y = dy });
            const is_top = dy == 0;
            const is_bottom = dy == kaiju.size - 1;
            const is_left = dx == 0;
            const is_right = dx == kaiju.size - 1;

            const glyph: u8 =
                if (is_top and is_left) 0xDA // ┌
                else if (is_top and is_right) 0xBF // ┐
                else if (is_bottom and is_left) 0xC0 // └
                else if (is_bottom and is_right) 0xD9 // ┘
                else if (is_top or is_bottom) 0xC4 // ─
                else if (is_left or is_right) 0xB3 // │
                else ' ';

            draw_world_glyph(pos.float(), glyph, .{ .clear_back = true, .color = .green });
        }
    }

    // Flush before K so it doesn't resize the border batch
    render_buffer.flush();
    const k_offset: f32 = 1.0 + @as(f32, @floatFromInt(kaiju.size - 2)) / 16.0;
    const k_pos = kaiju.render_position.plus(.{ .x = k_offset, .y = k_offset });
    draw_world_glyph(k_pos, 'K', .{ .clear_back = true, .color = .red, .size = @intCast(kaiju.size - 2) });
    render_buffer.flush();
}

fn render_unit(unit: *const main.Unit) void {
    switch (unit.tag) {
        .Player => {
            draw_world_glyph(
                unit.render_position,
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

const Color = RenderBuffer.Color;

pub fn bounding_box(positions: []const Vec2) Rect {
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

pub fn render_debug(val: anytype) void {
    const T = @TypeOf(val);
    const fields = @typeInfo(T).@"struct".fields;
    const x: f32 = 10;
    const size: f32 = 32;
    var y: f32 = 10;

    inline for (fields) |field| {
        const field_val = @field(val, field.name);
        const text = std.fmt.bufPrint(&printBuffer, "{s}: {any}", .{ field.name, field_val }) catch "...";
        splatString(x, y, text, .yellow, size);
        render_buffer.flush();
        y += size;
    }
}

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

        // Update camera: minimally shift to enclose player + reticles with buffer
        {
            const CAMERA_BUFFER: f32 = 10;
            const player = main.globals.player();
            const mount = player.mount();

            var points: [7]Vec2 = undefined;
            points[0] = player.render_position;
            var count: usize = 1;

            if (mount.tag != .Nil) {
                for (main.get_reticle_positions(mount)) |pos| {
                    points[count] = pos.float();
                    count += 1;
                }
            }

            const bbox = bounding_box(points[0..count]);

            const left = bbox.x - CAMERA_BUFFER;
            const top = bbox.y - CAMERA_BUFFER;
            const right = bbox.x + bbox.w + 1 + CAMERA_BUFFER;
            const bottom = bbox.y + bbox.h + 1 + CAMERA_BUFFER;

            if (left < camera.x) camera.x = left;
            if (top < camera.y) camera.y = top;
            if (right > camera.xmax()) camera.x = right - camera.w;
            if (bottom > camera.ymax()) camera.y = bottom - camera.h;

            // std.log.info("camera {}", .{camera});
        }
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
            const world_pos = IVec2{
                .x = x,
                .y = y,
            };
            const terrain = main.get_terrain_at(world_pos) orelse continue;
            const screen_pos = world_pos.float().minus(camera.pos()).scale(SPRITE_SCALE);
            const draw_sprite = Sprite{
                .pos = screen_pos,
                .color = .white,
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

    // Draw movement preview reticles
    blk: {
        const mount = main.globals.player().mount();
        if (mount.tag == .Nil) {
            break :blk;
        }
        for (main.get_reticle_positions(mount)) |pos| {
            const p0 = mount.position;
            const p1 = mount.position.plus(mount.orientation.ivec());
            if (pos.eq(p0)) {
                continue;
            }
            if (pos.eq(p1)) {
                continue;
            }
            draw_world_glyph(pos.float(), '%', .{
                .clear_back = true,
                .color = .yellow,
            });
        }
    }

    render_buffer.flush();

    const pl = main.globals.player();
    render_debug(.{
        .ppos = pl.position,
        .mount = pl.mounted_on,
        .motopos = main.globals.unit(2).position,
    });

    render_buffer.flush();
}
