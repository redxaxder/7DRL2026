const std = @import("std");
const lib = @import("_7DRL2026");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const RenderBuffer = @import("render.zig");
const Sprite = RenderBuffer.Sprite;
const map = @import("map.zig");
const Terrain = map.Terrain;
const core = @import("core.zig");
const IVec2 = core.IVec2;
const Dir4 = core.Dir4;
const Vec2 = core.Vec2;
const Rect = core.Rect;

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
    position: IVec2 = IVec2.default,
    render_position: Vec2 = Vec2.default,

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
            .render_position = pos.float(),
        };
    }
    pub fn init_motorcycle(pos: IVec2, orientation: Dir4) Unit {
        return Unit{
            .tag = .Motorcycle,
            .position = pos,
            .render_position = pos.float(),
            .orientation = orientation,
        };
    }

    pub fn init_kaiju(pos: IVec2, size: u8) Unit {
        return .{
            .tag = .Kaiju,
            .position = pos,
            .render_position = pos.float(),
            .size = size,
        };
    }

    pub inline fn occupies(self: *const @This(), pos: IVec2) bool {
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

    pub fn move_to(self: *@This(), pos: IVec2) void {
        self.position = pos;
        self.render_position = pos.float();
    }

    pub fn mount(self: *const @This()) *Unit {
        return globals.unit(self.mounted_on);
    }

    pub fn handlepos(self: *const @This()) IVec2 {
        return self.position.plus(self.orientation.ivec());
    }

    pub fn move(self: *@This(), dir: Dir4) void {
        if (self.tag == .Kaiju) {
            const target = self.position.plus(dir.ivec().scaled(self.size));
            self.move_to(target);
        }
    }
};

pub fn get_terrain_at(position: IVec2) ?Terrain {
    const ix = map.map_index(position) orelse return null;
    return globals.mapdata[ix];
}

pub const globals = struct {
    pub var units: [2000]Unit = .{Unit.default} ** 2000;
    pub var mapdata: [map.MAPDATA_LEN]Terrain = .{.Floor} ** map.MAPDATA_LEN;

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

pub fn init(rng: std.Random) !void {
    globals.player().* = .init_player(IVec2.zero);
    const moto_id = globals.free_unit_id() orelse @panic("how did we run out so fast");
    globals.unit(moto_id).* = .init_motorcycle(IVec2.zero, .Right);
    globals.player().mounted_on = moto_id;
    const kaiju_id = globals.free_unit_id() orelse @panic("how did we run out so fast");
    globals.unit(kaiju_id).* = .init_kaiju(
        IVec2{ .x = 6, .y = 6 },
        3,
    );

    const big_kaiju_id = globals.free_unit_id() orelse @panic("how did we run out so fast");
    globals.unit(big_kaiju_id).* = .init_kaiju(
        IVec2{ .x = 9, .y = 18 },
        5,
    );
    map.mapgen(rng, &globals.mapdata);
}

pub fn logic_tick(key: keyboard.Code, rng: std.Random) void {
    var player_acted = false;
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
            const motomove = resolve_motorcycle_movement(
                pmount,
                .{
                    .dir = d,
                    .shift = keyboard.isShiftDown(),
                },
            );
            if (motomove.dismount) {
                player.move_to(motomove.position);
                player.*.mounted_on = 0;
            } else if (crash_check(pmount, motomove)) |crashed| {
                pmount.move_to(crashed.position);
                pmount.*.orientation = crashed.orientation;
                pmount.*.speed = 0;
                if (motomove.brake) {
                    player.*.move_to(pmount.position);
                } else {
                    player.*.mounted_on = 0;
                }
                if (crashed.fling) {
                    const delta = motomove.midpoint.minus(player.position);
                    // TODO: slide player toward this position instead  (ie interrupted by obstacles) instead of assigning it
                    player.move_to(motomove.midpoint.plus(delta));
                }
            } else {
                pmount.*.orientation = motomove.orientation;
                pmount.*.speed = motomove.speed;
                pmount.move_to(motomove.position);
                player.move_to(motomove.position);
            }
        } else {
            // unmounted movement
            const dv = d.ivec();
            const target = player.position.plus(dv);

            if (get_occupant(target)) |occupant_id| {
                const occupant = globals.unit(occupant_id);
                if (occupant.tag == .Motorcycle) { // Mount it
                    player.move_to(occupant.position);
                    player.*.mounted_on = occupant_id;
                } else {
                    // TODO: do something other than move here
                }
            } else {
                player.move_to(target);
            }
        }
        player_acted = true;
    }

    if (player_acted) {
        tick_kaiju(rng);
    }
}

fn tick_kaiju(rng: std.Random) void {
    _ = rng;
    // kaiju behavior is based on proximity
    for (globals.units[1..]) |*u| {
        if (u.tag == .Kaiju) {
            // kaiju sleep if outside of 1 camera radius
            // TODO make more complex?
            if (u.position.max_norm_distance(globals.player().position) < 64) {
                // relentless chase the player
                u.move(u.position.facing(globals.player().position));
            }
        }
    }
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

pub fn get_occupant(pos: IVec2) ?UnitId {
    for (globals.units[1..], 1..) |u, id| {
        if (u.occupies(pos)) {
            return @intCast(id);
        }
    }
    return null;
}

pub fn player_passable(pos: IVec2) bool {
    const t = get_terrain_at(pos) orelse return false;
    if (!t.passable()) {
        return false;
    }
    //TODO: kaiju obstruction
    return true;
}

pub fn moto_passable(pos: IVec2, orientation: Dir4) bool {
    const t = get_terrain_at(pos) orelse return false;
    const p2 = pos.plus(orientation.ivec());
    const t2 = get_terrain_at(p2) orelse return false;
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

test {
    std.testing.refAllDecls(@This());
}
