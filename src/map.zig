const std = @import("std");
const core = @import("core.zig");
const IVec2 = core.IVec2;
const IRect = core.IRect;
const Interval = core.Interval;

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

fn mapgen_city_block(zone_size: IVec2, zone: IVec2, block_size: IVec2, block: IVec2, block_offset: IVec2, street_size: i16, rng: std.Random) void {
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
            var terrain: Terrain = .floor;
            if (is_street(local_pos, street_size, block_size)) {
                terrain = .asphalt;
            }
            // buildings
            if (is_wall_x(local_pos, street_size, block_size) or is_wall_y(local_pos, street_size, block_size)) {
                terrain = .wall;
            }
            // doors
            if (is_door(local_pos, street_size, block_size, doors)) {
                terrain = .door;
            }
            set_terrain_at(world_pos, terrain);
        }
    }
}

fn mapgen_blocks(zone: IVec2, zone_size: IVec2, block_size: IVec2, street_size: i16, rng: std.Random, block_offset: IVec2) void {
    // iterate over blocks
    for (0..@as(usize, @intCast(@divFloor(zone_size.x, block_size.x)))) |bx| {
        for (0..@as(usize, @intCast(@divFloor(zone_size.y, block_size.y)))) |by| {
            const block_x: i16 = @as(i16, @intCast(bx));
            const block_y: i16 = @as(i16, @intCast(by));
            // the body has been split into its own function so we can mess with different zone stuff later
            mapgen_city_block(zone, zone_size, block_size, .{ .x = block_x, .y = block_y }, block_offset, street_size, rng);
        }
    }
}

const Zone = enum {
    Nil,
    Residential,
    Commercial,
    Industrial,
};

fn fill_terrain(rect: IRect, terrain: Terrain) void {
    var iter = rect.iter();
    while (iter.next()) |pos| {
        set_terrain_at(pos, terrain);
    }
}

pub fn new_mapgen(rect: IRect, zone: Zone, rng: std.Random) void {
    // scheme:
    // recursively -
    //   draw some number of roads, which divide up the given rect
    //   the areas between the roads into new rects. Recursively
    //   call new mapgen on those rects, with some thresholding logic.
    //
    // Zones are decided at threshold area 20k and are nil before that.
    //
    // Road width ranges from 6 lanes (3 each direction) to 2 lanes in
    // pre-zone gen and 4 lanes (2 each direction) to 1 lane in post-zone gen.
    // Commercial and industrial are biased to bigger roads.
    // A road is
    // 1 tile sidewalk, 3 * lanes/2 tiles lane (lanes are 3 wide because cars are 3x3), 1 tile painted, then mirrored on the other side
    //
    // Once the rects are small enough, stop subdividing and do individual blocks
    // "small enough" being based on Zone.
    // TODO vary destruction level based on where mama kaiju spawns

    // blocks
    const area: u32 = rect.x * rect.y;
    const block_threshold: u32 = switch (zone) {
        .Residential => 200,
        .Commercial => 500,
        .Industrial => 1000,
        else => 0,
    };
    if (area < block_threshold) {
        // TODO block-level logic
    }

    // construct roads and determine subblocks
    var block_widths: [4]?Interval = .{null} ** 4;
    const block_heights: [4]?Interval = .{null} ** 4;
    var num_blocks: u8 = 0;
    const num_roads_vert: u8 = rng.intRangeAtMost(u8, 1, 3);
    // const num_roads_horiz: u8 = rng.intRangeAtMost(u8, 1, 3);
    var road_cursor: u16 = 0;
    for (0..num_roads_vert) |i| {
        const num_lanes: u8 = switch (zone) {
            .Nil, .Industrial => rng.intRangeAtMost(u8, 1, 3) * 2,
            .Residential => rng.intRangeAtMost(u8, 1, 2),
            .Commercial => rng.intRangeAtMost(u8, 1, 2) * 2,
        };
        const total_width: u8 = if (num_lanes == 1) 5 else 3 + 3 * num_lanes;
        if (road_cursor > rect.w - total_width) {
            // we're out of room for roads, just give up
            break;
        }
        const build_road_at: i16 = rect.x + rng.intRangeAtMost(i16, road_cursor, rect.w - total_width);
        block_widths[i] = .{ .origin = road_cursor, .len = build_road_at - road_cursor - 1 };
        defer road_cursor += build_road_at + total_width * 3;
        defer num_blocks += 1;

        //actually build the road
        const y_pos: i16 = rect.y;
        const height: i16 = rect.y + rect.y;
        var construction_cursor: i16 = 0;
        const left_sidewalk_rect: IRect = .{ .x = build_road_at + construction_cursor, .y = y_pos, .w = 1, .h = height };
        fill_terrain(left_sidewalk_rect, .Sidewalk);
        construction_cursor += 1;
        if (num_lanes == 1) {
            const lane_rect: IRect = .{ .x = build_road_at + construction_cursor, .y = y_pos, .w = 3, .h = height };
            fill_terrain(lane_rect, .Asphalt);
            construction_cursor += 1;
        } else {
            const lanes_width = 3 * @divExact(num_lanes, 2);
            const left_lanes_rect: IRect = .{ .x = build_road_at + construction_cursor, .y = y_pos, .w = lanes_width, .h = height };
            fill_terrain(left_lanes_rect, .Asphalt);
            const stripe: IRect = .{ .x = build_road_at + construction_cursor, .y = y_pos, .w = 1, .h = height };
            fill_terrain(stripe, .RoadPaint);
            construction_cursor += 1;
            const right_lanes_rect: IRect = .{ .x = build_road_at + construction_cursor, .y = y_pos, .w = lanes_width, .h = height };
            fill_terrain(right_lanes_rect, .Asphalt);
            construction_cursor += lanes_width;
        }
        const right_sidewalk_rect: IRect = .{ .x = build_road_at + construction_cursor, .y = y_pos, .w = 1, .h = height };
        fill_terrain(right_sidewalk_rect, .Sidewalk);
    }

    // get blocks and recurse
    const zone_threshold: u32 = 20000;
    for (0..num_blocks) |i| {
        if (block_widths[i]) |w| {
            if (block_heights[i]) |h| {
                const new_rect: IRect = .{ .x = w.origin, .y = h.origin, .w = w.len, .h = h.len };
                const new_zone: Zone = if (new_rect.w * new_rect.h < zone_threshold) rng.enumValue(Zone) else zone;
                new_mapgen(new_rect, new_zone);
            } else {
                break;
            }
        } else {
            break;
        }
    }
}

