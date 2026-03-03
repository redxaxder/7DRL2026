const std = @import("std");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const RenderBuffer = @import("render.zig");
const Sprite = RenderBuffer.Sprite;
const main = @import("main.zig");
const map = @import("map.zig");

const Vec2 = @import("core.zig").Vec2;
const IVec2 = @import("core.zig").IVec2;
const Rect = @import("core.zig").Rect;

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
var camera: Vec2 = .ZERO;
var camera_target: Vec2 = .ZERO;
const camera_w: f32 = 64;
const camera_h: f32 = 64;

pub export fn init(buffer_size: i32, screenW: f32, screenH: f32) i32 {
    const allocator = std.heap.wasm_allocator;
    resize(screenW, screenH);

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
    size: u8 = 1,
    color: Color = .white,
    bgcolor: ?Color = null,
    pixel_shift: bool = false,
};
pub fn draw_world_glyph(world_pos: Vec2, src_idx: u8, options: DrawOptions) void {
    const rcamera = Vec2{
        .x = std.math.round(camera.x * 8) / 8,
        .y = std.math.round(camera.y * 8) / 8,
    };
    const screen_pos = world_pos.minus(rcamera).scaled(SPRITE_SCALE);
    const dim = SPRITE_DIM.scaled(@floatFromInt(options.size));

    if (options.bgcolor) |bgcolor| {
        render_buffer.push(.{
            .pos = screen_pos,
            .size = dim,
            .color = bgcolor,
            .src_idx = 0xDB,
        });
    }

    const offset: f32 = if (options.pixel_shift)
        (SPRITE_SCALE / 16.0) * @as(f32, @floatFromInt(options.size))
    else
        0;

    render_buffer.push(.{
        .pos = screen_pos.plus(Vec2.ONE.scaled(offset)),
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
            const pos = kaiju.render_position.plus(.{
                .x = @floatFromInt(dx),
                .y = @floatFromInt(dy),
            });
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

            draw_world_glyph(pos, glyph, .{
                .bgcolor = .black,
                .color = .green,
            });
        }
    }

    // Flush before K so it doesn't resize the border batch
    render_buffer.flush();
    draw_world_glyph(kaiju.render_position.plus(Vec2.ONE), 'K', .{
        .bgcolor = .black,
        .color = .red,
        .size = kaiju.size - 2,
        .pixel_shift = true,
    });
    render_buffer.flush();
}

fn update_camera() void {
    const CAMERA_BUFFER: f32 = 10;
    const player = main.globals.player();

    var points: [7]Vec2 = undefined;
    points[0] = player.render_position;
    var count: usize = 1;

    if (main.get_reticle_positions()) |reticles| {
        for (reticles) |pos| {
            points[count] = pos.float();
            count += 1;
        }
    }

    const bbox = bounding_box(points[0..count]);

    const left = bbox.x - CAMERA_BUFFER;
    const top = bbox.y - CAMERA_BUFFER;
    const right = bbox.x + bbox.w + 1 + CAMERA_BUFFER;
    const bottom = bbox.y + bbox.h + 1 + CAMERA_BUFFER;

    var target: Vec2 = camera_target;
    if (left < target.x) target.x = left;
    if (top < target.y) target.y = top;
    if (right > target.x + camera_w) target.x = right - camera_w;
    if (bottom > target.y + camera_h) target.y = bottom - camera_h;

    animate_camera_to(target);
}
fn animate_camera_to(target: Vec2) void {
    const dist = camera.distance(target);
    _ = main.globals.animation_queue.force_add(
        .{ .duration = dist * 20 },
        main.animlib.linear_slide,
        .{ camera_target, target, &camera },
    ).lock_exclusive(main.animlib.lock_camera);

    // _ = (try main.globals.animation_queue.push(.EMPTY))
    //     .chain()
    // .lock_exclusive(main.animlib.lock_unit_id(main.PLAYER_ID))
    // .lock_exclusive(main.animlib.lock_unit_id(main.globals.player().mounted_on));
    camera_target = target;
}

