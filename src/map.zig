const std = @import("std");
const core = @import("core.zig");
const IVec2 = core.IVec2;
const IRect = core.IRect;
const Interval = core.Interval;
const UnitType = @import("main.zig").UnitType;
const Color = @import("render.zig").Color;

const Zone = enum {
    Residential,
    Commercial,
    Industrial,
};

fn fill_terrain(rect: IRect, terrain: Terrain) void {
    var iter = BOUNDS.intersection(rect).iter();
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
            else => {
                std.log.err("nontraditional output of mod 2", .{});
                unreachable;
            },
        }
    }
}

pub fn pick_road_interval(rect: IRect, rng: std.Random, orientation: core.Orientation, zone: Zone, zone_is_fixed: bool, max_road_width: i16) core.Interval {
    const v_interval, const h_interval = rect.intervals();
    const interval = switch (orientation) {
        .v => v_interval,
        .h => h_interval,
    };

    // std.log.info("interval {any}", .{interval});
    if (interval.origin < 0) {
        @panic("oh no");
    }

    const max_lanes = @divFloor(max_road_width, 4);
    var lanes = max_lanes;
    // std.log.info("2 lanes {}", .{lanes});
    // bias lanes
    if (zone_is_fixed) {
        const commercial_options: [2]i16 = .{ 2, 4 };
        const industrial_options: [2]i16 = .{ 4, 6 };
        const residential_options: [2]i16 = .{ 1, 2 };
        const bias: [2]f32 = .{ 0.3, 0.7 };
        lanes = switch (zone) {
            .Commercial => commercial_options[rng.weightedIndex(f32, &bias)],
            .Industrial => industrial_options[rng.weightedIndex(f32, &bias)],
            .Residential => residential_options[rng.weightedIndex(f32, &bias)],
        };
    } else {
        const bias: [2]f32 = .{ 0.3, 0.7 };
        const zone_options: [2]i16 = .{ 4, 6 };
        lanes = zone_options[rng.weightedIndex(f32, &bias)];
    }
    // std.log.info("1 lanes {}", .{lanes});
    // lanes = @min(lanes, @divFloor(interval.len, 16));
    // must have an even number of lanes if more than one
    if (@mod(lanes, 2) == 1 and lanes > 1) {
        lanes -= 1;
    }
    // std.log.info("3 lanes {}", .{lanes});
    // can't have 0 lanes
    lanes = @max(1, lanes);
    // std.log.info("4 lanes {}", .{lanes});
    lanes = @min(lanes, max_lanes);
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

    if (got.origin < interval.origin or got.origin + got.len > interval.origin + interval.len) {
        std.log.info("pick_road_interval: interval={} road={} lanes={} len={} orientation={}", .{ interval, got, lanes, len, orientation });
        unreachable;
    }
    return got;
}

fn gen_industrial(rect: IRect, rng: std.Random) void {
    // fill with grass
    fill_terrain(rect, .grass);

    roll_interesting_terrain(rect, .Industrial, rng);

    // gen small buildings
    // approach: gen 2-3 disjoint intervals in the interior
    // of the zone in each direction. Those are rects that we can use
    const interior: IRect = rect.expand(-1);
    std.log.info("interior {}", .{interior});
    var subrects: [6]?IRect = .{null} ** 6;
    const tries: usize = 6;
    var i: usize = 0;
    for (0..tries) |_| {
        //generate a random rect in the interior
        const l: i16 = rng.intRangeAtMost(i16, interior.x + 1, interior.x + interior.w - 1);
        const t: i16 = rng.intRangeAtMost(i16, interior.y + 1, interior.y + interior.h - 1);
        const r: i16 = rng.intRangeAtMost(i16, l + 1, interior.x + interior.w);
        const b: i16 = rng.intRangeAtMost(i16, t + 1, interior.y + interior.h);
        const candidate: IRect = IRect.from_sides(l, t, r, b);
        if (candidate.w < 3 or candidate.h < 3) {
            continue;
        }
        for (&subrects) |sr| {
            if (sr) |s| {
                if (candidate.intersects(s)) {
                    break;
                }
            }
        }
        gen_small_building(candidate, rng);
        subrects[i] = candidate;
        i += 1;
    }

    var p_buffer: [1 << 12]?IVec2 = .{null} ** (1 << 12);
    var perimeter = rect.perimeter(&p_buffer);
    var gap_size: u8 = 0;
    while (perimeter.next()) |pos| {
        if (gap_size == 0 and rng.float(f32) < 0.1) {
            gap_size = rng.intRangeAtMost(u8, 3, 5);
        }
        if (gap_size > 0) {
            set_terrain_at(pos, .asphalt);
            gap_size -= 1;
        } else {
            set_terrain_at(pos, .wall);
        }
    }
}

