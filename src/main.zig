const std = @import("std");
const lib = @import("_7DRL2026");
const animation = @import("animation.zig");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const Callback = func.Callback;
const RenderBuffer = @import("render.zig");
const Sprite = RenderBuffer.Sprite;
const map = @import("map.zig");
const Terrain = map.Terrain;
const core = @import("core.zig");
const IVec2 = core.IVec2;
const Dir4 = core.Dir4;
const Vec2 = core.Vec2;
const Rect = core.Rect;
const sector = @import("sector.zig");
const inventory = @import("inventory.zig");
const fov = @import("fov.zig");
const Item = inventory.Item;

const get_occupants = sector.get_occupants;
const IRect = core.IRect;

const FOV_RANGE = 80;
const DANGER_GROWTH = 90;
const SPAWN_ROLL = 100000;

const ANIMATION_QUEUE_LEN = 256;

pub const animlib = struct {
    pub fn linear_slide(x0: Vec2, x1: Vec2, target: *Vec2, time: animation.Time) animation.Exit!void {
        const t = time.progress();
        target.* = x0.scaled(1 - t).plus(x1.scaled(t));
    }

    pub fn defer_set(comptime T: type) fn (T, *T, animation.Time) animation.Exit!void {
        return struct {
            pub fn call(val: T, ptr: *T, time: animation.Time) animation.Exit!void {
                _ = time;
                ptr.* = val;
                return error.Exit;
            }
        }.call;
    }

    pub const lock_camera = animation.singleton(255);
    pub const lock_player = animation.singleton(254);
    pub fn lock_unit_id(uid: UnitId) animation.LockData {
        if (uid == 0) {
            return .initEmpty();
        }
        if (uid == 1) {
            return lock_player;
        }
        const i = uid % 254;
        return animation.singleton(@intCast(i));
    }

    pub fn lock_position(pos: IVec2) animation.LockData {
        const bx: u4 = @truncate(@as(u16, @bitCast(pos.x)));
        const by: u4 = @truncate(@as(u16, @bitCast(pos.y)));
        const bit = (@as(usize, @intCast(bx)) << 4) + @as(usize, @intCast(by));
        return animation.singleton(bit + 256);
    }

    pub fn lock_position_sweep(pos: IVec2, dir: Dir4, dist: i16) animation.LockData {
        return lock_rect_sweep(IRect.singleton(pos), dir, dist);
    }

    pub fn lock_rect(rect: IRect) animation.LockData {
        var data = animation.LockData.initEmpty();
        var it = rect.iter();
        while (it.next()) |pos| {
            data.setUnion(lock_position(pos));
        }
        return data;
    }

    pub fn lock_rect_sweep(rect: IRect, dir: Dir4, dist: i16) animation.LockData {
        var data = lock_rect(rect);
        var slide = rect.slide(dir, dist);
        while (slide.next()) |edge| {
            data.setUnion(lock_rect(edge));
        }
        return data;
    }
};

pub const UnitType = enum {
    Nil,
    Player,
    Kaiju,
    Motorcycle,
    PendingExplosion,
    PendingRubble,
};

