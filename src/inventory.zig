const IVec2 = @import("core.zig").IVec2;
const Dir4 = @import("core.zig").Dir4;
const map = @import("map.zig");
const std = @import("std");
const combat_log = @import("combat_log.zig");

const BASE_ITEM_CAPACITY: usize = 3;
const INVENTORY_SIZE: usize = 10;

var pending_pickups: usize = 0;
pub var inventory: [INVENTORY_SIZE]Item = .{Item.DEFAULT} ** INVENTORY_SIZE;
var active_index: ?usize = null;
var item_count: usize = 0;
pub var item_capacity: usize = 3;
var cash: usize = 0;

pub var next_item: Item = undefined;

const BASE_WEAPON: Item = blk: {
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
    it.attrs.field(.radioactive_damage).* = 10;
    break :blk it;
};

const EXAMPLE_ROCKET: Item = blk: {
    var it: Item = .tagged(ItemTag.Rocket_Launcher);
    it.attrs.field(.explosion_radius).* = 1;
    it.attrs.field(.explosion_damage).* = 10;
    break :blk it;
};

pub fn init(rng: std.Random) void {
    inventory[0] = BASE_WEAPON;
    inventory[1] = EXAMPLE_TRINKET;
    inventory[2] = EXAMPLE_ROCKET;
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
    const t: ItemTag = blk: while (true) {
        const x: ItemTag = rng.enumValue(ItemTag);
        if (x != .Nil) {
            break :blk x;
        }
    };
    next_item = .tagged(t);

    switch (t) {
        .Labubu => {
            next_item.attrs.field(.impact_damage).* +=
                roll_low(rng, 2, 3, 6);
        },
        .Gamma_Beam => {
            next_item.attrs.field(.radioactive_damage).* +=
                roll_low(rng, 4, 2, 10);
        },
        .Rifle => {
            next_item.attrs.field(.gun_damage).* +=
                roll_low(rng, 5, 1, 30);
            next_item.attrs.field(.accuracy).* +=
                roll_low(rng, 3, 1, 10);
        },
        .Rocket_Launcher => {
            next_item.attrs.field(.explosion_damage).* +=
                roll_low(rng, 5, 1, 30);
            next_item.attrs.field(.explosion_radius).* +=
                roll_low(rng, 8, 1, 5);
        },
        .Cell_Phone => {
            next_item.attrs.field(.explosion_radius).* +=
                roll_low(rng, 12, 1, 5);
        },
        .Figurine => {
            next_item.attrs.field(.top_speed).* +=
                roll_low(rng, 3, 1, 10);
        },
        .Pencil_Case => {
            next_item.attrs.field(.top_speed).* +=
                roll_low(rng, 3, 1, 10);
        },
        .Talisman => {
            next_item.attrs.field(.armor).* +=
                roll_low(rng, 2, 3, 6);
        },
        .Hachimaki => {
            next_item.attrs.field(.gun_damage).* +=
                roll_low(rng, 8, 1, 30);
            next_item.attrs.field(.accuracy).* +=
                roll_low(rng, 8, 1, 10);
        },
        // .Amulet => { },
        // .Briefcase => {},
        // .Hair_Clip => {},
        // .Juzu_Beads => {},
        // .Credit_Card => {},
        // .Stamp_Seal => {},
        .Odd_Odometer => {
            next_item.attrs.field(.crit3_bonus).* +=
                roll_low(rng, 3, 2, 10);
        },
        .Odder_Odometer => {
            next_item.attrs.field(.crit4_bonus).* +=
                roll_low(rng, 4, 4, 15);
        },
        .Oddest_Odometer => {
            next_item.attrs.field(.crit5_bonus).* +=
                roll_low(rng, 5, 5, 20);
        },
        .Nil => {
            std.log.err("we reroll these", .{});
            unreachable;
        },
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
        combat_log.log("You throw away your {s}.", .{inventory[slot].tag.name()});
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

pub const ItemTag = enum {
    Nil,

    // Trinkets
    Labubu,
    Cell_Phone,
    Figurine,
    Pencil_Case,
    Talisman,
    Hachimaki,
    // Amulet,
    // Briefcase,
    // Hair_Clip,
    // Juzu_Beads,
    // Credit_Card,
    // Stamp_Seal,
    Odd_Odometer,
    Odder_Odometer,
    Oddest_Odometer,

    // Weapons
    Rifle,
    Rocket_Launcher,
    Gamma_Beam,

    pub fn is_trinket(self: ItemTag) bool {
        return !self.is_weapon();
    }

    pub fn is_weapon(self: ItemTag) bool {
        return switch (self) {
            .Rifle, .Rocket_Launcher, .Gamma_Beam => true,
            else => false,
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
    radioactive_damage,
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
};

fn inventory_first_free() ?usize {
    for (inventory, 0..) |item, i| {
        if (item.tag == .Nil) {
            return i;
        }
    }
    return null;
}
