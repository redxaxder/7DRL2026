const std = @import("std");
const lib = @import("_7DRL2026");
const animation = @import("animation.zig");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const combat_log = @import("combat_log.zig");
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
const RingBuffer = @import("ringbuffer.zig").RingBuffer;

const get_occupants = sector.get_occupants;
const IRect = core.IRect;

// given that killing a size 3 kaiju unlocks the 4th slot, and it scales linearly..
// we get size 9 -> 10th slot
// size 10 -> victory
pub const MOTHER_KAIJU_SIZE = 10;
pub const MIN_KAIJU_SIZE = 3;

pub const FOV_RANGE = 40;
const SPAWN_ROLL = 400000;

const ANIMATION_QUEUE_LEN = 256;

pub fn danger_growth(pos: IVec2) u64 {
    const d: u64 = @intCast(KMOM_START.manhattan_distance(pos));
    return (5000 - d) / 7;
}

pub const animlib = struct {
    pub fn linear_slide(x0: Vec2, x1: Vec2, target: *Vec2, time: animation.Time) animation.Exit!void {
        const t = time.progress();
        target.* = x0.scaled(1 - t).plus(x1.scaled(t));
    }

    pub fn setval(comptime T: type) fn (*T, T) void {
        return struct {
            pub fn call(ptr: *T, val: T) void {
                ptr.* = val;
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

pub const Motorcycle = enum {
    Nil,
    Nova_Glide,
    Cinder_Wolf_Pro,
    Kawamura_ZX,

    pub fn stats(self: Motorcycle) inventory.Attributes {
        var attrs: inventory.Attributes = .{};
        const fields: [4]inventory.Attribute = .{
            .top_speed,
            .acceleration,
            .armor,
            .impact_damage,
        };

        const got: [4]i16 = switch (self) {
            .Nova_Glide => .{ 10, 0, 8, 2 },
            .Cinder_Wolf_Pro => .{ 5, 8, 14, 12 },
            .Kawamura_ZX => .{ 7, 3, 6, 4 },
            .Nil => .{0} ** 4,
        };
        for (fields, 0..) |field, i| {
            attrs.field(field).* += got[i];
        }
        return attrs;
    }

    pub fn name(self: Motorcycle) []const u8 {
        if (self == .Nil) return "";
        return switch (self) {
            inline else => |tag| {
                const tag_name = @tagName(tag);
                const result = comptime blk: {
                    var buf: [tag_name.len]u8 = undefined;
                    for (&buf, tag_name) |*b, c| {
                        b.* = if (c == '_') ' ' else c;
                    }
                    break :blk buf;
                };
                return &result;
            },
        };
    }
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
    model: Motorcycle = .Nil,

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

    pub fn init_pending_explosion(pos: IVec2, size: u8, dmg: i64) Unit {
        return .{
            .tag = .PendingExplosion,
            .position = pos,
            .render_position = pos.float(),
            .size = size,
            .hp = dmg,
            .alive = true,
        };
    }

    pub fn mounted(self: *const Unit) bool {
        const m = self.mount();
        return m.tag != .Nil and m.alive;
    }

    pub fn init_motorcycle(pos: IVec2, orientation: Dir4, model: Motorcycle, hp: i64) Unit {
        return Unit{
            .tag = .Motorcycle,
            .position = pos,
            .render_position = pos.float(),
            .orientation = orientation,
            .render_orientation = orientation,
            .hp = hp,
            .alive = true,
            .model = model,
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

    pub const Impassable = union(enum) { terrain: IVec2, unit: UnitId };
    pub const CheckWhere = struct {
        pos: IVec2 = .ZERO,
        orientation: Dir4 = .Right,
    };
    pub fn check_passable_full(
        self: *const Unit,
        where: CheckWhere,
    ) ?Impassable {
        const rect = blk: {
            var u: Unit = self.*;
            u.position = where.pos;
            u.orientation = where.orientation;
            break :blk u.get_rect();
        };

        var occupants = sector.get_occupants_rect(rect);
        const id = self.get_id();
        while (occupants.next()) |uid| {
            if (uid == id) {
                continue;
            }

            const u = globals.unit(uid);
            switch (u.tag) {
                .Kaiju, .Player => {
                    return .{ .unit = uid };
                },
                .Motorcycle => {
                    switch (self.tag) {
                        .Motorcycle => return .{ .unit = uid },
                        else => continue,
                    }
                },
                else => continue,
            }
        }
        var it = rect.iter();
        while (it.next()) |pos| {
            const terrain = map.get_terrain_at(pos);
            if (!terrain.unit_passable(self.tag)) {
                return .{ .terrain = pos };
            }
        }
        return null;
    }

    pub fn check_passable(
        self: *const Unit,
        where: CheckWhere,
    ) bool {
        return check_passable_full(self, where) == null;
    }

    pub fn move_to(self: *Unit, pos: IVec2) void {
        const from = self.position.float();
        const to = pos.float();
        const facing = self.position.facing(pos);
        const idist = self.position.max_norm_distance(pos);
        var slide = self.get_rect().slide(facing, idist);

        var halt = false;
        while (slide.next()) |edge| {
            var positions = edge.iter();
            while (positions.next()) |p| {
                const tt = map.get_terrain_at(p);
                if (tt.halting()) {
                    halt = true;
                    if (self.tag == .Player and globals.player().mounted()) {
                        combat_log.log("You drive through the {s}.", .{tt.name()});
                    }
                    _ = animate_terrain_to(p, .floor).chain();
                }
                if (self.tag == .Player) {
                    const r = IRect.singleton(p);
                    var iter = if (self.mounted()) r.expand(1).iter() else r.iter();
                    while (iter.next()) |q| {
                        if (map.get_terrain_at(q) == .trinket) {
                            _ = animate_terrain_to(q, .floor).chain();
                            inventory.add_pending_pickup();
                        }

                        if (map.get_terrain_at(q) == .money) {
                            _ = animate_terrain_to(q, .floor).chain();
                            combat_log.log("You pick up 100 yen", .{});
                            globals.money += 100;
                        }
                    }
                }
            }
            // kaiju crush motorcycles and smashable terrain
            if (self.tag == .Kaiju) {
                var occupants = sector.get_occupants_rect(edge);
                while (occupants.next()) |uid| {
                    const occupant = globals.unit(uid);
                    if (occupant.tag == .Motorcycle) {
                        occupant.hp -= 1;
                    }
                }
                var posit = edge.iter();
                while (posit.next()) |p| {
                    _ = destroy1(p);
                }
            }
        }

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

        var landed = if (self.mounted())
            self.mount().get_rect().iter()
        else
            self.get_rect().iter();
        while (landed.next()) |p| {
            if (map.get_terrain_at(p).halting()) {
                halt = true;
                _ = animate_terrain_to(p, .floor).chain();
            }
        }
        if (halt) {
            self.speed = 0;
            self.mount().speed = 0;
        }
    }
    const Field: type = std.meta.FieldEnum(Unit);

    pub fn deferred_set(self: *Unit, comptime field: Field, val: @TypeOf(@field(self.*, @tagName(field)))) *animation.Animation {
        const name = @tagName(field);
        return globals.animation_queue.force_add(
            .{ .on_wake = .lambda(
                animlib.setval(@TypeOf(@field(self.*, name))),
                .{ &@field(self, name), val },
            ) },
            animation.noop,
            .{},
        );
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
        const id = self.get_id();
        if (self.tag == .Kaiju and self.hp > 0) {
            globals.focus = id;
        }
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
            .Kaiju => {
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
            .PendingExplosion => {
                const r: i16 = @intCast(self.size);
                return core.IRect{
                    .x = self.position.x - r,
                    .y = self.position.y - r,
                    .w = 2 * r + 1,
                    .h = 2 * r + 1,
                };
            },
        }
    }

    pub fn attack_range(self: *const Unit) i16 {
        return self.size / 3;
    }

    pub fn threat(self: *const Unit) [2]core.IRect {
        const r = self.get_rect();
        const reach = self.attack_range();

        return .{ r.expando(.v, reach), r.expando(.h, reach) };
    }

    pub fn handlepos(self: *const Unit) IVec2 {
        return self.position.plus(self.orientation.ivec());
    }

    pub fn move(self: *Unit, dir: Dir4, distance: i16) void {
        const target = self.position.plus(dir.ivec().scaled(distance));
        self.move_to(target);
    }
};

pub const ux = struct {
    pub const InputMode = enum { Movement, Attack };
    pub const Action = union(enum) { move: struct { Dir4, bool }, attack: Dir4, pass: void };
    pub fn resolve_input(key: keyboard.Code, rng: std.Random) ?Action {
        const dir: ?Dir4 = switch (key) {
            .KeyW, .ArrowUp, .KeyK => .Up,
            .KeyA, .ArrowLeft, .KeyH => .Left,
            .KeyS, .ArrowDown, .KeyJ => .Down,
            .KeyD, .ArrowRight, .KeyL => .Right,
            else => null,
        };
        const number: ?usize = switch (key) {
            .Digit1, .Numpad1 => 1,
            .Digit2, .Numpad2 => 2,
            .Digit3, .Numpad3 => 3,
            .Digit4, .Numpad4 => 4,
            .Digit5, .Numpad5 => 5,
            .Digit6, .Numpad6 => 6,
            .Digit7, .Numpad7 => 7,
            .Digit8, .Numpad8 => 8,
            .Digit9, .Numpad9 => 9,
            .Digit0, .Numpad0 => 0,
            else => null,
        };
        const pass: bool = switch (key) {
            .Tab, .ControlRight, .ControlLeft, .AltLeft, .AltRight => {
                globals.animation_queue.hurry(3);
                return null;
            },
            .Space, .Period, .NumpadDecimal => true,
            else => false,
        };

        if (inventory.has_pending_pickups()) {
            if (number) |slot| {
                inventory.overwrite_slot(rng, (slot + 9) % 10);
            }
            if (pass or key == .Escape) {
                inventory.discard_pending(rng);
            }
        } else if (dir) |d| {
            if (inventory.active_weapon()) |_| {
                return .{ .attack = d };
            } else {
                const shift = keyboard.isShiftDown();
                return .{ .move = .{ d, shift } };
            }
        } else if (number) |weapon_id| {
            inventory.toggle_weapon(weapon_id);
        } else if (inventory.active_weapon()) |_| {
            if (key == .Escape) {
                inventory.active_index = null;
            }
        } else if (pass) {
            return .pass;
        }

        return null;
    }
};

pub const GameState = enum {
    TitleScreen,
    MainGame,
    Death,
    Victory,
};

pub const globals = struct {
    pub var units: [5000]Unit = .{Unit.DEFAULT} ** 5000;

    pub var combo_target: ?UnitId = 0;
    pub var combo_count: i64 = 0;
    pub var turn: i64 = 0;
    pub var money: i64 = 1000;
    pub var focus: UnitId = 0;

    pub var danger: u64 = 0;
    pub var animation_queue: animation.Queue = undefined;
    pub var rng: std.Random = undefined;
    pub var gamestate: GameState = .TitleScreen;
    pub var psi: i64 = 0;
    pub var particles: Particles = .{};

    pub fn unit(u: UnitId) *Unit {
        return &units[@intCast(u)];
    }

    pub fn player() *Unit {
        return globals.unit(PLAYER_ID);
    }

    pub fn kmom() *Unit {
        return globals.unit(KMOM_ID);
    }

    pub fn free_unit_id() !UnitId {
        for (units[1..], 1..) |u, i| {
            if (u.tag == .Nil) {
                return @intCast(i);
            }
        }
        return error.OutOfUnitSlots;
    }

    pub fn reset() void {
        units = .{Unit.DEFAULT} ** 5000;

        combo_target = 0;
        combo_count = 0;
        turn = 0;
        money = 1000;
        focus = 0;

        danger = 0;
        animation_queue = undefined;
        rng = undefined;
        gamestate = .TitleScreen;
        psi = 0;
        particles = .{};
    }
};

pub const PLAYER_ID: UnitId = 1;
pub const KMOM_ID: UnitId = 2;
pub const PLAYER_START: IVec2 = .{ .x = 300, .y = 2200 };
pub const KMOM_START: IVec2 = .{ .x = 2300, .y = 200 };

pub fn spawn(u: Unit) !UnitId {
    const id = try globals.free_unit_id();
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
    globals.reset();
    inventory.reset();
    sector.init();
    globals.animation_queue = try animation.Queue.init(std.heap.wasm_allocator, ANIMATION_QUEUE_LEN);
    globals.rng = rng;

    const map_rect: IRect = .{ .x = 0, .y = 0, .w = 2500, .h = 2500 };
    map.new_mapgen(map_rect, .Residential, rng, 0, 25);

    // start within a hundred units or so of PLAYER_START but only if on a road
    const start_radius = 50;
    const num_tries: usize = 1000;
    var start: IVec2 = PLAYER_START;
    for (0..num_tries) |_| {
        const player_x = PLAYER_START.x + rng.intRangeAtMost(i16, -1 * start_radius, start_radius);
        const player_y = PLAYER_START.y + rng.intRangeAtMost(i16, -1 * start_radius, start_radius);
        const pos: IVec2 = .{ .x = player_x, .y = player_y };
        const t: Terrain = map.get_terrain_at(pos);
        if (t == .asphalt or t == .road_paint or t == .road_paint_2) {
            start = pos;
            break;
        }
    }
    globals.units[PLAYER_ID] = .init_player(start);
    sector.add(PLAYER_ID, globals.player());
    globals.units[KMOM_ID] = .init_kaiju(KMOM_START, MOTHER_KAIJU_SIZE);
    sector.add(KMOM_ID, globals.kmom());
    _ = destroy_area(globals.kmom().get_rect().expand(3), rng);

    const moto_id = try spawn(Unit.init_motorcycle(start, .Right, .Nova_Glide, 80));
    globals.player().mounted_on = moto_id;

    inventory.init(rng);
    fov.refresh_fov(globals.player().position, FOV_RANGE);

    var motoplaced: u32 = 0;
    { // place motorcycles
        const placement_attempts = 10;
        const SECTION_COUNT: i16 = 40;
        const SECTION_SIZE: i16 = map.BOUNDS.w / SECTION_COUNT;
        var sections = (IRect{
            .x = 0,
            .y = 0,
            .w = SECTION_COUNT,
            .h = SECTION_COUNT,
        }).iter();
        const rect0 = IRect{ .x = 0, .y = 0, .w = SECTION_SIZE, .h = SECTION_SIZE };

        while (sections.next()) |section| {
            const rect = rect0.displace(section.scaled(SECTION_SIZE));
            for (0..placement_attempts) |_| {
                if (try_place_moto(rect, rng)) {
                    motoplaced += 1;
                    break;
                }
            }
        }
    }
}

fn try_place_moto(rect: IRect, rng: std.Random) bool {
    const pos = rect.roll(rng);
    const face = rng.enumValue(Dir4);
    const pos2 = pos.plus(face.ivec());
    const t1 = map.get_terrain_at(pos);
    const t2 = map.get_terrain_at(pos2);
    if (t1.can_place_moto() and t2.can_place_moto()) {
        const model = blk: {
            const v = std.enums.values(Motorcycle);
            const ix = rng.intRangeAtMost(usize, 1, v.len - 1);
            break :blk v[ix];
        };

        _ = spawn(
            .init_motorcycle(
                pos,
                face,
                model,
                @intCast(inventory.roll_low(rng, 3, 10, 200)),
            ),
        ) catch {
            std.log.err("cant seed initial motorcycle", .{});
            return false;
        };
        return true;
    }
    return false;
}

fn handle_vending(rng: std.Random) bool {
    if (globals.money < 100) {
        combat_log.log("You don't have money for a drink.", .{});
    } else {
        if (rng.float(f32) < 0.05) {
            combat_log.log("The vending machine has run dry.", .{});
            return false;
        }

        combat_log.log("You put money in the vending machine.", .{});
        const healing: i64 = rng.intRangeAtMost(i64, 1, 6);
        const phrase: u8 = rng.intRangeAtMost(u8, 0, 3);
        switch (phrase) {
            0 => combat_log.log("Ramune! You heal {} HP.", .{healing}),
            1 => combat_log.log("Executive Coffee! You heal {} HP.", .{healing}),
            2 => combat_log.log("Cowbliss! You heal {} HP.", .{healing}),
            3 => combat_log.log("D.D. Lime! You heal {} HP.", .{healing}),
            else => unreachable,
        }
        globals.player().hp += healing;

        globals.money -= 100;
    }
    return true;
}

// dir is null when you turn is not an active move, you are maybe just coasting
pub fn handle_player_move(dir: ?Dir4, shift: bool, rng: std.Random) bool {
    const player = globals.player();
    const pmount = player.mount();
    const motostats = pmount.model.stats();
    if (player.mounted()) {
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
                    if (player.check_passable(.{ .pos = path })) {
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
                combat_log.log("You leap off your motorcycle.", .{});
            }

            if (crashed.collided_with) |collision| {
                switch (collision) {
                    .unit => |uid| {
                        const u = globals.unit(uid);
                        switch (u.tag) {
                            .Kaiju => {
                                const base_damage = motostats.effective_value(.impact_damage);
                                const dmg = base_damage * motomove.speed * motomove.speed;
                                combat_log.log("It plows into the beast, dealing {} damage.", .{dmg});
                                u.damage(dmg);
                            },
                            .Motorcycle => {
                                // TODO: what happens when a motorcycle hits another?
                            },
                            else => {},
                        }
                    },
                    .terrain => |where| {
                        const terrain = map.get_terrain_at(where);
                        combat_log.log("The motorcycle hits a {s}.", .{terrain.name()});
                        if (terrain.smash()) |to| {
                            if (motomove.speed > 4) {
                                _ = animate_terrain_to(
                                    where,
                                    to,
                                ).lock_exclusive(pmount.lock());
                            }
                        }
                    },
                }
            }
            const attackroll = rng.intRangeAtMost(i16, 0, 20);
            const armor = motostats.effective_value(.armor);
            const dmg = rng.intRangeAtMost(i64, 1, @max(1, motomove.speed));
            if (attackroll > armor) {
                combat_log.log("The {s} took {} damage.", .{ pmount.model.name(), dmg });
                pmount.damage(dmg);
            } else {
                combat_log.log("The {s} came out unscathed.", .{pmount.model.name()});
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
            const terrain = map.get_terrain_at(target);
            if (!terrain.unit_passable(.Player)) {
                switch (terrain) {
                    .wall => combat_log.log("The wall rejects your advances.", .{}),
                    .void_ => combat_log.log("You're not done yet.", .{}),
                    .window => combat_log.log("The window is cold.", .{}),
                    .vending_machine => {
                        const remaining = handle_vending(rng);
                        if (!remaining) {
                            // TODO: empty vending machine
                            _ = animate_terrain_to(target, .rubble);
                        }
                    },
                    else => combat_log.log("You can't go there", .{}),
                }
                return false;
            }

            var occupants = get_occupants(target);
            while (occupants.next()) |occupant_id| {
                const occupant = globals.unit(occupant_id);
                switch (occupant.tag) {
                    .Motorcycle => { // Mount it
                        player.move_to(occupant.position);
                        player.*.mounted_on = occupant_id;
                        combat_log.log("You start the {s}.", .{occupant.model.name()});
                        return true;
                    },
                    .Kaiju => {
                        // move into kaiju?
                        combat_log.log("You don't like your prospects.", .{});
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

pub fn fire_weapon(aim: IVec2, target: ?*Unit, whiff: bool) bool {
    const weapon = inventory.active_weapon() orelse return false;

    const lock: animation.AnimationLock = .{ .exclusive = globals.player().lock() };
    const ppos = globals.player().position;
    const delta = aim.minus(ppos);
    const d = delta.principal_dir();
    const dir = d.ivec();

    switch (weapon.tag) {
        .Rifle => {
            const glyph: u8 = switch (d.orientation()) {
                .v => 0xB3, // │
                .h => 0xC4, // ─
            };
            var starts = ppos.minus(dir.scaled(4)).scan(d, 8);
            while (starts.next()) |start| {
                send_projectile(.{
                    .from = start.float(),
                    .to = aim.float(),
                    .glyph = glyph,
                    .speed = 70,
                    .color = .red,
                    .start_lock = lock,
                });
            }
        },
        .Gamma_Beam => {
            const glyph: u8 = 'X';
            var starts = ppos.scan(d, delta.max_norm() - 1);
            while (starts.next()) |start| {
                const a = start.float();
                const b = start.plus(dir).float();
                send_projectile(.{
                    .from = a,
                    .to = b,
                    .glyph = glyph,
                    .speed = 0.2,
                    .color = .green,
                    .start_lock = lock,
                });
                send_projectile(.{
                    .from = b,
                    .to = a,
                    .glyph = glyph,
                    .speed = 0.2,
                    .color = .dark_green,
                    .start_lock = lock,
                });
            }
        },
        .Rocket_Launcher => {
            const base_speed: f32 = 10;
            send_projectile(.{
                .from = ppos.float(),
                .to = aim.float(),
                .glyph = 'O',
                .speed = base_speed,
                .color = .white,
                .start_lock = lock,
            });
            for (1..8) |i| {
                const color: RenderBuffer.Color = switch (i) {
                    1, 3 => .red,
                    2, 4, 6 => .orange,
                    else => .dark_gray,
                };
                const j: f32 = @floatFromInt(i);
                const n: f32 = 9;
                send_projectile(.{
                    .from = ppos.float(),
                    .to = aim.float(),
                    .glyph = '%',
                    .speed = n * base_speed / (n + j),
                    .color = color,
                    .start_lock = lock,
                });
            }
        },
        .Psionic_Focus => {
            const anchor = ppos.plus(dir.scaled(SHOT_RANGE));
            const radius = weapon.attrs.effective_value(.psi_radius);
            const base = IRect.singleton(anchor).expando(d.orientation().flip(), radius);
            var it = base.iter();
            while (it.next()) |to| {
                send_projectile(.{
                    .from = ppos.float(),
                    .to = to.float(),
                    .glyph = 0x0F,
                    .color = .purple,
                    .start_lock = lock,
                    .speed = globals.rng.float(f32) * 0.2 + 6,
                });
            }
        },

        else => {},
    }

    if (whiff and weapon.tag != .Psionic_Focus) {
        combat_log.log("You fire off into the distance.", .{});
        globals.combo_count = 0;
        return true;
    }

    const tid: ?UnitId = if (target) |t| t.get_id() else null;

    if (tid != globals.combo_target) {
        globals.combo_count = 0;
    }
    const combo_mul: f64 = std.math.pow(f64, 1.03, @floatFromInt(globals.combo_count));
    const combo_linear: f64 = @floatFromInt(globals.combo_count);
    const crit: f64 = @floatFromInt(crit_bonus());

    const terrain = map.get_terrain_at(aim);
    switch (weapon.tag) {
        .Rifle => {
            const base_damage: f64 = @floatFromInt(weapon.attrs.effective_value(.gun_damage));
            const combo_gain = weapon.attrs.effective_value(.accuracy);
            const damage: f64 = (base_damage + combo_linear) * combo_mul * crit;
            const idamage: i64 = @as(i64, @intFromFloat(@trunc(damage)));
            globals.combo_target = tid;
            if (target) |u| {
                u.damage(idamage);
                globals.combo_count += combo_gain;
                combat_log.log("The rifle round deals {} damage. You dial in your next shot.", .{idamage});
            } else {
                combat_log.log("You shoot the {s}.", .{terrain.name()});
            }
        },
        .Rocket_Launcher => {
            const base_damage: f64 = @floatFromInt(weapon.attrs.effective_value(.explosion_damage));
            const radius: u8 = @intCast(weapon.attrs.effective_value(.explosion_radius));
            const damage: f64 = (base_damage + combo_linear) * combo_mul * crit;
            const idamage: i64 = @as(i64, @intFromFloat(@trunc(damage)));
            _ = spawn(.init_pending_explosion(aim, radius, idamage)) catch {
                std.log.err("out of unit slots? cant fire missiles!", .{});
                return true;
            };
            combat_log.log("You fire a rocket.", .{});
        },
        .Psionic_Focus => {
            const base_damage: f64 = @floatFromInt(globals.psi);
            const radius: u8 = @intCast(weapon.attrs.effective_value(.psi_radius));
            const damage: f64 = (base_damage + combo_linear) * combo_mul * crit;
            const idamage: i64 = @as(i64, @intFromFloat(@trunc(damage)));

            const target_pos: IVec2 = ppos.plus(dir.scaled(SHOT_RANGE));
            globals.combo_count = 0;
            handle_psychic_damage(target_pos, radius, idamage);
        },
        .Gamma_Beam => {
            const u = target orelse {
                combat_log.log("You shoot the {s}.", .{terrain.name()});
                return true;
            };
            const base_damage: f64 = @floatFromInt(weapon.attrs.effective_value(.radiation_damage));
            const multiplied = (base_damage + combo_linear) * combo_mul * crit;
            const decay = 1 - std.math.pow(f64, 0.99, multiplied);
            const hp: f64 = @floatFromInt(u.hp);
            const damage = decay * hp;
            const idamage: i64 = @as(i64, @intFromFloat(@trunc(damage)));
            u.damage(idamage);
            combat_log.log("The gamma ray deals {} damage.", .{idamage});
        },
        else => {
            return false;
        },
    }
    return true;
}

fn handle_psychic_damage(target_pos: IVec2, radius: i16, damage: i64) void {
    var cone = core.cone_iter(globals.player().position, target_pos, radius);
    var i: usize = 0;
    var candidate_kaiju: [100]UnitId = .{0} ** 100;
    var resonance = false;

    while (cone.next()) |pos| {
        var occupants = get_occupants(pos);
        while (occupants.next()) |id| {
            const unit = globals.unit(id);
            if (unit.tag == .Kaiju) {
                candidate_kaiju[i] = id;
                i += 1;
            }
        }
    }

    // dedup and do_damage
    std.mem.sort(UnitId, candidate_kaiju[0..i], {}, comptime std.sort.desc(UnitId));
    var previous: UnitId = 0;
    for (candidate_kaiju[0..i]) |k_id| {
        if (k_id == previous) {
            continue;
        }
        if (k_id == 0) {
            break;
        }
        if (!resonance) {
            combat_log.log("You unleash a psychic blast.", .{});
            resonance = true;
        }
        previous = k_id;
        resonance = true;
        combat_log.log("The monster takes {} psychic damage.", .{damage});
        globals.units[k_id].damage(damage);
    }

    if (!resonance) {
        combat_log.log("You lash out with psychic energy, but feel no resonance.", .{});
    }
}

pub fn handle_player_attack(dir: Dir4) bool {
    var scan = globals.player().position.scan(dir, SHOT_RANGE);
    while (scan.next()) |aim| {
        const terrain = map.get_terrain_at(aim);
        if (terrain.blocks_shot()) {
            // you shoot at the terrain
            // consequences TBD
            globals.combo_count = 0;
            return fire_weapon(aim, null, false);
        }
        var aim_occupants = get_occupants(aim);
        while (aim_occupants.next()) |occupant_id| {
            const unit = globals.unit(occupant_id);
            if (unit.tag == .Kaiju) {
                return fire_weapon(aim, unit, false);
            }
        }
    }
    const aim = globals.player().position.plus(dir.ivec().scaled(SHOT_RANGE));
    return fire_weapon(aim, null, true);
}

pub fn logic_tick(key: keyboard.Code, rng: std.Random) void {
    var player_acted = false;
    const player_start = globals.player().position;
    if (globals.player().hp <= 0) {
        return;
    }

    if (ux.resolve_input(key, rng)) |action| {
        globals.animation_queue.hurry(1.5);
        switch (action) {
            .pass => {
                player_acted = true;
                _ = handle_player_move(null, false, rng);
            },
            .move => |movedata| {
                const d, const shift = movedata;
                player_acted = handle_player_move(d, shift, rng);
                if (player_acted) {
                    globals.combo_target = 0;
                }
                globals.combo_count = 0;
            },
            .attack => |d| {
                player_acted = handle_player_attack(d);
                if (player_acted) {
                    _ = handle_player_move(null, false, rng);
                    // TODO: motorcycle with speed moves
                }
            },
        }
    }
    if (player_acted) {
        resolve_pending(rng);
        const player_end = globals.player().position;
        const travel_distance: u64 = @intCast(player_start.max_norm_distance(player_end));
        globals.danger += (travel_distance + 1) * danger_growth(player_end);
        globals.turn += 1;

        tick_kaiju(rng);

        if (roll_new_enemy(rng)) |spawn_rect| {
            new_kaiju(spawn_rect, rng) catch {
                std.log.err("failed to spawn enemy at {}", .{spawn_rect});
            };
        }

        units_cleanup(rng);
        decay_psi();

        fov.refresh_fov(globals.player().position, FOV_RANGE);
        inventory.handle_pending_pickups(rng);
    }
}

fn decay_psi() void {
    const psi: f64 = @floatFromInt(globals.psi);
    const reservoir: f64 = @floatFromInt(inventory.bonuses().readfield(.psi_reservoir));
    const base_decay = 0.95;
    const effective_decay = std.math.pow(f64, base_decay, 1 / reservoir);
    const result = psi * effective_decay;
    globals.psi = @intFromFloat(@ceil(result));
}

pub fn crit_bonus() i64 {
    const bonuses = inventory.bonuses();
    var mul: i64 = 1;
    if (@mod(globals.turn, 3) == 0) {
        mul *= bonuses.readfield(.crit3_bonus) + 1;
    }
    if (@mod(globals.turn, 4) == 0) {
        mul *= bonuses.readfield(.crit4_bonus) + 1;
    }
    if (@mod(globals.turn, 5) == 0) {
        mul *= bonuses.readfield(.crit5_bonus) + 1;
    }
    return mul;
}

fn set_terrain(pos: IVec2, terrain: Terrain) void {
    if (map.map_index(pos)) |ix| {
        if (map.mapdata[ix].is_masked) {
            _ = animate_terrain_to(pos, terrain);
            return;
        }
    }
    map.set_terrain_at(pos, terrain);
}

fn animate_terrain_to(pos: IVec2, terrain: Terrain) *animation.Animation {
    const prev_terrain = map.get_render_terrain_at(pos);
    // update the real terrain state
    map.set_terrain_at(pos, terrain);
    // hide it with a fake image
    map.set_render_terrain_at(pos, prev_terrain);
    return globals.animation_queue.force_add_empty(.{
        .lock_exclusive = animlib.lock_position(pos),
        .on_wake = .lambda(map.set_render_terrain_at, .{ pos, terrain }),
    });
}

fn resolve_pending(rng: std.Random) void {
    for (globals.units[1..]) |*u| {
        switch (u.tag) {
            .PendingRubble => {
                const terrain: Terrain = if (rng.float(f32) < 0.9) .debris else .rubble;
                const pos = u.position;
                unspawn(u);
                _ = animate_terrain_to(pos, terrain).chain();

                var player: *Unit = globals.player();
                const moto: ?*Unit = if (player.mounted()) player.mount() else null;
                if (pos.eq(player.position)) {
                    const dmg = rng.intRangeAtMost(i64, 1, 6);
                    combat_log.log("You take {} damage from falling debris", .{dmg});
                    player.damage(dmg);
                } else if (moto) |m| {
                    const dmg = rng.intRangeAtMost(i64, 1, 6);
                    if (m.get_rect().contains(pos)) {
                        m.damage(dmg);
                    }
                }
            },
            .PendingExplosion => {
                if (u.alive) {
                    u.alive = false;
                } else {
                    const radius: i16 = @intCast(u.size);
                    var iter = sector.get_occupants_rect(u.get_rect());
                    while (iter.next()) |tid| {
                        const target = globals.unit(tid);
                        const impact = target.get_rect().count_overlap(u.position, radius);
                        if (impact == 0) {
                            continue;
                        }
                        const damage = impact * u.hp;
                        switch (target.tag) {
                            .Kaiju => {
                                combat_log.log("The explosion deals {} damage to the monster.", .{damage});
                                target.damage(damage);
                            },
                            .Motorcycle => {
                                const roll = rng.intRangeAtMost(i16, 1, 20);
                                if (roll > target.model.stats().readfield(.armor)) {
                                    const max = @as(i64, @intCast(impact)) * 3;
                                    const dmg = rng.intRangeAtMost(i64, 0, max);
                                    combat_log.log("The explosion deals {} damage to the {s}", .{ dmg, target.model.name() });
                                    target.damage(dmg);
                                }
                            },
                            .Player => {
                                const knockdir = target.position.minus(u.position).principal_dir();
                                combat_log.log("You are caught in the blast.", .{});
                                smack_player(knockdir, rng, damage);
                            },
                            else => {},
                        }
                    }
                    var iterloc = u.get_rect().iter();
                    while (iterloc.next()) |p| {
                        if (p.manhattan_distance(u.position) <= radius) {
                            const roll = rng.intRangeAtMost(u8, 1, 20);
                            if (roll == 20) {
                                _ = destroy1(p);
                            }
                        }
                    }

                    unspawn(u);
                }
            },
            else => {},
        }
    }
}

fn destroy_area(target: IRect, rng: std.Random) bool {
    var any = false;
    var it = target.iter();
    while (it.next()) |pos| {
        any = any or destroy(pos, rng);
    }
    return any;
}

fn new_kaiju(target: IRect, rng: std.Random) !void {
    const size = target.w;
    _ = destroy_area(target.expand(@divTrunc(size, 2)), rng);
    _ = try spawn(.init_kaiju(target.ivec(), @intCast(size)));
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
                        tp.terrain = .viscera;
                    }

                    map.set_terrain_payload_at(pos, tp);
                    map.set_render_terrain_payload_at(pos, prev);
                },
                .followup => {
                    // make the displayed terrain bloody
                    var tp = map.get_render_terrain_payload_at(pos);
                    tp.bloody = true;
                    if (viscera) {
                        tp.terrain = .viscera;
                    }
                    map.set_render_terrain_payload_at(pos, tp);
                },
            }
        }
    }
}

pub fn trigger_victory() void {
    combat_log.log("You have finally put down the menace.", .{});
    combat_log.log("Press the R key to go back to the title screen.", .{});
    globals.gamestate = .Victory;
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
                    combat_log.log("The monster is slain!", .{});
                    do_splatter(splatter_zone, seed, .initial);
                    const callback: Callback = .lambda(do_splatter, .{ splatter_zone, seed, .followup });
                    _ = globals.animation_queue.force_add_empty(.{ .on_wake = callback, .chain = true });

                    if (u.size == MOTHER_KAIJU_SIZE) {
                        trigger_victory();
                    }
                    if (u.hp < 0 and inventory.has_psi()) {
                        globals.psi -= u.hp;
                    }

                    const leveled_up = inventory.extend_item_capacity(u.size);
                    if (leveled_up) {
                        combat_log.log("You feel stronger after felling a powerful foe.", .{});
                        combat_log.log("Inventory size increased to {}.", .{inventory.item_capacity});
                    }
                    return;
                },
                .Motorcycle => {
                    var it = u.get_rect().iter();
                    while (it.next()) |pos| {
                        _ = animate_terrain_to(pos, .debris);
                    }
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
    const roll: u64 = blk: {
        var z: u64 = std.math.maxInt(u64);
        for (0..3) |_| {
            z = @min(z, rng.int(u64) % SPAWN_ROLL);
        }
        break :blk z;
    };

    const active_threat: u64 = blk: {
        var count: u64 = 0;
        const nearby = player.get_rect().expand(30);
        var it = sector.get_occupants_rect(nearby);
        while (it.next()) |uid| {
            const u = globals.unit(uid);
            if (u.tag == .Kaiju) {
                count += u.size * u.size;
            }
        }
        break :blk count * 1000;
    };

    if (roll + active_threat > globals.danger) {
        return null;
    }
    // how far away they can spawn
    const RADIUS: i16 = 90;
    // how close they can spawn
    const MIN_RADIUS: i16 = 50;
    // how much the candidate spawn zone moves in
    // the direction of travel
    const SHIFT: i16 = 60;
    const size_roll: u8 = @clz(rng.int(u32));
    const size: i16 = @as(i16, @min(size_roll + MIN_KAIJU_SIZE, MOTHER_KAIJU_SIZE - 1));

    var arena: IRect = (IRect{
        .x = player.position.x - RADIUS,
        .y = player.position.y - RADIUS,
        .w = 2 * RADIUS + 1 - (size - 1),
        .h = 2 * RADIUS + 1 - (size - 1),
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
        IVec2.ONE.scaled(size),
    );
    if (target_rect.point_distance(player.position).max_norm() < MIN_RADIUS) {
        return null;
    }

    if (!map.BOUNDS.contains_rect(target_rect)) {
        return null;
    }

    globals.danger = 0;
    return target_rect;
}

// destroys wall
fn destroy_wall(demolitionist: *const Unit, dir: Dir4, rng: std.Random) void {
    var wall_iter = demolitionist.get_rect().slide(dir, 1);

    // destroy the wall
    while (wall_iter.next()) |wall| {
        var boom_iter = wall.iter();
        while (boom_iter.next()) |boom_coord| {
            _ = destroy(boom_coord, rng);
        }
    }

    // spawn pending rubble
    const maxrng = 5 * @as(i16, @intCast(demolitionist.size));
    const fling_distance: i16 = rng.intRangeAtMost(i16, 6, maxrng);
    const rubble_spawn_chance: f32 = 0.03;
    var rubble_iter = demolitionist.get_rect().expand(demolitionist.size / 2).slide(dir, fling_distance);
    while (rubble_iter.next()) |front| {
        var front_iter = front.iter();
        while (front_iter.next()) |pos| {
            if (rng.float(f32) < rubble_spawn_chance) {
                const pr: Unit = Unit.init_pending_destruction(pos);
                _ = spawn(pr) catch {
                    std.log.err("no room for rubble", .{});
                };
            }
        }
    }
}
fn harm(damage: i64) void {
    const player = globals.player();
    combat_log.log("You are hit for {} damage.", .{damage});

    const safe = player.hp > 1;
    player.hp -= damage;
    if (safe) {
        if (player.hp < 1) {
            combat_log.log("You barely survive.", .{});
        }

        player.hp = @max(player.hp, 1);
    }
}

fn destroy1(pos: IVec2) bool {
    if (map.get_terrain_at(pos).smash()) |to| {
        _ = set_terrain(pos, to);
        return true;
    }
    return false;
}

fn destroy(pos: IVec2, rng: std.Random) bool {
    const count = rng.intRangeAtMost(usize, 1, 2);
    var any = false;
    for (0..count) |_| {
        any = any or destroy1(pos);
    }
    return any;
}

fn smack_player(dir: Dir4, rng: std.Random, damage: i64) void {
    const fling_distance: i16 = 10;
    var player = globals.player();
    const moto: ?*Unit = if (player.mounted()) player.mount() else null;
    if (globals.player().hp <= 1) {
        globals.player().hp = 0;
        const splatter_zone = globals.player().get_rect().expand(1);
        const seed = rng.int(u16);
        do_splatter(splatter_zone, seed, .initial);
        const callback: Callback = .lambda(do_splatter, .{ splatter_zone, seed, .followup });
        _ = globals.animation_queue.force_add_empty(.{ .on_wake = callback, .chain = true });
        combat_log.log("You have been killed.", .{});
        combat_log.log("Press R to restart.", .{});
        globals.gamestate = .Death;
    } else {
        harm(damage);

        // fling player
        combat_log.log("You are sent flying!", .{});
        const fling_rect: IRect = if (moto) |m| m.get_rect() else player.get_rect();
        var fling_iter = fling_rect.slide(dir, fling_distance);
        var flung: i16 = 0;
        var destroyed = false;
        outer: while (fling_iter.next()) |fling_slice| {
            var iter = fling_slice.iter();
            while (iter.next()) |pos| {
                const terrain = map.get_terrain_at(pos);
                if (terrain == .void_) {
                    break :outer;
                }

                destroyed = destroyed or destroy(pos, rng);
                destroyed = destroyed or destroy(pos, rng);
            }
            flung += 1;
        }
        if (destroyed) {
            combat_log.log("Smash!!", .{});
        }
        const target: IVec2 = player.position.plus(dir.ivec().scaled(flung));
        globals.player().move_to(target);
        if (moto) |m| {
            m.move_to(target);
            m.speed = 0;
        }
    }
}

const KaijuLook = struct {
    distance: i16 = 0,
    position: IVec2 = .DEFAULT,
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
                result.position = pos;
                return result;
            }
        }
        var occupant_iter = sector.get_occupants_rect(edge);
        while (occupant_iter.next()) |uid| {
            const u = globals.unit(uid);
            switch (u.tag) {
                .Kaiju, .Player => {
                    result.unit = uid;
                    result.position = u.position;
                    return result;
                },
                .Motorcycle => {
                    if (uid == globals.player().mounted_on) {
                        result.unit = uid;
                        const r = u.get_rect().intersection(edge);
                        result.position = r.ivec();
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
    const r = k.get_rect();
    const player = globals.player();

    const prect = if (player.mounted()) player.mount().get_rect() else player.get_rect();
    const halign = r.vertical().overlap(prect.vertical());
    const valign = r.horizontal().overlap(prect.horizontal());

    const dir = blk: {
        const dx: Dir4 = if (r.x < prect.x) .Right else .Left;
        const dy: Dir4 = if (r.y < prect.y) .Down else .Up;
        if (halign) {
            break :blk dx;
        }
        if (valign) {
            break :blk dy;
        }
        if (rng.boolean()) {
            break :blk dx;
        } else {
            break :blk dy;
        }
    };

    // const dir: Dir4 = k.position.facing(globals.player().position);
    const seen = kaiju_look(k, dir, k.size);
    if (seen.terrain) |_| {
        if (seen.distance == 0) {
            destroy_wall(k, dir, rng);
            return;
        }
    } else if (seen.unit) |u| {
        switch (globals.unit(u).tag) {
            .Player, .Motorcycle => {
                for (k.threat()) |threat_rect| {
                    if (threat_rect.contains(seen.position)) {
                        smack_player(dir, rng, k.hp);
                        return;
                    }
                }
            },
            else => {},
        }
    }
    k.move(dir, seen.distance);
}

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

pub const CrashInfo = struct {
    position: IVec2,
    orientation: Dir4,
    fling: bool = false,
    collided_with: ?Unit.Impassable = null,
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
            if (!moto.check_passable(.{ .pos = p, .orientation = move.orientation })) {
                // we shouldnt end up here
                std.log.err("unhandled movement case", .{});
                unreachable;
            }
            cursor.position = p;
            cursor.orientation = move.orientation;
        }
        const steps: usize = @intCast(delta.max_norm());
        for (0..steps) |_| {
            const next = cursor.position.plus(v);
            if (moto.check_passable_full(.{ .pos = next, .orientation = cursor.orientation })) |impassable| {
                cursor.collided_with = impassable;
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
            if (!shifted and !moto.check_passable(.{ .pos = next, .orientation = moto.orientation })) {
                next = next.plus(secondary_vector);
                shifted = true;
            }
            if (moto.check_passable_full(.{ .pos = next, .orientation = moto.orientation })) |impassable| {
                cursor.collided_with = impassable;
                return cursor;
            }

            cursor.position = next;
        }
        if (!shifted) {
            const final = cursor.position.plus(secondary_vector);
            if (moto.check_passable_full(.{ .pos = final, .orientation = moto.orientation })) |impassable| {
                cursor.collided_with = impassable;
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
        if (moto.check_passable_full(.{ .pos = next, .orientation = o })) |impassable| {
            cursor.collided_with = impassable;
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
            if (moto.check_passable_full(.{ .pos = next, .orientation = move.orientation })) |impassable| {
                cursor.collided_with = impassable;
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

    const stats = globals.player().mount().model.stats();
    const acc: u8 = @intCast(stats.effective_value(.acceleration));
    const maxspd: u8 = @intCast(stats.effective_value(.top_speed));

    switch (core.RelativeDir.from(change, moto.orientation)) {
        .Forward => {
            // accelerate!

            const more_accel: u8 = if (it.speed < acc) 1 else 0;
            it.speed = @min(it.speed + 1 + more_accel, maxspd);
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
                    combat_log.log("You dismount the motorcycle.", .{});
                }
            } else { // turn!
                const turned_speed = blk: {
                    if (moto.speed > slide_dist) {
                        break :blk moto.speed - slide_dist;
                    } else {
                        break :blk 0;
                    }
                };
                const more_accel: u8 = if (turned_speed < (acc / 2)) 1 else 0;
                const pre_drift = moto.orientation.ivec().scaled(@intCast(slide_dist));
                it.midpoint = it.position.plus(pre_drift);
                const post_drift = change.ivec().scaled(@intCast(turned_speed));
                it.position = it.midpoint.plus(post_drift);
                it.speed = @max(1, turned_speed + more_accel);
                it.orientation = change;
            }
        },
        .Reverse => { // brake!
            it.brake = true;
            if (move.shift) {
                if (it.speed > 0) {
                    // slight brake
                    it.speed -= 1;
                    const amount: i16 = @intCast(it.speed);
                    const drift = moto.orientation.ivec()
                        .scaled(@max(amount, 2))
                        .plus(change.ivec());
                    it.position = it.position.plus(drift);
                } else {
                    // dismount
                    it.dismount = true;
                    combat_log.log("You dismount the motorcycle.", .{});
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
                const slideface = moto.orientation.turn(.Left);
                const slidestart = moto.handlepos().minus(slideface.ivec());
                if (slide_dist >= 2 and moto.check_passable(.{ .pos = slidestart, .orientation = slideface })) {
                    it.slide = true;
                    it.position = it.position.plus(it.orientation.ivec());
                    it.orientation = slideface;
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

    const prj = resolve_motorcycle_movement(mount, .{});
    const hpos = prj.position.plus(prj.orientation.ivec());
    var result: [5]IVec2 = .{hpos} ** 5;

    if (inventory.active_weapon() == null) {
        for (std.enums.values(Dir4), 0..) |d, i| {
            const projection = resolve_motorcycle_movement(mount, .{ .dir = d });
            const ppos = projection.position;
            const handlepos = ppos.plus(projection.orientation.ivec());
            result[i] = handlepos;
        }
    }

    return result;
}

pub const Particle = struct {
    pending: bool = false,
    active: bool = false,
    pos: Vec2 = .ZERO,
    color: RenderBuffer.Color = .black,
    glyph: u8 = 'o',

    pub fn release(self: *Particle) void {
        self.pending = false;
        self.active = false;
    }

    pub fn wake(self: *Particle) void {
        self.active = true;
    }
};

pub const Particles = struct {
    data: [200]Particle = .{Particle{}} ** 200,

    pub fn clear(self: *Particles) void {
        self.* = .{};
    }

    pub fn free_id(self: *const Particles) !usize {
        for (self.data, 0..) |it, ix| {
            if (!it.pending) {
                return ix;
            }
        }
        return error.OutOfSlots;
    }
};

pub fn send_projectile(opts: struct {
    from: Vec2,
    to: Vec2,
    glyph: u8 = 'o',
    color: RenderBuffer.Color = .black,
    speed: f32 = 1,
    start_lock: animation.AnimationLock = .EMPTY,
}) void {
    const ix = globals.particles.free_id() catch {
        std.log.err("no particle slots", .{});
        return;
    };
    var it = &globals.particles.data[ix];
    it.glyph = opts.glyph;
    it.color = opts.color;
    it.pending = true;
    const duration = opts.from.distance(opts.to) * 100 / opts.speed;
    var anim = globals.animation_queue.add(.{
        .duration = duration,
        .on_wake = .lambda(Particle.wake, .{it}),
        .on_finish = .lambda(Particle.release, .{it}),
    }, animlib.linear_slide, .{ opts.from, opts.to, &it.pos }) catch {
        return;
    };
    anim.lock_until_start = opts.start_lock;
}

test {
    std.testing.refAllDecls(@This());
}
