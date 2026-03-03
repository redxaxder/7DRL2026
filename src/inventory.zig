const IVec2 = @import("core.zig").IVec2;
const Dir4 = @import("core.zig").Dir4;
const map = @import("map.zig");
const std = @import("std");

pub const NAME_LEN: usize = 32;

pub const NAMES = [_][]const u8{
    "labubu",
    "cell phone",
    "figurine",
    "pencil case",
    "omamori",
    "talisman",
    "amulet",
    "sakazuki",
    "hachimaki",
    "briefcase",
    "hair clip",
    "juzu beads",
    "credit card",
    "stamp seal",
};

const INVENTORY_SIZE = 10;

pub const ItemType = enum(u8) {
    Nil,
    Trinket,
    Gun,
};

pub const Item = struct {
    // universal
    tag: ItemType = .Nil,
    in_inventory: bool = false,
    position: IVec2 = .{ .x = 0, .y = 0 },

    //trinkets
    name: []const u8 = undefined,

    pub const DEFAULT: Item = .{};
};

var inventory: [INVENTORY_SIZE]Item = .{Item.DEFAULT} ** INVENTORY_SIZE;

fn inventory_add(index: usize, item: Item) void {
    inventory[index] = item;
    inventory[index].in_inventory = true;
    std.log.info("get equipped with {s}", .{item.name});
}

fn inventory_destroy(index: usize) void {
    inventory[index] = Item.DEFAULT;
}

fn inventory_first_free() ?usize {
    for (inventory, 0..) |slot, i| {
        if (!slot.in_inventory) return i;
    }
    return null;
}

pub fn try_add_items(accum_items: []?Item) void {
    for (accum_items) |ai| {
        if (ai) |i| {
            // TODO do item replace UI
            const slot = inventory_first_free() orelse return;
            inventory_add(slot, i);
            map.set_terrain_at(i.position, .Floor);
        }
    }
}