pub const UnitId = u16;
pub const Unit = struct {
    // Universal
    tag: UnitType = .Nil,
    position: IVec2 = IVec2.DEFAULT,
    render_position: Vec2 = Vec2.DEFAULT,

    // Healthy
    hp: i64 = 0,
    alive: bool = false,

    // Kaiju
    size: u8 = 1,

    // Motorcycle
    orientation: Dir4 = .Right,
    render_orientation: Dir4 = .Right,
    speed: u8 = 0,
    //TODO: model

    mounted_on: UnitId = 0,

    pub const DEFAULT: Unit = .{};

    // a unit occupies a position if it potentially obscructs travel into it
    // the only things that can do this are:
    //   - the player
    //   - motorcycles
    //   - kaiju
    // these are considered to have mutually exclusive ownership over locations,
    // except when the player is riding a motorcycle

    pub fn init_player(pos: IVec2) Unit {
        return .{
            .tag = .Player,
            .position = pos,
            .hp = 50,
            .alive = true,
            .render_position = pos.float(),
        };
    }

    pub fn init_pending_destruction(pos: IVec2) Unit {
        return .{
            .tag = .PendingRubble,
            .position = pos,
            .render_position = pos.float(),
        };
    }

    pub fn mounted(self: *const Unit) bool {
        return self.mount().tag != .Nil;
    }

    pub fn init_motorcycle(pos: IVec2, orientation: Dir4) Unit {
        return Unit{
            .tag = .Motorcycle,
            .position = pos,
            .render_position = pos.float(),
            .orientation = orientation,
            .render_orientation = orientation,
            .hp = 80,
            .alive = true,
        };
    }

    pub fn init_kaiju(pos: IVec2, size: u8) Unit {
        return .{
            .tag = .Kaiju,
            .position = pos,
            .render_position = pos.float(),
            .hp = std.math.pow(i64, 10, @intCast(size - 1)),
            .alive = true,
            .size = size,
        };
    }

    pub inline fn occupies(self: *const Unit, pos: IVec2) bool {
        const u: UnitType = self.tag;

        switch (u) {
            .Player => {
                return self.position.eq(pos);
            },
            .Motorcycle => {
                return self.position.eq(pos) or self.handlepos().eq(pos);
            },
            .Kaiju => {
                const delta = pos.minus(self.position);
                return delta.x >= 0 and delta.y >= 0 and delta.max_norm() <= self.size;
            },
            else => {
                return false;
            },
        }
    }

    pub fn get_id(self: *const Unit) UnitId {
        return @intCast((@intFromPtr(self) - @intFromPtr(&globals.units)) / @sizeOf(Unit));
    }

    pub fn move_to(self: *Unit, pos: IVec2) void {
        const from = self.position.float();
        const to = pos.float();
        const facing = self.position.facing(pos);
        const idist = self.position.max_norm_distance(pos);
        try_pickup(self.position, pos, facing);

        const id = self.get_id();
        sector.remove(id, self);
        self.position = pos;
        sector.add(id, self);
        const dist = to.distance(from);
        _ = globals.animation_queue.force_add(
            .{
                .duration = 50 * dist,
                .lock_exclusive = self.lock(),
                .lock_shared = animlib.lock_rect_sweep(self.get_rect(), facing, idist),
            },
            animlib.linear_slide,
            .{ from, to, &self.render_position },
        );
    }
    const Field: type = std.meta.FieldEnum(Unit);

    pub fn deferred_set(self: *Unit, comptime field: Field, val: @TypeOf(@field(self.*, @tagName(field)))) *animation.Animation {
        const name = @tagName(field);
        return globals.animation_queue.force_add(.{}, animlib.defer_set(@TypeOf(@field(self.*, name))), .{ val, &@field(self, name) });
    }

    pub fn lock(self: *const Unit) animation.LockData {
        return animlib.lock_unit_id(self.get_id());
    }

    pub fn set_orientation(self: *Unit, dir: Dir4) void {
        self.orientation = dir;
        const anim = self.deferred_set(.render_orientation, dir);
        _ = anim.lock_exclusive(self.lock());
    }

    pub fn damage(self: *Unit, amount: i64) void {
        self.hp -= amount;
    }

    pub fn mount(self: *const Unit) *Unit {
        return globals.unit(self.mounted_on);
    }

    pub fn get_rect(self: *const Unit) core.IRect {
        switch (self.tag) {
            .Nil => {
                return .{};
            },
            .Player, .PendingRubble => {
                return core.IRect.singleton(self.position);
            },
            .Kaiju, .PendingExplosion => {
                return core.IRect{
                    .x = self.position.x,
                    .y = self.position.y,
                    .w = @intCast(self.size),
                    .h = @intCast(self.size),
                };
            },
            .Motorcycle => {
                const p1 = self.position;
                const p2 = self.handlepos();
                const w: i16 = @intCast(@abs(p1.x - p2.x) + 1);
                const h: i16 = @intCast(@abs(p1.y - p2.y) + 1);
                return core.IRect{
                    .x = @min(p1.x, p2.x),
                    .y = @min(p1.y, p2.y),
                    .w = w,
                    .h = h,
                };
            },
        }
    }

    pub fn handlepos(self: *const Unit) IVec2 {
        return self.position.plus(self.orientation.ivec());
    }

    pub fn move(self: *Unit, dir: Dir4, distance: i16) void {
        const target = self.position.plus(dir.ivec().scaled(distance));
        self.move_to(target);
    }
};

