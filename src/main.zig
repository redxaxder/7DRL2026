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

pub const UnitType = enum {
    Nil,
    Player,
    Kaiju,
    Motorcycle,
    PendingExplosion,
    PendingRubble,
};

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
};

pub const Dir4 = enum {
    Right,
    Up,
    Left,
    Down,
    pub fn ivec(self: Dir4) IVec2 {
        return switch (self) {
            .Right => IVec2{ .x = 1 },
            .Left => IVec2{ .x = -1 },
            .Down => IVec2{ .y = 1 },
            .Up => IVec2{ .y = -1 },
        };
    }

    pub fn turn(self: Dir4, rd: RelativeDir) Dir4 {
        const uself: u8 = @intFromEnum(self);
        const urd: u8 = @intFromEnum(rd);
        const combined: u2 = @truncate(uself + urd);
        return @enumFromInt(combined);
    }
};
pub const RelativeDir = enum {
    Forward,
    Left,
    Reverse,
    Right,

    // This new direction is ____ compared to the starting dir
    pub fn from(new: Dir4, root: Dir4) RelativeDir {
        const inew: i8 = @intCast(@intFromEnum(new));
        const iroot: i8 = @intCast(@intFromEnum(root));
        return switch (inew - iroot) {
            -3 => .Left,
            -2 => .Reverse,
            -1 => .Right,
            0 => .Forward,
            1 => .Left,
            2 => .Reverse,
            3 => .Right,
            else => unreachable,
        };
    }
};

pub const UnitId = u16;
pub const Unit = struct {
    // Universal
    tag: UnitType = .Nil,
    position: IVec2 = IVec2.default,
    // TODO: add render_position Vec2

    // Healthy
    hp: i64 = 0,
    max_hp: i64 = 0,

    // Kaiju
    size: u8 = 1,

    // Motorcycle
    orientation: Dir4 = .Right,
    speed: u8 = 0,
    //TODO: model

    mounted_on: UnitId = 0,

    pub const default: Unit = .{};

    pub fn mount(self: *const @This()) *Unit {
        return globals.unit(self.mounted_on);
    }
};

const MAP_SIZE = 2500;
const MAPDATA_LEN = MAP_SIZE * MAP_SIZE;

