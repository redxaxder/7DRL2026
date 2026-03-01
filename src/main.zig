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

    pub fn eq(self: IVec2, rhs: IVec2) bool {
        return self.x == rhs.x and self.y == rhs.y;
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
    Door,
    _,

    pub fn glyph(self: @This()) u8 {
        switch (self) {
            .Asphalt => return 0xB0,
            .Floor => return '.',
            .Wall => return '#',
            .Door => return '+',
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

fn is_street(pos: IVec2, street_size: i16, block_size: IVec2) bool {
    return pos.y < street_size or pos.x < street_size or pos.x >= block_size.x - street_size or pos.y >= block_size.y - street_size;
}

fn is_wall_y(pos: IVec2, street_size: i16, block_size: IVec2) bool {
    return (pos.y == street_size or pos.y == block_size.y - street_size - 1) and !is_street(pos, street_size, block_size);
}

fn is_wall_x(pos: IVec2, street_size: i16, block_size: IVec2) bool {
    return (pos.x == street_size or pos.x == block_size.x - street_size - 1) and !is_street(pos, street_size, block_size);
}

const DirFlags = packed struct(u4) {
    north: bool = false,
    south: bool = false,
    east: bool = false,
    west: bool = false,
};

fn is_door(pos: IVec2, street_size: i16, block_size: IVec2, doors: DirFlags) bool {
    if (doors.east) {
        //right
        if (is_wall_x(pos, street_size, block_size) and @abs(pos.y - @divFloor(block_size.y, 2)) < 2 and pos.x == block_size.x - street_size - 1) {
            return true;
        }
    }
    if (doors.north) {
        //top
        if (is_wall_y(pos, street_size, block_size) and @abs(pos.x - @divFloor(block_size.x, 2)) < 2 and pos.y == street_size) {
            return true;
        }
    }
    if (doors.west) {
        //left
        if (is_wall_x(pos, street_size, block_size) and @abs(pos.y - @divFloor(block_size.y, 2)) < 2 and pos.x == street_size) {
            return true;
        }
    }
    if (doors.south) {
        //bottom
        if (is_wall_y(pos, street_size, block_size) and @abs(pos.x - @divFloor(block_size.x, 2)) < 2 and pos.y == block_size.y - street_size - 1) {
            return true;
        }
    }
    return false;
}

const PLAYER_ID: UnitId = 1;

fn mapgen_blocks(zone: IVec2, zone_size: IVec2, block_size: IVec2, street_size: i16, rng: std.Random) void {
    // iterate over blocks
    for (0..@as(usize, @intCast(@divFloor(zone_size.x, block_size.x)))) |bx| {
        for (0..@as(usize, @intCast(@divFloor(zone_size.y, block_size.y)))) |by| {
            const doors: DirFlags = @bitCast(rng.int(u4));
            for (0..@as(usize, @intCast(block_size.x))) |xx| {
                for (0..@as(usize, @intCast(block_size.y))) |yy| {
                    const block_x: i16 = @as(i16, @intCast(bx));
                    const block_y: i16 = @as(i16, @intCast(by));
                    const x: i16 = @as(i16, @intCast(xx));
                    const y: i16 = @as(i16, @intCast(yy));
                    // streets
                    const local_pos: IVec2 = .{
                        .x = x,
                        .y = y,
                    };
                    const world_pos: IVec2 = .{ .x = (zone.x * zone_size.x) + (block_x * block_size.x) + x, .y = (zone.y * zone_size.y) + (block_y * block_size.y) + y };
                    if (is_street(local_pos, street_size, block_size)) {
                        set_terrain_at(world_pos, .Asphalt);
                    }
                    // buildings
                    if (is_wall_x(local_pos, street_size, block_size) or is_wall_y(local_pos, street_size, block_size)) {
                        set_terrain_at(world_pos, .Wall);
                    }
                    // doors
                    if (is_door(local_pos, street_size, block_size, doors)) {
                        set_terrain_at(world_pos, .Door);
                    }
                }
            }
        }
    }
}

pub fn mapgen(rng: std.Random) void {
    const num_zones_x: i16 = rng.intRangeAtMost(i16, 3, 8);
    const num_zones_y: i16 = rng.intRangeAtMost(i16, 3, 8);
    const zone_size: IVec2 = .{ .x = @divFloor(MAP_SIZE, num_zones_x), .y = @divFloor(MAP_SIZE, num_zones_y) };
    for (0..@as(usize, @intCast(num_zones_x))) |zx| {
        for (0..@as(usize, @intCast(num_zones_y))) |zy| {
            const block_size: IVec2 = .{ .x = rng.intRangeAtMost(i16, 20, 50), .y = rng.intRangeAtMost(i16, 20, 50) };
            const street_size: i16 = rng.intRangeAtMost(i16, 1, 5);
            const zone: IVec2 = .{ .x = @as(i16, @intCast(zx)), .y = @as(i16, @intCast(zy)) };
            mapgen_blocks(zone, zone_size, block_size, street_size, rng);
        }
    }
}

pub fn init(rng: std.Random) !void {
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
    const kaiju_id = globals.free_unit_id() orelse @panic("how did we run out so fast");
    globals.unit(kaiju_id).* = Unit{
        .tag = .Kaiju,
        .position = IVec2{ .x = 6, .y = 6 },
        .size = 1,
    };

    const big_kaiju_id = globals.free_unit_id() orelse @panic("how did we run out so fast");
    globals.unit(big_kaiju_id).* = Unit{
        .tag = .Kaiju,
        .position = IVec2{ .x = 9, .y = 18 },
        .size = 2,
    };
    mapgen(rng);
}

pub fn logic_tick(key: keyboard.Code, rng: std.Random) void {
    _ = rng;

    var move_dir: ?Dir4 = null;
    switch (key) {
        .KeyW, .ArrowUp => {
            move_dir = .Up;
        },
        .KeyA, .ArrowLeft => {
            move_dir = .Left;
        },
        .KeyS, .ArrowDown => {
            move_dir = .Down;
        },
        .KeyD, .ArrowRight => {
            move_dir = .Right;
        },
        else => {},
    }
    if (move_dir) |d| {
        const player = globals.player();
        const pmount = player.mount();
        if (pmount.tag == .Motorcycle) {
            // mounted movement
            const target = resolve_motorcycle_movement(pmount, .{ .dir = d });
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

pub const MAX_SPEED = 20;

pub const MotoMove = struct {
    dir: ?Dir4 = null,
    shift: bool = false,
};
pub const MotoResult = struct {
    midpoint: IVec2,
    position: IVec2,
    orientation: Dir4,
    speed: u8,
};

pub fn resolve_motorcycle_movement(
    moto: *const Unit,
    move: MotoMove,
) MotoResult {
    var it = MotoResult{
        .position = moto.position,
        .midpoint = moto.position,
        .speed = moto.speed,
        .orientation = moto.orientation,
    };

    const change = move.dir orelse {
        const drift = moto.orientation.ivec().scaled(@intCast(moto.speed));
        it.position = it.position.plus(drift);
        return it;
    };

    const slide_dist = @max(moto.speed / 2, 1);

    switch (RelativeDir.from(change, moto.orientation)) {
        .Forward => { // accelerate!
            it.speed = @min(it.speed + 1, MAX_SPEED);
            const drift = moto.orientation.ivec().scaled(@intCast(it.speed));
            it.position = it.position.plus(drift);
        },
        .Left, .Right => { // turn!
            const turned_speed = blk: {
                if (moto.speed > slide_dist) {
                    break :blk moto.speed - slide_dist;
                } else {
                    break :blk 0;
                }
            };
            const pre_drift = moto.orientation.ivec().scaled(@intCast(slide_dist));
            it.midpoint = it.position.plus(pre_drift);
            const post_drift = change.ivec().scaled(@intCast(turned_speed));
            it.position = it.midpoint.plus(post_drift);
            it.speed = @max(1, turned_speed);
            it.orientation = change;
        },
        .Reverse => { // brake!

            const drift = moto.orientation.ivec().scaled(@intCast(slide_dist));
            it.position = it.position.plus(drift);
            if (moto.speed == 0) {
                it.orientation = change;
            }
            it.speed = 0;
            // if speed is high enough, brake via akira slide
            if (slide_dist >= 2) {
                it.orientation = moto.orientation.turn(RelativeDir.Right);
                it.position = it.position.minus(it.orientation.ivec());
            }
        },
    }
    return it;
}

pub fn get_reticle_positions(unit: *const Unit) [5]IVec2 {
    var result: [5]IVec2 = undefined;
    for (std.enums.values(Dir4), 0..) |d, i| {
        const projection = resolve_motorcycle_movement(unit, .{ .dir = d });
        const ppos = projection.position;
        const handlepos = ppos.plus(projection.orientation.ivec());
        result[i] = handlepos;
    }
    const projection = resolve_motorcycle_movement(unit, .{});
    const ppos = projection.position;
    const handlepos = ppos.plus(projection.orientation.ivec());
    result[4] = handlepos;
    return result;
}
