const std = @import("std");
const lib = @import("_7DRL2026");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const RenderBuffer = @import("render.zig");
const Sprite = RenderBuffer.Sprite;

const Vec2 = @import("core.zig").Vec2;
const Rect = @import("core.zig").Rect;

var prev_time: f64 = 0;

const UnitType = enum {
    Nil,
    Player,
    Kaiju,
    Motorcycle,
    PendingExplosion,
    PendingRubble,
};

pub const IVec2 = struct {
    x: i16,
    y: i16,

    pub const zero = .{
        .x = 0,
        .y = 0,
    };
    pub const default = .{
        .x = -3200,
        .y = -3200,
    };

    pub fn float(self: IVec2) Vec2 {
        return .{ .x = @floatFromInt(self.x), .y = @floatFromInt(self.y) };
    }
};

const Dir4 = enum { Right, Up, Left, Down };

const Unit = struct {
    // Universal
    tag: UnitType = .Nil,
    position: IVec2 = .default,

    // Healthy
    hp: i64 = 0,
    max_hp: i64 = 0,

    // Kaiju
    size: u8 = 1,

    // Motorcycle
    orientation: Dir4 = .Right,
    speed: u8 = 0,
    //TODO: model

};

const MAP_SIZE = 2500;
const MAPDATA_LEN = MAP_SIZE * MAP_SIZE;

const Terrain = enum(u8) {
    Floor,
    Asphalt,
    Wall,
    _,

    pub fn glyph(self: @This()) u8 {
        switch (self) {
            .Asphalt => return 0xB0,
            .Floor => return '.',
            .Wall => return '#',
            else => return '?',
        }
    }
};

pub fn map_index(position: IVec2) ?usize {
    if (position.x < 0 or position.x >= MAP_SIZE) {
        return null;
    }
    if (position.y < 0 or position.y >= MAP_SIZE) {
        return null;
    }
    return (@as(usize, @intCast(position.y)) * MAP_SIZE) + @as(usize, @intCast(position.x));
}

pub fn set_terrain_at(position: IVec2, terrain: Terrain) void {
    const ix = map_index(position) orelse return;
    globals.mapdata[ix] = terrain;
}

pub fn get_terrain_at(position: IVec2) ?Terrain {
    const ix = map_index(position) orelse return null;
    return globals.mapdata[ix];
}

const globals = struct {
    var units: [2000]Unit = .{.Nil} ** 2000;
    var mapdata: [MAPDATA_LEN]Terrain = .{.Floor} ** MAPDATA_LEN;
};

pub fn init() !void {
    // TODO
}

pub fn logic_tick(key: keyboard.Code, rng: std.Random) void {
    _ = key;
    _ = rng;
    //TODO
}
