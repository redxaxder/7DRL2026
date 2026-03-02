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

fn sector_index(pos: IVec2) ?usize {
    if (pos.x < 0 or pos.y < 0) return null;
    const sx: usize = @intCast(@divFloor(pos.x, SECTOR_SIZE));
    const sy: usize = @intCast(@divFloor(pos.y, SECTOR_SIZE));
    if (sx >= SECTORS_PER_SIDE or sy >= SECTORS_PER_SIDE) return null;
    return sy * SECTORS_PER_SIDE + sx;
}

const MAX_UNIT_SECTORS = 4;
const SectorSet = struct {
    buf: [MAX_UNIT_SECTORS]usize = undefined,
    len: usize = 0,

    fn append(self: *SectorSet, val: usize) void {
        if (self.len < MAX_UNIT_SECTORS) {
            self.buf[self.len] = val;
            self.len += 1;
        }
    }

    fn slice(self: *const SectorSet) []const usize {
        return self.buf[0..self.len];
    }
};

fn sectors_for_unit(u: *const Unit) SectorSet {
    var result = SectorSet{};
    const rect = u.get_rect();
    var it = rect.iter();
    while (it.next()) |pos| {
        const si = sector_index(pos) orelse continue;
        // deduplicate
        var found = false;
        for (result.slice()) |existing| {
            if (existing == si) {
                found = true;
                break;
            }
        }
        if (!found) result.append(si);
    }
    return result;
}

pub fn add(id: UnitId, u: *const Unit) void {
    const secs = sectors_for_unit(u);
    for (secs.slice()) |si| {
        const ni = alloc_node();
        nodes[ni] = .{
            .unit_id = id,
            .next = sector_heads[si],
        };
        sector_heads[si] = ni;
    }
}

pub fn remove(id: UnitId, u: *const Unit) void {
    const secs = sectors_for_unit(u);
    for (secs.slice()) |si| {
        var prev: ?NodeIndex = null;
        var cur: NodeIndex = sector_heads[si];
        while (cur != SENTINEL) {
            const node = &nodes[cur];
            if (node.unit_id == id) {
                // unlink
                if (prev) |p| {
                    nodes[p].next = node.next;
                } else {
                    sector_heads[si] = node.next;
                }
                free_node(cur);
                break;
            }
            prev = cur;
            cur = node.next;
        }
    }
}

pub fn get_occupant(pos: IVec2) ?UnitId {
    const si = sector_index(pos) orelse return null;
    var cur: NodeIndex = sector_heads[si];
    while (cur != SENTINEL) {
        const node = &nodes[cur];
        if (main.globals.unit(node.unit_id).occupies(pos)) {
            return node.unit_id;
        }
        cur = node.next;
    }
    return null;
}
