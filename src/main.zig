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

    // a unit occupies a position if it potentially obscructs travel into it
    // the only things that can do this are:
    //   - the player
    //   - motorcycles
    //   - kaiju
    // these are considered to have mutually exclusive ownership over locations,
    // except when the player is riding a motorcycle
    pub inline fn occupies(self: *const @This(), pos: IVec2) bool {
        const u: UnitType = self.tag;

        switch (u) {
            .Player => {
                return self.position.eq(pos);
            },
            .Motorcycle => {
                const p2 = self.position.plus(self.orientation.ivec());
                return self.position.eq(pos) or p2.eq(pos);
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
    pub fn mount(self: *const @This()) *Unit {
        return globals.unit(self.mounted_on);
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
    globals.player().* = Unit{
        .tag = .Player,
        .position = IVec2{ .x = 0, .y = 0 },
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
    map.mapgen(rng, &globals.mapdata);
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
            const motomove = resolve_motorcycle_movement(
                pmount,
                .{
                    .dir = d,
                    .shift = keyboard.isShiftDown(),
                },
            );
            if (full_crash_check(pmount, motomove)) |crashed| {
                pmount.*.position = crashed.position;
                pmount.*.orientation = crashed.orientation;
                pmount.*.speed = 0;
                player.*.speed = 0;
                // TODO: handle post-midpoint crash
                player.*.mounted_on = 0;
            } else {
                pmount.*.position = motomove.position;
                pmount.*.orientation = motomove.orientation;
                pmount.*.speed = motomove.speed;
                player.*.position = pmount.position;
            }
        } else {
            // unmounted movement
            const dv = d.ivec();
            const target = player.position.plus(dv);

            if (get_occupant(target)) |occupant_id| {
                const occupant = globals.unit(occupant_id);
                if (occupant.tag == .Motorcycle) { // Mount it
                    player.*.position = occupant.position;
                    player.*.mounted_on = occupant_id;
                } else {
                    // TODO: do something other than move here
                }
            } else {
                player.*.position = target;
            }
        }
    }

    // std.log.info("player at {}", .{globals.units[PLAYER_ID].position});

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
    midpoint: bool = false,
};

pub fn full_crash_check(moto: *const Unit, move: MotoResult) ?CrashInfo {
    const delta = move.position.minus(moto.position);
    const n = delta.max_norm();

    // we're strafing if we haven't changed direction, but we're moving on both x and y
    const strafe_mode = (move.orientation == moto.orientation) and delta.x != 0 and delta.y != 0;

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
    cursor.orientation = move.orientation;
    const steps2 = delta.projection(move.orientation).max_norm();
    for (0..@intCast(steps2)) |_| {
        const next = cursor.position.plus(move.orientation.ivec());
        if (!moto_passable(next, move.orientation)) {
            return cursor;
        }
        cursor.position = next;
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

            if (move.shift) { // slight brake
                const drift = moto.orientation.ivec()
                    .scaled(@intCast(it.speed))
                    .plus(change.ivec());
                it.position = it.position.plus(drift);
                if (it.speed > 0) {
                    it.speed -= 1;
                }
            } else { // full brake
                const drift = moto.orientation.ivec().scaled(@intCast(slide_dist));
                it.position = it.position.plus(drift);
                if (moto.speed == 0) {
                    it.orientation = change;
                }
                it.speed = 0;
                // if speed is high enough, brake via akira slide
                if (slide_dist >= 2) {
                    it.orientation = moto.orientation.turn(.Right);
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
