const std = @import("std");
const core = @import("core.zig");
const map = @import("map.zig");
const IVec2 = core.IVec2;
const Dir4 = core.Dir4;
const RelativeDir = core.RelativeDir;

const Contains = enum(u8) {
    Inside,
    Boundary,
    Outside,
};

const ShadowInterval = struct {
    a: IVec2,
    b: IVec2,

    fn contains(self: ShadowInterval, v: IVec2) Contains {
        const o1 = orient2di(IVec2.ZERO, v, self.a);
        const o2 = orient2di(IVec2.ZERO, self.b, v);
        if (o1 == 0 and o2 == 0) return .Boundary;
        if (o1 < 0 and o2 < 0) return .Inside;
        return .Outside;
    }

    fn overlaps(self: ShadowInterval, rhs: ShadowInterval) bool {
        const c0 = self.contains(rhs.a);
        const c1 = self.contains(rhs.b);
        const c2 = rhs.contains(self.a);
        const c3 = rhs.contains(self.b);
        const min_val = @min(@min(@intFromEnum(c0), @intFromEnum(c1)), @min(@intFromEnum(c2), @intFromEnum(c3)));
        return min_val <= @intFromEnum(Contains.Boundary);
    }

    fn test_shadow(self: ShadowInterval, rhs: ShadowInterval) Contains {
        var n: u8 = 0;
        if (@intFromEnum(self.contains(rhs.a)) <= @intFromEnum(Contains.Boundary)) n += 1;
        if (@intFromEnum(self.contains(rhs.b)) <= @intFromEnum(Contains.Boundary)) n += 1;
        return switch (n) {
            0 => .Outside,
            1 => .Boundary,
            else => .Inside,
        };
    }

    fn merge(self: *ShadowInterval, rhs: ShadowInterval) void {
        if (self.contains(rhs.a) == .Outside) self.a = rhs.a;
        if (self.contains(rhs.b) == .Outside) self.b = rhs.b;
    }
};

fn orient2di(p: IVec2, q: IVec2, r: IVec2) i32 {
    const ax: i32 = @as(i32, q.x) - @as(i32, p.x);
    const ay: i32 = @as(i32, q.y) - @as(i32, p.y);
    const bx: i32 = @as(i32, r.x) - @as(i32, p.x);
    const by: i32 = @as(i32, r.y) - @as(i32, p.y);
    return ay * bx - ax * by;
}

const MAX_SHADOWS = 64;

const Shadows = struct {
    intervals: [MAX_SHADOWS]ShadowInterval = undefined,
    len: usize = 0,

    fn coverage(self: *const Shadows, s: ShadowInterval) usize {
        var ret: usize = 0;
        for (self.intervals[0..self.len]) |interval| {
            switch (interval.test_shadow(s)) {
                .Inside => return 3,
                .Boundary => ret += 1,
                .Outside => {},
            }
        }
        return ret;
    }

    fn add_interval(self: *Shadows, si: ShadowInterval) void {
        var fused: ?usize = null;
        var i: usize = 0;
        while (i < self.len) {
            if (si.overlaps(self.intervals[i])) {
                if (fused) |j| {
                    // merge this overlapping interval into the first fused one, then remove it
                    self.intervals[j].merge(self.intervals[i]);
                    self.len -= 1;
                    self.intervals[i] = self.intervals[self.len];
                    continue; // don't increment i
                } else {
                    self.intervals[i].merge(si);
                    fused = i;
                }
            }
            i += 1;
        }
        if (fused == null) {
            if (self.len < MAX_SHADOWS) {
                self.intervals[self.len] = si;
                self.len += 1;
            }
        }
    }
};

const FrontierEntry = struct {
    pos: IVec2,
    v: IVec2,
};

const MAX_FRONTIER = 512;

fn scan_quadrant(from: IVec2, rotation: u2, distance: u8, blocked: *const fn (IVec2) bool, record: *const fn (IVec2) void) void {
    const rd: RelativeDir = @enumFromInt(rotation);
    const right = Dir4.Right.turn(rd);
    const up = Dir4.Up.turn(rd);
    const origin = IVec2.ZERO;
    const d2: i16 = @as(i16, @intCast(distance)) * 2;

    var shadows = Shadows{};
    var frontier: [MAX_FRONTIER]FrontierEntry = undefined;
    var next: [MAX_FRONTIER]FrontierEntry = undefined;
    var frontier_len: usize = 1;
    var next_len: usize = 0;
    frontier[0] = .{ .pos = from, .v = origin };

    while (frontier_len > 0) {
        for (frontier[0..frontier_len]) |entry| {
            const pos = entry.pos;
            const v = entry.v;

            if (v.max_norm_distance(origin) > d2) continue;

            // a/b are swapped relative to the Rust original because
            // this game uses y-down screen coordinates, which flips
            // the handedness of the (right, up) basis.
            const cell_shadow = ShadowInterval{
                .a = v.plus(right.ivec()).minus(up.ivec()),
                .b = v.plus(up.ivec()).minus(right.ivec()),
            };

            const u_pos = pos.plus(up.ivec());
            const u_v = v.plus(up.ivec().scaled(2));
            const r_pos = pos.plus(right.ivec());
            const r_v = v.plus(right.ivec().scaled(2));

            const cov = shadows.coverage(cell_shadow);
            if (cov >= 3) continue;

            record(pos);

            if (blocked(pos) and !v.eq(origin)) {
                shadows.add_interval(cell_shadow);
            }

            if (cov < 2) {
                // deduplicate: only add u if it differs from the last entry
                if (next_len == 0 or !next[next_len - 1].pos.eq(u_pos) or !next[next_len - 1].v.eq(u_v)) {
                    if (next_len < MAX_FRONTIER) {
                        next[next_len] = .{ .pos = u_pos, .v = u_v };
                        next_len += 1;
                    }
                }
                if (next_len < MAX_FRONTIER) {
                    next[next_len] = .{ .pos = r_pos, .v = r_v };
                    next_len += 1;
                }
            }
        }

        // swap frontier and next
        const tmp_len = frontier_len;
        _ = tmp_len;
        frontier_len = next_len;
        next_len = 0;
        @memcpy(frontier[0..frontier_len], next[0..frontier_len]);
    }
}

fn is_blocked(pos: IVec2) bool {
    return map.get_terrain_at(pos).blocks_fov();
}

pub fn refresh_fov(center: IVec2, distance: u8) void {
    std.log.info("fov: {}", .{center});
    // mark the center tile
    map.mark_seen(center);

    // scan all four quadrants
    for (0..4) |r| {
        scan_quadrant(center, @intCast(r), distance, &is_blocked, &map.mark_seen);
    }
}