pub fn try_pickup(from: IVec2, to: IVec2, dir: Dir4) void {
    const player = globals.player();
    const mounted: bool = player.mounted();
    const speed = from.minus(to).max_norm();
    var front_iter = player.get_rect().expand(1).slide(dir, speed);
    var accum_items: [10]?Item = .{null} ** 10;
    var accum_ix: usize = 0;
    while (front_iter.next()) |front_rect| {
        var rect_iter = front_rect.iter();
        while (rect_iter.next()) |p| {
            // if on foot, only pick up
            if (!(mounted or p.eq(player.position.plus(dir.ivec())))) {
                continue;
            }
            if (map.get_terrain_at(p) == .Trinket) {
                // randomly roll new item
                const name_ix: usize = globals.rng.intRangeAtMost(usize, 0, inventory.NAMES.len - 1);
                const name: []const u8 = inventory.NAMES[name_ix];
                const item: Item = .{
                    .tag = .Trinket,
                    .name = name,
                    .position = p,
                };
                accum_items[accum_ix] = item;
                accum_ix += 1;
                if (accum_ix >= 10) {
                    break;
                }
            }
        }
    }

    inventory.try_add_items(&accum_items);
}

pub const ux = struct {
    pub const InputMode = enum { Movement, Attack };
    pub const Action = union(enum) {
        move: struct { Dir4, bool },
        attack: Dir4,
    };
    pub var input_mode: InputMode = .Movement;

    fn toggle_weapon(id: usize) void {
        // TODO: handle inventory interaction
        _ = id;
        if (input_mode == .Movement) {
            input_mode = .Attack;
        } else {
            input_mode = .Movement;
        }
    }

    pub fn resolve_input(key: keyboard.Code) ?Action {
        const dir: ?Dir4 = switch (key) {
            .KeyW, .ArrowUp => .Up,
            .KeyA, .ArrowLeft => .Left,
            .KeyS, .ArrowDown => .Down,
            .KeyD, .ArrowRight => .Right,
            else => null,
        };

        if (dir) |d| {
            switch (input_mode) {
                .Movement => {
                    const shift = keyboard.isShiftDown();
                    return .{ .move = .{ d, shift } };
                },
                .Attack => {
                    return .{ .attack = d };
                },
            }
        } else {
            const weapon_id: ?usize = switch (key) {
                .Digit1, .Numpad1 => 1,
                .Digit2, .Numpad2 => 2,
                .Digit3, .Numpad3 => 3,
                .Digit4, .Numpad4 => 4,
                .Digit6, .Numpad6 => 6,
                .Digit7, .Numpad7 => 7,
                .Digit8, .Numpad8 => 8,
                .Digit9, .Numpad9 => 9,
                .Digit0, .Numpad0 => 0,
                else => null,
            };
            if (weapon_id) |weap| {
                toggle_weapon(weap);
            }
        }

        return null;
    }
};

