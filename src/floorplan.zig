const std = @import("std");
const core = @import("core.zig");
const map = @import("map.zig");
const Terrain = map.Terrain;
const IVec2 = core.IVec2;
const IRect = core.IRect;

const max_template_side = 16;
const max_output_side = 128;
const scratch_size = 8192;

fn assert(ok: bool, comptime msg: []const u8, args: anytype) void {
    if (!ok) {
        std.log.err(msg, args);
        unreachable;
    }
}

pub fn stamp_floorplan(rect: IRect, rng: std.Random) bool {
    std.log.err("stamp_floorplan: x={} y={} w={} h={}", .{ rect.x, rect.y, rect.w, rect.h });
    assert(rect.w >= 0, "rect.w={} negative", .{rect.w});
    assert(rect.h >= 0, "rect.h={} negative", .{rect.h});
    assert(rect.w <= max_output_side, "rect.w={} > max_output_side", .{rect.w});
    assert(rect.h <= max_output_side, "rect.h={} > max_output_side", .{rect.h});
    const target_w: u8 = @intCast(rect.w);
    const target_h: u8 = @intCast(rect.h);

    const template = pick_template(target_w, target_h, rng) orelse return false;
    assert(template.w >= 2, "template.w={} < 2", .{template.w});
    assert(template.h >= 2, "template.h={} < 2", .{template.h});
    assert(template.w <= target_w, "template.w={} > target_w={}", .{ template.w, target_w });
    assert(template.h <= target_h, "template.h={} > target_h={}", .{ template.h, target_h });

    var scratch: [scratch_size]Terrain = undefined;

    const extra_cols = target_w - template.w;
    var col_map: [max_output_side]u8 = undefined;
    for (0..template.w) |i| {
        col_map[i] = @intCast(i);
    }
    var col_is_dup: [max_output_side]bool = .{false} ** max_output_side;
    var current_w: u8 = template.w;
    for (0..extra_cols) |_| {
        const gap = rng.intRangeLessThan(u8, 0, current_w - 1);
        const c0 = col_map[gap];
        const c1 = col_map[gap + 1];
        const v0 = template.is_valid_col_seam(c0);
        const v1 = template.is_valid_col_seam(c1);
        const pick: u8 = if (v0 and v1)
            if (rng.boolean()) c0 else c1
        else if (v0)
            c0
        else
            c1;
        var j: u8 = current_w;
        while (j > gap + 1) : (j -= 1) {
            col_map[j] = col_map[j - 1];
            col_is_dup[j] = col_is_dup[j - 1];
        }
        col_map[gap + 1] = pick;
        col_is_dup[gap + 1] = true;
        current_w += 1;
    }

    const extra_rows = target_h - template.h;
    var row_map: [max_output_side]u8 = undefined;
    for (0..template.h) |i| {
        row_map[i] = @intCast(i);
    }
    var row_is_dup: [max_output_side]bool = .{false} ** max_output_side;
    var current_h: u8 = template.h;
    for (0..extra_rows) |_| {
        const gap = rng.intRangeLessThan(u8, 0, current_h - 1);
        const r0 = row_map[gap];
        const r1 = row_map[gap + 1];
        const v0 = template.is_valid_row_seam(r0);
        const v1 = template.is_valid_row_seam(r1);
        const pick: u8 = if (v0 and v1)
            if (rng.boolean()) r0 else r1
        else if (v0)
            r0
        else
            r1;
        var j: u8 = current_h;
        while (j > gap + 1) : (j -= 1) {
            row_map[j] = row_map[j - 1];
            row_is_dup[j] = row_is_dup[j - 1];
        }
        row_map[gap + 1] = pick;
        row_is_dup[gap + 1] = true;
        current_h += 1;
    }

    const total = @as(usize, target_w) * target_h;
    if (total > scratch_size) return false;

    for (0..target_h) |y| {
        for (0..target_w) |x| {
            var t = template.get(col_map[x], row_map[y]);
            if ((col_is_dup[x] or row_is_dup[y]) and t.restricted()) {
                t = .wall;
            }
            scratch[y * target_w + x] = t;
        }
    }

    for (0..target_h) |y| {
        for (0..target_w) |x| {
            const pos = IVec2{
                .x = rect.x + @as(i16, @intCast(x)),
                .y = rect.y + @as(i16, @intCast(y)),
            };
            map.set_terrain_at(pos, scratch[y * target_w + x]);
        }
    }
    std.log.err("stamp_floorplan: done", .{});
    return true;
}

fn pick_template(target_w: u8, target_h: u8, rng: std.Random) ?Template {
    // Try a few random templates with random transforms
    const max_attempts = all_templates.len * 8;
    for (0..max_attempts) |_| {
        const base = all_templates[rng.intRangeLessThan(usize, 0, all_templates.len)];
        const transformed = base.transform(Dihedral.random(rng));
        if (transformed.w <= target_w and transformed.h <= target_h) {
            return transformed;
        }
    }
    return null;
}

