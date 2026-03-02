const std = @import("std");
const main = @import("main.zig");
const core = @import("core.zig");
const map = @import("map.zig");
const IVec2 = core.IVec2;
const Unit = main.Unit;
const UnitId = main.UnitId;

pub const SECTOR_SIZE = 100;
pub const SECTORS_PER_SIDE = map.MAP_SIZE / SECTOR_SIZE; // 25
pub const NUM_SECTORS = SECTORS_PER_SIDE * SECTORS_PER_SIDE; // 625

const NodeIndex = u16;
const SENTINEL: NodeIndex = std.math.maxInt(NodeIndex);
const MAX_NODES = 4000;

const SectorNode = struct {
    unit_id: UnitId,
    next: NodeIndex,
};

var sector_heads: [NUM_SECTORS]NodeIndex = .{SENTINEL} ** NUM_SECTORS;
var nodes: [MAX_NODES]SectorNode = undefined;
var free_head: NodeIndex = SENTINEL;

pub fn init() void {
    sector_heads = .{SENTINEL} ** NUM_SECTORS;
    for (0..MAX_NODES) |i| {
        nodes[i].next = if (i + 1 < MAX_NODES) @intCast(i + 1) else SENTINEL;
    }
    free_head = 0;
}

fn alloc_node() NodeIndex {
    const idx = free_head;
    if (idx == SENTINEL) @panic("sector node pool exhausted");
    free_head = nodes[idx].next;
    return idx;
}

fn free_node(idx: NodeIndex) void {
    nodes[idx].next = free_head;
    free_head = idx;
}

fn sector_head(pos: IVec2) *NodeIndex {
    return &sector_heads[@as(usize, @intCast(pos.y)) * SECTORS_PER_SIDE + @as(usize, @intCast(pos.x))];
}

fn sector_bounds(rect: core.IRect) core.IRect {
    const sx_min: i16 = @intCast(@as(usize, @intCast(@max(0, @divFloor(rect.x, SECTOR_SIZE)))));
    const sx_max: i16 = @intCast(@min(SECTORS_PER_SIDE - 1, @as(usize, @intCast(@max(0, @divFloor(rect.x + rect.w - 1, SECTOR_SIZE))))));
    const sy_min: i16 = @intCast(@as(usize, @intCast(@max(0, @divFloor(rect.y, SECTOR_SIZE)))));
    const sy_max: i16 = @intCast(@min(SECTORS_PER_SIDE - 1, @as(usize, @intCast(@max(0, @divFloor(rect.y + rect.h - 1, SECTOR_SIZE))))));
    return .{ .x = sx_min, .y = sy_min, .w = sx_max - sx_min + 1, .h = sy_max - sy_min + 1 };
}

pub fn add(id: UnitId, u: *const Unit) void {
    var it = sector_bounds(u.get_rect()).iter();
    while (it.next()) |pos| {
        const head = sector_head(pos);
        const ni = alloc_node();
        nodes[ni] = .{
            .unit_id = id,
            .next = head.*,
        };
        head.* = ni;
    }
}

pub fn remove(id: UnitId, u: *const Unit) void {
    var it = sector_bounds(u.get_rect()).iter();
    while (it.next()) |pos| {
        const head = sector_head(pos);
        var prev: ?NodeIndex = null;
        var cur: NodeIndex = head.*;
        while (cur != SENTINEL) {
            const node = &nodes[cur];
            if (node.unit_id == id) {
                if (prev) |p| {
                    nodes[p].next = node.next;
                } else {
                    head.* = node.next;
                }
                free_node(cur);
                break;
            }
            prev = cur;
            cur = node.next;
        }
    }
}

pub fn get_occupants(pos: IVec2) OccupantIterator {
    return get_occupants_rect(core.IRect.singleton(pos));
}

pub const OccupantIterator = struct {
    rect: core.IRect,
    sector_iter: core.IRect.LocationIterator,
    cur: NodeIndex,

    pub fn next(self: *OccupantIterator) ?UnitId {
        while (true) {
            while (self.cur != SENTINEL) {
                const node = &nodes[self.cur];
                self.cur = node.next;
                if (main.globals.unit(node.unit_id).get_rect().intersects(self.rect)) {
                    return node.unit_id;
                }
            }
            const pos = self.sector_iter.next() orelse return null;
            self.cur = sector_head(pos).*;
        }
    }
};

pub fn get_occupants_rect(rect: core.IRect) OccupantIterator {
    var sector_iter = sector_bounds(rect).iter();
    const first = sector_iter.next() orelse return .{
        .rect = rect,
        .sector_iter = sector_iter,
        .cur = SENTINEL,
    };
    return .{
        .rect = rect,
        .sector_iter = sector_iter,
        .cur = sector_head(first).*,
    };
}
