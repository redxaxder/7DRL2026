const std = @import("std");
const core = @import("core.zig");
const IVec2 = core.IVec2;

const DirFlags = packed struct(u4) {
    north: bool = false,
    south: bool = false,
    east: bool = false,
    west: bool = false,
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

fn mapgen_city_block(zone_size: IVec2, zone: IVec2, block_size: IVec2, block: IVec2, block_offset: IVec2, street_size: i16, rng: std.Random, map: []Terrain) void {
    const doors: DirFlags = @bitCast(rng.int(u4));
    for (0..@as(usize, @intCast(block_size.x))) |xx| {
        for (0..@as(usize, @intCast(block_size.y))) |yy| {
            const x: i16 = @as(i16, @intCast(xx));
            const y: i16 = @as(i16, @intCast(yy));
            // streets
            const local_pos: IVec2 = .{
                .x = x,
                .y = y,
            };
            const world_x: i16 = (zone.x * zone_size.x) + (block.x * block_size.x) - block_offset.x + x;
            const world_y: i16 = (zone.y * zone_size.y) + (block.y * block_size.y) - block_offset.y + y;
            const world_pos: IVec2 = .{ .x = world_x, .y = world_y };
            var terrain: Terrain = .Floor;
            if (is_street(local_pos, street_size, block_size)) {
                terrain = .Asphalt;
            }
            // buildings
            if (is_wall_x(local_pos, street_size, block_size) or is_wall_y(local_pos, street_size, block_size)) {
                terrain = .Wall;
            }
            // doors
            if (is_door(local_pos, street_size, block_size, doors)) {
                terrain = .Door;
            }
            set_terrain_at(world_pos, terrain, map);
        }
    }
}

fn mapgen_blocks(zone: IVec2, zone_size: IVec2, block_size: IVec2, street_size: i16, rng: std.Random, block_offset: IVec2, map: []Terrain) void {
    // iterate over blocks
    for (0..@as(usize, @intCast(@divFloor(zone_size.x, block_size.x)))) |bx| {
        for (0..@as(usize, @intCast(@divFloor(zone_size.y, block_size.y)))) |by| {
            const block_x: i16 = @as(i16, @intCast(bx));
            const block_y: i16 = @as(i16, @intCast(by));
            // the body has been split into its own function so we can mess with different zone stuff later
            mapgen_city_block(zone, zone_size, block_size, .{ .x = block_x, .y = block_y }, block_offset, street_size, rng, map);
        }
    }
}

pub fn mapgen(rng: std.Random, map: []Terrain) void {
    // basic mapgen strategy:
    // the map is chunked into zones, each zone is chunked into blocks, each block is made up of tiles
    const num_zones_x: i16 = rng.intRangeAtMost(i16, 3, 8);
    const num_zones_y: i16 = rng.intRangeAtMost(i16, 3, 8);
    const zone_size: IVec2 = .{ .x = @divFloor(MAP_SIZE, num_zones_x), .y = @divFloor(MAP_SIZE, num_zones_y) };

    // for each zone, we track block offsets, because a zone with width z and block width b will have z % b leftover space
    // we use these block offsets so that the zones mesh with no gap
    // TODO probably a big gap on the far edges of the map
    var block_offset_x: i16 = 0;
    for (0..@as(usize, @intCast(num_zones_x))) |zx| {
        const block_size_x = rng.intRangeAtMost(i16, 20, 50);
        var block_offset_y: i16 = 0;
        for (0..@as(usize, @intCast(num_zones_y))) |zy| {
            const block_size: IVec2 = .{ .x = block_size_x, .y = rng.intRangeAtMost(i16, 20, 50) };
            const street_size: i16 = rng.intRangeAtMost(i16, 1, 5);
            const zone: IVec2 = .{ .x = @as(i16, @intCast(zx)), .y = @as(i16, @intCast(zy)) };
            const block_offset: IVec2 = .{ .x = block_offset_x, .y = block_offset_y };
            mapgen_blocks(zone, zone_size, block_size, street_size, rng, block_offset, map);
            block_offset_y += @rem(zone_size.y, block_size.y);
        }
        block_offset_x += @rem(zone_size.x, block_size_x);
    }
}

pub const MAP_SIZE = 2500;
pub const MAPDATA_LEN = MAP_SIZE * MAP_SIZE;

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

    pub fn passable(self: @This()) bool {
        return switch (self) {
            .Wall, .Door => false,
            else => true,
        };
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

fn set_terrain_at(position: IVec2, terrain: Terrain, map: []Terrain) void {
    const ix = map_index(position) orelse return;
    map[ix] = terrain;
}

fn get_terrain_at(position: IVec2, map: []Terrain) ?Terrain {
    const ix = map_index(position) orelse return null;
    return map[ix];
}
