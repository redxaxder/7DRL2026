const IVec2 = @import("core.zig").IVec2;
const Dir4 = @import("core.zig").Dir4;
const map = @import("map.zig");
const std = @import("std");

const BASE_ITEM_CAPACITY: usize = 3;
const INVENTORY_SIZE: usize = 10;

var pending_pickups: usize = 0;
pub var inventory: [INVENTORY_SIZE]Item = .{Item.DEFAULT} ** INVENTORY_SIZE;
var item_count: usize = 0;
var item_capacity: usize = 3;
var cash: usize = 0;

var next_item: Item = undefined;

pub fn has_pending_pickups() bool {
    return pending_pickups > 0;
}

pub fn extend_item_capacity(ksize: u8) void {
    const sz: usize = @intCast(ksize);
    const bonus = sz - 2;
    item_capacity = @max(item_capacity, BASE_ITEM_CAPACITY + bonus);
    item_capacity = @min(item_capacity, INVENTORY_SIZE);
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
        const c = rng.int(usize) % std.enums.values(ItemTag).len;
        const x: ItemTag = @enumFromInt(c);
        if (x != .Nil) {
            break :blk x;
        }
    };
    next_item = .tagged(t);

    switch (t) {
        .Labubu => {
            next_item.attrs.field(.motorcycle_armor).* +=
                roll_low(2, 3, 6);
        },
        .Gamma_Beam => {
            next_item.attrs.field(.radioactive_damage).* +=
                roll_low(4, 2, 10);
        },
        .Rifle => {},
        .Rocket_Launcher => {},
        .Nil => {
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
    std.log.info("got! {any}", .{next_item});
    if (slot < item_capacity) {
        inventory[slot] = next_item;
        roll_next_item(rng);
        pending_pickups -= 1;
    }
}

pub const ItemTag = enum {
    Nil,

    // Trinkets
    Labubu,
    // Cell_Phone,
    // Figurine,
    // Pencil_Case,
    // Omamori,
    // Talisman,
    // Amulet,
    // Sakazuki,
    // Hachimaki,
    // Briefcase,
    // Hair_Clip,
    // Juzu_Beads,
    // Credit_Card,
    // Stamp_Seal,
    // Odd_Odometer,
    // Odder_Odometer,
    // Oddest_Odometer,

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
        if (self == .nil) {
            return "";
        }
        const tag_name = @tagName(self);
        const result = comptime blk: {
            var buf: [tag_name.len]u8 = undefined;
            for (&buf, tag_name) |*b, c| {
                b.* = if (c == '_') ' ' else c;
            }
            break :blk buf;
        };
        return &result;
    }
};

pub const Attribute = enum {
    radioactive_damage,
    explosion_radius,
    explosion_damage,
    gun_damage,
    gun_combo,
    crit3_bonus,
    crit4_bonus,
    crit5_bonus,
    motorcycle_damage,
    motorcycle_armor,
    top_speed,
    acceleration,
};

const NUM_ATTRIBUTES: usize = std.enums.values(Attribute).len;
pub const Attributes = struct {
    data: [NUM_ATTRIBUTES]i16 = .{0} ** NUM_ATTRIBUTES,

    pub const ZERO: Attributes = .{};

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
    pub fn effective_value(self: *Attributes, attr: Attribute) i16 {
        return self.field(attr) + bonuses().field(attr);
    }
};

pub fn bonuses() Attributes {
    const n = inventory_first_free() orelse item_capacity;
    var accum: Attributes = .ZERO;
    for (0..n) |ix| {
        const item = inventory[ix];
        if (item.tag.is_trinket()) {
            accum.pluseq(item.attrs);
        }
    }
    return accum;
}

pub const Item = struct {
    // universal
    tag: ItemTag = .Nil,
    attrs: Attributes = .ZERO,

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