pub fn mapgen(rng: std.Random) void {
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
            mapgen_blocks(zone, zone_size, block_size, street_size, rng, block_offset);
            block_offset_y += @rem(zone_size.y, block_size.y);
        }
        block_offset_x += @rem(zone_size.x, block_size_x);
    }
    // rubble
    const destruction_factor: f32 = 0.001; // how likely an individual tile is to be the epicenter of some destruction
    for (0..MAP_SIZE - 1) |x| {
        for (0..MAP_SIZE - 1) |y| {
            if (rng.float(f32) < destruction_factor) {
                const terrain: Terrain = if (rng.float(f32) < 0.5) .rubble else .debris;
                switch (terrain) {
                    .rubble => {
                        const rx: i16 = rng.intRangeAtMost(i16, 4, 10);
                        const ry: i16 = rng.intRangeAtMost(i16, 4, 10);
                        rubblum(.{ .x = rx, .y = ry }, .{ .x = @as(i16, @intCast(x)), .y = @as(i16, @intCast(y)) }, terrain, 0.1, rng) catch continue;
                    },
                    .debris => {
                        const rx: i16 = rng.intRangeAtMost(i16, 4, 10);
                        const ry: i16 = rng.intRangeAtMost(i16, 4, 10);
                        rubblum(.{ .x = rx, .y = ry }, .{ .x = @as(i16, @intCast(x)), .y = @as(i16, @intCast(y)) }, terrain, 0.01, rng) catch continue;
                    },
                    else => {
                        unreachable;
                    },
                }
            }
        }
    }
    // trinkets — rare items scattered on passable tiles
    const trinket_factor: f32 = 0.002;
    for (0..MAP_SIZE - 1) |x| {
        for (0..MAP_SIZE - 1) |y| {
            const pos: IVec2 = .{ .x = @as(i16, @intCast(x)), .y = @as(i16, @intCast(y)) };
            if (rng.float(f32) < trinket_factor) {
                const existing = get_terrain_at(pos);
                if (existing.passable()) {
                    set_terrain_at(pos, .trinket);
                }
            }
        }
    }
}

pub const ENABLE_MASKING = true;
pub const MAP_SIZE = 2500;
pub const MAPDATA_LEN = MAP_SIZE * MAP_SIZE;
pub const BOUNDS: core.IRect = .{ .x = 0, .y = 0, .w = MAP_SIZE, .h = MAP_SIZE };

pub var mapdata: [MAPDATA_LEN]FullTerrain = .{FullTerrain.from(.floor)} ** MAPDATA_LEN;