pub const globals = struct {
    pub var units: [2000]Unit = .{Unit.DEFAULT} ** 2000;

    pub var attack_chain_target: ?UnitId = 0;
    pub var attack_chain_count: i64 = 0;
    pub var danger: u64 = 0;
    pub var animation_queue: animation.Queue = undefined;
    pub var rng: std.Random = undefined;

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

pub const PLAYER_ID: UnitId = 1;

pub fn spawn(u: Unit) UnitId {
    const id = globals.free_unit_id() orelse @panic("how did we run out so fast");
    globals.unit(id).* = u;
    sector.add(id, globals.unit(id));
    return id;
}

pub fn unspawn(u: *Unit) void {
    const anim = u.deferred_set(.tag, .Nil);
    _ = anim.lock_exclusive(u.lock())
        .lock_exclusive(animlib.lock_rect(u.get_rect()));
}

pub fn init(rng: std.Random) !void {
    sector.init();
    globals.animation_queue = try animation.Queue.init(std.heap.wasm_allocator, ANIMATION_QUEUE_LEN);
    globals.rng = rng;

    globals.units[PLAYER_ID] = .init_player(IVec2.ZERO);
    sector.add(PLAYER_ID, globals.player());

    const moto_id = spawn(.init_motorcycle(IVec2.ZERO, .Right));
    globals.player().mounted_on = moto_id;

    // _ = spawn(.init_kaiju(
    //     IVec2{ .x = 6, .y = 6 },
    //     3,
    // ));

    _ = spawn(.init_kaiju(
        IVec2{ .x = 9, .y = 28 },
        5,
    ));
    map.mapgen(rng);
    fov.refresh_fov(globals.player().position, FOV_RANGE);

    map.set_render_terrain_at(IVec2.ONE.scaled(7), Terrain.Void);

    const a = IRect{
        .x = 0,
        .y = 0,
        .w = 3,
        .h = 3,
    };
    var foo = a.slide(.Right, 2);
    while (foo.next()) |r| {
        std.log.info("r {}", .{r});
    }
}

// dir is null when you turn is not an active move, you are maybe just coasting
pub fn handle_player_move(dir: ?Dir4, shift: bool) bool {
    const player = globals.player();
    const pmount = player.mount();
    if (pmount.tag == .Motorcycle) {
        // mounted movement
        const motomove = resolve_motorcycle_movement(
            pmount,
            .{
                .dir = dir,
                .shift = shift,
            },
        );
        if (motomove.dismount) {
            player.move_to(motomove.position);
            player.*.mounted_on = 0;
        } else if (crash_check(pmount, motomove)) |crashed| {
            if (crashed.fling) {
                const delta = motomove.midpoint.minus(player.position);
                var landed_at = motomove.midpoint;
                var scan = landed_at.scan(pmount.orientation, delta.max_norm());
                while (scan.next()) |path| {
                    if (player_passable(path)) {
                        landed_at = path;
                    } else {
                        break;
                    }
                }
                player.move_to(landed_at);
            }
            pmount.move_to(motomove.midpoint);
            pmount.set_orientation(crashed.orientation);
            pmount.move_to(crashed.position);
            pmount.*.speed = 0;
            if (motomove.brake) {
                player.*.move_to(pmount.position);
            } else {
                player.*.mounted_on = 0;
            }
        } else {
            pmount.*.speed = motomove.speed;
            pmount.move_to(motomove.midpoint);
            player.move_to(motomove.midpoint);
            pmount.set_orientation(motomove.orientation);
            pmount.move_to(motomove.position);
            player.move_to(motomove.position);
        }
    } else {
        if (dir) |d| { // unmounted movement
            const dv = d.ivec();
            const target = player.position.plus(dv);

            var occupants = get_occupants(target);
            while (occupants.next()) |occupant_id| {
                const occupant = globals.unit(occupant_id);
                switch (occupant.tag) {
                    .Motorcycle => { // Mount it
                        player.move_to(occupant.position);
                        player.*.mounted_on = occupant_id;
                        return true;
                    },
                    .Kaiju => {
                        // move into kaiju?
                        return false;
                    },
                    else => {
                        continue;
                    },
                }
            }
            player.move_to(target);
        }
    }
    return true;
}

const SHOT_RANGE: usize = 64;

pub fn handle_player_attack(dir: Dir4) bool {
    var scan = globals.player().position.scan(dir, SHOT_RANGE);
    while (scan.next()) |aim| {
        const terrain = map.get_terrain_at(aim);
        if (terrain.blocks_shot()) {
            // you shoot at the terrain
            // consequences TBD
            std.log.info("plink!", .{});
            return true;
        }
        var aim_occupants = get_occupants(aim);
        while (aim_occupants.next()) |occupant_id| {
            const unit = globals.unit(occupant_id);
            if (unit.tag == .Kaiju) {
                // you shoot at the kaiju
                if (globals.attack_chain_target != occupant_id) {
                    globals.attack_chain_target = occupant_id;
                    globals.attack_chain_count = 0;
                } else {
                    globals.attack_chain_count += 1;
                }
                // TBD
                const damage = 1000000 + (2 * globals.attack_chain_count);
                unit.damage(damage);
                std.log.info("bang! {}", .{unit.hp});
                return true;
            }
        }
    }
    std.log.info("whiff!", .{});
    return true;
}

pub fn logic_tick(key: keyboard.Code, rng: std.Random) void {
    // TODO currently we are iterating through all the units
    // to get at kaiju. This is an optimization opportunity
    var player_acted = false;
    const player_start = globals.player().position;

    if (ux.resolve_input(key)) |action| {
        globals.animation_queue.hurry(1.5);
        switch (action) {
            .move => |movedata| {
                const d, const shift = movedata;
                player_acted = handle_player_move(d, shift);
                if (player_acted) {
                    globals.attack_chain_target = 0;
                }
            },
            .attack => |d| {
                player_acted = handle_player_attack(d);
                if (player_acted) {
                    _ = handle_player_move(null, false);
                    // TODO: motorcycle with speed moves
                }
            },
        }

        player_acted = true;
    }
    if (player_acted) {
        fov.refresh_fov(globals.player().position, FOV_RANGE);
        resolve_pending(rng);
        const player_end = globals.player().position;
        const travel_distance: u64 = @intCast(player_start.max_norm_distance(player_end));
        // TODO: vary danger growth by location
        globals.danger += (travel_distance + 1) * DANGER_GROWTH;

        tick_kaiju(rng);

        if (roll_new_enemy(rng)) |spawn_rect| {
            new_kaiju(spawn_rect, rng) catch {
                std.log.err("failed to spawn enemy at {}", .{spawn_rect});
            };
        }

        units_cleanup(rng);
    }
}

fn resolve_pending(rng: std.Random) void {
    // TODO this could be more efficient
    for (globals.units[1..]) |*u| {
        if (u.tag == .PendingRubble) {
            const terrain: Terrain = if (rng.boolean()) .Debris else .Rubble;
            const pos = u.position;
            unspawn(u);
            const prev_terrain = map.get_render_terrain_at(pos);
            // update the real terrain state
            map.set_terrain_at(pos, terrain);
            // hide it with a fake image
            map.set_render_terrain_at(pos, prev_terrain);
            _ = globals.animation_queue.force_add_empty(
                .{
                    .chain = true,
                    .on_wake = .lambda(map.set_render_terrain_at, .{ pos, terrain }),
                },
            );

            var player: *Unit = globals.player();
            const moto: ?*Unit = if (player.mounted()) player.mount() else null;
            // damage player if hit
            // TODO how much damage?
            if (pos.eq(player.position)) {
                player.damage(10);
            } else if (moto) |m| {
                // damage moto if hit
                if (m.get_rect().contains(pos)) {
                    m.damage(10);
                }
            }
        }
    }
}

fn new_kaiju(target: IRect, rng: std.Random) !void {
    const size = target.w;
    const id = globals.free_unit_id() orelse return error.OutOfUnitSlots;
    var to_clear = target.expand(@divTrunc(size, 2)).iter();
    while (to_clear.next()) |pos| {
        destroy(pos, rng);
    }
    globals.units[id] = .init_kaiju(target.ivec(), @intCast(size));
}

fn tick_kaiju(rng: std.Random) void {
    // kaiju behavior is based on proximity
    for (globals.units[1..]) |*u| {
        if (u.tag == .Kaiju and u.alive and u.hp > 0) {
            // kaiju sleep if outside of 1 camera radius
            // TODO make more complex?
            const ppos = globals.player().position;
            if (u.get_rect().point_distance(ppos).max_norm() < 64) {
                kaiju_logic(u, rng);
            }
        }
    }
}

fn do_splatter(rect: IRect, seed: u16, mode: enum { initial, followup }) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var it = rect.iter();
    std.log.info("do splatter {}", .{mode});
    while (it.next()) |pos| {
        if (rng.boolean()) {
            const viscera = rng.boolean();
            switch (mode) {
                .initial => {
                    // make the real terrain bloody,
                    // but hide this in the displayed terrain
                    var tp = map.get_terrain_payload_at(pos);
                    const prev = tp;
                    tp.bloody = true;
                    if (viscera) {
                        tp.terrain = .Viscera;
                    }
                    map.set_terrain_payload_at(pos, tp);
                    map.set_render_terrain_payload_at(pos, prev);
                },
                .followup => {
                    // make the displayed terrain bloody
                    var tp = map.get_render_terrain_payload_at(pos);
                    tp.bloody = true;
                    if (viscera) {
                        tp.terrain = .Viscera;
                    }
                    map.set_render_terrain_payload_at(pos, tp);
                },
            }
        }
    }
}

