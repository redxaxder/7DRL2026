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
fn render_kaiju(unit: *const main.Unit) void {
    const render_at = unit.position.float();
    const screen_space = render_at.minus(camera.pos());

    render_buffer.push(.{
        .pos = screen_space.scale(SPRITE_SCALE),
        .size = SPRITE_DIM,
        .color = BLACK,
        .src_idx = 0xDB,
    });
    // this will create the top boundary of the kaiju,
    render_buffer.push(.{
        .pos = screen_space.scale(SPRITE_SCALE),
        .size = SPRITE_DIM,
        .color = WHITE,
        .src_idx = '|',
    });
    render_buffer.push(.{
        .pos = screen_space.scale(SPRITE_SCALE),
        .size = .{ .x = SPRITE_SCALE + 15, .y = SPRITE_SCALE },
        .color = WHITE,
        .src_idx = '-',
    });
    render_buffer.push(.{
        .pos = screen_space.scale(SPRITE_SCALE),
        .size = .{ .x = SPRITE_SCALE + 30, .y = SPRITE_SCALE },
        .color = WHITE,
        .src_idx = '|',
    });
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

// TODO: fill out this list. convert into enum.
const WHITE = 0;
const YELLOW = 2;
const BLACK = 13;

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
            points[0] = player.position.float();
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

            std.log.info("camera {}", .{camera});
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
                .color = YELLOW,
            });
        }
    }

    render_buffer.flush();

    splatString(10, 10, "hello world", 0, 32);

    render_buffer.flush();
}
