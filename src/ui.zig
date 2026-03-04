const core = @import("core.zig");
const IRect = core.IRect;

const max_entries = 16;

pub const MAIN_VIEW: Layout = parse(@embedFile("main_view.txt"));

const Entry = struct {
    name: []const u8,
    rect: IRect,
};

pub const Layout = struct {
    entries: [max_entries]Entry,
    count: usize,

    pub fn get(comptime self: Layout, comptime name: []const u8) IRect {
        inline for (0..self.count) |i| {
            if (comptime std.mem.eql(u8, self.entries[i].name, name)) {
                return self.entries[i].rect;
            }
        }
        @compileError("layout region not found: " ++ name);
    }
};

const std = @import("std");

fn isLabelChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

pub fn parse(comptime source: []const u8) Layout {
    comptime {
        @setEvalBranchQuota(100000);
        // Split into lines
        const lines = splitLines(source);
        const height = lines.len;
        if (height == 0) @compileError("empty layout");

        var result: Layout = .{
            .entries = undefined,
            .count = 0,
        };

        // Scan for labels
        for (0..height) |row| {
            const line = lines[row];
            var col: usize = 0;
            while (col < line.len) {
                // Skip comments inside brackets
                if (line[col] == '[') {
                    while (col < line.len and line[col] != ']') {
                        col += 1;
                    }
                    if (col < line.len) col += 1; // skip ']'
                    continue;
                }
                if (isLabelChar(line[col])) {
                    // Check that preceding char is not a label char
                    if (col > 0 and isLabelChar(line[col - 1])) {
                        col += 1;
                        continue;
                    }
                    // Read the full label run
                    const start = col;
                    while (col < line.len and isLabelChar(line[col])) {
                        col += 1;
                    }
                    const name = line[start..col];

                    // Find enclosing borders
                    const rect = findEnclosingRect(lines, start, row);

                    if (result.count >= max_entries) {
                        @compileError("too many layout regions (max 16)");
                    }
                    result.entries[result.count] = .{ .name = name, .rect = rect };
                    result.count += 1;
                } else {
                    col += 1;
                }
            }
        }

        if (result.count == 0) @compileError("no labels found in layout");

        return result;
    }
}

fn charAt(comptime lines: []const []const u8, comptime col: usize, comptime row: usize) u8 {
    if (row >= lines.len) return 0;
    if (col >= lines[row].len) return 0;
    return lines[row][col];
}

fn isBorderV(ch: u8) bool {
    return ch == '|' or ch == '+';
}

fn isBorderH(ch: u8) bool {
    return ch == '-' or ch == '+';
}

fn findEnclosingRect(comptime lines: []const []const u8, comptime label_col: usize, comptime label_row: usize) IRect {
    comptime {
        // Scan left for | or +
        var left_col: usize = label_col;
        while (true) {
            if (left_col == 0) @compileError("no left border found for label");
            left_col -= 1;
            if (isBorderV(charAt(lines, left_col, label_row))) break;
        }

        // Scan right for | or +
        var right_col: usize = label_col;
        while (true) {
            right_col += 1;
            if (right_col >= lines[label_row].len) @compileError("no right border found for label");
            if (isBorderV(charAt(lines, right_col, label_row))) break;
        }

        // Scan up for - or +
        var top_row: usize = label_row;
        while (true) {
            if (top_row == 0) @compileError("no top border found for label");
            top_row -= 1;
            if (isBorderH(charAt(lines, label_col, top_row))) break;
        }

        // Scan down for - or +
        var bottom_row: usize = label_row;
        while (true) {
            bottom_row += 1;
            if (bottom_row >= lines.len) @compileError("no bottom border found for label");
            if (isBorderH(charAt(lines, label_col, bottom_row))) break;
        }

        // Region owns left/top border, not right/bottom
        return .{
            .x = @intCast(left_col),
            .y = @intCast(top_row),
            .w = @intCast(right_col - left_col),
            .h = @intCast(bottom_row - top_row),
        };
    }
}

fn splitLines(comptime source: []const u8) []const []const u8 {
    comptime {
        var line_count: usize = 0;
        var i: usize = 0;

        // Count lines
        while (i <= source.len) {
            if (i == source.len or source[i] == '\n') {
                line_count += 1;
                i += 1;
            } else {
                i += 1;
            }
        }

        var lines: [line_count][]const u8 = undefined;
        var line_start: usize = 0;
        var line_idx: usize = 0;
        i = 0;
        while (i <= source.len) {
            if (i == source.len or source[i] == '\n') {
                var end = i;
                // Trim \r
                if (end > line_start and source[end - 1] == '\r') {
                    end -= 1;
                }
                lines[line_idx] = source[line_start..end];
                line_idx += 1;
                line_start = i + 1;
                i += 1;
            } else {
                i += 1;
            }
        }

        return &lines;
    }
}

test "basic layout parsing" {
    const source =
        \\+-------+----------+
        \\|       |   log    |
        \\| game  |          |
        \\|       +----------+
        \\|       | status   |
        \\+-------+----------+
    ;

    const layout = comptime parse(source);

    const game = comptime layout.get("game");
    try std.testing.expectEqual(@as(i16, 0), game.x);
    try std.testing.expectEqual(@as(i16, 0), game.y);
    try std.testing.expectEqual(@as(i16, 8), game.w);
    try std.testing.expectEqual(@as(i16, 5), game.h);

    const log = comptime layout.get("log");
    try std.testing.expectEqual(@as(i16, 8), log.x);
    try std.testing.expectEqual(@as(i16, 0), log.y);
    try std.testing.expectEqual(@as(i16, 11), log.w);
    try std.testing.expectEqual(@as(i16, 3), log.h);

    const status = comptime layout.get("status");
    try std.testing.expectEqual(@as(i16, 8), status.x);
    try std.testing.expectEqual(@as(i16, 3), status.y);
    try std.testing.expectEqual(@as(i16, 11), status.w);
    try std.testing.expectEqual(@as(i16, 2), status.h);
}