fn units_cleanup(rng: std.Random) void {
    for (globals.units[1..]) |*u| {
        if (u.hp <= 0 and u.alive) {
            u.alive = false;
            unspawn(u);
            switch (u.tag) {
                .Kaiju => {
                    const splatter_zone = u.get_rect().expand(1);
                    const seed = rng.int(u16);
                    do_splatter(splatter_zone, seed, .initial);
                    const callback: Callback = .lambda(do_splatter, .{ splatter_zone, seed, .followup });
                    _ = globals.animation_queue.force_add_empty(.{ .on_wake = callback, .chain = true });
                    return;
                },
                .Motorcycle => {
                    return;
                },
                .Player => {
                    return;
                },
                else => {
                    return;
                },
            }
        }
    }
}

fn roll_new_enemy(rng: std.Random) ?IRect {
    const player = globals.player();
    const roll = rng.int(u64) % SPAWN_ROLL;
    if (roll > globals.danger) {
        return null;
    }
    // how far away they can spawn
    const RADIUS: i16 = 90;
    // how close they can spawn
    const MIN_RADIUS: i16 = 50;
    // how much the candidate spawn zone moves in
    // the direction of travel
    const SHIFT: i16 = 60;
    const rolled_size = @as(i16, @clz(rng.int(u32))) + 3;
    var arena: IRect = (IRect{
        .x = player.position.x - RADIUS,
        .y = player.position.y - RADIUS,
        .w = 2 * RADIUS + 1 - (rolled_size - 1),
        .h = 2 * RADIUS + 1 - (rolled_size - 1),
    });
    if (player.mounted()) {
        const mount = player.mount();
        const v = mount.orientation.ivec().scaled(SHIFT);
        arena = arena.displace(v);
    }
    const w: usize = @intCast(arena.w);
    const h: usize = @intCast(arena.h);
    const rolled_pos = arena.from_linear_index(
        rng.int(usize) % (w * h),
    );
    const target_rect = IRect.from(
        rolled_pos,
        IVec2.ONE.scaled(rolled_size),
    );
    if (target_rect.point_distance(player.position).max_norm() < MIN_RADIUS) {
        return null;
    }

    globals.danger -= roll;
    return target_rect;
}

