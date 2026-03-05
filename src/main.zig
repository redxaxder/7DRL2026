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

const FOV_RANGE = 40;
const DANGER_GROWTH = 90;
// const DANGER_GROWTH = 0;
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

    pub fn init_motorcycle(pos: IVec2, orientation: Dir4, model: Motorcycle) Unit {
        return Unit{
            .tag = .Motorcycle,
            .position = pos,
            .render_position = pos.float(),
            .orientation = orientation,
            .render_orientation = orientation,
            .hp = 80,
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
                if (map.get_terrain_at(p).halting()) {
                    halt = true;
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
                            globals.money += 1000;
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
            .KeyW, .ArrowUp => .Up,
            .KeyA, .ArrowLeft => .Left,
            .KeyS, .ArrowDown => .Down,
            .KeyD, .ArrowRight => .Right,
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
            .Space, .Period => true,
            else => false,
        };

        if (inventory.has_pending_pickups()) {
            if (number) |slot| {
                inventory.overwrite_slot(rng, (slot + 9) % 10);
            }
            if (pass) {
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
        }

        return null;
    }
};

pub const globals = struct {
    pub var units: [2000]Unit = .{Unit.DEFAULT} ** 2000;

    pub var combo_target: ?UnitId = 0;
    pub var combo_count: i64 = 0;
    pub var turn: i64 = 0;
    pub var money = 0;

    pub var danger: u64 = 0;
    pub var animation_queue: animation.Queue = undefined;
    pub var rng: std.Random = undefined;

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
};

pub const PLAYER_ID: UnitId = 1;
pub const KMOM_ID: UnitId = 2;
pub const PLAYER_START: IVec2 = .{ .x = 200, .y = 2300 };
pub const KMOM_START: IVec2 = .{ .x = 2300, .y = 200 };

pub fn spawn(u: Unit) !UnitId {
    const id = try globals.free_unit_id();
    globals.unit(id).* = u;
    sector.add(id, globals.unit(id));

    std.log.info("spawn {}", .{u.tag});
    return id;
}

pub fn unspawn(u: *Unit) void {
    std.log.info("unspawn {}", .{u.tag});

    const anim = u.deferred_set(.tag, .Nil);
    _ = anim.lock_exclusive(u.lock())
        .lock_exclusive(animlib.lock_rect(u.get_rect()));
}

pub fn init(rng: std.Random) !void {
    sector.init();
    globals.animation_queue = try animation.Queue.init(std.heap.wasm_allocator, ANIMATION_QUEUE_LEN);
    globals.rng = rng;

    const map_rect: IRect = .{ .x = 0, .y = 0, .w = 2500, .h = 2500 };
    map.new_mapgen(map_rect, .Residential, rng, 0, 25);
    // map.mapgen(rng);

    globals.units[PLAYER_ID] = .init_player(PLAYER_START);
    sector.add(PLAYER_ID, globals.player());
    {
        var it = globals.player().get_rect().expand(3).iter();
        while (it.next()) |pos| {
            map.set_terrain_at(pos, .grass);
        }
    }
    globals.units[KMOM_ID] = .init_kaiju(KMOM_START, MOTHER_KAIJU_SIZE);
    sector.add(KMOM_ID, globals.kmom());
    _ = destroy_area(globals.kmom().get_rect().expand(3), rng);

    const moto_id = try spawn(Unit.init_motorcycle(PLAYER_START, .Right, .Kawamura_ZX));
    globals.player().mounted_on = moto_id;

    inventory.init(rng);
    fov.refresh_fov(globals.player().position, FOV_RANGE);

    map.set_render_terrain_at(IVec2.ONE.scaled(7), Terrain.void_);
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
                combat_log.log("You leap off the motorcycle.", .{});
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
                        combat_log.log("It plows into the {s}.", .{terrain.name()});
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
                    else => combat_log.log("Can't go there", .{}),
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

pub fn fire_weapon(aim: IVec2, target: ?*Unit) bool {
    const weapon = inventory.active_weapon() orelse return false;

    const tid: ?UnitId = if (target) |t| t.get_id() else null;

    if (tid != globals.combo_target) {
        globals.combo_count = 0;
    }
    const combo_mul: f64 = std.math.pow(f64, 1.03, @floatFromInt(globals.combo_count));
    const combo_linear: f64 = @floatFromInt(globals.combo_count);
    const crit: f64 = @floatFromInt(crit_bonus());

    // combat_log.log("You shoot the {s}.", .{terrain.name()});

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
        .Gamma_Beam => {
            const u = target orelse {
                combat_log.log("You shoot the {s}.", .{terrain.name()});
                return true;
            };
            const base_damage: f64 = @floatFromInt(weapon.attrs.effective_value(.radioactive_damage));
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

pub fn handle_player_attack(dir: Dir4) bool {
    var scan = globals.player().position.scan(dir, SHOT_RANGE);
    while (scan.next()) |aim| {
        const terrain = map.get_terrain_at(aim);
        if (terrain.blocks_shot()) {
            // you shoot at the terrain
            // consequences TBD
            globals.combo_count = 0;
            return fire_weapon(aim, null);
        }
        var aim_occupants = get_occupants(aim);
        while (aim_occupants.next()) |occupant_id| {
            const unit = globals.unit(occupant_id);
            if (unit.tag == .Kaiju) {
                return fire_weapon(aim, unit);
            }
        }
    }
    combat_log.log("You fire off into the distance.", .{});
    globals.combo_count = 0;
    return true;
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
        // TODO: vary danger growth by location
        globals.danger += (travel_distance + 1) * DANGER_GROWTH;
        globals.turn += 1;

        tick_kaiju(rng);

        if (roll_new_enemy(rng)) |spawn_rect| {
            new_kaiju(spawn_rect, rng) catch {
                std.log.err("failed to spawn enemy at {}", .{spawn_rect});
            };
        }

        units_cleanup(rng);

        fov.refresh_fov(globals.player().position, FOV_RANGE);
        inventory.handle_pending_pickups(rng);
    }
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
    // TODO this could be more efficient
    for (globals.units[1..]) |*u| {
        switch (u.tag) {
            .PendingRubble => {
                const terrain: Terrain = if (rng.boolean()) .debris else .rubble;
                const pos = u.position;
                unspawn(u);
                _ = animate_terrain_to(pos, terrain).chain();

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
                                    combat_log.log("The {s} is caught in the blast. It takes {} damage.", .{ target.model.name(), dmg });
                                    target.damage(dmg);
                                }
                            },
                            .Player => {
                                // const knockdir =
                                // TODO: handle explosion hurting player
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
    // TBD
    //
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
            if (map.get_terrain_at(boom_coord) == .wall) {
                const terrain: Terrain = if (rng.boolean()) .rubble else .debris;
                _ = animate_terrain_to(boom_coord, terrain).chain();
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
                _ = spawn(pr) catch {
                    std.log.err("no room for rubble", .{});
                };
            }
        }
    }
}
fn harm() void {
    globals.player().hp = 1;
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

fn smack_player(dir: Dir4, rng: std.Random) void {
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
    } else {
        harm();

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
    const attack_range = k.size / 3;
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

test {
    std.testing.refAllDecls(@This());
}