fn render_unit(unit: *const main.Unit) void {
    switch (unit.tag) {
        .Player => {
            draw_world_glyph(
                unit.render_position,
                '@',
                .{ .bgcolor = .black },
            );
        },
        .Motorcycle => {
            const p0 = unit.render_position;
            const p1 = p0.plus(unit.render_orientation.ivec().float());
            draw_world_glyph(p0, 'o', .{ .bgcolor = .black });

            draw_world_glyph(p1, '%', .{ .bgcolor = .black });
        },
        .Kaiju => render_kaiju(unit),
        .PendingRubble => {
            draw_world_glyph(unit.render_position, 'X', .{
                .color = .yellow,
                .bgcolor = .black,
            });
        },
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

const IRect = @import("core.zig").IRect;

pub fn debug_draw_rect(rect: IRect, color: Color) void {
    var it = rect.iter();
    while (it.next()) |pos| {
        const is_top = pos.y == rect.y;
        const is_bottom = pos.y == rect.y + rect.h - 1;
        const is_left = pos.x == rect.x;
        const is_right = pos.x == rect.x + rect.w - 1;

        const glyph: u8 =
            if (is_top and is_left) 0xDA // ┌
            else if (is_top and is_right) 0xBF // ┐
            else if (is_bottom and is_left) 0xC0 // └
            else if (is_bottom and is_right) 0xD9 // ┘
            else if (is_top or is_bottom) 0xC4 // ─
            else if (is_left or is_right) 0xB3 // │
            else continue;

        draw_world_glyph(pos.float(), glyph, .{ .color = color });
    }
    render_buffer.flush();
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
        splatString(x, y, text, .magenta, size);
        render_buffer.flush();
        y += size;
    }
}

pub export fn frame(t: f64) void {
    const rawdt = t - prev_time;
    const dt: f32 = @floatCast(@min(20, rawdt));
    prev_time = t;

    audio.tick(dt);
    main.globals.animation_queue.tick(dt);
    keyboard.globals.update();
    mouse.globals.update();

    RenderBuffer.clear();

    if (keyboard.firstJustPressed()) |key| {
        main.logic_tick(key, prng.random());
        update_camera();
    }

    // Draw the terrain
    const imin = IVec2{
        .x = @intFromFloat(@floor(camera.x)),
        .y = @intFromFloat(@floor(camera.y)),
    };
    for (0..@intFromFloat(camera_w + 1)) |dx| {
        for (0..@intFromFloat(camera_h + 1)) |dy| {
            const x = imin.x + @as(i16, @intCast(dx));
            const y = imin.y + @as(i16, @intCast(dy));
            const world_pos = IVec2{
                .x = x,
                .y = y,
            };
            const payload = map.get_render_terrain_payload_at(world_pos);
            const terrain = payload.terrain;
            const color: Color = if (payload.bloody)
                .red
            else
                .white;
            draw_world_glyph(world_pos.float(), terrain.glyph(), .{ .color = color });
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
            // debug_draw_rect(u.get_rect(), .yellow);
        }
    }

    // Draw movement preview reticles
    const reticles: ?[5]IVec2 = main.get_reticle_positions();
    const reticle_blink = @mod(t, 1000) < 500;
    if (reticle_blink) {
        if (reticles) |highlight| {
            const mount = main.globals.player().mount();
            const p0 = mount.position;
            const p1 = mount.position.plus(mount.orientation.ivec());
            for (highlight) |pos| {
                if (pos.eq(p0)) {
                    continue;
                }
                if (pos.eq(p1)) {
                    continue;
                }
                draw_world_glyph(pos.float(), 0x09, .{
                    .color = .blue,
                });
            }
        }
    }

    render_buffer.flush();

    render_debug(.{
        .mode = main.ux.input_mode,
    });

    render_buffer.flush();
}