// destroys wall
// TODO, fling rubble
fn destroy_wall(demolitionist: *const Unit, dir: Dir4, rng: std.Random) void {
    var wall_iter = demolitionist.get_rect().slide(dir, 1);

    // destroy the wall
    while (wall_iter.next()) |wall| {
        var boom_iter = wall.iter();
        while (boom_iter.next()) |boom_coord| {
            if (map.get_terrain_at(boom_coord) == .Wall) {
                const terrain: Terrain = if (rng.boolean()) .Rubble else .Debris;
                map.set_terrain_at(boom_coord, terrain);
            }
        }
    }

    // spawn pending rubble
    const fling_distance: i16 = 10;
    const rubble_spawn_chance: f32 = 0.05;
    var rubble_iter = demolitionist.get_rect().slide(dir, fling_distance);
    while (rubble_iter.next()) |front| {
        var front_iter = front.iter();
        while (front_iter.next()) |pos| {
            if (rng.float(f32) < rubble_spawn_chance) {
                const pr: Unit = Unit.init_pending_destruction(pos);
                _ = spawn(pr);
            }
        }
    }
}

fn die() void {
    std.log.info("YOU LOSE TURKEY", .{});
}

fn harm() void {
    std.log.info("ouchie", .{});
    globals.player().hp = 1;
}

fn destroy(pos: IVec2, rng: std.Random) void {
    const rubble_type: Terrain = if (rng.boolean()) .Debris else .Rubble;
    map.set_terrain_at(pos, rubble_type);
}

fn smack_player(dir: Dir4, rng: std.Random) void {
    const fling_distance: i16 = 10;
    var player = globals.player();
    const moto: ?*Unit = if (player.mounted()) player.mount() else null;
    if (globals.player().hp <= 1) {
        die();
    } else {
        harm();

        // fling player
        const fling_rect: IRect = if (moto) |m| m.get_rect() else player.get_rect();
        var fling_iter = fling_rect.slide(dir, fling_distance);
        while (fling_iter.next()) |fling_slice| {
            var iter = fling_slice.iter();
            while (iter.next()) |pos| {
                if (map.get_terrain_at(pos) == .Wall) {
                    destroy(pos, rng);
                }
            }
        }
        const target: IVec2 = player.position.plus(dir.ivec().scaled(fling_distance));
        globals.player().move_to(target);
        if (moto) |m| {
            m.move_to(target);
            m.speed = 0;
        }
    }
}