fn gen_commercial(rect: IRect, rng: std.Random) void {
    // TODO interior walls
    // fill with floor
    fill_terrain(rect, .floor);
    roll_interesting_terrain(rect, .Commercial, rng);

    var buffer: [1 << 12]?IVec2 = .{null} ** (1 << 12);
    var perimeter = rect.perimeter(&buffer);
    var gap_size: u8 = 0;
    var num_doors: u8 = 0;
    const max_doors: u8 = 2;
    while (perimeter.next()) |pos| {
        if (gap_size == 0 and rng.float(f32) < 0.3 and num_doors < max_doors) {
            gap_size = rng.intRangeAtMost(u8, 2, 4);
            num_doors += 1;
        }
        if (gap_size > 0) {
            set_terrain_at(pos, .door);
            gap_size -= 1;
        } else if (rng.float(f32) < 0.1) {
            set_terrain_at(pos, .window);
        } else {
            set_terrain_at(pos, .wall);
        }
    }
}

pub fn gen_small_building(rect: IRect, rng: std.Random) void {
    // fill with floor
    fill_terrain(rect, .floor);
    roll_interesting_terrain(rect, .Residential, rng);
    var buffer: [1 << 12]?IVec2 = .{null} ** (1 << 12);
    var perimeter = rect.perimeter(&buffer);
    var gap_size: u8 = 0;
    var num_doors: u8 = 0;
    const max_doors: u8 = 2;
    while (perimeter.next()) |pos| {
        if (gap_size == 0 and rng.float(f32) < 0.3 and num_doors < max_doors) {
            gap_size = rng.intRangeAtMost(u8, 1, 2);
            num_doors += 1;
        }
        if (gap_size > 0) {
            set_terrain_at(pos, .door);
            gap_size -= 1;
        } else {
            set_terrain_at(pos, .wall);
        }
    }
}

fn gen_residential(rect: IRect, rng: std.Random) void {
    // fill with sidewalk
    fill_terrain(rect, .sidewalk);

    // split rect on height
    const orientation: core.Orientation = if (rect.h > rect.w) .h else .v;
    const ix, const iy = rect.intervals();
    const interval: Interval = switch (orientation) {
        .h => iy,
        .v => ix,
    };
    const min_origin = interval.origin + @divFloor(interval.len - 2, 3);
    const max_origin = interval.origin + @divFloor(2 * (interval.len - 2), 3);
    const origin = rng.intRangeAtMost(i16, min_origin, max_origin);
    const slice_interval: Interval = .{ .origin = origin, .len = 2 };
    const first, const m, const second = rect.slice(orientation, slice_interval);
    _ = m;

    gen_small_building(first, rng);
    gen_small_building(second, rng);
}

const Option = enum {
    Item,
    Rubble,
    Debris,
    Money,
    Vending,
    Wall,
    Ground,
};

fn prob_table(entries: []const f32, comptime size: usize) [size]f32 {
    var sum: f32 = 0;
    var result: [size]f32 = .{0} ** size;
    for (entries, 0..) |e, i| {
        sum += e;
        result[i] = entries[i];
    }
    result[size - 1] = 1.0 - sum;
    return result;
}

pub fn roll_interesting_terrain(rect: IRect, zone: Zone, rng: std.Random) void {
    const options: [7]Option = .{
        .Item,
        .Rubble,
        .Debris,
        .Money,
        .Vending,
        .Wall,
        .Ground,
    };
    const roll_table: [6]f32 = switch (zone) {
        .Residential => .{ 0.03, 0.02, 0.05, 0.1, 0, 0 },
        .Commercial => .{ 0.0025, 0.005, 0.0075, 0.005, 0.001, 0.0015 },
        .Industrial => .{ 0, 0.004, 0.010, 0, 0, 0.002 },
    };
    const probs: [7]f32 = prob_table(&roll_table, 7);
    var iter = rect.iter();
    while (iter.next()) |pos| {
        const thing: Option = options[rng.weightedIndex(f32, &probs)];
        const terrain: Terrain = switch (thing) {
            .Item => .trinket,
            .Rubble => .rubble,
            .Debris => .debris,
            .Money => .money,
            .Wall => .wall,
            .Vending => .vending_machine,
            .Ground => switch (zone) {
                .Residential => .floor,
                .Commercial => .floor,
                .Industrial => .grass,
            },
        };
        if (get_terrain_at(pos) != .wall) {
            set_terrain_at(pos, terrain);
        }
    }
}

