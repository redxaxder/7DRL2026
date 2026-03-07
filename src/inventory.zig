const IVec2 = @import("core.zig").IVec2;
const Dir4 = @import("core.zig").Dir4;
const map = @import("map.zig");
const std = @import("std");
const main = @import("main.zig");
const combat_log = @import("combat_log.zig");

const BASE_ITEM_CAPACITY: usize = 3;
const INVENTORY_SIZE: usize = 10;

var pending_pickups: usize = 0;
pub var inventory: [INVENTORY_SIZE]Item = .{Item.DEFAULT} ** INVENTORY_SIZE;
pub var active_index: ?usize = null;
var item_count: usize = 0;
pub var item_capacity: usize = 3;
var cash: usize = 0;

pub var next_item: Item = undefined;

pub fn reset() void {
    pending_pickups = 0;
    inventory = .{Item.DEFAULT} ** INVENTORY_SIZE;
    active_index = null;
    item_count = 0;
    item_capacity = 4;
    cash = 0;
}

pub const BASE_WEAPON: Item = blk: {
    var it: Item = .tagged(ItemTag.Rifle);
    it.attrs.field(.gun_damage).* = 1;
    it.attrs.field(.accuracy).* = 1;
    break :blk it;
};

const EXAMPLE_TRINKET: Item = blk: {
    var it: Item = .tagged(ItemTag.Hachimaki);
    it.attrs.field(.explosion_radius).* = 4;
    it.attrs.field(.crit3_bonus).* = 2;
    break :blk it;
};

const EXAMPLE_GAMMA: Item = blk: {
    var it: Item = .tagged(ItemTag.Gamma_Beam);
    it.attrs.field(.radiation_damage).* = 10;
    break :blk it;
};

const EXAMPLE_ROCKET: Item = blk: {
    var it: Item = .tagged(ItemTag.Rocket_Launcher);
    it.attrs.field(.explosion_radius).* = 1;
    it.attrs.field(.explosion_damage).* = 10;
    break :blk it;
};

const EXAMPLE_FOCUS: Item = blk: {
    var it: Item = .tagged(ItemTag.Psionic_Focus);
    it.attrs.field(.psi_reservoir).* = 1;
    it.attrs.field(.psi_radius).* = 10;
    break :blk it;
};

pub fn init(rng: std.Random) void {
    // inventory[0] = BASE_WEAPON;
    // inventory[1] = EXAMPLE_FOCUS;
    // inventory[2] = EXAMPLE_TRINKET;
    // inventory[1] = EXAMPLE_FOCUS;
    // inventory[2] = EXAMPLE_GAMMA;
    // inventory[3] = EXAMPLE_ROCKET;
    roll_next_item(rng);
}

pub fn active_weapon() ?*const Item {
    if (active_index) |ix| {
        return &inventory[ix];
    }
    return null;
}

pub fn get_active_index() ?usize {
    return active_index;
}

pub fn toggle_weapon(id: usize) void {
    const index = (id + 9) % 10;
    if (active_index) |active| {
        if (active == index) {
            active_index = null;
            return;
        }
    }
    if (inventory[index].tag.is_weapon()) {
        active_index = index;
    } else {
        active_index = null;
    }
}

pub fn has_pending_pickups() bool {
    return pending_pickups > 0;
}

pub fn extend_item_capacity(ksize: u8) bool {
    const sz: usize = @intCast(ksize);
    const bonus = sz - 2;
    const prev_capacity = item_capacity;
    item_capacity = @max(item_capacity, BASE_ITEM_CAPACITY + bonus);
    item_capacity = @min(item_capacity, INVENTORY_SIZE);
    return item_capacity > prev_capacity;
}

pub fn roll_low(rng: std.Random, rounds: usize, min: i16, max: i16) i16 {
    var result = max;
    for (0..rounds) |_| {
        result = @min(result, rng.intRangeAtMost(i16, min, max));
    }
    return result;
}