const Template = struct {
    data: [max_template_side * max_template_side]Terrain,
    w: u8,
    h: u8,

    fn get(self: *const Template, x: u8, y: u8) Terrain {
        return self.data[@as(usize, y) * self.w + x];
    }

    fn col_has_consecutive_restricted(self: *const Template, x: u8) bool {
        var prev_restricted = false;
        for (0..self.h) |yi| {
            const r = self.get(x, @intCast(yi)).restricted();
            if (r and prev_restricted) return true;
            prev_restricted = r;
        }
        return false;
    }

    fn row_has_consecutive_restricted(self: *const Template, y: u8) bool {
        var prev_restricted = false;
        for (0..self.w) |xi| {
            const r = self.get(@intCast(xi), y).restricted();
            if (r and prev_restricted) return true;
            prev_restricted = r;
        }
        return false;
    }

    fn is_valid_row_seam(self: *const Template, y: u8) bool {
        return !self.row_has_consecutive_restricted(y);
    }

    fn is_valid_col_seam(self: *const Template, x: u8) bool {
        return !self.col_has_consecutive_restricted(x);
    }

    fn is_saturated(self: *const Template) bool {
        for (0..self.h - 1) |y| {
            const yi: u8 = @intCast(y);
            if (!self.is_valid_row_seam(yi) and !self.is_valid_row_seam(yi + 1)) return false;
        }
        for (0..self.w - 1) |x| {
            const xi: u8 = @intCast(x);
            if (!self.is_valid_col_seam(xi) and !self.is_valid_col_seam(xi + 1)) return false;
        }
        return true;
    }

    fn transform(self: *const Template, d: Dihedral) Template {
        const new_w: u8 = if (d.swaps_axes()) self.h else self.w;
        const new_h: u8 = if (d.swaps_axes()) self.w else self.h;
        var data: [max_template_side * max_template_side]Terrain = undefined;
        for (0..new_h) |y| {
            for (0..new_w) |x| {
                const src = d.apply(@intCast(x), @intCast(y), self.w, self.h);
                data[y * new_w + x] = self.get(src[0], src[1]);
            }
        }
        return .{ .data = data, .w = new_w, .h = new_h };
    }

    fn char_to_terrain(c: u8) Terrain {
        return switch (c) {
            '#' => .wall,
            '=' => .window,
            '.' => .floor,
            '+' => .door,
            else => .floor,
        };
    }
};

const Dihedral = struct {
    rotation: u2,
    reflect: bool,

    fn random(rng: std.Random) Dihedral {
        return .{
            .rotation = rng.int(u2),
            .reflect = rng.boolean(),
        };
    }

    fn swaps_axes(self: Dihedral) bool {
        return self.rotation == 1 or self.rotation == 3;
    }

    // Maps output (x,y) to source (sx,sy).
    // Output dimensions are (new_w, new_h) where swapped axes use (src_h, src_w).
    fn apply(self: Dihedral, x: u8, y: u8, src_w: u8, src_h: u8) [2]u8 {
        var sx: u8 = x;
        var sy: u8 = y;
        switch (self.rotation) {
            0 => {},
            1 => {
                // 90° CW: source(sx,sy) -> output(src_h-1-sy, sx)
                // inverse: output(x,y) -> source(y, src_h-1-x)
                sx = y;
                sy = src_h - 1 - x;
            },
            2 => {
                sx = src_w - 1 - x;
                sy = src_h - 1 - y;
            },
            3 => {
                // 270° CW: source(sx,sy) -> output(sy, src_w-1-sx)
                // inverse: output(x,y) -> source(src_w-1-y, x)
                sx = src_w - 1 - y;
                sy = x;
            },
        }
        if (self.reflect) {
            sx = src_w - 1 - sx;
        }
        return .{ sx, sy };
    }
};

const floorplan_data = @embedFile("floorplans/plans.txt");
const all_templates = parse_all(all_lines);

fn split_lines(comptime data: []const u8) []const []const u8 {
    @setEvalBranchQuota(10000);
    var lines: []const []const u8 = &.{};
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        lines = lines ++ .{line};
    }
    return lines;
}

fn count_templates(comptime lines: []const []const u8) usize {
    var count: usize = 0;
    var has_rows = false;
    for (lines) |line| {
        const is_separator = line.len > 0 and line[0] == '-';
        const is_empty = line.len == 0;
        if (is_separator or is_empty) {
            if (has_rows) {
                count += 1;
                has_rows = false;
            }
        } else {
            has_rows = true;
        }
    }
    if (has_rows) count += 1;
    return count;
}

const all_lines = split_lines(floorplan_data);

fn parse_all(comptime lines: []const []const u8) [count_templates(lines)]Template {
    const count = count_templates(lines);
    if (count == 0) @compileError("no templates found");
    var result: [count]Template = undefined;
    var idx: usize = 0;

    var rows: [max_template_side][]const u8 = undefined;
    var row_count: usize = 0;

    for (lines) |line| {
        const is_separator = line.len > 0 and line[0] == '-';
        const is_empty = line.len == 0;

        if (is_separator or is_empty) {
            if (row_count > 0) {
                result[idx] = parse_template(rows[0..row_count], idx);
                idx += 1;
                row_count = 0;
            }
        } else {
            if (row_count >= max_template_side) @compileError("template too tall");
            rows[row_count] = line;
            row_count += 1;
        }
    }
    if (row_count > 0) {
        result[idx] = parse_template(rows[0..row_count], idx);
    }

    return result;
}

fn parse_template(comptime rows: []const []const u8, comptime index: usize) Template {
    @setEvalBranchQuota(10000);
    const h: u8 = @intCast(rows.len);
    const w: u8 = @intCast(rows[0].len);
    var data: [max_template_side * max_template_side]Terrain = .{.floor} ** (max_template_side * max_template_side);
    for (0..h) |y| {
        if (rows[y].len != w) @compileError("inconsistent row width in template");
        for (0..w) |x| {
            data[y * w + x] = Template.char_to_terrain(rows[y][x]);
        }
    }
    const result = Template{ .data = data, .w = w, .h = h };
    if (!result.is_saturated()) {
        @compileError(std.fmt.comptimePrint("template {} is not saturated", .{index}));
    }
    return result;
}