pub fn new_mapgen(rect: IRect, zone: Zone, rng: std.Random, depth: u8, max_road_width: i16) void {
    // scheme:
    // recursively -
    //   draw some number of roads, which divide up the given rect
    //   the areas between the roads into new rects. Recursively
    //   call new mapgen on those rects, with some thresholding logic.
    //
    // Zones are decided at threshold
    //
    // Road width ranges from 6 lanes (3 each direction) to 2 lanes in
    // pre-zone gen and 4 lanes (2 each direction) to 1 lane in post-zone gen.
    // Commercial and industrial are biased to bigger roads.
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
        .Industrial => 64,
    };
    if (rect.w < block_threshold or rect.h < block_threshold) {
        // TODO real logic
        switch (zone) {
            .Industrial => {
                gen_industrial(rect, rng);
            },
            .Commercial => {
                gen_commercial(rect, rng);
            },
            .Residential => {
                gen_residential(rect, rng);
            },
        }
        return;
    }

    const road_v = pick_road_interval(rect, rng, .v, zone, zone_is_fixed, max_road_width);
    const road_h = pick_road_interval(rect, rng, .h, zone, zone_is_fixed, max_road_width);
    const max_road: i16 = @min(road_v.len, road_h.len);

    const l, const v, const r = rect.slice(.v, road_v);
    const ur, const h1, const lr = r.slice(.h, road_h);
    const ul, const h2, const ll = l.slice(.h, road_h);
    const v1, const c, const v2 = v.slice(.h, road_h);

    // now actually pave the roads
    // v road
    {
        pave_road(v1, .v, rng);
        pave_road(v2, .v, rng);
    }
    // h road
    {
        pave_road(h1, .h, rng);
        pave_road(h2, .h, rng);
    }
    fill_terrain(c, .asphalt);
    for (c.corners()) |p| {
        set_terrain_at(p, .sidewalk);
    }

    new_mapgen(ul, new_zone, rng, depth + 1, max_road);
    new_mapgen(ur, new_zone, rng, depth + 1, max_road);
    new_mapgen(ll, new_zone, rng, depth + 1, max_road);
    new_mapgen(lr, new_zone, rng, depth + 1, max_road);
}

pub fn pave_road(rect: IRect, orientation: core.Orientation, rng: std.Random) void {
    const v_interval, const h_interval = rect.intervals();
    const interval = switch (orientation) {
        .v => v_interval,
        .h => h_interval,
    };

    const lanes = @divFloor(interval.len, 4);
    const pattern = switch (lanes) {
        1 => "10001",
        2 => "100030001",
        4 => "10003000200030001",
        6 => "1000300030002000300030001",
        else => {
            std.log.err("jank lane count", .{});
            unreachable;
        },
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
            '1' => fill_sidewalk(to_pave, rng),
            '2' => fill_terrain(to_pave, .road_paint),
            '3' => fill_hatched(to_pave, .road_paint, .asphalt),
            else => {
                std.log.err("jank kind", .{});
                unreachable;
            },
        }
    }

    const other_interval = switch (orientation) {
        .v => h_interval,
        .h => v_interval,
    };
    const flip = orientation.flip();
    const danglers = rect
        .expando(orientation, 1)
        .expando(flip, -1)
        .slice(orientation.flip(), other_interval);
    fill_terrain(danglers[0], .asphalt);
    fill_terrain(danglers[2], .asphalt);
}

