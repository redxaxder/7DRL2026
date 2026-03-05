const std = @import("std");
const core = @import("core.zig");
const IVec2 = core.IVec2;
const IRect = core.IRect;
const Interval = core.Interval;
const UnitType = @import("main.zig").UnitType;

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

pub fn fill_hatched(rect: IRect, t1: Terrain, t2: Terrain) void {
    var iter = rect.iter();
    const granularity = 3;
    while (iter.next()) |pos| {
        const gx = @divFloor(pos.x, granularity);
        const gy = @divFloor(pos.y, granularity);
        switch (@mod(gx ^ gy, 2)) {
            0 => set_terrain_at(pos, t1),
            1 => set_terrain_at(pos, t2),
            else => unreachable,
        }
    }
}

pub fn pick_road_interval(rect: IRect, rng: std.Random, orientation: core.Orientation, zone: Zone, max_road_width: i16) core.Interval {
    const v_interval, const h_interval = rect.intervals();
    const interval = switch (orientation) {
        .v => v_interval,
        .h => h_interval,
    };

    std.log.info("interval {any}", .{interval});
    if (interval.origin < 0) {
        @panic("oh no");
    }

    const max_lanes = @divFloor(max_road_width, 4);
    var lanes = max_lanes;

    if (rng.boolean()) {
        lanes -= 1;
    }
    lanes = @min(lanes, @divFloor(interval.len, 15));
    _ = zone; // TODO zone affects lanes
    if (@mod(lanes, 2) == 1 and lanes > 1) {
        lanes -= 1;
    }
    lanes = @max(lanes, 1);
    const len = lanes * 4 + 1;

    const min_origin = interval.origin + @divFloor(interval.len - len, 3);
    const max_origin = interval.origin + @divFloor(2 * (interval.len - len), 3);
    const got: core.Interval = .{
        .len = len,
        .origin = rng.intRangeAtMost(
            i16,
            min_origin,
            max_origin,
        ),
    };

    std.log.info("got {any}", .{got});
    return got;
}

pub fn new_mapgen(rect: IRect, zone: Zone, rng: std.Random, depth: u8, max_road_width: i16) void {
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
    // if (depth > 1) {
    //     return;
    // }

    // blocks
    const zone_is_fixed = @max(rect.w, rect.h) < 300;
    const new_zone: Zone = if (zone_is_fixed) zone else rng.enumValue(Zone);
    const block_threshold: i16 = switch (zone) {
        .Residential => 24,
        .Commercial => 48,
        .Industrial => 96,
    };
    if (rect.w < block_threshold or rect.h < block_threshold) {
        // TODO real logic
        fill_terrain(rect, .wall);
        if (rect.w > 3 and rect.h > 3) {
            fill_terrain(rect.expand(-1), .floor);
        }
        return;
    }

    const road_v = pick_road_interval(rect, rng, .v, zone, max_road_width);
    const road_h = pick_road_interval(rect, rng, .h, zone, max_road_width);
    const max_road: i16 = @min(road_v.len, road_h.len);

    const l, const v, const r = rect.slice(.v, road_v);
    const ur, const h1, const lr = r.slice(.h, road_h);
    const ul, const h2, const ll = l.slice(.h, road_h);
    const v1, const c, const v2 = v.slice(.h, road_h);

    new_mapgen(ul, new_zone, rng, depth + 1, max_road);
    new_mapgen(ur, new_zone, rng, depth + 1, max_road);
    new_mapgen(ll, new_zone, rng, depth + 1, max_road);
    new_mapgen(lr, new_zone, rng, depth + 1, max_road);

    // now actually pave the roads
    // v road
    {
        pave_road(v1, .v);
        pave_road(v2, .v);
    }
    // h road
    {
        pave_road(h1, .h);
        pave_road(h2, .h);
    }
    fill_terrain(c, .asphalt);
}

pub fn pave_road(rect: IRect, orientation: core.Orientation) void {
    const v_interval, const h_interval = rect.intervals();
    const interval = switch (orientation) {
        .v => v_interval,
        .h => h_interval,
    };

    const lanes = @divFloor(interval.len, 4);
    const pattern = switch (lanes) {
        1 => "10001",
        2 => "100020001",
        4 => "10003000200030001",
        6 => "1000300030002000300030001",
        else => unreachable,
    };
    for (pattern, 0..) |kind, ix| {
        const offset: i16 = @intCast(ix);
        const slice = core.Interval{
            .origin = offset + interval.origin,
            .len = 1,
        };
        const to_pave = rect.slice(orientation, slice)[1];
        switch (kind) {
            '0' => fill_terrain(to_pave, .asphalt),
            '1' => fill_terrain(to_pave, .sidewalk),
            '2' => fill_terrain(to_pave, .road_paint),
            '3' => fill_hatched(to_pave, .road_paint, .asphalt),
            else => unreachable,
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
                if (existing.moto_passable()) {
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

pub var mapdata: [MAPDATA_LEN]FullTerrain = .{FullTerrain.from(.grass)} ** MAPDATA_LEN;

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
    sidewalk,
    road_paint,
    grass,
    void_,
    _,

    pub fn name(self: Terrain) []const u8 {
        return switch (self) {
            .void_ => "strange barrier",
            else => std.enums.tagName(Terrain, self) orelse "",
        };
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
            .sidewalk => return 0xB0,
            .road_paint => return 0xB1,
            .grass => return '\"',
            else => return '/',
        }
    }

    pub fn unit_passable(self: Terrain, u: UnitType) bool {
        return switch (u) {
            .Kaiju => self.kaiju_passable(),
            .Player => self.player_passable(),
            .Motorcycle => self.moto_passable(),
            else => true,
        };
    }
    pub fn player_passable(self: Terrain) bool {
        return switch (self) {
            .wall, .void_ => false,
            else => true,
        };
    }

    pub fn moto_passable(self: Terrain) bool {
        return switch (self) {
            .wall, .rubble, .void_ => false,
            else => true,
        };
    }

    pub fn kaiju_passable(self: Terrain) bool {
        return switch (self) {
            .wall, .void_ => false,
            else => true,
        };
    }

    pub fn halting(self: Terrain) bool {
        return switch (self) {
            .door, .viscera => true,
            else => false,
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