pub fn roll_next_item(rng: std.Random) void {
    const danger_level: f32 = @floatFromInt(main.danger_growth(main.globals.player().position));
    const qualmod = 0.4 + std.math.sqrt(danger_level) / 10;

    const t: ItemTag = blk: while (true) {
        const x: ItemTag = rng.enumValue(ItemTag);
        if (x != .Nil) {
            break :blk x;
        }
    };
    next_item = .tagged(t);
    if (t.is_weapon()) {
        for (gun_stats(t)) |attr| {
            next_item.roll_attr(rng, qualmod, attr);
        }
    } else if (t.is_trinket()) {
        const stat2 = rng.enumValue(Attribute);
        next_item.roll_attr(rng, qualmod * 0.3, stat2);

        const primary_options = trinket_stat(t);
        if (primary_options.len < 1) {
            return;
        }
        const ix = rng.intRangeAtMost(usize, 0, primary_options.len - 1);

        const stat1 = primary_options[ix];
        next_item.roll_attr(rng, qualmod * 0.5, stat1);
    }
}

pub fn add_pending_pickup() void {
    pending_pickups += 1;
}

pub fn handle_pending_pickups(rng: std.Random) void {
    while (pending_pickups > 0) {
        const slot = inventory_first_free() orelse return;
        if (slot < item_capacity) {
            overwrite_slot(rng, slot);
        } else {
            return;
        }
    }
}

pub fn overwrite_slot(rng: std.Random, slot: usize) void {
    if (slot < item_capacity) {
        if (slot == active_index) {
            active_index = null;
        }
        if (inventory[slot].tag != .Nil) {
            combat_log.log("You throw away your {s}.", .{inventory[slot].tag.name()});
        }
        combat_log.log("You equip the {s}.", .{next_item.tag.name()});
        inventory[slot] = next_item;
        roll_next_item(rng);
        pending_pickups -= 1;
    }
}

pub fn discard_pending(rng: std.Random) void {
    combat_log.log("You throw away the {s}.", .{next_item.tag.name()});
    roll_next_item(rng);
    pending_pickups -= 1;
}

fn gun_stats(t: ItemTag) []const Attribute {
    return switch (t) {
        .Rifle => ([_]Attribute{ .gun_damage, .accuracy })[0..],
        .Gamma_Beam => ([_]Attribute{.radiation_damage})[0..],
        .Rocket_Launcher => ([_]Attribute{ .explosion_damage, .explosion_radius })[0..],
        .Psionic_Focus => ([_]Attribute{ .psi_reservoir, .psi_radius })[0..],
        else => &.{},
    };
}

fn trinket_stat(t: ItemTag) []const Attribute {
    const T = Attribute;
    return switch (t) {
        .Labubu => ([_]T{.impact_damage})[0..],
        .Cell_Phone => ([_]T{.explosion_radius})[0..],
        .Figurine => ([_]T{ .crit3_bonus, .crit4_bonus, .crit5_bonus })[0..],
        .Pencil_Case => ([_]T{.acceleration})[0..],
        .Talisman => ([_]T{.armor})[0..],
        .Hachimaki => ([_]T{.accuracy})[0..],
        .Juzu_Beads => ([_]T{.psi_reservoir})[0..],
        .Briefcase => ([_]T{.explosion_damage})[0..],
        .Odometer => ([_]T{.top_speed})[0..],
        .Hair_Clip => ([_]T{.radiation_damage})[0..],
        else => &.{},
    };
}