pub const Terrain = enum(u8) {
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

pub const globals = struct {
    pub var units: [2000]Unit = .{Unit.default} ** 2000;
    pub var mapdata: [MAPDATA_LEN]Terrain = .{.Floor} ** MAPDATA_LEN;

    pub fn unit(u: UnitId) *Unit {
        return &units[@intCast(u)];
    }

    pub fn player() *Unit {
        return globals.unit(PLAYER_ID);
    }

    pub fn free_unit_id() ?UnitId {
        for (units[1..], 1..) |u, i| {
            if (u.tag == .Nil) {
                return @intCast(i);
            }
        }
        return null;
    }
};

const PLAYER_ID: UnitId = 1;
pub fn mapgen() void {
    const block_size: IVec2 = .{ .x = 30, .y = 50 };
    const street_size: i16 = 3;
    for (0..(MAP_SIZE / block_size.x)) |block_x| {
        for (0..(MAP_SIZE / block_size.y)) |block_y| {
            for (0..block_size.x) |x| {
                for (0..block_size.y) |y| {
                    // assume street width is 3 tiles
                    // streets
                    const pos: IVec2 = .{ .x = @as(i16, @intCast((block_x * block_size.x) + x)), .y = @as(i16, @intCast((block_y * block_size.y) + y)) };
                    if (y < street_size or x < street_size or x >= block_size.x - street_size or y >= block_size.y - street_size) {
                        if (pos.x < 20 and pos.y < 20) {
                            std.log.info("x {} y {}", .{ pos.x, pos.y });
                        }
                        set_terrain_at(pos, .Asphalt);
                    }
                }
            }
        }
    }
    _ = 5;
}

pub fn init() !void {
    globals.player().* = Unit{
        .tag = .Player,
        .position = IVec2{ .x = 5, .y = 5 },
    };
    const moto_id = globals.free_unit_id() orelse @panic("how did we run out so fast");
    globals.unit(moto_id).* = Unit{
        .tag = .Motorcycle,
        .position = globals.player().position,
        .orientation = .Right,
    };
    globals.player().mounted_on = moto_id;
    const kaiu_id = globals.free_unit_id() orelse @panic("how did we run out so fast");
    globals.unit(kaiu_id).* = Unit{
        .tag = .Kaiju,
        .position = IVec2{ .x = 6, .y = 6 },
        .size = 1,
    };
    mapgen();
}

pub fn logic_tick(key: keyboard.Code, rng: std.Random) void {
    _ = rng;

    var move_dir: ?Dir4 = null;
    switch (key) {
        .KeyW => {
            move_dir = .Up;
        },
        .ArrowUp => {
            move_dir = .Up;
        },
        .KeyA => {
            move_dir = .Left;
        },
        .ArrowLeft => {
            move_dir = .Left;
        },
        .KeyS => {
            move_dir = .Down;
        },
        .ArrowDown => {
            move_dir = .Down;
        },
        .KeyD => {
            move_dir = .Right;
        },
        .ArrowRight => {
            move_dir = .Right;
        },
        else => {},
    }
    if (move_dir) |d| {
        const player = globals.player();
        const pmount = player.mount();
        if (pmount.tag == .Motorcycle) {
            // mounted movement
            const target = resolve_motorcycle_movement(
                pmount.position,
                pmount.orientation,
                pmount.speed,
                d,
            );
            pmount.*.position = target.position;
            pmount.*.orientation = target.orientation;
            pmount.*.speed = target.speed;
            player.*.position = pmount.position;
        } else {
            // unmounted movement
            const dv = d.ivec();
            player.*.position.x += dv.x;
            player.*.position.y += dv.y;
        }
    }

    std.log.info("player at {}", .{globals.units[PLAYER_ID].position});

    //TODO
}

pub const MotoResult = struct {
    midpoint: IVec2,
    position: IVec2,
    orientation: Dir4,
    speed: u8,
};
pub fn resolve_motorcycle_movement(
    position: IVec2,
    orientation: Dir4,
    speed: u8,
    // TODO: slight movement
    input: ?Dir4,
) MotoResult {
    var it = MotoResult{
        .position = position,
        .midpoint = position,
        .speed = speed,
        .orientation = orientation,
    };

    const change = input orelse {
        const drift = orientation.ivec().scaled(@intCast(speed));
        it.position = it.position.plus(drift);
        return it;
    };

    const slide_dist = @max(speed / 2, 1);

    switch (RelativeDir.from(change, orientation)) {
        .Forward => { // accelerate!
            it.speed += 1;
            const drift = orientation.ivec().scaled(@intCast(it.speed));
            it.position = it.position.plus(drift);
        },
        .Left, .Right => { // turn!
            const turned_speed = blk: {
                if (speed > slide_dist) {
                    break :blk speed - slide_dist;
                } else {
                    break :blk 1;
                }
            };
            const pre_drift = orientation.ivec().scaled(@intCast(slide_dist));
            it.midpoint = it.position.plus(pre_drift);
            const post_drift = change.ivec().scaled(@intCast(turned_speed));
            it.position = it.midpoint.plus(post_drift);
            it.speed = turned_speed;
            it.orientation = change;
        },
        .Reverse => { // brake!

            const drift = orientation.ivec().scaled(@intCast(slide_dist));
            it.position = it.position.plus(drift);
            if (speed == 0) {
                it.orientation = change;
            }
            it.speed = 0;
            // if speed is high enough, brake via akira slide
            if (slide_dist >= 2) {
                it.orientation = orientation.turn(RelativeDir.Right);
                it.position = it.position.minus(it.orientation.ivec());
            }
        },
    }
    return it;
}

pub fn get_reticle_positions(unit: *const Unit) [5]IVec2 {
    var result: [5]IVec2 = undefined;
    for (std.enums.values(Dir4), 0..) |d, i| {
        const projection = resolve_motorcycle_movement(
            unit.position,
            unit.orientation,
            unit.speed,
            d,
        );
        const ppos = projection.position;
        const handlepos = ppos.plus(projection.orientation.ivec());
        result[i] = handlepos;
    }

    const projection = resolve_motorcycle_movement(
        unit.position,
        unit.orientation,
        unit.speed,
        null,
    );
    const ppos = projection.position;
    const handlepos = ppos.plus(projection.orientation.ivec());
    result[4] = handlepos;
    return result;
}