const KaijuLook = struct {
    distance: i16 = 0,
    unit: ?UnitId = null,
    terrain: ?Terrain = null,
};
fn kaiju_look(from: *const Unit, dir: Dir4, limit: i16) KaijuLook {
    var slide_iter = from.get_rect().slide(dir, limit);
    var result: KaijuLook = .{};
    while (slide_iter.next()) |edge| {
        var frontier_iter = edge.iter();
        while (frontier_iter.next()) |pos| {
            const terrain = map.get_terrain_at(pos);
            if (!terrain.kaiju_passable()) {
                result.terrain = terrain;
                return result;
            }
        }
        var occupant_iter = sector.get_occupants_rect(edge);
        while (occupant_iter.next()) |uid| {
            const u = globals.unit(uid);
            switch (u.tag) {
                .Kaiju, .Player => {
                    result.unit = uid;
                    return result;
                },
                .Motorcycle => {
                    if (uid == globals.player().mounted_on) {
                        result.unit = uid;
                        return result;
                    }
                },
                else => {},
            }
        }
        result.distance += 1;
    }
    return result;
}

fn kaiju_logic(k: *Unit, rng: std.Random) void {
    const dir: Dir4 = k.position.facing(globals.player().position);
    const seen = kaiju_look(k, dir, k.size);
    const attack_range = (k.size + 1) / 3;
    if (seen.terrain) |_| {
        if (seen.distance == 0) {
            destroy_wall(k, dir, rng);
            return;
        }
    } else if (seen.unit) |u| {
        switch (globals.unit(u).tag) {
            .Player, .Motorcycle => {
                if (seen.distance <= attack_range) {
                    smack_player(dir, rng);
                    return;
                }
            },
            else => {},
        }
    }
    k.move(dir, seen.distance);
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
    brake: bool,
    slide: bool,
    dismount: bool,
};

pub fn player_passable(pos: IVec2) bool {
    const t = map.get_terrain_at(pos);
    if (!t.passable()) {
        return false;
    }
    //TODO: kaiju obstruction
    return true;
}

pub fn moto_passable(pos: IVec2, orientation: Dir4) bool {
    const t = map.get_terrain_at(pos);
    const p2 = pos.plus(orientation.ivec());
    const t2 = map.get_terrain_at(p2);
    return t.passable() and t2.passable();
}

pub const CrashInfo = struct {
    position: IVec2,
    orientation: Dir4,
    fling: bool = false,
};

pub fn crash_check(moto: *const Unit, move: MotoResult) ?CrashInfo {
    const delta = move.position.minus(moto.position);
    const n = delta.max_norm();

    if (core.RelativeDir.from(moto.orientation, move.orientation) == .Reverse) {
        return null;
    }

    // we're strafing if we haven't changed direction, but we're moving on both x and y
    const strafe_mode = (move.orientation == moto.orientation) and delta.x != 0 and delta.y != 0;

    if (move.brake) {
        const v = moto.orientation.ivec();
        var cursor = CrashInfo{
            .position = moto.position,
            .orientation = moto.orientation,
        };
        if (move.slide) {
            const p = moto.handlepos().minus(move.orientation.ivec());
            if (!moto_passable(p, move.orientation)) {
                // we shouldnt end up here
                std.log.err("unhandled movement case", .{});
            }
            cursor.position = p;
            cursor.orientation = move.orientation;
        }
        const steps: usize = @intCast(delta.max_norm());
        for (0..steps) |_| {
            const next = cursor.position.plus(v);
            if (!moto_passable(next, cursor.orientation)) {
                return cursor;
            }
            cursor.position = next;
        }
        return null;
    }

    if (strafe_mode) {
        // strafe crash resolution is generous:
        // the shift to the target row/column happens at the last possible legal moment
        const principal_vector = moto.orientation.ivec();
        const secondary_vector = delta.minus(principal_vector.scaled(n));
        var shifted: bool = false;

        var cursor = CrashInfo{
            .position = moto.position,
            .orientation = moto.orientation,
        };

        for (0..@intCast(n)) |_| {
            var next = cursor.position.plus(principal_vector);
            if (!shifted and !moto_passable(next, moto.orientation)) {
                next = next.plus(secondary_vector);
                shifted = true;
            }
            if (!moto_passable(next, moto.orientation)) {
                return cursor;
            }
            cursor.position = next;
        }
        if (!shifted) {
            const final = cursor.position.plus(secondary_vector);
            if (!moto_passable(final, moto.orientation)) {
                return cursor;
            }
        }

        return null;
    }

    var cursor = CrashInfo{
        .position = moto.position,
        .orientation = moto.orientation,
    };
    const steps: usize = @intCast(delta.projection(moto.orientation).max_norm());
    for (0..steps) |i| {
        const next = cursor.position.plus(moto.orientation.ivec());
        const o = if ((i + 1) < steps)
            moto.orientation
        else
            move.orientation;
        if (!moto_passable(next, o)) {
            return cursor;
        }
        cursor.position = next;
    }
    if (move.orientation != moto.orientation) {
        cursor.orientation = move.orientation;
        cursor.fling = true;
        const steps2 = delta.projection(move.orientation).max_norm();
        for (0..@intCast(steps2)) |_| {
            const next = cursor.position.plus(move.orientation.ivec());
            if (!moto_passable(next, move.orientation)) {
                return cursor;
            }
            cursor.position = next;
        }
    }
    return null;
}