pub const ItemTag = enum {
    Nil,

    // Trinkets
    Labubu,
    Cell_Phone,
    Figurine,
    Pencil_Case,
    Talisman,
    Hachimaki,
    Juzu_Beads,
    // Amulet,
    Briefcase,
    Hair_Clip,
    // Credit_Card,
    // Stamp_Seal,
    Odometer,

    // Weapons
    Rifle,
    Rocket_Launcher,
    Gamma_Beam,
    Psionic_Focus,

    pub fn is_trinket(self: ItemTag) bool {
        return !self.is_weapon();
    }

    pub fn is_weapon(self: ItemTag) bool {
        return switch (self) {
            .Rifle, .Rocket_Launcher, .Gamma_Beam, .Psionic_Focus => true,
            else => false,
        };
    }

    pub fn prefix(self: ItemTag) []const u8 {
        return switch (self) {
            .Rifle => "gun ",
            .Gamma_Beam => "radiation ",
            .Rocket_Launcher => "explosion ",
            .Psionic_Focus => "psi ",
            else => "",
        };
    }

    pub fn name(self: ItemTag) []const u8 {
        if (self == .Nil) return "";
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
};

pub const Attribute = enum {
    radiation_damage,
    explosion_radius,
    explosion_damage,
    gun_damage,
    accuracy,
    crit3_bonus,
    crit4_bonus,
    crit5_bonus,
    impact_damage,
    armor,
    top_speed,
    acceleration,
    psi_reservoir,
    psi_radius,

    const Config = struct { low: f32, high: f32, n: f32 };
    pub fn config(self: Attribute) Config {
        return switch (self) {
            .radiation_damage => .{
                .low = 2,
                .high = 10,
                .n = 4,
            },
            .explosion_radius => .{
                .low = 1,
                .high = 9,
                .n = 4,
            },
            .explosion_damage => .{
                .low = 5,
                .high = 90,
                .n = 9,
            },
            .psi_radius => .{
                .low = 5,
                .high = 10,
                .n = 3,
            },
            .psi_reservoir => .{
                .low = 5,
                .high = 30,
                .n = 5,
            },
            .gun_damage => .{
                .low = 1,
                .high = 30,
                .n = 5,
            },
            .accuracy => .{
                .low = 1,
                .high = 10,
                .n = 3,
            },
            .crit3_bonus => .{
                .low = 2,
                .high = 20,
                .n = 3,
            },
            .crit4_bonus => .{
                .low = 4,
                .high = 15,
                .n = 4,
            },
            .crit5_bonus => .{
                .low = 5,
                .high = 20,
                .n = 5,
            },

            .impact_damage => .{
                .low = 2,
                .high = 10,
                .n = 2,
            },
            .armor => .{
                .low = 1,
                .high = 6,
                .n = 2,
            },
            .top_speed => .{
                .low = 1,
                .high = 10,
                .n = 2,
            },
            .acceleration => .{
                .low = 1,
                .high = 10,
                .n = 4,
            },
        };
    }

    pub fn name(self: Attribute) []const u8 {
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
};

const NUM_ATTRIBUTES: usize = std.enums.values(Attribute).len;
pub const Attributes = struct {
    data: [NUM_ATTRIBUTES]i16 = .{0} ** NUM_ATTRIBUTES,

    pub fn pluseq(self: *Attributes, rhs: *const Attributes) void {
        for (&self.data, rhs.data) |*s, r| {
            s.* += r;
        }
    }

    pub fn plus(self: *const Attributes, rhs: *const Attributes) Attributes {
        var result = self.*;
        result.pluseq(rhs);
        return result;
    }

    pub fn field(self: *Attributes, attr: Attribute) *i16 {
        const ix: usize = @intFromEnum(attr);
        return &self.data[ix];
    }

    pub fn readfield(self: *const Attributes, attr: Attribute) i16 {
        const ix: usize = @intFromEnum(attr);
        return self.data[ix];
    }
    pub fn effective_value(self: *const Attributes, attr: Attribute) i16 {
        return self.readfield(attr) + bonuses().readfield(attr);
    }
};

pub fn bonuses() Attributes {
    const n = inventory_first_free() orelse item_capacity;
    var accum: Attributes = .{};
    for (0..n) |ix| {
        const item = inventory[ix];
        if (item.tag.is_trinket()) {
            accum.pluseq(&item.attrs);
        }
        if (item.tag == .Psionic_Focus) {
            accum.field(.psi_reservoir).* += item.attrs.readfield(.psi_reservoir);
        }
    }
    return accum;
}

pub const Item = struct {
    // universal
    tag: ItemTag = .Nil,
    attrs: Attributes = .{},

    pub const DEFAULT: Item = .{};

    pub fn tagged(t: ItemTag) Item {
        return .{ .tag = t };
    }

    pub fn roll_attr(self: *Item, rng: std.Random, qualmod: f32, attr: Attribute) void {
        const config = attr.config();
        const up = (config.high * qualmod) + qualmod;
        const down = config.low;
        const n = config.n * qualmod;
        const got = roll_low(
            rng,
            @intFromFloat(@floor(n)),
            @intFromFloat(@floor(down)),
            @intFromFloat(@ceil(up)),
        );
        self.attrs.field(attr).* = got;
    }
};

fn inventory_first_free() ?usize {
    for (inventory, 0..) |item, i| {
        if (item.tag == .Nil) {
            return i;
        }
    }
    return null;
}

pub fn has_psi() bool {
    return bonuses().effective_value(.psi_reservoir) > 0;
}