fn fill_sidewalk(rect: IRect, rng: std.Random) void {
    const vending_chance: f32 = 0.01;
    var iter = rect.iter();
    while (iter.next()) |pos| {
        const t: Terrain = if (rng.float(f32) < vending_chance) .vending_machine else .sidewalk;
        set_terrain_at(pos, t);
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

const DrawInfo = struct {
    glyph: u8,
    color: Color,
};
pub fn rendered_glyph(pos: IVec2) DrawInfo {
    if (!BOUNDS.contains(pos)) {
        return .{
            .glyph = '%',
            .color = .dark_gray,
        };
    }
    const payload: FullTerrain.Payload = get_render_terrain_payload_at(pos);
    if (!payload.seen) {
        return .{
            .glyph = '/',
            .color = .dark_blue,
        };
    }
    const terrain = payload.terrain;
    const glyph = if (terrain == .wall) wall_glyph(pos) else terrain.glyph();
    return .{
        .glyph = glyph,
        .color = if (payload.bloody) .red else terrain.default_color(),
    };
}

fn is_wall_at(pos: IVec2) bool {
    const t = get_render_terrain_at(pos);
    return switch (t) {
        .wall, .window, .door => true,
        else => false,
    };
}

fn wall_glyph(pos: IVec2) u8 {
    const right: u4 = if (is_wall_at(pos.plus(.{ .x = 1 }))) 1 else 0;
    const up: u4 = if (is_wall_at(pos.plus(.{ .y = -1 }))) 2 else 0;
    const left: u4 = if (is_wall_at(pos.plus(.{ .x = -1 }))) 4 else 0;
    const down: u4 = if (is_wall_at(pos.plus(.{ .y = 1 }))) 8 else 0;
    const mask = right | up | left | down;

    // CP437 double-line box-drawing characters indexed by adjacency bitmask
    // bit 0=right, 1=up, 2=left, 3=down
    return switch (mask) {
        0b0101 => 0xCD, // ═  left+right
        0b1010 => 0xBA, // ║  up+down
        0b1001 => 0xC9, // ╔  down+right
        0b1100 => 0xBB, // ╗  down+left
        0b0011 => 0xC8, // ╚  up+right
        0b0110 => 0xBC, // ╝  up+left
        0b1101 => 0xCB, // ╦  down+left+right
        0b0111 => 0xCA, // ╩  up+left+right
        0b1011 => 0xCC, // ╠  up+down+right
        0b1110 => 0xB9, // ╣  up+down+left
        0b1111 => 0xCE, // ╬  all four
        else => '#', // ╬
    };
}

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
    vending_machine,
    window,
    void_,

    pub fn name(self: Terrain) []const u8 {
        if (self == .void_) return "strange barrier";
        return switch (self) {
            inline else => |tag| {
                const tag_name = @tagName(tag);
                const result = comptime blk: {
                    var buf: [tag_name.len]u8 = undefined;
                    for (&buf, tag_name) |*b, c| {
                        b.* = if (c == '_') ' ' else std.ascii.toLower(c);
                    }
                    break :blk buf;
                };
                return &result;
            },
        };
    }

    fn default_color(self: Terrain) Color {
        return switch (self) {
            .window => .cyan,
            .grass => .green,
            .road_paint => .yellow,
            .trinket => .yellow,
            .vending_machine => .teal,
            .sidewalk => .gray,
            .debris => .dark_gray,
            .money => .dark_green,
            .door => .brown,
            .void_ => .dark_blue,
            else => .white,
        };
    }

    fn glyph(self: Terrain) u8 {
        switch (self) {
            .asphalt => return 0,
            // .asphalt => return '\\',
            .floor => return '.',
            .wall => return '#',
            .door => return '+',
            .window => return 0xCE, // ╬
            .rubble => return '&',
            .viscera => return 0x9C,
            .money => return 0x9D,
            .debris => return ';',
            .trinket => return 0x0F,
            .sidewalk => return 0xB0,
            .road_paint => return 0xB0,
            .grass => return ',',
            .vending_machine => return 0xF0,
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
            .wall, .void_, .vending_machine, .window => false,
            else => true,
        };
    }

    pub fn moto_passable(self: Terrain) bool {
        return switch (self) {
            .wall, .rubble, .void_, .vending_machine, .window => false,
            else => true,
        };
    }
    pub fn can_place_moto(self: Terrain) bool {
        return switch (self) {
            .asphalt, .road_paint, .sidewalk => true,
            else => false,
        };
    }

    pub fn kaiju_passable(self: Terrain) bool {
        return switch (self) {
            .wall, .void_, .window => false,
            else => true,
        };
    }

    pub fn halting(self: Terrain) bool {
        return switch (self) {
            .door, .viscera => true,
            else => false,
        };
    }

    pub fn smash(self: Terrain) ?Terrain {
        return switch (self) {
            .rubble, .viscera, .window, .door, .trinket, .vending_machine => .debris,
            .wall => .rubble,
            else => null,
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
