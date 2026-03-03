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

pub fn roll_next_item(rng: std.Random) void {
    const t = blk: while (true) {
        const c = rng.int(usize) % std.enums.values(ItemTag).len;
        const x: ItemTag = @enumFromInt(c);
        if (x != .Nil) {
            break :blk x;
        }
    };
    next_item = .tagged(t);
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
    Labubu,
    Cell_Phone,
    Figurine,
    Pencil_Case,
    Omamori,
    Talisman,
    Amulet,
    Sakazuki,
    Hachimaki,
    Briefcase,
    Hair_Clip,
    Juzu_Beads,
    Credit_Card,
    Stamp_Seal,
    Odd_Odometer,
    Odder_Odometer,
    Oddest_Odometer,

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

pub const Item = struct {
    // universal
    tag: ItemTag = .Nil,
    // in_inventory: bool = false,
    // position: IVec2 = .{ .x = 0, .y = 0 },

    //trinkets

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