pub const FullTerrain = packed struct(u8) {
    terrain: Terrain,
    seen: bool = false,
    bloody: bool = false,
    is_masked: bool = false,

    pub const Payload = packed struct(u7) {
        seen: bool = false,
        bloody: bool = false,
        terrain: Terrain,
    };

    pub fn from(t: Terrain) FullTerrain {
        return .{ .terrain = t };
    }

    pub fn mask_index(self: FullTerrain) u7 {
        return @bitCast(Payload{ .seen = self.seen, .bloody = self.bloody, .terrain = self.terrain });
    }

    pub fn from_mask_index(index: u7) FullTerrain {
        const payload: Payload = @bitCast(index);
        return .{ .seen = payload.seen, .bloody = payload.bloody, .is_masked = true, .terrain = payload.terrain };
    }
};

pub const Terrain = enum(u5) {
    floor,
    asphalt,
    wall,
    door,
    rubble,
    debris,
    trinket,
    viscera,
    money,
    void_,
    _,

    pub fn name(self: Terrain) []const u8 {
        return std.enums.tagName(Terrain, self) orelse "";
    }

    pub fn glyph(self: Terrain) u8 {
        switch (self) {
            .asphalt => return 0,
            // .asphalt => return '\\',
            .floor => return '.',
            .wall => return '#',
            .door => return '+',
            .rubble => return '&',
            .viscera => return 0x9C,
            .money => return 0x9D,
            .debris => return ';',
            .trinket => return 0xF0,
            else => return '/',
        }
    }

    pub fn passable(self: Terrain) bool {
        return switch (self) {
            .wall, .rubble, .void_ => false,
            else => true,
        };
    }

    pub fn halting(self: Terrain) bool {
        return switch (self) {
            .door, .viscera => true,
            else => false,
        };
    }

    pub fn kaiju_passable(self: Terrain) bool {
        return switch (self) {
            .wall, .void_ => false,
            else => true,
        };
    }

    pub fn smashable(self: Terrain) bool {
        return switch (self) {
            .wall, .door, .rubble, .viscera => true,
            else => false,
        };
    }

    pub fn blocks_fov(self: Terrain) bool {
        return switch (self) {
            .void_, .wall, .door => true,
            else => false,
        };
    }

    pub fn blocks_shot(self: Terrain) bool {
        return switch (self) {
            .wall, .door, .void_ => true,
            else => false,
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

pub fn mark_seen(pos: IVec2) void {
    var payload = get_terrain_payload_at(pos);
    if (!payload.seen) {
        payload.seen = true;
        set_terrain_payload_at(pos, payload);
    }
}

pub fn mark_bloody(pos: IVec2) void {
    var payload = get_terrain_payload_at(pos);
    if (!payload.bloody) {
        payload.bloody = true;
        set_terrain_payload_at(pos, payload);
    }
}

pub fn get_terrain_payload_at(position: IVec2) FullTerrain.Payload {
    const ix = map_index(position) orelse return .{ .terrain = .void_ };
    const tile = mapdata[ix];
    if (tile.is_masked) {
        return @bitCast(get_mask(position).sim[tile.mask_index()].mask_index());
    }
    return @bitCast(tile.mask_index());
}

pub fn get_render_terrain_payload_at(position: IVec2) FullTerrain.Payload {
    const ix = map_index(position) orelse return .{ .terrain = .void_ };
    const tile = mapdata[ix];
    if (tile.is_masked) {
        return @bitCast(get_mask(position).render[tile.mask_index()].mask_index());
    }
    return @bitCast(tile.mask_index());
}

pub fn set_terrain_payload_at(position: IVec2, payload: FullTerrain.Payload) void {
    const ix = map_index(position) orelse return;
    const tile = &mapdata[ix];
    if (tile.is_masked) {
        const mask_ix = tile.mask_index();
        const entry = &get_mask(position).sim[mask_ix];
        entry.terrain = payload.terrain;
        entry.seen = entry.seen or payload.seen;
        entry.bloody = entry.bloody or payload.bloody;
    } else {
        tile.terrain = payload.terrain;
        tile.seen = tile.seen or payload.seen;
        tile.bloody = tile.bloody or payload.bloody;
    }
}

pub fn set_render_terrain_payload_at(position: IVec2, payload: FullTerrain.Payload) void {
    const ix = map_index(position) orelse return;
    const tile = &mapdata[ix];
    const mask = get_mask(position);
    const payload_index: u7 = @bitCast(payload);
    if (tile.is_masked) {
        const mask_ix = tile.mask_index();
        if (payload.terrain == mask.sim[mask_ix].terrain) {
            mask.sim[mask_ix].seen = mask.sim[mask_ix].seen or payload.seen;
            mask.sim[mask_ix].bloody = mask.sim[mask_ix].bloody or payload.bloody;
            mask.unmask(position);
        } else {
            const entry = &mask.render[mask_ix];
            entry.terrain = payload.terrain;
            entry.seen = payload.seen;
            entry.bloody = payload.bloody;
        }
    } else if (ENABLE_MASKING) {
        if (payload_index != tile.mask_index()) {
            const mask_ix = mask.mask(position) catch {
                std.log.err("mask buffer full. skipping terrain mask at {}", .{position});
                return;
            };
            const entry = &mask.render[mask_ix];
            entry.terrain = payload.terrain;
            entry.seen = payload.seen;
            entry.bloody = payload.bloody;
        }
    }
}

pub fn set_terrain_at(position: IVec2, terrain: Terrain) void {
    var payload = get_terrain_payload_at(position);
    payload.terrain = terrain;
    set_terrain_payload_at(position, payload);
}

pub fn set_render_terrain_at(position: IVec2, terrain: Terrain) void {
    var payload = get_render_terrain_payload_at(position);
    payload.terrain = terrain;
    set_render_terrain_payload_at(position, payload);
}

pub fn get_terrain_at(position: IVec2) Terrain {
    return get_terrain_payload_at(position).terrain;
}

pub fn get_render_terrain_at(position: IVec2) Terrain {
    return get_render_terrain_payload_at(position).terrain;
}

pub const TerrainMask = struct {
    sim: [128]FullTerrain = .{FullTerrain.from(.void_)} ** 128,
    render: [128]FullTerrain = .{FullTerrain.from(.void_)} ** 128,
    free: [128]u7 = init_free_list(),
    free_count: u8 = 128,

    fn init_free_list() [128]u7 {
        var list: [128]u7 = undefined;
        for (0..128) |i| {
            list[i] = @intCast(i);
        }
        return list;
    }

    // This marks a piece of mapdata indicating that
    // the main array is no longer the source of truth for it.
    // it's replaced with an index into the array here.
    pub fn mask(self: *TerrainMask, pos: IVec2) !u7 {
        const ix = map_index(pos) orelse return error.OutOfBounds;
        if (self.free_count == 0) return error.MaskBufferFull;

        self.free_count -= 1;
        const index = self.free[self.free_count];
        self.sim[index] = mapdata[ix];
        self.render[index] = mapdata[ix];
        mapdata[ix] = FullTerrain.from_mask_index(index);
        return index;
    }

    pub fn unmask(self: *TerrainMask, pos: IVec2) void {
        const ix = map_index(pos) orelse return;
        const tile = mapdata[ix];
        if (!tile.is_masked) return;
        const index = tile.mask_index();
        var result = self.sim[index];
        result.seen = result.seen or self.render[index].seen;
        result.bloody = result.bloody or self.render[index].bloody;
        mapdata[ix] = result;
        self.free[self.free_count] = index;
        self.free_count += 1;
    }
};

fn mask_bucket(pos: IVec2) u8 {
    const low_x: u4 = @truncate(@as(u16, @bitCast(@as(i16, @truncate(pos.x)))));
    const low_y: u4 = @truncate(@as(u16, @bitCast(@as(i16, @truncate(pos.y)))));
    return @as(u8, low_x) << 4 | @as(u8, low_y);
}

fn get_mask(pos: IVec2) *TerrainMask {
    return &terrain_masks[mask_bucket(pos)];
}

pub var terrain_masks: [256]TerrainMask = .{TerrainMask{}} ** 256;

fn rubblum(radius: IVec2, at: IVec2, terrain: Terrain, density: f32, rng: std.Random) !void {
    var buffer: [2 << 16]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();
    const max_radius: i16 = if (radius.x >= radius.y) radius.x else radius.y;
    const crater_template = try allocator.alloc(bool, @as(usize, @intCast(max_radius * max_radius * 16)));
    defer allocator.free(crater_template);
    errdefer @compileError("No errors after this");

    const bound: i16 = max_radius * 4;
    core.splat(@floatFromInt(radius.x), @floatFromInt(radius.y), bound, crater_template);
    for (0..crater_template.len) |ixu| {
        const ix: i16 = @as(i16, @intCast(ixu));
        const x: i16 = @divTrunc(ix, bound) + at.x - max_radius * 2;
        const y: i16 = @mod(ix, bound) + at.y - max_radius * 2;
        if (crater_template[ixu] and rng.float(f32) < density) {
            set_terrain_at(.{ .x = x, .y = y }, terrain);
        }
    }
}