pub fn resolve_motorcycle_movement(
    moto: *const Unit,
    move: MotoMove,
) MotoResult {
    var it = MotoResult{
        .position = moto.position,
        .midpoint = moto.position,
        .speed = moto.speed,
        .orientation = moto.orientation,
        .dismount = false,
        .brake = false,
        .slide = false,
    };

    const change = move.dir orelse {
        const drift = moto.orientation.ivec().scaled(@intCast(moto.speed));
        it.position = it.position.plus(drift);
        return it;
    };
    const slide_dist = @max(moto.speed / 2, 1);

    switch (core.RelativeDir.from(change, moto.orientation)) {
        .Forward => {
            // accelerate!
            it.speed = @min(it.speed + 1, MAX_SPEED);
            const drift = moto.orientation.ivec().scaled(@intCast(it.speed));
            it.position = it.position.plus(drift);

            // in shift mode, we move at speed+1, but keep our previous speed
            if (move.shift) {
                it.speed = moto.speed;
            }
        },
        .Left, .Right => {
            // in shift mode, we strafe instead of turning
            if (move.shift) {
                const drift = moto.orientation.ivec()
                    .scaled(@intCast(it.speed))
                    .plus(change.ivec());
                it.position = it.position.plus(drift);
                if (moto.speed == 0) {
                    it.dismount = true;
                }
            } else { // turn!
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
            }
        },
        .Reverse => { // brake!
            it.brake = true;
            if (move.shift) {
                if (it.speed > 0) {
                    // slight brake
                    it.speed -= 1;
                    const drift = moto.orientation.ivec()
                        .scaled(@intCast(it.speed))
                        .plus(change.ivec());
                    it.position = it.position.plus(drift);
                } else {
                    // //dismount
                    it.dismount = true;
                    it.position = it.position.plus(change.ivec());
                }
            } else { // full brake
                const drift = moto.orientation.ivec().scaled(@intCast(slide_dist));
                it.position = it.position.plus(drift);
                if (moto.speed == 0) {
                    it.orientation = change;
                }
                it.speed = 0;
                // if speed is high enough, brake via akira slide.
                // we hold the handlebar position constant,
                // rotate the player's position around them
                const slidestart = moto.handlepos().plus(moto.orientation.turn(.Right).ivec());
                if (slide_dist >= 2 and player_passable(slidestart)) {
                    it.slide = true;
                    it.position = it.position.plus(it.orientation.ivec());
                    it.orientation = moto.orientation.turn(.Left);
                    it.position = it.position.minus(it.orientation.ivec());
                }
            }
        },
    }
    return it;
}

pub fn get_reticle_positions() ?[5]IVec2 {
    const mount = globals.player().mount();
    if (mount.tag == .Nil) {
        return null;
    }
    var result: [5]IVec2 = undefined;
    for (std.enums.values(Dir4), 0..) |d, i| {
        const projection = resolve_motorcycle_movement(mount, .{ .dir = d });
        const ppos = projection.position;
        const handlepos = ppos.plus(projection.orientation.ivec());
        result[i] = handlepos;
    }
    const projection = resolve_motorcycle_movement(mount, .{});
    const ppos = projection.position;
    const handlepos = ppos.plus(projection.orientation.ivec());
    result[4] = handlepos;
    return result;
}

test {
    std.testing.refAllDecls(@This());
}
